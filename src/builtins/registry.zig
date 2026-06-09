const core = @import("../core/root.zig");
const array_builtin = @import("array.zig");
const buffer_builtin = @import("buffer.zig");
const collection_builtin = @import("collection.zig");
const date_builtin = @import("date.zig");
const error_builtin = @import("error.zig");
const function_builtin = @import("function.zig");
const iterator_builtin = @import("iterator.zig");
const object_builtin = @import("object.zig");
const regexp_builtin = @import("regexp.zig");
const string_builtin = @import("string.zig");
const atomics_builtin = @import("atomics.zig");
const reflect_builtin = @import("reflect_proxy.zig");
const std = @import("std");

pub const Flags = struct {
    writable: bool,
    enumerable: bool,
    configurable: bool,
};

pub const Method = struct {
    name: []const u8,
    length: i32,
};

const ConstructorKind = enum {
    ordinary,
    object,
    function,
    array,
    string,
    number,
    boolean,
    symbol,
    bigint,
    date,
    regexp,
    aggregate_error,
    suppressed_error,
    error_,
    eval_error,
    range_error,
    reference_error,
    syntax_error,
    type_error,
    uri_error,
    dom_exception,
    disposable_stack,
    async_disposable_stack,
    promise,
    map,
    set,
    weak_map,
    weak_set,
    weak_ref,
    finalization_registry,
    array_buffer,
    shared_array_buffer,
    typed_array,
    int8_array,
    uint8_array,
    uint8_clamped_array,
    int16_array,
    uint16_array,
    int32_array,
    uint32_array,
    float16_array,
    float32_array,
    float64_array,
    bigint64_array,
    biguint64_array,
    data_view,
    proxy,
    iterator,
};

const ConstructorSpec = struct {
    name: []const u8,
    kind: ConstructorKind = .ordinary,
    length: i32,
    static_methods: []const Method = &.{},
    prototype_methods: []const Method = &.{},
};

pub const global_flags = Flags{ .writable = true, .enumerable = false, .configurable = true };
pub const method_flags = Flags{ .writable = true, .enumerable = false, .configurable = true };
pub const prototype_flags = Flags{ .writable = false, .enumerable = false, .configurable = false };
// QuickJS CLI exposes navigator.userAgent as "quickjs-ng/<JS_GetVersion()>".
// Keep this tied to the QuickJS reference version used by the local fixtures.
pub const navigator_user_agent = "quickjs-ng/0.14.0";

const shared_lazy_parse_int_slot: u8 = 1;
const shared_lazy_parse_float_slot: u8 = 2;
const shared_lazy_array_values_slot: u8 = 3;
const shared_lazy_typed_array_values_slot: u8 = 4;
const shared_lazy_map_entries_slot: u8 = 5;
const shared_lazy_set_values_slot: u8 = 6;
const shared_lazy_disposable_stack_dispose_slot: u8 = 7;
const shared_lazy_async_disposable_stack_dispose_slot: u8 = 8;
const shared_lazy_array_to_string_slot: u8 = 9;
const shared_lazy_date_to_utc_string_slot: u8 = 10;
const shared_lazy_string_trim_start_slot: u8 = 11;
const shared_lazy_string_trim_end_slot: u8 = 12;

comptime {
    std.debug.assert(shared_lazy_string_trim_end_slot <= core.runtime.shared_lazy_native_function_slots);
}

fn temporaryStringAtom(rt: *core.JSRuntime, name: []const u8) !core.Atom {
    return core.atom.predefinedId(name, .string) orelse try rt.internAtom(name);
}

fn freeTemporaryStringAtom(rt: *core.JSRuntime, atom_id: core.Atom) void {
    if (core.atom.isConst(atom_id) or core.atom.isTaggedInt(atom_id)) return;
    rt.atoms.free(atom_id);
}

fn createBuiltinAsciiStringValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    if (bytes.len == 0) {
        const cached = try rt.emptyString();
        return cached.value().dup();
    }
    const string_value = try core.string.String.createAscii(rt, bytes);
    return string_value.value();
}

fn constructorNameStringValueOrCreate(rt: *core.JSRuntime, ctor: *core.Object, fallback: []const u8) !core.JSValue {
    return ctor.getOwnDataPropertyValue(core.atom.ids.name) orelse
        try createBuiltinAsciiStringValue(rt, fallback);
}

pub fn defineData(
    rt: *core.JSRuntime,
    target: *core.Object,
    name: []const u8,
    value: core.JSValue,
    flags: Flags,
) !void {
    const key = try temporaryStringAtom(rt, name);
    defer freeTemporaryStringAtom(rt, key);
    try target.defineOwnProperty(rt, key, core.Descriptor.data(value, flags.writable, flags.enumerable, flags.configurable));
}

/// Fast-path variant of `defineData` for the standard-globals install
/// path. Caller must guarantee `target` is a freshly-built ordinary
/// object (no exotic methods, not an array / regexp / mapped-arguments)
/// and that `name` is not already present on `target`. Skips the
/// O(n) duplicate scan inside `defineOwnProperty`. See
/// `Object.defineOwnPropertyAssumingNew`.
pub fn defineDataAssumingNew(
    rt: *core.JSRuntime,
    target: *core.Object,
    name: []const u8,
    value: core.JSValue,
    flags: Flags,
) !void {
    const key = try temporaryStringAtom(rt, name);
    defer freeTemporaryStringAtom(rt, key);
    try target.defineOwnPropertyAssumingNew(rt, key, core.Descriptor.data(value, flags.writable, flags.enumerable, flags.configurable));
}

pub fn defineDataAtom(
    rt: *core.JSRuntime,
    target: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    flags: Flags,
) !void {
    try target.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, flags.writable, flags.enumerable, flags.configurable));
}

pub fn defineDataAtomAssumingNew(
    rt: *core.JSRuntime,
    target: *core.Object,
    atom_id: core.Atom,
    value: core.JSValue,
    flags: Flags,
) !void {
    try target.defineOwnPropertyAssumingNew(rt, atom_id, core.Descriptor.data(value, flags.writable, flags.enumerable, flags.configurable));
}

fn defineStringConstantAtomAssumingNew(
    rt: *core.JSRuntime,
    target: *core.Object,
    atom_id: core.Atom,
    bytes: []const u8,
    flags: Flags,
) !void {
    const property_flags = core.property.Flags.data(flags.writable, flags.enumerable, flags.configurable);
    try target.defineStringConstantAutoInitProperty(rt, atom_id, bytes, property_flags);
}

pub fn defineAccessorAtom(
    rt: *core.JSRuntime,
    target: *core.Object,
    atom_id: core.Atom,
    getter: core.JSValue,
    setter: core.JSValue,
    flags: Flags,
) !void {
    _ = flags.writable;
    try target.defineOwnProperty(rt, atom_id, core.Descriptor.accessor(getter, setter, flags.enumerable, flags.configurable));
}

fn defineLazyNativeGetterAtom(
    rt: *core.JSRuntime,
    target: *core.Object,
    atom_id: core.Atom,
    getter_name: []const u8,
    getter_native_builtin_id: i32,
    flags: Flags,
) !void {
    try defineLazyNativeGetterAtomWithRealm(rt, target, atom_id, getter_name, getter_native_builtin_id, flags, null);
}

fn defineLazyNativeGetterAtomWithRealm(
    rt: *core.JSRuntime,
    target: *core.Object,
    atom_id: core.Atom,
    getter_name: []const u8,
    getter_native_builtin_id: i32,
    flags: Flags,
    realm_global: ?*core.Object,
) !void {
    const property_flags = core.property.Flags.accessorFlags(flags.enumerable, flags.configurable);
    try target.defineNativeAccessorAutoInitPropertyWithRealmAndNative(
        rt,
        atom_id,
        getter_name,
        0,
        property_flags,
        realm_global,
        getter_native_builtin_id,
    );
}

fn defineLazyNativeAccessorPairAtom(
    rt: *core.JSRuntime,
    target: *core.Object,
    atom_id: core.Atom,
    getter_name: []const u8,
    getter_native_builtin_id: i32,
    setter_length: i32,
    setter_native_builtin_id: i32,
    flags: Flags,
    realm_global: ?*core.Object,
) !void {
    const property_flags = core.property.Flags.accessorFlags(flags.enumerable, flags.configurable);
    try target.defineNativeAccessorAutoInitPairPropertyWithRealmAndNative(
        rt,
        atom_id,
        getter_name,
        0,
        setter_length,
        property_flags,
        realm_global,
        getter_native_builtin_id,
        setter_native_builtin_id,
    );
}

pub fn defineNativeMethod(rt: *core.JSRuntime, target: *core.Object, method: Method) !void {
    const value = try function_builtin.nativeFunction(rt, method.name, method.length);
    defer value.free(rt);
    try defineData(rt, target, method.name, value, method_flags);
}

pub fn defineLazyNativeMethod(rt: *core.JSRuntime, target: *core.Object, method: Method) !void {
    const key = try temporaryStringAtom(rt, method.name);
    defer freeTemporaryStringAtom(rt, key);
    const flags = core.property.Flags.data(method_flags.writable, method_flags.enumerable, method_flags.configurable);
    try target.defineAutoInitProperty(rt, key, method.name, method.length, flags);
}

pub fn defineNativeMethods(rt: *core.JSRuntime, target: *core.Object, methods: []const Method) !void {
    for (methods) |method| try defineNativeMethod(rt, target, method);
}

/// Fast-path variant of `defineNativeMethods` for builtin install
/// paths. Caller must guarantee `target` is a freshly built ordinary
/// object and that no method name in `methods` already exists on it
/// (the standard `Method[]` tables in this file always satisfy this:
/// each entry name is unique within its slice). See
/// `Object.defineOwnPropertyAssumingNew` for the precondition list.
///
/// Lazy variant: installs `Object.defineAutoInitProperty` placeholders
/// instead of eagerly building each `nativeFunction`. The actual
/// function object is materialized on the first `getProperty` for
/// that key (mirrors QuickJS's `JS_PROP_AUTOINIT` mechanism on
/// `JSCFunctionListEntry`). This is the bulk of the
/// `installStandardGlobals` speedup: ~700 lazy placeholders cost
/// roughly two property-table inserts each (atom dup + shape
/// transition) vs the ~100us each that eager `nativeFunction` was
/// paying for the Object.create + 3 property defines + string alloc.
pub fn defineNativeMethodsAssumingNew(rt: *core.JSRuntime, target: *core.Object, methods: []const Method) !void {
    // registry.Flags has the local subset (no `.accessor`); translate
    // to the on-disk property.Flags packed-struct representation that
    // `defineAutoInitProperty` writes into the property table.
    const flags = core.property.Flags.data(method_flags.writable, method_flags.enumerable, method_flags.configurable);
    if (methods.len != 0) try target.reserveOwnPropertyCapacityAssumingPlain(rt, target.properties.len + methods.len);
    for (methods) |method| {
        const key = try temporaryStringAtom(rt, method.name);
        defer freeTemporaryStringAtom(rt, key);
        try target.defineAutoInitProperty(rt, key, method.name, method.length, flags);
    }
}

pub fn defineGlobalFunction(rt: *core.JSRuntime, global: *core.Object, name: []const u8, length: i32) !void {
    const value = try function_builtin.nativeFunction(rt, name, length);
    defer value.free(rt);
    try expectObject(value).setFunctionRealmGlobalPtr(rt, global);
    try defineData(rt, global, name, value, global_flags);
}

pub fn defineGlobalLazyFunction(rt: *core.JSRuntime, global: *core.Object, name: []const u8, length: i32) !void {
    const key = try temporaryStringAtom(rt, name);
    defer freeTemporaryStringAtom(rt, key);
    const flags = core.property.Flags.data(global_flags.writable, global_flags.enumerable, global_flags.configurable);
    try global.defineAutoInitPropertyWithRealm(rt, key, name, length, flags, global);
}

pub fn defineGlobalLazyNativeFunction(
    rt: *core.JSRuntime,
    global: *core.Object,
    name: []const u8,
    length: i32,
    domain: core.function.NativeBuiltinDomain,
    id: u32,
) !void {
    const key = try temporaryStringAtom(rt, name);
    defer freeTemporaryStringAtom(rt, key);
    const flags = core.property.Flags.data(global_flags.writable, global_flags.enumerable, global_flags.configurable);
    try global.defineAutoInitPropertyWithRealmAndNative(rt, key, name, length, flags, global, core.function.nativeBuiltinId(domain, id));
}

pub fn defineGlobalSharedLazyNativeFunction(
    rt: *core.JSRuntime,
    global: *core.Object,
    name: []const u8,
    length: i32,
    domain: core.function.NativeBuiltinDomain,
    id: u32,
    shared_cache_slot: u8,
) !void {
    const key = try temporaryStringAtom(rt, name);
    defer freeTemporaryStringAtom(rt, key);
    const flags = core.property.Flags.data(global_flags.writable, global_flags.enumerable, global_flags.configurable);
    try global.defineAutoInitPropertyWithRealmNativeAndCache(rt, key, name, length, flags, global, core.function.nativeBuiltinId(domain, id), shared_cache_slot);
}

fn defineSharedLazyNativeMethod(
    rt: *core.JSRuntime,
    target: *core.Object,
    global: *core.Object,
    atom_id: core.Atom,
    name: []const u8,
    length: i32,
    native_builtin_id: i32,
    shared_cache_slot: u8,
) !void {
    const flags = core.property.Flags.data(method_flags.writable, method_flags.enumerable, method_flags.configurable);
    if (target.is_array) {
        try target.defineAutoInitNonIndexPropertyWithRealmNativeAndCache(rt, atom_id, name, length, flags, global, native_builtin_id, shared_cache_slot);
        return;
    }
    try target.defineAutoInitPropertyWithRealmNativeAndCache(rt, atom_id, name, length, flags, global, native_builtin_id, shared_cache_slot);
}

fn replaceSharedLazyNativeMethod(
    rt: *core.JSRuntime,
    target: *core.Object,
    global: *core.Object,
    atom_id: core.Atom,
    name: []const u8,
    length: i32,
    native_builtin_id: i32,
    shared_cache_slot: u8,
) !void {
    const flags = core.property.Flags.data(method_flags.writable, method_flags.enumerable, method_flags.configurable);
    try target.replaceAutoInitPropertyWithRealmNativeAndCache(rt, atom_id, name, length, flags, global, native_builtin_id, shared_cache_slot);
}

pub fn defineNamespace(rt: *core.JSRuntime, global: *core.Object, name: []const u8, methods: []const Method) !*core.Object {
    const namespace = try createNamespaceObject(rt, global, methods, 0);
    errdefer namespace.value().free(rt);
    // `name` (Math/JSON/Reflect/Atomics) is added to the global once
    // per call from `installStandardGlobals` and the names do not
    // overlap with the constructor-spec or global-function entries
    // installed elsewhere in that same install pass.
    try defineDataAssumingNew(rt, global, name, namespace.value(), global_flags);
    namespace.value().free(rt);
    return namespace;
}

fn createNamespaceObject(rt: *core.JSRuntime, global: *core.Object, methods: []const Method, extra_property_count: usize) !*core.Object {
    const namespace = try core.Object.createWithOwnPropertyCapacity(
        rt,
        core.class.ids.object,
        objectPrototypeFromGlobal(rt, global),
        methods.len + extra_property_count,
    );
    errdefer namespace.value().free(rt);
    try namespace.setFunctionRealmGlobalPtr(rt, global);
    // Namespace is freshly created and method-table entries are unique
    // within `methods`; safe to skip the duplicate-property scan.
    try defineNativeMethodsAssumingNew(rt, namespace, methods);
    return namespace;
}

fn defineLazyNamespace(rt: *core.JSRuntime, global: *core.Object, name: []const u8, kind: core.property.AutoInitKind) !void {
    if (core.atom.predefinedId(name, .string)) |key| {
        const flags = core.property.Flags.data(global_flags.writable, global_flags.enumerable, global_flags.configurable);
        try global.defineBuiltinNamespaceAutoInitProperty(rt, key, name, flags, global, kind);
        return;
    }
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const flags = core.property.Flags.data(global_flags.writable, global_flags.enumerable, global_flags.configurable);
    try global.defineBuiltinNamespaceAutoInitProperty(rt, key, name, flags, global, kind);
}

pub fn materializeBuiltinNamespaceAutoInit(rt: *core.JSRuntime, global: *core.Object, kind: core.property.AutoInitKind) !core.JSValue {
    const namespace = switch (kind) {
        .math_namespace => try createNamespaceObject(rt, global, &math_methods, math_namespace_extra_property_count),
        .json_namespace => try createJsonNamespaceObject(rt, global),
        .reflect_namespace => try createNamespaceObject(rt, global, &reflect_methods, namespace_to_string_tag_property_count),
        .atomics_namespace => try createNamespaceObject(rt, global, &atomics_methods, namespace_to_string_tag_property_count),
        else => return error.TypeError,
    };
    errdefer namespace.value().free(rt);
    switch (kind) {
        .math_namespace => {
            try bindMathNativeRecords(rt, namespace);
            try installMathConstants(rt, namespace);
            try installNamespaceToStringTag(rt, namespace, "Math");
        },
        .json_namespace => {
            try installNamespaceToStringTag(rt, namespace, "JSON");
        },
        .reflect_namespace => {
            try bindReflectNativeRecords(rt, namespace);
            try installNamespaceToStringTag(rt, namespace, "Reflect");
        },
        .atomics_namespace => {
            try installNamespaceToStringTag(rt, namespace, "Atomics");
            try bindAtomicsNativeRecords(rt, namespace);
        },
        else => unreachable,
    }
    return namespace.value();
}

