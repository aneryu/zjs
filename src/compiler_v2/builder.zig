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
//! Control-flow note: `last_opcode_pos` mirrors qjs fd->last_opcode_pos from
//! day one. Label `ref_count` is relocation/short-form bookkeeping; exact
//! liveness is computed later from the LabelId block CFG.

const std = @import("std");
const builtin = @import("builtin");
const coverage = @import("coverage.zig");
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

/// A detached tail segment. Owns its backings and the atom refs moved out of
/// the builder ledger until spliceSegment (which consumes it) or
/// discardSegment (which releases it). Offsets are segment-relative.
pub const DetachedSegment = struct {
    code: []u8 = &.{},
    atoms: []core.atom.Atom = &.{},
    /// operand_offset is segment-relative; kind is preserved (jump32/aux32).
    relocs: []labels.RelocEntry = &.{},
    /// Labels whose bind sits inside the segment, as (label, rel offset).
    binds: []Bind = &.{},
    sources: []SourceSlot = &.{},

    pub const Bind = struct {
        label_index: u32,
        rel_offset: u32,
    };
};

pub const Error = error{
    OutOfMemory,
    InvalidBytecode,
    BytecodeOverflow,
};

/// Grow a backing without changing its initialized-prefix length. The visible
/// slice always spans the full allocation; `used` alone identifies readable
/// entries.
fn reserve(
    comptime T: type,
    mem: *core.memory.MemoryAccount,
    slice: *[]T,
    capacity: *usize,
    used: u32,
    need: usize,
    comptime min_cap: usize,
) Error!void {
    const required = std.math.add(usize, @as(usize, used), need) catch
        return error.OutOfMemory;
    if (required <= capacity.*) return;

    const doubled = std.math.mul(usize, capacity.*, 2) catch std.math.maxInt(usize);
    const new_capacity = @max(@max(required, doubled), min_cap);
    const new_backing = mem.alloc(T, new_capacity) catch return error.OutOfMemory;
    @memcpy(new_backing[0..used], slice.*[0..used]);

    const old_backing = slice.*;
    const old_capacity = capacity.*;
    slice.* = new_backing;
    capacity.* = new_capacity;
    if (old_capacity != 0) mem.free(T, old_backing);
}

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
        return .{ .memory = memory, .atoms = atoms };
    }

    /// Item-wise release of the owned atom prefix, then every backing freed
    /// by full capacity. Idempotent.
    pub fn deinit(self: *Builder) void {
        for (self.atom_operands[0..self.atom_len]) |atom_id| self.atoms.free(atom_id);

        if (self.code_capacity != 0) self.memory.free(u8, self.code);
        if (self.atom_capacity != 0) self.memory.free(core.atom.Atom, self.atom_operands);
        if (self.label_capacity != 0) self.memory.free(labels.LabelSlot, self.label_slots);
        if (self.reloc_capacity != 0) self.memory.free(labels.RelocEntry, self.relocs);
        if (self.source_capacity != 0) self.memory.free(SourceSlot, self.source_slots);

        self.code = &.{};
        self.code_capacity = 0;
        self.code_len = 0;
        self.atom_operands = &.{};
        self.atom_capacity = 0;
        self.atom_len = 0;
        self.label_slots = &.{};
        self.label_capacity = 0;
        self.label_len = 0;
        self.relocs = &.{};
        self.reloc_capacity = 0;
        self.reloc_len = 0;
        self.source_slots = &.{};
        self.source_capacity = 0;
        self.source_len = 0;
        self.last_opcode_pos = -1;
    }

    pub fn newLabel(self: *Builder) Error!LabelId {
        if (self.label_len == std.math.maxInt(u32)) return error.BytecodeOverflow;
        try reserve(
            labels.LabelSlot,
            self.memory,
            &self.label_slots,
            &self.label_capacity,
            self.label_len,
            1,
            8,
        );

        const label_index = self.label_len;
        self.label_slots[label_index] = .{};
        self.label_len += 1;
        return @enumFromInt(label_index);
    }

    /// Emit a jump-format opcode referencing `label`; appends a RelocEntry
    /// to the label's chain and bumps ref_count. The 4-byte operand holds
    /// the LabelId until final emission.
    pub fn emitJump(self: *Builder, op_id: u8, label: LabelId) Error!void {
        if (label.index() >= self.label_len) return error.InvalidBytecode;

        try self.reserveCode(5);
        try reserve(
            labels.RelocEntry,
            self.memory,
            &self.relocs,
            &self.reloc_capacity,
            self.reloc_len,
            1,
            8,
        );

        const opcode_offset = self.code_len;
        const opcode_index: usize = @intCast(opcode_offset);
        const operand_offset = opcode_offset + 1;
        self.code[opcode_index] = op_id;
        std.mem.writeInt(u32, self.code[opcode_index + 1 ..][0..4], label.index(), .little);

        const slot = &self.label_slots[label.index()];
        const reloc_index = self.reloc_len;
        self.relocs[reloc_index] = .{
            .next = slot.first_reloc,
            .operand_offset = operand_offset,
            .kind = .jump32,
        };
        // Relocations are pushed head-first, so following `next` always walks
        // strictly decreasing indices. Rollback relies on that ordering.
        slot.first_reloc = reloc_index;
        slot.ref_count += 1;
        if (slot.flags.bound) slot.flags.backward_target = true;

        self.reloc_len += 1;
        self.last_opcode_pos = @intCast(opcode_offset);
        self.code_len += 5;
    }

    /// Bind `label` to the current temporary position. Double-bind and
    /// binding a foreign label fail closed.
    pub fn bindLabel(self: *Builder, label: LabelId) Error!void {
        if (label.index() >= self.label_len) return error.InvalidBytecode;
        const slot = &self.label_slots[label.index()];
        if (slot.flags.bound) return error.InvalidBytecode;

        slot.bound_offset = self.code_len;
        slot.flags.bound = true;
    }

    /// Bind an identity-native label while retaining the sequential matcher
    /// barrier of a parser-emitted `OP_label`. Ordinary absolute-PC patch
    /// targets use `bindLabel` and remain transparent after losing all refs.
    pub fn bindLabelMatchBarrier(self: *Builder, label: LabelId) Error!void {
        try self.bindLabel(label);
        self.label_slots[label.index()].flags.match_barrier = true;
    }

    /// Move every pending reference from `from` onto `to`. This is the
    /// identity-native form of the legacy parser's `patchJumpTarget`: QuickJS
    /// resolves a jump whose destination only becomes known later by writing
    /// the destination PC back into the already-emitted operand
    /// (`js_parse_switch`'s dispatch patch, quickjs.c ~29365). V2 never
    /// materializes a PC in the parser, so the operand keeps holding a
    /// `LabelId` and the reference moves to the identity that already denotes
    /// that program point.
    ///
    /// This is deliberately NOT `bindLabel`: a bind creates a second identity
    /// at one boundary and forces the emitter to route through it, and
    /// `bindLabel` also invalidates the last opcode the way `patchForwardJump`
    /// does. `patchJumpTarget` does neither, and neither does this.
    ///
    /// `from` must still be unbound (retargeting a bound label would abandon a
    /// boundary other code can already reach) and `to` must already be bound
    /// (its position is the answer being published).
    pub fn retargetLabelRefs(self: *Builder, from: LabelId, to: LabelId) Error!void {
        if (from.index() >= self.label_len or to.index() >= self.label_len)
            return error.InvalidBytecode;
        if (from.index() == to.index()) return error.InvalidBytecode;
        const from_slot = &self.label_slots[from.index()];
        const to_slot = &self.label_slots[to.index()];
        if (from_slot.flags.bound or !to_slot.flags.bound) return error.InvalidBytecode;

        // Validate the whole chain before mutating anything: a half-moved
        // chain is unrecoverable.
        var moved: u32 = 0;
        var cursor = from_slot.first_reloc;
        while (cursor != labels.no_reloc) {
            if (cursor >= self.reloc_len) return error.InvalidBytecode;
            const entry = self.relocs[cursor];
            if (@as(u64, entry.operand_offset) + 4 > self.code_len)
                return error.InvalidBytecode;
            const operand: usize = @intCast(entry.operand_offset);
            if (std.mem.readInt(u32, self.code[operand..][0..4], .little) != from.index())
                return error.InvalidBytecode;
            moved += 1;
            cursor = entry.next;
        }
        if (from_slot.ref_count != moved) return error.InvalidBytecode;
        if (moved > std.math.maxInt(u32) - to_slot.ref_count)
            return error.BytecodeOverflow;

        cursor = from_slot.first_reloc;
        while (cursor != labels.no_reloc) {
            const entry = self.relocs[cursor];
            const operand: usize = @intCast(entry.operand_offset);
            std.mem.writeInt(u32, self.code[operand..][0..4], to.index(), .little);
            // Same predicate spliceSegment uses for a re-chained reference.
            if (to_slot.bound_offset < entry.operand_offset)
                to_slot.flags.backward_target = true;
            cursor = entry.next;
        }

        // Relocation chains are walked head-first by `rollback`/`detachTail`,
        // which stop at the first entry below a mark; that only works while a
        // chain stays strictly descending by reloc index. Merge, do not
        // concatenate.
        var merged_head: u32 = labels.no_reloc;
        var merged_tail: u32 = labels.no_reloc;
        var left = from_slot.first_reloc;
        var right = to_slot.first_reloc;
        while (left != labels.no_reloc or right != labels.no_reloc) {
            var take: u32 = undefined;
            if (right == labels.no_reloc or (left != labels.no_reloc and left > right)) {
                take = left;
                left = self.relocs[left].next;
            } else {
                take = right;
                right = self.relocs[right].next;
            }
            if (merged_head == labels.no_reloc) {
                merged_head = take;
            } else {
                self.relocs[merged_tail].next = take;
            }
            merged_tail = take;
        }
        if (merged_tail != labels.no_reloc) self.relocs[merged_tail].next = labels.no_reloc;

        to_slot.first_reloc = merged_head;
        to_slot.ref_count += moved;
        from_slot.first_reloc = labels.no_reloc;
        from_slot.ref_count = 0;
        // Every identity a function creates must end up bound: `labels_unbound`
        // is a dual-mode L0 ledger invariant. Record the merge for what it is —
        // `from` now denotes the same program point as `to` — instead of
        // leaving an orphan or binding it at some unrelated later position. It
        // carries no reference and no match barrier, so it is transparent to
        // Stage 4 and joins `to`'s alias group with `to`'s final address.
        from_slot.bound_offset = to_slot.bound_offset;
        from_slot.flags.bound = true;
    }

    /// Return the first unbound label in function-local creation order.
    pub fn firstUnboundLabel(self: *const Builder) ?LabelId {
        var label_index: u32 = 0;
        while (label_index < self.label_len) : (label_index += 1) {
            if (!self.label_slots[label_index].flags.bound) return @enumFromInt(label_index);
        }
        return null;
    }

    pub fn emitOp(self: *Builder, op_id: u8) Error!void {
        try self.reserveCode(1);

        const opcode_offset = self.code_len;
        self.code[opcode_offset] = op_id;
        self.last_opcode_pos = @intCast(opcode_offset);
        self.code_len += 1;
    }

    /// Emit an opcode with a u8 immediate operand (compact temp encoding).
    pub fn emitOpU8(self: *Builder, op_id: u8, val: u8) Error!void {
        try self.reserveCode(2);

        const opcode_offset = self.code_len;
        const opcode_index: usize = @intCast(opcode_offset);
        self.code[opcode_index] = op_id;
        self.code[opcode_index + 1] = val;
        self.last_opcode_pos = @intCast(opcode_offset);
        self.code_len += 2;
    }

    /// Emit an opcode with a u16 immediate operand (compact temp encoding).
    pub fn emitOpU16(self: *Builder, op_id: u8, val: u16) Error!void {
        try self.reserveCode(3);

        const opcode_offset = self.code_len;
        const opcode_index: usize = @intCast(opcode_offset);
        self.code[opcode_index] = op_id;
        std.mem.writeInt(u16, self.code[opcode_index + 1 ..][0..2], val, .little);
        self.last_opcode_pos = @intCast(opcode_offset);
        self.code_len += 3;
    }

    /// Emit an opcode with a u32 immediate operand (compact temp encoding).
    pub fn emitOpU32(self: *Builder, op_id: u8, val: u32) Error!void {
        try self.reserveCode(5);

        const opcode_offset = self.code_len;
        const opcode_index: usize = @intCast(opcode_offset);
        self.code[opcode_index] = op_id;
        std.mem.writeInt(u32, self.code[opcode_index + 1 ..][0..4], val, .little);
        self.last_opcode_pos = @intCast(opcode_offset);
        self.code_len += 5;
    }

    /// Emit an opcode with an i32 immediate operand (compact temp encoding).
    pub fn emitOpI32(self: *Builder, op_id: u8, val: i32) Error!void {
        try self.reserveCode(5);

        const opcode_offset = self.code_len;
        const opcode_index: usize = @intCast(opcode_offset);
        self.code[opcode_index] = op_id;
        std.mem.writeInt(i32, self.code[opcode_index + 1 ..][0..4], val, .little);
        self.last_opcode_pos = @intCast(opcode_offset);
        self.code_len += 5;
    }

    /// Emit an atom-bearing opcode; `atom_id` ownership (one retain)
    /// transfers into the builder ledger.
    pub fn emitAtomOpOwned(self: *Builder, op_id: u8, atom_id: core.atom.Atom) Error!void {
        // Ownership transfer is unconditional: the sink consumes the caller's
        // retained atom even when either capacity reservation fails.
        self.reserveCode(5) catch |err| {
            self.atoms.free(atom_id);
            return err;
        };
        reserve(
            core.atom.Atom,
            self.memory,
            &self.atom_operands,
            &self.atom_capacity,
            self.atom_len,
            1,
            8,
        ) catch |err| {
            self.atoms.free(atom_id);
            return err;
        };

        const opcode_offset = self.code_len;
        const opcode_index: usize = @intCast(opcode_offset);
        self.atom_operands[self.atom_len] = atom_id;
        self.code[opcode_index] = op_id;
        std.mem.writeInt(u32, self.code[opcode_index + 1 ..][0..4], atom_id, .little);

        self.atom_len += 1;
        self.last_opcode_pos = @intCast(opcode_offset);
        self.code_len += 5;
    }

    /// Emit an atom-bearing opcode with a trailing u8 immediate (op + atom +
    /// u8, the define_class/define_method temp encoding). `atom_id` ownership
    /// (one retain) transfers into the builder ledger.
    pub fn emitAtomOpU8Owned(self: *Builder, op_id: u8, atom_id: core.atom.Atom, val: u8) Error!void {
        self.reserveCode(6) catch |err| {
            self.atoms.free(atom_id);
            return err;
        };
        reserve(
            core.atom.Atom,
            self.memory,
            &self.atom_operands,
            &self.atom_capacity,
            self.atom_len,
            1,
            8,
        ) catch |err| {
            self.atoms.free(atom_id);
            return err;
        };

        const opcode_offset = self.code_len;
        const opcode_index: usize = @intCast(opcode_offset);
        self.atom_operands[self.atom_len] = atom_id;
        self.code[opcode_index] = op_id;
        std.mem.writeInt(u32, self.code[opcode_index + 1 ..][0..4], atom_id, .little);
        self.code[opcode_index + 5] = val;

        self.atom_len += 1;
        self.last_opcode_pos = @intCast(opcode_offset);
        self.code_len += 6;
    }

    /// Emit an atom-bearing opcode with a trailing u16 immediate (op + atom +
    /// scope operand, the scope_get_var-family temp encoding). Owned-atom sink.
    pub fn emitAtomOpU16Owned(self: *Builder, op_id: u8, atom_id: core.atom.Atom, val: u16) Error!void {
        self.reserveCode(7) catch |err| {
            self.atoms.free(atom_id);
            return err;
        };
        reserve(
            core.atom.Atom,
            self.memory,
            &self.atom_operands,
            &self.atom_capacity,
            self.atom_len,
            1,
            8,
        ) catch |err| {
            self.atoms.free(atom_id);
            return err;
        };

        const opcode_offset = self.code_len;
        const opcode_index: usize = @intCast(opcode_offset);
        self.atom_operands[self.atom_len] = atom_id;
        self.code[opcode_index] = op_id;
        std.mem.writeInt(u32, self.code[opcode_index + 1 ..][0..4], atom_id, .little);
        std.mem.writeInt(u16, self.code[opcode_index + 5 ..][0..2], val, .little);

        self.atom_len += 1;
        self.last_opcode_pos = @intCast(opcode_offset);
        self.code_len += 7;
    }

    /// Emit a scope-ref opcode carrying an auxiliary label operand:
    /// op + atom(4) + label(4) + scope(2), 11 bytes. The label operand holds the
    /// LabelId until final emission; the RelocEntry is kind .aux32 at
    /// opcode_offset + 5. Bumps ref_count (qjs update_label(fd, label, 1)) and
    /// marks backward_target when the label is already bound. Owned-atom sink;
    /// an invalid label fails closed after consuming the atom retain.
    pub fn emitScopeRefOpOwned(
        self: *Builder,
        op_id: u8,
        atom_id: core.atom.Atom,
        label: LabelId,
        scope: u16,
    ) Error!void {
        if (label.index() >= self.label_len) {
            self.atoms.free(atom_id);
            return error.InvalidBytecode;
        }

        self.reserveCode(11) catch |err| {
            self.atoms.free(atom_id);
            return err;
        };
        reserve(
            labels.RelocEntry,
            self.memory,
            &self.relocs,
            &self.reloc_capacity,
            self.reloc_len,
            1,
            8,
        ) catch |err| {
            self.atoms.free(atom_id);
            return err;
        };
        reserve(
            core.atom.Atom,
            self.memory,
            &self.atom_operands,
            &self.atom_capacity,
            self.atom_len,
            1,
            8,
        ) catch |err| {
            self.atoms.free(atom_id);
            return err;
        };

        const opcode_offset = self.code_len;
        const opcode_index: usize = @intCast(opcode_offset);
        const operand_offset = opcode_offset + 5;
        self.atom_operands[self.atom_len] = atom_id;
        self.code[opcode_index] = op_id;
        std.mem.writeInt(u32, self.code[opcode_index + 1 ..][0..4], atom_id, .little);
        std.mem.writeInt(u32, self.code[opcode_index + 5 ..][0..4], label.index(), .little);
        std.mem.writeInt(u16, self.code[opcode_index + 9 ..][0..2], scope, .little);

        const slot = &self.label_slots[label.index()];
        const reloc_index = self.reloc_len;
        self.relocs[reloc_index] = .{
            .next = slot.first_reloc,
            .operand_offset = operand_offset,
            .kind = .aux32,
        };
        slot.first_reloc = reloc_index;
        slot.ref_count += 1;
        if (slot.flags.bound) slot.flags.backward_target = true;

        self.atom_len += 1;
        self.reloc_len += 1;
        self.last_opcode_pos = @intCast(opcode_offset);
        self.code_len += 11;
    }

    /// Emit a final-format atom + auxiliary LabelId + u8 instruction. This is
    /// the compact identity-coordinate twin of the legacy atom_label_u8 form.
    /// Owned-atom sink with the same transactional guarantees as
    /// emitScopeRefOpOwned.
    pub fn emitAtomLabelOpU8Owned(
        self: *Builder,
        op_id: u8,
        atom_id: core.atom.Atom,
        label: LabelId,
        value: u8,
    ) Error!void {
        if (label.index() >= self.label_len) {
            self.atoms.free(atom_id);
            return error.InvalidBytecode;
        }

        self.reserveCode(10) catch |err| {
            self.atoms.free(atom_id);
            return err;
        };
        reserve(
            labels.RelocEntry,
            self.memory,
            &self.relocs,
            &self.reloc_capacity,
            self.reloc_len,
            1,
            8,
        ) catch |err| {
            self.atoms.free(atom_id);
            return err;
        };
        reserve(
            core.atom.Atom,
            self.memory,
            &self.atom_operands,
            &self.atom_capacity,
            self.atom_len,
            1,
            8,
        ) catch |err| {
            self.atoms.free(atom_id);
            return err;
        };

        const opcode_offset = self.code_len;
        const opcode_index: usize = @intCast(opcode_offset);
        const operand_offset = opcode_offset + 5;
        self.atom_operands[self.atom_len] = atom_id;
        self.code[opcode_index] = op_id;
        std.mem.writeInt(u32, self.code[opcode_index + 1 ..][0..4], atom_id, .little);
        std.mem.writeInt(u32, self.code[opcode_index + 5 ..][0..4], label.index(), .little);
        self.code[opcode_index + 9] = value;

        const slot = &self.label_slots[label.index()];
        const reloc_index = self.reloc_len;
        self.relocs[reloc_index] = .{
            .next = slot.first_reloc,
            .operand_offset = operand_offset,
            .kind = .aux32,
        };
        slot.first_reloc = reloc_index;
        slot.ref_count += 1;
        if (slot.flags.bound) slot.flags.backward_target = true;

        self.atom_len += 1;
        self.reloc_len += 1;
        self.last_opcode_pos = @intCast(opcode_offset);
        self.code_len += 10;
    }

    /// Transfer ownership of the newest ledger atom back to the caller
    /// (the reverse of an owned-atom sink). Fails closed on an empty ledger.
    pub fn takeLastAtomOwned(self: *Builder) Error!core.atom.Atom {
        if (self.atom_len == 0) return error.InvalidBytecode;
        self.atom_len -= 1;
        return self.atom_operands[self.atom_len];
    }

    pub fn addSourceMarker(self: *Builder, line: i32, col: i32) Error!void {
        if (line <= 0 or col <= 0) return;
        if (builtin.mode == .Debug) {
            std.debug.assert(self.source_len == 0 or
                self.source_slots[self.source_len - 1].temp_offset <= self.code_len);
        }
        try reserve(
            SourceSlot,
            self.memory,
            &self.source_slots,
            &self.source_capacity,
            self.source_len,
            1,
            8,
        );

        self.source_slots[self.source_len] = .{
            .temp_offset = self.code_len,
            .line = line,
            .col = col,
        };
        self.source_len += 1;
    }

    pub fn snapshot(self: *const Builder) Snapshot {
        return .{
            .code_len = self.code_len,
            .atom_len = self.atom_len,
            .label_len = self.label_len,
            .reloc_len = self.reloc_len,
            .source_len = self.source_len,
            .last_opcode_pos = self.last_opcode_pos,
        };
    }

    /// Roll back to `snap`: truncates code/labels/relocs/source slots and
    /// releases atom refs beyond the snapshot ledger length. Label slots
    /// created after the snapshot vanish; refs recorded after it are
    /// unchained by construction (their reloc entries are truncated).
    pub fn rollback(self: *Builder, snap: Snapshot) void {
        for (self.atom_operands[snap.atom_len..self.atom_len]) |atom_id| self.atoms.free(atom_id);
        self.atom_len = snap.atom_len;

        if (builtin.mode == .Debug) {
            var label_index = snap.label_len;
            while (label_index < self.label_len) : (label_index += 1) {
                var head = self.label_slots[label_index].first_reloc;
                while (head != labels.no_reloc) {
                    std.debug.assert(head >= snap.reloc_len);
                    head = self.relocs[head].next;
                }
            }
        }

        if (self.reloc_len != snap.reloc_len) {
            var label_index: u32 = 0;
            while (label_index < snap.label_len) : (label_index += 1) {
                const slot = &self.label_slots[label_index];
                var head = slot.first_reloc;
                while (head != labels.no_reloc and head >= snap.reloc_len) {
                    std.debug.assert(slot.ref_count > 0);
                    slot.ref_count -= 1;
                    head = self.relocs[head].next;
                }
                slot.first_reloc = head;
            }
        }

        var label_index: u32 = 0;
        while (label_index < snap.label_len) : (label_index += 1) {
            const slot = &self.label_slots[label_index];
            // Keep a bind exactly at the rollback boundary: a pre-snapshot bind
            // there is indistinguishable, and a post-snapshot bind there is
            // still valid at the restored position.
            if (slot.flags.bound and slot.bound_offset > snap.code_len) {
                slot.bound_offset = labels.unbound;
                slot.flags.bound = false;
            }
            // `backward_target` is intentionally conservative and is never a
            // correctness input, so rollback does not clear it.
        }

        self.code_len = snap.code_len;
        self.label_len = snap.label_len;
        self.reloc_len = snap.reloc_len;
        self.source_len = snap.source_len;
        self.last_opcode_pos = snap.last_opcode_pos;
    }

    /// Drop the code tail beyond `new_code_len` — the qjs get_lvalue
    /// `fd->byte_code.size = fd->last_opcode_pos` rewind. Only for tails that
    /// carry no relocations and no label binds: the newest reloc's operand is the
    /// high-water mark (operand offsets are emission-ordered), so the no-reloc
    /// requirement is an O(1) check; binds beyond the boundary are a Debug scan.
    /// Source markers at or beyond the boundary are dropped (legacy truncateCode
    /// slot rule). Invalidates last_opcode_pos.
    pub fn truncateTail(self: *Builder, new_code_len: u32) void {
        std.debug.assert(new_code_len <= self.code_len);
        std.debug.assert(self.reloc_len == 0 or
            self.relocs[self.reloc_len - 1].operand_offset + 4 <= new_code_len);

        if (builtin.mode == .Debug) {
            for (self.label_slots[0..self.label_len]) |slot| {
                std.debug.assert(!slot.flags.bound or slot.bound_offset <= new_code_len);
            }
        }

        while (self.source_len > 0 and
            self.source_slots[self.source_len - 1].temp_offset >= new_code_len)
        {
            self.source_len -= 1;
        }
        self.code_len = new_code_len;
        self.last_opcode_pos = -1;
    }

    /// Rewind one parser opcode emitted through a marker'd facade while
    /// retaining older zero-width source events at the same compact offset.
    /// Legacy OP_line_num bytes keep those older events physically before the
    /// getter opcode; the compact v2 ledger represents them at one offset, so
    /// only its newest slot belongs to the opcode being removed.
    pub fn truncateLastMarkedOpcode(self: *Builder, new_code_len: u32) Error!void {
        if (new_code_len > self.code_len or
            self.last_opcode_pos < 0 or
            @as(u32, @intCast(self.last_opcode_pos)) != new_code_len)
        {
            return error.InvalidBytecode;
        }
        if (self.reloc_len != 0 and
            self.relocs[self.reloc_len - 1].operand_offset + 4 > new_code_len)
        {
            return error.InvalidBytecode;
        }
        for (self.label_slots[0..self.label_len]) |slot| {
            if (slot.flags.bound and slot.bound_offset > new_code_len)
                return error.InvalidBytecode;
        }
        if (self.source_len == 0 or
            self.source_slots[self.source_len - 1].temp_offset != new_code_len)
        {
            return error.InvalidBytecode;
        }

        self.source_len -= 1;
        self.code_len = new_code_len;
        self.last_opcode_pos = -1;
    }

    /// Detach the tail emitted since `mark` (a snapshot taken at the segment
    /// start, BEFORE any emission or bind belonging to the segment). Captures
    /// code bytes, ledger atoms (ownership moves out; nothing is released),
    /// reloc entries (unchained from their labels with ref_count decremented,
    /// exactly the rollback discipline — reloc indices >= mark.reloc_len are the
    /// chain tails by construction), label binds strictly inside the segment
    /// (bound_offset > mark.code_len; a bind exactly AT the mark stays put,
    /// matching the rollback boundary rule), and source slots by ledger index
    /// (>= mark.source_len), all made segment-relative. Labels themselves are
    /// NOT captured: LabelIds are function-global and label_len is untouched.
    /// The builder is truncated back to the mark with last_opcode_pos
    /// invalidated. All allocations happen before any builder mutation: OOM
    /// leaves the builder exactly as it was.
    pub fn detachTail(self: *Builder, mark: Snapshot) Error!DetachedSegment {
        const lengths_valid = mark.code_len <= self.code_len and
            mark.atom_len <= self.atom_len and
            mark.label_len <= self.label_len and
            mark.reloc_len <= self.reloc_len and
            mark.source_len <= self.source_len;
        std.debug.assert(lengths_valid);
        if (!lengths_valid) return error.InvalidBytecode;

        if (mark.reloc_len != 0) {
            const newest_survivor = self.relocs[mark.reloc_len - 1];
            const survivor_valid = @as(u64, newest_survivor.operand_offset) + 4 <= mark.code_len;
            std.debug.assert(survivor_valid);
            if (!survivor_valid) return error.InvalidBytecode;
        }
        for (self.relocs[mark.reloc_len..self.reloc_len]) |entry| {
            const entry_valid = entry.operand_offset >= mark.code_len and
                @as(u64, entry.operand_offset) + 4 <= self.code_len;
            std.debug.assert(entry_valid);
            if (!entry_valid) return error.InvalidBytecode;
        }
        for (self.source_slots[mark.source_len..self.source_len]) |slot| {
            const slot_valid = slot.temp_offset >= mark.code_len and slot.temp_offset <= self.code_len;
            std.debug.assert(slot_valid);
            if (!slot_valid) return error.InvalidBytecode;
        }

        var bind_count: usize = 0;
        for (self.label_slots[0..self.label_len]) |slot| {
            if (!slot.flags.bound) continue;
            const bind_valid = slot.bound_offset <= self.code_len;
            std.debug.assert(bind_valid);
            if (!bind_valid) return error.InvalidBytecode;
            if (slot.bound_offset > mark.code_len) bind_count += 1;
        }

        const code_count: usize = @intCast(self.code_len - mark.code_len);
        const atom_count: usize = @intCast(self.atom_len - mark.atom_len);
        const reloc_count: usize = @intCast(self.reloc_len - mark.reloc_len);
        const source_count: usize = @intCast(self.source_len - mark.source_len);
        var seg: DetachedSegment = .{};

        if (code_count != 0) {
            seg.code = self.memory.alloc(u8, code_count) catch return error.OutOfMemory;
        }
        errdefer if (seg.code.len != 0) self.memory.free(u8, seg.code);

        if (atom_count != 0) {
            seg.atoms = self.memory.alloc(core.atom.Atom, atom_count) catch return error.OutOfMemory;
        }
        errdefer if (seg.atoms.len != 0) self.memory.free(core.atom.Atom, seg.atoms);

        if (reloc_count != 0) {
            seg.relocs = self.memory.alloc(labels.RelocEntry, reloc_count) catch return error.OutOfMemory;
        }
        errdefer if (seg.relocs.len != 0) self.memory.free(labels.RelocEntry, seg.relocs);

        if (bind_count != 0) {
            seg.binds = self.memory.alloc(DetachedSegment.Bind, bind_count) catch return error.OutOfMemory;
        }
        errdefer if (seg.binds.len != 0) self.memory.free(DetachedSegment.Bind, seg.binds);

        if (source_count != 0) {
            seg.sources = self.memory.alloc(SourceSlot, source_count) catch return error.OutOfMemory;
        }
        errdefer if (seg.sources.len != 0) self.memory.free(SourceSlot, seg.sources);

        @memcpy(seg.code, self.code[mark.code_len..self.code_len]);
        @memcpy(seg.atoms, self.atom_operands[mark.atom_len..self.atom_len]);
        for (self.relocs[mark.reloc_len..self.reloc_len], seg.relocs) |entry, *detached| {
            detached.* = entry;
            detached.operand_offset -= mark.code_len;
        }
        for (self.source_slots[mark.source_len..self.source_len], seg.sources) |slot, *detached| {
            detached.* = slot;
            detached.temp_offset -= mark.code_len;
        }

        for (self.label_slots[0..self.label_len]) |*slot| {
            var head = slot.first_reloc;
            while (head != labels.no_reloc and head >= mark.reloc_len) {
                std.debug.assert(slot.ref_count > 0);
                slot.ref_count -= 1;
                head = self.relocs[head].next;
            }
            slot.first_reloc = head;
        }

        var bind_index: usize = 0;
        for (self.label_slots[0..self.label_len], 0..) |*slot, label_index| {
            if (!slot.flags.bound or slot.bound_offset <= mark.code_len) continue;
            seg.binds[bind_index] = .{
                .label_index = @intCast(label_index),
                .rel_offset = slot.bound_offset - mark.code_len,
            };
            bind_index += 1;
            slot.bound_offset = labels.unbound;
            slot.flags.bound = false;
        }
        std.debug.assert(bind_index == bind_count);

        self.code_len = mark.code_len;
        self.atom_len = mark.atom_len;
        self.reloc_len = mark.reloc_len;
        self.source_len = mark.source_len;
        self.last_opcode_pos = -1;
        return seg;
    }

    /// Re-append a detached segment at the current position, shifting every
    /// captured offset by the new base. Jump/aux operands are LabelIds and are
    /// NOT rewritten (no target rebase exists in v2). Validates every captured
    /// reloc against the segment bytes and reserves all destination capacity
    /// before mutating; after success the segment is consumed (its backings are
    /// freed and its atom ownership has moved back into the ledger), and
    /// last_opcode_pos is invalidated. On error the segment is untouched and
    /// still owned by the caller.
    pub fn spliceSegment(self: *Builder, seg: *DetachedSegment) Error!void {
        var previous_reloc_offset: ?u32 = null;
        for (seg.relocs) |entry| {
            const operand_end = @as(u64, entry.operand_offset) + 4;
            if (operand_end > seg.code.len) return error.InvalidBytecode;
            if (previous_reloc_offset) |previous| {
                if (entry.operand_offset <= previous) return error.InvalidBytecode;
            }
            previous_reloc_offset = entry.operand_offset;

            const operand_offset: usize = @intCast(entry.operand_offset);
            const label_index = std.mem.readInt(u32, seg.code[operand_offset..][0..4], .little);
            if (label_index >= self.label_len) return error.InvalidBytecode;
        }
        for (seg.binds) |bind| {
            if (bind.label_index >= self.label_len) return error.InvalidBytecode;
            if (self.label_slots[bind.label_index].flags.bound) return error.InvalidBytecode;
            if (@as(u64, bind.rel_offset) > seg.code.len) return error.InvalidBytecode;
        }
        var previous_source_offset: ?u32 = null;
        for (seg.sources) |slot| {
            if (@as(u64, slot.temp_offset) > seg.code.len) return error.InvalidBytecode;
            if (previous_source_offset) |previous| {
                if (slot.temp_offset < previous) return error.InvalidBytecode;
            }
            previous_source_offset = slot.temp_offset;
        }

        if (seg.relocs.len > @as(usize, std.math.maxInt(u32) - self.reloc_len) or
            seg.sources.len > @as(usize, std.math.maxInt(u32) - self.source_len) or
            seg.atoms.len > @as(usize, std.math.maxInt(u32) - self.atom_len))
        {
            return error.BytecodeOverflow;
        }

        try self.reserveCode(seg.code.len);
        try reserve(
            labels.RelocEntry,
            self.memory,
            &self.relocs,
            &self.reloc_capacity,
            self.reloc_len,
            seg.relocs.len,
            8,
        );
        try reserve(
            SourceSlot,
            self.memory,
            &self.source_slots,
            &self.source_capacity,
            self.source_len,
            seg.sources.len,
            8,
        );
        try reserve(
            core.atom.Atom,
            self.memory,
            &self.atom_operands,
            &self.atom_capacity,
            self.atom_len,
            seg.atoms.len,
            8,
        );

        const new_base = self.code_len;
        const code_index: usize = @intCast(new_base);
        @memcpy(self.code[code_index..][0..seg.code.len], seg.code);

        const atom_index: usize = @intCast(self.atom_len);
        @memcpy(self.atom_operands[atom_index..][0..seg.atoms.len], seg.atoms);
        self.atom_len += @intCast(seg.atoms.len);

        for (seg.binds) |bind| {
            const slot = &self.label_slots[bind.label_index];
            slot.bound_offset = new_base + bind.rel_offset;
            slot.flags.bound = true;
        }

        for (seg.sources) |source| {
            var shifted = source;
            shifted.temp_offset += new_base;
            if (builtin.mode == .Debug) {
                std.debug.assert(self.source_len == 0 or
                    self.source_slots[self.source_len - 1].temp_offset <= shifted.temp_offset);
            }
            self.source_slots[self.source_len] = shifted;
            self.source_len += 1;
        }

        for (seg.relocs) |entry| {
            const relative_operand: usize = @intCast(entry.operand_offset);
            const label_index = std.mem.readInt(u32, seg.code[relative_operand..][0..4], .little);
            const slot = &self.label_slots[label_index];
            const operand_offset = new_base + entry.operand_offset;
            const reloc_index = self.reloc_len;
            self.relocs[reloc_index] = .{
                .next = slot.first_reloc,
                .operand_offset = operand_offset,
                .kind = entry.kind,
            };
            slot.first_reloc = reloc_index;
            slot.ref_count += 1;
            if (slot.flags.bound and slot.bound_offset < operand_offset) {
                slot.flags.backward_target = true;
            }
            self.reloc_len += 1;
        }

        self.code_len += @intCast(seg.code.len);
        self.invalidateLastOpcode();
        self.freeSegmentBackings(seg);
    }

    /// Release a segment that will not be spliced (error paths): item-wise atom
    /// release, then backings freed. Idempotent.
    pub fn discardSegment(self: *Builder, seg: *DetachedSegment) void {
        for (seg.atoms) |atom_id| self.atoms.free(atom_id);
        self.freeSegmentBackings(seg);
    }

    /// Control-flow merge: forget the last opcode so no peephole fuses across
    /// the join (qjs sets fd->last_opcode_pos = -1 at labels).
    pub fn invalidateLastOpcode(self: *Builder) void {
        self.last_opcode_pos = -1;
    }

    fn freeSegmentBackings(self: *Builder, seg: *DetachedSegment) void {
        if (seg.code.len != 0) self.memory.free(u8, seg.code);
        if (seg.atoms.len != 0) self.memory.free(core.atom.Atom, seg.atoms);
        if (seg.relocs.len != 0) self.memory.free(labels.RelocEntry, seg.relocs);
        if (seg.binds.len != 0) self.memory.free(DetachedSegment.Bind, seg.binds);
        if (seg.sources.len != 0) self.memory.free(SourceSlot, seg.sources);
        seg.* = .{};
    }

    fn reserveCode(self: *Builder, need: usize) Error!void {
        // One event per emitted instruction, plus one per spliced segment.
        // Legacy counts its byte-append events, so the measures are comparable
        // emission funnels rather than byte-identical totals.
        if (comptime coverage.enabled) coverage.noteV2Emission();
        const required = @as(u64, self.code_len) + @as(u64, @intCast(need));
        if (required > std.math.maxInt(u32)) return error.BytecodeOverflow;
        try reserve(
            u8,
            self.memory,
            &self.code,
            &self.code_capacity,
            self.code_len,
            need,
            16,
        );
    }
};

