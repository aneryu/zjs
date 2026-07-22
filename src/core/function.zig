const atom = @import("atom.zig");
const memory = @import("memory.zig");
const JSValue = @import("value.zig").JSValue;
const Object = @import("object.zig").Object;
const Descriptor = @import("descriptor.zig").Descriptor;
const property = @import("property.zig");
const string = @import("string.zig");
const runtime = @import("runtime.zig");
const JSRuntime = runtime.JSRuntime;
const RealmContext = @import("context.zig").RealmContext;
const class = @import("class.zig");
const std = @import("std");

fn dupOwnedValue(atoms: *atom.AtomTable, value: JSValue) JSValue {
    _ = atoms;
    return value.dup();
}

fn freeOwnedValue(atoms: *atom.AtomTable, value: JSValue, rt: anytype) void {
    _ = atoms;
    value.free(rt);
}

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
        else => return null,
    };
    return .{ .domain = domain, .id = @intCast(local_id) };
}

pub const Kind = enum {
    native,
    bytecode,
    bound,
};

pub const FunctionKind = enum {
    normal,
    generator,
    async_function,
    async_generator,
};

pub const NativeCall = *const fn () JSValue;

pub const NativeRecord = struct {
    name: atom.Atom = atom.null_atom,
    length: u16 = 0,
    call: ?NativeCall = null,
};

pub const BytecodeRecord = struct {
    name: atom.Atom = atom.null_atom,
    bytecode: []u8 = &.{},
    constants: []JSValue = &.{},
};

pub const BoundRecord = struct {
    target: JSValue = JSValue.undefinedValue(),
    this_value: JSValue = JSValue.undefinedValue(),
    args: []JSValue = &.{},
};

pub const FunctionRecord = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    kind: Kind,
    function_kind: FunctionKind = .normal,
    is_constructor: bool = false,
    home_object: JSValue = JSValue.undefinedValue(),
    payload: Payload,

    const Payload = union(Kind) {
        native: NativeRecord,
        bytecode: BytecodeRecord,
        bound: BoundRecord,
    };

    pub fn createNative(
        account: *memory.MemoryAccount,
        atoms: *atom.AtomTable,
        name: atom.Atom,
        length: u16,
        call: ?NativeCall,
        is_constructor: bool,
    ) FunctionRecord {
        return .{
            .memory = account,
            .atoms = atoms,
            .kind = .native,
            .is_constructor = is_constructor,
            .payload = .{ .native = .{
                .name = atoms.dup(name),
                .length = length,
                .call = call,
            } },
        };
    }

    pub fn createBytecode(
        account: *memory.MemoryAccount,
        atoms: *atom.AtomTable,
        name: atom.Atom,
        bytecode: []const u8,
        constants: []const JSValue,
        function_kind: FunctionKind,
        is_constructor: bool,
        home_object: JSValue,
    ) !FunctionRecord {
        const owned_code: []u8 = if (bytecode.len == 0)
            &.{}
        else blk: {
            const owned = try account.alloc(u8, bytecode.len);
            @memcpy(owned, bytecode);
            break :blk owned;
        };
        var owned_code_owned = owned_code.len != 0;
        errdefer if (owned_code_owned) account.free(u8, owned_code);

        const owned_constants: []JSValue = if (constants.len == 0)
            &.{}
        else blk: {
            const owned = try account.alloc(JSValue, constants.len);
            errdefer account.free(JSValue, owned);
            for (constants, owned) |constant, *slot| slot.* = dupOwnedValue(atoms, constant);
            break :blk owned;
        };

        owned_code_owned = false;
        return .{
            .memory = account,
            .atoms = atoms,
            .kind = .bytecode,
            .function_kind = function_kind,
            .is_constructor = is_constructor,
            .home_object = dupOwnedValue(atoms, home_object),
            .payload = .{ .bytecode = .{
                .name = atoms.dup(name),
                .bytecode = owned_code,
                .constants = owned_constants,
            } },
        };
    }

    pub fn createBound(
        account: *memory.MemoryAccount,
        atoms: *atom.AtomTable,
        target: JSValue,
        this_value: JSValue,
        args: []const JSValue,
        is_constructor: bool,
    ) !FunctionRecord {
        const owned_args: []JSValue = if (args.len == 0)
            &.{}
        else blk: {
            const owned = try account.alloc(JSValue, args.len);
            errdefer account.free(JSValue, owned);
            for (args, owned) |arg, *slot| slot.* = dupOwnedValue(atoms, arg);
            break :blk owned;
        };

        return .{
            .memory = account,
            .atoms = atoms,
            .kind = .bound,
            .is_constructor = is_constructor,
            .payload = .{ .bound = .{
                .target = dupOwnedValue(atoms, target),
                .this_value = dupOwnedValue(atoms, this_value),
                .args = owned_args,
            } },
        };
    }

    pub fn destroy(self: *FunctionRecord, rt: anytype) void {
        const account = self.memory;
        const atoms = self.atoms;
        const home_object = self.home_object;
        const payload = self.payload;
        self.* = .{
            .memory = account,
            .atoms = atoms,
            .kind = .native,
            .payload = .{ .native = .{} },
        };

        freeOwnedValue(atoms, home_object, rt);
        switch (payload) {
            .native => |record| {
                if (record.name != atom.null_atom) atoms.free(record.name);
            },
            .bytecode => |record| {
                if (record.name != atom.null_atom) atoms.free(record.name);
                for (record.constants) |*constant| {
                    const value = constant.*;
                    constant.* = JSValue.undefinedValue();
                    freeOwnedValue(atoms, value, rt);
                }
                if (record.constants.len != 0) account.free(JSValue, record.constants);
                if (record.bytecode.len != 0) account.free(u8, record.bytecode);
            },
            .bound => |record| {
                freeOwnedValue(atoms, record.target, rt);
                freeOwnedValue(atoms, record.this_value, rt);
                for (record.args) |*arg| {
                    const value = arg.*;
                    arg.* = JSValue.undefinedValue();
                    freeOwnedValue(atoms, value, rt);
                }
                if (record.args.len != 0) account.free(JSValue, record.args);
            },
        }
    }
};

