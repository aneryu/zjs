pub const subsystem_name = "builtins";

pub const object = @import("object.zig");
pub const function = @import("function.zig");
pub const array = @import("array.zig");
pub const string = @import("string.zig");
pub const number = @import("number.zig");
pub const boolean = @import("boolean.zig");
pub const symbol = @import("symbol.zig");
pub const bigint = @import("bigint.zig");
pub const math = @import("math.zig");
pub const date = @import("date.zig");
pub const json = @import("json.zig");
pub const uri = @import("uri.zig");
pub const regexp = @import("regexp.zig");
pub const error_ = @import("error.zig");
pub const promise = @import("promise.zig");
pub const collection = @import("collection.zig");
pub const buffer = @import("buffer.zig");
pub const reflect_proxy = @import("reflect_proxy.zig");
pub const iterator = @import("iterator.zig");
pub const atomics = @import("atomics.zig");
pub const registry = @import("registry.zig");

const core = @import("../core/root.zig");

pub const Intrinsics = struct {
    global: *core.Object,

    pub fn init(rt: *core.JSRuntime) !Intrinsics {
        const global = try core.Object.createWithOwnPropertyCapacity(
            rt,
            core.class.ids.object,
            null,
            registry.standardGlobalOwnPropertyCapacity(),
        );
        errdefer global.value().free(rt);
        try registry.installStandardGlobals(rt, global);
        return .{ .global = global };
    }

    pub fn deinit(self: *Intrinsics, rt: *core.JSRuntime) void {
        self.global.value().free(rt);
    }
};

pub const domains = [_][]const u8{
    "Object",
    "Function",
    "Array",
    "String",
    "Number",
    "Boolean",
    "Symbol",
    "BigInt",
    "Math",
    "Date",
    "JSON",
    "RegExp",
    "Error",
    "Promise",
    "Map",
    "Set",
    "WeakMap",
    "WeakSet",
    "ArrayBuffer",
    "TypedArray",
    "DataView",
    "Reflect",
    "Proxy",
    "Iterator",
    "Atomics",
};

test "intrinsic bootstrap registers global builtin domains through object properties" {
    const std = @import("std");

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    var intrinsics = try Intrinsics.init(rt);
    defer intrinsics.deinit(rt);

    for (domains) |name| {
        const atom_id = try rt.internAtom(name);
        defer rt.atoms.free(atom_id);
        try std.testing.expect(intrinsics.global.hasOwnProperty(atom_id));
        const desc = intrinsics.global.getOwnProperty(rt, atom_id).?;
        defer desc.destroy(rt);
        try std.testing.expectEqual(true, desc.writable.?);
        try std.testing.expectEqual(false, desc.enumerable.?);
        try std.testing.expectEqual(true, desc.configurable.?);
    }

    const map_atom = try rt.internAtom("Map");
    defer rt.atoms.free(map_atom);
    const map_ctor = intrinsics.global.getProperty(map_atom);
    defer map_ctor.free(rt);
    try std.testing.expect(map_ctor.isObject());
    const map_ctor_object: *core.Object = @fieldParentPtr("header", map_ctor.refHeader().?);
    try std.testing.expectEqual(core.class.ids.c_function, map_ctor_object.class_id);

    const prototype_atom = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_atom);
    const prototype_desc = map_ctor_object.getOwnProperty(rt, prototype_atom).?;
    defer prototype_desc.destroy(rt);
    try std.testing.expectEqual(false, prototype_desc.writable.?);
    try std.testing.expectEqual(false, prototype_desc.enumerable.?);
    try std.testing.expectEqual(false, prototype_desc.configurable.?);
    try std.testing.expect(prototype_desc.value.isObject());
    const map_proto: *core.Object = @fieldParentPtr("header", prototype_desc.value.refHeader().?);
    try std.testing.expectEqual(core.class.ids.object, map_proto.class_id);

    const set_atom = try rt.internAtom("set");
    defer rt.atoms.free(set_atom);
    const set_desc = map_proto.getOwnProperty(rt, set_atom).?;
    defer set_desc.destroy(rt);
    try std.testing.expectEqual(true, set_desc.writable.?);
    try std.testing.expectEqual(false, set_desc.enumerable.?);
    try std.testing.expectEqual(true, set_desc.configurable.?);
    try std.testing.expect(set_desc.value.isObject());
    const set_func_obj: *core.Object = @fieldParentPtr("header", set_desc.value.refHeader().?);
    try std.testing.expectEqual(core.class.ids.c_function, set_func_obj.class_id);
}
