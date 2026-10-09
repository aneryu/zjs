//! Process-level shared TestEngine: one realm per test binary.
//!
//! Each `test "X" {}` block traditionally does:
//!
//!     var js = try helpers.TestEngine.init(std.testing.allocator);
//!     defer js.deinit();
//!
//! That pays ~195us (Debug) / ~50us (ReleaseSafe) per test for
//! `installHostGlobals`, which dominates the per-test wall time for
//! tests whose actual eval body is small. The shared-engine pattern
//! builds the Engine once per test BINARY (using a stable allocator
//! independent of `std.testing.allocator`, which is reset between
//! tests), and resets only the per-eval mutable state in between tests:
//!
//!     const js = helpers.sharedTestEngine();
//!     defer helpers.endSharedTest();
//!
//! `endSharedTest` clears the pending exception slot, drains the
//! job queue, nulls out `context.lexicals` (dropping the previous
//! test's let / const declarations), and then rebuilds the global's
//! property array and shape layout from the baseline snapshot taken
//! after `installHostGlobals`. It then compares `globalThis.[[Prototype]]`
//! and the own properties of realm prototypes with a baseline. A mismatch
//! panics in the test that left the realm dirty; the gate does not write
//! the old state back. Tests that mutate built-in objects
//! (e.g. `Promise.resolve = ...`) or rely on freshly built closures
//! referencing the previous test's eval scope still need a fresh
//! `TestEngine.init` per call.

const std = @import("std");
const zjs = @import("zjs");
const core = zjs.core;
const exec = zjs.exec;
const test_engine = @import("test_engine.zig");
const gc = @import("gc.zig");

const TestEngine = test_engine.TestEngine;

pub fn expectPrints(source: []const u8, expected: []const u8) !void {
    const js = sharedTestEngine();
    defer endSharedTest();
    try expectPrintsOn(js, source, expected);
}

/// Same check as `expectPrints`, on a runtime this call owns.
/// Use it when the script has to leave a builtin dirty: `delete` of a
/// property that did not exist keeps a shape tombstone, and the shared
/// realm cannot be put back.
pub fn expectPrintsFresh(source: []const u8, expected: []const u8) !void {
    var js = try test_engine.TestEngine.init(std.testing.allocator);
    defer js.deinit();
    try expectPrintsOn(&js, source, expected);
}

fn expectPrintsOn(js: *TestEngine, source: []const u8, expected: []const u8) !void {
    var output_buffer: [8192]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOutput(source, &output);

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings(expected, output.buffered());
}

/// `expectPrints` for a TypeScript script (`f<T>(x)` and `x!` take their
/// TypeScript meaning only in `.ts` sources).
pub fn expectPrintsTs(source: []const u8, expected: []const u8) !void {
    const js = sharedTestEngine();
    defer endSharedTest();

    var output_buffer: [8192]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const result = try js.evalWithOptions(source, .{ .output = &output, .mode = .script, .filename = "test.ts" });

    try std.testing.expect(result.is(.undefined_value));
    try std.testing.expectEqualStrings(expected, output.buffered());
}

var shared_engine_storage: ?TestEngine = null;
// A Slot.dup of a VARREF retains the same mutable cell. Keep its original
// contents separately so deleting a baseline global cannot corrupt the
// snapshot by parking that shared cell at UNINITIALIZED.
const SharedBaselineVarRef = struct {
    value: core.JSValue,
    is_lexical: bool,
    is_const: bool,
    is_deletable: bool,
};
const Baseline = struct {
    property_count: usize = 0,
    shape_prop_count: usize = 0,
    shape_hash: u32 = 0,
    shape_deleted_count: usize = 0,
    properties: ?[]core.property.Entry = null,
    shape_props: ?[]core.shape.Property = null,
    var_refs: ?[]?SharedBaselineVarRef = null,
    allocation_count: usize = 0,
    allocated_bytes: usize = 0,
    module_count: usize = 0,
};
var shared_engine_baseline: Baseline = .{};
// Fresh three-pass census after Q4b: 814 warmed zero-module observations had
// allocation-count p95 0 and max 7. One extra allocation is the safety margin.
const shared_engine_allocation_tolerance: usize = 8;
var shared_engine_teardown_registered: bool = false;
// `[[Prototype]]` of the shared global, taken once the realm is built.
// `endSharedTest` compares it and panics on a mismatch. It does not
// write the pointer back: restoring here would hide the test that
// left the realm dirty.
var isolation_global_prototype: ?*core.Object = null;
var isolation_global_prototype_ready: bool = false;

fn captureGlobalPrototype(eng: *TestEngine) void {
    const global = eng.context.global orelse return;
    isolation_global_prototype = global.getPrototype();
    isolation_global_prototype_ready = true;
}

fn checkGlobalPrototype(eng: *TestEngine) void {
    if (!isolation_global_prototype_ready) return;
    const global = eng.context.global orelse return;
    if (global.getPrototype() == isolation_global_prototype) return;
    std.debug.panic(
        "shared-test isolation gate: test=\"{s}\" changed globalThis.[[Prototype]]",
        .{runnerTestName()},
    );
}

