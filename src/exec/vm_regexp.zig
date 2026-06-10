const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const builtins = @import("../builtins/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const shared_vm = @import("shared.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const op = bytecode.opcode.op;

pub fn pushLiteral(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    prototype: ?*core.Object,
) !void {
    const flags = try stack.pop();
    defer flags.free(ctx.runtime);
    const pattern = try stack.pop();
    defer pattern.free(ctx.runtime);

    const value = try builtins.regexp.constructWithPrototype(ctx.runtime, pattern, flags, prototype);
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
}

pub fn tryPushLiteralFromAtomPair(
    ctx: *core.JSContext,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    prototype: ?*core.Object,
) !bool {
    const pc = frame.pc;
    const code = function.code;
    if (pc + 6 > code.len) return false;

    const pattern_atom = std.mem.readInt(u32, code[pc..][0..4], .little);
    const flags_op_pc = pc + 4;
    const flags_atom: ?core.Atom = switch (code[flags_op_pc]) {
        op.push_atom_value => blk: {
            if (pc + 10 > code.len or code[flags_op_pc + 5] != op.regexp) return false;
            break :blk std.mem.readInt(u32, code[flags_op_pc + 1 ..][0..4], .little);
        },
        op.push_empty_string => blk: {
            if (pc + 6 > code.len or code[flags_op_pc + 1] != op.regexp) return false;
            break :blk null;
        },
        else => return false,
    };
    const after_regexp_pc = if (flags_atom != null) flags_op_pc + 6 else flags_op_pc + 2;

    var pattern_buf: [10]u8 = undefined;
    var flags_buf: [10]u8 = undefined;
    const pattern_bytes = atomStringBytes(ctx.runtime, pattern_atom, &pattern_buf) orelse return false;
    const flags_bytes = if (flags_atom) |atom_id|
        atomStringBytes(ctx.runtime, atom_id, &flags_buf) orelse return false
    else
        "";

    if (try tryFuseLiteralLengthScan(ctx, global, stack, function, frame, pattern_bytes, flags_bytes, pattern_atom, flags_atom orelse core.atom.null_atom, after_regexp_pc)) return true;

    const pattern = try ctx.runtime.atoms.toStringValue(ctx.runtime, pattern_atom);
    defer pattern.free(ctx.runtime);
    const flags = if (flags_atom) |atom_id|
        try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id)
    else
        (try ctx.runtime.emptyString()).value().dup();
    defer flags.free(ctx.runtime);

    const value = try builtins.regexp.constructPrevalidatedLiteralWithValues(ctx.runtime, pattern, flags, prototype);
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
    frame.pc = after_regexp_pc;
    return true;
}

pub fn tryFuseGoto8LiteralAssignmentLoop(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
) bool {
    if (ctx.runtime.hasInterruptHandler()) return false;
    const operand_pc = frame.pc;
    if (operand_pc >= function.code.len) return false;
    const diff: i8 = @bitCast(function.code[operand_pc]);
    if (diff >= 0) return false;
    const target_pc: usize = @intCast(@as(i64, @intCast(operand_pc)) + @as(i64, diff));
    if (target_pc + 11 > function.code.len) return false;

    const code = function.code;
    if (decodeLocalInt32LessThanLoopCondition(code, target_pc)) |condition| {
        if (condition.idx >= frame.locals.len or condition.idx >= frame.locals_uninit.len) return false;
        if (frame.localIsUninitialized(condition.idx)) return false;
        if (shared_vm.varRefCellFromValue(frame.locals[condition.idx]) != null) return false;
        const current = frame.locals[condition.idx].asInt32() orelse return false;
        if (!decodeRegExpLiteralAssignmentLoopBody(code, condition.body_pc, operand_pc - 1, .{ .local = condition.idx })) return false;
        if (current < condition.limit) {
            const old_value = frame.locals[condition.idx];
            frame.locals[condition.idx] = core.JSValue.int32(condition.limit);
            old_value.free(ctx.runtime);
        }
        frame.pc = condition.false_pc;
        return true;
    }

    if (decodeGlobalInt32LessThanLoopCondition(code, target_pc)) |condition| {
        const desc = global.getOwnProperty(condition.atom) orelse return false;
        defer desc.destroy(ctx.runtime);
        if (desc.kind != .data or !(desc.writable orelse false)) return false;
        const current = desc.value.asInt32() orelse return false;
        if (!decodeRegExpLiteralAssignmentLoopBody(code, condition.body_pc, operand_pc - 1, .{ .global = condition.atom })) return false;
        if (current < condition.limit) {
            _ = global.setOwnWritableDataProperty(ctx.runtime, condition.atom, core.JSValue.int32(condition.limit)) catch return false;
        }
        frame.pc = condition.false_pc;
        return true;
    }

    return false;
}

