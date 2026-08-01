//! QCP-1 compiler-v2 Stage 3: identity-native variable resolution with exact
//! block-CFG liveness.
//!
//! Pass A builds one immutable LabelId CFG from the read-only Builder, then
//! establishes the transactional output, short-form label bookkeeping, atom
//! ownership, source carry, and the simple QuickJS rewrites. Pass B keeps that
//! pass structure while delegating every binding decision and lowering writer
//! to the legacy resolver's curated reuse surface.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/root.zig");
const bytecode = @import("../bytecode.zig");
const builder = @import("builder.zig");
const cfg = @import("cfg.zig");
const labels = @import("labels.zig");

const opcode = bytecode.opcode;
const op = opcode.op;
const legacy_pipeline = bytecode.pipeline_resolve_variables;
const legacy = legacy_pipeline.v2;

pub const Error = error{
    OutOfMemory,
    InvalidBytecode,
    BytecodeOverflow,
    NoFunctionDef,
    NoParentScope,
    ClosureVarNotFound,
};

/// Output of the exact-CFG resolve pass (qjs shape: a fresh growable output
/// buffer, quickjs.c resolve_variables bc_out, plus the function's label
/// slots updated to output offsets as labels are passed).
pub const ResolvedProduct = struct {
    memory: *core.memory.MemoryAccount,
    atoms: *core.atom.AtomTable,
    code: []u8 = &.{},
    code_capacity: usize = 0,
    code_len: u32 = 0,
    /// Owned (retained) atoms, lockstep with atom-bearing opcodes of code.
    atom_operands: []core.atom.Atom = &.{},
    atom_capacity: usize = 0,
    atom_len: u32 = 0,
    /// Same label indices as the input builder (Pass B may append new ones).
    /// bound_offset = OUTPUT offset for labels passed in live code (qjs
    /// LabelSlot.pos2), labels.unbound for labels inside removed dead
    /// regions; ref_count = retained-reference count after qjs update_label
    /// bookkeeping for Stage 4 short-form selection;
    /// first_reloc is always labels.no_reloc here (resolve_labels_v2 builds
    /// its own chains next stage); flags.backward_target carried from input.
    label_slots: []labels.LabelSlot = &.{},
    label_capacity: usize = 0,
    label_len: u32 = 0,
    /// Source markers carried to OUTPUT offsets.
    source_slots: []builder.SourceSlot = &.{},
    source_capacity: usize = 0,
    source_len: u32 = 0,
    /// qjs s->jump_size analog counted by this pass.
    jump_size: u32 = 0,

    /// Item-wise release of the owned atom prefix, then free each backing by
    /// full capacity. Idempotent. Mirrors Builder.deinit discipline.
    pub fn deinitUncommitted(self: *ResolvedProduct) void {
        for (self.atom_operands[0..self.atom_len]) |atom_id| self.atoms.free(atom_id);

        if (self.code_capacity != 0) self.memory.free(u8, self.code);
        if (self.atom_capacity != 0) self.memory.free(core.atom.Atom, self.atom_operands);
        if (self.label_capacity != 0) self.memory.free(labels.LabelSlot, self.label_slots);
        if (self.source_capacity != 0) self.memory.free(builder.SourceSlot, self.source_slots);

        self.code = &.{};
        self.code_capacity = 0;
        self.code_len = 0;
        self.atom_operands = &.{};
        self.atom_capacity = 0;
        self.atom_len = 0;
        self.label_slots = &.{};
        self.label_capacity = 0;
        self.label_len = 0;
        self.source_slots = &.{};
        self.source_capacity = 0;
        self.source_len = 0;
        self.jump_size = 0;
    }
};

fn reserve(
    comptime T: type,
    memory: *core.memory.MemoryAccount,
    slice: *[]T,
    capacity: *usize,
    used: u32,
    need: usize,
    comptime min_capacity: usize,
) Error!void {
    const required = std.math.add(usize, @as(usize, used), need) catch
        return error.OutOfMemory;
    if (required <= capacity.*) return;

    const doubled = std.math.mul(usize, capacity.*, 2) catch std.math.maxInt(usize);
    const new_capacity = @max(@max(required, doubled), min_capacity);
    const new_backing = memory.alloc(T, new_capacity) catch return error.OutOfMemory;
    @memcpy(new_backing[0..used], slice.*[0..used]);

    const old_backing = slice.*;
    const old_capacity = capacity.*;
    slice.* = new_backing;
    capacity.* = new_capacity;
    if (old_capacity != 0) memory.free(T, old_backing);
}

const TempInstruction = cfg.TempInstruction;
const tempInstruction = cfg.tempInstruction;
const BindEntry = cfg.BindEntry;

fn updateLabel(product: *ResolvedProduct, label_index: u32, delta: i32) Error!u32 {
    if (label_index >= product.label_len) return error.InvalidBytecode;
    std.debug.assert(label_index < product.label_len);
    const slot = &product.label_slots[label_index];

    if (delta < 0) {
        const amount: u32 = @intCast(-@as(i64, delta));
        if (slot.ref_count < amount) return error.InvalidBytecode;
        std.debug.assert(slot.ref_count >= amount);
        slot.ref_count -= amount;
    } else if (delta > 0) {
        const amount: u32 = @intCast(delta);
        slot.ref_count = std.math.add(u32, slot.ref_count, amount) catch
            return error.InvalidBytecode;
    }
    std.debug.assert(@as(i64, slot.ref_count) >= 0);
    return slot.ref_count;
}

const SourcePoint = struct {
    line: i32,
    col: i32,
};

const PendingTailRewrite = struct {
    input_offset: u32,
    emit_dup: bool,
    put_action: legacy.ScopeVarActionAlias,
    consumed: bool = false,
};

const MakeRefFold = struct {
    tail_offset: u32,
    emit_dup: bool,
    reads_value: bool,
    get_action: legacy.ScopeVarActionAlias,
    put_action: legacy.ScopeVarActionAlias,
};

fn sourcePointEqual(lhs: SourcePoint, rhs: SourcePoint) bool {
    return lhs.line == rhs.line and lhs.col == rhs.col;
}