test {
    _ = Builder;
}

fn expectRelocChain(
    b: *const Builder,
    label: LabelId,
    expected_offsets: []const u32,
    expected_kinds: []const labels.RelocKind,
) !void {
    try std.testing.expectEqual(expected_offsets.len, expected_kinds.len);
    const slot = b.label_slots[label.index()];
    try std.testing.expectEqual(@as(u32, @intCast(expected_offsets.len)), slot.ref_count);

    var reloc_index = slot.first_reloc;
    var previous_index = labels.no_reloc;
    for (expected_offsets, expected_kinds) |expected_offset, expected_kind| {
        try std.testing.expect(reloc_index != labels.no_reloc);
        try std.testing.expect(reloc_index < b.reloc_len);
        try std.testing.expect(reloc_index < previous_index);
        const entry = b.relocs[reloc_index];
        try std.testing.expectEqual(expected_offset, entry.operand_offset);
        try std.testing.expectEqual(expected_kind, entry.kind);
        const operand_offset: usize = @intCast(entry.operand_offset);
        try std.testing.expectEqual(
            label.index(),
            std.mem.readInt(u32, b.code[operand_offset..][0..4], .little),
        );
        previous_index = reloc_index;
        reloc_index = entry.next;
    }
    try std.testing.expectEqual(labels.no_reloc, reloc_index);
}

