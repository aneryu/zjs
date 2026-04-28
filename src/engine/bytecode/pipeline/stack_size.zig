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

/// Options for the BFS. The opcode_table is required for non-empty
/// bytecode; it provides per-opcode metadata (size, n_pop, n_push,
/// format).
pub const Options = struct {
    opcode_table: ?*const opcode.ParsedTable = null,
};

/// Compute the maximum stack size required to execute `bytecode`.
///
/// Returns 0 for empty bytecode (no instructions to execute).
pub fn compute(bytecode: []const u8, options: Options) Error!u16 {
    if (bytecode.len == 0) return 0;
    const table = options.opcode_table orelse return error.InvalidOpcode;

    const allocator = std.heap.page_allocator;
    const stack_level_tab = try allocator.alloc(u16, bytecode.len);
    defer allocator.free(stack_level_tab);
    @memset(stack_level_tab, STACK_LEVEL_UNVISITED);

    var pc_stack: std.ArrayList(u32) = .empty;
    defer pc_stack.deinit(allocator);

    // Seed: entry pc=0 with stack level 0.
    try seed(stack_level_tab, &pc_stack, allocator, 0, 0);

    var stack_len_max: u16 = 0;

    while (pc_stack.pop()) |pos_any| {
        const pos: u32 = pos_any;
        var stack_len = stack_level_tab[pos];
        const op = bytecode[pos];
        if (op == 0) return error.InvalidOpcode;
        const meta = table.at(op) orelse return error.InvalidOpcode;
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
                const op_call0 = table.indexOf("call0") orelse return error.InvalidOpcode;
                n_pop += @as(u32, op) - @as(u32, @intCast(op_call0));
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
        const name = meta.name;
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
            try seed(stack_level_tab, &pc_stack, allocator, target, stack_len);
            continue;
        } else if (eq(name, "goto16")) {
            const diff = std.mem.readInt(i16, bytecode[pos + 1 ..][0..2], .little);
            const target = relTarget(pos, 1, @intCast(diff));
            try seed(stack_level_tab, &pc_stack, allocator, target, stack_len);
            continue;
        } else if (eq(name, "goto8")) {
            const diff: i8 = @bitCast(bytecode[pos + 1]);
            const target = relTarget(pos, 1, @intCast(diff));
            try seed(stack_level_tab, &pc_stack, allocator, target, stack_len);
            continue;
        } else if (eq(name, "if_true") or eq(name, "if_false")) {
            const diff = std.mem.readInt(i32, bytecode[pos + 1 ..][0..4], .little);
            const target = relTarget(pos, 1, diff);
            try seed(stack_level_tab, &pc_stack, allocator, target, stack_len);
            // fall through.
        } else if (eq(name, "if_true8") or eq(name, "if_false8")) {
            const diff: i8 = @bitCast(bytecode[pos + 1]);
            const target = relTarget(pos, 1, @intCast(diff));
            try seed(stack_level_tab, &pc_stack, allocator, target, stack_len);
            // fall through.
        }

        // Fall-through.
        try seed(stack_level_tab, &pc_stack, allocator, pos_next, stack_len);
    }

    return stack_len_max;
}

fn seed(
    stack_level_tab: []u16,
    pc_stack: *std.ArrayList(u32),
    allocator: std.mem.Allocator,
    pos: u32,
    stack_len: u16,
) Error!void {
    if (pos >= stack_level_tab.len) return error.BytecodeOverflow;
    const existing = stack_level_tab[pos];
    if (existing == STACK_LEVEL_UNVISITED) {
        stack_level_tab[pos] = stack_len;
        try pc_stack.append(allocator, pos);
    } else if (existing != stack_len) {
        return error.StackMismatch;
    }
}

fn relTarget(pos: u32, operand_offset: u32, diff: i32) u32 {
    const base: i64 = @as(i64, pos) + @as(i64, operand_offset);
    return @intCast(base + diff);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}