const gc = @import("gc.zig");
const Runtime = @import("runtime.zig").Runtime;
const Value = @import("value.zig").Value;

pub const String = struct {
    header: gc.Header,
    bytes: []u8,
    hash: u32,
    is_wide: bool = false,

    /// Returns an owned runtime string. The runtime releases it through
    /// reference counting when all `Value` handles are freed.
    pub fn createAscii(rt: *Runtime, bytes: []const u8) !*String {
        const self = try rt.memory.create(String);
        errdefer rt.memory.destroy(String, self);

        const owned = try rt.memory.alloc(u8, bytes.len);
        errdefer rt.memory.free(u8, owned);
        @memcpy(owned, bytes);

        self.* = .{
            .header = .{ .kind = .string },
            .bytes = owned,
            .hash = hashBytes(bytes),
        };
        return self;
    }

    pub fn value(self: *String) Value {
        return Value.string(&self.header);
    }

    pub fn eql(self: String, bytes: []const u8) bool {
        return std.mem.eql(u8, self.bytes, bytes);
    }

    pub fn destroyFromHeader(rt: *Runtime, header: *gc.Header) void {
        const self: *String = @fieldParentPtr("header", header);
        rt.memory.free(u8, self.bytes);
        rt.memory.destroy(String, self);
    }
};

pub fn hashBytes(bytes: []const u8) u32 {
    return @truncate(std.hash.Wyhash.hash(0, bytes));
}

const std = @import("std");