fn createJsonNamespaceObject(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    const namespace = try core.Object.createWithOwnPropertyCapacity(
        rt,
        core.class.ids.object,
        objectPrototypeFromGlobal(rt, global),
        json_methods.len + namespace_to_string_tag_property_count,
    );
    errdefer namespace.value().free(rt);
    try namespace.setFunctionRealmGlobalPtr(rt, global);
    const flags = core.property.Flags.data(method_flags.writable, method_flags.enumerable, method_flags.configurable);
    for (json_methods) |method| {
        const id = @import("json.zig").methodId(method.name) orelse continue;
        const key = try temporaryStringAtom(rt, method.name);
        defer freeTemporaryStringAtom(rt, key);
        try namespace.defineAutoInitPropertyWithRealmAndNative(rt, key, method.name, method.length, flags, global, core.function.nativeBuiltinId(.json, id));
    }
    return namespace;
}

fn objectPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    const object_atom = core.atom.predefinedId("Object", .string).?;
    if (global.getOwnDataObjectBorrowed(object_atom)) |object_ctor| {
        if (object_ctor.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    }
    const object_ctor_value = global.getProperty(core.atom.predefinedId("Object", .string).?);
    defer object_ctor_value.free(rt);
    if (!object_ctor_value.isObject()) return null;
    const object_ctor = expectObject(object_ctor_value);
    if (object_ctor.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    const prototype_value = object_ctor.getProperty(core.atom.ids.prototype);
    defer prototype_value.free(rt);
    if (!prototype_value.isObject()) return null;
    return expectObject(prototype_value);
}

const namespace_to_string_tag_property_count: usize = 1;
const math_constant_property_count: usize = 8;
const math_namespace_extra_property_count: usize = math_constant_property_count + namespace_to_string_tag_property_count;
const number_constant_property_count: usize = 8;
const global_lazy_function_property_count: usize = 15;

pub fn standardGlobalOwnPropertyCapacity() usize {
    return constructor_specs.len +
        4 + // Math, JSON, Reflect, Atomics
        2 + // performance, navigator
        global_lazy_function_property_count;
}

fn constructorOwnPropertyCapacity(spec: ConstructorSpec) usize {
    const prototype_count: usize = if (spec.kind == .proxy) 0 else 1;
    return 2 + prototype_count + spec.static_methods.len + constructorExtraPropertyCount(spec.kind);
}

fn prototypeOwnPropertyCapacity(spec: ConstructorSpec) usize {
    if (spec.kind == .proxy) return 0;
    const function_prototype_base: usize = if (spec.kind == .function) 2 else 0;
    return function_prototype_base +
        spec.prototype_methods.len +
        1 + // constructor, as data property or Iterator accessor
        prototypeExtraPropertyCount(spec.kind);
}

fn constructorExtraPropertyCount(kind: ConstructorKind) usize {
    return switch (kind) {
        .symbol => 15,
        .array => 1,
        .number => number_constant_property_count,
        .regexp => 21,
        .error_ => 1,
        .dom_exception => dom_exception_constants.len,
        .promise,
        .map,
        .set,
        .array_buffer,
        .shared_array_buffer,
        .typed_array,
        => 1,
        .uint8_array => 3,
        .int8_array,
        .uint8_clamped_array,
        .int16_array,
        .uint16_array,
        .int32_array,
        .uint32_array,
        .float16_array,
        .float32_array,
        .float64_array,
        .bigint64_array,
        .biguint64_array,
        => 1,
        else => 0,
    };
}

fn prototypeExtraPropertyCount(kind: ConstructorKind) usize {
    return switch (kind) {
        .object => 1,
        .function => 1,
        .array => 2,
        .string => 4,
        .symbol => 3,
        .bigint,
        .promise,
        .weak_ref,
        .finalization_registry,
        => 1,
        .date => 2,
        .regexp => 15,
        .aggregate_error,
        .suppressed_error,
        .eval_error,
        .range_error,
        .reference_error,
        .syntax_error,
        .type_error,
        .uri_error,
        => 2,
        .error_ => 3,
        .dom_exception => 1 + dom_exception_constants.len,
        .disposable_stack,
        .async_disposable_stack,
        .map,
        .set,
        => 3,
        .weak_map,
        .weak_set,
        => 1,
        .array_buffer => 6,
        .shared_array_buffer => 4,
        .typed_array => 8,
        .uint8_array => 5,
        .int8_array,
        .uint8_clamped_array,
        .int16_array,
        .uint16_array,
        .int32_array,
        .uint32_array,
        .float16_array,
        .float32_array,
        .float64_array,
        .bigint64_array,
        .biguint64_array,
        => 1,
        .data_view => 4,
        .iterator => 3,
        else => 0,
    };
}

pub fn defineConstructor(
    rt: *core.JSRuntime,
    global: *core.Object,
    spec: ConstructorSpec,
) !core.JSValue {
    const name = spec.name;
    const constructor_value = try core.function.nativeFunctionWithLazyNameAndCapacity(rt, name, spec.length, constructorOwnPropertyCapacity(spec));
    errdefer constructor_value.free(rt);
    const constructor = expectObject(constructor_value);
    try constructor.setFunctionRealmGlobalPtr(rt, global);

    if (spec.kind != .proxy) {
        const prototype_capacity = prototypeOwnPropertyCapacity(spec);
        const prototype_value = if (spec.kind == .function)
            try core.function.nativeFunctionWithLazyNameAndCapacity(rt, "", 0, prototype_capacity)
        else if (spec.kind == .array)
            (try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.array, null, prototype_capacity)).value()
        else if (spec.kind == .string)
            (try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.string, null, prototype_capacity)).value()
        else if (spec.kind == .number)
            (try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.number, null, prototype_capacity)).value()
        else if (spec.kind == .boolean)
            (try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.boolean, null, prototype_capacity)).value()
        else
            (try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.object, null, prototype_capacity)).value();
        errdefer prototype_value.free(rt);
        const prototype = expectObject(prototype_value);
        try prototype.setFunctionRealmGlobalPtr(rt, global);
        // Prototype is freshly created above; use the fast path that
        // skips the duplicate-property scan in `defineOwnProperty`.
        // Method-table names are unique within their slice and prototype
        // starts empty, so the precondition holds.
        try defineNativeMethodsAssumingNew(rt, prototype, spec.prototype_methods);
        if (spec.kind == .number) {
            try prototype.setOptionalValueSlot(rt, prototype.objectDataSlot(), core.JSValue.int32(0));
        }
        if (spec.kind == .string) {
            const empty = try createBuiltinAsciiStringValue(rt, "");
            defer empty.free(rt);
            try prototype.setOptionalValueSlot(rt, prototype.objectDataSlot(), empty.dup());
        }
        if (spec.kind == .boolean) {
            try prototype.setOptionalValueSlot(rt, prototype.objectDataSlot(), core.JSValue.boolean(false));
        }
        if (isErrorConstructorKind(spec.kind)) {
            try defineStringConstantAtomAssumingNew(rt, prototype, core.atom.ids.name, name, Flags{ .writable = true, .enumerable = false, .configurable = true });
            try defineStringConstantAtomAssumingNew(rt, prototype, core.atom.predefinedId("message", .string).?, "", Flags{ .writable = true, .enumerable = false, .configurable = true });
        }
        // Constructor is freshly created above; "prototype" is unique
        // among its existing visible properties (length / name).
        try defineDataAssumingNew(rt, constructor, "prototype", prototype_value, prototype_flags);
        prototype_value.free(rt);
    }

    // The global accumulates one entry per spec inside the
    // `installStandardGlobals` loop; spec names are mutually distinct,
    // so the new-property precondition holds for the install path.
    // Other callers of `defineConstructor` are absent today (this entry
    // point is internal to the registry); add a duplicate-tolerant
    // wrapper here if that ever changes.
    try defineDataAssumingNew(rt, global, name, constructor_value, global_flags);
    return constructor_value;
}

fn isErrorConstructorSpecName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Error") or isNativeErrorSubclassName(name);
}

fn isErrorConstructorKind(kind: ConstructorKind) bool {
    return switch (kind) {
        .aggregate_error,
        .suppressed_error,
        .error_,
        .eval_error,
        .range_error,
        .reference_error,
        .syntax_error,
        .type_error,
        .uri_error,
        => true,
        else => false,
    };
}

fn expectObject(value: core.JSValue) *core.Object {
    const header = value.refHeader().?;
    return @fieldParentPtr("header", header);
}

fn installedConstructor(constructors: []const ?*core.Object, kind: ConstructorKind) ?*core.Object {
    for (constructor_specs, 0..) |spec, index| {
        if (spec.kind == kind) return constructors[index];
    }
    return null;
}

fn constructorPrototypeObject(rt: *core.JSRuntime, ctor: *core.Object) ?*core.Object {
    if (ctor.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    const proto_value = ctor.getProperty(core.atom.ids.prototype);
    defer proto_value.free(rt);
    if (!proto_value.isObject()) return null;
    return expectObject(proto_value);
}

fn materializeBuiltinNamespace(rt: *core.JSRuntime, global: *core.Object, kind: core.property.AutoInitKind) anyerror!?core.JSValue {
    return try materializeBuiltinNamespaceAutoInit(rt, global, kind);
}

pub fn installStandardGlobals(rt: *core.JSRuntime, global: *core.Object) !void {
    rt.materialize_builtin_namespace_cb = materializeBuiltinNamespace;
    try global.reserveOwnPropertyCapacityAssumingPlain(rt, standardGlobalOwnPropertyCapacity());
    var installed_constructors: [constructor_specs.len]?*core.Object = @splat(null);
    for (constructor_specs, 0..) |spec, index| {
        {
            const constructor_value = try defineConstructor(rt, global, spec);
            defer constructor_value.free(rt);
            const constructor = expectObject(constructor_value);
            installed_constructors[index] = constructor;
            // Constructor object is freshly returned from
            // `defineConstructor`; it currently holds only visible
            // `length`, `name`, and `prototype` properties (the latter
            // skipped for `Proxy`). Static-method names per spec do not
            // collide with those, so fast-path is safe.
            try defineNativeMethodsAssumingNew(rt, constructor, spec.static_methods);
            switch (spec.kind) {
                .object => {
                    const object_proto = constructorPrototypeObject(rt, constructor) orelse return error.InvalidBuiltinRegistry;
                    const cached = try global.cachedRealmValueSlot(rt, .object_prototype);
                    try global.setOptionalValueSlot(rt, cached, object_proto.value().dup());
                    try bindObjectStaticNativeRecords(rt, constructor);
                    try installObjectPrototypeExtras(rt, constructor);
                    try bindObjectPrototypeNativeRecords(rt, constructor);
                },
                .symbol => try installSymbolExtras(rt, constructor),
                .array => {
                    constructor.arrayBuiltinMarkerSlot().* = .constructor;
                    const array_proto = constructorPrototypeObject(rt, constructor) orelse return error.InvalidBuiltinRegistry;
                    const cached = try global.cachedRealmValueSlot(rt, .array_prototype);
                    try global.setOptionalValueSlot(rt, cached, array_proto.value().dup());
                    try bindArrayNativeRecords(rt, constructor);
                    try installArrayPrototypeSymbols(rt, global, constructor);
                    try tagArrayPrototypeMethods(rt, constructor);
                    try bindArrayPrototypeNativeRecords(rt, constructor);
                },
                .string => {
                    constructor.nativeFunctionIdSlot().* = core.function.nativeBuiltinId(.string, @intFromEnum(@import("string.zig").ConstructorMethod.call));
                    try installStringPrototypeAliases(rt, global, constructor);
                    try bindStringNativeRecords(rt, constructor);
                },
                .number => {
                    try bindNumberNativeRecords(rt, constructor);
                },
                .regexp => {
                    constructor.nativeFunctionIdSlot().* = core.function.nativeBuiltinId(.regexp, @intFromEnum(regexp_builtin.ConstructorMethod.construct));
                    const cached = try global.cachedRealmValueSlot(rt, .regexp_constructor);
                    try global.setOptionalValueSlot(rt, cached, constructor.value().dup());
                    try installRegExpExtras(rt, constructor);
                },
                .promise => try installPromiseExtras(rt, global, constructor),
                .aggregate_error,
                .suppressed_error,
                .error_,
                .eval_error,
                .range_error,
                .reference_error,
                .syntax_error,
                .type_error,
                .uri_error,
                => {
                    if (spec.kind == .error_) {
                        try installErrorPrototypeExtras(rt, constructor);
                        try defineDataAssumingNew(rt, constructor, "stackTraceLimit", core.JSValue.int32(10), Flags{ .writable = true, .enumerable = false, .configurable = true });
                    }
                },
                .date => {
                    try bindDateNativeRecords(rt, constructor);
                    try installDatePrototypeAliases(rt, global, constructor);
                },
                .function => {
                    try installFunctionPrototypeExtras(rt, constructor);
                    // Stash Function.prototype on the realm global so the lazy
                    // `auto_init` materializer can wire each on-demand
                    // native function's `[[Prototype]]` without re-walking
                    // the global object. The realm cache retains the
                    // intrinsic so global property mutation cannot dangle it.
                    try global.setCachedFunctionProto(rt, constructorPrototypeObject(rt, constructor));
                },
                .array_buffer => {
                    constructor.nativeFunctionIdSlot().* = core.function.nativeBuiltinId(.buffer, @intFromEnum(buffer_builtin.ConstructorMethod.array_buffer));
                    try installArrayBufferExtras(rt, constructor);
                    try bindArrayBufferStaticNativeRecords(rt, constructor);
                    try bindBufferPrototypeNativeRecords(rt, constructor, 1);
                },
                .shared_array_buffer => {
                    constructor.nativeFunctionIdSlot().* = core.function.nativeBuiltinId(.buffer, @intFromEnum(buffer_builtin.ConstructorMethod.shared_array_buffer));
                    try installSharedArrayBufferExtras(rt, constructor);
                    try bindBufferPrototypeNativeRecords(rt, constructor, 2);
                },
                .data_view => try installDataViewExtras(rt, constructor),
                .iterator => try installIteratorExtras(rt, global, constructor),
                .dom_exception => try installDOMExceptionExtras(rt, constructor),
                .disposable_stack => try installDisposableStackExtras(rt, global, constructor),
                .async_disposable_stack => try installAsyncDisposableStackExtras(rt, global, constructor),
                else => {},
            }
            switch (spec.kind) {
                .bigint, .promise, .weak_ref, .finalization_registry => try installPrototypeToStringTag(rt, spec.name, constructor),
                else => {},
            }
            if (primitivePrototypeTagForKind(spec.kind)) |tag| try bindPrimitivePrototypeNativeRecordsWithTag(rt, constructor, tag);
            if (typedArrayElementSpecForKind(spec.kind)) |element| {
                try installTypedArrayElementSize(rt, constructor, element.size, element.kind);
                try installTypedArrayArrayBufferPrototype(rt, global, constructor);
            }
            if (spec.kind == .uint8_array) try installUint8ArrayCodecExtras(rt, constructor);
            if (collectionNameForKind(spec.kind)) |collection_name| try installCollectionExtras(rt, global, collection_name, constructor);
        }
    }
    try wireStandardConstructorGraph(rt, global, &installed_constructors);
    const object_ctor = installedConstructor(&installed_constructors, .object) orelse return error.InvalidBuiltinRegistry;
    const object_proto = constructorPrototypeObject(rt, object_ctor) orelse return error.InvalidBuiltinRegistry;
    try global.setPrototype(rt, object_proto);

    try defineLazyNamespace(rt, global, "Math", .math_namespace);
    try defineLazyNamespace(rt, global, "JSON", .json_namespace);
    try defineLazyNamespace(rt, global, "Reflect", .reflect_namespace);
    try defineLazyNamespace(rt, global, "Atomics", .atomics_namespace);
    try installPerformance(rt, global);
    try installNavigator(rt, global);

    const number_mod = @import("number.zig");
    try defineGlobalSharedLazyNativeFunction(rt, global, "parseInt", 2, .number, @intFromEnum(number_mod.StaticMethod.parse_int), shared_lazy_parse_int_slot);
    try defineGlobalSharedLazyNativeFunction(rt, global, "parseFloat", 1, .number, @intFromEnum(number_mod.StaticMethod.parse_float), shared_lazy_parse_float_slot);
    const number_constructor = installedConstructor(&installed_constructors, .number) orelse return error.InvalidBuiltinRegistry;
    try installNumberParseAliases(rt, global, number_constructor);
    try installNumberConstants(rt, number_constructor);
    try defineGlobalLazyNativeFunction(rt, global, "isNaN", 1, .number, @intFromEnum(number_mod.StaticMethod.is_nan));
    try defineGlobalLazyNativeFunction(rt, global, "isFinite", 1, .number, @intFromEnum(number_mod.StaticMethod.is_finite));
    try defineGlobalLazyFunction(rt, global, "eval", 1);
    const uri_mod = @import("uri.zig");
    try defineGlobalLazyNativeFunction(rt, global, "encodeURI", 1, .uri, uri_mod.methodId("encodeURI").?);
    try defineGlobalLazyNativeFunction(rt, global, "decodeURI", 1, .uri, uri_mod.methodId("decodeURI").?);
    try defineGlobalLazyNativeFunction(rt, global, "encodeURIComponent", 1, .uri, uri_mod.methodId("encodeURIComponent").?);
    try defineGlobalLazyNativeFunction(rt, global, "decodeURIComponent", 1, .uri, uri_mod.methodId("decodeURIComponent").?);
    try defineGlobalLazyFunction(rt, global, "escape", 1);
    try defineGlobalLazyFunction(rt, global, "unescape", 1);
    try defineGlobalLazyFunction(rt, global, "btoa", 1);
    try defineGlobalLazyFunction(rt, global, "atob", 1);
    try defineGlobalLazyFunction(rt, global, "queueMicrotask", 1);
    try defineGlobalLazyFunction(rt, global, "gc", 0);
    try wireAllNativeFunctionPrototypes(rt, global, &installed_constructors);
}

fn bindNumberGlobalNativeRecords(rt: *core.JSRuntime, global: *core.Object) !void {
    const number_mod = @import("number.zig");
    const names = [_][]const u8{ "parseInt", "parseFloat", "isNaN", "isFinite" };
    for (names) |name| {
        const id = number_mod.staticMethodId(name) orelse continue;
        try bindNativeRecordByName(rt, global, name, .number, id);
    }
}

fn installNumberParseAliases(rt: *core.JSRuntime, global: *core.Object, number: *core.Object) !void {
    const number_mod = @import("number.zig");
    const aliases = [_]struct {
        name: []const u8,
        length: i32,
        id: u32,
        cache_slot: u8,
    }{
        .{ .name = "parseInt", .length = 2, .id = @intFromEnum(number_mod.StaticMethod.parse_int), .cache_slot = shared_lazy_parse_int_slot },
        .{ .name = "parseFloat", .length = 1, .id = @intFromEnum(number_mod.StaticMethod.parse_float), .cache_slot = shared_lazy_parse_float_slot },
    };
    const flags = core.property.Flags.data(method_flags.writable, method_flags.enumerable, method_flags.configurable);
    for (aliases) |alias| {
        const key = try temporaryStringAtom(rt, alias.name);
        defer freeTemporaryStringAtom(rt, key);
        try number.replaceAutoInitPropertyWithRealmNativeAndCache(rt, key, alias.name, alias.length, flags, global, core.function.nativeBuiltinId(.number, alias.id), alias.cache_slot);
    }
}

fn installNumberConstants(rt: *core.JSRuntime, number: *core.Object) !void {
    const flags = Flags{ .writable = false, .enumerable = false, .configurable = false };
    const prop_flags = core.property.Flags.data(flags.writable, flags.enumerable, flags.configurable);
    const constants = [_][]const u8{
        "NaN",
        "POSITIVE_INFINITY",
        "NEGATIVE_INFINITY",
        "MAX_VALUE",
        "MIN_VALUE",
        "MAX_SAFE_INTEGER",
        "MIN_SAFE_INTEGER",
        "EPSILON",
    };
    try number.reserveOwnPropertyCapacityAssumingPlain(rt, number.properties.len + constants.len);
    for (constants) |name| {
        const key = try temporaryStringAtom(rt, name);
        defer freeTemporaryStringAtom(rt, key);
        try number.defineNumberConstantAutoInitProperty(rt, key, name, prop_flags);
    }
}

fn wireStandardConstructorGraph(rt: *core.JSRuntime, global: *core.Object, constructors: []const ?*core.Object) !void {
    const object_ctor = installedConstructor(constructors, .object) orelse return error.InvalidBuiltinRegistry;
    const object_proto = constructorPrototypeObject(rt, object_ctor) orelse return error.InvalidBuiltinRegistry;

    const function_ctor = installedConstructor(constructors, .function) orelse return error.InvalidBuiltinRegistry;
    const function_proto = constructorPrototypeObject(rt, function_ctor) orelse return error.InvalidBuiltinRegistry;
    try function_proto.setPrototype(rt, object_proto);

    const error_ctor = installedConstructor(constructors, .error_) orelse return error.InvalidBuiltinRegistry;
    const error_proto = constructorPrototypeObject(rt, error_ctor) orelse return error.InvalidBuiltinRegistry;

    for (constructor_specs, 0..) |spec, index| {
        const ctor = constructors[index] orelse continue;
        if (isNativeErrorSubclassKind(spec.kind)) {
            try ctor.setPrototype(rt, error_ctor);
        } else {
            try ctor.setPrototype(rt, function_proto);
        }

        const proto = constructorPrototypeObject(rt, ctor) orelse continue;
        if (!proto.hasOwnProperty(core.atom.ids.constructor)) {
            if (proto.is_array) {
                try defineData(rt, proto, "constructor", ctor.value(), Flags{ .writable = true, .enumerable = false, .configurable = true });
            } else {
                try defineDataAssumingNew(rt, proto, "constructor", ctor.value(), Flags{ .writable = true, .enumerable = false, .configurable = true });
            }
        }
        if (spec.kind == .object) {
            try proto.setPrototype(rt, null);
            proto.markImmutablePrototype();
        } else if (isNativeErrorSubclassKind(spec.kind) or spec.kind == .dom_exception) {
            try proto.setPrototype(rt, error_proto);
        } else {
            try proto.setPrototype(rt, object_proto);
        }
    }
    try installObjectConstructorPrimitivePrototypes(rt, constructors, object_ctor);
    try wireTypedArrayConstructorGraph(rt, constructors);
    try installTypedArrayIntrinsicExtras(rt, global, constructors);
}

fn installTypedArrayIntrinsicExtras(rt: *core.JSRuntime, global: *core.Object, constructors: []const ?*core.Object) !void {
    const typed_array_ctor = installedConstructor(constructors, .typed_array) orelse return;
    try installTypedArraySpecies(rt, typed_array_ctor);
    try tagTypedArrayStaticMethods(rt, typed_array_ctor);
    const proto = constructorPrototypeObject(rt, typed_array_ctor) orelse return;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.properties.len + 8);
    const to_string_atom = core.atom.predefinedId("toString", .string).?;
    const to_string_native_id = core.function.nativeBuiltinId(.array, @intFromEnum(array_builtin.PrototypeMethod.to_string));
    try replaceSharedLazyNativeMethod(rt, proto, global, to_string_atom, "toString", 0, to_string_native_id, shared_lazy_array_to_string_slot);
    try defineLazyNativeMethod(rt, proto, .{ .name = "set", .length = 1 });
    try defineLazyNativeMethod(rt, proto, .{ .name = "subarray", .length = 2 });
    const values_atom = core.atom.predefinedId("values", .string).?;
    const iterator_atom = core.atom.predefinedId("Symbol.iterator", .symbol).?;
    try replaceSharedLazyNativeMethod(rt, proto, global, values_atom, "values", 0, 0, shared_lazy_typed_array_values_slot);
    try defineSharedLazyNativeMethod(rt, proto, global, iterator_atom, "values", 0, 0, shared_lazy_typed_array_values_slot);
    if (!tagAutoInitArrayIteratorKindByAtom(proto, values_atom, 2)) return error.InvalidBuiltinRegistry;
    if (!tagAutoInitArrayIteratorKindByAtom(proto, iterator_atom, 2)) return error.InvalidBuiltinRegistry;
    if (!tagAutoInitTypedArrayBuiltinByAtom(proto, values_atom, .prototype_method)) return error.InvalidBuiltinRegistry;
    if (!tagAutoInitTypedArrayBuiltinByAtom(proto, iterator_atom, .prototype_method)) return error.InvalidBuiltinRegistry;
    try tagArrayIteratorMethod(rt, proto, "keys", 1);
    try tagArrayIteratorMethod(rt, proto, "values", 2);
    try tagArrayIteratorMethod(rt, proto, "entries", 3);
    try installTypedArrayPrototypeAccessors(rt, proto);
    try tagTypedArrayPrototypeMethods(rt, proto);
}

