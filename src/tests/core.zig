const std = @import("std");
const builtin = @import("builtin");
const zjs = @import("zjs");
const engine = zjs;

const core = zjs.core;

extern "c" fn tmpfile() ?*std.c.FILE;

test "QuickJS value tag constants are locked" {
    try std.testing.expectEqual(@as(i32, -9), core.Tag.first);
    try std.testing.expectEqual(@as(i32, -9), core.Tag.big_int);
    try std.testing.expectEqual(@as(i32, -8), core.Tag.symbol);
    try std.testing.expectEqual(@as(i32, -7), core.Tag.string);
    try std.testing.expectEqual(@as(i32, -6), core.Tag.string_rope);
    try std.testing.expectEqual(@as(i32, -3), core.Tag.module);
    try std.testing.expectEqual(@as(i32, -2), core.Tag.function_bytecode);
    try std.testing.expectEqual(@as(i32, -1), core.Tag.object);
    try std.testing.expectEqual(@as(i32, 0), core.Tag.int);
    try std.testing.expectEqual(@as(i32, 1), core.Tag.boolean);
    try std.testing.expectEqual(@as(i32, 2), core.Tag.null_value);
    try std.testing.expectEqual(@as(i32, 3), core.Tag.undefined_value);
    try std.testing.expectEqual(@as(i32, 4), core.Tag.uninitialized);
    try std.testing.expectEqual(@as(i32, 5), core.Tag.catch_offset);
    try std.testing.expectEqual(@as(i32, 6), core.Tag.exception);
    try std.testing.expectEqual(@as(i32, 7), core.Tag.short_big_int);
    try std.testing.expectEqual(@as(i32, 8), core.Tag.float64);
}

test "primitive value predicates match QuickJS helpers" {
    try std.testing.expect(core.JSValue.int32(1).isNumber());
    try std.testing.expect(core.JSValue.float64(1.5).isNumber());
    try std.testing.expect(core.JSValue.boolean(false).isBool());
    try std.testing.expect(core.JSValue.nullValue().isNull());
    try std.testing.expect(core.JSValue.undefinedValue().isUndefined());
    try std.testing.expect(core.JSValue.uninitialized().isUninitialized());
    try std.testing.expect(core.JSValue.exception().isException());
    try std.testing.expect(core.JSValue.shortBigInt(42).isBigInt());
    try std.testing.expectEqual(@as(?i32, 7), core.JSValue.int32(7).asInt32());
    try std.testing.expectEqual(@as(?i32, null), core.JSValue.float64(7).asInt32());
}

test "heap BigInt value uses reserved QuickJS tag" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const big = try core.bigint.BigInt.create(rt, @as(i128, 1) << 90);
    const value = big.valueRef();
    defer value.free(rt);

    try std.testing.expect(value.isBigInt());
    try std.testing.expectEqual(core.gc.RefKind.big_int, value.refHeader().?.kind);
}

test "runtime and context init-deinit are leak free" {
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const rt = try core.JSRuntime.create(std.testing.allocator);
        const ctx1 = try core.JSContext.create(rt);
        const ctx2 = try core.JSContext.create(rt);
        ctx2.destroy();
        ctx1.destroy();
        rt.destroy();
    }
}

test "atom replace handles self-assignment without releasing dynamic atom" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var slot = try rt.internAtom("dynamic-atom-self-replace");
    rt.atoms.replace(&slot, slot);

    try std.testing.expectEqualStrings("dynamic-atom-self-replace", rt.atoms.name(slot).?);
    rt.atoms.free(slot);
}

test "context takes pending promise jobs without allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    try ctx.ensurePendingPromiseJobCapacity(2);
    ctx.pending_promise_jobs = ctx.pending_promise_jobs.ptr[0..2];
    ctx.pending_promise_jobs[0] = .{ .sequence = 3, .value = core.JSValue.int32(10) };
    ctx.pending_promise_jobs[1] = .{ .sequence = 4, .value = core.JSValue.int32(11) };

    const old_bytes = rt.memory.allocated_bytes;
    const old_allocations = rt.memory.allocation_count;
    rt.setMemoryLimit(old_bytes);
    const first = ctx.takePendingPromiseJob().?;
    rt.setMemoryLimit(null);
    defer first.deinit(rt);

    try std.testing.expectEqual(@as(u64, 3), first.sequence);
    try std.testing.expectEqual(@as(?i32, 10), first.value.asInt32());
    try std.testing.expectEqual(@as(usize, 1), ctx.pending_promise_jobs.len);
    try std.testing.expectEqual(@as(usize, 4), ctx.pending_promise_jobs_capacity);
    try std.testing.expectEqual(@as(?u64, 4), ctx.peekPendingPromiseJobSequence());
    try std.testing.expectEqual(@as(?i32, 11), ctx.pending_promise_jobs[0].value.asInt32());
    try std.testing.expectEqual(old_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(old_allocations, rt.memory.allocation_count);

    const second = ctx.takePendingPromiseJob().?;
    defer second.deinit(rt);
    try std.testing.expectEqual(@as(u64, 4), second.sequence);
    try std.testing.expectEqual(@as(?i32, 11), second.value.asInt32());
    try std.testing.expectEqual(@as(usize, 0), ctx.pending_promise_jobs.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.pending_promise_jobs_capacity);
    try std.testing.expect(ctx.takePendingPromiseJob() == null);
}

fn testBacktraceLocationResolver(_: ?*const anyopaque, pc: usize) core.BacktraceLocation {
    return .{ .line_num = @intCast(pc), .col_num = @intCast(pc + 10) };
}

fn appendWeakCollectionEntry(rt: *core.JSRuntime, collection: *core.Object, key: *core.Object, value: core.JSValue) !void {
    const key_identity = (try core.Object.weakIdentityFromValue(rt, key.value())) orelse unreachable;
    const entries_slot = collection.weakCollectionEntriesSlot();
    const index = entries_slot.*.len;
    const inserted_holder = !rt.borrowedReferenceHolderRegistered(collection);
    try rt.registerBorrowedReferenceHolder(collection);
    errdefer if (inserted_holder) rt.unregisterBorrowedReferenceHolder(collection);
    try collection.ensureWeakCollectionEntryCapacity(rt, index + 1);
    const refreshed_entries = collection.weakCollectionEntriesSlot();
    refreshed_entries.* = refreshed_entries.*.ptr[0 .. index + 1];
    errdefer refreshed_entries.* = refreshed_entries.*[0..index];
    refreshed_entries.*[index] = .{
        .key_identity = key_identity,
        .value = value.dup(),
    };
}

fn appendFinalizationRegistryCell(
    rt: *core.JSRuntime,
    registry: *core.Object,
    target: core.JSValue,
    held_value: core.JSValue,
    unregister_token: core.JSValue,
) !void {
    const entries_slot = registry.finalizationRegistryCellsSlot();
    const index = entries_slot.*.len;
    const inserted_holder = !rt.borrowedReferenceHolderRegistered(registry);
    try rt.registerBorrowedReferenceHolder(registry);
    errdefer if (inserted_holder) rt.unregisterBorrowedReferenceHolder(registry);
    try registry.ensureFinalizationRegistryCellCapacity(rt, index + 1);
    const refreshed_entries = registry.finalizationRegistryCellsSlot();
    refreshed_entries.* = refreshed_entries.*.ptr[0 .. index + 1];
    errdefer refreshed_entries.* = refreshed_entries.*[0..index];
    refreshed_entries.*[index] = .{
        .target_identity = try core.Object.weakIdentityFromValue(rt, target),
        .held_value = held_value.dup(),
        .unregister_token = unregister_token.dup(),
    };
}

fn borrowedHolderInitialAllocationBytes() usize {
    return @sizeOf(*core.Object) * 64;
}

test "context backtrace can borrow VM frame pc lazily" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    try ctx.pushBacktraceFrameWithResolver(
        core.atom.ids.empty_string,
        core.atom.ids.empty_string,
        1,
        1,
        null,
        testBacktraceLocationResolver,
    );
    defer ctx.popBacktraceFrame();

    var pc: usize = 7;
    ctx.borrowBacktracePc(&pc);
    try std.testing.expectEqual(@as(i32, 6), ctx.backtrace_frames[0].location().line_num);
    try std.testing.expectEqual(@as(i32, 16), ctx.backtrace_frames[0].location().col_num);

    pc = 12;
    try std.testing.expectEqual(@as(i32, 11), ctx.backtrace_frames[0].location().line_num);
    try std.testing.expectEqual(@as(i32, 21), ctx.backtrace_frames[0].location().col_num);

    ctx.updateBacktracePc(3);
    try std.testing.expectEqual(@as(i32, 3), ctx.backtrace_frames[0].location().line_num);
    try std.testing.expectEqual(@as(i32, 13), ctx.backtrace_frames[0].location().col_num);
}

test "predefined atoms preserve QuickJS order and kinds" {
    try std.testing.expectEqual(@as(core.Atom, 0), core.atom.null_atom);
    try std.testing.expectEqual(@as(core.Atom, 1), core.atom.ids.null_);
    try std.testing.expectEqual(@as(core.Atom, 2), core.atom.ids.false_);
    try std.testing.expectEqual(@as(core.Atom, 3), core.atom.ids.true_);
    // The core predefined atom layout keeps QuickJS keyword/symbol ordering.
    // zjs startup-only names live after the registry/setup bands.
    try std.testing.expectEqual(@as(core.Atom, 46), core.atom.last_keyword);
    try std.testing.expectEqual(@as(core.Atom, 45), core.atom.last_strict_keyword);
    try std.testing.expectEqual(@as(core.Atom, 229), core.atom.ids.Symbol_asyncIterator);
    try std.testing.expectEqual(@as(core.Atom, 230), core.atom.ids.Symbol_asyncDispose);
    try std.testing.expectEqual(@as(core.Atom, 231), core.atom.ids.Symbol_dispose);
    try std.testing.expectEqual(@as(core.Atom, 232), core.atom.ids.zjs_proto_keepalive);
    try std.testing.expectEqual(@as(core.Atom, 264), core.atom.ids.zjs_last_internal_marker);
    try std.testing.expectEqual(@as(core.Atom, 364), core.atom.ids.zjs_last_registry_name);
    try std.testing.expectEqual(@as(core.Atom, 381), core.atom.ids.zjs_last_global_setup_name);
    try std.testing.expectEqual(@as(core.Atom, 419), core.atom.ids.zjs_last_global_extra_name);
    try std.testing.expectEqual(@as(core.Atom, 586), core.atom.ids.zjs_last_registry_extra_name);
    try std.testing.expectEqual(@as(core.Atom, 626), core.atom.ids.scriptArgs);
    try std.testing.expectEqual(@as(core.Atom, 656), core.atom.ids.zjs_last_startup_name);
    try std.testing.expectEqual(@as(usize, 656), core.atom.predefined_count);

    const brand = core.atom.predefinedById(core.atom.ids.Private_brand).?;
    try std.testing.expectEqual(core.atom.AtomKind.private, brand.kind);
    const iterator = core.atom.predefinedById(core.atom.ids.Symbol_iterator).?;
    try std.testing.expectEqual(core.atom.AtomKind.symbol, iterator.kind);

    for (core.atom.predefined_atoms, 0..) |entry, index| {
        try std.testing.expectEqual(@as(core.Atom, @intCast(index + 1)), entry.id);
    }
}

test "private brand property replacement retains stored private atom" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const object = try core.Object.create(rt, core.class.ids.object, null);
    defer object.value().free(rt);

    const brand = try rt.atoms.newSymbol("privateBrandReplacement", .private);
    try object.defineOwnProperty(
        rt,
        core.atom.ids.Private_brand,
        core.Descriptor.data(core.JSValue.symbol(brand), true, true, true),
    );
    rt.atoms.free(brand);
    try std.testing.expect(rt.atoms.name(brand) != null);

    try object.setProperty(rt, core.atom.ids.Private_brand, core.JSValue.symbol(brand));
    try std.testing.expect(rt.atoms.name(brand) != null);
    const stored = object.getProperty(core.atom.ids.Private_brand);
    try std.testing.expectEqual(@as(?core.Atom, brand), stored.asSymbolAtom());
}

test "atom table interns predefined dynamic and integer atoms" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const a = try rt.atoms.newSymbol("desc", .symbol);
    const b = try rt.atoms.newSymbol("desc", .symbol);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(core.atom.AtomKind.symbol, rt.atoms.kind(a).?);
    try std.testing.expectEqualStrings("desc", rt.atoms.name(a).?);
    rt.atoms.free(a);
    rt.atoms.free(b);
}

test "registered symbol index ignores unique symbols and private names" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const registry_name = "Symbol.for:registry-isolation";
    const unique = try rt.atoms.newSymbol(registry_name, .symbol);
    defer rt.atoms.free(unique);
    const private = try rt.atoms.newSymbol(registry_name, .private);
    defer rt.atoms.free(private);

    const registered = try rt.atoms.internSymbol(registry_name);
    const registered_again = try rt.atoms.internSymbol(registry_name);
    try std.testing.expect(unique != registered);
    try std.testing.expect(private != registered);
    try std.testing.expectEqual(registered, registered_again);
    try std.testing.expect(!rt.atoms.isRegisteredSymbol(unique));
    try std.testing.expect(!rt.atoms.isRegisteredSymbol(private));
    try std.testing.expect(rt.atoms.isRegisteredSymbol(registered));

    rt.atoms.free(registered);
    try std.testing.expect(rt.atoms.isRegisteredSymbol(registered_again));
    rt.atoms.free(registered_again);
    try std.testing.expect(!rt.atoms.isRegisteredSymbol(registered_again));
    try std.testing.expect(rt.atoms.name(unique) != null);
    try std.testing.expect(rt.atoms.name(private) != null);
}

test "registered value symbols keep a single registry ref" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const registry_name = "Symbol.for:registered-value-ref";
    const registered = try rt.atoms.internRegisteredValueSymbol(registry_name);
    const registered_again = try rt.atoms.internRegisteredValueSymbol(registry_name);
    try std.testing.expectEqual(registered, registered_again);
    try std.testing.expectEqual(@as(usize, 1), rt.atoms.refCount(registered).?);

    const manual = try rt.atoms.internSymbol(registry_name);
    try std.testing.expectEqual(registered, manual);
    try std.testing.expectEqual(@as(usize, 2), rt.atoms.refCount(registered).?);
    rt.atoms.free(manual);
    try std.testing.expectEqual(@as(usize, 1), rt.atoms.refCount(registered).?);
}

test "atom table deinit balances live empty dynamic symbol bytes" {
    var account = core.memory.MemoryAccount.init(std.testing.allocator);
    var atoms = core.atom.AtomTable.init(&account);

    const freed = try atoms.newSymbol("", .symbol);
    atoms.free(freed);

    const sym = try atoms.newSymbol("", .symbol);
    try std.testing.expectEqual(core.atom.AtomKind.symbol, atoms.kind(sym).?);
    try std.testing.expectEqualStrings("", atoms.name(sym).?);

    atoms.deinit();
    try std.testing.expect(!account.hasOutstandingAllocations());
}

test "GC sweeps unrooted unique symbol atoms" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-unrooted-symbol");
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "GC leaves manually owned unique symbol atoms alone" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newSymbol("gc-manual-symbol", .symbol);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    rt.atoms.free(symbol_atom);
}

test "GC keeps rooted unique symbol atoms until the root is gone" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-rooted-symbol");
    var rooted_value = core.JSValue.symbol(symbol_atom);
    var root_values = [_]core.runtime.ValueRootValue{.{ .value = &rooted_value }};
    const roots = core.runtime.ValueRootFrame{ .values = &root_values };

    _ = rt.runObjectCycleRemovalWithValueRoots(&roots);
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    rooted_value = core.JSValue.undefinedValue();
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "GC keeps atom-owned unique symbol atoms until the atom owner releases" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-atom-owned-symbol");
    const retained_atom = rt.atoms.dup(symbol_atom);
    try std.testing.expectEqual(symbol_atom, retained_atom);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    rt.atoms.free(retained_atom);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "GC keeps runtime and context value slot unique symbol atoms" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const runtime_symbol = try rt.atoms.newValueSymbol("gc-runtime-slot-symbol");
    rt.current_exception = core.JSValue.symbol(runtime_symbol);

    const exception_symbol = try rt.atoms.newValueSymbol("gc-context-exception-symbol");
    _ = ctx.throwValue(core.JSValue.symbol(exception_symbol));

    const rejection_symbol = try rt.atoms.newValueSymbol("gc-context-unhandled-symbol");
    ctx.recordUnhandledRejection(core.JSValue.symbol(rejection_symbol));

    const prototype_symbol = try rt.atoms.newValueSymbol("gc-context-prototype-symbol");
    ctx.class_prototypes[0] = core.JSValue.symbol(prototype_symbol);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(runtime_symbol) != null);
    try std.testing.expect(rt.atoms.name(exception_symbol) != null);
    try std.testing.expect(rt.atoms.name(rejection_symbol) != null);
    try std.testing.expect(rt.atoms.name(prototype_symbol) != null);

    const old_runtime_exception = rt.current_exception;
    rt.current_exception = core.JSValue.uninitialized();
    old_runtime_exception.free(rt);
    ctx.clearException();
    const old_prototype = ctx.class_prototypes[0];
    ctx.class_prototypes[0] = core.JSValue.nullValue();
    old_prototype.free(rt);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(runtime_symbol) == null);
    try std.testing.expect(rt.atoms.name(exception_symbol) == null);
    try std.testing.expect(rt.atoms.name(rejection_symbol) != null);
    try std.testing.expect(rt.atoms.name(prototype_symbol) == null);

    ctx.clearUnhandledRejection();
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(rejection_symbol) == null);
}

test "GC keeps context lexical object unique symbol atoms" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const env = try core.Object.create(rt, core.class.ids.object, null);
    ctx.lexicals = env;

    const property_name = try rt.internAtom("context-lexical-symbol-slot");
    defer rt.atoms.free(property_name);
    const lexical_symbol = try rt.atoms.newValueSymbol("gc-context-lexical-object-symbol");
    try env.defineOwnProperty(rt, property_name, core.Descriptor.data(core.JSValue.symbol(lexical_symbol), true, true, true));

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(lexical_symbol) != null);

    ctx.lexicals = null;
    env.value().free(rt);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(lexical_symbol) == null);
}

test "GC keeps context pending promise job unique symbol atoms until release" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const pending_symbol = try rt.atoms.newValueSymbol("gc-context-pending-job-symbol");
    try ctx.ensurePendingPromiseJobCapacity(1);
    ctx.pending_promise_jobs = ctx.pending_promise_jobs.ptr[0..1];
    ctx.pending_promise_jobs[0] = try core.context.PendingPromiseJob.init(ctx, 1, core.JSValue.symbol(pending_symbol));

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(pending_symbol) != null);

    var pending = ctx.takePendingPromiseJob().?;
    pending.deinit(rt);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(pending_symbol) == null);
}

test "GC keeps finalization job unique symbol atoms after dequeue until release" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const callback_symbol = try rt.atoms.newValueSymbol("gc-finalization-job-callback-symbol");
    const held_symbol = try rt.atoms.newValueSymbol("gc-finalization-job-held-symbol");

    try rt.enqueueFinalizationJob(core.JSValue.symbol(callback_symbol), core.JSValue.symbol(held_symbol));
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().pending_finalization_job_count);
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().finalizer_queue_length);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(callback_symbol) != null);
    try std.testing.expect(rt.atoms.name(held_symbol) != null);

    var job = rt.takePendingFinalizationJob().?;
    var job_alive = true;
    defer if (job_alive) job.deinit(rt);
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().pending_finalization_job_count);
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().finalizer_queue_length);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(callback_symbol) != null);
    try std.testing.expect(rt.atoms.name(held_symbol) != null);

    job.deinit(rt);
    job_alive = false;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(callback_symbol) == null);
    try std.testing.expect(rt.atoms.name(held_symbol) == null);
}

test "GC keeps dequeued finalization job function bytecode symbol constants until release" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const fb_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-finalization-job-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

    const bytecode_value = core.JSValue.functionBytecode(&fb.header);
    try rt.enqueueFinalizationJob(bytecode_value, core.JSValue.undefinedValue());
    bytecode_value.free(rt);

    var job = rt.takePendingFinalizationJob().?;
    var job_alive = true;
    defer if (job_alive) job.deinit(rt);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    job.deinit(rt);
    job_alive = false;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "GC keeps module registry unique symbol atoms until release" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const module_name = try rt.internAtom("gc-module-symbols.mjs");
    defer rt.atoms.free(module_name);
    const binding_name = try rt.internAtom("localSymbol");
    defer rt.atoms.free(binding_name);

    const record = try rt.modules.create(module_name);
    try record.ensureLocalBinding(binding_name);
    const binding_index = record.findLocalBindingIndex(binding_name).?;

    const binding_symbol = try rt.atoms.newValueSymbol("gc-module-binding-symbol");
    record.local_bindings[binding_index].initialized = true;
    record.local_bindings[binding_index].cell = core.JSValue.symbol(binding_symbol);

    const import_meta_symbol = try rt.atoms.newValueSymbol("gc-module-import-meta-symbol");
    record.import_meta = core.JSValue.symbol(import_meta_symbol);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(binding_symbol) != null);
    try std.testing.expect(rt.atoms.name(import_meta_symbol) != null);

    record.local_bindings[binding_index].cell = core.JSValue.undefinedValue();
    record.import_meta = null;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(binding_symbol) == null);
    try std.testing.expect(rt.atoms.name(import_meta_symbol) == null);
}

test "GC sweeps unique symbol atoms after description string cache" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-cached-symbol-description");
    const description = try rt.atoms.toStringValue(rt, symbol_atom);
    description.free(rt);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "GC keeps rooted function bytecode symbol constants" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const fb_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-bytecode-symbol-constant");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

    var rooted_value = core.JSValue.functionBytecode(&fb.header);
    var root_values = [_]core.runtime.ValueRootValue{.{ .value = &rooted_value }};
    const roots = core.runtime.ValueRootFrame{ .values = &root_values };

    _ = rt.runObjectCycleRemovalWithValueRoots(&roots);
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    rooted_value.free(rt);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "GC keeps object-held and registered symbol atoms" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.object, null);
    const key = try rt.internAtom("symbolValue");
    defer rt.atoms.free(key);

    const object_symbol = try rt.atoms.newValueSymbol("gc-object-held-symbol");
    try object.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.symbol(object_symbol), true, true, true));
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(object_symbol) != null);

    object.value().free(rt);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(object_symbol) == null);

    const registered = try rt.atoms.internSymbol("Symbol.for:gc-registered-symbol");
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(registered) != null);
    rt.atoms.free(registered);
}

test "strings choose QuickJS-style 8-bit or 16-bit storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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

    const lone_surrogate = try core.string.String.createUtf8(rt, "\xED\xA0\x80");
    defer lone_surrogate.value().free(rt);
    try std.testing.expect(lone_surrogate.isWide());
    try std.testing.expectEqual(@as(usize, 1), lone_surrogate.len());
    try std.testing.expectEqual(@as(u16, 0xd800), lone_surrogate.codeUnitAt(0));
}

test "normal strings use compact allocation with bounded in-place append" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const fixed_allocations = rt.memory.allocation_count;
    const fixed = try core.string.String.createLatin1(rt, "abc");
    try std.testing.expectEqual(core.string.Layout.compact, fixed.layout);
    try std.testing.expectEqual(@as(usize, 3), fixed.capacity);
    try std.testing.expectEqual(fixed_allocations + 1, rt.memory.allocation_count);
    try std.testing.expect(!try fixed.appendLatin1InPlace(rt, "d"));
    try std.testing.expectEqual(fixed_allocations + 1, rt.memory.allocation_count);
    fixed.value().free(rt);
    try std.testing.expectEqual(fixed_allocations, rt.memory.allocation_count);

    const growable_allocations = rt.memory.allocation_count;
    const growable = try core.string.String.createLatin1Concat(rt, "a", "b");
    defer growable.value().free(rt);
    try std.testing.expectEqual(core.string.Layout.compact, growable.layout);
    try std.testing.expect(growable.capacity > growable.len());
    try std.testing.expectEqual(growable_allocations + 1, rt.memory.allocation_count);

    try std.testing.expect(try growable.appendLatin1InPlace(rt, "c"));
    try std.testing.expectEqual(growable_allocations + 1, rt.memory.allocation_count);
    try std.testing.expect(growable.eqlBytes("abc"));
}

test "rope tail append extends an unmaterialized rope in place" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const left = try core.string.String.createLatin1(rt, "abc");
    const right = try core.string.String.createLatin1(rt, "def");
    const rope = try core.string.String.createRope(rt, left, right);
    left.value().free(rt);
    right.value().free(rt);
    defer rope.value().free(rt);

    try std.testing.expect(try rope.appendRopeTail(rt, .{ .latin1 = "ghi" }));
    try std.testing.expect(try rope.appendRopeTail(rt, .{ .latin1 = "jkl" }));
    try std.testing.expect(try rope.appendRopeTail(rt, .{ .latin1 = "" }));
    try std.testing.expectEqual(@as(usize, 12), rope.len());
    try std.testing.expect(!rope.isWide());

    // Length growth in a loop exercises the amortized-doubling regrowth.
    var round: usize = 0;
    while (round < 100) : (round += 1) {
        try std.testing.expect(try rope.appendRopeTail(rt, .{ .latin1 = "0123456789" }));
    }
    try std.testing.expectEqual(@as(usize, 1012), rope.len());

    // Content reads flatten the rope including the tail segment.
    try std.testing.expectEqual(@as(u16, 'g'), rope.codeUnitAt(6));
    try std.testing.expectEqual(@as(u16, 'l'), rope.codeUnitAt(11));
    try std.testing.expectEqual(@as(u16, '0'), rope.codeUnitAt(12));
    try std.testing.expectEqual(@as(u16, '9'), rope.codeUnitAt(1011));

    // Materialized ropes refuse tail appends: their hash caches are live.
    try std.testing.expect(!try rope.appendRopeTail(rt, .{ .latin1 = "nope" }));
    try std.testing.expectEqual(@as(usize, 1012), rope.len());

    // An unflattened rope destroyed with a pending tail releases it.
    const l2 = try core.string.String.createLatin1(rt, "xy");
    const r2 = try core.string.String.createLatin1(rt, "z");
    const dropped = try core.string.String.createRope(rt, l2, r2);
    l2.value().free(rt);
    r2.value().free(rt);
    try std.testing.expect(try dropped.appendRopeTail(rt, .{ .latin1 = "tail" }));
    dropped.value().free(rt);
}

