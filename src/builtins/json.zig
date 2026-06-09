const core = @import("../core/root.zig");
const std = @import("std");
const value_ops = @import("../exec/value_ops.zig");

const JsonStringifyError = std.mem.Allocator.Error || error{
    InvalidAtom,
    NoSpaceLeft,
    TypeError,
};

const SimpleJsonError = std.mem.Allocator.Error || error{
    IncompatibleDescriptor,
    InvalidAtom,
    InvalidLength,
    NotExtensible,
    ReadOnly,
    UnsupportedSimpleJson,
};

/// QuickJS source map: JSON.stringify/JSON.parse builtin functions in
/// quickjs.c. This is still a narrow port used by transitional JSON bytecode
/// lowering; the VM should delegate JSON behavior here instead of owning it.
const StringifyOptions = struct {
    property_list: []core.Atom = &.{},
    has_property_list: bool = false,
    gap: []const u8 = "",
};

pub const StaticMethod = enum(u32) {
    is_raw_json = 1,
    parse = 2,
    raw_json = 3,
    stringify = 4,
};

pub fn methodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "isRawJSON")) return @intFromEnum(StaticMethod.is_raw_json);
    if (std.mem.eql(u8, name, "parse")) return @intFromEnum(StaticMethod.parse);
    if (std.mem.eql(u8, name, "rawJSON")) return @intFromEnum(StaticMethod.raw_json);
    if (std.mem.eql(u8, name, "stringify")) return @intFromEnum(StaticMethod.stringify);
    return null;
}

pub fn stringify(rt: *core.JSRuntime, value: core.JSValue, replacer: core.JSValue, space: core.JSValue) !core.JSValue {
    var rooted_value = value;
    var rooted_replacer = replacer;
    var rooted_space = space;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
        .{ .value = &rooted_replacer },
        .{ .value = &rooted_space },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    if (rooted_value.isUndefined()) return core.JSValue.undefinedValue();

    const property_list = try stringifyPropertyList(rt, rooted_replacer);
    defer freePropertyList(rt, property_list);
    var gap = try stringifyGap(rt, rooted_space);
    defer gap.deinit(rt.memory.allocator);
    const options = StringifyOptions{ .property_list = property_list, .has_property_list = isArrayObject(rooted_replacer), .gap = gap.items };

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    var stack = std.ArrayList(*core.Object).empty;
    defer stack.deinit(rt.memory.allocator);
    try appendJsonValue(rt, &buffer, rooted_value, false, &stack, options, 0);
    if (buffer.items.len == 0) return core.JSValue.undefinedValue();

    return try createJsonStringValue(rt, buffer.items);
}

pub fn parse(rt: *core.JSRuntime, global: ?*core.Object, value: core.JSValue) !core.JSValue {
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendJsonInputString(rt, &bytes, rooted_value);

    if (try parseSimpleJsonValue(rt, global, bytes.items)) |parsed| return parsed;

    var parsed = std.json.parseFromSlice(std.json.Value, rt.memory.allocator, bytes.items, .{ .duplicate_field_behavior = .use_last }) catch return error.SyntaxError;
    defer parsed.deinit();
    return try valueFromStdJson(rt, global, parsed.value);
}

pub fn rawJSON(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    var rooted_value = value;
    var object_value = core.JSValue.undefinedValue();
    var text = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
        .{ .value = &object_value },
        .{ .value = &text },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    appendJsonInputString(rt, &bytes, rooted_value) catch |err| switch (err) {
        error.TypeError => {
            if (rooted_value.isObject()) return error.SyntaxError;
            return error.TypeError;
        },
        else => return err,
    };
    if (bytes.items.len == 0 or isRawJsonEdgeWhitespace(bytes.items[0]) or isRawJsonEdgeWhitespace(bytes.items[bytes.items.len - 1])) return error.SyntaxError;

    var parsed = std.json.parseFromSlice(std.json.Value, rt.memory.allocator, bytes.items, .{}) catch return error.SyntaxError;
    defer parsed.deinit();
    switch (parsed.value) {
        .array, .object => return error.SyntaxError,
        else => {},
    }

    const object = try core.Object.create(rt, core.class.ids.raw_json, null);
    object_value = object.value();
    errdefer {
        const failed_object = object_value;
        object_value = core.JSValue.undefinedValue();
        failed_object.free(rt);
    }
    text = try createJsonStringValue(rt, bytes.items);
    defer {
        const owned_text = text;
        text = core.JSValue.undefinedValue();
        owned_text.free(rt);
    }
    try defineData(rt, object, core.atom.ids.rawJSON, text, true);
    return object_value;
}

fn isRawJsonEdgeWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

pub fn isRawJSON(value: core.JSValue) bool {
    const header = value.refHeader() orelse return false;
    if (!value.isObject()) return false;
    const object: *core.Object = @fieldParentPtr("header", header);
    return object.class_id == core.class.ids.raw_json;
}

pub fn stringifyInt(buf: []u8, value: i32) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{value});
}

