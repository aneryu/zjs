const std = @import("std");
const unicode = @import("unicode.zig");

pub const max_captures = 256;
const max_stack = 256;

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

pub const ExecStatus = struct {
    result: enum {
        match,
        no_match,
        out_of_range,
        not_available,
    },
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

const Header = struct {
    flags: u16,
    capture_count: usize,
    stack_size: usize,
    bytecode_len: usize,
};

const header_len = 8;
const cp_ls = 0x2028;
const cp_ps = 0x2029;
const int32_max: u32 = 0x7fffffff;

const Op = enum(u8) {
    invalid,
    char8,
    char16,
    char32,
    dot,
    any,
    line_start,
    line_end,
    goto_,
    split_goto_first,
    split_next_first,
    match,
    save_start,
    save_end,
    save_reset,
    loop,
    push_i32,
    drop,
    word_boundary,
    not_word_boundary,
    back_reference,
    backward_back_reference,
    range,
    range32,
    lookahead,
    negative_lookahead,
    push_char_pos,
    check_advance,
    prev,
    simple_greedy_quant,
};

const CbufType = enum {
    latin1,
    utf16_units,
    utf16_unicode,
};

const StateType = enum {
    split,
    lookahead,
    negative_lookahead,
    greedy_quant,
};

const BacktrackState = struct {
    typ: StateType,
    stack_len: usize,
    count: usize,
    cpos: usize,
    pc: usize,
    capture_start: usize,
    capture_len: usize,
    stack_start: usize,
};

const JSContext = struct {
    allocator: std.mem.Allocator,
    input: Input,
    cbuf_type: CbufType,
    bytecode: []const u8,
    bytecode_end: usize,
    capture_count: usize,
    stack_size_max: usize,
    multi_line: bool,
    ignore_case: bool,
    is_unicode: bool,
    state_stack: std.ArrayList(BacktrackState),
    capture_snapshots: std.ArrayList(?usize),
    stack_snapshots: std.ArrayList(usize),

    fn deinit(self: *JSContext) void {
        self.state_stack.deinit(self.allocator);
        self.capture_snapshots.deinit(self.allocator);
        self.stack_snapshots.deinit(self.allocator);
    }

    fn pushState(
        self: *JSContext,
        captures: *const [max_captures * 2]?usize,
        stack: *const [max_stack]usize,
        stack_len: usize,
        pc: usize,
        cpos: usize,
        typ: StateType,
        count: usize,
    ) !void {
        if (stack_len > max_stack) return error.BytecodeCorrupt;
        const capture_slots = captureSlotCount(self.capture_count);
        const capture_start = self.capture_snapshots.items.len;
        const stack_start = self.stack_snapshots.items.len;
        try self.capture_snapshots.appendSlice(self.allocator, captures[0..capture_slots]);
        errdefer self.capture_snapshots.shrinkRetainingCapacity(capture_start);
        try self.stack_snapshots.appendSlice(self.allocator, stack[0..stack_len]);
        errdefer self.stack_snapshots.shrinkRetainingCapacity(stack_start);
        const state = BacktrackState{
            .typ = typ,
            .stack_len = stack_len,
            .count = count,
            .cpos = cpos,
            .pc = pc,
            .capture_start = capture_start,
            .capture_len = capture_slots,
            .stack_start = stack_start,
        };
        try self.state_stack.append(self.allocator, state);
    }

    fn dropState(self: *JSContext, state: BacktrackState) void {
        self.capture_snapshots.shrinkRetainingCapacity(state.capture_start);
        self.stack_snapshots.shrinkRetainingCapacity(state.stack_start);
    }

    fn popState(self: *JSContext) ?BacktrackState {
        const state = self.state_stack.pop() orelse return null;
        self.dropState(state);
        return state;
    }

    fn restoreState(
        self: *JSContext,
        state: *const BacktrackState,
        captures: *[max_captures * 2]?usize,
        stack: *[max_stack]usize,
        stack_len: *usize,
        pc: *usize,
        cpos: *usize,
        restore_captures: bool,
    ) void {
        if (restore_captures) @memcpy(captures[0..state.capture_len], self.capture_snapshots.items[state.capture_start..][0..state.capture_len]);
        stack_len.* = state.stack_len;
        @memcpy(stack[0..state.stack_len], self.stack_snapshots.items[state.stack_start..][0..state.stack_len]);
        pc.* = state.pc;
        cpos.* = state.cpos;
    }

    fn resolveResult(
        self: *JSContext,
        captures: *[max_captures * 2]?usize,
        stack: *[max_stack]usize,
        stack_len: *usize,
        pc: *usize,
        cpos: *usize,
        initial_ret: bool,
    ) !?bool {
        var ret = initial_ret;
        while (true) {
            if (self.state_stack.items.len == 0) return ret;
            const last_index = self.state_stack.items.len - 1;
            var state = &self.state_stack.items[last_index];
            switch (state.typ) {
                .split => {
                    if (!ret) {
                        self.restoreState(state, captures, stack, stack_len, pc, cpos, true);
                        _ = self.popState().?;
                        return null;
                    }
                },
                .greedy_quant => {
                    if (!ret) {
                        self.restoreState(state, captures, stack, stack_len, pc, cpos, true);
                        const char_count = try self.readU32(state.pc + 12);
                        var i: u32 = 0;
                        while (i < char_count) : (i += 1) {
                            cpos.* = try self.prevCharPos(cpos.*);
                        }
                        pc.* = try addOffset(state.pc + 16, try self.readI32(state.pc));
                        state.cpos = cpos.*;
                        state.count -= 1;
                        if (state.count == 0) _ = self.popState().?;
                        return null;
                    }
                },
                .lookahead, .negative_lookahead => {
                    ret = (state.typ == .lookahead and ret) or
                        (state.typ == .negative_lookahead and !ret);
                    if (ret) {
                        const restore_captures = state.typ == .negative_lookahead;
                        self.restoreState(state, captures, stack, stack_len, pc, cpos, restore_captures);
                        _ = self.popState().?;
                        return null;
                    }
                },
            }
            _ = self.popState().?;
        }
    }

    fn readU8(self: *const JSContext, index: usize) !u8 {
        if (index >= self.bytecode_end) return error.BytecodeCorrupt;
        return self.bytecode[index];
    }

    fn readU16(self: *const JSContext, index: usize) !u16 {
        if (index + 2 > self.bytecode_end) return error.BytecodeCorrupt;
        return std.mem.readInt(u16, self.bytecode[index..][0..2], .little);
    }

    fn readU32(self: *const JSContext, index: usize) !u32 {
        if (index + 4 > self.bytecode_end) return error.BytecodeCorrupt;
        return std.mem.readInt(u32, self.bytecode[index..][0..4], .little);
    }

    fn readI32(self: *const JSContext, index: usize) !i32 {
        const raw = try self.readU32(index);
        return @bitCast(raw);
    }

    fn charAt(self: *const JSContext, pos: usize) ?CharRead {
        return switch (self.input) {
            .latin1 => |bytes| {
                if (pos >= bytes.len) return null;
                return .{ .code_point = bytes[pos], .next = pos + 1 };
            },
            .utf16 => |units| {
                if (pos >= units.len) return null;
                var code_point: u21 = units[pos];
                var next = pos + 1;
                if (self.cbuf_type == .utf16_unicode and isHiSurrogate(code_point) and next < units.len and isLoSurrogate(units[next])) {
                    code_point = fromSurrogate(@intCast(code_point), units[next]);
                    next += 1;
                }
                return .{ .code_point = code_point, .next = next };
            },
        };
    }

    fn prevCharAt(self: *const JSContext, pos: usize) ?CharRead {
        if (pos == 0) return null;
        return switch (self.input) {
            .latin1 => |bytes| {
                if (pos > bytes.len) return null;
                return .{ .code_point = bytes[pos - 1], .next = pos - 1 };
            },
            .utf16 => |units| {
                if (pos > units.len) return null;
                var prev = pos - 1;
                var code_point: u21 = units[prev];
                if (self.cbuf_type == .utf16_unicode and isLoSurrogate(code_point) and prev > 0 and isHiSurrogate(units[prev - 1])) {
                    prev -= 1;
                    code_point = fromSurrogate(units[prev], @intCast(code_point));
                }
                return .{ .code_point = code_point, .next = prev };
            },
        };
    }

    fn prevCharPos(self: *const JSContext, pos: usize) !usize {
        return (self.prevCharAt(pos) orelse return error.BytecodeCorrupt).next;
    }
};

fn captureSlotCount(capture_count: usize) usize {
    return capture_count * 2;
}

fn initCaptures(captures: *[max_captures * 2]?usize, capture_count: usize) void {
    @memset(captures[0..captureSlotCount(capture_count)], null);
}

const CharRead = struct {
    code_point: u21,
    next: usize,
};

const BacktrackResult = union(enum) {
    match: bool,
    position: usize,
};

pub fn captureCount(bytecode: []const u8) usize {
    if (bytecode.len <= headerCaptureCount()) return 0;
    return bytecode[headerCaptureCount()];
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
        if (capture_index == one_based_capture_index) {
            if (end == pos) return null;
            return bytecode[pos..end];
        }
        pos = end + 1;
    }
    return null;
}

pub fn exec(allocator: std.mem.Allocator, bytecode: []const u8, input: Input, start_index: usize) !ExecStatus {
    const header = try parseHeader(bytecode);
    if (header.capture_count == 0 or header.capture_count > max_captures) return error.BytecodeCorrupt;
    if (header.stack_size > max_stack) return error.BytecodeCorrupt;
    if (start_index > input.len()) return .{ .result = .out_of_range };

    var ctx = JSContext{
        .allocator = allocator,
        .input = input,
        .cbuf_type = switch (input) {
            .latin1 => .latin1,
            .utf16 => if ((header.flags & flags.unicode) != 0) .utf16_unicode else .utf16_units,
        },
        .bytecode = bytecode,
        .bytecode_end = header_len + header.bytecode_len,
        .capture_count = header.capture_count,
        .stack_size_max = header.stack_size,
        .multi_line = (header.flags & flags.multiline) != 0,
        .ignore_case = (header.flags & flags.ignore_case) != 0,
        .is_unicode = (header.flags & flags.unicode) != 0,
        .state_stack = .empty,
        .capture_snapshots = .empty,
        .stack_snapshots = .empty,
    };
    defer ctx.deinit();

    if (hasSearchPrefix(bytecode, header)) {
        return try execSearchLoop(&ctx, bytecode, header, start_index);
    }

    var captures: [max_captures * 2]?usize = undefined;
    initCaptures(&captures, header.capture_count);
    var stack: [max_stack]usize = undefined;
    const result = try execBacktrack(&ctx, &captures, &stack, 0, header_len, start_index, false);
    return switch (result) {
        .position => error.BytecodeCorrupt,
        .match => |matched| if (matched)
            makeMatch(bytecode, header.capture_count, &captures)
        else
            .{ .result = .no_match },
    };
}

pub fn testMatch(allocator: std.mem.Allocator, bytecode: []const u8, input: Input, start_index: usize) !bool {
    const header = try parseHeader(bytecode);
    if (header.capture_count == 0 or header.capture_count > max_captures) return error.BytecodeCorrupt;
    if (header.stack_size > max_stack) return error.BytecodeCorrupt;
    if (start_index > input.len()) return false;

    var ctx = JSContext{
        .allocator = allocator,
        .input = input,
        .cbuf_type = switch (input) {
            .latin1 => .latin1,
            .utf16 => if ((header.flags & flags.unicode) != 0) .utf16_unicode else .utf16_units,
        },
        .bytecode = bytecode,
        .bytecode_end = header_len + header.bytecode_len,
        .capture_count = header.capture_count,
        .stack_size_max = header.stack_size,
        .multi_line = (header.flags & flags.multiline) != 0,
        .ignore_case = (header.flags & flags.ignore_case) != 0,
        .is_unicode = (header.flags & flags.unicode) != 0,
        .state_stack = .empty,
        .capture_snapshots = .empty,
        .stack_snapshots = .empty,
    };
    defer ctx.deinit();

    if (hasSearchPrefix(bytecode, header)) {
        return try testSearchLoop(&ctx, header, start_index);
    }

    var captures: [max_captures * 2]?usize = undefined;
    initCaptures(&captures, header.capture_count);
    var stack: [max_stack]usize = undefined;
    const result = try execBacktrack(&ctx, &captures, &stack, 0, header_len, start_index, false);
    return switch (result) {
        .position => error.BytecodeCorrupt,
        .match => |matched| matched,
    };
}

fn execSearchLoop(ctx: *JSContext, bytecode: []const u8, header: Header, start_index: usize) !ExecStatus {
    const body_pc = header_len + search_prefix_len;
    var cpos = start_index;

    while (true) {
        var captures: [max_captures * 2]?usize = undefined;
        initCaptures(&captures, header.capture_count);
        var stack: [max_stack]usize = undefined;
        ctx.state_stack.clearRetainingCapacity();
        ctx.capture_snapshots.clearRetainingCapacity();
        ctx.stack_snapshots.clearRetainingCapacity();
        const result = try execBacktrack(ctx, &captures, &stack, 0, body_pc, cpos, false);
        switch (result) {
            .position => return error.BytecodeCorrupt,
            .match => |matched| if (matched) return makeMatch(bytecode, header.capture_count, &captures),
        }

        if (cpos >= ctx.input.len()) return .{ .result = .no_match };
        cpos = (ctx.charAt(cpos) orelse return error.BytecodeCorrupt).next;
    }
}

fn testSearchLoop(ctx: *JSContext, header: Header, start_index: usize) !bool {
    const body_pc = header_len + search_prefix_len;
    var cpos = start_index;

    while (true) {
        var captures: [max_captures * 2]?usize = undefined;
        initCaptures(&captures, header.capture_count);
        var stack: [max_stack]usize = undefined;
        ctx.state_stack.clearRetainingCapacity();
        ctx.capture_snapshots.clearRetainingCapacity();
        ctx.stack_snapshots.clearRetainingCapacity();
        const result = try execBacktrack(ctx, &captures, &stack, 0, body_pc, cpos, false);
        switch (result) {
            .position => return error.BytecodeCorrupt,
            .match => |matched| if (matched) return true,
        }

        if (cpos >= ctx.input.len()) return false;
        cpos = (ctx.charAt(cpos) orelse return error.BytecodeCorrupt).next;
    }
}

