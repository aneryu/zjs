//! Core integration tests: runtime_lifecycle.
const std = @import("std");
const zjs = @import("zjs");
const core = zjs.core;

/// First allocation of a `JSRuntime` body comes from a prefilled buffer so
/// `create` can be shown to land on that address. Every other request uses
/// the testing allocator. The body itself is not owned by that allocator.
const PrefilledRuntimeAllocator = struct {
    body: []align(@alignOf(core.JSRuntime)) u8,
    child: std.mem.Allocator,
    served_body: bool = false,

    fn allocator(self: *PrefilledRuntimeAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PrefilledRuntimeAllocator = @ptrCast(@alignCast(ctx));
        if (!self.served_body and len == self.body.len and alignment.toByteUnits() <= @alignOf(core.JSRuntime)) {
            self.served_body = true;
            return self.body.ptr;
        }
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PrefilledRuntimeAllocator = @ptrCast(@alignCast(ctx));
        if (memory.ptr == self.body.ptr) return new_len <= self.body.len;
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *PrefilledRuntimeAllocator = @ptrCast(@alignCast(ctx));
        if (memory.ptr == self.body.ptr) return null;
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PrefilledRuntimeAllocator = @ptrCast(@alignCast(ctx));
        if (memory.ptr == self.body.ptr) return;
        self.child.rawFree(memory, alignment, ret_addr);
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

fn expectUnsetCompletionWait(rt: *core.JSRuntime) !void {
    const io = std.testing.io;
    const past = std.Io.Timestamp.now(io, .awake).subDuration(.{ .nanoseconds = std.time.ns_per_s });
    try std.testing.expect(!rt.host_wait.completion.isSet());
    try std.testing.expect(!rt.host_wait.waitUntil(io, past));
}

test "runtime init clears a prefilled host completion event" {
    var storage: [@sizeOf(core.JSRuntime)]u8 align(@alignOf(core.JSRuntime)) = undefined;
    @memset(std.mem.bytesAsSlice(u32, &storage), @intFromEnum(std.Io.Event.is_set));
    var prefilled = PrefilledRuntimeAllocator{
        .body = &storage,
        .child = std.testing.allocator,
    };
    const created = try core.JSRuntime.create(prefilled.allocator(), .{});
    defer created.destroy();
    try std.testing.expectEqual(@intFromPtr(&storage), @intFromPtr(created));
    try std.testing.expect(prefilled.served_body);
    try expectUnsetCompletionWait(created);

    created.host_wait.completion = .is_set;
    try std.testing.expect(created.host_wait.completion.isSet());
    created.host_wait.reset();
    try expectUnsetCompletionWait(created);
}

test "runtime create initializes defaults and options on prefilled storage" {
    const Interrupt = struct {
        fn run(_: *core.JSRuntime, context: ?*anyopaque) bool {
            const called: *bool = @ptrCast(@alignCast(context.?));
            called.* = true;
            return false;
        }
    };
    for ([_]usize{ 0, 64 * 1024 }) |native_stack_size| {
        var storage: [@sizeOf(core.JSRuntime)]u8 align(@alignOf(core.JSRuntime)) = undefined;
        @memset(&storage, 0xa5);
        var prefilled = PrefilledRuntimeAllocator{ .body = &storage, .child = std.testing.allocator };
        var interrupted = false;
        const rt = try core.JSRuntime.create(prefilled.allocator(), .{
            .microtask_policy = .explicit,
            .memory_limit = 16 * 1024 * 1024,
            .gc_threshold = 512 * 1024,
            .stack_size = 128 * 1024,
            .native_stack_size = native_stack_size,
            .interrupt_handler = Interrupt.run,
            .interrupt_context = &interrupted,
            .can_block = true,
        });
        defer rt.destroy();
        try std.testing.expectEqual(@intFromPtr(&storage), @intFromPtr(rt));
        try std.testing.expect(rt.isOwnerThread());
        try std.testing.expectEqual(.explicit, rt.microtasks.policy);
        try std.testing.expectEqual(@as(?usize, 16 * 1024 * 1024), rt.gc.heap_budget.limit);
        try std.testing.expectEqual(@as(usize, 512 * 1024), rt.gc.heap_budget.gc_threshold);
        try std.testing.expectEqual(@as(usize, 128 * 1024), rt.stack.limit);
        try std.testing.expectEqual(@as(u62, 128 * 1024), rt.stack.frame_storage.limit);
        try std.testing.expectEqual(.frame_window, rt.stack.frame_storage.ownership);
        try std.testing.expectEqual(native_stack_size, rt.stack.native_size);
        try std.testing.expect(rt.stack.native_top != 0);
        try std.testing.expectEqual(if (native_stack_size == 0) 0 else rt.stack.native_top -| native_stack_size, rt.stack.native_limit);
        try std.testing.expect(rt.host_wait.can_block);
        try std.testing.expect(!rt.interrupt.poll());
        try std.testing.expect(interrupted);

        try std.testing.expect(!rt.interrupt.termination_requested.load(.monotonic));
        try std.testing.expect(rt.exception.value.is(.uninitialized));
        try std.testing.expect(!rt.exception.uncatchable);
        try std.testing.expect(!rt.exception.out_of_memory);
        try std.testing.expectEqual(@as(usize, 1), rt.weak.next_id);
        try std.testing.expectEqual(@as(usize, 0), rt.stack.call_depth);
        try std.testing.expectEqual(@as(usize, 0), rt.vm_stack.chunk_count);
        for (rt.vm_stack.chunks, rt.vm_stack.used) |chunk, used| {
            try std.testing.expectEqual(@as(usize, 0), chunk.len);
            try std.testing.expectEqual(@as(usize, 0), used);
        }
        for (rt.strings.single_byte, rt.strings.percent_hex, rt.strings.small_int) |single, percent, integer| {
            try std.testing.expect(single == null and percent == null and integer == null);
        }
        for (rt.strings.recent_atoms) |entry| try std.testing.expect(entry == null);
        try std.testing.expect(rt.strings.empty == null and rt.strings.recent_two_unit == null);
        try std.testing.expectEqual(@as(u8, 0), rt.strings.recent_atom_next);
        try expectUnsetCompletionWait(rt);
        try std.testing.expect(rt.roots.usingInline());
        try std.testing.expect(rt.job_queue.runtime == rt);
        try expectRuntimeSelfReferences(rt);
    }
}

fn expectRuntimeSelfReferences(rt: *core.JSRuntime) !void {
    try std.testing.expect(rt.atoms.gc_registry == rt.gc);
    try std.testing.expectEqual(rt.owner_thread_id, rt.classes.owner_thread_id);
    try std.testing.expectEqual(@intFromPtr(rt.atoms), @intFromPtr(rt.classes.atoms));
    try std.testing.expect(rt.shapes.atoms == rt.atoms);
    try std.testing.expect(rt.classes.records.ptr == rt.classes.records_inline[0..].ptr);
    try std.testing.expectEqual(@intFromPtr(rt.gc), @intFromPtr(rt.shapes.gc_registry));
    try std.testing.expectEqual(@intFromPtr(rt), @intFromPtr(rt.nativeAllocator().ptr));
    try std.testing.expectEqual(@intFromPtr(rt), @intFromPtr(rt.gc.runtime.?));
    try std.testing.expectEqual(@intFromPtr(&rt.gc.cell_storage), @intFromPtr(&rt.gc.runtime.?.gc.cell_storage));
    try std.testing.expectEqual(@intFromPtr(&rt.gc.block_heap), @intFromPtr(rt.gc.cell_storage.block_heap.?));
    try std.testing.expectEqual(@intFromPtr(&rt.gc.nursery), @intFromPtr(rt.gc.cell_storage.nursery.?));
    const native_bytes = try rt.allocNative(u8, 24);
    defer rt.freeNative(u8, native_bytes);
    try std.testing.expectEqual(@intFromPtr(&rt.gc.cell_storage), @intFromPtr(&rt.gc.runtime.?.gc.cell_storage));
    try std.testing.expectEqual(@intFromPtr(&rt.gc.block_heap), @intFromPtr(rt.gc.address_registry.block_heap.?));
    try std.testing.expect(rt.gc.nonblock_objects != null);
    try std.testing.expect(rt.gc.cell_storage.slab.arena_observer != null);
}

test "runtime collector construction owns rollback and defers allocation callbacks" {
    // Creation and destruction work without even allocating a Runtime.
    const baseline = core.gc.Registry.nonblock_authorities_live_for_test;
    const options: core.gc.Registry.Options = .{
        .policy = .{},
        .threshold = 12345,
        .memory_limit = 1024 * 1024,
    };
    defer core.gc.Registry.fail_nonblock_authority_for_test = false;
    core.gc.Registry.fail_nonblock_authority_for_test = true;
    try std.testing.expectError(error.OutOfMemory, core.gc.Registry.create(std.testing.allocator, options));
    try std.testing.expectEqual(baseline, core.gc.Registry.nonblock_authorities_live_for_test);

    const collector = try core.gc.Registry.create(std.testing.allocator, options);
    defer collector.destroy();
    try std.testing.expect(collector.runtime == null);
    try std.testing.expectEqual(baseline + 1, core.gc.Registry.nonblock_authorities_live_for_test);
    try std.testing.expectEqual(options.threshold, collector.heap_budget.gc_threshold);
    try std.testing.expectEqual(options.memory_limit, collector.heap_budget.limit);
    try std.testing.expect(!collector.cell_storage.slab_enabled);
    try std.testing.expect(collector.cell_storage.block_heap == &collector.block_heap);
    try std.testing.expect(collector.cell_storage.nursery == &collector.nursery);
    try std.testing.expectEqual(@intFromPtr(collector), @intFromPtr(collector.cell_storage.slab.arena_observer.?.ctx));
}

test "runtime root set inline providers survive value relocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const Probe = struct {
        fn trace(_: *anyopaque, _: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {}
    };
    var context: usize = 0;
    const provider: core.runtime.RootProvider = .{ .context = &context, .trace = Probe.trace };
    var original: core.runtime.RootSet = .{};
    try std.testing.expect(original.usingInline());
    try std.testing.expectEqual(@as(usize, 0), original.providers().len);
    try original.register(rt, provider);
    var moved = original;
    original = .{};
    try std.testing.expect(moved.providers().ptr == moved.root_providers_inline[0..].ptr);
    try std.testing.expectEqual(provider.context, moved.providers()[0].context);
    moved.unregister(rt, provider);
    try std.testing.expect(moved.usingInline());
    try std.testing.expectEqual(@as(usize, 0), moved.providers().len);
}

test "runtime subsystem allocators preserve probes and accounting" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const Probe = struct {
        fn observe(context: ?*anyopaque, _: usize) void {
            const calls: *usize = @ptrCast(@alignCast(context.?));
            calls.* += 1;
        }
    };
    var calls: usize = 0;
    const budget = &rt.gc.heap_budget;
    const saved_probe = budget.installProbe(.{ .run = Probe.observe, .context = &calls });
    defer budget.restoreProbe(saved_probe);
    const baseline = rt.allocation_diagnostics.allocated_bytes;
    const direct = try rt.allocNative(u8, 37);
    const direct_charge = rt.allocation_diagnostics.allocated_bytes - baseline;
    rt.freeNative(u8, direct);
    try std.testing.expectEqual(@as(usize, 1), calls);

    const storage = rt.atoms.storage_allocator;
    const indirect = try storage.alloc(u8, 37);
    const indirect_charge = rt.allocation_diagnostics.allocated_bytes - baseline;
    storage.free(indirect);
    try std.testing.expectEqual(@as(usize, 2), calls);
    try std.testing.expectEqual(direct_charge, indirect_charge);
    try std.testing.expectEqual(baseline, rt.allocation_diagnostics.allocated_bytes);

    const native = rt.atoms.native_allocator;
    const unprobed = try native.alloc(u8, 37);
    native.free(unprobed);
    try std.testing.expectEqual(@as(usize, 2), calls);
    try std.testing.expectEqual(baseline, rt.allocation_diagnostics.allocated_bytes);
}

