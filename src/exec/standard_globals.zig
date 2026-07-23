//! Standard ECMAScript global bootstrap.
//!
//! This module owns the JS-visible constructor, namespace, prototype, and
//! method tables. Native operation bodies and record declarations live beside
//! it in exec; callers only need the installer interface below.

const core = @import("../core/root.zig");
const array_builtin = @import("array_builtin_ops.zig");
const buffer_builtin = @import("buffer_ops.zig");
const collection_builtin = @import("collection_ops.zig");
const date_builtin = @import("date_ops.zig");
const error_builtin = @import("error_ops.zig");
const iterator_builtin = @import("iterator_builtin_ops.zig");
const object_builtin = @import("object_builtin_ops.zig");
const regexp_builtin = @import("regexp_ops.zig");
const string_builtin = @import("string_builtin_ops.zig");
const atomics_builtin = @import("atomics_ops.zig");
const reflect_builtin = @import("reflect_proxy_ops.zig");
const typed_array_names = core.typed_array_names;
const internal_builtins = @import("internal_builtins.zig");
const function_ops = @import("function_ops.zig");
const json_builtin = @import("json_ops.zig");
const math_builtin = @import("math_ops.zig");
const number_builtin = @import("number_ops.zig");
const promise_ops = @import("promise_ops.zig");
const uri_builtin = @import("uri_ops.zig");
const std = @import("std");

pub const Flags = struct {
    writable: bool,
    enumerable: bool,
    configurable: bool,
};

/// A standard method table entry is the immutable PROP descriptor itself. Its
/// address is stored directly in the two-word AUTOINIT property slot.
pub const Method = core.property.AutoInit;

fn preparedMethods(comptime source: anytype) @TypeOf(source) {
    var methods = source;
    for (&methods) |*method| method.prepare_native_function = prepareStandardAutoInitNativeFunction;
    return methods;
}

const global_function_methods = preparedMethods([_]Method{
    .{ .name = "parseInt", .length = 2, .native_builtin_id = core.function.nativeBuiltinId(.number, @intFromEnum(number_builtin.StaticMethod.parse_int)) },
    .{ .name = "parseFloat", .length = 1, .native_builtin_id = core.function.nativeBuiltinId(.number, @intFromEnum(number_builtin.StaticMethod.parse_float)) },
    .{ .name = "isNaN", .length = 1, .native_builtin_id = core.function.nativeBuiltinId(.number, @intFromEnum(number_builtin.StaticMethod.is_nan)) },
    .{ .name = "isFinite", .length = 1, .native_builtin_id = core.function.nativeBuiltinId(.number, @intFromEnum(number_builtin.StaticMethod.is_finite)) },
    .{ .name = "eval", .length = 1 },
    .{ .name = "encodeURI", .length = 1, .native_builtin_id = core.function.nativeBuiltinId(.uri, uri_builtin.methodId("encodeURI").?) },
    .{ .name = "decodeURI", .length = 1, .native_builtin_id = core.function.nativeBuiltinId(.uri, uri_builtin.methodId("decodeURI").?) },
    .{ .name = "encodeURIComponent", .length = 1, .native_builtin_id = core.function.nativeBuiltinId(.uri, uri_builtin.methodId("encodeURIComponent").?) },
    .{ .name = "decodeURIComponent", .length = 1, .native_builtin_id = core.function.nativeBuiltinId(.uri, uri_builtin.methodId("decodeURIComponent").?) },
    .{ .name = "escape", .length = 1, .native_builtin_id = core.function.nativeBuiltinId(.uri, core.uri.escape_id) },
    .{ .name = "unescape", .length = 1, .native_builtin_id = core.function.nativeBuiltinId(.uri, core.uri.unescape_id) },
    .{ .name = "btoa", .length = 1, .native_builtin_id = core.function.nativeBuiltinId(.host, @intFromEnum(core.function.HostGlobalMethod.btoa)) },
    .{ .name = "atob", .length = 1, .native_builtin_id = core.function.nativeBuiltinId(.host, @intFromEnum(core.function.HostGlobalMethod.atob)) },
    .{ .name = "queueMicrotask", .length = 1, .native_builtin_id = core.function.nativeBuiltinId(.host, @intFromEnum(core.function.HostGlobalMethod.queue_microtask)) },
    .{ .name = "gc", .length = 0, .native_builtin_id = core.function.nativeBuiltinId(.host, @intFromEnum(core.function.HostGlobalMethod.gc)) },
});

const math_namespace_auto_init = Method{ .name = "Math", .length = 0, .kind = .math_namespace };
const json_namespace_auto_init = Method{ .name = "JSON", .length = 0, .kind = .json_namespace };
const reflect_namespace_auto_init = Method{ .name = "Reflect", .length = 0, .kind = .reflect_namespace };
const atomics_namespace_auto_init = Method{ .name = "Atomics", .length = 0, .kind = .atomics_namespace };
const navigator_auto_init = Method{ .name = "navigator", .length = 0, .kind = .navigator };
const performance_auto_init = Method{ .name = "performance", .length = 0, .kind = .performance };
const array_unscopables_auto_init = Method{ .name = "[Symbol.unscopables]", .length = 0, .kind = .array_unscopables };
const symbol_to_primitive_auto_init = Method{ .name = "[Symbol.toPrimitive]", .length = 1, .native_builtin_id = core.function.nativeBuiltinId(.primitive, primitive_symbol_to_primitive_id) };
const date_to_primitive_auto_init = Method{ .name = "[Symbol.toPrimitive]", .length = 1, .native_builtin_id = core.function.nativeBuiltinId(.date, @intFromEnum(date_builtin.PrototypeMethod.to_primitive)) };
const function_has_instance_auto_init = Method{ .name = "[Symbol.hasInstance]", .length = 1 };
const iterator_dispose_auto_init = Method{ .name = "[Symbol.dispose]", .length = 0, .native_builtin_id = core.function.nativeBuiltinId(.iterator, @intFromEnum(iterator_builtin.PrototypeMethod.dispose)) };
const string_iterator_auto_init = Method{ .name = "[Symbol.iterator]", .length = 0 };
const regexp_escape_auto_init = Method{ .name = "escape", .length = 1, .native_builtin_id = core.function.nativeBuiltinId(.regexp, @intFromEnum(regexp_builtin.StaticMethod.escape)) };

const regexp_symbol_auto_init = [_]struct {
    symbol: []const u8,
    info: Method,
}{
    .{ .symbol = "Symbol.match", .info = .{ .name = "[Symbol.match]", .length = 1, .native_builtin_id = core.function.nativeBuiltinId(.regexp, regexp_builtin.prototypeMethodId("[Symbol.match]").?) } },
    .{ .symbol = "Symbol.matchAll", .info = .{ .name = "[Symbol.matchAll]", .length = 1, .native_builtin_id = core.function.nativeBuiltinId(.regexp, regexp_builtin.prototypeMethodId("[Symbol.matchAll]").?) } },
    .{ .symbol = "Symbol.replace", .info = .{ .name = "[Symbol.replace]", .length = 2, .native_builtin_id = core.function.nativeBuiltinId(.regexp, regexp_builtin.prototypeMethodId("[Symbol.replace]").?) } },
    .{ .symbol = "Symbol.search", .info = .{ .name = "[Symbol.search]", .length = 1, .native_builtin_id = core.function.nativeBuiltinId(.regexp, regexp_builtin.prototypeMethodId("[Symbol.search]").?) } },
    .{ .symbol = "Symbol.split", .info = .{ .name = "[Symbol.split]", .length = 2, .native_builtin_id = core.function.nativeBuiltinId(.regexp, regexp_builtin.prototypeMethodId("[Symbol.split]").?) } },
};

const standard_string_auto_init = [_]Method{
    .{ .name = "", .length = 0, .kind = .string_constant },
    .{ .name = "Error", .length = 0, .kind = .string_constant },
    .{ .name = "EvalError", .length = 0, .kind = .string_constant },
    .{ .name = "RangeError", .length = 0, .kind = .string_constant },
    .{ .name = "ReferenceError", .length = 0, .kind = .string_constant },
    .{ .name = "SyntaxError", .length = 0, .kind = .string_constant },
    .{ .name = "TypeError", .length = 0, .kind = .string_constant },
    .{ .name = "URIError", .length = 0, .kind = .string_constant },
    .{ .name = "InternalError", .length = 0, .kind = .string_constant },
    .{ .name = "AggregateError", .length = 0, .kind = .string_constant },
    .{ .name = "SuppressedError", .length = 0, .kind = .string_constant },
    .{ .name = "DOMException", .length = 0, .kind = .string_constant },
    .{ .name = "Symbol", .length = 0, .kind = .string_constant },
    .{ .name = "ArrayBuffer", .length = 0, .kind = .string_constant },
    .{ .name = "SharedArrayBuffer", .length = 0, .kind = .string_constant },
    .{ .name = "DataView", .length = 0, .kind = .string_constant },
    .{ .name = "Map", .length = 0, .kind = .string_constant },
    .{ .name = "Set", .length = 0, .kind = .string_constant },
    .{ .name = "WeakMap", .length = 0, .kind = .string_constant },
    .{ .name = "WeakSet", .length = 0, .kind = .string_constant },
    .{ .name = "Math", .length = 0, .kind = .string_constant },
    .{ .name = "JSON", .length = 0, .kind = .string_constant },
    .{ .name = "Reflect", .length = 0, .kind = .string_constant },
    .{ .name = "Atomics", .length = 0, .kind = .string_constant },
    .{ .name = "BigInt", .length = 0, .kind = .string_constant },
    .{ .name = "Promise", .length = 0, .kind = .string_constant },
    .{ .name = "WeakRef", .length = 0, .kind = .string_constant },
    .{ .name = "FinalizationRegistry", .length = 0, .kind = .string_constant },
    .{ .name = "DisposableStack", .length = 0, .kind = .string_constant },
    .{ .name = "AsyncDisposableStack", .length = 0, .kind = .string_constant },
};

fn standardStringAutoInitDescriptor(bytes: []const u8) ?*const core.property.AutoInit {
    for (&standard_string_auto_init) |*info| {
        if (std.mem.eql(u8, info.name, bytes)) return info;
    }
    return null;
}

const ConstructorKind = enum {
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
    internal_error,
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

const constructor_kind_count = @typeInfo(ConstructorKind).@"enum".fields.len;

/// QuickJS `JS_NewCConstructor` publishes each intrinsic instance prototype
/// into `ctx->class_proto[class_id]`. Constructor objects and global bindings
/// remain independently mutable; construction fallback reads this realm-owned
/// slot after resolving `newTarget`'s FunctionRealm.
///
/// Native Error subclasses use QuickJS's separate `native_error_proto[]`
/// family and the abstract `%TypedArray%` constructor has no instance class of
/// its own, so neither belongs in this mapping.
fn constructorClassPrototypeId(kind: ConstructorKind) ?core.ClassId {
    return switch (kind) {
        .object => core.class.ids.object,
        .function => core.class.ids.bytecode_function,
        .array => core.class.ids.array,
        .string => core.class.ids.string,
        .number => core.class.ids.number,
        .boolean => core.class.ids.boolean,
        .symbol => core.class.ids.symbol,
        .bigint => core.class.ids.big_int,
        .date => core.class.ids.date,
        .regexp => core.class.ids.regexp,
        .error_ => core.class.ids.error_,
        .dom_exception => core.class.ids.dom_exception,
        .disposable_stack => core.class.ids.disposable_stack,
        .async_disposable_stack => core.class.ids.async_disposable_stack,
        .promise => core.class.ids.promise,
        .map => core.class.ids.map,
        .set => core.class.ids.set,
        .weak_map => core.class.ids.weakmap,
        .weak_set => core.class.ids.weakset,
        .weak_ref => core.class.ids.weak_ref,
        .finalization_registry => core.class.ids.finalization_registry,
        .array_buffer => core.class.ids.array_buffer,
        .shared_array_buffer => core.class.ids.shared_array_buffer,
        .int8_array => core.class.ids.int8_array,
        .uint8_array => core.class.ids.uint8_array,
        .uint8_clamped_array => core.class.ids.uint8c_array,
        .int16_array => core.class.ids.int16_array,
        .uint16_array => core.class.ids.uint16_array,
        .int32_array => core.class.ids.int32_array,
        .uint32_array => core.class.ids.uint32_array,
        .float16_array => core.class.ids.float16_array,
        .float32_array => core.class.ids.float32_array,
        .float64_array => core.class.ids.float64_array,
        .bigint64_array => core.class.ids.big_int64_array,
        .biguint64_array => core.class.ids.big_uint64_array,
        .data_view => core.class.ids.dataview,
        .iterator => core.class.ids.iterator,
        .aggregate_error,
        .suppressed_error,
        .eval_error,
        .range_error,
        .reference_error,
        .syntax_error,
        .type_error,
        .uri_error,
        .internal_error,
        .typed_array,
        .proxy,
        => null,
    };
}

pub const global_flags = Flags{ .writable = true, .enumerable = false, .configurable = true };
pub const method_flags = Flags{ .writable = true, .enumerable = false, .configurable = true };
pub const prototype_flags = Flags{ .writable = false, .enumerable = false, .configurable = false };
/// `.primitive` native-builtin ids encode `class_tag * 10 + method` (class
/// tags: 1 number, 2 boolean, 3 bigint, 4 symbol, 5 string; see
/// `exec/object_ops.qjsPrimitivePrototypeMethod`). Methods 1/2 are
/// toString/valueOf; 3 is the constructor-called-as-function path; 4/5 are
/// the Symbol `description` getter and `[Symbol.toPrimitive]`.
pub const primitive_boolean_ctor_call_id: u32 = 23;
pub const primitive_symbol_ctor_call_id: u32 = 43;
pub const primitive_symbol_description_get_id: u32 = 44;
pub const primitive_symbol_to_primitive_id: u32 = 45;

// `navigator_user_agent` relocated to engine core (`core/function.zig`, beside
// the `navigator_user_agent_get` host getter id) in Phase 6b-3 STEP 2;
// re-exported here unchanged.
pub const navigator_user_agent = core.function.navigator_user_agent;

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
    return defineStringConstantAtomAssumingNewWithRealm(rt, target, atom_id, bytes, flags, null);
}

fn defineStringConstantAtomAssumingNewWithRealm(
    rt: *core.JSRuntime,
    target: *core.Object,
    atom_id: core.Atom,
    bytes: []const u8,
    flags: Flags,
    realm_global: ?*core.Object,
) !void {
    const property_flags = core.property.Flags.data(flags.writable, flags.enumerable, flags.configurable);
    const info = standardStringAutoInitDescriptor(bytes) orelse return error.InvalidBuiltinRegistry;
    try target.defineAutoInitPropertyFromDescriptor(rt, atom_id, property_flags, realm_global, info);
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
    const realm = try bootstrapPropertyRealm(rt, target, realm_global);
    const getter = try core.function.nativeFunction(realm, getter_name, 0);
    defer getter.free(rt);
    if (getter_native_builtin_id != 0) expectObject(getter).setNativeBuiltinIdAndRecord(rt, getter_native_builtin_id);
    try defineAccessorAtom(rt, target, atom_id, getter, core.JSValue.undefinedValue(), flags);
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
    const realm = try bootstrapPropertyRealm(rt, target, realm_global);
    const getter = try core.function.nativeFunction(realm, getter_name, 0);
    defer getter.free(rt);
    if (getter_native_builtin_id != 0) expectObject(getter).setNativeBuiltinIdAndRecord(rt, getter_native_builtin_id);

    if (!std.mem.startsWith(u8, getter_name, "get ")) return error.InvalidBuiltinRegistry;
    var setter_name_buf: [128]u8 = undefined;
    const setter_name = try std.fmt.bufPrint(&setter_name_buf, "set {s}", .{getter_name["get ".len..]});
    const setter = try core.function.nativeFunction(realm, setter_name, setter_length);
    defer setter.free(rt);
    if (setter_native_builtin_id != 0) expectObject(setter).setNativeBuiltinIdAndRecord(rt, setter_native_builtin_id);
    try defineAccessorAtom(rt, target, atom_id, getter, setter, flags);
}

fn bootstrapPropertyRealm(rt: *core.JSRuntime, target: *core.Object, explicit_global: ?*core.Object) !*core.RealmContext {
    if (explicit_global) |global| return rt.contextForGlobalIncludingConstructing(global) orelse error.InvalidBuiltinRegistry;
    if (target.nativeFunctionRealm()) |realm| return realm;
    if (target.bytecodeFunctionRealmContext()) |realm| return realm;
    return rt.contextForGlobalIncludingConstructing(target) orelse error.InvalidBuiltinRegistry;
}

pub fn defineNativeMethod(rt: *core.JSRuntime, target: *core.Object, method: Method) !void {
    const realm = try bootstrapPropertyRealm(rt, target, null);
    const value = try core.function.nativeFunction(realm, method.name, method.length);
    defer value.free(rt);
    try defineData(rt, target, method.name, value, method_flags);
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
    return defineNativeMethodsAssumingNewWithRealm(rt, target, methods, null);
}

