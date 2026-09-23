//! Integration tests for runtime lifecycle, GC, and core heap contracts.
const mem_ops = @import("zjs").core.memory;
const std = @import("std");
const zjs = @import("zjs");
const engine = zjs;
const core = zjs.core;
const helpers = @import("harness.zig");

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
            .value => |value| .{ .value = value },
            .var_ref => |cell| .{ .var_ref = cell },
            .fail_once => |value| blk: {
                if (!self.failed_once) {
                    self.failed_once = true;
                    return error.OutOfMemory;
                }
                break :blk .{ .value = value };
            },
            .reenter => |entry| blk: {
                try entry.holder.setProperty(entry.rt, entry.atom_id, entry.replacement);
                break :blk .{ .value = entry.materialized };
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
    var pending = core.module.PendingDefinition.init(rt, &rt.atoms);
    defer pending.deinit();
    return publishFreshModule(registry, module_name, &pending);
}

fn liveRealmCount(rt: *core.JSRuntime) usize {
    var count: usize = 0;
    var current = rt.firstContext();
    while (current) |ctx| : (current = ctx.runtime_next) count += 1;
    return count;
}

fn testBacktraceLocationResolver(_: ?*const anyopaque, pc: usize) core.BacktraceLocation {
    return .{ .line_num = @intCast(pc), .col_num = @intCast(pc + 10) };
}

const appendWeakCollectionEntry = helpers.appendWeakCollectionEntry;

fn appendFinalizationRegistryCell(
    rt: *core.JSRuntime,
    registry: *core.Object,
    target: core.JSValue,
    held_value: core.JSValue,
    unregister_token: core.JSValue,
) !void {
    try registry.appendFinalizationRegistryCell(rt, target, held_value, unregister_token);
}

/// What the first registerBorrowedReferenceHolder allocates, measured on a
/// scratch runtime so the OOM-injection tests below follow the holder list's
/// growth policy instead of restating it.
fn borrowedHolderInitialAllocationBytes() usize {
    const probe = core.JSRuntime.create(.{ .allocator = std.testing.allocator }) catch unreachable;
    defer probe.destroy();
    const holder = core.Object.create(probe, core.class.ids.object, null) catch unreachable;
    const before = probe.memory.diagnostics.allocations.allocated_bytes;
    probe.registerBorrowedReferenceHolder(holder) catch unreachable;
    const bytes = probe.memory.diagnostics.allocations.allocated_bytes - before;
    probe.unregisterBorrowedReferenceHolder(holder);
    return bytes;
}

/// TGC S2-i: force a full collection before every allocation, the shape
/// `-Dzjs_force_gc=true` gives production. Used to prove the tail-buffer
/// append chain keeps every live view and its shared buffer.
const TailBufferForceGcProbe = struct {
    rt: *core.JSRuntime,
    fired: usize = 0,

    fn trigger(ctx: ?*anyopaque, size: usize) void {
        _ = size;
        const self: *TailBufferForceGcProbe = @ptrCast(@alignCast(ctx.?));
        self.fired += 1;
        _ = self.rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {}; // engine-frames-active trigger
    }
};

fn tailBufferText(rt: *core.JSRuntime, allocator: std.mem.Allocator, value: core.JSValue) ![]u8 {
    _ = rt;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    const len = core.string.stringValueLen(value);
    while (index < len) : (index += 1) {
        const unit = core.string.stringValueCodeUnitAt(value, index).?;
        try out.append(allocator, @intCast(unit & 0xff));
    }
    return out.toOwnedSlice(allocator);
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
        self.rt.registerClass(.{ .class_name = "GrowthDuringConstruction" }) catch {
            self.register_failed = true;
            return;
        };
        self.target_record_after_growth = @intFromPtr(self.rt.classes.recordPtr(self.target_id).?);
    }
};

fn accountedPlainObjectBytes() usize {
    const prefix = core.gc.metadata_prefix_size;
    return core.gc_block_heap.accountedBodyBytesForRequest(
        prefix + core.Object.objectBodyBytes(core.class.ids.object, false),
        prefix,
    ).?;
}

fn emptyRootShapeAllocationBytes() usize {
    return @sizeOf(core.shape.Shape) +
        @sizeOf(u32) * core.shape.initial_hash_size +
        @sizeOf(core.shape.Property) * core.shape.initial_prop_size;
}

const ObjectConstructionOrderProbe = struct {
    rt: *core.JSRuntime,
    prototype: *core.Object,
    live_shape_count_before: usize,
    shape_hash_count_before: usize,
    heap_live_bytes_before: usize,
    object_boundary_calls: usize = 0,
    shape_owned_at_object_boundary: bool = false,

    fn trigger(raw: ?*anyopaque, size: usize) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        // The trigger receives the bytes about to be charged: for a block
        // Object that is its class-rounded physical body capacity.
        if (size != accountedPlainObjectBytes()) return;
        self.object_boundary_calls += 1;
        // The Shape is fully initialized, hash-visible, and published before
        // the reentrant object-allocation boundary. The boundary roots it
        // until the Object takes ownership. Under the tracer the prototype
        // ownership is the Shape's edge and leaves no count for a probe to
        // read, so the retain is only observable in the build that counts.
        const proto_owned_by_shape = true;
        const shape_reserved = self.rt.shapes.shape_hash_count == self.shape_hash_count_before + 1 and
            proto_owned_by_shape;
        const shape_published = self.rt.gc.liveCountKind(.shape) == self.live_shape_count_before + 1 and
            self.rt.gcDetailedStats().heap_live_bytes == self.heap_live_bytes_before + emptyRootShapeAllocationBytes();
        self.shape_owned_at_object_boundary = shape_reserved and shape_published;
    }
};

const InlineClassFinalizerReentry = struct {
    var target_id: core.ClassId = core.class.invalid_class_id;
    var growth_id: core.ClassId = core.class.invalid_class_id;
    var property_atom: core.Atom = core.atom.null_atom;
    var calls: usize = 0;
    var register_failed: bool = false;
    var definition_visible_during_callback: bool = false;
    var property_storage_was_stripped: bool = false;
    var prototype_was_stripped: bool = false;
    var own_property_was_stripped: bool = false;
    var property_read_was_undefined: bool = false;
    var property_read_failed: bool = false;
    var owner_thread_observed: bool = false;

    fn reset() void {
        target_id = core.class.invalid_class_id;
        growth_id = core.class.invalid_class_id;
        property_atom = core.atom.null_atom;
        calls = 0;
        register_failed = false;
        definition_visible_during_callback = false;
        property_storage_was_stripped = false;
        prototype_was_stripped = false;
        own_property_was_stripped = false;
        property_read_was_undefined = false;
        property_read_failed = false;
        owner_thread_observed = false;
    }

    fn finalize(runtime: *anyopaque, object_ptr: *anyopaque, payload: *core.class.Payload) void {
        const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
        const object: *core.Object = @ptrCast(@alignCast(object_ptr));
        calls += 1;
        owner_thread_observed = rt.isOwnerThread() and rt.classes.isOwnerThread();
        property_storage_was_stripped = !object.hasPropertyStorage();
        prototype_was_stripped = object.getPrototype() == null;
        own_property_was_stripped = !object.hasOwnProperty(property_atom);
        const property_value = object.getProperty(property_atom) catch blk: {
            property_read_failed = true;
            break :blk core.JSValue.undefinedValue();
        };
        property_read_was_undefined = property_value.is(.undefined_value);
        definition_visible_during_callback = rt.classes.isRegistered(target_id);
        rt.registerClass(.{ .class_name = "GrowthDuringInlineFinalizer" }) catch {
            register_failed = true;
        };
        payload.* = null;
    }
};

const InlineObjectLifecycleProbe = struct {
    var expected_object: ?*core.Object = null;
    var expected_heap_live_bytes: usize = 0;
    var expected_allocated_bytes: usize = 0;
    var calls: usize = 0;
    var identity_matches: bool = false;
    var owns_object: bool = false;
    var heap_live_bytes: usize = 0;
    var allocated_bytes: usize = 0;

    fn reset() void {
        expected_object = null;
        expected_heap_live_bytes = 0;
        expected_allocated_bytes = 0;
        calls = 0;
        identity_matches = false;
        owns_object = false;
        heap_live_bytes = 0;
        allocated_bytes = 0;
    }

    fn finalize(runtime: *anyopaque, object_ptr: *anyopaque, payload: *core.class.Payload) void {
        const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
        const object: *core.Object = @ptrCast(@alignCast(object_ptr));
        calls += 1;
        identity_matches = object == expected_object;
        owns_object = identity_matches and rt.ownsObject(object);
        heap_live_bytes = rt.gcDetailedStats().heap_live_bytes;
        allocated_bytes = rt.diagnostics.allocations.allocated_bytes;
        payload.* = null;
    }
};

const SideAuthorityDestroyProbe = struct {
    const object_count = 7;

    var expected_objects: [object_count]?*core.Object = @splat(null);
    var calls: [object_count]usize = @splat(0);
    var unknown_calls: usize = 0;

    fn reset() void {
        expected_objects = @splat(null);
        calls = @splat(0);
        unknown_calls = 0;
    }

    fn finalize(_: *anyopaque, object_ptr: *anyopaque, payload: *core.class.Payload) void {
        const object: *core.Object = @ptrCast(@alignCast(object_ptr));
        for (expected_objects, 0..) |expected, index| {
            if (expected == object) {
                calls[index] += 1;
                payload.* = null;
                return;
            }
        }
        unknown_calls += 1;
        payload.* = null;
    }
};

fn registerStandaloneInlineObjectTestClass(
    rt: *core.JSRuntime,
    class_name: []const u8,
    finalizer: ?core.class.PayloadFinalizer,
) !core.ClassId {
    const binding = try rt.registerClass(.{
        .class_name = class_name,
        .inline_payload_size = 32,
        .inline_payload_align = 8,
        .payload_finalizer = finalizer,
    });
    return binding.id;
}

/// Path proof shared by the non-block Object fixtures below. A dynamic inline
/// payload forces `Object.createInternal` through its raw aligned allocation,
/// and the two counters prove the resulting header is both published and
/// enumerated exactly once by the collector rather than merely having the
/// expected allocation flag by accident.
fn expectPublishedStandaloneInlineObject(rt: *core.JSRuntime, object: *core.Object) !void {
    const header = object.gcHeader();
    try std.testing.expectEqual(core.gc.GcKind.object, header.metaConst().flags.kind);
    try std.testing.expect(header.metaConst().alloc_info.standalone);
    try std.testing.expect(!core.gc.Registry.isBlockCellHeader(header));
    try std.testing.expect(header.metaConst().alloc_info.heap_accounted);
    try std.testing.expect(rt.gc.address_registry.by_header.contains(@intFromPtr(header)));
    try std.testing.expect(rt.gc.nonblock_objects.?.items.items.len >= 1);

    var list_matches: usize = 0;
    var list_cursor = rt.gc.lists.objects.sentinel.next_non_object;
    while (list_cursor) |candidate| {
        if (candidate == &rt.gc.lists.objects.sentinel) break;
        if (candidate == header) list_matches += 1;
        list_cursor = candidate.nextNonObject();
    }
    try std.testing.expectEqual(@as(usize, 0), list_matches);

    var matching_headers: usize = 0;
    var published_nonblock_objects: usize = 0;
    var iterator = rt.gc.objectIterator(.all);
    while (iterator.next()) |candidate| {
        if (candidate.metaConst().flags.kind == .object and
            !core.gc.Registry.isBlockCellHeader(candidate))
        {
            published_nonblock_objects += 1;
        }
        if (candidate == header) matching_headers += 1;
    }
    try std.testing.expect(published_nonblock_objects >= 1);
    try std.testing.expectEqual(@as(usize, 1), matching_headers);
}

fn countYoungHeader(rt: *core.JSRuntime, expected: *core.gc.Header) usize {
    var matches: usize = 0;
    var iterator = rt.gc.objectIterator(.young);
    while (iterator.next()) |candidate| {
        if (candidate == expected) matches += 1;
    }
    return matches;
}

const ExternalObjectLifecyclePayload = struct {
    event: u8,
};

const ExternalObjectLifecycleProbe = struct {
    const max_events = 2;

    var expected_objects: [max_events]?*core.Object = @splat(null);
    var calls: usize = 0;
    var events: [max_events]u8 = @splat(0xff);
    var identity_matches: [max_events]bool = @splat(false);
    var owns_objects: [max_events]bool = @splat(false);
    var allocated_bytes: [max_events]usize = @splat(0);

    fn reset() void {
        expected_objects = @splat(null);
        calls = 0;
        events = @splat(0xff);
        identity_matches = @splat(false);
        owns_objects = @splat(false);
        allocated_bytes = @splat(0);
    }

    fn finalize(runtime: *anyopaque, object_ptr: *anyopaque, payload: *core.class.Payload) void {
        const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
        const typed: *ExternalObjectLifecyclePayload = @ptrCast(@alignCast(payload.*.?));
        const event: usize = typed.event;
        const index = calls;
        calls += 1;
        if (index < max_events) {
            events[index] = typed.event;
            identity_matches[index] = if (event < max_events and expected_objects[event] != null)
                @intFromPtr(object_ptr) == @intFromPtr(expected_objects[event].?)
            else
                false;
            owns_objects[index] = identity_matches[index] and
                rt.ownsObject(@ptrCast(@alignCast(object_ptr)));
            allocated_bytes[index] = rt.diagnostics.allocations.allocated_bytes;
        }
        mem_ops.destroy(rt, ExternalObjectLifecyclePayload, typed);
        payload.* = null;
    }
};

const ExternalClassFinalizerReentry = struct {
    var target_id: core.ClassId = core.class.invalid_class_id;
    var expected_object: ?*core.Object = null;
    var calls: usize = 0;
    var identity_matches: bool = false;
    var owns_object: bool = false;
    var definition_visible_during_callback: bool = false;

    fn reset() void {
        target_id = core.class.invalid_class_id;
        expected_object = null;
        calls = 0;
        identity_matches = false;
        owns_object = false;
        definition_visible_during_callback = false;
    }

    fn finalize(runtime: *anyopaque, object_ptr: *anyopaque, payload: *core.class.Payload) void {
        const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
        const object: *core.Object = @ptrCast(@alignCast(object_ptr));
        calls += 1;
        identity_matches = object == expected_object;
        owns_object = identity_matches and rt.ownsObject(object);
        definition_visible_during_callback =
            rt.classes.isRegistered(target_id);

        const ptr = payload.* orelse return;
        const typed: *TestExternalPayload = @ptrCast(@alignCast(ptr));
        mem_ops.destroy(rt, TestExternalPayload, typed);
        payload.* = null;
    }
};

fn createExternalObjectLifecycleProbe(
    rt: *core.JSRuntime,
    class_id: core.ClassId,
    event: u8,
) !*core.Object {
    const object = try core.Object.create(rt, class_id, null);
    const payload = try mem_ops.create(rt, ExternalObjectLifecyclePayload);
    payload.* = .{ .event = event };
    object.installExternalClassPayload(rt, @ptrCast(payload));
    return object;
}

fn finalizeTestExternalPayload(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    const ptr = payload.* orelse return;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const typed: *TestExternalPayload = @ptrCast(@alignCast(ptr));
    mem_ops.destroy(rt, TestExternalPayload, typed);
    payload.* = null;
}

fn finalizeTestExternalObjectPayload(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    const ptr = payload.* orelse return;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const typed: *TestExternalObjectPayload = @ptrCast(@alignCast(ptr));
    mem_ops.destroy(rt, TestExternalObjectPayload, typed);
    payload.* = null;
}

fn reentrantCollectionClearFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    payload.* = null;
    if (reentrant_collection_clear_calls != 0) return;
    reentrant_collection_clear_calls += 1;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const map = reentrant_collection_clear_target orelse return;
    _ = engine.exec.collection_ops.methodCall(rt, map.value(), 5, &.{}) catch return;
}

fn reentrantArrayDeleteFinalizer(runtime: *anyopaque, _: *anyopaque, payload: *core.class.Payload) void {
    payload_finalizer_calls += 1;
    payload.* = null;
    if (reentrant_array_delete_calls != 0) return;
    reentrant_array_delete_calls += 1;
    const rt: *core.JSRuntime = @ptrCast(@alignCast(runtime));
    const array = reentrant_array_delete_target orelse return;
    _ = array.deleteProperty(rt, core.Atom.taggedInt(0));
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
        core.Descriptor.data(core.JSValue.int32(99), .all),
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
    _ = engine.exec.array_builtin_ops.methodCall(rt, iterator.value(), 20, &.{}) catch return;
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

/// Single-winner resolution for tests: the last published GC header the
/// registry's candidate walk reports for `addr` (null when none).
fn registryResolveOne(rt: *core.JSRuntime, addr: usize) ?*core.gc.Header {
    const Probe = struct {
        last: ?*core.gc.Header = null,
        fn visit(raw: *anyopaque, header: *core.gc.Header) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.last = header;
        }
    };
    var probe: Probe = .{};
    _ = rt.gc.address_registry.forEachTraceCandidateAt(addr, rt.gc.address_registry.rebuildScanFilter(), &probe, Probe.visit);
    return probe.last;
}

