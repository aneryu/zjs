//! Core integration tests: storage_s4.
const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const core = zjs.core;

test "needs_finalizer is recorded in both the header and the block bitmap" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    const object = try core.Object.createPlainObject(rt, null);
    const header = object.gcHeader();
    try std.testing.expect(!core.gc.headerNeedsFinalizer(header));

    rt.gc.setNeedsFinalizer(header);
    try std.testing.expect(core.gc.headerNeedsFinalizer(header));

    // A plain object is a block cell; the sweep-side authority is the
    // fourth bitmap, keyed by the cell index the prefix carries.
    try std.testing.expect(core.gc.Registry.isBlockCellHeader(header));
    const cell = @intFromPtr(header) - core.gc.metadata_prefix_size;
    const block = core.gc_block_heap.Block.fromCellTrusted(cell);
    const index = header.metaConst().size_class;
    try std.testing.expect(block.cellNeedsFinalizer(index));
    // Every other cell in the block is unaffected.
    var others: usize = 0;
    var i: u32 = 0;
    while (i < block.cell_count) : (i += 1) {
        if (i == index) continue;
        if (block.cellNeedsFinalizer(i)) others += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), others);
}

// ---------------------------------------------------------------------------
// TGC S4-b (spec 2.2): `prop_values` and the dense element buffer are
// owner-marked, destructor-free GC cells. What these tests pin down is the
// three things that changed shape at once: the buffer is now RECLAIMED by the
// sweep (nobody frees it), it is kept alive ONLY by the owner's `storageCell`
// edge, and an owner that outlived a minor has to remember a buffer minted
// after its promotion.
// ---------------------------------------------------------------------------

/// Give `obj` `count` named data properties, which grows it past the inline
/// slots2 tail into an external `.property_storage` cell.
fn defineS4bNamedProperties(rt: *core.JSRuntime, obj: *core.Object, prefix: []const u8, count: usize) !void {
    var buf: [64]u8 = undefined;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const name = try std.fmt.bufPrint(&buf, "{s}{d}", .{ prefix, index });
        const key = try rt.internAtom(name);
        try obj.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(@intCast(index)), .all));
    }
}

fn expectS4bNamedProperties(rt: *core.JSRuntime, obj: *core.Object, prefix: []const u8, count: usize) !void {
    var buf: [64]u8 = undefined;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const name = try std.fmt.bufPrint(&buf, "{s}{d}", .{ prefix, index });
        const key = try rt.internAtom(name);
        try std.testing.expectEqual(@as(?i32, @intCast(index)), (try obj.getProperty(key)).as(.int));
    }
}

/// Append `count` dense elements one at a time, which walks
/// `ensureArrayBufferCapacity` up its whole 1.5x growth ladder.
fn fillS4bDenseArray(rt: *core.JSRuntime, arr: *core.Object, count: u32) !void {
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        // One slot at a time, so the buffer walks the whole growth ladder
        // instead of jumping straight to the final capacity.
        try arr.fastArrayEnsureCapacity(rt, index + 1);
        try std.testing.expectEqual(
            engine.exec.array_ops.DenseArrayOverwriteFastResult.handled,
            engine.exec.array_ops.putDenseArrayElementOverwriteOwnedFast(
                rt,
                arr.value(),
                core.JSValue.int32(@intCast(index)),
                core.JSValue.int32(@intCast(index)),
            ),
        );
    }
}

test "storage-cell mint writes runtime kind tags on block and extent paths" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const cases = [_]struct { u8, core.gc.GcKind }{
        .{ core.gc.representation.payload_kind_tag, .payload },
        .{ core.gc.representation.property_storage_kind_tag, .property_storage },
        .{ core.gc.representation.array_storage_kind_tag, .array_storage },
        .{ core.gc.representation.string_buffer_kind_tag, .string_buffer },
    };
    // Prefix + 16-byte body. For `.string_buffer` that body is the 8-byte
    // StringBuffer header plus 8 latin1 units — teardown sizes the cell
    // from `capacity`, so the header must match the request.
    const small = core.gc.metadata_prefix_size + 16;
    const large = core.gc_space.large_min_bytes;
    for (cases) |case| {
        const small_body = try rt.gc.createStorageCellPublished(case[0], small);
        installMintedStringBufferBody(case[1], small_body, small);
        const small_header: *core.gc.Header = @ptrCast(@alignCast(small_body));
        try std.testing.expectEqual(case[1], small_header.metaConst().flags.kind);
        try std.testing.expect(core.gc.Registry.isBlockCellHeader(small_header));

        const large_body = try rt.gc.createStorageCellPublished(case[0], large);
        installMintedStringBufferBody(case[1], large_body, large);
        const large_header: *core.gc.Header = @ptrCast(@alignCast(large_body));
        try std.testing.expectEqual(case[1], large_header.metaConst().flags.kind);
        try std.testing.expect(!core.gc.Registry.isBlockCellHeader(large_header));
    }
}