test "rope tail append widens for utf16 suffixes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const left = try core.string.String.createLatin1(rt, "ab");
    const right = try core.string.String.createLatin1(rt, "cd");
    const rope = try core.string.String.createRope(rt, left, right);
    left.value().free(rt);
    right.value().free(rt);
    defer rope.value().free(rt);

    try std.testing.expect(try rope.appendRopeTail(rt, .{ .latin1 = "12" }));
    try std.testing.expect(!rope.isWide());
    // A wide suffix widens the narrow tail in place and flips the rope wide.
    try std.testing.expect(try rope.appendRopeTail(rt, .{ .utf16 = &.{0x0100} }));
    try std.testing.expect(rope.isWide());
    // Narrow content keeps landing in the widened tail.
    try std.testing.expect(try rope.appendRopeTail(rt, .{ .latin1 = "z" }));
    try std.testing.expectEqual(@as(usize, 8), rope.len());

    const expected = try core.string.String.createUtf16(rt, &.{ 'a', 'b', 'c', 'd', '1', '2', 0x0100, 'z' });
    defer expected.value().free(rt);
    try std.testing.expect(rope.eqlString(expected.*));
    try std.testing.expectEqual(expected.contentHash(), rope.contentHash());
}

test "rope child with pending tail flattens through the parent rope" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const left = try core.string.String.createLatin1(rt, "abc");
    const right = try core.string.String.createLatin1(rt, "def");
    const inner = try core.string.String.createRope(rt, left, right);
    left.value().free(rt);
    right.value().free(rt);
    defer inner.value().free(rt);
    try std.testing.expect(try inner.appendRopeTail(rt, .{ .latin1 = "ghi" }));

    const suffix = try core.string.String.createLatin1(rt, "XY");
    const outer = try core.string.String.createRope(rt, inner, suffix);
    suffix.value().free(rt);
    defer outer.value().free(rt);

    // Becoming a rope child snapshots the content: further tail appends on
    // the child must refuse so the parent's view stays immutable.
    try std.testing.expect(!try inner.appendRopeTail(rt, .{ .latin1 = "no" }));
    try std.testing.expect(outer.eqlBytes("abcdefghiXY"));
    try std.testing.expect(inner.eqlBytes("abcdefghi"));
}

test "strings compare by code unit across storage widths" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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

test "atom table retains its cached string until the atom dies" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const atom_id = try rt.internAtom("ownedAtomName");
    const atom_string = try core.string.String.createAtomBacked(rt, atom_id);
    // The table caches the materialized string; repeat conversions reuse it.
    const again = try core.string.String.createAtomBacked(rt, atom_id);
    try std.testing.expect(again == atom_string);
    again.value().free(rt);
    // Releasing the string does not release the atom: `atom_id` is a weak
    // back-pointer, and the table keeps its own string reference.
    atom_string.value().free(rt);
    try std.testing.expect(rt.atoms.name(atom_id) != null);
    // The last atom reference frees the entry together with its string.
    rt.atoms.free(atom_id);
    try std.testing.expect(rt.atoms.name(atom_id) == null);
}

test "class table registers QuickJS standard classes and dynamic classes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    try std.testing.expectEqual(@as(core.ClassId, 0), core.class.invalid_class_id);
    try std.testing.expectEqual(@as(core.ClassId, 1), core.class.ids.object);
    try std.testing.expectEqual(@as(core.ClassId, 22), core.class.ids.uint8c_array);
    try std.testing.expectEqual(@as(core.ClassId, 37), core.class.ids.set);
    try std.testing.expectEqual(@as(core.ClassId, 65), core.class.ids.std_file);
    try std.testing.expectEqual(@as(core.ClassId, 66), core.class.ids.disposable_stack);
    try std.testing.expectEqual(@as(core.ClassId, 67), core.class.ids.async_disposable_stack);
    try std.testing.expectEqual(@as(core.ClassId, 68), core.class.ids.init_count);
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
    try std.testing.expectEqual(core.class.PayloadKind.none, record.payload_kind);
    const dynamic_name = rt.classes.className(dynamic_id).?;
    defer rt.atoms.free(dynamic_name);
    try std.testing.expectEqualStrings("HostThing", rt.atoms.name(dynamic_name).?);

    try std.testing.expectError(error.DuplicateClass, rt.classes.register(dynamic_id, .{ .class_name = "Again" }));
    rt.classes.unregisterDynamic(core.class.ids.object);
    try std.testing.expect(rt.classes.isRegistered(core.class.ids.object));
    rt.classes.unregisterDynamic(dynamic_id);
    try std.testing.expect(!rt.classes.isRegistered(dynamic_id));
    try std.testing.expect(rt.classes.className(dynamic_id) == null);
    try rt.classes.register(dynamic_id, .{ .class_name = "Again" });
    try std.testing.expect(rt.classes.isRegistered(dynamic_id));

    try std.testing.expectEqual(core.class.PayloadKind.ordinary, rt.classes.record(core.class.ids.object).?.payload_kind);
    try std.testing.expectEqual(core.class.PayloadKind.array, rt.classes.record(core.class.ids.array).?.payload_kind);
    try std.testing.expectEqual(core.class.PayloadKind.regexp, rt.classes.record(core.class.ids.regexp).?.payload_kind);
    try std.testing.expectEqual(core.class.PayloadKind.collection, rt.classes.record(core.class.ids.map).?.payload_kind);
    try std.testing.expectEqual(core.class.PayloadKind.iterator, rt.classes.record(core.class.ids.array_iterator).?.payload_kind);
    try std.testing.expectEqual(core.class.PayloadKind.generator, rt.classes.record(core.class.ids.generator).?.payload_kind);
    try std.testing.expectEqual(core.class.PayloadKind.function, rt.classes.record(core.class.ids.c_function).?.payload_kind);
    try std.testing.expectEqual(core.class.PayloadKind.function, rt.classes.record(core.class.ids.bytecode_function).?.payload_kind);
    try std.testing.expectEqual(core.class.PayloadKind.module_namespace, rt.classes.record(core.class.ids.module_ns).?.payload_kind);
    try std.testing.expectEqual(core.class.PayloadKind.disposable_stack, core.class.standardPayloadKind(core.class.ids.disposable_stack));
    try std.testing.expectEqual(core.class.PayloadKind.disposable_stack, core.class.standardPayloadKind(core.class.ids.async_disposable_stack));
}

var finalizer_calls: usize = 0;
var payload_finalizer_calls: usize = 0;
var payload_mark_calls: usize = 0;
var reentrant_collection_clear_target: ?*core.Object = null;
var reentrant_collection_clear_calls: usize = 0;
var reentrant_array_delete_target: ?*core.Object = null;
var reentrant_array_delete_calls: usize = 0;
var reentrant_property_delete_target: ?*core.Object = null;
var reentrant_property_delete_key: core.atom.Atom = core.atom.null_atom;
var reentrant_property_delete_calls: usize = 0;
var reentrant_regexp_last_index_target: ?*core.Object = null;
var reentrant_regexp_last_index_calls: usize = 0;
var reentrant_mapped_arguments_target: ?*core.Object = null;
var reentrant_mapped_arguments_key: core.atom.Atom = core.atom.null_atom;
var reentrant_mapped_arguments_calls: usize = 0;
var reentrant_cached_iterator_next_target: ?*core.Object = null;
var reentrant_cached_iterator_next_calls: usize = 0;
var reentrant_exception_slot_target: ?*core.exception.ExceptionSlot = null;
var reentrant_exception_slot_calls: usize = 0;
var reentrant_array_iterator_target: ?*core.Object = null;
var reentrant_array_iterator_calls: usize = 0;

fn countFinalizer() void {
    finalizer_calls += 1;
}

fn countNativeCleanup(ptr: *anyopaque) void {
    const count: *usize = @ptrCast(@alignCast(ptr));
    count.* += 1;
}

fn dummyExternalHostCall(_: *anyopaque, _: core.host_function.ExternalCall) anyerror!core.JSValue {
    return core.JSValue.undefinedValue();
}

fn expectOneDeferredClassPayloadFinalizer(rt: *core.JSRuntime) !void {
    try std.testing.expectEqual(@as(usize, 1), rt.pendingDeferredClassPayloadFinalizerCountForTest());
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().deferred_class_payload_finalizer_count);
}

fn runOneDeferredClassPayloadFinalizer(rt: *core.JSRuntime) !void {
    try std.testing.expectEqual(@as(usize, 1), rt.runDeferredClassPayloadFinalizerBudgeted(1));
    try std.testing.expectEqual(@as(usize, 0), rt.pendingDeferredClassPayloadFinalizerCountForTest());
}

fn countPayloadFinalizer(_: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    payload.* = .none;
}

fn countPayloadMark(
    _: *anyopaque,
    _: *anyopaque,
    payload: *core.class.Payload,
    visitor: *core.class.PayloadVisitor,
) void {
    payload_mark_calls += 1;
    visitor.value(@ptrCast(payload));
}

fn countVisitedValue(context: *anyopaque, _: *anyopaque) void {
    const count: *usize = @ptrCast(@alignCast(context));
    count.* += 1;
}

const TestExternalPayload = struct {
    value: core.JSValue = core.JSValue.undefinedValue(),
};

const TestExternalObjectPayload = struct {
    object: ?*core.Object = null,
};

fn finalizeTestExternalPayload(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    switch (payload.*) {
        .external => |ptr| {
            const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
            const typed: *TestExternalPayload = @ptrCast(@alignCast(ptr));
            typed.value.free(rt);
            rt.memory.destroy(TestExternalPayload, typed);
            payload.* = .none;
        },
        .none => {},
    }
}

fn finalizeTestExternalObjectPayload(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    switch (payload.*) {
        .external => |ptr| {
            const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
            const typed: *TestExternalObjectPayload = @ptrCast(@alignCast(ptr));
            if (typed.object) |object| object.value().free(rt);
            rt.memory.destroy(TestExternalObjectPayload, typed);
            payload.* = .none;
        },
        .none => {},
    }
}

fn reentrantCollectionClearFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    payload.* = .none;
    if (reentrant_collection_clear_calls != 0) return;
    reentrant_collection_clear_calls += 1;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const map = reentrant_collection_clear_target orelse return;
    const result = engine.builtins.collection.methodCall(rt, map.value(), 5, &.{}) catch return;
    result.free(rt);
}

fn reentrantArrayDeleteFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    payload.* = .none;
    if (reentrant_array_delete_calls != 0) return;
    reentrant_array_delete_calls += 1;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const array = reentrant_array_delete_target orelse return;
    _ = array.deleteProperty(rt, core.atom.atomFromUInt32(0));
}

fn reentrantPropertyDeleteFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    payload.* = .none;
    if (reentrant_property_delete_calls != 0) return;
    reentrant_property_delete_calls += 1;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const object = reentrant_property_delete_target orelse return;
    _ = object.deleteProperty(rt, reentrant_property_delete_key);
}

fn reentrantRegExpLastIndexFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    payload.* = .none;
    if (reentrant_regexp_last_index_calls != 0) return;
    reentrant_regexp_last_index_calls += 1;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const regexp = reentrant_regexp_last_index_target orelse return;
    regexp.setProperty(rt, core.atom.ids.lastIndex, core.JSValue.int32(99)) catch {};
}

fn reentrantMappedArgumentsFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    payload.* = .none;
    if (reentrant_mapped_arguments_calls != 0) return;
    reentrant_mapped_arguments_calls += 1;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const arguments = reentrant_mapped_arguments_target orelse return;
    arguments.defineOwnProperty(
        rt,
        reentrant_mapped_arguments_key,
        core.Descriptor.data(core.JSValue.int32(99), true, true, true),
    ) catch {};
}

fn reentrantCachedIteratorNextFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    payload.* = .none;
    if (reentrant_cached_iterator_next_calls != 0) return;
    reentrant_cached_iterator_next_calls += 1;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const object = reentrant_cached_iterator_next_target orelse return;
    object.clearCachedIteratorNext(rt);
}

fn reentrantExceptionSlotFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    payload.* = .none;
    if (reentrant_exception_slot_calls != 0) return;
    reentrant_exception_slot_calls += 1;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const slot = reentrant_exception_slot_target orelse return;
    slot.clear(rt);
}

fn reentrantArrayIteratorFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    payload.* = .none;
    if (reentrant_array_iterator_calls != 0) return;
    reentrant_array_iterator_calls += 1;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const iterator = reentrant_array_iterator_target orelse return;
    const result = engine.builtins.array.methodCall(rt, iterator.value(), 20, &.{}) catch return;
    result.free(rt);
}

fn markTestExternalPayload(
    _: *anyopaque,
    _: *anyopaque,
    payload: *core.class.Payload,
    visitor: *core.class.PayloadVisitor,
) void {
    payload_mark_calls += 1;
    switch (payload.*) {
        .external => |ptr| {
            const typed: *TestExternalPayload = @ptrCast(@alignCast(ptr));
            visitor.value(@ptrCast(&typed.value));
        },
        .none => {},
    }
}

fn markTestExternalObjectPayload(
    _: *anyopaque,
    _: *anyopaque,
    payload: *core.class.Payload,
    visitor: *core.class.PayloadVisitor,
) void {
    payload_mark_calls += 1;
    switch (payload.*) {
        .external => |ptr| {
            const typed: *TestExternalObjectPayload = @ptrCast(@alignCast(ptr));
            visitor.object(@ptrCast(&typed.object));
        },
        .none => {},
    }
}

test "class finalizers and context prototype slots are wired" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const dynamic_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(dynamic_id, .{
        .class_name = "FinalizedThing",
        .payload_kind = .iterator,
        .finalizer = countFinalizer,
        .payload_finalizer = countPayloadFinalizer,
        .payload_mark = countPayloadMark,
    });

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    try std.testing.expect(ctx.classPrototypeSlotCount() >= dynamic_id + 1);

    const prototype = try core.Object.create(rt, core.class.ids.object, null);
    const prototype_value = prototype.value();
    defer prototype_value.free(rt);
    try ctx.setClassPrototype(dynamic_id, prototype);
    try std.testing.expectEqual(prototype, ctx.classPrototypeObject(dynamic_id).?);
    ctx.clearClassPrototype(dynamic_id);
    try std.testing.expect(ctx.classPrototypeObject(dynamic_id) == null);

    finalizer_calls = 0;
    try std.testing.expect(rt.classes.runFinalizer(dynamic_id));
    try std.testing.expectEqual(@as(usize, 1), finalizer_calls);
    try std.testing.expect(!rt.classes.runFinalizer(core.class.ids.object));

    payload_finalizer_calls = 0;
    var payload: core.class.Payload = .none;
    try std.testing.expect(rt.classes.runPayloadFinalizerForTest(dynamic_id, @ptrCast(rt), @ptrCast(ctx), &payload));
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(core.class.Payload.none, payload);
    try std.testing.expect(!rt.classes.runPayloadFinalizerForTest(core.class.ids.object, @ptrCast(rt), @ptrCast(ctx), &payload));

    payload_mark_calls = 0;
    var visited_values: usize = 0;
    var visitor = core.class.PayloadVisitor{
        .context = @ptrCast(&visited_values),
        .visit_value = countVisitedValue,
    };
    payload = .none;
    try std.testing.expect(rt.classes.markPayload(dynamic_id, @ptrCast(rt), @ptrCast(ctx), &payload, &visitor));
    try std.testing.expectEqual(@as(usize, 1), payload_mark_calls);
    try std.testing.expectEqual(@as(usize, 1), visited_values);
    try std.testing.expect(!rt.classes.markPayload(core.class.ids.object, @ptrCast(rt), @ptrCast(ctx), &payload, &visitor));
}

test "object destruction defers class payload finalizers" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const payloadless_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(payloadless_id, .{
        .class_name = "PayloadlessFinalized",
        .payload_finalizer = countPayloadFinalizer,
    });

    payload_finalizer_calls = 0;
    const payloadless = try core.Object.create(rt, payloadless_id, null);
    try std.testing.expect(payloadless.class_payload == .none);
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    payloadless.value().free(rt);
    rt.setMemoryLimit(null);
    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);
    try expectOneDeferredClassPayloadFinalizer(rt);
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);

    const external_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(external_id, .{
        .class_name = "ExternalPayloadFinalized",
        .payload_finalizer = finalizeTestExternalPayload,
    });

    payload_finalizer_calls = 0;
    const external = try core.Object.create(rt, external_id, null);
    const payload = try rt.memory.create(TestExternalPayload);
    payload.* = .{};
    external.class_payload = .{ .external = @ptrCast(payload) };
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    external.value().free(rt);
    rt.setMemoryLimit(null);
    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);
    try expectOneDeferredClassPayloadFinalizer(rt);
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
}

test "strong collection clear defers value finalizer reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const reentrant_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(reentrant_id, .{
        .class_name = "ReentrantCollectionClear",
        .payload_finalizer = reentrantCollectionClearFinalizer,
    });

    const map = try core.Object.create(rt, core.class.ids.map, null);
    defer map.value().free(rt);
    const value = try core.Object.create(rt, reentrant_id, null);
    const set_result = try engine.builtins.collection.methodCall(rt, map.value(), 1, &.{ core.JSValue.int32(1), value.value() });
    set_result.free(rt);
    value.value().free(rt);

    payload_finalizer_calls = 0;
    reentrant_collection_clear_target = map;
    reentrant_collection_clear_calls = 0;
    defer {
        reentrant_collection_clear_target = null;
        reentrant_collection_clear_calls = 0;
    }

    const clear_result = try engine.builtins.collection.methodCall(rt, map.value(), 5, &.{});
    defer clear_result.free(rt);

    try std.testing.expect(clear_result.isUndefined());
    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 0), reentrant_collection_clear_calls);
    try expectOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 0), map.collectionActiveCount());
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 1), reentrant_collection_clear_calls);
    try std.testing.expectEqual(@as(usize, 0), map.collectionActiveCount());
}

test "dense array delete defers element finalizer reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const reentrant_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(reentrant_id, .{
        .class_name = "ReentrantArrayDelete",
        .payload_finalizer = reentrantArrayDeleteFinalizer,
    });

    const array = try core.Object.createArray(rt, null);
    defer array.value().free(rt);
    const value = try core.Object.create(rt, reentrant_id, null);
    try std.testing.expect(try array.defineDenseArrayDataProperty(rt, 0, value.value()));
    value.value().free(rt);

    payload_finalizer_calls = 0;
    reentrant_array_delete_target = array;
    reentrant_array_delete_calls = 0;
    defer {
        reentrant_array_delete_target = null;
        reentrant_array_delete_calls = 0;
    }

    try std.testing.expect(array.deleteProperty(rt, core.atom.atomFromUInt32(0)));
    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 0), reentrant_array_delete_calls);
    try expectOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(?core.JSValue, null), array.arrayElements()[0]);
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 1), reentrant_array_delete_calls);
    try std.testing.expectEqual(@as(?core.JSValue, null), array.arrayElements()[0]);
}

test "ordinary property delete defers value finalizer reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const reentrant_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(reentrant_id, .{
        .class_name = "ReentrantPropertyDelete",
        .payload_finalizer = reentrantPropertyDeleteFinalizer,
    });

    const object = try core.Object.create(rt, core.class.ids.object, null);
    defer object.value().free(rt);
    const value = try core.Object.create(rt, reentrant_id, null);
    const key = try rt.internAtom("reentrant_property_delete");
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value.value(), true, true, true));
    value.value().free(rt);

    payload_finalizer_calls = 0;
    reentrant_property_delete_target = object;
    reentrant_property_delete_key = key;
    reentrant_property_delete_calls = 0;
    defer {
        reentrant_property_delete_target = null;
        reentrant_property_delete_key = core.atom.null_atom;
        reentrant_property_delete_calls = 0;
    }

    try std.testing.expect(object.deleteProperty(rt, key));
    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 0), reentrant_property_delete_calls);
    try expectOneDeferredClassPayloadFinalizer(rt);
    var before_cleanup = object.getProperty(key);
    defer before_cleanup.free(rt);
    try std.testing.expect(before_cleanup.isUndefined());
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 1), reentrant_property_delete_calls);
    const after = object.getProperty(key);
    defer after.free(rt);
    try std.testing.expect(after.isUndefined());
}

test "regexp lastIndex set defers value finalizer reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const reentrant_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(reentrant_id, .{
        .class_name = "ReentrantRegExpLastIndexSet",
        .payload_finalizer = reentrantRegExpLastIndexFinalizer,
    });

    const regexp = try core.Object.create(rt, core.class.ids.regexp, null);
    defer regexp.value().free(rt);
    regexp.regexpLastIndexWritableSlot().* = true;
    const value = try core.Object.create(rt, reentrant_id, null);
    regexp.regexpLastIndexSlot().* = value.value().dup();
    value.value().free(rt);

    payload_finalizer_calls = 0;
    reentrant_regexp_last_index_target = regexp;
    reentrant_regexp_last_index_calls = 0;
    defer {
        reentrant_regexp_last_index_target = null;
        reentrant_regexp_last_index_calls = 0;
    }

    try regexp.setProperty(rt, core.atom.ids.lastIndex, core.JSValue.int32(7));

    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 0), reentrant_regexp_last_index_calls);
    try expectOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(?i32, 7), regexp.regexpLastIndex().?.asInt32());
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 1), reentrant_regexp_last_index_calls);
    try std.testing.expectEqual(@as(?i32, 99), regexp.regexpLastIndex().?.asInt32());
}

test "regexp lastIndex define defers value finalizer reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const reentrant_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(reentrant_id, .{
        .class_name = "ReentrantRegExpLastIndexDefine",
        .payload_finalizer = reentrantRegExpLastIndexFinalizer,
    });

    const regexp = try core.Object.create(rt, core.class.ids.regexp, null);
    defer regexp.value().free(rt);
    regexp.regexpLastIndexWritableSlot().* = true;
    const value = try core.Object.create(rt, reentrant_id, null);
    regexp.regexpLastIndexSlot().* = value.value().dup();
    value.value().free(rt);

    payload_finalizer_calls = 0;
    reentrant_regexp_last_index_target = regexp;
    reentrant_regexp_last_index_calls = 0;
    defer {
        reentrant_regexp_last_index_target = null;
        reentrant_regexp_last_index_calls = 0;
    }

    try regexp.defineOwnProperty(
        rt,
        core.atom.ids.lastIndex,
        core.Descriptor.data(core.JSValue.int32(7), true, false, false),
    );

    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 0), reentrant_regexp_last_index_calls);
    try expectOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(?i32, 7), regexp.regexpLastIndex().?.asInt32());
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 1), reentrant_regexp_last_index_calls);
    try std.testing.expectEqual(@as(?i32, 99), regexp.regexpLastIndex().?.asInt32());
}

test "mapped arguments binding update defers value finalizer reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const reentrant_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(reentrant_id, .{
        .class_name = "ReentrantMappedArgumentsSet",
        .payload_finalizer = reentrantMappedArgumentsFinalizer,
    });

    const arguments = try core.Object.create(rt, core.class.ids.mapped_arguments, null);
    defer arguments.value().free(rt);
    const key = core.atom.atomFromUInt32(0);
    const value = try core.Object.create(rt, reentrant_id, null);
    const refs = try rt.memory.alloc(core.JSValue, 1);
    refs[0] = value.value().dup();
    arguments.argumentsVarRefsSlot().* = refs;
    value.value().free(rt);

    payload_finalizer_calls = 0;
    reentrant_mapped_arguments_target = arguments;
    reentrant_mapped_arguments_key = key;
    reentrant_mapped_arguments_calls = 0;
    defer {
        reentrant_mapped_arguments_target = null;
        reentrant_mapped_arguments_key = core.atom.null_atom;
        reentrant_mapped_arguments_calls = 0;
    }

    try arguments.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(7), true, true, true));

    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 0), reentrant_mapped_arguments_calls);
    try expectOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(?i32, 7), arguments.argumentsVarRefs()[0].asInt32());
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 1), reentrant_mapped_arguments_calls);
    try std.testing.expectEqual(@as(?i32, 99), arguments.argumentsVarRefs()[0].asInt32());
}

test "mapped arguments var-ref binding update defers value finalizer reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const reentrant_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(reentrant_id, .{
        .class_name = "ReentrantMappedArgumentsVarRefSet",
        .payload_finalizer = reentrantMappedArgumentsFinalizer,
    });

    const arguments = try core.Object.create(rt, core.class.ids.mapped_arguments, null);
    defer arguments.value().free(rt);
    const key = core.atom.atomFromUInt32(0);
    const value = try core.Object.create(rt, reentrant_id, null);
    const cell = try core.Object.create(rt, core.class.ids.object, null);
    try cell.initVarRefPayload(rt, value.value().dup());
    const refs = try rt.memory.alloc(core.JSValue, 1);
    refs[0] = cell.value().dup();
    arguments.argumentsVarRefsSlot().* = refs;
    value.value().free(rt);

    payload_finalizer_calls = 0;
    reentrant_mapped_arguments_target = arguments;
    reentrant_mapped_arguments_key = key;
    reentrant_mapped_arguments_calls = 0;
    defer {
        reentrant_mapped_arguments_target = null;
        reentrant_mapped_arguments_key = core.atom.null_atom;
        reentrant_mapped_arguments_calls = 0;
    }

    try arguments.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(7), true, true, true));

    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 0), reentrant_mapped_arguments_calls);
    try expectOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(?i32, 7), cell.varRefValue().?.asInt32());
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 1), reentrant_mapped_arguments_calls);
    try std.testing.expectEqual(@as(?i32, 99), cell.varRefValue().?.asInt32());
    cell.value().free(rt);
}

test "mapped arguments binding delete defers value finalizer reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const reentrant_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(reentrant_id, .{
        .class_name = "ReentrantMappedArgumentsDelete",
        .payload_finalizer = reentrantMappedArgumentsFinalizer,
    });

    const arguments = try core.Object.create(rt, core.class.ids.mapped_arguments, null);
    defer arguments.value().free(rt);
    const key = core.atom.atomFromUInt32(0);
    const refs = try rt.memory.alloc(core.JSValue, 1);
    refs[0] = core.JSValue.uninitialized();
    arguments.argumentsVarRefsSlot().* = refs;
    try arguments.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(1), true, true, true));

    const value = try core.Object.create(rt, reentrant_id, null);
    refs[0] = value.value().dup();
    value.value().free(rt);

    payload_finalizer_calls = 0;
    reentrant_mapped_arguments_target = arguments;
    reentrant_mapped_arguments_key = key;
    reentrant_mapped_arguments_calls = 0;
    defer {
        reentrant_mapped_arguments_target = null;
        reentrant_mapped_arguments_key = core.atom.null_atom;
        reentrant_mapped_arguments_calls = 0;
    }

    try std.testing.expect(arguments.deleteProperty(rt, key));

    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 0), reentrant_mapped_arguments_calls);
    try expectOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expect(arguments.argumentsVarRefs()[0].isUninitialized());
    var before_cleanup = arguments.getProperty(key);
    defer before_cleanup.free(rt);
    try std.testing.expect(before_cleanup.isUndefined());
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 1), reentrant_mapped_arguments_calls);
    try std.testing.expect(arguments.argumentsVarRefs()[0].isUninitialized());
    const after = arguments.getProperty(key);
    defer after.free(rt);
    try std.testing.expectEqual(@as(?i32, 99), after.asInt32());
}

