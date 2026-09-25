//! Non-test-build coverage: scalar root helpers have a different production policy.
const std = @import("std");
const zjs = @import("zjs");
const core = zjs.core;

comptime {
    if (@import("builtin").is_test) @compileError("exact root production fixture must be an executable");
}

fn require(condition: bool) !void {
    if (!condition) return error.ExactRootContractFailed;
}

fn optionalValueResult(result: anytype) @typeInfo(@TypeOf(result)).error_union.error_set!?core.JSValue {
    return try result;
}

const TraceProbe = struct {
    rt: *core.JSRuntime,
    reference: core.runtime.MutableRootedValueRef,
    denied: bool = false,
    fn value(_: *anyopaque, _: *core.JSValue) core.runtime.RootTraceError!void {}
    fn object(_: *anyopaque, _: *?*core.Object) core.runtime.RootTraceError!void {}
    fn trace(raw: *anyopaque, _: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.reference.set(self.rt, core.JSValue.undefinedValue()) catch |err| {
            self.denied = err == error.RootMutationDuringCollection;
        };
        return error.OutOfMemory;
    }
};

fn verifyWaiterRoots(rt: *core.JSRuntime) !void {
    const atomics = zjs.exec.atomics_ops;
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    // The waiter slot is a general JSValue root. Use a nursery-eligible
    // object to prove relocation, then drop the job without Promise dispatch.
    const object = try core.Object.createPlainObject(rt, null);
    const before = @intFromPtr(object.gcHeader());
    try require(core.gc.Registry.isNurseryHeader(object.gcHeader()));
    const waiter = try rt.nativeAllocator().create(atomics.AtomicsWaiter);
    waiter.* = .{ .key = .{ .offset_or_ptr = @intFromPtr(ctx) }, .promise = object.value(), .realm = core.RealmRef.retain(ctx) };
    atomics.atomicsLinkAsyncWaiter(waiter);
    defer atomics.cleanupAtomicsWaitersForContext(ctx);
    _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
    const moved = waiter.promise.?.heapReference().?;
    try require(@intFromPtr(moved) != before);
    try require(atomics.atomicsWakeWaiters(waiter.key, 1) == 1);
    try atomics.processExpiredAtomicsWaiters(ctx);
    try require(rt.job_queue.jobs.len == 1);
    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
    try require(rt.job_queue.jobs[0].payload.atomics_waiter.promise.heapReference().? == moved);
    try require(rt.gc.containsHeader(rt.job_queue.jobs[0].payload.atomics_waiter.promise.cycleMarkHeader().?));
    var job = rt.job_queue.takeFirst().?;
    job.deinit();

    const input = (try core.string.String.createAscii(rt, "waitAsync-production-input")).value();
    const input_header = input.cycleMarkHeader().?;
    const epoch = rt.gc.collection_epoch;
    const pins_before = rt.gc.pins.count();
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    if (atomics.atomicsWaitAsyncResult(ctx, false, input)) |_| return error.ExpectedResultOom else |err| {
        if (err != error.OutOfMemory) return err;
    }
    try require(rt.gc.collection_epoch > epoch);
    try require(rt.gc.containsHeader(input_header));
    try require(rt.gc.pins.count() == pins_before);
    rt.setMemoryLimit(null);
    const wrapper = try atomics.atomicsWaitAsyncResult(ctx, false, input);
    const wrapper_object = core.Object.fromHeader(wrapper.cycleMarkHeader().?);
    const stored = try wrapper_object.getProperty(core.atom.ids.value);
    try require(stored.asStringBodyRaw().?.eqlBytes("waitAsync-production-input"));
    try require(rt.gc.pins.count() == pins_before);
}

pub fn main() !void {
    try verifyRetainedNurseryPrototype();
    try verifyCollectionGroupRoots();
    try verifyTailBufferPublication();
    try verifyStringAddRoots();
    try verifyPrimitiveBoxingRoots();
    try verifyDispatchNameSnapshot();
    try verifyPureValueReadWindows();
    try verifyBareNumberAutoInitRoots();
    try verifyNumberParseCoercionRoots();
    try verifyBitmapHeapBudgetReclaim();
    try verifyRawJsonConstructionRoots();
    const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
    defer rt.destroy();
    var borrow = core.runtime.NoGcScope{};
    borrow.activate(rt);
    if (comptime @import("builtin").mode == .Debug) {
        try require(rt.active_no_gc_scope == &borrow);
    } else {
        try require(@sizeOf(core.runtime.NoGcScope) == 0);
    }
    borrow.deactivate();
    // Explicitly exclude conservative retention: the registered slot must be
    // sufficient even when the compiler leaves stale copies on the stack.
    rt.gc.scheduler.host_quiescent = true;
    var roots = core.runtime.ExactValueRoots(2){};
    try roots.activate(rt);
    defer roots.deactivate();
    const reference = try roots.ref(0);
    const value = (try core.string.String.createAscii(rt, "production exact root")).value();
    const header = value.cycleMarkHeader().?;
    try reference.set(rt, value);
    var probe = TraceProbe{ .rt = rt, .reference = reference };
    const provider = core.runtime.RootProvider{ .context = &probe, .trace = TraceProbe.trace };
    try rt.registerRootProvider(provider);
    var visitor = core.runtime.RootVisitor{ .readonly = .observe, .context = &probe, .visit_value = TraceProbe.value, .visit_object = TraceProbe.object };
    if (rt.roots.traceProviders(&visitor)) |_| return error.ExpectedTraceFailure else |err| {
        if (err != error.OutOfMemory) return err;
    }
    try require(probe.denied and !rt.roots.isTracing());
    rt.unregisterRootProvider(provider);
    try require((try reference.get(rt)).bits == value.bits);
    try require(rt.active_value_roots != null);
    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
    try require(rt.gc.containsHeader(header));
    try require((try reference.get(rt)).asStringBodyRaw().?.eqlBytes("production exact root"));
    roots.deactivate();
    if (reference.get(rt)) |_| return error.ExpiredReferenceAccepted else |err| {
        if (err != error.InactiveRoot) return err;
    }
    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
    try require(!rt.gc.containsHeader(header));

    try roots.activate(rt);
    const first = try roots.ref(0);
    const second = try roots.ref(1);
    rt.gc.nursery.enabled = true;
    const object = try core.Object.createPlainObject(rt, null);
    try first.set(rt, object.value());
    try second.copyFrom(rt, first.readOnly());
    const before = @intFromPtr(object.gcHeader());
    try require(core.gc.Registry.isNurseryHeader(object.gcHeader()));
    _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
    const moved = (try first.get(rt)).cycleMarkHeader().?;
    try require(@intFromPtr(moved) != before);
    try require((try first.get(rt)).bits == (try second.get(rt)).bits);
    try require(rt.gc.containsHeader(moved));

    try first.set(rt, (try core.string.String.createAscii(rt, "explicit-")).value());
    try second.set(rt, (try core.string.String.createAscii(rt, "flat")).value());
    try first.set(rt, (try core.string.String.createRope(rt, try first.get(rt), try second.get(rt))).value());
    try require(core.string.asFlat(try first.get(rt)) == null);
    const before_input = (try first.get(rt)).bits;
    const before_output = (try second.get(rt)).bits;
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    if (core.string.ensureFlat(rt, first.readOnly(), second)) |_| return error.ExpectedMaterializationOom else |err| {
        if (err != error.OutOfMemory) return err;
    }
    try require((try first.get(rt)).bits == before_input);
    try require((try second.get(rt)).bits == before_output);
    rt.setMemoryLimit(null);
    try core.string.ensureFlat(rt, first.readOnly(), first);
    try require(core.string.asFlat(try first.get(rt)).?.eqlBytes("explicit-flat"));
    try verifyWaiterRoots(rt);
    try verifyStreamingConversions(rt);
    try verifyPadding(rt);
    try verifyConcat(rt);
    try verifySlices(rt);
    try verifyRegExpReplace(rt);
    try verifyRegExpSplit(rt);
    try verifyAsciiSuffix(rt);
    try verifyRegExpSplitEntry(rt);
    try verifyRegExpMatchSearch(rt);
    try verifyRegExpMatchAll(rt);
    try verifyStringMatchAll(rt);
    try verifyStableHeaderRoot(rt);
    try verifyGenericReplace(rt);
    try verifyStringConversionChains(rt);
    try verifyRopeQueries(rt);
    try verifyStringSearchRoots(rt);
    try verifyStringWrapperAndRepeat(rt);
    try verifyStringSplitRoots(rt);
    try verifyStringCaseRoots(rt);
    try verifyStringIteratorRoots(rt);
    try verifyNativeFunctionMetadataRoots(rt);
    try verifyPropertyKeyRoots(rt);
    try verifyExceptionNameReads(rt);
    try verifyRegExpEscapeBorrow(rt);
    try verifyRegExpSourcePublication(rt);
    try verifyRegExpCompileRoots(rt);
    try verifyRegExpProgramCommit();
    try verifyRegExpExecutionRoots(rt);
    try verifyRegExpCaptureResultRoots(rt);
    try verifyRegExpLegacyStaticsRoots(rt);
    try verifyReadonlyNurseryRoots();
    try verifyCellRootCarriers();
    try verifyAccessorSlots();
    try verifyFunctionHomeObject();
    try verifyEvacuationRollback();
    try verifyWeakEphemeronRelocation();
    try verifyUriReadWindows();
    try verifyDateReadWindows();
    try verifyDateCoercionRoots();
    try verifyDateCallbackChains();
    try verifyJsonQuoteReadWindows();
    try verifyJsonParseReadWindows();
    try verifyJsonReviverRoots();
    try verifyJsonStringifyOptionRoots();
    try verifyJsonGapReadWindows();
    try verifyJsonStringifyCallbackRoots();
    try verifyJsonStringifyGetterRoots();
    try verifyNativeJsonStringifyRoots();
    try verifyNativeJsonAutoInitRoots();
    try verifyIteratorResult(rt);
    try verifyCallEntryRoots();
    try verifyCallSiteLifetime();
    try verifyIteratorAccumulatorRoots();
    try verifyIteratorCloseExceptionRoots();
    try verifyIteratorHelperCreationRoots();
    try verifyFlatMapInnerPublication();
    try verifyZipCallbackRoots();
    try verifyZipCreationRoots();
    try verifyConcatCreationRoots();
    try verifyZipCollectionRoots();
    try verifyIteratorStepRoots();
    try verifyIteratorAppendRoots();
    try verifySpreadDenseRoots();
    try verifyIteratorFromRoots();
    try verifyNamedNativePublicationRoots();
    try verifyPropertyRedefinitionRoots();
    try verifyAutoInitReadRoots();
    try verifyAutoInitNativePreparationRoots();
    try verifyAutoInitBuilderRoots();
    try verifyNamespacePublicationRoots();
    try verifyNativeMethodTableRoots();
    try verifyHeapLayoutProjections();
    try verifyDescriptorConversionRoots();
    try verifyBulkDescriptorRoots();
    try verifyArrayLengthConversionRoots();
    try verifyObjectAssignRoots();
    try verifyOwnPropertyKeyConversionRoots();
    try verifyFromEntriesRoots();
    try verifyObjectGroupByRoots();
    try verifyDescriptorResultRoots();
    try verifyBulkDescriptorResultRoots();
}

fn verifyBulkDescriptorResultRoots() !void {
    const Probe = struct {
        owner: core.property.AutoInitModuleOwner = .{ .resolve = resolve },
        source: usize = 0,
        incoming: usize = 0,
        key: core.Atom,
        fail: bool,
        lost: bool = false,
        fn resolve(owner: *const core.property.AutoInitModuleOwner, realm_header: *core.gc.Header, _: core.Atom) anyerror!core.property.AutoInitMaterialization {
            const self: *@This() = @constCast(@fieldParentPtr("owner", owner));
            const ctx: *core.JSContext = @alignCast(@fieldParentPtr("header", realm_header));
            const rt = ctx.runtime;
            const source = rt.liveObjectFromWeakIdentity(self.source).?;
            try require(source.deleteProperty(rt, core.atom.ids.name));
            try require(source.deleteProperty(rt, self.key));
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            self.lost = rt.liveObjectFromWeakIdentity(self.incoming) == null or rt.atoms.name(self.key) == null;
            if (self.lost or self.fail) return error.OutOfMemory;
            return .{ .value = core.JSValue.int32(17) };
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |fail| {
            const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer rt.destroy();
            rt.gc.nursery.enabled = nursery;
            rt.gc.scheduler.host_quiescent = true;
            const ctx = try core.JSContext.create(rt, .{});
            defer ctx.destroy();
            const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
            var probe = Probe{ .key = try rt.internAtom("bulkDescriptorLaterKey"), .fail = fail };
            const input = setup: {
                var source = try core.JSValueHandle.init(rt, (try core.Object.createPlainObject(rt, null)).value());
                defer source.deinit();
                const incoming = try core.Object.createPlainObject(rt, null);
                const object = core.Object.fromHeader(source.get().refHeader().?);
                try object.defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(incoming.value(), .all));
                try object.defineModuleAutoInitPropertyForFixture(rt, core.atom.ids.length, core.property.Flags.data(.all), ctx, &probe.owner);
                try object.defineOwnProperty(rt, probe.key, core.Descriptor.data(core.JSValue.int32(23), .all));
                probe.source = try rt.registerWeakObjectIdentity(object);
                probe.incoming = try rt.registerWeakObjectIdentity(incoming);
                break :setup source.get();
            };
            const result = zjs.exec.object_ops.getOwnPropertyDescriptorsCall(ctx, null, global, &.{input}, null, null);
            if (probe.lost) return error.LostBulkDescriptorResultRoot;
            try require(rt.active_value_roots == null);
            if (fail) {
                try require(if (result) |_| false else |err| err == error.OutOfMemory);
            } else {
                var kept = try core.JSValueHandle.init(rt, (try result).?);
                defer kept.deinit();
                _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                const out = core.Object.fromHeader(kept.get().refHeader().?);
                const first = core.Object.fromHeader((try out.getProperty(core.atom.ids.name)).refHeader().?);
                try require((try first.getProperty(core.atom.ids.value)).same(rt.liveObjectFromWeakIdentity(probe.incoming).?.value()));
                const second = core.Object.fromHeader((try out.getProperty(core.atom.ids.length)).refHeader().?);
                try require((try second.getProperty(core.atom.ids.value)).same(core.JSValue.int32(17)));
                try require(out.shape_ref.prop_count == 2);
            }
        }
    }
}

fn verifyDescriptorResultRoots() !void {
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |accessor| {
            for ([_]?usize{ null, 0, 128, 512, 2048, 8192 }) |budget| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const ctx = try core.JSContext.create(rt, .{});
                defer ctx.destroy();
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                const incoming = if (accessor) try core.function.nativeFunction(ctx, "descriptorResultAccessor", 0) else (try core.Object.createPlainObject(rt, null)).value();
                const identity = try rt.registerWeakObjectIdentity(core.Object.fromHeader(incoming.refHeader().?));
                const desc = if (accessor) core.Descriptor.accessor(incoming, incoming, .all) else core.Descriptor.data(incoming, .all);
                if (budget) |extra| rt.setMemoryLimit(if (extra == 0) 0 else rt.gc.heap_budget.bytes + extra);
                const result = zjs.exec.object_ops.descriptorObjectFromDescriptor(rt, global, desc);
                rt.setMemoryLimit(null);
                const live = rt.liveObjectFromWeakIdentity(identity) orelse return error.LostDescriptorResultInput;
                try require(rt.active_value_roots == null);
                const returned = result catch |err| retry: {
                    try require(err == error.OutOfMemory);
                    const retry_desc = if (accessor) core.Descriptor.accessor(live.value(), live.value(), .all) else core.Descriptor.data(live.value(), .all);
                    break :retry try zjs.exec.object_ops.descriptorObjectFromDescriptor(rt, global, retry_desc);
                };
                if (budget != null and budget.? == 0) try require(if (result) |_| false else |err| err == error.OutOfMemory);
                var kept = try core.JSValueHandle.init(rt, returned);
                defer kept.deinit();
                _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                const object = core.Object.fromHeader(kept.get().refHeader().?);
                const expected = rt.liveObjectFromWeakIdentity(identity).?.value();
                if (accessor) {
                    try require((try object.getProperty(core.atom.ids.get)).same(expected));
                    try require((try object.getProperty(core.atom.ids.set)).same(expected));
                } else {
                    try require((try object.getProperty(core.atom.ids.value)).same(expected));
                    try require((try object.getProperty(core.atom.ids.writable)).same(core.JSValue.boolean(true)));
                }
                try require((try object.getProperty(core.atom.ids.enumerable)).same(core.JSValue.boolean(true)));
                try require((try object.getProperty(core.atom.ids.configurable)).same(core.JSValue.boolean(true)));
            }
        }
    }
}

fn verifyObjectGroupByRoots() !void {
    const Probe = struct {
        failure: i32,
        close_failure: bool,
        item: ?usize = null,
        lost: bool = false,
        closes: usize = 0,
        fn thunk(ctx: *core.JSContext, _: core.JSValue, args: [*]const core.JSValue, argc: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            const stage = args[0].as(.int).?;
            const rt = ctx.runtime;
            if (stage == 5 and argc == 2) self.item = rt.registerWeakObjectIdentity(core.Object.fromHeader(args[1].refHeader().?)) catch |err| return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
            if (stage == 7) self.closes += 1;
            _ = rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only) catch |err| return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
            if (stage == 6) self.lost = rt.liveObjectFromWeakIdentity(self.item.?) == null;
            return core.JSValue.boolean(self.lost or stage == self.failure or (stage == 7 and self.close_failure));
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for (0..7) |failure| {
            for ([_]bool{ false, true }) |close_failure| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const context = try zjs.Context.create(rt, .{});
                defer context.destroy();
                const ctx = context.core;
                defer ctx.clearException();
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                var probe = Probe{ .failure = @intCast(failure), .close_failure = close_failure };
                var callback = try core.JSValueHandle.init(rt, try core.function.nativeFunction(ctx, "groupBoundary", 2));
                defer callback.deinit();
                const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.thunk), .kind = .managed, .state = &probe });
                core.Object.fromHeader(callback.get().refHeader().?).installNativeEntry(entry);
                try global.defineOwnProperty(rt, try rt.internAtom("groupBoundary"), core.Descriptor.data(callback.get(), .all));
                var fixture = try core.JSValueHandle.init(rt, try context.eval(
                    \\(() => {
                    \\  function hit(n) { if (groupBoundary(n)) throw {stage:n}; }
                    \\  const source = {[Symbol.iterator]() { hit(1); let i=0; return {
                    \\    next() { hit(2); return {
                    \\      get done() { hit(3); return i >= 3; },
                    \\      get value() { hit(4); return {marker:i++}; }
                    \\    }; },
                    \\    return() { hit(7); return {}; }
                    \\  }; }};
                    \\  return [source, function(item,index) {
                    \\    if (groupBoundary(5,item)) throw {stage:5};
                    \\    return {[Symbol.toPrimitive]() { hit(6); return 'group' + (index % 2); }};
                    \\  }];
                    \\})()
                , .{}));
                defer fixture.deinit();
                const pair = core.Object.fromHeader(fixture.get().refHeader().?);
                const args = [_]core.JSValue{ try pair.getProperty(core.Atom.taggedInt(0)), try pair.getProperty(core.Atom.taggedInt(1)) };
                const result = zjs.exec.object_ops.objectGroupByCall(ctx, null, global, &args, null, null);
                if (probe.lost) return error.LostObjectGroupByItem;
                try require(rt.active_value_roots == null);
                try require(probe.closes == if (failure >= 4) @as(usize, 1) else 0);
                if (failure != 0) {
                    try require(if (result) |_| false else |err| err == error.JSException);
                    var exception = try core.JSValueHandle.init(rt, ctx.takeException());
                    defer exception.deinit();
                    const thrown = core.Object.fromHeader(exception.get().refHeader().?);
                    try require((try thrown.getProperty(try rt.internAtom("stage"))).same(core.JSValue.int32(@intCast(failure))));
                } else {
                    var kept = try core.JSValueHandle.init(rt, (try result).?);
                    defer kept.deinit();
                    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                    const out = core.Object.fromHeader(kept.get().refHeader().?);
                    try require(out.getPrototype() == null);
                    for ([_][]const u8{ "group0", "group1" }, 0..) |name, group_index| {
                        const group = core.Object.fromHeader((try out.getProperty(try rt.internAtom(name))).refHeader().?);
                        try require(group.arrayLength() == if (group_index == 0) @as(u32, 2) else 1);
                        for (0..group.arrayLength()) |index| {
                            const item = try group.getProperty(core.Atom.taggedInt(@intCast(index)));
                            try require((try core.Object.fromHeader(item.refHeader().?).getProperty(try rt.internAtom("marker"))).same(core.JSValue.int32(@intCast(group_index + index * 2))));
                        }
                    }
                }
            }
        }
    }
}

fn verifyFromEntriesRoots() !void {
    const Probe = struct {
        failure: i32,
        close_failure: bool,
        seen: u32 = 0,
        closes: usize = 0,
        fn thunk(ctx: *core.JSContext, _: core.JSValue, args: [*]const core.JSValue, _: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            const stage = args[0].as(.int).?;
            self.seen |= @as(u32, 1) << @intCast(stage);
            if (stage == 8) self.closes += 1;
            _ = ctx.runtime.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only) catch |err| return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
            return core.JSValue.boolean(stage == self.failure or (stage == 8 and self.close_failure));
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for (0..8) |failure| {
            for ([_]bool{ false, true }) |close_failure| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const context = try zjs.Context.create(rt, .{});
                defer context.destroy();
                const ctx = context.core;
                defer ctx.clearException();
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                var probe = Probe{ .failure = @intCast(failure), .close_failure = close_failure };
                var callback = try core.JSValueHandle.init(rt, try core.function.nativeFunction(ctx, "entriesBoundary", 1));
                defer callback.deinit();
                const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.thunk), .kind = .managed, .state = &probe });
                core.Object.fromHeader(callback.get().refHeader().?).installNativeEntry(entry);
                try global.defineOwnProperty(rt, try rt.internAtom("entriesBoundary"), core.Descriptor.data(callback.get(), .all));
                var source = try core.JSValueHandle.init(rt, try context.eval(
                    \\(() => {
                    \\  function hit(n) { if (entriesBoundary(n)) throw {stage:n}; }
                    \\  return {[Symbol.iterator]() { hit(1); let i=0; return {
                    \\    next() { hit(2); return {
                    \\      get done() { hit(3); return i++ > 0; },
                    \\      get value() { hit(4); return {
                    \\        get 0() { hit(5); return {[Symbol.toPrimitive]() {hit(7); return 'entryKey';}}; },
                    \\        get 1() { hit(6); return {marker:42}; }
                    \\      }; }
                    \\    }; },
                    \\    return() { hit(8); return {}; }
                    \\  }; }};
                    \\})()
                , .{}));
                defer source.deinit();
                const result = zjs.exec.object_ops.objectFromEntriesCall(ctx, null, global, &.{source.get()}, null, null);
                try require(rt.active_value_roots == null);
                try require(probe.closes == if (failure >= 4) @as(usize, 1) else 0);
                if (failure != 0) {
                    try require(if (result) |_| false else |err| err == error.JSException);
                    try require(probe.seen & (@as(u32, 1) << @intCast(failure)) != 0);
                    var exception = try core.JSValueHandle.init(rt, ctx.takeException());
                    defer exception.deinit();
                    const thrown = core.Object.fromHeader(exception.get().refHeader().?);
                    if (!(try thrown.getProperty(try rt.internAtom("stage"))).same(core.JSValue.int32(@intCast(failure)))) return error.FromEntriesLostOriginalException;
                } else {
                    var kept = try core.JSValueHandle.init(rt, (try result).?);
                    defer kept.deinit();
                    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                    const value = try core.Object.fromHeader(kept.get().refHeader().?).getProperty(try rt.internAtom("entryKey"));
                    try require((try core.Object.fromHeader(value.refHeader().?).getProperty(try rt.internAtom("marker"))).same(core.JSValue.int32(42)));
                }
            }
        }
    }
}

fn verifyOwnPropertyKeyConversionRoots() !void {
    const Probe = struct {
        target: usize = 0,
        accessor: usize = 0,
        needs_accessor: bool,
        fail: bool,
        lost: bool = false,
        calls: usize = 0,
        fn thunk(ctx: *core.JSContext, _: core.JSValue, _: [*]const core.JSValue, _: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            const rt = ctx.runtime;
            _ = rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only) catch |err| return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
            self.calls += 1;
            self.lost = rt.liveObjectFromWeakIdentity(self.target) == null or (self.needs_accessor and rt.liveObjectFromWeakIdentity(self.accessor) == null);
            if (self.lost or self.fail) return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, error.OutOfMemory);
            const key = core.string.String.createAscii(rt, "name") catch |err| return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
            return key.value();
        }
    };
    const ops = zjs.exec.object_ops;
    for ([_]bool{ false, true }) |nursery| {
        for (0..8) |mode| {
            for ([_]bool{ false, true }) |fail| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const ctx = try core.JSContext.create(rt, .{});
                defer ctx.destroy();
                defer ctx.clearException();
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                var probe = Probe{ .needs_accessor = mode >= 3, .fail = fail };
                const inputs = setup: {
                    var values = [_]core.JSValue{core.JSValue.undefinedValue()} ** 4;
                    const live: []core.JSValue = &values;
                    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &live }};
                    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
                    roots.activate(rt);
                    defer roots.deactivate(rt);
                    values[0] = (try core.Object.createPlainObject(rt, null)).value();
                    values[1] = (try core.Object.createPlainObject(rt, null)).value();
                    values[2] = try core.function.nativeFunction(ctx, "keyAccessor", 0);
                    values[3] = try core.function.nativeFunction(ctx, "keyConversion", 1);
                    const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.thunk), .kind = .managed, .state = &probe });
                    core.Object.fromHeader(values[3].refHeader().?).installNativeEntry(entry);
                    try core.Object.fromHeader(values[1].refHeader().?).defineOwnProperty(rt, core.atom.predefinedId("Symbol.toPrimitive", .symbol).?, core.Descriptor.data(values[3], .all));
                    const target = core.Object.fromHeader(values[0].refHeader().?);
                    if (mode < 3) try target.defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(core.JSValue.int32(17), .all));
                    if (mode >= 5) try target.defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.accessor(values[2], values[2], .all));
                    probe.target = try rt.registerWeakObjectIdentity(target);
                    probe.accessor = try rt.registerWeakObjectIdentity(core.Object.fromHeader(values[2].refHeader().?));
                    break :setup [_]core.JSValue{ values[0], values[1], values[2] };
                };
                const result = switch (mode) {
                    0 => ops.objectHasOwnCall(ctx, null, global, inputs[0..2], null, null),
                    1, 2 => ops.objectPrototypeOwnPropertyCall(ctx, null, global, inputs[0], @intFromEnum(if (mode == 1) ops.PrototypeMethod.has_own_property else ops.PrototypeMethod.property_is_enumerable), inputs[1..2], null, null),
                    3, 4 => ops.objectPrototypeDefineAccessorCall(ctx, null, global, inputs[0], inputs[1..3], mode == 3, null, null),
                    7 => ops.getOwnPropertyDescriptorCall(ctx, null, global, inputs[0..2], null, null),
                    else => ops.objectPrototypeLookupAccessorCall(ctx, null, global, inputs[0], inputs[1..2], mode == 5, null, null),
                };
                if (probe.lost) return error.LostOwnPropertyConversionRoot;
                try require(probe.calls == 1 and rt.active_value_roots == null);
                if (fail) {
                    try require(if (result) |_| false else |err| err == error.OutOfMemory or err == error.JSException);
                } else {
                    const returned = (try result).?;
                    if (mode < 3) try require(returned.same(core.JSValue.boolean(true))) else {
                        const expected = rt.liveObjectFromWeakIdentity(probe.accessor).?.value();
                        if (mode == 7) {
                            const object = core.Object.fromHeader(returned.refHeader().?);
                            try require((try object.getProperty(core.atom.ids.get)).same(expected));
                            try require((try object.getProperty(core.atom.ids.set)).same(expected));
                        } else if (mode >= 5) try require(returned.same(expected)) else {
                            const desc = (try rt.liveObjectFromWeakIdentity(probe.target).?.getOwnProperty(rt, core.atom.ids.name)).?;
                            try require((if (mode == 3) desc.getter else desc.setter).same(expected));
                        }
                    }
                }
            }
        }
    }
}

fn verifyObjectAssignRoots() !void {
    const Probe = struct {
        owner: core.property.AutoInitModuleOwner = .{ .resolve = resolve },
        target: usize = 0,
        source: usize = 0,
        later: usize = 0,
        key: core.Atom,
        direct: bool,
        fail: bool,
        lost: bool = false,
        fn resolve(owner: *const core.property.AutoInitModuleOwner, realm_header: *core.gc.Header, _: core.Atom) anyerror!core.property.AutoInitMaterialization {
            const self: *@This() = @constCast(@fieldParentPtr("owner", owner));
            const ctx: *core.JSContext = @alignCast(@fieldParentPtr("header", realm_header));
            const rt = ctx.runtime;
            try require(rt.liveObjectFromWeakIdentity(self.source).?.deleteProperty(rt, self.key));
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            self.lost = rt.liveObjectFromWeakIdentity(self.target) == null or (!self.direct and rt.liveObjectFromWeakIdentity(self.later) == null) or rt.atoms.name(self.key) == null;
            if (self.lost or self.fail) return error.OutOfMemory;
            return .{ .value = core.JSValue.int32(17) };
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |direct| {
            for ([_]bool{ false, true }) |fail| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const ctx = try core.JSContext.create(rt, .{});
                defer ctx.destroy();
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                var probe = Probe{ .key = try rt.internAtom("assignLaterBoundaryKey"), .direct = direct, .fail = fail };
                const inputs = setup: {
                    var values = [_]core.JSValue{core.JSValue.undefinedValue()} ** 3;
                    const live: []core.JSValue = &values;
                    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &live }};
                    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
                    roots.activate(rt);
                    defer roots.deactivate(rt);
                    for (&values) |*value| value.* = (try core.Object.createPlainObject(rt, null)).value();
                    const source = core.Object.fromHeader(values[1].refHeader().?);
                    try source.defineModuleAutoInitPropertyForFixture(rt, core.atom.ids.name, core.property.Flags.data(.all), ctx, &probe.owner);
                    try source.defineOwnProperty(rt, probe.key, core.Descriptor.data(core.JSValue.int32(23), .all));
                    try core.Object.fromHeader(values[2].refHeader().?).defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(42), .all));
                    probe.target = try rt.registerWeakObjectIdentity(core.Object.fromHeader(values[0].refHeader().?));
                    probe.source = try rt.registerWeakObjectIdentity(source);
                    probe.later = try rt.registerWeakObjectIdentity(core.Object.fromHeader(values[2].refHeader().?));
                    break :setup values;
                };
                const result: anyerror!void = if (direct) direct_call: {
                    const keys = [_]core.Atom{ core.atom.ids.name, probe.key };
                    break :direct_call zjs.exec.object_ops.objectAssignKeys(ctx, null, global, inputs[0], inputs[1], core.Object.fromHeader(inputs[1].refHeader().?), &keys, null, null, null);
                } else assign_call: {
                    _ = zjs.exec.object_ops.objectAssignCall(ctx, null, global, &inputs, null, null) catch |err| break :assign_call err;
                    break :assign_call {};
                };
                if (probe.lost) return error.LostObjectAssignRoot;
                try require(rt.active_value_roots == null);
                if (fail) {
                    try require(if (result) |_| false else |err| err == error.OutOfMemory);
                } else {
                    try result;
                    const target = rt.liveObjectFromWeakIdentity(probe.target).?;
                    try require((try target.getProperty(core.atom.ids.name)).same(core.JSValue.int32(17)));
                    if (!direct) try require((try target.getProperty(core.atom.ids.length)).same(core.JSValue.int32(42)));
                }
            }
        }
    }
}

fn verifyArrayLengthConversionRoots() !void {
    const Probe = struct {
        rt: *core.JSRuntime,
        original_retry: *const fn (*anyopaque) void,
        original_context: *anyopaque,
        minor_error: ?anyerror = null,
        moved: bool = false,
        calls: usize = 0,
        identity: usize = 0,
        lost: bool = false,
        failure: usize,
        fn retry(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            // Exercise a minor/major sequence at hint-string admission. Keep
            // the normal retry and heap-limit enforcement after the minor.
            const before = self.rt.liveObjectFromWeakIdentity(self.identity).?;
            _ = core.gc_trace_stw.collectMinor(self.rt, null, .declared_only) catch |err| {
                self.minor_error = err;
                return;
            };
            const after = self.rt.liveObjectFromWeakIdentity(self.identity);
            self.moved = self.moved or (after != null and before != after.?);
            self.original_retry(self.original_context);
            const retried = self.rt.liveObjectFromWeakIdentity(self.identity);
            self.moved = self.moved or (retried != null and before != retried.?);
        }
        fn thunk(ctx: *core.JSContext, receiver: core.JSValue, _: [*]const core.JSValue, _: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            self.calls += 1;
            const live = ctx.runtime.liveObjectFromWeakIdentity(self.identity);
            self.lost = live == null or !live.?.value().same(receiver);
            if (self.lost or self.calls == self.failure) return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, error.OutOfMemory);
            return core.JSValue.int32(17);
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for (0..4) |budget| {
            for (0..3) |failure| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const ctx = try core.JSContext.create(rt, .{});
                defer ctx.destroy();
                defer ctx.clearException();
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
                var probe = Probe{ .failure = failure, .rt = rt, .original_retry = rt.gc.heap_budget.retry.?, .original_context = rt.gc.heap_budget.retry_ctx.? };
                var method = try core.JSValueHandle.init(rt, try core.function.nativeFunction(ctx, "lengthConversion", 1));
                defer method.deinit();
                const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.thunk), .kind = .managed, .state = &probe });
                core.Object.fromHeader(method.get().refHeader().?).installNativeEntry(entry);
                _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                const source = try core.Object.createPlainObject(rt, null);
                try source.defineOwnProperty(rt, core.atom.predefinedId("Symbol.toPrimitive", .symbol).?, core.Descriptor.data(method.get(), .all));
                probe.identity = try rt.registerWeakObjectIdentity(source);
                // Admission can reclaim this unrooted string and then succeed.
                _ = try core.string.String.createAscii(rt, &([_]u8{'x'} ** 8192));
                if (budget != 0) rt.setMemoryLimit(if (budget == 1) 0 else rt.gc.heap_budget.bytes);
                if (budget == 3) {
                    rt.gc.heap_budget.retry = Probe.retry;
                    rt.gc.heap_budget.retry_ctx = &probe;
                }
                const result = zjs.exec.array_ops.arrayLengthDefineValue(ctx, null, global, source.value());
                rt.gc.heap_budget.retry = probe.original_retry;
                rt.gc.heap_budget.retry_ctx = probe.original_context;
                rt.setMemoryLimit(null);
                if (probe.minor_error) |err| return err;
                if (budget == 3 and nursery and !probe.moved) return error.ArrayLengthFixtureDidNotMove;
                if (probe.lost) return error.LostArrayLengthConversionReceiver;
                if (budget == 1 or failure != 0) {
                    try require(if (result) |_| false else |err| err == error.OutOfMemory or err == error.JSException);
                    try require(probe.calls == if (budget == 1) @as(usize, 0) else failure);
                } else {
                    const returned = result catch return error.ArrayLengthConversionFailedAfterGc;
                    try require(returned.same(core.JSValue.int32(17)));
                    try require(probe.calls == 2);
                }
                try require(rt.active_value_roots == null);
            }
        }
    }
}

fn verifyBulkDescriptorRoots() !void {
    const Probe = struct {
        owner: core.property.AutoInitModuleOwner = .{ .resolve = resolve },
        target: usize = 0,
        properties: usize = 0,
        incoming: usize = 0,
        fail: bool,
        lost: bool = false,
        calls: usize = 0,
        fn resolve(owner: *const core.property.AutoInitModuleOwner, realm_header: *core.gc.Header, _: core.Atom) anyerror!core.property.AutoInitMaterialization {
            const self: *@This() = @constCast(@fieldParentPtr("owner", owner));
            const ctx: *core.JSContext = @alignCast(@fieldParentPtr("header", realm_header));
            const rt = ctx.runtime;
            const properties = rt.liveObjectFromWeakIdentity(self.properties).?;
            try require(properties.deleteProperty(rt, core.atom.ids.name));
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            self.calls += 1;
            self.lost = rt.liveObjectFromWeakIdentity(self.target) == null or rt.liveObjectFromWeakIdentity(self.incoming) == null;
            if (self.lost or self.fail) return error.OutOfMemory;
            var descriptor = try core.JSValueHandle.init(rt, (try core.Object.createPlainObject(rt, null)).value());
            defer descriptor.deinit();
            try core.Object.fromHeader(descriptor.get().refHeader().?).defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.data(core.JSValue.int32(42), .all));
            return .{ .value = descriptor.get() };
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |fail| {
            const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer rt.destroy();
            rt.gc.nursery.enabled = nursery;
            rt.gc.scheduler.host_quiescent = true;
            const ctx = try core.JSContext.create(rt, .{});
            defer ctx.destroy();
            const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
            var probe = Probe{ .fail = fail };
            const inputs = setup: {
                var values = [_]core.JSValue{core.JSValue.undefinedValue()} ** 4;
                const live: []core.JSValue = &values;
                const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &live }};
                var roots = core.runtime.ValueRootFrame{ .slices = &slices };
                roots.activate(rt);
                defer roots.deactivate(rt);
                for (&values) |*value| value.* = (try core.Object.createPlainObject(rt, null)).value();
                try core.Object.fromHeader(values[2].refHeader().?).defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.data(values[3], .all));
                try core.Object.fromHeader(values[1].refHeader().?).defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(values[2], .all));
                try core.Object.fromHeader(values[1].refHeader().?).defineModuleAutoInitPropertyForFixture(rt, core.atom.ids.length, core.property.Flags.data(.all), ctx, &probe.owner);
                probe.target = try rt.registerWeakObjectIdentity(core.Object.fromHeader(values[0].refHeader().?));
                probe.properties = try rt.registerWeakObjectIdentity(core.Object.fromHeader(values[1].refHeader().?));
                probe.incoming = try rt.registerWeakObjectIdentity(core.Object.fromHeader(values[3].refHeader().?));
                break :setup [_]core.JSValue{ values[0], values[1] };
            };
            const result = zjs.exec.call_runtime.definePropertiesOnTarget(ctx, null, global, core.Object.fromHeader(inputs[0].refHeader().?), inputs[1], null, null);
            if (probe.lost) return error.LostBulkDescriptorRoot;
            try require(probe.calls == 1 and rt.active_value_roots == null);
            const target = rt.liveObjectFromWeakIdentity(probe.target) orelse return error.LostBulkDescriptorTarget;
            if (fail) {
                try require(if (result) |_| false else |err| err == error.OutOfMemory);
                try require((try target.getOwnProperty(rt, core.atom.ids.name)) == null);
            } else {
                try result;
                const incoming = rt.liveObjectFromWeakIdentity(probe.incoming).?;
                try require((try target.getProperty(core.atom.ids.name)).same(incoming.value()));
                try require((try target.getProperty(core.atom.ids.length)).same(core.JSValue.int32(42)));
            }
        }
    }
}

