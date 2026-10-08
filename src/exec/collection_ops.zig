//! Map, Set, WeakMap, and WeakSet construction, methods, and iteration.
//!
//! Strong collection records hold their keys and values; weak tables retain
//! identity without making their keys strong, and live iterators retain their
//! backing record until detach. Returned JSValues are owned. Re-export
//! and alias walls preserve the neutral core callback/id ABI and earlier exec
//! extraction seams without merging implementations. Keep the measured
//! `ctx`/`output`/`global`/caller-function/caller-frame tuple explicit and keep
//! collection hot arms separate from cold generic callbacks.

const core = @import("../core/root.zig");
const iterator_ops = @import("iterator_ops.zig");
const function_builtin = core.function;
const globals_mod = core.global_slots;
const unicode = @import("../libs/unicode.zig");
const std = @import("std");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call_runtime = @import("call_runtime.zig");
const call_site_mod = @import("call_site.zig");
const CallSite = call_site_mod.CallSite;

const object_ops = @import("object_ops.zig");
const array_ops = @import("array_ops.zig");
const exception_ops = @import("exception_ops.zig");
const value_ops = @import("value_ops.zig");

const HostError = exception_ops.HostError;

// The collection callback protocol lives in `core/host_function.zig`, beside
// the neutral host-function ABI.
const CallbackError = core.host_function.CallbackError;
const CallbackHost = core.host_function.CallbackHost;

pub const StaticMethod = enum(u32) {
    group_by = 101,
};

// ConstructorMethod + ConstructorKind + constructorId + constructIdForKind
// relocated to engine core (`core/host_function.zig`:
// `builtin_method_ids.collection` for the construct-record id enum,
// `builtin_method_id_lookup.collection` for the pure name/kind->id helpers) in
// Phase 6b-3 STEP 2/6 alongside the other pure collection id helpers;
// re-exported here so the construct/install side keeps the original names.
// `constructorKindFromId` below (construct record handler reverse mapper, not
// VM-referenced) keeps its local definition and consumes the re-exports.
const ConstructorMethod = core.host_function.builtin_method_ids.collection.ConstructorMethod;
const ConstructorKind = core.host_function.builtin_method_id_lookup.collection.ConstructorKind;

/// Construct id -> `ConstructorKind` value (map=1, set=2, weak_map=3,
/// weak_set=4) for the construct record handler.
fn constructorKindFromId(id: u32) ?u32 {
    return switch (id) {
        @intFromEnum(ConstructorMethod.construct_map) => @intFromEnum(ConstructorKind.map),
        @intFromEnum(ConstructorMethod.construct_set) => @intFromEnum(ConstructorKind.set),
        @intFromEnum(ConstructorMethod.construct_weak_map) => @intFromEnum(ConstructorKind.weak_map),
        @intFromEnum(ConstructorMethod.construct_weak_set) => @intFromEnum(ConstructorKind.weak_set),
        else => null,
    };
}

pub fn staticMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "groupBy")) return @intFromEnum(StaticMethod.group_by);
    return null;
}

pub const PrototypeMethod = core.host_function.builtin_method_ids.collection.PrototypeMethod;

// Pure name->id mapping + the class-keyed fast-path / legacy-closure id helpers
// relocated to engine core (`core/host_function.zig`, next to
// `builtin_method_ids.collection`) in Phase 6b-3c; re-exported here so the
// dispatch/install side keeps the original names.
const collection_id_lookup = core.host_function.builtin_method_id_lookup.collection;
pub const prototypeMethodId = collection_id_lookup.prototypeMethodId;

/// Declaration + dispatch table for the `.collection` native-builtin domain
/// (QuickJS js_map_funcs / js_set_funcs analogue). One shared record handler
/// `collectionCall` switches on the per-record `magic` (== domain-local id) and
/// dispatches to the method bodies in this module: the primitive strong/weak
/// implementations (`mapSet`/`mapGet`/`setAdd`/...) for the bare-runtime path,
/// and the realm-aware bodies that drive user callbacks through the VM. The
/// weak-collection key registry stays GC-coupled in core
/// (`Object.weakIdentityFromValue`); direct Map/Set opcode paths call the
/// primitive implementations. The four constructors, the static `Map.groupBy`
/// and the shared prototype methods all route through the table. Standard-global bootstrap resolves
/// names through its map/set/weak-collection prototype method lists; this table
/// is consumed by the record-dispatch path (`internal_builtins.table`).
pub const internal_entries = collectionEntries: {
    const RecordEntry = core.host_function.InternalEntry;
    break :collectionEntries [_]RecordEntry{
        // Map/Set/WeakMap/WeakSet constructors. Construct-capable so
        // `new Map(...)` etc. route through `collectionCall`'s construct branch;
        // not installed with a native id on the constructor objects (resolved by
        // name), so reached only via `callConstructRecord` with an explicit ref.
        collectionConstructorEntry("Map", 0, @intFromEnum(ConstructorMethod.construct_map)),
        collectionConstructorEntry("Set", 0, @intFromEnum(ConstructorMethod.construct_set)),
        collectionConstructorEntry("WeakMap", 0, @intFromEnum(ConstructorMethod.construct_weak_map)),
        collectionConstructorEntry("WeakSet", 0, @intFromEnum(ConstructorMethod.construct_weak_set)),
        collectionEntry("set", 2, @intFromEnum(PrototypeMethod.set)),
        collectionEntry("get", 1, @intFromEnum(PrototypeMethod.get)),
        collectionEntry("has", 1, @intFromEnum(PrototypeMethod.has)),
        collectionEntry("delete", 1, @intFromEnum(PrototypeMethod.delete)),
        collectionEntry("clear", 0, @intFromEnum(PrototypeMethod.clear)),
        collectionEntry("add", 1, @intFromEnum(PrototypeMethod.add)),
        collectionEntry("keys", 0, @intFromEnum(PrototypeMethod.keys)),
        collectionEntry("values", 0, @intFromEnum(PrototypeMethod.values)),
        collectionEntry("entries", 0, @intFromEnum(PrototypeMethod.entries)),
        collectionEntry("forEach", 1, @intFromEnum(PrototypeMethod.for_each)),
        collectionEntry("getOrInsert", 2, @intFromEnum(PrototypeMethod.get_or_insert)),
        collectionEntry("getOrInsertComputed", 2, @intFromEnum(PrototypeMethod.get_or_insert_computed)),
        collectionEntry("next", 0, @intFromEnum(PrototypeMethod.iterator_next)),
        collectionEntry("get size", 0, @intFromEnum(PrototypeMethod.size_getter)),
        collectionEntry("difference", 1, @intFromEnum(PrototypeMethod.difference)),
        collectionEntry("intersection", 1, @intFromEnum(PrototypeMethod.intersection)),
        collectionEntry("isDisjointFrom", 1, @intFromEnum(PrototypeMethod.is_disjoint_from)),
        collectionEntry("isSubsetOf", 1, @intFromEnum(PrototypeMethod.is_subset_of)),
        collectionEntry("isSupersetOf", 1, @intFromEnum(PrototypeMethod.is_superset_of)),
        collectionEntry("symmetricDifference", 1, @intFromEnum(PrototypeMethod.symmetric_difference)),
        collectionEntry("union", 1, @intFromEnum(PrototypeMethod.union_)),
        collectionEntry("groupBy", 2, @intFromEnum(StaticMethod.group_by)),
    };
};

fn collectionEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&collectionCall),
    };
}

/// A collection constructor record (one per `ConstructorKind`): construct-capable
/// so `new Map/Set/WeakMap/WeakSet(...)` reach `collectionCall`'s construct
/// branch.
fn collectionConstructorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .constructor_magic,
        .native_function = builtin_dispatch.constructorMagic(&collectionCall),
    };
}

