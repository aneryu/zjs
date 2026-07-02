//! QuickJS source map: js_json_obj / js_json_funcs (JS_ParseJSON,
//! js_json_stringify) in quickjs.c. Implementation and declaration table live
//! side by side (QuickJS client model); dispatch reaches `internal_entries`
//! through `rt.internal_builtins` (see `internal_table.zig`), and the install
//! path consumes the same entries.

const core = @import("../core/root.zig");
const unicode = @import("../libs/unicode.zig");
const std = @import("std");
const array_builtin = @import("array.zig");
const builtin_dispatch = @import("../exec/builtin_dispatch.zig");
const call_runtime = @import("../exec/call_runtime.zig");
const coercion_ops = @import("../exec/coercion_ops.zig");
const exceptions = @import("../exec/exceptions.zig");
const object_ops = @import("../exec/object_ops.zig");
const string_ops = @import("../exec/string_ops.zig");
const value_ops = @import("../exec/value_ops.zig");

const Bytecode = builtin_dispatch.Bytecode;
const Frame = builtin_dispatch.Frame;
const HostError = exceptions.HostError;
const InternalCall = core.host_function.InternalCall;

const JsonStringifyError = std.mem.Allocator.Error || error{
    InvalidAtom,
    NoSpaceLeft,
    TypeError,
    StackOverflow,
};

const SimpleJsonError = std.mem.Allocator.Error || error{
    IncompatibleDescriptor,
    InvalidAtom,
    InvalidLength,
    NotExtensible,
    ReadOnly,
    UnsupportedSimpleJson,
    // Native recursion guard: QuickJS surfaces deep JSON.parse nesting as a
    // catchable SyntaxError (json parser js_parse_error, quickjs.c:23483).
    SyntaxError,
};

const StringifyOptions = struct {
    property_list: []core.Atom = &.{},
    has_property_list: bool = false,
    gap: []const u8 = "",
};

// Method-id enum mirrored in `core.host_function.builtin_method_ids.json` so
// import-free exec sites (e.g. exec/module.zig's synthetic JSON loader) can name
// `JSON.parse`'s native id without importing builtins. Re-exported here so
// `internal_entries` and the install path keep referring to it locally.
pub const StaticMethod = core.host_function.builtin_method_ids.json.StaticMethod;

/// Declaration table: one entry per `JSON.*` method.
pub const internal_entries = [_]core.host_function.InternalEntry{
    .{ .name = "isRawJSON", .length = 1, .id = @intFromEnum(StaticMethod.is_raw_json), .prepared_call_ok = true, .call = &jsonIsRawJsonCall },
    .{ .name = "parse", .length = 2, .id = @intFromEnum(StaticMethod.parse), .prepared_call_ok = true, .call = &jsonParseRecordCall },
    .{ .name = "rawJSON", .length = 1, .id = @intFromEnum(StaticMethod.raw_json), .prepared_call_ok = true, .call = &jsonRawJsonCall },
    .{ .name = "stringify", .length = 3, .id = @intFromEnum(StaticMethod.stringify), .prepared_call_ok = true, .call = &jsonStringifyRecordCall },
};

fn jsonIsRawJsonCall(host_call: InternalCall) HostError!core.JSValue {
    return core.JSValue.boolean(host_call.args.len >= 1 and isRawJSON(host_call.args[0]));
}

fn jsonRawJsonCall(host_call: InternalCall) HostError!core.JSValue {
    const value = if (host_call.args.len >= 1) host_call.args[0] else core.JSValue.undefinedValue();
    return rawJSON(host_call.ctx.runtime, value) catch |err| switch (err) {
        error.SyntaxError, error.TypeError => err,
        else => err,
    };
}

fn jsonParseRecordCall(host_call: InternalCall) HostError!core.JSValue {
    const ctx = host_call.ctx;
    if (host_call.global) |global| {
        if (try qjsJsonParseCall(ctx, host_call.output, global, host_call.args, builtin_dispatch.callerBytecode(host_call), builtin_dispatch.callerFrame(host_call))) |value| return value;
        return error.TypeError;
    }
    const value = if (host_call.args.len >= 1) host_call.args[0] else core.JSValue.undefinedValue();
    return parse(ctx.runtime, null, value) catch |err| switch (err) {
        error.SyntaxError, error.TypeError => err,
        else => err,
    };
}

fn jsonStringifyRecordCall(host_call: InternalCall) HostError!core.JSValue {
    const ctx = host_call.ctx;
    if (host_call.global) |global| {
        if (try qjsJsonStringifyCall(ctx, host_call.output, global, host_call.args, builtin_dispatch.callerBytecode(host_call), builtin_dispatch.callerFrame(host_call))) |value| return value;
        return error.TypeError;
    }
    const value = if (host_call.args.len >= 1) host_call.args[0] else core.JSValue.undefinedValue();
    const replacer = if (host_call.args.len >= 2) host_call.args[1] else core.JSValue.undefinedValue();
    const space = if (host_call.args.len >= 3) host_call.args[2] else core.JSValue.undefinedValue();
    return stringify(ctx.runtime, value, replacer, space) catch |err| switch (err) {
        error.TypeError => error.TypeError,
        else => err,
    };
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

fn createSimpleJsonAsciiStringValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    return (try core.string.String.createAscii(rt, bytes)).value();
}

