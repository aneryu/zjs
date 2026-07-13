//! Atomics namespace method-id metadata owned by exec. Method bodies live in
//! `atomics_wait.zig` and `call_runtime.zig`.

const std = @import("std");
const atomics_wait = @import("atomics_wait.zig");

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
