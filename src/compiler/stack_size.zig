//! Phase 3c: compute_stack_size
//!
//! Mirrors `compute_stack_size` at `quickjs.c`.
//!
//! Performs a BFS over the bytecode graph to compute the maximum
//! stack depth. Validates that:
//!   - no path causes a stack underflow
//!   - the same pc is never revisited with a different stack level
//!   - max stack depth never exceeds `JS_STACK_SIZE_MAX`
//!
//! Operates on bytecode that has already been through `resolve_labels`
//! (jumps are relative); the BFS walks fall-through and jump
//! successors symmetrically.

const std = @import("std");
const bytecode_mod = @import("../bytecode.zig");
const atom = @import("../core/atom.zig");
const bulk_memory = @import("../core/bulk_memory.zig");
const runtime = @import("../core/runtime.zig");
const pipeline = bytecode_mod.pipeline;
const opcode = bytecode_mod.opcode;

/// `JS_STACK_SIZE_MAX` mirror.
pub const JS_STACK_SIZE_MAX: u16 = 0xFFFE;

/// Sentinel: pc has not yet been visited.
const STACK_LEVEL_UNVISITED: u16 = 0xFFFF;

const ScratchRow = struct {
    stack_level: u16,
    catch_pos: i32,
    pending_pc: u32,
};
const scratch_bytes_per_position =
    @sizeOf(@FieldType(ScratchRow, "stack_level")) +
    @sizeOf(@FieldType(ScratchRow, "catch_pos")) +
    @sizeOf(@FieldType(ScratchRow, "pending_pc"));
const stack_scratch_position_capacity = 256;
const stack_scratch_bytes =
    stack_scratch_position_capacity * scratch_bytes_per_position +
    @alignOf(i32) - 1;

pub const Error = error{
    StackUnderflow,
    StackOverflow,
    StackMismatch,
    InvalidOpcode,
    InvalidFinalArtifact,
    BytecodeOverflow,
    ReachableFalloff,
    OutOfMemory,
};

/// Extra production-artifact proof fused into the stack-size walk. The
/// atom ledger is ordered by physical instruction position, so its cursor
/// remains linear even though stack propagation follows the control-flow
/// graph. Whenever the graph walk reaches that linear frontier, both
/// proofs consume the same opcode metadata lookup.
pub const FinalArtifactValidation = struct {
    atom_owners: []const atom.Atom,
    closure_var_count: usize,
};

/// Options for the BFS.
pub const Options = struct {
    /// Fallback owner for verifier scratch that exceeds the small-function
    /// stack budget. The default preserves the standalone verifier API;
    /// production finalization supplies the runtime-accounted allocator.
    scratch_allocator: std.mem.Allocator = std.heap.page_allocator,

    /// When non-null, receives the return-balance proof: true iff every
    /// reachable `return` / `return_undef` terminator completes with an
    /// EMPTY operand stack once the return value is popped. The parser
    /// elides trailing expression-statement drops and keeps switch
    /// discriminants live across `return` (qjs releases both in the done:
    /// local_buf..sp loop, quickjs.c), so this is a
    /// per-return-site fact, not a validity check: `compute` still
    /// succeeds for unbalanced functions. Sole consumer is the zero-arg
    /// empty-leaf publication gate in final execution-flag publication, whose
    /// normal-return arm runs a narrow epilogue with no operand-release
    /// loop. Piggybacks on this BFS because the per-pc levels here are
    /// exact (`seed` rejects any pc revisited at a different level), so
    /// branchy-but-balanced bodies keep their proof — a linear scan would
    /// have to refuse them conservatively.
    returns_balanced_out: ?*bool = null,

    /// Packed-finalize-only validation. Standalone stack-size callers leave
    /// this null because their producing pipeline retains its own output
    /// proof.
    final_artifact: ?FinalArtifactValidation = null,
};

