//! QCP-1 compiler-v2 Stage 3: identity-native variable resolution with exact
//! block-CFG liveness.
//!
//! Pass A builds one immutable LabelId CFG from the read-only Builder, then
//! establishes the transactional output, short-form label bookkeeping, atom
//! ownership, source carry, and the simple QuickJS rewrites. Pass B keeps that
//! pass structure while delegating every binding decision and lowering writer
//! to the legacy resolver's curated reuse surface.

const std = @import("std");
const core = @import("../core/root.zig");
const bytecode = @import("../bytecode.zig");
const builder = @import("builder.zig");
const cfg = @import("cfg.zig");
const labels = @import("labels.zig");

const opcode = bytecode.opcode;
const op = opcode.op;
const legacy_pipeline = bytecode.pipeline_resolve_variables;
const legacy = legacy_pipeline.v2;

const audit_oracles = cfg.audit_oracles;

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

    /// RELEASE AT THE CONSUMPTION POINT: the S4 walk is the last reader of the
    /// resolved stream, the atom ledger and the source markers. They become
    /// inert here (slices empty, capacity 0, owned atom refs released item-wise)
    /// while `label_slots` stays live, because S4 keeps mutating label ref
    /// counts after the walk.
    /// Idempotent, and `deinitUncommitted` remains correct whether or not this
    /// ran.
    pub fn releaseConsumedStreams(self: *ResolvedProduct) void {
        for (self.atom_operands[0..self.atom_len]) |atom_id| self.atoms.free(atom_id);

        if (self.code_capacity != 0) self.memory.free(u8, self.code);
        if (self.atom_capacity != 0) self.memory.free(core.atom.Atom, self.atom_operands);
        if (self.source_capacity != 0) self.memory.free(builder.SourceSlot, self.source_slots);

        self.code = &.{};
        self.code_capacity = 0;
        self.code_len = 0;
        self.atom_operands = &.{};
        self.atom_capacity = 0;
        self.atom_len = 0;
        self.source_slots = &.{};
        self.source_capacity = 0;
        self.source_len = 0;
    }

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
// Sequential walks have the exact atom-ledger cursor for their current pc and
// enforce the QuickJS phase-1 opcode view. Random-access pattern probes compare
// their exact fixed-width opcodes directly, like QuickJS `code_match`.
const phase1Instruction = cfg.phase1Instruction;
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
    opt_boundaries: []cfg.OptimizationBoundary = &.{},
    opt_boundary_capacity: usize = 0,
    opt_boundary_len: u32 = 0,

    bind_cursor: usize = 0,
    block_cursor: usize = 0,
    atom_index: u32 = 0,
    source_cursor: u32 = 0,
    source_attach_cursor: u32 = 0,
    next_bind_offset: u64,
    next_source_offset: u64,
    has_dynamic_env_objects: bool,
    dynamic_env_closure_len: usize,

    fn deinitScratch(self: *Resolver) void {
        if (self.pending_tail_capacity != 0) {
            self.product.memory.free(PendingTailRewrite, self.pending_tail_rewrites);
        }
        self.pending_tail_rewrites = &.{};
        self.pending_tail_capacity = 0;
        self.pending_tail_len = 0;
        if (comptime audit_oracles) {
            if (self.opt_boundary_capacity != 0) {
                self.product.memory.free(cfg.OptimizationBoundary, self.opt_boundaries);
            }
            self.opt_boundaries = &.{};
            self.opt_boundary_capacity = 0;
            self.opt_boundary_len = 0;
        }
    }

    /// QuickJS discovers a binding and its preceding with/eval environments
    /// in one `resolve_scope_var` walk. V2 splits topology discovery from
    /// emission, so a function with no such environment must not rescan the
    /// same scope/closure chains for every identifier. Vars and eval-object
    /// slots are fixed before this pass; only closure rows can grow here, and
    /// those are checked incrementally after each topology lookup.
    inline fn hasDynamicEnvObjects(self: *Resolver) Error!bool {
        if (self.has_dynamic_env_objects) return true;
        const fd = self.ctx.function_def orelse return error.NoFunctionDef;
        if (self.dynamic_env_closure_len > fd.closure_var.len)
            return error.InvalidBytecode;
        if (self.dynamic_env_closure_len != fd.closure_var.len) {
            self.has_dynamic_env_objects = legacy.closureVarRangeHasDynamicEnvObjects(
                fd,
                self.dynamic_env_closure_len,
            );
            self.dynamic_env_closure_len = fd.closure_var.len;
        }
        return self.has_dynamic_env_objects;
    }

    /// `replacement_product` is the PRODUCT offset the replacement is written
    /// at, captured by the caller at the instant of the replacing emission
    /// (`labels.unbound` for a fold whose replacement is emitted later; the
    /// deferred make_ref tail patches it in `emitPendingTailRewrite`). The F3
    /// classifier compares it against the product offset of the label bound at
    /// `replacement_start`.
    fn recordOptimizationBoundary(
        self: *Resolver,
        kind: cfg.OptimizationBoundaryKind,
        fold_start: u32,
        consumed_end: u32,
        replacement_start: u32,
        replacement_product: u32,
    ) Error!void {
        if (comptime !audit_oracles) return;
        if (self.opt_boundary_len == std.math.maxInt(u32))
            return error.BytecodeOverflow;
        try reserve(
            cfg.OptimizationBoundary,
            self.product.memory,
            &self.opt_boundaries,
            &self.opt_boundary_capacity,
            self.opt_boundary_len,
            1,
            4,
        );
        self.opt_boundaries[self.opt_boundary_len] = .{
            .kind = kind,
            .fold_start = fold_start,
            .consumed_end = consumed_end,
            .replacement_start = replacement_start,
            .replacement_product = replacement_product,
        };
        self.opt_boundary_len += 1;
    }

    /// Fill in the product offset of a fold whose replacement is emitted after
    /// the boundary was recorded (make_ref tail). Called from the emission
    /// point with `product.code_len` taken before the replacing write.
    fn resolveDeferredFoldProduct(
        self: *Resolver,
        kind: cfg.OptimizationBoundaryKind,
        fold_start: u32,
        replacement_product: u32,
    ) void {
        if (comptime !audit_oracles) return;
        for (self.opt_boundaries[0..self.opt_boundary_len]) |*boundary| {
            if (boundary.kind == kind and boundary.fold_start == fold_start and
                boundary.replacement_product == labels.unbound)
            {
                boundary.replacement_product = replacement_product;
                return;
            }
        }
    }

    inline fn streamHasCapacity(capacity: usize, used: u32, need: usize) bool {
        const used_usize: usize = @intCast(used);
        return used_usize <= capacity and need <= capacity - used_usize;
    }

    /// All three product ledgers are pre-sized from the Builder at entry.  A
    /// rewrite that grows beyond those estimates still comes here and retains
    /// the original overflow/OOM behavior, but ordinary copied instructions
    /// should not carry three generic reserve calls through the hot loop.
    noinline fn growProductStreams(
        self: *Resolver,
        code_need: usize,
        atom_need: usize,
        source_need: usize,
    ) Error!void {
        if (code_need > std.math.maxInt(u32) or
            atom_need > std.math.maxInt(u32) or
            source_need > std.math.maxInt(u32))
        {
            return error.BytecodeOverflow;
        }
        _ = std.math.add(u32, self.product.code_len, @as(u32, @intCast(code_need))) catch
            return error.BytecodeOverflow;
        _ = std.math.add(u32, self.product.atom_len, @as(u32, @intCast(atom_need))) catch
            return error.BytecodeOverflow;
        _ = std.math.add(u32, self.product.source_len, @as(u32, @intCast(source_need))) catch
            return error.BytecodeOverflow;

        if (code_need != 0) {
            try reserve(
                u8,
                self.product.memory,
                &self.product.code,
                &self.product.code_capacity,
                self.product.code_len,
                code_need,
                16,
            );
        }
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
        if (source_need != 0) {
            try reserve(
                builder.SourceSlot,
                self.product.memory,
                &self.product.source_slots,
                &self.product.source_capacity,
                self.product.source_len,
                source_need,
                8,
            );
        }
    }

    inline fn ensureProductStreams(
        self: *Resolver,
        code_need: usize,
        atom_need: usize,
        source_need: usize,
    ) Error!void {
        if (code_need <= std.math.maxInt(u32) and
            atom_need <= std.math.maxInt(u32) and
            source_need <= std.math.maxInt(u32) and
            code_need <= std.math.maxInt(u32) - self.product.code_len and
            atom_need <= std.math.maxInt(u32) - self.product.atom_len and
            source_need <= std.math.maxInt(u32) - self.product.source_len and
            streamHasCapacity(self.product.code_capacity, self.product.code_len, code_need) and
            streamHasCapacity(self.product.atom_capacity, self.product.atom_len, atom_need) and
            streamHasCapacity(self.product.source_capacity, self.product.source_len, source_need))
        {
            return;
        }
        return self.growProductStreams(code_need, atom_need, source_need);
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

        const pending_source_count = try self.pendingSourceUpperBound();
        _ = std.math.add(u32, self.product.source_len, pending_source_count) catch
            return error.BytecodeOverflow;
        try self.ensureProductStreams(code_need, atom_need, pending_source_count);
        if (pending_source_count != 0) self.attachPendingSourcesAssumeCapacity();
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

    /// Ordinary QuickJS scope resolution writes the selected local/argument/
    /// closure/global opcode immediately.  Keep the generic pointer-counting
    /// writer for the atom-bearing readonly throw, but write the overwhelmingly
    /// common 1--3 byte action from the compact resolver result without
    /// materializing another `ScopeVarAction` on the caller's stack.
    fn writeResolvedScopeVarPlan(
        self: *Resolver,
        atom_id: core.atom.Atom,
        plan: legacy.ResolvedScopeVarPlanAlias,
    ) Error!void {
        if (plan.action_op_id == op.throw_error) {
            return self.writeScopeVarAction(
                atom_id,
                legacy.resolvedScopeVarPlanAction(plan),
            );
        }

        const code_need: usize = plan.action_size;
        if (code_need == 0 or code_need != @as(usize, plan.action_operand_size) + 1)
            return error.InvalidBytecode;
        try self.prepareLegacyWrite(code_need, 0);

        const code_start: usize = @intCast(self.product.code_len);
        const output = self.product.code[code_start..][0..code_need];
        output[0] = plan.action_op_id;
        switch (plan.action_operand_size) {
            0 => {},
            1 => {
                if (plan.action_index > std.math.maxInt(u8))
                    return error.InvalidBytecode;
                output[1] = @intCast(plan.action_index);
            },
            2 => std.mem.writeInt(u16, output[1..3], plan.action_index, .little),
            else => return error.InvalidBytecode,
        }
        self.product.code_len += @intCast(code_need);
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

    fn ensureDynamicEnvLabel(
        self: *Resolver,
        label_done: *?u32,
    ) Error!u32 {
        if (label_done.*) |label_index| return label_index;
        const label_index = try self.newProductLabel();
        label_done.* = label_index;
        return label_index;
    }

    /// QuickJS reaches `var_object_test()` only after its binding walk has
    /// encountered a with/eval object.  Keep the equivalent negative test in
    /// the caller's hot path: most functions have no dynamic environment, so
    /// they must not materialize a binding or enter the outlined emitter just
    /// to rediscover that fact.
    inline fn needsDynamicEnvProbes(
        self: *Resolver,
        atom_id: core.atom.Atom,
        scope_level: i32,
        oracle_plan: ?legacy.ScopeVarProbePlanAlias,
    ) Error!bool {
        if (!legacy.scopeVarDynamicProbeEligible(atom_id, scope_level) or
            !try self.hasDynamicEnvObjects())
        {
            if (comptime audit_oracles) {
                if (oracle_plan != null) return error.InvalidBytecode;
            }
            return false;
        }
        return true;
    }

    /// QuickJS emits dynamic-environment probes while walking the binding
    /// chain.  V2's growable product can do the same: allocate the done label
    /// lazily on the first real probe and avoid the former count/size prepass.
    /// `needsDynamicEnvProbes()` has already proved that the uncommon emitter
    /// is required.
    fn emitDynamicEnvProbes(
        self: *Resolver,
        atom_id: core.atom.Atom,
        scope_level: i32,
        probe_op: u8,
        binding: legacy.ScopeVarBindingAlias,
        oracle_plan: ?legacy.ScopeVarProbePlanAlias,
    ) Error!?u32 {
        var label_done: ?u32 = null;
        const code_start = self.product.code_len;
        const atom_start = self.product.atom_len;

        var with_iter = legacy.localWithProbeIteratorInit(self.ctx, atom_id, scope_level);
        while (legacy.localWithProbeIteratorNext(&with_iter)) |idx| {
            const label_index = try self.ensureDynamicEnvLabel(&label_done);
            try self.emitDynamicEnvProbe(atom_id, .{ .with_local = idx }, probe_op, label_index);
        }

        if (!legacy.resolvedBindingStopsDynamicEnvProbes(
            self.ctx,
            atom_id,
            scope_level,
            binding,
        )) {
            const fd = self.ctx.function_def orelse return error.NoFunctionDef;
            if (!legacy.scopeUsesArgumentEnvironmentOnly(fd, scope_level) and fd.var_object_idx >= 0) {
                const label_index = try self.ensureDynamicEnvLabel(&label_done);
                try self.emitDynamicEnvProbe(
                    atom_id,
                    .{ .local = @intCast(fd.var_object_idx) },
                    probe_op,
                    label_index,
                );
            }
            if (fd.arg_var_object_idx >= 0) {
                const label_index = try self.ensureDynamicEnvLabel(&label_done);
                try self.emitDynamicEnvProbe(
                    atom_id,
                    .{ .local = @intCast(fd.arg_var_object_idx) },
                    probe_op,
                    label_index,
                );
            }
            var closure_iter = legacy.closureDynamicEnvProbeIteratorInitResolved(self.ctx, binding);
            while (legacy.closureDynamicEnvProbeIteratorNext(&closure_iter)) |idx| {
                if (idx >= fd.closure_var.len) return error.InvalidBytecode;
                const label_index = try self.ensureDynamicEnvLabel(&label_done);
                try self.emitDynamicEnvProbe(
                    atom_id,
                    legacy.evalVarObjectClosureProbe(fd.closure_var[idx], idx),
                    probe_op,
                    label_index,
                );
            }
        }

        if (comptime audit_oracles) {
            const actual_size: usize = @intCast(self.product.code_len - code_start);
            const actual_count: usize = @intCast(self.product.atom_len - atom_start);
            if (oracle_plan) |expected| {
                if (actual_size != expected.prefix_size or actual_count != expected.count or
                    label_done == null)
                {
                    return error.InvalidBytecode;
                }
            } else if (actual_size != 0 or actual_count != 0 or label_done != null) {
                return error.InvalidBytecode;
            }
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

    fn emitWideU16(self: *Resolver, op_id: u8, value: u16) Error!void {
        var bytes: [3]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u16, bytes[1..3], value, .little);
        try self.emitInstruction(&bytes, null);
    }

    fn emitWideU32(self: *Resolver, op_id: u8, value: u32) Error!void {
        var bytes: [5]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u32, bytes[1..5], value, .little);
        try self.emitInstruction(&bytes, null);
    }

    fn emitAtomWide(self: *Resolver, op_id: u8, atom_id: core.atom.Atom) Error!void {
        var bytes: [5]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u32, bytes[1..5], atom_id, .little);
        try self.emitInstruction(&bytes, atom_id);
    }

    fn emitProductJump(self: *Resolver, op_id: u8, label_index: u32) Error!void {
        if (label_index >= self.product.label_len) return error.InvalidBytecode;
        try self.emitWideU32(op_id, label_index);
        _ = try updateLabel(self.product, label_index, 1);
        try self.incrementJumpSize();
    }

    /// qjs instantiate_hoisted_definitions at the function-body scope
    /// (quickjs.c:34398-34409). Keep every branch operand label-native; Stage
    /// 4 alone converts the module-body LabelId into a relative displacement.
    fn emitBodyHoists(self: *Resolver) Error!void {
        const fd = self.ctx.function_def orelse return error.NoFunctionDef;

        for (fd.args, 0..) |arg, arg_idx| {
            if (arg.func_pool_idx < 0) continue;
            if (arg_idx > std.math.maxInt(u16)) return error.BytecodeOverflow;
            try self.emitWideU32(op.fclosure, @intCast(arg.func_pool_idx));
            try self.emitWideU16(op.put_arg, @intCast(arg_idx));
        }
        for (fd.vars, 0..) |vd, var_idx| {
            if (vd.scope_level != 0 or vd.func_pool_idx < 0) continue;
            if (var_idx > std.math.maxInt(u16)) return error.BytecodeOverflow;
            try self.emitWideU32(op.fclosure, @intCast(vd.func_pool_idx));
            try self.emitWideU16(op.put_loc, @intCast(var_idx));
        }

        const module_body = if (fd.is_module) try self.newProductLabel() else null;
        if (module_body) |body_label| {
            try self.emitInstruction(&.{op.push_this}, null);
            try self.emitProductJump(op.if_false, body_label);
        }

        for (fd.global_vars) |gv| {
            switch (gv.eval_target) {
                .closure => |ref_idx| {
                    if (gv.cpool_idx < 0) continue;
                    try self.emitWideU32(op.fclosure, @intCast(gv.cpool_idx));
                    try self.emitWideU16(op.put_var_ref, ref_idx);
                },
                .var_object => |ref_idx| {
                    try self.emitWideU16(op.get_var_ref, ref_idx);
                    if (gv.cpool_idx >= 0) {
                        try self.emitWideU32(op.fclosure, @intCast(gv.cpool_idx));
                        try self.emitAtomWide(op.define_field, gv.var_name);
                    } else {
                        // EvalDeclarationInstantiation creates a new var
                        // object property only when the name is absent, so a
                        // repeated direct-eval `var x` must preserve the
                        // existing value and binding cell. Identity-native
                        // twin of the legacy `writeBodyHoists` guard: the
                        // branch destination is a LabelId here, and Stage 4
                        // alone turns it into a displacement.
                        const defined_label = try self.newProductLabel();
                        try self.emitAtomWide(op.get_field2, gv.var_name);
                        try self.emitInstruction(&.{op.is_undefined}, null);
                        try self.emitProductJump(op.if_false, defined_label);
                        try self.emitInstruction(&.{op.undefined}, null);
                        try self.emitAtomWide(op.define_field, gv.var_name);
                        try self.bindProductLabel(defined_label);
                    }
                    try self.emitInstruction(&.{op.drop}, null);
                },
                .global => {},
                .unresolved => return error.InvalidBytecode,
            }
        }

        if (module_body) |body_label| {
            try self.emitInstruction(&.{op.return_undef}, null);
            try self.bindProductLabel(body_label);
        }
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
        self.resolveDeferredFoldProduct(
            .make_ref_tail,
            rewrite.input_offset,
            self.product.code_len,
        );
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

    inline fn refreshSourceFrontier(self: *Resolver) void {
        self.next_source_offset = if (self.source_cursor < self.input_sources.len)
            self.input_sources[self.source_cursor].temp_offset
        else
            std.math.maxInt(u64);
    }

    fn absorbSourcesThrough(self: *Resolver, input_pos: u32) void {
        if (self.next_source_offset > input_pos) return;
        while (self.source_cursor < self.input_sources.len) {
            if (self.input_sources[self.source_cursor].temp_offset > input_pos) break;
            self.source_cursor += 1;
        }
        self.refreshSourceFrontier();
    }

    fn pendingSourceUpperBound(self: *const Resolver) Error!u32 {
        if (self.source_attach_cursor > self.source_cursor)
            return error.InvalidBytecode;
        return self.source_cursor - self.source_attach_cursor;
    }

    /// Carry every parser source event consumed since the previous output
    /// instruction. Stage 3 must not deduplicate even identical consecutive
    /// points: Stage 4 can relocate or discard the earlier event while a later
    /// equal event remains authoritative at a different output boundary.
    /// Final-output attachment performs coordinate deduplication only after
    /// those independent relocation decisions.
    fn attachPendingSourcesAssumeCapacity(self: *Resolver) void {
        while (self.source_attach_cursor < self.source_cursor) {
            const slot = self.input_sources[self.source_attach_cursor];
            self.source_attach_cursor += 1;
            self.product.source_slots[self.product.source_len] = .{
                .temp_offset = self.product.code_len,
                .line = slot.line,
                .col = slot.col,
            };
            self.product.source_len += 1;
        }
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
        const pending_source_count = try self.pendingSourceUpperBound();
        _ = std.math.add(u32, self.product.source_len, pending_source_count) catch
            return error.BytecodeOverflow;

        try self.ensureProductStreams(
            bytes.len,
            @intFromBool(atom_id != null),
            pending_source_count,
        );

        if (pending_source_count != 0) self.attachPendingSourcesAssumeCapacity();

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
        _: u32,
        instruction: TempInstruction,
    ) Error!?core.atom.Atom {
        if (!instruction.has_atom) return null;
        // phase1Instruction has just proved both facts for this cursor. Keep
        // the assertions for debug builds without paying the same validation
        // branches twice in the production loop.
        std.debug.assert(self.atom_index < self.atom_ledger.len);
        std.debug.assert(instruction.size >= 5);
        const ledger_atom = self.atom_ledger[self.atom_index];
        // phase1Instruction already matched the encoded operand to this exact
        // ledger entry.  Do not reload and compare the same u32 a second time.
        self.atom_index += 1;
        return ledger_atom;
    }

    /// QuickJS's `no_change` arm appends the instruction selected by the
    /// current decode directly to `bc_out`.  `phase1Instruction` has already
    /// proved the non-zero size and input boundary for this exact instruction;
    /// the no-atom copy therefore only has to reserve the output ledgers and
    /// carry source events.  Rewritten/synthesized instructions continue to
    /// use `emitInstruction`, which retains its full defensive validation.
    fn emitValidatedCopyNoAtom(
        self: *Resolver,
        input_pos: u32,
        byte_count: u8,
    ) Error!void {
        std.debug.assert(byte_count != 0);
        const pending_source_count = try self.pendingSourceUpperBound();
        try self.ensureProductStreams(byte_count, 0, pending_source_count);
        if (pending_source_count != 0) self.attachPendingSourcesAssumeCapacity();

        const input_start: usize = @intCast(input_pos);
        const output_start: usize = @intCast(self.product.code_len);
        @memcpy(
            self.product.code[output_start..][0..byte_count],
            self.code[input_start..][0..byte_count],
        );
        // ensureProductStreams proved this addition fits both the backing and
        // the u32 logical length.
        self.product.code_len += byte_count;
    }

    /// Atom-bearing copies have the same proof plus the exact operand/ledger
    /// equality established by `phase1Instruction`.  ConsumeInputAtom supplies
    /// that ledger entry, so do not reload the encoded u32 a third time here.
    fn emitValidatedCopyAtom(
        self: *Resolver,
        input_pos: u32,
        byte_count: u8,
        atom_id: core.atom.Atom,
    ) Error!void {
        std.debug.assert(byte_count >= 5);
        const pending_source_count = try self.pendingSourceUpperBound();
        try self.ensureProductStreams(byte_count, 1, pending_source_count);
        if (pending_source_count != 0) self.attachPendingSourcesAssumeCapacity();

        const input_start: usize = @intCast(input_pos);
        const output_start: usize = @intCast(self.product.code_len);
        @memcpy(
            self.product.code[output_start..][0..byte_count],
            self.code[input_start..][0..byte_count],
        );
        self.product.atom_operands[self.product.atom_len] = self.product.atoms.dup(atom_id);
        self.product.atom_len += 1;
        self.product.code_len += byte_count;
    }

    fn copyInputInstruction(
        self: *Resolver,
        input_pos: u32,
        instruction: TempInstruction,
        atom_id: ?core.atom.Atom,
    ) Error!void {
        if (instruction.has_atom) {
            try self.emitValidatedCopyAtom(input_pos, instruction.size, atom_id.?);
        } else {
            std.debug.assert(atom_id == null);
            try self.emitValidatedCopyNoAtom(input_pos, instruction.size);
        }
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
        if (self.next_bind_offset != input_pos) {
            if (self.next_bind_offset < input_pos) return error.InvalidBytecode;
            return;
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
        self.refreshBindFrontier();
    }

    inline fn refreshBindFrontier(self: *Resolver) void {
        self.next_bind_offset = if (self.bind_cursor < self.binds.len)
            self.binds[self.bind_cursor].input_offset
        else
            std.math.maxInt(u64);
    }

    inline fn passSideEventsThrough(self: *Resolver, input_pos: u32) Error!void {
        if (input_pos < self.next_bind_offset and input_pos < self.next_source_offset)
            return;
        try self.passBindsAt(input_pos);
        self.absorbSourcesThrough(input_pos);
    }

    fn hasLiveMatchBarrierAt(self: *const Resolver, input_pos: u32) bool {
        var index = self.firstBindAtOrAfter(input_pos);
        while (index < self.binds.len and self.binds[index].input_offset == input_pos) : (index += 1) {
            const entry = self.binds[index];
            if (!entry.dead_skipped and
                self.product.label_slots[entry.label_index].flags.match_barrier)
            {
                return true;
            }
        }
        return false;
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
        if (comptime !audit_oracles) {
            if (self.next_bind_offset < input_pos) return error.InvalidBytecode;
            if (self.next_bind_offset != input_pos) return false;
            var end = self.bind_cursor;
            while (end < self.binds.len and self.binds[end].input_offset == input_pos) : (end += 1) {}
            std.debug.assert(end != self.bind_cursor);

            var has_live = false;
            for (self.binds[self.bind_cursor..end]) |entry| {
                if (self.product.label_slots[entry.label_index].ref_count != 0) {
                    has_live = true;
                    break;
                }
            }
            if (has_live) {
                for (self.binds[self.bind_cursor..end]) |*entry| {
                    const slot = self.product.label_slots[entry.label_index];
                    if (slot.ref_count == 0 and !slot.flags.match_barrier)
                        entry.dead_skipped = true;
                }
                return true;
            }

            for (self.binds[self.bind_cursor..end]) |*entry| {
                std.debug.assert(self.product.label_slots[entry.label_index].first_reloc == labels.no_reloc);
                entry.dead_skipped = true;
            }
            self.bind_cursor = end;
            self.refreshBindFrontier();
            return false;
        }

        const block_index = try self.blockAt(input_pos);
        if (self.next_bind_offset < input_pos) return error.InvalidBytecode;
        if (self.next_bind_offset != input_pos) return false;
        var end = self.bind_cursor;
        while (end < self.binds.len and self.binds[end].input_offset == input_pos) : (end += 1) {}
        std.debug.assert(end != self.bind_cursor);

        if (self.graph.block_starts[block_index] != input_pos)
            return error.InvalidBytecode;
        std.debug.assert(self.graph.block_starts[block_index] == input_pos);
        if (self.graph.isReachable(block_index)) {
            for (self.binds[self.bind_cursor..end]) |*entry| {
                const slot = self.product.label_slots[entry.label_index];
                if (slot.ref_count == 0 and !slot.flags.match_barrier)
                    entry.dead_skipped = true;
            }
            return true;
        }

        for (self.binds[self.bind_cursor..end]) |*entry| {
            std.debug.assert(self.product.label_slots[entry.label_index].first_reloc == labels.no_reloc);
            entry.dead_skipped = true;
        }
        self.bind_cursor = end;
        self.refreshBindFrontier();
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
        binding: legacy.ScopeVarBindingAlias,
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

        const binding_is_global = switch (binding) {
            .global => true,
            else => false,
        };
        if (binding_is_global and !legacy.canOptimizeGlobalRefPutTail(self.ctx, atom_id)) {
            return null;
        }

        const get_action = try legacy.planResolvedScopeVarAction(
            self.ctx,
            atom_id,
            op.scope_get_var,
            binding,
        );
        const put_action = try legacy.planResolvedScopeVarAction(
            self.ctx,
            atom_id,
            op.scope_put_var,
            binding,
        );
        if (legacy.scopeVarActionAtomCount(get_action) != 0 or
            legacy.scopeVarActionAtomCount(put_action) != 0 or
            get_action.selected.op_id == op.drop or
            put_action.selected.op_id == op.drop or
            get_action.selected.op_id == op.throw_error or
            put_action.selected.op_id == op.throw_error)
        {
            return null;
        }

        return .{
            .tail_offset = tail_offset,
            .emit_dup = first_op == op.insert3,
            .reads_value = position_next < self.input.code_len and
                self.code[position_next] == op.get_ref_value,
            .get_action = get_action,
            .put_action = put_action,
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
        const branch_op = self.code[start];
        if (branch_op != op.if_false and branch_op != op.if_true) return null;
        if (expected_op) |wanted| if (branch_op != wanted) return null;
        const branch_size = opcode.sizeOf(branch_op);
        if (branch_size != 5 or branch_size > self.code.len - start)
            return error.InvalidBytecode;
        const drop_pos = start + branch_size;
        if (drop_pos >= self.code.len) return null;
        if (self.code[drop_pos] != op.drop) return null;
        const after = drop_pos + 1;
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
        if (self.code[start] != op.dup) return null;
        const branch_start = start + 1;
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
        if (self.code[start] != expected_branch) return null;
        const branch_size = opcode.sizeOf(expected_branch);
        if (branch_size != 5 or branch_size > self.code.len - start)
            return error.InvalidBytecode;
        const after = start + branch_size;
        if (self.hasBindInRange(start, after, transparent_start_binds)) return null;
        return .{ .label_index = try self.labelAt(start, 1), .after = after };
    }

    const InsertTailMatch = struct {
        middle_op: u8,
        drop_pos: u32,
        after: u32,
    };

    /// The legacy phase-1 stream materializes a changed source position as an
    /// inline `line_num` instruction. Its local indexed-store matcher requires
    /// the three opcodes to be byte-adjacent, so an effective transition at an
    /// interior offset is a fold barrier. Builder retains repeated marker calls
    /// too; those are not barriers because legacy `emitSourcePos` suppresses an
    /// unchanged source offset.
    fn hasSourceTransitionAt(self: *const Resolver, input_pos: u32) bool {
        var low: usize = 0;
        var high: usize = self.input_sources.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.input_sources[middle].temp_offset < input_pos) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (low == self.input_sources.len or
            self.input_sources[low].temp_offset != input_pos)
        {
            return false;
        }

        var previous: ?SourcePoint = if (low == 0) null else .{
            .line = self.input_sources[low - 1].line,
            .col = self.input_sources[low - 1].col,
        };
        var index = low;
        while (index < self.input_sources.len and
            self.input_sources[index].temp_offset == input_pos) : (index += 1)
        {
            const current: SourcePoint = .{
                .line = self.input_sources[index].line,
                .col = self.input_sources[index].col,
            };
            if (previous == null or !sourcePointEqual(current, previous.?))
                return true;
            previous = current;
        }
        return false;
    }

    fn matchInsertTail(self: *Resolver, start: u32) Error!?InsertTailMatch {
        if (start >= self.code.len) return null;
        const middle_op = self.code[start];
        if (middle_op != op.put_array_el and middle_op != op.put_ref_value)
            return null;
        const drop_pos = start + 1;
        if (drop_pos >= self.code.len) return null;
        if (self.code[drop_pos] != op.drop) return null;
        const after = drop_pos + 1;
        if (self.hasSourceTransitionAt(start) or self.hasSourceTransitionAt(drop_pos))
            return null;
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
            const goto_size = opcode.sizeOf(op.goto);
            if (goto_size != 5 or goto_size > self.code.len - position)
                return error.InvalidBytecode;
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
            const instruction = try phase1Instruction(
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
            // phase1Instruction proved this cursor advance is within the
            // u32-sized input stream.
            position += instruction.size;
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
        const plan = try legacy.resolveScopeVarPlan(
            self.ctx,
            atom_id,
            scope_operand.level,
            op_id,
        );
        if (comptime audit_oracles) {
            const action = legacy.resolvedScopeVarPlanAction(plan);
            const oracle = try legacy.planScopeVarLowering(
                self.ctx,
                atom_id,
                scope_operand,
                op_id,
                false,
            );
            if (!std.meta.eql(action, oracle.action)) return error.InvalidBytecode;
        }

        var label_done: ?u32 = null;
        if (legacy.scopeVarProbeKind(op_id, scope_operand.no_dynamic_env)) |kind| {
            const oracle_plan = if (comptime audit_oracles)
                legacy.evalVarObjectProbePlan(
                    self.ctx,
                    atom_id,
                    scope_operand.level,
                    op_id,
                    kind,
                )
            else
                null;
            if (try self.needsDynamicEnvProbes(
                atom_id,
                scope_operand.level,
                oracle_plan,
            )) {
                label_done = try self.emitDynamicEnvProbes(
                    atom_id,
                    scope_operand.level,
                    legacy.scopeVarProbeOpcode(kind),
                    legacy.resolvedScopeVarPlanBinding(plan),
                    oracle_plan,
                );
            }
        }
        try self.writeResolvedScopeVarPlan(atom_id, plan);
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
        const binding = try legacy.resolveScopeVarBindingTopology(
            self.ctx,
            atom_id,
            scope_operand.level,
        );

        const probe_kind: legacy.EvalVarObjectProbeKindAlias = if (op_id == op.scope_delete_var)
            .delete
        else if (op_id == op.scope_get_ref)
            .get_ref
        else
            return error.InvalidBytecode;
        const oracle_plan = if (comptime audit_oracles)
            legacy.evalVarObjectProbePlan(
                self.ctx,
                atom_id,
                scope_operand.level,
                op_id,
                probe_kind,
            )
        else
            null;
        const label_done = if (try self.needsDynamicEnvProbes(
            atom_id,
            scope_operand.level,
            oracle_plan,
        ))
            try self.emitDynamicEnvProbes(
                atom_id,
                scope_operand.level,
                legacy.scopeVarProbeOpcode(probe_kind),
                binding,
                oracle_plan,
            )
        else
            null;

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
        const binding = try legacy.resolveScopeVarBindingTopology(
            self.ctx,
            atom_id,
            scope_operand.level,
        );

        if (try self.planMakeRefFold(
            position_next,
            atom_id,
            scope_operand,
            aux_label,
            binding,
        )) |fold| {
            try self.registerPendingTailRewrite(
                fold.tail_offset,
                fold.emit_dup,
                fold.put_action,
            );
            // Product offset the consumed head resolves to. Nothing has been
            // emitted since the caller's passBindsAt(position), so this is
            // exactly where a label bound at `position` was bound.
            const head_product = self.product.code_len;
            var value_product = head_product;
            var next = position_next;
            if (fold.reads_value) {
                try self.passSideEventsThrough(position_next);
                value_product = self.product.code_len;
                try self.writeScopeVarAction(atom_id, fold.get_action);
                next = std.math.add(u32, next, 1) catch return error.InvalidBytecode;
            }
            if (comptime audit_oracles) {
                const tail_end = std.math.add(u32, fold.tail_offset, 2) catch
                    return error.InvalidBytecode;
                // The head is one span per consumed instruction: a bind may
                // legitimately sit at position_next and is passed above.
                try self.recordOptimizationBoundary(
                    .make_ref_head,
                    position,
                    position_next,
                    position,
                    head_product,
                );
                if (fold.reads_value) {
                    try self.recordOptimizationBoundary(
                        .make_ref_head,
                        position_next,
                        next,
                        position_next,
                        value_product,
                    );
                }
                // The tail replacement is emitted later, at the loop visit of
                // fold.tail_offset; emitPendingTailRewrite fills the product.
                try self.recordOptimizationBoundary(
                    .make_ref_tail,
                    fold.tail_offset,
                    tail_end,
                    fold.tail_offset,
                    labels.unbound,
                );
            }
            return next;
        }

        const oracle_plan = if (comptime audit_oracles)
            legacy.evalVarObjectProbePlan(
                self.ctx,
                atom_id,
                scope_operand.level,
                op.scope_make_ref,
                .make_ref,
            )
        else
            null;
        // qjs:33024-33032, 33287-33299, 33332-33336. Only a surviving
        // reference captures a local/argument cell.
        try legacy.markReferenceTakenBinding(self.ctx, atom_id, scope_operand.level);

        const label_done = if (try self.needsDynamicEnvProbes(
            atom_id,
            scope_operand.level,
            oracle_plan,
        ))
            try self.emitDynamicEnvProbes(
                atom_id,
                scope_operand.level,
                op.with_make_ref,
                binding,
                oracle_plan,
            )
        else
            null;
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
            try self.passSideEventsThrough(position);

            if (try self.pendingTailRewriteAt(position)) |rewrite_index| {
                position = try self.emitPendingTailRewrite(rewrite_index);
                continue;
            }

            const instruction = try phase1Instruction(
                self.code,
                self.atom_ledger,
                position,
                self.atom_index,
            );
            // phase1Instruction proved this cursor advance is within the
            // u32-sized input stream.
            var position_next = position + instruction.size;
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
                        if (comptime audit_oracles) {
                            // The replacement is empty: the anchor is the
                            // product offset the deleted gosub would have
                            // occupied, i.e. the current output cursor.
                            try self.recordOptimizationBoundary(
                                .gosub_empty,
                                position,
                                position_next,
                                position,
                                self.product.code_len,
                            );
                        }
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
                            const fold_product = self.product.code_len;
                            try self.emitInstruction(&rewritten, null);
                            if (comptime audit_oracles) {
                                try self.recordOptimizationBoundary(
                                    .dup_branch_fold,
                                    position,
                                    first.after,
                                    position,
                                    fold_product,
                                );
                            }
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
                        const fold_product = self.product.code_len;
                        try self.emitInstruction(&.{match.middle_op}, null);
                        if (comptime audit_oracles) {
                            try self.recordOptimizationBoundary(
                                .insert_tail_fold,
                                position,
                                match.after,
                                position,
                                fold_product,
                            );
                        }
                        self.absorbSourcesThrough(match.drop_pos);
                        position_next = match.after;
                    } else {
                        try self.copyInputInstruction(position, instruction, input_atom);
                    }
                },

                // qjs:34499-34501 normally erases OP_nop. A nop at a physical
                // OP_label boundary survives zjs's legacy phase-2 product,
                // however: put_lvalue uses precisely that shape for an
                // un-folded scope_make_ref tail. v2 has no label byte, so its
                // match-barrier identity is the exact retention signal.
                op.nop => if (self.hasLiveMatchBarrierAt(position))
                    try self.copyInputInstruction(position, instruction, input_atom),

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
                    if (scope == fd.body_scope) try self.emitBodyHoists();
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

        try self.passSideEventsThrough(self.input.code_len);
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
            .flags = .{
                .backward_target = input_slot.flags.backward_target,
                .match_barrier = input_slot.flags.match_barrier,
            },
        };
        product.label_len += 1;
    }
}

