const core = @import("../core/root.zig");
const std = @import("std");
const builtin_dispatch = @import("../exec/builtin_dispatch.zig");
const call = @import("../exec/call.zig");
const exceptions = @import("../exec/exceptions.zig");
const object_ops = @import("../exec/object_ops.zig");
const call_runtime = @import("../exec/call_runtime.zig");
const array_ops = @import("../exec/array_ops.zig");
const string_ops = @import("../exec/string_ops.zig");
const coercion_ops = @import("../exec/coercion_ops.zig");
const exception_ops = @import("../exec/vm_exception_ops.zig");
const property_ops = @import("../exec/property_ops.zig");
const value_ops = @import("../exec/value_ops.zig");
const buffer = @import("buffer.zig");

const HostError = exceptions.HostError;
const InternalCall = core.host_function.InternalCall;

// --- VM ops the relocated Object.* method implementations call back into.
// These stay in exec because opcode handlers / other exec modules dispatch
// them directly (builtins -> exec is the Phase 6 client model). The relocated
// methods reference them through these aliases, mirroring the alias web that
// lived alongside the implementations in object_ops.zig. ---
const IntegrityLevel = call_runtime.IntegrityLevel;
const objectFromValue = object_ops.objectFromValue;
const primitiveObjectForAccess = object_ops.primitiveObjectForAccess;
const objectRestOwnKeys = object_ops.objectRestOwnKeys;
const objectRestOwnPropertyDescriptor = object_ops.objectRestOwnPropertyDescriptor;
const getValueProperty = object_ops.getValueProperty;
const setValuePropertyStrict = object_ops.setValuePropertyStrict;
const toPropertyKeyAtom = object_ops.toPropertyKeyAtom;
const proxyAwareOwnPropertyDescriptor = object_ops.proxyAwareOwnPropertyDescriptor;
const proxyAwareExistsOwnProperty = object_ops.proxyAwareExistsOwnProperty;
const proxyDefineOwnProperty = object_ops.proxyDefineOwnProperty;
const proxyAwarePreventExtensions = object_ops.proxyAwarePreventExtensions;
const createDataPropertyOrThrow = object_ops.createDataPropertyOrThrow;
const descriptorObjectFromDescriptor = object_ops.descriptorObjectFromDescriptor;
const objectPrototypeFromGlobal = object_ops.objectPrototypeFromGlobal;
const functionPrototypeFromGlobal = object_ops.functionPrototypeFromGlobal;
const qjsObjectGetPrototypeOfStep = object_ops.qjsObjectGetPrototypeOfStep;
const qjsObjectGetPrototypeOfValue = object_ops.qjsObjectGetPrototypeOfValue;
const qjsDefinePropertiesOnTarget = call_runtime.qjsDefinePropertiesOnTarget;
const isCallableValue = call_runtime.isCallableValue;
const iteratorForValue = call_runtime.iteratorForValue;
const iteratorStepValue = call_runtime.iteratorStepValue;
const closeIteratorForFromEntriesAbrupt = call_runtime.closeIteratorForFromEntriesAbrupt;
const callValueOrBytecode = call_runtime.callValueOrBytecode;
const arrayPrototypeFromGlobal = array_ops.arrayPrototypeFromGlobal;
const valueTruthy = coercion_ops.valueTruthy;
const throwTypeErrorMessage = exception_ops.throwTypeErrorMessage;

// `EntriesMode` + `ownEntriesArray` relocated to engine core
// (`core/object.zig`) in Phase 6b-3 STEP 2; re-exported here unchanged so the
// install/dispatch side keeps the original names.
pub const EntriesMode = core.object.EntriesMode;

const RootedValueCopies = struct {
    values: []core.JSValue,
    roots: []core.runtime.ValueRootValue,

    fn init(rt: *core.JSRuntime, source: []const core.JSValue) !RootedValueCopies {
        const values = try rt.memory.alloc(core.JSValue, source.len);
        errdefer rt.memory.free(core.JSValue, values);
        @memcpy(values, source);

        const roots = try rt.memory.alloc(core.runtime.ValueRootValue, source.len);
        errdefer rt.memory.free(core.runtime.ValueRootValue, roots);
        for (values, 0..) |*value, index| {
            roots[index] = .{ .value = value };
        }

        return .{ .values = values, .roots = roots };
    }

    fn deinit(self: RootedValueCopies, rt: *core.JSRuntime) void {
        rt.memory.free(core.runtime.ValueRootValue, self.roots);
        rt.memory.free(core.JSValue, self.values);
    }
};

pub const StaticMethod = core.host_function.builtin_method_ids.object.StaticMethod;

pub const PrototypeMethod = enum(u32) {
    to_string = 101,
    to_locale_string = 102,
    value_of = 103,
    has_own_property = 104,
    is_prototype_of = 105,
    property_is_enumerable = 106,
    define_getter = 107,
    define_setter = 108,
    lookup_getter = 109,
    lookup_setter = 110,
};

pub fn staticMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "assign")) return @intFromEnum(StaticMethod.assign);
    if (std.mem.eql(u8, name, "create")) return @intFromEnum(StaticMethod.create);
    if (std.mem.eql(u8, name, "defineProperty")) return @intFromEnum(StaticMethod.define_property);
    if (std.mem.eql(u8, name, "defineProperties")) return @intFromEnum(StaticMethod.define_properties);
    if (std.mem.eql(u8, name, "getOwnPropertyDescriptor")) return @intFromEnum(StaticMethod.get_own_property_descriptor);
    if (std.mem.eql(u8, name, "getOwnPropertyDescriptors")) return @intFromEnum(StaticMethod.get_own_property_descriptors);
    if (std.mem.eql(u8, name, "getOwnPropertyNames")) return @intFromEnum(StaticMethod.get_own_property_names);
    if (std.mem.eql(u8, name, "getOwnPropertySymbols")) return @intFromEnum(StaticMethod.get_own_property_symbols);
    if (std.mem.eql(u8, name, "getPrototypeOf")) return @intFromEnum(StaticMethod.get_prototype_of);
    if (std.mem.eql(u8, name, "hasOwn")) return @intFromEnum(StaticMethod.has_own);
    if (std.mem.eql(u8, name, "isExtensible")) return @intFromEnum(StaticMethod.is_extensible);
    if (std.mem.eql(u8, name, "keys")) return @intFromEnum(StaticMethod.keys);
    if (std.mem.eql(u8, name, "preventExtensions")) return @intFromEnum(StaticMethod.prevent_extensions);
    if (std.mem.eql(u8, name, "seal")) return @intFromEnum(StaticMethod.seal);
    if (std.mem.eql(u8, name, "isSealed")) return @intFromEnum(StaticMethod.is_sealed);
    if (std.mem.eql(u8, name, "isFrozen")) return @intFromEnum(StaticMethod.is_frozen);
    if (std.mem.eql(u8, name, "setPrototypeOf")) return @intFromEnum(StaticMethod.set_prototype_of);
    if (std.mem.eql(u8, name, "values")) return @intFromEnum(StaticMethod.values);
    if (std.mem.eql(u8, name, "entries")) return @intFromEnum(StaticMethod.entries);
    if (std.mem.eql(u8, name, "is")) return @intFromEnum(StaticMethod.is);
    if (std.mem.eql(u8, name, "freeze")) return @intFromEnum(StaticMethod.freeze);
    if (std.mem.eql(u8, name, "fromEntries")) return @intFromEnum(StaticMethod.from_entries);
    if (std.mem.eql(u8, name, "groupBy")) return @intFromEnum(StaticMethod.group_by);
    return null;
}

