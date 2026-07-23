const core = @import("../core/root.zig");
const std = @import("std");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call = @import("call.zig");
const call_runtime = @import("call_runtime.zig");
const exceptions = @import("exceptions.zig");
const reflect_ops = @import("reflect_ops.zig");

const HostError = exceptions.HostError;

pub const StaticMethod = core.host_function.builtin_method_ids.reflect.StaticMethod;

pub fn methodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "defineProperty")) return @intFromEnum(StaticMethod.define_property);
    if (std.mem.eql(u8, name, "getOwnPropertyDescriptor")) return @intFromEnum(StaticMethod.get_own_property_descriptor);
    if (std.mem.eql(u8, name, "deleteProperty")) return @intFromEnum(StaticMethod.delete_property);
    if (std.mem.eql(u8, name, "get")) return @intFromEnum(StaticMethod.get);
    if (std.mem.eql(u8, name, "getPrototypeOf")) return @intFromEnum(StaticMethod.get_prototype_of);
    if (std.mem.eql(u8, name, "set")) return @intFromEnum(StaticMethod.set);
    if (std.mem.eql(u8, name, "setPrototypeOf")) return @intFromEnum(StaticMethod.set_prototype_of);
    if (std.mem.eql(u8, name, "isExtensible")) return @intFromEnum(StaticMethod.is_extensible);
    if (std.mem.eql(u8, name, "preventExtensions")) return @intFromEnum(StaticMethod.prevent_extensions);
    if (std.mem.eql(u8, name, "has")) return @intFromEnum(StaticMethod.has);
    if (std.mem.eql(u8, name, "ownKeys")) return @intFromEnum(StaticMethod.own_keys);
    if (std.mem.eql(u8, name, "construct")) return @intFromEnum(StaticMethod.construct);
    if (std.mem.eql(u8, name, "apply")) return @intFromEnum(StaticMethod.apply);
    return null;
}

/// Declaration + dispatch table for the `.reflect` native-builtin domain
/// (the `Reflect.*` statics plus the `Proxy.revocable` constructor helper and
/// its revoke closure). One shared record handler `reflectCall` switches on the
/// per-record `magic` (== domain-local `StaticMethod` id) and forwards to the
/// reflective exec VM ops, which stay in exec because the proxy trap core and
/// the object internal ops they call (`object.defineOwnProperty`, proxy trap
/// dispatch, property lookups) are also reached from opcode handlers. `id`
/// doubles as `magic`, so the record carries no extra selector.
///
/// Standard-global bootstrap resolves names/lengths through its Reflect method
/// list and `methodId`; `proxy_revocable` and the dynamically materialized
/// `proxy_revoke` closure bind through `reflect_ops.proxyRevocable` directly.
/// This array is consumed by the record-dispatch path (`rt.internal_builtins`).
pub const internal_entries = reflectEntries: {
    const Entry = core.host_function.InternalEntry;
    break :reflectEntries [_]Entry{
        reflectEntry("apply", 3, @intFromEnum(StaticMethod.apply)),
        reflectEntry("construct", 2, @intFromEnum(StaticMethod.construct)),
        reflectEntry("defineProperty", 3, @intFromEnum(StaticMethod.define_property)),
        reflectEntry("deleteProperty", 2, @intFromEnum(StaticMethod.delete_property)),
        reflectEntry("get", 2, @intFromEnum(StaticMethod.get)),
        reflectEntry("getOwnPropertyDescriptor", 2, @intFromEnum(StaticMethod.get_own_property_descriptor)),
        reflectEntry("getPrototypeOf", 1, @intFromEnum(StaticMethod.get_prototype_of)),
        reflectEntry("has", 2, @intFromEnum(StaticMethod.has)),
        reflectEntry("isExtensible", 1, @intFromEnum(StaticMethod.is_extensible)),
        reflectEntry("ownKeys", 1, @intFromEnum(StaticMethod.own_keys)),
        reflectEntry("preventExtensions", 1, @intFromEnum(StaticMethod.prevent_extensions)),
        reflectEntry("set", 3, @intFromEnum(StaticMethod.set)),
        reflectEntry("setPrototypeOf", 2, @intFromEnum(StaticMethod.set_prototype_of)),
        reflectEntry("revocable", 2, @intFromEnum(StaticMethod.proxy_revocable)),
        reflectEntry("revoke", 0, @intFromEnum(StaticMethod.proxy_revoke)),
    };
};

fn reflectEntry(comptime name: []const u8, comptime length: u8, comptime id: u32) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&reflectCall),
    };
}

/// Shared record handler for the `.reflect` domain. Mirrors the retired
/// `call.zig` `callReflectNativeFunctionRecord`: the `Proxy.revocable` helper
/// and its revoke closure run their exec reflect ops, while the 13 `Reflect.*`
/// statics route through `call_runtime.qjsReflectCallForNativeRecord`. These
/// records have no algorithmic func-object-free reuse: every entry is an
/// observable callable and therefore requires its atomic call realm view.
fn reflectCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const ctx = host_call.ctx;
    const output = host_call.output;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == ctx);
    const global = realm.global;
    const id: u32 = host_call.magic;
    const args = host_call.args;
    const caller_function = builtin_dispatch.callerBytecode(host_call);
    const caller_frame = builtin_dispatch.callerFrame(host_call);

    if (id == @intFromEnum(StaticMethod.proxy_revoke)) {
        const function_object = host_call.func_obj orelse return error.TypeError;
        return reflect_ops.revokeProxy(ctx.runtime, function_object);
    }
    if (id == @intFromEnum(StaticMethod.proxy_revocable)) {
        // qjs js_proxy_revocable (quickjs.c:51502) is a plain JS_CFUNC_DEF that
        // never reads this_val: detached/rebound calls (`const {revocable} =
        // Proxy; revocable(t, h)`) work. No receiver validation.
        return reflect_ops.proxyRevocable(ctx.runtime, global, args);
    }
    return try call_runtime.qjsReflectCallForNativeRecord(ctx, output, global, id, args, caller_function, caller_frame);
}

pub fn ownKeys(rt: *core.JSRuntime, object: *core.Object) ![]core.Atom {
    return object.ownKeys(rt);
}

pub const RevocableProxy = struct {
    revoked: bool = false,

    pub fn revoke(self: *RevocableProxy) void {
        self.revoked = true;
    }
};
