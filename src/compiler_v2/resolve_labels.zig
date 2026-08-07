//! QCP-1 compiler-v2 Stage 4: QuickJS resolve_labels port (single forward
//! pass + relocation chains + comptime-selectable plain/short final layout).
//! Direct spec: quickjs.c resolve_labels (34796). Comment each arm qjs:<line>.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("../core/root.zig");
const bytecode = @import("../bytecode.zig");
const builder = @import("builder.zig");
const cfg = @import("cfg.zig");
const labels = @import("labels.zig");
const resolve_variables = @import("resolve_variables.zig");

const opcode = bytecode.opcode;
const op = opcode.op;
const SourceLocSlot = bytecode.pipeline_pc2line.SourceLocSlot;

pub const Error = error{ OutOfMemory, InvalidBytecode, BytecodeOverflow };

pub const LayoutMode = enum { plain, short };

/// The final-layout mode `compileFunctionV2` actually resolves with; the one
/// value handed to `run` on the production path (root.zig). `-Dzjs_v2_layout`
/// selects it and QCP-1 ships `short`. `.plain` stays reachable as the A/B
/// diagnostic instrument (it is how C2-B artifact residency was localised),
/// which is why this is a real option rather than a deleted branch.
///
/// The config signature reads THIS declaration, not the `-D` string, so a
/// build that believes `short` while the compiler resolves with `plain`
/// fails the signature gate instead of reporting green.
pub const default_layout: LayoutMode = std.meta.stringToEnum(
    LayoutMode,
    @import("build_options").zjs_v2_layout,
) orelse @compileError("invalid zjs_v2_layout build option value");

/// Kept private and duplicated from resolve_variables.zig deliberately: both
/// compiler-v2 passes own independent growable outputs and neither frozen
/// predecessor API should grow a shared allocation abstraction for Stage 4.
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

const FinalReloc = struct {
    next: u32,
    addr: u32,
    size: u8,
};

const AuditCanonicalIdentity = if (cfg.audit_oracles) u32 else void;
const no_audit_canonical_identity: AuditCanonicalIdentity = if (cfg.audit_oracles)
    labels.unbound
else {};

const JumpSlot = struct {
    op: u8,
    size: u8,
    pos: u32,
    label: u32,
    canonical_identity: AuditCanonicalIdentity = no_audit_canonical_identity,
};

const BindEntry = struct {
    bound_offset: u32,
    label_index: u32,
    initially_referenced: bool,
    match_barrier: bool,
    dead_skipped: bool = false,
};

fn bindLessThan(_: void, lhs: BindEntry, rhs: BindEntry) bool {
    if (lhs.bound_offset != rhs.bound_offset)
        return lhs.bound_offset < rhs.bound_offset;
    return lhs.label_index < rhs.label_index;
}

fn lowerBoundBindOffset(binds: []const BindEntry, bound_offset: u32) usize {
    var low: usize = 0;
    var high = binds.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (binds[middle].bound_offset < bound_offset)
            low = middle + 1
        else
            high = middle;
    }
    return low;
}

/// Product-coordinate form of cfg.canonicalIdentityAtOffset. Callers already
/// hold the target LabelSlot and pass slot.bound_offset, keeping every jump
/// lookup O(log binds) rather than scanning this offset-primary index by id.
fn canonicalIdentityAtProductOffset(
    binds: []const BindEntry,
    bound_offset: u32,
) ?u32 {
    const first = lowerBoundBindOffset(binds, bound_offset);
    if (first >= binds.len or binds[first].bound_offset != bound_offset) return null;
    return binds[first].label_index;
}

const FinalAliasSplit = struct {
    first_label: u32,
    first_address: u32,
    second_label: u32,
    second_address: u32,
};

fn finalAliasSplit(group: []const BindEntry, addr: []const u32) ?FinalAliasSplit {
    var first_live_label: ?u32 = null;
    for (group) |entry| {
        if (entry.label_index >= addr.len) return null;
        const final_address = addr[entry.label_index];
        if (final_address == labels.unbound) continue;
        if (first_live_label) |first_label| {
            const first_address = addr[first_label];
            if (first_address != final_address) {
                return .{
                    .first_label = first_label,
                    .first_address = first_address,
                    .second_label = entry.label_index,
                    .second_address = final_address,
                };
            }
        } else {
            first_live_label = entry.label_index;
        }
    }
    return null;
}

const AliasLivenessSplit = struct {
    live_label: u32,
    retired_label: u32,
};

fn aliasLivenessSplit(group: []const BindEntry, addr: []const u32) ?AliasLivenessSplit {
    var live_label: ?u32 = null;
    var retired_label: ?u32 = null;
    for (group) |entry| {
        if (entry.label_index >= addr.len) return null;
        if (addr[entry.label_index] == labels.unbound)
            retired_label = retired_label orelse entry.label_index
        else
            live_label = live_label orelse entry.label_index;
        if (live_label != null and retired_label != null) {
            return .{ .live_label = live_label.?, .retired_label = retired_label.? };
        }
    }
    return null;
}

/// A boundary whose whole alias run was retired must have been retired
/// deliberately and must own nothing: it was dead-skipped, holds no relocation
/// and carries no surviving reference.
///
/// `match_barrier` is deliberately NOT a disqualifier. The barrier flag means
/// "Stage 4 must not FOLD across this bind even at ref_count zero"
/// (labels.zig LabelFlags), and `hasBindInRange` — the routine that enforces
/// it — reads `initially_referenced`/`match_barrier` without consulting
/// `dead_skipped`, so retiring the bind keeps the barrier intact. Only
/// `skipDeadCode` can retire a barrier bind (`processBindsAt`'s pass-over loop
/// fails closed on one), and it scans unreachable code only; that is exactly
/// the S4 analogue of resolve_variables' `deadBoundaryAt` unreachable arm,
/// which likewise retires barrier binds. cfg.auditBoundaryUniqueness encodes
/// the same asymmetry in input coordinates.
fn retiredIdentityStillReferenced(entry: BindEntry, slot: labels.LabelSlot) bool {
    return !entry.dead_skipped or
        slot.first_reloc != labels.no_reloc or
        slot.ref_count != 0;
}

fn panicFinalBoundaryUniquenessViolation(
    bucket: cfg.DiffBucket,
    category: []const u8,
    role: []const u8,
    canonical_identities: [2]u32,
    raw_labels: [2]u32,
    product_offsets: [2]u32,
    final_addresses: [2]u32,
) noreturn {
    cfg.recordDiffBucket(bucket);
    std.debug.panic(
        "compiler_v2 oracle violation: bucket={s} category={s} role={s} construct=resolve_labels_v2 key=canonical_identities={d},{d}:raw_labels={d},{d} identities=[canonical_label#{d}@{d}, canonical_label#{d}@{d}] block=none label=none source=none addresses=[{d},{d}]",
        .{
            bucket.name(),
            category,
            role,
            canonical_identities[0],
            canonical_identities[1],
            raw_labels[0],
            raw_labels[1],
            canonical_identities[0],
            product_offsets[0],
            canonical_identities[1],
            product_offsets[1],
            final_addresses[0],
            final_addresses[1],
        },
    );
}

fn resolvedJumpAddress(
    output: []const u8,
    output_len: u32,
    jump: JumpSlot,
) Error!u32 {
    const opcode_delta: u32 = if (isWithOp(jump.op)) 5 else 1;
    if (jump.pos < opcode_delta or jump.pos > output_len or
        @as(usize, jump.pos) + jump.size > output_len or
        output[jump.pos - opcode_delta] != jump.op)
    {
        return error.InvalidBytecode;
    }
    const operand: i64 = switch (jump.size) {
        1 => @as(i8, @bitCast(output[jump.pos])),
        2 => std.mem.readInt(i16, output[jump.pos..][0..2], .little),
        4 => std.mem.readInt(i32, output[jump.pos..][0..4], .little),
        else => return error.InvalidBytecode,
    };
    const target = @as(i64, jump.pos) + operand;
    if (target < 0 or target > output_len) return error.InvalidBytecode;
    return @intCast(target);
}

const SourcePoint = struct {
    line: i32,
    col: i32,
};

fn sourcePointEqual(lhs: SourcePoint, rhs: SourcePoint) bool {
    return lhs.line == rhs.line and lhs.col == rhs.col;
}

const Instruction = struct {
    op_id: u8,
    size: u32,
    format: opcode.Format,
};

fn decodeInstruction(code: []const u8, position: u32) Error!Instruction {
    if (position >= code.len) return error.InvalidBytecode;
    const op_id = code[position];
    // qjs:34900 reads ONE `opcode_info[op]` row and takes both `.size` and
    // `.fmt` out of it. `sizeOf`/`formatOf` each re-derive the short-opcode
    // index and then stride the 24-byte diagnostic `Info` row separately, so
    // every S4 decode paid two address computations and two loads into a table
    // six times larger than it needs to be. `compact_opcode_info` is the
    // four-byte production row QuickJS actually compiles (bytecode.zig
    // `CompactInfo`, "do not make each verifier instruction stride across a
    // 24-byte row just to read these four fields"). Take both fields from it.
    const info = opcode.finalCompactInfo(op_id) orelse return error.InvalidBytecode;
    const size = info.size;
    // `position < code.len` makes the subtraction well-defined, and this
    // comparison proves the caller's subsequent `position + size` is within
    // the u32-sized product stream. Do not encode the same proof again as a
    // checked add in every S4 decode (QuickJS uses pos + len after its table
    // lookup for the same reason).
    if (size == 0 or size > code.len - position)
        return error.InvalidBytecode;
    return .{ .op_id = op_id, .size = size, .format = info.fmt };
}

fn isJumpOp(op_id: u8) bool {
    return op_id == op.if_false or op_id == op.if_true or op_id == op.goto or
        op_id == op.@"catch" or op_id == op.gosub;
}

fn isWithOp(op_id: u8) bool {
    return op_id == op.with_get_var or op_id == op.with_put_var or
        op_id == op.with_delete_var or op_id == op.with_make_ref or
        op_id == op.with_get_ref;
}

fn hasAtomFormat(format: opcode.Format) bool {
    return format == .atom or format == .atom_u8 or format == .atom_u16 or
        format == .atom_label_u8 or format == .atom_label_u16;
}

fn readU16(code: []const u8, position: u32) Error!u16 {
    const start = std.math.add(u32, position, 1) catch return error.InvalidBytecode;
    if (@as(usize, start) + 2 > code.len) return error.InvalidBytecode;
    return std.mem.readInt(u16, code[start..][0..2], .little);
}

fn readU32At(code: []const u8, position: u32, delta: u32) Error!u32 {
    const start = std.math.add(u32, position, delta) catch
        return error.InvalidBytecode;
    if (@as(usize, start) + 4 > code.len) return error.InvalidBytecode;
    return std.mem.readInt(u32, code[start..][0..4], .little);
}

fn readI32(code: []const u8, position: u32) Error!i32 {
    const start = std.math.add(u32, position, 1) catch return error.InvalidBytecode;
    if (@as(usize, start) + 4 > code.len) return error.InvalidBytecode;
    return std.mem.readInt(i32, code[start..][0..4], .little);
}

/// Cheap structural preflight needed before constructing slices and the
/// offset-primary bind/source cursors.  Keep this proof on every entry path:
/// the main walk relies on sorted sources and coherent bound-label metadata.
fn validateProductMetadata(product: *const resolve_variables.ResolvedProduct) Error!void {
    if (product.code_len > product.code.len or
        product.atom_len > product.atom_operands.len or
        product.label_len > product.label_slots.len or
        product.source_len > product.source_slots.len)
    {
        return error.InvalidBytecode;
    }

    var previous_source: u32 = 0;
    for (product.source_slots[0..product.source_len], 0..) |source, index| {
        if (source.temp_offset > product.code_len or source.line <= 0 or source.col <= 0 or
            (index != 0 and source.temp_offset < previous_source))
        {
            return error.InvalidBytecode;
        }
        previous_source = source.temp_offset;
    }

    for (product.label_slots[0..product.label_len]) |slot| {
        if (slot.first_reloc != labels.no_reloc) return error.InvalidBytecode;
        if (slot.flags.bound) {
            if (slot.bound_offset == labels.unbound or slot.bound_offset > product.code_len)
                return error.InvalidBytecode;
        } else if (slot.bound_offset != labels.unbound) {
            return error.InvalidBytecode;
        }
    }
}

/// Full S3 byte-stream proof for standalone callers.  The production packed
/// path receives this stream directly from resolve_variables, whose output
/// walk already emits opcode-sized instructions and parallel atom/label
/// ledgers.  resolve_labels then decodes those same bytes while consuming
/// them, and the packed finalizer validates the resulting S4 stream in its
/// fused owner/var-ref walk.  QuickJS likewise trusts the internal bytecode
/// handed from resolve_variables to resolve_labels (quickjs.c:34796) instead
/// of running an extra validation traversal between the two passes.
fn validateProductCode(product: *const resolve_variables.ResolvedProduct) Error!void {
    const code = product.code[0..product.code_len];
    var atom_index: u32 = 0;
    var position: u32 = 0;
    while (position < product.code_len) {
        const instruction = try decodeInstruction(code, position);
        if (instruction.op_id == op.invalid) return error.InvalidBytecode;

        switch (instruction.format) {
            .label => {
                if (!isJumpOp(instruction.op_id) or instruction.size != 5)
                    return error.InvalidBytecode;
                const label_index = try readU32At(code, position, 1);
                if (label_index >= product.label_len) return error.InvalidBytecode;
            },
            .atom_label_u8 => {
                if (!isWithOp(instruction.op_id) or instruction.size != 10)
                    return error.InvalidBytecode;
                const label_index = try readU32At(code, position, 5);
                if (label_index >= product.label_len) return error.InvalidBytecode;
            },
            // S3 emits only wide logical LabelIds. Accepting a final short or
            // another label-bearing format here would reinterpret a relative
            // operand as an identity and silently corrupt the side table.
            .label8, .label16, .label_u16, .atom_label_u16 => return error.InvalidBytecode,
            else => {},
        }

        if (hasAtomFormat(instruction.format)) {
            if (instruction.size < 5 or atom_index >= product.atom_len)
                return error.InvalidBytecode;
            const encoded = try readU32At(code, position, 1);
            if (encoded != product.atom_operands[atom_index])
                return error.InvalidBytecode;
            atom_index += 1;
        }
        position += instruction.size;
    }
    if (position != product.code_len or atom_index != product.atom_len)
        return error.InvalidBytecode;
}

fn updateLabel(
    product: *resolve_variables.ResolvedProduct,
    label_index: u32,
    delta: i32,
) Error!u32 {
    if (label_index >= product.label_len) return error.InvalidBytecode;
    const slot = &product.label_slots[label_index];
    if (delta < 0) {
        const amount: u32 = @intCast(-@as(i64, delta));
        if (slot.ref_count < amount) return error.InvalidBytecode;
        slot.ref_count -= amount;
    } else if (delta > 0) {
        const amount: u32 = @intCast(delta);
        slot.ref_count = std.math.add(u32, slot.ref_count, amount) catch
            return error.InvalidBytecode;
    }
    return slot.ref_count;
}

const PatternToken = struct {
    options: []const u8,
    idx: ?u16 = null,
};

const SeqMatch = struct {
    end: u32,
    // Every consumer needs at most the first two operand positions. The
    // matched opcode is already present at code[position], so returning a
    // second eight-byte opcode ledger merely inflated every successful and
    // failed matcher result. QuickJS's code_match likewise publishes only
    // the few fields its caller asks for through CodeContext.
    positions: [2]u32,
};