fn defineNativeMethodsAssumingNewWithRealm(rt: *core.JSRuntime, target: *core.Object, methods: []const Method, realm_global: ?*core.Object) !void {
    // Standard-global Flags has the local subset (no `.accessor`); translate
    // to the on-disk property.Flags packed-struct representation that
    // `defineAutoInitProperty` writes into the property table.
    const flags = core.property.Flags.data(method_flags.writable, method_flags.enumerable, method_flags.configurable);
    if (methods.len != 0) try target.reserveOwnPropertyCapacityAssumingPlain(rt, target.shape_ref.prop_count + methods.len);
    for (methods) |*method| {
        const key = try temporaryStringAtom(rt, method.name);
        defer freeTemporaryStringAtom(rt, key);
        try target.defineAutoInitPropertyFromDescriptor(rt, key, flags, realm_global, method);
    }
}

pub fn defineGlobalFunction(rt: *core.JSRuntime, global: *core.Object, name: []const u8, length: i32) !void {
    const value = try core.function.nativeFunctionForGlobal(rt, global, name, length);
    defer value.free(rt);
    try defineData(rt, global, name, value, global_flags);
}

fn defineGlobalLazyMethods(rt: *core.JSRuntime, global: *core.Object, methods: []const Method) !void {
    const flags = core.property.Flags.data(global_flags.writable, global_flags.enumerable, global_flags.configurable);
    for (methods) |*method| {
        const key = try temporaryStringAtom(rt, method.name);
        defer freeTemporaryStringAtom(rt, key);
        try global.defineAutoInitPropertyFromDescriptor(rt, key, flags, global, method);
    }
}

fn publishMethodAlias(
    rt: *core.JSRuntime,
    target: *core.Object,
    source: *core.Object,
    source_atom: core.Atom,
    alias_atom: core.Atom,
    replace_existing_auto_init: bool,
) !void {
    const value = try source.getProperty(source_atom);
    defer value.free(rt);
    const flags = core.property.Flags.data(method_flags.writable, method_flags.enumerable, method_flags.configurable);
    if (replace_existing_auto_init) {
        try target.replaceAutoInitPropertyWithData(rt, alias_atom, value, flags);
    } else {
        try target.defineOwnPropertyAssumingNew(
            rt,
            alias_atom,
            core.Descriptor.data(value, method_flags.writable, method_flags.enumerable, method_flags.configurable),
        );
    }
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
    // Namespace is freshly created and method-table entries are unique
    // within `methods`; safe to skip the duplicate-property scan.
    try defineNativeMethodsAssumingNewWithRealm(rt, namespace, methods, global);
    return namespace;
}

fn defineLazyNamespace(rt: *core.JSRuntime, global: *core.Object, name: []const u8, kind: core.property.AutoInitKind) !void {
    const info: *const core.property.AutoInit = switch (kind) {
        .math_namespace => &math_namespace_auto_init,
        .json_namespace => &json_namespace_auto_init,
        .reflect_namespace => &reflect_namespace_auto_init,
        .atomics_namespace => &atomics_namespace_auto_init,
        else => return error.InvalidBuiltinRegistry,
    };
    if (!std.mem.eql(u8, name, info.name)) return error.InvalidBuiltinRegistry;
    const flags = core.property.Flags.data(global_flags.writable, global_flags.enumerable, global_flags.configurable);
    if (core.atom.predefinedId(name, .string)) |key| {
        try global.defineAutoInitPropertyFromDescriptor(rt, key, flags, global, info);
        return;
    }
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try global.defineAutoInitPropertyFromDescriptor(rt, key, flags, global, info);
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
            try installNamespaceToStringTag(rt, global, namespace, "Math");
        },
        .json_namespace => {
            try installNamespaceToStringTag(rt, global, namespace, "JSON");
        },
        .reflect_namespace => {
            try bindReflectNativeRecords(rt, namespace);
            try installNamespaceToStringTag(rt, global, namespace, "Reflect");
        },
        .atomics_namespace => {
            try installNamespaceToStringTag(rt, global, namespace, "Atomics");
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
    const flags = core.property.Flags.data(method_flags.writable, method_flags.enumerable, method_flags.configurable);
    for (&json_methods) |*method| {
        const key = try temporaryStringAtom(rt, method.name);
        defer freeTemporaryStringAtom(rt, key);
        try namespace.defineAutoInitPropertyFromDescriptor(rt, key, flags, global, method);
    }
    return namespace;
}

fn objectPrototypeFromGlobal(rt: *core.JSRuntime, global: *core.Object) ?*core.Object {
    _ = rt;
    const object_atom = core.atom.predefinedId("Object", .string).?;
    if (global.getOwnDataObjectBorrowed(object_atom)) |object_ctor| {
        if (object_ctor.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    }
    return null;
}

const namespace_to_string_tag_property_count: usize = 1;
const math_constant_property_count: usize = 8;
const math_namespace_extra_property_count: usize = math_constant_property_count + namespace_to_string_tag_property_count;
const number_constant_property_count: usize = 8;
const global_lazy_function_property_count: usize = 15;

pub fn standardGlobalOwnPropertyCapacity() usize {
    return constructor_kind_count +
        4 + // Math, JSON, Reflect, Atomics
        2 + // performance, navigator
        global_lazy_function_property_count;
}

fn constructorOwnPropertyCapacity(kind: ConstructorKind, static_method_count: usize) usize {
    const prototype_count: usize = if (kind == .proxy) 0 else 1;
    return 2 + prototype_count + static_method_count + constructorExtraPropertyCount(kind);
}

fn prototypeOwnPropertyCapacity(kind: ConstructorKind, prototype_method_count: usize) usize {
    if (kind == .proxy) return 0;
    const function_prototype_base: usize = if (kind == .function) 2 else 0;
    return function_prototype_base +
        prototype_method_count +
        1 + // constructor, as data property or Iterator accessor
        prototypeExtraPropertyCount(kind);
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
        .internal_error,
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

fn constructorStaticMethodsBeforePrototype(kind: ConstructorKind) bool {
    return switch (kind) {
        .object,
        .number,
        .symbol,
        .error_,
        .date,
        .array,
        .string,
        .bigint,
        .promise,
        .map,
        .array_buffer,
        .typed_array,
        .iterator,
        => true,
        else => false,
    };
}

fn prototypeMethodsAreInstalledByExtras(kind: ConstructorKind) bool {
    return switch (kind) {
        .map,
        .set,
        .array_buffer,
        .shared_array_buffer,
        .data_view,
        => true,
        else => false,
    };
}

fn defineConstructor(
    rt: *core.JSRuntime,
    global: *core.Object,
    constructor_parent: *core.Object,
    prototype_parent: ?*core.Object,
    existing_prototype: ?*core.Object,
    name: []const u8,
    kind: ConstructorKind,
    length: i32,
    static_methods: []const Method,
    prototype_methods: []const Method,
) !core.JSValue {
    const realm = rt.contextForGlobalIncludingConstructing(global) orelse return error.InvalidBuiltinRegistry;
    const constructor_value = try core.function.nativeFunctionWithPrototypeAndCapacity(
        realm,
        constructor_parent,
        name,
        length,
        constructorOwnPropertyCapacity(kind, static_methods.len),
    );
    errdefer constructor_value.free(rt);
    const constructor = expectObject(constructor_value);

    if (kind != .proxy) {
        const prototype_capacity = prototypeOwnPropertyCapacity(kind, prototype_methods.len);
        const prototype_value = if (existing_prototype) |prototype|
            prototype.value().dup()
        else if (kind == .function)
            try core.function.nativeFunctionWithPrototypeAndCapacity(realm, prototype_parent, "", 0, prototype_capacity)
        else if (kind == .array)
            (try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.array, prototype_parent, prototype_capacity)).value()
        else if (kind == .string)
            (try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.string, prototype_parent, prototype_capacity)).value()
        else if (kind == .number)
            (try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.number, prototype_parent, prototype_capacity)).value()
        else if (kind == .boolean)
            (try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.boolean, prototype_parent, prototype_capacity)).value()
        else
            (try core.Object.createWithOwnPropertyCapacity(rt, core.class.ids.object, prototype_parent, prototype_capacity)).value();
        errdefer prototype_value.free(rt);
        const prototype = expectObject(prototype_value);
        // %Array.prototype% is a real Array whose named builtin properties use
        // the cold ordinary payload while it remains non-dense. This is class
        // storage, not a Realm carrier.
        if (kind == .array) _ = try prototype.ensureOrdinaryPayload(rt);
        // Prototype is freshly created above; use the fast path that
        // skips the duplicate-property scan in `defineOwnProperty`.
        // Method-table names are unique within their slice and prototype
        // starts empty, so the precondition holds.
        if (kind == .date)
            try defineDatePrototypeMethodsAssumingNew(rt, global, prototype)
        else if (kind == .object)
            try defineObjectPrototypeMethodsAssumingNew(rt, global, prototype)
        else if (!prototypeMethodsAreInstalledByExtras(kind))
            try defineNativeMethodsAssumingNewWithRealm(rt, prototype, prototype_methods, global);
        if (kind == .number) {
            try prototype.setOptionalValueSlot(rt, prototype.objectDataSlot(), core.JSValue.int32(0));
        }
        if (kind == .string) {
            const empty = try createBuiltinAsciiStringValue(rt, "");
            defer empty.free(rt);
            try prototype.setOptionalValueSlot(rt, prototype.objectDataSlot(), empty.dup());
        }
        if (kind == .boolean) {
            try prototype.setOptionalValueSlot(rt, prototype.objectDataSlot(), core.JSValue.boolean(false));
        }
        if (isErrorConstructorKind(kind)) {
            try defineStringConstantAtomAssumingNewWithRealm(rt, prototype, core.atom.ids.name, name, Flags{ .writable = true, .enumerable = false, .configurable = true }, global);
            try defineStringConstantAtomAssumingNewWithRealm(rt, prototype, core.atom.predefinedId("message", .string).?, "", Flags{ .writable = true, .enumerable = false, .configurable = true }, global);
        }
        if (constructorStaticMethodsBeforePrototype(kind)) {
            // QuickJS's intrinsic setup installs `JSCFunctionListEntry` static
            // entries before `JS_SetConstructor2` attaches `.prototype`.
            try defineNativeMethodsAssumingNew(rt, constructor, static_methods);
        }
        if (kind == .number) {
            try installNumberConstants(rt, constructor);
        }
        if (kind == .symbol) {
            try installWellKnownSymbolProperties(rt, constructor);
        }
        if (typed_array_names.element(name)) |element| {
            try installTypedArrayConstructorElementSize(rt, constructor, @intCast(element.size));
            if (kind == .uint8_array) try installUint8ArrayConstructorCodecExtras(rt, constructor);
        }
        // JS_SetConstructor2 appends the prototype back-reference only after
        // its own function-list fields have been installed.
        if (prototype.isArray())
            try defineData(rt, prototype, "constructor", constructor_value, method_flags)
        else
            try defineDataAssumingNew(rt, prototype, "constructor", constructor_value, method_flags);
        // Constructor is freshly created above; "prototype" is unique among its
        // existing visible properties. For most constructors those are only
        // length/name; Number intentionally has its static fields first.
        try defineDataAssumingNew(rt, constructor, "prototype", prototype_value, prototype_flags);
        prototype_value.free(rt);
    }

    // `installStandardConstructors` invokes this once per distinct global
    // constructor name, so the new-property precondition holds for bootstrap.
    // Other callers of `defineConstructor` are absent today (this entry
    // point is internal to bootstrap); add a duplicate-tolerant
    // wrapper here if that ever changes.
    try defineDataAssumingNew(rt, global, name, constructor_value, global_flags);
    return constructor_value;
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
        .internal_error,
        => true,
        else => false,
    };
}

fn nativeErrorKind(kind: ConstructorKind) ?core.context.NativeErrorKind {
    return switch (kind) {
        .error_ => .error_,
        .eval_error => .eval_error,
        .range_error => .range_error,
        .reference_error => .reference_error,
        .syntax_error => .syntax_error,
        .type_error => .type_error,
        .uri_error => .uri_error,
        .internal_error => .internal_error,
        .aggregate_error => .aggregate_error,
        .suppressed_error => .suppressed_error,
        else => null,
    };
}

fn expectObject(value: core.JSValue) *core.Object {
    const header = value.refHeader().?;
    return @fieldParentPtr("header", header);
}

fn installedConstructor(constructors: []const ?*core.Object, kind: ConstructorKind) ?*core.Object {
    return constructors[@intFromEnum(kind)];
}

