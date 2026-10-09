//! Core integration tests: roots_nursery.
const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const core = zjs.core;
const helpers = @import("../harness.zig");

test "no-GC scope nesting native allocation and error unwind" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const other = try core.JSRuntime.create(std.testing.allocator, .{});
    defer other.destroy();
    const Probe = struct {
        fn fail(runtime: *core.JSRuntime) !void {
            var inner = core.runtime.NoGcScope{};
            inner.activate(runtime);
            defer inner.deactivate();
            const bytes = try runtime.nativeAllocator().alloc(u8, 64);
            defer runtime.nativeAllocator().free(bytes);
            return error.BorrowAborted;
        }
    };
    var outer = core.runtime.NoGcScope{};
    outer.activate(rt);
    defer outer.deactivate();
    try std.testing.expectError(error.BorrowAborted, Probe.fail(rt));
    try std.testing.expect(rt.active_no_gc_scope == &outer);
    // The prohibition belongs to one Runtime, not to the owner thread.
    const other_epoch = other.gc.collection_epoch;
    _ = try other.collectForTest();
    try std.testing.expect(other.gc.collection_epoch > other_epoch);
    outer.deactivate();
    try std.testing.expect(rt.active_no_gc_scope == null);
    outer.activate(rt);
    outer.deactivate();
    const epoch = rt.gc.collection_epoch;
    _ = try rt.collectForTest();
    try std.testing.expect(rt.gc.collection_epoch > epoch);
}

test "no-GC scope lifecycle and collection entry guards" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var outer = core.runtime.NoGcScope{};
    outer.activate(rt);
    defer outer.deactivate();
    var inner = core.runtime.NoGcScope{};
    inner.activate(rt);
    defer inner.deactivate();
    const mode = if (std.c.getenv("ZJS_NO_GC_INJECT")) |raw| std.fmt.parseInt(u8, std.mem.span(raw), 10) catch 0 else 0;
    switch (mode) {
        1 => _ = try rt.collectForTest(),
        2 => _ = try rt.pollGC(.safepoint),
        3 => _ = try core.gc_trace_stw.collectCycles(rt, .declared_only),
        4 => _ = try core.gc_trace_stw.collectMinor(rt, .declared_only),
        5 => _ = try @import("../../src/core/gc_driver.zig").pollGC(rt, .safepoint),
        8 => rt.destroy(),
        9 => outer.deactivate(),
        10 => {
            var copied = inner;
            copied.deactivate();
        },
        11 => inner.activate(rt),
        else => {},
    }
}

test "heap reference layout bridge preserves VarRef identity rather than cell contents" {
    const layout = @import("../../src/core/value_heap_layout.zig");
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(3){};
    try roots.activate(rt);
    defer roots.deactivate();
    const first = try core.VarRef.createClosed(rt, core.JSValue.int32(42));
    try (try roots.ref(0)).set(rt, first.valueRef());
    const copied = try core.VarRef.createClosed(rt, core.JSValue.int32(42));
    try (try roots.ref(1)).set(rt, copied.valueRef());
    const object = try core.Object.createPlainObject(rt, null);
    try (try roots.ref(2)).set(rt, object.value());
    const value = try (try roots.ref(0)).get(rt);
    try std.testing.expect(value.is(.object));
    try std.testing.expectEqual(core.gc.RefKind.var_ref, layout.header(value.heapReference().?).metaConst().flags.kind);
    try std.testing.expectEqual(value.cycleMarkHeader().?, layout.header(value.heapReference().?));
    const copied_value = layout.relocate(value, (try (try roots.ref(1)).get(rt)).heapReference().?);
    try std.testing.expect(copied_value.is(.object));
    try std.testing.expectEqual((try (try roots.ref(1)).get(rt)).bits, copied_value.bits);
    try std.testing.expect(!copied_value.same(core.JSValue.int32(42)));
    if (std.c.getenv("ZJS_VALUE_ENCODING_INJECT")) |raw| {
        if (std.mem.eql(u8, std.mem.span(raw), "3"))
            std.mem.doNotOptimizeAway(layout.relocate(value, object.value().heapReference().?));
    }
}

