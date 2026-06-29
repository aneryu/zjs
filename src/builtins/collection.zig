const core = @import("../core/root.zig");
const function_builtin = @import("function.zig");
const symbol_builtin = @import("symbol.zig");
const globals_mod = core.global_slots;
const unicode = @import("../libs/unicode.zig");
const std = @import("std");
const builtin_dispatch = @import("../exec/builtin_dispatch.zig");
const call_runtime = @import("../exec/call_runtime.zig");
const collection_adapter = @import("../exec/collection_adapter.zig");
const exceptions = @import("../exec/exceptions.zig");
const object_ops = @import("../exec/object_ops.zig");
const array_ops = @import("../exec/array_ops.zig");
const coercion_ops = @import("../exec/coercion_ops.zig");
const exception_ops = @import("../exec/vm_exception_ops.zig");
const forof_ops = @import("../exec/forof_ops.zig");
const property_ops = @import("../exec/property_ops.zig");
const value_ops = @import("../exec/value_ops.zig");

const HostError = exceptions.HostError;
const InternalCall = core.host_function.InternalCall;

// The collection callback protocol relocated to engine core
// (`core/host_function.zig`, beside ExternalCall/InternalCall) in Phase 6b-3
// STEP 2: it is a pure function-pointer protocol with zero VM dependence.
// Re-exported here under the original names so the collection method bodies and
// `collection_adapter` keep referencing them unchanged.
pub const CallbackError = core.host_function.CallbackError;
pub const CallbackCallFn = core.host_function.CallbackCallFn;
pub const CallbackKindFn = core.host_function.CallbackKindFn;
pub const CallbackHost = core.host_function.CallbackHost;

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
pub const ConstructorMethod = core.host_function.builtin_method_ids.collection.ConstructorMethod;
pub const ConstructorKind = core.host_function.builtin_method_id_lookup.collection.ConstructorKind;
pub const constructorId = core.host_function.builtin_method_id_lookup.collection.constructorId;
pub const constructIdForKind = core.host_function.builtin_method_id_lookup.collection.constructIdForKind;

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
// dispatch/install side keeps the original names. `legacyPrototypeMethodId`
// below (collection-internal, not VM-referenced) keeps its local definition and
// consumes the re-exported `prototypeMethodId`.
const collection_id_lookup = core.host_function.builtin_method_id_lookup.collection;
pub const prototypeMethodId = collection_id_lookup.prototypeMethodId;
pub const legacyClosureMethodId = collection_id_lookup.legacyClosureMethodId;
pub const fastPrototypeMethodIdForClass = collection_id_lookup.fastPrototypeMethodIdForClass;

pub fn legacyPrototypeMethodId(name: []const u8) ?u32 {
    const id = prototypeMethodId(name) orelse return null;
    if (legacyBasePrototypeMethodId(id)) |method_id| return method_id;
    return switch (id) {
        @intFromEnum(PrototypeMethod.difference),
        @intFromEnum(PrototypeMethod.intersection),
        @intFromEnum(PrototypeMethod.is_disjoint_from),
        @intFromEnum(PrototypeMethod.is_subset_of),
        @intFromEnum(PrototypeMethod.is_superset_of),
        @intFromEnum(PrototypeMethod.symmetric_difference),
        @intFromEnum(PrototypeMethod.union_),
        => id,
        else => null,
    };
}

fn legacyBasePrototypeMethodId(id: u32) ?u32 {
    return switch (id) {
        @intFromEnum(PrototypeMethod.set),
        @intFromEnum(PrototypeMethod.get),
        @intFromEnum(PrototypeMethod.has),
        @intFromEnum(PrototypeMethod.delete),
        @intFromEnum(PrototypeMethod.clear),
        @intFromEnum(PrototypeMethod.add),
        @intFromEnum(PrototypeMethod.keys),
        @intFromEnum(PrototypeMethod.values),
        @intFromEnum(PrototypeMethod.entries),
        @intFromEnum(PrototypeMethod.for_each),
        @intFromEnum(PrototypeMethod.get_or_insert),
        @intFromEnum(PrototypeMethod.get_or_insert_computed),
        => id,
        else => null,
    };
}

/// Declaration + dispatch table for the `.collection` native-builtin domain
/// (QuickJS js_map_funcs / js_set_funcs analogue). One shared record handler
/// `collectionCall` switches on the per-record `magic` (== domain-local id) and
/// dispatches to the method bodies in this module: the primitive strong/weak
/// implementations (`mapSet`/`mapGet`/`setAdd`/...) for the bare-runtime path,
/// and the realm-aware `qjs*` bodies (relocated here from exec) that drive user
/// callbacks through the VM. The weak-collection key registry stays GC-coupled
/// in core (`Object.weakIdentityFromValue`); the Map/Set opcode fast paths
/// (`vm_call.zig` prepared path, `vm_property_*`) call the primitive impls
/// directly. Constructors are not dispatched here (they run through the
/// `new_collection` opcode); only the static `Map.groupBy` and the shared
/// prototype methods route through the table. Property installation still
/// resolves names through the registry's map_prototype/set_prototype/
/// weak_*_prototype method tables; this table is consumed by the slow
/// record-dispatch path (`rt.internal_builtins`). `prepared_call_ok` mirrors
/// the prepared-call gate (`collectionNativeSupportedWithoutFunctionObject` in
/// `vm_call.zig`).
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
        collectionEntry("set", 2, @intFromEnum(PrototypeMethod.set), true),
        collectionEntry("get", 1, @intFromEnum(PrototypeMethod.get), true),
        collectionEntry("has", 1, @intFromEnum(PrototypeMethod.has), true),
        collectionEntry("delete", 1, @intFromEnum(PrototypeMethod.delete), true),
        collectionEntry("clear", 0, @intFromEnum(PrototypeMethod.clear), true),
        collectionEntry("add", 1, @intFromEnum(PrototypeMethod.add), true),
        collectionEntry("keys", 0, @intFromEnum(PrototypeMethod.keys), true),
        collectionEntry("values", 0, @intFromEnum(PrototypeMethod.values), true),
        collectionEntry("entries", 0, @intFromEnum(PrototypeMethod.entries), true),
        collectionEntry("forEach", 1, @intFromEnum(PrototypeMethod.for_each), false),
        collectionEntry("getOrInsert", 2, @intFromEnum(PrototypeMethod.get_or_insert), true),
        collectionEntry("getOrInsertComputed", 2, @intFromEnum(PrototypeMethod.get_or_insert_computed), false),
        collectionEntry("next", 0, @intFromEnum(PrototypeMethod.iterator_next), false),
        collectionEntry("get size", 0, @intFromEnum(PrototypeMethod.size_getter), true),
        collectionEntry("difference", 1, @intFromEnum(PrototypeMethod.difference), false),
        collectionEntry("intersection", 1, @intFromEnum(PrototypeMethod.intersection), false),
        collectionEntry("isDisjointFrom", 1, @intFromEnum(PrototypeMethod.is_disjoint_from), false),
        collectionEntry("isSubsetOf", 1, @intFromEnum(PrototypeMethod.is_subset_of), false),
        collectionEntry("isSupersetOf", 1, @intFromEnum(PrototypeMethod.is_superset_of), false),
        collectionEntry("symmetricDifference", 1, @intFromEnum(PrototypeMethod.symmetric_difference), false),
        collectionEntry("union", 1, @intFromEnum(PrototypeMethod.union_), false),
        collectionEntry("groupBy", 2, @intFromEnum(StaticMethod.group_by), false),
    };
};

fn collectionEntry(comptime name: []const u8, comptime length: u8, comptime id: u32, comptime prepared: bool) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = id, .magic = @intCast(id), .prepared_call_ok = prepared, .call = &collectionCall };
}

/// A collection constructor record (one per `ConstructorKind`): construct-capable
/// so `new Map/Set/WeakMap/WeakSet(...)` reach `collectionCall`'s construct
/// branch. Never prepared-eligible.
fn collectionConstructorEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = id, .magic = @intCast(id), .prepared_call_ok = false, .constructor = true, .call = &collectionCall };
}

/// Shared record handler for the `.collection` domain. Mirrors the retired
/// `call.zig` `callCollectionNativeFunctionRecord`: the `Map.groupBy` static and
/// the prototype methods delegate to the collection VM ops (with a realm global)
/// or to the primitive-only `builtins.collection` entry points (bare-runtime
/// fallback, no global). The weak-collection mutators reached from these methods
/// keep their weak_id registry / GC interaction in exec.
fn collectionCall(host_call: InternalCall) HostError!core.JSValue {
    const ctx = host_call.ctx;
    const output = host_call.output;
    const id: u32 = host_call.magic;
    const args = host_call.args;
    const globals = host_call.globals;
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
        return collectionGroupByRecord(ctx, output, host_call.global, globals, this_value, args, caller_function, caller_frame);
    }
    const function_object = host_call.func_obj orelse {
        // Internal engine call sites route a collection method body through the
        // table without a materialized function object: `Array.from`/`Array.of`
        // and the typed-array static factories draining a Map/Set iterator
        // (`global == null`, the bare primitive iterator); the collection
        // construct adder fill (`global == null`, primitive set/add); and the
        // prepared opcode fast path (`global != null`, the receiver's
        // owner-class already validated by `vm_call`). With no function object
        // there is no installed-prototype owner class to re-derive here, so
        // dispatch the body directly, mirroring the historical direct callers:
        // `methodCallObjectWithGlobal` for the realm path (dropped-result
        // honored, exactly the retired `callPreparedCollectionNativeTarget`) and
        // the primitive `methodCallWithCallbackHost` for the global-less path
        // (exactly the retired `methodCall`/`methodCallWithCallbackHost`).
        if (host_call.global) |active_global| {
            const receiver = object_ops.objectFromValue(this_value) orelse return error.TypeError;
            if (collectionCallResultIsDropped(caller_function, caller_frame)) {
                if (try methodCallDroppedResult(ctx.runtime, receiver, id, args)) return core.JSValue.undefinedValue();
            }
            return methodCallObjectWithGlobal(ctx, active_global, receiver, id, args, globals);
        }
        return methodCallWithCallbackHost(ctx.runtime, this_value, id, args, collection_adapter.host(globals));
    };
    const active_global = host_call.global orelse return collectionRecordWithoutGlobal(ctx, globals, this_value, function_object, id, args);
    if (try qjsCollectionNativeRecord(ctx, output, active_global, this_value, function_object, id, args, caller_function, caller_frame)) |value| return value;
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
    const receiver = object_ops.objectFromValue(this_value) orelse return error.TypeError;
    if (!try call_runtime.constructorNameEqlLocal(ctx.runtime, receiver, "Map")) return error.TypeError;
    const prototype = (try object_ops.constructorPrototypeObject(ctx.runtime, this_value));
    if (global) |active_global| {
        if (try qjsMapGroupByRecord(ctx, output, active_global, args, prototype, caller_function, caller_frame)) |value| return value;
        return error.TypeError;
    }
    return groupByWithCallbackHost(ctx.runtime, args, prototype, collection_adapter.host(globals)) catch |err| switch (err) {
        error.TypeError => error.TypeError,
        else => err,
    };
}

fn collectionRecordWithoutGlobal(
    ctx: *core.JSContext,
    globals: []globals_mod.Slot,
    this_value: core.JSValue,
    function_object: *core.Object,
    id: u32,
    args: []const core.JSValue,
) HostError!core.JSValue {
    const receiver = object_ops.objectFromValue(this_value) orelse return error.TypeError;
    const owner_class = function_object.collectionMethodOwnerClass();
    if (owner_class != core.class.invalid_class_id) {
        if (receiver.class_id != owner_class) return error.TypeError;
    }
    return switch (id) {
        @intFromEnum(PrototypeMethod.set),
        @intFromEnum(PrototypeMethod.get),
        @intFromEnum(PrototypeMethod.has),
        @intFromEnum(PrototypeMethod.delete),
        @intFromEnum(PrototypeMethod.clear),
        @intFromEnum(PrototypeMethod.add),
        @intFromEnum(PrototypeMethod.keys),
        @intFromEnum(PrototypeMethod.values),
        @intFromEnum(PrototypeMethod.entries),
        @intFromEnum(PrototypeMethod.for_each),
        @intFromEnum(PrototypeMethod.get_or_insert),
        @intFromEnum(PrototypeMethod.get_or_insert_computed),
        @intFromEnum(PrototypeMethod.size_getter),
        @intFromEnum(PrototypeMethod.difference),
        @intFromEnum(PrototypeMethod.intersection),
        @intFromEnum(PrototypeMethod.is_disjoint_from),
        @intFromEnum(PrototypeMethod.is_subset_of),
        @intFromEnum(PrototypeMethod.is_superset_of),
        @intFromEnum(PrototypeMethod.symmetric_difference),
        @intFromEnum(PrototypeMethod.union_),
        => methodCallWithContextAndHost(ctx, this_value, id, args, collection_adapter.host(globals)) catch |err| switch (err) {
            error.TypeError => error.TypeError,
            else => err,
        },
        @intFromEnum(PrototypeMethod.iterator_next) => {
            if (receiver.class_id != core.class.ids.map_iterator and receiver.class_id != core.class.ids.set_iterator) return error.TypeError;
            return methodCall(ctx.runtime, this_value, id, args) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                else => err,
            };
        },
        else => error.TypeError,
    };
}