// Own-property fingerprints of realm prototypes. Relocatable JSValues and
// object pointers live in slices the shared runtime traces, so a copying
// collection rewrites the baseline before the next bit compare. `a`/`b`
// still hold the non-relocatable residue (auto_init id, var_ref cell
// address). The checker never dereferences a stored old bit pattern.
const isolation_object_cap = 160;
const isolation_label_cap = 96;
const isolation_root_none: u32 = std.math.maxInt(u32);
const IsolationSlot = struct {
    atom: core.atom.Atom,
    flags: u6,
    a: u64,
    b: u64,
    value_root: u32 = isolation_root_none,
    ptr_a: u32 = isolation_root_none,
    ptr_b: u32 = isolation_root_none,
};
const IsolationObject = struct {
    object_root: u32,
    proto_root: u32,
    shape_identity: u64,
    prop_count: u32,
    slots: []IsolationSlot,
    label: [isolation_label_cap]u8,
    label_len: u8,
};
const IntrinsicVisit = *const fn (*core.Object, []const u8) void;
const CachedPrototype = struct {
    slot: core.context.RealmValueSlot,
    label: []const u8,
};
const cached_prototypes = [_]CachedPrototype{
    .{ .slot = .object_prototype, .label = "Object.prototype" },
    .{ .slot = .array_prototype, .label = "Array.prototype" },
    .{ .slot = .string_prototype, .label = "String.prototype" },
    .{ .slot = .number_prototype, .label = "Number.prototype" },
    .{ .slot = .boolean_prototype, .label = "Boolean.prototype" },
    .{ .slot = .bigint_prototype, .label = "BigInt.prototype" },
    .{ .slot = .symbol_prototype, .label = "Symbol.prototype" },
    .{ .slot = .async_function_prototype, .label = "AsyncFunction.prototype" },
    .{ .slot = .generator_prototype, .label = "Generator.prototype" },
    .{ .slot = .async_iterator_prototype, .label = "AsyncIterator.prototype" },
    .{ .slot = .async_generator_prototype, .label = "AsyncGenerator.prototype" },
    .{ .slot = .generator_function_prototype, .label = "GeneratorFunction.prototype" },
    .{ .slot = .async_generator_function_prototype, .label = "AsyncGeneratorFunction.prototype" },
    .{ .slot = .iterator_helper_prototype, .label = "IteratorHelper.prototype" },
    .{ .slot = .wrap_for_valid_iterator_prototype, .label = "WrapForValidIterator.prototype" },
    .{ .slot = .callsite_prototype, .label = "CallSite.prototype" },
};
const native_error_labels = [_][]const u8{
    "Error.prototype",
    "EvalError.prototype",
    "RangeError.prototype",
    "ReferenceError.prototype",
    "SyntaxError.prototype",
    "TypeError.prototype",
    "URIError.prototype",
    "InternalError.prototype",
    "AggregateError.prototype",
    "SuppressedError.prototype",
};
var isolation_objects: [isolation_object_cap]IsolationObject = undefined;
var isolation_object_count: usize = 0;
var isolation_objects_ready: bool = false;
var isolation_values: []core.JSValue = &.{};
var isolation_value_len: usize = 0;
var isolation_ptrs: []?*core.Object = &.{};
var isolation_ptr_len: usize = 0;
var isolation_root_token: u8 = 0;
var isolation_roots_registered: bool = false;

comptime {
    std.debug.assert(native_error_labels.len == @intFromEnum(core.error_names.NativeErrorKind.count));
}

fn isolationLabel(watched: *const IsolationObject) []const u8 {
    return watched.label[0..watched.label_len];
}

fn panicChanged(label: []const u8, rt: *core.JSRuntime, atom_id: core.atom.Atom) noreturn {
    if (rt.atoms.name(atom_id)) |spelling| {
        std.debug.panic(
            "shared-test isolation gate: test=\"{s}\" changed {s}.{s}",
            .{ runnerTestName(), label, spelling },
        );
    }
    var buf: [16]u8 = undefined;
    const spelling = if (atom_id.isTaggedInt())
        std.fmt.bufPrint(&buf, "{d}", .{atom_id.toUInt32()}) catch "<?>"
    else if (atom_id == core.atom.null_atom)
        "<deleted>"
    else
        "<shape>";
    std.debug.panic(
        "shared-test isolation gate: test=\"{s}\" changed {s}.{s}",
        .{ runnerTestName(), label, spelling },
    );
}

fn panicPrototype(label: []const u8) noreturn {
    std.debug.panic(
        "shared-test isolation gate: test=\"{s}\" changed {s}.[[Prototype]]",
        .{ runnerTestName(), label },
    );
}