fn verifyDescriptorConversionRoots() !void {
    const Probe = struct {
        owner: core.property.AutoInitModuleOwner = .{ .resolve = resolve },
        descriptor: usize,
        incoming: usize,
        field: core.Atom,
        fail: bool,
        lost: bool = false,
        calls: usize = 0,
        fn resolve(owner: *const core.property.AutoInitModuleOwner, realm_header: *core.gc.Header, _: core.Atom) anyerror!core.property.AutoInitMaterialization {
            const self: *@This() = @constCast(@fieldParentPtr("owner", owner));
            const ctx: *core.JSContext = @alignCast(@fieldParentPtr("header", realm_header));
            const rt = ctx.runtime;
            const descriptor = rt.liveObjectFromWeakIdentity(self.descriptor).?;
            try require(descriptor.deleteProperty(rt, self.field));
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            self.calls += 1;
            self.lost = rt.liveObjectFromWeakIdentity(self.incoming) == null;
            if (self.lost or self.fail) return error.OutOfMemory;
            return .{ .value = if (self.field == core.atom.ids.value) core.JSValue.boolean(true) else core.JSValue.undefinedValue() };
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |accessor| {
            for ([_]bool{ false, true }) |fail| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const ctx = try core.JSContext.create(rt, .{});
                defer ctx.destroy();
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                var descriptor = try core.JSValueHandle.init(rt, (try core.Object.createPlainObject(rt, null)).value());
                defer descriptor.deinit();
                var target = try core.JSValueHandle.init(rt, (try core.Object.createPlainObject(rt, null)).value());
                defer target.deinit();
                const incoming = if (accessor) try core.function.nativeFunction(ctx, "descriptorGetter", 0) else (try core.Object.createPlainObject(rt, null)).value();
                var probe = Probe{
                    .descriptor = try rt.registerWeakObjectIdentity(core.Object.fromHeader(descriptor.get().refHeader().?)),
                    .incoming = try rt.registerWeakObjectIdentity(core.Object.fromHeader(incoming.refHeader().?)),
                    .field = if (accessor) core.atom.ids.get else core.atom.ids.value,
                    .fail = fail,
                };
                try core.Object.fromHeader(descriptor.get().refHeader().?).defineOwnProperty(rt, probe.field, core.Descriptor.data(incoming, .all));
                try core.Object.fromHeader(descriptor.get().refHeader().?).defineModuleAutoInitPropertyForFixture(rt, if (accessor) core.atom.ids.set else core.atom.ids.writable, core.property.Flags.data(.all), ctx, &probe.owner);
                const result = zjs.exec.object_ops.descriptorFromObject(ctx, null, global, descriptor.get(), core.Object.fromHeader(descriptor.get().refHeader().?), core.Object.fromHeader(target.get().refHeader().?), core.atom.ids.name, null, null);
                if (probe.lost) return error.LostDescriptorConversionValue;
                try require(probe.calls == 1 and rt.active_value_roots == null);
                if (fail) {
                    try require(if (result) |_| false else |err| err == error.OutOfMemory);
                } else {
                    const converted = try result;
                    const live = rt.liveObjectFromWeakIdentity(probe.incoming) orelse return error.LostDescriptorConversionValue;
                    try require((if (accessor) converted.getter else converted.value).same(live.value()));
                }
            }
        }
    }
}

fn verifyHeapLayoutProjections() !void {
    // These addresses are deliberately not heap allocations. Every operation
    // below must be an address projection, never a metadata/link-word read.
    const address: usize = 0x1000;
    const reference: core.JSValue.HeapRef = @ptrFromInt(address);
    inline for ([_]core.JSValue.Kind{ .symbol, .string, .string_rope, .big_int, .module, .function_bytecode, .object }) |kind| {
        const value = core.JSValue.fromHeapReference(kind, reference);
        try require(@intFromPtr(value.as(kind).?) == address);
        try require(@intFromPtr(value.cycleMarkHeader().?) == address);
        try require(value.heapReference().? == reference);
        switch (kind) {
            .symbol => try require(@intFromPtr(value.asSymbolBody().?) == address),
            .string => {
                try require(@intFromPtr(value.asStringBodyRaw().?) == address);
                try require(@intFromPtr(value.stringHeader().?) == address);
                try require(@intFromPtr(value.stringHeaderAssumeStringLike()) == address);
            },
            .string_rope => {
                try require(@intFromPtr(value.ropeBody().?) == address);
                try require(@intFromPtr(value.stringHeader().?) == address);
                try require(@intFromPtr(value.stringHeaderAssumeStringLike()) == address);
            },
            .big_int => {
                try require(@intFromPtr(value.refHeader().?) == address);
            },
            .module => try require(@intFromPtr(value.refHeader().?) == address),
            .function_bytecode => try require(@intFromPtr(value.functionBytecodeHeader().?) == address),
            .object => {
                try require(@intFromPtr(value.refHeader().?) == address);
                try require(@intFromPtr(value.refHeaderAssumeObject()) == address);
            },
            else => unreachable,
        }
    }
    const empty = core.JSValue.undefinedValue();
    try require(empty.asSymbolBody() == null and empty.asStringBodyRaw() == null and empty.ropeBody() == null);
    try require(empty.refHeader() == null and empty.stringHeader() == null and empty.functionBytecodeHeader() == null);
    const null_payload = core.JSValue{ .bits = core.JSValue.fromHeapReference(.object, reference).bits & ~@as(u64, 0x0000_ffff_ffff_ffff) };
    try require(null_payload.refHeader() == null);
}

fn verifyNativeMethodTableRoots() !void {
    try verifyNativeMethodTableRootsMode(true);
    try verifyNativeMethodTableRootsMode(false);
}

fn verifyNativeMethodTableRootsMode(comptime reserve_only: bool) !void {
    const methods = comptime build: {
        var entries: [16]core.property.AutoInit = undefined;
        for (&entries, 0..) |*entry, i| entry.* = .{ .name = std.fmt.comptimePrint("boundaryMethod{d}", .{i}), .length = 0 };
        break :build entries;
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]?usize{ null, 0, 128, 512, 2048, 8192 }) |budget| {
            const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer rt.destroy();
            rt.gc.nursery.enabled = nursery;
            rt.gc.scheduler.host_quiescent = true;
            const ctx = try core.JSContext.create(rt, .{});
            defer ctx.destroy();
            _ = try zjs.exec.zjs_vm.contextGlobal(ctx);
            const target_value = try core.function.nativeFunction(ctx, "methodTableOwner", 0);
            const target = core.Object.fromHeader(target_value.refHeader().?);
            try target.defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.data(core.JSValue.int32(99), .all));
            const identity = try rt.registerWeakObjectIdentity(target);
            if (budget) |extra| rt.setMemoryLimit(if (extra == 0) 0 else rt.gc.heap_budget.bytes + extra);
            rt.gc.heap_budget.gc_threshold = 0;
            const result = if (reserve_only)
                target.reserveOwnPropertyCapacityAssumingPlain(rt, target.shape_ref.prop_count + methods.len)
            else
                zjs.exec.standard_globals.defineNativeMethodsAssumingNew(rt, target, &methods);
            rt.setMemoryLimit(std.math.maxInt(usize));
            rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
            const live = rt.liveObjectFromWeakIdentity(identity) orelse return error.LostNativeMethodTableOwner;
            var kept = try core.JSValueHandle.init(rt, live.value());
            defer kept.deinit();
            try require(rt.active_value_roots == null);
            const installed = live.shape_ref.prop_count - 3;
            try require(installed <= methods.len);
            if (result) |_| {
                try require(budget != 0);
            } else |err| {
                try require(budget != null and err == error.OutOfMemory);
                // Bulk installation commits one property at a time. Resume
                // only the uncommitted suffix, preserving the new-key contract.
                _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            }
            if (installed < methods.len) try zjs.exec.standard_globals.defineNativeMethodsAssumingNew(rt, core.Object.fromHeader(kept.get().refHeader().?), methods[installed..]);
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            try require((try core.Object.fromHeader(kept.get().refHeader().?).getProperty(core.atom.ids.value)).same(core.JSValue.int32(99)));
            for (methods) |entry| {
                const key = try rt.internAtom(entry.name);
                const value = try core.Object.fromHeader(kept.get().refHeader().?).getProperty(key);
                try require(zjs.exec.call_runtime.isCallableValue(value));
                const name = try core.Object.fromHeader(value.refHeader().?).getProperty(core.atom.ids.name);
                try require(zjs.exec.string_ops.stringValueUnitsEqualBytes(name, entry.name));
            }
            try require(rt.active_value_roots == null);
        }
    }
}

fn verifyNamespacePublicationRoots() !void {
    const cases = [_]struct { name: []const u8, key: core.Atom, methods: [2][]const u8 }{
        .{ .name = "Math", .key = core.atom.ids.Math, .methods = .{ "abs", "max" } },
        .{ .name = "JSON", .key = core.atom.ids.JSON, .methods = .{ "parse", "stringify" } },
        .{ .name = "Reflect", .key = core.atom.ids.Reflect, .methods = .{ "get", "ownKeys" } },
        .{ .name = "Atomics", .key = core.atom.ids.Atomics, .methods = .{ "load", "waitAsync" } },
    };
    for ([_]bool{ false, true }) |nursery| {
        for (cases) |case| {
            for ([_]?usize{ null, 0, 128, 512, 2048, 8192 }) |budget| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const ctx = try core.JSContext.create(rt, .{});
                defer ctx.destroy();
                var global = try core.JSValueHandle.init(rt, (try zjs.exec.zjs_vm.contextGlobal(ctx)).value());
                defer global.deinit();
                const owner = core.Object.fromHeader(global.get().refHeader().?);
                try require(owner.propKindAt(owner.findProperty(case.key).?) == .auto_init);
                if (budget) |extra| rt.setMemoryLimit(if (extra == 0) 0 else rt.gc.heap_budget.bytes + extra);
                rt.gc.heap_budget.gc_threshold = 0;
                var result = owner.getProperty(case.key);
                rt.setMemoryLimit(std.math.maxInt(usize));
                rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
                if (result) |_| {
                    try require(budget != 0);
                } else |err| {
                    try require(budget != null and err == error.OutOfMemory);
                    try require(rt.active_value_roots == null);
                    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                    const live = core.Object.fromHeader(global.get().refHeader().?);
                    try require(live.propKindAt(live.findProperty(case.key).?) == .auto_init);
                    result = live.getProperty(case.key);
                }
                var namespace = try core.JSValueHandle.init(rt, try result);
                defer namespace.deinit();
                _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                try require((try core.Object.fromHeader(global.get().refHeader().?).getProperty(case.key)).same(namespace.get()));
                for (case.methods) |name| {
                    const key = try rt.internAtom(name);
                    const method = try core.Object.fromHeader(namespace.get().refHeader().?).getProperty(key);
                    try require(zjs.exec.call_runtime.isCallableValue(method));
                }
                const tag = try core.Object.fromHeader(namespace.get().refHeader().?).getProperty(core.atom.predefinedId("Symbol.toStringTag", .symbol).?);
                try require(zjs.exec.string_ops.stringValueUnitsEqualBytes(tag, case.name));
                if (case.key == core.atom.ids.Math) {
                    const pi = try core.Object.fromHeader(namespace.get().refHeader().?).getProperty(core.atom.ids.PI);
                    try require(pi.asNumber().? == std.math.pi);
                }
                try require(rt.active_value_roots == null);
            }
        }
    }
}

fn verifyAutoInitBuilderRoots() !void {
    const infos = [_]core.property.AutoInit{
        .{ .name = "navigator", .length = 0, .kind = .navigator },
        .{ .name = "hostCtor", .length = 0, .host_function_kind = 1, .host_function_prototype = true },
        .{ .name = "performance", .length = 0, .kind = .performance },
        .{ .name = "unscopables", .length = 0, .kind = .array_unscopables },
    };
    for ([_]bool{ false, true }) |nursery| {
        for (0..5) |mode| {
            for ([_]?usize{ null, 0, 128, 512, 2048, 8192 }) |budget| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const ctx = try core.JSContext.create(rt, .{});
                defer ctx.destroy();
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                var target = try core.JSValueHandle.init(rt, try core.function.nativeFunction(ctx, "builderOwner", 0));
                defer target.deinit();
                const owner = core.Object.fromHeader(target.get().refHeader().?);
                const key = if (mode == 4) core.atom.ids.prototype else core.atom.ids.value;
                if (mode == 4)
                    try owner.defineFunctionPrototypeAutoInit(rt, ctx, core.property.Flags.data(.all))
                else
                    try owner.defineAutoInitPropertyFromDescriptor(rt, key, core.property.Flags.data(.all), global, &infos[mode]);
                if (budget) |extra| rt.setMemoryLimit(if (extra == 0) 0 else rt.gc.heap_budget.bytes + extra);
                rt.gc.heap_budget.gc_threshold = 0;
                var result = owner.getProperty(key);
                rt.setMemoryLimit(std.math.maxInt(usize));
                rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
                if (result) |_| {
                    try require(budget != 0);
                } else |err| {
                    try require(budget != null and err == error.OutOfMemory);
                    try require(rt.active_value_roots == null);
                    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                    result = core.Object.fromHeader(target.get().refHeader().?).getProperty(key);
                }
                var kept = try core.JSValueHandle.init(rt, try result);
                defer kept.deinit();
                _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                const value = kept.get();
                const object = core.Object.fromHeader(value.refHeader().?);
                try require((try core.Object.fromHeader(target.get().refHeader().?).getProperty(key)).same(value));
                switch (mode) {
                    0 => {
                        const prototype = object.getPrototype().?;
                        const getter = (try prototype.getOwnProperty(rt, core.atom.ids.userAgent)).?.getter;
                        try require(zjs.exec.call_runtime.isCallableValue(getter));
                        const tag = try object.getProperty(core.atom.predefinedId("Symbol.toStringTag", .symbol).?);
                        try require(zjs.exec.string_ops.stringValueUnitsEqualBytes(tag, "Navigator"));
                    },
                    1 => {
                        try require(zjs.exec.call_runtime.isCallableValue(value));
                        try require((try object.getProperty(core.atom.ids.prototype)).is(.object));
                        try require(object.hostFunctionKindSlot().* == 1);
                    },
                    2 => {
                        try require(zjs.exec.call_runtime.isCallableValue(try object.getProperty(core.atom.predefinedId("now", .string).?)));
                        try require((try object.getProperty(core.atom.predefinedId("timeOrigin", .string).?)).asNumber() != null);
                    },
                    3 => for ([_][]const u8{ "at", "copyWithin", "find", "findIndex", "findLast", "findLastIndex", "flat", "flatMap", "includes", "keys", "toReversed", "toSorted", "toSpliced", "values" }) |name| {
                        try require((try object.getProperty(try rt.internAtom(name))).same(core.JSValue.boolean(true)));
                    },
                    4 => try require((try object.getProperty(core.atom.ids.constructor)).same(target.get())),
                    else => unreachable,
                }
                try require(rt.active_value_roots == null);
            }
        }
    }
}

fn verifyAutoInitNativePreparationRoots() !void {
    const Probe = struct {
        var active: *@This() = undefined;
        target: usize = 0,
        produced: usize = 0,
        calls: usize = 0,
        fail: bool,
        lost: bool = false,
        fn prepare(rt: *core.JSRuntime, _: *const core.property.AutoInit, value: core.JSValue) anyerror!void {
            const self = active;
            self.produced = try rt.registerWeakObjectIdentity(core.Object.fromHeader(value.refHeader().?));
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            self.calls += 1;
            self.lost = rt.liveObjectFromWeakIdentity(self.target) == null or rt.liveObjectFromWeakIdentity(self.produced) == null;
            if (self.fail or self.lost) return error.OutOfMemory;
        }
    };
    const info = core.property.AutoInit{ .name = "prepared", .length = 0, .prepare_native_function = Probe.prepare };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |fail| {
            const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer rt.destroy();
            rt.gc.nursery.enabled = nursery;
            rt.gc.scheduler.host_quiescent = true;
            const ctx = try core.JSContext.create(rt, .{});
            defer ctx.destroy();
            const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
            var probe = Probe{ .fail = fail };
            Probe.active = &probe;
            const object = try core.Object.create(rt, core.class.ids.object, null);
            try object.defineAutoInitPropertyFromDescriptor(rt, core.atom.ids.name, core.property.Flags.data(.all), global, &info);
            probe.target = try rt.registerWeakObjectIdentity(object);
            var result = object.getProperty(core.atom.ids.name);
            if (probe.lost) return error.LostAutoInitNativePreparationRoot;
            try require(probe.calls == 1 and rt.active_value_roots == null);
            if (fail) {
                try require(if (result) |_| false else |err| err == error.OutOfMemory);
                probe.fail = false;
                result = object.getProperty(core.atom.ids.name);
                try require(probe.calls == 2 and !probe.lost);
            }
            var kept = try core.JSValueHandle.init(rt, try result);
            defer kept.deinit();
            try require(zjs.exec.call_runtime.isCallableValue(kept.get()));
            try require((try object.getProperty(core.atom.ids.name)).same(kept.get()));
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            try require(rt.liveObjectFromWeakIdentity(probe.target) == null);
            const produced = rt.liveObjectFromWeakIdentity(probe.produced) orelse return error.LostAutoInitNativeResult;
            try require(kept.get().same(produced.value()));
            try require(rt.active_value_roots == null);
        }
    }
}

fn verifyAutoInitReadRoots() !void {
    const Probe = struct {
        owner: core.property.AutoInitModuleOwner = .{ .resolve = resolve },
        target: usize = 0,
        produced: usize = 0,
        calls: usize = 0,
        cell: bool,
        fail: bool,
        replace: bool,
        lost: bool = false,
        fn resolve(owner: *const core.property.AutoInitModuleOwner, realm_header: *core.gc.Header, key: core.Atom) anyerror!core.property.AutoInitMaterialization {
            const self: *@This() = @constCast(@fieldParentPtr("owner", owner));
            const ctx: *core.JSContext = @alignCast(@fieldParentPtr("header", realm_header));
            const rt = ctx.runtime;
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            self.calls += 1;
            self.lost = rt.liveObjectFromWeakIdentity(self.target) == null;
            if (self.lost or self.fail) return error.OutOfMemory;
            if (self.replace) {
                const target = rt.liveObjectFromWeakIdentity(self.target).?;
                try require(target.deleteProperty(rt, key));
                // Neither the placeholder nor its atom is reachable from the
                // target now. The in-flight transaction must still name both.
                _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                try target.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(99), .all));
            }
            var result = try core.JSValueHandle.init(rt, (try core.Object.create(rt, core.class.ids.object, null)).value());
            defer result.deinit();
            self.produced = try rt.registerWeakObjectIdentity(core.Object.fromHeader(result.get().refHeader().?));
            if (self.cell) return .{ .var_ref = try core.var_ref.VarRef.createClosed(rt, result.get()) };
            return .{ .value = result.get() };
        }
        fn read(object: *core.Object, rt: *core.JSRuntime, key: core.Atom, descriptor_read: bool) !core.JSValue {
            return if (descriptor_read)
                (try object.getOwnProperty(rt, key)).?.value
            else
                try object.getProperty(key);
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |descriptor_read| {
            for ([_]bool{ false, true }) |cell| {
                for (0..3) |outcome| {
                    const fail = outcome == 1;
                    const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                    defer rt.destroy();
                    rt.gc.nursery.enabled = nursery;
                    rt.gc.scheduler.host_quiescent = true;
                    const ctx = try core.JSContext.create(rt, .{});
                    defer ctx.destroy();
                    var probe = Probe{ .cell = cell, .fail = fail, .replace = outcome == 2 };
                    const key = try rt.internAtom("boundaryLazyRead");
                    const object = try core.Object.create(rt, core.class.ids.object, null);
                    try object.defineModuleAutoInitPropertyForFixture(rt, key, core.property.Flags.data(.all), ctx, &probe.owner);
                    probe.target = try rt.registerWeakObjectIdentity(object);
                    var result = Probe.read(object, rt, key, descriptor_read);
                    if (probe.lost) return error.LostAutoInitReadTarget;
                    try require(probe.calls == 1 and rt.active_value_roots == null);
                    if (probe.replace) {
                        try require(if (result) |_| false else |err| err == error.IncompatibleDescriptor);
                        try require((try Probe.read(object, rt, key, descriptor_read)).same(core.JSValue.int32(99)));
                        _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                        try require(rt.liveObjectFromWeakIdentity(probe.target) == null);
                        try require(rt.liveObjectFromWeakIdentity(probe.produced) == null);
                        continue;
                    }
                    if (fail) {
                        try require(if (result) |_| false else |err| err == error.OutOfMemory);
                        probe.fail = false;
                        result = Probe.read(object, rt, key, descriptor_read);
                        try require(probe.calls == 2 and !probe.lost);
                    }
                    var kept = try core.JSValueHandle.init(rt, try result);
                    defer kept.deinit();
                    try require((try Probe.read(object, rt, key, descriptor_read)).same(kept.get()));
                    try require(probe.calls == if (fail) @as(usize, 2) else 1);
                    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                    try require(rt.liveObjectFromWeakIdentity(probe.target) == null);
                    const produced = rt.liveObjectFromWeakIdentity(probe.produced) orelse return error.LostAutoInitReadResult;
                    try require(kept.get().same(produced.value()));
                    try require(rt.active_value_roots == null);
                }
            }
        }
    }
}

fn verifyPropertyRedefinitionRoots() !void {
    const Probe = struct {
        owner: core.property.AutoInitModuleOwner = .{ .resolve = resolve },
        target: usize = 0,
        incoming: usize = 0,
        calls: usize = 0,
        fail: bool,
        lost: bool = false,
        fn resolve(owner: *const core.property.AutoInitModuleOwner, realm_header: *core.gc.Header, _: core.Atom) anyerror!core.property.AutoInitMaterialization {
            const self: *@This() = @constCast(@fieldParentPtr("owner", owner));
            const ctx: *core.JSContext = @alignCast(@fieldParentPtr("header", realm_header));
            const rt = ctx.runtime;
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            self.calls += 1;
            self.lost = rt.liveObjectFromWeakIdentity(self.target) == null or rt.liveObjectFromWeakIdentity(self.incoming) == null;
            if (self.lost or self.fail) return error.OutOfMemory;
            return .{ .value = core.JSValue.int32(7) };
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for (0..4) |mode| {
            for ([_]bool{ false, true }) |fail| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const ctx = try core.JSContext.create(rt, .{});
                defer ctx.destroy();
                var probe = Probe{ .fail = fail };
                // Accessor fixtures use real native functions and therefore
                // need the Realm's standard Function prototype initialized.
                _ = try zjs.exec.zjs_vm.contextGlobal(ctx);
                const values = setup: {
                    var roots = core.runtime.ExactValueRoots(2){};
                    try roots.activate(rt);
                    defer roots.deactivate();
                    const target = try roots.ref(0);
                    const incoming = try roots.ref(1);
                    try target.set(rt, (try core.Object.create(rt, core.class.ids.object, null)).value());
                    try incoming.set(rt, if (mode < 2)
                        (try core.Object.create(rt, core.class.ids.object, null)).value()
                    else
                        try core.function.nativeFunction(ctx, "redefinitionAccessor", 0));
                    const object = core.Object.fromHeader((try target.get(rt)).refHeader().?);
                    try object.defineModuleAutoInitPropertyForFixture(rt, core.atom.ids.name, core.property.Flags.data(.all), ctx, &probe.owner);
                    probe.target = try rt.registerWeakObjectIdentity(object);
                    probe.incoming = try rt.registerWeakObjectIdentity(core.Object.fromHeader((try incoming.get(rt)).refHeader().?));
                    break :setup [_]core.JSValue{ try target.get(rt), try incoming.get(rt) };
                };
                const object = core.Object.fromHeader(values[0].refHeader().?);
                const desc = switch (mode) {
                    2 => core.Descriptor.accessor(values[1], core.JSValue.undefinedValue(), .all),
                    3 => core.Descriptor.accessor(core.JSValue.undefinedValue(), values[1], .all),
                    else => core.Descriptor.data(values[1], .all),
                };
                const result = if (mode == 0)
                    object.definePlainDataPropertyKnownFast(rt, core.atom.ids.name, values[1])
                else
                    object.defineOwnProperty(rt, core.atom.ids.name, desc);
                if (probe.lost) return error.LostPropertyRedefinitionRoot;
                try require(probe.calls == 1);
                try require(rt.active_value_roots == null);
                if (fail) {
                    try require(if (result) |_| false else |err| err == error.OutOfMemory);
                    probe.fail = false;
                    if (mode == 0)
                        try object.definePlainDataPropertyKnownFast(rt, core.atom.ids.name, values[1])
                    else
                        try object.defineOwnProperty(rt, core.atom.ids.name, desc);
                    try require(probe.calls == 2 and !probe.lost);
                } else try result;
                const live = rt.liveObjectFromWeakIdentity(probe.target) orelse return error.LostPropertyRedefinitionTarget;
                const incoming = rt.liveObjectFromWeakIdentity(probe.incoming) orelse return error.LostPropertyRedefinitionValue;
                const installed = (try live.getOwnProperty(rt, core.atom.ids.name)).?;
                const installed_value = switch (mode) {
                    2 => installed.getter,
                    3 => installed.setter,
                    else => installed.value,
                };
                try require(installed_value.same(incoming.value()));
                try require(rt.active_value_roots == null);
            }
        }
    }
}

fn verifyNamedNativePublicationRoots() !void {
    for ([_]bool{ false, true }) |nursery| {
        for ([_]?usize{ null, 0, 1024, 4096 }) |budget| {
            const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer rt.destroy();
            rt.gc.nursery.enabled = nursery;
            rt.gc.scheduler.host_quiescent = true;
            const ctx = try core.JSContext.create(rt, .{});
            defer ctx.destroy();
            const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
            if (budget) |extra| rt.setMemoryLimit(if (extra == 0) 0 else rt.gc.heap_budget.bytes + extra);
            rt.gc.heap_budget.gc_threshold = 0;
            var result = zjs.exec.object_ops.callSitePrototypeFromGlobal(rt, global);
            rt.setMemoryLimit(std.math.maxInt(usize));
            rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
            if (result) |_| {
                if (budget == 0) return error.ExpectedNamedNativeAllocationFailure;
            } else |err| {
                try require(budget != null and err == error.OutOfMemory);
                try require(rt.active_value_roots == null);
                _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                try require(global.cachedRealmValue(rt, .callsite_prototype) == null);
                // A failed partial publication must also permit a clean retry.
                result = zjs.exec.object_ops.callSitePrototypeFromGlobal(rt, global);
            }
            var kept = try core.JSValueHandle.init(rt, (try result).value());
            defer kept.deinit();
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            const object = core.Object.fromHeader(kept.get().refHeader().?);
            const methods = [_]struct { name: []const u8, id: core.function.HostGlobalMethod }{
                .{ .name = "getFunction", .id = .callsite_get_function },
                .{ .name = "getFunctionName", .id = .callsite_get_function_name },
                .{ .name = "getFileName", .id = .callsite_get_file_name },
                .{ .name = "getLineNumber", .id = .callsite_get_line_number },
                .{ .name = "getColumnNumber", .id = .callsite_get_column_number },
                .{ .name = "isNative", .id = .callsite_is_native },
            };
            for (methods) |expected| {
                const method = try object.getProperty(try rt.internAtom(expected.name));
                try require(zjs.exec.call_runtime.isCallableValue(method));
                const function = core.Object.fromHeader(method.refHeader().?);
                try require(function.nativeFunctionId() == core.function.nativeBuiltinId(.host, @intFromEnum(expected.id)));
                try require((try function.getProperty(core.atom.ids.length)).same(core.JSValue.int32(0)));
                try require(zjs.exec.string_ops.stringValueUnitsEqualBytes(try function.getProperty(core.atom.ids.name), expected.name));
            }
            try require(try zjs.exec.object_ops.callSitePrototypeFromGlobal(rt, global) == object);
            try require(rt.active_value_roots == null);
        }
    }
}

fn verifyIteratorFromRoots() !void {
    const Probe = struct {
        failure: i32,
        iterator: ?usize = null,
        seen: u32 = 0,
        fn thunk(ctx: *core.JSContext, _: core.JSValue, args: [*]const core.JSValue, argc: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            const stage = args[0].as(.int).?;
            if (stage == 0 and argc == 2) {
                self.iterator = ctx.runtime.registerWeakObjectIdentity(core.Object.fromHeader(args[1].refHeader().?)) catch |err| return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
                return core.JSValue.undefinedValue();
            }
            self.seen |= @as(u32, 1) << @intCast(stage);
            _ = ctx.runtime.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only) catch |err| return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
            if (stage == self.failure) return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, error.OutOfMemory);
            if (stage == 3) ctx.runtime.gc.heap_budget.gc_threshold = 0;
            return core.JSValue.undefinedValue();
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |warm| {
            for ([_]i32{ 0, 1, 2, 3, 4, 5 }) |failure| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const context = try zjs.Context.create(rt, .{});
                defer context.destroy();
                const ctx = context.core;
                defer ctx.clearException();
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
                if (warm) _ = try zjs.exec.object_ops.wrapForValidIteratorPrototype(rt, global);
                var probe = Probe{ .failure = failure };
                var callback = try core.JSValueHandle.init(rt, try core.function.nativeFunction(ctx, "fromBoundaryGc", 2));
                defer callback.deinit();
                const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.thunk), .kind = .managed, .state = &probe });
                core.Object.fromHeader(callback.get().refHeader().?).installNativeEntry(entry);
                try global.defineOwnProperty(rt, try rt.internAtom("fromBoundaryGc"), core.Descriptor.data(callback.get(), .all));
                var source = try core.JSValueHandle.init(rt, try context.eval("({get [Symbol.iterator]() {fromBoundaryGc(1); return function() {fromBoundaryGc(2); return {marker:42, get next() {fromBoundaryGc(0,this); fromBoundaryGc(3); return function() {fromBoundaryGc(5); return {value:this.marker,done:false};};}, get return() {fromBoundaryGc(4); return function() {return {value:this.marker,done:true};};}};};}})", .{}));
                defer source.deinit();
                const result: anyerror!void = exercise: {
                    const value = zjs.exec.iterator_ops.iteratorFromCall(ctx, null, global, &.{source.get()}, null, null) catch |err| break :exercise err;
                    var wrapper = core.JSValueHandle.init(rt, value) catch |err| break :exercise err;
                    defer wrapper.deinit();
                    rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
                    const owner = core.Object.fromHeader(wrapper.get().refHeader().?);
                    const target = rt.liveObjectFromWeakIdentity(probe.iterator.?) orelse break :exercise error.LostIteratorFromTarget;
                    try require(owner.iteratorTargetSlot().*.?.same(target.value()));
                    const next_method = try owner.getProperty(core.atom.ids.next);
                    const next = zjs.exec.iterator_ops.iteratorWrapNext(ctx, null, global, wrapper.get(), core.Object.fromHeader(next_method.refHeader().?), null, null) catch |err| break :exercise err;
                    try require((try core.Object.fromHeader(next.?.refHeader().?).getProperty(core.atom.ids.value)).same(core.JSValue.int32(42)));
                    const return_method = try core.Object.fromHeader(wrapper.get().refHeader().?).getProperty(core.atom.ids.return_);
                    const returned = zjs.exec.iterator_ops.iteratorWrapReturn(ctx, null, global, wrapper.get(), core.Object.fromHeader(return_method.refHeader().?), null, null) catch |err| break :exercise err;
                    try require((try core.Object.fromHeader(returned.?.refHeader().?).getProperty(core.atom.ids.value)).same(core.JSValue.int32(42)));
                    break :exercise {};
                };
                if (failure != 0) {
                    if (result) |_| return error.ExpectedIteratorFromFailure else |err| try require(err == error.OutOfMemory or err == error.JSException);
                    try require(probe.seen & (@as(u32, 1) << @intCast(failure)) != 0);
                } else try result;
                try require(rt.active_value_roots == null);
            }
        }
    }
}

fn verifySpreadDenseRoots() !void {
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |alias| {
            const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer rt.destroy();
            rt.gc.nursery.enabled = nursery;
            rt.gc.scheduler.host_quiescent = true;
            const context = try zjs.Context.create(rt, .{});
            defer context.destroy();
            const ctx = context.core;
            const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
            rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
            var source = try core.JSValueHandle.init(rt, try context.eval("Array.from({length:128}, (_,i)=>({n:i}))", .{}));
            defer source.deinit();
            const target = if (alias) core.Object.fromHeader(source.get().refHeader().?) else try core.Object.createArray(rt, null);
            const identity = try rt.registerWeakObjectIdentity(target);
            const start: i32 = if (alias) 128 else 0;
            rt.gc.heap_budget.gc_threshold = 0;
            const index = try zjs.exec.call_runtime.appendSpreadValuesEnumerate(ctx, null, global, target, source.get(), start);
            rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
            try require(index == start + 128);
            var kept = try core.JSValueHandle.init(rt, (rt.liveObjectFromWeakIdentity(identity) orelse return error.LostSpreadDenseTarget).value());
            defer kept.deinit();
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            const array = core.Object.fromHeader(kept.get().refHeader().?);
            const source_array = core.Object.fromHeader(source.get().refHeader().?);
            const n = try rt.internAtom("n");
            try require(array.arrayLength() == @as(u32, @intCast(start + 128)));
            for (0..128) |offset| {
                const expected = try source_array.getProperty(core.Atom.taggedInt(@intCast(offset)));
                const value = try array.getProperty(core.Atom.taggedInt(@as(u32, @intCast(start)) + @as(u32, @intCast(offset))));
                try require(value.same(expected));
                try require((try core.Object.fromHeader(value.refHeader().?).getProperty(n)).as(.int).? == @as(i32, @intCast(offset)));
            }
            try require(rt.active_value_roots == null);
        }
    }
}

fn verifyIteratorAppendRoots() !void {
    const Probe = struct {
        failure: i32,
        target: usize = 0,
        lost: bool = false,
        seen: u32 = 0,
        next_gets: usize = 0,
        fn thunk(ctx: *core.JSContext, _: core.JSValue, args: [*]const core.JSValue, _: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            const stage = args[0].as(.int).?;
            self.seen |= @as(u32, 1) << @intCast(stage);
            if (stage == 3) self.next_gets += 1;
            _ = ctx.runtime.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only) catch |err| return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
            if (ctx.runtime.liveObjectFromWeakIdentity(self.target) == null) self.lost = true;
            if (self.lost or stage == self.failure) return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, error.OutOfMemory);
            return core.JSValue.undefinedValue();
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |spread| {
            for ([_]i32{ 0, 1, 2, 3, 4 }) |failure| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const context = try zjs.Context.create(rt, .{});
                defer context.destroy();
                const ctx = context.core;
                defer ctx.clearException();
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
                var probe = Probe{ .failure = failure };
                var callback = try core.JSValueHandle.init(rt, try core.function.nativeFunction(ctx, "appendBoundaryGc", 1));
                defer callback.deinit();
                const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.thunk), .kind = .managed, .state = &probe });
                core.Object.fromHeader(callback.get().refHeader().?).installNativeEntry(entry);
                try global.defineOwnProperty(rt, try rt.internAtom("appendBoundaryGc"), core.Descriptor.data(callback.get(), .all));
                var source = try core.JSValueHandle.init(rt, try context.eval("({get [Symbol.iterator]() { appendBoundaryGc(1); return function() { appendBoundaryGc(2); let i=0; return {get next() {appendBoundaryGc(3); return function() {appendBoundaryGc(4); return {done:i>=2,value:{n:++i}};};}};};}})", .{}));
                defer source.deinit();
                const target = try core.Object.createArray(rt, null);
                try target.defineOwnProperty(rt, core.Atom.taggedInt(0), core.Descriptor.data(core.JSValue.int32(99), .all));
                probe.target = try rt.registerWeakObjectIdentity(target);
                const result = if (spread)
                    zjs.exec.call_runtime.appendSpreadValuesEnumerate(ctx, null, global, target, source.get(), 1)
                else
                    zjs.exec.call_runtime.appendIteratorValues(ctx, null, global, target, source.get(), 1);
                if (probe.lost) return error.LostIteratorAppendTarget;
                if (failure != 0) {
                    if (result) |_| return error.ExpectedIteratorAppendFailure else |err| try require(err == error.OutOfMemory or err == error.JSException);
                    try require(probe.seen & (@as(u32, 1) << @intCast(failure)) != 0);
                } else {
                    try require(try result == 3);
                    const array = rt.liveObjectFromWeakIdentity(probe.target) orelse return error.LostIteratorAppendTarget;
                    try require((try array.getProperty(core.Atom.taggedInt(0))).as(.int).? == 99);
                    for (1..3) |index| {
                        const value = try array.getProperty(core.Atom.taggedInt(@intCast(index)));
                        try require((try core.Object.fromHeader(value.refHeader().?).getProperty(try rt.internAtom("n"))).as(.int).? == @as(i32, @intCast(index)));
                    }
                    try require(probe.next_gets == (if (spread) @as(usize, 1) else 3));
                }
                try require(rt.active_value_roots == null);
            }
        }
    }
}