fn constructorPrototypeObject(rt: *core.JSRuntime, ctor: *core.Object) ?*core.Object {
    _ = rt;
    if (ctor.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    return null;
}

fn materializeBuiltinNamespace(rt: *core.JSRuntime, global: *core.Object, kind: core.property.AutoInitKind) anyerror!?core.JSValue {
    return try materializeBuiltinNamespaceAutoInit(rt, global, kind);
}

/// Register exec's standard-globals installer as the process-wide default.
/// New bare `core.JSRuntime` instances copy this callback and capacity during
/// initialization without introducing a core -> exec dependency.
pub fn registerStandardGlobalsDefault() void {
    core.runtime.setDefaultStandardGlobalsInstaller(installStandardGlobals, standardGlobalOwnPropertyCapacity());
}

/// Configure an existing runtime for standard-global bootstrap. This is the
/// single setup interface for binding and test callers that already own a
/// runtime; it keeps the callback and its capacity invariant together.
pub fn configureRuntime(rt: *core.JSRuntime) void {
    registerStandardGlobalsDefault();
    rt.install_standard_globals_cb = installStandardGlobals;
    rt.standard_global_own_property_capacity = standardGlobalOwnPropertyCapacity();
}

/// Install one explicitly named standard constructor. The caller supplies the
/// domain-local function-list tables directly; installation order is expressed
/// by `installStandardConstructors`, not by a generic descriptor registry.
fn installStandardConstructor(
    rt: *core.JSRuntime,
    global: *core.Object,
    constructors: *[constructor_kind_count]?*core.Object,
    name: []const u8,
    kind: ConstructorKind,
    length: i32,
    static_methods: []const Method,
    prototype_methods: []const Method,
) !void {
    return installStandardConstructorWithPrototype(rt, global, constructors, name, kind, length, static_methods, prototype_methods, null);
}

fn installStandardConstructorWithPrototype(
    rt: *core.JSRuntime,
    global: *core.Object,
    constructors: *[constructor_kind_count]?*core.Object,
    name: []const u8,
    kind: ConstructorKind,
    length: i32,
    static_methods: []const Method,
    prototype_methods: []const Method,
    existing_prototype: ?*core.Object,
) !void {
    const function_proto = global.cachedFunctionProto(rt) orelse return error.InvalidBuiltinRegistry;
    const constructor_parent = if (isNativeErrorSubclassKind(kind))
        installedConstructor(constructors, .error_) orelse return error.InvalidBuiltinRegistry
    else if (isConcreteTypedArrayKind(kind))
        installedConstructor(constructors, .typed_array) orelse return error.InvalidBuiltinRegistry
    else
        function_proto;

    const prototype_parent: ?*core.Object = if (kind == .object)
        null
    else if (isNativeErrorSubclassKind(kind) or kind == .dom_exception) blk: {
        const error_ctor = installedConstructor(constructors, .error_) orelse return error.InvalidBuiltinRegistry;
        break :blk constructorPrototypeObject(rt, error_ctor) orelse return error.InvalidBuiltinRegistry;
    } else if (isConcreteTypedArrayKind(kind)) blk: {
        const typed_array_ctor = installedConstructor(constructors, .typed_array) orelse return error.InvalidBuiltinRegistry;
        break :blk constructorPrototypeObject(rt, typed_array_ctor) orelse return error.InvalidBuiltinRegistry;
    } else blk: {
        const object_ctor = installedConstructor(constructors, .object) orelse return error.InvalidBuiltinRegistry;
        break :blk constructorPrototypeObject(rt, object_ctor) orelse return error.InvalidBuiltinRegistry;
    };

    const constructor_value = try defineConstructor(
        rt,
        global,
        constructor_parent,
        prototype_parent,
        existing_prototype,
        name,
        kind,
        length,
        static_methods,
        prototype_methods,
    );
    defer constructor_value.free(rt);
    const constructor = expectObject(constructor_value);
    constructors[@intFromEnum(kind)] = constructor;

    if (constructorClassPrototypeId(kind)) |class_id| {
        const realm = rt.contextForGlobalIncludingConstructing(global) orelse return error.InvalidBuiltinRegistry;
        const prototype = constructorPrototypeObject(rt, constructor) orelse return error.InvalidBuiltinRegistry;
        try realm.setClassPrototype(class_id, prototype);
    }
    if (nativeErrorKind(kind)) |error_kind| {
        const realm = rt.contextForGlobalIncludingConstructing(global) orelse return error.InvalidBuiltinRegistry;
        const prototype = constructorPrototypeObject(rt, constructor) orelse return error.InvalidBuiltinRegistry;
        realm.setNativeErrorPrototype(error_kind, prototype);
    }

    // The constructor is fresh: static names cannot collide with the visible
    // length/name/prototype fields (Proxy has no prototype field).
    if (!constructorStaticMethodsBeforePrototype(kind)) try defineNativeMethodsAssumingNew(rt, constructor, static_methods);
    switch (kind) {
        .object => {
            const object_proto = constructorPrototypeObject(rt, constructor) orelse return error.InvalidBuiltinRegistry;
            const cached = try global.cachedRealmValueSlot(rt, .object_prototype);
            try global.setOptionalValueSlot(rt, cached, object_proto.value().dup());
            constructor.setNativeBuiltinIdAndRecord(rt, core.function.nativeBuiltinId(.object, @intFromEnum(object_builtin.ConstructorMethod.call)));
            try bindObjectStaticNativeRecords(rt, constructor);
            try bindObjectPrototypeNativeRecords(rt, constructor);
        },
        .symbol => {
            const symbol_proto = constructorPrototypeObject(rt, constructor) orelse return error.InvalidBuiltinRegistry;
            const cached = try global.cachedRealmValueSlot(rt, .symbol_prototype);
            try global.setOptionalValueSlot(rt, cached, symbol_proto.value().dup());
            constructor.setNativeBuiltinIdAndRecord(rt, core.function.nativeBuiltinId(.primitive, primitive_symbol_ctor_call_id));
            try installSymbolExtras(rt, global, constructor);
        },
        .boolean => {
            const boolean_proto = constructorPrototypeObject(rt, constructor) orelse return error.InvalidBuiltinRegistry;
            const cached = try global.cachedRealmValueSlot(rt, .boolean_prototype);
            try global.setOptionalValueSlot(rt, cached, boolean_proto.value().dup());
            constructor.setNativeBuiltinIdAndRecord(rt, core.function.nativeBuiltinId(.primitive, primitive_boolean_ctor_call_id));
        },
        .proxy => try bindNativeRecordByName(rt, constructor, "revocable", .reflect, @intFromEnum(reflect_builtin.StaticMethod.proxy_revocable)),
        .array => {
            (try constructor.arrayBuiltinMarkerSlot(rt)).* = .constructor;
            const array_proto = constructorPrototypeObject(rt, constructor) orelse return error.InvalidBuiltinRegistry;
            const cached = try global.cachedRealmValueSlot(rt, .array_prototype);
            try global.setOptionalValueSlot(rt, cached, array_proto.value().dup());
            try bindArrayNativeRecords(rt, constructor);
            try installArrayPrototypeSymbols(rt, global, constructor);
            try tagArrayPrototypeMethods(rt, constructor);
            try bindArrayPrototypeNativeRecords(rt, constructor);
            const values_key = (comptime core.atom.predefinedId("values", .string)) orelse return error.InvalidBuiltinRegistry;
            const values = try array_proto.getProperty(values_key);
            defer values.free(rt);
            const cached_values = try global.cachedRealmValueSlot(rt, .array_prototype_values);
            try global.setOptionalValueSlot(rt, cached_values, values.dup());
        },
        .string => {
            const string_proto = constructorPrototypeObject(rt, constructor) orelse return error.InvalidBuiltinRegistry;
            const cached = try global.cachedRealmValueSlot(rt, .string_prototype);
            try global.setOptionalValueSlot(rt, cached, string_proto.value().dup());
            constructor.setNativeBuiltinIdAndRecord(rt, core.function.nativeBuiltinId(.string, @intFromEnum(string_builtin.ConstructorMethod.call)));
            try installStringPrototypeAliases(rt, global, constructor);
            try bindStringNativeRecords(rt, constructor);
        },
        .number => {
            const number_proto = constructorPrototypeObject(rt, constructor) orelse return error.InvalidBuiltinRegistry;
            const cached = try global.cachedRealmValueSlot(rt, .number_prototype);
            try global.setOptionalValueSlot(rt, cached, number_proto.value().dup());
            try bindNumberNativeRecords(rt, constructor);
        },
        .bigint => {
            const bigint_proto = constructorPrototypeObject(rt, constructor) orelse return error.InvalidBuiltinRegistry;
            const cached = try global.cachedRealmValueSlot(rt, .bigint_prototype);
            try global.setOptionalValueSlot(rt, cached, bigint_proto.value().dup());
        },
        .regexp => {
            constructor.setNativeBuiltinIdAndRecord(rt, core.function.nativeBuiltinId(.regexp, @intFromEnum(regexp_builtin.ConstructorMethod.construct)));
            const cached = try global.cachedRealmValueSlot(rt, .regexp_constructor);
            try global.setOptionalValueSlot(rt, cached, constructor.value().dup());
            try installRegExpExtras(rt, global, constructor);
        },
        .promise => try installPromiseExtras(rt, global, constructor),
        .error_ => {
            try installErrorPrototypeExtras(rt, global, constructor);
            try bindNativeRecordByName(rt, constructor, "captureStackTrace", .error_object, @intFromEnum(error_builtin.StaticMethod.capture_stack_trace));
            try defineDataAssumingNew(rt, constructor, "stackTraceLimit", core.JSValue.int32(10), Flags{ .writable = true, .enumerable = false, .configurable = true });
        },
        .date => {
            try bindDateNativeRecords(rt, constructor);
            try installDatePrototypeAliases(rt, global, constructor);
        },
        .function => {
            try installFunctionPrototypeExtras(rt, global, constructor);
            try global.setCachedFunctionProto(rt, constructorPrototypeObject(rt, constructor));
        },
        .array_buffer => {
            constructor.setNativeBuiltinIdAndRecord(rt, core.function.nativeBuiltinId(.buffer, @intFromEnum(buffer_builtin.ConstructorMethod.array_buffer)));
            try installArrayBufferExtras(rt, global, constructor);
            try bindArrayBufferStaticNativeRecords(rt, constructor);
            try bindBufferPrototypeNativeRecords(rt, constructor, 1);
        },
        .shared_array_buffer => {
            constructor.setNativeBuiltinIdAndRecord(rt, core.function.nativeBuiltinId(.buffer, @intFromEnum(buffer_builtin.ConstructorMethod.shared_array_buffer)));
            try installSharedArrayBufferExtras(rt, global, constructor);
            try bindBufferPrototypeNativeRecords(rt, constructor, 2);
        },
        .data_view => try installDataViewExtras(rt, global, constructor),
        .iterator => try installIteratorExtras(rt, global, constructor),
        .dom_exception => {
            constructor.setNativeBuiltinIdAndRecord(rt, core.function.nativeBuiltinId(.host, @intFromEnum(core.function.HostGlobalMethod.dom_exception_ctor_call)));
            try installDOMExceptionExtras(rt, global, constructor);
        },
        .disposable_stack => try installDisposableStackExtras(rt, global, constructor),
        .async_disposable_stack => try installAsyncDisposableStackExtras(rt, global, constructor),
        else => {},
    }

    switch (kind) {
        .bigint, .promise, .weak_ref, .finalization_registry => try installPrototypeToStringTag(rt, global, name, constructor),
        else => {},
    }
    if (primitivePrototypeTagForKind(kind)) |tag| try bindPrimitivePrototypeNativeRecordsWithTag(rt, constructor, tag);
    if (typed_array_names.element(name)) |element| {
        try installTypedArrayElementSize(rt, constructor, @intCast(element.size), element.kind);
    }
    if (kind == .uint8_array) try installUint8ArrayCodecExtras(rt, global, constructor);
    if (collectionNameForKind(kind)) |collection_name| try installCollectionExtras(rt, global, collection_name, constructor);
}

fn installStandardConstructors(
    rt: *core.JSRuntime,
    global: *core.Object,
    constructors: *[constructor_kind_count]?*core.Object,
) !void {
    const realm = rt.contextForGlobalIncludingConstructing(global) orelse return error.InvalidBuiltinRegistry;

    // QuickJS basic-object bootstrap: Object.prototype exists first with a
    // null prototype, then Function.prototype is constructed as a true C
    // function inheriting from it. Only after both final objects exist do we
    // publish the Object and Function constructors.
    const object_proto_value = (try core.Object.createWithOwnPropertyCapacity(
        rt,
        core.class.ids.object,
        null,
        prototypeOwnPropertyCapacity(.object, object_prototype.len),
    )).value();
    defer object_proto_value.free(rt);
    const object_proto = expectObject(object_proto_value);

    const function_proto_value = try core.function.nativeFunctionWithPrototypeAndCapacity(
        realm,
        object_proto,
        "",
        0,
        prototypeOwnPropertyCapacity(.function, function_prototype.len),
    );
    defer function_proto_value.free(rt);
    const function_proto = expectObject(function_proto_value);
    try global.setCachedFunctionProto(rt, function_proto);

    try installStandardConstructorWithPrototype(rt, global, constructors, "Object", .object, 1, &object_static, &object_prototype, object_proto);
    try installStandardConstructorWithPrototype(rt, global, constructors, "Function", .function, 1, &no_methods, &function_prototype, function_proto);
    try installStandardConstructor(rt, global, constructors, "Array", .array, 1, &array_static, &array_prototype);
    try installStandardConstructor(rt, global, constructors, "String", .string, 1, &string_static, &string_prototype);
    try installStandardConstructor(rt, global, constructors, "Number", .number, 1, &number_static, &number_prototype);
    try installStandardConstructor(rt, global, constructors, "Boolean", .boolean, 1, &no_methods, &boolean_prototype);
    try installStandardConstructor(rt, global, constructors, "Symbol", .symbol, 0, &symbol_static, &symbol_prototype);
    try installStandardConstructor(rt, global, constructors, "BigInt", .bigint, 1, &bigint_static, &bigint_prototype);
    try installStandardConstructor(rt, global, constructors, "Date", .date, 7, &date_static, &date_prototype);
    try installStandardConstructor(rt, global, constructors, "RegExp", .regexp, 2, &no_methods, &regexp_prototype);
    try installStandardConstructor(rt, global, constructors, "Error", .error_, 1, &error_static, &error_prototype);
    try installStandardConstructor(rt, global, constructors, "EvalError", .eval_error, 1, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "RangeError", .range_error, 1, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "ReferenceError", .reference_error, 1, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "SyntaxError", .syntax_error, 1, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "TypeError", .type_error, 1, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "URIError", .uri_error, 1, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "InternalError", .internal_error, 1, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "AggregateError", .aggregate_error, 2, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "SuppressedError", .suppressed_error, 3, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "DOMException", .dom_exception, 2, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "DisposableStack", .disposable_stack, 0, &no_methods, &disposable_stack_prototype);
    try installStandardConstructor(rt, global, constructors, "AsyncDisposableStack", .async_disposable_stack, 0, &no_methods, &async_disposable_stack_prototype);
    try installStandardConstructor(rt, global, constructors, "Promise", .promise, 1, &promise_static, &promise_prototype);
    try installStandardConstructor(rt, global, constructors, "Map", .map, 0, &map_static, &map_prototype);
    try installStandardConstructor(rt, global, constructors, "Set", .set, 0, &no_methods, &set_prototype);
    try installStandardConstructor(rt, global, constructors, "WeakMap", .weak_map, 0, &no_methods, &weak_map_prototype);
    try installStandardConstructor(rt, global, constructors, "WeakSet", .weak_set, 0, &no_methods, &weak_set_prototype);
    try installStandardConstructor(rt, global, constructors, "WeakRef", .weak_ref, 1, &no_methods, &weak_ref_prototype);
    try installStandardConstructor(rt, global, constructors, "FinalizationRegistry", .finalization_registry, 1, &no_methods, &finalization_registry_prototype);
    try installStandardConstructor(rt, global, constructors, "ArrayBuffer", .array_buffer, 1, &array_buffer_static, &buffer_prototype);
    try installStandardConstructor(rt, global, constructors, "SharedArrayBuffer", .shared_array_buffer, 1, &no_methods, &shared_buffer_prototype);
    try installStandardConstructor(rt, global, constructors, "TypedArray", .typed_array, 0, &typed_array_static, &typed_array_prototype);
    try installStandardConstructor(rt, global, constructors, "Int8Array", .int8_array, 3, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "Uint8Array", .uint8_array, 3, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "Uint8ClampedArray", .uint8_clamped_array, 3, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "Int16Array", .int16_array, 3, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "Uint16Array", .uint16_array, 3, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "Int32Array", .int32_array, 3, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "Uint32Array", .uint32_array, 3, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "Float16Array", .float16_array, 3, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "Float32Array", .float32_array, 3, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "Float64Array", .float64_array, 3, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "BigInt64Array", .bigint64_array, 3, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "BigUint64Array", .biguint64_array, 3, &no_methods, &no_methods);
    try installStandardConstructor(rt, global, constructors, "DataView", .data_view, 1, &no_methods, &data_view_prototype);
    try installStandardConstructor(rt, global, constructors, "Proxy", .proxy, 2, &proxy_static, &no_methods);
    try installStandardConstructor(rt, global, constructors, "Iterator", .iterator, 0, &iterator_static, &iterator_prototype);

    for (constructors) |constructor| {
        if (constructor == null) return error.InvalidBuiltinRegistry;
    }
}

pub fn installStandardGlobals(rt: *core.JSRuntime, global: *core.Object) !void {
    // Keep the per-runtime + process-global installer hooks live for any later
    // runtime/realm built off this one, even when bootstrap reached us directly.
    configureRuntime(rt);
    rt.materialize_builtin_namespace_cb = materializeBuiltinNamespace;
    rt.internal_builtins = &internal_builtins.table;
    try global.reserveOwnPropertyCapacityAssumingPlain(rt, standardGlobalOwnPropertyCapacity());
    var installed_constructors: [constructor_kind_count]?*core.Object = @splat(null);
    try installStandardConstructors(rt, global, &installed_constructors);
    try finalizeStandardConstructorGraph(rt, global, &installed_constructors);
    const object_ctor = installedConstructor(&installed_constructors, .object) orelse return error.InvalidBuiltinRegistry;
    const object_proto = constructorPrototypeObject(rt, object_ctor) orelse return error.InvalidBuiltinRegistry;
    try global.setPrototype(rt, object_proto);

    try defineLazyNamespace(rt, global, "Math", .math_namespace);
    try defineLazyNamespace(rt, global, "JSON", .json_namespace);
    try defineLazyNamespace(rt, global, "Reflect", .reflect_namespace);
    try defineLazyNamespace(rt, global, "Atomics", .atomics_namespace);
    try installPerformance(rt, global);
    try installNavigator(rt, global);

    try defineGlobalLazyMethods(rt, global, global_function_methods[0..2]);
    const number_constructor = installedConstructor(&installed_constructors, .number) orelse return error.InvalidBuiltinRegistry;
    try installNumberParseAliases(rt, global, number_constructor);
    try defineGlobalLazyMethods(rt, global, global_function_methods[2..]);
    const array_ctor = installedConstructor(&installed_constructors, .array) orelse return error.InvalidBuiltinRegistry;
    const regexp_ctor = installedConstructor(&installed_constructors, .regexp) orelse return error.InvalidBuiltinRegistry;
    const array_proto = constructorPrototypeObject(rt, array_ctor) orelse return error.InvalidBuiltinRegistry;
    const regexp_proto = constructorPrototypeObject(rt, regexp_ctor) orelse return error.InvalidBuiltinRegistry;
    const ctx = rt.contextForGlobalIncludingConstructing(global) orelse return error.InvalidBuiltinRegistry;
    try ctx.initializeInitialShapes(object_proto, array_proto, regexp_proto);
    // Publish only after the intrinsic graph and realm-owned initial shapes are
    // complete. Indexed mutation of this Array prototype (or its matching
    // Object prototype) clears the marker permanently, as in QuickJS.
    array_proto.publishStandardArrayPrototype();
}

fn bindNumberGlobalNativeRecords(rt: *core.JSRuntime, global: *core.Object) !void {
    const number_mod = @import("number_ops.zig");
    const names = [_][]const u8{ "parseInt", "parseFloat", "isNaN", "isFinite" };
    for (names) |name| {
        const id = number_mod.staticMethodId(name) orelse continue;
        try bindNativeRecordByName(rt, global, name, .number, id);
    }
}

fn installNumberParseAliases(rt: *core.JSRuntime, global: *core.Object, number: *core.Object) !void {
    for ([_][]const u8{ "parseInt", "parseFloat" }) |name| {
        const key = try temporaryStringAtom(rt, name);
        defer freeTemporaryStringAtom(rt, key);
        try publishMethodAlias(rt, number, global, key, key, true);
    }
}

fn installNumberConstants(rt: *core.JSRuntime, number: *core.Object) !void {
    const flags = Flags{ .writable = false, .enumerable = false, .configurable = false };
    const constants = [_][]const u8{
        "MAX_VALUE",
        "MIN_VALUE",
        "NaN",
        "NEGATIVE_INFINITY",
        "POSITIVE_INFINITY",
        "EPSILON",
        "MAX_SAFE_INTEGER",
        "MIN_SAFE_INTEGER",
    };
    try number.reserveOwnPropertyCapacityAssumingPlain(rt, number.shape_ref.prop_count + constants.len);
    for (constants) |name| {
        const key = try temporaryStringAtom(rt, name);
        defer freeTemporaryStringAtom(rt, key);
        try defineDataAtomAssumingNew(rt, number, key, numberConstantValue(name) orelse return error.InvalidBuiltinRegistry, flags);
    }
}

fn numberConstantValue(name: []const u8) ?core.JSValue {
    if (std.mem.eql(u8, name, "NaN")) return core.JSValue.number(std.math.nan(f64));
    if (std.mem.eql(u8, name, "POSITIVE_INFINITY")) return core.JSValue.number(std.math.inf(f64));
    if (std.mem.eql(u8, name, "NEGATIVE_INFINITY")) return core.JSValue.number(-std.math.inf(f64));
    if (std.mem.eql(u8, name, "MAX_VALUE")) return core.JSValue.number(std.math.floatMax(f64));
    if (std.mem.eql(u8, name, "MIN_VALUE")) return core.JSValue.number(@as(f64, @bitCast(@as(u64, 1))));
    if (std.mem.eql(u8, name, "MAX_SAFE_INTEGER")) return core.JSValue.number(9007199254740991.0);
    if (std.mem.eql(u8, name, "MIN_SAFE_INTEGER")) return core.JSValue.number(-9007199254740991.0);
    if (std.mem.eql(u8, name, "EPSILON")) return core.JSValue.number(2.220446049250313e-16);
    return null;
}

fn finalizeStandardConstructorGraph(rt: *core.JSRuntime, global: *core.Object, constructors: []const ?*core.Object) !void {
    const object_ctor = installedConstructor(constructors, .object) orelse return error.InvalidBuiltinRegistry;
    const object_proto = constructorPrototypeObject(rt, object_ctor) orelse return error.InvalidBuiltinRegistry;
    object_proto.markImmutablePrototype();
    try installTypedArrayIntrinsicExtras(rt, global, constructors);
}

fn installTypedArrayIntrinsicExtras(rt: *core.JSRuntime, global: *core.Object, constructors: []const ?*core.Object) !void {
    const typed_array_ctor = installedConstructor(constructors, .typed_array) orelse return;
    try installTypedArraySpecies(rt, typed_array_ctor);
    try tagTypedArrayStaticMethods(rt, typed_array_ctor);
    const proto = constructorPrototypeObject(rt, typed_array_ctor) orelse return;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.shape_ref.prop_count + 8);
    const to_string_atom = core.atom.predefinedId("toString", .string).?;
    const array_proto_value = global.cachedRealmValue(rt, .array_prototype) orelse return error.InvalidBuiltinRegistry;
    if (!array_proto_value.isObject()) return error.InvalidBuiltinRegistry;
    const array_proto = expectObject(array_proto_value);
    try publishMethodAlias(rt, proto, array_proto, to_string_atom, to_string_atom, true);
    try defineNativeMethodsAssumingNewWithRealm(rt, proto, &typed_array_intrinsic_extra_methods, global);
    const values_atom = core.atom.predefinedId("values", .string).?;
    const iterator_atom = core.atom.predefinedId("Symbol.iterator", .symbol).?;
    try publishMethodAlias(rt, proto, proto, values_atom, iterator_atom, false);
    if (!try tagAutoInitArrayIteratorKindByAtom(rt, proto, values_atom, 2)) return error.InvalidBuiltinRegistry;
    if (!try tagAutoInitArrayIteratorKindByAtom(rt, proto, iterator_atom, 2)) return error.InvalidBuiltinRegistry;
    if (!try tagAutoInitTypedArrayBuiltinByAtom(rt, proto, values_atom, .prototype_method)) return error.InvalidBuiltinRegistry;
    if (!try tagAutoInitTypedArrayBuiltinByAtom(rt, proto, iterator_atom, .prototype_method)) return error.InvalidBuiltinRegistry;
    try tagArrayIteratorMethod(rt, proto, "keys", 1);
    try tagArrayIteratorMethod(rt, proto, "values", 2);
    try tagArrayIteratorMethod(rt, proto, "entries", 3);
    try installTypedArrayPrototypeAccessors(rt, global, proto);
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
        if (try tagAutoInitTypedArrayBuiltinByAtom(rt, ctor, key, tag.marker)) continue;
        const value = try ctor.getProperty(key);
        defer value.free(rt);
        if (!value.isObject()) continue;
        if (!try expectObject(value).addTypedArrayBuiltinMarker(rt, tag.marker)) return error.InvalidBuiltinRegistry;
    }
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
        .internal_error,
        => true,
        else => false,
    };
}