test "runtime subsystems create without a Runtime and keep stable dependencies" {
    const gc = try core.gc.Registry.create(std.testing.allocator, .{
        .policy = .{},
        .threshold = 12345,
        .memory_limit = null,
    });
    defer gc.destroy();
    const atoms = try core.atom.AtomTable.create(std.testing.allocator, .{
        .storage_allocator = std.testing.allocator,
        .native_allocator = std.testing.allocator,
        .gc_registry = gc,
    });
    defer atoms.destroy();
    const classes = try core.class.Table.create(std.testing.allocator, std.testing.allocator, atoms);
    defer classes.destroy();
    const shapes = try core.shape.Registry.create(std.testing.allocator, std.testing.allocator, atoms, gc);
    defer shapes.destroy();

    const name = try atoms.internString("independent-subsystem-name");
    try std.testing.expectEqualStrings("independent-subsystem-name", atoms.name(name).?);
    try std.testing.expect(atoms.gc_registry == gc);
    try std.testing.expect(classes.atoms == atoms and shapes.atoms == atoms);
    try std.testing.expect(shapes.gc_registry == gc);
    try std.testing.expect(classes.records.ptr == classes.records_inline[0..].ptr);
    try std.testing.expect(classes.registration_states.ptr == classes.registration_states_inline[0..].ptr);
    try std.testing.expect(classes.records[core.class.ids.object].isRegistered());
}

