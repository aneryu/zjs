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
const builtin = @import("builtin");
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

    /// Control-flow merge: forget the last opcode so no peephole fuses across
    /// the join (qjs sets fd->last_opcode_pos = -1 at labels).
    pub fn invalidateLastOpcode(self: *Builder) void {
        self.last_opcode_pos = -1;
    }

    fn reserveCode(self: *Builder, need: usize) Error!void {
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