test "exact value roots validate lifetime runtime aliasing and reused scopes" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const other = try core.JSRuntime.create(std.testing.allocator, .{});
    defer other.destroy();
    var scope = core.runtime.ExactValueRoots(2){};
    try std.testing.expectError(error.InactiveRoot, scope.ref(0));
    try scope.activate(rt);
    defer scope.deactivate();
    try std.testing.expectError(error.RootAlreadyActive, scope.activate(rt));
    const first = try scope.ref(0);
    const second = try scope.ref(1);
    try first.set(rt, core.JSValue.int32(7));
    try first.copyFrom(rt, first.readOnly());
    try second.copyFrom(rt, first.readOnly());
    try std.testing.expectEqual(@as(?i32, 7), (try second.get(rt)).as(.int));
    try std.testing.expectError(error.WrongRuntime, first.get(other));
    try std.testing.expectError(error.WrongRuntime, first.set(other, core.JSValue.int32(9)));
    scope.deactivate();
    try std.testing.expectError(error.InactiveRoot, first.get(rt));
    try scope.activate(rt);
    // Reusing the same frame address must not revive old borrows.
    try std.testing.expect((try (try scope.ref(0)).get(rt)).is(.undefined_value));
    try std.testing.expectError(error.InactiveRoot, first.get(rt));
    try std.testing.expectError(error.InactiveRoot, first.set(rt, core.JSValue.int32(9)));
    try (try scope.ref(0)).set(rt, core.JSValue.int32(11));
    {
        var inner = core.runtime.ExactValueRoots(1){};
        try inner.activate(rt);
        defer inner.deactivate();
        try (try inner.ref(0)).copyFrom(rt, (try scope.ref(0)).readOnly());
        try std.testing.expectEqual(@as(?i32, 11), (try (try inner.ref(0)).get(rt)).as(.int));
    }
    try std.testing.expectEqual(@as(?i32, 11), (try (try scope.ref(0)).get(rt)).as(.int));
    const Escaped = struct {
        fn borrow(runtime: *core.JSRuntime) !core.runtime.RootedValueRef {
            var local = core.runtime.ExactValueRoots(1){};
            try local.activate(runtime);
            defer local.deactivate();
            return (try local.ref(0)).readOnly();
        }
    };
    const escaped = try Escaped.borrow(rt);
    // The frame's storage has left scope; validation must not dereference it.
    try std.testing.expectError(error.InactiveRoot, escaped.get(rt));
}

test "exact value roots protect handle transfer and failed transfer keeps ownership" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const other = try core.JSRuntime.create(std.testing.allocator, .{});
    defer other.destroy();
    var destination = core.runtime.ExactValueRoots(1){};
    try destination.activate(other);
    defer destination.deactivate();
    const wrong_runtime = try destination.ref(0);
    var handle = try core.runtime.JSValueHandle.init(rt, (try core.string.String.createAscii(rt, "exact-root-transfer")).value());
    defer handle.deinit();
    const header = handle.get().cycleMarkHeader().?;
    try std.testing.expectError(error.WrongRuntime, handle.takeInto(wrong_runtime));
    try std.testing.expectEqual(@as(usize, 1), rt.roots.persistent_root_slots.items.len);
    try std.testing.expectEqual(header, handle.get().cycleMarkHeader().?);
    try std.testing.expect((try wrong_runtime.get(other)).is(.undefined_value));
    destination.deactivate();
    try destination.activate(rt);
    const expired = try destination.ref(0);
    destination.deactivate();
    try std.testing.expectError(error.InactiveRoot, handle.takeInto(expired));
    try std.testing.expectEqual(@as(usize, 1), rt.roots.persistent_root_slots.items.len);
    try destination.activate(rt);
    const output = try destination.ref(0);
    try handle.takeInto(output);
    try std.testing.expect(handle.slot == null);
    try std.testing.expectEqual(@as(usize, 0), rt.roots.persistent_root_slots.items.len);
    _ = try rt.collectForTest();
    try std.testing.expect(rt.gc.containsHeader(header));
    try std.testing.expect((try output.get(rt)).asStringBodyRaw().?.eqlBytes("exact-root-transfer"));
    try output.set(rt, core.JSValue.undefinedValue());
    _ = try rt.collectForTest();
    try std.testing.expect(!rt.gc.containsHeader(header));
}

test "exact value roots register without allocation and unwind early errors" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const Fixture = struct {
        fn fail(runtime: *core.JSRuntime) !void {
            var roots = core.runtime.ExactValueRoots(1){};
            try roots.activate(runtime);
            defer roots.deactivate();
            try (try roots.ref(0)).set(runtime, core.JSValue.int32(42));
            return error.ExpectedEarlyExit;
        }
    };
    rt.setNativeBytesLimitForTest(rt.allocation_diagnostics.allocated_bytes);
    defer rt.setNativeBytesLimitForTest(null);
    try std.testing.expectError(error.ExpectedEarlyExit, Fixture.fail(rt));
    try std.testing.expect(rt.active_value_roots == null);
    try std.testing.expect(rt.roots.active_exact_roots == null);
    rt.roots.exact_root_generation = std.math.maxInt(u64);
    var exhausted = core.runtime.ExactValueRoots(1){};
    try std.testing.expectError(error.RootGenerationExhausted, exhausted.activate(rt));
    try std.testing.expect(rt.active_value_roots == null);
}

