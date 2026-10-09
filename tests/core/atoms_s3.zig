//! Core integration tests: atoms_s3.
const std = @import("std");
const zjs = @import("zjs");
const core = zjs.core;
const helpers = @import("../harness.zig");
const runtime_owner = @import("zjs").core.runtime;

fn publishFreshModule(
    registry: *core.module.Registry,
    module_name: core.Atom,
    pending: *core.module.PendingDefinition,
) !*core.ModuleRecord {
    const prepared = try registry.prepareFreshTarget(module_name, pending);
    if (!prepared.isFresh()) return error.TestUnexpectedResult;
    return prepared.record();
}

fn publishEmptyModule(
    rt: *core.JSRuntime,
    registry: *core.module.Registry,
    module_name: core.Atom,
) !*core.ModuleRecord {
    var pending = core.module.PendingDefinition.init(rt, rt.atoms);
    defer pending.deinit();
    return publishFreshModule(registry, module_name, &pending);
}

// ---------------------------------------------------------------------------
// TGC S3: tracing-owned atom liveness.
//
// The edge tests below read `DynamicAtom.mark_epoch` directly: that is the
// mechanism the sweep then acts on, and pinning it separately keeps an edge
// regression from hiding behind some other root that happens to keep the
// entry alive.
// ---------------------------------------------------------------------------

fn s3AtomEntry(rt: *core.JSRuntime, id: core.Atom) *core.atom.DynamicAtom {
    return &rt.atoms.entries[id.raw() - core.atom.first_dynamic_atom];
}

fn s3MarkEpoch(rt: *core.JSRuntime) u64 {
    return rt.gc.block_heap.mark_epoch;
}

fn s3RunMajor(rt: *core.JSRuntime) !void {
    _ = try rt.forceGC(null);
}

test "TGC S3: a shape property key is an atom trace edge" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    rt.forcePreciseRootScanForTest();

    const key = try rt.internAtom("zjsS3ShapeKeyEdge");
    const object = try core.Object.createPlainObject(rt, null);
    try rt.gc.pinHeader(object.gcHeader());
    defer rt.gc.unpinHeader(object.gcHeader());
    try object.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(1), .all));
    // Hand the id over: from here the entry is reachable only through the
    // shape's property array.

    try s3RunMajor(rt);
    try std.testing.expectEqual(s3MarkEpoch(rt), s3AtomEntry(rt, key).mark_epoch);
}

test "TGC S3: an inline bytecode atom operand is an atom trace edge" {
    var engine_instance = try helpers.TestEngine.init(std.testing.allocator);
    defer engine_instance.deinit();
    const rt = engine_instance.runtime;

    // The property name only ever appears as a `get_field` operand inside the
    // published FunctionBytecode: nothing ever builds a shape with this key,
    // so a mark here can only have come from the C edge.
    _ = try engine_instance.eval(
        \\globalThis.zjsS3Keep = function (o) { return o.zjsS3BytecodeOperand; };
    );

    const operand = try rt.internAtom("zjsS3BytecodeOperand");

    try s3RunMajor(rt);
    try std.testing.expectEqual(s3MarkEpoch(rt), s3AtomEntry(rt, operand).mark_epoch);
}

test "TGC S3: a module record name is an atom trace edge" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    rt.forcePreciseRootScanForTest();

    const module_name = try rt.internAtom("zjs-s3-module-edge.mjs");
    const record = try publishEmptyModule(rt, &ctx.modules, module_name);
    // Only the record names the atom now.

    var record_roots = [_]core.runtime.HeaderRootValue{.{ .header = &record.header }};
    var record_frame = core.runtime.ValueRootFrame{ .headers = &record_roots };
    record_frame.activate(rt);
    defer record_frame.deactivate(rt);

    try s3RunMajor(rt);
    try std.testing.expectEqual(s3MarkEpoch(rt), s3AtomEntry(rt, module_name).mark_epoch);
}

