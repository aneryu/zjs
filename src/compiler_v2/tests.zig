const std = @import("std");
const build_options = @import("build_options");
const config_signature = @import("../config_signature.zig");
const core = @import("../core/root.zig");
const parser_mod = @import("../parser.zig");
const bytecode_mod = @import("../bytecode.zig");
const zjs_vm = @import("../exec/zjs_vm.zig");
const object_ops = @import("../exec/object_ops.zig");
const stack_mod = @import("../exec/stack.zig");
const standard_globals = @import("../exec/standard_globals.zig");
const builder_mod = @import("builder.zig");
const coverage = @import("coverage.zig");
const labels = @import("labels.zig");
const resolve_labels = @import("resolve_labels.zig");
const resolve_variables = @import("resolve_variables.zig");
const test_entry = @import("test_entry.zig");
const P = parser_mod.Parser;
const opcode = bytecode_mod.opcode;
const qop = bytecode_mod.opcode.op;

const V2Parse = struct {
    rt: *core.JSRuntime,
    name_atom: core.atom.Atom,
    function: bytecode_mod.Bytecode,
    lex: parser_mod.Lexer,
    state: P.ParseState,

    /// `h` must be a stack local (`var h: V2Parse = undefined;`).
    fn init(h: *V2Parse, src: []const u8) !void {
        h.rt = try core.JSRuntime.create(std.testing.allocator);
        errdefer h.rt.destroy();
        h.name_atom = try h.rt.atoms.internString("s2g1");
        errdefer h.rt.atoms.free(h.name_atom);
        h.function = bytecode_mod.Bytecode.init(&h.rt.memory, &h.rt.atoms, h.name_atom);
        errdefer h.function.deinit(h.rt);
        h.lex = parser_mod.Lexer.init(std.testing.allocator, &h.rt.atoms, src);
        h.state = try P.ParseState.init(&h.lex, &h.function);
        // Scope events (enter_scope/leave_scope) belong to the un-migrated
        // scope group; the S2-G1 harness parses without phase-1 temp scope
        // markers so statement snippets stay inside the migrated surface.
        h.state.emit_phase1_temp = false;
        try h.state.beginV2EmissionForTest();
    }

    fn builder(h: *V2Parse) *builder_mod.Builder {
        return h.state.function_def.v2_builder.?;
    }

    fn childBuilder(h: *V2Parse, index: usize) *builder_mod.Builder {
        return h.state.function_def.child_list[index].v2_builder.?;
    }

    fn grandchildBuilder(h: *V2Parse, index: usize, sub: usize) *builder_mod.Builder {
        return h.state.function_def.child_list[index].child_list[sub].v2_builder.?;
    }

    fn deinit(h: *V2Parse) void {
        h.state.deinit(h.rt);
        h.function.deinit(h.rt);
        h.rt.atoms.free(h.name_atom);
        h.rt.destroy();
    }
};

const LegacyParse = struct {
    rt: *core.JSRuntime,
    name_atom: core.atom.Atom,
    function: bytecode_mod.Bytecode,
    lex: parser_mod.Lexer,
    state: P.ParseState,

    /// Parse through the ordinary phase-1 emitter. Unlike V2Parse, this keeps
    /// source markers and scope temporary opcodes and emits the root stream to
    /// function.code; nested functions own their FunctionDef.byte_code stream.
    fn init(h: *LegacyParse, src: []const u8) !void {
        h.rt = try core.JSRuntime.create(std.testing.allocator);
        errdefer h.rt.destroy();
        h.name_atom = try h.rt.atoms.internString("compiler_v2-s3-equivalence");
        errdefer h.rt.atoms.free(h.name_atom);
        h.function = bytecode_mod.Bytecode.init(&h.rt.memory, &h.rt.atoms, h.name_atom);
        errdefer h.function.deinit(h.rt);
        h.lex = parser_mod.Lexer.init(std.testing.allocator, &h.rt.atoms, src);
        h.state = try P.ParseState.init(&h.lex, &h.function);
        // The seed models a script-global var environment while deliberately
        // leaving is_eval false so top-level let/const remain local TDZ slots.
        h.state.function_def.is_global_var = true;
    }

    fn parseProgram(h: *LegacyParse, capture_top_level_functions: bool) !void {
        h.state.top_level_functions_as_children = capture_top_level_functions;
        try P.parseProgramStatements(
            &h.state,
            P.DeclMask{ .func = true, .func_with_label = true, .other = true },
        );
        try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);
    }

    fn deinit(h: *LegacyParse) void {
        h.state.deinit(h.rt);
        h.function.deinit(h.rt);
        h.rt.atoms.free(h.name_atom);
        h.rt.destroy();
    }
};

const V2Exec = struct {
    rt: *core.JSRuntime,
    ctx: *core.JSContext,
    name_atom: core.atom.Atom,
    function: bytecode_mod.Bytecode,
    lex: parser_mod.Lexer,
    state: P.ParseState,
    installed_short_opcode: bool,

    /// `h` must be a stack local (`var h: V2Exec = undefined;`).
    fn init(h: *V2Exec, src: []const u8) !void {
        h.rt = try core.JSRuntime.create(std.testing.allocator);
        errdefer h.rt.destroy();
        standard_globals.configureRuntime(h.rt);
        h.ctx = try core.JSContext.create(h.rt);
        errdefer h.ctx.destroy();
        h.name_atom = try h.rt.atoms.internString("compiler_v2-s4-exec");
        errdefer h.rt.atoms.free(h.name_atom);
        h.function = bytecode_mod.Bytecode.init(&h.rt.memory, &h.rt.atoms, h.name_atom);
        errdefer h.function.deinit(h.rt);
        h.lex = parser_mod.Lexer.init(std.testing.allocator, &h.rt.atoms, src);
        errdefer h.lex.deinit();
        h.state = try P.ParseState.initCanonicalRootWithRuntime(h.rt, &h.lex, &h.function);
        h.state.function_def.is_global_var = true;
        h.state.top_level_functions_as_children = true;
        h.installed_short_opcode = false;
    }

    fn deinit(h: *V2Exec) void {
        h.state.deinit(h.rt);
        h.lex.deinit();
        h.function.deinit(h.rt);
        h.ctx.destroy();
        h.rt.atoms.free(h.name_atom);
        h.rt.destroy();
    }
};

const ExpectedInsn = struct {
    op: u8,
    size: u8,
    label: ?u32 = null,
    atom: ?core.atom.Atom = null,
};

fn expectV2Stream(b: *const builder_mod.Builder, expected: []const ExpectedInsn) !void {
    var pc: usize = 0;
    for (expected) |insn| {
        try std.testing.expect(pc < b.code_len);
        try std.testing.expectEqual(insn.op, b.code[pc]);
        if (insn.label) |label_index|
            try std.testing.expectEqual(label_index, std.mem.readInt(u32, b.code[pc + 1 ..][0..4], .little));
        if (insn.atom) |atom_id|
            try std.testing.expectEqual(atom_id, std.mem.readInt(u32, b.code[pc + 1 ..][0..4], .little));
        pc += insn.size;
    }
    try std.testing.expectEqual(@as(usize, @intCast(b.code_len)), pc);
}

fn expectResolvedStream(
    product: *const resolve_variables.ResolvedProduct,
    expected: []const ExpectedInsn,
) !void {
    var pc: usize = 0;
    for (expected) |insn| {
        try std.testing.expect(pc < product.code_len);
        try std.testing.expectEqual(insn.op, product.code[pc]);
        if (insn.label) |label_index|
            try std.testing.expectEqual(
                label_index,
                std.mem.readInt(u32, product.code[pc + 1 ..][0..4], .little),
            );
        if (insn.atom) |atom_id|
            try std.testing.expectEqual(
                atom_id,
                std.mem.readInt(u32, product.code[pc + 1 ..][0..4], .little),
            );
        pc += insn.size;
    }
    try std.testing.expectEqual(@as(usize, @intCast(product.code_len)), pc);
}

fn expectLabel(b: *const builder_mod.Builder, index: u32, ref_count: u32, bound_offset: u32) !void {
    try std.testing.expect(index < b.label_len);
    const slot = b.label_slots[index];
    try std.testing.expect(slot.flags.bound);
    try std.testing.expectEqual(ref_count, slot.ref_count);
    try std.testing.expectEqual(bound_offset, slot.bound_offset);
}

fn expectResolvedLabel(
    product: *const resolve_variables.ResolvedProduct,
    index: u32,
    ref_count: u32,
    bound_offset: u32,
) !void {
    try std.testing.expect(index < product.label_len);
    const slot = product.label_slots[index];
    try std.testing.expectEqual(ref_count, slot.ref_count);
    try std.testing.expectEqual(bound_offset, slot.bound_offset);
    try std.testing.expectEqual(bound_offset != labels.unbound, slot.flags.bound);
    try std.testing.expectEqual(labels.no_reloc, slot.first_reloc);
}

const Phase1Instruction = struct {
    size: u8,
    is_temp: bool = false,
    has_atom: bool = false,
};

fn phase1TempAtomInstructionSize(op_id: u8) ?u8 {
    return switch (op_id) {
        qop.scope_get_var_undef,
        qop.scope_get_var,
        qop.scope_put_var,
        qop.scope_delete_var,
        qop.scope_get_ref,
        qop.scope_put_var_init,
        qop.scope_get_var_checkthis,
        qop.scope_get_private_field,
        qop.scope_get_private_field2,
        qop.scope_put_private_field,
        qop.scope_in_private_field,
        => 7,
        qop.scope_make_ref => 11,
        qop.get_field_opt_chain => 5,
        else => null,
    };
}

fn phase1InstructionHasAtom(op_id: u8, is_temp: bool) bool {
    if (is_temp) return switch (op_id) {
        qop.scope_get_var_undef,
        qop.scope_get_var,
        qop.scope_put_var,
        qop.scope_delete_var,
        qop.scope_make_ref,
        qop.scope_get_ref,
        qop.scope_put_var_init,
        qop.scope_get_var_checkthis,
        qop.scope_get_private_field,
        qop.scope_get_private_field2,
        qop.scope_put_private_field,
        qop.scope_in_private_field,
        qop.get_field_opt_chain,
        => true,
        else => false,
    };

    return switch (opcode.formatOf(op_id)) {
        .atom, .atom_u8, .atom_u16, .atom_label_u8, .atom_label_u16 => true,
        else => false,
    };
}

/// Test-local twin of parserPhaseInstruction. The atom ledger disambiguates
/// phase-1 temporary ids from the overlapping final short-opcode ids.
fn decodePhase1Instruction(
    code: []const u8,
    atoms: []const core.atom.Atom,
    pc: usize,
    atom_index: usize,
) !Phase1Instruction {
    if (pc >= code.len) return error.InvalidBytecode;
    const op_id = code[pc];

    if (phase1TempAtomInstructionSize(op_id)) |temp_size| {
        if (pc + temp_size <= code.len and atom_index < atoms.len and
            std.mem.readInt(u32, code[pc + 1 ..][0..4], .little) == atoms[atom_index])
        {
            return .{ .size = temp_size, .is_temp = true, .has_atom = true };
        }
    }

    var instruction: Phase1Instruction = switch (op_id) {
        qop.enter_scope,
        qop.leave_scope,
        qop.label,
        qop.get_array_el_opt_chain,
        qop.set_class_name,
        qop.line_num,
        => .{ .size = opcode.sizeOfPhase1(op_id), .is_temp = true },
        else => .{ .size = opcode.sizeOf(op_id) },
    };
    if (instruction.size == 0 or pc + instruction.size > code.len)
        return error.InvalidBytecode;
    instruction.has_atom = phase1InstructionHasAtom(op_id, instruction.is_temp);
    return instruction;
}

fn phase1LabelOperandOffset(op_id: u8, instruction: Phase1Instruction) ?usize {
    if (instruction.is_temp) {
        if (op_id == qop.scope_make_ref) return 5;
        return null;
    }
    return switch (opcode.formatOf(op_id)) {
        .label => 1,
        .atom_label_u8, .atom_label_u16 => 5,
        else => null,
    };
}

fn u32LessThan(_: void, lhs: u32, rhs: u32) bool {
    return lhs < rhs;
}

fn translatedTargetLabel(
    targets: []const u32,
    target_labels: []const labels.LabelId,
    target_pc: u32,
) !labels.LabelId {
    if (targets.len != target_labels.len) return error.InvalidBytecode;
    var lo: usize = 0;
    var hi = targets.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (targets[mid] < target_pc)
            lo = mid + 1
        else
            hi = mid;
    }
    if (lo >= targets.len or targets[lo] != target_pc)
        return error.InvalidBytecode;
    return target_labels[lo];
}

/// Translate a real legacy parser phase-1 stream into a fresh identity-native
/// Builder. Every legacy label instruction and absolute-PC label operand is
/// mapped to a LabelId; line/label bytes disappear while binds retain their
/// exact normalized instruction boundary.
fn translatePhase1ToV2(
    b: *builder_mod.Builder,
    code: []const u8,
    atoms: []const core.atom.Atom,
) !void {
    if (b.code_len != 0 or b.atom_len != 0 or b.label_len != 0 or b.reloc_len != 0)
        return error.InvalidBytecode;

    var target_pcs: std.ArrayList(u32) = .empty;
    defer target_pcs.deinit(std.testing.allocator);

    var pc: usize = 0;
    var atom_index: usize = 0;
    while (pc < code.len) {
        const instruction = try decodePhase1Instruction(code, atoms, pc, atom_index);
        const op_id = code[pc];
        if (instruction.is_temp and op_id == qop.label) {
            try target_pcs.append(std.testing.allocator, @intCast(pc));
        }
        if (phase1LabelOperandOffset(op_id, instruction)) |operand_offset| {
            if (operand_offset + 4 > instruction.size) return error.InvalidBytecode;
            const target_pc = std.mem.readInt(u32, code[pc + operand_offset ..][0..4], .little);
            if (target_pc > code.len) return error.InvalidBytecode;
            try target_pcs.append(std.testing.allocator, target_pc);
        }
        if (instruction.has_atom) atom_index += 1;
        pc += instruction.size;
    }
    if (pc != code.len or atom_index != atoms.len) return error.InvalidBytecode;

    std.mem.sort(u32, target_pcs.items, {}, u32LessThan);
    var target_count: usize = 0;
    for (target_pcs.items) |target_pc| {
        if (target_count == 0 or target_pcs.items[target_count - 1] != target_pc) {
            target_pcs.items[target_count] = target_pc;
            target_count += 1;
        }
    }
    const targets = target_pcs.items[0..target_count];
    const target_labels = try std.testing.allocator.alloc(labels.LabelId, target_count);
    defer std.testing.allocator.free(target_labels);
    for (target_labels) |*label| label.* = try b.newLabel();

    pc = 0;
    atom_index = 0;
    var bind_cursor: usize = 0;
    while (pc < code.len) {
        while (bind_cursor < targets.len and targets[bind_cursor] == pc) : (bind_cursor += 1) {
            try b.bindLabel(target_labels[bind_cursor]);
        }
        if (bind_cursor < targets.len and targets[bind_cursor] < pc)
            return error.InvalidBytecode;

        const instruction = try decodePhase1Instruction(code, atoms, pc, atom_index);
        const op_id = code[pc];

        if (instruction.is_temp) {
            switch (op_id) {
                qop.label, qop.line_num => {},
                qop.enter_scope, qop.leave_scope => {
                    if (instruction.size != 3) return error.InvalidBytecode;
                    try b.emitOpU16(
                        op_id,
                        std.mem.readInt(u16, code[pc + 1 ..][0..2], .little),
                    );
                },
                qop.scope_get_var_undef,
                qop.scope_get_var,
                qop.scope_put_var,
                qop.scope_delete_var,
                qop.scope_get_ref,
                qop.scope_put_var_init,
                qop.scope_get_var_checkthis,
                qop.scope_get_private_field,
                qop.scope_get_private_field2,
                qop.scope_put_private_field,
                qop.scope_in_private_field,
                => {
                    if (instruction.size != 7 or atom_index >= atoms.len)
                        return error.InvalidBytecode;
                    const atom_id = atoms[atom_index];
                    if (std.mem.readInt(u32, code[pc + 1 ..][0..4], .little) != atom_id)
                        return error.InvalidBytecode;
                    try b.emitAtomOpU16Owned(
                        op_id,
                        b.atoms.dup(atom_id),
                        std.mem.readInt(u16, code[pc + 5 ..][0..2], .little),
                    );
                    atom_index += 1;
                },
                qop.scope_make_ref => {
                    if (instruction.size != 11 or atom_index >= atoms.len)
                        return error.InvalidBytecode;
                    const atom_id = atoms[atom_index];
                    if (std.mem.readInt(u32, code[pc + 1 ..][0..4], .little) != atom_id)
                        return error.InvalidBytecode;
                    const target_pc = std.mem.readInt(u32, code[pc + 5 ..][0..4], .little);
                    try b.emitScopeRefOpOwned(
                        op_id,
                        b.atoms.dup(atom_id),
                        try translatedTargetLabel(targets, target_labels, target_pc),
                        std.mem.readInt(u16, code[pc + 9 ..][0..2], .little),
                    );
                    atom_index += 1;
                },
                else => return error.NonStraightLinePhase1,
            }
            pc += instruction.size;
            continue;
        }

        const format = opcode.formatOf(op_id);
        switch (format) {
            .none, .none_int, .none_loc, .none_arg, .none_var_ref, .npopx => {
                if (instruction.size != 1) return error.InvalidBytecode;
                try b.emitOp(op_id);
            },
            .u8, .i8, .loc8, .const8 => {
                if (instruction.size != 2) return error.InvalidBytecode;
                try b.emitOpU8(op_id, code[pc + 1]);
            },
            .u16, .i16, .npop, .loc, .arg, .var_ref => {
                if (instruction.size != 3) return error.InvalidBytecode;
                try b.emitOpU16(
                    op_id,
                    std.mem.readInt(u16, code[pc + 1 ..][0..2], .little),
                );
            },
            .npop_u16, .u32, .i32, .@"const" => {
                if (instruction.size != 5) return error.InvalidBytecode;
                try b.emitOpU32(
                    op_id,
                    std.mem.readInt(u32, code[pc + 1 ..][0..4], .little),
                );
            },
            .atom, .atom_u8, .atom_u16 => {
                if (atom_index >= atoms.len) return error.InvalidBytecode;
                const atom_id = atoms[atom_index];
                if (std.mem.readInt(u32, code[pc + 1 ..][0..4], .little) != atom_id)
                    return error.InvalidBytecode;
                switch (format) {
                    .atom => {
                        if (instruction.size != 5) return error.InvalidBytecode;
                        try b.emitAtomOpOwned(op_id, b.atoms.dup(atom_id));
                    },
                    .atom_u8 => {
                        if (instruction.size != 6) return error.InvalidBytecode;
                        try b.emitAtomOpU8Owned(op_id, b.atoms.dup(atom_id), code[pc + 5]);
                    },
                    .atom_u16 => {
                        if (instruction.size != 7) return error.InvalidBytecode;
                        try b.emitAtomOpU16Owned(
                            op_id,
                            b.atoms.dup(atom_id),
                            std.mem.readInt(u16, code[pc + 5 ..][0..2], .little),
                        );
                    },
                    else => unreachable,
                }
                atom_index += 1;
            },
            .label => {
                if (instruction.size != 5) return error.InvalidBytecode;
                const target_pc = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
                try b.emitJump(
                    op_id,
                    try translatedTargetLabel(targets, target_labels, target_pc),
                );
            },
            .atom_label_u8, .atom_label_u16 => {
                if (atom_index >= atoms.len) return error.InvalidBytecode;
                const atom_id = atoms[atom_index];
                if (std.mem.readInt(u32, code[pc + 1 ..][0..4], .little) != atom_id)
                    return error.InvalidBytecode;
                const target_pc = std.mem.readInt(u32, code[pc + 5 ..][0..4], .little);
                const target_label = try translatedTargetLabel(targets, target_labels, target_pc);
                switch (format) {
                    .atom_label_u8 => {
                        if (instruction.size != 10) return error.InvalidBytecode;
                        try b.emitAtomLabelOpU8Owned(
                            op_id,
                            b.atoms.dup(atom_id),
                            target_label,
                            code[pc + 9],
                        );
                    },
                    .atom_label_u16 => {
                        if (instruction.size != 11) return error.InvalidBytecode;
                        try b.emitScopeRefOpOwned(
                            op_id,
                            b.atoms.dup(atom_id),
                            target_label,
                            std.mem.readInt(u16, code[pc + 9 ..][0..2], .little),
                        );
                    },
                    else => unreachable,
                }
                atom_index += 1;
            },
            .label8, .label16, .label_u16 => return error.NonStraightLinePhase1,
        }
        pc += instruction.size;
    }
    while (bind_cursor < targets.len and targets[bind_cursor] == code.len) : (bind_cursor += 1) {
        try b.bindLabel(target_labels[bind_cursor]);
    }
    if (bind_cursor != targets.len or atom_index != atoms.len)
        return error.InvalidBytecode;
}

