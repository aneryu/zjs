//! QuickJS source map: js_json_obj / js_json_funcs (JS_ParseJSON,
//! js_json_stringify) in quickjs.c. Implementation and declaration table live
//! side by side, matching QuickJS's JSCFunctionListEntry pattern.

const core = @import("../core/root.zig");
const unicode = @import("../libs/unicode.zig");
const std = @import("std");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call_runtime = @import("call_runtime.zig");
const coercion_ops = @import("coercion_ops.zig");
const exception_ops = @import("vm_exception_ops.zig");
const exceptions = @import("exceptions.zig");
const object_ops = @import("object_ops.zig");
const string_ops = @import("string_ops.zig");
const value_ops = @import("value_ops.zig");

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
    StringTooLong,
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
    if (host_call.global) |raw_global| {
        const input = if (!value.isString()) input: {
            const coerced = try string_ops.toStringForAnnexB(host_call.ctx, host_call.output, raw_global, value, builtin_dispatch.callerBytecode(host_call), builtin_dispatch.callerFrame(host_call));
            defer coerced.free(host_call.ctx.runtime);
            break :input coerced;
        } else value;
        return rawJSON(host_call.ctx.runtime, input) catch |err| switch (err) {
            error.SyntaxError => exception_ops.throwSyntaxErrorMessage(host_call.ctx, raw_global, "invalid rawJSON string"),
            error.TypeError => err,
            else => err,
        };
    }
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

    if (rooted_value.asStringBody()) |body| {
        try body.ensureFlat(rt);
        return switch (body.resolveData()) {
            .latin1 => |latin1| jsonParseFull(u8, rt, global, latin1),
            .utf16 => |units| jsonParseFull(u16, rt, global, units),
        };
    }
    return jsonParseFullFromBytes(rt, global, bytes.items);
}

pub const JsonParseWithRecord = struct {
    value: core.JSValue,
    record: JsonParseRecord,

    fn deinit(self: *JsonParseWithRecord, rt: *core.JSRuntime) void {
        self.record.deinit(rt);
        const owned = self.value;
        self.value = core.JSValue.undefinedValue();
        owned.free(rt);
    }
};

/// Parse `value` and build the parallel parse-record tree in lockstep, mirroring
/// qjs js_json_parse's reviver branch which calls JS_ParseJSON3 with a live
/// `pr` (quickjs.c:49834). Unlike `parse`, this never takes the record-less
/// simple fast path: the reviver needs the full record for `context.source`.
/// Caller owns both the returned value and record (record.deinit frees the
/// tree; the value must be freed separately).
pub fn parseWithRecord(rt: *core.JSRuntime, global: ?*core.Object, value: core.JSValue) !JsonParseWithRecord {
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

    if (rooted_value.asStringBody()) |body| {
        try body.ensureFlat(rt);
        return switch (body.resolveData()) {
            .latin1 => |latin1| jsonParseFullWithRecord(u8, rt, global, latin1),
            .utf16 => |units| jsonParseFullWithRecord(u16, rt, global, units),
        };
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.memory.allocator);
    try appendJsonInputString(rt, &bytes, rooted_value);
    const text = try core.string.String.createUtf8(rt, bytes.items);
    defer text.value().free(rt);
    try text.ensureFlat(rt);
    return switch (text.resolveData()) {
        .latin1 => |latin1| jsonParseFullWithRecord(u8, rt, global, latin1),
        .utf16 => |units| jsonParseFullWithRecord(u16, rt, global, units),
    };
}

fn jsonParseFullWithRecord(comptime T: type, rt: *core.JSRuntime, global: ?*core.Object, units: []const T) !JsonParseWithRecord {
    var parser = JsonUnitParser(T){ .rt = rt, .global = global, .units = units };
    parser.skipWhitespace();
    var record: JsonParseRecord = undefined;
    const value = try parser.parseValueRecord(&record);
    errdefer {
        record.deinit(rt);
        value.free(rt);
    }
    parser.skipWhitespace();
    if (parser.index != parser.units.len) return error.SyntaxError;
    return .{ .value = value, .record = record };
}

/// Coerced (non-string) inputs: decode the UTF-8 bytes into a real string and
/// parse its code units through the same faithful walk.
fn jsonParseFullFromBytes(rt: *core.JSRuntime, global: ?*core.Object, bytes: []const u8) !core.JSValue {
    const text = try core.string.String.createUtf8(rt, bytes);
    defer text.value().free(rt);
    try text.ensureFlat(rt);
    return switch (text.resolveData()) {
        .latin1 => |latin1| jsonParseFull(u8, rt, global, latin1),
        .utf16 => |units| jsonParseFull(u16, rt, global, units),
    };
}