const FinalArtifactValidator = struct {
    config: FinalArtifactValidation,
    pc: usize = 0,
    owner_index: usize = 0,

    /// F0b: driven by the decoded header. The operand kinds carry what
    /// this used to rediscover from the format, and the two closure-slot
    /// arms collapse into one -- a `var_ref_slot` is a `var_ref_slot`
    /// whether its value sits in a payload byte or in the opcode.
    ///
    /// The arm that went away is the one P0-2 rules out by name: the old
    /// `none_var_ref` case recovered the slot as `op_id - get_var_ref0`,
    /// deriving a semantic operand from the physical id. That derivation
    /// loses its definition the moment an id is aliased or moved behind a
    /// carrier, which is exactly what this work does to ids.
    /// `inline` is load-bearing, not a hint. The unmigrated validator was
    /// small enough that LLVM inlined it into both walkers; the migrated
    /// one is not, and the per-instruction call was measured at 72M
    /// instructions on the CodeLoad compile path (2026-08-28).
    inline fn validateKnownInstruction(
        self: *FinalArtifactValidator,
        bytecode: []const u8,
        h: opcode.decode.Header,
    ) Error!void {
        const size: usize = h.size;
        if (size == 0 or size > bytecode.len - self.pc)
            return error.InvalidFinalArtifact;

        // C0 / D7: a carrier tag outside the accepted set -- a
        // resident's slot or the add range -- must fail the artifact
        // proof rather than reach dispatch. The add range's hint
        // values have their own authority (DisposalHint) and stay the
        // executor's check, as before.
        if (h.form == .ext0) {
            const tag = opcode.decode.operandAt(h, bytecode, 0, u8) catch
                return error.InvalidFinalArtifact;
            if (opcode.logical.subForm(tag) == null and !opcode.ext0_sub.isAdd(tag))
                return error.InvalidFinalArtifact;
        }

        const lay = h.layout();
        if (lay.atom_slot) |i| {
            if (self.owner_index >= self.config.atom_owners.len)
                return error.InvalidFinalArtifact;
            const encoded = opcode.decode.operandAt(h, bytecode, i, u32) catch
                return error.InvalidFinalArtifact;
            if (atom.Atom.fromRaw(encoded) != self.config.atom_owners[self.owner_index])
                return error.InvalidFinalArtifact;
            self.owner_index += 1;
        }
        if (lay.var_ref_slot) |i| {
            const idx = opcode.decode.operandAt(h, bytecode, i, u32) catch
                return error.InvalidFinalArtifact;
            if (idx >= self.config.closure_var_count)
                return error.InvalidFinalArtifact;
        }
        self.pc += size;
    }

    /// F0b behaviour change, deliberate: `headerAt` rejects an id that
    /// the ledger says is reclaimed, where the old metadata lookup would
    /// hand back the `unused_N` row and walk it as a one-byte
    /// instruction. A reclaimed id must never appear in a final artifact
    /// (11.5 clause 2), so failing validation is the correct reading; the
    /// old path could have let one through.
    ///
    /// Validate physical instructions before `limit`. Overshooting `limit`
    /// is intentional: a malformed jump into an operand remains the stack
    /// verifier's diagnosis, while the linear proof still consumes the
    /// containing instruction exactly once as before this fusion.
    fn validateBefore(
        self: *FinalArtifactValidator,
        bytecode: []const u8,
        limit: usize,
    ) Error!void {
        while (self.pc < limit) {
            const h = opcode.decode.headerAt(.final, bytecode, @intCast(self.pc)) catch
                return error.InvalidFinalArtifact;
            try self.validateKnownInstruction(bytecode, h);
        }
    }

    fn finish(self: *FinalArtifactValidator, bytecode: []const u8) Error!void {
        try self.validateBefore(bytecode, bytecode.len);
        if (self.pc != bytecode.len or self.owner_index != self.config.atom_owners.len)
            return error.InvalidFinalArtifact;
    }
};

