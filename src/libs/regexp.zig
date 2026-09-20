//! ECMAScript regular-expression compiler and QuickJS `libregexp.c`-style backtracking bytecode executor.
//! Patterns and inputs are borrowed; `Compiled` owns bytecode, and scratch storage owns only inline-buffer overflow.
//!
//! The executor only runs bytecode this compiler produced: like QuickJS's
//! `lre_exec`, it trusts the header and opcode operands, with Debug assertions
//! guarding the internal contract. `error.BytecodeCorrupt` is reserved for the
//! few operand shapes that would otherwise index out of range even on
//! well-formed input.
const std = @import("std");
const array_list_erased = @import("../core/array_list_erased.zig");
const sort_erased = @import("../core/sort_erased.zig");
const unicode = @import("unicode.zig");
const regexp_properties = unicode;

pub const max_captures = 255;
const register_count_max = 255;
pub const max_exec_slots = max_captures * 2 + register_count_max;
pub const small_exec_slots = 64;
const static_bt_frame_count = 16;
const static_undo_count = 32;
const interrupt_counter_init = 10000;

/// The flag word at the head of compiled bytecode (a little-endian u16):
/// the eight `dgimsuvy` letters plus `named_groups`, which the compiler
/// sets when the pattern declares a named capture.
pub const Flags = packed struct(u16) {
    global: bool = false,
    ignore_case: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
    unicode: bool = false,
    sticky: bool = false,
    indices: bool = false,
    named_groups: bool = false,
    unicode_sets: bool = false,
    _reserved: u7 = 0,

    pub fn fromBits(raw: u16) Flags {
        return @bitCast(raw);
    }

    pub fn bits(self: Flags) u16 {
        return @bitCast(self);
    }

    /// `u` or `v`: pattern and input are read as code points.
    pub fn fullUnicode(self: Flags) bool {
        return self.unicode or self.unicode_sets;
    }

    /// A `dgimsuvy` flag string in any order: repeats and unknown letters
    /// are InvalidPattern, and `u` excludes `v`.
    pub fn parse(flag_bytes: []const u8) CompileError!Flags {
        var seen: [256]bool = [_]bool{false} ** 256;
        var parsed: Flags = .{};
        for (flag_bytes) |flag| {
            if (seen[flag]) return error.InvalidPattern;
            seen[flag] = true;
            switch (flag) {
                'd' => parsed.indices = true,
                'g' => parsed.global = true,
                'i' => parsed.ignore_case = true,
                'm' => parsed.multiline = true,
                's' => parsed.dot_all = true,
                'u' => parsed.unicode = true,
                'v' => parsed.unicode_sets = true,
                'y' => parsed.sticky = true,
                else => return error.InvalidPattern,
            }
        }
        if (parsed.unicode and parsed.unicode_sets) return error.InvalidPattern;
        return parsed;
    }
};

pub const ExecResult = enum {
    match,
    no_match,
    out_of_range,
    not_available,
};

pub const Input = union(enum) {
    latin1: []const u8,
    utf16: []const u16,

    // Module-private: callers outside this file choose their own input handling.
    fn len(self: Input) usize {
        return switch (self) {
            .latin1 => |bytes| bytes.len,
            .utf16 => |units| units.len,
        };
    }
};

/// Host callbacks the compiler and executor poll, bound to one opaque
/// context pointer. Both are optional: without them the library never
/// interrupts a match and never refuses recursion.
pub const Host = struct {
    context: ?*anyopaque = null,
    /// Polled every `interrupt_counter_init` backtrack steps; true aborts the
    /// match with `error.Timeout`.
    checkTimeout: ?*const fn (?*anyopaque) bool = null,
    /// Mirrors qjs `lre_check_stack_overflow`: true when `alloca_size` more
    /// bytes of native stack would overflow, which the parser reports as a
    /// pattern error.
    checkStackOverflow: ?*const fn (?*anyopaque, usize) bool = null,

    fn stackOverflows(self: Host, alloca_size: usize) bool {
        const check = self.checkStackOverflow orelse return false;
        return check(self.context, alloca_size);
    }
};

pub const ExecOptions = struct {
    host: Host = .{},
};

const REBytecodeHeader = struct {
    flags: Flags,
    capture_count: usize,
    register_count: usize,
    bytecode_len: usize,
};

const CaptureSlotBuffer = struct {
    inline_slots: [small_exec_slots]usize = undefined,
    heap_slots: []usize = &.{},
    slots: []usize = &.{},

    /// `CaptureSlotBuffer{}` memcpy's a 544-byte `.rodata` template: 64 zero
    /// slots plus two empty `[]usize` whose pointer is `@alignOf(usize)`.
    /// Zero in place and store `&.{}` so that template can leave.
    fn initDefault(self: *CaptureSlotBuffer) void {
        self.* = std.mem.zeroes(CaptureSlotBuffer);
        const empty: []usize = &.{};
        self.heap_slots = empty;
        self.slots = empty;
    }

    fn init(self: *CaptureSlotBuffer, allocator: std.mem.Allocator, count: usize) !void {
        if (count <= self.inline_slots.len) {
            self.slots = self.inline_slots[0..count];
            return;
        }
        self.heap_slots = try allocator.alloc(usize, count);
        self.slots = self.heap_slots;
    }

    fn deinit(self: *CaptureSlotBuffer, allocator: std.mem.Allocator) void {
        if (self.heap_slots.len != 0) allocator.free(self.heap_slots);
        self.initDefault();
    }
};

//=== Opcode enum ==========================================================

const REOPCodeEnum = enum(u8) {
    invalid,
    char,
    char_i,
    char32,
    char32_i,
    dot,
    any,
    space,
    not_space,
    line_start,
    line_start_m,
    line_end,
    line_end_m,
    goto_,
    split_goto_first,
    split_next_first,
    match,
    lookahead_match,
    negative_lookahead_match,
    save_start,
    save_end,
    save_reset,
    loop,
    loop_split_goto_first,
    loop_split_next_first,
    loop_check_adv_split_goto_first,
    loop_check_adv_split_next_first,
    set_i32,
    word_boundary,
    word_boundary_i,
    not_word_boundary,
    not_word_boundary_i,
    back_reference,
    back_reference_i,
    backward_back_reference,
    backward_back_reference_i,
    range,
    range_i,
    range32,
    range32_i,
    lookahead,
    negative_lookahead,
    set_char_pos,
    check_advance,
    prev,
    class8,
    not_class8,
    scan_until_char8,
    loop_class8_g,
    loop_not_class8_g,
};

//=== Bytecode layout & shared tables ======================================

const header_len = 8;
const re_header_capture_count = 2;
const re_header_register_count = 3;
const re_header_bytecode_len = 4;
const int32_max: u32 = 0x7fffffff;
const group_name_trailer_len = 2;
const class8_bitmap_len = 16;
const class8_char_count = class8_bitmap_len * 8;

//=== Execution enums & context ===========================================

const CbufType = enum {
    latin1,
    utf16_units,
    utf16_unicode,
};

const REExecStateEnum = enum(u3) {
    split,
    lookahead,
    negative_lookahead,
};

const no_slot_value = std.math.maxInt(usize);
const compact_no_slot_value = std.math.maxInt(u32);

const REBTFrame = extern struct {
    pc_off: u32,
    cptr: u32,
    undo_top: u32,
    typ: u8,
};

const REUndo = extern struct {
    old_value: u32,
    slot: u16,
};

const REExecContext = struct {
    allocator: std.mem.Allocator,
    cbuf: [*]const u8,
    cbuf_end: usize,
    capture_count: usize,
    register_count: usize,
    alloc_count: usize,
    is_unicode: bool,
    interrupt_counter: i32,
    host: Host,
    bt_frames: []REBTFrame,
    undo_stack: []REUndo,
    static_bt_frames: [static_bt_frame_count]REBTFrame,
    static_undo_stack: [static_undo_count]REUndo,

    fn deinit(self: *REExecContext) void {
        if (self.bt_frames.len != 0 and self.bt_frames.ptr != self.static_bt_frames[0..].ptr) {
            self.allocator.free(self.bt_frames);
        }
        if (self.undo_stack.len != 0 and self.undo_stack.ptr != self.static_undo_stack[0..].ptr) {
            self.allocator.free(self.undo_stack);
        }
        self.bt_frames = &.{};
        self.undo_stack = &.{};
    }

    inline fn pollTimeout(self: *REExecContext) !void {
        const check_timeout = self.host.checkTimeout orelse return;
        self.interrupt_counter -= 1;
        if (self.interrupt_counter <= 0) {
            self.interrupt_counter = interrupt_counter_init;
            if (check_timeout(self.host.context)) return error.Timeout;
        }
    }

    fn btFrameRealloc(self: *REExecContext, n: usize, used: usize) !void {
        var new_size = self.bt_frames.len * 3 / 2;
        if (new_size < n) new_size = n;
        if (self.bt_frames.ptr == self.static_bt_frames[0..].ptr) {
            const new_stack = try self.allocator.alloc(REBTFrame, new_size);
            @memcpy(new_stack[0..used], self.bt_frames[0..used]);
            self.bt_frames = new_stack;
        } else {
            self.bt_frames = try self.allocator.realloc(self.bt_frames, new_size);
        }
    }

    fn undoRealloc(self: *REExecContext, n: usize, used: usize) !void {
        var new_size = self.undo_stack.len * 3 / 2;
        if (new_size < n) new_size = n;
        if (self.undo_stack.ptr == self.static_undo_stack[0..].ptr) {
            const new_stack = try self.allocator.alloc(REUndo, new_size);
            @memcpy(new_stack[0..used], self.undo_stack[0..used]);
            self.undo_stack = new_stack;
        } else {
            self.undo_stack = try self.allocator.realloc(self.undo_stack, new_size);
        }
    }
};

// Shared classification and canonicalization tables.

const lre_ctype_space: u8 = 1 << 0;
const lre_ctype_digit: u8 = 1 << 1;
const lre_ctype_upper: u8 = 1 << 2;
const lre_ctype_lower: u8 = 1 << 3;
const lre_ctype_under: u8 = 1 << 4;

const lre_ctype_bits = buildLRECtypeBits();
const lre_canonicalize_non_unicode_latin1 = buildLRECanonicalizeLatin1(false);
const lre_canonicalize_unicode_latin1 = buildLRECanonicalizeLatin1(true);

fn buildLRECtypeBits() [256]u8 {
    var table: [256]u8 = @splat(0);
    for (0..table.len) |i| {
        const byte: u8 = @intCast(i);
        if ((byte >= 0x09 and byte <= 0x0d) or byte == 0x20 or byte == 0xa0) table[i] |= lre_ctype_space;
        if (byte >= '0' and byte <= '9') table[i] |= lre_ctype_digit;
        if (byte >= 'A' and byte <= 'Z') table[i] |= lre_ctype_upper;
        if (byte >= 'a' and byte <= 'z') table[i] |= lre_ctype_lower;
        if (byte == '_') table[i] |= lre_ctype_under;
    }
    return table;
}

fn buildLRECanonicalizeLatin1(comptime is_unicode: bool) [256]u21 {
    @setEvalBranchQuota(20000);
    var table: [256]u21 = undefined;
    for (0..table.len) |i| {
        table[i] = unicode.regexpCanonicalize(@intCast(i), is_unicode);
    }
    return table;
}

inline fn lreCanonicalize(code_point: u21, is_unicode: bool) u21 {
    if (code_point < 128) {
        if (is_unicode) {
            if (code_point >= 'A' and code_point <= 'Z') return code_point - 'A' + 'a';
        } else {
            if (code_point >= 'a' and code_point <= 'z') return code_point - 'a' + 'A';
        }
        return code_point;
    }
    if (code_point < 256) {
        const byte: u8 = @intCast(code_point);
        return if (is_unicode)
            lre_canonicalize_unicode_latin1[byte]
        else
            lre_canonicalize_non_unicode_latin1[byte];
    }
    return unicode.regexpCanonicalize(code_point, is_unicode);
}

//=== Header / slot helpers ===============================================

fn normalizeStartIndex(input: Input, cbuf_type: CbufType, start_index: usize) usize {
    if (cbuf_type != .utf16_unicode) return start_index;
    return switch (input) {
        .latin1 => start_index,
        .utf16 => |units| {
            if (start_index == 0 or start_index >= units.len) return start_index;
            if (isLoSurrogate(units[start_index]) and isHiSurrogate(units[start_index - 1])) {
                return start_index - 1;
            }
            return start_index;
        },
    };
}

fn slotOptional(value: usize) ?usize {
    return if (value == no_slot_value) null else value;
}

pub fn captureSlotValue(value: usize) ?usize {
    return slotOptional(value);
}

fn captureCountFromBytecode(bytecode: []const u8) usize {
    if (bytecode.len <= re_header_capture_count) return 0;
    return bytecode[re_header_capture_count];
}

fn registerCountFromBytecode(bytecode: []const u8) usize {
    if (bytecode.len <= re_header_register_count) return 0;
    return bytecode[re_header_register_count];
}

fn allocCountFromBytecode(bytecode: []const u8) usize {
    return captureCountFromBytecode(bytecode) * 2 + registerCountFromBytecode(bytecode);
}

pub fn getFlags(bytecode: []const u8) Flags {
    if (bytecode.len < 2) return .{};
    return Flags.fromBits(std.mem.readInt(u16, bytecode[0..2], .little));
}

fn groupNameFromBytecode(bytecode: []const u8, one_based_capture_index: usize) ?[]const u8 {
    if (one_based_capture_index == 0 or !getFlags(bytecode).named_groups) return null;
    const header = parseHeader(bytecode) catch return null;
    if (one_based_capture_index >= header.capture_count) return null;
    var pos = header_len + header.bytecode_len;
    var capture_index: usize = 1;
    while (capture_index < header.capture_count and pos <= bytecode.len) : (capture_index += 1) {
        const end = std.mem.indexOfScalarPos(u8, bytecode, pos, 0) orelse return null;
        if (end + 1 >= bytecode.len) return null;
        if (capture_index == one_based_capture_index) {
            if (end == pos) return null;
            return bytecode[pos..end];
        }
        pos = end + group_name_trailer_len;
    }
    return null;
}

pub fn groupName(bytecode: []const u8, one_based_capture_index: usize) ?[]const u8 {
    return groupNameFromBytecode(bytecode, one_based_capture_index);
}

//=== Compiled wrapper & exec entry points ================================

pub const Compiled = struct {
    bytecode: []u8,

    pub fn deinit(self: *Compiled, allocator: std.mem.Allocator) void {
        allocator.free(self.bytecode);
        self.bytecode = &.{};
    }

    pub fn captureCount(self: Compiled) usize {
        return captureCountFromBytecode(self.bytecode);
    }

    pub fn allocCount(self: Compiled) usize {
        return allocCountFromBytecode(self.bytecode);
    }

    pub fn groupName(self: Compiled, one_based_capture_index: usize) ?[]const u8 {
        return groupNameFromBytecode(self.bytecode, one_based_capture_index);
    }

    pub fn flags(self: Compiled) Flags {
        return getFlags(self.bytecode);
    }
};

pub fn compilePatternAndFlags(allocator: std.mem.Allocator, pattern: []const u8, flags_str: []const u8) !Compiled {
    return compilePatternAndFlagsWithOptions(allocator, pattern, flags_str, .{});
}

pub fn compilePatternAndFlagsWithOptions(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    flags_str: []const u8,
    options: CompileOptions,
) !Compiled {
    return .{ .bytecode = try compileWithOptions(allocator, pattern, flags_str, options) };
}

pub fn compilePatternWithFlagsAndOptions(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    re_flags: Flags,
    options: CompileOptions,
) !Compiled {
    return .{ .bytecode = try compileWithFlagsAndOptions(allocator, pattern, re_flags, options) };
}

fn isSupportedUnicodePropertyExpression(name: []const u8) bool {
    return regexp_properties.isSupportedUnicodePropertyExpression(name);
}

/// Capture-slot execution for compiler-produced bytecode: the header is
/// trusted (Debug-asserted), and `capture` must hold `capture_count * 2 +
/// register_count` slots.
pub fn execCaptureSlotsSliceTrustedWithOptions(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    input: Input,
    start_index: usize,
    options: ExecOptions,
    capture: []usize,
) !ExecResult {
    const header = parseHeaderTrusted(bytecode);
    return execCaptureSlotsParsed(allocator, bytecode, input, start_index, options, header, capture);
}

fn execCaptureSlotsParsed(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    input: Input,
    start_index: usize,
    options: ExecOptions,
    header: REBytecodeHeader,
    capture: []usize,
) !ExecResult {
    const alloc_count = header.capture_count * 2 + header.register_count;
    std.debug.assert(capture.len >= alloc_count);
    if (start_index > input.len()) return .out_of_range;
    std.debug.assert(input.len() < compact_no_slot_value);
    std.debug.assert(header_len + header.bytecode_len < compact_no_slot_value);
    const cbuf_type: CbufType = switch (input) {
        .latin1 => .latin1,
        .utf16 => if (header.flags.fullUnicode()) .utf16_unicode else .utf16_units,
    };
    const initial_cptr = normalizeStartIndex(input, cbuf_type, start_index);
    const cbuf: [*]const u8 = switch (input) {
        .latin1 => |bytes| bytes.ptr,
        .utf16 => |units| @ptrCast(units.ptr),
    };

    var ctx = REExecContext{
        .allocator = allocator,
        .cbuf = cbuf,
        .cbuf_end = input.len(),
        .capture_count = header.capture_count,
        .register_count = header.register_count,
        .alloc_count = alloc_count,
        .is_unicode = header.flags.fullUnicode(),
        .interrupt_counter = interrupt_counter_init,
        .host = options.host,
        .bt_frames = &.{},
        .undo_stack = &.{},
        .static_bt_frames = undefined,
        .static_undo_stack = undefined,
    };
    ctx.bt_frames = ctx.static_bt_frames[0..];
    ctx.undo_stack = ctx.static_undo_stack[0..];
    defer ctx.deinit();

    @memset(capture[0..alloc_count], no_slot_value);
    const bytecode_end = header_len + header.bytecode_len;
    const matched = switch (cbuf_type) {
        .latin1 => try lreExecBacktrack(.latin1, &ctx, capture.ptr, bytecode, bytecode_end, header_len, initial_cptr),
        .utf16_units => try lreExecBacktrack(.utf16_units, &ctx, capture.ptr, bytecode, bytecode_end, header_len, initial_cptr),
        .utf16_unicode => try lreExecBacktrack(.utf16_unicode, &ctx, capture.ptr, bytecode, bytecode_end, header_len, initial_cptr),
    };
    return if (matched) .match else .no_match;
}