fn isConcreteTypedArrayKind(kind: ConstructorKind) bool {
    return switch (kind) {
        .int8_array,
        .uint8_array,
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
        => true,
        else => false,
    };
}

fn installMathConstants(rt: *core.JSRuntime, math: *core.Object) !void {
    const flags = Flags{ .writable = false, .enumerable = false, .configurable = false };
    try defineData(rt, math, "E", core.JSValue.float64(math_builtin.E), flags);
    try defineData(rt, math, "LN10", core.JSValue.float64(math_builtin.LN10), flags);
    try defineData(rt, math, "LN2", core.JSValue.float64(math_builtin.LN2), flags);
    try defineData(rt, math, "LOG2E", core.JSValue.float64(math_builtin.LOG2E), flags);
    try defineData(rt, math, "LOG10E", core.JSValue.float64(math_builtin.LOG10E), flags);
    try defineData(rt, math, "PI", core.JSValue.float64(math_builtin.PI), flags);
    try defineData(rt, math, "SQRT1_2", core.JSValue.float64(math_builtin.SQRT1_2), flags);
    try defineData(rt, math, "SQRT2", core.JSValue.float64(math_builtin.SQRT2), flags);
}

fn bindMathNativeRecords(rt: *core.JSRuntime, math: *core.Object) !void {
    for (math_builtin.internal_entries) |entry| {
        try bindNativeRecordByName(rt, math, entry.name, .math, entry.id);
    }
}

fn bindAtomicsNativeRecords(rt: *core.JSRuntime, atomics: *core.Object) !void {
    for (atomics_builtin.internal_entries) |entry| {
        try bindNativeRecordByName(rt, atomics, entry.name, .atomics, entry.id);
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
    for (uri_builtin.internal_entries) |entry| {
        try bindNativeRecordByName(rt, global, entry.name, .uri, entry.id);
    }
}

fn bindNumberNativeRecords(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const number_mod = @import("number_ops.zig");
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
    const string_mod = @import("string_builtin_ops.zig");
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

fn defineCollectionPrototypeMethodsAssumingNew(rt: *core.JSRuntime, global: *core.Object, proto: *core.Object, name: []const u8) !void {
    if (std.mem.eql(u8, name, "Map")) {
        try defineNativeMethodsAssumingNewWithRealm(rt, proto, map_prototype[0..7], global);
        try defineCollectionSizeAccessorAssumingNew(rt, global, proto, core.class.ids.map);
        try defineNativeMethodsAssumingNewWithRealm(rt, proto, map_prototype[7..], global);
    } else if (std.mem.eql(u8, name, "Set")) {
        try defineNativeMethodsAssumingNewWithRealm(rt, proto, set_prototype[0..4], global);
        try defineCollectionSizeAccessorAssumingNew(rt, global, proto, core.class.ids.set);
        try defineNativeMethodsAssumingNewWithRealm(rt, proto, set_prototype[4..], global);
    } else {
        try defineNativeMethodsAssumingNewWithRealm(rt, proto, collectionPrototypeMethods(name) orelse return error.InvalidBuiltinRegistry, global);
    }
}

fn defineCollectionSizeAccessorAssumingNew(rt: *core.JSRuntime, global: *core.Object, proto: *core.Object, owner_class: core.ClassId) !void {
    const size_atom = core.atom.predefinedId("size", .string).?;
    const native_id = core.function.nativeBuiltinId(.collection, @intFromEnum(collection_builtin.PrototypeMethod.size_getter));
    try defineLazyNativeGetterAtomWithRealm(rt, proto, size_atom, "get size", native_id, Flags{ .writable = false, .enumerable = false, .configurable = true }, global);
    if (!try tagAutoInitCollectionOwnerByAtom(rt, proto, size_atom, owner_class)) return error.InvalidBuiltinRegistry;
}

fn bindDateNativeRecords(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const date_mod = @import("date_ops.zig");
    ctor.setNativeBuiltinIdAndRecord(rt, core.function.nativeBuiltinId(.date, @intFromEnum(date_mod.ConstructorMethod.construct)));
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
    const array_mod = @import("array_builtin_ops.zig");
    for (array_static) |method| {
        const id = array_mod.staticMethodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, ctor, method.name, .array, id);
    }
}

fn bindArrayPrototypeNativeRecords(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return;
    const array_mod = @import("array_builtin_ops.zig");
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
    if (bindAutoInitNativeRecordByAtom(rt, object, key, native_id)) return;
    const value = try object.getProperty(key);
    defer value.free(rt);
    if (!value.isObject()) return;
    const function_object = expectObject(value);
    function_object.setNativeBuiltinIdAndRecord(rt, native_id);
}

fn bindAutoInitNativeRecordByAtom(_: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, native_id: i32) bool {
    if (object.hasExoticMethods()) return false;
    if (object.findProperty(atom_id)) |property_index| {
        const entry = &object.prop_values[property_index];
        switch (object.propKindAt(property_index)) {
            .auto_init => return standardAutoInitFacts(core.property.autoInit(entry.slot.auto_init)).native_builtin_id == native_id,
            else => return false,
        }
    }
    return false;
}

fn tagAutoInitArrayBuiltinByAtom(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, marker: core.property.ArrayBuiltinMarker) !bool {
    if (object.hasExoticMethods()) return false;
    if (object.findProperty(atom_id)) |property_index| {
        const entry = &object.prop_values[property_index];
        switch (object.propKindAt(property_index)) {
            .auto_init => return standardAutoInitFacts(core.property.autoInit(entry.slot.auto_init)).array_builtin_marker == marker,
            .data => {
                const value = entry.slot.data;
                if (!value.isObject()) return false;
                return try expectObject(value).addArrayBuiltinMarker(rt, marker);
            },
            .accessor => {
                const getter = entry.slot.accessor.getterValue();
                if (!getter.isObject()) return false;
                return try expectObject(getter).addArrayBuiltinMarker(rt, marker);
            },
            else => return false,
        }
    }
    return false;
}

fn tagAutoInitTypedArrayBuiltinByAtom(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, marker: core.property.TypedArrayBuiltinMarker) !bool {
    if (object.hasExoticMethods()) return false;
    if (object.findProperty(atom_id)) |property_index| {
        const entry = &object.prop_values[property_index];
        switch (object.propKindAt(property_index)) {
            .auto_init => return standardAutoInitFacts(core.property.autoInit(entry.slot.auto_init)).typed_array_builtin_marker == marker,
            .data => {
                const value = entry.slot.data;
                if (!value.isObject()) return false;
                return try expectObject(value).addTypedArrayBuiltinMarker(rt, marker);
            },
            else => return false,
        }
    }
    return false;
}

fn tagAutoInitArrayIteratorKindByAtom(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, kind: u8) !bool {
    if (object.hasExoticMethods()) return false;
    if (object.findProperty(atom_id)) |property_index| {
        const entry = &object.prop_values[property_index];
        switch (object.propKindAt(property_index)) {
            .auto_init => return standardAutoInitFacts(core.property.autoInit(entry.slot.auto_init)).array_iterator_kind == kind,
            .data => {
                const value = entry.slot.data;
                if (!value.isObject()) return false;
                return try expectObject(value).addArrayIteratorKind(rt, kind);
            },
            else => return false,
        }
    }
    return false;
}

fn tagAutoInitIteratorIdentityByAtom(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !bool {
    if (object.hasExoticMethods()) return false;
    if (object.findProperty(atom_id)) |property_index| {
        const entry = &object.prop_values[property_index];
        switch (object.propKindAt(property_index)) {
            .auto_init => return standardAutoInitFacts(core.property.autoInit(entry.slot.auto_init)).iterator_identity,
            .data => {
                const value = entry.slot.data;
                if (!value.isObject()) return false;
                return try expectObject(value).addIteratorIdentityFunction(rt);
            },
            else => return false,
        }
    }
    return false;
}

fn tagAutoInitCollectionOwnerByAtom(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, owner_class: core.ClassId) !bool {
    if (object.hasExoticMethods()) return false;
    if (object.findProperty(atom_id)) |property_index| {
        const entry = &object.prop_values[property_index];
        switch (object.propKindAt(property_index)) {
            .auto_init => return standardAutoInitFacts(core.property.autoInit(entry.slot.auto_init)).collection_method_owner_class == owner_class,
            .data => {
                const value = entry.slot.data;
                if (!value.isObject()) return false;
                return try expectObject(value).addCollectionMethodOwnerClass(rt, owner_class);
            },
            .accessor => {
                const getter = entry.slot.accessor.getterValue();
                if (!getter.isObject()) return false;
                return try expectObject(getter).addCollectionMethodOwnerClass(rt, owner_class);
            },
            else => return false,
        }
    }
    return false;
}

fn tagAutoInitDisposableStackMethodByAtom(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, method_id: u8) !bool {
    if (object.hasExoticMethods()) return false;
    if (object.findProperty(atom_id)) |property_index| {
        const entry = &object.prop_values[property_index];
        switch (object.propKindAt(property_index)) {
            .auto_init => return standardAutoInitFacts(core.property.autoInit(entry.slot.auto_init)).disposable_stack_method == method_id,
            .data => {
                const value = entry.slot.data;
                if (!value.isObject()) return false;
                return try expectObject(value).addDisposableStackMethod(rt, method_id);
            },
            .accessor => {
                const getter = entry.slot.accessor.getterValue();
                if (!getter.isObject()) return false;
                return try expectObject(getter).addDisposableStackMethod(rt, method_id);
            },
            else => return false,
        }
    }
    return false;
}

fn tagAutoInitAsyncDisposableStackMethodByAtom(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, method_id: u8) !bool {
    if (object.hasExoticMethods()) return false;
    if (object.findProperty(atom_id)) |property_index| {
        const entry = &object.prop_values[property_index];
        switch (object.propKindAt(property_index)) {
            .auto_init => return standardAutoInitFacts(core.property.autoInit(entry.slot.auto_init)).async_disposable_stack_method == method_id,
            .data => {
                const value = entry.slot.data;
                if (!value.isObject()) return false;
                return try expectObject(value).addAsyncDisposableStackMethod(rt, method_id);
            },
            .accessor => {
                const getter = entry.slot.accessor.getterValue();
                if (!getter.isObject()) return false;
                return try expectObject(getter).addAsyncDisposableStackMethod(rt, method_id);
            },
            else => return false,
        }
    }
    return false;
}

fn installTypedArrayElementSize(rt: *core.JSRuntime, ctor: *core.Object, size: i32, kind: u8) !void {
    ctor.typedArrayElementSizeSlot().* = @intCast(size);
    ctor.typedArrayKindSlot().* = kind;
    const bytes_key = core.atom.predefinedId("BYTES_PER_ELEMENT", .string).?;
    if (!ctor.hasOwnProperty(bytes_key)) {
        try installTypedArrayConstructorElementSize(rt, ctor, size);
    }
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.shape_ref.prop_count + 1);
    try defineDataAtomAssumingNew(rt, proto, bytes_key, core.JSValue.int32(size), Flags{ .writable = false, .enumerable = false, .configurable = false });
}

fn installTypedArrayConstructorElementSize(rt: *core.JSRuntime, ctor: *core.Object, size: i32) !void {
    const bytes_key = core.atom.predefinedId("BYTES_PER_ELEMENT", .string).?;
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.shape_ref.prop_count + 1);
    try defineDataAtomAssumingNew(rt, ctor, bytes_key, core.JSValue.int32(size), Flags{ .writable = false, .enumerable = false, .configurable = false });
}

fn installUint8ArrayConstructorCodecExtras(rt: *core.JSRuntime, ctor: *core.Object) !void {
    try defineNativeMethodsAssumingNew(rt, ctor, &uint8_array_constructor_codec_methods);
}