const Resolver = struct {
    function: *bytecode.Bytecode,
    fd: ?*const bytecode.function_def.FunctionDef,
    product: *resolve_variables.ResolvedProduct,
    memory: *core.memory.MemoryAccount,
    atoms: *core.atom.AtomTable,
    code: []const u8,
    input_atoms: []const core.atom.Atom,
    input_sources: []const builder.SourceSlot,

    addr: []u32 = &.{},
    binds: []BindEntry = &.{},
    jump_slots: []JumpSlot = &.{},

    relocs: []FinalReloc = &.{},
    reloc_capacity: usize = 0,
    reloc_len: u32 = 0,

    output: []u8 = &.{},
    output_capacity: usize = 0,
    output_len: u32 = 0,

    output_atoms: []core.atom.Atom = &.{},
    output_atom_capacity: usize = 0,
    output_atom_len: u32 = 0,
    /// False while the S4 output ledger borrows the S3 owners. It becomes true
    /// only after a successful walk transfers the retained subsequence out of
    /// `product`; error paths therefore leave the input ledger owning every
    /// atom and free only the uncommitted output backing.
    output_atoms_owned: bool = false,

    output_sources: []SourceLocSlot = &.{},
    output_source_capacity: usize = 0,
    output_source_len: u32 = 0,

    bind_cursor: usize = 0,
    /// Product offset of `binds[bind_cursor]`, or `maxInt` once the sorted
    /// bind side table is exhausted. QuickJS reaches OP_label as an ordinary
    /// switch arm of the same walk (qjs:34911), so an instruction that carries
    /// no identity pays nothing at all for the label machinery. V2 keeps
    /// identities out of band; this frontier gives them the same zero cost,
    /// and is the idiom `resolve_variables` already uses for both of its side
    /// tables (`refreshBindFrontier` / `refreshSourceFrontier` there).
    next_bind_offset: u64 = std.math.maxInt(u64),
    jump_count: u32 = 0,
    atom_cursor: u32 = 0,
    source_cursor: u32 = 0,
    source_attach_cursor: u32 = 0,
    last_attached_source: ?SourcePoint = null,

    fn deinit(self: *Resolver) void {
        if (self.output_atoms_owned) {
            for (self.output_atoms[0..self.output_atom_len]) |atom_id|
                self.atoms.free(atom_id);
        }
        if (self.output_atom_capacity != 0)
            self.memory.free(core.atom.Atom, self.output_atoms);
        if (self.output_capacity != 0) self.memory.free(u8, self.output);
        if (self.output_source_capacity != 0)
            self.memory.free(SourceLocSlot, self.output_sources);
        if (self.reloc_capacity != 0) self.memory.free(FinalReloc, self.relocs);
        if (self.addr.len != 0) self.memory.free(u32, self.addr);
        if (self.binds.len != 0) self.memory.free(BindEntry, self.binds);
        if (self.jump_slots.len != 0) self.memory.free(JumpSlot, self.jump_slots);

        self.output_atoms = &.{};
        self.output_atom_capacity = 0;
        self.output_atom_len = 0;
        self.output_atoms_owned = false;
        self.output = &.{};
        self.output_capacity = 0;
        self.output_len = 0;
        self.output_sources = &.{};
        self.output_source_capacity = 0;
        self.output_source_len = 0;
        self.relocs = &.{};
        self.reloc_capacity = 0;
        self.reloc_len = 0;
        self.addr = &.{};
        self.binds = &.{};
        self.jump_slots = &.{};
    }

    fn releaseConsumedProduct(self: *Resolver) Error!void {
        // QuickJS copies atom ids between its resolve_labels DynBufs without
        // changing their reference counts: the new buffer inherits the old
        // buffer's owners. S4 never invents or reorders atom-bearing values;
        // its output atom ledger is a retained subsequence of S3. Prove that
        // invariant before changing either owner's state, then move those
        // references and let releaseConsumedStreams free only discarded ones.
        var input_index: usize = 0;
        var output_index: usize = 0;
        while (output_index < self.output_atom_len) : (output_index += 1) {
            const output_atom = self.output_atoms[output_index];
            while (input_index < self.input_atoms.len and
                self.input_atoms[input_index] != output_atom) : (input_index += 1)
            {}
            if (input_index == self.input_atoms.len)
                return error.InvalidBytecode;
            input_index += 1;
        }

        input_index = 0;
        output_index = 0;
        while (output_index < self.output_atom_len) : (output_index += 1) {
            const output_atom = self.output_atoms[output_index];
            while (self.input_atoms[input_index] != output_atom) : (input_index += 1) {}
            self.product.atom_operands[input_index] = core.atom.null_atom;
            input_index += 1;
        }
        self.output_atoms_owned = true;
        self.code = &.{};
        self.input_atoms = &.{};
        self.input_sources = &.{};
        self.product.releaseConsumedStreams();
    }

    fn initScratch(self: *Resolver, comptime layout: LayoutMode) Error!void {
        if (self.product.label_len != 0) {
            self.addr = self.memory.alloc(u32, self.product.label_len) catch
                return error.OutOfMemory;
            @memset(self.addr, labels.unbound);
        }

        var bind_count: usize = 0;
        for (self.product.label_slots[0..self.product.label_len]) |slot| {
            if (slot.flags.bound) bind_count += 1;
        }
        if (bind_count != 0) {
            self.binds = self.memory.alloc(BindEntry, bind_count) catch
                return error.OutOfMemory;
            var index: usize = 0;
            for (self.product.label_slots[0..self.product.label_len], 0..) |slot, label_index| {
                if (!slot.flags.bound) continue;
                self.binds[index] = .{
                    .bound_offset = slot.bound_offset,
                    .label_index = @intCast(label_index),
                    // Stage 4's match barriers are defined by the immutable
                    // input target topology, not by refcounts later consumed
                    // while branches are threaded or folded.
                    .initially_referenced = slot.ref_count != 0,
                    .match_barrier = slot.flags.match_barrier,
                };
                index += 1;
            }
            std.mem.sort(BindEntry, self.binds, {}, bindLessThan);
        }
        self.refreshBindFrontier();

        if (self.product.jump_size != 0) {
            self.jump_slots = self.memory.alloc(JumpSlot, self.product.jump_size) catch
                return error.OutOfMemory;
        }

        // Stage 4's ordinary rewrites copy or shrink the S3 stream; only the
        // function prologue grows it.  Size that prologue exactly and reserve
        // the common output once.  Keep the cold growth path below because a
        // future rewrite is allowed to expand without turning this sizing
        // observation into a memory-safety contract.
        const initial_output_capacity = std.math.add(
            u32,
            self.product.code_len,
            try self.functionPrologueSize(layout),
        ) catch return error.BytecodeOverflow;
        if (initial_output_capacity != 0) {
            try reserve(
                u8,
                self.memory,
                &self.output,
                &self.output_capacity,
                0,
                initial_output_capacity,
                32,
            );
        }

        // Every final source slot comes from exactly one entry in the S3
        // source ledger.  Peepholes may discard entries, coalesce equal
        // coordinates, or defer a consumed subrange, but they never invent
        // another source event.  Reserve that hard upper bound once so the
        // per-instruction source path only publishes into contiguous storage.
        // Keep ensureOutputSources' cold growth path as a defensive contract
        // for future rewrites that may legitimately synthesize an event.
        if (self.input_sources.len != 0) {
            try reserve(
                SourceLocSlot,
                self.memory,
                &self.output_sources,
                &self.output_source_capacity,
                0,
                self.input_sources.len,
                8,
            );
        }

        // resolve_labels only drops or retains atom-bearing instructions; it
        // never synthesizes another atom owner. Reserve the exact hard upper
        // bound once, then publish borrowed ids in the hot walk without a
        // retain and without geometric ledger growth.
        if (self.input_atoms.len != 0) {
            try reserve(
                core.atom.Atom,
                self.memory,
                &self.output_atoms,
                &self.output_atom_capacity,
                0,
                self.input_atoms.len,
                8,
            );
        }
    }

    noinline fn growOutput(self: *Resolver, need: usize) Error!void {
        if (need > std.math.maxInt(u32)) return error.BytecodeOverflow;
        _ = std.math.add(u32, self.output_len, @as(u32, @intCast(need))) catch
            return error.BytecodeOverflow;
        try reserve(
            u8,
            self.memory,
            &self.output,
            &self.output_capacity,
            self.output_len,
            need,
            32,
        );
    }

    inline fn ensureOutput(self: *Resolver, need: usize) Error!void {
        const used: usize = @intCast(self.output_len);
        std.debug.assert(used <= self.output_capacity);
        if (need <= self.output_capacity - used) return;
        return self.growOutput(need);
    }

    noinline fn growOutputSources(self: *Resolver, need: usize) Error!void {
        if (need > std.math.maxInt(u32)) return error.BytecodeOverflow;
        _ = std.math.add(u32, self.output_source_len, @as(u32, @intCast(need))) catch
            return error.BytecodeOverflow;
        try reserve(
            SourceLocSlot,
            self.memory,
            &self.output_sources,
            &self.output_source_capacity,
            self.output_source_len,
            need,
            8,
        );
    }

    inline fn ensureOutputSources(self: *Resolver, need: usize) Error!void {
        const used: usize = @intCast(self.output_source_len);
        std.debug.assert(used <= self.output_source_capacity);
        if (need <= self.output_source_capacity - used) return;
        return self.growOutputSources(need);
    }

    inline fn appendByte(self: *Resolver, value: u8) Error!void {
        try self.ensureOutput(1);
        self.output[self.output_len] = value;
        self.output_len += 1;
    }

    inline fn appendRaw(self: *Resolver, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        try self.ensureOutput(bytes.len);
        const start: usize = @intCast(self.output_len);
        @memcpy(self.output[start..][0..bytes.len], bytes);
        self.output_len += @intCast(bytes.len);
    }

    inline fn appendU16(self: *Resolver, value: u16) Error!void {
        try self.ensureOutput(2);
        const start: usize = @intCast(self.output_len);
        std.mem.writeInt(u16, self.output[start..][0..2], value, .little);
        self.output_len += 2;
    }

    inline fn appendI16(self: *Resolver, value: i16) Error!void {
        try self.ensureOutput(2);
        const start: usize = @intCast(self.output_len);
        std.mem.writeInt(i16, self.output[start..][0..2], value, .little);
        self.output_len += 2;
    }

    inline fn appendU32(self: *Resolver, value: u32) Error!void {
        try self.ensureOutput(4);
        const start: usize = @intCast(self.output_len);
        std.mem.writeInt(u32, self.output[start..][0..4], value, .little);
        self.output_len += 4;
    }

    inline fn appendI32(self: *Resolver, value: i32) Error!void {
        try self.ensureOutput(4);
        const start: usize = @intCast(self.output_len);
        std.mem.writeInt(i32, self.output[start..][0..4], value, .little);
        self.output_len += 4;
    }

    fn appendOutputAtom(self: *Resolver, atom_id: core.atom.Atom) Error!void {
        if (self.output_atom_len == std.math.maxInt(u32))
            return error.BytecodeOverflow;
        if (self.output_atom_len >= self.output_atom_capacity)
            return error.InvalidBytecode;
        self.output_atoms[self.output_atom_len] = atom_id;
        self.output_atom_len += 1;
    }

    fn consumeAtomsRange(
        self: *Resolver,
        start: u32,
        end: u32,
        keep_atom_position: ?u32,
    ) Error!void {
        if (start > end or end > self.product.code_len)
            return error.InvalidBytecode;
        var position = start;
        var kept = false;
        while (position < end) {
            const instruction = try decodeInstruction(self.code, position);
            const position_next = position + instruction.size;
            if (position_next > end) return error.InvalidBytecode;
            if (hasAtomFormat(instruction.format)) {
                if (self.atom_cursor >= self.input_atoms.len)
                    return error.InvalidBytecode;
                const encoded = try readU32At(self.code, position, 1);
                const ledger_atom = self.input_atoms[self.atom_cursor];
                if (encoded != ledger_atom) return error.InvalidBytecode;
                if (keep_atom_position != null and keep_atom_position.? == position) {
                    try self.appendOutputAtom(ledger_atom);
                    kept = true;
                }
                self.atom_cursor += 1;
            }
            position = position_next;
        }
        if (position != end or (keep_atom_position != null and !kept))
            return error.InvalidBytecode;
    }

    /// Consume the atom ledger entry for an instruction the main S4 walk has
    /// already decoded.  The range form above is still required for skipped
    /// peephole tails, but using it for the ordinary one-instruction case
    /// decoded every non-atom opcode a second time merely to discover that it
    /// had no atom.  QuickJS's atom operand is carried by that same bytecode
    /// instruction, so its resolve_labels walk pays no corresponding rescan.
    fn consumeInstructionAtom(
        self: *Resolver,
        position: u32,
        instruction: Instruction,
        keep: bool,
    ) Error!void {
        if (!hasAtomFormat(instruction.format)) return;
        if (self.atom_cursor >= self.input_atoms.len)
            return error.InvalidBytecode;
        const encoded = try readU32At(self.code, position, 1);
        const ledger_atom = self.input_atoms[self.atom_cursor];
        if (encoded != ledger_atom) return error.InvalidBytecode;
        if (keep) try self.appendOutputAtom(ledger_atom);
        self.atom_cursor += 1;
    }

    fn absorbSources(self: *Resolver, limit: u32) void {
        while (self.source_cursor < self.input_sources.len and
            self.input_sources[self.source_cursor].temp_offset < limit)
        {
            self.source_cursor += 1;
        }
    }

    fn absorbSourcesAtEnd(self: *Resolver) void {
        while (self.source_cursor < self.input_sources.len and
            self.input_sources[self.source_cursor].temp_offset <= self.product.code_len)
        {
            self.source_cursor += 1;
        }
    }

    fn hasInputSourceAt(self: *const Resolver, input_pos: u32) bool {
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
        return low < self.input_sources.len and
            self.input_sources[low].temp_offset == input_pos;
    }

    /// qjs:34547 add_pc2line_info. Preserve every source transition absorbed
    /// across a peephole match at the replacement instruction's PC, exactly
    /// like the legacy old-PC relocation table. Consecutive equal coordinates
    /// still dedupe before pc2line encoding.
    inline fn attachSource(self: *Resolver) Error!void {
        if (self.source_attach_cursor == self.source_cursor) return;
        if (self.source_attach_cursor > self.source_cursor)
            return error.InvalidBytecode;

        // The normal walk consumes one instruction's source event and emits
        // it immediately.  Keep that overwhelmingly common case inline; only
        // peepholes spanning several instructions need the outlined range
        // loop below.
        if (self.source_attach_cursor == self.source_cursor - 1) {
            const source = self.input_sources[self.source_attach_cursor];
            const pending = SourcePoint{ .line = source.line, .col = source.col };
            if (self.last_attached_source) |last| {
                if (sourcePointEqual(last, pending)) {
                    self.source_attach_cursor += 1;
                    return;
                }
            }
            try self.ensureOutputSources(1);
            self.output_sources[self.output_source_len] = .{
                .pc = self.output_len,
                .line_num = pending.line,
                .col_num = pending.col,
            };
            self.output_source_len += 1;
            self.source_attach_cursor += 1;
            self.last_attached_source = pending;
            return;
        }
        return self.attachSourceSlow();
    }

    noinline fn attachSourceSlow(self: *Resolver) Error!void {
        const pending_count = self.source_cursor - self.source_attach_cursor;
        std.debug.assert(pending_count != 0);
        try self.ensureOutputSources(pending_count);
        while (self.source_attach_cursor < self.source_cursor) {
            const source = self.input_sources[self.source_attach_cursor];
            self.source_attach_cursor += 1;
            const pending = SourcePoint{ .line = source.line, .col = source.col };
            if (self.last_attached_source) |last| {
                if (sourcePointEqual(last, pending)) continue;
            }
            self.output_sources[self.output_source_len] = .{
                .pc = self.output_len,
                .line_num = pending.line,
                .col_num = pending.col,
            };
            self.output_source_len += 1;
            self.last_attached_source = pending;
        }
    }

    /// Publish an already-consumed input-source subrange at a later output
    /// boundary. Legacy resolve_labels maps the source before the
    /// push_atom_value consumed by the typeof-string fold to the instruction
    /// after the replacement test; later consumed compare/branch markers map
    /// backwards and are consequently not published. Keep that exact ordered
    /// source contract without materializing old-PC relocation coordinates.
    fn attachInputSourceRangeAt(
        self: *Resolver,
        start: u32,
        end: u32,
        output_pc: u32,
    ) Error!void {
        if (start > end or end > self.input_sources.len) return error.InvalidBytecode;
        if (self.output_source_len != 0 and
            self.output_sources[self.output_source_len - 1].pc > output_pc)
        {
            return error.InvalidBytecode;
        }
        const pending_count = end - start;
        try self.ensureOutputSources(pending_count);
        var index = start;
        while (index < end) : (index += 1) {
            const source = self.input_sources[index];
            const pending = SourcePoint{ .line = source.line, .col = source.col };
            if (self.last_attached_source) |last| {
                if (sourcePointEqual(last, pending)) continue;
            }
            self.output_sources[self.output_source_len] = .{
                .pc = output_pc,
                .line_num = pending.line,
                .col_num = pending.col,
            };
            self.output_source_len += 1;
            self.last_attached_source = pending;
        }
    }

    fn lowerBoundBind(self: *const Resolver, position: u32) usize {
        var low: usize = 0;
        var high = self.binds.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.binds[middle].bound_offset < position)
                low = middle + 1
            else
                high = middle;
        }
        return low;
    }

    fn hasBindInRange(self: *const Resolver, start: u32, end: u32) bool {
        if (start >= end) return false;
        var index = self.lowerBoundBind(start);
        while (index < self.binds.len and self.binds[index].bound_offset < end) : (index += 1) {
            const label_index = self.binds[index].label_index;
            std.debug.assert(label_index < self.product.label_len);
            // Absolute-PC patch targets become transparent after losing every
            // input reference. Explicit parser-label binds retain the physical
            // OP_label sequential-match barrier even at ref_count zero. An
            // original phase-2 target also remains a barrier after an earlier
            // fold consumes its live refcount.
            if (label_index < self.product.label_len and
                (self.binds[index].initially_referenced or
                    self.binds[index].match_barrier))
            {
                return true;
            }
        }
        return false;
    }

    fn readIndex(self: *const Resolver, position: u32) Error!u16 {
        const instruction = try decodeInstruction(self.code, position);
        return switch (instruction.format) {
            .u8, .i8, .loc8, .const8 => self.code[position + 1],
            .u16, .npop, .loc, .arg, .var_ref => try readU16(self.code, position),
            else => error.InvalidBytecode,
        };
    }

    /// qjs:33881 code_match, with source markers already out of band. A bind
    /// at any byte boundary in the candidate range rejects the match exactly
    /// as an OP_label byte would have rejected QuickJS's sequential matcher.
    fn matchSeq(
        self: *const Resolver,
        start: u32,
        tokens: []const PatternToken,
    ) Error!?SeqMatch {
        if (tokens.len > 8) return error.InvalidBytecode;
        var result: SeqMatch = undefined;
        var position = start;
        for (tokens, 0..) |token, token_index| {
            if (token.options.len == 0 or position >= self.product.code_len)
                return null;
            const instruction = try decodeInstruction(self.code, position);
            if (token.options.len == 1) {
                if (instruction.op_id != token.options[0]) return null;
            } else {
                var selected = false;
                for (token.options) |candidate| {
                    if (instruction.op_id == candidate) {
                        selected = true;
                        break;
                    }
                }
                if (!selected) return null;
            }
            if (token.idx) |expected| {
                // The instruction was decoded immediately above. Reuse its
                // format instead of paying a second metadata lookup and a
                // second bounds proof for every indexed pattern.
                const actual: u16 = switch (instruction.format) {
                    .u8, .i8, .loc8, .const8 => self.code[position + 1],
                    .u16, .npop, .loc, .arg, .var_ref => try readU16(self.code, position),
                    else => return error.InvalidBytecode,
                };
                if (actual != expected) return null;
            }
            if (token_index < result.positions.len) {
                result.positions[token_index] = position;
            }
            position += instruction.size;
        }
        if (self.hasBindInRange(start, position)) return null;
        result.end = position;
        return result;
    }

    fn addReloc(self: *Resolver, label_index: u32, addr_value: u32, size: u8) Error!void {
        if (label_index >= self.product.label_len) return error.InvalidBytecode;
        if (self.reloc_len == labels.no_reloc) return error.BytecodeOverflow;
        try reserve(
            FinalReloc,
            self.memory,
            &self.relocs,
            &self.reloc_capacity,
            self.reloc_len,
            1,
            8,
        );
        const slot = &self.product.label_slots[label_index];
        self.relocs[self.reloc_len] = .{
            .next = slot.first_reloc,
            .addr = addr_value,
            .size = size,
        };
        slot.first_reloc = self.reloc_len;
        self.reloc_len += 1;
    }

    fn writeRelative(self: *Resolver, operand_pos: u32, size: u8, diff: i64) Error!void {
        if (@as(usize, operand_pos) + size > self.output_len)
            return error.InvalidBytecode;
        const start: usize = @intCast(operand_pos);
        switch (size) {
            1 => {
                if (diff < std.math.minInt(i8) or diff > std.math.maxInt(i8))
                    return error.InvalidBytecode;
                self.output[start] = @bitCast(@as(i8, @intCast(diff)));
            },
            2 => {
                if (diff < std.math.minInt(i16) or diff > std.math.maxInt(i16))
                    return error.InvalidBytecode;
                std.mem.writeInt(
                    i16,
                    self.output[start..][0..2],
                    @intCast(diff),
                    .little,
                );
            },
            4 => {
                if (diff < std.math.minInt(i32) or diff > std.math.maxInt(i32))
                    return error.BytecodeOverflow;
                std.mem.writeInt(
                    i32,
                    self.output[start..][0..4],
                    @intCast(diff),
                    .little,
                );
            },
            else => return error.InvalidBytecode,
        }
    }

    /// A peephole may span compact side-table binds that became unreferenced
    /// after its edge was threaded. Legacy absolute-PC joins have no
    /// materialized OP_label byte in that case, so consume those dead binds
    /// just as skipDeadCode does. A live or already-relocated bind remains a
    /// fail-closed interior target. Every consumer of a spanned range must
    /// retire them before handing the range on: `skipDeadCode` fails closed on
    /// a bind cursor left behind its start.
    fn retireSpannedDeadBinds(self: *Resolver, position: u32) Error!void {
        while (self.bind_cursor < self.binds.len and
            self.binds[self.bind_cursor].bound_offset < position)
        {
            const entry = self.binds[self.bind_cursor];
            if (entry.label_index >= self.product.label_len)
                return error.InvalidBytecode;
            const slot = &self.product.label_slots[entry.label_index];
            if (entry.match_barrier or slot.ref_count != 0 or
                slot.first_reloc != labels.no_reloc or
                self.addr[entry.label_index] != labels.unbound)
            {
                return error.InvalidBytecode;
            }
            self.binds[self.bind_cursor].dead_skipped = true;
            self.bind_cursor += 1;
        }
        self.refreshBindFrontier();
    }

    inline fn refreshBindFrontier(self: *Resolver) void {
        self.next_bind_offset = if (self.bind_cursor < self.binds.len)
            self.binds[self.bind_cursor].bound_offset
        else
            std.math.maxInt(u64);
    }

    /// qjs:34911-34939 OP_label, represented by the sorted bind side table.
    /// `binds` is sorted by product offset and `bind_cursor` only moves
    /// forward, so a frontier strictly past `position` proves BOTH loops below
    /// would find nothing: every unconsumed bind is at or past the frontier,
    /// hence none is `< position` for `retireSpannedDeadBinds` and none is
    /// `== position` for the pass-over loop. That compare is then the whole
    /// per-instruction cost of the out-of-band identity table.
    inline fn processBindsAt(self: *Resolver, position: u32) Error!void {
        if (position < self.next_bind_offset) return;
        return self.processBindsAtCold(position);
    }

    noinline fn processBindsAtCold(self: *Resolver, position: u32) Error!void {
        try self.retireSpannedDeadBinds(position);
        while (self.bind_cursor < self.binds.len and
            self.binds[self.bind_cursor].bound_offset == position)
        {
            const entry = self.binds[self.bind_cursor];
            self.bind_cursor += 1;
            if (entry.dead_skipped) continue;
            if (entry.label_index >= self.product.label_len or
                self.addr[entry.label_index] != labels.unbound)
            {
                return error.InvalidBytecode;
            }
            self.addr[entry.label_index] = self.output_len;
            const slot = &self.product.label_slots[entry.label_index];
            var reloc_index = slot.first_reloc;
            var walked: u32 = 0;
            while (reloc_index != labels.no_reloc) {
                if (reloc_index >= self.reloc_len or walked >= self.reloc_len)
                    return error.InvalidBytecode;
                const relocation = self.relocs[reloc_index];
                const diff = @as(i64, self.output_len) - @as(i64, relocation.addr);
                try self.writeRelative(relocation.addr, relocation.size, diff);
                reloc_index = relocation.next;
                walked += 1;
            }
            slot.first_reloc = labels.no_reloc;
        }
        self.refreshBindFrontier();
    }

    fn appendJumpSlot(
        self: *Resolver,
        op_id: u8,
        size: u8,
        operand_pos: u32,
        label_index: u32,
    ) Error!u32 {
        if (self.jump_count >= self.jump_slots.len)
            return error.InvalidBytecode;
        const index = self.jump_count;
        self.jump_slots[index] = .{
            .op = op_id,
            .size = size,
            .pos = operand_pos,
            .label = label_index,
        };
        if (comptime cfg.audit_oracles) {
            if (label_index >= self.product.label_len)
                return error.InvalidBytecode;
            const slot = self.product.label_slots[label_index];
            if (!slot.flags.bound or slot.bound_offset == labels.unbound)
                return error.InvalidBytecode;
            self.jump_slots[index].canonical_identity =
                canonicalIdentityAtProductOffset(self.binds, slot.bound_offset) orelse
                return error.InvalidBytecode;
        }
        self.jump_count += 1;
        return index;
    }

    /// Two `LabelId`s bound at the same temporary-stream offset denote one
    /// program point. QuickJS never has to say so: its `code_has_label`
    /// (qjs:34633) compares label numbers because its switch parser patches
    /// the dispatch operand backwards onto the single default label. v2's
    /// label discipline forbids that patch, so the identity-native dispatch
    /// bridge routes the clause fallthrough and the default body through two
    /// distinct ids that always bind together. The legacy backend, which the
    /// dual oracle measures against, compares resolved addresses
    /// (`targetAppearsAtFollowingBoundary`, bytecode.zig) and therefore sees
    /// the co-bound pair as one boundary.
    fn labelsShareBindOffset(self: *const Resolver, left: u32, right: u32) Error!bool {
        if (left >= self.product.label_len or right >= self.product.label_len)
            return error.InvalidBytecode;
        if (left == right) return true;
        const left_slot = self.product.label_slots[left];
        const right_slot = self.product.label_slots[right];
        if (!left_slot.flags.bound or !right_slot.flags.bound) return false;
        if (left_slot.bound_offset == labels.unbound or
            right_slot.bound_offset == labels.unbound) return false;
        return left_slot.bound_offset == right_slot.bound_offset;
    }

    /// The identity-native switch default bridge, seen from the front: a
    /// source-less backward `goto DEFAULT_BODY` entered only through no-match
    /// dispatch binds that this walk has already consumed. It is the exact
    /// instruction legacy never materializes — legacy patches the dispatch
    /// operand straight onto the default body — so it must stay invisible to
    /// the qjs:34968-34982 next-label check. Otherwise
    /// `if_false NO_MATCH ; goto BREAK ; NO_MATCH: goto DEFAULT` reads as
    /// qjs's `if_X L1 ; goto L2 ; L1:` inversion and v2 emits
    /// `if_true BREAK ; goto DEFAULT` where legacy emits a plain
    /// `if_false DEFAULT` whose fallthrough goto folds away. Reached by a
    /// leading `default` whose switch ends in a `break`-only or empty clause,
    /// e.g. `switch (m) { default: a(); break; case 3: break; }`.
    ///
    /// The three traits are all load-bearing and deliberately narrow. Dropping
    /// any of them and asking only "is this boundary unreachable" regresses
    /// box2d/code-load/crypto/earley-boyer/mandreel/typescript/v8-v7/zlib:
    /// legacy keeps plenty of other unreachable goto aliases and inverts
    /// against them. `deadSwitchTrampolineCanReachLabel` reads the same shape
    /// from behind, for the goto arm.
    ///
    /// The switch epilogue no longer emits the bridge — it moves the
    /// unmatched-dispatch references onto the default identity
    /// (`Builder.retargetLabelRefs`), the same thing legacy's `patchJumpTarget`
    /// does — so this predicate is retained as the narrow fold suppressor it
    /// always was, not as a description of code the parser still produces.
    /// Removing a fold suppressor can only widen folding, which is the exact
    /// direction that regressed eight benchmarks above.
    fn isSwitchDispatchBridgeAt(self: *const Resolver, position: u32) Error!bool {
        if (position >= self.product.code_len) return false;
        if (self.hasInputSourceAt(position)) return false;
        const instruction = try decodeInstruction(self.code, position);
        if (instruction.op_id != op.goto) return false;
        const target = try readU32At(self.code, position, 1);
        if (target >= self.product.label_len) return error.InvalidBytecode;
        const target_slot = self.product.label_slots[target];
        if (!target_slot.flags.bound or target_slot.bound_offset == labels.unbound or
            target_slot.bound_offset >= position) return false;
        var index = self.lowerBoundBind(position);
        var saw_bind = false;
        while (index < self.binds.len and self.binds[index].bound_offset == position) : (index += 1) {
            const label_index = self.binds[index].label_index;
            if (label_index >= self.product.label_len) return error.InvalidBytecode;
            if (self.product.label_slots[label_index].ref_count > 0) return false;
            saw_bind = true;
        }
        return saw_bind;
    }

    /// qjs:34633 code_has_label. Side-table binds replace adjacent OP_label
    /// bytes; the immediately following goto case remains bytecode-native.
    fn codeHasLabel(self: *const Resolver, position: u32, label_index: u32) Error!bool {
        if (label_index >= self.product.label_len) return error.InvalidBytecode;
        const slot = self.product.label_slots[label_index];
        if (slot.flags.bound and slot.bound_offset == position) return true;
        if (position < self.product.code_len) {
            const instruction = try decodeInstruction(self.code, position);
            if (instruction.op_id == op.goto)
                return try self.labelsShareBindOffset(
                    try readU32At(self.code, position, 1),
                    label_index,
                );
        }
        return false;
    }

    /// The identity-native switch default bridge can leave `goto TARGET`
    /// followed only by a now-unreferenced dispatch trampoline before TARGET.
    /// QuickJS's parser patches that dispatch directly to the earlier default
    /// body, so this shape does not exist in its qjs:34968-34982 next-label
    /// check. Prove the intervening bind set is dead before asking the normal
    /// dead-code consumer to expose the same logical fallthrough.
    ///
    /// The switch epilogue no longer emits that trampoline (see
    /// `isSwitchDispatchBridgeAt`); this stays as the narrowly-shaped consumer
    /// of any source-less `goto`/dead-bind pair, and its unit test builds the
    /// shape directly.
    fn deadSwitchTrampolineCanReachLabel(
        self: *const Resolver,
        start: u32,
        label_index: u32,
    ) Error!bool {
        if (label_index >= self.product.label_len) return error.InvalidBytecode;
        const slot = self.product.label_slots[label_index];
        if (!slot.flags.bound or slot.bound_offset == labels.unbound or
            slot.bound_offset <= start or slot.bound_offset > self.product.code_len)
        {
            return false;
        }

        var index = self.bind_cursor;
        if (index < self.binds.len and self.binds[index].bound_offset < start)
            return error.InvalidBytecode;
        while (index < self.binds.len and
            self.binds[index].bound_offset < slot.bound_offset) : (index += 1)
        {
            const entry = self.binds[index];
            if (entry.dead_skipped) continue;
            if (entry.match_barrier) return false;
            if (entry.label_index >= self.product.label_len)
                return error.InvalidBytecode;
            if (self.product.label_slots[entry.label_index].ref_count != 0)
                return false;
        }

        // The switch-only bridge is exactly one backward goto between the
        // dead no-match bind and the live skip bind. Do not generalize this to
        // an arbitrary dead range: legacy deliberately retains some of those
        // goto edges (notably constant-false eval completion joins).
        // The synthetic switch dispatch is source-less; loop backedges carry
        // their parser source and must retain the legacy CFG edge.
        if (self.hasInputSourceAt(start)) return false;
        const dispatch = try decodeInstruction(self.code, start);
        if (dispatch.op_id != op.goto or start + dispatch.size != slot.bound_offset)
            return false;
        const dispatch_label = try readU32At(self.code, start, 1);
        if (dispatch_label >= self.product.label_len)
            return error.InvalidBytecode;
        const dispatch_slot = self.product.label_slots[dispatch_label];
        return dispatch_slot.flags.bound and
            dispatch_slot.bound_offset != labels.unbound and
            dispatch_slot.bound_offset < start and
            try self.codeHasLabel(slot.bound_offset, label_index);
    }

    /// qjs:34661 find_jump_target. The line-output parameter is intentionally
    /// absent: qjs's sole goto caller leaves its captured line unapplied.
    fn findJumpTarget(
        self: *Resolver,
        label0: u32,
        out_op: *u8,
    ) Error!u32 {
        var label_index = label0;
        _ = try updateLabel(self.product, label_index, -1);
        var target_op: u8 = op.invalid;
        var iteration: u8 = 0;
        while (iteration < 10) : (iteration += 1) {
            if (label_index >= self.product.label_len)
                return error.InvalidBytecode;
            const slot = self.product.label_slots[label_index];
            if (!slot.flags.bound or slot.bound_offset == labels.unbound or
                slot.bound_offset > self.product.code_len)
            {
                return error.InvalidBytecode;
            }
            var position = slot.bound_offset;
            if (position == self.product.code_len) {
                target_op = op.invalid;
                break;
            }
            const instruction = try decodeInstruction(self.code, position);
            target_op = instruction.op_id;
            if (target_op == op.goto) {
                label_index = try readU32At(self.code, position, 1);
                continue;
            }
            if (target_op == op.drop) {
                var source_blocked = false;
                while (position < self.product.code_len and self.code[position] == op.drop) {
                    const drop = try decodeInstruction(self.code, position);
                    position += drop.size;
                    // The canonical legacy Stage-4 topology scans the raw
                    // drop run and rejects terminal threading when a source
                    // slot sits after any consumed drop. Source markers are
                    // side-table entries in v2, so enforce the same barrier
                    // explicitly (qjs find_jump_target, quickjs.c:34661).
                    if (self.hasInputSourceAt(position)) {
                        source_blocked = true;
                        break;
                    }
                }
                if (!source_blocked and position < self.product.code_len) {
                    const after_drops = try decodeInstruction(self.code, position);
                    if (after_drops.op_id == op.return_undef)
                        target_op = op.return_undef;
                }
            }
            break;
        } else {
            // qjs:34695-34708 cycle workaround: restore the original edge.
            label_index = label0;
        }
        out_op.* = target_op;
        _ = try updateLabel(self.product, label_index, 1);
        return label_index;
    }

    /// Retarget a conditional edge consumed by a producer peephole through
    /// the same bounded goto walk as an ordinary branch.  This reuses qjs's
    /// `find_jump_target` refcount transaction (quickjs.c:34661-34710); the
    /// canonical legacy resolver also applies it to nullish/typeof fold
    /// targets before dead-code reachability is decided.
    fn findFoldedBranchTarget(self: *Resolver, label_index: u32) Error!u32 {
        var target_op: u8 = op.invalid;
        return self.findJumpTarget(label_index, &target_op);
    }

    /// qjs:34112 skip_dead_code, with atoms and sources consumed from their
    /// side ledgers while dead labels remain unresolved.
    fn skipDeadCode(self: *Resolver, start: u32) Error!u32 {
        var position = start;
        while (true) {
            if (position > self.product.code_len) return error.InvalidBytecode;
            if (self.bind_cursor < self.binds.len and
                self.binds[self.bind_cursor].bound_offset < position)
            {
                return error.InvalidBytecode;
            }

            const bind_start = self.bind_cursor;
            var bind_end = bind_start;
            var has_live_bind = false;
            while (bind_end < self.binds.len and
                self.binds[bind_end].bound_offset == position)
            {
                const label_index = self.binds[bind_end].label_index;
                if (label_index >= self.product.label_len)
                    return error.InvalidBytecode;
                const slot = &self.product.label_slots[label_index];
                if (slot.ref_count > 0) {
                    has_live_bind = true;
                } else if (slot.first_reloc != labels.no_reloc) {
                    return error.InvalidBytecode;
                }
                bind_end += 1;
            }
            // Retire a boundary's alias run wholesale or not at all. Marking
            // unreferenced aliases while still scanning retired them even when
            // the run turned out to be live, and `processBindsAt` then skipped
            // exactly those identities: one semantic boundary would carry a
            // surviving identity resolved to the output position plus an alias
            // resolved to nothing. That is the split the boundary-uniqueness
            // oracle rejects as `alias_liveness_split`. S3 retires transparent
            // zero-ref aliases (deadBoundaryAt, qjs label transparency) before
            // this stage ever sees them, so every alias reaching S4 is one S3
            // chose to keep.
            if (has_live_bind) return position;
            for (self.binds[bind_start..bind_end]) |*entry| entry.dead_skipped = true;
            self.bind_cursor = bind_end;
            self.refreshBindFrontier();
            if (position == self.product.code_len) return position;

            const instruction = try decodeInstruction(self.code, position);
            const position_next = position + instruction.size;
            self.absorbSources(position_next);
            switch (instruction.op_id) {
                op.if_false, op.if_true, op.goto, op.@"catch", op.gosub => {
                    _ = try updateLabel(
                        self.product,
                        try readU32At(self.code, position, 1),
                        -1,
                    );
                },
                op.with_get_var,
                op.with_put_var,
                op.with_delete_var,
                op.with_make_ref,
                op.with_get_ref,
                => {
                    _ = try updateLabel(
                        self.product,
                        try readU32At(self.code, position, 5),
                        -1,
                    );
                },
                else => {},
            }
            try self.consumeAtomsRange(position, position_next, null);
            position = position_next;
        }
    }

    fn shortSlotOp(op_id: u8, idx: u16) ?u8 {
        if (idx < 4) {
            const base: ?u8 = switch (op_id) {
                op.get_loc => op.get_loc0,
                op.put_loc => op.put_loc0,
                op.set_loc => op.set_loc0,
                op.get_arg => op.get_arg0,
                op.put_arg => op.put_arg0,
                op.set_arg => op.set_arg0,
                op.get_var_ref => op.get_var_ref0,
                op.put_var_ref => op.put_var_ref0,
                op.set_var_ref => op.set_var_ref0,
                op.call => op.call0,
                else => null,
            };
            if (base) |short_base| return short_base + @as(u8, @intCast(idx));
        }
        if (idx < 256) {
            return switch (op_id) {
                op.get_loc => op.get_loc8,
                op.put_loc => op.put_loc8,
                op.set_loc => op.set_loc8,
                else => null,
            };
        }
        return null;
    }

    fn putShortCodeSize(comptime layout: LayoutMode, op_id: u8, idx: u16) u32 {
        if (layout == .short) {
            if (shortSlotOp(op_id, idx)) |short_op| {
                return if (short_op == op.get_loc8 or short_op == op.put_loc8 or
                    short_op == op.set_loc8)
                    2
                else
                    1;
            }
        }
        return 3;
    }

    fn specialObjectSize(comptime layout: LayoutMode, slot: i32) Error!u32 {
        return 2 + putShortCodeSize(
            layout,
            op.put_loc,
            try checkedSlotIndex(slot),
        );
    }

    /// Exact byte count emitted by emitFunctionPrologue.  Keeping this beside
    /// the short-op selector makes the initial output reservation track the
    /// same layout decisions as emission instead of relying on a loose magic
    /// headroom constant.
    fn functionPrologueSize(self: *const Resolver, comptime layout: LayoutMode) Error!u32 {
        const fd = self.fd orelse return 0;
        var size: u32 = 0;
        if (fd.home_object_var_idx >= 0)
            size += try specialObjectSize(layout, fd.home_object_var_idx);
        if (fd.this_active_func_var_idx >= 0)
            size += try specialObjectSize(layout, fd.this_active_func_var_idx);
        if (fd.new_target_var_idx >= 0)
            size += try specialObjectSize(layout, fd.new_target_var_idx);
        if (fd.this_var_idx >= 0) {
            const idx = try checkedSlotIndex(fd.this_var_idx);
            size += if (fd.is_derived_class_constructor)
                3
            else
                1 + putShortCodeSize(layout, op.put_loc, idx);
        }
        if (fd.arguments_var_idx >= 0) {
            size += 2;
            if (fd.arguments_arg_idx >= 0) {
                size += putShortCodeSize(
                    layout,
                    op.set_loc,
                    try checkedSlotIndex(fd.arguments_arg_idx),
                );
            }
            size += putShortCodeSize(
                layout,
                op.put_loc,
                try checkedSlotIndex(fd.arguments_var_idx),
            );
        }
        if (fd.func_var_idx >= 0)
            size += try specialObjectSize(layout, fd.func_var_idx);
        if (fd.var_object_idx >= 0)
            size += try specialObjectSize(layout, fd.var_object_idx);
        if (fd.arg_var_object_idx >= 0)
            size += try specialObjectSize(layout, fd.arg_var_object_idx);
        return size;
    }

    /// qjs:34737 put_short_code plus the zjs legacy call0..3 lowering.
    fn putShortCode(
        self: *Resolver,
        comptime layout: LayoutMode,
        op_id: u8,
        idx: u16,
    ) Error!void {
        if (layout == .short) {
            if (shortSlotOp(op_id, idx)) |short_op| {
                try self.appendByte(short_op);
                if (short_op == op.get_loc8 or short_op == op.put_loc8 or
                    short_op == op.set_loc8)
                {
                    try self.appendByte(@intCast(idx));
                }
                return;
            }
        }
        try self.appendByte(op_id);
        try self.appendU16(idx);
    }

    /// qjs:34715 push_short_int, using zjs's explicit push_minus1 row.
    fn pushShortInt(
        self: *Resolver,
        comptime layout: LayoutMode,
        value: i32,
    ) Error!void {
        if (layout == .plain) {
            try self.appendByte(op.push_i32);
            try self.appendI32(value);
            return;
        }
        if (value >= -1 and value <= 7) {
            try self.appendByte(@intCast(@as(i32, op.push_0) + value));
        } else if (value >= std.math.minInt(i8) and value <= std.math.maxInt(i8)) {
            try self.appendByte(op.push_i8);
            try self.appendByte(@bitCast(@as(i8, @intCast(value))));
        } else if (value >= std.math.minInt(i16) and value <= std.math.maxInt(i16)) {
            try self.appendByte(op.push_i16);
            try self.appendI16(@intCast(value));
        } else {
            try self.appendByte(op.push_i32);
            try self.appendI32(value);
        }
    }

    fn checkedSlotIndex(value: i32) Error!u16 {
        if (value < 0 or value > std.math.maxInt(u16))
            return error.InvalidBytecode;
        return @intCast(value);
    }

    fn emitSpecialObject(
        self: *Resolver,
        comptime layout: LayoutMode,
        subtype: u8,
        slot: i32,
    ) Error!void {
        try self.appendByte(op.special_object);
        try self.appendByte(subtype);
        try self.putShortCode(layout, op.put_loc, try checkedSlotIndex(slot));
    }

    /// qjs:34833-34896, following legacy emitFunctionPrologue. Argument
    /// capture stays in zjs finalization and is deliberately absent here.
    fn emitFunctionPrologue(self: *Resolver, comptime layout: LayoutMode) Error!void {
        const fd = self.fd orelse return;
        const special = opcode.special_object_subtype;
        if (fd.home_object_var_idx >= 0)
            try self.emitSpecialObject(layout, special.home_object, fd.home_object_var_idx);
        if (fd.this_active_func_var_idx >= 0)
            try self.emitSpecialObject(layout, special.current_function, fd.this_active_func_var_idx);
        if (fd.new_target_var_idx >= 0)
            try self.emitSpecialObject(layout, special.new_target, fd.new_target_var_idx);
        if (fd.this_var_idx >= 0) {
            const idx = try checkedSlotIndex(fd.this_var_idx);
            if (fd.is_derived_class_constructor) {
                // This opcode has no short form in zjs.
                try self.appendByte(op.set_loc_uninitialized);
                try self.appendU16(idx);
            } else {
                try self.appendByte(op.push_this);
                try self.putShortCode(layout, op.put_loc, idx);
            }
        }
        if (fd.arguments_var_idx >= 0) {
            try self.appendByte(op.special_object);
            try self.appendByte(if (fd.is_strict_mode or !fd.has_simple_parameter_list)
                special.arguments
            else
                special.mapped_arguments);
            if (fd.arguments_arg_idx >= 0)
                try self.putShortCode(
                    layout,
                    op.set_loc,
                    try checkedSlotIndex(fd.arguments_arg_idx),
                );
            try self.putShortCode(
                layout,
                op.put_loc,
                try checkedSlotIndex(fd.arguments_var_idx),
            );
        }
        if (fd.func_var_idx >= 0)
            try self.emitSpecialObject(layout, special.current_function, fd.func_var_idx);
        if (fd.var_object_idx >= 0)
            try self.emitSpecialObject(layout, special.var_object, fd.var_object_idx);
        if (fd.arg_var_object_idx >= 0)
            try self.emitSpecialObject(layout, special.var_object, fd.arg_var_object_idx);
    }

    fn shortJumpOp(op_id: u8) Error!u8 {
        return switch (op_id) {
            op.if_false => op.if_false8,
            op.if_true => op.if_true8,
            op.goto => op.goto8,
            else => error.InvalidBytecode,
        };
    }

    fn emitHasLabel(
        self: *Resolver,
        comptime layout: LayoutMode,
        input_position: u32,
        initial_next: u32,
        op_id: u8,
        label_index: u32,
    ) Error!u32 {
        try self.attachSource();
        var position_next = initial_next;
        if (op_id == op.goto)
            position_next = try self.skipDeadCode(position_next);
        if (label_index >= self.product.label_len)
            return error.InvalidBytecode;
        const slot = &self.product.label_slots[label_index];
        const jump_index = try self.appendJumpSlot(
            op_id,
            4,
            std.math.add(u32, self.output_len, 1) catch
                return error.BytecodeOverflow,
            label_index,
        );

        if (self.addr[label_index] == labels.unbound and
            (!slot.flags.bound or slot.bound_offset == labels.unbound))
        {
            return error.InvalidBytecode;
        }

        if (layout == .short and self.addr[label_index] == labels.unbound) {
            const estimated = @as(i64, slot.bound_offset) -
                @as(i64, input_position) - 1;
            if (estimated < 128 and
                (op_id == op.if_false or op_id == op.if_true or op_id == op.goto))
            {
                const short_op = try shortJumpOp(op_id);
                self.jump_slots[jump_index].op = short_op;
                self.jump_slots[jump_index].size = 1;
                try self.appendByte(short_op);
                const operand_pos = self.output_len;
                self.jump_slots[jump_index].pos = operand_pos;
                try self.appendByte(0);
                try self.addReloc(label_index, operand_pos, 1);
                return position_next;
            }
            if (estimated < 32768 and op_id == op.goto) {
                self.jump_slots[jump_index].op = op.goto16;
                self.jump_slots[jump_index].size = 2;
                try self.appendByte(op.goto16);
                const operand_pos = self.output_len;
                self.jump_slots[jump_index].pos = operand_pos;
                try self.appendU16(0);
                try self.addReloc(label_index, operand_pos, 2);
                return position_next;
            }
        } else if (layout == .short) {
            const diff = @as(i64, self.addr[label_index]) -
                @as(i64, self.output_len) - 1;
            if (diff >= std.math.minInt(i8) and diff <= std.math.maxInt(i8) and
                (op_id == op.if_false or op_id == op.if_true or op_id == op.goto))
            {
                const short_op = try shortJumpOp(op_id);
                self.jump_slots[jump_index].op = short_op;
                self.jump_slots[jump_index].size = 1;
                try self.appendByte(short_op);
                const operand_pos = self.output_len;
                self.jump_slots[jump_index].pos = operand_pos;
                try self.appendByte(@bitCast(@as(i8, @intCast(diff))));
                return position_next;
            }
            if (diff >= std.math.minInt(i16) and diff <= std.math.maxInt(i16) and
                op_id == op.goto)
            {
                self.jump_slots[jump_index].op = op.goto16;
                self.jump_slots[jump_index].size = 2;
                try self.appendByte(op.goto16);
                const operand_pos = self.output_len;
                self.jump_slots[jump_index].pos = operand_pos;
                try self.appendI16(@intCast(diff));
                return position_next;
            }
        }

        try self.appendByte(op_id);
        const operand_pos = self.output_len;
        self.jump_slots[jump_index].pos = operand_pos;
        if (self.addr[label_index] == labels.unbound) {
            try self.appendU32(0);
            try self.addReloc(label_index, operand_pos, 4);
        } else {
            const diff = @as(i64, self.addr[label_index]) - @as(i64, operand_pos);
            if (diff < std.math.minInt(i32) or diff > std.math.maxInt(i32))
                return error.BytecodeOverflow;
            try self.appendI32(@intCast(diff));
        }
        return position_next;
    }

    const SlotFamily = struct {
        get: u8,
        put: u8,
        set: u8,
    };

    fn putFamily(op_id: u8) ?SlotFamily {
        return switch (op_id) {
            op.put_loc => .{ .get = op.get_loc, .put = op.put_loc, .set = op.set_loc },
            op.put_loc_check => .{
                .get = op.get_loc_check,
                .put = op.put_loc_check,
                .set = op.set_loc_check,
            },
            op.put_arg => .{ .get = op.get_arg, .put = op.put_arg, .set = op.set_arg },
            op.put_var_ref => .{
                .get = op.get_var_ref,
                .put = op.put_var_ref,
                .set = op.set_var_ref,
            },
            else => null,
        };
    }

    fn isShortSlotFamily(op_id: u8) bool {
        return op_id == op.get_loc or op_id == op.put_loc or op_id == op.set_loc or
            op_id == op.get_arg or op_id == op.put_arg or op_id == op.set_arg or
            op_id == op.get_var_ref or op_id == op.put_var_ref or
            op_id == op.set_var_ref;
    }

    fn copyDefault(
        self: *Resolver,
        comptime layout: LayoutMode,
        position: u32,
        instruction: Instruction,
    ) Error!void {
        try self.attachSource();
        const position_next = position + instruction.size;
        if (instruction.op_id == op.call) {
            try self.putShortCode(layout, op.call, try readU16(self.code, position));
        } else if (isShortSlotFamily(instruction.op_id)) {
            try self.putShortCode(
                layout,
                instruction.op_id,
                try readU16(self.code, position),
            );
        } else {
            try self.appendRaw(self.code[position..position_next]);
        }
        try self.consumeInstructionAtom(position, instruction, true);
    }

    fn emitRawInstruction(
        self: *Resolver,
        position: u32,
        instruction: Instruction,
    ) Error!void {
        try self.attachSource();
        const position_next = position + instruction.size;
        try self.appendRaw(self.code[position..position_next]);
        try self.consumeInstructionAtom(position, instruction, true);
    }

    fn handleGoto(
        self: *Resolver,
        comptime layout: LayoutMode,
        input_position: u32,
        initial_next: u32,
        initial_label: u32,
    ) Error!u32 {
        var target_op: u8 = op.invalid;
        const label_index = try self.findJumpTarget(initial_label, &target_op);
        if (try self.codeHasLabel(initial_next, label_index)) {
            _ = try updateLabel(self.product, label_index, -1);
            return initial_next;
        }
        if (target_op == op.@"return" or target_op == op.return_undef or
            target_op == op.throw)
        {
            _ = try updateLabel(self.product, label_index, -1);
            try self.attachSource();
            try self.appendByte(target_op);
            return self.skipDeadCode(initial_next);
        }
        if (try self.deadSwitchTrampolineCanReachLabel(initial_next, label_index)) {
            const live_next = try self.skipDeadCode(initial_next);
            if (!try self.codeHasLabel(live_next, label_index))
                return error.InvalidBytecode;
            _ = try updateLabel(self.product, label_index, -1);
            return live_next;
        }
        return self.emitHasLabel(
            layout,
            input_position,
            initial_next,
            op.goto,
            label_index,
        );
    }

    fn handleConstantTest(
        self: *Resolver,
        comptime layout: LayoutMode,
        input_position: u32,
        value: bool,
        match: SeqMatch,
    ) Error!u32 {
        self.absorbSources(match.end);
        const branch_op = self.code[match.positions[0]];
        const label_index = try readU32At(
            self.code,
            match.positions[0],
            1,
        );
        if (value == (branch_op == op.if_true)) {
            return self.handleGoto(layout, input_position, match.end, label_index);
        }
        _ = try updateLabel(self.product, label_index, -1);
        return match.end;
    }

    /// qjs:35099 atom_label_u8 family.
    fn emitWithProbe(
        self: *Resolver,
        position: u32,
        position_next: u32,
        op_id: u8,
    ) Error!void {
        const atom_id = try readU32At(self.code, position, 1);
        var target_op: u8 = op.invalid;
        const label_index = try self.findJumpTarget(
            try readU32At(self.code, position, 5),
            &target_op,
        );
        if (label_index >= self.product.label_len)
            return error.InvalidBytecode;
        try self.attachSource();
        const jump_index = try self.appendJumpSlot(
            op_id,
            4,
            std.math.add(u32, self.output_len, 5) catch
                return error.BytecodeOverflow,
            label_index,
        );
        try self.appendByte(op_id);
        try self.appendU32(atom_id);
        const operand_pos = self.output_len;
        self.jump_slots[jump_index].pos = operand_pos;
        if (self.addr[label_index] == labels.unbound) {
            const slot = self.product.label_slots[label_index];
            if (!slot.flags.bound or slot.bound_offset == labels.unbound)
                return error.InvalidBytecode;
            try self.appendU32(0);
            try self.addReloc(label_index, operand_pos, 4);
        } else {
            const diff = @as(i64, self.addr[label_index]) - @as(i64, operand_pos);
            if (diff < std.math.minInt(i32) or diff > std.math.maxInt(i32))
                return error.BytecodeOverflow;
            try self.appendI32(@intCast(diff));
        }
        try self.appendByte(self.code[position + 9]);
        try self.consumeAtomsRange(position, position_next, position);
    }

    fn walk(self: *Resolver, comptime layout: LayoutMode) Error!void {
        try self.emitFunctionPrologue(layout);

        var position: u32 = 0;
        while (position < self.product.code_len) {
            try self.processBindsAt(position);
            self.absorbSources(position + 1);
            const instruction = try decodeInstruction(self.code, position);
            var position_next = position + instruction.size;

            switch (instruction.op_id) {
                // qjs:34941-34959 deliberately diverges: zjs emits tail_call
                // directly and legacy resolve_labels never folds call+return.
                // Ordinary call still takes the default call0..3 selector.
                op.call, op.call_method => try self.copyDefault(layout, position, instruction),

                // The Builder-native path has no preceding legacy
                // resolve_bytecode walk, so this is the complete terminal set
                // whose dead tails that walk removes (qjs:34352-34378), plus
                // return_async as in resolve_labels (qjs:34960-34967).
                op.tail_call,
                op.tail_call_method,
                op.@"return",
                op.return_undef,
                op.return_async,
                op.throw,
                op.throw_error,
                op.ret,
                => {
                    try self.emitRawInstruction(position, instruction);
                    position_next = try self.skipDeadCode(position_next);
                },

                // qjs:34968-34998.
                op.goto => {
                    position_next = try self.handleGoto(
                        layout,
                        position,
                        position_next,
                        try readU32At(self.code, position, 1),
                    );
                },

                // qjs:34999-35010. The disabled empty-finalizer fold stays
                // disabled; S3 already removes that shape.
                op.gosub, op.@"catch" => {
                    position_next = try self.emitHasLabel(
                        layout,
                        position,
                        position_next,
                        instruction.op_id,
                        try readU32At(self.code, position, 1),
                    );
                },

                // qjs:35015-35098.
                op.if_true, op.if_false => {
                    var target_op: u8 = op.invalid;
                    var label_index = try self.findJumpTarget(
                        try readU32At(self.code, position, 1),
                        &target_op,
                    );
                    if (try self.codeHasLabel(position_next, label_index)) {
                        _ = try updateLabel(self.product, label_index, -1);
                        try self.attachSource();
                        try self.appendByte(op.drop);
                    } else if (try self.matchSeq(position_next, &.{
                        .{ .options = &.{op.goto} },
                    })) |match| {
                        if (!(try self.isSwitchDispatchBridgeAt(match.end)) and
                            try self.codeHasLabel(match.end, label_index))
                        {
                            const goto_label = try readU32At(
                                self.code,
                                match.positions[0],
                                1,
                            );
                            if (try self.codeHasLabel(match.end, goto_label)) {
                                // Both arms land on `match.end`: the taken arm
                                // through `label_index`, the fallthrough arm
                                // through the `goto`'s own target. The test is
                                // therefore pure stack discipline, so the pair
                                // collapses to the same `drop` the direct
                                // next-label case above emits. QuickJS's
                                // syntactic `code_has_label` (qjs:34968-34982)
                                // stops at the intervening `goto` and leaves
                                // the inverted branch standing; the legacy
                                // backend resolves targets after layout and
                                // folds it, and dual-mode identity is measured
                                // against the legacy product. Reached by an
                                // empty `case` clause that falls directly into
                                // a trailing `default`, e.g.
                                // `switch (d) { case c: default: e(); }`.
                                self.absorbSources(match.end);
                                _ = try updateLabel(self.product, label_index, -1);
                                _ = try updateLabel(self.product, goto_label, -1);
                                try self.attachSource();
                                try self.appendByte(op.drop);
                                position_next = match.end;
                            } else {
                                self.absorbSources(match.end);
                                _ = try updateLabel(self.product, label_index, -1);
                                label_index = goto_label;
                                const inverted = if (instruction.op_id == op.if_false)
                                    op.if_true
                                else
                                    op.if_false;
                                position_next = try self.emitHasLabel(
                                    layout,
                                    position,
                                    match.end,
                                    inverted,
                                    label_index,
                                );
                            }
                        } else {
                            position_next = try self.emitHasLabel(
                                layout,
                                position,
                                position_next,
                                instruction.op_id,
                                label_index,
                            );
                        }
                    } else {
                        position_next = try self.emitHasLabel(
                            layout,
                            position,
                            position_next,
                            instruction.op_id,
                            label_index,
                        );
                    }
                },

                // qjs:35099-35135.
                op.with_get_var,
                op.with_put_var,
                op.with_delete_var,
                op.with_make_ref,
                op.with_get_ref,
                => try self.emitWithProbe(
                    position,
                    position_next,
                    instruction.op_id,
                ),

                // qjs:35136-35145.
                op.drop => {
                    if (try self.matchSeq(position_next, &.{
                        .{ .options = &.{op.return_undef} },
                    })) |match| {
                        // The return is intentionally revisited by the main
                        // loop; only its carried source is absorbed here.
                        self.absorbSources(match.end);
                    } else {
                        try self.copyDefault(layout, position, instruction);
                    }
                },

                // qjs:35146-35169, followed by the false constant-test case.
                op.null => {
                    if (try self.matchSeq(position_next, &.{
                        .{ .options = &.{op.strict_eq} },
                    })) |match| {
                        self.absorbSources(match.end);
                        try self.attachSource();
                        try self.appendByte(op.is_null);
                        position_next = match.end;
                    } else if (try self.matchSeq(position_next, &.{
                        .{ .options = &.{op.strict_neq} },
                        .{ .options = &.{ op.if_false, op.if_true } },
                    })) |match| {
                        self.absorbSources(match.end);
                        try self.attachSource();
                        try self.appendByte(op.is_null);
                        const inverted = if (self.code[match.positions[1]] == op.if_false)
                            op.if_true
                        else
                            op.if_false;
                        const label_index = try self.findFoldedBranchTarget(
                            try readU32At(self.code, match.positions[1], 1),
                        );
                        position_next = try self.emitHasLabel(
                            layout,
                            position,
                            match.end,
                            inverted,
                            label_index,
                        );
                    } else if (try self.matchSeq(position_next, &.{
                        .{ .options = &.{ op.if_false, op.if_true } },
                    })) |match| {
                        position_next = try self.handleConstantTest(
                            layout,
                            position,
                            false,
                            match,
                        );
                    } else {
                        try self.copyDefault(layout, position, instruction);
                    }
                },

                // qjs:35170-35196.
                op.push_false, op.push_true => {
                    if (try self.matchSeq(position_next, &.{
                        .{ .options = &.{ op.if_false, op.if_true } },
                    })) |match| {
                        position_next = try self.handleConstantTest(
                            layout,
                            position,
                            instruction.op_id == op.push_true,
                            match,
                        );
                    } else {
                        try self.copyDefault(layout, position, instruction);
                    }
                },

                // qjs:35197-35229, with the deliberate legacy zjs ordering:
                // constant-test recognition precedes neg and push/drop folds.
                op.push_i32 => {
                    const value = try readI32(self.code, position);
                    if (try self.matchSeq(position_next, &.{
                        .{ .options = &.{ op.if_false, op.if_true } },
                    })) |match| {
                        position_next = try self.handleConstantTest(
                            layout,
                            position,
                            value != 0,
                            match,
                        );
                    } else if (value != std.math.minInt(i32) and value != 0) {
                        if (try self.matchSeq(position_next, &.{
                            .{ .options = &.{op.neg} },
                        })) |neg_match| {
                            if (try self.matchSeq(neg_match.end, &.{
                                .{ .options = &.{op.drop} },
                            })) |drop_match| {
                                self.absorbSources(drop_match.end);
                                position_next = drop_match.end;
                            } else {
                                self.absorbSources(neg_match.end);
                                try self.attachSource();
                                try self.pushShortInt(layout, -value);
                                position_next = neg_match.end;
                            }
                        } else if (try self.matchSeq(position_next, &.{
                            .{ .options = &.{op.drop} },
                        })) |drop_match| {
                            self.absorbSources(drop_match.end);
                            position_next = drop_match.end;
                        } else {
                            try self.attachSource();
                            try self.pushShortInt(layout, value);
                        }
                    } else if (try self.matchSeq(position_next, &.{
                        .{ .options = &.{op.drop} },
                    })) |drop_match| {
                        self.absorbSources(drop_match.end);
                        position_next = drop_match.end;
                    } else {
                        try self.attachSource();
                        try self.pushShortInt(layout, value);
                    }
                },

                // qjs:35230-35250. zjs guards the entire fold, including the
                // discarded variant, against INT32_MIN.
                op.push_bigint_i32 => {
                    const value = try readI32(self.code, position);
                    if (value != std.math.minInt(i32)) {
                        if (try self.matchSeq(position_next, &.{
                            .{ .options = &.{op.neg} },
                        })) |neg_match| {
                            if (try self.matchSeq(neg_match.end, &.{
                                .{ .options = &.{op.drop} },
                            })) |drop_match| {
                                self.absorbSources(drop_match.end);
                                position_next = drop_match.end;
                            } else {
                                self.absorbSources(neg_match.end);
                                try self.attachSource();
                                try self.appendByte(op.push_bigint_i32);
                                try self.appendI32(-value);
                                position_next = neg_match.end;
                            }
                        } else {
                            try self.copyDefault(layout, position, instruction);
                        }
                    } else {
                        try self.copyDefault(layout, position, instruction);
                    }
                },

                // qjs:35251-35263.
                op.push_const, op.fclosure => {
                    const index = try readU32At(self.code, position, 1);
                    if (layout == .short and index < 256) {
                        try self.attachSource();
                        try self.appendByte(if (instruction.op_id == op.push_const)
                            op.push_const8
                        else
                            op.fclosure8);
                        try self.appendByte(@intCast(index));
                    } else {
                        try self.copyDefault(layout, position, instruction);
                    }
                },

                // qjs:35264-35275.
                op.get_field => {
                    if (layout == .short and
                        try readU32At(self.code, position, 1) == core.atom.ids.length)
                    {
                        try self.attachSource();
                        try self.appendByte(op.get_length);
                        try self.consumeAtomsRange(position, position_next, null);
                    } else {
                        try self.copyDefault(layout, position, instruction);
                    }
                },

                // qjs:35276-35296.
                op.push_atom_value => {
                    if (try self.matchSeq(position_next, &.{
                        .{ .options = &.{op.drop} },
                    })) |match| {
                        self.absorbSources(match.end);
                        try self.consumeAtomsRange(position, match.end, null);
                        position_next = match.end;
                    } else if (layout == .short and
                        try readU32At(self.code, position, 1) ==
                            core.atom.ids.empty_string)
                    {
                        try self.attachSource();
                        try self.appendByte(op.push_empty_string);
                        try self.consumeAtomsRange(position, position_next, null);
                    } else {
                        try self.copyDefault(layout, position, instruction);
                    }
                },

                // qjs:35297-35307 deliberately not ported: legacy zjs has no
                // to_propkey/store fold.
                op.to_propkey => try self.copyDefault(layout, position, instruction),

                // qjs:35308-35351.
                op.undefined => {
                    if (try self.matchSeq(position_next, &.{
                        .{ .options = &.{op.drop} },
                    })) |match| {
                        self.absorbSources(match.end);
                        position_next = match.end;
                    } else if (try self.matchSeq(position_next, &.{
                        .{ .options = &.{op.@"return"} },
                    })) |match| {
                        self.absorbSources(match.end);
                        try self.attachSource();
                        try self.appendByte(op.return_undef);
                        // The pair IS a return, so its tail is dead exactly as
                        // the op.return arm's is (qjs:34352-34378). Without this
                        // the loop backedge behind `while (..) { if (..) return; }`
                        // survives in v2 and legacy drops it. The match may have
                        // spanned a dead compact bind, which skipDeadCode
                        // requires retired before its start.
                        try self.retireSpannedDeadBinds(match.end);
                        position_next = try self.skipDeadCode(match.end);
                    } else if (try self.matchSeq(position_next, &.{
                        .{ .options = &.{ op.if_false, op.if_true } },
                    })) |match| {
                        position_next = try self.handleConstantTest(
                            layout,
                            position,
                            false,
                            match,
                        );
                    } else if (try self.matchSeq(position_next, &.{
                        .{ .options = &.{op.strict_eq} },
                    })) |match| {
                        self.absorbSources(match.end);
                        try self.attachSource();
                        try self.appendByte(op.is_undefined);
                        position_next = match.end;
                    } else if (try self.matchSeq(position_next, &.{
                        .{ .options = &.{op.strict_neq} },
                        .{ .options = &.{ op.if_false, op.if_true } },
                    })) |match| {
                        self.absorbSources(match.end);
                        try self.attachSource();
                        try self.appendByte(op.is_undefined);
                        const inverted = if (self.code[match.positions[1]] == op.if_false)
                            op.if_true
                        else
                            op.if_false;
                        const label_index = try self.findFoldedBranchTarget(
                            try readU32At(self.code, match.positions[1], 1),
                        );
                        position_next = try self.emitHasLabel(
                            layout,
                            position,
                            match.end,
                            inverted,
                            label_index,
                        );
                    } else {
                        try self.copyDefault(layout, position, instruction);
                    }
                },

                else => try self.walkLateArm(layout, position, instruction, &position_next),
            }

            position = position_next;
        }

        try self.processBindsAt(self.product.code_len);
        self.absorbSourcesAtEnd();
        if (self.bind_cursor != self.binds.len or
            self.atom_cursor != self.input_atoms.len or
            self.source_cursor != self.input_sources.len or
            self.source_attach_cursor > self.source_cursor)
        {
            return error.InvalidBytecode;
        }
        for (self.product.label_slots[0..self.product.label_len]) |slot| {
            if (slot.first_reloc != labels.no_reloc)
                return error.InvalidBytecode;
        }
    }

    fn walkLateArm(
        self: *Resolver,
        comptime layout: LayoutMode,
        position: u32,
        instruction: Instruction,
        position_next: *u32,
    ) Error!void {
        switch (instruction.op_id) {
            // qjs:35352-35367.
            op.insert2 => {
                if (try self.matchSeq(position_next.*, &.{
                    .{ .options = &.{op.put_field} },
                    .{ .options = &.{op.drop} },
                })) |match| {
                    // qjs:35352-35367. The marker owned by `insert2` maps to
                    // the replacement store. Legacy's old-PC relocation maps
                    // markers on either consumed tail instruction to the
                    // boundary after that store, so publish them only once the
                    // replacement bytes exist.
                    try self.attachSource();
                    const put_position = match.positions[0];
                    try self.appendByte(op.put_field);
                    try self.appendU32(try readU32At(self.code, put_position, 1));
                    try self.consumeAtomsRange(position, match.end, put_position);
                    self.absorbSources(match.end);
                    try self.attachSource();
                    position_next.* = match.end;
                } else {
                    try self.copyDefault(layout, position, instruction);
                }
            },

            // qjs:35368-35394. Explicit families replace qjs's arithmetic
            // get/put/set assumptions, including the checked-local family.
            op.dup => {
                if (try self.matchSeq(position_next.*, &.{
                    .{ .options = &.{
                        op.put_loc,
                        op.put_loc_check,
                        op.put_arg,
                        op.put_var_ref,
                    } },
                })) |put_match| {
                    const family = putFamily(self.code[put_match.positions[0]]) orelse
                        return error.InvalidBytecode;
                    const idx = try self.readIndex(put_match.positions[0]);
                    self.absorbSources(put_match.end);
                    var result_op = family.set;
                    var final_end = put_match.end;
                    var delayed_source_end: ?u32 = null;
                    if (try self.matchSeq(final_end, &.{
                        .{ .options = &.{op.drop} },
                    })) |drop_match| {
                        self.absorbSources(drop_match.end);
                        result_op = family.put;
                        final_end = drop_match.end;
                        if (try self.matchSeq(final_end, &.{
                            .{ .options = &.{family.get}, .idx = idx },
                        })) |get_match| {
                            // qjs:35382-35391 stores this matcher's source as
                            // `line2`, emits the replacement using the earlier
                            // line, and applies line2 only afterward.
                            delayed_source_end = get_match.end;
                            result_op = family.set;
                            final_end = get_match.end;
                        }
                    }
                    try self.attachSource();
                    try self.putShortCode(layout, result_op, idx);
                    if (delayed_source_end) |source_end| {
                        self.absorbSources(source_end);
                        try self.attachSource();
                    }
                    position_next.* = final_end;
                } else {
                    try self.copyDefault(layout, position, instruction);
                }
            },

            // qjs:35395-35468.
            op.get_loc => {
                const idx = try readU16(self.code, position);
                if (idx >= 256) {
                    try self.copyDefault(layout, position, instruction);
                    return;
                }

                if (try self.matchSeq(position_next.*, &.{
                    .{ .options = &.{ op.post_dec, op.post_inc } },
                    .{ .options = &.{op.put_loc}, .idx = idx },
                    .{ .options = &.{op.drop} },
                })) |match| {
                    self.absorbSources(match.end);
                    try self.attachSource();
                    try self.appendByte(if (self.code[match.positions[0]] == op.post_inc)
                        op.inc_loc
                    else
                        op.dec_loc);
                    try self.appendByte(@intCast(idx));
                    position_next.* = match.end;
                } else if (try self.matchSeq(position_next.*, &.{
                    .{ .options = &.{ op.dec, op.inc } },
                    .{ .options = &.{op.dup} },
                    .{ .options = &.{op.put_loc}, .idx = idx },
                    .{ .options = &.{op.drop} },
                })) |match| {
                    self.absorbSources(match.end);
                    try self.attachSource();
                    try self.appendByte(if (self.code[match.positions[0]] == op.inc)
                        op.inc_loc
                    else
                        op.dec_loc);
                    try self.appendByte(@intCast(idx));
                    position_next.* = match.end;
                } else if (try self.matchSeq(position_next.*, &.{
                    .{ .options = &.{op.push_atom_value} },
                    .{ .options = &.{op.add} },
                    .{ .options = &.{op.dup} },
                    .{ .options = &.{op.put_loc}, .idx = idx },
                    .{ .options = &.{op.drop} },
                })) |match| {
                    self.absorbSources(match.end);
                    try self.attachSource();
                    const atom_position = match.positions[0];
                    const atom_id = try readU32At(self.code, atom_position, 1);
                    if (layout == .short and atom_id == core.atom.ids.empty_string) {
                        try self.appendByte(op.push_empty_string);
                        try self.consumeAtomsRange(position, match.end, null);
                    } else {
                        try self.appendByte(op.push_atom_value);
                        try self.appendU32(atom_id);
                        try self.consumeAtomsRange(
                            position,
                            match.end,
                            atom_position,
                        );
                    }
                    try self.appendByte(op.add_loc);
                    try self.appendByte(@intCast(idx));
                    position_next.* = match.end;
                } else if (try self.matchSeq(position_next.*, &.{
                    .{ .options = &.{op.push_i32} },
                    .{ .options = &.{op.add} },
                    .{ .options = &.{op.dup} },
                    .{ .options = &.{op.put_loc}, .idx = idx },
                    .{ .options = &.{op.drop} },
                })) |match| {
                    self.absorbSources(match.end);
                    try self.attachSource();
                    try self.pushShortInt(layout, try readI32(self.code, match.positions[0]));
                    try self.appendByte(op.add_loc);
                    try self.appendByte(@intCast(idx));
                    position_next.* = match.end;
                } else if (try self.matchSeq(position_next.*, &.{
                    .{ .options = &.{ op.get_loc, op.get_arg, op.get_var_ref } },
                    .{ .options = &.{op.add} },
                    .{ .options = &.{op.dup} },
                    .{ .options = &.{op.put_loc}, .idx = idx },
                    .{ .options = &.{op.drop} },
                })) |match| {
                    self.absorbSources(match.end);
                    try self.attachSource();
                    try self.putShortCode(
                        layout,
                        self.code[match.positions[0]],
                        try self.readIndex(match.positions[0]),
                    );
                    try self.appendByte(op.add_loc);
                    try self.appendByte(@intCast(idx));
                    position_next.* = match.end;
                } else {
                    try self.attachSource();
                    try self.putShortCode(layout, op.get_loc, idx);
                }
            },

            // qjs:35469-35479.
            op.get_arg, op.get_var_ref => {
                try self.attachSource();
                try self.putShortCode(
                    layout,
                    instruction.op_id,
                    try readU16(self.code, position),
                );
            },

            // qjs:35480-35500.
            op.put_loc, op.put_loc_check, op.put_arg, op.put_var_ref => {
                const family = putFamily(instruction.op_id) orelse
                    return error.InvalidBytecode;
                const idx = try readU16(self.code, position);
                if (try self.matchSeq(position_next.*, &.{
                    .{ .options = &.{family.get}, .idx = idx },
                })) |match| {
                    self.absorbSources(match.end);
                    try self.attachSource();
                    try self.putShortCode(layout, family.set, idx);
                    position_next.* = match.end;
                } else {
                    try self.attachSource();
                    // put_loc_check is intentionally wide: putShortCode has
                    // no short-family row for it.
                    try self.putShortCode(layout, family.put, idx);
                }
            },

            // qjs:35501-35545.
            op.post_inc, op.post_dec => {
                const update_op = if (instruction.op_id == op.post_inc)
                    op.inc
                else
                    op.dec;
                if (try self.matchSeq(position_next.*, &.{
                    .{ .options = &.{ op.put_loc, op.put_arg, op.put_var_ref } },
                    .{ .options = &.{op.drop} },
                })) |store_match| {
                    const family = putFamily(self.code[store_match.positions[0]]) orelse
                        return error.InvalidBytecode;
                    const idx = try self.readIndex(store_match.positions[0]);
                    var store_op = family.put;
                    var final_end = store_match.end;
                    if (try self.matchSeq(final_end, &.{
                        .{ .options = &.{family.get}, .idx = idx },
                    })) |get_match| {
                        store_op = family.set;
                        final_end = get_match.end;
                    }
                    // Legacy final-layout relocation maps every source on the
                    // consumed store/drop/optional-get tail to the boundary
                    // after both replacement instructions. Only the post-op's
                    // own marker belongs on the update (qjs:35501-35545).
                    try self.attachSource();
                    try self.appendByte(update_op);
                    try self.putShortCode(layout, store_op, idx);
                    self.absorbSources(final_end);
                    try self.attachSource();
                    position_next.* = final_end;
                } else if (try self.matchSeq(position_next.*, &.{
                    .{ .options = &.{op.perm3} },
                    .{ .options = &.{op.put_field} },
                    .{ .options = &.{op.drop} },
                })) |match| {
                    try self.attachSource();
                    const put_position = match.positions[1];
                    try self.appendByte(update_op);
                    try self.appendByte(op.put_field);
                    try self.appendU32(try readU32At(self.code, put_position, 1));
                    try self.consumeAtomsRange(position, match.end, put_position);
                    self.absorbSources(match.end);
                    try self.attachSource();
                    position_next.* = match.end;
                } else if (try self.matchSeq(position_next.*, &.{
                    .{ .options = &.{op.perm4} },
                    .{ .options = &.{op.put_array_el} },
                    .{ .options = &.{op.drop} },
                })) |match| {
                    try self.attachSource();
                    try self.appendByte(update_op);
                    try self.appendByte(op.put_array_el);
                    self.absorbSources(match.end);
                    try self.attachSource();
                    position_next.* = match.end;
                } else {
                    try self.copyDefault(layout, position, instruction);
                }
            },

            // qjs:35546-35586.
            op.typeof => {
                if (try self.matchSeq(position_next.*, &.{
                    .{ .options = &.{op.push_atom_value} },
                    .{ .options = &.{ op.strict_eq, op.strict_neq, op.eq, op.neq } },
                })) |compare_match| {
                    const atom_id = try readU32At(
                        self.code,
                        compare_match.positions[0],
                        1,
                    );
                    const test_op: ?u8 = if (atom_id == core.atom.ids.undefined_)
                        op.typeof_is_undefined
                    else if (atom_id == core.atom.ids.type_function)
                        op.typeof_is_function
                    else
                        null;
                    if (test_op) |selected_test| {
                        const compare_op = self.code[compare_match.positions[1]];
                        if (compare_op == op.strict_eq or compare_op == op.eq) {
                            // Legacy old-PC relocation places the marker on
                            // push_atom_value after the one-byte replacement,
                            // while the later compare marker maps backwards
                            // and is not published. Preserve that ordering
                            // explicitly in the identity-coordinate stream.
                            try self.attachSource();
                            const deferred_start = self.source_attach_cursor;
                            self.absorbSources(compare_match.positions[1]);
                            const deferred_end = self.source_cursor;
                            self.absorbSources(compare_match.end);
                            self.source_attach_cursor = self.source_cursor;
                            try self.appendByte(selected_test);
                            try self.consumeAtomsRange(
                                position,
                                compare_match.end,
                                null,
                            );
                            position_next.* = compare_match.end;
                            try self.attachInputSourceRangeAt(
                                deferred_start,
                                deferred_end,
                                self.output_len,
                            );
                            return;
                        }
                        if (try self.matchSeq(compare_match.end, &.{
                            .{ .options = &.{op.if_false} },
                        })) |branch_match| {
                            try self.attachSource();
                            const deferred_start = self.source_attach_cursor;
                            self.absorbSources(compare_match.positions[1]);
                            const deferred_end = self.source_cursor;
                            self.absorbSources(branch_match.end);
                            self.source_attach_cursor = self.source_cursor;
                            try self.appendByte(selected_test);
                            try self.consumeAtomsRange(
                                position,
                                branch_match.end,
                                null,
                            );
                            const label_index = try self.findFoldedBranchTarget(
                                try readU32At(
                                    self.code,
                                    branch_match.positions[0],
                                    1,
                                ),
                            );
                            position_next.* = try self.emitHasLabel(
                                layout,
                                position,
                                branch_match.end,
                                op.if_true,
                                label_index,
                            );
                            try self.attachInputSourceRangeAt(
                                deferred_start,
                                deferred_end,
                                self.output_len,
                            );
                            return;
                        }
                    }
                }
                try self.copyDefault(layout, position, instruction);
            },

            // qjs:35587-35592.
            else => try self.copyDefault(layout, position, instruction),
        }
    }

    /// qjs:35599-35673 bounded jump relaxation. This intentionally retains
    /// QuickJS's quadratic tail move; replacing it belongs to a measured
    /// follow-up, not the semantic port.
    fn relaxJumps(self: *Resolver) Error!void {
        var patch_offsets: u32 = 0;
        var index: u32 = 0;
        while (index < self.jump_count) : (index += 1) {
            const jump = &self.jump_slots[index];
            if (jump.label >= self.product.label_len or
                self.addr[jump.label] == labels.unbound)
            {
                return error.InvalidBytecode;
            }

            var delta: u32 = 3;
            switch (jump.op) {
                op.goto16 => delta = 1,
                op.if_false, op.if_true, op.goto => {},
                else => continue,
            }
            if (jump.pos > self.output_len) return error.InvalidBytecode;
            const diff = @as(i64, self.addr[jump.label]) - @as(i64, jump.pos);

            var new_size: ?u8 = null;
            var new_op = jump.op;
            if (diff >= -128 and diff <= 127 + @as(i64, delta)) {
                new_size = 1;
                new_op = if (jump.op == op.goto16)
                    op.goto8
                else
                    try shortJumpOp(jump.op);
            } else if (jump.op == op.goto and
                diff >= std.math.minInt(i16) and diff <= std.math.maxInt(i16))
            {
                new_size = 2;
                delta = 2;
                new_op = op.goto16;
            }

            const compact_size = new_size orelse continue;
            if (jump.pos == 0) return error.InvalidBytecode;
            const source_start = std.math.add(
                u32,
                jump.pos,
                @as(u32, compact_size) + delta,
            ) catch return error.InvalidBytecode;
            const destination_start = jump.pos + compact_size;
            if (source_start > self.output_len or destination_start > source_start)
                return error.InvalidBytecode;
            self.output[jump.pos - 1] = new_op;
            const tail_len: usize = @intCast(self.output_len - source_start);
            std.mem.copyForwards(
                u8,
                self.output[destination_start..][0..tail_len],
                self.output[source_start..][0..tail_len],
            );
            self.output_len -= delta;
            jump.op = new_op;
            jump.size = compact_size;
            patch_offsets += 1;

            // F3 anchor-split instrumentation: label addresses and source pcs
            // are shifted below as two independent arrays. Both use the SAME
            // predicate and delta, so the only way they can end up disagreeing
            // is an event sitting STRICTLY INSIDE the removed bytes
            // `(jump.pos, source_start)` - that event would be pulled behind
            // its own instruction by one array while the other kept it. These
            // counters make that population falsifiable instead of argued.
            if (comptime cfg.audit_oracles) {
                var window_labels: u64 = 0;
                var window_sources: u64 = 0;
                for (self.addr) |label_addr| {
                    if (label_addr != labels.unbound and
                        label_addr > jump.pos and label_addr < source_start)
                    {
                        window_labels += 1;
                    }
                }
                for (self.output_sources[0..self.output_source_len]) |source| {
                    if (source.pc > jump.pos and source.pc < source_start) window_sources += 1;
                }
                cfg.recordRelaxCompaction(window_sources, window_labels);
            }

            for (self.addr) |*label_addr| {
                if (label_addr.* != labels.unbound and label_addr.* > jump.pos)
                    label_addr.* -= delta;
            }
            var later = index + 1;
            while (later < self.jump_count) : (later += 1) {
                if (self.jump_slots[later].pos > jump.pos)
                    self.jump_slots[later].pos -= delta;
            }
            for (self.output_sources[0..self.output_source_len]) |*source| {
                if (source.pc > jump.pos) source.pc -= delta;
            }
        }

        if (patch_offsets != 0) {
            for (self.jump_slots[0..self.jump_count]) |jump| {
                if (jump.label >= self.product.label_len or
                    self.addr[jump.label] == labels.unbound)
                {
                    return error.InvalidBytecode;
                }
                const diff = @as(i64, self.addr[jump.label]) - @as(i64, jump.pos);
                try self.writeRelative(jump.pos, jump.size, diff);
            }
        }
    }

    /// F3 audit scratch: one bit per emitted source event, set when that event
    /// sat exactly on a bound identity's final address before relaxJumps.
    const AnchorCoincidence = struct {
        bits: []u8 = &.{},
        count: u64 = 0,

        fn deinit(self: *AnchorCoincidence, memory: *core.memory.MemoryAccount) void {
            if (self.bits.len != 0) memory.free(u8, self.bits);
            self.bits = &.{};
        }
    };

    /// True when `pc` equals the final address of some bound alias group.
    /// `group_cursor` walks `self.binds` monotonically, so a caller iterating
    /// source events in ascending pc order pays one merge, not a search each.
    fn anchorAtAddress(self: *const Resolver, pc: u32, group_cursor: *usize) bool {
        while (group_cursor.* < self.binds.len) {
            var group_end = group_cursor.* + 1;
            while (group_end < self.binds.len and
                self.binds[group_end].bound_offset ==
                    self.binds[group_cursor.*].bound_offset) : (group_end += 1)
            {}
            const group_identity = self.binds[group_cursor.*].label_index;
            if (group_identity >= self.addr.len) return false;
            const group_address = self.addr[group_identity];
            if (group_address == labels.unbound or group_address < pc) {
                group_cursor.* = group_end;
                continue;
            }
            return group_address == pc;
        }
        return false;
    }

    fn captureAnchorCoincidence(self: *const Resolver) Error!AnchorCoincidence {
        if (comptime !cfg.audit_oracles) return .{};
        if (self.output_source_len == 0) return .{};
        const byte_count = (@as(usize, self.output_source_len) + 7) / 8;
        const bits = self.memory.alloc(u8, byte_count) catch return error.OutOfMemory;
        @memset(bits, 0);
        var result: AnchorCoincidence = .{ .bits = bits };
        var group_cursor: usize = 0;
        for (self.output_sources[0..self.output_source_len], 0..) |source, index| {
            if (!self.anchorAtAddress(source.pc, &group_cursor)) continue;
            bits[index / 8] |= @as(u8, 1) << @intCast(index % 8);
            result.count += 1;
        }
        return result;
    }

    fn reportAnchorCoincidence(self: *const Resolver, before: *const AnchorCoincidence) void {
        if (comptime !cfg.audit_oracles) return;
        var after_count: u64 = 0;
        var lost: u64 = 0;
        var gained: u64 = 0;
        var group_cursor: usize = 0;
        for (self.output_sources[0..self.output_source_len], 0..) |source, index| {
            const after = self.anchorAtAddress(source.pc, &group_cursor);
            if (after) after_count += 1;
            const was = before.bits.len > index / 8 and
                (before.bits[index / 8] & (@as(u8, 1) << @intCast(index % 8))) != 0;
            if (was and !after) lost += 1;
            if (after and !was) gained += 1;
        }
        cfg.recordRelaxCoincidence(before.count, after_count, lost, gained);
    }

    /// Debug/ReleaseSafe product-to-final proof obligation. Canonical
    /// identities are compared before final addresses; address equality only
    /// corroborates the already-matched identity chain.
    fn auditFinalBoundaryIdentity(self: *const Resolver) Error!void {
        if (self.product.label_len > self.product.label_slots.len or
            self.addr.len < self.product.label_len or
            self.jump_count > self.jump_slots.len or
            self.output_len > self.output.len or
            self.output_source_len > self.output_sources.len)
        {
            return error.InvalidBytecode;
        }

        var bound_count: usize = 0;
        for (self.product.label_slots[0..self.product.label_len]) |slot| {
            if (slot.flags.bound) bound_count += 1;
        }
        if (bound_count != self.binds.len) return error.InvalidBytecode;

        var previous_bind: ?BindEntry = null;
        for (self.binds) |entry| {
            if (entry.label_index >= self.product.label_len)
                return error.InvalidBytecode;
            const slot = self.product.label_slots[entry.label_index];
            if (!slot.flags.bound or slot.bound_offset != entry.bound_offset)
                return error.InvalidBytecode;
            if (previous_bind) |previous| {
                if (entry.bound_offset < previous.bound_offset or
                    (entry.bound_offset == previous.bound_offset and
                        entry.label_index <= previous.label_index))
                {
                    return error.InvalidBytecode;
                }
            }
            previous_bind = entry;
        }

        var previous_live_address: ?u32 = null;
        var live_group_count: u64 = 0;
        var group_start: usize = 0;
        while (group_start < self.binds.len) {
            var group_end = group_start + 1;
            while (group_end < self.binds.len and
                self.binds[group_end].bound_offset == self.binds[group_start].bound_offset) : (group_end += 1)
            {}
            const group = self.binds[group_start..group_end];
            const product_offset = group[0].bound_offset;
            const canonical_identity = group[0].label_index;
            if (canonicalIdentityAtProductOffset(self.binds, product_offset) != canonical_identity)
                return error.InvalidBytecode;

            if (finalAliasSplit(group, self.addr)) |split| {
                panicFinalBoundaryUniquenessViolation(
                    .boundary_mismatch,
                    "alias_final_address_split",
                    "position",
                    .{ canonical_identity, canonical_identity },
                    .{ split.first_label, split.second_label },
                    .{ product_offset, product_offset },
                    .{ split.first_address, split.second_address },
                );
            }
            if (aliasLivenessSplit(group, self.addr)) |split| {
                panicFinalBoundaryUniquenessViolation(
                    .boundary_mismatch,
                    "alias_liveness_split",
                    "position",
                    .{ canonical_identity, canonical_identity },
                    .{ split.live_label, split.retired_label },
                    .{ product_offset, product_offset },
                    .{ self.addr[split.live_label], self.addr[split.retired_label] },
                );
            }

            const group_address = self.addr[canonical_identity];
            if (group_address == labels.unbound) {
                for (group) |entry| {
                    const slot = self.product.label_slots[entry.label_index];
                    if (retiredIdentityStillReferenced(entry, slot)) {
                        panicFinalBoundaryUniquenessViolation(
                            .binding_mismatch,
                            "retired_identity_still_referenced",
                            "position",
                            .{ canonical_identity, canonical_identity },
                            .{ entry.label_index, canonical_identity },
                            .{ product_offset, product_offset },
                            .{ self.addr[entry.label_index], group_address },
                        );
                    }
                }
            } else {
                if (group_address > self.output_len) return error.InvalidBytecode;
                if (previous_live_address) |previous| {
                    if (group_address < previous) return error.InvalidBytecode;
                }
                previous_live_address = group_address;
                live_group_count += 1;
            }
            group_start = group_end;
        }

        for (self.jump_slots[0..self.jump_count]) |jump| {
            if (jump.label >= self.product.label_len)
                return error.InvalidBytecode;
            const target_slot = self.product.label_slots[jump.label];
            if (!target_slot.flags.bound or target_slot.bound_offset == labels.unbound)
                return error.InvalidBytecode;

            // JumpSlot retains the jump subsystem's canonical identity when
            // emitted. Recompute the position subsystem's identity from the
            // held LabelSlot offset, then compare identities before reading an
            // address or decoding the relative operand.
            const jump_identity = jump.canonical_identity;
            const boundary_identity = canonicalIdentityAtProductOffset(
                self.binds,
                target_slot.bound_offset,
            ) orelse return error.InvalidBytecode;
            if (jump_identity >= self.product.label_len)
                return error.InvalidBytecode;
            const jump_identity_slot = self.product.label_slots[jump_identity];
            if (!jump_identity_slot.flags.bound or
                jump_identity_slot.bound_offset == labels.unbound)
            {
                return error.InvalidBytecode;
            }
            if (jump_identity != boundary_identity) {
                panicFinalBoundaryUniquenessViolation(
                    .binding_mismatch,
                    "cross_subsystem_identity_split",
                    "jump_target",
                    .{ jump_identity, boundary_identity },
                    .{ jump.label, boundary_identity },
                    .{ jump_identity_slot.bound_offset, target_slot.bound_offset },
                    .{ self.addr[jump.label], self.addr[boundary_identity] },
                );
            }

            const encoded_address = try resolvedJumpAddress(
                self.output[0..self.output_len],
                self.output_len,
                jump,
            );
            const target_address = self.addr[jump.label];
            if (target_address == labels.unbound or encoded_address != target_address) {
                panicFinalBoundaryUniquenessViolation(
                    .binding_mismatch,
                    "cross_subsystem_identity_split",
                    "jump_target",
                    .{ jump_identity, boundary_identity },
                    .{ jump.label, boundary_identity },
                    .{ jump_identity_slot.bound_offset, target_slot.bound_offset },
                    .{ target_address, encoded_address },
                );
            }
        }

        var source_group_start: usize = 0;
        var previous_source_pc: ?u32 = null;
        var source_events_on_identity: u64 = 0;
        var source_events_between_identities: u64 = 0;
        for (self.output_sources[0..self.output_source_len]) |source| {
            if (source.pc >= self.output_len) return error.InvalidBytecode;
            if (previous_source_pc) |previous| {
                if (source.pc < previous) return error.InvalidBytecode;
            }
            previous_source_pc = source.pc;

            var on_identity = false;
            while (source_group_start < self.binds.len) {
                var source_group_end = source_group_start + 1;
                while (source_group_end < self.binds.len and
                    self.binds[source_group_end].bound_offset == self.binds[source_group_start].bound_offset) : (source_group_end += 1)
                {}
                const group_identity = self.binds[source_group_start].label_index;
                const group_address = self.addr[group_identity];
                if (group_address == labels.unbound or group_address < source.pc) {
                    source_group_start = source_group_end;
                    continue;
                }
                on_identity = group_address == source.pc;
                break;
            }
            if (on_identity)
                source_events_on_identity += 1
            else
                source_events_between_identities += 1;
        }
        cfg.recordFinalSourceCensus(
            self.output_source_len,
            source_events_on_identity,
            source_events_between_identities,
        );
        cfg.recordFinalBoundaryHops(live_group_count);
    }

    fn validateFinalSources(self: *const Resolver) Error!void {
        var previous_pc: u32 = 0;
        for (self.output_sources[0..self.output_source_len], 0..) |source, index| {
            if (source.pc >= self.output_len or
                (index != 0 and source.pc < previous_pc))
            {
                return error.InvalidBytecode;
            }
            previous_pc = source.pc;
        }
    }

    fn validateFinalOutput(self: *const Resolver) Error!void {
        const code = self.output[0..self.output_len];
        var position: u32 = 0;
        var atom_index: u32 = 0;
        while (position < self.output_len) {
            const instruction = try decodeInstruction(code, position);
            if (instruction.op_id == op.invalid) return error.InvalidBytecode;
            if (hasAtomFormat(instruction.format)) {
                if (atom_index >= self.output_atom_len)
                    return error.InvalidBytecode;
                if (try readU32At(code, position, 1) != self.output_atoms[atom_index])
                    return error.InvalidBytecode;
                atom_index += 1;
            }
            position += instruction.size;
        }
        if (position != self.output_len or atom_index != self.output_atom_len)
            return error.InvalidBytecode;
        try self.validateFinalSources();
    }

    fn installSourceLocsNoFail(
        self: *Resolver,
        function: *bytecode.Bytecode,
        owned: []SourceLocSlot,
        owned_capacity: usize,
    ) void {
        std.debug.assert(owned.len <= owned_capacity);
        std.debug.assert(owned_capacity != 0 or owned.len == 0);
        const old = function.source_loc_slots;
        const old_capacity = function.source_loc_capacity;
        function.source_loc_slots = owned;
        function.source_loc_capacity = owned_capacity;
        if (old_capacity != 0)
            self.memory.free(SourceLocSlot, old.ptr[0..old_capacity]);
    }

    /// Sole ownership-transfer point for the growable final outputs. Every
    /// operation is allocation-free and infallible, so no observable
    /// half-install can escape by construction.
    fn commit(self: *Resolver) void {
        const owned_code = self.output[0..self.output_len];
        const owned_code_capacity = self.output_capacity;
        self.output = &.{};
        self.output_capacity = 0;
        self.output_len = 0;
        self.function.installCodeWithCapacity(owned_code, owned_code_capacity);

        const owned_atoms = self.output_atoms[0..self.output_atom_len];
        const owned_atom_capacity = self.output_atom_capacity;
        self.output_atoms = &.{};
        self.output_atom_capacity = 0;
        self.output_atom_len = 0;
        self.output_atoms_owned = false;
        for (self.function.atom_operands) |old_atom|
            self.atoms.free(old_atom);
        self.function.installAtomOperandsWithCapacity(owned_atoms, owned_atom_capacity);

        const owned_sources = self.output_sources[0..self.output_source_len];
        const owned_source_capacity = self.output_source_capacity;
        self.output_sources = &.{};
        self.output_source_capacity = 0;
        self.output_source_len = 0;
        self.installSourceLocsNoFail(self.function, owned_sources, owned_source_capacity);
    }
};