test "runtime subsystem allocation failures release all earlier owners" {
    const Probe = struct {
        fn createAndDestroy(allocator: std.mem.Allocator) !void {
            const baseline = core.gc.Registry.nonblock_authorities_live_for_test;
            const rt = core.JSRuntime.create(allocator, .{}) catch |err| {
                try std.testing.expectEqual(baseline, core.gc.Registry.nonblock_authorities_live_for_test);
                return err;
            };
            rt.destroy();
            try std.testing.expectEqual(baseline, core.gc.Registry.nonblock_authorities_live_for_test);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.createAndDestroy, .{});
}

test "runtime creation recovers after collector failure and keeps self references" {
    defer core.gc.Registry.fail_nonblock_authority_for_test = false;
    const baseline = core.gc.Registry.nonblock_authorities_live_for_test;

    core.gc.Registry.fail_nonblock_authority_for_test = true;
    try std.testing.expectError(error.OutOfMemory, core.JSRuntime.create(std.testing.allocator, .{}));
    try std.testing.expectEqual(baseline, core.gc.Registry.nonblock_authorities_live_for_test);

    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    errdefer rt.destroy();
    const other = try core.JSRuntime.create(std.testing.allocator, .{});
    errdefer other.destroy();
    try std.testing.expectEqual(baseline + 2, core.gc.Registry.nonblock_authorities_live_for_test);
    try expectRuntimeSelfReferences(rt);
    try expectRuntimeSelfReferences(other);
    other.destroy();
    rt.destroy();
    try std.testing.expectEqual(baseline, core.gc.Registry.nonblock_authorities_live_for_test);
}

test "runtime tryDestroy rejects a non-owner thread" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const Probe = struct {
        var failed: ?anyerror = null;

        fn run(runtime: *core.JSRuntime) void {
            runtime.tryDestroy() catch |err| {
                failed = err;
                return;
            };
            failed = error.UnexpectedSuccess;
        }
    };
    Probe.failed = null;
    const thread = try std.Thread.spawn(.{}, Probe.run, .{rt});
    thread.join();
    try std.testing.expectEqual(error.WrongRuntimeThread, Probe.failed.?);
}

