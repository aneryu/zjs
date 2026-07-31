const std = @import("std");
const core = @import("../core/root.zig");
const parser_mod = @import("../parser.zig");
const bytecode_mod = @import("../bytecode.zig");
const builder_mod = @import("builder.zig");
const labels = @import("labels.zig");
const P = parser_mod.Parser;
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

    fn deinit(h: *V2Parse) void {
        h.state.deinit(h.rt);
        h.function.deinit(h.rt);
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

fn expectLabel(b: *const builder_mod.Builder, index: u32, ref_count: u32, bound_offset: u32) !void {
    try std.testing.expect(index < b.label_len);
    const slot = b.label_slots[index];
    try std.testing.expect(slot.flags.bound);
    try std.testing.expectEqual(ref_count, slot.ref_count);
    try std.testing.expectEqual(bound_offset, slot.bound_offset);
}

/// Validate every intrusive relocation chain, including unique coverage of the
/// complete relocation ledger, and require every parser-created label bound.
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
    try expectSourceOffsets(b, &.{ 0, 1, 6 });
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
    try expectSourceOffsets(b, &.{ 0, 1, 11 });
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
        .{ .op = qop.if_false, .size = 5, .label = 1 },
        .{ .op = qop.goto, .size = 5, .label = 0 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 3 },
        .{ .op = qop.goto, .size = 5, .label = 2 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 27), b.code_len);
    try std.testing.expectEqual(@as(u32, 4), b.label_len);
    try expectLabel(b, 0, 1, 26);
    try expectLabel(b, 1, 1, 21);
    try expectLabel(b, 2, 1, 14);
    try expectLabel(b, 3, 1, 26);
    try std.testing.expectEqual(@as(i64, 26), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 2, 3, 4, 14, 26 });
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
        .{ .op = qop.goto, .size = 5, .label = 1 },
        .{ .op = qop.null, .size = 1 },
        .{ .op = qop.drop, .size = 1 },
        .{ .op = qop.goto, .size = 5, .label = 3 },
        .{ .op = qop.goto, .size = 5, .label = 2 },
        .{ .op = qop.drop, .size = 1 },
    });
    try std.testing.expectEqual(@as(u32, 19), b.code_len);
    try std.testing.expectEqual(@as(u32, 4), b.label_len);
    try expectLabel(b, 0, 0, 18);
    try expectLabel(b, 1, 1, 13);
    try expectLabel(b, 2, 1, 6);
    try expectLabel(b, 3, 1, 18);
    try std.testing.expectEqual(@as(i64, 18), b.last_opcode_pos);
    try expectSourceOffsets(b, &.{ 0, 1, 6, 18 });
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