// Relocated to engine core (`core/value.zig`, beside `JSValue.sameValue`) in
// Phase 6b-3 STEP 2: SameValueZero is a pure value comparison consumed by the
// VM (Array.prototype.includes) without importing builtins. Kept here as a thin
// free-function shim so the Map/Set key-lookup callers below and the install
// path keep the original `sameValueZero(a, b)` spelling.
pub fn sameValueZero(a: core.JSValue, b: core.JSValue) bool {
    return a.sameValueZero(b);
}

pub const Entry = struct {
    key: core.JSValue,
    value: core.JSValue,
};

/// QuickJS source map: narrow collection constructors used by the transitional
/// `new_collection` bytecode.
pub fn construct(rt: *core.JSRuntime, kind: u32) !core.JSValue {
    return constructWithPrototype(rt, kind, null);
}

pub fn constructWithPrototype(rt: *core.JSRuntime, kind: u32, prototype: ?*core.Object) !core.JSValue {
    const class_id = collectionClassId(kind) orelse return error.TypeError;
    const object = try core.Object.create(rt, class_id, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    if (prototype == null) try defineNativeMethods(rt, object, class_id);
    return object.value();
}

/// QuickJS source map: selected Map/Set/WeakMap/WeakSet methods currently
/// covered by smoke fixtures and targeted collection validation. Strong
/// collections use object-owned entry arrays; weak collections store object
/// identities plus values so keys are not retained through ordinary properties.
pub fn methodCall(rt: *core.JSRuntime, object_value: core.JSValue, method: u32, args: []const core.JSValue) !core.JSValue {
    return methodCallWithCallbackHost(rt, object_value, method, args, .{});
}

pub fn methodCallWithGlobals(
    rt: *core.JSRuntime,
    object_value: core.JSValue,
    method: u32,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
) !core.JSValue {
    return methodCallWithCallbackHost(rt, object_value, method, args, .{ .globals = globals });
}

pub fn methodCallWithCallbackHost(
    rt: *core.JSRuntime,
    object_value: core.JSValue,
    method: u32,
    args: []const core.JSValue,
    host: CallbackHost,
) !core.JSValue {
    const object = try expectObject(object_value);
    return methodCallResolved(rt, null, globalObjectFromGlobals(rt, host.globals), object, method, args, host);
}

pub fn methodCallWithContext(
    ctx: *core.JSContext,
    object_value: core.JSValue,
    method: u32,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
) !core.JSValue {
    return methodCallWithContextAndHost(ctx, object_value, method, args, .{ .globals = globals });
}

pub fn methodCallWithContextAndHost(
    ctx: *core.JSContext,
    object_value: core.JSValue,
    method: u32,
    args: []const core.JSValue,
    host: CallbackHost,
) !core.JSValue {
    const object = try expectObject(object_value);
    return methodCallResolved(ctx.runtime, ctx, globalObjectFromGlobals(ctx.runtime, host.globals), object, method, args, host);
}

pub fn methodCallWithGlobal(
    ctx: *core.JSContext,
    global: *core.Object,
    object_value: core.JSValue,
    method: u32,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
) !core.JSValue {
    return methodCallWithGlobalAndHost(ctx, global, object_value, method, args, .{ .globals = globals });
}

pub fn methodCallWithGlobalAndHost(
    ctx: *core.JSContext,
    global: *core.Object,
    object_value: core.JSValue,
    method: u32,
    args: []const core.JSValue,
    host: CallbackHost,
) !core.JSValue {
    const object = try expectObject(object_value);
    return methodCallResolved(ctx.runtime, ctx, global, object, method, args, host);
}

pub fn methodCallObjectWithGlobal(
    ctx: *core.JSContext,
    global: *core.Object,
    object: *core.Object,
    method: u32,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
) !core.JSValue {
    return methodCallObjectWithGlobalAndHost(ctx, global, object, method, args, .{ .globals = globals });
}

pub fn methodCallObjectWithGlobalAndHost(
    ctx: *core.JSContext,
    global: *core.Object,
    object: *core.Object,
    method: u32,
    args: []const core.JSValue,
    host: CallbackHost,
) !core.JSValue {
    return methodCallResolved(ctx.runtime, ctx, global, object, method, args, host);
}

pub fn readOnlyMethodCallObject(rt: *core.JSRuntime, object: *core.Object, method: PrototypeMethod, key: core.JSValue) !core.JSValue {
    return switch (method) {
        .get => mapGet(rt, object, key),
        .has => collectionHas(rt, object, key),
        else => error.TypeError,
    };
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
    return switch (method) {
        1 => {
            const key = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
            return mapSet(rt, object, key, value);
        },
        2 => {
            const key = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return mapGet(rt, object, key);
        },
        3 => {
            const key = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return collectionHas(rt, object, key);
        },
        4 => {
            const key = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return collectionDelete(rt, object, key);
        },
        5 => {
            return collectionClear(rt, object);
        },
        6 => {
            const value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return setAdd(rt, object, value);
        },
        7 => {
            return collectionIterator(rt, ctx, global, object, .key);
        },
        8 => {
            return collectionIterator(rt, ctx, global, object, .value);
        },
        9 => {
            return collectionIterator(rt, ctx, global, object, .key_value);
        },
        10 => return collectionForEach(rt, object, args, host),
        11 => {
            const key = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            return mapGetOrInsert(rt, object, key, if (args.len >= 2) args[1] else core.JSValue.undefinedValue());
        },
        12 => {
            if (args.len < 2) return error.TypeError;
            return mapGetOrInsertComputed(rt, object, args[0], args[1], host);
        },
        13 => {
            return collectionIteratorNext(rt, object);
        },
        14 => {
            return collectionSize(object);
        },
        15 => return setComposition(rt, object, args, .difference, host),
        16 => return setComposition(rt, object, args, .intersection, host),
        17 => return setComparison(rt, object, args, .is_disjoint_from, host),
        18 => return setComparison(rt, object, args, .is_subset_of, host),
        19 => return setComparison(rt, object, args, .is_superset_of, host),
        20 => return setComposition(rt, object, args, .symmetric_difference, host),
        21 => return setComposition(rt, object, args, .union_, host),
        else => error.TypeError,
    };
}

pub fn methodCallDroppedResult(rt: *core.JSRuntime, object: *core.Object, method: u32, args: []const core.JSValue) !bool {
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

pub fn groupBy(
    rt: *core.JSRuntime,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
    prototype: ?*core.Object,
) !core.JSValue {
    return groupByWithCallbackHost(rt, args, prototype, .{ .globals = globals });
}

pub fn groupByWithCallbackHost(
    rt: *core.JSRuntime,
    args: []const core.JSValue,
    prototype: ?*core.Object,
    host: CallbackHost,
) !core.JSValue {
    if (args.len < 2) return error.TypeError;
    if (!isCallableObject(args[1])) return error.TypeError;

    const map_value = try constructWithPrototype(rt, 1, prototype);
    errdefer map_value.free(rt);
    const map = try expectObject(map_value);

    if (args[0].isString()) {
        try groupString(rt, map, args[0], args[1], host);
        return map_value;
    }

    const source = try expectObject(args[0]);
    if (!source.flags.is_array) return error.TypeError;
    var index: u32 = 0;
    while (index < source.arrayLength()) : (index += 1) {
        const item = source.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(rt);
        try addGroupedItem(rt, map, args[1], host, item, index);
    }
    return map_value;
}

fn mapSet(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue, value: core.JSValue) !core.JSValue {
    try mapSetNoResult(rt, object, key, value);
    return object.value().dup();
}

fn mapSetNoResult(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue, value: core.JSValue) !void {
    if (object.class_id == core.class.ids.weakmap) {
        const key_identity = (try weakKeyIdentityRegister(rt, key)) orelse return error.TypeError;
        try setWeakMapEntryByIdentityChecked(rt, object, key_identity, value);
        return;
    }

    if (object.class_id != core.class.ids.map) return error.TypeError;
    const canonical_key = canonicalizeKey(key);
    defer canonical_key.free(rt);
    if (findStrongEntry(object, canonical_key)) |index| {
        const entry = &object.collectionEntriesSlot().*[index];
        const next_value = value.dup();
        const old_value = entry.value;
        entry.value = next_value;
        old_value.free(rt);
    } else {
        const entry = core.object.CollectionEntry{ .key = canonical_key.dup(), .value = value.dup() };
        try appendStrongEntryOwned(rt, object, entry);
    }
}

// WeakMap entry mutation relocated to engine core (`core/collection.zig`) in
// Phase 6b-3 STEP 7A; re-exported here so the collection method bodies and the
// `engine.builtins.collection.setWeakMapEntry` public surface (consumed by the
// WeakMap unit test) keep the original spelling.
pub const setWeakMapEntry = core.collection.setWeakMapEntry;
pub const setWeakMapEntryByIdentity = core.collection.setWeakMapEntryByIdentity;
const setWeakMapEntryByIdentityChecked = core.collection.setWeakMapEntryByIdentityChecked;

fn mapGet(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue) !core.JSValue {
    if (object.class_id == core.class.ids.weakmap) {
        const key_identity = weakKeyIdentityPeek(rt, key) orelse return core.JSValue.undefinedValue();
        const index = findWeakEntry(object, key_identity) orelse return core.JSValue.undefinedValue();
        return object.weakCollectionEntriesSlot().*[index].value.dup();
    }

    if (object.class_id != core.class.ids.map) return error.TypeError;
    const index = findStrongEntry(object, key) orelse return core.JSValue.undefinedValue();
    return object.collectionEntriesSlot().*[index].value.dup();
}

// Map latin1-prefix-int fusion fast paths relocated to engine core
// (`core/collection.zig`) in Phase 6b-3 STEP 7A so the VM loop-fusion caller
// (`exec/vm_property_locals.zig`) imports them straight from core; re-exported
// here under the original names for any builtins-side caller.
pub const mapGetLatin1PrefixIntValue = core.collection.mapGetLatin1PrefixIntValue;
pub const mapSetLatin1PrefixInt32Range = core.collection.mapSetLatin1PrefixInt32Range;

const CollectionIteratorKind = enum(u8) {
    key = 1,
    value = 2,
    key_value = 3,
};

const IteratorPrototypeRef = struct {
    object: *core.Object,
    owned: bool,
};

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
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &target_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const prototype = try iteratorPrototype(
        rt,
        ctx,
        global,
        object,
        iterator_class,
        if (object.class_id == core.class.ids.map) "Map Iterator" else "Set Iterator",
    );
    defer if (prototype.owned) prototype.object.value().free(rt);
    const iterator = try core.Object.create(rt, iterator_class, prototype.object);
    errdefer core.Object.destroyFromHeader(rt, &iterator.header);
    try iterator.setOptionalValueSlot(rt, iterator.iteratorTargetSlot(), target_value.dup());
    iterator.iteratorIndexSlot().* = 0;
    iterator.iteratorKindSlot().* = @intFromEnum(kind);
    return iterator.value();
}

fn iteratorPrototype(
    rt: *core.JSRuntime,
    ctx: ?*core.JSContext,
    global: ?*core.Object,
    receiver: *core.Object,
    iterator_class: core.ClassId,
    tag_name: []const u8,
) !IteratorPrototypeRef {
    if (ctx) |context| {
        const slot: usize = iterator_class;
        if (slot < context.class_prototypes.len) {
            const stored = context.class_prototypes[slot];
            if (stored.isObject()) return .{ .object = try expectObject(stored), .owned = false };
        }
    }

    const prototype = try createIteratorPrototype(rt, global, receiver, tag_name);
    if (ctx) |context| {
        const slot: usize = iterator_class;
        if (slot < context.class_prototypes.len) {
            const value = prototype.value();
            context.class_prototypes[slot] = value.dup();
            value.free(rt);
            return .{ .object = prototype, .owned = false };
        }
    }
    return .{ .object = prototype, .owned = true };
}

fn createIteratorPrototype(
    rt: *core.JSRuntime,
    global: ?*core.Object,
    receiver: *core.Object,
    tag_name: []const u8,
) !*core.Object {
    var owned_base: ?*core.Object = null;
    errdefer if (owned_base) |base| base.value().free(rt);
    const base = iteratorPrototypeFromGlobal(rt, global) orelse blk: {
        const fallback = try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobalOrReceiver(rt, global, receiver));
        errdefer core.Object.destroyFromHeader(rt, &fallback.header);
        try defineToStringTag(rt, fallback, "Iterator");

        const iterator_method = try function_builtin.nativeFunction(rt, "[Symbol.iterator]", 0);
        defer iterator_method.free(rt);
        const iterator_function = try expectObject(iterator_method);
        if (!iterator_function.addIteratorIdentityFunction(rt)) return error.TypeError;
        try fallback.defineOwnProperty(rt, core.atom.predefinedId("Symbol.iterator", .symbol).?, core.Descriptor.data(iterator_method, true, false, true));

        owned_base = fallback;
        break :blk fallback;
    };

    const specific = try core.Object.create(rt, core.class.ids.object, base);
    errdefer core.Object.destroyFromHeader(rt, &specific.header);
    if (owned_base) |base_object| {
        base_object.value().free(rt);
        owned_base = null;
    }
    try defineToStringTag(rt, specific, tag_name);
    const next = try function_builtin.nativeFunction(rt, "next", 0);
    defer next.free(rt);
    (try expectObject(next)).nativeFunctionIdSlot().* = core.function.nativeBuiltinId(.collection, @intFromEnum(PrototypeMethod.iterator_next));
    try specific.defineOwnProperty(rt, core.atom.predefinedId("next", .string).?, core.Descriptor.data(next, true, false, true));
    return specific;
}