pub fn parseInt(bytes: []const u8) !i32 {
    return std.fmt.parseInt(i32, bytes, 10);
}

pub fn createJsonStringValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    const str = if (jsonBytesAreAscii(bytes))
        try core.string.String.createAscii(rt, bytes)
    else
        try core.string.String.createUtf8(rt, bytes);
    return str.value();
}

fn jsonBytesAreAscii(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte >= 0x80) return false;
    }
    return true;
}

fn createSimpleJsonAsciiStringValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    return (try core.string.String.createAscii(rt, bytes)).value();
}

fn appendJsonValue(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue, array_slot: bool, stack: *std.ArrayList(*core.Object), options: StringifyOptions, depth: usize) JsonStringifyError!void {
    var rooted_value = value;
    var raw = core.JSValue.undefinedValue();
    var primitive = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
        .{ .value = &raw },
        .{ .value = &primitive },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    if (rooted_value.isUndefined()) {
        try buffer.appendSlice(rt.memory.allocator, if (array_slot) "null" else "");
    } else if (rooted_value.isNull()) {
        try buffer.appendSlice(rt.memory.allocator, "null");
    } else if (rooted_value.isSymbol()) {
        try buffer.appendSlice(rt.memory.allocator, if (array_slot) "null" else "");
    } else if (rooted_value.asInt32()) |int_value| {
        var int_buf: [64]u8 = undefined;
        const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{int_value});
        try buffer.appendSlice(rt.memory.allocator, printed);
    } else if (rooted_value.asFloat64()) |float_value| {
        if (!std.math.isFinite(float_value)) {
            try buffer.appendSlice(rt.memory.allocator, "null");
        } else if (float_value == 0) {
            try buffer.append(rt.memory.allocator, '0');
        } else {
            var number_buf: [128]u8 = undefined;
            const printed = try std.fmt.bufPrint(&number_buf, "{d}", .{float_value});
            try buffer.appendSlice(rt.memory.allocator, printed);
        }
    } else if (rooted_value.asBool()) |bool_value| {
        try buffer.appendSlice(rt.memory.allocator, if (bool_value) "true" else "false");
    } else if (rooted_value.isString()) {
        try appendJsonStringValue(rt, buffer, rooted_value);
    } else if (rooted_value.isBigInt()) {
        return error.TypeError;
    } else if (rooted_value.isObject()) {
        const header = rooted_value.refHeader() orelse return;
        const object_value: *core.Object = @fieldParentPtr("header", header);
        if (object_value.class_id == core.class.ids.raw_json) {
            raw = object_value.getProperty(core.atom.ids.rawJSON);
            defer raw.free(rt);
            try appendRawString(rt, buffer, raw);
        } else if (isCallableJsonOmittedObject(object_value)) {
            try buffer.appendSlice(rt.memory.allocator, if (array_slot) "null" else "");
        } else if (object_value.class_id == core.class.ids.number or object_value.class_id == core.class.ids.string or object_value.class_id == core.class.ids.boolean) {
            primitive = try primitiveValue(rt, object_value) orelse core.JSValue.undefinedValue();
            defer primitive.free(rt);
            try appendJsonValue(rt, buffer, primitive, array_slot, stack, options, depth);
        } else if (object_value.is_array) {
            try appendJsonArray(rt, buffer, object_value, stack, options, depth);
        } else {
            try appendJsonObject(rt, buffer, object_value, stack, options, depth);
        }
    } else {
        try buffer.appendSlice(rt.memory.allocator, "null");
    }
}

fn appendJsonArray(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), object: *core.Object, stack: *std.ArrayList(*core.Object), options: StringifyOptions, depth: usize) JsonStringifyError!void {
    if (objectInStack(stack.items, object)) return error.TypeError;
    try stack.append(rt.memory.allocator, object);
    defer _ = stack.pop();

    try buffer.append(rt.memory.allocator, '[');
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        if (index != 0) try buffer.append(rt.memory.allocator, ',');
        if (options.gap.len != 0) {
            try buffer.append(rt.memory.allocator, '\n');
            try appendIndent(rt, buffer, options.gap, depth + 1);
        }
        const value = object.getDenseArrayElementValue(index) orelse object.getProperty(core.atom.atomFromUInt32(index));
        defer value.free(rt);
        var rooted_value = value;
        var root_values = [_]core.runtime.ValueRootValue{
            .{ .value = &rooted_value },
        };
        const root_frame = core.runtime.ValueRootFrame{
            .previous = rt.active_value_roots,
            .values = &root_values,
        };
        rt.active_value_roots = &root_frame;
        defer rt.active_value_roots = root_frame.previous;
        try appendJsonValue(rt, buffer, rooted_value, true, stack, options, depth + 1);
    }
    if (options.gap.len != 0 and object.length != 0) {
        try buffer.append(rt.memory.allocator, '\n');
        try appendIndent(rt, buffer, options.gap, depth);
    }
    try buffer.append(rt.memory.allocator, ']');
}