fn attachTranslatedBuilder(
    fd: *bytecode_mod.function_def.FunctionDef,
    code: []const u8,
    atoms: []const core.atom.Atom,
) !void {
    try std.testing.expect(fd.v2_builder == null);
    const b = try fd.memory.create(builder_mod.Builder);
    b.* = builder_mod.Builder.init(fd.memory, fd.atoms);
    errdefer {
        b.deinit();
        fd.memory.destroy(builder_mod.Builder, b);
    }
    try translatePhase1ToV2(b, code, atoms);
    fd.v2_builder = b;
}

fn isFullPhase1JumpOp(op_id: u8) bool {
    return op_id == qop.goto or op_id == qop.if_true or
        op_id == qop.if_false or op_id == qop.@"catch" or
        op_id == qop.gosub;
}

/// Complete the legacy parser-label transaction before translation. Most
/// forward jumps are patched in place by the parser; shared exception/finally
/// labels retain parser identities until legacy resolve_variables binds them.
/// The v2 test bridge performs that same allocation-before-mutation bind so
/// translatePhase1ToV2Full still rejects any unpatched identity it receives.
fn completeLegacyParserLabels(code: []u8, atoms: []const core.atom.Atom) !void {
    if (code.len >= qop.parser_label_tag) return error.BytecodeOverflow;

    var reference_sites: std.ArrayList(usize) = .empty;
    defer reference_sites.deinit(std.testing.allocator);
    var max_label_id: u32 = 0;
    var pc: usize = 0;
    var atom_index: usize = 0;
    while (pc < code.len) {
        const instruction = try decodePhase1Instruction(code, atoms, pc, atom_index);
        const op_id = code[pc];
        if (instruction.is_temp and op_id == qop.label) {
            const id = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
            if (id > max_label_id) max_label_id = id;
        }
        if (phase1LabelOperandOffset(op_id, instruction)) |offset| {
            if (offset + 4 > instruction.size) return error.InvalidBytecode;
            const encoded = std.mem.readInt(u32, code[pc + offset ..][0..4], .little);
            if ((encoded & qop.parser_label_tag) != 0) {
                const id = encoded & ~qop.parser_label_tag;
                if (id == 0) return error.InvalidBytecode;
                if (id > max_label_id) max_label_id = id;
                try reference_sites.append(std.testing.allocator, pc + offset);
            }
        }
        if (instruction.has_atom) atom_index += 1;
        pc += instruction.size;
    }
    if (pc != code.len or atom_index != atoms.len) return error.InvalidBytecode;
    if (reference_sites.items.len == 0) return;

    const unbound = std.math.maxInt(u32);
    const targets = try std.testing.allocator.alloc(u32, @as(usize, max_label_id) + 1);
    defer std.testing.allocator.free(targets);
    @memset(targets, unbound);

    pc = 0;
    atom_index = 0;
    while (pc < code.len) {
        const instruction = try decodePhase1Instruction(code, atoms, pc, atom_index);
        const op_id = code[pc];
        if (instruction.is_temp and op_id == qop.label) {
            const id = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
            if (id != 0) {
                if (id >= targets.len or targets[id] != unbound)
                    return error.InvalidBytecode;
                targets[id] = @intCast(pc);
            }
        }
        if (instruction.has_atom) atom_index += 1;
        pc += instruction.size;
    }

    // Validate every site before publishing any absolute target.
    for (reference_sites.items) |site| {
        const encoded = std.mem.readInt(u32, code[site..][0..4], .little);
        const id = encoded & ~qop.parser_label_tag;
        if ((encoded & qop.parser_label_tag) == 0 or id >= targets.len or
            targets[id] == unbound)
        {
            return error.InvalidBytecode;
        }
    }
    for (reference_sites.items) |site| {
        const encoded = std.mem.readInt(u32, code[site..][0..4], .little);
        const id = encoded & ~qop.parser_label_tag;
        std.mem.writeInt(u32, code[site..][0..4], targets[id], .little);
    }
}

/// Translate a completed parser phase-1 stream. Parser label markers disappear;
/// their patched absolute byte offsets become builder-native LabelIds.
fn translatePhase1ToV2Full(
    b: *builder_mod.Builder,
    code: []const u8,
    atoms: []const core.atom.Atom,
) !void {
    if (b.code_len != 0 or b.atom_len != 0 or b.label_len != 0 or b.reloc_len != 0)
        return error.InvalidBytecode;

    var target_pcs: std.ArrayList(u32) = .empty;
    defer target_pcs.deinit(std.testing.allocator);

    // Pass 1 assigns one LabelId to each referenced absolute phase-1 target.
    // The raw ids carried by op.label are parser-only patching identities.
    var pc: usize = 0;
    var atom_index: usize = 0;
    while (pc < code.len) {
        const instruction = try decodePhase1Instruction(code, atoms, pc, atom_index);
        const op_id = code[pc];
        var target_pc: ?u32 = null;
        if (instruction.is_temp and op_id == qop.scope_make_ref) {
            if (instruction.size != 11) return error.InvalidBytecode;
            target_pc = std.mem.readInt(u32, code[pc + 5 ..][0..4], .little);
        } else if (!instruction.is_temp and opcode.formatOf(op_id) == .label) {
            if (!isFullPhase1JumpOp(op_id) or instruction.size != 5)
                return error.InvalidBytecode;
            target_pc = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
        }
        if (target_pc) |target| {
            if ((target & qop.parser_label_tag) != 0 or target > code.len)
                return error.InvalidBytecode;
            try target_pcs.append(std.testing.allocator, target);
        }
        if (instruction.has_atom) atom_index += 1;
        pc += instruction.size;
    }
    if (pc != code.len or atom_index != atoms.len) return error.InvalidBytecode;

    std.mem.sort(u32, target_pcs.items, {}, u32LessThan);
    var target_count: usize = 0;
    for (target_pcs.items) |target_pc| {
        if (target_count == 0 or target_pcs.items[target_count - 1] != target_pc) {
            target_pcs.items[target_count] = target_pc;
            target_count += 1;
        }
    }
    const targets = target_pcs.items[0..target_count];
    const target_labels = try std.testing.allocator.alloc(labels.LabelId, target_count);
    defer std.testing.allocator.free(target_labels);
    for (target_labels) |*label| label.* = try b.newLabel();

    // Pass 2 binds targets at the corresponding instruction boundary and
    // emits the compact v2 instruction stream.
    pc = 0;
    atom_index = 0;
    var bind_cursor: usize = 0;
    while (pc < code.len) {
        while (bind_cursor < targets.len and targets[bind_cursor] == pc) : (bind_cursor += 1) {
            try b.bindLabel(target_labels[bind_cursor]);
        }
        if (bind_cursor < targets.len and targets[bind_cursor] < pc)
            return error.InvalidBytecode;

        const instruction = try decodePhase1Instruction(code, atoms, pc, atom_index);
        const op_id = code[pc];
        if (instruction.is_temp) {
            switch (op_id) {
                // v2 source markers are exercised by resolve_labels inline
                // tests; VM execution semantics do not consume pc2line.
                qop.label, qop.line_num => {},
                qop.enter_scope, qop.leave_scope => {
                    if (instruction.size != 3) return error.InvalidBytecode;
                    try b.emitOpU16(
                        op_id,
                        std.mem.readInt(u16, code[pc + 1 ..][0..2], .little),
                    );
                },
                qop.scope_get_var_undef,
                qop.scope_get_var,
                qop.scope_put_var,
                qop.scope_delete_var,
                qop.scope_get_ref,
                qop.scope_put_var_init,
                qop.scope_get_var_checkthis,
                qop.scope_get_private_field,
                qop.scope_get_private_field2,
                qop.scope_put_private_field,
                qop.scope_in_private_field,
                => {
                    if (instruction.size != 7 or atom_index >= atoms.len)
                        return error.InvalidBytecode;
                    const atom_id = atoms[atom_index];
                    if (std.mem.readInt(u32, code[pc + 1 ..][0..4], .little) != atom_id)
                        return error.InvalidBytecode;
                    try b.emitAtomOpU16Owned(
                        op_id,
                        b.atoms.dup(atom_id),
                        std.mem.readInt(u16, code[pc + 5 ..][0..2], .little),
                    );
                    atom_index += 1;
                },
                qop.scope_make_ref => {
                    if (instruction.size != 11 or atom_index >= atoms.len)
                        return error.InvalidBytecode;
                    const atom_id = atoms[atom_index];
                    if (std.mem.readInt(u32, code[pc + 1 ..][0..4], .little) != atom_id)
                        return error.InvalidBytecode;
                    const target_pc = std.mem.readInt(u32, code[pc + 5 ..][0..4], .little);
                    if ((target_pc & qop.parser_label_tag) != 0)
                        return error.InvalidBytecode;
                    try b.emitScopeRefOpOwned(
                        op_id,
                        b.atoms.dup(atom_id),
                        try translatedTargetLabel(targets, target_labels, target_pc),
                        std.mem.readInt(u16, code[pc + 9 ..][0..2], .little),
                    );
                    atom_index += 1;
                },
                else => return error.NonStraightLinePhase1,
            }
            pc += instruction.size;
            continue;
        }

        const format = opcode.formatOf(op_id);
        switch (format) {
            .none, .none_int, .none_loc, .none_arg, .none_var_ref, .npopx => {
                if (instruction.size != 1) return error.InvalidBytecode;
                try b.emitOp(op_id);
            },
            .u8, .i8, .loc8, .const8 => {
                if (instruction.size != 2) return error.InvalidBytecode;
                try b.emitOpU8(op_id, code[pc + 1]);
            },
            .u16, .i16, .npop, .loc, .arg, .var_ref => {
                if (instruction.size != 3) return error.InvalidBytecode;
                try b.emitOpU16(
                    op_id,
                    std.mem.readInt(u16, code[pc + 1 ..][0..2], .little),
                );
            },
            .npop_u16, .u32, .i32, .@"const" => {
                if (instruction.size != 5) return error.InvalidBytecode;
                try b.emitOpU32(
                    op_id,
                    std.mem.readInt(u32, code[pc + 1 ..][0..4], .little),
                );
            },
            .atom, .atom_u8, .atom_u16 => {
                if (atom_index >= atoms.len) return error.InvalidBytecode;
                const atom_id = atoms[atom_index];
                if (std.mem.readInt(u32, code[pc + 1 ..][0..4], .little) != atom_id)
                    return error.InvalidBytecode;
                switch (format) {
                    .atom => {
                        if (instruction.size != 5) return error.InvalidBytecode;
                        try b.emitAtomOpOwned(op_id, b.atoms.dup(atom_id));
                    },
                    .atom_u8 => {
                        if (instruction.size != 6) return error.InvalidBytecode;
                        try b.emitAtomOpU8Owned(op_id, b.atoms.dup(atom_id), code[pc + 5]);
                    },
                    .atom_u16 => {
                        if (instruction.size != 7) return error.InvalidBytecode;
                        try b.emitAtomOpU16Owned(
                            op_id,
                            b.atoms.dup(atom_id),
                            std.mem.readInt(u16, code[pc + 5 ..][0..2], .little),
                        );
                    },
                    else => unreachable,
                }
                atom_index += 1;
            },
            .label => {
                if (!isFullPhase1JumpOp(op_id) or instruction.size != 5)
                    return error.InvalidBytecode;
                const target_pc = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
                if ((target_pc & qop.parser_label_tag) != 0)
                    return error.InvalidBytecode;
                try b.emitJump(
                    op_id,
                    try translatedTargetLabel(targets, target_labels, target_pc),
                );
            },
            .atom_label_u8, .atom_label_u16 => {
                if (atom_index >= atoms.len) return error.InvalidBytecode;
                const atom_id = atoms[atom_index];
                if (std.mem.readInt(u32, code[pc + 1 ..][0..4], .little) != atom_id)
                    return error.InvalidBytecode;
                const target_pc = std.mem.readInt(u32, code[pc + 5 ..][0..4], .little);
                if ((target_pc & qop.parser_label_tag) != 0)
                    return error.InvalidBytecode;
                const target_label = try translatedTargetLabel(targets, target_labels, target_pc);
                switch (format) {
                    .atom_label_u8 => {
                        if (instruction.size != 10) return error.InvalidBytecode;
                        try b.emitAtomLabelOpU8Owned(
                            op_id,
                            b.atoms.dup(atom_id),
                            target_label,
                            code[pc + 9],
                        );
                    },
                    .atom_label_u16 => {
                        if (instruction.size != 11) return error.InvalidBytecode;
                        try b.emitScopeRefOpOwned(
                            op_id,
                            b.atoms.dup(atom_id),
                            target_label,
                            std.mem.readInt(u16, code[pc + 9 ..][0..2], .little),
                        );
                    },
                    else => unreachable,
                }
                atom_index += 1;
            },
            .label8, .label16, .label_u16 => return error.NonStraightLinePhase1,
        }
        pc += instruction.size;
    }
    while (bind_cursor < targets.len and targets[bind_cursor] == code.len) : (bind_cursor += 1) {
        try b.bindLabel(target_labels[bind_cursor]);
    }
    if (bind_cursor != targets.len or atom_index != atoms.len)
        return error.InvalidBytecode;
}

fn attachTranslatedBuilderFull(
    fd: *bytecode_mod.function_def.FunctionDef,
    code: []u8,
    atoms: []const core.atom.Atom,
) !void {
    try std.testing.expect(fd.v2_builder == null);
    try completeLegacyParserLabels(code, atoms);
    const b = try fd.memory.create(builder_mod.Builder);
    b.* = builder_mod.Builder.init(fd.memory, fd.atoms);
    errdefer {
        b.deinit();
        fd.memory.destroy(builder_mod.Builder, b);
    }
    try translatePhase1ToV2Full(b, code, atoms);
    fd.v2_builder = b;
}

fn attachTranslatedBuilderTree(fd: *bytecode_mod.function_def.FunctionDef) !void {
    try attachTranslatedBuilderFull(fd, fd.byte_code, fd.atom_operands);
    for (fd.child_list) |child| try attachTranslatedBuilderTree(child);
}

fn installedFunctionHasShortOpcode(fb: *const bytecode_mod.FunctionBytecode) !bool {
    const code = fb.byteCode();
    var pc: usize = 0;
    while (pc < code.len) {
        const op_id = code[pc];
        const size: usize = opcode.sizeOf(op_id);
        if (size == 0 or size > code.len - pc) return error.InvalidBytecode;
        switch (op_id) {
            qop.goto8,
            qop.if_true8,
            qop.if_false8,
            qop.put_loc0...qop.put_loc3,
            => return true,
            else => {},
        }
        pc += size;
    }
    return false;
}

/// Parse as a completion-returning script, translate the whole FunctionDef
/// tree to v2, finalize through the production packed-FB pipeline, and execute
/// it on the VM. The returned completion value is owned by the caller.
fn v2CompileAndRun(h: *V2Exec) !core.JSValue {
    try h.state.enableReturnCompletion();
    try P.parseProgramStatements(
        &h.state,
        P.DeclMask{ .func = true, .func_with_label = true, .other = true },
    );
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);
    try h.state.finalizeEvalReturn();

    try attachTranslatedBuilderTree(&h.state.function_def);

    const fb_slice = try bytecode_mod.pipeline_finalize.createFunctionBytecode(
        &h.state.function_def,
        .{ .realm = h.ctx },
    );
    const fb = &fb_slice[0];
    var fb_value = core.JSValue.functionBytecode(&fb.header);
    var fb_value_owned = true;
    errdefer if (fb_value_owned) fb_value.free(h.rt);
    h.installed_short_opcode = try installedFunctionHasShortOpcode(fb);

    const global = try zjs_vm.contextGlobal(h.ctx);
    // createRootBytecodeFunctionObject consumes the FB value on every path.
    fb_value_owned = false;
    const root_fn = try object_ops.createRootBytecodeFunctionObject(
        h.ctx,
        global,
        fb_value,
        .root_global,
    );
    defer root_fn.free(h.rt);
    const root_object = object_ops.objectFromValue(root_fn) orelse
        return error.InvalidBytecode;

    var stack = stack_mod.Stack.init(&h.rt.memory, h.ctx.stackLimit());
    defer stack.deinit(h.rt);
    try stack.reserveAdditional(fb.stack_size);
    return zjs_vm.runWithCallEnv(.{
        .ctx = h.ctx,
        .stack = &stack,
        .function = fb,
        .initial_this_value = if (fb.runtimeStrictMode())
            core.JSValue.undefinedValue()
        else
            root_object.bytecodeFunctionRealmGlobalPtr().?.value(),
        .var_refs = root_object.functionCaptures(),
        .global = root_object.bytecodeFunctionRealmGlobalPtr() orelse
            return error.InvalidBytecode,
        .strict_unresolved_get_var = fb.isStrictMode(),
        .current_function_value = root_fn,
        .direct_eval_vars_reach_global = true,
        .global_declarations_prevalidated = true,
    });
}