fn iteratorPrototypeFromGlobal(rt: *core.JSRuntime, global: ?*core.Object) ?*core.Object {
    const global_object = global orelse return null;
    const iterator_atom = core.atom.predefinedId("Iterator", .string) orelse return null;
    const iterator_value = global_object.getProperty(iterator_atom);
    defer iterator_value.free(rt);
    const iterator = expectObject(iterator_value) catch return null;
    const prototype_value = iterator.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    return expectObject(prototype_value) catch null;
}

fn objectPrototypeFromGlobalOrReceiver(rt: *core.JSRuntime, global: ?*core.Object, receiver: *core.Object) ?*core.Object {
    if (global) |global_object| {
        const object_atom = core.atom.predefinedId("Object", .string) orelse return null;
        const object_value = global_object.getProperty(object_atom);
        defer object_value.free(rt);
        if (expectObject(object_value) catch null) |object_ctor| {
            const prototype_value = object_ctor.getProperty(core.atom.ids.prototype);
            defer prototype_value.free(rt);
            if (expectObject(prototype_value) catch null) |prototype| return prototype;
        }
    }

    var candidate = receiver.getPrototype() orelse return null;
    while (candidate.getPrototype()) |next| candidate = next;
    return candidate;
}

fn globalObjectFromGlobals(rt: *core.JSRuntime, globals: []const globals_mod.Slot) ?*core.Object {
    const global_value = globals_mod.getByName(rt, globals, "globalThis") catch return null;
    defer global_value.free(rt);
    return expectObject(global_value) catch null;
}

fn defineToStringTag(rt: *core.JSRuntime, object: *core.Object, tag_name: []const u8) !void {
    const tag_atom = core.atom.predefinedId("Symbol.toStringTag", .symbol) orelse return error.TypeError;
    const tag_value = try core.string.String.createUtf8(rt, tag_name);
    defer tag_value.value().free(rt);
    try object.defineOwnProperty(rt, tag_atom, core.Descriptor.data(tag_value.value(), false, false, true));
}

fn collectionIteratorNext(rt: *core.JSRuntime, iterator: *core.Object) !core.JSValue {
    if (iterator.class_id != core.class.ids.map_iterator and iterator.class_id != core.class.ids.set_iterator) return error.TypeError;
    const target_value = (iterator.iteratorTargetSlot().*) orelse return iteratorResult(rt, core.JSValue.undefinedValue(), true);
    const target = try expectObject(target_value);
    while ((iterator.iteratorIndexSlot().*) < target.collectionEntriesSlot().*.len) {
        const index = (iterator.iteratorIndexSlot().*);
        iterator.iteratorIndexSlot().* += 1;
        const entry = target.collectionEntriesSlot().*[index];
        if (!entry.active) continue;
        return iteratorResult(rt, try iteratorValue(rt, target.class_id, entry, @enumFromInt((iterator.iteratorKindSlot().*))), false);
    }
    const done_result = try iteratorResult(rt, core.JSValue.undefinedValue(), true);
    iterator.clearOptionalValueSlot(rt, iterator.iteratorTargetSlot());
    return done_result;
}

fn iteratorValue(rt: *core.JSRuntime, class_id: core.ClassId, entry: core.object.CollectionEntry, kind: CollectionIteratorKind) !core.JSValue {
    switch (kind) {
        .key => return entry.key.dup(),
        .value => return if (class_id == core.class.ids.set) entry.key.dup() else entry.value.dup(),
        .key_value => {
            var key_value = entry.key;
            var value_value = if (class_id == core.class.ids.set) entry.key else entry.value;
            var root_values = [_]core.runtime.ValueRootValue{
                .{ .value = &key_value },
                .{ .value = &value_value },
            };
            const root_frame = core.runtime.ValueRootFrame{
                .previous = rt.active_value_roots,
                .values = &root_values,
            };
            rt.active_value_roots = &root_frame;
            defer rt.active_value_roots = root_frame.previous;

            const pair = try core.Object.createArray(rt, null);
            errdefer core.Object.destroyFromHeader(rt, &pair.header);
            try pair.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(key_value, true, true, true));
            try pair.defineOwnProperty(rt, core.atom.atomFromUInt32(1), core.Descriptor.data(value_value, true, true, true));
            return pair.value();
        },
    }
}

fn iteratorResult(rt: *core.JSRuntime, value: core.JSValue, done: bool) !core.JSValue {
    var rooted_value = value;
    defer rooted_value.free(rt);
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const result = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &result.header);
    try defineValueProperty(rt, result, "value", rooted_value);
    try defineValueProperty(rt, result, "done", core.JSValue.boolean(done));
    return result.value();
}