fn appendJsonValue(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue, array_slot: bool, stack: *std.ArrayList(*core.Object), options: StringifyOptions, depth: usize) JsonStringifyError!void {
    if (rt.checkNativeStackOverflow(0)) return error.StackOverflow;
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
        } else if (object_value.flags.is_array) {
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
    while (index < object.arrayLength()) : (index += 1) {
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
    if (options.gap.len != 0 and object.arrayLength() != 0) {
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
        if (rt.atoms.isPublicSymbol(key)) continue;
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
        if (self.rt.checkNativeStackOverflow(0)) return error.SyntaxError;
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
            if (self.peek()) |byte| if (unicode.isAsciiDigitByte(byte)) return error.UnsupportedSimpleJson;
        } else {
            const first = self.peek() orelse return error.UnsupportedSimpleJson;
            if (!unicode.isAsciiDigitByte(first) or first == '0') return error.UnsupportedSimpleJson;
            while (self.peek()) |byte| {
                if (!unicode.isAsciiDigitByte(byte)) break;
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

test "simple JSON parser uses shared ASCII digit classification for integers" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const int_value = (try parseSimpleJsonValue(rt, null, "12345")).?;
    defer int_value.free(rt);
    try std.testing.expectEqual(@as(?i32, 12345), int_value.asInt32());

    const zero_value = (try parseSimpleJsonValue(rt, null, "0")).?;
    defer zero_value.free(rt);
    try std.testing.expectEqual(@as(?i32, 0), zero_value.asInt32());

    try std.testing.expect((try parseSimpleJsonValue(rt, null, "01")) == null);
    try std.testing.expect((try parseSimpleJsonValue(rt, null, "1.5")) == null);
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
    return object.flags.is_array;
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
    if (!object.flags.is_array) return &.{};

    var list = std.ArrayList(core.Atom).empty;
    errdefer {
        for (list.items) |atom| rt.atoms.free(atom);
        list.deinit(rt.memory.allocator);
    }
    var index: u32 = 0;
    while (index < object.arrayLength()) : (index += 1) {
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
        const string_object = rooted_value.asStringBody().?;
        return try string_object.internAtom(rt);
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
    if (rooted_value.isBigInt()) return core.value_format.appendBigIntBase10(rt.memory.allocator, buffer, rooted_value);
    if (rooted_value.isObject()) {
        const header = rooted_value.refHeader() orelse return error.TypeError;
        const object: *core.Object = @fieldParentPtr("header", header);
        primitive = try primitiveValue(rt, object) orelse return error.TypeError;
        defer primitive.free(rt);
        return appendJsonInputString(rt, buffer, primitive);
    }
    return error.TypeError;
}

// JSON-formatting primitives (string factory + escape suite) now live in
// `core/json.zig`; QuickJS keeps these pure serializer helpers in the engine
// core and they carry zero exec/builtins dependency. Re-exported here so the
// builtins JSON serializer keeps calling them by their original names.
pub const createJsonStringValue = core.json.createJsonStringValue;
pub const appendJsonStringValue = core.json.appendJsonStringValue;
pub const appendJsonAtomName = core.json.appendJsonAtomName;
pub const appendEscapedJsonString = core.json.appendEscapedJsonString;

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

    const string_value = rooted_value.asStringBody() orelse return;
    try string_value.ensureFlat(rt);
    switch (string_value.resolveData()) {
        .latin1 => |bytes| try buffer.appendSlice(rt.memory.allocator, bytes),
        .utf16 => |units| try unicode.appendUtf16UnitsAsUtf8(rt.memory.allocator, buffer, units),
    }
}

// --- VM-coercing JSON.parse/JSON.stringify (moved from exec/json_ops.zig) ----

const JsonSourceCollectError = std.mem.Allocator.Error;

const SimpleJsonStringifyError = std.mem.Allocator.Error || error{
    InvalidUtf8,
    NoSpaceLeft,
    TypeError,
    StackOverflow,
};

const JsonStringifyVmOptions = struct {
    replacer: core.JSValue = core.JSValue.undefinedValue(),
    property_list: []const core.Atom = &.{},
    has_property_list: bool = false,
    gap: []const u8 = "",
};

const JsonStringifyPropertyList = struct {
    items: []core.Atom = &.{},
    has_property_list: bool = false,

    fn deinit(self: JsonStringifyPropertyList, rt: *core.JSRuntime) void {
        for (self.items) |atom| rt.atoms.free(atom);
        rt.memory.allocator.free(self.items);
    }
};

const JsonParseSourceCursor = struct {
    sources: []const []const u8,
    index: usize = 0,

    fn next(self: *JsonParseSourceCursor) ?[]const u8 {
        if (self.index >= self.sources.len) return null;
        const source = self.sources[self.index];
        self.index += 1;
        return source;
    }
};

const JsonInternalizeChildInfo = struct {
    key: core.Atom,
    key_owned: bool = false,
    original_index: usize,
    source_count: usize,

    fn deinit(self: JsonInternalizeChildInfo, rt: *core.JSRuntime) void {
        if (self.key_owned) rt.atoms.free(self.key);
    }
};

const SimpleJsonResult = enum {
    appended,
    omitted,
    fallback,
};

fn deinitLengthIndexAtom(rt: *core.JSRuntime, atom: anytype) void {
    if (atom.owned) rt.atoms.free(atom.atom);
}

pub fn qjsJsonParseCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) !?core.JSValue {
    var input = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    var reviver = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    var text = core.JSValue.undefinedValue();
    var parsed = core.JSValue.undefinedValue();
    var holder_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &input },
        .{ .value = &reviver },
        .{ .value = &text },
        .{ .value = &parsed },
        .{ .value = &holder_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    text = try string_ops.toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
    defer {
        const owned_text = text;
        text = core.JSValue.undefinedValue();
        owned_text.free(ctx.runtime);
    }
    parsed = try parse(ctx.runtime, global, text);
    errdefer {
        const owned_parsed = parsed;
        parsed = core.JSValue.undefinedValue();
        owned_parsed.free(ctx.runtime);
    }
    if (!call_runtime.isCallableValue(reviver)) return parsed;

    var text_bytes = std.ArrayList(u8).empty;
    defer text_bytes.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendRawString(ctx.runtime, &text_bytes, text);
    var primitive_sources = std.ArrayList([]const u8).empty;
    defer primitive_sources.deinit(ctx.runtime.memory.allocator);
    try qjsJsonCollectPrimitiveSources(ctx.runtime.memory.allocator, text_bytes.items, &primitive_sources);

    const holder = try core.Object.create(ctx.runtime, core.class.ids.object, object_ops.objectPrototypeFromGlobal(ctx.runtime, global));
    holder_value = holder.value();
    defer {
        const owned_holder = holder_value;
        holder_value = core.JSValue.undefinedValue();
        owned_holder.free(ctx.runtime);
    }
    const root_key = try ctx.runtime.internAtom("");
    defer ctx.runtime.atoms.free(root_key);
    try holder.defineOwnProperty(ctx.runtime, root_key, core.Descriptor.data(parsed, true, true, true));
    const stored_parsed = parsed;
    parsed = core.JSValue.undefinedValue();
    stored_parsed.free(ctx.runtime);

    var source_cursor = JsonParseSourceCursor{ .sources = primitive_sources.items };
    return try qjsJsonInternalizeProperty(ctx, output, global, holder_value, root_key, reviver, &source_cursor, caller_function, caller_frame);
}

test "JSON.parse roots direct function bytecode input while coercing to string" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);

    const fb_slice = try rt.memory.alloc(core.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = core.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    {
        const __cp = try rt.memory.alloc(core.JSValue, 1);
        fb.cpool = __cp.ptr;
        fb.cpool_count = @intCast(__cp.len);
    }
    const symbol_atom = try rt.atoms.newValueSymbol("gc-json-parse-input-bytecode-symbol");
    fb.cpool[0] = try rt.symbolValue(symbol_atom);
    fb.cpool_count = 1;

    var input = core.JSValue.functionBytecode(&fb.header);
    var input_alive = true;
    defer if (input_alive) input.free(rt);
    const args = [_]core.JSValue{input};

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try std.testing.expectError(error.SyntaxError, qjsJsonParseCall(ctx, null, global, &args, null, null));
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    input.free(rt);
    input_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn qjsJsonInternalizeProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    holder_value: core.JSValue,
    key: core.Atom,
    reviver: core.JSValue,
    source_cursor: ?*JsonParseSourceCursor,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) !core.JSValue {
    var rooted_holder_value = holder_value;
    var rooted_reviver = reviver;
    var value = core.JSValue.undefinedValue();
    var key_value = core.JSValue.undefinedValue();
    var context_value = core.JSValue.undefinedValue();
    var scratch_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_holder_value },
        .{ .value = &rooted_reviver },
        .{ .value = &value },
        .{ .value = &key_value },
        .{ .value = &context_value },
        .{ .value = &scratch_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    value = try object_ops.getValueProperty(ctx, output, global, rooted_holder_value, key, caller_function, caller_frame);
    defer {
        const owned_value = value;
        value = core.JSValue.undefinedValue();
        owned_value.free(ctx.runtime);
    }

    if (object_ops.objectFromValue(value)) |object| {
        if (try array_builtin.isArrayValue(value)) {
            const length_value = try object_ops.getValueProperty(ctx, output, global, value, core.atom.ids.length, caller_function, caller_frame);
            defer length_value.free(ctx.runtime);
            const length = try coercion_ops.toLengthIndex(ctx, output, global, length_value);
            var index: usize = 0;
            var child_infos = std.ArrayList(JsonInternalizeChildInfo).empty;
            defer {
                for (child_infos.items) |info| info.deinit(ctx.runtime);
                child_infos.deinit(ctx.runtime.memory.allocator);
            }
            var child_values = std.ArrayList(core.JSValue).empty;
            defer {
                for (child_values.items) |child_value| child_value.free(ctx.runtime);
                child_values.deinit(ctx.runtime.memory.allocator);
            }
            var child_root_slices = [_]core.runtime.ValueRootSlice{
                .{ .mutable = &child_values.items },
            };
            const child_root_frame = core.runtime.ValueRootFrame{
                .previous = ctx.runtime.active_value_roots,
                .slices = &child_root_slices,
            };
            ctx.runtime.active_value_roots = &child_root_frame;
            defer ctx.runtime.active_value_roots = child_root_frame.previous;
            while (index < length) : (index += 1) {
                const child_key = try object_ops.propertyAtomFromLengthIndex(ctx.runtime, index);
                scratch_value = try object_ops.getValueProperty(ctx, output, global, value, child_key.atom, caller_function, caller_frame);
                const original_index = child_values.items.len;
                child_values.append(ctx.runtime.memory.allocator, scratch_value) catch |err| {
                    const failed_child = scratch_value;
                    scratch_value = core.JSValue.undefinedValue();
                    failed_child.free(ctx.runtime);
                    deinitLengthIndexAtom(ctx.runtime, child_key);
                    return err;
                };
                scratch_value = core.JSValue.undefinedValue();
                const source_count = qjsJsonSourceCountForValue(ctx.runtime, child_values.items[original_index]) catch |err| {
                    deinitLengthIndexAtom(ctx.runtime, child_key);
                    return err;
                };
                child_infos.append(ctx.runtime.memory.allocator, .{
                    .key = child_key.atom,
                    .key_owned = child_key.owned,
                    .original_index = original_index,
                    .source_count = source_count,
                }) catch |err| {
                    deinitLengthIndexAtom(ctx.runtime, child_key);
                    return err;
                };
            }
            for (child_infos.items) |info| {
                try qjsJsonInternalizeChild(ctx, output, global, value, object, info.key, rooted_reviver, source_cursor, child_values.items[info.original_index], info.source_count, caller_function, caller_frame);
            }
        } else {
            const keys = try object_ops.objectRestOwnKeys(ctx, output, global, object);
            defer core.Object.freeKeys(ctx.runtime, keys);
            var child_infos = std.ArrayList(JsonInternalizeChildInfo).empty;
            defer {
                for (child_infos.items) |info| info.deinit(ctx.runtime);
                child_infos.deinit(ctx.runtime.memory.allocator);
            }
            var child_values = std.ArrayList(core.JSValue).empty;
            defer {
                for (child_values.items) |child_value| child_value.free(ctx.runtime);
                child_values.deinit(ctx.runtime.memory.allocator);
            }
            var child_root_slices = [_]core.runtime.ValueRootSlice{
                .{ .mutable = &child_values.items },
            };
            const child_root_frame = core.runtime.ValueRootFrame{
                .previous = ctx.runtime.active_value_roots,
                .slices = &child_root_slices,
            };
            ctx.runtime.active_value_roots = &child_root_frame;
            defer ctx.runtime.active_value_roots = child_root_frame.previous;
            for (keys) |child_key| {
                if (ctx.runtime.atoms.isPublicSymbol(child_key)) continue;
                const desc = try object_ops.objectRestOwnPropertyDescriptor(ctx, output, global, object, child_key) orelse continue;
                defer desc.destroy(ctx.runtime);
                if (desc.enumerable != true) continue;
                scratch_value = try object_ops.getValueProperty(ctx, output, global, value, child_key, caller_function, caller_frame);
                const original_index = child_values.items.len;
                child_values.append(ctx.runtime.memory.allocator, scratch_value) catch |err| {
                    const failed_child = scratch_value;
                    scratch_value = core.JSValue.undefinedValue();
                    failed_child.free(ctx.runtime);
                    return err;
                };
                scratch_value = core.JSValue.undefinedValue();
                const source_count = try qjsJsonSourceCountForValue(ctx.runtime, child_values.items[original_index]);
                child_infos.append(ctx.runtime.memory.allocator, .{
                    .key = child_key,
                    .key_owned = false,
                    .original_index = original_index,
                    .source_count = source_count,
                }) catch |err| {
                    return err;
                };
            }
            for (child_infos.items) |info| {
                try qjsJsonInternalizeChild(ctx, output, global, value, object, info.key, rooted_reviver, source_cursor, child_values.items[info.original_index], info.source_count, caller_function, caller_frame);
            }
        }
    }

    key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, key);
    defer {
        const owned_key = key_value;
        key_value = core.JSValue.undefinedValue();
        owned_key.free(ctx.runtime);
    }
    context_value = try qjsJsonReviverContext(ctx.runtime, global, value, source_cursor);
    defer {
        const owned_context = context_value;
        context_value = core.JSValue.undefinedValue();
        owned_context.free(ctx.runtime);
    }
    const result = try call_runtime.callValueOrBytecode(ctx, output, global, rooted_holder_value, rooted_reviver, &.{ key_value, value, context_value }, caller_function, caller_frame);
    if (result.same(value) or result.same(key_value) or result.same(rooted_holder_value)) {
        const duplicated = result.dup();
        result.free(ctx.runtime);
        return duplicated;
    }
    return result;
}