fn expectFunctionDefInertAfterEscape(
    fd: *const bytecode_mod.function_def.FunctionDef,
) !void {
    try std.testing.expect(fd.v2_builder == null);
    try std.testing.expectEqual(core.atom.null_atom, fd.func_name);
    try std.testing.expectEqual(core.atom.null_atom, fd.filename);
    try std.testing.expectEqual(core.atom.null_atom, fd.script_or_module);
    try std.testing.expect(fd.source_text == null);
    for (fd.args) |arg| try std.testing.expectEqual(core.atom.null_atom, arg.var_name);
    for (fd.vars) |local| try std.testing.expectEqual(core.atom.null_atom, local.var_name);
    for (fd.closure_var) |closure| try std.testing.expectEqual(core.atom.null_atom, closure.var_name);
    for (fd.cpool) |value| try std.testing.expect(value.isUndefined());
    try std.testing.expectEqual(@as(i32, 0), fd.cpool_count);

    for (fd.child_list) |child| try expectFunctionDefInertAfterEscape(child);
}

const PublishedEscapeOwners = struct {
    named_args: usize = 0,
    named_vars: usize = 0,
    named_closure_vars: usize = 0,
    child_functions: usize = 0,
};

fn expectPublishedAtomResolves(rt: *const core.JSRuntime, atom_id: core.atom.Atom) !void {
    try std.testing.expect(atom_id != core.atom.null_atom);
    try std.testing.expect(rt.atoms.name(atom_id) != null);
}

fn expectPublishedFunctionBytecodeOwnersResolve(
    rt: *const core.JSRuntime,
    fb: *const bytecode_mod.FunctionBytecode,
    owners: *PublishedEscapeOwners,
) !void {
    try expectPublishedAtomResolves(rt, fb.funcName());
    try expectPublishedAtomResolves(rt, fb.filenameAtom());

    for (fb.argVarDefs()) |arg| {
        if (arg.var_name == core.atom.null_atom) continue;
        owners.named_args += 1;
        try std.testing.expect(rt.atoms.name(arg.var_name) != null);
    }
    for (fb.varDefs()) |local| {
        if (local.var_name == core.atom.null_atom) continue;
        owners.named_vars += 1;
        try std.testing.expect(rt.atoms.name(local.var_name) != null);
    }
    for (fb.closureVar()) |closure| {
        if (closure.var_name == core.atom.null_atom) continue;
        owners.named_closure_vars += 1;
        try std.testing.expect(rt.atoms.name(closure.var_name) != null);
    }
    for (fb.cpoolSlice()) |value| {
        if (!value.isFunctionBytecode()) continue;
        const header = value.objectHeader() orelse return error.TestUnexpectedResult;
        const child: *const bytecode_mod.FunctionBytecode = @fieldParentPtr("header", header);
        owners.child_functions += 1;
        try expectPublishedFunctionBytecodeOwnersResolve(rt, child, owners);
    }
}

fn expectFdTopologyEqual(
    legacy_fd: *const bytecode_mod.function_def.FunctionDef,
    v2_fd: *const bytecode_mod.function_def.FunctionDef,
) !void {
    try std.testing.expectEqual(legacy_fd.vars.len, v2_fd.vars.len);
    for (legacy_fd.vars, v2_fd.vars) |legacy_var, v2_var| {
        try std.testing.expectEqual(legacy_var.var_name, v2_var.var_name);
        try std.testing.expectEqual(legacy_var.scope_level, v2_var.scope_level);
        try std.testing.expectEqual(legacy_var.var_kind, v2_var.var_kind);
        try std.testing.expectEqual(legacy_var.is_lexical, v2_var.is_lexical);
        try std.testing.expectEqual(legacy_var.is_const, v2_var.is_const);
        try std.testing.expectEqual(legacy_var.is_captured, v2_var.is_captured);
    }

    try std.testing.expectEqual(legacy_fd.args.len, v2_fd.args.len);
    for (legacy_fd.args, v2_fd.args) |legacy_arg, v2_arg| {
        try std.testing.expectEqual(legacy_arg.var_name, v2_arg.var_name);
        try std.testing.expectEqual(legacy_arg.scope_level, v2_arg.scope_level);
        try std.testing.expectEqual(legacy_arg.var_kind, v2_arg.var_kind);
        try std.testing.expectEqual(legacy_arg.is_lexical, v2_arg.is_lexical);
        try std.testing.expectEqual(legacy_arg.is_const, v2_arg.is_const);
        try std.testing.expectEqual(legacy_arg.is_captured, v2_arg.is_captured);
    }

    try std.testing.expectEqual(legacy_fd.closure_var.len, v2_fd.closure_var.len);
    for (legacy_fd.closure_var, v2_fd.closure_var) |legacy_ref, v2_ref| {
        try std.testing.expectEqual(legacy_ref.var_name, v2_ref.var_name);
        try std.testing.expectEqual(legacy_ref.closureType(), v2_ref.closureType());
        try std.testing.expectEqual(legacy_ref.isLexical(), v2_ref.isLexical());
        try std.testing.expectEqual(legacy_ref.isConst(), v2_ref.isConst());
        // var_idx is the closure-ref topology order, not just row metadata.
        try std.testing.expectEqual(legacy_ref.var_idx, v2_ref.var_idx);
    }
}

fn normalizedLegacyCode(code: []const u8) ![]u8 {
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(std.testing.allocator);
    var pc: usize = 0;
    while (pc < code.len) {
        const op_id = code[pc];
        const size: usize = if (op_id == qop.label) 5 else opcode.sizeOf(op_id);
        if (size == 0 or pc + size > code.len) return error.InvalidBytecode;
        if (op_id != qop.label and op_id != qop.nop)
            try normalized.appendSlice(std.testing.allocator, code[pc .. pc + size]);
        pc += size;
    }
    return normalized.toOwnedSlice(std.testing.allocator);
}

fn expectLoweredStreamEqual(
    legacy_function: *const bytecode_mod.Bytecode,
    v2_product: *const resolve_variables.ResolvedProduct,
) !void {
    const normalized = try normalizedLegacyCode(legacy_function.code);
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualSlices(
        u8,
        normalized,
        v2_product.code[0..v2_product.code_len],
    );
    try std.testing.expectEqualSlices(
        core.atom.Atom,
        legacy_function.atom_operands,
        v2_product.atom_operands[0..v2_product.atom_len],
    );
}

const AtomBalanceRow = struct {
    atom_id: core.atom.Atom,
    before_release: usize,
    owned_count: usize,
};

fn deinitProductAndExpectAtomBalance(
    atoms: *core.atom.AtomTable,
    product: *resolve_variables.ResolvedProduct,
) !void {
    var balances: std.ArrayList(AtomBalanceRow) = .empty;
    defer balances.deinit(std.testing.allocator);
    for (product.atom_operands[0..product.atom_len]) |atom_id| {
        var found = false;
        for (balances.items) |*row| {
            if (row.atom_id != atom_id) continue;
            row.owned_count += 1;
            found = true;
            break;
        }
        if (!found) {
            try balances.append(std.testing.allocator, .{
                .atom_id = atom_id,
                .before_release = atoms.refCount(atom_id) orelse return error.InvalidBytecode,
                .owned_count = 1,
            });
        }
    }

    product.deinitUncommitted();
    for (balances.items) |row| {
        try std.testing.expect(row.before_release >= row.owned_count);
        try std.testing.expectEqual(
            row.before_release - row.owned_count,
            atoms.refCount(row.atom_id) orelse return error.InvalidBytecode,
        );
    }
}

fn runLegacyResolve(
    function: *bytecode_mod.Bytecode,
    fd: *bytecode_mod.function_def.FunctionDef,
) !void {
    var ctx = bytecode_mod.pipeline_resolve_variables.JSContext.initWithFunctionDef(function, fd);
    try bytecode_mod.pipeline_resolve_variables.run(&ctx);
}

fn installPhase1Stream(
    function: *bytecode_mod.Bytecode,
    code: []const u8,
    atoms: []const core.atom.Atom,
) !void {
    try function.setCode(code);
    for (atoms) |atom_id| try function.retainAtomOperand(atom_id);
}

const RootSeedKind = enum {
    global,
    top_level_lexical,
    block_lexical,
};

fn expectRootNormalizedEquivalence(src: []const u8, kind: RootSeedKind) !void {
    var legacy: LegacyParse = undefined;
    try legacy.init(src);
    defer legacy.deinit();
    try legacy.parseProgram(false);

    var v2: LegacyParse = undefined;
    try v2.init(src);
    defer v2.deinit();
    try v2.parseProgram(false);
    try attachTranslatedBuilder(
        &v2.state.function_def,
        v2.function.code,
        v2.function.atom_operands,
    );

    try runLegacyResolve(&legacy.function, &legacy.state.function_def);
    var product = try resolve_variables.run(&v2.function, &v2.state.function_def);
    defer product.deinitUncommitted();

    try expectFdTopologyEqual(&legacy.state.function_def, &v2.state.function_def);
    try expectLoweredStreamEqual(&legacy.function, &product);
    switch (kind) {
        .global => {
            try std.testing.expectEqual(@as(usize, 1), legacy.state.function_def.closure_var.len);
            try std.testing.expectEqual(
                bytecode_mod.function_def.ClosureType.global,
                legacy.state.function_def.closure_var[0].closureType(),
            );
        },
        .top_level_lexical, .block_lexical => {
            try std.testing.expect(legacy.state.function_def.vars.len != 0);
        },
    }
    try deinitProductAndExpectAtomBalance(&v2.rt.atoms, &product);
}

const ExpectedChildShape = struct {
    args: ?usize = null,
    vars: ?usize = null,
};

fn expectChildNormalizedEquivalence(src: []const u8, expected_shape: ExpectedChildShape) !void {
    var legacy: LegacyParse = undefined;
    try legacy.init(src);
    defer legacy.deinit();
    try legacy.parseProgram(true);
    try std.testing.expectEqual(@as(usize, 1), legacy.state.function_def.child_list.len);
    const legacy_child = legacy.state.function_def.child_list[0];

    var v2: LegacyParse = undefined;
    try v2.init(src);
    defer v2.deinit();
    try v2.parseProgram(true);
    try std.testing.expectEqual(@as(usize, 1), v2.state.function_def.child_list.len);
    const v2_child = v2.state.function_def.child_list[0];
    try attachTranslatedBuilder(v2_child, v2_child.byte_code, v2_child.atom_operands);

    var legacy_function = bytecode_mod.Bytecode.init(
        &legacy.rt.memory,
        &legacy.rt.atoms,
        legacy_child.func_name,
    );
    defer legacy_function.deinit(legacy.rt);
    try installPhase1Stream(
        &legacy_function,
        legacy_child.byte_code,
        legacy_child.atom_operands,
    );
    try runLegacyResolve(&legacy_function, legacy_child);

    var v2_function = bytecode_mod.Bytecode.init(
        &v2.rt.memory,
        &v2.rt.atoms,
        v2_child.func_name,
    );
    defer v2_function.deinit(v2.rt);
    var product = try resolve_variables.run(&v2_function, v2_child);
    defer product.deinitUncommitted();

    try expectFdTopologyEqual(legacy_child, v2_child);
    try expectLoweredStreamEqual(&legacy_function, &product);
    // Byte equality proves selected loc/arg operands; var_idx equality in
    // expectFdTopologyEqual proves closure-ref index order. Optional explicit
    // shape checks keep seed-specific expectations out of the general helper.
    if (expected_shape.args) |expected_args|
        try std.testing.expectEqual(expected_args, legacy_child.args.len);
    if (expected_shape.vars) |expected_vars|
        try std.testing.expectEqual(expected_vars, legacy_child.vars.len);
    try deinitProductAndExpectAtomBalance(&v2.rt.atoms, &product);
}

/// Validate every intrusive relocation chain, including unique coverage of the
/// complete relocation ledger, and require every parser-created label bound.
/// The parser harness cannot produce aux32 while scope_make_ref remains
/// phase-1-gated, so every relocation here must be jump32; builder inline tests
/// cover aux32.
fn expectRelocIntegrity(b: *const builder_mod.Builder) !void {
    const visited = try std.testing.allocator.alloc(bool, @intCast(b.reloc_len));
    defer std.testing.allocator.free(visited);
    @memset(visited, false);

    var total_relocs: u32 = 0;
    var label_index: u32 = 0;
    while (label_index < b.label_len) : (label_index += 1) {
        const slot = b.label_slots[label_index];
        try std.testing.expect(slot.flags.bound);
        try std.testing.expect(slot.bound_offset != labels.unbound);
        try std.testing.expect(slot.bound_offset <= b.code_len);

        var reloc_index = slot.first_reloc;
        var previous_reloc = labels.no_reloc;
        var chain_count: u32 = 0;
        while (reloc_index != labels.no_reloc) {
            try std.testing.expect(reloc_index < b.reloc_len);
            try std.testing.expect(reloc_index < previous_reloc);

            const reloc_usize: usize = @intCast(reloc_index);
            try std.testing.expect(!visited[reloc_usize]);
            visited[reloc_usize] = true;

            const entry = b.relocs[reloc_usize];
            try std.testing.expectEqual(labels.RelocKind.jump32, entry.kind);
            try std.testing.expect(entry.operand_offset >= 1);
            try std.testing.expect(entry.operand_offset <= b.code_len);
            try std.testing.expect(b.code_len - entry.operand_offset >= 4);
            const operand_offset: usize = @intCast(entry.operand_offset);
            try std.testing.expectEqual(
                label_index,
                std.mem.readInt(u32, b.code[operand_offset..][0..4], .little),
            );

            chain_count += 1;
            total_relocs += 1;
            previous_reloc = reloc_index;
            reloc_index = entry.next;
        }
        try std.testing.expectEqual(slot.ref_count, chain_count);
    }

    try std.testing.expectEqual(b.reloc_len, total_relocs);
    for (visited) |was_visited| try std.testing.expect(was_visited);
}

/// Source slots must be non-decreasing and point at an instruction in the
/// temporary stream.
fn expectSourceOrder(b: *const builder_mod.Builder) !void {
    var previous_offset: u32 = 0;
    for (b.source_slots[0..b.source_len]) |slot| {
        try std.testing.expect(slot.temp_offset >= previous_offset);
        try std.testing.expect(slot.temp_offset < b.code_len);
        previous_offset = slot.temp_offset;
    }
}

fn expectSourceOffsets(b: *const builder_mod.Builder, expected: []const u32) !void {
    try std.testing.expectEqual(@as(usize, @intCast(b.source_len)), expected.len);
    for (expected, 0..) |offset, index| {
        try std.testing.expectEqual(offset, b.source_slots[index].temp_offset);
    }
}

test "compiler_v2.tests: forward jump binds and relocates" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var b = builder_mod.Builder.init(&rt.memory, &rt.atoms);
    defer b.deinit();

    const label = try b.newLabel();
    const operand_offset = b.code_len + 1;
    try b.emitJump(0x41, label);
    const bind_offset = b.code_len;
    try b.bindLabel(label);

    const slot = b.label_slots[label.index()];
    try std.testing.expectEqual(bind_offset, slot.bound_offset);
    try std.testing.expectEqual(@as(u32, 1), slot.ref_count);

    var reloc_index = slot.first_reloc;
    var entry_count: u32 = 0;
    while (reloc_index != labels.no_reloc) {
        const entry = b.relocs[reloc_index];
        try std.testing.expectEqual(operand_offset, entry.operand_offset);
        try std.testing.expectEqual(labels.RelocKind.jump32, entry.kind);
        entry_count += 1;
        reloc_index = entry.next;
    }
    try std.testing.expectEqual(@as(u32, 1), entry_count);
}

test "compiler_v2.tests: backward jump marks target and relocates" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var b = builder_mod.Builder.init(&rt.memory, &rt.atoms);
    defer b.deinit();

    const label = try b.newLabel();
    try b.bindLabel(label);
    const operand_offset = b.code_len + 1;
    try b.emitJump(0x42, label);

    const slot = b.label_slots[label.index()];
    try std.testing.expectEqual(@as(u32, 1), slot.ref_count);
    try std.testing.expect(slot.flags.backward_target);

    var reloc_index = slot.first_reloc;
    var entry_count: u32 = 0;
    while (reloc_index != labels.no_reloc) {
        const entry = b.relocs[reloc_index];
        try std.testing.expectEqual(operand_offset, entry.operand_offset);
        try std.testing.expectEqual(labels.RelocKind.jump32, entry.kind);
        entry_count += 1;
        reloc_index = entry.next;
    }
    try std.testing.expectEqual(@as(u32, 1), entry_count);
}

test "compiler_v2.tests: many jumps share a head-first reloc chain" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var b = builder_mod.Builder.init(&rt.memory, &rt.atoms);
    defer b.deinit();

    const label = try b.newLabel();
    var operand_offsets: [3]u32 = undefined;

    operand_offsets[0] = b.code_len + 1;
    try b.emitJump(0x43, label);
    operand_offsets[1] = b.code_len + 1;
    try b.emitJump(0x44, label);
    operand_offsets[2] = b.code_len + 1;
    try b.emitJump(0x45, label);

    const slot = b.label_slots[label.index()];
    try std.testing.expectEqual(@as(u32, 3), slot.ref_count);

    var reloc_index = slot.first_reloc;
    var expected_offset_index = operand_offsets.len;
    var entry_count: u32 = 0;
    while (reloc_index != labels.no_reloc) {
        try std.testing.expect(expected_offset_index > 0);
        expected_offset_index -= 1;

        const entry = b.relocs[reloc_index];
        try std.testing.expectEqual(@as(u32, @intCast(expected_offset_index)), reloc_index);
        try std.testing.expectEqual(operand_offsets[expected_offset_index], entry.operand_offset);
        try std.testing.expectEqual(labels.RelocKind.jump32, entry.kind);
        entry_count += 1;
        reloc_index = entry.next;
    }
    try std.testing.expectEqual(@as(usize, 0), expected_offset_index);
    try std.testing.expectEqual(@as(u32, 3), entry_count);
}

test "compiler_v2.tests: first unbound label and binds fail closed" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var b = builder_mod.Builder.init(&rt.memory, &rt.atoms);
    defer b.deinit();

    const first = try b.newLabel();
    const second = try b.newLabel();
    try b.bindLabel(second);
    try std.testing.expectEqual(first, b.firstUnboundLabel().?);

    try b.bindLabel(first);
    try std.testing.expect(b.firstUnboundLabel() == null);
    try std.testing.expectError(error.InvalidBytecode, b.bindLabel(first));
    try std.testing.expectError(error.InvalidBytecode, b.bindLabel(@enumFromInt(9999)));
}

