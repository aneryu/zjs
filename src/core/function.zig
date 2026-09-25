//! Core native-builtin identities and function-object creation.
//!
//! Encoded builtin domains are stable dispatch metadata shared with exec, not
//! VM state.
//! QuickJS map: `JSFunctionBytecode` and function object data around
//! quickjs.c. Higher layers may consume this core module; it may not
//! import parser/exec/runtime/binding.

const atom = @import("atom.zig");
const JSValue = @import("value.zig").JSValue;
const Object = @import("object.zig").Object;
const Descriptor = @import("descriptor.zig").Descriptor;
const string = @import("string.zig");
const runtime = @import("../runtime.zig");
const JSRuntime = runtime.JSRuntime;
const RealmContext = @import("context.zig").RealmContext;
const class = @import("class.zig");
const std = @import("std");

pub const NativeBuiltinDomain = enum(i32) {
    math = 1,
    number = 2,
    string = 3,
    date = 4,
    array = 5,
    regexp = 6,
    collection = 7,
    buffer = 8,
    uri = 9,
    performance = 10,
    json = 11,
    atomics = 12,
    reflect = 13,
    object = 14,
    primitive = 15,
    function = 16,
    error_object = 17,
    iterator = 18,
    host = 19,
    promise = 20,
    /// WeakRef.prototype / FinalizationRegistry.prototype. qjs declares these
    /// as their own function lists (`js_weakref_proto_funcs` quickjs.c,
    /// `js_finrec_proto_funcs` quickjs.c) rather than folding them into
    /// the Map/Set lists, so they get their own id namespace here too.
    weak_ref = 21,
};

/// Method ids for the `.host` native-builtin domain: host/web globals and
/// engine-internal helpers that have no spec namespace of their own
/// (navigator accessors, constructor stubs, the shared `[Symbol.species]`
/// getter, and the V8-style CallSite methods).
pub const HostGlobalMethod = enum(u32) {
    // Retired bundled-host ids. Preserve the numbering; their functions now
    // use host-owned NativeEntry records and are not dispatched by these ids.
    btoa = 1,
    atob = 2,
    queue_microtask = 3,
    gc = 4,
    navigator_user_agent_get = 5,
    dom_exception_ctor_call = 6,
    species_getter = 7,
    callsite_get_function = 8,
    callsite_get_function_name = 9,
    callsite_get_file_name = 10,
    callsite_get_line_number = 11,
    callsite_get_column_number = 12,
    callsite_is_native = 13,
};

// QuickJS CLI exposes navigator.userAgent as "quickjs-ng/<JS_GetVersion()>".
// Pure version constant returned by the `navigator_user_agent_get` host getter
// above; relocated to engine core in Phase 6b-3 STEP 2. Kept tied to the
// QuickJS reference version used by the local
// fixtures.
pub const navigator_user_agent = "quickjs-ng/0.14.0";

pub const NativeBuiltinRef = struct {
    domain: NativeBuiltinDomain,
    id: u32,
};

/// One native builtin addressed by domain and per-domain id, in the 32-bit
/// form the function payload and the method tables store: the id in the low
/// ten bits, the domain code above it, all-zero for "no builtin".  Storage
/// stays an `i32` (`Object.nativeFunctionId`); this is the layout of it.
pub const NativeBuiltinId = packed struct(i32) {
    id: u10 = 0,
    domain: u22 = 0,

    pub const none: NativeBuiltinId = .{};

    pub fn init(domain: NativeBuiltinDomain, id: u32) NativeBuiltinId {
        std.debug.assert(id != 0 and id <= std.math.maxInt(u10));
        return .{ .id = @intCast(id), .domain = @intCast(@intFromEnum(domain)) };
    }

    pub fn fromRaw(encoded: i32) NativeBuiltinId {
        return @bitCast(encoded);
    }

    pub fn raw(self: NativeBuiltinId) i32 {
        return @bitCast(self);
    }

    /// Null for the zero id and for any domain code the enum does not name
    /// (which covers every negative raw value: its sign bit lands in
    /// `domain`).
    pub fn decode(self: NativeBuiltinId) ?NativeBuiltinRef {
        if (self.id == 0) return null;
        const domain = domainFromCode(self.domain) orelse return null;
        return .{ .domain = domain, .id = self.id };
    }

    /// The domain codes are contiguous, so membership is one range check
    /// (`std.enums.fromInt` would expand to a 21-way jump table on the
    /// property-fast-path callers).
    fn domainFromCode(code: u22) ?NativeBuiltinDomain {
        const domains = comptime std.enums.values(NativeBuiltinDomain);
        const first = comptime @intFromEnum(domains[0]);
        const last = comptime @intFromEnum(domains[domains.len - 1]);
        comptime std.debug.assert(last - first + 1 == domains.len);
        if (code < first or code > last) return null;
        return @enumFromInt(code);
    }
};