pub fn qjsJsonInternalizeChild(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    holder_value: core.JSValue,
    holder: *core.Object,
    key: core.Atom,
    reviver: core.JSValue,
    source_cursor: ?*JsonParseSourceCursor,
    original_value: core.JSValue,
    source_count: usize,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) HostError!void {
    var rooted_holder_value = holder_value;
    var rooted_reviver = reviver;
    var rooted_original_value = original_value;
    var current = core.JSValue.undefinedValue();
    var revived = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_holder_value },
        .{ .value = &rooted_reviver },
        .{ .value = &rooted_original_value },
        .{ .value = &current },
        .{ .value = &revived },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    var child_source_cursor = source_cursor;
    if (source_count != 0) {
        current = try object_ops.getValueProperty(ctx, output, global, rooted_holder_value, key, caller_function, caller_frame);
        defer {
            const owned_current = current;
            current = core.JSValue.undefinedValue();
            owned_current.free(ctx.runtime);
        }
        if (!current.same(rooted_original_value)) {
            qjsJsonDiscardSources(source_cursor, source_count);
            child_source_cursor = null;
        }
    }
    revived = try qjsJsonInternalizeProperty(ctx, output, global, rooted_holder_value, key, rooted_reviver, child_source_cursor, caller_function, caller_frame);
    defer {
        const owned_revived = revived;
        revived = core.JSValue.undefinedValue();
        owned_revived.free(ctx.runtime);
    }
    if (revived.isUndefined()) {
        _ = try object_ops.deleteValueProperty(ctx, output, global, rooted_holder_value, holder, key, caller_function, caller_frame);
    } else {
        try qjsJsonCreateDataProperty(ctx, output, global, rooted_holder_value, holder, key, revived, caller_function, caller_frame);
    }
}