test "symbol inline extent survives id roots and leaves a weak shell on collection" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.forcePreciseRootScanForTest();
    const text = "long-description" ** 1024;
    const value = try rt.newSymbolValue(text);
    const id = value.asSymbolAtom().?;
    try std.testing.expect(!core.gc.Registry.isBlockCellHeader(value.asSymbolBody().?.header()));
    try std.testing.expectEqual(core.gc.RefKind.symbol, value.asSymbolBody().?.header().metaConst().flags.kind);
    rt.atoms.pinForHost(id);
    rt.atoms.retainSymbolWeakRef(id);
    defer rt.atoms.releaseSymbolWeakRef(rt, id);
    try s3RunMajor(rt);
    try std.testing.expectEqualStrings(text, rt.atoms.symbolDescription(rt, id).?);
    try std.testing.expect(rt.gc.containsHeader(value.asSymbolBody().?.header()));
    rt.atoms.unpinForHost(id);
    try s3RunMajor(rt);
    try std.testing.expect(rt.atoms.symbolValueIfLive(rt, id).is(.undefined_value));
    try std.testing.expect(rt.atoms.name(id) == null);
    const replacement = try rt.newSymbolValue(text);
    try std.testing.expect(replacement.asSymbolAtom().? != id);
}

test "symbol registry roots preserve inline identity across major collections" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.forcePreciseRootScanForTest();
    const key = "registry-description" ** 512;
    const value = try rt.globalSymbolValue(key);
    const id = value.asSymbolAtom().?;
    const body = value.asSymbolBody().?;
    // No value or atom pin remains: the registry itself is the root.
    try s3RunMajor(rt);
    try s3RunMajor(rt);
    try std.testing.expectEqualStrings(key, core.symbol.registryKey(rt.atoms, id).?);
    try std.testing.expectEqual(body, (try rt.globalSymbolValue(key)).asSymbolBody().?);
    try std.testing.expectEqual(@as(usize, 0), rt.atoms.entries[id.raw() - core.atom.first_dynamic_atom].bytes.len);
}

test "symbol failed registry materialization releases pending description" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.forcePreciseRootScanForTest();
    const key = "failed-registered-symbol";
    const id = try rt.atoms.internRegisteredValueSymbol(key);
    rt.setMemoryLimit(0);
    try std.testing.expectError(error.OutOfMemory, rt.symbolValue(id));
    rt.setMemoryLimit(null);
    try s3RunMajor(rt);
    try s3RunMajor(rt);
    try std.testing.expect(rt.atoms.name(id) == null);
    const value = try rt.globalSymbolValue(key);
    try std.testing.expectEqualStrings(key, value.asSymbolBody().?.descriptionBytes().?);
}

test "symbol body allocation failure preserves pending atom and description" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.forcePreciseRootScanForTest();
    const id = try rt.atoms.newValueSymbol("pending-symbol");
    rt.atoms.pinForHost(id);
    defer rt.atoms.unpinForHost(id);
    rt.setMemoryLimit(0);
    try std.testing.expectError(error.OutOfMemory, rt.symbolValue(id));
    try std.testing.expectEqualStrings("pending-symbol", rt.atoms.name(id).?);
    try std.testing.expect(rt.atoms.entries[id.raw() - core.atom.first_dynamic_atom].body == null);
    rt.setMemoryLimit(null);
    var value = try rt.symbolValue(id);
    var roots = core.runtime.rootValues(.{&value});
    roots.activate(rt);
    defer roots.deactivate(rt);
    const body = value.asSymbolBody().?;
    rt.setMemoryLimit(0);
    try std.testing.expectError(error.OutOfMemory, body.descriptionValue(rt));
    try std.testing.expectEqualStrings("pending-symbol", body.descriptionBytes().?);
    rt.setMemoryLimit(null);
    try std.testing.expect((try body.descriptionValue(rt)).isString());
}

test "TGC S3: an id-held value symbol keeps its body marked" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    rt.forcePreciseRootScanForTest();

    const symbol_atom = try rt.atoms.newValueSymbol("zjs-s3-symbol-edge");
    // Materialize the body, then drop the JSValue: the body is now reachable
    // only through the entry the shape names by id.
    const body_value = try rt.symbolValue(symbol_atom);
    const body_header = body_value.asSymbolBody().?.header();

    const object = try core.Object.createPlainObject(rt, null);
    try rt.gc.pinHeader(object.gcHeader());
    defer rt.gc.unpinHeader(object.gcHeader());
    try object.defineOwnProperty(rt, symbol_atom, core.Descriptor.data(core.JSValue.int32(7), .all));

    try s3RunMajor(rt);
    try std.testing.expectEqual(s3MarkEpoch(rt), s3AtomEntry(rt, symbol_atom).mark_epoch);
    try std.testing.expect(rt.gc.headerMarked(body_header));
}

