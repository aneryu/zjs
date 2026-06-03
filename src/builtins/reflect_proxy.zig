const core = @import("../core/root.zig");
const std = @import("std");

pub const StaticMethod = enum(u32) {
    define_property = 1,
    get_own_property_descriptor = 2,
    delete_property = 3,
    get = 4,
    get_prototype_of = 5,
    set = 6,
    set_prototype_of = 7,
    is_extensible = 8,
    prevent_extensions = 9,
    has = 10,
    own_keys = 11,
    construct = 12,
    apply = 13,
};

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

pub fn ownKeys(rt: *core.JSRuntime, object: *core.Object) ![]core.Atom {
    return object.ownKeys(rt);
}

pub const RevocableProxy = struct {
    revoked: bool = false,

    pub fn revoke(self: *RevocableProxy) void {
        self.revoked = true;
    }
};