/// Shared record handler for the `.collection` domain: the `Map.groupBy` static and
/// the prototype methods delegate to the collection VM ops (with a realm global)
/// or to the primitive-only collection entry points (bare-runtime
/// fallback, no global). The weak-collection mutators reached from these methods
/// keep their weak_id registry / GC interaction in core.
fn collectionCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const ctx = host_call.ctx;
    const observable = host_call.func_obj != null;
    const callable_global: ?*core.Object = if (observable) blk: {
        const realm = try builtin_dispatch.callableRealm(host_call);
        std.debug.assert(realm.realm == ctx);
        break :blk realm.global;
    } else host_call.global;
    const output = host_call.output;
    const id: u32 = host_call.magic;
    const args = host_call.args;
    // Legacy slots belong only to func-object-free algorithmic reuse. An
    // observable callable's realm/global authority is the view above.
    const globals: []core.global_slots.Slot = if (observable) &.{} else host_call.globals;
    const this_value = host_call.this_value;
    const caller_function = builtin_dispatch.callerBytecode(host_call);
    const caller_frame = builtin_dispatch.callerFrame(host_call);

    if (constructorKindFromId(id)) |kind| {
        // `new Map/Set/WeakMap/WeakSet(...)` arrives through the construct record
        // path with the resolved instance prototype in `new_target`; the adder
        // (set/add) protocol filling from an iterable argument is driven by the
        // VM construct sites after this object is created, exactly as before.
        return constructWithPrototype(ctx.runtime, kind, host_call.new_target);
    }
    if (id == @intFromEnum(StaticMethod.group_by)) {
        return collectionGroupByRecord(ctx, output, callable_global, globals, this_value, args, caller_function, caller_frame);
    }
    const function_object = host_call.func_obj orelse {
        // Internal engine call sites route a collection method body through the
        // table without a materialized function object: `Array.from`/`Array.of`
        // and the typed-array static factories draining a Map/Set iterator
        // (`global == null`, the bare primitive iterator); the collection
        // construct adder fill (`global == null`, primitive set/add); and the
        // direct opcode path (`global != null`, with the receiver's owner class
        // already validated). With no function object
        // there is no installed-prototype owner class to re-derive here, so
        // dispatch the body directly, mirroring the historical direct callers:
        // `methodCallObjectWithGlobal` for the realm path (dropped-result
        // honored, exactly the retired `callPreparedCollectionNativeTarget`) and
        // the primitive `methodCallWithCallbackHost` for the global-less path
        // (exactly the retired `methodCall`/`methodCallWithCallbackHost`).
        if (host_call.global) |active_global| {
            const receiver = object_ops.objectFromValue(this_value) orelse return error.TypeError;
            if (builtin_dispatch.callerResultIsDropped(caller_function, caller_frame)) {
                if (try methodCallDroppedResult(ctx.runtime, receiver, id, args)) return core.JSValue.undefinedValue();
            }
            return methodCallObjectWithGlobal(ctx, active_global, receiver, id, args, globals);
        }
        return methodCallWithCallbackHost(ctx.runtime, this_value, id, args, callbackHost(ctx, globals));
    };
    const active_global = callable_global orelse return error.InvalidBuiltinRegistry;
    if (try collectionNativeRecord(ctx, output, active_global, this_value, function_object, id, args, caller_function, caller_frame)) |value| return value;
    return error.TypeError;
}

fn collectionGroupByRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: ?*core.Object,
    globals: []globals_mod.Slot,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) HostError!core.JSValue {
    // Mirrors js_object_groupBy (quickjs.c, shared is_map=1 entry for
    // Map.groupBy): the receiver is never read — qjs constructs the result via
    // js_map_constructor with a JS_UNDEFINED this (the intrinsic Map
    // prototype), so a detached `const g = Map.groupBy; g(items, fn)` works.
    if (global) |active_global| {
        return mapGroupByCall(ctx, output, active_global, args, caller_function, caller_frame);
    }
    // Bare-runtime path (no realm intrinsics): keep deriving the result
    // prototype from a constructor receiver when one is supplied, but never
    // require the receiver.
    const prototype = if (object_ops.objectFromValue(this_value) != null)
        try object_ops.constructorPrototypeObject(this_value)
    else
        null;
    return groupByWithCallbackHost(ctx.runtime, args, prototype, callbackHost(ctx, globals));
}

/// QuickJS source map: narrow collection constructors used by the transitional
/// `new_collection` bytecode. The prototype-less compatibility object exposes
/// own C-function methods, so their construction realm is explicit.
pub fn construct(realm: *core.RealmContext, kind: u32) !core.JSValue {
    const value = try constructWithPrototype(realm.runtime, kind, null);
    const object = try expectObject(value);
    try defineNativeMethods(realm, object, object.class_id);
    return value;
}

/// Payload-only fixture/algorithm constructor. Callers use `methodCall`
/// directly and therefore do not publish own callable properties.
pub fn constructBare(rt: *core.JSRuntime, kind: u32) !core.JSValue {
    return constructWithPrototype(rt, kind, null);
}

pub fn constructWithPrototype(rt: *core.JSRuntime, kind: u32, prototype: ?*core.Object) !core.JSValue {
    const class_id = collectionClassId(kind) orelse return error.TypeError;
    const object = try core.Object.create(rt, class_id, prototype);
    errdefer core.Object.destroyFromHeader(rt, object.gcHeader());
    return object.value();
}

/// QuickJS source map: selected Map/Set/WeakMap/WeakSet methods currently
/// covered by smoke fixtures and targeted collection validation. Strong
/// collections use object-owned entry arrays; weak collections store object
/// identities plus values so keys are not retained through ordinary properties.
pub fn methodCall(rt: *core.JSRuntime, object_value: core.JSValue, method: u32, args: []const core.JSValue) !core.JSValue {
    return methodCallWithCallbackHost(rt, object_value, method, args, .{});
}

fn methodCallWithCallbackHost(
    rt: *core.JSRuntime,
    object_value: core.JSValue,
    method: u32,
    args: []const core.JSValue,
    host: CallbackHost,
) !core.JSValue {
    const object = try expectObject(object_value);
    return methodCallResolved(rt, null, globalObjectFromGlobals(host.globals), object, method, args, host);
}

fn methodCallObjectWithGlobal(
    ctx: *core.JSContext,
    global: *core.Object,
    object: *core.Object,
    method: u32,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
) !core.JSValue {
    return methodCallResolved(ctx.runtime, ctx, global, object, method, args, .{ .globals = globals });
}

fn methodCallResolved(
    rt: *core.JSRuntime,
    ctx: ?*core.JSContext,
    global: ?*core.Object,
    object: *core.Object,
    method: u32,
    args: []const core.JSValue,
    host: CallbackHost,
) !core.JSValue {
    // Collection methods reach the engine through this channel rather than
    // the builtin dispatch funnel, so the receiver has to be rooted here too.
    // A minor that runs mid-insert would otherwise reclaim the very
    // collection the operation is walking.
    var receiver: ?*core.Object = object;
    var receiver_roots = core.runtime.rootObjects(.{&receiver});
    receiver_roots.activate(rt);
    defer receiver_roots.deactivate(rt);

    const method_id = std.enums.fromInt(PrototypeMethod, method) orelse return error.TypeError;
    return switch (method_id) {
        .set => {
            const key = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
            return mapSet(rt, object, key, value);
        },
        .get => {
            const key = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return mapGet(rt, object, key);
        },
        .has => {
            const key = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return collectionHas(rt, object, key);
        },
        .delete => {
            const key = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return collectionDelete(rt, object, key);
        },
        .clear => {
            return collectionClear(rt, object);
        },
        .add => {
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return setAdd(rt, object, value);
        },
        .keys => {
            return collectionIterator(rt, ctx, global, object, .key);
        },
        .values => {
            return collectionIterator(rt, ctx, global, object, .value);
        },
        .entries => {
            return collectionIterator(rt, ctx, global, object, .key_value);
        },
        .for_each => return collectionForEach(object, args, host),
        .get_or_insert => {
            const key = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return mapGetOrInsert(rt, object, key, if (args.len >= 2) args[1] else core.JSValue.undefinedValue());
        },
        .get_or_insert_computed => {
            if (args.len < 2) return error.NotAFunction;
            return mapGetOrInsertComputed(rt, object, args[0], args[1], host);
        },
        .iterator_next => {
            return collectionIteratorNext(rt, global, object);
        },
        .size_getter => {
            return collectionSize(object);
        },
        .difference, .intersection, .is_disjoint_from, .is_subset_of, .is_superset_of, .symmetric_difference, .union_ => error.TypeError,
    };
}

fn methodCallDroppedResult(rt: *core.JSRuntime, object: *core.Object, method: u32, args: []const core.JSValue) !bool {
    switch (method) {
        @intFromEnum(PrototypeMethod.set) => {
            const key = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
            try mapSetNoResult(rt, object, key, value);
            return true;
        },
        @intFromEnum(PrototypeMethod.add) => {
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            try setAddNoResult(rt, object, value);
            return true;
        },
        @intFromEnum(PrototypeMethod.delete) => {
            const key = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            try collectionDeleteNoResult(rt, object, key);
            return true;
        },
        else => return false,
    }
}

