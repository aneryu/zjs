const std = @import("std");
const builtin = @import("builtin");
const zjs = @import("zjs");
const engine = zjs;

const core = zjs.core;

extern "c" fn tmpfile() ?*std.c.FILE;

const ModuleAutoInitFixture = struct {
    owner: core.property.AutoInitModuleOwner = .{ .resolve = resolve },
    expected_realm: *core.gc.Header,
    expected_atom: ?core.Atom = null,
    calls: usize = 0,
    failed_once: bool = false,
    result: Result,

    const Result = union(enum) {
        value: core.JSValue,
        var_ref: *core.VarRef,
        fail_once: core.JSValue,
        reenter: struct {
            rt: *core.JSRuntime,
            holder: *core.Object,
            atom_id: core.Atom,
            replacement: core.JSValue,
            materialized: core.JSValue,
        },
    };

    fn resolve(
        owner: *const core.property.AutoInitModuleOwner,
        realm_header: *core.gc.Header,
        atom_id: core.Atom,
    ) anyerror!core.property.AutoInitMaterialization {
        const self: *ModuleAutoInitFixture = @constCast(@fieldParentPtr("owner", owner));
        if (realm_header != self.expected_realm) return error.InvalidBuiltinRegistry;
        if (self.expected_atom) |expected| {
            if (atom_id != expected) return error.InvalidBuiltinRegistry;
        }
        self.calls += 1;
        return switch (self.result) {
            .value => |value| .{ .value = value.dup() },
            .var_ref => |cell| .{ .var_ref = cell },
            .fail_once => |value| blk: {
                if (!self.failed_once) {
                    self.failed_once = true;
                    return error.OutOfMemory;
                }
                break :blk .{ .value = value.dup() };
            },
            .reenter => |entry| blk: {
                try entry.holder.setProperty(entry.rt, entry.atom_id, entry.replacement);
                break :blk .{ .value = entry.materialized.dup() };
            },
        };
    }
};

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
    var pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer pending.deinit(rt);
    return publishFreshModule(registry, module_name, &pending);
}

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

test "every JSValue constructor recovers its QuickJS semantic tag" {
    var header: core.gc.Header = undefined;
    var string_header: core.gc.StringHeader = undefined;
    var object_header: core.gc.GCObjectHeader = undefined;

    const cases = [_]struct { value: core.JSValue, tag: i32 }{
        .{ .value = core.JSValue.bigInt(&header), .tag = core.Tag.big_int },
        .{ .value = core.JSValue.symbol(&string_header), .tag = core.Tag.symbol },
        .{ .value = core.JSValue.string(&string_header), .tag = core.Tag.string },
        .{ .value = core.JSValue.stringRope(&string_header), .tag = core.Tag.string_rope },
        .{ .value = core.JSValue.module(&header), .tag = core.Tag.module },
        .{ .value = core.JSValue.functionBytecode(&object_header), .tag = core.Tag.function_bytecode },
        .{ .value = core.JSValue.object(&header), .tag = core.Tag.object },
        .{ .value = core.JSValue.int32(-42), .tag = core.Tag.int },
        .{ .value = core.JSValue.boolean(true), .tag = core.Tag.boolean },
        .{ .value = core.JSValue.nullValue(), .tag = core.Tag.null_value },
        .{ .value = core.JSValue.undefinedValue(), .tag = core.Tag.undefined_value },
        .{ .value = core.JSValue.uninitialized(), .tag = core.Tag.uninitialized },
        .{ .value = core.JSValue.catchOffset(-7), .tag = core.Tag.catch_offset },
        .{ .value = core.JSValue.exception(), .tag = core.Tag.exception },
        .{ .value = core.JSValue.shortBigInt(-123), .tag = core.Tag.short_big_int },
        .{ .value = core.JSValue.float64(-1.5), .tag = core.Tag.float64 },
    };

    for (cases) |case| try std.testing.expectEqual(case.tag, case.value.tagOf());
}

test "refcounted JSValue payloads keep rc at the QuickJS minus-four offset" {
    const RawWideValue = extern struct {
        payload: u64,
        tag: i64,
    };
    const pointerPayload = struct {
        fn get(value: core.JSValue) usize {
            if (@sizeOf(core.JSValue) == @sizeOf(u64)) {
                const bits: u64 = @bitCast(value);
                return @intCast(bits & 0x0000_FFFF_FFFF_FFFF);
            }
            const raw: RawWideValue = @bitCast(value);
            return @intCast(raw.payload);
        }
    }.get;

    var gc_storage: [@sizeOf(core.gc.Metadata) + @sizeOf(core.gc.Header)]u8 align(@alignOf(core.gc.Header)) = undefined;
    const gc_meta: *core.gc.Metadata = @ptrCast(@alignCast(&gc_storage));
    const gc_header: *core.gc.Header = @ptrCast(@alignCast(&gc_storage[@sizeOf(core.gc.Metadata)]));
    gc_meta.* = .{};
    gc_header.* = .{};

    var flat_storage: [core.gc.string_rc_prefix_size + @sizeOf(core.string.String)]u8 align(@alignOf(core.string.String)) = undefined;
    const flat_rc: *core.gc.StringHeader = @ptrCast(@alignCast(&flat_storage));
    const flat_body: *core.string.String = @ptrCast(@alignCast(&flat_storage[core.gc.string_rc_prefix_size]));
    flat_rc.* = .{};

    var rope_storage: [core.string.StringRope.rc_prefix_size + @sizeOf(core.string.StringRope)]u8 align(@alignOf(core.string.StringRope)) = undefined;
    const rope_body: *core.string.StringRope = @ptrCast(@alignCast(&rope_storage[core.string.StringRope.rc_prefix_size]));
    const rope_rc = rope_body.header();
    rope_rc.* = .{};

    const cases = [_]struct {
        value: core.JSValue,
        body_address: usize,
        rc_address: usize,
    }{
        .{ .value = core.JSValue.bigInt(gc_header), .body_address = @intFromPtr(gc_header), .rc_address = @intFromPtr(&gc_meta.rc) },
        .{ .value = core.JSValue.symbol(flat_rc), .body_address = @intFromPtr(flat_body), .rc_address = @intFromPtr(flat_rc) },
        .{ .value = core.JSValue.string(flat_rc), .body_address = @intFromPtr(flat_body), .rc_address = @intFromPtr(flat_rc) },
        .{ .value = core.JSValue.stringRope(rope_rc), .body_address = @intFromPtr(rope_body), .rc_address = @intFromPtr(rope_rc) },
        .{ .value = core.JSValue.module(gc_header), .body_address = @intFromPtr(gc_header), .rc_address = @intFromPtr(&gc_meta.rc) },
        .{ .value = core.JSValue.functionBytecode(gc_header), .body_address = @intFromPtr(gc_header), .rc_address = @intFromPtr(&gc_meta.rc) },
        .{ .value = core.JSValue.object(gc_header), .body_address = @intFromPtr(gc_header), .rc_address = @intFromPtr(&gc_meta.rc) },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.body_address, pointerPayload(case.value));
        try std.testing.expectEqual(case.rc_address + @sizeOf(core.gc.StringHeader), pointerPayload(case.value));
    }
}

test "proven object release preserves generic JSValue ownership semantics" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const baseline_objects = rt.gc.liveCount();
    const object = try core.Object.create(rt, core.class.ids.object, null);
    const value = object.value();
    const retained = value.dup();
    try std.testing.expectEqual(@as(i32, 2), object.header.meta().rc);

    retained.freeObjectAssumeObject(rt);
    try std.testing.expectEqual(@as(i32, 1), object.header.meta().rc);
    value.freeObjectAssumeObject(rt);
    try std.testing.expectEqual(baseline_objects, rt.gc.liveCount());
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

test "int32 same-tag update preserves the value representation invariant" {
    var value = core.JSValue.int32(-1);
    value.setInt32AssumeInt(1234567);

    try std.testing.expectEqual(core.Tag.int, value.tagOf());
    try std.testing.expectEqual(@as(?i32, 1234567), value.asInt32());
}

test "int32 slot move selects only the representation where it removes an aggregate copy" {
    var destination = core.JSValue.int32(11);
    const source = core.JSValue.int32(22);
    const optimized = destination.trySetInt32FromSlot(&source);

    if (core.value.nan_boxing) {
        try std.testing.expect(!optimized);
        try std.testing.expectEqual(@as(?i32, 11), destination.asInt32());
    } else {
        try std.testing.expect(optimized);
        try std.testing.expectEqual(@as(?i32, 22), destination.asInt32());
    }

    var non_int = core.JSValue.boolean(false);
    try std.testing.expect(!non_int.trySetInt32FromSlot(&source));
    try std.testing.expectEqual(@as(?bool, false), non_int.asBool());
}

test "float construction is valid across JSValue representations" {
    const finite = core.JSValue.float64(1.5);
    try std.testing.expectEqual(@as(?f64, 1.5), finite.asFloat64());

    const negative_zero = core.JSValue.float64(-0.0);
    const negative_zero_value = negative_zero.asFloat64().?;
    try std.testing.expect(negative_zero_value == 0.0);
    try std.testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), @as(u64, @bitCast(negative_zero_value)));

    const nan_value = core.JSValue.float64(@bitCast(@as(u64, 0x7FF8_0000_0000_0042)));
    try std.testing.expect(std.math.isNan(nan_value.asFloat64().?));
}

test "heap BigInt value uses reserved QuickJS tag" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const big = try core.bigint.BigInt.create(rt, @as(i128, 1) << 90);
    const value = big.valueRef();
    defer value.free(rt);

    try std.testing.expect(value.isBigInt());
    try std.testing.expectEqual(core.gc.RefKind.big_int, value.refHeader().?.meta().kind);
}

test "heap BigInt limbs participate in runtime memory limit and accounting" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var source = try engine.libs.bigint.pow2(std.testing.allocator, 512 * 1024);
    defer source.deinit();
    const limb_bytes = source.limbs.len * @sizeOf(engine.libs.bigint.Limb);
    const baseline = rt.memory.allocated_bytes;

    // Leave room for the wrapper and a small margin, but not the retained limb
    // storage. A raw persistent_allocator clone used to bypass this limit.
    rt.setMemoryLimit(baseline + @sizeOf(core.bigint.BigInt) + 1024);
    defer rt.setMemoryLimit(null);
    if (core.bigint.BigInt.createFromBigInt(rt, source)) |unexpected| {
        unexpected.valueRef().free(rt);
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }

    rt.setMemoryLimit(null);
    const stored = try core.bigint.BigInt.createFromBigInt(rt, source);
    try std.testing.expect(rt.memory.allocated_bytes >= baseline + @sizeOf(core.bigint.BigInt) + limb_bytes);
    stored.valueRef().free(rt);
    try std.testing.expectEqual(baseline, rt.memory.allocated_bytes);
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

test "RealmContext is header-first and RealmRef owns independently of runtime list membership" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(core.RealmContext, "header"));
    try std.testing.expectEqual(@sizeOf(?*core.RealmContext), @sizeOf(core.RealmRef));

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const first = try core.RealmContext.create(rt);
    const second = try core.RealmContext.create(rt);

    try std.testing.expectEqual(core.gc.GcKind.realm_context, first.header.meta().kind);
    try std.testing.expectEqual(first, rt.firstContext().?);

    var owner = core.RealmRef.retain(first);
    first.destroy();
    try std.testing.expectEqual(first, rt.firstContext().?);

    second.destroy();
    try std.testing.expectEqual(first, rt.firstContext().?);

    owner.deinit();
    try std.testing.expect(rt.firstContext() == null);
}

test "RealmContext construction stays unpublished and untraced until the live commit" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.RealmContext.createConstructingWithOptions(rt, .{});
    defer ctx.destroy();

    try std.testing.expectEqual(.constructing, ctx.publicationState());
    try std.testing.expect(rt.firstContext() == null);
    try std.testing.expectEqual(ctx, rt.constructing_context_head.?);
    try std.testing.expectError(error.InvalidBuiltinRegistry, ctx.publishLive());

    const marker = 0x5151;
    ctx.eval_function = core.JSValue.int32(marker);
    const Counter = struct {
        count: usize = 0,

        fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (slot.asInt32() == marker) self.count += 1;
        }

        fn visitObject(_: *anyopaque, _: *?*core.Object) core.runtime.RootTraceError!void {}
    };
    var counter = Counter{};
    var visitor = core.runtime.RootVisitor{
        .context = &counter,
        .visit_value = Counter.visitValue,
        .visit_object = Counter.visitObject,
    };
    try rt.traceActiveRoots(&visitor);
    try std.testing.expectEqual(@as(usize, 0), counter.count);

    try ctx.finishConstruction();
    try std.testing.expectEqual(.live, ctx.publicationState());
    try std.testing.expectEqual(ctx, rt.firstContext().?);
    try std.testing.expect(rt.constructing_context_head == null);
    try rt.traceActiveRoots(&visitor);
    try std.testing.expectEqual(@as(usize, 1), counter.count);
}

test "RealmContext owns the five QuickJS initial layouts as Shapes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.RealmContext.create(rt);
    defer ctx.destroy();

    const object_prototype = try core.Object.create(rt, core.class.ids.object, null);
    defer object_prototype.value().free(rt);
    const array_prototype = try core.Object.createArray(rt, object_prototype);
    defer array_prototype.value().free(rt);
    const regexp_prototype = try core.Object.create(rt, core.class.ids.object, object_prototype);
    defer regexp_prototype.value().free(rt);

    try ctx.initializeInitialShapes(object_prototype, array_prototype, regexp_prototype);
    const initial_shapes = [_]*core.Shape{
        ctx.array_shape.?,
        ctx.arguments_shape.?,
        ctx.mapped_arguments_shape.?,
        ctx.regexp_shape.?,
        ctx.regexp_result_shape.?,
    };
    for (initial_shapes) |initial_shape| {
        try std.testing.expectEqual(core.gc.GcKind.shape, initial_shape.header.meta().kind);
    }
    try std.testing.expectEqual(array_prototype, ctx.array_shape.?.proto.?);
    try std.testing.expectEqual(object_prototype, ctx.arguments_shape.?.proto.?);
    try std.testing.expectEqual(object_prototype, ctx.mapped_arguments_shape.?.proto.?);
    try std.testing.expectEqual(regexp_prototype, ctx.regexp_shape.?.proto.?);
    try std.testing.expectEqual(array_prototype, ctx.regexp_result_shape.?.proto.?);
    try std.testing.expectEqual(@as(u32, 0), ctx.array_shape.?.prop_count);
    try std.testing.expectEqual(@as(u32, 3), ctx.arguments_shape.?.prop_count);
    try std.testing.expectEqual(@as(u32, 3), ctx.mapped_arguments_shape.?.prop_count);
    try std.testing.expectEqual(@as(u32, 1), ctx.regexp_shape.?.prop_count);
    try std.testing.expectEqual(@as(u32, 3), ctx.regexp_result_shape.?.prop_count);

    const array = try core.Object.createArray(rt, array_prototype);
    defer array.value().free(rt);
    try std.testing.expectEqual(ctx.array_shape.?, array.shape_ref);
}

test "Runtime queues retain their originating Realm until owned jobs are released" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.RealmContext.create(rt);

    try rt.job_queue.enqueuePromise(ctx, core.JSValue.int32(11));

    const TestJob = struct {
        fn run(_: *core.JSContext, _: []const core.JSValue) core.JSValue {
            return core.JSValue.undefinedValue();
        }
    };
    try rt.job_queue.enqueueFunc(ctx, TestJob.run, &.{});
    try rt.enqueueFinalizationJobForRealm(ctx, core.JSValue.int32(12), core.JSValue.int32(13));

    ctx.destroy();
    try std.testing.expectEqual(ctx, rt.firstContext().?);

    var promise_job = rt.job_queue.takeFirst().?;
    promise_job.deinit();
    try std.testing.expectEqual(ctx, rt.firstContext().?);
    var generic_job = rt.job_queue.takeFirst().?;
    const generic_result = generic_job.run();
    try std.testing.expect(!generic_result.isException());
    generic_result.free(rt);
    generic_job.deinit();
    try std.testing.expectEqual(ctx, rt.firstContext().?);
    var finalization_job = rt.job_queue.takeFirst().?;
    finalization_job.deinit();
    try std.testing.expect(rt.firstContext() == null);
}

test "caller-owned ClassIdSlot is process-stable while definitions stay per Runtime" {
    var slot: core.class.ClassIdSlot = .{};
    const class_id = try slot.getOrAllocate();
    try std.testing.expectEqual(class_id, try slot.getOrAllocate());

    const first_rt = try core.JSRuntime.create(std.testing.allocator);
    defer first_rt.destroy();
    const second_rt = try core.JSRuntime.create(std.testing.allocator);
    defer second_rt.destroy();

    try first_rt.classes.register(class_id, .{ .class_name = "ProcessStableClassFirstRuntime" });
    try second_rt.classes.register(class_id, .{ .class_name = "ProcessStableClassSecondRuntime" });
    try std.testing.expect(first_rt.classes.isRegistered(class_id));
    try std.testing.expect(second_rt.classes.isRegistered(class_id));
    try std.testing.expectEqual(class_id, try first_rt.newClassId(class_id));
    try std.testing.expectEqual(class_id, try second_rt.newClassId(class_id));

    const first_name = first_rt.classes.className(class_id).?;
    defer first_rt.atoms.free(first_name);
    const second_name = second_rt.classes.className(class_id).?;
    defer second_rt.atoms.free(second_name);
    try std.testing.expectEqualStrings("ProcessStableClassFirstRuntime", first_rt.atoms.name(first_name).?);
    try std.testing.expectEqualStrings("ProcessStableClassSecondRuntime", second_rt.atoms.name(second_name).?);

    const final_class_id = std.math.maxInt(core.ClassId);
    try first_rt.classes.register(final_class_id, .{ .class_name = "FinalLegalClassId" });
    try std.testing.expect(first_rt.classes.isRegistered(final_class_id));
    try std.testing.expectEqual(final_class_id, try first_rt.newClassId(final_class_id));
}

test "Runtime owner thread rejects foreign structural mutation before publication" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const live = try core.RealmContext.create(rt);
    var live_guard = core.RealmRef.retain(live);
    const constructing = try core.RealmContext.createConstructingWithOptions(rt, .{});
    defer constructing.destroy();

    const registered_id: core.ClassId = 1024;
    const foreign_growth_id: core.ClassId = 4096;
    try rt.ensureContextClassPrototypeCapacity(registered_id);
    try rt.classes.register(registered_id, .{ .class_name = "OwnerThreadRegistered" });
    defer rt.classes.unregisterDynamic(registered_id);

    const Attempt = struct {
        rt: *core.JSRuntime,
        live: *core.RealmContext,
        constructing: *core.RealmContext,
        registered_id: core.ClassId,
        growth_id: core.ClassId,
        owner_check_rejected: bool = false,
        context_create_rejected: bool = false,
        context_publish_rejected: bool = false,
        context_destroy_rejected: bool = false,
        context_destroy_succeeded: bool = false,
        class_register_rejected: bool = false,
        class_unregister_rejected: bool = false,
        class_growth_rejected: bool = false,
        gc_rejected: bool = false,
        unexpected_context: ?*core.RealmContext = null,

        fn run(self: *@This()) void {
            self.owner_check_rejected = if (self.rt.requireOwnerThread()) |_| false else |err| err == error.WrongRuntimeThread;
            self.context_create_rejected = if (core.RealmContext.create(self.rt)) |created| blk: {
                self.unexpected_context = created;
                break :blk false;
            } else |err| err == error.WrongRuntimeThread;
            self.context_publish_rejected = if (self.constructing.finishConstructionChecked()) |_| false else |err| err == error.WrongRuntimeThread;
            if (self.live.tryDestroy()) |_| {
                self.context_destroy_succeeded = true;
            } else |err| {
                self.context_destroy_rejected = err == error.WrongRuntimeThread;
            }
            self.class_register_rejected = if (self.rt.classes.register(self.growth_id, .{ .class_name = "ForeignGrowth" })) |_| false else |err| err == error.WrongRuntimeThread;
            self.class_unregister_rejected = if (self.rt.classes.tryUnregisterDynamic(self.registered_id)) |_| false else |err| err == error.WrongRuntimeThread;
            self.class_growth_rejected = if (self.rt.ensureContextClassPrototypeCapacity(self.growth_id)) |_| false else |err| err == error.WrongRuntimeThread;
            self.gc_rejected = if (self.rt.pollGCChecked(null, .urgent)) |_| false else |err| err == error.WrongRuntimeThread;
        }
    };

    var attempt = Attempt{
        .rt = rt,
        .live = live,
        .constructing = constructing,
        .registered_id = registered_id,
        .growth_id = foreign_growth_id,
    };
    defer {
        if (!attempt.context_destroy_succeeded) live.destroy();
        live_guard.deinit();
    }

    const memory_before = rt.memory.allocated_bytes;
    const class_capacity_before = rt.classes.records.len;
    const live_slots_before = live.class_prototypes.len;
    const constructing_slots_before = constructing.class_prototypes.len;
    rt.requestGCForTest();
    const gc_pending_before = rt.gcPendingForTest();

    const thread = try std.Thread.spawn(.{}, Attempt.run, .{&attempt});
    thread.join();
    defer if (attempt.unexpected_context) |created| created.destroy();

    try std.testing.expect(attempt.owner_check_rejected);
    try std.testing.expect(attempt.context_create_rejected);
    try std.testing.expect(attempt.context_publish_rejected);
    try std.testing.expect(attempt.context_destroy_rejected);
    try std.testing.expect(!attempt.context_destroy_succeeded);
    try std.testing.expect(attempt.class_register_rejected);
    try std.testing.expect(attempt.class_unregister_rejected);
    try std.testing.expect(attempt.class_growth_rejected);
    try std.testing.expect(attempt.gc_rejected);
    try std.testing.expect(attempt.unexpected_context == null);

    try std.testing.expectEqual(memory_before, rt.memory.allocated_bytes);
    try std.testing.expectEqual(class_capacity_before, rt.classes.records.len);
    try std.testing.expectEqual(live_slots_before, live.class_prototypes.len);
    try std.testing.expectEqual(constructing_slots_before, constructing.class_prototypes.len);
    try std.testing.expectEqual(gc_pending_before, rt.gcPendingForTest());
    try std.testing.expectEqual(live, rt.firstContext().?);
    try std.testing.expect(rt.classes.isRegistered(registered_id));
    try std.testing.expect(!rt.classes.unregisterPending(registered_id));
    try std.testing.expect(!rt.classes.isRegistered(foreign_growth_id));
    try std.testing.expectError(error.InvalidBuiltinRegistry, constructing.publishLive());
}

test "process-global ClassId allocation is atomic across owner-thread Runtimes" {
    const worker_count = 4;
    const ids_per_worker = 12;
    var shared_slot: core.class.ClassIdSlot = .{};

    const Worker = struct {
        shared_slot: *core.class.ClassIdSlot,
        shared_id: core.ClassId = core.class.invalid_class_id,
        ids: [ids_per_worker]core.ClassId = @splat(core.class.invalid_class_id),
        failed: bool = false,

        fn run(self: *@This()) void {
            const rt = core.JSRuntime.create(std.heap.page_allocator) catch {
                self.failed = true;
                return;
            };
            defer rt.destroy();

            self.shared_id = self.shared_slot.getOrAllocate() catch {
                self.failed = true;
                return;
            };
            for (&self.ids) |*id| {
                id.* = rt.newClassId(core.class.invalid_class_id) catch {
                    self.failed = true;
                    return;
                };
            }
        }
    };

    var workers: [worker_count]Worker = undefined;
    var threads: [worker_count]std.Thread = undefined;
    for (&workers, 0..) |*worker, index| {
        worker.* = .{ .shared_slot = &shared_slot };
        threads[index] = try std.Thread.spawn(.{}, Worker.run, .{worker});
    }
    for (threads) |thread| thread.join();

    const shared_id = workers[0].shared_id;
    try std.testing.expect(shared_id != core.class.invalid_class_id);
    for (workers) |worker| {
        try std.testing.expect(!worker.failed);
        try std.testing.expectEqual(shared_id, worker.shared_id);
    }
    for (workers, 0..) |worker, worker_index| {
        for (worker.ids, 0..) |id, id_index| {
            try std.testing.expect(id != core.class.invalid_class_id);
            try std.testing.expect(id != shared_id);
            for (workers[0..worker_index]) |earlier_worker| {
                for (earlier_worker.ids) |earlier_id| try std.testing.expect(id != earlier_id);
            }
            for (worker.ids[0..id_index]) |earlier_id| try std.testing.expect(id != earlier_id);
        }
    }
}

test "RealmContext participates in cycle collection through typed RealmRef edges" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.RealmContext.create(rt);

    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const realm_record = try core.Object.create(rt, core.class.ids.object, null);
    var realm_owner = core.RealmRef.retain(ctx);
    try realm_record.installOwnedRealmRef(rt, &realm_owner);
    const record_key = try rt.internAtom("realmCycleRecord");
    defer rt.atoms.free(record_key);
    try global.defineOwnProperty(
        rt,
        record_key,
        core.Descriptor.data(realm_record.value(), true, true, true),
    );
    realm_record.value().free(rt);

    ctx.destroy();
    try std.testing.expect(rt.firstContext() != null);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.firstContext() == null);
}

test "FunctionBytecode RealmRef edge participates in realm-global cycle collection" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.RealmContext.create(rt);
    var ctx_alive = true;
    defer if (ctx_alive) ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;

    const code = [_]u8{engine.bytecode.opcode.op.return_undef};
    const fb = try engine.bytecode.FunctionBytecode.createFixture(rt, .{
        .realm = ctx,
        .arg_count = 1,
        .var_count = 1,
        .closure_var_count = 1,
        .cpool_count = 1,
        .byte_code = &code,
        .has_debug = true,
        .has_extension = true,
    });
    const expected_layout = try engine.bytecode.FunctionLayout.init(
        true,
        true,
        1,
        1,
        1,
        1,
        code.len,
    );
    try std.testing.expect(std.meta.eql(expected_layout, fb.layout()));
    try std.testing.expect(fb.famBytes() > @sizeOf(engine.bytecode.function_bytecode.DebugInfo));
    fb.publishFixtureNoFail(rt);
    const fb_value = core.JSValue.functionBytecode(&fb.header);
    var fb_value_alive = true;
    defer if (fb_value_alive) fb_value.free(rt);

    const cycle_key = try rt.internAtom("functionBytecodeRealmCycle");
    defer rt.atoms.free(cycle_key);
    try global.defineOwnProperty(
        rt,
        cycle_key,
        core.Descriptor.data(fb_value, true, true, true),
    );
    fb_value.free(rt);
    fb_value_alive = false;

    // Only the cycle remains: Context -> global -> FB -> RealmRef(Context).
    ctx.destroy();
    ctx_alive = false;
    try std.testing.expect(rt.firstContext() != null);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.firstContext() == null);
}

test "FinalizationRegistry RealmRef edge participates in realm-global cycle collection" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.RealmContext.create(rt);
    var ctx_alive = true;
    defer if (ctx_alive) ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;

    const registry = try core.Object.createFinalizationRegistry(rt, ctx, null);
    try std.testing.expectEqual(ctx, registry.finalizationRegistryRealmContext().?);
    const cycle_key = try rt.internAtom("finalizationRegistryRealmCycle");
    defer rt.atoms.free(cycle_key);
    try global.defineOwnProperty(
        rt,
        cycle_key,
        core.Descriptor.data(registry.value(), true, true, true),
    );
    registry.value().free(rt);

    // Only the cycle remains: Context -> global -> registry -> RealmRef(Context).
    // The registry's typed realm edge must participate in decref/scan/restore,
    // then release exactly once when the condemned payload is destroyed.
    ctx.destroy();
    ctx_alive = false;
    try std.testing.expect(rt.firstContext() != null);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.firstContext() == null);
}

test "FinalizationRegistry RealmRef retains and releases its construction realm exactly once" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.RealmContext.create(rt);
    var ctx_alive = true;
    defer if (ctx_alive) ctx.destroy();

    const base_ref_count = ctx.header.meta().rc;
    const registry = try core.Object.createFinalizationRegistry(rt, ctx, null);
    try std.testing.expectEqual(base_ref_count + 1, ctx.header.meta().rc);
    try std.testing.expectEqual(ctx, registry.finalizationRegistryRealmContext().?);

    registry.value().free(rt);
    try std.testing.expectEqual(base_ref_count, ctx.header.meta().rc);
    ctx.destroy();
    ctx_alive = false;
    try std.testing.expect(rt.firstContext() == null);
}

test "dynamic class registration reserves slots in live and future realms" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const first = try core.RealmContext.create(rt);
    defer first.destroy();
    const second = try core.RealmContext.create(rt);
    defer second.destroy();

    const class_id = try rt.newClassId(core.class.invalid_class_id);
    try rt.ensureContextClassPrototypeCapacity(class_id);
    try rt.classes.register(class_id, .{ .class_name = "RealmCapacityTest" });
    try std.testing.expect(first.classPrototypeObject(class_id) == null);
    try std.testing.expect(second.classPrototypeObject(class_id) == null);

    const future = try core.RealmContext.create(rt);
    defer future.destroy();
    try std.testing.expect(future.classPrototypeObject(class_id) == null);
    _ = try future.ensureClassPrototypeSlot(class_id);
}

test "dynamic class prototype capacity and clearing include constructing realms" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const constructing = try core.RealmContext.createConstructingWithOptions(rt, .{});
    defer constructing.destroy();

    const class_id: core.ClassId = 1024;
    try rt.ensureContextClassPrototypeCapacity(class_id);
    try std.testing.expect(constructing.class_prototypes.len > class_id);
    try rt.classes.register(class_id, .{ .class_name = "ConstructingRealmClass" });

    const prototype = try core.Object.create(rt, core.class.ids.object, null);
    const prototype_value = prototype.value();
    defer prototype_value.free(rt);
    try constructing.setClassPrototype(class_id, prototype);
    try std.testing.expectEqual(prototype, constructing.classPrototypeObject(class_id).?);

    rt.clearContextClassPrototype(class_id);
    rt.classes.unregisterDynamic(class_id);
    try std.testing.expect(constructing.classPrototypeObject(class_id) == null);
    try std.testing.expect(!rt.classes.isRegistered(class_id));
}

test "runtime-resident indexes outlive a temporary allocator" {
    var rt: core.JSRuntime = undefined;
    try rt.init(std.heap.page_allocator, .{});
    defer rt.deinit();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const stable_allocator = rt.memory.allocator;
    rt.memory.allocator = arena.allocator();
    errdefer {
        rt.memory.allocator = stable_allocator;
        arena.deinit();
    }

    rt.beginBorrowedWeakCleanup();
    try rt.enqueueBorrowedWeakCleanupIdentity(2);
    rt.endBorrowedWeakCleanup();

    rt.memory.allocator = stable_allocator;
    arena.deinit();

    // Clearing after the temporary arena is gone exercises the retained hash
    // allocation. It must have come from the runtime's persistent allocator.
    rt.beginBorrowedWeakCleanup();
    rt.endBorrowedWeakCleanup();
}

test "atom replace handles self-assignment without releasing dynamic atom" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var slot = try rt.internAtom("dynamic-atom-self-replace");
    rt.atoms.replace(&slot, slot);

    try std.testing.expectEqualStrings("dynamic-atom-self-replace", rt.atoms.name(slot).?);
    rt.atoms.free(slot);
}