fn fingerprintSlot(object: *core.Object, index: usize) struct { a: u64, b: u64 } {
    const flags = object.propFlagsAt(index);
    if (flags.deleted) return .{ .a = 0, .b = 0 };
    return switch (flags.kind) {
        .data => .{ .a = object.asDataAt(index).?.bits, .b = 0 },
        .accessor => blk: {
            const accessor = object.asAccessorAt(index).?;
            break :blk .{
                .a = if (accessor.getter) |getter| @intFromPtr(getter) else 0,
                .b = if (accessor.setter) |setter| @intFromPtr(setter) else 0,
            };
        },
        .var_ref => blk: {
            const cell = object.asVarRefAt(index).?;
            break :blk .{ .a = @intFromPtr(cell), .b = cell.varRefValue().bits };
        },
        // The realm pointer packed into an auto_init slot is rewritten by a
        // moving collection. The id and the immutable descriptor are not.
        .auto_init => blk: {
            const slot = object.propertyEntry(index).*.slot.auto_init;
            break :blk .{
                .a = @intFromEnum(slot.realm_and_id.id()),
                .b = if (slot.opaque_ptr) |pointer| @intFromPtr(pointer) else 0,
            };
        },
    };
}

fn traceIsolationRoots(_: *anyopaque, visitor: *core.gc_roots.RootVisitor) core.gc_roots.RootTraceError!void {
    if (isolation_value_len != 0) try visitor.values(isolation_values[0..isolation_value_len]);
    for (isolation_ptrs[0..isolation_ptr_len]) |*slot| try visitor.optionalObject(slot);
    if (isolation_global_prototype_ready) try visitor.optionalObject(&isolation_global_prototype);
    if (shared_engine_baseline.properties) |entries| {
        if (shared_engine_baseline.shape_props) |props| {
            const count = @min(entries.len, props.len);
            for (entries[0..count], props[0..count]) |*entry, prop| {
                const flags = core.property.Flags.fromBits(prop.flags);
                if (flags.deleted) continue;
                switch (flags.kind) {
                    .data => try visitor.value(&entry.slot.data),
                    .accessor => {
                        try visitor.optionalObject(&entry.slot.accessor.getter);
                        try visitor.optionalObject(&entry.slot.accessor.setter);
                    },
                    .var_ref, .auto_init => {},
                }
            }
        }
    }
    if (shared_engine_baseline.var_refs) |refs| {
        for (refs) |*stored| {
            if (stored.*) |*state| try visitor.value(&state.value);
        }
    }
}

fn ensureIsolationRoots(rt: *core.JSRuntime) void {
    if (isolation_roots_registered) return;
    rt.registerRootProvider(.{
        .context = @ptrCast(&isolation_root_token),
        .trace = traceIsolationRoots,
    }) catch |err| std.debug.panic("registerRootProvider: {s}", .{@errorName(err)});
    isolation_roots_registered = true;
}

fn releaseIsolationRoots(rt: *core.JSRuntime) void {
    if (isolation_roots_registered) {
        rt.unregisterRootProvider(.{
            .context = @ptrCast(&isolation_root_token),
            .trace = traceIsolationRoots,
        });
        isolation_roots_registered = false;
    }
    if (isolation_values.len != 0) std.heap.page_allocator.free(isolation_values);
    isolation_values = &.{};
    isolation_value_len = 0;
    if (isolation_ptrs.len != 0) std.heap.page_allocator.free(isolation_ptrs);
    isolation_ptrs = &.{};
    isolation_ptr_len = 0;
}

fn pushRoot(comptime T: type, list: *[]T, len: *usize, item: T, empty: T) u32 {
    if (len.* == list.len) {
        const grown = std.heap.page_allocator.realloc(list.*, @max(list.len * 2, 64)) catch |err|
            std.debug.panic("isolation root growth: {s}", .{@errorName(err)});
        @memset(grown[len.*..], empty);
        list.* = grown;
    }
    list.*[len.*] = item;
    len.* += 1;
    return @intCast(len.* - 1);
}

fn pushIsolationValue(value: core.JSValue) u32 {
    return pushRoot(core.JSValue, &isolation_values, &isolation_value_len, value, core.JSValue.undefinedValue());
}

fn pushIsolationPtr(object: ?*core.Object) u32 {
    return pushRoot(?*core.Object, &isolation_ptrs, &isolation_ptr_len, object, null);
}

fn installSlotRoots(object: *core.Object, index: usize, base: *IsolationSlot) void {
    const flags = object.propFlagsAt(index);
    base.flags = flags.bits();
    base.value_root = isolation_root_none;
    base.ptr_a = isolation_root_none;
    base.ptr_b = isolation_root_none;
    base.a = 0;
    base.b = 0;
    if (flags.deleted) return;
    switch (flags.kind) {
        .data => {
            const value = object.asDataAt(index).?;
            base.value_root = pushIsolationValue(value);
            base.a = value.bits;
        },
        .accessor => {
            const accessor = object.asAccessorAt(index).?;
            base.ptr_a = pushIsolationPtr(accessor.getter);
            base.ptr_b = pushIsolationPtr(accessor.setter);
            base.a = if (accessor.getter) |getter| @intFromPtr(getter) else 0;
            base.b = if (accessor.setter) |setter| @intFromPtr(setter) else 0;
        },
        .var_ref => {
            const cell = object.asVarRefAt(index).?;
            const value = cell.varRefValue();
            base.value_root = pushIsolationValue(value);
            base.a = @intFromPtr(cell);
            base.b = value.bits;
        },
        .auto_init => {
            const slot = object.propertyEntry(index).*.slot.auto_init;
            base.a = @intFromEnum(slot.realm_and_id.id());
            base.b = if (slot.opaque_ptr) |pointer| @intFromPtr(pointer) else 0;
        },
    }
}

