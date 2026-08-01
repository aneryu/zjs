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

pub const OptimizationBoundaryKind = enum {
    make_ref_head,
    make_ref_tail,
    dup_branch_fold,
    insert_tail_fold,
    gosub_empty,
};

pub const OptimizationBoundary = struct {
    kind: OptimizationBoundaryKind,
    fold_start: u32,
    consumed_end: u32,
    replacement_start: u32,
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

fn eventIsBinding(op_id: u8, is_temp: bool) bool {
    if (!is_temp) return false;
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
        op.enter_scope,
        => true,
        else => false,
    };
}

fn eventIsMakeRef(op_id: u8, is_temp: bool) bool {
    return is_temp and op_id == op.scope_make_ref;
}

fn eventIsCleanup(op_id: u8, is_temp: bool) bool {
    return (is_temp and op_id == op.leave_scope) or
        op_id == op.gosub or
        op_id == op.ret;
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

const EventClass = enum {
    instruction,
    binding,
    atom_owner,
    make_ref,
    cleanup,
};

const DivergenceOrigin = struct {
    block_index: usize,
    bound_label: ?u32,
    source: ?builder.SourceSlot,
};

const AtomEventKind = enum {
    created,
    transferred,
    released,
};

const AtomEvent = struct {
    kind: AtomEventKind,
    ledger_index: u32,
    offset: u32,
};

fn validateAuditInput(
    input: *const builder.Builder,
    graph: *const Graph,
    binds: []const BindEntry,
) Error!void {
    if (input.code_len > input.code.len or
        input.atom_len > input.atom_operands.len or
        input.label_len > input.label_slots.len or
        input.reloc_len > input.relocs.len or
        input.source_len > input.source_slots.len)
    {
        return error.InvalidBytecode;
    }
    try validateBindIndex(input, binds);

    var previous_source_offset: u32 = 0;
    for (input.source_slots[0..input.source_len], 0..) |source, index| {
        if (source.temp_offset > input.code_len or
            (index != 0 and source.temp_offset < previous_source_offset))
        {
            return error.InvalidBytecode;
        }
        previous_source_offset = source.temp_offset;
    }

    if (graph.block_starts.len == 0 or
        graph.block_starts.len != graph.blocks.len or
        graph.block_starts[0] != 0 or
        graph.block_starts[graph.block_starts.len - 1] != input.code_len)
    {
        return error.InvalidBytecode;
    }
    for (graph.block_starts, 0..) |block_start, block_index| {
        if (block_start > input.code_len or
            (block_index != 0 and block_start <= graph.block_starts[block_index - 1]))
        {
            return error.InvalidBytecode;
        }
    }
    const reachable_word_count = try bitWordCount(graph.blocks.len);
    if (graph.reachable_words.len < reachable_word_count)
        return error.InvalidBytecode;
}

fn resolveDivergenceOrigin(
    input: *const builder.Builder,
    graph: *const Graph,
    binds: []const BindEntry,
    pc: u32,
) Error!DivergenceOrigin {
    if (pc > input.code_len) return error.InvalidBytecode;

    var block_lo: usize = 0;
    var block_hi = graph.block_starts.len;
    while (block_lo < block_hi) {
        const mid = block_lo + (block_hi - block_lo) / 2;
        if (graph.block_starts[mid] <= pc)
            block_lo = mid + 1
        else
            block_hi = mid;
    }
    if (block_lo == 0) return error.InvalidBytecode;
    const block_index = block_lo - 1;
    if (block_index >= graph.blocks.len) return error.InvalidBytecode;
    const block_start = graph.block_starts[block_index];

    var bind_lo: usize = 0;
    var bind_hi = binds.len;
    while (bind_lo < bind_hi) {
        const mid = bind_lo + (bind_hi - bind_lo) / 2;
        if (binds[mid].input_offset < block_start)
            bind_lo = mid + 1
        else
            bind_hi = mid;
    }
    const bound_label = if (bind_lo < binds.len and
        binds[bind_lo].input_offset == block_start)
        binds[bind_lo].label_index
    else
        null;

    const sources = input.source_slots[0..input.source_len];
    var source_lo: usize = 0;
    var source_hi = sources.len;
    while (source_lo < source_hi) {
        const mid = source_lo + (source_hi - source_lo) / 2;
        if (sources[mid].temp_offset <= pc)
            source_lo = mid + 1
        else
            source_hi = mid;
    }
    const source = if (source_lo == 0) null else sources[source_lo - 1];

    return .{
        .block_index = block_index,
        .bound_label = bound_label,
        .source = source,
    };
}

fn formatDivergenceOrigin(buffer: []u8, origin: DivergenceOrigin) []const u8 {
    if (origin.bound_label) |label_index| {
        if (origin.source) |source| {
            return std.fmt.bufPrint(
                buffer,
                "block={d} label={d} source={d}:{d}",
                .{ origin.block_index, label_index, source.line, source.col },
            ) catch unreachable;
        }
        return std.fmt.bufPrint(
            buffer,
            "block={d} label={d} source=none",
            .{ origin.block_index, label_index },
        ) catch unreachable;
    }
    if (origin.source) |source| {
        return std.fmt.bufPrint(
            buffer,
            "block={d} label=none source={d}:{d}",
            .{ origin.block_index, source.line, source.col },
        ) catch unreachable;
    }
    return std.fmt.bufPrint(
        buffer,
        "block={d} label=none source=none",
        .{origin.block_index},
    ) catch unreachable;
}

fn panicEventClassDivergence(
    class: EventClass,
    legacy_live: bool,
    v2_live: bool,
    pc: u32,
    op_id: u8,
    origin: DivergenceOrigin,
) noreturn {
    var origin_buffer: [160]u8 = undefined;
    const origin_text = formatDivergenceOrigin(&origin_buffer, origin);
    std.debug.panic(
        "compiler_v2 CFG event-class divergence: class={s} legacy_live={} v2_live={} offset={d} opcode=0x{x:0>2} {s}",
        .{ @tagName(class), legacy_live, v2_live, pc, op_id, origin_text },
    );
}

fn compareEventClass(
    input: *const builder.Builder,
    graph: *const Graph,
    binds: []const BindEntry,
    class: EventClass,
    legacy_live: bool,
    v2_live: bool,
    pc: u32,
) Error!void {
    if (legacy_live == v2_live) return;
    const origin = try resolveDivergenceOrigin(input, graph, binds, pc);
    panicEventClassDivergence(class, legacy_live, v2_live, pc, input.code[pc], origin);
}

fn appendAtomEvents(
    events: []AtomEvent,
    event_len: *usize,
    ledger_index: u32,
    offset: u32,
    is_live: bool,
) Error!void {
    const next_len = std.math.add(usize, event_len.*, 2) catch
        return error.InvalidBytecode;
    if (next_len > events.len) return error.InvalidBytecode;
    events[event_len.*] = .{
        .kind = .created,
        .ledger_index = ledger_index,
        .offset = offset,
    };
    events[event_len.* + 1] = .{
        .kind = if (is_live) .transferred else .released,
        .ledger_index = ledger_index,
        .offset = offset,
    };
    event_len.* = next_len;
}

fn atomEventsEqual(lhs: AtomEvent, rhs: AtomEvent) bool {
    return lhs.kind == rhs.kind and
        lhs.ledger_index == rhs.ledger_index and
        lhs.offset == rhs.offset;
}

fn formatAtomEvent(
    buffer: []u8,
    event: ?AtomEvent,
    origin: ?DivergenceOrigin,
) []const u8 {
    const entry = event orelse return "{kind=none, ledger_index=none, offset=none, origin=none}";
    var origin_buffer: [160]u8 = undefined;
    const origin_text = formatDivergenceOrigin(&origin_buffer, origin orelse unreachable);
    return std.fmt.bufPrint(
        buffer,
        "{{kind={s}, ledger_index={d}, offset={d}, {s}}}",
        .{ @tagName(entry.kind), entry.ledger_index, entry.offset, origin_text },
    ) catch unreachable;
}

fn panicAtomEventDivergence(
    sequence_index: usize,
    expected_len: usize,
    legacy_events: []const AtomEvent,
    v2_events: []const AtomEvent,
    legacy_event: ?AtomEvent,
    v2_event: ?AtomEvent,
    legacy_origin: ?DivergenceOrigin,
    v2_origin: ?DivergenceOrigin,
) noreturn {
    var legacy_buffer: [320]u8 = undefined;
    var v2_buffer: [320]u8 = undefined;
    const legacy_text = formatAtomEvent(&legacy_buffer, legacy_event, legacy_origin);
    const v2_text = formatAtomEvent(&v2_buffer, v2_event, v2_origin);
    std.debug.panic(
        "compiler_v2 CFG atom-owner sub-event divergence: position={d} expected_len={d} legacy_len={d} v2_len={d} legacy={s} v2={s}",
        .{
            sequence_index,
            expected_len,
            legacy_events.len,
            v2_events.len,
            legacy_text,
            v2_text,
        },
    );
}

/// Debug/ReleaseSafe proof obligation: compare instruction-granularity
/// reachability against block reachability plus each block's first-terminal
/// cutoff. ReleaseFast callers do not reference this routine.
pub fn auditInstructionOwnership(
    memory: *core.memory.MemoryAccount,
    input: *const builder.Builder,
    graph: *const Graph,
    binds: []const BindEntry,
) Error!void {
    try validateAuditInput(input, graph, binds);

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
    const instruction_live = memory.alloc(usize, live_word_count) catch
        return error.OutOfMemory;
    defer memory.free(usize, instruction_live);
    @memset(instruction_live, 0);

    const binding_event_live = memory.alloc(usize, live_word_count) catch
        return error.OutOfMemory;
    defer memory.free(usize, binding_event_live);
    @memset(binding_event_live, 0);

    const atom_owner_event_live = memory.alloc(usize, live_word_count) catch
        return error.OutOfMemory;
    defer memory.free(usize, atom_owner_event_live);
    @memset(atom_owner_event_live, 0);

    const make_ref_event_live = memory.alloc(usize, live_word_count) catch
        return error.OutOfMemory;
    defer memory.free(usize, make_ref_event_live);
    @memset(make_ref_event_live, 0);

    const cleanup_event_live = memory.alloc(usize, live_word_count) catch
        return error.OutOfMemory;
    defer memory.free(usize, cleanup_event_live);
    @memset(cleanup_event_live, 0);

    const worklist = memory.alloc(u32, node_count) catch
        return error.OutOfMemory;
    defer memory.free(u32, worklist);
    var worklist_len: usize = 0;
    try enqueueAuditOffset(nodes, instruction_live, worklist, &worklist_len, 0);

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
                try enqueueAuditOffset(nodes, instruction_live, worklist, &worklist_len, target_offset);
            }
            if (op_id != op.goto) {
                try enqueueAuditOffset(nodes, instruction_live, worklist, &worklist_len, next);
            }
        } else if (!isUnconditionalTerminal(op_id)) {
            try enqueueAuditOffset(nodes, instruction_live, worklist, &worklist_len, next);
        }
    }

    const atom_event_count = std.math.mul(
        usize,
        @as(usize, input.atom_len),
        2,
    ) catch return error.OutOfMemory;
    var legacy_atom_events: []AtomEvent = &.{};
    if (atom_event_count != 0) {
        legacy_atom_events = memory.alloc(AtomEvent, atom_event_count) catch
            return error.OutOfMemory;
    }
    defer if (legacy_atom_events.len != 0)
        memory.free(AtomEvent, legacy_atom_events);

    var v2_atom_events: []AtomEvent = &.{};
    if (atom_event_count != 0) {
        v2_atom_events = memory.alloc(AtomEvent, atom_event_count) catch
            return error.OutOfMemory;
    }
    defer if (v2_atom_events.len != 0)
        memory.free(AtomEvent, v2_atom_events);

    var legacy_atom_event_len: usize = 0;
    var legacy_ledger_index: u32 = 0;
    pc = 0;
    while (pc < input.code_len) {
        const node = nodes[pc];
        if (node.size == 0) return error.InvalidBytecode;
        const op_id = input.code[pc];
        const instruction: TempInstruction = .{
            .size = node.size,
            .is_temp = node.is_temp,
            .has_atom = instructionHasAtom(op_id, node.is_temp),
        };
        const is_live = bitIsSet(instruction_live, pc);
        if (is_live and eventIsBinding(op_id, instruction.is_temp))
            setBit(binding_event_live, pc);
        if (is_live and instruction.has_atom)
            setBit(atom_owner_event_live, pc);
        if (is_live and eventIsMakeRef(op_id, instruction.is_temp))
            setBit(make_ref_event_live, pc);
        if (is_live and eventIsCleanup(op_id, instruction.is_temp))
            setBit(cleanup_event_live, pc);

        if (instruction.has_atom) {
            try appendAtomEvents(
                legacy_atom_events,
                &legacy_atom_event_len,
                legacy_ledger_index,
                pc,
                is_live,
            );
            legacy_ledger_index = std.math.add(u32, legacy_ledger_index, 1) catch
                return error.InvalidBytecode;
        }

        pc = std.math.add(u32, pc, node.size) catch
            return error.InvalidBytecode;
    }
    if (pc != input.code_len) return error.InvalidBytecode;

    var v2_atom_event_len: usize = 0;
    var v2_ledger_index: u32 = 0;
    for (graph.blocks, 0..) |block, block_index| {
        const block_start = graph.block_starts[block_index];
        const block_end = if (block_index + 1 < graph.block_starts.len)
            graph.block_starts[block_index + 1]
        else
            input.code_len;
        var block_pc = block_start;
        while (block_pc < block_end) {
            const node = nodes[block_pc];
            if (node.size == 0) return error.InvalidBytecode;
            const next = std.math.add(u32, block_pc, node.size) catch
                return error.InvalidBytecode;
            if (next > block_end) return error.InvalidBytecode;

            const op_id = input.code[block_pc];
            const instruction: TempInstruction = .{
                .size = node.size,
                .is_temp = node.is_temp,
                .has_atom = instructionHasAtom(op_id, node.is_temp),
            };
            const v2_live = graph.isReachable(block_index) and
                (!block.has_terminal or block_pc <= block.cutoff_offset);

            try compareEventClass(
                input,
                graph,
                binds,
                .instruction,
                bitIsSet(instruction_live, block_pc),
                v2_live,
                block_pc,
            );
            try compareEventClass(
                input,
                graph,
                binds,
                .binding,
                bitIsSet(binding_event_live, block_pc),
                v2_live and eventIsBinding(op_id, instruction.is_temp),
                block_pc,
            );
            try compareEventClass(
                input,
                graph,
                binds,
                .atom_owner,
                bitIsSet(atom_owner_event_live, block_pc),
                v2_live and instruction.has_atom,
                block_pc,
            );
            try compareEventClass(
                input,
                graph,
                binds,
                .make_ref,
                bitIsSet(make_ref_event_live, block_pc),
                v2_live and eventIsMakeRef(op_id, instruction.is_temp),
                block_pc,
            );
            try compareEventClass(
                input,
                graph,
                binds,
                .cleanup,
                bitIsSet(cleanup_event_live, block_pc),
                v2_live and eventIsCleanup(op_id, instruction.is_temp),
                block_pc,
            );

            if (instruction.has_atom) {
                try appendAtomEvents(
                    v2_atom_events,
                    &v2_atom_event_len,
                    v2_ledger_index,
                    block_pc,
                    v2_live,
                );
                v2_ledger_index = std.math.add(u32, v2_ledger_index, 1) catch
                    return error.InvalidBytecode;
            }

            block_pc = next;
        }
        if (block_pc != block_end) return error.InvalidBytecode;
    }

    const legacy_events = legacy_atom_events[0..legacy_atom_event_len];
    const v2_events = v2_atom_events[0..v2_atom_event_len];
    var sequence_index: usize = 0;
    while (sequence_index < @min(legacy_events.len, v2_events.len)) : (sequence_index += 1) {
        const legacy_event = legacy_events[sequence_index];
        const v2_event = v2_events[sequence_index];
        if (atomEventsEqual(legacy_event, v2_event)) continue;
        const legacy_origin = try resolveDivergenceOrigin(
            input,
            graph,
            binds,
            legacy_event.offset,
        );
        const v2_origin = try resolveDivergenceOrigin(
            input,
            graph,
            binds,
            v2_event.offset,
        );
        panicAtomEventDivergence(
            sequence_index,
            atom_event_count,
            legacy_events,
            v2_events,
            legacy_event,
            v2_event,
            legacy_origin,
            v2_origin,
        );
    }

    if (legacy_events.len != v2_events.len) {
        const legacy_event = if (sequence_index < legacy_events.len)
            legacy_events[sequence_index]
        else
            null;
        const v2_event = if (sequence_index < v2_events.len)
            v2_events[sequence_index]
        else
            null;
        const legacy_origin = if (legacy_event) |event|
            try resolveDivergenceOrigin(input, graph, binds, event.offset)
        else
            null;
        const v2_origin = if (v2_event) |event|
            try resolveDivergenceOrigin(input, graph, binds, event.offset)
        else
            null;
        panicAtomEventDivergence(
            sequence_index,
            atom_event_count,
            legacy_events,
            v2_events,
            legacy_event,
            v2_event,
            legacy_origin,
            v2_origin,
        );
    }

    if (legacy_events.len != atom_event_count or v2_events.len != atom_event_count) {
        panicAtomEventDivergence(
            legacy_events.len,
            atom_event_count,
            legacy_events,
            v2_events,
            null,
            null,
            null,
            null,
        );
    }
    if (legacy_ledger_index != input.atom_len or v2_ledger_index != input.atom_len)
        return error.InvalidBytecode;
}