test "runtime takes typed Promise jobs without allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    try rt.job_queue.ensureCapacity(2);
    try rt.job_queue.enqueuePromise(ctx, core.JSValue.int32(10));
    try rt.job_queue.enqueuePromise(ctx, core.JSValue.int32(11));

    const old_bytes = rt.memory.allocated_bytes;
    const old_allocations = rt.memory.allocation_count;
    rt.setMemoryLimit(old_bytes);
    var first = rt.job_queue.takeFirst().?;
    rt.setMemoryLimit(null);
    defer first.deinit();

    try std.testing.expectEqual(@as(?i32, 10), first.payload.promise.value.asInt32());
    try std.testing.expectEqual(@as(usize, 1), rt.job_queue.jobs.len);
    try std.testing.expectEqual(@as(usize, 4), rt.job_queue.capacity);
    try std.testing.expectEqual(@as(?i32, 11), rt.job_queue.jobs[0].payload.promise.value.asInt32());
    try std.testing.expectEqual(old_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(old_allocations, rt.memory.allocation_count);

    var second = rt.job_queue.takeFirst().?;
    defer second.deinit();
    try std.testing.expectEqual(@as(?i32, 11), second.payload.promise.value.asInt32());
    try std.testing.expectEqual(@as(usize, 0), rt.job_queue.jobs.len);
    try std.testing.expectEqual(@as(usize, 4), rt.job_queue.capacity);
    try std.testing.expect(rt.job_queue.takeFirst() == null);
}

test "typed job reservations preserve capacity without claiming a FIFO position" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    try rt.job_queue.enqueuePromise(ctx, core.JSValue.int32(10));
    try rt.job_queue.enqueuePromise(ctx, core.JSValue.int32(11));
    try rt.job_queue.enqueuePromise(ctx, core.JSValue.int32(12));
    try std.testing.expectEqual(@as(usize, 4), rt.job_queue.capacity);

    try rt.job_queue.reserveEntries(1);

    // A reentrant ordinary enqueue owns the next FIFO position, but cannot
    // consume the slot promised to the prepared transaction.
    try rt.job_queue.enqueuePromise(ctx, core.JSValue.int32(20));
    try std.testing.expectEqual(@as(usize, 8), rt.job_queue.capacity);

    const reserved_value = try core.Object.create(rt, core.class.ids.object, null);
    defer reserved_value.value().free(rt);
    rt.job_queue.enqueueOwnedPromiseObjectPrepared(ctx, reserved_value.value().dup());

    const expected = [_]i32{ 10, 11, 12, 20 };
    for (expected) |value| {
        var job = rt.job_queue.takeFirst().?;
        defer job.deinit();
        try std.testing.expectEqual(@as(?i32, value), job.payload.promise.value.asInt32());
    }
    var reserved_job = rt.job_queue.takeFirst().?;
    defer reserved_job.deinit();
    try std.testing.expect(reserved_job.payload.promise.value.same(reserved_value.value()));
    try std.testing.expect(rt.job_queue.takeFirst() == null);
}

fn testBacktraceLocationResolver(_: ?*const anyopaque, pc: usize) core.BacktraceLocation {
    return .{ .line_num = @intCast(pc), .col_num = @intCast(pc + 10) };
}

fn appendWeakCollectionEntry(rt: *core.JSRuntime, collection: *core.Object, key: *core.Object, value: core.JSValue) !void {
    const key_identity = (try core.Object.weakIdentityFromValue(rt, key.value())) orelse unreachable;
    rt.retainWeakIdentity(key_identity);
    errdefer rt.releaseWeakIdentity(key_identity);
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
    try rt.registerBorrowedReferenceHolder(collection);
}

fn appendFinalizationRegistryCell(
    rt: *core.JSRuntime,
    registry: *core.Object,
    target: core.JSValue,
    held_value: core.JSValue,
    unregister_token: core.JSValue,
) !void {
    try registry.appendFinalizationRegistryCell(rt, target, held_value, unregister_token);
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
    try std.testing.expectEqual(@as(i32, 6), ctx.runtime.backtrace_frames[0].location().line_num);
    try std.testing.expectEqual(@as(i32, 16), ctx.runtime.backtrace_frames[0].location().col_num);

    pc = 12;
    try std.testing.expectEqual(@as(i32, 11), ctx.runtime.backtrace_frames[0].location().line_num);
    try std.testing.expectEqual(@as(i32, 21), ctx.runtime.backtrace_frames[0].location().col_num);

    ctx.updateBacktracePc(3);
    try std.testing.expectEqual(@as(i32, 3), ctx.runtime.backtrace_frames[0].location().line_num);
    try std.testing.expectEqual(@as(i32, 13), ctx.runtime.backtrace_frames[0].location().col_num);
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

test "private brand property owns exactly one stored symbol value across replacement" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const object = try core.Object.create(rt, core.class.ids.object, null);
    var object_alive = true;
    defer if (object_alive) object.value().free(rt);

    const brand = try rt.atoms.newSymbol("privateBrandReplacement", .private);
    {
        const initial = try rt.symbolValue(brand);
        defer initial.free(rt);
        try object.defineOwnProperty(
            rt,
            core.atom.ids.Private_brand,
            core.Descriptor.data(initial, true, true, true),
        );
    }
    rt.atoms.free(brand);
    try std.testing.expect(rt.atoms.name(brand) != null);

    {
        const replacement = try rt.symbolValue(brand);
        defer replacement.free(rt);
        try object.setProperty(rt, core.atom.ids.Private_brand, replacement);
    }
    try std.testing.expect(rt.atoms.name(brand) != null);
    {
        const stored = try object.getProperty(core.atom.ids.Private_brand);
        defer stored.free(rt);
        try std.testing.expectEqual(@as(?core.Atom, brand), stored.asSymbolAtom());
    }

    object.value().free(rt);
    object_alive = false;
    try std.testing.expect(rt.atoms.name(brand) == null);
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

test "GC leaves atom-owned unique symbol atoms until release" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-unrooted-symbol");
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    rt.atoms.free(symbol_atom);
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
    var rooted_value = try rt.symbolValue(symbol_atom);
    var root_values = [_]core.runtime.ValueRootValue{.{ .value = &rooted_value }};
    const roots = core.runtime.ValueRootFrame{ .values = &root_values };

    _ = rt.runObjectCycleRemovalWithValueRoots(&roots);
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    rooted_value.free(rt);
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
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    rt.atoms.free(symbol_atom);
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "GC keeps runtime exception and realm value slot unique symbol atoms" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const runtime_symbol = try rt.atoms.newValueSymbol("gc-runtime-slot-symbol");
    rt.current_exception = try rt.symbolValue(runtime_symbol);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(runtime_symbol) != null);
    ctx.clearException();
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(runtime_symbol) == null);

    const exception_symbol = try rt.atoms.newValueSymbol("gc-context-exception-symbol");
    _ = ctx.throwValue(try rt.symbolValue(exception_symbol));

    const rejection_symbol = try rt.atoms.newValueSymbol("gc-context-unhandled-symbol");
    const rejection_value = try rt.symbolValue(rejection_symbol);
    ctx.recordUnhandledRejection(rejection_value);
    rejection_value.free(rt);

    const prototype_symbol = try rt.atoms.newValueSymbol("gc-context-prototype-symbol");
    ctx.class_prototypes[0] = try rt.symbolValue(prototype_symbol);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(exception_symbol) != null);
    try std.testing.expect(rt.atoms.name(rejection_symbol) != null);
    try std.testing.expect(rt.atoms.name(prototype_symbol) != null);

    ctx.clearException();
    const old_prototype = ctx.class_prototypes[0];
    ctx.class_prototypes[0] = core.JSValue.nullValue();
    old_prototype.free(rt);

    _ = rt.runObjectCycleRemoval();
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
    const lexical_value = try rt.symbolValue(lexical_symbol);
    try env.defineOwnProperty(rt, property_name, core.Descriptor.data(lexical_value, true, true, true));
    lexical_value.free(rt);

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
    const pending_value = try rt.symbolValue(pending_symbol);
    try rt.job_queue.enqueuePromise(ctx, pending_value);
    pending_value.free(rt);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(pending_symbol) != null);

    var pending = rt.job_queue.takeFirst().?;
    pending.deinit();

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(pending_symbol) == null);
}

test "GC keeps finalization job unique symbol atoms after dequeue until release" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const callback_symbol = try rt.atoms.newValueSymbol("gc-finalization-job-callback-symbol");
    const held_symbol = try rt.atoms.newValueSymbol("gc-finalization-job-held-symbol");

    const callback_value = try rt.symbolValue(callback_symbol);
    const held_value = try rt.symbolValue(held_symbol);
    try rt.enqueueFinalizationJobForRealm(ctx, callback_value, held_value);
    callback_value.free(rt);
    held_value.free(rt);
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().pending_finalization_job_count);
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().finalizer_queue_length);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(callback_symbol) != null);
    try std.testing.expect(rt.atoms.name(held_symbol) != null);

    var job = rt.job_queue.takeFirst().?;
    var job_alive = true;
    defer if (job_alive) job.deinit();
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().pending_finalization_job_count);
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().finalizer_queue_length);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(callback_symbol) != null);
    try std.testing.expect(rt.atoms.name(held_symbol) != null);

    job.deinit();
    job_alive = false;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(callback_symbol) == null);
    try std.testing.expect(rt.atoms.name(held_symbol) == null);
}

test "GC keeps dequeued finalization job function bytecode symbol constants until release" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const fb = try engine.bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
    var fb_published = false;
    errdefer if (!fb_published) fb.destroyUnpublishedFixture(rt);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-finalization-job-bytecode-symbol");
    const symbol_value = try rt.symbolValue(symbol_atom);
    fb.cpoolSlice()[0] = symbol_value;
    fb.publishFixtureNoFail(rt);
    fb_published = true;

    const bytecode_value = core.JSValue.functionBytecode(&fb.header);
    try rt.enqueueFinalizationJobForRealm(ctx, bytecode_value, core.JSValue.undefinedValue());
    bytecode_value.free(rt);

    var job = rt.job_queue.takeFirst().?;
    var job_alive = true;
    defer if (job_alive) job.deinit();

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    job.deinit();
    job_alive = false;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "GC keeps module registry unique symbol atoms until release" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const module_name = try rt.internAtom("gc-module-symbols.mjs");
    defer rt.atoms.free(module_name);
    const binding_name = try rt.internAtom("localSymbol");
    defer rt.atoms.free(binding_name);

    const binding_symbol = try rt.atoms.newValueSymbol("gc-module-binding-symbol");
    const binding_cell = try core.VarRef.createClosed(rt, try rt.symbolValue(binding_symbol));

    var pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer pending.deinit(rt);
    try pending.addExport(binding_name, binding_name, 0);
    const record = try publishFreshModule(&ctx.modules, module_name, &pending);
    record.publishRetainedExportCellNoFail(0, binding_cell.valueRef());

    const import_meta_symbol = try rt.atoms.newValueSymbol("gc-module-import-meta-symbol");
    record.import_meta = try rt.symbolValue(import_meta_symbol);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(binding_symbol) != null);
    try std.testing.expect(rt.atoms.name(import_meta_symbol) != null);

    record.clearRetainedExportCellNoFail(rt, 0);
    if (record.import_meta) |old_import_meta| old_import_meta.free(rt);
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
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    rt.atoms.free(symbol_atom);
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "GC keeps rooted function bytecode symbol constants" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const fb = try engine.bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
    var fb_published = false;
    errdefer if (!fb_published) fb.destroyUnpublishedFixture(rt);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-bytecode-symbol-constant");
    const symbol_value = try rt.symbolValue(symbol_atom);
    fb.cpoolSlice()[0] = symbol_value;
    fb.publishFixtureNoFail(rt);
    fb_published = true;

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
    const object_symbol_value = try rt.symbolValue(object_symbol);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(object_symbol_value, true, true, true));
    object_symbol_value.free(rt);
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

test "runtime teardown keeps unique symbol property keys live through shape destruction" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.object, null);
    const symbol_value = try rt.newSymbolValue(null);
    const symbol_atom = symbol_value.asSymbolAtom().?;
    try object.defineOwnProperty(
        rt,
        symbol_atom,
        core.Descriptor.data(core.JSValue.boolean(true), true, true, true),
    );
    symbol_value.free(rt);

    // Keep the object alive until JSRuntime.deinit. The shape is held for GC
    // teardown phase 3, so its atom ref must outlive the pre-GC string-cache
    // release rather than being mistaken for a disposable cache reference.
}

test "strings choose QuickJS-style 8-bit or 16-bit storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ascii = try core.string.String.createUtf8(rt, "abc");
    defer ascii.value().free(rt);
    try std.testing.expect(!ascii.isWide());
    try std.testing.expectEqual(@as(usize, 3), ascii.len());
    try std.testing.expect(ascii.eqlBytes("abc"));
    // `hash == 0` is the qjs "not yet computed" sentinel.
    try std.testing.expectEqual(@as(u32, 0), ascii.hash_meta.hash);
    const computed = ascii.contentHash();
    try std.testing.expect(computed != 0);
    // Stable across repeated demands.
    try std.testing.expectEqual(computed, ascii.contentHash());
    try std.testing.expect(ascii.hash_meta.hash != 0);

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

test "ASCII suffix concatenation preserves source width with one result allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const narrow_source = try core.string.String.createLatin1(rt, "ab");
    defer narrow_source.value().free(rt);
    const narrow_allocations = rt.memory.allocation_count;
    const narrow = try core.string.String.createAsciiSuffix(rt, narrow_source.resolveData(), "y");
    defer narrow.value().free(rt);
    try std.testing.expect(!narrow.isWide());
    try std.testing.expect(narrow.eqlBytes("aby"));
    try std.testing.expectEqual(narrow_allocations + 1, rt.memory.allocation_count);

    const wide_source = try core.string.String.createUtf16(rt, &.{ 0x0100, 'a' });
    defer wide_source.value().free(rt);
    const wide_allocations = rt.memory.allocation_count;
    const wide = try core.string.String.createAsciiSuffix(rt, wide_source.resolveData(), "y");
    defer wide.value().free(rt);
    try std.testing.expect(wide.isWide());
    try std.testing.expectEqual(@as(usize, 3), wide.len());
    try std.testing.expectEqual(@as(u16, 0x0100), wide.codeUnitAt(0));
    try std.testing.expectEqual(@as(u16, 'a'), wide.codeUnitAt(1));
    try std.testing.expectEqual(@as(u16, 'y'), wide.codeUnitAt(2));
    try std.testing.expectEqual(wide_allocations + 1, rt.memory.allocation_count);
}

test "flat strings store characters inline in a single fixed-size allocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    // QuickJS `JSString` keeps characters inline (a flexible array member),
    // so creating a flat string is exactly one allocation and holds no spare
    // capacity to append into.
    const fixed_allocations = rt.memory.allocation_count;
    const fixed = try core.string.String.createLatin1(rt, "abc");
    try std.testing.expectEqual(@as(usize, 3), fixed.len());
    try std.testing.expect(!fixed.isWide());
    try std.testing.expect(fixed.eqlBytes("abc"));
    try std.testing.expectEqual(fixed_allocations + 1, rt.memory.allocation_count);
    fixed.value().free(rt);
    try std.testing.expectEqual(fixed_allocations, rt.memory.allocation_count);

    const growable_allocations = rt.memory.allocation_count;
    const growable = try core.string.String.createLatin1Concat(rt, "ab", "c");
    defer growable.value().free(rt);
    try std.testing.expect(growable.eqlBytes("abc"));
    try std.testing.expectEqual(growable_allocations + 1, rt.memory.allocation_count);
}

test "ordinary rope nodes keep accumulator state out of line" {
    // QJS's node is just u32/u8/u8 plus two JSValues. zjs additionally needs
    // one runtime pointer for its context-free borrowed-string API; generic
    // ropes must not regress to embedding the private tail pointer/union,
    // cached-flat/hash, or destroy link.
    const compact_limit = 2 * @sizeOf(core.JSValue) + @sizeOf(*anyopaque) + 8;
    try std.testing.expect(@sizeOf(core.string.StringRope) <= compact_limit);
}

test "rope tail append extends an unmaterialized rope in place" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const left = try core.string.String.createLatin1(rt, "abc");
    const right = try core.string.String.createLatin1(rt, "def");
    // A rope is a standalone `StringRope` reached through a `Tag.string_rope`
    // value; createRope retains its children, so drop our own references.
    const rope = try core.string.String.createAccumulatorRope(rt, left.value(), right.value());
    left.value().free(rt);
    right.value().free(rt);
    const rope_value = rope.value();
    defer rope_value.free(rt);

    try std.testing.expect(try core.string.appendRopeTail(rope, rt, .{ .latin1 = "ghi" }, 1));
    try std.testing.expect(try core.string.appendRopeTail(rope, rt, .{ .latin1 = "jkl" }, 1));
    try std.testing.expect(try core.string.appendRopeTail(rope, rt, .{ .latin1 = "" }, 1));
    try std.testing.expectEqual(@as(usize, 12), rope.len_());
    try std.testing.expect(!rope.isWide());

    // Length growth in a loop exercises the amortized-doubling regrowth.
    var round: usize = 0;
    while (round < 100) : (round += 1) {
        try std.testing.expect(try core.string.appendRopeTail(rope, rt, .{ .latin1 = "0123456789" }, 1));
    }
    try std.testing.expectEqual(@as(usize, 1012), rope.len_());

    // Content reads flatten the rope including the tail segment.
    const flat = try rope.flatten();
    try std.testing.expectEqual(@as(u16, 'g'), flat.codeUnitAt(6));
    try std.testing.expectEqual(@as(u16, 'l'), flat.codeUnitAt(11));
    try std.testing.expectEqual(@as(u16, '0'), flat.codeUnitAt(12));
    try std.testing.expectEqual(@as(u16, '9'), flat.codeUnitAt(1011));

    // Materialized ropes refuse tail appends: their content is captured.
    try std.testing.expect(!try core.string.appendRopeTail(rope, rt, .{ .latin1 = "nope" }, 1));
    try std.testing.expectEqual(@as(usize, 1012), rope.len_());

    // An unflattened rope destroyed with a pending tail releases it.
    const l2 = try core.string.String.createLatin1(rt, "xy");
    const r2 = try core.string.String.createLatin1(rt, "z");
    const dropped = try core.string.String.createAccumulatorRope(rt, l2.value(), r2.value());
    l2.value().free(rt);
    r2.value().free(rt);
    try std.testing.expect(try core.string.appendRopeTail(dropped, rt, .{ .latin1 = "tail" }, 1));
    dropped.value().free(rt);
}

test "rope tail append widens for utf16 suffixes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const left = try core.string.String.createLatin1(rt, "ab");
    const right = try core.string.String.createLatin1(rt, "cd");
    const rope = try core.string.String.createAccumulatorRope(rt, left.value(), right.value());
    left.value().free(rt);
    right.value().free(rt);
    const rope_value = rope.value();
    defer rope_value.free(rt);

    try std.testing.expect(try core.string.appendRopeTail(rope, rt, .{ .latin1 = "12" }, 1));
    try std.testing.expect(!rope.isWide());
    // A wide suffix widens the narrow tail in place and flips the rope wide.
    try std.testing.expect(try core.string.appendRopeTail(rope, rt, .{ .utf16 = &.{0x0100} }, 1));
    try std.testing.expect(rope.isWide());
    // Narrow content keeps landing in the widened tail.
    try std.testing.expect(try core.string.appendRopeTail(rope, rt, .{ .latin1 = "z" }, 1));
    try std.testing.expectEqual(@as(usize, 8), rope.len_());

    const expected = try core.string.String.createUtf16(rt, &.{ 'a', 'b', 'c', 'd', '1', '2', 0x0100, 'z' });
    defer expected.value().free(rt);
    const flat = try rope.flatten();
    try std.testing.expect(flat.eqlString(expected));
    try std.testing.expectEqual(expected.contentHash(), rope.contentHash());
}

test "rope index compare and hash traverse nested leaves without flattening" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const left = try core.string.String.createLatin1(rt, "ab");
    const right = try core.string.String.createUtf16(rt, &.{ 0x0100, 'c' });
    const inner = try core.string.String.createAccumulatorRope(rt, left.value(), right.value());
    left.value().free(rt);
    right.value().free(rt);
    const inner_value = inner.value();
    defer inner_value.free(rt);
    try std.testing.expect(try core.string.appendRopeTail(inner, rt, .{ .latin1 = "xy" }, 1));

    const suffix = try core.string.String.createLatin1(rt, "!");
    const outer = try core.string.String.createRope(rt, inner_value, suffix.value());
    suffix.value().free(rt);
    const outer_value = outer.value();
    defer outer_value.free(rt);

    const expected = try core.string.String.createUtf16(rt, &.{ 'a', 'b', 0x0100, 'c', 'x', 'y', '!' });
    defer expected.value().free(rt);

    try std.testing.expectEqual(@as(?u16, 'a'), core.string.stringValueCodeUnitAt(outer_value, 0));
    try std.testing.expectEqual(@as(?u16, 0x0100), core.string.stringValueCodeUnitAt(outer_value, 2));
    try std.testing.expectEqual(@as(?u16, 'x'), core.string.stringValueCodeUnitAt(outer_value, 4));
    try std.testing.expectEqual(@as(?u16, '!'), core.string.stringValueCodeUnitAt(outer_value, 6));
    try std.testing.expectEqual(@as(?u16, null), core.string.stringValueCodeUnitAt(outer_value, 7));

    try std.testing.expectEqual(@as(?i32, 0), core.string.compareStringValues(outer_value, expected.value(), false));
    try std.testing.expectEqual(@as(?i32, 0), core.string.compareStringValues(outer_value, expected.value(), true));
    try std.testing.expectEqual(expected.contentHash(), core.string.stringValueContentHash(outer_value).?);
    try std.testing.expectEqual(expected.contentHash(), outer.contentHash());

    // These QJS-style readers must leave both levels as ropes.
    try std.testing.expect(!inner.isLinearized());
    try std.testing.expect(!outer.isLinearized());
}

test "rope child snapshots content: shared child refuses tail appends" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const left = try core.string.String.createLatin1(rt, "abc");
    const right = try core.string.String.createLatin1(rt, "def");
    const inner = try core.string.String.createAccumulatorRope(rt, left.value(), right.value());
    left.value().free(rt);
    right.value().free(rt);
    const inner_value = inner.value();
    defer inner_value.free(rt);
    try std.testing.expect(try core.string.appendRopeTail(inner, rt, .{ .latin1 = "ghi" }, 1));

    const suffix = try core.string.String.createLatin1(rt, "XY");
    // `inner` becomes a rope child (its rc rises to 2), so further in-place
    // tail appends on it must refuse — the refcount analogue of the old
    // `rope_child` snapshot bit — keeping the parent's view immutable.
    const outer = try core.string.String.createRope(rt, inner.value(), suffix.value());
    suffix.value().free(rt);
    const outer_value = outer.value();
    defer outer_value.free(rt);

    try std.testing.expect(!try core.string.appendRopeTail(inner, rt, .{ .latin1 = "no" }, 1));

    const outer_flat = try outer.flatten();
    try std.testing.expect(outer_flat.eqlBytes("abcdefghiXY"));
    const inner_flat = try inner.flatten();
    try std.testing.expect(inner_flat.eqlBytes("abcdefghi"));
}

test "strings compare by code unit across storage widths" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const latin1 = try core.string.String.createUtf8(rt, "é");
    defer latin1.value().free(rt);
    const utf16_same = try core.string.String.createUtf16(rt, &.{0x00e9});
    defer utf16_same.value().free(rt);
    try std.testing.expect(latin1.eqlString(utf16_same));

    const a = try core.string.String.createUtf8(rt, "abc");
    defer a.value().free(rt);
    const b = try core.string.String.createUtf8(rt, "abd");
    defer b.value().free(rt);
    try std.testing.expect(a.compare(b) < 0);
    try std.testing.expect(b.compare(a) > 0);
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
    // OP_push_atom_value's QJS-like direct entry path returns the same cached
    // body and performs no allocation after the first materialization.
    const allocations = rt.memory.allocation_count;
    const pushed = try rt.atoms.toStringValueForPush(rt, atom_id);
    try std.testing.expect(pushed.asStringBodyRaw() == atom_string);
    try std.testing.expectEqual(allocations, rt.memory.allocation_count);
    pushed.free(rt);
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
    try std.testing.expectEqual(@as(core.ClassId, 68), core.class.ids.global_object);
    try std.testing.expectEqual(@as(core.ClassId, 69), core.class.ids.init_count);
    try std.testing.expect(rt.classes.isRegistered(core.class.ids.object));
    try std.testing.expect(rt.classes.isRegistered(core.class.ids.generator));
    try std.testing.expect(!rt.classes.isRegistered(core.class.ids.proxy));

    const object_name = rt.classes.className(core.class.ids.object).?;
    defer rt.atoms.free(object_name);
    try std.testing.expectEqual(core.atom.ids.Object, object_name);

    const dynamic_id = try rt.newClassId(core.class.invalid_class_id);
    try std.testing.expect(dynamic_id >= core.class.ids.init_count);
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
    try std.testing.expectEqual(core.class.PayloadKind.none, rt.classes.record(core.class.ids.array).?.payload_kind);
    try std.testing.expectEqual(core.class.PayloadKind.regexp, rt.classes.record(core.class.ids.regexp).?.payload_kind);
    try std.testing.expectEqual(core.class.PayloadKind.collection, rt.classes.record(core.class.ids.map).?.payload_kind);
    try std.testing.expectEqual(core.class.PayloadKind.iterator, rt.classes.record(core.class.ids.array_iterator).?.payload_kind);
    try std.testing.expectEqual(core.class.PayloadKind.generator, rt.classes.record(core.class.ids.generator).?.payload_kind);
    try std.testing.expectEqual(core.class.PayloadKind.function, rt.classes.record(core.class.ids.c_function).?.payload_kind);
    try std.testing.expectEqual(core.class.PayloadKind.function, rt.classes.record(core.class.ids.bytecode_function).?.payload_kind);
    try std.testing.expectEqual(core.class.PayloadKind.none, rt.classes.record(core.class.ids.module_ns).?.payload_kind);
    try std.testing.expectEqual(core.class.PayloadKind.weak_ref, core.class.standardPayloadKind(core.class.ids.weak_ref));
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
    payload.* = null;
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

const ClassConstructionUnregisterProbe = struct {
    rt: *core.JSRuntime,
    class_id: core.ClassId,
    fired: bool = false,

    fn trigger(raw: ?*anyopaque, _: usize) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (self.fired) return;
        self.fired = true;
        self.rt.classes.unregisterDynamic(self.class_id);
    }
};

const ClassConstructionGrowthProbe = struct {
    rt: *core.JSRuntime,
    target_id: core.ClassId,
    growth_id: core.ClassId,
    fired: bool = false,
    register_failed: bool = false,
    target_record_after_growth: usize = 0,

    fn trigger(raw: ?*anyopaque, _: usize) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (self.fired) return;
        self.fired = true;
        self.rt.classes.register(self.growth_id, .{ .class_name = "GrowthDuringConstruction" }) catch {
            self.register_failed = true;
            return;
        };
        self.target_record_after_growth = @intFromPtr(self.rt.classes.recordPtr(self.target_id).?);
    }
};

const InlineClassFinalizerReentry = struct {
    var target_id: core.ClassId = core.class.invalid_class_id;
    var growth_id: core.ClassId = core.class.invalid_class_id;
    var calls: usize = 0;
    var register_failed: bool = false;
    var definition_visible_after_unregister: bool = false;
    var property_storage_was_stripped: bool = false;
    var owner_thread_observed: bool = false;

    fn reset() void {
        target_id = core.class.invalid_class_id;
        growth_id = core.class.invalid_class_id;
        calls = 0;
        register_failed = false;
        definition_visible_after_unregister = false;
        property_storage_was_stripped = false;
        owner_thread_observed = false;
    }

    fn finalize(runtime: *anyopaque, object_ptr: *anyopaque, payload: *core.class.Payload) void {
        const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
        const object: *core.Object = @ptrCast(@alignCast(object_ptr));
        calls += 1;
        owner_thread_observed = rt.isOwnerThread() and rt.classes.isOwnerThread();
        property_storage_was_stripped = !object.hasPropertyStorage();
        rt.classes.unregisterDynamic(target_id);
        definition_visible_after_unregister = rt.classes.isRegistered(target_id) and rt.classes.unregisterPending(target_id);
        rt.classes.register(growth_id, .{ .class_name = "GrowthDuringInlineFinalizer" }) catch {
            register_failed = true;
        };
        payload.* = null;
    }
};

fn finalizeTestExternalPayload(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    const ptr = payload.* orelse return;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const typed: *TestExternalPayload = @ptrCast(@alignCast(ptr));
    typed.value.free(rt);
    rt.memory.destroy(TestExternalPayload, typed);
    payload.* = null;
}

fn finalizeTestExternalObjectPayload(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    const ptr = payload.* orelse return;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const typed: *TestExternalObjectPayload = @ptrCast(@alignCast(ptr));
    if (typed.object) |object| object.value().free(rt);
    rt.memory.destroy(TestExternalObjectPayload, typed);
    payload.* = null;
}

fn reentrantCollectionClearFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    payload.* = null;
    if (reentrant_collection_clear_calls != 0) return;
    reentrant_collection_clear_calls += 1;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const map = reentrant_collection_clear_target orelse return;
    const result = engine.exec.collection_ops.methodCall(rt, map.value(), 5, &.{}) catch return;
    result.free(rt);
}

fn reentrantArrayDeleteFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    payload.* = null;
    if (reentrant_array_delete_calls != 0) return;
    reentrant_array_delete_calls += 1;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const array = reentrant_array_delete_target orelse return;
    _ = array.deleteProperty(rt, core.atom.atomFromUInt32(0));
}

fn reentrantPropertyDeleteFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    payload.* = null;
    if (reentrant_property_delete_calls != 0) return;
    reentrant_property_delete_calls += 1;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const object = reentrant_property_delete_target orelse return;
    _ = object.deleteProperty(rt, reentrant_property_delete_key);
}

fn reentrantRegExpLastIndexFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    payload.* = null;
    if (reentrant_regexp_last_index_calls != 0) return;
    reentrant_regexp_last_index_calls += 1;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const regexp = reentrant_regexp_last_index_target orelse return;
    regexp.setProperty(rt, core.atom.ids.lastIndex, core.JSValue.int32(99)) catch {};
}

fn reentrantMappedArgumentsFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    payload.* = null;
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
    payload.* = null;
    if (reentrant_cached_iterator_next_calls != 0) return;
    reentrant_cached_iterator_next_calls += 1;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const object = reentrant_cached_iterator_next_target orelse return;
    object.clearCachedIteratorNext(rt);
}

fn reentrantExceptionSlotFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    payload.* = null;
    if (reentrant_exception_slot_calls != 0) return;
    reentrant_exception_slot_calls += 1;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const slot = reentrant_exception_slot_target orelse return;
    slot.clear(rt);
}

fn reentrantArrayIteratorFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    payload.* = null;
    if (reentrant_array_iterator_calls != 0) return;
    reentrant_array_iterator_calls += 1;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const iterator = reentrant_array_iterator_target orelse return;
    const result = engine.exec.array_builtin_ops.methodCall(rt, iterator.value(), 20, &.{}) catch return;
    result.free(rt);
}

fn markTestExternalPayload(
    _: *anyopaque,
    _: *anyopaque,
    payload: *core.class.Payload,
    visitor: *core.class.PayloadVisitor,
) void {
    payload_mark_calls += 1;
    const ptr = payload.* orelse return;
    const typed: *TestExternalPayload = @ptrCast(@alignCast(ptr));
    visitor.value(@ptrCast(&typed.value));
}