/// Faithful port of the qjs JSON parser (js_json_parse -> json_next_token /
/// json_parse_value, quickjs.c:23440): recursive descent over the source
/// string's CODE UNITS (WTF-16; lone surrogates in string literals are legal
/// JSON and round-trip, unlike the retired std.json backend), JSON whitespace
/// only, strict number grammar, last-duplicate-key-wins, own "__proto__"
/// property (no prototype mutation). Depth is bounded by the native stack
/// guard (json_next_token js_check_stack_overflow, quickjs.c:23483).
fn jsonParseFull(comptime T: type, rt: *core.JSRuntime, global: ?*core.Object, units: []const T) !core.JSValue {
    var parser = JsonUnitParser(T){ .rt = rt, .global = global, .units = units };
    parser.skipWhitespace();
    const value = try parser.parseValue();
    errdefer value.free(rt);
    parser.skipWhitespace();
    if (parser.index != parser.units.len) return error.SyntaxError;
    return value;
}

const JsonParseError = std.mem.Allocator.Error || error{
    SyntaxError,
    TypeError,
    IncompatibleDescriptor,
    InvalidAtom,
    InvalidLength,
    NotExtensible,
    ReadOnly,
    StringTooLong,
};

/// Parallel parse-record tree, mirroring qjs's `JSONParseRecord`
/// (quickjs.c:49336). Built during parse *only* when a reviver is present, so
/// `internalize_json_property` can attach `context.source` for primitives and
/// perform the `js_same_value(pr->value, val)` guard (quickjs.c:49740). Each
/// node caches the value produced at parse time (`value`, dup'd so it survives
/// reviver mutations that would otherwise free the original) and, for
/// primitives, the raw source-text span. Object entries are stored in document
/// order and `findObjectEntry` returns the FIRST entry for a key (qjs
/// json_parse_record_find, quickjs.c:49430): under duplicate keys the recorded
/// value therefore differs from the last-wins property value, so the same-value
/// guard drops the source, matching qjs.
const JsonParseRecord = union(enum) {
    /// Non-object leaf (string / number / boolean / null). `source` holds the
    /// WTF-8 bytes of the original source span (qjs stores source_pos/source_len
    /// into text_str; quickjs.c:49786).
    primitive: struct { value: core.JSValue, source: []u8 },
    array: struct { value: core.JSValue, elements: []JsonParseRecord },
    object: struct { value: core.JSValue, entries: []JsonParseRecordEntry },

    fn recordValue(self: *const JsonParseRecord) core.JSValue {
        return switch (self.*) {
            .primitive => |p| p.value,
            .array => |a| a.value,
            .object => |o| o.value,
        };
    }

    /// Locate the child record for `atom` under an object record. Mirrors
    /// json_parse_record_find: FIRST match wins (quickjs.c:49430).
    fn findObjectEntry(self: *const JsonParseRecord, atom: core.Atom) ?*const JsonParseRecord {
        switch (self.*) {
            .object => |o| {
                for (o.entries) |*entry| {
                    if (entry.atom == atom) return &entry.record;
                }
                return null;
            },
            else => return null,
        }
    }

    fn arrayElement(self: *const JsonParseRecord, index: usize) ?*const JsonParseRecord {
        switch (self.*) {
            .array => |a| {
                if (index < a.elements.len) return &a.elements[index];
                return null;
            },
            else => return null,
        }
    }

    /// Recursively free the record tree (owned atoms, source bytes, element
    /// arrays). Mirrors json_free_parse_record (quickjs.c:49459). The cached
    /// `value` is dup'd on record creation, so it is freed here.
    fn deinit(self: *JsonParseRecord, rt: *core.JSRuntime) void {
        switch (self.*) {
            .primitive => |*p| {
                p.value.free(rt);
                if (p.source.len != 0) rt.memory.allocator.free(p.source);
            },
            .array => |*a| {
                a.value.free(rt);
                for (a.elements) |*element| element.deinit(rt);
                rt.memory.allocator.free(a.elements);
            },
            .object => |*o| {
                o.value.free(rt);
                for (o.entries) |*entry| {
                    rt.atoms.free(entry.atom);
                    entry.record.deinit(rt);
                }
                rt.memory.allocator.free(o.entries);
            },
        }
    }

    /// Append every cached record value into `out` so the GC roots the whole
    /// tree for the duration of the reviver walk. qjs keeps them alive via the
    /// ref-counted `pr->value` fields; zjs needs an explicit root slice.
    fn collectValues(self: *const JsonParseRecord, allocator: std.mem.Allocator, out: *std.ArrayList(core.JSValue)) std.mem.Allocator.Error!void {
        switch (self.*) {
            .primitive => |p| try out.append(allocator, p.value),
            .array => |a| {
                try out.append(allocator, a.value);
                for (a.elements) |*element| try element.collectValues(allocator, out);
            },
            .object => |o| {
                try out.append(allocator, o.value);
                for (o.entries) |*entry| try entry.record.collectValues(allocator, out);
            },
        }
    }
};

