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

/// Options for the BFS.
pub const Options = struct {};

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
        _ = options;
        const meta = metadataFor(op) orelse return error.InvalidOpcode;
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

fn metadataFor(op_id: u8) ?OpMeta {
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

test "stack_size: empty bytecode produces zero stack" {
    const result = try compute(&.{}, .{});
    try std.testing.expectEqual(@as(u16, 0), result);
}

test "stack_size: simple push + return_undef gives stack=1" {
    const op = opcode.op;

    // push_i32 <42> ; return_undef
    var bc = [_]u8{0} ** 6;
    bc[0] = op.push_i32;
    std.mem.writeInt(i32, bc[1..5], 42, .little);
    bc[5] = op.return_undef;

    const result = try compute(&bc, .{});
    try std.testing.expectEqual(@as(u16, 1), result);
}

test "stack_size: push push add return gives stack=2" {
    const op = opcode.op;

    // push_i32 1 ; push_i32 2 ; add ; return_undef
    var bc = [_]u8{0} ** 12;
    bc[0] = op.push_i32;
    std.mem.writeInt(i32, bc[1..5], 1, .little);
    bc[5] = op.push_i32;
    std.mem.writeInt(i32, bc[6..10], 2, .little);
    bc[10] = op.add;
    bc[11] = op.return_undef;

    const result = try compute(&bc, .{});
    try std.testing.expectEqual(@as(u16, 2), result);
}

test "stack_size: stack underflow detected" {
    const op = opcode.op;

    // drop without anything on the stack → underflow.
    const bc = [_]u8{ op.drop, op.return_undef };
    const result = compute(&bc, .{});
    try std.testing.expectError(error.StackUnderflow, result);
}

test "stack_size: relative goto explored" {
    const op = opcode.op;

    // push_i32 7 ; goto +1 (skip drop) ; drop ; return_undef
    // Layout (pc): 0: push_i32, 5: goto, 10: drop, 11: return_undef.
    // Goto operand at pc+1 = 6, target = pos + 1 + diff. We want to
    // reach pc=11, so diff = 11 - (5 + 1) = 5.
    var bc = [_]u8{0} ** 12;
    bc[0] = op.push_i32;
    std.mem.writeInt(i32, bc[1..5], 7, .little);
    bc[5] = op.goto;
    std.mem.writeInt(i32, bc[6..10], 5, .little);
    bc[10] = op.drop; // skipped by goto
    bc[11] = op.return_undef;

    const result = try compute(&bc, .{});
    // The drop is unreachable, so max stack = 1 (push_i32) and no underflow.
    try std.testing.expectEqual(@as(u16, 1), result);
}

test "stack_size: catch handler edge contributes to max stack" {
    const op = opcode.op;

    // catch +5 (handler at pc=6) ; return_undef ; push_i32 9 ; return_undef
    // The normal fallthrough only reaches stack depth 1 from the catch marker.
    // The exception edge reaches the handler with the thrown value on the
    // stack, then push_i32 raises the required max stack to 2.
    var bc = [_]u8{0} ** 12;
    bc[0] = op.@"catch";
    std.mem.writeInt(i32, bc[1..5], 5, .little);
    bc[5] = op.return_undef;
    bc[6] = op.push_i32;
    std.mem.writeInt(i32, bc[7..11], 9, .little);
    bc[11] = op.return_undef;

    const result = try compute(&bc, .{});
    try std.testing.expectEqual(@as(u16, 2), result);
}

test "stack_size: indexed method call QuickJS shape is strict-computable" {
    const op = opcode.op;

    // get_var obj ; get_var key ; get_array_el2 ; get_var arg ; call_method 1 ; drop ; return_undef
    var bc = [_]u8{0} ** 21;
    bc[0] = op.get_var;
    bc[5] = op.get_var;
    bc[10] = op.get_array_el2;
    bc[11] = op.get_var;
    bc[16] = op.call_method;
    std.mem.writeInt(u16, bc[17..19], 1, .little);
    bc[19] = op.drop;
    bc[20] = op.return_undef;

    const result = try compute(&bc, .{});
    try std.testing.expectEqual(@as(u16, 3), result);
}

test "stack_size: indexed compound assignment QuickJS shape is strict-computable" {
    const op = opcode.op;

    // get_var obj ; get_var key ; to_propkey2 ; dup2 ; get_array_el ;
    // get_var rhs ; add ; put_array_el ; return_undef
    var bc = [_]u8{0} ** 22;
    bc[0] = op.get_var;
    bc[5] = op.get_var;
    bc[10] = op.to_propkey2;
    bc[11] = op.dup2;
    bc[12] = op.get_array_el;
    bc[13] = op.get_var;
    bc[18] = op.add;
    bc[19] = op.put_array_el;
    bc[20] = op.undefined;
    bc[21] = op.@"return";

    const result = try compute(&bc, .{});
    try std.testing.expectEqual(@as(u16, 4), result);
}

test "stack_size: regexp literal QuickJS shape is strict-computable" {
    const op = opcode.op;

    // push_atom_value "a" ; push_atom_value "g" ; regexp ; return_undef
    var bc = [_]u8{0} ** 12;
    bc[0] = op.push_atom_value;
    bc[5] = op.push_atom_value;
    bc[10] = op.regexp;
    bc[11] = op.return_undef;

    const result = try compute(&bc, .{});
    try std.testing.expectEqual(@as(u16, 2), result);
}

test "stack_size: bare new expression QuickJS shape is strict-computable" {
    const op = opcode.op;

    // get_var X ; dup ; call_constructor 0 ; drop ; return_undef
    var bc = [_]u8{0} ** 15;
    bc[0] = op.get_var;
    bc[5] = op.dup;
    bc[6] = op.call_constructor;
    std.mem.writeInt(u16, bc[7..9], 0, .little);
    bc[9] = op.drop;
    bc[10] = op.return_undef;

    const result = try compute(bc[0..11], .{});
    try std.testing.expectEqual(@as(u16, 2), result);
}

test "stack_size: super method call shape is strict-computable" {
    const op = opcode.op;

    // push_this ; special_object home ; get_super ; push_atom_value x ;
    // get_array_el ; tail_call_method 0
    var bc = [_]u8{0} ** 16;
    bc[0] = op.push_this;
    bc[1] = op.special_object;
    bc[2] = 4;
    bc[3] = op.get_super;
    bc[4] = op.push_atom_value;
    bc[9] = op.get_array_el;
    bc[10] = op.tail_call_method;
    std.mem.writeInt(u16, bc[11..13], 0, .little);

    const result = try compute(bc[0..13], .{});
    try std.testing.expectEqual(@as(u16, 3), result);
}

test "stack_size: super property value shape is strict-computable" {
    const op = opcode.op;

    // push_this ; special_object home ; get_super ; push_atom_value x ;
    // get_super_value ; return
    var bc = [_]u8{0} ** 12;
    bc[0] = op.push_this;
    bc[1] = op.special_object;
    bc[2] = 4;
    bc[3] = op.get_super;
    bc[4] = op.push_atom_value;
    bc[9] = op.get_super_value;
    bc[10] = op.@"return";

    const result = try compute(bc[0..11], .{});
    try std.testing.expectEqual(@as(u16, 3), result);
}

test "stack_size: base class declaration QuickJS shape is strict-computable" {
    const op = opcode.op;

    // set_loc_uninitialized C ; undefined ; set_loc_uninitialized <class_fields_init> ;
    // push_const ctor ; define_class ; undefined ; put_loc fields ; drop ;
    // set_loc C ; close_loc fields ; put_var_ref C ; return_undef
    var bc = [_]u8{0} ** 35;
    bc[0] = op.set_loc_uninitialized;
    std.mem.writeInt(u16, bc[1..3], 0, .little);
    bc[3] = op.undefined;
    bc[4] = op.set_loc_uninitialized;
    std.mem.writeInt(u16, bc[5..7], 1, .little);
    bc[7] = op.push_const;
    bc[12] = op.define_class;
    bc[18] = op.undefined;
    bc[19] = op.put_loc;
    std.mem.writeInt(u16, bc[20..22], 1, .little);
    bc[22] = op.drop;
    bc[23] = op.set_loc;
    std.mem.writeInt(u16, bc[24..26], 0, .little);
    bc[26] = op.close_loc;
    std.mem.writeInt(u16, bc[27..29], 1, .little);
    bc[29] = op.put_var_ref;
    std.mem.writeInt(u16, bc[30..32], 0, .little);
    bc[32] = op.return_undef;

    const result = try compute(bc[0..33], .{});
    try std.testing.expectEqual(@as(u16, 3), result);
}

test "stack_size: default derived constructor QuickJS shape is strict-computable" {
    const op = opcode.op;

    // set_loc_uninitialized this ; init_ctor ; put_loc_check_init this ;
    // get_var_ref_check <class_fields_init> ; dup ; if_false8 8 ;
    // get_loc_check this ; swap ; call_method 0 ; drop ; get_loc_check this ; return
    var bc = [_]u8{0} ** 25;
    bc[0] = op.set_loc_uninitialized;
    std.mem.writeInt(u16, bc[1..3], 0, .little);
    bc[3] = op.init_ctor;
    bc[4] = op.put_loc_check_init;
    std.mem.writeInt(u16, bc[5..7], 0, .little);
    bc[7] = op.get_var_ref_check;
    std.mem.writeInt(u16, bc[8..10], 0, .little);
    bc[10] = op.dup;
    bc[11] = op.if_false8;
    bc[12] = 8;
    bc[13] = op.get_loc_check;
    std.mem.writeInt(u16, bc[14..16], 0, .little);
    bc[16] = op.swap;
    bc[17] = op.call_method;
    std.mem.writeInt(u16, bc[18..20], 0, .little);
    bc[20] = op.drop;
    bc[21] = op.get_loc_check;
    std.mem.writeInt(u16, bc[22..24], 0, .little);
    bc[24] = op.@"return";

    const result = try compute(&bc, .{});
    try std.testing.expectEqual(@as(u16, 2), result);
}

test "stack_size: for-of iterator close catch position is strict-computable" {
    const op = opcode.op;

    // array_from 0 ; for_of_start ; goto next ; body: put_loc0 ; goto next ;
    // exit: drop ; iterator_close ; return_undef ;
    // next: for_of_next 0 ; if_false body ; drop ; iterator_close ; return_undef
    var bc = [_]u8{0} ** 19;
    bc[0] = op.array_from;
    std.mem.writeInt(u16, bc[1..3], 0, .little);
    bc[3] = op.for_of_start;
    bc[4] = op.goto8;
    bc[5] = 7;
    bc[6] = op.put_loc0;
    bc[7] = op.goto8;
    bc[8] = 4;
    bc[9] = op.drop;
    bc[10] = op.iterator_close;
    bc[11] = op.return_undef;
    bc[12] = op.for_of_next;
    bc[13] = 0;
    bc[14] = op.if_false8;
    bc[15] = @bitCast(@as(i8, -9));
    bc[16] = op.drop;
    bc[17] = op.iterator_close;
    bc[18] = op.return_undef;

    const result = try compute(&bc, .{});
    try std.testing.expectEqual(@as(u16, 5), result);
}
