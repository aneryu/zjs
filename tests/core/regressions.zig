//! Core integration tests: regressions.
const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const core = zjs.core;
const common = @import("common.zig");
const appendFinalizationRegistryCell = common.appendFinalizationRegistryCell;
const dropGcPtr = common.dropGcPtr;

test "conservative scan retains nursery objects named only by native frames" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.gc.nursery.enabled = true;
    const object = try core.Object.createPlainObject(rt, null);
    try std.testing.expect(core.gc.Registry.isNurseryHeader(object.gcHeader()));
    // Only this frame names the object: no declared root.
    var held: *core.Object = object;
    std.mem.doNotOptimizeAway(&held);
    _ = try core.gc_trace_stw.collectMinor(rt, .engine_active);
    std.mem.doNotOptimizeAway(&held);
    try std.testing.expect(!core.gc.headerForwarded(held.gcHeader()));
    try std.testing.expect(rt.gc.containsHeader(held.gcHeader()));
}

test "nursery residents kept in place are traced again by the next minor" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.gc.nursery.enabled = true;
    const object = try core.Object.createPlainObject(rt, null);
    try std.testing.expect(core.gc.Registry.isNurseryHeader(object.gcHeader()));
    // A ledger pin keeps the object on its nursery page, marked in place.
    try rt.gc.pinHeader(object.gcHeader());
    defer rt.gc.unpinHeader(object.gcHeader());
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    try std.testing.expect(core.gc.Registry.isNurseryHeader(object.gcHeader()));
    // Grow into fresh young property storage holding fresh young values; only
    // the object names them.
    var keys: [40]core.Atom = undefined;
    for (&keys, 0..) |*key, i| {
        key.* = core.Atom.taggedInt(@intCast(i));
        const value = try core.Object.createPlainObject(rt, null);
        try object.defineOwnProperty(rt, key.*, core.Descriptor.data(value.value(), .all));
    }
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    for (keys) |key| {
        const value = try object.getProperty(key);
        try std.testing.expect(rt.gc.containsHeader(value.cycleMarkHeader().?));
    }
}

test "a dead resident on a retained nursery page is not resurrected" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.gc.nursery.enabled = true;
    const keeper = try core.Object.createPlainObject(rt, null);
    const corpse = try core.Object.createPlainObject(rt, null);
    try std.testing.expect(rt.gc.nursery.pageOf(@intFromPtr(keeper.gcHeader())) == rt.gc.nursery.pageOf(@intFromPtr(corpse.gcHeader())));
    // The keeper retains the shared page; the corpse is unreachable.
    try rt.gc.pinHeader(keeper.gcHeader());
    defer rt.gc.unpinHeader(keeper.gcHeader());
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    try std.testing.expect(!rt.gc.containsHeader(corpse.gcHeader()) or !corpse.gcHeader().metaConst().alloc_info.heap_accounted);
    // A stale native word naming the corpse must not bring it back.
    var stale: *core.Object = corpse;
    std.mem.doNotOptimizeAway(&stale);
    _ = try core.gc_trace_stw.collectMinor(rt, .engine_active);
    std.mem.doNotOptimizeAway(&stale);
    try std.testing.expect(!rt.gc.headerMarked(stale.gcHeader()));
}

test "nursery evacuation moves self-referencing owners with inline and external property storage" {
    for ([_]bool{ false, true }) |external| {
        const rt = try core.JSRuntime.create(std.testing.allocator, .{});
        defer rt.destroy();
        rt.gc.nursery.enabled = true;
        var values = [_]core.JSValue{core.JSValue.undefinedValue()};
        const live: []core.JSValue = &values;
        const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &live }};
        var frame = core.runtime.ValueRootFrame{ .slices = &slices };
        frame.activate(rt);
        defer frame.deactivate(rt);
        const owner = try core.Object.createPlainObjectReserved2(rt, null);
        values[0] = owner.value();
        const self_key = try rt.internAtom("self");
        try owner.defineOwnProperty(rt, self_key, core.Descriptor.data(owner.value(), .all));
        // Enough further properties to leave the inline slots2 tail for an
        // external property storage cell, which does not move with the body.
        const extra: usize = if (external) 12 else 0;
        for (0..extra) |i| try owner.defineOwnProperty(rt, core.Atom.taggedInt(@intCast(i)), core.Descriptor.data(owner.value(), .all));
        try std.testing.expectEqual(!external, owner.hasSlots2Layout() and owner.prop_values == owner.trailingPropertyStorageBase());
        const before = values[0].bits;
        _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
        try std.testing.expect(values[0].bits != before);
        const moved = core.Object.fromHeader(values[0].cycleMarkHeader().?);
        // Inline storage follows the body; every self-reference names the copy.
        if (!external) try std.testing.expect(moved.prop_values == moved.trailingPropertyStorageBase());
        try std.testing.expect((try moved.getProperty(self_key)).same(moved.value()));
        for (0..extra) |i| try std.testing.expect((try moved.getProperty(core.Atom.taggedInt(@intCast(i)))).same(moved.value()));
    }
}

