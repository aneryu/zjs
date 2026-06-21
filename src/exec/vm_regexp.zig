const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const op = bytecode.opcode.op;

// RegExp construct records keyed by native-builtin ref: the literal opcode
// handlers run the builtin RegExp constructor bodies through the record table
// (Phase 6b-3 STEP 4) rather than naming `builtins.regexp` directly. The
// `.construct` ref validates the (pattern, flags) value pair; the
// `.construct_prevalidated` ref skips recompilation for parser-validated
// literals. Both construct branches read only `args`/`new_target`, so no
// constructor function object or caller frame is threaded.
const regexp_construct_ref = core.function.NativeBuiltinRef{
    .domain = .regexp,
    .id = @intFromEnum(core.host_function.builtin_method_ids.regexp.ConstructorMethod.construct),
};
const regexp_construct_prevalidated_ref = core.function.NativeBuiltinRef{
    .domain = .regexp,
    .id = @intFromEnum(core.host_function.builtin_method_ids.regexp.ConstructorMethod.construct_prevalidated),
};

fn constructRegExpRecord(
    ctx: *core.JSContext,
    native_ref: core.function.NativeBuiltinRef,
    prototype: ?*core.Object,
    pattern: core.JSValue,
    flags: core.JSValue,
) !core.JSValue {
    const args = [_]core.JSValue{ pattern, flags };
    return (try builtin_dispatch.callConstructRecord(ctx, null, null, &.{}, null, native_ref, prototype, &args, null, null)) orelse error.TypeError;
}

pub noinline fn pushLiteral(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    prototype: ?*core.Object,
) !void {
    const flags = try stack.pop();
    defer flags.free(ctx.runtime);
    const pattern = try stack.pop();
    defer pattern.free(ctx.runtime);

    const value = try constructRegExpRecord(ctx, regexp_construct_ref, prototype, pattern, flags);
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
}

pub fn tryPushLiteralFromAtomPair(
    ctx: *core.JSContext,
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

    // Keep the original fusion gate: only short ASCII pattern/flags atoms
    // take this fast path.
    var pattern_buf: [10]u8 = undefined;
    var flags_buf: [10]u8 = undefined;
    if (atomStringBytes(ctx.runtime, pattern_atom, &pattern_buf) == null) return false;
    if (flags_atom) |atom_id| {
        if (atomStringBytes(ctx.runtime, atom_id, &flags_buf) == null) return false;
    }

    const pattern = try ctx.runtime.atoms.toStringValue(ctx.runtime, pattern_atom);
    defer pattern.free(ctx.runtime);
    const flags = if (flags_atom) |atom_id|
        try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id)
    else
        (try ctx.runtime.emptyString()).value().dup();
    defer flags.free(ctx.runtime);

    const value = try constructRegExpRecord(ctx, regexp_construct_prevalidated_ref, prototype, pattern, flags);
    errdefer value.free(ctx.runtime);
    try stack.pushOwned(value);
    frame.pc = after_regexp_pc;
    return true;
}

const LocalAccess = struct {
    idx: u16,
    next_pc: usize,
};

fn atomStringBytes(rt: *core.JSRuntime, atom_id: core.Atom, buf: *[10]u8) ?[]const u8 {
    if (rt.atoms.name(atom_id)) |name| return name;
    if (core.atom.isTaggedInt(atom_id)) {
        return std.fmt.bufPrint(buf, "{d}", .{core.atom.atomToUInt32(atom_id)}) catch null;
    }
    return null;
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