test "compiler_v2.builder: jump emission, bind, reloc chains" {
    var acct = core.memory.MemoryAccount.init(std.testing.allocator);
    var table = core.atom.AtomTable.init(&acct);
    defer table.deinit();

    var b = Builder.init(&acct, &table);
    defer b.deinit();

    const label = try b.newLabel();
    try b.emitJump(0x21, label);
    try std.testing.expectEqual(@as(u32, 5), b.code_len);
    try std.testing.expectEqual(@as(u8, 0x21), b.code[0]);
    try std.testing.expectEqual(label.index(), std.mem.readInt(u32, b.code[1..5], .little));
    try std.testing.expectEqual(@as(u32, 1), b.label_slots[label.index()].ref_count);
    try std.testing.expectEqual(@as(u32, 0), b.label_slots[label.index()].first_reloc);
    try std.testing.expectEqual(@as(u32, 1), b.relocs[0].operand_offset);
    try std.testing.expectEqual(labels.RelocKind.jump32, b.relocs[0].kind);
    try std.testing.expect(!b.label_slots[label.index()].flags.backward_target);

    try b.bindLabel(label);
    try std.testing.expectEqual(@as(u32, 5), b.label_slots[label.index()].bound_offset);
    try std.testing.expect(b.label_slots[label.index()].flags.bound);
    try std.testing.expectError(error.InvalidBytecode, b.bindLabel(label));

    try b.emitOp(0x01);
    try std.testing.expectEqual(@as(i64, 5), b.last_opcode_pos);
    try b.emitJump(0x21, label);
    try std.testing.expectEqual(@as(u32, 2), b.label_slots[label.index()].ref_count);
    try std.testing.expectEqual(@as(u32, 1), b.label_slots[label.index()].first_reloc);
    try std.testing.expectEqual(@as(u32, 0), b.relocs[1].next);
    try std.testing.expectEqual(labels.no_reloc, b.relocs[0].next);
    try std.testing.expect(b.label_slots[label.index()].flags.backward_target);

    try std.testing.expectError(error.InvalidBytecode, b.emitJump(0x21, @enumFromInt(99)));
}