test "runtime local native bindings reject foreign owners and keep definitions until teardown" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const other = try core.JSRuntime.create(std.testing.allocator, .{});
    defer other.destroy();
    const next_id = rt.classes.next_dynamic_id;
    try std.testing.expectError(error.WrongRuntime, rt.classes.registerDefinition(other, .{ .class_name = "Foreign" }));
    try std.testing.expectEqual(next_id, rt.classes.next_dynamic_id);
    const a = try core.native_object.registerType(rt, "Owned", null);
    const b = try core.native_object.registerType(other, "Foreign", null);
    try std.testing.expectEqual(a.class_id, b.class_id);
    var payload: usize = 42;
    try std.testing.expectError(error.WrongRuntime, core.native_object.create(other, a, null, &payload));
    const foreign_proto = try core.Object.create(other, core.class.ids.object, null);
    try std.testing.expectError(error.WrongRuntime, core.native_object.create(rt, a, foreign_proto, &payload));
    const obj = try core.native_object.create(rt, a, null, &payload);
    const val = core.JSValue.object(obj.gcHeader());
    try std.testing.expectEqual(@as(?*anyopaque, &payload), core.native_object.unwrap(rt, val, a));
    try std.testing.expectEqual(@as(?*anyopaque, null), core.native_object.unwrap(other, val, b));
    try std.testing.expectEqual(@as(?*anyopaque, null), core.native_object.unwrap(rt, val, b));
    try std.testing.expectEqual(@as(?*anyopaque, null), core.native_object.unwrap(rt, core.JSValue.undefinedValue(), a));
    _ = obj.takeNativeSelf();
    try std.testing.expectEqual(@as(?*anyopaque, null), core.native_object.unwrap(rt, val, a));
    rt.forcePreciseRootScanForTest();
    _ = try rt.forceGC(null);
    try std.testing.expectEqual(a, core.native_object.NativeType.fromRecord(rt, a.class_id).?);
    const next = try rt.registerClass(.{ .class_name = "Next" });
    try std.testing.expect(next.id > a.class_id);
    rt.classes.next_dynamic_id = std.math.maxInt(core.ClassId);
    const last = try rt.registerClass(.{ .class_name = "Last" });
    try std.testing.expectEqual(std.math.maxInt(core.ClassId), last.id);
    try std.testing.expectError(error.ClassIdExhausted, rt.registerClass(.{ .class_name = "Overflow" }));
}

