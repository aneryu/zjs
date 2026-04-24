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

test "strings choose QuickJS-style 8-bit or 16-bit storage" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const ascii = try core.string.String.createUtf8(rt, "abc");
    defer ascii.value().free(rt);
    try std.testing.expect(!ascii.isWide());
    try std.testing.expectEqual(@as(usize, 3), ascii.len());
    try std.testing.expect(ascii.eqlBytes("abc"));
    try std.testing.expectEqual(core.string.hashBytes("abc"), ascii.hash);

    const latin1 = try core.string.String.createUtf8(rt, "é");
    defer latin1.value().free(rt);
    try std.testing.expect(!latin1.isWide());
    try std.testing.expectEqual(@as(usize, 1), latin1.len());
    try std.testing.expectEqual(@as(u16, 0x00e9), latin1.codeUnitAt(0));

    const wide = try core.string.String.createUtf8(rt, "Ā");
    defer wide.value().free(rt);
    try std.testing.expect(wide.isWide());
    try std.testing.expectEqual(@as(usize, 1), wide.len());
    try std.testing.expectEqual(@as(u16, 0x0100), wide.codeUnitAt(0));

    const face = try core.string.String.createUtf8(rt, "😀");
    defer face.value().free(rt);
    try std.testing.expect(face.isWide());
    try std.testing.expectEqual(@as(usize, 2), face.len());
    try std.testing.expectEqual(@as(u16, 0xd83d), face.codeUnitAt(0));
    try std.testing.expectEqual(@as(u16, 0xde00), face.codeUnitAt(1));
}

test "strings compare by code unit across storage widths" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const latin1 = try core.string.String.createUtf8(rt, "é");
    defer latin1.value().free(rt);
    const utf16_same = try core.string.String.createUtf16(rt, &.{0x00e9});
    defer utf16_same.value().free(rt);
    try std.testing.expect(latin1.eqlString(utf16_same.*));

    const a = try core.string.String.createUtf8(rt, "abc");
    defer a.value().free(rt);
    const b = try core.string.String.createUtf8(rt, "abd");
    defer b.value().free(rt);
    try std.testing.expect(a.compare(b.*) < 0);
    try std.testing.expect(b.compare(a.*) > 0);
}

test "atom-backed strings retain atom until string free" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const atom_id = try rt.internAtom("ownedAtomName");
    const atom_string = try core.string.String.createAtomBacked(rt, atom_id);
    rt.atoms.free(atom_id);
    try std.testing.expect(rt.atoms.name(atom_id) != null);
    try std.testing.expect(atom_string.eqlBytes("ownedAtomName"));
    atom_string.value().free(rt);
    try std.testing.expect(rt.atoms.name(atom_id) == null);
}

test "class table registers QuickJS standard classes and dynamic classes" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    try std.testing.expectEqual(@as(core.ClassId, 0), core.class.invalid_class_id);
    try std.testing.expectEqual(@as(core.ClassId, 1), core.class.ids.object);
    try std.testing.expectEqual(@as(core.ClassId, 22), core.class.ids.uint8c_array);
    try std.testing.expectEqual(@as(core.ClassId, 37), core.class.ids.set);
    try std.testing.expectEqual(@as(core.ClassId, 65), core.class.ids.init_count);
    try std.testing.expect(rt.classes.isRegistered(core.class.ids.object));
    try std.testing.expect(rt.classes.isRegistered(core.class.ids.generator));
    try std.testing.expect(!rt.classes.isRegistered(core.class.ids.proxy));

    const object_name = rt.classes.className(core.class.ids.object).?;
    defer rt.atoms.free(object_name);
    try std.testing.expectEqual(core.atom.ids.Object, object_name);

    const dynamic_id = rt.newClassId(core.class.invalid_class_id);
    try std.testing.expectEqual(core.class.ids.init_count, dynamic_id);
    try rt.classes.register(dynamic_id, .{ .class_name = "HostThing", .has_exotic = true });
    try std.testing.expect(rt.classes.isRegistered(dynamic_id));
    const record = rt.classes.record(dynamic_id).?;
    try std.testing.expect(record.has_exotic);
    const dynamic_name = rt.classes.className(dynamic_id).?;
    defer rt.atoms.free(dynamic_name);
    try std.testing.expectEqualStrings("HostThing", rt.atoms.name(dynamic_name).?);

    try std.testing.expectError(error.DuplicateClass, rt.classes.register(dynamic_id, .{ .class_name = "Again" }));
}

var finalizer_calls: usize = 0;

fn countFinalizer() void {
    finalizer_calls += 1;
}

test "class finalizers and context prototype slots are wired" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const dynamic_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(dynamic_id, .{ .class_name = "FinalizedThing", .finalizer = countFinalizer });

    const ctx = try core.Context.create(rt);
    defer ctx.destroy();
    try std.testing.expect(ctx.classPrototypeSlotCount() >= dynamic_id + 1);

    finalizer_calls = 0;
    try std.testing.expect(rt.classes.runFinalizer(dynamic_id));
    try std.testing.expectEqual(@as(usize, 1), finalizer_calls);
    try std.testing.expect(!rt.classes.runFinalizer(core.class.ids.object));
}

test "shapes retain property atoms and compare transitions" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name_atom = try rt.internAtom("shapeProp");
    const first = try rt.shapes.create(123);
    const second = try rt.shapes.create(123);
    try rt.shapes.addProperty(first, name_atom, 0b000011);
    try rt.shapes.addProperty(second, name_atom, 0b000011);
    rt.atoms.free(name_atom);

    try std.testing.expect(first.is_hashed);
    try std.testing.expectEqual(@as(usize, 1), first.prop_count);
    try std.testing.expect(first.sameTransition(second.*));
    try std.testing.expect(rt.atoms.name(first.props[0].atom_id) != null);
    try std.testing.expectEqual(
        core.shape.hashIndex(first.hash, core.shape.initial_shape_hash_bits),
        core.shape.hashIndex(first.hash, rt.shapes.shape_hash_bits),
    );

    rt.shapes.release(first);
    try std.testing.expect(rt.atoms.name(second.props[0].atom_id) != null);
    rt.shapes.release(second);
    try std.testing.expectEqual(@as(usize, 0), rt.shapes.shape_hash_count);
}