const BoundaryCategory = enum {
    instruction_start,
    instruction_end,
    jump_target,
    exception_landing,
    cleanup_subroutine,
    terminal,
    cleanup_op,
    fold_start,
    fold_consumed_end,
    fold_replacement,
    source_event,
};

const BoundaryFailureReason = enum {
    unmapped,
    bind_not_block,
    target_not_label,
    ambiguous,
    invalid_fold_range,
    bind_inside_fold,
};

const BoundaryFlags = struct {
    is_bind: bool,
    is_block_start: bool,
    is_instr: bool,
};

const BoundaryFailure = struct {
    category: BoundaryCategory,
    offset: u32,
    reason: BoundaryFailureReason,
    is_bind: bool,
    is_block_start: bool,
    is_instr: bool,
};

const BoundaryFailures = struct {
    entries: [8]BoundaryFailure = undefined,
    recorded: usize = 0,
    total: usize = 0,

    fn append(
        self: *BoundaryFailures,
        category: BoundaryCategory,
        offset: u32,
        reason: BoundaryFailureReason,
        flags: BoundaryFlags,
    ) void {
        self.total = std.math.add(usize, self.total, 1) catch std.math.maxInt(usize);
        if (self.recorded == self.entries.len) return;
        self.entries[self.recorded] = .{
            .category = category,
            .offset = offset,
            .reason = reason,
            .is_bind = flags.is_bind,
            .is_block_start = flags.is_block_start,
            .is_instr = flags.is_instr,
        };
        self.recorded += 1;
    }
};