fn tagTypedArrayStaticMethods(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const tags = [_]struct { name: []const u8, marker: core.property.TypedArrayBuiltinMarker }{
        .{ .name = "from", .marker = .static_from },
        .{ .name = "of", .marker = .static_of },
    };
    for (tags) |tag| {
        const key = try rt.internAtom(tag.name);
        defer rt.atoms.free(key);
        if (tagAutoInitTypedArrayBuiltinByAtom(ctor, key, tag.marker)) continue;
        const value = ctor.getProperty(key);
        defer value.free(rt);
        if (!value.isObject()) continue;
        if (!expectObject(value).addTypedArrayBuiltinMarker(tag.marker)) return error.InvalidBuiltinRegistry;
    }
}

fn wireTypedArrayConstructorGraph(rt: *core.JSRuntime, constructors: []const ?*core.Object) !void {
    const typed_array_ctor = installedConstructor(constructors, .typed_array) orelse return;
    const typed_array_proto = constructorPrototypeObject(rt, typed_array_ctor) orelse return;

    for (constructor_specs, 0..) |spec, index| {
        if (!isConcreteTypedArrayKind(spec.kind)) continue;
        const ctor = constructors[index] orelse continue;
        try ctor.setPrototype(rt, typed_array_ctor);

        const proto = constructorPrototypeObject(rt, ctor) orelse continue;
        try proto.setPrototype(rt, typed_array_proto);
    }
}

fn isConcreteTypedArrayName(name: []const u8) bool {
    return typedArrayElementSpec(name) != null;
}

fn isConcreteTypedArrayKind(kind: ConstructorKind) bool {
    return typedArrayElementSpecForKind(kind) != null;
}

fn installObjectConstructorPrimitivePrototypes(
    rt: *core.JSRuntime,
    constructors: []const ?*core.Object,
    object_ctor: *core.Object,
) !void {
    const entries = [_]struct {
        kind: ConstructorKind,
        slot: core.object.PrimitivePrototypeSlot,
    }{
        .{ .kind = .string, .slot = .string },
        .{ .kind = .number, .slot = .number },
        .{ .kind = .boolean, .slot = .boolean },
        .{ .kind = .symbol, .slot = .symbol },
        .{ .kind = .bigint, .slot = .bigint },
    };
    for (entries) |entry| {
        const ctor = installedConstructor(constructors, entry.kind) orelse continue;
        const proto = constructorPrototypeObject(rt, ctor) orelse continue;
        const slot = object_ctor.functionPrimitivePrototypeSlot(entry.slot);
        try object_ctor.setOptionalValueSlot(rt, slot, proto.value().dup());
    }
}

fn isNativeErrorSubclassName(name: []const u8) bool {
    return std.mem.eql(u8, name, "AggregateError") or
        std.mem.eql(u8, name, "SuppressedError") or
        std.mem.eql(u8, name, "EvalError") or
        std.mem.eql(u8, name, "RangeError") or
        std.mem.eql(u8, name, "ReferenceError") or
        std.mem.eql(u8, name, "SyntaxError") or
        std.mem.eql(u8, name, "TypeError") or
        std.mem.eql(u8, name, "URIError");
}

fn isNativeErrorSubclassKind(kind: ConstructorKind) bool {
    return switch (kind) {
        .aggregate_error,
        .suppressed_error,
        .eval_error,
        .range_error,
        .reference_error,
        .syntax_error,
        .type_error,
        .uri_error,
        => true,
        else => false,
    };
}

fn installMathConstants(rt: *core.JSRuntime, math: *core.Object) !void {
    const math_mod = @import("math.zig");
    const flags = Flags{ .writable = false, .enumerable = false, .configurable = false };
    try defineData(rt, math, "E", core.JSValue.float64(math_mod.E), flags);
    try defineData(rt, math, "LN10", core.JSValue.float64(math_mod.LN10), flags);
    try defineData(rt, math, "LN2", core.JSValue.float64(math_mod.LN2), flags);
    try defineData(rt, math, "LOG2E", core.JSValue.float64(math_mod.LOG2E), flags);
    try defineData(rt, math, "LOG10E", core.JSValue.float64(math_mod.LOG10E), flags);
    try defineData(rt, math, "PI", core.JSValue.float64(math_mod.PI), flags);
    try defineData(rt, math, "SQRT1_2", core.JSValue.float64(math_mod.SQRT1_2), flags);
    try defineData(rt, math, "SQRT2", core.JSValue.float64(math_mod.SQRT2), flags);
}

fn bindMathNativeRecords(rt: *core.JSRuntime, math: *core.Object) !void {
    const math_mod = @import("math.zig");
    for (math_methods) |method| {
        const id = math_mod.methodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, math, method.name, .math, id);
    }
}

fn bindAtomicsNativeRecords(rt: *core.JSRuntime, atomics: *core.Object) !void {
    for (atomics_methods) |method| {
        const id = atomics_builtin.methodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, atomics, method.name, .atomics, id);
    }
}

fn bindReflectNativeRecords(rt: *core.JSRuntime, reflect: *core.Object) !void {
    for (reflect_methods) |method| {
        const id = reflect_builtin.methodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, reflect, method.name, .reflect, id);
    }
}

fn bindObjectStaticNativeRecords(rt: *core.JSRuntime, ctor: *core.Object) !void {
    for (object_static) |method| {
        const id = object_builtin.staticMethodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, ctor, method.name, .object, id);
    }
}

fn bindObjectPrototypeNativeRecords(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    for (object_prototype) |method| {
        const id = object_builtin.prototypeMethodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, proto, method.name, .object, id);
    }
}

fn bindUriNativeRecords(rt: *core.JSRuntime, global: *core.Object) !void {
    const uri_mod = @import("uri.zig");
    const names = [_][]const u8{ "encodeURI", "encodeURIComponent", "decodeURI", "decodeURIComponent" };
    for (names) |name| {
        const id = uri_mod.methodId(name) orelse continue;
        try bindNativeRecordByName(rt, global, name, .uri, id);
    }
}

fn bindNumberNativeRecords(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const number_mod = @import("number.zig");
    for (number_static) |method| {
        if (std.mem.eql(u8, method.name, "parseInt") or std.mem.eql(u8, method.name, "parseFloat")) continue;
        const id = number_mod.staticMethodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, ctor, method.name, .number, id);
    }

    const proto = constructorPrototypeObject(rt, ctor) orelse return;
    for (number_prototype) |method| {
        const id = number_mod.prototypeMethodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, proto, method.name, .number, id);
    }
}

fn bindStringNativeRecords(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const string_mod = @import("string.zig");
    for (string_static) |method| {
        const id = string_mod.staticMethodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, ctor, method.name, .string, id);
    }

    const proto = constructorPrototypeObject(rt, ctor) orelse return;
    for (string_prototype) |method| {
        const id = string_mod.prototypeMethodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, proto, method.name, .string, id);
    }
}

fn bindDateNativeRecords(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const date_mod = @import("date.zig");
    ctor.nativeFunctionIdSlot().* = core.function.nativeBuiltinId(.date, @intFromEnum(date_mod.ConstructorMethod.construct));
    for (date_static) |method| {
        const id = date_mod.staticMethodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, ctor, method.name, .date, id);
    }

    const proto = constructorPrototypeObject(rt, ctor) orelse return;
    for (date_prototype) |method| {
        const id = date_mod.prototypeMethodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, proto, method.name, .date, id);
    }
}

fn bindCollectionStaticNativeRecords(rt: *core.JSRuntime, ctor: *core.Object, name: []const u8) !void {
    if (!std.mem.eql(u8, name, "Map")) return;
    for (map_static) |method| {
        const id = collection_builtin.staticMethodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, ctor, method.name, .collection, id);
    }
}

fn bindArrayBufferStaticNativeRecords(rt: *core.JSRuntime, ctor: *core.Object) !void {
    for (array_buffer_static) |method| {
        const id = buffer_builtin.staticMethodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, ctor, method.name, .buffer, id);
    }
}

fn bindArrayNativeRecords(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const array_mod = @import("array.zig");
    for (array_static) |method| {
        const id = array_mod.staticMethodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, ctor, method.name, .array, id);
    }
}

fn bindArrayPrototypeNativeRecords(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return;
    const array_mod = @import("array.zig");
    for (array_prototype) |method| {
        const id = array_mod.prototypeMethodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, proto, method.name, .array, id);
    }
}

fn bindNativeRecordByName(
    rt: *core.JSRuntime,
    object: *core.Object,
    name: []const u8,
    domain: core.function.NativeBuiltinDomain,
    id: u32,
) !void {
    const key = try temporaryStringAtom(rt, name);
    defer freeTemporaryStringAtom(rt, key);
    const native_id = core.function.nativeBuiltinId(domain, id);
    if (bindAutoInitNativeRecordByAtom(object, key, native_id)) return;
    const value = object.getProperty(key);
    defer value.free(rt);
    if (!value.isObject()) return;
    const function_object = expectObject(value);
    function_object.nativeFunctionIdSlot().* = native_id;
}

fn bindAutoInitNativeRecordByAtom(object: *core.Object, atom_id: core.Atom, native_id: i32) bool {
    if (object.exotic != null) return false;
    for (object.properties) |*entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        switch (entry.slot) {
            .auto_init => |*info| {
                info.native_builtin_id = native_id;
                return true;
            },
            else => return false,
        }
    }
    return false;
}

