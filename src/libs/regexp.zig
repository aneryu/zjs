const std = @import("std");
const unicode = @import("unicode.zig");
const regexp_properties = @import("unicode/regexp_properties.zig");

pub const max_captures = 255;
const register_count_max = 255;
pub const max_exec_slots = max_captures * 2 + register_count_max;
pub const small_exec_slots = 64;
const static_stack_buf_count = 32;
const interrupt_counter_init = 10000;

pub const flags = struct {
    pub const global: u16 = 1 << 0;
    pub const ignore_case: u16 = 1 << 1;
    pub const multiline: u16 = 1 << 2;
    pub const dot_all: u16 = 1 << 3;
    pub const unicode: u16 = 1 << 4;
    pub const sticky: u16 = 1 << 5;
    pub const indices: u16 = 1 << 6;
    pub const named_groups: u16 = 1 << 7;
    pub const unicode_sets: u16 = 1 << 8;
};

pub const Capture = struct {
    start: ?usize,
    end: ?usize,
    name: ?[]const u8 = null,
};

pub const Match = struct {
    start: usize,
    end: usize,
    capture_count: usize,
    captures: [max_captures]Capture = undefined,
};

pub const ExecResult = enum {
    match,
    no_match,
    out_of_range,
    not_available,
};

pub const ExecStatus = struct {
    result: ExecResult,
    match: Match = undefined,
};

pub const Input = union(enum) {
    latin1: []const u8,
    utf16: []const u16,

    fn len(self: Input) usize {
        return switch (self) {
            .latin1 => |bytes| bytes.len,
            .utf16 => |units| units.len,
        };
    }
};

pub const CheckTimeout = *const fn (?*anyopaque) bool;

pub const ExecOptions = struct {
    @"opaque": ?*anyopaque = null,
    check_timeout: ?CheckTimeout = null,
};

const REBytecodeHeader = struct {
    flags: u16,
    capture_count: usize,
    register_count: usize,
    bytecode_len: usize,
};

const CaptureSlotBuffer = struct {
    inline_slots: [small_exec_slots]usize = undefined,
    heap_slots: []usize = &.{},
    slots: []usize = &.{},

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
        self.* = .{};
    }
};

const header_len = 8;
const re_header_capture_count = 2;
const re_header_register_count = 3;
const re_header_bytecode_len = 4;
const int32_max: u32 = 0x7fffffff;
const group_name_trailer_len = 2;
const class8_bitmap_len = 16;
const class8_char_count = class8_bitmap_len * 8;

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

const CbufType = enum {
    latin1,
    utf16_units,
    utf16_unicode,
};

const ExecSafety = enum {
    checked,
    trusted,
};

const REExecStateEnum = enum(u3) {
    split,
    lookahead,
    negative_lookahead,
};

const frame_entry_count = 3;
const bp_type_bits = 3;
const bp_type_mask = (1 << bp_type_bits) - 1;
const no_slot_value = std.math.maxInt(usize);
const StackElem = usize;

const REExecContext = struct {
    allocator: std.mem.Allocator,
    cbuf: Input,
    cbuf_latin1: []const u8,
    cbuf_utf16: []const u16,
    cbuf_end: usize,
    cbuf_type: CbufType,
    bc_buf: []const u8,
    bc_buf_end: usize,
    capture_count: usize,
    register_count: usize,
    alloc_count: usize,
    is_unicode: bool,
    interrupt_counter: i32,
    @"opaque": ?*anyopaque,
    check_timeout: ?CheckTimeout,
    stack_buf: []StackElem,
    stack_size: usize,
    static_stack_buf: [static_stack_buf_count]StackElem,

    fn deinit(self: *REExecContext) void {
        if (self.stack_buf.len != 0 and self.stack_buf.ptr != self.static_stack_buf[0..].ptr) {
            self.allocator.free(self.stack_buf);
        }
        self.stack_buf = &.{};
        self.stack_size = 0;
    }

    inline fn pollTimeout(self: *REExecContext) !void {
        const check_timeout = self.check_timeout orelse return;
        self.interrupt_counter -= 1;
        if (self.interrupt_counter <= 0) {
            self.interrupt_counter = interrupt_counter_init;
            if (check_timeout(self.@"opaque")) return error.Timeout;
        }
    }

    fn stackRealloc(self: *REExecContext, n: usize) !void {
        var new_size = self.stack_size * 3 / 2;
        if (new_size < n) new_size = n;
        if (self.stack_buf.ptr == self.static_stack_buf[0..].ptr) {
            const new_stack = try self.allocator.alloc(StackElem, new_size);
            @memcpy(new_stack[0..self.stack_size], self.stack_buf[0..self.stack_size]);
            self.stack_buf = new_stack;
        } else {
            self.stack_buf = try self.allocator.realloc(self.stack_buf, new_size);
        }
        self.stack_size = new_size;
    }
};

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

pub fn captureCount(bytecode: []const u8) usize {
    if (bytecode.len <= re_header_capture_count) return 0;
    return bytecode[re_header_capture_count];
}

pub fn registerCount(bytecode: []const u8) usize {
    if (bytecode.len <= re_header_register_count) return 0;
    return bytecode[re_header_register_count];
}

pub fn allocCount(bytecode: []const u8) usize {
    return captureCount(bytecode) * 2 + registerCount(bytecode);
}

pub fn getFlags(bytecode: []const u8) u16 {
    if (bytecode.len < 2) return 0;
    return std.mem.readInt(u16, bytecode[0..2], .little);
}