test "TGC S3-c: an atom no edge and no root reaches is retired by the major" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    rt.forcePreciseRootScanForTest();

    // A bare native id nothing declares. Before the flip `ref_count` kept it
    // and the shadow audit named it; now the sweep retires it.
    const orphan = try rt.internAtom("zjs-s3-orphan-atom");
    const entry_index = orphan.raw() - core.atom.first_dynamic_atom;

    try s3RunMajor(rt);
    try std.testing.expect(rt.atoms.entries[entry_index].mark_epoch != s3MarkEpoch(rt));
    try std.testing.expect(rt.atoms.name(orphan) == null);
    try std.testing.expect(!rt.atoms.entries[entry_index].slotOccupied());
}

// ---------------------------------------------------------------------------
// TGC S3-b: the compile scope provider (K/L/M).
// ---------------------------------------------------------------------------

test "TGC S3-b: a compile scope roots an atom no holder edge names" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    rt.forcePreciseRootScanForTest();

    // Same shape as the orphan probe above -- a bare id nothing declares and
    // no tracer edge reaches -- except a compile scope is open. That is the
    // front end's exact situation between interning an identifier and
    // publishing the FunctionBytecode that will finally name it.
    const ident = try rt.internAtom("zjsS3CompileScopeIdent");
    const entry_index = ident.raw() - core.atom.first_dynamic_atom;
    {
        var scope = core.atom.CompileAtomScope.init(rt.atoms, rt);
        defer scope.deinit();
        try scope.activate();
        // Recording is ambient: every `internX` inside an open scope records,
        // and `note` is the same seam for an id obtained before it opened.
        scope.note(ident);

        try s3RunMajor(rt);
        try std.testing.expectEqual(s3MarkEpoch(rt), rt.atoms.entries[entry_index].mark_epoch);
        try std.testing.expect(rt.atoms.name(ident) != null);
    }

    // Scope closed: the id is an unrooted native temporary again, so the next
    // major must NOT reach it and must retire the entry. Without this half the
    // assertion above could be satisfied by any other root.
    try s3RunMajor(rt);
    try std.testing.expect(rt.atoms.entries[entry_index].mark_epoch != s3MarkEpoch(rt));
    try std.testing.expect(rt.atoms.name(ident) == null);
}

test "TGC S3-b: a compile scope on a runtime-less table records without registering" {
    // The parser/compiler fixtures build a standalone `AtomTable` that has no
    // collector at all; every S3 seam has to degrade to a no-op there.
    const account = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
    defer account.destroy();
    var table = core.atom.AtomTable.init(account);
    defer table.deinit();

    var scope = core.atom.CompileAtomScope.init(&table, null);
    defer scope.deinit();
    try scope.activate();
    try std.testing.expect(scope.rt == null);

    const id = try scope.intern("zjsS3FixtureIdent");
    // Ambient and explicit recording agree, and the direct-mapped filter keeps
    // a repeat from growing the list.
    try std.testing.expectEqual(id, scope.noteExisting(id));
    try std.testing.expectEqual(@as(usize, 1), scope.ids.items.len);
    try std.testing.expectEqual(id, scope.ids.items[0]);
}

fn s3OccupiedEntryCount(rt: *core.JSRuntime) usize {
    var total: usize = 0;
    for (rt.atoms.entries) |entry| total += @intFromBool(entry.slotOccupied());
    return total;
}

test "TGC S3-c: the atom entry census falls back after a major" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    rt.forcePreciseRootScanForTest();

    // Settle whatever startup left unreachable, so the baseline is a real
    // floor rather than "everything interned so far".
    try s3RunMajor(rt);
    const baseline = s3OccupiedEntryCount(rt);

    // 10k spellings nothing keeps: no holder edge, no root frame, no host pin.
    // Under refcounting these could only be reclaimed by an explicit `free`.
    var buffer: [64]u8 = undefined;
    var index: usize = 0;
    while (index < 10_000) : (index += 1) {
        const name = try std.fmt.bufPrint(&buffer, "zjsS3CensusProbe{d}", .{index});
        _ = try rt.internAtom(name);
    }
    const peak = s3OccupiedEntryCount(rt);
    try std.testing.expect(peak >= baseline + 10_000);

    try s3RunMajor(rt);
    const after = s3OccupiedEntryCount(rt);
    // Not "== baseline": black allocation keeps anything interned inside an
    // open marking window alive for that cycle, so the claim is that the
    // census collapses back to the floor rather than tracking the peak.
    try std.testing.expect(after < baseline + 1_000);
}