test "shape refcounts and prototype transitions are tracked" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name_atom = try rt.internAtom("shapeProtoProp");
    defer rt.atoms.free(name_atom);

    const first = try rt.shapes.create(1);
    const second = try rt.shapes.create(2);
    try rt.shapes.addProperty(first, name_atom, 0b000001);
    try rt.shapes.addProperty(second, name_atom, 0b000001);
    try std.testing.expect(!first.sameTransition(second.*));

    first.retain();
    try std.testing.expectEqual(@as(usize, 2), first.ref_count);
    rt.shapes.release(first);
    try std.testing.expectEqual(@as(usize, 1), first.ref_count);
    rt.shapes.release(first);
    rt.shapes.release(second);
    try std.testing.expectEqual(@as(usize, 0), rt.shapes.shape_hash_count);
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

test "gc registry tracks zero-ref objects and mark placeholders" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const header = try rt.memory.create(core.gc.ObjectHeader);
    defer rt.memory.destroy(core.gc.ObjectHeader, header);
    header.* = .{ .kind = .object };
    try rt.gc.add(header);
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCount());

    rt.gc.mark(header);
    try std.testing.expect(header.marked);
    rt.gc.runCycleRemovalPlaceholder();
    try std.testing.expect(!header.marked);

    try std.testing.expect(try rt.gc.releaseObject(header));
    try std.testing.expectEqual(@as(usize, 1), rt.gc.zeroRefCount());
    rt.gc.remove(header);
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
    try std.testing.expectEqual(@as(usize, 0), rt.gc.zeroRefCount());
}

test "function records own native bytecode and bound payloads" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("fn");
    defer rt.atoms.free(name);

    var native = core.FunctionRecord.createNative(&rt.memory, &rt.atoms, name, 2, null, true);
    try std.testing.expectEqual(core.function.Kind.native, native.kind);
    try std.testing.expect(native.is_constructor);
    try std.testing.expectEqual(@as(u16, 2), native.payload.native.length);
    native.destroy(rt);

    const constant_string = try core.string.String.createAscii(rt, "const");
    const constant_value = constant_string.value();
    var bytecode = try core.FunctionRecord.createBytecode(
        &rt.memory,
        &rt.atoms,
        name,
        &.{ 0xaa, 0xbb },
        &.{constant_value},
        .generator,
        false,
        core.Value.undefinedValue(),
    );
    try std.testing.expectEqual(core.function.Kind.bytecode, bytecode.kind);
    try std.testing.expectEqual(core.function.FunctionKind.generator, bytecode.function_kind);
    try std.testing.expectEqual(@as(usize, 2), bytecode.payload.bytecode.bytecode.len);
    try std.testing.expectEqual(@as(usize, 1), bytecode.payload.bytecode.constants.len);
    try std.testing.expectEqual(@as(usize, 2), constant_string.header.ref_count);
    constant_value.free(rt);
    bytecode.destroy(rt);

    const bound_string = try core.string.String.createAscii(rt, "arg");
    const bound_arg = bound_string.value();
    var bound = try core.FunctionRecord.createBound(
        &rt.memory,
        &rt.atoms,
        core.Value.undefinedValue(),
        core.Value.nullValue(),
        &.{bound_arg},
        false,
    );
    try std.testing.expectEqual(core.function.Kind.bound, bound.kind);
    try std.testing.expectEqual(@as(usize, 2), bound_string.header.ref_count);
    bound_arg.free(rt);
    bound.destroy(rt);
}

test "module records retain import export metadata and status" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const module_name = try rt.internAtom("main.mjs");
    const dep_name = try rt.internAtom("dep.mjs");
    const import_name = try rt.internAtom("value");
    const local_name = try rt.internAtom("local");
    const export_name = try rt.internAtom("default");

    const record = try rt.modules.create(module_name);
    try record.addRequestedModule(dep_name);
    try record.addImport(dep_name, import_name, local_name);
    try record.addExport(export_name, local_name);
    record.setStatus(.linked);

    rt.atoms.free(module_name);
    rt.atoms.free(dep_name);
    rt.atoms.free(import_name);
    rt.atoms.free(local_name);
    rt.atoms.free(export_name);

    try std.testing.expectEqual(core.module.Status.linked, record.status);
    try std.testing.expectEqual(@as(usize, 1), record.requested_modules.len);
    try std.testing.expectEqual(@as(usize, 1), record.imports.len);
    try std.testing.expectEqual(@as(usize, 1), record.exports.len);
    try std.testing.expect(rt.atoms.name(record.module_name) != null);
    try std.testing.expect(rt.atoms.name(record.imports[0].local_name) != null);
}

fn interruptOnce(rt: *core.Runtime) bool {
    rt.random_state +%= 1;
    return true;
}

test "runtime stack and interrupt state are stored" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    rt.setStackSize(4096);
    try std.testing.expectEqual(@as(usize, 4096), rt.stackSize());
    try std.testing.expect(!rt.hasInterruptHandler());
    rt.setInterruptHandler(interruptOnce);
    try std.testing.expect(rt.hasInterruptHandler());
    const before = rt.random_state;
    try std.testing.expect(rt.runInterruptHandler());
    try std.testing.expectEqual(before +% 1, rt.random_state);
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