fn installUint8ArrayCodecExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const from_base64_atom = try temporaryStringAtom(rt, "fromBase64");
    defer freeTemporaryStringAtom(rt, from_base64_atom);
    if (!ctor.hasOwnProperty(from_base64_atom)) {
        try installUint8ArrayConstructorCodecExtras(rt, ctor);
    }

    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try defineNativeMethodsAssumingNewWithRealm(rt, proto, &uint8_array_prototype_codec_methods, global);
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
        const typed_array_marker_deferred = try tagAutoInitTypedArrayBuiltinByAtom(rt, proto, key, .prototype_method);
        const array_marker_deferred = if (std.mem.eql(u8, name, "toString"))
            try tagAutoInitArrayBuiltinByAtom(rt, proto, key, .to_string)
        else if (std.mem.eql(u8, name, "toLocaleString"))
            try tagAutoInitArrayBuiltinByAtom(rt, proto, key, .to_locale_string)
        else
            true;
        if (typed_array_marker_deferred and array_marker_deferred) continue;
        const value = try proto.getProperty(key);
        defer value.free(rt);
        if (value.isObject()) {
            const object = expectObject(value);
            if (!typed_array_marker_deferred) {
                if (!try object.addTypedArrayBuiltinMarker(rt, .prototype_method)) return error.InvalidBuiltinRegistry;
            }
            if (std.mem.eql(u8, name, "toString") and !array_marker_deferred) {
                if (!try object.addArrayBuiltinMarker(rt, .to_string)) return error.InvalidBuiltinRegistry;
            } else if (std.mem.eql(u8, name, "toLocaleString") and !array_marker_deferred) {
                if (!try object.addArrayBuiltinMarker(rt, .to_locale_string)) return error.InvalidBuiltinRegistry;
            }
        }
    }
}

fn installTypedArrayPrototypeAccessors(rt: *core.JSRuntime, global: *core.Object, proto: *core.Object) !void {
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
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.shape_ref.prop_count + accessors.len + 1);
    for (accessors) |accessor| {
        const native_id = if (buffer_builtin.typedArrayAccessorMethodId(accessor.property_name)) |id|
            core.function.nativeBuiltinId(.buffer, id)
        else
            0;
        const key = core.atom.predefinedId(accessor.property_name, .string) orelse return error.InvalidBuiltinRegistry;
        try defineLazyNativeGetterAtomWithRealm(rt, proto, key, accessor.getter_name, native_id, flags, global);
    }

    const tag_native_id = if (buffer_builtin.typedArrayAccessorMethodId("[Symbol.toStringTag]")) |id|
        core.function.nativeBuiltinId(.buffer, id)
    else
        0;
    try defineLazyNativeGetterAtomWithRealm(rt, proto, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, "get [Symbol.toStringTag]", tag_native_id, flags, global);
}

// Object's constructor properties mirror QuickJS `js_object_funcs` order. The
// record ids still live in `object_builtin.internal_entries`; this list is only
// the visible property installation order.
const object_static = preparedMethods([_]Method{
    .{ .name = "create", .length = 2 },
    .{ .name = "getPrototypeOf", .length = 1 },
    .{ .name = "setPrototypeOf", .length = 2 },
    .{ .name = "defineProperty", .length = 3 },
    .{ .name = "defineProperties", .length = 2 },
    .{ .name = "getOwnPropertyNames", .length = 1 },
    .{ .name = "getOwnPropertySymbols", .length = 1 },
    .{ .name = "groupBy", .length = 2 },
    .{ .name = "keys", .length = 1 },
    .{ .name = "values", .length = 1 },
    .{ .name = "entries", .length = 1 },
    .{ .name = "isExtensible", .length = 1 },
    .{ .name = "preventExtensions", .length = 1 },
    .{ .name = "getOwnPropertyDescriptor", .length = 2 },
    .{ .name = "getOwnPropertyDescriptors", .length = 1 },
    .{ .name = "is", .length = 2 },
    .{ .name = "assign", .length = 2 },
    .{ .name = "seal", .length = 1 },
    .{ .name = "freeze", .length = 1 },
    .{ .name = "isSealed", .length = 1 },
    .{ .name = "isFrozen", .length = 1 },
    .{ .name = "fromEntries", .length = 1 },
    .{ .name = "hasOwn", .length = 2 },
});

const object_prototype = methodsFromInternalEntriesWhere(&object_builtin.internal_entries, struct {
    fn keep(id: u32) bool {
        return object_builtin.prototypeMethodOrdinal(id) != null;
    }
}.keep);

const function_prototype = preparedMethods([_]Method{
    .{ .name = "call", .length = 1 },
    .{ .name = "apply", .length = 2 },
    .{ .name = "bind", .length = 1 },
    .{ .name = "toString", .length = 0 },
});

const array_static = preparedMethods([_]Method{
    .{ .name = "isArray", .length = 1 },
    .{ .name = "from", .length = 1 },
    .{ .name = "of", .length = 0 },
    .{ .name = "fromAsync", .length = 1 },
});

const array_prototype = preparedMethods([_]Method{
    .{ .name = "at", .length = 1 },
    .{ .name = "with", .length = 2 },
    .{ .name = "concat", .length = 1 },
    .{ .name = "every", .length = 1 },
    .{ .name = "some", .length = 1 },
    .{ .name = "forEach", .length = 1 },
    .{ .name = "map", .length = 1 },
    .{ .name = "filter", .length = 1 },
    .{ .name = "reduce", .length = 1 },
    .{ .name = "reduceRight", .length = 1 },
    .{ .name = "fill", .length = 1 },
    .{ .name = "find", .length = 1 },
    .{ .name = "findIndex", .length = 1 },
    .{ .name = "findLast", .length = 1 },
    .{ .name = "findLastIndex", .length = 1 },
    .{ .name = "indexOf", .length = 1 },
    .{ .name = "lastIndexOf", .length = 1 },
    .{ .name = "includes", .length = 1 },
    .{ .name = "join", .length = 1 },
    .{ .name = "toString", .length = 0 },
    .{ .name = "toLocaleString", .length = 0 },
    .{ .name = "pop", .length = 0 },
    .{ .name = "push", .length = 1 },
    .{ .name = "shift", .length = 0 },
    .{ .name = "unshift", .length = 1 },
    .{ .name = "reverse", .length = 0 },
    .{ .name = "toReversed", .length = 0 },
    .{ .name = "sort", .length = 1 },
    .{ .name = "toSorted", .length = 1 },
    .{ .name = "slice", .length = 2 },
    .{ .name = "splice", .length = 2 },
    .{ .name = "toSpliced", .length = 2 },
    .{ .name = "copyWithin", .length = 2 },
    .{ .name = "flatMap", .length = 1 },
    .{ .name = "flat", .length = 0 },
    .{ .name = "values", .length = 0 },
    .{ .name = "keys", .length = 0 },
    .{ .name = "entries", .length = 0 },
});

/// %TypedArray%.prototype method surface — mirrors
/// js_typed_array_base_proto_funcs (quickjs.c:59765). Unlike Array.prototype
/// there is no push/pop/shift/unshift/splice/concat/flat/flatMap/toSpliced:
/// neither the spec nor qjs installs the Array-only length-mutating and
/// nesting methods on the %TypedArray% prototype.
const typed_array_prototype = preparedMethods([_]Method{
    .{ .name = "toString", .length = 0 },
    .{ .name = "toLocaleString", .length = 0 },
    .{ .name = "map", .length = 1 },
    .{ .name = "filter", .length = 1 },
    .{ .name = "reduce", .length = 1 },
    .{ .name = "reduceRight", .length = 1 },
    .{ .name = "forEach", .length = 1 },
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
    .{ .name = "join", .length = 1 },
    .{ .name = "reverse", .length = 0 },
    .{ .name = "sort", .length = 1 },
    .{ .name = "toReversed", .length = 0 },
    .{ .name = "toSorted", .length = 1 },
    .{ .name = "with", .length = 2 },
    .{ .name = "keys", .length = 0 },
    .{ .name = "values", .length = 0 },
    .{ .name = "entries", .length = 0 },
});

const typed_array_intrinsic_extra_methods = preparedMethods([_]Method{
    .{ .name = "set", .length = 1 },
    .{ .name = "subarray", .length = 2 },
});

const uint8_array_constructor_codec_methods = preparedMethods([_]Method{
    .{ .name = "fromBase64", .length = 1 },
    .{ .name = "fromHex", .length = 1 },
});

const uint8_array_prototype_codec_methods = preparedMethods([_]Method{
    .{ .name = "toBase64", .length = 0 },
    .{ .name = "toHex", .length = 0 },
    .{ .name = "setFromBase64", .length = 1 },
    .{ .name = "setFromHex", .length = 1 },
});

const string_static = preparedMethods([_]Method{
    .{ .name = "fromCharCode", .length = 1 },
    .{ .name = "fromCodePoint", .length = 1 },
    .{ .name = "raw", .length = 1 },
});

const string_prototype = preparedMethods([_]Method{
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
});

const number_static = preparedMethods([_]Method{
    .{ .name = "parseInt", .length = 2 },
    .{ .name = "parseFloat", .length = 1 },
    .{ .name = "isNaN", .length = 1 },
    .{ .name = "isFinite", .length = 1 },
    .{ .name = "isInteger", .length = 1 },
    .{ .name = "isSafeInteger", .length = 1 },
});

const bigint_static = preparedMethods([_]Method{
    .{ .name = "asIntN", .length = 2 },
    .{ .name = "asUintN", .length = 2 },
});

const typed_array_static = preparedMethods([_]Method{
    .{ .name = "from", .length = 1 },
    .{ .name = "of", .length = 0 },
});

const no_methods = preparedMethods([_]Method{});

const proxy_static = preparedMethods([_]Method{
    .{ .name = "revocable", .length = 2 },
});

const number_prototype = preparedMethods([_]Method{
    .{ .name = "toExponential", .length = 1 },
    .{ .name = "toFixed", .length = 1 },
    .{ .name = "toPrecision", .length = 1 },
    .{ .name = "toString", .length = 1 },
    .{ .name = "toLocaleString", .length = 0 },
    .{ .name = "valueOf", .length = 0 },
});

const boolean_prototype = preparedMethods([_]Method{
    .{ .name = "toString", .length = 0, .native_builtin_id = core.function.nativeBuiltinId(.primitive, 21) },
    .{ .name = "valueOf", .length = 0, .native_builtin_id = core.function.nativeBuiltinId(.primitive, 22) },
});

const bigint_prototype = preparedMethods([_]Method{
    .{ .name = "toString", .length = 0, .native_builtin_id = core.function.nativeBuiltinId(.primitive, 31) },
    .{ .name = "valueOf", .length = 0, .native_builtin_id = core.function.nativeBuiltinId(.primitive, 32) },
});

const symbol_prototype = preparedMethods([_]Method{
    .{ .name = "toString", .length = 0, .native_builtin_id = core.function.nativeBuiltinId(.primitive, 41) },
    .{ .name = "valueOf", .length = 0, .native_builtin_id = core.function.nativeBuiltinId(.primitive, 42) },
});

const error_prototype = preparedMethods([_]Method{
    .{ .name = "toString", .length = 0 },
});

const symbol_static = preparedMethods([_]Method{
    .{ .name = "for", .length = 1 },
    .{ .name = "keyFor", .length = 1 },
});

const date_static = preparedMethods([_]Method{
    .{ .name = "now", .length = 0 },
    .{ .name = "parse", .length = 1 },
    .{ .name = "UTC", .length = 7 },
});

const date_prototype = preparedMethods([_]Method{
    .{ .name = "valueOf", .length = 0 },
    .{ .name = "toString", .length = 0 },
    .{ .name = "toUTCString", .length = 0 },
    .{ .name = "toISOString", .length = 0 },
    .{ .name = "toDateString", .length = 0 },
    .{ .name = "toTimeString", .length = 0 },
    .{ .name = "toLocaleString", .length = 0 },
    .{ .name = "toLocaleDateString", .length = 0 },
    .{ .name = "toLocaleTimeString", .length = 0 },
    .{ .name = "getTimezoneOffset", .length = 0 },
    .{ .name = "getTime", .length = 0 },
    .{ .name = "getYear", .length = 0 },
    .{ .name = "getFullYear", .length = 0 },
    .{ .name = "getUTCFullYear", .length = 0 },
    .{ .name = "getMonth", .length = 0 },
    .{ .name = "getUTCMonth", .length = 0 },
    .{ .name = "getDate", .length = 0 },
    .{ .name = "getUTCDate", .length = 0 },
    .{ .name = "getHours", .length = 0 },
    .{ .name = "getUTCHours", .length = 0 },
    .{ .name = "getMinutes", .length = 0 },
    .{ .name = "getUTCMinutes", .length = 0 },
    .{ .name = "getSeconds", .length = 0 },
    .{ .name = "getUTCSeconds", .length = 0 },
    .{ .name = "getMilliseconds", .length = 0 },
    .{ .name = "getUTCMilliseconds", .length = 0 },
    .{ .name = "getDay", .length = 0 },
    .{ .name = "getUTCDay", .length = 0 },
    .{ .name = "setTime", .length = 1 },
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
    .{ .name = "setYear", .length = 1 },
    .{ .name = "setFullYear", .length = 3 },
    .{ .name = "setUTCFullYear", .length = 3 },
    .{ .name = "toJSON", .length = 1 },
});

const regexp_prototype = preparedMethods([_]Method{
    .{ .name = "compile", .length = 2 },
    .{ .name = "exec", .length = 1 },
    .{ .name = "test", .length = 1 },
    .{ .name = "toString", .length = 0 },
});

const promise_static = preparedMethods([_]Method{
    .{ .name = "resolve", .length = 1 },
    .{ .name = "reject", .length = 1 },
    .{ .name = "all", .length = 1 },
    .{ .name = "allKeyed", .length = 1 },
    .{ .name = "allSettled", .length = 1 },
    .{ .name = "allSettledKeyed", .length = 1 },
    .{ .name = "any", .length = 1 },
    .{ .name = "try", .length = 1 },
    .{ .name = "race", .length = 1 },
    .{ .name = "withResolvers", .length = 0 },
});

const promise_prototype = preparedMethods([_]Method{
    .{ .name = "then", .length = 2 },
    .{ .name = "catch", .length = 1 },
    .{ .name = "finally", .length = 1 },
});

const error_static = preparedMethods([_]Method{
    .{ .name = "captureStackTrace", .length = 1 },
    .{ .name = "isError", .length = 1 },
});

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

const map_static = preparedMethods([_]Method{
    .{ .name = "groupBy", .length = 2 },
});

const map_prototype = preparedMethods([_]Method{
    .{ .name = "set", .length = 2 },
    .{ .name = "get", .length = 1 },
    .{ .name = "getOrInsert", .length = 2 },
    .{ .name = "getOrInsertComputed", .length = 2 },
    .{ .name = "has", .length = 1 },
    .{ .name = "delete", .length = 1 },
    .{ .name = "clear", .length = 0 },
    .{ .name = "forEach", .length = 1 },
    .{ .name = "values", .length = 0 },
    .{ .name = "keys", .length = 0 },
    .{ .name = "entries", .length = 0 },
});

const weak_map_prototype = preparedMethods([_]Method{
    .{ .name = "set", .length = 2 },
    .{ .name = "get", .length = 1 },
    .{ .name = "getOrInsert", .length = 2 },
    .{ .name = "getOrInsertComputed", .length = 2 },
    .{ .name = "has", .length = 1 },
    .{ .name = "delete", .length = 1 },
});

const set_prototype = preparedMethods([_]Method{
    .{ .name = "add", .length = 1 },
    .{ .name = "has", .length = 1 },
    .{ .name = "delete", .length = 1 },
    .{ .name = "clear", .length = 0 },
    .{ .name = "forEach", .length = 1 },
    .{ .name = "isDisjointFrom", .length = 1 },
    .{ .name = "isSubsetOf", .length = 1 },
    .{ .name = "isSupersetOf", .length = 1 },
    .{ .name = "intersection", .length = 1 },
    .{ .name = "difference", .length = 1 },
    .{ .name = "symmetricDifference", .length = 1 },
    .{ .name = "union", .length = 1 },
    .{ .name = "values", .length = 0 },
    .{ .name = "keys", .length = 0 },
    .{ .name = "entries", .length = 0 },
});

const weak_set_prototype = preparedMethods([_]Method{
    .{ .name = "add", .length = 1 },
    .{ .name = "has", .length = 1 },
    .{ .name = "delete", .length = 1 },
});

const weak_ref_prototype = preparedMethods([_]Method{
    .{ .name = "deref", .length = 0 },
});

const finalization_registry_prototype = preparedMethods([_]Method{
    .{ .name = "register", .length = 2 },
    .{ .name = "unregister", .length = 1 },
});

const disposable_stack_prototype = preparedMethods([_]Method{
    .{ .name = "use", .length = 1 },
    .{ .name = "adopt", .length = 2 },
    .{ .name = "defer", .length = 1 },
    .{ .name = "dispose", .length = 0 },
    .{ .name = "move", .length = 0 },
});

const async_disposable_stack_prototype = preparedMethods([_]Method{
    .{ .name = "use", .length = 1 },
    .{ .name = "adopt", .length = 2 },
    .{ .name = "defer", .length = 1 },
    .{ .name = "disposeAsync", .length = 0 },
    .{ .name = "move", .length = 0 },
});