/// Match test without capture output, for compiler-produced bytecode.
pub fn testMatchTrustedWithOptions(allocator: std.mem.Allocator, bytecode: []const u8, input: Input, start_index: usize, options: ExecOptions) !bool {
    const header = parseHeaderTrusted(bytecode);
    var capture_buf: CaptureSlotBuffer = undefined;
    capture_buf.initDefault();
    try capture_buf.init(allocator, header.capture_count * 2 + header.register_count);
    defer capture_buf.deinit(allocator);
    return (try execCaptureSlotsParsed(allocator, bytecode, input, start_index, options, header, capture_buf.slots)) == .match;
}

//=== Execution state & backtrack interpreter ==============================

const ExecState = struct {
    s: *REExecContext,
    capture: [*]usize,
    bc_base: [*]const u8,
    pc: [*]const u8,
    bc_end: [*]const u8,
    bt_frames: [*]REBTFrame,
    undo_stack: [*]REUndo,
    cbuf: [*]const u8,
    cptr: usize,
    bt_len: usize,
    bt_end: usize,
    undo_len: usize,
    undo_end: usize,
    cbuf_end: usize,

    fn init(
        s: *REExecContext,
        capture: [*]usize,
        bytecode: []const u8,
        bytecode_end: usize,
        initial_pc: usize,
        initial_cptr: usize,
    ) ExecState {
        std.debug.assert(initial_pc <= bytecode_end);
        const bc_ptr = bytecode.ptr;
        return .{
            .s = s,
            .capture = capture,
            .bc_base = bc_ptr,
            .pc = bc_ptr + initial_pc,
            .bc_end = bc_ptr + bytecode_end,
            .bt_frames = s.bt_frames.ptr,
            .undo_stack = s.undo_stack.ptr,
            .cbuf = s.cbuf,
            .cptr = initial_cptr,
            .bt_len = 0,
            .bt_end = s.bt_frames.len,
            .undo_len = 0,
            .undo_end = s.undo_stack.len,
            .cbuf_end = s.cbuf_end,
        };
    }

    inline fn cbufUtf16(self: *const ExecState) [*]const u16 {
        return @ptrCast(@alignCast(self.cbuf));
    }

    inline fn checkFrameSpace(self: *ExecState, n: usize) !void {
        const needs_grow = self.bt_end - self.bt_len < n;
        if (needs_grow) {
            @branchHint(.unlikely);
            try self.s.btFrameRealloc(self.bt_len + n, self.bt_len);
            self.bt_frames = self.s.bt_frames.ptr;
            self.bt_end = self.s.bt_frames.len;
        }
    }

    inline fn checkUndoSpace(self: *ExecState, n: usize) !void {
        const needs_grow = self.undo_end - self.undo_len < n;
        if (needs_grow) {
            @branchHint(.unlikely);
            try self.s.undoRealloc(self.undo_len + n, self.undo_len);
            self.undo_stack = self.s.undo_stack.ptr;
            self.undo_end = self.s.undo_stack.len;
        }
    }

    inline fn pcWithOffset(self: *const ExecState, offset: i32) [*]const u8 {
        const delta: usize = @bitCast(@as(isize, offset));
        return @ptrFromInt(@intFromPtr(self.pc) +% delta);
    }

    inline fn getU8(self: *ExecState) u8 {
        const value = self.pc[0];
        self.pc += 1;
        return value;
    }

    inline fn readU8At(_: *const ExecState, ptr: [*]const u8) u8 {
        return ptr[0];
    }

    inline fn getU16(self: *ExecState) u16 {
        const value = std.mem.readInt(u16, self.pc[0..2], .little);
        self.pc += 2;
        return value;
    }

    inline fn readU16UncheckedAt(ptr: [*]const u8) u16 {
        return std.mem.readInt(u16, ptr[0..2], .little);
    }

    inline fn getU32(self: *ExecState) u32 {
        const value = std.mem.readInt(u32, self.pc[0..4], .little);
        self.pc += 4;
        return value;
    }

    inline fn readU32At(_: *const ExecState, ptr: [*]const u8) u32 {
        return std.mem.readInt(u32, ptr[0..4], .little);
    }

    inline fn readU32UncheckedAt(ptr: [*]const u8) u32 {
        return std.mem.readInt(u32, ptr[0..4], .little);
    }

    inline fn getI32(self: *ExecState) i32 {
        return @bitCast(self.getU32());
    }

    inline fn compactIndex(value: usize) u32 {
        return @intCast(value);
    }

    inline fn compactCaptureValue(value: usize) u32 {
        if (value == no_slot_value) return compact_no_slot_value;
        return @intCast(value);
    }

    inline fn expandCaptureValue(value: u32) usize {
        return if (value == compact_no_slot_value) no_slot_value else @as(usize, value);
    }

    inline fn pcOffset(self: *const ExecState, pc: [*]const u8) u32 {
        return compactIndex(@intFromPtr(pc) - @intFromPtr(self.bc_base));
    }

    inline fn pcFromOffset(self: *const ExecState, offset: u32) [*]const u8 {
        return self.bc_base + offset;
    }

    inline fn frameType(frame: REBTFrame) REExecStateEnum {
        return @enumFromInt(frame.typ);
    }

    inline fn pushExecState(self: *ExecState, pc: [*]const u8, typ: REExecStateEnum) !void {
        try self.checkFrameSpace(1);
        const undo_top = compactIndex(self.undo_len);
        self.bt_frames[self.bt_len] = .{
            .pc_off = self.pcOffset(pc),
            .cptr = compactIndex(self.cptr),
            .undo_top = undo_top,
            .typ = @intFromEnum(typ),
        };
        self.bt_len += 1;
    }

    inline fn saveCapture(self: *ExecState, idx: usize, value: usize) !void {
        try self.pushUndo(idx, value);
    }

    inline fn pushUndo(self: *ExecState, idx: usize, value: usize) !void {
        try self.checkUndoSpace(1);
        self.pushUndoAssumeSpace(idx, value);
    }

    inline fn pushUndoAssumeSpace(self: *ExecState, idx: usize, value: usize) void {
        self.undo_stack[self.undo_len] = .{
            .old_value = compactCaptureValue(self.capture[idx]),
            .slot = @intCast(idx),
        };
        self.undo_len += 1;
        self.capture[idx] = value;
    }

    inline fn saveCaptureCheck(self: *ExecState, idx: usize, value: usize) !void {
        const undo_base = self.currentUndoBase();
        var pos = self.undo_len;
        while (pos > undo_base) {
            pos -= 1;
            if (self.undo_stack[pos].slot == idx) {
                self.capture[idx] = value;
                return;
            }
        }
        try self.pushUndo(idx, value);
    }

    inline fn restoreOneUndo(self: *ExecState) void {
        self.undo_len -= 1;
        const undo = self.undo_stack[self.undo_len];
        const slot: usize = undo.slot;
        self.capture[slot] = expandCaptureValue(undo.old_value);
    }

    inline fn restoreUndoTo(self: *ExecState, undo_top: usize) void {
        while (self.undo_len > undo_top) {
            self.restoreOneUndo();
        }
    }

    inline fn currentUndoBase(self: *const ExecState) usize {
        return if (self.bt_len == 0) 0 else self.bt_frames[self.bt_len - 1].undo_top;
    }

    inline fn popFrameRestore(self: *ExecState) REBTFrame {
        const frame = self.bt_frames[self.bt_len - 1];
        self.restoreUndoTo(frame.undo_top);
        self.bt_len -= 1;
        self.pc = self.pcFromOffset(frame.pc_off);
        self.cptr = frame.cptr;
        return frame;
    }

    inline fn popFrameKeepUndo(self: *ExecState) REBTFrame {
        const frame = self.bt_frames[self.bt_len - 1];
        self.bt_len -= 1;
        self.pc = self.pcFromOffset(frame.pc_off);
        self.cptr = frame.cptr;
        return frame;
    }

    inline fn registerSlot(self: *const ExecState, register: usize) usize {
        return self.s.capture_count * 2 + register;
    }

    inline fn readRegisterValue(self: *const ExecState, register: usize) usize {
        return self.capture[self.registerSlot(register)];
    }

    /// Read the code point at `pos.*` (advancing it); the caller guarantees
    /// `pos.* < end <= cbuf_end`.
    inline fn getCharAtBounded(self: *const ExecState, comptime cbuf_type: CbufType, pos: *usize, end: usize) u21 {
        std.debug.assert(pos.* < end and end <= self.cbuf_end);
        if (comptime cbuf_type == .latin1) {
            const code_point: u21 = self.cbuf[pos.*];
            pos.* += 1;
            return code_point;
        }
        const units = self.cbufUtf16();
        var next = pos.* + 1;
        var code_point: u21 = units[pos.*];
        if (comptime cbuf_type == .utf16_unicode) {
            if (isHiSurrogate(code_point) and next < end and isLoSurrogate(units[next])) {
                code_point = fromSurrogate(@intCast(code_point), units[next]);
                next += 1;
            }
        }
        pos.* = next;
        return code_point;
    }

    /// Read the code point before `pos.*` (retreating it); the caller
    /// guarantees `start < pos.* <= cbuf_end`.
    inline fn getPrevCharAtBounded(self: *const ExecState, comptime cbuf_type: CbufType, pos: *usize, start: usize) u21 {
        std.debug.assert(start < pos.* and pos.* <= self.cbuf_end);
        if (comptime cbuf_type == .latin1) {
            pos.* -= 1;
            return self.cbuf[pos.*];
        }
        const units = self.cbufUtf16();
        var prev = pos.* - 1;
        var code_point: u21 = units[prev];
        if (comptime cbuf_type == .utf16_unicode) {
            if (isLoSurrogate(code_point) and prev > start and isHiSurrogate(units[prev - 1])) {
                prev -= 1;
                code_point = fromSurrogate(units[prev], @intCast(code_point));
            }
        }
        pos.* = prev;
        return code_point;
    }

    inline fn getCharUnchecked(self: *ExecState, comptime cbuf_type: CbufType) u21 {
        if (comptime cbuf_type == .latin1) {
            const code_point: u21 = self.cbuf[self.cptr];
            self.cptr += 1;
            return code_point;
        }
        const units = self.cbufUtf16();
        var code_point: u21 = units[self.cptr];
        self.cptr += 1;
        if (comptime cbuf_type == .utf16_unicode) {
            if (isHiSurrogate(code_point) and self.cptr < self.cbuf_end and isLoSurrogate(units[self.cptr])) {
                code_point = fromSurrogate(@intCast(code_point), units[self.cptr]);
                self.cptr += 1;
            }
        }
        return code_point;
    }

    inline fn peekChar(self: *const ExecState, comptime cbuf_type: CbufType) ?u21 {
        if (comptime cbuf_type == .latin1) {
            if (self.cptr >= self.cbuf_end) return null;
            return self.cbuf[self.cptr];
        }
        if (self.cptr >= self.cbuf_end) return null;
        const units = self.cbufUtf16();
        var code_point: u21 = units[self.cptr];
        const next = self.cptr + 1;
        if (comptime cbuf_type == .utf16_unicode) {
            if (isHiSurrogate(code_point) and next < self.cbuf_end and isLoSurrogate(units[next])) {
                code_point = fromSurrogate(@intCast(code_point), units[next]);
            }
        }
        return code_point;
    }

    inline fn peekPrevChar(self: *const ExecState, comptime cbuf_type: CbufType) ?u21 {
        if (self.cptr == 0) return null;
        if (comptime cbuf_type == .latin1) {
            if (self.cptr > self.cbuf_end) return null;
            return self.cbuf[self.cptr - 1];
        }
        if (self.cptr > self.cbuf_end) return null;
        const units = self.cbufUtf16();
        const prev = self.cptr - 1;
        var code_point: u21 = units[prev];
        if (comptime cbuf_type == .utf16_unicode) {
            if (isLoSurrogate(code_point) and prev > 0 and isHiSurrogate(units[prev - 1])) {
                code_point = fromSurrogate(units[prev - 1], @intCast(code_point));
            }
        }
        return code_point;
    }

    inline fn prevChar(self: *ExecState, comptime cbuf_type: CbufType) !void {
        if (self.cptr == 0) return error.BytecodeCorrupt;
        if (comptime cbuf_type == .latin1) {
            if (self.cptr > self.cbuf_end) return error.BytecodeCorrupt;
            self.cptr -= 1;
            return;
        }
        if (self.cptr > self.cbuf_end) return error.BytecodeCorrupt;
        const units = self.cbufUtf16();
        var prev = self.cptr - 1;
        const code_point: u21 = units[prev];
        if (comptime cbuf_type == .utf16_unicode) {
            if (isLoSurrogate(code_point) and prev > 0 and isHiSurrogate(units[prev - 1])) {
                prev -= 1;
            }
        }
        self.cptr = prev;
    }

    inline fn scanUntilChar8(self: *ExecState, comptime cbuf_type: CbufType, needle: u8) bool {
        // The search prelude has already consumed the current unit; resume from
        // the following position and leave cptr on the matched needle.
        if (self.cptr >= self.cbuf_end) return false;
        var pos = self.cptr + 1;
        if (comptime cbuf_type == .latin1) {
            const haystack = self.cbuf[pos..self.cbuf_end];
            if (std.mem.indexOfScalar(u8, haystack, needle)) |offset| {
                self.cptr = pos + offset;
                return true;
            }
            return false;
        }

        const units = self.cbufUtf16();
        while (pos < self.cbuf_end) : (pos += 1) {
            if (units[pos] == needle) {
                self.cptr = pos;
                return true;
            }
        }
        return false;
    }

    inline fn scanGreedyClass8(
        self: *ExecState,
        comptime cbuf_type: CbufType,
        bitmap: [*]const u8,
        inverted: bool,
        min: u8,
        continuation_pc: [*]const u8,
    ) !bool {
        var count: usize = 0;
        var last_candidate: ?usize = if (min == 0) self.cptr else null;
        while (self.cptr < self.cbuf_end) {
            const before = self.cptr;
            const c = self.getCharUnchecked(cbuf_type);
            const matched = class8CodePointMatches(bitmap, c);
            if (if (inverted) matched else !matched) {
                self.cptr = before;
                break;
            }
            count += 1;
            if (count >= min) {
                const after = self.cptr;
                if (last_candidate) |candidate| {
                    self.cptr = candidate;
                    try self.pushExecState(continuation_pc, .split);
                    self.cptr = after;
                }
                last_candidate = after;
            }
            try self.s.pollTimeout();
        }
        if (last_candidate) |candidate| {
            self.cptr = candidate;
            return true;
        }
        return false;
    }

    inline fn matchRawForward(self: *ExecState, comptime cbuf_type: CbufType, start: usize, end: usize) bool {
        std.debug.assert(start <= end);
        const len = end - start;
        if (self.cptr > self.cbuf_end) return false;
        if (self.cbuf_end - self.cptr < len) return false;
        const input_start = self.cptr;
        const input_end = input_start + len;
        const matched = if (comptime cbuf_type == .latin1)
            std.mem.eql(u8, self.cbuf[start..end], self.cbuf[input_start..input_end])
        else
            std.mem.eql(u16, self.cbufUtf16()[start..end], self.cbufUtf16()[input_start..input_end]);
        if (!matched) return false;
        self.cptr = input_end;
        return true;
    }

    inline fn matchRawBackward(self: *ExecState, comptime cbuf_type: CbufType, start: usize, end: usize) bool {
        std.debug.assert(start <= end);
        const len = end - start;
        if (self.cptr < len) return false;
        const input_start = self.cptr - len;
        const matched = if (comptime cbuf_type == .latin1)
            std.mem.eql(u8, self.cbuf[start..end], self.cbuf[input_start..self.cptr])
        else
            std.mem.eql(u16, self.cbufUtf16()[start..end], self.cbufUtf16()[input_start..self.cptr]);
        if (!matched) return false;
        self.cptr = input_start;
        return true;
    }
};