test "exact value roots expose actual slots for collector repair" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(1){};
    try roots.activate(rt);
    defer roots.deactivate();
    const reference = try roots.ref(0);
    try reference.set(rt, core.JSValue.int32(10));
    const Repair = struct {
        visits: usize = 0,
        fn value(raw: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.visits += 1;
            slot.* = core.JSValue.int32(20);
        }
        fn object(_: *anyopaque, _: *?*core.Object) core.runtime.RootTraceError!void {}
    };
    var repair = Repair{};
    var visitor = core.runtime.RootVisitor{ .readonly = .observe, .context = &repair, .visit_value = Repair.value, .visit_object = Repair.object };
    try core.runtime.ValueRootFrame.traceChain(rt.active_value_roots, &visitor);
    try std.testing.expectEqual(@as(usize, 1), repair.visits);
    try std.testing.expectEqual(@as(?i32, 20), (try reference.get(rt)).as(.int));
}

test "exact value roots reject mutator writes and activation during trace and collection" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(1){};
    try roots.activate(rt);
    defer roots.deactivate();
    const reference = try roots.ref(0);
    try reference.set(rt, core.JSValue.int32(7));
    const Probe = struct {
        rt: *core.JSRuntime,
        reference: core.runtime.MutableRootedValueRef,
        writes_denied: usize = 0,
        activations_denied: usize = 0,
        fn value(_: *anyopaque, _: *core.JSValue) core.runtime.RootTraceError!void {}
        fn object(_: *anyopaque, _: *?*core.Object) core.runtime.RootTraceError!void {}
        fn trace(raw: *anyopaque, _: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.reference.set(self.rt, core.JSValue.int32(9)) catch |err| {
                if (err != error.RootMutationDuringCollection) return error.PayloadMarkFailed;
                self.writes_denied += 1;
            };
            var attempted = core.runtime.ExactValueRoots(1){};
            attempted.activate(self.rt) catch |err| {
                if (err != error.RootMutationDuringCollection) return error.PayloadMarkFailed;
                self.activations_denied += 1;
                return;
            };
            attempted.deactivate();
            return error.PayloadMarkFailed;
        }
    };
    var probe = Probe{ .rt = rt, .reference = reference };
    const provider = core.runtime.RootProvider{ .context = &probe, .trace = Probe.trace };
    try rt.registerRootProvider(provider);
    defer rt.unregisterRootProvider(provider);
    var visitor = core.runtime.RootVisitor{ .readonly = .observe, .context = &probe, .visit_value = Probe.value, .visit_object = Probe.object };
    try std.testing.expect(!rt.gc.isCollecting());
    try rt.roots.traceProviders(&visitor);
    try std.testing.expectEqual(@as(usize, 1), probe.writes_denied);
    try std.testing.expectEqual(@as(usize, 1), probe.activations_denied);
    _ = try rt.collectForTest();
    try std.testing.expect(probe.writes_denied > 0);
    try std.testing.expectEqual(probe.writes_denied, probe.activations_denied);
    try std.testing.expectEqual(@as(?i32, 7), (try reference.get(rt)).as(.int));
}

test "root tracing unwinds nested failures and permits collector slot repair" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var handle = try core.runtime.JSValueHandle.init(rt, core.JSValue.int32(1));
    defer handle.deinit();
    const Probe = struct {
        rt: *core.JSRuntime,
        visits: usize = 0,
        fn value(raw: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (!self.rt.roots.isTracing()) return error.PayloadMarkFailed;
            self.visits += 1;
            slot.* = core.JSValue.int32(2);
            return error.OutOfMemory;
        }
        fn object(_: *anyopaque, _: *?*core.Object) core.runtime.RootTraceError!void {}
        fn trace(raw: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const depth = self.rt.roots.trace_depth;
            self.rt.roots.traceHandleSlots(visitor) catch |err| {
                if (self.rt.roots.trace_depth != depth) return error.PayloadMarkFailed;
                return err;
            };
            return error.PayloadMarkFailed;
        }
    };
    var probe = Probe{ .rt = rt };
    const provider = core.runtime.RootProvider{ .context = &probe, .trace = Probe.trace };
    try rt.registerRootProvider(provider);
    var visitor = core.runtime.RootVisitor{ .readonly = .observe, .context = &probe, .visit_value = Probe.value, .visit_object = Probe.object };
    try std.testing.expectError(error.OutOfMemory, rt.roots.traceProviders(&visitor));
    try std.testing.expectEqual(@as(usize, 0), rt.roots.trace_depth);
    try std.testing.expectEqual(@as(usize, 1), probe.visits);
    try std.testing.expectEqual(@as(?i32, 2), handle.get().as(.int));
    rt.unregisterRootProvider(provider);
    var next = try core.runtime.JSValueHandle.init(rt, core.JSValue.int32(3));
    next.deinit();
}