const buffer_prototype = preparedMethods([_]Method{
    .{ .name = "resize", .length = 1 },
    .{ .name = "slice", .length = 2 },
    .{ .name = "sliceToImmutable", .length = 2 },
    .{ .name = "transfer", .length = 0 },
    .{ .name = "transferToFixedLength", .length = 0 },
    .{ .name = "transferToImmutable", .length = 0 },
});

const shared_buffer_prototype = preparedMethods([_]Method{
    .{ .name = "grow", .length = 1 },
    .{ .name = "slice", .length = 2 },
});

const array_buffer_static = preparedMethods([_]Method{
    .{ .name = "isView", .length = 1 },
});

const data_view_prototype = preparedMethods([_]Method{
    .{ .name = "getInt8", .length = 1 },
    .{ .name = "getUint8", .length = 1 },
    .{ .name = "getInt16", .length = 1 },
    .{ .name = "getUint16", .length = 1 },
    .{ .name = "getInt32", .length = 1 },
    .{ .name = "getUint32", .length = 1 },
    .{ .name = "getBigInt64", .length = 1 },
    .{ .name = "getBigUint64", .length = 1 },
    .{ .name = "getFloat16", .length = 1 },
    .{ .name = "getFloat32", .length = 1 },
    .{ .name = "getFloat64", .length = 1 },
    .{ .name = "setInt8", .length = 2 },
    .{ .name = "setUint8", .length = 2 },
    .{ .name = "setInt16", .length = 2 },
    .{ .name = "setUint16", .length = 2 },
    .{ .name = "setInt32", .length = 2 },
    .{ .name = "setUint32", .length = 2 },
    .{ .name = "setBigInt64", .length = 2 },
    .{ .name = "setBigUint64", .length = 2 },
    .{ .name = "setFloat16", .length = 2 },
    .{ .name = "setFloat32", .length = 2 },
    .{ .name = "setFloat64", .length = 2 },
});

const iterator_static = preparedMethods([_]Method{
    .{ .name = "concat", .length = 0 },
    .{ .name = "from", .length = 1 },
    .{ .name = "zip", .length = 1 },
    .{ .name = "zipKeyed", .length = 1 },
});

const iterator_prototype = preparedMethods([_]Method{
    .{ .name = "drop", .length = 1 },
    .{ .name = "filter", .length = 1 },
    .{ .name = "flatMap", .length = 1 },
    .{ .name = "map", .length = 1 },
    .{ .name = "take", .length = 1 },
    .{ .name = "every", .length = 1 },
    .{ .name = "find", .length = 1 },
    .{ .name = "forEach", .length = 1 },
    .{ .name = "some", .length = 1 },
    .{ .name = "reduce", .length = 1 },
    .{ .name = "toArray", .length = 0 },
});

const iterator_identity_method = Method{
    .name = "[Symbol.iterator]",
    .length = 0,
    .iterator_identity = true,
};

// Math/JSON method declarations live with their implementations
// (math.zig/json.zig `internal_entries`); these derived views keep the
// generic namespace-creation machinery working unchanged.
const math_methods = methodsFromInternalEntries(&math_builtin.internal_entries);

const json_methods = methodsFromInternalEntries(&json_builtin.internal_entries);

fn methodsFromInternalEntries(comptime entries: []const core.host_function.InternalEntry) [entries.len]Method {
    var methods: [entries.len]Method = undefined;
    for (entries, 0..) |entry, index| {
        methods[index] = .{
            .name = entry.name,
            .length = entry.length,
            .prepare_native_function = prepareStandardAutoInitNativeFunction,
        };
    }
    return methods;
}

/// Derive an install Method table from the subset of `entries` whose id matches
/// `keep`, preserving declaration order. Used to partition a single internal
/// entry table (e.g. Object's) into its static and prototype install lists.
fn methodsFromInternalEntriesWhere(
    comptime entries: []const core.host_function.InternalEntry,
    comptime keep: fn (id: u32) bool,
) [countInternalEntriesWhere(entries, keep)]Method {
    var methods: [countInternalEntriesWhere(entries, keep)]Method = undefined;
    var index: usize = 0;
    for (entries) |entry| {
        if (!keep(entry.id)) continue;
        methods[index] = .{
            .name = entry.name,
            .length = entry.length,
            .prepare_native_function = prepareStandardAutoInitNativeFunction,
        };
        index += 1;
    }
    return methods;
}

fn countInternalEntriesWhere(
    comptime entries: []const core.host_function.InternalEntry,
    comptime keep: fn (id: u32) bool,
) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (keep(entry.id)) count += 1;
    }
    return count;
}

const reflect_methods = preparedMethods([_]Method{
    .{ .name = "apply", .length = 3 },
    .{ .name = "construct", .length = 2 },
    .{ .name = "defineProperty", .length = 3 },
    .{ .name = "deleteProperty", .length = 2 },
    .{ .name = "get", .length = 2 },
    .{ .name = "getOwnPropertyDescriptor", .length = 2 },
    .{ .name = "getPrototypeOf", .length = 1 },
    .{ .name = "has", .length = 2 },
    .{ .name = "isExtensible", .length = 1 },
    .{ .name = "ownKeys", .length = 1 },
    .{ .name = "preventExtensions", .length = 1 },
    .{ .name = "set", .length = 3 },
    .{ .name = "setPrototypeOf", .length = 2 },
});

const atomics_methods = preparedMethods([_]Method{
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
});

const performance_methods = preparedMethods([_]Method{
    .{ .name = "now", .length = 0 },
});

const StandardAutoInitFacts = struct {
    native_builtin_id: i32 = 0,
    array_builtin_marker: core.property.ArrayBuiltinMarker = .none,
    typed_array_builtin_marker: core.property.TypedArrayBuiltinMarker = .none,
    array_iterator_kind: u8 = 0,
    iterator_identity: bool = false,
    collection_method_owner_class: core.ClassId = core.class.invalid_class_id,
    disposable_stack_method: u8 = 0,
    async_disposable_stack_method: u8 = 0,
};

fn descriptorIn(info: *const core.property.AutoInit, methods: []const Method) bool {
    for (methods) |*method| if (method == info) return true;
    return false;
}

fn internalEntryId(entries: []const core.host_function.InternalEntry, name: []const u8) ?u32 {
    for (entries) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.id;
    return null;
}

fn standardAutoInitFacts(info: *const core.property.AutoInit) StandardAutoInitFacts {
    var facts = StandardAutoInitFacts{
        .native_builtin_id = info.native_builtin_id,
        .array_builtin_marker = info.array_builtin_marker,
        .typed_array_builtin_marker = info.typed_array_builtin_marker,
        .array_iterator_kind = info.array_iterator_kind,
        .iterator_identity = info.iterator_identity,
        .collection_method_owner_class = info.collection_method_owner_class,
        .disposable_stack_method = info.disposable_stack_method,
        .async_disposable_stack_method = info.async_disposable_stack_method,
    };

    const name = info.name;
    if (descriptorIn(info, &object_static)) {
        if (object_builtin.staticMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.object, id);
    } else if (descriptorIn(info, &object_prototype)) {
        if (object_builtin.prototypeMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.object, id);
    } else if (descriptorIn(info, &function_prototype)) {
        const id: ?u32 = if (std.mem.eql(u8, name, "call"))
            @intFromEnum(function_ops.PrototypeMethod.call)
        else if (std.mem.eql(u8, name, "apply"))
            @intFromEnum(function_ops.PrototypeMethod.apply)
        else if (std.mem.eql(u8, name, "bind"))
            @intFromEnum(function_ops.PrototypeMethod.bind)
        else if (std.mem.eql(u8, name, "toString"))
            @intFromEnum(function_ops.PrototypeMethod.to_string)
        else
            null;
        if (id) |method_id| facts.native_builtin_id = core.function.nativeBuiltinId(.function, method_id);
    } else if (descriptorIn(info, &array_static)) {
        if (array_builtin.staticMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.array, id);
    } else if (descriptorIn(info, &array_prototype)) {
        if (array_builtin.prototypeMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.array, id);
        if (std.mem.eql(u8, name, "toString")) facts.array_builtin_marker = .to_string;
        if (std.mem.eql(u8, name, "toLocaleString")) facts.array_builtin_marker = .to_locale_string;
        if (std.mem.eql(u8, name, "concat")) facts.array_builtin_marker = .concat;
        if (std.mem.eql(u8, name, "keys")) facts.array_iterator_kind = 1;
        if (std.mem.eql(u8, name, "values")) facts.array_iterator_kind = 2;
        if (std.mem.eql(u8, name, "entries")) facts.array_iterator_kind = 3;
    } else if (descriptorIn(info, &typed_array_static)) {
        if (std.mem.eql(u8, name, "from")) facts.typed_array_builtin_marker = .static_from;
        if (std.mem.eql(u8, name, "of")) facts.typed_array_builtin_marker = .static_of;
    } else if (descriptorIn(info, &typed_array_prototype) or descriptorIn(info, &typed_array_intrinsic_extra_methods)) {
        facts.typed_array_builtin_marker = .prototype_method;
        if (std.mem.eql(u8, name, "toString")) facts.array_builtin_marker = .to_string;
        if (std.mem.eql(u8, name, "toLocaleString")) facts.array_builtin_marker = .to_locale_string;
        if (std.mem.eql(u8, name, "keys")) facts.array_iterator_kind = 1;
        if (std.mem.eql(u8, name, "values")) facts.array_iterator_kind = 2;
        if (std.mem.eql(u8, name, "entries")) facts.array_iterator_kind = 3;
    } else if (descriptorIn(info, &string_static)) {
        if (string_builtin.staticMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.string, id);
    } else if (descriptorIn(info, &string_prototype)) {
        if (string_builtin.prototypeMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.string, id);
    } else if (descriptorIn(info, &number_static)) {
        if (number_builtin.staticMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.number, id);
    } else if (descriptorIn(info, &number_prototype)) {
        if (number_builtin.prototypeMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.number, id);
        if (std.mem.eql(u8, name, "valueOf")) facts.native_builtin_id = core.function.nativeBuiltinId(.primitive, 12);
    } else if (descriptorIn(info, &proxy_static)) {
        facts.native_builtin_id = core.function.nativeBuiltinId(.reflect, @intFromEnum(reflect_builtin.StaticMethod.proxy_revocable));
    } else if (descriptorIn(info, &error_prototype)) {
        facts.native_builtin_id = core.function.nativeBuiltinId(.error_object, @intFromEnum(error_builtin.PrototypeMethod.to_string));
    } else if (descriptorIn(info, &error_static)) {
        if (std.mem.eql(u8, name, "captureStackTrace")) {
            facts.native_builtin_id = core.function.nativeBuiltinId(.error_object, @intFromEnum(error_builtin.StaticMethod.capture_stack_trace));
        }
    } else if (descriptorIn(info, &date_static)) {
        if (date_builtin.staticMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.date, id);
    } else if (descriptorIn(info, &date_prototype)) {
        if (date_builtin.prototypeMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.date, id);
    } else if (descriptorIn(info, &regexp_prototype)) {
        if (regexp_builtin.prototypeMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.regexp, id);
    } else if (descriptorIn(info, &promise_static)) {
        if (promise_ops.legacyStaticMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.promise, id);
    } else if (descriptorIn(info, &map_static)) {
        if (collection_builtin.staticMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.collection, id);
    } else if (descriptorIn(info, &map_prototype)) {
        if (collection_builtin.prototypeMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.collection, id);
        facts.collection_method_owner_class = core.class.ids.map;
    } else if (descriptorIn(info, &set_prototype)) {
        if (collection_builtin.prototypeMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.collection, id);
        facts.collection_method_owner_class = core.class.ids.set;
    } else if (descriptorIn(info, &weak_map_prototype)) {
        if (collection_builtin.prototypeMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.collection, id);
        facts.collection_method_owner_class = core.class.ids.weakmap;
    } else if (descriptorIn(info, &weak_set_prototype)) {
        if (collection_builtin.prototypeMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.collection, id);
        facts.collection_method_owner_class = core.class.ids.weakset;
    } else if (descriptorIn(info, &buffer_prototype)) {
        if (buffer_builtin.arrayBufferPrototypeMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.buffer, id);
    } else if (descriptorIn(info, &shared_buffer_prototype)) {
        if (buffer_builtin.sharedArrayBufferPrototypeMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.buffer, id);
    } else if (descriptorIn(info, &array_buffer_static)) {
        if (buffer_builtin.staticMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.buffer, id);
    } else if (descriptorIn(info, &data_view_prototype)) {
        if (buffer_builtin.dataViewPrototypeMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.buffer, id);
    } else if (descriptorIn(info, &iterator_static)) {
        if (iterator_builtin.staticMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.iterator, id);
    } else if (descriptorIn(info, &iterator_prototype)) {
        if (iterator_builtin.prototypeMethodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.iterator, id);
    } else if (descriptorIn(info, &math_methods)) {
        if (internalEntryId(&math_builtin.internal_entries, name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.math, id);
    } else if (descriptorIn(info, &json_methods)) {
        if (internalEntryId(&json_builtin.internal_entries, name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.json, id);
    } else if (descriptorIn(info, &reflect_methods)) {
        if (reflect_builtin.methodId(name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.reflect, id);
    } else if (descriptorIn(info, &atomics_methods)) {
        if (internalEntryId(&atomics_builtin.internal_entries, name)) |id| facts.native_builtin_id = core.function.nativeBuiltinId(.atomics, id);
    } else if (descriptorIn(info, &disposable_stack_prototype)) {
        if (std.mem.eql(u8, name, "use")) facts.disposable_stack_method = 1;
        if (std.mem.eql(u8, name, "adopt")) facts.disposable_stack_method = 2;
        if (std.mem.eql(u8, name, "defer")) facts.disposable_stack_method = 3;
        if (std.mem.eql(u8, name, "dispose")) facts.disposable_stack_method = 4;
        if (std.mem.eql(u8, name, "move")) facts.disposable_stack_method = 5;
    } else if (descriptorIn(info, &async_disposable_stack_prototype)) {
        if (std.mem.eql(u8, name, "use")) facts.async_disposable_stack_method = 1;
        if (std.mem.eql(u8, name, "adopt")) facts.async_disposable_stack_method = 2;
        if (std.mem.eql(u8, name, "defer")) facts.async_disposable_stack_method = 3;
        if (std.mem.eql(u8, name, "disposeAsync")) facts.async_disposable_stack_method = 4;
        if (std.mem.eql(u8, name, "move")) facts.async_disposable_stack_method = 5;
    }
    return facts;
}

fn prepareStandardAutoInitNativeFunction(
    rt: *core.JSRuntime,
    info: *const core.property.AutoInit,
    function_value: core.JSValue,
) !void {
    const facts = standardAutoInitFacts(info);
    const function_object = expectObject(function_value);
    if (facts.native_builtin_id != 0) function_object.setNativeBuiltinIdAndRecord(rt, facts.native_builtin_id);
    if (facts.array_builtin_marker != .none and !try function_object.addArrayBuiltinMarker(rt, facts.array_builtin_marker)) return error.InvalidBuiltinRegistry;
    if (facts.typed_array_builtin_marker != .none and !try function_object.addTypedArrayBuiltinMarker(rt, facts.typed_array_builtin_marker)) return error.InvalidBuiltinRegistry;
    if (facts.array_iterator_kind != 0 and !try function_object.addArrayIteratorKind(rt, facts.array_iterator_kind)) return error.InvalidBuiltinRegistry;
    if (facts.iterator_identity and !try function_object.addIteratorIdentityFunction(rt)) return error.InvalidBuiltinRegistry;
    if (facts.collection_method_owner_class != core.class.invalid_class_id and !try function_object.addCollectionMethodOwnerClass(rt, facts.collection_method_owner_class)) return error.InvalidBuiltinRegistry;
    if (facts.disposable_stack_method != 0 and !try function_object.addDisposableStackMethod(rt, facts.disposable_stack_method)) return error.InvalidBuiltinRegistry;
    if (facts.async_disposable_stack_method != 0 and !try function_object.addAsyncDisposableStackMethod(rt, facts.async_disposable_stack_method)) return error.InvalidBuiltinRegistry;
}

fn installSymbolExtras(rt: *core.JSRuntime, global: *core.Object, symbol_ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, symbol_ctor) orelse return error.InvalidBuiltinRegistry;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.shape_ref.prop_count + 3);

    const description_key = core.atom.predefinedId("description", .string).?;
    try defineLazyNativeGetterAtomWithRealm(rt, proto, description_key, "get description", core.function.nativeBuiltinId(.primitive, primitive_symbol_description_get_id), Flags{ .writable = false, .enumerable = false, .configurable = true }, global);

    const to_primitive_flags = core.property.Flags.data(false, false, true);
    try proto.defineAutoInitPropertyFromDescriptor(rt, core.atom.predefinedId("Symbol.toPrimitive", .symbol).?, to_primitive_flags, global, &symbol_to_primitive_auto_init);

    try defineStringConstantAtomAssumingNewWithRealm(rt, proto, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, "Symbol", Flags{ .writable = false, .enumerable = false, .configurable = true }, global);
}

fn installWellKnownSymbolProperties(rt: *core.JSRuntime, symbol_ctor: *core.Object) !void {
    try symbol_ctor.reserveOwnPropertyCapacityAssumingPlain(rt, symbol_ctor.shape_ref.prop_count + 15);
    try defineWellKnownSymbol(rt, symbol_ctor, "toPrimitive", "Symbol.toPrimitive");
    try defineWellKnownSymbol(rt, symbol_ctor, "iterator", "Symbol.iterator");
    try defineWellKnownSymbol(rt, symbol_ctor, "match", "Symbol.match");
    try defineWellKnownSymbol(rt, symbol_ctor, "matchAll", "Symbol.matchAll");
    try defineWellKnownSymbol(rt, symbol_ctor, "replace", "Symbol.replace");
    try defineWellKnownSymbol(rt, symbol_ctor, "search", "Symbol.search");
    try defineWellKnownSymbol(rt, symbol_ctor, "split", "Symbol.split");
    try defineWellKnownSymbol(rt, symbol_ctor, "toStringTag", "Symbol.toStringTag");
    try defineWellKnownSymbol(rt, symbol_ctor, "isConcatSpreadable", "Symbol.isConcatSpreadable");
    try defineWellKnownSymbol(rt, symbol_ctor, "hasInstance", "Symbol.hasInstance");
    try defineWellKnownSymbol(rt, symbol_ctor, "species", "Symbol.species");
    try defineWellKnownSymbol(rt, symbol_ctor, "unscopables", "Symbol.unscopables");
    try defineWellKnownSymbol(rt, symbol_ctor, "asyncIterator", "Symbol.asyncIterator");
    try defineWellKnownSymbol(rt, symbol_ctor, "asyncDispose", "Symbol.asyncDispose");
    try defineWellKnownSymbol(rt, symbol_ctor, "dispose", "Symbol.dispose");
}

fn defineWellKnownSymbol(rt: *core.JSRuntime, symbol_ctor: *core.Object, name: []const u8, symbol_name: []const u8) !void {
    const symbol_atom = core.atom.predefinedId(symbol_name, .symbol) orelse return error.InvalidBuiltinRegistry;
    const symbol_value = try rt.symbolValue(symbol_atom);
    defer symbol_value.free(rt);
    try defineDataAssumingNew(rt, symbol_ctor, name, symbol_value, Flags{ .writable = false, .enumerable = false, .configurable = false });
}

fn installArrayPrototypeSymbols(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    const accessor_flags = Flags{ .writable = false, .enumerable = false, .configurable = true };
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.shape_ref.prop_count + 1);
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.shape_ref.prop_count + 2);

    const species_atom = core.atom.predefinedId("Symbol.species", .symbol).?;
    try defineLazyNativeGetterAtom(rt, ctor, species_atom, "get [Symbol.species]", core.function.nativeBuiltinId(.host, @intFromEnum(core.function.HostGlobalMethod.species_getter)), accessor_flags);
    if (!try tagAutoInitArrayBuiltinByAtom(rt, ctor, species_atom, .species_getter)) return error.InvalidBuiltinRegistry;

    const iterator_atom = core.atom.predefinedId("Symbol.iterator", .symbol).?;
    const values_atom = core.atom.predefinedId("values", .string).?;
    try publishMethodAlias(rt, proto, proto, values_atom, iterator_atom, false);
    if (!try tagAutoInitArrayIteratorKindByAtom(rt, proto, values_atom, 2)) return error.InvalidBuiltinRegistry;
    if (!try tagAutoInitArrayIteratorKindByAtom(rt, proto, iterator_atom, 2)) return error.InvalidBuiltinRegistry;

    const unscopables_atom = core.atom.predefinedId("Symbol.unscopables", .symbol).?;
    try proto.defineAutoInitPropertyFromDescriptor(
        rt,
        unscopables_atom,
        core.property.Flags.data(accessor_flags.writable, accessor_flags.enumerable, accessor_flags.configurable),
        global,
        &array_unscopables_auto_init,
    );
}