fn appendJsonObject(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), object: *core.Object, stack: *std.ArrayList(*core.Object), options: StringifyOptions, depth: usize) JsonStringifyError!void {
    if (objectInStack(stack.items, object)) return error.TypeError;
    try stack.append(rt.memory.allocator, object);
    defer _ = stack.pop();

    try buffer.append(rt.memory.allocator, '{');
    const owned_keys: []core.Atom = if (!options.has_property_list) try object.ownKeys(rt) else &.{};
    defer if (!options.has_property_list) core.Object.freeKeys(rt, owned_keys);
    const keys = if (options.has_property_list) options.property_list else owned_keys;
    var emitted = false;
    for (keys) |key| {
        if (rt.atoms.kind(key) == .symbol) continue;
        const value = object.getOwnDataPropertyValue(key) orelse object.getProperty(key);
        defer value.free(rt);
        var rooted_value = value;
        var root_values = [_]core.runtime.ValueRootValue{
            .{ .value = &rooted_value },
        };
        const root_frame = core.runtime.ValueRootFrame{
            .previous = rt.active_value_roots,
            .values = &root_values,
        };
        rt.active_value_roots = &root_frame;
        defer rt.active_value_roots = root_frame.previous;
        if (rooted_value.isUndefined() or rooted_value.isSymbol()) continue;
        if (rooted_value.isObject()) {
            const header = rooted_value.refHeader() orelse continue;
            const child_object: *core.Object = @fieldParentPtr("header", header);
            if (isCallableJsonOmittedObject(child_object)) continue;
        }
        if (emitted) try buffer.append(rt.memory.allocator, ',');
        if (options.gap.len != 0) {
            try buffer.append(rt.memory.allocator, '\n');
            try appendIndent(rt, buffer, options.gap, depth + 1);
        }
        emitted = true;
        try appendJsonAtomName(rt, buffer, key);
        try buffer.appendSlice(rt.memory.allocator, if (options.gap.len == 0) ":" else ": ");
        try appendJsonValue(rt, buffer, rooted_value, false, stack, options, depth + 1);
    }
    if (options.gap.len != 0 and emitted) {
        try buffer.append(rt.memory.allocator, '\n');
        try appendIndent(rt, buffer, options.gap, depth);
    }
    try buffer.append(rt.memory.allocator, '}');
}