test "root tracing also freezes direct payload mark callbacks" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var roots = core.runtime.ExactValueRoots(1){};
    try roots.activate(rt);
    defer roots.deactivate();
    const reference = try roots.ref(0);
    try reference.set(rt, core.JSValue.int32(7));
    const Probe = struct {
        reference: core.runtime.MutableRootedValueRef,
        denied: bool = false,
        fn mark(raw_rt: *anyopaque, _: *anyopaque, payload: *core.class.Payload, _: *core.class.PayloadVisitor) void {
            const runtime: *core.JSRuntime = @ptrCast(@alignCast(raw_rt));
            const self: *@This() = @ptrCast(@alignCast(payload.*.?));
            self.reference.set(runtime, core.JSValue.int32(9)) catch |err| {
                self.denied = err == error.RootMutationDuringCollection;
            };
        }
    };
    const binding = try rt.registerClass(.{ .class_name = "TraceFreeze", .payload_mark = Probe.mark });
    var probe = Probe{ .reference = reference };
    var payload: core.class.Payload = &probe;
    var visitor = core.class.PayloadVisitor{ .context = &probe };
    const object = try core.Object.createPlainObject(rt, null);
    try std.testing.expect(!rt.gc.isCollecting());
    try std.testing.expect(rt.classes.markPayload(binding.id, rt, object, &payload, &visitor));
    try std.testing.expect(probe.denied);
    try std.testing.expect(!rt.roots.isTracing());
    try std.testing.expectEqual(@as(?i32, 7), (try reference.get(rt)).as(.int));
    try reference.set(rt, core.JSValue.int32(10));
}

test "root tracing lifecycle guards" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var handle = try core.runtime.JSValueHandle.init(rt, core.JSValue.int32(1));
    defer handle.deinit();
    var stored = core.JSValue.int32(2);
    var frame = core.runtime.rootValues(.{&stored});
    frame.activate(rt);
    defer frame.deactivate(rt);
    const Probe = struct {
        rt: *core.JSRuntime,
        handle: *core.runtime.JSValueHandle,
        frame: *core.runtime.ValueRootFrame,
        fn value(_: *anyopaque, _: *core.JSValue) core.runtime.RootTraceError!void {}
        fn object(_: *anyopaque, _: *?*core.Object) core.runtime.RootTraceError!void {}
        fn trace(raw: *anyopaque, _: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const mode = if (std.c.getenv("ZJS_TRACE_INJECT")) |env| std.fmt.parseInt(u8, std.mem.span(env), 10) catch 0 else 0;
            const provider = core.runtime.RootProvider{ .context = raw, .trace = trace };
            switch (mode) {
                1 => self.rt.registerRootProvider(provider) catch return error.OutOfMemory,
                2 => self.rt.unregisterRootProvider(provider),
                3 => {
                    var attempted = core.runtime.JSValueHandle.init(self.rt, core.JSValue.int32(3)) catch return error.OutOfMemory;
                    attempted.deinit();
                },
                4 => self.handle.deinit(),
                5 => {
                    var attempted: core.runtime.ValueRootFrame = .{};
                    attempted.activate(self.rt);
                    attempted.deactivate(self.rt);
                },
                6 => self.frame.deactivate(self.rt),
                7 => self.rt.destroy(),
                8 => _ = self.rt.collectForTest() catch return error.OutOfMemory,
                9 => _ = self.rt.pollGC(.safepoint) catch return error.OutOfMemory,
                10 => _ = core.gc_trace_stw.collectMinor(self.rt, .declared_only) catch return error.OutOfMemory,
                else => {},
            }
        }
    };
    var probe = Probe{ .rt = rt, .handle = &handle, .frame = &frame.frame };
    const provider = core.runtime.RootProvider{ .context = &probe, .trace = Probe.trace };
    try rt.registerRootProvider(provider);
    defer rt.unregisterRootProvider(provider);
    var visitor = core.runtime.RootVisitor{ .readonly = .observe, .context = &probe, .visit_value = Probe.value, .visit_object = Probe.object };
    try rt.roots.traceProviders(&visitor);
    try std.testing.expect(!rt.roots.isTracing());
}

test "exact value roots receive nursery relocation in every aliased slot" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.gc.nursery.enabled = true;
    var roots = core.runtime.ExactValueRoots(2){};
    try roots.activate(rt);
    defer roots.deactivate();
    const first = try roots.ref(0);
    const second = try roots.ref(1);
    const object = try core.Object.createPlainObject(rt, null);
    try first.set(rt, object.value());
    try second.copyFrom(rt, first.readOnly());
    const before = @intFromPtr(object.gcHeader());
    try std.testing.expect(core.gc.Registry.isNurseryHeader(object.gcHeader()));
    _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
    const moved = (try first.get(rt)).cycleMarkHeader().?;
    try std.testing.expect(@intFromPtr(moved) != before);
    try std.testing.expect(!core.gc.Registry.isNurseryHeader(moved));
    try std.testing.expectEqual((try first.get(rt)).bits, (try second.get(rt)).bits);
    try std.testing.expect(rt.gc.containsHeader(moved));
}