/// Final emission over the S3 product. product label-slot ref_counts and
/// first_reloc heads are mutated in place qjs-style. All fallible output work
/// finishes before the Bytecode's single allocation-free ownership-transfer
/// commit point.
fn runImpl(
    comptime packed_finalize_validates_code: bool,
    comptime layout: LayoutMode,
    function: *bytecode.Bytecode,
    fd: ?*const bytecode.function_def.FunctionDef,
    product: *resolve_variables.ResolvedProduct,
) Error!void {
    if (function.memory != product.memory or function.atoms != product.atoms)
        return error.InvalidBytecode;
    if (fd) |function_def| {
        if (function_def.memory != product.memory or function_def.atoms != product.atoms)
            return error.InvalidBytecode;
    }
    try validateProductMetadata(product);
    if (comptime !packed_finalize_validates_code)
        try validateProductCode(product);

    var resolver: Resolver = .{
        .function = function,
        .fd = fd,
        .product = product,
        .memory = product.memory,
        .atoms = product.atoms,
        .code = product.code[0..product.code_len],
        .input_atoms = product.atom_operands[0..product.atom_len],
        .input_sources = product.source_slots[0..product.source_len],
    };
    defer resolver.deinit();
    try resolver.initScratch(layout);
    try resolver.walk(layout);
    try resolver.releaseConsumedProduct();
    if (layout == .short) {
        // F3: relaxJumps is the one pass that moves source events and label
        // addresses after they are both fixed. Snapshot which events sit on an
        // identity BEFORE it runs and re-derive after, so "positional
        // attribution survives compaction" is measured, not assumed.
        var stability = try resolver.captureAnchorCoincidence();
        defer stability.deinit(resolver.memory);
        try resolver.relaxJumps();
        resolver.reportAnchorCoincidence(&stability);
    }
    if (comptime cfg.audit_oracles) try resolver.auditFinalBoundaryIdentity();
    if (comptime packed_finalize_validates_code) {
        // The packed FunctionBytecode choke point immediately validates final
        // code, atom-owner sequence, and var-ref bounds in one fused walk.
        // Source slots are consumed before that point, so retain their proof
        // here while avoiding a duplicate code traversal.
        try resolver.validateFinalSources();
    } else {
        try resolver.validateFinalOutput();
    }
    resolver.commit();
    std.debug.assert(resolver.output_capacity == 0 and
        resolver.output_atom_capacity == 0 and resolver.output_source_capacity == 0);
}