fn execBacktrack(
    ctx: *JSContext,
    captures: *[max_captures * 2]?usize,
    stack: *[max_stack]usize,
    initial_stack_len: usize,
    initial_pc: usize,
    initial_cpos: usize,
    no_recurse: bool,
) !BacktrackResult {
    var stack_len = initial_stack_len;
    var pc = initial_pc;
    var cpos = initial_cpos;

    main: while (true) {
        const opcode_byte = try ctx.readU8(pc);
        pc += 1;
        const opcode = decodeOp(opcode_byte) orelse return error.BytecodeCorrupt;
        switch (opcode) {
            .invalid => return error.BytecodeCorrupt,
            .match => {
                if (no_recurse) return .{ .position = cpos };
                if (try ctx.resolveResult(captures, stack, &stack_len, &pc, &cpos, true)) |done| return .{ .match = done };
            },
            .char32, .char16, .char8 => {
                const expected: u21 = switch (opcode) {
                    .char32 => blk: {
                        const value = try ctx.readU32(pc);
                        pc += 4;
                        break :blk @intCast(value);
                    },
                    .char16 => blk: {
                        const value = try ctx.readU16(pc);
                        pc += 2;
                        break :blk value;
                    },
                    .char8 => blk: {
                        const value = try ctx.readU8(pc);
                        pc += 1;
                        break :blk value;
                    },
                    else => unreachable,
                };
                var read = ctx.charAt(cpos) orelse {
                    if (try handleNoMatch(ctx, captures, stack, &stack_len, &pc, &cpos, no_recurse)) |done| return done;
                    continue :main;
                };
                if (ctx.ignore_case) read.code_point = canonicalize(read.code_point, ctx.is_unicode);
                if (expected != read.code_point) {
                    if (try handleNoMatch(ctx, captures, stack, &stack_len, &pc, &cpos, no_recurse)) |done| return done;
                    continue :main;
                }
                cpos = read.next;
            },
            .split_goto_first, .split_next_first => {
                const offset = try ctx.readI32(pc);
                pc += 4;
                const pc1 = if (opcode == .split_next_first)
                    try addOffset(pc, offset)
                else
                    pc;
                if (opcode == .split_goto_first) pc = try addOffset(pc, offset);
                try ctx.pushState(captures, stack, stack_len, pc1, cpos, .split, 0);
            },
            .lookahead, .negative_lookahead => {
                const offset = try ctx.readI32(pc);
                pc += 4;
                try ctx.pushState(
                    captures,
                    stack,
                    stack_len,
                    try addOffset(pc, offset),
                    cpos,
                    if (opcode == .lookahead) .lookahead else .negative_lookahead,
                    0,
                );
            },
            .goto_ => {
                const offset = try ctx.readI32(pc);
                pc = try addOffset(pc + 4, offset);
            },
            .line_start => {
                if (cpos == 0) continue :main;
                if (!ctx.multi_line) {
                    if (try handleNoMatch(ctx, captures, stack, &stack_len, &pc, &cpos, no_recurse)) |done| return done;
                    continue :main;
                }
                const prev = ctx.prevCharAt(cpos) orelse return error.BytecodeCorrupt;
                if (!isLineTerminator(prev.code_point)) {
                    if (try handleNoMatch(ctx, captures, stack, &stack_len, &pc, &cpos, no_recurse)) |done| return done;
                    continue :main;
                }
            },
            .line_end => {
                if (cpos == ctx.input.len()) continue :main;
                if (!ctx.multi_line) {
                    if (try handleNoMatch(ctx, captures, stack, &stack_len, &pc, &cpos, no_recurse)) |done| return done;
                    continue :main;
                }
                const current = ctx.charAt(cpos) orelse return error.BytecodeCorrupt;
                if (!isLineTerminator(current.code_point)) {
                    if (try handleNoMatch(ctx, captures, stack, &stack_len, &pc, &cpos, no_recurse)) |done| return done;
                    continue :main;
                }
            },
            .dot, .any => {
                const current = ctx.charAt(cpos) orelse {
                    if (try handleNoMatch(ctx, captures, stack, &stack_len, &pc, &cpos, no_recurse)) |done| return done;
                    continue :main;
                };
                if (opcode == .dot and isLineTerminator(current.code_point)) {
                    if (try handleNoMatch(ctx, captures, stack, &stack_len, &pc, &cpos, no_recurse)) |done| return done;
                    continue :main;
                }
                cpos = current.next;
            },
            .save_start, .save_end => {
                const capture_index = try ctx.readU8(pc);
                pc += 1;
                if (capture_index >= ctx.capture_count) return error.BytecodeCorrupt;
                const capture_slot = @as(usize, capture_index) * 2 + @intFromBool(opcode == .save_end);
                captures[capture_slot] = cpos;
            },
            .save_reset => {
                var first = try ctx.readU8(pc);
                const last = try ctx.readU8(pc + 1);
                pc += 2;
                if (last >= ctx.capture_count or first > last) return error.BytecodeCorrupt;
                while (first <= last) : (first += 1) {
                    const capture_slot = @as(usize, first) * 2;
                    captures[capture_slot] = null;
                    captures[capture_slot + 1] = null;
                }
            },
            .push_i32 => {
                if (stack_len >= ctx.stack_size_max or stack_len >= max_stack) return error.BytecodeCorrupt;
                stack[stack_len] = try ctx.readU32(pc);
                stack_len += 1;
                pc += 4;
            },
            .drop => {
                if (stack_len == 0) return error.BytecodeCorrupt;
                stack_len -= 1;
            },
            .loop => {
                if (stack_len == 0) return error.BytecodeCorrupt;
                const offset = try ctx.readI32(pc);
                pc += 4;
                stack[stack_len - 1] -= 1;
                if (stack[stack_len - 1] != 0) pc = try addOffset(pc, offset);
            },
            .push_char_pos => {
                if (stack_len >= ctx.stack_size_max or stack_len >= max_stack) return error.BytecodeCorrupt;
                stack[stack_len] = cpos;
                stack_len += 1;
            },
            .check_advance => {
                if (stack_len == 0) return error.BytecodeCorrupt;
                stack_len -= 1;
                if (stack[stack_len] == cpos) {
                    if (try handleNoMatch(ctx, captures, stack, &stack_len, &pc, &cpos, no_recurse)) |done| return done;
                    continue :main;
                }
            },
            .word_boundary, .not_word_boundary => {
                const before = if (cpos == 0) false else isWordChar((ctx.prevCharAt(cpos) orelse return error.BytecodeCorrupt).code_point);
                const after = if (cpos >= ctx.input.len()) false else isWordChar((ctx.charAt(cpos) orelse return error.BytecodeCorrupt).code_point);
                const wants_boundary = opcode == .word_boundary;
                if ((before != after) != wants_boundary) {
                    if (try handleNoMatch(ctx, captures, stack, &stack_len, &pc, &cpos, no_recurse)) |done| return done;
                    continue :main;
                }
            },
            .back_reference, .backward_back_reference => {
                const capture_index = try ctx.readU8(pc);
                pc += 1;
                if (capture_index >= ctx.capture_count) {
                    if (try handleNoMatch(ctx, captures, stack, &stack_len, &pc, &cpos, no_recurse)) |done| return done;
                    continue :main;
                }
                const capture_start = captures[2 * capture_index] orelse continue :main;
                const capture_end = captures[2 * capture_index + 1] orelse continue :main;
                if (opcode == .back_reference) {
                    var capture_pos = capture_start;
                    while (capture_pos < capture_end) {
                        var capture_char = ctx.charAt(capture_pos) orelse return error.BytecodeCorrupt;
                        var input_char = ctx.charAt(cpos) orelse {
                            if (try handleNoMatch(ctx, captures, stack, &stack_len, &pc, &cpos, no_recurse)) |done| return done;
                            continue :main;
                        };
                        if (ctx.ignore_case) {
                            capture_char.code_point = canonicalize(capture_char.code_point, ctx.is_unicode);
                            input_char.code_point = canonicalize(input_char.code_point, ctx.is_unicode);
                        }
                        if (capture_char.code_point != input_char.code_point) {
                            if (try handleNoMatch(ctx, captures, stack, &stack_len, &pc, &cpos, no_recurse)) |done| return done;
                            continue :main;
                        }
                        capture_pos = capture_char.next;
                        cpos = input_char.next;
                    }
                } else {
                    var capture_pos = capture_end;
                    while (capture_pos > capture_start) {
                        var capture_char = ctx.prevCharAt(capture_pos) orelse return error.BytecodeCorrupt;
                        var input_char = ctx.prevCharAt(cpos) orelse {
                            if (try handleNoMatch(ctx, captures, stack, &stack_len, &pc, &cpos, no_recurse)) |done| return done;
                            continue :main;
                        };
                        if (ctx.ignore_case) {
                            capture_char.code_point = canonicalize(capture_char.code_point, ctx.is_unicode);
                            input_char.code_point = canonicalize(input_char.code_point, ctx.is_unicode);
                        }
                        if (capture_char.code_point != input_char.code_point) {
                            if (try handleNoMatch(ctx, captures, stack, &stack_len, &pc, &cpos, no_recurse)) |done| return done;
                            continue :main;
                        }
                        capture_pos = capture_char.next;
                        cpos = input_char.next;
                    }
                }
            },
            .range, .range32 => {
                const n = try ctx.readU16(pc);
                pc += 2;
                if (n == 0) return error.BytecodeCorrupt;
                var current = ctx.charAt(cpos) orelse {
                    if (try handleNoMatch(ctx, captures, stack, &stack_len, &pc, &cpos, no_recurse)) |done| return done;
                    continue :main;
                };
                if (ctx.ignore_case) current.code_point = canonicalize(current.code_point, ctx.is_unicode);
                const matched = if (opcode == .range)
                    try matchRange16(ctx, pc, n, current.code_point)
                else
                    try matchRange32(ctx, pc, n, current.code_point);
                pc += if (opcode == .range) @as(usize, n) * 4 else @as(usize, n) * 8;
                if (!matched) {
                    if (try handleNoMatch(ctx, captures, stack, &stack_len, &pc, &cpos, no_recurse)) |done| return done;
                    continue :main;
                }
                cpos = current.next;
            },
            .prev => {
                if (cpos == 0) {
                    if (try handleNoMatch(ctx, captures, stack, &stack_len, &pc, &cpos, no_recurse)) |done| return done;
                    continue :main;
                }
                cpos = try ctx.prevCharPos(cpos);
            },
            .simple_greedy_quant => {
                const next_pos = try ctx.readI32(pc);
                const quant_min = try ctx.readU32(pc + 4);
                const quant_max = try ctx.readU32(pc + 8);
                pc += 16;
                const atom_pc = pc;
                pc = try addOffset(pc, next_pos);
                var q: usize = 0;
                switch (try matchSimpleQuantAtom(ctx, atom_pc, cpos)) {
                    .unsupported => {
                        while (true) {
                            const atom_result = try execBacktrack(ctx, captures, stack, stack_len, atom_pc, cpos, true);
                            const next_cpos = switch (atom_result) {
                                .match => |matched| if (matched) cpos else break,
                                .position => |position| position,
                            };
                            cpos = next_cpos;
                            q += 1;
                            if (q >= quant_max and quant_max != int32_max) break;
                        }
                    },
                    .no_match => {},
                    .position => |first_pos| {
                        cpos = first_pos;
                        q = 1;
                        while (q < quant_max or quant_max == int32_max) {
                            switch (try matchSimpleQuantAtom(ctx, atom_pc, cpos)) {
                                .unsupported => return error.BytecodeCorrupt,
                                .no_match => break,
                                .position => |next_cpos| {
                                    cpos = next_cpos;
                                    q += 1;
                                },
                            }
                        }
                    },
                }
                if (q < quant_min) {
                    if (try handleNoMatch(ctx, captures, stack, &stack_len, &pc, &cpos, no_recurse)) |done| return done;
                    continue :main;
                }
                if (q > quant_min) {
                    try ctx.pushState(captures, stack, stack_len, atom_pc - 16, cpos, .greedy_quant, q - quant_min);
                }
            },
        }
    }
}

fn handleNoMatch(
    ctx: *JSContext,
    captures: *[max_captures * 2]?usize,
    stack: *[max_stack]usize,
    stack_len: *usize,
    pc: *usize,
    cpos: *usize,
    no_recurse: bool,
) !?BacktrackResult {
    if (no_recurse) return .{ .match = false };
    if (try ctx.resolveResult(captures, stack, stack_len, pc, cpos, false)) |done| return .{ .match = done };
    return null;
}

const SimpleQuantAtomMatch = union(enum) {
    unsupported,
    no_match,
    position: usize,
};

fn matchSimpleQuantAtom(ctx: *const JSContext, atom_pc: usize, cpos: usize) !SimpleQuantAtomMatch {
    const opcode = decodeOp(try ctx.readU8(atom_pc)) orelse return error.BytecodeCorrupt;
    var pc = atom_pc + 1;
    switch (opcode) {
        .char32, .char16, .char8 => {
            const expected: u21 = switch (opcode) {
                .char32 => blk: {
                    const value = try ctx.readU32(pc);
                    pc += 4;
                    break :blk @intCast(value);
                },
                .char16 => blk: {
                    const value = try ctx.readU16(pc);
                    pc += 2;
                    break :blk value;
                },
                .char8 => blk: {
                    const value = try ctx.readU8(pc);
                    pc += 1;
                    break :blk value;
                },
                else => unreachable,
            };
            try expectSimpleQuantAtomEnd(ctx, pc);
            var read = ctx.charAt(cpos) orelse return .no_match;
            if (ctx.ignore_case) read.code_point = canonicalize(read.code_point, ctx.is_unicode);
            return if (expected == read.code_point) .{ .position = read.next } else .no_match;
        },
        .dot, .any => {
            try expectSimpleQuantAtomEnd(ctx, pc);
            const current = ctx.charAt(cpos) orelse return .no_match;
            if (opcode == .dot and isLineTerminator(current.code_point)) return .no_match;
            return .{ .position = current.next };
        },
        .range, .range32 => {
            const n = try ctx.readU16(pc);
            pc += 2;
            if (n == 0) return error.BytecodeCorrupt;
            var current = ctx.charAt(cpos) orelse return .no_match;
            if (ctx.ignore_case) current.code_point = canonicalize(current.code_point, ctx.is_unicode);
            const matched = if (opcode == .range)
                try matchRange16(ctx, pc, n, current.code_point)
            else
                try matchRange32(ctx, pc, n, current.code_point);
            pc += if (opcode == .range) @as(usize, n) * 4 else @as(usize, n) * 8;
            try expectSimpleQuantAtomEnd(ctx, pc);
            return if (matched) .{ .position = current.next } else .no_match;
        },
        else => return .unsupported,
    }
}

fn expectSimpleQuantAtomEnd(ctx: *const JSContext, pc: usize) !void {
    const opcode = decodeOp(try ctx.readU8(pc)) orelse return error.BytecodeCorrupt;
    if (opcode != .match) return error.BytecodeCorrupt;
}

fn makeMatch(bytecode: []const u8, total_capture_count: usize, captures: *const [max_captures * 2]?usize) ExecStatus {
    const start = captures[0] orelse 0;
    const end = captures[1] orelse start;
    var result = Match{
        .start = start,
        .end = end,
        .capture_count = total_capture_count - 1,
    };
    var i: usize = 0;
    while (i < result.capture_count) : (i += 1) {
        const capture_index = i + 1;
        result.captures[i] = .{
            .start = captures[2 * capture_index],
            .end = captures[2 * capture_index + 1],
            .name = groupName(bytecode, capture_index),
        };
    }
    return .{ .result = .match, .match = result };
}