/// Compute the maximum stack size required to execute `bytecode`.
///
/// Rejects empty bytecode and every reachable fall-through past the final
/// instruction: finalized production bodies must end in an explicit
/// terminator on every path.
pub fn compute(bytecode: []const u8, options: Options) Error!u16 {
    if (options.returns_balanced_out) |out| out.* = true;
    if (bytecode.len == 0) return error.ReachableFalloff;

    // MultiArrayList stores these fields as one tightly packed SoA owner:
    // 2 + 4 + 4 bytes per bytecode position. Check the exact allocation
    // arithmetic before initCapacity performs its unchecked multiply.
    _ = std.math.mul(usize, scratch_bytes_per_position, bytecode.len) catch
        return error.OutOfMemory;

    var stack_fallback = std.heap.stackFallback(stack_scratch_bytes, options.scratch_allocator);
    const scratch_allocator = stack_fallback.get();
    var scratch = try std.MultiArrayList(ScratchRow).initCapacity(scratch_allocator, bytecode.len);
    defer scratch.deinit(scratch_allocator);
    scratch.len = bytecode.len;
    const scratch_slices = scratch.slice();

    const stack_level_tab = scratch_slices.items(.stack_level);
    bulk_memory.fillByte(std.mem.sliceAsBytes(stack_level_tab), 0xff);
    const catch_pos_tab = scratch_slices.items(.catch_pos);
    // Match QuickJS compute_stack_size: catch_pos_tab does not need a
    // sentinel fill. `seed` publishes catch_pos before it publishes the pc
    // to pending_pc, and every later read is guarded by a visited
    // stack_level_tab entry.
    const pending_pc = scratch_slices.items(.pending_pc);
    var pending_len: usize = 0;
    var final_validator: ?FinalArtifactValidator = if (options.final_artifact) |config|
        .{ .config = config }
    else
        null;
    // Before this proof was fused, the stack verifier completed first and
    // the artifact walk ran only after it succeeded.  Keep that public
    // error priority: an artifact mismatch is remembered while the graph
    // walk continues, then reported only if the stack proof succeeds.
    var final_artifact_invalid = false;

    // Seed: entry pc=0 with stack level 0.
    try seed(stack_level_tab, catch_pos_tab, pending_pc, &pending_len, 0, 0, -1);

    var stack_len_max: u16 = 0;

    while (pending_len != 0) {
        pending_len -= 1;
        const pos = pending_pc[pending_len];
        var stack_len = stack_level_tab[pos];
        var catch_pos = catch_pos_tab[pos];
        // F0b: one structured decode per instruction. Nothing below reads
        // a payload byte by hand, and the control-flow switch keys on the
        // logical form rather than the physical id -- which is the point:
        // a reclaimed or re-encoded id must not silently change what this
        // pass believes an instruction is.
        const h = opcode.decode.headerAt(.final, bytecode, pos) catch |err| switch (err) {
            error.InvalidOpcode => return error.InvalidOpcode,
            error.BytecodeOverflow => return error.BytecodeOverflow,
        };
        if (!final_artifact_invalid) {
            if (final_validator) |*validator| {
                validator.validateBefore(bytecode, pos) catch |err| switch (err) {
                    error.InvalidFinalArtifact => final_artifact_invalid = true,
                    else => return err,
                };
            }
        }
        if (h.form == .invalid) return error.InvalidOpcode;
        // Both proofs now share the one decoded header instead of a
        // separately looked-up metadata row.
        const pos_next = h.next_pc();

        // Effects come from the declaration, not from a format switch
        // here. `npop`, `npop_u16` and `none_npop` (call0..3, whose count is
        // burned into the opcode) all evaluate the same affine
        // expression, and `using`/`dyn_env_probe` read their operand
        // table -- the three special cases this pass used to carry are
        // now one call.
        const effect = opcode.decode.stackEffect(h, bytecode) catch |err| switch (err) {
            error.InvalidOpcode => return error.InvalidOpcode,
            error.BytecodeOverflow => return error.BytecodeOverflow,
        };
        const n_pop: u32 = effect.pop;
        const n_push: u32 = effect.push;
        // Two opcodes carry their stack effect in an operand byte instead
        // of the table: the `using` cold plane's sub-opcode, and
        // `dyn_env_probe`'s kind.
        var dyn_env_flags: ?opcode.dyn_env.Flags = null;
        // Only the branch edge still needs the decoded flags; the
        // fall-through effect already came from `stackEffect`.
        if (h.form == .dyn_env_probe) {
            const raw = opcode.decode.operandAt(h, bytecode, 2, u8) catch
                return error.BytecodeOverflow;
            dyn_env_flags = opcode.dyn_env.decode(raw) orelse return error.InvalidOpcode;
        }

        if (stack_len < n_pop) {
            return error.StackUnderflow;
        }
        const new_stack_i32: i32 = @as(i32, stack_len) - @as(i32, @intCast(n_pop)) + @as(i32, @intCast(n_push));
        if (new_stack_i32 < 0) return error.StackUnderflow;
        if (new_stack_i32 > JS_STACK_SIZE_MAX) return error.StackOverflow;
        stack_len = @intCast(new_stack_i32);
        if (stack_len > stack_len_max) stack_len_max = stack_len;

        if (!final_artifact_invalid) {
            if (final_validator) |*validator| {
                if (validator.pc == pos) {
                    validator.validateKnownInstruction(bytecode, h) catch |err| switch (err) {
                        error.InvalidFinalArtifact => final_artifact_invalid = true,
                        else => return err,
                    };
                }
            }
        }

        // QuickJS dispatches directly on the numeric opcode. Apart from
        // avoiding string comparisons, this keeps all control-flow
        // classification auditable against compute_stack_size's switch.
        switch (h.form) {
            .@"return", .return_undef => {
                // `stack_len` already includes the return-value pop.
                if (stack_len != 0) {
                    if (options.returns_balanced_out) |out| out.* = false;
                }
                continue;
            },
            .return_async,
            .throw,
            .throw_error,
            .tail_call,
            .tail_call_method,
            .ret,
            => continue,
            .goto, .goto16, .goto8 => {
                const target = try opcode.decode.targetOfLabel(h, bytecode, 0);
                try seed(stack_level_tab, catch_pos_tab, pending_pc, &pending_len, target, stack_len, catch_pos);
                continue;
            },
            .if_true, .if_false, .if_true8, .if_false8 => {
                const target = try opcode.decode.targetOfLabel(h, bytecode, 0);
                try seed(stack_level_tab, catch_pos_tab, pending_pc, &pending_len, target, stack_len, catch_pos);
            },
            .gosub => {
                const target = try opcode.decode.targetOfLabel(h, bytecode, 0);
                try seed(stack_level_tab, catch_pos_tab, pending_pc, &pending_len, target, stack_len + 1, catch_pos);
            },
            .dyn_env_probe => {
                const target = try opcode.decode.targetOfLabel(h, bytecode, 1);
                const delta = (dyn_env_flags orelse return error.InvalidOpcode).branchStackDelta();
                const branch_level = @as(i32, stack_len) + delta;
                if (branch_level < 0) return error.StackUnderflow;
                if (branch_level > JS_STACK_SIZE_MAX) return error.StackOverflow;
                try seed(stack_level_tab, catch_pos_tab, pending_pc, &pending_len, target, @intCast(branch_level), catch_pos);
            },
            .@"catch" => {
                const target = try opcode.decode.targetOfLabel(h, bytecode, 0);
                try seed(stack_level_tab, catch_pos_tab, pending_pc, &pending_len, target, stack_len, catch_pos);
                catch_pos = @intCast(pos);
            },
            .for_of_start, .for_await_of_start => catch_pos = @intCast(pos),
            .drop, .nip, .iterator_close => {
                const catch_level = switch (h.form) {
                    .iterator_close => stack_len + 2,
                    .nip => blk: {
                        if (stack_len == 0) return error.StackUnderflow;
                        break :blk stack_len - 1;
                    },
                    else => stack_len,
                };
                catch_pos = maybePopCatchPos(bytecode, stack_level_tab, catch_pos_tab, catch_pos, catch_level);
            },
            .nip_catch => {
                if (catch_pos < 0) return error.InvalidOpcode;
                const catch_idx: usize = @intCast(catch_pos);
                stack_len = stack_level_tab[catch_idx];
                if (!opcode.decode.matchesFormAt(bytecode, @intCast(catch_idx), .@"catch")) stack_len += 1;
                stack_len += 1;
                catch_pos = catch_pos_tab[catch_idx];
            },
            else => {},
        }

        // Fall-through.
        try seed(stack_level_tab, catch_pos_tab, pending_pc, &pending_len, pos_next, stack_len, catch_pos);
    }

    if (!final_artifact_invalid) {
        if (final_validator) |*validator| {
            validator.finish(bytecode) catch |err| switch (err) {
                error.InvalidFinalArtifact => final_artifact_invalid = true,
                else => return err,
            };
        }
    }
    if (final_artifact_invalid) return error.InvalidFinalArtifact;
    return stack_len_max;
}