/// The resolved stream is normally no larger than its compact input; rare
/// dynamic-environment probes and hoists grow from this baseline. Reserve the
/// three common output ledgers once, like a sized QuickJS DynBuf, so the hot
/// per-instruction emit path only takes the capacity-success branches.
fn preallocateProductStreams(
    product: *ResolvedProduct,
    input: *const builder.Builder,
) Error!void {
    if (input.code_len != 0) {
        try reserve(
            u8,
            product.memory,
            &product.code,
            &product.code_capacity,
            0,
            input.code_len,
            16,
        );
    }
    if (input.atom_len != 0) {
        try reserve(
            core.atom.Atom,
            product.memory,
            &product.atom_operands,
            &product.atom_capacity,
            0,
            input.atom_len,
            8,
        );
    }
    if (input.source_len != 0) {
        try reserve(
            builder.SourceSlot,
            product.memory,
            &product.source_slots,
            &product.source_capacity,
            0,
            input.source_len,
            8,
        );
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

/// Deliver reachable direct-eval capture events before the output walk can
/// lower an earlier `leave_scope`. QuickJS marks the scope at OP_eval /
/// OP_apply_eval (qjs:34247-34262); zjs's exact-CFG preflight makes that
/// binding fact available to every real consumer regardless of byte order.
fn markReachableEvalCaptures(
    input: *const builder.Builder,
    graph: *const cfg.Graph,
    fd: *bytecode.function_def.FunctionDef,
) Error!void {
    const code = input.code[0..input.code_len];
    const atom_ledger = input.atom_operands[0..input.atom_len];
    var position: u32 = 0;
    var atom_index: u32 = 0;
    var block_index: usize = 0;

    while (position < input.code_len) {
        while (block_index + 1 < graph.block_starts.len and
            graph.block_starts[block_index + 1] <= position)
        {
            block_index += 1;
        }
        if (block_index >= graph.blocks.len or
            graph.block_starts[block_index] > position)
        {
            return error.InvalidBytecode;
        }

        const instruction = try phase1Instruction(
            code,
            atom_ledger,
            position,
            atom_index,
        );
        const pc: usize = @intCast(position);
        if (instruction.has_atom) {
            if (atom_index >= atom_ledger.len or instruction.size < 5)
                return error.InvalidBytecode;
            const encoded_atom = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
            if (encoded_atom != atom_ledger[atom_index])
                return error.InvalidBytecode;
            atom_index += 1;
        }

        const block = graph.blocks[block_index];
        const reachable = graph.isReachable(block_index) and
            (!block.has_terminal or position <= block.cutoff_offset);
        if (reachable) switch (code[pc]) {
            op.eval => {
                if (instruction.size != 5) return error.InvalidBytecode;
                const scope = std.mem.readInt(u16, code[pc + 3 ..][0..2], .little);
                try legacy.markEvalCapturedVariables(fd, scope);
            },
            op.apply_eval => {
                if (instruction.size != 3) return error.InvalidBytecode;
                const scope = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little);
                try legacy.markEvalCapturedVariables(fd, scope);
            },
            else => {},
        };

        // phase1Instruction proved this cursor advance is within the
        // u32-sized input stream.
        position += instruction.size;
    }
    if (position != input.code_len or atom_index != input.atom_len)
        return error.InvalidBytecode;
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
    try legacy.resolveEvalGlobalVarTargets(fd);

    const binds = try buildBindIndex(fd.memory, input);
    defer if (binds.len != 0) fd.memory.free(BindEntry, binds);

    var graph: cfg.Graph = .{ .memory = fd.memory };
    defer if (comptime audit_oracles) graph.deinit();
    if (comptime audit_oracles) {
        graph = try cfg.build(fd.memory, input, binds);
        try cfg.auditInstructionOwnership(fd.memory, input, &graph);
    }
    // QuickJS marks captured scopes only when its resolve_variables walk
    // reaches OP_eval / OP_apply_eval (quickjs.c:34247-34262). cfg.build has
    // already decoded every instruction, so use its opcode census rather than
    // rescanning streams that provably contain neither instruction. Do not use
    // fd.has_eval_call here: synthetic/internal Builder callers are allowed to
    // construct the opcode stream without parser metadata.
    if (comptime audit_oracles) {
        if (graph.has_eval_instruction) try markReachableEvalCaptures(input, &graph, fd);
    }

    var product: ResolvedProduct = .{ .memory = fd.memory, .atoms = fd.atoms };
    errdefer product.deinitUncommitted();
    try initializeLabels(&product, input);
    try preallocateProductStreams(&product, input);

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
        .next_bind_offset = if (binds.len != 0)
            binds[0].input_offset
        else
            std.math.maxInt(u64),
        .next_source_offset = if (input.source_len != 0)
            input.source_slots[0].temp_offset
        else
            std.math.maxInt(u64),
        .has_dynamic_env_objects = legacy.functionHasDynamicEnvObjects(&ctx),
        .dynamic_env_closure_len = fd.closure_var.len,
    };
    defer resolver.deinitScratch();
    try resolver.run();
    if (comptime cfg.audit_oracles) {
        try cfg.auditBoundaryUniqueness(
            fd.memory,
            input,
            &graph,
            binds,
            product.label_slots[0..product.label_len],
            product.source_slots[0..product.source_len],
            resolver.opt_boundaries[0..resolver.opt_boundary_len],
        );
    }
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
    try std.testing.expectEqual(@as(u32, 3), product.source_len);
    try std.testing.expectEqual(@as(u32, 0), product.source_slots[0].temp_offset);
    try std.testing.expectEqual(@as(i32, 10), product.source_slots[0].line);
    try std.testing.expectEqual(@as(i32, 2), product.source_slots[0].col);
    try std.testing.expectEqual(@as(u32, 1), product.source_slots[1].temp_offset);
    try std.testing.expectEqual(@as(i32, 10), product.source_slots[1].line);
    try std.testing.expectEqual(@as(i32, 2), product.source_slots[1].col);
    try std.testing.expectEqual(@as(u32, 2), product.source_slots[2].temp_offset);
    try std.testing.expectEqual(@as(i32, 20), product.source_slots[2].line);
    try std.testing.expectEqual(@as(i32, 3), product.source_slots[2].col);
}