fn markTestExternalObjectPayload(
    _: *anyopaque,
    _: *anyopaque,
    payload: *core.class.Payload,
    visitor: *core.class.PayloadVisitor,
) void {
    payload_mark_calls += 1;
    const ptr = payload.* orelse return;
    const typed: *TestExternalObjectPayload = @ptrCast(@alignCast(ptr));
    visitor.object(@ptrCast(&typed.object));
}

test "class registration growth OOM does not publish a partial definition and retry succeeds" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const class_id: core.ClassId = 4096;
    const record_bytes = @sizeOf(core.class.Record) * (@as(usize, class_id) + 1);
    rt.setMemoryLimit(rt.memory.allocated_bytes + record_bytes);
    try std.testing.expectError(error.OutOfMemory, rt.classes.register(class_id, .{ .class_name = "Object" }));
    try std.testing.expect(!rt.classes.isRegistered(class_id));
    try std.testing.expect(rt.classes.recordPtr(class_id) == null);

    rt.setMemoryLimit(null);
    try rt.classes.register(class_id, .{ .class_name = "Object" });
    try std.testing.expect(rt.classes.isRegistered(class_id));
    rt.classes.unregisterDynamic(class_id);
}

test "object creation rejects an unregistered dynamic class generation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const class_id = try rt.newClassId(core.class.invalid_class_id);
    try std.testing.expectError(error.InvalidClassId, core.Object.create(rt, class_id, null));

    try rt.classes.register(class_id, .{ .class_name = "RegisteredGeneration" });
    const object = try core.Object.create(rt, class_id, null);
    object.value().free(rt);
    rt.classes.unregisterDynamic(class_id);

    try std.testing.expectError(error.InvalidClassId, core.Object.create(rt, class_id, null));
}

test "class construction pins its definition across reentrant unregister" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const class_id = try rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(class_id, .{
        .class_name = "PinnedConstructionDefinition",
        .payload_kind = .object_data,
        .has_exotic = true,
    });

    var probe = ClassConstructionUnregisterProbe{ .rt = rt, .class_id = class_id };
    const saved_trigger = rt.memory.trigger_gc_fn;
    const saved_context = rt.memory.trigger_gc_ctx;
    rt.memory.trigger_gc_fn = ClassConstructionUnregisterProbe.trigger;
    rt.memory.trigger_gc_ctx = &probe;
    defer {
        rt.memory.trigger_gc_fn = saved_trigger;
        rt.memory.trigger_gc_ctx = saved_context;
    }

    const object = try core.Object.create(rt, class_id, null);
    try std.testing.expect(probe.fired);
    try std.testing.expect(rt.classes.isRegistered(class_id));
    try std.testing.expect(rt.classes.unregisterPending(class_id));
    try std.testing.expectError(error.InvalidClassId, core.Object.create(rt, class_id, null));
    try std.testing.expectEqual(core.class.PayloadKind.object_data, object.flags.class_payload_kind);
    try std.testing.expect(object.u.payload != null);
    try std.testing.expect(object.flags.has_exotic_methods);

    object.value().free(rt);
    try std.testing.expect(!rt.classes.isRegistered(class_id));
    try std.testing.expect(!rt.classes.unregisterPending(class_id));
}

test "class construction scalar plan survives record table growth" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const target_id: core.ClassId = 1024;
    const growth_id: core.ClassId = 4096;
    try rt.classes.register(target_id, .{
        .class_name = "ConstructionGrowthTarget",
        .payload_kind = .object_data,
        .has_exotic = true,
    });
    const target_record_before_growth = @intFromPtr(rt.classes.recordPtr(target_id).?);

    var probe = ClassConstructionGrowthProbe{
        .rt = rt,
        .target_id = target_id,
        .growth_id = growth_id,
    };
    const saved_trigger = rt.memory.trigger_gc_fn;
    const saved_context = rt.memory.trigger_gc_ctx;
    rt.memory.trigger_gc_fn = ClassConstructionGrowthProbe.trigger;
    rt.memory.trigger_gc_ctx = &probe;
    defer {
        rt.memory.trigger_gc_fn = saved_trigger;
        rt.memory.trigger_gc_ctx = saved_context;
    }

    const object = try core.Object.create(rt, target_id, null);
    try std.testing.expect(probe.fired);
    try std.testing.expect(!probe.register_failed);
    try std.testing.expect(probe.target_record_after_growth != target_record_before_growth);
    try std.testing.expectEqual(core.class.PayloadKind.object_data, object.flags.class_payload_kind);
    try std.testing.expect(object.flags.has_exotic_methods);

    object.value().free(rt);
    rt.classes.unregisterDynamic(target_id);
    rt.classes.unregisterDynamic(growth_id);
}

test "inline class finalizer reentry keeps definition pinned while growing the table" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    InlineClassFinalizerReentry.reset();
    defer InlineClassFinalizerReentry.reset();
    const target_id: core.ClassId = 2048;
    const growth_id: core.ClassId = 8192;
    InlineClassFinalizerReentry.target_id = target_id;
    InlineClassFinalizerReentry.growth_id = growth_id;
    try rt.classes.register(target_id, .{
        .class_name = "InlineFinalizerReentryTarget",
        .inline_payload_size = 32,
        .inline_payload_align = 8,
        .payload_finalizer = InlineClassFinalizerReentry.finalize,
    });

    const object = try core.Object.create(rt, target_id, null);
    const property_atom = try rt.internAtom("owned-before-inline-finalizer");
    defer rt.atoms.free(property_atom);
    try object.defineOwnProperty(rt, property_atom, core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    try std.testing.expect(object.hasPropertyStorage());
    object.value().free(rt);

    try std.testing.expectEqual(@as(usize, 1), InlineClassFinalizerReentry.calls);
    try std.testing.expect(InlineClassFinalizerReentry.definition_visible_after_unregister);
    try std.testing.expect(InlineClassFinalizerReentry.property_storage_was_stripped);
    try std.testing.expect(InlineClassFinalizerReentry.owner_thread_observed);
    try std.testing.expect(!InlineClassFinalizerReentry.register_failed);
    try std.testing.expect(!rt.classes.isRegistered(target_id));
    try std.testing.expect(rt.classes.isRegistered(growth_id));
    rt.classes.unregisterDynamic(growth_id);
}

test "dynamic class definition stays pinned until a weak husk is reclaimed" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const class_id = try rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(class_id, .{
        .class_name = "WeakHuskDefinitionPin",
        .payload_kind = .object_data,
    });
    const weak_ref = try core.Object.create(rt, core.class.ids.weak_ref, null);
    const target = try core.Object.create(rt, class_id, null);
    try weak_ref.setWeakRefTarget(rt, target.value());

    rt.classes.unregisterDynamic(class_id);
    target.value().free(rt);
    try std.testing.expect(rt.classes.isRegistered(class_id));
    try std.testing.expect(rt.classes.unregisterPending(class_id));
    try std.testing.expect(weak_ref.weakRefDeref(rt).isUndefined());

    weak_ref.value().free(rt);
    try std.testing.expect(!rt.classes.isRegistered(class_id));
    try std.testing.expect(!rt.classes.unregisterPending(class_id));
}

test "class finalizers and context prototype slots are wired" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const dynamic_id = try rt.newClassId(core.class.invalid_class_id);
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
    var payload: core.class.Payload = null;
    try std.testing.expect(rt.classes.runPayloadFinalizerForTest(dynamic_id, @ptrCast(rt), @ptrCast(ctx), &payload));
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(null, payload);
    try std.testing.expect(!rt.classes.runPayloadFinalizerForTest(core.class.ids.object, @ptrCast(rt), @ptrCast(ctx), &payload));

    payload_mark_calls = 0;
    var visited_values: usize = 0;
    var visitor = core.class.PayloadVisitor{
        .context = @ptrCast(&visited_values),
        .visit_value = countVisitedValue,
    };
    payload = null;
    try std.testing.expect(rt.classes.markPayload(dynamic_id, @ptrCast(rt), @ptrCast(ctx), &payload, &visitor));
    try std.testing.expectEqual(@as(usize, 1), payload_mark_calls);
    try std.testing.expectEqual(@as(usize, 1), visited_values);
    try std.testing.expect(!rt.classes.markPayload(core.class.ids.object, @ptrCast(rt), @ptrCast(ctx), &payload, &visitor));
}

test "object destruction defers class payload finalizers" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const payloadless_id = try rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(payloadless_id, .{
        .class_name = "PayloadlessFinalized",
        .payload_finalizer = countPayloadFinalizer,
    });

    payload_finalizer_calls = 0;
    const payloadless = try core.Object.create(rt, payloadless_id, null);
    try std.testing.expect(payloadless.u.payload == null);
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    payloadless.value().free(rt);
    rt.setMemoryLimit(null);
    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);
    try expectOneDeferredClassPayloadFinalizer(rt);
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);

    const external_id = try rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(external_id, .{
        .class_name = "ExternalPayloadFinalized",
        .payload_finalizer = finalizeTestExternalPayload,
    });

    payload_finalizer_calls = 0;
    const external = try core.Object.create(rt, external_id, null);
    const payload = try rt.memory.create(TestExternalPayload);
    payload.* = .{};
    external.u.payload = @ptrCast(payload);
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

    const reentrant_id = try rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(reentrant_id, .{
        .class_name = "ReentrantCollectionClear",
        .payload_finalizer = reentrantCollectionClearFinalizer,
    });

    const map = try core.Object.create(rt, core.class.ids.map, null);
    defer map.value().free(rt);
    const value = try core.Object.create(rt, reentrant_id, null);
    const set_result = try engine.exec.collection_ops.methodCall(rt, map.value(), 1, &.{ core.JSValue.int32(1), value.value() });
    set_result.free(rt);
    value.value().free(rt);

    payload_finalizer_calls = 0;
    reentrant_collection_clear_target = map;
    reentrant_collection_clear_calls = 0;
    defer {
        reentrant_collection_clear_target = null;
        reentrant_collection_clear_calls = 0;
    }

    const clear_result = try engine.exec.collection_ops.methodCall(rt, map.value(), 5, &.{});
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

    const reentrant_id = try rt.newClassId(core.class.invalid_class_id);
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
    try std.testing.expectEqual(core.object.ArrayStorageMode.sparse, array.arrayElementStorageMode());
    try std.testing.expectEqual(@as(usize, 0), array.arrayElements().len);
    try std.testing.expect(!array.hasOwnProperty(core.atom.atomFromUInt32(0)));
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 1), reentrant_array_delete_calls);
    try std.testing.expectEqual(@as(usize, 0), array.arrayElements().len);
}

test "ordinary property delete defers value finalizer reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const reentrant_id = try rt.newClassId(core.class.invalid_class_id);
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
    var before_cleanup = try object.getProperty(key);
    defer before_cleanup.free(rt);
    try std.testing.expect(before_cleanup.isUndefined());
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 1), reentrant_property_delete_calls);
    const after = try object.getProperty(key);
    defer after.free(rt);
    try std.testing.expect(after.isUndefined());
}

test "regexp lastIndex set defers value finalizer reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const reentrant_id = try rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(reentrant_id, .{
        .class_name = "ReentrantRegExpLastIndexSet",
        .payload_finalizer = reentrantRegExpLastIndexFinalizer,
    });

    const regexp = try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.regexp, null, 1);
    defer regexp.value().free(rt);
    try regexp.initializeRegExpLastIndex(rt);
    const value = try core.Object.create(rt, reentrant_id, null);
    try regexp.setProperty(rt, core.atom.ids.lastIndex, value.value());
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

    const reentrant_id = try rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(reentrant_id, .{
        .class_name = "ReentrantRegExpLastIndexDefine",
        .payload_finalizer = reentrantRegExpLastIndexFinalizer,
    });

    const regexp = try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.regexp, null, 1);
    defer regexp.value().free(rt);
    try regexp.initializeRegExpLastIndex(rt);
    const value = try core.Object.create(rt, reentrant_id, null);
    try regexp.setProperty(rt, core.atom.ids.lastIndex, value.value());
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

    const reentrant_id = try rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(reentrant_id, .{
        .class_name = "ReentrantMappedArgumentsSet",
        .payload_finalizer = reentrantMappedArgumentsFinalizer,
    });

    const arguments = try core.Object.create(rt, core.class.ids.mapped_arguments, null);
    defer arguments.value().free(rt);
    const key = core.atom.atomFromUInt32(0);
    const value = try core.Object.create(rt, reentrant_id, null);
    const refs = try arguments.allocateMappedArgumentsVarRefsAssumingEmpty(rt, 1);
    const cell = try core.VarRef.createClosed(rt, value.value().dup());
    refs[0] = cell;
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
    try std.testing.expectEqual(@as(?i32, 7), arguments.argumentsVarRefs()[0].?.varRefValue().asInt32());
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 1), reentrant_mapped_arguments_calls);
    try std.testing.expectEqual(@as(?i32, 99), arguments.argumentsVarRefs()[0].?.varRefValue().asInt32());
}

test "mapped arguments var-ref binding update defers value finalizer reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const reentrant_id = try rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(reentrant_id, .{
        .class_name = "ReentrantMappedArgumentsVarRefSet",
        .payload_finalizer = reentrantMappedArgumentsFinalizer,
    });

    const arguments = try core.Object.create(rt, core.class.ids.mapped_arguments, null);
    defer arguments.value().free(rt);
    const key = core.atom.atomFromUInt32(0);
    const value = try core.Object.create(rt, reentrant_id, null);
    const cell = try core.VarRef.createClosed(rt, value.value().dup());
    const refs = try arguments.allocateMappedArgumentsVarRefsAssumingEmpty(rt, 1);
    refs[0] = cell;
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
    try std.testing.expectEqual(@as(?i32, 7), cell.varRefValue().asInt32());
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 1), reentrant_mapped_arguments_calls);
    try std.testing.expectEqual(@as(?i32, 99), cell.varRefValue().asInt32());
}

test "mapped arguments binding delete defers value finalizer reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const reentrant_id = try rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(reentrant_id, .{
        .class_name = "ReentrantMappedArgumentsDelete",
        .payload_finalizer = reentrantMappedArgumentsFinalizer,
    });

    const arguments = try core.Object.create(rt, core.class.ids.mapped_arguments, null);
    defer arguments.value().free(rt);
    const key = core.atom.atomFromUInt32(0);
    const refs = try arguments.allocateMappedArgumentsVarRefsAssumingEmpty(rt, 1);
    try arguments.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(1), true, true, true));

    const value = try core.Object.create(rt, reentrant_id, null);
    const cell = try core.VarRef.createClosed(rt, value.value().dup());
    refs[0] = cell;
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
    try std.testing.expect(arguments.argumentsVarRefs()[0] == null);
    var before_cleanup = try arguments.getProperty(key);
    defer before_cleanup.free(rt);
    try std.testing.expect(before_cleanup.isUndefined());
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 1), reentrant_mapped_arguments_calls);
    try std.testing.expect(arguments.argumentsVarRefs()[0] == null);
    const after = try arguments.getProperty(key);
    defer after.free(rt);
    try std.testing.expectEqual(@as(?i32, 99), after.asInt32());
}

test "cached iterator next clear defers value finalizer reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const reentrant_id = try rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(reentrant_id, .{
        .class_name = "ReentrantCachedIteratorNextClear",
        .payload_finalizer = reentrantCachedIteratorNextFinalizer,
    });

    const object = try core.Object.create(rt, core.class.ids.iterator, null);
    defer object.value().free(rt);
    const value = try core.Object.create(rt, reentrant_id, null);
    (try object.cachedIteratorNextSlot(rt)).* = value.value().dup();
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
    try std.testing.expect(object.cachedIteratorNext(rt) == null);
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 1), reentrant_cached_iterator_next_calls);
    try std.testing.expect(object.cachedIteratorNext(rt) == null);
}

test "exception slot clear defers value finalizer reentry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const reentrant_id = try rt.newClassId(core.class.invalid_class_id);
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

    const reentrant_id = try rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(reentrant_id, .{
        .class_name = "ReentrantArrayIteratorTargetClear",
        .payload_finalizer = reentrantArrayIteratorFinalizer,
    });

    const iterator = try core.Object.create(rt, core.class.ids.array_iterator, null);
    defer iterator.value().free(rt);
    const target = try core.Object.createArray(rt, null);
    const held = try core.Object.create(rt, reentrant_id, null);
    const held_key = try rt.internAtom("held");
    defer rt.atoms.free(held_key);
    try target.defineOwnProperty(rt, held_key, core.Descriptor.data(held.value(), true, true, true));
    held.value().free(rt);
    iterator.iteratorTargetSlot().* = target.value().dup();
    target.value().free(rt);

    payload_finalizer_calls = 0;
    reentrant_array_iterator_target = iterator;
    reentrant_array_iterator_calls = 0;
    defer {
        reentrant_array_iterator_target = null;
        reentrant_array_iterator_calls = 0;
    }

    const result = try engine.exec.array_builtin_ops.methodCall(rt, iterator.value(), 20, &.{});
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

    const payloadless_id = try rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(payloadless_id, .{
        .class_name = "PayloadlessInCycle",
        .payload_finalizer = countPayloadFinalizer,
    });
    const external_id = try rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(external_id, .{
        .class_name = "ExternalPayloadInCycle",
        .payload_finalizer = finalizeTestExternalPayload,
        .payload_mark = markTestExternalPayload,
    });

    const payloadless = try core.Object.create(rt, payloadless_id, null);
    const external = try core.Object.create(rt, external_id, null);
    const payload = try rt.memory.create(TestExternalPayload);
    payload.* = .{ .value = payloadless.value().dup() };
    external.u.payload = @ptrCast(payload);

    const key = try rt.internAtom("external");
    defer rt.atoms.free(key);
    try payloadless.defineOwnProperty(rt, key, core.Descriptor.data(external.value(), true, true, true));

    payload_finalizer_calls = 0;
    payload_mark_calls = 0;
    external.value().free(rt);
    payloadless.value().free(rt);
    rt.classes.unregisterDynamic(payloadless_id);
    rt.classes.unregisterDynamic(external_id);
    try std.testing.expect(rt.classes.unregisterPending(payloadless_id));
    try std.testing.expect(rt.classes.unregisterPending(external_id));

    try std.testing.expectEqual(@as(usize, 4), rt.runObjectCycleRemoval());
    try std.testing.expect(payload_mark_calls > 0);
    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 2), rt.pendingDeferredClassPayloadFinalizerCountForTest());
    try std.testing.expectEqual(@as(usize, 2), rt.runDeferredClassPayloadFinalizerBudgeted(2));
    try std.testing.expectEqual(@as(usize, 2), payload_finalizer_calls);
    try std.testing.expect(!rt.classes.isRegistered(payloadless_id));
    try std.testing.expect(!rt.classes.isRegistered(external_id));
}

test "pending class payload finalizers trace payload value roots" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const external_id = try rt.newClassId(core.class.invalid_class_id);
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
    wrapper.u.payload = @ptrCast(payload);

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

test "deferred payload callback pins the old generation through unregister" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const class_id = try rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(class_id, .{
        .class_name = "DeferredDefinitionPin",
        .payload_finalizer = finalizeTestExternalPayload,
        .payload_mark = markTestExternalPayload,
    });

    const wrapper = try core.Object.create(rt, class_id, null);
    const old_generation = rt.classes.destructionPlan(class_id).?.generation;
    const child = try core.Object.create(rt, core.class.ids.object, null);
    const child_header = &child.header;
    const payload = try rt.memory.create(TestExternalPayload);
    payload.* = .{ .value = child.value().dup() };
    wrapper.u.payload = @ptrCast(payload);
    child.value().free(rt);

    payload_finalizer_calls = 0;
    payload_mark_calls = 0;
    wrapper.value().free(rt);
    try expectOneDeferredClassPayloadFinalizer(rt);
    rt.classes.unregisterDynamic(class_id);
    try std.testing.expect(rt.classes.isRegistered(class_id));
    try std.testing.expect(rt.classes.unregisterPending(class_id));

    const Counter = struct {
        expected: *core.gc.Header,
        count: usize = 0,

        fn visitValue(context: *anyopaque, slot: *core.JSValue) core.runtime.RootTraceError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (slot.refHeader()) |header| {
                if (header == self.expected) self.count += 1;
            }
        }

        fn visitObject(_: *anyopaque, _: *?*core.Object) core.runtime.RootTraceError!void {}
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

    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expect(!rt.classes.isRegistered(class_id));
    try std.testing.expect(!rt.classes.unregisterPending(class_id));

    try rt.classes.register(class_id, .{ .class_name = "DeferredDefinitionPinRetry" });
    var next_generation = try rt.classes.beginConstruction(class_id);
    defer next_generation.abort();
    try std.testing.expect(next_generation.definition.generation != old_generation);
    rt.classes.unregisterDynamic(class_id);
}

test "runtime cycle removal clears class payload object slots before finalizers" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const external_id = try rt.newClassId(core.class.invalid_class_id);
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
    external.u.payload = @ptrCast(payload);

    const key = try rt.internAtom("external");
    defer rt.atoms.free(key);
    try child.defineOwnProperty(rt, key, core.Descriptor.data(external.value(), true, true, true));

    payload_finalizer_calls = 0;
    payload_mark_calls = 0;
    external.value().free(rt);
    child.value().free(rt);

    try std.testing.expectEqual(@as(usize, 4), rt.runObjectCycleRemoval());
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

    try std.testing.expectEqual(null, object.u.payload);
    try std.testing.expectEqual(core.class.PayloadKind.none, object.flags.class_payload_kind);
    try std.testing.expect(@sizeOf(core.Object) <= core.Object.post_a_object_size_baseline / 2);
}

test "iterator classes store iterator state in class payload" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const iterator = try core.Object.create(rt, core.class.ids.array_iterator, null);
    defer iterator.value().free(rt);

    try std.testing.expect(iterator.u.payload != null);
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

    try std.testing.expect(map.u.payload != null);
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
    try std.testing.expect(buffer.u.payload != null);
    try std.testing.expectEqual(core.class.PayloadKind.buffer, buffer.flags.class_payload_kind);
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
    try std.testing.expect(view.u.payload != null);
    try std.testing.expectEqual(core.class.PayloadKind.typed_array, view.flags.class_payload_kind);
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

    const right_value = try engine.exec.buffer_ops.sharedArrayBufferFromStore(right_rt, store, null, null);
    defer right_value.free(right_rt);
    const right_header = right_value.refHeader() orelse return error.TestExpectedEqual;
    const right: *core.Object = @fieldParentPtr("header", right_header);

    left.byteStorage()[0] = 77;
    try std.testing.expectEqual(@as(u8, 77), right.byteStorage()[0]);
}

test "array buffer backing stores report external memory" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const buffer_value = try engine.exec.buffer_ops.arrayBufferConstructLength(rt, 16, 32, null);
    try std.testing.expectEqual(@as(usize, 16), rt.externalMemoryBytes());

    const resize_result = try engine.exec.buffer_ops.arrayBufferResizeLength(rt, buffer_value, 8);
    resize_result.free(rt);
    try std.testing.expectEqual(@as(usize, 8), rt.externalMemoryBytes());

    const detach_result = try engine.exec.buffer_ops.detachArrayBuffer(rt, buffer_value);
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

    const ctx = try core.JSContext.create(&rt);
    defer ctx.destroy();

    try rt.job_queue.enqueuePromise(ctx, core.JSValue.int32(101));

    const TestJob = struct {
        fn run(_: *core.JSContext, _: []const core.JSValue) core.JSValue {
            return core.JSValue.undefinedValue();
        }
    };
    try rt.job_queue.enqueueFunc(ctx, TestJob.run, &.{core.JSValue.int32(106)});
    try rt.enqueueFinalizationJobForRealm(ctx, core.JSValue.int32(107), core.JSValue.int32(108));

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

test "regexp internals use inline storage and lastIndex uses first shape slot" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const source = try core.string.String.createAscii(rt, "a+");
    defer source.value().free(rt);

    const regexp = try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.regexp, null, 1);
    defer regexp.value().free(rt);

    try std.testing.expectEqual(core.class.PayloadKind.regexp, regexp.flags.class_payload_kind);
    try regexp.initializeRegExpLastIndex(rt);
    try regexp.setRegexpSource(rt, source.value());
    try regexp.setRegexpCompiledBytecode(rt, &.{ 1, 2, 3 });
    try regexp.defineOwnProperty(
        rt,
        core.atom.ids.lastIndex,
        core.Descriptor.data(core.JSValue.int32(3), false, false, false),
    );

    try std.testing.expect(regexp.regexpSource() != null);
    try std.testing.expectEqual(@as(usize, 3), regexp.regexpCompiledBytecode().len);
    try std.testing.expectEqual(core.atom.ids.lastIndex, regexp.propAtomAt(0));
    try std.testing.expectEqual(@as(?i32, 3), regexp.regexpLastIndex().?.asInt32());
    try std.testing.expect(!regexp.regexpLastIndexWritable());
}

test "bound function state uses payload storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const bound = try core.Object.create(rt, core.class.ids.bound_function, null);
    defer bound.value().free(rt);

    try std.testing.expect(bound.u.payload != null);
    try std.testing.expectEqual(core.class.PayloadKind.bound_function, bound.flags.class_payload_kind);
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

    const proxy = try core.Object.create(rt, core.class.ids.proxy, null);
    defer proxy.value().free(rt);
    try proxy.ensureProxyPayload(rt);

    try std.testing.expect(proxy.u.payload != null);
    try std.testing.expectEqual(core.class.PayloadKind.proxy, proxy.flags.class_payload_kind);
    proxy.proxyTargetSlot().* = core.JSValue.int32(55);
    proxy.proxyHandlerSlot().* = core.JSValue.int32(66);

    try std.testing.expectEqual(@as(?i32, 55), proxy.proxyTarget().?.asInt32());
    try std.testing.expectEqual(@as(?i32, 66), proxy.proxyHandler().?.asInt32());
}

test "mapped arguments state uses inline var-ref storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const arguments = try core.Object.create(rt, core.class.ids.mapped_arguments, null);
    defer arguments.value().free(rt);

    try std.testing.expectEqual(core.class.PayloadKind.none, arguments.flags.class_payload_kind);
    const refs = try arguments.allocateMappedArgumentsVarRefsAssumingEmpty(rt, 2);
    refs[0] = try core.VarRef.createClosed(rt, core.JSValue.int32(77));
    refs[1] = try core.VarRef.createClosed(rt, core.JSValue.int32(88));

    try std.testing.expectEqual(@intFromPtr(refs.ptr), @intFromPtr(arguments.u.array.values));
    try std.testing.expect(arguments.externalClassPayload() == null);
    try std.testing.expectEqual(@as(usize, 2), arguments.argumentsVarRefs().len);
    try std.testing.expectEqual(@as(?i32, 77), arguments.argumentsVarRefs()[0].?.varRefValue().asInt32());
    try std.testing.expectEqual(@as(?i32, 88), arguments.argumentsVarRefs()[1].?.varRefValue().asInt32());
}

test "unmapped arguments share a prepared shape and use dense element storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const template = try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.arguments, null, 3);
    defer template.value().free(rt);
    try template.defineOwnPropertyAssumingNew(
        rt,
        core.atom.ids.length,
        core.Descriptor.data(core.JSValue.int32(0), true, false, true),
    );
    const iterator_key = comptime core.atom.predefinedId("Symbol.iterator", .symbol).?;
    try template.defineOwnPropertyAssumingNew(
        rt,
        iterator_key,
        core.Descriptor.data(core.JSValue.int32(17), true, false, true),
    );
    const callee_key = comptime core.atom.predefinedId("callee", .string).?;
    try template.defineOwnPropertyAssumingNew(
        rt,
        callee_key,
        core.Descriptor.accessor(core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), false, false),
    );

    const arguments = try core.Object.createFromPropertyTemplate(rt, template);
    defer arguments.value().free(rt);
    try std.testing.expectEqual(template.shape_ref, arguments.shape_ref);
    try std.testing.expectEqual(core.class.ids.arguments, arguments.class_id);
    try std.testing.expectEqual(core.class.PayloadKind.none, arguments.flags.class_payload_kind);
    try std.testing.expect(!arguments.isArray());

    arguments.replaceOwnDataPropertyValueAtAssumingShapeOwned(rt, 0, core.JSValue.int32(2));
    const elements = try rt.memory.alloc(core.JSValue, 2);
    elements[0] = core.JSValue.int32(31);
    elements[1] = core.JSValue.int32(32);
    arguments.adoptDenseUnmappedArgumentsElementsAssumingEmpty(rt, elements);

    try std.testing.expect(arguments.flags.fast_array);
    try std.testing.expectEqual(core.object.ArrayStorageMode.dense, arguments.arrayElementStorageMode());
    try std.testing.expectEqual(@as(?i32, 2), (try arguments.getProperty(core.atom.ids.length)).asInt32());
    try std.testing.expectEqual(@as(?i32, 31), (try arguments.getProperty(core.atom.atomFromUInt32(0))).asInt32());
    try std.testing.expectEqual(@as(?i32, 32), (try arguments.getProperty(core.atom.atomFromUInt32(1))).asInt32());
    try std.testing.expect(arguments.externalClassPayload() == null);

    // Redefining a dense numeric property materializes the run into ordinary
    // shape entries, exactly like qjs's arguments define-own-property exotic.
    try arguments.defineOwnProperty(
        rt,
        core.atom.atomFromUInt32(1),
        core.Descriptor.data(core.JSValue.int32(41), false, false, false),
    );
    try std.testing.expect(!arguments.flags.fast_array);
    try std.testing.expectEqual(@as(?i32, 31), (try arguments.getProperty(core.atom.atomFromUInt32(0))).asInt32());
    try std.testing.expectEqual(@as(?i32, 41), (try arguments.getProperty(core.atom.atomFromUInt32(1))).asInt32());
    try std.testing.expectEqual(@as(?i32, 0), (try template.getProperty(core.atom.ids.length)).asInt32());
}

test "object data state uses payload storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.string, null);
    defer object.value().free(rt);

    const data = try core.string.String.createAscii(rt, "wrapped");
    defer data.value().free(rt);

    try std.testing.expect(object.u.payload != null);
    try std.testing.expectEqual(core.class.PayloadKind.object_data, object.flags.class_payload_kind);
    object.objectDataSlot().* = data.value().dup();
    try std.testing.expect(object.objectData() != null);
}

test "array element state uses inline fast-array storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const array = try core.Object.createArray(rt, null);
    defer array.value().free(rt);

    try std.testing.expectEqual(@as(u32, 0), array.u.array.count);
    try std.testing.expectEqual(@as(u32, 0), array.u.array.capacity);
    try std.testing.expectEqual(core.class.PayloadKind.none, array.flags.class_payload_kind);
    try std.testing.expect(array.flags.fast_array);
    try std.testing.expectEqual(core.object.ArrayStorageMode.dense, array.arrayElementStorageMode());
    try std.testing.expect(try array.appendDenseArrayIndex(rt, 0, core.atom.atomFromUInt32(0), core.JSValue.int32(7)));
    try std.testing.expectEqual(@as(usize, 1), array.arrayElements().len);
    try std.testing.expectEqual(@as(?i32, 7), array.arrayElements()[0].asInt32());
}

