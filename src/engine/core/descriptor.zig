const property = @import("property.zig");
const JSValue = @import("value.zig").JSValue;

pub const Kind = enum {
    generic,
    data,
    accessor,
};

pub const Descriptor = struct {
    kind: Kind = .generic,
    value: JSValue = JSValue.undefinedValue(),
    value_present: bool = false,
    getter: JSValue = JSValue.undefinedValue(),
    getter_present: bool = false,
    setter: JSValue = JSValue.undefinedValue(),
    setter_present: bool = false,
    writable: ?bool = null,
    enumerable: ?bool = null,
    configurable: ?bool = null,

    pub fn data(value: JSValue, writable: bool, enumerable: bool, configurable: bool) Descriptor {
        return .{
            .kind = .data,
            .value = value,
            .value_present = true,
            .writable = writable,
            .enumerable = enumerable,
            .configurable = configurable,
        };
    }

    pub fn accessor(getter: JSValue, setter: JSValue, enumerable: bool, configurable: bool) Descriptor {
        return .{
            .kind = .accessor,
            .getter = getter,
            .getter_present = true,
            .setter = setter,
            .setter_present = true,
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
                .value_present = true,
                .writable = entry.flags.writable,
                .enumerable = entry.flags.enumerable,
                .configurable = entry.flags.configurable,
            },
            .accessor => |accessor_entry| .{
                .kind = .accessor,
                .getter = accessor_entry.getter.dup(),
                .getter_present = true,
                .setter = accessor_entry.setter.dup(),
                .setter_present = true,
                .enumerable = entry.flags.enumerable,
                .configurable = entry.flags.configurable,
            },
            // Callers must materialize an `.auto_init` slot before
            // converting it to a descriptor (`Object.getOwnProperty`
            // and the like trigger materialization on the slot itself
            // before reaching `fromEntry`). Reaching this arm would
            // mean a `.data`-shaped entry was promised but the slot
            // is still a placeholder.
            .auto_init => unreachable,
            .deleted => .{},
        };
    }

    pub fn destroy(self: Descriptor, rt: anytype) void {
        self.value.free(rt);
        self.getter.free(rt);
        self.setter.free(rt);
    }
};