test "compiler_v2.builder: retargetLabelRefs merges a pending identity into a bound one" {
    var acct = core.memory.MemoryAccount.init(std.testing.allocator);
    var table = core.atom.AtomTable.init(&acct);
    defer table.deinit();

    var b = Builder.init(&acct, &table);
    defer b.deinit();

    // The switch shape: two pending dispatch jumps, then a bound default body,
    // then one more pending jump behind it.
    const pending = try b.newLabel();
    const target = try b.newLabel();
    const other = try b.newLabel();
    try b.emitJump(0x21, pending); // reloc 0, operand 1  (forward)
    try b.emitJump(0x21, other); // reloc 1, operand 6  (an unrelated chain)
    try b.emitOp(0x01); // 10
    try b.bindLabel(target); // 11
    try b.emitOp(0x02); // 11
    try b.emitJump(0x21, pending); // reloc 2, operand 13 (backward once merged)
    try b.bindLabel(other);

    try std.testing.expectEqual(@as(u32, 2), b.label_slots[pending.index()].ref_count);
    try std.testing.expectEqual(@as(u32, 0), b.label_slots[target.index()].ref_count);
    try std.testing.expect(!b.label_slots[target.index()].flags.backward_target);

    try b.retargetLabelRefs(pending, target);

    // Both operands now name `target`, and only `target` holds the references.
    try std.testing.expectEqual(target.index(), std.mem.readInt(u32, b.code[1..5], .little));
    try std.testing.expectEqual(target.index(), std.mem.readInt(u32, b.code[13..17], .little));
    try std.testing.expectEqual(other.index(), std.mem.readInt(u32, b.code[6..10], .little));
    try std.testing.expectEqual(@as(u32, 2), b.label_slots[target.index()].ref_count);
    try std.testing.expectEqual(@as(u32, 0), b.label_slots[pending.index()].ref_count);
    try std.testing.expectEqual(labels.no_reloc, b.label_slots[pending.index()].first_reloc);
    // The jump at 13 sits behind the bind at 11.
    try std.testing.expect(b.label_slots[target.index()].flags.backward_target);
    // The merged identity aliases the boundary it moved into; every label a
    // function creates has to end up bound.
    try std.testing.expect(b.label_slots[pending.index()].flags.bound);
    try std.testing.expectEqual(
        b.label_slots[target.index()].bound_offset,
        b.label_slots[pending.index()].bound_offset,
    );
    // Chains stay strictly descending by reloc index, which rollback/detach
    // both depend on.
    try expectRelocChain(&b, target, &.{ 13, 1 }, &.{ .jump32, .jump32 });
    // `other`'s chain is untouched.
    try expectRelocChain(&b, other, &.{6}, &.{.jump32});

    // Fail-closed: a bound source, an unbound destination, self-merge and a
    // foreign id are all rejected.
    try std.testing.expectError(error.InvalidBytecode, b.retargetLabelRefs(pending, target));
    try std.testing.expectError(error.InvalidBytecode, b.retargetLabelRefs(target, target));
    const unbound_dest = try b.newLabel();
    const fresh = try b.newLabel();
    try std.testing.expectError(error.InvalidBytecode, b.retargetLabelRefs(fresh, unbound_dest));
    try std.testing.expectError(
        error.InvalidBytecode,
        b.retargetLabelRefs(fresh, @as(LabelId, @enumFromInt(99))),
    );
}