const Resolver = struct {
    ctx: *legacy_pipeline.JSContext,
    input: *const builder.Builder,
    code: []const u8,
    atom_ledger: []const core.atom.Atom,
    input_sources: []const builder.SourceSlot,
    product: *ResolvedProduct,
    binds: []BindEntry,
    graph: *const cfg.Graph,

    pending_tail_rewrites: []PendingTailRewrite = &.{},
    pending_tail_capacity: usize = 0,
    pending_tail_len: u32 = 0,

    bind_cursor: usize = 0,
    block_cursor: usize = 0,
    atom_index: u32 = 0,
    source_cursor: u32 = 0,
    pending_source: ?SourcePoint = null,
    last_attached_source: ?SourcePoint = null,

    fn deinitScratch(self: *Resolver) void {
        if (self.pending_tail_capacity != 0) {
            self.product.memory.free(PendingTailRewrite, self.pending_tail_rewrites);
        }
        self.pending_tail_rewrites = &.{};
        self.pending_tail_capacity = 0;
        self.pending_tail_len = 0;
    }

    fn prepareLegacyWrite(
        self: *Resolver,
        code_need: usize,
        atom_need: usize,
    ) Error!void {
        if (code_need == 0) {
            if (atom_need != 0) return error.InvalidBytecode;
            return;
        }
        if (code_need > std.math.maxInt(u32) or atom_need > std.math.maxInt(u32))
            return error.BytecodeOverflow;
        _ = std.math.add(u32, self.product.code_len, @as(u32, @intCast(code_need))) catch
            return error.BytecodeOverflow;
        _ = std.math.add(u32, self.product.atom_len, @as(u32, @intCast(atom_need))) catch
            return error.BytecodeOverflow;

        const attach_source = self.shouldAttachSource();
        if (attach_source and self.product.source_len == std.math.maxInt(u32))
            return error.BytecodeOverflow;

        try reserve(
            u8,
            self.product.memory,
            &self.product.code,
            &self.product.code_capacity,
            self.product.code_len,
            code_need,
            16,
        );
        if (atom_need != 0) {
            try reserve(
                core.atom.Atom,
                self.product.memory,
                &self.product.atom_operands,
                &self.product.atom_capacity,
                self.product.atom_len,
                atom_need,
                8,
            );
        }
        if (attach_source) {
            try reserve(
                builder.SourceSlot,
                self.product.memory,
                &self.product.source_slots,
                &self.product.source_capacity,
                self.product.source_len,
                1,
                8,
            );
            const source = self.pending_source.?;
            self.product.source_slots[self.product.source_len] = .{
                .temp_offset = self.product.code_len,
                .line = source.line,
                .col = source.col,
            };
            self.product.source_len += 1;
            self.last_attached_source = source;
        }
    }

    fn finishLegacyWrite(
        self: *Resolver,
        code_used: usize,
        atom_used: usize,
    ) void {
        std.debug.assert(code_used <= std.math.maxInt(u32));
        std.debug.assert(atom_used <= std.math.maxInt(u32));
        self.product.code_len += @intCast(code_used);
        self.product.atom_len += @intCast(atom_used);
    }

    fn newProductLabel(self: *Resolver) Error!u32 {
        if (self.product.label_len == std.math.maxInt(u32))
            return error.BytecodeOverflow;
        try reserve(
            labels.LabelSlot,
            self.product.memory,
            &self.product.label_slots,
            &self.product.label_capacity,
            self.product.label_len,
            1,
            8,
        );
        const label_index = self.product.label_len;
        self.product.label_slots[label_index] = .{};
        self.product.label_len += 1;
        return label_index;
    }

    fn bindProductLabel(self: *Resolver, label_index: u32) Error!void {
        if (label_index >= self.product.label_len) return error.InvalidBytecode;
        const slot = &self.product.label_slots[label_index];
        if (slot.flags.bound or slot.bound_offset != labels.unbound)
            return error.InvalidBytecode;
        slot.bound_offset = self.product.code_len;
        slot.flags.bound = true;
    }

    fn writeScopeVarAction(
        self: *Resolver,
        atom_id: core.atom.Atom,
        action: legacy.ScopeVarActionAlias,
    ) Error!void {
        const code_need = legacy.scopeVarActionSize(action);
        const atom_need = legacy.scopeVarActionAtomCount(action);
        try self.prepareLegacyWrite(code_need, atom_need);
        const code_start: usize = @intCast(self.product.code_len);
        const atom_start: usize = @intCast(self.product.atom_len);
        var out_idx: usize = 0;
        var out_atom_idx: usize = 0;
        defer self.finishLegacyWrite(out_idx, out_atom_idx);
        try legacy.writeScopeVarAction(
            self.ctx.function,
            self.product.code[code_start..][0..code_need],
            &out_idx,
            self.product.atom_operands[atom_start..][0..atom_need],
            &out_atom_idx,
            atom_id,
            action,
        );
        if (out_idx != code_need or out_atom_idx != atom_need)
            return error.InvalidBytecode;
    }

    fn emitDynamicEnvProbe(
        self: *Resolver,
        atom_id: core.atom.Atom,
        probe: legacy.EvalVarObjectProbeAlias,
        probe_op: u8,
        label_done: u32,
    ) Error!void {
        const accessor_size = legacy.evalVarObjectProbeAccessorSize(self.ctx, probe);
        const probe_size = opcode.sizeOf(probe_op);
        if (probe_size != 10) return error.InvalidBytecode;
        const code_need = std.math.add(usize, accessor_size, probe_size) catch
            return error.BytecodeOverflow;
        try self.prepareLegacyWrite(code_need, 1);
        const code_start: usize = @intCast(self.product.code_len);
        const atom_start: usize = @intCast(self.product.atom_len);
        var out_idx: usize = 0;
        var out_atom_idx: usize = 0;
        defer self.finishLegacyWrite(out_idx, out_atom_idx);

        const output = self.product.code[code_start..][0..code_need];
        try legacy.writeEvalVarObjectProbeAccessor(self.ctx, output, &out_idx, probe);
        if (out_idx != accessor_size or out_idx + probe_size > output.len)
            return error.InvalidBytecode;
        output[out_idx] = probe_op;
        std.mem.writeInt(u32, output[out_idx + 1 ..][0..4], atom_id, .little);
        std.mem.writeInt(u32, output[out_idx + 5 ..][0..4], label_done, .little);
        output[out_idx + 9] = if (probe_op == op.with_put_var)
            @intFromEnum(legacy.evalVarObjectPutProbeMode(probe))
        else
            @intFromBool(legacy.evalVarObjectProbeIsWith(probe));
        self.product.atom_operands[atom_start] = self.ctx.function.atoms.dup(atom_id);
        out_atom_idx = 1;
        out_idx += probe_size;
        if (out_idx != code_need) return error.InvalidBytecode;

        _ = try updateLabel(self.product, label_done, 1);
        try self.incrementJumpSize();
    }

    fn emitDynamicEnvProbes(
        self: *Resolver,
        atom_id: core.atom.Atom,
        scope_level: i32,
        probe_op: u8,
        expected_count: usize,
        expected_prefix_size: usize,
    ) Error!u32 {
        if (expected_count == 0) return error.InvalidBytecode;
        const label_done = try self.newProductLabel();
        const code_start = self.product.code_len;
        const atom_start = self.product.atom_len;

        var with_iter = legacy.localWithProbeIteratorInit(self.ctx, atom_id, scope_level);
        while (legacy.localWithProbeIteratorNext(&with_iter)) |idx| {
            try self.emitDynamicEnvProbe(atom_id, .{ .with_local = idx }, probe_op, label_done);
        }

        if (!legacy.staticBindingStopsDynamicEnvProbes(self.ctx, atom_id, scope_level)) {
            const fd = self.ctx.function_def orelse return error.NoFunctionDef;
            if (!legacy.scopeUsesArgumentEnvironmentOnly(fd, scope_level) and fd.var_object_idx >= 0) {
                try self.emitDynamicEnvProbe(
                    atom_id,
                    .{ .local = @intCast(fd.var_object_idx) },
                    probe_op,
                    label_done,
                );
            }
            if (fd.arg_var_object_idx >= 0) {
                try self.emitDynamicEnvProbe(
                    atom_id,
                    .{ .local = @intCast(fd.arg_var_object_idx) },
                    probe_op,
                    label_done,
                );
            }
            var closure_iter = legacy.closureDynamicEnvProbeIteratorInit(self.ctx, atom_id);
            while (legacy.closureDynamicEnvProbeIteratorNext(&closure_iter)) |idx| {
                if (idx >= fd.closure_var.len) return error.InvalidBytecode;
                try self.emitDynamicEnvProbe(
                    atom_id,
                    legacy.evalVarObjectClosureProbe(fd.closure_var[idx], idx),
                    probe_op,
                    label_done,
                );
            }
        }

        if (@as(usize, self.product.code_len - code_start) != expected_prefix_size or
            @as(usize, self.product.atom_len - atom_start) != expected_count)
        {
            return error.InvalidBytecode;
        }
        return label_done;
    }

    fn emitThrowVarRedeclaration(
        self: *Resolver,
        atom_id: core.atom.Atom,
    ) Error!void {
        const code_need = legacy.throw_error_instr_size;
        try self.prepareLegacyWrite(code_need, 1);
        const code_start: usize = @intCast(self.product.code_len);
        const atom_start: usize = @intCast(self.product.atom_len);
        var out_idx: usize = 0;
        var out_atom_idx: usize = 0;
        defer self.finishLegacyWrite(out_idx, out_atom_idx);
        legacy.writeThrowVarRedeclaration(
            self.ctx.function,
            self.product.code[code_start..][0..code_need],
            &out_idx,
            self.product.atom_operands[atom_start..][0..1],
            &out_atom_idx,
            atom_id,
        );
        if (out_idx != code_need or out_atom_idx != 1)
            return error.InvalidBytecode;
    }

    fn writeLoweredScopeDeleteVar(
        self: *Resolver,
        atom_id: core.atom.Atom,
        scope_level: i32,
    ) Error!void {
        const code_need = legacy.loweredScopeDeleteVarSize(self.ctx, atom_id, scope_level);
        const atom_need: usize = @intFromBool(code_need == 5);
        try self.prepareLegacyWrite(code_need, atom_need);
        const code_start: usize = @intCast(self.product.code_len);
        const atom_start: usize = @intCast(self.product.atom_len);
        var out_idx: usize = 0;
        var out_atom_idx: usize = 0;
        defer self.finishLegacyWrite(out_idx, out_atom_idx);
        try legacy.writeLoweredScopeDeleteVar(
            self.ctx,
            self.ctx.function,
            self.product.code[code_start..][0..code_need],
            &out_idx,
            self.product.atom_operands[atom_start..][0..atom_need],
            &out_atom_idx,
            atom_id,
            scope_level,
        );
        if (out_idx != code_need or out_atom_idx != atom_need)
            return error.InvalidBytecode;
    }

    fn writeLoweredScopeGetRef(
        self: *Resolver,
        atom_id: core.atom.Atom,
        scope_level: i32,
    ) Error!void {
        const code_need = legacy.loweredScopeGetRefSize(self.ctx, atom_id, scope_level);
        try self.prepareLegacyWrite(code_need, 0);
        const code_start: usize = @intCast(self.product.code_len);
        var out_idx: usize = 0;
        defer self.finishLegacyWrite(out_idx, 0);
        try legacy.writeLoweredScopeGetRef(
            self.ctx,
            self.product.code[code_start..][0..code_need],
            &out_idx,
            atom_id,
            scope_level,
        );
        if (out_idx != code_need) return error.InvalidBytecode;
    }

    fn writeLoweredScopeMakeRef(
        self: *Resolver,
        atom_id: core.atom.Atom,
        scope_level: i32,
    ) Error!void {
        const code_need = legacy.loweredScopeMakeRefSize(self.ctx, atom_id, scope_level);
        const atom_need = legacy.loweredScopeMakeRefAtomCount(self.ctx, atom_id, scope_level);
        try self.prepareLegacyWrite(code_need, atom_need);
        const code_start: usize = @intCast(self.product.code_len);
        const atom_start: usize = @intCast(self.product.atom_len);
        var out_idx: usize = 0;
        var out_atom_idx: usize = 0;
        defer self.finishLegacyWrite(out_idx, out_atom_idx);
        try legacy.writeLoweredScopeMakeRef(
            self.ctx,
            self.ctx.function,
            self.product.code[code_start..][0..code_need],
            &out_idx,
            self.product.atom_operands[atom_start..][0..atom_need],
            &out_atom_idx,
            atom_id,
            scope_level,
        );
        if (out_idx != code_need or out_atom_idx != atom_need)
            return error.InvalidBytecode;
    }

    fn writeLoweredPrivateField(
        self: *Resolver,
        op_id: u8,
        atom_id: core.atom.Atom,
        scope_level: i32,
        resolution: legacy.PrivateFieldResolutionAlias,
    ) Error!void {
        const code_need = try legacy.loweredPrivateFieldSize(
            self.ctx,
            op_id,
            atom_id,
            scope_level,
            resolution,
        );
        const atom_need = legacy.loweredPrivateFieldAtomCount(op_id, resolution);
        try self.prepareLegacyWrite(code_need, atom_need);
        const code_start: usize = @intCast(self.product.code_len);
        const atom_start: usize = @intCast(self.product.atom_len);
        var out_idx: usize = 0;
        var out_atom_idx: usize = 0;
        defer self.finishLegacyWrite(out_idx, out_atom_idx);
        try legacy.writeLoweredPrivateField(
            self.ctx,
            self.product.code[code_start..][0..code_need],
            &out_idx,
            self.product.atom_operands[atom_start..][0..atom_need],
            &out_atom_idx,
            op_id,
            atom_id,
            scope_level,
            resolution,
        );
        if (out_idx != code_need or out_atom_idx != atom_need)
            return error.InvalidBytecode;
    }

    fn writeEnterScopeRefresh(self: *Resolver, scope: i32) Error!void {
        const code_need = try legacy.enterScopeRefreshSize(self.ctx, scope);
        if (code_need == 0) return;
        try self.prepareLegacyWrite(code_need, 0);
        const code_start: usize = @intCast(self.product.code_len);
        var out_idx: usize = 0;
        defer self.finishLegacyWrite(out_idx, 0);
        try legacy.writeEnterScopeRefresh(
            self.ctx,
            self.product.code[code_start..][0..code_need],
            &out_idx,
            scope,
        );
        if (out_idx != code_need) return error.InvalidBytecode;
    }

    fn writeLeaveScopeClose(self: *Resolver, scope: i32) Error!void {
        const code_need = legacy.leaveScopeCloseSize(self.ctx, scope);
        if (code_need == 0) return;
        try self.prepareLegacyWrite(code_need, 0);
        const code_start: usize = @intCast(self.product.code_len);
        var out_idx: usize = 0;
        defer self.finishLegacyWrite(out_idx, 0);
        legacy.writeLeaveScopeClose(
            self.ctx,
            self.product.code[code_start..][0..code_need],
            &out_idx,
            scope,
        );
        if (out_idx != code_need) return error.InvalidBytecode;
    }

    fn registerPendingTailRewrite(
        self: *Resolver,
        input_offset: u32,
        emit_dup: bool,
        put_action: legacy.ScopeVarActionAlias,
    ) Error!void {
        for (self.pending_tail_rewrites[0..self.pending_tail_len]) |rewrite| {
            if (!rewrite.consumed and rewrite.input_offset == input_offset)
                return error.InvalidBytecode;
        }
        if (self.pending_tail_len == std.math.maxInt(u32))
            return error.BytecodeOverflow;
        try reserve(
            PendingTailRewrite,
            self.product.memory,
            &self.pending_tail_rewrites,
            &self.pending_tail_capacity,
            self.pending_tail_len,
            1,
            4,
        );
        self.pending_tail_rewrites[self.pending_tail_len] = .{
            .input_offset = input_offset,
            .emit_dup = emit_dup,
            .put_action = put_action,
        };
        self.pending_tail_len += 1;
    }

    fn pendingTailRewriteAt(self: *Resolver, input_pos: u32) Error!?usize {
        for (self.pending_tail_rewrites[0..self.pending_tail_len], 0..) |rewrite, index| {
            if (rewrite.consumed) continue;
            if (rewrite.input_offset < input_pos) return error.InvalidBytecode;
            if (rewrite.input_offset == input_pos) return index;
        }
        return null;
    }

    fn emitPendingTailRewrite(
        self: *Resolver,
        rewrite_index: usize,
    ) Error!u32 {
        if (rewrite_index >= self.pending_tail_len) return error.InvalidBytecode;
        const rewrite = &self.pending_tail_rewrites[rewrite_index];
        const tail_end = std.math.add(u32, rewrite.input_offset, 2) catch
            return error.InvalidBytecode;
        if (rewrite.consumed or tail_end > self.input.code_len)
            return error.InvalidBytecode;
        const first_op = self.code[rewrite.input_offset];
        if ((first_op != op.insert3 and first_op != op.perm4 and
            first_op != op.rot3l and first_op != op.nop) or
            self.code[rewrite.input_offset + 1] != op.put_ref_value)
        {
            return error.InvalidBytecode;
        }
        if (rewrite.emit_dup) try self.emitInstruction(&.{op.dup}, null);
        try self.writeScopeVarAction(core.atom.null_atom, rewrite.put_action);
        self.absorbSourcesThrough(rewrite.input_offset + 1);
        rewrite.consumed = true;
        return tail_end;
    }

    fn ensureAllPendingTailsConsumed(self: *const Resolver) Error!void {
        for (self.pending_tail_rewrites[0..self.pending_tail_len]) |rewrite| {
            if (!rewrite.consumed) return error.InvalidBytecode;
        }
    }

    fn incrementJumpSize(self: *Resolver) Error!void {
        self.product.jump_size = std.math.add(u32, self.product.jump_size, 1) catch
            return error.BytecodeOverflow;
    }

    fn absorbSourcesThrough(self: *Resolver, input_pos: u32) void {
        while (self.source_cursor < self.input_sources.len and
            self.input_sources[self.source_cursor].temp_offset <= input_pos)
        {
            const source = self.input_sources[self.source_cursor];
            self.pending_source = .{ .line = source.line, .col = source.col };
            self.source_cursor += 1;
        }
    }

    fn shouldAttachSource(self: *const Resolver) bool {
        const pending = self.pending_source orelse return false;
        const last = self.last_attached_source orelse return true;
        return !sourcePointEqual(pending, last);
    }

    fn emitInstruction(
        self: *Resolver,
        bytes: []const u8,
        atom_id: ?core.atom.Atom,
    ) Error!void {
        if (bytes.len == 0 or bytes.len > std.math.maxInt(u32))
            return error.InvalidBytecode;
        const byte_count: u32 = @intCast(bytes.len);
        const next_code_len = std.math.add(u32, self.product.code_len, byte_count) catch
            return error.BytecodeOverflow;
        if (atom_id) |expected_atom| {
            if (bytes.len < 5 or
                std.mem.readInt(u32, bytes[1..5], .little) != expected_atom)
            {
                return error.InvalidBytecode;
            }
            if (self.product.atom_len == std.math.maxInt(u32))
                return error.BytecodeOverflow;
        }
        const attach_source = self.shouldAttachSource();
        if (attach_source and self.product.source_len == std.math.maxInt(u32))
            return error.BytecodeOverflow;

        try reserve(
            u8,
            self.product.memory,
            &self.product.code,
            &self.product.code_capacity,
            self.product.code_len,
            bytes.len,
            16,
        );
        if (atom_id != null) {
            try reserve(
                core.atom.Atom,
                self.product.memory,
                &self.product.atom_operands,
                &self.product.atom_capacity,
                self.product.atom_len,
                1,
                8,
            );
        }
        if (attach_source) {
            try reserve(
                builder.SourceSlot,
                self.product.memory,
                &self.product.source_slots,
                &self.product.source_capacity,
                self.product.source_len,
                1,
                8,
            );
        }

        if (attach_source) {
            const source = self.pending_source.?;
            self.product.source_slots[self.product.source_len] = .{
                .temp_offset = self.product.code_len,
                .line = source.line,
                .col = source.col,
            };
            self.product.source_len += 1;
            self.last_attached_source = source;
        }

        const output_start: usize = @intCast(self.product.code_len);
        @memcpy(self.product.code[output_start..][0..bytes.len], bytes);
        if (atom_id) |input_atom| {
            self.product.atom_operands[self.product.atom_len] = self.product.atoms.dup(input_atom);
            self.product.atom_len += 1;
        }
        self.product.code_len = next_code_len;
    }

    fn consumeInputAtom(
        self: *Resolver,
        input_pos: u32,
        instruction: TempInstruction,
    ) Error!?core.atom.Atom {
        if (!instruction.has_atom) return null;
        if (self.atom_index >= self.atom_ledger.len or instruction.size < 5)
            return error.InvalidBytecode;
        const pc: usize = @intCast(input_pos);
        const operand = std.mem.readInt(u32, self.code[pc + 1 ..][0..4], .little);
        const ledger_atom = self.atom_ledger[self.atom_index];
        if (operand != ledger_atom) return error.InvalidBytecode;
        self.atom_index += 1;
        return ledger_atom;
    }

    fn copyInputInstruction(
        self: *Resolver,
        input_pos: u32,
        instruction: TempInstruction,
        atom_id: ?core.atom.Atom,
    ) Error!void {
        const start: usize = @intCast(input_pos);
        const end = start + instruction.size;
        try self.emitInstruction(self.code[start..end], atom_id);
    }

    fn validateLabelIndex(self: *const Resolver, label_index: u32) Error!void {
        if (label_index >= self.input.label_len) return error.InvalidBytecode;
    }

    fn labelAt(self: *const Resolver, input_pos: u32, operand_delta: u32) Error!u32 {
        const operand_pos = std.math.add(u32, input_pos, operand_delta) catch
            return error.InvalidBytecode;
        const operand_index: usize = @intCast(operand_pos);
        if (operand_index + 4 > self.code.len) return error.InvalidBytecode;
        const label_index = std.mem.readInt(u32, self.code[operand_index..][0..4], .little);
        try self.validateLabelIndex(label_index);
        return label_index;
    }

    fn passBindsAt(self: *Resolver, input_pos: u32) Error!void {
        if (self.bind_cursor < self.binds.len and
            self.binds[self.bind_cursor].input_offset < input_pos)
        {
            return error.InvalidBytecode;
        }
        while (self.bind_cursor < self.binds.len and
            self.binds[self.bind_cursor].input_offset == input_pos)
        {
            const entry = &self.binds[self.bind_cursor];
            if (!entry.dead_skipped) {
                const slot = &self.product.label_slots[entry.label_index];
                slot.bound_offset = self.product.code_len;
                slot.flags.bound = true;
            }
            self.bind_cursor += 1;
        }
    }

    fn blockAt(self: *Resolver, input_pos: u32) Error!usize {
        if (input_pos > self.input.code_len or self.graph.block_starts.len == 0)
            return error.InvalidBytecode;
        while (self.block_cursor + 1 < self.graph.block_starts.len and
            self.graph.block_starts[self.block_cursor + 1] <= input_pos)
        {
            self.block_cursor += 1;
        }
        if (self.block_cursor >= self.graph.blocks.len or
            self.graph.block_starts[self.block_cursor] > input_pos)
        {
            return error.InvalidBytecode;
        }
        return self.block_cursor;
    }

    /// Exact-CFG dead boundary with qjs ref_count bookkeeping retained for
    /// Stage 4 short-form selection. Dead blocks discard every bind at their
    /// start; at a reachable boundary, only zero-reference label positions are
    /// suppressed before the ordinary live bind pass.
    fn deadBoundaryAt(self: *Resolver, input_pos: u32) Error!bool {
        const block_index = try self.blockAt(input_pos);
        if (self.bind_cursor < self.binds.len and
            self.binds[self.bind_cursor].input_offset < input_pos)
        {
            return error.InvalidBytecode;
        }
        var end = self.bind_cursor;
        while (end < self.binds.len and self.binds[end].input_offset == input_pos) : (end += 1) {}
        if (end == self.bind_cursor) return false;

        if (self.graph.block_starts[block_index] != input_pos)
            return error.InvalidBytecode;
        std.debug.assert(self.graph.block_starts[block_index] == input_pos);
        if (self.graph.isReachable(block_index)) {
            for (self.binds[self.bind_cursor..end]) |*entry| {
                if (self.product.label_slots[entry.label_index].ref_count == 0)
                    entry.dead_skipped = true;
            }
            return true;
        }

        for (self.binds[self.bind_cursor..end]) |*entry| {
            std.debug.assert(self.product.label_slots[entry.label_index].first_reloc == labels.no_reloc);
            entry.dead_skipped = true;
        }
        self.bind_cursor = end;
        return false;
    }

    fn firstBindAtOrAfter(self: *const Resolver, input_pos: u32) usize {
        var lo: usize = 0;
        var hi: usize = self.binds.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.binds[mid].input_offset < input_pos)
                lo = mid + 1
            else
                hi = mid;
        }
        return lo;
    }

    fn hasBindInRange(
        self: *const Resolver,
        start: u32,
        end: u32,
        transparent_start_binds: bool,
    ) bool {
        var index = self.firstBindAtOrAfter(start);
        while (index < self.binds.len and self.binds[index].input_offset < end) : (index += 1) {
            if (!transparent_start_binds or self.binds[index].input_offset != start)
                return true;
        }
        return false;
    }

    /// qjs:32770-32831. Decide only the v2 tail-structure adaptation here;
    /// both selected variable forms come from the legacy binding planner.
    fn planMakeRefFold(
        self: *Resolver,
        position_next: u32,
        atom_id: core.atom.Atom,
        scope_operand: legacy.ScopeOperandAlias,
        aux_label: u32,
    ) Error!?MakeRefFold {
        if (legacy.evalVarObjectProbePlan(
            self.ctx,
            atom_id,
            scope_operand.level,
            op.scope_make_ref,
            .make_ref,
        ) != null) return null;

        if (aux_label >= self.input.label_len) return error.InvalidBytecode;
        const input_slot = self.input.label_slots[aux_label];
        if (!input_slot.flags.bound or input_slot.bound_offset == labels.unbound)
            return error.InvalidBytecode;
        const tail_offset = input_slot.bound_offset;
        const tail_end = std.math.add(u32, tail_offset, 2) catch return null;
        if (tail_offset < position_next or tail_end > self.input.code_len)
            return null;
        const first_op = self.code[tail_offset];
        if ((first_op != op.insert3 and first_op != op.perm4 and
            first_op != op.rot3l and first_op != op.nop) or
            self.code[tail_offset + 1] != op.put_ref_value)
        {
            return null;
        }
        if (self.hasBindInRange(tail_offset + 1, tail_end, false))
            return null;

        if (legacy.makeRefBindingIsGlobal(self.ctx, atom_id, scope_operand.level) and
            !legacy.canOptimizeGlobalRefPutTail(self.ctx, atom_id))
        {
            return null;
        }

        const get_plan = try legacy.planScopeVarLowering(
            self.ctx,
            atom_id,
            scope_operand,
            op.scope_get_var,
            false,
        );
        const put_plan = try legacy.planScopeVarLowering(
            self.ctx,
            atom_id,
            scope_operand,
            op.scope_put_var,
            false,
        );
        if (get_plan.probe.count != 0 or put_plan.probe.count != 0 or
            legacy.scopeVarActionAtomCount(get_plan.action) != 0 or
            legacy.scopeVarActionAtomCount(put_plan.action) != 0 or
            get_plan.action.selected.op_id == op.drop or
            put_plan.action.selected.op_id == op.drop or
            get_plan.action.selected.op_id == op.throw_error or
            put_plan.action.selected.op_id == op.throw_error)
        {
            return null;
        }

        return .{
            .tail_offset = tail_offset,
            .emit_dup = first_op == op.insert3,
            .reads_value = position_next < self.input.code_len and
                self.code[position_next] == op.get_ref_value,
            .get_action = get_plan.action,
            .put_action = put_plan.action,
        };
    }

    const BranchDropMatch = struct {
        branch_op: u8,
        label_index: u32,
        drop_pos: u32,
        after: u32,
    };

    fn matchBranchDrop(
        self: *Resolver,
        start: u32,
        expected_op: ?u8,
        transparent_start_binds: bool,
    ) Error!?BranchDropMatch {
        if (start >= self.code.len) return null;
        const branch = try tempInstruction(self.code, self.atom_ledger, start, self.atom_index);
        const branch_op = self.code[start];
        if (branch_op != op.if_false and branch_op != op.if_true) return null;
        if (expected_op) |wanted| if (branch_op != wanted) return null;
        if (branch.size != 5 or branch.has_atom) return error.InvalidBytecode;
        const drop_pos = start + branch.size;
        if (drop_pos >= self.code.len) return null;
        const drop = try tempInstruction(self.code, self.atom_ledger, drop_pos, self.atom_index);
        if (self.code[drop_pos] != op.drop or drop.size != 1) return null;
        const after = drop_pos + drop.size;
        if (self.hasBindInRange(start, after, transparent_start_binds)) return null;
        return .{
            .branch_op = branch_op,
            .label_index = try self.labelAt(start, 1),
            .drop_pos = drop_pos,
            .after = after,
        };
    }

    fn matchDupBranchDrop(
        self: *Resolver,
        start: u32,
        expected_branch: u8,
        transparent_start_binds: bool,
    ) Error!?BranchDropMatch {
        if (start >= self.code.len) return null;
        const duplicate = try tempInstruction(self.code, self.atom_ledger, start, self.atom_index);
        if (self.code[start] != op.dup or duplicate.size != 1) return null;
        const branch_start = start + duplicate.size;
        const tail = (try self.matchBranchDrop(branch_start, expected_branch, true)) orelse return null;
        if (self.hasBindInRange(start, tail.after, transparent_start_binds)) return null;
        return tail;
    }

    const BareBranchMatch = struct {
        label_index: u32,
        after: u32,
    };

    fn matchBareBranch(
        self: *Resolver,
        start: u32,
        expected_branch: u8,
        transparent_start_binds: bool,
    ) Error!?BareBranchMatch {
        if (start >= self.code.len) return null;
        const branch = try tempInstruction(self.code, self.atom_ledger, start, self.atom_index);
        if (self.code[start] != expected_branch or branch.size != 5 or branch.has_atom) return null;
        const after = start + branch.size;
        if (self.hasBindInRange(start, after, transparent_start_binds)) return null;
        return .{ .label_index = try self.labelAt(start, 1), .after = after };
    }

    const InsertTailMatch = struct {
        middle_op: u8,
        drop_pos: u32,
        after: u32,
    };

    fn matchInsertTail(self: *Resolver, start: u32) Error!?InsertTailMatch {
        if (start >= self.code.len) return null;
        const middle = try tempInstruction(self.code, self.atom_ledger, start, self.atom_index);
        const middle_op = self.code[start];
        if ((middle_op != op.put_array_el and middle_op != op.put_ref_value) or middle.size != 1)
            return null;
        const drop_pos = start + middle.size;
        if (drop_pos >= self.code.len) return null;
        const drop = try tempInstruction(self.code, self.atom_ledger, drop_pos, self.atom_index);
        if (self.code[drop_pos] != op.drop or drop.size != 1) return null;
        const after = drop_pos + drop.size;
        if (self.hasBindInRange(start, after, false)) return null;
        return .{ .middle_op = middle_op, .drop_pos = drop_pos, .after = after };
    }

    /// qjs:34161-34182. A v2 bind already denotes the position after its
    /// conceptual OP_label, so binds at the returned position are transparent.
    fn getLabelPos(self: *Resolver, initial_label: u32) Error!u32 {
        var label_index = initial_label;
        var position: u32 = 0;
        var iteration: u8 = 0;
        while (iteration < 20) : (iteration += 1) {
            try self.validateLabelIndex(label_index);
            const slot = self.input.label_slots[label_index];
            if (!slot.flags.bound or slot.bound_offset == labels.unbound or
                slot.bound_offset > self.input.code_len)
            {
                return error.InvalidBytecode;
            }
            position = slot.bound_offset;
            if (position == self.input.code_len) return position;
            if (self.code[position] != op.goto) return position;
            const instruction = try tempInstruction(self.code, self.atom_ledger, position, self.atom_index);
            if (instruction.size != 5 or instruction.has_atom) return error.InvalidBytecode;
            label_index = try self.labelAt(position, 1);
        }
        return position;
    }

    /// qjs:34111-34159.
    fn skipDeadCode(self: *Resolver, start: u32) Error!u32 {
        var position = start;
        while (true) {
            if (try self.deadBoundaryAt(position)) return position;
            if (position == self.input.code_len) return position;
            if (position > self.input.code_len) return error.InvalidBytecode;

            self.absorbSourcesThrough(position);
            const instruction = try tempInstruction(
                self.code,
                self.atom_ledger,
                position,
                self.atom_index,
            );
            _ = try self.consumeInputAtom(position, instruction);
            const op_id = self.code[position];

            // qjs:34137-34152.
            switch (op_id) {
                op.if_false, op.if_true, op.goto, op.@"catch", op.gosub => {
                    const label_index = try self.labelAt(position, 1);
                    _ = try updateLabel(self.product, label_index, -1);
                },
                op.scope_make_ref => {
                    if (instruction.is_temp) {
                        const label_index = try self.labelAt(position, 5);
                        _ = try updateLabel(self.product, label_index, -1);
                    }
                },
                else => {
                    const format = if (instruction.is_temp)
                        opcode.formatOfPhase1(op_id)
                    else
                        opcode.formatOf(op_id);
                    if (format == .atom_label_u8 or format == .atom_label_u16) {
                        const label_index = try self.labelAt(position, 5);
                        _ = try updateLabel(self.product, label_index, -1);
                    }
                },
            }
            position = std.math.add(u32, position, instruction.size) catch
                return error.InvalidBytecode;
        }
    }

    fn lowerScopeVar(
        self: *Resolver,
        position: u32,
        op_id: u8,
        atom_id: core.atom.Atom,
    ) Error!void {
        const pc: usize = @intCast(position);
        const scope_operand = legacy.decodeScopeOperand(self.code[pc + 5 ..][0..2]);
        try legacy.resolveBindingTopology(self.ctx, atom_id, scope_operand.level);
        const plan = try legacy.planScopeVarLowering(
            self.ctx,
            atom_id,
            scope_operand,
            op_id,
            legacy.functionHasDynamicEnvObjects(self.ctx),
        );

        var label_done: ?u32 = null;
        if (plan.probe.count != 0) {
            const kind = legacy.scopeVarProbeKind(op_id, scope_operand.no_dynamic_env) orelse
                return error.InvalidBytecode;
            label_done = try self.emitDynamicEnvProbes(
                atom_id,
                scope_operand.level,
                legacy.scopeVarProbeOpcode(kind),
                plan.probe.count,
                plan.probe.prefix_size,
            );
        }
        try self.writeScopeVarAction(atom_id, plan.action);
        if (label_done) |label_index| try self.bindProductLabel(label_index);
    }

    fn lowerScopeRef(
        self: *Resolver,
        position: u32,
        op_id: u8,
        atom_id: core.atom.Atom,
    ) Error!void {
        const pc: usize = @intCast(position);
        const scope_operand = legacy.decodeScopeOperand(self.code[pc + 5 ..][0..2]);
        try legacy.resolveBindingTopology(self.ctx, atom_id, scope_operand.level);

        const probe_kind: enum { delete, get_ref } = if (op_id == op.scope_delete_var)
            .delete
        else if (op_id == op.scope_get_ref)
            .get_ref
        else
            return error.InvalidBytecode;
        const probe_plan = switch (probe_kind) {
            .delete => legacy.evalVarObjectProbePlan(
                self.ctx,
                atom_id,
                scope_operand.level,
                op_id,
                .delete,
            ),
            .get_ref => legacy.evalVarObjectProbePlan(
                self.ctx,
                atom_id,
                scope_operand.level,
                op_id,
                .get_ref,
            ),
        };
        var label_done: ?u32 = null;
        if (probe_plan) |probe| {
            label_done = try self.emitDynamicEnvProbes(
                atom_id,
                scope_operand.level,
                if (probe_kind == .delete) op.with_delete_var else op.with_get_ref,
                probe.count,
                probe.prefix_size,
            );
        }

        if (op_id == op.scope_delete_var) {
            try self.writeLoweredScopeDeleteVar(atom_id, scope_operand.level);
        } else {
            try self.writeLoweredScopeGetRef(atom_id, scope_operand.level);
        }
        if (label_done) |label_index| try self.bindProductLabel(label_index);
    }

    /// qjs:34277-34288, 32995-33034, 33250-33261, 33310-33337.
    fn lowerScopeMakeRef(
        self: *Resolver,
        position: u32,
        position_next: u32,
        atom_id: core.atom.Atom,
    ) Error!u32 {
        const pc: usize = @intCast(position);
        const aux_label = try self.labelAt(position, 5);
        // qjs:34284. The parser's auxiliary association is never a runtime jump.
        _ = try updateLabel(self.product, aux_label, -1);

        const scope_operand = legacy.decodeScopeOperand(self.code[pc + 9 ..][0..2]);
        try legacy.resolveBindingTopology(self.ctx, atom_id, scope_operand.level);

        if (try self.planMakeRefFold(position_next, atom_id, scope_operand, aux_label)) |fold| {
            try self.registerPendingTailRewrite(
                fold.tail_offset,
                fold.emit_dup,
                fold.put_action,
            );
            var next = position_next;
            if (fold.reads_value) {
                try self.passBindsAt(position_next);
                self.absorbSourcesThrough(position_next);
                try self.writeScopeVarAction(atom_id, fold.get_action);
                next = std.math.add(u32, next, 1) catch return error.InvalidBytecode;
            }
            return next;
        }

        const probe_plan = legacy.evalVarObjectProbePlan(
            self.ctx,
            atom_id,
            scope_operand.level,
            op.scope_make_ref,
            .make_ref,
        );
        // qjs:33024-33032, 33287-33299, 33332-33336. Only a surviving
        // reference captures a local/argument cell.
        try legacy.markReferenceTakenBinding(self.ctx, atom_id, scope_operand.level);

        var label_done: ?u32 = null;
        if (probe_plan) |probe| {
            label_done = try self.emitDynamicEnvProbes(
                atom_id,
                scope_operand.level,
                op.with_make_ref,
                probe.count,
                probe.prefix_size,
            );
        }
        try self.writeLoweredScopeMakeRef(atom_id, scope_operand.level);
        if (label_done) |label_index| try self.bindProductLabel(label_index);
        return position_next;
    }

    fn lowerPrivateField(
        self: *Resolver,
        position: u32,
        op_id: u8,
        atom_id: core.atom.Atom,
    ) Error!void {
        const pc: usize = @intCast(position);
        const scope_operand = legacy.decodeScopeOperand(self.code[pc + 5 ..][0..2]);
        try legacy.resolvePrivateBindingTopology(
            self.ctx,
            op_id,
            atom_id,
            scope_operand.level,
        );
        const resolution = legacy.resolvePrivateField(
            self.ctx,
            atom_id,
            scope_operand.level,
        ) orelse return error.ClosureVarNotFound;
        try self.writeLoweredPrivateField(
            op_id,
            atom_id,
            scope_operand.level,
            resolution,
        );
    }

    fn run(self: *Resolver) Error!void {
        // qjs:34200-34234. Runtime redeclaration checks are emitted before the
        // walk can create any demand-driven ordinary-global closure rows.
        const fd = self.ctx.function_def orelse return error.NoFunctionDef;
        for (fd.global_vars) |global_var| {
            if (legacy.hasDirectEvalLexicalRedeclaration(fd, global_var)) {
                try self.emitThrowVarRedeclaration(global_var.var_name);
            }
        }

        var position: u32 = 0;
        while (position < self.input.code_len) {
            try self.passBindsAt(position);
            self.absorbSourcesThrough(position);

            if (try self.pendingTailRewriteAt(position)) |rewrite_index| {
                position = try self.emitPendingTailRewrite(rewrite_index);
                continue;
            }

            const instruction = try tempInstruction(
                self.code,
                self.atom_ledger,
                position,
                self.atom_index,
            );
            var position_next = std.math.add(u32, position, instruction.size) catch
                return error.InvalidBytecode;
            const input_atom = try self.consumeInputAtom(position, instruction);
            const op_id = self.code[position];

            switch (op_id) {
                // qjs:34304.
                op.gosub => {
                    try self.incrementJumpSize();
                    const label_index = try self.labelAt(position, 1);
                    const slot = self.input.label_slots[label_index];
                    if (!slot.flags.bound or slot.bound_offset == labels.unbound or
                        slot.bound_offset > self.input.code_len)
                    {
                        return error.InvalidBytecode;
                    }
                    if (slot.bound_offset < self.input.code_len and
                        self.code[slot.bound_offset] == op.ret)
                    {
                        _ = try updateLabel(self.product, label_index, -1);
                    } else {
                        try self.copyInputInstruction(position, instruction, input_atom);
                    }
                },

                // qjs:34360-34381.
                op.goto,
                op.tail_call,
                op.tail_call_method,
                op.@"return",
                op.return_undef,
                op.throw,
                op.throw_error,
                op.ret,
                => {
                    if (op_id == op.goto) {
                        try self.incrementJumpSize();
                        _ = try self.labelAt(position, 1);
                    }
                    try self.copyInputInstruction(position, instruction, input_atom);
                    position = try self.skipDeadCode(position_next);
                    continue;
                },

                // qjs:34460-34464.
                op.if_false, op.if_true, op.@"catch" => {
                    try self.incrementJumpSize();
                    _ = try self.labelAt(position, 1);
                    try self.copyInputInstruction(position, instruction, input_atom);
                },

                // qjs:34466-34496.
                op.dup => {
                    if (try self.matchBranchDrop(position_next, null, false)) |first| {
                        var target_position = try self.getLabelPos(first.label_index);
                        var chain_count: u8 = 0;
                        while (try self.matchDupBranchDrop(
                            target_position,
                            first.branch_op,
                            true,
                        )) |chain| {
                            // qjs:34466-34496 has no semantic depth limit. The
                            // cap is only bounded search work: stop chasing and
                            // let the final match fail back to the plain dup.
                            if (chain_count == 20) break;
                            chain_count += 1;
                            target_position = try self.getLabelPos(chain.label_index);
                        }
                        if (try self.matchBareBranch(
                            target_position,
                            first.branch_op,
                            true,
                        )) |target| {
                            try self.incrementJumpSize();
                            _ = try updateLabel(self.product, first.label_index, -1);
                            _ = try updateLabel(self.product, target.label_index, 1);
                            var rewritten: [5]u8 = undefined;
                            rewritten[0] = first.branch_op;
                            std.mem.writeInt(u32, rewritten[1..5], target.label_index, .little);
                            try self.emitInstruction(&rewritten, null);
                            self.absorbSourcesThrough(first.drop_pos);
                            position_next = first.after;
                        } else {
                            try self.copyInputInstruction(position, instruction, input_atom);
                        }
                    } else {
                        try self.copyInputInstruction(position, instruction, input_atom);
                    }
                },

                // qjs:34343-34358.
                op.insert3 => {
                    if (try self.matchInsertTail(position_next)) |match| {
                        try self.emitInstruction(&.{match.middle_op}, null);
                        self.absorbSourcesThrough(match.drop_pos);
                        position_next = match.after;
                    } else {
                        try self.copyInputInstruction(position, instruction, input_atom);
                    }
                },

                // qjs:34499-34501.
                op.nop => {},

                // qjs:34502-34504.
                op.set_class_name => {},

                // qjs:34451-34458.
                op.set_name => {
                    if (input_atom.? != core.atom.null_atom)
                        try self.copyInputInstruction(position, instruction, input_atom);
                },

                // qjs:34506-34512.
                op.get_field_opt_chain => {
                    if (instruction.is_temp) {
                        var rewritten: [5]u8 = undefined;
                        rewritten[0] = op.get_field;
                        std.mem.writeInt(u32, rewritten[1..5], input_atom.?, .little);
                        try self.emitInstruction(&rewritten, input_atom);
                    } else {
                        try self.copyInputInstruction(position, instruction, input_atom);
                    }
                },

                // qjs:34513-34515.
                op.get_array_el_opt_chain => try self.emitInstruction(&.{op.get_array_el}, null),

                // qjs:34247-34255.
                op.eval => {
                    if (instruction.size != 5) return error.InvalidBytecode;
                    const pc: usize = @intCast(position);
                    const call_argc = std.mem.readInt(u16, self.code[pc + 1 ..][0..2], .little);
                    const scope = std.mem.readInt(u16, self.code[pc + 3 ..][0..2], .little);
                    try legacy.markEvalCapturedVariables(fd, scope);
                    const encoded_head = try legacy.encodeEvalScopeHead(fd, scope);
                    var rewritten: [5]u8 = undefined;
                    rewritten[0] = op.eval;
                    std.mem.writeInt(u16, rewritten[1..3], call_argc, .little);
                    std.mem.writeInt(u16, rewritten[3..5], encoded_head, .little);
                    try self.emitInstruction(&rewritten, null);
                },

                // qjs:34257-34262.
                op.apply_eval => {
                    if (instruction.size != 3) return error.InvalidBytecode;
                    const pc: usize = @intCast(position);
                    const scope = std.mem.readInt(u16, self.code[pc + 1 ..][0..2], .little);
                    try legacy.markEvalCapturedVariables(fd, scope);
                    const encoded_head = try legacy.encodeEvalScopeHead(fd, scope);
                    var rewritten: [3]u8 = undefined;
                    rewritten[0] = op.apply_eval;
                    std.mem.writeInt(u16, rewritten[1..3], encoded_head, .little);
                    try self.emitInstruction(&rewritten, null);
                },

                // qjs:34263.
                op.scope_get_var_checkthis => {
                    if (instruction.is_temp)
                        try self.lowerScopeVar(position, op_id, input_atom.?)
                    else
                        try self.copyInputInstruction(position, instruction, input_atom);
                },

                // qjs:34264.
                op.scope_get_var_undef => {
                    if (instruction.is_temp)
                        try self.lowerScopeVar(position, op_id, input_atom.?)
                    else
                        try self.copyInputInstruction(position, instruction, input_atom);
                },

                // qjs:34265.
                op.scope_get_var => {
                    if (instruction.is_temp)
                        try self.lowerScopeVar(position, op_id, input_atom.?)
                    else
                        try self.copyInputInstruction(position, instruction, input_atom);
                },

                // qjs:34266.
                op.scope_put_var => {
                    if (instruction.is_temp)
                        try self.lowerScopeVar(position, op_id, input_atom.?)
                    else
                        try self.copyInputInstruction(position, instruction, input_atom);
                },

                // qjs:34267.
                op.scope_delete_var => {
                    if (instruction.is_temp)
                        try self.lowerScopeRef(position, op_id, input_atom.?)
                    else
                        try self.copyInputInstruction(position, instruction, input_atom);
                },

                // qjs:34268.
                op.scope_get_ref => {
                    if (instruction.is_temp)
                        try self.lowerScopeRef(position, op_id, input_atom.?)
                    else
                        try self.copyInputInstruction(position, instruction, input_atom);
                },

                // qjs:34269.
                op.scope_put_var_init => {
                    if (instruction.is_temp)
                        try self.lowerScopeVar(position, op_id, input_atom.?)
                    else
                        try self.copyInputInstruction(position, instruction, input_atom);
                },

                // qjs:34276-34288.
                op.scope_make_ref => {
                    if (instruction.is_temp)
                        position_next = try self.lowerScopeMakeRef(
                            position,
                            position_next,
                            input_atom.?,
                        )
                    else
                        try self.copyInputInstruction(position, instruction, input_atom);
                },

                // qjs:34290.
                op.scope_get_private_field => {
                    if (instruction.is_temp)
                        try self.lowerPrivateField(position, op_id, input_atom.?)
                    else
                        try self.copyInputInstruction(position, instruction, input_atom);
                },

                // qjs:34291.
                op.scope_get_private_field2 => {
                    if (instruction.is_temp)
                        try self.lowerPrivateField(position, op_id, input_atom.?)
                    else
                        try self.copyInputInstruction(position, instruction, input_atom);
                },

                // qjs:34292.
                op.scope_put_private_field => {
                    if (instruction.is_temp)
                        try self.lowerPrivateField(position, op_id, input_atom.?)
                    else
                        try self.copyInputInstruction(position, instruction, input_atom);
                },

                // qjs:34293.
                op.scope_in_private_field => {
                    if (instruction.is_temp)
                        try self.lowerPrivateField(position, op_id, input_atom.?)
                    else
                        try self.copyInputInstruction(position, instruction, input_atom);
                },

                // qjs:34398-34430.
                op.enter_scope => {
                    if (instruction.size != 3) return error.InvalidBytecode;
                    const pc: usize = @intCast(position);
                    const scope = std.mem.readInt(u16, self.code[pc + 1 ..][0..2], .little);
                    // QCP-1 S3: unlike qjs instantiate_hoisted_definitions here,
                    // zjs finalization owns BODY hoists and the parser emits no
                    // enter_scope marker for the function body.
                    try self.writeEnterScopeRefresh(scope);
                },

                // qjs:34432-34448.
                op.leave_scope => {
                    if (instruction.size != 3) return error.InvalidBytecode;
                    const pc: usize = @intCast(position);
                    const scope = std.mem.readInt(u16, self.code[pc + 1 ..][0..2], .little);
                    try self.writeLeaveScopeClose(scope);
                },

                // qjs:34517-34520.
                else => {
                    const format = if (instruction.is_temp)
                        opcode.formatOfPhase1(op_id)
                    else
                        opcode.formatOf(op_id);
                    if (format == .atom_label_u8 or format == .atom_label_u16)
                        _ = try self.labelAt(position, 5);
                    try self.copyInputInstruction(position, instruction, input_atom);
                },
            }

            position = position_next;
        }

        try self.passBindsAt(self.input.code_len);
        self.absorbSourcesThrough(self.input.code_len);
        try self.ensureAllPendingTailsConsumed();
        if (self.bind_cursor != self.binds.len or
            self.atom_index != self.atom_ledger.len or
            self.source_cursor != self.input_sources.len)
        {
            return error.InvalidBytecode;
        }
    }
};