fn oomScript(allocator: std.mem.Allocator) !void {
    const rt = try core.JSRuntime.create(allocator);
    defer rt.destroy();

    var b = builder_mod.Builder.init(&rt.memory, &rt.atoms);
    defer b.deinit();

    var initial_labels: [10]labels.LabelId = undefined;
    for (&initial_labels) |*label| label.* = try b.newLabel();

    var jump_index: usize = 0;
    while (jump_index < 9) : (jump_index += 1) {
        try b.emitJump(@intCast(0x50 + jump_index), initial_labels[0]);
    }
    try b.bindLabel(initial_labels[1]);
    try b.bindLabel(initial_labels[2]);
    try b.addSourceMarker(11, 12);

    const snap = b.snapshot();
    const pre_snapshot_ref_count = b.label_slots[initial_labels[0].index()].ref_count;
    const pre_snapshot_first_reloc = b.label_slots[initial_labels[0].index()].first_reloc;

    try b.emitJump(0x60, initial_labels[0]);
    const post_label_a = try b.newLabel();
    try b.emitJump(0x61, post_label_a);
    try b.bindLabel(post_label_a);
    const post_label_b = try b.newLabel();
    try b.emitJump(0x62, post_label_b);
    try b.addSourceMarker(13, 14);
    try b.emitOp(0x63);
    try b.addSourceMarker(15, 16);

    b.rollback(snap);
    try std.testing.expectEqual(snap.code_len, b.code_len);
    try std.testing.expectEqual(snap.label_len, b.label_len);
    try std.testing.expectEqual(snap.reloc_len, b.reloc_len);
    try std.testing.expectEqual(snap.source_len, b.source_len);
    try std.testing.expectEqual(
        pre_snapshot_ref_count,
        b.label_slots[initial_labels[0].index()].ref_count,
    );
    try std.testing.expectEqual(
        pre_snapshot_first_reloc,
        b.label_slots[initial_labels[0].index()].first_reloc,
    );

    try b.emitJump(0x64, initial_labels[0]);
    const continuation_label = try b.newLabel();
    try b.bindLabel(continuation_label);
    try b.addSourceMarker(17, 18);
}

test "compiler_v2.tests: allocation failure sweep preserves cleanup" {
    try oomScript(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, oomScript, .{});
}

test "compiler_v2.tests: source slots roll back to snapshot" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var b = builder_mod.Builder.init(&rt.memory, &rt.atoms);
    defer b.deinit();

    try b.addSourceMarker(21, 22);
    try b.emitOp(0x70);
    try b.addSourceMarker(23, 24);
    try b.emitOp(0x71);
    try b.addSourceMarker(25, 26);
    const snap = b.snapshot();
    const expected = [_]builder_mod.SourceSlot{
        b.source_slots[0],
        b.source_slots[1],
        b.source_slots[2],
    };

    try b.emitOp(0x72);
    try b.addSourceMarker(27, 28);
    try b.emitOp(0x73);
    try b.addSourceMarker(29, 30);
    b.rollback(snap);

    try std.testing.expectEqual(snap.source_len, b.source_len);
    for (expected, 0..) |entry, index| {
        const actual = b.source_slots[index];
        try std.testing.expectEqual(entry.temp_offset, actual.temp_offset);
        try std.testing.expectEqual(entry.line, actual.line);
        try std.testing.expectEqual(entry.col, actual.col);
    }
}

test "compiler_v2.tests: atom ownership balances across rollback and deinit" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const atom = try rt.atoms.internString("compiler_v2_atom_ownership");
    defer rt.atoms.free(atom);
    const base = rt.atoms.refCount(atom).?;

    var b = builder_mod.Builder.init(&rt.memory, &rt.atoms);
    defer b.deinit();

    try b.emitAtomOpOwned(0x80, rt.atoms.dup(atom));
    try b.emitAtomOpOwned(0x81, rt.atoms.dup(atom));
    try b.emitAtomOpOwned(0x82, rt.atoms.dup(atom));
    const snap = b.snapshot();

    try b.emitAtomOpOwned(0x83, rt.atoms.dup(atom));
    try b.emitAtomOpOwned(0x84, rt.atoms.dup(atom));
    try std.testing.expectEqual(base + 5, rt.atoms.refCount(atom).?);

    b.rollback(snap);
    try std.testing.expectEqual(base + 3, rt.atoms.refCount(atom).?);

    b.deinit();
    try std.testing.expectEqual(base, rt.atoms.refCount(atom).?);
}

test "compiler_v2.tests: rollback restores a shared label reloc chain" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var b = builder_mod.Builder.init(&rt.memory, &rt.atoms);
    defer b.deinit();

    const shared_label = try b.newLabel();
    try b.emitJump(0x90, shared_label);
    try b.emitJump(0x91, shared_label);
    const snap = b.snapshot();
    const pre_snapshot_first_reloc = b.label_slots[shared_label.index()].first_reloc;
    const pre_snapshot_ref_count = b.label_slots[shared_label.index()].ref_count;

    try b.emitJump(0x92, shared_label);
    try b.emitJump(0x93, shared_label);
    try b.emitJump(0x94, shared_label);
    b.rollback(snap);

    const slot = b.label_slots[shared_label.index()];
    try std.testing.expectEqual(pre_snapshot_first_reloc, slot.first_reloc);
    try std.testing.expectEqual(pre_snapshot_ref_count, slot.ref_count);

    var reloc_index = slot.first_reloc;
    var entry_count: u32 = 0;
    while (reloc_index != labels.no_reloc) {
        try std.testing.expect(reloc_index < snap.reloc_len);
        const entry = b.relocs[reloc_index];
        try std.testing.expectEqual(labels.RelocKind.jump32, entry.kind);
        entry_count += 1;
        reloc_index = entry.next;
    }
    try std.testing.expectEqual(slot.ref_count, entry_count);
}