const JsonParseRecordEntry = struct {
    atom: core.Atom,
    record: JsonParseRecord,
};

fn JsonUnitParser(comptime T: type) type {
    return struct {
        rt: *core.JSRuntime,
        global: ?*core.Object,
        units: []const T,
        index: usize = 0,

        const Self = @This();

        fn peek(self: *const Self) ?T {
            if (self.index >= self.units.len) return null;
            return self.units[self.index];
        }

        fn skipWhitespace(self: *Self) void {
            while (self.index < self.units.len) : (self.index += 1) {
                switch (self.units[self.index]) {
                    ' ', '\t', '\n', '\r' => {},
                    else => return,
                }
            }
        }

        fn expectLiteral(self: *Self, comptime text: []const u8) !void {
            if (self.index + text.len > self.units.len) return error.SyntaxError;
            inline for (text, 0..) |byte, offset| {
                if (self.units[self.index + offset] != byte) return error.SyntaxError;
            }
            self.index += text.len;
        }

        fn parseValue(self: *Self) JsonParseError!core.JSValue {
            return self.parseValueRecord(null);
        }

        /// Faithful port of qjs json_parse_value(s, pr) (quickjs.c:49484). When
        /// `record` is non-null, the parse also fills the parallel parse-record
        /// (value + primitive source span) so the reviver walk can attach
        /// `context.source` and run the same-value guard.
        fn parseValueRecord(self: *Self, record: ?*JsonParseRecord) JsonParseError!core.JSValue {
            if (self.rt.checkNativeStackOverflow(0)) return error.SyntaxError;
            self.skipWhitespace();
            const start = self.index;
            const unit = self.peek() orelse return error.SyntaxError;
            const value = switch (unit) {
                '{' => return self.parseObject(record),
                '[' => return self.parseArray(record),
                '"' => try self.parseString(),
                't' => blk: {
                    try self.expectLiteral("true");
                    break :blk core.JSValue.boolean(true);
                },
                'f' => blk: {
                    try self.expectLiteral("false");
                    break :blk core.JSValue.boolean(false);
                },
                'n' => blk: {
                    try self.expectLiteral("null");
                    break :blk core.JSValue.nullValue();
                },
                '-', '0'...'9' => try self.parseNumber(),
                else => return error.SyntaxError,
            };
            // Primitive leaf: record the value plus its raw source span
            // (json_parse_record_init_primitive, quickjs.c:49373). The span is
            // the code units [start, index); for strings this includes the
            // enclosing quotes, matching qjs's s->token.ptr..s->buf_ptr.
            if (record) |slot| {
                errdefer value.free(self.rt);
                const source = try self.recordSourceSpan(start, self.index);
                slot.* = .{ .primitive = .{ .value = value.dup(), .source = source } };
            }
            return value;
        }

        fn recordSourceSpan(self: *Self, start: usize, end: usize) ![]u8 {
            var bytes = std.ArrayList(u8).empty;
            errdefer bytes.deinit(self.rt.memory.allocator);
            if (T == u16) {
                try appendWtf8FromUnits(self.rt, &bytes, self.units[start..end]);
            } else {
                // Latin1 units are code points 0..255; widen and reuse the
                // WTF-8 encoder so bytes >= 0x80 emit their two-byte form.
                for (self.units[start..end]) |unit| {
                    const widened = [_]u16{unit};
                    try appendWtf8FromUnits(self.rt, &bytes, &widened);
                }
            }
            return bytes.toOwnedSlice(self.rt.memory.allocator);
        }

        fn parseObject(self: *Self, record: ?*JsonParseRecord) JsonParseError!core.JSValue {
            self.index += 1; // '{'
            const object = try core.Object.create(self.rt, core.class.ids.object, objectPrototypeFromGlobal(self.rt, self.global));
            var object_value = object.value();
            var root_values = [_]core.runtime.ValueRootValue{.{ .value = &object_value }};
            const root_frame = core.runtime.ValueRootFrame{ .previous = self.rt.active_value_roots, .values = &root_values };
            self.rt.active_value_roots = &root_frame;
            defer self.rt.active_value_roots = root_frame.previous;
            errdefer {
                const failed = object_value;
                object_value = core.JSValue.undefinedValue();
                failed.free(self.rt);
            }
            // json_parse_record_init_obj (quickjs.c:49508): the object record
            // caches the object value plus one entry per key OCCURRENCE (dup keys
            // add separate entries, document order).
            var entries = std.ArrayList(JsonParseRecordEntry).empty;
            errdefer if (record != null) {
                for (entries.items) |*entry| {
                    self.rt.atoms.free(entry.atom);
                    entry.record.deinit(self.rt);
                }
                entries.deinit(self.rt.memory.allocator);
            };
            self.skipWhitespace();
            if (self.peek() == @as(T, '}')) {
                self.index += 1;
                if (record) |slot| slot.* = .{ .object = .{ .value = object_value.dup(), .entries = try entries.toOwnedSlice(self.rt.memory.allocator) } };
                return object_value;
            }
            while (true) {
                self.skipWhitespace();
                if (self.peek() != @as(T, '"')) return error.SyntaxError;
                const key_atom = try self.parseKeyAtom();
                defer self.rt.atoms.free(key_atom);
                self.skipWhitespace();
                if (self.peek() != @as(T, ':')) return error.SyntaxError;
                self.index += 1;
                var child_slot_storage: JsonParseRecord = undefined;
                const child_slot: ?*JsonParseRecord = if (record != null) &child_slot_storage else null;
                const child = try self.parseValueRecord(child_slot);
                defer child.free(self.rt);
                // Append the record entry BEFORE defineOwnProperty so any later
                // failure is covered by the `entries` errdefer (no orphaned
                // child_slot_storage). A dup key adds a separate entry
                // (json_parse_record_add, quickjs.c:49405).
                if (child_slot) |slot| {
                    entries.append(self.rt.memory.allocator, .{ .atom = self.rt.atoms.dup(key_atom), .record = slot.* }) catch |err| {
                        slot.deinit(self.rt);
                        return err;
                    };
                }
                try object.defineOwnProperty(self.rt, key_atom, core.Descriptor.data(child, true, true, true));
                self.skipWhitespace();
                const next = self.peek() orelse return error.SyntaxError;
                if (next == '}') {
                    self.index += 1;
                    if (record) |slot| slot.* = .{ .object = .{ .value = object_value.dup(), .entries = try entries.toOwnedSlice(self.rt.memory.allocator) } };
                    return object_value;
                }
                if (next != ',') return error.SyntaxError;
                self.index += 1;
            }
        }

        fn parseArray(self: *Self, record: ?*JsonParseRecord) JsonParseError!core.JSValue {
            self.index += 1; // '['
            const object = try core.Object.createArray(self.rt, arrayPrototypeFromGlobal(self.rt, self.global));
            var object_value = object.value();
            var root_values = [_]core.runtime.ValueRootValue{.{ .value = &object_value }};
            const root_frame = core.runtime.ValueRootFrame{ .previous = self.rt.active_value_roots, .values = &root_values };
            self.rt.active_value_roots = &root_frame;
            defer self.rt.active_value_roots = root_frame.previous;
            errdefer {
                const failed = object_value;
                object_value = core.JSValue.undefinedValue();
                failed.free(self.rt);
            }
            // json_parse_record_init_array (quickjs.c:49571): one element record
            // per array slot, in order.
            var elements = std.ArrayList(JsonParseRecord).empty;
            errdefer if (record != null) {
                for (elements.items) |*element| element.deinit(self.rt);
                elements.deinit(self.rt.memory.allocator);
            };
            self.skipWhitespace();
            if (self.peek() == @as(T, ']')) {
                self.index += 1;
                if (record) |slot| slot.* = .{ .array = .{ .value = object_value.dup(), .elements = try elements.toOwnedSlice(self.rt.memory.allocator) } };
                return object_value;
            }
            var index: u32 = 0;
            while (true) {
                var child_slot_storage: JsonParseRecord = undefined;
                const child_slot: ?*JsonParseRecord = if (record != null) &child_slot_storage else null;
                const child = try self.parseValueRecord(child_slot);
                defer child.free(self.rt);
                // Append the element record BEFORE storing into the array so any
                // later failure is covered by the `elements` errdefer.
                if (child_slot) |slot| {
                    elements.append(self.rt.memory.allocator, slot.*) catch |err| {
                        slot.deinit(self.rt);
                        return err;
                    };
                }
                if (!try object.appendDenseArrayLiteralIndex(self.rt, index, child)) {
                    try object.defineOwnProperty(self.rt, core.atom.atomFromUInt32(index), core.Descriptor.data(child, true, true, true));
                }
                index += 1;
                self.skipWhitespace();
                const next = self.peek() orelse return error.SyntaxError;
                if (next == ']') {
                    self.index += 1;
                    if (record) |slot| slot.* = .{ .array = .{ .value = object_value.dup(), .elements = try elements.toOwnedSlice(self.rt.memory.allocator) } };
                    return object_value;
                }
                if (next != ',') return error.SyntaxError;
                self.index += 1;
            }
        }

        fn parseKeyAtom(self: *Self) !core.Atom {
            var key_units = std.ArrayList(u16).empty;
            defer key_units.deinit(self.rt.memory.allocator);
            try self.parseStringUnits(&key_units);
            var key_bytes = std.ArrayList(u8).empty;
            defer key_bytes.deinit(self.rt.memory.allocator);
            try appendWtf8FromUnits(self.rt, &key_bytes, key_units.items);
            return self.rt.internAtom(key_bytes.items);
        }

        fn parseString(self: *Self) !core.JSValue {
            var out = std.ArrayList(u16).empty;
            defer out.deinit(self.rt.memory.allocator);
            try self.parseStringUnits(&out);
            return (try core.string.String.createUtf16(self.rt, out.items)).value();
        }

        /// qjs js_parse_string JSON mode: raw code units pass through (including
        /// lone surrogates), \uXXXX escapes decode to bare units.
        fn parseStringUnits(self: *Self, out: *std.ArrayList(u16)) !void {
            self.index += 1; // opening quote
            while (true) {
                if (self.index >= self.units.len) return error.SyntaxError;
                const unit = self.units[self.index];
                self.index += 1;
                if (unit == '"') return;
                if (unit == '\\') {
                    if (self.index >= self.units.len) return error.SyntaxError;
                    const escape = self.units[self.index];
                    self.index += 1;
                    switch (escape) {
                        '"' => try out.append(self.rt.memory.allocator, '"'),
                        '\\' => try out.append(self.rt.memory.allocator, '\\'),
                        '/' => try out.append(self.rt.memory.allocator, '/'),
                        'b' => try out.append(self.rt.memory.allocator, 0x08),
                        'f' => try out.append(self.rt.memory.allocator, 0x0c),
                        'n' => try out.append(self.rt.memory.allocator, 0x0a),
                        'r' => try out.append(self.rt.memory.allocator, 0x0d),
                        't' => try out.append(self.rt.memory.allocator, 0x09),
                        'u' => {
                            if (self.index + 4 > self.units.len) return error.SyntaxError;
                            var code: u16 = 0;
                            inline for (0..4) |_| {
                                const digit = jsonHexDigit(self.units[self.index]) orelse return error.SyntaxError;
                                code = (code << 4) | digit;
                                self.index += 1;
                            }
                            try out.append(self.rt.memory.allocator, code);
                        },
                        else => return error.SyntaxError,
                    }
                    continue;
                }
                if (unit < 0x20) return error.SyntaxError;
                if (T == u8) {
                    try out.append(self.rt.memory.allocator, unit);
                } else {
                    try out.append(self.rt.memory.allocator, unit);
                }
            }
        }

        fn parseNumber(self: *Self) !core.JSValue {
            const start = self.index;
            var ascii = std.ArrayList(u8).empty;
            defer ascii.deinit(self.rt.memory.allocator);
            var had_fraction = false;
            if (self.peek() == @as(T, '-')) self.index += 1;
            // integer part: 0 | [1-9][0-9]*
            const first = self.peek() orelse return error.SyntaxError;
            if (first == '0') {
                self.index += 1;
            } else if (first >= '1' and first <= '9') {
                while (self.peek()) |unit| {
                    if (unit < '0' or unit > '9') break;
                    self.index += 1;
                }
            } else return error.SyntaxError;
            if (self.peek() == @as(T, '.')) {
                had_fraction = true;
                self.index += 1;
                var digits: usize = 0;
                while (self.peek()) |unit| {
                    if (unit < '0' or unit > '9') break;
                    self.index += 1;
                    digits += 1;
                }
                if (digits == 0) return error.SyntaxError;
            }
            if (self.peek() == @as(T, 'e') or self.peek() == @as(T, 'E')) {
                had_fraction = true;
                self.index += 1;
                if (self.peek() == @as(T, '+') or self.peek() == @as(T, '-')) self.index += 1;
                var digits: usize = 0;
                while (self.peek()) |unit| {
                    if (unit < '0' or unit > '9') break;
                    self.index += 1;
                    digits += 1;
                }
                if (digits == 0) return error.SyntaxError;
            }
            try ascii.ensureTotalCapacity(self.rt.memory.allocator, self.index - start);
            for (self.units[start..self.index]) |unit| ascii.appendAssumeCapacity(@intCast(unit));
            const text = ascii.items;
            if (!had_fraction) {
                if (std.fmt.parseInt(i64, text, 10)) |int_value| {
                    if (int_value >= std.math.minInt(i32) and int_value <= std.math.maxInt(i32)) {
                        if (!(int_value == 0 and text[0] == '-')) return core.JSValue.int32(@intCast(int_value));
                    }
                    return core.JSValue.float64(@floatFromInt(int_value));
                } else |_| {}
            }
            const float_value = std.fmt.parseFloat(f64, text) catch return error.SyntaxError;
            return core.JSValue.float64(float_value);
        }
    };
}