test "the minor audit reports an old owner holding an unbarriered young child" {
    // A store that skips the write barrier leaves the old array unremembered,
    // so the minor condemns the child the array still names: exactly what
    // `ZJS_GC_AUDIT` exists to report. Verify is off here -- it would (rightly)
    // reject the deliberately broken heap first.
    const saved_forensics = core.gc.forensics;
    defer core.gc.forensics = saved_forensics;
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    // After `create`: registry creation re-reads ZJS_GC_* from the environment.
    core.gc.forensics = .{ .audit = .count };
    var values = [_]core.JSValue{core.JSValue.undefinedValue()};
    const live: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &live }};
    var frame = core.runtime.ValueRootFrame{ .slices = &slices };
    frame.activate(rt);
    defer frame.deactivate(rt);
    const array = try core.Object.createArray(rt, null);
    values[0] = array.value();
    try array.appendFastArrayPushValues(rt, &.{core.JSValue.int32(1)});
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    try std.testing.expect(!array.gcHeader().metaConst().flags.young);
    try std.testing.expect(!rt.gc.generation.isRemembered(array.gcHeader()));

    const child = try core.Object.createPlainObject(rt, null);
    array.arrayElements()[0] = child.value(); // no barrier
    const reports_before = core.gc.forensics.audit_reports;
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    // The child is gone; drop the dangling slot before anything reads it.
    array.arrayElements()[0] = core.JSValue.int32(0);
    try std.testing.expect(core.gc.forensics.audit_reports > reports_before);
}

test "dense array in-capacity append remembers an old array" {
    const saved_forensics = core.gc.forensics;
    defer core.gc.forensics = saved_forensics;
    core.gc.forensics.audit = .fatal;
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var values = [_]core.JSValue{core.JSValue.undefinedValue()} ** 2;
    const live: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &live }};
    var frame = core.runtime.ValueRootFrame{ .slices = &slices };
    frame.activate(rt);
    defer frame.deactivate(rt);
    const array = try core.Object.createArray(rt, null);
    values[0] = array.value();
    try array.appendFastArrayPushValues(rt, &.{ core.JSValue.int32(1), core.JSValue.int32(2), core.JSValue.int32(3), core.JSValue.int32(4) });
    // Spare capacity past the count, then age the array.
    array.truncateArrayElements(rt, 2);
    array.setArrayLength(2);
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    try std.testing.expect(!array.gcHeader().metaConst().flags.young);
    const child = try core.Object.createPlainObject(rt, null);
    try std.testing.expectEqual(
        engine.exec.array_ops.DenseArrayOverwriteFastResult.handled,
        engine.exec.array_ops.putDenseArrayElementOverwriteOwnedFast(rt, array.value(), core.JSValue.int32(2), child.value()),
    );
    const child_header = child.gcHeader();
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    try std.testing.expect(rt.gc.containsHeader(child_header));
    try std.testing.expect(array.arrayElements()[2].same(child.value()));
}

test "an interrupt during a RegExp match is uncatchable for exec, test, and replace" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    // `arm()` makes every later interrupt poll fire. Catastrophic
    // backtracking reaches the matcher's poll long before the interpreter's.
    const Switch = struct {
        armed: bool = false,

        fn arm(c: *zjs.Call) zjs.Value {
            c.state(@This()).armed = true;
            return zjs.Value.undefinedValue();
        }

        fn poll(_: *zjs.JSRuntime, raw: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.armed;
        }
    };
    var state = Switch{};
    _ = try ctx.defineFunction("arm", Switch.arm, .{ .state = @ptrCast(&state) });
    rt.setInterruptHandler(Switch.poll, &state);
    defer rt.setInterruptHandler(null, null);

    const sources = [_][]const u8{
        "var s = 'a'.repeat(40) + 'b'; arm(); try { /(a|aa)+$/.exec(s); } catch (e) {}",
        "var s = 'a'.repeat(40) + 'b'; arm(); try { /(a|aa)+$/.test(s); } catch (e) {}",
        "var s = 'a'.repeat(40) + 'b'; arm(); try { s.replace(/(a|aa)+$/g, ''); } catch (e) {}",
    };
    for (sources) |source| {
        state.armed = false;
        try std.testing.expectError(error.Interrupted, ctx.eval(source, .{}));
        try std.testing.expect(ctx.hasException());
        ctx.clearException();
    }
}