fn verifyIteratorStepRoots() !void {
    const Probe = struct {
        failure: i32,
        argument: ?usize = null,
        step: ?usize = null,
        original_step: ?*core.gc.Header = null,
        moved: bool = false,
        lost: bool = false,
        seen: u32 = 0,
        fn thunk(ctx: *core.JSContext, _: core.JSValue, args: [*]const core.JSValue, argc: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            const stage = args[0].as(.int).?;
            if (stage == 0 and argc == 2) {
                self.original_step = args[1].refHeader().?;
                self.step = ctx.runtime.registerWeakObjectIdentity(core.Object.fromHeader(self.original_step.?)) catch |err| return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
                return core.JSValue.undefinedValue();
            }
            self.seen |= @as(u32, 1) << @intCast(stage);
            _ = ctx.runtime.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only) catch |err| return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
            if (self.argument) |id| {
                if (stage <= 2 and ctx.runtime.liveObjectFromWeakIdentity(id) == null) self.lost = true;
            }
            if (self.step) |id| {
                if (ctx.runtime.liveObjectFromWeakIdentity(id)) |object| self.moved = self.moved or object.gcHeader() != self.original_step.? else self.lost = true;
            }
            if (self.lost or stage == self.failure) return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, error.OutOfMemory);
            return core.JSValue.undefinedValue();
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |record| {
            for ([_]bool{ false, true }) |done| {
                for ([_]i32{ 0, 1, 2, 3, 4 }) |failure| {
                    const reads_value = record == done;
                    if (failure == 4 and !reads_value) continue;
                    const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                    defer rt.destroy();
                    rt.gc.nursery.enabled = nursery;
                    rt.gc.scheduler.host_quiescent = true;
                    const context = try zjs.Context.create(rt, .{});
                    defer context.destroy();
                    const ctx = context.core;
                    defer ctx.clearException();
                    const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                    rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
                    var probe = Probe{ .failure = failure };
                    var callback = try core.JSValueHandle.init(rt, try core.function.nativeFunction(ctx, "stepBoundaryGc", 2));
                    defer callback.deinit();
                    const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.thunk), .kind = .managed, .state = &probe });
                    core.Object.fromHeader(callback.get().refHeader().?).installNativeEntry(entry);
                    try global.defineOwnProperty(rt, try rt.internAtom("stepBoundaryGc"), core.Descriptor.data(callback.get(), .all));
                    const script = try std.fmt.allocPrint(rt.nativeAllocator(), "(function(done) {{ return {{ get next() {{ stepBoundaryGc(1); return function(arg) {{ stepBoundaryGc(2); return {{ get done() {{ stepBoundaryGc(0,this); stepBoundaryGc(3); return done; }}, get value() {{ stepBoundaryGc(4); return 42; }} }}; }}; }} }}; }})({s})", .{if (done) "true" else "false"});
                    defer rt.nativeAllocator().free(script);
                    var iterator = try core.JSValueHandle.init(rt, try context.eval(script, .{}));
                    defer iterator.deinit();
                    var argument = core.JSValue.undefinedValue();
                    if (record) {
                        const object = try core.Object.createPlainObject(rt, null);
                        probe.argument = try rt.registerWeakObjectIdentity(object);
                        argument = object.value();
                    }
                    const result: anyerror!zjs.exec.iterator_ops.IteratorStepResult = if (record)
                        zjs.exec.iterator_ops.iteratorStepResult(ctx, null, global, iterator.get(), argument)
                    else blk: {
                        const step = zjs.exec.iterator_ops.iteratorStepValue(ctx, null, global, iterator.get()) catch |err| break :blk err;
                        break :blk .{ .result = core.JSValue.undefinedValue(), .value = step.value, .done = step.done };
                    };
                    if (probe.lost) return error.LostIteratorStepRoot;
                    if (failure != 0) {
                        if (result) |_| return error.ExpectedIteratorStepFailure else |err| try require(err == error.OutOfMemory or err == error.JSException);
                        try require(probe.seen & (@as(u32, 1) << @intCast(failure)) != 0);
                    } else {
                        const step = try result;
                        try require(step.done == done);
                        try require(step.value.same(if (reads_value) core.JSValue.int32(42) else core.JSValue.undefinedValue()));
                        try require((probe.seen & (1 << 4) != 0) == reads_value);
                        if (record) try require(step.result.same((rt.liveObjectFromWeakIdentity(probe.step.?) orelse return error.LostIteratorStepRoot).value()));
                        if (nursery and !probe.moved) return error.IteratorStepDidNotMove;
                    }
                    try require(rt.active_value_roots == null);
                }
            }
        }
    }
}

fn verifyZipCollectionRoots() !void {
    const Probe = struct {
        failure: i32,
        seen: u32 = 0,
        fn thunk(ctx: *core.JSContext, _: core.JSValue, args: [*]const core.JSValue, argc: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            if (argc != 1) return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, error.TypeError);
            const stage = args[0].as(.int).?;
            self.seen |= @as(u32, 1) << @intCast(stage);
            _ = ctx.runtime.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only) catch |err| return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
            if (stage == self.failure) return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, error.OutOfMemory);
            return core.JSValue.undefinedValue();
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |keyed| {
            for ([_]i32{ 0, 1, 2, 3, 4, 5, 6, 8, 9, 10, 11 }) |failure| {
                if ((!keyed and failure == 3) or (keyed and failure >= 8)) continue;
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const context = try zjs.Context.create(rt, .{});
                defer context.destroy();
                const ctx = context.core;
                defer ctx.clearException();
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
                var probe = Probe{ .failure = failure };
                var callback = try core.JSValueHandle.init(rt, try core.function.nativeFunction(ctx, "zipCollectGc", 1));
                defer callback.deinit();
                const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.thunk), .kind = .managed, .state = &probe });
                core.Object.fromHeader(callback.get().refHeader().?).installNativeEntry(entry);
                try global.defineOwnProperty(rt, try rt.internAtom("zipCollectGc"), core.Descriptor.data(callback.get(), .all));
                const source =
                    \\(function(keyed) {
                    \\  function input(n, limit) { let count = 0; return {
                    \\    get [Symbol.iterator]() { zipCollectGc(4); return function() { return this; }; },
                    \\    get next() { zipCollectGc(5); return function() { return {done: count++ >= limit, value: n}; }; },
                    \\    return() { zipCollectGc(7); return {}; }
                    \\  }; }
                    \\  function outer(items, padding) { return {get [Symbol.iterator]() { zipCollectGc(8); return function() {
                    \\    let i = 0; return { get next() { zipCollectGc(9); return function() { const index = i++; return {
                    \\      get done() {zipCollectGc(10); return index >= items.length;}, get value() {zipCollectGc(padding ? 6 : 11); return items[index];}
                    \\    }; }; }, return() {zipCollectGc(7); return {};} };
                    \\  }; } }; }
                    \\  const a = input(11, 0), b = input(22, 1);
                    \\  const inputs = keyed ? {get a() {zipCollectGc(3); return a;}, get b() {zipCollectGc(3); return b;}} : outer([a, b], false);
                    \\  const pads = keyed ? {get a() {zipCollectGc(6); return {n:101};}, get b() {zipCollectGc(6); return {n:102};}} : outer([{n:101}, {n:102}], true);
                    \\  return [inputs, {get mode() {zipCollectGc(1); return 'longest';}, get padding() {zipCollectGc(2); return pads;}}];
                    \\})(
                ;
                const script = try std.fmt.allocPrint(rt.nativeAllocator(), "{s}{s})", .{ source, if (keyed) "true" else "false" });
                defer rt.nativeAllocator().free(script);
                const args = setup: {
                    var bundle = try core.JSValueHandle.init(rt, context.eval(script, .{}) catch |err| {
                        std.debug.print("zip collection setup failed: {s}\n", .{@errorName(err)});
                        return err;
                    });
                    defer bundle.deinit();
                    const array = core.Object.fromHeader(bundle.get().refHeader().?);
                    break :setup [_]core.JSValue{ try array.getProperty(core.Atom.taggedInt(0)), try array.getProperty(core.Atom.taggedInt(1)) };
                };
                const result = zjs.exec.iterator_ops.iteratorZipCall(ctx, null, global, &args, keyed, null, null);
                if (failure == 0) _ = result catch |err| {
                    std.debug.print("zip collection failed: nursery={} keyed={} stages={x} error={s}\n", .{ nursery, keyed, probe.seen, @errorName(err) });
                    return err;
                };
                if (failure != 0) {
                    if (result) |_| return error.ExpectedZipCollectionFailure else |err| try require(err == error.OutOfMemory or err == error.JSException);
                    try require(probe.seen & (@as(u32, 1) << @intCast(failure)) != 0);
                } else {
                    var helper = try core.JSValueHandle.init(rt, try result);
                    defer helper.deinit();
                    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                    const next_method = try core.Object.fromHeader(helper.get().refHeader().?).getProperty(core.atom.ids.next);
                    const step = (try zjs.exec.iterator_ops.iteratorHelperNext(ctx, null, global, helper.get(), core.Object.fromHeader(next_method.refHeader().?), null, null)).?;
                    const row = core.Object.fromHeader((try core.Object.fromHeader(step.refHeader().?).getProperty(core.atom.ids.value)).refHeader().?);
                    const first = try row.getProperty(if (keyed) try rt.internAtom("a") else core.Atom.taggedInt(0));
                    try require((try core.Object.fromHeader(first.refHeader().?).getProperty(try rt.internAtom("n"))).as(.int).? == 101);
                    try require((try row.getProperty(if (keyed) try rt.internAtom("b") else core.Atom.taggedInt(1))).as(.int).? == 22);
                    const expected: u32 = ((1 << 1) | (1 << 2) | (1 << 4) | (1 << 5) | (1 << 6)) | (if (keyed) @as(u32, 1 << 3) else @as(u32, (1 << 8) | (1 << 9) | (1 << 10) | (1 << 11)));
                    try require(probe.seen & expected == expected);
                }
                try require(rt.active_value_roots == null);
            }
        }
    }
}

fn verifyConcatCreationRoots() !void {
    const Probe = struct {
        fn getMethod(ctx: *core.JSContext, _: ?*std.Io.Writer, global: *core.Object, value: core.JSValue) !core.JSValue {
            const fail = (try core.Object.fromHeader(value.refHeader().?).getProperty(core.atom.ids.done)).same(core.JSValue.boolean(true));
            _ = try ctx.runtime.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            if (fail) return error.OutOfMemory;
            return global.getProperty(core.atom.ids.next);
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |fail| {
            const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer rt.destroy();
            rt.gc.nursery.enabled = nursery;
            rt.gc.scheduler.host_quiescent = true;
            const ctx = try core.JSContext.create(rt, .{});
            defer ctx.destroy();
            const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
            rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
            try global.defineOwnProperty(rt, core.atom.ids.next, core.Descriptor.data(try core.function.nativeFunction(ctx, "concatBoundaryMethod", 0), .all));
            var identities: [2]usize = undefined;
            var args: [2]core.JSValue = undefined;
            for (&args, &identities, 0..) |*value, *identity, index| {
                const input = try core.Object.createPlainObject(rt, null);
                try input.defineOwnProperty(rt, core.atom.ids.done, core.Descriptor.data(core.JSValue.boolean(fail and index == 1), .all));
                value.* = input.value();
                identity.* = try rt.registerWeakObjectIdentity(input);
            }
            const result = zjs.exec.iterator_ops.iteratorConcatCall(ctx, null, global, &args, zjs.exec.array_ops.arrayPrototypeFromGlobal, Probe.getMethod, zjs.exec.call_runtime.isCallableValue);
            if (fail) {
                if (result) |_| return error.ExpectedConcatGetterFailure else |err| try require(err == error.OutOfMemory);
                try require(rt.active_value_roots == null);
                _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                for (identities) |identity| try require(rt.liveObjectFromWeakIdentity(identity) == null);
                continue;
            }
            var helper = try core.JSValueHandle.init(rt, try result);
            defer helper.deinit();
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            const records = core.Object.fromHeader(core.Object.fromHeader(helper.get().refHeader().?).iteratorTargetSlot().*.?.refHeader().?);
            for (identities, 0..) |identity, index| {
                const input = rt.liveObjectFromWeakIdentity(identity) orelse return error.LostConcatInput;
                try require((try records.getProperty(core.Atom.taggedInt(@intCast(index * 2)))).same(input.value()));
                try require(zjs.exec.call_runtime.isCallableValue(try records.getProperty(core.Atom.taggedInt(@intCast(index * 2 + 1)))));
            }
            try require(rt.active_value_roots == null);
        }
    }
}

fn verifyZipCreationRoots() !void {
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |keyed| {
            for ([_]bool{ false, true }) |warm| {
                for ([_]?usize{ null, 0, 1024, 4096, 16384 }) |extra_budget| {
                    const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                    defer rt.destroy();
                    rt.gc.nursery.enabled = nursery;
                    rt.gc.scheduler.host_quiescent = true;
                    const ctx = try core.JSContext.create(rt, .{});
                    defer ctx.destroy();
                    const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                    rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
                    if (warm) _ = try zjs.exec.iterator_ops.iteratorHelperPrototype(rt, global);
                    var identities: [4]usize = undefined;
                    const inputs = setup: {
                        var roots = core.runtime.ExactValueRoots(4){};
                        try roots.activate(rt);
                        defer roots.deactivate();
                        var values: [4]core.JSValue = undefined;
                        inline for (0..4) |index| {
                            const object = try core.Object.createArray(rt, null);
                            try (try roots.ref(index)).set(rt, object.value());
                            identities[index] = try rt.registerWeakObjectIdentity(object);
                        }
                        inline for (0..4) |index| values[index] = try (try roots.ref(index)).get(rt);
                        break :setup values;
                    };
                    rt.gc.heap_budget.gc_threshold = 0;
                    if (extra_budget) |extra| rt.setMemoryLimit(rt.gc.heap_budget.bytes + extra);
                    const result = zjs.exec.iterator_ops.iteratorZipCreateHelper(
                        rt,
                        global,
                        core.Object.fromHeader(inputs[0].refHeader().?),
                        core.Object.fromHeader(inputs[1].refHeader().?),
                        core.Object.fromHeader(inputs[2].refHeader().?),
                        if (keyed) core.Object.fromHeader(inputs[3].refHeader().?) else null,
                        0,
                        .shortest,
                        keyed,
                    );
                    rt.setMemoryLimit(std.math.maxInt(usize));
                    if (result) |_| {
                        if (extra_budget == 0) return error.ExpectedZipAllocationFailure;
                    } else |err| {
                        try require(err == error.OutOfMemory and extra_budget != null);
                        try require(rt.active_value_roots == null);
                        _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                        for (identities) |identity| try require(rt.liveObjectFromWeakIdentity(identity) == null);
                        continue;
                    }
                    var helper = try core.JSValueHandle.init(rt, try result);
                    defer helper.deinit();
                    rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
                    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                    const owner = core.Object.fromHeader(helper.get().refHeader().?);
                    const edges = [_]?core.JSValue{ owner.iteratorTargetSlot().*, owner.iteratorZipNexts(), owner.iteratorZipPads(), owner.iteratorZipKeys() };
                    for (identities[0..if (keyed) @as(usize, 4) else 3], edges[0..if (keyed) @as(usize, 4) else 3]) |identity, edge| {
                        const target = rt.liveObjectFromWeakIdentity(identity) orelse return error.LostZipCreationInput;
                        try require(edge.?.same(target.value()));
                    }
                    try require(rt.active_value_roots == null);
                }
            }
        }
    }
}

fn verifyZipCallbackRoots() !void {
    const Probe = struct {
        calls: usize = 0,
        fail: bool,
        fn thunk(ctx: *core.JSContext, _: core.JSValue, _: [*]const core.JSValue, _: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            self.calls += 1;
            _ = ctx.runtime.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only) catch |err| return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
            if (self.fail and self.calls == 2) return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, error.OutOfMemory);
            return core.JSValue.undefinedValue();
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |keyed| {
            for ([_]bool{ false, true }) |fail| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const context = try zjs.Context.create(rt, .{});
                defer context.destroy();
                const ctx = context.core;
                defer ctx.clearException();
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
                var probe = Probe{ .fail = fail };
                var callback = try core.JSValueHandle.init(rt, try core.function.nativeFunction(ctx, "zipBoundaryGc", 0));
                defer callback.deinit();
                const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.thunk), .kind = .managed, .state = &probe });
                core.Object.fromHeader(callback.get().refHeader().?).installNativeEntry(entry);
                try global.defineOwnProperty(rt, try rt.internAtom("zipBoundaryGc"), core.Descriptor.data(callback.get(), .all));
                var helper = try core.JSValueHandle.init(rt, try context.eval(if (keyed)
                    "Iterator.zipKeyed({a: { next() { return { get done() { zipBoundaryGc(); return false; }, value: {n: 11} }; }, return() { zipBoundaryGc(); return {}; } }, b: { next() { return { get done() { zipBoundaryGc(); return false; }, value: {n: 22} }; }, return() { zipBoundaryGc(); return {}; } }})"
                else
                    "Iterator.zip([{ next() { return { get done() { zipBoundaryGc(); return false; }, value: {n: 11} }; }, return() { zipBoundaryGc(); return {}; } }, { next() { return { get done() { zipBoundaryGc(); return false; }, value: {n: 22} }; }, return() { zipBoundaryGc(); return {}; } }])", .{}));
                defer helper.deinit();
                const next_method = try core.Object.fromHeader(helper.get().refHeader().?).getProperty(core.atom.ids.next);
                const result = zjs.exec.iterator_ops.iteratorHelperNext(ctx, null, global, helper.get(), core.Object.fromHeader(next_method.refHeader().?), null, null);
                if (fail) {
                    if (result) |_| return error.ExpectedZipGetterFailure else |err| try require(err == error.OutOfMemory or err == error.JSException);
                    try require(probe.calls == 3);
                    try require(core.Object.fromHeader(helper.get().refHeader().?).iteratorTargetSlot().* == null);
                } else {
                    const row = try core.Object.fromHeader((try result).?.refHeader().?).getProperty(core.atom.ids.value);
                    for ([_]i32{ 11, 22 }, 0..) |expected, index| {
                        const key = if (keyed) try rt.internAtom(if (index == 0) "a" else "b") else core.Atom.taggedInt(@intCast(index));
                        const value = try core.Object.fromHeader(row.refHeader().?).getProperty(key);
                        if (!value.is(.object)) return error.LostZipResult;
                        try require((try core.Object.fromHeader(value.refHeader().?).getProperty(try rt.internAtom("n"))).as(.int).? == expected);
                    }
                    try require(probe.calls == 2);
                    const return_method = try core.Object.fromHeader(helper.get().refHeader().?).getProperty(core.atom.ids.return_);
                    const closed = (try zjs.exec.iterator_ops.iteratorHelperReturn(ctx, null, global, helper.get(), core.Object.fromHeader(return_method.refHeader().?), null, null)).?;
                    try require((try core.Object.fromHeader(closed.refHeader().?).getProperty(core.atom.ids.done)).same(core.JSValue.boolean(true)));
                    try require(probe.calls == 4);
                    try require(core.Object.fromHeader(helper.get().refHeader().?).iteratorTargetSlot().* == null);
                }
                try require(!core.Object.fromHeader(helper.get().refHeader().?).generatorExecuting());
                try require(rt.active_value_roots == null);
            }
        }
    }
}

fn verifyFlatMapInnerPublication() !void {
    const Probe = struct {
        collect: bool,
        fail: bool,
        calls: usize = 0,
        fn thunk(ctx: *core.JSContext, _: core.JSValue, _: [*]const core.JSValue, _: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            self.calls += 1;
            if (self.collect) {
                _ = ctx.runtime.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only) catch |err| return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
            }
            if (self.fail and self.calls == 2) return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, error.OutOfMemory);
            return core.JSValue.undefinedValue();
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |collect| {
            for ([_]bool{ false, true }) |fail| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const context = try zjs.Context.create(rt, .{});
                defer context.destroy();
                const ctx = context.core;
                defer ctx.clearException();
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
                var probe = Probe{ .collect = collect, .fail = fail };
                var callback = try core.JSValueHandle.init(rt, try core.function.nativeFunction(ctx, "flatMapBoundaryGc", 0));
                defer callback.deinit();
                const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.thunk), .kind = .managed, .state = &probe });
                core.Object.fromHeader(callback.get().refHeader().?).installNativeEntry(entry);
                try global.defineOwnProperty(rt, try rt.internAtom("flatMapBoundaryGc"), core.Descriptor.data(callback.get(), .all));
                var helper = try core.JSValueHandle.init(rt, try context.eval(
                    "Iterator.from([1]).flatMap(function () { return { [Symbol.iterator]() { flatMapBoundaryGc(); return this; }, get next() { flatMapBoundaryGc(); return function () { flatMapBoundaryGc(); return { value: 42, done: false }; }; } }; })",
                    .{},
                ));
                defer helper.deinit();
                _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                try require(!helper.get().refHeader().?.metaConst().flags.young);
                const next_method = try core.Object.fromHeader(helper.get().refHeader().?).getProperty(core.atom.ids.next);
                const result = zjs.exec.iterator_ops.iteratorHelperNext(ctx, null, global, helper.get(), core.Object.fromHeader(next_method.refHeader().?), null, null);
                try require(!core.Object.fromHeader(helper.get().refHeader().?).generatorExecuting());
                if (fail) {
                    if (result) |_| return error.ExpectedFlatMapGetterFailure else |err| try require(err == error.OutOfMemory or err == error.JSException);
                    try require(probe.calls == 2);
                    try require(core.Object.fromHeader(helper.get().refHeader().?).iteratorData() == null);
                } else {
                    try require((try core.Object.fromHeader((try result).?.refHeader().?).getProperty(core.atom.ids.value)).as(.int).? == 42);
                    const inner_id = try rt.registerWeakObjectIdentity(core.Object.fromHeader(core.Object.fromHeader(helper.get().refHeader().?).iteratorData().?.refHeader().?));
                    const next_id = try rt.registerWeakObjectIdentity(core.Object.fromHeader(core.Object.fromHeader(helper.get().refHeader().?).iteratorInnerNext().?.refHeader().?));
                    if (nursery) _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
                    const owner = core.Object.fromHeader(helper.get().refHeader().?);
                    try require(owner.iteratorData().?.same((rt.liveObjectFromWeakIdentity(inner_id) orelse return error.LostFlatMapInner).value()));
                    try require(owner.iteratorInnerNext().?.same((rt.liveObjectFromWeakIdentity(next_id) orelse return error.LostFlatMapNext).value()));
                    const again = (try zjs.exec.iterator_ops.iteratorHelperNext(ctx, null, global, helper.get(), core.Object.fromHeader(next_method.refHeader().?), null, null)).?;
                    try require((try core.Object.fromHeader(again.refHeader().?).getProperty(core.atom.ids.value)).as(.int).? == 42);
                    try require(probe.calls == 4);
                }
                try require(rt.active_value_roots == null);
            }
        }
    }
}

fn verifyIteratorHelperCreationRoots() !void {
    inline for (.{ .map, .filter, .flat_map, .take, .drop }) |method| try verifyIteratorHelperCreationMethod(method);
}

fn verifyIteratorHelperCreationMethod(comptime method: core.host_function.builtin_method_ids.iterator.PrototypeMethod) !void {
    const limited = method == .take or method == .drop;
    const Probe = struct {
        receiver_id: usize = 0,
        callback_id: usize = 0,
        lost: bool = false,
        calls: usize = 0,
        failure: usize,
        fn run(self: *@This(), ctx: *core.JSContext) !core.JSValue {
            self.calls += 1;
            _ = try ctx.runtime.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            const callback = ctx.runtime.liveObjectFromWeakIdentity(self.callback_id);
            if (callback == null or ctx.runtime.liveObjectFromWeakIdentity(self.receiver_id) == null) {
                self.lost = true;
                return error.OutOfMemory;
            }
            if (self.failure == 1) return error.OutOfMemory;
            if (self.failure == 2) ctx.runtime.setMemoryLimit(0);
            return if (limited) core.JSValue.int32(1) else callback.?.value();
        }
        fn thunk(ctx: *core.JSContext, _: core.JSValue, _: [*]const core.JSValue, _: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            return self.run(ctx) catch |err| zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |cached| {
            for (0..3) |failure| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const ctx = try core.JSContext.create(rt, .{});
                defer ctx.destroy();
                defer ctx.clearException();
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
                if (cached) _ = try zjs.exec.iterator_ops.iteratorHelperPrototype(rt, global);
                var probe = Probe{ .failure = failure };
                const inputs = setup: {
                    var roots = core.runtime.ExactValueRoots(4){};
                    try roots.activate(rt);
                    defer roots.deactivate();
                    const receiver = try roots.ref(0);
                    const callback = try roots.ref(1);
                    const getter = try roots.ref(2);
                    const argument = try roots.ref(3);
                    try receiver.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                    try callback.set(rt, try core.function.nativeFunction(ctx, "helperBoundaryCallback", 0));
                    try getter.set(rt, try core.function.nativeFunction(ctx, "helperBoundaryGetter", 0));
                    const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.thunk), .kind = .managed, .state = &probe });
                    core.Object.fromHeader((try getter.get(rt)).refHeader().?).installNativeEntry(entry);
                    if (limited) {
                        try argument.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                        try core.Object.fromHeader((try argument.get(rt)).refHeader().?).defineOwnProperty(rt, core.atom.ids.valueOf, core.Descriptor.data(try getter.get(rt), .all));
                        try core.Object.fromHeader((try receiver.get(rt)).refHeader().?).defineOwnProperty(rt, core.atom.ids.next, core.Descriptor.data(try callback.get(rt), .all));
                    } else {
                        try argument.set(rt, try callback.get(rt));
                        try core.Object.fromHeader((try receiver.get(rt)).refHeader().?).defineOwnProperty(rt, core.atom.ids.next, core.Descriptor.accessor(try getter.get(rt), core.JSValue.undefinedValue(), .all));
                    }
                    probe.receiver_id = try rt.registerWeakObjectIdentity(core.Object.fromHeader((try receiver.get(rt)).refHeader().?));
                    probe.callback_id = try rt.registerWeakObjectIdentity(core.Object.fromHeader((try callback.get(rt)).refHeader().?));
                    break :setup [_]core.JSValue{ try receiver.get(rt), try argument.get(rt) };
                };
                rt.gc.heap_budget.gc_threshold = 0;
                const result = zjs.exec.iterator_ops.iteratorPrototypeMethodCall(ctx, null, global, inputs[0], inputs[1..], @intFromEnum(method), null, null);
                rt.setMemoryLimit(null);
                if (probe.lost) return error.LostIteratorHelperInput;
                try require(probe.calls == 1);
                try require(rt.active_value_roots == null);
                if (failure != 0) {
                    if (result) |_| return error.ExpectedIteratorHelperFailure else |err| try require(err == error.OutOfMemory or err == error.JSException);
                } else {
                    var roots = core.runtime.ExactValueRoots(1){};
                    try roots.activate(rt);
                    defer roots.deactivate();
                    const kept = try roots.ref(0);
                    try kept.set(rt, (try result).?);
                    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                    const helper = core.Object.fromHeader((try kept.get(rt)).refHeader().?);
                    try require(helper.iteratorTargetSlot().*.?.same(rt.liveObjectFromWeakIdentity(probe.receiver_id).?.value()));
                    try require(helper.iteratorNextSlot().*.?.same(rt.liveObjectFromWeakIdentity(probe.callback_id).?.value()));
                    if (!limited) try require(helper.iteratorCallbackSlot().*.?.same(rt.liveObjectFromWeakIdentity(probe.callback_id).?.value()));
                }
            }
        }
    }
}

fn verifyIteratorCloseExceptionRoots() !void {
    inline for (.{ .single, .all, .normal }) |mode| try verifyIteratorCloseExceptionMode(mode);
}

fn verifyIteratorCloseExceptionMode(comptime mode: enum { single, all, normal }) !void {
    const Probe = struct {
        identity: usize = 0,
        lost: bool = false,
        calls: usize = 0,
        fail: bool,
        fn run(self: *@This(), ctx: *core.JSContext) !core.JSValue {
            self.calls += 1;
            if (mode == .normal and self.calls == 1) {
                const thrown = try core.Object.createPlainObject(ctx.runtime, null);
                self.identity = try ctx.runtime.registerWeakObjectIdentity(thrown);
                return ctx.throwValue(thrown.value());
            }
            // A later callback may clear/replace the pending exception. The
            // completion must retain its own copy until all closes finish.
            ctx.clearException();
            _ = try ctx.runtime.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            if (ctx.runtime.liveObjectFromWeakIdentity(self.identity) == null) {
                self.lost = true;
                return error.OutOfMemory;
            }
            const result = (try core.Object.createPlainObject(ctx.runtime, null)).value();
            return if (self.fail) ctx.throwValue(result) else result;
        }
        fn thunk(ctx: *core.JSContext, _: core.JSValue, _: [*]const core.JSValue, _: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            return self.run(ctx) catch |err| zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |fail| {
            const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer rt.destroy();
            rt.gc.nursery.enabled = nursery;
            rt.gc.scheduler.host_quiescent = true;
            const ctx = try core.JSContext.create(rt, .{});
            defer ctx.destroy();
            defer ctx.clearException();
            const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
            rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
            var probe = Probe{ .fail = fail };
            const inputs = setup: {
                var roots = core.runtime.ExactValueRoots(4){};
                try roots.activate(rt);
                defer roots.deactivate();
                const object = try roots.ref(0);
                const method = try roots.ref(1);
                const collection = try roots.ref(2);
                const extra = try roots.ref(3);
                try object.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                try method.set(rt, try core.function.nativeFunction(ctx, "iteratorCloseBoundary", 0));
                const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.thunk), .kind = .managed, .state = &probe });
                core.Object.fromHeader((try method.get(rt)).refHeader().?).installNativeEntry(entry);
                try core.Object.fromHeader((try object.get(rt)).refHeader().?).defineOwnProperty(rt, core.atom.ids.return_, core.Descriptor.data(try method.get(rt), .all));
                try collection.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                try extra.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                try core.Object.fromHeader((try extra.get(rt)).refHeader().?).defineOwnProperty(rt, core.atom.ids.return_, core.Descriptor.data(try method.get(rt), .all));
                for (0..2) |index| try core.Object.fromHeader((try collection.get(rt)).refHeader().?).defineOwnProperty(rt, core.Atom.taggedInt(@intCast(index)), core.Descriptor.data(try object.get(rt), .all));
                if (mode != .normal) {
                    const thrown = try core.Object.createPlainObject(rt, null);
                    probe.identity = try rt.registerWeakObjectIdentity(thrown);
                    _ = ctx.throwValue(thrown.value());
                }
                break :setup [_]core.JSValue{ try object.get(rt), try collection.get(rt), try extra.get(rt) };
            };
            const err = switch (mode) {
                .single => zjs.exec.iterator_ops.iteratorCloseWithCompletionAndPropagate(ctx, null, global, inputs[0], error.JSException, null, null),
                .all => zjs.exec.iterator_ops.iteratorZipCloseAllAndPropagate(ctx, null, global, core.Object.fromHeader(inputs[1].refHeader().?), 2, error.JSException, inputs[2], null, null),
                .normal => normal: {
                    var completion = zjs.exec.iterator_ops.IteratorZipCompletion.initNormal();
                    completion.activateRoots(rt);
                    defer completion.deinit(rt);
                    try zjs.exec.iterator_ops.iteratorZipCloseAllWithCompletion(ctx, null, global, &completion, core.Object.fromHeader(inputs[1].refHeader().?), 2, null, null);
                    completion.restore(ctx);
                    break :normal completion.err orelse return error.MissingIteratorCloseException;
                },
            };
            if (probe.lost) return error.LostIteratorCloseException;
            try require(err == error.JSException and probe.calls == (switch (mode) {
                .single => @as(usize, 1),
                .all => 3,
                .normal => 2,
            }));
            const expected = rt.liveObjectFromWeakIdentity(probe.identity) orelse return error.LostIteratorCloseException;
            try require(ctx.hasException() and rt.current_exception.same(expected.value()));
            try require(rt.active_value_roots == null);
        }
    }
}

fn verifyIteratorAccumulatorRoots() !void {
    inline for (.{ .reduce, .find, .to_array, .filter }) |method| try verifyIteratorTerminalRoots(method);
}

fn verifyIteratorTerminalRoots(comptime method: core.host_function.builtin_method_ids.iterator.PrototypeMethod) !void {
    const Probe = struct {
        accumulator: ?*core.gc.Header = null,
        identity: ?usize = null,
        moved: bool = false,
        next_calls: usize = 0,
        closes: usize = 0,
        lost: bool = false,
        fail: bool,
        fn collect(self: *@This(), ctx: *core.JSContext) !void {
            if (self.accumulator) |header| {
                _ = try ctx.runtime.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                const current = ctx.runtime.liveObjectFromWeakIdentity(self.identity.?) orelse {
                    self.lost = true;
                    return error.OutOfMemory;
                };
                self.moved = self.moved or current.gcHeader() != header;
                if (self.fail) return error.OutOfMemory;
            }
        }
        fn value(self: *@This(), ctx: *core.JSContext) !core.JSValue {
            const object = try core.Object.createPlainObject(ctx.runtime, null);
            self.accumulator = object.gcHeader();
            self.identity = try ctx.runtime.registerWeakObjectIdentity(object);
            return object.value();
        }
        fn next(self: *@This(), ctx: *core.JSContext) !core.JSValue {
            self.next_calls += 1;
            try self.collect(ctx);
            if (method != .reduce and self.next_calls == 1) {
                return zjs.exec.iterator_ops.createIteratorResult(ctx.runtime, try zjs.exec.zjs_vm.contextGlobal(ctx), try self.value(ctx), false);
            }
            return zjs.exec.iterator_ops.createIteratorResult(ctx.runtime, try zjs.exec.zjs_vm.contextGlobal(ctx), core.JSValue.int32(42), self.next_calls == 2);
        }
        fn nextThunk(ctx: *core.JSContext, _: core.JSValue, _: [*]const core.JSValue, _: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            return self.next(ctx) catch |err| zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
        }
        fn reduceThunk(ctx: *core.JSContext, _: core.JSValue, _: [*]const core.JSValue, _: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            if (method == .find or method == .filter) {
                self.collect(ctx) catch |err| return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
                return core.JSValue.boolean(true);
            }
            return self.value(ctx) catch |err| zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
        }
        fn closeThunk(ctx: *core.JSContext, _: core.JSValue, _: [*]const core.JSValue, _: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            self.closes += 1;
            self.collect(ctx) catch |err| return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
            const global = zjs.exec.zjs_vm.contextGlobal(ctx) catch |err| return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
            return zjs.exec.iterator_ops.createIteratorResult(ctx.runtime, global, core.JSValue.undefinedValue(), true) catch |err| zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |fail| {
            const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer rt.destroy();
            rt.gc.nursery.enabled = nursery;
            rt.gc.scheduler.host_quiescent = true;
            const ctx = try core.JSContext.create(rt, .{});
            defer ctx.destroy();
            defer ctx.clearException();
            const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
            rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
            var probe = Probe{ .fail = fail };
            const inputs = setup: {
                var roots = core.runtime.ExactValueRoots(4){};
                try roots.activate(rt);
                defer roots.deactivate();
                const iterator = try roots.ref(0);
                const next = try roots.ref(1);
                const reducer = try roots.ref(2);
                const closer = try roots.ref(3);
                try iterator.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                try next.set(rt, try core.function.nativeFunction(ctx, "iteratorBoundaryNext", 0));
                try reducer.set(rt, try core.function.nativeFunction(ctx, "iteratorBoundaryReduce", 2));
                try closer.set(rt, try core.function.nativeFunction(ctx, "iteratorBoundaryClose", 0));
                const next_entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.nextThunk), .kind = .managed, .state = &probe });
                const reduce_entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.reduceThunk), .kind = .managed, .state = &probe });
                core.Object.fromHeader((try next.get(rt)).refHeader().?).installNativeEntry(next_entry);
                core.Object.fromHeader((try reducer.get(rt)).refHeader().?).installNativeEntry(reduce_entry);
                const close_entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.closeThunk), .kind = .managed, .state = &probe });
                core.Object.fromHeader((try closer.get(rt)).refHeader().?).installNativeEntry(close_entry);
                try core.Object.fromHeader((try iterator.get(rt)).refHeader().?).defineOwnProperty(rt, core.atom.ids.next, core.Descriptor.data(try next.get(rt), .all));
                try core.Object.fromHeader((try iterator.get(rt)).refHeader().?).defineOwnProperty(rt, core.atom.ids.return_, core.Descriptor.data(try closer.get(rt), .all));
                break :setup [_]core.JSValue{ try iterator.get(rt), try reducer.get(rt) };
            };
            var result: anyerror!?core.JSValue = if (method == .filter) helper: {
                var kept = try core.JSValueHandle.init(rt, (try zjs.exec.iterator_ops.iteratorPrototypeMethodCall(ctx, null, global, inputs[0], &.{inputs[1]}, @intFromEnum(method), null, null)).?);
                defer kept.deinit();
                const next_method = try core.Object.fromHeader(kept.get().refHeader().?).getProperty(core.atom.ids.next);
                const next_result = zjs.exec.iterator_ops.iteratorHelperNext(ctx, null, global, kept.get(), core.Object.fromHeader(next_method.refHeader().?), null, null) catch |err| break :helper err;
                break :helper try core.Object.fromHeader(next_result.?.refHeader().?).getProperty(core.atom.ids.value);
            } else zjs.exec.iterator_ops.iteratorPrototypeMethodCall(ctx, null, global, inputs[0], &.{ inputs[1], core.JSValue.int32(0) }, @intFromEnum(method), null, null);
            if (probe.lost) return error.LostIteratorAccumulator;
            try require(probe.next_calls == (if (method == .find or method == .filter) @as(usize, 1) else 2));
            try require(probe.closes == (if (method == .find or (method == .filter and fail)) @as(usize, 1) else 0));
            if (method == .filter and !fail) {
                // Native callback arguments are readonly ABI roots. Once that
                // call has returned, the published value must also relocate.
                var returned = try core.JSValueHandle.init(rt, (try result).?);
                defer returned.deinit();
                try probe.collect(ctx);
                result = returned.get();
            }
            if (nursery and !probe.moved) {
                std.debug.print("Iterator result did not move: method={s} fail={} nursery_header={}\n", .{ @tagName(method), fail, core.gc.Registry.isNurseryHeader(probe.accumulator.?) });
                return error.IteratorResultDidNotMove;
            }
            if (fail) {
                if (result) |_| return error.ExpectedIteratorNextFailure else |err| try require(err == error.OutOfMemory or err == error.JSException);
            } else {
                const returned = (try result).?;
                const expected = rt.liveObjectFromWeakIdentity(probe.identity.?) orelse return error.LostIteratorAccumulator;
                if (method == .to_array) {
                    const array = core.Object.fromHeader(returned.refHeader().?);
                    try require((try array.getProperty(core.Atom.taggedInt(0))).same(expected.value()));
                    try require((try array.getProperty(core.atom.ids.length)).as(.int).? == 1);
                } else try require(returned.same(expected.value()));
            }
            try require(rt.active_value_roots == null);
        }
    }
}

fn verifyCallSiteLifetime() !void {
    inline for (.{ false, true }) |bytecode_route| {
        inline for (.{ false, true }) |internal_site| try verifyCallSiteLifetimeRoute(bytecode_route, internal_site);
    }
}