fn lowerBoundBindOffset(binds: []const BindEntry, offset: u32) usize {
    var lo: usize = 0;
    var hi = binds.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (binds[mid].input_offset < offset)
            lo = mid + 1
        else
            hi = mid;
    }
    return lo;
}

fn upperBoundBindOffset(binds: []const BindEntry, offset: u32) usize {
    var lo: usize = 0;
    var hi = binds.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (binds[mid].input_offset <= offset)
            lo = mid + 1
        else
            hi = mid;
    }
    return lo;
}

fn hasBindAtOffset(binds: []const BindEntry, offset: u32) bool {
    const index = lowerBoundBindOffset(binds, offset);
    return index < binds.len and binds[index].input_offset == offset;
}

const BoundaryChecker = struct {
    starts_words: []const usize,
    code_len: u32,
    graph: *const Graph,
    binds: []const BindEntry,
    failures: *BoundaryFailures,

    fn flagsAt(self: *const BoundaryChecker, offset: u32) BoundaryFlags {
        return .{
            .is_bind = hasBindAtOffset(self.binds, offset),
            .is_block_start = findBlockStart(self.graph.block_starts, offset) != null,
            .is_instr = offset <= self.code_len and
                bitIsSet(self.starts_words, @intCast(offset)),
        };
    }

    fn record(
        self: *BoundaryChecker,
        category: BoundaryCategory,
        offset: u32,
        reason: BoundaryFailureReason,
    ) void {
        self.failures.append(category, offset, reason, self.flagsAt(offset));
    }

    fn check(self: *BoundaryChecker, category: BoundaryCategory, offset: u32) void {
        const flags = self.flagsAt(offset);
        const needs_label = switch (category) {
            .jump_target, .exception_landing, .cleanup_subroutine => true,
            else => false,
        };

        var identity_count: u8 = 0;
        if (flags.is_bind and flags.is_block_start) identity_count += 1;
        if (flags.is_block_start and !flags.is_bind) identity_count += 1;
        if (flags.is_instr and !flags.is_block_start) identity_count += 1;

        if (offset > self.code_len or !flags.is_instr)
            self.failures.append(category, offset, .unmapped, flags);
        if (flags.is_bind and !flags.is_block_start)
            self.failures.append(category, offset, .bind_not_block, flags);
        if (needs_label and !flags.is_bind)
            self.failures.append(category, offset, .target_not_label, flags);
        if (identity_count != 1)
            self.failures.append(category, offset, .ambiguous, flags);
    }
};