fn installArrayBufferExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const accessor_flags = Flags{ .writable = false, .enumerable = false, .configurable = true };
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.shape_ref.prop_count + 1);
    try defineLazyNativeGetterAtom(rt, ctor, core.atom.predefinedId("Symbol.species", .symbol).?, "get [Symbol.species]", core.function.nativeBuiltinId(.host, @intFromEnum(core.function.HostGlobalMethod.species_getter)), accessor_flags);

    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    const accessors = [_]struct {
        property_name: []const u8,
        getter_name: []const u8,
    }{
        .{ .property_name = "byteLength", .getter_name = "get byteLength" },
        .{ .property_name = "maxByteLength", .getter_name = "get maxByteLength" },
        .{ .property_name = "resizable", .getter_name = "get resizable" },
        .{ .property_name = "detached", .getter_name = "get detached" },
        .{ .property_name = "immutable", .getter_name = "get immutable" },
    };
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.shape_ref.prop_count + accessors.len + 1);
    for (accessors) |accessor| {
        const native_id = if (buffer_builtin.arrayBufferAccessorMethodId(accessor.property_name)) |id|
            core.function.nativeBuiltinId(.buffer, id)
        else
            0;
        const atom = try temporaryStringAtom(rt, accessor.property_name);
        defer freeTemporaryStringAtom(rt, atom);
        try defineLazyNativeGetterAtomWithRealm(rt, proto, atom, accessor.getter_name, native_id, accessor_flags, global);
    }

    try defineNativeMethodsAssumingNewWithRealm(rt, proto, &buffer_prototype, global);
    try defineStringConstantAtomAssumingNewWithRealm(rt, proto, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, "ArrayBuffer", Flags{ .writable = false, .enumerable = false, .configurable = true }, global);
}

fn installSharedArrayBufferExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const accessor_flags = Flags{ .writable = false, .enumerable = false, .configurable = true };
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.shape_ref.prop_count + 1);
    try defineLazyNativeGetterAtom(rt, ctor, core.atom.predefinedId("Symbol.species", .symbol).?, "get [Symbol.species]", core.function.nativeBuiltinId(.host, @intFromEnum(core.function.HostGlobalMethod.species_getter)), accessor_flags);

    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    const accessors = [_]struct {
        property_name: []const u8,
        getter_name: []const u8,
    }{
        .{ .property_name = "byteLength", .getter_name = "get byteLength" },
        .{ .property_name = "maxByteLength", .getter_name = "get maxByteLength" },
        .{ .property_name = "growable", .getter_name = "get growable" },
    };
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.shape_ref.prop_count + accessors.len + 1);
    for (accessors) |accessor| {
        const native_id = if (buffer_builtin.sharedArrayBufferAccessorMethodId(accessor.property_name)) |id|
            core.function.nativeBuiltinId(.buffer, id)
        else
            0;
        const atom = core.atom.predefinedId(accessor.property_name, .string) orelse return error.InvalidBuiltinRegistry;
        try defineLazyNativeGetterAtomWithRealm(rt, proto, atom, accessor.getter_name, native_id, accessor_flags, global);
    }

    try defineNativeMethodsAssumingNewWithRealm(rt, proto, &shared_buffer_prototype, global);
    try defineStringConstantAtomAssumingNewWithRealm(rt, proto, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, "SharedArrayBuffer", Flags{ .writable = false, .enumerable = false, .configurable = true }, global);
}

fn installDataViewExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
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
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.shape_ref.prop_count + accessors.len + 1);
    for (accessors) |accessor| {
        const native_id = if (buffer_builtin.dataViewAccessorMethodId(accessor.property_name)) |id|
            core.function.nativeBuiltinId(.buffer, id)
        else
            0;
        const atom = core.atom.predefinedId(accessor.property_name, .string) orelse return error.InvalidBuiltinRegistry;
        try defineLazyNativeGetterAtomWithRealm(rt, proto, atom, accessor.getter_name, native_id, accessor_flags, global);
    }
    try defineNativeMethodsAssumingNewWithRealm(rt, proto, &data_view_prototype, global);
    for (data_view_prototype) |method| {
        const id = buffer_builtin.dataViewPrototypeMethodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, proto, method.name, .buffer, id);
    }

    try defineStringConstantAtomAssumingNewWithRealm(rt, proto, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, "DataView", Flags{ .writable = false, .enumerable = false, .configurable = true }, global);
}

fn defineDatePrototypeMethodsAssumingNew(rt: *core.JSRuntime, global: *core.Object, proto: *core.Object) !void {
    const flags = core.property.Flags.data(method_flags.writable, method_flags.enumerable, method_flags.configurable);
    if (date_prototype.len != 0) try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.shape_ref.prop_count + date_prototype.len + 1);
    for (&date_prototype) |*method| {
        const key = try temporaryStringAtom(rt, method.name);
        defer freeTemporaryStringAtom(rt, key);
        try proto.defineAutoInitPropertyFromDescriptor(rt, key, flags, global, method);
        if (std.mem.eql(u8, method.name, "toUTCString")) {
            try installNativeMethodAlias(rt, proto, "toUTCString", "toGMTString");
        }
    }
}

fn installDatePrototypeAliases(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.shape_ref.prop_count + 1);
    const to_primitive_atom = core.atom.predefinedId("Symbol.toPrimitive", .symbol).?;
    const to_primitive_flags = core.property.Flags.data(false, false, true);
    try proto.defineAutoInitPropertyFromDescriptor(rt, to_primitive_atom, to_primitive_flags, global, &date_to_primitive_auto_init);
}

fn installFunctionPrototypeExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.shape_ref.prop_count + 1);
    try bindNativeRecordByName(rt, proto, "call", .function, @intFromEnum(function_ops.PrototypeMethod.call));
    try bindNativeRecordByName(rt, proto, "apply", .function, @intFromEnum(function_ops.PrototypeMethod.apply));
    try bindNativeRecordByName(rt, proto, "toString", .function, @intFromEnum(function_ops.PrototypeMethod.to_string));
    try bindNativeRecordByName(rt, proto, "bind", .function, @intFromEnum(function_ops.PrototypeMethod.bind));

    const has_instance_atom = core.atom.predefinedId("Symbol.hasInstance", .symbol) orelse return error.InvalidBuiltinRegistry;
    const has_instance_flags = core.property.Flags.data(false, false, false);
    try proto.defineAutoInitPropertyFromDescriptor(rt, has_instance_atom, has_instance_flags, global, &function_has_instance_auto_init);
}

fn installErrorPrototypeExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.shape_ref.prop_count + 1);
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
        global,
    );
}

fn installPromiseExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const species_atom = core.atom.predefinedId("Symbol.species", .symbol) orelse return error.InvalidBuiltinRegistry;
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.shape_ref.prop_count + 1);
    try defineLazyNativeGetterAtom(rt, ctor, species_atom, "get [Symbol.species]", core.function.nativeBuiltinId(.host, @intFromEnum(core.function.HostGlobalMethod.species_getter)), Flags{ .writable = false, .enumerable = false, .configurable = true });
    for (promise_static) |method| {
        const id = promise_ops.legacyStaticMethodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, ctor, method.name, .promise, id);
    }
    try global.setCachedPromiseProto(rt, constructorPrototypeObject(rt, ctor));
    // Mirror qjs ctx->promise_ctor (JS_AddIntrinsicPromise quickjs.c:54663):
    // the realm retains the intrinsic constructor so await / the default
    // species never depend on the mutable globalThis.Promise binding.
    const cached_ctor = try global.cachedRealmValueSlot(rt, .promise_constructor);
    try global.setOptionalValueSlot(rt, cached_ctor, ctor.value().dup());
}

fn installIteratorExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    const accessor_flags = Flags{ .writable = false, .enumerable = false, .configurable = true };
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.shape_ref.prop_count + 4);

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
    try proto.defineAutoInitPropertyFromDescriptor(rt, iterator_atom, iterator_flags, global, &iterator_identity_method);
    if (!try tagAutoInitIteratorIdentityByAtom(rt, proto, iterator_atom)) return error.InvalidBuiltinRegistry;

    try proto.defineAutoInitPropertyFromDescriptor(rt, core.atom.ids.Symbol_dispose, iterator_flags, global, &iterator_dispose_auto_init);

    try defineLazyNativeAccessorPairAtom(
        rt,
        proto,
        core.atom.ids.constructor,
        "get constructor",
        core.function.nativeBuiltinId(.iterator, @intFromEnum(iterator_builtin.AccessorMethod.constructor_getter)),
        1,
        core.function.nativeBuiltinId(.iterator, @intFromEnum(iterator_builtin.AccessorMethod.constructor_setter)),
        accessor_flags,
        global,
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
        global,
    );
}

fn installStringPrototypeAliases(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.shape_ref.prop_count + 4);
    try defineData(rt, proto, "length", core.JSValue.int32(0), Flags{ .writable = false, .enumerable = false, .configurable = true });
    try installNativeMethodAlias(rt, proto, "trimStart", "trimLeft");
    try installNativeMethodAlias(rt, proto, "trimEnd", "trimRight");
    const iterator_flags = core.property.Flags.data(method_flags.writable, method_flags.enumerable, method_flags.configurable);
    try proto.defineAutoInitPropertyFromDescriptor(rt, core.atom.predefinedId("Symbol.iterator", .symbol).?, iterator_flags, global, &string_iterator_auto_init);
}

fn defineObjectPrototypeMethodsAssumingNew(rt: *core.JSRuntime, global: *core.Object, proto: *core.Object) !void {
    try defineNativeMethodsAssumingNewWithRealm(rt, proto, object_prototype[0..6], global);

    const proto_key = try rt.internAtom("__proto__");
    defer rt.atoms.free(proto_key);
    try defineLazyNativeAccessorPairAtom(rt, proto, proto_key, "get __proto__", 0, 1, 0, Flags{ .writable = false, .enumerable = false, .configurable = true }, global);

    try defineNativeMethodsAssumingNewWithRealm(rt, proto, object_prototype[6..], global);
}

fn tagArrayPrototypeMethods(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    const key = core.atom.predefinedId("toString", .string).?;
    if (!try tagAutoInitArrayBuiltinByAtom(rt, proto, key, .to_string)) return error.InvalidBuiltinRegistry;
    const locale_key = core.atom.predefinedId("toLocaleString", .string).?;
    if (!try tagAutoInitArrayBuiltinByAtom(rt, proto, locale_key, .to_locale_string)) return error.InvalidBuiltinRegistry;
    const concat_key = core.atom.predefinedId("concat", .string).?;
    if (!try tagAutoInitArrayBuiltinByAtom(rt, proto, concat_key, .concat)) return error.InvalidBuiltinRegistry;
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
            if (bindAutoInitNativeRecordByAtom(rt, proto, key, core.function.nativeBuiltinId(.buffer, native_id))) continue;
        }
        const value = try proto.getProperty(key);
        defer value.free(rt);
        if (!value.isObject()) continue;
        const function_object = expectObject(value);
        if (id) |native_id| function_object.setNativeBuiltinIdAndRecord(rt, core.function.nativeBuiltinId(.buffer, native_id));
    }
}

fn tagArrayIteratorMethod(rt: *core.JSRuntime, proto: *core.Object, name: []const u8, kind: u8) !void {
    const key = try temporaryStringAtom(rt, name);
    defer freeTemporaryStringAtom(rt, key);
    if (try tagAutoInitArrayIteratorKindByAtom(rt, proto, key, kind)) return;
    const value = try proto.getProperty(key);
    defer value.free(rt);
    if (!value.isObject()) return;
    if (!try expectObject(value).addArrayIteratorKind(rt, kind)) return error.InvalidBuiltinRegistry;
}

fn installPerformance(rt: *core.JSRuntime, global: *core.Object) !void {
    const key = core.atom.predefinedId("performance", .string).?;
    const flags = core.property.Flags.data(global_flags.writable, global_flags.enumerable, global_flags.configurable);
    try global.defineAutoInitPropertyFromDescriptor(rt, key, flags, global, &performance_auto_init);
}

fn installNavigator(rt: *core.JSRuntime, global: *core.Object) !void {
    const key = core.atom.predefinedId("navigator", .string).?;
    const flags = core.property.Flags.data(false, true, true);
    try global.defineAutoInitPropertyFromDescriptor(rt, key, flags, global, &navigator_auto_init);
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

fn installRegExpExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try bindRegExpPrototypeNativeRecords(rt, proto);
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.shape_ref.prop_count + 21);

    const escape_key = try rt.internAtom("escape");
    defer rt.atoms.free(escape_key);
    const escape_flags = core.property.Flags.data(method_flags.writable, method_flags.enumerable, method_flags.configurable);
    try ctor.defineAutoInitPropertyFromDescriptor(rt, escape_key, escape_flags, null, &regexp_escape_auto_init);

    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.shape_ref.prop_count + regexp_symbol_auto_init.len + 10);
    for (&regexp_symbol_auto_init) |*method| {
        const flags = core.property.Flags.data(method_flags.writable, method_flags.enumerable, method_flags.configurable);
        try proto.defineAutoInitPropertyFromDescriptor(
            rt,
            core.atom.predefinedId(method.symbol, .symbol).?,
            flags,
            global,
            &method.info,
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
        try defineLazyNativeGetterAtomWithRealm(rt, proto, key, accessor.getter_name, native_id, accessor_flags, global);
    }

    try defineLazyNativeGetterAtom(rt, ctor, core.atom.predefinedId("Symbol.species", .symbol).?, "get [Symbol.species]", core.function.nativeBuiltinId(.host, @intFromEnum(core.function.HostGlobalMethod.species_getter)), accessor_flags);

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
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.shape_ref.prop_count + accessors.len);
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
    const realm_global = ctor.nativeFunctionRealmGlobalPtr() orelse return error.InvalidBuiltinRegistry;
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
            realm_global,
        );
    } else {
        try defineLazyNativeGetterAtomWithRealm(rt, ctor, key, getter_name, getter_id, flags, realm_global);
    }
}