test "compiler_v2.s2g1: conditional expression" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("true ? false : null");
    defer h.deinit();

    try P.parseExpr(&h.state);
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 0 },
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 1 },
        .{ .op = qop.null, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 13), b.code_len);
    try std.testing.expectEqual(@as(u32, 2), b.label_len);
    try expectLabel(b, 0, 1, 12);
    try expectLabel(b, 1, 1, 13);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 6, 7, 12 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g1: logical or" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("false || true");
    defer h.deinit();

    try P.parseExpr(&h.state);
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.if_true, .size = 5, .label = 0 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.push_true, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 9), b.code_len);
    try std.testing.expectEqual(@as(u32, 1), b.label_len);
    try expectLabel(b, 0, 1, 9);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 8 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g1: logical and chain" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("true && false && null");
    defer h.deinit();

    try P.parseExpr(&h.state);
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 0 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 0 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.null, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 17), b.code_len);
    try std.testing.expectEqual(@as(u32, 1), b.label_len);
    try expectLabel(b, 0, 2, 17);
    try std.testing.expectEqual(@as(u32, 1), b.label_slots[0].first_reloc);
    try std.testing.expectEqual(@as(u32, 0), b.relocs[1].next);
    try std.testing.expectEqual(labels.no_reloc, b.relocs[0].next);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 8, 16 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g1: coalesce" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("null ?? true");
    defer h.deinit();

    try P.parseExpr(&h.state);
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.is_undefined_or_null, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 0 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.push_true, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 10), b.code_len);
    try std.testing.expectEqual(@as(u32, 1), b.label_len);
    try expectLabel(b, 0, 1, 10);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 2, 3, 8, 9 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g1: coalesce chain" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("null ?? null ?? true");
    defer h.deinit();

    try P.parseExpr(&h.state);
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.is_undefined_or_null, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 0 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.is_undefined_or_null, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 0 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.push_true, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 19), b.code_len);
    try std.testing.expectEqual(@as(u32, 1), b.label_len);
    try expectLabel(b, 0, 2, 19);
    try std.testing.expectEqual(@as(u32, 1), b.label_slots[0].first_reloc);
    try std.testing.expectEqual(@as(u32, 0), b.relocs[1].next);
    try std.testing.expectEqual(labels.no_reloc, b.relocs[0].next);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 2, 3, 8, 9, 10, 11, 12, 17, 18 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g1: optional chain field" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("true?.b");
    defer h.deinit();

    const field_atom = try h.rt.atoms.internString("b");
    defer h.rt.atoms.free(field_atom);

    try P.parseExpr(&h.state);
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.is_undefined_or_null, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 0 },
        .{ .op = qop.get_field_opt_chain, .size = 5, .atom = field_atom },
    });
    try std.testing.expectEqual(@as(u32, 20), b.code_len);
    try std.testing.expectEqual(@as(u32, 2), b.label_len);
    try expectLabel(b, 0, 1, 20);
    try expectLabel(b, 1, 1, 15);
    try std.testing.expectEqual(@as(u32, 1), b.atom_len);
    try std.testing.expectEqual(field_atom, b.atom_operands[0]);
    try std.testing.expectEqual(qop.get_field_opt_chain, b.code[15]);
    try std.testing.expectEqual(@as(i64, 15), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 2, 3, 8, 9, 15 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g1: optional chain element" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("true?.[false]");
    defer h.deinit();

    try P.parseExpr(&h.state);
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.is_undefined_or_null, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 0 },
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.get_array_el_opt_chain, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 17), b.code_len);
    try std.testing.expectEqual(@as(u32, 2), b.label_len);
    try expectLabel(b, 0, 1, 17);
    try expectLabel(b, 1, 1, 15);
    try std.testing.expectEqual(qop.get_array_el_opt_chain, b.code[16]);
    try std.testing.expectEqual(@as(i64, 16), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 2, 3, 8, 9, 15, 16 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g1: if else empty" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("if (true) ; else ;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 0 },
        .{ .op = qop.goto, .size = 5, .label = 1 },
    });
    try std.testing.expectEqual(@as(u32, 11), b.code_len);
    try std.testing.expectEqual(@as(u32, 2), b.label_len);
    try expectLabel(b, 0, 1, 11);
    try expectLabel(b, 1, 1, 11);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 6 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g1: if else expression bodies" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("if (true) false; else null;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 0 },
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 1 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 15), b.code_len);
    try std.testing.expectEqual(@as(u32, 2), b.label_len);
    try expectLabel(b, 0, 1, 13);
    try expectLabel(b, 1, 1, 15);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 6, 8, 13 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g1: if without else" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("if (true) ;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 0 },
    });
    try std.testing.expectEqual(@as(u32, 6), b.code_len);
    try std.testing.expectEqual(@as(u32, 1), b.label_len);
    try expectLabel(b, 0, 1, 6);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g1: labeled break" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("L: if (true) break L;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.goto, .size = 5, .label = 0 },
    });
    try std.testing.expectEqual(@as(u32, 11), b.code_len);
    try std.testing.expectEqual(@as(u32, 2), b.label_len);
    try expectLabel(b, 0, 1, 11);
    try expectLabel(b, 1, 1, 11);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g1: labeled statement without break" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("L: ;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{});
    try std.testing.expectEqual(@as(u32, 0), b.code_len);
    try std.testing.expectEqual(@as(u32, 1), b.label_len);
    try expectLabel(b, 0, 0, 0);
    try std.testing.expectEqual(labels.no_reloc, b.label_slots[0].first_reloc);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{});
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g1: optional chain atom ownership" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("true?.b");
    defer h.deinit();

    const field_atom = try h.rt.atoms.internString("b");
    defer h.rt.atoms.free(field_atom);

    try P.parseExpr(&h.state);
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try std.testing.expectEqual(@as(u32, 1), b.atom_len);
    try std.testing.expectEqual(field_atom, b.atom_operands[0]);
    try std.testing.expectEqual(qop.get_field_opt_chain, b.code[15]);
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g2: while" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("while (true) ;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.goto, .size = 5, .label = 0 },
    });
    try std.testing.expectEqual(@as(u32, 11), b.code_len);
    try std.testing.expectEqual(@as(u32, 4), b.label_len);
    try expectLabel(b, 0, 1, 0);
    try expectLabel(b, 1, 1, 11);
    try expectLabel(b, 2, 0, 6);
    try expectLabel(b, 3, 0, 11);
    try std.testing.expect(b.label_slots[0].flags.backward_target);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 6 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g2: while continue" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("while (true) continue;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.goto, .size = 5, .label = 2 },
        .{ .op = qop.goto, .size = 5, .label = 0 },
    });
    try std.testing.expectEqual(@as(u32, 16), b.code_len);
    try std.testing.expectEqual(@as(u32, 4), b.label_len);
    try expectLabel(b, 0, 1, 0);
    try expectLabel(b, 1, 1, 16);
    try expectLabel(b, 2, 1, 11);
    try expectLabel(b, 3, 0, 16);
    try std.testing.expect(b.label_slots[0].flags.backward_target);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 11 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g2: labeled while continue" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("L: while (true) continue L;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.goto, .size = 5, .label = 4 },
        .{ .op = qop.goto, .size = 5, .label = 0 },
    });
    try std.testing.expectEqual(@as(u32, 16), b.code_len);
    try std.testing.expectEqual(@as(u32, 6), b.label_len);
    try expectLabel(b, 0, 1, 0);
    try expectLabel(b, 1, 1, 16);
    try expectLabel(b, 2, 0, 11);
    try expectLabel(b, 3, 0, 16);
    try expectLabel(b, 4, 1, 11);
    try expectLabel(b, 5, 0, 16);
    try std.testing.expect(b.label_slots[0].flags.backward_target);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 11 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g2: do while" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("do ; while (false);");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.if_true, .size = 5, .label = 0 },
    });
    try std.testing.expectEqual(@as(u32, 6), b.code_len);
    try std.testing.expectEqual(@as(u32, 3), b.label_len);
    try expectLabel(b, 0, 1, 0);
    try expectLabel(b, 1, 0, 0);
    try expectLabel(b, 2, 0, 6);
    try std.testing.expect(b.label_slots[0].flags.backward_target);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g2: classic for empty head" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("for (;;) ;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.goto, .size = 5, .label = 0 },
    });
    try std.testing.expectEqual(@as(u32, 11), b.code_len);
    try std.testing.expectEqual(@as(u32, 4), b.label_len);
    try expectLabel(b, 0, 1, 0);
    try expectLabel(b, 1, 1, 11);
    try expectLabel(b, 2, 0, 6);
    try expectLabel(b, 3, 0, 11);
    try std.testing.expect(b.label_slots[0].flags.backward_target);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    // The classic-for test-entry marker and the synthetic true literal both
    // precede the first opcode; Stage 3 deduplicates them only when their
    // line/column points are identical.
    try expectSourceOffsets(b, &.{ 0, 0, 1, 6 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g2: classic for test break" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("for (; false; ) break;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.goto, .size = 5, .label = 3 },
        .{ .op = qop.goto, .size = 5, .label = 0 },
    });
    try std.testing.expectEqual(@as(u32, 16), b.code_len);
    try std.testing.expectEqual(@as(u32, 4), b.label_len);
    try expectLabel(b, 0, 1, 0);
    try expectLabel(b, 1, 1, 16);
    try expectLabel(b, 2, 0, 11);
    try expectLabel(b, 3, 1, 16);
    try std.testing.expect(b.label_slots[0].flags.backward_target);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 0, 1, 11 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g2: for in" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("for (var x in null) ;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.goto, .size = 5, .label = 0 },
        .{ .op = qop.put_var, .size = 3 },
        .{ .op = qop.goto, .size = 5, .label = 2 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.for_in_start, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 3 },
        .{ .op = qop.for_in_next, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 28), b.code_len);
    try std.testing.expectEqual(@as(u32, 6), b.label_len);
    try expectLabel(b, 0, 1, 13);
    try expectLabel(b, 1, 1, 5);
    try expectLabel(b, 2, 1, 20);
    try expectLabel(b, 3, 1, 20);
    try expectLabel(b, 4, 0, 20);
    try expectLabel(b, 5, 0, 28);
    try std.testing.expect(b.label_slots[1].flags.backward_target);
    try std.testing.expectEqual(@as(u32, 0), b.atom_len);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 5, 8, 13, 14, 15, 20, 21, 26, 27 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g2: for in break cleanup" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("for (var x in null) break;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.goto, .size = 5, .label = 0 },
        .{ .op = qop.put_var, .size = 3 },
        .{ .op = qop.goto, .size = 5, .label = 2 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.for_in_start, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 3 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 5 },
        .{ .op = qop.for_in_next, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 34), b.code_len);
    try std.testing.expectEqual(@as(u32, 6), b.label_len);
    try expectLabel(b, 0, 1, 13);
    try expectLabel(b, 1, 1, 5);
    try expectLabel(b, 2, 1, 20);
    try expectLabel(b, 3, 1, 26);
    try expectLabel(b, 4, 0, 26);
    try expectLabel(b, 5, 1, 34);
    try std.testing.expect(b.label_slots[1].flags.backward_target);
    try std.testing.expectEqual(@as(u32, 0), b.atom_len);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 5, 8, 13, 14, 15, 26, 27, 32, 33 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g2: for of" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("for (var x of null) ;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.goto, .size = 5, .label = 0 },
        .{ .op = qop.put_var, .size = 3 },
        .{ .op = qop.goto, .size = 5, .label = 2 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.for_of_start, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 3 },
        .{ .op = qop.for_of_next, .size = 2 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.iterator_close, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 29), b.code_len);
    try std.testing.expectEqual(@as(u32, 6), b.label_len);
    try expectLabel(b, 0, 1, 13);
    try expectLabel(b, 1, 1, 5);
    try expectLabel(b, 2, 1, 20);
    try expectLabel(b, 3, 1, 20);
    try expectLabel(b, 4, 0, 20);
    try expectLabel(b, 5, 0, 29);
    try std.testing.expect(b.label_slots[1].flags.backward_target);
    try std.testing.expectEqual(@as(u8, 0), b.code[21]);
    try std.testing.expectEqual(@as(u32, 0), b.atom_len);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 5, 8, 13, 14, 15, 20, 22, 27, 28 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g2: for of break cleanup" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("for (var x of null) break;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.goto, .size = 5, .label = 0 },
        .{ .op = qop.put_var, .size = 3 },
        .{ .op = qop.goto, .size = 5, .label = 2 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.for_of_start, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 3 },
        .{ .op = qop.iterator_close, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 5 },
        .{ .op = qop.for_of_next, .size = 2 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.iterator_close, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 35), b.code_len);
    try std.testing.expectEqual(@as(u32, 6), b.label_len);
    try expectLabel(b, 0, 1, 13);
    try expectLabel(b, 1, 1, 5);
    try expectLabel(b, 2, 1, 20);
    try expectLabel(b, 3, 1, 26);
    try expectLabel(b, 4, 0, 26);
    try expectLabel(b, 5, 1, 35);
    try std.testing.expect(b.label_slots[1].flags.backward_target);
    try std.testing.expectEqual(@as(u8, 0), b.code[27]);
    try std.testing.expectEqual(@as(u32, 0), b.atom_len);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 5, 8, 13, 14, 15, 26, 28, 33, 34 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g2: switch single case" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("switch (true) { case false: null; }");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.strict_eq, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 12), b.code_len);
    try std.testing.expectEqual(@as(u32, 2), b.label_len);
    try expectLabel(b, 0, 0, 11);
    try expectLabel(b, 1, 1, 11);
    try std.testing.expectEqual(@as(i64, 11), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 2, 3, 4, 9, 11 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g2: switch break default" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("switch (true) { case false: break; default: null; }");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.strict_eq, .size = 1 },
        // The unmatched-case dispatch operand names the DEFAULT identity: the
        // epilogue moved its reference there (`retargetLabelRefs`), exactly as
        // legacy's `patchJumpTarget` writes the default body's PC into it.
        .{ .op = qop.if_false, .size = 5, .label = 2 },
        .{ .op = qop.goto, .size = 5, .label = 0 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 17), b.code_len);
    try std.testing.expectEqual(@as(u32, 3), b.label_len);
    try expectLabel(b, 0, 1, 16);
    // The retargeted no-match identity keeps no reference and aliases the
    // default body it merged into.
    try expectLabel(b, 1, 0, 14);
    try expectLabel(b, 2, 1, 14);
    try std.testing.expectEqual(@as(i64, 16), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 2, 3, 4, 14, 16 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g2: switch case fallthrough" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("switch (true) { case false: null; case null: false; }");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.strict_eq, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 2 },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.strict_eq, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 3 },
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 27), b.code_len);
    try std.testing.expectEqual(@as(u32, 4), b.label_len);
    try expectLabel(b, 0, 0, 26);
    try expectLabel(b, 1, 1, 16);
    try expectLabel(b, 2, 1, 24);
    try expectLabel(b, 3, 1, 26);
    try std.testing.expectEqual(@as(i64, 26), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 2, 3, 4, 9, 11, 16, 17, 18, 19, 24, 26 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g2: switch default only" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("switch (true) { default: null; }");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        // A leading `default` still emits the dispatch continuation goto; the
        // epilogue then retargets it onto the default body, so it becomes the
        // jump-to-next-instruction that legacy's `patchJumpTarget` produces and
        // `resolve_labels` folds away.
        .{ .op = qop.goto, .size = 5, .label = 2 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 9), b.code_len);
    try std.testing.expectEqual(@as(u32, 3), b.label_len);
    try expectLabel(b, 0, 0, 8);
    try expectLabel(b, 1, 0, 6);
    try expectLabel(b, 2, 1, 6);
    try std.testing.expectEqual(@as(i64, 8), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 6, 8 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g2: switch break suppresses fallthrough" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("switch (true) { case false: break; case null: ; }");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.strict_eq, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.goto, .size = 5, .label = 0 },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.strict_eq, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 2 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 23), b.code_len);
    try std.testing.expectEqual(@as(u32, 3), b.label_len);
    try expectLabel(b, 0, 1, 22);
    try expectLabel(b, 1, 1, 14);
    try expectLabel(b, 2, 1, 22);
    try std.testing.expectEqual(@as(i64, 22), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 2, 3, 4, 14, 15, 16, 17, 22 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g3: try finally live tail" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("try { null; } finally { false; }");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.@"catch", .size = 5, .label = 0 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.gosub, .size = 5, .label = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 2 },
        .{ .op = qop.gosub, .size = 5, .label = 1 },
        .{ .op = qop.throw, .size = 1 },
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.ret, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 29), b.code_len);
    try std.testing.expectEqual(@as(u32, 3), b.label_len);
    try expectLabel(b, 0, 1, 20);
    try expectLabel(b, 1, 2, 26);
    try expectLabel(b, 2, 1, 29);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 5, 26 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g3: try catch optional binding live tails" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("try { null; } catch { false; }");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.@"catch", .size = 5, .label = 0 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.gosub, .size = 5, .label = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 2 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.@"catch", .size = 5, .label = 3 },
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.gosub, .size = 5, .label = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 2 },
        .{ .op = qop.gosub, .size = 5, .label = 1 },
        .{ .op = qop.throw, .size = 1 },
        .{ .op = qop.ret, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 48), b.code_len);
    try std.testing.expectEqual(@as(u32, 4), b.label_len);
    try expectLabel(b, 0, 1, 20);
    try expectLabel(b, 1, 3, 47);
    try expectLabel(b, 2, 2, 48);
    try expectLabel(b, 3, 1, 41);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 5, 21, 26 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g3: try catch binding after throw" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("try { throw true; } catch (e) { }");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.@"catch", .size = 5, .label = 0 },
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.throw, .size = 1 },
        .{ .op = qop.put_var, .size = 3 },
        .{ .op = qop.@"catch", .size = 5, .label = 3 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.gosub, .size = 5, .label = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 2 },
        .{ .op = qop.gosub, .size = 5, .label = 1 },
        .{ .op = qop.throw, .size = 1 },
        .{ .op = qop.ret, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 35), b.code_len);
    try std.testing.expectEqual(@as(u32, 4), b.label_len);
    try expectLabel(b, 0, 1, 7);
    try expectLabel(b, 1, 2, 34);
    try expectLabel(b, 2, 1, 35);
    try expectLabel(b, 3, 1, 28);
    try std.testing.expectEqual(@as(u32, 0), b.atom_len);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 5, 6, 7, 10 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g3: return through finally" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("try { return; } finally { null; }");
    // Statement-entry harness runs outside a function body; return needs the qjs return-allowed depth.
    h.state.return_depth = 1;
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.@"catch", .size = 5, .label = 0 },
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.nip_catch, .size = 1 },
        .{ .op = qop.gosub, .size = 5, .label = 1 },
        .{ .op = qop.@"return", .size = 1 },
        .{ .op = qop.gosub, .size = 5, .label = 1 },
        .{ .op = qop.throw, .size = 1 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.ret, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 22), b.code_len);
    try std.testing.expectEqual(@as(u32, 3), b.label_len);
    try expectLabel(b, 0, 1, 13);
    try expectLabel(b, 1, 2, 19);
    try expectLabel(b, 2, 0, 22);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 5, 6, 12, 19 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g3: break through finally inside loop" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("while (true) { try { break; } finally { null; } }");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.@"catch", .size = 5, .label = 4 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.gosub, .size = 5, .label = 5 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 3 },
        .{ .op = qop.gosub, .size = 5, .label = 5 },
        .{ .op = qop.throw, .size = 1 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.ret, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 0 },
    });
    try std.testing.expectEqual(@as(u32, 38), b.code_len);
    try std.testing.expectEqual(@as(u32, 7), b.label_len);
    try expectLabel(b, 0, 1, 0);
    try expectLabel(b, 1, 1, 38);
    try expectLabel(b, 2, 0, 33);
    try expectLabel(b, 3, 1, 38);
    try expectLabel(b, 4, 1, 24);
    try expectLabel(b, 5, 2, 30);
    try expectLabel(b, 6, 0, 33);
    try std.testing.expect(b.label_slots[0].flags.backward_target);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 6, 30, 33 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g3: epilogue after plain statement" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("null;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);
    try P.v2EmitPlainTailForTest(&h.state);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.return_undef, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 3), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    try std.testing.expectEqual(@as(i64, 2), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 2 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g3: epilogue after terminal" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("throw null;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);
    try P.v2EmitPlainTailForTest(&h.state);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.throw, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 2), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    try std.testing.expectEqual(@as(i64, 1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g3: epilogue after loop merge" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("while (true) ;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);
    try P.v2EmitPlainTailForTest(&h.state);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.goto, .size = 5, .label = 0 },
        .{ .op = qop.return_undef, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 12), b.code_len);
    try std.testing.expectEqual(@as(u32, 4), b.label_len);
    try expectLabel(b, 0, 1, 0);
    try expectLabel(b, 1, 1, 11);
    try expectLabel(b, 2, 0, 6);
    try expectLabel(b, 3, 0, 11);
    try std.testing.expect(b.label_slots[0].flags.backward_target);
    try std.testing.expectEqual(@as(i64, 11), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 6, 11 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g3: plain return dead epilogue" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("return;");
    // Statement-entry harness runs outside a function body; return needs the qjs return-allowed depth.
    h.state.return_depth = 1;
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try std.testing.expectEqual(@as(u32, 1), b.code_len);
    try P.v2EmitPlainTailForTest(&h.state);

    try expectV2Stream(b, &.{
        .{ .op = qop.return_undef, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 1), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    try std.testing.expectEqual(@as(i64, 0), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{0});
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g3: return with value" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("return null;");
    // Statement-entry harness runs outside a function body; return needs the qjs return-allowed depth.
    h.state.return_depth = 1;
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.@"return", .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 2), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    try std.testing.expectEqual(@as(i64, 1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g4: classic for splices update after body" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("for (; false; null) ;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 0 },
    });
    try std.testing.expectEqual(@as(u32, 13), b.code_len);
    try std.testing.expectEqual(@as(u32, 4), b.label_len);
    try expectLabel(b, 0, 1, 0);
    try expectLabel(b, 1, 1, 13);
    // continue label binds BEFORE the spliced update block.
    try expectLabel(b, 2, 0, 6);
    try expectLabel(b, 3, 0, 13);
    try std.testing.expect(b.label_slots[0].flags.backward_target);
    try std.testing.expectEqual(@as(u32, 0), b.atom_len);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    // Legacy moves only the update's code/atoms; its detached source slots at
    // 6 and 7 are intentionally absent from the final parser ledger.
    try expectSourceOffsets(b, &.{ 0, 0, 1, 8 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g4: classic for shifts detached conditional labels" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("for (; false; true ? null : false) ;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.push_true, .size = 1 },
        // Detached jump operands keep their original function-global LabelIds.
        .{ .op = qop.if_false, .size = 5, .label = 2 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 3 },
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 0 },
    });
    try std.testing.expectEqual(@as(u32, 25), b.code_len);
    try std.testing.expectEqual(@as(u32, 6), b.label_len);
    try expectLabel(b, 0, 1, 0);
    try expectLabel(b, 1, 1, 25);
    // Both conditional-expression binds move by the splice base of six bytes.
    try expectLabel(b, 2, 1, 18);
    try expectLabel(b, 3, 1, 19);
    // continue label binds BEFORE the spliced conditional update block.
    try expectLabel(b, 4, 0, 6);
    try expectLabel(b, 5, 0, 25);
    try std.testing.expect(b.label_slots[0].flags.backward_target);
    try std.testing.expectEqual(@as(u32, 0), b.atom_len);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    // Every marker inside the detached conditional update is discarded by
    // the legacy truncate+splice contract; the loop-edge marker remains.
    try expectSourceOffsets(b, &.{ 0, 0, 1, 20 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g4: classic for splices update after break" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("for (; false; null) break;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.goto, .size = 5, .label = 3 },
        // The detached update is spliced after the body's break goto.
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 0 },
    });
    try std.testing.expectEqual(@as(u32, 18), b.code_len);
    try std.testing.expectEqual(@as(u32, 4), b.label_len);
    try expectLabel(b, 0, 1, 0);
    try expectLabel(b, 1, 1, 18);
    try expectLabel(b, 2, 0, 11);
    try expectLabel(b, 3, 1, 18);
    try std.testing.expect(b.label_slots[0].flags.backward_target);
    try std.testing.expectEqual(@as(u32, 0), b.atom_len);
    try std.testing.expectEqual(@as(i64, -1), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 0, 1, 13 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g4: plain field assignment rewinds getter" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("true.b = null;");
    defer h.deinit();

    const field_atom = try h.rt.atoms.internString("b");
    defer h.rt.atoms.free(field_atom);

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        // v2GetLValue removes get_field before the RHS is emitted.
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.insert2, .size = 1 },
        .{ .op = qop.put_field, .size = 5, .atom = field_atom },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 9), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    // The getter's retained atom is transferred into the setter ledger entry.
    try std.testing.expectEqual(@as(u32, 1), b.atom_len);
    try std.testing.expectEqual(field_atom, b.atom_operands[0]);
    try std.testing.expectEqual(@as(i64, 8), b.last_opcode_pos);
    // truncateTail drops the removed getter's source marker; null reuses offset 1.
    try expectSourceOffsets(b, &.{ 0, 1 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g4: compound field assignment reemits getter" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("true.b += null;");
    defer h.deinit();

    const field_atom = try h.rt.atoms.internString("b");
    defer h.rt.atoms.free(field_atom);

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        // keep=true re-emits get_field2 without the rewound getter's marker.
        .{ .op = qop.get_field2, .size = 5, .atom = field_atom },
        .{ .op = qop.null, .size = 1 },
        // The compound arithmetic op is pinned to the += source event.
        .{ .op = qop.add, .size = 1 },
        .{ .op = qop.insert2, .size = 1 },
        .{ .op = qop.put_field, .size = 5, .atom = field_atom },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 15), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    try std.testing.expectEqual(@as(u32, 2), b.atom_len);
    try std.testing.expectEqual(field_atom, b.atom_operands[0]);
    try std.testing.expectEqual(field_atom, b.atom_operands[1]);
    try std.testing.expectEqual(@as(i64, 14), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 6, 7 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g4: plain array element assignment rewinds getter" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("true[false] = null;");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.push_false, .size = 1 },
        // v2GetLValue removes get_array_el and leaves base/key on the stack.
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.insert3, .size = 1 },
        .{ .op = qop.put_array_el, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 6), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    try std.testing.expectEqual(@as(u32, 0), b.atom_len);
    try std.testing.expectEqual(@as(i64, 5), b.last_opcode_pos);
    // The removed getter marker is replaced by the RHS marker at offset 2.
    try expectSourceOffsets(b, &.{ 0, 1, 2 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g4: postfix field update preserves old value" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("true.b++;");
    defer h.deinit();

    const field_atom = try h.rt.atoms.internString("b");
    defer h.rt.atoms.free(field_atom);

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.get_field2, .size = 5, .atom = field_atom },
        // The postfix update is pinned to the ++ source event.
        .{ .op = qop.post_inc, .size = 1 },
        .{ .op = qop.perm3, .size = 1 },
        .{ .op = qop.put_field, .size = 5, .atom = field_atom },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 14), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    try std.testing.expectEqual(@as(u32, 2), b.atom_len);
    try std.testing.expectEqual(field_atom, b.atom_operands[0]);
    try std.testing.expectEqual(field_atom, b.atom_operands[1]);
    try std.testing.expectEqual(@as(i64, 13), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 6 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g4: prefix array element update preserves new value" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("++true[false];");
    defer h.deinit();

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.get_array_el3, .size = 1 },
        // The prefix update is pinned to the leading ++ source event.
        .{ .op = qop.inc, .size = 1 },
        .{ .op = qop.insert3, .size = 1 },
        .{ .op = qop.put_array_el, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 7), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    try std.testing.expectEqual(@as(u32, 0), b.atom_len);
    try std.testing.expectEqual(@as(i64, 6), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 3 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);
}

test "compiler_v2.s2g4: minimal class expression and default constructor" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("(class {});");
    defer h.deinit();

    const empty_atom = try h.rt.atoms.internString("");
    defer h.rt.atoms.free(empty_atom);
    const fields_atom = try h.rt.atoms.internString("<class_fields_init>");
    defer h.rt.atoms.free(fields_atom);

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.set_loc_uninitialized, .size = 3 },
        .{ .op = qop.push_const, .size = 5 },
        .{ .op = qop.define_class, .size = 6, .atom = empty_atom },
        // Empty class body contributes an empty detached runtime segment.
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.put_loc_check_init, .size = 3 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 21), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    try std.testing.expectEqual(@as(u32, 1), b.atom_len);
    try std.testing.expectEqual(empty_atom, b.atom_operands[0]);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, b.code[5..9], .little));
    try std.testing.expectEqual(@as(u8, 0), b.code[14]);
    try std.testing.expectEqual(@as(i64, 20), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 4, 9, 15, 16, 19 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);

    try std.testing.expectEqual(@as(usize, 1), h.state.function_def.child_list.len);
    try std.testing.expectEqual(empty_atom, h.state.function_def.child_list[0].func_name);
    try std.testing.expectEqual(@as(i32, 0), h.state.function_def.child_list[0].parent_cpool_idx);
    const ctor = h.childBuilder(0);
    try expectV2Stream(ctor, &.{
        .{ .op = qop.check_ctor, .size = 1 },
        .{ .op = qop.enter_scope, .size = 3 },
        .{ .op = qop.scope_get_var, .size = 7, .atom = fields_atom },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 0 },
        .{ .op = qop.get_loc, .size = 3 },
        .{ .op = qop.swap, .size = 1 },
        .{ .op = qop.call_method, .size = 3 },
        // emitClassFieldInitCall binds its skip target at the shared drop.
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.return_undef, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 26), ctor.code_len);
    try std.testing.expectEqual(@as(u32, 1), ctor.label_len);
    try expectLabel(ctor, 0, 1, 24);
    try std.testing.expectEqual(@as(u32, 1), ctor.atom_len);
    try std.testing.expectEqual(fields_atom, ctor.atom_operands[0]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, ctor.code[22..24], .little));
    try std.testing.expectEqual(@as(i64, 25), ctor.last_opcode_pos);
    try expectRelocIntegrity(ctor);
    try expectSourceOrder(ctor);
}

test "compiler_v2.s2g4: class declaration stores local binding" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("class C {}");
    defer h.deinit();

    const class_atom = try h.rt.atoms.internString("C");
    defer h.rt.atoms.free(class_atom);
    const fields_atom = try h.rt.atoms.internString("<class_fields_init>");
    defer h.rt.atoms.free(fields_atom);

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.set_loc_uninitialized, .size = 3 },
        .{ .op = qop.push_const, .size = 5 },
        .{ .op = qop.define_class, .size = 6, .atom = class_atom },
        .{ .op = qop.swap, .size = 1 },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.put_loc_check_init, .size = 3 },
        .{ .op = qop.swap, .size = 1 },
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.put_loc_check_init, .size = 3 },
        .{ .op = qop.drop, .size = 1 },
        // Statement-entry parsing uses a containing local, so the declaration tail is set_loc + drop.
        .{ .op = qop.set_loc, .size = 3 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 30), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    try std.testing.expectEqual(@as(u32, 1), b.atom_len);
    try std.testing.expectEqual(class_atom, b.atom_operands[0]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, b.code[2..4], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, b.code[5..9], .little));
    try std.testing.expectEqual(@as(u8, 0), b.code[14]);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, b.code[27..29], .little));
    try std.testing.expectEqual(@as(i64, 29), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 4, 9, 15, 16, 17, 20, 21, 22, 25, 26, 29 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);

    try std.testing.expectEqual(@as(usize, 1), h.state.function_def.child_list.len);
    try std.testing.expectEqual(class_atom, h.state.function_def.child_list[0].func_name);
    const ctor = h.childBuilder(0);
    try expectV2Stream(ctor, &.{
        .{ .op = qop.check_ctor, .size = 1 },
        .{ .op = qop.enter_scope, .size = 3 },
        .{ .op = qop.scope_get_var, .size = 7, .atom = fields_atom },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 0 },
        .{ .op = qop.get_loc, .size = 3 },
        .{ .op = qop.swap, .size = 1 },
        .{ .op = qop.call_method, .size = 3 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.return_undef, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 26), ctor.code_len);
    try std.testing.expectEqual(@as(u32, 1), ctor.label_len);
    try expectLabel(ctor, 0, 1, 24);
    try std.testing.expectEqual(@as(u32, 1), ctor.atom_len);
    try std.testing.expectEqual(fields_atom, ctor.atom_operands[0]);
    try std.testing.expectEqual(@as(i64, 25), ctor.last_opcode_pos);
    try expectRelocIntegrity(ctor);
    try expectSourceOrder(ctor);
}