test "promise state uses payload storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    defer promise.value().free(rt);

    try std.testing.expect(promise.u.payload != null);
    try std.testing.expectEqual(core.class.PayloadKind.promise, promise.flags.class_payload_kind);
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

    try std.testing.expect(generator.u.payload != null);
    try std.testing.expectEqual(core.class.PayloadKind.generator, generator.flags.class_payload_kind);
    generator.generatorThisSlot().* = core.JSValue.int32(404);
    const args = try rt.memory.alloc(core.JSValue, 1);
    args[0] = core.JSValue.int32(505);
    const stack_values = try rt.memory.alloc(core.JSValue, 1);
    stack_values[0] = core.JSValue.int32(606);
    var replacement = core.object.SuspendedExecutionStorage{
        .stack = .{ .values = stack_values },
        .frame = .{ .args = args },
    };
    generator.generatorExecutionStateSlot().replaceStorageOwned(12, std.math.maxInt(u32), &replacement, rt);
    try std.testing.expect(replacement.isEmpty());
    generator.generatorDoneSlot().* = true;
    generator.generatorExecutingSlot().* = true;
    generator.generatorStartedSlot().* = true;
    generator.generatorJustYieldedSlot().* = true;

    try std.testing.expectEqual(@as(?i32, 404), generator.generatorThis().?.asInt32());
    try std.testing.expectEqual(@as(usize, 1), generator.generatorArgs().len);
    try std.testing.expectEqual(@as(?i32, 505), generator.generatorArgs()[0].asInt32());
    try std.testing.expectEqual(@as(usize, 12), generator.generatorPc());
    try generator.generatorExecutionStateSlot().storage.stack.ensureAdditional(rt, 8, 1);
    try std.testing.expectEqual(@as(?i32, 606), generator.generatorExecutionState().storage.stack.values[0].asInt32());
    var moved: core.object.SuspendedExecutionStorage = .{};
    generator.generatorExecutionStateSlot().storage.moveInto(&moved);
    defer moved.deinit(rt);
    try std.testing.expect(generator.generatorExecutionState().storage.isEmpty());
    try std.testing.expectEqual(@as(usize, 12), generator.generatorPc());
    try std.testing.expectEqual(@as(?i32, 606), moved.stack.values[0].asInt32());
    try std.testing.expect(generator.generatorDone());
    try std.testing.expect(generator.generatorExecuting());
    try std.testing.expect(generator.generatorStarted());
    try std.testing.expect(generator.generatorJustYielded());
}

test "generator bound and proxy payloads carry no realm compensation" {
    try std.testing.expect(!@hasField(core.object.GeneratorPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(core.object.GeneratorPayload, "borrowed_holder_index_lo"));
    try std.testing.expect(!@hasField(core.object.GeneratorPayload, "borrowed_holder_index_mid"));
    try std.testing.expect(!@hasField(core.object.GeneratorPayload, "borrowed_holder_index_hi"));
    try std.testing.expect(!@hasField(core.object.BoundFunctionPayload, "realm_global"));
    try std.testing.expect(!@hasField(core.object.BoundFunctionPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(core.object.ProxyPayload, "realm_global_ptr"));
}

test "leaf noncarrier payloads carry no borrowed realm compensation" {
    try std.testing.expect(!@hasField(core.object.OrdinaryPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(core.object.ObjectDataPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(core.object.OrdinaryPayload, "typed_array_array_buffer_prototype"));
    try std.testing.expect(!@hasField(core.object.FunctionRarePayload, "primitive_prototypes"));
    try std.testing.expect(!@hasField(core.object.FunctionRarePayload, "realm_type_error_constructor"));
    try std.testing.expect(!@hasField(core.object.BufferPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(core.object.ArgumentsPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(core.object.VarRefPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(core.object.StdFilePayload, "realm_global_ptr"));
    try std.testing.expectEqual(core.class.PayloadKind.none, core.class.standardPayloadKind(core.class.ids.module_ns));
    try std.testing.expect(!@hasField(core.object.PromisePayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(core.object.WeakRefPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(core.object.RegExpPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(core.object.TypedArrayPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(core.object.IteratorPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(core.object.CollectionPayload, "realm_global_ptr"));
    try std.testing.expect(!@hasField(core.object.DisposableStackPayload, "realm_global_ptr"));
}

test "object payloads carry no private-name remap side tables" {
    try std.testing.expect(!@hasField(core.object.OrdinaryPayload, "private_remap_from"));
    try std.testing.expect(!@hasField(core.object.OrdinaryPayload, "private_remap_to"));
    try std.testing.expect(!@hasField(core.object.FunctionRarePayload, "private_remap_from"));
    try std.testing.expect(!@hasField(core.object.FunctionRarePayload, "private_remap_to"));
    try std.testing.expect(!@hasField(core.object.FunctionRarePayload, "super_constructor"));
}

test "generator completion eagerly releases the resident execution owners" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const current_function = try core.Object.create(rt, core.class.ids.object, null);
    defer current_function.value().free(rt);
    const this_object = try core.Object.create(rt, core.class.ids.object, null);
    defer this_object.value().free(rt);
    const delegate = try core.Object.create(rt, core.class.ids.object, null);
    defer delegate.value().free(rt);
    const generator = try core.Object.create(rt, core.class.ids.generator, null);
    defer generator.value().free(rt);

    generator.setGeneratorCurrentFunction(rt, current_function.value().dup());
    generator.setGeneratorThis(rt, this_object.value().dup());
    generator.setGeneratorYieldStarIterator(rt, delegate.value().dup());
    generator.generatorActualArgCountSlot().* = 1;
    generator.generatorJustYieldedSlot().* = true;
    generator.generatorYieldStarSuspendedSlot().* = true;
    generator.generatorResumeCompletionTypeSlot().* = 1;

    const args = try rt.memory.alloc(core.JSValue, 1);
    args[0] = core.JSValue.int32(11);
    const stack_values = try rt.memory.alloc(core.JSValue, 1);
    stack_values[0] = core.JSValue.int32(22);
    var replacement = core.object.SuspendedExecutionStorage{
        .stack = .{ .values = stack_values },
        .frame = .{ .args = args },
    };
    generator.generatorExecutionStateSlot().replaceStorageOwned(17, 23, &replacement, rt);

    try std.testing.expect(!rt.borrowedReferenceHolderRegistered(generator));
    try std.testing.expect(generator.generatorExecutionState().has_frame);
    generator.completeGeneratorExecution(rt);

    try std.testing.expect(generator.generatorDone());
    try std.testing.expect(!generator.generatorExecutionState().has_frame);
    try std.testing.expect(generator.generatorExecutionState().storage.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), generator.generatorPc());
    try std.testing.expect(generator.generatorExecutionState().catchTarget() == null);
    try std.testing.expectEqual(@as(usize, 0), generator.generatorActualArgCount());
    try std.testing.expectEqual(@as(usize, 0), generator.generatorArgs().len);
    try std.testing.expect(generator.generatorThis() == null);
    try std.testing.expect(generator.generatorCurrentFunction() == null);
    try std.testing.expect(generator.generatorYieldStarIterator() == null);
    try std.testing.expect(!generator.generatorJustYielded());
    try std.testing.expect(!generator.generatorYieldStarSuspended());
    try std.testing.expectEqual(@as(i32, 0), generator.generatorResumeCompletionType());
    try std.testing.expect(generator.generatorFunctionRealmGlobalPtr() == null);
    try std.testing.expect(!rt.borrowedReferenceHolderRegistered(generator));

    // Async-generator completion can reach the same boundary after the VM
    // return handler already did; the ownership endpoint must stay idempotent.
    generator.completeGeneratorExecution(rt);
    try std.testing.expect(generator.generatorExecutionState().storage.isEmpty());
}

test "suspended execution preserves and closes open frame var refs" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const pointer_value_slots = try std.math.divCeil(usize, @sizeOf(?*core.VarRef), @sizeOf(core.JSValue));
    const storage = try rt.memory.alloc(core.JSValue, 1 + pointer_value_slots);
    var storage_is_standalone = true;
    defer if (storage_is_standalone) rt.memory.free(core.JSValue, storage);
    storage[0] = core.JSValue.int32(707);
    const open_bytes = std.mem.sliceAsBytes(storage[1..]);
    const open_var_refs: []?*core.VarRef = @alignCast(std.mem.bytesAsSlice(
        ?*core.VarRef,
        open_bytes[0..@sizeOf(?*core.VarRef)],
    ));

    const cell = try core.VarRef.createOpen(rt, &storage[0]);
    const retained_cell = cell.dupCell();
    defer retained_cell.freeCell(rt);
    open_var_refs[0] = cell;

    var suspended = core.object.SuspendedExecutionStorage{
        .frame = .{
            .storage = storage,
            .locals = storage[0..1],
            .open_var_refs = open_var_refs,
        },
    };
    storage_is_standalone = false;
    defer suspended.deinit(rt);

    try std.testing.expect(cell.is_open);
    try std.testing.expectEqual(@as(?i32, 707), cell.varRefValue().asInt32());
    suspended.deinit(rt);
    try std.testing.expect(suspended.isEmpty());
    try std.testing.expect(!cell.is_open);
    try std.testing.expectEqual(@as(?i32, 707), cell.varRefValue().asInt32());
}

test "suspended execution republishes running aliases without a second owner" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const values = try rt.memory.alloc(core.JSValue, 2);
    values[0] = core.JSValue.int32(11);
    values[1] = core.JSValue.int32(22);
    var state: core.object.SuspendedExecutionState = .{};
    defer state.deinit(rt);
    var initial = core.object.SuspendedExecutionStorage{
        .stack = .{ .values = values[0..1], .capacity = values.len },
    };
    state.replaceStorageOwned(7, 3, &initial, rt);
    state.beginRunningAliases();

    var resuspended = core.object.SuspendedExecutionStorage{
        .stack = .{ .values = values, .capacity = values.len },
    };
    state.replaceStorageOwned(9, 5, &resuspended, rt);
    try std.testing.expect(!state.running_aliases);
    try std.testing.expect(resuspended.isEmpty());
    try std.testing.expectEqual(@as(usize, 9), state.pc);
    try std.testing.expectEqual(@as(?usize, 5), state.catchTarget());
    try std.testing.expectEqual(@intFromPtr(values.ptr), @intFromPtr(state.storage.stack.values.ptr));
    try std.testing.expectEqual(@as(usize, 2), state.storage.stack.values.len);

    state.beginRunningAliases();
    var live_owner = state.storage;
    state.finishRunningAliases();
    try std.testing.expect(state.storage.isEmpty());
    try std.testing.expect(state.catchTarget() == null);
    live_owner.deinit(rt);
}

test "native function state uses payload storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.RealmContext.create(rt);
    defer ctx.destroy();
    const home = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try home.ensureGlobalPayload(rt);
    ctx.global = home;
    const function = try core.Object.create(rt, core.class.ids.c_function, null);
    function.setNativeFunctionRealm(ctx);
    defer function.value().free(rt);
    const source = try core.string.String.createAscii(rt, "function f(){}");
    defer source.value().free(rt);

    try std.testing.expect(function.u.payload != null);
    try std.testing.expectEqual(core.class.PayloadKind.function, function.flags.class_payload_kind);
    (try function.functionSourceSlot(rt)).* = source.value().dup();
    function.hostFunctionKindSlot().* = 11;
    function.nativeFunctionIdSlot().* = 22;
    (try function.functionRealmGlobalSlot(rt)).* = home.value().dup();

    try std.testing.expect(function.functionSource() != null);
    try std.testing.expectEqual(@as(i32, 11), function.hostFunctionKind());
    try std.testing.expectEqual(@as(i32, 22), function.nativeFunctionId());
    try std.testing.expect(function.functionBytecode() == null);
    try std.testing.expectEqual(@as(usize, 0), function.functionCaptures().len);
    try std.testing.expect(function.functionHomeObject() == null);
    try std.testing.expect(function.functionRealmGlobal() != null);
    try std.testing.expectEqual(ctx, function.nativeFunctionRealm().?);
    try std.testing.expectEqual(home, function.functionRealmGlobalPtr().?);
}

test "true C functions own their construction realm while data functions do not" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.RealmContext.create(rt);
    const function_proto = try core.Object.create(rt, core.class.ids.object, null);
    ctx.cached_function_proto = function_proto;
    const native = try engine.core.function.nativeFunction(ctx, "native", 0);
    const data = try engine.core.function.nativeDataFunctionWithPrototype(rt, function_proto, "data", 1);

    const native_object: *core.Object = @fieldParentPtr("header", native.refHeader().?);
    const data_object: *core.Object = @fieldParentPtr("header", data.refHeader().?);
    try std.testing.expectEqual(core.class.ids.c_function, native_object.class_id);
    try std.testing.expectEqual(ctx, native_object.nativeFunctionRealm().?);
    try std.testing.expectEqual(core.class.ids.c_function_data, data_object.class_id);
    try std.testing.expect(data_object.nativeFunctionRealm() == null);
    try std.testing.expectEqual(function_proto, native_object.getPrototype().?);
    try std.testing.expectEqual(function_proto, data_object.getPrototype().?);

    const data_name = (try data_object.getOwnProperty(rt, core.atom.ids.name)).?;
    defer data_name.destroy(rt);
    try std.testing.expect(data_name.value.asStringBody().?.eqlBytes("data"));
    try std.testing.expectEqual(false, data_name.writable.?);
    try std.testing.expectEqual(false, data_name.enumerable.?);
    try std.testing.expectEqual(true, data_name.configurable.?);

    const data_length = (try data_object.getOwnProperty(rt, core.atom.ids.length)).?;
    defer data_length.destroy(rt);
    try std.testing.expectEqual(@as(?i32, 1), data_length.value.asInt32());
    try std.testing.expectEqual(false, data_length.writable.?);
    try std.testing.expectEqual(false, data_length.enumerable.?);
    try std.testing.expectEqual(true, data_length.configurable.?);

    // The DATA carrier has no direct RealmRef. Its ordinary prototype edge is
    // still a real JS graph edge, so release it before isolating the native
    // function's direct construction-realm ownership below.
    data.free(rt);
    ctx.destroy();
    try std.testing.expectEqual(ctx, rt.firstContext().?);
    native.free(rt);
    try std.testing.expect(rt.firstContext() == null);
}

test "bytecode function state uses the inline qjs function arm" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const home = try core.Object.create(rt, core.class.ids.object, null);
    defer home.value().free(rt);
    const function = try core.Object.create(rt, core.class.ids.bytecode_function, null);
    defer function.value().free(rt);

    try std.testing.expectEqual(core.class.PayloadKind.function, function.flags.class_payload_kind);
    const fb = try engine.bytecode.FunctionBytecode.createFixture(rt, .{ .closure_var_count = 1 });
    fb.closureVar()[0] = engine.bytecode.function_bytecode.BytecodeClosureVar.init(.{
        .closure_type = .ref,
        .var_idx = 0,
        .var_name = rt.atoms.dup(core.atom.ids.empty_string),
    });
    fb.publishFixtureNoFail(rt);
    const attach_alloc_calls = rt.memory.alloc_calls;
    const attach_create_calls = rt.memory.create_calls;
    try function.setFunctionBytecodeValue(rt, core.JSValue.functionBytecode(&fb.header));
    try std.testing.expectEqual(attach_alloc_calls, rt.memory.alloc_calls);
    try std.testing.expectEqual(attach_create_calls, rt.memory.create_calls);
    try std.testing.expectEqual(fb, function.bytecodeFunctionStoragePtr().function_bytecode.?);
    try std.testing.expect(!@hasField(engine.bytecode.FunctionBytecode, "cached_view"));
    const captures = try rt.memory.alloc(*core.VarRef, 1);
    captures[0] = try core.VarRef.createClosed(rt, core.JSValue.int32(55));
    function.setFunctionCaptures(rt, captures);
    try function.setFunctionHomeObject(rt, home);

    try std.testing.expectEqual(@as(i32, 0), function.hostFunctionKind());
    try std.testing.expectEqual(@as(i32, 0), function.nativeFunctionId());
    try std.testing.expect(function.functionBytecode() != null);
    try std.testing.expectEqual(@as(?i32, 55), function.functionCaptures()[0].varRefValue().asInt32());
    try std.testing.expectEqual(home, function.functionHomeObject().?);
}

test "module namespace uses shape-only live-binding storage" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const namespace = try core.Object.create(rt, core.class.ids.module_ns, null);
    defer namespace.value().free(rt);
    const export_name = try rt.internAtom("value");
    defer rt.atoms.free(export_name);

    const cell = try core.VarRef.createClosed(rt, core.JSValue.int32(17));
    cell.is_const = true;
    try namespace.defineModuleVarRefProperty(rt, export_name, cell);
    namespace.preventExtensions();

    try std.testing.expect(namespace.u.payload == null);
    try std.testing.expectEqual(core.class.PayloadKind.none, namespace.flags.class_payload_kind);
    try std.testing.expectEqual(@as(usize, 1), namespace.shape_ref.prop_count);
    try std.testing.expectEqual(core.property.Kind.var_ref, namespace.propKindAt(0));
    try std.testing.expectEqual(cell, namespace.prop_values[0].slot.var_ref);

    const desc = (try namespace.getOwnProperty(rt, export_name)).?;
    defer desc.destroy(rt);
    try std.testing.expectEqual(@as(?bool, true), desc.writable);
    try std.testing.expectEqual(@as(?bool, true), desc.enumerable);
    try std.testing.expectEqual(@as(?bool, false), desc.configurable);
    try std.testing.expectEqual(@as(?i32, 17), desc.value.asInt32());

    try std.testing.expectError(error.ReadOnly, namespace.setProperty(rt, export_name, core.JSValue.int32(18)));
    try namespace.defineOwnProperty(rt, export_name, core.Descriptor.data(core.JSValue.int32(17), true, true, false));
    try std.testing.expectError(
        error.ReadOnly,
        namespace.defineOwnProperty(rt, export_name, core.Descriptor.data(core.JSValue.int32(18), true, true, false)),
    );
    try std.testing.expect(!namespace.deleteProperty(rt, export_name));
}

test "shapes retain property atoms and compare transitions" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name_atom = try rt.internAtom("shapeProp");
    var first = try rt.shapes.create(null);
    var second = try rt.shapes.create(null);
    try rt.shapes.addProperty(&first, name_atom, 0b000011);
    try rt.shapes.addProperty(&second, name_atom, 0b000011);
    rt.atoms.free(name_atom);

    try std.testing.expect(first.is_hashed);
    try std.testing.expectEqual(@as(usize, 1), first.prop_count);
    try std.testing.expect(first.sameTransition(second));
    try std.testing.expect(rt.atoms.name(first.props()[0].atom_id) != null);
    try std.testing.expectEqual(
        core.shape.hashIndex(first.hash, core.shape.initial_shape_hash_bits),
        core.shape.hashIndex(first.hash, rt.shapes.shape_hash_bits),
    );

    rt.shapes.release(first);
    try std.testing.expect(rt.atoms.name(second.props()[0].atom_id) != null);
    rt.shapes.release(second);
    try std.testing.expectEqual(@as(usize, 0), rt.shapes.shape_hash_count);
}

test "shape refcounts and prototype transitions are tracked" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name_atom = try rt.internAtom("shapeProtoProp");
    defer rt.atoms.free(name_atom);

    const proto_one = try core.Object.create(rt, core.class.ids.object, null);
    defer proto_one.value().free(rt);
    const proto_two = try core.Object.create(rt, core.class.ids.object, null);
    defer proto_two.value().free(rt);
    const shape_hash_baseline = rt.shapes.shape_hash_count;
    var first = try rt.shapes.create(proto_one);
    var second = try rt.shapes.create(proto_two);
    try rt.shapes.addProperty(&first, name_atom, 0b000001);
    try rt.shapes.addProperty(&second, name_atom, 0b000001);
    try std.testing.expect(!first.sameTransition(second));

    first.retain();
    try std.testing.expectEqual(@as(usize, 2), first.refCount());
    rt.shapes.release(first);
    try std.testing.expectEqual(@as(usize, 1), first.refCount());
    rt.shapes.release(first);
    rt.shapes.release(second);
    try std.testing.expectEqual(shape_hash_baseline, rt.shapes.shape_hash_count);
}

test "restorePropertyLayout rebuilds a baseline layout after FAM relocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const flags: u6 = 0b000111; // data property: writable/enumerable/configurable
    const names = [_][]const u8{ "p0", "p1", "p2", "p3", "p4", "p5" };
    var atoms: [6]core.Atom = undefined;
    for (names, 0..) |name, i| atoms[i] = try rt.internAtom(name);
    defer for (atoms) |a| rt.atoms.free(a);

    var shape = try rt.shapes.create(null);
    // Six properties exceed the initial capacity (4), forcing at least one FAM
    // relocation (the shape pointer moves; addProperty threads &shape back).
    for (atoms) |a| try rt.shapes.addProperty(&shape, a, flags);
    try std.testing.expectEqual(@as(u32, 6), shape.prop_count);
    try std.testing.expect(shape.prop_size >= 6); // grew past the initial capacity of 4

    // Snapshot a two-property baseline (mirrors the shared-test-engine reset
    // that restores the post-install global layout, dropping user-added props).
    var baseline = [_]core.shape.Property{ shape.props()[0], shape.props()[1] };
    var baseline_hash = core.shape.initialHash(null);
    baseline_hash = core.shape.transitionHash(baseline_hash, atoms[0], flags);
    baseline_hash = core.shape.transitionHash(baseline_hash, atoms[1], flags);

    try rt.shapes.restorePropertyLayout(&shape, &baseline, baseline_hash, 0);

    try std.testing.expectEqual(@as(u32, 2), shape.prop_count);
    try std.testing.expectEqual(atoms[0], shape.props()[0].atom_id);
    try std.testing.expectEqual(atoms[1], shape.props()[1].atom_id);
    try std.testing.expectEqual(baseline_hash, shape.hash);
    // The rebuilt hash table resolves the retained properties (their buckets are
    // non-empty, so the bucket head is a real index).
    try std.testing.expect(shape.firstPropertyIndex(atoms[0]) != core.shape.no_property_index);
    try std.testing.expect(shape.firstPropertyIndex(atoms[1]) != core.shape.no_property_index);
    try std.testing.expect(rt.atoms.name(shape.props()[0].atom_id) != null);

    rt.shapes.release(shape);
}

test "shape registry release maintains hashed and live counts" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const hashed_baseline = rt.shapes.shape_hash_count;
    const live_baseline = rt.shapes.live_shape_count;

    const first = try rt.shapes.create(null);
    const second = try rt.shapes.create(null);
    const third = try rt.shapes.create(null);

    // Every created shape is both hashed and live (qjs counts hashed shapes only,
    // and zjs has no separate registry array — both are intrusive GC-list shapes).
    try std.testing.expectEqual(hashed_baseline + 3, rt.shapes.shape_hash_count);
    try std.testing.expectEqual(live_baseline + 3, rt.shapes.live_shape_count);

    rt.shapes.release(second);
    try std.testing.expectEqual(hashed_baseline + 2, rt.shapes.shape_hash_count);
    try std.testing.expectEqual(live_baseline + 2, rt.shapes.live_shape_count);

    rt.shapes.release(first);
    rt.shapes.release(third);
    try std.testing.expectEqual(hashed_baseline, rt.shapes.shape_hash_count);
    try std.testing.expectEqual(live_baseline, rt.shapes.live_shape_count);
}

test "shape registry hash grows and reuses object root shapes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var shapes: [70]*core.shape.Shape = undefined;
    for (&shapes) |*slot| {
        slot.* = try rt.shapes.create(null);
    }
    try std.testing.expect(rt.shapes.shape_hash_buckets.len >= 128);
    try std.testing.expect(rt.shapes.shape_hash_bits > core.shape.initial_shape_hash_bits);
    for (shapes) |shape| rt.shapes.release(shape);
    try std.testing.expectEqual(@as(usize, 0), rt.shapes.shape_hash_count);

    const first = try rt.shapes.createObjectRoot(null);
    const second = try rt.shapes.createObjectRoot(null);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 2), first.refCount());
    rt.shapes.release(first);
    rt.shapes.release(second);
    try std.testing.expectEqual(@as(usize, 0), rt.shapes.shape_hash_count);
}

test "reserved object root shapes reuse only an exact property capacity" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const four = try rt.shapes.createObjectRootWithPropertyCapacity(null, 4);
    const eight = try rt.shapes.createObjectRootWithPropertyCapacity(null, 8);
    const four_again = try rt.shapes.createObjectRootWithPropertyCapacity(null, 4);
    defer rt.shapes.release(four);
    defer rt.shapes.release(eight);
    defer rt.shapes.release(four_again);

    try std.testing.expectEqual(four, four_again);
    try std.testing.expect(four != eight);
    try std.testing.expectEqual(@as(u32, 4), four.prop_size);
    try std.testing.expectEqual(@as(u32, 8), eight.prop_size);

    const four_object = try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.object, null, 4);
    defer four_object.value().free(rt);
    const eight_object = try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.object, null, 8);
    defer eight_object.value().free(rt);
    try std.testing.expectEqual(@as(u32, 4), four_object.shape_ref.prop_size);
    try std.testing.expectEqual(@as(u32, 8), eight_object.shape_ref.prop_size);
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
    try std.testing.expectEqual(@as(usize, 2), first.shape_ref.prop_count);
    try std.testing.expectEqual(@as(?i32, 1), (try first.getProperty(a)).asInt32());
    try std.testing.expectEqual(@as(?i32, 4), (try second.getProperty(b)).asInt32());
}

test "unique transition shape appends in place across FAM relocation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    // A fresh prototype identity guarantees that this object's empty root shape
    // has no other owner. QuickJS mutates such rc==1 transition misses in place.
    const prototype = try core.Object.create(rt, core.class.ids.object, null);
    defer prototype.value().free(rt);
    const object = try core.Object.create(rt, core.class.ids.object, prototype);
    defer object.value().free(rt);

    const names = [_][]const u8{ "unique_0", "unique_1", "unique_2", "unique_3", "unique_4" };
    var atoms: [names.len]core.Atom = undefined;
    for (names, 0..) |name, index| atoms[index] = try rt.internAtom(name);
    defer for (atoms) |name| rt.atoms.free(name);

    const initial_shape = object.shape_ref;
    const initial_hashed_count = rt.shapes.shape_hash_count;
    for (atoms[0..4], 0..) |name, index| {
        try object.defineOwnProperty(
            rt,
            name,
            core.Descriptor.data(core.JSValue.int32(@intCast(index)), true, true, true),
        );
        try std.testing.expectEqual(initial_shape, object.shape_ref);
    }
    try std.testing.expectEqual(initial_hashed_count, rt.shapes.shape_hash_count);

    // The fifth append grows the inline FAM, so the allocation moves while the
    // logical shape ownership and hashed/live registry counts stay unchanged.
    const before_relocation = object.shape_ref;
    try object.defineOwnProperty(
        rt,
        atoms[4],
        core.Descriptor.data(core.JSValue.int32(4), true, true, true),
    );
    try std.testing.expect(before_relocation != object.shape_ref);
    try std.testing.expectEqual(initial_hashed_count, rt.shapes.shape_hash_count);
    try std.testing.expectEqual(@as(u32, atoms.len), object.shape_ref.prop_count);
    for (atoms, 0..) |name, index| {
        try std.testing.expectEqual(@as(?i32, @intCast(index)), (try object.getProperty(name)).asInt32());
        try std.testing.expect(object.shape_ref.firstPropertyIndex(name) != core.shape.no_property_index);
    }
}

test "first property append OOM restores the no-storage sentinel" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    // Two objects with the same fresh prototype share their empty shape. The
    // first property append therefore allocates the value buffer and then must
    // allocate a private transition shape.
    const prototype = try core.Object.create(rt, core.class.ids.object, null);
    defer prototype.value().free(rt);
    const object = try core.Object.create(rt, core.class.ids.object, prototype);
    defer object.value().free(rt);
    const peer = try core.Object.create(rt, core.class.ids.object, prototype);
    defer peer.value().free(rt);
    try std.testing.expectEqual(object.shape_ref, peer.shape_ref);

    const name = try rt.internAtom("first_property_oom");
    defer rt.atoms.free(name);

    // Permit exactly the first value-buffer allocation. The following shape
    // allocation must fail after prop_values has temporarily left its sentinel.
    const initial_value_bytes = @sizeOf(core.property.Entry) *
        core.shape.propertyCapacityForNeeded(1);
    rt.setMemoryLimit(rt.memory.allocated_bytes + initial_value_bytes);
    try std.testing.expectError(
        error.OutOfMemory,
        object.defineOwnProperty(rt, name, core.Descriptor.data(core.JSValue.int32(1), true, true, true)),
    );
    rt.setMemoryLimit(null);

    try std.testing.expect(!object.hasPropertyStorage());
    try std.testing.expectEqual(@as(u32, 0), object.shape_ref.prop_count);
    try std.testing.expect(!object.hasOwnProperty(name));

    // Retrying the same mutation proves the failed append restored a valid
    // empty-object state rather than leaving a dangling pseudo-allocation.
    try object.defineOwnProperty(rt, name, core.Descriptor.data(core.JSValue.int32(2), true, true, true));
    try std.testing.expectEqual(@as(?i32, 2), (try object.getProperty(name)).asInt32());
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
    const e = try rt.internAtom("rollback_e");
    defer rt.atoms.free(a);
    defer rt.atoms.free(b);
    defer rt.atoms.free(c);
    defer rt.atoms.free(d);

    try object.defineOwnProperty(rt, a, core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    try object.defineOwnProperty(rt, b, core.Descriptor.data(core.JSValue.int32(2), true, true, true));
    try object.defineOwnProperty(rt, c, core.Descriptor.data(core.JSValue.int32(3), true, true, true));
    try object.defineOwnProperty(rt, d, core.Descriptor.data(core.JSValue.int32(4), true, true, true));

    try std.testing.expectEqual(@as(usize, 4), object.shape_ref.prop_count);
    try std.testing.expectEqual(@as(usize, 4), object.shape_ref.props().len);

    const retained_refs = retained.header.meta().rc;
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, object.defineOwnProperty(rt, e, core.Descriptor.data(retained.value(), true, true, true)));
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(retained_refs, retained.header.meta().rc);
    try std.testing.expectEqual(@as(usize, 4), object.shape_ref.prop_count);
    try std.testing.expect(!object.hasOwnProperty(e));

    rt.atoms.free(e);
    try std.testing.expect(rt.atoms.name(e) == null);
}

test "unique shape append OOM rolls back shape and value storage together" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    // A unique prototype keeps the named-property transition on the rc==1
    // in-place path. Four tombstones force the fifth append to grow both the
    // property FAM and its deleted-inclusive hash table.
    const prototype = try core.Object.create(rt, core.class.ids.object, null);
    defer prototype.value().free(rt);
    const object = try core.Object.create(rt, core.class.ids.object, prototype);
    defer object.value().free(rt);

    const names = [_][]const u8{ "oom_shape_a", "oom_shape_b", "oom_shape_c", "oom_shape_d", "oom_shape_e" };
    var atoms: [names.len]core.Atom = undefined;
    for (names, 0..) |name, index| atoms[index] = try rt.internAtom(name);
    defer for (atoms) |name| rt.atoms.free(name);

    for (atoms[0..4], 0..) |name, index| {
        try object.defineOwnProperty(rt, name, core.Descriptor.data(core.JSValue.int32(@intCast(index)), true, true, true));
    }
    for (atoms[0..4]) |name| try std.testing.expect(object.deleteProperty(rt, name));

    try std.testing.expectEqual(@as(u32, 4), object.shape_ref.prop_count);
    try std.testing.expectEqual(@as(u32, 4), object.shape_ref.prop_size);
    try std.testing.expectEqual(@as(u32, 4), object.shape_ref.deleted_prop_count);

    // Permit the value-buffer grow and the old two-step implementation's first
    // (8 props / 8 buckets) shape relocation, but not its second (16 buckets).
    // The fixed implementation requests the final shape layout in one fallible
    // allocation, so either implementation must report OOM without committing
    // only one side of the object layout.
    const grown_value_bytes = @sizeOf(core.property.Entry) * 8;
    const first_shape_bytes = @sizeOf(core.shape.Shape) +
        @sizeOf(u32) * 8 + @sizeOf(core.shape.Property) * 8;
    rt.setMemoryLimit(rt.memory.allocated_bytes + grown_value_bytes + first_shape_bytes);
    defer rt.setMemoryLimit(null);
    try std.testing.expectError(
        error.OutOfMemory,
        object.defineOwnProperty(rt, atoms[4], core.Descriptor.data(core.JSValue.int32(4), true, true, true)),
    );
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(@as(u32, 4), object.shape_ref.prop_count);
    try std.testing.expectEqual(@as(u32, 4), object.shape_ref.prop_size);
    try std.testing.expect(!object.hasOwnProperty(atoms[4]));

    // A retry on the same object proves its value buffer still agrees with the
    // shape capacity and catches the former out-of-bounds write on index four.
    try object.defineOwnProperty(rt, atoms[4], core.Descriptor.data(core.JSValue.int32(5), true, true, true));
    try std.testing.expectEqual(@as(?i32, 5), (try object.getProperty(atoms[4])).asInt32());
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
    try std.testing.expectEqual(@as(i32, 2), env.header.meta().rc);

    ctx.destroy();
    try expectNoLiveGc(rt);
}