fn lreExecBacktrack(
    comptime cbuf_type: CbufType,
    ctx: *REExecContext,
    capture: [*]usize,
    bytecode: []const u8,
    bytecode_end: usize,
    initial_pc: usize,
    initial_cptr: usize,
) !bool {
    var st = ExecState.init(ctx, capture, bytecode, bytecode_end, initial_pc, initial_cptr);

    main: while (true) {
        dispatch_once: {
            const opcode: REOPCodeEnum = @enumFromInt(st.getU8());
            switch (opcode) {
                .invalid => return error.BytecodeCorrupt,
                .match => return true,
                .lookahead_match => {
                    while (true) {
                        if (st.bt_len == 0) return error.BytecodeCorrupt;
                        const frame = st.popFrameKeepUndo();
                        if (ExecState.frameType(frame) == .lookahead) {
                            break;
                        }
                    }
                    continue :main;
                },
                .negative_lookahead_match => {
                    while (true) {
                        if (st.bt_len == 0) return error.BytecodeCorrupt;
                        const frame = st.popFrameRestore();
                        if (ExecState.frameType(frame) == .negative_lookahead) break;
                    }
                    break :dispatch_once;
                },
                .char32, .char32_i => {
                    const expected = st.getU32();
                    if (st.cptr >= st.cbuf_end) break :dispatch_once;
                    var c = st.getCharUnchecked(cbuf_type);
                    if (opcode == .char32_i) {
                        c = lreCanonicalize(c, st.s.is_unicode);
                    }
                    if (expected != @as(u32, c)) break :dispatch_once;
                    continue :main;
                },
                .char, .char_i => {
                    const expected: u32 = st.getU16();
                    if (st.cptr >= st.cbuf_end) break :dispatch_once;
                    var c = st.getCharUnchecked(cbuf_type);
                    if (opcode == .char_i) {
                        c = lreCanonicalize(c, st.s.is_unicode);
                    }
                    if (expected != @as(u32, c)) break :dispatch_once;
                    continue :main;
                },
                .split_goto_first, .split_next_first => {
                    const offset = st.getI32();
                    const pc1 = if (opcode == .split_next_first)
                        st.pcWithOffset(offset)
                    else
                        st.pc;
                    if (opcode == .split_goto_first) st.pc = st.pcWithOffset(offset);
                    try st.pushExecState(pc1, .split);
                    continue :main;
                },
                .lookahead, .negative_lookahead => {
                    const offset = st.getI32();
                    try st.pushExecState(st.pcWithOffset(offset), if (opcode == .lookahead) .lookahead else .negative_lookahead);
                    continue :main;
                },
                .goto_ => {
                    const offset = st.getI32();
                    st.pc = st.pcWithOffset(offset);
                    try st.s.pollTimeout();
                    continue :main;
                },
                .line_start, .line_start_m => {
                    if (st.cptr == 0) continue :main;
                    if (opcode == .line_start) break :dispatch_once;
                    const c = st.peekPrevChar(cbuf_type) orelse return error.BytecodeCorrupt;
                    if (!isLineTerminator(c)) break :dispatch_once;
                    continue :main;
                },
                .line_end, .line_end_m => {
                    if (st.cptr == st.cbuf_end) continue :main;
                    if (opcode == .line_end) break :dispatch_once;
                    const c = st.peekChar(cbuf_type) orelse return error.BytecodeCorrupt;
                    if (!isLineTerminator(c)) break :dispatch_once;
                    continue :main;
                },
                .dot => {
                    if (st.cptr >= st.cbuf_end) break :dispatch_once;
                    const c = st.getCharUnchecked(cbuf_type);
                    if (isLineTerminator(c)) break :dispatch_once;
                    continue :main;
                },
                .any => {
                    if (st.cptr >= st.cbuf_end) break :dispatch_once;
                    _ = st.getCharUnchecked(cbuf_type);
                    continue :main;
                },
                .space => {
                    if (st.cptr >= st.cbuf_end) break :dispatch_once;
                    const c = st.getCharUnchecked(cbuf_type);
                    if (!lreIsSpace(c)) break :dispatch_once;
                    continue :main;
                },
                .not_space => {
                    if (st.cptr >= st.cbuf_end) break :dispatch_once;
                    const c = st.getCharUnchecked(cbuf_type);
                    if (lreIsSpace(c)) break :dispatch_once;
                    continue :main;
                },
                .class8, .not_class8 => {
                    const bitmap = st.pc;
                    st.pc += class8_bitmap_len;
                    if (st.cptr >= st.cbuf_end) break :dispatch_once;
                    const c = st.getCharUnchecked(cbuf_type);
                    const matched = class8CodePointMatches(bitmap, c);
                    if (opcode == .class8) {
                        if (!matched) break :dispatch_once;
                    } else {
                        if (matched) break :dispatch_once;
                    }
                    continue :main;
                },
                .scan_until_char8 => {
                    const needle = st.getU8();
                    const offset = st.getI32();
                    if (!st.scanUntilChar8(cbuf_type, needle)) break :dispatch_once;
                    st.pc = st.pcWithOffset(offset);
                    continue :main;
                },
                .loop_class8_g, .loop_not_class8_g => {
                    const min = st.getU8();
                    if (min > 1) return error.BytecodeCorrupt;
                    const bitmap = st.pc;
                    st.pc += class8_bitmap_len;
                    if (!try st.scanGreedyClass8(cbuf_type, bitmap, opcode == .loop_not_class8_g, min, st.pc)) break :dispatch_once;
                    continue :main;
                },
                .save_start, .save_end => {
                    const val = st.getU8();
                    const idx = 2 * @as(usize, val) + @intFromEnum(opcode) - @intFromEnum(REOPCodeEnum.save_start);
                    try st.saveCapture(idx, st.cptr);
                    continue :main;
                },
                .save_reset => {
                    var first = st.readU8At(st.pc);
                    const last = st.readU8At(st.pc + 1);
                    st.pc += 2;
                    if (last >= st.s.capture_count or first > last) return error.BytecodeCorrupt;
                    const undo_count = (@as(usize, last) - @as(usize, first) + 1) * 2;
                    try st.checkUndoSpace(undo_count);
                    while (first <= last) : (first += 1) {
                        var slot = @as(usize, first) * 2;
                        st.pushUndoAssumeSpace(slot, no_slot_value);
                        slot += 1;
                        st.pushUndoAssumeSpace(slot, no_slot_value);
                    }
                    continue :main;
                },
                .set_i32 => {
                    const reg = st.readU8At(st.pc);
                    const value = st.readU32At(st.pc + 1);
                    st.pc += 5;
                    try st.saveCaptureCheck(st.registerSlot(reg), value);
                    continue :main;
                },
                .loop => {
                    const reg = st.readU8At(st.pc);
                    const offset: i32 = @bitCast(st.readU32At(st.pc + 1));
                    st.pc += 5;
                    const value = st.readRegisterValue(reg);
                    const next_value = value - 1;
                    try st.saveCaptureCheck(st.registerSlot(reg), next_value);
                    if (next_value != 0) {
                        st.pc = st.pcWithOffset(offset);
                        try st.s.pollTimeout();
                    }
                    continue :main;
                },
                .loop_split_goto_first, .loop_split_next_first, .loop_check_adv_split_goto_first, .loop_check_adv_split_next_first => {
                    const reg = st.readU8At(st.pc);
                    const limit = st.readU32At(st.pc + 1);
                    const offset: i32 = @bitCast(st.readU32At(st.pc + 5));
                    st.pc += 9;
                    const needs_advance_check = opcode == .loop_check_adv_split_goto_first or opcode == .loop_check_adv_split_next_first;
                    const value = st.readRegisterValue(reg);
                    const next_value = value - 1;
                    try st.saveCaptureCheck(st.registerSlot(reg), next_value);
                    if (next_value > limit) {
                        st.pc = st.pcWithOffset(offset);
                        try st.s.pollTimeout();
                    } else {
                        if (needs_advance_check and st.capture[st.registerSlot(@as(usize, reg) + 1)] == st.cptr and next_value != limit) {
                            break :dispatch_once;
                        }
                        if (next_value != 0) {
                            const pc1 = if (opcode == .loop_split_next_first or opcode == .loop_check_adv_split_next_first)
                                st.pcWithOffset(offset)
                            else
                                st.pc;
                            if (opcode == .loop_split_goto_first or opcode == .loop_check_adv_split_goto_first) st.pc = st.pcWithOffset(offset);
                            try st.pushExecState(pc1, .split);
                        }
                    }
                    continue :main;
                },
                .set_char_pos => {
                    const reg = st.readU8At(st.pc);
                    st.pc += 1;
                    try st.saveCaptureCheck(st.registerSlot(reg), st.cptr);
                    continue :main;
                },
                .check_advance => {
                    const reg = st.readU8At(st.pc);
                    st.pc += 1;
                    if (st.readRegisterValue(reg) == st.cptr) break :dispatch_once;
                    continue :main;
                },
                .word_boundary, .word_boundary_i, .not_word_boundary, .not_word_boundary_i => {
                    const ignore_case = opcode == .word_boundary_i or opcode == .not_word_boundary_i;
                    const is_boundary = opcode == .word_boundary or opcode == .word_boundary_i;
                    const before = before: {
                        if (st.cptr == 0) break :before false;
                        const c = st.peekPrevChar(cbuf_type) orelse return error.BytecodeCorrupt;
                        if (c < 256) break :before lreIsWordByte(@intCast(c));
                        break :before ignore_case and (c == 0x017f or c == 0x212a);
                    };
                    const after = after: {
                        if (st.cptr >= st.cbuf_end) break :after false;
                        const c = st.peekChar(cbuf_type) orelse return error.BytecodeCorrupt;
                        if (c < 256) break :after lreIsWordByte(@intCast(c));
                        break :after ignore_case and (c == 0x017f or c == 0x212a);
                    };
                    if ((before != after) != is_boundary) break :dispatch_once;
                    continue :main;
                },
                .back_reference, .back_reference_i, .backward_back_reference, .backward_back_reference_i => {
                    const n = st.getU8();
                    const pc1 = st.pc;
                    st.pc += @as(usize, n);

                    for (0..n) |i| {
                        const capture_index = pc1[i];
                        if (@as(usize, capture_index) >= st.s.capture_count) break :dispatch_once;
                        const capture_start = st.capture[@as(usize, capture_index) * 2];
                        const capture_end = st.capture[@as(usize, capture_index) * 2 + 1];
                        if (capture_start != no_slot_value and capture_end != no_slot_value) {
                            if (opcode == .back_reference) {
                                if (comptime cbuf_type == .utf16_unicode) {
                                    var capture_pos = capture_start;
                                    while (capture_pos < capture_end) {
                                        if (st.cptr >= st.cbuf_end) break :dispatch_once;
                                        const c1 = st.getCharAtBounded(cbuf_type, &capture_pos, capture_end);
                                        const c2 = st.getCharUnchecked(cbuf_type);
                                        if (c1 != c2) break :dispatch_once;
                                    }
                                } else if (!st.matchRawForward(cbuf_type, capture_start, capture_end)) break :dispatch_once;
                            } else if (opcode == .backward_back_reference) {
                                if (comptime cbuf_type == .utf16_unicode) {
                                    var capture_pos = capture_end;
                                    while (capture_pos > capture_start) {
                                        if (st.cptr == 0) break :dispatch_once;
                                        const c1 = st.getPrevCharAtBounded(cbuf_type, &capture_pos, capture_start);
                                        const c2 = st.getPrevCharAtBounded(cbuf_type, &st.cptr, 0);
                                        if (c1 != c2) break :dispatch_once;
                                    }
                                } else if (!st.matchRawBackward(cbuf_type, capture_start, capture_end)) break :dispatch_once;
                            } else if (opcode == .back_reference_i) {
                                var capture_pos = capture_start;
                                while (capture_pos < capture_end) {
                                    if (st.cptr >= st.cbuf_end) break :dispatch_once;
                                    var c1 = st.getCharAtBounded(cbuf_type, &capture_pos, capture_end);
                                    var c2_code = st.getCharUnchecked(cbuf_type);
                                    c1 = lreCanonicalize(c1, st.s.is_unicode);
                                    c2_code = lreCanonicalize(c2_code, st.s.is_unicode);
                                    if (c1 != c2_code) break :dispatch_once;
                                }
                            } else {
                                var capture_pos = capture_end;
                                while (capture_pos > capture_start) {
                                    if (st.cptr == 0) break :dispatch_once;
                                    var c1 = st.getPrevCharAtBounded(cbuf_type, &capture_pos, capture_start);
                                    var c2 = st.getPrevCharAtBounded(cbuf_type, &st.cptr, 0);
                                    c1 = lreCanonicalize(c1, st.s.is_unicode);
                                    c2 = lreCanonicalize(c2, st.s.is_unicode);
                                    if (c1 != c2) break :dispatch_once;
                                }
                            }
                            break;
                        }
                    }
                    continue :main;
                },
                .range, .range_i => {
                    const n = st.getU16();
                    if (n == 0) return error.BytecodeCorrupt;
                    range_match: {
                        if (st.cptr >= st.cbuf_end) break :dispatch_once;
                        var c = st.getCharUnchecked(cbuf_type);
                        if (opcode == .range_i) c = lreCanonicalize(c, st.s.is_unicode);
                        var idx_min: usize = 0;
                        var low = ExecState.readU16UncheckedAt(st.pc);
                        if (c < low) break :dispatch_once;
                        var idx_max: usize = n - 1;
                        var high = ExecState.readU16UncheckedAt(st.pc + idx_max * 4 + 2);
                        if (c >= 0xffff and high == 0xffff) break :range_match;
                        if (c > high) break :dispatch_once;
                        while (idx_min <= idx_max) {
                            const idx = (idx_min + idx_max) / 2;
                            low = ExecState.readU16UncheckedAt(st.pc + idx * 4);
                            high = ExecState.readU16UncheckedAt(st.pc + idx * 4 + 2);
                            if (c < low) {
                                if (idx == 0) break :dispatch_once;
                                idx_max = idx - 1;
                            } else if (c > high) {
                                idx_min = idx + 1;
                            } else {
                                break :range_match;
                            }
                        }
                        break :dispatch_once;
                    }
                    st.pc += @as(usize, n) * 4;
                    continue :main;
                },
                .range32, .range32_i => {
                    const n = st.getU16();
                    if (n == 0) return error.BytecodeCorrupt;
                    range32_match: {
                        if (st.cptr >= st.cbuf_end) break :dispatch_once;
                        var c = st.getCharUnchecked(cbuf_type);
                        if (opcode == .range32_i) c = lreCanonicalize(c, st.s.is_unicode);
                        var idx_min: usize = 0;
                        var low = ExecState.readU32UncheckedAt(st.pc);
                        if (c < low) break :dispatch_once;
                        var idx_max: usize = n - 1;
                        var high = ExecState.readU32UncheckedAt(st.pc + idx_max * 8 + 4);
                        if (c > high) break :dispatch_once;
                        while (idx_min <= idx_max) {
                            const idx = (idx_min + idx_max) / 2;
                            low = ExecState.readU32UncheckedAt(st.pc + idx * 8);
                            high = ExecState.readU32UncheckedAt(st.pc + idx * 8 + 4);
                            if (c < low) {
                                if (idx == 0) break :dispatch_once;
                                idx_max = idx - 1;
                            } else if (c > high) {
                                idx_min = idx + 1;
                            } else {
                                break :range32_match;
                            }
                        }
                        break :dispatch_once;
                    }
                    st.pc += @as(usize, n) * 8;
                    continue :main;
                },
                .prev => {
                    if (st.cptr == 0) break :dispatch_once;
                    try st.prevChar(cbuf_type);
                    continue :main;
                },
            }
            continue :main;
        }

        while (true) {
            if (st.bt_len == 0) return false;
            const frame = st.popFrameRestore();
            if (ExecState.frameType(frame) != .lookahead) break;
        }
        try st.s.pollTimeout();
        continue :main;
    }
}

//=== Exec output & header parse ===========================================

fn parseHeader(bytecode: []const u8) !REBytecodeHeader {
    if (bytecode.len < header_len) return error.BytecodeCorrupt;
    const bytecode_len = std.mem.readInt(u32, bytecode[re_header_bytecode_len..header_len], .little);
    if (header_len + bytecode_len > bytecode.len) return error.BytecodeCorrupt;
    return .{
        .flags = Flags.fromBits(std.mem.readInt(u16, bytecode[0..2], .little)),
        .capture_count = bytecode[re_header_capture_count],
        .register_count = bytecode[re_header_register_count],
        .bytecode_len = bytecode_len,
    };
}

fn parseHeaderTrusted(bytecode: []const u8) REBytecodeHeader {
    std.debug.assert(bytecode.len >= header_len);
    const bytecode_len = std.mem.readInt(u32, bytecode[re_header_bytecode_len..header_len], .little);
    std.debug.assert(header_len + bytecode_len <= bytecode.len);
    return .{
        .flags = Flags.fromBits(std.mem.readInt(u16, bytecode[0..2], .little)),
        .capture_count = bytecode[re_header_capture_count],
        .register_count = bytecode[re_header_register_count],
        .bytecode_len = bytecode_len,
    };
}

inline fn decodeOp(byte: u8) ?REOPCodeEnum {
    if (byte > @intFromEnum(REOPCodeEnum.loop_not_class8_g)) return null;
    return @enumFromInt(byte);
}

inline fn isLineTerminator(code_point: u21) bool {
    return code_point == '\n' or code_point == '\r' or code_point == 0x2028 or code_point == 0x2029;
}

inline fn lreIsSpaceByte(byte: u8) bool {
    return (lre_ctype_bits[byte] & lre_ctype_space) != 0;
}

inline fn lreIsSpace(code_point: u21) bool {
    if (code_point < 256) return lreIsSpaceByte(@intCast(code_point));
    return unicode.isEcmaWhitespaceOrLineTerminatorCodePoint(code_point);
}

inline fn isHiSurrogate(code_unit: u21) bool {
    return (code_unit >> 10) == (0xd800 >> 10);
}

inline fn isLoSurrogate(code_unit: u21) bool {
    return (code_unit >> 10) == (0xdc00 >> 10);
}

inline fn fromSurrogate(high: u16, low: u16) u21 {
    return 0x10000 + 0x400 * (@as(u21, high) - 0xd800) + (@as(u21, low) - 0xdc00);
}

const DecodedWtf8 = struct {
    code_point: u21,
    len: usize,
};

fn decodeWtf8Surrogate(bytes: []const u8, index: usize) ?DecodedWtf8 {
    if (index + 3 > bytes.len or bytes[index] != 0xed) return null;
    const second = bytes[index + 1];
    const third = bytes[index + 2];
    if (second < 0xa0 or second > 0xbf) return null;
    if (third < 0x80 or third > 0xbf) return null;
    const code_point: u21 =
        (@as(u21, bytes[index] & 0x0f) << 12) |
        (@as(u21, second & 0x3f) << 6) |
        @as(u21, third & 0x3f);
    return .{ .code_point = code_point, .len = 3 };
}

//=== Compiler =============================================================

pub const CompileError = std.mem.Allocator.Error || error{
    InvalidPattern,
    Unsupported,
    // qjs:libregexp.c re_parse_error(s, "stack overflow") — SyntaxError at JS wrappers
    StackOverflow,
};

pub const CompileOptions = struct {
    host: Host = .{},
};

const max_code_point: u21 = 0x10ffff;

const Atom = struct {
    start: usize,
    quantifiable: bool,
    capture_count_before: u8,
};

const ModifierGroup = struct {
    body_start: usize,
    add: [3]bool,
    remove: [3]bool,

    fn applyFlag(self: ModifierGroup, current: bool, flag: u8) bool {
        const slot = modifierFlagSlot(flag);
        if (self.add[slot]) return true;
        if (self.remove[slot]) return false;
        return current;
    }
};

fn parseModifierGroup(pattern: []const u8, start: usize) CompileError!?ModifierGroup {
    if (!startsWithAt(pattern, start, "(?")) return null;
    var pos = start + 2;
    if (pos >= pattern.len) return null;
    const first = pattern[pos];
    if (first != '-' and !isRegExpModifierFlag(first)) return null;

    var add: [3]bool = .{ false, false, false };
    var remove: [3]bool = .{ false, false, false };
    var saw_modifier = false;
    while (pos < pattern.len and isRegExpModifierFlag(pattern[pos])) : (pos += 1) {
        const slot = modifierFlagSlot(pattern[pos]);
        if (add[slot]) return error.InvalidPattern;
        add[slot] = true;
        saw_modifier = true;
    }
    if (pos < pattern.len and pattern[pos] == '-') {
        pos += 1;
        while (pos < pattern.len and isRegExpModifierFlag(pattern[pos])) : (pos += 1) {
            const slot = modifierFlagSlot(pattern[pos]);
            if (remove[slot]) return error.InvalidPattern;
            remove[slot] = true;
            saw_modifier = true;
        }
    }
    if (!saw_modifier) return error.InvalidPattern;
    if (pos >= pattern.len or pattern[pos] != ':') return error.InvalidPattern;
    for (0..add.len) |slot| {
        if (add[slot] and remove[slot]) return error.InvalidPattern;
    }
    return .{ .body_start = pos + 1, .add = add, .remove = remove };
}

fn startsWithAt(haystack: []const u8, index: usize, needle: []const u8) bool {
    return index <= haystack.len and haystack.len - index >= needle.len and std.mem.eql(u8, haystack[index..][0..needle.len], needle);
}

fn isRegExpModifierFlag(byte: u8) bool {
    return byte == 'i' or byte == 'm' or byte == 's';
}

fn modifierFlagSlot(byte: u8) usize {
    return switch (byte) {
        'i' => 0,
        'm' => 1,
        's' => 2,
        else => unreachable,
    };
}

const CharRange = unicode.CharRange;

const REClassAtom = union(enum) {
    code_point: u21,
    ranges: CharRange,
};