fn tagAutoInitArrayBuiltinByAtom(object: *core.Object, atom_id: core.Atom, marker: core.property.ArrayBuiltinMarker) bool {
    if (object.exotic != null) return false;
    for (object.properties) |*entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        switch (entry.slot) {
            .auto_init => |*info| return setAutoInitArrayBuiltinMarker(info, marker),
            .data => |value| {
                if (!value.isObject()) return false;
                return expectObject(value).addArrayBuiltinMarker(marker);
            },
            else => return false,
        }
    }
    return false;
}

fn setAutoInitArrayBuiltinMarker(info: *core.property.AutoInit, marker: core.property.ArrayBuiltinMarker) bool {
    if (info.array_builtin_marker != .none and info.array_builtin_marker != marker) return false;
    info.array_builtin_marker = marker;
    return true;
}

fn tagAutoInitTypedArrayBuiltinByAtom(object: *core.Object, atom_id: core.Atom, marker: core.property.TypedArrayBuiltinMarker) bool {
    if (object.exotic != null) return false;
    for (object.properties) |*entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        switch (entry.slot) {
            .auto_init => |*info| return setAutoInitTypedArrayBuiltinMarker(info, marker),
            .data => |value| {
                if (!value.isObject()) return false;
                return expectObject(value).addTypedArrayBuiltinMarker(marker);
            },
            else => return false,
        }
    }
    return false;
}

fn setAutoInitTypedArrayBuiltinMarker(info: *core.property.AutoInit, marker: core.property.TypedArrayBuiltinMarker) bool {
    if (info.typed_array_builtin_marker != .none and info.typed_array_builtin_marker != marker) return false;
    info.typed_array_builtin_marker = marker;
    return true;
}

fn tagAutoInitArrayIteratorKindByAtom(object: *core.Object, atom_id: core.Atom, kind: u8) bool {
    if (object.exotic != null) return false;
    for (object.properties) |*entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        switch (entry.slot) {
            .auto_init => |*info| return setAutoInitArrayIteratorKind(info, kind),
            .data => |value| {
                if (!value.isObject()) return false;
                return expectObject(value).addArrayIteratorKind(kind);
            },
            else => return false,
        }
    }
    return false;
}

fn setAutoInitArrayIteratorKind(info: *core.property.AutoInit, kind: u8) bool {
    if (info.array_iterator_kind != 0 and info.array_iterator_kind != kind) return false;
    info.array_iterator_kind = kind;
    return true;
}

fn tagAutoInitIteratorIdentityByAtom(object: *core.Object, atom_id: core.Atom) bool {
    if (object.exotic != null) return false;
    for (object.properties) |*entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        switch (entry.slot) {
            .auto_init => |*info| {
                info.iterator_identity = true;
                return true;
            },
            .data => |value| {
                if (!value.isObject()) return false;
                return expectObject(value).addIteratorIdentityFunction();
            },
            else => return false,
        }
    }
    return false;
}

fn tagAutoInitCollectionOwnerByAtom(object: *core.Object, atom_id: core.Atom, owner_class: core.ClassId) bool {
    if (object.exotic != null) return false;
    for (object.properties) |*entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        switch (entry.slot) {
            .auto_init => |*info| return setAutoInitCollectionOwner(info, owner_class),
            .data => |value| {
                if (!value.isObject()) return false;
                return expectObject(value).addCollectionMethodOwnerClass(owner_class);
            },
            else => return false,
        }
    }
    return false;
}

fn setAutoInitCollectionOwner(info: *core.property.AutoInit, owner_class: core.ClassId) bool {
    if (info.collection_method_owner_class != core.class.invalid_class_id and info.collection_method_owner_class != owner_class) return false;
    info.collection_method_owner_class = owner_class;
    return true;
}

fn tagAutoInitDisposableStackMethodByAtom(object: *core.Object, atom_id: core.Atom, method_id: u8) bool {
    if (object.exotic != null) return false;
    for (object.properties) |*entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        switch (entry.slot) {
            .auto_init => |*info| return setAutoInitDisposableStackMethod(info, method_id),
            .data => |value| {
                if (!value.isObject()) return false;
                return expectObject(value).addDisposableStackMethod(method_id);
            },
            else => return false,
        }
    }
    return false;
}

fn setAutoInitDisposableStackMethod(info: *core.property.AutoInit, method_id: u8) bool {
    if (info.disposable_stack_method != 0 and info.disposable_stack_method != method_id) return false;
    info.disposable_stack_method = method_id;
    return true;
}

fn tagAutoInitAsyncDisposableStackMethodByAtom(object: *core.Object, atom_id: core.Atom, method_id: u8) bool {
    if (object.exotic != null) return false;
    for (object.properties) |*entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        switch (entry.slot) {
            .auto_init => |*info| return setAutoInitAsyncDisposableStackMethod(info, method_id),
            .data => |value| {
                if (!value.isObject()) return false;
                return expectObject(value).addAsyncDisposableStackMethod(method_id);
            },
            else => return false,
        }
    }
    return false;
}

fn setAutoInitAsyncDisposableStackMethod(info: *core.property.AutoInit, method_id: u8) bool {
    if (info.async_disposable_stack_method != 0 and info.async_disposable_stack_method != method_id) return false;
    info.async_disposable_stack_method = method_id;
    return true;
}

const TypedArrayElementSpec = struct {
    size: i32,
    kind: u8,
};

fn typedArrayElementSpec(name: []const u8) ?TypedArrayElementSpec {
    if (std.mem.eql(u8, name, "Int8Array")) return .{ .size = 1, .kind = 1 };
    if (std.mem.eql(u8, name, "Uint8Array")) return .{ .size = 1, .kind = 2 };
    if (std.mem.eql(u8, name, "Uint8ClampedArray")) return .{ .size = 1, .kind = 3 };
    if (std.mem.eql(u8, name, "Int16Array")) return .{ .size = 2, .kind = 4 };
    if (std.mem.eql(u8, name, "Uint16Array")) return .{ .size = 2, .kind = 5 };
    if (std.mem.eql(u8, name, "Int32Array")) return .{ .size = 4, .kind = 6 };
    if (std.mem.eql(u8, name, "Uint32Array")) return .{ .size = 4, .kind = 7 };
    if (std.mem.eql(u8, name, "Float16Array")) return .{ .size = 2, .kind = 8 };
    if (std.mem.eql(u8, name, "Float32Array")) return .{ .size = 4, .kind = 9 };
    if (std.mem.eql(u8, name, "Float64Array")) return .{ .size = 8, .kind = 10 };
    if (std.mem.eql(u8, name, "BigInt64Array")) return .{ .size = 8, .kind = 11 };
    if (std.mem.eql(u8, name, "BigUint64Array")) return .{ .size = 8, .kind = 12 };
    return null;
}

fn typedArrayElementSpecForKind(kind: ConstructorKind) ?TypedArrayElementSpec {
    return switch (kind) {
        .int8_array => .{ .size = 1, .kind = 1 },
        .uint8_array => .{ .size = 1, .kind = 2 },
        .uint8_clamped_array => .{ .size = 1, .kind = 3 },
        .int16_array => .{ .size = 2, .kind = 4 },
        .uint16_array => .{ .size = 2, .kind = 5 },
        .int32_array => .{ .size = 4, .kind = 6 },
        .uint32_array => .{ .size = 4, .kind = 7 },
        .float16_array => .{ .size = 2, .kind = 8 },
        .float32_array => .{ .size = 4, .kind = 9 },
        .float64_array => .{ .size = 8, .kind = 10 },
        .bigint64_array => .{ .size = 8, .kind = 11 },
        .biguint64_array => .{ .size = 8, .kind = 12 },
        else => null,
    };
}

fn installTypedArrayElementSize(rt: *core.JSRuntime, ctor: *core.Object, size: i32, kind: u8) !void {
    ctor.typedArrayElementSizeSlot().* = @intCast(size);
    ctor.typedArrayKindSlot().* = kind;
    const flags = Flags{ .writable = false, .enumerable = false, .configurable = false };
    const prop_flags = core.property.Flags.data(flags.writable, flags.enumerable, flags.configurable);
    const bytes_key = core.atom.predefinedId("BYTES_PER_ELEMENT", .string).?;
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.properties.len + 1);
    try ctor.defineInt32ConstantAutoInitProperty(rt, bytes_key, "BYTES_PER_ELEMENT", size, prop_flags);
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.properties.len + 1);
    try proto.defineInt32ConstantAutoInitProperty(rt, bytes_key, "BYTES_PER_ELEMENT", size, prop_flags);
}

fn installUint8ArrayCodecExtras(rt: *core.JSRuntime, ctor: *core.Object) !void {
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.properties.len + 2);
    try defineLazyNativeMethod(rt, ctor, .{ .name = "fromBase64", .length = 1 });
    try defineLazyNativeMethod(rt, ctor, .{ .name = "fromHex", .length = 1 });

    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.properties.len + 4);
    try defineLazyNativeMethod(rt, proto, .{ .name = "setFromBase64", .length = 1 });
    try defineLazyNativeMethod(rt, proto, .{ .name = "setFromHex", .length = 1 });
    try defineLazyNativeMethod(rt, proto, .{ .name = "toBase64", .length = 0 });
    try defineLazyNativeMethod(rt, proto, .{ .name = "toHex", .length = 0 });
}

fn tagTypedArrayPrototypeMethods(rt: *core.JSRuntime, proto: *core.Object) !void {
    const names = [_][]const u8{
        "toString",
        "toLocaleString",
        "map",
        "filter",
        "reduce",
        "reduceRight",
        "forEach",
        "some",
        "every",
        "find",
        "findIndex",
        "findLast",
        "findLastIndex",
        "includes",
        "indexOf",
        "lastIndexOf",
        "at",
        "copyWithin",
        "fill",
        "slice",
        "join",
        "reverse",
        "sort",
        "toReversed",
        "toSorted",
        "with",
        "keys",
        "values",
        "entries",
        "set",
        "subarray",
    };
    for (names) |name| {
        const key = try temporaryStringAtom(rt, name);
        defer freeTemporaryStringAtom(rt, key);
        const typed_array_marker_deferred = tagAutoInitTypedArrayBuiltinByAtom(proto, key, .prototype_method);
        const array_marker_deferred = if (std.mem.eql(u8, name, "toString"))
            tagAutoInitArrayBuiltinByAtom(proto, key, .to_string)
        else if (std.mem.eql(u8, name, "toLocaleString"))
            tagAutoInitArrayBuiltinByAtom(proto, key, .to_locale_string)
        else
            true;
        if (typed_array_marker_deferred and array_marker_deferred) continue;
        const value = proto.getProperty(key);
        defer value.free(rt);
        if (value.isObject()) {
            const object = expectObject(value);
            if (!typed_array_marker_deferred) {
                if (!object.addTypedArrayBuiltinMarker(.prototype_method)) return error.InvalidBuiltinRegistry;
            }
            if (std.mem.eql(u8, name, "toString") and !array_marker_deferred) {
                if (!object.addArrayBuiltinMarker(.to_string)) return error.InvalidBuiltinRegistry;
            } else if (std.mem.eql(u8, name, "toLocaleString") and !array_marker_deferred) {
                if (!object.addArrayBuiltinMarker(.to_locale_string)) return error.InvalidBuiltinRegistry;
            }
        }
    }
}

fn installTypedArrayPrototypeAccessors(rt: *core.JSRuntime, proto: *core.Object) !void {
    const flags = Flags{ .writable = false, .enumerable = false, .configurable = true };
    const accessors = [_]struct {
        property_name: []const u8,
        getter_name: []const u8,
    }{
        .{ .property_name = "buffer", .getter_name = "get buffer" },
        .{ .property_name = "byteLength", .getter_name = "get byteLength" },
        .{ .property_name = "byteOffset", .getter_name = "get byteOffset" },
        .{ .property_name = "length", .getter_name = "get length" },
    };
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.properties.len + accessors.len + 1);
    for (accessors) |accessor| {
        const native_id = if (buffer_builtin.typedArrayAccessorMethodId(accessor.property_name)) |id|
            core.function.nativeBuiltinId(.buffer, id)
        else
            0;
        const key = core.atom.predefinedId(accessor.property_name, .string) orelse return error.InvalidBuiltinRegistry;
        try defineLazyNativeGetterAtom(rt, proto, key, accessor.getter_name, native_id, flags);
    }

    const tag_native_id = if (buffer_builtin.typedArrayAccessorMethodId("[Symbol.toStringTag]")) |id|
        core.function.nativeBuiltinId(.buffer, id)
    else
        0;
    try defineLazyNativeGetterAtom(rt, proto, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, "get [Symbol.toStringTag]", tag_native_id, flags);
}

const object_static = [_]Method{
    .{ .name = "assign", .length = 2 },
    .{ .name = "create", .length = 2 },
    .{ .name = "defineProperty", .length = 3 },
    .{ .name = "defineProperties", .length = 2 },
    .{ .name = "getOwnPropertyDescriptor", .length = 2 },
    .{ .name = "getOwnPropertyDescriptors", .length = 1 },
    .{ .name = "getOwnPropertyNames", .length = 1 },
    .{ .name = "getOwnPropertySymbols", .length = 1 },
    .{ .name = "getPrototypeOf", .length = 1 },
    .{ .name = "hasOwn", .length = 2 },
    .{ .name = "isExtensible", .length = 1 },
    .{ .name = "keys", .length = 1 },
    .{ .name = "preventExtensions", .length = 1 },
    .{ .name = "seal", .length = 1 },
    .{ .name = "isSealed", .length = 1 },
    .{ .name = "isFrozen", .length = 1 },
    .{ .name = "setPrototypeOf", .length = 2 },
    .{ .name = "values", .length = 1 },
    .{ .name = "entries", .length = 1 },
    .{ .name = "is", .length = 2 },
    .{ .name = "freeze", .length = 1 },
    .{ .name = "fromEntries", .length = 1 },
    .{ .name = "groupBy", .length = 2 },
};

const object_prototype = [_]Method{
    .{ .name = "toString", .length = 0 },
    .{ .name = "toLocaleString", .length = 0 },
    .{ .name = "valueOf", .length = 0 },
    .{ .name = "hasOwnProperty", .length = 1 },
    .{ .name = "isPrototypeOf", .length = 1 },
    .{ .name = "propertyIsEnumerable", .length = 1 },
    .{ .name = "__defineGetter__", .length = 2 },
    .{ .name = "__defineSetter__", .length = 2 },
    .{ .name = "__lookupGetter__", .length = 1 },
    .{ .name = "__lookupSetter__", .length = 1 },
};

const function_prototype = [_]Method{
    .{ .name = "call", .length = 1 },
    .{ .name = "apply", .length = 2 },
    .{ .name = "bind", .length = 1 },
    .{ .name = "toString", .length = 0 },
};

const array_static = [_]Method{
    .{ .name = "from", .length = 1 },
    .{ .name = "fromAsync", .length = 1 },
    .{ .name = "isArray", .length = 1 },
    .{ .name = "of", .length = 0 },
};

const array_prototype = [_]Method{
    .{ .name = "toString", .length = 0 },
    .{ .name = "toLocaleString", .length = 0 },
    .{ .name = "map", .length = 1 },
    .{ .name = "filter", .length = 1 },
    .{ .name = "reduce", .length = 1 },
    .{ .name = "reduceRight", .length = 1 },
    .{ .name = "forEach", .length = 1 },
    .{ .name = "push", .length = 1 },
    .{ .name = "pop", .length = 0 },
    .{ .name = "shift", .length = 0 },
    .{ .name = "unshift", .length = 1 },
    .{ .name = "some", .length = 1 },
    .{ .name = "every", .length = 1 },
    .{ .name = "find", .length = 1 },
    .{ .name = "findIndex", .length = 1 },
    .{ .name = "findLast", .length = 1 },
    .{ .name = "findLastIndex", .length = 1 },
    .{ .name = "includes", .length = 1 },
    .{ .name = "indexOf", .length = 1 },
    .{ .name = "lastIndexOf", .length = 1 },
    .{ .name = "at", .length = 1 },
    .{ .name = "copyWithin", .length = 2 },
    .{ .name = "fill", .length = 1 },
    .{ .name = "slice", .length = 2 },
    .{ .name = "splice", .length = 2 },
    .{ .name = "join", .length = 1 },
    .{ .name = "concat", .length = 1 },
    .{ .name = "reverse", .length = 0 },
    .{ .name = "sort", .length = 1 },
    .{ .name = "flat", .length = 0 },
    .{ .name = "flatMap", .length = 1 },
    .{ .name = "toReversed", .length = 0 },
    .{ .name = "toSorted", .length = 1 },
    .{ .name = "toSpliced", .length = 2 },
    .{ .name = "with", .length = 2 },
    .{ .name = "keys", .length = 0 },
    .{ .name = "values", .length = 0 },
    .{ .name = "entries", .length = 0 },
};

const string_static = [_]Method{
    .{ .name = "fromCharCode", .length = 1 },
    .{ .name = "fromCodePoint", .length = 1 },
    .{ .name = "raw", .length = 1 },
};

