const std = @import("std");
const engine = @import("quickjs_zig_engine");

const core = engine.core;

test "QuickJS value tag constants are locked" {
    try std.testing.expectEqual(@as(i64, -9), core.Tag.first);
    try std.testing.expectEqual(@as(i64, -9), core.Tag.big_int);
    try std.testing.expectEqual(@as(i64, -8), core.Tag.symbol);
    try std.testing.expectEqual(@as(i64, -7), core.Tag.string);
    try std.testing.expectEqual(@as(i64, -6), core.Tag.string_rope);
    try std.testing.expectEqual(@as(i64, -3), core.Tag.module);
    try std.testing.expectEqual(@as(i64, -2), core.Tag.function_bytecode);
    try std.testing.expectEqual(@as(i64, -1), core.Tag.object);
    try std.testing.expectEqual(@as(i64, 0), core.Tag.int);
    try std.testing.expectEqual(@as(i64, 1), core.Tag.boolean);
    try std.testing.expectEqual(@as(i64, 2), core.Tag.null_value);
    try std.testing.expectEqual(@as(i64, 3), core.Tag.undefined_value);
    try std.testing.expectEqual(@as(i64, 4), core.Tag.uninitialized);
    try std.testing.expectEqual(@as(i64, 5), core.Tag.catch_offset);
    try std.testing.expectEqual(@as(i64, 6), core.Tag.exception);
    try std.testing.expectEqual(@as(i64, 7), core.Tag.short_big_int);
    try std.testing.expectEqual(@as(i64, 8), core.Tag.float64);
}

test "primitive value predicates match QuickJS helpers" {
    try std.testing.expect(core.Value.int32(1).isNumber());
    try std.testing.expect(core.Value.float64(1.5).isNumber());
    try std.testing.expect(core.Value.boolean(false).isBool());
    try std.testing.expect(core.Value.nullValue().isNull());
    try std.testing.expect(core.Value.undefinedValue().isUndefined());
    try std.testing.expect(core.Value.uninitialized().isUninitialized());
    try std.testing.expect(core.Value.exception().isException());
    try std.testing.expect(core.Value.shortBigInt(42).isBigInt());
    try std.testing.expectEqual(@as(?i32, 7), core.Value.int32(7).asInt32());
    try std.testing.expectEqual(@as(?i32, null), core.Value.float64(7).asInt32());
}

test "runtime and context init-deinit are leak free" {
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const rt = try core.Runtime.create(std.testing.allocator);
        const ctx1 = try core.Context.create(rt);
        const ctx2 = try core.Context.create(rt);
        ctx2.destroy();
        ctx1.destroy();
        rt.destroy();
    }
}

test "predefined atoms preserve QuickJS order and kinds" {
    try std.testing.expectEqual(@as(core.Atom, 0), core.atom.null_atom);
    try std.testing.expectEqual(@as(core.Atom, 1), core.atom.ids.null_);
    try std.testing.expectEqual(@as(core.Atom, 2), core.atom.ids.false_);
    try std.testing.expectEqual(@as(core.Atom, 3), core.atom.ids.true_);
    try std.testing.expectEqual(@as(core.Atom, 35), core.atom.last_keyword);
    try std.testing.expectEqual(@as(core.Atom, 44), core.atom.last_strict_keyword);
    try std.testing.expectEqual(@as(core.Atom, 228), core.atom.ids.Symbol_asyncIterator);
    try std.testing.expectEqual(@as(usize, 228), core.atom.predefined_count);

    const brand = core.atom.predefinedById(core.atom.ids.Private_brand).?;
    try std.testing.expectEqual(core.atom.AtomKind.private, brand.kind);
    const iterator = core.atom.predefinedById(core.atom.ids.Symbol_iterator).?;
    try std.testing.expectEqual(core.atom.AtomKind.symbol, iterator.kind);

    for (core.atom.predefined_atoms, 0..) |entry, index| {
        try std.testing.expectEqual(@as(core.Atom, @intCast(index + 1)), entry.id);
    }
}

test "atom table interns predefined dynamic and integer atoms" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    try std.testing.expectEqual(core.atom.ids.length, try rt.internAtom("length"));
    try std.testing.expectEqual(core.atom.atomFromUInt32(123), try rt.internAtom("123"));
    try std.testing.expectEqual(@as(u32, 123), core.atom.atomToUInt32(core.atom.atomFromUInt32(123)));

    const first = try rt.internAtom("customName");
    const second = try rt.internAtom("customName");
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqualStrings("customName", rt.atoms.name(first).?);

    rt.atoms.free(first);
    try std.testing.expect(rt.atoms.name(second) != null);
    rt.atoms.free(second);
    try std.testing.expect(rt.atoms.name(second) == null);
}

test "symbol atoms are unique even with the same description" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const a = try rt.atoms.newSymbol("desc", .symbol);
    const b = try rt.atoms.newSymbol("desc", .symbol);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(core.atom.AtomKind.symbol, rt.atoms.kind(a).?);
    try std.testing.expectEqualStrings("desc", rt.atoms.name(a).?);
    rt.atoms.free(a);
    rt.atoms.free(b);
}

test "exception slot transfers owned value and clears context slot" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.Context.create(rt);
    defer ctx.destroy();

    const str = try core.string.String.createAscii(rt, "boom");
    const thrown = ctx.throwValue(str.value());
    try std.testing.expect(thrown.isException());
    try std.testing.expect(ctx.hasException());

    const taken = ctx.takeException();
    try std.testing.expect(taken.isString());
    try std.testing.expect(!ctx.hasException());
    taken.free(rt);
}

test "reference dup and free retain until final release" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const str = try core.string.String.createAscii(rt, "abc");
    const value = str.value();
    const duped = value.dup();
    try std.testing.expectEqual(@as(usize, 2), str.header.ref_count);

    value.free(rt);
    try std.testing.expectEqual(@as(usize, 1), str.header.ref_count);
    duped.free(rt);
}

test "memory account tracks same-allocator allocation and free" {
    var account = core.memory.MemoryAccount.init(std.testing.allocator);
    const buf = try account.alloc(u8, 16);
    try std.testing.expect(account.hasOutstandingAllocations());
    account.free(u8, buf);
    try std.testing.expect(!account.hasOutstandingAllocations());
}

test "intrusive list supports empty insert and remove" {
    var list = core.list.List{};
    list.init();
    try std.testing.expect(list.isEmpty());

    var a = core.list.Node{};
    var b = core.list.Node{};
    list.add(&a);
    list.addTail(&b);
    try std.testing.expect(!list.isEmpty());
    try std.testing.expect(a.isLinked());
    try std.testing.expect(b.isLinked());

    core.list.List.remove(&a);
    try std.testing.expect(!a.isLinked());
    try std.testing.expect(!list.isEmpty());

    core.list.List.remove(&b);
    try std.testing.expect(!b.isLinked());
    try std.testing.expect(list.isEmpty());
}