const DefineFieldForceGcProbe = struct {
    rt: *core.JSRuntime,
    fired: usize = 0,

    fn trigger(ctx: ?*anyopaque, size: usize) void {
        _ = size;
        const self: *DefineFieldForceGcProbe = @ptrCast(@alignCast(ctx.?));
        self.fired += 1;
        // Full cycle removal before every allocation — the force-GC shape of
        // `-Dzjs_force_gc=true` — so the collection lands inside the append
        // over-hang and the replace-branch shape mutation.
        _ = self.rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {}; // engine-frames-active trigger
    }
};

const deep_gc_chain_length: usize = 20_000;

fn createDeepOwnedPropertyChain(rt: *core.JSRuntime, key: core.Atom, length: usize) !*core.Object {
    std.debug.assert(length != 0);
    const head = try core.Object.create(rt, core.class.ids.object, null);

    var tail = head;
    for (1..length) |_| {
        const child = try core.Object.create(rt, core.class.ids.object, null);
        tail.defineOwnProperty(
            rt,
            key,
            core.Descriptor.data(child.value(), .all),
        ) catch |err| {
            return err;
        };
        // The property is now the child's sole owner. Keeping only a raw tail
        // pointer makes releasing `head` exercise the real RC cascade.
        tail = child;
    }
    return head;
}

const live_empty_object_gc_count: usize = 2;
const single_object_self_cycle_reclaimed_count: usize = 2;
/// Same graph, but the single object owns one external storage cell -- a named
/// property's `.property_storage` buffer or a dense array's `.array_storage`
/// buffer -- which TGC S4-b made a collected carrier.
const single_object_self_cycle_with_storage_count: usize = 3;
/// TGC S4-b: plus the two objects' external `.property_storage` cells.
const closed_property_cycle_reclaimed_count: usize = 7;
/// Same two-object cycle, but a third live object still holds the empty root
/// shape: two JS objects plus their two transition shapes.
const closed_property_cycle_root_kept_reclaimed_count: usize = 6;
/// Fast array + plain object: the two objects, the object's transition shape
/// and the array's own root shape; the plain-object root was unshared and
/// freed the moment the object left it.
/// TGC S4-b adds the plain object's `.property_storage` cell.
const iterator_next_cache_cycle_reclaimed_count: usize = 5;

/// Accounted bytes of an object's external `.property_storage` cell, zero when
/// the storage is the empty sentinel or the inline slots2 tail (TGC S4-b).
fn externalPropertyStorageBytes(rt: anytype, obj: *const core.Object) usize {
    const storage = obj.prop_values;
    if (!obj.propertyStoragePointerIsExternal(storage)) return 0;
    const header: *const core.gc.Header = @ptrCast(@alignCast(storage));
    return core.gc.Registry.heapByteSizeFromHeader(rt, header);
}

fn expectNoLiveGc(rt: *core.JSRuntime) !void {
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.shape));
}

fn expectCycleReclaimedIncludingShapes(rt: *core.JSRuntime, expected: usize, actual: usize) !void {
    // Shapes are GC objects now, so cycle reclaim counts include collected
    // object shapes in addition to the JS objects themselves. TGC S4-b added
    // the property/element storage cells and TGC S4-c the a-class payload
    // cells (`.ordinary`, `.proxy`, `.bound_function`, ...), so an out-of-line
    // payload contributes one more. Built-in Promise state is now inline.
    try std.testing.expectEqual(@as(usize, expected), actual);
    try expectNoLiveGc(rt);
}

fn expectAllLiveGcReclaimed(rt: *core.JSRuntime) !void {
    const live_before = rt.gc.liveCount();
    try std.testing.expectEqual(live_before, rt.collectForTest());
    try expectNoLiveGc(rt);
}

/// Zero a Zig pointer local that no longer holds a GC object, so a
/// conservative scan cannot treat leftover stack bits as a root (§7.2).
fn dropGcPtr(ptr: anytype) void {
    @memset(std.mem.asBytes(ptr), 0);
}

fn expectClosedPropertyCycleReclaimed(rt: *core.JSRuntime, freed: usize) !void {
    // Shape is a GC object. This graph collects the two JS objects plus the two
    // one-property transition shapes, plus the empty root shape both objects
    // started from: it was shared, so leaving it does not free it (the shared
    // bit is sticky) and the sweep reclaims it with the rest.
    try std.testing.expectEqual(@as(usize, closed_property_cycle_reclaimed_count), freed);
    try expectNoLiveGc(rt);
}

/// Records the child headers the production edge authority reports for one
/// header (the same per-kind dispatch as `gc_trace_stw.traceHeaderEdges`), so
/// tests can assert that a specific edge is visited.
const TraceEdges = struct {
    fn recordHeader(set: *std.AutoHashMap(usize, void), header: *core.gc.Header) void {
        set.put(@intFromPtr(header), {}) catch unreachable;
    }

    const Visitor = struct {
        set: *std.AutoHashMap(usize, void),

        pub fn visitValue(self: Visitor, val: *core.JSValue) void {
            if (val.cycleMarkHeader()) |header| recordHeader(self.set, header);
        }

        pub fn visitObject(self: Visitor, obj_ptr: *?*core.Object) void {
            if (obj_ptr.*) |obj| {
                if (@intFromPtr(obj) == 0) return;
                recordHeader(self.set, obj.gcHeader());
            }
        }

        pub fn visitShape(self: Visitor, shape_ref: *core.Shape) void {
            recordHeader(self.set, &shape_ref.header);
        }

        pub fn visitRealm(self: Visitor, ctx_ptr: *?*core.context.RealmContext) void {
            if (ctx_ptr.*) |ctx| recordHeader(self.set, &ctx.header);
        }

        pub fn visitModule(self: Visitor, record: *core.ModuleRecord) void {
            recordHeader(self.set, &record.header);
        }

        pub fn storageCell(self: Visitor, edge: core.gc_visit.CellSlot) void {
            const header: *core.gc.Header = @ptrFromInt(edge.address());
            recordHeader(self.set, header);
        }

        pub fn visitWeakCollectionEntry(_: Visitor, _: *core.object.WeakCollectionEntry) void {}

        pub fn visitFinalizationCell(self: Visitor, entry: *core.object.FinalizationRegistryCell) void {
            if (entry.keepsHeldValuesAlive()) self.visitValue(&entry.held_value);
        }
    };

    fn collect(rt: *core.JSRuntime, header: *core.gc.Header, allocator: std.mem.Allocator) ![]usize {
        var set = std.AutoHashMap(usize, void).init(allocator);
        defer set.deinit();
        const visitor = Visitor{ .set = &set };
        switch (header.meta().flags.kind) {
            .object => {
                const obj = core.Object.fromHeader(header);
                obj.traceChildEdgesNoFail(rt, visitor);
            },
            .function_bytecode => {
                const fb: *engine.bytecode.FunctionBytecode = @alignCast(@fieldParentPtr("header", header));
                var realm = fb.realm.ptr;
                visitor.visitRealm(&realm);
                fb.realm.ptr = realm;
                for (fb.cpoolSlice()) |*stored| visitor.visitValue(stored);
            },
            .var_ref => {
                const ref: *core.VarRef = @alignCast(@fieldParentPtr("header", header));
                visitor.visitValue(&ref.value);
            },
            .shape => {
                const shape_ref: *core.Shape = @alignCast(@fieldParentPtr("header", header));
                shape_ref.traceChildEdgesNoFail(rt, visitor);
            },
            .realm_context => {
                const ctx: *core.JSContext = @alignCast(@fieldParentPtr("header", header));
                ctx.traceChildEdgesNoFail(visitor);
            },
            .module => {
                const record: *core.ModuleRecord = @alignCast(@fieldParentPtr("header", header));
                record.traceChildEdgesNoFail(rt, visitor);
            },
            .rope => {
                const node: *core.string.StringRope = @ptrCast(@alignCast(header));
                if (node.buffer) |buf| visitor.storageCell(buf.header());
                visitor.visitValue(&node.left);
                visitor.visitValue(&node.right);
            },
            .string, .string_buffer, .big_int, .property_storage, .array_storage, .payload => {},
        }
        const keys = try allocator.alloc(usize, set.count());
        var index: usize = 0;
        var iterator = set.keyIterator();
        while (iterator.next()) |key| {
            keys[index] = key.*;
            index += 1;
        }
        std.mem.sort(usize, keys, {}, std.sort.asc(usize));
        return keys;
    }

    fn expectContains(headers: []const usize, header: *core.gc.Header) !void {
        const ptr = @intFromPtr(header);
        for (headers) |item| {
            if (item == ptr) return;
        }
        return error.TestUnexpectedResult;
    }
};

// ---------------------------------------------------------------------------
// TGC S2 lane A: symbol bodies are tracer-owned cells, so every weak seam that
// already worked for objects has to work for a symbol target too. The atom
// table's `entry.str` binding is NOT the authority during a sweep -- these
// four pin the mark as the authority instead.
// ---------------------------------------------------------------------------

fn weakPersistentCounterCallback(_: *core.JSRuntime, context: ?*anyopaque) void {
    const counter: *usize = @ptrCast(@alignCast(context.?));
    counter.* += 1;
}

fn interruptOnce(_: *core.JSRuntime, userdata: ?*anyopaque) bool {
    const count: *usize = @ptrCast(@alignCast(userdata.?));
    count.* += 1;
    return true;
}

var exotic_define_calls: usize = 0;
var exotic_delete_calls: usize = 0;

fn exoticGet(_: *core.Object, _: core.Atom) ?core.Descriptor {
    return core.Descriptor.data(core.JSValue.int32(99), .{ .configurable = true });
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
    const keys = try mem_ops.alloc(rt, core.Atom, 1);
    keys[0] = core.atom.ids.length;
    return keys;
}

/// How many times the whole-heap iterator yields `header`, and how many
/// extent strings it sees in total. Extents live in the block heap's
/// medium/large tables -- no list link, no cell, no bitmap -- so this is the
/// Latin1 length whose body cannot fit a block cell, sized off the frozen
/// class table rather than a literal: S2-f raised `measured_max_small_payload`
/// from 128 to 3760, and every one of these tests would otherwise have gone on
/// "testing extents" against block cells.
const extent_latin1_len: usize = core.gc_space.max_small_payload;

/// only enumeration that can prove they are visible to census/verify.
fn countExtentStringHeaders(rt: *core.JSRuntime, header: *const core.gc.Header) struct {
    matches: usize,
    extents: usize,
} {
    var matches: usize = 0;
    var extents: usize = 0;
    var iterator = rt.gc.objectIterator(.all);
    while (iterator.next()) |candidate| {
        if (candidate.metaConst().flags.kind != .string) continue;
        if (core.gc.Registry.isBlockCellHeader(candidate)) continue;
        extents += 1;
        if (candidate == header) matches += 1;
    }
    return .{ .matches = matches, .extents = extents };
}

/// TGC S3: an atom entry is not a heap object, so no `objectIterator` can save
/// or restore it -- its liveness is a stamp compared against `Heap.mark_epoch`.
/// One known id is a sharper probe than a table-wide count: the minor's own
/// trace re-stamps whatever it reaches, and a count would hide a lost stamp
/// behind that work.
fn atomMarkEpochForTest(rt: *core.JSRuntime, id: anytype) ?u64 {
    for (rt.atoms.entries) |*entry| {
        if (!entry.occupied) continue;
        if (entry.id == id) return entry.mark_epoch;
    }
    return null;
}

/// Drive one whole major -- mark, condemn and destroy -- over a heap of
/// `garbage` dead objects.
fn driveOneMajorForCensusTest(rt: *core.JSRuntime, garbage: usize) !void {
    rt.forcePreciseRootScanForTest();
    var index: usize = 0;
    while (index < garbage) : (index += 1) {
        _ = try core.Object.create(rt, core.class.ids.object, null);
    }
    rt.setGCThreshold(rt.gc.heap_budget.bytes -| 1);
    _ = try rt.pollGC(null, .safepoint);
    var polls: usize = 0;
    while (rt.gc.morgue.pending) : (polls += 1) {
        try std.testing.expect(polls < 10_000);
        _ = try rt.pollGC(null, .safepoint);
    }
}

test "the marked-set census is its own opt-in, not a rider on the stats panel" {
    if (comptime core.memory.force_gc_on_allocation_enabled) return;
    // `--gc-stats` is the only instrument for the pause distribution, and the
    // marked-set census is a whole-heap walk inside the final-remark stop. A
    // ruler that costs 24% of the score it is used to read cannot adjudicate
    // pause work, so the two flags are separate and this pins the separation:
    // asking for the panel must not start the walk.
    const reports_before = core.gc_trace_stw.detailed_reports;
    core.gc_trace_stw.detailed_reports = true;
    defer core.gc_trace_stw.detailed_reports = reports_before;
    const census_before = core.gc_trace_stw.mark_footprint_census;
    core.gc_trace_stw.mark_footprint_census = false;
    defer core.gc_trace_stw.mark_footprint_census = census_before;

    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    try driveOneMajorForCensusTest(rt, 256);
    try std.testing.expectEqual(@as(u64, 0), rt.diagnostics.mark_footprint.major_censuses);
    try std.testing.expectEqual(@as(u64, 0), rt.diagnostics.mark_footprint.marked_headers);

    // ... and the opt-in must actually reach the walk, or the assertion above
    // would pass just as well against a census that no flag can turn on.
    core.gc_trace_stw.mark_footprint_census = true;
    try driveOneMajorForCensusTest(rt, 256);
    try std.testing.expectEqual(@as(u64, 1), rt.diagnostics.mark_footprint.major_censuses);
    try std.testing.expect(rt.diagnostics.mark_footprint.marked_headers > 0);
}

test "runtime teardown owns a detached generator shell" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    _ = try core.Object.createGeneratorShell(rt, core.class.ids.generator);
    rt.destroy();
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
    helpers.finishGcCycles(rt);
}

test "TGC S3: a shape property key is an atom trace edge" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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

test "TGC S3: an id-held value symbol keeps its body marked" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    rt.forcePreciseRootScanForTest();

    const symbol_atom = try rt.atoms.newValueSymbol("zjs-s3-symbol-edge");
    // Materialize the body, then drop the JSValue: the body is now reachable
    // only through the entry the shape names by id.
    const body_value = try rt.symbolValue(symbol_atom);
    const body_header = body_value.stringHeader().?;

    const object = try core.Object.createPlainObject(rt, null);
    try rt.gc.pinHeader(object.gcHeader());
    defer rt.gc.unpinHeader(object.gcHeader());
    try object.defineOwnProperty(rt, symbol_atom, core.Descriptor.data(core.JSValue.int32(7), .all));

    try s3RunMajor(rt);
    try std.testing.expectEqual(s3MarkEpoch(rt), s3AtomEntry(rt, symbol_atom).mark_epoch);
    try std.testing.expect(rt.gc.headerMarked(body_header));
}

test "TGC S3-c: an atom no edge and no root reaches is retired by the major" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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
        var scope = core.atom.CompileAtomScope.init(&rt.atoms);
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
    const account = try mem_ops.createTestRuntime(std.testing.allocator);
    defer account.destroy();
    var table = core.atom.AtomTable.init(account);
    defer table.deinit();

    var scope = core.atom.CompileAtomScope.init(&table);
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
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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

    _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
    try std.testing.expect(entry.slotOccupied());
    try std.testing.expect(entry.str != null);
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    try std.testing.expect(!rt.atoms.symbolValueIfLive(rt, symbol_atom).is(.undefined_value));

    // Repeated minors keep it: the first one promoted the body, after which
    // the major's `visitAtom` rules are the only authority again.
    _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
    _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
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
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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
        if (index % 64 == 63) _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
    }

    var alive: usize = 0;
    for (ids) |id| alive += @intFromBool(!rt.atoms.symbolValueIfLive(rt, id).is(.undefined_value));
    try std.testing.expectEqual(@as(usize, 1000), alive);
}

test "TGC S3-c: a shape key keeps its atom, and the next major after the shape dies retires it" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    rt.forcePreciseRootScanForTest();

    const symbol_atom = try rt.atoms.newValueSymbol("zjsS3WeakShellSymbol");
    const entry_index = symbol_atom.raw() - core.atom.first_dynamic_atom;
    {
        var symbol_value = try rt.takeSymbolValue(symbol_atom);
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
    try std.testing.expect(rt.atoms.entries[entry_index].str == null);

    // A second major must not re-run the verdict on the shell.
    try s3RunMajor(rt);
    try std.testing.expect(rt.atoms.entries[entry_index].slotOccupied());

    // The last weak reference retires the shell.
    rt.atoms.releaseSymbolWeakRef(rt, symbol_atom);
    try std.testing.expect(!rt.atoms.entries[entry_index].slotOccupied());
}

test "needs_finalizer is recorded in both the header and the block bitmap" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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
    _ = rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCountKind(.property_storage));
    try std.testing.expect(rt.gc.containsHeader(storage));
    try expectS4bNamedProperties(rt, owner_slot.?, "s4b-live-", 6);

    owner_slot = null;
    _ = rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.property_storage));
}

test "TGC S4-b: an aged owner remembers a property buffer minted after its promotion" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    var owner_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.object, null);
    var owner_roots = core.runtime.rootObjects(.{&owner_slot});
    owner_roots.activate(rt);
    defer owner_roots.deactivate(rt);

    // Promote the owner before it owns any external storage: the minor's
    // sticky marks stop the trace at an old object, so from here every buffer
    // it adopts is an old-to-young edge that only a barrier can record.
    _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
    try std.testing.expect(!owner_slot.?.gcHeader().metaConst().flags.young);

    try defineS4bNamedProperties(rt, owner_slot.?, "s4b-grow-", 8);
    const storage: *core.gc.Header = @ptrCast(@alignCast(owner_slot.?.prop_values));
    try std.testing.expect(storage.metaConst().flags.young);

    // Deletion probe: drop `rememberOwnerForBulkWrite` from
    // `appendPreparedPropertyEntryWork` / `ensurePropertyCapacity` and this
    // minor condemns the buffer while `prop_values` still names it.
    _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
    try std.testing.expect(rt.gc.containsHeader(storage));
    try expectS4bNamedProperties(rt, owner_slot.?, "s4b-grow-", 8);
}