test "cached iterator next clear defers value finalizer reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const reentrant_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(reentrant_id, .{
        .class_name = "ReentrantCachedIteratorNextClear",
        .payload_finalizer = reentrantCachedIteratorNextFinalizer,
    });

    const object = try core.Object.create(rt, core.class.ids.object, null);
    defer object.value().free(rt);
    const value = try core.Object.create(rt, reentrant_id, null);
    object.cachedIteratorNextSlot().* = value.value().dup();
    value.value().free(rt);

    payload_finalizer_calls = 0;
    reentrant_cached_iterator_next_target = object;
    reentrant_cached_iterator_next_calls = 0;
    defer {
        reentrant_cached_iterator_next_target = null;
        reentrant_cached_iterator_next_calls = 0;
    }

    object.clearCachedIteratorNext(rt);

    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 0), reentrant_cached_iterator_next_calls);
    try expectOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expect(object.cachedIteratorNext() == null);
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 1), reentrant_cached_iterator_next_calls);
    try std.testing.expect(object.cachedIteratorNext() == null);
}

test "exception slot clear defers value finalizer reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const reentrant_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(reentrant_id, .{
        .class_name = "ReentrantExceptionSlotClear",
        .payload_finalizer = reentrantExceptionSlotFinalizer,
    });

    const value = try core.Object.create(rt, reentrant_id, null);
    var slot = core.exception.ExceptionSlot{ .value = value.value().dup() };
    value.value().free(rt);

    payload_finalizer_calls = 0;
    reentrant_exception_slot_target = &slot;
    reentrant_exception_slot_calls = 0;
    defer {
        reentrant_exception_slot_target = null;
        reentrant_exception_slot_calls = 0;
    }

    slot.clear(rt);

    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 0), reentrant_exception_slot_calls);
    try expectOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expect(!slot.hasException());
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 1), reentrant_exception_slot_calls);
    try std.testing.expect(!slot.hasException());
}

test "array iterator target clear defers value finalizer reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const reentrant_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(reentrant_id, .{
        .class_name = "ReentrantArrayIteratorTargetClear",
        .payload_finalizer = reentrantArrayIteratorFinalizer,
    });

    const iterator = try core.Object.create(rt, core.class.ids.array_iterator, null);
    defer iterator.value().free(rt);
    const target = try core.Object.create(rt, reentrant_id, null);
    target.flags.is_array = true;
    iterator.iteratorTargetSlot().* = target.value().dup();
    target.value().free(rt);

    payload_finalizer_calls = 0;
    reentrant_array_iterator_target = iterator;
    reentrant_array_iterator_calls = 0;
    defer {
        reentrant_array_iterator_target = null;
        reentrant_array_iterator_calls = 0;
    }

    const result = try engine.builtins.array.methodCall(rt, iterator.value(), 20, &.{});
    defer result.free(rt);

    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 0), reentrant_array_iterator_calls);
    try expectOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expect(iterator.iteratorTargetSlot().* == null);
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 1), reentrant_array_iterator_calls);
    try std.testing.expect(iterator.iteratorTargetSlot().* == null);
}

test "runtime cycle removal follows class payload mark hooks" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const payloadless_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(payloadless_id, .{
        .class_name = "PayloadlessInCycle",
        .payload_finalizer = countPayloadFinalizer,
    });
    const external_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(external_id, .{
        .class_name = "ExternalPayloadInCycle",
        .payload_finalizer = finalizeTestExternalPayload,
        .payload_mark = markTestExternalPayload,
    });

    const payloadless = try core.Object.create(rt, payloadless_id, null);
    const external = try core.Object.create(rt, external_id, null);
    const payload = try rt.memory.create(TestExternalPayload);
    payload.* = .{ .value = payloadless.value().dup() };
    external.class_payload = .{ .external = @ptrCast(payload) };

    const key = try rt.internAtom("external");
    defer rt.atoms.free(key);
    try payloadless.defineOwnProperty(rt, key, core.Descriptor.data(external.value(), true, true, true));

    payload_finalizer_calls = 0;
    payload_mark_calls = 0;
    external.value().free(rt);
    payloadless.value().free(rt);

    try std.testing.expectEqual(@as(usize, 2), rt.runObjectCycleRemoval());
    try std.testing.expect(payload_mark_calls > 0);
    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 2), rt.pendingDeferredClassPayloadFinalizerCountForTest());
    try std.testing.expectEqual(@as(usize, 2), rt.runDeferredClassPayloadFinalizerBudgeted(2));
    try std.testing.expectEqual(@as(usize, 2), payload_finalizer_calls);
}

test "pending class payload finalizers trace payload value roots" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const external_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(external_id, .{
        .class_name = "PendingExternalPayloadRoot",
        .payload_finalizer = finalizeTestExternalPayload,
        .payload_mark = markTestExternalPayload,
    });

    const wrapper = try core.Object.create(rt, external_id, null);
    const child = try core.Object.create(rt, core.class.ids.object, null);
    const child_header = &child.header;

    const payload = try rt.memory.create(TestExternalPayload);
    payload.* = .{ .value = child.value().dup() };
    wrapper.class_payload = .{ .external = @ptrCast(payload) };

    child.value().free(rt);
    payload_finalizer_calls = 0;
    payload_mark_calls = 0;

    wrapper.value().free(rt);
    try expectOneDeferredClassPayloadFinalizer(rt);

    const Counter = struct {
        expected: *core.gc.Header,
        count: usize = 0,

        fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (slot.refHeader()) |header| {
                if (header == self.expected) self.count += 1;
            }
        }

        fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void {
            _ = context;
            _ = slot;
        }
    };

    var counter = Counter{ .expected = child_header };
    var visitor = core.runtime.RootVisitor{
        .context = &counter,
        .visit_value = Counter.visitValue,
        .visit_object = Counter.visitObject,
    };
    try rt.traceActiveRoots(&visitor);

    try std.testing.expectEqual(@as(usize, 1), counter.count);
    try std.testing.expect(payload_mark_calls > 0);
    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);

    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
}

test "runtime cycle removal clears class payload object slots before finalizers" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const external_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(external_id, .{
        .class_name = "ExternalPayloadObjectSlotCycle",
        .payload_finalizer = finalizeTestExternalObjectPayload,
        .payload_mark = markTestExternalObjectPayload,
    });

    const external = try core.Object.create(rt, external_id, null);
    const child = try core.Object.create(rt, core.class.ids.object, null);
    const payload = try rt.memory.create(TestExternalObjectPayload);
    payload.* = .{ .object = child };
    core.gc.retain(&child.header);
    external.class_payload = .{ .external = @ptrCast(payload) };

    const key = try rt.internAtom("external");
    defer rt.atoms.free(key);
    try child.defineOwnProperty(rt, key, core.Descriptor.data(external.value(), true, true, true));

    payload_finalizer_calls = 0;
    payload_mark_calls = 0;
    external.value().free(rt);
    child.value().free(rt);

    try std.testing.expectEqual(@as(usize, 2), rt.runObjectCycleRemoval());
    try std.testing.expect(payload_mark_calls > 0);
    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);
    try expectOneDeferredClassPayloadFinalizer(rt);
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
}

test "plain objects do not allocate class payload storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.object, null);
    defer object.value().free(rt);

    try std.testing.expectEqual(core.class.Payload.none, object.class_payload);
    try std.testing.expectEqual(core.class.PayloadKind.none, object.class_payload_kind);
    try std.testing.expect(@sizeOf(core.Object) <= core.Object.post_a_object_size_baseline / 2);
}

test "iterator classes store iterator state in class payload" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const iterator = try core.Object.create(rt, core.class.ids.array_iterator, null);
    defer iterator.value().free(rt);

    try std.testing.expect(iterator.class_payload == .external);
    iterator.iteratorIndexSlot().* = 7;
    iterator.iteratorKindSlot().* = 3;
    try std.testing.expectEqual(@as(usize, 7), iterator.iteratorIndexSlot().*);
    try std.testing.expectEqual(@as(u8, 3), iterator.iteratorKindSlot().*);
}

test "collection classes store entries in class payload" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const map = try core.Object.create(rt, core.class.ids.map, null);
    defer map.value().free(rt);

    try std.testing.expect(map.class_payload == .external);
    const entries = try rt.memory.alloc(core.object.CollectionEntry, 1);
    entries[0] = .{ .key = core.JSValue.int32(1), .value = core.JSValue.int32(2), .active = true };
    map.collectionEntriesSlot().* = entries;
    try std.testing.expectEqual(@as(usize, 1), map.collectionEntries().len);
    try std.testing.expectEqual(@as(i32, 1), map.collectionEntries()[0].key.asInt32().?);
    try std.testing.expectEqual(@as(i32, 2), map.collectionEntries()[0].value.asInt32().?);
}

test "buffer and typed array state use payload storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const buffer = try core.Object.create(rt, core.class.ids.array_buffer, null);
    defer buffer.value().free(rt);
    try std.testing.expect(buffer.class_payload == .external);
    try std.testing.expectEqual(core.class.PayloadKind.buffer, buffer.class_payload_kind);
    const bytes = try rt.memory.alloc(u8, 3);
    @memset(bytes, 9);
    buffer.byteStorageSlot().* = bytes;
    buffer.arrayBufferMaxByteLengthSlot().* = 8;
    try std.testing.expectEqual(@as(usize, 3), buffer.byteStorage().len);
    try std.testing.expectEqual(@as(u8, 9), buffer.byteStorage()[0]);
    try std.testing.expectEqual(@as(?usize, 8), buffer.arrayBufferMaxByteLength());

    const view = try core.Object.create(rt, core.class.ids.object, null);
    defer view.value().free(rt);
    try view.ensureTypedArrayPayload(rt);
    try std.testing.expect(view.class_payload == .external);
    try std.testing.expectEqual(core.class.PayloadKind.typed_array, view.class_payload_kind);
    view.typedArrayBufferSlot().* = buffer.value().dup();
    view.typedArrayByteOffsetSlot().* = 1;
    view.typedArrayElementSizeSlot().* = 2;
    view.typedArrayFixedLengthSlot().* = 1;
    view.typedArrayKindSlot().* = 4;
    try std.testing.expect(view.typedArrayBuffer() != null);
    try std.testing.expectEqual(@as(usize, 1), view.typedArrayByteOffset());
    try std.testing.expectEqual(@as(u32, 2), view.typedArrayElementSize());
    try std.testing.expectEqual(@as(?u32, 1), view.typedArrayFixedLength());
    try std.testing.expectEqual(@as(u8, 4), view.typedArrayKind());
}

test "shared buffer store can back wrappers in separate runtimes" {
    const left_rt = try core.JSRuntime.create(std.testing.allocator);
    defer left_rt.destroy();
    const right_rt = try core.JSRuntime.create(std.testing.allocator);
    defer right_rt.destroy();

    const store = try core.object.SharedBufferStore.create(left_rt, 4);
    defer store.release();

    const left = try core.Object.create(left_rt, core.class.ids.shared_array_buffer, null);
    defer left.value().free(left_rt);
    store.retain();
    left.installSharedByteStorage(left_rt, store);
    try std.testing.expect(left.sharedByteStorageStore() != null);

    const right_value = try engine.builtins.buffer.sharedArrayBufferFromStore(right_rt, store, null, null);
    defer right_value.free(right_rt);
    const right_header = right_value.refHeader() orelse return error.TestExpectedEqual;
    const right: *core.Object = @fieldParentPtr("header", right_header);

    left.byteStorage()[0] = 77;
    try std.testing.expectEqual(@as(u8, 77), right.byteStorage()[0]);
}

test "array buffer backing stores report external memory" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const buffer_value = try engine.builtins.buffer.arrayBufferConstructLength(rt, 16, 32, null);
    try std.testing.expectEqual(@as(usize, 16), rt.externalMemoryBytes());

    const resize_result = try engine.builtins.buffer.arrayBufferResizeLength(rt, buffer_value, 8);
    resize_result.free(rt);
    try std.testing.expectEqual(@as(usize, 8), rt.externalMemoryBytes());

    const detach_result = try engine.builtins.buffer.detachArrayBuffer(rt, buffer_value);
    detach_result.free(rt);
    const buffer_header = buffer_value.refHeader() orelse return error.TestExpectedEqual;
    const buffer: *core.Object = @fieldParentPtr("header", buffer_header);
    try std.testing.expect(buffer.arrayBufferDetached());
    try std.testing.expectEqual(@as(usize, 0), buffer.byteStorage().len);
    try std.testing.expectEqual(@as(usize, 0), rt.externalMemoryBytes());

    buffer_value.free(rt);
    try std.testing.expectEqual(@as(usize, 0), rt.externalMemoryBytes());
}

test "shared buffer store reports external memory for its owner runtime" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const store = try core.object.SharedBufferStore.create(rt, 24);
    try std.testing.expectEqual(@as(usize, 24), rt.externalMemoryBytes());

    store.release();
    try std.testing.expectEqual(@as(usize, 0), rt.externalMemoryBytes());
}

test "runtime root tracer visits async roots" {
    var rt: core.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{});
    defer rt.deinit();

    var ctx: core.JSContext = undefined;
    try ctx.init(&rt, .{});
    defer ctx.deinit();

    try ctx.ensurePendingPromiseJobCapacity(1);
    ctx.pending_promise_jobs = ctx.pending_promise_jobs.ptr[0..1];
    ctx.pending_promise_jobs[0] = try core.context.PendingPromiseJob.init(&ctx, 1, core.JSValue.int32(101));

    const TestJob = struct {
        fn run(_: *core.JSContext, _: []const core.JSValue) core.JSValue {
            return core.JSValue.undefinedValue();
        }
    };
    try rt.job_queue.enqueueFunc(&ctx, TestJob.run, &.{core.JSValue.int32(106)});
    try rt.enqueueFinalizationJob(core.JSValue.int32(107), core.JSValue.int32(108));

    const Counter = struct {
        count: usize = 0,

        fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (slot.asInt32()) |value| {
                if (value == 101 or (value >= 106 and value <= 108)) self.count += 1;
            }
        }

        fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void {
            _ = context;
            _ = slot;
        }
    };
    var counter = Counter{};
    var visitor = core.runtime.RootVisitor{
        .context = &counter,
        .visit_value = Counter.visitValue,
        .visit_object = Counter.visitObject,
    };
    try rt.traceActiveRoots(&visitor);

    try std.testing.expectEqual(@as(usize, 4), counter.count);
}

test "runtime root frame slots are mutable" {
    var rt: core.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{});
    defer rt.deinit();

    const object = try core.Object.create(&rt, core.class.ids.object, null);
    defer object.value().free(&rt);

    var rooted_value = core.JSValue.int32(201);
    var rooted_object: ?*core.Object = object;
    var root_values = [_]core.runtime.ValueRootValue{.{ .value = &rooted_value }};
    var root_objects = [_]core.runtime.ObjectRootValue{.{ .object = &rooted_object }};
    const roots = core.runtime.ValueRootFrame{
        .values = &root_values,
        .objects = &root_objects,
    };

    const Rewriter = struct {
        saw_object: bool = false,

        fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
            _ = context;
            if (slot.asInt32()) |value| {
                if (value == 201) slot.* = core.JSValue.int32(202);
            }
        }

        fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (slot.* != null) {
                self.saw_object = true;
                slot.* = null;
            }
        }
    };
    var rewriter = Rewriter{};
    var visitor = core.runtime.RootVisitor{
        .context = &rewriter,
        .visit_value = Rewriter.visitValue,
        .visit_object = Rewriter.visitObject,
    };

    try rt.traceRoots(&roots, &visitor);

    try std.testing.expectEqual(@as(?i32, 202), rooted_value.asInt32());
    try std.testing.expect(rewriter.saw_object);
    try std.testing.expect(rooted_object == null);
}

test "value root buffer exposes mutable copied slice" {
    var rt: core.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{});
    defer rt.deinit();

    const source = [_]core.JSValue{core.JSValue.int32(301)};
    var buffer = try core.runtime.ValueRootBuffer.initCopy(&rt, &source);
    defer buffer.deinit(&rt);
    var root_slices = [_]core.runtime.ValueRootSlice{buffer.slice()};
    const roots = core.runtime.ValueRootFrame{
        .slices = &root_slices,
    };

    const Rewriter = struct {
        fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
            _ = context;
            if (slot.asInt32()) |value| {
                if (value == 301) slot.* = core.JSValue.int32(302);
            }
        }

        fn visitObject(context: *anyopaque, slot: *?*core.Object) core.runtime.RootTraceError!void {
            _ = context;
            _ = slot;
        }
    };
    var unused: u8 = 0;
    var visitor = core.runtime.RootVisitor{
        .context = &unused,
        .visit_value = Rewriter.visitValue,
        .visit_object = Rewriter.visitObject,
    };

    try rt.traceRoots(&roots, &visitor);

    try std.testing.expectEqual(@as(?i32, 301), source[0].asInt32());
    try std.testing.expectEqual(@as(?i32, 302), buffer.values[0].asInt32());
}

test "regexp state uses payload storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const source = try core.string.String.createAscii(rt, "a+");
    defer source.value().free(rt);
    const flags = try core.string.String.createAscii(rt, "g");
    defer flags.value().free(rt);

    const regexp = try core.Object.create(rt, core.class.ids.regexp, null);
    defer regexp.value().free(rt);

    try std.testing.expect(regexp.class_payload == .external);
    try std.testing.expectEqual(core.class.PayloadKind.regexp, regexp.class_payload_kind);
    regexp.regexpSourceSlot().* = source.value().dup();
    regexp.regexpFlagsSlot().* = flags.value().dup();
    regexp.regexpLastIndexSlot().* = core.JSValue.int32(3);
    regexp.regexpLastIndexWritableSlot().* = false;

    try std.testing.expect(regexp.regexpSource() != null);
    try std.testing.expect(regexp.regexpFlags() != null);
    try std.testing.expectEqual(@as(?i32, 3), regexp.regexpLastIndex().?.asInt32());
    try std.testing.expect(!regexp.regexpLastIndexWritable());
}

test "bound function state uses payload storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const bound = try core.Object.create(rt, core.class.ids.bound_function, null);
    defer bound.value().free(rt);

    try std.testing.expect(bound.class_payload == .external);
    try std.testing.expectEqual(core.class.PayloadKind.bound_function, bound.class_payload_kind);
    bound.boundTargetSlot().* = core.JSValue.int32(11);
    bound.boundThisSlot().* = core.JSValue.int32(22);
    const args = try rt.memory.alloc(core.JSValue, 2);
    args[0] = core.JSValue.int32(33);
    args[1] = core.JSValue.int32(44);
    bound.boundArgsSlot().* = args;

    try std.testing.expectEqual(@as(?i32, 11), bound.boundTarget().?.asInt32());
    try std.testing.expectEqual(@as(?i32, 22), bound.boundThis().?.asInt32());
    try std.testing.expectEqual(@as(usize, 2), bound.boundArgs().len);
    try std.testing.expectEqual(@as(?i32, 33), bound.boundArgs()[0].asInt32());
    try std.testing.expectEqual(@as(?i32, 44), bound.boundArgs()[1].asInt32());
}

test "proxy state uses payload storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const proxy = try core.Object.create(rt, core.class.ids.object, null);
    defer proxy.value().free(rt);
    proxy.flags.is_proxy = true;
    try proxy.ensureProxyPayload(rt);

    try std.testing.expect(proxy.class_payload == .external);
    try std.testing.expectEqual(core.class.PayloadKind.proxy, proxy.class_payload_kind);
    proxy.proxyTargetSlot().* = core.JSValue.int32(55);
    proxy.proxyHandlerSlot().* = core.JSValue.int32(66);

    try std.testing.expectEqual(@as(?i32, 55), proxy.proxyTarget().?.asInt32());
    try std.testing.expectEqual(@as(?i32, 66), proxy.proxyHandler().?.asInt32());
}

test "arguments state uses payload storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const arguments = try core.Object.create(rt, core.class.ids.mapped_arguments, null);
    defer arguments.value().free(rt);

    try std.testing.expect(arguments.class_payload == .external);
    try std.testing.expectEqual(core.class.PayloadKind.arguments, arguments.class_payload_kind);
    const refs = try rt.memory.alloc(core.JSValue, 2);
    refs[0] = core.JSValue.int32(77);
    refs[1] = core.JSValue.int32(88);
    arguments.argumentsVarRefsSlot().* = refs;

    try std.testing.expectEqual(@as(usize, 2), arguments.argumentsVarRefs().len);
    try std.testing.expectEqual(@as(?i32, 77), arguments.argumentsVarRefs()[0].asInt32());
    try std.testing.expectEqual(@as(?i32, 88), arguments.argumentsVarRefs()[1].asInt32());
}

test "object data state uses payload storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.string, null);
    defer object.value().free(rt);

    const data = try core.string.String.createAscii(rt, "wrapped");
    defer data.value().free(rt);

    try std.testing.expect(object.class_payload == .external);
    try std.testing.expectEqual(core.class.PayloadKind.object_data, object.class_payload_kind);
    object.objectDataSlot().* = data.value().dup();
    try std.testing.expect(object.objectData() != null);
}

test "array element state uses payload storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const array = try core.Object.createArray(rt, null);
    defer array.value().free(rt);

    try std.testing.expect(array.class_payload == .external);
    try std.testing.expectEqual(core.class.PayloadKind.array, array.class_payload_kind);
    try std.testing.expectEqual(core.object.ArrayStorageMode.dense, array.arrayElementStorageMode());
    try std.testing.expect(try array.appendDenseArrayIndex(rt, 0, core.atom.atomFromUInt32(0), core.JSValue.int32(7)));
    try std.testing.expectEqual(@as(usize, 1), array.arrayElements().len);
    try std.testing.expectEqual(@as(?i32, 7), array.arrayElements()[0].?.asInt32());
}

test "promise state uses payload storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    defer promise.value().free(rt);

    try std.testing.expect(promise.class_payload == .external);
    try std.testing.expectEqual(core.class.PayloadKind.promise, promise.class_payload_kind);
    try promise.setPromiseResult(rt, core.JSValue.int32(101));
    try promise.setPromiseReactionCallback(rt, core.JSValue.int32(202));
    try promise.setPromiseReactionArg(rt, core.JSValue.int32(303));
    promise.promiseIsRejectedSlot().* = true;

    try std.testing.expectEqual(@as(?i32, 101), promise.promiseResult().?.asInt32());
    try std.testing.expectEqual(@as(?i32, 202), promise.promiseReactionCallback().?.asInt32());
    try std.testing.expectEqual(@as(?i32, 303), promise.promiseReactionArg().?.asInt32());
    try std.testing.expect(promise.promiseIsRejected());
}

test "generator state uses payload storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const generator = try core.Object.create(rt, core.class.ids.generator, null);
    defer generator.value().free(rt);

    try std.testing.expect(generator.class_payload == .external);
    try std.testing.expectEqual(core.class.PayloadKind.generator, generator.class_payload_kind);
    generator.generatorThisSlot().* = core.JSValue.int32(404);
    const args = try rt.memory.alloc(core.JSValue, 1);
    args[0] = core.JSValue.int32(505);
    generator.generatorArgsSlot().* = args;
    generator.generatorPcSlot().* = 12;
    generator.generatorDoneSlot().* = true;
    generator.generatorExecutingSlot().* = true;
    generator.generatorStartedSlot().* = true;
    generator.generatorJustYieldedSlot().* = true;

    try std.testing.expectEqual(@as(?i32, 404), generator.generatorThis().?.asInt32());
    try std.testing.expectEqual(@as(usize, 1), generator.generatorArgs().len);
    try std.testing.expectEqual(@as(?i32, 505), generator.generatorArgs()[0].asInt32());
    try std.testing.expectEqual(@as(usize, 12), generator.generatorPc());
    try std.testing.expect(generator.generatorDone());
    try std.testing.expect(generator.generatorExecuting());
    try std.testing.expect(generator.generatorStarted());
    try std.testing.expect(generator.generatorJustYielded());
}

test "native function state uses payload storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const home = try core.Object.create(rt, core.class.ids.object, null);
    defer home.value().free(rt);
    const function = try core.Object.create(rt, core.class.ids.c_function, null);
    defer function.value().free(rt);
    const source = try core.string.String.createAscii(rt, "function f(){}");
    defer source.value().free(rt);

    try std.testing.expect(function.class_payload == .external);
    try std.testing.expectEqual(core.class.PayloadKind.function, function.class_payload_kind);
    function.functionSourceSlot().* = source.value().dup();
    function.hostFunctionKindSlot().* = 11;
    function.nativeFunctionIdSlot().* = 22;
    function.functionBytecodeSlot().* = core.JSValue.int32(33);
    function.functionClassFieldsInitSlot().* = core.JSValue.int32(44);
    const captures = try rt.memory.alloc(core.JSValue, 1);
    captures[0] = core.JSValue.int32(55);
    function.functionCapturesSlot().* = captures;
    const names = try rt.memory.alloc(core.Atom, 1);
    names[0] = try rt.internAtom("evalLocal");
    function.functionEvalLocalNamesSlot().* = names;
    const refs = try rt.memory.alloc(core.JSValue, 1);
    refs[0] = core.JSValue.int32(66);
    function.functionEvalLocalRefsSlot().* = refs;
    function.functionLexicalThisSlot().* = core.JSValue.int32(77);
    try function.setFunctionHomeObject(rt, home);
    const remap_from = try rt.memory.alloc(core.Atom, 1);
    remap_from[0] = try rt.internAtom("oldPrivate");
    function.privateRemapFromSlot().* = remap_from;
    const remap_to = try rt.memory.alloc(core.Atom, 1);
    remap_to[0] = try rt.internAtom("newPrivate");
    function.privateRemapToSlot().* = remap_to;
    function.functionRealmGlobalSlot().* = home.value().dup();
    try function.setFunctionRealmGlobalPtr(rt, home);

    try std.testing.expect(function.functionSource() != null);
    try std.testing.expectEqual(@as(i32, 11), function.hostFunctionKind());
    try std.testing.expectEqual(@as(i32, 22), function.nativeFunctionId());
    try std.testing.expectEqual(@as(?i32, 33), function.functionBytecode().?.asInt32());
    try std.testing.expectEqual(@as(?i32, 44), function.functionClassFieldsInit().?.asInt32());
    try std.testing.expectEqual(@as(?i32, 55), function.functionCaptures()[0].asInt32());
    try std.testing.expectEqual(@as(usize, 1), function.functionEvalLocalNames().len);
    try std.testing.expectEqual(@as(?i32, 66), function.functionEvalLocalRefs()[0].asInt32());
    try std.testing.expectEqual(@as(?i32, 77), function.functionLexicalThis().?.asInt32());
    try std.testing.expectEqual(home, function.functionHomeObject().?);
    try std.testing.expectEqual(@as(usize, 1), function.privateRemapFrom().len);
    try std.testing.expectEqual(@as(usize, 1), function.privateRemapTo().len);
    try std.testing.expect(function.functionRealmGlobal() != null);
    try std.testing.expectEqual(home, function.functionRealmGlobalPtr().?);
}