test "compiler_v2.builder: s2g4 scope ref owns atom and chains aux relocation" {
    var acct = core.memory.MemoryAccount.init(std.testing.allocator);
    var table = core.atom.AtomTable.init(&acct);
    defer table.deinit();

    const atom_id = try table.internString("qcp1_s2g4_scope_ref");
    defer table.free(atom_id);
    const base_ref_count = table.refCount(atom_id).?;

    var b = Builder.init(&acct, &table);
    defer b.deinit();

    const label = try b.newLabel();
    try b.emitJump(0x21, label);
    const snap = b.snapshot();

    try b.emitScopeRefOpOwned(0xd1, table.dup(atom_id), label, 0x1234);
    try std.testing.expectEqual(@as(u32, 16), b.code_len);
    try std.testing.expectEqual(@as(i64, 5), b.last_opcode_pos);
    try std.testing.expectEqual(@as(u8, 0xd1), b.code[5]);
    try std.testing.expectEqual(atom_id, std.mem.readInt(u32, b.code[6..10], .little));
    try std.testing.expectEqual(label.index(), std.mem.readInt(u32, b.code[10..14], .little));
    try std.testing.expectEqual(@as(u16, 0x1234), std.mem.readInt(u16, b.code[14..16], .little));
    try std.testing.expectEqual(@as(u32, 2), b.reloc_len);
    try std.testing.expectEqual(@as(u32, 2), b.label_slots[label.index()].ref_count);
    try std.testing.expectEqual(@as(u32, 1), b.label_slots[label.index()].first_reloc);
    try std.testing.expectEqual(@as(u32, 0), b.relocs[1].next);
    try std.testing.expectEqual(@as(u32, 10), b.relocs[1].operand_offset);
    try std.testing.expectEqual(labels.RelocKind.aux32, b.relocs[1].kind);
    try std.testing.expect(!b.label_slots[label.index()].flags.backward_target);

    try b.bindLabel(label);
    try b.emitScopeRefOpOwned(0xd2, table.dup(atom_id), label, 0xabcd);
    try std.testing.expectEqual(@as(u32, 27), b.code_len);
    try std.testing.expectEqual(@as(i64, 16), b.last_opcode_pos);
    try std.testing.expectEqual(@as(u32, 3), b.reloc_len);
    try std.testing.expectEqual(@as(u32, 3), b.label_slots[label.index()].ref_count);
    try std.testing.expectEqual(@as(u32, 2), b.label_slots[label.index()].first_reloc);
    try std.testing.expectEqual(@as(u32, 1), b.relocs[2].next);
    try std.testing.expectEqual(@as(u32, 21), b.relocs[2].operand_offset);
    try std.testing.expectEqual(labels.RelocKind.aux32, b.relocs[2].kind);
    try std.testing.expect(b.label_slots[label.index()].flags.backward_target);
    try std.testing.expectEqual(base_ref_count + 2, table.refCount(atom_id).?);

    b.rollback(snap);
    try std.testing.expectEqual(snap.code_len, b.code_len);
    try std.testing.expectEqual(snap.atom_len, b.atom_len);
    try std.testing.expectEqual(snap.reloc_len, b.reloc_len);
    try std.testing.expectEqual(@as(u32, 1), b.label_slots[label.index()].ref_count);
    try std.testing.expectEqual(@as(u32, 0), b.label_slots[label.index()].first_reloc);
    try std.testing.expect(!b.label_slots[label.index()].flags.bound);
    try std.testing.expectEqual(base_ref_count, table.refCount(atom_id).?);

    const code_len_before_invalid = b.code_len;
    const reloc_len_before_invalid = b.reloc_len;
    const invalid_owned_atom = table.dup(atom_id);
    try std.testing.expectEqual(base_ref_count + 1, table.refCount(atom_id).?);
    try std.testing.expectError(
        error.InvalidBytecode,
        b.emitScopeRefOpOwned(0xd3, invalid_owned_atom, @enumFromInt(99), 0),
    );
    try std.testing.expectEqual(code_len_before_invalid, b.code_len);
    try std.testing.expectEqual(reloc_len_before_invalid, b.reloc_len);
    try std.testing.expectEqual(base_ref_count, table.refCount(atom_id).?);
}