test "Q22: a bitmap-reclaimed storage cell leaves the byte ledger exactly once" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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
        const before_owner = rt.diagnostics.allocations.allocated_bytes;
        array_slot = try core.Object.createArray(rt, null);
        // Promote the owner first: every cell it adopts from here is an
        // old-to-young bulk write, so `rememberOwnerForBulkWrite` puts the
        // owner in the remembered map -- the condition that makes
        // `reclaimDoomedBlock` walk the corpses (test builds walk them
        // unconditionally under the lifecycle audit as well).
        _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
        try std.testing.expect(!array_slot.?.gcHeader().metaConst().flags.young);
        const before_cells = rt.diagnostics.allocations.allocated_bytes;

        try fillS4bDenseArray(rt, array_slot.?, 40);
        try std.testing.expect(rt.gc.generation.rememberedCount() != 0);
        try std.testing.expect(rt.gc.liveCountKind(.array_storage) > 4);
        const grown = rt.diagnostics.allocations.allocated_bytes;
        try std.testing.expect(grown > before_cells);

        // The superseded buffers owe no destructor: bitmap route only.
        _ = rt.collectForTest();
        try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCountKind(.array_storage));
        const one_cell = rt.diagnostics.allocations.allocated_bytes;
        try std.testing.expect(one_cell < grown);
        try std.testing.expect(one_cell > before_cells);

        array_slot = null;
        _ = rt.collectForTest();
        try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.array_storage));
        if (round == 1) try std.testing.expectEqual(before_owner, rt.diagnostics.allocations.allocated_bytes);
    }
}

test "TGC S4-b: a growing dense array leaves every superseded element cell to the sweep" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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

    _ = rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCountKind(.array_storage));
    try std.testing.expectEqual(@as(usize, 40), array_slot.?.arrayElements().len);
    for (array_slot.?.arrayElements(), 0..) |element, index| {
        try std.testing.expectEqual(@as(?i32, @intCast(index)), element.as(.int));
    }

    array_slot = null;
    _ = rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.array_storage));
}

test "Q21: the element cell is kept alive by the arm, not by flags.fast_array" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    var array_slot: ?*core.Object = try core.Object.createArray(rt, null);
    var array_roots = core.runtime.rootObjects(.{&array_slot});
    array_roots.activate(rt);
    defer array_roots.deactivate(rt);

    try fillS4bDenseArray(rt, array_slot.?, 40);
    _ = rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCountKind(.array_storage));
    const cell = core.Object.arrayStorageCellHeader(array_slot.?.arrayArm().*.values);
    try std.testing.expect(rt.gc.containsHeader(cell));

    // A dense-mode transition that leaves the buffer attached. No production
    // path does this today (both clears go through
    // `freeArrayElementBufferAfterMove`), but the flag is a semantics bit and
    // the collector's edge must come from the arm: with the trace guarded on
    // `flags.fast_array` this major sweeps the cell the arm still names.
    array_slot.?.flags.fast_array = false;
    _ = rt.collectForTest();
    try std.testing.expect(rt.gc.containsHeader(cell));
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCountKind(.array_storage));

    array_slot.?.flags.fast_array = true;
    try std.testing.expectEqual(@as(usize, 40), array_slot.?.arrayElements().len);
    for (array_slot.?.arrayElements(), 0..) |element, index| {
        try std.testing.expectEqual(@as(?i32, @intCast(index)), element.as(.int));
    }

    array_slot = null;
    _ = rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.array_storage));
}

test "TGC S4-b: a mapped-arguments var-ref table is an array storage cell" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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
    _ = rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCountKind(.array_storage));
    const live_refs = arguments_slot.?.argumentsVarRefs();
    try std.testing.expectEqual(@as(usize, 2), live_refs.len);
    try std.testing.expect(live_refs[0].?.varRefValue().sameValue(target_slot.?.value()));
    try std.testing.expectEqual(@as(?i32, 7), live_refs[1].?.varRefValue().as(.int));

    arguments_slot = null;
    target_slot = null;
    _ = rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.array_storage));
}

test "TGC S4-b: storage over the block-cell ceiling takes the extent route and is swept" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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
    _ = rt.collectForTest();
    try expectS4bNamedProperties(rt, owner_slot.?, "s4b-extent-", 200);
    try std.testing.expectEqual(@as(usize, 400), array_slot.?.arrayElements().len);
    try std.testing.expectEqual(@as(?i32, 399), array_slot.?.arrayElements()[399].as(.int));

    owner_slot = null;
    array_slot = null;
    _ = rt.collectForTest();
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

test "promise coallocation: state and reactions survive through the sole owner" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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
    _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
    try std.testing.expect(!promise.?.gcHeader().metaConst().flags.young);
    var targets: [4]*core.gc.Header = undefined;
    for (&targets, 0..) |*header, index| {
        temporary = try core.Object.create(rt, core.class.ids.object, null);
        header.* = temporary.?.gcHeader();
        switch (index) {
            0 => try promise.?.setPromiseResult(rt, temporary.?.value()),
            1 => try promise.?.setPromiseReactionCallback(rt, temporary.?.value()),
            2 => try promise.?.setPromiseReactionArg(rt, temporary.?.value()),
            3 => for (0..6) |_| {
                try engine.exec.promise_ops.appendPromiseReaction(rt, promise.?, temporary.?.value());
            },
            else => unreachable,
        }
    }
    temporary = null;
    _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
    for (targets) |header| try std.testing.expect(rt.gc.containsHeader(header));
    _ = rt.collectForTest();
    for (targets) |header| try std.testing.expect(rt.gc.containsHeader(header));
    try std.testing.expectEqual(result_slot, promise.?.promiseResultSlot());
    try std.testing.expectEqual(@as(usize, 6), promise.?.promiseReactions().len);
    // Only the final reaction backing is a standalone payload cell.
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCountKind(.payload));
    promise = null;
    _ = rt.collectForTest();
    for (targets) |header| try std.testing.expect(!rt.gc.containsHeader(header));
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.payload));
}

test "promise coallocation: accounting and allocation failure share the object cell" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    rt.forcePreciseRootScanForTest();
    rt.setGCThreshold(std.math.maxInt(usize));
    var promise: ?*core.Object = try core.Object.create(rt, core.class.ids.promise, null);
    var roots = core.runtime.rootObjects(.{&promise});
    roots.activate(rt);
    defer roots.deactivate(rt);
    _ = rt.collectForTest();
    const raw_bytes = rt.gc.block_heap.rawBytesForCell(@intFromPtr(promise.?), core.gc.metadata_prefix_size).?;
    const expected = raw_bytes - core.gc.metadata_prefix_size;
    try std.testing.expectEqual(expected, promise.?.bodyBytes());
    try std.testing.expectEqual(expected, promise.?.allocationSize(rt));
    try std.testing.expectEqual(expected, core.gc.Registry.heapByteSizeFromHeader(rt, promise.?.gcHeader()));
    const objects_before = rt.gc.liveCountKind(.object);
    rt.setNativeBytesLimitForTest(rt.diagnostics.allocations.allocated_bytes);
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
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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
    _ = rt.collectForTest();
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
    _ = rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.payload));
}

test "TGC S4-c: a bytecode function's rare/aux record is a payload cell" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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

    _ = rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 1), rt.gc.liveCountKind(.payload));
    try std.testing.expect(function_slot.?.functionSource().?.same(source_slot.?.value()));

    function_slot = null;
    _ = rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.payload));
}

test "TGC S4-c: an aged promise remembers a reaction cell minted after its promotion" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    var promise_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.promise, null);
    var target_slot: ?*core.Object = try core.Object.create(rt, core.class.ids.object, null);
    var roots = core.runtime.rootObjects(.{ &promise_slot, &target_slot });
    roots.activate(rt);
    defer roots.deactivate(rt);

    // Promote the promise (and its payload cell) before it owns a reaction
    // list, so every subsequent growth cell is an old-to-young edge.
    _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
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
    _ = try core.gc_trace_stw.collectMinor(rt, null, .declared_only);
    try std.testing.expect(rt.gc.containsHeader(reactions_cell));
    try std.testing.expectEqual(@as(usize, 6), promise_slot.?.promiseReactions().len);
    for (promise_slot.?.promiseReactions()) |reaction| {
        try std.testing.expect(reaction.same(target_slot.?.value()));
    }
}

test "TGC S4-c: bound arguments, disposable resources and arguments var-refs cross a major" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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
    _ = rt.collectForTest();
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
    _ = rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.payload));
}

test "TGC S4-c: a payload slice over the block-cell ceiling takes the extent route" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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
    _ = rt.collectForTest();
    try std.testing.expect(rt.gc.containsHeader(storage));
    try std.testing.expectEqual(@as(usize, 500), bound_slot.?.boundArgs().len);
    try std.testing.expect(bound_slot.?.boundArgs()[499].same(target_slot.?.value()));

    bound_slot = null;
    target_slot = null;
    _ = rt.collectForTest();
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCountKind(.payload));
}

// --- gc stress ---

const bytecode = zjs.bytecode;
const Rng = std.Random.DefaultPrng;

fn bindObjectRoots(slots: []?*core.Object, roots: []*?*core.Object) void {
    for (roots, slots) |*root, *slot| root.* = slot;
}

test "gc stress deterministic tiny heap preserves live roots" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator, .gc_threshold = 1 });
    defer rt.destroy();

    const count = 32;
    var objects: [count]?*core.Object = @splat(null);
    var object_roots: [count]*?*core.Object = undefined;
    bindObjectRoots(&objects, &object_roots);
    var frame = core.runtime.ValueRootFrame{ .objects = &object_roots };
    frame.activate(rt);
    defer frame.deactivate(rt);

    const edge_key = try rt.internAtom("tiny-heap-edge");

    for (&objects, 0..) |*slot, index| {
        slot.* = try core.Object.create(rt, core.class.ids.object, null);
        if (index != 0) {
            try objects[index - 1].?.defineOwnProperty(
                rt,
                edge_key,
                core.Descriptor.data(slot.*.?.value(), .all),
            );
        }
    }
    try objects[count - 1].?.defineOwnProperty(
        rt,
        edge_key,
        core.Descriptor.data(objects[0].?.value(), .all),
    );
    // Baseline after a sweep: shapes the objects transitioned away from are
    // tracer-owned garbage until collected, and must not count as "live".
    _ = try rt.forceGC(null);
    const live_with_cycle = rt.gc.liveCount();
    try std.testing.expect(live_with_cycle >= count);

    // Keep objects[0] as the named external root and drop the other
    // construction retains. The cycle through objects[0] keeps the rest.
    for (objects[1..]) |*slot| {
        slot.* = null;
    }
    _ = try rt.forceGC(null);
    try std.testing.expectEqual(live_with_cycle, rt.gc.liveCount());

    objects[0] = null;
    _ = try rt.forceGC(null);
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
    try std.testing.expect(rt.gc.stats.cycle_gc_count > 1);
}