fn parseHeader(bytecode: []const u8) !Header {
    if (bytecode.len < header_len) return error.BytecodeCorrupt;
    const bytecode_len = std.mem.readInt(u32, bytecode[4..8], .little);
    if (header_len + bytecode_len > bytecode.len) return error.BytecodeCorrupt;
    return .{
        .flags = std.mem.readInt(u16, bytecode[0..2], .little),
        .capture_count = bytecode[2],
        .stack_size = bytecode[3],
        .bytecode_len = bytecode_len,
    };
}

const search_prefix_len = 11;
const search_prefix_goto_offset: u32 = @bitCast(@as(i32, -11));

fn hasSearchPrefix(bytecode: []const u8, header: Header) bool {
    if ((header.flags & flags.sticky) != 0) return false;
    if (header.bytecode_len < search_prefix_len) return false;
    const pos = header_len;
    return bytecode[pos] == @intFromEnum(Op.split_goto_first) and
        std.mem.readInt(u32, bytecode[pos + 1 ..][0..4], .little) == 6 and
        bytecode[pos + 5] == @intFromEnum(Op.any) and
        bytecode[pos + 6] == @intFromEnum(Op.goto_) and
        std.mem.readInt(u32, bytecode[pos + 7 ..][0..4], .little) == search_prefix_goto_offset;
}

fn matchRange16(ctx: *const JSContext, pc: usize, n: u16, code_point: u21) !bool {
    var idx_min: usize = 0;
    const first_low = try ctx.readU16(pc);
    if (code_point < first_low) return false;
    var idx_max: usize = n - 1;
    const last_high = try ctx.readU16(pc + idx_max * 4 + 2);
    if (code_point >= 0xffff and last_high == 0xffff) return true;
    if (code_point > last_high) return false;
    while (idx_min <= idx_max) {
        const idx = (idx_min + idx_max) / 2;
        const low = try ctx.readU16(pc + idx * 4);
        const high = try ctx.readU16(pc + idx * 4 + 2);
        if (code_point < low) {
            if (idx == 0) return false;
            idx_max = idx - 1;
        } else if (code_point > high) {
            idx_min = idx + 1;
        } else {
            return true;
        }
    }
    return false;
}

fn matchRange32(ctx: *const JSContext, pc: usize, n: u16, code_point: u21) !bool {
    var idx_min: usize = 0;
    const first_low = try ctx.readU32(pc);
    if (code_point < first_low) return false;
    var idx_max: usize = n - 1;
    const last_high = try ctx.readU32(pc + idx_max * 8 + 4);
    if (code_point > last_high) return false;
    while (idx_min <= idx_max) {
        const idx = (idx_min + idx_max) / 2;
        const low = try ctx.readU32(pc + idx * 8);
        const high = try ctx.readU32(pc + idx * 8 + 4);
        if (code_point < low) {
            if (idx == 0) return false;
            idx_max = idx - 1;
        } else if (code_point > high) {
            idx_min = idx + 1;
        } else {
            return true;
        }
    }
    return false;
}

fn addOffset(base: usize, offset: i32) !usize {
    const base_signed: isize = @intCast(base);
    const next = base_signed + @as(isize, @intCast(offset));
    if (next < 0) return error.BytecodeCorrupt;
    return @intCast(next);
}

fn decodeOp(byte: u8) ?Op {
    return switch (byte) {
        0 => .invalid,
        1 => .char8,
        2 => .char16,
        3 => .char32,
        4 => .dot,
        5 => .any,
        6 => .line_start,
        7 => .line_end,
        8 => .goto_,
        9 => .split_goto_first,
        10 => .split_next_first,
        11 => .match,
        12 => .save_start,
        13 => .save_end,
        14 => .save_reset,
        15 => .loop,
        16 => .push_i32,
        17 => .drop,
        18 => .word_boundary,
        19 => .not_word_boundary,
        20 => .back_reference,
        21 => .backward_back_reference,
        22 => .range,
        23 => .range32,
        24 => .lookahead,
        25 => .negative_lookahead,
        26 => .push_char_pos,
        27 => .check_advance,
        28 => .prev,
        29 => .simple_greedy_quant,
        else => null,
    };
}

fn canonicalize(code_point: u21, is_unicode: bool) u21 {
    return unicode.regexpCanonicalize(code_point, is_unicode);
}

fn isLineTerminator(code_point: u21) bool {
    return code_point == '\n' or code_point == '\r' or code_point == cp_ls or code_point == cp_ps;
}

fn isWordChar(code_point: u21) bool {
    return unicode.isAsciiWordCodePoint(code_point);
}

fn isHiSurrogate(code_unit: u21) bool {
    return unicode.isHighSurrogateCodePoint(code_unit);
}

fn isLoSurrogate(code_unit: u21) bool {
    return unicode.isLowSurrogateCodePoint(code_unit);
}

fn fromSurrogate(high: u16, low: u16) u21 {
    return unicode.codePointFromSurrogatePair(high, low);
}

fn headerCaptureCount() usize {
    return 2;
}

fn writeHeader(buf: []u8, flag_bits: u16, captures: u8, stack_size: u8, code_len: u32) void {
    std.mem.writeInt(u16, buf[0..2], flag_bits, .little);
    buf[2] = captures;
    buf[3] = stack_size;
    std.mem.writeInt(u32, buf[4..8], code_len, .little);
}

test "QuickJS regexp bytecode VM executes core opcodes" {
    var literal = [_]u8{0} ** (header_len + 7);
    writeHeader(&literal, 0, 1, 0, 7);
    @memcpy(literal[header_len..], &[_]u8{ 12, 0, 1, 'a', 13, 0, 11 });
    const literal_status = try exec(std.testing.allocator, &literal, .{ .latin1 = "ba" }, 1);
    try std.testing.expectEqual(.match, literal_status.result);
    try std.testing.expectEqual(@as(usize, 1), literal_status.match.start);
    try std.testing.expectEqual(@as(usize, 2), literal_status.match.end);

    var range = [_]u8{0} ** (header_len + 12);
    writeHeader(&range, 0, 1, 0, 12);
    range[header_len..][0..5].* = .{ 12, 0, 22, 1, 0 };
    std.mem.writeInt(u16, range[header_len + 5 ..][0..2], 'a', .little);
    std.mem.writeInt(u16, range[header_len + 7 ..][0..2], 'c', .little);
    range[header_len + 9 ..][0..3].* = .{ 13, 0, 11 };
    const range_status = try exec(std.testing.allocator, &range, .{ .latin1 = "xb" }, 1);
    try std.testing.expectEqual(.match, range_status.result);
    try std.testing.expectEqual(@as(usize, 1), range_status.match.start);
    try std.testing.expectEqual(@as(usize, 2), range_status.match.end);

    var backref = [_]u8{0} ** (header_len + 13);
    writeHeader(&backref, 0, 2, 0, 13);
    @memcpy(backref[header_len..], &[_]u8{ 12, 0, 12, 1, 1, 'a', 13, 1, 20, 1, 13, 0, 11 });
    const backref_status = try exec(std.testing.allocator, &backref, .{ .latin1 = "aa" }, 0);
    try std.testing.expectEqual(.match, backref_status.result);
    try std.testing.expectEqual(@as(usize, 0), backref_status.match.start);
    try std.testing.expectEqual(@as(usize, 2), backref_status.match.end);
    try std.testing.expectEqual(@as(usize, 1), backref_status.match.capture_count);
    try std.testing.expectEqual(@as(?usize, 0), backref_status.match.captures[0].start);
    try std.testing.expectEqual(@as(?usize, 1), backref_status.match.captures[0].end);

    var unicode_char = [_]u8{0} ** (header_len + 10);
    writeHeader(&unicode_char, flags.unicode, 1, 0, 10);
    unicode_char[header_len..][0..3].* = .{ 12, 0, 3 };
    std.mem.writeInt(u32, unicode_char[header_len + 3 ..][0..4], 0x1d306, .little);
    unicode_char[header_len + 7 ..][0..3].* = .{ 13, 0, 11 };
    const astral = [_]u16{ 0xd834, 0xdf06 };
    const unicode_status = try exec(std.testing.allocator, &unicode_char, .{ .utf16 = &astral }, 0);
    try std.testing.expectEqual(.match, unicode_status.result);
    try std.testing.expectEqual(@as(usize, 0), unicode_status.match.start);
    try std.testing.expectEqual(@as(usize, 2), unicode_status.match.end);
}

const regex_bytecode = @This();

pub const CompileError = std.mem.Allocator.Error || error{
    InvalidPattern,
    Unsupported,
};

const max_code_point: u21 = 0x10ffff;

const Atom = struct {
    start: usize,
    simple_char_count: ?u32,
    quantifiable: bool,
    capture_count_before: u8,
};

const ParsedFlags = struct {
    bits: u16,
    ignore_case: bool,
    dot_all: bool,
    sticky: bool,
    unicode: bool,
};

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, flags_str: []const u8) CompileError![]u8 {
    const parsed_flags = try parseFlags(flags_str);
    var capture_scan = try scanCaptures(allocator, pattern);
    defer capture_scan.deinit();

    var compiler = Compiler{
        .allocator = allocator,
        .pattern = pattern,
        .flags = parsed_flags,
        .total_capture_count = capture_scan.count,
        .all_capture_names = capture_scan.names.items,
        .code = .empty,
    };
    errdefer compiler.code.deinit(allocator);
    defer compiler.capture_names.deinit(allocator);

    try compiler.emitHeader();
    if (!parsed_flags.sticky) {
        try compiler.emitOpI32(.split_goto_first, 6);
        try compiler.emitOp(.any);
        try compiler.emitOpI32(.goto_, -11);
    }
    try compiler.emitOpU8(.save_start, 0);
    try compiler.parseDisjunction(null, false);
    if (compiler.index != pattern.len) return error.InvalidPattern;
    try compiler.emitOpU8(.save_end, 0);
    try compiler.emitOp(.match);
    try compiler.patchHeader();

    return try compiler.code.toOwnedSlice(allocator);
}

fn parseFlags(flag_bytes: []const u8) CompileError!ParsedFlags {
    var seen: [256]bool = [_]bool{false} ** 256;
    var parsed = ParsedFlags{
        .bits = 0,
        .ignore_case = false,
        .dot_all = false,
        .sticky = false,
        .unicode = false,
    };
    var saw_u = false;
    var saw_v = false;
    for (flag_bytes) |flag| {
        if (seen[flag]) return error.InvalidPattern;
        seen[flag] = true;
        switch (flag) {
            'd' => parsed.bits |= regex_bytecode.flags.indices,
            'g' => parsed.bits |= regex_bytecode.flags.global,
            'i' => {
                parsed.bits |= regex_bytecode.flags.ignore_case;
                parsed.ignore_case = true;
            },
            'm' => parsed.bits |= regex_bytecode.flags.multiline,
            's' => {
                parsed.bits |= regex_bytecode.flags.dot_all;
                parsed.dot_all = true;
            },
            'u' => {
                parsed.bits |= regex_bytecode.flags.unicode;
                parsed.unicode = true;
                saw_u = true;
            },
            'v' => {
                parsed.bits |= regex_bytecode.flags.unicode | regex_bytecode.flags.unicode_sets;
                parsed.unicode = true;
                saw_v = true;
            },
            'y' => {
                parsed.bits |= regex_bytecode.flags.sticky;
                parsed.sticky = true;
            },
            else => return error.InvalidPattern,
        }
    }
    if (saw_u and saw_v) return error.InvalidPattern;
    return parsed;
}

const CaptureScan = struct {
    allocator: std.mem.Allocator,
    count: u16,
    names: std.ArrayList(?[]const u8),

    fn deinit(self: *CaptureScan) void {
        self.names.deinit(self.allocator);
    }
};

fn scanCaptures(allocator: std.mem.Allocator, pattern: []const u8) CompileError!CaptureScan {
    var scan = CaptureScan{
        .allocator = allocator,
        .count = 1,
        .names = .empty,
    };
    errdefer scan.deinit();

    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        switch (pattern[index]) {
            '\\' => {
                if (index + 1 < pattern.len) index += 1;
            },
            '[' => {
                index += 1;
                if (index < pattern.len and pattern[index] == ']') index += 1;
                while (index < pattern.len and pattern[index] != ']') : (index += 1) {
                    if (pattern[index] == '\\' and index + 1 < pattern.len) index += 1;
                }
            },
            '(' => {
                var name: ?[]const u8 = null;
                if (index + 1 < pattern.len and pattern[index + 1] == '?') {
                    if (index + 2 >= pattern.len) continue;
                    switch (pattern[index + 2]) {
                        ':', '=', '!' => continue,
                        '<' => {
                            if (index + 3 < pattern.len and (pattern[index + 3] == '=' or pattern[index + 3] == '!')) continue;
                            var name_index = index + 3;
                            name = try parseGroupNameAt(pattern, &name_index);
                        },
                        else => continue,
                    }
                }
                if (scan.count == 255) return error.InvalidPattern;
                scan.count += 1;
                try scan.names.append(allocator, name);
            },
            else => {},
        }
    }
    return scan;
}