const SimpleJsonParser = struct {
    rt: *core.JSRuntime,
    global: ?*core.Object,
    bytes: []const u8,
    index: usize = 0,

    fn parse(self: *SimpleJsonParser) !?core.JSValue {
        self.skipWhitespace();
        const value = self.parseValue() catch |err| switch (err) {
            error.UnsupportedSimpleJson => return null,
            else => return err,
        };
        errdefer value.free(self.rt);
        self.skipWhitespace();
        if (self.index != self.bytes.len) {
            value.free(self.rt);
            return null;
        }
        return value;
    }

    fn parseValue(self: *SimpleJsonParser) SimpleJsonError!core.JSValue {
        self.skipWhitespace();
        const byte = self.peek() orelse return error.UnsupportedSimpleJson;
        return switch (byte) {
            '{' => self.parseObject(),
            '[' => self.parseArray(),
            '"' => blk: {
                const text = try self.parseSimpleStringBytes();
                break :blk try createSimpleJsonAsciiStringValue(self.rt, text);
            },
            't' => if (self.consumeLiteral("true")) core.JSValue.boolean(true) else error.UnsupportedSimpleJson,
            'f' => if (self.consumeLiteral("false")) core.JSValue.boolean(false) else error.UnsupportedSimpleJson,
            'n' => if (self.consumeLiteral("null")) core.JSValue.nullValue() else error.UnsupportedSimpleJson,
            '-', '0'...'9' => self.parseInt32Number(),
            else => error.UnsupportedSimpleJson,
        };
    }

    fn parseObject(self: *SimpleJsonParser) !core.JSValue {
        self.expectByte('{') catch return error.UnsupportedSimpleJson;
        self.skipWhitespace();
        const object = try core.Object.createWithOwnPropertyCapacity(
            self.rt,
            core.class.ids.object,
            objectPrototypeFromGlobal(self.rt, self.global),
            if (self.peek() == '}') 0 else 4,
        );
        var object_value = object.value();
        var root_values = [_]core.runtime.ValueRootValue{
            .{ .value = &object_value },
        };
        const root_frame = core.runtime.ValueRootFrame{
            .previous = self.rt.active_value_roots,
            .values = &root_values,
        };
        self.rt.active_value_roots = &root_frame;
        defer self.rt.active_value_roots = root_frame.previous;
        errdefer {
            const failed_object = object_value;
            object_value = core.JSValue.undefinedValue();
            failed_object.free(self.rt);
        }
        if (self.consumeByte('}')) return object_value;

        while (true) {
            self.skipWhitespace();
            if (self.peek() != '"') return error.UnsupportedSimpleJson;
            const key_text = try self.parseSimpleStringBytes();
            const key = try self.rt.internAtom(key_text);
            defer self.rt.atoms.free(key);
            self.skipWhitespace();
            self.expectByte(':') catch return error.UnsupportedSimpleJson;
            var item_value = try self.parseValue();
            defer item_value.free(self.rt);
            var root_item = item_value;
            var item_roots = [_]core.runtime.ValueRootValue{
                .{ .value = &root_item },
            };
            const item_root_frame = core.runtime.ValueRootFrame{
                .previous = self.rt.active_value_roots,
                .values = &item_roots,
            };
            self.rt.active_value_roots = &item_root_frame;
            defer self.rt.active_value_roots = item_root_frame.previous;
            try object.defineJsonParseDataProperty(self.rt, key, item_value);
            self.skipWhitespace();
            if (self.consumeByte('}')) return object_value;
            self.expectByte(',') catch return error.UnsupportedSimpleJson;
        }
    }

    fn parseArray(self: *SimpleJsonParser) !core.JSValue {
        self.expectByte('[') catch return error.UnsupportedSimpleJson;
        const object = try core.Object.createArray(self.rt, arrayPrototypeFromGlobal(self.rt, self.global));
        var object_value = object.value();
        var root_values = [_]core.runtime.ValueRootValue{
            .{ .value = &object_value },
        };
        const root_frame = core.runtime.ValueRootFrame{
            .previous = self.rt.active_value_roots,
            .values = &root_values,
        };
        self.rt.active_value_roots = &root_frame;
        defer self.rt.active_value_roots = root_frame.previous;
        errdefer {
            const failed_object = object_value;
            object_value = core.JSValue.undefinedValue();
            failed_object.free(self.rt);
        }
        self.skipWhitespace();
        if (self.consumeByte(']')) return object_value;

        var index: u32 = 0;
        while (true) {
            var item_value = try self.parseValue();
            defer item_value.free(self.rt);
            var root_item = item_value;
            var item_roots = [_]core.runtime.ValueRootValue{
                .{ .value = &root_item },
            };
            const item_root_frame = core.runtime.ValueRootFrame{
                .previous = self.rt.active_value_roots,
                .values = &item_roots,
            };
            self.rt.active_value_roots = &item_root_frame;
            defer self.rt.active_value_roots = item_root_frame.previous;
            if (!(try object.appendDenseArrayLiteralIndex(self.rt, index, item_value))) {
                try object.defineOwnProperty(self.rt, core.atom.atomFromUInt32(index), core.Descriptor.data(item_value, true, true, true));
            }
            index += 1;
            self.skipWhitespace();
            if (self.consumeByte(']')) return object_value;
            self.expectByte(',') catch return error.UnsupportedSimpleJson;
        }
    }

    fn parseSimpleStringBytes(self: *SimpleJsonParser) ![]const u8 {
        self.expectByte('"') catch return error.UnsupportedSimpleJson;
        const start = self.index;
        while (self.index < self.bytes.len) : (self.index += 1) {
            const byte = self.bytes[self.index];
            if (byte == '"') {
                const out = self.bytes[start..self.index];
                self.index += 1;
                return out;
            }
            if (byte == '\\' or byte < 0x20 or byte >= 0x80) return error.UnsupportedSimpleJson;
        }
        return error.UnsupportedSimpleJson;
    }

    fn parseInt32Number(self: *SimpleJsonParser) !core.JSValue {
        const start = self.index;
        if (self.consumeByte('-') and self.peek() == null) return error.UnsupportedSimpleJson;
        if (self.consumeByte('0')) {
            if (self.peek()) |byte| if (byte >= '0' and byte <= '9') return error.UnsupportedSimpleJson;
        } else {
            const first = self.peek() orelse return error.UnsupportedSimpleJson;
            if (first < '1' or first > '9') return error.UnsupportedSimpleJson;
            while (self.peek()) |byte| {
                if (byte < '0' or byte > '9') break;
                self.index += 1;
            }
        }
        if (self.peek()) |byte| {
            if (byte == '.' or byte == 'e' or byte == 'E') return error.UnsupportedSimpleJson;
        }
        if (std.mem.eql(u8, self.bytes[start..self.index], "-0")) return core.JSValue.float64(-0.0);
        const parsed = std.fmt.parseInt(i32, self.bytes[start..self.index], 10) catch return error.UnsupportedSimpleJson;
        return core.JSValue.int32(parsed);
    }

    fn skipWhitespace(self: *SimpleJsonParser) void {
        while (self.peek()) |byte| {
            switch (byte) {
                ' ', '\t', '\n', '\r' => self.index += 1,
                else => return,
            }
        }
    }

    fn consumeLiteral(self: *SimpleJsonParser, text: []const u8) bool {
        if (self.index + text.len > self.bytes.len) return false;
        if (!std.mem.eql(u8, self.bytes[self.index .. self.index + text.len], text)) return false;
        self.index += text.len;
        return true;
    }

    fn consumeByte(self: *SimpleJsonParser, byte: u8) bool {
        if (self.peek() != byte) return false;
        self.index += 1;
        return true;
    }

    fn expectByte(self: *SimpleJsonParser, byte: u8) !void {
        if (!self.consumeByte(byte)) return error.UnsupportedSimpleJson;
    }

    fn peek(self: *const SimpleJsonParser) ?u8 {
        if (self.index >= self.bytes.len) return null;
        return self.bytes[self.index];
    }
};