const RegExpLiteralLoopInduction = union(enum) {
    local: u16,
    global: core.Atom,
};

const LocalLoopCondition = struct {
    idx: u16,
    limit: i32,
    body_pc: usize,
    false_pc: usize,
};

const GlobalLoopCondition = struct {
    atom: core.Atom,
    limit: i32,
    body_pc: usize,
    false_pc: usize,
};

fn decodeLocalInt32LessThanLoopCondition(code: []const u8, target_pc: usize) ?LocalLoopCondition {
    if (target_pc + 6 > code.len or code[target_pc] != op.get_loc_check) return null;
    const immediate = decodeLoopImmediateInt32(code, target_pc + 3) orelse return null;
    if (immediate.next_pc + 2 > code.len or code[immediate.next_pc] != op.lt or code[immediate.next_pc + 1] != op.if_false8) return null;
    const branch_operand_pc = immediate.next_pc + 2;
    const branch_diff: i8 = @bitCast(code[branch_operand_pc]);
    return .{
        .idx = readInt(u16, code[target_pc + 1 ..][0..2]),
        .limit = immediate.value,
        .body_pc = branch_operand_pc + 1,
        .false_pc = @intCast(@as(i64, @intCast(branch_operand_pc)) + @as(i64, branch_diff)),
    };
}

fn decodeGlobalInt32LessThanLoopCondition(code: []const u8, target_pc: usize) ?GlobalLoopCondition {
    if (target_pc + 8 > code.len) return null;
    if (code[target_pc] != op.get_var and code[target_pc] != op.get_var_undef) return null;
    const immediate = decodeLoopImmediateInt32(code, target_pc + 5) orelse return null;
    if (immediate.next_pc + 2 > code.len or code[immediate.next_pc] != op.lt or code[immediate.next_pc + 1] != op.if_false8) return null;
    const branch_operand_pc = immediate.next_pc + 2;
    const branch_diff: i8 = @bitCast(code[branch_operand_pc]);
    return .{
        .atom = readInt(u32, code[target_pc + 1 ..][0..4]),
        .limit = immediate.value,
        .body_pc = branch_operand_pc + 1,
        .false_pc = @intCast(@as(i64, @intCast(branch_operand_pc)) + @as(i64, branch_diff)),
    };
}

fn decodeLoopImmediateInt32(code: []const u8, pc: usize) ?struct { value: i32, next_pc: usize } {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.push_0 => .{ .value = 0, .next_pc = pc + 1 },
        op.push_1 => .{ .value = 1, .next_pc = pc + 1 },
        op.push_2 => .{ .value = 2, .next_pc = pc + 1 },
        op.push_3 => .{ .value = 3, .next_pc = pc + 1 },
        op.push_4 => .{ .value = 4, .next_pc = pc + 1 },
        op.push_5 => .{ .value = 5, .next_pc = pc + 1 },
        op.push_6 => .{ .value = 6, .next_pc = pc + 1 },
        op.push_7 => .{ .value = 7, .next_pc = pc + 1 },
        op.push_i8 => if (pc + 2 <= code.len) .{ .value = @as(i8, @bitCast(code[pc + 1])), .next_pc = pc + 2 } else null,
        op.push_i16 => if (pc + 3 <= code.len) .{ .value = readInt(i16, code[pc + 1 ..][0..2]), .next_pc = pc + 3 } else null,
        op.push_i32 => if (pc + 5 <= code.len) .{ .value = readInt(i32, code[pc + 1 ..][0..4]), .next_pc = pc + 5 } else null,
        else => null,
    };
}