test "Call.throwError reports a failure to build the Error instead of a bare JSException" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const Host = struct {
        fn throwUnderLimit(c: *zjs.Call) !zjs.Value {
            c.runtime().setMemoryLimit(0);
            return c.throwTypeError("unreachable message");
        }
    };
    _ = try ctx.defineFunction("throwUnderLimit", zjs.native.managed(Host.throwUnderLimit), .{});
    defer rt.setMemoryLimit(null);

    try std.testing.expectError(error.OutOfMemory, ctx.eval("throwUnderLimit()", .{}));
}

test "a tracked unhandled rejection from a native call leaves no pending exception" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{ .track_unhandled_rejections = true });
    defer ctx.destroy();

    const result = try ctx.eval("Promise.reject(2); Promise.all(1); Math.max(1, 2)", .{});
    try std.testing.expectEqual(@as(?i32, 2), result.as(.int));
    try std.testing.expect(ctx.hasUnhandledRejection());
    try std.testing.expect(!ctx.hasException());
    try std.testing.expectEqual(@as(?i32, 2), ctx.takeUnhandledRejection().as(.int));

    // Handling the rejection later removes it from the report.
    _ = try ctx.eval("const late = Promise.reject(3); late.catch(() => {});", .{});
    try ctx.runJobs(null);
    try std.testing.expect(ctx.hasUnhandledRejection()); // the Promise.all(1) rejection
    _ = ctx.takeUnhandledRejection();
    try std.testing.expect(!ctx.hasUnhandledRejection());
}

test "parser handles very long array literals and reports operand limits as SyntaxErrors" {
    const allocator = std.testing.allocator;
    const rt = try zjs.JSRuntime.create(allocator, .{});
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);

    // Past the operand-stack collection limit the literal switches to
    // running-index mode; distinct constants exceed u16 constant indices.
    try source.appendSlice(allocator, "var a = [");
    for (0..70_000) |i| try source.print(allocator, "{d}.5,", .{i});
    try source.appendSlice(allocator, "]; a.length + a[69999]");
    const sum = try ctx.eval(source.items, .{});
    try std.testing.expectEqual(@as(?f64, 70_000 + 69_999.5), sum.as(.float64));

    const Case = struct { prefix: []const u8, item: []const u8, suffix: []const u8, message: []const u8 };
    const cases = [_]Case{
        .{ .prefix = "(function () {})(", .item = "0,", .suffix = ")", .message = "Too many call arguments" },
        .{ .prefix = "`", .item = "${0}", .suffix = "`", .message = "too many template substitutions" },
        .{ .prefix = "(function () {", .item = "var v", .suffix = "})", .message = "implementation limit exceeded: function too large" },
    };
    for (cases) |case| {
        source.clearRetainingCapacity();
        try source.appendSlice(allocator, case.prefix);
        for (0..70_000) |i| {
            if (std.mem.eql(u8, case.item, "var v")) try source.print(allocator, "var v{d};", .{i}) else try source.appendSlice(allocator, case.item);
        }
        try source.appendSlice(allocator, case.suffix);
        try std.testing.expectError(error.JSException, ctx.eval(source.items, .{}));
        try std.testing.expect(try ctx.pendingExceptionMatchesErrorName("SyntaxError"));
        const thrown = ctx.takeException();
        const message = try ctx.toOwnedUtf8(try ctx.getProperty(thrown, "message"), allocator);
        defer allocator.free(message);
        try std.testing.expectEqualStrings(case.message, message);
    }
}

test "takePendingException prefers the thrown exception over an unhandled rejection" {
    const rt = try zjs.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();
    ctx.setTrackUnhandledRejections(true);

    _ = try ctx.eval("Promise.reject(1)", .{});
    try ctx.runJobs(null);
    try std.testing.expect(ctx.hasUnhandledRejection());
    try std.testing.expectError(error.JSException, ctx.eval("throw 2", .{}));

    try std.testing.expectEqual(@as(?i32, 2), ctx.takePendingException().as(.int));
    try std.testing.expect(ctx.hasUnhandledRejection());
    try std.testing.expectEqual(@as(?i32, 1), ctx.takePendingException().as(.int));
    try std.testing.expect(!ctx.hasUnhandledRejection());
}