fn bindRegExpPrototypeNativeRecords(rt: *core.JSRuntime, proto: *core.Object) !void {
    for (regexp_prototype) |method| {
        const id = regexp_builtin.prototypeMethodId(method.name) orelse continue;
        try bindNativeRecordByName(rt, proto, method.name, .regexp, id);
    }
}

fn installNativeMethodAlias(rt: *core.JSRuntime, proto: *core.Object, target: []const u8, alias: []const u8) !void {
    const target_key = try temporaryStringAtom(rt, target);
    defer freeTemporaryStringAtom(rt, target_key);
    const alias_key = try temporaryStringAtom(rt, alias);
    defer freeTemporaryStringAtom(rt, alias_key);
    try publishMethodAlias(rt, proto, proto, target_key, alias_key, false);
}

fn installCollectionExtras(rt: *core.JSRuntime, global: *core.Object, name: []const u8, ctor: *core.Object) !void {
    if (std.mem.eql(u8, name, "Map") or std.mem.eql(u8, name, "Set")) try installCollectionSpecies(rt, ctor);
    try bindCollectionStaticNativeRecords(rt, ctor, name);
    if (std.mem.eql(u8, name, "Map") or std.mem.eql(u8, name, "Set")) {
        const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
        try defineCollectionPrototypeMethodsAssumingNew(rt, global, proto, name);
    }
    try tagCollectionPrototypeMethods(rt, name, ctor);
    try installCollectionPrototypeSymbols(rt, global, name, ctor);
}

fn installCollectionSpecies(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const species_atom = core.atom.predefinedId("Symbol.species", .symbol) orelse return error.InvalidBuiltinRegistry;
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.shape_ref.prop_count + 1);
    try defineLazyNativeGetterAtom(rt, ctor, species_atom, "get [Symbol.species]", core.function.nativeBuiltinId(.host, @intFromEnum(core.function.HostGlobalMethod.species_getter)), Flags{ .writable = false, .enumerable = false, .configurable = true });
}

fn installTypedArraySpecies(rt: *core.JSRuntime, ctor: *core.Object) !void {
    const species_atom = core.atom.predefinedId("Symbol.species", .symbol) orelse return error.InvalidBuiltinRegistry;
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.shape_ref.prop_count + 1);
    try defineLazyNativeGetterAtom(rt, ctor, species_atom, "get [Symbol.species]", core.function.nativeBuiltinId(.host, @intFromEnum(core.function.HostGlobalMethod.species_getter)), Flags{ .writable = false, .enumerable = false, .configurable = true });
}

fn installCollectionPrototypeSymbols(rt: *core.JSRuntime, global: *core.Object, name: []const u8, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    const extra_count: usize = if (std.mem.eql(u8, name, "Map") or std.mem.eql(u8, name, "Set")) 2 else 1;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.shape_ref.prop_count + extra_count);

    if (std.mem.eql(u8, name, "Map")) {
        const entries_atom = core.atom.predefinedId("entries", .string).?;
        const iterator_atom = core.atom.predefinedId("Symbol.iterator", .symbol).?;
        try publishMethodAlias(rt, proto, proto, entries_atom, iterator_atom, false);
        if (!try tagAutoInitCollectionOwnerByAtom(rt, proto, entries_atom, core.class.ids.map)) return error.InvalidBuiltinRegistry;
        if (!try tagAutoInitCollectionOwnerByAtom(rt, proto, iterator_atom, core.class.ids.map)) return error.InvalidBuiltinRegistry;
    } else if (std.mem.eql(u8, name, "Set")) {
        const values_atom = core.atom.predefinedId("values", .string).?;
        const keys_atom = core.atom.predefinedId("keys", .string).?;
        const iterator_atom = core.atom.predefinedId("Symbol.iterator", .symbol).?;
        try publishMethodAlias(rt, proto, proto, values_atom, keys_atom, true);
        try publishMethodAlias(rt, proto, proto, values_atom, iterator_atom, false);
        if (!try tagAutoInitCollectionOwnerByAtom(rt, proto, values_atom, core.class.ids.set)) return error.InvalidBuiltinRegistry;
        if (!try tagAutoInitCollectionOwnerByAtom(rt, proto, keys_atom, core.class.ids.set)) return error.InvalidBuiltinRegistry;
        if (!try tagAutoInitCollectionOwnerByAtom(rt, proto, iterator_atom, core.class.ids.set)) return error.InvalidBuiltinRegistry;
    }

    try defineStringConstantAtomAssumingNewWithRealm(rt, proto, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, collectionTag(name) orelse return error.InvalidBuiltinRegistry, Flags{ .writable = false, .enumerable = false, .configurable = true }, global);
}

fn installNamespaceToStringTag(rt: *core.JSRuntime, global: *core.Object, namespace: *core.Object, tag_name: []const u8) !void {
    try defineStringConstantAtomAssumingNewWithRealm(rt, namespace, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, tag_name, Flags{ .writable = false, .enumerable = false, .configurable = true }, global);
}

fn installPrototypeToStringTag(rt: *core.JSRuntime, global: *core.Object, tag_name: []const u8, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try defineStringConstantAtomAssumingNewWithRealm(rt, proto, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, tag_name, Flags{ .writable = false, .enumerable = false, .configurable = true }, global);
}

fn installDisposableStackExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.shape_ref.prop_count + 3);

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
        if (try tagAutoInitDisposableStackMethodByAtom(rt, proto, key, tag.id)) continue;
        const value = try proto.getProperty(key);
        defer value.free(rt);
        if (!value.isObject()) return error.InvalidBuiltinRegistry;
        if (!try expectObject(value).addDisposableStackMethod(rt, tag.id)) return error.InvalidBuiltinRegistry;
    }

    const disposed_key = try temporaryStringAtom(rt, "disposed");
    defer freeTemporaryStringAtom(rt, disposed_key);
    try defineLazyNativeGetterAtomWithRealm(rt, proto, disposed_key, "get disposed", 0, Flags{ .writable = false, .enumerable = false, .configurable = true }, global);
    if (!try tagAutoInitDisposableStackMethodByAtom(rt, proto, disposed_key, 6)) return error.InvalidBuiltinRegistry;

    const dispose_atom = core.atom.predefinedId("dispose", .string).?;
    try publishMethodAlias(rt, proto, proto, dispose_atom, core.atom.ids.Symbol_dispose, false);
    if (!try tagAutoInitDisposableStackMethodByAtom(rt, proto, dispose_atom, 4)) return error.InvalidBuiltinRegistry;
    if (!try tagAutoInitDisposableStackMethodByAtom(rt, proto, core.atom.ids.Symbol_dispose, 4)) return error.InvalidBuiltinRegistry;

    try defineStringConstantAtomAssumingNewWithRealm(rt, proto, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, "DisposableStack", Flags{ .writable = false, .enumerable = false, .configurable = true }, global);
}

fn installAsyncDisposableStackExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.shape_ref.prop_count + 3);

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
        if (try tagAutoInitAsyncDisposableStackMethodByAtom(rt, proto, key, tag.id)) continue;
        const value = try proto.getProperty(key);
        defer value.free(rt);
        if (!value.isObject()) return error.InvalidBuiltinRegistry;
        if (!try expectObject(value).addAsyncDisposableStackMethod(rt, tag.id)) return error.InvalidBuiltinRegistry;
    }

    const disposed_key = try temporaryStringAtom(rt, "disposed");
    defer freeTemporaryStringAtom(rt, disposed_key);
    try defineLazyNativeGetterAtomWithRealm(rt, proto, disposed_key, "get disposed", 0, Flags{ .writable = false, .enumerable = false, .configurable = true }, global);
    if (!try tagAutoInitAsyncDisposableStackMethodByAtom(rt, proto, disposed_key, 6)) return error.InvalidBuiltinRegistry;

    const dispose_async_key = try temporaryStringAtom(rt, "disposeAsync");
    defer freeTemporaryStringAtom(rt, dispose_async_key);
    try publishMethodAlias(rt, proto, proto, dispose_async_key, core.atom.ids.Symbol_asyncDispose, false);
    if (!try tagAutoInitAsyncDisposableStackMethodByAtom(rt, proto, dispose_async_key, 4)) return error.InvalidBuiltinRegistry;
    if (!try tagAutoInitAsyncDisposableStackMethodByAtom(rt, proto, core.atom.ids.Symbol_asyncDispose, 4)) return error.InvalidBuiltinRegistry;

    try defineStringConstantAtomAssumingNewWithRealm(rt, proto, core.atom.predefinedId("Symbol.toStringTag", .symbol).?, "AsyncDisposableStack", Flags{ .writable = false, .enumerable = false, .configurable = true }, global);
}

fn installDOMExceptionExtras(rt: *core.JSRuntime, global: *core.Object, ctor: *core.Object) !void {
    try installPrototypeToStringTag(rt, global, "DOMException", ctor);
    const proto = constructorPrototypeObject(rt, ctor) orelse return error.InvalidBuiltinRegistry;
    const flags = Flags{ .writable = false, .enumerable = true, .configurable = false };
    try ctor.reserveOwnPropertyCapacityAssumingPlain(rt, ctor.shape_ref.prop_count + dom_exception_constants.len);
    try proto.reserveOwnPropertyCapacityAssumingPlain(rt, proto.shape_ref.prop_count + dom_exception_constants.len);
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
            bindAutoInitNativeRecordByAtom(rt, proto, method_key, core.function.nativeBuiltinId(.collection, id))
        else
            true;
        const marker_deferred = try tagAutoInitCollectionOwnerByAtom(rt, proto, method_key, class_id);
        if (native_deferred and marker_deferred) continue;
        const method_value = try proto.getProperty(method_key);
        defer method_value.free(rt);
        if (!method_value.isObject()) continue;
        const function_object = expectObject(method_value);
        if (collection_builtin.prototypeMethodId(method.name)) |id| {
            function_object.setNativeBuiltinIdAndRecord(rt, core.function.nativeBuiltinId(.collection, id));
        }
        if (!try function_object.addCollectionMethodOwnerClass(rt, class_id)) return error.InvalidBuiltinRegistry;
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

pub const Intrinsics = struct {
    context: *core.JSContext,
    global: *core.Object,

    pub fn init(rt: *core.JSRuntime) !Intrinsics {
        configureRuntime(rt);
        const context = try core.JSContext.create(rt);
        errdefer context.destroy();
        const global = try core.Object.createWithOwnPropertyCapacity(
            rt,
            core.class.ids.global_object,
            null,
            standardGlobalOwnPropertyCapacity(),
        );
        _ = try global.ensureGlobalPayload(rt);
        context.global = global;
        try rt.installStandardGlobals(global);
        return .{ .context = context, .global = global };
    }

    pub fn deinit(self: *Intrinsics, rt: *core.JSRuntime) void {
        _ = rt;
        self.context.destroy();
    }
};

const standard_global_domains = [_][]const u8{
    "Object",
    "Function",
    "Array",
    "String",
    "Number",
    "Boolean",
    "Symbol",
    "BigInt",
    "Math",
    "Date",
    "JSON",
    "RegExp",
    "Error",
    "Promise",
    "Map",
    "Set",
    "WeakMap",
    "WeakSet",
    "ArrayBuffer",
    "TypedArray",
    "DataView",
    "Reflect",
    "Proxy",
    "Iterator",
    "Atomics",
};

test "intrinsic bootstrap registers global builtin domains through object properties" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var intrinsics = try Intrinsics.init(rt);
    defer intrinsics.deinit(rt);

    for (standard_global_domains) |name| {
        const atom_id = try rt.internAtom(name);
        defer rt.atoms.free(atom_id);
        try std.testing.expect(intrinsics.global.hasOwnProperty(atom_id));
        const desc = (try intrinsics.global.getOwnProperty(rt, atom_id)).?;
        defer desc.destroy(rt);
        try std.testing.expectEqual(true, desc.writable.?);
        try std.testing.expectEqual(false, desc.enumerable.?);
        try std.testing.expectEqual(true, desc.configurable.?);
    }

    const map_atom = try rt.internAtom("Map");
    defer rt.atoms.free(map_atom);
    const map_ctor = try intrinsics.global.getProperty(map_atom);
    defer map_ctor.free(rt);
    try std.testing.expect(map_ctor.isObject());
    const map_ctor_object: *core.Object = @fieldParentPtr("header", map_ctor.refHeader().?);
    try std.testing.expectEqual(core.class.ids.c_function, map_ctor_object.class_id);

    const prototype_atom = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_atom);
    const prototype_desc = (try map_ctor_object.getOwnProperty(rt, prototype_atom)).?;
    defer prototype_desc.destroy(rt);
    try std.testing.expectEqual(false, prototype_desc.writable.?);
    try std.testing.expectEqual(false, prototype_desc.enumerable.?);
    try std.testing.expectEqual(false, prototype_desc.configurable.?);
    try std.testing.expect(prototype_desc.value.isObject());
    const map_proto: *core.Object = @fieldParentPtr("header", prototype_desc.value.refHeader().?);
    try std.testing.expectEqual(core.class.ids.object, map_proto.class_id);

    const set_atom = try rt.internAtom("set");
    defer rt.atoms.free(set_atom);
    const set_desc = (try map_proto.getOwnProperty(rt, set_atom)).?;
    defer set_desc.destroy(rt);
    try std.testing.expectEqual(true, set_desc.writable.?);
    try std.testing.expectEqual(false, set_desc.enumerable.?);
    try std.testing.expectEqual(true, set_desc.configurable.?);
    try std.testing.expect(set_desc.value.isObject());
    const set_func_obj: *core.Object = @fieldParentPtr("header", set_desc.value.refHeader().?);
    try std.testing.expectEqual(core.class.ids.c_function, set_func_obj.class_id);
}

test "lazy standard functions attach typed records for every formerly exceptional domain" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var intrinsics = try Intrinsics.init(rt);
    defer intrinsics.deinit(rt);

    const Expected = struct {
        owner: []const u8,
        method: []const u8,
        domain: core.function.NativeBuiltinDomain,
        id: u32,
    };
    const expected = [_]Expected{
        .{ .owner = "Atomics", .method = "waitAsync", .domain = .atomics, .id = @intFromEnum(atomics_builtin.StaticMethod.wait_async) },
        .{ .owner = "performance", .method = "now", .domain = .performance, .id = 1 },
        .{ .owner = "Promise", .method = "all", .domain = .promise, .id = @intFromEnum(promise_ops.LegacyStaticMethod.all) },
        .{ .owner = "Promise", .method = "allKeyed", .domain = .promise, .id = @intFromEnum(promise_ops.LegacyStaticMethod.all_keyed) },
        .{ .owner = "Promise", .method = "withResolvers", .domain = .promise, .id = @intFromEnum(promise_ops.LegacyStaticMethod.with_resolvers) },
    };

    for (expected) |item| {
        const owner_key = try temporaryStringAtom(rt, item.owner);
        defer freeTemporaryStringAtom(rt, owner_key);
        const owner_value = try intrinsics.global.getProperty(owner_key);
        defer owner_value.free(rt);
        const owner = expectObject(owner_value);

        const method_key = try temporaryStringAtom(rt, item.method);
        defer freeTemporaryStringAtom(rt, method_key);
        const method_value = try owner.getProperty(method_key);
        defer method_value.free(rt);
        const function_object = expectObject(method_value);

        try std.testing.expectEqual(core.function.nativeBuiltinId(item.domain, item.id), function_object.nativeFunctionId());
        const record = function_object.nativeRecord() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(core.host_function.NativeCProto.generic_magic, record.cproto);
        try std.testing.expect(record.native_function != null);
    }

    const escape_key = try temporaryStringAtom(rt, "escape");
    defer freeTemporaryStringAtom(rt, escape_key);
    const escape_value = try intrinsics.global.getProperty(escape_key);
    defer escape_value.free(rt);
    const escape_function = expectObject(escape_value);
    try std.testing.expectEqual(core.function.nativeBuiltinId(.uri, core.uri.escape_id), escape_function.nativeFunctionId());
    try std.testing.expect(escape_function.nativeRecord() != null);
}