test "context bootstrap names its realm and rejects another realms global" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const first = try core.JSContext.create(rt, .{});
    defer first.destroy();
    const second = try core.JSContext.create(rt, .{});
    defer second.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    try second.installStandardGlobals(global);
    try std.testing.expect(first.global == null);
    try std.testing.expectEqual(global, second.global.?);
    try std.testing.expectError(error.InvalidBuiltinRegistry, first.installStandardGlobals(global));
    try std.testing.expect(first.global == null);
    const second_global = try first.globalObject();
    try std.testing.expect(second_global != global);
    try std.testing.expectEqual(first, rt.contexts.forGlobal(second_global, .include_constructing).?);
}

test "runtime termination crosses threads and idle recovery permits new execution" {
    const rt = try zjs.Runtime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const Request = struct {
        fired: bool = false,
        failed: bool = false,
        fn worker(runtime: *core.JSRuntime) void {
            runtime.terminateExecution();
        }
        fn poll(runtime: *core.JSRuntime, opaque_state: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(opaque_state.?));
            if (self.fired) return self.failed;
            self.fired = true;
            const thread = std.Thread.spawn(.{}, worker, .{runtime}) catch {
                self.failed = true;
                return true;
            };
            thread.join();
            return false; // A subsequent engine poll must observe the atomic request.
        }
    };
    var state = Request{};
    rt.setInterruptHandler(Request.poll, &state);
    try std.testing.expectError(error.Interrupted, ctx.eval("while (true) {}", .{}));
    try std.testing.expect(state.fired and !state.failed);
    try std.testing.expect(rt.isExecutionTerminating());
    rt.setInterruptHandler(null, null);
    try rt.cancelTerminateExecution();
    _ = ctx.takeException();
    try std.testing.expect(!rt.isExecutionTerminating());
    const value = try ctx.eval("21 * 2", .{});
    try std.testing.expectEqual(@as(?i32, 42), value.as(.int));
    rt.terminateExecution();
    try std.testing.expect(rt.isExecutionTerminating());
    try std.testing.expectError(error.Interrupted, ctx.eval("1 + 1", .{}));
    _ = ctx.takeException();
    rt.stack.call_depth = 1;
    try std.testing.expectError(error.RuntimeBusy, rt.cancelTerminateExecution());
    rt.stack.call_depth = 0;
    try rt.cancelTerminateExecution();
}