fn validateInput(input: *const builder.Builder) Error!void {
    if (input.code_len > input.code.len or
        input.atom_len > input.atom_operands.len or
        input.label_len > input.label_slots.len or
        input.source_len > input.source_slots.len)
    {
        return error.InvalidBytecode;
    }

    var previous_source_offset: u32 = 0;
    for (input.source_slots[0..input.source_len], 0..) |source, index| {
        if (source.temp_offset > input.code_len or
            (index != 0 and source.temp_offset < previous_source_offset))
        {
            return error.InvalidBytecode;
        }
        previous_source_offset = source.temp_offset;
    }

    for (input.label_slots[0..input.label_len]) |slot| {
        if (slot.flags.bound) {
            if (slot.bound_offset == labels.unbound or slot.bound_offset > input.code_len)
                return error.InvalidBytecode;
        } else if (slot.bound_offset != labels.unbound) {
            return error.InvalidBytecode;
        }
    }
}

fn initializeLabels(product: *ResolvedProduct, input: *const builder.Builder) Error!void {
    if (input.label_len == 0) return;
    try reserve(
        labels.LabelSlot,
        product.memory,
        &product.label_slots,
        &product.label_capacity,
        0,
        input.label_len,
        8,
    );
    for (input.label_slots[0..input.label_len]) |input_slot| {
        product.label_slots[product.label_len] = .{
            .bound_offset = labels.unbound,
            .ref_count = input_slot.ref_count,
            .first_reloc = labels.no_reloc,
            .flags = .{ .backward_target = input_slot.flags.backward_target },
        };
        product.label_len += 1;
    }
}