fn parseSimpleJsonValue(rt: *core.JSRuntime, global: ?*core.Object, bytes: []const u8) !?core.JSValue {
    var parser = SimpleJsonParser{ .rt = rt, .global = global, .bytes = bytes };
    return try parser.parse();
}

fn valueFromStdJson(rt: *core.JSRuntime, global: ?*core.Object, value: std.json.Value) !core.JSValue {
    return switch (value) {
        .null => core.JSValue.nullValue(),
        .bool => |bool_value| core.JSValue.boolean(bool_value),
        .integer => |int_value| if (int_value >= std.math.minInt(i32) and int_value <= std.math.maxInt(i32))
            core.JSValue.int32(@intCast(int_value))
        else
            core.JSValue.float64(@floatFromInt(int_value)),
        .float => |float_value| core.JSValue.float64(float_value),
        .number_string => |text| core.JSValue.float64(std.fmt.parseFloat(f64, text) catch std.math.nan(f64)),
        .string => |text| try createJsonStringValue(rt, text),
        .array => |array| blk: {
            const object = try core.Object.createArray(rt, arrayPrototypeFromGlobal(rt, global));
            var object_value = object.value();
            var root_values = [_]core.runtime.ValueRootValue{
                .{ .value = &object_value },
            };
            const root_frame = core.runtime.ValueRootFrame{
                .previous = rt.active_value_roots,
                .values = &root_values,
            };
            rt.active_value_roots = &root_frame;
            defer rt.active_value_roots = root_frame.previous;
            errdefer {
                const failed_object = object_value;
                object_value = core.JSValue.undefinedValue();
                failed_object.free(rt);
            }
            try object.reserveDenseArrayElements(rt, @intCast(array.items.len));
            for (array.items, 0..) |item, index| {
                const item_value = try valueFromStdJson(rt, global, item);
                defer item_value.free(rt);
                var rooted_item = item_value;
                var item_roots = [_]core.runtime.ValueRootValue{
                    .{ .value = &rooted_item },
                };
                const item_root_frame = core.runtime.ValueRootFrame{
                    .previous = rt.active_value_roots,
                    .values = &item_roots,
                };
                rt.active_value_roots = &item_root_frame;
                defer rt.active_value_roots = item_root_frame.previous;
                if (try object.appendDenseArrayLiteralIndex(rt, @intCast(index), item_value)) continue;
                try object.defineOwnProperty(rt, core.atom.atomFromUInt32(@intCast(index)), core.Descriptor.data(item_value, true, true, true));
            }
            break :blk object_value;
        },
        .object => |object_map| blk: {
            const object = try core.Object.create(rt, core.class.ids.object, objectPrototypeFromGlobal(rt, global));
            var object_value = object.value();
            var root_values = [_]core.runtime.ValueRootValue{
                .{ .value = &object_value },
            };
            const root_frame = core.runtime.ValueRootFrame{
                .previous = rt.active_value_roots,
                .values = &root_values,
            };
            rt.active_value_roots = &root_frame;
            defer rt.active_value_roots = root_frame.previous;
            errdefer {
                const failed_object = object_value;
                object_value = core.JSValue.undefinedValue();
                failed_object.free(rt);
            }
            try object.reserveOwnPropertyCapacityAssumingPlain(rt, object_map.count());
            var iterator = object_map.iterator();
            while (iterator.next()) |entry| {
                const key = try rt.internAtom(entry.key_ptr.*);
                defer rt.atoms.free(key);
                const item_value = try valueFromStdJson(rt, global, entry.value_ptr.*);
                defer item_value.free(rt);
                var rooted_item = item_value;
                var item_roots = [_]core.runtime.ValueRootValue{
                    .{ .value = &rooted_item },
                };
                const item_root_frame = core.runtime.ValueRootFrame{
                    .previous = rt.active_value_roots,
                    .values = &item_roots,
                };
                rt.active_value_roots = &item_root_frame;
                defer rt.active_value_roots = item_root_frame.previous;
                try object.defineOwnPropertyAssumingNew(rt, key, core.Descriptor.data(item_value, true, true, true));
            }
            break :blk object_value;
        },
    };
}

fn objectPrototypeFromGlobal(rt: *core.JSRuntime, global: ?*core.Object) ?*core.Object {
    if (cachedRealmObject(global, .object_prototype)) |prototype| return prototype;
    return constructorPrototypeFromGlobal(rt, global, "Object");
}