test "bytecode function state uses payload storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const function = try core.Object.create(rt, core.class.ids.bytecode_function, null);
    defer function.value().free(rt);

    try std.testing.expect(function.class_payload == .external);
    try std.testing.expectEqual(core.class.PayloadKind.function, function.class_payload_kind);
    function.hostFunctionKindSlot().* = 11;
    function.nativeFunctionIdSlot().* = 22;

    try std.testing.expectEqual(@as(i32, 11), function.hostFunctionKind());
    try std.testing.expectEqual(@as(i32, 22), function.nativeFunctionId());
}

test "module namespace uses payload storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const namespace = try core.Object.create(rt, core.class.ids.module_ns, null);
    defer namespace.value().free(rt);

    try std.testing.expect(namespace.class_payload == .external);
    try std.testing.expectEqual(core.class.PayloadKind.module_namespace, namespace.class_payload_kind);
}

test "shapes retain property atoms and compare transitions" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
    const rt = try core.JSRuntime.create(std.testing.allocator);
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

test "shape registry release uses stable identity index after swap remove" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const first = try rt.shapes.create(1);
    const second = try rt.shapes.create(2);
    const third = try rt.shapes.create(3);

    try std.testing.expectEqual(@as(usize, 0), first.registry_index);
    try std.testing.expectEqual(@as(usize, 1), second.registry_index);
    try std.testing.expectEqual(@as(usize, 2), third.registry_index);

    rt.shapes.release(second);
    try std.testing.expectEqual(@as(usize, 2), rt.shapes.shape_hash_count);
    try std.testing.expectEqual(@as(usize, core.shape.no_registry_index), second.registry_index);
    try std.testing.expectEqual(@as(usize, 1), third.registry_index);
    try std.testing.expectEqual(third, rt.shapes.shapes[1]);

    rt.shapes.release(first);
    rt.shapes.release(third);
    try std.testing.expectEqual(@as(usize, 0), rt.shapes.shape_hash_count);
}

test "shape registry hash grows and reuses object root shapes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var shapes: [70]*core.shape.Shape = undefined;
    for (&shapes, 0..) |*slot, index| {
        slot.* = try rt.shapes.create(index);
    }
    try std.testing.expect(rt.shapes.shape_hash_buckets.len >= 128);
    try std.testing.expect(rt.shapes.shape_hash_bits > core.shape.initial_shape_hash_bits);
    for (shapes) |shape| rt.shapes.release(shape);
    try std.testing.expectEqual(@as(usize, 0), rt.shapes.shape_hash_count);

    const first = try rt.shapes.createObjectRoot(999);
    const second = try rt.shapes.createObjectRoot(999);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 2), first.ref_count);
    rt.shapes.release(first);
    rt.shapes.release(second);
    try std.testing.expectEqual(@as(usize, 0), rt.shapes.shape_hash_count);
}

test "ordinary object additions reuse transition shapes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const first = try core.Object.create(rt, core.class.ids.object, null);
    defer first.value().free(rt);
    const second = try core.Object.create(rt, core.class.ids.object, null);
    defer second.value().free(rt);

    const a = try rt.internAtom("shared_a");
    const b = try rt.internAtom("shared_b");
    defer rt.atoms.free(a);
    defer rt.atoms.free(b);

    try first.defineOwnProperty(rt, a, core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    try first.defineOwnProperty(rt, b, core.Descriptor.data(core.JSValue.int32(2), true, true, true));
    try second.defineOwnProperty(rt, a, core.Descriptor.data(core.JSValue.int32(3), true, true, true));
    try second.defineOwnProperty(rt, b, core.Descriptor.data(core.JSValue.int32(4), true, true, true));

    try std.testing.expectEqual(first.shape_ref, second.shape_ref);
    try std.testing.expect(first.shape_ref.parent != null);
    try std.testing.expectEqual(@as(usize, 2), first.shape_ref.prop_count);
    try std.testing.expectEqual(b, first.shape_ref.transition_atom);
    try std.testing.expectEqual(@as(?i32, 1), first.getProperty(a).asInt32());
    try std.testing.expectEqual(@as(?i32, 4), second.getProperty(b).asInt32());
}

test "failed new property definition rolls back retained entry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.object, null);
    defer object.value().free(rt);
    const retained = try core.Object.create(rt, core.class.ids.object, null);
    defer retained.value().free(rt);

    const a = try rt.internAtom("rollback_a");
    const b = try rt.internAtom("rollback_b");
    const c = try rt.internAtom("rollback_c");
    const d = try rt.internAtom("rollback_d");
    defer rt.atoms.free(a);
    defer rt.atoms.free(b);
    defer rt.atoms.free(c);

    try object.defineOwnProperty(rt, a, core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    try object.defineOwnProperty(rt, b, core.Descriptor.data(core.JSValue.int32(2), true, true, true));
    try object.defineOwnProperty(rt, c, core.Descriptor.data(core.JSValue.int32(3), true, true, true));

    try std.testing.expectEqual(@as(usize, 3), object.properties.len);
    try std.testing.expectEqual(@as(usize, 4), object.property_capacity);
    try std.testing.expectEqual(@as(usize, 3), object.shape_ref.prop_count);

    const retained_refs = retained.header.rc;
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, object.defineOwnProperty(rt, d, core.Descriptor.data(retained.value(), true, true, true)));
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(retained_refs, retained.header.rc);
    try std.testing.expectEqual(@as(usize, 3), object.properties.len);
    try std.testing.expectEqual(@as(usize, 3), object.shape_ref.prop_count);
    try std.testing.expect(!object.hasOwnProperty(d));

    rt.atoms.free(d);
    try std.testing.expect(rt.atoms.name(d) == null);
}

test "context lexicals property alias releases context strong reference" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    const global = try core.Object.create(rt, core.class.ids.object, null);
    const env = try core.Object.create(rt, core.class.ids.object, null);
    ctx.global = global;
    ctx.lexicals = env;

    const env_key = try rt.internAtom("env");
    defer rt.atoms.free(env_key);
    try global.defineOwnProperty(rt, env_key, core.Descriptor.data(env.value(), true, true, true));
    try std.testing.expectEqual(@as(i32, 2), env.header.rc);

    ctx.destroy();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "failed auto-init property definition rolls back retained entry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.object, null);
    defer object.value().free(rt);

    const a = try rt.internAtom("auto_rollback_a");
    const b = try rt.internAtom("auto_rollback_b");
    const c = try rt.internAtom("auto_rollback_c");
    const d = try rt.internAtom("auto_rollback_d");
    defer rt.atoms.free(a);
    defer rt.atoms.free(b);
    defer rt.atoms.free(c);

    try object.defineOwnProperty(rt, a, core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    try object.defineOwnProperty(rt, b, core.Descriptor.data(core.JSValue.int32(2), true, true, true));
    try object.defineOwnProperty(rt, c, core.Descriptor.data(core.JSValue.int32(3), true, true, true));

    try std.testing.expectEqual(@as(usize, 3), object.properties.len);
    try std.testing.expectEqual(@as(usize, 4), object.property_capacity);
    try std.testing.expectEqual(@as(usize, 3), object.shape_ref.prop_count);

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(
        error.OutOfMemory,
        object.defineAutoInitProperty(rt, d, "auto_rollback_d", 0, core.property.Flags.data(true, false, true)),
    );
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(@as(usize, 3), object.properties.len);
    try std.testing.expectEqual(@as(usize, 3), object.shape_ref.prop_count);
    try std.testing.expect(!object.hasOwnProperty(d));

    rt.atoms.free(d);
    try std.testing.expect(rt.atoms.name(d) == null);
}

test "failed realm auto-init property definition rolls back borrowed holder registration" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    global.flags.is_global = true;
    const object = try core.Object.create(rt, core.class.ids.object, null);
    defer object.value().free(rt);

    const a = try rt.internAtom("realm_auto_rollback_a");
    const b = try rt.internAtom("realm_auto_rollback_b");
    const c = try rt.internAtom("realm_auto_rollback_c");
    const d = try rt.internAtom("realm_auto_rollback_d");
    defer rt.atoms.free(a);
    defer rt.atoms.free(b);
    defer rt.atoms.free(c);

    try object.defineOwnProperty(rt, a, core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    try object.defineOwnProperty(rt, b, core.Descriptor.data(core.JSValue.int32(2), true, true, true));
    try object.defineOwnProperty(rt, c, core.Descriptor.data(core.JSValue.int32(3), true, true, true));

    const old_holder_count = rt.borrowed_reference_holders.len;
    rt.setMemoryLimit(rt.memory.allocated_bytes + borrowedHolderInitialAllocationBytes());
    try std.testing.expectError(
        error.OutOfMemory,
        object.definePerformanceAutoInitProperty(rt, d, core.property.Flags.data(true, false, true), global),
    );
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(old_holder_count, rt.borrowed_reference_holders.len);
    try std.testing.expectEqual(@as(usize, 3), object.properties.len);
    try std.testing.expectEqual(@as(usize, 3), object.shape_ref.prop_count);
    try std.testing.expect(!object.hasOwnProperty(d));

    rt.atoms.free(d);
    try std.testing.expect(rt.atoms.name(d) == null);
}

test "failed property replacement preserves existing entry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.object, null);
    defer object.value().free(rt);
    const old_value = try core.Object.create(rt, core.class.ids.object, null);
    defer old_value.value().free(rt);
    const replacement = try core.Object.create(rt, core.class.ids.object, null);
    defer replacement.value().free(rt);

    const key = try rt.internAtom("rollback_replace");
    defer rt.atoms.free(key);

    try object.defineOwnProperty(rt, key, core.Descriptor.data(old_value.value(), true, true, true));
    try std.testing.expectEqual(@as(usize, 1), object.properties.len);
    try std.testing.expectEqual(@as(usize, 1), object.shape_ref.prop_count);

    const old_refs = old_value.header.rc;
    const replacement_refs = replacement.header.rc;
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, object.defineOwnProperty(rt, key, core.Descriptor.data(replacement.value(), true, true, true)));
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(old_refs, old_value.header.rc);
    try std.testing.expectEqual(replacement_refs, replacement.header.rc);
    try std.testing.expectEqual(@as(usize, 1), object.properties.len);
    try std.testing.expectEqual(@as(usize, 1), object.shape_ref.prop_count);

    const stored = object.getProperty(key);
    defer stored.free(rt);
    try std.testing.expectEqual(&old_value.header, stored.refHeader().?);
}

test "object data property self-assignment keeps stored object alive" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const holder = try core.Object.create(rt, core.class.ids.object, null);
    defer holder.value().free(rt);
    const stored = try core.Object.create(rt, core.class.ids.object, null);
    const key = try rt.internAtom("self_assign");
    defer rt.atoms.free(key);

    try holder.defineOwnProperty(rt, key, core.Descriptor.data(stored.value(), true, true, true));
    stored.value().free(rt);
    try std.testing.expectEqual(@as(i32, 1), stored.header.rc);

    const own_value = holder.properties[0].slot.data;
    try std.testing.expect(try holder.setOwnWritableDataProperty(rt, key, own_value));
    try std.testing.expectEqual(@as(i32, 1), stored.header.rc);
    try std.testing.expectEqual(&stored.header, holder.properties[0].slot.data.refHeader().?);

    const property_value = holder.properties[0].slot.data;
    try holder.setProperty(rt, key, property_value);
    try std.testing.expectEqual(@as(i32, 1), stored.header.rc);
    try std.testing.expectEqual(&stored.header, holder.properties[0].slot.data.refHeader().?);

    const simple_value = holder.properties[0].slot.data;
    try std.testing.expect(try holder.setOrDefineOwnDataPropertyForSimpleSet(rt, key, simple_value));
    try std.testing.expectEqual(@as(i32, 1), stored.header.rc);
    try std.testing.expectEqual(&stored.header, holder.properties[0].slot.data.refHeader().?);
}

test "json parse data property self-assignment keeps stored object alive" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const holder = try core.Object.create(rt, core.class.ids.object, null);
    defer holder.value().free(rt);
    const stored = try core.Object.create(rt, core.class.ids.object, null);
    const key = try rt.internAtom("self_assign_json");
    defer rt.atoms.free(key);

    try holder.defineJsonParseDataProperty(rt, key, stored.value());
    stored.value().free(rt);
    try std.testing.expectEqual(@as(i32, 1), stored.header.rc);

    const current = holder.properties[0].slot.data;
    try holder.defineJsonParseDataProperty(rt, key, current);

    try std.testing.expectEqual(@as(i32, 1), stored.header.rc);
    try std.testing.expectEqual(&stored.header, holder.properties[0].slot.data.refHeader().?);
}

test "dense array element self-assignment keeps stored object alive" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const array = try core.Object.createArray(rt, null);
    defer array.value().free(rt);
    const stored = try core.Object.create(rt, core.class.ids.object, null);
    const index = core.atom.atomFromUInt32(0);

    try std.testing.expect(try array.appendDenseArrayIndex(rt, 0, index, stored.value()));
    stored.value().free(rt);
    try std.testing.expectEqual(@as(i32, 1), stored.header.rc);

    const current = array.arrayElements()[0].?;
    try array.setProperty(rt, index, current);

    try std.testing.expectEqual(@as(i32, 1), stored.header.rc);
    try std.testing.expectEqual(&stored.header, array.arrayElements()[0].?.refHeader().?);
}

test "prototype replacement clones shared transition shape" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const proto = try core.Object.create(rt, core.class.ids.object, null);
    defer proto.value().free(rt);
    const first = try core.Object.create(rt, core.class.ids.object, null);
    defer first.value().free(rt);
    const second = try core.Object.create(rt, core.class.ids.object, null);
    defer second.value().free(rt);

    const key = try rt.internAtom("shared_proto_key");
    defer rt.atoms.free(key);

    try first.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    try second.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(2), true, true, true));
    const shared_shape = first.shape_ref;
    try std.testing.expectEqual(shared_shape, second.shape_ref);

    try first.setPrototype(rt, proto);
    try std.testing.expect(first.shape_ref != shared_shape);
    try std.testing.expectEqual(shared_shape, second.shape_ref);
    try std.testing.expectEqual(@as(?usize, @intFromPtr(proto)), first.shape_ref.proto_id);
    try std.testing.expectEqual(@as(?usize, null), second.shape_ref.proto_id);
}

test "failed prototype replacement preserves prototype and refcounts" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const proto = try core.Object.create(rt, core.class.ids.object, null);
    defer proto.value().free(rt);
    const first = try core.Object.create(rt, core.class.ids.object, null);
    defer first.value().free(rt);
    const second = try core.Object.create(rt, core.class.ids.object, null);
    defer second.value().free(rt);

    const key = try rt.internAtom("failed_proto_key");
    defer rt.atoms.free(key);

    try first.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    try second.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(2), true, true, true));
    const shared_shape = first.shape_ref;
    try std.testing.expectEqual(shared_shape, second.shape_ref);
    try std.testing.expect(first.getPrototype() == null);

    const proto_refs = proto.header.rc;
    const shape_refs = shared_shape.ref_count;
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, first.setPrototype(rt, proto));
    rt.setMemoryLimit(null);

    try std.testing.expect(first.getPrototype() == null);
    try std.testing.expectEqual(proto_refs, proto.header.rc);
    try std.testing.expectEqual(shared_shape, first.shape_ref);
    try std.testing.expectEqual(shared_shape, second.shape_ref);
    try std.testing.expectEqual(shape_refs, shared_shape.ref_count);
    try std.testing.expectEqual(@as(?usize, null), shared_shape.proto_id);
}

test "failed object registration destroys initialized object once" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var objects: [64]*core.Object = undefined;
    for (&objects) |*slot| {
        slot.* = try core.Object.create(rt, core.class.ids.object, null);
    }
    defer {
        for (objects) |obj| obj.value().free(rt);
    }

    const shared_shape = objects[0].shape_ref;
    const shape_refs = shared_shape.ref_count;
    const bytes = rt.memory.allocated_bytes;
    const allocations = rt.memory.allocation_count;

    rt.setMemoryLimit(bytes);
    try std.testing.expectError(error.OutOfMemory, core.Object.create(rt, core.class.ids.object, null));
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(@as(usize, objects.len), rt.gc.liveCount());
    try std.testing.expectEqual(shape_refs, shared_shape.ref_count);
    try std.testing.expectEqual(bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(allocations, rt.memory.allocation_count);
}

test "shape transition cache releases chained shapes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const a = try rt.internAtom("release_a");
    const b = try rt.internAtom("release_b");
    const c = try rt.internAtom("release_c");
    defer rt.atoms.free(a);
    defer rt.atoms.free(b);
    defer rt.atoms.free(c);

    var objects: [32]*core.Object = undefined;
    for (&objects, 0..) |*slot, index| {
        const obj = try core.Object.create(rt, core.class.ids.object, null);
        try obj.defineOwnProperty(rt, a, core.Descriptor.data(core.JSValue.int32(@intCast(index)), true, true, true));
        try obj.defineOwnProperty(rt, b, core.Descriptor.data(core.JSValue.int32(@intCast(index + 1)), true, true, true));
        try obj.defineOwnProperty(rt, c, core.Descriptor.data(core.JSValue.int32(@intCast(index + 2)), true, true, true));
        slot.* = obj;
    }

    const shared_shape = objects[0].shape_ref;
    for (objects[1..]) |obj| try std.testing.expectEqual(shared_shape, obj.shape_ref);
    for (objects) |obj| obj.value().free(rt);

    try std.testing.expectEqual(@as(usize, 0), rt.shapes.shape_hash_count);
}

test "inline cache slot guards shape identity and version" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const obj = try core.Object.create(rt, core.class.ids.object, null);
    defer obj.value().free(rt);

    const key = try rt.internAtom("ic_key");
    defer rt.atoms.free(key);

    try obj.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(1), true, true, true));

    var slot = engine.bytecode.ic.Slot{};
    defer slot.deinit(&rt.shapes);

    try std.testing.expectEqual(engine.bytecode.ic.InstallResult.installed_mono, slot.installOwnData(&rt.shapes, obj, key, 0));
    try std.testing.expectEqual(@as(?usize, 0), slot.lookupOwnData(obj, key));

    try std.testing.expect(obj.deleteProperty(rt, key));
    try std.testing.expectEqual(@as(?usize, null), slot.lookupOwnData(obj, key));

    try obj.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(2), true, true, true));
    try std.testing.expectEqual(engine.bytecode.ic.InstallResult.promoted_poly, slot.installOwnData(&rt.shapes, obj, key, 1));
    try std.testing.expectEqual(@as(?usize, 1), slot.lookupOwnData(obj, key));
}

test "inline cache slot guards immediate prototype holder shape and version" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const proto = try core.Object.create(rt, core.class.ids.object, null);
    defer proto.value().free(rt);

    const obj = try core.Object.create(rt, core.class.ids.object, proto);
    defer obj.value().free(rt);

    const key = try rt.internAtom("proto_ic_key");
    defer rt.atoms.free(key);

    try proto.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(7), true, true, true));

    var slot = engine.bytecode.ic.Slot{};
    defer slot.deinit(&rt.shapes);

    try std.testing.expectEqual(engine.bytecode.ic.InstallResult.installed_mono, slot.installProtoData(&rt.shapes, obj, proto, key, 0));
    switch (slot.lookupProtoDataResult(obj, key)) {
        .hit => |hit| {
            try std.testing.expect(hit.holder == proto);
            try std.testing.expectEqual(@as(usize, 0), hit.slot_index);
        },
        .miss, .invalidated => return error.ExpectedProtoIcHit,
    }

    try std.testing.expect(proto.deleteProperty(rt, key));
    try std.testing.expectEqual(engine.bytecode.ic.ProtoLookupResult.invalidated, slot.lookupProtoDataResult(obj, key));
}

test "large object property lookup uses shape hash across delete and re-add" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const obj = try core.Object.create(rt, core.class.ids.object, null);
    defer obj.value().free(rt);

    var name_buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "prop_{d}", .{i});
        const key = try rt.internAtom(name);
        try obj.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(@intCast(i)), true, true, true));
        rt.atoms.free(key);
    }

    try std.testing.expect(obj.shape_ref.hasPropertyHash());
    try std.testing.expect(obj.shape_ref.version > 0);

    const target = try rt.internAtom("prop_96");
    defer rt.atoms.free(target);
    const before = obj.getProperty(target);
    defer before.free(rt);
    try std.testing.expectEqual(@as(?i32, 96), before.asInt32());

    const version_before_delete = obj.shape_ref.version;
    try std.testing.expect(obj.deleteProperty(rt, target));
    try std.testing.expect(obj.shape_ref.version > version_before_delete);
    try std.testing.expect(!obj.hasOwnProperty(target));

    try obj.defineOwnProperty(rt, target, core.Descriptor.data(core.JSValue.int32(777), true, true, true));
    const after = obj.getProperty(target);
    defer after.free(rt);
    try std.testing.expectEqual(@as(?i32, 777), after.asInt32());
}

test "exception slot transfers owned value and clears context slot" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
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
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const str = try core.string.String.createAscii(rt, "abc");
    const value = str.value();
    const duped = value.dup();
    try std.testing.expectEqual(@as(i32, 2), str.header.rc);

    value.free(rt);
    try std.testing.expectEqual(@as(i32, 1), str.header.rc);
    duped.free(rt);
}

test "memory account tracks same-allocator allocation and free" {
    var account = core.memory.MemoryAccount.init(std.testing.allocator);
    const buf = try account.alloc(u8, 16);
    try std.testing.expect(account.hasOutstandingAllocations());
    account.free(u8, buf);
    try std.testing.expect(!account.hasOutstandingAllocations());
}

test "memory account treats zero-length allocations as inert" {
    var account = core.memory.MemoryAccount.init(std.testing.allocator);
    const empty = try account.alloc(u8, 0);

    try std.testing.expectEqual(@as(usize, 0), account.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), account.allocation_count);
    try std.testing.expect(!account.hasOutstandingAllocations());

    account.free(u8, empty);
    try std.testing.expectEqual(@as(usize, 0), account.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), account.allocation_count);
    try std.testing.expect(!account.hasOutstandingAllocations());
}

test "gc registry tracks live objects and intrusive list state" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const obj = try core.Object.create(rt, core.class.ids.object, null);
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCount());

    rt.gc.unlinkObject(&obj.header);
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());

    // Clean up manually since we unlinked it
    core.Object.destroyFromHeader(rt, &obj.header);
}

test "gc policy presets do not enable unimplemented concurrent collectors by default" {
    const default_policy: core.gc.Policy = .{};
    try std.testing.expect(!default_policy.enable_concurrent_mark);
    try std.testing.expect(!default_policy.enable_concurrent_sweep);

    const throughput = core.gc.Policy.forMode(.throughput);
    try std.testing.expectEqual(core.gc.Mode.throughput, throughput.mode);
    try std.testing.expect(!throughput.enable_concurrent_mark);
    try std.testing.expect(!throughput.enable_concurrent_sweep);

    const low_rss = core.gc.Policy.forMode(.low_rss);
    try std.testing.expect(low_rss.external_weight > default_policy.external_weight);
    try std.testing.expect(low_rss.cgroup_soft_ratio_per_mille != 0);
    try std.testing.expect(low_rss.cgroup_hard_ratio_per_mille != 0);

    const low_latency = core.gc.Policy.forMode(.low_latency);
    try std.testing.expect(low_latency.callback_slice_budget_ns < default_policy.callback_slice_budget_ns);
}

test "gc process memory pressure policy maps rss and cgroup usage to major requests" {
    var rt: core.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{
        .gc_policy = .{
            .rss_soft_limit = 100,
            .rss_hard_limit = 200,
            .cgroup_soft_ratio_per_mille = 800,
            .cgroup_hard_ratio_per_mille = 950,
        },
    });
    defer rt.deinit();

    try std.testing.expect(rt.gc.processMemoryRequest(99, 0) == null);

    const rss_soft = rt.gc.processMemoryRequest(100, 0).?;
    try std.testing.expectEqual(core.gc.RequestReason.rss_pressure, rss_soft.reason);
    try std.testing.expectEqual(core.gc.RequestUrgency.soon, rss_soft.urgency);

    const rss_hard = rt.gc.processMemoryRequest(200, 0).?;
    try std.testing.expectEqual(core.gc.RequestReason.rss_pressure, rss_hard.reason);
    try std.testing.expectEqual(core.gc.RequestUrgency.urgent, rss_hard.urgency);

    const cgroup_hard = rt.gc.processMemoryRequest(96, 100).?;
    try std.testing.expectEqual(core.gc.RequestUrgency.urgent, cgroup_hard.urgency);
}

test "function bytecode registration is old-space accounted" {
    var rt: core.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{
        .gc_policy = .{
            .old_weight = 3,
            .major_debt_threshold = @sizeOf(engine.bytecode.FunctionBytecode) * 3,
        },
    });
    defer rt.deinit();

    const fb_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);
    const value = core.JSValue.functionBytecode(&fb.header);
    defer value.free(&rt);

    try std.testing.expectEqual(@as(usize, @sizeOf(engine.bytecode.FunctionBytecode)), rt.gc.stats.old_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), rt.gc.stats.old_alloc_count);
    try std.testing.expectEqual(@as(usize, @sizeOf(engine.bytecode.FunctionBytecode) * 3), rt.allocationDebtBytes());
    try std.testing.expect(rt.gcPendingForTest());
    try std.testing.expect(rt.gc.hasPendingMajorRequest());
    try std.testing.expectEqual(@as(?core.gc.RequestReason, core.gc.RequestReason.allocation_debt), rt.gcLastRequestReasonForTest());
}