fn qjsJsonReviverContext(rt: *core.JSRuntime, global: *core.Object, value: core.JSValue, source_cursor: ?*JsonParseSourceCursor) !core.JSValue {
    var rooted_value = value;
    var object_value = core.JSValue.undefinedValue();
    var source_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
        .{ .value = &object_value },
        .{ .value = &source_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const object = try core.Object.create(rt, core.class.ids.object, object_ops.objectPrototypeFromGlobal(rt, global));
    object_value = object.value();
    errdefer {
        const failed_object = object_value;
        object_value = core.JSValue.undefinedValue();
        failed_object.free(rt);
    }
    if (object_ops.objectFromValue(rooted_value) == null) {
        if (source_cursor) |cursor| {
            if (cursor.next()) |source| {
                source_value = try value_ops.createStringValue(rt, source);
                defer {
                    const owned_source = source_value;
                    source_value = core.JSValue.undefinedValue();
                    owned_source.free(rt);
                }
                try object.defineOwnProperty(rt, core.atom.ids.source, core.Descriptor.data(source_value, true, true, true));
            }
        }
    }
    return object_value;
}

fn qjsJsonDiscardSources(source_cursor: ?*JsonParseSourceCursor, count: usize) void {
    const cursor = source_cursor orelse return;
    cursor.index = @min(cursor.index + count, cursor.sources.len);
}

fn qjsJsonSourceCountForValue(rt: *core.JSRuntime, value: core.JSValue) !usize {
    var rooted_value = value;
    var child = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
        .{ .value = &child },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const object = object_ops.objectFromValue(rooted_value) orelse return 1;
    var count: usize = 0;
    if (object.flags.is_array) {
        var index: usize = 0;
        while (index < object.arrayLength()) : (index += 1) {
            const key = try object_ops.propertyAtomFromLengthIndex(rt, index);
            defer deinitLengthIndexAtom(rt, key);
            child = object.getProperty(key.atom);
            defer {
                const owned_child = child;
                child = core.JSValue.undefinedValue();
                owned_child.free(rt);
            }
            count += try qjsJsonSourceCountForValue(rt, child);
        }
        return count;
    }
    const keys = try object.ownKeys(rt);
    defer core.Object.freeKeys(rt, keys);
    for (keys) |key| {
        if (rt.atoms.isPublicSymbol(key)) continue;
        const desc = object.getOwnProperty(rt, key) orelse continue;
        defer desc.destroy(rt);
        if (desc.enumerable != true) continue;
        child = object.getProperty(key);
        defer {
            const owned_child = child;
            child = core.JSValue.undefinedValue();
            owned_child.free(rt);
        }
        count += try qjsJsonSourceCountForValue(rt, child);
    }
    return count;
}

fn qjsJsonCollectPrimitiveSources(allocator: std.mem.Allocator, bytes: []const u8, out: *std.ArrayList([]const u8)) JsonSourceCollectError!void {
    var index: usize = 0;
    try qjsJsonCollectValueSource(allocator, bytes, &index, out);
}

fn qjsJsonCollectValueSource(allocator: std.mem.Allocator, bytes: []const u8, index: *usize, out: *std.ArrayList([]const u8)) JsonSourceCollectError!void {
    qjsJsonSkipWhitespace(bytes, index);
    if (index.* >= bytes.len) return;
    switch (bytes[index.*]) {
        '{' => try qjsJsonCollectObjectSources(allocator, bytes, index, out),
        '[' => try qjsJsonCollectArraySources(allocator, bytes, index, out),
        '"' => {
            const start = index.*;
            qjsJsonSkipString(bytes, index);
            try out.append(allocator, bytes[start..index.*]);
        },
        else => {
            const start = index.*;
            qjsJsonSkipPrimitiveLiteral(bytes, index);
            try out.append(allocator, bytes[start..index.*]);
        },
    }
    qjsJsonSkipWhitespace(bytes, index);
}

fn qjsJsonCollectArraySources(allocator: std.mem.Allocator, bytes: []const u8, index: *usize, out: *std.ArrayList([]const u8)) JsonSourceCollectError!void {
    index.* += 1;
    qjsJsonSkipWhitespace(bytes, index);
    if (index.* < bytes.len and bytes[index.*] == ']') {
        index.* += 1;
        return;
    }
    while (index.* < bytes.len) {
        try qjsJsonCollectValueSource(allocator, bytes, index, out);
        qjsJsonSkipWhitespace(bytes, index);
        if (index.* >= bytes.len) return;
        if (bytes[index.*] == ']') {
            index.* += 1;
            return;
        }
        if (bytes[index.*] == ',') index.* += 1 else return;
    }
}

fn qjsJsonCollectObjectSources(allocator: std.mem.Allocator, bytes: []const u8, index: *usize, out: *std.ArrayList([]const u8)) JsonSourceCollectError!void {
    index.* += 1;
    qjsJsonSkipWhitespace(bytes, index);
    if (index.* < bytes.len and bytes[index.*] == '}') {
        index.* += 1;
        return;
    }
    while (index.* < bytes.len) {
        qjsJsonSkipWhitespace(bytes, index);
        qjsJsonSkipString(bytes, index);
        qjsJsonSkipWhitespace(bytes, index);
        if (index.* < bytes.len and bytes[index.*] == ':') index.* += 1 else return;
        try qjsJsonCollectValueSource(allocator, bytes, index, out);
        qjsJsonSkipWhitespace(bytes, index);
        if (index.* >= bytes.len) return;
        if (bytes[index.*] == '}') {
            index.* += 1;
            return;
        }
        if (bytes[index.*] == ',') index.* += 1 else return;
    }
}

fn qjsJsonSkipWhitespace(bytes: []const u8, index: *usize) void {
    while (index.* < bytes.len) : (index.* += 1) {
        switch (bytes[index.*]) {
            ' ', '\t', '\n', '\r' => {},
            else => return,
        }
    }
}

fn qjsJsonSkipString(bytes: []const u8, index: *usize) void {
    if (index.* >= bytes.len or bytes[index.*] != '"') return;
    index.* += 1;
    while (index.* < bytes.len) : (index.* += 1) {
        if (bytes[index.*] == '\\') {
            index.* += 1;
            continue;
        }
        if (bytes[index.*] == '"') {
            index.* += 1;
            return;
        }
    }
}

fn qjsJsonSkipPrimitiveLiteral(bytes: []const u8, index: *usize) void {
    while (index.* < bytes.len) : (index.* += 1) {
        switch (bytes[index.*]) {
            ' ', '\t', '\n', '\r', ',', ']', '}' => return,
            else => {},
        }
    }
}

pub fn qjsJsonCreateDataProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    holder_value: core.JSValue,
    holder: *core.Object,
    key: core.Atom,
    value: core.JSValue,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) HostError!void {
    var rooted_holder_value = holder_value;
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_holder_value },
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    if (holder.proxyTarget() != null) {
        object_ops.createDataPropertyOrThrow(ctx, output, global, rooted_holder_value, holder, key, rooted_value, caller_function, caller_frame) catch |err| switch (err) {
            error.TypeError => return,
            else => return err,
        };
        return;
    }
    holder.defineOwnProperty(ctx.runtime, key, core.Descriptor.data(rooted_value, true, true, true)) catch |err| switch (err) {
        error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return,
        else => return err,
    };
}