fn arrayPrototypeFromGlobal(rt: *core.JSRuntime, global: ?*core.Object) ?*core.Object {
    if (cachedRealmObject(global, .array_prototype)) |prototype| return prototype;
    return constructorPrototypeFromGlobal(rt, global, "Array");
}

fn cachedRealmObject(global: ?*core.Object, slot: core.object.RealmValueSlot) ?*core.Object {
    const global_object = global orelse return null;
    const stored = global_object.cachedRealmValue(slot) orelse return null;
    return objectFromValue(stored);
}

fn objectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn constructorPrototypeFromGlobal(rt: *core.JSRuntime, global: ?*core.Object, name: []const u8) ?*core.Object {
    const global_object = global orelse return null;
    const key = core.atom.predefinedId(name, .string) orelse return null;
    if (global_object.getOwnDataObjectBorrowed(key)) |ctor_object| {
        if (ctor_object.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    }
    const ctor = global_object.getProperty(key);
    defer ctor.free(rt);
    if (!ctor.isObject()) return null;
    const header = ctor.refHeader() orelse return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    const proto = object.getProperty(core.atom.ids.prototype);
    defer proto.free(rt);
    if (!proto.isObject()) return null;
    const proto_header = proto.refHeader() orelse return null;
    return @fieldParentPtr("header", proto_header);
}

fn objectInStack(stack: []const *core.Object, object: *core.Object) bool {
    for (stack) |item| {
        if (item == object) return true;
    }
    return false;
}

fn isCallableJsonOmittedObject(object: *core.Object) bool {
    return object.class_id == core.class.ids.c_function or
        object.class_id == core.class.ids.c_closure or
        object.class_id == core.class.ids.bytecode_function or
        object.class_id == core.class.ids.bound_function;
}

fn isArrayObject(value: core.JSValue) bool {
    const header = value.refHeader() orelse return false;
    if (!value.isObject()) return false;
    const object: *core.Object = @fieldParentPtr("header", header);
    return object.is_array;
}

fn stringifyPropertyList(rt: *core.JSRuntime, replacer: core.JSValue) ![]core.Atom {
    var rooted_replacer = replacer;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_replacer },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const header = rooted_replacer.refHeader() orelse return &.{};
    if (!rooted_replacer.isObject()) return &.{};
    const object: *core.Object = @fieldParentPtr("header", header);
    if (!object.is_array) return &.{};

    var list = std.ArrayList(core.Atom).empty;
    errdefer {
        for (list.items) |atom| rt.atoms.free(atom);
        list.deinit(rt.memory.allocator);
    }
    var index: u32 = 0;
    while (index < object.length) : (index += 1) {
        const item = object.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(rt);
        var rooted_item = item;
        var item_roots = [_]core.runtime.ValueRootValue{
            .{ .value = &rooted_item },
        };
        const item_root_frame = core.runtime.ValueRootFrame{
            .previous = rt.active_value_roots,
            .values = &item_roots,
        };
        rt.active_value_roots = &item_root_frame;
        defer rt.active_value_roots = item_root_frame.previous;
        const atom = try stringifyPropertyListAtom(rt, rooted_item) orelse continue;
        if (atomListContains(list.items, atom)) {
            rt.atoms.free(atom);
            continue;
        }
        errdefer rt.atoms.free(atom);
        try list.append(rt.memory.allocator, atom);
    }
    return try list.toOwnedSlice(rt.memory.allocator);
}

fn stringifyPropertyListAtom(rt: *core.JSRuntime, value: core.JSValue) !?core.Atom {
    var rooted_value = value;
    var primitive = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
        .{ .value = &primitive },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    if (rooted_value.isString()) {
        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(rt.memory.allocator);
        try appendRawString(rt, &bytes, rooted_value);
        return try rt.internAtom(bytes.items);
    }
    if (rooted_value.asInt32()) |int_value| {
        var buf: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}", .{int_value});
        return try rt.internAtom(text);
    }
    if (rooted_value.asFloat64()) |float_value| {
        var buf: [128]u8 = undefined;
        const text = if (std.math.isNan(float_value))
            "NaN"
        else if (std.math.isPositiveInf(float_value))
            "Infinity"
        else if (std.math.isNegativeInf(float_value))
            "-Infinity"
        else if (float_value == 0)
            "0"
        else
            try std.fmt.bufPrint(&buf, "{d}", .{float_value});
        return try rt.internAtom(text);
    }
    const header = rooted_value.refHeader() orelse return null;
    if (!rooted_value.isObject()) return null;
    const object: *core.Object = @fieldParentPtr("header", header);
    if (object.class_id != core.class.ids.string and object.class_id != core.class.ids.number) return null;
    primitive = try primitiveValue(rt, object) orelse return null;
    defer primitive.free(rt);
    return try stringifyPropertyListAtom(rt, primitive);
}

