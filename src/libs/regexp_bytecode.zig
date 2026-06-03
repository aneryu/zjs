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
    return (code_point >= '0' and code_point <= '9') or
        (code_point >= 'a' and code_point <= 'z') or
        (code_point >= 'A' and code_point <= 'Z') or
        code_point == '_';
}

fn isHiSurrogate(code_unit: u21) bool {
    return code_unit >= 0xd800 and code_unit <= 0xdbff;
}

fn isLoSurrogate(code_unit: u21) bool {
    return code_unit >= 0xdc00 and code_unit <= 0xdfff;
}

fn fromSurrogate(high: u16, low: u16) u21 {
    return 0x10000 + ((@as(u21, high) - 0xd800) << 10) + (@as(u21, low) - 0xdc00);
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
