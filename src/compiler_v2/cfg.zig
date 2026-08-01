//! Exact block-CFG liveness for the compiler-v2 temporary stream.
//!
//! Bound LabelIds partition the compact byte stream into basic blocks. The
//! production graph stores only block starts, one metadata row per block, a
//! flat CSR edge array, and a packed reachability bitset. Debug and
//! ReleaseSafe additionally run an instruction-granularity oracle to prove
//! that the block/cutoff classification is identical to byte-exact legacy
//! reachability.

const std = @import("std");
const core = @import("../core/root.zig");
const bytecode = @import("../bytecode.zig");
const builder = @import("builder.zig");
const labels = @import("labels.zig");

const opcode = bytecode.opcode;
const op = opcode.op;

pub const Error = error{
    OutOfMemory,
    InvalidBytecode,
};

/// Sorted bind-index row shared with resolve_variables. `dead_skipped` is
/// resolver bookkeeping; graph construction reads only the identity and the
/// immutable input offset.
pub const BindEntry = struct {
    input_offset: u32,
    label_index: u32,
    dead_skipped: bool = false,
};

pub fn bindLessThan(_: void, lhs: BindEntry, rhs: BindEntry) bool {
    if (lhs.input_offset != rhs.input_offset) return lhs.input_offset < rhs.input_offset;
    return lhs.label_index < rhs.label_index;
}

pub const TempInstruction = struct {
    size: u8,
    is_temp: bool = false,
    has_atom: bool = false,
};

fn tempAtomInstructionSize(op_id: u8) ?u8 {
    return switch (op_id) {
        op.scope_get_var_undef,
        op.scope_get_var,
        op.scope_put_var,
        op.scope_delete_var,
        op.scope_get_ref,
        op.scope_put_var_init,
        op.scope_get_var_checkthis,
        op.scope_get_private_field,
        op.scope_get_private_field2,
        op.scope_put_private_field,
        op.scope_in_private_field,
        => 7,
        op.scope_make_ref => 11,
        op.get_field_opt_chain => 5,
        else => null,
    };
}

fn instructionHasAtom(op_id: u8, is_temp: bool) bool {
    if (is_temp) return switch (op_id) {
        op.scope_get_var_undef,
        op.scope_get_var,
        op.scope_put_var,
        op.scope_delete_var,
        op.scope_make_ref,
        op.scope_get_ref,
        op.scope_put_var_init,
        op.scope_get_var_checkthis,
        op.scope_get_private_field,
        op.scope_get_private_field2,
        op.scope_put_private_field,
        op.scope_in_private_field,
        op.get_field_opt_chain,
        => true,
        else => false,
    };

    return switch (opcode.formatOf(op_id)) {
        .atom, .atom_u8, .atom_u16, .atom_label_u8, .atom_label_u16 => true,
        else => false,
    };
}

/// Shared phase-aware decoder for the compact v2 temporary stream. The atom
/// ledger disambiguates temporary atom opcodes from overlapping final short
/// opcodes.
pub fn tempInstruction(
    code: []const u8,
    atoms_ledger: []const core.atom.Atom,
    pc: u32,
    atom_index: u32,
) Error!TempInstruction {
    const pc_index: usize = @intCast(pc);
    if (pc_index >= code.len) return error.InvalidBytecode;
    const op_id = code[pc_index];

    if (tempAtomInstructionSize(op_id)) |temp_size| {
        const end = std.math.add(usize, pc_index, temp_size) catch
            return error.InvalidBytecode;
        if (end <= code.len and atom_index < atoms_ledger.len) {
            const operand = std.mem.readInt(u32, code[pc_index + 1 ..][0..4], .little);
            if (operand == atoms_ledger[atom_index]) {
                return .{ .size = temp_size, .is_temp = true, .has_atom = true };
            }
        }
    }

    var instruction: TempInstruction = switch (op_id) {
        // v2 labels and source positions are side-table entities.
        op.label, op.line_num => return error.InvalidBytecode,
        op.enter_scope,
        op.leave_scope,
        op.get_array_el_opt_chain,
        op.set_class_name,
        => .{ .size = opcode.sizeOfPhase1(op_id), .is_temp = true },
        else => .{ .size = opcode.sizeOf(op_id) },
    };
    if (instruction.size == 0) return error.InvalidBytecode;
    const end = std.math.add(usize, pc_index, instruction.size) catch
        return error.InvalidBytecode;
    if (end > code.len) return error.InvalidBytecode;
    instruction.has_atom = instructionHasAtom(op_id, instruction.is_temp);
    return instruction;
}

