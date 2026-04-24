const property = @import("property.zig");
const Value = @import("value.zig").Value;

pub const Kind = enum {
    generic,
    data,
    accessor,
};

pub const Descriptor = struct {
    kind: Kind = .generic,
    value: Value = Value.undefinedValue(),
    getter: Value = Value.undefinedValue(),
    setter: Value = Value.undefinedValue(),
    writable: ?bool = null,
    enumerable: ?bool = null,
    configurable: ?bool = null,

    pub fn data(value: Value, writable: bool, enumerable: bool, configurable: bool) Descriptor {
        return .{
            .kind = .data,
            .value = value,
            .writable = writable,
            .enumerable = enumerable,
            .configurable = configurable,
        };
    }

    pub fn accessor(getter: Value, setter: Value, enumerable: bool, configurable: bool) Descriptor {
        return .{
            .kind = .accessor,
            .getter = getter,
            .setter = setter,
            .enumerable = enumerable,
            .configurable = configurable,
        };
    }

    pub fn generic(enumerable: ?bool, configurable: ?bool) Descriptor {
        return .{
            .kind = .generic,
            .enumerable = enumerable,
            .configurable = configurable,
        };
    }

    pub fn fromEntry(entry: property.Entry) Descriptor {
        return switch (entry.slot) {
            .data => |value| .{
                .kind = .data,
                .value = value.dup(),
                .writable = entry.flags.writable,
                .enumerable = entry.flags.enumerable,
                .configurable = entry.flags.configurable,
            },
            .accessor => |accessor_entry| .{
                .kind = .accessor,
                .getter = accessor_entry.getter.dup(),
                .setter = accessor_entry.setter.dup(),
                .enumerable = entry.flags.enumerable,
                .configurable = entry.flags.configurable,
            },
            .deleted => .{},
        };
    }

    pub fn destroy(self: Descriptor, rt: anytype) void {
        self.value.free(rt);
        self.getter.free(rt);
        self.setter.free(rt);
    }
};