test "runtime exposes stable gc stats snapshot" {
    var rt: core.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{
        .gc_policy = .{
            .major_debt_threshold = std.math.maxInt(usize),
            .external_weight = 3,
        },
    });
    defer rt.deinit();

    const owner = try core.Object.create(&rt, core.class.ids.c_function, null);
    defer owner.value().free(&rt);
    const child = try core.Object.create(&rt, core.class.ids.object, null);
    defer child.value().free(&rt);

    var token = try rt.reportExternalAlloc(32);
    defer token.release();

    const key = try rt.internAtom("statsChild");
    defer rt.atoms.free(key);
    try owner.defineOwnProperty(&rt, key, core.Descriptor.data(child.value(), true, true, true));

    const snapshot = rt.gcStats();
    try std.testing.expectEqual(@as(usize, @sizeOf(core.Object) * 2), snapshot.total_allocated_bytes);
    try std.testing.expectEqual(@as(usize, @sizeOf(core.Object) * 2), snapshot.heap_live_bytes);
    try std.testing.expectEqual(@as(usize, @sizeOf(core.Object) * 2), snapshot.old_live_bytes);
    try std.testing.expectEqual(@as(usize, 0), snapshot.large_object_bytes);
    try std.testing.expectEqual(@as(usize, core.gc.logical_page_size), snapshot.heap_committed_bytes);
    try std.testing.expectEqual(@as(usize, core.gc.logical_page_size), snapshot.old_committed_bytes);
    try std.testing.expectEqual(@as(usize, @sizeOf(core.Object) * 2), snapshot.old_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 2), snapshot.old_alloc_count);
    try std.testing.expectEqual(@as(usize, 32), snapshot.external_bytes);
    try std.testing.expectEqual(@as(usize, 1), snapshot.external_alloc_count);
    try std.testing.expectEqual(@as(usize, 1), snapshot.external_token_count);
    try std.testing.expectEqual(@as(usize, 32), snapshot.external_token_bytes);
    try std.testing.expectEqual(@as(usize, 0), snapshot.weak_ref_count);
    try std.testing.expectEqual(@as(usize, 0), snapshot.finalizer_queue_length);
    try std.testing.expectEqual(@as(usize, 0), snapshot.major_gc_count);
    try std.testing.expectEqual(@as(u64, 0), snapshot.incremental_slice_ns_p50);
    try std.testing.expectEqual(@as(u64, 0), snapshot.incremental_slice_ns_p95);
    try std.testing.expectEqual(@as(u64, 0), snapshot.incremental_slice_ns_p99);
    if (builtin.os.tag == .linux) try std.testing.expect(snapshot.rss_bytes != 0);

    token.release();
    const after_external_free = rt.gcStats();
    try std.testing.expectEqual(@as(usize, 0), after_external_free.external_bytes);
    try std.testing.expectEqual(@as(usize, 1), after_external_free.external_free_count);
    try std.testing.expectEqual(@as(usize, 0), after_external_free.external_token_count);
    try std.testing.expectEqual(@as(usize, 0), after_external_free.external_token_bytes);
}

test "gc live heap stats drop when object is released" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.object, null);

    const allocated = rt.gcStats();
    try std.testing.expectEqual(@as(usize, @sizeOf(core.Object)), allocated.total_allocated_bytes);
    try std.testing.expectEqual(@as(usize, @sizeOf(core.Object)), allocated.heap_live_bytes);
    try std.testing.expectEqual(@as(usize, @sizeOf(core.Object)), allocated.old_live_bytes);
    try std.testing.expectEqual(@as(usize, 0), allocated.large_object_bytes);
    try std.testing.expectEqual(@as(usize, core.gc.logical_page_size), allocated.heap_committed_bytes);
    try std.testing.expectEqual(@as(usize, core.gc.logical_page_size), allocated.old_committed_bytes);

    object.value().free(rt);

    const released = rt.gcStats();
    try std.testing.expectEqual(@as(usize, @sizeOf(core.Object)), released.total_allocated_bytes);
    try std.testing.expectEqual(@as(usize, @sizeOf(core.Object)), released.old_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), released.heap_live_bytes);
    try std.testing.expectEqual(@as(usize, 0), released.old_live_bytes);
    try std.testing.expectEqual(@as(usize, 0), released.large_object_bytes);
    try std.testing.expectEqual(@as(usize, core.gc.logical_page_size), released.heap_committed_bytes);
    try std.testing.expectEqual(@as(usize, core.gc.logical_page_size), released.empty_page_bytes);
    try std.testing.expectEqual(@as(usize, 1000), released.old_fragmentation_ratio);

    rt.gc.decommitEmptyPagesNow();
    const decommitted = rt.gcStats();
    try std.testing.expectEqual(@as(usize, 0), decommitted.heap_committed_bytes);
    try std.testing.expectEqual(@as(usize, 0), decommitted.empty_page_bytes);
    try std.testing.expectEqual(@as(usize, core.gc.logical_page_size), decommitted.decommitted_bytes);
}

test "external memory token registry audits duplicate releases and leaks" {
    var rt: core.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{});
    defer rt.deinit();

    var token = try rt.reportExternalAlloc(64);
    var duplicate_token = token;

    var stats = rt.gcStats();
    try std.testing.expectEqual(@as(usize, 64), stats.external_bytes);
    try std.testing.expectEqual(@as(usize, 1), stats.external_token_count);
    try std.testing.expectEqual(@as(usize, 64), stats.external_token_bytes);
    try rt.gc.verifyHeapAccounting();
    try std.testing.expectError(error.LeakedExternalMemoryToken, rt.gc.verifyNoExternalTokenLeaks());

    token.release();
    stats = rt.gcStats();
    try std.testing.expectEqual(@as(usize, 0), stats.external_bytes);
    try std.testing.expectEqual(@as(usize, 0), stats.external_token_count);
    try std.testing.expectEqual(@as(usize, 1), stats.external_free_count);
    try rt.gc.verifyHeapAccounting();
    try rt.gc.verifyNoExternalTokenLeaks();

    duplicate_token.release();
    stats = rt.gcStats();
    try std.testing.expectEqual(@as(usize, 0), stats.external_bytes);
    try std.testing.expectEqual(@as(usize, 1), stats.external_free_count);
    try std.testing.expectEqual(@as(usize, 1), stats.external_invalid_release_count);
    try rt.gc.verifyHeapAccounting();
}

test "runtime runs deferred native cleanup jobs with a budget" {
    var rt: core.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{});
    defer rt.deinit();

    var calls: usize = 0;
    try rt.enqueueDeferredNativeCleanup(countNativeCleanup, @ptrCast(&calls));
    try rt.enqueueDeferredNativeCleanup(countNativeCleanup, @ptrCast(&calls));

    var stats = rt.gcStats();
    try std.testing.expectEqual(@as(usize, 2), rt.pendingDeferredNativeCleanupCountForTest());
    try std.testing.expectEqual(@as(usize, 2), stats.deferred_native_cleanup_count);
    try std.testing.expectEqual(@as(usize, 0), stats.deferred_native_cleanup_run_count);

    try std.testing.expectEqual(@as(usize, 1), rt.runDeferredNativeCleanupBudgeted(1));
    stats = rt.gcStats();
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 1), rt.pendingDeferredNativeCleanupCountForTest());
    try std.testing.expectEqual(@as(usize, 1), stats.deferred_native_cleanup_count);
    try std.testing.expectEqual(@as(usize, 1), stats.deferred_native_cleanup_run_count);

    rt.drainDeferredNativeCleanups();
    stats = rt.gcStats();
    try std.testing.expectEqual(@as(usize, 2), calls);
    try std.testing.expectEqual(@as(usize, 0), rt.pendingDeferredNativeCleanupCountForTest());
    try std.testing.expectEqual(@as(usize, 0), stats.deferred_native_cleanup_count);
    try std.testing.expectEqual(@as(usize, 2), stats.deferred_native_cleanup_run_count);
}

test "external host finalizers are deferred through native cleanup queue" {
    var rt: core.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{});
    defer rt.deinit();

    var calls: usize = 0;
    _ = try rt.registerExternalHostFunction(.{
        .ptr = @ptrCast(&calls),
        .call = dummyExternalHostCall,
        .finalizer = countNativeCleanup,
    });

    rt.clearExternalHostFunctions();
    try std.testing.expectEqual(@as(usize, 0), calls);
    try std.testing.expectEqual(@as(usize, 1), rt.pendingDeferredNativeCleanupCountForTest());
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().deferred_native_cleanup_count);

    try std.testing.expectEqual(@as(usize, 1), rt.runDeferredNativeCleanupBudgeted(1));
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 0), rt.pendingDeferredNativeCleanupCountForTest());
}

test "std file object destruction defers native close cleanup" {
    var rt: core.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{});
    defer rt.deinit();

    const file = tmpfile() orelse return error.SkipZigTest;
    var file_owned_by_test = true;
    errdefer {
        if (file_owned_by_test) _ = std.c.fclose(file);
    }

    const object = try core.Object.create(&rt, core.class.ids.std_file, null);
    object.stdFileSlot().* = file;
    object.stdFileIsPopenSlot().* = false;
    object.stdFileIsStdioSlot().* = false;
    file_owned_by_test = false;

    object.value().free(&rt);

    var stats = rt.gcStats();
    try std.testing.expectEqual(@as(usize, 1), rt.pendingDeferredNativeCleanupCountForTest());
    try std.testing.expectEqual(@as(usize, 1), stats.deferred_native_cleanup_count);
    try std.testing.expectEqual(@as(usize, 0), stats.deferred_native_cleanup_run_count);

    try std.testing.expectEqual(@as(usize, 1), rt.runDeferredNativeCleanupBudgeted(1));
    stats = rt.gcStats();
    try std.testing.expectEqual(@as(usize, 0), rt.pendingDeferredNativeCleanupCountForTest());
    try std.testing.expectEqual(@as(usize, 0), stats.deferred_native_cleanup_count);
    try std.testing.expectEqual(@as(usize, 1), stats.deferred_native_cleanup_run_count);
}

test "gc callback boundary defers non-urgent major work until idle" {
    var rt: core.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{});
    defer rt.deinit();

    rt.gc.requestGC(.manual, .soon);
    const callback_result = try rt.pollGC(null, .callback_boundary);
    try std.testing.expectEqual(@as(usize, 0), callback_result.freed_objects);
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().major_gc_count);
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().major_slice_count);
    try std.testing.expect(rt.gcPendingForTest());
    try std.testing.expect(rt.gc.hasPendingMajorRequest());

    _ = try rt.pollGC(null, .idle);
    const after_idle = rt.gcStats();
    try std.testing.expectEqual(@as(usize, 1), after_idle.major_gc_count);
    try std.testing.expectEqual(core.gc.MajorPhase.idle, after_idle.major_phase);
    try std.testing.expectEqual(@as(usize, 1), after_idle.major_slice_count);
    try std.testing.expectEqual(after_idle.major_gc_time_ns, after_idle.last_incremental_slice_ns);
    try std.testing.expectEqual(after_idle.major_gc_time_ns, after_idle.sweep_time_ns);
    try std.testing.expectEqual(after_idle.major_gc_time_ns, after_idle.major_pause_ns_p50);
    try std.testing.expectEqual(after_idle.major_gc_time_ns, after_idle.major_pause_ns_p95);
    try std.testing.expectEqual(after_idle.major_gc_time_ns, after_idle.major_pause_ns_p99);
    try std.testing.expect(!rt.gcPendingForTest());
}

test "gc callback boundary runs urgent major work" {
    var rt: core.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{});
    defer rt.deinit();

    rt.gc.requestGC(.manual, .urgent);
    _ = try rt.pollGC(null, .callback_boundary);

    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().major_gc_count);
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().major_slice_count);
    try std.testing.expect(!rt.gcPendingForTest());
}

test "runtime force major gc runs an urgent major poll" {
    var rt: core.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{});
    defer rt.deinit();

    const result = try rt.forceMajorGC(null);
    try std.testing.expectEqual(@as(usize, 0), result.freed_objects);
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().major_gc_count);
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().major_slice_count);
    try std.testing.expect(!rt.gcPendingForTest());
}

test "object child edge tracing exposes mutable value slots" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const array_obj = try core.Object.createArray(rt, null);
    defer array_obj.value().free(rt);

    const key = try rt.internAtom("traceSlot");
    defer rt.atoms.free(key);
    try array_obj.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(401), true, true, true));
    try std.testing.expect(try array_obj.appendDenseArrayIndex(rt, 0, core.atom.atomFromUInt32(0), core.JSValue.int32(402)));

    const Rewriter = struct {
        count_401: usize = 0,
        count_402: usize = 0,

        pub fn visitValue(self: *@This(), slot: *core.JSValue) void {
            if (slot.asInt32()) |value| {
                if (value == 401) {
                    self.count_401 += 1;
                    slot.* = core.JSValue.int32(501);
                }
                if (value == 402) {
                    self.count_402 += 1;
                    slot.* = core.JSValue.int32(502);
                }
            }
        }

        pub fn visitObject(_: *@This(), slot: *?*core.Object) void {
            _ = slot;
        }
    };
    var rewriter = Rewriter{};
    try array_obj.traceChildEdges(rt, &rewriter);

    try std.testing.expectEqual(@as(usize, 1), rewriter.count_401);
    try std.testing.expectEqual(@as(usize, 1), rewriter.count_402);

    const property_value = array_obj.getProperty(key);
    defer property_value.free(rt);
    try std.testing.expectEqual(@as(?i32, 501), property_value.asInt32());
    try std.testing.expectEqual(@as(?i32, 502), array_obj.arrayElements()[0].?.asInt32());
}

test "gc registry debug verifier accepts linked and unlinked list states" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    try rt.gc.verifyIntrusiveList();

    const obj = try core.Object.create(rt, core.class.ids.object, null);
    try rt.gc.verifyIntrusiveList();

    obj.value().free(rt);
    try rt.gc.verifyIntrusiveList();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "gc heap accounting verifier catches live byte drift" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    try rt.gc.verifyHeapAccounting();

    const obj = try core.Object.create(rt, core.class.ids.object, null);
    try rt.gc.verifyHeapAccounting();

    rt.gc.stats.heap_live_bytes += 1;
    try std.testing.expectError(error.HeapLiveBytesMismatch, rt.gc.verifyHeapAccounting());
    rt.gc.stats.heap_live_bytes -= 1;
    try rt.gc.verifyHeapAccounting();

    obj.value().free(rt);
    try rt.gc.verifyHeapAccounting();
}

test "gc heap accounting verifier catches missing allocation entries" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const obj = try core.Object.create(rt, core.class.ids.object, null);
    defer obj.value().free(rt);
    try rt.gc.verifyHeapAccounting();

    const old_allocations = rt.gc.heap_allocations;
    rt.gc.heap_allocations = old_allocations[0..0];
    try std.testing.expectError(error.MissingHeapAllocation, rt.gc.verifyHeapAccounting());
    rt.gc.heap_allocations = old_allocations;
    try rt.gc.verifyHeapAccounting();
}

test "gc heap accounting verifier catches pinned header flag drift" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const obj = try core.Object.create(rt, core.class.ids.object, null);
    const value = obj.value();
    var pin = (try core.runtime.pinValueForNative(rt, value)).?;
    defer pin.release();
    value.free(rt);

    try rt.gc.verifyHeapAccounting();
    obj.header.setPinned(false);
    try std.testing.expectError(error.PinnedHeaderFlagMismatch, rt.gc.verifyHeapAccounting());
    obj.header.setPinned(true);
    try rt.gc.verifyHeapAccounting();
}

test "object traceChildEdgesFallible propagates visitor errors" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const obj = try core.Object.create(rt, core.class.ids.object, null);
    defer obj.value().free(rt);
    const child = try core.Object.create(rt, core.class.ids.object, null);
    defer child.value().free(rt);
    const key = try rt.internAtom("trace-error-child");
    defer rt.atoms.free(key);

    try obj.defineOwnProperty(rt, key, core.Descriptor.data(child.value(), true, true, true));

    const Visitor = struct {
        pub fn visitValue(_: *@This(), _: *core.JSValue) !void {
            return error.OutOfMemory;
        }
    };

    var visitor = Visitor{};
    try std.testing.expectError(error.OutOfMemory, obj.traceChildEdgesFallible(rt, &visitor));
}

test "object traceChildEdgesFallible propagates class payload visitor errors" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const external_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(external_id, .{
        .class_name = "TraceErrorExternalPayload",
        .payload_finalizer = finalizeTestExternalPayload,
        .payload_mark = markTestExternalPayload,
    });

    const obj = try core.Object.create(rt, external_id, null);
    defer obj.value().free(rt);
    const child = try core.Object.create(rt, core.class.ids.object, null);
    defer child.value().free(rt);

    const payload = try rt.memory.create(TestExternalPayload);
    payload.* = .{ .value = child.value().dup() };
    obj.class_payload = .{ .external = @ptrCast(payload) };

    const Visitor = struct {
        err: ?core.gc.CollectionError = null,

        pub fn visitValue(_: *@This(), _: *core.JSValue) core.gc.CollectionError!void {
            return error.OutOfMemory;
        }
    };

    var visitor = Visitor{};
    try std.testing.expectError(error.OutOfMemory, obj.traceChildEdgesFallible(rt, &visitor));
}

test "gc object release does not allocate after refcount reaches zero" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const obj = try core.Object.create(rt, core.class.ids.object, null);

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    const did_release = rt.gc.releaseObject(&obj.header);
    rt.setMemoryLimit(null);

    try std.testing.expect(did_release);
    try std.testing.expectEqual(@as(i32, 0), obj.header.rc);
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());

    // Clean up manually since we released/unlinked it
    core.Object.destroyFromHeader(rt, &obj.header);
}

test "closed object property cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const left = try core.Object.create(rt, core.class.ids.object, null);
    const right = try core.Object.create(rt, core.class.ids.object, null);
    const left_key = try rt.internAtom("left");
    defer rt.atoms.free(left_key);
    const right_key = try rt.internAtom("right");
    defer rt.atoms.free(right_key);

    try left.defineOwnProperty(rt, right_key, core.Descriptor.data(right.value(), true, true, true));
    try right.defineOwnProperty(rt, left_key, core.Descriptor.data(left.value(), true, true, true));

    left.value().free(rt);
    right.value().free(rt);
    try std.testing.expectEqual(@as(usize, 2), rt.runObjectCycleRemoval());
}

test "fallible GC API reports reclaimed objects and no failure" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const left = try core.Object.create(rt, core.class.ids.object, null);
    const right = try core.Object.create(rt, core.class.ids.object, null);
    const left_key = try rt.internAtom("gc-result-left");
    defer rt.atoms.free(left_key);
    const right_key = try rt.internAtom("gc-result-right");
    defer rt.atoms.free(right_key);

    try left.defineOwnProperty(rt, right_key, core.Descriptor.data(right.value(), true, true, true));
    try right.defineOwnProperty(rt, left_key, core.Descriptor.data(left.value(), true, true, true));
    left.value().free(rt);
    right.value().free(rt);

    const before_collections = rt.gc.stats.collections;
    const result = try rt.tryRunObjectCycleRemoval();

    try std.testing.expectEqual(@as(usize, 2), result.freed_objects);
    try std.testing.expectEqual(before_collections + 1, rt.gc.stats.collections);
    try std.testing.expectEqual(@as(usize, 0), rt.gc.stats.failed_collections);
    try std.testing.expectEqual(core.gc.FailureKind.none, rt.gc.stats.last_failure);
}

test "pollGC runs pending collection and clears pending flag" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const left = try core.Object.create(rt, core.class.ids.object, null);
    const right = try core.Object.create(rt, core.class.ids.object, null);
    const left_key = try rt.internAtom("poll-left");
    defer rt.atoms.free(left_key);
    const right_key = try rt.internAtom("poll-right");
    defer rt.atoms.free(right_key);

    try left.defineOwnProperty(rt, right_key, core.Descriptor.data(right.value(), true, true, true));
    try right.defineOwnProperty(rt, left_key, core.Descriptor.data(left.value(), true, true, true));
    left.value().free(rt);
    right.value().free(rt);

    rt.requestGCForTest();
    try std.testing.expectEqual(@as(?core.gc.RequestReason, core.gc.RequestReason.manual), rt.gcLastRequestReasonForTest());
    const result = try rt.pollGC(null, .normal);
    try std.testing.expectEqual(@as(usize, 2), result.freed_objects);
    try std.testing.expect(!rt.gcPendingForTest());
}

test "persistent value handle keeps object and nested symbols alive" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.object, null);
    const key = try rt.atoms.newValueSymbol("persistent-handle-symbol-key");
    const value = object.value();
    try object.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.boolean(true), true, true, true));

    const handle = try rt.createPersistentValue(value);
    value.free(rt);

    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(key) != null);
    try std.testing.expect(rt.gc.liveCount() != 0);

    handle.destroy(rt);
    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(key) == null);
}

test "handle scope local keeps object alive until scope exits" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.object, null);
    const value = object.value();

    var scope = rt.enterHandleScope();
    const local = try scope.localDup(value);
    value.free(rt);

    try std.testing.expectEqual(@as(usize, 1), rt.localRootCountForTest());
    try std.testing.expectEqual(@as(usize, 0), rt.persistentRootCountForTest());
    try std.testing.expect(local.get().isObject());

    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCount());

    scope.exit();
    try std.testing.expectEqual(@as(usize, 0), rt.localRootCountForTest());

    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "handle scope locals do not clear persistent handles created inside scope" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const local_object = try core.Object.create(rt, core.class.ids.object, null);
    const persistent_object = try core.Object.create(rt, core.class.ids.object, null);
    const local_value = local_object.value();
    const persistent_value = persistent_object.value();

    var scope = rt.enterHandleScope();
    _ = try scope.localDup(local_value);
    local_value.free(rt);

    const persistent = try rt.createPersistentValue(persistent_value);
    persistent_value.free(rt);

    try std.testing.expectEqual(@as(usize, 1), rt.localRootCountForTest());
    try std.testing.expectEqual(@as(usize, 1), rt.persistentRootCountForTest());

    scope.exit();
    try std.testing.expectEqual(@as(usize, 0), rt.localRootCountForTest());
    try std.testing.expectEqual(@as(usize, 1), rt.persistentRootCountForTest());

    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCount());

    persistent.destroy(rt);
    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "native pin retains direct object and counts nested pins" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.object, null);
    const value = object.value();

    var first_pin = (try core.runtime.pinValueForNative(rt, value)).?;
    var second_pin = try core.runtime.pinHeaderForNative(rt, &object.header);

    try std.testing.expect(object.header.pinned());
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().pinned_cell_count);
    try std.testing.expectEqual(@as(i32, 3), object.header.rc);

    value.free(rt);
    try std.testing.expectEqual(@as(i32, 2), object.header.rc);
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCount());

    first_pin.release();
    try std.testing.expect(object.header.pinned());
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().pinned_cell_count);
    try std.testing.expectEqual(@as(i32, 1), object.header.rc);

    second_pin.release();
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().pinned_cell_count);
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

fn weakPersistentCounterCallback(_: *core.JSRuntime, context: ?*anyopaque) void {
    const counter: *usize = @ptrCast(@alignCast(context.?));
    counter.* += 1;
}

test "weak persistent value rejects non-weak targets" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    try std.testing.expectError(
        error.InvalidWeakTarget,
        rt.createWeakPersistentValue(core.JSValue.int32(1), null, null),
    );
}

test "weak persistent value does not retain direct object target" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    var clear_count: usize = 0;
    var weak = try rt.createWeakPersistentValue(target.value(), weakPersistentCounterCallback, &clear_count);
    defer weak.deinit();

    try std.testing.expectEqual(@as(usize, 1), rt.weakRootCountForTest());
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().weak_ref_count);
    try std.testing.expect(weak.isAlive());
    {
        const live = weak.get();
        defer live.free(rt);
        try std.testing.expectEqual(&target.header, live.refHeader().?);
    }

    target.value().free(rt);

    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
    try std.testing.expect(!weak.isAlive());
    try std.testing.expect(weak.get().isUndefined());
    try std.testing.expectEqual(@as(usize, 1), clear_count);

    weak.deinit();
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().weak_ref_count);
}

test "weak persistent value clears object cycle target during gc" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const target = try core.Object.create(rt, core.class.ids.object, null);
    const self_key = try rt.internAtom("weak-persistent-cycle-self");
    defer rt.atoms.free(self_key);
    try target.defineOwnProperty(rt, self_key, core.Descriptor.data(target.value(), true, true, true));

    var clear_count: usize = 0;
    var weak = try rt.createWeakPersistentValue(target.value(), weakPersistentCounterCallback, &clear_count);
    defer weak.deinit();

    target.value().free(rt);
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCount());

    try std.testing.expectEqual(@as(usize, 1), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
    try std.testing.expect(weak.get().isUndefined());
    try std.testing.expectEqual(@as(usize, 1), clear_count);
}

test "weak persistent value clears unrooted symbol target during gc" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("weak-persistent-symbol");
    var clear_count: usize = 0;
    var weak = try rt.createWeakPersistentValue(core.JSValue.symbol(symbol_atom), weakPersistentCounterCallback, &clear_count);
    defer weak.deinit();

    try std.testing.expect(weak.isAlive());
    try std.testing.expect(weak.get().same(core.JSValue.symbol(symbol_atom)));

    _ = rt.runObjectCycleRemoval();

    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
    try std.testing.expect(!weak.isAlive());
    try std.testing.expect(weak.get().isUndefined());
    try std.testing.expectEqual(@as(usize, 1), clear_count);
}

test "function home object cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const home = try core.Object.create(rt, core.class.ids.object, null);
    const function = try core.Object.create(rt, core.class.ids.c_function, null);
    const method_key = try rt.internAtom("method");
    defer rt.atoms.free(method_key);

    try function.setFunctionHomeObject(rt, home);
    try home.defineOwnProperty(rt, method_key, core.Descriptor.data(function.value(), true, true, true));

    home.value().free(rt);
    function.value().free(rt);
    try std.testing.expectEqual(@as(usize, 2), rt.runObjectCycleRemoval());
}

