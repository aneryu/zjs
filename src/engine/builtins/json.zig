const core = @import("../core/root.zig");
const std = @import("std");

/// QuickJS source map: JSON.stringify/JSON.parse builtin functions in
/// quickjs.c. This is still a narrow port used by transitional JSON bytecode
/// lowering; the VM should delegate JSON behavior here instead of owning it.
pub fn stringify(rt: *core.Runtime, value: core.Value) !core.Value {
    if (value.isUndefined()) return core.Value.undefinedValue();

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    try appendJsonValue(rt, &buffer, value, false);

    const str = try core.string.String.createUtf8(rt, buffer.items);
    return str.value();
}

pub fn parse(rt: *core.Runtime, value: core.Value) !core.Value {
    if (!value.isString()) return error.TypeError;

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendRawString(rt, &bytes, value);

    const object = try parseFlatObject(rt, bytes.items);
    return object.value();
}

pub fn stringifyInt(buf: []u8, value: i32) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{value});
}

pub fn parseInt(bytes: []const u8) !i32 {
    return std.fmt.parseInt(i32, bytes, 10);
}

fn appendJsonValue(rt: *core.Runtime, buffer: *std.ArrayList(u8), value: core.Value, array_slot: bool) anyerror!void {
    if (value.isUndefined()) {
        try buffer.appendSlice(rt.memory.allocator, if (array_slot) "null" else "");
    } else if (value.isNull()) {
        try buffer.appendSlice(rt.memory.allocator, "null");
    } else if (value.asInt32()) |int_value| {
        var int_buf: [64]u8 = undefined;
        const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{int_value});
        try buffer.appendSlice(rt.memory.allocator, printed);
    } else if (value.asBool()) |bool_value| {
        try buffer.appendSlice(rt.memory.allocator, if (bool_value) "true" else "false");
    } else if (value.isString()) {
        try buffer.append(rt.memory.allocator, '"');
        try appendRawString(rt, buffer, value);
        try buffer.append(rt.memory.allocator, '"');
    } else if (value.isObject()) {
        const header = value.refHeader() orelse return;
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (object_value.is_array) {
            try appendJsonArray(rt, buffer, object_value);
        } else {
            try appendJsonObject(rt, buffer, object_value);
        }
    } else {
        try buffer.appendSlice(rt.memory.allocator, "null");
    }
}

fn appendJsonArray(rt: *core.Runtime, buffer: *std.ArrayList(u8), object: *core.Object) anyerror!void {
    try buffer.append(rt.memory.allocator, '[');
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        if (index != 0) try buffer.append(rt.memory.allocator, ',');
        const value = object.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(rt);
        try appendJsonValue(rt, buffer, value, true);
    }
    try buffer.append(rt.memory.allocator, ']');
}

fn appendJsonObject(rt: *core.Runtime, buffer: *std.ArrayList(u8), object: *core.Object) anyerror!void {
    try buffer.append(rt.memory.allocator, '{');
    const keys = try object.ownKeys(rt);
    defer core.Object.freeKeys(rt, keys);
    var emitted = false;
    for (keys) |key| {
        const value = object.getProperty(key);
        defer value.free(rt);
        if (value.isUndefined()) continue;
        if (emitted) try buffer.append(rt.memory.allocator, ',');
        emitted = true;
        try buffer.append(rt.memory.allocator, '"');
        if (rt.atoms.name(key)) |name| try buffer.appendSlice(rt.memory.allocator, name);
        try buffer.appendSlice(rt.memory.allocator, "\":");
        try appendJsonValue(rt, buffer, value, false);
    }
    try buffer.append(rt.memory.allocator, '}');
}

fn parseFlatObject(rt: *core.Runtime, bytes: []const u8) !*core.Object {
    const object = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    if (bytes.len < 2 or bytes[0] != '{' or bytes[bytes.len - 1] != '}') return object;

    var index: usize = 1;
    while (index + 1 < bytes.len) {
        if (bytes[index] == ',') index += 1;
        if (index >= bytes.len or bytes[index] != '"') break;
        index += 1;
        const key_start = index;
        while (index < bytes.len and bytes[index] != '"') : (index += 1) {}
        if (index >= bytes.len) break;
        const key = try rt.internAtom(bytes[key_start..index]);
        index += 1;
        if (index >= bytes.len or bytes[index] != ':') break;
        index += 1;
        const value_start = index;
        while (index < bytes.len and bytes[index] != ',' and bytes[index] != '}') : (index += 1) {}
        const raw_value = bytes[value_start..index];
        const parsed_value = if (std.mem.eql(u8, raw_value, "null"))
            core.Value.nullValue()
        else
            core.Value.int32(std.fmt.parseInt(i32, raw_value, 10) catch 0);
        try object.defineOwnProperty(rt, key, core.Descriptor.data(parsed_value, true, true, true));
    }
    return object;
}

fn appendRawString(rt: *core.Runtime, buffer: *std.ArrayList(u8), value: core.Value) !void {
    const header = value.refHeader() orelse return;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.data) {
        .latin1 => |bytes| try buffer.appendSlice(rt.memory.allocator, bytes),
        .utf16 => |units| {
            for (units) |unit| {
                if (unit <= 0x7f) try buffer.append(rt.memory.allocator, @intCast(unit));
            }
        },
    }
}