pub fn nativeBuiltinId(domain: NativeBuiltinDomain, id: u32) i32 {
    return NativeBuiltinId.init(domain, id).raw();
}

pub fn decodeNativeBuiltinId(encoded: i32) ?NativeBuiltinRef {
    return NativeBuiltinId.fromRaw(encoded).decode();
}

test "native builtin ids round-trip and reject the zero id, unknown domains and negatives" {
    const encoded = nativeBuiltinId(.regexp, 17);
    try std.testing.expectEqual(@as(i32, 6 * 1024 + 17), encoded);
    const ref = decodeNativeBuiltinId(encoded).?;
    try std.testing.expectEqual(NativeBuiltinDomain.regexp, ref.domain);
    try std.testing.expectEqual(@as(u32, 17), ref.id);
    try std.testing.expectEqual(@as(?NativeBuiltinRef, null), decodeNativeBuiltinId(0));
    try std.testing.expectEqual(@as(?NativeBuiltinRef, null), decodeNativeBuiltinId(6 * 1024));
    try std.testing.expectEqual(@as(?NativeBuiltinRef, null), decodeNativeBuiltinId(22 * 1024 + 1));
    try std.testing.expectEqual(@as(?NativeBuiltinRef, null), decodeNativeBuiltinId(-5));
    try std.testing.expectEqual(@as(?NativeBuiltinRef, null), decodeNativeBuiltinId(std.math.minInt(i32)));
}

fn isAsciiBuiltinName(bytes: []const u8) bool {
    for (bytes) |b| {
        if (b >= 0x80) return false;
    }
    return true;
}

fn nativeFunctionWithClass(
    rt: *JSRuntime,
    class_id: class.ClassId,
    prototype: ?*Object,
    name: []const u8,
    length: i32,
) !JSValue {
    var values = [_]JSValue{if (prototype) |object| object.value() else JSValue.nullValue()};
    const slots: []JSValue = &values;
    const slices = [_]runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    const function_object = try Object.createWithOwnPropertyCapacity(rt, class_id, if (values[0].is(.object)) Object.fromHeader(values[0].refHeader().?) else null, 2);
    return publishNativeFunctionMetadata(rt, function_object, name, length);
}

/// Construct a true QuickJS C_FUNCTION. The realm owner is installed before
/// any fallible metadata work, so a successfully published native function can
/// never exist without its construction RealmRef.
pub fn nativeFunction(realm: *RealmContext, name: []const u8, length: i32) !JSValue {
    const function_proto = realm.cached_function_proto orelse return error.InvalidBuiltinRegistry;
    return nativeFunctionWithPrototypeAndCapacity(realm, function_proto, name, length, 2);
}

/// Construct a true C function with its final `[[Prototype]]` and RealmRef in
/// place before any fallible metadata publication. Bootstrap uses the explicit
/// prototype form because Function.prototype itself must initially inherit
/// from Object.prototype; ordinary post-bootstrap producers pass the realm's
/// Function.prototype.
pub fn nativeFunctionWithPrototypeAndCapacity(
    realm: *RealmContext,
    prototype: ?*Object,
    name: []const u8,
    length: i32,
    capacity: usize,
) !JSValue {
    std.debug.assert(capacity >= 2);
    const rt = realm.runtime;
    var values = [_]JSValue{if (prototype) |object| object.value() else JSValue.nullValue()};
    const slots: []JSValue = &values;
    const slices = [_]runtime.ValueRootSlice{.{ .mutable = &slots }};
    const headers = [_]runtime.HeaderRootValue{.{ .header = &realm.header }};
    var roots = runtime.ValueRootFrame{ .slices = &slices, .headers = &headers };
    roots.activate(rt);
    defer roots.deactivate(rt);
    const function_object = try Object.createWithOwnPropertyCapacity(rt, class.ids.c_function, if (values[0].is(.object)) Object.fromHeader(values[0].refHeader().?) else null, capacity);
    function_object.setNativeFunctionRealm(realm);
    return publishNativeFunctionMetadata(rt, function_object, name, length);
}