test "readonly roots retain nursery aliases before writable roots move" {
    for ([_]bool{ false, true }) |minor| {
        const rt = try core.JSRuntime.create(std.testing.allocator, .{});
        defer rt.destroy();
        rt.gc.nursery.enabled = true;
        const object = try core.Object.createPlainObject(rt, null);
        const borrowed = [_]core.JSValue{object.value()};
        const slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &borrowed }};
        var frame = core.runtime.ValueRootFrame{ .slices = &slices };
        frame.activate(rt);
        defer frame.deactivate(rt);
        // The younger mutable frame is visited first. A late pin cannot
        // repair the immutable reference after that visit has evacuated it.
        var roots = core.runtime.ExactValueRoots(1){};
        try roots.activate(rt);
        defer roots.deactivate();
        const writable = try roots.ref(0);
        try writable.set(rt, borrowed[0]);
        try std.testing.expect(core.gc.Registry.isNurseryHeader(object.gcHeader()));
        if (minor) {
            _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
        } else {
            _ = try rt.collectForTest();
        }
        try std.testing.expectEqual(borrowed[0].bits, (try writable.get(rt)).bits);
        try std.testing.expect(rt.gc.containsHeader(object.gcHeader()));
        try std.testing.expect(!core.gc.headerForwarded(object.gcHeader()));
    }
}

test "root protocol exposes Realm cache slots even when visitor fails" {
    for ([_]bool{ false, true }) |promise| {
        for ([_]bool{ false, true }) |fail| {
            const rt = try core.JSRuntime.create(std.testing.allocator, .{});
            defer rt.destroy();
            const ctx = try core.JSContext.create(rt, .{});
            defer ctx.destroy();
            const slot = if (promise) &ctx.cached_promise_proto else &ctx.cached_function_proto;
            const original = try core.Object.createPlainObject(rt, null);
            slot.* = original;
            const replacement = try core.Object.createPlainObject(rt, null);
            const Probe = struct {
                expected: *?*core.Object,
                original: *core.Object,
                replacement: *core.Object,
                fail: bool,
                actual_slot: bool = false,
                fn value(_: *anyopaque, _: *core.JSValue) core.runtime.RootTraceError!void {}
                fn object(raw: *anyopaque, incoming: *?*core.Object) core.runtime.RootTraceError!void {
                    const self: *@This() = @ptrCast(@alignCast(raw));
                    if (incoming.* != self.original) return;
                    self.actual_slot = incoming == self.expected;
                    incoming.* = self.replacement;
                    if (self.fail) return error.PayloadMarkFailed;
                }
            };
            var probe = Probe{ .expected = slot, .original = original, .replacement = replacement, .fail = fail };
            var visitor = core.runtime.RootVisitor{ .readonly = .observe, .context = &probe, .visit_value = Probe.value, .visit_object = Probe.object };
            if (fail) {
                try std.testing.expectError(error.PayloadMarkFailed, ctx.traceRoots(&visitor));
            } else {
                try ctx.traceRoots(&visitor);
            }
            try std.testing.expect(probe.actual_slot);
            try std.testing.expectEqual(replacement, slot.*.?);
        }
    }
}

test "root adapter string cache writes back before propagating visitor failure" {
    for ([_]bool{ false, true }) |optional| {
        for ([_]bool{ false, true }) |fail| {
            const rt = try core.JSRuntime.create(std.testing.allocator, .{});
            defer rt.destroy();
            const original = try core.string.String.createAscii(rt, "original");
            const replacement = try core.string.String.createAscii(rt, "replacement");
            const Probe = struct {
                replacement: core.JSValue,
                fail: bool,
                fn value(raw: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
                    const self: *@This() = @ptrCast(@alignCast(raw));
                    slot.* = self.replacement;
                    if (self.fail) return error.PayloadMarkFailed;
                }
                fn object(_: *anyopaque, _: *?*core.Object) core.runtime.RootTraceError!void {}
            };
            var probe = Probe{ .replacement = replacement.value(), .fail = fail };
            var visitor = core.runtime.RootVisitor{ .readonly = .observe, .context = &probe, .visit_value = Probe.value, .visit_object = Probe.object };
            var nullable: ?*core.string.String = original;
            var required = original;
            const result = if (optional) visitor.stringSlot(&nullable) else visitor.stringField(&required);
            if (fail) try std.testing.expectError(error.PayloadMarkFailed, result) else try result;
            try std.testing.expectEqual(replacement, if (optional) nullable.? else required);
        }
    }
}