/// A v-mode class set: code points plus multi-code-point strings
/// (from `\q{...}`). Single-code-point string alternatives fold into
/// `ranges`; `strings` stays deduplicated and allocator-owned.
const REStringList = struct {
    ranges: CharRange,
    strings: std.ArrayList([]u21) = .empty,

    fn init(allocator: std.mem.Allocator) REStringList {
        return .{ .ranges = CharRange.init(allocator) };
    }

    fn deinit(self: *REStringList) void {
        for (self.strings.items) |s| self.ranges.allocator.free(s);
        self.strings.deinit(self.ranges.allocator);
        self.ranges.deinit();
    }

    fn containsString(self: *const REStringList, needle: []const u21) bool {
        for (self.strings.items) |s| {
            if (std.mem.eql(u21, s, needle)) return true;
        }
        return false;
    }

    /// Takes ownership of `s` (frees it when already present).
    fn addOwnedString(self: *REStringList, s: []u21) !void {
        if (self.containsString(s)) {
            self.ranges.allocator.free(s);
            return;
        }
        try array_list_erased.append(&self.strings, self.ranges.allocator, s);
    }

    fn unionWith(self: *REStringList, other: *const REStringList) !void {
        try self.ranges.addSet(&other.ranges);
        for (other.strings.items) |s| {
            if (self.containsString(s)) continue;
            const copy = try self.ranges.allocator.dupe(u21, s);
            errdefer self.ranges.allocator.free(copy);
            try array_list_erased.append(&self.strings, self.ranges.allocator, copy);
        }
    }

    fn intersectWith(self: *REStringList, other: *REStringList) !void {
        try self.ranges.intersectWith(&other.ranges);
        var write: usize = 0;
        for (self.strings.items) |s| {
            if (other.containsString(s)) {
                self.strings.items[write] = s;
                write += 1;
            } else {
                self.ranges.allocator.free(s);
            }
        }
        self.strings.shrinkRetainingCapacity(write);
    }

    fn subtract(self: *REStringList, other: *REStringList) !void {
        try self.ranges.subWith(&other.ranges);
        var write: usize = 0;
        for (self.strings.items) |s| {
            if (!other.containsString(s)) {
                self.strings.items[write] = s;
                write += 1;
            } else {
                self.ranges.allocator.free(s);
            }
        }
        self.strings.shrinkRetainingCapacity(write);
    }
};

const REStringListOperandResult = struct { set: REStringList, was_range: bool };

const REStringListBuildContext = struct {
    s: *REParseState,
    set: *REStringList,
};

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, flags_str: []const u8) CompileError![]u8 {
    return compileWithOptions(allocator, pattern, flags_str, .{});
}

pub fn compileWithOptions(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    flags_str: []const u8,
    options: CompileOptions,
) CompileError![]u8 {
    return compileWithFlagsAndOptions(allocator, pattern, try Flags.parse(flags_str), options);
}

pub fn compileWithFlagsAndOptions(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    re_flags: Flags,
    options: CompileOptions,
) CompileError![]u8 {
    var s = REParseState{
        .allocator = allocator,
        .byte_code = .empty,
        .buf_start = pattern,
        .buf_end = pattern.len,
        .re_flags = re_flags,
        .is_unicode = re_flags.fullUnicode(),
        .unicode_sets = re_flags.unicode_sets,
        .ignore_case = re_flags.ignore_case,
        .multi_line = re_flags.multiline,
        .dotall = re_flags.dot_all,
        .host = options.host,
    };
    errdefer s.byte_code.deinit(allocator);
    defer s.group_names.deinit(allocator);

    try s.emitHeader();
    if (!re_flags.sticky) {
        try s.reEmitOpI32(.split_goto_first, 6);
        try s.reEmitOp(.any);
        try s.reEmitOpI32(.goto_, -11);
    }
    try s.reEmitOpU8(.save_start, 0);
    try s.reParseDisjunction(null, false);
    if (s.buf_ptr != pattern.len) return error.InvalidPattern;
    try s.reEmitOpU8(.save_end, 0);
    try s.reEmitOp(.match);
    s.patchSearchLiteralPrefix();
    try s.patchHeader();

    return try s.byte_code.toOwnedSlice(allocator);
}

fn parseGroupNameAt(pattern: []const u8, index: *usize) CompileError![]const u8 {
    const start = index.*;
    if (start >= pattern.len) return error.InvalidPattern;
    var position: usize = 0;
    while (index.* < pattern.len and pattern[index.*] != '>') : (position += 1) {
        const cp = try readGroupNameCodePoint(pattern, index);
        if (position == 0) {
            if (!isRegExpGroupNameStart(cp)) return error.InvalidPattern;
        } else if (!isRegExpGroupNameContinue(cp)) {
            return error.InvalidPattern;
        }
    }
    if (index.* == start or index.* >= pattern.len or pattern[index.*] != '>') return error.InvalidPattern;
    const name = pattern[start..index.*];
    index.* += 1;
    return name;
}

fn groupNamesEqual(lhs: []const u8, rhs: []const u8) bool {
    var lhs_index: usize = 0;
    var rhs_index: usize = 0;
    while (lhs_index < lhs.len and rhs_index < rhs.len) {
        const lhs_cp = readGroupNameCodePoint(lhs, &lhs_index) catch return false;
        const rhs_cp = readGroupNameCodePoint(rhs, &rhs_index) catch return false;
        if (lhs_cp != rhs_cp) return false;
    }
    return lhs_index == lhs.len and rhs_index == rhs.len;
}

fn readGroupNameCodePoint(pattern: []const u8, index: *usize) CompileError!u21 {
    if (index.* >= pattern.len) return error.InvalidPattern;
    if (pattern[index.*] == '\\') {
        const first = try readUnicodeEscapeCodePoint(pattern, index);
        if (isHiSurrogate(first)) {
            const saved = index.*;
            if (readUnicodeEscapeCodePoint(pattern, index)) |second| {
                if (isLoSurrogate(second)) return fromSurrogate(@intCast(first), @intCast(second));
            } else |_| {}
            index.* = saved;
        }
        if (first > max_code_point) return error.InvalidPattern;
        return first;
    }
    // qjs:libregexp.c — unicode_from_utf8 then unconditionally recombine
    // a following low surrogate. CESU-8 / WTF-8 hi/lo halves must decode first
    // (std.unicode.utf8Decode rejects them) so non-u `new RegExp` sources work.
    const first = try readGroupNameLiteralCodePoint(pattern, index);
    if (isHiSurrogate(first)) {
        const saved = index.*;
        if (readGroupNameLiteralCodePoint(pattern, index)) |second| {
            if (isLoSurrogate(second)) return fromSurrogate(@intCast(first), @intCast(second));
        } else |_| {}
        index.* = saved;
    }
    if (first > max_code_point) return error.InvalidPattern;
    return first;
}

fn readGroupNameLiteralCodePoint(pattern: []const u8, index: *usize) CompileError!u21 {
    if (index.* >= pattern.len) return error.InvalidPattern;
    if (decodeWtf8Surrogate(pattern, index.*)) |decoded| {
        index.* += decoded.len;
        return decoded.code_point;
    }
    const byte = pattern[index.*];
    const width = std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidPattern;
    if (index.* + width > pattern.len) return error.InvalidPattern;
    const cp = std.unicode.utf8Decode(pattern[index.* .. index.* + width]) catch return error.InvalidPattern;
    if (cp > max_code_point) return error.InvalidPattern;
    index.* += width;
    return @intCast(cp);
}

fn readUnicodeEscapeCodePoint(pattern: []const u8, index: *usize) CompileError!u21 {
    if (index.* + 2 > pattern.len or pattern[index.*] != '\\' or pattern[index.* + 1] != 'u') return error.InvalidPattern;
    var pos = index.* + 2;
    if (pos < pattern.len and pattern[pos] == '{') {
        pos += 1;
        var value: u21 = 0;
        var saw_digit = false;
        while (pos < pattern.len and pattern[pos] != '}') : (pos += 1) {
            const digit = fromHex(pattern[pos]) orelse return error.InvalidPattern;
            if (value > max_code_point / 16) return error.InvalidPattern;
            value = value * 16 + digit;
            if (value > max_code_point) return error.InvalidPattern;
            saw_digit = true;
        }
        if (!saw_digit or pos >= pattern.len or pattern[pos] != '}') return error.InvalidPattern;
        index.* = pos + 1;
        return value;
    }
    if (pos + 4 > pattern.len) return error.InvalidPattern;
    var value: u21 = 0;
    var count: usize = 0;
    while (count < 4) : (count += 1) {
        value = value * 16 + (fromHex(pattern[pos + count]) orelse return error.InvalidPattern);
    }
    index.* = pos + 4;
    return value;
}

fn isRegExpGroupNameStart(cp: u21) bool {
    if (cp == '$' or cp == '_') return true;
    if (unicode.isAsciiAlphaCodePoint(cp)) return true;
    if (isInvalidRegExpGroupNameStart(cp)) return false;
    return cp > 0x7f;
}

fn isRegExpGroupNameContinue(cp: u21) bool {
    if (isInvalidRegExpGroupNameContinue(cp)) return false;
    if (cp == 0x104a4) return true;
    if (isRegExpGroupNameStart(cp)) return true;
    if (unicode.isAsciiDigitCodePoint(cp)) return true;
    if (cp == 0x1d7da) return true;
    return false;
}

fn isInvalidRegExpGroupNameStart(cp: u21) bool {
    if (unicode.isSurrogateCodePoint(cp)) return true;
    return switch (cp) {
        0x275e, 0x2764, 0x104a4, 0x1d7da, 0x1f08b, 0x1f415, 0x1f712, 0x1f98a, 0x10ffff => true,
        else => false,
    };
}

fn isInvalidRegExpGroupNameContinue(cp: u21) bool {
    if (unicode.isSurrogateCodePoint(cp)) return true;
    return switch (cp) {
        0x275e, 0x2764, 0x1f08b, 0x1f415, 0x1f712, 0x1f98a, 0x10ffff => true,
        else => false,
    };
}

//=== Parser state =========================================================