pub fn qjsJsonStringifyCall(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.JSValue,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) !?core.JSValue {
    var value = if (args.len >= 1) args[0] else core.JSValue.undefinedValue();
    var replacer = if (args.len >= 2) args[1] else core.JSValue.undefinedValue();
    var space = if (args.len >= 3) args[2] else core.JSValue.undefinedValue();
    var holder_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &value },
        .{ .value = &replacer },
        .{ .value = &space },
        .{ .value = &holder_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    if (replacer.isUndefined() and space.isUndefined()) {
        if (try qjsJsonStringifySimpleNoOptions(ctx.runtime, global, value)) |fast| return fast;
    }

    const property_list = try qjsJsonStringifyPropertyList(ctx, output, global, replacer, caller_function, caller_frame);
    defer property_list.deinit(ctx.runtime);
    var gap = try qjsJsonStringifyGap(ctx, output, global, space, caller_function, caller_frame);
    defer gap.deinit(ctx.runtime.memory.allocator);
    const options = JsonStringifyVmOptions{
        .replacer = replacer,
        .property_list = property_list.items,
        .has_property_list = property_list.has_property_list,
        .gap = gap.items,
    };

    const holder = try core.Object.create(ctx.runtime, core.class.ids.object, object_ops.objectPrototypeFromGlobal(ctx.runtime, global));
    holder_value = holder.value();
    defer {
        const owned_holder = holder_value;
        holder_value = core.JSValue.undefinedValue();
        owned_holder.free(ctx.runtime);
    }
    const root_key = try ctx.runtime.internAtom("");
    defer ctx.runtime.atoms.free(root_key);
    try holder.defineOwnProperty(ctx.runtime, root_key, core.Descriptor.data(value, true, true, true));

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(ctx.runtime.memory.allocator);
    var stack = std.ArrayList(*core.Object).empty;
    defer stack.deinit(ctx.runtime.memory.allocator);
    try qjsJsonSerializeProperty(ctx, output, global, &buffer, holder_value, holder, root_key, false, &stack, options, 0, caller_function, caller_frame);
    if (buffer.items.len == 0) return core.JSValue.undefinedValue();
    return try createJsonStringValue(ctx.runtime, buffer.items);
}

test "JSON.stringify roots direct function bytecode value while creating holder" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);

    const fb_slice = try rt.memory.alloc(core.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = core.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    {
        const __cp = try rt.memory.alloc(core.JSValue, 1);
        fb.cpool = __cp.ptr;
        fb.cpool_count = @intCast(__cp.len);
    }
    const symbol_atom = try rt.atoms.newValueSymbol("gc-json-stringify-value-bytecode-symbol");
    fb.cpool[0] = try rt.symbolValue(symbol_atom);
    fb.cpool_count = 1;

    var value = core.JSValue.functionBytecode(&fb.header);
    var value_alive = true;
    defer if (value_alive) value.free(rt);
    const args = [_]core.JSValue{
        value,
        core.JSValue.undefinedValue(),
        core.JSValue.int32(0),
    };

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const maybe_result = try qjsJsonStringifyCall(ctx, null, global, &args, null, null);
    try std.testing.expect(maybe_result != null);
    const result = maybe_result.?;
    defer result.free(rt);
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try value_ops.appendRawString(rt, &bytes, result);
    try std.testing.expectEqualStrings("null", bytes.items);
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    value.free(rt);
    value_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn qjsJsonStringifySimpleNoOptions(rt: *core.JSRuntime, global: *core.Object, value: core.JSValue) SimpleJsonStringifyError!?core.JSValue {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    var stack = std.ArrayList(*core.Object).empty;
    defer stack.deinit(rt.memory.allocator);
    return switch (try qjsJsonAppendSimpleValue(rt, global, &buffer, value, false, &stack)) {
        .appended => try createJsonStringValue(rt, buffer.items),
        .omitted => core.JSValue.undefinedValue(),
        .fallback => null,
    };
}

fn qjsJsonAppendSimpleValue(
    rt: *core.JSRuntime,
    global: *core.Object,
    buffer: *std.ArrayList(u8),
    value: core.JSValue,
    array_slot: bool,
    stack: *std.ArrayList(*core.Object),
) SimpleJsonStringifyError!SimpleJsonResult {
    // Native recursion guard: the no-options fast path is the live JSON.stringify
    // route for plain values, so its per-value recursion is where deep nesting
    // must turn into a catchable InternalError "stack overflow" (QuickJS
    // js_json_to_str, quickjs.c:50075) instead of a native crash.
    if (rt.checkNativeStackOverflow(0)) return error.StackOverflow;
    if (value.isUndefined() or value.isSymbol()) {
        if (array_slot) {
            try buffer.appendSlice(rt.memory.allocator, "null");
            return .appended;
        }
        return .omitted;
    }
    if (value.isNull()) {
        try buffer.appendSlice(rt.memory.allocator, "null");
        return .appended;
    }
    if (value.isString()) {
        try appendJsonStringValue(rt, buffer, value);
        return .appended;
    }
    if (value.asBool()) |bool_value| {
        try buffer.appendSlice(rt.memory.allocator, if (bool_value) "true" else "false");
        return .appended;
    }
    if (value.asInt32()) |int_value| {
        var int_buf: [64]u8 = undefined;
        const printed = try std.fmt.bufPrint(&int_buf, "{d}", .{int_value});
        try buffer.appendSlice(rt.memory.allocator, printed);
        return .appended;
    }
    if (value_ops.numberValue(value)) |number| {
        if (!std.math.isFinite(number)) {
            try buffer.appendSlice(rt.memory.allocator, "null");
        } else if (number == 0) {
            try buffer.append(rt.memory.allocator, '0');
        } else {
            var number_buf: [128]u8 = undefined;
            const printed = try std.fmt.bufPrint(&number_buf, "{d}", .{number});
            try buffer.appendSlice(rt.memory.allocator, printed);
        }
        return .appended;
    }
    if (value.isBigInt()) return .fallback;

    const object = object_ops.objectFromValue(value) orelse {
        try buffer.appendSlice(rt.memory.allocator, "null");
        return .appended;
    };
    if (call_runtime.isCallableValue(value)) return .fallback;
    if (!qjsJsonSimplePrototypeChainHasNoToJSON(object)) return .fallback;
    if (object.flags.is_array) return try qjsJsonAppendSimpleArray(rt, global, buffer, object, stack);
    return try qjsJsonAppendSimpleObject(rt, global, buffer, object, stack);
}

fn qjsJsonSimplePrototypeChainHasNoToJSON(object: *core.Object) bool {
    const to_json_key = core.atom.ids.toJSON;
    var cursor: ?*core.Object = object;
    while (cursor) |current| {
        if (current.hasExoticMethods() or current.flags.is_proxy) return false;
        if (current.hasOwnProperty(to_json_key)) return false;
        cursor = current.getPrototype();
    }
    return true;
}

fn qjsJsonAppendSimpleArray(
    rt: *core.JSRuntime,
    global: *core.Object,
    buffer: *std.ArrayList(u8),
    object: *core.Object,
    stack: *std.ArrayList(*core.Object),
) SimpleJsonStringifyError!SimpleJsonResult {
    const start = buffer.items.len;
    if (object.hasExoticMethods() or object.arrayElementStorageMode() != .dense) return .fallback;
    if (qjsJsonObjectInStack(stack.items, object)) return error.TypeError;
    const elements = object.arrayElements();
    if (object.arrayLength() > elements.len) return .fallback;
    for (object.shapeProps()) |prop| {
        if (core.property.Flags.fromBits(prop.flags).deleted) continue;
        if (core.array.arrayIndexFromAtom(&rt.atoms, prop.atom_id) != null) return .fallback;
    }

    try stack.append(rt.memory.allocator, object);
    defer _ = stack.pop();
    errdefer buffer.shrinkRetainingCapacity(start);

    try buffer.append(rt.memory.allocator, '[');
    var index: usize = 0;
    while (index < object.arrayLength()) : (index += 1) {
        if (index != 0) try buffer.append(rt.memory.allocator, ',');
        const element = elements[index];
        switch (try qjsJsonAppendSimpleValue(rt, global, buffer, element, true, stack)) {
            .appended => {},
            .omitted => try buffer.appendSlice(rt.memory.allocator, "null"),
            .fallback => {
                buffer.shrinkRetainingCapacity(start);
                return .fallback;
            },
        }
    }
    try buffer.append(rt.memory.allocator, ']');
    return .appended;
}

fn qjsJsonAppendSimpleObject(
    rt: *core.JSRuntime,
    global: *core.Object,
    buffer: *std.ArrayList(u8),
    object: *core.Object,
    stack: *std.ArrayList(*core.Object),
) SimpleJsonStringifyError!SimpleJsonResult {
    const start = buffer.items.len;
    if (object.hasExoticMethods() or object.flags.is_proxy or object.class_id != core.class.ids.object) return .fallback;
    if (qjsJsonObjectInStack(stack.items, object)) return error.TypeError;

    try stack.append(rt.memory.allocator, object);
    defer _ = stack.pop();
    errdefer buffer.shrinkRetainingCapacity(start);

    try buffer.append(rt.memory.allocator, '{');
    var emitted = false;
    for (object.shapeProps(), 0..) |prop, property_index| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted or !prop_flags.enumerable) continue;
        if (rt.atoms.isPublicSymbol(prop.atom_id)) continue;
        if (core.array.arrayIndexFromAtom(&rt.atoms, prop.atom_id) != null) {
            buffer.shrinkRetainingCapacity(start);
            return .fallback;
        }
        if (prop_flags.isAccessor()) {
            buffer.shrinkRetainingCapacity(start);
            return .fallback;
        }
        const child_value = object.asDataAt(property_index) orelse {
            buffer.shrinkRetainingCapacity(start);
            return .fallback;
        };
        const property_start = buffer.items.len;
        if (emitted) try buffer.append(rt.memory.allocator, ',');
        try appendJsonAtomName(rt, buffer, prop.atom_id);
        try buffer.append(rt.memory.allocator, ':');
        switch (try qjsJsonAppendSimpleValue(rt, global, buffer, child_value, false, stack)) {
            .appended => emitted = true,
            .omitted => {
                buffer.shrinkRetainingCapacity(property_start);
                continue;
            },
            .fallback => {
                buffer.shrinkRetainingCapacity(start);
                return .fallback;
            },
        }
    }
    try buffer.append(rt.memory.allocator, '}');
    return .appended;
}