test "async continuation function cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const continuation = try core.Object.create(rt, core.class.ids.c_function, null);
    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    const key = try rt.internAtom("continuation");
    defer rt.atoms.free(key);

    continuation.functionAsyncContinuationSlot().* = promise.value().dup();
    try promise.defineOwnProperty(rt, key, core.Descriptor.data(continuation.value(), true, true, true));

    continuation.value().free(rt);
    promise.value().free(rt);
    try std.testing.expectEqual(@as(usize, 2), rt.runObjectCycleRemoval());
}

test "async generator promise cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const generator = try core.Object.create(rt, core.class.ids.async_generator, null);
    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    const key = try rt.internAtom("generator");
    defer rt.atoms.free(key);

    generator.generatorAsyncPromiseSlot().* = promise.value().dup();
    try promise.defineOwnProperty(rt, key, core.Descriptor.data(generator.value(), true, true, true));

    generator.value().free(rt);
    promise.value().free(rt);
    try std.testing.expectEqual(@as(usize, 2), rt.runObjectCycleRemoval());
}

test "shared lazy native function cache cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    const cached_key = try rt.internAtom("cached");
    defer rt.atoms.free(cached_key);
    const global_key = try rt.internAtom("global");
    defer rt.atoms.free(global_key);

    try global.defineAutoInitPropertyWithRealmNativeAndCache(
        rt,
        cached_key,
        "cached",
        0,
        core.property.Flags.data(true, false, true),
        global,
        0,
        1,
    );

    const cached_value = global.getProperty(cached_key);
    const cached_function: *core.Object = @fieldParentPtr("header", cached_value.refHeader().?);
    try cached_function.defineOwnProperty(rt, global_key, core.Descriptor.data(global.value(), true, true, true));

    cached_value.free(rt);
    global.value().free(rt);

    try std.testing.expectEqual(@as(usize, 2), rt.runObjectCycleRemoval());
}

test "function bytecode constant object cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("fn");
    defer rt.atoms.free(name);
    const function = try core.Object.create(rt, core.class.ids.bytecode_function, null);
    const captured = try core.Object.create(rt, core.class.ids.object, null);
    const function_key = try rt.internAtom("function");
    defer rt.atoms.free(function_key);

    const fb_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, name);
    try rt.gc.add(&fb.header);
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = captured.value().dup();
    fb.cpool_count = 1;

    function.functionBytecodeSlot().* = core.JSValue.functionBytecode(&fb.header);
    try captured.defineOwnProperty(rt, function_key, core.Descriptor.data(function.value(), true, true, true));

    function.value().free(rt);
    captured.value().free(rt);

    try std.testing.expectEqual(@as(usize, 2), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "runtime destroy releases callback bytecode before object registries" {
    const rt = try core.JSRuntime.create(std.testing.allocator);

    const captured = try core.Object.create(rt, core.class.ids.object, null);

    const fb_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = captured.value().dup();
    fb.cpool_count = 1;

    captured.value().free(rt);

    rt.destroy();
}

test "runtime destroy releases nested callback bytecode in owner order" {
    const rt = try core.JSRuntime.create(std.testing.allocator);

    const child_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const child = &child_slice[0];
    child.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&child.header);

    const parent_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const parent = &parent_slice[0];
    parent.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&parent.header);
    parent.cpool = try rt.memory.alloc(core.JSValue, 1);
    parent.cpool[0] = core.JSValue.functionBytecode(&child.header);
    parent.cpool_count = 1;

    rt.destroy();
}

test "runtime destroy revisits callback bytecode after parent release" {
    const rt = try core.JSRuntime.create(std.testing.allocator);

    const child_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const child = &child_slice[0];
    child.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&child.header);

    const parent_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const parent = &parent_slice[0];
    parent.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&parent.header);
    parent.cpool = try rt.memory.alloc(core.JSValue, 1);
    parent.cpool[0] = core.JSValue.functionBytecode(&child.header).dup();
    parent.cpool_count = 1;

    rt.destroy();
}

test "runtime destroy releases cyclic callback bytecode constants" {
    const rt = try core.JSRuntime.create(std.testing.allocator);

    const left_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const left = &left_slice[0];
    left.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&left.header);

    const right_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const right = &right_slice[0];
    right.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&right.header);

    left.cpool = try rt.memory.alloc(core.JSValue, 1);
    left.cpool[0] = core.JSValue.functionBytecode(&right.header).dup();
    left.cpool_count = 1;
    right.cpool = try rt.memory.alloc(core.JSValue, 1);
    right.cpool[0] = core.JSValue.functionBytecode(&left.header).dup();
    right.cpool_count = 1;

    rt.destroy();
}

test "runtime destroy releases callback bytecode constants with transferred ownership" {
    const rt = try core.JSRuntime.create(std.testing.allocator);

    const left_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const left = &left_slice[0];
    left.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&left.header);

    const right_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const right = &right_slice[0];
    right.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&right.header);

    left.cpool = try rt.memory.alloc(core.JSValue, 1);
    left.cpool[0] = core.JSValue.functionBytecode(&right.header);
    left.cpool_count = 1;
    right.cpool = try rt.memory.alloc(core.JSValue, 1);
    right.cpool[0] = core.JSValue.functionBytecode(&left.header);
    right.cpool_count = 1;

    rt.destroy();
}

test "runtime destroy releases callback bytecode class fields init with transferred ownership" {
    const rt = try core.JSRuntime.create(std.testing.allocator);

    const left_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const left = &left_slice[0];
    left.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&left.header);

    const right_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const right = &right_slice[0];
    right.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&right.header);

    left.class_fields_init = core.JSValue.functionBytecode(&right.header);
    right.class_fields_init = core.JSValue.functionBytecode(&left.header);

    rt.destroy();
}

test "bytecode-only callback constant cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const left_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const left = &left_slice[0];
    left.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&left.header);

    const right_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const right = &right_slice[0];
    right.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&right.header);

    left.cpool = try rt.memory.alloc(core.JSValue, 1);
    left.cpool[0] = core.JSValue.functionBytecode(&right.header);
    left.cpool_count = 1;
    right.cpool = try rt.memory.alloc(core.JSValue, 1);
    right.cpool[0] = core.JSValue.functionBytecode(&left.header);
    right.cpool_count = 1;

    try std.testing.expectEqual(@as(usize, 0), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "bytecode-only class fields init cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const left_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const left = &left_slice[0];
    left.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&left.header);

    const right_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const right = &right_slice[0];
    right.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&right.header);

    left.class_fields_init = core.JSValue.functionBytecode(&right.header);
    right.class_fields_init = core.JSValue.functionBytecode(&left.header);

    try std.testing.expectEqual(@as(usize, 0), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "shared function bytecode constant object cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("sharedFn");
    defer rt.atoms.free(name);
    const first = try core.Object.create(rt, core.class.ids.bytecode_function, null);
    const second = try core.Object.create(rt, core.class.ids.bytecode_function, null);
    const captured = try core.Object.create(rt, core.class.ids.object, null);
    const first_key = try rt.internAtom("first");
    defer rt.atoms.free(first_key);
    const second_key = try rt.internAtom("second");
    defer rt.atoms.free(second_key);

    const fb_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, name);
    try rt.gc.add(&fb.header);
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = captured.value().dup();
    fb.cpool_count = 1;

    const bytecode_value = core.JSValue.functionBytecode(&fb.header);
    first.functionBytecodeSlot().* = bytecode_value;
    second.functionBytecodeSlot().* = bytecode_value.dup();
    try captured.defineOwnProperty(rt, first_key, core.Descriptor.data(first.value(), true, true, true));
    try captured.defineOwnProperty(rt, second_key, core.Descriptor.data(second.value(), true, true, true));

    first.value().free(rt);
    second.value().free(rt);
    captured.value().free(rt);

    try std.testing.expectEqual(@as(usize, 3), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "nested function bytecode constant object cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const outer_name = try rt.internAtom("outerFn");
    defer rt.atoms.free(outer_name);
    const inner_name = try rt.internAtom("innerFn");
    defer rt.atoms.free(inner_name);
    const function = try core.Object.create(rt, core.class.ids.bytecode_function, null);
    const captured = try core.Object.create(rt, core.class.ids.object, null);
    const function_key = try rt.internAtom("function");
    defer rt.atoms.free(function_key);

    const outer_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const outer = &outer_slice[0];
    outer.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, outer_name);
    try rt.gc.add(&outer.header);

    const inner_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const inner = &inner_slice[0];
    inner.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, inner_name);
    try rt.gc.add(&inner.header);

    outer.cpool = try rt.memory.alloc(core.JSValue, 1);
    outer.cpool[0] = core.JSValue.functionBytecode(&inner.header);
    outer.cpool_count = 1;
    inner.cpool = try rt.memory.alloc(core.JSValue, 1);
    inner.cpool[0] = captured.value().dup();
    inner.cpool_count = 1;

    function.functionBytecodeSlot().* = core.JSValue.functionBytecode(&outer.header);
    try captured.defineOwnProperty(rt, function_key, core.Descriptor.data(function.value(), true, true, true));

    function.value().free(rt);
    captured.value().free(rt);

    try std.testing.expectEqual(@as(usize, 2), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "cyclic internal function bytecode references are released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const outer_name = try rt.internAtom("outerCycleFn");
    defer rt.atoms.free(outer_name);
    const inner_name = try rt.internAtom("innerCycleFn");
    defer rt.atoms.free(inner_name);
    const function = try core.Object.create(rt, core.class.ids.bytecode_function, null);
    const captured = try core.Object.create(rt, core.class.ids.object, null);
    const function_key = try rt.internAtom("function");
    defer rt.atoms.free(function_key);

    const outer_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const outer = &outer_slice[0];
    outer.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, outer_name);
    try rt.gc.add(&outer.header);

    const inner_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const inner = &inner_slice[0];
    inner.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, inner_name);
    try rt.gc.add(&inner.header);

    outer.cpool = try rt.memory.alloc(core.JSValue, 1);
    outer.cpool[0] = core.JSValue.functionBytecode(&inner.header);
    outer.cpool_count = 1;
    inner.cpool = try rt.memory.alloc(core.JSValue, 2);
    inner.cpool[0] = core.JSValue.functionBytecode(&outer.header).dup();
    inner.cpool[1] = captured.value().dup();
    inner.cpool_count = 2;

    function.functionBytecodeSlot().* = core.JSValue.functionBytecode(&outer.header);
    try captured.defineOwnProperty(rt, function_key, core.Descriptor.data(function.value(), true, true, true));

    function.value().free(rt);
    captured.value().free(rt);

    try std.testing.expectEqual(@as(usize, 2), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "class payload function bytecode constant object cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const external_id = rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(external_id, .{
        .class_name = "ExternalPayloadBytecodeCycle",
        .payload_finalizer = finalizeTestExternalPayload,
        .payload_mark = markTestExternalPayload,
    });

    const name = try rt.internAtom("payloadFn");
    defer rt.atoms.free(name);
    const external = try core.Object.create(rt, external_id, null);
    const captured = try core.Object.create(rt, core.class.ids.object, null);
    const external_key = try rt.internAtom("external");
    defer rt.atoms.free(external_key);

    const fb_slice = try rt.memory.alloc(engine.bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = engine.bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, name);
    try rt.gc.add(&fb.header);
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = captured.value().dup();
    fb.cpool_count = 1;

    const payload = try rt.memory.create(TestExternalPayload);
    payload.* = .{ .value = core.JSValue.functionBytecode(&fb.header) };
    external.class_payload = .{ .external = @ptrCast(payload) };
    try captured.defineOwnProperty(rt, external_key, core.Descriptor.data(external.value(), true, true, true));

    payload_finalizer_calls = 0;
    payload_mark_calls = 0;
    external.value().free(rt);
    captured.value().free(rt);

    try std.testing.expectEqual(@as(usize, 2), rt.runObjectCycleRemoval());
    try std.testing.expect(payload_mark_calls > 0);
    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);
    try expectOneDeferredClassPayloadFinalizer(rt);
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "realm cached prototypes are strong cycle-collected references" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    const function_proto = try core.Object.create(rt, core.class.ids.object, null);
    const promise_proto = try core.Object.create(rt, core.class.ids.object, null);
    const global_key = try rt.internAtom("global");
    defer rt.atoms.free(global_key);

    try global.setCachedFunctionProto(rt, function_proto);
    try global.setCachedPromiseProto(rt, promise_proto);
    try function_proto.defineOwnProperty(rt, global_key, core.Descriptor.data(global.value(), true, true, true));
    try promise_proto.defineOwnProperty(rt, global_key, core.Descriptor.data(global.value(), true, true, true));

    try std.testing.expectEqual(@as(i32, 3), global.header.rc);
    try std.testing.expectEqual(@as(i32, 2), function_proto.header.rc);
    try std.testing.expectEqual(@as(i32, 2), promise_proto.header.rc);

    global.value().free(rt);
    function_proto.value().free(rt);
    promise_proto.value().free(rt);

    try std.testing.expectEqual(@as(usize, 3), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "destroyed realm global clears borrowed realm pointers and auto init metadata" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    global.flags.is_global = true;
    const holder = try core.Object.create(rt, core.class.ids.object, null);
    const lazy_key = try rt.internAtom("lazy");
    defer rt.atoms.free(lazy_key);

    try holder.setFunctionRealmGlobalPtr(rt, global);
    try holder.defineAutoInitPropertyWithRealmNativeAndCache(
        rt,
        lazy_key,
        "lazy",
        0,
        core.property.Flags.data(true, false, true),
        global,
        0,
        1,
    );

    try std.testing.expectEqual(global, holder.functionRealmGlobalPtr().?);
    try std.testing.expectEqual(@intFromPtr(global), holder.properties[0].slot.auto_init.host_function_realm_global);

    global.value().free(rt);

    try std.testing.expectEqual(@as(?*core.Object, null), holder.functionRealmGlobalPtr());
    try std.testing.expectEqual(@as(usize, 0), holder.properties[0].slot.auto_init.host_function_realm_global);
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);

    const lazy = holder.getProperty(lazy_key);
    defer lazy.free(rt);
    try std.testing.expect(lazy.isObject());

    holder.value().free(rt);
    try std.testing.expectEqual(@as(usize, 0), rt.runObjectCycleRemoval());
}

test "cleared realm pointer unregisters empty borrowed holder" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    global.flags.is_global = true;
    const holder = try core.Object.create(rt, core.class.ids.object, null);
    defer holder.value().free(rt);

    try holder.setFunctionRealmGlobalPtr(rt, global);
    try std.testing.expectEqual(@as(usize, 1), rt.borrowed_reference_holders.len);

    try holder.setFunctionRealmGlobalPtr(rt, null);
    try std.testing.expectEqual(@as(?*core.Object, null), holder.functionRealmGlobalPtr());
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);
}

test "replaced realm auto-init unregisters empty borrowed holder" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    global.flags.is_global = true;
    const holder = try core.Object.create(rt, core.class.ids.object, null);
    defer holder.value().free(rt);
    const key = try rt.internAtom("lazy_replace_realm");
    defer rt.atoms.free(key);

    try holder.defineAutoInitPropertyWithRealmNativeAndCache(
        rt,
        key,
        "lazy_replace_realm",
        0,
        core.property.Flags.data(true, false, true),
        global,
        0,
        0,
    );
    try std.testing.expectEqual(@as(usize, 1), rt.borrowed_reference_holders.len);
    try std.testing.expectEqual(@intFromPtr(global), holder.properties[0].slot.auto_init.host_function_realm_global);

    try holder.replaceAutoInitPropertyWithRealmNativeAndCache(
        rt,
        key,
        "lazy_replace_realm",
        0,
        core.property.Flags.data(true, false, true),
        null,
        0,
        0,
    );

    try std.testing.expectEqual(@as(usize, 0), holder.properties[0].slot.auto_init.host_function_realm_global);
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);
}

test "deleted realm auto-init unregisters empty borrowed holder" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    global.flags.is_global = true;
    const holder = try core.Object.create(rt, core.class.ids.object, null);
    defer holder.value().free(rt);
    const key = try rt.internAtom("lazy_delete_realm");
    defer rt.atoms.free(key);

    try holder.definePerformanceAutoInitProperty(rt, key, core.property.Flags.data(true, false, true), global);
    try std.testing.expectEqual(@as(usize, 1), rt.borrowed_reference_holders.len);

    try std.testing.expect(holder.deleteProperty(rt, key));
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);
}

test "ordinary replacement of realm auto-init unregisters empty borrowed holder" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    global.flags.is_global = true;
    const holder = try core.Object.create(rt, core.class.ids.object, null);
    defer holder.value().free(rt);
    const define_key = try rt.internAtom("lazy_define_realm");
    defer rt.atoms.free(define_key);
    const set_key = try rt.internAtom("lazy_set_realm");
    defer rt.atoms.free(set_key);
    const own_set_key = try rt.internAtom("lazy_own_set_realm");
    defer rt.atoms.free(own_set_key);
    const simple_set_key = try rt.internAtom("lazy_simple_set_realm");
    defer rt.atoms.free(simple_set_key);

    try holder.definePerformanceAutoInitProperty(rt, define_key, core.property.Flags.data(true, false, true), global);
    try std.testing.expectEqual(@as(usize, 1), rt.borrowed_reference_holders.len);

    try holder.defineOwnProperty(rt, define_key, core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);

    try holder.definePerformanceAutoInitProperty(rt, set_key, core.property.Flags.data(true, false, true), global);
    try std.testing.expectEqual(@as(usize, 1), rt.borrowed_reference_holders.len);

    try holder.setProperty(rt, set_key, core.JSValue.int32(2));
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);

    try holder.definePerformanceAutoInitProperty(rt, own_set_key, core.property.Flags.data(true, false, true), global);
    try std.testing.expectEqual(@as(usize, 1), rt.borrowed_reference_holders.len);

    try std.testing.expect(try holder.setOwnWritableDataProperty(rt, own_set_key, core.JSValue.int32(3)));
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);

    try holder.definePerformanceAutoInitProperty(rt, simple_set_key, core.property.Flags.data(true, false, true), global);
    try std.testing.expectEqual(@as(usize, 1), rt.borrowed_reference_holders.len);

    try std.testing.expect(try holder.setOrDefineOwnDataPropertyForSimpleSet(rt, simple_set_key, core.JSValue.int32(4)));
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);
}

test "specialized auto-init realm metadata registers borrowed holders" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    global.flags.is_global = true;

    const navigator_holder = try core.Object.create(rt, core.class.ids.object, null);
    defer navigator_holder.value().free(rt);
    const performance_holder = try core.Object.create(rt, core.class.ids.object, null);
    defer performance_holder.value().free(rt);
    const namespace_holder = try core.Object.create(rt, core.class.ids.object, null);
    defer namespace_holder.value().free(rt);
    const host_holder = try core.Object.create(rt, core.class.ids.object, null);
    defer host_holder.value().free(rt);
    const replace_holder = try core.Object.create(rt, core.class.ids.object, null);
    defer replace_holder.value().free(rt);

    const navigator_key = try rt.internAtom("navigator");
    defer rt.atoms.free(navigator_key);
    const performance_key = try rt.internAtom("performance");
    defer rt.atoms.free(performance_key);
    const namespace_key = try rt.internAtom("Math");
    defer rt.atoms.free(namespace_key);
    const host_key = try rt.internAtom("gc");
    defer rt.atoms.free(host_key);
    const replace_key = try rt.internAtom("replace");
    defer rt.atoms.free(replace_key);

    const flags = core.property.Flags.data(true, false, true);
    try navigator_holder.defineNavigatorAutoInitProperty(rt, navigator_key, flags, global);
    try performance_holder.definePerformanceAutoInitProperty(rt, performance_key, flags, global);
    try namespace_holder.defineBuiltinNamespaceAutoInitProperty(rt, namespace_key, "Math", flags, global, .math_namespace);
    try host_holder.defineHostAutoInitProperty(rt, host_key, "gc", 0, flags, core.host_function.ids.output, false, global);
    try replace_holder.defineAutoInitProperty(rt, replace_key, "replace", 0, flags);
    try replace_holder.replaceAutoInitPropertyWithRealmNativeAndCache(rt, replace_key, "replace", 0, flags, global, 0, 0);

    const holders = [_]*core.Object{
        navigator_holder,
        performance_holder,
        namespace_holder,
        host_holder,
        replace_holder,
    };
    for (holders) |holder| {
        try std.testing.expectEqual(@intFromPtr(global), holder.properties[0].slot.auto_init.host_function_realm_global);
    }

    global.value().free(rt);

    for (holders) |holder| {
        try std.testing.expectEqual(@as(usize, 0), holder.properties[0].slot.auto_init.host_function_realm_global);
    }
}

test "materialized auto-init function realm pointer registers borrowed holder" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    global.flags.is_global = true;
    const holder = try core.Object.create(rt, core.class.ids.object, null);
    defer holder.value().free(rt);
    const host_key = try rt.internAtom("gc");
    defer rt.atoms.free(host_key);

    try holder.defineHostAutoInitProperty(
        rt,
        host_key,
        "gc",
        0,
        core.property.Flags.data(true, false, true),
        core.host_function.ids.output,
        false,
        global,
    );

    const function_value = holder.getProperty(host_key);
    defer function_value.free(rt);
    const function_header = function_value.refHeader().?;
    const function_object: *core.Object = @fieldParentPtr("header", function_header);

    try std.testing.expectEqual(global, function_object.functionRealmGlobalPtr().?);

    global.value().free(rt);

    try std.testing.expectEqual(@as(?*core.Object, null), function_object.functionRealmGlobalPtr());
}

test "dead weak collection key entry is swept when target is destroyed" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const weakmap = try core.Object.create(rt, core.class.ids.weakmap, null);
    defer weakmap.value().free(rt);
    const key = try core.Object.create(rt, core.class.ids.object, null);
    const value = try core.Object.create(rt, core.class.ids.object, null);

    try appendWeakCollectionEntry(rt, weakmap, key, value.value());

    key.value().free(rt);
    try std.testing.expectEqual(@as(usize, 0), weakmap.weakCollectionEntries().len);
    try std.testing.expectEqual(@as(i32, 1), value.header.rc);

    value.value().free(rt);

    try std.testing.expectEqual(@as(usize, 0), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 0), weakmap.weakCollectionEntries().len);
}

test "dead weak collection key entry is swept without freeing live value" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const weakmap = try core.Object.create(rt, core.class.ids.weakmap, null);
    defer weakmap.value().free(rt);
    const key = try core.Object.create(rt, core.class.ids.object, null);
    const value = try core.Object.create(rt, core.class.ids.object, null);
    defer value.value().free(rt);

    try appendWeakCollectionEntry(rt, weakmap, key, value.value());

    key.value().free(rt);

    try std.testing.expectEqual(@as(usize, 0), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 0), weakmap.weakCollectionEntries().len);
    try std.testing.expectEqual(@as(i32, 1), value.header.rc);
}

test "live weak collection key preserves stored value" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const weakmap = try core.Object.create(rt, core.class.ids.weakmap, null);
    const key = try core.Object.create(rt, core.class.ids.object, null);
    const value = try core.Object.create(rt, core.class.ids.object, null);

    try appendWeakCollectionEntry(rt, weakmap, key, value.value());
    value.value().free(rt);

    try std.testing.expectEqual(@as(usize, 0), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 1), weakmap.weakCollectionEntries().len);
    try std.testing.expectEqual(&value.header, weakmap.weakCollectionEntries()[0].value.refHeader().?);

    weakmap.value().free(rt);
    key.value().free(rt);
}

test "weak ref target identity does not retain object target" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const weak_ref = try core.Object.create(rt, core.class.ids.weak_ref, null);
    defer weak_ref.value().free(rt);
    const target = try core.Object.create(rt, core.class.ids.object, null);

    try weak_ref.setWeakRefTarget(rt, target.value());

    {
        const live = weak_ref.weakRefDeref(rt);
        defer live.free(rt);
        try std.testing.expectEqual(&target.header, live.refHeader().?);
    }

    target.value().free(rt);
    try std.testing.expect(weak_ref.weakRefDeref(rt).isUndefined());
}

test "weak ref target registration roots direct symbol target" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const weak_ref = try core.Object.create(rt, core.class.ids.weak_ref, null);
    defer weak_ref.value().free(rt);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-weak-ref-target-symbol");
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try weak_ref.setWeakRefTarget(rt, core.JSValue.symbol(symbol_atom));

    const live = weak_ref.weakRefDeref(rt);
    try std.testing.expect(live.same(core.JSValue.symbol(symbol_atom)));
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
    try std.testing.expect(weak_ref.weakRefDeref(rt).isUndefined());
}

test "weak ref target registration failure leaves target unset" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const weak_ref = try core.Object.create(rt, core.class.ids.weak_ref, null);
    defer weak_ref.value().free(rt);
    const target = try core.Object.create(rt, core.class.ids.object, null);
    defer target.value().free(rt);

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, weak_ref.setWeakRefTarget(rt, target.value()));
    rt.setMemoryLimit(null);

    try std.testing.expect(weak_ref.weakRefDeref(rt).isUndefined());
}

test "weak collection capacity failure leaves empty holder unregistered" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const weakmap = try core.Object.create(rt, core.class.ids.weakmap, null);
    defer weakmap.value().free(rt);

    const old_holder_count = rt.borrowed_reference_holders.len;
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, weakmap.ensureWeakCollectionEntryCapacity(rt, 1));
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(old_holder_count, rt.borrowed_reference_holders.len);
    try std.testing.expectEqual(@as(usize, 0), weakmap.weakCollectionEntries().len);
}

test "weak collection append failure rolls back borrowed holder registration" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const weakmap = try core.Object.create(rt, core.class.ids.weakmap, null);
    defer weakmap.value().free(rt);
    const key = try core.Object.create(rt, core.class.ids.object, null);
    defer key.value().free(rt);
    const value = try core.Object.create(rt, core.class.ids.object, null);
    defer value.value().free(rt);

    const old_holder_count = rt.borrowed_reference_holders.len;
    rt.setMemoryLimit(rt.memory.allocated_bytes + borrowedHolderInitialAllocationBytes());
    try std.testing.expectError(error.OutOfMemory, appendWeakCollectionEntry(rt, weakmap, key, value.value()));
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(old_holder_count, rt.borrowed_reference_holders.len);
    try std.testing.expectEqual(@as(usize, 0), weakmap.weakCollectionEntries().len);
}

test "weak collection capacity reservation keeps empty holder unregistered" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const weakmap = try core.Object.create(rt, core.class.ids.weakmap, null);
    defer weakmap.value().free(rt);

    try weakmap.ensureWeakCollectionEntryCapacity(rt, 1);

    try std.testing.expectEqual(@as(usize, 0), weakmap.weakCollectionEntries().len);
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);
}