test "gc stress deterministic object cycles are reclaimed" {
    var prng = Rng.init(0x7a6a_6763_0001);
    const random = prng.random();

    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const count = 128;
    var objects: [count]?*core.Object = @splat(null);
    var object_roots: [count]*?*core.Object = undefined;
    bindObjectRoots(&objects, &object_roots);
    var frame = core.runtime.ValueRootFrame{ .objects = &object_roots };
    frame.activate(rt);
    defer frame.deactivate(rt);
    var external_alive: [count]bool = @splat(true);

    for (&objects) |*slot| {
        slot.* = try core.Object.create(rt, core.class.ids.object, null);
    }

    const edge_key = try rt.internAtom("stress-edge");

    for (objects) |obj| {
        const target_index = random.uintLessThan(usize, objects.len);
        const target = objects[target_index].?;
        try obj.?.defineOwnProperty(rt, edge_key, core.Descriptor.data(target.value(), .all));
    }

    for (&objects, 0..) |*slot, index| {
        if ((index % 3) == 0) {
            slot.* = null;
            external_alive[index] = false;
        }
    }

    for (&objects, 0..) |*slot, index| {
        if (external_alive[index]) {
            slot.* = null;
        }
    }

    _ = try rt.forceGC(null);
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "gc stress weak map preserved key keeps value alive" {
    var prng = Rng.init(0x7a6a_6763_0002);
    const random = prng.random();

    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const weakmap = try core.Object.create(rt, core.class.ids.weakmap, null);
    const count = 16;
    const preserved_index = random.uintLessThan(usize, count);
    var keys: [count]?*core.Object = @splat(null);
    var values: [count]?*core.Object = @splat(null);
    var key_roots: [count]*?*core.Object = undefined;
    var value_roots: [count]*?*core.Object = undefined;
    bindObjectRoots(&keys, &key_roots);
    bindObjectRoots(&values, &value_roots);
    var weakmap_slot: ?*core.Object = weakmap;
    var live_roots = core.runtime.rootObjects(.{&weakmap_slot});
    live_roots.activate(rt);
    defer live_roots.deactivate(rt);
    var key_frame = core.runtime.ValueRootFrame{ .objects = &key_roots };
    key_frame.activate(rt);
    defer key_frame.deactivate(rt);
    var value_frame = core.runtime.ValueRootFrame{ .objects = &value_roots };
    value_frame.activate(rt);
    defer value_frame.deactivate(rt);

    for (&keys, &values) |*key_slot, *value_slot| {
        key_slot.* = try core.Object.create(rt, core.class.ids.object, null);
        value_slot.* = try core.Object.create(rt, core.class.ids.object, null);
    }

    for (keys, values) |key, value| {
        try appendWeakCollectionEntry(rt, weakmap, key.?, value.?.value());
    }
    for (&values) |*slot| slot.* = null;

    for (&keys, 0..) |*slot, index| {
        if (index != preserved_index) {
            slot.* = null;
        }
    }

    _ = try rt.forceGC(null);
    try std.testing.expectEqual(@as(usize, 1), weakmap.weakCollectionEntries().len);
    // Shapes are GC objects now: weakmap + preserved key + value share
    // one live empty root shape.
    try std.testing.expectEqual(@as(usize, 4), rt.gc.liveCount());

    weakmap_slot = null;
    keys[preserved_index] = null;
    _ = try rt.forceGC(null);
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "gc stress weak map dead cyclic keys clear values" {
    var prng = Rng.init(0x7a6a_6763_0003);
    const random = prng.random();

    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const weakmap = try core.Object.create(rt, core.class.ids.weakmap, null);
    const count = 24;
    var keys: [count]?*core.Object = @splat(null);
    var values: [count]?*core.Object = @splat(null);
    var key_roots: [count]*?*core.Object = undefined;
    var value_roots: [count]*?*core.Object = undefined;
    bindObjectRoots(&keys, &key_roots);
    bindObjectRoots(&values, &value_roots);
    var weakmap_slot: ?*core.Object = weakmap;
    var live_roots = core.runtime.rootObjects(.{&weakmap_slot});
    live_roots.activate(rt);
    defer live_roots.deactivate(rt);
    var key_frame = core.runtime.ValueRootFrame{ .objects = &key_roots };
    key_frame.activate(rt);
    defer key_frame.deactivate(rt);
    var value_frame = core.runtime.ValueRootFrame{ .objects = &value_roots };
    value_frame.activate(rt);
    defer value_frame.deactivate(rt);

    for (&keys, &values) |*key_slot, *value_slot| {
        key_slot.* = try core.Object.create(rt, core.class.ids.object, null);
        value_slot.* = try core.Object.create(rt, core.class.ids.object, null);
    }

    const self_key = try rt.internAtom("stress-weak-dead-self");
    const peer_key = try rt.internAtom("stress-weak-dead-peer");

    for (keys, values) |key, value| {
        try key.?.defineOwnProperty(rt, self_key, core.Descriptor.data(key.?.value(), .all));
        const peer = keys[random.uintLessThan(usize, keys.len)].?;
        try key.?.defineOwnProperty(rt, peer_key, core.Descriptor.data(peer.value(), .all));
        try appendWeakCollectionEntry(rt, weakmap, key.?, value.?.value());
    }
    for (&values) |*slot| slot.* = null;

    for (&keys) |*slot| {
        slot.* = null;
    }
    try std.testing.expectEqual(@as(usize, count), weakmap.weakCollectionEntries().len);

    _ = try rt.forceGC(null);
    try std.testing.expectEqual(@as(usize, 0), weakmap.weakCollectionEntries().len);
    // The live weakmap keeps its empty root shape alive.
    try std.testing.expectEqual(@as(usize, 2), rt.gc.liveCount());

    weakmap_slot = null;
    _ = try rt.forceGC(null);
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "gc stress finalization registry dead target queues pending job" {
    var prng = Rng.init(0x7a6a_6763_0004);
    const random = prng.random();

    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    var ctx = try core.JSContext.create(rt, .{});
    var ctx_alive = true;
    defer if (ctx_alive) ctx.destroy();

    const cleanup = try core.Object.create(rt, core.class.ids.object, null);
    const registry = try core.Object.createFinalizationRegistry(rt, ctx, null);
    var cleanup_slot: ?*core.Object = cleanup;
    var registry_slot: ?*core.Object = registry;
    var live_roots = core.runtime.rootObjects(.{ &registry_slot, &cleanup_slot });
    live_roots.activate(rt);
    defer live_roots.deactivate(rt);
    registry.finalizationRegistryCleanupCallbackSlot().* = cleanup.value();

    var target = try core.Object.create(rt, core.class.ids.object, null);
    var target_value = target.value();
    const self_key = try rt.internAtom("stress-finalization-target-self");
    try target.defineOwnProperty(rt, self_key, core.Descriptor.data(target_value, .all));

    var held = try core.Object.create(rt, core.class.ids.object, null);
    const held_key = try rt.internAtom("stress-finalization-held");
    try held.defineOwnProperty(rt, held_key, core.Descriptor.data(core.JSValue.int32(@intCast(random.intRangeLessThan(i16, 1, 2048))), .all));

    try registry.appendFinalizationRegistryCell(
        rt,
        target_value,
        held.value(),
        core.JSValue.undefinedValue(),
    );
    dropGcPtr(&held);
    target_value = core.JSValue.undefinedValue();
    dropGcPtr(&target);

    const collected = try rt.forceGC(null);
    try std.testing.expectEqual(@as(usize, 3), collected.freed_objects);
    // `processWeak` enqueues the cleanup in the same collection that unreaches
    // the target.
    try std.testing.expectEqual(@as(usize, 1), rt.pendingFinalizationJobCountForTest());
    try std.testing.expectEqual(@as(usize, 0), registry.finalizationRegistryCells().len);
    // cleanup + registry + held object + construction realm, plus the shared root shape and the
    // held object's one-property transition shape.
    try std.testing.expectEqual(@as(usize, 7), rt.gc.liveCount());

    rt.clearPendingFinalizationJobs();
    registry_slot = null;
    cleanup_slot = null;
    ctx.destroy();
    ctx_alive = false;
    dropGcPtr(&ctx);
    _ = try rt.forceGC(null);
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

test "gc stress function bytecode constant pool object cycles are reclaimed" {
    var prng = Rng.init(0x7a6a_6763_0006);
    const random = prng.random();

    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const count = 17;
    const step = 1 + random.uintLessThan(usize, count - 1);
    var functions: [count]?*core.Object = @splat(null);
    var captured: [count]?*core.Object = @splat(null);
    var function_roots: [count]*?*core.Object = undefined;
    var captured_roots: [count]*?*core.Object = undefined;
    bindObjectRoots(&functions, &function_roots);
    bindObjectRoots(&captured, &captured_roots);
    var function_frame = core.runtime.ValueRootFrame{ .objects = &function_roots };
    function_frame.activate(rt);
    defer function_frame.deactivate(rt);
    var captured_frame = core.runtime.ValueRootFrame{ .objects = &captured_roots };
    captured_frame.activate(rt);
    defer captured_frame.deactivate(rt);

    for (&functions, &captured) |*function_slot, *captured_slot| {
        const function = try core.Object.create(rt, core.class.ids.bytecode_function, null);
        const captured_obj = try core.Object.create(rt, core.class.ids.object, null);
        const fb = try bytecode.FunctionBytecode.createFixture(rt, .{ .cpool_count = 1 });
        fb.cpoolSlice()[0] = captured_obj.value();
        fb.publishFixtureNoFail(rt);

        try function.setFunctionBytecodeValue(rt, core.JSValue.functionBytecode(&fb.header));
        function_slot.* = function;
        captured_slot.* = captured_obj;
    }

    const function_key = try rt.internAtom("stress-bytecode-function");
    for (captured, 0..) |captured_obj, index| {
        const target_index = (index + step) % count;
        try captured_obj.?.defineOwnProperty(rt, function_key, core.Descriptor.data(functions[target_index].?.value(), .all));
    }

    for (&functions) |*slot| {
        slot.* = null;
    }
    for (&captured) |*slot| {
        slot.* = null;
    }

    _ = try rt.forceGC(null);
    try std.testing.expectEqual(@as(usize, 0), rt.gc.liveCount());
}

// --- oom cap ---

// 8MB memory-cap OOM behaviour fixtures (engine production gate).
// Catchable-OOM contract: unbounded JS growth under an 8MB cap becomes a JS
// InternalError, the process stays alive, and delivering the preallocated OOM
// exception allocates nothing.
const BindingContext = zjs.JSContext;

const cap_bytes: usize = 8 * 1024 * 1024;

fn expectStringValue(value: core.JSValue, expected: []const u8) !void {
    if (!value.isString()) return error.TestUnexpectedResult;
    const string_value = value.asStringBody() orelse return error.TestUnexpectedResult;
    if (!string_value.eqlBytes(expected)) return error.TestUnexpectedResult;
}

test "engine production: 8MB cap OOM reaches JS catch as InternalError and the context stays usable" {
    const rt = try core.JSRuntime.create(.{
        .allocator = std.testing.allocator,
        .memory_limit = cap_bytes,
    });
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    var wrapper = zjs.borrowContext(ctx);

    // Unbounded eager string growth must hit the cap, surface as a
    // catchable InternalError inside JS, and leave the engine alive.
    // (`"x".repeat(n)` materializes n bytes per round; plain `s = s + s`
    // would build O(1) rope links and overflow usize before ever touching
    // an 8MB cap.)
    const caught = try wrapper.eval(
        \\var oomName = "";
        \\var oomCaught = false;
        \\var n = 65536;
        \\var s = "";
        \\try {
        \\  for (;;) { n *= 2; s = "x".repeat(n); }
        \\} catch (e) {
        \\  // zjs maps OOM to the QuickJS-aligned InternalError *name*. There is
        \\  // no global InternalError constructor and the preallocated error's
        \\  // prototype is not chained under Error.prototype today, so pin the
        \\  // contract as: a catchable error object whose name is InternalError.
        \\  oomCaught = typeof e === "object" && e !== null && e.name === "InternalError";
        \\  oomName = e.name;
        \\  s = null;
        \\}
        \\oomCaught ? "caught:" + oomName : "uncaught"
    , .{ .filename = "<oom-cap>" });
    try expectStringValue(caught, "caught:InternalError");

    // Same context must keep working after the OOM was caught and the
    // oversized value released.
    const followup = try wrapper.eval("6 * 7", .{ .filename = "<oom-cap>" });
    try std.testing.expectEqual(@as(?i32, 42), followup.as(.int));

    // Array growth variant: same cap, same catchable shape. Chunky
    // elements keep the loop short (sub-second tier).
    const array_caught = try wrapper.eval(
        \\var arrName = "";
        \\try {
        \\  var a = [];
        \\  for (;;) { a.push("y".repeat(65536)); }
        \\} catch (e) {
        \\  arrName = e.name;
        \\  a = null;
        \\}
        \\arrName
    , .{ .filename = "<oom-cap>" });
    try expectStringValue(array_caught, "InternalError");

    const final = try wrapper.eval("\"alive\"", .{ .filename = "<oom-cap>" });
    try expectStringValue(final, "alive");
}

/// Counts allocations that actually reach the backing allocator. Used to
/// prove the exhausted-heap OOM delivery window performs zero allocations:
/// the runtime limit rejects Runtime allocation helpers-tracked allocations before they
/// reach this wrapper, and any path that bypassed the account (or released
/// the limit) would be counted here and fail the pin.
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    success_count: usize = 0,
    attempt_count: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }

    fn alloc(c: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(c));
        self.attempt_count += 1;
        const result = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.success_count += 1;
        return result;
    }

    fn resize(c: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(c));
        return self.backing.rawResize(m, a, n, ra);
    }

    fn remap(c: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(c));
        return self.backing.rawRemap(m, a, n, ra);
    }

    fn free(c: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(c));
        self.backing.rawFree(m, a, ra);
    }
};

const ExhaustState = struct {
    rt: *core.JSRuntime,
    counting: *CountingAllocator,
    snapshot: usize = 0,
    window_allocations: ?usize = null,

    fn exhaust(call: *zjs.native.Call) core.JSValue {
        const self = call.state(ExhaustState);
        self.snapshot = self.counting.success_count;
        // Freeze the heap: every further accounted allocation fails.
        mem_ops.setLimit(self.rt, self.rt.diagnostics.allocations.allocated_bytes);
        return core.JSValue.undefinedValue();
    }

    fn report(call: *zjs.native.Call) core.JSValue {
        const self = call.state(ExhaustState);
        self.window_allocations = self.counting.success_count - self.snapshot;
        mem_ops.setLimit(self.rt, null);
        return core.JSValue.undefinedValue();
    }
};

test "engine production: exhausted-heap OOM delivery to JS catch allocates nothing" {
    var counting = CountingAllocator{ .backing = std.testing.allocator };
    const rt = try core.JSRuntime.create(.{ .allocator = counting.allocator() });
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    var wrapper = zjs.borrowContext(ctx);

    var state = ExhaustState{ .rt = rt, .counting = &counting };
    _ = try wrapper.defineFunction("__exhaust", zjs.native.managed(ExhaustState.exhaust), .{ .state = @ptrCast(&state) });
    _ = try wrapper.defineFunction("__report", zjs.native.managed(ExhaustState.report), .{ .state = @ptrCast(&state) });

    // Phase 1 (normal memory): compile the probe up front so phase 2 runs
    // without parsing.
    const setup = try wrapper.eval(
        \\function trigger() { return "x".repeat(65536); }
        \\function probe() {
        \\  var name = "";
        \\  __exhaust();
        \\  try { trigger(); } catch (e) { name = e.name; }
        \\  __report();
        \\  return name;
        \\}
        \\"ready"
    , .{ .filename = "<oom-pin>" });
    try expectStringValue(setup, "ready");

    // Phase 2: inside one already-compiled call, exhaust the heap, force an
    // allocating operation to fail, and require (a) the catch handler sees
    // the preallocated InternalError and (b) zero allocations reached the
    // backing allocator inside the __exhaust..__report window.
    const result = try wrapper.eval("probe()", .{ .filename = "<oom-pin>" });
    try expectStringValue(result, "InternalError");

    try std.testing.expect(state.window_allocations != null);
    try std.testing.expectEqual(@as(usize, 0), state.window_allocations.?);
}

// --- engine production ---

const public_zjs = zjs;
const InterruptState = struct {
    hits: usize = 0,

    fn stop(_: *zjs.JSRuntime, ctx: ?*anyopaque) bool {
        const self: *InterruptState = @ptrCast(@alignCast(ctx.?));
        self.hits += 1;
        return true;
    }
};

const HostFunctionState = struct {
    value: i32,

    fn call(c: *zjs.native.Call) zjs.JSValue {
        return zjs.JSValue.int32(c.state(HostFunctionState).value);
    }
};

const HostFinalizerState = struct {
    calls: usize = 0,

    fn call(c: *zjs.native.Call) zjs.JSValue {
        _ = c;
        return zjs.JSValue.undefinedValue();
    }

    fn finalize(ptr: *anyopaque) void {
        const self: *HostFinalizerState = @ptrCast(@alignCast(ptr));
        self.calls += 1;
    }
};

const BytesStoreState = struct {
    allocator: std.mem.Allocator,
    calls: usize = 0,

    fn deinit(context: ?*anyopaque, bytes: []u8) void {
        const self: *BytesStoreState = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        self.allocator.free(bytes);
    }
};

test "production public API contract exposes Zig-native embedding spellings" {
    try std.testing.expect(@hasDecl(public_zjs, "Runtime"));
    try std.testing.expect(@hasDecl(public_zjs, "Context"));
    try std.testing.expect(@hasDecl(public_zjs, "Value"));
    try std.testing.expect(@hasDecl(public_zjs, "Call"));
    try std.testing.expect(@hasDecl(public_zjs, "EventLoop"));
    try std.testing.expect(@hasDecl(public_zjs.Context, "defineScriptArgs"));
    try std.testing.expect(public_zjs.Runtime == public_zjs.JSRuntime);
    try std.testing.expect(public_zjs.Context == public_zjs.JSContext);
    try std.testing.expect(public_zjs.Value == public_zjs.JSValue);
    try std.testing.expect(!@hasDecl(public_zjs.Value, "Scope"));
    try std.testing.expect(!@hasDecl(public_zjs.Value, "Local"));
    try std.testing.expect(!@hasDecl(public_zjs.Value, "Persistent"));
    try std.testing.expect(!@hasDecl(public_zjs.Value, "Weak"));
    try std.testing.expect(!@hasDecl(public_zjs, "host"));
    try std.testing.expect(!@hasDecl(public_zjs, "context"));
    try std.testing.expect(!@hasDecl(public_zjs, "value"));
    try std.testing.expect(!@hasDecl(public_zjs, "object"));
    try std.testing.expect(!@hasDecl(public_zjs, "module"));
    try std.testing.expect(!@hasDecl(public_zjs, "job"));
    try std.testing.expect(!@hasDecl(public_zjs, "internal"));
    try std.testing.expect(!@hasDecl(public_zjs, "kernel"));
    try std.testing.expect(!@hasDecl(public_zjs, "public_api"));
    try std.testing.expect(!@hasDecl(public_zjs, "CallSite"));
    try std.testing.expect(!@hasDecl(public_zjs, "PropertySite"));
    try std.testing.expect(!@hasDecl(public_zjs, "PropNameID"));
    try std.testing.expect(!@hasDecl(public_zjs, "binding"));
    try std.testing.expect(!@hasDecl(public_zjs, "binding_root"));
    try std.testing.expect(!@hasDecl(public_zjs, "js_context"));
}

test "production embedding can own JSRuntime and JSContext directly" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    var ctx: zjs.JSContext = undefined;
    try ctx.init(rt, .{});
    defer ctx.deinit();

    const value = try ctx.eval("1 + 1", .{});
    try std.testing.expectEqual(@as(?i32, 2), value.as(.int));

    const object = try ctx.eval("({ answer: 42 })", .{});
    try std.testing.expect(object.is(.object));

    const global = try zjs.globalObjectPtr(&ctx);
    try std.testing.expect(global.isGlobal());
}

test "production embedding API applies limits and releases eval handles" {
    const rt = try zjs.JSRuntime.create(.{
        .allocator = std.testing.allocator,
        .stack_size = 128 * 1024,
        .gc_threshold = 32 * 1024,
    });
    defer rt.destroy();

    try std.testing.expectEqual(@as(usize, 32 * 1024), rt.gcThreshold());
    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    try std.testing.expectEqual(@as(usize, 128 * 1024), rt.stackSize());
    // Bootstrap keeps the collector-adjusted dynamic threshold.
    try std.testing.expect(rt.gcThreshold() > 32 * 1024);
    try std.testing.expect(rt.gcThreshold() >= rt.gc.heap_budget.bytes);

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try ctx.eval("print(1 + 2);", .{ .output = &output });

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings("3\n", output.buffered());
}

test "production embedding can configure context policy through public methods" {
    const rt = try zjs.JSRuntime.create(.{
        .allocator = std.testing.allocator,
        .stack_size = 96 * 1024,
    });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{
        .track_unhandled_rejections = false,
    });
    defer ctx.destroy();

    try std.testing.expectEqual(@as(usize, 96 * 1024), ctx.stackLimit());
    ctx.setStackLimit(64 * 1024);
    try std.testing.expectEqual(@as(usize, 64 * 1024), ctx.stackLimit());

    try std.testing.expect(!ctx.tracksUnhandledRejections());
    ctx.setTrackUnhandledRejections(true);
    try std.testing.expect(ctx.tracksUnhandledRejections());

    try std.testing.expect(!ctx.preservesUncaughtException());
    ctx.setPreserveUncaughtException(true);
    try std.testing.expect(ctx.preservesUncaughtException());
}

test "production default host surface stays minimal" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var output_buffer: [160]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try ctx.eval(
        \\print(1);
        \\console.log(2);
        \\print(typeof std, typeof os, typeof setTimeout);
        \\try { std; } catch (e) { print(e.name); }
        \\try { os; } catch (e) { print(e.name); }
    , .{ .output = &output });

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings(
        "1\n2\nundefined undefined undefined\nReferenceError\nReferenceError\n",
        output.buffered(),
    );
}

test "production event loop does not add product runtime globals" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var output_buffer: [160]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var event_loop = zjs.runtime.EventLoop.init(ctx, .{ .output = &output });
    event_loop.install();
    defer event_loop.deinit();

    const result = try ctx.eval(
        \\print(1);
        \\console.log(2);
        \\print(typeof std, typeof os, typeof setTimeout, typeof setInterval, typeof clearTimeout, typeof clearInterval);
    , .{ .output = &output });

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings(
        "1\n2\nundefined undefined undefined undefined undefined undefined\n",
        output.buffered(),
    );
}

test "production embedding can install external host functions" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var state = HostFunctionState{ .value = 42 };
    _ = try ctx.defineFunction("hostValue", zjs.native.managed(HostFunctionState.call), .{ .state = @ptrCast(&state) });

    const result = try ctx.eval("hostValue()", .{});
    try std.testing.expectEqual(@as(?i32, 42), result.as(.int));
}