pub fn run(
    comptime layout: LayoutMode,
    function: *bytecode.Bytecode,
    fd: ?*const bytecode.function_def.FunctionDef,
    product: *resolve_variables.ResolvedProduct,
) Error!void {
    return runImpl(false, layout, function, fd, product);
}

/// Packed-finalize variant.  Its caller must perform the fused final-code,
/// atom-owner, and var-ref validation before publishing the FunctionBytecode.
/// All other callers use `run`, which keeps the self-contained full proof.
pub fn runForPackedFinalize(
    comptime layout: LayoutMode,
    function: *bytecode.Bytecode,
    fd: ?*const bytecode.function_def.FunctionDef,
    product: *resolve_variables.ResolvedProduct,
) Error!void {
    return runImpl(true, layout, function, fd, product);
}

const ResolveLabelsTestHarness = struct {
    rt: *core.JSRuntime,
    name_atom: core.atom.Atom,
    function: bytecode.Bytecode,
    fd: bytecode.function_def.FunctionDef,

    fn init(harness: *ResolveLabelsTestHarness, allocator: std.mem.Allocator) !void {
        harness.rt = try core.JSRuntime.create(allocator);
        errdefer harness.rt.destroy();
        harness.name_atom = try harness.rt.atoms.internString("qcp1-s4-pass-a");
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

    fn deinit(harness: *ResolveLabelsTestHarness) void {
        harness.fd.deinit(harness.rt);
        harness.function.deinit(harness.rt);
        harness.rt.atoms.free(harness.name_atom);
        harness.rt.destroy();
    }

    fn input(harness: *ResolveLabelsTestHarness) *builder.Builder {
        return harness.fd.v2_builder.?;
    }

    fn resolve(harness: *ResolveLabelsTestHarness) !resolve_variables.ResolvedProduct {
        return resolve_variables.run(&harness.function, &harness.fd);
    }
};

test "compiler_v2.resolve_labels: straight-line slot shortening and source dedupe" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    try input.addSourceMarker(10, 2);
    try input.emitOpU16(op.get_loc, 0);
    try input.addSourceMarker(10, 2);
    try input.emitOpU16(op.get_loc, 3);
    try input.addSourceMarker(20, 4);
    try input.emitOpU16(op.get_loc, 4);
    try input.emitOpU16(op.get_loc, 255);
    try input.emitOpU16(op.get_loc, 256);
    try input.emitOpU16(op.set_loc, 0);
    try input.emitOpU16(op.set_loc, 3);
    try input.emitOpU16(op.set_loc, 4);
    try input.emitOpU16(op.set_loc, 255);
    try input.emitOpU16(op.set_loc, 256);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.short, &harness.function, null, &product);

    const expected = [_]u8{
        op.get_loc0,
        op.get_loc3,
        op.get_loc8,
        4,
        op.get_loc8,
        255,
        op.get_loc,
        0,
        1,
        op.set_loc0,
        op.set_loc3,
        op.set_loc8,
        4,
        op.set_loc8,
        255,
        op.set_loc,
        0,
        1,
    };
    try std.testing.expectEqualSlices(u8, &expected, harness.function.code);
    try std.testing.expectEqual(@as(usize, 2), harness.function.source_loc_slots.len);
    try std.testing.expectEqualDeep(
        SourceLocSlot{ .pc = 0, .line_num = 10, .col_num = 2 },
        harness.function.source_loc_slots[0],
    );
    try std.testing.expectEqualDeep(
        SourceLocSlot{ .pc = 2, .line_num = 20, .col_num = 4 },
        harness.function.source_loc_slots[1],
    );
}