test "class registration reserves ids across allocation reentry and failure" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const Probe = struct {
        rt: *core.JSRuntime,
        first: ?core.class.Binding = null,
        last: ?core.class.Binding = null,
        failure: ?anyerror = null,
        fn allocate(raw: ?*anyopaque, _: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.rt.gc.heap_budget.restoreProbe(null);
            for (0..200) |_| {
                const binding = self.rt.registerClass(.{ .class_name = "Nested" }) catch |err| {
                    self.failure = err;
                    return;
                };
                if (self.first == null) self.first = binding;
                self.last = binding;
            }
        }
    };
    var probe = Probe{ .rt = rt };
    _ = rt.gc.heap_budget.installProbe(.{ .run = Probe.allocate, .context = &probe });
    defer rt.gc.heap_budget.restoreProbe(null);
    const outer = try rt.registerClass(.{ .class_name = "Outer" });
    try std.testing.expect(probe.failure == null);
    try std.testing.expect(probe.first != null and probe.last != null);
    try std.testing.expect(outer.id < probe.first.?.id);
    try std.testing.expect(rt.classes.isRegistered(outer.id));
    try std.testing.expect(rt.classes.isRegistered(probe.first.?.id));
    try std.testing.expect(rt.classes.isRegistered(probe.last.?.id));
    const failed_id: core.ClassId = @intCast(rt.classes.next_dynamic_id);
    rt.setNativeBytesLimitForTest(0);
    try std.testing.expectError(error.OutOfMemory, rt.registerClass(.{ .class_name = "UnpublishedAfterAllocationFailure" }));
    rt.setNativeBytesLimitForTest(null);
    try std.testing.expect(!rt.classes.isRegistered(failed_id));
    const after = try rt.registerClass(.{ .class_name = "AfterFailure" });
    try std.testing.expect(after.id > failed_id);
}

test "native type definition remains available while teardown finalizes its instances" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    const State = struct {
        rt: *core.JSRuntime,
        id: core.ClassId = 0,
        calls: usize = 0,
        definition_visible: bool = false,
        fn finish(ptr: *anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            self.definition_visible = self.rt.classes.isRegistered(self.id);
        }
    };
    var state = State{ .rt = rt };
    {
        errdefer rt.destroy();
        const binding = try core.native_object.registerType(rt, "TeardownOwner", State.finish);
        state.id = binding.class_id;
        _ = try core.native_object.create(rt, binding, null, &state);
    }
    rt.destroy();
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expect(state.definition_visible);
}

test "context bootstrap allocation failure leaves other realms untouched and can retry" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const first = try core.JSContext.create(rt, .{});
    defer first.destroy();
    const second = try core.JSContext.create(rt, .{});
    defer second.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    var held: ?*core.Object = global;
    var roots = core.runtime.rootObjects(.{&held});
    roots.activate(rt);
    defer roots.deactivate(rt);
    rt.setNativeBytesLimitForTest(0);
    try std.testing.expectError(error.OutOfMemory, second.installStandardGlobals(global));
    rt.setNativeBytesLimitForTest(null);
    try std.testing.expect(first.global == null);
    try std.testing.expect(second.global == null);
    try second.installStandardGlobals(global);
    try std.testing.expect(first.global == null);
    try std.testing.expectEqual(global, second.global.?);
}