test "compiler_v2.builder: compact immediate emission and rollback" {
    var acct = core.memory.MemoryAccount.init(std.testing.allocator);
    var table = core.atom.AtomTable.init(&acct);
    defer table.deinit();

    var b = Builder.init(&acct, &table);
    defer b.deinit();

    const empty = b.snapshot();

    try b.emitOpU8(0xa1, 0x7f);
    try std.testing.expectEqual(@as(u32, 2), b.code_len);
    try std.testing.expectEqual(@as(i64, 0), b.last_opcode_pos);
    try std.testing.expectEqualSlices(u8, &.{ 0xa1, 0x7f }, b.code[0..2]);
    b.rollback(empty);
    try std.testing.expectEqual(empty.code_len, b.code_len);
    try std.testing.expectEqual(empty.last_opcode_pos, b.last_opcode_pos);

    try b.emitOpU16(0xb2, 0x1234);
    try std.testing.expectEqual(@as(u32, 3), b.code_len);
    try std.testing.expectEqual(@as(i64, 0), b.last_opcode_pos);
    try std.testing.expectEqualSlices(u8, &.{ 0xb2, 0x34, 0x12 }, b.code[0..3]);
    b.rollback(empty);
    try std.testing.expectEqual(empty.code_len, b.code_len);
    try std.testing.expectEqual(empty.last_opcode_pos, b.last_opcode_pos);

    try b.emitOpI32(0xc3, -2);
    try std.testing.expectEqual(@as(u32, 5), b.code_len);
    try std.testing.expectEqual(@as(i64, 0), b.last_opcode_pos);
    try std.testing.expectEqualSlices(u8, &.{ 0xc3, 0xfe, 0xff, 0xff, 0xff }, b.code[0..5]);
    b.rollback(empty);
    try std.testing.expectEqual(empty.code_len, b.code_len);
    try std.testing.expectEqual(empty.last_opcode_pos, b.last_opcode_pos);
}

test "compiler_v2.builder: s2g4 compact atom immediates own refs" {
    var acct = core.memory.MemoryAccount.init(std.testing.allocator);
    var table = core.atom.AtomTable.init(&acct);
    defer table.deinit();

    const atom_id = try table.internString("qcp1_s2g4_compact_atom");
    defer table.free(atom_id);
    const base_ref_count = table.refCount(atom_id).?;

    var b = Builder.init(&acct, &table);
    defer b.deinit();

    const empty = b.snapshot();
    try b.emitOpU32(0xc1, 0x78563412);
    try std.testing.expectEqual(@as(u32, 5), b.code_len);
    try std.testing.expectEqual(@as(i64, 0), b.last_opcode_pos);
    try std.testing.expectEqualSlices(u8, &.{ 0xc1, 0x12, 0x34, 0x56, 0x78 }, b.code[0..5]);

    try b.emitAtomOpU8Owned(0xc2, table.dup(atom_id), 0xa5);
    try std.testing.expectEqual(@as(u32, 11), b.code_len);
    try std.testing.expectEqual(@as(i64, 5), b.last_opcode_pos);
    try std.testing.expectEqual(@as(u8, 0xc2), b.code[5]);
    try std.testing.expectEqual(atom_id, std.mem.readInt(u32, b.code[6..10], .little));
    try std.testing.expectEqual(@as(u8, 0xa5), b.code[10]);

    try b.emitAtomOpU16Owned(0xc3, table.dup(atom_id), 0x1234);
    try std.testing.expectEqual(@as(u32, 18), b.code_len);
    try std.testing.expectEqual(@as(i64, 11), b.last_opcode_pos);
    try std.testing.expectEqual(@as(u8, 0xc3), b.code[11]);
    try std.testing.expectEqual(atom_id, std.mem.readInt(u32, b.code[12..16], .little));
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12 }, b.code[16..18]);
    try std.testing.expectEqual(@as(u32, 2), b.atom_len);
    try std.testing.expectEqual(atom_id, b.atom_operands[0]);
    try std.testing.expectEqual(atom_id, b.atom_operands[1]);
    try std.testing.expectEqual(base_ref_count + 2, table.refCount(atom_id).?);

    b.rollback(empty);
    try std.testing.expectEqual(@as(u32, 0), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.atom_len);
    try std.testing.expectEqual(base_ref_count, table.refCount(atom_id).?);

    try b.emitAtomOpU8Owned(0xc4, table.dup(atom_id), 0x5a);
    try b.emitAtomOpU16Owned(0xc5, table.dup(atom_id), 0xabcd);
    b.deinit();
    try std.testing.expectEqual(base_ref_count, table.refCount(atom_id).?);
}