fn installMintedStringBufferBody(kind: core.gc.GcKind, body: [*]u8, total_bytes: usize) void {
    if (kind != .string_buffer) return;
    const buf: *core.string.StringBuffer = @ptrCast(@alignCast(body));
    buf.* = .{
        .capacity = @intCast(total_bytes - core.gc.metadata_prefix_size - core.string.StringBuffer.units_offset),
        .is_wide = false,
    };
}

test "TGC S4-b: an external property buffer survives with its owner and dies one major later" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    var owner_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.object, null);
    var owner_roots = core.runtime.rootObjects(.{&owner_slot});
    owner_roots.activate(rt);
    defer owner_roots.deactivate(rt);
    try defineS4bNamedProperties(rt, owner_slot.?, "s4b-live-", 6);

    // Growth left the superseded buffers on the heap: nothing frees a cell.
    try std.testing.expect(rt.gc.liveCountKind(.property_storage) > 1);
    const storage: *core.gc.Header = @ptrCast(@alignCast(owner_slot.?.prop_values));
    try std.testing.expect(owner_slot.?.propertyStoragePointerIsExternal(owner_slot.?.prop_values));

    // Deletion probe: drop the `storageCell` edge from
    // `tracePropertyEdgesFallible` and this major reclaims the buffer under a
    // live owner (the reads below then walk a recycled cell).
    _ = try rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCountKind(.property_storage));
    try std.testing.expect(rt.gc.containsHeader(storage));
    try expectS4bNamedProperties(rt, owner_slot.?, "s4b-live-", 6);

    owner_slot = null;
    _ = try rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.property_storage));
}

test "TGC S4-b: an aged owner remembers a property buffer minted after its promotion" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    var owner_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.object, null);
    var owner_roots = core.runtime.rootObjects(.{&owner_slot});
    owner_roots.activate(rt);
    defer owner_roots.deactivate(rt);

    // Promote the owner before it owns any external storage: the minor's
    // sticky marks stop the trace at an old object, so from here every buffer
    // it adopts is an old-to-young edge that only a barrier can record.
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    try std.testing.expect(!owner_slot.?.gcHeader().metaConst().flags.young);

    try defineS4bNamedProperties(rt, owner_slot.?, "s4b-grow-", 8);
    const storage: *core.gc.Header = @ptrCast(@alignCast(owner_slot.?.prop_values));
    try std.testing.expect(storage.metaConst().flags.young);

    // Deletion probe: drop `rememberOwnerForBulkWrite` from
    // `appendPreparedPropertyEntryWork` / `ensurePropertyCapacity` and this
    // minor condemns the buffer while `prop_values` still names it.
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    try std.testing.expect(rt.gc.containsHeader(storage));
    try expectS4bNamedProperties(rt, owner_slot.?, "s4b-grow-", 8);
}