fn verifyCallSiteLifetimeRoute(comptime bytecode_route: bool, comptime internal_site: bool) !void {
    const Native = struct {
        fn thunk(_: *core.JSContext, receiver: core.JSValue, _: [*]const core.JSValue, _: u32, _: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            return receiver;
        }
    };
    const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
    defer rt.destroy();
    rt.gc.nursery.enabled = true;
    rt.gc.scheduler.host_quiescent = true;
    const context = try zjs.Context.create(rt, .{});
    defer context.destroy();
    const ctx = context.core;
    const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
    rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
    var receiver = try core.JSValueHandle.init(rt, (try core.Object.createPlainObject(rt, null)).value());
    defer receiver.deinit();
    var callee = try core.JSValueHandle.init(rt, if (bytecode_route)
        try context.eval("(function () { 'use strict'; return this; })", .{})
    else
        try core.function.nativeFunction(ctx, "callSiteLifetime", 0));
    defer callee.deinit();
    if (!bytecode_route) {
        const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Native.thunk), .kind = .managed });
        core.Object.fromHeader(callee.get().refHeader().?).installNativeEntry(entry);
    }
    var site = if (internal_site)
        zjs.exec.call_site.CallSite.initInternal(ctx, null, global, receiver.get(), callee.get(), null, null)
    else
        try zjs.exec.call_site.CallSite.init(ctx, null, global, receiver.get(), callee.get());
    if (internal_site) site.activateRoots();
    defer site.deinit();
    try require((site.route == .bytecode) == bytecode_route);
    try require((try site.call(&.{})).same(receiver.get()));
    const before = receiver.get();
    _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
    try require(!receiver.get().same(before));
    const result = try site.call(&.{});
    if (!result.same(receiver.get())) return error.StaleCallSiteReceiver;
    try require(rt.active_value_roots == (if (internal_site) &site.internal_roots.frame else null));
    const identity = try rt.registerWeakObjectIdentity(core.Object.fromHeader(receiver.get().refHeader().?));
    receiver.deinit();
    callee.deinit();
    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
    const held = rt.liveObjectFromWeakIdentity(identity) orelse return error.LostCallSiteOwnedReceiver;
    try require((try site.call(&.{})).same(held.value()));
    site.deinit();
    try require(rt.active_value_roots == null);
    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
    try require(rt.liveObjectFromWeakIdentity(identity) == null);
}

fn verifyCallEntryRoots() !void {
    inline for (.{ .root, .site, .site_this, .internal_site, .internal_this, .once }) |mode| try verifyCallEntryRootsMode(mode);
}

fn verifyCallEntryRootsMode(comptime mode: enum { root, site, site_this, internal_site, internal_this, once }) !void {
    const Probe = struct {
        headers: [3]*core.gc.Header,
        args: []core.JSValue,
        stop: bool,
        gc_error: ?anyerror = null,
        lost: bool = false,
        polls: usize = 0,
        fn poll(runtime: *core.JSRuntime, state: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(state.?));
            self.polls += 1;
            if (mode == .root) @memset(self.args, core.JSValue.undefinedValue());
            _ = runtime.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only) catch |err| {
                self.gc_error = err;
                return true;
            };
            for (self.headers) |header| {
                if (!runtime.gc.containsHeader(header)) self.lost = true;
            }
            return self.lost or self.stop;
        }
        fn thunk(_: *core.JSContext, receiver: core.JSValue, args: [*]const core.JSValue, argc: u32, _: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            return if (argc == 0) receiver else args[argc - 1];
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for (0..8) |case| {
            const argc = ([_]usize{ 0, 8, 9, 16 })[case / 2];
            const runtime = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer runtime.destroy();
            runtime.gc.nursery.enabled = nursery;
            runtime.gc.scheduler.host_quiescent = true;
            const ctx = try core.JSContext.create(runtime, .{});
            defer ctx.destroy();
            defer ctx.clearException();
            const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
            runtime.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
            const inputs = setup: {
                var roots = core.runtime.ExactValueRoots(3){};
                try roots.activate(runtime);
                defer roots.deactivate();
                const receiver = try roots.ref(0);
                const callee = try roots.ref(1);
                const argument = try roots.ref(2);
                try receiver.set(runtime, (try core.Object.createPlainObject(runtime, null)).value());
                try callee.set(runtime, try core.function.nativeFunction(ctx, "callEntryRoots", 0));
                try argument.set(runtime, (try core.Object.createPlainObject(runtime, null)).value());
                const entry = try runtime.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.thunk), .kind = .managed });
                core.Object.fromHeader((try callee.get(runtime)).refHeader().?).installNativeEntry(entry);
                break :setup [_]core.JSValue{ try receiver.get(runtime), try callee.get(runtime), try argument.get(runtime) };
            };
            var args = [_]core.JSValue{inputs[2]} ** 16;
            var probe = Probe{
                .headers = .{ inputs[0].refHeader().?, inputs[1].refHeader().?, (if (argc == 0) global.value() else inputs[2]).refHeader().? },
                .args = args[0..argc],
                .stop = case % 2 != 0,
            };
            var site = if (mode == .site or mode == .site_this)
                try zjs.exec.call_site.CallSite.init(ctx, null, global, inputs[0], inputs[1])
            else
                zjs.exec.call_site.CallSite.initInternal(ctx, null, global, inputs[0], inputs[1], null, null);
            if (mode == .internal_site or mode == .internal_this) site.activateRoots();
            defer site.deinit();
            runtime.setInterruptHandler(&Probe.poll, &probe);
            defer runtime.setInterruptHandler(null, null);
            ctx.interrupt_counter = 1;
            const result: anyerror!core.JSValue = switch (mode) {
                .root => zjs.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, inputs[0], inputs[1], args[0..argc], null, null),
                .site, .internal_site => site.call(args[0..argc]),
                .site_this, .internal_this => site.callWithThis(inputs[0], args[0..argc]),
                .once => once: {
                    var out: core.JSValue = undefined;
                    zjs.exec.call_site.callOnceInto(ctx, null, global, inputs[0], inputs[1], args[0..argc], null, null, &out) catch |err| break :once err;
                    break :once out;
                },
            };
            if (probe.gc_error) |err| return err;
            if (probe.lost) return error.LostCallEntryRoot;
            try require(probe.polls == 1);
            if (probe.stop) {
                if (result) |_| return error.ExpectedCallEntryInterrupt else |err| try require(err == error.Interrupted);
                try require(ctx.exceptionIsUncatchable());
            } else {
                const returned = try result;
                try require(returned.same(inputs[if (argc == 0) @as(usize, 0) else 2]));
                var roots = core.runtime.ExactValueRoots(1){};
                try roots.activate(runtime);
                defer roots.deactivate();
                const kept = try roots.ref(0);
                try kept.set(runtime, returned);
                _ = try runtime.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                try require(runtime.gc.containsHeader((try kept.get(runtime)).refHeader().?));
            }
            try require(runtime.active_value_roots == (if (mode == .internal_site or mode == .internal_this) &site.internal_roots.frame else null));
        }
    }
}

fn verifyRetainedNurseryPrototype() !void {
    for ([_]bool{ false, true }) |major| {
        const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
        defer rt.destroy();
        rt.gc.nursery.enabled = true;
        rt.gc.scheduler.host_quiescent = true;
        rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
        var roots = core.runtime.ExactValueRoots(2){};
        try roots.activate(rt);
        defer roots.deactivate();
        const prototype = try roots.ref(0);
        const owner = try roots.ref(1);
        try prototype.set(rt, (try core.Object.createPlainObject(rt, null)).value());
        const original = (try prototype.get(rt)).cycleMarkHeader().?;
        try require(core.gc.Registry.isNurseryHeader(original));
        const identity = try rt.registerWeakObjectIdentity(core.Object.fromHeader(original));
        try owner.set(rt, (try core.Object.createPlainObject(rt, core.Object.fromHeader(original))).value());
        {
            const pinned = [_]core.JSValue{try prototype.get(rt)};
            const slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &pinned }};
            var frame = core.runtime.ValueRootFrame{ .slices = &slices };
            frame.activate(rt);
            defer frame.deactivate(rt);
            if (major) {
                _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            } else {
                _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
            }
            try require((try prototype.get(rt)).cycleMarkHeader().? == original);
        }
        try prototype.set(rt, core.JSValue.undefinedValue());
        _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
        const moved = rt.liveObjectFromWeakIdentity(identity) orelse return error.LostRetainedNurseryPrototype;
        try require(moved.gcHeader() != original);
        try require(core.Object.fromHeader((try owner.get(rt)).cycleMarkHeader().?).getPrototype() == moved);
    }
}

fn verifyCollectionGroupRoots() !void {
    const units = [_]u16{ 'a', 0xd83d, 0xde00, 0xd800, 'z' };
    const starts = [_]usize{ 0, 1, 3, 4, 5 };
    const Probe = struct {
        // This executable invokes fixtures serially. The CallbackHost ABI has
        // no user data pointer; this fixture-local rendezvous holds no roots.
        var active: ?*@This() = null;
        source: core.JSValue,
        source_identity: ?usize,
        callback_identity: usize,
        prototype_identity: usize,
        key_kind: usize,
        failure: usize,
        calls: usize = 0,
        moved_items: usize = 0,
        lost_source: bool = false,
        lost_item: bool = false,
        lost_callback: bool = false,
        unexpected_error: ?anyerror = null,
        key_identities: [4]usize = undefined,
        item_identities: [4]usize = undefined,
        fn call(ctx: *core.JSContext, _: core.JSValue, _: core.JSValue, args: []const core.JSValue, globals: []core.global_slots.Slot) core.host_function.CallbackError!core.JSValue {
            _ = globals;
            return run(ctx, args) catch |err| switch (err) {
                error.JSException => error.JSException,
                error.OutOfMemory => error.OutOfMemory,
                else => blk: {
                    active.?.unexpected_error = err;
                    break :blk error.JSException;
                },
            };
        }
        fn run(ctx: *core.JSContext, args: []const core.JSValue) !core.JSValue {
            const self = active.?;
            const rt = ctx.runtime;
            const item = args[0].cycleMarkHeader().?;
            const identity = if (args[0].is(.object)) try rt.registerWeakObjectIdentity(core.Object.fromHeader(item)) else null;
            if (self.source_identity) |id| {
                // Remove the source's edge so the caller's item slot is the
                // only strong owner until the group publishes it.
                const array = rt.liveObjectFromWeakIdentity(id).?;
                try require(array.deleteProperty(rt, core.Atom.taggedInt(@intCast(self.calls))));
            }
            if (rt.gc.nursery.enabled) _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            self.lost_source = if (self.source_identity) |id| rt.liveObjectFromWeakIdentity(id) == null else !rt.gc.containsHeader(self.source.cycleMarkHeader().?);
            self.lost_item = if (identity) |id| rt.liveObjectFromWeakIdentity(id) == null else !rt.gc.containsHeader(item);
            self.lost_callback = rt.liveObjectFromWeakIdentity(self.callback_identity) == null;
            if (self.lost_source or self.lost_item or self.lost_callback) return error.JSException;
            if (identity) |id| {
                // The callback reads the caller's actual, repaired argument
                // slot; preserving a separate copy would not satisfy this.
                if (args[0].cycleMarkHeader().? != rt.liveObjectFromWeakIdentity(id).?.gcHeader()) return error.JSException;
                if (args[0].cycleMarkHeader().? != item) self.moved_items += 1;
                self.item_identities[self.calls] = id;
            }
            if (args[1].as(.int).? != self.calls) return error.JSException;
            self.calls += 1;
            if (self.failure == 1 and self.calls == 2) return error.JSException;
            const key = switch (self.key_kind) {
                0 => core.JSValue.int32(0),
                1 => try rt.newSymbolValue("group-boundary-key"),
                else => blk: {
                    const object = try core.Object.createPlainObject(rt, null);
                    self.key_identities[self.calls - 1] = try rt.registerWeakObjectIdentity(object);
                    break :blk object.value();
                },
            };
            if (self.failure == 2) rt.setMemoryLimit(0);
            return key;
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for (0..5) |mode| {
            for (0..3) |key_kind| {
                for (0..3) |failure| {
                    const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                    defer rt.destroy();
                    rt.gc.nursery.enabled = nursery;
                    rt.gc.scheduler.host_quiescent = true;
                    rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
                    const ctx = try core.JSContext.create(rt, .{});
                    defer ctx.destroy();
                    _ = try zjs.exec.zjs_vm.contextGlobal(ctx);
                    const inputs = setup: {
                        var roots = core.runtime.ExactValueRoots(5){};
                        try roots.activate(rt);
                        defer roots.deactivate();
                        const source = try roots.ref(0);
                        const callback = try roots.ref(1);
                        const prototype = try roots.ref(2);
                        const temporary = try roots.ref(3);
                        const right = try roots.ref(4);
                        try callback.set(rt, try core.function.nativeFunction(ctx, "groupBoundaryCallback", 2));
                        try prototype.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                        if (mode == 4) {
                            try source.set(rt, (try core.Object.createArray(rt, null)).value());
                            for (0..4) |index| {
                                try temporary.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                                const array = core.Object.fromHeader((try source.get(rt)).cycleMarkHeader().?);
                                try array.defineOwnProperty(rt, core.Atom.taggedInt(@intCast(index)), core.Descriptor.data(try temporary.get(rt), .all));
                            }
                        } else if (mode == 0) {
                            try source.set(rt, (try core.string.String.createUtf16(rt, &units)).value());
                        } else {
                            // The surrogate pair straddles two leaves.
                            try temporary.set(rt, (try core.string.String.createUtf16(rt, units[0..2])).value());
                            try right.set(rt, (try core.string.String.createUtf16(rt, units[2..])).value());
                            try source.set(rt, if (mode == 3)
                                (try core.string.createTailBufferRope(rt, core.string.asFlat(try temporary.get(rt)).?, core.string.asFlat(try right.get(rt)).?)).value()
                            else
                                (try core.string.String.createRope(rt, try temporary.get(rt), try right.get(rt))).value());
                            if (mode == 2) try core.string.ensureFlat(rt, source.readOnly(), temporary);
                        }
                        break :setup [_]core.JSValue{ try source.get(rt), try callback.get(rt), try prototype.get(rt) };
                    };
                    var probe = Probe{
                        .source = inputs[0],
                        .source_identity = if (mode == 4) try rt.registerWeakObjectIdentity(core.Object.fromHeader(inputs[0].cycleMarkHeader().?)) else null,
                        .callback_identity = try rt.registerWeakObjectIdentity(core.Object.fromHeader(inputs[1].cycleMarkHeader().?)),
                        .prototype_identity = try rt.registerWeakObjectIdentity(core.Object.fromHeader(inputs[2].cycleMarkHeader().?)),
                        .key_kind = key_kind,
                        .failure = failure,
                    };
                    Probe.active = &probe;
                    defer Probe.active = null;
                    // Keep array elements young until the callback so its
                    // repaired argument slot is exercised by evacuation.
                    rt.gc.heap_budget.gc_threshold = if (mode == 4) std.math.maxInt(usize) else 0;
                    const result = zjs.exec.collection_ops.groupByWithCallbackHost(rt, inputs[0..2], core.Object.fromHeader(inputs[2].cycleMarkHeader().?), .{ .ctx = ctx, .call = Probe.call });
                    rt.setMemoryLimit(null);
                    if (probe.unexpected_error) |err| return err;
                    if (probe.lost_source) return error.LostCollectionGroupSource;
                    if (probe.lost_item) return error.LostCollectionGroupItem;
                    if (probe.lost_callback) return error.LostCollectionGroupCallback;
                    try require(rt.active_value_roots == null);
                    if (failure != 0) {
                        if (result) |_| return error.ExpectedCollectionGroupFailure else |err| {
                            if (err != (if (failure == 1) error.JSException else error.OutOfMemory)) return err;
                        }
                        try require(probe.calls == (if (failure == 1) @as(usize, 2) else 1));
                        continue;
                    }
                    var roots = core.runtime.ExactValueRoots(1){};
                    try roots.activate(rt);
                    defer roots.deactivate();
                    const kept = try roots.ref(0);
                    try kept.set(rt, try result);
                    try require(probe.calls == 4);
                    if (mode == 1) try require(inputs[0].ropeBody().?.flatString() == null);
                    if (mode == 3) try require(inputs[0].ropeBody().?.buffer != null);
                    if (nursery and mode == 4) try require(probe.moved_items > 0);
                    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                    const map = core.Object.fromHeader((try kept.get(rt)).cycleMarkHeader().?);
                    try require(map.getPrototype() == rt.liveObjectFromWeakIdentity(probe.prototype_identity));
                    const entries = map.collectionEntries();
                    try require(entries.len == (if (key_kind == 0) @as(usize, 1) else 4));
                    for (0..4) |index| {
                        const entry = entries[if (key_kind == 0) 0 else index];
                        if (key_kind == 1) try require(rt.atoms.name(entry.key.asSymbolAtom().?) != null);
                        if (key_kind == 2) try require(entry.key.cycleMarkHeader().? == rt.liveObjectFromWeakIdentity(probe.key_identities[index]).?.gcHeader());
                        const group = core.Object.fromHeader(entry.value.cycleMarkHeader().?);
                        try require(group.arrayLength() == (if (key_kind == 0) @as(u32, 4) else 1));
                        const item = try group.getProperty(core.Atom.taggedInt(if (key_kind == 0) @intCast(index) else 0));
                        if (mode == 4) {
                            try require(item.cycleMarkHeader().? == rt.liveObjectFromWeakIdentity(probe.item_identities[index]).?.gcHeader());
                        } else {
                            const expected = units[starts[index]..starts[index + 1]];
                            try require(core.string.stringValueLenUnchecked(item) == expected.len);
                            for (expected, 0..) |unit, offset| try require(core.string.stringValueCodeUnitAtUnchecked(item, offset) == unit);
                        }
                    }
                }
            }
        }
    }
}

fn verifyTailBufferPublication() !void {
    const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
    defer rt.destroy();
    rt.gc.scheduler.host_quiescent = true;
    var roots = core.runtime.ExactValueRoots(2){};
    try roots.activate(rt);
    defer roots.deactivate();
    const left = try roots.ref(0);
    const right = try roots.ref(1);
    try left.set(rt, (try core.string.String.createAscii(rt, "x" ** 512)).value());
    try right.set(rt, (try core.string.String.createAscii(rt, "!")).value());
    const measured = try core.string.createTailBufferRope(rt, core.string.asFlat(try left.get(rt)).?, core.string.asFlat(try right.get(rt)).?);
    const charge = core.string.accountedStorageSizeFromHeader(measured.buffer.?.header());
    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
    // Admit the buffer but collect at node allocation. The unpublished
    // buffer must remain live, so this cap must produce a recoverable OOM.
    rt.setMemoryLimit(rt.gc.heap_budget.bytes + charge);
    const attempt = core.string.createTailBufferRope(rt, core.string.asFlat(try left.get(rt)).?, core.string.asFlat(try right.get(rt)).?);
    if (attempt) |node| {
        if (!rt.gc.containsHeader(node.buffer.?.header())) return error.LostConcatTailBuffer;
        return error.ExpectedTailNodeOom;
    } else |err| if (err != error.OutOfMemory) return err;
    rt.setMemoryLimit(null);
    const node = try core.string.createTailBufferRope(rt, core.string.asFlat(try left.get(rt)).?, core.string.asFlat(try right.get(rt)).?);
    try require(core.string.stringValueCodeUnitAtUnchecked(node.value(), 512) == '!');
}

fn verifyStringAddRoots() !void {
    const source = [_]u16{ 's', 'o', 'u', 'r', 'c', 'e' };
    const wide = [_]u16{ 0xe9, 0x100, 0xd800 };
    const source_integer = source ++ [_]u16{ '4', '2' };
    const wide_integer = [_]u16{ '4', '2' } ++ wide;
    const source_suffix = source ++ [_]u16{ 'p', 'a', 'r', 't', '!' };
    const source_prefix = [_]u16{'!'} ++ source ++ [_]u16{ 'p', 'a', 'r', 't' };
    const seed = [_]u16{'x'} ** 512 ++ [_]u16{'!'};
    const tail = seed ++ [_]u16{'?'};
    const wide_tail = seed ++ [_]u16{0x100};
    const balanced = [_]u16{'x'} ** 61 ++ [_]u16{'y'} ** 513;
    for ([_]bool{ false, true }) |nursery| {
        for (0..12) |mode| {
            const expected: []const u16 = switch (mode) {
                1 => &wide_integer,
                5 => &.{ '%', 'F', 'F' },
                6 => &source_suffix,
                7 => &source_prefix,
                8 => &seed,
                9 => &tail,
                10 => &wide_tail,
                11 => &balanced,
                else => &source_integer,
            };
            var peak: usize = 0;
            for (0..3) |failure_stage| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
                const inputs = setup: {
                    var roots = core.runtime.ExactValueRoots(3){};
                    try roots.activate(rt);
                    defer roots.deactivate();
                    const left = try roots.ref(0);
                    const right = try roots.ref(1);
                    const temporary = try roots.ref(2);
                    try left.set(rt, (try core.string.String.createAscii(rt, "source")).value());
                    try right.set(rt, core.JSValue.int32(42));
                    switch (mode) {
                        0 => {},
                        1 => {
                            try left.set(rt, core.JSValue.int32(42));
                            try right.set(rt, (try core.string.String.createUtf16(rt, &wide)).value());
                        },
                        2, 3, 4 => {
                            try temporary.set(rt, (try core.string.String.createAscii(rt, "")).value());
                            try left.set(rt, if (mode == 4)
                                (try core.string.createTailBufferRope(rt, core.string.asFlat(try left.get(rt)).?, core.string.asFlat(try temporary.get(rt)).?)).value()
                            else
                                (try core.string.String.createRope(rt, try left.get(rt), try temporary.get(rt))).value());
                            if (mode == 3) try core.string.ensureFlat(rt, left.readOnly(), temporary);
                        },
                        5 => {
                            try left.set(rt, (try core.string.String.createAscii(rt, "%F")).value());
                            try right.set(rt, (try core.string.String.createAscii(rt, "F")).value());
                        },
                        6, 7 => {
                            try temporary.set(rt, (try core.string.String.createAscii(rt, "part")).value());
                            try left.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try temporary.get(rt))).value());
                            try right.set(rt, (try core.string.String.createAscii(rt, "!")).value());
                            if (mode == 7) {
                                const first = try left.get(rt);
                                try left.set(rt, try right.get(rt));
                                try right.set(rt, first);
                            }
                        },
                        8, 9, 10 => {
                            try left.set(rt, (try core.string.String.createAscii(rt, "x" ** 512)).value());
                            try right.set(rt, (try core.string.String.createAscii(rt, "!")).value());
                            if (mode != 8) {
                                try left.set(rt, (try core.string.createTailBufferRope(rt, core.string.asFlat(try left.get(rt)).?, core.string.asFlat(try right.get(rt)).?)).value());
                                try right.set(rt, (try core.string.String.createUtf16(rt, if (mode == 9) &.{'?'} else &.{0x100})).value());
                            }
                        },
                        11 => {
                            try left.set(rt, (try core.string.String.createAscii(rt, "x")).value());
                            try temporary.set(rt, try left.get(rt));
                            for (0..60) |_| try left.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try temporary.get(rt))).value());
                            try right.set(rt, (try core.string.String.createAscii(rt, "y" ** 513)).value());
                        },
                        else => unreachable,
                    }
                    try temporary.set(rt, core.JSValue.undefinedValue());
                    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                    break :setup [_]core.JSValue{ try left.get(rt), try right.get(rt) };
                };
                var candidate_peak: usize = 0;
                rt.gc.heap_budget.beginCyclePeakTracking(&candidate_peak);
                rt.gc.heap_budget.gc_threshold = 0;
                rt.setMemoryLimit(switch (failure_stage) {
                    0 => null,
                    1 => 0,
                    else => peak - 1,
                });
                const epoch = rt.gc.collection_epoch;
                const result = if (mode <= 4)
                    zjs.exec.value_ops.binary(rt, zjs.bytecode.opcode.op.add, inputs[0], inputs[1])
                else
                    zjs.exec.value_ops.addStringsOwned(rt, inputs[0], inputs[1]);
                rt.gc.heap_budget.endCyclePeakTracking();
                rt.setMemoryLimit(null);
                try require(rt.gc.collection_epoch > epoch);
                try require(rt.active_value_roots == null);
                if (failure_stage != 0) {
                    if (result) |_| return error.ExpectedStringAddOom else |err| if (err != error.OutOfMemory) return err;
                    try require(rt.gc.heap_budget.limit_retries > 0);
                    continue;
                }
                peak = candidate_peak;
                var roots = core.runtime.ExactValueRoots(1){};
                try roots.activate(rt);
                defer roots.deactivate();
                const kept = try roots.ref(0);
                try kept.set(rt, try result);
                for (0..2) |pass| {
                    if (pass == 1) _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                    const value = try kept.get(rt);
                    if (core.string.stringValueLenUnchecked(value) != expected.len) return error.StringAddResultChanged;
                    for (expected, 0..) |unit, index| {
                        if (core.string.stringValueCodeUnitAtUnchecked(value, index) != unit) return error.StringAddResultChanged;
                    }
                    if (mode == 11) try require(value.ropeBody().?.depth <= core.string.String.rope_max_depth);
                }
            }
        }
    }
}

fn verifyPrimitiveBoxingRoots() !void {
    const cases = [_]struct { class_id: core.class.ClassId, name: core.Atom }{
        .{ .class_id = core.class.ids.big_int, .name = comptime core.atom.predefinedId("BigInt", .string).? },
        .{ .class_id = core.class.ids.symbol, .name = comptime core.atom.predefinedId("Symbol", .string).? },
        .{ .class_id = core.class.ids.number, .name = comptime core.atom.predefinedId("Number", .string).? },
        .{ .class_id = core.class.ids.boolean, .name = comptime core.atom.predefinedId("Boolean", .string).? },
        .{ .class_id = core.class.ids.string, .name = comptime core.atom.predefinedId("String", .string).? },
        .{ .class_id = core.class.ids.string, .name = comptime core.atom.predefinedId("String", .string).? },
        .{ .class_id = core.class.ids.string, .name = comptime core.atom.predefinedId("String", .string).? },
        .{ .class_id = core.class.ids.big_int, .name = comptime core.atom.predefinedId("BigInt", .string).? },
    };
    const units = [_]u16{ 'a', 0xe9, 0x100, 0xd83d, 0xde00, 0xd800 };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |access| {
            for (cases, 0..) |case, mode| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
                const ctx = try core.JSContext.create(rt, .{});
                defer ctx.destroy();
                _ = try zjs.exec.zjs_vm.contextGlobal(ctx);
                const inputs = setup: {
                    var roots = core.runtime.ExactValueRoots(5){};
                    try roots.activate(rt);
                    defer roots.deactivate();
                    const global = try roots.ref(0);
                    const prototype = try roots.ref(1);
                    const constructor = try roots.ref(2);
                    const input = try roots.ref(3);
                    const right = try roots.ref(4);
                    try global.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                    try prototype.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                    try constructor.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                    try core.Object.fromHeader((try constructor.get(rt)).refHeader().?).defineOwnProperty(rt, core.atom.ids.prototype, core.Descriptor.data(try prototype.get(rt), .all));
                    try core.Object.fromHeader((try global.get(rt)).refHeader().?).defineOwnProperty(rt, case.name, core.Descriptor.data(try constructor.get(rt), .all));
                    try input.set(rt, switch (mode) {
                        0 => (try core.bigint.BigInt.create(rt, (@as(i128, 1) << 90) + 7)).valueRef(),
                        1 => try rt.takeSymbolValue(try rt.atoms.newValueSymbol("boxing-input")),
                        2 => core.JSValue.float64(-0.0),
                        3 => core.JSValue.boolean(true),
                        7 => core.JSValue.shortBigInt(123),
                        else => (try core.string.String.createUtf16(rt, if (mode == 4) &units else units[0..4])).value(),
                    });
                    if (mode == 5 or mode == 6) {
                        try right.set(rt, (try core.string.String.createUtf16(rt, units[4..])).value());
                        try input.set(rt, (try core.string.String.createRope(rt, try input.get(rt), try right.get(rt))).value());
                        if (mode == 6) try core.string.ensureFlat(rt, input.readOnly(), right);
                    }
                    break :setup .{
                        .global = try global.get(rt),
                        .prototype = try prototype.get(rt),
                        .prototype_id = try rt.registerWeakObjectIdentity(core.Object.fromHeader((try prototype.get(rt)).refHeader().?)),
                        .input = try input.get(rt),
                    };
                };
                const header = inputs.input.cycleMarkHeader();
                const before = rt.active_value_roots;
                const epoch = rt.gc.collection_epoch;
                rt.gc.heap_budget.gc_threshold = 0;
                const result = if (access)
                    try zjs.exec.object_ops.primitiveObjectForAccess(rt, core.Object.fromHeader(inputs.global.refHeader().?), inputs.input)
                else
                    try zjs.exec.call.primitiveWrapper(ctx, case.class_id, inputs.input, core.Object.fromHeader(inputs.prototype.refHeader().?));
                if (header) |live| if (!rt.gc.containsHeader(live)) return error.LostPrimitiveBoxingInput;
                const object = core.Object.fromHeader(result.refHeader().?);
                try require(object.class_id == case.class_id);
                try require(object.objectData().?.same(inputs.input));
                try require(object.getPrototype() == rt.liveObjectFromWeakIdentity(inputs.prototype_id).?);
                if (mode >= 4 and mode <= 6) {
                    try require((try object.getProperty(core.atom.ids.length)).as(.int).? == units.len);
                    for (units, 0..) |unit, index| {
                        const descriptor = (try object.getOwnProperty(rt, core.Atom.taggedInt(@intCast(index)))).?;
                        try require(descriptor.enumerable.? and !descriptor.configurable.? and !descriptor.writable.?);
                        try require(core.string.stringValueCodeUnitAtUnchecked(descriptor.value, 0) == unit);
                    }
                    if (mode != 4) try require(inputs.input.ropeBody().?.isLinearized() == (mode == 6));
                }
                try require(rt.gc.collection_epoch > epoch);
                try require(rt.active_value_roots == before);
                var roots = core.runtime.ExactValueRoots(1){};
                try roots.activate(rt);
                defer roots.deactivate();
                const kept = try roots.ref(0);
                try kept.set(rt, result);
                _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                try require(core.Object.fromHeader((try kept.get(rt)).refHeader().?).objectData().?.same(inputs.input));
            }
        }
    }
}

fn verifyDispatchNameSnapshot() !void {
    const Probe = struct {
        constructor: core.runtime.RootedValueRef,
        mode: usize,
        fail: bool,
        calls: usize = 0,
        reused: bool = false,
        injected: bool = false,
        fn run(self: *@This(), ctx: *core.JSContext) !core.JSValue {
            const rt = ctx.runtime;
            self.calls += 1;
            const constructor = core.Object.fromHeader((try self.constructor.get(rt)).refHeader().?);
            const visible = constructor.getOwnDataPropertyValue(core.atom.ids.name).?;
            if (self.mode != 0) try require(visible.ropeBody().?.isLinearized() == (self.mode == 2));
            const flat = if (visible.ropeBody()) |rope| rope.flatString() else core.string.asFlat(visible);
            const name_header = if (flat) |body| body.header() else null;
            try require(constructor.deleteProperty(rt, core.atom.ids.name));
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            const before = rt.active_value_roots;
            const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
            const parse_float = try global.getProperty(comptime core.atom.predefinedId("parseFloat", .string).?);
            const nested = try zjs.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, core.JSValue.undefinedValue(), parse_float, &.{core.JSValue.int32(42)}, null, null);
            try require(nested.as(.int).? == 42);
            try require(rt.active_value_roots == before);
            // Reuse the dead name's cell before the constructor resumes its
            // name comparisons. A borrowed slice must not survive this point.
            if (name_header) |header| {
                try require(!rt.gc.containsHeader(header));
                for (0..1024) |_| {
                    const replacement = try core.string.String.createAscii(rt, "xxxxxxxxxxxxxxxxx");
                    if (replacement.header() == header) {
                        self.reused = true;
                        break;
                    }
                }
                try require(self.reused);
            }
            if (self.fail) {
                self.injected = true;
                return error.OutOfMemory;
            }
            return core.JSValue.int32(8);
        }
        fn thunk(ctx: *core.JSContext, _: core.JSValue, _: [*]const core.JSValue, _: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            return self.run(ctx) catch |err| zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for (0..3) |mode| {
            for ([_]bool{ false, true }) |fail| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
                const ctx = try core.JSContext.create(rt, .{});
                defer ctx.destroy();
                defer ctx.clearException();
                _ = try zjs.exec.zjs_vm.contextGlobal(ctx);
                var roots = core.runtime.ExactValueRoots(4){};
                try roots.activate(rt);
                defer roots.deactivate();
                const constructor = try roots.ref(0);
                const target = try roots.ref(1);
                const input = try roots.ref(2);
                const callback = try roots.ref(3);
                try constructor.set(rt, try core.function.nativeFunction(ctx, "SharedArrayBuffer", 1));
                const constructor_object = core.Object.fromHeader((try constructor.get(rt)).refHeader().?);
                constructor_object.nativeDispatchNameSlot().* = core.atom.null_atom;
                if (mode != 0) {
                    try target.set(rt, (try core.string.String.createAscii(rt, "SharedArray")).value());
                    try input.set(rt, (try core.string.String.createAscii(rt, "Buffer")).value());
                    try target.set(rt, (try core.string.String.createRope(rt, try target.get(rt), try input.get(rt))).value());
                    if (mode == 2) try core.string.ensureFlat(rt, target.readOnly(), input);
                    try core.Object.fromHeader((try constructor.get(rt)).refHeader().?).defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(try target.get(rt), .all));
                }
                var probe = Probe{
                    .constructor = constructor.readOnly(),
                    .mode = mode,
                    .fail = fail,
                };
                try target.set(rt, try core.function.nativeFunction(ctx, "dispatchBoundaryTarget", 0));
                try input.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                try callback.set(rt, try core.function.nativeFunction(ctx, "dispatchBoundaryCoercion", 0));
                const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.thunk), .kind = .managed, .state = &probe });
                core.Object.fromHeader((try callback.get(rt)).refHeader().?).installNativeEntry(entry);
                try core.Object.fromHeader((try input.get(rt)).refHeader().?).defineOwnProperty(rt, core.atom.ids.valueOf, core.Descriptor.data(try callback.get(rt), .all));
                const before = rt.active_value_roots;
                const result = zjs.exec.call_runtime.constructValueOrBytecodeWithNewTarget(ctx, null, try zjs.exec.zjs_vm.contextGlobal(ctx), try constructor.get(rt), &.{try input.get(rt)}, null, null, try target.get(rt));
                if (fail) {
                    // The managed callback seam represents OOM as a pending
                    // JavaScript exception; only the host boundary restores it.
                    if (result) |_| return error.ExpectedDispatchCallbackOom else |err| if (err != error.JSException) return err;
                    try require(probe.injected and ctx.exceptionIsOutOfMemory());
                } else if (core.Object.fromHeader((try result).refHeader().?).class_id != core.class.ids.shared_array_buffer) return error.LostDispatchNameSnapshot;
                try require(probe.calls == 1);
                try require(rt.active_value_roots == before);
            }
        }
    }
}

fn verifyPureValueReadWindows() !void {
    for (0..4) |mode| {
        var failing = std.testing.FailingAllocator.init(std.heap.page_allocator, .{});
        const rt = try core.JSRuntime.create(failing.allocator(), .{});
        defer rt.destroy();
        rt.gc.scheduler.host_quiescent = true;
        const inputs = setup: {
            var roots = core.runtime.ExactValueRoots(4){};
            try roots.activate(rt);
            defer roots.deactivate();
            const input = try roots.ref(0);
            const temporary = try roots.ref(1);
            const map = try roots.ref(2);
            const array = try roots.ref(3);
            try input.set(rt, (try core.string.String.createAscii(rt, if (mode == 3) "X123Y" else if (mode == 0) "123" else "12")).value());
            if (mode == 3) {
                try input.set(rt, (try core.string.String.createValueSlice(rt, try input.get(rt), 1, 3)).value());
            } else if (mode != 0) {
                try temporary.set(rt, (try core.string.String.createAscii(rt, "3")).value());
                try input.set(rt, (try core.string.String.createRope(rt, try input.get(rt), try temporary.get(rt))).value());
                if (mode == 2) try core.string.ensureFlat(rt, input.readOnly(), temporary);
            }
            try map.set(rt, (try core.Object.create(rt, core.class.ids.map, null)).value());
            try core.collection.appendStrongEntryOwned(rt, core.Object.fromHeader((try map.get(rt)).cycleMarkHeader().?), .{ .key = try input.get(rt), .value = core.JSValue.int32(42) });
            try array.set(rt, (try core.Object.createArray(rt, null)).value());
            break :setup [_]core.JSValue{ try input.get(rt), try map.get(rt), try array.get(rt) };
        };
        rt.setMemoryLimit(0);
        rt.gc.heap_budget.gc_threshold = 0;
        const epoch = rt.gc.collection_epoch;
        const native_before = rt.diagnostics.allocations.allocated_bytes;
        failing.fail_index = failing.alloc_index;
        failing.resize_fail_index = failing.resize_index;
        {
            var borrow = core.runtime.NoGcScope{};
            borrow.activate(rt);
            defer borrow.deactivate();
            try require(core.value_semantics.toBoolean(inputs[0]));
            try require(core.collection.mapGetLatin1PrefixIntValue(core.Object.fromHeader(inputs[1].cycleMarkHeader().?), "1", 23).?.as(.int).? == 42);
            const array = core.Object.fromHeader(inputs[2].refHeader().?);
            if (array.defineOwnProperty(rt, core.atom.ids.length, .{ .value = inputs[0], .value_present = true })) |_| return error.ExpectedArrayLengthSnapshotOom else |err| try require(err == error.OutOfMemory);
            try require(array.arrayLength() == 0);
            const integer = core.number.parseIntValue(rt, inputs[0], null);
            const float = core.number.parseFloatValue(rt, inputs[0]);
            if (mode == 1 or mode == 2) {
                if (integer) |_| return error.ExpectedNumberSnapshotOom else |err| try require(err == error.OutOfMemory);
                if (float) |_| return error.ExpectedNumberSnapshotOom else |err| try require(err == error.OutOfMemory);
            } else {
                try require(try integer == 123);
                try require(try float == 123);
            }
        }
        failing.fail_index = std.math.maxInt(usize);
        failing.resize_fail_index = std.math.maxInt(usize);
        const array = core.Object.fromHeader(inputs[2].refHeader().?);
        try array.defineOwnProperty(rt, core.atom.ids.length, .{ .value = inputs[0], .value_present = true });
        try require(array.arrayLength() == 123);
        try require(try core.number.parseIntValue(rt, inputs[0], null) == 123);
        try require(try core.number.parseFloatValue(rt, inputs[0]) == 123);
        if (mode == 1 or mode == 2) try require(inputs[0].ropeBody().?.isLinearized() == (mode == 2));
        try require(rt.gc.collection_epoch == epoch);
        try require(rt.diagnostics.allocations.allocated_bytes == native_before);
        try require(rt.active_value_roots == null);
        if (comptime @import("builtin").mode == .Debug) try require(rt.active_no_gc_scope == null);
    }
}