fn isAsciiBuiltinName(bytes: []const u8) bool {
    for (bytes) |b| {
        if (b >= 0x80) return false;
    }
    return true;
}

fn nativeFunctionWithClass(rt: *JSRuntime, class_id: class.ClassId, name: []const u8, length: i32) !JSValue {
    const function_object = try Object.createWithOwnPropertyCapacity(rt, class_id, null, 2);
    errdefer function_object.value().free(rt);

    const length_key = atom.predefinedId("length", .string).?;
    try function_object.defineOwnPropertyAssumingNew(rt, length_key, Descriptor.data(JSValue.int32(length), false, false, true));

    const name_string = if (name.len == 0)
        try rt.emptyString()
    else if (isAsciiBuiltinName(name))
        try string.String.createAscii(rt, name)
    else
        try string.String.createUtf8(rt, name);
    const name_value = if (name.len == 0) name_string.value().dup() else name_string.value();
    defer name_value.free(rt);

    const name_key = atom.predefinedId("name", .string).?;
    try function_object.defineOwnPropertyAssumingNew(rt, name_key, Descriptor.data(name_value, false, false, true));

    function_object.nativeDispatchNameSlot().* = try rt.internAtom(name);

    return function_object.value();
}

/// Construct a true QuickJS C_FUNCTION. The realm owner is installed before
/// any fallible metadata work, so a successfully published native function can
/// never exist without its construction RealmRef.
pub fn nativeFunction(realm: *RealmContext, name: []const u8, length: i32) !JSValue {
    const rt = realm.runtime;
    const function_object = try Object.createWithOwnPropertyCapacity(rt, class.ids.c_function, null, 2);
    function_object.setNativeFunctionRealm(realm);
    errdefer function_object.value().free(rt);

    const length_key = atom.predefinedId("length", .string).?;
    try function_object.defineOwnPropertyAssumingNew(rt, length_key, Descriptor.data(JSValue.int32(length), false, false, true));

    const name_string = if (name.len == 0)
        try rt.emptyString()
    else if (isAsciiBuiltinName(name))
        try string.String.createAscii(rt, name)
    else
        try string.String.createUtf8(rt, name);
    const name_value = if (name.len == 0) name_string.value().dup() else name_string.value();
    defer name_value.free(rt);

    const name_key = atom.predefinedId("name", .string).?;
    try function_object.defineOwnPropertyAssumingNew(rt, name_key, Descriptor.data(name_value, false, false, true));

    function_object.nativeDispatchNameSlot().* = try rt.internAtom(name);
    return function_object.value();
}