test "Q22: a bitmap-reclaimed storage cell leaves the byte ledger exactly once" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    var array_slot: ?*core.Object = null;
    var array_roots = core.runtime.rootObjects(.{&array_slot});
    array_roots.activate(rt);
    defer array_roots.deactivate(rt);

    // Round 0 warms every lazily created persistent (the realm's initial
    // array shape, atoms); round 1 is the measured one, and its ledger must
    // return to the exact pre-allocation value. A corpse debited on both
    // routes (`reclaimDoomedBlock`'s per-corpse unpublish and the
    // `debitBlockBytes` batch) would land below it; a missed debit above.
    var round: usize = 0;
    while (round < 2) : (round += 1) {
        const before_owner = rt.allocation_diagnostics.allocated_bytes;
        array_slot = try core.Object.createArray(rt, null);
        // Promote the owner first: every cell it adopts from here is an
        // old-to-young bulk write, so `rememberOwnerForBulkWrite` puts the
        // owner in the remembered map -- the condition that makes
        // `reclaimDoomedBlock` walk the corpses (test builds walk them
        // unconditionally under the lifecycle audit as well).
        _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
        try std.testing.expect(!array_slot.?.gcHeader().metaConst().flags.young);
        const before_cells = rt.allocation_diagnostics.allocated_bytes;

        try fillS4bDenseArray(rt, array_slot.?, 40);
        try std.testing.expect(rt.gc.generation.rememberedCount() != 0);
        try std.testing.expect(rt.gc.liveCountKind(.array_storage) > 4);
        const grown = rt.allocation_diagnostics.allocated_bytes;
        try std.testing.expect(grown > before_cells);

        // The superseded buffers owe no destructor: bitmap route only.
        _ = try rt.collectForTest();
        try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCountKind(.array_storage));
        const one_cell = rt.allocation_diagnostics.allocated_bytes;
        try std.testing.expect(one_cell < grown);
        try std.testing.expect(one_cell > before_cells);

        array_slot = null;
        _ = try rt.collectForTest();
        try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.array_storage));
        if (round == 1) try std.testing.expectEqual(before_owner, rt.allocation_diagnostics.allocated_bytes);
    }
}

test "TGC S4-b: a growing dense array leaves every superseded element cell to the sweep" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    var array_slot: ?*core.Object = try core.Object.createArray(rt, null);
    var array_roots = core.runtime.rootObjects(.{&array_slot});
    array_roots.activate(rt);
    defer array_roots.deactivate(rt);

    // The 1.5x ladder from an empty array takes well over four steps to reach
    // 40 slots, so the heap is holding a stack of superseded buffers: growth
    // no longer frees the old one.
    try fillS4bDenseArray(rt, array_slot.?, 40);
    try std.testing.expect(rt.gc.liveCountKind(.array_storage) > 4);

    _ = try rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCountKind(.array_storage));
    try std.testing.expectEqual(@as(usize, 40), array_slot.?.arrayElements().len);
    for (array_slot.?.arrayElements(), 0..) |element, index| {
        try std.testing.expectEqual(@as(?i32, @intCast(index)), element.as(.int));
    }

    array_slot = null;
    _ = try rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.array_storage));
}

test "Q21: the element cell is kept alive by the arm, not by flags.fast_array" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    var array_slot: ?*core.Object = try core.Object.createArray(rt, null);
    var array_roots = core.runtime.rootObjects(.{&array_slot});
    array_roots.activate(rt);
    defer array_roots.deactivate(rt);

    try fillS4bDenseArray(rt, array_slot.?, 40);
    _ = try rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCountKind(.array_storage));
    const cell = core.Object.arrayStorageCellHeader(array_slot.?.arrayArm().*.values);
    try std.testing.expect(rt.gc.containsHeader(cell));

    // A dense-mode transition that leaves the buffer attached. No production
    // path does this today (both clears go through
    // `freeArrayElementBufferAfterMove`), but the flag is a semantics bit and
    // the collector's edge must come from the arm: with the trace guarded on
    // `flags.fast_array` this major sweeps the cell the arm still names.
    array_slot.?.flags.fast_array = false;
    _ = try rt.collectForTest();
    try std.testing.expect(rt.gc.containsHeader(cell));
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCountKind(.array_storage));

    array_slot.?.flags.fast_array = true;
    try std.testing.expectEqual(@as(usize, 40), array_slot.?.arrayElements().len);
    for (array_slot.?.arrayElements(), 0..) |element, index| {
        try std.testing.expectEqual(@as(?i32, @intCast(index)), element.as(.int));
    }

    array_slot = null;
    _ = try rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.array_storage));
}

test "TGC S4-b: a mapped-arguments var-ref table is an array storage cell" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    var arguments_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.mapped_arguments, null);
    var target_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.object, null);
    var roots = core.runtime.rootObjects(.{ &arguments_slot, &target_slot });
    roots.activate(rt);
    defer roots.deactivate(rt);

    const refs = try arguments_slot.?.allocateMappedArgumentsVarRefsAssumingEmpty(rt, 2);
    refs[0] = try core.VarRef.createClosed(rt, target_slot.?.value());
    refs[1] = try core.VarRef.createClosed(rt, core.JSValue.int32(7));
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCountKind(.array_storage));

    // The owner's trace reads the SAME cell as `?*VarRef` rather than
    // `JSValue`; the cell itself has no self-interpretation to disagree with.
    _ = try rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCountKind(.array_storage));
    const live_refs = arguments_slot.?.argumentsVarRefs();
    try std.testing.expectEqual(@as(usize, 2), live_refs.len);
    try std.testing.expect(live_refs[0].?.varRefValue().sameValue(target_slot.?.value()));
    try std.testing.expectEqual(@as(?i32, 7), live_refs[1].?.varRefValue().as(.int));

    arguments_slot = null;
    target_slot = null;
    _ = try rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.array_storage));
}

