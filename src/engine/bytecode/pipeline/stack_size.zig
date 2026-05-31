//! Phase 3c: compute_stack_size
//!
//! Mirrors `compute_stack_size` at `quickjs.c:35167`.
//!
//! Performs a BFS over the bytecode graph to compute the maximum
//! stack depth. Validates that:
//!   - no path causes a stack underflow
//!   - the same pc is never revisited with a different stack level
//!   - max stack depth never exceeds `JS_STACK_SIZE_MAX`
//!
//! Operates on bytecode that has already been through `resolve_labels`
//! (jumps are relative); the BFS walks fall-through and jump
//! successors symmetrically.

const std = @import("std");
const opcode = @import("../opcode.zig");

/// `JS_STACK_SIZE_MAX` mirror.
pub const JS_STACK_SIZE_MAX: u16 = 0xFFFE;

/// Sentinel: pc has not yet been visited.
const STACK_LEVEL_UNVISITED: u16 = 0xFFFF;

pub const Error = error{
    StackUnderflow,
    StackOverflow,
    StackMismatch,
    InvalidOpcode,
    BytecodeOverflow,
    OutOfMemory,
};

/// Options for the BFS. When opcode_table is omitted, the generated
/// QuickJS metadata baked into `opcode.zig` is used.
pub const Options = struct {
    opcode_table: ?*const opcode.ParsedTable = null,
};

/// Compute the maximum stack size required to execute `bytecode`.
///
/// Returns 0 for empty bytecode (no instructions to execute).
pub fn compute(bytecode: []const u8, options: Options) Error!u16 {
    if (bytecode.len == 0) return 0;

    const allocator = std.heap.page_allocator;
    const stack_level_tab = try allocator.alloc(u16, bytecode.len);
    defer allocator.free(stack_level_tab);
    @memset(stack_level_tab, STACK_LEVEL_UNVISITED);
    const catch_pos_tab = try allocator.alloc(i32, bytecode.len);
    defer allocator.free(catch_pos_tab);
    @memset(catch_pos_tab, -1);

    var pc_stack: std.ArrayList(u32) = .empty;
    defer pc_stack.deinit(allocator);

    // Seed: entry pc=0 with stack level 0.
    try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, 0, 0, -1);

    var stack_len_max: u16 = 0;

    while (pc_stack.pop()) |pos_any| {
        const pos: u32 = pos_any;
        var stack_len = stack_level_tab[pos];
        var catch_pos = catch_pos_tab[pos];
        const op = bytecode[pos];
        if (op == 0) return error.InvalidOpcode;
        const meta = metadataFor(op, options) orelse return error.InvalidOpcode;
        const name = meta.name;
        const pos_next = pos + meta.size;
        if (pos_next > bytecode.len) return error.BytecodeOverflow;

        // Compute n_pop, accounting for npop/npop_u16/npopx variable forms.
        var n_pop: u32 = meta.n_pop;
        switch (meta.format) {
            .npop, .npop_u16 => {
                if (pos + 1 + 2 > bytecode.len) return error.BytecodeOverflow;
                n_pop += std.mem.readInt(u16, bytecode[pos + 1 ..][0..2], .little);
            },
            .npopx => {
                // OP_call0..call3: extra args = (op - OP_call0).
                n_pop += @as(u32, op) - @as(u32, opcode.op.call0);
            },
            else => {},
        }

        if (stack_len < n_pop) return error.StackUnderflow;
        const new_stack_i32: i32 = @as(i32, stack_len) - @as(i32, @intCast(n_pop)) + @as(i32, meta.n_push);
        if (new_stack_i32 < 0) return error.StackUnderflow;
        if (new_stack_i32 > JS_STACK_SIZE_MAX) return error.StackOverflow;
        stack_len = @intCast(new_stack_i32);
        if (stack_len > stack_len_max) stack_len_max = stack_len;

        // Dispatch on opcode name (we don't have the OP_* enum exposed
        // generically). Using name comparison is fine: the table is
        // small and this code runs once per function.
        if (eq(name, "return") or eq(name, "return_undef") or eq(name, "return_async") or
            eq(name, "throw") or eq(name, "throw_error") or
            eq(name, "tail_call") or eq(name, "tail_call_method") or
            eq(name, "ret"))
        {
            continue; // terminator: no successors.
        }

        // Jump-style opcodes. For Phase 3a-resolved bytecode, jumps are
        // pc-relative.
        if (eq(name, "goto")) {
            const diff = std.mem.readInt(i32, bytecode[pos + 1 ..][0..4], .little);
            const target = relTarget(pos, 1, diff);
            try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len, catch_pos);
            continue;
        } else if (eq(name, "goto16")) {
            const diff = std.mem.readInt(i16, bytecode[pos + 1 ..][0..2], .little);
            const target = relTarget(pos, 1, @intCast(diff));
            try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len, catch_pos);
            continue;
        } else if (eq(name, "goto8")) {
            const diff: i8 = @bitCast(bytecode[pos + 1]);
            const target = relTarget(pos, 1, @intCast(diff));
            try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len, catch_pos);
            continue;
        } else if (eq(name, "if_true") or eq(name, "if_false")) {
            const diff = std.mem.readInt(i32, bytecode[pos + 1 ..][0..4], .little);
            const target = relTarget(pos, 1, diff);
            try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len, catch_pos);
            // fall through.
        } else if (eq(name, "if_true8") or eq(name, "if_false8")) {
            const diff: i8 = @bitCast(bytecode[pos + 1]);
            const target = relTarget(pos, 1, @intCast(diff));
            try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len, catch_pos);
            // fall through.
        } else if (op == opcode.op.gosub) {
            const diff = std.mem.readInt(i32, bytecode[pos + 1 ..][0..4], .little);
            const target = relTarget(pos, 1, diff);
            try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len + 1, catch_pos);
            // fall through.
        } else if (op == opcode.op.with_get_var or op == opcode.op.with_delete_var) {
            const diff = std.mem.readInt(i32, bytecode[pos + 5 ..][0..4], .little);
            const target = relTarget(pos, 5, diff);
            try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len + 1, catch_pos);
            // fall through.
        } else if (op == opcode.op.with_make_ref or op == opcode.op.with_get_ref or op == opcode.op.with_get_ref_undef) {
            const diff = std.mem.readInt(i32, bytecode[pos + 5 ..][0..4], .little);
            const target = relTarget(pos, 5, diff);
            try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len + 2, catch_pos);
            // fall through.
        } else if (op == opcode.op.with_put_var) {
            const diff = std.mem.readInt(i32, bytecode[pos + 5 ..][0..4], .little);
            const target = relTarget(pos, 5, diff);
            if (stack_len == 0) return error.StackUnderflow;
            try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len - 1, catch_pos);
            // fall through.
        } else if (eq(name, "catch")) {
            const diff = std.mem.readInt(i32, bytecode[pos + 1 ..][0..4], .little);
            const target = relTarget(pos, 1, diff);
            try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, target, stack_len, catch_pos);
            catch_pos = @intCast(pos);
        } else if (op == opcode.op.for_of_start or op == opcode.op.for_await_of_start) {
            catch_pos = @intCast(pos);
        } else if (op == opcode.op.drop or op == opcode.op.nip or op == opcode.op.nip1 or op == opcode.op.iterator_close) {
            const catch_level = if (op == opcode.op.iterator_close)
                stack_len + 2
            else if (op == opcode.op.nip or op == opcode.op.nip1) blk: {
                if (stack_len == 0) return error.StackUnderflow;
                break :blk stack_len - 1;
            } else stack_len;
            catch_pos = maybePopCatchPos(bytecode, stack_level_tab, catch_pos_tab, catch_pos, catch_level);
        } else if (op == opcode.op.nip_catch) {
            if (catch_pos < 0) return error.InvalidOpcode;
            const catch_idx: usize = @intCast(catch_pos);
            stack_len = stack_level_tab[catch_idx];
            if (bytecode[catch_idx] != opcode.op.@"catch") stack_len += 1;
            stack_len += 1;
            catch_pos = catch_pos_tab[catch_idx];
        }

        // Fall-through.
        try seed(stack_level_tab, catch_pos_tab, &pc_stack, allocator, pos_next, stack_len, catch_pos);
    }

    return stack_len_max;
}