pub fn isUnconditionalTerminal(op_id: u8) bool {
    return switch (op_id) {
        op.goto,
        op.tail_call,
        op.tail_call_method,
        op.@"return",
        op.return_undef,
        op.throw,
        op.throw_error,
        op.ret,
        => true,
        else => false,
    };
}

fn labelOperandOffset(op_id: u8, instruction: TempInstruction) ?u32 {
    return switch (op_id) {
        op.if_false, op.if_true, op.goto, op.@"catch", op.gosub => 1,
        op.scope_make_ref => if (instruction.is_temp) 5 else null,
        else => switch (if (instruction.is_temp)
            opcode.formatOfPhase1(op_id)
        else
            opcode.formatOf(op_id)) {
            .atom_label_u8, .atom_label_u16 => 5,
            else => null,
        },
    };
}

fn validateAndAdvanceAtom(
    input: *const builder.Builder,
    pc: u32,
    instruction: TempInstruction,
    atom_index: *u32,
) Error!void {
    if (!instruction.has_atom) return;
    if (atom_index.* >= input.atom_len or instruction.size < 5)
        return error.InvalidBytecode;
    const pc_index: usize = @intCast(pc);
    const operand = std.mem.readInt(u32, input.code[pc_index + 1 ..][0..4], .little);
    if (operand != input.atom_operands[atom_index.*]) return error.InvalidBytecode;
    atom_index.* += 1;
}

fn readLabelIndex(
    input: *const builder.Builder,
    pc: u32,
    instruction: TempInstruction,
    operand_offset: u32,
) Error!u32 {
    const operand_end = std.math.add(u32, operand_offset, 4) catch
        return error.InvalidBytecode;
    if (operand_end > instruction.size) return error.InvalidBytecode;
    const operand_pc = std.math.add(u32, pc, operand_offset) catch
        return error.InvalidBytecode;
    const operand_index: usize = @intCast(operand_pc);
    if (operand_index + 4 > input.code_len) return error.InvalidBytecode;
    const label_index = std.mem.readInt(u32, input.code[operand_index..][0..4], .little);
    if (label_index >= input.label_len) return error.InvalidBytecode;
    return label_index;
}

fn labelTargetOffset(input: *const builder.Builder, label_index: u32) Error!u32 {
    if (label_index >= input.label_len) return error.InvalidBytecode;
    const slot = input.label_slots[label_index];
    if (!slot.flags.bound or slot.bound_offset == labels.unbound or
        slot.bound_offset > input.code_len)
    {
        return error.InvalidBytecode;
    }
    return slot.bound_offset;
}

fn isEmptyGosub(input: *const builder.Builder, op_id: u8, target_offset: u32) bool {
    return op_id == op.gosub and
        target_offset < input.code_len and
        input.code[target_offset] == op.ret;
}

pub const Block = struct {
    edge_start: usize = 0,
    edge_end: usize = 0,
    cutoff_offset: u32 = 0,
    has_terminal: bool = false,
};

pub const Graph = struct {
    memory: *core.memory.MemoryAccount,
    block_starts: []u32 = &.{},
    blocks: []Block = &.{},
    edge_storage: []usize = &.{},
    edge_len: usize = 0,
    reachable_words: []usize = &.{},

    pub fn deinit(self: *Graph) void {
        self.memory.free(u32, self.block_starts);
        self.memory.free(Block, self.blocks);
        self.memory.free(usize, self.edge_storage);
        self.memory.free(usize, self.reachable_words);
        self.block_starts = &.{};
        self.blocks = &.{};
        self.edge_storage = &.{};
        self.edge_len = 0;
        self.reachable_words = &.{};
    }

    pub fn edgesForBlock(self: *const Graph, block_index: usize) []const usize {
        std.debug.assert(block_index < self.blocks.len);
        const block = self.blocks[block_index];
        std.debug.assert(block.edge_start <= block.edge_end);
        std.debug.assert(block.edge_end <= self.edge_len);
        return self.edge_storage[block.edge_start..block.edge_end];
    }

    pub fn isReachable(self: *const Graph, block_index: usize) bool {
        std.debug.assert(block_index < self.blocks.len);
        return bitIsSet(self.reachable_words, block_index);
    }
};

const word_bits = @bitSizeOf(usize);

fn bitWordCount(bit_count: usize) Error!usize {
    const rounded = std.math.add(usize, bit_count, word_bits - 1) catch
        return error.OutOfMemory;
    return rounded / word_bits;
}