test "TGC S4-b: storage over the block-cell ceiling takes the extent route and is swept" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    var owner_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.object, null);
    var array_slot: ?*core.Object = try core.Object.createArray(rt, null);
    var roots = core.runtime.rootObjects(.{ &owner_slot, &array_slot });
    roots.activate(rt);
    defer roots.deactivate(rt);

    // 3760 bytes is the small-class ceiling (TGC S2-f), so both of these run
    // off the end of it and land in the block heap's extent tables instead.
    try defineS4bNamedProperties(rt, owner_slot.?, "s4b-extent-", 200);
    try fillS4bDenseArray(rt, array_slot.?, 400);

    const property_storage: *core.gc.Header = @ptrCast(@alignCast(owner_slot.?.prop_values));
    const array_storage: *core.gc.Header = @ptrCast(@alignCast(array_slot.?.arrayElements().ptr));
    try std.testing.expect(!core.gc.Registry.isBlockCellHeader(property_storage));
    try std.testing.expect(property_storage.metaConst().alloc_info.standalone);
    try std.testing.expect(!core.gc.Registry.isBlockCellHeader(array_storage));
    try std.testing.expect(array_storage.metaConst().alloc_info.standalone);

    // An extent's mark lives in the extent table, not a block bitmap: the same
    // `storageCell` edge has to reach it, and `sweepExtents` has to give it
    // back on the kind-dispatched pure-memory arm.
    _ = try rt.collectForTest();
    try expectS4bNamedProperties(rt, owner_slot.?, "s4b-extent-", 200);
    try std.testing.expectEqual(@as(usize, 400), array_slot.?.arrayElements().len);
    try std.testing.expectEqual(@as(?i32, 399), array_slot.?.arrayElements()[399].as(.int));

    owner_slot = null;
    array_slot = null;
    _ = try rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.property_storage));
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.array_storage));
}

/// Register a dynamic class whose only interesting property is the a-class
/// payload kind it selects, for the kinds no standard class declares.
fn registerS4cPayloadClass(
    rt: *core.JSRuntime,
    name: []const u8,
    payload_kind: core.class.PayloadKind,
) !core.class.ClassId {
    const binding = try rt.registerClass(.{ .class_name = name, .payload_kind = payload_kind });
    return binding.id;
}

test "destroying an old remembered Object removes it from the remembered set" {
    // An `errdefer destroyFromHeader` after user code ran can free an object
    // a barrier remembered; its cell may be reused by another kind.
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.forcePreciseRootScanForTest();
    var owner: ?*core.Object = try core.Object.create(rt, core.class.ids.object, null);
    var roots = core.runtime.rootObjects(.{&owner});
    roots.activate(rt);
    defer roots.deactivate(rt);
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    try std.testing.expect(!owner.?.gcHeader().metaConst().flags.young);
    const young = try core.Object.create(rt, core.class.ids.object, null);
    rt.gc.generationalBarrier(owner.?.gcHeader(), young.gcHeader());
    const address = @intFromPtr(owner.?.gcHeader());
    try std.testing.expect(rt.gc.generation.remembered.contains(address));
    const header = owner.?.gcHeader();
    owner = null;
    core.Object.destroyFromHeader(rt, header);
    try std.testing.expect(!rt.gc.generation.remembered.contains(address));
}