const SlotBits = struct { a: u64, b: u64 };

fn rootedBaselineBits(base: *const IsolationSlot) SlotBits {
    const flags = core.property.Flags.fromBits(base.flags);
    if (flags.deleted) return .{ .a = 0, .b = 0 };
    var bits: SlotBits = .{ .a = base.a, .b = base.b };
    if (base.value_root != isolation_root_none) {
        const value_bits = isolation_values[base.value_root].bits;
        if (flags.kind == .var_ref) bits.b = value_bits else bits.a = value_bits;
    }
    if (base.ptr_a != isolation_root_none) {
        bits.a = if (isolation_ptrs[base.ptr_a]) |object| @intFromPtr(object) else 0;
    }
    if (base.ptr_b != isolation_root_none) {
        bits.b = if (isolation_ptrs[base.ptr_b]) |object| @intFromPtr(object) else 0;
    }
    return bits;
}

fn isolationObject(watched: *const IsolationObject) *core.Object {
    return isolation_ptrs[watched.object_root] orelse {
        std.debug.panic("shared-test isolation gate: watched object was collected", .{});
    };
}

fn isLegalMaterialization(before: core.property.Flags, after: core.property.Flags) bool {
    if (!before.isAutoInit() or after.deleted) return false;
    if (after.kind != .data and after.kind != .var_ref) return false;
    return before.writable == after.writable and
        before.enumerable == after.enumerable and
        before.configurable == after.configurable;
}

fn formatClassPrototypeLabel(rt: *core.JSRuntime, class_id: core.class.ClassId, buf: []u8) []const u8 {
    if (rt.classes.className(class_id)) |name_atom| {
        if (rt.atoms.name(name_atom)) |spelling| {
            if (std.fmt.bufPrint(buf, "{s}.prototype", .{spelling})) |written| return written else |_| {}
        }
    }
    return std.fmt.bufPrint(buf, "class-{d}.prototype", .{class_id}) catch "class.prototype";
}

fn eachIntrinsic(eng: *TestEngine, visit: IntrinsicVisit) void {
    const ctx = eng.context;
    const global = ctx.global orelse return;
    const class_count = @min(ctx.class_prototypes.len, @as(usize, core.class.ids.init_count));
    var class_index: usize = 0;
    while (class_index < class_count) : (class_index += 1) {
        const class_id: core.class.ClassId = @intCast(class_index);
        const object = ctx.classPrototypeObject(class_id) orelse continue;
        if (object == global) continue;
        var label_buf: [isolation_label_cap]u8 = undefined;
        const label = formatClassPrototypeLabel(eng.runtime, class_id, &label_buf);
        visit(object, label);
    }
    var kind_index: usize = 0;
    while (kind_index < native_error_labels.len) : (kind_index += 1) {
        const kind: core.error_names.NativeErrorKind = @enumFromInt(kind_index);
        const object = ctx.nativeErrorPrototypeObject(kind) orelse continue;
        if (object == global) continue;
        visit(object, native_error_labels[kind_index]);
    }
    for (cached_prototypes) |entry| {
        const stored = ctx.cached_values[@intFromEnum(entry.slot)] orelse continue;
        const object = core.value_semantics.objectFromValue(stored) orelse continue;
        if (object == global) continue;
        visit(object, entry.label);
    }
    if (ctx.cached_function_proto) |object| {
        if (object != global) visit(object, "Function.prototype");
    }
    if (ctx.cached_promise_proto) |object| {
        if (object != global) visit(object, "Promise.prototype");
    }
    var cursor = global.getPrototype();
    var depth: usize = 0;
    while (cursor) |object| {
        if (depth == 16) break;
        var label_buf: [isolation_label_cap]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "proto-chain-{d}", .{depth}) catch "proto-chain";
        if (object != global) visit(object, label);
        cursor = object.getPrototype();
        depth += 1;
    }
}

fn noteObject(object: *core.Object, label: []const u8) void {
    var index: usize = 0;
    while (index < isolation_object_count) : (index += 1) {
        if (isolation_ptrs[isolation_objects[index].object_root] == object) return;
    }
    if (isolation_object_count == isolation_object_cap) {
        std.debug.panic("shared-test isolation gate: prototype table cap {d}", .{isolation_object_cap});
    }
    const slot_count: usize = object.shape_ref.prop_count;
    const slots: []IsolationSlot = if (slot_count == 0) &.{} else mustPageAlloc(IsolationSlot, slot_count);
    var label_buf: [isolation_label_cap]u8 = @splat(0);
    const label_len = @min(label.len, isolation_label_cap);
    @memcpy(label_buf[0..label_len], label[0..label_len]);
    var slot_index: usize = 0;
    while (slot_index < slot_count) : (slot_index += 1) {
        slots[slot_index] = .{ .atom = object.propAtomAt(slot_index), .flags = 0, .a = 0, .b = 0 };
        installSlotRoots(object, slot_index, &slots[slot_index]);
    }
    isolation_objects[isolation_object_count] = .{
        .object_root = pushIsolationPtr(object),
        .proto_root = pushIsolationPtr(object.getPrototype()),
        .shape_identity = object.shape_ref.identity,
        .prop_count = object.shape_ref.prop_count,
        .slots = slots,
        .label = label_buf,
        .label_len = @intCast(label_len),
    };
    isolation_object_count += 1;
}