pub fn groupName(bytecode: []const u8, one_based_capture_index: usize) ?[]const u8 {
    if (one_based_capture_index == 0 or (getFlags(bytecode) & flags.named_groups) == 0) return null;
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

pub const Compiled = struct {
    bytecode: []u8,

    pub fn deinit(self: *Compiled, allocator: std.mem.Allocator) void {
        allocator.free(self.bytecode);
        self.bytecode = &.{};
    }

    pub fn captureCount(self: Compiled) usize {
        return regex_bytecode.captureCount(self.bytecode);
    }

    pub fn registerCount(self: Compiled) usize {
        return regex_bytecode.registerCount(self.bytecode);
    }

    pub fn allocCount(self: Compiled) usize {
        return regex_bytecode.allocCount(self.bytecode);
    }

    pub fn groupName(self: Compiled, one_based_capture_index: usize) ?[]const u8 {
        return regex_bytecode.groupName(self.bytecode, one_based_capture_index);
    }

    pub fn flagBits(self: Compiled) u16 {
        return regex_bytecode.getFlags(self.bytecode);
    }
};

pub fn compilePatternAndFlags(allocator: std.mem.Allocator, pattern: []const u8, flags_str: []const u8) !Compiled {
    return .{ .bytecode = try regex_bytecode.compile(allocator, pattern, flags_str) };
}

pub fn isSupportedUnicodePropertyExpression(name: []const u8) bool {
    return regexp_properties.isSupportedUnicodePropertyExpression(name);
}

pub fn exec(allocator: std.mem.Allocator, bytecode: []const u8, input: Input, start_index: usize) !ExecStatus {
    return execWithOptions(allocator, bytecode, input, start_index, .{});
}

pub fn execWithOptions(allocator: std.mem.Allocator, bytecode: []const u8, input: Input, start_index: usize, options: ExecOptions) !ExecStatus {
    var match: Match = undefined;
    return switch (try execIntoMatchWithOptions(allocator, bytecode, input, start_index, options, &match)) {
        .match => .{ .result = .match, .match = match },
        .no_match => .{ .result = .no_match },
        .out_of_range => .{ .result = .out_of_range },
        .not_available => .{ .result = .not_available },
    };
}

pub fn execIntoMatch(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    input: Input,
    start_index: usize,
    out_match: *Match,
) !ExecResult {
    return execIntoMatchWithOptions(allocator, bytecode, input, start_index, .{}, out_match);
}

pub fn execIntoMatchWithOptions(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    input: Input,
    start_index: usize,
    options: ExecOptions,
    out_match: *Match,
) !ExecResult {
    const header = try parseHeader(bytecode);
    var capture_buf = CaptureSlotBuffer{};
    try capture_buf.init(allocator, try checkedAllocCount(header));
    defer capture_buf.deinit(allocator);

    const result = try execCaptureSlotsParsed(.checked, allocator, bytecode, input, start_index, options, header, capture_buf.slots);
    if (result != .match) return result;
    writeMatch(bytecode, header.capture_count, capture_buf.slots.ptr, out_match);
    return .match;
}

/// Fast path for bytecode produced by this compiler or by an equivalent validator.
pub fn execIntoMatchTrustedWithOptions(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    input: Input,
    start_index: usize,
    options: ExecOptions,
    out_match: *Match,
) !ExecResult {
    const header = try parseHeader(bytecode);
    var capture_buf = CaptureSlotBuffer{};
    try capture_buf.init(allocator, try checkedAllocCount(header));
    defer capture_buf.deinit(allocator);

    const result = try execCaptureSlotsParsed(.trusted, allocator, bytecode, input, start_index, options, header, capture_buf.slots);
    if (result != .match) return result;
    writeMatch(bytecode, header.capture_count, capture_buf.slots.ptr, out_match);
    return .match;
}

pub fn execCaptureSlots(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    input: Input,
    start_index: usize,
    capture: *[max_exec_slots]usize,
) !ExecResult {
    return execCaptureSlotsWithOptions(allocator, bytecode, input, start_index, .{}, capture);
}

pub fn execCaptureSlotsWithOptions(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    input: Input,
    start_index: usize,
    options: ExecOptions,
    capture: *[max_exec_slots]usize,
) !ExecResult {
    return execCaptureSlotsSliceWithOptions(allocator, bytecode, input, start_index, options, capture[0..]);
}

pub fn execCaptureSlotsSlice(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    input: Input,
    start_index: usize,
    capture: []usize,
) !ExecResult {
    return execCaptureSlotsSliceWithOptions(allocator, bytecode, input, start_index, .{}, capture);
}

pub fn execCaptureSlotsSliceWithOptions(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    input: Input,
    start_index: usize,
    options: ExecOptions,
    capture: []usize,
) !ExecResult {
    const header = try parseHeader(bytecode);
    return execCaptureSlotsParsed(.checked, allocator, bytecode, input, start_index, options, header, capture);
}

/// Fast path for bytecode produced by this compiler or by an equivalent validator.
pub fn execCaptureSlotsSliceTrustedWithOptions(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    input: Input,
    start_index: usize,
    options: ExecOptions,
    capture: []usize,
) !ExecResult {
    const header = try parseHeader(bytecode);
    return execCaptureSlotsParsed(.trusted, allocator, bytecode, input, start_index, options, header, capture);
}

fn execCaptureSlotsParsed(
    comptime safety: ExecSafety,
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    input: Input,
    start_index: usize,
    options: ExecOptions,
    header: REBytecodeHeader,
    capture: []usize,
) !ExecResult {
    const alloc_count = try checkedAllocCount(header);
    if (capture.len < alloc_count) return error.BytecodeCorrupt;
    if (start_index > input.len()) return .out_of_range;
    const cbuf_type: CbufType = switch (input) {
        .latin1 => .latin1,
        .utf16 => if ((header.flags & (flags.unicode | flags.unicode_sets)) != 0) .utf16_unicode else .utf16_units,
    };
    const initial_cptr = normalizeStartIndex(input, cbuf_type, start_index);
    const cbuf_latin1: []const u8 = switch (input) {
        .latin1 => |bytes| bytes,
        .utf16 => &.{},
    };
    const cbuf_utf16: []const u16 = switch (input) {
        .latin1 => &.{},
        .utf16 => |units| units,
    };

    var ctx = REExecContext{
        .allocator = allocator,
        .cbuf = input,
        .cbuf_latin1 = cbuf_latin1,
        .cbuf_utf16 = cbuf_utf16,
        .cbuf_end = input.len(),
        .cbuf_type = cbuf_type,
        .bc_buf = bytecode,
        .bc_buf_end = header_len + header.bytecode_len,
        .capture_count = header.capture_count,
        .register_count = header.register_count,
        .alloc_count = alloc_count,
        .is_unicode = (header.flags & (flags.unicode | flags.unicode_sets)) != 0,
        .interrupt_counter = interrupt_counter_init,
        .@"opaque" = options.@"opaque",
        .check_timeout = options.check_timeout,
        .stack_buf = &.{},
        .stack_size = static_stack_buf_count,
        .static_stack_buf = undefined,
    };
    ctx.stack_buf = ctx.static_stack_buf[0..];
    defer ctx.deinit();

    @memset(capture[0 .. header.capture_count * 2], no_slot_value);
    if (comptime safety == .checked) {
        @memset(capture[header.capture_count * 2 .. alloc_count], no_slot_value);
    }
    const matched = switch (cbuf_type) {
        .latin1 => try lreExecBacktrack(safety, .latin1, &ctx, capture.ptr, header_len, initial_cptr),
        .utf16_units => try lreExecBacktrack(safety, .utf16_units, &ctx, capture.ptr, header_len, initial_cptr),
        .utf16_unicode => try lreExecBacktrack(safety, .utf16_unicode, &ctx, capture.ptr, header_len, initial_cptr),
    };
    return if (matched) .match else .no_match;
}

pub fn testMatch(allocator: std.mem.Allocator, bytecode: []const u8, input: Input, start_index: usize) !bool {
    return testMatchWithOptions(allocator, bytecode, input, start_index, .{});
}

pub fn testMatchWithOptions(allocator: std.mem.Allocator, bytecode: []const u8, input: Input, start_index: usize, options: ExecOptions) !bool {
    const header = try parseHeader(bytecode);
    var capture_buf = CaptureSlotBuffer{};
    try capture_buf.init(allocator, try checkedAllocCount(header));
    defer capture_buf.deinit(allocator);
    return (try execCaptureSlotsParsed(.checked, allocator, bytecode, input, start_index, options, header, capture_buf.slots)) == .match;
}

/// Fast path for bytecode produced by this compiler or by an equivalent validator.
pub fn testMatchTrustedWithOptions(allocator: std.mem.Allocator, bytecode: []const u8, input: Input, start_index: usize, options: ExecOptions) !bool {
    const header = try parseHeader(bytecode);
    var capture_buf = CaptureSlotBuffer{};
    try capture_buf.init(allocator, try checkedAllocCount(header));
    defer capture_buf.deinit(allocator);
    return (try execCaptureSlotsParsed(.trusted, allocator, bytecode, input, start_index, options, header, capture_buf.slots)) == .match;
}

inline fn decodeExecState(comptime safety: ExecSafety, meta: usize) !REExecStateEnum {
    const type_value = meta & bp_type_mask;
    if (comptime safety == .checked) {
        if (type_value > @intFromEnum(REExecStateEnum.negative_lookahead)) return error.BytecodeCorrupt;
    }
    return @enumFromInt(type_value);
}

inline fn execStatePrevBp(meta: usize) usize {
    return meta >> bp_type_bits;
}

const ExecState = struct {
    s: *REExecContext,
    capture: [*]usize,
    pc: [*]const u8,
    bc_end: [*]const u8,
    stack_buf: [*]usize,
    cbuf_latin1: [*]const u8,
    cbuf_utf16: [*]const u16,
    cptr: usize,
    sp: usize,
    bp: usize,
    stack_end: usize,
    cbuf_type: CbufType,
    cbuf_end: usize,

    fn init(
        s: *REExecContext,
        capture: [*]usize,
        initial_pc: usize,
        initial_cptr: usize,
    ) !ExecState {
        if (initial_pc > s.bc_buf_end) return error.BytecodeCorrupt;
        const bc_ptr = s.bc_buf.ptr;
        return .{
            .s = s,
            .capture = capture,
            .pc = bc_ptr + initial_pc,
            .bc_end = bc_ptr + s.bc_buf_end,
            .stack_buf = s.stack_buf.ptr,
            .cbuf_latin1 = s.cbuf_latin1.ptr,
            .cbuf_utf16 = s.cbuf_utf16.ptr,
            .cptr = initial_cptr,
            .sp = 0,
            .bp = 0,
            .stack_end = s.stack_size,
            .cbuf_type = s.cbuf_type,
            .cbuf_end = s.cbuf_end,
        };
    }

    inline fn checkStackSpace(self: *ExecState, comptime safety: ExecSafety, n: usize) !void {
        const needs_grow = if (comptime safety == .checked)
            self.stack_end < self.sp or self.stack_end - self.sp < n
        else
            self.stack_end - self.sp < n;
        if (needs_grow) {
            @branchHint(.unlikely);
            try self.s.stackRealloc(self.sp + n);
            self.stack_buf = self.s.stack_buf.ptr;
            self.stack_end = self.s.stack_size;
        }
    }

    inline fn ensurePc(self: *const ExecState, comptime safety: ExecSafety, ptr: [*]const u8, n: usize) !void {
        if (comptime safety == .trusted) return;
        const base_addr = @intFromPtr(self.s.bc_buf.ptr);
        const ptr_addr = @intFromPtr(ptr);
        const end_addr = @intFromPtr(self.bc_end);
        if (ptr_addr < base_addr or ptr_addr > end_addr or end_addr - ptr_addr < n) return error.BytecodeCorrupt;
    }

    inline fn pcWithOffset(self: *const ExecState, comptime safety: ExecSafety, offset: i32) ![*]const u8 {
        if (comptime safety == .trusted) {
            const delta: usize = @bitCast(@as(isize, offset));
            return @ptrFromInt(@intFromPtr(self.pc) +% delta);
        }
        const base_addr = @intFromPtr(self.s.bc_buf.ptr);
        const pc_addr = @intFromPtr(self.pc);
        const end_addr = @intFromPtr(self.bc_end);
        if (pc_addr < base_addr or pc_addr > end_addr) return error.BytecodeCorrupt;
        const next_addr = if (offset >= 0) next: {
            const delta: usize = @intCast(offset);
            if (end_addr - pc_addr < delta) return error.BytecodeCorrupt;
            break :next pc_addr + delta;
        } else next: {
            const delta: usize = @intCast(-@as(i64, offset));
            if (pc_addr - base_addr < delta) return error.BytecodeCorrupt;
            break :next pc_addr - delta;
        };
        return @ptrFromInt(next_addr);
    }

    inline fn getU8(self: *ExecState, comptime safety: ExecSafety) !u8 {
        try self.ensurePc(safety, self.pc, 1);
        const value = self.pc[0];
        self.pc += 1;
        return value;
    }

    inline fn readU8At(self: *const ExecState, comptime safety: ExecSafety, ptr: [*]const u8) !u8 {
        try self.ensurePc(safety, ptr, 1);
        return ptr[0];
    }

    inline fn getU16(self: *ExecState, comptime safety: ExecSafety) !u16 {
        try self.ensurePc(safety, self.pc, 2);
        const value = std.mem.readInt(u16, self.pc[0..2], .little);
        self.pc += 2;
        return value;
    }

    inline fn readU16At(self: *const ExecState, comptime safety: ExecSafety, ptr: [*]const u8) !u16 {
        try self.ensurePc(safety, ptr, 2);
        return std.mem.readInt(u16, ptr[0..2], .little);
    }

    inline fn readU16UncheckedAt(ptr: [*]const u8) u16 {
        return std.mem.readInt(u16, ptr[0..2], .little);
    }

    inline fn getU32(self: *ExecState, comptime safety: ExecSafety) !u32 {
        try self.ensurePc(safety, self.pc, 4);
        const value = std.mem.readInt(u32, self.pc[0..4], .little);
        self.pc += 4;
        return value;
    }

    inline fn readU32At(self: *const ExecState, comptime safety: ExecSafety, ptr: [*]const u8) !u32 {
        try self.ensurePc(safety, ptr, 4);
        return std.mem.readInt(u32, ptr[0..4], .little);
    }

    inline fn readU32UncheckedAt(ptr: [*]const u8) u32 {
        return std.mem.readInt(u32, ptr[0..4], .little);
    }

    inline fn getI32(self: *ExecState, comptime safety: ExecSafety) !i32 {
        return @bitCast(try self.getU32(safety));
    }

    inline fn pushExecState(self: *ExecState, comptime safety: ExecSafety, pc: [*]const u8, typ: REExecStateEnum) !void {
        try self.checkStackSpace(safety, frame_entry_count);
        const pos = self.sp;
        const stack_buf = self.stack_buf;
        stack_buf[pos] = @intFromPtr(pc);
        stack_buf[pos + 1] = self.cptr;
        stack_buf[pos + 2] = (self.bp << bp_type_bits) | @intFromEnum(typ);
        self.sp = pos + frame_entry_count;
        self.bp = self.sp;
    }

    inline fn saveCapture(self: *ExecState, comptime safety: ExecSafety, idx: usize, value: usize) !void {
        if (comptime safety == .checked) {
            if (idx >= self.s.alloc_count) return error.BytecodeCorrupt;
        }
        try self.checkStackSpace(safety, 2);
        self.saveCaptureAssumeSpace(idx, value);
    }

    inline fn saveCaptureAssumeSpace(self: *ExecState, idx: usize, value: usize) void {
        const pos = self.sp;
        const stack_buf = self.stack_buf;
        stack_buf[pos] = idx;
        stack_buf[pos + 1] = self.capture[idx];
        self.sp = pos + 2;
        self.capture[idx] = value;
    }

    inline fn saveCaptureCheck(self: *ExecState, comptime safety: ExecSafety, idx: usize, value: usize) !void {
        if (comptime safety == .checked) {
            if (idx >= self.s.alloc_count) return error.BytecodeCorrupt;
        }
        const stack_buf = self.stack_buf;
        var sp1 = self.sp;
        while (true) {
            if (sp1 > self.bp) {
                if (comptime safety == .checked) {
                    if (sp1 < 2) return error.BytecodeCorrupt;
                }
                if (stack_buf[sp1 - 2] == idx) break;
                sp1 -= 2;
            } else {
                try self.checkStackSpace(safety, 2);
                self.saveCaptureAssumeSpace(idx, value);
                return;
            }
        }
        self.capture[idx] = value;
    }

    inline fn registerSlot(self: *const ExecState, register: usize) usize {
        return self.s.capture_count * 2 + register;
    }

    inline fn readRegisterValue(self: *const ExecState, comptime safety: ExecSafety, register: usize) !usize {
        const slot = self.registerSlot(register);
        if (comptime safety == .checked) {
            if (slot >= self.s.alloc_count) return error.BytecodeCorrupt;
        }
        const value = self.capture[slot];
        if (comptime safety == .checked) {
            if (value == no_slot_value) return error.BytecodeCorrupt;
        }
        return value;
    }

    inline fn getCharAtBounded(self: *const ExecState, comptime safety: ExecSafety, comptime cbuf_type: CbufType, pos: *usize, end: usize) ?u21 {
        if (comptime safety == .checked) {
            if (end > self.cbuf_end) return null;
        }
        if (comptime cbuf_type == .latin1) {
            if (comptime safety == .checked) {
                if (pos.* >= end) return null;
            }
            const code_point: u21 = self.cbuf_latin1[pos.*];
            pos.* += 1;
            return code_point;
        }
        const units = self.cbuf_utf16;
        if (comptime safety == .checked) {
            if (pos.* >= end) return null;
        }
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

    inline fn getPrevCharAtBounded(self: *const ExecState, comptime safety: ExecSafety, comptime cbuf_type: CbufType, pos: *usize, start: usize) ?u21 {
        if (comptime safety == .checked) {
            if (pos.* <= start or start > self.cbuf_end) return null;
        }
        if (comptime cbuf_type == .latin1) {
            if (comptime safety == .checked) {
                if (pos.* > self.cbuf_end) return null;
            }
            pos.* -= 1;
            return self.cbuf_latin1[pos.*];
        }
        const units = self.cbuf_utf16;
        if (comptime safety == .checked) {
            if (pos.* > self.cbuf_end) return null;
        }
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
            const code_point: u21 = self.cbuf_latin1[self.cptr];
            self.cptr += 1;
            return code_point;
        }
        const units = self.cbuf_utf16;
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
            return self.cbuf_latin1[self.cptr];
        }
        if (self.cptr >= self.cbuf_end) return null;
        const units = self.cbuf_utf16;
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
            return self.cbuf_latin1[self.cptr - 1];
        }
        if (self.cptr > self.cbuf_end) return null;
        const units = self.cbuf_utf16;
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
        const units = self.cbuf_utf16;
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
        if (self.cptr >= self.cbuf_end) return false;
        var pos = self.cptr + 1;
        if (comptime cbuf_type == .latin1) {
            const haystack = self.cbuf_latin1[pos..self.cbuf_end];
            if (std.mem.indexOfScalar(u8, haystack, needle)) |offset| {
                self.cptr = pos + offset;
                return true;
            }
            return false;
        }

        const units = self.cbuf_utf16;
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
        comptime safety: ExecSafety,
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
                    try self.pushExecState(safety, continuation_pc, .split);
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

    inline fn matchRawForward(self: *ExecState, comptime safety: ExecSafety, comptime cbuf_type: CbufType, start: usize, end: usize) bool {
        if (comptime safety == .checked) {
            if (end < start) return false;
        }
        const len = end - start;
        if (self.cptr > self.cbuf_end) return false;
        if (self.cbuf_end - self.cptr < len) return false;
        const input_start = self.cptr;
        const input_end = input_start + len;
        const matched = if (comptime cbuf_type == .latin1)
            std.mem.eql(u8, self.cbuf_latin1[start..end], self.cbuf_latin1[input_start..input_end])
        else
            std.mem.eql(u16, self.cbuf_utf16[start..end], self.cbuf_utf16[input_start..input_end]);
        if (!matched) return false;
        self.cptr = input_end;
        return true;
    }

    inline fn matchRawBackward(self: *ExecState, comptime safety: ExecSafety, comptime cbuf_type: CbufType, start: usize, end: usize) bool {
        if (comptime safety == .checked) {
            if (end < start) return false;
        }
        const len = end - start;
        if (self.cptr < len) return false;
        const input_start = self.cptr - len;
        const matched = if (comptime cbuf_type == .latin1)
            std.mem.eql(u8, self.cbuf_latin1[start..end], self.cbuf_latin1[input_start..self.cptr])
        else
            std.mem.eql(u16, self.cbuf_utf16[start..end], self.cbuf_utf16[input_start..self.cptr]);
        if (!matched) return false;
        self.cptr = input_start;
        return true;
    }
};