test "promise coallocation: state and reactions survive through the sole owner" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.forcePreciseRootScanForTest();
    var promise: ?*core.Object = try core.Object.create(rt, core.class.ids.promise, null);
    var temporary: ?*core.Object = null;
    var roots = core.runtime.rootObjects(.{ &promise, &temporary });
    roots.activate(rt);
    defer roots.deactivate(rt);

    try std.testing.expect(!promise.?.hasTracerOwnedPayloadCell());
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.payload));
    const payload = promise.?.promisePayload().?;
    const base = @intFromPtr(promise.?);
    try std.testing.expect(@intFromPtr(payload) >= base + @sizeOf(core.Object));
    try std.testing.expect(@intFromPtr(payload) + @sizeOf(@TypeOf(payload.*)) <= base + core.Object.objectBodyBytes(core.class.ids.promise, false));
    const result_slot = promise.?.promiseResultSlot();
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    try std.testing.expect(!promise.?.gcHeader().metaConst().flags.young);
    var targets: [2]*core.gc.Header = undefined;
    for (&targets, 0..) |*header, index| {
        temporary = try core.Object.create(rt, core.class.ids.object, null);
        header.* = temporary.?.gcHeader();
        switch (index) {
            0 => try promise.?.setPromiseResult(rt, temporary.?.value()),
            1 => for (0..6) |_| {
                try engine.exec.promise_ops.appendPromiseReaction(rt, promise.?, temporary.?.value());
            },
            else => unreachable,
        }
    }
    temporary = null;
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    for (targets) |header| try std.testing.expect(rt.gc.containsHeader(header));
    _ = try rt.collectForTest();
    for (targets) |header| try std.testing.expect(rt.gc.containsHeader(header));
    try std.testing.expectEqual(result_slot, promise.?.promiseResultSlot());
    try std.testing.expectEqual(@as(usize, 6), promise.?.promiseReactions().len);
    // Only the final reaction backing is a standalone payload cell.
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCountKind(.payload));
    promise = null;
    _ = try rt.collectForTest();
    for (targets) |header| try std.testing.expect(!rt.gc.containsHeader(header));
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.payload));
}

test "promise coallocation: accounting and allocation failure share the object cell" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.forcePreciseRootScanForTest();
    rt.setGCThreshold(std.math.maxInt(usize));
    var promise: ?*core.Object = try core.Object.create(rt, core.class.ids.promise, null);
    var roots = core.runtime.rootObjects(.{&promise});
    roots.activate(rt);
    defer roots.deactivate(rt);
    _ = try rt.collectForTest();
    const raw_bytes = rt.gc.block_heap.rawBytesForCell(@intFromPtr(promise.?), core.gc.metadata_prefix_size).?;
    const expected = raw_bytes - core.gc.metadata_prefix_size;
    try std.testing.expectEqual(expected, promise.?.bodyBytes());
    try std.testing.expectEqual(expected, promise.?.allocationSize(rt));
    try std.testing.expectEqual(expected, core.gc.Registry.heapByteSizeFromHeader(rt, promise.?.gcHeader()));
    const objects_before = rt.gc.liveCountKind(.object);
    rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
    defer rt.setNativeBytesLimitForTest(null);
    try std.testing.expectError(error.OutOfMemory, core.Object.create(rt, core.class.ids.promise, null));
    rt.setNativeBytesLimitForTest(null);
    try std.testing.expectEqual(objects_before, rt.gc.liveCountKind(.object));
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.payload));
    const next = try core.Object.create(rt, core.class.ids.promise, null);
    try std.testing.expect(next.promiseResult() == null);
    try std.testing.expectEqual(objects_before + 1, rt.gc.liveCountKind(.object));
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.payload));
}