pub fn qjsJsonStringifyPropertyList(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    replacer: core.JSValue,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) !JsonStringifyPropertyList {
    var rooted_replacer = replacer;
    var item = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_replacer },
        .{ .value = &item },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    if (!try array_builtin.isArrayValue(rooted_replacer)) return .{};

    var list = std.ArrayList(core.Atom).empty;
    errdefer {
        for (list.items) |atom| ctx.runtime.atoms.free(atom);
        list.deinit(ctx.runtime.memory.allocator);
    }

    const length_value = try object_ops.getValueProperty(ctx, output, global, rooted_replacer, core.atom.ids.length, caller_function, caller_frame);
    defer length_value.free(ctx.runtime);
    const length = try coercion_ops.toLengthIndex(ctx, output, global, length_value);

    var index: usize = 0;
    while (index < length) : (index += 1) {
        const index_key = try object_ops.propertyAtomFromLengthIndex(ctx.runtime, index);
        defer deinitLengthIndexAtom(ctx.runtime, index_key);
        item = try object_ops.getValueProperty(ctx, output, global, rooted_replacer, index_key.atom, caller_function, caller_frame);
        defer {
            const owned_item = item;
            item = core.JSValue.undefinedValue();
            owned_item.free(ctx.runtime);
        }
        const atom = try qjsJsonStringifyPropertyListAtom(ctx, output, global, item, caller_function, caller_frame) orelse continue;
        if (qjsJsonAtomListContains(list.items, atom)) {
            ctx.runtime.atoms.free(atom);
            continue;
        }
        errdefer ctx.runtime.atoms.free(atom);
        try list.append(ctx.runtime.memory.allocator, atom);
    }

    return .{
        .items = try list.toOwnedSlice(ctx.runtime.memory.allocator),
        .has_property_list = true,
    };
}

fn qjsJsonStringifyPropertyListAtom(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) !?core.Atom {
    var rooted_value = value;
    var string_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
        .{ .value = &string_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    const needs_string = rooted_value.isString() or
        value_ops.numberValue(rooted_value) != null or
        qjsJsonIsStringOrNumberObject(rooted_value);
    if (!needs_string) return null;

    string_value = try string_ops.toStringForAnnexB(ctx, output, global, rooted_value, caller_function, caller_frame);
    defer {
        const owned_string = string_value;
        string_value = core.JSValue.undefinedValue();
        owned_string.free(ctx.runtime);
    }
    const string_object = string_value.asStringBody().?;
    return try string_object.internAtom(ctx.runtime);
}

fn qjsJsonIsStringOrNumberObject(value: core.JSValue) bool {
    const object = object_ops.objectFromValue(value) orelse return false;
    return object.class_id == core.class.ids.string or object.class_id == core.class.ids.number;
}

fn qjsJsonAtomListContains(items: []const core.Atom, atom: core.Atom) bool {
    for (items) |item| {
        if (item == atom) return true;
    }
    return false;
}

pub fn qjsJsonStringifyGap(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    space: core.JSValue,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) !std.ArrayList(u8) {
    var rooted_space = space;
    var primitive = core.JSValue.undefinedValue();
    var number_value = core.JSValue.undefinedValue();
    var string_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_space },
        .{ .value = &primitive },
        .{ .value = &number_value },
        .{ .value = &string_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    var out = std.ArrayList(u8).empty;
    if (rooted_space.isObject()) {
        if (object_ops.objectFromValue(rooted_space)) |object| {
            if (object.class_id == core.class.ids.number) {
                primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, rooted_space);
                defer {
                    const owned_primitive = primitive;
                    primitive = core.JSValue.undefinedValue();
                    owned_primitive.free(ctx.runtime);
                }
                number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
                defer {
                    const owned_number = number_value;
                    number_value = core.JSValue.undefinedValue();
                    owned_number.free(ctx.runtime);
                }
                return qjsJsonStringifyGap(ctx, output, global, number_value, caller_function, caller_frame);
            } else if (object.class_id == core.class.ids.string) {
                string_value = try string_ops.toStringForAnnexB(ctx, output, global, rooted_space, caller_function, caller_frame);
                defer {
                    const owned_string = string_value;
                    string_value = core.JSValue.undefinedValue();
                    owned_string.free(ctx.runtime);
                }
                return qjsJsonStringifyGap(ctx, output, global, string_value, caller_function, caller_frame);
            } else if (object.class_id == core.class.ids.boolean) {
                primitive = try qjsJsonPrimitiveWrapperValue(ctx.runtime, object) orelse return out;
                defer {
                    const owned_primitive = primitive;
                    primitive = core.JSValue.undefinedValue();
                    owned_primitive.free(ctx.runtime);
                }
                return qjsJsonStringifyGap(ctx, output, global, primitive, caller_function, caller_frame);
            }
        }
    }
    if (rooted_space.isString()) {
        var raw = std.ArrayList(u8).empty;
        defer raw.deinit(ctx.runtime.memory.allocator);
        try value_ops.appendRawString(ctx.runtime, &raw, rooted_space);
        try out.appendSlice(ctx.runtime.memory.allocator, raw.items[0..@min(raw.items.len, 10)]);
    } else if (value_ops.numberValue(rooted_space)) |number| {
        const count_float = @min(@max(@floor(number), 0), 10);
        const count: usize = @intFromFloat(count_float);
        try out.appendNTimes(ctx.runtime.memory.allocator, ' ', count);
    }
    return out;
}