test "production embedding can create external host function values" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var state = HostFunctionState{ .value = 7 };
    const function = try ctx.createFunction("HostCtor", zjs.native.managed(HostFunctionState.call), .{ .state = @ptrCast(&state), .with_prototype = true });
    try std.testing.expect(function.is(.object));
    try std.testing.expect(ctx.isCallable(function));
    try std.testing.expect(ctx.isConstructor(function));

    const name = try ctx.functionName(function, std.testing.allocator);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("HostCtor", name);

    const prototype = try ctx.getProperty(function, "prototype");
    try std.testing.expect(prototype.is(.object));

    const global = try ctx.globalObject();
    try ctx.defineDataProperty(global, "HostCtor", function, .{});
    const surface = try ctx.eval(
        \\var prototypeDescriptor = Object.getOwnPropertyDescriptor(HostCtor, "prototype");
        \\var constructorDescriptor = Object.getOwnPropertyDescriptor(HostCtor.prototype, "constructor");
        \\if (Object.getPrototypeOf(HostCtor) !== Function.prototype ||
        \\    Object.getPrototypeOf(HostCtor.prototype) !== Object.prototype ||
        \\    prototypeDescriptor.writable !== true ||
        \\    prototypeDescriptor.enumerable !== false ||
        \\    prototypeDescriptor.configurable !== false ||
        \\    constructorDescriptor.value !== HostCtor ||
        \\    constructorDescriptor.writable !== true ||
        \\    constructorDescriptor.enumerable !== false ||
        \\    constructorDescriptor.configurable !== true) {
        \\    throw new Error("invalid external constructor surface");
        \\}
    , .{});
    try std.testing.expect(surface.is(.undefined_value));
}

test "production embedding can create objects and define data properties" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const object = try ctx.createObject();
    try ctx.defineDataProperty(object, "answer", zjs.JSValue.int32(42), .{});

    const answer = try ctx.getProperty(object, "answer");
    try std.testing.expectEqual(@as(?i32, 42), answer.as(.int));
}

test "production embedding can inspect own property descriptors by JS key" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const envelope = try ctx.eval(
        \\(() => {
        \\  const key = Symbol("embedded");
        \\  const object = {};
        \\  Object.defineProperty(object, key, {
        \\    value: 17,
        \\    writable: false,
        \\    enumerable: false,
        \\    configurable: true,
        \\  });
        \\  return { object, key };
        \\})()
    , .{});

    const object = try ctx.getProperty(envelope, "object");
    const key = try ctx.getProperty(envelope, "key");

    try std.testing.expect(try ctx.hasOwnPropertyKey(object, key, .{}));
    var desc = (try ctx.ownPropertyDescriptor(object, key, .{})) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(core.PropertyDescriptor.data(zjs.JSValue.int32(17), .{ .configurable = true }).kind, desc.kind);
    try std.testing.expectEqual(@as(?i32, 17), desc.value.as(.int));
    try std.testing.expectEqual(false, desc.writable.?);
    try std.testing.expectEqual(false, desc.enumerable.?);
    try std.testing.expectEqual(true, desc.configurable.?);

    const read_value = try ctx.getPropertyKey(object, key, .{});
    try std.testing.expectEqual(@as(?i32, 17), read_value.as(.int));

    const inherited = try ctx.eval("Object.create({ inherited: 1 })", .{});
    try std.testing.expect(!try ctx.hasOwnProperty(inherited, "inherited"));
    try ctx.defineDataProperty(inherited, "owned", zjs.JSValue.int32(1), .{});
    try std.testing.expect(try ctx.hasOwnProperty(inherited, "owned"));
    try std.testing.expect(try ctx.deleteProperty(inherited, "owned"));
    try std.testing.expect(!try ctx.hasOwnProperty(inherited, "owned"));

    const proxy = try ctx.eval("new Proxy({ visible: 99 }, {})", .{});
    const visible_key = try ctx.createString("visible");
    var proxy_desc = (try ctx.ownPropertyDescriptor(proxy, visible_key, .{})) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(?i32, 99), proxy_desc.value.as(.int));

    const revoked = try ctx.eval("const r = Proxy.revocable({ visible: 1 }, {}); r.revoke(); r.proxy", .{});
    try std.testing.expectError(error.TypeError, ctx.ownPropertyDescriptor(revoked, visible_key, .{}));
}

test "production embedding can create strings and convert values to owned utf8" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const direct = try ctx.createString("caf\xc3\xa9");
    const direct_text = try direct.asString().?.toOwnedUtf8(std.testing.allocator);
    defer std.testing.allocator.free(direct_text);
    try std.testing.expectEqualStrings("caf\xc3\xa9", direct_text);

    const object = try ctx.eval("({ toString() { return 'semantic-\\u00e9'; } })", .{});
    const semantic_text = try ctx.toOwnedUtf8(object, std.testing.allocator);
    defer std.testing.allocator.free(semantic_text);
    try std.testing.expectEqualStrings("semantic-\xc3\xa9", semantic_text);
}

test "production embedding can convert values to numbers" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    try std.testing.expectEqual(@as(?f64, 42), zjs.JSValue.number(42.0).asNumber());
    try std.testing.expect(zjs.JSValue.number(-0.0).as(.float64).? == 0);

    const numeric_object = try ctx.eval("({ valueOf() { return 12.75; } })", .{});
    try std.testing.expectEqual(@as(f64, 12.75), try ctx.toNumber(numeric_object));
    try std.testing.expectEqual(@as(f64, 12), try ctx.toIntegerOrInfinity(numeric_object));

    const non_numeric = try ctx.eval("({ toString() { return 'not-a-number'; } })", .{});
    try std.testing.expect(std.math.isNan(try ctx.toNumber(non_numeric)));
}

test "production embedding can inspect callable and constructor values" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const function = try ctx.eval("(function NamedForEmbedding() {})", .{});
    try std.testing.expect(ctx.isCallable(function));
    try std.testing.expect(ctx.isConstructor(function));

    const name = try ctx.functionName(function, std.testing.allocator);
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("NamedForEmbedding", name);

    const arrow = try ctx.eval("(() => {})", .{});
    try std.testing.expect(ctx.isCallable(arrow));
    try std.testing.expect(!ctx.isConstructor(arrow));

    try std.testing.expect(!ctx.isCallable(zjs.JSValue.int32(1)));
    try std.testing.expect(!ctx.isConstructor(zjs.JSValue.int32(1)));
}

test "production embedding can call JavaScript functions" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const function = try ctx.eval("(function addToBase(a, b) { return this.base + a + b; })", .{});

    const receiver = try ctx.createObject();
    try ctx.defineDataProperty(receiver, "base", zjs.JSValue.int32(10), .{});

    const result = try ctx.callFunction(function, &.{ zjs.JSValue.int32(2), zjs.JSValue.int32(3) }, .{
        .this_value = receiver,
    });
    try std.testing.expectEqual(@as(?i32, 15), result.as(.int));

    const throwing = try ctx.eval("(function fail() { throw new TypeError('call failed'); })", .{});
    try std.testing.expectError(error.JSException, ctx.callFunction(throwing, &.{}, .{}));
    try std.testing.expect(ctx.hasException());
    const exception = ctx.takePendingException();
    try std.testing.expect(exception.is(.object));
}

test "production embedding can compare values with SameValue semantics" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    try std.testing.expect(zjs.JSValue.float64(std.math.nan(f64)).sameValue(zjs.JSValue.float64(std.math.nan(f64))));
    try std.testing.expect(!zjs.JSValue.float64(0.0).sameValue(zjs.JSValue.float64(-0.0)));
    try std.testing.expect(zjs.JSValue.shortBigInt(7).sameValue(zjs.JSValue.shortBigInt(7)));

    const lhs = try ctx.eval("'same-value-string'", .{});
    const rhs = try ctx.eval("'same-' + 'value-string'", .{});
    try std.testing.expect(lhs.sameValue(rhs));
}

test "production embedding can inspect arrays and indexed values" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const array = try ctx.eval("[1, 2, 3]", .{});
    try std.testing.expect(try ctx.isArray(array));
    try std.testing.expectEqual(@as(u32, 3), try ctx.arrayLength(array));

    const second = try ctx.getIndex(array, 1);
    try std.testing.expectEqual(@as(?i32, 2), second.as(.int));

    const proxy = try ctx.eval("new Proxy([4], {})", .{});
    try std.testing.expect(try ctx.isArray(proxy));
    try std.testing.expectEqual(@as(u32, 1), try ctx.arrayLength(proxy));

    const object = try ctx.eval("({ length: 1, 0: 9 })", .{});
    try std.testing.expect(!try ctx.isArray(object));
    try std.testing.expectError(error.TypeError, ctx.arrayLength(object));

    const revoked = try ctx.eval("const r = Proxy.revocable([], {}); r.revoke(); r.proxy", .{});
    try std.testing.expectError(error.TypeError, ctx.isArray(revoked));
}

test "ordinary runtime stats do not walk the heap" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();
    const object = try ctx.eval("({})", .{});
    try std.testing.expect(object.is(.object));
    const walks_before = core.gc.heap_walks_for_test;
    const usage = rt.memoryUsage();
    const stats = rt.gcStats();
    try std.testing.expectEqual(walks_before, core.gc.heap_walks_for_test);
    try std.testing.expect(usage.allocated_bytes > 0);
    try std.testing.expectEqual(usage.peak_allocated_bytes, stats.peak_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), stats.external_bytes);
    const detailed = rt.gcDetailedStats();
    try std.testing.expect(core.gc.heap_walks_for_test > walks_before);
    try std.testing.expect(detailed.heap_live_bytes > 0);
    try std.testing.expectEqual(stats.external_bytes, detailed.counters.external_bytes);
    try std.testing.expectEqual(stats.peak_allocated_bytes, detailed.counters.peak_allocated_bytes);
}

fn countTraceMarker(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        n += 1;
        rest = rest[index + needle.len ..];
    }
    return n;
}

test "allocation trace records one account event and stops after writer failure" {
    const buf = try std.testing.allocator.alloc(u8, 256 * 1024);
    defer std.testing.allocator.free(buf);
    var writer = std.Io.Writer.fixed(buf);
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator, .trace_writer = &writer });
    defer rt.destroy();
    try std.testing.expect(!rt.diagnostics.trace.failed);
    const after_create = writer.buffered().len;
    var ticks: u64 = 0;
    rt.diagnostics.trace.profile_alloc_count = &ticks;
    const mem = try rt.allocRuntime(u8, 24);
    rt.freeRuntime(u8, mem);
    const added = writer.buffered()[after_create..];
    try std.testing.expectEqual(@as(usize, 1), countTraceMarker(added, "A "));
    try std.testing.expectEqual(@as(usize, 1), countTraceMarker(added, "F "));
    try std.testing.expectEqual(@as(u64, 1), ticks);

    const quiet = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer quiet.destroy();
    const quiet_before = writer.buffered().len;
    const quiet_mem = try quiet.allocRuntime(u8, 8);
    quiet.freeRuntime(u8, quiet_mem);
    try std.testing.expectEqual(quiet_before, writer.buffered().len);
    try std.testing.expect(quiet.diagnostics.trace.writer == null);

    var tiny: [1]u8 = undefined;
    var failing = std.Io.Writer.fixed(&tiny);
    const rt_fail = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator, .trace_writer = &failing });
    defer rt_fail.destroy();
    try std.testing.expect(rt_fail.diagnostics.trace.failed);
    const failed_mem = try rt_fail.allocRuntime(u8, 8);
    rt_fail.freeRuntime(u8, failed_mem);
    try std.testing.expect(rt_fail.diagnostics.trace.failed);
}

test "production embedding can inspect runtime memory usage without internal modules" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const usage: zjs.RuntimeMemoryUsage = rt.memoryUsage();
    try std.testing.expect(usage.allocated_bytes > 0);
    try std.testing.expect(usage.allocation_count > 0);
    try std.testing.expect(usage.atom_count > 0);
}

test "production embedding roots host-held values with public handles" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const object = try ctx.eval("({ answer: 42 })", .{});

    var scope = rt.enterHandleScope();
    const local = try scope.localDup(object);

    try std.testing.expectEqual(@as(usize, 1), rt.localRootCountForTest());
    try std.testing.expectEqual(@as(usize, 0), rt.persistentRootCountForTest());
    try std.testing.expect(local.get().is(.object));

    var persistent = try rt.createPersistentValue(local.get());
    defer persistent.deinit();

    scope.deinit();
    try std.testing.expectEqual(@as(usize, 0), rt.localRootCountForTest());
    try std.testing.expectEqual(@as(usize, 1), rt.persistentRootCountForTest());

    const answer = try ctx.getProperty(persistent.get(), "answer");
    try std.testing.expectEqual(@as(?i32, 42), answer.as(.int));

    persistent.deinit();
    try std.testing.expectEqual(@as(usize, 0), rt.persistentRootCountForTest());
}

test "production embedding can expose owned and shared byte stores" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var owned_state = BytesStoreState{ .allocator = std.testing.allocator };
    const owned_backing = try std.testing.allocator.alloc(u8, 4);
    @memcpy(owned_backing, &[_]u8{ 1, 2, 3, 4 });
    var owned_store = zjs.JSBytes.Store.owned(owned_backing, .{
        .deinit = BytesStoreState.deinit,
        .context = &owned_state,
    });
    errdefer owned_store.release();

    const owned_value = try ctx.arrayBuffer(&owned_store);
    try std.testing.expectEqual(@as(usize, 0), owned_store.bytes.len);
    try std.testing.expectEqual(@as(usize, 4), rt.gcStats().external_bytes);
    try std.testing.expectEqual(@as(usize, 4), rt.gcStats().external_token_bytes);
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().external_token_count);

    const owned_view: zjs.JSBytes = try owned_value.asBytes();
    try std.testing.expect(!owned_view.isShared());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, owned_view.slice());
    const owned_mut = try owned_view.sliceMut();
    owned_mut[1] = 9;
    try std.testing.expectEqualSlices(u8, &.{ 1, 9, 3, 4 }, owned_view.slice());
    try std.testing.expectEqual(@as(usize, 0), owned_state.calls);

    // Dropping the embedder's last reference is what ends the buffer's life
    // under refcounting; under the tracer it is what makes it collectable, and
    // the store's `deinit` runs when the collection reaches it. This is an
    // API-visible timing change for embedders that attach OS resources to a
    // byte store.
    helpers.reclaimNow(rt);
    try std.testing.expectEqual(@as(usize, 1), owned_state.calls);
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().external_bytes);
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().external_token_count);

    var shared_state = BytesStoreState{ .allocator = std.testing.allocator };
    const shared_backing = try std.testing.allocator.alloc(u8, 3);
    @memcpy(shared_backing, &[_]u8{ 8, 9, 10 });
    var shared_store = zjs.JSBytes.Store.shared(shared_backing, .{
        .deinit = BytesStoreState.deinit,
        .context = &shared_state,
    });
    errdefer shared_store.release();

    const shared_value = try ctx.arrayBuffer(&shared_store);
    try std.testing.expectEqual(@as(usize, 0), shared_store.bytes.len);
    try std.testing.expectEqual(@as(usize, 3), rt.gcStats().external_bytes);
    try std.testing.expectEqual(@as(usize, 3), rt.gcStats().external_token_bytes);
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().external_token_count);

    const shared_view: zjs.JSBytes = try shared_value.asBytes();
    try std.testing.expect(shared_view.isShared());
    try std.testing.expectEqualSlices(u8, &.{ 8, 9, 10 }, shared_view.slice());
    const shared_mut = try shared_view.sliceMut();
    shared_mut[0] = 12;
    try std.testing.expectEqualSlices(u8, &.{ 12, 9, 10 }, shared_view.slice());
    try std.testing.expectEqual(@as(usize, 0), shared_state.calls);

    helpers.reclaimNow(rt);
    try std.testing.expectEqual(@as(usize, 1), shared_state.calls);
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().external_bytes);
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().external_token_count);
}

test "production runtime can detach array buffers" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var owned_state = BytesStoreState{ .allocator = std.testing.allocator };
    const owned_backing = try std.testing.allocator.alloc(u8, 2);
    @memcpy(owned_backing, &[_]u8{ 3, 4 });
    var owned_store = zjs.JSBytes.Store.owned(owned_backing, .{
        .deinit = BytesStoreState.deinit,
        .context = &owned_state,
    });
    errdefer owned_store.release();

    const owned_value = try ctx.arrayBuffer(&owned_store);
    try std.testing.expectEqual(@as(usize, 0), owned_state.calls);

    const detached = try zjs.exec.buffer_ops.detachArrayBuffer(rt, owned_value);
    try std.testing.expect(detached.is(.undefined_value));
    try std.testing.expectEqual(@as(usize, 1), owned_state.calls);
    try std.testing.expectError(error.Detached, owned_value.asBytes());

    var shared_state = BytesStoreState{ .allocator = std.testing.allocator };
    const shared_backing = try std.testing.allocator.alloc(u8, 1);
    @memcpy(shared_backing, &[_]u8{5});
    var shared_store = zjs.JSBytes.Store.shared(shared_backing, .{
        .deinit = BytesStoreState.deinit,
        .context = &shared_state,
    });
    errdefer shared_store.release();

    const shared_value = try ctx.arrayBuffer(&shared_store);
    try std.testing.expectError(error.TypeError, zjs.exec.buffer_ops.detachArrayBuffer(rt, shared_value));
    try std.testing.expectEqual(@as(usize, 0), shared_state.calls);
}

