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

const core = @import("../core/root.zig");

pub const Intrinsics = struct {
    global: *core.Object,

    pub fn init(rt: *core.Runtime) !Intrinsics {
        const global = try core.Object.create(rt, core.class.ids.object, null);
        errdefer global.value().free(rt);
        inline for (domains) |name| {
            const atom_id = try rt.internAtom(name);
            defer rt.atoms.free(atom_id);
            try global.defineOwnProperty(rt, atom_id, core.Descriptor.data(core.Value.undefinedValue(), true, false, true));
        }
        return .{ .global = global };
    }

    pub fn deinit(self: *Intrinsics, rt: *core.Runtime) void {
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
