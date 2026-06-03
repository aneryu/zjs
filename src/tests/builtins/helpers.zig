const std = @import("std");
const engine = @import("quickjs_zig_engine");
const core = engine.core;

pub fn fillOwnPropertyStorage(rt: *core.JSRuntime, object: *core.Object) !void {
    var index: usize = 0;
    while (object.properties.len < object.property_capacity or object.shape_ref.prop_count < object.shape_ref.props.len) : (index += 1) {
        if (index > 512) return error.TestUnexpectedResult;
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "fill_{d}", .{index});
        const atom_id = try rt.internAtom(name);
        try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(core.JSValue.int32(@intCast(index)), true, true, true));
        rt.atoms.free(atom_id);
    }
}

pub fn expectStringValue(rt: *core.JSRuntime, expected: []const u8, value: core.JSValue) !void {
    defer value.free(rt);
    try std.testing.expect(value.isString());
    const header = value.refHeader().?;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    try std.testing.expect(string_value.eqlBytes(expected));
}

pub fn expectStringValueContains(rt: *core.JSRuntime, expected: []const u8, value: core.JSValue) !void {
    defer value.free(rt);
    try std.testing.expect(value.isString());
    const header = value.refHeader().?;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    const bytes = string_value.borrowLatin1() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
}

pub fn expectSameStringValue(expected: core.JSValue, actual: core.JSValue) !void {
    try std.testing.expect(expected.isString());
    try std.testing.expect(actual.isString());
    const expected_header = expected.refHeader().?;
    const actual_header = actual.refHeader().?;
    const expected_string: *core.string.String = @fieldParentPtr("header", expected_header);
    const actual_string: *core.string.String = @fieldParentPtr("header", actual_header);
    try std.testing.expect(expected_string.eqlString(actual_string.*));
}

pub fn keepOnlyIdentityLive(context: ?*anyopaque, key_identity: usize) bool {
    const live: *usize = @ptrCast(@alignCast(context.?));
    return key_identity == live.*;
}

pub fn expectNumberValue(rt: *core.JSRuntime, expected: f64, value: core.JSValue) !void {
    defer value.free(rt);
    try std.testing.expectEqual(expected, numberValue(value).?);
}

pub fn expectObjectClass(value: core.JSValue, expected: core.ClassId) !void {
    try std.testing.expect(value.isObject());
    const object = objectFromValue(value);
    try std.testing.expectEqual(expected, object.class_id);
}

pub fn objectFromValue(value: core.JSValue) *core.Object {
    const header = value.refHeader().?;
    return @fieldParentPtr("header", header);
}

pub fn expectObjectPropertyClass(rt: *core.JSRuntime, object_value: core.JSValue, name: []const u8, expected: core.ClassId) !void {
    try std.testing.expect(object_value.isObject());
    const object = objectFromValue(object_value);
    const atom_id = try rt.internAtom(name);
    defer rt.atoms.free(atom_id);
    const value = object.getProperty(atom_id);
    defer value.free(rt);
    try expectObjectClass(value, expected);
}

pub fn expectIntProperty(rt: *core.JSRuntime, object_value: core.JSValue, name: []const u8, expected: i32) !void {
    try std.testing.expect(object_value.isObject());
    const header = object_value.refHeader().?;
    const object: *core.Object = @fieldParentPtr("header", header);
    const atom_id = try rt.internAtom(name);
    defer rt.atoms.free(atom_id);
    const value = object.getProperty(atom_id);
    defer value.free(rt);
    try std.testing.expectEqual(@as(?i32, expected), value.asInt32());
}

pub fn expectNoOwnProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8) !void {
    const atom_id = try rt.internAtom(name);
    defer rt.atoms.free(atom_id);
    try std.testing.expect(!object.hasOwnProperty(atom_id));
}

pub fn expectIntIndex(rt: *core.JSRuntime, object_value: core.JSValue, index: u32, expected: i32) !void {
    try std.testing.expect(object_value.isObject());
    const header = object_value.refHeader().?;
    const object: *core.Object = @fieldParentPtr("header", header);
    const value = object.getProperty(core.atom.atomFromUInt32(index));
    defer value.free(rt);
    try std.testing.expectEqual(@as(?i32, expected), value.asInt32());
}

pub fn expectArrayLength(object_value: core.JSValue, expected: u32) !void {
    try std.testing.expect(object_value.isObject());
    const header = object_value.refHeader().?;
    const object: *core.Object = @fieldParentPtr("header", header);
    try std.testing.expect(object.is_array);
    try std.testing.expectEqual(expected, object.length);
}

pub fn numberValue(value: core.JSValue) ?f64 {
    if (value.asInt32()) |int_value| return @floatFromInt(int_value);
    if (value.asFloat64()) |float_value| return float_value;
    return null;
}