fn visitNote(object: *core.Object, label: []const u8) void {
    noteObject(object, label);
}

fn materializeOwnAutoInits(object: *core.Object) void {
    // A few hundred builtin methods. Restart after each one: materializing
    // can append or rewrite the shape under us.
    var guard: usize = 0;
    while (guard < 4096) : (guard += 1) {
        const count = object.shape_ref.prop_count;
        var index: usize = 0;
        var pending: ?core.atom.Atom = null;
        while (index < count) : (index += 1) {
            if (!object.propFlagsAt(index).isAutoInit()) continue;
            pending = object.propAtomAt(index);
            break;
        }
        const key = pending orelse return;
        _ = object.getProperty(key) catch |err|
            std.debug.panic("isolation preheat: {s}", .{@errorName(err)});
    }
    std.debug.panic("isolation preheat: auto_init did not settle", .{});
}

fn visitMaterialize(object: *core.Object, _: []const u8) void {
    materializeOwnAutoInits(object);
}

fn mustPublish(object: anytype) void {
    _ = object catch |err| std.debug.panic("isolation preheat: {s}", .{@errorName(err)});
}

/// Publish lazy prototypes, then force every watched auto_init slot to its
/// real builtin value. A later `RegExp.prototype.exec = function(){}` is
/// then a bit change. A slot that is still auto_init at check time may
/// become data/var_ref with the same attributes; that update is written
/// into the baseline and is not a failure. Prototypes that do not exist
/// yet are adopted on the first `endSharedTest` that sees them, so a test
/// which both creates and mutates one of those before that snapshot is
/// not caught.
fn publishLazyIntrinsicPrototypes(eng: *TestEngine) void {
    const global = eng.context.global orelse return;
    const rt = eng.runtime;
    const ctx = eng.context;
    mustPublish(exec.array_ops.arrayIteratorPrototypeFromContext(ctx, global));
    mustPublish(exec.string_ops.stringIteratorPrototypeFromContext(ctx, global));
    mustPublish(exec.string_ops.regExpStringIteratorPrototype(ctx, global));
    mustPublish(exec.object_ops.generatorPrototypeFromGlobal(rt, global));
    mustPublish(exec.object_ops.generatorFunctionPrototypeFromGlobal(rt, global));
    mustPublish(exec.object_ops.asyncGeneratorFunctionPrototypeFromGlobal(rt, global));
    mustPublish(exec.promise_ops.asyncFunctionPrototypeFromGlobal(rt, global));
    mustPublish(exec.promise_ops.asyncIteratorPrototypeFromGlobal(rt, global));
    mustPublish(exec.promise_ops.asyncGeneratorPrototypeFromGlobal(rt, global));
    mustPublish(exec.object_ops.wrapForValidIteratorPrototype(rt, global));
    mustPublish(exec.object_ops.callSitePrototypeFromGlobal(rt, global));
    mustPublish(exec.iterator_ops.iteratorHelperPrototype(rt, global));
    _ = exec.iterator_ops.iteratorPrototypeFromGlobal(rt, global);
    _ = eng.eval("void new Map().keys(); void new Set().values();") catch |err|
        std.debug.panic("isolation preheat: {s}", .{@errorName(err)});
    eachIntrinsic(eng, visitMaterialize);
    while (true) switch (exec.promise_ops.drainOnePendingJob(ctx, null) catch |err|
        std.debug.panic("drainOnePendingJob: {s}", .{@errorName(err)})) {
        .empty, .exception => break,
        .success => {},
    };
    clearPendingState(eng);
    ctx.lexicals = null;
}

fn captureIsolationBaseline(eng: *TestEngine) void {
    eachIntrinsic(eng, visitNote);
    isolation_objects_ready = true;
}

fn releaseIsolationBaseline(rt: *core.JSRuntime) void {
    var index: usize = 0;
    while (index < isolation_object_count) : (index += 1) {
        const slots = isolation_objects[index].slots;
        if (slots.len != 0) std.heap.page_allocator.free(slots);
        isolation_objects[index].slots = &.{};
    }
    isolation_object_count = 0;
    isolation_objects_ready = false;
    releaseIsolationRoots(rt);
}

fn liveHasAtom(object: *core.Object, atom_id: core.atom.Atom) bool {
    var index: usize = 0;
    while (index < object.shape_ref.prop_count) : (index += 1) {
        if (object.propFlagsAt(index).deleted) continue;
        if (object.propAtomAt(index) == atom_id) return true;
    }
    return false;
}

fn baselineHasAtom(watched: *const IsolationObject, atom_id: core.atom.Atom, live_only: bool) bool {
    var index: usize = 0;
    while (index < watched.prop_count) : (index += 1) {
        if (live_only and core.property.Flags.fromBits(watched.slots[index].flags).deleted) continue;
        if (watched.slots[index].atom == atom_id) return true;
    }
    return false;
}