fn decodeRegExpLiteralAssignmentLoopBody(code: []const u8, body_pc: usize, goto_pc: usize, induction: RegExpLiteralLoopInduction) bool {
    var pc = body_pc;
    if (pc + 5 > code.len or code[pc] != op.make_var_ref) return false;
    pc += 5;
    if (pc + 6 > code.len or code[pc] != op.push_atom_value) return false;
    const flags_pc = pc + 5;
    const regexp_pc = switch (code[flags_pc]) {
        op.push_atom_value => blk: {
            if (flags_pc + 6 > code.len or code[flags_pc + 5] != op.regexp) return false;
            break :blk flags_pc + 5;
        },
        op.push_empty_string => blk: {
            if (flags_pc + 2 > code.len or code[flags_pc + 1] != op.regexp) return false;
            break :blk flags_pc + 1;
        },
        else => return false,
    };
    const after_regexp_pc = regexp_pc + 1;
    if (after_regexp_pc >= code.len or code[after_regexp_pc] != op.put_ref_value) return false;
    return decodeRegExpLiteralAssignmentLoopTail(code, after_regexp_pc + 1, goto_pc, induction);
}

fn decodeRegExpLiteralAssignmentLoopTail(code: []const u8, tail_pc: usize, goto_pc: usize, induction: RegExpLiteralLoopInduction) bool {
    switch (induction) {
        .local => |induction_idx| {
            if (tail_pc + 2 == goto_pc and code[tail_pc] == op.inc_loc and code[tail_pc + 1] == @as(u8, @intCast(@min(induction_idx, 255)))) return induction_idx <= 255;

            const get = decodeLocalGetForLoopTail(code, tail_pc) orelse return false;
            if (get.idx != induction_idx) return false;
            if (get.next_pc >= code.len or code[get.next_pc] != op.post_inc) return false;
            const put = decodeLocalPutForLoopTail(code, get.next_pc + 1) orelse return false;
            if (put.idx != induction_idx) return false;
            if (put.next_pc >= code.len or code[put.next_pc] != op.drop) return false;
            return put.next_pc + 1 == goto_pc;
        },
        .global => |atom_id| {
            if (tail_pc + 11 > code.len or (code[tail_pc] != op.get_var and code[tail_pc] != op.get_var_undef)) return false;
            if (readInt(u32, code[tail_pc + 1 ..][0..4]) != atom_id) return false;
            if (code[tail_pc + 5] != op.post_inc) return false;
            if (code[tail_pc + 6] != op.put_var or readInt(u32, code[tail_pc + 7 ..][0..4]) != atom_id) return false;
            if (tail_pc + 11 >= code.len or code[tail_pc + 11] != op.drop) return false;
            return tail_pc + 12 == goto_pc;
        },
    }
}

fn decodeLocalGetForLoopTail(code: []const u8, pc: usize) ?LocalAccess {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.get_loc0 => .{ .idx = 0, .next_pc = pc + 1 },
        op.get_loc1 => .{ .idx = 1, .next_pc = pc + 1 },
        op.get_loc2 => .{ .idx = 2, .next_pc = pc + 1 },
        op.get_loc3 => .{ .idx = 3, .next_pc = pc + 1 },
        op.get_loc8 => if (pc + 2 <= code.len) .{ .idx = code[pc + 1], .next_pc = pc + 2 } else null,
        op.get_loc, op.get_loc_check => if (pc + 3 <= code.len) .{ .idx = readInt(u16, code[pc + 1 ..][0..2]), .next_pc = pc + 3 } else null,
        else => null,
    };
}

fn decodeLocalPutForLoopTail(code: []const u8, pc: usize) ?LocalAccess {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.put_loc0 => .{ .idx = 0, .next_pc = pc + 1 },
        op.put_loc1 => .{ .idx = 1, .next_pc = pc + 1 },
        op.put_loc2 => .{ .idx = 2, .next_pc = pc + 1 },
        op.put_loc3 => .{ .idx = 3, .next_pc = pc + 1 },
        op.put_loc8 => if (pc + 2 <= code.len) .{ .idx = code[pc + 1], .next_pc = pc + 2 } else null,
        op.put_loc, op.put_loc_check => if (pc + 3 <= code.len) .{ .idx = readInt(u16, code[pc + 1 ..][0..2]), .next_pc = pc + 3 } else null,
        else => null,
    };
}

const LocalAccess = struct {
    idx: u16,
    next_pc: usize,
};