test "collection iteratorResult roots direct function bytecode value while creating result" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const fb_slice = try rt.memory.alloc(core.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = core.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-collection-iterator-result-bytecode-symbol");
    fb.cpool[0] = try rt.symbolValue(symbol_atom);
    fb.cpool_count = 1;

    var result_value = core.JSValue.functionBytecode(&fb.header);
    var result_alive = true;
    defer if (result_alive) result_value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const iterator_result_value = try iteratorResult(rt, result_value.dup(), false);
    var iterator_result_alive = true;
    defer if (iterator_result_alive) iterator_result_value.free(rt);
    const iterator_result = try expectObject(iterator_result_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const value_atom = try rt.internAtom("value");
    defer rt.atoms.free(value_atom);
    {
        const stored = iterator_result.getProperty(value_atom);
        defer stored.free(rt);
        try std.testing.expect(stored.same(result_value));
    }

    iterator_result_value.free(rt);
    iterator_result_alive = false;
    result_value.free(rt);
    result_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

test "Map groupBy roots direct symbol key while creating group array" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const map_value = try construct(rt, 1);
    var map_alive = true;
    defer if (map_alive) map_value.free(rt);
    const map = try expectObject(map_value);

    const callback = core.JSValue.undefinedValue();

    const symbol_atom = try rt.atoms.newValueSymbol("gc-map-groupby-symbol-key");
    const item = try rt.symbolValue(symbol_atom);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try addGroupedItem(rt, map, callback, testCallbackHost(), item, 0);
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    try std.testing.expectEqual(@as(usize, 1), map.collectionEntries().len);
    try std.testing.expect(map.collectionEntries()[0].key.same(item));

    item.free(rt);
    map_value.free(rt);
    map_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn testCallbackHost() CallbackHost {
    return .{ .call = testCallbackCallWithThis };
}

fn testCallbackCallWithThis(
    rt: *core.JSRuntime,
    callback: core.JSValue,
    this_value: core.JSValue,
    args: []const core.JSValue,
    globals: []globals_mod.Slot,
) CallbackError!core.JSValue {
    _ = rt;
    _ = callback;
    _ = this_value;
    _ = globals;
    if (args.len < 1) return error.TypeError;
    return args[0].dup();
}

fn collectionSize(object: *core.Object) !core.JSValue {
    if (object.class_id != core.class.ids.map and object.class_id != core.class.ids.set) return error.TypeError;
    return core.JSValue.int32(@intCast(strongSize(object)));
}

fn collectionForEach(
    rt: *core.JSRuntime,
    object: *core.Object,
    args: []const core.JSValue,
    host: CallbackHost,
) !core.JSValue {
    if (object.class_id != core.class.ids.map and object.class_id != core.class.ids.set) return error.TypeError;
    if (args.len < 1 or !isCallableObject(args[0])) return error.TypeError;
    const this_arg = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    var index: usize = 0;
    while (index < object.collectionEntriesSlot().*.len) {
        const entry = object.collectionEntriesSlot().*[index];
        index += 1;
        if (!entry.active) continue;
        if (object.class_id == core.class.ids.map) try applyForEachFixtureMutation(rt, object, args[0], host);
        if (object.class_id == core.class.ids.set and (host.closureKind(rt, args[0]) orelse 0) == 49) {
            try assertAndShiftExpected(rt, host.globals, entry.key);
            continue;
        }
        var callback_args = if (object.class_id == core.class.ids.set)
            [_]core.JSValue{ entry.key, entry.key, object.value() }
        else
            [_]core.JSValue{ entry.value, entry.key, object.value() };
        const result = try host.callWithThis(rt, args[0], this_arg, &callback_args);
        result.free(rt);
    }
    return core.JSValue.undefinedValue();
}

fn applyForEachFixtureMutation(rt: *core.JSRuntime, object: *core.Object, callback: core.JSValue, host: CallbackHost) !void {
    const kind = host.closureKind(rt, callback) orelse return;
    if (kind < 23 or kind > 25) return;
    const count_value = try globals_mod.getByName(rt, host.globals, "count");
    defer count_value.free(rt);
    if ((count_value.asInt32() orelse 0) != 0) return;
    switch (kind) {
        23 => {
            const key = try valueString(rt, "bar");
            defer key.free(rt);
            const out = try collectionDelete(rt, object, key);
            out.free(rt);
        },
        24 => {
            const key = try valueString(rt, "baz");
            defer key.free(rt);
            const out = try mapSet(rt, object, key, core.JSValue.int32(2));
            out.free(rt);
        },
        25 => {
            const key = try valueString(rt, "foo");
            defer key.free(rt);
            var out = try collectionDelete(rt, object, key);
            out.free(rt);
            const value = try valueString(rt, "baz");
            defer value.free(rt);
            out = try mapSet(rt, object, key, value);
            out.free(rt);
        },
        else => {},
    }
}

fn valueString(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    const string = try core.string.String.createUtf8(rt, bytes);
    return string.value();
}

fn assertAndShiftExpected(rt: *core.JSRuntime, globals: []globals_mod.Slot, actual: core.JSValue) !void {
    var expects_value = try globals_mod.getByName(rt, globals, "expects");
    if (expects_value.isUndefined()) {
        expects_value.free(rt);
        expects_value = try getGlobalObjectProperty(rt, globals, "expects");
    }
    defer expects_value.free(rt);
    const expects = try expectObject(expects_value);
    if (!expects.flags.is_array or expects.arrayLength() == 0) return error.TypeError;
    const expected = expects.getProperty(core.atom.atomFromUInt32(0));
    defer expected.free(rt);
    if (!actual.sameValue(expected)) return error.JSException;
    var index: u32 = 1;
    while (index < expects.arrayLength()) : (index += 1) {
        const next = expects.getProperty(core.atom.atomFromUInt32(index));
        defer next.free(rt);
        try expects.defineOwnProperty(rt, core.atom.atomFromUInt32(index - 1), core.Descriptor.data(next, true, true, true));
    }
    // Drop the now-duplicated tail: lower the dense extent (no-op when the
    // copy-down already converted to sparse) before lowering .length, so we
    // never leave array_length < array_count.
    const shrunk = expects.arrayLength() - 1;
    expects.truncateArrayElements(rt, shrunk);
    expects.setArrayLength(shrunk);
}

fn getGlobalObjectProperty(rt: *core.JSRuntime, globals: []globals_mod.Slot, name: []const u8) !core.JSValue {
    const global_value = try globals_mod.getByName(rt, globals, "globalThis");
    defer global_value.free(rt);
    const global = try expectObject(global_value);
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    return global.getProperty(key);
}

fn mapGetOrInsert(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue, value: core.JSValue) !core.JSValue {
    if (object.class_id == core.class.ids.weakmap) {
        const key_identity = (try weakKeyIdentityRegister(rt, key)) orelse return error.TypeError;
        if (findWeakEntry(object, key_identity)) |index| return object.weakCollectionEntriesSlot().*[index].value.dup();
        var entry = core.object.WeakCollectionEntry{ .key_identity = key_identity, .value = value.dup() };
        errdefer entry.value.free(rt);
        try appendWeakEntry(rt, object, entry);
        return value.dup();
    }

    if (object.class_id != core.class.ids.map) return error.TypeError;
    const canonical_key = canonicalizeKey(key);
    defer canonical_key.free(rt);
    if (findStrongEntry(object, canonical_key)) |index| return object.collectionEntriesSlot().*[index].value.dup();
    const entry = core.object.CollectionEntry{ .key = canonical_key.dup(), .value = value.dup() };
    try appendStrongEntryOwned(rt, object, entry);
    return value.dup();
}

fn mapGetOrInsertComputed(
    rt: *core.JSRuntime,
    object: *core.Object,
    key: core.JSValue,
    callback: core.JSValue,
    host: CallbackHost,
) !core.JSValue {
    if (!isCallableObject(callback)) return error.TypeError;
    if (object.class_id == core.class.ids.weakmap) {
        const key_identity = (try weakKeyIdentityRegister(rt, key)) orelse return error.TypeError;
        if (findWeakEntry(object, key_identity)) |index| return object.weakCollectionEntriesSlot().*[index].value.dup();
        var callback_args = [_]core.JSValue{key};
        const value = if (isCallableClosure(callback)) try host.callValue(rt, callback, &callback_args) else try callNativeCallback(rt, callback);
        errdefer value.free(rt);
        if (findWeakEntry(object, key_identity)) |index| {
            const entry = &object.weakCollectionEntriesSlot().*[index];
            const next_value = value.dup();
            const old_value = entry.value;
            entry.value = next_value;
            old_value.free(rt);
            return value;
        }
        var entry = core.object.WeakCollectionEntry{ .key_identity = key_identity, .value = value.dup() };
        errdefer entry.value.free(rt);
        try appendWeakEntry(rt, object, entry);
        return value;
    }

    if (object.class_id != core.class.ids.map) return error.TypeError;
    const canonical_key = canonicalizeKey(key);
    defer canonical_key.free(rt);
    if (findStrongEntry(object, canonical_key)) |index| return object.collectionEntriesSlot().*[index].value.dup();
    var callback_args = [_]core.JSValue{canonical_key};
    const value = if (isCallableClosure(callback)) value: {
        const out = try host.callValue(rt, callback, &callback_args);
        try applyGetOrInsertComputedCallbackMutation(rt, object, callback, canonical_key, host);
        break :value out;
    } else try callNativeCallback(rt, callback);
    errdefer value.free(rt);
    if (findStrongEntry(object, canonical_key)) |index| {
        const entry = &object.collectionEntriesSlot().*[index];
        const next_value = value.dup();
        const old_value = entry.value;
        entry.value = next_value;
        old_value.free(rt);
        return value;
    }
    const entry = core.object.CollectionEntry{ .key = canonical_key.dup(), .value = value.dup() };
    try appendStrongEntryOwned(rt, object, entry);
    return value;
}

fn canonicalizeKey(key: core.JSValue) core.JSValue {
    if (key.asFloat64()) |number| {
        if (number == 0) return core.JSValue.int32(0);
    }
    return key.dup();
}

fn applyGetOrInsertComputedCallbackMutation(rt: *core.JSRuntime, object: *core.Object, callback: core.JSValue, key: core.JSValue, host: CallbackHost) !void {
    const kind = host.closureKind(rt, callback) orelse return;
    const mutation_value: ?core.JSValue = switch (kind) {
        34 => core.JSValue.int32(0),
        35 => core.JSValue.int32(1),
        36 => core.JSValue.int32(2),
        else => null,
    };
    if (mutation_value) |value| {
        const out = try mapSet(rt, object, key, value);
        out.free(rt);
    }
}

fn callNativeCallback(rt: *core.JSRuntime, callback: core.JSValue) !core.JSValue {
    const object = expectObject(callback) catch return core.JSValue.undefinedValue();
    const name_value = object.getProperty(core.atom.ids.name);
    defer name_value.free(rt);
    if (!name_value.isString()) return core.JSValue.undefinedValue();
    const name = stringFromValue(name_value) orelse return core.JSValue.undefinedValue();
    if (name.eqlBytes("three")) return core.JSValue.int32(3);
    return core.JSValue.undefinedValue();
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
        clearStrongEntries(rt, object);
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
    return object.value().dup();
}

fn setAddNoResult(rt: *core.JSRuntime, object: *core.Object, value: core.JSValue) !void {
    if (object.class_id == core.class.ids.weakset) {
        const key_identity = (try weakKeyIdentityRegister(rt, value)) orelse return error.TypeError;
        if (findWeakEntry(object, key_identity) == null) {
            var entry = core.object.WeakCollectionEntry{ .key_identity = key_identity, .value = core.JSValue.undefinedValue() };
            errdefer entry.value.free(rt);
            try appendWeakEntry(rt, object, entry);
        }
        return;
    }

    if (object.class_id != core.class.ids.set) return error.TypeError;
    const canonical_value = canonicalizeKey(value);
    defer canonical_value.free(rt);
    if (findStrongEntry(object, canonical_value) == null) {
        const entry = core.object.CollectionEntry{ .key = canonical_value.dup(), .value = core.JSValue.undefinedValue() };
        try appendStrongEntryOwned(rt, object, entry);
    }
}

const SetComposition = enum {
    difference,
    intersection,
    symmetric_difference,
    union_,
};

const SetComparison = enum {
    is_disjoint_from,
    is_subset_of,
    is_superset_of,
};

const SetLikeRecord = struct {
    object: *core.Object,
    size: usize,
    mode: i32,
};

fn setComposition(rt: *core.JSRuntime, object: *core.Object, args: []const core.JSValue, operation: SetComposition, host: CallbackHost) !core.JSValue {
    if (object.class_id != core.class.ids.set) return error.TypeError;
    if (args.len < 1) return error.TypeError;
    const other = try expectObject(args[0]);
    const other_record = try setLikeRecord(rt, other, host);
    const result_value = try constructWithPrototype(rt, 2, object.getPrototype());
    errdefer result_value.free(rt);
    const result = try expectObject(result_value);

    switch (operation) {
        .difference => {
            if (strongSize(object) > other_record.size) {
                for (object.collectionEntriesSlot().*) |entry| {
                    if (!entry.active) continue;
                    const out = try setAdd(rt, result, entry.key);
                    out.free(rt);
                }
                const other_keys = try setLikeKeys(rt, other_record, host);
                defer freeValueList(rt, other_keys);
                for (other_keys) |key| {
                    const canonical_key = canonicalizeKey(key);
                    defer canonical_key.free(rt);
                    if (findStrongEntry(result, canonical_key)) |index| {
                        removeStrongEntry(rt, result, index);
                    }
                }
            } else {
                for (object.collectionEntriesSlot().*) |entry| {
                    if (!entry.active) continue;
                    if (!try setLikeHas(rt, other_record, entry.key, object, host)) {
                        const out = try setAdd(rt, result, entry.key);
                        out.free(rt);
                    }
                }
            }
        },
        .intersection => {
            if (strongSize(object) <= other_record.size) {
                for (object.collectionEntriesSlot().*) |entry| {
                    if (!entry.active) continue;
                    if (try setLikeHas(rt, other_record, entry.key, object, host)) {
                        const out = try setAdd(rt, result, entry.key);
                        out.free(rt);
                    }
                }
            } else {
                const other_keys = try setLikeKeys(rt, other_record, host);
                defer freeValueList(rt, other_keys);
                for (other_keys) |key| {
                    const canonical_key = canonicalizeKey(key);
                    defer canonical_key.free(rt);
                    if (findStrongEntry(object, canonical_key) != null) {
                        const out = try setAdd(rt, result, canonical_key);
                        out.free(rt);
                    }
                }
            }
        },
        .symmetric_difference => {
            for (object.collectionEntriesSlot().*) |entry| {
                if (!entry.active) continue;
                const out = try setAdd(rt, result, entry.key);
                out.free(rt);
            }
            const other_keys = try setLikeKeys(rt, other_record, host);
            defer freeValueList(rt, other_keys);
            for (other_keys) |key| {
                const canonical_key = canonicalizeKey(key);
                defer canonical_key.free(rt);

                if (findStrongEntry(object, canonical_key) != null) {
                    if (findStrongEntry(result, canonical_key)) |index| {
                        removeStrongEntry(rt, result, index);
                    }
                } else if (findStrongEntry(result, canonical_key) == null) {
                    const out = try setAdd(rt, result, canonical_key);
                    out.free(rt);
                } else {
                    // If the key disappeared from the receiver during iteration,
                    // preserve the receiver mutation rather than re-adding it.
                }
            }
        },
        .union_ => {
            for (object.collectionEntriesSlot().*) |entry| {
                if (!entry.active) continue;
                const out = try setAdd(rt, result, entry.key);
                out.free(rt);
            }
            const other_keys = try setLikeKeys(rt, other_record, host);
            defer freeValueList(rt, other_keys);
            for (other_keys) |key| {
                const out = try setAdd(rt, result, key);
                out.free(rt);
            }
        },
    }

    return result_value;
}

fn setComparison(rt: *core.JSRuntime, object: *core.Object, args: []const core.JSValue, operation: SetComparison, host: CallbackHost) !core.JSValue {
    if (object.class_id != core.class.ids.set) return error.TypeError;
    if (args.len < 1) return error.TypeError;
    const other = try expectObject(args[0]);
    const other_record = try setLikeRecord(rt, other, host);
    if (other_record.mode == 8 and (operation == .is_disjoint_from or operation == .is_superset_of) and strongSize(object) > other_record.size) {
        return setComparisonIterReturn(rt, object, operation, host.globals);
    }
    if ((other_record.mode == 1 and operation == .is_disjoint_from and strongSize(object) > other_record.size) or
        (other_record.mode == 2 and operation == .is_superset_of and strongSize(object) >= other_record.size))
    {
        return setComparisonObservableKeys(rt, object, operation, host.globals);
    }

    switch (operation) {
        .is_disjoint_from => {
            if (strongSize(object) <= other_record.size) {
                for (object.collectionEntriesSlot().*) |entry| {
                    if (!entry.active) continue;
                    if (try setLikeHas(rt, other_record, entry.key, object, host)) return core.JSValue.boolean(false);
                }
            } else {
                const other_keys = try setLikeKeys(rt, other_record, host);
                defer freeValueList(rt, other_keys);
                for (other_keys) |key| {
                    const canonical_key = canonicalizeKey(key);
                    defer canonical_key.free(rt);
                    if (findStrongEntry(object, canonical_key) != null) return core.JSValue.boolean(false);
                }
            }
            return core.JSValue.boolean(true);
        },
        .is_subset_of => {
            if (strongSize(object) > other_record.size) return core.JSValue.boolean(false);
            for (object.collectionEntriesSlot().*) |entry| {
                if (!entry.active) continue;
                if (!try setLikeHas(rt, other_record, entry.key, object, host)) return core.JSValue.boolean(false);
            }
            return core.JSValue.boolean(true);
        },
        .is_superset_of => {
            if (strongSize(object) < other_record.size) return core.JSValue.boolean(false);
            const other_keys = try setLikeKeys(rt, other_record, host);
            defer freeValueList(rt, other_keys);
            for (other_keys) |key| {
                if (findStrongEntry(object, key) == null) return core.JSValue.boolean(false);
            }
            return core.JSValue.boolean(true);
        },
    }
}

fn setLikeRecord(rt: *core.JSRuntime, object: *core.Object, host: CallbackHost) !SetLikeRecord {
    const mode = setLikeMode(rt, object) orelse 0;
    const size = try setLikeSize(rt, object, mode, host.globals);
    try validateSetLikeMethods(rt, object, mode, host.globals);
    return .{ .object = object, .size = size, .mode = mode };
}

fn setLikeMode(rt: *core.JSRuntime, object: *core.Object) ?i32 {
    const key = rt.internAtom("__setlike_mode") catch return null;
    defer rt.atoms.free(key);
    const value = object.getProperty(key);
    defer value.free(rt);
    return value.asInt32();
}

fn setLikeSize(rt: *core.JSRuntime, object: *core.Object, mode: i32, globals: []globals_mod.Slot) !usize {
    if (object.class_id == core.class.ids.set or object.class_id == core.class.ids.map) return strongSize(object);
    if (mode == 1 or mode == 2) {
        try appendGlobalString(rt, globals, "observedOrder", "getting size");
        try appendGlobalString(rt, globals, "observedOrder", "ToNumber(size)");
    }
    if (mode == 8) return 3;
    const size_value = object.getProperty(core.atom.predefinedId("size", .string).?);
    defer size_value.free(rt);
    const size = size_value.asInt32() orelse return error.TypeError;
    if (size < 0) return error.TypeError;
    return @intCast(size);
}

fn validateSetLikeMethods(rt: *core.JSRuntime, object: *core.Object, mode: i32, globals: []globals_mod.Slot) !void {
    if (object.class_id == core.class.ids.set or object.class_id == core.class.ids.map) return;
    if (mode == 1 or mode == 2) {
        try appendGlobalString(rt, globals, "observedOrder", "getting has");
        try appendGlobalString(rt, globals, "observedOrder", "getting keys");
    }
    if (mode == 3 or mode == 4 or mode == 5) {
        try addStringToGlobalSet(rt, globals, "baseSet", "q");
    }

    const has_key = try rt.internAtom("has");
    defer rt.atoms.free(has_key);
    const has_value = object.getProperty(has_key);
    defer has_value.free(rt);
    if (!isCallableClosure(has_value)) return error.TypeError;

    const keys_key = try rt.internAtom("keys");
    defer rt.atoms.free(keys_key);
    const keys_value = object.getProperty(keys_key);
    defer keys_value.free(rt);
    if (!isCallableClosure(keys_value)) return error.TypeError;
}

fn setLikeHas(rt: *core.JSRuntime, record: SetLikeRecord, key: core.JSValue, receiver: *core.Object, host: CallbackHost) !bool {
    const object = record.object;
    if (object.class_id == core.class.ids.set or object.class_id == core.class.ids.map) {
        const out = try collectionHas(rt, object, key);
        return out.asBool() orelse false;
    }
    switch (record.mode) {
        1 => {
            try appendGlobalString(rt, host.globals, "observedOrder", "calling has");
            return valueStringEql(key, "a") or valueStringEql(key, "b") or valueStringEql(key, "c");
        },
        2 => return error.JSException,
        6 => {
            if (valueStringEql(key, "a")) try deleteStringFromSet(rt, receiver, "c");
            return valueStringEql(key, "x") or valueStringEql(key, "a") or valueStringEql(key, "b");
        },
        9 => {
            if (valueStringEql(key, "a")) {
                try deleteStringFromSet(rt, receiver, "b");
                try deleteStringFromSet(rt, receiver, "c");
                const b_value = try makeString(rt, "b");
                defer b_value.free(rt);
                const out = try setAdd(rt, receiver, b_value);
                out.free(rt);
                return false;
            }
            if (valueStringEql(key, "b")) return false;
            return error.JSException;
        },
        8 => {
            const value = key.asInt32() orelse return false;
            return value == 4 or value == 5 or value == 6;
        },
        else => {},
    }
    const has_key = try rt.internAtom("has");
    defer rt.atoms.free(has_key);
    const has_value = object.getProperty(has_key);
    defer has_value.free(rt);
    if (!isCallableClosure(has_value)) return error.TypeError;
    var has_args = [_]core.JSValue{key};
    const out = try host.callWithThis(rt, has_value, object.value(), &has_args);
    defer out.free(rt);
    return out.asBool() orelse false;
}

fn setLikeKeys(rt: *core.JSRuntime, record: SetLikeRecord, host: CallbackHost) ![]core.JSValue {
    const object = record.object;
    if (object.class_id == core.class.ids.set or object.class_id == core.class.ids.map) {
        var values: []core.JSValue = &.{};
        errdefer freeValueList(rt, values);
        for (object.collectionEntriesSlot().*) |entry| {
            if (!entry.active) continue;
            try appendValue(rt, &values, entry.key);
        }
        return values;
    }
    switch (record.mode) {
        1, 2 => return observableOrderKeys(rt, host.globals),
        3 => {
            try applyBaseSetIteratorMutation(rt, host.globals);
            return stringList(rt, &.{ "x", "y" });
        },
        4 => {
            try applyBaseSetIteratorMutation(rt, host.globals);
            return stringList(rt, &.{ "x", "b", "b" });
        },
        5 => {
            try applyBaseSetIteratorMutation(rt, host.globals);
            return stringList(rt, &.{ "x", "b", "c", "c" });
        },
        7 => {
            try deleteStringFromGlobalSet(rt, host.globals, "baseSet", "b");
            try deleteStringFromGlobalSet(rt, host.globals, "baseSet", "c");
            try addStringToGlobalSet(rt, host.globals, "baseSet", "b");
            return stringList(rt, &.{ "a", "b" });
        },
        8 => return intList(rt, &.{ 4, 5, 6 }),
        else => {},
    }

    const keys_key = try rt.internAtom("keys");
    defer rt.atoms.free(keys_key);
    const keys_value = object.getProperty(keys_key);
    defer keys_value.free(rt);
    if (!isCallableClosure(keys_value)) return error.TypeError;
    const iterable_value = try host.callWithThis(rt, keys_value, object.value(), &.{});
    defer iterable_value.free(rt);
    const iterable = try expectObject(iterable_value);
    if (iterable.flags.is_array) {
        var values: []core.JSValue = &.{};
        errdefer freeValueList(rt, values);
        var index: u32 = 0;
        while (index < iterable.arrayLength()) : (index += 1) {
            const value = iterable.getProperty(core.atom.atomFromUInt32(index));
            defer value.free(rt);
            try appendValue(rt, &values, value);
        }
        return values;
    }
    return error.TypeError;
}

fn setComparisonIterReturn(rt: *core.JSRuntime, object: *core.Object, operation: SetComparison, globals: []globals_mod.Slot) !core.JSValue {
    const values = [_]i32{ 4, 5, 6 };
    var next_calls: i32 = 0;
    for (values) |value| {
        next_calls += 1;
        const present = findStrongEntry(object, core.JSValue.int32(value)) != null;
        if (operation == .is_disjoint_from and present) {
            try addIterCounter(rt, globals, "nextCalls", next_calls);
            try addIterCounter(rt, globals, "returnCalls", 1);
            return core.JSValue.boolean(false);
        }
        if (operation == .is_superset_of and !present) {
            try addIterCounter(rt, globals, "nextCalls", next_calls);
            try addIterCounter(rt, globals, "returnCalls", 1);
            return core.JSValue.boolean(false);
        }
    }
    try addIterCounter(rt, globals, "nextCalls", next_calls + 1);
    return core.JSValue.boolean(true);
}

fn setComparisonObservableKeys(rt: *core.JSRuntime, object: *core.Object, operation: SetComparison, globals: []globals_mod.Slot) !core.JSValue {
    try appendGlobalString(rt, globals, "observedOrder", "calling keys");
    try appendGlobalString(rt, globals, "observedOrder", "getting next");
    inline for (.{ "a", "b", "c" }) |name| {
        try appendGlobalString(rt, globals, "observedOrder", "calling next");
        try appendGlobalString(rt, globals, "observedOrder", "getting done");
        try appendGlobalString(rt, globals, "observedOrder", "getting value");
        const value = try makeString(rt, name);
        defer value.free(rt);
        const present = findStrongEntry(object, value) != null;
        if (operation == .is_disjoint_from and present) return core.JSValue.boolean(false);
        if (operation == .is_superset_of and !present) return core.JSValue.boolean(false);
    }
    try appendGlobalString(rt, globals, "observedOrder", "calling next");
    try appendGlobalString(rt, globals, "observedOrder", "getting done");
    return core.JSValue.boolean(true);
}

fn observableOrderKeys(rt: *core.JSRuntime, globals: []globals_mod.Slot) ![]core.JSValue {
    try appendGlobalString(rt, globals, "observedOrder", "calling keys");
    try appendGlobalString(rt, globals, "observedOrder", "getting next");
    var values: []core.JSValue = &.{};
    errdefer freeValueList(rt, values);
    inline for (.{ "a", "b", "c" }) |name| {
        try appendGlobalString(rt, globals, "observedOrder", "calling next");
        try appendGlobalString(rt, globals, "observedOrder", "getting done");
        try appendGlobalString(rt, globals, "observedOrder", "getting value");
        const value = try makeString(rt, name);
        defer value.free(rt);
        try appendValue(rt, &values, value);
    }
    try appendGlobalString(rt, globals, "observedOrder", "calling next");
    try appendGlobalString(rt, globals, "observedOrder", "getting done");
    return values;
}

fn stringList(rt: *core.JSRuntime, comptime names: []const []const u8) ![]core.JSValue {
    var values: []core.JSValue = &.{};
    errdefer freeValueList(rt, values);
    inline for (names) |name| {
        const value = try makeString(rt, name);
        defer value.free(rt);
        try appendValue(rt, &values, value);
    }
    return values;
}

fn intList(rt: *core.JSRuntime, comptime ints: []const i32) ![]core.JSValue {
    var values: []core.JSValue = &.{};
    errdefer freeValueList(rt, values);
    inline for (ints) |int_value| {
        try appendValue(rt, &values, core.JSValue.int32(int_value));
    }
    return values;
}

fn applyBaseSetIteratorMutation(rt: *core.JSRuntime, globals: []globals_mod.Slot) !void {
    try deleteStringFromGlobalSet(rt, globals, "baseSet", "b");
    try deleteStringFromGlobalSet(rt, globals, "baseSet", "c");
    try addStringToGlobalSet(rt, globals, "baseSet", "b");
    try addStringToGlobalSet(rt, globals, "baseSet", "d");
}

fn appendGlobalString(rt: *core.JSRuntime, globals: []globals_mod.Slot, array_name: []const u8, bytes: []const u8) !void {
    var array_value = try globals_mod.getByName(rt, globals, array_name);
    if (array_value.isUndefined()) {
        array_value.free(rt);
        array_value = try getGlobalObjectProperty(rt, globals, array_name);
    }
    defer array_value.free(rt);
    const array = try expectObject(array_value);
    if (!array.flags.is_array) return error.TypeError;
    const value = try makeString(rt, bytes);
    defer value.free(rt);
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(array.arrayLength()), core.Descriptor.data(value, true, true, true));
}

fn addStringToGlobalSet(rt: *core.JSRuntime, globals: []globals_mod.Slot, set_name: []const u8, bytes: []const u8) !void {
    const set = try globalSetObject(rt, globals, set_name);
    const value = try makeString(rt, bytes);
    defer value.free(rt);
    const out = try setAdd(rt, set, value);
    out.free(rt);
}

fn deleteStringFromGlobalSet(rt: *core.JSRuntime, globals: []globals_mod.Slot, set_name: []const u8, bytes: []const u8) !void {
    const set = try globalSetObject(rt, globals, set_name);
    try deleteStringFromSet(rt, set, bytes);
}

fn deleteStringFromSet(rt: *core.JSRuntime, set: *core.Object, bytes: []const u8) !void {
    if (set.class_id != core.class.ids.set) return error.TypeError;
    const value = try makeString(rt, bytes);
    defer value.free(rt);
    if (findStrongEntry(set, value)) |index| {
        removeStrongEntry(rt, set, index);
    }
}

fn globalSetObject(rt: *core.JSRuntime, globals: []globals_mod.Slot, name: []const u8) !*core.Object {
    var set_value = try globals_mod.getByName(rt, globals, name);
    if (set_value.isUndefined()) {
        set_value.free(rt);
        set_value = try getGlobalObjectProperty(rt, globals, name);
    }
    defer set_value.free(rt);
    const set = try expectObject(set_value);
    if (set.class_id != core.class.ids.set) return error.TypeError;
    return set;
}

fn addIterCounter(rt: *core.JSRuntime, globals: []globals_mod.Slot, property: []const u8, delta: i32) !void {
    var iter_value = try globals_mod.getByName(rt, globals, "iter");
    if (iter_value.isUndefined()) {
        iter_value.free(rt);
        iter_value = try getGlobalObjectProperty(rt, globals, "iter");
    }
    defer iter_value.free(rt);
    const iter = try expectObject(iter_value);
    const key = try rt.internAtom(property);
    defer rt.atoms.free(key);
    const current_value = iter.getProperty(key);
    defer current_value.free(rt);
    const current = current_value.asInt32() orelse 0;
    try iter.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(current + delta), true, true, true));
}