pub fn groupByWithCallbackHost(
    rt: *core.JSRuntime,
    args: []const core.JSValue,
    prototype: ?*core.Object,
    host: CallbackHost,
) !core.JSValue {
    if (args.len < 2 or !call_runtime.isCallableValue(args[1])) return error.NotAFunction;

    // Actual slots survive callbacks in both test and executable builds.
    // The constructor still accepts a raw prototype, so pin that snapshot
    // until it has been installed in the result's shape.
    var values = [_]core.JSValue{ args[0], args[1], core.JSValue.undefinedValue(), if (prototype) |object| object.value() else core.JSValue.nullValue() };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{ .{ .mutable = &slots }, .{ .borrowed = values[3..4] } };
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    values[2] = try constructWithPrototype(rt, 1, prototype);
    values[3] = core.JSValue.undefinedValue();

    if (values[0].isString()) {
        var unit_index: usize = 0;
        var element_index: u32 = 0;
        while (unit_index < core.string.stringValueLenUnchecked(values[0])) : (element_index += 1) {
            const element = try stringElementAt(rt, values[0], &unit_index);
            try addGroupedItem(rt, try expectObject(values[2]), values[1], host, element, element_index);
        }
        return values[2];
    }

    if (!(try expectObject(values[0])).isArray()) return error.TypeError;
    var index: u32 = 0;
    while (index < (try expectObject(values[0])).arrayLength()) : (index += 1) {
        const item = try (try expectObject(values[0])).getProperty(core.Atom.taggedInt(index));
        try addGroupedItem(rt, try expectObject(values[2]), values[1], host, item, index);
    }
    return values[2];
}

fn mapSet(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue, value: core.JSValue) !core.JSValue {
    try mapSetNoResult(rt, object, key, value);
    return object.value();
}

fn mapSetNoResult(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue, value: core.JSValue) !void {
    if (object.class_id == core.class.ids.weakmap) {
        const key_identity = (try weakKeyIdentityRegister(rt, key)) orelse return error.TypeError;
        try setWeakMapEntryByIdentityChecked(rt, object, key_identity, value);
        return;
    }

    if (object.class_id != core.class.ids.map) return error.TypeError;
    const canonical_key = canonicalizeKey(key);
    if (findStrongEntry(object, canonical_key)) |index| {
        const entry = &object.collectionEntriesSlot().items[index];
        entry.value = value;
        // Overwriting an existing entry stores into the payload slice, which
        // no property-store barrier covers.
        rt.gc.generationalBarrier(object.gcHeader(), value.cycleMarkHeader());
    } else {
        const entry = core.object.CollectionEntry{ .key = canonical_key, .value = value };
        try appendStrongEntryOwned(rt, object, entry);
    }
}

// WeakMap entry mutation relocated to engine core (`core/collection.zig`) in
// Phase 6b-3 STEP 7A; re-exported here so the collection method bodies and the
// legacy public surface consumed by the WeakMap unit test keeps the original
// spelling.
pub const setWeakMapEntry = core.collection.setWeakMapEntry;
const setWeakMapEntryByIdentityChecked = core.collection.setWeakMapEntryByIdentityChecked;

fn mapGet(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue) !core.JSValue {
    if (object.class_id == core.class.ids.weakmap) {
        const key_identity = weakKeyIdentityPeek(rt, key) orelse return core.JSValue.undefinedValue();
        const index = findWeakEntry(object, key_identity) orelse return core.JSValue.undefinedValue();
        return object.weakCollectionEntriesSlot().items[index].value;
    }

    if (object.class_id != core.class.ids.map) return error.TypeError;
    const index = findStrongEntry(object, key) orelse return core.JSValue.undefinedValue();
    return object.collectionEntriesSlot().items[index].value;
}

const CollectionIteratorKind = iterator_ops.CollectionIteratorKind;

const IteratorRealm = struct {
    context: *core.JSContext,
    global: *core.Object,
};

fn iteratorRealm(
    rt: *core.JSRuntime,
    current_context: ?*core.JSContext,
    explicit_global: ?*core.Object,
) !IteratorRealm {
    if (explicit_global) |global| {
        const context = rt.contextForGlobalIncludingConstructing(global) orelse return error.InvalidBuiltinRegistry;
        return .{ .context = context, .global = global };
    }
    const context = current_context orelse return error.InvalidBuiltinRegistry;
    const global = context.global orelse return error.InvalidBuiltinRegistry;
    return .{ .context = context, .global = global };
}

fn collectionIterator(
    rt: *core.JSRuntime,
    ctx: ?*core.JSContext,
    global: ?*core.Object,
    object: *core.Object,
    kind: CollectionIteratorKind,
) !core.JSValue {
    const iterator_class = if (object.class_id == core.class.ids.map)
        core.class.ids.map_iterator
    else if (object.class_id == core.class.ids.set)
        core.class.ids.set_iterator
    else
        return error.TypeError;
    var target_value = object.value();
    var root_frame = core.runtime.rootValues(.{&target_value});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const realm = try iteratorRealm(rt, ctx, global);
    const prototype = try iteratorPrototype(
        rt,
        realm.context,
        realm.global,
        iterator_class,
        if (object.class_id == core.class.ids.map) "Map Iterator" else "Set Iterator",
    );
    const iterator = try core.Object.create(rt, iterator_class, prototype);
    errdefer core.Object.destroyFromHeader(rt, iterator.gcHeader());
    try iterator.setOptionalValueSlot(rt, iterator.iteratorTargetSlot(), target_value);
    // No entry-array cursor yet: qjs's fresh iterator has `cur_record == NULL`
    // and holds no record reference (js_map_iterator_new quickjs.c). The
    // cursor is taken on the first advance and released on exhaustion or in the
    // iterator payload teardown.
    iterator.iteratorIndexSlot().* = 0;
    iterator_ops.setCollectionIteratorKind(iterator, kind);
    return iterator.value();
}

fn iteratorPrototype(
    rt: *core.JSRuntime,
    realm: *core.JSContext,
    global: *core.Object,
    iterator_class: core.ClassId,
    tag_name: []const u8,
) !*core.Object {
    if (realm.classPrototypeObject(iterator_class)) |cached| return cached;
    const prototype = try createIteratorPrototype(rt, global, iterator_class, tag_name);
    try realm.setClassPrototype(iterator_class, prototype);
    return prototype;
}

fn createIteratorPrototype(
    rt: *core.JSRuntime,
    global: *core.Object,
    iterator_class: core.ClassId,
    tag_name: []const u8,
) !*core.Object {
    const base = iterator_ops.iteratorPrototypeFromGlobal(rt, global) orelse blk: {
        const fallback = try core.Object.create(rt, core.class.ids.object, object_ops.objectPrototypeFromGlobal(rt, global));
        errdefer core.Object.destroyFromHeader(rt, fallback.gcHeader());
        try defineToStringTag(rt, fallback, "Iterator");

        const iterator_method = try function_builtin.nativeFunctionForGlobal(rt, global, "[Symbol.iterator]", 0);
        const iterator_function = try expectObject(iterator_method);
        iterator_function.setNativeBuiltinIdAndRecord(core.function.nativeBuiltinId(.iterator, @intFromEnum(core.host_function.builtin_method_ids.iterator.IntrinsicMethod.iterator)));
        try fallback.defineOwnProperty(rt, core.atom.predefinedId("Symbol.iterator", .symbol).?, core.Descriptor.data(iterator_method, .method));

        break :blk fallback;
    };

    const specific = try core.Object.create(rt, core.class.ids.object, base);
    errdefer core.Object.destroyFromHeader(rt, specific.gcHeader());
    try defineToStringTag(rt, specific, tag_name);
    const next = try function_builtin.nativeFunctionForGlobal(rt, global, "next", 0);
    const next_object = try expectObject(next);
    next_object.nativeFunctionIdSlot().* = core.function.nativeBuiltinId(.collection, @intFromEnum(PrototypeMethod.iterator_next));
    // Mirrors js_map_iterator_next: the next function is
    // bound to one iterator class (JS_GetOpaque2 with JS_CLASS_MAP_ITERATOR +
    // magic), so a Map Iterator's next rejects Set iterators and vice versa.
    if (!try next_object.addCollectionMethodOwnerClass(rt, iterator_class)) return error.TypeError;
    try specific.defineOwnProperty(rt, core.atom.predefinedId("next", .string).?, core.Descriptor.data(next, .method));
    return specific;
}

fn globalObjectFromGlobals(globals: []const globals_mod.Slot) ?*core.Object {
    const global_value = globals_mod.getByAtom(globals, core.atom.ids.globalThis);
    return core.value_semantics.objectFromValue(global_value);
}

const defineToStringTag = iterator_ops.defineToStringTag;

fn collectionIteratorNext(rt: *core.JSRuntime, global: ?*core.Object, iterator: *core.Object) !core.JSValue {
    if (iterator.class_id != core.class.ids.map_iterator and iterator.class_id != core.class.ids.set_iterator) return error.TypeError;
    const target_value = (iterator.iteratorTargetSlot().*) orelse return iteratorResult(rt, global, core.JSValue.undefinedValue(), true);
    const target = try expectObject(target_value);
    // Park the cursor before reading a position out of the entry array
    // (quickjs.c `mr->ref_count++`); the done arm below detaches it.
    iterator.retainCollectionIteratorCursor();
    while (core.collection.nextIteratorEntry(target, iterator.iteratorIndexSlot())) |entry| {
        if (!entry.active) continue;
        const kind = iterator_ops.collectionIteratorKind(iterator) orelse return error.TypeError;
        return iteratorResult(rt, global, try iteratorValue(rt, global, target.class_id, entry, kind), false);
    }
    const done_result = try iteratorResult(rt, global, core.JSValue.undefinedValue(), true);
    iterator.detachCollectionIteratorTarget(rt);
    return done_result;
}

