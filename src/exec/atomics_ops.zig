//! Atomics namespace function-list metadata and typed record handler.
//!
//! Method bodies live in `atomics_wait.zig`, `call_runtime.zig`, and
//! `promise_ops.zig`; this module owns the QuickJS-style declaration table that
//! binds those bodies to the standard native-call ABI.

const std = @import("std");
const core = @import("../core/root.zig");
const atomics_wait = @import("atomics_wait.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call_runtime = @import("call_runtime.zig");
const HostError = @import("exceptions.zig").HostError;

pub const StaticMethod = atomics_wait.StaticMethod;

pub fn methodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "isLockFree")) return @intFromEnum(StaticMethod.is_lock_free);
    if (std.mem.eql(u8, name, "load")) return @intFromEnum(StaticMethod.load);
    if (std.mem.eql(u8, name, "store")) return @intFromEnum(StaticMethod.store);
    if (std.mem.eql(u8, name, "add")) return @intFromEnum(StaticMethod.add);
    if (std.mem.eql(u8, name, "sub")) return @intFromEnum(StaticMethod.sub);
    if (std.mem.eql(u8, name, "and")) return @intFromEnum(StaticMethod.@"and");
    if (std.mem.eql(u8, name, "or")) return @intFromEnum(StaticMethod.@"or");
    if (std.mem.eql(u8, name, "xor")) return @intFromEnum(StaticMethod.xor);
    if (std.mem.eql(u8, name, "exchange")) return @intFromEnum(StaticMethod.exchange);
    if (std.mem.eql(u8, name, "compareExchange")) return @intFromEnum(StaticMethod.compare_exchange);
    if (std.mem.eql(u8, name, "wait")) return @intFromEnum(StaticMethod.wait);
    if (std.mem.eql(u8, name, "waitAsync")) return @intFromEnum(StaticMethod.wait_async);
    if (std.mem.eql(u8, name, "notify")) return @intFromEnum(StaticMethod.notify);
    if (std.mem.eql(u8, name, "pause")) return @intFromEnum(StaticMethod.pause);
    return null;
}

/// QuickJS-style function-list entries for every `Atomics.*` method installed
/// by `standard_globals`. The domain uses one typed generic+magic handler; the
/// method id is carried as `magic` and selects the existing exec-owned body.
pub const internal_entries = [_]core.host_function.InternalEntry{
    atomicsEntry("add", 3, .add),
    atomicsEntry("and", 3, .@"and"),
    atomicsEntry("compareExchange", 4, .compare_exchange),
    atomicsEntry("exchange", 3, .exchange),
    atomicsEntry("isLockFree", 1, .is_lock_free),
    atomicsEntry("load", 2, .load),
    atomicsEntry("notify", 3, .notify),
    atomicsEntry("or", 3, .@"or"),
    atomicsEntry("pause", 0, .pause),
    atomicsEntry("store", 3, .store),
    atomicsEntry("sub", 3, .sub),
    atomicsEntry("wait", 4, .wait),
    atomicsEntry("waitAsync", 4, .wait_async),
    atomicsEntry("xor", 3, .xor),
};

fn atomicsEntry(
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
        .prepared_call_ok = false,
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(&atomicsCall),
    };
}

fn atomicsCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const global = host_call.global orelse return error.TypeError;
    return call_runtime.qjsAtomicsCallForNativeRecord(
        host_call.ctx,
        host_call.output,
        global,
        host_call.magic,
        host_call.args,
        builtin_dispatch.callerBytecode(host_call),
        builtin_dispatch.callerFrame(host_call),
    );
}
