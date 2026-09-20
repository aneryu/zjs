//! Shared vocabulary of the two resolve passes over the compiler temporary
//! stream: the bind index rows, the phase-1 instruction view, and the source
//! point used to dedupe markers.

const std = @import("std");
const core = @import("../core/root.zig");
const bytecode = @import("../bytecode.zig");

const opcode = bytecode.opcode;

pub const Error = error{
    OutOfMemory,
    InvalidBytecode,
};

/// Sorted bind-index row of `resolve_variables`: one per bound label, keyed
/// by the temporary-stream offset the label is bound at. `dead_skipped` is
/// resolver bookkeeping.
pub const BindEntry = struct {
    input_offset: u32,
    label_index: u32,
    dead_skipped: bool = false,
};

pub fn bindLessThan(_: void, lhs: BindEntry, rhs: BindEntry) bool {
    if (lhs.input_offset != rhs.input_offset) return lhs.input_offset < rhs.input_offset;
    return lhs.label_index < rhs.label_index;
}

pub const TempInstruction = packed struct(u16) {
    size: u8,
    is_temp: bool = false,
    has_atom: bool = false,
    has_label: bool = false,
    reserved: u5 = 0,
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
        .has_label = h.hasLabel(),
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