test "production embedding can retain and rewrap shared array buffers" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var shared_state = BytesStoreState{ .allocator = std.testing.allocator };
    const shared_backing = try std.testing.allocator.alloc(u8, 3);
    @memcpy(shared_backing, &[_]u8{ 1, 2, 3 });
    var store = zjs.JSBytes.Store.shared(shared_backing, .{
        .deinit = BytesStoreState.deinit,
        .context = &shared_state,
    });
    errdefer store.release();

    const original = try ctx.arrayBuffer(&store);
    var shared_ref = try ctx.retainSharedArrayBuffer(original);
    defer shared_ref.release();

    const other_rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer other_rt.destroy();
    const other_ctx = try zjs.JSContext.create(other_rt, .{});
    defer other_ctx.destroy();

    const rewrapped = try other_ctx.sharedArrayBufferFromRef(shared_ref);
    const rewrapped_view = try rewrapped.asBytes();
    const rewrapped_mut = try rewrapped_view.sliceMut();
    rewrapped_mut[1] = 9;

    const original_view = try original.asBytes();
    try std.testing.expect(original_view.isShared());
    try std.testing.expectEqualSlices(u8, &.{ 1, 9, 3 }, original_view.slice());
    try std.testing.expectEqual(@as(usize, 0), shared_state.calls);

    try std.testing.expectError(error.TypeError, ctx.retainSharedArrayBuffer(zjs.JSValue.int32(1)));
}

test "production embedding lifecycle deinitializes repeated script and module evals" {
    var index: usize = 0;
    while (index < 4) : (index += 1) {
        const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
        defer rt.destroy();

        const ctx = try zjs.JSContext.create(rt, .{});
        defer ctx.destroy();

        const script_result = try ctx.eval(
            \\let values = [];
            \\for (let i = 0; i < 8; i++) values.push({ i });
            \\values.map(v => v.i).join(",");
        , .{ .discard_script_result = true });
        try std.testing.expect(script_result.is(.undefined_value));

        _ = try ctx.eval(
            \\const value = await Promise.resolve(42);
            \\export { value };
        , .{ .mode = .module });
    }
}

test "production module import.meta identity survives methods and nested closures" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    _ = try ctx.eval(
        \\const rootMeta = import.meta;
        \\class Holder {
        \\  read() { return import.meta; }
        \\}
        \\function nested() {
        \\  const arrow = () => import.meta;
        \\  return [import.meta, arrow()];
        \\}
        \\const [nestedMeta, arrowMeta] = nested();
        \\if (new Holder().read() !== rootMeta ||
        \\    nestedMeta !== rootMeta ||
        \\    arrowMeta !== rootMeta) {
        \\  throw new Error("import.meta identity escaped its module");
        \\}
    , .{ .mode = .module });
}

test "heap budget caps published cells without capping native alloc or external bytes" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    rt.forcePreciseRootScanForTest();
    rt.suppressLimitCollectionForTest(true);
    rt.setGCThreshold(std.math.maxInt(usize));

    const other = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer other.destroy();
    other.suppressLimitCollectionForTest(true);
    other.setGCThreshold(std.math.maxInt(usize));

    const before = rt.gc.heap_budget.bytes;
    var object: ?*core.Object = try core.Object.create(rt, core.class.ids.object, null);
    const with_object = rt.gc.heap_budget.bytes;
    try std.testing.expect(with_object > before);
    object = null;
    _ = rt.collectForTest();
    const after_collect = rt.gc.heap_budget.bytes;
    try std.testing.expect(after_collect < with_object);
    const charge = with_object - after_collect;

    const retries_before = rt.gc.heap_budget.limit_retries;
    rt.setMemoryLimit(after_collect + charge - 1);
    try std.testing.expectError(error.OutOfMemory, core.Object.create(rt, core.class.ids.object, null));
    try std.testing.expectEqual(after_collect, rt.gc.heap_budget.bytes);
    try std.testing.expectEqual(retries_before, rt.gc.heap_budget.limit_retries);

    rt.setMemoryLimit(after_collect + charge);
    object = try core.Object.create(rt, core.class.ids.object, null);
    try std.testing.expectEqual(after_collect + charge, rt.gc.heap_budget.bytes);
    object = null;
    _ = rt.collectForTest();
    try std.testing.expectEqual(after_collect, rt.gc.heap_budget.bytes);

    rt.setMemoryLimit(0);
    const native = try rt.allocRuntime(u8, 32);
    const heap_before_remap = rt.gc.heap_budget.bytes;
    rt.setNativeBytesLimitForTest(rt.diagnostics.allocations.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, rt.remapRuntime(u8, native, 128));
    try std.testing.expectEqual(heap_before_remap, rt.gc.heap_budget.bytes);
    rt.setNativeBytesLimitForTest(null);
    rt.freeRuntime(u8, native);

    const external_before = rt.gc.heap_budget.bytes;
    var token = try rt.reportExternalAlloc(128);
    defer token.release();
    try std.testing.expectEqual(external_before, rt.gc.heap_budget.bytes);
    try std.testing.expect(rt.gcStats().external_bytes >= 128);

    const other_before = other.gc.heap_budget.bytes;
    const other_object = try core.Object.create(other, core.class.ids.object, null);
    try std.testing.expect(other.gc.heap_budget.bytes > other_before);
    core.Object.destroyFromHeader(other, other_object.gcHeader());
    try std.testing.expectEqual(other_before, other.gc.heap_budget.bytes);
    try std.testing.expectEqual(after_collect, rt.gc.heap_budget.bytes);
}

test "heap limit collects once and then admits another object" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    rt.forcePreciseRootScanForTest();
    rt.setGCThreshold(std.math.maxInt(usize));
    _ = rt.collectForTest();

    const kept_object = try core.Object.create(rt, core.class.ids.object, null);
    var kept = kept_object.value();
    var kept_roots = core.runtime.rootValues(.{&kept});
    kept_roots.activate(rt);
    defer kept_roots.deactivate(rt);
    const with_kept = rt.gc.heap_budget.bytes;

    const charge = blk: {
        const dropped = try core.Object.create(rt, core.class.ids.object, null);
        const with_dropped = rt.gc.heap_budget.bytes;
        try std.testing.expect(with_dropped > with_kept);
        std.mem.doNotOptimizeAway(dropped);
        break :blk with_dropped - with_kept;
    };

    rt.setMemoryLimit(with_kept + charge);
    const retries = rt.gc.heap_budget.limit_retries;
    const majors = rt.gc.stats.collections;
    const created = try core.Object.create(rt, core.class.ids.object, null);
    try std.testing.expectEqual(retries + 1, rt.gc.heap_budget.limit_retries);
    try std.testing.expectEqual(majors + 1, rt.gc.stats.collections);
    try std.testing.expectEqual(with_kept + charge, rt.gc.heap_budget.bytes);
    try std.testing.expectEqual(core.class.ids.object, kept_object.class_id);
    try std.testing.expect(created != kept_object);
}

test "heap limit retry keeps a local object the precise root set cannot name" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    rt.setGCThreshold(std.math.maxInt(usize));
    _ = rt.collectForTest();

    var live = try core.Object.create(rt, core.class.ids.object, null);
    std.mem.doNotOptimizeAway(&live);
    const with_live = rt.gc.heap_budget.bytes;
    rt.setMemoryLimit(with_live);
    const retries = rt.gc.heap_budget.limit_retries;
    try std.testing.expectError(error.OutOfMemory, core.Object.create(rt, core.class.ids.object, null));
    try std.testing.expectEqual(retries + 1, rt.gc.heap_budget.limit_retries);
    try std.testing.expectEqual(with_live, rt.gc.heap_budget.bytes);
    try std.testing.expectEqual(core.class.ids.object, live.class_id);
}

test "heap limit of zero collects once and still rejects" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    rt.setGCThreshold(std.math.maxInt(usize));
    const seeded = try core.Object.create(rt, core.class.ids.object, null);
    std.mem.doNotOptimizeAway(seeded);
    try std.testing.expect(rt.gc.heap_budget.bytes > 0);
    rt.setMemoryLimit(0);
    const retries = rt.gc.heap_budget.limit_retries;
    try std.testing.expectError(error.OutOfMemory, core.Object.create(rt, core.class.ids.object, null));
    try std.testing.expectEqual(retries + 1, rt.gc.heap_budget.limit_retries);
    try std.testing.expect(rt.gc.heap_budget.bytes > 0);
}

test "native byte cap does not retry the heap limit" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    rt.setGCThreshold(std.math.maxInt(usize));
    const retries = rt.gc.heap_budget.limit_retries;
    const majors = rt.gc.stats.collections;
    rt.setNativeBytesLimitForTest(rt.diagnostics.allocations.allocated_bytes);
    defer rt.setNativeBytesLimitForTest(null);
    try std.testing.expectError(error.OutOfMemory, rt.allocRuntime(u8, 64));
    try std.testing.expectEqual(retries, rt.gc.heap_budget.limit_retries);
    try std.testing.expectEqual(majors, rt.gc.stats.collections);
}

test "heap limit retry does not nest while a collection is running" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    rt.setGCThreshold(std.math.maxInt(usize));
    rt.setMemoryLimit(rt.gc.heap_budget.bytes);
    rt.gc_running = true;
    defer rt.gc_running = false;
    const retries = rt.gc.heap_budget.limit_retries;
    const majors = rt.gc.stats.collections;
    try std.testing.expectError(error.OutOfMemory, core.Object.create(rt, core.class.ids.object, null));
    try std.testing.expect(rt.gc.heap_budget.limit_retries > retries);
    try std.testing.expectEqual(majors, rt.gc.stats.collections);
}

test "production embedding memory limit reports allocation failure without leaking" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    rt.setNativeBytesLimitForTest(rt.diagnostics.allocations.allocated_bytes);
    defer rt.setNativeBytesLimitForTest(null);

    try std.testing.expectError(error.OutOfMemory, ctx.eval("({ payload: new Array(32).fill('x') });", .{}));
}

test "production embedding public API allocation failures keep host ownership intact" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const object = try ctx.eval("({ answer: 42 })", .{});

    const persistent_before = rt.persistentRootCountForTest();
    const local_before = rt.localRootCountForTest();

    // Collect first, THEN pin the native cap to what is left.
    //
    // The cap is exactly the current footprint. A native cap does not collect,
    // so this only stays a failing allocation if nothing in the call allocates
    // less than the pinned total. The explicit collection makes that footprint
    // the live set rather than whatever garbage the previous test left behind.
    _ = rt.collectForTest();

    rt.setNativeBytesLimitForTest(rt.diagnostics.allocations.allocated_bytes);
    defer rt.setNativeBytesLimitForTest(null);

    if (rt.createPersistentValue(object)) |handle| {
        var owned = handle;
        owned.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expectEqual(persistent_before, rt.persistentRootCountForTest());
    try std.testing.expectEqual(local_before, rt.localRootCountForTest());

    if (ctx.createString("must allocate")) |_| {
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expectEqual(persistent_before, rt.persistentRootCountForTest());
    try std.testing.expectEqual(local_before, rt.localRootCountForTest());

    var finalizer_state = HostFinalizerState{};
    if (ctx.createFunction(
        "AllocationBlockedHostFn",
        zjs.native.managed(HostFinalizerState.call),
        .{ .state = @ptrCast(&finalizer_state), .finalize = HostFinalizerState.finalize },
    )) |_| {
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expectEqual(@as(usize, 0), finalizer_state.calls);

    var bytes_state = BytesStoreState{ .allocator = std.testing.allocator };
    const backing = try std.testing.allocator.alloc(u8, 2);
    @memcpy(backing, &[_]u8{ 1, 2 });
    var store = zjs.JSValue.Bytes.Store.owned(backing, .{
        .deinit = BytesStoreState.deinit,
        .context = &bytes_state,
    });
    defer store.release();

    if (ctx.arrayBuffer(&store)) |_| {
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    try std.testing.expectEqual(@as(usize, 0), bytes_state.calls);
    try std.testing.expectEqual(@as(usize, 2), store.bytes.len);
}

test "production embedding interrupt handler aborts unbounded execution" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var state = InterruptState{};
    rt.setInterruptHandler(InterruptState.stop, &state);
    defer rt.setInterruptHandler(null, null);

    try std.testing.expectError(error.Interrupted, ctx.eval("while (true) {}", .{}));
    try std.testing.expect(state.hits > 0);
}

test "production embedding interrupt handler aborts conditional-only backedge" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var state = InterruptState{};
    rt.setInterruptHandler(InterruptState.stop, &state);
    defer rt.setInterruptHandler(null, null);

    // A do/while loop closes with OP_if_true8 rather than OP_goto8. Conditional
    // branches must therefore poll just like unconditional backedges do.
    try std.testing.expectError(error.Interrupted, ctx.eval("do {} while (true);", .{}));
    try std.testing.expect(state.hits > 0);
}

test "production embedding interrupt handler aborts a recursion-only call loop" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    var state = InterruptState{};
    rt.setInterruptHandler(InterruptState.stop, &state);
    defer rt.setInterruptHandler(null, null);

    // There is no bytecode backedge in recurse: interruption depends on the
    // bytecode-call entry poll, matching QuickJS JS_CallInternal's poll point.
    try std.testing.expectError(
        error.Interrupted,
        ctx.eval("function recurse() { return 1 + recurse(); } recurse();", .{}),
    );
    try std.testing.expect(state.hits > 0);
}

test "production embedding takeException captures exception snapshot without leaking" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    _ = ctx.eval("throw new Error('test exception snapshot');", .{}) catch |err| {
        try std.testing.expectEqual(error.JSException, err);
        const thrown = ctx.takePendingException();
        try std.testing.expect(thrown.is(.object));
    };
}

test "production embedding can create and throw named errors" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const created = try ctx.createError("TypeError", "host-created", .{});
    const created_text = try ctx.formatException(created, std.testing.allocator);
    defer std.testing.allocator.free(created_text);
    try std.testing.expectEqualStrings("TypeError: host-created", created_text);

    const created_stack = try ctx.formatExceptionStack(created, std.testing.allocator);
    defer if (created_stack) |stack| std.testing.allocator.free(stack);
    try std.testing.expect(created_stack != null);

    try std.testing.expectError(error.JSException, ctx.throwError("RangeError", "host-thrown", .{}));
    try std.testing.expect(ctx.hasException());
    const thrown = ctx.takePendingException();

    const thrown_text = try ctx.formatException(thrown, std.testing.allocator);
    defer std.testing.allocator.free(thrown_text);
    try std.testing.expectEqualStrings("RangeError: host-thrown", thrown_text);
}

test "production embedding can match pending exceptions by error name" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    try std.testing.expect(!try ctx.pendingExceptionMatchesErrorName("TypeError"));
    try std.testing.expect(!try ctx.consumePendingExceptionIfErrorName("TypeError"));

    _ = ctx.eval("throw new TypeError('expected type');", .{}) catch |err| {
        try std.testing.expectEqual(error.JSException, err);
        try std.testing.expect(try ctx.pendingExceptionMatchesErrorName("TypeError"));
        try std.testing.expect(!try ctx.pendingExceptionMatchesErrorName("RangeError"));
        try std.testing.expect(try ctx.consumePendingExceptionIfErrorName("TypeError"));
        try std.testing.expect(!ctx.hasException());
    };

    try std.testing.expect(ctx.runtimeErrorMatchesErrorName(error.TypeError, "TypeError"));
    try std.testing.expect(ctx.runtimeErrorMatchesErrorName(error.NotExtensible, "TypeError"));
    try std.testing.expect(ctx.runtimeErrorMatchesErrorName(error.InvalidUtf8, "URIError"));
    try std.testing.expect(!ctx.runtimeErrorMatchesErrorName(error.RangeError, "TypeError"));
}

test "production embedding can create independent realms" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const retained = blk: {
        const realm = try ctx.createRealm();

        const realm_global = try ctx.realmGlobal(realm);
        try std.testing.expect(realm_global.is(.object));

        const realm_global_object = try ctx.realmGlobalObject(realm);
        try std.testing.expect(realm_global_object.isGlobal());

        const realm_global_this = try ctx.getProperty(realm_global, "globalThis");
        try std.testing.expect(realm_global_this.sameValue(realm_global));

        const current_array = try ctx.eval("Array", .{});
        const realm_array = try ctx.getProperty(realm_global, "Array");
        try std.testing.expect(!realm_array.sameValue(current_array));

        break :blk .{ try ctx.createValueHandle(realm_global), realm_global_object };
    };

    var realm_global_handle = retained[0];
    defer realm_global_handle.deinit();
    const realm_global_object = retained[1];
    try std.testing.expect(rt.contextForGlobal(realm_global_object) != null);
    {
        const retained_global_this = try ctx.getProperty(realm_global_handle.get(), "globalThis");
        try std.testing.expect(retained_global_this.sameValue(realm_global_handle.get()));
    }

    realm_global_handle.deinit();
    _ = rt.collectForTest();
    try std.testing.expect(rt.contextForGlobal(realm_global_object) == null);
}