const string_prototype = [_]Method{
    .{ .name = "charAt", .length = 1 },
    .{ .name = "charCodeAt", .length = 1 },
    .{ .name = "codePointAt", .length = 1 },
    .{ .name = "concat", .length = 1 },
    .{ .name = "at", .length = 1 },
    .{ .name = "slice", .length = 2 },
    .{ .name = "substring", .length = 2 },
    .{ .name = "toUpperCase", .length = 0 },
    .{ .name = "toLowerCase", .length = 0 },
    .{ .name = "toLocaleUpperCase", .length = 0 },
    .{ .name = "toLocaleLowerCase", .length = 0 },
    .{ .name = "indexOf", .length = 1 },
    .{ .name = "lastIndexOf", .length = 1 },
    .{ .name = "includes", .length = 1 },
    .{ .name = "startsWith", .length = 1 },
    .{ .name = "endsWith", .length = 1 },
    .{ .name = "localeCompare", .length = 1 },
    .{ .name = "repeat", .length = 1 },
    .{ .name = "padStart", .length = 1 },
    .{ .name = "padEnd", .length = 1 },
    .{ .name = "normalize", .length = 0 },
    .{ .name = "isWellFormed", .length = 0 },
    .{ .name = "toWellFormed", .length = 0 },
    .{ .name = "trim", .length = 0 },
    .{ .name = "trimStart", .length = 0 },
    .{ .name = "trimEnd", .length = 0 },
    .{ .name = "toString", .length = 0 },
    .{ .name = "valueOf", .length = 0 },
    .{ .name = "anchor", .length = 1 },
    .{ .name = "big", .length = 0 },
    .{ .name = "blink", .length = 0 },
    .{ .name = "bold", .length = 0 },
    .{ .name = "fixed", .length = 0 },
    .{ .name = "fontcolor", .length = 1 },
    .{ .name = "fontsize", .length = 1 },
    .{ .name = "italics", .length = 0 },
    .{ .name = "link", .length = 1 },
    .{ .name = "small", .length = 0 },
    .{ .name = "strike", .length = 0 },
    .{ .name = "sub", .length = 0 },
    .{ .name = "substr", .length = 2 },
    .{ .name = "split", .length = 2 },
    .{ .name = "match", .length = 1 },
    .{ .name = "matchAll", .length = 1 },
    .{ .name = "search", .length = 1 },
    .{ .name = "replace", .length = 2 },
    .{ .name = "replaceAll", .length = 2 },
    .{ .name = "sup", .length = 0 },
};

const number_static = [_]Method{
    .{ .name = "parseInt", .length = 2 },
    .{ .name = "parseFloat", .length = 1 },
    .{ .name = "isNaN", .length = 1 },
    .{ .name = "isFinite", .length = 1 },
    .{ .name = "isInteger", .length = 1 },
    .{ .name = "isSafeInteger", .length = 1 },
};

const bigint_static = [_]Method{
    .{ .name = "asIntN", .length = 2 },
    .{ .name = "asUintN", .length = 2 },
};

const typed_array_static = [_]Method{
    .{ .name = "from", .length = 1 },
    .{ .name = "of", .length = 0 },
};

const no_methods = [_]Method{};

const proxy_static = [_]Method{
    .{ .name = "revocable", .length = 2 },
};

const number_prototype = [_]Method{
    .{ .name = "toString", .length = 1 },
    .{ .name = "toLocaleString", .length = 0 },
    .{ .name = "toFixed", .length = 1 },
    .{ .name = "toExponential", .length = 1 },
    .{ .name = "toPrecision", .length = 1 },
    .{ .name = "valueOf", .length = 0 },
};

const primitive_prototype = [_]Method{
    .{ .name = "toString", .length = 0 },
    .{ .name = "valueOf", .length = 0 },
};

const error_prototype = [_]Method{
    .{ .name = "toString", .length = 0 },
};

const symbol_static = [_]Method{
    .{ .name = "for", .length = 1 },
    .{ .name = "keyFor", .length = 1 },
};

const date_static = [_]Method{
    .{ .name = "UTC", .length = 7 },
    .{ .name = "parse", .length = 1 },
    .{ .name = "now", .length = 0 },
};

const date_prototype = [_]Method{
    .{ .name = "getTime", .length = 0 },
    .{ .name = "getTimezoneOffset", .length = 0 },
    .{ .name = "setTime", .length = 1 },
    .{ .name = "valueOf", .length = 0 },
    .{ .name = "getFullYear", .length = 0 },
    .{ .name = "getMonth", .length = 0 },
    .{ .name = "getDate", .length = 0 },
    .{ .name = "getDay", .length = 0 },
    .{ .name = "getHours", .length = 0 },
    .{ .name = "getMinutes", .length = 0 },
    .{ .name = "getSeconds", .length = 0 },
    .{ .name = "getMilliseconds", .length = 0 },
    .{ .name = "setMilliseconds", .length = 1 },
    .{ .name = "setUTCMilliseconds", .length = 1 },
    .{ .name = "setSeconds", .length = 2 },
    .{ .name = "setUTCSeconds", .length = 2 },
    .{ .name = "setMinutes", .length = 3 },
    .{ .name = "setUTCMinutes", .length = 3 },
    .{ .name = "setHours", .length = 4 },
    .{ .name = "setUTCHours", .length = 4 },
    .{ .name = "setDate", .length = 1 },
    .{ .name = "setUTCDate", .length = 1 },
    .{ .name = "setMonth", .length = 2 },
    .{ .name = "setUTCMonth", .length = 2 },
    .{ .name = "setFullYear", .length = 3 },
    .{ .name = "setUTCFullYear", .length = 3 },
    .{ .name = "toLocaleString", .length = 0 },
    .{ .name = "toISOString", .length = 0 },
    .{ .name = "toJSON", .length = 1 },
    .{ .name = "toString", .length = 0 },
    .{ .name = "toDateString", .length = 0 },
    .{ .name = "toTimeString", .length = 0 },
    .{ .name = "toLocaleDateString", .length = 0 },
    .{ .name = "toLocaleTimeString", .length = 0 },
    .{ .name = "toUTCString", .length = 0 },
    .{ .name = "getUTCFullYear", .length = 0 },
    .{ .name = "getUTCMonth", .length = 0 },
    .{ .name = "getUTCDate", .length = 0 },
    .{ .name = "getUTCHours", .length = 0 },
    .{ .name = "getUTCMinutes", .length = 0 },
    .{ .name = "getUTCSeconds", .length = 0 },
    .{ .name = "getUTCMilliseconds", .length = 0 },
    .{ .name = "getUTCDay", .length = 0 },
    .{ .name = "getYear", .length = 0 },
    .{ .name = "setYear", .length = 1 },
};

const regexp_prototype = [_]Method{
    .{ .name = "compile", .length = 2 },
    .{ .name = "exec", .length = 1 },
    .{ .name = "test", .length = 1 },
    .{ .name = "toString", .length = 0 },
};

const promise_static = [_]Method{
    .{ .name = "resolve", .length = 1 },
    .{ .name = "all", .length = 1 },
    .{ .name = "allKeyed", .length = 1 },
    .{ .name = "allSettled", .length = 1 },
    .{ .name = "allSettledKeyed", .length = 1 },
    .{ .name = "any", .length = 1 },
    .{ .name = "race", .length = 1 },
    .{ .name = "reject", .length = 1 },
    .{ .name = "try", .length = 1 },
    .{ .name = "withResolvers", .length = 0 },
};

const promise_prototype = [_]Method{
    .{ .name = "then", .length = 2 },
    .{ .name = "catch", .length = 1 },
    .{ .name = "finally", .length = 1 },
};

const error_static = [_]Method{
    .{ .name = "captureStackTrace", .length = 1 },
    .{ .name = "isError", .length = 1 },
};

const dom_exception_constants = [_]struct { name: []const u8, code: i32 }{
    .{ .name = "INDEX_SIZE_ERR", .code = 1 },
    .{ .name = "DOMSTRING_SIZE_ERR", .code = 2 },
    .{ .name = "HIERARCHY_REQUEST_ERR", .code = 3 },
    .{ .name = "WRONG_DOCUMENT_ERR", .code = 4 },
    .{ .name = "INVALID_CHARACTER_ERR", .code = 5 },
    .{ .name = "NO_DATA_ALLOWED_ERR", .code = 6 },
    .{ .name = "NO_MODIFICATION_ALLOWED_ERR", .code = 7 },
    .{ .name = "NOT_FOUND_ERR", .code = 8 },
    .{ .name = "NOT_SUPPORTED_ERR", .code = 9 },
    .{ .name = "INUSE_ATTRIBUTE_ERR", .code = 10 },
    .{ .name = "INVALID_STATE_ERR", .code = 11 },
    .{ .name = "SYNTAX_ERR", .code = 12 },
    .{ .name = "INVALID_MODIFICATION_ERR", .code = 13 },
    .{ .name = "NAMESPACE_ERR", .code = 14 },
    .{ .name = "INVALID_ACCESS_ERR", .code = 15 },
    .{ .name = "VALIDATION_ERR", .code = 16 },
    .{ .name = "TYPE_MISMATCH_ERR", .code = 17 },
    .{ .name = "SECURITY_ERR", .code = 18 },
    .{ .name = "NETWORK_ERR", .code = 19 },
    .{ .name = "ABORT_ERR", .code = 20 },
    .{ .name = "URL_MISMATCH_ERR", .code = 21 },
    .{ .name = "QUOTA_EXCEEDED_ERR", .code = 22 },
    .{ .name = "TIMEOUT_ERR", .code = 23 },
    .{ .name = "INVALID_NODE_TYPE_ERR", .code = 24 },
    .{ .name = "DATA_CLONE_ERR", .code = 25 },
};

const map_static = [_]Method{
    .{ .name = "groupBy", .length = 2 },
};

const map_prototype = [_]Method{
    .{ .name = "set", .length = 2 },
    .{ .name = "get", .length = 1 },
    .{ .name = "has", .length = 1 },
    .{ .name = "delete", .length = 1 },
    .{ .name = "clear", .length = 0 },
    .{ .name = "keys", .length = 0 },
    .{ .name = "values", .length = 0 },
    .{ .name = "entries", .length = 0 },
    .{ .name = "forEach", .length = 1 },
    .{ .name = "getOrInsert", .length = 2 },
    .{ .name = "getOrInsertComputed", .length = 2 },
};

const weak_map_prototype = [_]Method{
    .{ .name = "set", .length = 2 },
    .{ .name = "get", .length = 1 },
    .{ .name = "has", .length = 1 },
    .{ .name = "delete", .length = 1 },
    .{ .name = "getOrInsert", .length = 2 },
    .{ .name = "getOrInsertComputed", .length = 2 },
};

const set_prototype = [_]Method{
    .{ .name = "add", .length = 1 },
    .{ .name = "has", .length = 1 },
    .{ .name = "delete", .length = 1 },
    .{ .name = "clear", .length = 0 },
    .{ .name = "entries", .length = 0 },
    .{ .name = "forEach", .length = 1 },
    .{ .name = "keys", .length = 0 },
    .{ .name = "values", .length = 0 },
    .{ .name = "difference", .length = 1 },
    .{ .name = "intersection", .length = 1 },
    .{ .name = "isDisjointFrom", .length = 1 },
    .{ .name = "isSubsetOf", .length = 1 },
    .{ .name = "isSupersetOf", .length = 1 },
    .{ .name = "symmetricDifference", .length = 1 },
    .{ .name = "union", .length = 1 },
};

const weak_set_prototype = [_]Method{
    .{ .name = "add", .length = 1 },
    .{ .name = "has", .length = 1 },
    .{ .name = "delete", .length = 1 },
};

const weak_ref_prototype = [_]Method{
    .{ .name = "deref", .length = 0 },
};

const finalization_registry_prototype = [_]Method{
    .{ .name = "register", .length = 2 },
    .{ .name = "unregister", .length = 1 },
};

const disposable_stack_prototype = [_]Method{
    .{ .name = "use", .length = 1 },
    .{ .name = "adopt", .length = 2 },
    .{ .name = "defer", .length = 1 },
    .{ .name = "dispose", .length = 0 },
    .{ .name = "move", .length = 0 },
};

const async_disposable_stack_prototype = [_]Method{
    .{ .name = "use", .length = 1 },
    .{ .name = "adopt", .length = 2 },
    .{ .name = "defer", .length = 1 },
    .{ .name = "disposeAsync", .length = 0 },
    .{ .name = "move", .length = 0 },
};

const buffer_prototype = [_]Method{
    .{ .name = "slice", .length = 2 },
    .{ .name = "sliceToImmutable", .length = 2 },
    .{ .name = "resize", .length = 1 },
    .{ .name = "transfer", .length = 0 },
    .{ .name = "transferToFixedLength", .length = 0 },
    .{ .name = "transferToImmutable", .length = 0 },
};

const shared_buffer_prototype = [_]Method{
    .{ .name = "slice", .length = 2 },
    .{ .name = "grow", .length = 1 },
};

const array_buffer_static = [_]Method{
    .{ .name = "isView", .length = 1 },
};

const data_view_prototype = [_]Method{
    .{ .name = "getInt8", .length = 1 },
    .{ .name = "getUint8", .length = 1 },
    .{ .name = "getInt16", .length = 1 },
    .{ .name = "getUint16", .length = 1 },
    .{ .name = "getInt32", .length = 1 },
    .{ .name = "getUint32", .length = 1 },
    .{ .name = "getFloat16", .length = 1 },
    .{ .name = "getFloat32", .length = 1 },
    .{ .name = "getFloat64", .length = 1 },
    .{ .name = "getBigInt64", .length = 1 },
    .{ .name = "getBigUint64", .length = 1 },
    .{ .name = "setInt8", .length = 2 },
    .{ .name = "setUint8", .length = 2 },
    .{ .name = "setInt16", .length = 2 },
    .{ .name = "setUint16", .length = 2 },
    .{ .name = "setInt32", .length = 2 },
    .{ .name = "setUint32", .length = 2 },
    .{ .name = "setFloat16", .length = 2 },
    .{ .name = "setFloat32", .length = 2 },
    .{ .name = "setFloat64", .length = 2 },
    .{ .name = "setBigInt64", .length = 2 },
    .{ .name = "setBigUint64", .length = 2 },
};

const iterator_static = [_]Method{
    .{ .name = "concat", .length = 0 },
    .{ .name = "from", .length = 1 },
    .{ .name = "zip", .length = 1 },
    .{ .name = "zipKeyed", .length = 1 },
};

const iterator_prototype = [_]Method{
    .{ .name = "drop", .length = 1 },
    .{ .name = "every", .length = 1 },
    .{ .name = "filter", .length = 1 },
    .{ .name = "find", .length = 1 },
    .{ .name = "flatMap", .length = 1 },
    .{ .name = "forEach", .length = 1 },
    .{ .name = "map", .length = 1 },
    .{ .name = "reduce", .length = 1 },
    .{ .name = "some", .length = 1 },
    .{ .name = "take", .length = 1 },
    .{ .name = "toArray", .length = 0 },
};