const OpMeta = struct {
    name: []const u8,
    size: u8,
    n_pop: u8,
    n_push: u8,
    format: opcode.Format,
};

fn metadataFor(op_id: u8, options: Options) ?OpMeta {
    if (options.opcode_table) |table| {
        const meta = table.at(op_id) orelse return null;
        return .{
            .name = meta.name,
            .size = meta.size,
            .n_pop = meta.n_pop,
            .n_push = meta.n_push,
            .format = meta.format,
        };
    }
    const size = opcode.sizeOf(op_id);
    const name = opcode.nameOf(op_id);
    if (size == 0 or name.len == 0) return null;
    return .{
        .name = name,
        .size = size,
        .n_pop = opcode.nPopOf(op_id),
        .n_push = opcode.nPushOf(op_id),
        .format = opcode.formatOf(op_id),
    };
}

fn seed(
    stack_level_tab: []u16,
    catch_pos_tab: []i32,
    pc_stack: *std.ArrayList(u32),
    allocator: std.mem.Allocator,
    pos: u32,
    stack_len: u16,
    catch_pos: i32,
) Error!void {
    if (pos == stack_level_tab.len) return;
    if (pos > stack_level_tab.len) return error.BytecodeOverflow;
    const existing = stack_level_tab[pos];
    if (existing == STACK_LEVEL_UNVISITED) {
        stack_level_tab[pos] = stack_len;
        catch_pos_tab[pos] = catch_pos;
        try pc_stack.append(allocator, pos);
    } else if (existing != stack_len) {
        return error.StackMismatch;
    } else if (catch_pos_tab[pos] != catch_pos) {
        return error.StackMismatch;
    }
}

fn maybePopCatchPos(bytecode: []const u8, stack_level_tab: []const u16, catch_pos_tab: []const i32, catch_pos: i32, catch_level: u16) i32 {
    if (catch_pos < 0) return catch_pos;
    const catch_idx: usize = @intCast(catch_pos);
    var level = stack_level_tab[catch_idx];
    if (bytecode[catch_idx] != opcode.op.@"catch") level += 1;
    if (catch_level == level) return catch_pos_tab[catch_idx];
    return catch_pos;
}

fn relTarget(pos: u32, operand_offset: u32, diff: i32) u32 {
    const base: i64 = @as(i64, pos) + @as(i64, operand_offset);
    return @intCast(base + diff);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