test "compiler_v2.resolve_labels: plain layout keeps slot families wide" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    try input.emitOpU16(op.get_loc, 0);
    try input.emitOpU16(op.get_loc, 3);
    try input.emitOpU16(op.get_loc, 4);
    try input.emitOpU16(op.get_loc, 255);
    try input.emitOpU16(op.get_loc, 256);
    try input.emitOpU16(op.set_loc, 0);
    try input.emitOpU16(op.set_loc, 3);
    try input.emitOpU16(op.set_loc, 4);
    try input.emitOpU16(op.set_loc, 255);
    try input.emitOpU16(op.set_loc, 256);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.plain, &harness.function, null, &product);

    try std.testing.expectEqualSlices(
        u8,
        &.{
            op.get_loc, 0,   0,
            op.get_loc, 3,   0,
            op.get_loc, 4,   0,
            op.get_loc, 255, 0,
            op.get_loc, 0,   1,
            op.set_loc, 0,   0,
            op.set_loc, 3,   0,
            op.set_loc, 4,   0,
            op.set_loc, 255, 0,
            op.set_loc, 0,   1,
        },
        harness.function.code,
    );
}

test "compiler_v2.resolve_labels: put-get fold preserves both source transitions" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    try input.addSourceMarker(10, 2);
    try input.emitOpU16(op.put_loc, 0);
    try input.addSourceMarker(20, 4);
    try input.emitOpU16(op.get_loc, 0);
    try input.emitOp(op.@"return");

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.short, &harness.function, null, &product);

    try std.testing.expectEqualSlices(u8, &.{ op.set_loc0, op.@"return" }, harness.function.code);
    try std.testing.expectEqualSlices(
        SourceLocSlot,
        &.{
            .{ .pc = 0, .line_num = 10, .col_num = 2 },
            .{ .pc = 0, .line_num = 20, .col_num = 4 },
        },
        harness.function.source_loc_slots,
    );
}