pub fn staticMethodName(id: u32) ?[]const u8 {
    return switch (id) {
        @intFromEnum(StaticMethod.assign) => "assign",
        @intFromEnum(StaticMethod.create) => "create",
        @intFromEnum(StaticMethod.define_property) => "defineProperty",
        @intFromEnum(StaticMethod.define_properties) => "defineProperties",
        @intFromEnum(StaticMethod.get_own_property_descriptor) => "getOwnPropertyDescriptor",
        @intFromEnum(StaticMethod.get_own_property_descriptors) => "getOwnPropertyDescriptors",
        @intFromEnum(StaticMethod.get_own_property_names) => "getOwnPropertyNames",
        @intFromEnum(StaticMethod.get_own_property_symbols) => "getOwnPropertySymbols",
        @intFromEnum(StaticMethod.get_prototype_of) => "getPrototypeOf",
        @intFromEnum(StaticMethod.has_own) => "hasOwn",
        @intFromEnum(StaticMethod.is_extensible) => "isExtensible",
        @intFromEnum(StaticMethod.keys) => "keys",
        @intFromEnum(StaticMethod.prevent_extensions) => "preventExtensions",
        @intFromEnum(StaticMethod.seal) => "seal",
        @intFromEnum(StaticMethod.is_sealed) => "isSealed",
        @intFromEnum(StaticMethod.is_frozen) => "isFrozen",
        @intFromEnum(StaticMethod.set_prototype_of) => "setPrototypeOf",
        @intFromEnum(StaticMethod.values) => "values",
        @intFromEnum(StaticMethod.entries) => "entries",
        @intFromEnum(StaticMethod.is) => "is",
        @intFromEnum(StaticMethod.freeze) => "freeze",
        @intFromEnum(StaticMethod.from_entries) => "fromEntries",
        @intFromEnum(StaticMethod.group_by) => "groupBy",
        else => null,
    };
}

pub fn prototypeMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "toString")) return @intFromEnum(PrototypeMethod.to_string);
    if (std.mem.eql(u8, name, "toLocaleString")) return @intFromEnum(PrototypeMethod.to_locale_string);
    if (std.mem.eql(u8, name, "valueOf")) return @intFromEnum(PrototypeMethod.value_of);
    if (std.mem.eql(u8, name, "hasOwnProperty")) return @intFromEnum(PrototypeMethod.has_own_property);
    if (std.mem.eql(u8, name, "isPrototypeOf")) return @intFromEnum(PrototypeMethod.is_prototype_of);
    if (std.mem.eql(u8, name, "propertyIsEnumerable")) return @intFromEnum(PrototypeMethod.property_is_enumerable);
    if (std.mem.eql(u8, name, "__defineGetter__")) return @intFromEnum(PrototypeMethod.define_getter);
    if (std.mem.eql(u8, name, "__defineSetter__")) return @intFromEnum(PrototypeMethod.define_setter);
    if (std.mem.eql(u8, name, "__lookupGetter__")) return @intFromEnum(PrototypeMethod.lookup_getter);
    if (std.mem.eql(u8, name, "__lookupSetter__")) return @intFromEnum(PrototypeMethod.lookup_setter);
    return null;
}

pub fn prototypeMethodOrdinal(id: u32) ?i32 {
    return switch (id) {
        @intFromEnum(PrototypeMethod.to_string) => 1,
        @intFromEnum(PrototypeMethod.to_locale_string) => 2,
        @intFromEnum(PrototypeMethod.value_of) => 3,
        @intFromEnum(PrototypeMethod.has_own_property) => 4,
        @intFromEnum(PrototypeMethod.is_prototype_of) => 5,
        @intFromEnum(PrototypeMethod.property_is_enumerable) => 6,
        @intFromEnum(PrototypeMethod.define_getter) => 7,
        @intFromEnum(PrototypeMethod.define_setter) => 8,
        @intFromEnum(PrototypeMethod.lookup_getter) => 9,
        @intFromEnum(PrototypeMethod.lookup_setter) => 10,
        else => null,
    };
}

fn staticEntry(comptime name: []const u8, comptime length: u8, comptime method: StaticMethod) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = @intFromEnum(method), .magic = @intFromEnum(method), .prepared_call_ok = false, .call = &objectCall };
}

fn prototypeEntry(comptime name: []const u8, comptime length: u8, comptime method: PrototypeMethod) core.host_function.InternalEntry {
    return .{ .name = name, .length = length, .id = @intFromEnum(method), .magic = @intFromEnum(method), .prepared_call_ok = false, .call = &objectCall };
}

