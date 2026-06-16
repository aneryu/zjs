//! Install-time name dispatch for the `Atomics` namespace. The `StaticMethod`
//! selector and the lock-free predicate are VM-core primitives that live in
//! `exec/atomics_wait.zig` (QuickJS keeps the Atomics wait mechanism in the
//! engine); this module only re-exports the selector and maps method names to
//! ids for the registry's namespace binding (builtins -> exec is legal under
//! the Phase 6 client model).

const std = @import("std");
const atomics_wait = @import("../exec/atomics_wait.zig");

pub const StaticMethod = atomics_wait.StaticMethod;

pub fn methodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "add")) return @intFromEnum(StaticMethod.add);
    if (std.mem.eql(u8, name, "and")) return @intFromEnum(StaticMethod.@"and");
    if (std.mem.eql(u8, name, "compareExchange")) return @intFromEnum(StaticMethod.compare_exchange);
    if (std.mem.eql(u8, name, "exchange")) return @intFromEnum(StaticMethod.exchange);
    if (std.mem.eql(u8, name, "isLockFree")) return @intFromEnum(StaticMethod.is_lock_free);
    if (std.mem.eql(u8, name, "load")) return @intFromEnum(StaticMethod.load);
    if (std.mem.eql(u8, name, "notify")) return @intFromEnum(StaticMethod.notify);
    if (std.mem.eql(u8, name, "or")) return @intFromEnum(StaticMethod.@"or");
    if (std.mem.eql(u8, name, "pause")) return @intFromEnum(StaticMethod.pause);
    if (std.mem.eql(u8, name, "store")) return @intFromEnum(StaticMethod.store);
    if (std.mem.eql(u8, name, "sub")) return @intFromEnum(StaticMethod.sub);
    if (std.mem.eql(u8, name, "wait")) return @intFromEnum(StaticMethod.wait);
    if (std.mem.eql(u8, name, "waitAsync")) return @intFromEnum(StaticMethod.wait_async);
    if (std.mem.eql(u8, name, "xor")) return @intFromEnum(StaticMethod.xor);
    return null;
}