fn panicBoundarySetDivergence(failures: *const BoundaryFailures) noreturn {
    var message_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&message_buffer);
    writer.print(
        "compiler_v2 boundary-set divergence ({d} offending):",
        .{failures.total},
    ) catch unreachable;
    for (failures.entries[0..failures.recorded]) |failure| {
        writer.print(
            " [category={s} offset={d} reason={s} bind={} block={} instr={}]",
            .{
                @tagName(failure.category),
                failure.offset,
                @tagName(failure.reason),
                failure.is_bind,
                failure.is_block_start,
                failure.is_instr,
            },
        ) catch unreachable;
    }
    if (failures.total > failures.recorded) {
        writer.print(
            " [truncated recorded={d} total={d}]",
            .{ failures.recorded, failures.total },
        ) catch unreachable;
    }
    std.debug.panic("{s}", .{writer.buffered()});
}

/// Debug/ReleaseSafe proof obligation: every legacy-notion boundary in the
/// temporary stream has exactly one v2 boundary identity preserved for final
/// emission.
pub fn auditBoundarySet(
    memory: *core.memory.MemoryAccount,
    input: *const builder.Builder,
    graph: *const Graph,
    binds: []const BindEntry,
    opt_bounds: []const OptimizationBoundary,
) Error!void {
    try validateAuditInput(input, graph, binds);

    const boundary_count = std.math.add(usize, @as(usize, input.code_len), 1) catch
        return error.OutOfMemory;
    const word_count = try bitWordCount(boundary_count);
    const starts_words = memory.alloc(usize, word_count) catch
        return error.OutOfMemory;
    defer memory.free(usize, starts_words);
    @memset(starts_words, 0);

    var pc: u32 = 0;
    var atom_index: u32 = 0;
    while (pc < input.code_len) {
        const instruction = try tempInstruction(
            input.code[0..input.code_len],
            input.atom_operands[0..input.atom_len],
            pc,
            atom_index,
        );
        setBit(starts_words, @intCast(pc));
        try validateAndAdvanceAtom(input, pc, instruction, &atom_index);
        pc = std.math.add(u32, pc, instruction.size) catch
            return error.InvalidBytecode;
    }
    if (pc != input.code_len or atom_index != input.atom_len)
        return error.InvalidBytecode;
    setBit(starts_words, @intCast(input.code_len));

    var failures: BoundaryFailures = .{};
    var checker: BoundaryChecker = .{
        .starts_words = starts_words,
        .code_len = input.code_len,
        .graph = graph,
        .binds = binds,
        .failures = &failures,
    };

    pc = 0;
    atom_index = 0;
    var label_reference_count: u32 = 0;
    while (pc < input.code_len) {
        const instruction = try tempInstruction(
            input.code[0..input.code_len],
            input.atom_operands[0..input.atom_len],
            pc,
            atom_index,
        );
        const next = std.math.add(u32, pc, instruction.size) catch
            return error.InvalidBytecode;
        try validateAndAdvanceAtom(input, pc, instruction, &atom_index);

        checker.check(.instruction_start, pc);
        checker.check(.instruction_end, next);

        const op_id = input.code[pc];
        if (labelOperandOffset(op_id, instruction)) |operand_offset| {
            if (label_reference_count == std.math.maxInt(u32))
                return error.InvalidBytecode;
            label_reference_count += 1;
            const label_index = try readLabelIndex(input, pc, instruction, operand_offset);
            const target_offset = try labelTargetOffset(input, label_index);
            checker.check(.jump_target, target_offset);
            if (op_id == op.@"catch")
                checker.check(.exception_landing, target_offset);
            if (op_id == op.gosub)
                checker.check(.cleanup_subroutine, target_offset);
        }
        if (isUnconditionalTerminal(op_id)) checker.check(.terminal, pc);
        if (instruction.is_temp and op_id == op.leave_scope)
            checker.check(.cleanup_op, pc);

        pc = next;
    }
    if (pc != input.code_len or atom_index != input.atom_len or
        label_reference_count != input.reloc_len)
    {
        return error.InvalidBytecode;
    }

    for (opt_bounds) |boundary| {
        checker.check(.fold_start, boundary.fold_start);
        checker.check(.fold_consumed_end, boundary.consumed_end);
        checker.check(.fold_replacement, boundary.replacement_start);

        if (boundary.fold_start > boundary.replacement_start or
            boundary.replacement_start > boundary.consumed_end)
        {
            checker.record(
                .fold_replacement,
                boundary.replacement_start,
                .invalid_fold_range,
            );
        }
        if (boundary.consumed_end > input.code_len) {
            checker.record(
                .fold_consumed_end,
                boundary.consumed_end,
                .invalid_fold_range,
            );
        }

        var bind_index = upperBoundBindOffset(binds, boundary.fold_start);
        var previous_offset: ?u32 = null;
        while (bind_index < binds.len and
            binds[bind_index].input_offset < boundary.consumed_end) : (bind_index += 1)
        {
            const bind_offset = binds[bind_index].input_offset;
            if (previous_offset == null or previous_offset.? != bind_offset) {
                checker.record(.fold_start, bind_offset, .bind_inside_fold);
                previous_offset = bind_offset;
            }
        }
    }

    for (input.source_slots[0..input.source_len]) |source| {
        checker.check(.source_event, source.temp_offset);
    }

    if (failures.total != 0) panicBoundarySetDivergence(&failures);
}