test "finalization registry capacity failure leaves empty holder unregistered" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const registry = try core.Object.create(rt, core.class.ids.finalization_registry, null);
    defer registry.value().free(rt);

    const old_holder_count = rt.borrowed_reference_holders.len;
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, registry.ensureFinalizationRegistryCellCapacity(rt, 1));
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(old_holder_count, rt.borrowed_reference_holders.len);
    try std.testing.expectEqual(@as(usize, 0), registry.finalizationRegistryCells().len);
}

test "finalization registry append failure rolls back borrowed holder registration" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const registry = try core.Object.create(rt, core.class.ids.finalization_registry, null);
    defer registry.value().free(rt);
    const target = try core.Object.create(rt, core.class.ids.object, null);
    defer target.value().free(rt);

    const old_holder_count = rt.borrowed_reference_holders.len;
    rt.setMemoryLimit(rt.memory.allocated_bytes + borrowedHolderInitialAllocationBytes());
    try std.testing.expectError(
        error.OutOfMemory,
        appendFinalizationRegistryCell(rt, registry, target.value(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue()),
    );
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(old_holder_count, rt.borrowed_reference_holders.len);
    try std.testing.expectEqual(@as(usize, 0), registry.finalizationRegistryCells().len);
}

test "finalization registry capacity reservation keeps empty holder unregistered" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const registry = try core.Object.create(rt, core.class.ids.finalization_registry, null);
    defer registry.value().free(rt);

    try registry.ensureFinalizationRegistryCellCapacity(rt, 1);

    try std.testing.expectEqual(@as(usize, 0), registry.finalizationRegistryCells().len);
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);
}

test "weak collection delete and clear unregister empty borrowed holder" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const weakmap = try core.Object.create(rt, core.class.ids.weakmap, null);
    defer weakmap.value().free(rt);
    const map_key = try core.Object.create(rt, core.class.ids.object, null);
    defer map_key.value().free(rt);

    const set_result = try engine.builtins.collection.methodCall(rt, weakmap.value(), 1, &.{ map_key.value(), core.JSValue.int32(1) });
    set_result.free(rt);
    try std.testing.expectEqual(@as(usize, 1), rt.borrowed_reference_holders.len);

    const delete_result = try engine.builtins.collection.methodCall(rt, weakmap.value(), 4, &.{map_key.value()});
    defer delete_result.free(rt);
    try std.testing.expectEqual(@as(?bool, true), delete_result.asBool());
    try std.testing.expectEqual(@as(usize, 0), weakmap.weakCollectionEntries().len);
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);

    const weakset = try core.Object.create(rt, core.class.ids.weakset, null);
    defer weakset.value().free(rt);
    const set_key = try core.Object.create(rt, core.class.ids.object, null);
    defer set_key.value().free(rt);

    const add_result = try engine.builtins.collection.methodCall(rt, weakset.value(), 6, &.{set_key.value()});
    add_result.free(rt);
    try std.testing.expectEqual(@as(usize, 1), rt.borrowed_reference_holders.len);

    const clear_result = try engine.builtins.collection.methodCall(rt, weakset.value(), 5, &.{});
    defer clear_result.free(rt);
    try std.testing.expect(clear_result.isUndefined());
    try std.testing.expectEqual(@as(usize, 0), weakset.weakCollectionEntries().len);
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);
}

test "finalization registry unregister unregisters empty borrowed holder" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const registry = try core.Object.create(rt, core.class.ids.finalization_registry, null);
    defer registry.value().free(rt);
    const target = try core.Object.create(rt, core.class.ids.object, null);
    defer target.value().free(rt);
    const token = try core.Object.create(rt, core.class.ids.object, null);
    defer token.value().free(rt);

    try appendFinalizationRegistryCell(rt, registry, target.value(), core.JSValue.undefinedValue(), token.value());
    try std.testing.expectEqual(@as(usize, 1), registry.finalizationRegistryCells().len);
    try std.testing.expectEqual(@as(usize, 1), rt.borrowed_reference_holders.len);

    try std.testing.expect(registry.unregisterFinalizationRegistryCells(rt, token.value()));
    try std.testing.expectEqual(@as(usize, 0), registry.finalizationRegistryCells().len);
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);
}

test "finalization registry unregister tolerates token cleanup reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const registry = try core.Object.create(rt, core.class.ids.finalization_registry, null);
    defer registry.value().free(rt);
    const target_and_token = try core.Object.create(rt, core.class.ids.object, null);

    try appendFinalizationRegistryCell(
        rt,
        registry,
        target_and_token.value(),
        core.JSValue.undefinedValue(),
        target_and_token.value(),
    );
    target_and_token.value().free(rt);

    try std.testing.expect(registry.unregisterFinalizationRegistryCells(rt, target_and_token.value()));
    try std.testing.expectEqual(@as(usize, 0), registry.finalizationRegistryCells().len);
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);
}

test "finalization registry dead target cleanup tolerates held value reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const registry = try core.Object.create(rt, core.class.ids.finalization_registry, null);
    defer registry.value().free(rt);
    const first_target = try core.Object.create(rt, core.class.ids.object, null);
    const held_and_second_target = try core.Object.create(rt, core.class.ids.object, null);

    try appendFinalizationRegistryCell(
        rt,
        registry,
        first_target.value(),
        held_and_second_target.value(),
        core.JSValue.undefinedValue(),
    );
    try appendFinalizationRegistryCell(
        rt,
        registry,
        held_and_second_target.value(),
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
    );
    held_and_second_target.value().free(rt);

    first_target.value().free(rt);

    try std.testing.expectEqual(@as(usize, 0), registry.finalizationRegistryCells().len);
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);
}

test "weak collection delete tolerates value cleanup reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const weakmap = try core.Object.create(rt, core.class.ids.weakmap, null);
    defer weakmap.value().free(rt);
    const key = try core.Object.create(rt, core.class.ids.object, null);

    try appendWeakCollectionEntry(rt, weakmap, key, key.value());
    key.value().free(rt);

    const delete_result = try engine.builtins.collection.methodCall(rt, weakmap.value(), 4, &.{key.value()});
    defer delete_result.free(rt);

    try std.testing.expectEqual(@as(?bool, true), delete_result.asBool());
    try std.testing.expectEqual(@as(usize, 0), weakmap.weakCollectionEntries().len);
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);
}

test "weak collection clear tolerates value cleanup reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const weakmap = try core.Object.create(rt, core.class.ids.weakmap, null);
    defer weakmap.value().free(rt);
    const first_key = try core.Object.create(rt, core.class.ids.object, null);
    defer first_key.value().free(rt);
    const middle = try core.Object.create(rt, core.class.ids.object, null);
    const tail = try core.Object.create(rt, core.class.ids.object, null);

    try appendWeakCollectionEntry(rt, weakmap, first_key, middle.value());
    try appendWeakCollectionEntry(rt, weakmap, middle, tail.value());
    middle.value().free(rt);
    tail.value().free(rt);

    const clear_result = try engine.builtins.collection.methodCall(rt, weakmap.value(), 5, &.{});
    defer clear_result.free(rt);

    try std.testing.expect(clear_result.isUndefined());
    try std.testing.expectEqual(@as(usize, 0), weakmap.weakCollectionEntries().len);
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);
}

test "weak map deep value chain releases without recursive destruction" {
    const rt = try core.JSRuntime.createWithOptions(std.testing.allocator, .{
        .gc_threshold = 256 * 1024 * 1024,
    });
    defer rt.destroy();

    const map = try core.Object.create(rt, core.class.ids.weakmap, null);
    defer map.value().free(rt);
    const head = try core.Object.create(rt, core.class.ids.object, null);

    var key = head;
    for (0..5_000) |_| {
        const next = try core.Object.create(rt, core.class.ids.object, null);
        try appendWeakCollectionEntry(rt, map, key, next.value());
        next.value().free(rt);
        key = next;
    }

    head.value().free(rt);
    try std.testing.expectEqual(@as(usize, 0), map.weakCollectionEntries().len);
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCount());
}

test "weak map cycle sweep clears index after removing dead keys" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const map = try core.Object.create(rt, core.class.ids.weakmap, null);
    defer map.value().free(rt);

    const self_key = try rt.internAtom("self");
    defer rt.atoms.free(self_key);

    var keys: [8]*core.Object = undefined;
    var key_count: usize = 0;
    var first_key_released = false;
    defer {
        var index = key_count;
        while (index != 0) {
            index -= 1;
            if (index == 0 and first_key_released) continue;
            keys[index].value().free(rt);
        }
    }

    for (&keys, 0..) |*slot, index| {
        const key = try core.Object.create(rt, core.class.ids.object, null);
        slot.* = key;
        key_count += 1;
        if (index == 0) {
            try key.defineOwnProperty(rt, self_key, core.Descriptor.data(key.value(), true, true, true));
        }
        const result = try engine.builtins.collection.methodCall(rt, map.value(), 1, &.{ key.value(), core.JSValue.int32(@intCast(index)) });
        result.free(rt);
    }
    try std.testing.expectEqual(@as(usize, 8), map.weakCollectionEntries().len);
    try std.testing.expectEqual(@as(usize, 8), rt.gcStats().weak_ref_count);
    try std.testing.expect(map.collectionBucketHeads().len != 0);

    keys[0].value().free(rt);
    first_key_released = true;
    try std.testing.expectEqual(@as(usize, 1), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 7), map.weakCollectionEntries().len);
    try std.testing.expectEqual(@as(usize, 7), rt.gcStats().weak_ref_count);
    try std.testing.expectEqual(@as(usize, 0), map.collectionBucketHeads().len);

    var index: usize = 1;
    while (index < key_count) : (index += 1) {
        const value = try engine.builtins.collection.methodCall(rt, map.value(), 2, &.{keys[index].value()});
        defer value.free(rt);
        try std.testing.expectEqual(@as(?i32, @intCast(index)), value.asInt32());
    }
}

test "finalization registry dead target releases held value when target is destroyed" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const registry = try core.Object.create(rt, core.class.ids.finalization_registry, null);
    defer registry.value().free(rt);
    const target = try core.Object.create(rt, core.class.ids.object, null);
    const held = try core.Object.create(rt, core.class.ids.object, null);

    try appendFinalizationRegistryCell(rt, registry, target.value(), held.value(), core.JSValue.undefinedValue());

    target.value().free(rt);
    try std.testing.expectEqual(@as(usize, 0), registry.finalizationRegistryCells().len);
    try std.testing.expectEqual(@as(i32, 1), held.header.rc);

    held.value().free(rt);

    try std.testing.expectEqual(@as(usize, 0), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 0), registry.finalizationRegistryCells().len);
}

test "finalization registry live target preserves held value" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const registry = try core.Object.create(rt, core.class.ids.finalization_registry, null);
    const target = try core.Object.create(rt, core.class.ids.object, null);
    const held = try core.Object.create(rt, core.class.ids.object, null);

    try appendFinalizationRegistryCell(rt, registry, target.value(), held.value(), core.JSValue.undefinedValue());
    held.value().free(rt);

    try std.testing.expectEqual(@as(usize, 0), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 1), registry.finalizationRegistryCells().len);
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().weak_ref_count);
    try std.testing.expectEqual(&held.header, registry.finalizationRegistryCells()[0].held_value.refHeader().?);

    registry.value().free(rt);
    target.value().free(rt);
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().weak_ref_count);
}

test "finalization registry unregister preserves pending cleanup cell" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const cleanup = try core.Object.create(rt, core.class.ids.object, null);
    defer cleanup.value().free(rt);
    const registry = try core.Object.create(rt, core.class.ids.finalization_registry, null);
    registry.finalizationRegistryCleanupCallbackSlot().* = cleanup.value().dup();
    var registry_value = registry.value();
    defer registry_value.free(rt);
    const token = try core.Object.create(rt, core.class.ids.object, null);
    defer token.value().free(rt);

    const target = try core.Object.create(rt, core.class.ids.object, null);
    var target_value = target.value();
    const self_key = try rt.internAtom("gc-finalization-unregister-pending-self");
    defer rt.atoms.free(self_key);
    try target.defineOwnProperty(rt, self_key, core.Descriptor.data(target_value, true, true, true));
    try registry.appendFinalizationRegistryCell(
        rt,
        target_value,
        core.JSValue.int32(5678),
        token.value(),
    );

    _ = try rt.tryRunObjectCycleRemoval();
    target_value.free(rt);
    target_value = core.JSValue.undefinedValue();

    const limit = rt.memory.allocated_bytes;
    rt.setMemoryLimit(limit);
    try std.testing.expectError(error.OutOfMemory, rt.tryRunObjectCycleRemoval());
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(@as(usize, 1), registry.pendingFinalizationCellCountForTest());
    try std.testing.expect(!registry.unregisterFinalizationRegistryCells(rt, token.value()));
    try std.testing.expectEqual(@as(usize, 1), registry.finalizationRegistryCells().len);
    try std.testing.expectEqual(@as(usize, 1), registry.pendingFinalizationCellCountForTest());

    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 1), rt.pendingFinalizationJobCountForTest());
    try std.testing.expectEqual(@as(usize, 0), registry.pendingFinalizationCellCountForTest());

    rt.clearPendingFinalizationJobs();
}

test "object allocation threshold triggers runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const left = try core.Object.create(rt, core.class.ids.object, null);
    const right = try core.Object.create(rt, core.class.ids.object, null);
    const left_key = try rt.internAtom("left");
    defer rt.atoms.free(left_key);
    const right_key = try rt.internAtom("right");
    defer rt.atoms.free(right_key);

    try left.defineOwnProperty(rt, right_key, core.Descriptor.data(right.value(), true, true, true));
    try right.defineOwnProperty(rt, left_key, core.Descriptor.data(left.value(), true, true, true));
    left.value().free(rt);
    right.value().free(rt);

    rt.setGCThreshold(0);
    const survivor = try core.Object.create(rt, core.class.ids.object, null);
    defer survivor.value().free(rt);

    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCount());
    try std.testing.expectEqual(@as(usize, 0), rt.runObjectCycleRemoval());
}

test "gc threshold API resets to surviving allocated bytes plus half" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    try std.testing.expectEqual(core.runtime.default_gc_threshold, rt.gcThreshold());
    rt.setGCThreshold(0);
    try std.testing.expectEqual(@as(usize, 0), rt.gcThreshold());

    const survivor = try core.Object.create(rt, core.class.ids.object, null);
    defer survivor.value().free(rt);

    const expected = rt.memory.allocated_bytes + (rt.memory.allocated_bytes >> 1);
    try std.testing.expectEqual(expected, rt.gcThreshold());
}

test "proxy target handler cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const proxy = try core.Object.create(rt, core.class.ids.proxy, null);
    const target = try core.Object.create(rt, core.class.ids.object, null);
    const key = try rt.internAtom("proxy");
    defer rt.atoms.free(key);

    proxy.proxyTargetSlot().* = target.value().dup();
    proxy.proxyHandlerSlot().* = target.value().dup();
    try target.defineOwnProperty(rt, key, core.Descriptor.data(proxy.value(), true, true, true));

    proxy.value().free(rt);
    target.value().free(rt);
    try std.testing.expectEqual(@as(usize, 2), rt.runObjectCycleRemoval());
}

test "runtime cycle removal preserves externally rooted outgoing objects" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const left = try core.Object.create(rt, core.class.ids.object, null);
    const right = try core.Object.create(rt, core.class.ids.object, null);
    const external = try core.Object.create(rt, core.class.ids.object, null);
    const left_key = try rt.internAtom("left");
    defer rt.atoms.free(left_key);
    const right_key = try rt.internAtom("right");
    defer rt.atoms.free(right_key);
    const external_key = try rt.internAtom("external");
    defer rt.atoms.free(external_key);

    try left.defineOwnProperty(rt, right_key, core.Descriptor.data(right.value(), true, true, true));
    try right.defineOwnProperty(rt, left_key, core.Descriptor.data(left.value(), true, true, true));
    try left.defineOwnProperty(rt, external_key, core.Descriptor.data(external.value(), true, true, true));

    left.value().free(rt);
    right.value().free(rt);
    try std.testing.expectEqual(@as(usize, 2), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(i32, 1), external.header.rc);
    external.value().free(rt);
}

test "module namespace payload cell cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const namespace = try core.Object.create(rt, core.class.ids.module_ns, null);
    const cell = try core.Object.create(rt, core.class.ids.object, null);
    const target = try core.Object.create(rt, core.class.ids.object, null);
    const key = try rt.internAtom("namespace");
    defer rt.atoms.free(key);
    const export_name = try rt.internAtom("value");

    try cell.initVarRefPayload(rt, target.value().dup());
    try target.defineOwnProperty(rt, key, core.Descriptor.data(namespace.value(), true, true, true));

    const payload = namespace.moduleNamespacePayload().?;
    payload.names = try rt.memory.alloc(core.Atom, 1);
    payload.names[0] = export_name;
    const cells = try rt.memory.alloc(core.JSValue, 1);
    cells[0] = cell.value().dup();
    try namespace.setModuleNamespaceCells(rt, cells);

    namespace.value().free(rt);
    cell.value().free(rt);
    target.value().free(rt);
    try std.testing.expectEqual(@as(usize, 3), rt.runObjectCycleRemoval());
}

test "mapped arguments var-ref cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const arguments = try core.Object.create(rt, core.class.ids.mapped_arguments, null);
    const target = try core.Object.create(rt, core.class.ids.object, null);
    const key = try rt.internAtom("arguments");
    defer rt.atoms.free(key);

    const refs = try rt.memory.alloc(core.JSValue, 1);
    refs[0] = target.value().dup();
    arguments.argumentsVarRefsSlot().* = refs;
    try target.defineOwnProperty(rt, key, core.Descriptor.data(arguments.value(), true, true, true));

    arguments.value().free(rt);
    target.value().free(rt);
    try std.testing.expectEqual(@as(usize, 2), rt.runObjectCycleRemoval());
}

test "array element self-cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const array = try core.Object.createArray(rt, null);
    const index = core.atom.atomFromUInt32(0);
    try std.testing.expect(try array.appendDenseArrayIndex(rt, 0, index, array.value()));

    array.value().free(rt);
    try std.testing.expectEqual(@as(usize, 1), rt.runObjectCycleRemoval());
}

test "typed-array buffer self-cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const view = try core.Object.create(rt, core.class.ids.object, null);
    try view.ensureTypedArrayPayload(rt);
    view.typedArrayBufferSlot().* = view.value().dup();

    view.value().free(rt);
    try std.testing.expectEqual(@as(usize, 1), rt.runObjectCycleRemoval());
}

test "regexp payload self-cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const regexp = try core.Object.create(rt, core.class.ids.regexp, null);
    regexp.regexpSourceSlot().* = regexp.value().dup();
    regexp.regexpFlagsSlot().* = regexp.value().dup();
    regexp.regexpLastIndexSlot().* = regexp.value().dup();

    regexp.value().free(rt);
    try std.testing.expectEqual(@as(usize, 1), rt.runObjectCycleRemoval());
}

test "function records own native bytecode and bound payloads" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
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
        core.JSValue.undefinedValue(),
    );
    try std.testing.expectEqual(core.function.Kind.bytecode, bytecode.kind);
    try std.testing.expectEqual(core.function.FunctionKind.generator, bytecode.function_kind);
    try std.testing.expectEqual(@as(usize, 2), bytecode.payload.bytecode.bytecode.len);
    try std.testing.expectEqual(@as(usize, 1), bytecode.payload.bytecode.constants.len);
    try std.testing.expectEqual(@as(i32, 2), constant_string.header.rc);
    constant_value.free(rt);
    bytecode.destroy(rt);

    const bound_string = try core.string.String.createAscii(rt, "arg");
    const bound_arg = bound_string.value();
    var bound = try core.FunctionRecord.createBound(
        &rt.memory,
        &rt.atoms,
        core.JSValue.undefinedValue(),
        core.JSValue.nullValue(),
        &.{bound_arg},
        false,
    );
    try std.testing.expectEqual(core.function.Kind.bound, bound.kind);
    try std.testing.expectEqual(@as(i32, 2), bound_string.header.rc);
    bound_arg.free(rt);
    bound.destroy(rt);
}

test "function records retain owned unique symbol atoms" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try rt.internAtom("fn-symbol-record");
    defer rt.atoms.free(name);

    const home_symbol = try rt.atoms.newValueSymbol("gc-function-record-home");
    const constant_symbol = try rt.atoms.newValueSymbol("gc-function-record-constant");
    var bytecode = try core.FunctionRecord.createBytecode(
        &rt.memory,
        &rt.atoms,
        name,
        &.{0xaa},
        &.{core.JSValue.symbol(constant_symbol)},
        .normal,
        false,
        core.JSValue.symbol(home_symbol),
    );
    var bytecode_alive = true;
    defer if (bytecode_alive) bytecode.destroy(rt);

    const target_symbol = try rt.atoms.newValueSymbol("gc-function-record-target");
    const this_symbol = try rt.atoms.newValueSymbol("gc-function-record-this");
    const arg_symbol = try rt.atoms.newValueSymbol("gc-function-record-arg");
    var bound = try core.FunctionRecord.createBound(
        &rt.memory,
        &rt.atoms,
        core.JSValue.symbol(target_symbol),
        core.JSValue.symbol(this_symbol),
        &.{core.JSValue.symbol(arg_symbol)},
        false,
    );
    var bound_alive = true;
    defer if (bound_alive) bound.destroy(rt);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(home_symbol) != null);
    try std.testing.expect(rt.atoms.name(constant_symbol) != null);
    try std.testing.expect(rt.atoms.name(target_symbol) != null);
    try std.testing.expect(rt.atoms.name(this_symbol) != null);
    try std.testing.expect(rt.atoms.name(arg_symbol) != null);

    bytecode.destroy(rt);
    bytecode_alive = false;
    bound.destroy(rt);
    bound_alive = false;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(home_symbol) == null);
    try std.testing.expect(rt.atoms.name(constant_symbol) == null);
    try std.testing.expect(rt.atoms.name(target_symbol) == null);
    try std.testing.expect(rt.atoms.name(this_symbol) == null);
    try std.testing.expect(rt.atoms.name(arg_symbol) == null);
}

test "function records skip zero-length payload allocations" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const base_bytes = rt.memory.allocated_bytes;
    const base_allocations = rt.memory.allocation_count;

    var bytecode = try core.FunctionRecord.createBytecode(
        &rt.memory,
        &rt.atoms,
        core.atom.ids.empty_string,
        &.{},
        &.{},
        .normal,
        false,
        core.JSValue.undefinedValue(),
    );
    try std.testing.expectEqual(@as(usize, 0), bytecode.payload.bytecode.bytecode.len);
    try std.testing.expectEqual(@as(usize, 0), bytecode.payload.bytecode.constants.len);
    bytecode.destroy(rt);
    try std.testing.expectEqual(base_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(base_allocations, rt.memory.allocation_count);

    var bound = try core.FunctionRecord.createBound(
        &rt.memory,
        &rt.atoms,
        core.JSValue.undefinedValue(),
        core.JSValue.undefinedValue(),
        &.{},
        false,
    );
    try std.testing.expectEqual(@as(usize, 0), bound.payload.bound.args.len);
    bound.destroy(rt);
    try std.testing.expectEqual(base_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(base_allocations, rt.memory.allocation_count);
}

test "module records retain import export metadata and status" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const module_name = try rt.internAtom("main.mjs");
    const dep_name = try rt.internAtom("dep.mjs");
    const import_name = try rt.internAtom("value");
    const local_name = try rt.internAtom("local");
    const export_name = try rt.internAtom("default");
    const attr_key = try rt.internAtom("type");
    const attr_value = try rt.internAtom("json");

    const record = try rt.modules.create(module_name);
    try record.addRequestedModule(dep_name);
    try record.addImport(dep_name, import_name, local_name);
    try record.addExport(export_name, local_name);
    try record.addIndirectExport(dep_name, export_name, import_name);
    try record.addStarExport(dep_name, core.atom.predefinedId("*", .string).?);
    try record.addImportAttribute(dep_name, attr_key, attr_value);
    record.has_top_level_await = true;
    record.setStatus(.linked);

    rt.atoms.free(module_name);
    rt.atoms.free(dep_name);
    rt.atoms.free(import_name);
    rt.atoms.free(local_name);
    rt.atoms.free(export_name);
    rt.atoms.free(attr_key);
    rt.atoms.free(attr_value);

    try std.testing.expectEqual(core.module.Status.linked, record.status);
    try std.testing.expectEqual(@as(usize, 1), record.requested_modules.len);
    try std.testing.expectEqual(@as(usize, 1), record.imports.len);
    try std.testing.expectEqual(@as(usize, 1), record.exports.len);
    try std.testing.expectEqual(@as(usize, 1), record.indirect_exports.len);
    try std.testing.expectEqual(@as(usize, 1), record.star_exports.len);
    try std.testing.expectEqual(@as(usize, 1), record.import_attributes.len);
    try std.testing.expectEqual(@as(usize, 0), record.resolved_imports.len);
    try std.testing.expectEqual(@as(usize, 0), record.local_bindings.len);
    try std.testing.expect(record.has_top_level_await);
    try std.testing.expect(rt.atoms.name(record.module_name) != null);
    try std.testing.expect(rt.atoms.name(record.imports[0].local_name) != null);
}

test "module record add failure releases duplicated atom references" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const module_name = try rt.internAtom("oom-main.mjs");
    defer rt.atoms.free(module_name);

    const dep_name = try rt.internAtom("oom-dep.mjs");
    const import_name = try rt.internAtom("oom-import");
    const local_name = try rt.internAtom("oom-local");

    const record = try rt.modules.create(module_name);

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, record.addImport(dep_name, import_name, local_name));
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(@as(usize, 0), record.imports.len);

    rt.atoms.free(dep_name);
    rt.atoms.free(import_name);
    rt.atoms.free(local_name);

    try std.testing.expect(rt.atoms.name(dep_name) == null);
    try std.testing.expect(rt.atoms.name(import_name) == null);
    try std.testing.expect(rt.atoms.name(local_name) == null);
}