test "TGC S3-c: a young symbol body a shape names by id survives a minor" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    rt.forcePreciseRootScanForTest();

    var object: ?*core.Object = try core.Object.createPlainObject(rt, null);
    var object_roots = core.runtime.rootObjects(.{&object});
    object_roots.activate(rt);
    defer object_roots.deactivate(rt);

    const symbol_atom = try rt.atoms.newValueSymbol("zjsS3YoungSymbolBody");
    const entry = s3AtomEntry(rt, symbol_atom);
    // Materialize the body and drop the JSValue: the body is YOUNG and its
    // only holder is the shape, which reaches it over an atom id. A minor
    // traces neither the atom table's entries nor (usefully) that id -- an
    // entry already stamped for this epoch short-circuits `visitAtom`, and
    // before the first major the epoch is 0, which every fresh entry already
    // reads. Without the young-body root the minor sweeps the body and the
    // destroy handshake retires a live holder's entry.
    _ = try rt.symbolValue(symbol_atom);
    try object.?.defineOwnProperty(rt, symbol_atom, core.Descriptor.data(core.JSValue.int32(7), .all));

    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    try std.testing.expect(entry.slotOccupied());
    try std.testing.expect(entry.body != null);
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    try std.testing.expect(!rt.atoms.symbolValueIfLive(rt, symbol_atom).is(.undefined_value));

    // Repeated minors keep it: the first one promoted the body, after which
    // the major's `visitAtom` rules are the only authority again.
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    try std.testing.expect(!rt.atoms.symbolValueIfLive(rt, symbol_atom).is(.undefined_value));

    // The shape edge is what keeps it across majors, not the young list.
    try s3RunMajor(rt);
    try std.testing.expectEqual(s3MarkEpoch(rt), entry.mark_epoch);
    try std.testing.expect(!rt.atoms.symbolValueIfLive(rt, symbol_atom).is(.undefined_value));

    // Drop the holder: with no edge left the major retires the entry.
    object = null;
    try s3RunMajor(rt);
    try s3RunMajor(rt);
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "TGC S3-c: a thousand fresh symbol keys survive the minors taken while they accumulate" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    rt.forcePreciseRootScanForTest();

    // The `staging/sm/object/getOwnPropertySymbols.js` shape, in Zig: an
    // object accumulating 1000 symbol keys while minors run underneath.
    var object: ?*core.Object = try core.Object.createPlainObject(rt, null);
    var object_roots = core.runtime.rootObjects(.{&object});
    object_roots.activate(rt);
    defer object_roots.deactivate(rt);

    var ids: [1000]core.Atom = undefined;
    var buffer: [64]u8 = undefined;
    for (&ids, 0..) |*slot, index| {
        const name = try std.fmt.bufPrint(&buffer, "zjsS3SymbolKey{d}", .{index});
        slot.* = try rt.atoms.newValueSymbol(name);
        _ = try rt.symbolValue(slot.*);
        try object.?.defineOwnProperty(rt, slot.*, core.Descriptor.data(core.JSValue.int32(1), .all));
        if (index % 64 == 63) _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    }

    var alive: usize = 0;
    for (ids) |id| alive += @intFromBool(!rt.atoms.symbolValueIfLive(rt, id).is(.undefined_value));
    try std.testing.expectEqual(@as(usize, 1000), alive);
}

test "TGC S3-c: a shape key keeps its atom, and the next major after the shape dies retires it" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    rt.forcePreciseRootScanForTest();

    const key = try rt.internAtom("zjsS3ShapeKeyLifetime");
    var object: ?*core.Object = try core.Object.createPlainObject(rt, null);
    var object_roots = core.runtime.rootObjects(.{&object});
    object_roots.activate(rt);
    defer object_roots.deactivate(rt);
    try object.?.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(1), .all));

    // The shape's property array is the only thing naming the id now.
    try s3RunMajor(rt);
    try std.testing.expect(rt.atoms.name(key) != null);
    try s3RunMajor(rt);
    try std.testing.expect(rt.atoms.name(key) != null);

    // Drop the object: the shape becomes garbage and the edge with it.
    object = null;
    try s3RunMajor(rt);
    try s3RunMajor(rt);
    try std.testing.expect(rt.atoms.name(key) == null);
}