fn iteratorValue(rt: *core.JSRuntime, global: ?*core.Object, class_id: core.ClassId, entry: core.object.CollectionEntry, kind: CollectionIteratorKind) !core.JSValue {
    switch (kind) {
        .key => return entry.key,
        .value => return if (class_id == core.class.ids.set) entry.key else entry.value,
        .key_value => {
            var key_value = entry.key;
            var value_value = if (class_id == core.class.ids.set) entry.key else entry.value;
            var root_frame = core.runtime.rootValues(.{ &key_value, &value_value });
            root_frame.activate(rt);
            defer root_frame.deactivate(rt);

            // qjs js_create_array → JS_NewArray: pair proto
            // is the realm Array.prototype, not a null-proto class-name fallback.
            const prototype = if (global) |g| array_ops.arrayPrototypeFromGlobal(rt, g) else null;
            const pair = try core.Object.createArray(rt, prototype);
            errdefer core.Object.destroyFromHeader(rt, pair.gcHeader());
            try pair.defineOwnProperty(rt, core.Atom.taggedInt(0), core.Descriptor.data(key_value, .all));
            try pair.defineOwnProperty(rt, core.Atom.taggedInt(1), core.Descriptor.data(value_value, .all));
            return pair.value();
        },
    }
}

/// Owning wrapper over the single `CreateIterResultObject` owner: this file's
/// callers hand over their reference to `value`.
fn iteratorResult(rt: *core.JSRuntime, global: ?*core.Object, value: core.JSValue, done: bool) !core.JSValue {
    return iterator_ops.createIteratorResult(rt, global, value, done);
}

test "collection iteratorResult roots direct function bytecode value while creating result" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-collection-iterator-result-bytecode-symbol");
    const fb = try core.FunctionBytecode.createPublishedFixture(rt, .{ .cpool_count = 1 }, &.{try rt.takeSymbolValue(symbol_atom)});

    const result_value = core.JSValue.functionBytecode(&fb.header);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const iterator_result_value = try iteratorResult(rt, null, result_value, false);
    const iterator_result = try expectObject(iterator_result_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_atom = try rt.internAtom("value");
    {
        const stored = try iterator_result.getProperty(value_atom);
        try std.testing.expect(stored.same(result_value));
    }

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "Map groupBy roots direct symbol key while creating group array" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const map_value = try constructBare(rt, 1);
    const map = try expectObject(map_value);

    const callback = core.JSValue.undefinedValue();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-map-groupby-symbol-key");
    const item = try rt.takeSymbolValue(symbol_atom);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();

    try addGroupedItem(rt, map, callback, testCallbackHost(ctx), item, 0);
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    try std.testing.expectEqual(@as(usize, 1), map.collectionEntries().len);
    try std.testing.expect(map.collectionEntries()[0].key.same(item));

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn testCallbackHost(ctx: *core.JSContext) CallbackHost {
    return .{ .ctx = ctx, .call = testCallbackCallWithThis };
}

fn testCallbackCallWithThis(
    ctx: *core.JSContext,
    callback: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
) CallbackError!core.JSValue {
    _ = ctx;
    _ = callback;
    _ = this_value;
    _ = globals;
    std.debug.assert(args.len >= 1);
    return args[0];
}

fn collectionSize(object: *core.Object) !core.JSValue {
    if (object.class_id != core.class.ids.map and object.class_id != core.class.ids.set) return error.TypeError;
    return core.JSValue.int32(@intCast(strongSize(object)));
}

fn collectionForEach(
    object: *core.Object,
    args: []const core.JSValue,
    host: CallbackHost,
) !core.JSValue {
    if (object.class_id != core.class.ids.map and object.class_id != core.class.ids.set) return error.TypeError;
    if (args.len < 1 or !call_runtime.isCallableValue(args[0])) return error.TypeError;
    const this_arg = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    // js_map_forEach locks the current record for the
    // duration of the callback and only then advances. zjs walks by index, so
    // the lock is on the entry array: the callback may delete entries, but the
    // slots must not shift under the cursor.
    object.retainCollectionCursor();
    defer object.releaseCollectionCursor();
    var index: usize = 0;
    while (index < object.collectionEntriesSlot().items.len) {
        const entry = object.collectionEntriesSlot().items[index];
        index += 1;
        if (!entry.active) continue;
        // "must duplicate in case the record is deleted":
        // the callback can delete this entry. Under the tracing GC the copy is
        // not a retain, it is the read-before-callback that keeps the pair
        // stable -- the entry slot itself may be cleared while the callback
        // runs, and `callback_args` is what keeps the values reachable.
        const key = entry.key;
        const value = if (object.class_id == core.class.ids.set) key else entry.value;
        var callback_args = [_]core.JSValue{ value, key, object.value() };
        _ = try host.callWithThis(args[0], this_arg, &callback_args);
    }
    return core.JSValue.undefinedValue();
}

fn mapGetOrInsert(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue, value: core.JSValue) !core.JSValue {
    if (object.class_id == core.class.ids.weakmap) {
        const key_identity = (try weakKeyIdentityRegister(rt, key)) orelse return error.TypeError;
        if (findWeakEntry(object, key_identity)) |index| return object.weakCollectionEntriesSlot().items[index].value;
        const entry = core.object.WeakCollectionEntry{ .key_identity = key_identity, .value = value };
        try appendWeakEntry(rt, object, entry);
        return value;
    }

    if (object.class_id != core.class.ids.map) return error.TypeError;
    const canonical_key = canonicalizeKey(key);
    if (findStrongEntry(object, canonical_key)) |index| return object.collectionEntriesSlot().items[index].value;
    const entry = core.object.CollectionEntry{ .key = canonical_key, .value = value };
    try appendStrongEntryOwned(rt, object, entry);
    return value;
}

fn mapGetOrInsertComputed(
    rt: *core.JSRuntime,
    object: *core.Object,
    key: core.JSValue,
    callback: core.JSValue,
    host: CallbackHost,
) !core.JSValue {
    if (!call_runtime.isCallableValue(callback)) return error.TypeError;
    if (object.class_id == core.class.ids.weakmap) {
        const key_identity = (try weakKeyIdentityRegister(rt, key)) orelse return error.TypeError;
        if (findWeakEntry(object, key_identity)) |index| return object.weakCollectionEntriesSlot().items[index].value;
        var callback_args = [_]core.JSValue{key};
        const value = try host.callValue(callback, &callback_args);
        // A record the callback inserted is overwritten in place (see below).
        try setWeakMapEntryByIdentityChecked(rt, object, key_identity, value);
        return value;
    }

    if (object.class_id != core.class.ids.map) return error.TypeError;
    const canonical_key = canonicalizeKey(key);
    if (findStrongEntry(object, canonical_key)) |index| return object.collectionEntriesSlot().items[index].value;
    var callback_args = [_]core.JSValue{canonical_key};
    const value = try host.callValue(callback, &callback_args);
    // Spec step 7: a record the callback inserted for this key keeps its
    // position and takes the computed value. QuickJS deletes and re-appends
    // it at the iteration tail instead (js_map_getOrInsert).
    try mapSetNoResult(rt, object, canonical_key, value);
    return value;
}

fn canonicalizeKey(key: core.JSValue) core.JSValue {
    if (key.as(.float64)) |number| {
        if (number == 0) return core.JSValue.int32(0);
    }
    return key;
}

fn collectionHas(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue) !core.JSValue {
    if (object.class_id == core.class.ids.weakmap or object.class_id == core.class.ids.weakset) {
        const key_identity = weakKeyIdentityPeek(rt, key) orelse return core.JSValue.boolean(false);
        return core.JSValue.boolean(findWeakEntry(object, key_identity) != null);
    }
    if (object.class_id == core.class.ids.map or object.class_id == core.class.ids.set) {
        return core.JSValue.boolean(findStrongEntry(object, key) != null);
    }
    return error.TypeError;
}

fn collectionDelete(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue) !core.JSValue {
    return core.JSValue.boolean(try collectionDeleteBool(rt, object, key));
}

fn collectionDeleteNoResult(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue) !void {
    _ = try collectionDeleteBool(rt, object, key);
}

fn collectionDeleteBool(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue) !bool {
    if (object.class_id == core.class.ids.weakmap or object.class_id == core.class.ids.weakset) {
        const key_identity = weakKeyIdentityPeek(rt, key) orelse return false;
        const index = findWeakEntry(object, key_identity) orelse return false;
        try removeWeakEntry(rt, object, index);
        return true;
    }

    if (object.class_id != core.class.ids.map and object.class_id != core.class.ids.set) return error.TypeError;
    const index = findStrongEntry(object, key) orelse return false;
    removeStrongEntry(rt, object, index);
    return true;
}

fn collectionClear(rt: *core.JSRuntime, object: *core.Object) !core.JSValue {
    if (object.class_id == core.class.ids.map or object.class_id == core.class.ids.set) {
        clearStrongEntries(object);
        return core.JSValue.undefinedValue();
    }
    if (object.class_id == core.class.ids.weakmap or object.class_id == core.class.ids.weakset) {
        clearWeakEntries(rt, object);
        return core.JSValue.undefinedValue();
    }
    return error.TypeError;
}

fn setAdd(rt: *core.JSRuntime, object: *core.Object, value: core.JSValue) !core.JSValue {
    try setAddNoResult(rt, object, value);
    return object.value();
}

fn setAddNoResult(rt: *core.JSRuntime, object: *core.Object, value: core.JSValue) !void {
    if (object.class_id == core.class.ids.weakset) {
        const key_identity = (try weakKeyIdentityRegister(rt, value)) orelse return error.TypeError;
        if (findWeakEntry(object, key_identity) == null) {
            const entry = core.object.WeakCollectionEntry{ .key_identity = key_identity, .value = core.JSValue.undefinedValue() };
            try appendWeakEntry(rt, object, entry);
        }
        return;
    }

    if (object.class_id != core.class.ids.set) return error.TypeError;
    const canonical_value = canonicalizeKey(value);
    if (findStrongEntry(object, canonical_value) == null) {
        const entry = core.object.CollectionEntry{ .key = canonical_value, .value = core.JSValue.undefinedValue() };
        try appendStrongEntryOwned(rt, object, entry);
    }
}

fn freeValueList(rt: *core.JSRuntime, values: []core.JSValue) void {
    rt.nativeAllocator().free(values);
}

fn addGroupedItem(
    rt: *core.JSRuntime,
    map: *core.Object,
    callback: core.JSValue,
    host: CallbackHost,
    item: core.JSValue,
    index: u32,
) !void {
    // map, callback, callback arguments, key, group. Pass the registered
    // argument slots themselves so a collection can update the caller's item.
    var values = [_]core.JSValue{
        map.value(),                   callback,                      item, core.JSValue.int32(@intCast(index)),
        core.JSValue.undefinedValue(), core.JSValue.undefinedValue(),
    };
    const slots: []core.JSValue = &values;
    const slices = [_]core.runtime.ValueRootSlice{.{ .mutable = &slots }};
    var root_frame = core.runtime.ValueRootFrame{ .slices = &slices };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    values[4] = try host.callValue(values[1], values[2..4]);

    values[5] = try mapGet(rt, try expectObject(values[0]), values[4]);
    if (!values[5].is(.undefined_value)) {
        try appendArrayValue(rt, try expectObject(values[5]), values[2]);
        return;
    }

    values[5] = (try core.Object.createArray(rt, null)).value();
    try appendArrayValue(rt, try expectObject(values[5]), values[2]);
    // Entry publication passes snapshots through storage growth. Keep those
    // snapshots stable for that call, then release the pins with this frame.
    const publish = [_]core.JSValue{ values[0], values[4], values[5] };
    const publish_slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &publish }};
    var publish_roots = core.runtime.ValueRootFrame{ .slices = &publish_slices };
    publish_roots.activate(rt);
    defer publish_roots.deactivate(rt);
    _ = try mapSet(rt, try expectObject(publish[0]), publish[1], publish[2]);
}