test "production embedding can eval script source in explicit function realms" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const realm = try ctx.createRealm();
    const realm_global = try ctx.realmGlobal(realm);
    const realm_global_object = try ctx.realmGlobalObject(realm);

    try ctx.defineDataProperty(realm_global, "realmMarker", zjs.JSValue.int32(40), .{});

    const source_result = try ctx.evalScriptSource("realmMarker + 2", .{
        .realm_global = realm_global_object,
        .filename = "embedding-realm-source.js",
    });
    try std.testing.expectEqual(@as(?i32, 42), source_result.as(.int));

    const source_value = try ctx.createString("realmMarker + 3");
    const value_result = try ctx.evalScriptValue(source_value, .{
        .realm_global = realm_global_object,
        .filename = "embedding-realm-value.js",
    });
    try std.testing.expectEqual(@as(?i32, 43), value_result.as(.int));

    var state = HostFunctionState{ .value = 1 };
    const function = try ctx.createFunction("RealmTaggedHost", zjs.native.managed(HostFunctionState.call), .{
        .state = @ptrCast(&state),
        .realm_global = realm_global,
    });
    const function_global = (try ctx.functionRealmGlobal(function)) orelse return error.TestExpectedEqual;
    try std.testing.expect(function_global == realm_global_object);

    try std.testing.expectError(error.TypeError, ctx.evalScriptValue(zjs.JSValue.int32(1), .{}));
}

test "production embedding getProperty follows JavaScript accessors" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const object = try ctx.eval(
        \\let hits = 0;
        \\({
        \\  get stack() {
        \\    hits += 1;
        \\    return "semantic stack";
        \\  },
        \\  get hits() {
        \\    return hits;
        \\  }
        \\})
    , .{});

    const stack = try ctx.getProperty(object, "stack");
    var stack_text = try stack.asString().?.toUtf8(std.testing.allocator);
    defer stack_text.deinit();
    try std.testing.expectEqualStrings("semantic stack", stack_text.slice());

    const hits = try ctx.getProperty(object, "hits");
    try std.testing.expectEqual(@as(?i32, 1), hits.as(.int));
}

test "production embedding getProperty reports accessor exceptions" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const ctx = try zjs.JSContext.create(rt, .{});
    defer ctx.destroy();

    const object = try ctx.eval(
        \\({
        \\  get stack() {
        \\    throw new Error("stack getter failed");
        \\  }
        \\})
    , .{});

    try std.testing.expectError(error.JSException, ctx.getProperty(object, "stack"));
    try std.testing.expect(ctx.hasException());
    const thrown = ctx.takePendingException();
    try std.testing.expect(thrown.is(.object));
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
        const saved_trigger_fn = self.rt.gc.heap_budget.probe;
        const saved_trigger_ctx = self.rt.gc.heap_budget.probe_ctx;
        self.rt.gc.heap_budget.probe = null;
        self.rt.gc.heap_budget.probe_ctx = null;
        defer {
            self.rt.gc.heap_budget.probe = saved_trigger_fn;
            self.rt.gc.heap_budget.probe_ctx = saved_trigger_ctx;
        }
        const before = self.rt.gc.block_heap.mark_epoch;
        _ = self.rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {};
        if (self.rt.gc.block_heap.mark_epoch != before) self.majors += 1;
    }
};

test "TGC S3: a host-defined property name stays reachable across a major taken mid-define" {
    const rt = try zjs.JSRuntime.create(.{ .allocator = std.testing.allocator });
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

    const saved_trigger_fn = rt.gc.heap_budget.probe;
    const saved_trigger_ctx = rt.gc.heap_budget.probe_ctx;
    var probe = S3HostDefineMajorProbe{ .rt = rt };
    rt.gc.heap_budget.probe = S3HostDefineMajorProbe.trigger;
    rt.gc.heap_budget.probe_ctx = &probe;
    defer {
        rt.gc.heap_budget.probe = saved_trigger_fn;
        rt.gc.heap_budget.probe_ctx = saved_trigger_ctx;
    }

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
    try std.testing.expect(!rt.host_completion_event.isSet());
    try std.testing.expect(!rt.waitForHostCompletionUntil(io, past));
}

test "runtime init clears a prefilled host completion event and mark footprint" {
    var storage: [@sizeOf(core.JSRuntime)]u8 align(@alignOf(core.JSRuntime)) = undefined;
    @memset(std.mem.bytesAsSlice(u32, &storage), @intFromEnum(std.Io.Event.is_set));
    var prefilled = PrefilledRuntimeAllocator{
        .body = &storage,
        .child = std.testing.allocator,
    };
    const created = try core.JSRuntime.create(.{ .allocator = prefilled.allocator() });
    defer created.destroy();
    try std.testing.expectEqual(@intFromPtr(&storage), @intFromPtr(created));
    try std.testing.expect(prefilled.served_body);
    try std.testing.expectEqual(@as(usize, 0), created.diagnostics.mark_footprint.major_censuses);
    try std.testing.expectEqual(@as(usize, 0), created.diagnostics.mark_footprint.marked_headers);
    try expectUnsetCompletionWait(created);

    created.host_completion_event = .is_set;
    try std.testing.expect(created.host_completion_event.isSet());
    created.resetHostCompletionSignal();
    try expectUnsetCompletionWait(created);
}

fn expectRuntimeSelfReferences(rt: *core.JSRuntime) !void {
    try std.testing.expectEqual(@intFromPtr(rt), @intFromPtr(rt.atoms.owner_runtime.?));
    try std.testing.expectEqual(@intFromPtr(rt), @intFromPtr(rt.atoms.runtime.?));
    try std.testing.expectEqual(@intFromPtr(rt), @intFromPtr(rt.atoms.owner));
    try std.testing.expectEqual(@intFromPtr(rt), @intFromPtr(rt.classes.owner));
    try std.testing.expectEqual(@intFromPtr(&rt.atoms), @intFromPtr(rt.classes.atoms));
    try std.testing.expectEqual(@intFromPtr(rt), @intFromPtr(rt.shapes.runtime));
    try std.testing.expectEqual(@intFromPtr(rt), @intFromPtr(rt.shapes.runtime));
    try std.testing.expectEqual(@intFromPtr(&rt.gc), @intFromPtr(rt.shapes.gc_registry));
    try std.testing.expectEqual(@intFromPtr(rt), @intFromPtr(rt.nativeAllocator().ptr));
    try std.testing.expectEqual(@intFromPtr(rt), @intFromPtr(rt.gc.runtime));
    try std.testing.expectEqual(@intFromPtr(&rt.gc.cell_storage), @intFromPtr(&rt.gc.runtime.gc.cell_storage));
    try std.testing.expectEqual(@intFromPtr(&rt.gc.block_heap), @intFromPtr(rt.gc.cell_storage.block_heap.?));
    try std.testing.expectEqual(@intFromPtr(&rt.gc.nursery), @intFromPtr(rt.gc.cell_storage.nursery.?));
    const native_bytes = try mem_ops.alloc(rt, u8, 24);
    defer mem_ops.free(rt, u8, native_bytes);
    try std.testing.expectEqual(@intFromPtr(&rt.gc.cell_storage), @intFromPtr(&rt.gc.runtime.gc.cell_storage));
    try std.testing.expectEqual(@intFromPtr(&rt.gc.block_heap), @intFromPtr(rt.gc.address_registry.block_heap.?));
    try std.testing.expectEqual(@intFromPtr(rt), @intFromPtr(rt.gc.heap_budget.owner_ctx.?));
    try std.testing.expectEqual(@intFromPtr(rt), @intFromPtr(rt.gc.heap_budget.retry_ctx.?));
    try std.testing.expect(rt.gc.nonblock_objects != null);
    try std.testing.expect(rt.gc.cell_storage.slab.arena_observer != null);
    try std.testing.expectEqual(@intFromPtr(rt.hooks.materialize_context_global), @intFromPtr(rt.materialize_context_global_cb.?));
    try std.testing.expectEqual(rt.hooks.standard_global_own_property_capacity, rt.standardGlobalOwnPropertyCapacity());
}

test "runtime construction failure rolls back each stage and keeps self references" {
    defer core.gc.Registry.fail_nonblock_authority_for_test = false;
    defer core.runtime.setRuntimeConstructionFailpointForTest(.none);
    const baseline = core.gc.Registry.nonblock_authorities_live_for_test;

    const stages = [_]core.runtime.RuntimeConstructionFailpoint{
        .after_object_cells,
        .after_class_table,
        .after_shapes,
    };
    core.gc.Registry.fail_nonblock_authority_for_test = true;
    try std.testing.expectError(error.OutOfMemory, core.JSRuntime.create(.{ .allocator = std.testing.allocator }));
    try std.testing.expectEqual(baseline, core.gc.Registry.nonblock_authorities_live_for_test);
    for (stages) |stage| {
        core.runtime.setRuntimeConstructionFailpointForTest(stage);
        try std.testing.expectError(error.OutOfMemory, core.JSRuntime.create(.{ .allocator = std.testing.allocator }));
        try std.testing.expectEqual(baseline, core.gc.Registry.nonblock_authorities_live_for_test);
    }

    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    errdefer rt.destroy();
    const other = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    errdefer other.destroy();
    try std.testing.expectEqual(@intFromPtr(rt.hooks), @intFromPtr(other.hooks));
    try std.testing.expectEqual(baseline + 2, core.gc.Registry.nonblock_authorities_live_for_test);
    try expectRuntimeSelfReferences(rt);
    try expectRuntimeSelfReferences(other);
    other.destroy();
    rt.destroy();
    try std.testing.expectEqual(baseline, core.gc.Registry.nonblock_authorities_live_for_test);
}

test "runtime tryDestroy rejects a non-owner thread" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    const other = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer other.destroy();
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
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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
    try std.testing.expectEqual(first, rt.contextForGlobalIncludingConstructing(second_global).?);
}

test "runtime termination crosses threads and idle recovery permits new execution" {
    const rt = try zjs.Runtime.create(.{ .allocator = std.testing.allocator });
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
    rt.call_depth = 1;
    try std.testing.expectError(error.RuntimeBusy, rt.cancelTerminateExecution());
    rt.call_depth = 0;
    try rt.cancelTerminateExecution();
}

test "class registration reserves ids across allocation reentry and failure" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    const Probe = struct {
        rt: *core.JSRuntime,
        first: ?core.class.Binding = null,
        last: ?core.class.Binding = null,
        failure: ?anyerror = null,
        fn allocate(raw: ?*anyopaque, _: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.rt.gc.heap_budget.probe = null;
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
    rt.gc.heap_budget.probe = Probe.allocate;
    rt.gc.heap_budget.probe_ctx = &probe;
    defer {
        rt.gc.heap_budget.probe = null;
        rt.gc.heap_budget.probe_ctx = null;
    }
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
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
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

const MicrotaskContractProbe = struct {
    ran: usize = 0,
    reported: usize = 0,
    fail_handler: bool = false,
    reentry_rejected: bool = false,

    fn fail(ctx: *core.JSContext, _: []const core.JSValue) core.JSValue {
        return ctx.throwValue(core.JSValue.int32(73));
    }

    fn succeed(ctx: *core.JSContext, _: []const core.JSValue) core.JSValue {
        const ptr: *@This() = @ptrCast(@alignCast(ctx.runtime.microtasks.userdata.?));
        ptr.ran += 1;
        return core.JSValue.undefinedValue();
    }

    fn report(rt: *core.JSRuntime, value: core.JSValue, data: ?*anyopaque) core.errors.HostError!void {
        const self: *@This() = @ptrCast(@alignCast(data.?));
        self.reported += 1;
        if (value.asNumber().? != 73) return error.SystemError;
        rt.runMicrotasks() catch |err| {
            if (err != error.MicrotaskReentry) return err;
            self.reentry_rejected = true;
        };
        if (self.fail_handler) return error.SystemError;
    }

    fn enqueueSuccess(self: *@This(), ctx: *core.JSContext) !void {
        ctx.runtime.microtasks.userdata = self;
        try ctx.runtime.job_queue.enqueueFunc(ctx, succeed, &.{});
    }
};

test "microtask checkpoint explicit failure preserves tail and handler failure remains visible" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator, .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    var probe: MicrotaskContractProbe = .{};
    try rt.job_queue.enqueueFunc(ctx.core, MicrotaskContractProbe.fail, &.{});
    try probe.enqueueSuccess(ctx.core);
    try std.testing.expectError(error.JSException, rt.runMicrotasks());
    try std.testing.expectEqual(@as(usize, 0), probe.ran);
    try std.testing.expect(rt.job_queue.hasJobs());
    try std.testing.expectEqual(@as(f64, 73), ctx.takeException().asNumber().?);
    try rt.runMicrotasks();
    try std.testing.expectEqual(@as(usize, 1), probe.ran);

    rt.setMicrotaskExceptionHandler(MicrotaskContractProbe.report, &probe);
    try rt.job_queue.enqueueFunc(ctx.core, MicrotaskContractProbe.fail, &.{});
    try probe.enqueueSuccess(ctx.core);
    try rt.runMicrotasks();
    try std.testing.expectEqual(@as(usize, 2), probe.ran);
    try std.testing.expectEqual(@as(usize, 1), probe.reported);
    try std.testing.expect(probe.reentry_rejected);
    try std.testing.expect(!ctx.hasException());

    probe.fail_handler = true;
    try rt.job_queue.enqueueFunc(ctx.core, MicrotaskContractProbe.fail, &.{});
    try probe.enqueueSuccess(ctx.core);
    try std.testing.expectError(error.SystemError, rt.runMicrotasks());
    try std.testing.expect(rt.job_queue.hasJobs());
    try std.testing.expectEqual(@as(usize, 2), probe.ran);
    try std.testing.expectEqual(@as(f64, 73), ctx.takeException().asNumber().?);
    probe.fail_handler = false;
    try rt.runMicrotasks();
    try std.testing.expectEqual(@as(usize, 3), probe.ran);
}

test "microtask checkpoint explicit and nested scoped policies defer automatic eval drain" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator, .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    _ = try ctx.eval("globalThis.order = 0; Promise.resolve().then(() => { order = 1; });", .{});
    try std.testing.expectEqual(@as(f64, 0), (try ctx.eval("order", .{})).asNumber().?);
    try rt.runMicrotasks();
    try std.testing.expectEqual(@as(f64, 1), (try ctx.eval("order", .{})).asNumber().?);

    rt.microtasks.policy = .scoped;
    var outer = try rt.enterMicrotaskScope();
    var inner = try rt.enterMicrotaskScope();
    _ = try ctx.eval("Promise.resolve().then(() => { order = 2; });", .{});
    try rt.runMicrotasks();
    try std.testing.expectEqual(@as(f64, 1), (try ctx.eval("order", .{})).asNumber().?);
    try std.testing.expectError(error.InvalidMicrotaskScope, outer.finish());
    try inner.finish();
    try std.testing.expectEqual(@as(f64, 1), (try ctx.eval("order", .{})).asNumber().?);
    try outer.finish();
    try std.testing.expectEqual(@as(f64, 2), (try ctx.eval("order", .{})).asNumber().?);
    try std.testing.expectError(error.InvalidMicrotaskScope, outer.finish());
}

test "microtask checkpoint termination discards old tasks and recovery accepts new ones" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator, .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    var probe: MicrotaskContractProbe = .{};
    try probe.enqueueSuccess(ctx.core);
    rt.terminateExecution();
    try std.testing.expectError(error.Interrupted, rt.runMicrotasks());
    try std.testing.expect(!rt.job_queue.hasJobs());
    try std.testing.expectEqual(@as(usize, 0), probe.ran);
    try rt.cancelTerminateExecution();
    try probe.enqueueSuccess(ctx.core);
    try rt.runMicrotasks();
    try std.testing.expectEqual(@as(usize, 1), probe.ran);
}

test "microtask checkpoint roots notified exception through precise collection" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator, .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const Probe = struct {
        observed: bool = false,
        fn fail(context: *core.JSContext, args: []const core.JSValue) core.JSValue {
            return context.throwValue(args[0]);
        }
        fn report(runtime: *core.JSRuntime, value: core.JSValue, raw: ?*anyopaque) core.errors.HostError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = runtime.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only) catch return error.SystemError;
            const object = core.Object.expect(value) catch return error.SystemError;
            if (!runtime.ownsObject(object)) return error.SystemError;
            self.observed = true;
        }
    };
    var probe: Probe = .{};
    rt.setMicrotaskExceptionHandler(Probe.report, &probe);
    try rt.job_queue.enqueueFunc(ctx.core, Probe.fail, &.{try ctx.createObject()});
    try rt.runMicrotasks();
    try std.testing.expect(probe.observed);
    try std.testing.expect(!ctx.hasException());
}

test "microtask checkpoint nested entry is noop and newly queued tasks run before completion" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator, .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const Probe = struct {
        order: usize = 0,
        fn first(context: *core.JSContext, _: []const core.JSValue) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(context.runtime.microtasks.userdata.?));
            context.runtime.runMicrotasks() catch return context.throwValue(core.JSValue.int32(-1));
            if (self.order != 0) return context.throwValue(core.JSValue.int32(-2));
            self.order = 1;
            context.runtime.job_queue.enqueueFunc(context, last, &.{}) catch return context.throwValue(core.JSValue.int32(-3));
            return core.JSValue.undefinedValue();
        }
        fn last(context: *core.JSContext, _: []const core.JSValue) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(context.runtime.microtasks.userdata.?));
            if (self.order != 1) return context.throwValue(core.JSValue.int32(-4));
            self.order = 2;
            return core.JSValue.undefinedValue();
        }
    };
    var probe: Probe = .{};
    rt.microtasks.userdata = &probe;
    try rt.job_queue.enqueueFunc(ctx.core, Probe.first, &.{});
    try rt.runMicrotasks();
    try std.testing.expectEqual(@as(usize, 2), probe.order);
    try std.testing.expect(!rt.job_queue.hasJobs());
}

