//! QCP-1 compiler-v2 Stage 1: the parser-facing emission builder.
//!
//! API-FROZEN SHELL (driver-owned). Stage 1 fills the bodies; later stages
//! code against exactly this surface. The parser emits COMPACT temporary
//! bytecode (opcode + compact operands + LabelId + Atom + scope operand) —
//! no per-instruction object IR (C1 proved a per-instruction record stream
//! is a real cache tax). Consumer-proportional side tables only:
//! LabelSlot[], RelocEntry[], SourceSlot[].
//!
//! Ownership contract:
//!   - atom operands appended to the builder are OWNED (retained) by the
//!     builder's ledger until the product is committed or the builder is
//!     deinitialized (item-wise release of the initialized prefix, then
//!     backings freed by full capacity, uninitialized tails never read);
//!   - speculative emission uses snapshot/rollback restoring code length,
//!     atom ledger length (releasing rolled-back refs), label count,
//!     reloc length, and source-slot length — mirroring the legacy
//!     EmissionSnapshot discipline;
//!   - OOM anywhere leaves the builder consistent for deinit; no partial
//!     state is observable by later passes.
//!
//! Liveness note: `last_opcode_pos` mirrors qjs fd->last_opcode_pos from
//! day one, and label `ref_count` is the O(1) merge-liveness answer — the
//! legacy FlowTailSummary machinery is deliberately NOT ported.

const std = @import("std");
const labels = @import("labels.zig");
const core = @import("../core/root.zig");

pub const LabelId = labels.LabelId;

/// Source marker bound to the logical output event order, not to a byte pc
/// of any intermediate stream. pc2line is generated at final emission from
/// current output positions (QuickJS shape); no old-PC relocation chain.
pub const SourceSlot = struct {
    /// Temporary-stream offset of the instruction the marker precedes.
    /// Used only until final emission maps events to output positions.
    temp_offset: u32,
    line: i32,
    col: i32,
};

pub const Error = error{
    OutOfMemory,
    InvalidBytecode,
    BytecodeOverflow,
};

pub const Snapshot = struct {
    code_len: u32,
    atom_len: u32,
    label_len: u32,
    reloc_len: u32,
    source_len: u32,
    last_opcode_pos: i64,
};

pub const Builder = struct {
    memory: *core.memory.MemoryAccount,
    atoms: *core.atom.AtomTable,

    /// Compact temporary bytecode.
    code: []u8 = &.{},
    code_capacity: usize = 0,
    code_len: u32 = 0,

    /// Owned (retained) atom operands, lockstep with atom-bearing opcodes.
    atom_operands: []core.atom.Atom = &.{},
    atom_capacity: usize = 0,
    atom_len: u32 = 0,

    label_slots: []labels.LabelSlot = &.{},
    label_capacity: usize = 0,
    label_len: u32 = 0,

    relocs: []labels.RelocEntry = &.{},
    reloc_capacity: usize = 0,
    reloc_len: u32 = 0,

    source_slots: []SourceSlot = &.{},
    source_capacity: usize = 0,
    source_len: u32 = 0,

    /// qjs fd->last_opcode_pos: temp offset of the last emitted opcode, or
    /// -1 when invalidated at a control-flow merge.
    last_opcode_pos: i64 = -1,

    pub fn init(memory: *core.memory.MemoryAccount, atoms: *core.atom.AtomTable) Builder {
        _ = memory;
        _ = atoms;
        @compileError("Stage 1 implements Builder.init");
    }

    /// Item-wise release of the owned atom prefix, then every backing freed
    /// by full capacity. Idempotent.
    pub fn deinit(self: *Builder) void {
        _ = self;
        @compileError("Stage 1 implements Builder.deinit");
    }

    pub fn newLabel(self: *Builder) Error!LabelId {
        _ = self;
        @compileError("Stage 1 implements Builder.newLabel");
    }

    /// Emit a jump-format opcode referencing `label`; appends a RelocEntry
    /// to the label's chain and bumps ref_count. The 4-byte operand holds
    /// the LabelId until final emission.
    pub fn emitJump(self: *Builder, op_id: u8, label: LabelId) Error!void {
        _ = self;
        _ = op_id;
        _ = label;
        @compileError("Stage 1 implements Builder.emitJump");
    }

    /// Bind `label` to the current temporary position. Double-bind and
    /// binding a foreign label fail closed.
    pub fn bindLabel(self: *Builder, label: LabelId) Error!void {
        _ = self;
        _ = label;
        @compileError("Stage 1 implements Builder.bindLabel");
    }

    pub fn emitOp(self: *Builder, op_id: u8) Error!void {
        _ = self;
        _ = op_id;
        @compileError("Stage 1 implements Builder.emitOp");
    }

    /// Emit an atom-bearing opcode; `atom_id` ownership (one retain)
    /// transfers into the builder ledger.
    pub fn emitAtomOpOwned(self: *Builder, op_id: u8, atom_id: core.atom.Atom) Error!void {
        _ = self;
        _ = op_id;
        _ = atom_id;
        @compileError("Stage 1 implements Builder.emitAtomOpOwned");
    }

    pub fn addSourceMarker(self: *Builder, line: i32, col: i32) Error!void {
        _ = self;
        _ = line;
        _ = col;
        @compileError("Stage 1 implements Builder.addSourceMarker");
    }

    pub fn snapshot(self: *const Builder) Snapshot {
        _ = self;
        @compileError("Stage 1 implements Builder.snapshot");
    }

    /// Roll back to `snap`: truncates code/labels/relocs/source slots and
    /// releases atom refs beyond the snapshot ledger length. Label slots
    /// created after the snapshot vanish; refs recorded after it are
    /// unchained by construction (their reloc entries are truncated).
    pub fn rollback(self: *Builder, snap: Snapshot) void {
        _ = self;
        _ = snap;
        @compileError("Stage 1 implements Builder.rollback");
    }
};

test {
    _ = Builder;
}