fn jsonHexDigit(unit: anytype) ?u16 {
    return switch (unit) {
        '0'...'9' => @intCast(unit - '0'),
        'a'...'f' => @intCast(unit - 'a' + 10),
        'A'...'F' => @intCast(unit - 'A' + 10),
        else => null,
    };
}

/// Encode UTF-16 code units as WTF-8 bytes (surrogate pairs join; lone
/// surrogates encode as their 3-byte form): the atom-name byte encoding.
fn appendWtf8FromUnits(rt: *core.JSRuntime, out: *std.ArrayList(u8), units: []const u16) !void {
    var index: usize = 0;
    while (index < units.len) : (index += 1) {
        const unit = units[index];
        var cp: u32 = unit;
        if (unit >= 0xD800 and unit <= 0xDBFF and index + 1 < units.len) {
            const next = units[index + 1];
            if (next >= 0xDC00 and next <= 0xDFFF) {
                cp = 0x10000 + ((@as(u32, unit) - 0xD800) << 10) + (next - 0xDC00);
                index += 1;
            }
        }
        if (cp < 0x80) {
            try out.append(rt.memory.allocator, @intCast(cp));
        } else if (cp < 0x800) {
            try out.append(rt.memory.allocator, @intCast(0xc0 | (cp >> 6)));
            try out.append(rt.memory.allocator, @intCast(0x80 | (cp & 0x3f)));
        } else if (cp < 0x10000) {
            try out.append(rt.memory.allocator, @intCast(0xe0 | (cp >> 12)));
            try out.append(rt.memory.allocator, @intCast(0x80 | ((cp >> 6) & 0x3f)));
            try out.append(rt.memory.allocator, @intCast(0x80 | (cp & 0x3f)));
        } else {
            try out.append(rt.memory.allocator, @intCast(0xf0 | (cp >> 18)));
            try out.append(rt.memory.allocator, @intCast(0x80 | ((cp >> 12) & 0x3f)));
            try out.append(rt.memory.allocator, @intCast(0x80 | ((cp >> 6) & 0x3f)));
            try out.append(rt.memory.allocator, @intCast(0x80 | (cp & 0x3f)));
        }
    }
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

    {
        const validated = try jsonParseFullFromBytes(rt, null, bytes.items);
        defer validated.free(rt);
        if (validated.isObject()) return error.SyntaxError;
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
    try object.seal(rt);
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
            const printed = try value_ops.formatFiniteNumber(&number_buf, float_value);
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
            try value_ops.formatFiniteNumber(&buf, float_value);
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
        const printed = try value_ops.formatFiniteNumber(&float_buf, float_value);
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

const SimpleJsonStringifyError = std.mem.Allocator.Error || error{
    InvalidUtf8,
    NoSpaceLeft,
    TypeError,
    StackOverflow,
    StringTooLong,
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

    // No reviver: plain parse (may take the record-less simple fast path).
    if (!call_runtime.isCallableValue(reviver)) {
        return try parse(ctx.runtime, global, text);
    }

    // Reviver present: build the parallel parse-record tree in lockstep so
    // internalize can attach context.source and run the same-value guard,
    // mirroring qjs js_json_parse (JS_ParseJSON3 with a live pr,
    // quickjs.c:49834).
    var parse_result = try parseWithRecord(ctx.runtime, global, text);
    // The record tree is freed after the walk returns and, crucially, after the
    // record-value root frame below is popped (deinit registered first => runs
    // last), so the borrowed record values stay rooted for the whole walk.
    defer parse_result.record.deinit(ctx.runtime);
    parsed = parse_result.value;
    parse_result.value = core.JSValue.undefinedValue();
    errdefer {
        const owned_parsed = parsed;
        parsed = core.JSValue.undefinedValue();
        owned_parsed.free(ctx.runtime);
    }

    // Root every cached record value for the duration of the walk (qjs keeps
    // them alive via the ref-counted JSONParseRecord.value fields).
    var record_values = std.ArrayList(core.JSValue).empty;
    defer record_values.deinit(ctx.runtime.memory.allocator);
    try parse_result.record.collectValues(ctx.runtime.memory.allocator, &record_values);
    var record_root_slices = [_]core.runtime.ValueRootSlice{
        .{ .mutable = &record_values.items },
    };
    const record_root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .slices = &record_root_slices,
    };
    ctx.runtime.active_value_roots = &record_root_frame;
    defer ctx.runtime.active_value_roots = record_root_frame.previous;

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

    return try qjsJsonInternalizeProperty(ctx, output, global, holder_value, root_key, reviver, &parse_result.record, caller_function, caller_frame);
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

/// Faithful port of internalize_json_property (quickjs.c:49708). `record` is the
/// parse record for `holder[key]` (already located by the caller; the root
/// call passes the record for the whole parsed value, recursion passes the
/// located child record), or null when there is no record / it was cleared by
/// the same-value guard. Performs exactly ONE [[Get]] per property (json#9: the
/// prior implementation did up to three), then recurses over children, then
/// invokes the reviver with a `context` carrying `source` only for primitives
/// whose parse-time value still matches (json#8).
pub fn qjsJsonInternalizeProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    holder_value: core.JSValue,
    key: core.Atom,
    reviver: core.JSValue,
    record: ?*const JsonParseRecord,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) HostError!core.JSValue {
    var rooted_holder_value = holder_value;
    var rooted_reviver = reviver;
    var value = core.JSValue.undefinedValue();
    var key_value = core.JSValue.undefinedValue();
    var context_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_holder_value },
        .{ .value = &rooted_reviver },
        .{ .value = &value },
        .{ .value = &key_value },
        .{ .value = &context_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    // ONE [[Get]] per property (val = JS_GetProperty(holder, name),
    // quickjs.c:49722).
    value = try object_ops.getValueProperty(ctx, output, global, rooted_holder_value, key, caller_function, caller_frame);
    defer {
        const owned_value = value;
        value = core.JSValue.undefinedValue();
        owned_value.free(ctx.runtime);
    }

    // Same-value guard (quickjs.c:49740): if the current value no longer matches
    // the value recorded at parse time (mutation-during-walk, or a duplicate key
    // whose recorded first-occurrence value differs from the last-wins value),
    // drop the record so this subtree gets no source attribution.
    var active_record = record;
    if (active_record) |rec| {
        if (!rec.recordValue().sameValue(value)) active_record = null;
    }

    if (object_ops.objectFromValue(value)) |object| {
        if (try core.array.isArrayValue(value)) {
            const length_value = try object_ops.getValueProperty(ctx, output, global, value, core.atom.ids.length, caller_function, caller_frame);
            defer length_value.free(ctx.runtime);
            const length = try coercion_ops.toLengthIndex(ctx, output, global, length_value);
            var index: usize = 0;
            while (index < length) : (index += 1) {
                const child_key = try object_ops.propertyAtomFromLengthIndex(ctx.runtime, index);
                defer deinitLengthIndexAtom(ctx.runtime, child_key);
                const child_record: ?*const JsonParseRecord = if (active_record) |rec| rec.arrayElement(index) else null;
                try qjsJsonInternalizeChild(ctx, output, global, value, object, child_key.atom, rooted_reviver, child_record, caller_function, caller_frame);
            }
        } else {
            // qjs snapshots own enumerable STRING property names ONCE via
            // JS_GetOwnPropertyNamesInternal(JS_GPN_ENUM_ONLY | JS_GPN_STRING_MASK)
            // (quickjs.c:49757), then iterates that fixed list unconditionally.
            // Enumerability and string-ness are captured at snapshot time; a
            // reviver that later deletes / redefines a property does NOT change
            // which names are visited (the recursion's single [[Get]] surfaces
            // the mutated/deleted value). Doing the descriptor probe per
            // iteration instead would wrongly skip a deleted key (json#9 walk
            // matrix: `del-mut` must still visit `c`).
            const keys = try object_ops.objectRestOwnKeys(ctx, output, global, object);
            defer core.Object.freeKeys(ctx.runtime, keys);
            var enumerable_keys = std.ArrayList(core.Atom).empty;
            defer enumerable_keys.deinit(ctx.runtime.memory.allocator);
            for (keys) |child_key| {
                if (ctx.runtime.atoms.isPublicSymbol(child_key)) continue;
                const desc = try object_ops.objectRestOwnPropertyDescriptor(ctx, output, global, object, child_key) orelse continue;
                defer desc.destroy(ctx.runtime);
                if (desc.enumerable != true) continue;
                try enumerable_keys.append(ctx.runtime.memory.allocator, child_key);
            }
            for (enumerable_keys.items) |child_key| {
                const child_record: ?*const JsonParseRecord = if (active_record) |rec| rec.findObjectEntry(child_key) else null;
                try qjsJsonInternalizeChild(ctx, output, global, value, object, child_key, rooted_reviver, child_record, caller_function, caller_frame);
            }
        }
    }

    key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, key);
    defer {
        const owned_key = key_value;
        key_value = core.JSValue.undefinedValue();
        owned_key.free(ctx.runtime);
    }
    // context.source only for primitives with a surviving record
    // (quickjs.c:49784: the source branch is in the `else` of JS_IsObject(val)).
    const primitive_record: ?*const JsonParseRecord = if (object_ops.objectFromValue(value) == null) active_record else null;
    context_value = try qjsJsonReviverContext(ctx.runtime, global, primitive_record);
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

/// Recurse into one child then define/delete the result (the loop body of
/// internalize_json_property, quickjs.c:49762-49782). The recursion performs the
/// single [[Get]] for this child; no prefetch Get is done here.
pub fn qjsJsonInternalizeChild(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    holder_value: core.JSValue,
    holder: *core.Object,
    key: core.Atom,
    reviver: core.JSValue,
    record: ?*const JsonParseRecord,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) HostError!void {
    var rooted_holder_value = holder_value;
    var rooted_reviver = reviver;
    var revived = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_holder_value },
        .{ .value = &rooted_reviver },
        .{ .value = &revived },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = ctx.runtime.active_value_roots,
        .values = &root_values,
    };
    ctx.runtime.active_value_roots = &root_frame;
    defer ctx.runtime.active_value_roots = root_frame.previous;

    revived = try qjsJsonInternalizeProperty(ctx, output, global, rooted_holder_value, key, rooted_reviver, record, caller_function, caller_frame);
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