test "finalization registry unregister cancels a queued cleanup" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var ctx = try core.JSContext.create(rt, .{});
    var ctx_alive = true;
    defer if (ctx_alive) ctx.destroy();

    const cleanup = try core.Object.create(rt, core.class.ids.object, null);
    const registry = try core.Object.createFinalizationRegistry(rt, ctx, null);
    const token = try core.Object.create(rt, core.class.ids.object, null);
    var cleanup_slot: ?*core.Object = cleanup;
    var registry_slot: ?*core.Object = registry;
    var token_slot: ?*core.Object = token;
    var live_roots = core.runtime.rootObjects(.{ &registry_slot, &cleanup_slot, &token_slot });
    live_roots.activate(rt);
    defer live_roots.deactivate(rt);
    registry.finalizationRegistryCleanupCallbackSlot().* = cleanup.value();

    var target = try core.Object.create(rt, core.class.ids.object, null);
    try registry.appendFinalizationRegistryCell(rt, target.value(), core.JSValue.int32(7), token.value());
    dropGcPtr(&target);

    _ = try rt.forceGC(null);
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.countKind(.finalization));
    // The target is dead and its job queued, but the cell is still in
    // [[Cells]]: unregister finds it, and the job then has nothing to run.
    try std.testing.expect(registry.unregisterFinalizationRegistryCells(rt, token.value()));
    try std.testing.expectEqual(@as(usize, 0), registry.finalizationRegistryCells().len);
    var job = rt.job_queue.takeFirst().?;
    defer job.deinit();
    try std.testing.expect(!registry.takeQueuedFinalizationCell(rt, job.payload.finalization.cell_id));

    registry_slot = null;
    cleanup_slot = null;
    token_slot = null;
    ctx.destroy();
    ctx_alive = false;
    dropGcPtr(&ctx);
    _ = try rt.forceGC(null);
}

test "weak holders are allocated old so the raw holder chain never names a nursery husk" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.gc.nursery.enabled = true;
    var roots = core.runtime.ExactValueRoots(4){};
    try roots.activate(rt);
    defer roots.deactivate();
    const holder_classes = [_]core.ClassId{ core.class.ids.weakmap, core.class.ids.weakset, core.class.ids.weak_ref, core.class.ids.finalization_registry };
    var holders: [holder_classes.len]*core.Object = undefined;
    inline for (holder_classes, 0..) |class_id, index| {
        holders[index] = try core.Object.create(rt, class_id, null);
        try (try roots.ref(index)).set(rt, holders[index].value());
        // `gc_weak` links holders by raw address and evacuation does not
        // relink them, so no holder may be born in the nursery.
        try std.testing.expect(rt.gc.nursery.pageOf(@intFromPtr(holders[index].gcHeader())) == null);
    }
    const plain = try core.Object.createPlainObject(rt, null);
    try std.testing.expect(rt.gc.nursery.pageOf(@intFromPtr(plain.gcHeader())) != null);
    _ = try rt.collectForTest();
    inline for (0..holders.len) |index| {
        try std.testing.expectEqual(holders[index].value().bits, (try (try roots.ref(index)).get(rt)).bits);
    }
}

test "production embedding native stack budget stays inside a small thread stack" {
    // The default budget is larger than this thread's whole stack; the guard
    // must still raise its catchable error before the real stack runs out.
    const Run = struct {
        fn run(result: *?anyerror) void {
            result.* = runChecked();
        }
        fn runChecked() ?anyerror {
            const rt = zjs.JSRuntime.create(std.heap.c_allocator, .{}) catch |err| return err;
            defer rt.destroy();
            const ctx = zjs.JSContext.create(rt, .{}) catch |err| return err;
            defer ctx.destroy();
            const value = ctx.eval(
                \\function r(n) { return n ? [n].map(() => r(n - 1))[0] : 0; }
                \\var caught = '';
                \\try { r(1e6); } catch (e) { caught = e.constructor.name; }
                \\caught === 'InternalError';
            , .{}) catch |err| return err;
            if (value.as(.boolean) != true) return error.TestUnexpectedResult;
            return null;
        }
    };
    var result: ?anyerror = error.TestUnexpectedResult;
    const thread = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, Run.run, .{&result});
    thread.join();
    if (result) |err| return err;
}