test "compiler_v2.resolve_variables: preserves ordered source transitions at one offset" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    try input.addSourceMarker(10, 2);
    try input.addSourceMarker(20, 3);
    try input.emitOp(op.undefined);

    var product = try harness.resolve();
    defer product.deinitUncommitted();

    try expectProductCode(&product, &.{op.undefined});
    try std.testing.expectEqual(@as(u32, 2), product.source_len);
    try std.testing.expectEqual(@as(u32, 0), product.source_slots[0].temp_offset);
    try std.testing.expectEqual(@as(i32, 10), product.source_slots[0].line);
    try std.testing.expectEqual(@as(i32, 2), product.source_slots[0].col);
    try std.testing.expectEqual(@as(u32, 0), product.source_slots[1].temp_offset);
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

test "compiler_v2.resolve_variables: match-barrier nop preserves legacy tail shape" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const boundary = try input.newLabel();
    try input.bindLabelMatchBarrier(boundary);
    try input.emitOp(op.nop);
    try input.emitOp(op.return_undef);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try expectProductCode(&product, &.{ op.nop, op.return_undef });
    try std.testing.expectEqual(@as(u32, 0), product.label_slots[boundary.index()].bound_offset);
    try std.testing.expect(product.label_slots[boundary.index()].flags.match_barrier);
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