test "failed auto-init property definition rolls back retained entry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.RealmContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;

    const object = try core.Object.create(rt, core.class.ids.object, null);
    defer object.value().free(rt);

    const a = try rt.internAtom("auto_rollback_a");
    const b = try rt.internAtom("auto_rollback_b");
    const c = try rt.internAtom("auto_rollback_c");
    const d = try rt.internAtom("auto_rollback_d");
    const e = try rt.internAtom("auto_rollback_e");
    defer rt.atoms.free(a);
    defer rt.atoms.free(b);
    defer rt.atoms.free(c);
    defer rt.atoms.free(d);

    try object.defineOwnProperty(rt, a, core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    try object.defineOwnProperty(rt, b, core.Descriptor.data(core.JSValue.int32(2), true, true, true));
    try object.defineOwnProperty(rt, c, core.Descriptor.data(core.JSValue.int32(3), true, true, true));
    try object.defineOwnProperty(rt, d, core.Descriptor.data(core.JSValue.int32(4), true, true, true));

    try std.testing.expectEqual(@as(usize, 4), object.shape_ref.prop_count);
    try std.testing.expectEqual(@as(usize, 4), object.shape_ref.props().len);

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(
        error.OutOfMemory,
        object.defineAutoInitPropertyWithRealm(rt, e, "auto_rollback_e", 0, core.property.Flags.data(true, false, true), global),
    );
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(@as(usize, 4), object.shape_ref.prop_count);
    try std.testing.expect(!object.hasOwnProperty(e));

    rt.atoms.free(e);
    try std.testing.expect(rt.atoms.name(e) == null);
}

test "failed realm auto-init property definition rolls back borrowed holder registration" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const object = try core.Object.create(rt, core.class.ids.object, null);
    defer object.value().free(rt);

    const a = try rt.internAtom("realm_auto_rollback_a");
    const b = try rt.internAtom("realm_auto_rollback_b");
    const c = try rt.internAtom("realm_auto_rollback_c");
    const d = try rt.internAtom("realm_auto_rollback_d");
    const e = try rt.internAtom("realm_auto_rollback_e");
    defer rt.atoms.free(a);
    defer rt.atoms.free(b);
    defer rt.atoms.free(c);
    defer rt.atoms.free(d);

    try object.defineOwnProperty(rt, a, core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    try object.defineOwnProperty(rt, b, core.Descriptor.data(core.JSValue.int32(2), true, true, true));
    try object.defineOwnProperty(rt, c, core.Descriptor.data(core.JSValue.int32(3), true, true, true));
    try object.defineOwnProperty(rt, d, core.Descriptor.data(core.JSValue.int32(4), true, true, true));

    const old_holder_count = rt.borrowed_reference_holders.len;
    rt.setMemoryLimit(rt.memory.allocated_bytes + borrowedHolderInitialAllocationBytes());
    try std.testing.expectError(
        error.OutOfMemory,
        object.definePerformanceAutoInitProperty(rt, e, core.property.Flags.data(true, false, true), global),
    );
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(old_holder_count, rt.borrowed_reference_holders.len);
    try std.testing.expectEqual(@as(usize, 4), object.shape_ref.prop_count);
    try std.testing.expect(!object.hasOwnProperty(e));

    rt.atoms.free(e);
    try std.testing.expect(rt.atoms.name(e) == null);
}

test "property replacement preserves references under memory cap" {
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
    try std.testing.expectEqual(@as(usize, 1), object.shape_ref.prop_count);
    try std.testing.expectEqual(@as(usize, 1), object.shape_ref.prop_count);

    const old_refs = old_value.header.meta().rc;
    const replacement_refs = replacement.header.meta().rc;
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(replacement.value(), true, true, true));
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(old_refs - 1, old_value.header.meta().rc);
    try std.testing.expectEqual(replacement_refs + 1, replacement.header.meta().rc);
    try std.testing.expectEqual(@as(usize, 1), object.shape_ref.prop_count);
    try std.testing.expectEqual(@as(usize, 1), object.shape_ref.prop_count);

    const stored = try object.getProperty(key);
    defer stored.free(rt);
    try std.testing.expectEqual(&replacement.header, stored.refHeader().?);
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
    try std.testing.expectEqual(@as(i32, 1), stored.header.meta().rc);

    const own_value = holder.prop_values[0].slot.data;
    try std.testing.expect(try holder.setOwnWritableDataProperty(rt, key, own_value));
    try std.testing.expectEqual(@as(i32, 1), stored.header.meta().rc);
    try std.testing.expectEqual(&stored.header, holder.prop_values[0].slot.data.refHeader().?);

    const property_value = holder.prop_values[0].slot.data;
    try holder.setProperty(rt, key, property_value);
    try std.testing.expectEqual(@as(i32, 1), stored.header.meta().rc);
    try std.testing.expectEqual(&stored.header, holder.prop_values[0].slot.data.refHeader().?);

    const simple_value = holder.prop_values[0].slot.data;
    try std.testing.expect(try holder.setOrDefineOwnDataPropertyForSimpleSet(rt, key, simple_value));
    try std.testing.expectEqual(@as(i32, 1), stored.header.meta().rc);
    try std.testing.expectEqual(&stored.header, holder.prop_values[0].slot.data.refHeader().?);
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
    try std.testing.expectEqual(@as(i32, 1), stored.header.meta().rc);

    const current = holder.prop_values[0].slot.data;
    try holder.defineJsonParseDataProperty(rt, key, current);

    try std.testing.expectEqual(@as(i32, 1), stored.header.meta().rc);
    try std.testing.expectEqual(&stored.header, holder.prop_values[0].slot.data.refHeader().?);
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
    try std.testing.expectEqual(@as(i32, 1), stored.header.meta().rc);

    const current = array.arrayElements()[0];
    try array.setProperty(rt, index, current);

    try std.testing.expectEqual(@as(i32, 1), stored.header.meta().rc);
    try std.testing.expectEqual(&stored.header, array.arrayElements()[0].refHeader().?);
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
    try std.testing.expectEqual(@as(?*core.Object, proto), first.shape_ref.proto);
    try std.testing.expectEqual(@as(?*core.Object, null), second.shape_ref.proto);
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

    const proto_refs = proto.header.meta().rc;
    const shape_refs = shared_shape.refCount();
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, first.setPrototype(rt, proto));
    rt.setMemoryLimit(null);

    try std.testing.expect(first.getPrototype() == null);
    try std.testing.expectEqual(proto_refs, proto.header.meta().rc);
    try std.testing.expectEqual(shared_shape, first.shape_ref);
    try std.testing.expectEqual(shared_shape, second.shape_ref);
    try std.testing.expectEqual(shape_refs, shared_shape.refCount());
    try std.testing.expectEqual(@as(?*core.Object, null), shared_shape.proto);
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
    const shape_refs = shared_shape.refCount();
    const bytes = rt.memory.allocated_bytes;
    const allocations = rt.memory.allocation_count;

    rt.setMemoryLimit(bytes);
    try std.testing.expectError(error.OutOfMemory, core.Object.create(rt, core.class.ids.object, null));
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(@as(usize, objects.len + 1), rt.gc.liveCount());
    try std.testing.expectEqual(shape_refs, shared_shape.refCount());
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

    const target = try rt.internAtom("prop_96");
    defer rt.atoms.free(target);
    const before = try obj.getProperty(target);
    defer before.free(rt);
    try std.testing.expectEqual(@as(?i32, 96), before.asInt32());

    try std.testing.expect(obj.deleteProperty(rt, target));
    try std.testing.expect(!obj.hasOwnProperty(target));

    try obj.defineOwnProperty(rt, target, core.Descriptor.data(core.JSValue.int32(777), true, true, true));
    const after = try obj.getProperty(target);
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
    try std.testing.expectEqual(@as(i32, 2), str.header().rc);

    value.free(rt);
    try std.testing.expectEqual(@as(i32, 1), str.header().rc);
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

test "runtime allocator facades share memory accounting" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const baseline = rt.memory.allocated_bytes;
    const current = try rt.memory.allocator.alloc(u8, 2048);
    var current_live = true;
    defer if (current_live) rt.memory.allocator.free(current);
    try std.testing.expectEqual(baseline + current.len, rt.memory.allocated_bytes);

    const persistent = try rt.memory.persistent_allocator.alloc(u8, 4096);
    var persistent_live = true;
    defer if (persistent_live) rt.memory.persistent_allocator.free(persistent);
    try std.testing.expectEqual(baseline + current.len + persistent.len, rt.memory.allocated_bytes);

    rt.memory.persistent_allocator.free(persistent);
    persistent_live = false;
    try std.testing.expectEqual(baseline + current.len, rt.memory.allocated_bytes);
    rt.memory.allocator.free(current);
    current_live = false;
    try std.testing.expectEqual(baseline, rt.memory.allocated_bytes);
}

test "gc registry tracks live objects and intrusive list state" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const obj = try core.Object.create(rt, core.class.ids.object, null);
    try std.testing.expectEqual(@as(usize, 2), rt.gc.liveCount());

    rt.gc.unlinkObject(&obj.header);
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCount());

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
    const fixture_layout = try engine.bytecode.FunctionLayout.init(
        true,
        true,
        64,
        3,
        5,
        4,
        1,
    );
    // Keep this above the 512-byte small-object ceiling even in the alternate
    // 8-byte JSValue representation. The main FAM must therefore use one
    // standalone GC metadata prefix and one matching destroyWithFam call.
    try std.testing.expect(fixture_layout.mainPayloadBytes() > 512);
    try std.testing.expect(fixture_layout.total_size > 512);

    var rt: core.JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{
        .gc_policy = .{
            .old_weight = 3,
            .major_debt_threshold = fixture_layout.total_size * 3,
        },
    });
    defer rt.deinit();

    const baseline_bytes = rt.memory.allocated_bytes;
    const baseline_allocations = rt.memory.allocation_count;
    const baseline_create_calls = rt.memory.create_calls;
    const baseline_destroy_calls = rt.memory.destroy_calls;
    const fb = try engine.bytecode.FunctionBytecode.createFixture(&rt, .{
        .arg_count = 3,
        .var_count = 5,
        .defined_arg_count = 2,
        .closure_var_count = 4,
        .cpool_count = 64,
        .byte_code = &.{engine.bytecode.opcode.op.return_undef},
        .has_debug = true,
        .has_extension = true,
    });
    var fb_published = false;
    errdefer if (!fb_published) fb.destroyUnpublishedFixture(&rt);

    try std.testing.expectEqual(fixture_layout.total_size, fb.layout().total_size);
    try std.testing.expectEqual(fixture_layout.total_size, fb.heapByteSize());
    try std.testing.expect(!fb.header.meta().flags.metadata_in_slab);
    try std.testing.expectEqual(
        baseline_bytes + fixture_layout.total_size + core.gc.metadata_prefix_size,
        rt.memory.allocated_bytes,
    );
    try std.testing.expectEqual(baseline_allocations + 1, rt.memory.allocation_count);
    try std.testing.expectEqual(baseline_create_calls + 1, rt.memory.create_calls);
    try std.testing.expectEqual(baseline_destroy_calls, rt.memory.destroy_calls);

    fb.publishFixtureNoFail(&rt);
    fb_published = true;
    const value = core.JSValue.functionBytecode(&fb.header);
    var value_alive = true;
    defer if (value_alive) value.free(&rt);

    // old_allocated_bytes / old_alloc_count are derived lazily from live space
    // bytes and the GC object list, not stored per allocation.
    const fb_stats = rt.gcStats();
    try std.testing.expectEqual(fb.heapByteSize(), fb_stats.old_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), fb_stats.old_alloc_count);
    // Heap object registration no longer accrues weighted allocation_debt; that
    // counter is reserved for the off-heap external-memory trigger. Even with a
    // debt threshold sized to this allocation, the heap path never consults
    // externalMemoryRequestReason, so no GC is requested (asserted below).
    try std.testing.expectEqual(@as(usize, 0), rt.allocationDebtBytes());
    if (!core.memory.force_gc_on_allocation_enabled) {
        try std.testing.expect(!rt.gcPendingForTest());
        try std.testing.expect(!rt.gc.hasPendingMajorRequest());
        try std.testing.expectEqual(@as(?core.gc.RequestReason, null), rt.gcLastRequestReasonForTest());
    }

    value.free(&rt);
    value_alive = false;
    try std.testing.expectEqual(baseline_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(baseline_allocations, rt.memory.allocation_count);
    try std.testing.expectEqual(baseline_create_calls + 1, rt.memory.create_calls);
    try std.testing.expectEqual(baseline_destroy_calls + 1, rt.memory.destroy_calls);
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

    const owner = try core.Object.create(&rt, core.class.ids.c_function_data, null);
    defer owner.value().free(&rt);
    const child = try core.Object.create(&rt, core.class.ids.object, null);
    defer child.value().free(&rt);

    var token = try rt.reportExternalAlloc(32);
    defer token.release();

    const key = try rt.internAtom("statsChild");
    defer rt.atoms.free(key);
    try owner.defineOwnProperty(&rt, key, core.Descriptor.data(child.value(), true, true, true));

    const snapshot = rt.gcStats();
    const expected_gc_bytes =
        owner.allocationSize(&rt) +
        child.allocationSize(&rt) +
        owner.shape_ref.allocationSize() +
        child.shape_ref.allocationSize();
    try std.testing.expectEqual(@as(usize, expected_gc_bytes), snapshot.total_allocated_bytes);
    try std.testing.expectEqual(@as(usize, expected_gc_bytes), snapshot.heap_live_bytes);
    try std.testing.expectEqual(@as(usize, expected_gc_bytes), snapshot.old_live_bytes);
    try std.testing.expectEqual(@as(usize, 0), snapshot.large_object_bytes);
    try std.testing.expectEqual(@as(usize, core.gc.logical_page_size), snapshot.heap_committed_bytes);
    try std.testing.expectEqual(@as(usize, core.gc.logical_page_size), snapshot.old_committed_bytes);
    try std.testing.expectEqual(@as(usize, expected_gc_bytes), snapshot.old_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 4), snapshot.old_alloc_count);
    try std.testing.expectEqual(@as(usize, 32), snapshot.external_bytes);
    try std.testing.expectEqual(@as(usize, 1), snapshot.external_alloc_count);
    try std.testing.expectEqual(@as(usize, 1), snapshot.external_token_count);
    try std.testing.expectEqual(@as(usize, 32), snapshot.external_token_bytes);
    try std.testing.expectEqual(@as(usize, 0), snapshot.weak_ref_count);
    try std.testing.expectEqual(@as(usize, 0), snapshot.finalizer_queue_length);
    if (!core.memory.force_gc_on_allocation_enabled) {
        try std.testing.expectEqual(@as(usize, 0), snapshot.major_gc_count);
        try std.testing.expectEqual(@as(u64, 0), snapshot.incremental_slice_ns_p50);
        try std.testing.expectEqual(@as(u64, 0), snapshot.incremental_slice_ns_p95);
        try std.testing.expectEqual(@as(u64, 0), snapshot.incremental_slice_ns_p99);
    }
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
    const expected_gc_bytes = object.allocationSize(rt) + object.shape_ref.allocationSize();
    try std.testing.expectEqual(@as(usize, expected_gc_bytes), allocated.total_allocated_bytes);
    try std.testing.expectEqual(@as(usize, expected_gc_bytes), allocated.heap_live_bytes);
    try std.testing.expectEqual(@as(usize, expected_gc_bytes), allocated.old_live_bytes);
    try std.testing.expectEqual(@as(usize, 0), allocated.large_object_bytes);
    try std.testing.expectEqual(@as(usize, core.gc.logical_page_size), allocated.heap_committed_bytes);
    try std.testing.expectEqual(@as(usize, core.gc.logical_page_size), allocated.old_committed_bytes);

    object.value().free(rt);

    const released = rt.gcStats();
    try std.testing.expectEqual(@as(usize, 0), released.total_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), released.peak_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), released.old_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), released.old_alloc_count);
    try std.testing.expectEqual(@as(usize, 0), released.heap_live_bytes);
    try std.testing.expectEqual(@as(usize, 0), released.old_live_bytes);
    try std.testing.expectEqual(@as(usize, 0), released.large_object_bytes);
    // Page geometry is derived from live_bytes on demand. The SmallObjectSlab's
    // bounded per-class reserve is allocator-private and released at runtime
    // teardown, so a fully-freed GC heap reports zero logical committed/empty/
    // fragmentation immediately.
    try std.testing.expectEqual(@as(usize, 0), released.heap_committed_bytes);
    try std.testing.expectEqual(@as(usize, 0), released.empty_page_bytes);
    try std.testing.expectEqual(@as(usize, 0), released.old_fragmentation_ratio);

    // decommitEmptyPagesNow is a diagnostics refresh; allocator-private reserves
    // are outside the logical GC page account.
    rt.gc.decommitEmptyPagesNow();
    const decommitted = rt.gcStats();
    try std.testing.expectEqual(@as(usize, 0), decommitted.heap_committed_bytes);
    try std.testing.expectEqual(@as(usize, 0), decommitted.empty_page_bytes);
    try std.testing.expectEqual(@as(usize, 0), decommitted.decommitted_bytes);
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
    try rt.gc.verifyHeapAccounting(&rt);
    try std.testing.expectError(error.LeakedExternalMemoryToken, rt.gc.verifyNoExternalTokenLeaks());

    token.release();
    stats = rt.gcStats();
    try std.testing.expectEqual(@as(usize, 0), stats.external_bytes);
    try std.testing.expectEqual(@as(usize, 0), stats.external_token_count);
    try std.testing.expectEqual(@as(usize, 1), stats.external_free_count);
    try rt.gc.verifyHeapAccounting(&rt);
    try rt.gc.verifyNoExternalTokenLeaks();

    duplicate_token.release();
    stats = rt.gcStats();
    try std.testing.expectEqual(@as(usize, 0), stats.external_bytes);
    try std.testing.expectEqual(@as(usize, 1), stats.external_free_count);
    try std.testing.expectEqual(@as(usize, 1), stats.external_invalid_release_count);
    try rt.gc.verifyHeapAccounting(&rt);
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

    const property_value = try array_obj.getProperty(key);
    defer property_value.free(rt);
    try std.testing.expectEqual(@as(?i32, 501), property_value.asInt32());
    try std.testing.expectEqual(@as(?i32, 502), array_obj.arrayElements()[0].asInt32());
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

    try rt.gc.verifyHeapAccounting(rt);

    const obj = try core.Object.create(rt, core.class.ids.object, null);
    try rt.gc.verifyHeapAccounting(rt);

    // heap_live_bytes is derived from old_space.live_bytes (the source of truth
    // since the gc.stats mirror was retired); drift it there and the object-list
    // walk still catches the mismatch first.
    rt.gc.old_space.live_bytes += 1;
    try std.testing.expectError(error.HeapLiveBytesMismatch, rt.gc.verifyHeapAccounting(rt));
    rt.gc.old_space.live_bytes -= 1;
    try rt.gc.verifyHeapAccounting(rt);

    obj.value().free(rt);
    try rt.gc.verifyHeapAccounting(rt);
}

test "gc heap accounting verifier catches missing allocation entries" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const obj = try core.Object.create(rt, core.class.ids.object, null);
    defer obj.value().free(rt);
    try rt.gc.verifyHeapAccounting(rt);

    obj.header.meta().flags.heap_accounted = false;
    try std.testing.expectError(error.MissingHeapAllocation, rt.gc.verifyHeapAccounting(rt));
    obj.header.meta().flags.heap_accounted = true;
    try rt.gc.verifyHeapAccounting(rt);
}

test "gc heap accounting verifier catches pinned header flag drift" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const obj = try core.Object.create(rt, core.class.ids.object, null);
    const value = obj.value();
    var pin = (try core.runtime.pinValueForNative(rt, value)).?;
    defer pin.release();
    value.free(rt);

    try rt.gc.verifyHeapAccounting(rt);
    obj.header.setPinned(false);
    try std.testing.expectError(error.PinnedHeaderFlagMismatch, rt.gc.verifyHeapAccounting(rt));
    obj.header.setPinned(true);
    try rt.gc.verifyHeapAccounting(rt);
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

    const external_id = try rt.newClassId(core.class.invalid_class_id);
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
    obj.u.payload = @ptrCast(payload);

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
    try std.testing.expectEqual(@as(i32, 0), obj.header.meta().rc);
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCount());

    // Clean up manually since we released/unlinked it
    core.Object.destroyFromHeader(rt, &obj.header);
}

const deep_gc_chain_length: usize = 20_000;

fn createDeepOwnedPropertyChain(rt: *core.JSRuntime, key: core.Atom, length: usize) !*core.Object {
    std.debug.assert(length != 0);
    const head = try core.Object.create(rt, core.class.ids.object, null);
    errdefer head.value().free(rt);

    var tail = head;
    for (1..length) |_| {
        const child = try core.Object.create(rt, core.class.ids.object, null);
        tail.defineOwnProperty(
            rt,
            key,
            core.Descriptor.data(child.value(), true, true, true),
        ) catch |err| {
            child.value().free(rt);
            return err;
        };
        // The property is now the child's sole owner. Keeping only a raw tail
        // pointer makes releasing `head` exercise the real RC cascade.
        child.value().free(rt);
        tail = child;
    }
    return head;
}

test "zero-ref release drains a deep acyclic object chain iteratively" {
    const rt = try core.JSRuntime.createWithOptions(std.testing.allocator, .{
        .gc_threshold = 256 * 1024 * 1024,
    });
    defer rt.destroy();

    const key = try rt.internAtom("deep-zero-ref-next");
    defer rt.atoms.free(key);
    const head = try createDeepOwnedPropertyChain(rt, key, deep_gc_chain_length);

    head.value().free(rt);
    try expectNoLiveGc(rt);
}

test "cycle scan preserves a deeply rooted object chain without recursion" {
    const rt = try core.JSRuntime.createWithOptions(std.testing.allocator, .{
        .gc_threshold = 256 * 1024 * 1024,
    });
    defer rt.destroy();

    const key = try rt.internAtom("deep-cycle-scan-next");
    defer rt.atoms.free(key);
    _ = try createDeepOwnedPropertyChain(rt, key, deep_gc_chain_length);

    const before = rt.gc.liveCount();
    const result = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 0), result.freed_objects);
    try std.testing.expectEqual(before, rt.gc.liveCount());
}

const live_empty_object_gc_count: usize = 2;
const single_object_self_cycle_reclaimed_count: usize = 2;
const closed_property_cycle_reclaimed_count: usize = 4;

fn expectNoLiveGc(rt: *core.JSRuntime) !void {
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
    try std.testing.expectEqual(@as(usize, 0), rt.shapes.live_shape_count);
}

fn expectCycleReclaimedIncludingShapes(rt: *core.JSRuntime, expected: usize, actual: usize) !void {
    // Shapes are GC objects now, so cycle reclaim counts include collected
    // object shapes in addition to the JS objects themselves.
    try std.testing.expectEqual(@as(usize, expected), actual);
    try expectNoLiveGc(rt);
}

fn expectClosedPropertyCycleReclaimed(rt: *core.JSRuntime, freed: usize) !void {
    // Shape is a GC object. This graph collects the two JS objects plus the two
    // one-property transition shapes; the shared empty root shape is released
    // when both objects leave it.
    try std.testing.expectEqual(@as(usize, closed_property_cycle_reclaimed_count), freed);
    try expectNoLiveGc(rt);
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
    try expectClosedPropertyCycleReclaimed(rt, rt.runObjectCycleRemoval());
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

    try expectClosedPropertyCycleReclaimed(rt, result.freed_objects);
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
    try expectClosedPropertyCycleReclaimed(rt, result.freed_objects);
    try std.testing.expect(!rt.gcPendingForTest());
}

test "pollGC preserves a pending major request during refcount teardown" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    rt.requestGCForTest();
    const collections_before = rt.gc.stats.collections;
    rt.gc.phase = .decref;
    defer rt.gc.phase = .none;

    const nested = try rt.pollGC(null, .urgent);
    try std.testing.expectEqual(@as(usize, 0), nested.freed_objects);
    try std.testing.expectEqual(collections_before, rt.gc.stats.collections);
    try std.testing.expect(rt.gcPendingForTest());

    // The object-allocation boundary delegates to pollGC, so it must preserve
    // the same pending request rather than nesting through this phase too.
    rt.collectBeforeObjectAllocation(@sizeOf(core.Object));
    try std.testing.expectEqual(collections_before, rt.gc.stats.collections);
    try std.testing.expect(rt.gcPendingForTest());

    rt.gc.phase = .none;
    _ = try rt.pollGC(null, .urgent);
    try std.testing.expect(!rt.gcPendingForTest());
}

test "persistent value handle keeps object and nested symbols alive" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.object, null);
    const key = try rt.atoms.newValueSymbol("persistent-handle-symbol-key");
    const value = object.value();
    try object.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.boolean(true), true, true, true));
    rt.atoms.free(key);

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
    try std.testing.expectEqual(@as(usize, live_empty_object_gc_count), rt.gc.liveCount());

    scope.exit();
    try std.testing.expectEqual(@as(usize, 0), rt.localRootCountForTest());

    _ = try rt.tryRunObjectCycleRemoval();
    try expectNoLiveGc(rt);
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
    try std.testing.expectEqual(@as(usize, live_empty_object_gc_count), rt.gc.liveCount());

    persistent.destroy(rt);
    _ = try rt.tryRunObjectCycleRemoval();
    try expectNoLiveGc(rt);
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
    try std.testing.expectEqual(@as(i32, 3), object.header.meta().rc);

    value.free(rt);
    try std.testing.expectEqual(@as(i32, 2), object.header.meta().rc);
    try std.testing.expectEqual(@as(usize, live_empty_object_gc_count), rt.gc.liveCount());

    first_pin.release();
    try std.testing.expect(object.header.pinned());
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().pinned_cell_count);
    try std.testing.expectEqual(@as(i32, 1), object.header.meta().rc);

    second_pin.release();
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().pinned_cell_count);
    try expectNoLiveGc(rt);
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
    try std.testing.expectEqual(@as(usize, 0), clear_count);
    _ = rt.runObjectCycleRemoval();
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
    try std.testing.expectEqual(@as(usize, single_object_self_cycle_reclaimed_count), rt.gc.liveCount());

    try expectCycleReclaimedIncludingShapes(rt, single_object_self_cycle_reclaimed_count, rt.runObjectCycleRemoval());
    try std.testing.expect(weak.get().isUndefined());
    try std.testing.expectEqual(@as(usize, 0), clear_count);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 1), clear_count);
}

test "weak persistent value clears unrooted symbol target during gc" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("weak-persistent-symbol");
    var clear_count: usize = 0;
    var symbol_value = try rt.symbolValue(symbol_atom);
    var weak = try rt.createWeakPersistentValue(symbol_value, weakPersistentCounterCallback, &clear_count);
    defer weak.deinit();

    try std.testing.expect(weak.isAlive());
    {
        const live = weak.get();
        defer live.free(rt);
        try std.testing.expect(live.same(symbol_value));
    }

    symbol_value.free(rt);
    symbol_value = core.JSValue.undefinedValue();

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
    const function = try core.Object.create(rt, core.class.ids.bytecode_function, null);
    const method_key = try rt.internAtom("method");
    defer rt.atoms.free(method_key);

    try function.setFunctionHomeObject(rt, home);
    try home.defineOwnProperty(rt, method_key, core.Descriptor.data(function.value(), true, true, true));

    home.value().free(rt);
    function.value().free(rt);
    try expectCycleReclaimedIncludingShapes(rt, 4, rt.runObjectCycleRemoval());
}

test "async continuation function cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const continuation = try core.Object.create(rt, core.class.ids.c_function_data, null);
    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    const key = try rt.internAtom("continuation");
    defer rt.atoms.free(key);

    (try continuation.functionAsyncContinuationSlot(rt)).* = promise.value().dup();
    try promise.defineOwnProperty(rt, key, core.Descriptor.data(continuation.value(), true, true, true));

    continuation.value().free(rt);
    promise.value().free(rt);
    try expectCycleReclaimedIncludingShapes(rt, 4, rt.runObjectCycleRemoval());
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
    try expectCycleReclaimedIncludingShapes(rt, 4, rt.runObjectCycleRemoval());
}

test "materialized native function cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.RealmContext.create(rt);
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    // The focused cycle fixture does not run exec's full intrinsic bootstrap;
    // provide an in-graph Function.prototype stand-in so auto-init exercises
    // the production direct-prototype constructor instead of a null-prototype
    // compatibility path.
    try global.setCachedFunctionProto(rt, global);
    const cached_key = try rt.internAtom("cached");
    defer rt.atoms.free(cached_key);
    const global_key = try rt.internAtom("global");
    defer rt.atoms.free(global_key);

    try global.defineAutoInitPropertyWithRealmAndNative(
        rt,
        cached_key,
        "cached",
        0,
        core.property.Flags.data(true, false, true),
        global,
        0,
    );

    const cached_value = try global.getProperty(cached_key);
    const cached_function: *core.Object = @fieldParentPtr("header", cached_value.refHeader().?);
    try cached_function.defineOwnProperty(rt, global_key, core.Descriptor.data(global.value(), true, true, true));

    cached_value.free(rt);
    ctx.destroy();

    // Global materialization publishes the function through a fresh VarRef;
    // that true C function independently owns the context. The collector must
    // reclaim context -> global -> VarRef -> function -> context in one batch.
    try expectCycleReclaimedIncludingShapes(rt, 6, rt.runObjectCycleRemoval());
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

    const fb = try engine.bytecode.FunctionBytecode.createFixture(rt, .{
        .name = name,
        .cpool_count = 1,
    });
    fb.cpoolSlice()[0] = captured.value().dup();
    fb.publishFixtureNoFail(rt);

    try function.setFunctionBytecodeValue(rt, core.JSValue.functionBytecode(&fb.header));
    try captured.defineOwnProperty(rt, function_key, core.Descriptor.data(function.value(), true, true, true));

    function.value().free(rt);
    captured.value().free(rt);

    try expectCycleReclaimedIncludingShapes(rt, 4, rt.runObjectCycleRemoval());
}

test "runtime destroy releases callback bytecode before object registries" {
    const rt = try core.JSRuntime.create(std.testing.allocator);

    const captured = try core.Object.create(rt, core.class.ids.object, null);

    const fb = try engine.bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
    fb.cpoolSlice()[0] = captured.value().dup();
    fb.publishFixtureNoFail(rt);

    captured.value().free(rt);

    rt.destroy();
}