const Compiler = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    flags: ParsedFlags,
    total_capture_count: u16,
    all_capture_names: []const ?[]const u8,
    index: usize = 0,
    capture_count: u8 = 1,
    code: std.ArrayList(u8),
    capture_names: std.ArrayList(?[]const u8) = .empty,
    has_named_captures: bool = false,

    fn emitHeader(self: *Compiler) !void {
        try self.code.appendNTimes(self.allocator, 0, header_len);
    }

    fn patchHeader(self: *Compiler) !void {
        const bytecode_len = self.code.items.len - header_len;
        const stack_size = try computeStackSize(self.code.items[header_len..]);
        if (self.has_named_captures) {
            var capture_index: usize = 1;
            while (capture_index < self.capture_count) : (capture_index += 1) {
                const name = self.capture_names.items[capture_index - 1] orelse "";
                try self.code.appendSlice(self.allocator, name);
                try self.code.append(self.allocator, 0);
            }
        }
        const flag_bits = self.flags.bits | if (self.has_named_captures) regex_bytecode.flags.named_groups else 0;
        std.mem.writeInt(u16, self.code.items[0..2], flag_bits, .little);
        self.code.items[2] = self.capture_count;
        self.code.items[3] = stack_size;
        std.mem.writeInt(u32, self.code.items[4..8], @intCast(bytecode_len), .little);
    }

    fn parseDisjunction(self: *Compiler, terminator: ?u8, is_backward_dir: bool) CompileError!void {
        const start = self.code.items.len;
        try self.parseAlternative(terminator, is_backward_dir);
        while (self.index < self.pattern.len and self.pattern[self.index] == '|') {
            self.index += 1;
            const previous_len = self.code.items.len - start;
            try self.insertBytes(start, 5);
            self.code.items[start] = opByte(.split_next_first);
            std.mem.writeInt(u32, self.code.items[start + 1 ..][0..4], @intCast(previous_len + 5), .little);

            const goto_pos = try self.emitOpU32At(.goto_, 0);
            try self.parseAlternative(terminator, is_backward_dir);
            std.mem.writeInt(u32, self.code.items[goto_pos..][0..4], @intCast(self.code.items.len - (goto_pos + 4)), .little);
        }
        if (terminator) |end| {
            if (self.index >= self.pattern.len or self.pattern[self.index] != end) return error.InvalidPattern;
            self.index += 1;
        }
    }

    fn parseAlternative(self: *Compiler, terminator: ?u8, is_backward_dir: bool) CompileError!void {
        const start = self.code.items.len;
        while (self.index < self.pattern.len) {
            const byte = self.pattern[self.index];
            if (terminator) |end| {
                if (byte == end) return;
            }
            if (byte == '|') return;
            if (byte == ')') return error.InvalidPattern;
            const term_start = self.code.items.len;
            const atom = try self.parseTerm(is_backward_dir);
            try self.parseQuantifier(atom);
            if (is_backward_dir) try self.moveTermToStart(start, term_start, self.code.items.len);
        }
    }

    fn parseTerm(self: *Compiler, is_backward_dir: bool) CompileError!Atom {
        if (self.index >= self.pattern.len) return error.InvalidPattern;
        const start = self.code.items.len;
        const capture_count_before = self.capture_count;
        const byte = self.pattern[self.index];
        switch (byte) {
            '^' => {
                self.index += 1;
                try self.emitOp(.line_start);
                return .{ .start = start, .simple_char_count = null, .quantifiable = false, .capture_count_before = capture_count_before };
            },
            '$' => {
                self.index += 1;
                try self.emitOp(.line_end);
                return .{ .start = start, .simple_char_count = null, .quantifiable = false, .capture_count_before = capture_count_before };
            },
            '.' => {
                self.index += 1;
                if (is_backward_dir) try self.emitOp(.prev);
                try self.emitOp(if (self.flags.dot_all) .any else .dot);
                if (is_backward_dir) try self.emitOp(.prev);
                return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = capture_count_before };
            },
            '*', '+', '?' => return error.InvalidPattern,
            '{' => {
                if (self.flags.unicode or self.looksLikeQuantifier(self.index)) return error.InvalidPattern;
                self.index += 1;
                try self.emitCharacterAtom('{', is_backward_dir);
                return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = capture_count_before };
            },
            '(' => return self.parseGroup(start, is_backward_dir),
            '[' => return self.parseClass(start, is_backward_dir),
            '\\' => return self.parseEscape(start, is_backward_dir),
            ']', '}' => {
                if (self.flags.unicode) return error.InvalidPattern;
                self.index += 1;
                try self.emitCharacterAtom(byte, is_backward_dir);
                return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = capture_count_before };
            },
            else => {
                const cp = try self.readPatternCodePoint();
                if (cp > 0xffff and !self.flags.unicode) {
                    const quant_start = try self.emitNonUnicodeSurrogatePairTerms(cp, is_backward_dir);
                    return .{ .start = quant_start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = capture_count_before };
                }
                try self.emitCharacterAtom(canonicalizeLiteral(cp, self.flags), is_backward_dir);
                return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = capture_count_before };
            },
        }
    }

    fn parseGroup(self: *Compiler, start: usize, is_backward_dir: bool) CompileError!Atom {
        std.debug.assert(self.pattern[self.index] == '(');
        const capture_count_before = self.capture_count;
        if (self.index + 1 < self.pattern.len and self.pattern[self.index + 1] == '?') {
            if (self.index + 2 < self.pattern.len and self.pattern[self.index + 2] == ':') {
                self.index += 3;
                try self.parseDisjunction(')', is_backward_dir);
                return .{ .start = start, .simple_char_count = null, .quantifiable = true, .capture_count_before = capture_count_before };
            }
            if (self.index + 2 < self.pattern.len and (self.pattern[self.index + 2] == '=' or self.pattern[self.index + 2] == '!')) {
                const negative = self.pattern[self.index + 2] == '!';
                self.index += 3;
                const offset_pos = try self.emitOpU32At(if (negative) .negative_lookahead else .lookahead, 0);
                try self.parseDisjunction(')', false);
                try self.emitOp(.match);
                std.mem.writeInt(u32, self.code.items[offset_pos..][0..4], @intCast(self.code.items.len - (offset_pos + 4)), .little);
                return .{ .start = start, .simple_char_count = null, .quantifiable = !self.flags.unicode, .capture_count_before = capture_count_before };
            }
            if (self.index + 3 < self.pattern.len and self.pattern[self.index + 2] == '<' and
                (self.pattern[self.index + 3] == '=' or self.pattern[self.index + 3] == '!'))
            {
                const negative = self.pattern[self.index + 3] == '!';
                self.index += 4;
                const offset_pos = try self.emitOpU32At(if (negative) .negative_lookahead else .lookahead, 0);
                try self.parseDisjunction(')', true);
                try self.emitOp(.match);
                std.mem.writeInt(u32, self.code.items[offset_pos..][0..4], @intCast(self.code.items.len - (offset_pos + 4)), .little);
                return .{ .start = start, .simple_char_count = null, .quantifiable = false, .capture_count_before = capture_count_before };
            }
            if (self.index + 2 < self.pattern.len and self.pattern[self.index + 2] == '<') {
                self.index += 3;
                const name = try self.parseGroupName();
                return try self.parseCaptureGroup(start, name, is_backward_dir);
            }
            return error.Unsupported;
        }
        self.index += 1;
        return try self.parseCaptureGroup(start, null, is_backward_dir);
    }

    fn parseCaptureGroup(self: *Compiler, start: usize, maybe_name: ?[]const u8, is_backward_dir: bool) CompileError!Atom {
        if (self.capture_count == 255) return error.InvalidPattern;
        const capture_index = self.capture_count;
        self.capture_count += 1;
        if (maybe_name) |name| {
            if (self.findCaptureName(name, capture_index) != null) return error.InvalidPattern;
            self.has_named_captures = true;
        }
        try self.capture_names.append(self.allocator, maybe_name);
        try self.emitOpU8(if (is_backward_dir) .save_end else .save_start, capture_index);
        try self.parseDisjunction(')', is_backward_dir);
        try self.emitOpU8(if (is_backward_dir) .save_start else .save_end, capture_index);
        return .{ .start = start, .simple_char_count = null, .quantifiable = true, .capture_count_before = capture_index };
    }

    fn parseEscape(self: *Compiler, start: usize, is_backward_dir: bool) CompileError!Atom {
        std.debug.assert(self.pattern[self.index] == '\\');
        if (self.index + 1 >= self.pattern.len) return error.InvalidPattern;
        const escaped = self.pattern[self.index + 1];
        switch (escaped) {
            'b', 'B' => {
                self.index += 2;
                try self.emitOp(if (escaped == 'b') .word_boundary else .not_word_boundary);
                return .{ .start = start, .simple_char_count = null, .quantifiable = false, .capture_count_before = self.capture_count };
            },
            'd', 'D', 's', 'S', 'w', 'W' => {
                self.index += 2;
                var ranges = RangeSet.init(self.allocator);
                defer ranges.deinit();
                try ranges.addClassEscape(escaped);
                if (self.flags.ignore_case) try ranges.regexpCanonicalize(self.flags.unicode);
                if (is_backward_dir) try self.emitOp(.prev);
                try self.emitRangeSet(&ranges);
                if (is_backward_dir) try self.emitOp(.prev);
                return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = self.capture_count };
            },
            '1'...'9' => {
                const escape_start = self.index;
                const capture_index = try self.parseDecimalEscape();
                if (capture_index == 0 or capture_index >= self.total_capture_count) {
                    if (self.flags.unicode) return error.InvalidPattern;
                    self.index = escape_start + 1;
                    const cp = try self.parseLegacyDecimalEscape();
                    try self.emitCharacterAtom(canonicalizeLiteral(cp, self.flags), is_backward_dir);
                    return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = self.capture_count };
                }
                try self.emitOpU8(if (is_backward_dir) .backward_back_reference else .back_reference, @intCast(capture_index));
                return .{ .start = start, .simple_char_count = null, .quantifiable = true, .capture_count_before = self.capture_count };
            },
            '0' => {
                self.index += 2;
                if (self.index < self.pattern.len and isDecimalDigit(self.pattern[self.index]) and self.flags.unicode) return error.InvalidPattern;
                const cp = try self.parseLegacyOctalAfterZero();
                try self.emitCharacterAtom(canonicalizeLiteral(cp, self.flags), is_backward_dir);
                return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = self.capture_count };
            },
            'x' => {
                const escape_start = self.index;
                const cp = self.parseFixedHexEscape(2) catch |err| {
                    self.index = escape_start;
                    if (self.flags.unicode) return err;
                    self.index += 2;
                    try self.emitCharacterAtom(canonicalizeLiteral('x', self.flags), is_backward_dir);
                    return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = self.capture_count };
                };
                try self.emitCharacterAtom(canonicalizeLiteral(cp, self.flags), is_backward_dir);
                return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = self.capture_count };
            },
            'u' => {
                const escape_start = self.index;
                const braced = self.isBracedUnicodeEscape();
                const cp = self.parseUnicodeEscape() catch |err| {
                    self.index = escape_start;
                    if (self.flags.unicode) return err;
                    self.index += 2;
                    try self.emitCharacterAtom(canonicalizeLiteral('u', self.flags), is_backward_dir);
                    return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = self.capture_count };
                };
                const combined = if (braced) cp else try self.combineEscapedSurrogatePair(cp);
                try self.emitCharacterAtom(canonicalizeLiteral(combined, self.flags), is_backward_dir);
                return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = self.capture_count };
            },
            'c' => {
                if (self.index + 2 >= self.pattern.len or !std.ascii.isAlphabetic(self.pattern[self.index + 2])) {
                    if (self.flags.unicode) return error.InvalidPattern;
                    self.index += 2;
                    try self.emitCharacterAtom('\\', is_backward_dir);
                    try self.emitCharacterAtom('c', is_backward_dir);
                    var char_count: u32 = 2;
                    if (self.index < self.pattern.len) {
                        const cp = try self.readUtf8CodePoint();
                        if (cp > 0xffff) {
                            try self.emitNonUnicodeSurrogatePairAtom(cp, is_backward_dir);
                            char_count += 2;
                        } else {
                            try self.emitCharacterAtom(canonicalizeLiteral(cp, self.flags), is_backward_dir);
                            char_count += 1;
                        }
                    }
                    return .{ .start = start, .simple_char_count = if (is_backward_dir) null else char_count, .quantifiable = true, .capture_count_before = self.capture_count };
                }
                const cp: u21 = self.pattern[self.index + 2] & 0x1f;
                self.index += 3;
                try self.emitCharacterAtom(canonicalizeLiteral(cp, self.flags), is_backward_dir);
                return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = self.capture_count };
            },
            'f', 'n', 'r', 't', 'v' => {
                self.index += 2;
                const cp: u21 = switch (escaped) {
                    'f' => 0x0c,
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    'v' => 0x0b,
                    else => unreachable,
                };
                try self.emitCharacterAtom(canonicalizeLiteral(cp, self.flags), is_backward_dir);
                return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = self.capture_count };
            },
            'p', 'P' => {
                if (!self.flags.unicode) {
                    self.index += 2;
                    try self.emitCharacterAtom(canonicalizeLiteral(escaped, self.flags), is_backward_dir);
                    return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = self.capture_count };
                }
                const inverted = escaped == 'P';
                var ranges = try self.parseUnicodePropertyEscape(inverted);
                defer ranges.deinit();
                if (self.flags.ignore_case) try ranges.regexpCanonicalize(self.flags.unicode);
                if (is_backward_dir) try self.emitOp(.prev);
                try self.emitRangeSet(&ranges);
                if (is_backward_dir) try self.emitOp(.prev);
                return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = self.capture_count };
            },
            'k' => {
                const escape_start = self.index;
                if (self.index + 2 >= self.pattern.len or self.pattern[self.index + 2] != '<') {
                    if (self.flags.unicode or self.patternHasNamedCaptures()) return error.InvalidPattern;
                    self.index += 2;
                    try self.emitCharacterAtom(canonicalizeLiteral('k', self.flags), is_backward_dir);
                    return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = self.capture_count };
                }
                self.index += 3;
                const name = self.parseGroupName() catch |err| {
                    if (self.flags.unicode or self.patternHasNamedCaptures()) return err;
                    self.index = escape_start + 2;
                    try self.emitCharacterAtom(canonicalizeLiteral('k', self.flags), is_backward_dir);
                    return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = self.capture_count };
                };
                const capture_index = self.findCaptureName(name, self.capture_count) orelse self.findScannedCaptureName(name) orelse {
                    if (self.flags.unicode or self.patternHasNamedCaptures()) return error.InvalidPattern;
                    self.index = escape_start + 2;
                    try self.emitCharacterAtom(canonicalizeLiteral('k', self.flags), is_backward_dir);
                    return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = self.capture_count };
                };
                try self.emitOpU8(if (is_backward_dir) .backward_back_reference else .back_reference, @intCast(capture_index));
                return .{ .start = start, .simple_char_count = null, .quantifiable = true, .capture_count_before = self.capture_count };
            },
            else => {
                if (escaped >= 0x80) {
                    if (self.flags.unicode) return error.InvalidPattern;
                    self.index += 1;
                    const cp = try self.readUtf8CodePoint();
                    if (cp > 0xffff) {
                        const quant_start = try self.emitNonUnicodeSurrogatePairTerms(cp, is_backward_dir);
                        return .{ .start = quant_start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = self.capture_count };
                    }
                    try self.emitCharacterAtom(canonicalizeLiteral(cp, self.flags), is_backward_dir);
                    return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = self.capture_count };
                }
                if (isSyntaxEscape(escaped) or escaped == '/') {
                    self.index += 2;
                    try self.emitCharacterAtom(canonicalizeLiteral(escaped, self.flags), is_backward_dir);
                    return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = self.capture_count };
                }
                if (self.flags.unicode) return error.InvalidPattern;
                self.index += 2;
                try self.emitCharacterAtom(canonicalizeLiteral(escaped, self.flags), is_backward_dir);
                return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = self.capture_count };
            },
        }
    }

    fn parseClass(self: *Compiler, start: usize, is_backward_dir: bool) CompileError!Atom {
        self.index += 1;
        var ranges = RangeSet.init(self.allocator);
        defer ranges.deinit();
        const invert = if (self.index < self.pattern.len and self.pattern[self.index] == '^') blk: {
            self.index += 1;
            break :blk true;
        } else false;
        const body_start = self.index;
        var has_class_set_lhs = false;

        while (self.index < self.pattern.len) {
            if (self.pattern[self.index] == ']') {
                self.index += 1;
                try ranges.normalize();
                if (self.flags.ignore_case) try ranges.regexpCanonicalize(self.flags.unicode);
                if (invert) try ranges.invert();
                if (is_backward_dir) try self.emitOp(.prev);
                try self.emitRangeSet(&ranges);
                if (is_backward_dir) try self.emitOp(.prev);
                return .{ .start = start, .simple_char_count = if (is_backward_dir) null else 1, .quantifiable = true, .capture_count_before = self.capture_count };
            }

            if ((self.flags.bits & regex_bytecode.flags.unicode_sets) != 0 and
                self.index + 1 < self.pattern.len and
                self.pattern[self.index] == '&' and
                self.pattern[self.index + 1] == '&')
            {
                if (!has_class_set_lhs) return error.InvalidPattern;
                self.index += 2;
                var rhs = try self.parseClassAtomOrRange(body_start);
                defer rhs.deinit();
                try ranges.intersectWith(&rhs);
                continue;
            }

            var atom_ranges = try self.parseClassAtomOrRange(body_start);
            defer atom_ranges.deinit();
            try ranges.addSet(&atom_ranges);
            has_class_set_lhs = true;
        }
        return error.InvalidPattern;
    }

    fn parseClassAtomOrRange(self: *Compiler, body_start: usize) CompileError!RangeSet {
        if ((self.flags.bits & regex_bytecode.flags.unicode_sets) != 0 and self.index < self.pattern.len and self.pattern[self.index] != '\\') {
            const raw = self.pattern[self.index];
            if (isUnicodeSetsReservedClassByte(raw, self.index == body_start or (self.index + 1 < self.pattern.len and self.pattern[self.index + 1] == ']'))) {
                return error.InvalidPattern;
            }
            if (self.index + 1 < self.pattern.len and isUnicodeSetsReservedDoublePunctuator(raw, self.pattern[self.index + 1])) {
                return error.InvalidPattern;
            }
        }

        var ranges = RangeSet.init(self.allocator);
        errdefer ranges.deinit();

        const first = try self.parseClassAtom();
        if (self.index < self.pattern.len and self.pattern[self.index] == '-' and self.index + 1 < self.pattern.len and self.pattern[self.index + 1] != ']') {
            if (first != .code_point) {
                if (self.flags.unicode) return error.InvalidPattern;
                try ranges.addAtom(first);
                return ranges;
            }
            const hyphen_index = self.index;
            self.index += 1;
            const second = try self.parseClassAtom();
            if (second != .code_point) {
                if (self.flags.unicode) return error.InvalidPattern;
                self.index = hyphen_index;
                try ranges.addAtom(first);
                return ranges;
            }
            if (second.code_point < first.code_point) return error.InvalidPattern;
            try ranges.addInclusive(first.code_point, second.code_point);
        } else {
            try ranges.addAtom(first);
        }
        return ranges;
    }

    fn parseClassAtom(self: *Compiler) CompileError!ClassAtom {
        if (self.index >= self.pattern.len) return error.InvalidPattern;
        const byte = self.pattern[self.index];
        if (byte == '\\') {
            if (self.index + 1 >= self.pattern.len) return error.InvalidPattern;
            const escaped = self.pattern[self.index + 1];
            switch (escaped) {
                'd', 'D', 's', 'S', 'w', 'W' => {
                    self.index += 2;
                    var ranges = RangeSet.init(self.allocator);
                    errdefer ranges.deinit();
                    try ranges.addClassEscape(escaped);
                    return .{ .ranges = ranges };
                },
                '0' => {
                    if (self.flags.unicode) {
                        if (self.index + 2 < self.pattern.len and isDecimalDigit(self.pattern[self.index + 2])) return error.InvalidPattern;
                        self.index += 2;
                        return .{ .code_point = 0 };
                    }
                    return .{ .code_point = try self.parseLegacyClassDecimalEscape() };
                },
                '1'...'9' => {
                    if (self.flags.unicode) return error.InvalidPattern;
                    return .{ .code_point = try self.parseLegacyClassDecimalEscape() };
                },
                'b' => {
                    self.index += 2;
                    return .{ .code_point = 0x08 };
                },
                'c' => {
                    if (self.flags.unicode) {
                        if (self.index + 2 >= self.pattern.len or !std.ascii.isAlphabetic(self.pattern[self.index + 2])) return error.InvalidPattern;
                        const cp: u21 = self.pattern[self.index + 2] & 0x1f;
                        self.index += 3;
                        return .{ .code_point = cp };
                    }
                    if (self.index + 2 < self.pattern.len and isClassControlLetter(self.pattern[self.index + 2])) {
                        const cp: u21 = self.pattern[self.index + 2] & 0x1f;
                        self.index += 3;
                        return .{ .code_point = cp };
                    }
                    self.index += 2;
                    var ranges = RangeSet.init(self.allocator);
                    errdefer ranges.deinit();
                    try ranges.addInclusive('\\', '\\');
                    try ranges.addInclusive('c', 'c');
                    return .{ .ranges = ranges };
                },
                'B', 'k' => {
                    if (self.flags.unicode) return error.Unsupported;
                    self.index += 2;
                    return .{ .code_point = escaped };
                },
                'p', 'P' => {
                    if (!self.flags.unicode) {
                        self.index += 2;
                        return .{ .code_point = escaped };
                    }
                    return .{ .ranges = try self.parseUnicodePropertyEscape(escaped == 'P') };
                },
                'x' => {
                    const escape_start = self.index;
                    const cp = self.parseFixedHexEscape(2) catch |err| {
                        self.index = escape_start;
                        if (self.flags.unicode) return err;
                        self.index += 2;
                        return .{ .code_point = 'x' };
                    };
                    return .{ .code_point = cp };
                },
                'u' => {
                    const escape_start = self.index;
                    const cp = self.parseUnicodeEscape() catch |err| {
                        self.index = escape_start;
                        if (self.flags.unicode) return err;
                        self.index += 2;
                        return .{ .code_point = 'u' };
                    };
                    return .{ .code_point = cp };
                },
                'f', 'n', 'r', 't', 'v' => {
                    self.index += 2;
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
                        self.index += 2;
                        return .{ .code_point = escaped };
                    }
                    if (self.flags.unicode) return error.InvalidPattern;
                    self.index += 2;
                    return .{ .code_point = escaped };
                },
            }
        }
        const cp = try self.readClassCodePoint();
        if (cp > 0xffff and !self.flags.unicode) {
            var ranges = RangeSet.init(self.allocator);
            errdefer ranges.deinit();
            try ranges.addNonUnicodeSurrogatePair(cp);
            return .{ .ranges = ranges };
        }
        return .{ .code_point = cp };
    }

    fn parseQuantifier(self: *Compiler, atom: Atom) CompileError!void {
        if (self.index >= self.pattern.len) return;
        var min: u32 = 1;
        var max: u32 = 1;
        const quant_start = self.index;
        switch (self.pattern[self.index]) {
            '*' => {
                self.index += 1;
                min = 0;
                max = int32_max;
            },
            '+' => {
                self.index += 1;
                min = 1;
                max = int32_max;
            },
            '?' => {
                self.index += 1;
                min = 0;
                max = 1;
            },
            '{' => {
                if (self.index + 1 >= self.pattern.len or !isDecimalDigit(self.pattern[self.index + 1])) return;
                self.index += 1;
                min = try self.parseDigits(true);
                max = min;
                if (self.index < self.pattern.len and self.pattern[self.index] == ',') {
                    self.index += 1;
                    if (self.index < self.pattern.len and isDecimalDigit(self.pattern[self.index])) {
                        max = try self.parseDigits(true);
                        if (max < min) return error.InvalidPattern;
                    } else {
                        max = int32_max;
                    }
                }
                if (self.index >= self.pattern.len or self.pattern[self.index] != '}') {
                    self.index = quant_start;
                    if (self.flags.unicode) return error.InvalidPattern;
                    return;
                }
                self.index += 1;
            },
            else => return,
        }
        if (!atom.quantifiable) return error.InvalidPattern;
        const greedy = if (self.index < self.pattern.len and self.pattern[self.index] == '?') blk: {
            self.index += 1;
            break :blk false;
        } else true;
        if (min == 1 and max == 1) return;
        if (greedy) {
            if (atom.simple_char_count) |char_count| {
                try self.wrapSimpleGreedyQuantifier(atom.start, char_count, min, max);
                return;
            }
        }
        var atom_start = atom.start;
        if (min == 0 and self.capture_count != atom.capture_count_before) {
            try self.insertBytes(atom.start, 3);
            self.code.items[atom.start] = opByte(.save_reset);
            self.code.items[atom.start + 1] = atom.capture_count_before;
            self.code.items[atom.start + 2] = self.capture_count - 1;
            atom_start += 3;
        }
        try self.wrapGenericQuantifier(atom_start, min, max, greedy);
    }

    fn wrapSimpleGreedyQuantifier(self: *Compiler, atom_start: usize, char_count: u32, min: u32, max: u32) !void {
        try self.emitOp(.match);
        const old_len = self.code.items.len;
        try self.code.appendNTimes(self.allocator, 0, 17);
        const move_len = old_len - atom_start;
        std.mem.copyBackwards(
            u8,
            self.code.items[atom_start + 17 .. atom_start + 17 + move_len],
            self.code.items[atom_start .. atom_start + move_len],
        );
        self.code.items[atom_start] = opByte(.simple_greedy_quant);
        std.mem.writeInt(u32, self.code.items[atom_start + 1 ..][0..4], @intCast(move_len), .little);
        std.mem.writeInt(u32, self.code.items[atom_start + 5 ..][0..4], min, .little);
        std.mem.writeInt(u32, self.code.items[atom_start + 9 ..][0..4], max, .little);
        std.mem.writeInt(u32, self.code.items[atom_start + 13 ..][0..4], char_count, .little);
    }

    fn wrapGenericQuantifier(self: *Compiler, atom_start: usize, min: u32, max: u32, greedy: bool) CompileError!void {
        const atom_len = self.code.items.len - atom_start;
        const add_zero_advance_check = true;
        const split_op: Op = if (greedy) .split_next_first else .split_goto_first;
        if (min == 0) {
            if (max == 0) {
                self.code.shrinkRetainingCapacity(atom_start);
                return;
            }
            if (max == 1 or max == int32_max) {
                const has_goto = max == int32_max;
                try self.insertBytes(atom_start, 5 + if (add_zero_advance_check) @as(usize, 1) else 0);
                self.code.items[atom_start] = opByte(split_op);
                std.mem.writeInt(
                    u32,
                    self.code.items[atom_start + 1 ..][0..4],
                    @intCast(atom_len + (if (has_goto) @as(usize, 5) else 0) + (if (add_zero_advance_check) @as(usize, 2) else 0)),
                    .little,
                );
                if (add_zero_advance_check) {
                    self.code.items[atom_start + 5] = opByte(.push_char_pos);
                    try self.emitOp(.check_advance);
                }
                if (has_goto) try self.emitGoto(.goto_, atom_start);
                return;
            }

            try self.insertBytes(atom_start, 10 + if (add_zero_advance_check) @as(usize, 1) else 0);
            self.code.items[atom_start] = opByte(.push_i32);
            std.mem.writeInt(u32, self.code.items[atom_start + 1 ..][0..4], max, .little);
            self.code.items[atom_start + 5] = opByte(split_op);
            std.mem.writeInt(
                u32,
                self.code.items[atom_start + 6 ..][0..4],
                @intCast(atom_len + 5 + if (add_zero_advance_check) @as(usize, 2) else 0),
                .little,
            );
            if (add_zero_advance_check) self.code.items[atom_start + 10] = opByte(.push_char_pos);
            if (add_zero_advance_check) try self.emitOp(.check_advance);
            try self.emitGoto(.loop, atom_start + 5);
            try self.emitOp(.drop);
            return;
        }

        var repeated_atom_start = atom_start;
        if (min > 1) {
            try self.insertBytes(atom_start, 5);
            self.code.items[atom_start] = opByte(.push_i32);
            std.mem.writeInt(u32, self.code.items[atom_start + 1 ..][0..4], min, .little);
            repeated_atom_start += 5;
            try self.emitGoto(.loop, repeated_atom_start);
            try self.emitOp(.drop);
        }

        if (max == int32_max) {
            const split_pos = self.code.items.len;
            try self.emitOpU32(split_op, @intCast(atom_len + 5 + if (add_zero_advance_check) @as(usize, 2) else 0));
            if (add_zero_advance_check) try self.emitOp(.push_char_pos);
            try self.appendCodeCopy(repeated_atom_start, atom_len);
            if (add_zero_advance_check) try self.emitOp(.check_advance);
            try self.emitGoto(.goto_, split_pos);
        } else if (max > min) {
            try self.emitOpU32(.push_i32, max - min);
            const split_pos = self.code.items.len;
            try self.emitOpU32(split_op, @intCast(atom_len + 5 + if (add_zero_advance_check) @as(usize, 2) else 0));
            if (add_zero_advance_check) try self.emitOp(.push_char_pos);
            try self.appendCodeCopy(repeated_atom_start, atom_len);
            if (add_zero_advance_check) try self.emitOp(.check_advance);
            try self.emitGoto(.loop, split_pos);
            try self.emitOp(.drop);
        }
    }

    fn parseDecimalEscape(self: *Compiler) CompileError!u32 {
        std.debug.assert(self.pattern[self.index] == '\\');
        self.index += 1;
        return self.parseDigits(false);
    }

    fn parseLegacyDecimalEscape(self: *Compiler) CompileError!u21 {
        if (self.index >= self.pattern.len or !isDecimalDigit(self.pattern[self.index])) return error.InvalidPattern;
        if (self.pattern[self.index] > '7') {
            const cp = self.pattern[self.index];
            self.index += 1;
            return cp;
        }

        var cp: u21 = 0;
        if (self.pattern[self.index] <= '3') {
            cp = self.pattern[self.index] - '0';
            self.index += 1;
        }
        var consumed: usize = 0;
        while (consumed < 2 and self.index < self.pattern.len and isOctalDigit(self.pattern[self.index])) : (consumed += 1) {
            cp = cp * 8 + (self.pattern[self.index] - '0');
            self.index += 1;
        }
        return cp;
    }

    fn parseLegacyOctalAfterZero(self: *Compiler) CompileError!u21 {
        var cp: u21 = 0;
        var consumed: usize = 0;
        while (consumed < 2 and self.index < self.pattern.len and isOctalDigit(self.pattern[self.index])) : (consumed += 1) {
            cp = cp * 8 + (self.pattern[self.index] - '0');
            self.index += 1;
        }
        return cp;
    }

    fn parseLegacyClassDecimalEscape(self: *Compiler) CompileError!u21 {
        std.debug.assert(self.pattern[self.index] == '\\');
        self.index += 1;
        if (self.index >= self.pattern.len or !isDecimalDigit(self.pattern[self.index])) return error.InvalidPattern;
        if (!isOctalDigit(self.pattern[self.index])) {
            const cp = self.pattern[self.index];
            self.index += 1;
            return cp;
        }

        var cp: u21 = 0;
        var consumed: usize = 0;
        while (consumed < 3 and self.index < self.pattern.len and isOctalDigit(self.pattern[self.index])) : (consumed += 1) {
            const next = cp * 8 + (self.pattern[self.index] - '0');
            if (next > 0xff) break;
            cp = next;
            self.index += 1;
        }
        return cp;
    }

    fn parseGroupName(self: *Compiler) CompileError![]const u8 {
        return parseGroupNameAt(self.pattern, &self.index);
    }

    fn parseUnicodePropertyEscape(self: *Compiler, inverted: bool) CompileError!RangeSet {
        std.debug.assert(self.pattern[self.index] == '\\');
        if (self.index + 3 >= self.pattern.len or self.pattern[self.index + 2] != '{') return error.InvalidPattern;
        self.index += 3;
        const name_start = self.index;
        while (self.index < self.pattern.len and self.pattern[self.index] != '}') : (self.index += 1) {
            const byte = self.pattern[self.index];
            if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '=')) return error.Unsupported;
        }
        if (self.index == name_start or self.index >= self.pattern.len or self.pattern[self.index] != '}') return error.InvalidPattern;
        const name = self.pattern[name_start..self.index];
        self.index += 1;

        var ranges = RangeSet.init(self.allocator);
        errdefer ranges.deinit();
        try ranges.addUnicodeProperty(name, inverted);
        return ranges;
    }

    fn findCaptureName(self: *const Compiler, name: []const u8, limit_capture_index: usize) ?usize {
        var capture_index: usize = 1;
        while (capture_index < limit_capture_index and capture_index - 1 < self.capture_names.items.len) : (capture_index += 1) {
            const existing = self.capture_names.items[capture_index - 1] orelse continue;
            if (groupNamesEqual(existing, name)) return capture_index;
        }
        return null;
    }

    fn findScannedCaptureName(self: *const Compiler, name: []const u8) ?usize {
        var capture_index: usize = 1;
        while (capture_index < self.total_capture_count and capture_index - 1 < self.all_capture_names.len) : (capture_index += 1) {
            const existing = self.all_capture_names[capture_index - 1] orelse continue;
            if (groupNamesEqual(existing, name)) return capture_index;
        }
        return null;
    }

    fn patternHasNamedCaptures(self: *const Compiler) bool {
        for (self.all_capture_names) |maybe_name| {
            if (maybe_name != null) return true;
        }
        return false;
    }

    fn parseDigits(self: *Compiler, allow_overflow: bool) CompileError!u32 {
        var value: u64 = 0;
        var saw_digit = false;
        while (self.index < self.pattern.len and isDecimalDigit(self.pattern[self.index])) : (self.index += 1) {
            saw_digit = true;
            value = value * 10 + (self.pattern[self.index] - '0');
            if (value >= int32_max) {
                if (!allow_overflow) return error.InvalidPattern;
                value = int32_max;
            }
        }
        if (!saw_digit) return error.InvalidPattern;
        return @intCast(value);
    }

    fn parseFixedHexEscape(self: *Compiler, digit_count: usize) CompileError!u21 {
        if (self.index + 2 + digit_count > self.pattern.len) return error.InvalidPattern;
        self.index += 2;
        var cp: u21 = 0;
        var i: usize = 0;
        while (i < digit_count) : (i += 1) {
            cp = cp * 16 + (hexValue(self.pattern[self.index]) orelse return error.InvalidPattern);
            self.index += 1;
        }
        return cp;
    }

    fn parseUnicodeEscape(self: *Compiler) CompileError!u21 {
        if (self.index + 1 >= self.pattern.len or self.pattern[self.index] != '\\' or self.pattern[self.index + 1] != 'u') return error.InvalidPattern;
        if (self.isBracedUnicodeEscape()) {
            self.index += 3;
            var cp: u21 = 0;
            var saw_digit = false;
            while (self.index < self.pattern.len and self.pattern[self.index] != '}') : (self.index += 1) {
                const digit = hexValue(self.pattern[self.index]) orelse return error.InvalidPattern;
                if (cp > max_code_point / 16) return error.InvalidPattern;
                cp = cp * 16 + digit;
                if (cp > max_code_point) return error.InvalidPattern;
                saw_digit = true;
            }
            if (!saw_digit or self.index >= self.pattern.len or self.pattern[self.index] != '}') return error.InvalidPattern;
            self.index += 1;
            return cp;
        }
        return self.parseFixedHexEscape(4);
    }

    fn isBracedUnicodeEscape(self: *const Compiler) bool {
        return self.flags.unicode and self.index + 2 < self.pattern.len and self.pattern[self.index + 2] == '{';
    }

    fn combineEscapedSurrogatePair(self: *Compiler, first: u21) CompileError!u21 {
        if (!self.flags.unicode or !isHiSurrogate(first)) return first;
        const saved = self.index;
        if (self.index + 5 >= self.pattern.len or self.pattern[self.index] != '\\' or self.pattern[self.index + 1] != 'u') return first;
        if (self.index + 2 < self.pattern.len and self.pattern[self.index + 2] == '{') return first;
        const second = try self.parseFixedHexEscape(4);
        if (!isLoSurrogate(second)) {
            self.index = saved;
            return first;
        }
        return fromSurrogate(@intCast(first), @intCast(second));
    }

    fn readPatternCodePoint(self: *Compiler) CompileError!u21 {
        if (self.index >= self.pattern.len) return error.InvalidPattern;
        const byte = self.pattern[self.index];
        if (byte < 0x80 and isRegexSyntax(byte)) return error.InvalidPattern;
        return self.readUtf8CodePoint();
    }

    fn readClassCodePoint(self: *Compiler) CompileError!u21 {
        return self.readUtf8CodePoint();
    }

    fn readUtf8CodePoint(self: *Compiler) CompileError!u21 {
        if (self.index >= self.pattern.len) return error.InvalidPattern;
        const byte = self.pattern[self.index];
        if (byte < 0x80) {
            self.index += 1;
            return byte;
        }
        if (decodeWtf8Surrogate(self.pattern, self.index)) |decoded| {
            self.index += decoded.len;
            return decoded.code_point;
        }
        const width = std.unicode.utf8ByteSequenceLength(byte) catch return error.InvalidPattern;
        if (self.index + width > self.pattern.len) return error.InvalidPattern;
        const cp = std.unicode.utf8Decode(self.pattern[self.index .. self.index + width]) catch return error.InvalidPattern;
        if (cp > max_code_point) return error.InvalidPattern;
        self.index += width;
        return @intCast(cp);
    }

    fn looksLikeQuantifier(self: *const Compiler, start: usize) bool {
        if (start + 1 >= self.pattern.len or !isDecimalDigit(self.pattern[start + 1])) return false;
        var pos = start + 1;
        while (pos < self.pattern.len and isDecimalDigit(self.pattern[pos])) : (pos += 1) {}
        if (pos < self.pattern.len and self.pattern[pos] == ',') {
            pos += 1;
            while (pos < self.pattern.len and isDecimalDigit(self.pattern[pos])) : (pos += 1) {}
        }
        return pos < self.pattern.len and self.pattern[pos] == '}';
    }

    fn emitChar(self: *Compiler, cp: u21) !void {
        if (cp <= 0x7f) {
            try self.emitOpU8(.char8, @intCast(cp));
        } else if (cp <= 0xffff) {
            try self.emitOpU16(.char16, @intCast(cp));
        } else {
            try self.emitOpU32(.char32, cp);
        }
    }

    fn emitCharacterAtom(self: *Compiler, cp: u21, is_backward_dir: bool) !void {
        if (is_backward_dir) try self.emitOp(.prev);
        try self.emitChar(cp);
        if (is_backward_dir) try self.emitOp(.prev);
    }

    fn emitNonUnicodeSurrogatePairAtom(self: *Compiler, cp: u21, is_backward_dir: bool) !void {
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

    fn emitNonUnicodeSurrogatePairTerms(self: *Compiler, cp: u21, is_backward_dir: bool) !usize {
        const pair = unicode.surrogatePairFromCodePoint(cp);
        const high: u21 = pair.high;
        const low: u21 = pair.low;
        if (is_backward_dir) {
            const low_start = self.code.items.len;
            try self.emitCharacterAtom(low, true);
            try self.emitCharacterAtom(high, true);
            return low_start;
        }
        try self.emitCharacterAtom(high, false);
        const low_start = self.code.items.len;
        try self.emitCharacterAtom(low, false);
        return low_start;
    }

    fn emitRangeSet(self: *Compiler, ranges: *RangeSet) !void {
        try ranges.normalize();
        if (ranges.ranges.items.len == 0) {
            try self.emitOpU16(.range32, 1);
            try self.appendU32(0xffffffff);
            try self.appendU32(0xffffffff);
            return;
        }
        const use_32 = ranges.ranges.items[ranges.ranges.items.len - 1].hi > 0x10000;
        if (use_32) {
            try self.emitOpU16(.range32, @intCast(ranges.ranges.items.len));
            for (ranges.ranges.items) |range| {
                try self.appendU32(range.lo);
                try self.appendU32(@as(u32, range.hi) - 1);
            }
        } else {
            try self.emitOpU16(.range, @intCast(ranges.ranges.items.len));
            for (ranges.ranges.items) |range| {
                try self.appendU16(@intCast(range.lo));
                try self.appendU16(@intCast(range.hi - 1));
            }
        }
    }

    fn emitOp(self: *Compiler, op: Op) !void {
        try self.code.append(self.allocator, opByte(op));
    }

    fn emitOpU8(self: *Compiler, op: Op, value: u8) !void {
        try self.emitOp(op);
        try self.code.append(self.allocator, value);
    }

    fn emitOpU16(self: *Compiler, op: Op, value: u16) !void {
        try self.emitOp(op);
        try self.appendU16(value);
    }

    fn emitOpU32(self: *Compiler, op: Op, value: u32) !void {
        try self.emitOp(op);
        try self.appendU32(value);
    }

    fn emitOpU32At(self: *Compiler, op: Op, value: u32) !usize {
        try self.emitOp(op);
        const pos = self.code.items.len;
        try self.appendU32(value);
        return pos;
    }

    fn emitOpI32(self: *Compiler, op: Op, value: i32) !void {
        try self.emitOpU32(op, @bitCast(value));
    }

    fn emitGoto(self: *Compiler, op: Op, target: usize) !void {
        try self.emitOp(op);
        const operand_pos = self.code.items.len;
        const base: isize = @intCast(operand_pos + 4);
        const destination: isize = @intCast(target);
        const offset: i32 = @intCast(destination - base);
        try self.appendU32(@bitCast(offset));
    }

    fn appendU16(self: *Compiler, value: u16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, value, .little);
        try self.code.appendSlice(self.allocator, &buf);
    }

    fn appendU32(self: *Compiler, value: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .little);
        try self.code.appendSlice(self.allocator, &buf);
    }

    fn insertBytes(self: *Compiler, index: usize, count: usize) !void {
        const old_len = self.code.items.len;
        try self.code.appendNTimes(self.allocator, 0, count);
        std.mem.copyBackwards(
            u8,
            self.code.items[index + count .. index + count + old_len - index],
            self.code.items[index..old_len],
        );
    }

    fn appendCodeCopy(self: *Compiler, start: usize, len: usize) !void {
        const copy = try self.allocator.dupe(u8, self.code.items[start .. start + len]);
        defer self.allocator.free(copy);
        try self.code.appendSlice(self.allocator, copy);
    }

    fn moveTermToStart(self: *Compiler, start: usize, term_start: usize, term_end: usize) !void {
        if (term_start == start or term_start == term_end) return;
        const term_len = term_end - term_start;
        const term = try self.allocator.dupe(u8, self.code.items[term_start..term_end]);
        defer self.allocator.free(term);
        std.mem.copyBackwards(
            u8,
            self.code.items[start + term_len .. term_end],
            self.code.items[start..term_start],
        );
        @memcpy(self.code.items[start .. start + term_len], term);
    }
};