test "TGC S4-c: every a-class payload is a cell that dies one major after its owner" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.payload));

    const arguments_class = try registerS4cPayloadClass(rt, "S4cArguments", .arguments);
    const var_ref_class = try registerS4cPayloadClass(rt, "S4cVarRef", .var_ref);
    const regexp_class = try registerS4cPayloadClass(rt, "S4cRegExp", .regexp);

    const promise_class = try registerS4cPayloadClass(rt, "S4cPromise", .promise);

    // One owner per out-of-line a-class payload kind. Built-in Promise state
    // is inline; a custom class still exercises its separate payload cell.
    // `.ordinary`, `.global` and `.proxy`
    // attach lazily; the rest are minted by `createInternal`.
    var ordinary_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.object, null);
    var arguments_slot: ?*core.Object = try core.Object.create(rt, arguments_class, null);
    var object_data_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.string, null);
    var bound_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.bound_function, null);
    var proxy_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.proxy, null);
    var var_ref_slot: ?*core.Object = try core.Object.create(rt, var_ref_class, null);
    var promise_slot: ?*core.Object = try core.Object.create(rt, promise_class, null);
    var stack_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.disposable_stack, null);
    var global_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.global_object, null);
    var regexp_slot: ?*core.Object = try core.Object.create(rt, regexp_class, null);
    var roots = core.runtime.rootObjects(.{
        &ordinary_slot, &arguments_slot, &object_data_slot, &bound_slot,
        &proxy_slot,    &var_ref_slot,   &promise_slot,     &stack_slot,
        &global_slot,   &regexp_slot,
    });
    roots.activate(rt);
    defer roots.deactivate(rt);

    _ = try ordinary_slot.?.ensureOrdinaryPayload(rt);
    try proxy_slot.?.ensureProxyPayload(rt);
    _ = try global_slot.?.ensureGlobalPayload(rt);

    // Contents that must survive: each payload holds one strong edge back to
    // an object only the payload names.
    var target_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.object, null);
    var target_roots = core.runtime.rootObjects(.{&target_slot});
    target_roots.activate(rt);
    defer target_roots.deactivate(rt);
    try ordinary_slot.?.setErrorStack(rt, target_slot.?.value());
    object_data_slot.?.objectDataSlot().* = target_slot.?.value();
    bound_slot.?.boundTargetSlot().* = target_slot.?.value();
    proxy_slot.?.proxyTargetSlot().* = target_slot.?.value();
    promise_slot.?.promiseResultSlot().* = target_slot.?.value();

    const expected_payloads: usize = 10;
    try std.testing.expectEqual(expected_payloads, rt.gc.liveCountKind(.payload));

    // Deletion probe: drop the `storageCell(payload)` edge from
    // `traceChildEdgesFallible` and this major reclaims every payload under a
    // live owner.
    _ = try rt.collectForTest();
    try std.testing.expectEqual(expected_payloads, rt.gc.liveCountKind(.payload));
    try std.testing.expect(ordinary_slot.?.errorStack().?.same(target_slot.?.value()));
    try std.testing.expect(object_data_slot.?.objectData().?.same(target_slot.?.value()));
    try std.testing.expect(bound_slot.?.boundTarget().?.same(target_slot.?.value()));
    try std.testing.expect(proxy_slot.?.proxyTarget().?.same(target_slot.?.value()));
    try std.testing.expect(promise_slot.?.promiseResult().?.same(target_slot.?.value()));

    ordinary_slot = null;
    arguments_slot = null;
    object_data_slot = null;
    bound_slot = null;
    proxy_slot = null;
    var_ref_slot = null;
    promise_slot = null;
    stack_slot = null;
    global_slot = null;
    regexp_slot = null;
    _ = try rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.payload));
}

test "TGC S4-c: a bytecode function's rare/aux record is a payload cell" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    var function_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.bytecode_function, null);
    var roots = core.runtime.rootObjects(.{&function_slot});
    roots.activate(rt);
    defer roots.deactivate(rt);

    // Touching any rare slot materializes `BytecodeFunctionAux` behind the
    // low-bit-tagged `home_or_aux` word.
    _ = try function_slot.?.arrayBuiltinMarkerSlot(rt);
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCountKind(.payload));

    var source_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.object, null);
    var source_roots = core.runtime.rootObjects(.{&source_slot});
    source_roots.activate(rt);
    defer source_roots.deactivate(rt);
    (try function_slot.?.functionSourceSlot(rt)).* = source_slot.?.value();

    _ = try rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCountKind(.payload));
    try std.testing.expect(function_slot.?.functionSource().?.same(source_slot.?.value()));

    function_slot = null;
    _ = try rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.payload));
}

test "TGC S4-c: an aged promise remembers a reaction cell minted after its promotion" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    var promise_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.promise, null);
    var target_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.object, null);
    var roots = core.runtime.rootObjects(.{ &promise_slot, &target_slot });
    roots.activate(rt);
    defer roots.deactivate(rt);

    // Promote the promise (and its payload cell) before it owns a reaction
    // list, so every subsequent growth cell is an old-to-young edge.
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    try std.testing.expect(!promise_slot.?.gcHeader().metaConst().flags.young);

    // Six subscribers walk past the initial capacity of four, so the live list
    // lives in a SECOND cell and the first is superseded garbage.
    var index: usize = 0;
    while (index < 6) : (index += 1) {
        try engine.exec.promise_ops.appendPromiseReaction(rt, promise_slot.?, target_slot.?.value());
    }
    const reactions_cell: *core.gc.Header = @ptrCast(@alignCast(promise_slot.?.promiseReactions().ptr));
    try std.testing.expect(reactions_cell.metaConst().flags.young);

    // Deletion probe: drop `rememberOwnerForBulkWrite` from
    // `appendPromiseReaction` and this minor condemns the reaction list while
    // the promise payload still names it.
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    try std.testing.expect(rt.gc.containsHeader(reactions_cell));
    try std.testing.expectEqual(@as(usize, 6), promise_slot.?.promiseReactions().len);
    for (promise_slot.?.promiseReactions()) |reaction| {
        try std.testing.expect(reaction.same(target_slot.?.value()));
    }
}