test "runtime destroy releases nested callback bytecode in owner order" {
    const rt = try core.JSRuntime.create(std.testing.allocator);

    const child = try engine.bytecode.FunctionBytecode.createFixture(rt, .{});
    var child_published = false;
    errdefer if (!child_published) child.destroyUnpublishedFixture(rt);
    const parent = try engine.bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
    var parent_published = false;
    errdefer if (!parent_published) parent.destroyUnpublishedFixture(rt);

    parent.cpoolSlice()[0] = core.JSValue.functionBytecode(&child.header);
    child.publishFixtureNoFail(rt);
    child_published = true;
    parent.publishFixtureNoFail(rt);
    parent_published = true;

    rt.destroy();
}

test "runtime destroy revisits callback bytecode after parent release" {
    const rt = try core.JSRuntime.create(std.testing.allocator);

    const child = try engine.bytecode.FunctionBytecode.createFixture(rt, .{});
    var child_published = false;
    errdefer if (!child_published) child.destroyUnpublishedFixture(rt);
    const parent = try engine.bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
    var parent_published = false;
    errdefer if (!parent_published) parent.destroyUnpublishedFixture(rt);

    child.publishFixtureNoFail(rt);
    child_published = true;
    parent.publishFixtureNoFail(rt);
    parent_published = true;
    parent.cpoolSlice()[0] = core.JSValue.functionBytecode(&child.header).dup();

    rt.destroy();
}

test "runtime destroy releases cyclic callback bytecode constants" {
    const rt = try core.JSRuntime.create(std.testing.allocator);

    const left = try engine.bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
    var left_published = false;
    errdefer if (!left_published) left.destroyUnpublishedFixture(rt);
    const right = try engine.bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
    var right_published = false;
    errdefer if (!right_published) right.destroyUnpublishedFixture(rt);

    left.publishFixtureNoFail(rt);
    left_published = true;
    right.publishFixtureNoFail(rt);
    right_published = true;
    left.cpoolSlice()[0] = core.JSValue.functionBytecode(&right.header).dup();
    right.cpoolSlice()[0] = core.JSValue.functionBytecode(&left.header).dup();

    rt.destroy();
}

test "runtime destroy releases callback bytecode constants with transferred ownership" {
    const rt = try core.JSRuntime.create(std.testing.allocator);

    const left = try engine.bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
    var left_published = false;
    errdefer if (!left_published) left.destroyUnpublishedFixture(rt);
    const right = try engine.bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
    var right_published = false;
    errdefer if (!right_published) right.destroyUnpublishedFixture(rt);

    left.cpoolSlice()[0] = core.JSValue.functionBytecode(&right.header);
    right.cpoolSlice()[0] = core.JSValue.functionBytecode(&left.header);
    left.publishFixtureNoFail(rt);
    left_published = true;
    right.publishFixtureNoFail(rt);
    right_published = true;

    rt.destroy();
}

test "bytecode-only callback constant cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const left = try engine.bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
    var left_published = false;
    errdefer if (!left_published) left.destroyUnpublishedFixture(rt);
    const right = try engine.bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
    var right_published = false;
    errdefer if (!right_published) right.destroyUnpublishedFixture(rt);

    left.cpoolSlice()[0] = core.JSValue.functionBytecode(&right.header);
    right.cpoolSlice()[0] = core.JSValue.functionBytecode(&left.header);
    left.publishFixtureNoFail(rt);
    left_published = true;
    right.publishFixtureNoFail(rt);
    right_published = true;

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

    const fb = try engine.bytecode.FunctionBytecode.createFixture(rt, .{
        .name = name,
        .cpool_count = 1,
    });
    fb.cpoolSlice()[0] = captured.value().dup();
    fb.publishFixtureNoFail(rt);

    const bytecode_value = core.JSValue.functionBytecode(&fb.header);
    try first.setFunctionBytecodeValue(rt, bytecode_value.dup());
    try second.setFunctionBytecodeValue(rt, bytecode_value);
    try captured.defineOwnProperty(rt, first_key, core.Descriptor.data(first.value(), true, true, true));
    try captured.defineOwnProperty(rt, second_key, core.Descriptor.data(second.value(), true, true, true));

    first.value().free(rt);
    second.value().free(rt);
    captured.value().free(rt);

    try expectCycleReclaimedIncludingShapes(rt, 5, rt.runObjectCycleRemoval());
}

test "cycle teardown frees bytecode function captures before FB metadata" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    const function = try core.Object.create(rt, core.class.ids.bytecode_function, null);
    const function_key = try rt.internAtom("capturedFunction");
    defer rt.atoms.free(function_key);

    const fb = try engine.bytecode.FunctionBytecode.createFixture(rt, .{ .closure_var_count = 1 });
    fb.closureVar()[0] = engine.bytecode.function_bytecode.BytecodeClosureVar.init(.{
        .closure_type = .ref,
        .var_idx = 0,
        .var_name = rt.atoms.dup(core.atom.ids.empty_string),
    });
    fb.publishFixtureNoFail(rt);

    try function.setFunctionBytecodeValue(rt, core.JSValue.functionBytecode(&fb.header));
    const captures = try rt.memory.alloc(*core.VarRef, 1);
    captures[0] = try core.VarRef.createClosed(rt, core.JSValue.int32(1));
    function.setFunctionCaptures(rt, captures);
    try global.defineOwnProperty(rt, function_key, core.Descriptor.data(function.value(), true, true, true));

    function.value().free(rt);
    global.value().free(rt);

    _ = rt.runObjectCycleRemoval();
    try expectNoLiveGc(rt);
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

    const outer = try engine.bytecode.FunctionBytecode.createFixture(rt, .{
        .name = outer_name,
        .cpool_count = 1,
    });
    var outer_published = false;
    errdefer if (!outer_published) outer.destroyUnpublishedFixture(rt);
    const inner = try engine.bytecode.FunctionBytecode.createFixture(rt, .{
        .name = inner_name,
        .cpool_count = 1,
    });
    var inner_published = false;
    errdefer if (!inner_published) inner.destroyUnpublishedFixture(rt);

    outer.cpoolSlice()[0] = core.JSValue.functionBytecode(&inner.header);
    inner.cpoolSlice()[0] = captured.value().dup();
    outer.publishFixtureNoFail(rt);
    outer_published = true;
    inner.publishFixtureNoFail(rt);
    inner_published = true;

    try function.setFunctionBytecodeValue(rt, core.JSValue.functionBytecode(&outer.header));
    try captured.defineOwnProperty(rt, function_key, core.Descriptor.data(function.value(), true, true, true));

    function.value().free(rt);
    captured.value().free(rt);

    try expectCycleReclaimedIncludingShapes(rt, 4, rt.runObjectCycleRemoval());
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

    const outer = try engine.bytecode.FunctionBytecode.createFixture(rt, .{
        .name = outer_name,
        .cpool_count = 1,
    });
    var outer_published = false;
    errdefer if (!outer_published) outer.destroyUnpublishedFixture(rt);
    const inner = try engine.bytecode.FunctionBytecode.createFixture(rt, .{
        .name = inner_name,
        .cpool_count = 2,
    });
    var inner_published = false;
    errdefer if (!inner_published) inner.destroyUnpublishedFixture(rt);

    outer.cpoolSlice()[0] = core.JSValue.functionBytecode(&inner.header);
    inner.cpoolSlice()[1] = captured.value().dup();
    outer.publishFixtureNoFail(rt);
    outer_published = true;
    inner.publishFixtureNoFail(rt);
    inner_published = true;
    inner.cpoolSlice()[0] = core.JSValue.functionBytecode(&outer.header).dup();

    try function.setFunctionBytecodeValue(rt, core.JSValue.functionBytecode(&outer.header));
    try captured.defineOwnProperty(rt, function_key, core.Descriptor.data(function.value(), true, true, true));

    function.value().free(rt);
    captured.value().free(rt);

    try expectCycleReclaimedIncludingShapes(rt, 4, rt.runObjectCycleRemoval());
}

test "class payload function bytecode constant object cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const external_id = try rt.newClassId(core.class.invalid_class_id);
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

    const fb = try engine.bytecode.FunctionBytecode.createFixture(rt, .{
        .name = name,
        .cpool_count = 1,
    });
    var fb_published = false;
    errdefer if (!fb_published) fb.destroyUnpublishedFixture(rt);
    const payload = try rt.memory.create(TestExternalPayload);
    fb.cpoolSlice()[0] = captured.value().dup();
    payload.* = .{ .value = core.JSValue.functionBytecode(&fb.header) };
    external.u.payload = @ptrCast(payload);
    fb.publishFixtureNoFail(rt);
    fb_published = true;
    try captured.defineOwnProperty(rt, external_key, core.Descriptor.data(external.value(), true, true, true));

    payload_finalizer_calls = 0;
    payload_mark_calls = 0;
    external.value().free(rt);
    captured.value().free(rt);

    try std.testing.expectEqual(@as(usize, 4), rt.runObjectCycleRemoval());
    try std.testing.expect(payload_mark_calls > 0);
    try std.testing.expectEqual(@as(usize, 0), payload_finalizer_calls);
    try expectOneDeferredClassPayloadFinalizer(rt);
    try runOneDeferredClassPayloadFinalizer(rt);
    try std.testing.expectEqual(@as(usize, 1), payload_finalizer_calls);
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "realm context owns cached prototype references" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const function_proto = try core.Object.create(rt, core.class.ids.object, null);
    const promise_proto = try core.Object.create(rt, core.class.ids.object, null);
    const global_key = try rt.internAtom("global");
    defer rt.atoms.free(global_key);

    try global.setCachedFunctionProto(rt, function_proto);
    try global.setCachedPromiseProto(rt, promise_proto);
    try function_proto.defineOwnProperty(rt, global_key, core.Descriptor.data(global.value(), true, true, true));
    try promise_proto.defineOwnProperty(rt, global_key, core.Descriptor.data(global.value(), true, true, true));

    try std.testing.expectEqual(@as(i32, 3), global.header.meta().rc);
    try std.testing.expectEqual(@as(i32, 2), function_proto.header.meta().rc);
    try std.testing.expectEqual(@as(i32, 2), promise_proto.header.meta().rc);

    ctx.destroy();
    function_proto.value().free(rt);
    promise_proto.value().free(rt);

    try std.testing.expectEqual(@as(usize, 0), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "auto-init slot owns its Realm until the property is deleted" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.RealmContext.create(rt);
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const holder = try core.Object.create(rt, core.class.ids.object, null);
    const lazy_key = try rt.internAtom("lazy");
    defer rt.atoms.free(lazy_key);

    try holder.defineAutoInitPropertyWithRealmAndNative(
        rt,
        lazy_key,
        "lazy",
        0,
        core.property.Flags.data(true, false, true),
        global,
        0,
    );

    const slot = holder.prop_values[0].slot.auto_init;
    try std.testing.expectEqual(core.property.AutoInitId.prop, slot.realm_and_id.id());
    try std.testing.expectEqual(&ctx.header, slot.realm_and_id.realmHeader().?);

    ctx.destroy();
    try std.testing.expectEqual(ctx, rt.firstContext().?);

    try std.testing.expect(holder.deleteProperty(rt, lazy_key));
    try std.testing.expectEqual(@as(?*core.RealmContext, null), rt.firstContext());

    holder.value().free(rt);
    try std.testing.expectEqual(@as(usize, 0), rt.runObjectCycleRemoval());
}

test "typed MODULE_NS auto-init publishes a normal value or the same VarRef cell" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.RealmContext.create(rt);
    defer ctx.destroy();
    const value_holder = try core.Object.create(rt, core.class.ids.object, null);
    defer value_holder.value().free(rt);
    const cell_holder = try core.Object.create(rt, core.class.ids.object, null);
    defer cell_holder.value().free(rt);
    const value_key = try rt.internAtom("module_namespace_value");
    defer rt.atoms.free(value_key);
    const cell_key = try rt.internAtom("module_namespace_cell");
    defer rt.atoms.free(cell_key);
    const flags = core.property.Flags.data(true, false, true);

    var value_fixture = ModuleAutoInitFixture{
        .expected_realm = &ctx.header,
        .result = .{ .value = core.JSValue.int32(41) },
    };
    try value_holder.defineModuleAutoInitPropertyForFixture(rt, value_key, flags, ctx, &value_fixture.owner);
    try std.testing.expectEqual(core.property.AutoInitId.module_ns, value_holder.prop_values[0].slot.auto_init.realm_and_id.id());
    const namespace_value = try value_holder.getProperty(value_key);
    defer namespace_value.free(rt);
    try std.testing.expectEqual(@as(?i32, 41), namespace_value.asInt32());
    try std.testing.expectEqual(@as(usize, 1), value_fixture.calls);
    try std.testing.expectEqual(core.property.Kind.data, value_holder.propKindAt(0));

    const cell = try core.VarRef.createClosed(rt, core.JSValue.int32(7));
    defer cell.freeCell(rt);
    var cell_fixture = ModuleAutoInitFixture{
        .expected_realm = &ctx.header,
        .result = .{ .var_ref = cell },
    };
    try cell_holder.defineModuleAutoInitPropertyForFixture(rt, cell_key, flags, ctx, &cell_fixture.owner);
    const first_cell_value = try cell_holder.getProperty(cell_key);
    defer first_cell_value.free(rt);
    try std.testing.expectEqual(@as(?i32, 7), first_cell_value.asInt32());
    try std.testing.expectEqual(@as(usize, 1), cell_fixture.calls);
    try std.testing.expectEqual(core.property.Kind.var_ref, cell_holder.propKindAt(0));
    try std.testing.expectEqual(cell, cell_holder.prop_values[0].slot.var_ref);

    cell.setVarRefValue(rt, core.JSValue.int32(9));
    const updated_cell_value = try cell_holder.getProperty(cell_key);
    defer updated_cell_value.free(rt);
    try std.testing.expectEqual(@as(?i32, 9), updated_cell_value.asInt32());
    try std.testing.expectEqual(@as(usize, 1), cell_fixture.calls);
}

test "MODULE_NS auto-init failure retains its slot Realm and retries once per read" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.RealmContext.create(rt);
    defer ctx.destroy();
    const holder = try core.Object.create(rt, core.class.ids.object, null);
    defer holder.value().free(rt);
    const key = try rt.internAtom("module_namespace_retry");
    defer rt.atoms.free(key);
    const baseline_realm_refs = ctx.header.meta().rc;
    var fixture = ModuleAutoInitFixture{
        .expected_realm = &ctx.header,
        .result = .{ .fail_once = core.JSValue.int32(88) },
    };

    try holder.defineModuleAutoInitPropertyForFixture(rt, key, core.property.Flags.data(true, false, true), ctx, &fixture.owner);
    try std.testing.expectEqual(baseline_realm_refs + 1, ctx.header.meta().rc);
    try std.testing.expectError(error.OutOfMemory, holder.getProperty(key));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqual(core.property.Kind.auto_init, holder.propKindAt(0));
    try std.testing.expectEqual(&ctx.header, holder.prop_values[0].slot.auto_init.realm_and_id.realmHeader().?);
    try std.testing.expectEqual(baseline_realm_refs + 1, ctx.header.meta().rc);

    const retried = try holder.getProperty(key);
    defer retried.free(rt);
    try std.testing.expectEqual(@as(?i32, 88), retried.asInt32());
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try std.testing.expectEqual(core.property.Kind.data, holder.propKindAt(0));
    try std.testing.expectEqual(baseline_realm_refs, ctx.header.meta().rc);
}

test "MODULE_NS auto-init reentry cannot overwrite the replacement property" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.RealmContext.create(rt);
    defer ctx.destroy();
    const holder = try core.Object.create(rt, core.class.ids.object, null);
    defer holder.value().free(rt);
    const key = try rt.internAtom("module_namespace_reentry");
    defer rt.atoms.free(key);
    var fixture = ModuleAutoInitFixture{
        .expected_realm = &ctx.header,
        .result = .{ .reenter = .{
            .rt = rt,
            .holder = holder,
            .atom_id = key,
            .replacement = core.JSValue.int32(99),
            .materialized = core.JSValue.int32(1),
        } },
    };

    try holder.defineModuleAutoInitPropertyForFixture(rt, key, core.property.Flags.data(true, false, true), ctx, &fixture.owner);
    try std.testing.expectError(error.IncompatibleDescriptor, holder.getProperty(key));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqual(core.property.Kind.data, holder.propKindAt(0));
    const replacement = try holder.getProperty(key);
    defer replacement.free(rt);
    try std.testing.expectEqual(@as(?i32, 99), replacement.asInt32());
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "auto-init slot clone and destroy retain and release the typed Realm edge exactly once" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.RealmContext.create(rt);
    defer ctx.destroy();
    const holder = try core.Object.create(rt, core.class.ids.object, null);
    defer holder.value().free(rt);
    const key = try rt.internAtom("module_namespace_clone");
    defer rt.atoms.free(key);
    var fixture = ModuleAutoInitFixture{
        .expected_realm = &ctx.header,
        .result = .{ .value = core.JSValue.int32(1) },
    };
    const baseline_realm_refs = ctx.header.meta().rc;

    try holder.defineModuleAutoInitPropertyForFixture(rt, key, core.property.Flags.data(true, false, true), ctx, &fixture.owner);
    try std.testing.expectEqual(baseline_realm_refs + 1, ctx.header.meta().rc);
    var clone = holder.prop_values[0].slot.auto_init.clone();
    try std.testing.expectEqual(baseline_realm_refs + 2, ctx.header.meta().rc);
    clone.deinit(rt);
    try std.testing.expectEqual(baseline_realm_refs + 1, ctx.header.meta().rc);
    try std.testing.expect(holder.deleteProperty(rt, key));
    try std.testing.expectEqual(baseline_realm_refs, ctx.header.meta().rc);
}

test "unmaterialized MODULE_NS slot participates in Realm cycle marking" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.RealmContext.create(rt);
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const holder = try core.Object.create(rt, core.class.ids.object, null);
    const lazy_key = try rt.internAtom("module_namespace_cycle");
    defer rt.atoms.free(lazy_key);
    const holder_key = try rt.internAtom("holder");
    defer rt.atoms.free(holder_key);
    var fixture = ModuleAutoInitFixture{
        .expected_realm = &ctx.header,
        .result = .{ .value = core.JSValue.int32(1) },
    };

    try holder.defineModuleAutoInitPropertyForFixture(rt, lazy_key, core.property.Flags.data(true, false, true), ctx, &fixture.owner);
    try global.defineOwnProperty(rt, holder_key, core.Descriptor.data(holder.value(), true, true, true));
    ctx.destroy();
    holder.value().free(rt);

    // Realm -> global -> holder -> typed AUTOINIT Realm, plus the two
    // one-property shapes.
    try expectCycleReclaimedIncludingShapes(rt, 5, rt.runObjectCycleRemoval());
}

test "ordinary and object-data payloads ignore generic realm assignment" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    _ = try global.ensureRealmPayload(rt);
    const ordinary = try core.Object.create(rt, core.class.ids.object, null);
    defer ordinary.value().free(rt);
    const object_data = try core.Object.create(rt, core.class.ids.number, null);
    defer object_data.value().free(rt);

    for ([_]*core.Object{ ordinary, object_data }) |holder| {
        try holder.setFunctionRealmGlobalPtr(rt, global);
        try holder.setFunctionRealmGlobalPtrIfNull(rt, global);
        try std.testing.expect(holder.functionRealmGlobalPtr() == null);
        try std.testing.expect(!rt.borrowedReferenceHolderRegistered(holder));
        try std.testing.expect(holder.borrowedReferenceHolderIndex() == null);
    }
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);
}

test "native call carriers do not enter borrowed realm bookkeeping" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.RealmContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const function_proto = try core.Object.create(rt, core.class.ids.object, null);
    ctx.cached_function_proto = function_proto;

    const native = try engine.core.function.nativeFunction(ctx, "native", 0);
    defer native.free(rt);
    const data = try engine.core.function.nativeDataFunctionWithPrototype(rt, function_proto, "data", 0);
    defer data.free(rt);
    const native_object: *core.Object = @fieldParentPtr("header", native.refHeader().?);
    const data_object: *core.Object = @fieldParentPtr("header", data.refHeader().?);

    try data_object.setFunctionRealmGlobalPtr(rt, global);
    try std.testing.expectEqual(ctx, native_object.nativeFunctionRealm().?);
    try std.testing.expect(data_object.nativeFunctionRealm() == null);
    try std.testing.expect(native_object.borrowedReferenceHolderIndex() == null);
    try std.testing.expect(data_object.borrowedReferenceHolderIndex() == null);
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);
}

test "generator noncarriers never enter borrowed realm bookkeeping" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    _ = try global.ensureRealmPayload(rt);

    const first = try core.Object.create(rt, core.class.ids.generator, null);
    defer first.value().free(rt);
    const second = try core.Object.create(rt, core.class.ids.async_generator, null);
    defer second.value().free(rt);
    const third = try core.Object.create(rt, core.class.ids.generator, null);
    defer third.value().free(rt);

    try first.setFunctionRealmGlobalPtr(rt, global);
    try second.setFunctionRealmGlobalPtrIfNull(rt, global);
    try third.setFunctionRealmGlobalPtr(rt, global);
    for ([_]*core.Object{ first, second, third }) |generator| {
        try std.testing.expect(generator.functionRealmGlobalPtr() == null);
        try std.testing.expect(generator.borrowedReferenceHolderIndex() == null);
        try std.testing.expect(!rt.borrowedReferenceHolderRegistered(generator));
    }
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);
}

test "leaf payload noncarriers ignore generic realm assignment" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    _ = try global.ensureRealmPayload(rt);

    const arguments_class = try rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(arguments_class, .{
        .class_name = "ArgumentsPayloadNoncarrier",
        .payload_kind = .arguments,
    });
    defer rt.classes.unregisterDynamic(arguments_class);

    const var_ref_class = try rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(var_ref_class, .{
        .class_name = "VarRefPayloadNoncarrier",
        .payload_kind = .var_ref,
    });
    defer rt.classes.unregisterDynamic(var_ref_class);

    const objects = [_]*core.Object{
        try core.Object.create(rt, core.class.ids.array_buffer, null),
        try core.Object.create(rt, arguments_class, null),
        try core.Object.create(rt, var_ref_class, null),
        try core.Object.create(rt, core.class.ids.std_file, null),
        try core.Object.create(rt, core.class.ids.module_ns, null),
    };
    defer for (objects) |object| object.value().free(rt);

    for (objects) |object| {
        try object.setFunctionRealmGlobalPtr(rt, global);
        try object.setFunctionRealmGlobalPtrIfNull(rt, global);
        try std.testing.expect(object.functionRealmGlobalPtr() == null);
        try std.testing.expect(object.borrowedReferenceHolderIndex() == null);
        try std.testing.expect(!rt.borrowedReferenceHolderRegistered(object));
    }
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);
}

test "promise weak-ref regexp and typed-array payloads ignore generic realm assignment" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    _ = try global.ensureRealmPayload(rt);

    const promise = try core.Object.create(rt, core.class.ids.promise, null);
    defer promise.value().free(rt);
    const weak_ref = try core.Object.create(rt, core.class.ids.weak_ref, null);
    defer weak_ref.value().free(rt);
    const regexp = try core.Object.create(rt, core.class.ids.regexp, null);
    defer regexp.value().free(rt);
    const typed_array = try core.Object.create(rt, core.class.ids.uint8_array, null);
    defer typed_array.value().free(rt);

    for ([_]*core.Object{ promise, weak_ref, regexp, typed_array }) |object| {
        try object.setFunctionRealmGlobalPtr(rt, global);
        try object.setFunctionRealmGlobalPtrIfNull(rt, global);
        try std.testing.expect(object.functionRealmGlobalPtr() == null);
        try std.testing.expect(object.borrowedReferenceHolderIndex() == null);
        try std.testing.expect(!rt.borrowedReferenceHolderRegistered(object));
    }
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);

    // WeakRef's payload-resident lifetime list is real weak-edge machinery and
    // remains independent from the retired generic realm registry entries.
    try std.testing.expectEqual(weak_ref, rt.weak_reference_holder_head.?);
    try std.testing.expectEqual(weak_ref, rt.weak_reference_holder_tail.?);
    try std.testing.expect(weak_ref.weakReferenceHolderPrevious() == null);
    try std.testing.expect(weak_ref.weakReferenceHolderNext() == null);
}

test "iterator collection and disposable payloads ignore generic realm assignment" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    _ = try global.ensureRealmPayload(rt);

    const iterator = try core.Object.create(rt, core.class.ids.map_iterator, null);
    defer iterator.value().free(rt);
    const collection = try core.Object.create(rt, core.class.ids.map, null);
    defer collection.value().free(rt);
    const disposable = try core.Object.create(rt, core.class.ids.disposable_stack, null);
    defer disposable.value().free(rt);

    for ([_]*core.Object{ iterator, collection, disposable }) |object| {
        try object.setFunctionRealmGlobalPtr(rt, global);
        try object.setFunctionRealmGlobalPtrIfNull(rt, global);
        try std.testing.expect(object.functionRealmGlobalPtr() == null);
        try std.testing.expect(object.borrowedReferenceHolderIndex() == null);
        try std.testing.expect(!rt.borrowedReferenceHolderRegistered(object));
    }
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);
}

test "collection iterator prototype follows explicit active realm, never receiver" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const first_realm = try core.RealmContext.create(rt);
    defer first_realm.destroy();
    const first_global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try first_global.ensureGlobalPayload(rt);
    first_realm.global = first_global;

    const second_realm = try core.RealmContext.create(rt);
    defer second_realm.destroy();
    const second_global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try second_global.ensureGlobalPayload(rt);
    second_realm.global = second_global;

    const first_iterator_prototype = try core.Object.create(rt, core.class.ids.object, null);
    defer first_iterator_prototype.value().free(rt);
    const second_iterator_prototype = try core.Object.create(rt, core.class.ids.object, null);
    defer second_iterator_prototype.value().free(rt);
    first_realm.class_prototypes[core.class.ids.map_iterator] = first_iterator_prototype.value().dup();
    second_realm.class_prototypes[core.class.ids.map_iterator] = second_iterator_prototype.value().dup();

    const map = try core.Object.create(rt, core.class.ids.map, first_iterator_prototype);
    defer map.value().free(rt);

    const context_iterator_value = try engine.exec.collection_ops.methodCallWithContext(
        second_realm,
        map.value(),
        @intFromEnum(engine.exec.collection_ops.PrototypeMethod.keys),
        &.{},
        &.{},
    );
    defer context_iterator_value.free(rt);
    const context_iterator = try core.Object.expect(context_iterator_value);
    try std.testing.expectEqual(second_iterator_prototype, context_iterator.getPrototype().?);

    // The explicit active global wins even when the caller passes a different
    // current context and the receiver belongs to that context's object graph.
    const iterator_value = try engine.exec.collection_ops.methodCallWithGlobal(
        first_realm,
        second_global,
        map.value(),
        @intFromEnum(engine.exec.collection_ops.PrototypeMethod.keys),
        &.{},
        &.{},
    );
    defer iterator_value.free(rt);
    const result_iterator = try core.Object.expect(iterator_value);
    try std.testing.expectEqual(second_iterator_prototype, result_iterator.getPrototype().?);

    // Payload-only helpers have no Realm authority and must fail rather than
    // recovering one from the collection receiver.
    try std.testing.expectError(
        error.InvalidBuiltinRegistry,
        engine.exec.collection_ops.methodCall(
            rt,
            map.value(),
            @intFromEnum(engine.exec.collection_ops.PrototypeMethod.keys),
            &.{},
        ),
    );
}

test "weak reference holders use a lifetime intrusive list" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const strong_map = try core.Object.create(rt, core.class.ids.map, null);
    const first = try core.Object.create(rt, core.class.ids.weakmap, null);
    const middle = try core.Object.create(rt, core.class.ids.weak_ref, null);
    const last = try core.Object.create(rt, core.class.ids.finalization_registry, null);

    // QuickJS registers every weak-capable holder for its full payload
    // lifetime, including an empty WeakMap / FinalizationRegistry. Strong
    // Map shares the collection payload shape but must not enter this list.
    try std.testing.expectEqual(first, rt.weak_reference_holder_head.?);
    try std.testing.expectEqual(last, rt.weak_reference_holder_tail.?);
    try std.testing.expectEqual(@as(?*core.Object, null), first.weakReferenceHolderPrevious());
    try std.testing.expectEqual(@as(?*core.Object, middle), first.weakReferenceHolderNext());
    try std.testing.expectEqual(@as(?*core.Object, first), middle.weakReferenceHolderPrevious());
    try std.testing.expectEqual(@as(?*core.Object, last), middle.weakReferenceHolderNext());
    try std.testing.expectEqual(@as(?*core.Object, middle), last.weakReferenceHolderPrevious());
    try std.testing.expectEqual(@as(?*core.Object, null), last.weakReferenceHolderNext());

    middle.value().free(rt);
    try std.testing.expectEqual(@as(?*core.Object, last), first.weakReferenceHolderNext());
    try std.testing.expectEqual(@as(?*core.Object, first), last.weakReferenceHolderPrevious());

    first.value().free(rt);
    try std.testing.expectEqual(last, rt.weak_reference_holder_head.?);
    try std.testing.expectEqual(last, rt.weak_reference_holder_tail.?);

    last.value().free(rt);
    try std.testing.expectEqual(@as(?*core.Object, null), rt.weak_reference_holder_head);
    try std.testing.expectEqual(@as(?*core.Object, null), rt.weak_reference_holder_tail);
    strong_map.value().free(rt);
}

test "weak collection borrowed holder cache supports reverse teardown" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var holders: [8]?*core.Object = @splat(null);
    var keys: [8]?*core.Object = @splat(null);
    defer {
        for (&holders) |*holder| {
            if (holder.*) |object| object.value().free(rt);
            holder.* = null;
        }
        for (&keys) |*key| {
            if (key.*) |object| object.value().free(rt);
            key.* = null;
        }
    }

    for (&holders, &keys, 0..) |*holder_slot, *key_slot, index| {
        const holder = try core.Object.create(rt, core.class.ids.weakmap, null);
        holder_slot.* = holder;
        const key = try core.Object.create(rt, core.class.ids.object, null);
        key_slot.* = key;
        const value = try core.Object.create(rt, core.class.ids.object, null);
        var value_owned = true;
        defer if (value_owned) value.value().free(rt);
        try appendWeakCollectionEntry(rt, holder, key, value.value());
        value.value().free(rt);
        value_owned = false;
        try std.testing.expectEqual(@as(?usize, index), holder.borrowedReferenceHolderIndex());
    }

    var remaining = holders.len;
    while (remaining != 0) {
        remaining -= 1;
        const holder = holders[remaining].?;
        holder.value().free(rt);
        holders[remaining] = null;
        try std.testing.expectEqual(remaining, rt.borrowed_reference_holders.len);
    }
}

test "ordinary last-ref values do not schedule irrelevant borrowed cleanup" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ordinary = try core.Object.create(rt, core.class.ids.object, null);
    defer ordinary.value().free(rt);

    rt.beginBorrowedWeakCleanup();
    defer rt.endBorrowedWeakCleanup();
    try std.testing.expect(rt.prepareBorrowedWeakCleanupForLastRefValue(ordinary.value()) != null);
    try std.testing.expectEqual(@as(usize, 0), rt.borrowedWeakCleanupIdentityCount());
}