const ClassAtom = union(enum) {
    code_point: u21,
    ranges: RangeSet,
};

const Range = struct {
    lo: u21,
    hi: u21,
};

const RangeSet = struct {
    allocator: std.mem.Allocator,
    ranges: std.ArrayList(Range),

    fn init(allocator: std.mem.Allocator) RangeSet {
        return .{ .allocator = allocator, .ranges = .empty };
    }

    fn deinit(self: *RangeSet) void {
        self.ranges.deinit(self.allocator);
    }

    fn addAtom(self: *RangeSet, atom: ClassAtom) !void {
        switch (atom) {
            .code_point => |cp| try self.addInclusive(cp, cp),
            .ranges => |owned_ranges| {
                defer {
                    var mutable = owned_ranges;
                    mutable.deinit();
                }
                try self.ranges.appendSlice(self.allocator, owned_ranges.ranges.items);
            },
        }
    }

    fn addSet(self: *RangeSet, other: *const RangeSet) !void {
        try self.ranges.appendSlice(self.allocator, other.ranges.items);
    }

    fn addInclusive(self: *RangeSet, lo: u21, hi_inclusive: u21) !void {
        if (hi_inclusive < lo) return error.InvalidPattern;
        if (hi_inclusive == max_code_point) {
            try self.ranges.append(self.allocator, .{ .lo = lo, .hi = max_code_point + 1 });
        } else {
            try self.ranges.append(self.allocator, .{ .lo = lo, .hi = hi_inclusive + 1 });
        }
    }

    fn addNonUnicodeSurrogatePair(self: *RangeSet, cp: u21) !void {
        const pair = unicode.surrogatePairFromCodePoint(cp);
        try self.addInclusive(pair.high, pair.high);
        try self.addInclusive(pair.low, pair.low);
    }

    fn addHalfOpen(self: *RangeSet, lo: u21, hi: u21) !void {
        if (hi <= lo) return;
        try self.ranges.append(self.allocator, .{ .lo = lo, .hi = hi });
    }

    fn addClassEscape(self: *RangeSet, escaped: u8) !void {
        switch (escaped) {
            'd', 'D' => {
                try self.addHalfOpen('0', '9' + 1);
                if (escaped == 'D') try self.invert();
            },
            's', 'S' => {
                try self.addHalfOpen(0x0009, 0x000d + 1);
                try self.addHalfOpen(0x0020, 0x0020 + 1);
                try self.addHalfOpen(0x00a0, 0x00a0 + 1);
                try self.addHalfOpen(0x1680, 0x1680 + 1);
                try self.addHalfOpen(0x2000, 0x200a + 1);
                try self.addHalfOpen(0x2028, 0x2029 + 1);
                try self.addHalfOpen(0x202f, 0x202f + 1);
                try self.addHalfOpen(0x205f, 0x205f + 1);
                try self.addHalfOpen(0x3000, 0x3000 + 1);
                try self.addHalfOpen(0xfeff, 0xfeff + 1);
                if (escaped == 'S') try self.invert();
            },
            'w', 'W' => {
                try self.addHalfOpen('0', '9' + 1);
                try self.addHalfOpen('A', 'Z' + 1);
                try self.addHalfOpen('_', '_' + 1);
                try self.addHalfOpen('a', 'z' + 1);
                if (escaped == 'W') try self.invert();
            },
            else => unreachable,
        }
    }

    fn addUnicodeProperty(self: *RangeSet, name: []const u8, inverted: bool) CompileError!void {
        const property_ranges = unicode.propertyRangesAlloc(self.allocator, name, inverted) catch |err| switch (err) {
            error.InvalidProperty => return error.InvalidPattern,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer self.allocator.free(property_ranges);
        for (property_ranges) |range| try self.addHalfOpen(range.lo, range.hi);
    }

    fn regexpCanonicalize(self: *RangeSet, is_unicode: bool) !void {
        try self.normalize();
        const bit_count: usize = @as(usize, max_code_point) + 1;
        var present = try self.allocator.alloc(bool, bit_count);
        defer self.allocator.free(present);
        @memset(present, false);

        for (self.ranges.items) |range| {
            var cp = range.lo;
            while (cp < range.hi) : (cp += 1) {
                const folded = unicode.regexpCanonicalize(cp, is_unicode);
                present[@intCast(folded)] = true;
            }
        }

        var canonical = std.ArrayList(Range).empty;
        errdefer canonical.deinit(self.allocator);
        var cp: usize = 0;
        while (cp < bit_count) {
            if (!present[cp]) {
                cp += 1;
                continue;
            }
            const start = cp;
            while (cp < bit_count and present[cp]) : (cp += 1) {}
            try canonical.append(self.allocator, .{ .lo = @intCast(start), .hi = @intCast(cp) });
        }

        self.ranges.deinit(self.allocator);
        self.ranges = canonical;
    }

    fn invert(self: *RangeSet) !void {
        try self.normalize();
        var inverted = std.ArrayList(Range).empty;
        errdefer inverted.deinit(self.allocator);
        var cursor: u21 = 0;
        for (self.ranges.items) |range| {
            if (cursor < range.lo) try inverted.append(self.allocator, .{ .lo = cursor, .hi = range.lo });
            if (cursor < range.hi) cursor = range.hi;
        }
        if (cursor <= max_code_point) try inverted.append(self.allocator, .{ .lo = cursor, .hi = max_code_point + 1 });
        self.ranges.deinit(self.allocator);
        self.ranges = inverted;
    }

    fn intersectWith(self: *RangeSet, other: *RangeSet) !void {
        try self.normalize();
        try other.normalize();
        var intersection = std.ArrayList(Range).empty;
        errdefer intersection.deinit(self.allocator);

        var lhs_index: usize = 0;
        var rhs_index: usize = 0;
        while (lhs_index < self.ranges.items.len and rhs_index < other.ranges.items.len) {
            const lhs = self.ranges.items[lhs_index];
            const rhs = other.ranges.items[rhs_index];
            const lo = @max(lhs.lo, rhs.lo);
            const hi = @min(lhs.hi, rhs.hi);
            if (lo < hi) try intersection.append(self.allocator, .{ .lo = lo, .hi = hi });
            if (lhs.hi < rhs.hi) {
                lhs_index += 1;
            } else {
                rhs_index += 1;
            }
        }

        self.ranges.deinit(self.allocator);
        self.ranges = intersection;
    }

    fn normalize(self: *RangeSet) !void {
        insertionSortRanges(self.ranges.items);
        if (self.ranges.items.len <= 1) return;
        var write: usize = 0;
        var read: usize = 1;
        while (read < self.ranges.items.len) : (read += 1) {
            const current = self.ranges.items[read];
            if (current.lo <= self.ranges.items[write].hi) {
                if (current.hi > self.ranges.items[write].hi) self.ranges.items[write].hi = current.hi;
            } else {
                write += 1;
                self.ranges.items[write] = current;
            }
        }
        self.ranges.shrinkRetainingCapacity(write + 1);
    }
};

fn insertionSortRanges(ranges: []Range) void {
    var i: usize = 1;
    while (i < ranges.len) : (i += 1) {
        const item = ranges[i];
        var j = i;
        while (j > 0 and ranges[j - 1].lo > item.lo) : (j -= 1) {
            ranges[j] = ranges[j - 1];
        }
        ranges[j] = item;
    }
}

fn computeStackSize(code: []const u8) CompileError!u8 {
    var pos: usize = 0;
    var stack_size: u16 = 0;
    var stack_size_max: u16 = 0;
    while (pos < code.len) {
        const op: Op = @enumFromInt(code[pos]);
        var len = opFixedSize(op) orelse return error.InvalidPattern;
        switch (op) {
            .push_i32, .push_char_pos => {
                stack_size += 1;
                if (stack_size > 255) return error.Unsupported;
                if (stack_size > stack_size_max) stack_size_max = stack_size;
            },
            .drop, .check_advance => {
                if (stack_size == 0) return error.InvalidPattern;
                stack_size -= 1;
            },
            .range => {
                if (pos + 3 > code.len) return error.InvalidPattern;
                const count = std.mem.readInt(u16, code[pos + 1 ..][0..2], .little);
                len += @as(usize, count) * 4;
            },
            .range32 => {
                if (pos + 3 > code.len) return error.InvalidPattern;
                const count = std.mem.readInt(u16, code[pos + 1 ..][0..2], .little);
                len += @as(usize, count) * 8;
            },
            else => {},
        }
        if (pos + len > code.len) return error.InvalidPattern;
        pos += len;
    }
    return @intCast(stack_size_max);
}

fn opFixedSize(op: Op) ?usize {
    return switch (op) {
        .invalid => null,
        .char8 => 2,
        .char16 => 3,
        .char32 => 5,
        .dot, .any, .line_start, .line_end, .match, .drop, .word_boundary, .not_word_boundary, .push_char_pos, .check_advance, .prev => 1,
        .goto_, .split_goto_first, .split_next_first, .loop, .push_i32, .lookahead, .negative_lookahead => 5,
        .save_start, .save_end, .back_reference, .backward_back_reference => 2,
        .save_reset, .range, .range32 => 3,
        .simple_greedy_quant => 17,
    };
}

fn canonicalizeLiteral(cp: u21, parsed_flags: ParsedFlags) u21 {
    if (!parsed_flags.ignore_case) return cp;
    return unicode.regexpCanonicalize(cp, parsed_flags.unicode);
}

fn opByte(op: Op) u8 {
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
            const digit = hexValue(pattern[pos]) orelse return error.InvalidPattern;
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
        value = value * 16 + (hexValue(pattern[pos + count]) orelse return error.InvalidPattern);
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

fn hexValue(byte: u8) ?u21 {
    const value = unicode.asciiHexDigitValueByte(byte) orelse return null;
    return @intCast(value);
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

fn isDecimalDigit(byte: u8) bool {
    return unicode.isAsciiDigitByte(byte);
}

fn isOctalDigit(byte: u8) bool {
    return unicode.isAsciiOctalDigitByte(byte);
}

fn isClassControlLetter(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

test "Zig regexp compiler emits bytecode for common ASCII patterns" {
    const allocator = std.testing.allocator;

    const literal = try compile(allocator, "a+", "");
    defer allocator.free(literal);
    const literal_status = try regex_bytecode.exec(allocator, literal, .{ .latin1 = "baaac" }, 0);
    try std.testing.expectEqual(.match, literal_status.result);
    try std.testing.expectEqual(@as(usize, 1), literal_status.match.start);
    try std.testing.expectEqual(@as(usize, 4), literal_status.match.end);

    const class = try compile(allocator, "^[\\d]+$", "");
    defer allocator.free(class);
    const class_status = try regex_bytecode.exec(allocator, class, .{ .latin1 = "123" }, 0);
    try std.testing.expectEqual(.match, class_status.result);
    try std.testing.expectEqual(@as(usize, 0), class_status.match.start);
    try std.testing.expectEqual(@as(usize, 3), class_status.match.end);

    const ignore_case_class = try compile(allocator, "[a-z]+", "iy");
    defer allocator.free(ignore_case_class);
    const ignore_case_class_status = try regex_bytecode.exec(allocator, ignore_case_class, .{ .latin1 = "AbC" }, 0);
    try std.testing.expectEqual(.match, ignore_case_class_status.result);
    try std.testing.expectEqual(@as(usize, 3), ignore_case_class_status.match.end);

    const unicode_ignore_case_class = try compile(allocator, "[A]", "iuy");
    defer allocator.free(unicode_ignore_case_class);
    const unicode_ignore_case_class_status = try regex_bytecode.exec(allocator, unicode_ignore_case_class, .{ .latin1 = "a" }, 0);
    try std.testing.expectEqual(.match, unicode_ignore_case_class_status.result);
    try std.testing.expectEqual(@as(usize, 1), unicode_ignore_case_class_status.match.end);

    const unicode_null_class = try compile(allocator, "([\\0]+)", "uy");
    defer allocator.free(unicode_null_class);
    const unicode_null_class_status = try regex_bytecode.exec(allocator, unicode_null_class, .{ .latin1 = "\x00" }, 0);
    try std.testing.expectEqual(.match, unicode_null_class_status.result);
    try std.testing.expectEqual(@as(usize, 1), unicode_null_class_status.match.end);
    try std.testing.expectError(error.InvalidPattern, compile(allocator, "[\\00]", "u"));

    const non_unicode_astral_class = try compile(allocator, "[\xf0\x9f\x90\xb8]", "y");
    defer allocator.free(non_unicode_astral_class);
    const frog_units = [_]u16{ 0xd83d, 0xdc38 };
    const non_unicode_astral_class_status = try regex_bytecode.exec(allocator, non_unicode_astral_class, .{ .utf16 = &frog_units }, 0);
    try std.testing.expectEqual(.match, non_unicode_astral_class_status.result);
    try std.testing.expectEqual(@as(usize, 0), non_unicode_astral_class_status.match.start);
    try std.testing.expectEqual(@as(usize, 1), non_unicode_astral_class_status.match.end);

    const non_unicode_astral_optional = try compile(allocator, "\xf0\x9f\x90\xb8?", "y");
    defer allocator.free(non_unicode_astral_optional);
    const non_unicode_astral_optional_frog = try regex_bytecode.exec(allocator, non_unicode_astral_optional, .{ .utf16 = &frog_units }, 0);
    try std.testing.expectEqual(.match, non_unicode_astral_optional_frog.result);
    try std.testing.expectEqual(@as(usize, 2), non_unicode_astral_optional_frog.match.end);
    const high_surrogate_only = [_]u16{0xd83d};
    const non_unicode_astral_optional_high = try regex_bytecode.exec(allocator, non_unicode_astral_optional, .{ .utf16 = &high_surrogate_only }, 0);
    try std.testing.expectEqual(.match, non_unicode_astral_optional_high.result);
    try std.testing.expectEqual(@as(usize, 1), non_unicode_astral_optional_high.match.end);
    const non_unicode_astral_optional_empty = try regex_bytecode.exec(allocator, non_unicode_astral_optional, .{ .latin1 = "" }, 0);
    try std.testing.expectEqual(.no_match, non_unicode_astral_optional_empty.result);

    const unicode_braced_after_high_surrogate = try compile(allocator, "\\uD83D\\u{3042}*", "uy");
    defer allocator.free(unicode_braced_after_high_surrogate);
    const high_surrogate_a = [_]u16{ 0xd83d, 0x3042, 0x3042 };
    const unicode_braced_after_high_status = try regex_bytecode.exec(allocator, unicode_braced_after_high_surrogate, .{ .utf16 = &high_surrogate_a }, 0);
    try std.testing.expectEqual(.match, unicode_braced_after_high_status.result);
    try std.testing.expectEqual(@as(usize, 3), unicode_braced_after_high_status.match.end);
    const unicode_braced_high_fixed_low = try compile(allocator, "\\u{D83D}\\uDC38+", "uy");
    defer allocator.free(unicode_braced_high_fixed_low);
    const unicode_braced_high_fixed_low_status = try regex_bytecode.exec(allocator, unicode_braced_high_fixed_low, .{ .utf16 = &frog_units }, 0);
    try std.testing.expectEqual(.no_match, unicode_braced_high_fixed_low_status.result);

    const annex_literal_brace = try compile(allocator, "a{1x", "y");
    defer allocator.free(annex_literal_brace);
    const annex_literal_brace_status = try regex_bytecode.exec(allocator, annex_literal_brace, .{ .latin1 = "a{1x" }, 0);
    try std.testing.expectEqual(.match, annex_literal_brace_status.result);
    try std.testing.expectEqual(@as(usize, 4), annex_literal_brace_status.match.end);

    const identity_escape = try compile(allocator, "\\q[\\p]", "y");
    defer allocator.free(identity_escape);
    const identity_escape_status = try regex_bytecode.exec(allocator, identity_escape, .{ .latin1 = "qp" }, 0);
    try std.testing.expectEqual(.match, identity_escape_status.result);
    try std.testing.expectEqual(@as(usize, 2), identity_escape_status.match.end);

    const empty_class = try compile(allocator, "[]", "y");
    defer allocator.free(empty_class);
    const empty_class_status = try regex_bytecode.exec(allocator, empty_class, .{ .latin1 = "" }, 0);
    try std.testing.expectEqual(.no_match, empty_class_status.result);

    const legacy_class_range = try compile(allocator, "[\\d-a]", "y");
    defer allocator.free(legacy_class_range);
    const legacy_class_range_status = try regex_bytecode.exec(allocator, legacy_class_range, .{ .latin1 = "-" }, 0);
    try std.testing.expectEqual(.match, legacy_class_range_status.result);
    const legacy_class_escape_status = try regex_bytecode.exec(allocator, legacy_class_range, .{ .latin1 = "5" }, 0);
    try std.testing.expectEqual(.match, legacy_class_escape_status.result);

    const legacy_octal = try compile(allocator, "\\141\\8", "y");
    defer allocator.free(legacy_octal);
    const legacy_octal_status = try regex_bytecode.exec(allocator, legacy_octal, .{ .latin1 = "a8" }, 0);
    try std.testing.expectEqual(.match, legacy_octal_status.result);
    try std.testing.expectEqual(@as(usize, 2), legacy_octal_status.match.end);

    const captures = try compile(allocator, "(a)\\1", "");
    defer allocator.free(captures);
    const capture_status = try regex_bytecode.exec(allocator, captures, .{ .latin1 = "xaa" }, 0);
    try std.testing.expectEqual(.match, capture_status.result);
    try std.testing.expectEqual(@as(usize, 1), capture_status.match.start);
    try std.testing.expectEqual(@as(usize, 3), capture_status.match.end);

    const disjunction = try compile(allocator, "foo|bar", "");
    defer allocator.free(disjunction);
    const disjunction_status = try regex_bytecode.exec(allocator, disjunction, .{ .latin1 = "xxbar" }, 0);
    try std.testing.expectEqual(.match, disjunction_status.result);
    try std.testing.expectEqual(@as(usize, 2), disjunction_status.match.start);
    try std.testing.expectEqual(@as(usize, 5), disjunction_status.match.end);

    const latin1 = try compile(allocator, "é+", "");
    defer allocator.free(latin1);
    const latin1_input = [_]u8{ 0xe9, 0xe9 };
    const latin1_status = try regex_bytecode.exec(allocator, latin1, .{ .latin1 = &latin1_input }, 0);
    try std.testing.expectEqual(.match, latin1_status.result);
    try std.testing.expectEqual(@as(usize, 0), latin1_status.match.start);
    try std.testing.expectEqual(@as(usize, 2), latin1_status.match.end);

    const escaped_astral = try compile(allocator, "\\uD834\\uDF06", "u");
    defer allocator.free(escaped_astral);
    const astral = [_]u16{ 0xd834, 0xdf06 };
    const escaped_astral_status = try regex_bytecode.exec(allocator, escaped_astral, .{ .utf16 = &astral }, 0);
    try std.testing.expectEqual(.match, escaped_astral_status.result);
    try std.testing.expectEqual(@as(usize, 0), escaped_astral_status.match.start);
    try std.testing.expectEqual(@as(usize, 2), escaped_astral_status.match.end);

    const unknown_script_property = try compile(allocator, "\\p{Script=Unknown}", "u");
    defer allocator.free(unknown_script_property);
    const unknown_input = [_]u16{0x038b};
    const unknown_script_property_status = try regex_bytecode.exec(allocator, unknown_script_property, .{ .utf16 = &unknown_input }, 0);
    try std.testing.expectEqual(.match, unknown_script_property_status.result);
    try std.testing.expectEqual(@as(usize, 1), unknown_script_property_status.match.end);

    const unknown_script_ext_property = try compile(allocator, "\\p{Script_Extensions=Unknown}", "u");
    defer allocator.free(unknown_script_ext_property);
    const unknown_script_ext_property_status = try regex_bytecode.exec(allocator, unknown_script_ext_property, .{ .utf16 = &unknown_input }, 0);
    try std.testing.expectEqual(.match, unknown_script_ext_property_status.result);
    try std.testing.expectEqual(@as(usize, 1), unknown_script_ext_property_status.match.end);

    const lookahead = try compile(allocator, "foo(?=bar)", "");
    defer allocator.free(lookahead);
    const lookahead_status = try regex_bytecode.exec(allocator, lookahead, .{ .latin1 = "xxfoobar" }, 0);
    try std.testing.expectEqual(.match, lookahead_status.result);
    try std.testing.expectEqual(@as(usize, 2), lookahead_status.match.start);
    try std.testing.expectEqual(@as(usize, 5), lookahead_status.match.end);

    const negative_lookahead = try compile(allocator, "foo(?!bar)", "");
    defer allocator.free(negative_lookahead);
    const negative_lookahead_status = try regex_bytecode.exec(allocator, negative_lookahead, .{ .latin1 = "xxfoobaz" }, 0);
    try std.testing.expectEqual(.match, negative_lookahead_status.result);
    try std.testing.expectEqual(@as(usize, 2), negative_lookahead_status.match.start);
    try std.testing.expectEqual(@as(usize, 5), negative_lookahead_status.match.end);
    const blocked_negative_status = try regex_bytecode.exec(allocator, negative_lookahead, .{ .latin1 = "xxfoobar" }, 0);
    try std.testing.expectEqual(.no_match, blocked_negative_status.result);

    const lookbehind = try compile(allocator, "(?<=foo)bar", "");
    defer allocator.free(lookbehind);
    const lookbehind_status = try regex_bytecode.exec(allocator, lookbehind, .{ .latin1 = "xxfoobar" }, 0);
    try std.testing.expectEqual(.match, lookbehind_status.result);
    try std.testing.expectEqual(@as(usize, 5), lookbehind_status.match.start);
    try std.testing.expectEqual(@as(usize, 8), lookbehind_status.match.end);

    const negative_lookbehind = try compile(allocator, "(?<!foo)bar", "");
    defer allocator.free(negative_lookbehind);
    const negative_lookbehind_status = try regex_bytecode.exec(allocator, negative_lookbehind, .{ .latin1 = "xxbar" }, 0);
    try std.testing.expectEqual(.match, negative_lookbehind_status.result);
    try std.testing.expectEqual(@as(usize, 2), negative_lookbehind_status.match.start);
    const blocked_negative_lookbehind_status = try regex_bytecode.exec(allocator, negative_lookbehind, .{ .latin1 = "foobar" }, 0);
    try std.testing.expectEqual(.no_match, blocked_negative_lookbehind_status.result);

    const lookbehind_capture = try compile(allocator, "(?<=(a)b)c", "");
    defer allocator.free(lookbehind_capture);
    const lookbehind_capture_status = try regex_bytecode.exec(allocator, lookbehind_capture, .{ .latin1 = "abc" }, 0);
    try std.testing.expectEqual(.match, lookbehind_capture_status.result);
    try std.testing.expectEqual(@as(usize, 2), lookbehind_capture_status.match.start);
    try std.testing.expectEqual(@as(?usize, 0), lookbehind_capture_status.match.captures[0].start);
    try std.testing.expectEqual(@as(?usize, 1), lookbehind_capture_status.match.captures[0].end);

    const named = try compile(allocator, "(?<x>a)", "");
    defer allocator.free(named);
    const named_status = try regex_bytecode.exec(allocator, named, .{ .latin1 = "ba" }, 0);
    try std.testing.expectEqual(.match, named_status.result);
    try std.testing.expectEqual(@as(usize, 1), named_status.match.start);
    try std.testing.expectEqual(@as(?usize, 1), named_status.match.captures[0].start);
    try std.testing.expectEqualStrings("x", named_status.match.captures[0].name.?);

    const named_backref = try compile(allocator, "(?<x>a)\\k<x>", "");
    defer allocator.free(named_backref);
    const named_backref_status = try regex_bytecode.exec(allocator, named_backref, .{ .latin1 = "xaa" }, 0);
    try std.testing.expectEqual(.match, named_backref_status.result);
    try std.testing.expectEqual(@as(usize, 1), named_backref_status.match.start);
    try std.testing.expectEqual(@as(usize, 3), named_backref_status.match.end);

    const forward_backref = try compile(allocator, "\\1(a)", "y");
    defer allocator.free(forward_backref);
    const forward_backref_status = try regex_bytecode.exec(allocator, forward_backref, .{ .latin1 = "a" }, 0);
    try std.testing.expectEqual(.match, forward_backref_status.result);
    try std.testing.expectEqual(@as(usize, 1), forward_backref_status.match.end);
    try std.testing.expectEqual(@as(?usize, 0), forward_backref_status.match.captures[0].start);
    try std.testing.expectEqual(@as(?usize, 1), forward_backref_status.match.captures[0].end);

    const forward_named_backref = try compile(allocator, "\\k<x>(?<x>a)", "y");
    defer allocator.free(forward_named_backref);
    const forward_named_backref_status = try regex_bytecode.exec(allocator, forward_named_backref, .{ .latin1 = "a" }, 0);
    try std.testing.expectEqual(.match, forward_named_backref_status.result);
    try std.testing.expectEqual(@as(usize, 1), forward_named_backref_status.match.end);
    try std.testing.expectEqual(@as(?usize, 0), forward_named_backref_status.match.captures[0].start);

    const grouped_quantifier = try compile(allocator, "(?:ab)+", "");
    defer allocator.free(grouped_quantifier);
    const grouped_quantifier_status = try regex_bytecode.exec(allocator, grouped_quantifier, .{ .latin1 = "xxababz" }, 0);
    try std.testing.expectEqual(.match, grouped_quantifier_status.result);
    try std.testing.expectEqual(@as(usize, 2), grouped_quantifier_status.match.start);
    try std.testing.expectEqual(@as(usize, 6), grouped_quantifier_status.match.end);

    const optional_capture = try compile(allocator, "(a)?b", "y");
    defer allocator.free(optional_capture);
    const skipped_capture_status = try regex_bytecode.exec(allocator, optional_capture, .{ .latin1 = "b" }, 0);
    try std.testing.expectEqual(.match, skipped_capture_status.result);
    try std.testing.expectEqual(@as(?usize, null), skipped_capture_status.match.captures[0].start);
    const matched_capture_status = try regex_bytecode.exec(allocator, optional_capture, .{ .latin1 = "ab" }, 0);
    try std.testing.expectEqual(.match, matched_capture_status.result);
    try std.testing.expectEqual(@as(?usize, 0), matched_capture_status.match.captures[0].start);
    try std.testing.expectEqual(@as(?usize, 1), matched_capture_status.match.captures[0].end);

    const repeated_capture = try compile(allocator, "(a)*", "y");
    defer allocator.free(repeated_capture);
    const repeated_capture_status = try regex_bytecode.exec(allocator, repeated_capture, .{ .latin1 = "aaa" }, 0);
    try std.testing.expectEqual(.match, repeated_capture_status.result);
    try std.testing.expectEqual(@as(usize, 3), repeated_capture_status.match.end);
    try std.testing.expectEqual(@as(?usize, 2), repeated_capture_status.match.captures[0].start);
    try std.testing.expectEqual(@as(?usize, 3), repeated_capture_status.match.captures[0].end);

    const repeated_capture_disjunction = try compile(allocator, "(.|\\r|\\n)*", "y");
    defer allocator.free(repeated_capture_disjunction);
    const repeated_capture_disjunction_status = try regex_bytecode.exec(allocator, repeated_capture_disjunction, .{ .latin1 = "undefined" }, 0);
    try std.testing.expectEqual(.match, repeated_capture_disjunction_status.result);
    try std.testing.expectEqual(@as(usize, 9), repeated_capture_disjunction_status.match.end);
    try std.testing.expectEqual(@as(?usize, 8), repeated_capture_disjunction_status.match.captures[0].start);
    try std.testing.expectEqual(@as(?usize, 9), repeated_capture_disjunction_status.match.captures[0].end);

    const scanned_repeated_capture_disjunction = try compile(allocator, "(.|\\r|\\n)*", "");
    defer allocator.free(scanned_repeated_capture_disjunction);
    const scanned_repeated_capture_disjunction_status = try regex_bytecode.exec(allocator, scanned_repeated_capture_disjunction, .{ .latin1 = "undefined" }, 0);
    try std.testing.expectEqual(.match, scanned_repeated_capture_disjunction_status.result);
    try std.testing.expectEqual(@as(usize, 9), scanned_repeated_capture_disjunction_status.match.end);
    const undefined_utf16 = [_]u16{ 'u', 'n', 'd', 'e', 'f', 'i', 'n', 'e', 'd' };
    const scanned_repeated_capture_disjunction_utf16_status = try regex_bytecode.exec(allocator, scanned_repeated_capture_disjunction, .{ .utf16 = &undefined_utf16 }, 0);
    try std.testing.expectEqual(.match, scanned_repeated_capture_disjunction_utf16_status.result);
    try std.testing.expectEqual(@as(usize, 9), scanned_repeated_capture_disjunction_utf16_status.match.end);

    const lazy_simple = try compile(allocator, "a+?", "y");
    defer allocator.free(lazy_simple);
    const lazy_simple_status = try regex_bytecode.exec(allocator, lazy_simple, .{ .latin1 = "aaa" }, 0);
    try std.testing.expectEqual(.match, lazy_simple_status.result);
    try std.testing.expectEqual(@as(usize, 1), lazy_simple_status.match.end);

    const lazy_followed = try compile(allocator, "a+?a", "y");
    defer allocator.free(lazy_followed);
    const lazy_followed_status = try regex_bytecode.exec(allocator, lazy_followed, .{ .latin1 = "aaa" }, 0);
    try std.testing.expectEqual(.match, lazy_followed_status.result);
    try std.testing.expectEqual(@as(usize, 2), lazy_followed_status.match.end);

    const lazy_optional_capture = try compile(allocator, "(a)??b", "y");
    defer allocator.free(lazy_optional_capture);
    const lazy_optional_capture_status = try regex_bytecode.exec(allocator, lazy_optional_capture, .{ .latin1 = "ab" }, 0);
    try std.testing.expectEqual(.match, lazy_optional_capture_status.result);
    try std.testing.expectEqual(@as(?usize, 0), lazy_optional_capture_status.match.captures[0].start);

    const disjunction_quantifier = try compile(allocator, "(?:foo|bar)*", "y");
    defer allocator.free(disjunction_quantifier);
    const disjunction_quantifier_status = try regex_bytecode.exec(allocator, disjunction_quantifier, .{ .latin1 = "foobarbarz" }, 0);
    try std.testing.expectEqual(.match, disjunction_quantifier_status.result);
    try std.testing.expectEqual(@as(usize, 0), disjunction_quantifier_status.match.start);
    try std.testing.expectEqual(@as(usize, 9), disjunction_quantifier_status.match.end);

    const hex_property = try compile(allocator, "\\p{Hex}+", "u");
    defer allocator.free(hex_property);
    const hex_property_status = try regex_bytecode.exec(allocator, hex_property, .{ .latin1 = "xxA9fg" }, 0);
    try std.testing.expectEqual(.match, hex_property_status.result);
    try std.testing.expectEqual(@as(usize, 2), hex_property_status.match.start);
    try std.testing.expectEqual(@as(usize, 5), hex_property_status.match.end);

    const uppercase_property = try compile(allocator, "\\p{Lu}+", "u");
    defer allocator.free(uppercase_property);
    const uppercase_property_status = try regex_bytecode.exec(allocator, uppercase_property, .{ .latin1 = "xAb" }, 0);
    try std.testing.expectEqual(.match, uppercase_property_status.result);
    try std.testing.expectEqual(@as(usize, 1), uppercase_property_status.match.start);
    try std.testing.expectEqual(@as(usize, 2), uppercase_property_status.match.end);

    const cased_letter_property = try compile(allocator, "\\p{LC}+", "u");
    defer allocator.free(cased_letter_property);
    const cased_letter_property_status = try regex_bytecode.exec(allocator, cased_letter_property, .{ .latin1 = "az" }, 0);
    try std.testing.expectEqual(.match, cased_letter_property_status.result);
    try std.testing.expectEqual(@as(usize, 2), cased_letter_property_status.match.end);

    const greek_script_property = try compile(allocator, "\\p{Script=Greek}", "u");
    defer allocator.free(greek_script_property);
    const greek_input = [_]u16{0x03b1};
    const greek_script_property_status = try regex_bytecode.exec(allocator, greek_script_property, .{ .utf16 = &greek_input }, 0);
    try std.testing.expectEqual(.match, greek_script_property_status.result);
    try std.testing.expectEqual(@as(usize, 1), greek_script_property_status.match.end);

    const not_ascii_property = try compile(allocator, "\\P{ASCII}", "u");
    defer allocator.free(not_ascii_property);
    const non_ascii_input = [_]u8{ 'a', 0xe9 };
    const not_ascii_property_status = try regex_bytecode.exec(allocator, not_ascii_property, .{ .latin1 = &non_ascii_input }, 0);
    try std.testing.expectEqual(.match, not_ascii_property_status.result);
    try std.testing.expectEqual(@as(usize, 1), not_ascii_property_status.match.start);
    try std.testing.expectEqual(@as(usize, 2), not_ascii_property_status.match.end);

    const property_class = try compile(allocator, "[\\p{Hex}\\P{Hex}]", "u");
    defer allocator.free(property_class);
    const property_class_status = try regex_bytecode.exec(allocator, property_class, .{ .latin1 = "Z" }, 0);
    try std.testing.expectEqual(.match, property_class_status.result);
    try std.testing.expectEqual(@as(usize, 0), property_class_status.match.start);
    try std.testing.expectEqual(@as(usize, 1), property_class_status.match.end);
}