const REParseState = struct {
    allocator: std.mem.Allocator,
    byte_code: std.ArrayList(u8),
    buf_ptr: usize = 0,
    buf_end: usize,
    buf_start: []const u8,
    re_flags: Flags,
    is_unicode: bool,
    unicode_sets: bool,
    ignore_case: bool,
    multi_line: bool,
    dotall: bool,
    group_name_scope: u8 = 0,
    capture_count: u8 = 1,
    /// Whole-pattern capture census, computed lazily by `reCountCaptures`.
    capture_census: ?CaptureParseResult = null,
    /// A named group has been emitted; known before the census runs.
    saw_named_group: bool = false,
    host: Host = .{},
    group_names: std.ArrayList(u8) = .empty,

    fn lreCheckStackOverflow(self: *const REParseState, alloca_size: usize) bool {
        return self.host.stackOverflows(alloca_size);
    }

    fn atomResult(self: *const REParseState, start: usize, quantifiable: bool) Atom {
        return .{ .start = start, .quantifiable = quantifiable, .capture_count_before = self.capture_count };
    }

    //--- group name storage ---

    const CaptureParseResult = struct {
        count: u16,
        has_named_captures: bool,
    };

    fn putGroupName(self: *REParseState, maybe_name: ?[]const u8) CompileError!void {
        if (maybe_name) |name| {
            try self.group_names.appendSlice(self.allocator, name);
            try self.group_names.append(self.allocator, 0);
            try self.group_names.append(self.allocator, self.group_name_scope);
            self.saw_named_group = true;
            return;
        }
        try self.group_names.append(self.allocator, 0);
        try self.group_names.append(self.allocator, 0);
    }

    fn isDuplicateGroupName(self: *const REParseState, name: []const u8, scope: u8) bool {
        var pos: usize = 0;
        while (pos < self.group_names.items.len) {
            const end = std.mem.indexOfScalarPos(u8, self.group_names.items, pos, 0) orelse return false;
            if (end + 1 >= self.group_names.items.len) return false;
            if (groupNamesEqual(self.group_names.items[pos..end], name) and self.group_names.items[end + 1] == scope) return true;
            pos = end + group_name_trailer_len;
        }
        return false;
    }

    fn findGroupName(self: *REParseState, name: []const u8, emit_group_index: bool) CompileError!u16 {
        var pos: usize = 0;
        var capture_index: u16 = 1;
        var count: u16 = 0;
        while (pos < self.group_names.items.len) : (capture_index += 1) {
            const end = std.mem.indexOfScalarPos(u8, self.group_names.items, pos, 0) orelse return error.InvalidPattern;
            if (end + 1 >= self.group_names.items.len) return error.InvalidPattern;
            if (groupNamesEqual(self.group_names.items[pos..end], name)) {
                if (emit_group_index) try self.byte_code.append(self.allocator, @intCast(capture_index));
                count += 1;
            }
            pos = end + group_name_trailer_len;
        }
        return count;
    }

    fn reParseCaptures(self: *REParseState, capture_name: ?[]const u8, emit_group_index: bool) CompileError!CaptureParseResult {
        var capture_index: u16 = 1;
        var count: u16 = 0;
        var has_named = false;
        var pos: usize = 0;
        while (pos < self.buf_end) : (pos += 1) {
            switch (self.buf_start[pos]) {
                '\\' => {
                    if (pos + 1 < self.buf_end) pos += 1;
                },
                '[' => {
                    pos += 1;
                    if (pos < self.buf_end and self.buf_start[pos] == ']') pos += 1;
                    while (pos < self.buf_end and self.buf_start[pos] != ']') : (pos += 1) {
                        if (self.buf_start[pos] == '\\' and pos + 1 < self.buf_end) pos += 1;
                    }
                },
                '(' => {
                    if (pos + 1 < self.buf_end and self.buf_start[pos + 1] == '?') {
                        if (pos + 2 >= self.buf_end) continue;
                        switch (self.buf_start[pos + 2]) {
                            ':', '=', '!' => continue,
                            '<' => {
                                if (pos + 3 < self.buf_end and (self.buf_start[pos + 3] == '=' or self.buf_start[pos + 3] == '!')) continue;
                                has_named = true;
                                if (capture_name) |needle| {
                                    var name_index = pos + 3;
                                    if (parseGroupNameAt(self.buf_start, &name_index)) |name| {
                                        if (groupNamesEqual(name, needle)) {
                                            if (emit_group_index) try self.byte_code.append(self.allocator, @intCast(capture_index));
                                            count += 1;
                                        }
                                    } else |_| {}
                                }
                            },
                            else => continue,
                        }
                    }
                    capture_index += 1;
                    if (capture_index >= max_captures) break;
                },
                else => {},
            }
        }
        return .{
            .count = if (capture_name == null) capture_index else count,
            .has_named_captures = has_named,
        };
    }

    fn captureCensus(self: *REParseState) CompileError!CaptureParseResult {
        if (self.capture_census == null) self.capture_census = try self.reParseCaptures(null, false);
        return self.capture_census.?;
    }

    fn reCountCaptures(self: *REParseState) CompileError!u16 {
        return (try self.captureCensus()).count;
    }

    fn reHasNamedCaptures(self: *REParseState) CompileError!bool {
        if (self.saw_named_group) return true;
        return (try self.captureCensus()).has_named_captures;
    }

    //--- header emit / patch ---

    fn emitHeader(self: *REParseState) !void {
        try self.byte_code.appendNTimes(self.allocator, 0, header_len);
    }

    fn patchHeader(self: *REParseState) !void {
        const bytecode_len = self.byte_code.items.len - header_len;
        const stack_size = try reComputeRegisterCount(self.byte_code.items[header_len..]);
        const has_named_groups = self.group_names.items.len > @as(usize, self.capture_count - 1) * group_name_trailer_len;
        if (has_named_groups) try self.byte_code.appendSlice(self.allocator, self.group_names.items);
        var header_flags = self.re_flags;
        header_flags.named_groups = has_named_groups;
        std.mem.writeInt(u16, self.byte_code.items[0..2], header_flags.bits(), .little);
        self.byte_code.items[2] = self.capture_count;
        self.byte_code.items[3] = stack_size;
        std.mem.writeInt(u32, self.byte_code.items[4..8], @intCast(bytecode_len), .little);
    }

    fn patchSearchLiteralPrefix(self: *REParseState) void {
        if (self.re_flags.sticky) return;
        const prelude = header_len;
        const pattern_start = prelude + 11;
        const first_atom = pattern_start + 2;
        const code = self.byte_code.items;
        if (code.len < first_atom + 3) return;
        if (code[prelude] != opByte(.split_goto_first)) return;
        if (std.mem.readInt(u32, code[prelude + 1 ..][0..4], .little) != 6) return;
        if (code[prelude + 5] != opByte(.any)) return;
        if (code[prelude + 6] != opByte(.goto_)) return;
        if (@as(i32, @bitCast(std.mem.readInt(u32, code[prelude + 7 ..][0..4], .little))) != -11) return;
        if (code[pattern_start] != opByte(.save_start) or code[pattern_start + 1] != 0) return;
        if (code[first_atom] != opByte(.char)) return;

        const needle_u16 = std.mem.readInt(u16, code[first_atom + 1 ..][0..2], .little);
        if (needle_u16 > 0xff) return;
        // Only the two bytes of the `any` + `goto_` pair change: `scan_until_char8`
        // takes the literal as its operand and keeps the same instruction width,
        // so the -11 branch displacement at `prelude + 7` (already asserted above)
        // stays valid and is deliberately left untouched.
        code[prelude + 5] = opByte(.scan_until_char8);
        code[prelude + 6] = @intCast(needle_u16);
    }

    //--- top-level parse dispatch ---

    fn reParseDisjunction(self: *REParseState, terminator: ?u8, is_backward_dir: bool) CompileError!void {
        // qjs:libregexp.c — one native-stack check per recursive disjunction entry
        if (self.lreCheckStackOverflow(0)) return error.StackOverflow;
        const start = self.byte_code.items.len;
        try self.reParseAlternative(terminator, is_backward_dir);
        while (self.buf_ptr < self.buf_start.len and self.buf_start[self.buf_ptr] == '|') {
            self.buf_ptr += 1;
            const previous_len = self.byte_code.items.len - start;
            try self.insertBytes(start, 5);
            self.byte_code.items[start] = opByte(.split_next_first);
            std.mem.writeInt(u32, self.byte_code.items[start + 1 ..][0..4], @intCast(previous_len + 5), .little);

            const goto_pos = try self.reEmitOpU32At(.goto_, 0);
            self.group_name_scope +%= 1;
            try self.reParseAlternative(terminator, is_backward_dir);
            std.mem.writeInt(u32, self.byte_code.items[goto_pos..][0..4], @intCast(self.byte_code.items.len - (goto_pos + 4)), .little);
        }
        if (terminator) |end| {
            if (self.buf_ptr >= self.buf_start.len or self.buf_start[self.buf_ptr] != end) return error.InvalidPattern;
            self.buf_ptr += 1;
        }
    }

    fn reParseAlternative(self: *REParseState, terminator: ?u8, is_backward_dir: bool) CompileError!void {
        const start = self.byte_code.items.len;
        while (self.buf_ptr < self.buf_start.len) {
            const byte = self.buf_start[self.buf_ptr];
            if (terminator) |end| {
                if (byte == end) return;
            }
            if (byte == '|') return;
            if (byte == ')') return error.InvalidPattern;
            const term_start = self.byte_code.items.len;
            const atom = try self.reParseTerm(is_backward_dir);
            try self.parseQuantifier(atom);
            if (is_backward_dir) try self.moveTermToStart(start, term_start, self.byte_code.items.len);
        }
    }

    fn reParseTerm(self: *REParseState, is_backward_dir: bool) CompileError!Atom {
        if (self.buf_ptr >= self.buf_start.len) return error.InvalidPattern;
        const start = self.byte_code.items.len;
        const capture_count_before = self.capture_count;
        const byte = self.buf_start[self.buf_ptr];
        switch (byte) {
            '^' => {
                self.buf_ptr += 1;
                try self.reEmitOp(if (self.multi_line) .line_start_m else .line_start);
                return .{ .start = start, .quantifiable = false, .capture_count_before = capture_count_before };
            },
            '$' => {
                self.buf_ptr += 1;
                try self.reEmitOp(if (self.multi_line) .line_end_m else .line_end);
                return .{ .start = start, .quantifiable = false, .capture_count_before = capture_count_before };
            },
            '.' => {
                self.buf_ptr += 1;
                try self.emitDirectional(if (self.dotall) .any else .dot, is_backward_dir);
                return .{ .start = start, .quantifiable = true, .capture_count_before = capture_count_before };
            },
            '*', '+', '?' => return error.InvalidPattern,
            '{' => {
                if (self.is_unicode or self.looksLikeQuantifier(self.buf_ptr)) return error.InvalidPattern;
                self.buf_ptr += 1;
                try self.emitCharacterAtom('{', is_backward_dir);
                return .{ .start = start, .quantifiable = true, .capture_count_before = capture_count_before };
            },
            '(' => return self.parseGroup(start, is_backward_dir),
            '[' => return self.reParseCharClass(start, is_backward_dir),
            '\\' => return self.parseEscape(start, is_backward_dir),
            ']', '}' => {
                if (self.is_unicode) return error.InvalidPattern;
                self.buf_ptr += 1;
                try self.emitCharacterAtom(byte, is_backward_dir);
                return .{ .start = start, .quantifiable = true, .capture_count_before = capture_count_before };
            },
            else => {
                const cp = try self.readPatternCodePoint();
                if (cp > 0xffff and !self.is_unicode) {
                    const quant_start = try self.emitNonUnicodeSurrogatePairTerms(cp, is_backward_dir);
                    return .{ .start = quant_start, .quantifiable = true, .capture_count_before = capture_count_before };
                }
                try self.emitCanonicalChar(cp, is_backward_dir);
                return .{ .start = start, .quantifiable = true, .capture_count_before = capture_count_before };
            },
        }
    }

    fn parseGroup(self: *REParseState, start: usize, is_backward_dir: bool) CompileError!Atom {
        std.debug.assert(self.buf_start[self.buf_ptr] == '(');
        const capture_count_before = self.capture_count;
        if (self.buf_ptr + 1 < self.buf_start.len and self.buf_start[self.buf_ptr + 1] == '?') {
            if (self.buf_ptr + 2 < self.buf_start.len and self.buf_start[self.buf_ptr + 2] == ':') {
                self.buf_ptr += 3;
                try self.reParseDisjunction(')', is_backward_dir);
                return .{ .start = start, .quantifiable = true, .capture_count_before = capture_count_before };
            }
            if (try parseModifierGroup(self.buf_start, self.buf_ptr)) |modifier_group| {
                self.buf_ptr = modifier_group.body_start;
                const saved_ignore_case = self.ignore_case;
                const saved_multi_line = self.multi_line;
                const saved_dotall = self.dotall;
                self.ignore_case = modifier_group.applyFlag(saved_ignore_case, 'i');
                self.multi_line = modifier_group.applyFlag(saved_multi_line, 'm');
                self.dotall = modifier_group.applyFlag(saved_dotall, 's');
                defer {
                    self.ignore_case = saved_ignore_case;
                    self.multi_line = saved_multi_line;
                    self.dotall = saved_dotall;
                }
                try self.reParseDisjunction(')', is_backward_dir);
                return .{ .start = start, .quantifiable = true, .capture_count_before = capture_count_before };
            }
            if (self.buf_ptr + 2 < self.buf_start.len and (self.buf_start[self.buf_ptr + 2] == '=' or self.buf_start[self.buf_ptr + 2] == '!')) {
                const negative = self.buf_start[self.buf_ptr + 2] == '!';
                self.buf_ptr += 3;
                const offset_pos = try self.reEmitOpU32At(if (negative) .negative_lookahead else .lookahead, 0);
                try self.reParseDisjunction(')', false);
                try self.reEmitOp(if (negative) .negative_lookahead_match else .lookahead_match);
                std.mem.writeInt(u32, self.byte_code.items[offset_pos..][0..4], @intCast(self.byte_code.items.len - (offset_pos + 4)), .little);
                return .{ .start = start, .quantifiable = !self.is_unicode, .capture_count_before = capture_count_before };
            }
            if (self.buf_ptr + 3 < self.buf_start.len and self.buf_start[self.buf_ptr + 2] == '<' and
                (self.buf_start[self.buf_ptr + 3] == '=' or self.buf_start[self.buf_ptr + 3] == '!'))
            {
                const negative = self.buf_start[self.buf_ptr + 3] == '!';
                self.buf_ptr += 4;
                const offset_pos = try self.reEmitOpU32At(if (negative) .negative_lookahead else .lookahead, 0);
                try self.reParseDisjunction(')', true);
                try self.reEmitOp(if (negative) .negative_lookahead_match else .lookahead_match);
                std.mem.writeInt(u32, self.byte_code.items[offset_pos..][0..4], @intCast(self.byte_code.items.len - (offset_pos + 4)), .little);
                return .{ .start = start, .quantifiable = false, .capture_count_before = capture_count_before };
            }
            if (self.buf_ptr + 2 < self.buf_start.len and self.buf_start[self.buf_ptr + 2] == '<') {
                self.buf_ptr += 3;
                const name = try self.parseGroupName();
                return try self.parseCaptureGroup(start, name, is_backward_dir);
            }
            return error.Unsupported;
        }
        self.buf_ptr += 1;
        return try self.parseCaptureGroup(start, null, is_backward_dir);
    }

    fn parseCaptureGroup(self: *REParseState, start: usize, maybe_name: ?[]const u8, is_backward_dir: bool) CompileError!Atom {
        if (self.capture_count == 255) return error.InvalidPattern;
        const capture_index = self.capture_count;
        self.capture_count += 1;
        if (maybe_name) |name| {
            if (self.isDuplicateGroupName(name, self.group_name_scope)) return error.InvalidPattern;
        }
        try self.putGroupName(maybe_name);
        try self.reEmitOpU8(if (is_backward_dir) .save_end else .save_start, capture_index);
        try self.reParseDisjunction(')', is_backward_dir);
        try self.reEmitOpU8(if (is_backward_dir) .save_start else .save_end, capture_index);
        return .{ .start = start, .quantifiable = true, .capture_count_before = capture_index };
    }

    //--- escape parsing ---

    fn parseEscape(self: *REParseState, start: usize, is_backward_dir: bool) CompileError!Atom {
        std.debug.assert(self.buf_start[self.buf_ptr] == '\\');
        if (self.buf_ptr + 1 >= self.buf_start.len) return error.InvalidPattern;
        const escaped = self.buf_start[self.buf_ptr + 1];
        switch (escaped) {
            'b', 'B' => {
                self.buf_ptr += 2;
                const op: REOPCodeEnum = if (self.ignore_case and self.is_unicode)
                    if (escaped == 'b') .word_boundary_i else .not_word_boundary_i
                else if (escaped == 'b')
                    .word_boundary
                else
                    .not_word_boundary;
                try self.reEmitOp(op);
                return self.atomResult(start, false);
            },
            's', 'S' => {
                self.buf_ptr += 2;
                try self.emitDirectional(if (escaped == 's') .space else .not_space, is_backward_dir);
                return self.atomResult(start, true);
            },
            'd', 'D', 'w', 'W' => {
                self.buf_ptr += 2;
                var ranges = CharRange.init(self.allocator);
                defer ranges.deinit();
                try addClassEscape(&ranges, escaped);
                try self.emitDirectionalRange(&ranges, is_backward_dir);
                return self.atomResult(start, true);
            },
            '1'...'9' => {
                const escape_start = self.buf_ptr;
                const capture_index = try self.parseDecimalEscape();
                if (capture_index == 0 or capture_index >= try self.reCountCaptures()) {
                    if (self.is_unicode) return error.InvalidPattern;
                    self.buf_ptr = escape_start + 1;
                    const cp = try self.parseLegacyDecimalEscape();
                    try self.emitCanonicalChar(cp, is_backward_dir);
                    return self.atomResult(start, true);
                }
                try self.emitBackReference(is_backward_dir, &.{@intCast(capture_index)});
                return self.atomResult(start, true);
            },
            '0' => {
                self.buf_ptr += 2;
                if (self.buf_ptr < self.buf_start.len and isDigit(self.buf_start[self.buf_ptr]) and self.is_unicode) return error.InvalidPattern;
                const cp = try self.parseLegacyOctalAfterZero();
                try self.emitCanonicalChar(cp, is_backward_dir);
                return self.atomResult(start, true);
            },
            'x' => {
                const escape_start = self.buf_ptr;
                const cp = self.parseFixedHexEscape(2) catch |err| {
                    self.buf_ptr = escape_start;
                    if (self.is_unicode) return err;
                    self.buf_ptr += 2;
                    try self.emitCanonicalChar('x', is_backward_dir);
                    return self.atomResult(start, true);
                };
                try self.emitCanonicalChar(cp, is_backward_dir);
                return self.atomResult(start, true);
            },
            'u' => {
                const escape_start = self.buf_ptr;
                const braced = self.isBracedUnicodeEscape();
                const cp = self.parseUnicodeEscape() catch |err| {
                    self.buf_ptr = escape_start;
                    if (self.is_unicode) return err;
                    self.buf_ptr += 2;
                    try self.emitCanonicalChar('u', is_backward_dir);
                    return self.atomResult(start, true);
                };
                const combined = if (braced) cp else try self.combineEscapedSurrogatePair(cp);
                try self.emitCanonicalChar(combined, is_backward_dir);
                return self.atomResult(start, true);
            },
            'c' => {
                if (self.buf_ptr + 2 >= self.buf_start.len) {
                    if (self.is_unicode) return error.InvalidPattern;
                    try self.emitInvalidControlEscape(is_backward_dir);
                    return self.atomResult(start, true);
                }
                const cp_byte = self.buf_start[self.buf_ptr + 2];
                if (!((cp_byte >= 'a' and cp_byte <= 'z') or (cp_byte >= 'A' and cp_byte <= 'Z'))) {
                    if (self.is_unicode) return error.InvalidPattern;
                    try self.emitInvalidControlEscape(is_backward_dir);
                    return self.atomResult(start, true);
                }
                const cp: u21 = cp_byte & 0x1f;
                self.buf_ptr += 3;
                try self.emitCanonicalChar(cp, is_backward_dir);
                return self.atomResult(start, true);
            },
            'f', 'n', 'r', 't', 'v' => {
                self.buf_ptr += 2;
                const cp: u21 = switch (escaped) {
                    'f' => 0x0c,
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    'v' => 0x0b,
                    else => unreachable,
                };
                try self.emitCanonicalChar(cp, is_backward_dir);
                return self.atomResult(start, true);
            },
            'p', 'P' => {
                if (!self.is_unicode) {
                    self.buf_ptr += 2;
                    try self.emitCanonicalChar(escaped, is_backward_dir);
                    return self.atomResult(start, true);
                }
                if (self.unicode_sets) {
                    if (try self.parseStringPropertyEscape()) |string_set| {
                        var set = string_set;
                        defer set.deinit();
                        try self.reEmitStringList(&set, is_backward_dir);
                        return self.atomResult(start, true);
                    }
                }
                const inverted = escaped == 'P';
                var ranges = try self.parseUnicodePropertyEscape();
                defer ranges.deinit();
                if (self.ignore_case and self.unicode_sets) {
                    try ranges.regexpCanonicalize(self.is_unicode);
                }
                if (inverted) try ranges.invert();
                if (self.ignore_case and !self.unicode_sets) {
                    try ranges.regexpCanonicalize(self.is_unicode);
                }
                try self.emitDirectionalRange(&ranges, is_backward_dir);
                return self.atomResult(start, true);
            },
            'k' => {
                const escape_start = self.buf_ptr;
                if (self.buf_ptr + 2 >= self.buf_start.len or self.buf_start[self.buf_ptr + 2] != '<') {
                    if (self.is_unicode or try self.reHasNamedCaptures()) return error.InvalidPattern;
                    self.buf_ptr += 2;
                    try self.emitCanonicalChar('k', is_backward_dir);
                    return self.atomResult(start, true);
                }
                self.buf_ptr += 3;
                const name = self.parseGroupName() catch |err| {
                    if (self.is_unicode or try self.reHasNamedCaptures()) return err;
                    self.buf_ptr = escape_start + 2;
                    try self.emitCanonicalChar('k', is_backward_dir);
                    return self.atomResult(start, true);
                };
                var is_forward = false;
                var capture_count = try self.findGroupName(name, false);
                if (capture_count == 0) {
                    const parsed = try self.reParseCaptures(name, false);
                    capture_count = parsed.count;
                    if (capture_count == 0) {
                        if (self.is_unicode or try self.reHasNamedCaptures()) return error.InvalidPattern;
                        self.buf_ptr = escape_start + 2;
                        try self.emitCanonicalChar('k', is_backward_dir);
                        return self.atomResult(start, true);
                    }
                    is_forward = true;
                }
                try self.reEmitOpU8(self.backReferenceOp(is_backward_dir), @intCast(capture_count));
                if (is_forward) {
                    _ = try self.reParseCaptures(name, true);
                } else {
                    _ = try self.findGroupName(name, true);
                }
                return self.atomResult(start, true);
            },
            else => {
                if (escaped >= 0x80) {
                    if (self.is_unicode) return error.InvalidPattern;
                    self.buf_ptr += 1;
                    const cp = try self.readUtf8CodePoint();
                    if (cp > 0xffff) {
                        const quant_start = try self.emitNonUnicodeSurrogatePairTerms(cp, is_backward_dir);
                        return .{ .start = quant_start, .quantifiable = true, .capture_count_before = self.capture_count };
                    }
                    try self.emitCanonicalChar(cp, is_backward_dir);
                    return self.atomResult(start, true);
                }
                if (isSyntaxEscape(escaped) or escaped == '/') {
                    self.buf_ptr += 2;
                    try self.emitCanonicalChar(escaped, is_backward_dir);
                    return self.atomResult(start, true);
                }
                if (self.is_unicode) return error.InvalidPattern;
                self.buf_ptr += 2;
                try self.emitCanonicalChar(escaped, is_backward_dir);
                return self.atomResult(start, true);
            },
        }
    }

    //--- char class parsing ---

    fn reParseCharClass(self: *REParseState, start: usize, is_backward_dir: bool) CompileError!Atom {
        self.buf_ptr += 1;
        if (self.unicode_sets) {
            var set = try self.reParseNestedClass();
            defer set.deinit();
            try self.reEmitStringList(&set, is_backward_dir);
            return self.atomResult(start, true);
        }
        var ranges = CharRange.init(self.allocator);
        defer ranges.deinit();
        const invert = if (self.buf_ptr < self.buf_start.len and self.buf_start[self.buf_ptr] == '^') blk: {
            self.buf_ptr += 1;
            break :blk true;
        } else false;
        const body_start = self.buf_ptr;

        while (self.buf_ptr < self.buf_start.len) {
            if (self.buf_start[self.buf_ptr] == ']') {
                self.buf_ptr += 1;
                ranges.normalize();
                if (invert) try ranges.invert();
                try self.emitDirectionalRange(&ranges, is_backward_dir);
                return self.atomResult(start, true);
            }

            var atom_ranges = try self.reParseClassAtomOrRange(body_start);
            defer atom_ranges.deinit();
            try ranges.addSet(&atom_ranges);
        }
        return error.InvalidPattern;
    }

    fn atMatch(self: *const REParseState, needle: []const u8) bool {
        return self.buf_ptr + needle.len <= self.buf_start.len and
            std.mem.eql(u8, self.buf_start[self.buf_ptr..][0..needle.len], needle);
    }

    /// v-mode ClassSetExpression body. Entered just past the opening `[`
    /// (top-level or nested); consumes through the matching `]`. The
    /// expression is one of ClassUnion, ClassIntersection (`&&`-chain) or
    /// ClassDifference (`--`-chain) — operators must not be mixed at one
    /// level. Returns the resolved class set, case-folded per operand when
    /// ignoring case and complemented when the class is negated (negation
    /// of a set that may contain strings is a SyntaxError).
    fn reParseNestedClass(self: *REParseState) CompileError!REStringList {
        // qjs:libregexp.c — one native-stack check per recursive v-mode class entry
        if (self.lreCheckStackOverflow(0)) return error.StackOverflow;
        const invert = if (self.buf_ptr < self.buf_start.len and self.buf_start[self.buf_ptr] == '^') blk: {
            self.buf_ptr += 1;
            break :blk true;
        } else false;

        var result = REStringList.init(self.allocator);
        errdefer result.deinit();

        if (self.buf_ptr < self.buf_start.len and self.buf_start[self.buf_ptr] == ']') {
            self.buf_ptr += 1;
            if (invert) try result.ranges.invert();
            return result;
        }

        const first = try self.reParseClassSetOperand(true);
        result.deinit();
        result = first.set;

        if (self.atMatch("--")) {
            // ClassSetRange is only valid inside ClassUnion.
            if (first.was_range) return error.InvalidPattern;
            while (true) {
                if (self.buf_ptr < self.buf_start.len and self.buf_start[self.buf_ptr] == ']') {
                    self.buf_ptr += 1;
                    break;
                }
                if (!self.atMatch("--")) return error.InvalidPattern;
                self.buf_ptr += 2;
                var rhs = try self.reParseClassSetOperand(false);
                defer rhs.set.deinit();
                try result.subtract(&rhs.set);
            }
        } else if (self.atMatch("&&")) {
            if (first.was_range) return error.InvalidPattern;
            while (true) {
                if (self.buf_ptr < self.buf_start.len and self.buf_start[self.buf_ptr] == ']') {
                    self.buf_ptr += 1;
                    break;
                }
                if (!self.atMatch("&&")) return error.InvalidPattern;
                self.buf_ptr += 2;
                var rhs = try self.reParseClassSetOperand(false);
                defer rhs.set.deinit();
                try result.intersectWith(&rhs.set);
            }
        } else {
            while (true) {
                if (self.buf_ptr >= self.buf_start.len) return error.InvalidPattern;
                if (self.buf_start[self.buf_ptr] == ']') {
                    self.buf_ptr += 1;
                    break;
                }
                // Operators must not appear in a union chain.
                if (self.atMatch("--") or self.atMatch("&&")) return error.InvalidPattern;
                var rhs = try self.reParseClassSetOperand(true);
                defer rhs.set.deinit();
                try result.unionWith(&rhs.set);
            }
        }
        result.ranges.normalize();
        if (invert) {
            // ClassComplement of a set that may contain strings.
            if (result.strings.items.len != 0) return error.InvalidPattern;
            try result.ranges.invert();
        }
        return result;
    }

    /// One ClassSetOperand (or, when `allow_range`, a ClassSetRange) of a
    /// v-mode class set expression. The caller owns the returned set.
    fn reParseClassSetOperand(self: *REParseState, allow_range: bool) CompileError!REStringListOperandResult {
        if (self.buf_ptr >= self.buf_start.len) return error.InvalidPattern;
        const raw = self.buf_start[self.buf_ptr];
        if (raw == ']') return error.InvalidPattern;
        if (raw == '[') {
            // Nested class.
            self.buf_ptr += 1;
            const set = try self.reParseNestedClass();
            return .{ .set = set, .was_range = false };
        }
        if (raw != '\\') {
            // A lone `-` is a ClassSetSyntaxCharacter: never a valid
            // operand start in v-mode (ranges consume their hyphen below).
            if (isUnicodeSetsReservedClassByte(raw, true)) return error.InvalidPattern;
            if (self.buf_ptr + 1 < self.buf_start.len and isUnicodeSetsReservedDoublePunctuator(raw, self.buf_start[self.buf_ptr + 1])) {
                return error.InvalidPattern;
            }
        } else if (self.buf_ptr + 1 < self.buf_start.len and self.buf_start[self.buf_ptr + 1] == 'q') {
            return .{ .set = try self.parseClassStringDisjunction(), .was_range = false };
        } else if (self.buf_ptr + 1 < self.buf_start.len and (self.buf_start[self.buf_ptr + 1] == 'p' or self.buf_start[self.buf_ptr + 1] == 'P')) {
            if (try self.parseStringPropertyEscape()) |set| {
                return .{ .set = set, .was_range = false };
            }
        }

        var set = REStringList.init(self.allocator);
        errdefer set.deinit();
        var was_range = false;

        const first = try self.getClassAtom();
        const can_be_range = allow_range and first == .code_point and
            self.buf_ptr + 1 < self.buf_start.len and
            self.buf_start[self.buf_ptr] == '-' and
            self.buf_start[self.buf_ptr + 1] != ']' and
            self.buf_start[self.buf_ptr + 1] != '-';
        if (can_be_range) {
            self.buf_ptr += 1;
            var second = try self.getClassAtom();
            if (second != .code_point) {
                second.ranges.deinit();
                return error.InvalidPattern;
            }
            if (second.code_point < first.code_point) return error.InvalidPattern;
            try addInclusiveRange(&set.ranges, first.code_point, second.code_point);
            if (self.ignore_case) try set.ranges.regexpCanonicalize(true);
            was_range = true;
        } else {
            try addAtomToCharRange(&set.ranges, first, self.ignore_case, true);
        }
        set.ranges.normalize();
        return .{ .set = set, .was_range = was_range };
    }

    /// `\q{alt|alt|...}`: each alternative is a (possibly empty) sequence
    /// of ClassSetCharacters. Single-code-point alternatives fold into the
    /// range set; longer ones (and the empty string) become set strings.
    fn parseClassStringDisjunction(self: *REParseState) CompileError!REStringList {
        std.debug.assert(self.atMatch("\\q"));
        self.buf_ptr += 2;
        if (self.buf_ptr >= self.buf_start.len or self.buf_start[self.buf_ptr] != '{') return error.InvalidPattern;
        self.buf_ptr += 1;

        var set = REStringList.init(self.allocator);
        errdefer set.deinit();
        var current = std.ArrayList(u21).empty;
        defer current.deinit(self.allocator);

        while (true) {
            if (self.buf_ptr >= self.buf_start.len) return error.InvalidPattern;
            const byte = self.buf_start[self.buf_ptr];
            if (byte == '}' or byte == '|') {
                self.buf_ptr += 1;
                if (current.items.len == 1) {
                    try addInclusiveRange(&set.ranges, current.items[0], current.items[0]);
                } else {
                    const copy = try self.allocator.dupe(u21, current.items);
                    errdefer self.allocator.free(copy);
                    try set.addOwnedString(copy);
                }
                current.clearRetainingCapacity();
                if (byte == '}') break;
                continue;
            }
            var atom = try self.getClassAtom();
            if (atom != .code_point) {
                if (atom == .ranges) atom.ranges.deinit();
                return error.InvalidPattern;
            }
            const cp = if (self.ignore_case) lreCanonicalize(atom.code_point, true) else atom.code_point;
            try current.append(self.allocator, cp);
        }
        set.ranges.normalize();
        if (self.ignore_case) try set.ranges.regexpCanonicalize(true);
        return set;
    }

    /// Emit the matcher for a v-mode class set. Multi-code-point strings
    /// are tried first (longest first, per spec ordering), then the
    /// code-point set, then the empty string when present.
    fn reEmitStringList(self: *REParseState, set: *REStringList, is_backward_dir: bool) CompileError!void {
        if (set.strings.items.len == 0) {
            if (is_backward_dir) try self.reEmitOp(.prev);
            try self.reEmitRange(&set.ranges);
            if (is_backward_dir) try self.reEmitOp(.prev);
            return;
        }

        // Sort strings by descending length. Distinct equal-length class-set
        // strings cannot both match the same input, so their relative order is
        // unobservable; duplicates are already coalesced. QuickJS likewise
        // uses its ordinary rqsort with only a length comparator
        //. Avoid a large stable block-sort instance here.
        const items = set.strings.items;
        sort_erased.heap([]u21, items, {}, struct {
            fn longerFirst(_: void, lhs: []u21, rhs: []u21) bool {
                return lhs.len > rhs.len;
            }
        }.longerFirst);

        const has_empty = items.len > 0 and items[items.len - 1].len == 0;
        const string_count = items.len - @intFromBool(has_empty);
        const has_ranges = !set.ranges.isEmpty();

        var end_jumps = std.ArrayList(usize).empty;
        defer end_jumps.deinit(self.allocator);

        for (items[0..string_count], 0..) |s, string_index| {
            const is_last_branch = string_index + 1 == string_count and !has_ranges and !has_empty;
            const split_pos = if (!is_last_branch) try self.reEmitOpU32At(.split_next_first, 0) else null;
            if (is_backward_dir) {
                var k = s.len;
                while (k > 0) {
                    k -= 1;
                    try self.emitCharacterAtom(s[k], true);
                }
            } else {
                for (s) |cp| try self.emitCharacterAtom(cp, false);
            }
            if (!is_last_branch) {
                const goto_pos = try self.reEmitOpU32At(.goto_, 0);
                try end_jumps.append(self.allocator, goto_pos);
            }
            if (split_pos) |pos| {
                std.mem.writeInt(u32, self.byte_code.items[pos..][0..4], @intCast(self.byte_code.items.len - (pos + 4)), .little);
            }
        }

        if (has_ranges) {
            const split_pos = if (has_empty) try self.reEmitOpU32At(.split_next_first, 0) else null;
            if (is_backward_dir) try self.reEmitOp(.prev);
            try self.reEmitRange(&set.ranges);
            if (is_backward_dir) try self.reEmitOp(.prev);
            if (split_pos) |pos| {
                // The empty-string branch matches nothing: fall through.
                std.mem.writeInt(u32, self.byte_code.items[pos..][0..4], @intCast(self.byte_code.items.len - (pos + 4)), .little);
            }
        }
        // has_empty: the empty alternative emits no instructions.

        for (end_jumps.items) |goto_pos| {
            std.mem.writeInt(u32, self.byte_code.items[goto_pos..][0..4], @intCast(self.byte_code.items.len - (goto_pos + 4)), .little);
        }
    }

    fn reParseClassAtomOrRange(self: *REParseState, body_start: usize) CompileError!CharRange {
        if (self.unicode_sets and self.buf_ptr < self.buf_start.len and self.buf_start[self.buf_ptr] != '\\') {
            const raw = self.buf_start[self.buf_ptr];
            if (isUnicodeSetsReservedClassByte(raw, self.buf_ptr == body_start or (self.buf_ptr + 1 < self.buf_start.len and self.buf_start[self.buf_ptr + 1] == ']'))) {
                return error.InvalidPattern;
            }
            if (self.buf_ptr + 1 < self.buf_start.len and isUnicodeSetsReservedDoublePunctuator(raw, self.buf_start[self.buf_ptr + 1])) {
                return error.InvalidPattern;
            }
        }

        var ranges = CharRange.init(self.allocator);
        errdefer ranges.deinit();

        const first = try self.getClassAtom();
        if (self.buf_ptr < self.buf_start.len and self.buf_start[self.buf_ptr] == '-' and self.buf_ptr + 1 < self.buf_start.len and self.buf_start[self.buf_ptr + 1] != ']') {
            if (first != .code_point) {
                // `getClassAtom` hands this frame the owner of a class-escape
                // atom (`\d` and friends carry a `CharRange`), and the only
                // consumer is `addAtomToCharRange`. A leg that rejects instead
                // of consuming has to release it, exactly like the v-mode
                // operand parser does (`reParseClassSetOperand`).
                if (self.is_unicode) {
                    var owned_ranges = first.ranges;
                    owned_ranges.deinit();
                    return error.InvalidPattern;
                }
                try addAtomToCharRange(&ranges, first, self.ignore_case, self.is_unicode);
                return ranges;
            }
            const hyphen_index = self.buf_ptr;
            self.buf_ptr += 1;
            var second = try self.getClassAtom();
            if (second != .code_point) {
                // Both legs below drop `second`: the non-unicode one rewinds to
                // the hyphen so the class escape is re-read as its own atom.
                second.ranges.deinit();
                if (self.is_unicode) return error.InvalidPattern;
                self.buf_ptr = hyphen_index;
                try addAtomToCharRange(&ranges, first, self.ignore_case, self.is_unicode);
                return ranges;
            }
            if (second.code_point < first.code_point) return error.InvalidPattern;
            try addInclusiveRange(&ranges, first.code_point, second.code_point);
            if (self.ignore_case) try ranges.regexpCanonicalize(self.is_unicode);
        } else {
            try addAtomToCharRange(&ranges, first, self.ignore_case, self.is_unicode);
        }
        return ranges;
    }

    fn getClassAtom(self: *REParseState) CompileError!REClassAtom {
        if (self.buf_ptr >= self.buf_start.len) return error.InvalidPattern;
        const byte = self.buf_start[self.buf_ptr];
        if (byte == '\\') {
            if (self.buf_ptr + 1 >= self.buf_start.len) return error.InvalidPattern;
            const escaped = self.buf_start[self.buf_ptr + 1];
            switch (escaped) {
                'd', 'D', 's', 'S', 'w', 'W' => {
                    self.buf_ptr += 2;
                    var ranges = CharRange.init(self.allocator);
                    errdefer ranges.deinit();
                    try addClassEscape(&ranges, escaped);
                    return .{ .ranges = ranges };
                },
                '0' => {
                    if (self.is_unicode) {
                        if (self.buf_ptr + 2 < self.buf_start.len and isDigit(self.buf_start[self.buf_ptr + 2])) return error.InvalidPattern;
                        self.buf_ptr += 2;
                        return .{ .code_point = 0 };
                    }
                    return .{ .code_point = try self.parseLegacyClassDecimalEscape() };
                },
                '1'...'9' => {
                    if (self.is_unicode) return error.InvalidPattern;
                    return .{ .code_point = try self.parseLegacyClassDecimalEscape() };
                },
                'b' => {
                    self.buf_ptr += 2;
                    return .{ .code_point = 0x08 };
                },
                'c' => {
                    if (self.is_unicode) {
                        if (self.buf_ptr + 2 >= self.buf_start.len) return error.InvalidPattern;
                        const cp_byte = self.buf_start[self.buf_ptr + 2];
                        if (!((cp_byte >= 'a' and cp_byte <= 'z') or (cp_byte >= 'A' and cp_byte <= 'Z'))) return error.InvalidPattern;
                        const cp: u21 = cp_byte & 0x1f;
                        self.buf_ptr += 3;
                        return .{ .code_point = cp };
                    }
                    if (self.buf_ptr + 2 < self.buf_start.len) {
                        const cp_byte = self.buf_start[self.buf_ptr + 2];
                        if ((cp_byte >= 'a' and cp_byte <= 'z') or
                            (cp_byte >= 'A' and cp_byte <= 'Z') or
                            isDigit(cp_byte) or cp_byte == '_')
                        {
                            const cp: u21 = cp_byte & 0x1f;
                            self.buf_ptr += 3;
                            return .{ .code_point = cp };
                        }
                    }
                    self.buf_ptr += 2;
                    var ranges = CharRange.init(self.allocator);
                    errdefer ranges.deinit();
                    try addInclusiveRange(&ranges, '\\', '\\');
                    try addInclusiveRange(&ranges, 'c', 'c');
                    return .{ .ranges = ranges };
                },
                'B', 'k' => {
                    if (self.is_unicode) return error.Unsupported;
                    self.buf_ptr += 2;
                    return .{ .code_point = escaped };
                },
                'p', 'P' => {
                    if (!self.is_unicode) {
                        self.buf_ptr += 2;
                        return .{ .code_point = escaped };
                    }
                    return .{ .ranges = try self.parseUnicodePropertyEscapeWithOrdering(escaped == 'P') };
                },
                'x' => {
                    const escape_start = self.buf_ptr;
                    const cp = self.parseFixedHexEscape(2) catch |err| {
                        self.buf_ptr = escape_start;
                        if (self.is_unicode) return err;
                        self.buf_ptr += 2;
                        return .{ .code_point = 'x' };
                    };
                    return .{ .code_point = cp };
                },
                'u' => {
                    const escape_start = self.buf_ptr;
                    const braced = self.isBracedUnicodeEscape();
                    const cp = self.parseUnicodeEscape() catch |err| {
                        self.buf_ptr = escape_start;
                        if (self.is_unicode) return err;
                        self.buf_ptr += 2;
                        return .{ .code_point = 'u' };
                    };
                    return .{ .code_point = if (braced) cp else try self.combineEscapedSurrogatePair(cp) };
                },
                'f', 'n', 'r', 't', 'v' => {
                    self.buf_ptr += 2;
                    return .{ .code_point = switch (escaped) {
                        'f' => 0x0c,
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        'v' => 0x0b,
                        else => unreachable,
                    } };
                },
                else => {
                    if (isSyntaxEscape(escaped) or escaped == '/' or escaped == '-') {
                        self.buf_ptr += 2;
                        return .{ .code_point = escaped };
                    }
                    if (self.is_unicode) return error.InvalidPattern;
                    self.buf_ptr += 2;
                    return .{ .code_point = escaped };
                },
            }
        }
        const cp = try self.readClassCodePoint();
        if (cp > 0xffff and !self.is_unicode) {
            var ranges = CharRange.init(self.allocator);
            errdefer ranges.deinit();
            try addNonUnicodeSurrogatePair(&ranges, cp);
            return .{ .ranges = ranges };
        }
        return .{ .code_point = cp };
    }

    //--- quantifier ---

    fn parseQuantifier(self: *REParseState, atom: Atom) CompileError!void {
        if (self.buf_ptr >= self.buf_start.len) return;
        var min: u32 = 1;
        var max: u32 = 1;
        const quant_start = self.buf_ptr;
        switch (self.buf_start[self.buf_ptr]) {
            '*' => {
                self.buf_ptr += 1;
                min = 0;
                max = int32_max;
            },
            '+' => {
                self.buf_ptr += 1;
                min = 1;
                max = int32_max;
            },
            '?' => {
                self.buf_ptr += 1;
                min = 0;
                max = 1;
            },
            '{' => {
                if (self.buf_ptr + 1 >= self.buf_start.len or !isDigit(self.buf_start[self.buf_ptr + 1])) return;
                self.buf_ptr += 1;
                min = try self.parseDigits(true);
                max = min;
                if (self.buf_ptr < self.buf_start.len and self.buf_start[self.buf_ptr] == ',') {
                    self.buf_ptr += 1;
                    if (self.buf_ptr < self.buf_start.len and isDigit(self.buf_start[self.buf_ptr])) {
                        max = try self.parseDigits(true);
                        if (max < min) return error.InvalidPattern;
                    } else {
                        max = int32_max;
                    }
                }
                if (self.buf_ptr >= self.buf_start.len or self.buf_start[self.buf_ptr] != '}') {
                    self.buf_ptr = quant_start;
                    if (self.is_unicode) return error.InvalidPattern;
                    return;
                }
                self.buf_ptr += 1;
            },
            else => return,
        }
        if (!atom.quantifiable) return error.InvalidPattern;
        const greedy = if (self.buf_ptr < self.buf_start.len and self.buf_start[self.buf_ptr] == '?') blk: {
            self.buf_ptr += 1;
            break :blk false;
        } else true;
        if (min == 1 and max == 1) return;
        const analysis = try reNeedCheckAdvAndCaptureInit(self.byte_code.items[atom.start..]);
        var quant_atom_start = atom.start;
        if (self.capture_count != atom.capture_count_before) {
            if (analysis.need_capture_init) {
                try self.reInsertSaveReset(quant_atom_start, atom.capture_count_before, self.capture_count - 1);
            } else if (min == 0) {
                try self.reInsertSaveReset(quant_atom_start, atom.capture_count_before, self.capture_count - 1);
                quant_atom_start += 3;
            }
        }
        if (greedy and max == int32_max and (min == 0 or min == 1) and !analysis.need_check_advance) {
            if (try self.tryFoldGreedyClass8Loop(quant_atom_start, @intCast(min))) return;
        }
        try self.wrapGenericQuantifier(quant_atom_start, min, max, greedy, analysis.need_check_advance);
    }

    fn tryFoldGreedyClass8Loop(self: *REParseState, atom_start: usize, min: u8) !bool {
        if (atom_start >= self.byte_code.items.len) return false;
        const op = decodeOp(self.byte_code.items[atom_start]) orelse return false;
        if (op != .class8 and op != .not_class8) return false;
        if (self.byte_code.items.len - atom_start != 1 + class8_bitmap_len) return false;
        try self.insertBytes(atom_start + 1, 1);
        self.byte_code.items[atom_start] = opByte(if (op == .class8) .loop_class8_g else .loop_not_class8_g);
        self.byte_code.items[atom_start + 1] = min;
        return true;
    }

    fn wrapGenericQuantifier(self: *REParseState, atom_start: usize, min: u32, max: u32, greedy: bool, need_check_advance: bool) CompileError!void {
        const atom_len = self.byte_code.items.len - atom_start;
        const split_op: REOPCodeEnum = if (greedy) .split_next_first else .split_goto_first;
        if (min == 0) {
            if (max == 0) {
                self.byte_code.shrinkRetainingCapacity(atom_start);
                return;
            }
            if (max == 1 or max == int32_max) {
                const has_goto = max == int32_max;
                try self.insertBytes(atom_start, 5 + if (need_check_advance) @as(usize, 2) else 0);
                self.byte_code.items[atom_start] = opByte(split_op);
                std.mem.writeInt(
                    u32,
                    self.byte_code.items[atom_start + 1 ..][0..4],
                    @intCast(atom_len + (if (has_goto) @as(usize, 5) else 0) + (if (need_check_advance) @as(usize, 4) else 0)),
                    .little,
                );
                if (need_check_advance) {
                    self.byte_code.items[atom_start + 5] = opByte(.set_char_pos);
                    self.byte_code.items[atom_start + 6] = 0;
                    try self.reEmitOpU8(.check_advance, 0);
                }
                if (has_goto) try self.reEmitGoto(.goto_, atom_start);
                return;
            }

            try self.insertBytes(atom_start, 11 + if (need_check_advance) @as(usize, 2) else 0);
            self.byte_code.items[atom_start] = opByte(split_op);
            std.mem.writeInt(
                u32,
                self.byte_code.items[atom_start + 1 ..][0..4],
                @intCast(6 + (if (need_check_advance) @as(usize, 2) else 0) + atom_len + 10),
                .little,
            );
            var pos = atom_start + 5;
            self.byte_code.items[pos] = opByte(.set_i32);
            self.byte_code.items[pos + 1] = 0;
            std.mem.writeInt(u32, self.byte_code.items[pos + 2 ..][0..4], max, .little);
            pos += 6;
            const loop_target = pos;
            if (need_check_advance) {
                self.byte_code.items[pos] = opByte(.set_char_pos);
                self.byte_code.items[pos + 1] = 0;
                pos += 2;
            }
            std.debug.assert(pos == atom_start + 11 + if (need_check_advance) @as(usize, 2) else 0);
            try self.reEmitGotoU8U32(loopSplitOp(greedy, need_check_advance), 0, max, loop_target);
            return;
        }

        if (min == 1 and max == int32_max and !need_check_advance) {
            try self.reEmitGoto(if (greedy) .split_goto_first else .split_next_first, atom_start);
            return;
        }

        const add_zero_advance_check = if (min == max) false else need_check_advance;
        try self.insertBytes(atom_start, 6 + if (add_zero_advance_check) @as(usize, 2) else 0);
        var pos = atom_start;
        self.byte_code.items[pos] = opByte(.set_i32);
        self.byte_code.items[pos + 1] = 0;
        std.mem.writeInt(u32, self.byte_code.items[pos + 2 ..][0..4], max, .little);
        pos += 6;
        const loop_target = pos;
        if (add_zero_advance_check) {
            self.byte_code.items[pos] = opByte(.set_char_pos);
            self.byte_code.items[pos + 1] = 0;
            pos += 2;
        }
        std.debug.assert(pos == atom_start + 6 + if (add_zero_advance_check) @as(usize, 2) else 0);
        if (min == max) {
            try self.reEmitGotoU8(.loop, 0, loop_target);
        } else {
            try self.reEmitGotoU8U32(loopSplitOp(greedy, add_zero_advance_check), 0, max - min, loop_target);
        }
    }

    //--- numeric escape ---

    fn parseDecimalEscape(self: *REParseState) CompileError!u32 {
        std.debug.assert(self.buf_start[self.buf_ptr] == '\\');
        self.buf_ptr += 1;
        return self.parseDigits(false);
    }

    fn parseLegacyDecimalEscape(self: *REParseState) CompileError!u21 {
        if (self.buf_ptr >= self.buf_start.len or !isDigit(self.buf_start[self.buf_ptr])) return error.InvalidPattern;
        if (self.buf_start[self.buf_ptr] > '7') {
            const cp = self.buf_start[self.buf_ptr];
            self.buf_ptr += 1;
            return cp;
        }

        var cp: u21 = 0;
        if (self.buf_start[self.buf_ptr] <= '3') {
            cp = self.buf_start[self.buf_ptr] - '0';
            self.buf_ptr += 1;
        }
        var consumed: usize = 0;
        while (consumed < 2 and self.buf_ptr < self.buf_start.len) : (consumed += 1) {
            const byte = self.buf_start[self.buf_ptr];
            if (byte < '0' or byte > '7') break;
            cp = cp * 8 + (self.buf_start[self.buf_ptr] - '0');
            self.buf_ptr += 1;
        }
        return cp;
    }

    fn parseLegacyOctalAfterZero(self: *REParseState) CompileError!u21 {
        var cp: u21 = 0;
        var consumed: usize = 0;
        while (consumed < 2 and self.buf_ptr < self.buf_start.len) : (consumed += 1) {
            const byte = self.buf_start[self.buf_ptr];
            if (byte < '0' or byte > '7') break;
            cp = cp * 8 + (self.buf_start[self.buf_ptr] - '0');
            self.buf_ptr += 1;
        }
        return cp;
    }

    fn parseLegacyClassDecimalEscape(self: *REParseState) CompileError!u21 {
        std.debug.assert(self.buf_start[self.buf_ptr] == '\\');
        self.buf_ptr += 1;
        if (self.buf_ptr >= self.buf_start.len or !isDigit(self.buf_start[self.buf_ptr])) return error.InvalidPattern;
        if (self.buf_start[self.buf_ptr] > '7') {
            const cp = self.buf_start[self.buf_ptr];
            self.buf_ptr += 1;
            return cp;
        }

        var cp: u21 = 0;
        var consumed: usize = 0;
        while (consumed < 3 and self.buf_ptr < self.buf_start.len) : (consumed += 1) {
            const byte = self.buf_start[self.buf_ptr];
            if (byte < '0' or byte > '7') break;
            const next = cp * 8 + (self.buf_start[self.buf_ptr] - '0');
            if (next > 0xff) break;
            cp = next;
            self.buf_ptr += 1;
        }
        return cp;
    }

    //--- group name & unicode property escape ---

    fn parseGroupName(self: *REParseState) CompileError![]const u8 {
        return parseGroupNameAt(self.buf_start, &self.buf_ptr);
    }

    /// When the `\p{...}`/`\P{...}` escape at `self.buf_ptr` names a v-mode
    /// property of strings, consumes it and returns its class set. `\P` of
    /// a property of strings is a SyntaxError (MayContainStrings under
    /// complement). Any other escape leaves the position untouched and
    /// returns null so the regular code-point property path applies.
    fn parseStringPropertyEscape(self: *REParseState) CompileError!?REStringList {
        std.debug.assert(self.buf_start[self.buf_ptr] == '\\');
        std.debug.assert(self.buf_start[self.buf_ptr + 1] == 'p' or self.buf_start[self.buf_ptr + 1] == 'P');
        if (self.buf_ptr + 2 >= self.buf_start.len or self.buf_start[self.buf_ptr + 2] != '{') return null;
        var end = self.buf_ptr + 3;
        while (end < self.buf_start.len and self.buf_start[end] != '}') : (end += 1) {}
        if (end >= self.buf_start.len) return null;
        const property_name = self.buf_start[self.buf_ptr + 3 .. end];
        if (!unicode.isSequencePropertyName(property_name)) return null;
        if (self.buf_start[self.buf_ptr + 1] == 'P') return error.InvalidPattern;
        const set = (try self.buildStringPropertyStringList(property_name)).?;
        self.buf_ptr = end + 1;
        return set;
    }

    fn buildStringPropertyStringList(self: *REParseState, property_name: []const u8) CompileError!?REStringList {
        var set = REStringList.init(self.allocator);
        errdefer set.deinit();

        var ctx = REStringListBuildContext{ .s = self, .set = &set };
        const found = unicode.addSequenceProperty(self.allocator, REStringListBuildContext, &ctx, property_name, addSequenceToStringList) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidProperty => unreachable,
        };
        if (!found) {
            set.deinit();
            return null;
        }

        set.ranges.normalize();
        if (self.ignore_case) try set.ranges.regexpCanonicalize(true);
        return set;
    }

    fn addSequenceToStringList(ctx: *REStringListBuildContext, sequence: []const u21) std.mem.Allocator.Error!void {
        if (sequence.len == 1) {
            const cp = sequence[0];
            try ctx.set.ranges.addInterval(cp, cp + 1);
            return;
        }

        const copy = try ctx.s.allocator.dupe(u21, sequence);
        errdefer ctx.s.allocator.free(copy);
        if (ctx.s.ignore_case) {
            for (copy) |*cp| cp.* = lreCanonicalize(cp.*, true);
        }
        if (ctx.set.containsString(copy)) {
            ctx.s.allocator.free(copy);
            return;
        }
        try array_list_erased.append(&ctx.set.strings, ctx.s.allocator, copy);
    }

    fn parseUnicodePropertyEscapeWithOrdering(self: *REParseState, inverted: bool) CompileError!CharRange {
        var ranges = try self.parseUnicodePropertyEscape();
        errdefer ranges.deinit();
        if (self.ignore_case and self.unicode_sets) {
            try ranges.regexpCanonicalize(self.is_unicode);
        }
        if (inverted) try ranges.invert();
        if (self.ignore_case and !self.unicode_sets) {
            try ranges.regexpCanonicalize(self.is_unicode);
        }
        return ranges;
    }

    fn parseUnicodePropertyEscape(self: *REParseState) CompileError!CharRange {
        std.debug.assert(self.buf_start[self.buf_ptr] == '\\');
        if (self.buf_ptr + 3 >= self.buf_start.len or self.buf_start[self.buf_ptr + 2] != '{') return error.InvalidPattern;
        self.buf_ptr += 3;
        const name_start = self.buf_ptr;
        while (self.buf_ptr < self.buf_start.len and self.buf_start[self.buf_ptr] != '}') : (self.buf_ptr += 1) {
            const byte = self.buf_start[self.buf_ptr];
            if (!lreIsWordByte(byte) and byte != '=') return error.Unsupported;
        }
        if (self.buf_ptr == name_start or self.buf_ptr >= self.buf_start.len or self.buf_start[self.buf_ptr] != '}') return error.InvalidPattern;
        const name = self.buf_start[name_start..self.buf_ptr];
        self.buf_ptr += 1;

        var ranges = CharRange.init(self.allocator);
        errdefer ranges.deinit();
        try addUnicodeProperty(&ranges, name);
        return ranges;
    }

    //--- code point readers ---

    fn parseDigits(self: *REParseState, allow_overflow: bool) CompileError!u32 {
        var value: u64 = 0;
        var saw_digit = false;
        while (self.buf_ptr < self.buf_start.len and isDigit(self.buf_start[self.buf_ptr])) : (self.buf_ptr += 1) {
            saw_digit = true;
            value = value * 10 + (self.buf_start[self.buf_ptr] - '0');
            if (value >= int32_max) {
                if (!allow_overflow) return error.InvalidPattern;
                value = int32_max;
            }
        }
        if (!saw_digit) return error.InvalidPattern;
        return @intCast(value);
    }

    fn parseFixedHexEscape(self: *REParseState, digit_count: usize) CompileError!u21 {
        if (self.buf_ptr + 2 + digit_count > self.buf_start.len) return error.InvalidPattern;
        self.buf_ptr += 2;
        var cp: u21 = 0;
        for (0..digit_count) |_| {
            cp = cp * 16 + (fromHex(self.buf_start[self.buf_ptr]) orelse return error.InvalidPattern);
            self.buf_ptr += 1;
        }
        return cp;
    }

    fn parseUnicodeEscape(self: *REParseState) CompileError!u21 {
        if (self.buf_ptr + 1 >= self.buf_start.len or self.buf_start[self.buf_ptr] != '\\' or self.buf_start[self.buf_ptr + 1] != 'u') return error.InvalidPattern;
        if (self.isBracedUnicodeEscape()) {
            self.buf_ptr += 3;
            var cp: u21 = 0;
            var saw_digit = false;
            while (self.buf_ptr < self.buf_start.len and self.buf_start[self.buf_ptr] != '}') : (self.buf_ptr += 1) {
                const digit = fromHex(self.buf_start[self.buf_ptr]) orelse return error.InvalidPattern;
                if (cp > max_code_point / 16) return error.InvalidPattern;
                cp = cp * 16 + digit;
                if (cp > max_code_point) return error.InvalidPattern;
                saw_digit = true;
            }
            if (!saw_digit or self.buf_ptr >= self.buf_start.len or self.buf_start[self.buf_ptr] != '}') return error.InvalidPattern;
            self.buf_ptr += 1;
            return cp;
        }
        return self.parseFixedHexEscape(4);
    }

    fn isBracedUnicodeEscape(self: *const REParseState) bool {
        return self.is_unicode and self.buf_ptr + 2 < self.buf_start.len and self.buf_start[self.buf_ptr + 2] == '{';
    }

    fn combineEscapedSurrogatePair(self: *REParseState, first: u21) CompileError!u21 {
        if (!self.is_unicode or !isHiSurrogate(first)) return first;
        const saved = self.buf_ptr;
        if (self.buf_ptr + 5 >= self.buf_start.len or self.buf_start[self.buf_ptr] != '\\' or self.buf_start[self.buf_ptr + 1] != 'u') return first;
        if (self.buf_ptr + 2 < self.buf_start.len and self.buf_start[self.buf_ptr + 2] == '{') return first;
        const second = try self.parseFixedHexEscape(4);
        if (!isLoSurrogate(second)) {
            self.buf_ptr = saved;
            return first;
        }
        return fromSurrogate(@intCast(first), @intCast(second));
    }

    fn readPatternCodePoint(self: *REParseState) CompileError!u21 {
        if (self.buf_ptr >= self.buf_start.len) return error.InvalidPattern;
        const byte = self.buf_start[self.buf_ptr];
        if (byte < 0x80 and isRegexSyntax(byte)) return error.InvalidPattern;
        return self.readUtf8CodePoint();
    }

    fn readClassCodePoint(self: *REParseState) CompileError!u21 {
        const first = try self.readUtf8CodePoint();
        if (!self.is_unicode or !isHiSurrogate(first)) return first;

        const saved = self.buf_ptr;
        const second = self.readUtf8CodePoint() catch |err| {
            self.buf_ptr = saved;
            if (err == error.InvalidPattern) return first;
            return err;
        };
        if (!isLoSurrogate(second)) {
            self.buf_ptr = saved;
            return first;
        }
        return fromSurrogate(@intCast(first), @intCast(second));
    }

    fn readUtf8CodePoint(self: *REParseState) CompileError!u21 {
        if (self.buf_ptr >= self.buf_start.len) return error.InvalidPattern;
        const byte = self.buf_start[self.buf_ptr];
        if (byte < 0x80) {
            self.buf_ptr += 1;
            return byte;
        }
        if (decodeWtf8Surrogate(self.buf_start, self.buf_ptr)) |decoded| {
            self.buf_ptr += decoded.len;
            return decoded.code_point;
        }
        const width = std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidPattern;
        if (self.buf_ptr + width > self.buf_start.len) return error.InvalidPattern;
        const cp = std.unicode.utf8Decode(self.buf_start[self.buf_ptr .. self.buf_ptr + width]) catch return error.InvalidPattern;
        if (cp > max_code_point) return error.InvalidPattern;
        self.buf_ptr += width;
        return @intCast(cp);
    }

    fn looksLikeQuantifier(self: *const REParseState, start: usize) bool {
        if (start + 1 >= self.buf_start.len or !isDigit(self.buf_start[start + 1])) return false;
        var pos = start + 1;
        while (pos < self.buf_start.len and isDigit(self.buf_start[pos])) : (pos += 1) {}
        if (pos < self.buf_start.len and self.buf_start[pos] == ',') {
            pos += 1;
            while (pos < self.buf_start.len and isDigit(self.buf_start[pos])) : (pos += 1) {}
        }
        return pos < self.buf_start.len and self.buf_start[pos] == '}';
    }

    //--- bytecode emit ---

    fn reEmitChar(self: *REParseState, cp: u21) !void {
        if (cp <= 0xffff) {
            try self.reEmitOpU16(if (self.ignore_case) .char_i else .char, @intCast(cp));
        } else {
            try self.reEmitOpU32(if (self.ignore_case) .char32_i else .char32, cp);
        }
    }

    fn emitCharacterAtom(self: *REParseState, cp: u21, is_backward_dir: bool) !void {
        if (is_backward_dir) try self.reEmitOp(.prev);
        try self.reEmitChar(cp);
        if (is_backward_dir) try self.reEmitOp(.prev);
    }

    fn emitCanonicalChar(self: *REParseState, cp: u21, is_backward_dir: bool) !void {
        try self.emitCharacterAtom(canonicalizeLiteral(cp, self.ignore_case, self.is_unicode), is_backward_dir);
    }

    fn emitDirectional(self: *REParseState, op: REOPCodeEnum, is_backward_dir: bool) !void {
        if (is_backward_dir) try self.reEmitOp(.prev);
        try self.reEmitOp(op);
        if (is_backward_dir) try self.reEmitOp(.prev);
    }

    fn emitDirectionalRange(self: *REParseState, ranges: *CharRange, is_backward_dir: bool) !void {
        if (is_backward_dir) try self.reEmitOp(.prev);
        try self.reEmitRange(ranges);
        if (is_backward_dir) try self.reEmitOp(.prev);
    }

    fn emitNonUnicodeSurrogatePairAtom(self: *REParseState, cp: u21, is_backward_dir: bool) !void {
        const pair = unicode.surrogatePairFromCodePoint(cp);
        const high: u21 = pair.high;
        const low: u21 = pair.low;
        if (is_backward_dir) {
            try self.emitCharacterAtom(low, true);
            try self.emitCharacterAtom(high, true);
        } else {
            try self.emitCharacterAtom(high, false);
            try self.emitCharacterAtom(low, false);
        }
    }

    fn emitNonUnicodeCodePointAtom(self: *REParseState, cp: u21, is_backward_dir: bool) !void {
        std.debug.assert(!self.is_unicode);
        if (cp > 0xffff) {
            try self.emitNonUnicodeSurrogatePairAtom(cp, is_backward_dir);
        } else {
            try self.emitCanonicalChar(cp, is_backward_dir);
        }
    }

    fn emitInvalidControlEscape(self: *REParseState, is_backward_dir: bool) CompileError!void {
        std.debug.assert(!self.is_unicode);
        self.buf_ptr += 2;
        try self.emitCharacterAtom('\\', is_backward_dir);
        try self.emitCharacterAtom('c', is_backward_dir);
        if (self.buf_ptr < self.buf_start.len) {
            const cp = try self.readUtf8CodePoint();
            try self.emitNonUnicodeCodePointAtom(cp, is_backward_dir);
        }
    }

    fn emitNonUnicodeSurrogatePairTerms(self: *REParseState, cp: u21, is_backward_dir: bool) !usize {
        const pair = unicode.surrogatePairFromCodePoint(cp);
        const high: u21 = pair.high;
        const low: u21 = pair.low;
        if (is_backward_dir) {
            const low_start = self.byte_code.items.len;
            try self.emitCharacterAtom(low, true);
            try self.emitCharacterAtom(high, true);
            return low_start;
        }
        try self.emitCharacterAtom(high, false);
        const low_start = self.byte_code.items.len;
        try self.emitCharacterAtom(low, false);
        return low_start;
    }

    fn reEmitRange(self: *REParseState, ranges: *CharRange) !void {
        ranges.normalize();
        if (ranges.isEmpty()) {
            try self.reEmitOpU32(.char32, 0xffffffff);
            return;
        }
        if (!self.ignore_case) {
            if (buildClass8IncludedBitmap(ranges)) |bitmap| {
                try self.reEmitClass8(.class8, &bitmap);
                return;
            }
            if (buildClass8ExcludedBitmap(ranges)) |bitmap| {
                try self.reEmitClass8(.not_class8, &bitmap);
                return;
            }
        }
        var high = ranges.lastHi();
        if (high == unicode.char_range_sentinel) {
            high = ranges.points.items[ranges.points.items.len - 2];
        }
        const use_32 = high > 0xffff;
        const range_count = ranges.rangeCount();
        if (use_32) {
            try self.reEmitOpU16(if (self.ignore_case) .range32_i else .range32, @intCast(range_count));
            var i: usize = 0;
            while (i < range_count) : (i += 1) {
                const range = ranges.rangeAt(i);
                try self.appendU32(range.lo);
                try self.appendU32(@as(u32, range.hi) - 1);
            }
        } else {
            try self.reEmitOpU16(if (self.ignore_case) .range_i else .range, @intCast(range_count));
            for (0..range_count) |i| {
                const range = ranges.rangeAt(i);
                var inclusive_hi = range.hi - 1;
                if (inclusive_hi == unicode.char_range_sentinel - 1) inclusive_hi = 0xffff;
                try self.appendU16(@intCast(range.lo));
                try self.appendU16(@intCast(inclusive_hi));
            }
        }
    }

    fn reEmitClass8(self: *REParseState, op: REOPCodeEnum, bitmap: *const [class8_bitmap_len]u8) !void {
        try self.reEmitOp(op);
        try self.byte_code.appendSlice(self.allocator, bitmap[0..]);
    }

    fn backReferenceOp(self: *const REParseState, is_backward_dir: bool) REOPCodeEnum {
        if (is_backward_dir) return if (self.ignore_case) .backward_back_reference_i else .backward_back_reference;
        return if (self.ignore_case) .back_reference_i else .back_reference;
    }

    fn emitBackReference(self: *REParseState, is_backward_dir: bool, capture_indexes: []const u8) !void {
        if (capture_indexes.len == 0 or capture_indexes.len > 255) return error.Unsupported;
        try self.reEmitOpU8(self.backReferenceOp(is_backward_dir), @intCast(capture_indexes.len));
        try self.byte_code.appendSlice(self.allocator, capture_indexes);
    }

    fn reEmitOp(self: *REParseState, op: REOPCodeEnum) !void {
        try self.byte_code.append(self.allocator, opByte(op));
    }

    fn reEmitOpU8(self: *REParseState, op: REOPCodeEnum, value: u8) !void {
        try self.reEmitOp(op);
        try self.byte_code.append(self.allocator, value);
    }

    fn reEmitOpU16(self: *REParseState, op: REOPCodeEnum, value: u16) !void {
        try self.reEmitOp(op);
        try self.appendU16(value);
    }

    fn reEmitOpU32(self: *REParseState, op: REOPCodeEnum, value: u32) !void {
        try self.reEmitOp(op);
        try self.appendU32(value);
    }

    fn reEmitOpU32At(self: *REParseState, op: REOPCodeEnum, value: u32) !usize {
        try self.reEmitOp(op);
        const pos = self.byte_code.items.len;
        try self.appendU32(value);
        return pos;
    }

    fn reEmitOpI32(self: *REParseState, op: REOPCodeEnum, value: i32) !void {
        try self.reEmitOpU32(op, @bitCast(value));
    }

    fn reEmitGoto(self: *REParseState, op: REOPCodeEnum, target: usize) !void {
        try self.reEmitOp(op);
        const operand_pos = self.byte_code.items.len;
        const base: isize = @intCast(operand_pos + 4);
        const destination: isize = @intCast(target);
        const offset: i32 = @intCast(destination - base);
        try self.appendU32(@bitCast(offset));
    }

    fn reEmitGotoU8(self: *REParseState, op: REOPCodeEnum, reg: u8, target: usize) !void {
        try self.reEmitOp(op);
        try self.byte_code.append(self.allocator, reg);
        const operand_pos = self.byte_code.items.len;
        const base: isize = @intCast(operand_pos + 4);
        const destination: isize = @intCast(target);
        const offset: i32 = @intCast(destination - base);
        try self.appendU32(@bitCast(offset));
    }

    fn reEmitGotoU8U32(self: *REParseState, op: REOPCodeEnum, reg: u8, limit: u32, target: usize) !void {
        try self.reEmitOp(op);
        try self.byte_code.append(self.allocator, reg);
        try self.appendU32(limit);
        const operand_pos = self.byte_code.items.len;
        const base: isize = @intCast(operand_pos + 4);
        const destination: isize = @intCast(target);
        const offset: i32 = @intCast(destination - base);
        try self.appendU32(@bitCast(offset));
    }

    fn reInsertSaveReset(self: *REParseState, index: usize, first: u8, last: u8) !void {
        try self.insertBytes(index, 3);
        self.byte_code.items[index] = opByte(.save_reset);
        self.byte_code.items[index + 1] = first;
        self.byte_code.items[index + 2] = last;
    }

    fn appendU16(self: *REParseState, value: u16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, value, .little);
        try self.byte_code.appendSlice(self.allocator, &buf);
    }

    fn appendU32(self: *REParseState, value: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .little);
        try self.byte_code.appendSlice(self.allocator, &buf);
    }

    fn insertBytes(self: *REParseState, index: usize, count: usize) !void {
        const old_len = self.byte_code.items.len;
        try self.byte_code.appendNTimes(self.allocator, 0, count);
        std.mem.copyBackwards(
            u8,
            self.byte_code.items[index + count .. index + count + old_len - index],
            self.byte_code.items[index..old_len],
        );
    }

    fn moveTermToStart(self: *REParseState, start: usize, term_start: usize, term_end: usize) !void {
        if (term_start == start or term_start == term_end) return;
        const term_len = term_end - term_start;
        const term = try self.allocator.dupe(u8, self.byte_code.items[term_start..term_end]);
        defer self.allocator.free(term);
        std.mem.copyBackwards(
            u8,
            self.byte_code.items[start + term_len .. term_end],
            self.byte_code.items[start..term_start],
        );
        @memcpy(self.byte_code.items[start .. start + term_len], term);
    }
};