fn appendArrayValue(rt: *core.JSRuntime, array: *core.Object, value: core.JSValue) !void {
    if (!array.isArray()) return error.TypeError;
    const snapshots = [_]core.JSValue{ array.value(), value };
    const slices = [_]core.runtime.ValueRootSlice{.{ .borrowed = &snapshots }};
    var roots = core.runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    try array.defineOwnProperty(rt, core.Atom.taggedInt(array.arrayLength()), core.Descriptor.data(value, .all));
}

fn stringElementAt(rt: *core.JSRuntime, string_value: core.JSValue, index: *usize) !core.JSValue {
    // Copy at most two units before allocating. No borrowed leaf or iterator
    // survives either this allocation or the grouping callback.
    const first = core.string.stringValueCodeUnitAtUnchecked(string_value, index.*);
    index.* += 1;
    if (unicode.isHighSurrogateUnit(first) and index.* < core.string.stringValueLenUnchecked(string_value)) {
        const second = core.string.stringValueCodeUnitAtUnchecked(string_value, index.*);
        if (unicode.isLowSurrogateUnit(second)) {
            index.* += 1;
            const units = [_]u16{ first, second };
            const out = try core.string.String.createUtf16(rt, &units);
            return out.value();
        }
    }
    const units = [_]u16{first};
    const out = try core.string.String.createUtf16(rt, &units);
    return out.value();
}

// Map/Set/WeakMap/WeakSet hash + index backend relocated to engine core
// (`core/collection.zig`) in Phase 6b-3 STEP 7A: the strong/weak entry hashing,
// bucket index linking/growth, entry append/take/rollback, weak-key identity
// resolution, and weak sweep are pure `core.Object` storage-slot operations with
// zero exec/VM dependence. Local aliases keep the method bodies short.
const collection_core = core.collection;
const findStrongEntry = collection_core.findStrongEntry;
const strongSize = collection_core.strongSize;
const findWeakEntry = collection_core.findWeakEntry;
const appendStrongEntryOwned = collection_core.appendStrongEntryOwned;
const appendWeakEntry = collection_core.appendWeakEntry;
const removeStrongEntry = collection_core.removeStrongEntry;
const removeWeakEntry = collection_core.removeWeakEntry;
const clearStrongEntries = collection_core.clearStrongEntries;
const clearWeakEntries = collection_core.clearWeakEntries;
const weakKeyIdentityRegister = collection_core.weakKeyIdentityRegister;
const weakKeyIdentityPeek = collection_core.weakKeyIdentityPeek;

fn collectionClassId(kind: u32) ?core.ClassId {
    return switch (kind) {
        1 => core.class.ids.map,
        2 => core.class.ids.set,
        3 => core.class.ids.weakmap,
        4 => core.class.ids.weakset,
        else => null,
    };
}

/// Own-method variant used by the prototype-less legacy `construct` path:
/// create the named method and stamp it with its `.collection` native-record
/// id so calls dispatch through the integer record mechanism.
fn defineNativeMethodWithRecordId(realm: *core.RealmContext, object: *core.Object, key: core.Atom, length: i32) !void {
    const name = core.atom.predefinedName(key);
    const rt = realm.runtime;
    const method = try function_builtin.nativeFunction(realm, name, length);
    const method_object = try expectObject(method);
    const id = prototypeMethodId(name) orelse return error.TypeError;
    method_object.nativeFunctionIdSlot().* = core.function.nativeBuiltinId(.collection, id);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(method, .method));
}

fn defineNativeMethods(realm: *core.RealmContext, object: *core.Object, class_id: core.ClassId) !void {
    switch (class_id) {
        core.class.ids.map, core.class.ids.weakmap => {
            try defineNativeMethodWithRecordId(realm, object, core.atom.ids.set, 2);
            try defineNativeMethodWithRecordId(realm, object, core.atom.ids.get, 1);
            try defineNativeMethodWithRecordId(realm, object, core.atom.ids.has, 1);
            try defineNativeMethodWithRecordId(realm, object, core.atom.ids.delete, 1);
            if (class_id == core.class.ids.map) {
                try defineNativeMethodWithRecordId(realm, object, core.atom.ids.clear, 0);
                try defineNativeMethodWithRecordId(realm, object, core.atom.ids.keys, 0);
                try defineNativeMethodWithRecordId(realm, object, core.atom.ids.values, 0);
                try defineNativeMethodWithRecordId(realm, object, core.atom.ids.entries, 0);
                try defineNativeMethodWithRecordId(realm, object, core.atom.ids.forEach, 1);
                try defineNativeMethodWithRecordId(realm, object, core.atom.ids.getOrInsert, 2);
                try defineNativeMethodWithRecordId(realm, object, core.atom.ids.getOrInsertComputed, 2);
            } else {
                try defineNativeMethodWithRecordId(realm, object, core.atom.ids.getOrInsert, 2);
                try defineNativeMethodWithRecordId(realm, object, core.atom.ids.getOrInsertComputed, 2);
            }
        },
        core.class.ids.set, core.class.ids.weakset => {
            try defineNativeMethodWithRecordId(realm, object, core.atom.ids.add, 1);
            try defineNativeMethodWithRecordId(realm, object, core.atom.ids.has, 1);
            try defineNativeMethodWithRecordId(realm, object, core.atom.ids.delete, 1);
            if (class_id == core.class.ids.set) {
                try defineNativeMethodWithRecordId(realm, object, core.atom.ids.clear, 0);
                try defineNativeMethodWithRecordId(realm, object, core.atom.ids.keys, 0);
                try defineNativeMethodWithRecordId(realm, object, core.atom.ids.values, 0);
                try defineNativeMethodWithRecordId(realm, object, core.atom.ids.entries, 0);
                try defineNativeMethodWithRecordId(realm, object, core.atom.ids.forEach, 1);
            }
        },
        else => {},
    }
}