fn buildBindIndex(
    memory: *core.memory.MemoryAccount,
    input: *const builder.Builder,
) Error![]BindEntry {
    var bind_count: usize = 0;
    for (input.label_slots[0..input.label_len]) |slot| {
        if (slot.flags.bound) bind_count += 1;
    }
    if (bind_count == 0) return &.{};

    const binds = memory.alloc(BindEntry, bind_count) catch return error.OutOfMemory;
    var bind_index: usize = 0;
    for (input.label_slots[0..input.label_len], 0..) |slot, label_index| {
        if (!slot.flags.bound) continue;
        binds[bind_index] = .{
            .input_offset = slot.bound_offset,
            .label_index = @intCast(label_index),
        };
        bind_index += 1;
    }
    std.mem.sort(BindEntry, binds, {}, cfg.bindLessThan);
    return binds;
}

/// Exact block-CFG resolve pass over fd.v2_builder. The input Builder is
/// strictly read-only: every output atom is freshly retained, and every
/// fallible output allocation is owned by the uncommitted product or scratch
/// topology until the caller commits or deinitializes it.
pub fn run(
    function: *bytecode.Bytecode,
    fd: *bytecode.function_def.FunctionDef,
) Error!ResolvedProduct {
    const input = fd.v2_builder orelse return error.InvalidBytecode;
    if (input.memory != fd.memory or input.atoms != fd.atoms)
        return error.InvalidBytecode;
    try validateInput(input);

    const binds = try buildBindIndex(fd.memory, input);
    defer if (binds.len != 0) fd.memory.free(BindEntry, binds);

    var graph = try cfg.build(fd.memory, input, binds);
    defer graph.deinit();
    if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
        try cfg.auditInstructionOwnership(fd.memory, input, &graph);
    }

    var product: ResolvedProduct = .{ .memory = fd.memory, .atoms = fd.atoms };
    errdefer product.deinitUncommitted();
    try initializeLabels(&product, input);

    var ctx = legacy_pipeline.JSContext.initWithFunctionDef(function, fd);
    // QCP-1 S3: exact-scope accelerator deferred; the linked-chain fallback is
    // the semantic path shared with the legacy pipeline.

    var resolver: Resolver = .{
        .ctx = &ctx,
        .input = input,
        .code = input.code[0..input.code_len],
        .atom_ledger = input.atom_operands[0..input.atom_len],
        .input_sources = input.source_slots[0..input.source_len],
        .product = &product,
        .binds = binds,
        .graph = &graph,
    };
    defer resolver.deinitScratch();
    try resolver.run();
    return product;
}