fn seed(
    stack_level_tab: []u16,
    catch_pos_tab: []i32,
    pending_pc: []u32,
    pending_len: *usize,
    pos: u32,
    stack_len: u16,
    catch_pos: i32,
) Error!void {
    if (pos == stack_level_tab.len) return error.ReachableFalloff;
    if (pos > stack_level_tab.len) return error.BytecodeOverflow;
    const existing = stack_level_tab[pos];
    if (existing == STACK_LEVEL_UNVISITED) {
        stack_level_tab[pos] = stack_len;
        catch_pos_tab[pos] = catch_pos;
        std.debug.assert(pending_len.* < pending_pc.len);
        pending_pc[pending_len.*] = pos;
        pending_len.* += 1;
    } else if (existing != stack_len) {
        return error.StackMismatch;
    } else if (catch_pos_tab[pos] != catch_pos) {
        return error.StackMismatch;
    }
}

fn maybePopCatchPos(bytecode: []const u8, stack_level_tab: []const u16, catch_pos_tab: []const i32, catch_pos: i32, catch_level: u16) i32 {
    if (catch_pos < 0) return catch_pos;
    const catch_idx: usize = @intCast(catch_pos);
    var level = stack_level_tab[catch_idx];
    if (bytecode[catch_idx] != opcode.op.@"catch") level += 1;
    if (catch_level == level) return catch_pos_tab[catch_idx];
    return catch_pos;
}