const expectObject = core.value_semantics.expectObject;

// === Realm-aware Map/Set/WeakMap method bodies (relocated from exec) ===
//
// QuickJS client model (Phase 6b): the realm-sensitive collection method
// bodies that drive user callbacks through the VM (forEach, getOrInsertComputed,
// Map.groupBy) and the Set-composition/comparison algorithms that iterate
// foreign set-like objects live here, alongside the declaration table and the
// primitive strong/weak implementations above. They were previously stranded in
// `exec/array_ops.zig`; they import the exec VM ops (`call_runtime`/
// `value_ops`/`object_ops`/`exception_ops`) directly. The VM caller pair stays
// type-erased through `builtin_dispatch` (no `src/bytecode.zig` import). The
// `.collection` record handler (`collectionCall`) calls these; the weak-key
// registry / GC interaction stays in `core` (`Object.weakIdentityFromValue`).

const SetLikeRecordVm = struct {
    object_value: core.JSValue,
    size: i64,
    has: core.JSValue,
    keys: core.JSValue,
};

const ValueListRoot = struct {
    rt: ?*core.JSRuntime = null,
    slices: [1]core.runtime.ValueRootSlice = undefined,
    frame: core.runtime.ValueRootFrame = .{},

    fn init(self: *ValueListRoot, rt: *core.JSRuntime, values: *[]core.JSValue) void {
        self.rt = rt;
        self.slices[0] = .{ .mutable = values };
        self.frame = .{
            .slices = &self.slices,
        };
        self.frame.activate(rt);
    }

    fn deinit(self: *ValueListRoot) void {
        const rt = self.rt orelse return;
        self.frame.deactivate(rt);
        self.rt = null;
    }
};

fn collectionNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    const receiver = object_ops.objectFromValue(this_value) orelse {
        if (collectionMethodOwnerClass(function_object)) |owner_class| {
            return @as(?core.JSValue, try throwCollectionReceiverTypeError(ctx, global, owner_class));
        }
        return error.TypeError;
    };
    if (collectionMethodOwnerClass(function_object)) |owner_class| {
        if (receiver.class_id != owner_class) return @as(?core.JSValue, try throwCollectionReceiverTypeError(ctx, global, owner_class));
    }

    const method = std.enums.fromInt(PrototypeMethod, id) orelse return null;

    if (builtin_dispatch.callerResultIsDropped(caller_function, caller_frame)) {
        const handled = methodCallDroppedResult(ctx.runtime, receiver, id, args) catch |err| switch (err) {
            error.TypeError => return @as(?core.JSValue, try throwCollectionMethodTypeError(ctx, global, receiver, method, args)),
            else => return err,
        };
        if (handled) return core.JSValue.undefinedValue();
    }

    return switch (method) {
        .set,
        .get,
        .has,
        .delete,
        .clear,
        .add,
        .keys,
        .values,
        .entries,
        .get_or_insert,
        .size_getter,
        => methodCallObjectWithGlobal(ctx, global, receiver, id, args, &.{}) catch |err| switch (err) {
            error.TypeError => return @as(?core.JSValue, try throwCollectionMethodTypeError(ctx, global, receiver, method, args)),
            else => err,
        },
        .for_each => try collectionForEachRecord(ctx, output, global, receiver, args, caller_function, caller_frame),
        .get_or_insert_computed => try mapGetOrInsertComputedCall(ctx, output, global, this_value, function_object, args, caller_function, caller_frame),
        .difference,
        .intersection,
        .is_disjoint_from,
        .is_subset_of,
        .is_superset_of,
        .symmetric_difference,
        .union_,
        => try setMethodRecord(ctx, output, global, receiver, method, args, caller_function, caller_frame),
        .iterator_next => {
            // collectionIteratorNext checks the iterator class. Route through the realm-carrying entry like every other arm
            // here. The global-less `methodCall` used to be enough because
            // this file built iterator results with a null prototype; now
            // that they go through the single `CreateIterResultObject` owner,
            // dropping the realm on the floor would hand back a
            // null-prototype result object.
            return try methodCallObjectWithGlobal(ctx, global, receiver, id, args, &.{});
        },
    };
}

fn collectionForEachRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    if (receiver.class_id != core.class.ids.map and receiver.class_id != core.class.ids.set) return throwCollectionReceiverTypeError(ctx, global, receiver.class_id);
    if (args.len < 1 or !call_runtime.isCallableValue(args[0])) return error.NotAFunction;
    const callback = args[0];
    const this_arg = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    var callback_call = CallSite.initInternal(
        ctx,
        output,
        global,
        this_arg,
        callback,
        caller_function,
        caller_frame,
    );
    callback_call.activateRoots();
    defer callback_call.deinit();
    // Same record lock + argument duplication as js_map_forEach
    receiver.retainCollectionCursor();
    defer receiver.releaseCollectionCursor();
    var index: usize = 0;
    while (index < receiver.collectionEntriesSlot().items.len) : (index += 1) {
        const entry = receiver.collectionEntriesSlot().items[index];
        if (!entry.active) continue;
        const key = entry.key;
        const value = if (receiver.class_id == core.class.ids.set) key else entry.value;
        const callback_args = [_]core.JSValue{ value, key, receiver.value() };
        _ = try callback_call.call(&callback_args);
    }
    return core.JSValue.undefinedValue();
}