const constructor_specs = [_]ConstructorSpec{
    .{ .name = "Object", .kind = .object, .length = 1, .static_methods = &object_static, .prototype_methods = &object_prototype },
    .{ .name = "Function", .kind = .function, .length = 1, .prototype_methods = &function_prototype },
    .{ .name = "Array", .kind = .array, .length = 1, .static_methods = &array_static, .prototype_methods = &array_prototype },
    .{ .name = "String", .kind = .string, .length = 1, .static_methods = &string_static, .prototype_methods = &string_prototype },
    .{ .name = "Number", .kind = .number, .length = 1, .static_methods = &number_static, .prototype_methods = &number_prototype },
    .{ .name = "Boolean", .kind = .boolean, .length = 1, .prototype_methods = &primitive_prototype },
    .{ .name = "Symbol", .kind = .symbol, .length = 0, .static_methods = &symbol_static, .prototype_methods = &primitive_prototype },
    .{ .name = "BigInt", .kind = .bigint, .length = 1, .static_methods = &bigint_static, .prototype_methods = &primitive_prototype },
    .{ .name = "Date", .kind = .date, .length = 7, .static_methods = &date_static, .prototype_methods = &date_prototype },
    .{ .name = "RegExp", .kind = .regexp, .length = 2, .prototype_methods = &regexp_prototype },
    .{ .name = "AggregateError", .kind = .aggregate_error, .length = 2, .prototype_methods = &no_methods },
    .{ .name = "SuppressedError", .kind = .suppressed_error, .length = 3, .prototype_methods = &no_methods },
    .{ .name = "Error", .kind = .error_, .length = 1, .static_methods = &error_static, .prototype_methods = &error_prototype },
    .{ .name = "EvalError", .kind = .eval_error, .length = 1, .prototype_methods = &no_methods },
    .{ .name = "RangeError", .kind = .range_error, .length = 1, .prototype_methods = &no_methods },
    .{ .name = "ReferenceError", .kind = .reference_error, .length = 1, .prototype_methods = &no_methods },
    .{ .name = "SyntaxError", .kind = .syntax_error, .length = 1, .prototype_methods = &no_methods },
    .{ .name = "TypeError", .kind = .type_error, .length = 1, .prototype_methods = &no_methods },
    .{ .name = "URIError", .kind = .uri_error, .length = 1, .prototype_methods = &no_methods },
    .{ .name = "DOMException", .kind = .dom_exception, .length = 2, .prototype_methods = &no_methods },
    .{ .name = "DisposableStack", .kind = .disposable_stack, .length = 0, .prototype_methods = &disposable_stack_prototype },
    .{ .name = "AsyncDisposableStack", .kind = .async_disposable_stack, .length = 0, .prototype_methods = &async_disposable_stack_prototype },
    .{ .name = "Promise", .kind = .promise, .length = 1, .static_methods = &promise_static, .prototype_methods = &promise_prototype },
    .{ .name = "Map", .kind = .map, .length = 0, .static_methods = &map_static, .prototype_methods = &map_prototype },
    .{ .name = "Set", .kind = .set, .length = 0, .prototype_methods = &set_prototype },
    .{ .name = "WeakMap", .kind = .weak_map, .length = 0, .prototype_methods = &weak_map_prototype },
    .{ .name = "WeakSet", .kind = .weak_set, .length = 0, .prototype_methods = &weak_set_prototype },
    .{ .name = "WeakRef", .kind = .weak_ref, .length = 1, .prototype_methods = &weak_ref_prototype },
    .{ .name = "FinalizationRegistry", .kind = .finalization_registry, .length = 1, .prototype_methods = &finalization_registry_prototype },
    .{ .name = "ArrayBuffer", .kind = .array_buffer, .length = 1, .static_methods = &array_buffer_static, .prototype_methods = &buffer_prototype },
    .{ .name = "SharedArrayBuffer", .kind = .shared_array_buffer, .length = 1, .prototype_methods = &shared_buffer_prototype },
    .{ .name = "TypedArray", .kind = .typed_array, .length = 0, .static_methods = &typed_array_static, .prototype_methods = &array_prototype },
    .{ .name = "Int8Array", .kind = .int8_array, .length = 3, .prototype_methods = &no_methods },
    .{ .name = "Uint8Array", .kind = .uint8_array, .length = 3, .prototype_methods = &no_methods },
    .{ .name = "Uint8ClampedArray", .kind = .uint8_clamped_array, .length = 3, .prototype_methods = &no_methods },
    .{ .name = "Int16Array", .kind = .int16_array, .length = 3, .prototype_methods = &no_methods },
    .{ .name = "Uint16Array", .kind = .uint16_array, .length = 3, .prototype_methods = &no_methods },
    .{ .name = "Int32Array", .kind = .int32_array, .length = 3, .prototype_methods = &no_methods },
    .{ .name = "Uint32Array", .kind = .uint32_array, .length = 3, .prototype_methods = &no_methods },
    .{ .name = "Float16Array", .kind = .float16_array, .length = 3, .prototype_methods = &no_methods },
    .{ .name = "Float32Array", .kind = .float32_array, .length = 3, .prototype_methods = &no_methods },
    .{ .name = "Float64Array", .kind = .float64_array, .length = 3, .prototype_methods = &no_methods },
    .{ .name = "BigInt64Array", .kind = .bigint64_array, .length = 3, .prototype_methods = &no_methods },
    .{ .name = "BigUint64Array", .kind = .biguint64_array, .length = 3, .prototype_methods = &no_methods },
    .{ .name = "DataView", .kind = .data_view, .length = 1, .prototype_methods = &data_view_prototype },
    .{ .name = "Proxy", .kind = .proxy, .length = 2, .static_methods = &proxy_static },
    .{ .name = "Iterator", .kind = .iterator, .length = 0, .static_methods = &iterator_static, .prototype_methods = &iterator_prototype },
};

const math_methods = [_]Method{
    .{ .name = "abs", .length = 1 },
    .{ .name = "floor", .length = 1 },
    .{ .name = "ceil", .length = 1 },
    .{ .name = "round", .length = 1 },
    .{ .name = "sqrt", .length = 1 },
    .{ .name = "pow", .length = 2 },
    .{ .name = "min", .length = 2 },
    .{ .name = "max", .length = 2 },
    .{ .name = "random", .length = 0 },
    .{ .name = "exp", .length = 1 },
    .{ .name = "sin", .length = 1 },
    .{ .name = "cos", .length = 1 },
    .{ .name = "tan", .length = 1 },
    .{ .name = "acos", .length = 1 },
    .{ .name = "asin", .length = 1 },
    .{ .name = "atan", .length = 1 },
    .{ .name = "atan2", .length = 2 },
    .{ .name = "acosh", .length = 1 },
    .{ .name = "asinh", .length = 1 },
    .{ .name = "atanh", .length = 1 },
    .{ .name = "cbrt", .length = 1 },
    .{ .name = "clz32", .length = 1 },
    .{ .name = "cosh", .length = 1 },
    .{ .name = "expm1", .length = 1 },
    .{ .name = "f16round", .length = 1 },
    .{ .name = "fround", .length = 1 },
    .{ .name = "hypot", .length = 2 },
    .{ .name = "imul", .length = 2 },
    .{ .name = "log", .length = 1 },
    .{ .name = "log1p", .length = 1 },
    .{ .name = "log2", .length = 1 },
    .{ .name = "log10", .length = 1 },
    .{ .name = "sign", .length = 1 },
    .{ .name = "sinh", .length = 1 },
    .{ .name = "sumPrecise", .length = 1 },
    .{ .name = "tanh", .length = 1 },
    .{ .name = "trunc", .length = 1 },
};

const json_methods = [_]Method{
    .{ .name = "isRawJSON", .length = 1 },
    .{ .name = "parse", .length = 2 },
    .{ .name = "rawJSON", .length = 1 },
    .{ .name = "stringify", .length = 3 },
};

const reflect_methods = [_]Method{
    .{ .name = "defineProperty", .length = 3 },
    .{ .name = "getOwnPropertyDescriptor", .length = 2 },
    .{ .name = "deleteProperty", .length = 2 },
    .{ .name = "get", .length = 2 },
    .{ .name = "getPrototypeOf", .length = 1 },
    .{ .name = "set", .length = 3 },
    .{ .name = "setPrototypeOf", .length = 2 },
    .{ .name = "isExtensible", .length = 1 },
    .{ .name = "preventExtensions", .length = 1 },
    .{ .name = "has", .length = 2 },
    .{ .name = "ownKeys", .length = 1 },
    .{ .name = "construct", .length = 2 },
    .{ .name = "apply", .length = 3 },
};

const atomics_methods = [_]Method{
    .{ .name = "add", .length = 3 },
    .{ .name = "and", .length = 3 },
    .{ .name = "compareExchange", .length = 4 },
    .{ .name = "exchange", .length = 3 },
    .{ .name = "isLockFree", .length = 1 },
    .{ .name = "load", .length = 2 },
    .{ .name = "notify", .length = 3 },
    .{ .name = "or", .length = 3 },
    .{ .name = "pause", .length = 0 },
    .{ .name = "store", .length = 3 },
    .{ .name = "sub", .length = 3 },
    .{ .name = "wait", .length = 4 },
    .{ .name = "waitAsync", .length = 4 },
    .{ .name = "xor", .length = 3 },
};

const performance_methods = [_]Method{
    .{ .name = "now", .length = 0 },
};

fn installSymbolExtras(rt: *core.JSRuntime, symbol_ctor: *core.Object) !void {
    try installWellKnownSymbolProperties(rt, symbol_ctor);
    const proto = constructorPrototypeObject(rt, symbol_ctor) orelse return error.InvalidBuiltinRegistry;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.properties.len + 3);

    const description_key = core.atom.predefinedId("description", .string).?;
    try defineLazyNativeGetterAtom(rt, proto, description_key, "get description", 0, Flags{ .writable = false, .enumerable = false, .configurable = true });

    const to_primitive_flags = core.property.Flags.data(false, false, true);
    try proto.defineAutoInitProperty(rt, core.atom.predefinedId("Symbol.toPrimitive", .symbol).?, "[Symbol.toPrimitive]", 1, to_primitive_flags);

    try defineStringConstantAtomAssumingNew(rt, proto, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, "Symbol", Flags{ .writable = false, .enumerable = false, .configurable = true });
}

fn installWellKnownSymbolProperties(rt: *core.JSRuntime, symbol_ctor: *core.Object) !void {
    try symbol_ctor.reserveOwnPropertyCapacityAssumingPlain(rt, symbol_ctor.properties.len + 15);
    try defineWellKnownSymbol(rt, symbol_ctor, "toPrimitive", "Symbol.toPrimitive");
    try defineWellKnownSymbol(rt, symbol_ctor, "species", "Symbol.species");
    try defineWellKnownSymbol(rt, symbol_ctor, "iterator", "Symbol.iterator");
    try defineWellKnownSymbol(rt, symbol_ctor, "match", "Symbol.match");
    try defineWellKnownSymbol(rt, symbol_ctor, "matchAll", "Symbol.matchAll");
    try defineWellKnownSymbol(rt, symbol_ctor, "replace", "Symbol.replace");
    try defineWellKnownSymbol(rt, symbol_ctor, "search", "Symbol.search");
    try defineWellKnownSymbol(rt, symbol_ctor, "split", "Symbol.split");
    try defineWellKnownSymbol(rt, symbol_ctor, "toStringTag", "Symbol.toStringTag");
    try defineWellKnownSymbol(rt, symbol_ctor, "isConcatSpreadable", "Symbol.isConcatSpreadable");
    try defineWellKnownSymbol(rt, symbol_ctor, "hasInstance", "Symbol.hasInstance");
    try defineWellKnownSymbol(rt, symbol_ctor, "unscopables", "Symbol.unscopables");
    try defineWellKnownSymbol(rt, symbol_ctor, "asyncIterator", "Symbol.asyncIterator");
    try defineWellKnownSymbol(rt, symbol_ctor, "asyncDispose", "Symbol.asyncDispose");
    try defineWellKnownSymbol(rt, symbol_ctor, "dispose", "Symbol.dispose");
}

fn defineWellKnownSymbol(rt: *core.JSRuntime, symbol_ctor: *core.Object, name: []const u8, symbol_name: []const u8) !void {
    const symbol_atom = core.atom.predefinedId(symbol_name, .symbol) orelse return error.InvalidBuiltinRegistry;
    try defineDataAssumingNew(rt, symbol_ctor, name, core.JSValue.symbol(symbol_atom), Flags{ .writable = false, .enumerable = false, .configurable = false });
}

fn installArrayPrototypeSymbols(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    const accessor_flags = Flags{ .writable = false, .enumerable = false, .configurable = true };
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.properties.len + 1);
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.properties.len + 2);
    proto.is_array = true;

    const species_atom = core.atom.predefinedId("Symbol.species", .symbol).?;
    try defineLazyNativeGetterAtom(rt, ctor, species_atom, "get [Symbol.species]", 0, accessor_flags);
    if (!tagAutoInitArrayBuiltinByAtom(ctor, species_atom, .species_getter)) return error.InvalidBuiltinRegistry;

    const iterator_atom = core.atom.predefinedId("Symbol.iterator", .symbol).?;
    const values_atom = core.atom.predefinedId("values", .string).?;
    const values_native_id = core.function.nativeBuiltinId(.array, @intFromEnum(array_builtin.PrototypeMethod.values));
    const to_string_atom = core.atom.predefinedId("toString", .string).?;
    const to_string_native_id = core.function.nativeBuiltinId(.array, @intFromEnum(array_builtin.PrototypeMethod.to_string));
    try replaceSharedLazyNativeMethod(rt, proto, global, to_string_atom, "toString", 0, to_string_native_id, shared_lazy_array_to_string_slot);
    try replaceSharedLazyNativeMethod(rt, proto, global, values_atom, "values", 0, values_native_id, shared_lazy_array_values_slot);
    try defineSharedLazyNativeMethod(rt, proto, global, iterator_atom, "values", 0, values_native_id, shared_lazy_array_values_slot);
    if (!tagAutoInitArrayIteratorKindByAtom(proto, values_atom, 2)) return error.InvalidBuiltinRegistry;
    if (!tagAutoInitArrayIteratorKindByAtom(proto, iterator_atom, 2)) return error.InvalidBuiltinRegistry;

    const unscopables_atom = core.atom.predefinedId("Symbol.unscopables", .symbol).?;
    try proto.defineArrayUnscopablesAutoInitProperty(
        rt,
        unscopables_atom,
        core.property.Flags.data(accessor_flags.writable, accessor_flags.enumerable, accessor_flags.configurable),
    );
}

fn installArrayBufferExtras(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const accessor_flags = Flags{ .writable = false, .enumerable = false, .configurable = true };
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.properties.len + 1);
    try defineLazyNativeGetterAtom(rt, ctor, core.atom.predefinedId("Symbol.species", .symbol).?, "get [Symbol.species]", 0, accessor_flags);

    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    const accessors = [_]struct {
        property_name: []const u8,
        getter_name: []const u8,
    }{
        .{ .property_name = "byteLength", .getter_name = "get byteLength" },
        .{ .property_name = "detached", .getter_name = "get detached" },
        .{ .property_name = "maxByteLength", .getter_name = "get maxByteLength" },
        .{ .property_name = "resizable", .getter_name = "get resizable" },
        .{ .property_name = "immutable", .getter_name = "get immutable" },
    };
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.properties.len + accessors.len + 1);
    for (accessors) |accessor| {
        const native_id = if (buffer_builtin.arrayBufferAccessorMethodId(accessor.property_name)) |id|
            core.function.nativeBuiltinId(.buffer, id)
        else
            0;
        const atom = try temporaryStringAtom(rt, accessor.property_name);
        defer freeTemporaryStringAtom(rt, atom);
        try defineLazyNativeGetterAtom(rt, proto, atom, accessor.getter_name, native_id, accessor_flags);
    }

    try defineStringConstantAtomAssumingNew(rt, proto, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, "ArrayBuffer", Flags{ .writable = false, .enumerable = false, .configurable = true });
}

fn installSharedArrayBufferExtras(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const accessor_flags = Flags{ .writable = false, .enumerable = false, .configurable = true };
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.properties.len + 1);
    try defineLazyNativeGetterAtom(rt, ctor, core.atom.predefinedId("Symbol.species", .symbol).?, "get [Symbol.species]", 0, accessor_flags);

    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    const accessors = [_]struct {
        property_name: []const u8,
        getter_name: []const u8,
    }{
        .{ .property_name = "byteLength", .getter_name = "get byteLength" },
        .{ .property_name = "maxByteLength", .getter_name = "get maxByteLength" },
        .{ .property_name = "growable", .getter_name = "get growable" },
    };
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.properties.len + accessors.len + 1);
    for (accessors) |accessor| {
        const native_id = if (buffer_builtin.sharedArrayBufferAccessorMethodId(accessor.property_name)) |id|
            core.function.nativeBuiltinId(.buffer, id)
        else
            0;
        const atom = core.atom.predefinedId(accessor.property_name, .string) orelse return error.InvalidBuiltinRegistry;
        try defineLazyNativeGetterAtom(rt, proto, atom, accessor.getter_name, native_id, accessor_flags);
    }

    try defineStringConstantAtomAssumingNew(rt, proto, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, "SharedArrayBuffer", Flags{ .writable = false, .enumerable = false, .configurable = true });
}

fn installDataViewExtras(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    const accessor_flags = Flags{ .writable = false, .enumerable = false, .configurable = true };
    const accessors = [_]struct {
        property_name: []const u8,
        getter_name: []const u8,
    }{
        .{ .property_name = "buffer", .getter_name = "get buffer" },
        .{ .property_name = "byteLength", .getter_name = "get byteLength" },
        .{ .property_name = "byteOffset", .getter_name = "get byteOffset" },
    };
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.properties.len + accessors.len + 1);
    for (accessors) |accessor| {
        const native_id = if (buffer_builtin.dataViewAccessorMethodId(accessor.property_name)) |id|
            core.function.nativeBuiltinId(.buffer, id)
        else
            0;
        const atom = core.atom.predefinedId(accessor.property_name, .string) orelse return error.InvalidBuiltinRegistry;
        try defineLazyNativeGetterAtom(rt, proto, atom, accessor.getter_name, native_id, accessor_flags);
    }
    for (data_view_prototype) |method| {
        const id = buffer_builtin.dataViewPrototypeMethodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, proto, method.name, .buffer, id);
    }

    try defineStringConstantAtomAssumingNew(rt, proto, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, "DataView", Flags{ .writable = false, .enumerable = false, .configurable = true });
}

fn installDatePrototypeAliases(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.properties.len + 2);
    const to_utc_id = core.function.nativeBuiltinId(.date, @intFromEnum(date_builtin.PrototypeMethod.to_utc_string));
    try installSharedLazyNativeMethodAlias(rt, proto, global, "toUTCString", "toGMTString", "toUTCString", 0, to_utc_id, shared_lazy_date_to_utc_string_slot);

    const to_primitive_atom = core.atom.predefinedId("Symbol.toPrimitive", .symbol).?;
    const to_primitive_flags = core.property.Flags.data(false, false, true);
    try proto.defineAutoInitPropertyWithRealmAndNative(
        rt,
        to_primitive_atom,
        "[Symbol.toPrimitive]",
        1,
        to_primitive_flags,
        proto.functionRealmGlobalPtr(),
        core.function.nativeBuiltinId(.date, @intFromEnum(@import("date.zig").PrototypeMethod.to_primitive)),
    );
}