test "stack_size: empty bytecode is reachable falloff" {
    try std.testing.expectError(error.ReachableFalloff, compute(&.{}, .{}));
}

test "stack_size: fused final artifact proof accepts owners and var refs" {
    const owned_atom: u32 = 700;
    var bc = [_]u8{0} ** 10;
    bc[0] = opcode.op.push_atom_value;
    std.mem.writeInt(u32, bc[1..5], owned_atom, .little);
    bc[5] = opcode.op.drop;
    bc[6] = opcode.op.get_var_ref;
    std.mem.writeInt(u16, bc[7..9], 0, .little);
    bc[9] = opcode.op.@"return";

    try std.testing.expectEqual(@as(u16, 1), try compute(&bc, .{
        .final_artifact = .{
            .atom_owners = &.{atom.Atom.fromRaw(owned_atom)},
            .closure_var_count = 1,
        },
    }));
}

test "stack_size: fused final artifact proof validates unreachable tail" {
    const encoded_atom: u32 = 701;
    const wrong_owner: u32 = 702;
    var bc = [_]u8{0} ** 6;
    bc[0] = opcode.op.return_undef;
    bc[1] = opcode.op.push_atom_value;
    std.mem.writeInt(u32, bc[2..6], encoded_atom, .little);

    try std.testing.expectError(error.InvalidFinalArtifact, compute(&bc, .{
        .final_artifact = .{
            .atom_owners = &.{atom.Atom.fromRaw(wrong_owner)},
            .closure_var_count = 0,
        },
    }));
}

test "stack_size: fused final artifact proof rejects wide and short var refs" {
    var wide = [_]u8{ opcode.op.get_var_ref, 1, 0, opcode.op.@"return" };
    try std.testing.expectError(error.InvalidFinalArtifact, compute(&wide, .{
        .final_artifact = .{ .atom_owners = &.{}, .closure_var_count = 1 },
    }));

    const short = [_]u8{ opcode.op.get_var_ref1, opcode.op.@"return" };
    try std.testing.expectError(error.InvalidFinalArtifact, compute(&short, .{
        .final_artifact = .{ .atom_owners = &.{}, .closure_var_count = 1 },
    }));
}