fn setMethodRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    method: PrototypeMethod,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    if (receiver.class_id != core.class.ids.set) return throwCollectionReceiverTypeError(ctx, global, core.class.ids.set);
    const other_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const other_record = try getSetRecord(ctx, output, global, other_value, caller_function, caller_frame);
    // Keep entry indices stable across the set-like has/keys user calls.
    receiver.retainCollectionCursor();
    defer receiver.releaseCollectionCursor();
    return switch (method) {
        .difference => try setDifference(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .intersection => try setIntersection(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_disjoint_from => try setIsDisjointFrom(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_subset_of => try setIsSubsetOf(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_superset_of => try setIsSupersetOf(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .symmetric_difference => try setSymmetricDifference(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .union_ => try setUnion(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        else => unreachable, // collectionNativeRecord routes only the set methods here
    };
}

fn getSetRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    other_value: core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !SetLikeRecordVm {
    if (object_ops.objectFromValue(other_value) == null) {
        _ = try exception_ops.throwTypeErrorMessage(ctx, global, "not an object");
        unreachable;
    }
    // GetSetRecord step 2 reads `size` observably even for a native Set:
    // a getter on the instance or Set.prototype runs. QuickJS reads the
    // internal record count for a native Set (get_set_record).
    const raw_size = try object_ops.getValueProperty(ctx, output, global, other_value, core.atom.predefinedId("size", .string).?, caller_function, caller_frame);
    const size_value = if (raw_size.is(.object))
        try value_ops.toPrimitiveForNumber(ctx, output, global, raw_size)
    else
        raw_size;
    const number_value = try value_ops.toNumberValue(ctx.runtime, size_value);
    const size_number = value_ops.numberValue(number_value) orelse return error.TypeError;
    if (std.math.isNan(size_number)) {
        _ = try exception_ops.throwTypeErrorMessage(ctx, global, ".size is not a number");
        unreachable;
    }
    // ToIntegerOrInfinity truncates toward zero, so only values <= -1 are
    // negative integers.
    if (size_number <= -1) {
        _ = try exception_ops.throwRangeErrorMessage(ctx, global, ".size must be positive");
        unreachable;
    }
    // Saturate +Infinity and huge sizes: maxInt(i64) is not representable in
    // f64, and 0x1p63 is the first f64 past it.
    const size: i64 = if (size_number >= 0x1p63) std.math.maxInt(i64) else @intFromFloat(size_number);

    const has_value = try object_ops.getValueProperty(ctx, output, global, other_value, core.atom.ids.has, caller_function, caller_frame);
    if (has_value.is(.undefined_value)) {
        _ = try exception_ops.throwTypeErrorMessage(ctx, global, ".has is undefined");
        unreachable;
    }
    if (!call_runtime.isCallableValue(has_value)) {
        _ = try exception_ops.throwTypeErrorMessage(ctx, global, ".has is not a function");
        unreachable;
    }

    const keys_value = try object_ops.getValueProperty(ctx, output, global, other_value, core.atom.ids.keys, caller_function, caller_frame);
    if (keys_value.is(.undefined_value)) {
        _ = try exception_ops.throwTypeErrorMessage(ctx, global, ".keys is undefined");
        unreachable;
    }
    if (!call_runtime.isCallableValue(keys_value)) {
        _ = try exception_ops.throwTypeErrorMessage(ctx, global, ".keys is not a function");
        unreachable;
    }

    return .{
        .object_value = other_value,
        .size = size,
        .has = has_value,
        .keys = keys_value,
    };
}

fn constructPlainSet(ctx: *core.JSContext) !core.JSValue {
    const set_proto = ctx.classPrototypeObject(core.class.ids.set) orelse return error.InvalidBuiltinRegistry;
    return constructWithPrototype(ctx.runtime, 2, set_proto);
}

fn setAddValue(rt: *core.JSRuntime, set_value: core.JSValue, key: core.JSValue) !void {
    _ = try methodCall(rt, set_value, @intFromEnum(PrototypeMethod.add), &.{key});
}

fn setDeleteValue(rt: *core.JSRuntime, set_value: core.JSValue, key: core.JSValue) !void {
    _ = try methodCall(rt, set_value, @intFromEnum(PrototypeMethod.delete), &.{key});
}

fn setHasValue(rt: *core.JSRuntime, set_value: core.JSValue, key: core.JSValue) !bool {
    const out = try methodCall(rt, set_value, @intFromEnum(PrototypeMethod.has), &.{key});
    return value_ops.valueTruthy(out);
}

fn setLikeHasCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    record: SetLikeRecordVm,
    key: core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !bool {
    // Mirrors js_set_isSubsetOf and friends: the record's
    // retrieved `has` is JS_Call'ed for every argument kind, native Sets
    // included.
    const out = try call_runtime.callValueOrBytecodeSyncInternalOutlined(
        ctx,
        output,
        global,
        record.object_value,
        record.has,
        &.{key},
        caller_function,
        caller_frame,
    );
    return value_ops.valueTruthy(out);
}

fn setLikeKeysIterator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    record: SetLikeRecordVm,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !iterator_ops.IteratorRecord {
    // GetIteratorFromMethod(set, keys): the record's retrieved `keys` is
    // called for every argument kind, native Sets/Maps included.
    const source = try call_runtime.callValueOrBytecodeSyncInternalOutlined(
        ctx,
        output,
        global,
        record.object_value,
        record.keys,
        &.{},
        caller_function,
        caller_frame,
    );
    return iterator_ops.getIteratorDirect(ctx, output, global, source, caller_function, caller_frame);
}

/// A copy of the receiver's [[SetData]]. The keys are already distinct and
/// normalized, so they append without a lookup; the copy calls no user code.
/// Hashes are recomputed: an object key's stored hash is stale once a minor
/// has moved it, until the receiver's next lookup refreshes its index.
fn setCloneReceiver(ctx: *core.JSContext, receiver: *core.Object) !core.JSValue {
    const result_value = try constructPlainSet(ctx);
    const result = core.value_semantics.objectFromValue(result_value).?;
    var index: usize = 0;
    while (index < receiver.collectionEntriesSlot().items.len) : (index += 1) {
        try ctx.runtime.pollNativeWork();
        const entry = receiver.collectionEntriesSlot().items[index];
        if (!entry.active) continue;
        try core.collection.appendStrongEntryOwned(ctx.runtime, result, .{ .key = entry.key, .value = entry.value });
    }
    return result_value;
}

fn setSnapshotKeys(rt: *core.JSRuntime, receiver: *core.Object) ![]core.JSValue {
    const count = strongSize(receiver);
    if (count == 0) return &.{};
    const keys = try rt.nativeAllocator().alloc(core.JSValue, count);
    errdefer rt.nativeAllocator().free(keys);
    var out: usize = 0;
    for (receiver.collectionEntriesSlot().items) |entry| {
        if (!entry.active) continue;
        keys[out] = entry.key;
        out += 1;
    }
    return keys;
}

test "set difference snapshot key root exposes dynamic key slice" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    var keys = try rt.nativeAllocator().alloc(core.JSValue, 1);
    const first_atom = try rt.atoms.newValueSymbol("gc-set-difference-snapshot-key");
    keys[0] = try rt.takeSymbolValue(first_atom);
    defer freeValueList(rt, keys);

    var keys_root = ValueListRoot{};
    keys_root.init(rt, &keys);
    defer keys_root.deinit();

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(first_atom) != null);
}

fn setDifference(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    const result_value = try constructPlainSet(ctx);
    if (@as(i64, @intCast(strongSize(receiver))) > other_record.size) {
        var copy_index: usize = 0;
        while (copy_index < receiver.collectionEntriesSlot().items.len) : (copy_index += 1) {
            const entry = receiver.collectionEntriesSlot().items[copy_index];
            if (!entry.active) continue;
            try setAddValue(ctx.runtime, result_value, entry.key);
        }
        const keys_iter = try setLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
        while (true) {
            const step = try iterator_ops.iteratorStepValue(ctx, output, global, keys_iter);
            if (step.done) break;
            try setDeleteValue(ctx.runtime, result_value, step.value);
        }
    } else {
        var keys = try setSnapshotKeys(ctx.runtime, receiver);
        defer freeValueList(ctx.runtime, keys);
        var keys_root = ValueListRoot{};
        keys_root.init(ctx.runtime, &keys);
        defer keys_root.deinit();
        for (keys) |key| {
            if (!try setLikeHasCall(ctx, output, global, other_record, key, caller_function, caller_frame)) {
                try setAddValue(ctx.runtime, result_value, key);
            }
        }
    }
    return result_value;
}

fn setIntersection(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    const result_value = try constructPlainSet(ctx);
    if (@as(i64, @intCast(strongSize(receiver))) <= other_record.size) {
        var index: usize = 0;
        while (index < receiver.collectionEntriesSlot().items.len) : (index += 1) {
            const entry = receiver.collectionEntriesSlot().items[index];
            if (!entry.active) continue;
            if (try setLikeHasCall(ctx, output, global, other_record, entry.key, caller_function, caller_frame)) {
                try setAddValue(ctx.runtime, result_value, entry.key);
            }
        }
    } else {
        const keys_iter = try setLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
        while (true) {
            const step = try iterator_ops.iteratorStepValue(ctx, output, global, keys_iter);
            if (step.done) break;
            if (try setHasValue(ctx.runtime, receiver.value(), step.value)) {
                try setAddValue(ctx.runtime, result_value, step.value);
            }
        }
    }
    return result_value;
}

fn setUnion(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    const keys_iter = try setLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
    const result_value = try setCloneReceiver(ctx, receiver);
    while (true) {
        const step = try iterator_ops.iteratorStepValue(ctx, output, global, keys_iter);
        if (step.done) break;
        try setAddValue(ctx.runtime, result_value, step.value);
    }
    return result_value;
}

fn setSymmetricDifference(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    const keys_iter = try setLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
    const result_value = try setCloneReceiver(ctx, receiver);
    while (true) {
        const step = try iterator_ops.iteratorStepValue(ctx, output, global, keys_iter);
        if (step.done) break;
        if (try setHasValue(ctx.runtime, receiver.value(), step.value)) {
            try setDeleteValue(ctx.runtime, result_value, step.value);
        } else if (!try setHasValue(ctx.runtime, result_value, step.value)) {
            try setAddValue(ctx.runtime, result_value, step.value);
        }
    }
    return result_value;
}

fn setIsDisjointFrom(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    if (@as(i64, @intCast(strongSize(receiver))) <= other_record.size) {
        var index: usize = 0;
        while (index < receiver.collectionEntriesSlot().items.len) : (index += 1) {
            const entry = receiver.collectionEntriesSlot().items[index];
            if (!entry.active) continue;
            if (try setLikeHasCall(ctx, output, global, other_record, entry.key, caller_function, caller_frame)) {
                return core.JSValue.boolean(false);
            }
        }
        return core.JSValue.boolean(true);
    }

    const keys_iter = try setLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
    while (true) {
        const step = try iterator_ops.iteratorStepValue(ctx, output, global, keys_iter);
        if (step.done) {
            return core.JSValue.boolean(true);
        }
        if (try setHasValue(ctx.runtime, receiver.value(), step.value)) {
            try iterator_ops.iteratorClose(ctx, output, global, keys_iter.iterator, null, null);
            return core.JSValue.boolean(false);
        }
    }
}

fn setIsSubsetOf(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    if (@as(i64, @intCast(strongSize(receiver))) > other_record.size) return core.JSValue.boolean(false);
    var index: usize = 0;
    while (index < receiver.collectionEntriesSlot().items.len) : (index += 1) {
        const entry = receiver.collectionEntriesSlot().items[index];
        if (!entry.active) continue;
        if (!try setLikeHasCall(ctx, output, global, other_record, entry.key, caller_function, caller_frame)) {
            return core.JSValue.boolean(false);
        }
    }
    return core.JSValue.boolean(true);
}

fn setIsSupersetOf(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    if (@as(i64, @intCast(strongSize(receiver))) < other_record.size) return core.JSValue.boolean(false);
    const keys_iter = try setLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
    while (true) {
        const step = try iterator_ops.iteratorStepValue(ctx, output, global, keys_iter);
        if (step.done) {
            return core.JSValue.boolean(true);
        }
        if (!try setHasValue(ctx.runtime, receiver.value(), step.value)) {
            try iterator_ops.iteratorClose(ctx, output, global, keys_iter.iterator, null, null);
            return core.JSValue.boolean(false);
        }
    }
}

fn mapGroupByCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    if (args.len < 2 or !call_runtime.isCallableValue(args[1])) return error.NotAFunction;
    const map_proto = ctx.classPrototypeObject(core.class.ids.map) orelse return error.InvalidBuiltinRegistry;

    const map_value = try constructWithPrototype(ctx.runtime, 1, map_proto);

    const iterator = try iterator_ops.getIterator(ctx, output, global, args[0], caller_function, caller_frame);
    var callback_call = CallSite.initInternal(
        ctx,
        output,
        global,
        core.JSValue.undefinedValue(),
        args[1],
        caller_function,
        caller_frame,
    );
    callback_call.activateRoots();
    defer callback_call.deinit();

    var index: usize = 0;
    while (true) {
        const max_safe_integer: usize = 9007199254740991;
        if (index >= max_safe_integer) {
            try iterator_ops.iteratorCloseForThrow(ctx, output, global, iterator.iterator);
            return error.TypeError;
        }

        const step = try iterator_ops.iteratorStepValue(ctx, output, global, iterator);
        if (step.done) return map_value;

        const index_value = value_ops.numberToValue(@floatFromInt(index));
        const key = callback_call.call(&.{ step.value, index_value }) catch |err| {
            try iterator_ops.iteratorCloseForThrow(ctx, output, global, iterator.iterator);
            return err;
        };

        mapAppendGroupByValue(ctx, global, map_value, key, step.value) catch |err| {
            try iterator_ops.iteratorCloseForThrow(ctx, output, global, iterator.iterator);
            return err;
        };
        index += 1;
    }
}

fn mapGetOrInsertComputedCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    const receiver = core.value_semantics.objectFromValue(receiver_value) orelse return null;
    if (receiver.class_id != core.class.ids.weakmap and receiver.class_id != core.class.ids.map) return null;
    if (collectionMethodOwnerClass(function_object)) |owner_class| {
        if (receiver.class_id != owner_class) return @as(?core.JSValue, try throwCollectionReceiverTypeError(ctx, global, owner_class));
    }
    if (args.len < 2 or !call_runtime.isCallableValue(args[1])) return error.NotAFunction;

    const key = if (receiver.class_id == core.class.ids.map)
        canonicalizeKey(args[0])
    else
        args[0];
    if (receiver.class_id == core.class.ids.weakmap and !value_ops.canBeHeldWeakly(ctx.runtime, key)) {
        return @as(?core.JSValue, try exception_ops.throwTypeErrorMessage(ctx, global, "invalid value used as WeakMap key"));
    }

    const has_value = try methodCall(ctx.runtime, receiver_value, @intFromEnum(PrototypeMethod.has), &.{key});
    if (has_value.as(.boolean) == true) {
        return try methodCall(ctx.runtime, receiver_value, @intFromEnum(PrototypeMethod.get), &.{key});
    }

    const computed = try call_runtime.callValueOrBytecodeSyncInternalOutlined(
        ctx,
        output,
        global,
        core.JSValue.undefinedValue(),
        args[1],
        &.{key},
        caller_function,
        caller_frame,
    );
    // Spec step 7: `set` overwrites a record the callback inserted in place
    // (QuickJS deletes and re-appends it; see mapGetOrInsertComputed).
    _ = try methodCall(ctx.runtime, receiver_value, @intFromEnum(PrototypeMethod.set), &.{ key, computed });
    return computed;
}

fn collectionMethodOwnerClass(function_object: *core.Object) ?core.ClassId {
    const cached = function_object.collectionMethodOwnerClass();
    if (cached != core.class.invalid_class_id) return cached;
    return null;
}

fn throwCollectionReceiverTypeError(ctx: *core.JSContext, global: *core.Object, owner_class: core.ClassId) !core.JSValue {
    return exception_ops.throwTypeErrorMessage(ctx, global, collectionReceiverMessage(owner_class));
}

fn throwCollectionMethodTypeError(
    ctx: *core.JSContext,
    global: *core.Object,
    receiver: *core.Object,
    method: PrototypeMethod,
    args: []const core.JSValue,
) !core.JSValue {
    if (receiver.class_id == core.class.ids.weakmap and
        (method == .set or method == .get_or_insert or method == .get_or_insert_computed) and
        args.len >= 1 and !value_ops.canBeHeldWeakly(ctx.runtime, args[0]))
    {
        return exception_ops.throwTypeErrorMessage(ctx, global, "invalid value used as WeakMap key");
    }
    if (receiver.class_id == core.class.ids.weakset and
        method == .add and
        args.len >= 1 and !value_ops.canBeHeldWeakly(ctx.runtime, args[0]))
    {
        return exception_ops.throwTypeErrorMessage(ctx, global, "invalid value used in weak set");
    }
    return exception_ops.throwTypeErrorMessage(ctx, global, collectionReceiverMessage(receiver.class_id));
}

fn collectionReceiverMessage(owner_class: core.ClassId) []const u8 {
    if (owner_class == core.class.ids.map) return "Map object expected";
    if (owner_class == core.class.ids.set) return "Set object expected";
    if (owner_class == core.class.ids.weakmap) return "WeakMap object expected";
    if (owner_class == core.class.ids.weakset) return "WeakSet object expected";
    if (owner_class == core.class.ids.map_iterator) return "Map Iterator object expected";
    if (owner_class == core.class.ids.set_iterator) return "Set Iterator object expected";
    return "not an object";
}

fn mapAppendGroupByValue(
    ctx: *core.JSContext,
    global: *core.Object,
    map_value: core.JSValue,
    key: core.JSValue,
    value: core.JSValue,
) !void {
    const existing = try methodCall(ctx.runtime, map_value, @intFromEnum(PrototypeMethod.get), &.{key});

    if (!existing.is(.undefined_value)) {
        const group = try expectObject(existing);
        if (!group.isArray()) return error.TypeError;
        try group.defineOwnProperty(
            ctx.runtime,
            core.Atom.taggedInt(group.arrayLength()),
            core.Descriptor.data(value, .all),
        );
        return;
    }

    const group = try core.Object.createArray(ctx.runtime, array_ops.arrayPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, group.gcHeader());
    try group.defineOwnProperty(
        ctx.runtime,
        core.Atom.taggedInt(group.arrayLength()),
        core.Descriptor.data(value, .all),
    );
    _ = try methodCall(ctx.runtime, map_value, @intFromEnum(PrototypeMethod.set), &.{ key, group.value() });
}

// ----- Realm-aware collection callback adapter -----
// Realm-aware adapter for the core collection callback protocol.
//
// Callback, receiver, arguments, and legacy global slots are borrowed;
// successful heap results are owned by the caller. The explicit `JSContext`
// is the error realm authority: ordinary engine failures become a pending JS
// exception here, while only the seven hard/control outcomes cross the core
// callback seam. JS [[Call]] requires a Realm global (KD20); missing that is
// `InvalidBuiltinRegistry`, not a re-entry into `c_closure`.
pub fn callbackHost(ctx: *core.JSContext, globals: []globals_mod.Slot) CallbackHost {
    return .{
        .ctx = ctx,
        .globals = globals,
        .call = callCallbackWithThis,
    };
}

fn callCallbackWithThis(
    ctx: *core.JSContext,
    callback: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
) CallbackError!core.JSValue {
    const global = ctx.global orelse globalObjectFromGlobals(globals) orelse
        return narrowCallbackError(ctx, error.InvalidBuiltinRegistry);
    return call_runtime.callValueOrBytecodeRoot(
        ctx,
        null,
        global,
        this_value,
        callback,
        args,
        null,
        null,
    ) catch |err| return narrowCallbackError(ctx, err);
}

fn narrowCallbackError(ctx: *core.JSContext, err: anytype) CallbackError {
    return switch (@as(anyerror, err)) {
        error.OutOfMemory => error.OutOfMemory,
        error.Interrupted => error.Interrupted,
        error.ProcessExit => error.ProcessExit,
        error.StackOverflow => error.StackOverflow,
        error.Timeout => error.Timeout,
        error.UnhandledPromiseRejection => error.UnhandledPromiseRejection,
        error.JSException => if (ctx.hasException()) error.JSException else blk: {
            _ = builtin_dispatch.nativeFromHostError(ctx, ctx.global, err);
            break :blk error.JSException;
        },
        else => blk: {
            _ = builtin_dispatch.nativeFromHostError(ctx, ctx.global, err);
            break :blk error.JSException;
        },
    };
}