test "compiler_v2.cfg: boundary-set maps control flow and source events" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var input = builder.Builder.init(&rt.memory, &rt.atoms);
    defer input.deinit();
    const merge = try input.newLabel();
    try input.emitJump(op.if_false, merge);
    try input.addSourceMarker(10, 2);
    try input.emitOp(op.return_undef);
    try input.bindLabel(merge);
    try input.emitOp(op.return_undef);

    const binds = [_]BindEntry{
        .{
            .input_offset = input.label_slots[merge.index()].bound_offset,
            .label_index = merge.index(),
        },
    };
    var graph = try build(&rt.memory, &input, &binds);
    defer graph.deinit();

    try auditBoundarySet(&rt.memory, &input, &graph, &binds, &.{});
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
    try auditInstructionOwnership(&rt.memory, &input, &graph, &binds);
}

test "compiler_v2.cfg: scope_make_ref event survives a dead branch tail" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var input = builder.Builder.init(&rt.memory, &rt.atoms);
    defer input.deinit();
    const atom = try rt.atoms.internString("cfg-live-scope-make-ref");
    defer rt.atoms.free(atom);
    const merge = try input.newLabel();
    const dead = try input.newLabel();
    try input.emitScopeRefOpOwned(op.scope_make_ref, rt.atoms.dup(atom), merge, 0);
    try input.emitOp(op.return_undef);
    try input.emitJump(op.if_false, dead);
    try input.bindLabel(dead);
    try input.emitOp(op.return_undef);
    try input.bindLabel(merge);
    try input.emitOp(op.return_undef);

    var binds = [_]BindEntry{
        .{ .input_offset = input.label_slots[merge.index()].bound_offset, .label_index = merge.index() },
        .{ .input_offset = input.label_slots[dead.index()].bound_offset, .label_index = dead.index() },
    };
    std.mem.sort(BindEntry, &binds, {}, bindLessThan);

    var graph = try build(&rt.memory, &input, &binds);
    defer graph.deinit();
    try std.testing.expectEqualSlices(u32, &.{ 0, 17, 18, 19 }, graph.block_starts);
    try std.testing.expect(graph.isReachable(0));
    try std.testing.expect(!graph.isReachable(1));
    try std.testing.expect(graph.isReachable(2));
    try std.testing.expect(!graph.isReachable(3));
    try std.testing.expectEqual(@as(u32, 11), graph.blocks[0].cutoff_offset);
    try std.testing.expect(graph.blocks[0].has_terminal);
    try std.testing.expectEqualSlices(usize, &.{2}, graph.edgesForBlock(0));
    try auditInstructionOwnership(&rt.memory, &input, &graph, &binds);
}

test "compiler_v2.cfg: dead atom owner records a released sub-event" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var input = builder.Builder.init(&rt.memory, &rt.atoms);
    defer input.deinit();
    const atom = try rt.atoms.internString("cfg-dead-atom-owner");
    defer rt.atoms.free(atom);
    try input.emitOp(op.return_undef);
    try input.emitAtomOpU16Owned(op.scope_get_var, rt.atoms.dup(atom), 0);

    const binds: []const BindEntry = &.{};
    var graph = try build(&rt.memory, &input, binds);
    defer graph.deinit();
    try std.testing.expectEqualSlices(u32, &.{ 0, 8 }, graph.block_starts);
    try std.testing.expect(graph.isReachable(0));
    try std.testing.expect(!graph.isReachable(1));
    try std.testing.expectEqual(@as(u32, 0), graph.blocks[0].cutoff_offset);
    try std.testing.expect(graph.blocks[0].has_terminal);
    try auditInstructionOwnership(&rt.memory, &input, &graph, binds);
}