test "compiler_v2.resolve_labels: dup put drop get delays getter source" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    try input.addSourceMarker(10, 2);
    try input.emitOp(op.dup);
    try input.addSourceMarker(20, 4);
    try input.emitOpU16(op.put_loc, 0);
    try input.addSourceMarker(30, 6);
    try input.emitOp(op.drop);
    try input.addSourceMarker(40, 8);
    try input.emitOpU16(op.get_loc, 0);
    try input.emitOp(op.push_true);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.short, &harness.function, null, &product);

    try std.testing.expectEqualSlices(
        u8,
        &.{ op.set_loc0, op.push_true },
        harness.function.code,
    );
    try std.testing.expectEqualSlices(
        SourceLocSlot,
        &.{
            .{ .pc = 0, .line_num = 10, .col_num = 2 },
            .{ .pc = 0, .line_num = 20, .col_num = 4 },
            .{ .pc = 0, .line_num = 30, .col_num = 6 },
            .{ .pc = 1, .line_num = 40, .col_num = 8 },
        },
        harness.function.source_loc_slots,
    );
}

test "compiler_v2.resolve_labels: discarded field store delays tail sources" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const field = try harness.rt.atoms.internString("qcp1-s4-field-store");
    defer harness.rt.atoms.free(field);
    try input.addSourceMarker(10, 2);
    try input.emitOp(op.insert2);
    try input.addSourceMarker(20, 4);
    try input.emitAtomOpOwned(op.put_field, harness.rt.atoms.dup(field));
    try input.addSourceMarker(30, 6);
    try input.emitOp(op.drop);
    try input.addSourceMarker(40, 8);
    try input.emitOp(op.object);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.short, &harness.function, null, &product);

    var expected = [_]u8{ op.put_field, 0, 0, 0, 0, op.object };
    std.mem.writeInt(u32, expected[1..5], field, .little);
    try std.testing.expectEqualSlices(u8, &expected, harness.function.code);
    try std.testing.expectEqualSlices(
        SourceLocSlot,
        &.{
            .{ .pc = 0, .line_num = 10, .col_num = 2 },
            .{ .pc = 5, .line_num = 20, .col_num = 4 },
            .{ .pc = 5, .line_num = 30, .col_num = 6 },
            .{ .pc = 5, .line_num = 40, .col_num = 8 },
        },
        harness.function.source_loc_slots,
    );
}

