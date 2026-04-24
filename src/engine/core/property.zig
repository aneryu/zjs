const atom = @import("atom.zig");
const Value = @import("value.zig").Value;

pub const Flags = packed struct(u6) {
    writable: bool = false,
    enumerable: bool = false,
    configurable: bool = false,
    accessor: bool = false,
    deleted: bool = false,
    reserved: bool = false,

    pub fn data(writable: bool, enumerable: bool, configurable: bool) Flags {
        return .{
            .writable = writable,
            .enumerable = enumerable,
            .configurable = configurable,
        };
    }

    pub fn accessorFlags(enumerable: bool, configurable: bool) Flags {
        return .{
            .enumerable = enumerable,
            .configurable = configurable,
            .accessor = true,
        };
    }

    pub fn bits(self: Flags) u6 {
        return @bitCast(self);
    }

    pub fn fromBits(bits_value: u6) Flags {
        return @bitCast(bits_value);
    }
};

pub const Accessor = struct {
    getter: Value = Value.undefinedValue(),
    setter: Value = Value.undefinedValue(),
};

pub const Slot = union(enum) {
    data: Value,
    accessor: Accessor,
    deleted,

    pub fn destroy(self: Slot, rt: anytype) void {
        switch (self) {
            .data => |value| value.free(rt),
            .accessor => |entry| {
                entry.getter.free(rt);
                entry.setter.free(rt);
            },
            .deleted => {},
        }
    }

    pub fn dup(self: Slot) Slot {
        return switch (self) {
            .data => |value| .{ .data = value.dup() },
            .accessor => |entry| .{ .accessor = .{
                .getter = entry.getter.dup(),
                .setter = entry.setter.dup(),
            } },
            .deleted => .deleted,
        };
    }
};

pub const Entry = struct {
    atom_id: atom.Atom = atom.null_atom,
    flags: Flags = .{},
    slot: Slot = .deleted,
};