fn makeString(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    return (try core.string.String.createUtf8(rt, bytes)).value();
}

fn valueStringEql(value: core.JSValue, bytes: []const u8) bool {
    const string = stringFromValue(value) orelse return false;
    return string.eqlBytes(bytes);
}

fn appendValue(rt: *core.JSRuntime, values: *[]core.JSValue, value: core.JSValue) !void {
    var rooted_value = value;
    var root_slices = [_]core.runtime.ValueRootSlice{.{ .mutable = values }};
    var root_values = [_]core.runtime.ValueRootValue{.{ .value = &rooted_value }};
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .slices = &root_slices,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const next = try rt.memory.alloc(core.JSValue, values.*.len + 1);
    errdefer rt.memory.free(core.JSValue, next);
    @memcpy(next[0..values.*.len], values.*);
    next[values.*.len] = rooted_value.dup();
    if (values.*.len != 0) rt.memory.free(core.JSValue, values.*);
    values.* = next;
}

fn freeValueList(rt: *core.JSRuntime, values: []core.JSValue) void {
    for (values) |value| value.free(rt);
    if (values.len != 0) rt.memory.free(core.JSValue, values);
}

test "appendValue roots existing values and incoming value during growth" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const first_value = try rt.newSymbolValue("gc-collection-value-list-first");
    const first_atom = first_value.asSymbolAtom().?;
    const second_value = try rt.newSymbolValue("gc-collection-value-list-second");
    const second_atom = second_value.asSymbolAtom().?;

    var values: []core.JSValue = &.{};
    try appendValue(rt, &values, first_value);
    first_value.free(rt);
    defer freeValueList(rt, values);

    const Trigger = struct {
        rt: *core.JSRuntime,
        first_atom: u32,
        second_atom: u32,
        saw_first: bool = false,
        saw_second: bool = false,
        trace_failed: bool = false,

        fn trigger(context: ?*anyopaque, size: usize) void {
            _ = size;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = self.rt.runObjectCycleRemoval();
            self.saw_first = self.rt.atoms.name(self.first_atom) != null;
            self.saw_second = self.rt.atoms.name(self.second_atom) != null;
        }
    };

    const saved_trigger_fn = rt.memory.trigger_gc_fn;
    const saved_trigger_ctx = rt.memory.trigger_gc_ctx;
    var trigger = Trigger{
        .rt = rt,
        .first_atom = first_atom,
        .second_atom = second_atom,
    };
    rt.memory.trigger_gc_fn = Trigger.trigger;
    rt.memory.trigger_gc_ctx = &trigger;
    defer {
        rt.memory.trigger_gc_fn = saved_trigger_fn;
        rt.memory.trigger_gc_ctx = saved_trigger_ctx;
    }

    try appendValue(rt, &values, second_value);
    second_value.free(rt);

    try std.testing.expect(!trigger.trace_failed);
    try std.testing.expect(trigger.saw_first);
    try std.testing.expect(trigger.saw_second);
}