test "compiler_v2.resolve_variables: source transitions bound insert3 fold" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    // A changed source before either interior opcode is an inline `line_num`
    // in the legacy phase-1 stream and therefore breaks its exact match.
    try input.emitOp(op.insert3);
    try input.addSourceMarker(10, 2);
    try input.emitOp(op.put_array_el);
    try input.emitOp(op.drop);
    try input.addSourceMarker(20, 3);
    try input.emitOp(op.insert3);
    try input.emitOp(op.put_ref_value);
    try input.addSourceMarker(30, 4);
    try input.emitOp(op.drop);

    // Repeated calls at the same source position are suppressed by legacy
    // `emitSourcePos`, so they must not manufacture a fold barrier.
    try input.addSourceMarker(40, 5);
    try input.emitOp(op.insert3);
    try input.addSourceMarker(40, 5);
    try input.emitOp(op.put_array_el);
    try input.addSourceMarker(40, 5);
    try input.emitOp(op.drop);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try expectProductCode(
        &product,
        &.{
            op.insert3,      op.put_array_el,  op.drop,
            op.insert3,      op.put_ref_value, op.drop,
            op.put_array_el,
        },
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

test "compiler_v2.resolve_variables: later apply_eval capture closes an earlier scope exit" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();

    const captured = try harness.rt.atoms.internString("qcp1-s3-eval-close-before-call");
    defer harness.rt.atoms.free(captured);
    _ = try harness.fd.appendScope(-1);
    const local_index = try harness.fd.addScopeVar(captured, .normal, 0, true, false);
    try harness.input().emitOpU16(op.leave_scope, 0);
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
    _ = try legacy_fd.addScopeVar(captured, .normal, 0, true, false);
    const legacy_input = [_]u8{
        op.leave_scope,  0, 0,
        op.apply_eval,   0, 0,
        op.return_undef,
    };
    try runLegacyForComparison(&legacy_function, &legacy_fd, &legacy_input, &.{});

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(op.close_loc, product.code[0]);
    try std.testing.expectEqual(
        @as(u16, @intCast(local_index)),
        std.mem.readInt(u16, product.code[1..3], .little),
    );
    try expectProductCode(&product, legacy_function.code);
    try expectBindingRowsEqual(&harness.fd, &legacy_fd);
    try snapshot.expectUnchanged(harness.input());
    try expectOwnedAtomRelease(&harness, &product, captured);
}

