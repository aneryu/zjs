const std = @import("std");
const core = @import("../core/root.zig");

/// Interned property name for binding/install-time dispatch.
///
/// Phase 1 treats this as a long-lived/static name owned by the caller. The
/// caller must release it when the owning binding/runtime state is destroyed.
pub const PropNameID = extern struct {
    value: u32 = 0,

    pub fn internStatic(rt: *core.JSRuntime, name: []const u8) !PropNameID {
        return .{ .value = try rt.internAtom(name) };
    }

    pub fn release(self: PropNameID, rt: *core.JSRuntime) void {
        rt.atoms.free(raw(self));
    }

    pub fn eql(self: PropNameID, other: PropNameID) bool {
        return self.value == other.value;
    }

    pub fn defineDataProperty(self: PropNameID, rt: *core.JSRuntime, object: *core.Object, descriptor: core.Descriptor) !void {
        try object.defineOwnProperty(rt, raw(self), descriptor);
    }

    pub fn getProperty(self: PropNameID, object: *core.Object) core.context.DynamicImportError!core.JSValue {
        return object.getProperty(raw(self));
    }

    pub fn debugName(self: PropNameID, rt: *core.JSRuntime) ?[]const u8 {
        return rt.atoms.name(raw(self));
    }
};

fn raw(id: PropNameID) core.Atom {
    return id.value;
}

test "PropNameID interns and releases a static property name" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const name = try PropNameID.internStatic(rt, "kernelName");
    defer name.release(rt);

    try std.testing.expect(name.eql(name));
    try std.testing.expectEqual(@sizeOf(u32), @sizeOf(PropNameID));
    try std.testing.expect(switch (@typeInfo(PropNameID)) {
        .@"struct" => true,
        else => false,
    });
    try std.testing.expectEqualStrings("kernelName", name.debugName(rt).?);
}