fn stringifyGap(rt: *core.JSRuntime, space: core.JSValue) !std.ArrayList(u8) {
    var rooted_space = space;
    var primitive = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_space },
        .{ .value = &primitive },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    var out = std.ArrayList(u8).empty;
    const number = if (rooted_space.asInt32()) |int_value|
        @as(f64, @floatFromInt(int_value))
    else if (rooted_space.asFloat64()) |float_value|
        float_value
    else blk: {
        const header = rooted_space.refHeader() orelse break :blk null;
        if (!rooted_space.isObject()) break :blk null;
        const object: *core.Object = @fieldParentPtr("header", header);
        if (object.class_id == core.class.ids.number) {
            primitive = try primitiveValue(rt, object) orelse break :blk null;
            defer primitive.free(rt);
            break :blk primitive.asInt32() orelse primitive.asFloat64();
        }
        break :blk null;
    };
    if (number) |raw_number| {
        const count: usize = @intFromFloat(@min(@max(raw_number, 0), 10));
        try out.appendNTimes(rt.memory.allocator, ' ', count);
        return out;
    }

    if (rooted_space.isString()) {
        try appendRawString(rt, &out, rooted_space);
    } else if (rooted_space.isObject()) {
        const header = rooted_space.refHeader() orelse return out;
        const object: *core.Object = @fieldParentPtr("header", header);
        if (object.class_id == core.class.ids.string) {
            primitive = try primitiveValue(rt, object) orelse return out;
            defer primitive.free(rt);
            try appendRawString(rt, &out, primitive);
        }
    }
    if (out.items.len > 10) out.items = out.items[0..10];
    return out;
}

fn primitiveValue(rt: *core.JSRuntime, object: *core.Object) !?core.JSValue {
    _ = rt;
    if (object.class_id == core.class.ids.string) {
        if (object.objectData()) |value| return value.dup();
    }
    switch (object.class_id) {
        core.class.ids.number,
        core.class.ids.boolean,
        core.class.ids.big_int,
        core.class.ids.symbol,
        => return if (object.objectData()) |value| value.dup() else null,
        else => return null,
    }
}

fn atomListContains(list: []const core.Atom, atom: core.Atom) bool {
    for (list) |item| {
        if (item == atom) return true;
    }
    return false;
}

fn freePropertyList(rt: *core.JSRuntime, list: []core.Atom) void {
    for (list) |atom| rt.atoms.free(atom);
    if (list.len != 0) rt.memory.allocator.free(list);
}

fn appendIndent(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), gap: []const u8, depth: usize) !void {
    var index: usize = 0;
    while (index < depth) : (index += 1) try buffer.appendSlice(rt.memory.allocator, gap);
}

fn defineData(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue, enumerable: bool) !void {
    var object_value = object.value();
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &object_value },
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(rooted_value, false, enumerable, false));
}

fn appendJsonInputString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void {
    var rooted_value = value;
    var primitive = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
        .{ .value = &primitive },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    if (rooted_value.isString()) return appendRawString(rt, buffer, rooted_value);
    if (rooted_value.isSymbol()) return error.TypeError;
    if (rooted_value.isNull()) return buffer.appendSlice(rt.memory.allocator, "null");
    if (rooted_value.isUndefined()) return buffer.appendSlice(rt.memory.allocator, "undefined");
    if (rooted_value.asBool()) |bool_value| return buffer.appendSlice(rt.memory.allocator, if (bool_value) "true" else "false");
    if (rooted_value.asInt32()) |int_value| {
        var int_buf: [64]u8 = undefined;
        const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{int_value});
        return buffer.appendSlice(rt.memory.allocator, printed);
    }
    if (rooted_value.asFloat64()) |float_value| {
        if (float_value == 0) return buffer.append(rt.memory.allocator, '0');
        var float_buf: [128]u8 = undefined;
        const printed = try std.fmt.bufPrint(&float_buf, "{d}", .{float_value});
        return buffer.appendSlice(rt.memory.allocator, printed);
    }
    if (rooted_value.isBigInt()) return value_ops.appendValueString(rt, buffer, rooted_value);
    if (rooted_value.isObject()) {
        const header = rooted_value.refHeader() orelse return error.TypeError;
        const object: *core.Object = @fieldParentPtr("header", header);
        primitive = try primitiveValue(rt, object) orelse return error.TypeError;
        defer primitive.free(rt);
        return appendJsonInputString(rt, buffer, primitive);
    }
    return error.TypeError;
}

pub fn appendJsonStringValue(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void {
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const header = rooted_value.refHeader() orelse {
        try appendEscapedJsonString(rt, buffer, "");
        return;
    };
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| try appendEscapedJsonLatin1String(rt, buffer, bytes),
        .utf16 => |units| try appendEscapedJsonUtf16String(rt, buffer, units),
    }
}

pub fn appendJsonAtomName(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), atom_id: core.Atom) !void {
    if (core.atom.isTaggedInt(atom_id)) {
        var int_buf: [10]u8 = undefined;
        const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{core.atom.atomToUInt32(atom_id)});
        return appendEscapedJsonString(rt, buffer, printed);
    }
    const name = rt.atoms.name(atom_id) orelse "";
    return appendEscapedJsonString(rt, buffer, name);
}