test "compiler_v2.s2g4: named class method splices runtime definition" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("(class { m() { null; } });");
    defer h.deinit();

    const empty_atom = try h.rt.atoms.internString("");
    defer h.rt.atoms.free(empty_atom);
    const method_atom = try h.rt.atoms.internString("m");
    defer h.rt.atoms.free(method_atom);
    const fields_atom = try h.rt.atoms.internString("<class_fields_init>");
    defer h.rt.atoms.free(fields_atom);

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.set_loc_uninitialized, .size = 3 },
        .{ .op = qop.push_const, .size = 5 },
        .{ .op = qop.define_class, .size = 6, .atom = empty_atom },
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.put_loc_check_init, .size = 3 },
        // parseClass splices the method closure and definition after define_class setup.
        .{ .op = qop.fclosure8, .size = 2 },
        .{ .op = qop.define_method, .size = 6, .atom = method_atom },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 29), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    try std.testing.expectEqual(@as(u32, 2), b.atom_len);
    try std.testing.expectEqual(empty_atom, b.atom_operands[0]);
    try std.testing.expectEqual(method_atom, b.atom_operands[1]);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, b.code[5..9], .little));
    try std.testing.expectEqual(@as(u8, 0), b.code[20]);
    try std.testing.expectEqual(@as(u8, 0), b.code[26]);
    try std.testing.expectEqual(@as(i64, 28), b.last_opcode_pos);
    // Runtime method markers at 19/21 belong to the detached class segment;
    // legacy moves the instructions and atoms but not those source slots.
    try expectSourceOffsets(b, &.{ 0, 1, 4, 9, 15, 16, 27 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);

    try std.testing.expectEqual(@as(usize, 2), h.state.function_def.child_list.len);
    try std.testing.expectEqual(@as(i32, 0), h.state.function_def.child_list[0].parent_cpool_idx);
    const method = h.childBuilder(0);
    try expectV2Stream(method, &.{
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.return_undef, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 3), method.code_len);
    try std.testing.expectEqual(@as(u32, 0), method.label_len);
    try std.testing.expectEqual(@as(u32, 0), method.atom_len);
    try std.testing.expectEqual(@as(i64, 2), method.last_opcode_pos);
    try expectRelocIntegrity(method);
    try expectSourceOrder(method);

    try std.testing.expectEqual(@as(i32, 1), h.state.function_def.child_list[1].parent_cpool_idx);
    const ctor = h.childBuilder(1);
    try expectV2Stream(ctor, &.{
        .{ .op = qop.check_ctor, .size = 1 },
        .{ .op = qop.enter_scope, .size = 3 },
        .{ .op = qop.scope_get_var, .size = 7, .atom = fields_atom },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 0 },
        .{ .op = qop.get_loc, .size = 3 },
        .{ .op = qop.swap, .size = 1 },
        .{ .op = qop.call_method, .size = 3 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.return_undef, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 26), ctor.code_len);
    try std.testing.expectEqual(@as(u32, 1), ctor.label_len);
    try expectLabel(ctor, 0, 1, 24);
    try std.testing.expectEqual(@as(u32, 1), ctor.atom_len);
    try std.testing.expectEqual(fields_atom, ctor.atom_operands[0]);
    try std.testing.expectEqual(@as(i64, 25), ctor.last_opcode_pos);
    try expectRelocIntegrity(ctor);
    try expectSourceOrder(ctor);
}

test "compiler_v2.s2g4: explicit constructor rolls back parent closure" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("(class { constructor() { null; } });");
    defer h.deinit();

    const empty_atom = try h.rt.atoms.internString("");
    defer h.rt.atoms.free(empty_atom);

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.set_loc_uninitialized, .size = 3 },
        // The explicit constructor closure was rolled back; push_const names its cpool slot directly.
        .{ .op = qop.push_const, .size = 5 },
        .{ .op = qop.define_class, .size = 6, .atom = empty_atom },
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.put_loc_check_init, .size = 3 },
        // The detached class-body runtime segment is empty after constructor rollback.
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 21), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    try std.testing.expectEqual(@as(u32, 1), b.atom_len);
    try std.testing.expectEqual(empty_atom, b.atom_operands[0]);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, b.code[5..9], .little));
    try std.testing.expectEqual(@as(i64, 20), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 4, 9, 15, 16, 19 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);

    try std.testing.expectEqual(@as(usize, 1), h.state.function_def.child_list.len);
    try std.testing.expectEqual(@as(i32, 0), h.state.function_def.child_list[0].parent_cpool_idx);
    const ctor = h.childBuilder(0);
    try expectV2Stream(ctor, &.{
        // parseFunctionParamsAndBody emits check_ctor before the explicit body.
        .{ .op = qop.check_ctor, .size = 1 },
        .{ .op = qop.get_var, .size = 3 },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 0 },
        .{ .op = qop.get_var, .size = 3 },
        .{ .op = qop.swap, .size = 1 },
        .{ .op = qop.call_method, .size = 3 },
        // emitClassFieldInitCall binds the skip target at this drop.
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.return_undef, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 21), ctor.code_len);
    try std.testing.expectEqual(@as(u32, 1), ctor.label_len);
    try expectLabel(ctor, 0, 1, 17);
    try std.testing.expectEqual(@as(u32, 0), ctor.atom_len);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, ctor.code[15..17], .little));
    try std.testing.expectEqual(@as(i64, 20), ctor.last_opcode_pos);
    try expectRelocIntegrity(ctor);
    try expectSourceOrder(ctor);
}

test "compiler_v2.s2g4: derived default constructor returns checked this" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("(class extends null {});");
    defer h.deinit();

    const empty_atom = try h.rt.atoms.internString("");
    defer h.rt.atoms.free(empty_atom);
    const fields_atom = try h.rt.atoms.internString("<class_fields_init>");
    defer h.rt.atoms.free(fields_atom);

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        // Heritage null is already on the stack, so the base-class undefined is absent.
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.set_loc_uninitialized, .size = 3 },
        .{ .op = qop.push_const, .size = 5 },
        .{ .op = qop.define_class, .size = 6, .atom = empty_atom },
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.put_loc_check_init, .size = 3 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 21), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    try std.testing.expectEqual(@as(u32, 1), b.atom_len);
    try std.testing.expectEqual(empty_atom, b.atom_operands[0]);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, b.code[5..9], .little));
    try std.testing.expectEqual(@as(u8, 1), b.code[14]);
    try std.testing.expectEqual(@as(i64, 20), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 4, 9, 15, 16, 19 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);

    try std.testing.expectEqual(@as(usize, 1), h.state.function_def.child_list.len);
    const ctor = h.childBuilder(0);
    try expectV2Stream(ctor, &.{
        // Default derived constructors use init_ctor instead of the base check_ctor entry.
        .{ .op = qop.enter_scope, .size = 3 },
        .{ .op = qop.init_ctor, .size = 1 },
        .{ .op = qop.put_loc_check_init, .size = 3 },
        .{ .op = qop.scope_get_var, .size = 7, .atom = fields_atom },
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 0 },
        .{ .op = qop.get_loc_check, .size = 3 },
        .{ .op = qop.swap, .size = 1 },
        .{ .op = qop.call_method, .size = 3 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.get_loc_checkthis, .size = 3 },
        .{ .op = qop.@"return", .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 32), ctor.code_len);
    try std.testing.expectEqual(@as(u32, 1), ctor.label_len);
    try expectLabel(ctor, 0, 1, 27);
    try std.testing.expectEqual(@as(u32, 1), ctor.atom_len);
    try std.testing.expectEqual(fields_atom, ctor.atom_operands[0]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, ctor.code[25..27], .little));
    try std.testing.expectEqual(@as(i64, 31), ctor.last_opcode_pos);
    try expectRelocIntegrity(ctor);
    try expectSourceOrder(ctor);
}

test "compiler_v2.s2g4: instance field uses dormant brand prologue" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("(class { x = null; });");
    defer h.deinit();

    const empty_atom = try h.rt.atoms.internString("");
    defer h.rt.atoms.free(empty_atom);
    const fields_atom = try h.rt.atoms.internString("<class_fields_init>");
    defer h.rt.atoms.free(fields_atom);
    const home_atom = try h.rt.atoms.internString("<home_object>");
    defer h.rt.atoms.free(home_atom);
    const field_atom = try h.rt.atoms.internString("x");
    defer h.rt.atoms.free(field_atom);

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.set_loc_uninitialized, .size = 3 },
        .{ .op = qop.push_const, .size = 5 },
        .{ .op = qop.define_class, .size = 6, .atom = empty_atom },
        // The parent runtime segment is empty; install the fields child directly.
        .{ .op = qop.fclosure8, .size = 2 },
        .{ .op = qop.set_home_object, .size = 1 },
        .{ .op = qop.put_loc_check_init, .size = 3 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 23), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    try std.testing.expectEqual(@as(u32, 1), b.atom_len);
    try std.testing.expectEqual(empty_atom, b.atom_operands[0]);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, b.code[5..9], .little));
    try std.testing.expectEqual(@as(u8, 0), b.code[16]);
    try std.testing.expectEqual(@as(i64, 22), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 4, 9, 15, 17, 18, 21 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);

    try std.testing.expectEqual(@as(usize, 2), h.state.function_def.child_list.len);
    try std.testing.expectEqual(fields_atom, h.state.function_def.child_list[0].func_name);
    try std.testing.expectEqual(@as(i32, 0), h.state.function_def.child_list[0].parent_cpool_idx);
    try std.testing.expectEqual(@as(i32, 1), h.state.function_def.child_list[1].parent_cpool_idx);
    const fields = h.childBuilder(0);
    try expectV2Stream(fields, &.{
        // createClassFieldsInitFunction starts with a dormant, patchable brand test.
        .{ .op = qop.push_false, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 0 },
        .{ .op = qop.push_this, .size = 1 },
        .{ .op = qop.scope_get_var, .size = 7, .atom = home_atom },
        .{ .op = qop.add_brand, .size = 1 },
        // The dormant-prologue skip target binds before the field initializer.
        .{ .op = qop.push_this, .size = 1 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.define_field, .size = 5, .atom = field_atom },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.return_undef, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 24), fields.code_len);
    try std.testing.expectEqual(@as(u32, 1), fields.label_len);
    try expectLabel(fields, 0, 1, 15);
    try std.testing.expectEqual(@as(u32, 2), fields.atom_len);
    try std.testing.expectEqual(home_atom, fields.atom_operands[0]);
    try std.testing.expectEqual(field_atom, fields.atom_operands[1]);
    try std.testing.expectEqual(@as(i64, 23), fields.last_opcode_pos);
    try expectRelocIntegrity(fields);
    try expectSourceOrder(fields);
}

test "compiler_v2.s2g4: private method patches instance brand prologue" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("(class { #m() {} });");
    defer h.deinit();

    const empty_atom = try h.rt.atoms.internString("");
    defer h.rt.atoms.free(empty_atom);
    const fields_atom = try h.rt.atoms.internString("<class_fields_init>");
    defer h.rt.atoms.free(fields_atom);
    const home_atom = try h.rt.atoms.internString("<home_object>");
    defer h.rt.atoms.free(home_atom);

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try std.testing.expectEqual(@as(u32, 2), b.atom_len);
    const private_atom = b.atom_operands[1];
    try std.testing.expectEqualStrings("#m", h.rt.atoms.name(private_atom).?);
    try expectV2Stream(b, &.{
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.set_loc_uninitialized, .size = 3 },
        .{ .op = qop.push_const, .size = 5 },
        .{ .op = qop.define_class, .size = 6, .atom = empty_atom },
        .{ .op = qop.fclosure8, .size = 2 },
        .{ .op = qop.set_home_object, .size = 1 },
        .{ .op = qop.put_loc_check_init, .size = 3 },
        // emitClassPrivateBrands brands the prototype before spliced private code runs.
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.swap, .size = 1 },
        .{ .op = qop.add_brand, .size = 1 },
        // parseClassElement's deferred private-method sequence.
        .{ .op = qop.fclosure8, .size = 2 },
        .{ .op = qop.set_home_object, .size = 1 },
        .{ .op = qop.set_name, .size = 5, .atom = private_atom },
        .{ .op = qop.put_var_init, .size = 3 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 38), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    // The root ledger exactly covers define_class's empty name and set_name's private symbol.
    try std.testing.expectEqual(empty_atom, b.atom_operands[0]);
    try std.testing.expectEqual(private_atom, b.atom_operands[1]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, b.code[5..9], .little));
    try std.testing.expectEqual(@as(u8, 1), b.code[16]);
    try std.testing.expectEqual(@as(u8, 0), b.code[26]);
    try std.testing.expectEqual(@as(i64, 37), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 4, 9, 15, 17, 18, 21, 22, 23, 24, 36 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);

    try std.testing.expectEqual(@as(usize, 3), h.state.function_def.child_list.len);
    try std.testing.expectEqual(@as(i32, 0), h.state.function_def.child_list[0].parent_cpool_idx);
    const method = h.childBuilder(0);
    try expectV2Stream(method, &.{
        .{ .op = qop.return_undef, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 1), method.code_len);
    try std.testing.expectEqual(@as(u32, 0), method.label_len);
    try std.testing.expectEqual(@as(u32, 0), method.atom_len);
    try std.testing.expectEqual(@as(i64, 0), method.last_opcode_pos);
    try expectRelocIntegrity(method);
    try expectSourceOrder(method);

    try std.testing.expectEqual(fields_atom, h.state.function_def.child_list[1].func_name);
    try std.testing.expectEqual(@as(i32, 1), h.state.function_def.child_list[1].parent_cpool_idx);
    try std.testing.expectEqual(@as(i32, 2), h.state.function_def.child_list[2].parent_cpool_idx);
    const fields = h.childBuilder(1);
    try expectV2Stream(fields, &.{
        // markPrivateBrandNeeded patches the dormant first opcode in place.
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 0 },
        .{ .op = qop.push_this, .size = 1 },
        .{ .op = qop.scope_get_var, .size = 7, .atom = home_atom },
        .{ .op = qop.add_brand, .size = 1 },
        .{ .op = qop.return_undef, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 16), fields.code_len);
    try std.testing.expectEqual(@as(u32, 1), fields.label_len);
    try expectLabel(fields, 0, 1, 15);
    try std.testing.expectEqual(@as(u32, 1), fields.atom_len);
    try std.testing.expectEqual(home_atom, fields.atom_operands[0]);
    try std.testing.expectEqual(@as(i64, 15), fields.last_opcode_pos);
    try expectRelocIntegrity(fields);
    try expectSourceOrder(fields);
}

test "compiler_v2.s2g4: static block nests closure in static initializer" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("(class { static { null; } });");
    defer h.deinit();

    const empty_atom = try h.rt.atoms.internString("");
    defer h.rt.atoms.free(empty_atom);
    const fields_atom = try h.rt.atoms.internString("<class_fields_init>");
    defer h.rt.atoms.free(fields_atom);

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.set_loc_uninitialized, .size = 3 },
        .{ .op = qop.push_const, .size = 5 },
        .{ .op = qop.define_class, .size = 6, .atom = empty_atom },
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.put_loc_check_init, .size = 3 },
        .{ .op = qop.drop, .size = 1 },
        // emitClassStaticInitCall invokes the separate static-init child immediately.
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.fclosure8, .size = 2 },
        .{ .op = qop.set_home_object, .size = 1 },
        .{ .op = qop.call_method, .size = 3 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 29), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    try std.testing.expectEqual(@as(u32, 1), b.atom_len);
    try std.testing.expectEqual(empty_atom, b.atom_operands[0]);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, b.code[5..9], .little));
    try std.testing.expectEqual(@as(u8, 0), b.code[22]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, b.code[25..27], .little));
    try std.testing.expectEqual(@as(i64, 28), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 4, 9, 15, 16, 19, 20, 21, 23, 24, 27 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);

    try std.testing.expectEqual(@as(usize, 2), h.state.function_def.child_list.len);
    try std.testing.expectEqual(fields_atom, h.state.function_def.child_list[0].func_name);
    try std.testing.expectEqual(@as(i32, 0), h.state.function_def.child_list[0].parent_cpool_idx);
    try std.testing.expectEqual(@as(i32, 1), h.state.function_def.child_list[1].parent_cpool_idx);
    const static_init = h.childBuilder(0);
    try expectV2Stream(static_init, &.{
        // Static initializers deliberately have no instance-brand prologue.
        .{ .op = qop.fclosure8, .size = 2 },
        .{ .op = qop.get_var, .size = 3 },
        .{ .op = qop.swap, .size = 1 },
        .{ .op = qop.call_method, .size = 3 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.return_undef, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 11), static_init.code_len);
    try std.testing.expectEqual(@as(u32, 0), static_init.label_len);
    try std.testing.expectEqual(@as(u32, 0), static_init.atom_len);
    try std.testing.expectEqual(@as(u8, 0), static_init.code[1]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, static_init.code[7..9], .little));
    try std.testing.expectEqual(@as(i64, 10), static_init.last_opcode_pos);
    try expectRelocIntegrity(static_init);
    try expectSourceOrder(static_init);

    try std.testing.expectEqual(@as(usize, 1), h.state.function_def.child_list[0].child_list.len);
    try std.testing.expectEqual(@as(i32, 0), h.state.function_def.child_list[0].child_list[0].parent_cpool_idx);
    const block = h.grandchildBuilder(0, 0);
    try expectV2Stream(block, &.{
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.return_undef, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 3), block.code_len);
    try std.testing.expectEqual(@as(u32, 0), block.label_len);
    try std.testing.expectEqual(@as(u32, 0), block.atom_len);
    try std.testing.expectEqual(@as(i64, 2), block.last_opcode_pos);
    try expectRelocIntegrity(block);
    try expectSourceOrder(block);
}