test "compiler_v2.resolve_labels: typeof string fold preserves legacy source relocation order" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    try input.addSourceMarker(10, 2);
    try input.emitOp(op.typeof);
    try input.addSourceMarker(20, 4);
    try input.emitAtomOpOwned(
        op.push_atom_value,
        harness.rt.atoms.dup(core.atom.ids.undefined_),
    );
    try input.addSourceMarker(30, 6);
    try input.emitOp(op.strict_eq);
    try input.addSourceMarker(40, 8);
    try input.emitOp(op.push_false);
    try input.addSourceMarker(50, 10);
    try input.emitOp(op.strict_eq);
    try input.emitOp(op.@"return");

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.short, &harness.function, null, &product);

    try std.testing.expectEqualSlices(
        u8,
        &.{ op.typeof_is_undefined, op.push_false, op.strict_eq, op.@"return" },
        harness.function.code,
    );
    try std.testing.expectEqualSlices(
        SourceLocSlot,
        &.{
            .{ .pc = 0, .line_num = 10, .col_num = 2 },
            .{ .pc = 1, .line_num = 20, .col_num = 4 },
            .{ .pc = 1, .line_num = 40, .col_num = 8 },
            .{ .pc = 2, .line_num = 50, .col_num = 10 },
        },
        harness.function.source_loc_slots,
    );
}

test "compiler_v2.resolve_labels: typeof branch keeps equal next-op source" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const else_path = try input.newLabel();
    const done = try input.newLabel();
    try input.addSourceMarker(10, 2);
    try input.emitOp(op.typeof);
    try input.addSourceMarker(20, 4);
    try input.emitAtomOpOwned(
        op.push_atom_value,
        harness.rt.atoms.dup(core.atom.ids.undefined_),
    );
    try input.addSourceMarker(30, 6);
    try input.emitOp(op.strict_neq);
    try input.addSourceMarker(40, 8);
    try input.emitJump(op.if_false, else_path);
    // The parser can emit this same coordinate again for the first operand
    // after `?`; Stage 3 must retain it even though the branch marker matches.
    try input.addSourceMarker(40, 8);
    try input.emitOp(op.object);
    try input.emitJump(op.goto, done);
    try input.bindLabel(else_path);
    try input.emitOp(op.null);
    try input.bindLabel(done);
    try input.emitOp(op.@"return");

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.short, &harness.function, null, &product);

    try std.testing.expectEqualSlices(
        SourceLocSlot,
        &.{
            .{ .pc = 0, .line_num = 10, .col_num = 2 },
            .{ .pc = 3, .line_num = 20, .col_num = 4 },
            .{ .pc = 3, .line_num = 40, .col_num = 8 },
        },
        harness.function.source_loc_slots,
    );
}

test "compiler_v2.resolve_labels: backward goto selects exact i8 and i16 encodings" {
    {
        var harness: ResolveLabelsTestHarness = undefined;
        try harness.init(std.testing.allocator);
        defer harness.deinit();
        const input = harness.input();
        const loop = try input.newLabel();
        try input.bindLabel(loop);
        try input.emitOp(op.undefined);
        try input.emitJump(op.goto, loop);

        var product = try harness.resolve();
        defer product.deinitUncommitted();
        try run(.short, &harness.function, null, &product);
        try std.testing.expectEqualSlices(
            u8,
            &.{ op.undefined, op.goto8, 0xfe },
            harness.function.code,
        );
    }

    {
        var harness: ResolveLabelsTestHarness = undefined;
        try harness.init(std.testing.allocator);
        defer harness.deinit();
        const input = harness.input();
        const loop = try input.newLabel();
        try input.bindLabel(loop);
        var filler: usize = 0;
        while (filler < 130) : (filler += 1)
            try input.emitOp(op.undefined);
        try input.emitJump(op.goto, loop);

        var product = try harness.resolve();
        defer product.deinitUncommitted();
        try run(.short, &harness.function, null, &product);
        var expected = [_]u8{op.undefined} ** 133;
        expected[130] = op.goto16;
        expected[131] = 0x7d;
        expected[132] = 0xff;
        try std.testing.expectEqualSlices(u8, &expected, harness.function.code);
    }
}

test "compiler_v2.resolve_labels: plain layout keeps backward goto wide" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();
    const loop = try input.newLabel();
    try input.bindLabel(loop);
    try input.emitOp(op.undefined);
    try input.emitJump(op.goto, loop);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.plain, &harness.function, null, &product);
    try std.testing.expectEqualSlices(
        u8,
        &.{ op.undefined, op.goto, 0xfe, 0xff, 0xff, 0xff },
        harness.function.code,
    );
}

test "compiler_v2.resolve_labels: forward goto uses a one-byte relocation" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const body = try input.newLabel();
    const target = try input.newLabel();
    try input.emitJump(op.goto, target);
    try input.bindLabel(body);
    try input.emitOp(op.object);
    try input.bindLabel(target);
    try input.emitJump(op.if_false, body);
    try input.emitOp(op.object);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.short, &harness.function, null, &product);
    try std.testing.expectEqualSlices(
        u8,
        &.{ op.goto8, 2, op.object, op.if_false8, 0xfe, op.object },
        harness.function.code,
    );
}

test "compiler_v2.resolve_labels: goto16 relaxes after body shortening and moves sources" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const body = try input.newLabel();
    const target = try input.newLabel();
    try input.addSourceMarker(10, 1);
    try input.emitJump(op.goto, target);
    try input.bindLabel(body);
    var index: usize = 0;
    while (index < 30) : (index += 1)
        try input.emitOpU32(op.push_i32, 1);
    try input.bindLabel(target);
    try input.addSourceMarker(30, 3);
    try input.emitJump(op.if_false, body);
    try input.emitOp(op.object);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.short, &harness.function, null, &product);

    var expected: [35]u8 = undefined;
    expected[0] = op.goto8;
    expected[1] = 31;
    @memset(expected[2..32], op.push_1);
    expected[32] = op.if_false8;
    expected[33] = 0xe1;
    expected[34] = op.object;
    try std.testing.expectEqualSlices(u8, &expected, harness.function.code);
    try std.testing.expectEqual(@as(usize, 2), harness.function.source_loc_slots.len);
    try std.testing.expectEqual(@as(u32, 0), harness.function.source_loc_slots[0].pc);
    try std.testing.expectEqual(@as(u32, 32), harness.function.source_loc_slots[1].pc);
    try std.testing.expectEqual(@as(i32, 30), harness.function.source_loc_slots[1].line_num);
}

test "compiler_v2.resolve_labels: next conditional drops and adjacent goto inverts" {
    {
        var harness: ResolveLabelsTestHarness = undefined;
        try harness.init(std.testing.allocator);
        defer harness.deinit();
        const input = harness.input();
        const next = try input.newLabel();
        try input.emitJump(op.if_false, next);
        try input.bindLabel(next);
        try input.emitOp(op.object);

        var product = try harness.resolve();
        defer product.deinitUncommitted();
        try run(.short, &harness.function, null, &product);
        try std.testing.expectEqualSlices(
            u8,
            &.{ op.drop, op.object },
            harness.function.code,
        );
        try std.testing.expectEqual(@as(u32, 0), product.label_slots[next.index()].ref_count);
    }

    {
        var harness: ResolveLabelsTestHarness = undefined;
        try harness.init(std.testing.allocator);
        defer harness.deinit();
        const input = harness.input();
        const false_path = try input.newLabel();
        const done = try input.newLabel();
        try input.emitJump(op.if_false, false_path);
        try input.emitJump(op.goto, done);
        try input.bindLabel(false_path);
        try input.emitOp(op.undefined);
        try input.bindLabel(done);
        try input.emitOp(op.object);

        var product = try harness.resolve();
        defer product.deinitUncommitted();
        try run(.short, &harness.function, null, &product);
        try std.testing.expectEqualSlices(
            u8,
            &.{ op.if_true8, 2, op.undefined, op.object },
            harness.function.code,
        );
        try std.testing.expectEqual(
            @as(u32, 0),
            product.label_slots[false_path.index()].ref_count,
        );
    }
}

test "compiler_v2.resolve_labels: unreferenced compact bind does not block drop return fold" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const transparent = try input.newLabel();
    try input.emitOp(op.drop);
    try input.bindLabel(transparent);
    try input.emitOp(op.return_undef);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(
        @as(u32, 0),
        product.label_slots[transparent.index()].ref_count,
    );
    try run(.short, &harness.function, null, &product);
    try std.testing.expectEqualSlices(u8, &.{op.return_undef}, harness.function.code);
}

test "compiler_v2.resolve_labels: peephole consumes a spanned dead compact bind" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const transparent = try input.newLabel();
    try input.emitOp(op.undefined);
    try input.bindLabel(transparent);
    try input.emitOp(op.@"return");

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(
        @as(u32, 0),
        product.label_slots[transparent.index()].ref_count,
    );
    try run(.short, &harness.function, null, &product);
    try std.testing.expectEqualSlices(u8, &.{op.return_undef}, harness.function.code);
}

test "compiler_v2.resolve_labels: referenced compact bind blocks drop return fold" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const target = try input.newLabel();
    try input.emitOp(op.object);
    try input.emitJump(op.if_false, target);
    try input.emitOp(op.drop);
    try input.bindLabel(target);
    try input.emitOp(op.return_undef);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(@as(u32, 1), product.label_slots[target.index()].ref_count);
    try run(.short, &harness.function, null, &product);
    try std.testing.expectEqualSlices(
        u8,
        &.{ op.object, op.if_false8, 2, op.drop, op.return_undef },
        harness.function.code,
    );
}

test "compiler_v2.resolve_labels: consumed refcount remains a target barrier" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const target = try input.newLabel();
    try input.emitOp(op.push_false);
    try input.emitJump(op.if_true, target);
    try input.emitOp(op.object);
    try input.emitOp(op.drop);
    try input.bindLabel(target);
    try input.emitOp(op.return_undef);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(@as(u32, 1), product.label_slots[target.index()].ref_count);
    try run(.short, &harness.function, null, &product);
    try std.testing.expectEqualSlices(
        u8,
        &.{ op.object, op.drop, op.return_undef },
        harness.function.code,
    );
    try std.testing.expectEqual(@as(u32, 0), product.label_slots[target.index()].ref_count);
}

test "compiler_v2.resolve_labels: goto terminal fold skips live S3 fallthrough edges" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const tail = try input.newLabel();
    const returns = try input.newLabel();
    try input.emitOp(op.push_true);
    try input.emitJump(op.if_true, returns);
    try input.emitJump(op.goto, tail);
    try input.bindLabel(tail);
    try input.emitOp(op.object);
    try input.bindLabel(returns);
    try input.emitOp(op.return_undef);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(@as(u32, 1), product.label_slots[tail.index()].ref_count);
    try run(.short, &harness.function, null, &product);
    try std.testing.expectEqualSlices(
        u8,
        &.{op.return_undef},
        harness.function.code,
    );
    try std.testing.expectEqual(@as(u32, 0), product.label_slots[tail.index()].ref_count);
}

test "compiler_v2.resolve_labels: source after target drop blocks goto terminal fold" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const side = try input.newLabel();
    const target = try input.newLabel();
    try input.emitOp(op.push_true);
    try input.emitJump(op.if_false, side);
    try input.emitOp(op.object);
    try input.emitOp(op.drop);
    try input.emitJump(op.goto, target);
    try input.bindLabel(side);
    try input.emitOp(op.object);
    try input.emitOp(op.drop);
    try input.bindLabel(target);
    try input.emitOp(op.drop);
    try input.addSourceMarker(20, 4);
    try input.emitOp(op.return_undef);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.short, &harness.function, null, &product);
    try std.testing.expectEqualSlices(
        u8,
        &.{ op.object, op.drop, op.goto8, 1, op.return_undef },
        harness.function.code,
    );
}

test "compiler_v2.resolve_labels: folded typeof branch threads through dead goto" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const else_path = try input.newLabel();
    const through = try input.newLabel();
    const final = try input.newLabel();
    try input.emitOp(op.object);
    try input.emitJump(op.if_false, else_path);
    try input.emitOpU16(op.get_arg, 0);
    try input.emitOp(op.typeof);
    try input.emitAtomOpOwned(
        op.push_atom_value,
        harness.rt.atoms.dup(core.atom.ids.undefined_),
    );
    try input.emitOp(op.neq);
    try input.emitJump(op.if_false, through);
    try input.emitOp(op.object);
    try input.emitOp(op.@"return");
    try input.bindLabel(through);
    try input.emitJump(op.goto, final);
    try input.bindLabel(else_path);
    try input.emitOp(op.null);
    try input.emitOp(op.@"return");
    try input.bindLabel(final);
    try input.emitOpU16(op.get_arg, 0);
    try input.emitOp(op.@"return");

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.short, &harness.function, null, &product);
    try std.testing.expectEqualSlices(
        u8,
        &.{
            op.object,
            op.if_false8,
            7,
            op.get_arg0,
            op.typeof_is_undefined,
            op.if_true8,
            5,
            op.object,
            op.@"return",
            op.null,
            op.@"return",
            op.get_arg0,
            op.@"return",
        },
        harness.function.code,
    );
    try std.testing.expectEqual(@as(u32, 0), product.label_slots[through.index()].ref_count);
    try std.testing.expectEqual(@as(usize, 0), harness.function.atom_operands.len);
}

test "compiler_v2.resolve_labels: folded nullish branches thread through dead goto" {
    const cases = [_]struct { literal: u8, test_op: u8 }{
        .{ .literal = op.null, .test_op = op.is_null },
        .{ .literal = op.undefined, .test_op = op.is_undefined },
    };

    for (cases) |case| {
        var harness: ResolveLabelsTestHarness = undefined;
        try harness.init(std.testing.allocator);
        defer harness.deinit();
        const input = harness.input();

        const else_path = try input.newLabel();
        const through = try input.newLabel();
        const final = try input.newLabel();
        try input.emitOp(op.object);
        try input.emitJump(op.if_false, else_path);
        try input.emitOpU16(op.get_arg, 0);
        try input.emitOp(case.literal);
        try input.emitOp(op.strict_neq);
        try input.emitJump(op.if_false, through);
        try input.emitOp(op.object);
        try input.emitOp(op.@"return");
        try input.bindLabel(through);
        try input.emitJump(op.goto, final);
        try input.bindLabel(else_path);
        try input.emitOp(op.null);
        try input.emitOp(op.@"return");
        try input.bindLabel(final);
        try input.emitOpU16(op.get_arg, 0);
        try input.emitOp(op.@"return");

        var product = try harness.resolve();
        defer product.deinitUncommitted();
        try run(.short, &harness.function, null, &product);
        try std.testing.expectEqualSlices(
            u8,
            &.{
                op.object,
                op.if_false8,
                7,
                op.get_arg0,
                case.test_op,
                op.if_true8,
                5,
                op.object,
                op.@"return",
                op.null,
                op.@"return",
                op.get_arg0,
                op.@"return",
            },
            harness.function.code,
        );
        try std.testing.expectEqual(@as(u32, 0), product.label_slots[through.index()].ref_count);
    }
}