fn bitIsSet(words: []const usize, bit_index: usize) bool {
    const shift: std.math.Log2Int(usize) = @intCast(bit_index % word_bits);
    return (words[bit_index / word_bits] & (@as(usize, 1) << shift)) != 0;
}

fn setBit(words: []usize, bit_index: usize) void {
    const shift: std.math.Log2Int(usize) = @intCast(bit_index % word_bits);
    words[bit_index / word_bits] |= @as(usize, 1) << shift;
}

fn findBlockStart(block_starts: []const u32, target_offset: u32) ?usize {
    var lo: usize = 0;
    var hi = block_starts.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (block_starts[mid] < target_offset)
            lo = mid + 1
        else
            hi = mid;
    }
    if (lo >= block_starts.len or block_starts[lo] != target_offset) return null;
    return lo;
}

fn appendEdge(graph: *Graph, target_block: usize) Error!void {
    if (graph.edge_len >= graph.edge_storage.len) return error.InvalidBytecode;
    graph.edge_storage[graph.edge_len] = target_block;
    graph.edge_len += 1;
}

fn validateBindIndex(input: *const builder.Builder, binds: []const BindEntry) Error!void {
    var bound_count: usize = 0;
    for (input.label_slots[0..input.label_len]) |slot| {
        if (slot.flags.bound) bound_count += 1;
    }
    if (bound_count != binds.len) return error.InvalidBytecode;

    var previous: ?BindEntry = null;
    for (binds) |entry| {
        if (entry.label_index >= input.label_len or entry.input_offset > input.code_len)
            return error.InvalidBytecode;
        const slot = input.label_slots[entry.label_index];
        if (!slot.flags.bound or slot.bound_offset != entry.input_offset)
            return error.InvalidBytecode;
        if (previous) |prev| {
            if (entry.input_offset < prev.input_offset or
                (entry.input_offset == prev.input_offset and
                    entry.label_index <= prev.label_index))
            {
                return error.InvalidBytecode;
            }
        }
        previous = entry;
    }
}