//=== Char-class / CharRange helpers =======================================

inline fn class8Mask(byte: u8) u8 {
    return @as(u8, 1) << @as(u3, @intCast(byte & 7));
}

inline fn class8BitmapContains(bitmap: [*]const u8, byte: u8) bool {
    return (bitmap[byte >> 3] & class8Mask(byte)) != 0;
}

inline fn class8CodePointMatches(bitmap: [*]const u8, code_point: u21) bool {
    if (code_point >= class8_char_count) return false;
    return class8BitmapContains(bitmap, @intCast(code_point));
}

inline fn setClass8BitmapBit(bitmap: *[class8_bitmap_len]u8, byte: u8) void {
    bitmap[byte >> 3] |= class8Mask(byte);
}

fn buildClass8IncludedBitmap(ranges: *const CharRange) ?[class8_bitmap_len]u8 {
    var bitmap: [class8_bitmap_len]u8 = @splat(0);
    var range_index: usize = 0;
    while (range_index < ranges.rangeCount()) : (range_index += 1) {
        const range = ranges.rangeAt(range_index);
        if (range.hi > class8_char_count) return null;
        var c = range.lo;
        while (c < range.hi) : (c += 1) {
            setClass8BitmapBit(&bitmap, @intCast(c));
        }
    }
    return bitmap;
}