test "stack_size: fused final artifact proof preserves stack diagnostic priority" {
    const invalid_opcode = [_]u8{0xff};
    try std.testing.expectError(error.InvalidOpcode, compute(&invalid_opcode, .{
        .final_artifact = .{ .atom_owners = &.{}, .closure_var_count = 0 },
    }));

    const truncated_atom = [_]u8{opcode.op.push_atom_value};
    try std.testing.expectError(error.BytecodeOverflow, compute(&truncated_atom, .{
        .final_artifact = .{ .atom_owners = &.{}, .closure_var_count = 0 },
    }));

    const invalid_var_ref_with_underflow = [_]u8{
        opcode.op.put_var_ref,
        0,
        0,
        opcode.op.return_undef,
    };
    try std.testing.expectError(error.StackUnderflow, compute(&invalid_var_ref_with_underflow, .{
        .final_artifact = .{ .atom_owners = &.{}, .closure_var_count = 0 },
    }));

    const encoded_atom: u32 = 703;
    const wrong_owner: u32 = 704;
    var earlier_artifact_mismatch = [_]u8{0} ** 8;
    earlier_artifact_mismatch[0] = opcode.op.push_atom_value;
    std.mem.writeInt(u32, earlier_artifact_mismatch[1..5], encoded_atom, .little);
    earlier_artifact_mismatch[5] = opcode.op.drop;
    earlier_artifact_mismatch[6] = opcode.op.drop;
    earlier_artifact_mismatch[7] = opcode.op.return_undef;
    try std.testing.expectError(error.StackUnderflow, compute(&earlier_artifact_mismatch, .{
        .final_artifact = .{ .atom_owners = &.{atom.Atom.fromRaw(wrong_owner)}, .closure_var_count = 0 },
    }));
}

test "stack_size: simple push + return_undef gives stack=1" {
    const op = opcode.op;

    // push_i32 <42> ; return_undef
    var bc = [_]u8{0} ** 6;
    bc[0] = op.push_i32;
    std.mem.writeInt(i32, bc[1..5], 42, .little);
    bc[5] = op.return_undef;

    const result = try compute(&bc, .{});
    try std.testing.expectEqual(@as(u16, 1), result);
}

test "stack_size: push push add return gives stack=2" {
    const op = opcode.op;

    // push_i32 1 ; push_i32 2 ; add ; return_undef
    var bc = [_]u8{0} ** 12;
    bc[0] = op.push_i32;
    std.mem.writeInt(i32, bc[1..5], 1, .little);
    bc[5] = op.push_i32;
    std.mem.writeInt(i32, bc[6..10], 2, .little);
    bc[10] = op.add;
    bc[11] = op.return_undef;

    const result = try compute(&bc, .{});
    try std.testing.expectEqual(@as(u16, 2), result);
}

test "stack_size: stack underflow detected" {
    const op = opcode.op;

    // drop without anything on the stack → underflow.
    const bc = [_]u8{ op.drop, op.return_undef };
    const result = compute(&bc, .{});
    try std.testing.expectError(error.StackUnderflow, result);
}

test "stack_size: relative goto explored" {
    const op = opcode.op;

    // push_i32 7 ; goto +1 (skip drop) ; drop ; return_undef
    // Layout (pc): 0: push_i32, 5: goto, 10: drop, 11: return_undef.
    // Goto operand at pc+1 = 6, target = pos + 1 + diff. We want to
    // reach pc=11, so diff = 11 - (5 + 1) = 5.
    var bc = [_]u8{0} ** 12;
    bc[0] = op.push_i32;
    std.mem.writeInt(i32, bc[1..5], 7, .little);
    bc[5] = op.goto;
    std.mem.writeInt(i32, bc[6..10], 5, .little);
    bc[10] = op.drop; // skipped by goto
    bc[11] = op.return_undef;

    const result = try compute(&bc, .{});
    // The drop is unreachable, so max stack = 1 (push_i32) and no underflow.
    try std.testing.expectEqual(@as(u16, 1), result);
}

test "stack_size: catch handler edge contributes to max stack" {
    const op = opcode.op;

    // catch +5 (handler at pc=6) ; return_undef ; push_i32 9 ; return_undef
    // The normal fallthrough only reaches stack depth 1 from the catch marker.
    // The exception edge reaches the handler with the thrown value on the
    // stack, then push_i32 raises the required max stack to 2.
    var bc = [_]u8{0} ** 12;
    bc[0] = op.@"catch";
    std.mem.writeInt(i32, bc[1..5], 5, .little);
    bc[5] = op.return_undef;
    bc[6] = op.push_i32;
    std.mem.writeInt(i32, bc[7..11], 9, .little);
    bc[11] = op.return_undef;

    const result = try compute(&bc, .{});
    try std.testing.expectEqual(@as(u16, 2), result);
}

