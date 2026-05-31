const std = @import("std");

pub const Result = struct {
    value_index: usize,
    done: bool,
};

pub const AccessorMethod = enum(u32) {
    constructor_getter = 1,
    constructor_setter = 2,
    to_string_tag_getter = 3,
    to_string_tag_setter = 4,
};

pub const StaticMethod = enum(u32) {
    from = 101,
    concat = 102,
    zip = 103,
    zip_keyed = 104,
};

pub const PrototypeMethod = enum(u32) {
    to_array = 201,
    every = 202,
    find = 203,
    for_each = 204,
    reduce = 205,
    some = 206,
    map = 207,
    filter = 208,
    take = 209,
    drop = 210,
    flat_map = 211,
    dispose = 212,
};

pub fn staticMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "from")) return @intFromEnum(StaticMethod.from);
    if (std.mem.eql(u8, name, "concat")) return @intFromEnum(StaticMethod.concat);
    if (std.mem.eql(u8, name, "zip")) return @intFromEnum(StaticMethod.zip);
    if (std.mem.eql(u8, name, "zipKeyed")) return @intFromEnum(StaticMethod.zip_keyed);
    return null;
}

pub fn prototypeMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "toArray")) return @intFromEnum(PrototypeMethod.to_array);
    if (std.mem.eql(u8, name, "every")) return @intFromEnum(PrototypeMethod.every);
    if (std.mem.eql(u8, name, "find")) return @intFromEnum(PrototypeMethod.find);
    if (std.mem.eql(u8, name, "forEach")) return @intFromEnum(PrototypeMethod.for_each);
    if (std.mem.eql(u8, name, "reduce")) return @intFromEnum(PrototypeMethod.reduce);
    if (std.mem.eql(u8, name, "some")) return @intFromEnum(PrototypeMethod.some);
    if (std.mem.eql(u8, name, "map")) return @intFromEnum(PrototypeMethod.map);
    if (std.mem.eql(u8, name, "filter")) return @intFromEnum(PrototypeMethod.filter);
    if (std.mem.eql(u8, name, "take")) return @intFromEnum(PrototypeMethod.take);
    if (std.mem.eql(u8, name, "drop")) return @intFromEnum(PrototypeMethod.drop);
    if (std.mem.eql(u8, name, "flatMap")) return @intFromEnum(PrototypeMethod.flat_map);
    return null;
}

pub fn next(index: *usize, length: usize) Result {
    if (index.* >= length) return .{ .value_index = index.*, .done = true };
    const current = index.*;
    index.* += 1;
    return .{ .value_index = current, .done = false };
}