const ResolveTestHarness = struct {
    rt: *core.JSRuntime,
    name_atom: core.atom.Atom,
    function: bytecode.Bytecode,
    fd: bytecode.function_def.FunctionDef,

    fn init(harness: *ResolveTestHarness, allocator: std.mem.Allocator) !void {
        harness.rt = try core.JSRuntime.create(allocator);
        errdefer harness.rt.destroy();

        harness.name_atom = try harness.rt.atoms.internString("qcp1-s3-pass-a");
        errdefer harness.rt.atoms.free(harness.name_atom);

        harness.function = bytecode.Bytecode.init(
            &harness.rt.memory,
            &harness.rt.atoms,
            harness.name_atom,
        );
        errdefer harness.function.deinit(harness.rt);

        harness.fd = bytecode.function_def.FunctionDef.init(
            &harness.rt.memory,
            &harness.rt.atoms,
            harness.name_atom,
        );
        errdefer harness.fd.deinit(harness.rt);

        const input_builder = try harness.rt.memory.create(builder.Builder);
        input_builder.* = builder.Builder.init(&harness.rt.memory, &harness.rt.atoms);
        harness.fd.v2_builder = input_builder;
    }

    fn deinit(harness: *ResolveTestHarness) void {
        harness.fd.deinit(harness.rt);
        harness.function.deinit(harness.rt);
        harness.rt.atoms.free(harness.name_atom);
        harness.rt.destroy();
    }

    fn deinitInput(harness: *ResolveTestHarness) void {
        if (harness.fd.v2_builder) |input_builder| {
            harness.fd.v2_builder = null;
            input_builder.deinit();
            harness.rt.memory.destroy(builder.Builder, input_builder);
        }
    }

    fn input(harness: *ResolveTestHarness) *builder.Builder {
        return harness.fd.v2_builder.?;
    }

    fn resolve(harness: *ResolveTestHarness) Error!ResolvedProduct {
        return run(&harness.function, &harness.fd);
    }
};

fn requireCompilerV2() !void {
    var skip = std.mem.eql(u8, @import("build_options").zjs_compiler, "legacy");
    _ = &skip;
    if (skip) return error.SkipZigTest;
}

fn expectProductCode(product: *const ResolvedProduct, expected: []const u8) !void {
    try std.testing.expectEqual(@as(u32, @intCast(expected.len)), product.code_len);
    try std.testing.expectEqualSlices(u8, expected, product.code[0..product.code_len]);
}

fn expectProductLabel(
    product: *const ResolvedProduct,
    label: labels.LabelId,
    ref_count: u32,
    bound_offset: u32,
) !void {
    const slot = product.label_slots[label.index()];
    try std.testing.expectEqual(ref_count, slot.ref_count);
    try std.testing.expectEqual(bound_offset, slot.bound_offset);
    try std.testing.expectEqual(bound_offset != labels.unbound, slot.flags.bound);
    try std.testing.expectEqual(labels.no_reloc, slot.first_reloc);
}

const TestInputSnapshot = struct {
    code: []u8,
    atoms: []core.atom.Atom,
    label_slots: []labels.LabelSlot,
    relocs: []labels.RelocEntry,
    source_slots: []builder.SourceSlot,
    code_len: u32,
    atom_len: u32,
    label_len: u32,
    reloc_len: u32,
    source_len: u32,
    last_opcode_pos: i64,

    fn init(input: *const builder.Builder) !TestInputSnapshot {
        const code = try std.testing.allocator.dupe(u8, input.code[0..input.code_len]);
        errdefer std.testing.allocator.free(code);
        const atoms = try std.testing.allocator.dupe(
            core.atom.Atom,
            input.atom_operands[0..input.atom_len],
        );
        errdefer std.testing.allocator.free(atoms);
        const label_slots = try std.testing.allocator.dupe(
            labels.LabelSlot,
            input.label_slots[0..input.label_len],
        );
        errdefer std.testing.allocator.free(label_slots);
        const relocs = try std.testing.allocator.dupe(
            labels.RelocEntry,
            input.relocs[0..input.reloc_len],
        );
        errdefer std.testing.allocator.free(relocs);
        const source_slots = try std.testing.allocator.dupe(
            builder.SourceSlot,
            input.source_slots[0..input.source_len],
        );
        errdefer std.testing.allocator.free(source_slots);
        return .{
            .code = code,
            .atoms = atoms,
            .label_slots = label_slots,
            .relocs = relocs,
            .source_slots = source_slots,
            .code_len = input.code_len,
            .atom_len = input.atom_len,
            .label_len = input.label_len,
            .reloc_len = input.reloc_len,
            .source_len = input.source_len,
            .last_opcode_pos = input.last_opcode_pos,
        };
    }

    fn deinit(self: *TestInputSnapshot) void {
        std.testing.allocator.free(self.code);
        std.testing.allocator.free(self.atoms);
        std.testing.allocator.free(self.label_slots);
        std.testing.allocator.free(self.relocs);
        std.testing.allocator.free(self.source_slots);
        self.* = undefined;
    }

    fn expectUnchanged(self: *const TestInputSnapshot, input: *const builder.Builder) !void {
        try std.testing.expectEqual(self.code_len, input.code_len);
        try std.testing.expectEqual(self.atom_len, input.atom_len);
        try std.testing.expectEqual(self.label_len, input.label_len);
        try std.testing.expectEqual(self.reloc_len, input.reloc_len);
        try std.testing.expectEqual(self.source_len, input.source_len);
        try std.testing.expectEqual(self.last_opcode_pos, input.last_opcode_pos);
        try std.testing.expectEqualSlices(u8, self.code, input.code[0..input.code_len]);
        try std.testing.expectEqualSlices(
            core.atom.Atom,
            self.atoms,
            input.atom_operands[0..input.atom_len],
        );
        for (self.label_slots, input.label_slots[0..input.label_len]) |expected, actual| {
            try std.testing.expectEqual(expected.bound_offset, actual.bound_offset);
            try std.testing.expectEqual(expected.ref_count, actual.ref_count);
            try std.testing.expectEqual(expected.first_reloc, actual.first_reloc);
            try std.testing.expectEqualDeep(expected.flags, actual.flags);
        }
        for (self.relocs, input.relocs[0..input.reloc_len]) |expected, actual| {
            try std.testing.expectEqualDeep(expected, actual);
        }
        for (self.source_slots, input.source_slots[0..input.source_len]) |expected, actual| {
            try std.testing.expectEqualDeep(expected, actual);
        }
    }
};

fn runLegacyForComparison(
    function: *bytecode.Bytecode,
    fd: *bytecode.function_def.FunctionDef,
    code: []const u8,
    atom_operands: []const core.atom.Atom,
) !void {
    try function.setCode(code);
    for (atom_operands) |atom_id| try function.retainAtomOperand(atom_id);
    var ctx = legacy_pipeline.JSContext.initWithFunctionDef(function, fd);
    try legacy_pipeline.run(&ctx);
}

fn expectBindingRowsEqual(
    lhs: *const bytecode.function_def.FunctionDef,
    rhs: *const bytecode.function_def.FunctionDef,
) !void {
    try std.testing.expectEqual(lhs.vars.len, rhs.vars.len);
    for (lhs.vars, rhs.vars) |left, right| {
        try std.testing.expectEqual(left.var_name, right.var_name);
        try std.testing.expectEqual(left.scope_level, right.scope_level);
        try std.testing.expectEqual(left.is_lexical, right.is_lexical);
        try std.testing.expectEqual(left.is_const, right.is_const);
        try std.testing.expectEqual(left.is_captured, right.is_captured);
        try std.testing.expectEqual(left.var_kind, right.var_kind);
    }
    try std.testing.expectEqual(lhs.args.len, rhs.args.len);
    for (lhs.args, rhs.args) |left, right| {
        try std.testing.expectEqual(left.var_name, right.var_name);
        try std.testing.expectEqual(left.scope_level, right.scope_level);
        try std.testing.expectEqual(left.is_lexical, right.is_lexical);
        try std.testing.expectEqual(left.is_const, right.is_const);
        try std.testing.expectEqual(left.is_captured, right.is_captured);
        try std.testing.expectEqual(left.var_kind, right.var_kind);
    }
    try std.testing.expectEqual(lhs.closure_var.len, rhs.closure_var.len);
    for (lhs.closure_var, rhs.closure_var) |left, right| {
        try std.testing.expectEqual(left.var_name, right.var_name);
        try std.testing.expectEqual(left.closureType(), right.closureType());
        try std.testing.expectEqual(left.var_idx, right.var_idx);
        try std.testing.expectEqual(left.isLexical(), right.isLexical());
        try std.testing.expectEqual(left.isConst(), right.isConst());
        try std.testing.expectEqual(left.varKind(), right.varKind());
    }
}

fn normalizedLegacyResolveCode(code: []const u8) ![]u8 {
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(std.testing.allocator);
    var pc: usize = 0;
    while (pc < code.len) {
        const op_id = code[pc];
        const size: usize = if (op_id == op.label) 5 else opcode.sizeOf(op_id);
        if (size == 0 or pc + size > code.len) return error.InvalidBytecode;
        if (op_id != op.label and op_id != op.nop) {
            try normalized.appendSlice(std.testing.allocator, code[pc .. pc + size]);
        }
        pc += size;
    }
    return normalized.toOwnedSlice(std.testing.allocator);
}

fn expectOwnedAtomRelease(
    harness: *ResolveTestHarness,
    product: *ResolvedProduct,
    atom_id: core.atom.Atom,
) !void {
    for (product.atom_operands[0..product.atom_len]) |owned| {
        try std.testing.expectEqual(atom_id, owned);
    }
    for (harness.input().atom_operands[0..harness.input().atom_len]) |owned| {
        try std.testing.expectEqual(atom_id, owned);
    }

    const before_product = harness.rt.atoms.refCount(atom_id).?;
    const product_atom_len = product.atom_len;
    product.deinitUncommitted();
    try std.testing.expectEqual(
        before_product - product_atom_len,
        harness.rt.atoms.refCount(atom_id).?,
    );

    const before_input = harness.rt.atoms.refCount(atom_id).?;
    const input_atom_len = harness.input().atom_len;
    harness.deinitInput();
    try std.testing.expectEqual(
        before_input - input_atom_len,
        harness.rt.atoms.refCount(atom_id).?,
    );
}