test "compiler_v2.builder: s2g4 take atom and truncate speculative tail" {
    var acct = core.memory.MemoryAccount.init(std.testing.allocator);
    var table = core.atom.AtomTable.init(&acct);
    defer table.deinit();

    const atom_id = try table.internString("qcp1_s2g4_truncate_atom");
    defer table.free(atom_id);
    const base_ref_count = table.refCount(atom_id).?;

    var b = Builder.init(&acct, &table);
    defer b.deinit();

    try b.addSourceMarker(1, 1);
    const label = try b.newLabel();
    try b.bindLabel(label);
    try b.emitJump(0x21, label);
    const op_start = b.code_len;
    try std.testing.expectEqual(@as(u32, 5), op_start);
    try b.addSourceMarker(2, 2);
    try b.emitAtomOpOwned(0xd4, table.dup(atom_id));
    try b.addSourceMarker(3, 3);
    try std.testing.expectEqual(@as(u32, 3), b.source_len);
    try std.testing.expectEqual(op_start, b.source_slots[1].temp_offset);
    try std.testing.expectEqual(@as(u32, 10), b.source_slots[2].temp_offset);
    try std.testing.expectEqual(base_ref_count + 1, table.refCount(atom_id).?);

    const returned_atom = try b.takeLastAtomOwned();
    try std.testing.expectEqual(atom_id, returned_atom);
    try std.testing.expectEqual(@as(u32, 0), b.atom_len);
    try std.testing.expectEqual(base_ref_count + 1, table.refCount(atom_id).?);
    try std.testing.expectError(error.InvalidBytecode, b.takeLastAtomOwned());

    b.truncateTail(op_start);
    try std.testing.expectEqual(op_start, b.code_len);
    try std.testing.expectEqual(@as(u32, 1), b.reloc_len);
    try std.testing.expectEqual(@as(u32, 1), b.label_slots[label.index()].ref_count);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try std.testing.expectEqual(@as(u32, 1), b.source_len);
    try std.testing.expectEqual(@as(u32, 0), b.source_slots[0].temp_offset);

    table.free(returned_atom);
    try std.testing.expectEqual(base_ref_count, table.refCount(atom_id).?);
}

test "compiler_v2.builder: marked opcode rewind preserves older same-offset source" {
    var acct = core.memory.MemoryAccount.init(std.testing.allocator);
    var table = core.atom.AtomTable.init(&acct);
    defer table.deinit();

    var b = Builder.init(&acct, &table);
    defer b.deinit();

    try b.addSourceMarker(1, 10);
    try b.addSourceMarker(1, 20);
    try b.emitOp(0xd4);
    try std.testing.expectEqual(@as(u32, 2), b.source_len);

    try b.truncateLastMarkedOpcode(0);
    try std.testing.expectEqual(@as(u32, 0), b.code_len);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try std.testing.expectEqual(@as(u32, 1), b.source_len);
    try std.testing.expectEqual(@as(u32, 0), b.source_slots[0].temp_offset);
    try std.testing.expectEqual(@as(i32, 1), b.source_slots[0].line);
    try std.testing.expectEqual(@as(i32, 10), b.source_slots[0].col);
}

test "compiler_v2.builder: s2g4 detach and splice preserves global labels" {
    var acct = core.memory.MemoryAccount.init(std.testing.allocator);
    var table = core.atom.AtomTable.init(&acct);
    defer table.deinit();

    const pre_atom = try table.internString("qcp1_s2g4_pre_atom");
    defer table.free(pre_atom);
    const segment_atom = try table.internString("qcp1_s2g4_segment_atom");
    defer table.free(segment_atom);
    const scope_atom = try table.internString("qcp1_s2g4_scope_atom");
    defer table.free(scope_atom);
    const pre_atom_base = table.refCount(pre_atom).?;
    const segment_atom_base = table.refCount(segment_atom).?;
    const scope_atom_base = table.refCount(scope_atom).?;

    var b = Builder.init(&acct, &table);
    defer b.deinit();

    const label_a = try b.newLabel();
    const label_c = try b.newLabel();
    try b.bindLabel(label_a);
    try b.emitJump(0xe0, label_a);
    try b.emitAtomOpOwned(0xe1, table.dup(pre_atom));
    try b.addSourceMarker(10, 10);
    try b.bindLabel(label_c);
    const mark = b.snapshot();
    try std.testing.expectEqual(@as(u32, 10), mark.code_len);

    try b.emitJump(0xe2, label_a);
    const label_b = try b.newLabel();
    try b.emitJump(0xe3, label_b);
    try b.emitOp(0xe4);
    try b.bindLabel(label_b);
    try b.emitAtomOpOwned(0xe5, table.dup(segment_atom));
    try b.addSourceMarker(20, 20);
    try b.emitScopeRefOpOwned(0xe6, table.dup(scope_atom), label_c, 0x5678);

    try std.testing.expectEqual(@as(u32, 37), b.code_len);
    try std.testing.expectEqual(@as(u32, 3), b.atom_len);
    try std.testing.expectEqual(@as(u32, 4), b.reloc_len);
    try std.testing.expectEqual(@as(u32, 3), b.label_len);
    try std.testing.expectEqual(@as(u32, 2), b.source_len);
    try expectRelocChain(&b, label_a, &.{ 11, 1 }, &.{ .jump32, .jump32 });
    try expectRelocChain(&b, label_b, &.{16}, &.{.jump32});
    try expectRelocChain(&b, label_c, &.{31}, &.{.aux32});
    try std.testing.expectEqual(segment_atom_base + 1, table.refCount(segment_atom).?);
    try std.testing.expectEqual(scope_atom_base + 1, table.refCount(scope_atom).?);

    var seg = try b.detachTail(mark);
    defer b.discardSegment(&seg);
    try std.testing.expectEqual(mark.code_len, b.code_len);
    try std.testing.expectEqual(mark.atom_len, b.atom_len);
    try std.testing.expectEqual(mark.reloc_len, b.reloc_len);
    try std.testing.expectEqual(mark.source_len, b.source_len);
    try std.testing.expectEqual(@as(u32, 3), b.label_len);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectRelocChain(&b, label_a, &.{1}, &.{.jump32});
    try expectRelocChain(&b, label_b, &.{}, &.{});
    try expectRelocChain(&b, label_c, &.{}, &.{});
    try std.testing.expect(!b.label_slots[label_b.index()].flags.bound);
    try std.testing.expectEqual(labels.unbound, b.label_slots[label_b.index()].bound_offset);
    try std.testing.expect(b.label_slots[label_c.index()].flags.bound);
    try std.testing.expectEqual(mark.code_len, b.label_slots[label_c.index()].bound_offset);

    try std.testing.expectEqual(@as(usize, 27), seg.code.len);
    try std.testing.expectEqual(@as(usize, 2), seg.atoms.len);
    try std.testing.expectEqual(segment_atom, seg.atoms[0]);
    try std.testing.expectEqual(scope_atom, seg.atoms[1]);
    try std.testing.expectEqual(@as(usize, 3), seg.relocs.len);
    try std.testing.expectEqual(@as(u32, 1), seg.relocs[0].operand_offset);
    try std.testing.expectEqual(labels.RelocKind.jump32, seg.relocs[0].kind);
    try std.testing.expectEqual(@as(u32, 6), seg.relocs[1].operand_offset);
    try std.testing.expectEqual(labels.RelocKind.jump32, seg.relocs[1].kind);
    try std.testing.expectEqual(@as(u32, 21), seg.relocs[2].operand_offset);
    try std.testing.expectEqual(labels.RelocKind.aux32, seg.relocs[2].kind);
    try std.testing.expectEqual(@as(usize, 1), seg.binds.len);
    try std.testing.expectEqual(label_b.index(), seg.binds[0].label_index);
    try std.testing.expectEqual(@as(u32, 11), seg.binds[0].rel_offset);
    try std.testing.expectEqual(@as(usize, 1), seg.sources.len);
    try std.testing.expectEqual(@as(u32, 16), seg.sources[0].temp_offset);
    try std.testing.expectEqual(segment_atom_base + 1, table.refCount(segment_atom).?);
    try std.testing.expectEqual(scope_atom_base + 1, table.refCount(scope_atom).?);

    var detached_bytes: [27]u8 = undefined;
    @memcpy(detached_bytes[0..], seg.code);
    try b.emitOp(0xef);
    try b.addSourceMarker(30, 30);
    const new_base = b.code_len;
    try std.testing.expectEqual(@as(u32, 11), new_base);

    try b.spliceSegment(&seg);
    try std.testing.expectEqual(@as(u32, 38), b.code_len);
    try std.testing.expectEqualSlices(u8, &detached_bytes, b.code[new_base..b.code_len]);
    try std.testing.expectEqual(@as(u32, 3), b.atom_len);
    try std.testing.expectEqual(pre_atom, b.atom_operands[0]);
    try std.testing.expectEqual(segment_atom, b.atom_operands[1]);
    try std.testing.expectEqual(scope_atom, b.atom_operands[2]);
    try std.testing.expectEqual(@as(u32, 4), b.reloc_len);
    try std.testing.expectEqual(@as(u32, 3), b.label_len);
    try std.testing.expect(b.label_slots[label_b.index()].flags.bound);
    try std.testing.expectEqual(new_base + 11, b.label_slots[label_b.index()].bound_offset);
    try expectRelocChain(&b, label_a, &.{ 12, 1 }, &.{ .jump32, .jump32 });
    try expectRelocChain(&b, label_b, &.{17}, &.{.jump32});
    try expectRelocChain(&b, label_c, &.{32}, &.{.aux32});
    try std.testing.expectEqual(label_a.index(), std.mem.readInt(u32, b.code[12..16], .little));
    try std.testing.expectEqual(label_b.index(), std.mem.readInt(u32, b.code[17..21], .little));
    try std.testing.expectEqual(label_c.index(), std.mem.readInt(u32, b.code[32..36], .little));
    try std.testing.expect(b.label_slots[label_a.index()].flags.backward_target);
    try std.testing.expect(!b.label_slots[label_b.index()].flags.backward_target);
    try std.testing.expect(b.label_slots[label_c.index()].flags.backward_target);
    try std.testing.expectEqual(@as(u32, 3), b.source_len);
    try std.testing.expectEqual(@as(u32, 10), b.source_slots[0].temp_offset);
    try std.testing.expectEqual(@as(u32, 11), b.source_slots[1].temp_offset);
    try std.testing.expectEqual(@as(u32, 27), b.source_slots[2].temp_offset);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try std.testing.expectEqual(@as(usize, 0), seg.code.len);
    try std.testing.expectEqual(@as(usize, 0), seg.atoms.len);
    try std.testing.expectEqual(@as(usize, 0), seg.relocs.len);
    try std.testing.expectEqual(@as(usize, 0), seg.binds.len);
    try std.testing.expectEqual(@as(usize, 0), seg.sources.len);

    b.discardSegment(&seg);
    b.deinit();
    try std.testing.expectEqual(pre_atom_base, table.refCount(pre_atom).?);
    try std.testing.expectEqual(segment_atom_base, table.refCount(segment_atom).?);
    try std.testing.expectEqual(scope_atom_base, table.refCount(scope_atom).?);
}