fn panicShapeDiff(rt: *core.JSRuntime, object: *core.Object, watched: *const IsolationObject) noreturn {
    const label = isolationLabel(watched);
    var index: usize = 0;
    while (index < watched.prop_count) : (index += 1) {
        if (core.property.Flags.fromBits(watched.slots[index].flags).deleted) continue;
        const atom_id = watched.slots[index].atom;
        if (!liveHasAtom(object, atom_id)) panicChanged(label, rt, atom_id);
    }
    index = 0;
    while (index < object.shape_ref.prop_count) : (index += 1) {
        const atom_id = object.propAtomAt(index);
        const deleted = object.propFlagsAt(index).deleted;
        if (deleted) {
            if (!baselineHasAtom(watched, atom_id, false)) panicChanged(label, rt, atom_id);
            continue;
        }
        if (!baselineHasAtom(watched, atom_id, true)) panicChanged(label, rt, atom_id);
    }
    panicChanged(label, rt, core.atom.null_atom);
}

fn compareIsolationObject(rt: *core.JSRuntime, watched: *IsolationObject) void {
    const object = isolationObject(watched);
    const label = isolationLabel(watched);
    if (object.getPrototype() != isolation_ptrs[watched.proto_root]) panicPrototype(label);
    const live_count: usize = object.shape_ref.prop_count;
    if (live_count != watched.prop_count) panicShapeDiff(rt, object, watched);

    var materialized = false;
    var index: usize = 0;
    while (index < live_count) : (index += 1) {
        const base = &watched.slots[index];
        const live_atom = object.propAtomAt(index);
        if (live_atom != base.atom) panicChanged(label, rt, base.atom);
        const live_flags = object.propFlagsAt(index);
        const base_flags = core.property.Flags.fromBits(base.flags);
        const live_bits = fingerprintSlot(object, index);
        if (isLegalMaterialization(base_flags, live_flags)) {
            installSlotRoots(object, index, base);
            materialized = true;
            continue;
        }
        const base_bits = rootedBaselineBits(base);
        if (live_flags.bits() != base.flags or
            (!live_flags.deleted and (live_bits.a != base_bits.a or live_bits.b != base_bits.b)))
        {
            panicChanged(label, rt, live_atom);
        }
    }
    const identity = object.shape_ref.identity;
    if (materialized or identity != watched.shape_identity) watched.shape_identity = identity;
}

fn checkSharedIsolation(eng: *TestEngine) void {
    checkGlobalPrototype(eng);
    if (!isolation_objects_ready) return;
    var index: usize = 0;
    while (index < isolation_object_count) : (index += 1) {
        compareIsolationObject(eng.runtime, &isolation_objects[index]);
    }
    eachIntrinsic(eng, visitNote);
}

fn clearPendingState(eng: *TestEngine) void {
    if (eng.context.hasException()) _ = eng.context.takeException();
    if (eng.context.hasUnhandledRejection()) _ = eng.context.takeUnhandledRejection();
}

fn mustPageAlloc(comptime T: type, n: usize) []T {
    return std.heap.page_allocator.alloc(T, n) catch |err|
        std.debug.panic("page_allocator.alloc: {s}", .{@errorName(err)});
}

const test_runner_root = @import("root");

fn leakCensusEnabled() bool {
    return std.c.getenv("ZJS_LEAK_CENSUS") != null;
}

fn runnerPass() usize {
    if (@hasDecl(test_runner_root, "zjs_test_runner_current_pass")) return test_runner_root.zjs_test_runner_current_pass;
    return 0;
}

fn runnerTestName() []const u8 {
    if (@hasDecl(test_runner_root, "zjs_test_runner_current_name_ptr")) {
        return test_runner_root.zjs_test_runner_current_name_ptr[0..test_runner_root.zjs_test_runner_current_name_len];
    }
    return "";
}