fn lreExecBacktrack(
    comptime safety: ExecSafety,
    comptime cbuf_type: CbufType,
    ctx: *REExecContext,
    capture: [*]usize,
    initial_pc: usize,
    initial_cptr: usize,
) !bool {
    var st = try ExecState.init(ctx, capture, initial_pc, initial_cptr);

    main: while (true) {
        dispatch_once: {
            const opcode_byte = try st.getU8(safety);
            const opcode = decodeOp(opcode_byte) orelse return error.BytecodeCorrupt;
            switch (opcode) {
                .invalid => return error.BytecodeCorrupt,
                .match => return true,
                .lookahead_match => {
                    const items = st.stack_buf;
                    var sp1: usize = undefined;
                    const sp_top = st.sp;
                    var next_sp: usize = undefined;
                    var typ: REExecStateEnum = undefined;

                    while (true) {
                        sp1 = st.sp;
                        st.sp = st.bp;
                        if (st.sp < frame_entry_count) return error.BytecodeCorrupt;
                        st.pc = @ptrFromInt(items[st.sp - 3]);
                        try st.ensurePc(safety, st.pc, 0);
                        st.cptr = items[st.sp - 2];
                        const meta = items[st.sp - 1];
                        typ = try decodeExecState(safety, meta);
                        st.bp = execStatePrevBp(meta);
                        items[st.sp - 1] = sp1;
                        st.sp -= frame_entry_count;
                        if (typ == .lookahead) break;
                    }
                    if (st.sp != 0) {
                        sp1 = st.sp;
                        while (sp1 < sp_top) {
                            if (sp1 + 2 >= sp_top) return error.BytecodeCorrupt;
                            next_sp = items[sp1 + 2];
                            if (next_sp < sp1 + frame_entry_count or next_sp > sp_top) return error.BytecodeCorrupt;
                            sp1 += frame_entry_count;
                            while (sp1 < next_sp) : (sp1 += 1) {
                                items[st.sp] = items[sp1];
                                st.sp += 1;
                            }
                        }
                    }
                    continue :main;
                },
                .negative_lookahead_match => {
                    const items = st.stack_buf;
                    while (true) {
                        if (st.bp == 0) return error.BytecodeCorrupt;
                        while (st.sp > st.bp) {
                            if (comptime safety == .checked) {
                                if (st.sp < 2) return error.BytecodeCorrupt;
                            }
                            const slot = items[st.sp - 2];
                            if (comptime safety == .checked) {
                                if (slot >= st.s.alloc_count) return error.BytecodeCorrupt;
                            }
                            st.capture[slot] = items[st.sp - 1];
                            st.sp -= 2;
                        }
                        if (comptime safety == .checked) {
                            if (st.sp < frame_entry_count) return error.BytecodeCorrupt;
                        }
                        st.pc = @ptrFromInt(items[st.sp - 3]);
                        try st.ensurePc(safety, st.pc, 0);
                        st.cptr = items[st.sp - 2];
                        const meta = items[st.sp - 1];
                        const typ = try decodeExecState(safety, meta);
                        st.bp = execStatePrevBp(meta);
                        st.sp -= frame_entry_count;
                        if (typ == .negative_lookahead) break;
                    }
                    break :dispatch_once;
                },
                .char32, .char32_i => {
                    const expected = try st.getU32(safety);
                    if (st.cptr >= st.cbuf_end) break :dispatch_once;
                    var c = st.getCharUnchecked(cbuf_type);
                    if (opcode == .char32_i) {
                        c = lreCanonicalize(c, st.s.is_unicode);
                    }
                    if (expected != @as(u32, c)) break :dispatch_once;
                    continue :main;
                },
                .char, .char_i => {
                    const expected: u32 = try st.getU16(safety);
                    if (st.cptr >= st.cbuf_end) break :dispatch_once;
                    var c = st.getCharUnchecked(cbuf_type);
                    if (opcode == .char_i) {
                        c = lreCanonicalize(c, st.s.is_unicode);
                    }
                    if (expected != @as(u32, c)) break :dispatch_once;
                    continue :main;
                },
                .split_goto_first, .split_next_first => {
                    const offset = try st.getI32(safety);
                    const pc1 = if (opcode == .split_next_first)
                        try st.pcWithOffset(safety, offset)
                    else
                        st.pc;
                    if (opcode == .split_goto_first) st.pc = try st.pcWithOffset(safety, offset);
                    try st.pushExecState(safety, pc1, .split);
                    continue :main;
                },
                .lookahead, .negative_lookahead => {
                    const offset = try st.getI32(safety);
                    try st.pushExecState(safety, try st.pcWithOffset(safety, offset), if (opcode == .lookahead) .lookahead else .negative_lookahead);
                    continue :main;
                },
                .goto_ => {
                    const offset = try st.getI32(safety);
                    st.pc = try st.pcWithOffset(safety, offset);
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
                    try st.ensurePc(safety, st.pc, class8_bitmap_len);
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
                    const needle = try st.getU8(safety);
                    const offset = try st.getI32(safety);
                    if (!st.scanUntilChar8(cbuf_type, needle)) break :dispatch_once;
                    st.pc = try st.pcWithOffset(safety, offset);
                    continue :main;
                },
                .loop_class8_g, .loop_not_class8_g => {
                    const min = try st.getU8(safety);
                    if (min > 1) return error.BytecodeCorrupt;
                    try st.ensurePc(safety, st.pc, class8_bitmap_len);
                    const bitmap = st.pc;
                    st.pc += class8_bitmap_len;
                    if (!try st.scanGreedyClass8(safety, cbuf_type, bitmap, opcode == .loop_not_class8_g, min, st.pc)) break :dispatch_once;
                    continue :main;
                },
                .save_start, .save_end => {
                    const val = try st.getU8(safety);
                    if (val >= st.s.capture_count) return error.BytecodeCorrupt;
                    const idx = 2 * @as(usize, val) + @intFromEnum(opcode) - @intFromEnum(REOPCodeEnum.save_start);
                    try st.saveCapture(safety, idx, st.cptr);
                    continue :main;
                },
                .save_reset => {
                    var first = try st.readU8At(safety, st.pc);
                    const last = try st.readU8At(safety, st.pc + 1);
                    st.pc += 2;
                    if (last >= st.s.capture_count or first > last) return error.BytecodeCorrupt;
                    const count = (@as(usize, last) - @as(usize, first) + 1) * 4;
                    try st.checkStackSpace(safety, count);
                    var pos = st.sp;
                    const stack_buf = st.stack_buf;
                    while (first <= last) : (first += 1) {
                        var slot = @as(usize, first) * 2;
                        if (comptime safety == .checked) {
                            if (slot + 1 >= st.s.alloc_count) return error.BytecodeCorrupt;
                        }
                        stack_buf[pos] = slot;
                        stack_buf[pos + 1] = st.capture[slot];
                        st.capture[slot] = no_slot_value;
                        pos += 2;
                        slot += 1;
                        stack_buf[pos] = slot;
                        stack_buf[pos + 1] = st.capture[slot];
                        st.capture[slot] = no_slot_value;
                        pos += 2;
                    }
                    st.sp = pos;
                    continue :main;
                },
                .set_i32 => {
                    const reg = try st.readU8At(safety, st.pc);
                    const value = try st.readU32At(safety, st.pc + 1);
                    st.pc += 5;
                    if (comptime safety == .checked) {
                        if (reg >= st.s.register_count or reg >= register_count_max) return error.BytecodeCorrupt;
                    }
                    try st.saveCaptureCheck(safety, st.registerSlot(reg), value);
                    continue :main;
                },
                .loop => {
                    const reg = try st.readU8At(safety, st.pc);
                    const offset: i32 = @bitCast(try st.readU32At(safety, st.pc + 1));
                    st.pc += 5;
                    if (comptime safety == .checked) {
                        if (reg >= st.s.register_count or reg >= register_count_max) return error.BytecodeCorrupt;
                    }
                    const value = try st.readRegisterValue(safety, reg);
                    if (comptime safety == .checked) {
                        if (value == 0) return error.BytecodeCorrupt;
                    }
                    const next_value = value - 1;
                    try st.saveCaptureCheck(safety, st.registerSlot(reg), next_value);
                    if (next_value != 0) {
                        st.pc = try st.pcWithOffset(safety, offset);
                        try st.s.pollTimeout();
                    }
                    continue :main;
                },
                .loop_split_goto_first, .loop_split_next_first, .loop_check_adv_split_goto_first, .loop_check_adv_split_next_first => {
                    const reg = try st.readU8At(safety, st.pc);
                    const limit = try st.readU32At(safety, st.pc + 1);
                    const offset: i32 = @bitCast(try st.readU32At(safety, st.pc + 5));
                    st.pc += 9;
                    if (comptime safety == .checked) {
                        if (reg >= st.s.register_count or reg >= register_count_max) return error.BytecodeCorrupt;
                    }
                    const needs_advance_check = opcode == .loop_check_adv_split_goto_first or opcode == .loop_check_adv_split_next_first;
                    if (comptime safety == .checked) {
                        if (needs_advance_check and (@as(usize, reg) + 1 >= st.s.register_count or @as(usize, reg) + 1 >= register_count_max)) return error.BytecodeCorrupt;
                    }
                    const value = try st.readRegisterValue(safety, reg);
                    if (comptime safety == .checked) {
                        if (value == 0) return error.BytecodeCorrupt;
                    }
                    const next_value = value - 1;
                    try st.saveCaptureCheck(safety, st.registerSlot(reg), next_value);
                    if (next_value > limit) {
                        st.pc = try st.pcWithOffset(safety, offset);
                        try st.s.pollTimeout();
                    } else {
                        if (needs_advance_check and st.capture[st.registerSlot(@as(usize, reg) + 1)] == st.cptr and next_value != limit) {
                            break :dispatch_once;
                        }
                        if (next_value != 0) {
                            const pc1 = if (opcode == .loop_split_next_first or opcode == .loop_check_adv_split_next_first)
                                try st.pcWithOffset(safety, offset)
                            else
                                st.pc;
                            if (opcode == .loop_split_goto_first or opcode == .loop_check_adv_split_goto_first) st.pc = try st.pcWithOffset(safety, offset);
                            try st.pushExecState(safety, pc1, .split);
                        }
                    }
                    continue :main;
                },
                .set_char_pos => {
                    const reg = try st.readU8At(safety, st.pc);
                    st.pc += 1;
                    if (comptime safety == .checked) {
                        if (reg >= st.s.register_count or reg >= register_count_max) return error.BytecodeCorrupt;
                    }
                    try st.saveCaptureCheck(safety, st.registerSlot(reg), st.cptr);
                    continue :main;
                },
                .check_advance => {
                    const reg = try st.readU8At(safety, st.pc);
                    st.pc += 1;
                    if (comptime safety == .checked) {
                        if (reg >= st.s.register_count or reg >= register_count_max) return error.BytecodeCorrupt;
                    }
                    if ((try st.readRegisterValue(safety, reg)) == st.cptr) break :dispatch_once;
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
                    const n = try st.getU8(safety);
                    const pc1 = st.pc;
                    try st.ensurePc(safety, st.pc, n);
                    st.pc += @as(usize, n);

                    var i: usize = 0;
                    while (i < n) : (i += 1) {
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
                                        const c1 = st.getCharAtBounded(safety, cbuf_type, &capture_pos, capture_end) orelse return error.BytecodeCorrupt;
                                        const c2 = st.getCharUnchecked(cbuf_type);
                                        if (c1 != c2) break :dispatch_once;
                                    }
                                } else if (!st.matchRawForward(safety, cbuf_type, capture_start, capture_end)) break :dispatch_once;
                            } else if (opcode == .backward_back_reference) {
                                if (comptime cbuf_type == .utf16_unicode) {
                                    var capture_pos = capture_end;
                                    while (capture_pos > capture_start) {
                                        if (st.cptr == 0) break :dispatch_once;
                                        const c1 = st.getPrevCharAtBounded(safety, cbuf_type, &capture_pos, capture_start) orelse return error.BytecodeCorrupt;
                                        const c2 = st.getPrevCharAtBounded(safety, cbuf_type, &st.cptr, 0) orelse break :dispatch_once;
                                        if (c1 != c2) break :dispatch_once;
                                    }
                                } else if (!st.matchRawBackward(safety, cbuf_type, capture_start, capture_end)) break :dispatch_once;
                            } else if (opcode == .back_reference_i) {
                                var capture_pos = capture_start;
                                while (capture_pos < capture_end) {
                                    if (st.cptr >= st.cbuf_end) break :dispatch_once;
                                    var c1 = st.getCharAtBounded(safety, cbuf_type, &capture_pos, capture_end) orelse return error.BytecodeCorrupt;
                                    var c2_code = st.getCharUnchecked(cbuf_type);
                                    c1 = lreCanonicalize(c1, st.s.is_unicode);
                                    c2_code = lreCanonicalize(c2_code, st.s.is_unicode);
                                    if (c1 != c2_code) break :dispatch_once;
                                }
                            } else {
                                var capture_pos = capture_end;
                                while (capture_pos > capture_start) {
                                    if (st.cptr == 0) break :dispatch_once;
                                    var c1 = st.getPrevCharAtBounded(safety, cbuf_type, &capture_pos, capture_start) orelse return error.BytecodeCorrupt;
                                    var c2 = st.getPrevCharAtBounded(safety, cbuf_type, &st.cptr, 0) orelse break :dispatch_once;
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
                    const n = try st.getU16(safety);
                    if (n == 0) return error.BytecodeCorrupt;
                    try st.ensurePc(safety, st.pc, @as(usize, n) * 4);
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
                    const n = try st.getU16(safety);
                    if (n == 0) return error.BytecodeCorrupt;
                    try st.ensurePc(safety, st.pc, @as(usize, n) * 8);
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

        var items = st.stack_buf;
        while (true) {
            if (st.bp == 0) return false;
            while (st.sp > st.bp) {
                if (comptime safety == .checked) {
                    if (st.sp < 2) return error.BytecodeCorrupt;
                }
                const slot = items[st.sp - 2];
                if (comptime safety == .checked) {
                    if (slot >= st.s.alloc_count) return error.BytecodeCorrupt;
                }
                st.capture[slot] = items[st.sp - 1];
                st.sp -= 2;
            }

            if (comptime safety == .checked) {
                if (st.sp < frame_entry_count) return error.BytecodeCorrupt;
            }
            st.pc = @ptrFromInt(items[st.sp - 3]);
            try st.ensurePc(safety, st.pc, 0);
            st.cptr = items[st.sp - 2];
            const meta = items[st.sp - 1];
            const typ = try decodeExecState(safety, meta);
            st.bp = execStatePrevBp(meta);
            st.sp -= frame_entry_count;
            if (typ != .lookahead) break;
            items = st.stack_buf;
        }
        try st.s.pollTimeout();
        continue :main;
    }
}

fn writeMatch(bytecode: []const u8, total_capture_count: usize, captures: [*]const usize, result: *Match) void {
    const start = slotOptional(captures[0]) orelse 0;
    const end = slotOptional(captures[1]) orelse start;
    result.* = .{
        .start = start,
        .end = end,
        .capture_count = total_capture_count - 1,
    };
    var i: usize = 0;
    while (i < result.capture_count) : (i += 1) {
        const capture_index = i + 1;
        result.captures[i] = .{
            .start = slotOptional(captures[2 * capture_index]),
            .end = slotOptional(captures[2 * capture_index + 1]),
            .name = groupName(bytecode, capture_index),
        };
    }
}

fn parseHeader(bytecode: []const u8) !REBytecodeHeader {
    if (bytecode.len < header_len) return error.BytecodeCorrupt;
    const bytecode_len = std.mem.readInt(u32, bytecode[re_header_bytecode_len..header_len], .little);
    if (header_len + bytecode_len > bytecode.len) return error.BytecodeCorrupt;
    return .{
        .flags = std.mem.readInt(u16, bytecode[0..2], .little),
        .capture_count = bytecode[re_header_capture_count],
        .register_count = bytecode[re_header_register_count],
        .bytecode_len = bytecode_len,
    };
}

fn checkedAllocCount(header: REBytecodeHeader) !usize {
    if (header.capture_count == 0 or header.capture_count > max_captures) return error.BytecodeCorrupt;
    if (header.register_count > register_count_max) return error.BytecodeCorrupt;
    return header.capture_count * 2 + header.register_count;
}

inline fn decodeOp(byte: u8) ?REOPCodeEnum {
    if (byte > @intFromEnum(REOPCodeEnum.loop_not_class8_g)) return null;
    return @enumFromInt(byte);
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

fn writeHeader(buf: []u8, flag_bits: u16, captures: u8, stack_size: u8, code_len: u32) void {
    std.mem.writeInt(u16, buf[0..2], flag_bits, .little);
    buf[re_header_capture_count] = captures;
    buf[re_header_register_count] = stack_size;
    std.mem.writeInt(u32, buf[re_header_bytecode_len..header_len], code_len, .little);
}

const regex_bytecode = @This();

pub const CompileError = std.mem.Allocator.Error || error{
    InvalidPattern,
    Unsupported,
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

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, flags_str: []const u8) CompileError![]u8 {
    const re_flags = try parseFlags(flags_str);

    var s = REParseState{
        .allocator = allocator,
        .byte_code = .empty,
        .buf_start = pattern,
        .buf_end = pattern.len,
        .re_flags = re_flags,
        .is_unicode = (re_flags & (regex_bytecode.flags.unicode | regex_bytecode.flags.unicode_sets)) != 0,
        .unicode_sets = (re_flags & regex_bytecode.flags.unicode_sets) != 0,
        .ignore_case = (re_flags & regex_bytecode.flags.ignore_case) != 0,
        .multi_line = (re_flags & regex_bytecode.flags.multiline) != 0,
        .dotall = (re_flags & regex_bytecode.flags.dot_all) != 0,
    };
    errdefer s.byte_code.deinit(allocator);
    defer s.group_names.deinit(allocator);

    try s.emitHeader();
    if ((re_flags & regex_bytecode.flags.sticky) == 0) {
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

fn parseFlags(flag_bytes: []const u8) CompileError!u16 {
    var seen: [256]bool = [_]bool{false} ** 256;
    var re_flags: u16 = 0;
    var saw_u = false;
    var saw_v = false;
    for (flag_bytes) |flag| {
        if (seen[flag]) return error.InvalidPattern;
        seen[flag] = true;
        switch (flag) {
            'd' => re_flags |= regex_bytecode.flags.indices,
            'g' => re_flags |= regex_bytecode.flags.global,
            'i' => {
                re_flags |= regex_bytecode.flags.ignore_case;
            },
            'm' => {
                re_flags |= regex_bytecode.flags.multiline;
            },
            's' => {
                re_flags |= regex_bytecode.flags.dot_all;
            },
            'u' => {
                re_flags |= regex_bytecode.flags.unicode;
                saw_u = true;
            },
            'v' => {
                re_flags |= regex_bytecode.flags.unicode_sets;
                saw_v = true;
            },
            'y' => {
                re_flags |= regex_bytecode.flags.sticky;
            },
            else => return error.InvalidPattern,
        }
    }
    if (saw_u and saw_v) return error.InvalidPattern;
    return re_flags;
}

const REParseState = struct {
    allocator: std.mem.Allocator,
    byte_code: std.ArrayList(u8),
    buf_ptr: usize = 0,
    buf_end: usize,
    buf_start: []const u8,
    re_flags: u16,
    is_unicode: bool,
    unicode_sets: bool,
    ignore_case: bool,
    multi_line: bool,
    dotall: bool,
    group_name_scope: u8 = 0,
    capture_count: u8 = 1,
    total_capture_count: i32 = -1,
    has_named_captures: i32 = -1,
    @"opaque": ?*anyopaque = null,
    group_names: std.ArrayList(u8) = .empty,

    const CaptureParseResult = struct {
        count: u16,
        has_named_captures: bool,
    };

    fn putGroupName(self: *REParseState, maybe_name: ?[]const u8) CompileError!void {
        if (maybe_name) |name| {
            try self.group_names.appendSlice(self.allocator, name);
            try self.group_names.append(self.allocator, 0);
            try self.group_names.append(self.allocator, self.group_name_scope);
            self.has_named_captures = 1;
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

    fn reCountCaptures(self: *REParseState) CompileError!u16 {
        if (self.total_capture_count < 0) {
            const result = try self.reParseCaptures(null, false);
            self.total_capture_count = @intCast(result.count);
            self.has_named_captures = @intFromBool(result.has_named_captures);
        }
        return @intCast(self.total_capture_count);
    }

    fn reHasNamedCaptures(self: *REParseState) CompileError!bool {
        if (self.has_named_captures < 0) _ = try self.reCountCaptures();
        return self.has_named_captures != 0;
    }

    fn emitHeader(self: *REParseState) !void {
        try self.byte_code.appendNTimes(self.allocator, 0, header_len);
    }

    fn patchHeader(self: *REParseState) !void {
        const bytecode_len = self.byte_code.items.len - header_len;
        const stack_size = try reComputeRegisterCount(self.byte_code.items[header_len..]);
        const has_named_groups = self.group_names.items.len > @as(usize, self.capture_count - 1) * group_name_trailer_len;
        if (has_named_groups) try self.byte_code.appendSlice(self.allocator, self.group_names.items);
        const flag_bits = self.re_flags | if (has_named_groups) regex_bytecode.flags.named_groups else 0;
        std.mem.writeInt(u16, self.byte_code.items[0..2], flag_bits, .little);
        self.byte_code.items[2] = self.capture_count;
        self.byte_code.items[3] = stack_size;
        std.mem.writeInt(u32, self.byte_code.items[4..8], @intCast(bytecode_len), .little);
    }

    fn patchSearchLiteralPrefix(self: *REParseState) void {
        if ((self.re_flags & regex_bytecode.flags.sticky) != 0) return;
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
        code[prelude + 5] = opByte(.scan_until_char8);
        code[prelude + 6] = @intCast(needle_u16);
        std.mem.writeInt(u32, code[prelude + 7 ..][0..4], @bitCast(@as(i32, -11)), .little);
    }

    fn reParseDisjunction(self: *REParseState, terminator: ?u8, is_backward_dir: bool) CompileError!void {
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
                if (is_backward_dir) try self.reEmitOp(.prev);
                try self.reEmitOp(if (self.dotall) .any else .dot);
                if (is_backward_dir) try self.reEmitOp(.prev);
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
                try self.emitCharacterAtom(canonicalizeLiteral(cp, self.ignore_case, self.is_unicode), is_backward_dir);
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
                return .{ .start = start, .quantifiable = false, .capture_count_before = self.capture_count };
            },
            's', 'S' => {
                self.buf_ptr += 2;
                if (is_backward_dir) try self.reEmitOp(.prev);
                try self.reEmitOp(if (escaped == 's') .space else .not_space);
                if (is_backward_dir) try self.reEmitOp(.prev);
                return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
            },
            'd', 'D', 'w', 'W' => {
                self.buf_ptr += 2;
                var ranges = CharRange.init(self.allocator);
                defer ranges.deinit();
                try addClassEscape(&ranges, escaped);
                if (is_backward_dir) try self.reEmitOp(.prev);
                try self.reEmitRange(&ranges);
                if (is_backward_dir) try self.reEmitOp(.prev);
                return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
            },
            '1'...'9' => {
                const escape_start = self.buf_ptr;
                const capture_index = try self.parseDecimalEscape();
                if (capture_index == 0 or capture_index >= try self.reCountCaptures()) {
                    if (self.is_unicode) return error.InvalidPattern;
                    self.buf_ptr = escape_start + 1;
                    const cp = try self.parseLegacyDecimalEscape();
                    try self.emitCharacterAtom(canonicalizeLiteral(cp, self.ignore_case, self.is_unicode), is_backward_dir);
                    return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
                }
                try self.emitBackReference(is_backward_dir, &.{@intCast(capture_index)});
                return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
            },
            '0' => {
                self.buf_ptr += 2;
                if (self.buf_ptr < self.buf_start.len and isDigit(self.buf_start[self.buf_ptr]) and self.is_unicode) return error.InvalidPattern;
                const cp = try self.parseLegacyOctalAfterZero();
                try self.emitCharacterAtom(canonicalizeLiteral(cp, self.ignore_case, self.is_unicode), is_backward_dir);
                return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
            },
            'x' => {
                const escape_start = self.buf_ptr;
                const cp = self.parseFixedHexEscape(2) catch |err| {
                    self.buf_ptr = escape_start;
                    if (self.is_unicode) return err;
                    self.buf_ptr += 2;
                    try self.emitCharacterAtom(canonicalizeLiteral('x', self.ignore_case, self.is_unicode), is_backward_dir);
                    return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
                };
                try self.emitCharacterAtom(canonicalizeLiteral(cp, self.ignore_case, self.is_unicode), is_backward_dir);
                return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
            },
            'u' => {
                const escape_start = self.buf_ptr;
                const braced = self.isBracedUnicodeEscape();
                const cp = self.parseUnicodeEscape() catch |err| {
                    self.buf_ptr = escape_start;
                    if (self.is_unicode) return err;
                    self.buf_ptr += 2;
                    try self.emitCharacterAtom(canonicalizeLiteral('u', self.ignore_case, self.is_unicode), is_backward_dir);
                    return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
                };
                const combined = if (braced) cp else try self.combineEscapedSurrogatePair(cp);
                try self.emitCharacterAtom(canonicalizeLiteral(combined, self.ignore_case, self.is_unicode), is_backward_dir);
                return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
            },
            'c' => {
                if (self.buf_ptr + 2 >= self.buf_start.len) {
                    if (self.is_unicode) return error.InvalidPattern;
                    self.buf_ptr += 2;
                    try self.emitCharacterAtom('\\', is_backward_dir);
                    try self.emitCharacterAtom('c', is_backward_dir);
                    if (self.buf_ptr < self.buf_start.len) {
                        const cp = try self.readUtf8CodePoint();
                        if (cp > 0xffff) {
                            try self.emitNonUnicodeSurrogatePairAtom(cp, is_backward_dir);
                        } else {
                            try self.emitCharacterAtom(canonicalizeLiteral(cp, self.ignore_case, self.is_unicode), is_backward_dir);
                        }
                    }
                    return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
                }
                const cp_byte = self.buf_start[self.buf_ptr + 2];
                if (!((cp_byte >= 'a' and cp_byte <= 'z') or (cp_byte >= 'A' and cp_byte <= 'Z'))) {
                    if (self.is_unicode) return error.InvalidPattern;
                    self.buf_ptr += 2;
                    try self.emitCharacterAtom('\\', is_backward_dir);
                    try self.emitCharacterAtom('c', is_backward_dir);
                    if (self.buf_ptr < self.buf_start.len) {
                        const cp = try self.readUtf8CodePoint();
                        if (cp > 0xffff) {
                            try self.emitNonUnicodeSurrogatePairAtom(cp, is_backward_dir);
                        } else {
                            try self.emitCharacterAtom(canonicalizeLiteral(cp, self.ignore_case, self.is_unicode), is_backward_dir);
                        }
                    }
                    return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
                }
                const cp: u21 = cp_byte & 0x1f;
                self.buf_ptr += 3;
                try self.emitCharacterAtom(canonicalizeLiteral(cp, self.ignore_case, self.is_unicode), is_backward_dir);
                return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
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
                try self.emitCharacterAtom(canonicalizeLiteral(cp, self.ignore_case, self.is_unicode), is_backward_dir);
                return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
            },
            'p', 'P' => {
                if (!self.is_unicode) {
                    self.buf_ptr += 2;
                    try self.emitCharacterAtom(canonicalizeLiteral(escaped, self.ignore_case, self.is_unicode), is_backward_dir);
                    return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
                }
                if (self.unicode_sets) {
                    if (try self.parseStringPropertyEscape()) |string_set| {
                        var set = string_set;
                        defer set.deinit();
                        try self.reEmitStringList(&set, is_backward_dir);
                        return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
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
                if (is_backward_dir) try self.reEmitOp(.prev);
                try self.reEmitRange(&ranges);
                if (is_backward_dir) try self.reEmitOp(.prev);
                return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
            },
            'k' => {
                const escape_start = self.buf_ptr;
                if (self.buf_ptr + 2 >= self.buf_start.len or self.buf_start[self.buf_ptr + 2] != '<') {
                    if (self.is_unicode or try self.reHasNamedCaptures()) return error.InvalidPattern;
                    self.buf_ptr += 2;
                    try self.emitCharacterAtom(canonicalizeLiteral('k', self.ignore_case, self.is_unicode), is_backward_dir);
                    return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
                }
                self.buf_ptr += 3;
                const name = self.parseGroupName() catch |err| {
                    if (self.is_unicode or try self.reHasNamedCaptures()) return err;
                    self.buf_ptr = escape_start + 2;
                    try self.emitCharacterAtom(canonicalizeLiteral('k', self.ignore_case, self.is_unicode), is_backward_dir);
                    return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
                };
                var is_forward = false;
                var capture_count = try self.findGroupName(name, false);
                if (capture_count == 0) {
                    const parsed = try self.reParseCaptures(name, false);
                    capture_count = parsed.count;
                    if (capture_count == 0) {
                        if (self.is_unicode or try self.reHasNamedCaptures()) return error.InvalidPattern;
                        self.buf_ptr = escape_start + 2;
                        try self.emitCharacterAtom(canonicalizeLiteral('k', self.ignore_case, self.is_unicode), is_backward_dir);
                        return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
                    }
                    is_forward = true;
                }
                try self.reEmitOpU8(self.backReferenceOp(is_backward_dir), @intCast(capture_count));
                if (is_forward) {
                    _ = try self.reParseCaptures(name, true);
                } else {
                    _ = try self.findGroupName(name, true);
                }
                return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
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
                    try self.emitCharacterAtom(canonicalizeLiteral(cp, self.ignore_case, self.is_unicode), is_backward_dir);
                    return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
                }
                if (isSyntaxEscape(escaped) or escaped == '/') {
                    self.buf_ptr += 2;
                    try self.emitCharacterAtom(canonicalizeLiteral(escaped, self.ignore_case, self.is_unicode), is_backward_dir);
                    return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
                }
                if (self.is_unicode) return error.InvalidPattern;
                self.buf_ptr += 2;
                try self.emitCharacterAtom(canonicalizeLiteral(escaped, self.ignore_case, self.is_unicode), is_backward_dir);
                return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
            },
        }
    }

    fn reParseCharClass(self: *REParseState, start: usize, is_backward_dir: bool) CompileError!Atom {
        self.buf_ptr += 1;
        if (self.unicode_sets) {
            var set = try self.reParseNestedClass();
            defer set.deinit();
            try self.reEmitStringList(&set, is_backward_dir);
            return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
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
                if (is_backward_dir) try self.reEmitOp(.prev);
                try self.reEmitRange(&ranges);
                if (is_backward_dir) try self.reEmitOp(.prev);
                return .{ .start = start, .quantifiable = true, .capture_count_before = self.capture_count };
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
            try self.strings.append(self.ranges.allocator, s);
        }

        fn unionWith(self: *REStringList, other: *const REStringList) !void {
            try self.ranges.addSet(&other.ranges);
            for (other.strings.items) |s| {
                if (self.containsString(s)) continue;
                const copy = try self.ranges.allocator.dupe(u21, s);
                errdefer self.ranges.allocator.free(copy);
                try self.strings.append(self.ranges.allocator, copy);
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

    /// v-mode ClassSetExpression body. Entered just past the opening `[`
    /// (top-level or nested); consumes through the matching `]`. The
    /// expression is one of ClassUnion, ClassIntersection (`&&`-chain) or
    /// ClassDifference (`--`-chain) — operators must not be mixed at one
    /// level. Returns the resolved class set, case-folded per operand when
    /// ignoring case and complemented when the class is negated (negation
    /// of a set that may contain strings is a SyntaxError).
    fn reParseNestedClass(self: *REParseState) CompileError!REStringList {
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

    const REStringListOperandResult = struct { set: REStringList, was_range: bool };

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

        // Sort strings by descending length (stable, preserving insertion
        // order between equal lengths per spec ordering). The empty string,
        // if present, lands last.
        const items = set.strings.items;
        std.sort.block([]u21, items, {}, struct {
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
                if (self.is_unicode) return error.InvalidPattern;
                try addAtomToCharRange(&ranges, first, self.ignore_case, self.is_unicode);
                return ranges;
            }
            const hyphen_index = self.buf_ptr;
            self.buf_ptr += 1;
            const second = try self.getClassAtom();
            if (second != .code_point) {
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

    const REStringListBuildContext = struct {
        s: *REParseState,
        set: *REStringList,
    };

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
        try ctx.set.strings.append(ctx.s.allocator, copy);
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
        var i: usize = 0;
        while (i < digit_count) : (i += 1) {
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
            var i: usize = 0;
            while (i < range_count) : (i += 1) {
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

const REClassAtom = union(enum) {
    code_point: u21,
    ranges: CharRange,
};

const CharRange = unicode.CharRange;

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

inline fn fromHex(byte: u8) ?u21 {
    if (byte >= '0' and byte <= '9') return byte - '0';
    if (byte >= 'A' and byte <= 'F') return byte - 'A' + 10;
    if (byte >= 'a' and byte <= 'f') return byte - 'a' + 10;
    return null;
}

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

inline fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

inline fn lreIsWordByte(byte: u8) bool {
    return (lre_ctype_bits[byte] & (lre_ctype_upper | lre_ctype_lower | lre_ctype_under | lre_ctype_digit)) != 0;
}