test "TGC S3-c: a WeakRef'd symbol still leaves a weak shell instead of a recycled slot" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    rt.forcePreciseRootScanForTest();

    const symbol_atom = try rt.atoms.newValueSymbol("zjsS3WeakShellSymbol");
    const entry_index = symbol_atom.raw() - core.atom.first_dynamic_atom;
    {
        var symbol_value = try rt.symbolValue(symbol_atom);
        var symbol_roots = core.runtime.rootValues(.{&symbol_value});
        symbol_roots.activate(rt);
        defer symbol_roots.deactivate(rt);
        // A raw weak reference, the same accounting `WeakRef` takes.
        rt.atoms.retainSymbolWeakRef(symbol_atom);
        try s3RunMajor(rt);
        try std.testing.expect(!rt.atoms.symbolValueIfLive(rt, symbol_atom).is(.undefined_value));
    }

    // Body unreachable: the entry must become a SHELL (unindexed, no body,
    // still occupying its slot) so the WeakRef can observe the death, not a
    // free slot the next intern could hand back under the same id.
    try s3RunMajor(rt);
    try std.testing.expect(rt.atoms.symbolValueIfLive(rt, symbol_atom).is(.undefined_value));
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
    try std.testing.expect(rt.atoms.entries[entry_index].slotOccupied());
    try std.testing.expect(rt.atoms.entries[entry_index].body == null);

    // A second major must not re-run the verdict on the shell.
    try s3RunMajor(rt);
    try std.testing.expect(rt.atoms.entries[entry_index].slotOccupied());

    // The last weak reference retires the shell.
    rt.atoms.releaseSymbolWeakRef(rt, symbol_atom);
    try std.testing.expect(!rt.atoms.entries[entry_index].slotOccupied());
}

// --- TGC S3-b: host-held property-name atoms ---
//
// `JSContext.defineDataProperty` interns the embedder's `[]const u8` and then
// holds the bare id across a define that allocates a shape. See the JSON-parse
// test in `tests/exec.zig` for why the §2.6 shadow audit reading is the
// "`mark_epoch == epoch` while the frame held it" assertion.
const S3HostDefineMajorProbe = struct {
    rt: *zjs.JSRuntime,
    active: bool = false,
    majors: usize = 0,

    fn trigger(context: ?*anyopaque, size: usize) void {
        _ = size;
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (!self.active) return;
        const before = self.rt.gc.block_heap.mark_epoch;
        _ = self.rt.collectFull() catch {};
        if (self.rt.gc.block_heap.mark_epoch != before) self.majors += 1;
    }
};

test "TGC S3: a host-defined property name stays reachable across a major taken mid-define" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    // Install the standard globals before arming the probe: their own atom
    // traffic is not what this test is about.
    _ = try ctx.globalObject();

    var object = try ctx.createObject();
    var object_roots = zjs.core.runtime.rootValues(.{&object});
    object_roots.activate(rt);
    defer object_roots.deactivate(rt);

    var probe = S3HostDefineMajorProbe{ .rt = rt };
    const saved_trigger_fn = rt.gc.heap_budget.installProbe(.{ .run = S3HostDefineMajorProbe.trigger, .context = &probe });
    defer rt.gc.heap_budget.restoreProbe(saved_trigger_fn);

    rt.atoms.atom_audit_stale_edge = 0;
    probe.active = true;
    ctx.defineDataProperty(object, "zjsS3HostDefinedPropertyName", zjs.JSValue.int32(42), .{}) catch |err| {
        probe.active = false;
        return err;
    };
    probe.active = false;

    try std.testing.expect(probe.majors > 0);
    try std.testing.expectEqual(@as(usize, 0), rt.atoms.atom_audit_stale_edge);

    const answer = try ctx.getProperty(object, "zjsS3HostDefinedPropertyName");
    try std.testing.expectEqual(@as(?i32, 42), answer.as(.int));
}