test "stack_size: indexed method call QuickJS shape is strict-computable" {
    const op = opcode.op;

    // get_var obj ; get_var key ; get_array_el2 ; get_var arg ; call_method 1 idx ; drop ; return_undef
    var bc = [_]u8{0} ** 15;
    bc[0] = op.get_var;
    std.mem.writeInt(u16, bc[1..3], 0, .little);
    bc[3] = op.get_var;
    std.mem.writeInt(u16, bc[4..6], 1, .little);
    bc[6] = op.get_array_el2;
    bc[7] = op.get_var;
    std.mem.writeInt(u16, bc[8..10], 2, .little);
    bc[10] = op.call_method;
    std.mem.writeInt(u16, bc[11..13], 1, .little);
    bc[13] = op.drop;
    bc[14] = op.return_undef;

    const result = try compute(&bc, .{});
    try std.testing.expectEqual(@as(u16, 3), result);
}

test "stack_size: indexed compound assignment QuickJS shape is strict-computable" {
    const op = opcode.op;

    // get_var obj ; get_var key ; get_array_el3 ;
    // get_var rhs ; add ; insert3 ; put_array_el ; undefined ; return
    var bc = [_]u8{0} ** 15;
    bc[0] = op.get_var;
    std.mem.writeInt(u16, bc[1..3], 0, .little);
    bc[3] = op.get_var;
    std.mem.writeInt(u16, bc[4..6], 1, .little);
    bc[6] = op.get_array_el3;
    bc[7] = op.get_var;
    std.mem.writeInt(u16, bc[8..10], 2, .little);
    bc[10] = op.add;
    bc[11] = op.insert3;
    bc[12] = op.put_array_el;
    bc[13] = op.undefined;
    bc[14] = op.@"return";

    const result = try compute(&bc, .{});
    try std.testing.expectEqual(@as(u16, 4), result);
}

test "stack_size: regexp literal QuickJS shape is strict-computable" {
    const op = opcode.op;

    // push_atom_value "a" ; push_const compiled_bytecode ; regexp ; return_undef
    var bc = [_]u8{0} ** 12;
    bc[0] = op.push_atom_value;
    bc[5] = op.push_const;
    bc[10] = op.regexp;
    bc[11] = op.return_undef;

    const result = try compute(&bc, .{});
    try std.testing.expectEqual(@as(u16, 2), result);
}

test "stack_size: bare new expression QuickJS shape is strict-computable" {
    const op = opcode.op;

    // get_var X ; dup ; call_constructor 0 ; drop ; return_undef
    var bc = [_]u8{0} ** 9;
    bc[0] = op.get_var;
    std.mem.writeInt(u16, bc[1..3], 0, .little);
    bc[3] = op.dup;
    bc[4] = op.call_constructor;
    std.mem.writeInt(u16, bc[5..7], 0, .little);
    bc[7] = op.drop;
    bc[8] = op.return_undef;

    const result = try compute(&bc, .{});
    try std.testing.expectEqual(@as(u16, 2), result);
}

test "stack_size: super method call shape is strict-computable" {
    const op = opcode.op;

    // push_this ; special_object home ; get_super ; push_atom_value x ;
    // get_array_el ; tail_call_method 0 idx
    var bc = [_]u8{0} ** 16;
    bc[0] = op.push_this;
    bc[1] = op.special_object;
    bc[2] = 4;
    bc[3] = op.get_super;
    bc[4] = op.push_atom_value;
    bc[9] = op.get_array_el;
    bc[10] = op.tail_call_method;
    std.mem.writeInt(u16, bc[11..13], 0, .little);
    bc[13] = 255;

    const result = try compute(bc[0..14], .{});
    try std.testing.expectEqual(@as(u16, 3), result);
}

test "stack_size: super property value shape is strict-computable" {
    const op = opcode.op;

    // push_this ; special_object home ; get_super ; push_atom_value x ;
    // get_super_value ; return
    var bc = [_]u8{0} ** 12;
    bc[0] = op.push_this;
    bc[1] = op.special_object;
    bc[2] = 4;
    bc[3] = op.get_super;
    bc[4] = op.push_atom_value;
    bc[9] = op.get_super_value;
    bc[10] = op.@"return";

    const result = try compute(bc[0..11], .{});
    try std.testing.expectEqual(@as(u16, 3), result);
}