pub fn qjsJsonSerializeProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    buffer: *std.ArrayList(u8),
    holder_value: core.JSValue,
    holder: *core.Object,
    key: core.Atom,
    array_slot: bool,
    stack: *std.ArrayList(*core.Object),
    options: JsonStringifyVmOptions,
    depth: usize,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) HostError!void {
    // Native recursion guard: deep JSON.stringify nesting is a catchable
    // InternalError "stack overflow" in QuickJS (js_json_to_str
    // JS_ThrowStackOverflow, quickjs.c:50075). error.StackOverflow maps to that
    // InternalError via runtimeErrorInfo.
    if (ctx.runtime.checkNativeStackOverflow(0)) return error.StackOverflow;
    var rooted_holder_value = holder_value;
    var rooted_replacer = options.replacer;
    var value = core.JSValue.undefinedValue();
    var key_value = core.JSValue.undefinedValue();
    var to_json = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_holder_value },
        .{ .value = &rooted_replacer },
        .{ .value = &value },
        .{ .value = &key_value },
        .{ .value = &to_json },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    value = try object_ops.getValueProperty(ctx, output, global, rooted_holder_value, key, caller_function, caller_frame);
    defer {
        const owned_value = value;
        value = core.JSValue.undefinedValue();
        owned_value.free(ctx.runtime);
    }
    key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, key);
    defer {
        const owned_key = key_value;
        key_value = core.JSValue.undefinedValue();
        owned_key.free(ctx.runtime);
    }

    if (object_ops.objectFromValue(value) != null or value.isBigInt()) {
        to_json = try object_ops.getValueProperty(ctx, output, global, value, core.atom.ids.toJSON, caller_function, caller_frame);
        defer {
            const owned_to_json = to_json;
            to_json = core.JSValue.undefinedValue();
            owned_to_json.free(ctx.runtime);
        }
        if (call_runtime.isCallableValue(to_json)) {
            const next = try call_runtime.callValueOrBytecode(ctx, output, global, value, to_json, &.{key_value}, caller_function, caller_frame);
            const old_value = value;
            value = next;
            old_value.free(ctx.runtime);
        }
    }

    if (call_runtime.isCallableValue(rooted_replacer)) {
        const next = try call_runtime.callValueOrBytecode(ctx, output, global, rooted_holder_value, rooted_replacer, &.{ key_value, value }, caller_function, caller_frame);
        const old_value = value;
        value = next;
        old_value.free(ctx.runtime);
    }

    _ = holder;
    try qjsJsonAppendValue(ctx, output, global, buffer, value, array_slot, stack, options, depth, caller_function, caller_frame);
}

pub fn qjsJsonAppendValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    buffer: *std.ArrayList(u8),
    value: core.JSValue,
    array_slot: bool,
    stack: *std.ArrayList(*core.Object),
    options: JsonStringifyVmOptions,
    depth: usize,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) !void {
    var rooted_value = value;
    var raw = core.JSValue.undefinedValue();
    var primitive = core.JSValue.undefinedValue();
    var number_value = core.JSValue.undefinedValue();
    var string_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
        .{ .value = &raw },
        .{ .value = &primitive },
        .{ .value = &number_value },
        .{ .value = &string_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    if (rooted_value.isUndefined() or rooted_value.isSymbol()) {
        try buffer.appendSlice(ctx.runtime.memory.allocator, if (array_slot) "null" else "");
    } else if (rooted_value.isNull()) {
        try buffer.appendSlice(ctx.runtime.memory.allocator, "null");
    } else if (rooted_value.isString()) {
        try appendJsonStringValue(ctx.runtime, buffer, rooted_value);
    } else if (rooted_value.asBool()) |bool_value| {
        try buffer.appendSlice(ctx.runtime.memory.allocator, if (bool_value) "true" else "false");
    } else if (value_ops.numberValue(rooted_value)) |number| {
        if (!std.math.isFinite(number)) {
            try buffer.appendSlice(ctx.runtime.memory.allocator, "null");
        } else if (number == 0) {
            try buffer.append(ctx.runtime.memory.allocator, '0');
        } else {
            var number_buf: [128]u8 = undefined;
            const printed = try std.fmt.bufPrint(&number_buf, "{d}", .{number});
            try buffer.appendSlice(ctx.runtime.memory.allocator, printed);
        }
    } else if (rooted_value.isBigInt()) {
        return error.TypeError;
    } else if (object_ops.objectFromValue(rooted_value)) |object| {
        if (object.class_id == core.class.ids.raw_json) {
            raw = object.getProperty(core.atom.ids.rawJSON);
            defer {
                const owned_raw = raw;
                raw = core.JSValue.undefinedValue();
                owned_raw.free(ctx.runtime);
            }
            var raw_bytes = std.ArrayList(u8).empty;
            defer raw_bytes.deinit(ctx.runtime.memory.allocator);
            try value_ops.appendRawString(ctx.runtime, &raw_bytes, raw);
            try buffer.appendSlice(ctx.runtime.memory.allocator, raw_bytes.items);
        } else if (call_runtime.isCallableValue(rooted_value)) {
            try buffer.appendSlice(ctx.runtime.memory.allocator, if (array_slot) "null" else "");
        } else if (object.class_id == core.class.ids.number) {
            primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, rooted_value);
            defer {
                const owned_primitive = primitive;
                primitive = core.JSValue.undefinedValue();
                owned_primitive.free(ctx.runtime);
            }
            number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
            defer {
                const owned_number = number_value;
                number_value = core.JSValue.undefinedValue();
                owned_number.free(ctx.runtime);
            }
            try qjsJsonAppendValue(ctx, output, global, buffer, number_value, array_slot, stack, options, depth, caller_function, caller_frame);
        } else if (object.class_id == core.class.ids.string) {
            string_value = try string_ops.toStringForAnnexB(ctx, output, global, rooted_value, caller_function, caller_frame);
            defer {
                const owned_string = string_value;
                string_value = core.JSValue.undefinedValue();
                owned_string.free(ctx.runtime);
            }
            try qjsJsonAppendValue(ctx, output, global, buffer, string_value, array_slot, stack, options, depth, caller_function, caller_frame);
        } else if (object.class_id == core.class.ids.boolean) {
            primitive = try qjsJsonPrimitiveWrapperValue(ctx.runtime, object) orelse core.JSValue.undefinedValue();
            defer {
                const owned_primitive = primitive;
                primitive = core.JSValue.undefinedValue();
                owned_primitive.free(ctx.runtime);
            }
            try qjsJsonAppendValue(ctx, output, global, buffer, primitive, array_slot, stack, options, depth, caller_function, caller_frame);
        } else if (object.class_id == core.class.ids.big_int) {
            primitive = coercion_ops.primitiveWrapperStoredValue(ctx.runtime, rooted_value) orelse return error.TypeError;
            defer {
                const owned_primitive = primitive;
                primitive = core.JSValue.undefinedValue();
                owned_primitive.free(ctx.runtime);
            }
            try qjsJsonAppendValue(ctx, output, global, buffer, primitive, array_slot, stack, options, depth, caller_function, caller_frame);
        } else if (try array_builtin.isArrayValue(rooted_value)) {
            try qjsJsonAppendArray(ctx, output, global, buffer, rooted_value, object, stack, options, depth, caller_function, caller_frame);
        } else {
            try qjsJsonAppendObject(ctx, output, global, buffer, rooted_value, object, stack, options, depth, caller_function, caller_frame);
        }
    } else {
        try buffer.appendSlice(ctx.runtime.memory.allocator, "null");
    }
}