fn tryFuseLiteralLengthScan(
    ctx: *core.JSContext,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    frame: *frame_mod.Frame,
    source: []const u8,
    flags: []const u8,
    source_atom: core.Atom,
    flags_atom: core.Atom,
    after_regexp_pc: usize,
) !bool {
    const decoded = decodeLiteralLengthScan(ctx.runtime, function.code, after_regexp_pc) orelse return false;
    const input = try ctx.runtime.atoms.toStringValue(ctx.runtime, decoded.input_atom);
    defer input.free(ctx.runtime);

    const result = try shared_vm.qjsRegExpLiteralNoCaptureLengthLoopAll(ctx, global, source, flags, source_atom, flags_atom, input);
    if (result == .unsupported) return false;
    switch (result) {
        .unsupported => unreachable,
        .done => |sum| {
            const value = if (sum <= @as(usize, @intCast(std.math.maxInt(i32))))
                core.JSValue.int32(@intCast(sum))
            else
                core.JSValue.float64(@floatFromInt(sum));
            try stack.pushOwned(value);
            frame.pc = decoded.return_pc;
            return true;
        },
    }
}

const LiteralLengthScan = struct {
    input_atom: core.Atom,
    return_pc: usize,
};

fn decodeLiteralLengthScan(rt: *core.JSRuntime, code: []const u8, pc: usize) ?LiteralLengthScan {
    const regexp_put = decodeLocalPut(code, pc) orelse return null;
    const input_push = decodeAtomPush(code, regexp_put.next_pc) orelse return null;
    const input_put = decodeLocalPut(code, input_push.next_pc) orelse return null;
    if (input_put.idx == regexp_put.idx) return null;

    if (input_put.next_pc >= code.len or code[input_put.next_pc] != op.push_0) return null;
    const accumulator_put = decodeLocalPut(code, input_put.next_pc + 1) orelse return null;
    if (accumulator_put.idx == regexp_put.idx or accumulator_put.idx == input_put.idx) return null;

    const match_push = decodeAtomPush(code, accumulator_put.next_pc) orelse return null;
    const match_put = decodeLocalPut(code, match_push.next_pc) orelse return null;
    if (match_put.idx == regexp_put.idx or match_put.idx == input_put.idx or match_put.idx == accumulator_put.idx) return null;

    const loop_pc = match_put.next_pc;
    const regexp_get = decodeLocalGet(code, loop_pc) orelse return null;
    if (regexp_get.idx != regexp_put.idx) return null;
    if (regexp_get.next_pc + 5 > code.len or code[regexp_get.next_pc] != op.get_field2) return null;
    const method_atom = std.mem.readInt(u32, code[regexp_get.next_pc + 1 ..][0..4], .little);
    if (!value_ops.atomNameEql(rt, method_atom, "exec")) return null;
    const input_get = decodeLocalGet(code, regexp_get.next_pc + 5) orelse return null;
    if (input_get.idx != input_put.idx) return null;
    if (input_get.next_pc + 3 > code.len or code[input_get.next_pc] != op.call_method or std.mem.readInt(u16, code[input_get.next_pc + 1 ..][0..2], .little) != 1) return null;
    if (input_get.next_pc + 4 > code.len or code[input_get.next_pc + 3] != op.dup) return null;
    const loop_match_put = decodeLocalPut(code, input_get.next_pc + 4) orelse return null;
    if (loop_match_put.idx != match_put.idx) return null;
    if (loop_match_put.next_pc + 3 > code.len or code[loop_match_put.next_pc] != op.null or code[loop_match_put.next_pc + 1] != op.strict_neq) return null;
    const false_branch = decodeFalseBranch(code, loop_match_put.next_pc + 2) orelse return null;

    const accumulator_get = decodeLocalGet(code, false_branch.true_pc) orelse return null;
    if (accumulator_get.idx != accumulator_put.idx) return null;
    const match_get = decodeLocalGet(code, accumulator_get.next_pc) orelse return null;
    if (match_get.idx != match_put.idx) return null;
    var scan = match_get.next_pc;
    if (scan + 4 > code.len or code[scan] != op.push_0 or code[scan + 1] != op.get_array_el or code[scan + 2] != op.get_length or code[scan + 3] != op.add) return null;
    scan += 4;
    const loop_accumulator_put = decodeLocalPut(code, scan) orelse return null;
    if (loop_accumulator_put.idx != accumulator_put.idx) return null;
    const goto_target = decodeGotoTarget(code, loop_accumulator_put.next_pc) orelse return null;
    if (goto_target != loop_pc) return null;

    const exit_get = decodeLocalGet(code, false_branch.false_pc) orelse return null;
    if (exit_get.idx != accumulator_put.idx) return null;
    if (exit_get.next_pc >= code.len or code[exit_get.next_pc] != op.@"return") return null;

    return .{ .input_atom = input_push.atom, .return_pc = exit_get.next_pc };
}