test "TGC S4-c: bound arguments, disposable resources and arguments var-refs cross a major" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const arguments_class = try registerS4cPayloadClass(rt, "S4cArgumentsSlice", .arguments);

    var bound_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.bound_function, null);
    var stack_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.disposable_stack, null);
    var arguments_slot: ?*core.Object = try core.Object.create(rt, arguments_class, null);
    var target_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.object, null);
    var roots = core.runtime.rootObjects(.{
        &bound_slot, &stack_slot, &arguments_slot, &target_slot,
    });
    roots.activate(rt);
    defer roots.deactivate(rt);

    const args = try core.Object.createPayloadSliceCell(rt, core.JSValue, 2);
    args[0] = target_slot.?.value();
    args[1] = core.JSValue.int32(7);
    bound_slot.?.boundArgsSlot().* = args;

    // Six resources walk the 4 -> 8 growth step, so the live list is a second
    // cell and the first is superseded garbage.
    var index: usize = 0;
    while (index < 6) : (index += 1) {
        try stack_slot.?.appendDisposableResource(
            rt,
            target_slot.?.value(),
            core.JSValue.undefinedValue(),
            .defer_,
            .sync,
            .direct,
        );
    }

    const arguments_payload: *core.object.ArgumentsPayload =
        @ptrCast(@alignCast(arguments_slot.?.payloadArm().*.?));
    arguments_payload.var_refs = try core.Object.createPayloadSliceCell(rt, core.JSValue, 1);
    arguments_payload.var_refs[0] = target_slot.?.value();

    // Deletion probe: drop any of the three `storageCell` edges in
    // `object_payloads.zig` and this major reclaims the slice under a live
    // owner.
    _ = try rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 2), bound_slot.?.boundArgs().len);
    try std.testing.expect(bound_slot.?.boundArgs()[0].same(target_slot.?.value()));
    try std.testing.expectEqual(@as(?i32, 7), bound_slot.?.boundArgs()[1].as(.int));
    var popped: usize = 0;
    while (stack_slot.?.popDisposableResource()) |resource| {
        try std.testing.expect(resource.value.same(target_slot.?.value()));
        popped += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), popped);
    try std.testing.expectEqual(@as(usize, 1), arguments_payload.var_refs.len);
    try std.testing.expect(arguments_payload.var_refs[0].same(target_slot.?.value()));

    bound_slot = null;
    stack_slot = null;
    arguments_slot = null;
    target_slot = null;
    _ = try rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.payload));
}

test "TGC S4-c: a payload slice over the block-cell ceiling takes the extent route" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    var bound_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.bound_function, null);
    var target_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.object, null);
    var roots = core.runtime.rootObjects(.{ &bound_slot, &target_slot });
    roots.activate(rt);
    defer roots.deactivate(rt);

    // 3760 bytes is the small-class ceiling (TGC S2-f). The payload STRUCTS
    // all fit a cell; only a subordinate slice can run off the end of it.
    const args = try core.Object.createPayloadSliceCell(rt, core.JSValue, 500);
    for (args) |*slot| slot.* = target_slot.?.value();
    bound_slot.?.boundArgsSlot().* = args;

    const storage: *core.gc.Header = @ptrCast(@alignCast(args.ptr));
    try std.testing.expect(!core.gc.Registry.isBlockCellHeader(storage));
    try std.testing.expect(storage.metaConst().alloc_info.standalone);

    // An extent's mark lives in the extent table, not a block bitmap: the
    // payload's `storageCell` edge has to reach it, and `sweepExtents` has to
    // give it back on the pure-memory arm rather than reading it as a String.
    _ = try rt.collectForTest();
    try std.testing.expect(rt.gc.containsHeader(storage));
    try std.testing.expectEqual(@as(usize, 500), bound_slot.?.boundArgs().len);
    try std.testing.expect(bound_slot.?.boundArgs()[499].same(target_slot.?.value()));

    bound_slot = null;
    target_slot = null;
    _ = try rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.payload));
}