test "fresh object prototype rebinding reuses the shared empty root shape" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const prototype = try core.Object.create(rt, core.class.ids.object, null);
    defer prototype.value().free(rt);
    const first = try core.Object.create(rt, core.class.ids.generator, null);
    defer first.value().free(rt);
    const second = try core.Object.create(rt, core.class.ids.async_generator, null);
    defer second.value().free(rt);

    try first.setFreshObjectPrototype(rt, prototype);
    try second.setFreshObjectPrototype(rt, prototype);

    try std.testing.expectEqual(prototype, first.getPrototype().?);
    try std.testing.expectEqual(prototype, second.getPrototype().?);
    try std.testing.expectEqual(first.shape_ref, second.shape_ref);
    try std.testing.expectEqual(@as(u32, 0), first.shape_ref.prop_count);
}

test "replacing auto-init transfers the owned Realm edge" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const first_ctx = try core.RealmContext.create(rt);
    defer first_ctx.destroy();
    const first_global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try first_global.ensureGlobalPayload(rt);
    first_ctx.global = first_global;
    const second_ctx = try core.RealmContext.create(rt);
    defer second_ctx.destroy();
    const second_global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try second_global.ensureGlobalPayload(rt);
    second_ctx.global = second_global;
    const holder = try core.Object.create(rt, core.class.ids.object, null);
    defer holder.value().free(rt);
    const key = try rt.internAtom("lazy_replace_realm");
    defer rt.atoms.free(key);

    try holder.defineAutoInitPropertyWithRealmAndNative(
        rt,
        key,
        "lazy_replace_realm",
        0,
        core.property.Flags.data(true, false, true),
        first_global,
        0,
    );
    try std.testing.expectEqual(&first_ctx.header, holder.prop_values[0].slot.auto_init.realm_and_id.realmHeader().?);

    try holder.replaceAutoInitPropertyWithRealmAndNative(
        rt,
        key,
        "lazy_replace_realm",
        0,
        core.property.Flags.data(true, false, true),
        second_global,
        0,
    );

    try std.testing.expectEqual(&second_ctx.header, holder.prop_values[0].slot.auto_init.realm_and_id.realmHeader().?);
}

test "deleting auto-init releases its owned Realm edge" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.RealmContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const holder = try core.Object.create(rt, core.class.ids.object, null);
    defer holder.value().free(rt);
    const key = try rt.internAtom("lazy_delete_realm");
    defer rt.atoms.free(key);

    const baseline_realm_refs = ctx.header.meta().rc;
    try holder.definePerformanceAutoInitProperty(rt, key, core.property.Flags.data(true, false, true), global);
    try std.testing.expectEqual(baseline_realm_refs + 1, ctx.header.meta().rc);

    try std.testing.expect(holder.deleteProperty(rt, key));
    try std.testing.expectEqual(baseline_realm_refs, ctx.header.meta().rc);
}

test "ordinary auto-init replacement releases each owned Realm edge" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.RealmContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    const object_proto_slot = try global.cachedRealmValueSlot(rt, .object_prototype);
    object_proto_slot.* = global.value().dup();
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

    const baseline_realm_refs = ctx.header.meta().rc;
    try holder.definePerformanceAutoInitProperty(rt, define_key, core.property.Flags.data(true, false, true), global);
    try std.testing.expectEqual(baseline_realm_refs + 1, ctx.header.meta().rc);

    try holder.defineOwnProperty(rt, define_key, core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    try std.testing.expectEqual(baseline_realm_refs, ctx.header.meta().rc);

    try holder.definePerformanceAutoInitProperty(rt, set_key, core.property.Flags.data(true, false, true), global);
    try std.testing.expectEqual(baseline_realm_refs + 1, ctx.header.meta().rc);

    try holder.setProperty(rt, set_key, core.JSValue.int32(2));
    try std.testing.expectEqual(baseline_realm_refs, ctx.header.meta().rc);

    try holder.definePerformanceAutoInitProperty(rt, own_set_key, core.property.Flags.data(true, false, true), global);
    try std.testing.expectEqual(baseline_realm_refs + 1, ctx.header.meta().rc);

    try std.testing.expect(try holder.setOwnWritableDataProperty(rt, own_set_key, core.JSValue.int32(3)));
    try std.testing.expectEqual(baseline_realm_refs, ctx.header.meta().rc);

    try holder.definePerformanceAutoInitProperty(rt, simple_set_key, core.property.Flags.data(true, false, true), global);
    try std.testing.expectEqual(baseline_realm_refs + 1, ctx.header.meta().rc);

    try std.testing.expect(try holder.setOrDefineOwnDataPropertyForSimpleSet(rt, simple_set_key, core.JSValue.int32(4)));
    try std.testing.expectEqual(baseline_realm_refs, ctx.header.meta().rc);
}

test "specialized auto-init producers retain the same typed Realm owner" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.RealmContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;

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
    try replace_holder.defineAutoInitPropertyWithRealm(rt, replace_key, "replace", 0, flags, global);
    try replace_holder.replaceAutoInitPropertyWithRealmAndNative(rt, replace_key, "replace", 0, flags, global, 0);

    const holders = [_]*core.Object{
        navigator_holder,
        performance_holder,
        namespace_holder,
        host_holder,
        replace_holder,
    };
    for (holders) |holder| {
        const slot = holder.prop_values[0].slot.auto_init;
        try std.testing.expectEqual(core.property.AutoInitId.prop, slot.realm_and_id.id());
        try std.testing.expectEqual(&ctx.header, slot.realm_and_id.realmHeader().?);
    }
    try std.testing.expectEqual(@as(i32, 1 + holders.len), ctx.header.meta().rc);
}

test "materialized auto-init true C function owns its construction realm" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.RealmContext.create(rt);
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    _ = try global.ensureGlobalPayload(rt);
    ctx.global = global;
    try global.setCachedFunctionProto(rt, global);
    const holder = try core.Object.create(rt, core.class.ids.object, null);
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

    const function_value = try holder.getProperty(host_key);
    const function_header = function_value.refHeader().?;
    const function_object: *core.Object = @fieldParentPtr("header", function_header);

    try std.testing.expectEqual(ctx, function_object.nativeFunctionRealm().?);
    try std.testing.expectEqual(global, function_object.functionRealmGlobalPtr().?);

    ctx.destroy();
    try std.testing.expectEqual(ctx, rt.firstContext().?);
    try std.testing.expectEqual(global, function_object.functionRealmGlobalPtr().?);

    function_value.free(rt);
    holder.value().free(rt);
    try std.testing.expect(rt.firstContext() == null);
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
    try std.testing.expectEqual(@as(usize, 0), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 0), weakmap.weakCollectionEntries().len);
    try std.testing.expectEqual(@as(i32, 1), value.header.meta().rc);

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
    try std.testing.expectEqual(@as(i32, 1), value.header.meta().rc);
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

    var symbol_value = try rt.symbolValue(symbol_atom);
    try weak_ref.setWeakRefTarget(rt, symbol_value);

    {
        const live = weak_ref.weakRefDeref(rt);
        defer live.free(rt);
        try std.testing.expect(live.same(symbol_value));
    }
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    symbol_value.free(rt);
    symbol_value = core.JSValue.undefinedValue();

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

    const set_result = try engine.exec.collection_ops.methodCall(rt, weakmap.value(), 1, &.{ map_key.value(), core.JSValue.int32(1) });
    set_result.free(rt);
    try std.testing.expectEqual(@as(usize, 1), rt.borrowed_reference_holders.len);

    const delete_result = try engine.exec.collection_ops.methodCall(rt, weakmap.value(), 4, &.{map_key.value()});
    defer delete_result.free(rt);
    try std.testing.expectEqual(@as(?bool, true), delete_result.asBool());
    try std.testing.expectEqual(@as(usize, 0), weakmap.weakCollectionEntries().len);
    try std.testing.expectEqual(@as(usize, 0), rt.borrowed_reference_holders.len);

    const weakset = try core.Object.create(rt, core.class.ids.weakset, null);
    defer weakset.value().free(rt);
    const set_key = try core.Object.create(rt, core.class.ids.object, null);
    defer set_key.value().free(rt);

    const add_result = try engine.exec.collection_ops.methodCall(rt, weakset.value(), 6, &.{set_key.value()});
    add_result.free(rt);
    try std.testing.expectEqual(@as(usize, 1), rt.borrowed_reference_holders.len);

    const clear_result = try engine.exec.collection_ops.methodCall(rt, weakset.value(), 5, &.{});
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

test "finalization registry unregister handles token equal to target" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const registry = try core.Object.create(rt, core.class.ids.finalization_registry, null);
    defer registry.value().free(rt);
    const target_and_token = try core.Object.create(rt, core.class.ids.object, null);
    var target_and_token_value = target_and_token.value();
    defer target_and_token_value.free(rt);

    try appendFinalizationRegistryCell(
        rt,
        registry,
        target_and_token_value,
        core.JSValue.undefinedValue(),
        target_and_token_value,
    );

    try std.testing.expect(registry.unregisterFinalizationRegistryCells(rt, target_and_token_value));
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
    _ = rt.runObjectCycleRemoval();

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

    const delete_result = try engine.exec.collection_ops.methodCall(rt, weakmap.value(), 4, &.{key.value()});
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

    const clear_result = try engine.exec.collection_ops.methodCall(rt, weakmap.value(), 5, &.{});
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
    if (!core.memory.force_gc_on_allocation_enabled) {
        _ = rt.runObjectCycleRemoval();
        try std.testing.expectEqual(@as(usize, 0), map.weakCollectionEntries().len);
        try std.testing.expectEqual(@as(usize, live_empty_object_gc_count), rt.gc.liveCount());
    } else {
        // TODO(S3): weak-collection liveness under forced GC.
    }
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
        const result = try engine.exec.collection_ops.methodCall(rt, map.value(), 1, &.{ key.value(), core.JSValue.int32(@intCast(index)) });
        result.free(rt);
    }
    try std.testing.expectEqual(@as(usize, 8), map.weakCollectionEntries().len);
    try std.testing.expectEqual(@as(usize, 8), rt.gcStats().weak_ref_count);
    try std.testing.expect(map.collectionBucketHeads().len != 0);

    keys[0].value().free(rt);
    first_key_released = true;
    try std.testing.expectEqual(@as(usize, single_object_self_cycle_reclaimed_count), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 0), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 7), map.weakCollectionEntries().len);
    try std.testing.expectEqual(@as(usize, 7), rt.gcStats().weak_ref_count);
    try std.testing.expectEqual(@as(usize, 0), map.collectionBucketHeads().len);

    var index: usize = 1;
    while (index < key_count) : (index += 1) {
        const value = try engine.exec.collection_ops.methodCall(rt, map.value(), 2, &.{keys[index].value()});
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
    try std.testing.expectEqual(@as(usize, 0), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(usize, 0), registry.finalizationRegistryCells().len);
    try std.testing.expectEqual(@as(i32, 1), held.header.meta().rc);

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

test "finalization registry unregister cannot remove queued cleanup cell" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const cleanup = try core.Object.create(rt, core.class.ids.object, null);
    defer cleanup.value().free(rt);
    const registry = try core.Object.createFinalizationRegistry(rt, ctx, null);
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

    const collected = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, single_object_self_cycle_reclaimed_count), collected.freed_objects);
    try std.testing.expectEqual(@as(usize, 0), registry.pendingFinalizationCellCountForTest());

    const enqueued = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 0), enqueued.freed_objects);
    try std.testing.expectEqual(@as(usize, 1), rt.pendingFinalizationJobCountForTest());
    try std.testing.expectEqual(@as(usize, 0), registry.pendingFinalizationCellCountForTest());
    try std.testing.expect(!registry.unregisterFinalizationRegistryCells(rt, token.value()));
    try std.testing.expectEqual(@as(usize, 0), registry.finalizationRegistryCells().len);

    rt.clearPendingFinalizationJobs();
}

test "finalization registry enqueue OOM retains stable pending cells for same-runtime retry" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const cleanup = try core.Object.create(rt, core.class.ids.object, null);
    defer cleanup.value().free(rt);
    const registry = try core.Object.createFinalizationRegistry(rt, ctx, null);
    defer registry.value().free(rt);
    registry.finalizationRegistryCleanupCallbackSlot().* = cleanup.value().dup();

    var targets: [3]*core.Object = undefined;
    for (&targets, 0..) |*slot, index| {
        const target = try core.Object.create(rt, core.class.ids.object, null);
        slot.* = target;
        try registry.appendFinalizationRegistryCell(
            rt,
            target.value(),
            core.JSValue.int32(@intCast(index + 1)),
            core.JSValue.undefinedValue(),
        );
    }

    // Warm the collector while all targets are live so the injected failure is
    // specifically the first unified-FIFO publication allocation.
    _ = try rt.tryRunObjectCycleRemoval();
    for (targets) |target| target.value().free(rt);

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    defer rt.setMemoryLimit(null);
    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 0), rt.pendingFinalizationJobCountForTest());
    try std.testing.expectEqual(@as(usize, 3), registry.pendingFinalizationCellCountForTest());
    try std.testing.expectEqual(@as(usize, 3), registry.finalizationRegistryCells().len);
    try std.testing.expectEqual(ctx, registry.finalizationRegistryRealmContext().?);

    rt.setMemoryLimit(null);
    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 0), registry.pendingFinalizationCellCountForTest());
    try std.testing.expectEqual(@as(usize, 0), registry.finalizationRegistryCells().len);
    try std.testing.expectEqual(@as(usize, 3), rt.pendingFinalizationJobCountForTest());

    for (rt.job_queue.jobs[0..3], 0..) |job, index| {
        try std.testing.expectEqual(ctx, job.realm.borrow().?);
        const payload = switch (job.payload) {
            .finalization => |payload| payload,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(?i32, @intCast(index + 1)), payload.held_value.asInt32());
    }

    // A further weak sweep cannot publish any cell twice.
    _ = try rt.tryRunObjectCycleRemoval();
    try std.testing.expectEqual(@as(usize, 3), rt.pendingFinalizationJobCountForTest());
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

    try std.testing.expectEqual(@as(usize, live_empty_object_gc_count), rt.gc.liveCount());
    try std.testing.expectEqual(@as(usize, 0), rt.runObjectCycleRemoval());
}

test "object allocation collects reclaimable cycles before memory-limit rejection" {
    const rt = try core.JSRuntime.createWithOptions(std.testing.allocator, .{
        .gc_threshold = 256 * 1024 * 1024,
    });
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.object, null);
    const key = try rt.internAtom("gc-before-limit-self");
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(object.value(), true, true, true));
    object.value().free(rt);

    // Exactly the current logical heap leaves no room for a replacement object
    // unless the pending threshold collection runs before MemoryAccount checks
    // the allocation. This is the ordering used by QJS JS_NewObjectFromShape.
    rt.setGCThreshold(0);
    rt.setMemoryLimit(rt.memory.allocated_bytes);
    defer rt.setMemoryLimit(null);

    const replacement = try core.Object.create(rt, core.class.ids.object, null);
    replacement.value().free(rt);
    try expectNoLiveGc(rt);
}

test "gc threshold API resets after scheduled collection and survives force-GC instrumentation" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    try std.testing.expectEqual(core.runtime.default_gc_threshold, rt.gcThreshold());
    rt.setGCThreshold(0);
    try std.testing.expectEqual(@as(usize, 0), rt.gcThreshold());

    const before_object_allocation = rt.memory.allocated_bytes;
    const survivor = try core.Object.create(rt, core.class.ids.object, null);
    defer survivor.value().free(rt);

    if (comptime core.memory.force_gc_on_allocation_enabled) {
        // Synthetic pre-allocation collections must not rewrite user policy.
        try std.testing.expectEqual(@as(usize, 0), rt.gcThreshold());
    } else {
        // QJS resets malloc_gc_threshold immediately after its pre-object GC,
        // before the triggering JSObject allocation is charged.
        const expected = before_object_allocation + (before_object_allocation >> 1);
        try std.testing.expectEqual(expected, rt.gcThreshold());
    }
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
    try expectCycleReclaimedIncludingShapes(rt, 4, rt.runObjectCycleRemoval());
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
    try std.testing.expectEqual(@as(usize, 4), rt.runObjectCycleRemoval());
    try std.testing.expectEqual(@as(i32, 1), external.header.meta().rc);
    external.value().free(rt);
    try expectNoLiveGc(rt);
}

test "module namespace shape VarRef cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const namespace = try core.Object.create(rt, core.class.ids.module_ns, null);
    const target = try core.Object.create(rt, core.class.ids.object, null);
    const key = try rt.internAtom("namespace");
    defer rt.atoms.free(key);
    const export_name = try rt.internAtom("value");
    defer rt.atoms.free(export_name);

    try target.defineOwnProperty(rt, key, core.Descriptor.data(namespace.value(), true, true, true));
    const cell = try core.VarRef.createClosed(rt, target.value().dup());
    try namespace.defineModuleVarRefProperty(rt, export_name, cell);

    namespace.value().free(rt);
    target.value().free(rt);
    try expectCycleReclaimedIncludingShapes(rt, 5, rt.runObjectCycleRemoval());
}

test "mapped arguments var-ref cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const arguments = try core.Object.create(rt, core.class.ids.mapped_arguments, null);
    const target = try core.Object.create(rt, core.class.ids.object, null);
    const key = try rt.internAtom("arguments");
    defer rt.atoms.free(key);

    const refs = try arguments.allocateMappedArgumentsVarRefsAssumingEmpty(rt, 1);
    refs[0] = try core.VarRef.createClosed(rt, target.value().dup());
    try target.defineOwnProperty(rt, key, core.Descriptor.data(arguments.value(), true, true, true));

    arguments.value().free(rt);
    target.value().free(rt);
    // arguments -> VarRef -> target -> arguments, plus the two object shapes.
    try expectCycleReclaimedIncludingShapes(rt, 5, rt.runObjectCycleRemoval());
}

test "array element self-cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const array = try core.Object.createArray(rt, null);
    const index = core.atom.atomFromUInt32(0);
    try std.testing.expect(try array.appendDenseArrayIndex(rt, 0, index, array.value()));

    array.value().free(rt);
    try expectCycleReclaimedIncludingShapes(rt, single_object_self_cycle_reclaimed_count, rt.runObjectCycleRemoval());
}

test "typed-array buffer self-cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const view = try core.Object.create(rt, core.class.ids.object, null);
    try view.ensureTypedArrayPayload(rt);
    view.typedArrayBufferSlot().* = view.value().dup();

    view.value().free(rt);
    try expectCycleReclaimedIncludingShapes(rt, single_object_self_cycle_reclaimed_count, rt.runObjectCycleRemoval());
}

test "regexp lastIndex self-cycle is released by runtime cycle removal" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const regexp = try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.regexp, null, 1);
    try regexp.initializeRegExpLastIndex(rt);
    const source = try core.string.String.createAscii(rt, "a");
    defer source.value().free(rt);
    try regexp.setRegexpSource(rt, source.value());
    try regexp.setRegexpCompiledBytecode(rt, &.{ 1, 2, 3 });
    try regexp.setProperty(rt, core.atom.ids.lastIndex, regexp.value());

    regexp.value().free(rt);
    try expectCycleReclaimedIncludingShapes(rt, single_object_self_cycle_reclaimed_count, rt.runObjectCycleRemoval());
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
    try std.testing.expectEqual(@as(i32, 2), constant_string.header().rc);
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
    try std.testing.expectEqual(@as(i32, 2), bound_string.header().rc);
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
    const constant_value = try rt.symbolValue(constant_symbol);
    const home_value = try rt.symbolValue(home_symbol);
    var bytecode = try core.FunctionRecord.createBytecode(
        &rt.memory,
        &rt.atoms,
        name,
        &.{0xaa},
        &.{constant_value},
        .normal,
        false,
        home_value,
    );
    constant_value.free(rt);
    home_value.free(rt);
    var bytecode_alive = true;
    defer if (bytecode_alive) bytecode.destroy(rt);

    const target_symbol = try rt.atoms.newValueSymbol("gc-function-record-target");
    const this_symbol = try rt.atoms.newValueSymbol("gc-function-record-this");
    const arg_symbol = try rt.atoms.newValueSymbol("gc-function-record-arg");
    const target_value = try rt.symbolValue(target_symbol);
    const this_value = try rt.symbolValue(this_symbol);
    const arg_value = try rt.symbolValue(arg_symbol);
    var bound = try core.FunctionRecord.createBound(
        &rt.memory,
        &rt.atoms,
        target_value,
        this_value,
        &.{arg_value},
        false,
    );
    target_value.free(rt);
    this_value.free(rt);
    arg_value.free(rt);
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

test "realm module registry keeps published record addresses stable" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const first_name = try rt.internAtom("stable-first.mjs");
    defer rt.atoms.free(first_name);
    const first = try publishEmptyModule(rt, &ctx.modules, first_name);
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(core.ModuleRecord, "header"));
    try std.testing.expectEqual(core.gc.GcKind.module, first.header.meta().kind);

    var buffer: [48]u8 = undefined;
    for (0..48) |index| {
        const text = try std.fmt.bufPrint(&buffer, "stable-{d}.mjs", .{index});
        const name = try rt.internAtom(text);
        _ = try publishEmptyModule(rt, &ctx.modules, name);
        rt.atoms.free(name);
        try std.testing.expectEqual(first, ctx.modules.find(first_name).?);
    }
}

test "module registries isolate records between realms" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const first_ctx = try core.JSContext.create(rt);
    defer first_ctx.destroy();
    const second_ctx = try core.JSContext.create(rt);
    defer second_ctx.destroy();

    const module_name = try rt.internAtom("shared-name.mjs");
    defer rt.atoms.free(module_name);
    const binding_name = try rt.internAtom("only-in-first");
    defer rt.atoms.free(binding_name);

    var first_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer first_pending.deinit(rt);
    try first_pending.addExport(binding_name, binding_name, 0);
    const first = try publishFreshModule(&first_ctx.modules, module_name, &first_pending);
    const second = try publishEmptyModule(rt, &second_ctx.modules, module_name);
    try std.testing.expect(first != second);
    try std.testing.expectEqual(first, first_ctx.modules.find(module_name).?);
    try std.testing.expectEqual(second, second_ctx.modules.find(module_name).?);

    first.setStatus(.linked);
    try std.testing.expectEqual(@as(usize, 1), first.exports.len);
    try std.testing.expectEqual(core.module.Status.linked, first.status);
    try std.testing.expectEqual(@as(usize, 0), second.exports.len);
    try std.testing.expectEqual(core.module.Status.unlinked, second.status);
}

test "module registry ownership is one-way and does not retain its realm" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const module_name = try rt.internAtom("no-module-realm-backref.mjs");
    defer rt.atoms.free(module_name);
    const realm_refs = ctx.header.meta().rc;
    const record = try publishEmptyModule(rt, &ctx.modules, module_name);
    try std.testing.expectEqual(realm_refs, ctx.header.meta().rc);

    record.retain();
    try std.testing.expectEqual(realm_refs, ctx.header.meta().rc);
    record.release(rt);
    try std.testing.expectEqual(realm_refs, ctx.header.meta().rc);
}

test "module finalizer self-unlinks a still-linked realm registry node" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const module_name = try rt.internAtom("finalizer-self-unlink.mjs");
    defer rt.atoms.free(module_name);
    const owner_atom_refs = rt.atoms.refCount(module_name).?;
    const record = try publishEmptyModule(rt, &ctx.modules, module_name);
    try std.testing.expectEqual(owner_atom_refs + 1, rt.atoms.refCount(module_name).?);
    try std.testing.expectEqual(@as(usize, 1), ctx.modules.count);

    // Internal finalizer-path probe: consume the registry base-ref while the
    // node is still linked. This is deliberately not a caller-facing release
    // pattern; it verifies ModuleRecord.destroyFromHeader splices itself before
    // Realm teardown later sees the now-empty registry.
    record.release(rt);
    try std.testing.expect(ctx.modules.head == null);
    try std.testing.expect(ctx.modules.tail == null);
    try std.testing.expectEqual(@as(usize, 0), ctx.modules.count);
    try std.testing.expect(ctx.modules.find(module_name) == null);
    try std.testing.expectEqual(owner_atom_refs, rt.atoms.refCount(module_name).?);
    try rt.gc.verifyHeapAccounting(rt);
}

test "externally retained module outlives realm registry teardown" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    var ctx_alive = true;
    defer if (ctx_alive) ctx.destroy();

    const module_name = try rt.internAtom("retained-after-realm.mjs");
    defer rt.atoms.free(module_name);
    const owner_atom_refs = rt.atoms.refCount(module_name).?;
    const record = try publishEmptyModule(rt, &ctx.modules, module_name);
    var record_retained = false;
    defer if (record_retained) record.release(rt);
    record.retain();
    record_retained = true;

    try std.testing.expectEqual(owner_atom_refs + 1, rt.atoms.refCount(module_name).?);
    try std.testing.expectEqual(@as(i32, 2), record.header.meta().rc);

    ctx.destroy();
    ctx_alive = false;
    try std.testing.expect(rt.firstContext() == null);
    try std.testing.expect(record.registry == null);
    try std.testing.expectEqual(@as(i32, 1), record.header.meta().rc);
    try std.testing.expectEqual(owner_atom_refs + 1, rt.atoms.refCount(module_name).?);

    record.release(rt);
    record_retained = false;
    try std.testing.expectEqual(owner_atom_refs, rt.atoms.refCount(module_name).?);
}

test "module namespace strong edge participates in realm object cycle collection" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    var ctx_alive = true;
    defer if (ctx_alive) ctx.destroy();

    const module_name = try rt.internAtom("realm-module-cycle.mjs");
    defer rt.atoms.free(module_name);
    const record = try publishEmptyModule(rt, &ctx.modules, module_name);

    const realm_record = try core.Object.create(rt, core.class.ids.object, null);
    var object_transferred = false;
    defer if (!object_transferred) realm_record.value().free(rt);
    var realm_owner = core.RealmRef.retain(ctx);
    defer realm_owner.deinit();
    try realm_record.installOwnedRealmRef(rt, &realm_owner);
    record.publishModuleNamespaceNoFail(realm_record.value());
    object_transferred = true;

    ctx.destroy();
    ctx_alive = false;
    try std.testing.expect(rt.firstContext() != null);
    try std.testing.expectEqual(@as(usize, 1), rt.memoryUsage().module_count);

    try std.testing.expect(rt.runObjectCycleRemoval() >= 3);
    try std.testing.expect(rt.firstContext() == null);
    try std.testing.expectEqual(@as(usize, 0), rt.memoryUsage().module_count);
}

test "Nth module allocation OOM leaves registry and Atom ownership recoverable" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const rt = try core.JSRuntime.create(failing_allocator.allocator());
    defer rt.destroy();
    defer failing_allocator.fail_index = std.math.maxInt(usize);
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    var names: [64]core.Atom = undefined;
    var names_initialized: usize = 0;
    defer for (names[0..names_initialized]) |name| rt.atoms.free(name);
    var buffer: [48]u8 = undefined;
    while (names_initialized < names.len) : (names_initialized += 1) {
        const text = try std.fmt.bufPrint(&buffer, "nth-oom-{d}.mjs", .{names_initialized});
        names[names_initialized] = try rt.internAtom(text);
    }

    // Seed one record, then fail a later backing allocation so several
    // publications commit before the selected Nth create is rejected.
    _ = try publishEmptyModule(rt, &ctx.modules, names[0]);
    const successful_creates_before_failure = 7;
    failing_allocator.fail_index = failing_allocator.alloc_index + successful_creates_before_failure;

    var failed_index: ?usize = null;
    create_until_failure: for (1..names.len) |index| {
        _ = publishEmptyModule(rt, &ctx.modules, names[index]) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failed_index = index;
            break :create_until_failure;
        };
    }
    const failed = failed_index orelse return error.TestUnexpectedResult;
    try std.testing.expect(failed > 1);
    try std.testing.expectEqual(failed, ctx.modules.count);
    try std.testing.expect(ctx.modules.find(names[failed]) == null);
    try std.testing.expectEqual(@as(usize, 1), rt.atoms.refCount(names[failed]).?);
    try std.testing.expectEqual(@as(usize, 2), rt.atoms.refCount(names[failed - 1]).?);

    failing_allocator.fail_index = std.math.maxInt(usize);
    const recovered = try publishEmptyModule(rt, &ctx.modules, names[failed]);
    try std.testing.expectEqual(recovered, ctx.modules.find(names[failed]).?);
    try std.testing.expectEqual(failed + 1, ctx.modules.count);
    try std.testing.expectEqual(@as(usize, 2), rt.atoms.refCount(names[failed]).?);
}

test "runtime memory usage counts linked and realm-unlinked retained modules" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    var ctx_alive = true;
    defer if (ctx_alive) ctx.destroy();

    const empty = rt.memoryUsage();
    try std.testing.expectEqual(@as(usize, 0), empty.module_count);
    try std.testing.expectEqual(@as(usize, 0), empty.module_bytes);

    const module_name = try rt.internAtom("memory-usage-module.mjs");
    defer rt.atoms.free(module_name);
    const record = try publishEmptyModule(rt, &ctx.modules, module_name);
    const linked = rt.memoryUsage();
    try std.testing.expectEqual(@as(usize, 1), linked.module_count);
    try std.testing.expectEqual(@sizeOf(core.ModuleRecord), linked.module_bytes);
    try rt.gc.verifyHeapAccounting(rt);

    record.retain();
    var record_retained = true;
    defer if (record_retained) record.release(rt);
    ctx.destroy();
    ctx_alive = false;
    const unlinked_retained = rt.memoryUsage();
    try std.testing.expect(record.registry == null);
    try std.testing.expectEqual(@as(usize, 1), unlinked_retained.module_count);
    try std.testing.expectEqual(@sizeOf(core.ModuleRecord), unlinked_retained.module_bytes);
    try rt.gc.verifyHeapAccounting(rt);

    record.release(rt);
    record_retained = false;
    const released = rt.memoryUsage();
    try std.testing.expectEqual(@as(usize, 0), released.module_count);
    try std.testing.expectEqual(@as(usize, 0), released.module_bytes);
    try rt.gc.verifyHeapAccounting(rt);
}