/// Construct a QuickJS C_FUNCTION_DATA-style carrier. It deliberately owns no
/// realm; its callback receives the caller's RealmContext at dispatch time.
pub fn nativeDataFunction(rt: *JSRuntime, name: []const u8, length: i32) !JSValue {
    return nativeFunctionWithClass(rt, class.ids.c_function_data, name, length);
}

pub fn nativeFunctionForGlobal(rt: *JSRuntime, global: *Object, name: []const u8, length: i32) !JSValue {
    const realm = rt.contextForGlobalIncludingConstructing(global) orelse return error.InvalidBuiltinRegistry;
    return nativeFunction(realm, name, length);
}

/// `name` must outlive the function object. This is intended for standard
/// builtin tables whose names have static storage.
pub fn nativeFunctionWithLazyName(realm: *RealmContext, name: []const u8, length: i32) !JSValue {
    return nativeFunctionWithLazyNameAndCapacity(realm, name, length, 2);
}

/// `name` must outlive the function object. This is intended for standard
/// builtin tables whose names have static storage.
pub fn nativeFunctionWithLazyNameAndCapacity(realm: *RealmContext, name: []const u8, length: i32, capacity: usize) !JSValue {
    std.debug.assert(capacity >= 2);
    const rt = realm.runtime;
    const function_object = try Object.createWithOwnPropertyCapacity(rt, class.ids.c_function, null, capacity);
    function_object.setNativeFunctionRealm(realm);
    errdefer function_object.value().free(rt);

    const length_key = atom.predefinedId("length", .string).?;
    try function_object.defineOwnPropertyAssumingNew(rt, length_key, Descriptor.data(JSValue.int32(length), false, false, true));

    const name_key = atom.predefinedId("name", .string).?;
    const name_flags = property.Flags.data(false, false, true);
    try function_object.defineStringConstantAutoInitProperty(rt, name_key, name, name_flags);

    function_object.nativeDispatchNameSlot().* = try rt.internAtom(name);

    return function_object.value();
}

/// Creates a fresh native function named `name`/arity `length` and installs it
/// as a `writable: true, enumerable: false, configurable: true` own data
/// property on `target` under the same key. This is the lazy method-install
/// primitive used when a Promise object is constructed without a shared
/// prototype (so `then`/`catch` must be materialized directly on the
/// instance). It depends only on core ops (`nativeDataFunction` + descriptor
/// install), so engine-core callers may use it without reaching into builtins.
/// These fallback methods have no construction realm to own, so they use the
/// caller-realm C_FUNCTION_DATA carrier instead of manufacturing a realm-less
/// true C_FUNCTION.
pub fn defineNativeMethod(rt: *JSRuntime, target: *Object, name: []const u8, length: i32) !void {
    const method = try nativeDataFunction(rt, name, length);
    defer method.free(rt);
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
    var root_values = [_]runtime.ValueRootValue{
        .{ .value = &target_value },
        .{ .value = &rooted_value },
    };
    const root_frame = runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try target.defineOwnProperty(rt, key, Descriptor.data(rooted_value, writable, enumerable, configurable));
}