/// Build the reviver `context` argument (quickjs.c:49746 JS_NewObject +
/// 49784-49792 the primitive source branch). `record` is non-null only for a
/// primitive value whose parse-time value survived the same-value guard; in
/// that case `context.source` is created from the recorded source span.
fn qjsJsonReviverContext(rt: *core.JSRuntime, global: *core.Object, record: ?*const JsonParseRecord) !core.JSValue {
    var object_value = core.JSValue.undefinedValue();
    var source_value = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
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
    if (record) |rec| {
        switch (rec.*) {
            .primitive => |p| {
                source_value = try value_ops.createStringValue(rt, p.source);
                defer {
                    const owned_source = source_value;
                    source_value = core.JSValue.undefinedValue();
                    owned_source.free(rt);
                }
                try object.defineOwnProperty(rt, core.atom.ids.source, core.Descriptor.data(source_value, true, true, true));
            },
            else => {},
        }
    }
    return object_value;
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
            const printed = try value_ops.formatFiniteNumber(&number_buf, number);
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
        if (rt.atoms.kind(prop.atom_id) == .private) continue;
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

    if (!try core.array.isArrayValue(rooted_replacer)) return .{};

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
        if (rooted_space.asStringBody()) |body| {
            try body.ensureFlat(ctx.runtime);
            switch (body.resolveData()) {
                .latin1 => |bytes| {
                    const take = @min(bytes.len, 10);
                    for (bytes[0..take]) |byte| {
                        if (byte < 0x80) {
                            try out.append(ctx.runtime.memory.allocator, byte);
                        } else {
                            try out.append(ctx.runtime.memory.allocator, 0xc0 | (byte >> 6));
                            try out.append(ctx.runtime.memory.allocator, 0x80 | (byte & 0x3f));
                        }
                    }
                },
                .utf16 => |units| {
                    var take = @min(units.len, 10);
                    // A pair split at the cut would leave a lone high surrogate
                    // that the UTF-8 output pipeline cannot represent; drop it.
                    if (take > 0 and take < units.len and unicode.isHighSurrogateUnit(units[take - 1]) and unicode.isLowSurrogateUnit(units[take])) take -= 1;
                    var index: usize = 0;
                    while (index < take) : (index += 1) {
                        const unit = units[index];
                        if (unicode.isHighSurrogateUnit(unit) and index + 1 < take and unicode.isLowSurrogateUnit(units[index + 1])) {
                            var cp_buf: [4]u8 = undefined;
                            const cp: u21 = @intCast(unicode.codePointFromSurrogatePair(unit, units[index + 1]));
                            const cp_len = std.unicode.utf8Encode(cp, &cp_buf) catch continue;
                            try out.appendSlice(ctx.runtime.memory.allocator, cp_buf[0..cp_len]);
                            index += 1;
                        } else if (unit < 0x80) {
                            try out.append(ctx.runtime.memory.allocator, @intCast(unit));
                        } else if (!unicode.isHighSurrogateUnit(unit) and !unicode.isLowSurrogateUnit(unit)) {
                            var cp_buf: [4]u8 = undefined;
                            const cp_len = std.unicode.utf8Encode(@intCast(unit), &cp_buf) catch continue;
                            try out.appendSlice(ctx.runtime.memory.allocator, cp_buf[0..cp_len]);
                        }
                    }
                },
            }
        }
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
            const printed = try value_ops.formatFiniteNumber(&number_buf, number);
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
        } else if (try core.array.isArrayValue(rooted_value)) {
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