test "microtask checkpoint termination inside a native job discards tail before recovery" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator, .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const Stop = struct {
        fn run(context: *core.JSContext, _: []const core.JSValue) core.JSValue {
            context.runtime.terminateExecution();
            return core.JSValue.undefinedValue();
        }
    };
    var probe: MicrotaskContractProbe = .{};
    try rt.job_queue.enqueueFunc(ctx.core, Stop.run, &.{});
    try probe.enqueueSuccess(ctx.core);
    try std.testing.expectError(error.Interrupted, rt.runMicrotasks());
    try std.testing.expect(!rt.job_queue.hasJobs());
    try std.testing.expectEqual(@as(usize, 0), probe.ran);
    try rt.cancelTerminateExecution();
    try probe.enqueueSuccess(ctx.core);
    try rt.runMicrotasks();
    try std.testing.expectEqual(@as(usize, 1), probe.ran);
}

test "microtask checkpoint WeakRef kept-alive spans jobs and clears only on completion" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator, .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const Probe = struct {
        object: ?*core.Object = null,
        observed: bool = false,
        fn keep(context: *core.JSContext, args: []const core.JSValue) core.JSValue {
            context.runtime.keepAliveWeakRefTarget(args[0]);
            return core.JSValue.undefinedValue();
        }
        fn collect(context: *core.JSContext, _: []const core.JSValue) core.JSValue {
            const self: *@This() = @ptrCast(@alignCast(context.runtime.microtasks.userdata.?));
            _ = context.runtime.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only) catch return context.throwValue(core.JSValue.int32(-1));
            self.observed = context.runtime.ownsObject(self.object.?);
            return core.JSValue.undefinedValue();
        }
    };
    var probe: Probe = .{ .object = try core.Object.expect(try ctx.createObject()) };
    rt.microtasks.userdata = &probe;
    try rt.job_queue.enqueueFunc(ctx.core, Probe.keep, &.{probe.object.?.value()});
    try rt.job_queue.enqueueFunc(ctx.core, Probe.collect, &.{});
    try rt.runMicrotasks();
    try std.testing.expect(probe.observed);
    try std.testing.expectEqual(@as(usize, 0), rt.weakref_kept_alive.items.len);
    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
    try std.testing.expect(!rt.ownsObject(probe.object.?));
}

test "microtask checkpoint auto drains outermost callFunction and newly enqueued jobs" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const callback = try ctx.eval("globalThis.order = ''; (() => { Promise.resolve().then(() => { order += 'a'; Promise.resolve().then(() => { order += 'b'; }); }); return 42; })", .{});
    const result = try ctx.callFunction(callback, &.{}, .{});
    try std.testing.expectEqual(@as(f64, 42), result.asNumber().?);
    try std.testing.expect(!rt.job_queue.hasJobs());
    const ok = try ctx.eval("order === 'ab'", .{});
    try std.testing.expect(ok.as(.boolean).?);
}

test "microtask policy boundaries preserve OOM classification and ordinary exception continuation" {
    const Dispatch = struct {
        fn run(ctx: *zjs.Context, policy: zjs.MicrotaskPolicy) !void {
            switch (policy) {
                .auto => {
                    _ = try ctx.eval("0", .{});
                },
                .explicit => try ctx.core.runtime.runMicrotasks(),
                .scoped => {
                    var scope = try ctx.core.runtime.enterMicrotaskScope();
                    try scope.finish();
                },
            }
        }
        fn oom(ctx: *core.JSContext, _: []const core.JSValue) core.JSValue {
            const rt = ctx.runtime;
            rt.setNativeBytesLimitForTest(0);
            defer rt.setNativeBytesLimitForTest(null);
            const bytes = rt.nativeAllocator().alloc(u8, 16) catch {
                const result = ctx.throwValue(ctx.preallocated_oom_error.?);
                ctx.markExceptionOutOfMemory();
                return result;
            };
            rt.nativeAllocator().free(bytes);
            return core.JSValue.undefinedValue();
        }
    };
    inline for (.{ zjs.MicrotaskPolicy.auto, .explicit, .scoped }) |policy| {
        const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator, .microtask_policy = policy });
        defer rt.destroy();
        const ctx = try zjs.Context.create(rt, .{});
        defer ctx.destroy();
        var probe: MicrotaskContractProbe = .{};
        rt.setMicrotaskExceptionHandler(MicrotaskContractProbe.report, &probe);
        try rt.job_queue.enqueueFunc(ctx.core, Dispatch.oom, &.{});
        try probe.enqueueSuccess(ctx.core);
        try std.testing.expectError(error.OutOfMemory, Dispatch.run(ctx, policy));
        try std.testing.expectEqual(@as(usize, 0), probe.reported);
        try std.testing.expectEqual(@as(usize, 0), probe.ran);
        try std.testing.expect(rt.job_queue.hasJobs());
        _ = ctx.takeException();
        try Dispatch.run(ctx, policy);
        try std.testing.expectEqual(@as(usize, 1), probe.ran);
        try rt.job_queue.enqueueFunc(ctx.core, MicrotaskContractProbe.fail, &.{});
        try probe.enqueueSuccess(ctx.core);
        try Dispatch.run(ctx, policy);
        try std.testing.expectEqual(@as(usize, 1), probe.reported);
        try std.testing.expectEqual(@as(usize, 2), probe.ran);
    }
}

test "dynamic import job wrapper propagates checkpoint exceptions and handler failures" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator, .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    var state = zjs.exec.module_graph.DynamicImportState{
        .runtime = rt,
        .output = null,
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .max_source_size = 4096,
    };
    defer state.deinit();
    var probe: MicrotaskContractProbe = .{};
    try rt.job_queue.enqueueFunc(ctx.core, MicrotaskContractProbe.fail, &.{});
    try probe.enqueueSuccess(ctx.core);
    try std.testing.expectError(error.JSException, state.runJobs(ctx.core));
    try std.testing.expectEqual(@as(usize, 0), probe.ran);
    try std.testing.expectEqual(@as(f64, 73), ctx.takeException().asNumber().?);
    try state.runJobs(ctx.core);
    try std.testing.expectEqual(@as(usize, 1), probe.ran);

    rt.setMicrotaskExceptionHandler(MicrotaskContractProbe.report, &probe);
    try rt.job_queue.enqueueFunc(ctx.core, MicrotaskContractProbe.fail, &.{});
    try probe.enqueueSuccess(ctx.core);
    try state.runJobs(ctx.core);
    try std.testing.expectEqual(@as(usize, 1), probe.reported);
    try std.testing.expectEqual(@as(usize, 2), probe.ran);
    try std.testing.expect(probe.reentry_rejected);

    probe.fail_handler = true;
    try rt.job_queue.enqueueFunc(ctx.core, MicrotaskContractProbe.fail, &.{});
    try probe.enqueueSuccess(ctx.core);
    try std.testing.expectError(error.SystemError, state.runJobs(ctx.core));
    try std.testing.expect(rt.job_queue.hasJobs());
    try std.testing.expectEqual(@as(usize, 2), probe.ran);
    try std.testing.expectEqual(@as(f64, 73), ctx.takeException().asNumber().?);
    probe.fail_handler = false;
    try state.runJobs(ctx.core);
    try std.testing.expectEqual(@as(usize, 3), probe.ran);
}

test "runtime review module scheduler rejects termination and preserves nested checkpoint ordering" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator, .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    var state = zjs.exec.module_graph.DynamicImportState{
        .runtime = rt,
        .output = null,
        .io = std.testing.io,
        .allocator = std.testing.allocator,
        .max_source_size = 4096,
    };
    defer state.deinit();
    const Probe = struct {
        phase: usize = 0,
        observed: usize = 0,
        fn first(c: *core.JSContext, _: []const core.JSValue) core.JSValue {
            const p: *@This() = @ptrCast(@alignCast(c.runtime.microtasks.userdata.?));
            p.phase = 1;
            c.runtime.runMicrotasks() catch return c.throwValue(core.JSValue.int32(90));
            p.phase = 2;
            return core.JSValue.undefinedValue();
        }
        fn tail(c: *core.JSContext, _: []const core.JSValue) core.JSValue {
            const p: *@This() = @ptrCast(@alignCast(c.runtime.microtasks.userdata.?));
            p.observed = p.phase;
            return core.JSValue.undefinedValue();
        }
    };
    var probe: Probe = .{};
    rt.microtasks.userdata = &probe;
    try rt.job_queue.enqueueFunc(ctx.core, Probe.first, &.{});
    try rt.job_queue.enqueueFunc(ctx.core, Probe.tail, &.{});
    try state.runJobs(ctx.core);
    try std.testing.expectEqual(@as(usize, 2), probe.observed);

    probe.observed = 0;
    try rt.job_queue.enqueueFunc(ctx.core, Probe.tail, &.{});
    var scope = try rt.enterMicrotaskScope();
    try state.runJobs(ctx.core);
    try std.testing.expectEqual(@as(usize, 0), probe.observed);
    try std.testing.expect(rt.job_queue.hasJobs());
    try scope.finish();
    try state.runJobs(ctx.core);
    try std.testing.expectEqual(@as(usize, 2), probe.observed);

    probe.observed = 0;
    try rt.job_queue.enqueueFunc(ctx.core, Probe.tail, &.{});
    rt.terminateExecution();
    try std.testing.expectError(error.Interrupted, state.runJobs(ctx.core));
    try std.testing.expectEqual(@as(usize, 0), probe.observed);
    try std.testing.expect(!rt.job_queue.hasJobs());
    try rt.cancelTerminateExecution();
}

test "runtime review handler installed OOM keeps its failure classification" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator, .microtask_policy = .explicit });
    defer rt.destroy();
    const ctx = try zjs.Context.create(rt, .{});
    defer ctx.destroy();
    const Handler = struct {
        fn report(r: *core.JSRuntime, _: core.JSValue, _: ?*anyopaque) core.errors.HostError!void {
            @import("../src/core/exception.zig").install(r, core.JSValue.int32(99));
            r.current_exception_out_of_memory = true;
        }
    };
    rt.setMicrotaskExceptionHandler(Handler.report, null);
    try rt.job_queue.enqueueFunc(ctx.core, MicrotaskContractProbe.fail, &.{});
    try std.testing.expectError(error.OutOfMemory, rt.runMicrotasks());
    try std.testing.expectEqual(@as(f64, 99), ctx.takeException().asNumber().?);
}

const BufferCollectionProbe = struct {
    runtime: *core.JSRuntime,
    source_to_clear: []core.JSValue = &.{},
    calls: usize = 0,
    failure: ?core.gc.CollectionError = null,

    fn trigger(raw: ?*anyopaque, _: usize) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        // The copy is complete when provider growth allocates. Its source
        // may now change through a reentrant owner, without changing the copy.
        if (self.calls == 2) @memset(self.source_to_clear, core.JSValue.undefinedValue());
        _ = self.runtime.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only) catch |err| {
            self.failure = err;
        };
    }
};

fn traceEmptyBufferTestProvider(_: *anyopaque, _: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {}

test "ValueRootBuffer protects copy and provider growth then owns liveness" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    // Occupy the inline provider slot so registration must allocate too.
    const dummy = core.runtime.RootProvider{ .context = rt, .trace = traceEmptyBufferTestProvider };
    try rt.registerRootProvider(dummy);
    defer rt.unregisterRootProvider(dummy);
    try std.testing.expectEqual(rt.roots.root_providers_capacity, rt.roots.root_providers.len);
    const source = try std.testing.allocator.alloc(core.JSValue, 1);
    defer std.testing.allocator.free(source);
    const first_id = try rt.atoms.newValueSymbol("root-buffer-first");
    source[0] = try rt.takeSymbolValue(first_id);
    var probe = BufferCollectionProbe{ .runtime = rt, .source_to_clear = source };
    const epoch = rt.gc.collection_epoch;
    rt.gc.heap_budget.probe = BufferCollectionProbe.trigger;
    rt.gc.heap_budget.probe_ctx = &probe;
    defer {
        rt.gc.heap_budget.probe = null;
        rt.gc.heap_budget.probe_ctx = null;
    }
    var first = try core.runtime.ValueRootBuffer.initCopy(rt, source);
    defer first.deinit();
    rt.gc.heap_budget.probe = null;
    rt.gc.heap_budget.probe_ctx = null;
    if (probe.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expectEqual(epoch + 2, rt.gc.collection_epoch);
    try std.testing.expect(rt.atoms.name(first_id) != null);
    try std.testing.expect(rt.active_value_roots == null);
    source[0] = core.JSValue.undefinedValue();
    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
    try std.testing.expect(rt.atoms.name(first_id) != null);
    try std.testing.expect(!first.values()[0].is(.undefined_value));

    const second_id = try rt.atoms.newValueSymbol("root-buffer-second");
    source[0] = try rt.takeSymbolValue(second_id);
    var second = try core.runtime.ValueRootBuffer.initCopy(rt, source);
    defer second.deinit();
    source[0] = core.JSValue.undefinedValue();
    // Non-LIFO removal must leave the other provider intact.
    first.deinit();
    first.deinit();
    try std.testing.expectEqual(@as(usize, 0), first.values().len);
    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
    try std.testing.expect(rt.atoms.name(first_id) == null);
    try std.testing.expect(rt.atoms.name(second_id) != null);
    second.deinit();
    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
    try std.testing.expect(rt.atoms.name(second_id) == null);
    try std.testing.expectEqual(@as(usize, 0), rt.roots.value_root_buffers);
}

test "ValueRootBuffer allocation failures restore roots and storage" {
    for (0..2) |fail_offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.JSRuntime.create(.{ .allocator = failing.allocator() });
        defer rt.destroy();
        const dummy = core.runtime.RootProvider{ .context = rt, .trace = traceEmptyBufferTestProvider };
        try rt.registerRootProvider(dummy);
        defer rt.unregisterRootProvider(dummy);
        const slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &.{} }};
        var outer = core.runtime.ValueRootFrame{ .slices = &slices };
        outer.activate(rt);
        defer outer.deactivate(rt);
        const live_bytes = failing.allocated_bytes - failing.freed_bytes;
        failing.fail_index = failing.alloc_index + fail_offset;
        try std.testing.expectError(error.OutOfMemory, core.runtime.ValueRootBuffer.initCopy(rt, &.{core.JSValue.int32(42)}));
        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(live_bytes, failing.allocated_bytes - failing.freed_bytes);
        try std.testing.expectEqual(@as(usize, 1), rt.roots.root_providers.len);
        try std.testing.expectEqual(@as(usize, 0), rt.roots.value_root_buffers);
        try std.testing.expect(rt.active_value_roots == &outer);
        var retry = try core.runtime.ValueRootBuffer.initCopy(rt, &.{core.JSValue.int32(42)});
        defer retry.deinit();
        try std.testing.expect(retry.values()[0].same(core.JSValue.int32(42)));
    }
}

test "ValueRootBuffer empty needs no allocation or registration" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const rt = try core.JSRuntime.create(.{ .allocator = failing.allocator() });
    defer rt.destroy();
    failing.fail_index = failing.alloc_index;
    var buffer = try core.runtime.ValueRootBuffer.initCopy(rt, &.{});
    buffer.deinit();
    buffer.deinit();
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), buffer.values().len);
    try std.testing.expectEqual(@as(usize, 0), rt.roots.value_root_buffers);
    failing.fail_index = std.math.maxInt(usize);
}

test "ValueRootBuffer teardown guard" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    var buffer = try core.runtime.ValueRootBuffer.initCopy(rt, &.{core.JSValue.int32(1)});
    defer buffer.deinit();
    // Run through zig build test with this filter to exercise the real
    // Runtime.destroy guard, rather than a test-only copy of its predicate.
    if (std.c.getenv("ZJS_VALUE_ROOT_BUFFER_INJECT")) |raw| {
        if (std.mem.eql(u8, std.mem.span(raw), "1")) rt.destroy();
    }
}

test "ValueRootBuffer registration survives allocation probe reentry" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    const dummy = core.runtime.RootProvider{ .context = rt, .trace = traceEmptyBufferTestProvider };
    try rt.registerRootProvider(dummy);
    defer rt.unregisterRootProvider(dummy);
    const Probe = struct {
        runtime: *core.JSRuntime,
        calls: usize = 0,
        nested: [3]core.runtime.ValueRootBuffer = @splat(.{}),
        failure: ?std.mem.Allocator.Error = null,

        fn trigger(raw: ?*anyopaque, _: usize) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            // Reenter specifically while the outer provider table is growing.
            if (self.calls != 2) return;
            for (&self.nested) |*buffer| {
                buffer.* = core.runtime.ValueRootBuffer.initCopy(self.runtime, &.{core.JSValue.int32(7)}) catch |err| {
                    self.failure = err;
                    return;
                };
            }
        }
    };
    var probe = Probe{ .runtime = rt };
    defer for (&probe.nested) |*buffer| buffer.deinit();
    rt.gc.heap_budget.probe = Probe.trigger;
    rt.gc.heap_budget.probe_ctx = &probe;
    defer {
        rt.gc.heap_budget.probe = null;
        rt.gc.heap_budget.probe_ctx = null;
    }
    var outer = try core.runtime.ValueRootBuffer.initCopy(rt, &.{core.JSValue.int32(9)});
    defer outer.deinit();
    if (probe.failure) |err| return err;
    try std.testing.expect(probe.calls >= 2);
    try std.testing.expectEqual(@as(usize, 4), rt.roots.value_root_buffers);
    try std.testing.expectEqual(@as(usize, 5), rt.roots.root_providers.len);
    _ = try rt.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
}