test "compiler_v2.resolve_variables: local scope_make_ref fold equals legacy" {
    try requireCompilerV2();

    // The corpus never reaches the make_ref fold (a `with` lvalue always needs
    // the var-object probe), so this is the only place the deferred
    // make_ref_tail replacement anchor is exercised: the F3 classifier's
    // `fold_product_unknown` must stay zero here or the class D counts for
    // that kind would be unmeasured rather than measured-as-agreeing.
    cfg.resetAnchorSplitCensus();
    defer cfg.resetAnchorSplitCensus();

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

    if (comptime audit_oracles) {
        const census = cfg.anchorSplitSnapshot();
        try std.testing.expectEqual(
            @as(u64, 2),
            census.fold_by_kind[@intFromEnum(cfg.OptimizationBoundaryKind.make_ref_head)],
        );
        try std.testing.expectEqual(
            @as(u64, 1),
            census.fold_by_kind[@intFromEnum(cfg.OptimizationBoundaryKind.make_ref_tail)],
        );
        try std.testing.expectEqual(@as(u64, 0), census.fold_product_unknown);
        try std.testing.expectEqual(@as(u64, 0), cfg.anchorClassTotal(census, .a));
    }
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

test "compiler_v2.resolve_variables: eval function declaration hoist enters v2 product" {
    try requireCompilerV2();

    var harness: ResolveTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();

    const declared = try harness.rt.atoms.internString("qcp1-s3-eval-function-hoist");
    defer harness.rt.atoms.free(declared);
    harness.fd.is_eval = true;
    harness.fd.body_scope = harness.fd.appendScope(-1) catch return error.OutOfMemory;
    try harness.fd.appendGlobalVar(.{
        .cpool_idx = 0,
        .scope_level = 0,
        .var_name = declared,
    });
    _ = try harness.fd.addClosureVar(.{
        .closure_type = .global_decl,
        .var_kind = .global_function_decl,
        .var_idx = 0,
        .var_name = declared,
    });
    try harness.input().emitOpU16(op.enter_scope, @intCast(harness.fd.body_scope));
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
    legacy_fd.is_eval = true;
    legacy_fd.body_scope = legacy_fd.appendScope(-1) catch return error.OutOfMemory;
    try legacy_fd.appendGlobalVar(.{
        .cpool_idx = 0,
        .scope_level = 0,
        .var_name = declared,
    });
    _ = try legacy_fd.addClosureVar(.{
        .closure_type = .global_decl,
        .var_kind = .global_function_decl,
        .var_idx = 0,
        .var_name = declared,
    });
    const legacy_input = [_]u8{
        op.enter_scope,  0, 0,
        op.return_undef,
    };
    try runLegacyForComparison(&legacy_function, &legacy_fd, &legacy_input, &.{});

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    // Legacy phase 2 selects fclosure8 immediately. The v2 S3 product keeps
    // the wide closure form so label-native S4 performs the one final
    // shortening pass; both retain the same cpool/ref operands.
    try expectProductCode(&product, &.{
        op.fclosure,    0, 0, 0,               0,
        op.put_var_ref, 0, 0, op.return_undef,
    });
    try std.testing.expectEqualSlices(u8, &.{
        op.fclosure8,   0,
        op.put_var_ref, 0,
        0,              op.return_undef,
    }, legacy_function.code);
    try std.testing.expectEqualDeep(
        bytecode.function_def.EvalBindingTarget{ .closure = 0 },
        harness.fd.global_vars[0].eval_target,
    );
    try snapshot.expectUnchanged(harness.input());
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