test "compiler_v2.resolve_variables: copy-through and source carry" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    try input.addSourceMarker(10, 2);
    try input.emitOp(op.undefined);
    try input.addSourceMarker(10, 2);
    try input.emitOp(op.push_true);
    try input.addSourceMarker(20, 3);
    try input.emitOp(op.drop);

    const expected_input = [_]u8{ op.undefined, op.push_true, op.drop };
    var product = try harness.resolve();
    defer product.deinitUncommitted();

    try expectProductCode(&product, &expected_input);
    try std.testing.expectEqual(@as(u32, 2), product.source_len);
    try std.testing.expectEqual(@as(u32, 0), product.source_slots[0].temp_offset);
    try std.testing.expectEqual(@as(i32, 10), product.source_slots[0].line);
    try std.testing.expectEqual(@as(i32, 2), product.source_slots[0].col);
    try std.testing.expectEqual(@as(u32, 2), product.source_slots[1].temp_offset);
    try std.testing.expectEqual(@as(i32, 20), product.source_slots[1].line);
    try std.testing.expectEqual(@as(i32, 3), product.source_slots[1].col);
}

test "compiler_v2.resolve_variables: dead code resumes at a live label" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const live = try input.newLabel();
    try input.emitJump(op.if_false, live);
    try input.emitOp(op.return_undef);
    try input.emitOp(op.drop);
    try input.emitOp(op.drop);
    try input.bindLabel(live);
    try input.emitOp(op.undefined);
    try input.emitOp(op.return_undef);

    var expected = [_]u8{ op.if_false, 0, 0, 0, 0, op.return_undef, op.undefined, op.return_undef };
    std.mem.writeInt(u32, expected[1..5], live.index(), .little);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try expectProductCode(&product, &expected);
    try expectProductLabel(&product, live, 1, 6);
    try std.testing.expectEqual(@as(u32, 1), product.jump_size);
}

test "compiler_v2.resolve_variables: label referenced only by dead code stays dead" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const live = try input.newLabel();
    const dead = try input.newLabel();
    try input.emitJump(op.if_false, live);
    try input.emitOp(op.return_undef);
    try input.emitJump(op.goto, dead);
    try input.bindLabel(dead);
    try input.emitOp(op.drop);
    try input.bindLabel(live);
    try input.emitOp(op.return_undef);

    var expected = [_]u8{ op.if_false, 0, 0, 0, 0, op.return_undef, op.return_undef };
    std.mem.writeInt(u32, expected[1..5], live.index(), .little);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try expectProductCode(&product, &expected);
    try expectProductLabel(&product, dead, 0, labels.unbound);
    try expectProductLabel(&product, live, 1, 6);
    try std.testing.expectEqual(@as(u32, 1), product.jump_size);
}

test "compiler_v2.resolve_variables: dead self-loop is skipped through to live merge" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const dead_loop = try input.newLabel();
    const merge = try input.newLabel();
    try input.emitJump(op.if_false, merge);
    try input.emitOp(op.return_undef);
    try input.bindLabel(dead_loop);
    try input.emitJump(op.goto, dead_loop);
    try input.bindLabel(merge);
    try input.emitOp(op.return_undef);

    var expected = [_]u8{
        op.if_false,     0,               0, 0, 0,
        op.return_undef, op.return_undef,
    };
    std.mem.writeInt(u32, expected[1..5], merge.index(), .little);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try expectProductCode(&product, &expected);
    try expectProductLabel(&product, dead_loop, 0, labels.unbound);
    try expectProductLabel(&product, merge, 1, 6);
    try std.testing.expectEqual(@as(u32, 1), product.jump_size);
}

test "compiler_v2.resolve_variables: dead forward jump cannot retain another dead block" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const dead_source = try input.newLabel();
    const dead_target = try input.newLabel();
    const merge = try input.newLabel();
    try input.emitJump(op.if_false, merge);
    try input.emitOp(op.return_undef);
    try input.bindLabel(dead_source);
    try input.emitJump(op.goto, dead_target);
    try input.bindLabel(dead_target);
    try input.emitOp(op.drop);
    try input.bindLabel(merge);
    try input.emitOp(op.return_undef);

    var expected = [_]u8{
        op.if_false,     0,               0, 0, 0,
        op.return_undef, op.return_undef,
    };
    std.mem.writeInt(u32, expected[1..5], merge.index(), .little);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try expectProductCode(&product, &expected);
    try expectProductLabel(&product, dead_source, 0, labels.unbound);
    try expectProductLabel(&product, dead_target, 0, labels.unbound);
    try expectProductLabel(&product, merge, 1, 6);
    try std.testing.expectEqual(@as(u32, 1), product.jump_size);
}

test "compiler_v2.resolve_variables: scope_make_ref after terminal owns nothing" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();

    const local = try harness.rt.atoms.internString("qcp1-s3r-dead-make-ref");
    defer harness.rt.atoms.free(local);
    _ = try harness.fd.appendScope(-1);
    _ = try harness.fd.addScopeVar(local, .normal, 0, false, false);
    const base_refs = harness.rt.atoms.refCount(local).?;

    const put_tail = try harness.input().newLabel();
    try harness.input().emitOp(op.return_undef);
    try harness.input().emitScopeRefOpOwned(
        op.scope_make_ref,
        harness.rt.atoms.dup(local),
        put_tail,
        0,
    );
    try harness.input().bindLabel(put_tail);
    try harness.input().emitOp(op.nop);
    try harness.input().emitOp(op.put_ref_value);
    try std.testing.expectEqual(base_refs + 1, harness.rt.atoms.refCount(local).?);
    var snapshot = try TestInputSnapshot.init(harness.input());
    defer snapshot.deinit();

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try expectProductCode(&product, &.{op.return_undef});
    try std.testing.expectEqual(@as(u32, 0), product.atom_len);
    try expectProductLabel(&product, put_tail, 0, labels.unbound);
    try std.testing.expectEqual(@as(usize, 0), harness.fd.closure_var.len);
    try std.testing.expect(!harness.fd.vars[0].is_captured);
    try snapshot.expectUnchanged(harness.input());

    product.deinitUncommitted();
    try std.testing.expectEqual(base_refs + 1, harness.rt.atoms.refCount(local).?);
    harness.deinitInput();
    try std.testing.expectEqual(base_refs, harness.rt.atoms.refCount(local).?);
}

test "compiler_v2.resolve_variables: empty gosub finalizer removal and non-empty retention" {
    try requireCompilerV2();

    {
        var harness: ResolveTestHarness = undefined;
        try harness.init(std.testing.allocator);
        defer harness.deinit();
        const input = harness.input();

        const finalizer = try input.newLabel();
        try input.emitJump(op.gosub, finalizer);
        try input.emitOp(op.return_undef);
        try input.bindLabel(finalizer);
        try input.emitOp(op.ret);

        var product = try harness.resolve();
        defer product.deinitUncommitted();
        try expectProductCode(&product, &.{op.return_undef});
        try expectProductLabel(&product, finalizer, 0, labels.unbound);
        try std.testing.expectEqual(@as(u32, 1), product.jump_size);
    }

    {
        var harness: ResolveTestHarness = undefined;
        try harness.init(std.testing.allocator);
        defer harness.deinit();
        const input = harness.input();

        const finalizer = try input.newLabel();
        try input.emitJump(op.gosub, finalizer);
        try input.emitOp(op.return_undef);
        try input.bindLabel(finalizer);
        try input.emitOp(op.drop);
        try input.emitOp(op.ret);

        var expected = [_]u8{ op.gosub, 0, 0, 0, 0, op.return_undef, op.drop, op.ret };
        std.mem.writeInt(u32, expected[1..5], finalizer.index(), .little);

        var product = try harness.resolve();
        defer product.deinitUncommitted();
        try expectProductCode(&product, &expected);
        try expectProductLabel(&product, finalizer, 1, 6);
        try std.testing.expectEqual(@as(u32, 1), product.jump_size);
    }
}

test "compiler_v2.resolve_variables: set_name null drops and named atom copies" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const named = try harness.rt.atoms.internString("qcp1-s3-set-name");
    defer harness.rt.atoms.free(named);
    const base_refs = harness.rt.atoms.refCount(named).?;

    try input.emitAtomOpOwned(op.set_name, core.atom.null_atom);
    try input.emitAtomOpOwned(op.set_name, harness.rt.atoms.dup(named));
    try std.testing.expectEqual(base_refs + 1, harness.rt.atoms.refCount(named).?);

    var expected = [_]u8{ op.set_name, 0, 0, 0, 0 };
    std.mem.writeInt(u32, expected[1..5], named, .little);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try expectProductCode(&product, &expected);
    try std.testing.expectEqualSlices(core.atom.Atom, &.{named}, product.atom_operands[0..product.atom_len]);
    try std.testing.expectEqual(base_refs + 2, harness.rt.atoms.refCount(named).?);

    product.deinitUncommitted();
    try std.testing.expectEqual(base_refs + 1, harness.rt.atoms.refCount(named).?);
    harness.deinitInput();
    try std.testing.expectEqual(base_refs, harness.rt.atoms.refCount(named).?);
}

test "compiler_v2.resolve_variables: erased temp ops and optional-chain rewrites" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const field = try harness.rt.atoms.internString("qcp1-s3-field");
    defer harness.rt.atoms.free(field);
    const base_refs = harness.rt.atoms.refCount(field).?;

    try input.emitOp(op.nop);
    try input.emitOpU32(op.set_class_name, 0x1234_5678);
    try input.emitAtomOpOwned(op.get_field_opt_chain, harness.rt.atoms.dup(field));
    try input.emitOp(op.get_array_el_opt_chain);

    var expected = [_]u8{ op.get_field, 0, 0, 0, 0, op.get_array_el };
    std.mem.writeInt(u32, expected[1..5], field, .little);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try expectProductCode(&product, &expected);
    try std.testing.expectEqualSlices(core.atom.Atom, &.{field}, product.atom_operands[0..product.atom_len]);
    try std.testing.expectEqual(base_refs + 2, harness.rt.atoms.refCount(field).?);

    product.deinitUncommitted();
    try std.testing.expectEqual(base_refs + 1, harness.rt.atoms.refCount(field).?);
    harness.deinitInput();
    try std.testing.expectEqual(base_refs, harness.rt.atoms.refCount(field).?);
}

test "compiler_v2.resolve_variables: insert3 fold recognizes both put variants" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    try input.emitOp(op.insert3);
    try input.emitOp(op.put_array_el);
    try input.emitOp(op.drop);
    try input.emitOp(op.insert3);
    try input.emitOp(op.put_ref_value);
    try input.emitOp(op.drop);
    try input.emitOp(op.insert3);
    try input.emitOp(op.undefined);
    try input.emitOp(op.drop);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try expectProductCode(
        &product,
        &.{ op.put_array_el, op.put_ref_value, op.insert3, op.undefined, op.drop },
    );
}

test "compiler_v2.resolve_variables: dup branch fold preserves precomputed live block" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const first = try input.newLabel();
    const target = try input.newLabel();
    try input.emitOp(op.dup);
    try input.emitJump(op.if_false, first);
    try input.emitOp(op.drop);
    try input.emitOp(op.return_undef);
    try input.bindLabel(first);
    try input.emitJump(op.if_false, target);
    try input.emitOp(op.return_undef);
    try input.bindLabel(target);
    try input.emitOp(op.return_undef);

    // The fold moves the first branch reference to target, but the exact CFG
    // was intentionally computed before the walk. The originally reachable
    // `first` block therefore remains live and is copied; only its zero-ref
    // label position is suppressed for Stage 4 bookkeeping.
    var expected = [_]u8{
        op.if_false,     0,               0,               0, 0,
        op.return_undef, op.if_false,     0,               0, 0,
        0,               op.return_undef, op.return_undef,
    };
    std.mem.writeInt(u32, expected[1..5], target.index(), .little);
    std.mem.writeInt(u32, expected[7..11], target.index(), .little);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try expectProductCode(&product, &expected);
    try expectProductLabel(&product, first, 0, labels.unbound);
    try expectProductLabel(&product, target, 2, 12);
    try std.testing.expectEqual(@as(u32, 2), product.jump_size);
}

test "compiler_v2.resolve_variables: scope_get_var global reuses legacy topology" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const scoped_name = try harness.rt.atoms.internString("qcp1-s3-global");
    defer harness.rt.atoms.free(scoped_name);
    const base_refs = harness.rt.atoms.refCount(scoped_name).?;
    try input.emitAtomOpU16Owned(
        op.scope_get_var,
        harness.rt.atoms.dup(scoped_name),
        0,
    );
    try input.emitOp(op.return_undef);
    var snapshot = try TestInputSnapshot.init(input);
    defer snapshot.deinit();

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    var expected = [_]u8{ op.get_var, 0, 0, op.return_undef };
    std.mem.writeInt(u16, expected[1..3], 0, .little);
    try expectProductCode(&product, &expected);
    try std.testing.expectEqual(@as(u32, 0), product.atom_len);
    try std.testing.expectEqual(@as(usize, 1), harness.fd.closure_var.len);
    try std.testing.expectEqual(scoped_name, harness.fd.closure_var[0].var_name);
    try std.testing.expectEqual(
        bytecode.function_def.ClosureType.global,
        harness.fd.closure_var[0].closureType(),
    );

    try snapshot.expectUnchanged(input);
    try std.testing.expectEqual(base_refs + 2, harness.rt.atoms.refCount(scoped_name).?);
    try expectOwnedAtomRelease(&harness, &product, scoped_name);
    try std.testing.expectEqual(base_refs + 1, harness.rt.atoms.refCount(scoped_name).?);
}

test "compiler_v2.resolve_variables: local scope_get_var equals legacy" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    harness.fd.use_short_opcodes = true;

    const x = try harness.rt.atoms.internString("qcp1-s3-local-x");
    defer harness.rt.atoms.free(x);
    _ = try harness.fd.appendScope(-1);
    _ = try harness.fd.addScopeVar(x, .normal, 0, false, false);
    try harness.input().emitAtomOpU16Owned(op.scope_get_var, harness.rt.atoms.dup(x), 0);
    try harness.input().emitOp(op.return_undef);
    var snapshot = try TestInputSnapshot.init(harness.input());
    defer snapshot.deinit();

    var legacy_function = bytecode.Bytecode.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_function.deinit(harness.rt);
    var legacy_fd = bytecode.function_def.FunctionDef.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_fd.deinit(harness.rt);
    legacy_fd.use_short_opcodes = true;
    _ = try legacy_fd.appendScope(-1);
    _ = try legacy_fd.addScopeVar(x, .normal, 0, false, false);
    var legacy_input = [_]u8{ op.scope_get_var, 0, 0, 0, 0, 0, 0, op.return_undef };
    std.mem.writeInt(u32, legacy_input[1..5], x, .little);
    try runLegacyForComparison(&legacy_function, &legacy_fd, &legacy_input, &.{x});

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(op.get_loc0, product.code[0]);
    try expectProductCode(&product, legacy_function.code);
    try expectBindingRowsEqual(&harness.fd, &legacy_fd);
    try snapshot.expectUnchanged(harness.input());
    try expectOwnedAtomRelease(&harness, &product, x);
}