/// Metadata publication can collect. Root the function and its name in all
/// builds, refresh the owner after allocation, and return the updated value.
fn publishNativeFunctionMetadata(
    rt: *JSRuntime,
    function_object: *Object,
    name: []const u8,
    length: i32,
) !JSValue {
    var values = [_]JSValue{ function_object.value(), JSValue.undefinedValue() };
    const slots: []JSValue = &values;
    const slices = [_]runtime.ValueRootSlice{.{ .mutable = &slots }};
    var roots = runtime.ValueRootFrame{ .slices = &slices };
    roots.activate(rt);
    defer roots.deactivate(rt);
    const length_key = atom.predefinedId("length", .string).?;
    try Object.fromHeader(values[0].refHeader().?).defineOwnPropertyAssumingNew(rt, length_key, Descriptor.data(JSValue.int32(length), .{ .configurable = true }));

    const name_string = if (name.len == 0)
        try rt.emptyString()
    else if (isAsciiBuiltinName(name))
        try string.String.createAscii(rt, name)
    else
        try string.String.createUtf8(rt, name);
    values[1] = name_string.value();

    const name_key = atom.predefinedId("name", .string).?;
    try Object.fromHeader(values[0].refHeader().?).defineOwnPropertyAssumingNew(rt, name_key, Descriptor.data(values[1], .{ .configurable = true }));

    const dispatch_atom = try rt.internAtom(name);
    // TGC S3 §2.3: this stores an atom id into a published function payload.
    Object.fromHeader(values[0].refHeader().?).nativeDispatchNameSlot().* = dispatch_atom;
    return values[0];
}

/// Construct a C_FUNCTION_DATA-style callable with the construction realm's
/// final Function.prototype, but without retaining that realm. Its callback
/// still executes in the caller realm; the prototype only fixes the function
/// object's construction-time surface and allocation topology.
pub fn nativeDataFunctionWithPrototype(
    rt: *JSRuntime,
    prototype: ?*Object,
    name: []const u8,
    length: i32,
) !JSValue {
    return nativeFunctionWithClass(rt, class.ids.c_function_data, prototype, name, length);
}

pub fn nativeFunctionForGlobal(rt: *JSRuntime, global: *Object, name: []const u8, length: i32) !JSValue {
    const realm = rt.contextForGlobalIncludingConstructing(global) orelse return error.InvalidBuiltinRegistry;
    const function_proto = realm.cached_function_proto orelse return error.InvalidBuiltinRegistry;
    return nativeFunctionWithPrototypeAndCapacity(realm, function_proto, name, length, 2);
}

/// Creates a fresh native function named `name`/arity `length` and installs it
/// as a `writable: true, enumerable: false, configurable: true` own data
/// property on `target` under the same key. This is the lazy method-install
/// primitive used when a Promise object is constructed without a shared
/// prototype (so `then`/`catch` must be materialized directly on the
/// instance). It depends only on core ops (`nativeDataFunctionWithPrototype` +
/// descriptor install), so engine-core callers may use it without reaching
/// into builtins. The C_FUNCTION_DATA callback retains caller-realm execution
/// semantics, while its construction-time object surface uses the supplied
/// realm's final Function.prototype. Returns the installed method so the
/// caller can write `nativeFunctionIdSlot` without a second Get.
pub fn defineNativeMethod(realm: *RealmContext, target: *Object, name: []const u8, length: i32) !JSValue {
    const rt = realm.runtime;
    var values = [_]JSValue{ target.value(), JSValue.undefinedValue() };
    const slots: []JSValue = &values;
    const slices = [_]runtime.ValueRootSlice{.{ .mutable = &slots }};
    const headers = [_]runtime.HeaderRootValue{.{ .header = &realm.header }};
    var roots = runtime.ValueRootFrame{ .slices = &slices, .headers = &headers };
    roots.activate(rt);
    defer roots.deactivate(rt);
    const function_proto = realm.cached_function_proto orelse return error.InvalidBuiltinRegistry;
    values[1] = try nativeDataFunctionWithPrototype(rt, function_proto, name, length);
    try defineMethodData(rt, Object.fromHeader(values[0].refHeader().?), name, values[1], true, false, true);
    return values[1];
}

fn defineMethodData(
    rt: *JSRuntime,
    target: *Object,
    name: []const u8,
    value: JSValue,
    writable: bool,
    enumerable: bool,
    configurable: bool,
) !void {
    var values = [_]JSValue{ target.value(), value };
    const slots: []JSValue = &values;
    const slices = [_]runtime.ValueRootSlice{.{ .mutable = &slots }};
    var root_frame = runtime.ValueRootFrame{ .slices = &slices };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const key = try rt.internAtom(name);
    // TGC S3 §4 class B: `defineOwnProperty` allocates (shape transition), so
    // the bare id has to be a root for the whole window.
    var key_roots = runtime.rootAtoms(.{&key});
    key_roots.activate(rt);
    defer key_roots.deactivate(rt);
    try Object.fromHeader(values[0].refHeader().?).defineOwnProperty(rt, key, Descriptor.data(values[1], .{ .writable = writable, .enumerable = enumerable, .configurable = configurable }));
}