test "stack_size: base class declaration QuickJS shape is strict-computable" {
    const op = opcode.op;

    // set_loc_uninitialized C ; undefined ; set_loc_uninitialized <class_fields_init> ;
    // push_const ctor ; define_class ; undefined ; put_loc fields ; drop ;
    // set_loc C ; close_loc fields ; put_var_ref C ; return_undef
    var bc = [_]u8{0} ** 35;
    bc[0] = op.set_loc_uninitialized;
    std.mem.writeInt(u16, bc[1..3], 0, .little);
    bc[3] = op.undefined;
    bc[4] = op.set_loc_uninitialized;
    std.mem.writeInt(u16, bc[5..7], 1, .little);
    bc[7] = op.push_const;
    bc[12] = op.define_class;
    bc[18] = op.undefined;
    bc[19] = op.put_loc;
    std.mem.writeInt(u16, bc[20..22], 1, .little);
    bc[22] = op.drop;
    bc[23] = op.set_loc;
    std.mem.writeInt(u16, bc[24..26], 0, .little);
    bc[26] = op.close_loc;
    std.mem.writeInt(u16, bc[27..29], 1, .little);
    bc[29] = op.put_var_ref;
    std.mem.writeInt(u16, bc[30..32], 0, .little);
    bc[32] = op.return_undef;

    const result = try compute(bc[0..33], .{});
    try std.testing.expectEqual(@as(u16, 3), result);
}

test "stack_size: default derived constructor QuickJS shape is strict-computable" {
    const op = opcode.op;

    // set_loc_uninitialized this ; init_ctor ; put_loc_check_init this ;
    // get_var_ref_check <class_fields_init> ; dup ; if_false8 9 ;
    // get_loc_check this ; swap ; call_method 0 idx ; drop ;
    // get_loc_checkthis this ; return
    var bc = [_]u8{0} ** 25;
    bc[0] = op.set_loc_uninitialized;
    std.mem.writeInt(u16, bc[1..3], 0, .little);
    bc[3] = op.init_ctor;
    bc[4] = op.put_loc_check_init;
    std.mem.writeInt(u16, bc[5..7], 0, .little);
    bc[7] = op.get_var_ref_check;
    std.mem.writeInt(u16, bc[8..10], 0, .little);
    bc[10] = op.dup;
    bc[11] = op.if_false8;
    bc[12] = 8;
    bc[13] = op.get_loc_check;
    std.mem.writeInt(u16, bc[14..16], 0, .little);
    bc[16] = op.swap;
    bc[17] = op.call_method;
    std.mem.writeInt(u16, bc[18..20], 0, .little);
    bc[20] = op.drop;
    bc[21] = op.get_loc_checkthis;
    std.mem.writeInt(u16, bc[22..24], 0, .little);
    bc[24] = op.@"return";

    const result = try compute(&bc, .{});
    try std.testing.expectEqual(@as(u16, 2), result);
}

test "stack_size: for-of iterator close catch position is strict-computable" {
    const op = opcode.op;

    // array_from 0 ; for_of_start ; goto next ; body: put_loc0 ; goto next ;
    // exit: drop ; iterator_close ; return_undef ;
    // next: for_of_next 0 ; if_false body ; drop ; iterator_close ; return_undef
    var bc = [_]u8{0} ** 19;
    bc[0] = op.array_from;
    std.mem.writeInt(u16, bc[1..3], 0, .little);
    bc[3] = op.for_of_start;
    bc[4] = op.goto8;
    bc[5] = 7;
    bc[6] = op.put_loc0;
    bc[7] = op.goto8;
    bc[8] = 4;
    bc[9] = op.drop;
    bc[10] = op.iterator_close;
    bc[11] = op.return_undef;
    bc[12] = op.for_of_next;
    bc[13] = 0;
    bc[14] = op.if_false8;
    bc[15] = @bitCast(@as(i8, -9));
    bc[16] = op.drop;
    bc[17] = op.iterator_close;
    bc[18] = op.return_undef;

    const result = try compute(&bc, .{});
    try std.testing.expectEqual(@as(u16, 5), result);
}