test "compiler_v2.resolve_variables: argument scope_get_var equals legacy" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    harness.fd.use_short_opcodes = true;

    const argument = try harness.rt.atoms.internString("qcp1-s3-argument-a");
    defer harness.rt.atoms.free(argument);
    _ = try harness.fd.appendScope(-1);
    _ = try harness.fd.appendArg(.{ .var_name = argument, .scope_level = 0 });
    try harness.input().emitAtomOpU16Owned(
        op.scope_get_var,
        harness.rt.atoms.dup(argument),
        0,
    );
    try harness.input().emitOp(op.return_undef);
    var snapshot = try TestInputSnapshot.init(harness.input());
    defer snapshot.deinit();

    var legacy_function = bytecode.Bytecode.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_function.deinit(harness.rt);
    var legacy_fd = bytecode.function_def.FunctionDef.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_fd.deinit(harness.rt);
    legacy_fd.use_short_opcodes = true;
    _ = try legacy_fd.appendScope(-1);
    _ = try legacy_fd.appendArg(.{ .var_name = argument, .scope_level = 0 });
    var legacy_input = [_]u8{ op.scope_get_var, 0, 0, 0, 0, 0, 0, op.return_undef };
    std.mem.writeInt(u32, legacy_input[1..5], argument, .little);
    try runLegacyForComparison(&legacy_function, &legacy_fd, &legacy_input, &.{argument});

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(op.get_arg0, product.code[0]);
    try expectProductCode(&product, legacy_function.code);
    try expectBindingRowsEqual(&harness.fd, &legacy_fd);
    try snapshot.expectUnchanged(harness.input());
    try expectOwnedAtomRelease(&harness, &product, argument);
}

test "compiler_v2.resolve_variables: lexical TDZ get and put equal legacy" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    harness.fd.use_short_opcodes = true;

    const lexical = try harness.rt.atoms.internString("qcp1-s3-lexical-tdz");
    defer harness.rt.atoms.free(lexical);
    _ = try harness.fd.appendScope(-1);
    _ = try harness.fd.addScopeVar(lexical, .normal, 0, true, false);
    try harness.input().emitAtomOpU16Owned(
        op.scope_get_var,
        harness.rt.atoms.dup(lexical),
        0,
    );
    try harness.input().emitAtomOpU16Owned(
        op.scope_put_var,
        harness.rt.atoms.dup(lexical),
        0,
    );
    try harness.input().emitOp(op.return_undef);
    var snapshot = try TestInputSnapshot.init(harness.input());
    defer snapshot.deinit();

    var legacy_function = bytecode.Bytecode.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_function.deinit(harness.rt);
    var legacy_fd = bytecode.function_def.FunctionDef.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_fd.deinit(harness.rt);
    legacy_fd.use_short_opcodes = true;
    _ = try legacy_fd.appendScope(-1);
    _ = try legacy_fd.addScopeVar(lexical, .normal, 0, true, false);
    var legacy_input = [_]u8{0} ** 15;
    legacy_input[0] = op.scope_get_var;
    std.mem.writeInt(u32, legacy_input[1..5], lexical, .little);
    legacy_input[7] = op.scope_put_var;
    std.mem.writeInt(u32, legacy_input[8..12], lexical, .little);
    legacy_input[14] = op.return_undef;
    try runLegacyForComparison(
        &legacy_function,
        &legacy_fd,
        &legacy_input,
        &.{ lexical, lexical },
    );

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(op.get_loc_check, product.code[0]);
    try std.testing.expectEqual(op.put_loc_check, product.code[3]);
    try expectProductCode(&product, legacy_function.code);
    try expectBindingRowsEqual(&harness.fd, &legacy_fd);
    try snapshot.expectUnchanged(harness.input());
    try expectOwnedAtomRelease(&harness, &product, lexical);
}

test "compiler_v2.resolve_variables: const scope_put_var throw equals legacy" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    harness.fd.use_short_opcodes = true;

    const constant = try harness.rt.atoms.internString("qcp1-s3-const");
    defer harness.rt.atoms.free(constant);
    _ = try harness.fd.appendScope(-1);
    _ = try harness.fd.addScopeVar(constant, .normal, 0, true, true);
    try harness.input().emitAtomOpU16Owned(
        op.scope_put_var,
        harness.rt.atoms.dup(constant),
        0,
    );
    try harness.input().emitOp(op.return_undef);
    var snapshot = try TestInputSnapshot.init(harness.input());
    defer snapshot.deinit();

    var legacy_function = bytecode.Bytecode.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_function.deinit(harness.rt);
    var legacy_fd = bytecode.function_def.FunctionDef.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_fd.deinit(harness.rt);
    legacy_fd.use_short_opcodes = true;
    _ = try legacy_fd.appendScope(-1);
    _ = try legacy_fd.addScopeVar(constant, .normal, 0, true, true);
    var legacy_input = [_]u8{ op.scope_put_var, 0, 0, 0, 0, 0, 0, op.return_undef };
    std.mem.writeInt(u32, legacy_input[1..5], constant, .little);
    try runLegacyForComparison(&legacy_function, &legacy_fd, &legacy_input, &.{constant});

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(op.throw_error, product.code[0]);
    try std.testing.expectEqual(@as(u32, 1), product.atom_len);
    try expectProductCode(&product, legacy_function.code);
    try std.testing.expectEqualSlices(
        core.atom.Atom,
        legacy_function.atom_operands,
        product.atom_operands[0..product.atom_len],
    );
    try expectBindingRowsEqual(&harness.fd, &legacy_fd);
    try snapshot.expectUnchanged(harness.input());
    try expectOwnedAtomRelease(&harness, &product, constant);
}

test "compiler_v2.resolve_variables: lexical scope_put_var_init equals legacy" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    harness.fd.use_short_opcodes = true;

    const lexical = try harness.rt.atoms.internString("qcp1-s3-lexical-init");
    defer harness.rt.atoms.free(lexical);
    _ = try harness.fd.appendScope(-1);
    _ = try harness.fd.addScopeVar(lexical, .normal, 0, true, false);
    try harness.input().emitAtomOpU16Owned(
        op.scope_put_var_init,
        harness.rt.atoms.dup(lexical),
        0,
    );
    try harness.input().emitOp(op.return_undef);
    var snapshot = try TestInputSnapshot.init(harness.input());
    defer snapshot.deinit();

    var legacy_function = bytecode.Bytecode.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_function.deinit(harness.rt);
    var legacy_fd = bytecode.function_def.FunctionDef.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_fd.deinit(harness.rt);
    legacy_fd.use_short_opcodes = true;
    _ = try legacy_fd.appendScope(-1);
    _ = try legacy_fd.addScopeVar(lexical, .normal, 0, true, false);
    var legacy_input = [_]u8{ op.scope_put_var_init, 0, 0, 0, 0, 0, 0, op.return_undef };
    std.mem.writeInt(u32, legacy_input[1..5], lexical, .little);
    try runLegacyForComparison(&legacy_function, &legacy_fd, &legacy_input, &.{lexical});

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(op.put_loc0, product.code[0]);
    try expectProductCode(&product, legacy_function.code);
    try expectBindingRowsEqual(&harness.fd, &legacy_fd);
    try snapshot.expectUnchanged(harness.input());
    try expectOwnedAtomRelease(&harness, &product, lexical);
}

test "compiler_v2.resolve_variables: enter and leave scope equal legacy" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();

    const captured = try harness.rt.atoms.internString("qcp1-s3-captured-lexical");
    defer harness.rt.atoms.free(captured);
    _ = try harness.fd.appendScope(-1);
    const local_index = try harness.fd.addScopeVar(captured, .normal, 0, true, false);
    try harness.fd.captureLocal(@intCast(local_index));
    try harness.input().emitOpU16(op.enter_scope, 0);
    try harness.input().emitOpU16(op.leave_scope, 0);
    try harness.input().emitOp(op.return_undef);
    var snapshot = try TestInputSnapshot.init(harness.input());
    defer snapshot.deinit();

    var legacy_function = bytecode.Bytecode.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_function.deinit(harness.rt);
    var legacy_fd = bytecode.function_def.FunctionDef.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_fd.deinit(harness.rt);
    _ = try legacy_fd.appendScope(-1);
    const legacy_local_index = try legacy_fd.addScopeVar(captured, .normal, 0, true, false);
    try legacy_fd.captureLocal(@intCast(legacy_local_index));
    var legacy_input = [_]u8{
        op.enter_scope,  0, 0,
        op.leave_scope,  0, 0,
        op.return_undef,
    };
    try runLegacyForComparison(&legacy_function, &legacy_fd, &legacy_input, &.{});

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(op.set_loc_uninitialized, product.code[0]);
    try std.testing.expectEqual(op.close_loc, product.code[3]);
    try expectProductCode(&product, legacy_function.code);
    try expectBindingRowsEqual(&harness.fd, &legacy_fd);
    try snapshot.expectUnchanged(harness.input());
    try expectOwnedAtomRelease(&harness, &product, captured);
}

test "compiler_v2.resolve_variables: apply_eval scope head equals legacy" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();

    const captured = try harness.rt.atoms.internString("qcp1-s3-eval-captured");
    defer harness.rt.atoms.free(captured);
    _ = try harness.fd.appendScope(-1);
    for (0..255) |_| {
        _ = try harness.fd.addScopeVar(captured, .normal, 0, false, false);
    }
    try harness.input().emitOpU16(op.apply_eval, 0);
    try harness.input().emitOp(op.return_undef);
    var snapshot = try TestInputSnapshot.init(harness.input());
    defer snapshot.deinit();

    var legacy_function = bytecode.Bytecode.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_function.deinit(harness.rt);
    var legacy_fd = bytecode.function_def.FunctionDef.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_fd.deinit(harness.rt);
    _ = try legacy_fd.appendScope(-1);
    for (0..255) |_| {
        _ = try legacy_fd.addScopeVar(captured, .normal, 0, false, false);
    }
    const legacy_input = [_]u8{ op.apply_eval, 0, 0, op.return_undef };
    try runLegacyForComparison(&legacy_function, &legacy_fd, &legacy_input, &.{});

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(@as(u32, 4), product.code_len);
    try std.testing.expectEqual(
        @as(u16, 256),
        std.mem.readInt(u16, product.code[1..3], .little),
    );
    try expectProductCode(&product, legacy_function.code);
    try expectBindingRowsEqual(&harness.fd, &legacy_fd);
    try snapshot.expectUnchanged(harness.input());
    try expectOwnedAtomRelease(&harness, &product, captured);
}

test "compiler_v2.resolve_variables: local scope_make_ref fold equals legacy" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    harness.fd.use_short_opcodes = true;

    const local = try harness.rt.atoms.internString("qcp1-s3-make-ref-fold");
    defer harness.rt.atoms.free(local);
    _ = try harness.fd.appendScope(-1);
    _ = try harness.fd.addScopeVar(local, .normal, 0, false, false);
    const tail = try harness.input().newLabel();
    try harness.input().emitScopeRefOpOwned(
        op.scope_make_ref,
        harness.rt.atoms.dup(local),
        tail,
        0,
    );
    try harness.input().emitOp(op.get_ref_value);
    try harness.input().bindLabel(tail);
    try harness.input().emitOp(op.nop);
    try harness.input().emitOp(op.put_ref_value);
    try harness.input().emitOp(op.return_undef);
    var snapshot = try TestInputSnapshot.init(harness.input());
    defer snapshot.deinit();

    var legacy_function = bytecode.Bytecode.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_function.deinit(harness.rt);
    var legacy_fd = bytecode.function_def.FunctionDef.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_fd.deinit(harness.rt);
    legacy_fd.use_short_opcodes = true;
    _ = try legacy_fd.appendScope(-1);
    _ = try legacy_fd.addScopeVar(local, .normal, 0, false, false);
    var legacy_input = [_]u8{0} ** 20;
    legacy_input[0] = op.scope_make_ref;
    std.mem.writeInt(u32, legacy_input[1..5], local, .little);
    std.mem.writeInt(u32, legacy_input[5..9], 17, .little);
    legacy_input[11] = op.get_ref_value;
    legacy_input[12] = op.label;
    std.mem.writeInt(u32, legacy_input[13..17], 1, .little);
    legacy_input[17] = op.nop;
    legacy_input[18] = op.put_ref_value;
    legacy_input[19] = op.return_undef;
    try runLegacyForComparison(&legacy_function, &legacy_fd, &legacy_input, &.{local});
    const normalized_legacy = try normalizedLegacyResolveCode(legacy_function.code);
    defer std.testing.allocator.free(normalized_legacy);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try expectProductCode(&product, &.{ op.get_loc0, op.put_loc0, op.return_undef });
    try std.testing.expectEqualSlices(u8, normalized_legacy, product.code[0..product.code_len]);
    try expectProductLabel(&product, tail, 0, 1);
    try std.testing.expect(!harness.fd.vars[0].is_captured);
    try expectBindingRowsEqual(&harness.fd, &legacy_fd);
    try snapshot.expectUnchanged(harness.input());
    try expectOwnedAtomRelease(&harness, &product, local);
}