fn verifyBareNumberAutoInitRoots() !void {
    const Probe = struct {
        owner: core.property.AutoInitModuleOwner = .{ .resolve = resolve },
        array: usize = 0,
        text: ?*core.gc.Header = null,
        value: i32,
        fail: bool,
        calls: usize = 0,
        lost_array: bool = false,
        lost_text: bool = false,
        collection_failure: ?core.gc.CollectionError = null,
        fn resolve(owner: *const core.property.AutoInitModuleOwner, realm_header: *core.gc.Header, _: core.Atom) anyerror!core.property.AutoInitMaterialization {
            const self: *@This() = @constCast(@fieldParentPtr("owner", owner));
            const ctx: *core.JSContext = @alignCast(@fieldParentPtr("header", realm_header));
            const rt = ctx.runtime;
            const epoch = rt.gc.collection_epoch;
            _ = rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only) catch |err| {
                self.collection_failure = err;
                return error.ReferenceError;
            };
            try require(rt.gc.collection_epoch > epoch);
            self.calls += 1;
            self.lost_array = rt.liveObjectFromWeakIdentity(self.array) == null;
            if (self.text) |text| self.lost_text = !rt.gc.containsHeader(text);
            if (self.fail or self.lost_array or self.lost_text) return error.ReferenceError;
            return .{ .value = core.JSValue.int32(self.value) };
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for (0..4) |mode| {
            for ([_]bool{ false, true }) |fail| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const ctx = try core.JSContext.create(rt, .{});
                defer ctx.destroy();
                var probe = Probe{ .value = if (mode == 0) 10 else 123, .fail = fail };
                const inputs = setup: {
                    var roots = core.runtime.ExactValueRoots(3){};
                    try roots.activate(rt);
                    defer roots.deactivate();
                    const array = try roots.ref(0);
                    const module = try roots.ref(1);
                    const text = try roots.ref(2);
                    try module.set(rt, (try core.Object.create(rt, core.class.ids.module_ns, null)).value());
                    const prototype = core.Object.fromHeader((try module.get(rt)).cycleMarkHeader().?);
                    try prototype.defineModuleAutoInitProperty(rt, core.Atom.taggedInt(0), ctx, &probe.owner);
                    try array.set(rt, (try core.Object.createArray(rt, prototype)).value());
                    const object = core.Object.fromHeader((try array.get(rt)).cycleMarkHeader().?);
                    try object.defineOwnProperty(rt, core.Atom.taggedInt(0), core.Descriptor.data(core.JSValue.undefinedValue(), .all));
                    try require(object.deleteProperty(rt, core.Atom.taggedInt(0)));
                    probe.array = try rt.registerWeakObjectIdentity(object);
                    if (mode < 2) {
                        try text.set(rt, (try core.string.String.createAscii(rt, if (mode == 0) "123" else "10")).value());
                        probe.text = (try text.get(rt)).cycleMarkHeader().?;
                    }
                    break :setup [_]core.JSValue{ try array.get(rt), try text.get(rt) };
                };
                const result = switch (mode) {
                    0 => core.number.parseIntValue(rt, inputs[1], inputs[0]),
                    1 => core.number.parseIntValue(rt, inputs[0], inputs[1]),
                    2 => core.number.parseFloatValue(rt, inputs[0]),
                    else => core.number.toNumber(rt, inputs[0]),
                };
                if (probe.collection_failure) |err| return err;
                if (probe.lost_array) return error.LostBareNumberArray;
                if (probe.lost_text) return error.LostBareNumberPendingString;
                try require(probe.calls == 1);
                if (fail) {
                    if (result) |_| return error.ExpectedBareNumberReferenceError else |err| try require(err == error.ReferenceError);
                } else try require(try result == 123);
                try require(rt.active_value_roots == null);
                if (comptime @import("builtin").mode == .Debug) try require(rt.active_no_gc_scope == null);
            }
        }
    }
}

fn verifyNumberParseCoercionRoots() !void {
    try verifyNumberAndIndexCoercionRoots(false);
    try verifyNumberAndIndexCoercionRoots(true);
    try verifyStringIndexAllocationRoots();
}

fn verifyStringIndexAllocationRoots() !void {
    const managed = comptime blk: {
        for (zjs.exec.string_ops.internal_entries) |entry| {
            if (std.mem.eql(u8, entry.name, "charCodeAt")) break :blk entry.managed.?;
        }
        @compileError("missing charCodeAt managed entry");
    };
    const entry = core.NativeEntry{ .target = core.NativeEntry.code(managed), .kind = .managed };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |oom| {
            const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer rt.destroy();
            rt.gc.nursery.enabled = nursery;
            rt.gc.scheduler.host_quiescent = true;
            const ctx = try core.JSContext.create(rt, .{});
            defer ctx.destroy();
            defer ctx.clearException();
            _ = try zjs.exec.zjs_vm.contextGlobal(ctx);
            rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
            const input = setup: {
                var roots = core.runtime.ExactValueRoots(2){};
                try roots.activate(rt);
                defer roots.deactivate();
                const left = try roots.ref(0);
                const right = try roots.ref(1);
                try left.set(rt, (try core.string.String.createAscii(rt, "123")).value());
                try right.set(rt, (try core.string.String.createAscii(rt, "tail")).value());
                break :setup (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value();
            };
            rt.gc.heap_budget.gc_threshold = 0;
            rt.setMemoryLimit(if (oom) 0 else null);
            const epoch = rt.gc.collection_epoch;
            const args = [_]core.JSValue{core.JSValue.int32(1)};
            const result = managed(ctx, input, &args, args.len, &entry, null);
            rt.setMemoryLimit(null);
            try require(rt.gc.collection_epoch > epoch);
            try require(rt.active_value_roots == null);
            if (oom) {
                try require(result.is(.exception));
            } else {
                try require(result.as(.int).? == '2');
            }
        }
    }
}

fn verifyNumberAndIndexCoercionRoots(comptime index_read: bool) !void {
    const Probe = struct {
        text: ?*core.gc.Header = null,
        calls: usize = 0,
        reentries: usize = 0,
        lost: bool = false,
        fail_at: usize,
        rope: bool,
        fn run(self: *@This(), ctx: *core.JSContext) !core.JSValue {
            const rt = ctx.runtime;
            const epoch = rt.gc.collection_epoch;
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            try require(rt.gc.collection_epoch > epoch);
            self.calls += 1;
            if (self.calls == 2) {
                const before = rt.active_value_roots;
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                const parse_float = try global.getProperty(comptime core.atom.predefinedId("parseFloat", .string).?);
                const nested = try zjs.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, core.JSValue.undefinedValue(), parse_float, &.{core.JSValue.int32(42)}, null, null);
                try require(nested.as(.int).? == 42);
                try require(rt.active_value_roots == before);
                self.reentries += 1;
                _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            }
            if (self.text) |text| if (!rt.gc.containsHeader(text)) {
                self.lost = true;
                return error.OutOfMemory;
            };
            if (self.calls == self.fail_at) return error.OutOfMemory;
            if (self.calls == 1) {
                var roots = core.runtime.ExactValueRoots(2){};
                try roots.activate(rt);
                defer roots.deactivate();
                const left = try roots.ref(0);
                const right = try roots.ref(1);
                try left.set(rt, (try core.string.String.createAscii(rt, if (self.rope) "123" else "123tail")).value());
                if (self.rope) {
                    try right.set(rt, (try core.string.String.createAscii(rt, "tail")).value());
                    try left.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value());
                }
                self.text = (try left.get(rt)).cycleMarkHeader().?;
                return left.get(rt);
            }
            return core.JSValue.int32(if (index_read) 1 else 10);
        }
        fn thunk(ctx: *core.JSContext, _: core.JSValue, _: [*]const core.JSValue, _: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            return self.run(ctx) catch |err| zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |rope| {
            for (0..3) |fail_at| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const ctx = try core.JSContext.create(rt, .{});
                defer ctx.destroy();
                defer ctx.clearException();
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                const callable = if (index_read) blk: {
                    const constructor = try global.getProperty(comptime core.atom.predefinedId("String", .string).?);
                    const prototype = try core.Object.fromHeader(constructor.refHeader().?).getProperty(core.atom.ids.prototype);
                    break :blk try core.Object.fromHeader(prototype.refHeader().?).getProperty(comptime core.atom.predefinedId("charCodeAt", .string).?);
                } else try global.getProperty(comptime core.atom.predefinedId("parseInt", .string).?);
                var probe = Probe{ .fail_at = fail_at, .rope = rope };
                const inputs = setup: {
                    var roots = core.runtime.ExactValueRoots(3){};
                    try roots.activate(rt);
                    defer roots.deactivate();
                    const input = try roots.ref(0);
                    const radix = try roots.ref(1);
                    const callback = try roots.ref(2);
                    try input.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                    try radix.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                    try callback.set(rt, try core.function.nativeFunction(ctx, "parseBoundaryCoercion", 0));
                    const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.thunk), .kind = .managed, .state = &probe });
                    core.Object.fromHeader((try callback.get(rt)).cycleMarkHeader().?).installNativeEntry(entry);
                    try core.Object.fromHeader((try input.get(rt)).cycleMarkHeader().?).defineOwnProperty(rt, core.atom.ids.toString, core.Descriptor.data(try callback.get(rt), .all));
                    try core.Object.fromHeader((try radix.get(rt)).cycleMarkHeader().?).defineOwnProperty(rt, core.atom.ids.valueOf, core.Descriptor.data(try callback.get(rt), .all));
                    break :setup [_]core.JSValue{ try input.get(rt), try radix.get(rt) };
                };
                const result = zjs.exec.call_runtime.callValueOrBytecodeRoot(ctx, null, global, if (index_read) inputs[0] else core.JSValue.undefinedValue(), callable, if (index_read) inputs[1..] else &inputs, null, null);
                if (probe.lost) return if (index_read) error.LostStringIndexConvertedString else error.LostParseIntConvertedString;
                if (fail_at == 0) {
                    try require((try result).as(.int).? == (if (index_read) @as(i32, '2') else 123));
                    try require(probe.calls == 2);
                } else {
                    if (result) |_| return error.ExpectedParseIntCoercionFailure else |err| try require(err == error.OutOfMemory or err == error.JSException);
                    try require(probe.calls == fail_at);
                }
                try require(probe.reentries == @as(usize, if (fail_at == 1) 0 else 1));
                try require(rt.active_value_roots == null);
            }
        }
    }
}

fn verifyBitmapHeapBudgetReclaim() !void {
    for ([_]bool{ false, true }) |minor| {
        const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
        defer rt.destroy();
        rt.gc.scheduler.host_quiescent = true;
        rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
        var roots = core.runtime.ExactValueRoots(1){};
        try roots.activate(rt);
        defer roots.deactivate();
        const survivor = try roots.ref(0);
        try survivor.set(rt, (try core.string.String.createAscii(rt, "s" ** 31)).value());
        const baseline = rt.gc.heap_budget.bytes;
        for ([_]usize{ 2, 512, 2 }) |count| {
            for (0..count) |_| _ = try core.string.String.createAscii(rt, "x" ** 31);
            // Weak identity cleanup requires an Object destructor. Its
            // per-cell budget debit must not enter the bitmap bulk debit.
            const dead = try core.Object.create(rt, core.class.ids.raw_json, null);
            const identity = try rt.registerWeakObjectIdentity(dead);
            const epoch = rt.gc.collection_epoch;
            if (minor) {
                _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
            } else {
                _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            }
            try require(rt.gc.collection_epoch > epoch);
            if (rt.gc.heap_budget.bytes != baseline) return error.BitmapReclaimLeakedHeapBudget;
            try require(rt.liveObjectFromWeakIdentity(identity) == null);
            try require(core.string.asFlat(try survivor.get(rt)).?.eqlBytes("s" ** 31));
        }
    }
}

fn verifyRawJsonConstructionRoots() !void {
    const units = [_]u16{'a'} ** 4096;
    const source = "\"" ++ "a" ** 4096 ++ "\"";
    const charges = measured: {
        const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
        defer rt.destroy();
        rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
        const before = rt.gc.heap_budget.bytes;
        _ = try core.string.String.createUtf16(rt, &units);
        const parsed = rt.gc.heap_budget.bytes;
        _ = try core.Object.create(rt, core.class.ids.raw_json, null);
        const object = rt.gc.heap_budget.bytes;
        _ = try core.string.String.createAscii(rt, source);
        break :measured .{ .construction = object - before, .minimum_result = rt.gc.heap_budget.bytes - parsed };
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |rope| {
            for (0..3) |failure_stage| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
                const base = rt.gc.heap_budget.bytes;
                const input = setup: {
                    if (!rope) break :setup (try core.string.String.createAscii(rt, source)).value();
                    var roots = core.runtime.ExactValueRoots(2){};
                    try roots.activate(rt);
                    defer roots.deactivate();
                    const left = try roots.ref(0);
                    const right = try roots.ref(1);
                    try left.set(rt, (try core.string.String.createAscii(rt, source[0..2048])).value());
                    try right.set(rt, (try core.string.String.createAscii(rt, source[2048..])).value());
                    break :setup (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value();
                };
                // Success admits validation and the raw object, then collects
                // on stored text. The late-failure cap cannot fit even the
                // result's object and text, after dropping validation/input.
                rt.setMemoryLimit(switch (failure_stage) {
                    0 => rt.gc.heap_budget.bytes + charges.construction,
                    1 => 0,
                    else => base + charges.minimum_result - 1,
                });
                const epoch = rt.gc.collection_epoch;
                const attempt = zjs.exec.json_ops.rawJSON(rt, input);
                if (rt.gc.collection_epoch == epoch) return error.RawJsonCollectionNotExercised;
                if (rt.active_value_roots != null) return error.LeakedRawJsonRoots;
                if (comptime @import("builtin").mode == .Debug) try require(rt.active_no_gc_scope == null);
                const result = if (failure_stage == 0) try attempt else retry: {
                    if (attempt) |_| return error.ExpectedRawJsonOom else |err| try require(err == error.OutOfMemory);
                    rt.setMemoryLimit(null);
                    // The original input is deliberately no longer rooted.
                    // Recreate it before retrying in the same Runtime.
                    const fresh = (try core.string.String.createAscii(rt, source)).value();
                    break :retry try zjs.exec.json_ops.rawJSON(rt, fresh);
                };
                rt.setMemoryLimit(null);
                if (!rt.gc.containsHeader(result.cycleMarkHeader().?)) return error.LostRawJsonResult;
                var roots = core.runtime.ExactValueRoots(1){};
                try roots.activate(rt);
                defer roots.deactivate();
                const kept = try roots.ref(0);
                try kept.set(rt, result);
                _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                const object = core.Object.fromHeader((try kept.get(rt)).cycleMarkHeader().?);
                if (!zjs.exec.json_ops.isRawJSON(try kept.get(rt))) return error.InvalidRawJsonClass;
                if (object.flags.extensible or object.getPrototype() != null) return error.InvalidRawJsonIntegrity;
                const descriptor = (try object.getOwnProperty(rt, core.atom.ids.rawJSON)).?;
                try require(descriptor.enumerable.? and !descriptor.configurable.? and !descriptor.writable.?);
                if (!core.string.asFlat(descriptor.value).?.eqlBytes(source)) return error.InvalidRawJsonText;
            }
        }
    }
}

fn verifyNativeJsonAutoInitRoots() !void {
    const Probe = struct {
        owner: core.property.AutoInitModuleOwner = .{ .resolve = resolve },
        target: usize = 0,
        old_target: *core.gc.Header = undefined,
        property_list: bool,
        fail_once: bool,
        calls: usize = 0,
        lost: bool = false,
        moved: bool = false,
        collection_failure: ?core.gc.CollectionError = null,
        fn resolve(owner: *const core.property.AutoInitModuleOwner, realm_header: *core.gc.Header, _: core.Atom) anyerror!core.property.AutoInitMaterialization {
            const self: *@This() = @constCast(@fieldParentPtr("owner", owner));
            const realm: *core.JSContext = @alignCast(@fieldParentPtr("header", realm_header));
            const rt = realm.runtime;
            const epoch = rt.gc.collection_epoch;
            _ = rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only) catch |err| {
                self.collection_failure = err;
                return error.OutOfMemory;
            };
            try require(rt.gc.collection_epoch > epoch);
            const target = rt.liveObjectFromWeakIdentity(self.target) orelse {
                self.lost = true;
                return error.ReferenceError;
            };
            self.moved = self.moved or target.gcHeader() != self.old_target;
            self.calls += 1;
            if (self.fail_once and self.calls == 1) return error.ReferenceError;
            return .{ .value = if (self.property_list) (try core.string.String.createAscii(rt, "value")).value() else core.JSValue.int32(9) };
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |property_list| {
            for ([_]bool{ false, true }) |fail_once| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const ctx = try core.JSContext.create(rt, .{});
                defer ctx.destroy();
                var probe = Probe{ .property_list = property_list, .fail_once = fail_once };
                var inputs = setup: {
                    var roots = core.runtime.ExactValueRoots(4){};
                    try roots.activate(rt);
                    defer roots.deactivate();
                    const value = try roots.ref(0);
                    const replacer = try roots.ref(1);
                    const space = try roots.ref(2);
                    const child = try roots.ref(3);
                    try value.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                    if (property_list) {
                        try core.Object.fromHeader((try value.get(rt)).cycleMarkHeader().?).defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.data(core.JSValue.int32(9), .all));
                        // A hole falls through to an inherited lazy module
                        // property; dense Array storage cannot own AUTOINIT.
                        try child.set(rt, (try core.Object.create(rt, core.class.ids.module_ns, null)).value());
                        try core.Object.fromHeader((try child.get(rt)).cycleMarkHeader().?).defineModuleAutoInitProperty(rt, core.Atom.taggedInt(0), ctx, &probe.owner);
                        try replacer.set(rt, (try core.Object.createArray(rt, core.Object.fromHeader((try child.get(rt)).cycleMarkHeader().?))).value());
                        const array = core.Object.fromHeader((try replacer.get(rt)).cycleMarkHeader().?);
                        try array.defineOwnProperty(rt, core.Atom.taggedInt(0), core.Descriptor.data(core.JSValue.undefinedValue(), .all));
                        try require(array.deleteProperty(rt, core.Atom.taggedInt(0)));
                    } else {
                        try child.set(rt, (try core.Object.create(rt, core.class.ids.module_ns, null)).value());
                        try core.Object.fromHeader((try child.get(rt)).cycleMarkHeader().?).defineModuleAutoInitProperty(rt, core.atom.ids.value, ctx, &probe.owner);
                        try core.Object.fromHeader((try value.get(rt)).cycleMarkHeader().?).defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.data(try child.get(rt), .all));
                    }
                    try child.set(rt, (try core.string.String.createAscii(rt, " ")).value());
                    try space.set(rt, (try core.string.String.createRope(rt, try child.get(rt), try child.get(rt))).value());
                    probe.target = try rt.registerWeakObjectIdentity(core.Object.fromHeader((try value.get(rt)).cycleMarkHeader().?));
                    probe.old_target = (try value.get(rt)).cycleMarkHeader().?;
                    break :setup [_]core.JSValue{ try value.get(rt), try replacer.get(rt), try space.get(rt) };
                };
                if (fail_once) {
                    const first = zjs.exec.json_ops.stringify(rt, inputs[0], inputs[1], inputs[2]);
                    if (probe.collection_failure) |err| return err;
                    if (probe.lost) return error.LostNativeJsonAutoInitInput;
                    if (first) |_| return error.ExpectedNativeJsonReferenceError else |err| try require(err == error.ReferenceError);
                    try require(rt.active_value_roots == null);
                    // Reacquire the movable input before retrying. Array and
                    // rope carriers retain stable addresses in this collector.
                    inputs[0] = (rt.liveObjectFromWeakIdentity(probe.target) orelse return error.LostNativeJsonAutoInitInput).value();
                }
                const result = try zjs.exec.json_ops.stringify(rt, inputs[0], inputs[1], inputs[2]);
                if (probe.collection_failure) |err| return err;
                if (probe.lost) return error.LostNativeJsonAutoInitInput;
                try require(core.string.asFlat(result).?.eqlBytes(if (property_list) "{\n  \"value\": 9\n}" else "{\n  \"value\": {\n    \"value\": 9\n  }\n}"));
                try require(probe.calls == (if (fail_once) @as(usize, 2) else 1));
                try require(!inputs[2].ropeBody().?.isLinearized());
                if (nursery) try require(probe.moved);
                try require(rt.active_value_roots == null);
            }
        }
    }
}

fn verifyNativeJsonStringifyRoots() !void {
    const Probe = struct {
        ancestor: usize = 0,
        child: usize = 0,
        old_ancestor: *core.gc.Header = undefined,
        calls: usize = 0,
        fail: bool,
        lost: bool = false,
        skipped: bool = false,
        moved: bool = false,
        failure: ?core.gc.CollectionError = null,
        const methods = core.object.ExoticMethods{ .own_keys = ownKeys };
        fn ownKeys(object: *core.Object, rt: *core.JSRuntime) std.mem.Allocator.Error![]core.Atom {
            const self: *@This() = @ptrCast(@alignCast(rt.classes.recordPtr(object.class_id).?.binding_data.?));
            self.calls += 1;
            if (self.calls > 1) return error.OutOfMemory;
            const epoch = rt.gc.collection_epoch;
            _ = rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only) catch |err| {
                self.failure = err;
                return error.OutOfMemory;
            };
            self.skipped = rt.gc.collection_epoch == epoch;
            const ancestor = rt.liveObjectFromWeakIdentity(self.ancestor);
            if (ancestor == null or rt.liveObjectFromWeakIdentity(self.child) == null) {
                self.lost = true;
                return error.OutOfMemory;
            }
            self.moved = ancestor.?.gcHeader() != self.old_ancestor;
            if (self.fail) return error.OutOfMemory;
            const keys = try rt.allocNative(core.Atom, 1);
            keys[0] = core.atom.ids.value;
            return keys;
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |array| {
            for ([_]bool{ false, true }) |cycle| {
                for ([_]bool{ false, true }) |fail| {
                    const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                    defer rt.destroy();
                    rt.gc.nursery.enabled = nursery;
                    rt.gc.scheduler.host_quiescent = true;
                    var probe = Probe{ .fail = fail };
                    const binding = try rt.registerClass(.{ .class_name = "NativeJsonKeys", .binding_data = &probe, .exotic_methods = &Probe.methods });
                    const input = setup: {
                        var roots = core.runtime.ExactValueRoots(2){};
                        try roots.activate(rt);
                        defer roots.deactivate();
                        const parent = try roots.ref(0);
                        const child = try roots.ref(1);
                        try parent.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                        try child.set(rt, (try core.Object.create(rt, binding.id, null)).value());
                        try core.Object.fromHeader((try child.get(rt)).cycleMarkHeader().?).defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.data(if (cycle) try parent.get(rt) else core.JSValue.int32(7), .all));
                        try core.Object.fromHeader((try parent.get(rt)).cycleMarkHeader().?).defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.data(try child.get(rt), .all));
                        probe.ancestor = try rt.registerWeakObjectIdentity(core.Object.fromHeader((try parent.get(rt)).cycleMarkHeader().?));
                        probe.child = try rt.registerWeakObjectIdentity(core.Object.fromHeader((try child.get(rt)).cycleMarkHeader().?));
                        probe.old_ancestor = (try parent.get(rt)).cycleMarkHeader().?;
                        if (array) {
                            try child.set(rt, (try core.Object.createArray(rt, null)).value());
                            try core.Object.fromHeader((try child.get(rt)).cycleMarkHeader().?).defineOwnProperty(rt, core.Atom.taggedInt(0), core.Descriptor.data(try parent.get(rt), .all));
                            try parent.set(rt, try child.get(rt));
                        }
                        break :setup try parent.get(rt);
                    };
                    const result = zjs.exec.json_ops.stringify(rt, input, core.JSValue.undefinedValue(), core.JSValue.undefinedValue());
                    if (probe.failure) |err| return err;
                    if (probe.lost) return error.LostNativeJsonInput;
                    try require(!probe.skipped and probe.calls == 1);
                    if (fail) {
                        if (result) |_| return error.ExpectedNativeJsonFailure else |err| try require(err == error.OutOfMemory);
                    } else if (cycle) {
                        if (result) |_| return error.ExpectedNativeJsonCycle else |err| try require(err == error.TypeError);
                    } else try require(core.string.asFlat(try result).?.eqlBytes(if (array) "[{\"value\":{\"value\":7}}]" else "{\"value\":{\"value\":7}}"));
                    if (nursery) try require(probe.moved);
                    try require(rt.active_value_roots == null);
                }
            }
        }
    }
}

fn verifyJsonStringifyGetterRoots() !void {
    const Probe = struct {
        calls: usize = 0,
        reentries: usize = 0,
        fail_at: usize,
        delete_later: bool,
        later_key: core.Atom,
        moved: bool = false,
        invalid_receiver: bool = false,
        fn run(self: *@This(), stage: usize, ctx: *core.JSContext, receiver: core.JSValue) !core.JSValue {
            const rt = ctx.runtime;
            const header = receiver.cycleMarkHeader() orelse return error.InvalidStringifyGetterReceiver;
            if (!rt.gc.containsHeader(header)) {
                self.invalid_receiver = true;
                return error.InvalidStringifyGetterReceiver;
            }
            const identity = try rt.registerWeakObjectIdentity(core.Object.fromHeader(header));
            if (stage == 2 and self.delete_later) {
                try require(core.Object.fromHeader(header).deleteProperty(rt, self.later_key));
            }
            const epoch = rt.gc.collection_epoch;
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            try require(rt.gc.collection_epoch > epoch);
            if (stage == 2 and rt.atoms.name(self.later_key) == null) return error.LostStringifySnapshotAtom;
            self.calls += 1;
            // Reenter the serializer with its own cycle stack while the
            // outer getter/toJSON and enumeration frames remain active.
            const nested = try zjs.exec.json_ops.jsonStringifyCall(ctx, null, try zjs.exec.zjs_vm.contextGlobal(ctx), &.{core.JSValue.int32(42)}, null, null);
            try require(core.string.asFlat(nested.?).?.eqlBytes("42"));
            self.reentries += 1;
            const current = rt.liveObjectFromWeakIdentity(identity) orelse return error.InvalidStringifyGetterReceiver;
            self.moved = self.moved or current.gcHeader() != header;
            if (self.calls == self.fail_at) return error.OutOfMemory;
            return switch (stage) {
                0 => current.getProperty(core.atom.ids.value),
                1 => current.value(),
                2 => core.JSValue.int32(1),
                3 => core.JSValue.int32(2),
                else => unreachable,
            };
        }
    };
    const Stage = struct {
        probe: *Probe,
        index: usize,
        fn thunk(ctx: *core.JSContext, receiver: core.JSValue, _: [*]const core.JSValue, _: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            return self.probe.run(self.index, ctx, receiver) catch |err| zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |delete_later| {
            const expected_calls: usize = if (delete_later) 3 else 4;
            for (0..expected_calls + 1) |fail_at| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const ctx = try core.JSContext.create(rt, .{});
                defer ctx.destroy();
                defer ctx.clearException();
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                var probe = Probe{ .fail_at = fail_at, .delete_later = delete_later, .later_key = try rt.internAtom("json-boundary-later") };
                var stages: [4]Stage = undefined;
                const input = setup: {
                    var roots = core.runtime.ExactValueRoots(2){};
                    try roots.activate(rt);
                    defer roots.deactivate();
                    const value = try roots.ref(0);
                    const callable = try roots.ref(1);
                    var key_roots = core.runtime.rootAtoms(.{&probe.later_key});
                    key_roots.activate(rt);
                    defer key_roots.deactivate(rt);
                    try value.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                    for (&stages, 0..) |*stage, index| {
                        stage.* = .{ .probe = &probe, .index = index };
                        try callable.set(rt, try core.function.nativeFunction(ctx, "jsonBoundaryGetter", 0));
                        const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Stage.thunk), .kind = .managed, .state = stage });
                        core.Object.fromHeader((try callable.get(rt)).cycleMarkHeader().?).installNativeEntry(entry);
                        const key = switch (index) {
                            0 => core.atom.ids.toJSON,
                            1 => core.atom.ids.value,
                            2 => try rt.internAtom("a"),
                            3 => probe.later_key,
                            else => unreachable,
                        };
                        const descriptor = if (index == 1) core.Descriptor.data(try callable.get(rt), .{}) else core.Descriptor.accessor(try callable.get(rt), core.JSValue.undefinedValue(), .{ .enumerable = index >= 2, .configurable = true });
                        try core.Object.fromHeader((try value.get(rt)).cycleMarkHeader().?).defineOwnProperty(rt, key, descriptor);
                    }
                    break :setup try value.get(rt);
                };
                const result = zjs.exec.json_ops.jsonStringifyCall(ctx, null, global, &.{input}, null, null);
                if (probe.invalid_receiver) return error.InvalidStringifyGetterReceiver;
                if (fail_at == 0) {
                    try require(core.string.asFlat((try result).?).?.eqlBytes(if (delete_later) "{\"a\":1}" else "{\"a\":1,\"json-boundary-later\":2}"));
                } else if (result) |_| return error.ExpectedStringifyGetterFailure else |err| try require(err == error.OutOfMemory or err == error.JSException);
                try require(probe.calls == (if (fail_at == 0) expected_calls else fail_at));
                try require(probe.reentries == probe.calls);
                if (nursery) try require(probe.moved);
                try require(rt.active_value_roots == null);
            }
        }
    }
}

fn verifyJsonStringifyCallbackRoots() !void {
    const Probe = struct {
        cycle: bool,
        fail: bool,
        calls: usize = 0,
        invalid_receiver: bool = false,
        moved: bool = false,
        ancestor: usize = 0,
        fn run(self: *@This(), ctx: *core.JSContext, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
            if (args.len != 2) return error.InvalidStringifyCallbackArguments;
            if (core.string.asFlat(args[0]).?.len() == 0) return args[1];
            if (args[1].is(.object)) return args[1];
            const rt = ctx.runtime;
            const header = receiver.cycleMarkHeader() orelse return error.InvalidStringifyReceiver;
            if (!rt.gc.containsHeader(header)) {
                self.invalid_receiver = true;
                return error.InvalidStringifyReceiver;
            }
            if (self.calls >= 2) return error.StringifyCycleNotDetected;
            const identity = try rt.registerWeakObjectIdentity(core.Object.fromHeader(header));
            var roots = core.runtime.ExactValueRoots(1){};
            try roots.activate(rt);
            defer roots.deactivate();
            const result = try roots.ref(0);
            try result.set(rt, args[1]);
            const epoch = rt.gc.collection_epoch;
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            try require(rt.gc.collection_epoch > epoch);
            const current = rt.liveObjectFromWeakIdentity(identity) orelse return error.InvalidStringifyReceiver;
            self.moved = self.moved or current.gcHeader() != header;
            self.calls += 1;
            if (self.fail) return error.OutOfMemory;
            return if (self.cycle) (rt.liveObjectFromWeakIdentity(self.ancestor) orelse return error.LostStringifyAncestor).value() else try result.get(rt);
        }
        fn thunk(ctx: *core.JSContext, receiver: core.JSValue, argv: [*]const core.JSValue, argc: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            return self.run(ctx, receiver, argv[0..argc]) catch |err| zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for (0..4) |layout| {
            const array = layout % 2 == 1;
            const depth: usize = if (layout >= 2) 16 else 0;
            for ([_]bool{ false, true }) |cycle| {
                for ([_]bool{ false, true }) |fail| {
                    const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                    defer rt.destroy();
                    rt.gc.nursery.enabled = nursery;
                    rt.gc.scheduler.host_quiescent = true;
                    const ctx = try core.JSContext.create(rt, .{});
                    defer ctx.destroy();
                    defer ctx.clearException();
                    const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                    var probe = Probe{ .cycle = cycle, .fail = fail };
                    errdefer std.debug.print("Stringify callback case: nursery={} array={} depth={d} cycle={} fail={} calls={d} moved={}\n", .{ nursery, array, depth, cycle, fail, probe.calls, probe.moved });
                    const inputs = setup: {
                        var roots = core.runtime.ExactValueRoots(2){};
                        try roots.activate(rt);
                        defer roots.deactivate();
                        const value = try roots.ref(0);
                        const replacer = try roots.ref(1);
                        // Plain objects are nursery eligible; the parser's
                        // preallocated property layout currently is not.
                        try value.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                        try core.Object.fromHeader((try value.get(rt)).cycleMarkHeader().?).defineOwnProperty(rt, try rt.internAtom("a"), core.Descriptor.data(core.JSValue.int32(1), .all));
                        try core.Object.fromHeader((try value.get(rt)).cycleMarkHeader().?).defineOwnProperty(rt, try rt.internAtom("b"), core.Descriptor.data(core.JSValue.int32(2), .all));
                        for (0..depth) |_| {
                            try replacer.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                            try core.Object.fromHeader((try replacer.get(rt)).cycleMarkHeader().?).defineOwnProperty(rt, try rt.internAtom("child"), core.Descriptor.data(try value.get(rt), .all));
                            try value.set(rt, try replacer.get(rt));
                        }
                        probe.ancestor = try rt.registerWeakObjectIdentity(core.Object.fromHeader((try value.get(rt)).cycleMarkHeader().?));
                        if (array) try value.set(rt, try zjs.exec.array_ops.createArrayFromArgs(rt, global, &.{try value.get(rt)}));
                        try replacer.set(rt, try core.function.nativeFunction(ctx, "jsonBoundaryReplacer", 2));
                        const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.thunk), .kind = .managed, .state = &probe });
                        core.Object.fromHeader((try replacer.get(rt)).cycleMarkHeader().?).installNativeEntry(entry);
                        break :setup [_]core.JSValue{ try value.get(rt), try replacer.get(rt) };
                    };
                    const result = zjs.exec.json_ops.jsonStringifyCall(ctx, null, global, &inputs, null, null);
                    if (probe.invalid_receiver) return error.InvalidStringifyReceiver;
                    if (fail) {
                        if (result) |_| return error.ExpectedStringifyCallbackFailure else |err| try require(err == error.OutOfMemory or err == error.JSException);
                    } else if (cycle) {
                        if (result) |_| return error.ExpectedStringifyCycle else |err| try require(err == error.TypeError or err == error.JSException);
                    } else {
                        var expected = std.ArrayList(u8).empty;
                        defer expected.deinit(rt.nativeAllocator());
                        if (array) try expected.append(rt.nativeAllocator(), '[');
                        for (0..depth) |_| try expected.appendSlice(rt.nativeAllocator(), "{\"child\":");
                        try expected.appendSlice(rt.nativeAllocator(), "{\"a\":1,\"b\":2}");
                        try expected.appendNTimes(rt.nativeAllocator(), '}', depth);
                        if (array) try expected.append(rt.nativeAllocator(), ']');
                        if (!core.string.asFlat((try result).?).?.eqlBytes(expected.items)) return error.StringifyCallbackOutputMismatch;
                    }
                    if (probe.calls != (if (fail or cycle) @as(usize, 1) else 2)) return error.StringifyCallbackCountMismatch;
                    if (nursery and !probe.moved) return error.StringifyReceiverDidNotMove;
                    try require(rt.active_value_roots == null);
                }
            }
        }
    }
}

fn verifyJsonGapReadWindows() !void {
    for (0..4) |mode| {
        var failures: usize = 0;
        var succeeded = false;
        for (0..8) |offset| {
            var failing = std.testing.FailingAllocator.init(std.heap.page_allocator, .{});
            const rt = try core.JSRuntime.create(failing.allocator(), .{});
            defer rt.destroy();
            const ctx = try core.JSContext.create(rt, .{});
            defer ctx.destroy();
            const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
            const input = setup: {
                var roots = core.runtime.ExactValueRoots(3){};
                try roots.activate(rt);
                defer roots.deactivate();
                const left = try roots.ref(0);
                const right = try roots.ref(1);
                const result = try roots.ref(2);
                const units = [_]u16{0xd800} ** 10 ++ [_]u16{ 'x', 'y' };
                if (mode == 0) {
                    try result.set(rt, (try core.string.String.createUtf16(rt, &units)).value());
                } else if (mode == 3) {
                    try left.set(rt, (try core.string.String.createUtf16(rt, &(.{0x100} ++ units ++ .{0x100}))).value());
                    try result.set(rt, (try core.string.String.createValueSlice(rt, try left.get(rt), 1, units.len)).value());
                } else {
                    try left.set(rt, (try core.string.String.createUtf16(rt, units[0..5])).value());
                    try right.set(rt, (try core.string.String.createUtf16(rt, units[5..])).value());
                    try result.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value());
                    if (mode == 2) try core.string.ensureFlat(rt, result.readOnly(), left);
                }
                break :setup try result.get(rt);
            };
            // No caller roots; every native output growth can independently
            // fail. Partial output belongs to the callee even on OOM.
            rt.setMemoryLimit(0);
            rt.gc.heap_budget.gc_threshold = 0;
            const native_before = rt.diagnostics.allocations.allocated_bytes;
            const epoch = rt.gc.collection_epoch;
            failing.fail_index = failing.alloc_index + offset;
            failing.resize_fail_index = failing.resize_index;
            const result = zjs.exec.json_ops.jsonStringifyGap(ctx, null, global, input, null, null);
            failing.fail_index = std.math.maxInt(usize);
            failing.resize_fail_index = std.math.maxInt(usize);
            if (result) |bytes| {
                var gap = bytes;
                defer gap.deinit(rt.nativeAllocator());
                try require(std.mem.eql(u8, gap.items, "\xed\xa0\x80" ** 10));
                succeeded = true;
            } else |err| {
                try require(err == error.OutOfMemory);
                failures += 1;
            }
            try require(native_before == rt.diagnostics.allocations.allocated_bytes);
            if (mode == 1 or mode == 2) try require(input.ropeBody().?.isLinearized() == (mode == 2));
            try require(rt.gc.collection_epoch == epoch);
            if (comptime @import("builtin").mode == .Debug) try require(rt.active_no_gc_scope == null);
            try require(rt.active_value_roots == null);
            if (succeeded) break;
        }
        // At most 30 WTF-8 bytes fit the ArrayList's first allocation on
        // this target; sweep until success without assuming extra growth.
        try require(succeeded and failures >= 1);
    }
}