test "root adapter Realm record exposes its actual slot on visitor failure" {
    const payloads = @import("../../src/core/object_payloads.zig");
    for ([_]bool{ false, true }) |fail| {
        const rt = try core.JSRuntime.create(std.testing.allocator, .{});
        defer rt.destroy();
        const original = try core.JSContext.create(rt, .{});
        defer original.destroy();
        const replacement = try core.JSContext.create(rt, .{});
        defer replacement.destroy();
        var payload = payloads.RealmRecordPayload{ .realm = core.context.RealmRef.retain(original) };
        defer payload.destroy();
        const Probe = struct {
            pub const gc_visit_policy: core.gc_visit.Policy = .partial;
            expected: *?*core.JSContext,
            replacement: *core.JSContext,
            fail: bool,
            actual_slot: bool = false,
            pub fn visitRealm(self: *@This(), slot: *?*core.JSContext) !void {
                self.actual_slot = slot == self.expected;
                slot.* = self.replacement;
                if (self.fail) return error.PayloadMarkFailed;
            }
        };
        var probe = Probe{ .expected = &payload.realm.ptr, .replacement = replacement, .fail = fail };
        if (fail) try std.testing.expectError(error.PayloadMarkFailed, payload.traceChildEdges(&probe)) else try payload.traceChildEdges(&probe);
        try std.testing.expect(probe.actual_slot);
        try std.testing.expectEqual(replacement, payload.realm.ptr.?);
    }
}

test "root protocol classifies cell carriers as stable references" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const cell = try core.VarRef.createClosed(rt, core.JSValue.int32(42));
    var cells = [_]*core.VarRef{cell};
    const live: []*core.VarRef = &cells;
    const slices = [_]core.runtime.ValueRootSlice{ .{ .cells = &live }, .{ .borrowed_cells = &cells } };
    const frame = core.runtime.ValueRootFrame{ .slices = &slices };
    const Probe = struct {
        expected: *core.gc.Header,
        stable: usize = 0,
        fn value(_: *anyopaque, _: *core.JSValue) core.runtime.RootTraceError!void {
            return error.PayloadMarkFailed;
        }
        fn object(_: *anyopaque, _: *?*core.Object) core.runtime.RootTraceError!void {
            return error.PayloadMarkFailed;
        }
        fn header(raw: *anyopaque, incoming: *const core.gc.Header) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (incoming != self.expected) return error.PayloadMarkFailed;
            self.stable += 1;
        }
    };
    var probe = Probe{ .expected = &cell.header };
    var visitor = core.runtime.RootVisitor{
        .context = &probe,
        .readonly = .{ .pinned = Probe.header },
        .visit_value = Probe.value,
        .visit_object = Probe.object,
    };
    try core.runtime.ValueRootFrame.traceChain(&frame, &visitor);
    try std.testing.expectEqual(@as(usize, 2), probe.stable);
}

test "nursery evacuation rollback restores roots after provider failure" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.gc.nursery.enabled = true;
    var roots = core.runtime.ExactValueRoots(1){};
    try roots.activate(rt);
    defer roots.deactivate();
    const root = try roots.ref(0);
    const object = try core.Object.createPlainObject(rt, null);
    try root.set(rt, object.value());
    try object.defineOwnProperty(rt, core.atom.ids.name, core.Descriptor.data(core.JSValue.int32(17), .all));
    try object.defineOwnProperty(rt, core.atom.ids.value, core.Descriptor.data(object.value(), .all));
    const before = (try root.get(rt)).bits;
    const Probe = struct {
        root: core.runtime.MutableRootedValueRef,
        rt: *core.JSRuntime,
        alias: core.JSValue,
        calls: usize = 0,
        saw_move: bool = false,
        fn trace(raw: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (self.calls == 2) {
                const current = self.root.get(self.rt) catch return error.PayloadMarkFailed;
                self.saw_move = current.bits != self.alias.bits;
                return error.OutOfMemory;
            }
            try visitor.value(&self.alias);
        }
    };
    var probe = Probe{ .root = root, .rt = rt, .alias = try root.get(rt) };
    const provider = core.runtime.RootProvider{ .context = &probe, .trace = Probe.trace };
    try rt.registerRootProvider(provider);
    defer rt.unregisterRootProvider(provider);
    try std.testing.expectError(error.OutOfMemory, rt.collectForTest());
    try std.testing.expect(probe.saw_move);
    try std.testing.expectEqual(before, (try root.get(rt)).bits);
    try std.testing.expect(!core.gc.headerForwarded(object.gcHeader()));
    try std.testing.expectEqual(@as(?i32, 17), (try object.getProperty(core.atom.ids.name)).as(.int));
    try std.testing.expectEqual(before, (try object.getProperty(core.atom.ids.value)).bits);
    try rt.gc.verifyHeapAccounting(rt);
    _ = try rt.collectForTest();
    const moved = try root.get(rt);
    try std.testing.expect(moved.bits != before);
    try std.testing.expectEqual(moved.bits, probe.alias.bits);
    const moved_object = core.Object.fromHeader(moved.cycleMarkHeader().?);
    try std.testing.expectEqual(moved.bits, (try moved_object.getProperty(core.atom.ids.value)).bits);
}