test "compiler_v2.s2g4: static field emits through static initializer" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("(class { static x = null; });");
    defer h.deinit();

    const empty_atom = try h.rt.atoms.internString("");
    defer h.rt.atoms.free(empty_atom);
    const fields_atom = try h.rt.atoms.internString("<class_fields_init>");
    defer h.rt.atoms.free(fields_atom);
    const field_atom = try h.rt.atoms.internString("x");
    defer h.rt.atoms.free(field_atom);

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.set_loc_uninitialized, .size = 3 },
        .{ .op = qop.push_const, .size = 5 },
        .{ .op = qop.define_class, .size = 6, .atom = empty_atom },
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.put_loc_check_init, .size = 3 },
        .{ .op = qop.drop, .size = 1 },
        // The static-field child is installed as the class's immediate static-init call.
        .{ .op = qop.dup, .size = 1 },
        .{ .op = qop.fclosure8, .size = 2 },
        .{ .op = qop.set_home_object, .size = 1 },
        .{ .op = qop.call_method, .size = 3 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 29), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    try std.testing.expectEqual(@as(u32, 1), b.atom_len);
    try std.testing.expectEqual(empty_atom, b.atom_operands[0]);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, b.code[5..9], .little));
    try std.testing.expectEqual(@as(u8, 0), b.code[22]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, b.code[25..27], .little));
    try std.testing.expectEqual(@as(i64, 28), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 4, 9, 15, 16, 19, 20, 21, 23, 24, 27 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);

    try std.testing.expectEqual(@as(usize, 2), h.state.function_def.child_list.len);
    try std.testing.expectEqual(fields_atom, h.state.function_def.child_list[0].func_name);
    try std.testing.expectEqual(@as(i32, 0), h.state.function_def.child_list[0].parent_cpool_idx);
    try std.testing.expectEqual(@as(i32, 1), h.state.function_def.child_list[1].parent_cpool_idx);
    const static_init = h.childBuilder(0);
    try expectV2Stream(static_init, &.{
        // Static initializer children omit the instance-brand prologue entirely.
        .{ .op = qop.get_var, .size = 3 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.define_field, .size = 5, .atom = field_atom },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.return_undef, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 11), static_init.code_len);
    try std.testing.expectEqual(@as(u32, 0), static_init.label_len);
    try std.testing.expectEqual(@as(u32, 1), static_init.atom_len);
    try std.testing.expectEqual(field_atom, static_init.atom_operands[0]);
    try std.testing.expectEqual(@as(i64, 10), static_init.last_opcode_pos);
    try expectRelocIntegrity(static_init);
    try expectSourceOrder(static_init);
}

test "compiler_v2.s2g4: computed method splices key and closure" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("(class { [true]() {} });");
    defer h.deinit();

    const empty_atom = try h.rt.atoms.internString("");
    defer h.rt.atoms.free(empty_atom);

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.set_loc_uninitialized, .size = 3 },
        .{ .op = qop.push_const, .size = 5 },
        .{ .op = qop.define_class, .size = 6, .atom = empty_atom },
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.put_loc_check_init, .size = 3 },
        // parseClassComputedName and parseClassElementFunction move together in the segment.
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.to_propkey, .size = 1 },
        .{ .op = qop.fclosure8, .size = 2 },
        .{ .op = qop.define_method_computed, .size = 2 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 27), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    try std.testing.expectEqual(@as(u32, 1), b.atom_len);
    try std.testing.expectEqual(empty_atom, b.atom_operands[0]);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, b.code[5..9], .little));
    try std.testing.expectEqual(@as(u8, 0), b.code[22]);
    try std.testing.expectEqual(@as(u8, 0), b.code[24]);
    try std.testing.expectEqual(@as(i64, 26), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 4, 9, 15, 16, 25 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);

    try std.testing.expectEqual(@as(usize, 2), h.state.function_def.child_list.len);
    try std.testing.expectEqual(@as(i32, 0), h.state.function_def.child_list[0].parent_cpool_idx);
    try std.testing.expectEqual(@as(i32, 1), h.state.function_def.child_list[1].parent_cpool_idx);
    const method = h.childBuilder(0);
    try expectV2Stream(method, &.{
        .{ .op = qop.return_undef, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 1), method.code_len);
    try std.testing.expectEqual(@as(u32, 0), method.label_len);
    try std.testing.expectEqual(@as(u32, 0), method.atom_len);
    try std.testing.expectEqual(@as(i64, 0), method.last_opcode_pos);
    try expectRelocIntegrity(method);
    try expectSourceOrder(method);
}

test "compiler_v2.s2g4: getter child keeps return terminal" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("(class { get g() { return null; } });");
    defer h.deinit();

    const empty_atom = try h.rt.atoms.internString("");
    defer h.rt.atoms.free(empty_atom);
    const getter_atom = try h.rt.atoms.internString("g");
    defer h.rt.atoms.free(getter_atom);

    try P.parseStatementOrDecl(&h.state, P.DeclMask{ .func = true, .func_with_label = true, .other = true });
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const b = h.builder();
    try expectV2Stream(b, &.{
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.set_loc_uninitialized, .size = 3 },
        .{ .op = qop.push_const, .size = 5 },
        .{ .op = qop.define_class, .size = 6, .atom = empty_atom },
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.put_loc_check_init, .size = 3 },
        // The accessor closure and define_method flag travel in the detached segment.
        .{ .op = qop.fclosure8, .size = 2 },
        .{ .op = qop.define_method, .size = 6, .atom = getter_atom },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 29), b.code_len);
    try std.testing.expectEqual(@as(u32, 0), b.label_len);
    try std.testing.expectEqual(@as(u32, 2), b.atom_len);
    try std.testing.expectEqual(empty_atom, b.atom_operands[0]);
    try std.testing.expectEqual(getter_atom, b.atom_operands[1]);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, b.code[5..9], .little));
    try std.testing.expectEqual(@as(u8, 0), b.code[20]);
    try std.testing.expectEqual(@as(u8, 1), b.code[26]);
    try std.testing.expectEqual(@as(i64, 28), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 4, 9, 15, 16, 27 });
    try expectRelocIntegrity(b);
    try expectSourceOrder(b);

    try std.testing.expectEqual(@as(usize, 2), h.state.function_def.child_list.len);
    try std.testing.expectEqual(@as(i32, 0), h.state.function_def.child_list[0].parent_cpool_idx);
    try std.testing.expectEqual(@as(i32, 1), h.state.function_def.child_list[1].parent_cpool_idx);
    const getter = h.childBuilder(0);
    try expectV2Stream(getter, &.{
        .{ .op = qop.null, .size = 1 },
        // S2-G3 keeps the explicit return terminal; no return_undef is appended.
        .{ .op = qop.@"return", .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 2), getter.code_len);
    try std.testing.expectEqual(@as(u32, 0), getter.label_len);
    try std.testing.expectEqual(@as(u32, 0), getter.atom_len);
    try std.testing.expectEqual(@as(i64, 1), getter.last_opcode_pos);
    try expectRelocIntegrity(getter);
    try expectSourceOrder(getter);
}

test "compiler_v2.s3: parsed dead code after break is dropped" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    // Numeric literal emission is outside the migrated v2 parser surface;
    // null keeps the same dead expression-statement shape through v2.
    try h.init("for (;;) { break; null; }");
    defer h.deinit();

    try P.parseStatementOrDecl(
        &h.state,
        P.DeclMask{ .func = true, .func_with_label = true, .other = true },
    );
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const input = h.builder();
    try expectV2Stream(input, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.goto, .size = 5, .label = 3 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 0 },
    });
    try expectLabel(input, 0, 1, 0);
    try expectLabel(input, 1, 1, 18);
    try expectLabel(input, 2, 0, 13);
    try expectLabel(input, 3, 1, 18);

    var product = try resolve_variables.run(&h.function, &h.state.function_def);
    defer product.deinitUncommitted();
    try expectResolvedStream(&product, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.goto, .size = 5, .label = 3 },
    });
    try expectResolvedLabel(&product, 0, 0, 0);
    try expectResolvedLabel(&product, 1, 1, 11);
    try expectResolvedLabel(&product, 2, 0, labels.unbound);
    try expectResolvedLabel(&product, 3, 1, 11);
    try std.testing.expectEqual(@as(u32, 2), product.jump_size);
}

test "compiler_v2.s3: parsed dead-only loop labels stay dead" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("for (;;) { break; continue; }");
    defer h.deinit();

    try P.parseStatementOrDecl(
        &h.state,
        P.DeclMask{ .func = true, .func_with_label = true, .other = true },
    );
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const input = h.builder();
    try expectV2Stream(input, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.goto, .size = 5, .label = 3 },
        .{ .op = qop.goto, .size = 5, .label = 2 },
        .{ .op = qop.goto, .size = 5, .label = 0 },
    });
    try expectLabel(input, 0, 1, 0);
    try expectLabel(input, 1, 1, 21);
    try expectLabel(input, 2, 1, 16);
    try expectLabel(input, 3, 1, 21);

    var product = try resolve_variables.run(&h.function, &h.state.function_def);
    defer product.deinitUncommitted();
    try expectResolvedStream(&product, &.{
        .{ .op = qop.push_true, .size = 1 },
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.goto, .size = 5, .label = 3 },
    });
    // The loop head was passed before dead-code skipping, so it remains bound
    // at output zero even though its only back-edge reference was removed.
    try expectResolvedLabel(&product, 0, 0, 0);
    try expectResolvedLabel(&product, 1, 1, 11);
    try expectResolvedLabel(&product, 2, 0, labels.unbound);
    try expectResolvedLabel(&product, 3, 1, 11);
    try std.testing.expectEqual(@as(u32, 2), product.jump_size);
}

test "compiler_v2.s3: parsed return through finally keeps live gosub" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("try { return; } finally { null; }");
    h.state.return_depth = 1;
    defer h.deinit();

    try P.parseStatementOrDecl(
        &h.state,
        P.DeclMask{ .func = true, .func_with_label = true, .other = true },
    );
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const input = h.builder();
    const expected = [_]ExpectedInsn{
        .{ .op = qop.@"catch", .size = 5, .label = 0 },
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.nip_catch, .size = 1 },
        .{ .op = qop.gosub, .size = 5, .label = 1 },
        .{ .op = qop.@"return", .size = 1 },
        .{ .op = qop.gosub, .size = 5, .label = 1 },
        .{ .op = qop.throw, .size = 1 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.ret, .size = 1 },
    };
    try expectV2Stream(input, &expected);
    try expectLabel(input, 0, 1, 13);
    try expectLabel(input, 1, 2, 19);
    try expectLabel(input, 2, 0, 22);

    var product = try resolve_variables.run(&h.function, &h.state.function_def);
    defer product.deinitUncommitted();
    try expectResolvedStream(&product, &expected);
    try expectResolvedLabel(&product, 0, 1, 13);
    try expectResolvedLabel(&product, 1, 2, 19);
    try expectResolvedLabel(&product, 2, 0, labels.unbound);
    try std.testing.expectEqual(@as(u32, 3), product.jump_size);
}

test "compiler_v2.s3: parsed empty finally removes gosub" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Parse = undefined;
    try h.init("try { return; } finally { }");
    h.state.return_depth = 1;
    defer h.deinit();

    try P.parseStatementOrDecl(
        &h.state,
        P.DeclMask{ .func = true, .func_with_label = true, .other = true },
    );
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);

    const input = h.builder();
    try expectV2Stream(input, &.{
        .{ .op = qop.@"catch", .size = 5, .label = 0 },
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.nip_catch, .size = 1 },
        .{ .op = qop.gosub, .size = 5, .label = 1 },
        .{ .op = qop.@"return", .size = 1 },
        .{ .op = qop.gosub, .size = 5, .label = 1 },
        .{ .op = qop.throw, .size = 1 },
        .{ .op = qop.ret, .size = 1 },
    });
    try expectLabel(input, 0, 1, 13);
    try expectLabel(input, 1, 2, 19);
    try expectLabel(input, 2, 0, 20);

    var product = try resolve_variables.run(&h.function, &h.state.function_def);
    defer product.deinitUncommitted();
    try expectResolvedStream(&product, &.{
        .{ .op = qop.@"catch", .size = 5, .label = 0 },
        .{ .op = qop.undefined, .size = 1 },
        .{ .op = qop.nip_catch, .size = 1 },
        .{ .op = qop.@"return", .size = 1 },
        .{ .op = qop.throw, .size = 1 },
    });
    try expectResolvedLabel(&product, 0, 1, 8);
    try expectResolvedLabel(&product, 1, 0, labels.unbound);
    try expectResolvedLabel(&product, 2, 0, labels.unbound);
    try std.testing.expectEqual(@as(u32, 3), product.jump_size);
}

test "compiler_v2.s3: normalized global binding equals legacy" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;
    try expectRootNormalizedEquivalence("var g = 1; g;", .global);
}

test "compiler_v2.s3: normalized top-level lexical equals legacy" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;
    try expectRootNormalizedEquivalence(
        "let a = 1; a = a + 2; a;",
        .top_level_lexical,
    );
}

test "compiler_v2.s3: normalized block lexical equals legacy" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;
    try expectRootNormalizedEquivalence("{ let b = 2; b; }", .block_lexical);
}

test "compiler_v2.s3: normalized child loc arg indices equal legacy" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;
    try expectChildNormalizedEquivalence(
        "function f(p) { var v; v = p; return v; }",
        .{ .args = 1, .vars = 1 },
    );
}

test "compiler_v2.s3r: normalized dead jump cycle equals legacy exact CFG" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;
    try expectChildNormalizedEquivalence(
        "function f(p) { return p; for (;;) { p = p + 1; } }",
        .{ .args = 1 },
    );
}

test "compiler_v2.s3r: normalized dead forward branch equals legacy exact CFG" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;
    try expectChildNormalizedEquivalence(
        "function f(p) { return p; if (p) { p = 1; } else { p = 2; } }",
        .{ .args = 1 },
    );
}

test "compiler_v2.s3r: normalized assignment after return equals legacy exact CFG" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;
    try expectChildNormalizedEquivalence(
        "function f(p) { return p; p = 1; }",
        .{ .args = 1 },
    );
}

test "compiler_v2.s3r: normalized dead binding events equal legacy exact CFG" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;
    try expectChildNormalizedEquivalence(
        "function f(p) { return p; { let b = 1; b; } }",
        .{ .args = 1 },
    );
    try expectChildNormalizedEquivalence(
        "function f(p) { return p; var v; v = p; }",
        .{ .args = 1, .vars = 1 },
    );
}

fn expectV2ExecutionCompletion(src: []const u8, expected: i32) !void {
    var h: V2Exec = undefined;
    try h.init(src);
    defer h.deinit();
    const result = try v2CompileAndRun(&h);
    defer result.free(h.rt);
    try std.testing.expectEqual(expected, result.asInt32().?);
}

test "compiler_v2.s4: arithmetic executes installed FunctionBytecode" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;
    try expectV2ExecutionCompletion("6 * 7;", 42);
}

test "compiler_v2.s4: if else true arm executes" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;
    try expectV2ExecutionCompletion(
        "let r; if (true) { r = 1; } else { r = 2; } r;",
        1,
    );
}

test "compiler_v2.s4: if else false arm executes" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;
    try expectV2ExecutionCompletion(
        "let r; if (false) { r = 1; } else { r = 2; } r;",
        2,
    );
}

test "compiler_v2.s4: while break executes" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;
    try expectV2ExecutionCompletion(
        "let i = 0; while (true) { i = i + 1; if (i == 3) break; } i;",
        3,
    );
}

test "compiler_v2.s4: for accumulate executes" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;
    try expectV2ExecutionCompletion(
        "let s = 0; for (let k = 0; k < 5; k = k + 1) { s = s + k; } s;",
        10,
    );
}

test "compiler_v2.s4: switch fallthrough executes" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;
    try expectV2ExecutionCompletion(
        "let x = 0; switch (2) { case 1: x = x + 1; case 2: x = x + 10; case 3: x = x + 100; break; default: x = x + 1000; } x;",
        110,
    );
}

test "compiler_v2.s4: try finally value executes" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;
    try expectV2ExecutionCompletion(
        "let t = 0; try { t = 1; } finally { t = t + 10; } t;",
        11,
    );
}

test "compiler_v2.s4: try catch throw executes" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;
    try expectV2ExecutionCompletion(
        "let c = 0; try { throw 5; } catch (e) { c = e + 2; } c;",
        7,
    );
}

test "compiler_v2.s4: nested closure capture executes" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;
    // S3 deliberately leaves function-body hoist instantiation to a later
    // finalization owner (resolve_variables.zig enter_scope arm). Use an
    // explicit function-expression assignment until that documented stub is
    // filled; this still exercises child + grandchild FBs, fclosure, and
    // var_ref capture.
    try expectV2ExecutionCompletion(
        "(function () { let c = 5; let inner = function () { return c + 2; }; return inner(); })();",
        7,
    );
}

test "compiler_v2.s4: labeled break executes" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;
    try expectV2ExecutionCompletion(
        "let n = 0; L: { n = 1; break L; n = 2; } n;",
        1,
    );
}

test "compiler_v2.s4: global var machinery executes" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;
    try expectV2ExecutionCompletion("var g = 4; g + 1;", 5);
}

test "compiler_v2.s4: installed for loop matches the configured default layout" {
    var skip = !P.v2_available;
    _ = &skip;
    if (skip) return error.SkipZigTest;

    var h: V2Exec = undefined;
    try h.init("let s = 0; for (let k = 0; k < 5; k = k + 1) { s = s + k; } s;");
    defer h.deinit();
    const result = try v2CompileAndRun(&h);
    defer result.free(h.rt);
    try std.testing.expectEqual(@as(i32, 10), result.asInt32().?);
    // The production path lowers with `resolve_labels.default_layout`
    // (`-Dzjs_v2_layout`), so assert against that declaration rather than
    // against a hardcoded mode. This test previously pinned `.plain` and was
    // the one place in the suite that silently depended on the old default:
    // it is the same defect class as a gate reporting green about a
    // configuration it never ran, one level down.
    //
    // `installed_short_opcode` is read back off the INSTALLED
    // FunctionBytecode, so it is evidence about emitted bytes rather than
    // about a mode variable. This fixture emits at least one short-form
    // opcode under `.short` and none under `.plain`, which makes the
    // comparison below a statement about which mode actually reached
    // emission.
    const observed_layout: []const u8 = if (h.installed_short_opcode) "short" else "plain";
    switch (resolve_labels.default_layout) {
        .plain => try std.testing.expectEqualStrings("plain", observed_layout),
        .short => try std.testing.expectEqualStrings("short", observed_layout),
    }
    // The `.plain` diagnostic's self-proof, in-suite half. `.plain` survives
    // release only as an A/B instrument, and an instrument that exists in name
    // while being ignored in fact would silently invalidate every diagnostic
    // taken with it. So close the whole chain here, from the option string to
    // the emitted bytes to the string every gate compares:
    //
    //   -Dzjs_v2_layout  ->  resolve_labels.default_layout  ->  emitted
    //   bytecode  ->  config_signature.layout
    //
    // Note the direction: the option string is checked AGAINST the observed
    // emission, not the other way round. A test that asserted `.plain` because
    // `.plain` was the input parameter would pass on a build where the
    // resolver ignores the option entirely.
    try std.testing.expectEqualStrings(build_options.zjs_v2_layout, observed_layout);
    try std.testing.expectEqualStrings(observed_layout, config_signature.layout);
}