fn buildClass8ExcludedBitmap(ranges: *const CharRange) ?[class8_bitmap_len]u8 {
    if (!rangesContainTailFrom(ranges, class8_char_count)) return null;
    var bitmap: [class8_bitmap_len]u8 = @splat(0);
    var c: u32 = 0;
    while (c < class8_char_count) : (c += 1) {
        if (!rangesContainCodePoint(ranges, c)) {
            setClass8BitmapBit(&bitmap, @intCast(c));
        }
    }
    return bitmap;
}

fn rangesContainTailFrom(ranges: *const CharRange, start: u32) bool {
    var range_index: usize = 0;
    while (range_index < ranges.rangeCount()) : (range_index += 1) {
        const range = ranges.rangeAt(range_index);
        if (range.hi <= start) continue;
        return range.lo <= start and range.hi == unicode.char_range_sentinel;
    }
    return false;
}

fn rangesContainCodePoint(ranges: *const CharRange, cp: u32) bool {
    var range_index: usize = 0;
    while (range_index < ranges.rangeCount()) : (range_index += 1) {
        const range = ranges.rangeAt(range_index);
        if (cp < range.lo) return false;
        if (cp < range.hi) return true;
    }
    return false;
}

fn addAtomToCharRange(ranges: *CharRange, atom: REClassAtom, ignore_case: bool, is_unicode: bool) CompileError!void {
    switch (atom) {
        .code_point => |cp| {
            const folded = if (ignore_case) lreCanonicalize(cp, is_unicode) else cp;
            try addInclusiveRange(ranges, folded, folded);
        },
        .ranges => |owned_ranges| {
            defer {
                var mutable = owned_ranges;
                mutable.deinit();
            }
            try ranges.addSet(&owned_ranges);
        },
    }
}