test "TGC S3: a module's export names stay rooted from compile to install" {
    // The parsed record parks its names in plain fields between the end of
    // the compile and the module install that copies them; a major in that
    // window (every allocation here, as in a force-GC build) used to free a
    // second `as` alias and leave the module record naming a dead atom.
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();
    _ = try ctx.globalObject();

    var probe = S3HostDefineMajorProbe{ .rt = rt };
    const saved_trigger_fn = rt.gc.heap_budget.installProbe(.{ .run = S3HostDefineMajorProbe.trigger, .context = &probe });
    defer rt.gc.heap_budget.restoreProbe(saved_trigger_fn);

    rt.atoms.atom_audit_stale_edge = 0;
    probe.active = true;
    const result = ctx.eval(
        \\let zq = 1, zr = 2, zs = 3;
        \\export { zq, zr as zjsModuleAliasTwo, zs as zjsModuleAliasThree };
    , .{ .mode = .module, .filename = "self-alias.mjs" });
    probe.active = false;
    _ = result catch |err| return err;

    try std.testing.expect(probe.majors > 0);
    // The audit counts any edge a later major finds naming a freed atom.
    _ = try rt.forceGC(null);
    try std.testing.expectEqual(@as(usize, 0), rt.atoms.atom_audit_stale_edge);
}

test "TGC S3: a number property key stays rooted through proxy traps and accessor naming" {
    // A number key becomes a fresh atom nothing else holds. A proxy trap's
    // lookup and call run JavaScript, and naming a computed getter
    // ("get 1.5") allocates, before the key is used again; a major there
    // used to free it, handing the trap `undefined` or defining the getter
    // under a dead atom.
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();
    _ = try ctx.globalObject();
    _ = try ctx.eval(
        \\var handler = new Proxy({}, { get(t, name) { return function (t, k) { return String(k); }; } });
        \\var p = new Proxy({}, handler);
        \\var h2 = { has(t, k) { return k === String(1.5 + 1); }, deleteProperty(t, k) { return k === String(1.5 + 2); } };
        \\var p2 = new Proxy({}, h2);
    , .{});

    var probe = S3HostDefineMajorProbe{ .rt = rt };
    const saved_trigger_fn = rt.gc.heap_budget.installProbe(.{ .run = S3HostDefineMajorProbe.trigger, .context = &probe });
    defer rt.gc.heap_budget.restoreProbe(saved_trigger_fn);

    rt.atoms.atom_audit_stale_edge = 0;
    probe.active = true;
    const result = ctx.eval(
        \\var x = 1.5, n = 1e20;
        \\var o = { get [x + 8]() { return 1; } };
        \\p[x] === String(x) && p[n * 10] === String(n * 10) && ((x + 1) in p2) && delete p2[x + 2] && Object.keys(o)[0] === String(x + 8);
    , .{});
    probe.active = false;
    const value = result catch |err| return err;

    try std.testing.expect(probe.majors > 0);
    try std.testing.expectEqual(@as(?bool, true), value.as(.boolean));
    _ = try rt.forceGC(null);
    try std.testing.expectEqual(@as(usize, 0), rt.atoms.atom_audit_stale_edge);
}

test "TGC S3: a number property key stays rooted through primitive [[Set]] and sparse array conversion" {
    // Setting on a primitive boxes it (an allocation) and a dense array
    // written at an index of 2^31 or more converts its elements (more
    // allocations) before the fresh key atom is stored; a major there used
    // to free it, so the trap saw undefined or the element landed under a
    // reused atom.
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();
    _ = try ctx.globalObject();
    _ = try ctx.eval(
        \\var seen;
        \\Object.setPrototypeOf(Number.prototype, new Proxy({}, { set(t, k) { seen = k; return true; } }));
    , .{});

    var probe = S3HostDefineMajorProbe{ .rt = rt };
    const saved_trigger_fn = rt.gc.heap_budget.installProbe(.{ .run = S3HostDefineMajorProbe.trigger, .context = &probe });
    defer rt.gc.heap_budget.restoreProbe(saved_trigger_fn);

    rt.atoms.atom_audit_stale_edge = 0;
    probe.active = true;
    const result = ctx.eval(
        \\var k = 1.5, big = 2 ** 32 - 2;
        \\(5)[k + 1] = 0;
        \\var a = [1, 2, 3]; a[big] = 7; var s = {}; s[big + 3] = 0;
        \\seen === String(k + 1) && Object.keys(a).join() === '0,1,2,' + big && a[big] === 7;
    , .{});
    probe.active = false;
    const value = result catch |err| return err;

    try std.testing.expect(probe.majors > 0);
    try std.testing.expectEqual(@as(?bool, true), value.as(.boolean));
    _ = try rt.forceGC(null);
    try std.testing.expectEqual(@as(usize, 0), rt.atoms.atom_audit_stale_edge);
}
