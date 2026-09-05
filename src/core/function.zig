//! Core native-builtin identities and function-object creation.
//!
//! Encoded builtin domains are stable dispatch metadata shared with exec, not
//! VM state.
//! QuickJS map: `JSFunctionBytecode` and function object data around
//! quickjs.c:619-713. Higher layers may consume this core module; it may not
//! import parser/exec/runtime/binding.

const atom = @import("atom.zig");
const JSValue = @import("value.zig").JSValue;
const Object = @import("object.zig").Object;
const Descriptor = @import("descriptor.zig").Descriptor;
const string = @import("string.zig");
const runtime = @import("runtime.zig");
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
    /// as their own function lists (`js_weakref_proto_funcs` quickjs.c:61197,
    /// `js_finrec_proto_funcs` quickjs.c:61376) rather than folding them into
    /// the Map/Set lists, so they get their own id namespace here too.
    weak_ref = 21,
};

/// Method ids for the `.host` native-builtin domain: host/web globals and
/// engine-internal helpers that have no spec namespace of their own (HTML
/// btoa/atob/queueMicrotask, the zjs `gc` helper, navigator accessors, host
/// constructor stubs, the shared `[Symbol.species]` getter, and the V8-style
/// CallSite methods).
pub const HostGlobalMethod = enum(u32) {
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

const native_builtin_domain_stride: i32 = 1024;

pub fn nativeBuiltinId(domain: NativeBuiltinDomain, id: u32) i32 {
    return @intFromEnum(domain) * native_builtin_domain_stride + @as(i32, @intCast(id));
}

pub fn decodeNativeBuiltinId(encoded: i32) ?NativeBuiltinRef {
    if (encoded <= 0) return null;
    const domain_code = @divTrunc(encoded, native_builtin_domain_stride);
    const local_id = @mod(encoded, native_builtin_domain_stride);
    if (local_id <= 0) return null;
    const domain: NativeBuiltinDomain = switch (domain_code) {
        1 => .math,
        2 => .number,
        3 => .string,
        4 => .date,
        5 => .array,
        6 => .regexp,
        7 => .collection,
        8 => .buffer,
        9 => .uri,
        10 => .performance,
        11 => .json,
        12 => .atomics,
        13 => .reflect,
        14 => .object,
        15 => .primitive,
        16 => .function,
        17 => .error_object,
        18 => .iterator,
        19 => .host,
        20 => .promise,
        21 => .weak_ref,
        else => return null,
    };
    return .{ .domain = domain, .id = @intCast(local_id) };
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
    const function_object = try Object.createWithOwnPropertyCapacity(rt, class_id, prototype, 2);
    try publishNativeFunctionMetadata(rt, function_object, name, length);
    return function_object.value();
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
    const function_object = try Object.createWithOwnPropertyCapacity(rt, class.ids.c_function, prototype, capacity);
    function_object.setNativeFunctionRealm(realm);
    try publishNativeFunctionMetadata(rt, function_object, name, length);
    return function_object.value();
}

/// Name, length, and dispatch-atom intern can collect. Exact-mark tests do
/// not treat the Zig `*Object` as a root unless it is named here; CLI STW
/// keeps conservative as backup for this scalar frame.
fn publishNativeFunctionMetadata(
    rt: *JSRuntime,
    function_object: *Object,
    name: []const u8,
    length: i32,
) !void {
    if (comptime runtime.value_root_frames_enabled) {
        var holder: ?*Object = function_object;
        var obj_roots = runtime.rootObjects(.{&holder});
        obj_roots.activate(rt);
        defer obj_roots.deactivate(rt);
        return publishNativeFunctionMetadataWork(rt, function_object, name, length);
    }
    return publishNativeFunctionMetadataWork(rt, function_object, name, length);
}

fn publishNativeFunctionMetadataWork(
    rt: *JSRuntime,
    function_object: *Object,
    name: []const u8,
    length: i32,
) !void {
    const length_key = atom.predefinedId("length", .string).?;
    try function_object.defineOwnPropertyAssumingNew(rt, length_key, Descriptor.data(JSValue.int32(length), false, false, true));

    const name_string = if (name.len == 0)
        try rt.emptyString()
    else if (isAsciiBuiltinName(name))
        try string.String.createAscii(rt, name)
    else
        try string.String.createUtf8(rt, name);
    const name_value = if (name.len == 0) name_string.value() else name_string.value();

    const name_key = atom.predefinedId("name", .string).?;
    try function_object.defineOwnPropertyAssumingNew(rt, name_key, Descriptor.data(name_value, false, false, true));

    const dispatch_atom = try rt.internAtom(name);
    // TGC S3 §2.3: this stores an atom id into a published function payload.
    rt.atoms.shadeAtomIfMarking(dispatch_atom);
    function_object.nativeDispatchNameSlot().* = dispatch_atom;
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
/// realm's final Function.prototype.
pub fn defineNativeMethod(realm: *RealmContext, target: *Object, name: []const u8, length: i32) !void {
    const rt = realm.runtime;
    const function_proto = realm.cached_function_proto orelse return error.InvalidBuiltinRegistry;
    const method = try nativeDataFunctionWithPrototype(rt, function_proto, name, length);
    try defineMethodData(rt, target, name, method, true, false, true);
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
    var target_value = target.value();
    var rooted_value = value;
    var root_frame = runtime.rootValues(.{ &target_value, &rooted_value });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const key = try rt.internAtom(name);
    // TGC S3 §4 class B: `defineOwnProperty` allocates (shape transition), so
    // the bare id has to be a root for the whole window.
    var key_roots = runtime.rootAtoms(.{&key});
    key_roots.activate(rt);
    defer key_roots.deactivate(rt);
    try target.defineOwnProperty(rt, key, Descriptor.data(rooted_value, writable, enumerable, configurable));
}