fn verifyJsonStringifyOptionRoots() !void {
    const Probe = struct {
        target: usize,
        replacer: usize,
        target_header: *core.gc.Header,
        calls: usize = 0,
        fail_call: usize,
        lost: bool = false,
        moved: bool = false,
        fn run(self: *@This(), ctx: *core.JSContext) !core.JSValue {
            const rt = ctx.runtime;
            const key = try rt.internAtom("orphan-option-key");
            if (self.calls == 0) {
                const array = rt.liveObjectFromWeakIdentity(self.replacer) orelse return error.LostStringifyReplacer;
                _ = array.deleteProperty(rt, core.Atom.taggedInt(0));
            }
            const epoch = rt.gc.collection_epoch;
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            try require(rt.gc.collection_epoch > epoch);
            self.calls += 1;
            const target = rt.liveObjectFromWeakIdentity(self.target);
            if (target == null or rt.liveObjectFromWeakIdentity(self.replacer) == null or rt.atoms.name(key) == null) {
                self.lost = true;
                return error.LostStringifyOptionRoot;
            }
            self.moved = self.moved or target.?.gcHeader() != self.target_header;
            if (self.calls == self.fail_call) return error.OutOfMemory;
            return if (self.calls == 1) core.JSValue.undefinedValue() else core.JSValue.int32(2);
        }
        fn thunk(ctx: *core.JSContext, _: core.JSValue, _: [*]const core.JSValue, _: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            return self.run(ctx) catch |err| zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for (0..3) |fail_call| {
            const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer rt.destroy();
            rt.gc.nursery.enabled = nursery;
            rt.gc.scheduler.host_quiescent = true;
            const ctx = try core.JSContext.create(rt, .{});
            defer ctx.destroy();
            defer ctx.clearException();
            const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
            var probe: Probe = undefined;
            const inputs = setup: {
                var roots = core.runtime.ExactValueRoots(5){};
                try roots.activate(rt);
                defer roots.deactivate();
                const target = try roots.ref(0);
                const replacer = try roots.ref(1);
                const space = try roots.ref(2);
                const callable = try roots.ref(3);
                const key = try roots.ref(4);
                try target.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                try key.set(rt, (try core.string.String.createAscii(rt, "orphan-option-key")).value());
                try replacer.set(rt, try zjs.exec.array_ops.createArrayFromArgs(rt, global, &.{ try key.get(rt), core.JSValue.undefinedValue() }));
                try space.set(rt, (try core.Object.create(rt, core.class.ids.number, null)).value());
                core.Object.fromHeader((try space.get(rt)).cycleMarkHeader().?).objectDataSlot().* = core.JSValue.int32(2);
                try callable.set(rt, try core.function.nativeFunction(ctx, "jsonOptionCoercion", 0));
                const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.thunk), .kind = .managed, .state = &probe });
                core.Object.fromHeader((try callable.get(rt)).cycleMarkHeader().?).installNativeEntry(entry);
                try core.Object.fromHeader((try replacer.get(rt)).cycleMarkHeader().?).defineOwnProperty(rt, core.Atom.taggedInt(1), core.Descriptor.accessor(try callable.get(rt), core.JSValue.undefinedValue(), .all));
                try core.Object.fromHeader((try space.get(rt)).cycleMarkHeader().?).defineOwnProperty(rt, core.atom.ids.valueOf, core.Descriptor.data(try callable.get(rt), .all));
                probe = .{
                    .target = try rt.registerWeakObjectIdentity(core.Object.fromHeader((try target.get(rt)).cycleMarkHeader().?)),
                    .replacer = try rt.registerWeakObjectIdentity(core.Object.fromHeader((try replacer.get(rt)).cycleMarkHeader().?)),
                    .target_header = (try target.get(rt)).cycleMarkHeader().?,
                    .fail_call = fail_call,
                };
                break :setup [_]core.JSValue{ try target.get(rt), try replacer.get(rt), try space.get(rt) };
            };
            const result = zjs.exec.json_ops.jsonStringifyCall(ctx, null, global, &inputs, null, null);
            if (probe.lost) return error.LostStringifyOptionRoot;
            if (fail_call == 0) {
                try require(core.string.asFlat((try result).?).?.eqlBytes("{}"));
            } else if (result) |_| return error.ExpectedStringifyOptionFailure else |err| try require(err == error.OutOfMemory or err == error.JSException);
            try require(probe.calls == (if (fail_call == 0) @as(usize, 2) else fail_call));
            if (nursery) try require(probe.moved);
            try require(rt.active_value_roots == null);
        }
    }
}

fn verifyJsonQuoteReadWindows() !void {
    for (0..4) |mode| {
        for ([_]bool{ false, true }) |fail| {
            var failing = std.testing.FailingAllocator.init(std.heap.page_allocator, .{});
            const rt = try core.JSRuntime.create(failing.allocator(), .{});
            defer rt.destroy();
            const input = setup: {
                var roots = core.runtime.ExactValueRoots(3){};
                try roots.activate(rt);
                defer roots.deactivate();
                const left = try roots.ref(0);
                const right = try roots.ref(1);
                const result = try roots.ref(2);
                const units = [_]u16{ 'a', 0xe9, 0xd83d, 0xde00, 0xd800, '"' };
                if (mode == 0) {
                    try result.set(rt, (try core.string.String.createUtf16(rt, &units)).value());
                } else if (mode == 3) {
                    try left.set(rt, (try core.string.String.createUtf16(rt, &(.{0x100} ++ units ++ .{0x100}))).value());
                    try result.set(rt, (try core.string.String.createValueSlice(rt, try left.get(rt), 1, units.len)).value());
                } else {
                    try left.set(rt, (try core.string.String.createUtf16(rt, units[0..3])).value());
                    try right.set(rt, (try core.string.String.createUtf16(rt, units[3..])).value());
                    try result.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value());
                    if (mode == 2) try core.string.ensureFlat(rt, result.readOnly(), left);
                }
                break :setup try result.get(rt);
            };
            // No caller roots or JS allocation budget. The escaper must only
            // borrow its input and may fail solely on native output growth.
            rt.setMemoryLimit(0);
            rt.gc.heap_budget.gc_threshold = 0;
            if (fail) failing.fail_index = failing.alloc_index;
            const epoch = rt.gc.collection_epoch;
            var bytes = std.ArrayList(u8).empty;
            defer bytes.deinit(rt.nativeAllocator());
            const result = core.json.appendJsonStringValue(rt, &bytes, input);
            failing.fail_index = std.math.maxInt(usize);
            if (fail) {
                if (result) |_| return error.ExpectedJsonQuoteOom else |err| try require(err == error.OutOfMemory);
            } else {
                try result;
                try require(std.mem.eql(u8, bytes.items, "\"a\xc3\xa9\xf0\x9f\x98\x80\\ud800\\\"\""));
            }
            if (mode == 1 or mode == 2) try require(input.ropeBody().?.isLinearized() == (mode == 2));
            try require(rt.gc.collection_epoch == epoch);
            if (comptime @import("builtin").mode == .Debug) try require(rt.active_no_gc_scope == null);
            try require(rt.active_value_roots == null);
        }
    }
}

fn verifyJsonReviverRoots() !void {
    const Probe = struct {
        calls: usize = 0,
        invalid_holder: bool = false,
        mode: usize,
        fail_call: usize,
        shadowed_first: bool,
        moved: bool = false,
        fn run(self: *@This(), ctx: *core.JSContext, receiver: core.JSValue, args: []const core.JSValue) !core.JSValue {
            if (args.len != 3) return error.InvalidReviverArguments;
            const rt = ctx.runtime;
            const header = receiver.cycleMarkHeader() orelse return error.InvalidReviverHolder;
            if (!rt.gc.containsHeader(header)) {
                self.invalid_holder = true;
                return error.InvalidReviverHolder;
            }
            const key = core.string.asFlat(args[0]).?;
            const first = key.eqlBytes("a");
            if (key.eqlBytes("")) {
                const held = try core.Object.fromHeader(header).getProperty(core.atom.ids.empty_string);
                if (held.bits != args[1].bits) {
                    self.invalid_holder = true;
                    return error.InvalidReviverHolder;
                }
            } else {
                const context = core.Object.fromHeader(args[2].cycleMarkHeader().?);
                const source = try context.getProperty(core.atom.ids.source);
                if (first and self.shadowed_first) {
                    try require(source.is(.undefined_value));
                } else try require(core.string.asFlat(source).?.eqlBytes(if (first) "1" else "2"));
            }
            const identity = try rt.registerWeakObjectIdentity(core.Object.fromHeader(header));
            var roots = core.runtime.ExactValueRoots(1){};
            try roots.activate(rt);
            defer roots.deactivate();
            const result = try roots.ref(0);
            try result.set(rt, args[1]);
            const epoch = rt.gc.collection_epoch;
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            try require(rt.gc.collection_epoch > epoch);
            const current = rt.liveObjectFromWeakIdentity(identity) orelse return error.InvalidReviverHolder;
            self.moved = self.moved or current.gcHeader() != header;
            self.calls += 1;
            if (self.calls == self.fail_call) return error.OutOfMemory;
            if (first and self.mode == 1) return core.JSValue.undefinedValue();
            if (first and self.mode == 2) {
                const replacement = try core.Object.createPlainObject(rt, null);
                try result.set(rt, replacement.value());
                try replacement.defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.data(core.JSValue.int32(99), .all));
            }
            return result.get(rt);
        }
        fn thunk(ctx: *core.JSContext, receiver: core.JSValue, argv: [*]const core.JSValue, argc: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            return self.run(ctx, receiver, argv[0..argc]) catch |err| zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for (0..3) |mode| {
            for (0..4) |fail_call| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                const ctx = try core.JSContext.create(rt, .{});
                defer ctx.destroy();
                defer ctx.clearException();
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                var probe = Probe{ .mode = mode, .fail_call = fail_call, .shadowed_first = nursery };
                rt.gc.scheduler.host_quiescent = true;
                var source_bytes = std.ArrayList(u8).empty;
                defer source_bytes.deinit(rt.nativeAllocator());
                if (nursery) {
                    // The callback's readonly context argument pins its page.
                    // A shadowed parse-record subtree separates that page from
                    // the receiver and tests orphan-record ownership as well.
                    try source_bytes.appendSlice(rt.nativeAllocator(), "{\"a\":[{}");
                    for (0..2048) |_| try source_bytes.appendSlice(rt.nativeAllocator(), ",{}");
                    try source_bytes.appendSlice(rt.nativeAllocator(), "],\"a\":1,\"b\":2}");
                } else try source_bytes.appendSlice(rt.nativeAllocator(), "{\"a\":1,\"b\":2}");
                const inputs = setup: {
                    var roots = core.runtime.ExactValueRoots(2){};
                    try roots.activate(rt);
                    defer roots.deactivate();
                    const source = try roots.ref(0);
                    const reviver = try roots.ref(1);
                    try source.set(rt, (try core.string.String.createAscii(rt, source_bytes.items)).value());
                    try reviver.set(rt, try core.function.nativeFunction(ctx, "jsonBoundaryReviver", 2));
                    const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.thunk), .kind = .managed, .state = &probe });
                    core.Object.fromHeader((try reviver.get(rt)).cycleMarkHeader().?).installNativeEntry(entry);
                    break :setup [_]core.JSValue{ try source.get(rt), try reviver.get(rt) };
                };
                const result = zjs.exec.json_ops.jsonParseCall(ctx, null, global, &inputs, null, null);
                if (probe.invalid_holder) return error.InvalidReviverHolder;
                if (fail_call == 0) {
                    const object = core.Object.fromHeader((try result).?.cycleMarkHeader().?);
                    const a = try object.getProperty(try rt.internAtom("a"));
                    switch (mode) {
                        0 => try require(a.as(.int).? == 1),
                        1 => try require(a.is(.undefined_value)),
                        2 => try require((try core.Object.fromHeader(a.cycleMarkHeader().?).getProperty(core.atom.ids.value)).as(.int).? == 99),
                        else => unreachable,
                    }
                    try require((try object.getProperty(try rt.internAtom("b"))).as(.int).? == 2);
                } else if (result) |_| return error.ExpectedReviverFailure else |err| try require(err == error.OutOfMemory or err == error.JSException);
                try require(probe.calls == (if (fail_call == 0) @as(usize, 3) else fail_call));
                if (nursery and !probe.moved) {
                    std.debug.print("Reviver receiver did not move: mode={d} fail_call={d}\n", .{ mode, fail_call });
                    return error.ReviverReceiverDidNotMove;
                }
                try require(rt.active_value_roots == null);
            }
        }
    }
}

fn verifyJsonParseReadWindows() !void {
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |full| {
            for ([_]bool{ false, true }) |fail| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const input = setup: {
                    var roots = core.runtime.ExactValueRoots(2){};
                    try roots.activate(rt);
                    defer roots.deactivate();
                    const left = try roots.ref(0);
                    const right = try roots.ref(1);
                    try left.set(rt, (try core.string.String.createAscii(rt, "{\"a\":[{\"b\":\"")).value());
                    try right.set(rt, (try core.string.String.createAscii(rt, if (full) "\\u0078\"},2]}" else "x\"},2]}")).value());
                    break :setup (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value();
                };
                rt.gc.heap_budget.gc_threshold = 0;
                if (fail) rt.setMemoryLimit(0);
                const epoch = rt.gc.collection_epoch;
                const result = zjs.exec.json_ops.parse(rt, null, input);
                if (fail) {
                    if (result) |_| return error.ExpectedJsonParseOom else |err| try require(err == error.OutOfMemory);
                } else {
                    const object = core.Object.fromHeader((try result).cycleMarkHeader().?);
                    const array_value = try object.getProperty(try rt.internAtom("a"));
                    const array = core.Object.fromHeader(array_value.cycleMarkHeader().?);
                    try require((try array.getProperty(core.Atom.taggedInt(1))).as(.int).? == 2);
                    const child = core.Object.fromHeader((try array.getProperty(core.Atom.taggedInt(0))).cycleMarkHeader().?);
                    const text = try child.getProperty(try rt.internAtom("b"));
                    try require(core.string.asFlat(text).?.eqlBytes("x"));
                }
                try require(rt.gc.collection_epoch > epoch);
                try require(rt.active_value_roots == null);
            }
        }
    }
}

fn verifyDateReadWindows() !void {
    for (0..3) |mode| {
        for ([_]bool{ false, true }) |fail| {
            const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer rt.destroy();
            rt.gc.scheduler.host_quiescent = true;
            // Multi-argument Date construction uses local time, unlike UTC.
            // Compare rope arguments with immediate numbers in the same zone.
            const expected: f64 = if (mode == 2) blk: {
                const numeric = try zjs.exec.date_ops.construct(rt, &.{ core.JSValue.int32(1970), core.JSValue.int32(0), core.JSValue.int32(1) });
                break :blk zjs.exec.value_ops.numberValue(try zjs.exec.date_ops.methodCall(rt, numeric, .get_time)).?;
            } else if (mode == 1) 123 else 0;
            const input = setup: {
                var roots = core.runtime.ExactValueRoots(2){};
                try roots.activate(rt);
                defer roots.deactivate();
                const left = try roots.ref(0);
                const right = try roots.ref(1);
                if (mode == 1) break :setup try zjs.exec.date_ops.construct(rt, &.{core.JSValue.int32(123)});
                try left.set(rt, (try core.string.String.createAscii(rt, if (mode == 0) "1970-01-" else "19")).value());
                try right.set(rt, (try core.string.String.createAscii(rt, if (mode == 0) "01T00:00:00.000Z" else "70")).value());
                break :setup (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value();
            };
            var args = [_]core.JSValue{ input, core.JSValue.int32(0), core.JSValue.int32(1) };
            const selected = args[0..@as(usize, if (mode == 2) 3 else 1)];
            const epoch = rt.gc.collection_epoch;
            rt.setMemoryLimit(0);
            if (mode != 1) {
                const parsed = try zjs.exec.date_ops.staticCall(rt, if (mode == 0) .parse else .utc, selected);
                try require(zjs.exec.value_ops.numberValue(parsed).? == 0);
                try require(!input.ropeBody().?.isLinearized());
                try require(rt.gc.collection_epoch == epoch);
            }
            if (!fail) rt.setMemoryLimit(null);
            rt.gc.heap_budget.gc_threshold = 0;
            // The constructor must consume unrooted inputs before this
            // allocation collects their storage; it needs only the scalar ms.
            const result = zjs.exec.date_ops.construct(rt, selected);
            if (fail) {
                if (result) |_| return error.ExpectedDateOom else |err| try require(err == error.OutOfMemory);
            } else {
                const ms = try zjs.exec.date_ops.methodCall(rt, try result, .get_time);
                if (zjs.exec.value_ops.numberValue(ms).? != expected) return error.DateConstructorValueMismatch;
            }
            try require(rt.gc.collection_epoch > epoch);
            try require(rt.active_value_roots == null);
        }
    }
}

fn verifyDateCoercionRoots() !void {
    const Probe = struct {
        receiver: *core.gc.Header,
        later_identity: usize,
        check_receiver: bool,
        check_later: bool,
        fail: bool,
        calls: usize = 0,
        lost: bool = false,
        fn run(self: *@This(), ctx: *core.JSContext) !core.JSValue {
            const rt = ctx.runtime;
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            self.calls += 1;
            if ((self.check_receiver and !rt.gc.containsHeader(self.receiver)) or
                (self.check_later and rt.liveObjectFromWeakIdentity(self.later_identity) == null))
            {
                self.lost = true;
                return error.LostDateInput;
            }
            if (self.fail) return error.OutOfMemory;
            return core.JSValue.int32(23);
        }
        fn thunk(ctx: *core.JSContext, _: core.JSValue, _: [*]const core.JSValue, _: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            return self.run(ctx) catch |err| zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for (0..7) |mode| {
            for ([_]bool{ false, true }) |fail| {
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const ctx = try core.JSContext.create(rt, .{});
                defer ctx.destroy();
                defer ctx.clearException();
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                var probe: Probe = undefined;
                const inputs = setup: {
                    var roots = core.runtime.ExactValueRoots(4){};
                    try roots.activate(rt);
                    defer roots.deactivate();
                    const callable = try roots.ref(0);
                    const first = try roots.ref(1);
                    const later = try roots.ref(2);
                    const date = try roots.ref(3);
                    try callable.set(rt, try core.function.nativeFunction(ctx, "dateBoundaryCoercion", 0));
                    const entry = try rt.allocNativeEntry(.{ .target = core.NativeEntry.code(&Probe.thunk), .kind = .managed, .state = &probe });
                    core.Object.fromHeader((try callable.get(rt)).cycleMarkHeader().?).installNativeEntry(entry);
                    for ([_]core.runtime.MutableRootedValueRef{ first, later }) |root| {
                        try root.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                        try core.Object.fromHeader((try root.get(rt)).cycleMarkHeader().?).defineOwnProperty(rt, core.atom.ids.valueOf, core.Descriptor.data(try callable.get(rt), .all));
                    }
                    try date.set(rt, try zjs.exec.date_ops.construct(rt, &.{core.JSValue.int32(0)}));
                    break :setup [_]core.JSValue{ try date.get(rt), try first.get(rt), try later.get(rt) };
                };
                const later_identity = try rt.registerWeakObjectIdentity(core.Object.fromHeader(inputs[2].cycleMarkHeader().?));
                probe = .{ .receiver = inputs[0].cycleMarkHeader().?, .later_identity = later_identity, .check_receiver = mode < 4, .check_later = mode >= 2, .fail = fail };
                const result = switch (mode) {
                    0 => zjs.exec.date_ops.dateSetTime(ctx, null, global, inputs[0], inputs[1..], null, null),
                    1 => zjs.exec.date_ops.dateSetYear(ctx, null, global, inputs[0], inputs[1..], null, null),
                    2 => zjs.exec.date_ops.dateCapturedSetterCall(ctx, null, global, inputs[0], .set_hours, inputs[1..], null, null),
                    3 => zjs.exec.builtin_dispatch.callInternalRecord(ctx, null, global, &.{}, null, inputs[0], .{ .domain = .date, .id = @intFromEnum(zjs.exec.date_ops.PrototypeMethod.set_utc_hours) }, inputs[1..], null, null),
                    4 => zjs.exec.date_ops.dateStaticCall(ctx, null, global, core.JSValue.undefinedValue(), .utc, inputs[1..], null, null),
                    else => optionalValueResult(zjs.exec.date_ops.dateConstructWithPrototype(ctx, null, global, core.Object.fromHeader(inputs[2].cycleMarkHeader().?), inputs[1..@as(usize, if (mode == 5) 2 else 3)])),
                };
                try require(!probe.lost);
                if (fail) {
                    if (result) |_| return error.ExpectedDateCoercionFailure else |err| try require(err == error.OutOfMemory or err == error.JSException);
                    if (mode < 4) {
                        const unchanged = try zjs.exec.date_ops.methodCall(rt, inputs[0], .get_time);
                        try require(zjs.exec.value_ops.numberValue(unchanged).? == 0);
                    }
                } else if (mode >= 5) {
                    const date = core.Object.fromHeader((try result).?.cycleMarkHeader().?);
                    try require(date.getPrototype() == rt.liveObjectFromWeakIdentity(later_identity));
                } else try require((try result).?.isNumber());
                if (nursery and (mode == 2 or mode >= 5)) {
                    // The second argument is not part of the first callback's
                    // invocation. Only the setter's mutable snapshot roots it.
                    const moved = rt.liveObjectFromWeakIdentity(later_identity).?;
                    try require(moved.gcHeader() != inputs[2].cycleMarkHeader().?);
                }
                try require(probe.calls == @as(usize, if (fail or mode < 2 or mode == 5) 1 else 2));
                try require(rt.active_value_roots == null);
            }
        }
    }
}

fn verifyDateCallbackChains() !void {
    const Probe = struct {
        receiver_id: usize = 0,
        json: bool,
        exotic_hint: ?[]const u8 = null,
        absent_exotic: bool = false,
        fail_stage: u16,
        sequence: u16 = 0,
        moved: bool = false,
        stale: bool = false,
        lost: bool = false,
        fn run(self: *@This(), ctx: *core.JSContext, incoming: core.JSValue, stage: u16) !core.JSValue {
            const rt = ctx.runtime;
            const previous = rt.liveObjectFromWeakIdentity(self.receiver_id) orelse return error.DateCallbackReceiverLost;
            // Do not dereference incoming: an un-repaired caller snapshot
            // can name a poisoned nursery forwarding husk.
            if (incoming.cycleMarkHeader() != previous.gcHeader()) {
                self.stale = true;
                return error.DateCallbackReceiverStale;
            }
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            const current = rt.liveObjectFromWeakIdentity(self.receiver_id) orelse {
                self.lost = true;
                return error.DateCallbackReceiverLost;
            };
            self.moved = self.moved or current != previous;
            self.sequence = self.sequence * 10 + stage;
            if (self.fail_stage == stage) return error.OutOfMemory;
            return switch (stage) {
                1 => if (self.absent_exotic) core.JSValue.undefinedValue() else current.getProperty(if (self.json or self.exotic_hint != null) core.atom.ids.value else core.atom.ids.name),
                2 => if (self.json) core.JSValue.int32(0) else current.value(),
                3 => core.JSValue.int32(47),
                else => error.InvalidDateCallbackStage,
            };
        }
        fn thunk(ctx: *core.JSContext, incoming: core.JSValue, argv: [*]const core.JSValue, argc: u32, entry: *const core.NativeEntry, _: ?*core.Object) callconv(.c) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(entry.state.?));
            if (entry.magic == 3) if (self.exotic_hint) |hint| {
                if (argc != 1) return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, error.InvalidPrimitiveHint);
                const actual = core.string.asFlat(argv[0]) orelse return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, error.InvalidPrimitiveHint);
                if (!actual.eqlBytes(hint)) return zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, error.InvalidPrimitiveHint);
            };
            return self.run(ctx, incoming, entry.magic) catch |err| zjs.exec.builtin_dispatch.embedderErrorToValue(ctx, err);
        }
        fn function(self: *@This(), ctx: *core.JSContext, stage: u16) !core.JSValue {
            const value = try core.function.nativeFunction(ctx, "dateBoundaryStage", 0);
            const entry = try ctx.runtime.allocNativeEntry(.{ .target = core.NativeEntry.code(&thunk), .kind = .managed, .state = self, .magic = stage });
            core.Object.fromHeader(value.cycleMarkHeader().?).installNativeEntry(entry);
            return value;
        }
    };
    for ([_]bool{ false, true }) |nursery| {
        for (0..8) |mode| {
            for (0..4) |fail_stage| {
                if ((mode == 5 or mode == 6) and fail_stage == 2) continue;
                const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                defer rt.destroy();
                rt.gc.nursery.enabled = nursery;
                rt.gc.scheduler.host_quiescent = true;
                const ctx = try core.JSContext.create(rt, .{});
                defer ctx.destroy();
                defer ctx.clearException();
                const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
                var probe = Probe{
                    .json = mode == 0,
                    .exotic_hint = if (mode == 5) "default" else if (mode == 6) "number" else null,
                    .absent_exotic = mode == 7,
                    .fail_stage = @intCast(fail_stage),
                };
                const inputs = setup: {
                    var roots = core.runtime.ExactValueRoots(5){};
                    try roots.activate(rt);
                    defer roots.deactivate();
                    const receiver = try roots.ref(0);
                    const first = try roots.ref(1);
                    const second = try roots.ref(2);
                    const getter = try roots.ref(3);
                    const hint = try roots.ref(4);
                    try receiver.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                    try first.set(rt, try probe.function(ctx, 2));
                    try second.set(rt, try probe.function(ctx, 3));
                    try getter.set(rt, try probe.function(ctx, 1));
                    const hints = [_][]const u8{ "", "string", "number", "default", "default", "default", "number", "default" };
                    try hint.set(rt, (try core.string.String.createAscii(rt, hints[mode])).value());
                    const object = core.Object.fromHeader((try receiver.get(rt)).cycleMarkHeader().?);
                    probe.receiver_id = try rt.registerWeakObjectIdentity(object);
                    // Native callback state keeps identities only. Heap fields
                    // own the callable values returned by getters.
                    try object.defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(try first.get(rt), .all));
                    try object.defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.data(try second.get(rt), .all));
                    if (mode == 0) {
                        try object.defineOwnProperty(rt, core.atom.ids.valueOf, core.Descriptor.data(try first.get(rt), .all));
                        try object.defineOwnProperty(rt, core.atom.ids.toISOString, core.Descriptor.accessor(try getter.get(rt), core.JSValue.undefinedValue(), .{ .configurable = true }));
                    } else if (mode >= 5) {
                        const symbol = core.atom.predefinedId("Symbol.toPrimitive", .symbol).?;
                        try object.defineOwnProperty(rt, symbol, core.Descriptor.accessor(try getter.get(rt), core.JSValue.undefinedValue(), .{ .configurable = true }));
                        if (mode == 7) {
                            try object.defineOwnProperty(rt, core.atom.ids.valueOf, core.Descriptor.data(try first.get(rt), .all));
                            try object.defineOwnProperty(rt, core.atom.ids.toString, core.Descriptor.data(try second.get(rt), .all));
                        }
                    } else {
                        const first_key = if (mode == 2 or mode == 4) core.atom.ids.valueOf else core.atom.ids.toString;
                        const second_key = if (mode == 2 or mode == 4) core.atom.ids.toString else core.atom.ids.valueOf;
                        try object.defineOwnProperty(rt, first_key, core.Descriptor.accessor(try getter.get(rt), core.JSValue.undefinedValue(), .{ .configurable = true }));
                        try object.defineOwnProperty(rt, second_key, core.Descriptor.data(try second.get(rt), .all));
                    }
                    break :setup [_]core.JSValue{ try receiver.get(rt), try hint.get(rt) };
                };
                const result = switch (mode) {
                    0 => zjs.exec.date_ops.dateToJsonCall(ctx, null, global, inputs[0], &.{}, null, null),
                    4, 5, 7 => optionalValueResult(zjs.exec.date_ops.dateConstructWithPrototype(ctx, null, global, null, inputs[0..1])),
                    6 => optionalValueResult(zjs.exec.value_ops.toPrimitiveForNumber(ctx, null, global, inputs[0])),
                    else => optionalValueResult(zjs.exec.date_ops.dateToPrimitiveCall(ctx, null, global, inputs[0], inputs[1..], null, null)),
                };
                if (probe.stale) {
                    std.debug.print("Date callback stale receiver: mode={d} nursery={} fail_stage={d} sequence={d}\n", .{ mode, nursery, fail_stage, probe.sequence });
                    return error.DateCallbackReceiverStale;
                }
                if (probe.lost) return error.DateCallbackReceiverLost;
                if (fail_stage == 0) {
                    if (mode == 4 or mode == 5 or mode == 7) {
                        const ms = try zjs.exec.date_ops.methodCall(rt, (try result).?, .get_time);
                        try require(zjs.exec.value_ops.numberValue(ms).? == 47);
                    } else try require((try result).?.as(.int).? == 47);
                } else {
                    if (result) |_| return error.ExpectedDateCallbackFailure else |err| try require(err == error.OutOfMemory or err == error.JSException);
                }
                const expected: u16 = if (mode == 0)
                    (if (fail_stage == 2) 2 else if (fail_stage == 1) 21 else 213)
                else if (mode == 5 or mode == 6)
                    (if (fail_stage == 1) 1 else 13)
                else
                    (if (fail_stage == 1) 1 else if (fail_stage == 2) 12 else 123);
                if (probe.sequence != expected) return error.DateCallbackOrderMismatch;
                if (nursery and !probe.moved) return error.DateCallbackDidNotMove;
                try require(rt.active_value_roots == null);
            }
        }
    }
}

fn verifyUriReadWindows() !void {
    for (1..7) |mode| {
        for ([_]bool{ false, true }) |fail| {
            const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer rt.destroy();
            rt.gc.scheduler.host_quiescent = true;
            const ctx = try core.JSContext.create(rt, .{});
            defer ctx.destroy();
            const decode = mode == 3 or mode == 4 or mode == 6;
            var input: core.JSValue = undefined;
            {
                var roots = core.runtime.ExactValueRoots(2){};
                try roots.activate(rt);
                defer roots.deactivate();
                const left = try roots.ref(0);
                const right = try roots.ref(1);
                try left.set(rt, (try core.string.String.createAscii(rt, if (decode) "a%" else "a ")).value());
                try right.set(rt, (try core.string.String.createAscii(rt, if (decode) "20%2F" else "/%")).value());
                input = (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value();
            }
            // No caller root survives into the operation. Output allocation
            // must happen after the last borrowed input read, even on OOM.
            rt.gc.heap_budget.gc_threshold = 0;
            if (fail) rt.setMemoryLimit(0);
            const epoch = rt.gc.collection_epoch;
            const result = switch (mode) {
                5 => zjs.exec.uri_ops.escape(rt, input),
                6 => zjs.exec.uri_ops.unescape(rt, input),
                else => zjs.exec.uri_ops.call(ctx, null, @intCast(mode), input),
            };
            if (fail) {
                if (result) |_| return error.ExpectedUriOom else |err| try require(err == error.OutOfMemory);
            } else {
                const expected = switch (mode) {
                    1 => "a%20/%25",
                    2 => "a%20%2F%25",
                    3 => "a %2F",
                    4, 6 => "a /",
                    5 => "a%20/%25",
                    else => unreachable,
                };
                try require(core.string.asFlat(try result).?.eqlBytes(expected));
            }
            try require(rt.gc.collection_epoch > epoch);
            try require(rt.active_value_roots == null);
            if (comptime @import("builtin").mode == .Debug) try require(rt.active_no_gc_scope == null);
        }
    }
}

fn verifyEvacuationRollback() !void {
    for ([_]bool{ false, true }) |minor| {
        for ([_]core.runtime.RootTraceError{ error.OutOfMemory, error.PayloadMarkFailed }) |failure| {
            const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer rt.destroy();
            rt.gc.nursery.enabled = true;
            rt.gc.scheduler.host_quiescent = true;
            var roots = core.runtime.ExactValueRoots(2){};
            try roots.activate(rt);
            defer roots.deactivate();
            const first = try roots.ref(0);
            const second = try roots.ref(1);
            try first.set(rt, (try core.Object.createPlainObject(rt, null)).value());
            try second.set(rt, (try core.Object.createPlainObject(rt, null)).value());
            const first_object = core.Object.fromHeader((try first.get(rt)).cycleMarkHeader().?);
            const second_object = core.Object.fromHeader((try second.get(rt)).cycleMarkHeader().?);
            try first_object.defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.data(try second.get(rt), .all));
            try second_object.defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.data(try first.get(rt), .all));
            const before = [_]core.JSValue{ try first.get(rt), try second.get(rt) };
            var weak = try core.runtime.WeakPersistentValue.init(rt, before[0], null, null);
            defer weak.deinit();
            const weak_identity = weak.slot.?.identity.?;
            const Probe = struct {
                aliases: [2]core.JSValue,
                object_alias: ?*core.Object,
                before: core.JSValue,
                failure: core.runtime.RootTraceError,
                calls: usize = 0,
                saw_move: bool = false,
                fn trace(raw: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
                    const self: *@This() = @ptrCast(@alignCast(raw));
                    self.calls += 1;
                    try visitor.values(&self.aliases);
                    try visitor.optionalObject(&self.object_alias);
                    if (self.calls == 2) {
                        self.saw_move = self.aliases[0].bits != self.before.bits;
                        return self.failure;
                    }
                }
            };
            var probe = Probe{ .aliases = before, .object_alias = first_object, .before = before[0], .failure = failure };
            const provider = core.runtime.RootProvider{ .context = &probe, .trace = Probe.trace };
            try rt.registerRootProvider(provider);
            defer rt.unregisterRootProvider(provider);
            const heap_before = rt.gc.heap_budget.bytes;
            if (collectReadonlyRootFixture(rt, null, minor)) |_| return error.ExpectedTraceFailure else |err| {
                try require(err == failure);
            }
            try require(probe.saw_move and !rt.roots.isTracing() and !rt.gc_running);
            try require(rt.gc.heap_budget.bytes == heap_before);
            try require(probe.object_alias == first_object);
            try require((try first.get(rt)).bits == before[0].bits);
            try require((try second.get(rt)).bits == before[1].bits);
            try require(weak.get().bits == before[0].bits);
            try require(weak.slot.?.identity.? == weak_identity);
            try require(rt.weak_object_ids.count() == 1 and rt.weak_id_objects.count() == 1);
            try require(rt.weak_object_ids.get(@intFromPtr(first_object.gcHeader())).? == weak_identity >> 1);
            for (probe.aliases, before) |restored, previous| {
                try require(restored.bits == previous.bits);
                try require(!core.gc.headerForwarded(restored.cycleMarkHeader().?));
            }
            try require((try first_object.getProperty(core.atom.ids.value)).bits == before[1].bits);
            try require((try second_object.getProperty(core.atom.ids.value)).bits == before[0].bits);
            try rt.gc.verifyHeapAccounting(rt);
            // A failed retirement requires a major before minors resume.
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            const moved_first = try first.get(rt);
            const moved_second = try second.get(rt);
            try require(weak.get().bits == moved_first.bits);
            try require(weak.slot.?.identity.? == weak_identity);
            try require(!rt.weak_object_ids.contains(@intFromPtr(first_object.gcHeader())));
            try require(moved_first.bits != before[0].bits and moved_second.bits != before[1].bits);
            try require(probe.aliases[0].bits == moved_first.bits and probe.aliases[1].bits == moved_second.bits);
            try require(probe.object_alias == core.Object.fromHeader(moved_first.cycleMarkHeader().?));
            try require((try core.Object.fromHeader(moved_first.cycleMarkHeader().?).getProperty(core.atom.ids.value)).bits == moved_second.bits);
            try require((try core.Object.fromHeader(moved_second.cycleMarkHeader().?).getProperty(core.atom.ids.value)).bits == moved_first.bits);
        }
    }
}

fn verifyWeakEphemeronRelocation() !void {
    for ([_]bool{ false, true }) |nursery| {
        for ([_]bool{ false, true }) |minor| {
            for ([_]bool{ false, true }) |symbol_key| {
                for ([_]bool{ false, true }) |strong_value| {
                    const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
                    defer rt.destroy();
                    rt.gc.nursery.enabled = nursery;
                    rt.gc.scheduler.host_quiescent = true;
                    var roots = core.runtime.ExactValueRoots(4){};
                    try roots.activate(rt);
                    defer roots.deactivate();
                    const table_root = try roots.ref(0);
                    const key_root = try roots.ref(1);
                    const middle_root = try roots.ref(2);
                    const value_root = try roots.ref(3);
                    try table_root.set(rt, (try core.Object.create(rt, core.class.ids.weakmap, null)).value());
                    try key_root.set(rt, if (symbol_key) try rt.newSymbolValue("ephemeron-root") else (try core.Object.createPlainObject(rt, null)).value());
                    try middle_root.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                    try value_root.set(rt, (try core.Object.createPlainObject(rt, null)).value());
                    const table = core.Object.fromHeader((try table_root.get(rt)).cycleMarkHeader().?);
                    // Weak holders currently use stable storage. Only the plain
                    // objects below may move; do not hide this carrier boundary.
                    try require(!core.gc.Registry.isNurseryHeader(table.gcHeader()));
                    const middle_before = try middle_root.get(rt);
                    const value_before = try value_root.get(rt);
                    // Visit B -> C -> B before A -> B: the cycle needs another
                    // fixed-point round when C has no independent strong root.
                    // After A dies, the conditional cycle must not retain itself.
                    try zjs.exec.collection_ops.setWeakMapEntry(rt, table, middle_before, value_before);
                    try zjs.exec.collection_ops.setWeakMapEntry(rt, table, value_before, middle_before);
                    try zjs.exec.collection_ops.setWeakMapEntry(rt, table, try key_root.get(rt), middle_before);
                    var weak_middle = try core.runtime.WeakPersistentValue.init(rt, middle_before, null, null);
                    defer weak_middle.deinit();
                    const middle_identity = weak_middle.slot.?.identity.?;
                    const Callback = struct {
                        calls: usize = 0,
                        fn cleared(_: *core.JSRuntime, raw: ?*anyopaque) void {
                            const self: *@This() = @ptrCast(@alignCast(raw.?));
                            self.calls += 1;
                        }
                    };
                    var callback = Callback{};
                    var weak_value = try core.runtime.WeakPersistentValue.init(rt, value_before, Callback.cleared, &callback);
                    defer weak_value.deinit();
                    const value_identity = weak_value.slot.?.identity.?;
                    try middle_root.set(rt, core.JSValue.undefinedValue());
                    if (!strong_value) try value_root.set(rt, core.JSValue.undefinedValue());
                    try collectReadonlyRootFixture(rt, null, minor);
                    const entries = table.weakCollectionEntries();
                    try require(entries.len == 3);
                    try require((entries[0].value.bits != value_before.bits) == nursery);
                    try require((entries[1].value.bits != middle_before.bits) == nursery);
                    try require(rt.gc.containsHeader(entries[0].value.cycleMarkHeader().?));
                    try require(rt.gc.containsHeader(entries[1].value.cycleMarkHeader().?));
                    try require(weak_middle.get().bits == entries[1].value.bits);
                    try require(entries[1].value.bits == entries[2].value.bits);
                    try require(weak_value.get().bits == entries[0].value.bits);
                    try require(weak_middle.slot.?.identity.? == middle_identity);
                    try require(weak_value.slot.?.identity.? == value_identity);
                    try require(callback.calls == 0);
                    if (strong_value) try require((try value_root.get(rt)).bits == entries[0].value.bits);
                    try key_root.set(rt, core.JSValue.undefinedValue());
                    try value_root.set(rt, core.JSValue.undefinedValue());
                    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                    try require(table.weakCollectionEntries().len == 0);
                    try require(!weak_middle.isAlive() and !weak_value.isAlive());
                    try require(weak_middle.get().is(.undefined_value) and weak_value.get().is(.undefined_value));
                    try require(rt.weak_object_ids.count() == 0 and rt.weak_id_objects.count() == 0);
                    try require(callback.calls == 1);
                    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                    try require(callback.calls == 1);
                    try rt.gc.verifyHeapAccounting(rt);
                }
            }
        }
    }
}

