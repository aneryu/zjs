const std = @import("std");
const core = @import("../core/root.zig");
const builder_mod = @import("builder.zig");
const labels = @import("labels.zig");

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