/// Declaration table for the `.object` domain: one entry per `Object.*` static
/// and `Object.prototype.*` method. `id`/`magic` are the `StaticMethod`/
/// `PrototypeMethod` enum values consumed by `qjsObjectCallForNativeRecord` and
/// the bare-runtime fallback, kept in lockstep with the install names in
/// `registry.object_static`/`object_prototype`. Every record sets
/// `prepared_call_ok = false`: Object methods need a realm global and/or the
/// shared property helper web, matching the prepared-call gate
/// (`vm_call.nativeBuiltinSupportedWithoutFunctionObject` returns false for
/// `.object`).
pub const internal_entries = [_]core.host_function.InternalEntry{
    staticEntry("assign", 2, .assign),
    staticEntry("create", 2, .create),
    staticEntry("defineProperty", 3, .define_property),
    staticEntry("defineProperties", 2, .define_properties),
    staticEntry("getOwnPropertyDescriptor", 2, .get_own_property_descriptor),
    staticEntry("getOwnPropertyDescriptors", 1, .get_own_property_descriptors),
    staticEntry("getOwnPropertyNames", 1, .get_own_property_names),
    staticEntry("getOwnPropertySymbols", 1, .get_own_property_symbols),
    staticEntry("getPrototypeOf", 1, .get_prototype_of),
    staticEntry("hasOwn", 2, .has_own),
    staticEntry("isExtensible", 1, .is_extensible),
    staticEntry("keys", 1, .keys),
    staticEntry("preventExtensions", 1, .prevent_extensions),
    staticEntry("seal", 1, .seal),
    staticEntry("isSealed", 1, .is_sealed),
    staticEntry("isFrozen", 1, .is_frozen),
    staticEntry("setPrototypeOf", 2, .set_prototype_of),
    staticEntry("values", 1, .values),
    staticEntry("entries", 1, .entries),
    staticEntry("is", 2, .is),
    staticEntry("freeze", 1, .freeze),
    staticEntry("fromEntries", 1, .from_entries),
    staticEntry("groupBy", 2, .group_by),
    prototypeEntry("toString", 0, .to_string),
    prototypeEntry("toLocaleString", 0, .to_locale_string),
    prototypeEntry("valueOf", 0, .value_of),
    prototypeEntry("hasOwnProperty", 1, .has_own_property),
    prototypeEntry("isPrototypeOf", 1, .is_prototype_of),
    prototypeEntry("propertyIsEnumerable", 1, .property_is_enumerable),
    prototypeEntry("__defineGetter__", 2, .define_getter),
    prototypeEntry("__defineSetter__", 2, .define_setter),
    prototypeEntry("__lookupGetter__", 1, .lookup_getter),
    prototypeEntry("__lookupSetter__", 1, .lookup_setter),
};

/// Shared record handler for the `.object` domain. With a realm global the
/// statics and prototype methods dispatch through `objectCallForNativeRecord`
/// below (the relocated `Object.*` implementations, now co-located with the
/// declaration table); the bare-runtime (no global) path takes the
/// primitive-only `call.objectPrototypeMethodCall`/`call.callObjectStatic`
/// fallbacks that live with the shared property helpers in call.zig.
fn objectCall(host_call: InternalCall) HostError!core.JSValue {
    const ctx = host_call.ctx;
    const output = host_call.output;
    const global = host_call.global;
    const globals = host_call.globals;
    const id: u32 = host_call.magic;
    const args = host_call.args;
    const this_value = host_call.this_value;
    const caller_function = builtin_dispatch.callerBytecode(host_call);
    const caller_frame = builtin_dispatch.callerFrame(host_call);

    if (global) |global_object| return try objectCallForNativeRecord(ctx, output, global_object, this_value, id, args, caller_function, caller_frame);
    if (prototypeMethodOrdinal(id)) |method| {
        return call.objectPrototypeMethodCall(ctx, output, global, globals, method, this_value, args);
    }
    return call.callObjectStatic(ctx, output, global, globals, id, args) catch |err| switch (err) {
        error.TypeError => error.TypeError,
        else => err,
    };
}