test "nursery weak identity follows live target and clears after death" {
    for ([_]bool{ false, true }) |minor| {
        const rt = try core.JSRuntime.create(std.testing.allocator, .{});
        defer rt.destroy();
        rt.gc.nursery.enabled = true;
        var roots = core.runtime.ExactValueRoots(1){};
        try roots.activate(rt);
        defer roots.deactivate();
        const root = try roots.ref(0);
        const object = try core.Object.createPlainObject(rt, null);
        try root.set(rt, object.value());
        var weak = try core.runtime.WeakPersistentValue.init(rt, object.value(), null, null);
        defer weak.deinit();
        const identity = weak.slot.?.identity.?;
        const before = @intFromPtr(object.gcHeader());
        if (minor) {
            _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
        } else {
            _ = try rt.collectForTest();
        }
        const moved = try root.get(rt);
        try std.testing.expect(@intFromPtr(moved.cycleMarkHeader().?) != before);
        try std.testing.expectEqual(moved.bits, weak.get().bits);
        try std.testing.expectEqual(identity, weak.slot.?.identity.?);
        try std.testing.expectEqual(identity, try rt.registerWeakObjectIdentity(core.Object.fromHeader(moved.cycleMarkHeader().?)));
        try std.testing.expect(!rt.weak.object_ids.contains(before));
        try root.set(rt, core.JSValue.undefinedValue());
        _ = try rt.collectForTest();
        try std.testing.expect(!weak.isAlive());
        try std.testing.expect(weak.get().is(.undefined_value));
        try std.testing.expectEqual(@as(usize, 0), rt.weak.object_ids.count());
        try std.testing.expectEqual(@as(usize, 0), rt.weak.id_objects.count());
    }
}

test "weak handle callbacks run after the collection and may release handles" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const Probe = struct {
        handles: [4]core.runtime.WeakPersistentValue = .{ .{}, .{}, .{}, .{} },
        fired: [4]usize = .{ 0, 0, 0, 0 },
        collecting_seen: bool = false,
        allocated: bool = false,
    };
    const Callback = struct {
        var probe: Probe = .{};

        fn cleared(runtime: *core.JSRuntime, context: ?*anyopaque) void {
            const index = @intFromPtr(context.?) - 1;
            probe.fired[index] += 1;
            if (runtime.gc.isBusy() or runtime.roots.isTracing()) probe.collecting_seen = true;
            // Release its own handle and, from the first callback, the handle
            // whose callback is still queued: that callback must not run.
            probe.handles[index].deinit();
            const other = index ^ 1;
            probe.handles[other].deinit();
            // Allocation may start another collection; it must not nest.
            if (core.Object.createPlainObject(runtime, null)) |_| {
                probe.allocated = true;
            } else |_| {}
            helpers.gc.reclaimNow(runtime);
        }
    };
    Callback.probe = .{};
    for (&Callback.probe.handles, 0..) |*handle, index| {
        const object = try core.Object.createPlainObject(rt, null);
        handle.* = try core.runtime.WeakPersistentValue.init(rt, object.value(), Callback.cleared, @ptrFromInt(index + 1));
    }
    _ = try rt.collectForTest();
    const probe = &Callback.probe;
    try std.testing.expect(!probe.collecting_seen);
    try std.testing.expect(probe.allocated);
    // Each pair fires exactly one callback; its partner is cancelled.
    try std.testing.expectEqual(@as(usize, 1), probe.fired[0] + probe.fired[1]);
    try std.testing.expectEqual(@as(usize, 1), probe.fired[2] + probe.fired[3]);
    try std.testing.expectEqual(@as(usize, 0), rt.roots.weak_root_slots.items.len);
    try std.testing.expectEqual(@as(usize, 0), rt.roots.weak_notify_queue.items.len);
}

test "weak handle callbacks run after a minor-only poll" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    rt.forcePreciseRootScanForTest();
    defer rt.restoreDefaultRootScanForTest();
    rt.setGCThreshold(std.math.maxInt(usize) / 2);
    const Callback = struct {
        var fired: usize = 0;
        fn cleared(_: *core.JSRuntime, _: ?*anyopaque) void {
            fired += 1;
        }
    };
    Callback.fired = 0;
    var weak = try core.runtime.WeakPersistentValue.init(rt, (try core.Object.createPlainObject(rt, null)).value(), Callback.cleared, null);
    defer weak.deinit();
    // Enough young garbage that the safepoint offers a minor.
    for (0..core.gc.minor_young_threshold) |_| _ = try core.Object.createPlainObject(rt, null);
    try std.testing.expect(rt.gc.shouldTryMinor());
    const minors = rt.gc.generation.stats.minor_collections;
    _ = try rt.pollGC(.safepoint);
    try std.testing.expect(rt.gc.generation.stats.minor_collections > minors);
    try std.testing.expect(!weak.isAlive());
    try std.testing.expectEqual(@as(usize, 1), Callback.fired);
    try std.testing.expectEqual(@as(usize, 0), rt.roots.weak_notify_queue.items.len);
}

