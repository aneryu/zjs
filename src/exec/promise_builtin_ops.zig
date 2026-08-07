//! Internal-record declarations for Promise static methods.
//!
//! QuickJS stores its Promise static bodies in `JSCFunctionListEntry` records.
//! zjs keeps the specialized `Promise.resolve` handler and routes the remaining
//! statics through one typed generic+magic handler into their shared capability
//! machinery.

const std = @import("std");
const core = @import("../core/root.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const promise_ops = @import("promise_ops.zig");

const HostError = @import("exceptions.zig").HostError;
const StaticMethod = core.host_function.builtin_method_ids.promise.LegacyStaticMethod;
const PrototypeMethod = core.host_function.builtin_method_ids.promise.PrototypeMethod;

pub const internal_entries = [_]core.host_function.InternalEntry{
    .{
        .name = "resolve",
        .length = 1,
        .id = @intFromEnum(StaticMethod.resolve),
        .magic = @intFromEnum(StaticMethod.resolve),
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&promiseResolveCall),
    },
    promiseStaticEntry("all", 1, .all),
    promiseStaticEntry("race", 1, .race),
    promiseStaticEntry("reject", 1, .reject),
    promiseStaticEntry("allSettled", 1, .all_settled),
    promiseStaticEntry("any", 1, .any),
    promiseStaticEntry("try", 1, .try_),
    promiseStaticEntry("withResolvers", 0, .with_resolvers),
    promiseStaticEntry("allKeyed", 1, .all_keyed),
    promiseStaticEntry("allSettledKeyed", 1, .all_settled_keyed),
    // qjs js_promise_proto_funcs (quickjs.c:54376).
    promisePrototypeEntry("then", 2, .then),
    promisePrototypeEntry("catch", 1, .catch_),
    promisePrototypeEntry("finally", 1, .finally),
};

fn promiseStaticEntry(
    comptime name: []const u8,
    comptime length: u8,
    comptime method: StaticMethod,
) core.host_function.InternalEntry {
    const id: u32 = @intFromEnum(method);
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&promiseStaticCall),
    };
}

fn promisePrototypeEntry(
    comptime name: []const u8,
    comptime length: u8,
    comptime method: PrototypeMethod,
) core.host_function.InternalEntry {
    const id: u32 = @intFromEnum(method);
    return .{
        .name = name,
        .length = length,
        .id = id,
        .magic = @intCast(id),
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&promisePrototypeCall),
    };
}

/// Shared record handler for `Promise.prototype.then` / `catch` / `finally`
/// (qjs `js_promise_proto_funcs`, quickjs.c:54376). The magic only selects
/// which of the three method names `qjsPromiseThen` branches on, so the whole
/// body -- the `JS_GetOpaque2` receiver check (quickjs.c:54253), the
/// `JS_SpeciesConstructor` derivation (quickjs.c:54257), `catch`'s
/// unconditional `JS_Invoke(this, "then", ...)` re-entry (quickjs.c:54275) and
/// `finally`'s thunk construction (quickjs.c:54329) -- is bit-for-bit the same
/// code the name cascade reached.
fn promisePrototypeCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    const method_name: []const u8 = switch (host_call.magic) {
        @intFromEnum(PrototypeMethod.then) => "then",
        @intFromEnum(PrototypeMethod.catch_) => "catch",
        @intFromEnum(PrototypeMethod.finally) => "finally",
        else => return error.TypeError,
    };
    const result = try promise_ops.qjsPromiseThen(
        host_call.ctx,
        host_call.output,
        realm.global,
        host_call.this_value,
        method_name,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    );
    // `qjsPromiseThen` only reports "not mine" for callers that reached it by
    // name; every id routed here is one of its three methods.
    return result orelse error.TypeError;
}

fn promiseResolveCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == host_call.ctx);
    return promise_ops.qjsPromiseResolveStaticCall(
        host_call.ctx,
        host_call.output,
        realm.global,
        host_call.this_value,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    );
}

fn promiseStaticCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == host_call.ctx);
    const mode: promise_ops.PromiseStaticMode = switch (host_call.magic) {
        @intFromEnum(StaticMethod.all) => .all,
        @intFromEnum(StaticMethod.race) => .race,
        @intFromEnum(StaticMethod.reject) => .reject,
        @intFromEnum(StaticMethod.all_settled) => .all_settled,
        @intFromEnum(StaticMethod.any) => .any,
        @intFromEnum(StaticMethod.try_) => .try_,
        @intFromEnum(StaticMethod.with_resolvers) => .with_resolvers,
        @intFromEnum(StaticMethod.all_keyed) => .all_keyed,
        @intFromEnum(StaticMethod.all_settled_keyed) => .all_settled_keyed,
        else => return error.TypeError,
    };
    return promise_ops.qjsPromiseStaticCall(
        host_call.ctx,
        host_call.output,
        realm.global,
        host_call.this_value,
        host_call.args,
        mode,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    );
}
