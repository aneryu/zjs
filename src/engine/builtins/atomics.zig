const std = @import("std");

pub const StaticMethod = enum(u32) {
    add = 1,
    @"and" = 2,
    compare_exchange = 3,
    exchange = 4,
    is_lock_free = 5,
    load = 6,
    notify = 7,
    @"or" = 8,
    pause = 9,
    store = 10,
    sub = 11,
    wait = 12,
    wait_async = 13,
    xor = 14,
};

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

pub fn isLockFree(size: usize) bool {
    return size == 1 or size == 2 or size == 4 or size == 8;
}