test "nursery ephemeron values repair their actual table slots" {
    for ([_]bool{ false, true }) |strong_value| {
        const rt = try core.JSRuntime.create(std.testing.allocator, .{});
        defer rt.destroy();
        rt.gc.nursery.enabled = true;
        var roots = core.runtime.ExactValueRoots(3){};
        try roots.activate(rt);
        defer roots.deactivate();
        const table_root = try roots.ref(0);
        const key_root = try roots.ref(1);
        const value_root = try roots.ref(2);
        const table = try core.Object.create(rt, core.class.ids.weakmap, null);
        try table_root.set(rt, table.value());
        try key_root.set(rt, (try core.Object.createPlainObject(rt, null)).value());
        try value_root.set(rt, (try core.Object.createPlainObject(rt, null)).value());
        const before = (try value_root.get(rt)).bits;
        try engine.exec.collection_ops.setWeakMapEntry(rt, table, try key_root.get(rt), try value_root.get(rt));
        if (!strong_value) try value_root.set(rt, core.JSValue.undefinedValue());
        _ = try rt.collectForTest();
        const stored = table.weakCollectionEntries()[0].value;
        try std.testing.expect(stored.bits != before);
        try std.testing.expect(rt.gc.containsHeader(stored.cycleMarkHeader().?));
        if (strong_value) try std.testing.expectEqual((try value_root.get(rt)).bits, stored.bits);
        try key_root.set(rt, core.JSValue.undefinedValue());
        try value_root.set(rt, core.JSValue.undefinedValue());
        _ = try rt.collectForTest();
        try std.testing.expectEqual(@as(usize, 0), table.weakCollectionEntries().len);
        try std.testing.expect(!rt.gc.containsHeader(stored.cycleMarkHeader().?));
    }
}

test "nursery evacuation keeps Map object keys findable through the hash index" {
    for ([_]bool{ false, true }) |minor| {
        const rt = try core.JSRuntime.create(std.testing.allocator, .{});
        defer rt.destroy();
        rt.gc.nursery.enabled = true;
        const key_count = 9;
        // keys[key_count] is the Map itself; it is not nursery-allocated.
        var values = [_]core.JSValue{core.JSValue.undefinedValue()} ** (key_count + 1);
        const live: []core.JSValue = &values;
        const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &live }};
        var frame = core.runtime.ValueRootFrame{ .slices = &slices };
        frame.activate(rt);
        defer frame.deactivate(rt);
        const map = try core.Object.create(rt, core.class.ids.map, null);
        values[key_count] = map.value();
        try std.testing.expect(!core.gc.Registry.isNurseryHeader(map.gcHeader()));
        var before: [key_count]u64 = undefined;
        for (0..key_count) |i| {
            values[i] = (try core.Object.createPlainObject(rt, null)).value();
            before[i] = values[i].bits;
            try core.collection.appendStrongEntryOwned(rt, map, .{ .key = values[i], .value = core.JSValue.int32(@intCast(i)) });
        }
        try std.testing.expect(map.collectionBucketHeads().len != 0);
        if (minor) {
            _ = try core.gc_trace_stw.collectMinor(rt, .declared_only);
        } else {
            _ = try rt.collectForTest();
        }
        for (0..key_count) |i| {
            try std.testing.expect(values[i].bits != before[i]);
            const index = core.collection.findStrongEntry(map, values[i]) orelse return error.TestUnexpectedResult;
            try std.testing.expect(map.collectionEntries()[index].value.same(core.JSValue.int32(@intCast(i))));
        }
        // Removal and re-insertion of a moved key keep one entry per key.
        core.collection.removeStrongEntry(rt, map, core.collection.findStrongEntry(map, values[0]).?);
        try std.testing.expect(core.collection.findStrongEntry(map, values[0]) == null);
        try core.collection.appendStrongEntryOwned(rt, map, .{ .key = values[0], .value = core.JSValue.int32(99) });
        try std.testing.expectEqual(@as(usize, key_count), core.collection.strongSize(map));
    }
}

test "exact value roots lifecycle guards" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var outer = core.runtime.ExactValueRoots(1){};
    try outer.activate(rt);
    defer outer.deactivate();
    var inner = core.runtime.ExactValueRoots(1){};
    try inner.activate(rt);
    defer inner.deactivate();
    // One diagnostic binary, selected failure sites; invoke through zig build
    // test and verify the exact guard text, not merely an abnormal exit.
    if (std.c.getenv("ZJS_EXACT_ROOT_INJECT")) |raw| {
        const mode = std.mem.span(raw);
        if (std.mem.eql(u8, mode, "1")) outer.deactivate();
        if (std.mem.eql(u8, mode, "2")) rt.destroy();
        if (std.mem.eql(u8, mode, "3")) {
            rt.gc.hot.collecting = true;
            inner.deactivate();
        }
    }
}

test "runtime teardown owns a detached generator shell" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    _ = try core.Object.createGeneratorShell(rt, core.class.ids.generator);
    rt.destroy();
}