/// Build the exact block CFG once from the immutable Builder product.
pub fn build(
    memory: *core.memory.MemoryAccount,
    input: *const builder.Builder,
    binds: []const BindEntry,
) Error!Graph {
    if (input.code_len > input.code.len or
        input.atom_len > input.atom_operands.len or
        input.label_len > input.label_slots.len or
        input.reloc_len > input.relocs.len)
    {
        return error.InvalidBytecode;
    }
    try validateBindIndex(input, binds);

    var block_count: usize = 1;
    var last_start: u32 = 0;
    for (binds) |entry| {
        if (entry.input_offset != last_start) {
            block_count = std.math.add(usize, block_count, 1) catch
                return error.OutOfMemory;
            last_start = entry.input_offset;
        }
    }
    if (last_start != input.code_len) {
        block_count = std.math.add(usize, block_count, 1) catch
            return error.OutOfMemory;
    }

    var graph: Graph = .{ .memory = memory };
    errdefer graph.deinit();

    graph.block_starts = memory.alloc(u32, block_count) catch
        return error.OutOfMemory;
    graph.blocks = memory.alloc(Block, block_count) catch
        return error.OutOfMemory;

    var start_index: usize = 1;
    graph.block_starts[0] = 0;
    last_start = 0;
    for (binds) |entry| {
        if (entry.input_offset == last_start) continue;
        graph.block_starts[start_index] = entry.input_offset;
        start_index += 1;
        last_start = entry.input_offset;
    }
    if (last_start != input.code_len) {
        graph.block_starts[start_index] = input.code_len;
        start_index += 1;
    }
    if (start_index != block_count or graph.block_starts[block_count - 1] != input.code_len)
        return error.InvalidBytecode;

    const fallthrough_capacity = block_count - 1;
    const edge_capacity = std.math.add(
        usize,
        @as(usize, input.reloc_len),
        fallthrough_capacity,
    ) catch return error.OutOfMemory;
    if (edge_capacity != 0) {
        graph.edge_storage = memory.alloc(usize, edge_capacity) catch
            return error.OutOfMemory;
    }

    const reachable_word_count = try bitWordCount(block_count);
    graph.reachable_words = memory.alloc(usize, reachable_word_count) catch
        return error.OutOfMemory;
    @memset(graph.reachable_words, 0);

    var atom_index: u32 = 0;
    var label_reference_count: u32 = 0;
    for (graph.blocks, 0..) |*block, block_index| {
        const block_start = graph.block_starts[block_index];
        const block_end = if (block_index + 1 < block_count)
            graph.block_starts[block_index + 1]
        else
            input.code_len;
        block.* = .{
            .edge_start = graph.edge_len,
            .edge_end = graph.edge_len,
            .cutoff_offset = block_end,
        };

        var pc = block_start;
        while (pc < block_end) {
            const instruction = try tempInstruction(
                input.code[0..input.code_len],
                input.atom_operands[0..input.atom_len],
                pc,
                atom_index,
            );
            const next = std.math.add(u32, pc, instruction.size) catch
                return error.InvalidBytecode;
            if (next > block_end) return error.InvalidBytecode;
            try validateAndAdvanceAtom(input, pc, instruction, &atom_index);

            const op_id = input.code[pc];
            if (labelOperandOffset(op_id, instruction)) |operand_offset| {
                if (label_reference_count == std.math.maxInt(u32))
                    return error.InvalidBytecode;
                label_reference_count += 1;
                const label_index = try readLabelIndex(input, pc, instruction, operand_offset);
                const target_offset = try labelTargetOffset(input, label_index);
                const target_block = findBlockStart(graph.block_starts, target_offset) orelse
                    return error.InvalidBytecode;
                std.debug.assert(graph.block_starts[target_block] == target_offset);

                if (!block.has_terminal and !isEmptyGosub(input, op_id, target_offset)) {
                    try appendEdge(&graph, target_block);
                }
            }

            if (!block.has_terminal and isUnconditionalTerminal(op_id)) {
                block.has_terminal = true;
                block.cutoff_offset = pc;
            }
            pc = next;
        }
        if (pc != block_end) return error.InvalidBytecode;
        std.debug.assert(pc == block_end);

        if (!block.has_terminal and block_index + 1 < block_count) {
            try appendEdge(&graph, block_index + 1);
        }
        block.edge_end = graph.edge_len;
    }
    if (atom_index != input.atom_len or label_reference_count != input.reloc_len)
        return error.InvalidBytecode;

    const worklist = memory.alloc(usize, block_count) catch
        return error.OutOfMemory;
    defer memory.free(usize, worklist);
    var worklist_len: usize = 1;
    var worklist_index: usize = 0;
    worklist[0] = 0;
    setBit(graph.reachable_words, 0);
    while (worklist_index < worklist_len) : (worklist_index += 1) {
        const block_index = worklist[worklist_index];
        for (graph.edgesForBlock(block_index)) |target_block| {
            if (target_block >= block_count) return error.InvalidBytecode;
            if (bitIsSet(graph.reachable_words, target_block)) continue;
            if (worklist_len >= worklist.len) return error.InvalidBytecode;
            setBit(graph.reachable_words, target_block);
            worklist[worklist_len] = target_block;
            worklist_len += 1;
        }
    }
    return graph;
}

const AuditInstruction = struct {
    size: u8 = 0,
    is_temp: bool = false,
};

fn enqueueAuditOffset(
    nodes: []const AuditInstruction,
    live_words: []usize,
    worklist: []u32,
    worklist_len: *usize,
    target: u32,
) Error!void {
    const target_index: usize = @intCast(target);
    if (target_index >= nodes.len or
        (target_index + 1 != nodes.len and nodes[target_index].size == 0))
    {
        return error.InvalidBytecode;
    }
    if (bitIsSet(live_words, target_index)) return;
    if (worklist_len.* >= worklist.len) return error.InvalidBytecode;
    setBit(live_words, target_index);
    worklist[worklist_len.*] = target;
    worklist_len.* += 1;
}