fn addInclusiveRange(ranges: *CharRange, lo: u21, hi_inclusive: u21) CompileError!void {
    if (hi_inclusive < lo) return error.InvalidPattern;
    if (hi_inclusive == max_code_point) {
        try ranges.addInterval(lo, max_code_point + 1);
    } else {
        try ranges.addInterval(lo, hi_inclusive + 1);
    }
}

fn addNonUnicodeSurrogatePair(ranges: *CharRange, cp: u21) CompileError!void {
    const pair = unicode.surrogatePairFromCodePoint(cp);
    try addInclusiveRange(ranges, pair.high, pair.high);
    try addInclusiveRange(ranges, pair.low, pair.low);
}

fn addClassEscape(ranges: *CharRange, escaped: u8) CompileError!void {
    switch (escaped) {
        'd', 'D' => {
            try ranges.addInterval('0', '9' + 1);
            if (escaped == 'D') try ranges.invert();
        },
        's', 'S' => {
            for (unicode.ecmaWhitespaceOrLineTerminatorRanges) |range| {
                try ranges.addInterval(range.lo, range.hi);
            }
            if (escaped == 'S') try ranges.invert();
        },
        'w', 'W' => {
            try ranges.addInterval('0', '9' + 1);
            try ranges.addInterval('A', 'Z' + 1);
            try ranges.addInterval('_', '_' + 1);
            try ranges.addInterval('a', 'z' + 1);
            if (escaped == 'W') try ranges.invert();
        },
        else => unreachable,
    }
}

fn addUnicodeProperty(ranges: *CharRange, name: []const u8) CompileError!void {
    var property_points = unicode.propertyRangePoints(ranges.allocator, name, false) catch |err| switch (err) {
        error.InvalidProperty => return error.InvalidPattern,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer property_points.deinit();
    try ranges.addSet(&property_points);
}

//=== Post-parse analysis & opcode helpers =================================

const AtomAnalysis = struct {
    need_check_advance: bool,
    need_capture_init: bool,
};

fn reNeedCheckAdvAndCaptureInit(code: []const u8) CompileError!AtomAnalysis {
    var pos: usize = 0;
    var need_check_advance = true;
    var need_capture_init = false;
    while (pos < code.len) {
        const op: REOPCodeEnum = @enumFromInt(code[pos]);
        var len = opFixedSize(op) orelse return error.InvalidPattern;
        switch (op) {
            .range, .range_i => {
                if (pos + 3 > code.len) return error.InvalidPattern;
                const count = std.mem.readInt(u16, code[pos + 1 ..][0..2], .little);
                len += @as(usize, count) * 4;
                need_check_advance = false;
            },
            .range32, .range32_i => {
                if (pos + 3 > code.len) return error.InvalidPattern;
                const count = std.mem.readInt(u16, code[pos + 1 ..][0..2], .little);
                len += @as(usize, count) * 8;
                need_check_advance = false;
            },
            .char, .char_i, .char32, .char32_i, .dot, .any, .space, .not_space, .class8, .not_class8 => {
                need_check_advance = false;
            },
            .loop_class8_g, .loop_not_class8_g => {
                if (pos + 2 > code.len) return error.InvalidPattern;
                if (code[pos + 1] != 0) need_check_advance = false;
            },
            .line_start, .line_start_m, .line_end, .line_end_m, .set_i32, .set_char_pos, .word_boundary, .word_boundary_i, .not_word_boundary, .not_word_boundary_i, .prev => {},
            .save_start, .save_end, .save_reset => {},
            .back_reference, .back_reference_i, .backward_back_reference, .backward_back_reference_i => {
                if (pos + 2 > code.len) return error.InvalidPattern;
                len += @as(usize, code[pos + 1]);
                need_capture_init = true;
            },
            else => {
                need_capture_init = true;
                break;
            },
        }
        if (pos + len > code.len) return error.InvalidPattern;
        pos += len;
    }
    return .{ .need_check_advance = need_check_advance, .need_capture_init = need_capture_init };
}

fn reComputeRegisterCount(code: []u8) CompileError!u8 {
    var pos: usize = 0;
    var stack_size: u16 = 0;
    var register_count: u16 = 0;
    while (pos < code.len) {
        const op: REOPCodeEnum = @enumFromInt(code[pos]);
        var len = opFixedSize(op) orelse return error.InvalidPattern;
        switch (op) {
            .set_i32, .set_char_pos => {
                if (pos + 2 > code.len) return error.InvalidPattern;
                code[pos + 1] = @intCast(stack_size);
                stack_size += 1;
                if (stack_size > 255) return error.Unsupported;
                if (stack_size > register_count) register_count = stack_size;
            },
            .check_advance, .loop, .loop_split_goto_first, .loop_split_next_first => {
                if (stack_size == 0) return error.InvalidPattern;
                stack_size -= 1;
                if (pos + 2 > code.len) return error.InvalidPattern;
                code[pos + 1] = @intCast(stack_size);
            },
            .loop_check_adv_split_goto_first, .loop_check_adv_split_next_first => {
                if (stack_size < 2) return error.InvalidPattern;
                stack_size -= 2;
                if (pos + 2 > code.len) return error.InvalidPattern;
                code[pos + 1] = @intCast(stack_size);
            },
            .range, .range_i => {
                if (pos + 3 > code.len) return error.InvalidPattern;
                const count = std.mem.readInt(u16, code[pos + 1 ..][0..2], .little);
                len += @as(usize, count) * 4;
            },
            .range32, .range32_i => {
                if (pos + 3 > code.len) return error.InvalidPattern;
                const count = std.mem.readInt(u16, code[pos + 1 ..][0..2], .little);
                len += @as(usize, count) * 8;
            },
            .back_reference, .back_reference_i, .backward_back_reference, .backward_back_reference_i => {
                if (pos + 2 > code.len) return error.InvalidPattern;
                len += @as(usize, code[pos + 1]);
            },
            else => {},
        }
        if (pos + len > code.len) return error.InvalidPattern;
        pos += len;
    }
    return @intCast(register_count);
}

fn opFixedSize(op: REOPCodeEnum) ?usize {
    return switch (op) {
        .invalid => null,
        .char, .char_i => 3,
        .char32, .char32_i => 5,
        .dot, .any, .space, .not_space, .line_start, .line_start_m, .line_end, .line_end_m, .match, .lookahead_match, .negative_lookahead_match, .word_boundary, .word_boundary_i, .not_word_boundary, .not_word_boundary_i, .prev => 1,
        .class8, .not_class8 => 1 + class8_bitmap_len,
        .scan_until_char8 => 6,
        .loop_class8_g, .loop_not_class8_g => 2 + class8_bitmap_len,
        .goto_, .split_goto_first, .split_next_first, .lookahead, .negative_lookahead => 5,
        .loop, .set_i32 => 6,
        .set_char_pos, .check_advance => 2,
        .save_start, .save_end, .back_reference, .back_reference_i, .backward_back_reference, .backward_back_reference_i => 2,
        .save_reset, .range, .range_i, .range32, .range32_i => 3,
        .loop_split_goto_first, .loop_split_next_first, .loop_check_adv_split_goto_first, .loop_check_adv_split_next_first => 10,
    };
}

fn loopSplitOp(greedy: bool, need_check_advance: bool) REOPCodeEnum {
    if (need_check_advance) {
        return if (greedy) .loop_check_adv_split_goto_first else .loop_check_adv_split_next_first;
    }
    return if (greedy) .loop_split_goto_first else .loop_split_next_first;
}

fn canonicalizeLiteral(cp: u21, ignore_case: bool, is_unicode: bool) u21 {
    if (!ignore_case) return cp;
    return lreCanonicalize(cp, is_unicode);
}

//=== Syntax & name helpers ================================================

fn opByte(op: REOPCodeEnum) u8 {
    return @intFromEnum(op);
}

fn isRegexSyntax(byte: u8) bool {
    return switch (byte) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', '{', '|' => true,
        else => false,
    };
}

fn isSyntaxEscape(byte: u8) bool {
    return switch (byte) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => true,
        else => false,
    };
}

fn isUnicodeSetsReservedClassByte(byte: u8, hyphen_is_reserved: bool) bool {
    return switch (byte) {
        '(', ')', '[', '{', '}', '/', '|' => true,
        '-' => hyphen_is_reserved,
        else => false,
    };
}

fn isUnicodeSetsReservedDoublePunctuator(first: u8, second: u8) bool {
    if (first != second) return false;
    return switch (first) {
        '&', '!', '#', '$', '%', '*', '+', ',', '.', ':', ';', '<', '=', '>', '?', '@', '`', '~', '^' => true,
        else => false,
    };
}

//=== Encoding & classification helpers ====================================

inline fn fromHex(byte: u8) ?u21 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    return null;
}

inline fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

inline fn lreIsWordByte(byte: u8) bool {
    return (lre_ctype_bits[byte] & (lre_ctype_upper | lre_ctype_lower | lre_ctype_under | lre_ctype_digit)) != 0;
}