pub fn appendEscapedJsonString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), bytes: []const u8) !void {
    try buffer.append(rt.memory.allocator, '"');
    for (bytes) |byte| {
        try appendEscapedJsonByte(rt, buffer, byte);
    }
    try buffer.append(rt.memory.allocator, '"');
}

fn appendEscapedJsonLatin1String(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), bytes: []const u8) !void {
    try buffer.append(rt.memory.allocator, '"');
    for (bytes) |byte| {
        if (byte <= 0x7f) {
            try appendEscapedJsonByte(rt, buffer, byte);
        } else {
            try appendUtf8CodePoint(rt, buffer, byte);
        }
    }
    try buffer.append(rt.memory.allocator, '"');
}

fn appendEscapedJsonUtf16String(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), units: []const u16) !void {
    try buffer.append(rt.memory.allocator, '"');
    var index: usize = 0;
    while (index < units.len) : (index += 1) {
        const unit = units[index];
        if (unit >= 0xd800 and unit <= 0xdbff) {
            if (index + 1 < units.len) {
                const next = units[index + 1];
                if (next >= 0xdc00 and next <= 0xdfff) {
                    const high: u32 = @intCast(unit - 0xd800);
                    const low: u32 = @intCast(next - 0xdc00);
                    try appendUtf8CodePoint(rt, buffer, 0x10000 + (high << 10) + low);
                    index += 1;
                    continue;
                }
            }
            try appendEscapedJsonUnit(rt, buffer, unit);
        } else if (unit >= 0xdc00 and unit <= 0xdfff) {
            try appendEscapedJsonUnit(rt, buffer, unit);
        } else if (unit <= 0x7f) {
            try appendEscapedJsonByte(rt, buffer, @intCast(unit));
        } else {
            try appendUtf8CodePoint(rt, buffer, unit);
        }
    }
    try buffer.append(rt.memory.allocator, '"');
}

fn appendEscapedJsonByte(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), byte: u8) !void {
    switch (byte) {
        '"' => try buffer.appendSlice(rt.memory.allocator, "\\\""),
        '\\' => try buffer.appendSlice(rt.memory.allocator, "\\\\"),
        0x08 => try buffer.appendSlice(rt.memory.allocator, "\\b"),
        0x09 => try buffer.appendSlice(rt.memory.allocator, "\\t"),
        0x0a => try buffer.appendSlice(rt.memory.allocator, "\\n"),
        0x0c => try buffer.appendSlice(rt.memory.allocator, "\\f"),
        0x0d => try buffer.appendSlice(rt.memory.allocator, "\\r"),
        0x00...0x07, 0x0b, 0x0e...0x1f => try appendEscapedJsonUnit(rt, buffer, byte),
        else => try buffer.append(rt.memory.allocator, byte),
    }
}

fn appendEscapedJsonUnit(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), unit: anytype) !void {
    var escaped: [6]u8 = undefined;
    const text = try std.fmt.bufPrint(&escaped, "\\u{x:0>4}", .{unit});
    try buffer.appendSlice(rt.memory.allocator, text);
}

fn appendRawString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void {
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const header = rooted_value.refHeader() orelse return;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| try buffer.appendSlice(rt.memory.allocator, bytes),
        .utf16 => |units| {
            var index: usize = 0;
            while (index < units.len) : (index += 1) {
                const unit = units[index];
                if (unit >= 0xd800 and unit <= 0xdbff and index + 1 < units.len) {
                    const next = units[index + 1];
                    if (next >= 0xdc00 and next <= 0xdfff) {
                        const high: u32 = @intCast(unit - 0xd800);
                        const low: u32 = @intCast(next - 0xdc00);
                        try appendUtf8CodePoint(rt, buffer, 0x10000 + (high << 10) + low);
                        index += 1;
                        continue;
                    }
                }
                try appendUtf8CodePoint(rt, buffer, unit);
            }
        },
    }
}

fn appendUtf8CodePoint(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), cp: u32) !void {
    if (cp <= 0x7f) {
        try buffer.append(rt.memory.allocator, @intCast(cp));
    } else if (cp <= 0x7ff) {
        try buffer.append(rt.memory.allocator, @intCast(0xc0 | (cp >> 6)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | (cp & 0x3f)));
    } else if (cp <= 0xffff) {
        try buffer.append(rt.memory.allocator, @intCast(0xe0 | (cp >> 12)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | ((cp >> 6) & 0x3f)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | (cp & 0x3f)));
    } else {
        try buffer.append(rt.memory.allocator, @intCast(0xf0 | (cp >> 18)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | ((cp >> 12) & 0x3f)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | ((cp >> 6) & 0x3f)));
        try buffer.append(rt.memory.allocator, @intCast(0x80 | (cp & 0x3f)));
    }
}