fn verifyFunctionHomeObject() !void {
    for ([_]bool{ false, true }) |auxiliary| {
        for ([_]bool{ false, true }) |nursery| {
            const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer rt.destroy();
            rt.gc.nursery.enabled = nursery;
            rt.gc.scheduler.host_quiescent = true;
            var roots = core.runtime.ExactValueRoots(1){};
            try roots.activate(rt);
            defer roots.deactivate();
            const closure = try core.Object.create(rt, core.class.ids.bytecode_function, null);
            try (try roots.ref(0)).set(rt, closure.value());
            if (auxiliary) _ = try closure.functionSourceSlot(rt);
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            try require(!closure.gcHeader().meta().flags.young);
            var previous: ?*core.gc.Header = null;
            for (0..2) |_| {
                const home = try core.Object.createPlainObject(rt, null);
                const before = @intFromPtr(home);
                try closure.setFunctionHomeObject(rt, home);
                try closure.setFunctionHomeObject(rt, home);
                try require(rt.gc.generation.remembered.contains(@intFromPtr(closure.gcHeader())));
                _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
                const stored = closure.functionHomeObject().?;
                try require(rt.gc.containsHeader(stored.gcHeader()));
                try require(nursery == (@intFromPtr(stored) != before));
                _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                if (previous) |old| try require(!rt.gc.containsHeader(old));
                try require(closure.functionHomeObject() == stored);
                previous = stored.gcHeader();
            }
            try closure.setFunctionHomeObject(rt, null);
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            try require(closure.functionHomeObject() == null);
            try require(!rt.gc.containsHeader(previous.?));
        }
    }
}

fn verifyAccessorSlots() !void {
    for ([_]bool{ false, true }) |external| {
        for ([_]bool{ false, true }) |shared| {
            const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer rt.destroy();
            rt.gc.nursery.enabled = true;
            rt.gc.scheduler.host_quiescent = true;
            var roots = core.runtime.ExactValueRoots(3){};
            try roots.activate(rt);
            defer roots.deactivate();
            const owner = try roots.ref(0);
            const getter = try roots.ref(1);
            const setter = try roots.ref(2);
            try owner.set(rt, (try core.Object.createPlainObject(rt, null)).value());
            // Synthetic nursery objects exercise the pointer layout itself;
            // no getter/setter is invoked in this collector contract test.
            try getter.set(rt, (try core.Object.createPlainObject(rt, null)).value());
            try setter.set(rt, if (shared) try getter.get(rt) else (try core.Object.createPlainObject(rt, null)).value());
            const before_getter = (try getter.get(rt)).bits;
            const before_setter = (try setter.get(rt)).bits;
            var object = core.Object.fromHeader((try owner.get(rt)).cycleMarkHeader().?);
            if (external) {
                try object.defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(core.JSValue.int32(1), .all));
                try object.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(2), .all));
            }
            try object.defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.accessor(try getter.get(rt), try setter.get(rt), .{ .configurable = true }));
            try getter.set(rt, core.JSValue.undefinedValue());
            try setter.set(rt, core.JSValue.undefinedValue());
            _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
            object = core.Object.fromHeader((try owner.get(rt)).cycleMarkHeader().?);
            const index: usize = if (external) 2 else 0;
            const accessor = object.asAccessorAt(index).?;
            const moved_getter = accessor.getterValue();
            const moved_setter = accessor.setterValue();
            try require(moved_getter.bits != before_getter and moved_setter.bits != before_setter);
            try require((moved_getter.bits == moved_setter.bits) == shared);
            try require(rt.gc.containsHeader(moved_getter.cycleMarkHeader().?));
            try require(rt.gc.containsHeader(moved_setter.cycleMarkHeader().?));
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            try require(object.asAccessorAt(index).?.getterValue().bits == moved_getter.bits);
            try object.defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.data(core.JSValue.undefinedValue(), .all));
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            try require(!rt.gc.containsHeader(moved_getter.cycleMarkHeader().?));
            try require(!rt.gc.containsHeader(moved_setter.cycleMarkHeader().?));
        }
    }
}

fn verifyCellRootCarriers() !void {
    for ([_]bool{ false, true }) |borrowed| {
        for ([_]bool{ false, true }) |minor| {
            const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer rt.destroy();
            rt.gc.nursery.enabled = true;
            rt.gc.scheduler.host_quiescent = true;
            const cell = try core.VarRef.createClosed(rt, core.JSValue.undefinedValue());
            var cells = [_]*core.VarRef{cell};
            const live: []*core.VarRef = &cells;
            const slices = [_]core.runtime.ValueRootSlice{if (borrowed) .{ .borrowed_cells = &cells } else .{ .cells = &live }};
            var frame = core.runtime.ValueRootFrame{ .slices = &slices };
            frame.activate(rt);
            defer frame.deactivate(rt);
            const object = try core.Object.createPlainObject(rt, null);
            const before = object.value().bits;
            cell.setVarRefValue(rt, object.value());
            try require(core.gc.Registry.isNurseryHeader(object.gcHeader()));
            try collectReadonlyRootFixture(rt, null, minor);
            try require(cells[0] == cell and rt.gc.containsHeader(&cell.header));
            const moved = cell.varRefValue();
            try require(moved.bits != before);
            try require(rt.gc.containsHeader(moved.cycleMarkHeader().?));
            try collectReadonlyRootFixture(rt, null, false);
            try require(cell.varRefValue().bits == moved.bits);
            // Keeping the carrier rooted must not retain an overwritten child.
            cell.setVarRefValue(rt, core.JSValue.undefinedValue());
            try collectReadonlyRootFixture(rt, null, false);
            try require(rt.gc.containsHeader(&cell.header));
            try require(!rt.gc.containsHeader(moved.cycleMarkHeader().?));
        }
    }
}

fn collectReadonlyRootFixture(rt: *core.JSRuntime, roots: ?*const core.runtime.ValueRootFrame, minor: bool) core.runtime.RootTraceError!void {
    if (minor) {
        _ = try core.gc_trace_stw.collectMinor(rt, roots, .declared_only);
    } else {
        _ = try rt.tryRunObjectCycleRemovalWithValueRoots(roots, .declared_only);
    }
}

fn verifyReadonlyNurseryRoots() !void {
    const Kind = enum { borrowed, object_provider, extra_header };
    for ([_]bool{ false, true }) |minor| {
        for ([_]Kind{ .borrowed, .object_provider, .extra_header }) |kind| {
            const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer rt.destroy();
            rt.gc.nursery.enabled = true;
            rt.gc.scheduler.host_quiescent = true;
            const object = try core.Object.createPlainObject(rt, null);
            const borrowed = [_]core.JSValue{object.value()};
            const slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &borrowed }};
            var frame = core.runtime.ValueRootFrame{ .slices = if (kind == .borrowed) &slices else &.{} };
            frame.activate(rt);
            defer frame.deactivate(rt);
            const Provider = struct {
                object: *core.Object,
                fail: bool = false,
                fn trace(raw: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
                    const self: *@This() = @ptrCast(@alignCast(raw));
                    try visitor.constOptionalObject(self.object);
                    if (self.fail) return error.OutOfMemory;
                }
            };
            var provider_state = Provider{ .object = object, .fail = kind == .object_provider };
            const provider = core.runtime.RootProvider{ .context = &provider_state, .trace = Provider.trace };
            if (kind == .object_provider) try rt.registerRootProvider(provider);
            defer if (kind == .object_provider) rt.unregisterRootProvider(provider);
            const headers = [_]core.runtime.HeaderRootValue{.{ .header = object.gcHeader() }};
            const extra = core.runtime.ValueRootFrame{ .headers = &headers };
            const extra_roots: ?*const core.runtime.ValueRootFrame = if (kind == .extra_header) &extra else null;
            var roots = core.runtime.ExactValueRoots(1){};
            try roots.activate(rt);
            defer roots.deactivate();
            const writable = try roots.ref(0);
            try writable.set(rt, borrowed[0]);
            try require(core.gc.Registry.isNurseryHeader(object.gcHeader()));
            if (provider_state.fail) {
                const result = collectReadonlyRootFixture(rt, extra_roots, minor);
                if (result) |_| return error.ExpectedTraceFailure else |err| {
                    if (err != error.OutOfMemory) return err;
                }
                try require(!rt.gc_running and !rt.roots.isTracing());
                try require(!core.gc.headerForwarded(object.gcHeader()));
                try require((try writable.get(rt)).bits == borrowed[0].bits);
                provider_state.fail = false;
            }
            try collectReadonlyRootFixture(rt, extra_roots, minor);
            try require((try writable.get(rt)).bits == borrowed[0].bits);
            try require(rt.gc.containsHeader(object.gcHeader()));
            try require(!core.gc.headerForwarded(object.gcHeader()));
            // Retention also has to survive a later full collection.
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(extra_roots, .declared_only);
            try require((try writable.get(rt)).bits == borrowed[0].bits);
            try require(rt.gc.containsHeader(object.gcHeader()));
        }
    }
}

fn verifyRegExpLegacyStaticsRoots(rt: *core.JSRuntime) !void {
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const nursery_enabled = rt.gc.nursery.enabled;
    defer rt.gc.nursery.enabled = nursery_enabled;
    const threshold = rt.gc.heap_budget.gc_threshold;
    defer rt.gc.heap_budget.gc_threshold = threshold;
    const long_len = 1 << 20;
    const bytes = try rt.nativeAllocator().alloc(u8, long_len + 8);
    defer rt.nativeAllocator().free(bytes);
    @memset(bytes, 'x');
    @memcpy(bytes[0..2], "LL");
    @memcpy(bytes[long_len + 2 ..], "abCDRR");
    const unset = std.math.maxInt(usize);
    const captures = [_]usize{ 2, long_len + 2, long_len + 2, long_len + 4 } ++ [_]usize{unset} ** 14 ++ [_]usize{ long_len + 4, long_len + 6, unset, unset };
    const found = zjs.exec.string_ops.RegExpMatch{ .index = 2, .len = long_len + 4, .capture_slots = &captures, .capture_count = 11 };
    for ([_]bool{ false, true }) |nursery| {
        rt.gc.nursery.enabled = nursery;
        _ = try ctx.eval("/(old)/.exec('old');", .{});
        const global = try ctx.core.globalObject();
        const legacy = global.installedRealmRegExpLegacyStatics(rt).?;
        const old_input = legacy.input.?;
        const source = (try core.string.String.createLatin1(rt, bytes)).value();
        // No caller root protects this large source during failure or retry.
        const before = rt.active_value_roots;
        const epoch = rt.gc.collection_epoch;
        rt.gc.scheduler.host_quiescent = true;
        rt.setMemoryLimit(0);
        defer rt.setMemoryLimit(null);
        if (zjs.exec.string_ops.updateRegExpLegacyStaticsForMatch(rt, global, source, &found, bytes.len)) |_| return error.ExpectedLegacyStaticsOom else |err| {
            if (err != error.OutOfMemory) return err;
        }
        try require(rt.gc.collection_epoch > epoch);
        try require(rt.gc.containsHeader(source.cycleMarkHeader().?));
        try require(legacy.lazy_no_capture_match and legacy.input.?.same(old_input));
        try require(rt.active_value_roots == before);
        rt.setMemoryLimit(null);
        rt.gc.heap_budget.gc_threshold = 0;
        const retry_epoch = rt.gc.collection_epoch;
        try zjs.exec.string_ops.updateRegExpLegacyStaticsForMatch(rt, global, source, &found, bytes.len);
        try require(rt.gc.collection_epoch > retry_epoch);
        try require(rt.active_value_roots == before);
        _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
        try require(!legacy.lazy_no_capture_match);
        try require(core.string.stringValueLenUnchecked(legacy.last_match.?) == long_len + 4);
        try require(core.string.stringValueLenUnchecked(legacy.captures[0].?) == long_len);
        try require(core.string.asFlat(legacy.captures[1].?).?.eqlBytes("ab"));
        try require(legacy.capture_slot_count == 9);
        for (legacy.captures[2..]) |capture| try require(capture == null);
        try require(core.string.asFlat(legacy.last_paren.?).?.eqlBytes("CD"));
        try require(core.string.asFlat(legacy.left_context.?).?.eqlBytes("LL"));
        try require(core.string.asFlat(legacy.right_context.?).?.eqlBytes("RR"));
    }
}

fn verifyRegExpCaptureResultRoots(rt: *core.JSRuntime) !void {
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    _ = try ctx.eval("0;", .{});
    const nursery_enabled = rt.gc.nursery.enabled;
    defer rt.gc.nursery.enabled = nursery_enabled;
    const threshold = rt.gc.heap_budget.gc_threshold;
    defer rt.gc.heap_budget.gc_threshold = threshold;
    var compiled = try zjs.exec.regexp_ops.compileWithRuntime(rt, "(?<letter>a)(\xc4\x80)", "d");
    defer compiled.deinit(rt.nativeAllocator());
    const captures = [_]usize{ 2, 3, 3, 4 };
    const found = zjs.exec.string_ops.RegExpMatch{ .index = 2, .len = 2, .capture_slots = &captures, .capture_bytecode = compiled.bytecode, .capture_count = 2, .has_named_captures = true };
    for ([_]bool{ false, true }) |nursery| {
        rt.gc.nursery.enabled = nursery;
        const inputs = inputs: {
            var setup = core.runtime.ExactValueRoots(2){};
            try setup.activate(rt);
            defer setup.deactivate();
            const source = try setup.ref(0);
            const groups = try setup.ref(1);
            try source.set(rt, (try core.string.String.createUtf16(rt, &.{ 'x', 'x', 'a', 0x100, 'y', 'y' })).value());
            try groups.set(rt, (try core.Object.createPlainObject(rt, null)).value());
            break :inputs [_]core.JSValue{ try source.get(rt), try groups.get(rt) };
        };
        const old_groups = inputs[1].cycleMarkHeader().?;
        if (nursery) try require(core.gc.Registry.isNurseryHeader(old_groups));
        rt.gc.scheduler.host_quiescent = true;
        rt.gc.heap_budget.gc_threshold = 0;
        const epoch = rt.gc.collection_epoch;
        const before = rt.active_value_roots;
        const array = try core.Object.createRegExpMatchArrayFromShape(rt, ctx.core.regexp_result_shape.?, 2, inputs[0], inputs[1]);
        try require(rt.gc.collection_epoch > epoch);
        try require(rt.active_value_roots == before);
        const stored_groups = try array.getProperty(comptime core.atom.predefinedId("groups", .string).?);
        if (nursery) try require(stored_groups.cycleMarkHeader().? != old_groups);
        try require((try array.getProperty(core.atom.ids.input)).same(inputs[0]));
        var retained = core.runtime.ExactValueRoots(1){};
        try retained.activate(rt);
        defer retained.deactivate();
        const result = try retained.ref(0);
        try result.set(rt, array.value());
        _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);

        // The incoming string has no caller root during full construction.
        const input = (try core.string.String.createUtf16(rt, &.{ 'x', 'x', 'a', 0x100, 'y', 'y' })).value();
        const global = try ctx.core.globalObject();
        rt.gc.heap_budget.gc_threshold = 0;
        const build_epoch = rt.gc.collection_epoch;
        const pins = rt.gc.pins.count();
        try result.set(rt, try zjs.exec.string_ops.createRegExpMatchArrayFromValue(rt, global, input, &found, 6, true));
        try require(rt.gc.collection_epoch > build_epoch);
        try require(rt.gc.pins.count() == pins);
        _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
        const letter = try rt.internAtom("letter");
        const output = core.value_semantics.objectFromValue(try result.get(rt)).?;
        try require(output.arrayLength() == 3);
        try require(core.string.stringValueCodeUnitAtUnchecked(try output.getProperty(core.Atom.taggedInt(0)), 1) == 0x100);
        const groups = core.value_semantics.objectFromValue(try output.getProperty(comptime core.atom.predefinedId("groups", .string).?)).?;
        try require(core.string.asFlat(try groups.getProperty(letter)).?.eqlBytes("a"));
        const indices = core.value_semantics.objectFromValue(try output.getProperty(comptime core.atom.predefinedId("indices", .string).?)).?;
        const pair = core.value_semantics.objectFromValue(try indices.getProperty(core.Atom.taggedInt(0))).?;
        try require((try pair.getProperty(core.Atom.taggedInt(0))).as(.int).? == 2);
        try require((try pair.getProperty(core.Atom.taggedInt(1))).as(.int).? == 4);
    }
}

fn verifyRegExpExecutionRoots(rt: *core.JSRuntime) !void {
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const nursery_enabled = rt.gc.nursery.enabled;
    defer rt.gc.nursery.enabled = nursery_enabled;
    const threshold = rt.gc.heap_budget.gc_threshold;
    defer rt.gc.heap_budget.gc_threshold = threshold;
    for ([_]bool{ false, true }) |nursery| {
        rt.gc.nursery.enabled = nursery;
        for (0..3) |mode| {
            const inputs = inputs: {
                var roots = core.runtime.ExactValueRoots(3){};
                try roots.activate(rt);
                defer roots.deactivate();
                const receiver = try roots.ref(0);
                const source = try roots.ref(1);
                const right = try roots.ref(2);
                try receiver.set(rt, try ctx.eval(switch (mode) {
                    0 => "/a/",
                    1 => "/(?<letter>a)(\\u0100)/dg",
                    else => "/z/g",
                }, .{}));
                try source.set(rt, (try core.string.String.createAscii(rt, "a")).value());
                try right.set(rt, (try core.string.String.createUtf16(rt, &.{0x100})).value());
                try source.set(rt, (try core.string.String.createRope(rt, try source.get(rt), try right.get(rt))).value());
                break :inputs [_]core.JSValue{ try receiver.get(rt), try source.get(rt) };
            };
            const global = try ctx.core.globalObject();
            const before = rt.active_value_roots;
            const epoch = rt.gc.collection_epoch;
            rt.gc.scheduler.host_quiescent = true;
            rt.setMemoryLimit(0);
            defer rt.setMemoryLimit(null);
            if (mode == 0) {
                if (zjs.exec.regexp_ops.regExpTestFastNoResult(ctx.core, core.value_semantics.objectFromValue(inputs[0]).?, inputs[1])) |_| return error.ExpectedRegExpInputOom else |err| {
                    if (err != error.OutOfMemory) return err;
                }
            } else {
                if (zjs.exec.regexp_ops.regExpExecResult(ctx.core, null, global, inputs[0], core.value_semantics.objectFromValue(inputs[0]).?, inputs[1], true, null, null)) |_| return error.ExpectedRegExpInputOom else |err| {
                    if (err != error.OutOfMemory) return err;
                }
            }
            try require(rt.gc.collection_epoch > epoch);
            try require(rt.gc.containsHeader(inputs[0].cycleMarkHeader().?));
            try require(rt.gc.containsHeader(inputs[1].cycleMarkHeader().?));
            try require(!inputs[1].ropeBody().?.isLinearized());
            try require(rt.active_value_roots == before);

            rt.setMemoryLimit(null);
            rt.gc.heap_budget.gc_threshold = 0;
            const retry_epoch = rt.gc.collection_epoch;
            const result = if (mode == 0)
                (try zjs.exec.regexp_ops.regExpTestMethod(ctx.core, null, global, inputs[0], &.{inputs[1]}, null, null)).?
            else
                try zjs.exec.regexp_ops.regExpExecMethod(ctx.core, null, global, inputs[0], &.{inputs[1]}, null, null);
            try require(rt.gc.collection_epoch > retry_epoch);
            try require(rt.active_value_roots == before);
            if (mode == 0) {
                try require(result.as(.boolean).?);
            } else if (mode == 2) {
                try require(result.is(.null_value));
            } else {
                var roots = core.runtime.ExactValueRoots(1){};
                try roots.activate(rt);
                defer roots.deactivate();
                const kept = try roots.ref(0);
                try kept.set(rt, result);
                _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                const letter = try rt.internAtom("letter");
                const array = core.value_semantics.objectFromValue(try kept.get(rt)).?;
                try require(array.arrayLength() == 3);
                try require(core.string.stringValueCodeUnitAtUnchecked(try array.getProperty(core.Atom.taggedInt(0)), 1) == 0x100);
                const groups = core.value_semantics.objectFromValue(try array.getProperty(comptime core.atom.predefinedId("groups", .string).?)).?;
                try require(core.string.asFlat(try groups.getProperty(letter)).?.eqlBytes("a"));
                const indices = core.value_semantics.objectFromValue(try array.getProperty(comptime core.atom.predefinedId("indices", .string).?)).?;
                const pair = core.value_semantics.objectFromValue(try indices.getProperty(core.Atom.taggedInt(0))).?;
                try require((try pair.getProperty(core.Atom.taggedInt(0))).as(.int).? == 0);
                try require((try pair.getProperty(core.Atom.taggedInt(1))).as(.int).? == 2);
            }
        }
    }
}

fn verifyRegExpProgramCommit() !void {
    const flat_charge = measured: {
        const calibration = try core.JSRuntime.create(std.heap.page_allocator, .{});
        defer calibration.destroy();
        const before = calibration.gc.heap_budget.bytes;
        _ = try core.string.String.createUtf16(calibration, &.{ 'a', 0x100 });
        break :measured calibration.gc.heap_budget.bytes - before;
    };
    for ([_]bool{ false, true }) |nursery| {
        for (0..2) |failure_stage| {
            // Isolate the admission budget from unrelated fixture objects.
            const rt = try core.JSRuntime.create(std.heap.page_allocator, .{});
            defer rt.destroy();
            rt.gc.nursery.enabled = nursery;
            rt.gc.scheduler.host_quiescent = true;
            var old = try zjs.exec.regexp_ops.compileWithRuntime(rt, "old", "");
            defer old.deinit(rt.nativeAllocator());
            var compiled = try zjs.exec.regexp_ops.compileWithRuntime(rt, "a\xc4\x80", "g");
            defer compiled.deinit(rt.nativeAllocator());
            var base: usize = undefined;
            const inputs = inputs: {
                var roots = core.runtime.ExactValueRoots(3){};
                try roots.activate(rt);
                defer roots.deactivate();
                const owner = try roots.ref(0);
                const source = try roots.ref(1);
                const right = try roots.ref(2);
                try owner.set(rt, (try core.Object.create(rt, core.class.ids.regexp, null)).value());
                try source.set(rt, (try core.string.String.createAscii(rt, "old")).value());
                try core.value_semantics.objectFromValue(try owner.get(rt)).?.setRegexpProgram(rt, try source.get(rt), old.bytecode);
                try source.set(rt, (try core.string.String.createAscii(rt, "a")).value());
                try right.set(rt, (try core.string.String.createUtf16(rt, &.{0x100})).value());
                try source.set(rt, (try core.string.String.createRope(rt, try source.get(rt), try right.get(rt))).value());
                _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
                base = rt.gc.heap_budget.bytes;
                break :inputs [_]core.JSValue{ try owner.get(rt), try source.get(rt) };
            };
            // No caller root may hide a missing root in the program setter.
            const before = rt.active_value_roots;
            const epoch = rt.gc.collection_epoch;
            rt.setMemoryLimit(if (failure_stage == 0) 0 else base + flat_charge);
            defer rt.setMemoryLimit(null);
            if (core.value_semantics.objectFromValue(inputs[0]).?.setRegexpProgram(rt, inputs[1], compiled.bytecode)) |_| return error.ExpectedRegExpProgramOom else |err| {
                if (err != error.OutOfMemory) return err;
            }
            try require(rt.gc.collection_epoch > epoch);
            try require(rt.active_value_roots == before);
            if (comptime @import("builtin").mode == .Debug) try require(rt.active_no_gc_scope == null);
            try require(rt.gc.containsHeader(inputs[0].cycleMarkHeader().?));
            try require(rt.gc.containsHeader(inputs[1].cycleMarkHeader().?));
            const object = core.value_semantics.objectFromValue(inputs[0]).?;
            try require(core.string.asFlat(object.regexpSource().?).?.eqlBytes("old"));
            try require(std.mem.eql(u8, old.bytecode, object.regexpCompiledBytecode()));
            try require(inputs[1].ropeBody().?.isLinearized() == (failure_stage == 1));

            rt.setMemoryLimit(null);
            rt.gc.heap_budget.gc_threshold = 0;
            const retry_epoch = rt.gc.collection_epoch;
            try object.setRegexpProgram(rt, inputs[1], compiled.bytecode);
            try require(rt.gc.collection_epoch > retry_epoch);
            try require(rt.active_value_roots == before);
            var retained = core.runtime.ExactValueRoots(1){};
            try retained.activate(rt);
            defer retained.deactivate();
            const owner = try retained.ref(0);
            try owner.set(rt, inputs[0]);
            _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
            const published = core.value_semantics.objectFromValue(try owner.get(rt)).?;
            try require(core.string.stringValueLenUnchecked(published.regexpSource().?) == 2);
            try require(core.string.stringValueCodeUnitAtUnchecked(published.regexpSource().?, 1) == 0x100);
            try require(std.mem.eql(u8, compiled.bytecode, published.regexpCompiledBytecode()));
        }
    }
}

fn verifyRegExpCompileRoots(rt: *core.JSRuntime) !void {
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const nursery_enabled = rt.gc.nursery.enabled;
    defer rt.gc.nursery.enabled = nursery_enabled;
    const threshold = rt.gc.heap_budget.gc_threshold;
    defer rt.gc.heap_budget.gc_threshold = threshold;
    for ([_]bool{ false, true }) |nursery| {
        rt.gc.nursery.enabled = nursery;
        var values: [3]core.JSValue = undefined;
        {
            var setup = core.runtime.ExactValueRoots(3){};
            try setup.activate(rt);
            defer setup.deactivate();
            const receiver = try setup.ref(0);
            const source = try setup.ref(1);
            const flags = try setup.ref(2);
            try receiver.set(rt, try ctx.eval("/old/", .{}));
            try source.set(rt, (try core.string.String.createUtf16(rt, &.{ 'a', 0x100 })).value());
            try flags.set(rt, try ctx.eval("({ toString() { const allocation = { x: 1 }; return 'g'; } })", .{}));
            values = .{ try receiver.get(rt), try source.get(rt), try flags.get(rt) };
        }
        // No caller roots protect the receiver, source or flags during the call.
        const global = try ctx.core.globalObject();
        const before = rt.active_value_roots;
        const epoch = rt.gc.collection_epoch;
        rt.gc.scheduler.host_quiescent = true;
        rt.gc.heap_budget.gc_threshold = 0;
        const result = (try zjs.exec.regexp_ops.regExpCompile(ctx.core, null, global, values[0], &.{ values[1], values[2] }, null, null)).?;
        try require(rt.gc.collection_epoch > epoch);
        try require(rt.active_value_roots == before);
        const object = core.value_semantics.objectFromValue(result).?;
        const source = object.regexpSource().?;
        try require(core.string.stringValueLenUnchecked(source) == 2);
        try require(core.string.stringValueCodeUnitAtUnchecked(source, 1) == 0x100);
        try require(object.regexpCompiledBytecode().len > 0);
        try require(object.regexpLastIndex().?.as(.int).? == 0);
    }
}

fn verifyRegExpSourcePublication(rt: *core.JSRuntime) !void {
    const nursery_enabled = rt.gc.nursery.enabled;
    defer rt.gc.nursery.enabled = nursery_enabled;
    for ([_]bool{ false, true }) |nursery| {
        rt.gc.nursery.enabled = nursery;
        var roots = core.runtime.ExactValueRoots(4){};
        try roots.activate(rt);
        defer roots.deactivate();
        const owner = try roots.ref(0);
        const left = try roots.ref(1);
        const right = try roots.ref(2);
        const source = try roots.ref(3);
        try owner.set(rt, (try core.Object.create(rt, core.class.ids.regexp, null)).value());
        try left.set(rt, (try core.string.String.createAscii(rt, "old")).value());
        try core.value_semantics.objectFromValue(try owner.get(rt)).?.setRegexpSource(rt, try left.get(rt));
        try left.set(rt, (try core.string.String.createAscii(rt, "new-")).value());
        try right.set(rt, (try core.string.String.createUtf16(rt, &.{0x100})).value());
        try source.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value());
        const before = rt.active_value_roots;
        rt.setMemoryLimit(0);
        defer rt.setMemoryLimit(null);
        if (core.value_semantics.objectFromValue(try owner.get(rt)).?.setRegexpSource(rt, try source.get(rt))) |_| return error.ExpectedRegExpSourceOom else |err| {
            if (err != error.OutOfMemory) return err;
        }
        try require(core.string.asFlat(core.value_semantics.objectFromValue(try owner.get(rt)).?.regexpSource().?).?.eqlBytes("old"));
        try require(!(try source.get(rt)).ropeBody().?.isLinearized());
        rt.setMemoryLimit(null);
        const threshold = rt.gc.heap_budget.gc_threshold;
        defer rt.gc.heap_budget.gc_threshold = threshold;
        rt.gc.heap_budget.gc_threshold = 0;
        const epoch = rt.gc.collection_epoch;
        try core.value_semantics.objectFromValue(try owner.get(rt)).?.setRegexpSource(rt, try source.get(rt));
        const stored = core.value_semantics.objectFromValue(try owner.get(rt)).?.regexpSource().?;
        try require(core.string.asFlat(stored) != null);
        try require(core.string.stringValueLenUnchecked(stored) == 5);
        try require(core.string.stringValueCodeUnitAtUnchecked(stored, 4) == 0x100);
        try require(rt.gc.collection_epoch > epoch);
        try require(rt.active_value_roots == before);
        if (nursery) {
            // Exercise success on a fresh receiver as well. RegExp uses the
            // runtime-sized old-generation allocation path even when nursery
            // allocation is enabled; this is not an evacuation test.
            try source.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value());
            try owner.set(rt, (try core.Object.create(rt, core.class.ids.regexp, null)).value());
            const fresh = (try owner.get(rt)).cycleMarkHeader().?;
            try require(!core.gc.Registry.isNurseryHeader(fresh));
            rt.gc.heap_budget.gc_threshold = 0;
            const generation = rt.gc.collection_epoch;
            try core.value_semantics.objectFromValue(try owner.get(rt)).?.setRegexpSource(rt, try source.get(rt));
            try require(rt.gc.collection_epoch > generation);
            const published = core.value_semantics.objectFromValue(try owner.get(rt)).?.regexpSource().?;
            try require(core.string.stringValueCodeUnitAtUnchecked(published, 4) == 0x100);
        }
    }
    const inputs = input: {
        var roots = core.runtime.ExactValueRoots(3){};
        try roots.activate(rt);
        defer roots.deactivate();
        const source = try roots.ref(0);
        const right = try roots.ref(1);
        const flags = try roots.ref(2);
        try source.set(rt, (try core.string.String.createAscii(rt, "a")).value());
        try right.set(rt, (try core.string.String.createAscii(rt, "b")).value());
        try source.set(rt, (try core.string.String.createRope(rt, try source.get(rt), try right.get(rt))).value());
        try flags.set(rt, (try core.string.String.createAscii(rt, "g")).value());
        break :input [_]core.JSValue{ try source.get(rt), try flags.get(rt) };
    };
    const threshold = rt.gc.heap_budget.gc_threshold;
    defer rt.gc.heap_budget.gc_threshold = threshold;
    rt.gc.heap_budget.gc_threshold = 0;
    const before = rt.active_value_roots;
    const created = try zjs.exec.regexp_ops.constructWithPrototype(rt, inputs[0], inputs[1], null);
    try require(rt.active_value_roots == before);
    rt.gc.heap_budget.gc_threshold = 0;
    // Neither the source regexp nor its borrowed bytecode has a caller root
    // while cloning allocates a new object and copies the compiled payload.
    const clone = try zjs.exec.regexp_ops.constructWithPrototype(rt, created, core.JSValue.undefinedValue(), null);
    try require(rt.active_value_roots == before);
    var roots = core.runtime.ExactValueRoots(1){};
    try roots.activate(rt);
    defer roots.deactivate();
    const output = try roots.ref(0);
    try output.set(rt, clone);
    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
    const object = core.value_semantics.objectFromValue(try output.get(rt)).?;
    try require(core.string.asFlat(object.regexpSource().?).?.eqlBytes("ab"));
    try require(object.regexpCompiledBytecode().len != 0);
    try require(zjs.exec.regexp_ops.flagsFromBytecode(object.regexpCompiledBytecode()).global);
    try require(object.regexpLastIndex().?.as(.int).? == 0);
}

fn verifyRegExpEscapeBorrow(rt: *core.JSRuntime) !void {
    for (0..3) |mode| {
        const input = input: {
            if (mode == 0) break :input (try core.string.String.createAscii(rt, "a+b")).value();
            var roots = core.runtime.ExactValueRoots(2){};
            try roots.activate(rt);
            defer roots.deactivate();
            const left = try roots.ref(0);
            const right = try roots.ref(1);
            if (mode == 1) {
                try left.set(rt, (try core.string.String.createAscii(rt, "a")).value());
                try right.set(rt, (try core.string.String.createAscii(rt, "-b")).value());
            } else {
                try left.set(rt, (try core.string.String.createUtf16(rt, &.{ 'a', '.', 0xd83d })).value());
                try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 0xde00, 0xd800, '-', ' ' })).value());
            }
            break :input (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value();
        };
        const threshold = rt.gc.heap_budget.gc_threshold;
        defer rt.gc.heap_budget.gc_threshold = threshold;
        rt.gc.heap_budget.gc_threshold = 0;
        const epoch = rt.gc.collection_epoch;
        const before = rt.active_value_roots;
        // No caller root: all source reads must finish before result allocation.
        const result = try zjs.exec.regexp_ops.escape(rt, &.{input});
        try require(rt.gc.collection_epoch > epoch);
        try require(rt.active_value_roots == before);
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.nativeAllocator());
        try zjs.exec.string_ops.appendSourceStringUtf8(rt, &bytes, result);
        const expected = [_][]const u8{ "\\x61\\+b", "\\x61\\x2db", "\\x61\\.\xf0\x9f\x98\x80\\ud800\\x2d\\x20" };
        try require(std.mem.eql(u8, bytes.items, expected[mode]));
    }
}

fn verifyExceptionNameReads(rt: *core.JSRuntime) !void {
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    defer ctx.clearException();
    const names = [_][]const u8{ "TypeError", "InternalError", "RangeError" };
    const errors = [_]anyerror{ error.TypeError, error.OutOfMemory, error.RangeError };
    for (names, errors) |name, err| {
        for ([_]bool{ false, true }) |inherited| {
            var roots = core.runtime.ExactValueRoots(4){};
            try roots.activate(rt);
            defer roots.deactivate();
            const left = try roots.ref(0);
            const right = try roots.ref(1);
            const source = try roots.ref(2);
            const owner = try roots.ref(3);
            try left.set(rt, (try core.string.String.createAscii(rt, name[0..4])).value());
            var wide: [16]u16 = undefined;
            for (name[4..], 0..) |byte, index| wide[index] = byte;
            try right.set(rt, (try core.string.String.createUtf16(rt, wide[0 .. name.len - 4])).value());
            try source.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value());
            try owner.set(rt, (try core.Object.createPlainObject(rt, null)).value());
            try core.value_semantics.objectFromValue(try owner.get(rt)).?.defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(try source.get(rt), .all));
            if (inherited) try owner.set(rt, (try core.Object.createPlainObject(rt, core.value_semantics.objectFromValue(try owner.get(rt)).?)).value());
            _ = ctx.throwValue(try owner.get(rt));
            const pending = rt.current_exception;
            const epoch = rt.gc.collection_epoch;
            const heap_bytes = rt.gc.heap_budget.bytes;
            const native_bytes = rt.diagnostics.allocations.allocated_bytes;
            rt.setMemoryLimit(0);
            defer rt.setMemoryLimit(null);
            try require(zjs.exec.exception_ops.pendingExceptionMatchesError(ctx, err));
            try require(!zjs.exec.exception_ops.pendingExceptionMatchesError(ctx, error.SyntaxError));
            try require(zjs.exec.exception_ops.pendingExceptionMatchesError(ctx, error.JSException));
            try require(rt.current_exception.same(pending));
            try require(rt.gc.collection_epoch == epoch);
            try require(rt.gc.heap_budget.bytes == heap_bytes);
            try require(rt.diagnostics.allocations.allocated_bytes == native_bytes);
            try require(!(try source.get(rt)).ropeBody().?.isLinearized());
        }
    }
}

fn verifyPropertyKeyRoots(rt: *core.JSRuntime) !void {
    const nursery_enabled = rt.gc.nursery.enabled;
    rt.gc.nursery.enabled = false;
    defer rt.gc.nursery.enabled = nursery_enabled;
    const inputs = input: {
        var roots = core.runtime.ExactValueRoots(2){};
        try roots.activate(rt);
        defer roots.deactivate();
        const left = try roots.ref(0);
        const right = try roots.ref(1);
        try left.set(rt, (try core.string.String.createAscii(rt, "cold-")).value());
        try right.set(rt, (try core.string.String.createAscii(rt, "key")).value());
        try left.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value());
        const target = try core.Object.createPlainObject(rt, null);
        break :input [_]core.JSValue{ target.value(), try left.get(rt) };
    };
    const target_header = inputs[0].cycleMarkHeader().?;
    const source_header = inputs[1].cycleMarkHeader().?;
    const before = rt.active_value_roots;
    const epoch = rt.gc.collection_epoch;
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try require(zjs.exec.property_ops.propertyKeyAtomIfReady(inputs[1]) == null);
    try require(rt.gc.collection_epoch == epoch);
    if (zjs.exec.property_ops.propertyIn(rt, inputs[0], inputs[1])) |_| return error.ExpectedPropertyKeyOom else |err| {
        if (err != error.OutOfMemory) return err;
    }
    try require(rt.gc.collection_epoch > epoch);
    try require(rt.gc.containsHeader(target_header));
    try require(rt.gc.containsHeader(source_header));
    try require(!inputs[1].ropeBody().?.isLinearized());
    try require(rt.active_value_roots == before);
    rt.setMemoryLimit(null);
    try require(!(try zjs.exec.property_ops.propertyIn(rt, inputs[0], inputs[1])).as(.boolean).?);
    const key = zjs.exec.property_ops.propertyKeyAtomIfReady(inputs[1]) orelse return error.ExpectedCachedPropertyKey;
    try require(std.mem.eql(u8, rt.atoms.name(key).?, "cold-key"));
    try require(rt.active_value_roots == before);
}