/// Realm-global dispatcher for the `.object` domain methods. Relocated from
/// `exec/object_ops.zig` (Phase 6b-2): the builtins handler now holds the
/// `Object.*` static/prototype dispatch directly instead of delegating to exec.
/// Branches whose implementation stays in exec — because an opcode handler or
/// another exec module also calls it (`defineProperty`/`isExtensible`/
/// `setPrototypeOf`/`keys`/`values`/`entries`/`defineProperties`) or it is a
/// prototype method parked in another domain file (`toString`/`toLocaleString`)
/// — call back into exec through the qualified module path.
fn objectCallForNativeRecord(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    id: u32,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) HostError!core.JSValue {
    return switch (id) {
        @intFromEnum(StaticMethod.assign) => (try qjsObjectAssignCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(StaticMethod.create) => (try qjsObjectCreateCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(StaticMethod.define_property) => (try object_ops.qjsDefinePropertyWithKind(ctx, output, global, args, 1, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(StaticMethod.define_properties) => (try call_runtime.qjsDefinePropertiesCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(StaticMethod.get_own_property_descriptor) => (try qjsGetOwnPropertyDescriptorCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(StaticMethod.get_own_property_descriptors) => (try qjsGetOwnPropertyDescriptorsCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(StaticMethod.get_own_property_names) => (try qjsObjectOwnPropertyKeysCall(ctx, output, global, args, .string, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(StaticMethod.get_own_property_symbols) => (try qjsObjectOwnPropertyKeysCall(ctx, output, global, args, .symbol, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(StaticMethod.get_prototype_of) => (try qjsObjectGetPrototypeOfCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(StaticMethod.has_own) => (try qjsObjectHasOwnCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(StaticMethod.is_extensible) => (try object_ops.qjsObjectIsExtensibleCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(StaticMethod.keys) => (try object_ops.qjsObjectEnumerableOwnPropertiesCall(ctx, output, global, args, .keys, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(StaticMethod.prevent_extensions) => (try qjsObjectPreventExtensionsCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(StaticMethod.seal) => (try qjsObjectSetIntegrityCall(ctx, output, global, args, .sealed, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(StaticMethod.is_sealed) => (try qjsObjectTestIntegrityCall(ctx, output, global, args, .sealed)) orelse error.TypeError,
        @intFromEnum(StaticMethod.is_frozen) => (try qjsObjectTestIntegrityCall(ctx, output, global, args, .frozen)) orelse error.TypeError,
        @intFromEnum(StaticMethod.set_prototype_of) => (try object_ops.qjsObjectSetPrototypeOfCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(StaticMethod.values) => (try object_ops.qjsObjectEnumerableOwnPropertiesCall(ctx, output, global, args, .values, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(StaticMethod.entries) => (try object_ops.qjsObjectEnumerableOwnPropertiesCall(ctx, output, global, args, .entries, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(StaticMethod.is) => {
            const lhs = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
            const rhs = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
            return core.JSValue.boolean(lhs.sameValue(rhs));
        },
        @intFromEnum(StaticMethod.freeze) => (try qjsObjectSetIntegrityCall(ctx, output, global, args, .frozen, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(StaticMethod.from_entries) => (try qjsObjectFromEntriesCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(StaticMethod.group_by) => (try qjsObjectGroupByCall(ctx, output, global, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(PrototypeMethod.to_string) => try string_ops.qjsObjectToStringCall(ctx, output, global, this_value, caller_function, caller_frame),
        @intFromEnum(PrototypeMethod.to_locale_string) => try string_ops.qjsObjectToLocaleStringCall(ctx, output, global, this_value, caller_function, caller_frame),
        @intFromEnum(PrototypeMethod.value_of) => try qjsObjectValueOfCall(ctx.runtime, global, this_value),
        @intFromEnum(PrototypeMethod.has_own_property) => (try qjsObjectPrototypeOwnPropertyCall(ctx, output, global, this_value, id, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(PrototypeMethod.is_prototype_of) => try qjsObjectIsPrototypeOf(ctx, output, global, this_value, args, caller_function, caller_frame),
        @intFromEnum(PrototypeMethod.property_is_enumerable) => (try qjsObjectPrototypeOwnPropertyCall(ctx, output, global, this_value, id, args, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(PrototypeMethod.define_getter) => (try qjsObjectPrototypeDefineAccessorCall(ctx, output, global, this_value, args, true, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(PrototypeMethod.define_setter) => (try qjsObjectPrototypeDefineAccessorCall(ctx, output, global, this_value, args, false, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(PrototypeMethod.lookup_getter) => (try qjsObjectPrototypeLookupAccessorCall(ctx, output, global, this_value, args, true, caller_function, caller_frame)) orelse error.TypeError,
        @intFromEnum(PrototypeMethod.lookup_setter) => (try qjsObjectPrototypeLookupAccessorCall(ctx, output, global, this_value, args, false, caller_function, caller_frame)) orelse error.TypeError,
        else => error.TypeError,
    };
}

pub fn create(rt: *core.JSRuntime, prototype: ?*core.Object) !*core.Object {
    return core.Object.create(rt, core.class.ids.object, prototype);
}

pub fn keys(rt: *core.JSRuntime, object: *core.Object) ![]core.Atom {
    return object.ownKeys(rt);
}

/// QuickJS source map: narrow object-literal helper used by transitional
/// `new_object` bytecode.
pub fn literal(rt: *core.JSRuntime, names: []const core.Atom, values: []const core.JSValue) !core.JSValue {
    if (names.len != values.len) return error.TypeError;
    const rooted = try RootedValueCopies.init(rt, values);
    defer rooted.deinit(rt);
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = rooted.roots,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const object = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &object.header);

    for (names, rooted.values) |name, value| {
        try object.defineOwnProperty(rt, name, core.Descriptor.data(value, true, true, true));
    }
    return object.value();
}

test "object literal roots direct function bytecode values while creating object" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const key = try rt.internAtom("value");
    defer rt.atoms.free(key);
    const names = [_]core.Atom{key};

    const fb_slice = try rt.memory.alloc(core.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = core.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-object-literal-bytecode-symbol");
    fb.cpool[0] = try rt.symbolValue(symbol_atom);
    fb.cpool_count = 1;

    var literal_value = core.JSValue.functionBytecode(&fb.header);
    var literal_alive = true;
    defer if (literal_alive) literal_value.free(rt);
    const values = [_]core.JSValue{literal_value};

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const object_value = try literal(rt, &names, &values);
    var object_alive = true;
    defer if (object_alive) object_value.free(rt);
    const object = try expectObject(object_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = object.getProperty(key);
        defer stored.free(rt);
        try std.testing.expect(stored.same(literal_value));
    }

    object_value.free(rt);
    object_alive = false;
    literal_value.free(rt);
    literal_alive = false;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

// Relocated to engine core (`core/object.zig`) in Phase 6b-3 STEP 2; the pure
// own-property iteration constructor now lives there. Re-exported unchanged.
// (The `entryArrayValue`/`atomToStringValue` helpers below remain here only as
// the subjects of the GC-rooting unit test that follows.)
pub const ownEntriesArray = core.object.ownEntriesArray;

fn expectObject(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

fn entryArrayValue(rt: *core.JSRuntime, key: core.Atom, value: core.JSValue) !core.JSValue {
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

    const array = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &array.header);
    const key_value = try atomToStringValue(rt, key);
    defer key_value.free(rt);
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(key_value, true, true, true));
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(1), core.Descriptor.data(rooted_value, true, true, true));
    return array.value();
}

test "object entryArrayValue roots direct function bytecode value while creating entry array" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const key = try rt.internAtom("entryKey");
    defer rt.atoms.free(key);

    const fb_slice = try rt.memory.alloc(core.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = core.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    const symbol_atom = try rt.atoms.newValueSymbol("gc-object-entry-array-value-bytecode-symbol");
    fb.cpool[0] = try rt.symbolValue(symbol_atom);
    fb.cpool_count = 1;

    var entry_value = core.JSValue.functionBytecode(&fb.header);
    var entry_value_alive = true;
    defer if (entry_value_alive) entry_value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const pair_value = try entryArrayValue(rt, key, entry_value.dup());
    var pair_alive = true;
    defer if (pair_alive) pair_value.free(rt);
    const pair = try expectObject(pair_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    {
        const stored = pair.getProperty(core.atom.atomFromUInt32(1));
        defer stored.free(rt);
        try std.testing.expect(stored.same(entry_value));
    }

    pair_value.free(rt);
    pair_alive = false;
    entry_value.free(rt);
    entry_value_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn atomToStringValue(rt: *core.JSRuntime, atom_id: core.Atom) !core.JSValue {
    return rt.atoms.toStringValue(rt, atom_id);
}

// ==========================================================================
// Relocated Object.* method implementations (Phase 6b-2).
//
// Moved verbatim from exec/object_ops.zig: these implementations are reachable
// only through the .object record dispatch (objectCallForNativeRecord above),
// so per the QuickJS client model they live with the declaration table. They
// call back into exec VM ops (property/coercion/iterator/call helpers) through
// the aliases declared near the top of this file (builtins -> exec is legal).
// ==========================================================================

pub fn qjsObjectIsPrototypeOf(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !core.JSValue {
    if (args.len == 0) return core.JSValue.boolean(false);
    var current = objectFromValue(args[0]) orelse return core.JSValue.boolean(false);
    const this_object = objectFromValue(this_value) orelse return error.TypeError;
    while (try qjsObjectGetPrototypeOfStep(ctx, output, global, current, caller_function, caller_frame)) |prototype| {
        if (prototype == this_object) return core.JSValue.boolean(true);
        current = prototype;
    }
    return core.JSValue.boolean(false);
}

pub fn qjsObjectValueOfCall(rt: *core.JSRuntime, global: *core.Object, this_value: core.JSValue) !core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    if (this_value.isObject()) return this_value.dup();
    return primitiveObjectForAccess(rt, global, this_value);
}

pub fn qjsObjectCreateCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    const prototype: ?*core.Object = if (args[0].isNull())
        null
    else
        objectFromValue(args[0]) orelse return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "object prototype may only be an Object or null"));
    const object = try core.Object.create(ctx.runtime, core.class.ids.object, prototype);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &object.header);
    object.flags.null_prototype = args[0].isNull();
    if (args.len >= 2 and !args[1].isUndefined()) {
        try qjsDefinePropertiesOnTarget(ctx, output, global, object, args[1], caller_function, caller_frame);
    }
    return object.value();
}

pub fn qjsObjectAssignCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    if (args[0].isNull() or args[0].isUndefined()) return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "Cannot convert undefined or null to object"));
    const target_value = if (objectFromValue(args[0])) |_| args[0].dup() else try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    errdefer target_value.free(ctx.runtime);
    _ = objectFromValue(target_value) orelse return error.TypeError;

    for (args[1..]) |source_arg| {
        if (source_arg.isNull() or source_arg.isUndefined()) continue;
        const source_value = if (objectFromValue(source_arg)) |_| source_arg.dup() else try primitiveObjectForAccess(ctx.runtime, global, source_arg);
        defer source_value.free(ctx.runtime);
        const source = objectFromValue(source_value) orelse return error.TypeError;
        const own_keys = try objectRestOwnKeys(ctx, output, global, source);
        defer core.Object.freeKeys(ctx.runtime, own_keys);
        if (assignSourceIsOrdinary(source)) {
            // qjs js_object_assign is ONE JS_CopyDataProperties walk with
            // JS_GPN_ENUM_ONLY (quickjs.c:40654 -> 16920). For an ordinary
            // (non-exotic, non-proxy) source the enumerability is filtered
            // INLINE during the shape walk (quickjs.c:8628) and no per-key
            // descriptor is materialized (the ~ENUM_ONLY descriptor branch
            // at quickjs.c:16942 runs only for the exotic fallback). Mirror
            // that single enumerable-only spec-ordered pass here.
            try qjsObjectAssignEnumOnly(ctx, output, global, target_value, source_value, source, own_keys, caller_function, caller_frame);
        } else {
            // Proxy / exotic source: qjs clears JS_GPN_ENUM_ONLY
            // (quickjs.c:16924) and builds a per-key descriptor in the loop
            // so the ownKeys + getOwnPropertyDescriptor traps fire in order.
            // Keep the descriptor-driven single pass that preserves the trap
            // sequence (symbol_pass = null = no extra traversal).
            try qjsObjectAssignKeys(ctx, output, global, target_value, source_value, source, own_keys, null, caller_function, caller_frame);
        }
    }

    return target_value;
}

/// True when `Object.assign`'s source is an ordinary object — no proxy
/// handler, no typed-array indexed exotic, no module-namespace bindings,
/// and no exotic own-keys hook. This mirrors qjs's `!p->is_exotic ||
/// !em->get_own_property_names` test (quickjs.c:16920-16927): only such a
/// source keeps `JS_GPN_ENUM_ONLY` and reads the enumerable bit straight
/// off the shape. Everything else falls through to the descriptor path so
/// its traps/exotic enumeration fire exactly as qjs's ~ENUM_ONLY branch.
fn assignSourceIsOrdinary(source: *core.Object) bool {
    if (source.proxyTarget() != null) return false;
    if (source.hasExoticMethods()) return false;
    if (source.class_id == core.class.ids.module_ns) return false;
    if (core.object.isTypedArrayObject(source)) return false;
    return true;
}

/// Single ENUM_ONLY CopyDataProperties pass over an ordinary source's own
/// keys (already in spec order: integer indices ascending, then strings in
/// insertion order, then symbols). Enumerability is filtered ONCE at walk
/// time — exactly like qjs's JS_GPN_ENUM_ONLY GPN walk, which materializes
/// only the enumerable keys (quickjs.c:8628) BEFORE any user code runs.
/// The copy loop then does NO per-key enumerable re-check (quickjs.c:16933
/// skips the descriptor branch for ordinary sources): for each snapshotted
/// key it runs JS_GetProperty (the source getter fires once, in key order)
/// then JS_SetProperty on the target (target setters / Proxy traps fire).
/// Snapshotting up front is load-bearing: a getter on an earlier key may
/// mutate a later key's enumerability/existence, and qjs copies the key
/// regardless because it was already in the enumerable list. This is the
/// deliberate difference from Object.keys/values/entries, which re-check
/// enumerability per key after getters (quickjs.c:40400) and which zjs
/// keeps on its own descriptor path.
fn qjsObjectAssignEnumOnly(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target_value: core.JSValue,
    source_value: core.JSValue,
    source: *core.Object,
    own_keys: []const core.Atom,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !void {
    if (own_keys.len == 0) return;
    // Snapshot the enumerable bit of every key off the shape now, before
    // any getter/setter runs — mirroring qjs filling tab_atom[] with only
    // the enumerable keys during the ENUM_ONLY GPN walk.
    const enumerable_snapshot = try ctx.runtime.memory.alloc(bool, own_keys.len);
    defer ctx.runtime.memory.free(bool, enumerable_snapshot);
    for (own_keys, enumerable_snapshot) |key, *slot| {
        slot.* = source.ownPropertyEnumerable(key) orelse false;
    }
    for (own_keys, enumerable_snapshot) |key, enumerable| {
        if (!enumerable) continue;
        const value = try getValueProperty(ctx, output, global, source_value, key, caller_function, caller_frame);
        defer value.free(ctx.runtime);
        try setValuePropertyStrict(ctx, output, global, target_value, key, value, caller_function, caller_frame);
    }
}

pub fn qjsObjectAssignKeys(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    target_value: core.JSValue,
    source_value: core.JSValue,
    source: *core.Object,
    own_keys: []const core.Atom,
    symbol_pass: ?bool,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !void {
    for (own_keys) |key| {
        const is_symbol = ctx.runtime.atoms.isPublicSymbol(key);
        if (symbol_pass) |pass| {
            if (is_symbol != pass) continue;
        }
        const desc = try objectRestOwnPropertyDescriptor(ctx, output, global, source, key) orelse continue;
        defer desc.destroy(ctx.runtime);
        if (desc.enumerable != true) continue;
        const value = try getValueProperty(ctx, output, global, source_value, key, caller_function, caller_frame);
        defer value.free(ctx.runtime);
        try setValuePropertyStrict(ctx, output, global, target_value, key, value, caller_function, caller_frame);
    }
}

pub fn qjsObjectHasOwnCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (args.len < 1) return null;
    if (args[0].isNull() or args[0].isUndefined()) return error.TypeError;
    const object_value = if (objectFromValue(args[0])) |_| args[0].dup() else try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    defer object_value.free(ctx.runtime);
    const object = objectFromValue(object_value) orelse return error.TypeError;
    const key_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame);
    defer ctx.runtime.atoms.free(atom_id);
    // qjs `js_object_hasOwn` -> `JS_GetOwnPropertyInternal(ctx, NULL, p, atom)`:
    // the desc==NULL existence mode (quickjs.c:8854) -- no descriptor is built,
    // no value is dup'd, and auto-init instantiation is delayed. Proxies still
    // route through the full getOwnPropertyDescriptor trap inside the wrapper.
    const present = try proxyAwareExistsOwnProperty(ctx, output, global, object, atom_id, caller_function, caller_frame);
    return core.JSValue.boolean(present);
}

pub fn qjsObjectPrototypeOwnPropertyCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    method_id: u32,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (method_id != @intFromEnum(PrototypeMethod.has_own_property) and method_id != @intFromEnum(PrototypeMethod.property_is_enumerable)) return null;

    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame);
    defer ctx.runtime.atoms.free(atom_id);

    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    const object_value = if (objectFromValue(this_value)) |_| this_value.dup() else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    defer object_value.free(ctx.runtime);
    const object = property_ops.expectObject(object_value) catch return error.TypeError;
    // `hasOwnProperty` is the desc==NULL existence mode of
    // `JS_GetOwnPropertyInternal` (qjs `js_object_hasOwnProperty`,
    // quickjs.c:40536): probe presence with no descriptor materialization.
    // `propertyIsEnumerable` (qjs `js_object_propertyIsEnumerable`) still
    // needs the enumerable flag, so it keeps the full-descriptor path.
    if (method_id == @intFromEnum(PrototypeMethod.has_own_property)) {
        const present = try proxyAwareExistsOwnProperty(ctx, output, global, object, atom_id, caller_function, caller_frame);
        return core.JSValue.boolean(present);
    }
    const desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, object, atom_id, caller_function, caller_frame) orelse return core.JSValue.boolean(false);
    defer desc.destroy(ctx.runtime);
    return core.JSValue.boolean(desc.enumerable orelse false);
}

pub fn qjsObjectPrototypeDefineAccessorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    getter: bool,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    const object_value = if (objectFromValue(this_value)) |_| this_value.dup() else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    defer object_value.free(ctx.runtime);
    const object = objectFromValue(object_value) orelse return error.TypeError;
    const accessor_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    if (!isCallableValue(accessor_value)) return error.TypeError;
    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const key = try toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame);
    defer ctx.runtime.atoms.free(key);

    const desc = if (getter) core.Descriptor{
        .kind = .accessor,
        .getter = accessor_value.dup(),
        .getter_present = true,
        .enumerable = true,
        .configurable = true,
    } else core.Descriptor{
        .kind = .accessor,
        .setter = accessor_value.dup(),
        .setter_present = true,
        .enumerable = true,
        .configurable = true,
    };
    defer desc.destroy(ctx.runtime);
    const defined = if (object.proxyTarget() != null)
        proxyDefineOwnProperty(ctx, output, global, object, key, desc, caller_function, caller_frame) catch |err| switch (err) {
            error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
            error.InvalidLength => return error.RangeError,
            else => return err,
        }
    else blk: {
        object.defineOwnProperty(ctx.runtime, key, desc) catch |err| switch (err) {
            error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
            error.InvalidLength => return error.RangeError,
            else => return err,
        };
        break :blk true;
    };
    if (!defined) return error.TypeError;
    return core.JSValue.undefinedValue();
}

pub fn qjsObjectPrototypeLookupAccessorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    this_value: core.JSValue,
    args: []const core.JSValue,
    getter: bool,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (this_value.isNull() or this_value.isUndefined()) return error.TypeError;
    const object_value = if (objectFromValue(this_value)) |_| this_value.dup() else try primitiveObjectForAccess(ctx.runtime, global, this_value);
    defer object_value.free(ctx.runtime);
    var object = objectFromValue(object_value) orelse return error.TypeError;
    const key_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const key = try toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame);
    defer ctx.runtime.atoms.free(key);

    while (true) {
        const desc = try objectRestOwnPropertyDescriptor(ctx, output, global, object, key);
        if (desc) |item| {
            defer item.destroy(ctx.runtime);
            if (item.kind != .accessor) return core.JSValue.undefinedValue();
            if (getter) return if (item.getter_present) item.getter.dup() else core.JSValue.undefinedValue();
            return if (item.setter_present) item.setter.dup() else core.JSValue.undefinedValue();
        }
        object = (try qjsObjectGetPrototypeOfStep(ctx, output, global, object, caller_function, caller_frame)) orelse return core.JSValue.undefinedValue();
    }
}

pub fn qjsObjectFromEntriesCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    const out = try core.Object.create(ctx.runtime, core.class.ids.object, objectPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
    const out_value = out.value();

    const iterator_value = try iteratorForValue(ctx, output, global, args[0], caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);

    while (true) {
        const step = try iteratorStepValue(ctx, output, global, iterator_value);
        defer step.value.free(ctx.runtime);
        if (step.done) return out_value;

        const entry = objectFromValue(step.value) orelse {
            try closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return error.TypeError;
        };
        const key_value = getValueProperty(ctx, output, global, entry.value(), core.atom.atomFromUInt32(0), caller_function, caller_frame) catch |err| {
            try closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return err;
        };
        defer key_value.free(ctx.runtime);
        const value = getValueProperty(ctx, output, global, entry.value(), core.atom.atomFromUInt32(1), caller_function, caller_frame) catch |err| {
            try closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return err;
        };
        defer value.free(ctx.runtime);
        const key = toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame) catch |err| {
            try closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return err;
        };
        defer ctx.runtime.atoms.free(key);
        createDataPropertyOrThrow(ctx, output, global, out_value, out, key, value, caller_function, caller_frame) catch |err| {
            try closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return err;
        };
    }
}

pub fn qjsObjectGroupByCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (args.len < 2) return error.TypeError;
    if (!isCallableValue(args[1])) return error.TypeError;
    const out = try core.Object.create(ctx.runtime, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
    out.flags.null_prototype = true;
    const out_value = out.value();

    const iterator_value = try iteratorForValue(ctx, output, global, args[0], caller_function, caller_frame);
    defer iterator_value.free(ctx.runtime);

    var index: usize = 0;
    while (true) {
        const max_safe_integer: usize = 9007199254740991;
        if (index >= max_safe_integer) {
            try closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return error.TypeError;
        }
        const step = try iteratorStepValue(ctx, output, global, iterator_value);
        defer step.value.free(ctx.runtime);
        if (step.done) return out_value;

        const index_value = value_ops.numberToValue(@floatFromInt(index));
        const raw_key = callValueOrBytecode(ctx, output, global, core.JSValue.undefinedValue(), args[1], &.{ step.value, index_value }, caller_function, caller_frame) catch |err| {
            try closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return err;
        };
        defer raw_key.free(ctx.runtime);
        const key = toPropertyKeyAtom(ctx, output, global, raw_key, caller_function, caller_frame) catch |err| {
            try closeIteratorForFromEntriesAbrupt(ctx, output, global, iterator_value);
            return err;
        };
        defer ctx.runtime.atoms.free(key);
        try appendObjectGroupByValue(ctx, output, global, out_value, out, key, step.value, caller_function, caller_frame);
        index += 1;
    }
}

pub fn qjsObjectSetIntegrityCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    level: IntegrityLevel,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const object = objectFromValue(target_value) orelse return target_value.dup();
    if (level == .frozen and buffer.typedArrayBackedByResizableBuffer(object)) return error.TypeError;
    if (try qjsObjectPreventExtensionsCall(ctx, output, global, args, caller_function, caller_frame)) |prevented| {
        prevented.free(ctx.runtime);
    } else return error.TypeError;

    const own_keys = try objectRestOwnKeys(ctx, output, global, object);
    defer core.Object.freeKeys(ctx.runtime, own_keys);
    for (own_keys) |key| {
        const desc = if (level == .frozen)
            try objectRestOwnPropertyDescriptor(ctx, output, global, object, key)
        else
            null;
        defer if (desc) |item| item.destroy(ctx.runtime);

        const next_desc = switch (level) {
            .sealed => core.Descriptor.generic(null, false),
            .frozen => blk: {
                if (desc) |item| {
                    if (item.kind == .data) break :blk core.Descriptor{
                        .kind = .data,
                        .value_present = false,
                        .writable = false,
                        .configurable = false,
                    };
                }
                break :blk core.Descriptor.generic(null, false);
            },
        };
        const defined = if (object.proxyTarget() != null)
            try proxyDefineOwnProperty(ctx, output, global, object, key, next_desc, caller_function, caller_frame)
        else blk: {
            object.defineOwnProperty(ctx.runtime, key, next_desc) catch |err| switch (err) {
                error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return error.TypeError,
                error.InvalidLength => return error.RangeError,
                else => return err,
            };
            break :blk true;
        };
        if (!defined) return error.TypeError;
    }
    return target_value.dup();
}

pub fn qjsObjectTestIntegrityCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    level: IntegrityLevel,
) !?core.JSValue {
    const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const object = objectFromValue(target_value) orelse return core.JSValue.boolean(true);
    if (try objectIsExtensibleForIntegrity(ctx, output, global, object)) return core.JSValue.boolean(false);
    const own_keys = try objectRestOwnKeys(ctx, output, global, object);
    defer core.Object.freeKeys(ctx.runtime, own_keys);
    for (own_keys) |key| {
        const desc = try objectRestOwnPropertyDescriptor(ctx, output, global, object, key) orelse continue;
        defer desc.destroy(ctx.runtime);
        if (desc.configurable == true) return core.JSValue.boolean(false);
        if (level == .frozen and desc.kind == .data and desc.writable == true) return core.JSValue.boolean(false);
    }
    return core.JSValue.boolean(true);
}

pub fn objectIsExtensibleForIntegrity(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    object: *core.Object,
) !bool {
    if (object.proxyTarget() == null) return object.isExtensible();
    const target_value = object.proxyTarget() orelse return object.isExtensible();
    const target = property_ops.expectObject(target_value) catch return error.TypeError;
    const handler_value = object.proxyHandler() orelse return error.TypeError;
    const trap_key = try ctx.runtime.internAtom("isExtensible");
    defer ctx.runtime.atoms.free(trap_key);
    const trap = try getValueProperty(ctx, output, global, handler_value, trap_key, null, null);
    defer trap.free(ctx.runtime);
    if (trap.isUndefined() or trap.isNull()) return target.isExtensible();
    if (!isCallableValue(trap)) return error.TypeError;
    const result = try callValueOrBytecode(ctx, output, global, handler_value, trap, &.{target_value}, null, null);
    defer result.free(ctx.runtime);
    const extensible = valueTruthy(result);
    if (extensible != target.isExtensible()) return error.TypeError;
    return extensible;
}

pub fn appendObjectGroupByValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    out_value: core.JSValue,
    out: *core.Object,
    key: core.Atom,
    value: core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !void {
    var group_value = getValueProperty(ctx, output, global, out_value, key, caller_function, caller_frame) catch core.JSValue.undefinedValue();
    defer group_value.free(ctx.runtime);
    if (group_value.isUndefined()) {
        group_value.free(ctx.runtime);
        const group = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
        group_value = group.value();
        try createDataPropertyOrThrow(ctx, output, global, out_value, out, key, group_value, caller_function, caller_frame);
    }
    const group = objectFromValue(group_value) orelse return error.TypeError;
    try createDataPropertyOrThrow(ctx, output, global, group_value, group, core.atom.atomFromUInt32(group.arrayLength()), value, caller_function, caller_frame);
}

test "Object.groupBy new group define failure releases group once" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);
    const out = try core.Object.create(rt, core.class.ids.object, null);
    defer out.value().free(rt);
    out.preventExtensions();

    const key = try rt.internAtom("group");
    defer rt.atoms.free(key);

    try std.testing.expectError(
        error.TypeError,
        appendObjectGroupByValue(ctx, null, global, out.value(), out, key, core.JSValue.int32(1), null, null),
    );
    // Shapes are GC objects now: global and out share one live empty root shape.
    try std.testing.expectEqual(@as(usize, 3), rt.gc.liveCount());
}

pub fn qjsObjectPreventExtensionsCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    const target_value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    const object = objectFromValue(target_value) orelse return target_value.dup();
    if (object.proxyTarget() != null) {
        if (!try proxyAwarePreventExtensions(ctx, output, global, object, caller_function, caller_frame)) return error.TypeError;
        return target_value.dup();
    }
    object.preventExtensions();
    return target_value.dup();
}

pub fn qjsGetOwnPropertyDescriptorCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (args.len < 1) return null;
    if (args[0].isNull() or args[0].isUndefined()) return error.TypeError;
    const object_value = if (objectFromValue(args[0])) |_| args[0].dup() else try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    defer object_value.free(ctx.runtime);
    const object = objectFromValue(object_value) orelse return error.TypeError;
    const key_value = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    const atom_id = try toPropertyKeyAtom(ctx, output, global, key_value, caller_function, caller_frame);
    defer ctx.runtime.atoms.free(atom_id);
    var desc = try proxyAwareOwnPropertyDescriptor(ctx, output, global, object, atom_id, caller_function, caller_frame) orelse return core.JSValue.undefinedValue();
    try call.materializeMappedArgumentsDescriptorValueForVm(ctx.runtime, object, atom_id, &desc);
    defer desc.destroy(ctx.runtime);
    const desc_value = try descriptorObjectFromDescriptor(ctx.runtime, global, desc);
    return desc_value;
}

pub fn qjsObjectGetPrototypeOfCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (args.len < 1) return null;
    if (args[0].isNull() or args[0].isUndefined()) return @as(?core.JSValue, try throwTypeErrorMessage(ctx, global, "not an object"));
    const object_value = if (objectFromValue(args[0])) |_| args[0].dup() else try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    defer object_value.free(ctx.runtime);
    const object = objectFromValue(object_value) orelse return error.TypeError;
    if (try qjsObjectPrototypeMethodFunctionPrototype(ctx, global, object)) |prototype| return prototype.value().dup();
    return try qjsObjectGetPrototypeOfValue(ctx, output, global, object, caller_function, caller_frame);
}

pub fn qjsObjectPrototypeMethodFunctionPrototype(
    ctx: *core.JSContext,
    global: *core.Object,
    object: *core.Object,
) !?*core.Object {
    if (object.class_id != core.class.ids.c_function) return null;
    if (!isObjectPrototypeNativeRecord(object, @intFromEnum(PrototypeMethod.is_prototype_of))) return null;
    return functionPrototypeFromGlobal(ctx.runtime, global);
}

pub fn isObjectPrototypeNativeRecord(object: *core.Object, id: u32) bool {
    const native_ref = core.function.decodeNativeBuiltinId(object.nativeFunctionIdSlot().*) orelse return false;
    return native_ref.domain == .object and native_ref.id == id;
}

pub fn qjsGetOwnPropertyDescriptorsCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (args.len < 1) return null;
    if (args[0].isNull() or args[0].isUndefined()) return error.TypeError;
    const object_value = if (objectFromValue(args[0])) |_| args[0].dup() else try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    defer object_value.free(ctx.runtime);
    const object = objectFromValue(object_value) orelse return error.TypeError;
    const own_keys = try objectRestOwnKeys(ctx, output, global, object);
    defer core.Object.freeKeys(ctx.runtime, own_keys);

    const out = try core.Object.create(ctx.runtime, core.class.ids.object, objectPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
    for (own_keys) |key| {
        var desc = (try objectRestOwnPropertyDescriptor(ctx, output, global, object, key)) orelse continue;
        try call.materializeMappedArgumentsDescriptorValueForVm(ctx.runtime, object, key, &desc);
        defer desc.destroy(ctx.runtime);
        const desc_value = try descriptorObjectFromDescriptor(ctx.runtime, global, desc);
        defer desc_value.free(ctx.runtime);
        try createDataPropertyOrThrow(ctx, output, global, out.value(), out, key, desc_value, caller_function, caller_frame);
    }
    return out.value();
}

pub const OwnPropertyKeyFilter = enum {
    string,
    symbol,
};

pub fn qjsObjectOwnPropertyKeysCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    filter: OwnPropertyKeyFilter,
    caller_function: ?*const builtin_dispatch.Bytecode,
    caller_frame: ?*builtin_dispatch.Frame,
) !?core.JSValue {
    if (args.len < 1) return error.TypeError;
    if (args[0].isNull() or args[0].isUndefined()) return error.TypeError;
    const object_value = if (objectFromValue(args[0])) |_| args[0].dup() else try primitiveObjectForAccess(ctx.runtime, global, args[0]);
    defer object_value.free(ctx.runtime);
    const object = objectFromValue(object_value) orelse return error.TypeError;
    const own_keys = try objectRestOwnKeys(ctx, output, global, object);
    defer core.Object.freeKeys(ctx.runtime, own_keys);

    const out = try core.Object.createArray(ctx.runtime, arrayPrototypeFromGlobal(ctx.runtime, global));
    errdefer core.Object.destroyFromHeader(ctx.runtime, &out.header);
    for (own_keys) |key| {
        const is_symbol = ctx.runtime.atoms.isPublicSymbol(key);
        switch (filter) {
            .string => {
                if (is_symbol) continue;
                const name_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, key);
                defer name_value.free(ctx.runtime);
                try createDataPropertyOrThrow(ctx, output, global, out.value(), out, core.atom.atomFromUInt32(out.arrayLength()), name_value, caller_function, caller_frame);
            },
            .symbol => {
                if (!is_symbol) continue;
                const symbol_value = try ctx.runtime.symbolValue(key);
                defer symbol_value.free(ctx.runtime);
                try createDataPropertyOrThrow(ctx, output, global, out.value(), out, core.atom.atomFromUInt32(out.arrayLength()), symbol_value, caller_function, caller_frame);
            },
        }
    }
    return out.value();
}