test "compiler_v2.p5: FunctionDef owners are inert after the FunctionBytecode escape" {
    var h: V2Exec = undefined;
    try h.init(
        \\var escapeAuditOuter = 1;
        \\function escapeAuditChild(escapeAuditArg) {
        \\    var escapeAuditLocal = escapeAuditArg + escapeAuditOuter;
        \\    return { escapeAuditKey: escapeAuditLocal };
        \\}
        \\escapeAuditChild(2);
    );
    defer h.deinit();

    try h.state.enableReturnCompletion();
    try P.parseProgramStatements(
        &h.state,
        P.DeclMask{ .func = true, .func_with_label = true, .other = true },
    );
    try std.testing.expectEqual(parser_mod.token.TOK_EOF, h.state.token.val);
    try h.state.finalizeEvalReturn();
    try std.testing.expect(h.state.function_def.child_list.len >= 1);

    if (P.v2_available) try attachTranslatedBuilderTree(&h.state.function_def);

    const fb_slice = try bytecode_mod.pipeline_finalize.createFunctionBytecode(
        &h.state.function_def,
        .{ .realm = h.ctx },
    );
    const fb = &fb_slice[0];
    var fb_value = core.JSValue.functionBytecode(&fb.header);
    defer fb_value.free(h.rt);

    try expectFunctionDefInertAfterEscape(&h.state.function_def);

    var owners: PublishedEscapeOwners = .{};
    try expectPublishedFunctionBytecodeOwnersResolve(h.rt, fb, &owners);
    try std.testing.expect(owners.named_args >= 1);
    try std.testing.expect(owners.named_vars >= 1);
    try std.testing.expect(owners.named_closure_vars >= 1);
    // A recursive child count can only become non-zero after the root cpool
    // exposes a FunctionBytecode value.
    try std.testing.expect(owners.child_functions >= 1);
}

test "compiler_v2.p5: escaped atoms outlive compiler teardown" {
    const source =
        \\var o = {};
        \\o.escapeAuditProbeName = 7;
        \\o.escapeAuditProbeName;
    ;

    const rt = try core.JSRuntime.create(std.testing.allocator);
    standard_globals.configureRuntime(rt);
    const ctx = try core.JSContext.create(rt);
    const name_atom = try rt.atoms.internString("compiler_v2-p5-atom-escape");
    var function = bytecode_mod.Bytecode.init(&rt.memory, &rt.atoms, name_atom);
    var lex = parser_mod.Lexer.init(std.testing.allocator, &rt.atoms, source);
    var state = try P.ParseState.initCanonicalRootWithRuntime(rt, &lex, &function);
    state.function_def.is_global_var = true;
    state.top_level_functions_as_children = true;

    {
        const probe = try rt.atoms.internString("escapeAuditProbeName");
        defer rt.atoms.free(probe);
        const baseline = rt.atoms.refCount(probe).?;

        try state.enableReturnCompletion();
        try P.parseProgramStatements(
            &state,
            P.DeclMask{ .func = true, .func_with_label = true, .other = true },
        );
        try std.testing.expectEqual(parser_mod.token.TOK_EOF, state.token.val);
        try state.finalizeEvalReturn();

        var phase1_probe_refs: usize = 0;
        for (state.function_def.atom_operands) |owner| {
            phase1_probe_refs += @intFromBool(owner == probe);
        }
        try std.testing.expectEqual(@as(usize, 2), phase1_probe_refs);
        if (P.v2_available) try attachTranslatedBuilderTree(&state.function_def);

        const fb_slice = try bytecode_mod.pipeline_finalize.createFunctionBytecode(
            &state.function_def,
            .{ .realm = ctx },
        );
        var fb_value = core.JSValue.functionBytecode(&fb_slice[0].header);
        const after_compile = rt.atoms.refCount(probe).?;
        try std.testing.expect(after_compile > baseline);

        // The v2/dual test adapter duplicates every legacy phase-1 atom into
        // its translated builder. v2 publication consumes the builder copy
        // but intentionally leaves the original FunctionDef.atom_operands
        // scratch ledger for state.deinit; legacy lowerLegacyPhase1 instead
        // moves that original ledger into the FB. Account for those two
        // compiler-only refs exactly rather than weakening the FB-owner check.
        const retained_phase1_probe_refs = if (P.v2_available) phase1_probe_refs else 0;
        try std.testing.expectEqual(
            baseline + phase1_probe_refs + retained_phase1_probe_refs,
            after_compile,
        );

        state.deinit(rt);
        lex.deinit();
        function.deinit(rt);

        try std.testing.expectEqual(
            baseline + phase1_probe_refs,
            rt.atoms.refCount(probe).?,
        );
        try std.testing.expect(rt.atoms.name(probe) != null);

        fb_value.free(rt);
        try std.testing.expectEqual(baseline, rt.atoms.refCount(probe).?);
    }

    rt.atoms.free(name_atom);
    ctx.destroy();
    rt.destroy();
}

/// RULE D (CORPUS SKIPS) -- one corpus entry.
///
/// `expect_skip` is an ALLOWLIST BY IDENTITY: this specific snippet, and no
/// other, is permitted not to compile. It is not a tolerance and there is no
/// proportional form of it. The predecessor of this corpus asserted
/// `skipped * 2 <= cases.len`, i.e. up to HALF the corpus could quietly stop
/// covering anything while the test stayed green.
const CoverageCase = struct {
    source: []const u8,
    source_kind: test_entry.SourceKind = .javascript,
    /// Allowlisted skip. Requires `skip_reason`, and is checked in BOTH
    /// directions: an unlisted snippet that fails to compile is a failure, and
    /// a listed snippet that starts compiling is a stale allowlist entry and is
    /// also a failure.
    expect_skip: bool = false,
    skip_reason: []const u8 = "",
};

/// RULE D -- compare the ACTUAL skipped set against the EXPLICIT expected set,
/// per case, by identity, in both directions.
///
/// `skipped` is parallel to `cases`. Kept as a free function precisely so it
/// can be fault-injected: see the "RULE D" self-test below, which requires a
/// new skip, a stale allowlist entry, and both-at-once to fail.
fn expectCoverageSkipSetMatches(
    cases: []const CoverageCase,
    skipped: []const bool,
    verbose: bool,
) !void {
    std.debug.assert(cases.len == skipped.len);
    var mismatched = false;
    for (cases, skipped, 0..) |case, was_skipped, index| {
        if (was_skipped and !case.expect_skip) {
            mismatched = true;
            if (verbose) std.debug.print(
                "compiler_v2.coverage RULE D: snippet[{d}] SKIPPED but is not allowlisted\n" ++
                    "  {s}\n" ++
                    "  every corpus snippet must compile; either fix it, or add\n" ++
                    "  .expect_skip = true with a .skip_reason explaining why it never can\n",
                .{ index, case.source },
            );
        }
        if (!was_skipped and case.expect_skip) {
            mismatched = true;
            if (verbose) std.debug.print(
                "compiler_v2.coverage RULE D: snippet[{d}] is allowlisted to skip but COMPILED\n" ++
                    "  {s}\n  allowlist reason (now stale): {s}\n" ++
                    "  remove .expect_skip: a stale allowlist hides real coverage\n",
                .{ index, case.source, case.skip_reason },
            );
        }
    }
    if (mismatched) return error.CoverageSkipSetMismatch;
}

test "compiler_v2.coverage: RULE D -- the skip allowlist is compared by identity" {
    // Fault injection for RULE D, so the assertion in the corpus test below
    // cannot rot into a comment. Four cases: the exact expected set, a NEW
    // skip, a STALE allowlist entry, and both wrong at once.
    const cases = [_]CoverageCase{
        .{ .source = "compiles();" },
        .{ .source = "does not compile", .expect_skip = true, .skip_reason = "synthetic" },
    };
    // The expected set, exactly: passes.
    try expectCoverageSkipSetMatches(&cases, &[_]bool{ false, true }, false);
    // A NEW skip: must fail. This is the property the rule exists for.
    try std.testing.expectError(
        error.CoverageSkipSetMismatch,
        expectCoverageSkipSetMatches(&cases, &[_]bool{ true, true }, false),
    );
    // A STALE allowlist entry that now compiles: must fail too.
    try std.testing.expectError(
        error.CoverageSkipSetMismatch,
        expectCoverageSkipSetMatches(&cases, &[_]bool{ false, false }, false),
    );
    // Both wrong at once: must fail.
    try std.testing.expectError(
        error.CoverageSkipSetMismatch,
        expectCoverageSkipSetMatches(&cases, &[_]bool{ true, false }, false),
    );
    // And there is no proportional escape hatch: one skip out of two is not
    // "within tolerance", it is either the allowlisted one or a failure.
    const all_js = [_]CoverageCase{ .{ .source = "a();" }, .{ .source = "b();" } };
    try std.testing.expectError(
        error.CoverageSkipSetMismatch,
        expectCoverageSkipSetMatches(&all_js, &[_]bool{ true, false }, false),
    );
}

test "compiler_v2.coverage: RULE B -- TypeScript probes route through parseAndCompileV2TestProgram" {
    // A TypeScript probe must be expressed as a compile through
    // parseAndCompileV2TestProgram() with `.source_kind = .typescript`, never
    // as `zjs -e '<ts source>'`. The CLI's `-e` path has no TypeScript
    // handling at all -- there is no filename for the source-kind autodetect to
    // work from -- so it answers SyntaxError for EVERY construct, which is
    // indistinguishable from an engine failure and reads as a finding.
    //
    // This test pins the sanctioned route. tools/final-switch/selftest.sh pins
    // the other half: it refuses the `zjs -e` formulation statically and proves
    // dynamically that it does report SyntaxError.
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const probes = [_][]const u8{
        "enum Direction { Up, Down = 4, Name = 'name' }",
        "const enum Flag { A = 1, B = 2 } const flag: Flag = Flag.A;",
        "namespace Space { export const value = 1; }",
        "interface Box<T> { value: T } const boxed: Box<number> = { value: 1 };",
        "class Holder { constructor(public value: number) {} }",
    };
    for (probes) |source| {
        var program = try test_entry.parseAndCompileV2TestProgram(
            rt,
            std.testing.allocator,
            "rule-b-typescript-probe",
            source,
            .{ .source_kind = .typescript },
        );
        defer program.deinit(rt);
    }
}

test "compiler_v2.coverage: production constructs never fall back to legacy emission" {
    const Case = CoverageCase;
    const cases = [_]Case{
        .{ .source = "let value = 1 + 2; value *= 3; value;" },
        .{ .source = "let value = 0; if (true) value = 1; else value = 2;" },
        .{ .source = "let value = 0; while (value < 3) { value++; }" },
        .{ .source = "for (let index = 0; index < 3; index++) { index; }" },
        .{ .source = "for (const key in { a: 1 }) { key; }" },
        .{ .source = "for (const value of [1, 2]) { value; }" },
        .{ .source = "let value = 0; do { value++; } while (value < 2);" },
        .{ .source = "switch (1) { case 0: break; case 1: value: { break value; } default: break; }" },
        .{ .source = "try { throw 1; } catch (error) { error; } finally { 0; }" },
        .{ .source = "outer: for (let i = 0; i < 2; i++) { inner: while (true) { continue outer; break inner; } break outer; }" },
        .{ .source = "function declared(a, b = 1) { return a + b; }" },
        .{ .source = "const expression = function named(value) { return value; }; const arrow = value => value + 1;" },
        .{ .source = "const object = { method(value) { return value; }, get item() { return 1; }, set item(value) { this.saved = value; } };" },
        .{ .source = "function* generator() { yield 1; yield* [2, 3]; }" },
        .{ .source = "async function task() { return await Promise.resolve(1); }" },
        .{ .source = "async function* stream() { yield await Promise.resolve(1); }" },
        .{ .source = "class Base { method() { return 1; } } class Derived extends Base { constructor() { super(); } static method() { return 2; } }" },
        .{ .source = "const key = 'computed'; class Features { #field = 1; static #staticField = 2; #method() { return this.#field; } static #staticMethod() { return this.#staticField; } [key] = 3; [key + 'Method']() { return 4; } static { this.ready = true; } }" },
        .{ .source = "const [first = 1, , ...rest] = [undefined, 2, 3];" },
        .{ .source = "const { a: { b = 1 } = {}, c: renamed = 2, ...rest } = source;" },
        .{ .source = "const array = [0, ...items]; const object = { base: 1, ...extra }; fn(...array);" },
        .{ .source = "const name = 'world'; const text = `hello ${name}`;" },
        .{ .source = "function tag(strings, value) { return value; } tag`value ${1}`;" },
        .{ .source = "object?.property; object?.[key]; callable?.();" },
        .{ .source = "let a = null; let b = a ?? 1; a ??= 2; b &&= 3; b ||= 4;" },
        .{ .source = "class Item {} const item = new Item(); function factory() { return new.target; }" },
        // RULE D: the ONE allowlisted skip in this corpus, kept in place rather
        // than deleted so that the expected skip set is stated by identity and
        // a NEW skip anywhere else fails. A bare `new.target;` at top level is
        // genuinely invalid JavaScript in that position, so it can never reach
        // emission; the valid in-function form is the snippet directly above.
        .{
            .source = "new.target;",
            .expect_skip = true,
            .skip_reason = "`new.target` at top level is a SyntaxError in that position; " ++
                "the valid in-function form is covered by the preceding snippet",
        },
        .{ .source = "delete object.value; typeof missing; void value;" },
        .{ .source = "const pattern = /a+b?/gi; const integer = 12345678901234567890n;" },
        .{ .source = "const shorthand = 1; const key = 'dynamic'; const object = { __proto__: null, shorthand, get value() { return 1; }, set value(input) {}, [key]: 2, ...extra };" },
        .{ .source = "with ({ value: 1 }) { value; }" },
        .{ .source = "eval('1 + 1'); (0, eval)('2 + 2');" },
        .{ .source = "function dispose() { using resource = { [Symbol.dispose]() {} }; }" },
        .{ .source = "for (using resource of resources) { resource; }" },
        .{ .source = "async function dispose() { await using resource = value; await resource; }" },
        .{ .source = "interface Box<T> { value: T } type Pair = [number, string]; const value: number = 1; function typed(input: number): number { return input; }", .source_kind = .typescript },
        .{ .source = "enum Direction { Up, Down = 4, Name = 'name' }", .source_kind = .typescript },
        .{ .source = "const enum Flag { A = 1, B = 2 } const flag: Flag = Flag.A;", .source_kind = .typescript },
        .{ .source = "namespace Basic { const value = 1; }", .source_kind = .typescript },
        .{ .source = "namespace A.B { export const value = 1; }", .source_kind = .typescript },
        .{ .source = "namespace Exported { export const value = 1; export function make() { return value; } export class Item {} }", .source_kind = .typescript },
        .{ .source = "class Box { constructor(public value: number, private label: string, readonly id: number) {} }", .source_kind = .typescript },
        .{ .source = "const value = ({ count: 1 } as { count: number }) satisfies { count: number };", .source_kind = .typescript },
        .{ .source = "function identity<T>(value: T): T { return value; } const arrow = <T>(value: T): T => value; class Store<T> { value!: T; }", .source_kind = .typescript },
        .{ .source = "interface Merged { first: number } interface Merged { second: string } namespace Merged { export const value = 1; }", .source_kind = .typescript },
    };

    coverage.reset();
    defer if (coverage.collectMode()) coverage.dumpReport();

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var compiled: usize = 0;
    // RULE D: the ACTUAL skipped set, recorded per case, compared below against
    // the EXPLICIT expected set carried by `.expect_skip`. Not a count, not a
    // proportion -- a set, matched by identity in both directions.
    var skipped = [_]bool{false} ** cases.len;
    var all_fallbacks: std.EnumSet(coverage.LegacyConstruct) = .empty;
    var total_unallowed: u64 = 0;
    for (cases, 0..) |case, index| {
        var program = test_entry.parseAndCompileV2TestProgram(
            rt,
            std.testing.allocator,
            "compiler-v2-coverage-corpus",
            case.source,
            .{ .source_kind = case.source_kind },
        ) catch |err| {
            skipped[index] = true;
            std.debug.print(
                "compiler_v2.coverage snippet[{d}] ({s}) did not compile: {s}\n  {s}\n" ++
                    "  allowlisted={}  reason={s}\n",
                .{
                    index,
                    @tagName(case.source_kind),
                    @errorName(err),
                    case.source,
                    case.expect_skip,
                    if (case.expect_skip) case.skip_reason else "<none: this is a NEW skip>",
                },
            );
            continue;
        };
        defer program.deinit(rt);

        compiled += 1;
        all_fallbacks.setUnion(program.fallbacks);
        total_unallowed +|= program.unallowed_emissions;
        if (coverage.collectMode()) {
            var iterator = program.fallbacks.iterator();
            while (iterator.next()) |construct| {
                std.debug.print(
                    "compiler_v2.coverage fallback construct={s} snippet[{d}]={s}\n",
                    .{ @tagName(construct), index, case.source },
                );
            }
            if (program.unallowed_emissions != 0) {
                std.debug.print(
                    "compiler_v2.coverage OFFENDING snippet[{d}] unallowed={d}: {s}\n",
                    .{ index, program.unallowed_emissions, case.source },
                );
            }
        }
    }

    comptime var expected_skips: usize = 0;
    comptime {
        for (cases) |case| {
            if (case.expect_skip) expected_skips += 1;
            if (case.expect_skip and case.skip_reason.len == 0) {
                @compileError("RULE D: an allowlisted skip must carry a .skip_reason");
            }
        }
    }
    std.debug.print(
        "compiler_v2.coverage corpus compiled={d}/{d} allowlisted_skips={d}\n",
        .{ compiled, cases.len, expected_skips },
    );
    // RULE D. The actual skipped SET must equal the allowlisted SET, entry for
    // entry. A new skip fails; an allowlist entry that started compiling fails.
    // There is deliberately no proportional form of this check.
    try expectCoverageSkipSetMatches(&cases, &skipped, true);
    try std.testing.expectEqual(cases.len - expected_skips, compiled);
    try test_entry.expectNoUnallowedFallback(.{
        .fallbacks = all_fallbacks,
        .unallowed = total_unallowed,
    });
}