test "compiler_v2.resolve_labels: zero-ref parser label blocks nullish branch fold" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const parser_label = try input.newLabel();
    const done = try input.newLabel();
    try input.emitOpU16(op.get_arg, 0);
    try input.emitOp(op.null);
    try input.emitOp(op.strict_neq);
    try input.bindLabelMatchBarrier(parser_label);
    try input.emitJump(op.if_false, done);
    try input.emitOpU16(op.get_arg, 0);
    try input.emitOp(op.@"return");
    try input.bindLabel(done);
    try input.emitOp(op.undefined);
    try input.emitOp(op.@"return");

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(
        @as(u32, 0),
        product.label_slots[parser_label.index()].ref_count,
    );
    try std.testing.expect(product.label_slots[parser_label.index()].flags.bound);
    try std.testing.expect(product.label_slots[parser_label.index()].flags.match_barrier);

    try run(.short, &harness.function, null, &product);
    try std.testing.expectEqualSlices(
        u8,
        &.{ op.get_arg0, op.null, op.strict_neq, op.if_false8 },
        harness.function.code[0..4],
    );
    try std.testing.expect(std.mem.indexOfScalar(u8, harness.function.code, op.is_null) == null);
}

test "compiler_v2.resolve_labels: ret discards an unreachable tail" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    try input.emitOp(op.ret);
    try input.emitOp(op.object);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.short, &harness.function, null, &product);
    try std.testing.expectEqualSlices(u8, &.{op.ret}, harness.function.code);
}

test "compiler_v2.resolve_labels: two-hop goto threading targets the final label" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const first = try input.newLabel();
    const final = try input.newLabel();
    try input.emitOp(op.push_true);
    try input.emitJump(op.if_true, first);
    try input.emitOp(op.undefined);
    try input.bindLabel(first);
    try input.emitJump(op.goto, final);
    try input.bindLabel(final);
    try input.emitOp(op.object);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.short, &harness.function, null, &product);
    try std.testing.expectEqualSlices(
        u8,
        &.{ op.goto8, 1, op.object },
        harness.function.code,
    );
    try std.testing.expectEqual(@as(u32, 0), product.label_slots[first.index()].ref_count);
    try std.testing.expectEqual(@as(u32, 1), product.label_slots[final.index()].ref_count);
}

test "compiler_v2.resolve_labels: goto over dead switch trampoline becomes fallthrough" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const no_match = try input.newLabel();
    const default_body = try input.newLabel();
    const skip_dispatch = try input.newLabel();
    try input.emitOpU16(op.get_arg, 0);
    try input.emitJump(op.if_false, no_match);
    try input.emitOp(op.object);
    try input.bindLabel(default_body);
    try input.emitOp(op.null);
    try input.emitJump(op.goto, skip_dispatch);
    try input.bindLabel(no_match);
    try input.emitJump(op.goto, default_body);
    try input.bindLabel(skip_dispatch);
    try input.emitOpU16(op.get_arg, 0);
    try input.emitOp(op.@"return");

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.short, &harness.function, null, &product);
    try std.testing.expectEqualSlices(
        u8,
        &.{ op.get_arg0, op.if_false8, 2, op.object, op.null, op.get_arg0, op.@"return" },
        harness.function.code,
    );
    try std.testing.expectEqual(@as(u32, 0), product.label_slots[no_match.index()].ref_count);
    try std.testing.expectEqual(@as(u32, 0), product.label_slots[skip_dispatch.index()].ref_count);
}

test "compiler_v2.resolve_labels: sourceful constant-false loop keeps legacy goto edge" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const loop_top = try input.newLabel();
    const exit = try input.newLabel();
    try input.bindLabel(loop_top);
    try input.emitOp(op.push_false);
    try input.emitJump(op.if_false, exit);
    try input.addSourceMarker(10, 2);
    try input.emitJump(op.goto, loop_top);
    try input.bindLabel(exit);
    try input.emitOpU16(op.get_arg, 0);
    try input.emitOp(op.@"return");

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.short, &harness.function, null, &product);
    try std.testing.expectEqualSlices(
        u8,
        &.{ op.goto8, 1, op.get_arg0, op.@"return" },
        harness.function.code,
    );
}

test "compiler_v2.resolve_labels: variable pass removes forward-only dead tail" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const target = try input.newLabel();
    try input.emitJump(op.goto, target);
    try input.emitOp(op.object);
    try input.emitJump(op.goto, target);
    try input.bindLabel(target);
    try input.emitOpU16(op.get_arg, 0);
    try input.emitOp(op.@"return");

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.short, &harness.function, null, &product);
    try std.testing.expectEqualSlices(
        u8,
        &.{ op.get_arg0, op.@"return" },
        harness.function.code,
    );
    try std.testing.expectEqual(@as(u32, 0), product.label_slots[target.index()].ref_count);
}

test "compiler_v2.resolve_labels: boolean constant tests become goto or nothing" {
    {
        var harness: ResolveLabelsTestHarness = undefined;
        try harness.init(std.testing.allocator);
        defer harness.deinit();
        const input = harness.input();
        const target = try input.newLabel();
        try input.emitOp(op.push_true);
        try input.emitJump(op.if_true, target);
        try input.emitOp(op.undefined);
        try input.bindLabel(target);
        try input.emitOp(op.object);

        var product = try harness.resolve();
        defer product.deinitUncommitted();
        try run(.short, &harness.function, null, &product);
        try std.testing.expectEqualSlices(
            u8,
            &.{ op.goto8, 1, op.object },
            harness.function.code,
        );
        try std.testing.expectEqual(@as(u32, 1), product.label_slots[target.index()].ref_count);
    }

    {
        var harness: ResolveLabelsTestHarness = undefined;
        try harness.init(std.testing.allocator);
        defer harness.deinit();
        const input = harness.input();
        const target = try input.newLabel();
        try input.emitOp(op.push_false);
        try input.emitJump(op.if_true, target);
        try input.bindLabel(target);
        try input.emitOp(op.object);

        var product = try harness.resolve();
        defer product.deinitUncommitted();
        try run(.short, &harness.function, null, &product);
        try std.testing.expectEqualSlices(u8, &.{op.object}, harness.function.code);
        try std.testing.expectEqual(@as(u32, 0), product.label_slots[target.index()].ref_count);
    }
}

test "compiler_v2.resolve_labels: dup put and local update peepholes use short forms" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    try input.emitOp(op.dup);
    try input.emitOpU16(op.put_loc, 0);
    try input.emitOp(op.drop);
    try input.emitOpU16(op.put_loc, 1);
    try input.emitOpU16(op.get_loc, 1);
    try input.emitOpU16(op.get_loc, 2);
    try input.emitOp(op.post_inc);
    try input.emitOpU16(op.put_loc, 2);
    try input.emitOp(op.drop);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.short, &harness.function, null, &product);
    try std.testing.expectEqualSlices(
        u8,
        &.{ op.put_loc0, op.set_loc1, op.inc_loc, 2 },
        harness.function.code,
    );
}

test "compiler_v2.resolve_labels: post-update tails publish sources afterward" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const field = try harness.rt.atoms.internString("qcp1-s4-post-field");
    defer harness.rt.atoms.free(field);

    try input.addSourceMarker(10, 1);
    try input.emitOp(op.post_inc);
    try input.addSourceMarker(20, 2);
    try input.emitOpU16(op.put_loc, 0);
    try input.addSourceMarker(30, 3);
    try input.emitOp(op.drop);

    try input.addSourceMarker(40, 4);
    try input.emitOp(op.post_dec);
    try input.addSourceMarker(50, 5);
    try input.emitOp(op.perm3);
    try input.addSourceMarker(60, 6);
    try input.emitAtomOpOwned(op.put_field, harness.rt.atoms.dup(field));
    try input.addSourceMarker(70, 7);
    try input.emitOp(op.drop);

    try input.addSourceMarker(80, 8);
    try input.emitOp(op.post_inc);
    try input.addSourceMarker(90, 9);
    try input.emitOp(op.perm4);
    try input.addSourceMarker(100, 10);
    try input.emitOp(op.put_array_el);
    try input.addSourceMarker(110, 11);
    try input.emitOp(op.drop);
    try input.addSourceMarker(120, 12);
    try input.emitOp(op.object);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.short, &harness.function, null, &product);

    var expected = [_]u8{
        op.inc,    op.put_loc0,
        op.dec,    op.put_field,
        0,         0,
        0,         0,
        op.inc,    op.put_array_el,
        op.object,
    };
    std.mem.writeInt(u32, expected[4..8], field, .little);
    try std.testing.expectEqualSlices(u8, &expected, harness.function.code);
    try std.testing.expectEqualSlices(
        SourceLocSlot,
        &.{
            .{ .pc = 0, .line_num = 10, .col_num = 1 },
            .{ .pc = 2, .line_num = 20, .col_num = 2 },
            .{ .pc = 2, .line_num = 30, .col_num = 3 },
            .{ .pc = 2, .line_num = 40, .col_num = 4 },
            .{ .pc = 8, .line_num = 50, .col_num = 5 },
            .{ .pc = 8, .line_num = 60, .col_num = 6 },
            .{ .pc = 8, .line_num = 70, .col_num = 7 },
            .{ .pc = 8, .line_num = 80, .col_num = 8 },
            .{ .pc = 10, .line_num = 90, .col_num = 9 },
            .{ .pc = 10, .line_num = 100, .col_num = 10 },
            .{ .pc = 10, .line_num = 110, .col_num = 11 },
            .{ .pc = 10, .line_num = 120, .col_num = 12 },
        },
        harness.function.source_loc_slots,
    );
}

test "compiler_v2.resolve_labels: integer negation and short constants are byte exact" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    try input.emitOpU32(op.push_i32, @bitCast(@as(i32, -5)));
    try input.emitOp(op.neg);
    try input.emitOpU32(op.push_i32, 3);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.short, &harness.function, null, &product);
    try std.testing.expectEqualSlices(
        u8,
        &.{ op.push_5, op.push_3 },
        harness.function.code,
    );
}

test "compiler_v2.resolve_labels: dropped atom and length field balance ownership" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();
    const input = harness.input();

    const named = try harness.rt.atoms.internString("qcp1-s4-dropped");
    defer harness.rt.atoms.free(named);
    const base_refs = harness.rt.atoms.refCount(named).?;
    try input.emitAtomOpOwned(
        op.push_atom_value,
        harness.rt.atoms.dup(named),
    );
    try input.emitOp(op.drop);
    try input.emitAtomOpOwned(
        op.get_field,
        harness.rt.atoms.dup(core.atom.ids.length),
    );

    var product = try harness.resolve();
    try run(.short, &harness.function, null, &product);
    try std.testing.expectEqualSlices(u8, &.{op.get_length}, harness.function.code);
    try std.testing.expectEqual(@as(usize, 0), harness.function.atom_operands.len);
    product.deinitUncommitted();
    try std.testing.expectEqual(base_refs + 1, harness.rt.atoms.refCount(named).?);
}

test "compiler_v2.resolve_labels: shared with probes resolve operand-relative done label" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();

    const name = try harness.rt.atoms.internString("qcp1-s4-with-probe");
    defer harness.rt.atoms.free(name);
    _ = try harness.fd.appendScope(-1);
    harness.fd.var_object_idx = try harness.fd.appendVar(.{
        .var_name = core.atom.ids.var_object,
        .scope_level = 0,
        .scope_next = 0,
        .var_kind = .normal,
    });
    harness.fd.arg_var_object_idx = try harness.fd.appendVar(.{
        .var_name = core.atom.ids.arg_var_object,
        .scope_level = 0,
        .scope_next = 0,
        .var_kind = .normal,
    });
    _ = try harness.fd.addClosureVar(.{
        .closure_type = .global,
        .is_lexical = false,
        .is_const = false,
        .var_kind = .normal,
        .var_idx = 0,
        .var_name = name,
    });
    try harness.input().emitAtomOpU16Owned(
        op.scope_get_var,
        harness.rt.atoms.dup(name),
        0,
    );
    try harness.input().emitOp(op.return_undef);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try std.testing.expectEqual(@as(u32, 2), product.jump_size);
    try std.testing.expectEqual(op.with_get_var, product.code[3]);
    try std.testing.expectEqual(op.with_get_var, product.code[16]);
    try run(.short, &harness.function, null, &product);

    var expected = [_]u8{0} ** 26;
    expected[0] = op.get_loc0;
    expected[1] = op.with_get_var;
    std.mem.writeInt(u32, expected[2..6], name, .little);
    std.mem.writeInt(i32, expected[6..10], 19, .little);
    expected[10] = 0;
    expected[11] = op.get_loc1;
    expected[12] = op.with_get_var;
    std.mem.writeInt(u32, expected[13..17], name, .little);
    std.mem.writeInt(i32, expected[17..21], 8, .little);
    expected[21] = 0;
    expected[22] = op.get_var;
    std.mem.writeInt(u16, expected[23..25], 0, .little);
    expected[25] = op.return_undef;
    try std.testing.expectEqualSlices(u8, &expected, harness.function.code);
    try std.testing.expectEqualSlices(
        core.atom.Atom,
        &.{ name, name },
        harness.function.atom_operands,
    );
}

test "compiler_v2.resolve_labels: strict this and arguments prologue is exact" {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(std.testing.allocator);
    defer harness.deinit();

    _ = try harness.fd.appendScope(-1);
    harness.fd.this_var_idx = try harness.fd.addScopeVar(
        core.atom.ids.this_,
        .normal,
        0,
        false,
        false,
    );
    harness.fd.arguments_var_idx = try harness.fd.addScopeVar(
        core.atom.ids.arguments,
        .normal,
        0,
        false,
        false,
    );
    harness.fd.is_strict_mode = true;
    try harness.input().emitOp(op.object);

    var product = try harness.resolve();
    defer product.deinitUncommitted();
    try run(.short, &harness.function, &harness.fd, &product);
    try std.testing.expectEqualSlices(
        u8,
        &.{
            op.push_this,
            op.put_loc0,
            op.special_object,
            opcode.special_object_subtype.arguments,
            op.put_loc1,
            op.object,
        },
        harness.function.code,
    );
    try std.testing.expectEqual(@as(usize, 0), harness.function.source_loc_slots.len);
}

fn resolveLabelsOomScript(allocator: std.mem.Allocator) !void {
    var harness: ResolveLabelsTestHarness = undefined;
    try harness.init(allocator);
    defer harness.deinit();
    const input = harness.input();

    const name = try harness.rt.atoms.internString("qcp1-s4-oom");
    defer harness.rt.atoms.free(name);
    const base_refs = harness.rt.atoms.refCount(name).?;
    const body = try input.newLabel();
    const target = try input.newLabel();
    try input.addSourceMarker(10, 1);
    try input.emitJump(op.goto, target);
    try input.bindLabel(body);
    var index: usize = 0;
    while (index < 30) : (index += 1)
        try input.emitOpU32(op.push_i32, 1);
    try input.addSourceMarker(20, 2);
    try input.emitAtomOpOwned(op.get_field, harness.rt.atoms.dup(name));
    try input.bindLabel(target);
    try input.addSourceMarker(30, 3);
    try input.emitJump(op.if_false, body);
    try input.emitOp(op.object);
    try std.testing.expectEqual(base_refs + 1, harness.rt.atoms.refCount(name).?);

    var product = harness.resolve() catch |err| {
        try std.testing.expectEqual(@as(usize, 0), harness.function.code.len);
        try std.testing.expectEqual(base_refs + 1, harness.rt.atoms.refCount(name).?);
        return err;
    };
    var product_live = true;
    defer if (product_live) product.deinitUncommitted();

    run(.short, &harness.function, null, &product) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), harness.function.code.len);
        try std.testing.expectEqual(@as(usize, 0), harness.function.atom_operands.len);
        product.deinitUncommitted();
        product_live = false;
        try std.testing.expectEqual(base_refs + 1, harness.rt.atoms.refCount(name).?);
        return err;
    };

    try std.testing.expect(harness.function.code.len != 0);
    try std.testing.expectEqualSlices(
        core.atom.Atom,
        &.{name},
        harness.function.atom_operands,
    );
    product.deinitUncommitted();
    product_live = false;
    try std.testing.expectEqual(base_refs + 2, harness.rt.atoms.refCount(name).?);
}

test "compiler_v2.resolve_labels: allocation failure sweep is transactional" {
    try resolveLabelsOomScript(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        resolveLabelsOomScript,
        .{},
    );
}

test "compiler_v2.resolve_labels: alias group resolves to one final address" {
    const group = [_]BindEntry{
        .{
            .bound_offset = 4,
            .label_index = 0,
            .initially_referenced = true,
            .match_barrier = false,
        },
        .{
            .bound_offset = 4,
            .label_index = 1,
            .initially_referenced = true,
            .match_barrier = false,
        },
    };
    const addr = [_]u32{ 9, 9 };
    try std.testing.expect(finalAliasSplit(&group, &addr) == null);
    try std.testing.expect(aliasLivenessSplit(&group, &addr) == null);
}

test "compiler_v2.resolve_labels: split final addresses are rejected" {
    const group = [_]BindEntry{
        .{
            .bound_offset = 4,
            .label_index = 0,
            .initially_referenced = true,
            .match_barrier = false,
        },
        .{
            .bound_offset = 4,
            .label_index = 1,
            .initially_referenced = true,
            .match_barrier = false,
        },
    };
    const addr = [_]u32{ 9, 10 };
    const split = finalAliasSplit(&group, &addr) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 0), split.first_label);
    try std.testing.expectEqual(@as(u32, 1), split.second_label);
}

test "compiler_v2.resolve_labels: a half-retired alias group is rejected" {
    const group = [_]BindEntry{
        .{
            .bound_offset = 4,
            .label_index = 0,
            .initially_referenced = true,
            .match_barrier = false,
        },
        .{
            .bound_offset = 4,
            .label_index = 1,
            .initially_referenced = false,
            .match_barrier = false,
            .dead_skipped = true,
        },
    };
    const addr = [_]u32{ 9, labels.unbound };
    const split = aliasLivenessSplit(&group, &addr) orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 0), split.live_label);
    try std.testing.expectEqual(@as(u32, 1), split.retired_label);
}

test "compiler_v2.resolve_labels: identical final address is not a defence" {
    const binds = [_]BindEntry{
        .{
            .bound_offset = 4,
            .label_index = 0,
            .initially_referenced = true,
            .match_barrier = false,
        },
        .{
            .bound_offset = 8,
            .label_index = 1,
            .initially_referenced = true,
            .match_barrier = false,
        },
    };
    const addr = [_]u32{ 12, 12 };
    const first_identity = canonicalIdentityAtProductOffset(&binds, 4).?;
    const second_identity = canonicalIdentityAtProductOffset(&binds, 8).?;
    try std.testing.expect(first_identity != second_identity);
    try std.testing.expectEqual(addr[first_identity], addr[second_identity]);
}

test {
    _ = builtin;
}