fn installFunctionPrototypeExtras(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.properties.len + 1);
    try bindNativeRecordByName(rt, proto, "toString", .function, @intFromEnum(function_builtin.PrototypeMethod.to_string));

    const has_instance_atom = core.atom.predefinedId("Symbol.hasInstance", .symbol) orelse return error.InvalidBuiltinRegistry;
    const has_instance_flags = core.property.Flags.data(false, false, false);
    try proto.defineAutoInitPropertyWithRealm(rt, has_instance_atom, "[Symbol.hasInstance]", 1, has_instance_flags, proto.functionRealmGlobalPtr());
}

fn installErrorPrototypeExtras(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.properties.len + 1);
    try bindNativeRecordByName(rt, proto, "toString", .error_object, @intFromEnum(error_builtin.PrototypeMethod.to_string));

    const stack_key = try temporaryStringAtom(rt, "stack");
    defer freeTemporaryStringAtom(rt, stack_key);
    try defineLazyNativeAccessorPairAtom(
        rt,
        proto,
        stack_key,
        "get stack",
        core.function.nativeBuiltinId(.error_object, @intFromEnum(error_builtin.PrototypeMethod.stack_getter)),
        1,
        core.function.nativeBuiltinId(.error_object, @intFromEnum(error_builtin.PrototypeMethod.stack_setter)),
        Flags{ .writable = false, .enumerable = false, .configurable = true },
        proto.functionRealmGlobalPtr(),
    );
}

fn installPromiseExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const species_atom = core.atom.predefinedId("Symbol.species", .symbol) orelse return error.InvalidBuiltinRegistry;
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.properties.len + 1);
    try defineLazyNativeGetterAtom(rt, ctor, species_atom, "get [Symbol.species]", 0, Flags{ .writable = false, .enumerable = false, .configurable = true });
    try global.setCachedPromiseProto(rt, constructorPrototypeObject(rt, ctor));
}

fn installIteratorExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    _ = global;
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    const accessor_flags = Flags{ .writable = false, .enumerable = false, .configurable = true };
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.properties.len + 4);

    for (iterator_static) |method| {
        const id = iterator_builtin.staticMethodId(method.name) orelse return error.InvalidBuiltinRegistry;
        try bindNativeRecordByName(rt, ctor, method.name, .iterator, id);
    }

    for (iterator_prototype) |method| {
        const id = iterator_builtin.prototypeMethodId(method.name) orelse return error.InvalidBuiltinRegistry;
        try bindNativeRecordByName(rt, proto, method.name, .iterator, id);
    }

    const iterator_atom = core.atom.predefinedId("Symbol.iterator", .symbol).?;
    const iterator_flags = core.property.Flags.data(method_flags.writable, method_flags.enumerable, method_flags.configurable);
    try proto.defineAutoInitProperty(rt, iterator_atom, "[Symbol.iterator]", 0, iterator_flags);
    if (!tagAutoInitIteratorIdentityByAtom(proto, iterator_atom)) return error.InvalidBuiltinRegistry;

    try proto.defineAutoInitPropertyWithRealmAndNative(
        rt,
        core.atom.ids.Symbol_dispose,
        "[Symbol.dispose]",
        0,
        iterator_flags,
        null,
        core.function.nativeBuiltinId(.iterator, @intFromEnum(iterator_builtin.PrototypeMethod.dispose)),
    );

    try defineLazyNativeAccessorPairAtom(
        rt,
        proto,
        core.atom.ids.constructor,
        "get constructor",
        core.function.nativeBuiltinId(.iterator, @intFromEnum(iterator_builtin.AccessorMethod.constructor_getter)),
        1,
        core.function.nativeBuiltinId(.iterator, @intFromEnum(iterator_builtin.AccessorMethod.constructor_setter)),
        accessor_flags,
        null,
    );

    try defineLazyNativeAccessorPairAtom(
        rt,
        proto,
        core.atom.predefinedId("Symbol.toStringTag", .symbol).?,
        "get [Symbol.toStringTag]",
        core.function.nativeBuiltinId(.iterator, @intFromEnum(iterator_builtin.AccessorMethod.to_string_tag_getter)),
        1,
        core.function.nativeBuiltinId(.iterator, @intFromEnum(iterator_builtin.AccessorMethod.to_string_tag_setter)),
        accessor_flags,
        null,
    );
}

fn installStringPrototypeAliases(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.properties.len + 4);
    try defineData(rt, proto, "length", core.JSValue.int32(0), Flags{ .writable = false, .enumerable = false, .configurable = true });
    const trim_start_id = core.function.nativeBuiltinId(.string, @intFromEnum(string_builtin.PrototypeMethod.trim_start));
    try installSharedLazyNativeMethodAlias(rt, proto, global, "trimStart", "trimLeft", "trimStart", 0, trim_start_id, shared_lazy_string_trim_start_slot);
    const trim_end_id = core.function.nativeBuiltinId(.string, @intFromEnum(string_builtin.PrototypeMethod.trim_end));
    try installSharedLazyNativeMethodAlias(rt, proto, global, "trimEnd", "trimRight", "trimEnd", 0, trim_end_id, shared_lazy_string_trim_end_slot);
    const iterator_flags = core.property.Flags.data(method_flags.writable, method_flags.enumerable, method_flags.configurable);
    try proto.defineAutoInitProperty(rt, core.atom.predefinedId("Symbol.iterator", .symbol).?, "[Symbol.iterator]", 0, iterator_flags);
}

fn installObjectPrototypeExtras(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;

    const proto_key = try rt.internAtom("__proto__");
    defer rt.atoms.free(proto_key);
    try defineLazyNativeAccessorPairAtom(rt, proto, proto_key, "get __proto__", 0, 1, 0, Flags{ .writable = false, .enumerable = false, .configurable = true }, null);
}

fn tagArrayPrototypeMethods(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    const key = core.atom.predefinedId("toString", .string).?;
    if (!tagAutoInitArrayBuiltinByAtom(proto, key, .to_string)) return error.InvalidBuiltinRegistry;
    const locale_key = core.atom.predefinedId("toLocaleString", .string).?;
    if (!tagAutoInitArrayBuiltinByAtom(proto, locale_key, .to_locale_string)) return error.InvalidBuiltinRegistry;
    const concat_key = core.atom.predefinedId("concat", .string).?;
    if (!tagAutoInitArrayBuiltinByAtom(proto, concat_key, .concat)) return error.InvalidBuiltinRegistry;
    try tagArrayIteratorMethod(rt, proto, "keys", 1);
    try tagArrayIteratorMethod(rt, proto, "values", 2);
    try tagArrayIteratorMethod(rt, proto, "entries", 3);
}

fn bindBufferPrototypeNativeRecords(rt: *core.JSRuntime, ctor: *core.Object, kind: i32) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    const methods = switch (kind) {
        1 => buffer_prototype[0..],
        2 => shared_buffer_prototype[0..],
        else => return,
    };
    for (methods) |method| {
        const key = try temporaryStringAtom(rt, method.name);
        defer freeTemporaryStringAtom(rt, key);
        const id = switch (kind) {
            1 => buffer_builtin.arrayBufferPrototypeMethodId(method.name),
            2 => buffer_builtin.sharedArrayBufferPrototypeMethodId(method.name),
            else => null,
        };
        if (id) |native_id| {
            if (bindAutoInitNativeRecordByAtom(proto, key, core.function.nativeBuiltinId(.buffer, native_id))) continue;
        }
        const value = proto.getProperty(key);
        defer value.free(rt);
        if (!value.isObject()) continue;
        const function_object = expectObject(value);
        if (id) |native_id| function_object.nativeFunctionIdSlot().* = core.function.nativeBuiltinId(.buffer, native_id);
    }
}

fn tagArrayIteratorMethod(rt: *core.JSRuntime, proto: *core.Object, name: []const u8, kind: u8) !void {
    const key = try temporaryStringAtom(rt, name);
    defer freeTemporaryStringAtom(rt, key);
    if (tagAutoInitArrayIteratorKindByAtom(proto, key, kind)) return;
    const value = proto.getProperty(key);
    defer value.free(rt);
    if (!value.isObject()) return;
    if (!expectObject(value).addArrayIteratorKind(kind)) return error.InvalidBuiltinRegistry;
}

fn installPerformance(rt: *core.JSRuntime, global: *core.Object) !void {
    const key = core.atom.predefinedId("performance", .string).?;
    const flags = core.property.Flags.data(global_flags.writable, global_flags.enumerable, global_flags.configurable);
    try global.definePerformanceAutoInitProperty(rt, key, flags, global);
}

fn installNavigator(rt: *core.JSRuntime, global: *core.Object) !void {
    const key = core.atom.predefinedId("navigator", .string).?;
    const flags = core.property.Flags.data(false, true, true);
    try global.defineNavigatorAutoInitProperty(rt, key, flags, global);
}

fn bindPrimitivePrototypeNativeRecordsWithTag(rt: *core.JSRuntime, ctor: *core.Object, tag: i32) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    if (tag != 1) try bindNativeRecordByName(rt, proto, "toString", .primitive, @intCast(tag * 10 + 1));
    try bindNativeRecordByName(rt, proto, "valueOf", .primitive, @intCast(tag * 10 + 2));
}

fn primitivePrototypeTagForKind(kind: ConstructorKind) ?i32 {
    return switch (kind) {
        .number => 1,
        .boolean => 2,
        .bigint => 3,
        .symbol => 4,
        .string => 5,
        else => null,
    };
}

fn installRegExpExtras(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try bindRegExpPrototypeNativeRecords(rt, proto);
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.properties.len + 21);

    const escape_key = try rt.internAtom("escape");
    defer rt.atoms.free(escape_key);
    const escape_flags = core.property.Flags.data(method_flags.writable, method_flags.enumerable, method_flags.configurable);
    try ctor.defineAutoInitPropertyWithRealmAndNative(rt, escape_key, "escape", 1, escape_flags, null, core.function.nativeBuiltinId(.regexp, @intFromEnum(regexp_builtin.StaticMethod.escape)));

    const symbol_methods = [_]struct {
        symbol: []const u8,
        name: []const u8,
        length: i32,
    }{
        .{ .symbol = "Symbol.match", .name = "[Symbol.match]", .length = 1 },
        .{ .symbol = "Symbol.matchAll", .name = "[Symbol.matchAll]", .length = 1 },
        .{ .symbol = "Symbol.replace", .name = "[Symbol.replace]", .length = 2 },
        .{ .symbol = "Symbol.search", .name = "[Symbol.search]", .length = 1 },
        .{ .symbol = "Symbol.split", .name = "[Symbol.split]", .length = 2 },
    };
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.properties.len + symbol_methods.len + 10);
    for (symbol_methods) |method| {
        const id = regexp_builtin.prototypeMethodId(method.name) orelse return error.InvalidBuiltinRegistry;
        const flags = core.property.Flags.data(method_flags.writable, method_flags.enumerable, method_flags.configurable);
        try proto.defineAutoInitPropertyWithRealmAndNative(
            rt,
            core.atom.predefinedId(method.symbol, .symbol).?,
            method.name,
            method.length,
            flags,
            null,
            core.function.nativeBuiltinId(.regexp, id),
        );
    }

    const accessor_flags = Flags{ .writable = false, .enumerable = false, .configurable = true };
    const accessors = [_]struct {
        property_name: []const u8,
        getter_name: []const u8,
    }{
        .{ .property_name = "source", .getter_name = "get source" },
        .{ .property_name = "flags", .getter_name = "get flags" },
        .{ .property_name = "global", .getter_name = "get global" },
        .{ .property_name = "ignoreCase", .getter_name = "get ignoreCase" },
        .{ .property_name = "multiline", .getter_name = "get multiline" },
        .{ .property_name = "dotAll", .getter_name = "get dotAll" },
        .{ .property_name = "unicode", .getter_name = "get unicode" },
        .{ .property_name = "sticky", .getter_name = "get sticky" },
        .{ .property_name = "hasIndices", .getter_name = "get hasIndices" },
        .{ .property_name = "unicodeSets", .getter_name = "get unicodeSets" },
    };
    for (accessors) |accessor| {
        const native_id = if (regexp_builtin.accessorMethodId(accessor.property_name)) |id|
            core.function.nativeBuiltinId(.regexp, id)
        else
            0;
        const key = core.atom.predefinedId(accessor.property_name, .string) orelse return error.InvalidBuiltinRegistry;
        try defineLazyNativeGetterAtom(rt, proto, key, accessor.getter_name, native_id, accessor_flags);
    }

    try defineLazyNativeGetterAtom(rt, ctor, core.atom.predefinedId("Symbol.species", .symbol).?, "get [Symbol.species]", 0, accessor_flags);

    try installRegExpLegacyAccessors(rt, ctor);
}

fn installRegExpLegacyAccessors(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const flags = Flags{ .writable = false, .enumerable = false, .configurable = true };
    const accessors = [_]struct {
        name: []const u8,
        getter_name: []const u8,
        getter: regexp_builtin.LegacyAccessorMethod,
        setter: ?regexp_builtin.LegacyAccessorMethod = null,
    }{
        .{ .name = "input", .getter_name = "get input", .getter = .get_input, .setter = .set_input },
        .{ .name = "$_", .getter_name = "get $_", .getter = .get_input, .setter = .set_input },
        .{ .name = "lastMatch", .getter_name = "get lastMatch", .getter = .get_last_match },
        .{ .name = "$&", .getter_name = "get $&", .getter = .get_last_match },
        .{ .name = "lastParen", .getter_name = "get lastParen", .getter = .get_last_paren },
        .{ .name = "$+", .getter_name = "get $+", .getter = .get_last_paren },
        .{ .name = "leftContext", .getter_name = "get leftContext", .getter = .get_left_context },
        .{ .name = "$`", .getter_name = "get $`", .getter = .get_left_context },
        .{ .name = "rightContext", .getter_name = "get rightContext", .getter = .get_right_context },
        .{ .name = "$'", .getter_name = "get $'", .getter = .get_right_context },
        .{ .name = "$1", .getter_name = "get $1", .getter = .get_capture_1 },
        .{ .name = "$2", .getter_name = "get $2", .getter = .get_capture_2 },
        .{ .name = "$3", .getter_name = "get $3", .getter = .get_capture_3 },
        .{ .name = "$4", .getter_name = "get $4", .getter = .get_capture_4 },
        .{ .name = "$5", .getter_name = "get $5", .getter = .get_capture_5 },
        .{ .name = "$6", .getter_name = "get $6", .getter = .get_capture_6 },
        .{ .name = "$7", .getter_name = "get $7", .getter = .get_capture_7 },
        .{ .name = "$8", .getter_name = "get $8", .getter = .get_capture_8 },
        .{ .name = "$9", .getter_name = "get $9", .getter = .get_capture_9 },
    };
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.properties.len + accessors.len);
    for (accessors) |accessor| {
        try defineRegExpLegacyAccessor(rt, ctor, accessor.name, accessor.getter_name, accessor.getter, accessor.setter, flags);
    }
}

fn defineRegExpLegacyAccessor(
    rt: *core.JSRuntime,
    ctor: *core.Object,
    name: []const u8,
    getter_name: []const u8,
    getter_method: regexp_builtin.LegacyAccessorMethod,
    setter_method: ?regexp_builtin.LegacyAccessorMethod,
    flags: Flags,
) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    const getter_id = core.function.nativeBuiltinId(.regexp, @intFromEnum(getter_method));
    if (setter_method) |method| {
        try defineLazyNativeAccessorPairAtom(
            rt,
            ctor,
            key,
            getter_name,
            getter_id,
            1,
            core.function.nativeBuiltinId(.regexp, @intFromEnum(method)),
            flags,
            ctor.functionRealmGlobalPtr(),
        );
    } else {
        try defineLazyNativeGetterAtomWithRealm(rt, ctor, key, getter_name, getter_id, flags, ctor.functionRealmGlobalPtr());
    }
}

fn bindRegExpPrototypeNativeRecords(rt: *core.JSRuntime, proto: *core.Object) !void {
    for (regexp_prototype) |method| {
        const id = regexp_builtin.prototypeMethodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, proto, method.name, .regexp, id);
    }
}

fn installSharedLazyNativeMethodAlias(
    rt: *core.JSRuntime,
    proto: *core.Object,
    global: *core.Object,
    target: []const u8,
    alias: []const u8,
    function_name: []const u8,
    length: i32,
    native_builtin_id: i32,
    shared_cache_slot: u8,
) !void {
    const target_key = try temporaryStringAtom(rt, target);
    defer freeTemporaryStringAtom(rt, target_key);
    const alias_key = try temporaryStringAtom(rt, alias);
    defer freeTemporaryStringAtom(rt, alias_key);
    try replaceSharedLazyNativeMethod(rt, proto, global, target_key, function_name, length, native_builtin_id, shared_cache_slot);
    try defineSharedLazyNativeMethod(rt, proto, global, alias_key, function_name, length, native_builtin_id, shared_cache_slot);
}

fn installCollectionExtras(rt: *core.JSRuntime, global: *core.Object, name: []const u8, ctor: *core.Object) !void {
    if (std.mem.eql(u8, name, "Map") or std.mem.eql(u8, name, "Set")) try installCollectionSpecies(rt, ctor);
    try bindCollectionStaticNativeRecords(rt, ctor, name);
    try wireCollectionPrototypeGraph(rt, global, ctor);
    try tagCollectionPrototypeMethods(rt, name, ctor);
    try installCollectionPrototypeSymbols(rt, global, name, ctor);
}