test "module registry resolves local indirect star and ambiguous exports" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const main_name = try rt.internAtom("main.mjs");
    const dep_a_name = try rt.internAtom("dep-a.mjs");
    const dep_b_name = try rt.internAtom("dep-b.mjs");
    const dep_c_name = try rt.internAtom("dep-c.mjs");
    const value_name = try rt.internAtom("value");
    const other_name = try rt.internAtom("other");
    const local_a_name = try rt.internAtom("localA");
    const local_b_name = try rt.internAtom("localB");
    defer {
        rt.atoms.free(main_name);
        rt.atoms.free(dep_a_name);
        rt.atoms.free(dep_b_name);
        rt.atoms.free(dep_c_name);
        rt.atoms.free(value_name);
        rt.atoms.free(other_name);
        rt.atoms.free(local_a_name);
        rt.atoms.free(local_b_name);
    }

    _ = try rt.modules.create(main_name);
    _ = try rt.modules.create(dep_a_name);
    _ = try rt.modules.create(dep_b_name);
    _ = try rt.modules.create(dep_c_name);

    const main = &rt.modules.modules[rt.modules.findIndex(main_name).?];
    const dep_a = &rt.modules.modules[rt.modules.findIndex(dep_a_name).?];
    const dep_b = &rt.modules.modules[rt.modules.findIndex(dep_b_name).?];
    const dep_c = &rt.modules.modules[rt.modules.findIndex(dep_c_name).?];

    try dep_a.addExport(value_name, local_a_name);
    try dep_b.addExport(value_name, local_b_name);
    try dep_c.addIndirectExport(dep_a_name, other_name, value_name);

    try main.addIndirectExport(dep_c_name, other_name, other_name);
    try main.addStarExport(dep_a_name, core.atom.predefinedId("*", .string).?);

    const indirect = try rt.modules.resolveExport(main_name, other_name);
    try std.testing.expectEqual(core.module.ResolvedExport.resolved, std.meta.activeTag(indirect));
    try std.testing.expectEqual(local_a_name, indirect.resolved.local_name);

    const star = try rt.modules.resolveExport(main_name, value_name);
    try std.testing.expectEqual(core.module.ResolvedExport.resolved, std.meta.activeTag(star));
    try std.testing.expectEqual(local_a_name, star.resolved.local_name);

    try main.addStarExport(dep_b_name, core.atom.predefinedId("*", .string).?);
    const ambiguous = try rt.modules.resolveExport(main_name, value_name);
    try std.testing.expectEqual(core.module.ResolvedExport.ambiguous, std.meta.activeTag(ambiguous));
}

test "module registry createFresh replaces stale records by name" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const module_name = try rt.internAtom("fresh.mjs");
    const export_name = try rt.internAtom("old");
    defer {
        rt.atoms.free(module_name);
        rt.atoms.free(export_name);
    }

    const first = try rt.modules.createFresh(rt, module_name);
    try first.addExport(export_name, export_name);
    first.setStatus(.linked);

    const second = try rt.modules.createFresh(rt, module_name);
    try std.testing.expectEqual(@as(usize, 1), rt.modules.modules.len);
    try std.testing.expectEqual(core.module.Status.unlinked, second.status);
    try std.testing.expectEqual(@as(usize, 0), second.exports.len);
}

test "module registry link validates dependencies imports and ambiguous exports" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const main_name = try rt.internAtom("link-main.mjs");
    const dep_name = try rt.internAtom("link-dep.mjs");
    const cycle_name = try rt.internAtom("link-cycle.mjs");
    const missing_main_name = try rt.internAtom("missing-main.mjs");
    const ambiguous_main_name = try rt.internAtom("ambiguous-main.mjs");
    const ambiguous_consumer_name = try rt.internAtom("ambiguous-consumer.mjs");
    const amb_a_name = try rt.internAtom("amb-a.mjs");
    const amb_b_name = try rt.internAtom("amb-b.mjs");
    const value_name = try rt.internAtom("value");
    const local_name = try rt.internAtom("local");
    defer {
        rt.atoms.free(main_name);
        rt.atoms.free(dep_name);
        rt.atoms.free(cycle_name);
        rt.atoms.free(missing_main_name);
        rt.atoms.free(ambiguous_main_name);
        rt.atoms.free(ambiguous_consumer_name);
        rt.atoms.free(amb_a_name);
        rt.atoms.free(amb_b_name);
        rt.atoms.free(value_name);
        rt.atoms.free(local_name);
    }

    _ = try rt.modules.create(main_name);
    _ = try rt.modules.create(dep_name);
    _ = try rt.modules.create(cycle_name);
    _ = try rt.modules.create(missing_main_name);
    _ = try rt.modules.create(ambiguous_main_name);
    _ = try rt.modules.create(ambiguous_consumer_name);
    _ = try rt.modules.create(amb_a_name);
    _ = try rt.modules.create(amb_b_name);

    const main = &rt.modules.modules[rt.modules.findIndex(main_name).?];
    const dep = &rt.modules.modules[rt.modules.findIndex(dep_name).?];
    const cycle = &rt.modules.modules[rt.modules.findIndex(cycle_name).?];
    const missing_main = &rt.modules.modules[rt.modules.findIndex(missing_main_name).?];
    const ambiguous_main = &rt.modules.modules[rt.modules.findIndex(ambiguous_main_name).?];
    const ambiguous_consumer = &rt.modules.modules[rt.modules.findIndex(ambiguous_consumer_name).?];
    const amb_a = &rt.modules.modules[rt.modules.findIndex(amb_a_name).?];
    const amb_b = &rt.modules.modules[rt.modules.findIndex(amb_b_name).?];

    try dep.addExport(value_name, local_name);
    try dep.addRequestedModule(cycle_name);
    try cycle.addRequestedModule(dep_name);
    try main.addRequestedModule(dep_name);
    try main.addImport(dep_name, value_name, local_name);
    try rt.modules.linkModule(rt, main_name);
    try std.testing.expectEqual(core.module.Status.linked, main.status);
    try std.testing.expectEqual(core.module.Status.linked, dep.status);
    try std.testing.expectEqual(core.module.Status.linked, cycle.status);
    try std.testing.expectEqual(@as(usize, 0), main.local_bindings.len);
    try std.testing.expectEqual(@as(usize, 1), dep.local_bindings.len);
    try std.testing.expectEqual(local_name, dep.local_bindings[0].name);
    try std.testing.expect(!dep.local_bindings[0].initialized);
    try dep.markLocalBindingInitialized(local_name);
    try std.testing.expect(dep.local_bindings[0].initialized);
    try std.testing.expectEqual(@as(usize, 1), main.resolved_imports.len);
    try std.testing.expectEqual(local_name, main.resolved_imports[0].local_name);
    try std.testing.expectEqual(rt.modules.findIndex(dep_name).?, main.resolved_imports[0].module_index);
    try std.testing.expectEqual(local_name, main.resolved_imports[0].binding_name);

    try missing_main.addRequestedModule(amb_a_name);
    try missing_main.addImport(amb_a_name, value_name, local_name);
    try std.testing.expectError(error.MissingExport, rt.modules.linkModule(rt, missing_main_name));
    try std.testing.expectEqual(core.module.Status.errored, missing_main.status);
    try std.testing.expectEqual(@as(usize, 0), missing_main.resolved_imports.len);

    try amb_a.addExport(value_name, local_name);
    try amb_b.addExport(value_name, value_name);
    try ambiguous_main.addRequestedModule(amb_a_name);
    try ambiguous_main.addRequestedModule(amb_b_name);
    try ambiguous_main.addStarExport(amb_a_name, core.atom.predefinedId("*", .string).?);
    try ambiguous_main.addStarExport(amb_b_name, core.atom.predefinedId("*", .string).?);
    try ambiguous_consumer.addRequestedModule(ambiguous_main_name);
    try ambiguous_consumer.addImport(ambiguous_main_name, value_name, local_name);
    try std.testing.expectError(error.AmbiguousExport, rt.modules.linkModule(rt, ambiguous_consumer_name));
    try std.testing.expectEqual(core.module.Status.linked, ambiguous_main.status);
    try std.testing.expectEqual(core.module.Status.errored, ambiguous_consumer.status);
    try std.testing.expectEqual(@as(usize, 0), ambiguous_consumer.resolved_imports.len);
}

test "module resolution normalizes namespace re-export bindings" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const target_name = try rt.internAtom("target");
    const star_a_name = try rt.internAtom("star-a");
    const star_b_name = try rt.internAtom("star-b");
    const import_a_name = try rt.internAtom("import-a");
    const import_b_name = try rt.internAtom("import-b");
    const star_root_name = try rt.internAtom("star-root");
    const import_root_name = try rt.internAtom("import-root");
    const mixed_root_name = try rt.internAtom("mixed-root");
    const foo_name = try rt.internAtom("foo");
    const default_name = try rt.internAtom("default");
    const star_atom = core.atom.predefinedId("*", .string).?;
    defer {
        rt.atoms.free(target_name);
        rt.atoms.free(star_a_name);
        rt.atoms.free(star_b_name);
        rt.atoms.free(import_a_name);
        rt.atoms.free(import_b_name);
        rt.atoms.free(star_root_name);
        rt.atoms.free(import_root_name);
        rt.atoms.free(mixed_root_name);
        rt.atoms.free(foo_name);
        rt.atoms.free(default_name);
    }

    _ = try rt.modules.create(target_name);
    _ = try rt.modules.create(star_a_name);
    _ = try rt.modules.create(star_b_name);
    _ = try rt.modules.create(import_a_name);
    _ = try rt.modules.create(import_b_name);
    _ = try rt.modules.create(star_root_name);
    _ = try rt.modules.create(import_root_name);
    _ = try rt.modules.create(mixed_root_name);

    const star_a = &rt.modules.modules[rt.modules.findIndex(star_a_name).?];
    const star_b = &rt.modules.modules[rt.modules.findIndex(star_b_name).?];
    const import_a = &rt.modules.modules[rt.modules.findIndex(import_a_name).?];
    const import_b = &rt.modules.modules[rt.modules.findIndex(import_b_name).?];
    const star_root = &rt.modules.modules[rt.modules.findIndex(star_root_name).?];
    const import_root = &rt.modules.modules[rt.modules.findIndex(import_root_name).?];
    const mixed_root = &rt.modules.modules[rt.modules.findIndex(mixed_root_name).?];

    try star_a.addRequestedModule(target_name);
    try star_a.addStarExport(target_name, foo_name);
    try star_a.addStarExport(target_name, default_name);
    try star_b.addRequestedModule(target_name);
    try star_b.addStarExport(target_name, foo_name);
    try import_a.addRequestedModule(target_name);
    try import_a.addImport(target_name, star_atom, foo_name);
    try import_a.addExport(foo_name, foo_name);
    try import_b.addRequestedModule(target_name);
    try import_b.addImport(target_name, star_atom, foo_name);
    try import_b.addExport(foo_name, foo_name);

    try star_root.addRequestedModule(star_a_name);
    try star_root.addRequestedModule(star_b_name);
    try star_root.addStarExport(star_a_name, star_atom);
    try star_root.addStarExport(star_b_name, star_atom);
    try import_root.addRequestedModule(import_a_name);
    try import_root.addRequestedModule(import_b_name);
    try import_root.addStarExport(import_a_name, star_atom);
    try import_root.addStarExport(import_b_name, star_atom);
    try mixed_root.addRequestedModule(star_a_name);
    try mixed_root.addRequestedModule(import_a_name);
    try mixed_root.addStarExport(star_a_name, star_atom);
    try mixed_root.addStarExport(import_a_name, star_atom);

    try rt.modules.linkModule(rt, star_root_name);
    try rt.modules.linkModule(rt, import_root_name);
    try rt.modules.linkModule(rt, mixed_root_name);

    const star_resolution = try rt.modules.resolveExport(star_root_name, foo_name);
    try std.testing.expectEqual(.resolved, std.meta.activeTag(star_resolution));
    try std.testing.expectEqual(rt.modules.findIndex(target_name).?, star_resolution.resolved.module_index);
    try std.testing.expectEqual(star_atom, star_resolution.resolved.local_name);

    const explicit_default_resolution = try rt.modules.resolveExport(star_a_name, default_name);
    try std.testing.expectEqual(.resolved, std.meta.activeTag(explicit_default_resolution));
    try std.testing.expectEqual(rt.modules.findIndex(target_name).?, explicit_default_resolution.resolved.module_index);
    try std.testing.expectEqual(star_atom, explicit_default_resolution.resolved.local_name);

    const import_resolution = try rt.modules.resolveExport(import_root_name, foo_name);
    try std.testing.expectEqual(.resolved, std.meta.activeTag(import_resolution));
    try std.testing.expectEqual(rt.modules.findIndex(target_name).?, import_resolution.resolved.module_index);
    try std.testing.expectEqual(star_atom, import_resolution.resolved.local_name);

    const mixed_resolution = try rt.modules.resolveExport(mixed_root_name, foo_name);
    try std.testing.expectEqual(.resolved, std.meta.activeTag(mixed_resolution));
    try std.testing.expectEqual(rt.modules.findIndex(target_name).?, mixed_resolution.resolved.module_index);
    try std.testing.expectEqual(star_atom, mixed_resolution.resolved.local_name);
}

fn interruptOnce(rt: *core.JSRuntime, _: ?*anyopaque) bool {
    rt.random_state +%= 1;
    return true;
}

test "runtime stack and interrupt state are stored" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    rt.setStackSize(4096);
    try std.testing.expectEqual(@as(usize, 4096), rt.stackSize());
    try std.testing.expect(!rt.hasInterruptHandler());
    rt.setInterruptHandler(interruptOnce, null);
    try std.testing.expect(rt.hasInterruptHandler());
    const before = rt.random_state;
    try std.testing.expect(rt.runInterruptHandler());
    try std.testing.expectEqual(before +% 1, rt.random_state);
}

test "ordinary objects define own data properties and descriptors" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const obj = try core.Object.create(rt, core.class.ids.object, null);
    defer obj.value().free(rt);

    const key = try rt.internAtom("answer");
    defer rt.atoms.free(key);

    try obj.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(42), true, true, true));
    const desc = obj.getOwnProperty(key).?;
    defer desc.destroy(rt);
    try std.testing.expectEqual(core.descriptor.Kind.data, desc.kind);
    try std.testing.expectEqual(@as(?i32, 42), desc.value.asInt32());
    try std.testing.expectEqual(true, desc.writable.?);
    try std.testing.expect(obj.hasOwnProperty(key));

    try obj.setProperty(rt, key, core.JSValue.int32(7));
    const updated = obj.getProperty(key);
    try std.testing.expectEqual(@as(?i32, 7), updated.asInt32());
}

test "define property enforces non-configurable and non-writable invariants" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const obj = try core.Object.create(rt, core.class.ids.object, null);
    defer obj.value().free(rt);

    const key = try rt.internAtom("locked");
    defer rt.atoms.free(key);

    try obj.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(1), false, false, false));
    try std.testing.expectError(
        error.IncompatibleDescriptor,
        obj.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(2), false, false, false)),
    );
    try std.testing.expectError(
        error.IncompatibleDescriptor,
        obj.defineOwnProperty(rt, key, core.Descriptor.generic(true, null)),
    );
    try std.testing.expect(!obj.deleteProperty(rt, key));
}

test "accessor descriptors store getter setter placeholders" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const obj = try core.Object.create(rt, core.class.ids.object, null);
    defer obj.value().free(rt);

    const key = try rt.internAtom("accessor");
    defer rt.atoms.free(key);

    const getter = try core.string.String.createAscii(rt, "getter");
    const setter = try core.string.String.createAscii(rt, "setter");
    try obj.defineOwnProperty(rt, key, core.Descriptor.accessor(getter.value(), setter.value(), true, true));
    getter.value().free(rt);
    setter.value().free(rt);

    const desc = obj.getOwnProperty(key).?;
    defer desc.destroy(rt);
    try std.testing.expectEqual(core.descriptor.Kind.accessor, desc.kind);
    try std.testing.expect(desc.getter.isString());
    try std.testing.expect(desc.setter.isString());
}

test "prototype traversal and cycle checks are enforced" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const proto = try core.Object.create(rt, core.class.ids.object, null);
    defer proto.value().free(rt);
    const child = try core.Object.create(rt, core.class.ids.object, proto);
    defer child.value().free(rt);

    const key = try rt.internAtom("inherited");
    defer rt.atoms.free(key);
    try proto.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(11), true, true, true));

    try std.testing.expect(!child.hasOwnProperty(key));
    try std.testing.expect(child.hasProperty(key));
    try std.testing.expectEqual(@as(?i32, 11), child.getProperty(key).asInt32());
    try std.testing.expectError(error.PrototypeCycle, proto.setPrototype(rt, child));
}

test "own keys follow index string symbol ordering" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const obj = try core.Object.create(rt, core.class.ids.object, null);
    defer obj.value().free(rt);

    const str_b = try rt.internAtom("b");
    const index_2 = try rt.internAtom("2");
    const index_1 = try rt.internAtom("1");
    const sym = try rt.atoms.newSymbol("sym", .symbol);
    defer rt.atoms.free(str_b);
    defer rt.atoms.free(index_2);
    defer rt.atoms.free(index_1);
    defer rt.atoms.free(sym);

    try obj.defineOwnProperty(rt, str_b, core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    try obj.defineOwnProperty(rt, index_2, core.Descriptor.data(core.JSValue.int32(2), true, true, true));
    try obj.defineOwnProperty(rt, sym, core.Descriptor.data(core.JSValue.int32(3), true, true, true));
    try obj.defineOwnProperty(rt, index_1, core.Descriptor.data(core.JSValue.int32(4), true, true, true));

    const keys = try obj.ownKeys(rt);
    defer core.Object.freeKeys(rt, keys);

    try std.testing.expectEqual(@as(usize, 4), keys.len);
    try std.testing.expectEqual(index_1, keys[0]);
    try std.testing.expectEqual(index_2, keys[1]);
    try std.testing.expectEqual(str_b, keys[2]);
    try std.testing.expectEqual(sym, keys[3]);
}

test "extensibility seal and freeze update descriptor flags" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const obj = try core.Object.create(rt, core.class.ids.object, null);
    defer obj.value().free(rt);
    const key = try rt.internAtom("x");
    const other = try rt.internAtom("y");
    defer rt.atoms.free(key);
    defer rt.atoms.free(other);

    try obj.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    obj.preventExtensions();
    try std.testing.expect(!obj.isExtensible());
    try std.testing.expectError(error.NotExtensible, obj.defineOwnProperty(rt, other, core.Descriptor.data(core.JSValue.int32(2), true, true, true)));

    try obj.freeze(rt);
    const desc = obj.getOwnProperty(key).?;
    defer desc.destroy(rt);
    try std.testing.expectEqual(false, desc.configurable.?);
    try std.testing.expectEqual(false, desc.writable.?);
}

test "array index detection handles QuickJS boundaries" {
    try std.testing.expect(core.array.isArrayIndexName("0"));
    try std.testing.expect(core.array.isArrayIndexName("4294967294"));
    try std.testing.expect(!core.array.isArrayIndexName("4294967295"));
    try std.testing.expect(!core.array.isArrayIndexName("01"));
    try std.testing.expect(!core.array.isArrayIndexName("-1"));
    try std.testing.expect(core.array.canonicalNumericIndex("-0") != null);
}

test "array length tracks sparse indices and truncation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const array_obj = try core.Object.createArray(rt, null);
    defer array_obj.value().free(rt);

    const index_5 = try rt.internAtom("5");
    const index_1 = try rt.internAtom("1");
    defer rt.atoms.free(index_5);
    defer rt.atoms.free(index_1);

    try array_obj.defineOwnProperty(rt, index_5, core.Descriptor.data(core.JSValue.int32(5), true, true, true));
    try std.testing.expectEqual(@as(u32, 6), array_obj.length);
    try array_obj.defineOwnProperty(rt, index_1, core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    try std.testing.expectEqual(@as(u32, 6), array_obj.length);

    try array_obj.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(2), false, false, false));
    try std.testing.expectEqual(@as(u32, 2), array_obj.length);
    try std.testing.expect(!array_obj.hasOwnProperty(index_5));
    try std.testing.expect(array_obj.hasOwnProperty(index_1));
    try std.testing.expectError(error.ReadOnly, array_obj.defineOwnProperty(rt, index_5, core.Descriptor.data(core.JSValue.int32(5), true, true, true)));
}

test "array indexed delete does not let dense holes mask ordinary properties" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const array_obj = try core.Object.createArray(rt, null);
    defer array_obj.value().free(rt);

    const index_0 = core.atom.atomFromUInt32(0);
    try std.testing.expect(try array_obj.appendDenseArrayIndex(rt, 0, index_0, core.JSValue.int32(1)));
    try array_obj.defineOwnProperty(rt, index_0, core.Descriptor.data(core.JSValue.int32(2), true, true, true));
    try std.testing.expectEqual(@as(?i32, 2), array_obj.getProperty(index_0).asInt32());

    try std.testing.expect(array_obj.deleteProperty(rt, index_0));
    try std.testing.expect(!array_obj.hasOwnProperty(index_0));
}

test "array element storage mode moves between dense and sparse" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const array_obj = try core.Object.createArray(rt, null);
    defer array_obj.value().free(rt);

    const index_0 = try rt.internAtom("0");
    const index_100 = try rt.internAtom("100");
    defer rt.atoms.free(index_0);
    defer rt.atoms.free(index_100);

    try array_obj.defineOwnProperty(rt, index_0, core.Descriptor.data(core.JSValue.int32(0), true, true, true));
    try std.testing.expectEqual(core.object.ArrayStorageMode.dense, array_obj.arrayElementStorageMode());
    try array_obj.defineOwnProperty(rt, index_100, core.Descriptor.data(core.JSValue.int32(100), true, true, true));
    try std.testing.expectEqual(core.object.ArrayStorageMode.sparse, array_obj.arrayElementStorageMode());
    try array_obj.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(1), true, false, false));
    try std.testing.expectEqual(core.object.ArrayStorageMode.dense, array_obj.arrayElementStorageMode());
}

var exotic_define_calls: usize = 0;
var exotic_delete_calls: usize = 0;

fn exoticGet(_: *core.Object, _: core.Atom) ?core.Descriptor {
    return core.Descriptor.data(core.JSValue.int32(99), false, false, true);
}

fn exoticDefine(_: *core.Object, _: core.Atom, _: core.Descriptor) bool {
    exotic_define_calls += 1;
    return true;
}

fn exoticDelete(_: *core.Object, _: core.Atom) bool {
    exotic_delete_calls += 1;
    return true;
}

fn exoticOwnKeys(_: *core.Object, rt: *core.JSRuntime) ![]core.Atom {
    const keys = try rt.memory.alloc(core.Atom, 1);
    keys[0] = rt.atoms.dup(core.atom.ids.length);
    return keys;
}

test "exotic dispatch hooks are called without builtin shortcuts" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const obj = try core.Object.create(rt, core.class.ids.object, null);
    defer obj.value().free(rt);
    obj.exotic = .{
        .get_own_property = exoticGet,
        .define_own_property = exoticDefine,
        .delete_property = exoticDelete,
        .own_keys = exoticOwnKeys,
    };

    exotic_define_calls = 0;
    exotic_delete_calls = 0;
    const key = try rt.internAtom("hooked");
    defer rt.atoms.free(key);

    const desc = obj.getOwnProperty(key).?;
    defer desc.destroy(rt);
    try std.testing.expectEqual(@as(?i32, 99), desc.value.asInt32());
    try obj.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    try std.testing.expectEqual(@as(usize, 1), exotic_define_calls);
    try std.testing.expect(obj.deleteProperty(rt, key));
    try std.testing.expectEqual(@as(usize, 1), exotic_delete_calls);

    const keys = try obj.ownKeys(rt);
    defer core.Object.freeKeys(rt, keys);
    try std.testing.expectEqual(@as(usize, 1), keys.len);
    try std.testing.expectEqual(core.atom.ids.length, keys[0]);
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

test "external value root lifecycle preserves and releases registered values across GC" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-external-rooted-symbol");
    const rooted_value = core.JSValue.symbol(symbol_atom);

    try std.testing.expect(try rt.registerExternalValueSymbolRoot(rooted_value));
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    rt.unregisterExternalValueSymbolRoot(rooted_value);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "GC roots symmetry for finalization registry pending jobs" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const cleanup_sym = try rt.atoms.newValueSymbol("finalization-cleanup-callback");
    const cleanup_val = core.JSValue.symbol(cleanup_sym);

    const held_sym = try rt.atoms.newValueSymbol("finalization-held-value");
    const held_val = core.JSValue.symbol(held_sym);

    // Create a real object target
    const target_obj = try core.Object.create(rt, core.class.ids.object, null);
    var target_val = target_obj.value();
    defer target_val.free(rt);

    // Define a unique symbol property on the target object to track its GC lifecycle
    const target_sym = try rt.atoms.newValueSymbol("finalization-target-symbol");
    try target_obj.defineOwnProperty(rt, target_sym, core.Descriptor.data(core.JSValue.boolean(true), true, true, true));

    // Finalization Registry object creation
    const registry = try core.Object.create(rt, core.class.ids.finalization_registry, null);
    registry.finalizationRegistryCleanupCallbackSlot().* = cleanup_val.dup();

    // Add a cell to the cells list using the target object
    try registry.appendFinalizationRegistryCell(rt, target_val, held_val, core.JSValue.undefinedValue());

    // Root the registry and the target object so we can trace its components and keep it alive initially
    var registry_val = registry.value();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &registry_val },
        .{ .value = &target_val },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;

    // Run GC cycle, all components must be traced and kept alive
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(cleanup_sym) != null);
    try std.testing.expect(rt.atoms.name(target_sym) != null);
    try std.testing.expect(rt.atoms.name(held_sym) != null);

    // Remove the target object from root frame (keep only registry rooted)
    var root_values_after = [_]core.runtime.ValueRootValue{
        .{ .value = &registry_val },
    };
    const root_frame_after = core.runtime.ValueRootFrame{
        .previous = root_frame.previous,
        .values = &root_values_after,
    };
    rt.active_value_roots = &root_frame_after;

    // Release our stack reference to the target object so it is collected
    target_val.free(rt);
    target_val = core.JSValue.undefinedValue();

    // Run GC again. Since the target object is destroyed, its finalizer cell will be processed
    // and enqueued onto rt.pending_finalization_jobs!
    _ = rt.runObjectCycleRemoval();

    // Verify the target object and its property symbol are collected
    try std.testing.expect(rt.atoms.name(target_sym) == null);

    // BUT the enqueued finalization job must preserve the cleanup callback and held value symbols!
    try std.testing.expect(rt.atoms.name(cleanup_sym) != null);
    try std.testing.expect(rt.atoms.name(held_sym) != null);

    // Now unroot the registry
    rt.active_value_roots = root_frame_after.previous;
    registry_val.free(rt);

    // Clear the pending finalization jobs
    rt.clearPendingFinalizationJobs();

    // Run GC again. Everything must be collected and cleanly freed (zero leak)
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(cleanup_sym) == null);
    try std.testing.expect(rt.atoms.name(held_sym) == null);
}