pub fn sharedTestEngine() *TestEngine {
    if (shared_engine_storage == null) {
        shared_engine_storage = TestEngine.init(std.heap.page_allocator) catch |err|
            std.debug.panic("TestEngine.init: {s}", .{@errorName(err)});
        const eng = &shared_engine_storage.?;
        // Force the global object build (`installHostGlobals`) by
        // running an empty eval. This lets us snapshot the post-install
        // property count so subsequent `endSharedTest()` calls can
        // remove user-added globals (`var x = ...`, `function f() {}`,
        // ...) without rebuilding the entire standard-globals
        // namespace.
        _ = eng.eval(";") catch |err| std.debug.panic("baseline eval: {s}", .{@errorName(err)});
        clearPendingState(eng);
        publishLazyIntrinsicPrototypes(eng);
        ensureIsolationRoots(eng.runtime);
        if (eng.context.global) |g| {
            shared_engine_baseline.property_count = g.shape_ref.prop_count;
            shared_engine_baseline.shape_prop_count = g.shape_ref.prop_count;
            shared_engine_baseline.shape_hash = g.shape_ref.hash;
            shared_engine_baseline.shape_deleted_count = g.shape_ref.deletedPropCount();

            // Snapshot the baseline property entries (value slots only;
            // key atoms and flags are snapshotted with the shape props
            // below).
            shared_engine_baseline.properties = mustPageAlloc(core.property.Entry, g.shape_ref.prop_count);
            shared_engine_baseline.var_refs = mustPageAlloc(?SharedBaselineVarRef, g.shape_ref.prop_count);
            @memset(shared_engine_baseline.var_refs.?, null);
            for (g.propertyEntries(), 0..) |entry, idx| {
                // Dup the slot using its kind (read from the shape flags); the
                // value cell is untagged so dup/destroy need the flags.
                shared_engine_baseline.properties.?[idx] = .{ .slot = entry.slot };
                if (g.propFlagsAt(idx).isVarRef()) {
                    const cell = entry.slot.var_ref;
                    shared_engine_baseline.var_refs.?[idx] = .{
                        .value = cell.varRefValue(),
                        .is_lexical = cell.is_lexical,
                        .is_const = cell.varRefIsConstSlot().*,
                        .is_deletable = cell.varRefIsDeletableSlot().*,
                    };
                }
            }

            shared_engine_baseline.shape_props = mustPageAlloc(core.shape.Property, g.shape_ref.prop_count);
            for (g.shape_ref.props()[0..g.shape_ref.prop_count], 0..) |prop, idx| {
                shared_engine_baseline.shape_props.?[idx] = prop;
                shared_engine_baseline.shape_props.?[idx].hash_next = core.shape.no_property_index;
            }
        }
        gc.reclaimNow(eng.runtime);
        captureGlobalPrototype(eng);
        captureIsolationBaseline(eng);
        shared_engine_baseline.allocation_count = eng.runtime.allocation_diagnostics.allocation_count;
        shared_engine_baseline.allocated_bytes = eng.runtime.allocation_diagnostics.allocated_bytes;
        shared_engine_baseline.module_count = eng.context.modules.count();
        registerSharedEngineProcessTeardown();
    }
    return &shared_engine_storage.?;
}

extern "c" fn atexit(function: *const fn () callconv(.c) void) c_int;

fn registerSharedEngineProcessTeardown() void {
    if (shared_engine_teardown_registered) return;
    shared_engine_teardown_registered = true;
    _ = atexit(&sharedEngineProcessTeardown);
}

fn sharedEngineProcessTeardown() callconv(.c) void {
    deinitSharedTestEngine();
}

/// Process-exit teardown for the shared engine. Frees the baseline snapshot's
/// page-allocator storage, then destroys only the host-owned main context.
/// Leftover createRealm cycles are collected by `JSRuntime.deinit`; extra
/// `JSContext.destroy` on those children is the undercount that trips
/// `visitRealm`.
pub fn deinitSharedTestEngine() void {
    const eng = if (shared_engine_storage) |*e| e else return;
    // Last `endSharedTest` already restored the baseline; the snapshot itself
    // is now only page-allocator storage (var refs, properties, shape props),
    // so releasing it just frees those arrays before the engine goes away.
    releaseSharedEngineBaselineSnapshot(eng.runtime);
    var owned = eng.*;
    shared_engine_storage = null;
    owned.deinit();
}

fn releaseSharedEngineBaselineSnapshot(rt: *core.JSRuntime) void {
    if (shared_engine_baseline.var_refs) |var_refs| {
        std.heap.page_allocator.free(var_refs);
        shared_engine_baseline.var_refs = null;
    }
    if (shared_engine_baseline.properties) |baselines| {
        std.heap.page_allocator.free(baselines);
        shared_engine_baseline.properties = null;
    }
    if (shared_engine_baseline.shape_props) |baseline_shape_props| {
        std.heap.page_allocator.free(baseline_shape_props);
        shared_engine_baseline.shape_props = null;
    }
    shared_engine_baseline.property_count = 0;
    shared_engine_baseline.shape_prop_count = 0;
    shared_engine_baseline.shape_hash = 0;
    shared_engine_baseline.shape_deleted_count = 0;
    isolation_global_prototype = null;
    isolation_global_prototype_ready = false;
    releaseIsolationBaseline(rt);
}