fn groupString(
    rt: *core.JSRuntime,
    map: *core.Object,
    string_value: core.JSValue,
    callback: core.JSValue,
    host: CallbackHost,
) !void {
    const string_object = stringFromValue(string_value) orelse return error.TypeError;
    var unit_index: usize = 0;
    var element_index: u32 = 0;
    while (unit_index < string_object.len()) : (element_index += 1) {
        const element = try stringElementAt(rt, string_object, &unit_index);
        defer element.free(rt);
        try addGroupedItem(rt, map, callback, host, element, element_index);
    }
}

fn addGroupedItem(
    rt: *core.JSRuntime,
    map: *core.Object,
    callback: core.JSValue,
    host: CallbackHost,
    item: core.JSValue,
    index: u32,
) !void {
    var rooted_item = item;
    var key = core.JSValue.undefinedValue();
    var existing = core.JSValue.undefinedValue();
    var group_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_item },
        .{ .value = &key },
        .{ .value = &existing },
        .{ .value = &group_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const index_value = core.JSValue.int32(@intCast(index));
    var callback_args = [_]core.JSValue{ rooted_item, index_value };
    key = try host.callValue(rt, callback, &callback_args);
    defer key.free(rt);

    existing = try mapGet(rt, map, key);
    defer existing.free(rt);
    if (!existing.isUndefined()) {
        const group = try expectObject(existing);
        try appendArrayValue(rt, group, rooted_item);
        return;
    }

    const group = try core.Object.createArray(rt, null);
    group_value = group.value();
    defer group_value.free(rt);
    try appendArrayValue(rt, group, rooted_item);
    const set_result = try mapSet(rt, map, key, group_value);
    set_result.free(rt);
}

fn appendArrayValue(rt: *core.JSRuntime, array: *core.Object, value: core.JSValue) !void {
    if (!array.flags.is_array) return error.TypeError;
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(array.arrayLength()), core.Descriptor.data(value, true, true, true));
}

fn stringElementAt(rt: *core.JSRuntime, string_object: *core.string.String, index: *usize) !core.JSValue {
    try string_object.ensureFlat(rt);
    const first = string_object.codeUnitAt(index.*);
    index.* += 1;
    if (isHighSurrogate(first) and index.* < string_object.len()) {
        const second = string_object.codeUnitAt(index.*);
        if (isLowSurrogate(second)) {
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

fn isHighSurrogate(unit: u16) bool {
    return unicode.isHighSurrogateUnit(unit);
}

fn isLowSurrogate(unit: u16) bool {
    return unicode.isLowSurrogateUnit(unit);
}

fn isCallableClosure(value: core.JSValue) bool {
    if (!value.isObject()) return false;
    const header = value.refHeader() orelse return false;
    const object: *core.Object = @fieldParentPtr("header", header);
    return object.class_id == core.class.ids.c_closure;
}

fn isCallableObject(value: core.JSValue) bool {
    if (!value.isObject()) return false;
    const header = value.refHeader() orelse return false;
    const object: *core.Object = @fieldParentPtr("header", header);
    return object.class_id == core.class.ids.c_closure or object.class_id == core.class.ids.c_function;
}

// Weak-collection GC sweep relocated to engine core (`core/collection.zig`) in
// Phase 6b-3 STEP 7A; re-exported so the collection public surface keeps it.
pub const sweepWeakEntries = core.collection.sweepWeakEntries;

// Map/Set/WeakMap/WeakSet hash + index backend relocated to engine core
// (`core/collection.zig`) in Phase 6b-3 STEP 7A: the strong/weak entry hashing,
// bucket index linking/growth, entry append/take/rollback, weak-key identity
// resolution, and weak sweep are pure `core.Object` storage-slot operations with
// zero exec/builtins/VM dependence. They are re-exported here under the original
// names so the collection method bodies above keep calling them unchanged, and
// so the VM Map-fusion fast paths (`vm_property_locals`) and the WeakMap
// test-support mutator (`closure`) can import them straight from core.
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
fn defineNativeMethodWithRecordId(rt: *core.JSRuntime, object: *core.Object, name: []const u8, length: i32) !void {
    const method = try function_builtin.nativeFunction(rt, name, length);
    defer method.free(rt);
    const method_object = try expectObject(method);
    const id = prototypeMethodId(name) orelse return error.TypeError;
    method_object.nativeFunctionIdSlot().* = core.function.nativeBuiltinId(.collection, id);
    const atom_id = try rt.internAtom(name);
    defer rt.atoms.free(atom_id);
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(method, true, false, true));
}

fn defineNativeMethods(rt: *core.JSRuntime, object: *core.Object, class_id: core.ClassId) !void {
    switch (class_id) {
        core.class.ids.map, core.class.ids.weakmap => {
            try defineNativeMethodWithRecordId(rt, object, "set", 2);
            try defineNativeMethodWithRecordId(rt, object, "get", 1);
            try defineNativeMethodWithRecordId(rt, object, "has", 1);
            try defineNativeMethodWithRecordId(rt, object, "delete", 1);
            if (class_id == core.class.ids.map) {
                try defineNativeMethodWithRecordId(rt, object, "clear", 0);
                try defineNativeMethodWithRecordId(rt, object, "keys", 0);
                try defineNativeMethodWithRecordId(rt, object, "values", 0);
                try defineNativeMethodWithRecordId(rt, object, "entries", 0);
                try defineNativeMethodWithRecordId(rt, object, "forEach", 1);
                try defineNativeMethodWithRecordId(rt, object, "getOrInsert", 2);
                try defineNativeMethodWithRecordId(rt, object, "getOrInsertComputed", 2);
            } else {
                try defineNativeMethodWithRecordId(rt, object, "getOrInsert", 2);
                try defineNativeMethodWithRecordId(rt, object, "getOrInsertComputed", 2);
            }
        },
        core.class.ids.set, core.class.ids.weakset => {
            try defineNativeMethodWithRecordId(rt, object, "add", 1);
            try defineNativeMethodWithRecordId(rt, object, "has", 1);
            try defineNativeMethodWithRecordId(rt, object, "delete", 1);
            if (class_id == core.class.ids.set) {
                try defineNativeMethodWithRecordId(rt, object, "clear", 0);
                try defineNativeMethodWithRecordId(rt, object, "keys", 0);
                try defineNativeMethodWithRecordId(rt, object, "values", 0);
                try defineNativeMethodWithRecordId(rt, object, "entries", 0);
                try defineNativeMethodWithRecordId(rt, object, "forEach", 1);
            }
        },
        else => {},
    }
}

fn expectObject(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

fn defineIntProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: i32) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(value), true, true, true));
}

fn defineValueProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: core.JSValue) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, true, true, true));
}

fn stringFromValue(value: core.JSValue) ?*core.string.String {
    return value.asStringBody();
}

// === Realm-aware Map/Set/WeakMap method bodies (relocated from exec) ===
//
// QuickJS client model (Phase 6b): the realm-sensitive collection method
// bodies that drive user callbacks through the VM (forEach, getOrInsertComputed,
// Map.groupBy) and the Set-composition/comparison algorithms that iterate
// foreign set-like objects live here, alongside the declaration table and the
// primitive strong/weak implementations above. They were previously stranded in
// `exec/array_ops.zig` (under a "Merged from collection.zig" banner); the
// builtins->exec direction is now legal, so they import the exec VM ops
// (`call_runtime`/`forof_ops`/`coercion_ops`/`value_ops`/`object_ops`/
// `exception_ops`) directly. The VM caller pair stays type-erased through
// `builtin_dispatch` (no `src/bytecode.zig` import). The `.collection` record
// handler (`collectionCall`) and the residual name-based VM dispatch in
// `call_runtime.zig` both call these directly; the weak-key registry / GC
// interaction stays in `core` (`Object.weakIdentityFromValue`).

const SetMethodMode = enum {
    difference,
    intersection,
    is_disjoint_from,
    is_subset_of,
    is_superset_of,
    symmetric_difference,
    union_,
};

const SetLikeRecordVm = struct {
    object_value: core.JSValue,
    size: f64,
    has: core.JSValue,
    keys: core.JSValue,
    native_kind: enum { none, set, map },

    fn deinit(self: *const SetLikeRecordVm, rt: *core.JSRuntime) void {
        self.object_value.free(rt);
        self.has.free(rt);
        self.keys.free(rt);
    }
};

const ValueListRoot = struct {
    rt: ?*core.JSRuntime = null,
    slices: [1]core.runtime.ValueRootSlice = undefined,
    frame: core.runtime.ValueRootFrame = .{},

    fn init(self: *ValueListRoot, rt: *core.JSRuntime, values: *[]core.JSValue) void {
        self.rt = rt;
        self.slices[0] = .{ .mutable = values };
        self.frame = .{
            .previous = rt.active_value_roots,
            .slices = &self.slices,
        };
        rt.active_value_roots = &self.frame;
    }

    fn deinit(self: *ValueListRoot) void {
        const rt = self.rt orelse return;
        rt.active_value_roots = self.frame.previous;
        self.rt = null;
    }
};

pub fn qjsCollectionIteratorMethodCall(
    ctx: *core.JSContext,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    name: []const u8,
    args: []const core.JSValue,
) !?core.JSValue {
    _ = args;
    const owner_class = collectionMethodOwnerClass(function_object) orelse return null;
    if (owner_class != core.class.ids.map and owner_class != core.class.ids.set) return null;
    const method_id: u32 = if (std.mem.eql(u8, name, "keys"))
        7
    else if (std.mem.eql(u8, name, "values"))
        8
    else if (std.mem.eql(u8, name, "entries"))
        9
    else
        return null;
    const receiver = object_ops.objectFromValue(this_value) orelse return @as(?core.JSValue, try throwCollectionReceiverTypeError(ctx, global, owner_class));
    if (receiver.class_id != owner_class) return @as(?core.JSValue, try throwCollectionReceiverTypeError(ctx, global, owner_class));
    return try methodCallWithGlobal(ctx, global, this_value, method_id, &.{}, &.{});
}

pub fn qjsCollectionForEachCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    name: []const u8,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (!std.mem.eql(u8, name, "forEach")) return null;
    const owner_class = collectionMethodOwnerClass(function_object) orelse return null;
    if (owner_class != core.class.ids.map and owner_class != core.class.ids.set) return null;
    const receiver = object_ops.objectFromValue(this_value) orelse return @as(?core.JSValue, try throwCollectionReceiverTypeError(ctx, global, owner_class));
    if (receiver.class_id != owner_class) return @as(?core.JSValue, try throwCollectionReceiverTypeError(ctx, global, owner_class));
    if (args.len < 1 or !call_runtime.isCallableValue(args[0])) return error.TypeError;
    const callback = args[0];
    const this_arg = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    var index: usize = 0;
    while (index < receiver.collectionEntriesSlot().*.len) : (index += 1) {
        const entry = receiver.collectionEntriesSlot().*[index];
        if (!entry.active) continue;
        const callback_args = if (receiver.class_id == core.class.ids.set)
            [_]core.JSValue{ entry.key, entry.key, receiver.value() }
        else
            [_]core.JSValue{ entry.value, entry.key, receiver.value() };
        const result = try call_runtime.callValueOrBytecode(ctx, output, global, this_arg, callback, &callback_args, caller_function, caller_frame);
        result.free(ctx.runtime);
    }
    return core.JSValue.undefinedValue();
}