test "compiler_v2.builder: s2g4 empty segment splice invalidates last opcode" {
    var acct = core.memory.MemoryAccount.init(std.testing.allocator);
    var table = core.atom.AtomTable.init(&acct);
    defer table.deinit();

    var b = Builder.init(&acct, &table);
    defer b.deinit();

    try b.emitOp(0xf0);
    const mark = b.snapshot();
    var seg = try b.detachTail(mark);
    defer b.discardSegment(&seg);
    try std.testing.expectEqual(mark.code_len, b.code_len);
    try std.testing.expectEqual(mark.atom_len, b.atom_len);
    try std.testing.expectEqual(mark.reloc_len, b.reloc_len);
    try std.testing.expectEqual(mark.source_len, b.source_len);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try std.testing.expectEqual(@as(usize, 0), seg.code.len);
    try std.testing.expectEqual(@as(usize, 0), seg.atoms.len);
    try std.testing.expectEqual(@as(usize, 0), seg.relocs.len);
    try std.testing.expectEqual(@as(usize, 0), seg.binds.len);
    try std.testing.expectEqual(@as(usize, 0), seg.sources.len);

    try b.emitOp(0xf1);
    try std.testing.expectEqual(@as(i64, 1), b.last_opcode_pos);
    try b.spliceSegment(&seg);
    try std.testing.expectEqual(@as(u32, 2), b.code_len);
    try std.testing.expectEqualSlices(u8, &.{ 0xf0, 0xf1 }, b.code[0..2]);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);

    b.discardSegment(&seg);
    b.discardSegment(&seg);
}

fn s2g4OomScript(allocator: std.mem.Allocator) !void {
    var acct = core.memory.MemoryAccount.init(allocator);
    var table = core.atom.AtomTable.init(&acct);
    defer table.deinit();

    const atom_id = try table.internString("qcp1_s2g4_oom_atom");
    defer table.free(atom_id);
    const base_ref_count = table.refCount(atom_id).?;

    var b = Builder.init(&acct, &table);
    defer b.deinit();

    const label_c = try b.newLabel();
    try b.bindLabel(label_c);
    try b.emitOpU32(0x70, 0x12345678);
    try b.emitAtomOpU8Owned(0x71, table.dup(atom_id), 0x9a);
    try b.emitAtomOpU16Owned(0x72, table.dup(atom_id), 0xbcde);
    const mark = b.snapshot();

    const label_b = try b.newLabel();
    try b.emitJump(0x80, label_b);
    var jump_index: u8 = 0;
    while (jump_index < 6) : (jump_index += 1) {
        try b.emitJump(0x81 + jump_index, label_c);
    }
    try b.emitScopeRefOpOwned(0x90, table.dup(atom_id), label_c, 0x2468);
    var atom_index: u8 = 0;
    while (atom_index < 5) : (atom_index += 1) {
        try b.emitAtomOpOwned(0xa0 + atom_index, table.dup(atom_id));
    }
    try b.bindLabel(label_b);
    var marker_index: i32 = 0;
    while (marker_index < 8) : (marker_index += 1) {
        try b.addSourceMarker(100 + marker_index, 1);
    }

    try std.testing.expectEqual(@as(u32, 89), b.code_len);
    try std.testing.expectEqual(@as(u32, 8), b.atom_len);
    try std.testing.expectEqual(@as(u32, 8), b.reloc_len);
    try std.testing.expectEqual(@as(u32, 8), b.source_len);

    var seg: DetachedSegment = .{};
    defer b.discardSegment(&seg);
    seg = try b.detachTail(mark);
    try std.testing.expectEqual(@as(usize, 71), seg.code.len);
    try std.testing.expectEqual(@as(usize, 6), seg.atoms.len);
    try std.testing.expectEqual(@as(usize, 8), seg.relocs.len);
    try std.testing.expectEqual(@as(usize, 1), seg.binds.len);
    try std.testing.expectEqual(@as(usize, 8), seg.sources.len);

    var interim_index: u8 = 0;
    while (interim_index < 40) : (interim_index += 1) {
        try b.emitOp(0xc0 + interim_index);
    }
    try b.emitJump(0xe8, label_c);
    try b.emitAtomOpOwned(0xe9, table.dup(atom_id));
    try b.addSourceMarker(200, 1);

    try b.spliceSegment(&seg);
    try std.testing.expectEqual(@as(u32, 139), b.code_len);
    try std.testing.expectEqual(@as(u32, 9), b.atom_len);
    try std.testing.expectEqual(@as(u32, 9), b.reloc_len);
    try std.testing.expectEqual(@as(u32, 9), b.source_len);
    try std.testing.expect(b.label_slots[label_b.index()].flags.bound);
    try std.testing.expectEqual(@as(usize, 0), seg.code.len);

    b.deinit();
    try std.testing.expectEqual(base_ref_count, table.refCount(atom_id).?);
}

test "compiler_v2.builder: s2g4 allocation failure sweep balances detached atoms" {
    try s2g4OomScript(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, s2g4OomScript, .{});
}

test "compiler_v2.builder: snapshot rollback restores chains, atoms, markers" {
    var acct = core.memory.MemoryAccount.init(std.testing.allocator);
    var table = core.atom.AtomTable.init(&acct);
    defer table.deinit();

    var b = Builder.init(&acct, &table);
    defer b.deinit();

    const l0 = try b.newLabel();
    try b.emitJump(0x21, l0);
    const atom_id = try table.internString("qcp1a_smoke");
    defer table.free(atom_id);
    try b.emitAtomOpOwned(0x30, table.dup(atom_id));
    try b.addSourceMarker(1, 1);
    const snap = b.snapshot();

    try b.emitJump(0x21, l0);
    try b.emitJump(0x21, l0);
    const l1 = try b.newLabel();
    try b.emitJump(0x22, l1);
    try b.bindLabel(l1);
    try b.bindLabel(l0);
    const ref_count_before_post_atom = table.refCount(atom_id);
    try b.emitAtomOpOwned(0x30, table.dup(atom_id));
    try b.addSourceMarker(2, 2);
    b.invalidateLastOpcode();

    b.rollback(snap);
    try std.testing.expectEqual(snap.code_len, b.code_len);
    try std.testing.expectEqual(snap.atom_len, b.atom_len);
    try std.testing.expectEqual(snap.label_len, b.label_len);
    try std.testing.expectEqual(snap.reloc_len, b.reloc_len);
    try std.testing.expectEqual(snap.source_len, b.source_len);
    try std.testing.expectEqual(@as(u32, 1), b.label_slots[l0.index()].ref_count);
    try std.testing.expectEqual(@as(u32, 0), b.label_slots[l0.index()].first_reloc);
    try std.testing.expect(!b.label_slots[l0.index()].flags.bound);
    try std.testing.expectEqual(labels.unbound, b.label_slots[l0.index()].bound_offset);
    try std.testing.expectEqual(snap.last_opcode_pos, b.last_opcode_pos);
    try std.testing.expectEqual(ref_count_before_post_atom, table.refCount(atom_id));

    try b.emitJump(0x21, l0);
    b.deinit();
    b.deinit();
}