/// Debug/ReleaseSafe proof obligation: compare instruction-granularity
/// reachability against block reachability plus each block's first-terminal
/// cutoff. ReleaseFast callers do not reference this routine.
pub fn auditInstructionOwnership(
    memory: *core.memory.MemoryAccount,
    input: *const builder.Builder,
    graph: *const Graph,
) Error!void {
    const node_count = std.math.add(usize, @as(usize, input.code_len), 1) catch
        return error.OutOfMemory;
    const nodes = memory.alloc(AuditInstruction, node_count) catch
        return error.OutOfMemory;
    defer memory.free(AuditInstruction, nodes);
    @memset(nodes, .{});

    var pc: u32 = 0;
    var atom_index: u32 = 0;
    while (pc < input.code_len) {
        const instruction = try tempInstruction(
            input.code[0..input.code_len],
            input.atom_operands[0..input.atom_len],
            pc,
            atom_index,
        );
        nodes[pc] = .{ .size = instruction.size, .is_temp = instruction.is_temp };
        try validateAndAdvanceAtom(input, pc, instruction, &atom_index);
        pc = std.math.add(u32, pc, instruction.size) catch
            return error.InvalidBytecode;
    }
    if (pc != input.code_len or atom_index != input.atom_len)
        return error.InvalidBytecode;

    const live_word_count = try bitWordCount(node_count);
    const live_words = memory.alloc(usize, live_word_count) catch
        return error.OutOfMemory;
    defer memory.free(usize, live_words);
    @memset(live_words, 0);

    const worklist = memory.alloc(u32, node_count) catch
        return error.OutOfMemory;
    defer memory.free(u32, worklist);
    var worklist_len: usize = 0;
    try enqueueAuditOffset(nodes, live_words, worklist, &worklist_len, 0);

    var worklist_index: usize = 0;
    while (worklist_index < worklist_len) : (worklist_index += 1) {
        const current = worklist[worklist_index];
        if (current == input.code_len) continue;
        const node = nodes[current];
        const instruction: TempInstruction = .{
            .size = node.size,
            .is_temp = node.is_temp,
            .has_atom = instructionHasAtom(input.code[current], node.is_temp),
        };
        const next = std.math.add(u32, current, node.size) catch
            return error.InvalidBytecode;
        const op_id = input.code[current];

        if (labelOperandOffset(op_id, instruction)) |operand_offset| {
            const label_index = try readLabelIndex(input, current, instruction, operand_offset);
            const target_offset = try labelTargetOffset(input, label_index);
            if (!isEmptyGosub(input, op_id, target_offset)) {
                try enqueueAuditOffset(nodes, live_words, worklist, &worklist_len, target_offset);
            }
            if (op_id != op.goto) {
                try enqueueAuditOffset(nodes, live_words, worklist, &worklist_len, next);
            }
        } else if (!isUnconditionalTerminal(op_id)) {
            try enqueueAuditOffset(nodes, live_words, worklist, &worklist_len, next);
        }
    }

    var block_index: usize = 0;
    pc = 0;
    while (pc < input.code_len) {
        while (block_index + 1 < graph.block_starts.len and
            graph.block_starts[block_index + 1] <= pc)
        {
            block_index += 1;
        }
        if (block_index >= graph.blocks.len or graph.block_starts[block_index] > pc)
            return error.InvalidBytecode;
        const block = graph.blocks[block_index];
        const instruction_live = bitIsSet(live_words, pc);
        const cfg_live = graph.isReachable(block_index) and
            (!block.has_terminal or pc <= block.cutoff_offset);
        if (instruction_live != cfg_live) {
            std.debug.panic(
                "compiler_v2 CFG ownership divergence at offset {d}, opcode 0x{x:0>2}, block {d}: instruction_live={}, cfg_live={}",
                .{ pc, input.code[pc], block_index, instruction_live, cfg_live },
            );
        }
        pc = std.math.add(u32, pc, nodes[pc].size) catch
            return error.InvalidBytecode;
    }
}

test "compiler_v2.cfg: unreachable self-loop does not retain its block" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var input = builder.Builder.init(&rt.memory, &rt.atoms);
    defer input.deinit();
    const dead = try input.newLabel();
    const merge = try input.newLabel();
    try input.emitJump(op.if_false, merge);
    try input.emitOp(op.return_undef);
    try input.bindLabel(dead);
    try input.emitJump(op.goto, dead);
    try input.bindLabel(merge);
    try input.emitOp(op.return_undef);

    var binds = [_]BindEntry{
        .{ .input_offset = input.label_slots[dead.index()].bound_offset, .label_index = dead.index() },
        .{ .input_offset = input.label_slots[merge.index()].bound_offset, .label_index = merge.index() },
    };
    std.mem.sort(BindEntry, &binds, {}, bindLessThan);

    var graph = try build(&rt.memory, &input, &binds);
    defer graph.deinit();
    try std.testing.expectEqualSlices(u32, &.{ 0, 6, 11, 12 }, graph.block_starts);
    try std.testing.expect(graph.isReachable(0));
    try std.testing.expect(!graph.isReachable(1));
    try std.testing.expect(graph.isReachable(2));
    try std.testing.expect(!graph.isReachable(3));
    try std.testing.expectEqual(@as(u32, 5), graph.blocks[0].cutoff_offset);
    try std.testing.expect(graph.blocks[0].has_terminal);
    try std.testing.expectEqualSlices(usize, &.{2}, graph.edgesForBlock(0));
    try std.testing.expectEqualSlices(usize, &.{1}, graph.edgesForBlock(1));
    try auditInstructionOwnership(&rt.memory, &input, &graph);
}