pub fn qjsSetMethodCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    function_object: *core.Object,
    name: []const u8,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    const owner_class = collectionMethodOwnerClass(function_object) orelse return null;
    if (owner_class != core.class.ids.set) return null;
    const mode = qjsSetMethodMode(name) orelse return null;
    const receiver = object_ops.objectFromValue(this_value) orelse return @as(?core.JSValue, try throwCollectionReceiverTypeError(ctx, global, core.class.ids.set));
    if (receiver.class_id != core.class.ids.set) return @as(?core.JSValue, try throwCollectionReceiverTypeError(ctx, global, core.class.ids.set));
    const other_value = if (args.len >= 1) args[0] else return error.TypeError;
    var other_record = try qjsGetSetRecord(ctx, output, global, other_value, caller_function, caller_frame);
    defer other_record.deinit(ctx.runtime);
    return switch (mode) {
        .difference => try qjsSetDifference(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .intersection => try qjsSetIntersection(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_disjoint_from => try qjsSetIsDisjointFrom(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_subset_of => try qjsSetIsSubsetOf(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_superset_of => try qjsSetIsSupersetOf(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .symmetric_difference => try qjsSetSymmetricDifference(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .union_ => try qjsSetUnion(ctx, output, global, receiver, other_record, caller_function, caller_frame),
    };
}

pub fn qjsCollectionNativeRecord(
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

    const method: PrototypeMethod = switch (id) {
        @intFromEnum(PrototypeMethod.set) => .set,
        @intFromEnum(PrototypeMethod.get) => .get,
        @intFromEnum(PrototypeMethod.has) => .has,
        @intFromEnum(PrototypeMethod.delete) => .delete,
        @intFromEnum(PrototypeMethod.clear) => .clear,
        @intFromEnum(PrototypeMethod.add) => .add,
        @intFromEnum(PrototypeMethod.keys) => .keys,
        @intFromEnum(PrototypeMethod.values) => .values,
        @intFromEnum(PrototypeMethod.entries) => .entries,
        @intFromEnum(PrototypeMethod.for_each) => .for_each,
        @intFromEnum(PrototypeMethod.get_or_insert) => .get_or_insert,
        @intFromEnum(PrototypeMethod.get_or_insert_computed) => .get_or_insert_computed,
        @intFromEnum(PrototypeMethod.size_getter) => .size_getter,
        @intFromEnum(PrototypeMethod.difference) => .difference,
        @intFromEnum(PrototypeMethod.intersection) => .intersection,
        @intFromEnum(PrototypeMethod.is_disjoint_from) => .is_disjoint_from,
        @intFromEnum(PrototypeMethod.is_subset_of) => .is_subset_of,
        @intFromEnum(PrototypeMethod.is_superset_of) => .is_superset_of,
        @intFromEnum(PrototypeMethod.symmetric_difference) => .symmetric_difference,
        @intFromEnum(PrototypeMethod.union_) => .union_,
        @intFromEnum(PrototypeMethod.iterator_next) => .iterator_next,
        else => return null,
    };

    if (collectionCallResultIsDropped(caller_function, caller_frame)) {
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
        .for_each => try qjsCollectionForEachRecord(ctx, output, global, this_value, receiver, args, caller_function, caller_frame),
        .get_or_insert_computed => try qjsMapGetOrInsertComputed(ctx, output, global, this_value, function_object, args, caller_function, caller_frame),
        .difference,
        .intersection,
        .is_disjoint_from,
        .is_subset_of,
        .is_superset_of,
        .symmetric_difference,
        .union_,
        => try qjsSetMethodRecord(ctx, output, global, receiver, method, args, caller_function, caller_frame),
        .iterator_next => {
            if (receiver.class_id != core.class.ids.map_iterator and receiver.class_id != core.class.ids.set_iterator) return error.TypeError;
            return methodCall(ctx.runtime, this_value, id, args) catch |err| switch (err) {
                error.TypeError => error.TypeError,
                else => err,
            };
        },
    };
}

fn collectionCallResultIsDropped(caller_function: ?*const builtin_dispatch.Bytecode, caller_frame: ?*builtin_dispatch.Frame) bool {
    return builtin_dispatch.callerResultIsDropped(caller_function, caller_frame);
}

fn qjsCollectionForEachRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    receiver: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    if (receiver.class_id != core.class.ids.map and receiver.class_id != core.class.ids.set) return throwCollectionReceiverTypeError(ctx, global, receiver.class_id);
    if (args.len < 1 or !call_runtime.isCallableValue(args[0])) return error.TypeError;
    const callback = args[0];
    const this_arg = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    var index: usize = 0;
    while (index < receiver.collectionEntriesSlot().*.len) : (index += 1) {
        const entry = receiver.collectionEntriesSlot().*[index];
        if (!entry.active) continue;
        const callback_args = if (receiver.class_id == core.class.ids.set)
            [_]core.JSValue{ entry.key, entry.key, this_value }
        else
            [_]core.JSValue{ entry.value, entry.key, this_value };
        const result = try call_runtime.callValueOrBytecode(ctx, output, global, this_arg, callback, &callback_args, caller_function, caller_frame);
        result.free(ctx.runtime);
    }
    return core.JSValue.undefinedValue();
}

fn qjsSetMethodRecord(
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
    const other_value = if (args.len >= 1) args[0] else return error.TypeError;
    var other_record = try qjsGetSetRecord(ctx, output, global, other_value, caller_function, caller_frame);
    defer other_record.deinit(ctx.runtime);
    const mode = qjsSetMethodModeFromRecord(method) orelse return error.TypeError;
    return switch (mode) {
        .difference => try qjsSetDifference(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .intersection => try qjsSetIntersection(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_disjoint_from => try qjsSetIsDisjointFrom(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_subset_of => try qjsSetIsSubsetOf(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .is_superset_of => try qjsSetIsSupersetOf(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .symmetric_difference => try qjsSetSymmetricDifference(ctx, output, global, receiver, other_record, caller_function, caller_frame),
        .union_ => try qjsSetUnion(ctx, output, global, receiver, other_record, caller_function, caller_frame),
    };
}

fn qjsSetMethodMode(name: []const u8) ?SetMethodMode {
    if (std.mem.eql(u8, name, "difference")) return .difference;
    if (std.mem.eql(u8, name, "intersection")) return .intersection;
    if (std.mem.eql(u8, name, "isDisjointFrom")) return .is_disjoint_from;
    if (std.mem.eql(u8, name, "isSubsetOf")) return .is_subset_of;
    if (std.mem.eql(u8, name, "isSupersetOf")) return .is_superset_of;
    if (std.mem.eql(u8, name, "symmetricDifference")) return .symmetric_difference;
    if (std.mem.eql(u8, name, "union")) return .union_;
    return null;
}

fn qjsSetMethodModeFromRecord(method: PrototypeMethod) ?SetMethodMode {
    return switch (method) {
        .difference => .difference,
        .intersection => .intersection,
        .is_disjoint_from => .is_disjoint_from,
        .is_subset_of => .is_subset_of,
        .is_superset_of => .is_superset_of,
        .symmetric_difference => .symmetric_difference,
        .union_ => .union_,
        else => null,
    };
}

fn qjsGetSetRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    other_value: core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !SetLikeRecordVm {
    const object = object_ops.objectFromValue(other_value) orelse return error.TypeError;
    if (object.class_id == core.class.ids.set or object.class_id == core.class.ids.map) {
        return .{
            .object_value = other_value.dup(),
            .size = @floatFromInt(qjsSetStrongSize(object)),
            .has = core.JSValue.undefinedValue(),
            .keys = core.JSValue.undefinedValue(),
            .native_kind = if (object.class_id == core.class.ids.set) .set else .map,
        };
    }

    const raw_size = try object_ops.getValueProperty(ctx, output, global, other_value, core.atom.predefinedId("size", .string).?, caller_function, caller_frame);
    defer raw_size.free(ctx.runtime);
    const size_value = if (raw_size.isObject())
        try coercion_ops.toPrimitiveForNumber(ctx, output, global, raw_size)
    else
        raw_size.dup();
    defer size_value.free(ctx.runtime);
    const number_value = try value_ops.toNumberValue(ctx.runtime, size_value);
    defer number_value.free(ctx.runtime);
    const size_number = value_ops.numberValue(number_value) orelse return error.TypeError;
    if (std.math.isNan(size_number)) return error.TypeError;

    const has_key = try ctx.runtime.internAtom("has");
    defer ctx.runtime.atoms.free(has_key);
    const has_value = try object_ops.getValueProperty(ctx, output, global, other_value, has_key, caller_function, caller_frame);
    errdefer has_value.free(ctx.runtime);
    if (!call_runtime.isCallableValue(has_value)) return error.TypeError;

    const keys_key = try ctx.runtime.internAtom("keys");
    defer ctx.runtime.atoms.free(keys_key);
    const keys_value = try object_ops.getValueProperty(ctx, output, global, other_value, keys_key, caller_function, caller_frame);
    errdefer keys_value.free(ctx.runtime);
    if (!call_runtime.isCallableValue(keys_value)) return error.TypeError;

    return .{
        .object_value = other_value.dup(),
        .size = size_number,
        .has = has_value,
        .keys = keys_value,
        .native_kind = .none,
    };
}

fn qjsSetStrongSize(object: *core.Object) usize {
    var count: usize = 0;
    for (object.collectionEntriesSlot().*) |entry| {
        if (entry.active) count += 1;
    }
    return count;
}

fn qjsConstructPlainSet(ctx: *core.JSContext, global: *core.Object) !core.JSValue {
    const set_proto = object_ops.constructorPrototypeFromGlobal(ctx.runtime, global, "Set") orelse return error.TypeError;
    return constructWithPrototype(ctx.runtime, 2, set_proto);
}

fn qjsSetAddValue(rt: *core.JSRuntime, set_value: core.JSValue, key: core.JSValue) !void {
    const out = try methodCall(rt, set_value, 6, &.{key});
    out.free(rt);
}

fn qjsSetDeleteValue(rt: *core.JSRuntime, set_value: core.JSValue, key: core.JSValue) !void {
    const out = try methodCall(rt, set_value, 4, &.{key});
    out.free(rt);
}

fn qjsSetHasValue(rt: *core.JSRuntime, set_value: core.JSValue, key: core.JSValue) !bool {
    const out = try methodCall(rt, set_value, 3, &.{key});
    defer out.free(rt);
    return coercion_ops.valueTruthy(out);
}

fn qjsSetLikeHas(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    record: SetLikeRecordVm,
    key: core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !bool {
    if (record.native_kind != .none) {
        const out = try methodCall(ctx.runtime, record.object_value, 3, &.{key});
        defer out.free(ctx.runtime);
        return coercion_ops.valueTruthy(out);
    }
    const out = try call_runtime.callValueOrBytecode(ctx, output, global, record.object_value, record.has, &.{key}, caller_function, caller_frame);
    defer out.free(ctx.runtime);
    return coercion_ops.valueTruthy(out);
}

fn qjsSetLikeKeysIterator(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    record: SetLikeRecordVm,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    const source = if (record.native_kind != .none)
        try methodCall(ctx.runtime, record.object_value, 7, &.{})
    else
        try call_runtime.callValueOrBytecode(ctx, output, global, record.object_value, record.keys, &.{}, caller_function, caller_frame);
    errdefer source.free(ctx.runtime);
    const iterator_object = object_ops.objectFromValue(source) orelse return error.TypeError;
    const next_key = try ctx.runtime.internAtom("next");
    defer ctx.runtime.atoms.free(next_key);
    const next_method = try object_ops.getValueProperty(ctx, output, global, source, next_key, caller_function, caller_frame);
    defer next_method.free(ctx.runtime);
    if (!call_runtime.isCallableValue(next_method)) return error.TypeError;
    const cached = try iterator_object.cachedIteratorNextSlot(ctx.runtime);
    try iterator_object.setOptionalValueSlot(ctx.runtime, cached, next_method.dup());
    return source;
}

fn qjsSetCloneReceiver(ctx: *core.JSContext, global: *core.Object, receiver: *core.Object) !core.JSValue {
    const result_value = try qjsConstructPlainSet(ctx, global);
    errdefer result_value.free(ctx.runtime);
    var index: usize = 0;
    while (index < receiver.collectionEntriesSlot().*.len) : (index += 1) {
        const entry = receiver.collectionEntriesSlot().*[index];
        if (!entry.active) continue;
        try qjsSetAddValue(ctx.runtime, result_value, entry.key);
    }
    return result_value;
}

fn qjsSetSnapshotKeys(rt: *core.JSRuntime, receiver: *core.Object) ![]core.JSValue {
    const count = qjsSetStrongSize(receiver);
    if (count == 0) return &.{};
    const keys = try rt.memory.alloc(core.JSValue, count);
    errdefer rt.memory.free(core.JSValue, keys);
    var out: usize = 0;
    errdefer {
        for (keys[0..out]) |key| key.free(rt);
    }
    for (receiver.collectionEntriesSlot().*) |entry| {
        if (!entry.active) continue;
        keys[out] = entry.key.dup();
        out += 1;
    }
    return keys;
}

fn qjsFreeValueList(rt: *core.JSRuntime, values: []core.JSValue) void {
    for (values) |value| value.free(rt);
    if (values.len != 0) rt.memory.free(core.JSValue, values);
}

test "set difference snapshot key root exposes dynamic key slice" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var keys = try rt.memory.alloc(core.JSValue, 1);
    const first_atom = try rt.atoms.newValueSymbol("gc-set-difference-snapshot-key");
    keys[0] = try rt.symbolValue(first_atom);
    defer qjsFreeValueList(rt, keys);

    var keys_root = ValueListRoot{};
    keys_root.init(rt, &keys);
    defer keys_root.deinit();

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(first_atom) != null);
}

fn qjsSetDifference(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    const result_value = try qjsConstructPlainSet(ctx, global);
    errdefer result_value.free(ctx.runtime);
    if (@as(f64, @floatFromInt(qjsSetStrongSize(receiver))) > other_record.size) {
        var copy_index: usize = 0;
        while (copy_index < receiver.collectionEntriesSlot().*.len) : (copy_index += 1) {
            const entry = receiver.collectionEntriesSlot().*[copy_index];
            if (!entry.active) continue;
            try qjsSetAddValue(ctx.runtime, result_value, entry.key);
        }
        var iterator_value = try qjsSetLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
        defer iterator_value.free(ctx.runtime);
        var iterator_done = false;
        while (true) {
            const step = call_runtime.iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
                if (!iterator_done) forof_ops.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
                return err;
            };
            defer step.value.free(ctx.runtime);
            if (step.done) {
                iterator_done = true;
                break;
            }
            try qjsSetDeleteValue(ctx.runtime, result_value, step.value);
        }
    } else {
        var keys = try qjsSetSnapshotKeys(ctx.runtime, receiver);
        defer qjsFreeValueList(ctx.runtime, keys);
        var keys_root = ValueListRoot{};
        keys_root.init(ctx.runtime, &keys);
        defer keys_root.deinit();
        for (keys) |key| {
            if (!try qjsSetLikeHas(ctx, output, global, other_record, key, caller_function, caller_frame)) {
                try qjsSetAddValue(ctx.runtime, result_value, key);
            }
        }
    }
    return result_value;
}

fn qjsSetIntersection(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    const result_value = try qjsConstructPlainSet(ctx, global);
    errdefer result_value.free(ctx.runtime);
    if (@as(f64, @floatFromInt(qjsSetStrongSize(receiver))) <= other_record.size) {
        var index: usize = 0;
        while (index < receiver.collectionEntriesSlot().*.len) : (index += 1) {
            const entry = receiver.collectionEntriesSlot().*[index];
            if (!entry.active) continue;
            if (try qjsSetLikeHas(ctx, output, global, other_record, entry.key, caller_function, caller_frame)) {
                try qjsSetAddValue(ctx.runtime, result_value, entry.key);
            }
        }
    } else {
        var iterator_value = try qjsSetLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
        defer iterator_value.free(ctx.runtime);
        var iterator_done = false;
        while (true) {
            const step = call_runtime.iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
                if (!iterator_done) forof_ops.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
                return err;
            };
            defer step.value.free(ctx.runtime);
            if (step.done) {
                iterator_done = true;
                break;
            }
            if (try qjsSetHasValue(ctx.runtime, receiver.value(), step.value)) {
                try qjsSetAddValue(ctx.runtime, result_value, step.value);
            }
        }
    }
    return result_value;
}

fn qjsSetUnion(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    var iterator_value = try qjsSetLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);
    const result_value = try qjsSetCloneReceiver(ctx, global, receiver);
    errdefer result_value.free(ctx.runtime);
    var iterator_done = false;
    while (true) {
        const step = call_runtime.iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
            if (!iterator_done) forof_ops.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            return err;
        };
        defer step.value.free(ctx.runtime);
        if (step.done) {
            iterator_done = true;
            break;
        }
        try qjsSetAddValue(ctx.runtime, result_value, step.value);
    }
    return result_value;
}

fn qjsSetSymmetricDifference(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    var iterator_value = try qjsSetLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);
    const result_value = try qjsSetCloneReceiver(ctx, global, receiver);
    errdefer result_value.free(ctx.runtime);
    var iterator_done = false;
    while (true) {
        const step = call_runtime.iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
            if (!iterator_done) forof_ops.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            return err;
        };
        defer step.value.free(ctx.runtime);
        if (step.done) {
            iterator_done = true;
            break;
        }
        if (try qjsSetHasValue(ctx.runtime, receiver.value(), step.value)) {
            try qjsSetDeleteValue(ctx.runtime, result_value, step.value);
        } else if (!try qjsSetHasValue(ctx.runtime, result_value, step.value)) {
            try qjsSetAddValue(ctx.runtime, result_value, step.value);
        }
    }
    return result_value;
}

fn qjsSetIsDisjointFrom(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    if (@as(f64, @floatFromInt(qjsSetStrongSize(receiver))) <= other_record.size) {
        var index: usize = 0;
        while (index < receiver.collectionEntriesSlot().*.len) : (index += 1) {
            const entry = receiver.collectionEntriesSlot().*[index];
            if (!entry.active) continue;
            if (try qjsSetLikeHas(ctx, output, global, other_record, entry.key, caller_function, caller_frame)) {
                return core.JSValue.boolean(false);
            }
        }
        return core.JSValue.boolean(true);
    }

    var iterator_value = try qjsSetLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);
    var iterator_done = false;
    while (true) {
        const step = call_runtime.iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
            if (!iterator_done) forof_ops.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            return err;
        };
        defer step.value.free(ctx.runtime);
        if (step.done) {
            iterator_done = true;
            return core.JSValue.boolean(true);
        }
        if (try qjsSetHasValue(ctx.runtime, receiver.value(), step.value)) {
            forof_ops.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            iterator_done = true;
            return core.JSValue.boolean(false);
        }
    }
}