pub fn qjsJsonAppendArray(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    buffer: *std.ArrayList(u8),
    value: core.JSValue,
    object: *core.Object,
    stack: *std.ArrayList(*core.Object),
    options: JsonStringifyVmOptions,
    depth: usize,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) !void {
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    if (qjsJsonObjectInStack(stack.items, object)) return error.TypeError;
    try stack.append(ctx.runtime.memory.allocator, object);
    defer _ = stack.pop();
    const length_value = try object_ops.getValueProperty(ctx, output, global, rooted_value, core.atom.ids.length, caller_function, caller_frame);
    defer length_value.free(ctx.runtime);
    const length = try coercion_ops.toLengthIndex(ctx, output, global, length_value);
    try buffer.append(ctx.runtime.memory.allocator, '[');
    var index: usize = 0;
    while (index < length) : (index += 1) {
        if (index != 0) try buffer.append(ctx.runtime.memory.allocator, ',');
        if (options.gap.len != 0) {
            try buffer.append(ctx.runtime.memory.allocator, '\n');
            try qjsJsonAppendIndent(ctx.runtime, buffer, options.gap, depth + 1);
        }
        const child_key = try object_ops.propertyAtomFromLengthIndex(ctx.runtime, index);
        defer deinitLengthIndexAtom(ctx.runtime, child_key);
        try qjsJsonSerializeProperty(ctx, output, global, buffer, rooted_value, object, child_key.atom, true, stack, options, depth + 1, caller_function, caller_frame);
    }
    if (options.gap.len != 0 and length != 0) {
        try buffer.append(ctx.runtime.memory.allocator, '\n');
        try qjsJsonAppendIndent(ctx.runtime, buffer, options.gap, depth);
    }
    try buffer.append(ctx.runtime.memory.allocator, ']');
}

pub fn qjsJsonAppendObject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    buffer: *std.ArrayList(u8),
    value: core.JSValue,
    object: *core.Object,
    stack: *std.ArrayList(*core.Object),
    options: JsonStringifyVmOptions,
    depth: usize,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) !void {
    var rooted_value = value;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    if (qjsJsonObjectInStack(stack.items, object)) return error.TypeError;
    try stack.append(ctx.runtime.memory.allocator, object);
    defer _ = stack.pop();
    try buffer.append(ctx.runtime.memory.allocator, '{');
    const owned_keys: []core.Atom = if (!options.has_property_list) try object_ops.objectRestOwnKeys(ctx, output, global, object) else &.{};
    defer if (!options.has_property_list) core.Object.freeKeys(ctx.runtime, owned_keys);
    var enumerable_keys = std.ArrayList(core.Atom).empty;
    defer enumerable_keys.deinit(ctx.runtime.memory.allocator);
    if (!options.has_property_list) {
        for (owned_keys) |key| {
            if (ctx.runtime.atoms.isPublicSymbol(key)) continue;
            const desc = try object_ops.objectRestOwnPropertyDescriptor(ctx, output, global, object, key) orelse continue;
            defer desc.destroy(ctx.runtime);
            if (desc.enumerable == true) try enumerable_keys.append(ctx.runtime.memory.allocator, key);
        }
    }
    const keys = if (options.has_property_list) options.property_list else enumerable_keys.items;
    var emitted = false;
    for (keys) |key| {
        if (ctx.runtime.atoms.isPublicSymbol(key)) continue;
        const before = buffer.items.len;
        var child = std.ArrayList(u8).empty;
        defer child.deinit(ctx.runtime.memory.allocator);
        try qjsJsonSerializeProperty(ctx, output, global, &child, rooted_value, object, key, false, stack, options, depth + 1, caller_function, caller_frame);
        if (child.items.len == 0) {
            buffer.shrinkRetainingCapacity(before);
            continue;
        }
        if (emitted) try buffer.append(ctx.runtime.memory.allocator, ',');
        if (options.gap.len != 0) {
            try buffer.append(ctx.runtime.memory.allocator, '\n');
            try qjsJsonAppendIndent(ctx.runtime, buffer, options.gap, depth + 1);
        }
        emitted = true;
        try appendJsonAtomName(ctx.runtime, buffer, key);
        try buffer.appendSlice(ctx.runtime.memory.allocator, if (options.gap.len == 0) ":" else ": ");
        try buffer.appendSlice(ctx.runtime.memory.allocator, child.items);
    }
    if (options.gap.len != 0 and emitted) {
        try buffer.append(ctx.runtime.memory.allocator, '\n');
        try qjsJsonAppendIndent(ctx.runtime, buffer, options.gap, depth);
    }
    try buffer.append(ctx.runtime.memory.allocator, '}');
}

pub fn qjsJsonPrimitiveWrapperValue(rt: *core.JSRuntime, object: *core.Object) !?core.JSValue {
    _ = rt;
    if (object.class_id == core.class.ids.string) {
        if (object.objectData()) |stored| return stored.dup();
    }
    switch (object.class_id) {
        core.class.ids.number,
        core.class.ids.boolean,
        core.class.ids.big_int,
        core.class.ids.symbol,
        => return if (object.objectData()) |stored| stored.dup() else null,
        else => return null,
    }
}

pub fn qjsJsonObjectInStack(items: []const *core.Object, object: *core.Object) bool {
    for (items) |item| {
        if (item == object) return true;
    }
    return false;
}

pub fn qjsJsonAppendIndent(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), gap: []const u8, depth: usize) !void {
    var index: usize = 0;
    while (index < depth) : (index += 1) try buffer.appendSlice(rt.memory.allocator, gap);
}