fn verifyNativeFunctionMetadataRoots(rt: *core.JSRuntime) !void {
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    _ = try ctx.eval("0;", .{});
    const nursery_enabled = rt.gc.nursery.enabled;
    rt.gc.nursery.enabled = false;
    defer rt.gc.nursery.enabled = nursery_enabled;
    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
    const count = rt.gc.liveCountKind(.object);
    const epoch = rt.gc.collection_epoch;
    const before = rt.active_value_roots;
    // The object and its two property slots fit; the name cannot. Admission
    // retries collection while metadata construction still owns the object.
    const name = "x" ** 16384;
    rt.setMemoryLimit(rt.gc.heap_budget.bytes + 4096);
    defer rt.setMemoryLimit(null);
    if (core.function.nativeFunction(ctx.core, name, 2)) |_| return error.ExpectedNativeMetadataOom else |err| {
        if (err != error.OutOfMemory) return err;
    }
    try require(rt.gc.collection_epoch > epoch);
    try require(rt.active_value_roots == before);
    try require(rt.gc.liveCountKind(.object) == count + 1);
    rt.setMemoryLimit(null);
    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
    try require(rt.gc.liveCountKind(.object) == count);
    {
        const threshold = rt.gc.heap_budget.gc_threshold;
        defer rt.gc.heap_budget.gc_threshold = threshold;
        rt.gc.heap_budget.gc_threshold = std.math.maxInt(usize);
        // Leave enough reclaimable storage for admission to succeed on retry.
        // The retry must occur during metadata allocation, after the function
        // object exists, rather than at the initial object-allocation check.
        const garbage = (try core.string.String.createAscii(rt, "g" ** 32768)).header();
        const retries = rt.gc.heap_budget.limit_retries;
        const generation = rt.gc.collection_epoch;
        rt.setMemoryLimit(rt.gc.heap_budget.bytes + 4096);
        const created = try core.function.nativeFunction(ctx.core, name, 2);
        rt.setMemoryLimit(null);
        try require(rt.gc.heap_budget.limit_retries > retries);
        try require(rt.gc.collection_epoch > generation);
        // The successful retry may reuse the reclaimed address for the name
        // or its atom. Check the old payload as well as registry membership.
        if (rt.gc.containsHeader(garbage)) {
            try require(garbage.metaConst().flags.kind != .string or core.string.String.fromHeader(garbage).len() != 32768);
        }
        var roots = core.runtime.ExactValueRoots(1){};
        try roots.activate(rt);
        defer roots.deactivate();
        const function = try roots.ref(0);
        try function.set(rt, created);
        _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
        const object = core.value_semantics.objectFromValue(try function.get(rt)).?;
        try require(object.class_id == core.class.ids.c_function);
        try require(object.getPrototype() == ctx.core.cached_function_proto);
        try require((try object.getProperty(core.atom.ids.length)).as(.int).? == 2);
        try require(core.string.asFlat(try object.getProperty(core.atom.predefinedId("name", .string).?)).?.eqlBytes(name));
        try require(std.mem.eql(u8, rt.atoms.name(object.nativeDispatchName()).?, name));
        try require(object.nativeFunctionRealm().? == ctx.core);
    }
    for ([_]bool{ false, true }) |nursery| {
        rt.gc.nursery.enabled = nursery;
        var roots = core.runtime.ExactValueRoots(2){};
        try roots.activate(rt);
        defer roots.deactivate();
        const target = try roots.ref(0);
        const method = try roots.ref(1);
        try target.set(rt, (try core.Object.createPlainObject(rt, null)).value());
        const threshold = rt.gc.heap_budget.gc_threshold;
        defer rt.gc.heap_budget.gc_threshold = threshold;
        for ([_][]const u8{ "rootedNativeMethod", "\xce\xbb", "" }) |method_name| {
            // A collection recalculates the threshold; force each invocation,
            // including the cached/empty-name constructor paths.
            rt.gc.heap_budget.gc_threshold = 0;
            const generation = rt.gc.collection_epoch;
            try method.set(rt, try core.function.defineNativeMethod(ctx.core, core.value_semantics.objectFromValue(try target.get(rt)).?, method_name, 2));
            const key = try rt.internAtom(method_name);
            const object = core.value_semantics.objectFromValue(try target.get(rt)).?;
            try require((try object.getProperty(key)).same(try method.get(rt)));
            const function_object = core.value_semantics.objectFromValue(try method.get(rt)).?;
            try require(function_object.class_id == core.class.ids.c_function_data);
            try require(function_object.getPrototype() == ctx.core.cached_function_proto);
            try require((try function_object.getProperty(core.atom.ids.length)).as(.int).? == 2);
            const stored_name = try function_object.getProperty(core.atom.predefinedId("name", .string).?);
            if (std.mem.eql(u8, method_name, "\xce\xbb")) {
                try require(core.string.stringValueLenUnchecked(stored_name) == 1);
                try require(core.string.stringValueCodeUnitAtUnchecked(stored_name, 0) == 0x3bb);
            } else try require(core.string.asFlat(stored_name).?.eqlBytes(method_name));
            try require(rt.atoms.name(function_object.nativeDispatchName()) != null);
            try require(rt.gc.collection_epoch > generation);
        }
    }
}

fn verifyStringIteratorRoots(rt: *core.JSRuntime) !void {
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    _ = try ctx.eval("0;", .{});
    const nursery_enabled = rt.gc.nursery.enabled;
    defer rt.gc.nursery.enabled = nursery_enabled;
    for ([_]bool{ false, true }) |nursery| {
        rt.gc.nursery.enabled = nursery;
        const input = input: {
            var roots = core.runtime.ExactValueRoots(2){};
            try roots.activate(rt);
            defer roots.deactivate();
            const left = try roots.ref(0);
            const right = try roots.ref(1);
            try left.set(rt, (try core.string.String.createUtf16(rt, &.{ 'a', 0xd800 })).value());
            try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 0xdc00, 0x100, 0xdc01 })).value());
            break :input (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value();
        };
        const threshold = rt.gc.heap_budget.gc_threshold;
        defer rt.gc.heap_budget.gc_threshold = threshold;
        rt.gc.heap_budget.gc_threshold = 0;
        const epoch = rt.gc.collection_epoch;
        const before = rt.active_value_roots;
        // Construction must retain the input and every intermediate prototype
        // before the caller can register the completed iterator.
        const created = try zjs.exec.string_ops.stringIterator(ctx.core, input);
        try require(rt.active_value_roots == before);
        var roots = core.runtime.ExactValueRoots(1){};
        try roots.activate(rt);
        defer roots.deactivate();
        const iterator = try roots.ref(0);
        try iterator.set(rt, created);
        const object = core.value_semantics.objectFromValue(try iterator.get(rt)).?;
        const prototype = object.getPrototype().?;
        const tag = core.atom.predefinedId("Symbol.toStringTag", .symbol).?;
        try require(core.string.asFlat(try prototype.getProperty(tag)).?.eqlBytes("String Iterator"));
        try require(core.string.asFlat(try prototype.getPrototype().?.getProperty(tag)).?.eqlBytes("Iterator"));
        try require((try prototype.getProperty(core.atom.predefinedId("next", .string).?)).is(.object));
        const expected = [_][]const u16{ &.{'a'}, &.{ 0xd800, 0xdc00 }, &.{0x100}, &.{0xdc01} };
        for (expected) |units| {
            rt.gc.heap_budget.gc_threshold = 0;
            const generation = rt.gc.collection_epoch;
            const result = try zjs.exec.string_ops.stringIteratorNext(rt, try ctx.core.globalObject(), try iterator.get(rt));
            try require(rt.gc.collection_epoch > generation);
            const record = core.value_semantics.objectFromValue(result).?;
            try require(!(try record.getProperty(core.atom.ids.done)).as(.boolean).?);
            const value = try record.getProperty(core.atom.ids.value);
            try require(core.string.stringValueLenUnchecked(value) == units.len);
            for (units, 0..) |unit, index| try require(core.string.stringValueCodeUnitAtUnchecked(value, index) == unit);
        }
        for (0..2) |_| {
            rt.gc.heap_budget.gc_threshold = 0;
            const generation = rt.gc.collection_epoch;
            const result = try zjs.exec.string_ops.stringIteratorNext(rt, try ctx.core.globalObject(), try iterator.get(rt));
            try require(rt.gc.collection_epoch > generation);
            const record = core.value_semantics.objectFromValue(result).?;
            try require((try record.getProperty(core.atom.ids.done)).as(.boolean).?);
            try require((try record.getProperty(core.atom.ids.value)).is(.undefined_value));
            try require(core.value_semantics.objectFromValue(try iterator.get(rt)).?.iteratorTargetSlot().* == null);
        }
        try require(rt.gc.collection_epoch > epoch);
    }
}

fn verifyStringCaseRoots(rt: *core.JSRuntime) !void {
    for ([_]u32{ 2, 3 }) |method| {
        for (0..4) |mode| {
            const input = input: {
                var roots = core.runtime.ExactValueRoots(3){};
                try roots.activate(rt);
                defer roots.deactivate();
                const left = try roots.ref(0);
                const right = try roots.ref(1);
                const source = try roots.ref(2);
                if (mode == 0) break :input (try core.string.String.createAscii(rt, "Ab-z")).value();
                if (mode == 2) {
                    try left.set(rt, (try core.string.String.createUtf16(rt, &.{ 'A', 0x3a3 })).value());
                    try right.set(rt, (try core.string.String.createUtf16(rt, &.{ ' ', 0xdf, 0xd800 })).value());
                } else {
                    try left.set(rt, (try core.string.String.createAscii(rt, "Ab")).value());
                    try right.set(rt, (try core.string.String.createAscii(rt, "-z")).value());
                }
                try source.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value());
                if (mode == 3) try core.string.ensureFlat(rt, source.readOnly(), left);
                break :input try source.get(rt);
            };
            const threshold = rt.gc.heap_budget.gc_threshold;
            defer rt.gc.heap_budget.gc_threshold = threshold;
            rt.gc.heap_budget.gc_threshold = 0;
            const epoch = rt.gc.collection_epoch;
            const before = rt.active_value_roots;
            const header = input.cycleMarkHeader().?;
            const result = try zjs.exec.string_ops.methodCall(rt, input, method, &.{});
            const expected: []const u16 = if (mode == 2)
                (if (method == 2) &.{ 'A', 0x3a3, ' ', 'S', 'S', 0xd800 } else &.{ 'a', 0x3c2, ' ', 0xdf, 0xd800 })
            else if (method == 2) &.{ 'A', 'B', '-', 'Z' } else &.{ 'a', 'b', '-', 'z' };
            try require(core.string.stringValueLenUnchecked(result) == expected.len);
            for (expected, 0..) |unit, index| try require(core.string.stringValueCodeUnitAtUnchecked(result, index) == unit);
            if (mode != 2) {
                // Result allocation must keep the ASCII source alive even
                // without any caller root or conservative retention.
                try require(rt.gc.containsHeader(header));
                if (input.ropeBody()) |rope| try require(rope.isLinearized() == (mode == 3));
            }
            try require(rt.gc.collection_epoch > epoch);
            try require(rt.active_value_roots == before);
        }
    }
}

fn verifyStringSplitRoots(rt: *core.JSRuntime) !void {
    for (0..5) |mode| {
        const inputs = input: {
            var roots = core.runtime.ExactValueRoots(4){};
            try roots.activate(rt);
            defer roots.deactivate();
            const left = try roots.ref(0);
            const right = try roots.ref(1);
            const source = try roots.ref(2);
            const separator = try roots.ref(3);
            try left.set(rt, (try core.string.String.createUtf16(rt, &.{ 0x100, ',' })).value());
            try right.set(rt, (try core.string.String.createUtf16(rt, &.{ '|', 0xd800, ',', '|' })).value());
            try source.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value());
            try left.set(rt, (try core.string.String.createAscii(rt, ",")).value());
            try right.set(rt, (try core.string.String.createAscii(rt, "|")).value());
            try separator.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value());
            if (mode == 1) try separator.set(rt, (try rt.emptyString()).value());
            if (mode == 2) try separator.set(rt, core.JSValue.undefinedValue());
            // Exercise the native-text fallback as well as the rope path.
            if (mode == 4) {
                try source.set(rt, core.JSValue.int32(121));
                try separator.set(rt, (try core.string.String.createAscii(rt, "2")).value());
            }
            break :input [_]core.JSValue{ try source.get(rt), try separator.get(rt) };
        };
        const threshold = rt.gc.heap_budget.gc_threshold;
        defer rt.gc.heap_budget.gc_threshold = threshold;
        rt.gc.heap_budget.gc_threshold = 0;
        const epoch = rt.gc.collection_epoch;
        const before = rt.active_value_roots;
        const result = try zjs.exec.string_ops.methodCall(rt, inputs[0], 27, &.{ inputs[1], if (mode == 3) core.JSValue.int32(0) else core.JSValue.undefinedValue() });
        const array = core.value_semantics.objectFromValue(result).?;
        const length = (try array.getProperty(core.atom.ids.length)).as(.int).?;
        try require(length == ([_]i32{ 3, 6, 1, 0, 2 })[mode]);
        if (mode == 0) {
            try require(core.string.stringValueCodeUnitAtUnchecked(try array.getProperty(core.Atom.taggedInt(0)), 0) == 0x100);
            try require(core.string.stringValueCodeUnitAtUnchecked(try array.getProperty(core.Atom.taggedInt(1)), 0) == 0xd800);
            try require(core.string.stringValueLenUnchecked(try array.getProperty(core.Atom.taggedInt(2))) == 0);
        } else if (mode == 1) {
            for ([_]u16{ 0x100, ',', '|', 0xd800, ',', '|' }, 0..) |unit, index| {
                const value = try array.getProperty(core.Atom.taggedInt(@intCast(index)));
                try require(core.string.stringValueLenUnchecked(value) == 1);
                try require(core.string.stringValueCodeUnitAtUnchecked(value, 0) == unit);
            }
        } else if (mode == 2) {
            try require(core.string.stringValueLenUnchecked(try array.getProperty(core.Atom.taggedInt(0))) == 6);
        } else if (mode == 4) {
            for (0..2) |index| try require(core.string.asFlat(try array.getProperty(core.Atom.taggedInt(@intCast(index)))).?.eqlBytes("1"));
        }
        try require(rt.gc.collection_epoch > epoch);
        try require(rt.active_value_roots == before);
    }
}

fn verifyStringWrapperAndRepeat(rt: *core.JSRuntime) !void {
    for ([_]bool{ false, true }) |repeat_string| {
        const input = input: {
            var roots = core.runtime.ExactValueRoots(2){};
            try roots.activate(rt);
            defer roots.deactivate();
            const left = try roots.ref(0);
            const right = try roots.ref(1);
            try left.set(rt, (try core.string.String.createAscii(rt, "a")).value());
            try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 0x100, 0xd800 })).value());
            break :input (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value();
        };
        // The wrapper must root its input and partially initialized output.
        // Repeat consumes its input before allocating the result.
        const threshold = rt.gc.heap_budget.gc_threshold;
        defer rt.gc.heap_budget.gc_threshold = threshold;
        rt.gc.heap_budget.gc_threshold = 0;
        const epoch = rt.gc.collection_epoch;
        const before = rt.active_value_roots;
        if (repeat_string) {
            const result = try zjs.exec.string_ops.methodCall(rt, input, 33, &.{core.JSValue.int32(3)});
            try require(core.string.stringValueLen(result) == 9);
            for (0..9) |index| {
                try require(core.string.stringValueCodeUnitAtUnchecked(result, index) == ([_]u16{ 'a', 0x100, 0xd800 })[index % 3]);
            }
        } else {
            const result = try zjs.exec.string_ops.constructWithPrototype(rt, &.{input}, null);
            const object = core.value_semantics.objectFromValue(result).?;
            const stored = object.objectData().?;
            try require(stored.same(input));
            try require(!stored.ropeBody().?.isLinearized());
            try require((try object.getProperty(core.atom.ids.length)).as(.int).? == 3);
            try require(core.string.stringValueCodeUnitAtUnchecked(try object.getProperty(core.Atom.taggedInt(2)), 0) == 0xd800);
        }
        try require(rt.gc.collection_epoch > epoch);
        try require(rt.active_value_roots == before);
    }
}

fn verifyStringSearchRoots(rt: *core.JSRuntime) !void {
    for ([_]u32{ 4, 28, 5, 6, 7 }) |method| {
        const inputs = input: {
            var roots = core.runtime.ExactValueRoots(4){};
            try roots.activate(rt);
            defer roots.deactivate();
            const left = try roots.ref(0);
            const right = try roots.ref(1);
            const source = try roots.ref(2);
            const needle = try roots.ref(3);
            try left.set(rt, (try core.string.String.createAscii(rt, "a")).value());
            try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 0x100, 'y', 0x100, 'y' })).value());
            try source.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value());
            try left.set(rt, (try core.string.String.createUtf16(rt, &.{0x100})).value());
            try right.set(rt, (try core.string.String.createAscii(rt, "y")).value());
            try needle.set(rt, (try core.string.String.createRope(rt, try left.get(rt), try right.get(rt))).value());
            break :input [_]core.JSValue{ try source.get(rt), try needle.get(rt) };
        };
        // Only the callee owns precise roots for these operands from here.
        const threshold = rt.gc.heap_budget.gc_threshold;
        defer rt.gc.heap_budget.gc_threshold = threshold;
        rt.gc.scheduler.host_quiescent = true;
        rt.gc.heap_budget.gc_threshold = 0;
        const epoch = rt.gc.collection_epoch;
        const before = rt.active_value_roots;
        const pos = if (method == 6) core.JSValue.int32(3) else if (method == 7) core.JSValue.int32(5) else core.JSValue.undefinedValue();
        const result = try zjs.exec.string_ops.methodCall(rt, inputs[0], method, &.{ inputs[1], pos });
        try require(rt.gc.collection_epoch > epoch);
        try require(rt.active_value_roots == before);
        if (method == 4 or method == 28) {
            try require(result.as(.int).? == @as(i32, if (method == 4) 1 else 3));
        } else try require(result.as(.boolean).?);
    }
}

fn verifyRopeQueries(rt: *core.JSRuntime) !void {
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const left = try roots.ref(0);
    const right = try roots.ref(1);
    const source = try roots.ref(2);
    try left.set(rt, (try core.string.String.createUtf16(rt, &.{ ' ', 0xd800 })).value());
    try right.set(rt, (try core.string.String.createUtf16(rt, &.{ 0xdc00, 0xdc01, ' ' })).value());
    const rope = try core.string.String.createRope(rt, try left.get(rt), try right.get(rt));
    try source.set(rt, rope.value());
    const epoch = rt.gc.collection_epoch;
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    try require(zjs.exec.string_ops.stringAtomId(try source.get(rt)) == null);
    try require((try zjs.exec.string_ops.methodCall(rt, try source.get(rt), 38, &.{})).as(.boolean).? == false);
    try require(rt.gc.collection_epoch == epoch);
    rt.setMemoryLimit(null);
    const threshold = rt.gc.heap_budget.gc_threshold;
    defer rt.gc.heap_budget.gc_threshold = threshold;
    rt.gc.heap_budget.gc_threshold = 0;
    const trimmed = try zjs.exec.string_ops.methodCall(rt, try source.get(rt), 8, &.{});
    try require(core.string.stringValueLen(trimmed) == 3);
    const repaired = try zjs.exec.string_ops.methodCall(rt, try source.get(rt), 39, &.{});
    try require(core.string.stringValueCodeUnitAtUnchecked(repaired, 3) == 0xfffd);
    try require(rt.gc.collection_epoch > epoch);
    try require(!rope.isLinearized());
}

fn verifyStringConversionChains(rt: *core.JSRuntime) !void {
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const scripts = [_][]const u8{
        "({ toString() { const allocation = { x: 1 }; return 'NFC'; } })",
        "({ toString() { const allocation = { x: 1 }; return '\\u00e9'; } })",
        "({ toString() { const allocation = { x: 1 }; return 'e'; } })",
    };
    for (scripts, 0..) |script, mode| {
        const argument = try ctx.eval(script, .{});
        const source = try core.string.String.createUtf16(rt, &.{ 'e', 0x301 });
        const global = try ctx.core.globalObject();
        const threshold = rt.gc.heap_budget.gc_threshold;
        defer rt.gc.heap_budget.gc_threshold = threshold;
        rt.gc.scheduler.host_quiescent = true;
        rt.gc.heap_budget.gc_threshold = 0;
        const epoch = rt.gc.collection_epoch;
        const before = rt.active_value_roots;
        const result = switch (mode) {
            0 => try zjs.exec.string_ops.stringNormalize(ctx.core, null, global, source.value(), &.{argument}, null, null),
            1 => try zjs.exec.string_ops.stringLocaleCompare(ctx.core, null, global, source.value(), &.{argument}, null, null),
            else => try zjs.exec.string_ops.stringSearchPositionMethod(ctx.core, null, global, source.value(), 4, &.{argument}, null, null),
        };
        try require(rt.gc.collection_epoch > epoch);
        try require(rt.active_value_roots == before);
        if (mode == 0) {
            try require(core.string.stringValueLen(result) == 1);
            try require(core.string.stringValueCodeUnitAtUnchecked(result, 0) == 0xe9);
        } else try require(result.as(.int).? == 0);
    }
}

fn verifyStableHeaderRoot(rt: *core.JSRuntime) !void {
    const shape = try rt.shapes.createObjectRootReserved(rt, null);
    rt.shapes.publish(shape);
    const headers = [_]core.runtime.HeaderRootValue{.{ .header = &shape.header }};
    var roots = core.runtime.ValueRootFrame{ .headers = &headers };
    roots.activate(rt);
    defer roots.deactivate(rt);
    try require(rt.active_value_roots == &roots);
    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
    try require(rt.gc.containsHeader(&shape.header));
}

fn verifyGenericReplace(rt: *core.JSRuntime) !void {
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const rx = try roots.ref(0);
    const replacer = try roots.ref(1);
    const source = try roots.ref(2);
    try rx.set(rt, try ctx.eval("({ flags: 'g', n: 0, exec() { if (this.n === 3) return null; const n = this.n++; return { 0: 'a', 1: 'cap' + n, length: 2, index: n, groups: { n } }; } })", .{}));
    try replacer.set(rt, try ctx.eval("(function (m, cap, index, input, groups) { const allocated = { text: 'allocation' + index }; return groups.n + cap; })", .{}));
    try source.set(rt, (try core.string.String.createAscii(rt, "aaa")).value());
    const global = try ctx.core.globalObject();
    const threshold = rt.gc.heap_budget.gc_threshold;
    defer rt.gc.heap_budget.gc_threshold = threshold;
    rt.gc.scheduler.host_quiescent = true;
    rt.gc.heap_budget.gc_threshold = 0;
    const epoch = rt.gc.collection_epoch;
    const pin_count = rt.gc.pins.headers().len;
    const active_roots = rt.active_value_roots;
    const result = try zjs.exec.string_ops.regExpSymbolReplaceGeneric(ctx.core, null, global, try rx.get(rt), try source.get(rt), try replacer.get(rt), null, null);
    try require(rt.gc.collection_epoch > epoch);
    try require(rt.gc.pins.headers().len == pin_count);
    try require(rt.active_value_roots == active_roots);
    try require(result.asStringBodyRaw().?.eqlBytes("0cap01cap12cap2"));
}

fn verifyStringMatchAll(rt: *core.JSRuntime) !void {
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const global = try ctx.core.globalObject();
    const source = try core.string.String.createAscii(rt, "production-string-matchAll");
    const threshold = rt.gc.heap_budget.gc_threshold;
    defer rt.gc.heap_budget.gc_threshold = threshold;
    rt.gc.scheduler.host_quiescent = true;
    rt.gc.heap_budget.gc_threshold = 0;
    const epoch = rt.gc.collection_epoch;
    const result = try zjs.exec.string_ops.stringMatchAll(ctx.core, null, global, source.value(), &.{}, null, null);
    try require(rt.gc.collection_epoch > epoch);
    const iterator = core.value_semantics.objectFromValue(result).?;
    try require(iterator.class_id == core.class.ids.regexp_string_iterator);
    try require(iterator.iteratorData().?.asStringBodyRaw().?.eqlBytes("production-string-matchAll"));
}

fn verifyIteratorResult(rt: *core.JSRuntime) !void {
    const source = try core.string.String.createAscii(rt, "production-iterator-result");
    const header = source.header();
    const before = rt.active_value_roots;
    const epoch = rt.gc.collection_epoch;
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    if (zjs.exec.iterator_ops.createIteratorResult(rt, null, source.value(), false)) |_| return error.ExpectedIteratorResultOom else |err| {
        if (err != error.OutOfMemory) return err;
    }
    try require(rt.gc.collection_epoch > epoch);
    try require(rt.gc.containsHeader(header));
    try require(rt.active_value_roots == before);
    rt.setMemoryLimit(null);
    const result = try zjs.exec.iterator_ops.createIteratorResult(rt, null, source.value(), false);
    const object = core.value_semantics.objectFromValue(result).?;
    try require((try object.getProperty(core.atom.ids.value)).asStringBodyRaw().?.eqlBytes("production-iterator-result"));
    try require((try object.getProperty(core.atom.ids.done)).as(.boolean).? == false);
}

fn verifyRegExpMatchAll(rt: *core.JSRuntime) !void {
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const rx = try ctx.eval("/x/g", .{});
    const global = try ctx.core.globalObject();
    const source = try core.string.String.createAscii(rt, "production-matchAll-source");
    const arguments = [_]core.JSValue{source.value()};
    const threshold = rt.gc.heap_budget.gc_threshold;
    defer rt.gc.heap_budget.gc_threshold = threshold;
    rt.gc.scheduler.host_quiescent = true;
    rt.gc.heap_budget.gc_threshold = 0;
    const epoch = rt.gc.collection_epoch;
    const result = (try zjs.exec.string_ops.regExpSymbolMatchAll(ctx.core, null, global, rx, &arguments, null, null)) orelse return error.ExpectedMatchAllIterator;
    try require(rt.gc.collection_epoch > epoch);
    var roots = core.runtime.ExactValueRoots(1){};
    try roots.activate(rt);
    defer roots.deactivate();
    const published = try roots.ref(0);
    try published.set(rt, result);
    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
    const iterator = core.value_semantics.objectFromValue(try published.get(rt)).?;
    try require(iterator.class_id == core.class.ids.regexp_string_iterator);
    try require(iterator.iteratorTargetSlot().* != null);
    try require(iterator.iteratorData().?.asStringBodyRaw().?.eqlBytes("production-matchAll-source"));
}

fn verifyRegExpMatchSearch(rt: *core.JSRuntime) !void {
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const global = try ctx.core.globalObject();
    for ([_]bool{ false, true }) |match| {
        const rx = try ctx.eval(if (match)
            "({ flags: 'g', lastIndex: 0, n: 0, exec() { return this.n++ ? null : { 0: 'found' }; } })"
        else
            "({ get lastIndex() { return {}; }, set lastIndex(v) {}, exec() { return { index: 2 }; } })", .{});
        const source = try core.string.String.createAscii(rt, "production-regexp-source");
        const threshold = rt.gc.heap_budget.gc_threshold;
        defer rt.gc.heap_budget.gc_threshold = threshold;
        rt.gc.scheduler.host_quiescent = true;
        rt.gc.heap_budget.gc_threshold = 0;
        const epoch = rt.gc.collection_epoch;
        const result = if (match)
            try zjs.exec.string_ops.regExpSymbolMatchGeneric(ctx.core, null, global, rx, source.value(), null, null)
        else
            try zjs.exec.string_ops.regExpSymbolSearchGeneric(ctx.core, null, global, rx, source.value(), null, null);
        try require(rt.gc.collection_epoch > epoch);
        try require(rt.gc.containsHeader(source.header()));
        if (match) {
            const array = core.value_semantics.objectFromValue(result).?;
            try require((try array.getProperty(core.Atom.taggedInt(0))).asStringBodyRaw().?.eqlBytes("found"));
        } else try require(result.as(.int).? == 2);
    }
}

fn verifyRegExpSplitEntry(rt: *core.JSRuntime) !void {
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const rx = try ctx.eval("/x/", .{});
    const global = try ctx.core.globalObject();
    const source = try core.string.String.createAscii(rt, "split-entry-source");
    const arguments = [_]core.JSValue{ source.value(), core.JSValue.int32(1) };
    const threshold = rt.gc.heap_budget.gc_threshold;
    defer rt.gc.heap_budget.gc_threshold = threshold;
    rt.gc.scheduler.host_quiescent = true;
    rt.gc.heap_budget.gc_threshold = 0;
    const epoch = rt.gc.collection_epoch;
    const result = (try zjs.exec.string_ops.regExpSymbolSplit(ctx.core, null, global, rx, &arguments, null, null)) orelse return error.ExpectedSplitResult;
    try require(rt.gc.collection_epoch > epoch);
    const array = core.value_semantics.objectFromValue(result).?;
    const part = try array.getProperty(core.Atom.taggedInt(0));
    try require(part.asStringBodyRaw().?.eqlBytes("split-entry-source"));
}

fn verifyAsciiSuffix(rt: *core.JSRuntime) !void {
    const input = try core.string.String.createUtf16(rt, &.{ 0x100, 'u' });
    const header = input.header();
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    const epoch = rt.gc.collection_epoch;
    if (zjs.exec.value_ops.appendAsciiSuffixOwned(rt, input.value(), "y")) |_| return error.ExpectedSuffixOom else |err| {
        if (err != error.OutOfMemory) return err;
    }
    try require(rt.gc.collection_epoch > epoch);
    try require(rt.gc.containsHeader(header));
    rt.setMemoryLimit(null);
    const result = try zjs.exec.value_ops.appendAsciiSuffixOwned(rt, input.value(), "y");
    const flat = result.asStringBodyRaw().?;
    try require(flat.isWide() and flat.len() == 3);
    try require(flat.codeUnitAt(0) == 0x100 and flat.codeUnitAt(1) == 'u' and flat.codeUnitAt(2) == 'y');
}

fn verifyRegExpSplit(rt: *core.JSRuntime) !void {
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const splitter = try ctx.eval("({ lastIndex: 0, exec() { return null; } })", .{});
    const global = try ctx.core.globalObject();
    const a = try core.string.String.createUtf16(rt, &.{ 'a', 0xd83d });
    const b = try core.string.String.createUtf16(rt, &.{ 0xde00, 'b' });
    const source = try core.string.String.createRope(rt, a.value(), b.value());
    const threshold = rt.gc.heap_budget.gc_threshold;
    defer rt.gc.heap_budget.gc_threshold = threshold;
    rt.gc.scheduler.host_quiescent = true;
    rt.gc.heap_budget.gc_threshold = 0;
    const epoch = rt.gc.collection_epoch;
    const result = try zjs.exec.string_ops.regExpSymbolSplitGeneric(ctx.core, null, global, splitter, source.value(), 20, true, null, null);
    try require(rt.gc.collection_epoch > epoch);
    try require(!source.isLinearized());
    const array = core.value_semantics.objectFromValue(result).?;
    try require((try array.getProperty(core.Atom.taggedInt(0))).bits == source.value().bits);
}

fn verifyRegExpReplace(rt: *core.JSRuntime) !void {
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const rx = try ctx.eval("/a/g", .{});
    const global = try ctx.core.globalObject();
    const a = try core.string.String.createAscii(rt, "a");
    const b = try core.string.String.createAscii(rt, "b");
    const source = try core.string.String.createRope(rt, a.value(), b.value());
    const replacement = try core.string.String.createRope(rt, b.value(), a.value());
    const threshold = rt.gc.heap_budget.gc_threshold;
    defer rt.gc.heap_budget.gc_threshold = threshold;
    rt.gc.scheduler.host_quiescent = true;
    rt.gc.heap_budget.gc_threshold = 0;
    const epoch = rt.gc.collection_epoch;
    const result = (try zjs.exec.string_ops.regExpReplaceFast(ctx.core, null, global, rx, source.value(), replacement.value(), null, null)) orelse return error.ExpectedFastReplace;
    try require(rt.gc.collection_epoch > epoch);
    try require(result.asStringBodyRaw().?.eqlBytes("bab"));
}

fn verifySlices(rt: *core.JSRuntime) !void {
    // No caller root or conservative scan: createSlice must register parent
    // itself even in the non-test configuration and when allocation fails.
    const parent = try core.string.String.createUtf16(rt, &.{ 0x100, 'a', 'b', 0xd800 });
    const header = parent.header();
    const threshold = rt.gc.heap_budget.gc_threshold;
    defer rt.gc.heap_budget.gc_threshold = threshold;
    rt.gc.heap_budget.gc_threshold = 0;
    const epoch = rt.gc.collection_epoch;
    const narrow = try core.string.String.createSlice(rt, parent, 1, 2);
    try require(rt.gc.collection_epoch > epoch);
    try require(!narrow.isWide() and narrow.eqlBytes("ab"));
    try require(rt.gc.containsHeader(header));
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    const before = rt.gc.collection_epoch;
    if (core.string.String.createSlice(rt, parent, 2, 2)) |_| return error.ExpectedSliceOom else |err| {
        if (err != error.OutOfMemory) return err;
    }
    try require(rt.gc.collection_epoch > before);
    try require(rt.gc.containsHeader(header));
    rt.setMemoryLimit(null);
    const wide = try core.string.String.createSlice(rt, parent, 2, 2);
    try require(wide.isWide() and wide.len() == 2);
    try require(wide.codeUnitAt(0) == 'b' and wide.codeUnitAt(1) == 0xd800);
}

fn verifyConcat(rt: *core.JSRuntime) !void {
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
    var parts: [3]core.JSValue = undefined;
    {
        var roots = core.runtime.ExactValueRoots(2){};
        try roots.activate(rt);
        defer roots.deactivate();
        const left = try roots.ref(0);
        const right = try roots.ref(1);
        try left.set(rt, (try core.string.String.createAscii(rt, "left")).value());
        try right.set(rt, (try core.string.String.createAscii(rt, "right")).value());
        parts = .{ try left.get(rt), try right.get(rt), core.JSValue.int32(-2147483648) };
    }
    // Only the callee registers these values during each call. The native
    // array itself is not a root, and conservative retention is disabled.
    // Use the real threshold: allocation probes are erased outside tests.
    const threshold = rt.gc.heap_budget.gc_threshold;
    defer rt.gc.heap_budget.gc_threshold = threshold;
    rt.gc.heap_budget.gc_threshold = 0;
    const epoch = rt.gc.collection_epoch;
    const joined = try zjs.exec.string_ops.stringConcat(ctx, null, global, parts[0], parts[1..], null, null);
    try require(rt.gc.collection_epoch > epoch);
    try require(core.string.asFlat(joined).?.eqlBytes("leftright-2147483648"));
    rt.gc.heap_budget.gc_threshold = 0;
    const before = rt.gc.collection_epoch;
    const direct = try core.string.String.createConcatParts(rt, &parts);
    try require(rt.gc.collection_epoch > before);
    try require(direct.eqlBytes("leftright-2147483648"));
}

fn verifyPadding(rt: *core.JSRuntime) !void {
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try zjs.exec.zjs_vm.contextGlobal(ctx);
    var roots = core.runtime.ExactValueRoots(2){};
    try roots.activate(rt);
    defer roots.deactivate();
    const input = try roots.ref(0);
    const right = try roots.ref(1);
    try input.set(rt, (try core.string.String.createAscii(rt, "a")).value());
    try right.set(rt, (try core.string.String.createAscii(rt, "b")).value());
    try input.set(rt, (try core.string.String.createRope(rt, try input.get(rt), try right.get(rt))).value());
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    const epoch = rt.gc.collection_epoch;
    const unchanged = try zjs.exec.string_ops.stringPad(ctx, null, global, try input.get(rt), 34, &.{core.JSValue.int32(0)}, null, null);
    try require(unchanged.bits == (try input.get(rt)).bits);
    try require(rt.gc.collection_epoch == epoch);
    if (zjs.exec.string_ops.stringPad(ctx, null, global, try input.get(rt), 35, &.{ core.JSValue.int32(7), try input.get(rt) }, null, null)) |_| return error.ExpectedPaddingOom else |err| {
        if (err != error.OutOfMemory) return err;
    }
    try require(rt.gc.collection_epoch > epoch);
    try require(!(try input.get(rt)).ropeBody().?.isLinearized());
    rt.setMemoryLimit(null);
    const padded = try zjs.exec.string_ops.stringPad(ctx, null, global, try input.get(rt), 35, &.{ core.JSValue.int32(7), try input.get(rt) }, null, null);
    try require(core.string.asFlat(padded).?.eqlBytes("abababa"));
    try require(!(try input.get(rt)).ropeBody().?.isLinearized());
}

fn verifyStreamingConversions(rt: *core.JSRuntime) !void {
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const left = try roots.ref(0);
    const right = try roots.ref(1);
    const input = try roots.ref(2);
    try left.set(rt, (try core.string.String.createAscii(rt, "1")).value());
    try right.set(rt, (try core.string.String.createAscii(rt, "23")).value());
    const rope = try core.string.String.createRope(rt, try left.get(rt), try right.get(rt));
    try input.set(rt, rope.value());
    const epoch = rt.gc.collection_epoch;
    rt.setMemoryLimit(0);
    defer rt.setMemoryLimit(null);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try core.string.appendValueUtf8(rt, &bytes, try input.get(rt));
    try require(std.mem.eql(u8, bytes.items, "123"));
    const number = try zjs.exec.value_ops.toNumberValue(rt, try input.get(rt));
    try require(number.as(.int).? == 123);
    var bigint = try zjs.exec.value_ops.toBigIntValue(rt, try input.get(rt));
    defer bigint.deinit();
    try require(bigint.toI64().? == 123);
    try require(!rope.isLinearized());
    try require(rt.gc.collection_epoch == epoch);
}