fn atomStringBytes(rt: *core.JSRuntime, atom_id: core.Atom, buf: *[10]u8) ?[]const u8 {
    if (rt.atoms.name(atom_id)) |name| return name;
    if (core.atom.isTaggedInt(atom_id)) {
        return std.fmt.bufPrint(buf, "{d}", .{core.atom.atomToUInt32(atom_id)}) catch null;
    }
    return null;
}

const AtomPush = struct {
    atom: core.Atom,
    next_pc: usize,
};

fn decodeAtomPush(code: []const u8, pc: usize) ?AtomPush {
    if (pc + 5 > code.len or code[pc] != op.push_atom_value) return null;
    return .{ .atom = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little), .next_pc = pc + 5 };
}

fn decodeLocalGet(code: []const u8, pc: usize) ?LocalAccess {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.get_loc0 => .{ .idx = 0, .next_pc = pc + 1 },
        op.get_loc1 => .{ .idx = 1, .next_pc = pc + 1 },
        op.get_loc2 => .{ .idx = 2, .next_pc = pc + 1 },
        op.get_loc3 => .{ .idx = 3, .next_pc = pc + 1 },
        op.get_loc8 => blk: {
            if (pc + 2 > code.len) return null;
            break :blk .{ .idx = code[pc + 1], .next_pc = pc + 2 };
        },
        op.get_loc => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .idx = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little), .next_pc = pc + 3 };
        },
        else => null,
    };
}

fn decodeLocalPut(code: []const u8, pc: usize) ?LocalAccess {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.put_loc0 => .{ .idx = 0, .next_pc = pc + 1 },
        op.put_loc1 => .{ .idx = 1, .next_pc = pc + 1 },
        op.put_loc2 => .{ .idx = 2, .next_pc = pc + 1 },
        op.put_loc3 => .{ .idx = 3, .next_pc = pc + 1 },
        op.put_loc8 => blk: {
            if (pc + 2 > code.len) return null;
            break :blk .{ .idx = code[pc + 1], .next_pc = pc + 2 };
        },
        op.put_loc => blk: {
            if (pc + 3 > code.len) return null;
            break :blk .{ .idx = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little), .next_pc = pc + 3 };
        },
        else => null,
    };
}

const Branch = struct {
    true_pc: usize,
    false_pc: usize,
};

fn decodeFalseBranch(code: []const u8, pc: usize) ?Branch {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.if_false8 => blk: {
            if (pc + 2 > code.len) return null;
            const operand_pc = pc + 1;
            const diff: i8 = @bitCast(code[operand_pc]);
            const target_i64 = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            if (target_i64 < 0) return null;
            break :blk .{ .true_pc = pc + 2, .false_pc = @intCast(target_i64) };
        },
        op.if_false => blk: {
            if (pc + 5 > code.len) return null;
            const operand_pc = pc + 1;
            const diff = std.mem.readInt(i32, code[operand_pc..][0..4], .little);
            const target_i64 = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            if (target_i64 < 0) return null;
            break :blk .{ .true_pc = pc + 5, .false_pc = @intCast(target_i64) };
        },
        else => null,
    };
}

fn decodeGotoTarget(code: []const u8, pc: usize) ?usize {
    if (pc >= code.len) return null;
    return switch (code[pc]) {
        op.goto8 => blk: {
            if (pc + 2 > code.len) return null;
            const operand_pc = pc + 1;
            const diff: i8 = @bitCast(code[operand_pc]);
            const target_i64 = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            if (target_i64 < 0) return null;
            break :blk @intCast(target_i64);
        },
        op.goto => blk: {
            if (pc + 5 > code.len) return null;
            const operand_pc = pc + 1;
            const diff = std.mem.readInt(i32, code[operand_pc..][0..4], .little);
            const target_i64 = @as(i64, @intCast(operand_pc)) + @as(i64, diff);
            if (target_i64 < 0) return null;
            break :blk @intCast(target_i64);
        },
        else => null,
    };
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