test "module publication retains indexed metadata and all strong value edges" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const module_name = try rt.internAtom("main.mjs");
    const dep_name = try rt.internAtom("dep.mjs");
    const import_name = try rt.internAtom("value");
    const local_name = try rt.internAtom("local");
    const export_name = try rt.internAtom("default");
    const attr_key = try rt.internAtom("type");
    const attr_value = try rt.internAtom("json");
    defer {
        rt.atoms.free(module_name);
        rt.atoms.free(dep_name);
        rt.atoms.free(import_name);
        rt.atoms.free(local_name);
        rt.atoms.free(export_name);
        rt.atoms.free(attr_key);
        rt.atoms.free(attr_value);
    }

    const dependency = try publishEmptyModule(rt, &ctx.modules, dep_name);

    var pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer pending.deinit(rt);
    const request_index = try pending.addRequest(dep_name);
    try pending.addImport(request_index, import_name, local_name, 3, false);
    try pending.addExport(export_name, local_name, 4);
    try pending.addIndirectExport(request_index, import_name, export_name, false);
    try pending.addStarExport(request_index);
    try pending.addImportAttribute(request_index, attr_key, attr_value);
    pending.synthetic_kind = .json;
    pending.has_top_level_await = true;

    const function_owner = try core.Object.create(rt, core.class.ids.object, null);
    pending.adoptFuncObjectValueNoFail(function_owner.value());
    const record = try publishFreshModule(&ctx.modules, module_name, &pending);
    record.setRequestModuleNoFail(request_index, dependency);

    const namespace_owner = try core.Object.create(rt, core.class.ids.module_ns, null);
    record.publishModuleNamespaceNoFail(namespace_owner.value());
    const retained_cell = try core.VarRef.createClosed(rt, core.JSValue.int32(41));
    record.publishRetainedExportCellNoFail(0, retained_cell.valueRef());
    const import_meta_owner = try core.Object.create(rt, core.class.ids.object, null);
    record.import_meta = import_meta_owner.value();
    const exception_owner = try core.Object.create(rt, core.class.ids.object, null);
    record.setEvalException(rt, exception_owner.value());
    record.setStatus(.linked);

    try std.testing.expectEqual(core.module.Status.linked, record.status);
    try std.testing.expectEqual(@as(usize, 1), record.requests.len);
    try std.testing.expectEqual(dep_name, record.requests[0].module_name);
    try std.testing.expectEqual(dependency, record.requests[0].module.?);
    try std.testing.expectEqual(@as(usize, 1), record.imports.len);
    try std.testing.expectEqual(request_index, record.imports[0].request_index);
    try std.testing.expectEqual(@as(u16, 3), record.imports[0].var_idx);
    try std.testing.expectEqual(@as(usize, 1), record.exports.len);
    try std.testing.expectEqual(@as(u16, 4), record.exports[0].var_idx);
    try std.testing.expectEqual(@as(usize, 1), record.indirect_exports.len);
    try std.testing.expectEqual(@as(usize, 1), record.star_exports.len);
    try std.testing.expectEqual(@as(usize, 1), record.import_attributes.len);
    try std.testing.expectEqual(request_index, record.import_attributes[0].request_index);
    try std.testing.expectEqual(core.module.SyntheticKind.json, record.synthetic_kind);
    try std.testing.expect(record.has_top_level_await);
    try std.testing.expect(rt.atoms.name(record.module_name) != null);
    try std.testing.expect(rt.atoms.name(record.imports[0].local_name) != null);
    try std.testing.expectEqual(&function_owner.header, record.funcObjectValue().refHeader().?);
    try std.testing.expectEqual(&namespace_owner.header, record.moduleNamespaceValue().refHeader().?);
    try std.testing.expectEqual(retained_cell, core.VarRef.fromValue(record.retainedExportCellValue(0).?).?);
    try std.testing.expectEqual(&import_meta_owner.header, record.import_meta.?.refHeader().?);
    try std.testing.expectEqual(&exception_owner.header, record.eval_exception.?.refHeader().?);
}

test "pending module metadata and publication OOM are atomic" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const module_name = try rt.internAtom("oom-main.mjs");
    defer rt.atoms.free(module_name);

    const dep_name = try rt.internAtom("oom-dep.mjs");
    defer rt.atoms.free(dep_name);
    const import_name = try rt.internAtom("oom-import");
    defer rt.atoms.free(import_name);
    const local_name = try rt.internAtom("oom-local");
    defer rt.atoms.free(local_name);

    var pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer pending.deinit(rt);
    const request_index = try pending.addRequest(dep_name);

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, pending.addImport(request_index, import_name, local_name, 0, false));
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(@as(usize, 1), pending.requests.len);
    try std.testing.expectEqual(@as(usize, 0), pending.imports.len);
    try std.testing.expectEqual(@as(usize, 1), rt.atoms.refCount(import_name).?);
    try std.testing.expectEqual(@as(usize, 1), rt.atoms.refCount(local_name).?);
    try std.testing.expectEqual(@as(usize, 0), ctx.modules.count);

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, ctx.modules.prepareFreshTarget(module_name, &pending));
    rt.setMemoryLimit(null);
    try std.testing.expectEqual(@as(usize, 1), pending.requests.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.modules.count);
    try std.testing.expect(ctx.modules.find(module_name) == null);

    const record = try publishFreshModule(&ctx.modules, module_name, &pending);
    try std.testing.expectEqual(@as(usize, 0), pending.requests.len);
    try std.testing.expectEqual(@as(usize, 1), record.requests.len);
}

test "module registry resolves local indirect star and ambiguous exports" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const main_name = try rt.internAtom("main.mjs");
    const dep_a_name = try rt.internAtom("dep-a.mjs");
    const dep_b_name = try rt.internAtom("dep-b.mjs");
    const dep_c_name = try rt.internAtom("dep-c.mjs");
    const unique_name = try rt.internAtom("unique.mjs");
    const value_name = try rt.internAtom("value");
    const other_name = try rt.internAtom("other");
    const local_a_name = try rt.internAtom("localA");
    const local_b_name = try rt.internAtom("localB");
    defer {
        rt.atoms.free(main_name);
        rt.atoms.free(dep_a_name);
        rt.atoms.free(dep_b_name);
        rt.atoms.free(dep_c_name);
        rt.atoms.free(unique_name);
        rt.atoms.free(value_name);
        rt.atoms.free(other_name);
        rt.atoms.free(local_a_name);
        rt.atoms.free(local_b_name);
    }

    var dep_a_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer dep_a_pending.deinit(rt);
    try dep_a_pending.addExport(value_name, local_a_name, 0);
    const dep_a = try publishFreshModule(&ctx.modules, dep_a_name, &dep_a_pending);

    var dep_b_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer dep_b_pending.deinit(rt);
    try dep_b_pending.addExport(value_name, local_b_name, 0);
    const dep_b = try publishFreshModule(&ctx.modules, dep_b_name, &dep_b_pending);

    var dep_c_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer dep_c_pending.deinit(rt);
    const dep_c_to_a = try dep_c_pending.addRequest(dep_a_name);
    try dep_c_pending.addIndirectExport(dep_c_to_a, other_name, value_name, false);
    const dep_c = try publishFreshModule(&ctx.modules, dep_c_name, &dep_c_pending);
    dep_c.setRequestModuleNoFail(dep_c_to_a, dep_a);

    var unique_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer unique_pending.deinit(rt);
    const unique_to_a = try unique_pending.addRequest(dep_a_name);
    try unique_pending.addStarExport(unique_to_a);
    const unique = try publishFreshModule(&ctx.modules, unique_name, &unique_pending);
    unique.setRequestModuleNoFail(unique_to_a, dep_a);

    var main_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer main_pending.deinit(rt);
    const main_to_c = try main_pending.addRequest(dep_c_name);
    const main_to_a = try main_pending.addRequest(dep_a_name);
    const main_to_b = try main_pending.addRequest(dep_b_name);
    try main_pending.addIndirectExport(main_to_c, other_name, other_name, false);
    try main_pending.addStarExport(main_to_a);
    try main_pending.addStarExport(main_to_b);
    const main = try publishFreshModule(&ctx.modules, main_name, &main_pending);
    main.setRequestModuleNoFail(main_to_c, dep_c);
    main.setRequestModuleNoFail(main_to_a, dep_a);
    main.setRequestModuleNoFail(main_to_b, dep_b);

    const indirect = try ctx.modules.resolveExport(main, other_name);
    try std.testing.expectEqual(core.module.ResolvedExport.resolved, std.meta.activeTag(indirect));
    try std.testing.expectEqual(dep_a, indirect.resolved.module);
    try std.testing.expectEqual(local_a_name, indirect.resolved.bindingName());

    const star = try ctx.modules.resolveExport(unique, value_name);
    try std.testing.expectEqual(core.module.ResolvedExport.resolved, std.meta.activeTag(star));
    try std.testing.expectEqual(dep_a, star.resolved.module);
    try std.testing.expectEqual(local_a_name, star.resolved.bindingName());

    const ambiguous = try ctx.modules.resolveExport(main, value_name);
    try std.testing.expectEqual(core.module.ResolvedExport.ambiguous, std.meta.activeTag(ambiguous));
}

test "existing published module generation is not overwritten by pending definition" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const module_name = try rt.internAtom("fresh.mjs");
    const old_export_name = try rt.internAtom("old");
    const replacement_export_name = try rt.internAtom("replacement");
    defer {
        rt.atoms.free(module_name);
        rt.atoms.free(old_export_name);
        rt.atoms.free(replacement_export_name);
    }

    var first_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer first_pending.deinit(rt);
    try first_pending.addExport(old_export_name, old_export_name, 0);
    const first = try publishFreshModule(&ctx.modules, module_name, &first_pending);
    first.setStatus(.linked);

    var replacement = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer replacement.deinit(rt);
    try replacement.addExport(replacement_export_name, replacement_export_name, 1);
    const prepared = try ctx.modules.prepareFreshTarget(module_name, &replacement);

    try std.testing.expect(!prepared.isFresh());
    try std.testing.expectEqual(first, prepared.record());
    try std.testing.expectEqual(@as(usize, 1), ctx.modules.count);
    try std.testing.expectEqual(core.module.Status.linked, first.status);
    try std.testing.expectEqual(@as(usize, 1), first.exports.len);
    try std.testing.expectEqual(old_export_name, first.exports[0].export_name);
    // Existing lookup must leave the complete candidate untouched for the
    // caller to deinit or reuse.
    try std.testing.expectEqual(@as(usize, 1), replacement.exports.len);
    try std.testing.expectEqual(replacement_export_name, replacement.exports[0].export_name);
}

test "indexed module resolution is pure across not-found ambiguous and cyclic graphs" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const dep_name = try rt.internAtom("resolve-dep.mjs");
    const missing_name = try rt.internAtom("resolve-missing.mjs");
    const unresolved_name = try rt.internAtom("resolve-unresolved-request.mjs");
    const cycle_a_name = try rt.internAtom("resolve-cycle-a.mjs");
    const cycle_b_name = try rt.internAtom("resolve-cycle-b.mjs");
    const ambiguous_name = try rt.internAtom("resolve-ambiguous.mjs");
    const amb_a_name = try rt.internAtom("amb-a.mjs");
    const amb_b_name = try rt.internAtom("amb-b.mjs");
    const value_name = try rt.internAtom("value");
    const local_a_name = try rt.internAtom("local-a");
    const local_b_name = try rt.internAtom("local-b");
    defer {
        rt.atoms.free(dep_name);
        rt.atoms.free(missing_name);
        rt.atoms.free(unresolved_name);
        rt.atoms.free(cycle_a_name);
        rt.atoms.free(cycle_b_name);
        rt.atoms.free(ambiguous_name);
        rt.atoms.free(amb_a_name);
        rt.atoms.free(amb_b_name);
        rt.atoms.free(value_name);
        rt.atoms.free(local_a_name);
        rt.atoms.free(local_b_name);
    }

    var dep_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer dep_pending.deinit(rt);
    try dep_pending.addExport(value_name, local_a_name, 0);
    const dep = try publishFreshModule(&ctx.modules, dep_name, &dep_pending);
    const missing = try publishEmptyModule(rt, &ctx.modules, missing_name);

    var unresolved_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer unresolved_pending.deinit(rt);
    const unresolved_request = try unresolved_pending.addRequest(dep_name);
    try unresolved_pending.addStarExport(unresolved_request);
    const unresolved = try publishFreshModule(&ctx.modules, unresolved_name, &unresolved_pending);

    var cycle_a_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer cycle_a_pending.deinit(rt);
    const cycle_a_to_b = try cycle_a_pending.addRequest(cycle_b_name);
    try cycle_a_pending.addStarExport(cycle_a_to_b);
    const cycle_a = try publishFreshModule(&ctx.modules, cycle_a_name, &cycle_a_pending);

    var cycle_b_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer cycle_b_pending.deinit(rt);
    const cycle_b_to_a = try cycle_b_pending.addRequest(cycle_a_name);
    try cycle_b_pending.addStarExport(cycle_b_to_a);
    const cycle_b = try publishFreshModule(&ctx.modules, cycle_b_name, &cycle_b_pending);
    cycle_a.setRequestModuleNoFail(cycle_a_to_b, cycle_b);
    cycle_b.setRequestModuleNoFail(cycle_b_to_a, cycle_a);

    var amb_a_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer amb_a_pending.deinit(rt);
    try amb_a_pending.addExport(value_name, local_a_name, 0);
    const amb_a = try publishFreshModule(&ctx.modules, amb_a_name, &amb_a_pending);

    var amb_b_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer amb_b_pending.deinit(rt);
    try amb_b_pending.addExport(value_name, local_b_name, 0);
    const amb_b = try publishFreshModule(&ctx.modules, amb_b_name, &amb_b_pending);

    var ambiguous_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer ambiguous_pending.deinit(rt);
    const ambiguous_to_a = try ambiguous_pending.addRequest(amb_a_name);
    const ambiguous_to_b = try ambiguous_pending.addRequest(amb_b_name);
    try ambiguous_pending.addStarExport(ambiguous_to_a);
    try ambiguous_pending.addStarExport(ambiguous_to_b);
    const ambiguous = try publishFreshModule(&ctx.modules, ambiguous_name, &ambiguous_pending);
    ambiguous.setRequestModuleNoFail(ambiguous_to_a, amb_a);
    ambiguous.setRequestModuleNoFail(ambiguous_to_b, amb_b);

    dep.setStatus(.linked);
    missing.setStatus(.evaluating);
    unresolved.setStatus(.evaluated);
    cycle_a.setStatus(.linking);
    cycle_b.setStatus(.errored);
    ambiguous.setStatus(.evaluating);

    const local_resolution = try ctx.modules.resolveExport(dep, value_name);
    try std.testing.expectEqual(.resolved, std.meta.activeTag(local_resolution));
    try std.testing.expectEqual(dep, local_resolution.resolved.module);
    try std.testing.expectEqual(local_a_name, local_resolution.resolved.bindingName());

    const not_found = try ctx.modules.resolveExport(missing, value_name);
    try std.testing.expectEqual(.not_found, std.meta.activeTag(not_found));
    try std.testing.expectError(error.ModuleNotFound, ctx.modules.resolveExport(unresolved, value_name));

    const cycle = try ctx.modules.resolveExport(cycle_a, value_name);
    try std.testing.expectEqual(.not_found, std.meta.activeTag(cycle));
    const ambiguous_resolution = try ctx.modules.resolveExport(ambiguous, value_name);
    try std.testing.expectEqual(.ambiguous, std.meta.activeTag(ambiguous_resolution));

    try std.testing.expectEqual(core.module.Status.linked, dep.status);
    try std.testing.expectEqual(core.module.Status.evaluating, missing.status);
    try std.testing.expectEqual(core.module.Status.evaluated, unresolved.status);
    try std.testing.expectEqual(core.module.Status.linking, cycle_a.status);
    try std.testing.expectEqual(core.module.Status.errored, cycle_b.status);
    try std.testing.expectEqual(core.module.Status.evaluating, ambiguous.status);
}

test "module resolution follows local exports of ordinary imports" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const source_name = try rt.internAtom("source");
    const direct_name = try rt.internAtom("direct");
    const imported_name = try rt.internAtom("imported");
    const root_name = try rt.internAtom("root");
    const foo_name = try rt.internAtom("foo");
    const source_local_name = try rt.internAtom("source-local");
    defer {
        rt.atoms.free(source_name);
        rt.atoms.free(direct_name);
        rt.atoms.free(imported_name);
        rt.atoms.free(root_name);
        rt.atoms.free(foo_name);
        rt.atoms.free(source_local_name);
    }

    var source_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer source_pending.deinit(rt);
    try source_pending.addExport(foo_name, source_local_name, 0);
    const source = try publishFreshModule(&ctx.modules, source_name, &source_pending);

    var direct_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer direct_pending.deinit(rt);
    const direct_to_source = try direct_pending.addRequest(source_name);
    try direct_pending.addIndirectExport(direct_to_source, foo_name, foo_name, false);
    const direct = try publishFreshModule(&ctx.modules, direct_name, &direct_pending);
    direct.setRequestModuleNoFail(direct_to_source, source);

    var imported_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer imported_pending.deinit(rt);
    const imported_to_source = try imported_pending.addRequest(source_name);
    try imported_pending.addImport(imported_to_source, foo_name, foo_name, 0, false);
    try imported_pending.addExport(foo_name, foo_name, 0);
    const imported = try publishFreshModule(&ctx.modules, imported_name, &imported_pending);
    imported.setRequestModuleNoFail(imported_to_source, source);

    var root_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer root_pending.deinit(rt);
    const root_to_direct = try root_pending.addRequest(direct_name);
    const root_to_imported = try root_pending.addRequest(imported_name);
    try root_pending.addStarExport(root_to_direct);
    try root_pending.addStarExport(root_to_imported);
    const root = try publishFreshModule(&ctx.modules, root_name, &root_pending);
    root.setRequestModuleNoFail(root_to_direct, direct);
    root.setRequestModuleNoFail(root_to_imported, imported);

    const direct_resolution = try ctx.modules.resolveExport(direct, foo_name);
    try std.testing.expectEqual(.resolved, std.meta.activeTag(direct_resolution));
    try std.testing.expectEqual(source, direct_resolution.resolved.module);
    try std.testing.expectEqual(source_local_name, direct_resolution.resolved.bindingName());

    const imported_resolution = try ctx.modules.resolveExport(imported, foo_name);
    try std.testing.expectEqual(.resolved, std.meta.activeTag(imported_resolution));
    try std.testing.expectEqual(source, imported_resolution.resolved.module);
    try std.testing.expectEqual(source_local_name, imported_resolution.resolved.bindingName());
    try std.testing.expect(direct_resolution.resolved.sameIdentity(imported_resolution.resolved));

    const root_resolution = try ctx.modules.resolveExport(root, foo_name);
    try std.testing.expectEqual(.resolved, std.meta.activeTag(root_resolution));
    try std.testing.expectEqual(source, root_resolution.resolved.module);
    try std.testing.expectEqual(source_local_name, root_resolution.resolved.bindingName());
}

test "module resolution normalizes namespace re-export bindings" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

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

    const target = try publishEmptyModule(rt, &ctx.modules, target_name);

    var star_a_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer star_a_pending.deinit(rt);
    const star_a_to_target = try star_a_pending.addRequest(target_name);
    try star_a_pending.addIndirectExport(star_a_to_target, foo_name, star_atom, true);
    try star_a_pending.addIndirectExport(star_a_to_target, default_name, star_atom, true);
    const star_a = try publishFreshModule(&ctx.modules, star_a_name, &star_a_pending);
    star_a.setRequestModuleNoFail(star_a_to_target, target);

    var star_b_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer star_b_pending.deinit(rt);
    const star_b_to_target = try star_b_pending.addRequest(target_name);
    try star_b_pending.addIndirectExport(star_b_to_target, foo_name, star_atom, true);
    const star_b = try publishFreshModule(&ctx.modules, star_b_name, &star_b_pending);
    star_b.setRequestModuleNoFail(star_b_to_target, target);

    var import_a_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer import_a_pending.deinit(rt);
    const import_a_to_target = try import_a_pending.addRequest(target_name);
    try import_a_pending.addImport(import_a_to_target, star_atom, foo_name, 0, true);
    try import_a_pending.addExport(foo_name, foo_name, 0);
    const import_a = try publishFreshModule(&ctx.modules, import_a_name, &import_a_pending);
    import_a.setRequestModuleNoFail(import_a_to_target, target);

    var import_b_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer import_b_pending.deinit(rt);
    const import_b_to_target = try import_b_pending.addRequest(target_name);
    try import_b_pending.addImport(import_b_to_target, star_atom, foo_name, 0, true);
    try import_b_pending.addExport(foo_name, foo_name, 0);
    const import_b = try publishFreshModule(&ctx.modules, import_b_name, &import_b_pending);
    import_b.setRequestModuleNoFail(import_b_to_target, target);

    var star_root_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer star_root_pending.deinit(rt);
    const star_root_to_a = try star_root_pending.addRequest(star_a_name);
    const star_root_to_b = try star_root_pending.addRequest(star_b_name);
    try star_root_pending.addStarExport(star_root_to_a);
    try star_root_pending.addStarExport(star_root_to_b);
    const star_root = try publishFreshModule(&ctx.modules, star_root_name, &star_root_pending);
    star_root.setRequestModuleNoFail(star_root_to_a, star_a);
    star_root.setRequestModuleNoFail(star_root_to_b, star_b);

    var import_root_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer import_root_pending.deinit(rt);
    const import_root_to_a = try import_root_pending.addRequest(import_a_name);
    const import_root_to_b = try import_root_pending.addRequest(import_b_name);
    try import_root_pending.addStarExport(import_root_to_a);
    try import_root_pending.addStarExport(import_root_to_b);
    const import_root = try publishFreshModule(&ctx.modules, import_root_name, &import_root_pending);
    import_root.setRequestModuleNoFail(import_root_to_a, import_a);
    import_root.setRequestModuleNoFail(import_root_to_b, import_b);

    var mixed_root_pending = core.module.PendingDefinition.init(&rt.memory, &rt.atoms);
    defer mixed_root_pending.deinit(rt);
    const mixed_root_to_star = try mixed_root_pending.addRequest(star_a_name);
    const mixed_root_to_import = try mixed_root_pending.addRequest(import_a_name);
    try mixed_root_pending.addStarExport(mixed_root_to_star);
    try mixed_root_pending.addStarExport(mixed_root_to_import);
    const mixed_root = try publishFreshModule(&ctx.modules, mixed_root_name, &mixed_root_pending);
    mixed_root.setRequestModuleNoFail(mixed_root_to_star, star_a);
    mixed_root.setRequestModuleNoFail(mixed_root_to_import, import_a);

    const star_resolution = try ctx.modules.resolveExport(star_root, foo_name);
    try std.testing.expectEqual(.resolved, std.meta.activeTag(star_resolution));
    try std.testing.expectEqual(star_a, star_resolution.resolved.module);
    try std.testing.expectEqual(.namespace_export, std.meta.activeTag(star_resolution.resolved.entry));

    const explicit_default_resolution = try ctx.modules.resolveExport(star_a, default_name);
    try std.testing.expectEqual(.resolved, std.meta.activeTag(explicit_default_resolution));
    try std.testing.expectEqual(star_a, explicit_default_resolution.resolved.module);
    try std.testing.expectEqual(.namespace_export, std.meta.activeTag(explicit_default_resolution.resolved.entry));

    const import_resolution = try ctx.modules.resolveExport(import_root, foo_name);
    try std.testing.expectEqual(.resolved, std.meta.activeTag(import_resolution));
    try std.testing.expectEqual(import_a, import_resolution.resolved.module);
    try std.testing.expectEqual(.local_export, std.meta.activeTag(import_resolution.resolved.entry));

    const mixed_resolution = try ctx.modules.resolveExport(mixed_root, foo_name);
    try std.testing.expectEqual(.resolved, std.meta.activeTag(mixed_resolution));
    try std.testing.expectEqual(star_a, mixed_resolution.resolved.module);
    try std.testing.expectEqual(.namespace_export, std.meta.activeTag(mixed_resolution.resolved.entry));

    // Locators remain indexed into their originating records, while identity
    // comparison normalizes both explicit namespace re-exports and local
    // exports of namespace imports to the same target namespace.
    try std.testing.expect(star_resolution.resolved.sameIdentity(explicit_default_resolution.resolved));
    try std.testing.expect(star_resolution.resolved.sameIdentity(import_resolution.resolved));
    try std.testing.expect(star_resolution.resolved.sameIdentity(mixed_resolution.resolved));
}

fn interruptOnce(_: *core.JSRuntime, userdata: ?*anyopaque) bool {
    const count: *usize = @ptrCast(@alignCast(userdata.?));
    count.* += 1;
    return true;
}

test "runtime stack and interrupt state are stored" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    rt.setStackSize(4096);
    try std.testing.expectEqual(@as(usize, 4096), rt.stackSize());
    try std.testing.expectEqual(@as(u62, 4096), rt.vm_stack_arena_policy.limit);
    try std.testing.expect(rt.vm_stack_arena_policy.arena_window);
    try std.testing.expect(!rt.vm_stack_arena_policy.resident_window);
    rt.setStackSize(std.math.maxInt(usize));
    try std.testing.expectEqual(std.math.maxInt(usize), rt.stackSize());
    try std.testing.expectEqual(std.math.maxInt(u62), rt.vm_stack_arena_policy.limit);
    rt.setStackSize(4096);
    try std.testing.expect(!rt.hasInterruptHandler());
    var interrupt_count: usize = 0;
    rt.setInterruptHandler(interruptOnce, &interrupt_count);
    try std.testing.expect(rt.hasInterruptHandler());
    try std.testing.expect(rt.runInterruptHandler());
    try std.testing.expectEqual(@as(usize, 1), interrupt_count);
}

test "realm interrupt cadence advances without a handler and is realm-local" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const realm_a = try core.JSContext.create(rt);
    defer realm_a.destroy();
    const realm_b = try core.JSContext.create(rt);
    defer realm_b.destroy();

    const interval: usize = @intCast(core.JSContext.interrupt_counter_reset);

    // A raw QuickJS context starts at zero. Its first semantic poll therefore
    // resets the counter even when the Runtime has no handler installed.
    try std.testing.expect(!realm_a.pollInterrupt());
    for (0..(interval - 1)) |_| {
        try std.testing.expect(!realm_a.pollInterrupt());
    }

    var interrupt_count: usize = 0;
    rt.setInterruptHandler(interruptOnce, &interrupt_count);
    defer rt.setInterruptHandler(null, null);

    // Installing a handler does not reset the already-advanced Realm budget.
    try std.testing.expect(realm_a.pollInterrupt());
    try std.testing.expectEqual(@as(usize, 1), interrupt_count);

    // Every Realm owns an independent counter with the same initial-zero rule.
    try std.testing.expect(realm_b.pollInterrupt());
    try std.testing.expectEqual(@as(usize, 2), interrupt_count);

    // Callback-to-callback distance is exactly the QuickJS 10,000-poll reset.
    for (0..(interval - 1)) |_| {
        try std.testing.expect(!realm_a.pollInterrupt());
    }
    try std.testing.expect(realm_a.pollInterrupt());
    try std.testing.expectEqual(@as(usize, 3), interrupt_count);
}

test "ordinary objects define own data properties and descriptors" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const obj = try core.Object.create(rt, core.class.ids.object, null);
    defer obj.value().free(rt);

    const key = try rt.internAtom("answer");
    defer rt.atoms.free(key);

    try obj.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(42), true, true, true));
    const desc = (try obj.getOwnProperty(rt, key)).?;
    defer desc.destroy(rt);
    try std.testing.expectEqual(core.descriptor.Kind.data, desc.kind);
    try std.testing.expectEqual(@as(?i32, 42), desc.value.asInt32());
    try std.testing.expectEqual(true, desc.writable.?);
    try std.testing.expect(obj.hasOwnProperty(key));

    try obj.setProperty(rt, key, core.JSValue.int32(7));
    const updated = try obj.getProperty(key);
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

    // qjs `JSProperty` stores getter/setter as `JSObject*` (object or NULL);
    // accessor get/set are always callable objects or undefined, so use object
    // values here (the prior string placeholders relied on the old loose
    // JSValue accessor cell that L2 replaced with object-header pointers).
    const getter = try core.Object.create(rt, core.class.ids.object, null);
    const setter = try core.Object.create(rt, core.class.ids.object, null);
    try obj.defineOwnProperty(rt, key, core.Descriptor.accessor(getter.value(), setter.value(), true, true));
    getter.value().free(rt);
    setter.value().free(rt);

    const desc = (try obj.getOwnProperty(rt, key)).?;
    defer desc.destroy(rt);
    try std.testing.expectEqual(core.descriptor.Kind.accessor, desc.kind);
    try std.testing.expect(desc.getter.isObject());
    try std.testing.expect(desc.setter.isObject());
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
    try std.testing.expectEqual(@as(?i32, 11), (try child.getProperty(key)).asInt32());
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
    const desc = (try obj.getOwnProperty(rt, key)).?;
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
    try std.testing.expectEqual(@as(u32, 6), array_obj.arrayLength());
    try array_obj.defineOwnProperty(rt, index_1, core.Descriptor.data(core.JSValue.int32(1), true, true, true));
    try std.testing.expectEqual(@as(u32, 6), array_obj.arrayLength());

    try array_obj.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(2), false, false, false));
    try std.testing.expectEqual(@as(u32, 2), array_obj.arrayLength());
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
    try std.testing.expectEqual(@as(?i32, 2), (try array_obj.getProperty(index_0)).asInt32());

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

    try std.testing.expect(try array_obj.appendDenseArrayIndex(rt, 0, index_0, core.JSValue.int32(0)));
    try std.testing.expectEqual(core.object.ArrayStorageMode.dense, array_obj.arrayElementStorageMode());
    try array_obj.defineOwnProperty(rt, index_100, core.Descriptor.data(core.JSValue.int32(100), true, true, true));
    try std.testing.expectEqual(core.object.ArrayStorageMode.sparse, array_obj.arrayElementStorageMode());
    try array_obj.defineOwnProperty(rt, core.atom.ids.length, core.Descriptor.data(core.JSValue.int32(1), true, false, false));
    try std.testing.expectEqual(core.object.ArrayStorageMode.sparse, array_obj.arrayElementStorageMode());
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

    const exotic_id = try rt.newClassId(core.class.invalid_class_id);
    try rt.classes.register(exotic_id, .{ .class_name = "ExoticDispatchHooksForTest" });
    const exotic = core.object.ExoticMethods{
        .get_own_property = exoticGet,
        .define_own_property = exoticDefine,
        .delete_property = exoticDelete,
        .own_keys = exoticOwnKeys,
    };
    core.Object.installClassExoticMethods(rt, exotic_id, &exotic);

    const obj = try core.Object.create(rt, exotic_id, null);
    defer obj.value().free(rt);

    exotic_define_calls = 0;
    exotic_delete_calls = 0;
    const key = try rt.internAtom("hooked");
    defer rt.atoms.free(key);

    const desc = (try obj.getOwnProperty(rt, key)).?;
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

test "stored symbol value preserves and releases across GC without external value roots" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-external-rooted-symbol");
    const rooted_value = try rt.symbolValue(symbol_atom);

    try std.testing.expect(!try rt.registerExternalValueSymbolRoot(rooted_value));
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    rt.unregisterExternalValueSymbolRoot(rooted_value);
    rooted_value.free(rt);
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "finalization registry pending jobs preserve callback and held symbols" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const cleanup_sym = try rt.atoms.newValueSymbol("finalization-cleanup-callback");
    const cleanup_val = try rt.symbolValue(cleanup_sym);

    const held_sym = try rt.atoms.newValueSymbol("finalization-held-value");
    const held_val = try rt.symbolValue(held_sym);

    const target_obj = try core.Object.create(rt, core.class.ids.object, null);
    var target_val = target_obj.value();
    defer target_val.free(rt);

    const target_sym = try rt.atoms.newValueSymbol("finalization-target-symbol");
    try target_obj.defineOwnProperty(rt, target_sym, core.Descriptor.data(core.JSValue.boolean(true), true, true, true));
    rt.atoms.free(target_sym);

    const registry = try core.Object.createFinalizationRegistry(rt, ctx, null);
    registry.finalizationRegistryCleanupCallbackSlot().* = cleanup_val.dup();
    var registry_val = registry.value();
    defer registry_val.free(rt);

    try registry.appendFinalizationRegistryCell(rt, target_val, held_val, core.JSValue.undefinedValue());
    cleanup_val.free(rt);
    held_val.free(rt);

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(cleanup_sym) != null);
    try std.testing.expect(rt.atoms.name(target_sym) != null);
    try std.testing.expect(rt.atoms.name(held_sym) != null);

    target_val.free(rt);
    target_val = core.JSValue.undefinedValue();

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(target_sym) == null);
    try std.testing.expectEqual(@as(usize, 1), rt.pendingFinalizationJobCountForTest());
    try std.testing.expect(rt.atoms.name(cleanup_sym) != null);
    try std.testing.expect(rt.atoms.name(held_sym) != null);

    registry_val.free(rt);
    registry_val = core.JSValue.undefinedValue();

    rt.clearPendingFinalizationJobs();

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(cleanup_sym) == null);
    try std.testing.expect(rt.atoms.name(held_sym) == null);
}