fn installCollectionSpecies(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const species_atom = core.atom.predefinedId("Symbol.species", .symbol) orelse return error.InvalidBuiltinRegistry;
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.properties.len + 1);
    try defineLazyNativeGetterAtom(rt, ctor, species_atom, "get [Symbol.species]", 0, Flags{ .writable = false, .enumerable = false, .configurable = true });
}

fn installTypedArraySpecies(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const species_atom = core.atom.predefinedId("Symbol.species", .symbol) orelse return error.InvalidBuiltinRegistry;
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.properties.len + 1);
    try defineLazyNativeGetterAtom(rt, ctor, species_atom, "get [Symbol.species]", 0, Flags{ .writable = false, .enumerable = false, .configurable = true });
}

fn installTypedArrayArrayBufferPrototype(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const array_buffer_atom = core.atom.predefinedId("ArrayBuffer", .string).?;
    const array_buffer_ctor = global.getOwnDataObjectBorrowed(array_buffer_atom) orelse return;
    const array_buffer_proto = constructorPrototypeObject(rt, array_buffer_ctor) orelse return;

    const proto = constructorPrototypeObject(rt, ctor) orelse return;
    try proto.setTypedArrayArrayBufferPrototype(rt, array_buffer_proto.value().dup());
}

fn wireCollectionPrototypeGraph(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    if (!proto.hasOwnProperty(core.atom.ids.constructor)) {
        try defineData(rt, proto, "constructor", ctor.value(), Flags{ .writable = true, .enumerable = false, .configurable = true });
    }

    const object_ctor = global.getOwnDataObjectBorrowed(core.atom.ids.Object) orelse return error.InvalidBuiltinRegistry;
    const object_proto = constructorPrototypeObject(rt, object_ctor) orelse return error.InvalidBuiltinRegistry;
    try proto.setPrototype(rt, object_proto);

    const function_proto = try functionPrototypeForWiring(rt, global);
    try ctor.setPrototype(rt, function_proto);
}

fn installCollectionPrototypeSymbols(rt: *core.JSRuntime, global: *core.Object, name: []const u8, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    const extra_count: usize = if (std.mem.eql(u8, name, "Map") or std.mem.eql(u8, name, "Set")) 3 else 1;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.properties.len + extra_count);

    if (std.mem.eql(u8, name, "Map") or std.mem.eql(u8, name, "Set")) {
        const owner_class = if (std.mem.eql(u8, name, "Map")) core.class.ids.map else core.class.ids.set;
        const size_atom = core.atom.predefinedId("size", .string).?;
        const native_id = core.function.nativeBuiltinId(.collection, @intFromEnum(collection_builtin.PrototypeMethod.size_getter));
        try defineLazyNativeGetterAtom(rt, proto, size_atom, "get size", native_id, Flags{ .writable = false, .enumerable = false, .configurable = true });
        if (!tagAutoInitCollectionOwnerByAtom(proto, size_atom, owner_class)) return error.InvalidBuiltinRegistry;
    }

    if (std.mem.eql(u8, name, "Map")) {
        const entries_atom = core.atom.predefinedId("entries", .string).?;
        const iterator_atom = core.atom.predefinedId("Symbol.iterator", .symbol).?;
        const entries_native_id = core.function.nativeBuiltinId(.collection, @intFromEnum(collection_builtin.PrototypeMethod.entries));
        try replaceSharedLazyNativeMethod(rt, proto, global, entries_atom, "entries", 0, entries_native_id, shared_lazy_map_entries_slot);
        try defineSharedLazyNativeMethod(rt, proto, global, iterator_atom, "entries", 0, entries_native_id, shared_lazy_map_entries_slot);
        if (!tagAutoInitCollectionOwnerByAtom(proto, entries_atom, core.class.ids.map)) return error.InvalidBuiltinRegistry;
        if (!tagAutoInitCollectionOwnerByAtom(proto, iterator_atom, core.class.ids.map)) return error.InvalidBuiltinRegistry;
    } else if (std.mem.eql(u8, name, "Set")) {
        const values_atom = core.atom.predefinedId("values", .string).?;
        const keys_atom = core.atom.predefinedId("keys", .string).?;
        const iterator_atom = core.atom.predefinedId("Symbol.iterator", .symbol).?;
        const values_native_id = core.function.nativeBuiltinId(.collection, @intFromEnum(collection_builtin.PrototypeMethod.values));
        try replaceSharedLazyNativeMethod(rt, proto, global, values_atom, "values", 0, values_native_id, shared_lazy_set_values_slot);
        try replaceSharedLazyNativeMethod(rt, proto, global, keys_atom, "values", 0, values_native_id, shared_lazy_set_values_slot);
        try defineSharedLazyNativeMethod(rt, proto, global, iterator_atom, "values", 0, values_native_id, shared_lazy_set_values_slot);
        if (!tagAutoInitCollectionOwnerByAtom(proto, values_atom, core.class.ids.set)) return error.InvalidBuiltinRegistry;
        if (!tagAutoInitCollectionOwnerByAtom(proto, keys_atom, core.class.ids.set)) return error.InvalidBuiltinRegistry;
        if (!tagAutoInitCollectionOwnerByAtom(proto, iterator_atom, core.class.ids.set)) return error.InvalidBuiltinRegistry;
    }

    try defineStringConstantAtomAssumingNew(rt, proto, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, collectionTag(name) orelse return error.InvalidBuiltinRegistry, Flags{ .writable = false, .enumerable = false, .configurable = true });
}

fn installNamespaceToStringTag(rt: *core.JSRuntime, namespace: *core.Object, tag_name: []const u8) !void {
    try defineStringConstantAtomAssumingNew(rt, namespace, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, tag_name, Flags{ .writable = false, .enumerable = false, .configurable = true });
}

fn installPrototypeToStringTag(rt: *core.JSRuntime, tag_name: []const u8, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try defineStringConstantAtomAssumingNew(rt, proto, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, tag_name, Flags{ .writable = false, .enumerable = false, .configurable = true });
}

fn installDisposableStackExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.properties.len + 3);

    const method_tags = [_]struct { name: []const u8, id: u8 }{
        .{ .name = "use", .id = 1 },
        .{ .name = "adopt", .id = 2 },
        .{ .name = "defer", .id = 3 },
        .{ .name = "dispose", .id = 4 },
        .{ .name = "move", .id = 5 },
    };
    for (method_tags) |tag| {
        const key = try temporaryStringAtom(rt, tag.name);
        defer freeTemporaryStringAtom(rt, key);
        if (tagAutoInitDisposableStackMethodByAtom(proto, key, tag.id)) continue;
        const value = proto.getProperty(key);
        defer value.free(rt);
        if (!value.isObject()) return error.InvalidBuiltinRegistry;
        if (!expectObject(value).addDisposableStackMethod(tag.id)) return error.InvalidBuiltinRegistry;
    }

    const disposed_key = try temporaryStringAtom(rt, "disposed");
    defer freeTemporaryStringAtom(rt, disposed_key);
    try defineLazyNativeGetterAtom(rt, proto, disposed_key, "get disposed", 0, Flags{ .writable = false, .enumerable = false, .configurable = true });
    if (!tagAutoInitDisposableStackMethodByAtom(proto, disposed_key, 6)) return error.InvalidBuiltinRegistry;

    const dispose_atom = core.atom.predefinedId("dispose", .string).?;
    try replaceSharedLazyNativeMethod(rt, proto, global, dispose_atom, "dispose", 0, 0, shared_lazy_disposable_stack_dispose_slot);
    try defineSharedLazyNativeMethod(rt, proto, global, core.atom.ids.Symbol_dispose, "dispose", 0, 0, shared_lazy_disposable_stack_dispose_slot);
    if (!tagAutoInitDisposableStackMethodByAtom(proto, dispose_atom, 4)) return error.InvalidBuiltinRegistry;
    if (!tagAutoInitDisposableStackMethodByAtom(proto, core.atom.ids.Symbol_dispose, 4)) return error.InvalidBuiltinRegistry;

    try defineStringConstantAtomAssumingNew(rt, proto, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, "DisposableStack", Flags{ .writable = false, .enumerable = false, .configurable = true });
}

fn installAsyncDisposableStackExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.properties.len + 3);

    const method_tags = [_]struct { name: []const u8, id: u8 }{
        .{ .name = "use", .id = 1 },
        .{ .name = "adopt", .id = 2 },
        .{ .name = "defer", .id = 3 },
        .{ .name = "disposeAsync", .id = 4 },
        .{ .name = "move", .id = 5 },
    };
    for (method_tags) |tag| {
        const key = try temporaryStringAtom(rt, tag.name);
        defer freeTemporaryStringAtom(rt, key);
        if (tagAutoInitAsyncDisposableStackMethodByAtom(proto, key, tag.id)) continue;
        const value = proto.getProperty(key);
        defer value.free(rt);
        if (!value.isObject()) return error.InvalidBuiltinRegistry;
        if (!expectObject(value).addAsyncDisposableStackMethod(tag.id)) return error.InvalidBuiltinRegistry;
    }

    const disposed_key = try temporaryStringAtom(rt, "disposed");
    defer freeTemporaryStringAtom(rt, disposed_key);
    try defineLazyNativeGetterAtom(rt, proto, disposed_key, "get disposed", 0, Flags{ .writable = false, .enumerable = false, .configurable = true });
    if (!tagAutoInitAsyncDisposableStackMethodByAtom(proto, disposed_key, 6)) return error.InvalidBuiltinRegistry;

    const dispose_async_key = try temporaryStringAtom(rt, "disposeAsync");
    defer freeTemporaryStringAtom(rt, dispose_async_key);
    try replaceSharedLazyNativeMethod(rt, proto, global, dispose_async_key, "disposeAsync", 0, 0, shared_lazy_async_disposable_stack_dispose_slot);
    try defineSharedLazyNativeMethod(rt, proto, global, core.atom.ids.Symbol_asyncDispose, "disposeAsync", 0, 0, shared_lazy_async_disposable_stack_dispose_slot);
    if (!tagAutoInitAsyncDisposableStackMethodByAtom(proto, dispose_async_key, 4)) return error.InvalidBuiltinRegistry;
    if (!tagAutoInitAsyncDisposableStackMethodByAtom(proto, core.atom.ids.Symbol_asyncDispose, 4)) return error.InvalidBuiltinRegistry;

    try defineStringConstantAtomAssumingNew(rt, proto, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, "AsyncDisposableStack", Flags{ .writable = false, .enumerable = false, .configurable = true });
}

fn installDOMExceptionExtras(rt: *core.JSRuntime, ctor: *core.Object) !void {
    try installPrototypeToStringTag(rt, "DOMException", ctor);
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    const flags = Flags{ .writable = false, .enumerable = true, .configurable = false };
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.properties.len + dom_exception_constants.len);
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.properties.len + dom_exception_constants.len);
    for (dom_exception_constants) |constant| {
        try defineDataAssumingNew(rt, ctor, constant.name, core.JSValue.int32(constant.code), flags);
        try defineDataAssumingNew(rt, proto, constant.name, core.JSValue.int32(constant.code), flags);
    }
}

fn collectionTag(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "Map")) return "Map";
    if (std.mem.eql(u8, name, "Set")) return "Set";
    if (std.mem.eql(u8, name, "WeakMap")) return "WeakMap";
    if (std.mem.eql(u8, name, "WeakSet")) return "WeakSet";
    return null;
}

fn collectionNameForKind(kind: ConstructorKind) ?[]const u8 {
    return switch (kind) {
        .map => "Map",
        .set => "Set",
        .weak_map => "WeakMap",
        .weak_set => "WeakSet",
        else => null,
    };
}

fn tagCollectionPrototypeMethods(rt: *core.JSRuntime, name: []const u8, ctor: *core.Object) !void {
    const class_id = collectionClassId(name) orelse return error.InvalidBuiltinRegistry;
    const methods = collectionPrototypeMethods(name) orelse return error.InvalidBuiltinRegistry;
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;

    for (methods) |method| {
        const method_key = try temporaryStringAtom(rt, method.name);
        defer freeTemporaryStringAtom(rt, method_key);
        const native_deferred = if (collection_builtin.prototypeMethodId(method.name)) |id|
            bindAutoInitNativeRecordByAtom(proto, method_key, core.function.nativeBuiltinId(.collection, id))
        else
            true;
        const marker_deferred = tagAutoInitCollectionOwnerByAtom(proto, method_key, class_id);
        if (native_deferred and marker_deferred) continue;
        const method_value = proto.getProperty(method_key);
        defer method_value.free(rt);
        if (!method_value.isObject()) continue;
        const function_object = expectObject(method_value);
        if (collection_builtin.prototypeMethodId(method.name)) |id| {
            function_object.nativeFunctionIdSlot().* = core.function.nativeBuiltinId(.collection, id);
        }
        if (!function_object.addCollectionMethodOwnerClass(class_id)) return error.InvalidBuiltinRegistry;
    }
}

fn collectionPrototypeMethods(name: []const u8) ?[]const Method {
    if (std.mem.eql(u8, name, "Map")) return &map_prototype;
    if (std.mem.eql(u8, name, "Set")) return &set_prototype;
    if (std.mem.eql(u8, name, "WeakMap")) return &weak_map_prototype;
    if (std.mem.eql(u8, name, "WeakSet")) return &weak_set_prototype;
    return null;
}

fn collectionClassId(name: []const u8) ?core.ClassId {
    if (std.mem.eql(u8, name, "Map")) return core.class.ids.map;
    if (std.mem.eql(u8, name, "Set")) return core.class.ids.set;
    if (std.mem.eql(u8, name, "WeakMap")) return core.class.ids.weakmap;
    if (std.mem.eql(u8, name, "WeakSet")) return core.class.ids.weakset;
    return null;
}

fn functionPrototypeForWiring(rt: *core.JSRuntime, global: *core.Object) !*core.Object {
    if (global.cachedFunctionProto()) |function_proto| return function_proto;
    const function_ctor = global.getOwnDataObjectBorrowed(core.atom.ids.Function) orelse return error.InvalidBuiltinRegistry;
    return constructorPrototypeObject(rt, function_ctor) orelse return error.InvalidBuiltinRegistry;
}

fn wireNativeFunctionPropertyPrototypesWithProto(rt: *core.JSRuntime, target: *core.Object, function_proto: *core.Object) !void {
    // Walk the property table directly (instead of `ownKeys` + per-key
    // `getOwnProperty`) so we can SKIP `auto_init` placeholders without
    // forcing their materialization. The whole point of the lazy
    // builtins is that `installStandardGlobals` should NOT pay the
    // ~700 native-function-object allocations up front, and
    // `getOwnProperty` would materialize each placeholder on read.
    //
    // Function.prototype for lazy methods is set inside
    // `Object.materializeAutoInit` instead, using the cached
    // realm-global Function.prototype slot populated while installing
    // the Function constructor.
    for (target.properties) |entry| {
        if (entry.flags.deleted) continue;
        switch (entry.slot) {
            .data => |value| try wireNativeFunctionPrototype(rt, value, function_proto),
            .accessor => |accessor| {
                try wireNativeFunctionPrototype(rt, accessor.getter, function_proto);
                try wireNativeFunctionPrototype(rt, accessor.setter, function_proto);
            },
            // Auto-init placeholders self-wire on materialization.
            .auto_init => {},
            .deleted => {},
        }
    }
}

fn wireNativeFunctionPropertyPrototypes(rt: *core.JSRuntime, global: *core.Object, target: *core.Object) !void {
    const function_proto = try functionPrototypeForWiring(rt, global);
    try wireNativeFunctionPropertyPrototypesWithProto(rt, target, function_proto);
}

fn wireAllNativeFunctionPrototypes(rt: *core.JSRuntime, global: *core.Object, constructors: []const ?*core.Object) !void {
    const function_proto = try functionPrototypeForWiring(rt, global);
    try wireNativeFunctionPropertyPrototypesWithProto(rt, global, function_proto);

    for (constructors) |maybe_ctor| {
        const ctor = maybe_ctor orelse continue;
        try wireNativeFunctionPropertyPrototypesWithProto(rt, ctor, function_proto);
        if (constructorPrototypeObject(rt, ctor)) |proto| {
            try wireNativeFunctionPropertyPrototypesWithProto(rt, proto, function_proto);
        }
    }
}

fn wireNativeFunctionPrototype(rt: *core.JSRuntime, value: core.JSValue, function_proto: *core.Object) !void {
    if (!value.isObject()) return;
    const header = value.refHeader() orelse return;
    const object: *core.Object = @fieldParentPtr("header", header);
    try object.setFunctionRealmGlobalPtrIfNull(rt, function_proto.functionRealmGlobalPtr());
    if (object == function_proto) return;
    if (object.hasOwnProperty(core.atom.ids.prototype)) return;
    if (object.hostFunctionKind() != 0) return;
    switch (object.class_id) {
        core.class.ids.c_function,
        core.class.ids.c_function_data,
        core.class.ids.c_closure,
        core.class.ids.bytecode_function,
        core.class.ids.bound_function,
        => try object.setPrototype(rt, function_proto),
        else => {},
    }
}