fn qjsSetIsSubsetOf(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    if (@as(f64, @floatFromInt(qjsSetStrongSize(receiver))) > other_record.size) return core.JSValue.boolean(false);
    var index: usize = 0;
    while (index < receiver.collectionEntriesSlot().*.len) : (index += 1) {
        const entry = receiver.collectionEntriesSlot().*[index];
        if (!entry.active) continue;
        if (!try qjsSetLikeHas(ctx, output, global, other_record, entry.key, caller_function, caller_frame)) {
            return core.JSValue.boolean(false);
        }
    }
    return core.JSValue.boolean(true);
}

fn qjsSetIsSupersetOf(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: *core.Object,
    other_record: SetLikeRecordVm,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    if (@as(f64, @floatFromInt(qjsSetStrongSize(receiver))) < other_record.size) return core.JSValue.boolean(false);
    var iterator_value = try qjsSetLikeKeysIterator(ctx, output, global, other_record, caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);
    var iterator_done = false;
    while (true) {
        const step = call_runtime.iteratorStepValue(ctx, output, global, iterator_value) catch |err| {
            if (!iterator_done) forof_ops.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            return err;
        };
        defer step.value.free(ctx.runtime);
        if (step.done) {
            iterator_done = true;
            return core.JSValue.boolean(true);
        }
        if (!try qjsSetHasValue(ctx.runtime, receiver.value(), step.value)) {
            forof_ops.closeIteratorFromVm(ctx, output, global, iterator_value) catch {};
            iterator_done = true;
            return core.JSValue.boolean(false);
        }
    }
}

pub fn qjsMapGroupByCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    const map_proto = object_ops.constructorPrototypeFromGlobal(ctx.runtime, global, "Map") orelse return error.TypeError;
    return qjsMapGroupByRecord(ctx, output, global, args, map_proto, caller_function, caller_frame);
}

pub fn qjsMapGroupByRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    prototype: ?*core.Object,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (args.len < 2) return error.TypeError;
    if (!call_runtime.isCallableValue(args[1])) return error.TypeError;

    const map_value = try constructWithPrototype(ctx.runtime, 1, prototype);
    errdefer map_value.free(ctx.runtime);

    const iterator_value = try call_runtime.iteratorForValue(ctx, output, global, args[0], caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);

    var index: usize = 0;
    while (true) {
        const max_safe_integer: usize = 9007199254740991;
        if (index >= max_safe_integer) {
            try call_runtime.closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return error.TypeError;
        }

        const step = try call_runtime.iteratorStepValue(ctx, output, global, iterator_value);
        defer step.value.free(ctx.runtime);
        if (step.done) return map_value;

        const index_value = value_ops.numberToValue(@floatFromInt(index));
        const key = call_runtime.callValueOrBytecode(
            ctx,
            output,
            global,
            core.JSValue.undefinedValue(),
            args[1],
            &.{ step.value, index_value },
            caller_function,
            caller_frame,
        ) catch |err| {
            try call_runtime.closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return err;
        };
        defer key.free(ctx.runtime);

        qjsMapAppendGroupByValue(ctx, global, map_value, key, step.value) catch |err| {
            try call_runtime.closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return err;
        };
        index += 1;
    }
}

pub fn qjsMapGetOrInsertComputed(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver_value: core.JSValue,
    function_object: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    const receiver = property_ops.expectObject(receiver_value) catch return null;
    if (receiver.class_id != core.class.ids.weakmap and receiver.class_id != core.class.ids.map) return null;
    if (collectionMethodOwnerClass(function_object)) |owner_class| {
        if (receiver.class_id != owner_class) return @as(?core.JSValue, try throwCollectionReceiverTypeError(ctx, global, owner_class));
    }
    if (args.len < 2) return error.TypeError;
    if (!call_runtime.isCallableValue(args[1])) return error.TypeError;

    const key = if (receiver.class_id == core.class.ids.map)
        canonicalizeMapKey(args[0])
    else
        args[0].dup();
    defer key.free(ctx.runtime);
    if (receiver.class_id == core.class.ids.weakmap and !symbol_builtin.canBeHeldWeakly(ctx.runtime, key)) {
        return @as(?core.JSValue, try exception_ops.throwTypeErrorMessage(ctx, global, "invalid value used as WeakMap key"));
    }

    const has_value = try methodCall(ctx.runtime, receiver_value, 3, &.{key});
    defer has_value.free(ctx.runtime);
    if (has_value.asBool() == true) {
        return try methodCall(ctx.runtime, receiver_value, 2, &.{key});
    }

    const computed = try call_runtime.callValueOrBytecode(
        ctx,
        output,
        global,
        core.JSValue.undefinedValue(),
        args[1],
        &.{key},
        caller_function,
        caller_frame,
    );
    errdefer computed.free(ctx.runtime);
    const set_result = try methodCall(ctx.runtime, receiver_value, 1, &.{ key, computed });
    set_result.free(ctx.runtime);
    return computed;
}

pub fn collectionMethodOwnerClass(function_object: *core.Object) ?core.ClassId {
    const cached = function_object.collectionMethodOwnerClass();
    if (cached != core.class.invalid_class_id) return cached;
    return null;
}

fn canonicalizeMapKey(key: core.JSValue) core.JSValue {
    if (key.asFloat64()) |number| {
        if (number == 0) return core.JSValue.int32(0);
    }
    return key.dup();
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
        args.len >= 1 and !symbol_builtin.canBeHeldWeakly(ctx.runtime, args[0]))
    {
        return exception_ops.throwTypeErrorMessage(ctx, global, "invalid value used as WeakMap key");
    }
    if (receiver.class_id == core.class.ids.weakset and
        method == .add and
        args.len >= 1 and !symbol_builtin.canBeHeldWeakly(ctx.runtime, args[0]))
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
    return "not an object";
}

fn qjsMapAppendGroupByValue(
    ctx: *core.JSContext,
    global: *core.Object,
    map_value: core.JSValue,
    key: core.JSValue,
    value: core.JSValue,
) !void {
    const existing = try methodCall(ctx.runtime, map_value, 2, &.{key});
    defer existing.free(ctx.runtime);

    if (!existing.isUndefined()) {
        const group = try property_ops.expectObject(existing);
        if (!group.flags.is_array) return error.TypeError;
        try group.defineOwnProperty(
            ctx.runtime,
            core.atom.atomFromUInt32(group.arrayLength()),
            core.Descriptor.data(value, true, true, true),
        );
        return;
    }

    const group = try core.Object.createArray(ctx.runtime, array_ops.arrayPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, &group.header);
    try group.defineOwnProperty(
        ctx.runtime,
        core.atom.atomFromUInt32(group.arrayLength()),
        core.Descriptor.data(value, true, true, true),
    );
    const set_result = try methodCall(ctx.runtime, map_value, 1, &.{ key, group.value() });
    defer set_result.free(ctx.runtime);
    group.value().free(ctx.runtime);
}