pub fn endSharedTest() void {
    const eng = if (shared_engine_storage) |*e| e else return;
    resetSharedEngineAfterTest(eng);
    checkSharedIsolation(eng);

    const allocation_count = eng.runtime.allocation_diagnostics.allocation_count;
    const allocated_bytes = eng.runtime.allocation_diagnostics.allocated_bytes;
    const module_count = eng.context.modules.count();
    const count_delta = @as(i128, @intCast(allocation_count)) - @as(i128, @intCast(shared_engine_baseline.allocation_count));
    const bytes_delta = @as(i128, @intCast(allocated_bytes)) - @as(i128, @intCast(shared_engine_baseline.allocated_bytes));
    const module_delta = @as(i128, @intCast(module_count)) - @as(i128, @intCast(shared_engine_baseline.module_count));
    const test_name = runnerTestName();
    const current_pass = runnerPass();

    if (leakCensusEnabled()) {
        std.debug.print("leak-census: pass={} test=\"{s}\" count_delta={d} bytes_delta={d} module_count={} module_delta={d} count={} bytes={}\n", .{
            current_pass,
            test_name,
            count_delta,
            bytes_delta,
            module_count,
            module_delta,
            allocation_count,
            allocated_bytes,
        });
    }

    // Pass 0 deliberately warms lazy shared-Realm state. From pass 1 onward,
    // module-registry growth is the sole unbounded owner and is accounted by
    // its own monotonic count; every other test must stay within the measured
    // bounded property-capacity noise floor.
    const module_count_grew = module_count > shared_engine_baseline.module_count;
    if (current_pass != 0 and !module_count_grew) {
        const limit = std.math.add(usize, shared_engine_baseline.allocation_count, shared_engine_allocation_tolerance) catch std.math.maxInt(usize);
        if (allocation_count > limit) {
            std.debug.panic(
                "shared-test leak gate: test=\"{s}\" count_delta={d} bytes_delta={d} module_count={} module_delta={d} baseline_count={} observed_count={} tolerance={}",
                .{
                    test_name,
                    count_delta,
                    bytes_delta,
                    module_count,
                    module_delta,
                    shared_engine_baseline.allocation_count,
                    allocation_count,
                    shared_engine_allocation_tolerance,
                },
            );
        }
    }

    shared_engine_baseline.allocation_count = @max(shared_engine_baseline.allocation_count, allocation_count);
    shared_engine_baseline.allocated_bytes = @max(shared_engine_baseline.allocated_bytes, allocated_bytes);
    shared_engine_baseline.module_count = @max(shared_engine_baseline.module_count, module_count);
}

fn resetSharedEngineAfterTest(eng: *TestEngine) void {
    // Clear any exception still sitting on the context from a test
    // that returned via `try` without explicitly taking it.
    clearPendingState(eng);
    // Drain pending jobs so the next test starts with an empty queue;
    // tests that schedule a promise via `Promise.resolve(...)` and
    // return without awaiting would otherwise leak the job into the
    // next test.
    if (eng.context.global != null) {
        while (true) switch (exec.promise_ops.drainOnePendingJob(eng.context, null) catch |err|
            std.debug.panic("drainOnePendingJob: {s}", .{@errorName(err)})) {
            .empty, .exception => break,
            .success => {},
        };
    }
    clearPendingState(eng);
    exec.zjs_vm.cleanupAtomicsWaitersForContext(eng.context);
    if (eng.context.global) |global| {
        // Reset global lexical bindings (let / const) so the next
        // test can re-declare any name without triggering a
        // redeclaration SyntaxError.
        eng.context.lexicals = null;
        // Suppress allocation-triggered GC for the whole property restore.
        // Restoring slots and shape flags is a multi-step swap that passes
        // through transient states where a slot's arm and the live shape's
        // `Flags.kind` disagree (e.g. a materialized `.data` slot while the
        // baseline flags being restored say `.auto_init`). Under
        // `-Dzjs_force_gc=true` the `restorePropertyLayout` storage alloc
        // would otherwise run the cycle collector against that half-applied
        // state and trace the wrong union arm. Making the restore atomic
        // w.r.t. GC keeps the slot/flag pair consistent throughout.
        const budget = &eng.runtime.gc.heap_budget;
        const saved_suspend = budget.suspend_alloc_notify;
        budget.suspend_alloc_notify = true;
        defer budget.suspend_alloc_notify = saved_suspend;

        // Property compaction may have shifted live baseline entries and shrunk
        // the global's value buffer. Restore capacity, then rebuild both
        // parallel arrays entirely from the snapshot.
        // This also removes user-added globals without assuming baseline indices
        // survived a compacting delete.
        const baseline = shared_engine_baseline.property_count;
        global.reserveOwnPropertyCapacity(eng.runtime, baseline) catch |err|
            std.debug.panic("reserveOwnPropertyCapacity: {s}", .{@errorName(err)});

        // Restore baseline properties to their original states.
        if (shared_engine_baseline.properties) |baselines| {
            for (baselines, 0..) |base, idx| {
                if (shared_engine_baseline.var_refs.?[idx]) |state| {
                    // Restore the snapshot cell before publishing another ref
                    // to it in the rebuilt property array.
                    const cell = base.slot.var_ref;
                    cell.varRefValueSlot().* = state.value;
                    cell.is_lexical = state.is_lexical;
                    cell.varRefIsConstSlot().* = state.is_const;
                    cell.varRefIsDeletableSlot().* = state.is_deletable;
                }
                global.propertyEntry(idx).* = .{ .slot = base.slot };
            }
        }

        if (shared_engine_baseline.shape_props) |baseline_shape_props| {
            eng.runtime.shapes.restorePropertyLayout(
                eng.runtime,
                &global.shape_ref,
                baseline_shape_props[0..shared_engine_baseline.shape_prop_count],
                shared_engine_baseline.shape_hash,
                shared_engine_baseline.shape_deleted_count,
            ) catch |err| std.debug.panic("restorePropertyLayout: {s}", .{@errorName(err)});
        }
    }
    gc.reclaimNow(eng.runtime);
}