test "compiler_v2.resolve_variables: local scope_make_ref non-fold equals legacy" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    harness.fd.use_short_opcodes = true;

    const local = try harness.rt.atoms.internString("qcp1-s3-make-ref-live");
    defer harness.rt.atoms.free(local);
    _ = try harness.fd.appendScope(-1);
    _ = try harness.fd.addScopeVar(local, .normal, 0, false, false);
    const tail = try harness.input().newLabel();
    try harness.input().emitScopeRefOpOwned(
        op.scope_make_ref,
        harness.rt.atoms.dup(local),
        tail,
        0,
    );
    try harness.input().bindLabel(tail);
    try harness.input().emitOp(op.undefined);
    try harness.input().emitOp(op.put_ref_value);
    try harness.input().emitOp(op.return_undef);
    var snapshot = try TestInputSnapshot.init(harness.input());
    defer snapshot.deinit();

    var legacy_function = bytecode.Bytecode.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_function.deinit(harness.rt);
    var legacy_fd = bytecode.function_def.FunctionDef.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_fd.deinit(harness.rt);
    legacy_fd.use_short_opcodes = true;
    _ = try legacy_fd.appendScope(-1);
    _ = try legacy_fd.addScopeVar(local, .normal, 0, false, false);
    var legacy_input = [_]u8{0} ** 19;
    legacy_input[0] = op.scope_make_ref;
    std.mem.writeInt(u32, legacy_input[1..5], local, .little);
    std.mem.writeInt(u32, legacy_input[5..9], 16, .little);
    legacy_input[11] = op.label;
    std.mem.writeInt(u32, legacy_input[12..16], 1, .little);
    legacy_input[16] = op.undefined;
    legacy_input[17] = op.put_ref_value;
    legacy_input[18] = op.return_undef;
    try runLegacyForComparison(&legacy_function, &legacy_fd, &legacy_input, &.{local});
    const normalized_legacy = try normalizedLegacyResolveCode(legacy_function.code);
    defer std.testing.allocator.free(normalized_legacy);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(op.make_loc_ref, product.code[0]);
    try std.testing.expectEqualSlices(u8, normalized_legacy, product.code[0..product.code_len]);
    try std.testing.expectEqual(@as(u32, 1), product.atom_len);
    try std.testing.expectEqual(local, product.atom_operands[0]);
    try expectProductLabel(&product, tail, 0, 7);
    try std.testing.expect(harness.fd.vars[0].is_captured);
    try expectBindingRowsEqual(&harness.fd, &legacy_fd);
    try snapshot.expectUnchanged(harness.input());
    try expectOwnedAtomRelease(&harness, &product, local);
}

test "compiler_v2.resolve_variables: dynamic environment probe uses product label" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    harness.fd.use_short_opcodes = true;

    const dynamic_name = try harness.rt.atoms.internString("qcp1-s3-dynamic-name");
    defer harness.rt.atoms.free(dynamic_name);
    _ = try harness.fd.appendScope(-1);
    harness.fd.var_object_idx = try harness.fd.addScopeVar(
        core.atom.ids.var_object,
        .normal,
        0,
        false,
        false,
    );
    try harness.input().emitAtomOpU16Owned(
        op.scope_get_var,
        harness.rt.atoms.dup(dynamic_name),
        0,
    );
    try harness.input().emitOp(op.return_undef);
    var snapshot = try TestInputSnapshot.init(harness.input());
    defer snapshot.deinit();

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(op.get_loc0, product.code[0]);
    try std.testing.expectEqual(op.with_get_var, product.code[1]);
    try std.testing.expectEqual(
        dynamic_name,
        std.mem.readInt(u32, product.code[2..6], .little),
    );
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, product.code[6..10], .little));
    try std.testing.expectEqual(@as(u8, 0), product.code[10]);
    try std.testing.expectEqual(op.get_var, product.code[11]);
    try std.testing.expectEqual(op.return_undef, product.code[14]);
    try std.testing.expectEqual(@as(u32, 1), product.jump_size);
    try std.testing.expectEqual(@as(u32, 1), product.atom_len);
    try std.testing.expectEqual(dynamic_name, product.atom_operands[0]);
    try expectProductLabel(&product, @enumFromInt(0), 1, 14);
    try snapshot.expectUnchanged(harness.input());
    try expectOwnedAtomRelease(&harness, &product, dynamic_name);
}

test "compiler_v2.resolve_variables: scope delete and get_ref equal legacy" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();

    const global = try harness.rt.atoms.internString("qcp1-s3-ref-global");
    defer harness.rt.atoms.free(global);
    _ = try harness.fd.appendScope(-1);
    try harness.input().emitAtomOpU16Owned(
        op.scope_delete_var,
        harness.rt.atoms.dup(global),
        0,
    );
    try harness.input().emitAtomOpU16Owned(
        op.scope_get_ref,
        harness.rt.atoms.dup(global),
        0,
    );
    try harness.input().emitOp(op.return_undef);
    var snapshot = try TestInputSnapshot.init(harness.input());
    defer snapshot.deinit();

    var legacy_function = bytecode.Bytecode.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_function.deinit(harness.rt);
    var legacy_fd = bytecode.function_def.FunctionDef.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_fd.deinit(harness.rt);
    _ = try legacy_fd.appendScope(-1);
    var legacy_input = [_]u8{0} ** 15;
    legacy_input[0] = op.scope_delete_var;
    std.mem.writeInt(u32, legacy_input[1..5], global, .little);
    legacy_input[7] = op.scope_get_ref;
    std.mem.writeInt(u32, legacy_input[8..12], global, .little);
    legacy_input[14] = op.return_undef;
    try runLegacyForComparison(
        &legacy_function,
        &legacy_fd,
        &legacy_input,
        &.{ global, global },
    );

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(op.delete_var, product.code[0]);
    try std.testing.expectEqual(op.undefined, product.code[5]);
    try std.testing.expectEqual(op.get_var, product.code[6]);
    try expectProductCode(&product, legacy_function.code);
    try std.testing.expectEqualSlices(
        core.atom.Atom,
        legacy_function.atom_operands,
        product.atom_operands[0..product.atom_len],
    );
    try expectBindingRowsEqual(&harness.fd, &legacy_fd);
    try snapshot.expectUnchanged(harness.input());
    try expectOwnedAtomRelease(&harness, &product, global);
}

test "compiler_v2.resolve_variables: private field resolution equals legacy" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    harness.fd.use_short_opcodes = true;

    const private_name = try harness.rt.atoms.internString("#qcp1-s3-private");
    defer harness.rt.atoms.free(private_name);
    _ = try harness.fd.appendScope(-1);
    _ = try harness.fd.addScopeVar(private_name, .private_field, 0, true, false);
    try harness.input().emitAtomOpU16Owned(
        op.scope_get_private_field,
        harness.rt.atoms.dup(private_name),
        0,
    );
    try harness.input().emitOp(op.return_undef);
    var snapshot = try TestInputSnapshot.init(harness.input());
    defer snapshot.deinit();

    var legacy_function = bytecode.Bytecode.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_function.deinit(harness.rt);
    var legacy_fd = bytecode.function_def.FunctionDef.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_fd.deinit(harness.rt);
    legacy_fd.use_short_opcodes = true;
    _ = try legacy_fd.appendScope(-1);
    _ = try legacy_fd.addScopeVar(private_name, .private_field, 0, true, false);
    var legacy_input = [_]u8{
        op.scope_get_private_field, 0, 0, 0, 0, 0, 0,
        op.return_undef,
    };
    std.mem.writeInt(u32, legacy_input[1..5], private_name, .little);
    try runLegacyForComparison(&legacy_function, &legacy_fd, &legacy_input, &.{private_name});

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(op.get_loc0, product.code[0]);
    try std.testing.expectEqual(op.get_private_field, product.code[1]);
    try expectProductCode(&product, legacy_function.code);
    try expectBindingRowsEqual(&harness.fd, &legacy_fd);
    try snapshot.expectUnchanged(harness.input());
    try expectOwnedAtomRelease(&harness, &product, private_name);
}

test "compiler_v2.resolve_variables: direct eval redeclaration prefix equals legacy" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();

    const redeclared = try harness.rt.atoms.internString("qcp1-s3-eval-redecl");
    defer harness.rt.atoms.free(redeclared);
    harness.fd.is_direct_eval = true;
    _ = try harness.fd.addClosureVar(.{
        .closure_type = .ref,
        .is_lexical = true,
        .var_idx = 0,
        .var_name = redeclared,
    });
    try harness.fd.appendGlobalVar(.{
        .cpool_idx = -1,
        .scope_level = 0,
        .var_name = redeclared,
    });
    try harness.input().emitOp(op.return_undef);
    var snapshot = try TestInputSnapshot.init(harness.input());
    defer snapshot.deinit();

    var legacy_function = bytecode.Bytecode.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_function.deinit(harness.rt);
    var legacy_fd = bytecode.function_def.FunctionDef.init(
        &harness.rt.memory,
        &harness.rt.atoms,
        harness.name_atom,
    );
    defer legacy_fd.deinit(harness.rt);
    legacy_fd.is_direct_eval = true;
    _ = try legacy_fd.addClosureVar(.{
        .closure_type = .ref,
        .is_lexical = true,
        .var_idx = 0,
        .var_name = redeclared,
    });
    try legacy_fd.appendGlobalVar(.{
        .cpool_idx = -1,
        .scope_level = 0,
        .var_name = redeclared,
    });
    try runLegacyForComparison(
        &legacy_function,
        &legacy_fd,
        &.{op.return_undef},
        &.{},
    );

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(op.throw_error, product.code[0]);
    try std.testing.expectEqual(redeclared, std.mem.readInt(u32, product.code[1..5], .little));
    try std.testing.expectEqual(op.return_undef, product.code[6]);
    try expectProductCode(&product, legacy_function.code);
    try std.testing.expectEqualSlices(
        core.atom.Atom,
        legacy_function.atom_operands,
        product.atom_operands[0..product.atom_len],
    );
    try snapshot.expectUnchanged(harness.input());
    try expectOwnedAtomRelease(&harness, &product, redeclared);
}

test "compiler_v2.resolve_variables: deep logical chain falls back without error" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    var chain_labels: [22]labels.LabelId = undefined;
    for (&chain_labels) |*label| label.* = try input.newLabel();
    const done = try input.newLabel();
    try input.emitOp(op.dup);
    try input.emitJump(op.if_false, chain_labels[0]);
    try input.emitOp(op.drop);
    for (chain_labels[0..21], chain_labels[1..22]) |current, next| {
        try input.bindLabel(current);
        try input.emitOp(op.dup);
        try input.emitJump(op.if_false, next);
        try input.emitOp(op.drop);
    }
    try input.bindLabel(chain_labels[21]);
    try input.emitJump(op.if_false, done);
    try input.bindLabel(done);
    try input.emitOp(op.return_undef);
    var snapshot = try TestInputSnapshot.init(input);
    defer snapshot.deinit();

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(op.dup, product.code[0]);
    try snapshot.expectUnchanged(input);
}

fn expectOomInputUnchanged(
    input: *const builder.Builder,
    code_len: u32,
    atom_len: u32,
    source_len: u32,
    first_ref_count: u32,
    second_ref_count: u32,
) !void {
    try std.testing.expectEqual(code_len, input.code_len);
    try std.testing.expectEqual(atom_len, input.atom_len);
    try std.testing.expectEqual(source_len, input.source_len);
    try std.testing.expectEqual(first_ref_count, input.label_slots[0].ref_count);
    try std.testing.expectEqual(second_ref_count, input.label_slots[1].ref_count);
}

fn resolveVariablesOomScript(allocator: std.mem.Allocator) !void {
    var harness: ResolveTestHarness = undefined;
    try harness.init(allocator);
    defer harness.deinit();
    const input = harness.input();

    const live_atom = try harness.rt.atoms.internString("qcp1-s3-oom-live");
    defer harness.rt.atoms.free(live_atom);
    const dead_atom = try harness.rt.atoms.internString("qcp1-s3-oom-dead");
    defer harness.rt.atoms.free(dead_atom);
    const live_atom_base_refs = harness.rt.atoms.refCount(live_atom).?;
    const dead_atom_base_refs = harness.rt.atoms.refCount(dead_atom).?;

    const live_label = try input.newLabel();
    const dead_label = try input.newLabel();
    var atom_emit_index: u8 = 0;
    while (atom_emit_index < 10) : (atom_emit_index += 1) {
        try input.addSourceMarker(100 + atom_emit_index, 1);
        try input.emitAtomOpOwned(op.push_atom_value, harness.rt.atoms.dup(live_atom));
    }
    try input.emitJump(op.if_false, live_label);
    try input.emitOp(op.return_undef);
    try input.addSourceMarker(200, 2);
    try input.emitAtomOpOwned(op.push_atom_value, harness.rt.atoms.dup(dead_atom));
    try input.emitJump(op.goto, dead_label);
    try input.bindLabel(dead_label);
    try input.emitOp(op.drop);
    try input.bindLabel(live_label);
    try input.addSourceMarker(300, 3);
    try input.emitAtomOpOwned(op.get_field_opt_chain, harness.rt.atoms.dup(live_atom));
    try input.emitOp(op.return_undef);

    const code_len = input.code_len;
    const atom_len = input.atom_len;
    const source_len = input.source_len;
    const live_label_refs = input.label_slots[live_label.index()].ref_count;
    const dead_label_refs = input.label_slots[dead_label.index()].ref_count;
    const live_atom_refs = harness.rt.atoms.refCount(live_atom).?;
    const dead_atom_refs = harness.rt.atoms.refCount(dead_atom).?;

    var product = harness.resolve() catch |err| {
        try expectOomInputUnchanged(
            input,
            code_len,
            atom_len,
            source_len,
            live_label_refs,
            dead_label_refs,
        );
        try std.testing.expectEqual(live_atom_refs, harness.rt.atoms.refCount(live_atom).?);
        try std.testing.expectEqual(dead_atom_refs, harness.rt.atoms.refCount(dead_atom).?);
        harness.deinitInput();
        try std.testing.expectEqual(live_atom_base_refs, harness.rt.atoms.refCount(live_atom).?);
        try std.testing.expectEqual(dead_atom_base_refs, harness.rt.atoms.refCount(dead_atom).?);
        return err;
    };
    defer product.deinitUncommitted();

    try expectOomInputUnchanged(
        input,
        code_len,
        atom_len,
        source_len,
        live_label_refs,
        dead_label_refs,
    );
    product.deinitUncommitted();
    try std.testing.expectEqual(live_atom_refs, harness.rt.atoms.refCount(live_atom).?);
    try std.testing.expectEqual(dead_atom_refs, harness.rt.atoms.refCount(dead_atom).?);
    harness.deinitInput();
    try std.testing.expectEqual(live_atom_base_refs, harness.rt.atoms.refCount(live_atom).?);
    try std.testing.expectEqual(dead_atom_base_refs, harness.rt.atoms.refCount(dead_atom).?);
}

test "compiler_v2.resolve_variables: allocation failure sweep is transactional" {
    try requireCompilerV2();
    try resolveVariablesOomScript(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        resolveVariablesOomScript,
        .{},
    );
}

test {
    _ = ResolvedProduct;
}
