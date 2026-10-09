//! Shared vocabulary of the two resolve passes over the compiler temporary
//! stream: the bind index rows, the phase-1 instruction view, and the source
//! point used to dedupe markers.

const std = @import("std");
const core = @import("../core/root.zig");
const sort_erased = @import("../core/sort_erased.zig");
const bytecode = @import("../bytecode.zig");
const labels = @import("labels.zig");

const opcode = bytecode.opcode;

pub const Error = error{
    OutOfMemory,
    InvalidBytecode,
};

/// Sorted bind-index row shared by both resolve passes: one per bound
/// label, keyed by the temporary-stream offset it is bound at.
/// `dead_skipped` is walk bookkeeping. The two snapshots are read by
/// `resolve_labels` and stay false for variable resolution.
pub const BindEntry = struct {
    input_offset: u32,
    label_index: u32,
    dead_skipped: bool = false,
    initially_referenced: bool = false,
    match_barrier: bool = false,
};

pub fn bindLessThan(_: void, lhs: BindEntry, rhs: BindEntry) bool {
    if (lhs.input_offset != rhs.input_offset) return lhs.input_offset < rhs.input_offset;
    return lhs.label_index < rhs.label_index;
}

/// Structural preflight shared by the two resolve passes. `extra` carries
/// the checks only one pass needs; every failure is `InvalidBytecode`.
pub fn validateStreams(
    comptime S: type,
    s: *const S,
    comptime extra: fn (*const S) Error!void,
) Error!void {
    if (s.code_len > s.code.len or
        s.atom_len > s.atom_operands.len or
        s.label_len > s.label_slots.len or
        s.source_len > s.source_slots.len)
    {
        return error.InvalidBytecode;
    }

    var previous_source_offset: u32 = 0;
    for (s.source_slots[0..s.source_len], 0..) |source, index| {
        if (source.temp_offset > s.code_len or
            (index != 0 and source.temp_offset < previous_source_offset))
        {
            return error.InvalidBytecode;
        }
        previous_source_offset = source.temp_offset;
    }

    for (s.label_slots[0..s.label_len]) |slot| {
        if (slot.flags.bound) {
            if (slot.bound_offset == labels.unbound or slot.bound_offset > s.code_len)
                return error.InvalidBytecode;
        } else if (slot.bound_offset != labels.unbound) {
            return error.InvalidBytecode;
        }
    }
    try extra(s);
}

/// Count, allocate, fill, and sort the bound-label index. `fill` supplies
/// the pass-specific snapshots; the sort key is the shared one.
pub fn buildBindIndex(
    memory: std.mem.Allocator,
    slots: []const labels.LabelSlot,
    comptime fill: fn (labels.LabelSlot, usize) BindEntry,
) Error![]BindEntry {
    var bind_count: usize = 0;
    for (slots) |slot| {
        if (slot.flags.bound) bind_count += 1;
    }
    if (bind_count == 0) return &.{};

    const binds = memory.alloc(BindEntry, bind_count) catch return error.OutOfMemory;
    var index: usize = 0;
    for (slots, 0..) |slot, label_index| {
        if (!slot.flags.bound) continue;
        binds[index] = fill(slot, label_index);
        index += 1;
    }
    sort_erased.heap(BindEntry, binds, {}, bindLessThan);
    return binds;
}

pub const TempInstruction = packed struct(u16) {
    size: u8,
    is_temp: bool = false,
    has_atom: bool = false,
    reserved: u6 = 0,
};

/// Decode and validate one instruction from the parser-owned phase-1 Builder.
/// Ids in the temp/short overlap range are always the temp form here. The
/// atom comparison both proves that the phase-1 interpretation is valid and
/// authorizes the resolver to consume the matching ledger entry without
/// checking the same operand again.
pub inline fn phase1Instruction(
    code: []const u8,
    atoms_ledger: []const core.atom.Atom,
    pc: u32,
    atom_index: u32,
) Error!TempInstruction {
    const h = opcode.decode.headerAtPhase1(code, atoms_ledger, pc, atom_index) catch
        return error.InvalidBytecode;
    return .{
        .size = h.size,
        .is_temp = h.isLowered(),
        .has_atom = h.hasAtom(),
    };
}

/// A source line/column pair.
pub const SourcePoint = struct {
    line: i32,
    col: i32,

    pub fn eql(self: SourcePoint, other: SourcePoint) bool {
        return self.line == other.line and self.col == other.col;
    }
};
