//! QuickJS source map: js_json_obj / js_json_funcs (JS_ParseJSON,
//! js_json_stringify) in quickjs.c. Implementation and declaration table live
//! side by side, matching QuickJS's JSCFunctionListEntry pattern.

const core = @import("../core/root.zig");
const array_list_erased = @import("../core/array_list_erased.zig");
const unicode = @import("../libs/unicode.zig");
const std = @import("std");
const builtin_dispatch = @import("builtin_dispatch.zig");
const call_runtime = @import("call_runtime.zig");
const call_site_mod = @import("call_site.zig");
const CallSite = call_site_mod.CallSite;
const coercion_ops = @import("value_ops.zig");
const exception_ops = @import("exception_ops.zig");
const exceptions = @import("exception_ops.zig");
const object_ops = @import("object_ops.zig");
const string_ops = @import("string_ops.zig");
const value_ops = @import("value_ops.zig");
const number_format = @import("../libs/number_format.zig");

const Bytecode = builtin_dispatch.Bytecode;
const Frame = builtin_dispatch.Frame;
const HostError = exceptions.HostError;

const JsonStringifyError = std.mem.Allocator.Error || error{
    InvalidAtom,
    TypeError,
    StackOverflow,
};

const SimpleJsonError = std.mem.Allocator.Error || error{
    IncompatibleDescriptor,
    InvalidAtom,
    InvalidClassId,
    InvalidLength,
    NotExtensible,
    ReadOnly,
    UnsupportedSimpleJson,
    // Native recursion guard: QuickJS surfaces deep JSON.parse nesting as a
    // catchable SyntaxError (json parser js_parse_error, quickjs.c).
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
// `JSON.parse`'s native id without importing this operation Module. Re-exported here so
// `internal_entries` and the install path keep referring to it locally.
pub const StaticMethod = core.host_function.builtin_method_ids.json.StaticMethod;

/// Declaration table: one entry per `JSON.*` method.
pub const internal_entries = [_]core.host_function.InternalEntry{
    jsonEntry("isRawJSON", 1, @intFromEnum(StaticMethod.is_raw_json), &jsonIsRawJsonCall),
    jsonEntry("parse", 2, @intFromEnum(StaticMethod.parse), &jsonParseRecordCall),
    jsonEntry("rawJSON", 1, @intFromEnum(StaticMethod.raw_json), &jsonRawJsonCall),
    jsonEntry("stringify", 3, @intFromEnum(StaticMethod.stringify), &jsonStringifyRecordCall),
};

fn jsonEntry(
    comptime name: []const u8,
    comptime length: u8,
    comptime id: u32,
    comptime handler: anytype,
) core.host_function.InternalEntry {
    return .{
        .name = name,
        .length = length,
        .id = id,
        .cproto = .generic_magic,
        .native_function = builtin_dispatch.genericMagicFunction(handler),
    };
}

fn jsonIsRawJsonCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    return core.JSValue.boolean(host_call.args.len >= 1 and isRawJSON(host_call.args[0]));
}

fn jsonRawJsonCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == host_call.ctx);
    const value = if (host_call.args.len >= 1) host_call.args[0] else core.JSValue.undefinedValue();
    var owned_input: ?core.JSValue = null;
    const input = if (!value.isString()) input: {
        owned_input = try string_ops.toStringForAnnexB(host_call.ctx, host_call.output, realm.global, value, builtin_dispatch.callerBytecode(host_call), builtin_dispatch.callerFrame(host_call));
        break :input owned_input.?;
    } else value;
    return rawJSON(host_call.ctx.runtime, input) catch |err| switch (err) {
        error.SyntaxError => exception_ops.throwSyntaxErrorMessage(host_call.ctx, realm.global, "invalid rawJSON string"),
        error.TypeError => err,
        else => err,
    };
}

fn jsonParseRecordCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const ctx = host_call.ctx;
    // JSON modules reuse the parse record as an algorithmic operation and have
    // no observable C-function carrier. In that explicit synthetic arm, the
    // module loader's context/global pair is the realm authority. Ordinary JS
    // calls must still use the realm owned by their callable.
    const global = if (host_call.callable_realm) |realm| blk: {
        std.debug.assert(realm.realm == ctx);
        break :blk realm.global;
    } else blk: {
        // Only the loader's explicit algorithmic reuse may omit the callable
        // carrier. Keep an inconsistent observable-call environment from
        // silently falling back to caller authority.
        if (host_call.func_obj != null) return error.InvalidBuiltinRegistry;
        break :blk host_call.global orelse return error.InvalidBuiltinRegistry;
    };
    if (try jsonParseCall(ctx, host_call.output, global, host_call.args, builtin_dispatch.callerBytecode(host_call), builtin_dispatch.callerFrame(host_call))) |value| return value;
    return error.TypeError;
}

fn jsonStringifyRecordCall(
    native_ctx: *core.JSContext,
    native_this: core.JSValue,
    native_args: []const core.JSValue,
    native_magic: i32,
) HostError!core.JSValue {
    const host_call = builtin_dispatch.nativeCall(native_ctx, native_this, native_args, native_magic) orelse return error.TypeError;
    const ctx = host_call.ctx;
    const realm = try builtin_dispatch.callableRealm(host_call);
    std.debug.assert(realm.realm == ctx);
    if (try jsonStringifyCall(ctx, host_call.output, realm.global, host_call.args, builtin_dispatch.callerBytecode(host_call), builtin_dispatch.callerFrame(host_call))) |value| return value;
    return error.TypeError;
}

pub fn stringify(rt: *core.JSRuntime, value: core.JSValue, replacer: core.JSValue, space: core.JSValue) !core.JSValue {
    var rooted_value = value;
    var rooted_replacer = replacer;
    var rooted_space = space;
    var root_frame = core.runtime.rootValues(.{ &rooted_value, &rooted_replacer, &rooted_space });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    if (rooted_value.is(.undefined_value)) return core.JSValue.undefinedValue();

    var property_list = try stringifyPropertyList(rt, rooted_replacer);
    defer freePropertyList(rt, property_list);
    // TGC S3 §4 class B: a native []Atom held across toJSON/replacer calls.
    var property_list_roots = core.runtime.rootAtomList(&property_list);
    property_list_roots.activate(rt);
    defer property_list_roots.deactivate(rt);
    var gap = try stringifyGap(rt, rooted_space);
    defer gap.deinit(rt.nativeAllocator());
    const options = StringifyOptions{ .property_list = property_list, .has_property_list = isArrayObject(rooted_replacer), .gap = gap.items };

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.nativeAllocator());
    var stack = std.ArrayList(*core.Object).empty;
    defer stack.deinit(rt.nativeAllocator());
    try appendJsonValue(rt, &buffer, rooted_value, false, &stack, options, 0);
    if (buffer.items.len == 0) return core.JSValue.undefinedValue();

    return try createJsonStringValue(rt, buffer.items);
}

pub fn parse(rt: *core.JSRuntime, global: ?*core.Object, value: core.JSValue) !core.JSValue {
    var rooted_value = value;
    var root_frame = core.runtime.rootValues(.{&rooted_value});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try appendJsonInputString(rt, &bytes, rooted_value);

    if (try parseSimpleJsonValue(rt, global, bytes.items)) |parsed| return parsed;

    if (rooted_value.asStringBody()) |body| {
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
        self.value = core.JSValue.undefinedValue();
    }
};

/// Parse `value` and build the parallel parse-record tree in lockstep, mirroring
/// qjs js_json_parse's reviver branch which calls JS_ParseJSON3 with a live
/// `pr`. Unlike `parse`, this never takes the record-less
/// simple fast path: the reviver needs the full record for `context.source`.
/// Caller owns both the returned value and record (record.deinit frees the
/// tree; the value must be freed separately).
pub fn parseWithRecord(rt: *core.JSRuntime, global: ?*core.Object, value: core.JSValue) !JsonParseWithRecord {
    var rooted_value = value;
    var root_frame = core.runtime.rootValues(.{&rooted_value});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    if (rooted_value.asStringBody()) |body| {
        return switch (body.resolveData()) {
            .latin1 => |latin1| jsonParseFullWithRecord(u8, rt, global, latin1),
            .utf16 => |units| jsonParseFullWithRecord(u16, rt, global, units),
        };
    }

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try appendJsonInputString(rt, &bytes, rooted_value);
    const text = try core.string.String.createUtf8(rt, bytes.items);
    return switch (text.resolveData()) {
        .latin1 => |latin1| jsonParseFullWithRecord(u8, rt, global, latin1),
        .utf16 => |units| jsonParseFullWithRecord(u16, rt, global, units),
    };
}

fn jsonParseFullWithRecord(comptime T: type, rt: *core.JSRuntime, global: ?*core.Object, units: []const T) !JsonParseWithRecord {
    var parser = JsonUnitParser(T){ .rt = rt, .global = global, .units = units };
    var pending_roots = JsonPendingRecordRoots{ .runtime = rt, .head = &parser.pending_records };
    try pending_roots.activate();
    defer pending_roots.deactivate();
    parser.skipWhitespace();
    var record: JsonParseRecord = undefined;
    const value = try parser.parseValueRecord(&record);
    errdefer {
        record.deinit(rt);
    }
    parser.skipWhitespace();
    if (parser.index != parser.units.len) return error.SyntaxError;
    return .{ .value = value, .record = record };
}

/// Coerced (non-string) inputs: decode the UTF-8 bytes into a real string and
/// parse its code units through the same faithful walk.
fn jsonParseFullFromBytes(rt: *core.JSRuntime, global: ?*core.Object, bytes: []const u8) !core.JSValue {
    const text = try core.string.String.createUtf8(rt, bytes);
    return switch (text.resolveData()) {
        .latin1 => |latin1| jsonParseFull(u8, rt, global, latin1),
        .utf16 => |units| jsonParseFull(u16, rt, global, units),
    };
}

/// Faithful port of the qjs JSON parser (js_json_parse -> json_next_token /
/// json_parse_value, quickjs.c): recursive descent over the source
/// string's CODE UNITS (WTF-16; lone surrogates in string literals are legal
/// JSON and round-trip, unlike the retired std.json backend), JSON whitespace
/// only, strict number grammar, last-duplicate-key-wins, own "__proto__"
/// property (no prototype mutation). Depth is bounded by the native stack
/// guard (json_next_token js_check_stack_overflow, quickjs.c).
fn jsonParseFull(comptime T: type, rt: *core.JSRuntime, global: ?*core.Object, units: []const T) !core.JSValue {
    var parser = JsonUnitParser(T){ .rt = rt, .global = global, .units = units };
    parser.skipWhitespace();
    const value = try parser.parseValue();
    parser.skipWhitespace();
    if (parser.index != parser.units.len) return error.SyntaxError;
    return value;
}

const JsonParseError = std.mem.Allocator.Error || error{
    SyntaxError,
    TypeError,
    IncompatibleDescriptor,
    InvalidAtom,
    InvalidClassId,
    InvalidLength,
    NotExtensible,
    ReadOnly,
    StringTooLong,
};

/// Parallel parse-record tree, mirroring qjs's `JSONParseRecord`
///. Built during parse *only* when a reviver is present, so
/// `internalize_json_property` can attach `context.source` for primitives and
/// perform the `js_same_value(pr->value, val)` guard. Each
/// node caches the value produced at parse time (`value`, dup'd so it survives
/// reviver mutations that would otherwise free the original) and, for
/// primitives, the raw source-text span. Object entries are stored in document
/// order and `findObjectEntry` returns the FIRST entry for a key (qjs
/// json_parse_record_find, quickjs.c): under duplicate keys the recorded
/// value therefore differs from the last-wins property value, so the same-value
/// guard drops the source, matching qjs.
const JsonParseRecord = union(enum) {
    /// Non-object leaf (string / number / boolean / null). `source` holds the
    /// WTF-8 bytes of the original source span (qjs stores source_pos/source_len
    /// into text_str; quickjs.c).
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
    /// json_parse_record_find: FIRST match wins.
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

    /// Recursively free the record tree's native memory: the primitive source
    /// bytes and the element/entry arrays. Mirrors json_free_parse_record
    ///. The cached `value` and the entry atoms are NOT freed
    /// here — under tracing GC they are reported as roots by `JsonRecordRoots`
    /// / `JsonPendingRecordRoots` and reclaimed by the collector.
    fn deinit(self: *JsonParseRecord, rt: *core.JSRuntime) void {
        switch (self.*) {
            .primitive => |*p| {
                if (p.source.len != 0) rt.nativeAllocator().free(p.source);
            },
            .array => |*a| {
                for (a.elements) |*element| element.deinit(rt);
                rt.nativeAllocator().free(a.elements);
            },
            .object => |*o| {
                for (o.entries) |*entry| {
                    entry.record.deinit(rt);
                }
                rt.nativeAllocator().free(o.entries);
            },
        }
    }
};

const JsonParseRecordEntry = struct {
    atom: core.Atom,
    record: JsonParseRecord,
};

/// TGC S3 §2.2 root G: the parse-record tree is a native (non-GC) tree that
/// holds both atom ids and JSValues. Once the reviver deletes a property the
/// record is the ONLY holder of that key's atom, and the walk between two
/// reviver calls allocates freely, so the tree needs a root provider of its
/// own -- the `PendingDescriptorRoots` pattern in call_runtime.zig.
///
/// The value half was previously covered by a flat `collectValues` snapshot;
/// reporting the slots in place instead keeps them mutable (a moving
/// collector could rewrite them) and drops the parallel array.
const JsonRecordRoots = struct {
    runtime: *core.JSRuntime,
    /// Null until `parseWithRecord` has handed the tree over. The provider is
    /// armed BEFORE the parse so the hand-off itself -- `registerRootProvider`
    /// grows an array, and a growth is an allocation, and an allocation is a
    /// collection point -- happens with the tree already covered.
    record: ?*JsonParseRecord = null,
    registered: bool = false,

    fn traceRecord(record: *JsonParseRecord, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        switch (record.*) {
            .primitive => |*p| try visitor.value(&p.value),
            .array => |*a| {
                try visitor.value(&a.value);
                for (a.elements) |*element| try traceRecord(element, visitor);
            },
            .object => |*o| {
                try visitor.value(&o.value);
                for (o.entries) |*entry| {
                    try visitor.atomRoot(entry.atom);
                    try traceRecord(&entry.record, visitor);
                }
            },
        }
    }

    fn traceRoots(context: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        const self: *JsonRecordRoots = @ptrCast(@alignCast(context));
        const record = self.record orelse return;
        try traceRecord(record, visitor);
    }

    fn provider(self: *JsonRecordRoots) core.runtime.RootProvider {
        return .{ .context = @ptrCast(self), .trace = traceRoots };
    }

    fn activate(self: *JsonRecordRoots) !void {
        if (comptime !core.runtime.value_root_frames_enabled) return;
        try self.runtime.registerRootProvider(self.provider());
        self.registered = true;
    }

    fn deactivate(self: *JsonRecordRoots) void {
        if (comptime !core.runtime.value_root_frames_enabled) return;
        if (!self.registered) return;
        self.runtime.unregisterRootProvider(self.provider());
        self.registered = false;
    }
};

/// One in-flight object/array parse. `JsonRecordRoots` cannot help here: the
/// record tree does not exist until the whole parse returns, while the halves
/// already built live in native `ArrayList`s the collector cannot see.
///
/// For every key but a duplicate that does not matter -- a recorded child
/// value is also the parent object's property value, and the parent is rooted
/// by `parseObject`'s own value frame. A duplicate key breaks exactly that
/// invariant: parsing `{"x":{},"x":1}` overwrites the property, after which
/// the FIRST occurrence's value is reachable only from `entries` -- and the
/// reviver walk still needs it, because `findObjectEntry` returns the first
/// entry. The rest of the parse allocates freely (source spans, key atoms,
/// list growth), so that value can be collected before the walk reads it.
///
/// `pending` covers the one moment a completed child record is in neither
/// place: after the recursive call filled the caller's `child_slot_storage`
/// and before the appending `ArrayList` grew to hold it.
const JsonPendingRecordFrame = struct {
    previous: ?*JsonPendingRecordFrame,
    entries: ?*std.ArrayList(JsonParseRecordEntry) = null,
    elements: ?*std.ArrayList(JsonParseRecord) = null,
    pending: ?*JsonParseRecord = null,
};

/// One provider for the whole recursion: the parser owns the chain head and
/// each `parseObject`/`parseArray` pushes and pops its frame. Registering per
/// frame instead would make `registerRootProvider`'s duplicate scan quadratic
/// in the nesting depth.
const JsonPendingRecordRoots = struct {
    runtime: *core.JSRuntime,
    head: *?*JsonPendingRecordFrame,
    registered: bool = false,

    fn traceRoots(context: *anyopaque, visitor: *core.runtime.RootVisitor) core.runtime.RootTraceError!void {
        const self: *JsonPendingRecordRoots = @ptrCast(@alignCast(context));
        var cursor = self.head.*;
        while (cursor) |frame| : (cursor = frame.previous) {
            if (frame.entries) |list| {
                for (list.items) |*entry| {
                    try visitor.atomRoot(entry.atom);
                    try JsonRecordRoots.traceRecord(&entry.record, visitor);
                }
            }
            if (frame.elements) |list| {
                for (list.items) |*element| try JsonRecordRoots.traceRecord(element, visitor);
            }
            if (frame.pending) |slot| try JsonRecordRoots.traceRecord(slot, visitor);
        }
    }

    fn provider(self: *JsonPendingRecordRoots) core.runtime.RootProvider {
        return .{ .context = @ptrCast(self), .trace = traceRoots };
    }

    fn activate(self: *JsonPendingRecordRoots) !void {
        if (comptime !core.runtime.value_root_frames_enabled) return;
        try self.runtime.registerRootProvider(self.provider());
        self.registered = true;
    }

    fn deactivate(self: *JsonPendingRecordRoots) void {
        if (comptime !core.runtime.value_root_frames_enabled) return;
        if (!self.registered) return;
        self.runtime.unregisterRootProvider(self.provider());
        self.registered = false;
    }
};

fn JsonUnitParser(comptime T: type) type {
    return struct {
        rt: *core.JSRuntime,
        global: ?*core.Object,
        units: []const T,
        index: usize = 0,
        /// Innermost in-flight object/array record frame (`JsonPendingRecordRoots`).
        pending_records: ?*JsonPendingRecordFrame = null,

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

        /// Faithful port of qjs json_parse_value(s, pr). When
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
            // (json_parse_record_init_primitive, quickjs.c). The span is
            // the code units [start, index); for strings this includes the
            // enclosing quotes, matching qjs's s->token.ptr..s->buf_ptr.
            if (record) |slot| {
                const source = try self.recordSourceSpan(start, self.index);
                slot.* = .{ .primitive = .{ .value = value, .source = source } };
            }
            return value;
        }

        fn recordSourceSpan(self: *Self, start: usize, end: usize) ![]u8 {
            var bytes = std.ArrayList(u8).empty;
            errdefer bytes.deinit(self.rt.nativeAllocator());
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
            return bytes.toOwnedSlice(self.rt.nativeAllocator());
        }

        fn parseObject(self: *Self, record: ?*JsonParseRecord) JsonParseError!core.JSValue {
            self.index += 1; // '{'
            var object_value = (try core.Object.create(self.rt, core.class.ids.object, objectPrototypeFromGlobal(self.rt, self.global))).value();
            var root_values = [_]*core.JSValue{&object_value};
            var root_frame = core.runtime.ValueRootFrame{ .values = &root_values };
            root_frame.activate(self.rt);
            defer root_frame.deactivate(self.rt);
            errdefer {
                object_value = core.JSValue.undefinedValue();
            }
            // json_parse_record_init_obj: the object record
            // caches the object value plus one entry per key OCCURRENCE (dup keys
            // add separate entries, document order).
            var entries = std.ArrayList(JsonParseRecordEntry).empty;
            errdefer if (record != null) {
                for (entries.items) |*entry| {
                    entry.record.deinit(self.rt);
                }
                entries.deinit(self.rt.nativeAllocator());
            };
            // TGC S3-d: the entries built so far are native memory. Declared
            // after the errdefer above so the pop runs BEFORE the free.
            var pending_frame = JsonPendingRecordFrame{ .previous = self.pending_records, .entries = &entries };
            if (record != null) self.pending_records = &pending_frame;
            defer if (record != null) {
                self.pending_records = pending_frame.previous;
            };
            self.skipWhitespace();
            if (self.peek() == @as(T, '}')) {
                self.index += 1;
                if (record) |slot| slot.* = .{ .object = .{ .value = object_value, .entries = try array_list_erased.toOwnedSlice(&entries, self.rt.nativeAllocator()) } };
                return object_value;
            }
            while (true) {
                self.skipWhitespace();
                if (self.peek() != @as(T, '"')) return error.SyntaxError;
                const key_atom = try self.parseKeyAtom();
                // TGC S3 §4 class B: the key is a bare id held across the
                // recursive value parse, which allocates freely.
                var key_atom_roots = core.runtime.rootAtoms(.{&key_atom});
                key_atom_roots.activate(self.rt);
                defer key_atom_roots.deactivate(self.rt);
                self.skipWhitespace();
                if (self.peek() != @as(T, ':')) return error.SyntaxError;
                self.index += 1;
                var child_slot_storage: JsonParseRecord = undefined;
                const child_slot: ?*JsonParseRecord = if (record != null) &child_slot_storage else null;
                const child = try self.parseValueRecord(child_slot);
                // Append the record entry BEFORE defineOwnProperty so any later
                // failure is covered by the `entries` errdefer (no orphaned
                // child_slot_storage). A dup key adds a separate entry
                // (json_parse_record_add, quickjs.c).
                if (child_slot) |slot| {
                    pending_frame.pending = slot;
                    array_list_erased.append(&entries, self.rt.nativeAllocator(), .{ .atom = key_atom, .record = slot.* }) catch |err| {
                        pending_frame.pending = null;
                        slot.deinit(self.rt);
                        return err;
                    };
                    pending_frame.pending = null;
                }
                // Re-derived from the ROOTED value rather than from a pointer
                // taken before the recursive parse: that parse allocates, and a
                // moving young generation updates the slot, not a bare local.
                try core.Object.fromHeader(object_value.refHeaderAssumeObject())
                    .defineJsonParseDataProperty(self.rt, key_atom, child);
                self.skipWhitespace();
                const next = self.peek() orelse return error.SyntaxError;
                if (next == '}') {
                    self.index += 1;
                    if (record) |slot| slot.* = .{ .object = .{ .value = object_value, .entries = try array_list_erased.toOwnedSlice(&entries, self.rt.nativeAllocator()) } };
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
            var root_values = [_]*core.JSValue{&object_value};
            var root_frame = core.runtime.ValueRootFrame{ .values = &root_values };
            root_frame.activate(self.rt);
            defer root_frame.deactivate(self.rt);
            // json_parse_record_init_array: one element record
            // per array slot, in order.
            var elements = std.ArrayList(JsonParseRecord).empty;
            errdefer if (record != null) {
                for (elements.items) |*element| element.deinit(self.rt);
                elements.deinit(self.rt.nativeAllocator());
            };
            // Array elements are never overwritten, so their values stay
            // reachable through the array itself; the frame is here for the
            // duplicate-key orphan a nested OBJECT element can carry.
            var pending_frame = JsonPendingRecordFrame{ .previous = self.pending_records, .elements = &elements };
            if (record != null) self.pending_records = &pending_frame;
            defer if (record != null) {
                self.pending_records = pending_frame.previous;
            };
            self.skipWhitespace();
            if (self.peek() == @as(T, ']')) {
                self.index += 1;
                if (record) |slot| slot.* = .{ .array = .{ .value = object_value, .elements = try array_list_erased.toOwnedSlice(&elements, self.rt.nativeAllocator()) } };
                return object_value;
            }
            var index: u32 = 0;
            while (true) {
                var child_slot_storage: JsonParseRecord = undefined;
                const child_slot: ?*JsonParseRecord = if (record != null) &child_slot_storage else null;
                const child = try self.parseValueRecord(child_slot);
                // Append the element record BEFORE storing into the array so any
                // later failure is covered by the `elements` errdefer.
                if (child_slot) |slot| {
                    pending_frame.pending = slot;
                    array_list_erased.append(&elements, self.rt.nativeAllocator(), slot.*) catch |err| {
                        pending_frame.pending = null;
                        slot.deinit(self.rt);
                        return err;
                    };
                    pending_frame.pending = null;
                }
                if (!try object.appendDenseArrayLiteralIndex(self.rt, index, child)) {
                    // The parser owns this fresh array, so this fallback cannot
                    // encounter an AUTOINIT property whose builder widens the
                    // generic define error set.
                    object.defineOwnProperty(self.rt, core.Atom.taggedInt(index), core.Descriptor.data(child, .all)) catch |err| return @errorCast(err);
                }
                index += 1;
                self.skipWhitespace();
                const next = self.peek() orelse return error.SyntaxError;
                if (next == ']') {
                    self.index += 1;
                    if (record) |slot| slot.* = .{ .array = .{ .value = object_value, .elements = try array_list_erased.toOwnedSlice(&elements, self.rt.nativeAllocator()) } };
                    return object_value;
                }
                if (next != ',') return error.SyntaxError;
                self.index += 1;
            }
        }

        fn parseKeyAtom(self: *Self) !core.Atom {
            var key_units = std.ArrayList(u16).empty;
            defer key_units.deinit(self.rt.nativeAllocator());
            try self.parseStringUnits(&key_units);
            var key_bytes = std.ArrayList(u8).empty;
            defer key_bytes.deinit(self.rt.nativeAllocator());
            try appendWtf8FromUnits(self.rt, &key_bytes, key_units.items);
            return self.rt.internAtom(key_bytes.items);
        }

        fn parseString(self: *Self) !core.JSValue {
            var out = std.ArrayList(u16).empty;
            defer out.deinit(self.rt.nativeAllocator());
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
                        '"' => try out.append(self.rt.nativeAllocator(), '"'),
                        '\\' => try out.append(self.rt.nativeAllocator(), '\\'),
                        '/' => try out.append(self.rt.nativeAllocator(), '/'),
                        'b' => try out.append(self.rt.nativeAllocator(), 0x08),
                        'f' => try out.append(self.rt.nativeAllocator(), 0x0c),
                        'n' => try out.append(self.rt.nativeAllocator(), 0x0a),
                        'r' => try out.append(self.rt.nativeAllocator(), 0x0d),
                        't' => try out.append(self.rt.nativeAllocator(), 0x09),
                        'u' => {
                            if (self.index + 4 > self.units.len) return error.SyntaxError;
                            var code: u16 = 0;
                            inline for (0..4) |_| {
                                const digit = jsonHexDigit(self.units[self.index]) orelse return error.SyntaxError;
                                code = (code << 4) | digit;
                                self.index += 1;
                            }
                            try out.append(self.rt.nativeAllocator(), code);
                        },
                        else => return error.SyntaxError,
                    }
                    continue;
                }
                if (unit < 0x20) return error.SyntaxError;
                // A `u8` source unit widens implicitly into the `u16` output.
                try out.append(self.rt.nativeAllocator(), unit);
            }
        }

        fn parseNumber(self: *Self) !core.JSValue {
            const start = self.index;
            var ascii = std.ArrayList(u8).empty;
            defer ascii.deinit(self.rt.nativeAllocator());
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
            try ascii.ensureTotalCapacity(self.rt.nativeAllocator(), self.index - start);
            for (self.units[start..self.index]) |unit| ascii.appendAssumeCapacity(@intCast(unit));
            const text = ascii.items;
            if (!had_fraction) {
                if (core.value_format.parseAsciiInt(i64, text, 10)) |int_value| {
                    if (int_value >= std.math.minInt(i32) and int_value <= std.math.maxInt(i32)) {
                        if (!(int_value == 0 and text[0] == '-')) return core.JSValue.int32(@intCast(int_value));
                    }
                    return core.JSValue.float64(@floatFromInt(int_value));
                } else |_| {}
            }
            const float_value = number_format.parseNumberExact(text, 10, .{}) orelse return error.SyntaxError;
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
            try out.append(rt.nativeAllocator(), @intCast(cp));
        } else if (cp < 0x800) {
            try out.append(rt.nativeAllocator(), @intCast(0xc0 | (cp >> 6)));
            try out.append(rt.nativeAllocator(), @intCast(0x80 | (cp & 0x3f)));
        } else if (cp < 0x10000) {
            try out.append(rt.nativeAllocator(), @intCast(0xe0 | (cp >> 12)));
            try out.append(rt.nativeAllocator(), @intCast(0x80 | ((cp >> 6) & 0x3f)));
            try out.append(rt.nativeAllocator(), @intCast(0x80 | (cp & 0x3f)));
        } else {
            try out.append(rt.nativeAllocator(), @intCast(0xf0 | (cp >> 18)));
            try out.append(rt.nativeAllocator(), @intCast(0x80 | ((cp >> 12) & 0x3f)));
            try out.append(rt.nativeAllocator(), @intCast(0x80 | ((cp >> 6) & 0x3f)));
            try out.append(rt.nativeAllocator(), @intCast(0x80 | (cp & 0x3f)));
        }
    }
}

pub fn rawJSON(rt: *core.JSRuntime, value: core.JSValue) !core.JSValue {
    var rooted_value = value;
    var object_value = core.JSValue.undefinedValue();
    var text = core.JSValue.undefinedValue();
    var root_values = [_]*core.JSValue{
        &rooted_value,
        &object_value,
        &text,
    };
    var root_frame = core.runtime.ValueRootFrame{
        .values = &root_values,
    };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    appendJsonInputString(rt, &bytes, rooted_value) catch |err| switch (err) {
        error.TypeError => {
            if (rooted_value.is(.object)) return error.SyntaxError;
            return error.TypeError;
        },
        else => return err,
    };
    if (bytes.items.len == 0 or isRawJsonEdgeWhitespace(bytes.items[0]) or isRawJsonEdgeWhitespace(bytes.items[bytes.items.len - 1])) return error.SyntaxError;

    {
        const validated = try jsonParseFullFromBytes(rt, null, bytes.items);
        if (validated.is(.object)) return error.SyntaxError;
    }

    const object = try core.Object.create(rt, core.class.ids.raw_json, null);
    object_value = object.value();
    text = try createJsonStringValue(rt, bytes.items);
    try defineData(rt, object, core.atom.ids.rawJSON, text, true);
    try object.seal(rt);
    return object_value;
}

fn isRawJsonEdgeWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

pub fn isRawJSON(value: core.JSValue) bool {
    const header = value.refHeader() orelse return false;
    if (!value.is(.object)) return false;
    const object = core.Object.fromHeader(header);
    return object.class_id == core.class.ids.raw_json;
}

fn createSimpleJsonAsciiStringValue(rt: *core.JSRuntime, bytes: []const u8) !core.JSValue {
    return (try core.string.String.createAscii(rt, bytes)).value();
}

fn appendJsonValue(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue, array_slot: bool, stack: *std.ArrayList(*core.Object), options: StringifyOptions, depth: usize) JsonStringifyError!void {
    if (rt.checkNativeStackOverflow(0)) return error.StackOverflow;
    var rooted_value = value;
    var raw = core.JSValue.undefinedValue();
    var primitive = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &rooted_value, &raw, &primitive });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    if (rooted_value.is(.undefined_value)) {
        try buffer.appendSlice(rt.nativeAllocator(), if (array_slot) "null" else "");
    } else if (rooted_value.is(.null_value)) {
        try buffer.appendSlice(rt.nativeAllocator(), "null");
    } else if (rooted_value.is(.symbol)) {
        try buffer.appendSlice(rt.nativeAllocator(), if (array_slot) "null" else "");
    } else if (rooted_value.as(.int)) |int_value| {
        var int_buf: [20]u8 = undefined;
        const printed = number_format.formatInt64(&int_buf, @as(i64, int_value));
        try buffer.appendSlice(rt.nativeAllocator(), printed);
    } else if (rooted_value.as(.float64)) |float_value| {
        if (!std.math.isFinite(float_value)) {
            try buffer.appendSlice(rt.nativeAllocator(), "null");
        } else if (float_value == 0) {
            try buffer.append(rt.nativeAllocator(), '0');
        } else {
            var number_buf: [128]u8 = undefined;
            const printed = value_ops.formatFiniteNumberAssumeCapacity(&number_buf, float_value);
            try buffer.appendSlice(rt.nativeAllocator(), printed);
        }
    } else if (rooted_value.as(.boolean)) |bool_value| {
        try buffer.appendSlice(rt.nativeAllocator(), if (bool_value) "true" else "false");
    } else if (rooted_value.isString()) {
        try appendJsonStringValue(rt, buffer, rooted_value);
    } else if (rooted_value.isBigInt()) {
        return error.TypeError;
    } else if (rooted_value.is(.object)) {
        const header = rooted_value.refHeader() orelse return;
        const object_value = core.Object.fromHeader(header);
        if (object_value.class_id == core.class.ids.raw_json) {
            raw = try object_value.getProperty(core.atom.ids.rawJSON);
            try core.string.appendValueUtf8(rt, buffer, raw);
        } else if (isCallableJsonOmittedObject(object_value)) {
            try buffer.appendSlice(rt.nativeAllocator(), if (array_slot) "null" else "");
        } else if (object_value.class_id == core.class.ids.number or object_value.class_id == core.class.ids.string or object_value.class_id == core.class.ids.boolean) {
            primitive = jsonPrimitiveWrapperValue(object_value) orelse core.JSValue.undefinedValue();
            try appendJsonValue(rt, buffer, primitive, array_slot, stack, options, depth);
        } else if (object_value.isArray()) {
            try appendJsonArray(rt, buffer, object_value, stack, options, depth);
        } else {
            try appendJsonObject(rt, buffer, object_value, stack, options, depth);
        }
    } else {
        try buffer.appendSlice(rt.nativeAllocator(), "null");
    }
}

fn appendJsonArray(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), object: *core.Object, stack: *std.ArrayList(*core.Object), options: StringifyOptions, depth: usize) JsonStringifyError!void {
    if (objectInStack(stack.items, object)) return error.TypeError;
    try array_list_erased.append(stack, rt.nativeAllocator(), object);
    defer _ = stack.pop();

    try buffer.append(rt.nativeAllocator(), '[');
    var index: u32 = 0;
    while (index < object.arrayLength()) : (index += 1) {
        if (index != 0) try buffer.append(rt.nativeAllocator(), ',');
        if (options.gap.len != 0) {
            try buffer.append(rt.nativeAllocator(), '\n');
            try appendIndent(rt, buffer, options.gap, depth + 1);
        }
        const value = try object.getDenseArrayElementValue(index) orelse object.getProperty(core.Atom.taggedInt(index));
        var rooted_value = value;
        var root_frame = core.runtime.rootValues(.{&rooted_value});
        root_frame.activate(rt);
        defer root_frame.deactivate(rt);
        try appendJsonValue(rt, buffer, rooted_value, true, stack, options, depth + 1);
    }
    if (options.gap.len != 0 and object.arrayLength() != 0) {
        try buffer.append(rt.nativeAllocator(), '\n');
        try appendIndent(rt, buffer, options.gap, depth);
    }
    try buffer.append(rt.nativeAllocator(), ']');
}

fn appendJsonObject(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), object: *core.Object, stack: *std.ArrayList(*core.Object), options: StringifyOptions, depth: usize) JsonStringifyError!void {
    if (objectInStack(stack.items, object)) return error.TypeError;
    try array_list_erased.append(stack, rt.nativeAllocator(), object);
    defer _ = stack.pop();

    try buffer.append(rt.nativeAllocator(), '{');
    const owned_keys: []core.Atom = if (!options.has_property_list) try object.ownKeys(rt) else &.{};
    defer if (!options.has_property_list) core.Object.freeKeys(rt, owned_keys);
    const keys = if (options.has_property_list) options.property_list else owned_keys;
    var emitted = false;
    for (keys) |key| {
        if (rt.atoms.isPublicSymbol(key)) continue;
        const value = try object.getOwnDataPropertyValue(key) orelse object.getProperty(key);
        var rooted_value = value;
        var root_frame = core.runtime.rootValues(.{&rooted_value});
        root_frame.activate(rt);
        defer root_frame.deactivate(rt);
        if (rooted_value.is(.undefined_value) or rooted_value.is(.symbol)) continue;
        if (rooted_value.is(.object)) {
            const header = rooted_value.refHeader() orelse continue;
            const child_object = core.Object.fromHeader(header);
            if (isCallableJsonOmittedObject(child_object)) continue;
        }
        if (emitted) try buffer.append(rt.nativeAllocator(), ',');
        if (options.gap.len != 0) {
            try buffer.append(rt.nativeAllocator(), '\n');
            try appendIndent(rt, buffer, options.gap, depth + 1);
        }
        emitted = true;
        try appendJsonAtomName(rt, buffer, key);
        try buffer.appendSlice(rt.nativeAllocator(), if (options.gap.len == 0) ":" else ": ");
        try appendJsonValue(rt, buffer, rooted_value, false, stack, options, depth + 1);
    }
    if (options.gap.len != 0 and emitted) {
        try buffer.append(rt.nativeAllocator(), '\n');
        try appendIndent(rt, buffer, options.gap, depth);
    }
    try buffer.append(rt.nativeAllocator(), '}');
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
        self.skipWhitespace();
        if (self.index != self.bytes.len) {
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
        var root_values = [_]*core.JSValue{
            &object_value,
        };
        var root_frame = core.runtime.ValueRootFrame{
            .values = &root_values,
        };
        root_frame.activate(self.rt);
        defer root_frame.deactivate(self.rt);
        errdefer {
            object_value = core.JSValue.undefinedValue();
        }
        if (self.consumeByte('}')) return object_value;

        while (true) {
            self.skipWhitespace();
            if (self.peek() != '"') return error.UnsupportedSimpleJson;
            const key_text = try self.parseSimpleStringBytes();
            const key = try self.rt.internAtom(key_text);
            // TGC S3 §4 class B.
            var key_roots = core.runtime.rootAtoms(.{&key});
            key_roots.activate(self.rt);
            defer key_roots.deactivate(self.rt);
            self.skipWhitespace();
            self.expectByte(':') catch return error.UnsupportedSimpleJson;
            const item_value = try self.parseValue();
            var root_item = item_value;
            var item_roots = [_]*core.JSValue{
                &root_item,
            };
            var item_root_frame = core.runtime.ValueRootFrame{
                .values = &item_roots,
            };
            item_root_frame.activate(self.rt);
            defer item_root_frame.deactivate(self.rt);
            try object.defineJsonParseDataProperty(self.rt, key, item_value);
            self.skipWhitespace();
            if (self.consumeByte('}')) return object_value;
            self.expectByte(',') catch return error.UnsupportedSimpleJson;
        }
    }

    fn parseArray(self: *SimpleJsonParser) SimpleJsonError!core.JSValue {
        self.expectByte('[') catch return error.UnsupportedSimpleJson;
        const object = try core.Object.createArray(self.rt, arrayPrototypeFromGlobal(self.rt, self.global));
        var object_value = object.value();
        var root_frame = core.runtime.rootValues(.{&object_value});
        root_frame.activate(self.rt);
        defer root_frame.deactivate(self.rt);
        self.skipWhitespace();
        if (self.consumeByte(']')) return object_value;

        var index: u32 = 0;
        while (true) {
            const item_value = try self.parseValue();
            var root_item = item_value;
            var item_root_frame = core.runtime.rootValues(.{&root_item});
            item_root_frame.activate(self.rt);
            defer item_root_frame.deactivate(self.rt);
            if (!(try object.appendDenseArrayLiteralIndex(self.rt, index, item_value))) {
                // The parser owns this fresh array, so this fallback cannot
                // encounter an AUTOINIT property whose builder widens the
                // generic define error set.
                object.defineOwnProperty(self.rt, core.Atom.taggedInt(index), core.Descriptor.data(item_value, .all)) catch |err| return @errorCast(err);
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
        const parsed = core.value_format.parseAsciiInt(i32, self.bytes[start..self.index], 10) catch return error.UnsupportedSimpleJson;
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
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const int_value = (try parseSimpleJsonValue(rt, null, "12345")).?;
    try std.testing.expectEqual(@as(?i32, 12345), int_value.as(.int));

    const zero_value = (try parseSimpleJsonValue(rt, null, "0")).?;
    try std.testing.expectEqual(@as(?i32, 0), zero_value.as(.int));

    try std.testing.expect((try parseSimpleJsonValue(rt, null, "01")) == null);
    try std.testing.expect((try parseSimpleJsonValue(rt, null, "1.5")) == null);
}

fn objectPrototypeFromGlobal(rt: *core.JSRuntime, global: ?*core.Object) ?*core.Object {
    const global_object = global orelse return null;
    if (rt.contextForGlobal(global_object)) |ctx| {
        if (ctx.classPrototypeObject(core.class.ids.object)) |prototype| return prototype;
    }
    if (cachedRealmObject(rt, global, .object_prototype)) |prototype| return prototype;
    return constructorPrototypeFromGlobal(rt, global, "Object");
}

fn arrayPrototypeFromGlobal(rt: *core.JSRuntime, global: ?*core.Object) ?*core.Object {
    const global_object = global orelse return null;
    if (rt.contextForGlobal(global_object)) |ctx| {
        if (ctx.classPrototypeObject(core.class.ids.array)) |prototype| return prototype;
    }
    if (cachedRealmObject(rt, global, .array_prototype)) |prototype| return prototype;
    return constructorPrototypeFromGlobal(rt, global, "Array");
}

fn cachedRealmObject(rt: *core.JSRuntime, global: ?*core.Object, slot: core.object.RealmValueSlot) ?*core.Object {
    const global_object = global orelse return null;
    const stored = global_object.cachedRealmValue(rt, slot) orelse return null;
    return objectFromValue(stored);
}

const objectFromValue = core.value_semantics.objectFromValue;

/// Embedder fallback used only when the realm class table and cache are both
/// unpublished. JSON.parse result objects must not take this path in a live realm.
fn constructorPrototypeFromGlobal(rt: *core.JSRuntime, global: ?*core.Object, name: []const u8) ?*core.Object {
    _ = rt;
    const global_object = global orelse return null;
    const key = core.atom.predefinedId(name, .string) orelse return null;
    if (global_object.getOwnDataObjectBorrowed(key)) |ctor_object| {
        if (ctor_object.getOwnDataObjectBorrowed(core.atom.ids.prototype)) |prototype| return prototype;
    }
    return null;
}

fn objectInStack(stack: []const *core.Object, object: *core.Object) bool {
    for (stack) |item| {
        if (item == object) return true;
    }
    return false;
}

fn isCallableJsonOmittedObject(object: *core.Object) bool {
    return object.class_id == core.class.ids.c_function or
        object.class_id == core.class.ids.c_function_data or
        core.class.isAsyncFunctionResumeClass(object.class_id) or
        core.class.isBytecodeFunctionClass(object.class_id) or
        object.class_id == core.class.ids.bound_function;
}

test "JSON callable omission recognizes every bytecode function class" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const class_ids = [_]core.ClassId{
        core.class.ids.bytecode_function,
        core.class.ids.generator_function,
        core.class.ids.async_function,
        core.class.ids.async_generator_function,
    };
    for (class_ids) |class_id| {
        const function_object = try core.Object.create(rt, class_id, null);
        try std.testing.expect(isCallableJsonOmittedObject(function_object));
    }

    const plain_object = try core.Object.create(rt, core.class.ids.object, null);
    try std.testing.expect(!isCallableJsonOmittedObject(plain_object));
}

fn isArrayObject(value: core.JSValue) bool {
    const header = value.refHeader() orelse return false;
    if (!value.is(.object)) return false;
    const object = core.Object.fromHeader(header);
    return object.isArray();
}

fn stringifyPropertyList(rt: *core.JSRuntime, replacer: core.JSValue) ![]core.Atom {
    var rooted_replacer = replacer;
    var root_frame = core.runtime.rootValues(.{&rooted_replacer});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const header = rooted_replacer.refHeader() orelse return &.{};
    if (!rooted_replacer.is(.object)) return &.{};
    const object = core.Object.fromHeader(header);
    if (!object.isArray()) return &.{};

    var list = std.ArrayList(core.Atom).empty;
    errdefer {
        list.deinit(rt.nativeAllocator());
    }
    // TGC S3 §4 class B: the accumulated ids live in a native array across
    // `getProperty`, which can reach a JS accessor.
    var list_roots = core.runtime.rootAtomList(&list.items);
    list_roots.activate(rt);
    defer list_roots.deactivate(rt);
    var index: u32 = 0;
    while (index < object.arrayLength()) : (index += 1) {
        const item = try object.getProperty(core.Atom.taggedInt(index));
        var rooted_item = item;
        var item_root_frame = core.runtime.rootValues(.{&rooted_item});
        item_root_frame.activate(rt);
        defer item_root_frame.deactivate(rt);
        const atom = try stringifyPropertyListAtom(rt, rooted_item) orelse continue;
        if (atomListContains(list.items, atom)) {
            continue;
        }
        try list.append(rt.nativeAllocator(), atom);
    }
    return try list.toOwnedSlice(rt.nativeAllocator());
}

fn stringifyPropertyListAtom(rt: *core.JSRuntime, value: core.JSValue) !?core.Atom {
    var rooted_value = value;
    var primitive = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &rooted_value, &primitive });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    if (rooted_value.isString()) {
        const string_object = rooted_value.asStringBody().?;
        return try string_object.internAtom(rt);
    }
    if (rooted_value.as(.int)) |int_value| {
        var buf: [20]u8 = undefined;
        const text = number_format.formatInt64(&buf, @as(i64, int_value));
        return try rt.internAtom(text);
    }
    if (rooted_value.as(.float64)) |float_value| {
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
            value_ops.formatFiniteNumberAssumeCapacity(&buf, float_value);
        return try rt.internAtom(text);
    }
    const header = rooted_value.refHeader() orelse return null;
    if (!rooted_value.is(.object)) return null;
    const object = core.Object.fromHeader(header);
    if (object.class_id != core.class.ids.string and object.class_id != core.class.ids.number) return null;
    primitive = jsonPrimitiveWrapperValue(object) orelse return null;
    return try stringifyPropertyListAtom(rt, primitive);
}

fn stringifyGap(rt: *core.JSRuntime, space: core.JSValue) !std.ArrayList(u8) {
    var rooted_space = space;
    var primitive = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &rooted_space, &primitive });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    var out = std.ArrayList(u8).empty;
    const number = if (rooted_space.as(.int)) |int_value|
        @as(f64, @floatFromInt(int_value))
    else if (rooted_space.as(.float64)) |float_value|
        float_value
    else blk: {
        const header = rooted_space.refHeader() orelse break :blk null;
        if (!rooted_space.is(.object)) break :blk null;
        const object = core.Object.fromHeader(header);
        if (object.class_id == core.class.ids.number) {
            primitive = jsonPrimitiveWrapperValue(object) orelse break :blk null;
            break :blk primitive.as(.int) orelse primitive.as(.float64);
        }
        break :blk null;
    };
    if (number) |raw_number| {
        const count: usize = @intFromFloat(@min(@max(raw_number, 0), 10));
        try out.appendNTimes(rt.nativeAllocator(), ' ', count);
        return out;
    }

    if (rooted_space.isString()) {
        try core.string.appendValueUtf8(rt, &out, rooted_space);
    } else if (rooted_space.is(.object)) {
        const header = rooted_space.refHeader() orelse return out;
        const object = core.Object.fromHeader(header);
        if (object.class_id == core.class.ids.string) {
            primitive = jsonPrimitiveWrapperValue(object) orelse return out;
            try core.string.appendValueUtf8(rt, &out, primitive);
        }
    }
    if (out.items.len > 10) out.items = out.items[0..10];
    return out;
}

fn atomListContains(list: []const core.Atom, atom: core.Atom) bool {
    for (list) |item| {
        if (item == atom) return true;
    }
    return false;
}

fn freePropertyList(rt: *core.JSRuntime, list: []core.Atom) void {
    if (list.len != 0) rt.nativeAllocator().free(list);
}

fn appendIndent(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), gap: []const u8, depth: usize) !void {
    var index: usize = 0;
    while (index < depth) : (index += 1) try buffer.appendSlice(rt.nativeAllocator(), gap);
}

fn defineData(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue, enumerable: bool) !void {
    var object_value = object.value();
    var rooted_value = value;
    var root_frame = core.runtime.rootValues(.{ &object_value, &rooted_value });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(rooted_value, .{ .enumerable = enumerable }));
}

fn appendJsonInputString(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), value: core.JSValue) !void {
    var rooted_value = value;
    var primitive = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &rooted_value, &primitive });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    if (rooted_value.isString()) return core.string.appendValueUtf8(rt, buffer, rooted_value);
    if (rooted_value.is(.symbol)) return error.TypeError;
    if (rooted_value.is(.null_value)) return buffer.appendSlice(rt.nativeAllocator(), "null");
    if (rooted_value.is(.undefined_value)) return buffer.appendSlice(rt.nativeAllocator(), "undefined");
    if (rooted_value.as(.boolean)) |bool_value| return buffer.appendSlice(rt.nativeAllocator(), if (bool_value) "true" else "false");
    if (rooted_value.as(.int)) |int_value| {
        var int_buf: [20]u8 = undefined;
        const printed = number_format.formatInt64(&int_buf, @as(i64, int_value));
        return buffer.appendSlice(rt.nativeAllocator(), printed);
    }
    if (rooted_value.as(.float64)) |float_value| {
        if (float_value == 0) return buffer.append(rt.nativeAllocator(), '0');
        var float_buf: [128]u8 = undefined;
        const printed = value_ops.formatFiniteNumberAssumeCapacity(&float_buf, float_value);
        return buffer.appendSlice(rt.nativeAllocator(), printed);
    }
    if (rooted_value.isBigInt()) return core.value_format.appendBigIntBase10(rt.nativeAllocator(), buffer, rooted_value);
    if (rooted_value.is(.object)) {
        const header = rooted_value.refHeader() orelse return error.TypeError;
        const object = core.Object.fromHeader(header);
        primitive = jsonPrimitiveWrapperValue(object) orelse return error.TypeError;
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

// --- VM-coercing JSON.parse/JSON.stringify (moved from exec/json_ops.zig) ----

const SimpleJsonStringifyError = std.mem.Allocator.Error || error{
    InvalidUtf8,
    TypeError,
    StackOverflow,
    StringTooLong,
};

const JsonStringifyVmOptions = struct {
    replacer: core.JSValue = core.JSValue.undefinedValue(),
    replacer_call: ?*CallSite = null,
    property_list: []const core.Atom = &.{},
    has_property_list: bool = false,
    gap: []const u8 = "",
};

const JsonStringifyPropertyList = struct {
    items: []core.Atom = &.{},
    has_property_list: bool = false,

    fn deinit(self: JsonStringifyPropertyList, rt: *core.JSRuntime) void {
        rt.nativeAllocator().free(self.items);
    }
};

const SimpleJsonResult = enum {
    appended,
    omitted,
    fallback,
};

fn deinitLengthIndexAtom(_: *core.JSRuntime, _: anytype) void {}

pub fn jsonParseCall(
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
    var root_frame = core.runtime.rootValues(.{ &input, &reviver, &text, &parsed, &holder_value });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    text = try string_ops.toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);

    if (!call_runtime.isCallableValue(reviver)) {
        return try parse(ctx.runtime, global, text);
    }

    // Reviver present: build the parallel parse-record tree in lockstep so
    // internalize can attach context.source and run the same-value guard,
    // mirroring qjs js_json_parse (JS_ParseJSON3 with a live pr,
    // quickjs.c).
    // Root every cached record value AND every recorded key atom for the
    // duration of the walk (qjs keeps both alive via the ref-counted
    // JSONParseRecord fields; TGC S3 needs an explicit provider). Armed
    // BEFORE the parse and left tracing nothing until the tree exists:
    // `activate` can grow the provider array, and that allocation is a
    // collection point the finished tree must not be exposed to.
    var record_roots = JsonRecordRoots{ .runtime = ctx.runtime };
    try record_roots.activate();
    defer record_roots.deactivate();

    var parse_result = try parseWithRecord(ctx.runtime, global, text);
    record_roots.record = &parse_result.record;
    // The record tree is freed only after the walk returns, and the provider
    // stops naming it in the same statement that frees it.
    defer {
        record_roots.record = null;
        parse_result.record.deinit(ctx.runtime);
    }
    parsed = parse_result.value;
    parse_result.value = core.JSValue.undefinedValue();

    const holder = try core.Object.create(ctx.runtime, core.class.ids.object, object_ops.objectPrototypeFromGlobal(ctx.runtime, global));
    holder_value = holder.value();
    const root_key = core.atom.ids.empty_string;
    try holder.defineOwnProperty(ctx.runtime, root_key, core.Descriptor.data(parsed, .all));
    parsed = core.JSValue.undefinedValue();

    var reviver_call = CallSite.initInternal(
        ctx,
        output,
        global,
        holder_value,
        reviver,
        caller_function,
        caller_frame,
    );
    return try jsonInternalizeProperty(ctx, output, global, holder_value, root_key, reviver, &reviver_call, &parse_result.record, caller_function, caller_frame);
}

test "JSON.parse roots direct function bytecode input while coercing to string" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-json-parse-input-bytecode-symbol");
    const fb = try core.FunctionBytecode.createPublishedFixture(rt, .{ .cpool_count = 1 }, &.{try rt.takeSymbolValue(symbol_atom)});

    const input = core.JSValue.functionBytecode(&fb.header);
    const args = [_]core.JSValue{input};

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    try std.testing.expectError(error.SyntaxError, jsonParseCall(ctx, null, global, &args, null, null));
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

/// Faithful port of internalize_json_property. `record` is the
/// parse record for `holder[key]` (already located by the caller; the root
/// call passes the record for the whole parsed value, recursion passes the
/// located child record), or null when there is no record / it was cleared by
/// the same-value guard. Performs exactly ONE [[Get]] per property (json#9: the
/// prior implementation did up to three), then recurses over children, then
/// invokes the reviver with a `context` carrying `source` only for primitives
/// whose parse-time value still matches (json#8).
pub fn jsonInternalizeProperty(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    holder_value: core.JSValue,
    key: core.Atom,
    reviver: core.JSValue,
    reviver_call: *CallSite,
    record: ?*const JsonParseRecord,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) HostError!core.JSValue {
    var rooted_holder_value = holder_value;
    var rooted_reviver = reviver;
    var value = core.JSValue.undefinedValue();
    var key_value = core.JSValue.undefinedValue();
    var context_value = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{
        &rooted_holder_value,
        &rooted_reviver,
        &value,
        &key_value,
        &context_value,
    });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    // ONE [[Get]] per property (val = JS_GetProperty(holder, name),
    // quickjs.c).
    value = try object_ops.getValueProperty(ctx, output, global, rooted_holder_value, key, caller_function, caller_frame);

    // Same-value guard: if the current value no longer matches
    // the value recorded at parse time (mutation-during-walk, or a duplicate key
    // whose recorded first-occurrence value differs from the last-wins value),
    var active_record = record;
    if (active_record) |rec| {
        if (!rec.recordValue().sameValue(value)) active_record = null;
    }

    if (object_ops.objectFromValue(value)) |object| {
        if (try core.array.isArrayValue(value)) {
            const length_value = try object_ops.getValueProperty(ctx, output, global, value, core.atom.ids.length, caller_function, caller_frame);
            const length = try coercion_ops.toLengthIndex(ctx, output, global, length_value);
            for (0..length) |index| {
                const child_key = try object_ops.propertyAtomFromLengthIndex(ctx.runtime, index);
                defer deinitLengthIndexAtom(ctx.runtime, child_key);
                const child_record: ?*const JsonParseRecord = if (active_record) |rec| rec.arrayElement(index) else null;
                try jsonInternalizeChild(ctx, output, global, value, object, child_key.atom, rooted_reviver, reviver_call, child_record, caller_function, caller_frame);
            }
        } else {
            // qjs snapshots own enumerable STRING property names ONCE via
            // JS_GetOwnPropertyNamesInternal(JS_GPN_ENUM_ONLY | JS_GPN_STRING_MASK)
            //, then iterates that fixed list unconditionally.
            // Enumerability and string-ness are captured at snapshot time; a
            // reviver that later deletes / redefines a property does NOT change
            // which names are visited (the recursion's single [[Get]] surfaces
            // the mutated/deleted value). Doing the descriptor probe per
            // iteration instead would wrongly skip a deleted key (json#9 walk
            // matrix: `del-mut` must still visit `c`).
            const keys = try object_ops.objectRestOwnKeys(ctx, output, global, object);
            defer core.Object.freeKeys(ctx.runtime, keys);
            var enumerable_keys = std.ArrayList(core.Atom).empty;
            defer enumerable_keys.deinit(ctx.runtime.nativeAllocator());
            for (keys) |child_key| {
                if (ctx.runtime.atoms.isPublicSymbol(child_key)) continue;
                const desc = try object_ops.objectRestOwnPropertyDescriptor(ctx, output, global, object, child_key) orelse continue;
                if (desc.enumerable != true) continue;
                try enumerable_keys.append(ctx.runtime.nativeAllocator(), child_key);
            }
            for (enumerable_keys.items) |child_key| {
                const child_record: ?*const JsonParseRecord = if (active_record) |rec| rec.findObjectEntry(child_key) else null;
                try jsonInternalizeChild(ctx, output, global, value, object, child_key, rooted_reviver, reviver_call, child_record, caller_function, caller_frame);
            }
        }
    }

    key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, key);
    // context.source only for primitives with a surviving record
    // (quickjs.c: the source branch is in the `else` of JS_IsObject(val)).
    const primitive_record: ?*const JsonParseRecord = if (object_ops.objectFromValue(value) == null) active_record else null;
    context_value = try jsonReviverContext(ctx.runtime, global, primitive_record);
    const result = try reviver_call.callWithThis(rooted_holder_value, &.{ key_value, value, context_value });
    return result;
}

/// Recurse into one child then define/delete the result (the loop body of
/// internalize_json_property, quickjs.c). The recursion performs the
/// single [[Get]] for this child; no prefetch Get is done here.
pub fn jsonInternalizeChild(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    holder_value: core.JSValue,
    holder: *core.Object,
    key: core.Atom,
    reviver: core.JSValue,
    reviver_call: *CallSite,
    record: ?*const JsonParseRecord,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) HostError!void {
    var rooted_holder_value = holder_value;
    var rooted_reviver = reviver;
    var revived = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &rooted_holder_value, &rooted_reviver, &revived });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    revived = try jsonInternalizeProperty(ctx, output, global, rooted_holder_value, key, rooted_reviver, reviver_call, record, caller_function, caller_frame);
    if (revived.is(.undefined_value)) {
        _ = try object_ops.deleteValueProperty(ctx, output, global, rooted_holder_value, holder, key, caller_function, caller_frame);
    } else {
        try jsonCreateDataProperty(ctx, output, global, rooted_holder_value, holder, key, revived, caller_function, caller_frame);
    }
}

/// 49784-49792 the primitive source branch). `record` is non-null only for a
/// primitive value whose parse-time value survived the same-value guard; in
/// that case `context.source` is created from the recorded source span.
fn jsonReviverContext(rt: *core.JSRuntime, global: *core.Object, record: ?*const JsonParseRecord) !core.JSValue {
    var object_value = core.JSValue.undefinedValue();
    var source_value = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &object_value, &source_value });
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const object = try core.Object.create(rt, core.class.ids.object, object_ops.objectPrototypeFromGlobal(rt, global));
    object_value = object.value();
    if (record) |rec| {
        switch (rec.*) {
            .primitive => |p| {
                source_value = try value_ops.createStringValue(rt, p.source);
                try object.defineOwnProperty(rt, core.atom.ids.source, core.Descriptor.data(source_value, .all));
            },
            else => {},
        }
    }
    return object_value;
}

pub fn jsonCreateDataProperty(
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
    var root_frame = core.runtime.rootValues(.{ &rooted_holder_value, &rooted_value });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);
    // The caller hands over both the value and a convenience pointer to the
    // same object. Only the value is a root, so the pointer is re-derived
    // after the frame is live; `revive` above it allocates freely.
    _ = holder;
    const live_holder = objectFromValue(rooted_holder_value) orelse return;

    if (live_holder.proxyTarget() != null) {
        object_ops.createDataPropertyOrThrow(ctx, output, global, rooted_holder_value, live_holder, key, rooted_value, caller_function, caller_frame) catch |err| switch (err) {
            error.TypeError => return,
            else => return err,
        };
        return;
    }
    live_holder.defineOwnProperty(ctx.runtime, key, core.Descriptor.data(rooted_value, .all)) catch |err| switch (err) {
        error.IncompatibleDescriptor, error.NotExtensible, error.ReadOnly => return,
        else => return err,
    };
}

pub fn jsonStringifyCall(
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
    var root_frame = core.runtime.rootValues(.{ &value, &replacer, &space, &holder_value });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    if (replacer.is(.undefined_value) and space.is(.undefined_value)) {
        if (try jsonStringifySimpleNoOptions(ctx.runtime, global, value)) |fast| return fast;
    }

    const property_list = try jsonStringifyPropertyList(ctx, output, global, replacer, caller_function, caller_frame);
    defer property_list.deinit(ctx.runtime);
    var gap = try jsonStringifyGap(ctx, output, global, space, caller_function, caller_frame);
    defer gap.deinit(ctx.runtime.nativeAllocator());
    var replacer_call_storage: CallSite = undefined;
    const replacer_call: ?*CallSite = if (call_runtime.isCallableValue(replacer)) blk: {
        replacer_call_storage = CallSite.initInternal(
            ctx,
            output,
            global,
            core.JSValue.undefinedValue(),
            replacer,
            caller_function,
            caller_frame,
        );
        break :blk &replacer_call_storage;
    } else null;
    const options = JsonStringifyVmOptions{
        .replacer = replacer,
        .replacer_call = replacer_call,
        .property_list = property_list.items,
        .has_property_list = property_list.has_property_list,
        .gap = gap.items,
    };

    const holder = try core.Object.create(ctx.runtime, core.class.ids.object, object_ops.objectPrototypeFromGlobal(ctx.runtime, global));
    holder_value = holder.value();
    const root_key = core.atom.ids.empty_string;
    try holder.defineOwnProperty(ctx.runtime, root_key, core.Descriptor.data(value, .all));

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(ctx.runtime.nativeAllocator());
    var stack = std.ArrayList(*core.Object).empty;
    defer stack.deinit(ctx.runtime.nativeAllocator());
    try jsonSerializeProperty(ctx, output, global, &buffer, holder_value, holder, root_key, false, &stack, options, 0, caller_function, caller_frame);
    if (buffer.items.len == 0) return core.JSValue.undefinedValue();
    return try createJsonStringValue(ctx.runtime, buffer.items);
}

test "JSON.stringify roots direct function bytecode value while creating holder" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-json-stringify-value-bytecode-symbol");
    const fb = try core.FunctionBytecode.createPublishedFixture(rt, .{ .cpool_count = 1 }, &.{try rt.takeSymbolValue(symbol_atom)});

    const value = core.JSValue.functionBytecode(&fb.header);
    const args = [_]core.JSValue{
        value,
        core.JSValue.undefinedValue(),
        core.JSValue.int32(0),
    };

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const maybe_result = try jsonStringifyCall(ctx, null, global, &args, null, null);
    try std.testing.expect(maybe_result != null);
    const result = maybe_result.?;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try core.string.appendValueUtf8(rt, &bytes, result);
    try std.testing.expectEqualStrings("null", bytes.items);
    try std.testing.expect(rt.atoms.name(symbol_atom) != null);

    _ = rt.collectForTest();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn jsonStringifySimpleNoOptions(rt: *core.JSRuntime, global: *core.Object, value: core.JSValue) SimpleJsonStringifyError!?core.JSValue {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.nativeAllocator());
    var stack = std.ArrayList(*core.Object).empty;
    defer stack.deinit(rt.nativeAllocator());
    return switch (try jsonAppendSimpleValue(rt, global, &buffer, value, false, &stack)) {
        .appended => try createJsonStringValue(rt, buffer.items),
        .omitted => core.JSValue.undefinedValue(),
        .fallback => null,
    };
}

fn jsonAppendSimpleValue(
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
    // js_json_to_str, quickjs.c) instead of a native crash.
    if (rt.checkNativeStackOverflow(0)) return error.StackOverflow;
    if (value.is(.undefined_value) or value.is(.symbol)) {
        if (array_slot) {
            try buffer.appendSlice(rt.nativeAllocator(), "null");
            return .appended;
        }
        return .omitted;
    }
    if (value.is(.null_value)) {
        try buffer.appendSlice(rt.nativeAllocator(), "null");
        return .appended;
    }
    if (value.isString()) {
        try appendJsonStringValue(rt, buffer, value);
        return .appended;
    }
    if (value.as(.boolean)) |bool_value| {
        try buffer.appendSlice(rt.nativeAllocator(), if (bool_value) "true" else "false");
        return .appended;
    }
    if (value.as(.int)) |int_value| {
        var int_buf: [20]u8 = undefined;
        const printed = number_format.formatInt64(&int_buf, @as(i64, int_value));
        try buffer.appendSlice(rt.nativeAllocator(), printed);
        return .appended;
    }
    if (value_ops.numberValue(value)) |number| {
        if (!std.math.isFinite(number)) {
            try buffer.appendSlice(rt.nativeAllocator(), "null");
        } else if (number == 0) {
            try buffer.append(rt.nativeAllocator(), '0');
        } else {
            var number_buf: [128]u8 = undefined;
            const printed = value_ops.formatFiniteNumberAssumeCapacity(&number_buf, number);
            try buffer.appendSlice(rt.nativeAllocator(), printed);
        }
        return .appended;
    }
    if (value.isBigInt()) return .fallback;

    const object = object_ops.objectFromValue(value) orelse {
        try buffer.appendSlice(rt.nativeAllocator(), "null");
        return .appended;
    };
    if (call_runtime.isCallableValue(value)) return .fallback;
    if (!jsonSimplePrototypeChainHasNoToJSON(object)) return .fallback;
    if (object.isArray()) return try jsonAppendSimpleArray(rt, global, buffer, object, stack);
    return try jsonAppendSimpleObject(rt, global, buffer, object, stack);
}

fn jsonSimplePrototypeChainHasNoToJSON(object: *core.Object) bool {
    const to_json_key = core.atom.ids.toJSON;
    var cursor: ?*core.Object = object;
    while (cursor) |current| {
        if (current.hasExoticMethods() or current.isProxy()) return false;
        if (current.hasOwnProperty(to_json_key)) return false;
        cursor = current.getPrototype();
    }
    return true;
}

fn jsonAppendSimpleArray(
    rt: *core.JSRuntime,
    global: *core.Object,
    buffer: *std.ArrayList(u8),
    object: *core.Object,
    stack: *std.ArrayList(*core.Object),
) SimpleJsonStringifyError!SimpleJsonResult {
    const start = buffer.items.len;
    if (object.hasExoticMethods() or object.arrayElementStorageMode() != .dense) return .fallback;
    if (jsonObjectInStack(stack.items, object)) return error.TypeError;
    const elements = object.arrayElements();
    if (object.arrayLength() > elements.len) return .fallback;
    for (object.shapeProps()) |prop| {
        if (core.property.Flags.fromBits(prop.flags).deleted) continue;
        if (core.array.arrayIndexFromAtom(rt.atoms, prop.atom_id) != null) return .fallback;
    }

    try array_list_erased.append(stack, rt.nativeAllocator(), object);
    defer _ = stack.pop();
    errdefer buffer.shrinkRetainingCapacity(start);

    try buffer.append(rt.nativeAllocator(), '[');
    var index: usize = 0;
    while (index < object.arrayLength()) : (index += 1) {
        if (index != 0) try buffer.append(rt.nativeAllocator(), ',');
        const element = elements[index];
        switch (try jsonAppendSimpleValue(rt, global, buffer, element, true, stack)) {
            .appended => {},
            .omitted => try buffer.appendSlice(rt.nativeAllocator(), "null"),
            .fallback => {
                buffer.shrinkRetainingCapacity(start);
                return .fallback;
            },
        }
    }
    try buffer.append(rt.nativeAllocator(), ']');
    return .appended;
}

fn jsonAppendSimpleObject(
    rt: *core.JSRuntime,
    global: *core.Object,
    buffer: *std.ArrayList(u8),
    object: *core.Object,
    stack: *std.ArrayList(*core.Object),
) SimpleJsonStringifyError!SimpleJsonResult {
    const start = buffer.items.len;
    if (object.hasExoticMethods() or object.isProxy() or object.class_id != core.class.ids.object) return .fallback;
    if (jsonObjectInStack(stack.items, object)) return error.TypeError;

    try array_list_erased.append(stack, rt.nativeAllocator(), object);
    defer _ = stack.pop();
    errdefer buffer.shrinkRetainingCapacity(start);

    try buffer.append(rt.nativeAllocator(), '{');
    var emitted = false;
    for (object.shapeProps(), 0..) |prop, property_index| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted or !prop_flags.enumerable) continue;
        if (rt.atoms.isPublicSymbol(prop.atom_id)) continue;
        if (rt.atoms.kind(prop.atom_id) == .private) continue;
        if (core.array.arrayIndexFromAtom(rt.atoms, prop.atom_id) != null) {
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
        if (emitted) try buffer.append(rt.nativeAllocator(), ',');
        try appendJsonAtomName(rt, buffer, prop.atom_id);
        try buffer.append(rt.nativeAllocator(), ':');
        switch (try jsonAppendSimpleValue(rt, global, buffer, child_value, false, stack)) {
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
    try buffer.append(rt.nativeAllocator(), '}');
    return .appended;
}

pub fn jsonStringifyPropertyList(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    replacer: core.JSValue,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) !JsonStringifyPropertyList {
    var rooted_replacer = replacer;
    var item = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &rooted_replacer, &item });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    if (!try core.array.isArrayValue(rooted_replacer)) return .{};

    var list = std.ArrayList(core.Atom).empty;
    errdefer {
        list.deinit(ctx.runtime.nativeAllocator());
    }

    const length_value = try object_ops.getValueProperty(ctx, output, global, rooted_replacer, core.atom.ids.length, caller_function, caller_frame);
    const length = try coercion_ops.toLengthIndex(ctx, output, global, length_value);

    for (0..length) |index| {
        const index_key = try object_ops.propertyAtomFromLengthIndex(ctx.runtime, index);
        defer deinitLengthIndexAtom(ctx.runtime, index_key);
        item = try object_ops.getValueProperty(ctx, output, global, rooted_replacer, index_key.atom, caller_function, caller_frame);
        const atom = try jsonStringifyPropertyListAtom(ctx, output, global, item, caller_function, caller_frame) orelse continue;
        if (jsonAtomListContains(list.items, atom)) {
            continue;
        }
        try list.append(ctx.runtime.nativeAllocator(), atom);
    }

    return .{
        .items = try list.toOwnedSlice(ctx.runtime.nativeAllocator()),
        .has_property_list = true,
    };
}

fn jsonStringifyPropertyListAtom(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.JSValue,
    caller_function: ?*const Bytecode,
    caller_frame: ?*Frame,
) !?core.Atom {
    var rooted_value = value;
    var string_value = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{ &rooted_value, &string_value });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    const needs_string = rooted_value.isString() or
        value_ops.numberValue(rooted_value) != null or
        jsonIsStringOrNumberObject(rooted_value);
    if (!needs_string) return null;

    string_value = try string_ops.toStringForAnnexB(ctx, output, global, rooted_value, caller_function, caller_frame);
    const string_object = string_value.asStringBody().?;
    return try string_object.internAtom(ctx.runtime);
}

fn jsonIsStringOrNumberObject(value: core.JSValue) bool {
    const object = object_ops.objectFromValue(value) orelse return false;
    return object.class_id == core.class.ids.string or object.class_id == core.class.ids.number;
}

fn jsonAtomListContains(items: []const core.Atom, atom: core.Atom) bool {
    for (items) |item| {
        if (item == atom) return true;
    }
    return false;
}

pub fn jsonStringifyGap(
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
    var root_frame = core.runtime.rootValues(.{
        &rooted_space,
        &primitive,
        &number_value,
        &string_value,
    });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    var out = std.ArrayList(u8).empty;
    if (rooted_space.is(.object)) {
        if (object_ops.objectFromValue(rooted_space)) |object| {
            if (object.class_id == core.class.ids.number) {
                primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, rooted_space);
                number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
                return jsonStringifyGap(ctx, output, global, number_value, caller_function, caller_frame);
            } else if (object.class_id == core.class.ids.string) {
                string_value = try string_ops.toStringForAnnexB(ctx, output, global, rooted_space, caller_function, caller_frame);
                return jsonStringifyGap(ctx, output, global, string_value, caller_function, caller_frame);
            } else if (object.class_id == core.class.ids.boolean) {
                primitive = jsonPrimitiveWrapperValue(object) orelse return out;
                return jsonStringifyGap(ctx, output, global, primitive, caller_function, caller_frame);
            }
        }
    }
    if (rooted_space.isString()) {
        if (rooted_space.asStringBody()) |body| {
            switch (body.resolveData()) {
                .latin1 => |bytes| {
                    const take = @min(bytes.len, 10);
                    for (bytes[0..take]) |byte| {
                        if (byte < 0x80) {
                            try out.append(ctx.runtime.nativeAllocator(), byte);
                        } else {
                            try out.append(ctx.runtime.nativeAllocator(), 0xc0 | (byte >> 6));
                            try out.append(ctx.runtime.nativeAllocator(), 0x80 | (byte & 0x3f));
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
                            try out.appendSlice(ctx.runtime.nativeAllocator(), cp_buf[0..cp_len]);
                            index += 1;
                        } else if (unit < 0x80) {
                            try out.append(ctx.runtime.nativeAllocator(), @intCast(unit));
                        } else if (!unicode.isHighSurrogateUnit(unit) and !unicode.isLowSurrogateUnit(unit)) {
                            var cp_buf: [4]u8 = undefined;
                            const cp_len = std.unicode.utf8Encode(@intCast(unit), &cp_buf) catch continue;
                            try out.appendSlice(ctx.runtime.nativeAllocator(), cp_buf[0..cp_len]);
                        }
                    }
                },
            }
        }
    } else if (value_ops.numberValue(rooted_space)) |number| {
        const count_float = @min(@max(@floor(number), 0), 10);
        const count: usize = @intFromFloat(count_float);
        try out.appendNTimes(ctx.runtime.nativeAllocator(), ' ', count);
    }
    return out;
}

pub fn jsonSerializeProperty(
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
    // JS_ThrowStackOverflow, quickjs.c). error.StackOverflow maps to that
    // InternalError via runtimeErrorInfo.
    if (ctx.runtime.checkNativeStackOverflow(0)) return error.StackOverflow;
    var rooted_holder_value = holder_value;
    var rooted_replacer = options.replacer;
    var value = core.JSValue.undefinedValue();
    var key_value = core.JSValue.undefinedValue();
    var to_json = core.JSValue.undefinedValue();
    var root_frame = core.runtime.rootValues(.{
        &rooted_holder_value,
        &rooted_replacer,
        &value,
        &key_value,
        &to_json,
    });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    value = try object_ops.getValueProperty(ctx, output, global, rooted_holder_value, key, caller_function, caller_frame);
    key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, key);

    if (object_ops.objectFromValue(value) != null or value.isBigInt()) {
        to_json = try object_ops.getValueProperty(ctx, output, global, value, core.atom.ids.toJSON, caller_function, caller_frame);
        if (call_runtime.isCallableValue(to_json)) {
            const next = try call_runtime.callValueOrBytecodeSyncInternalOutlined(ctx, output, global, value, to_json, &.{key_value}, caller_function, caller_frame);
            value = next;
        }
    }

    if (options.replacer_call) |replacer_call| {
        const next = try replacer_call.callWithThis(rooted_holder_value, &.{ key_value, value });
        value = next;
    }

    _ = holder;
    try jsonAppendValue(ctx, output, global, buffer, value, array_slot, stack, options, depth, caller_function, caller_frame);
}

pub fn jsonAppendValue(
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
    var root_frame = core.runtime.rootValues(.{
        &rooted_value,
        &raw,
        &primitive,
        &number_value,
        &string_value,
    });
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    if (rooted_value.is(.undefined_value) or rooted_value.is(.symbol)) {
        try buffer.appendSlice(ctx.runtime.nativeAllocator(), if (array_slot) "null" else "");
    } else if (rooted_value.is(.null_value)) {
        try buffer.appendSlice(ctx.runtime.nativeAllocator(), "null");
    } else if (rooted_value.isString()) {
        try appendJsonStringValue(ctx.runtime, buffer, rooted_value);
    } else if (rooted_value.as(.boolean)) |bool_value| {
        try buffer.appendSlice(ctx.runtime.nativeAllocator(), if (bool_value) "true" else "false");
    } else if (value_ops.numberValue(rooted_value)) |number| {
        if (!std.math.isFinite(number)) {
            try buffer.appendSlice(ctx.runtime.nativeAllocator(), "null");
        } else if (number == 0) {
            try buffer.append(ctx.runtime.nativeAllocator(), '0');
        } else {
            var number_buf: [128]u8 = undefined;
            const printed = value_ops.formatFiniteNumberAssumeCapacity(&number_buf, number);
            try buffer.appendSlice(ctx.runtime.nativeAllocator(), printed);
        }
    } else if (rooted_value.isBigInt()) {
        return error.TypeError;
    } else if (object_ops.objectFromValue(rooted_value)) |object| {
        if (object.class_id == core.class.ids.raw_json) {
            raw = try object.getProperty(core.atom.ids.rawJSON);
            var raw_bytes = std.ArrayList(u8).empty;
            defer raw_bytes.deinit(ctx.runtime.nativeAllocator());
            try core.string.appendValueUtf8(ctx.runtime, &raw_bytes, raw);
            try buffer.appendSlice(ctx.runtime.nativeAllocator(), raw_bytes.items);
        } else if (call_runtime.isCallableValue(rooted_value)) {
            try buffer.appendSlice(ctx.runtime.nativeAllocator(), if (array_slot) "null" else "");
        } else if (object.class_id == core.class.ids.number) {
            primitive = try coercion_ops.toPrimitiveForNumber(ctx, output, global, rooted_value);
            number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
            try jsonAppendValue(ctx, output, global, buffer, number_value, array_slot, stack, options, depth, caller_function, caller_frame);
        } else if (object.class_id == core.class.ids.string) {
            string_value = try string_ops.toStringForAnnexB(ctx, output, global, rooted_value, caller_function, caller_frame);
            try jsonAppendValue(ctx, output, global, buffer, string_value, array_slot, stack, options, depth, caller_function, caller_frame);
        } else if (object.class_id == core.class.ids.boolean) {
            primitive = jsonPrimitiveWrapperValue(object) orelse core.JSValue.undefinedValue();
            try jsonAppendValue(ctx, output, global, buffer, primitive, array_slot, stack, options, depth, caller_function, caller_frame);
        } else if (object.class_id == core.class.ids.big_int) {
            primitive = coercion_ops.primitiveWrapperStoredValue(ctx.runtime, rooted_value) orelse return error.TypeError;
            try jsonAppendValue(ctx, output, global, buffer, primitive, array_slot, stack, options, depth, caller_function, caller_frame);
        } else if (try core.array.isArrayValue(rooted_value)) {
            try jsonAppendArray(ctx, output, global, buffer, rooted_value, object, stack, options, depth, caller_function, caller_frame);
        } else {
            try jsonAppendObject(ctx, output, global, buffer, rooted_value, object, stack, options, depth, caller_function, caller_frame);
        }
    } else {
        try buffer.appendSlice(ctx.runtime.nativeAllocator(), "null");
    }
}

pub fn jsonAppendArray(
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
    var root_frame = core.runtime.rootValues(.{&rooted_value});
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    if (jsonObjectInStack(stack.items, object)) return error.TypeError;
    try array_list_erased.append(stack, ctx.runtime.nativeAllocator(), object);
    defer _ = stack.pop();
    const length_value = try object_ops.getValueProperty(ctx, output, global, rooted_value, core.atom.ids.length, caller_function, caller_frame);
    const length = try coercion_ops.toLengthIndex(ctx, output, global, length_value);
    try buffer.append(ctx.runtime.nativeAllocator(), '[');
    for (0..length) |index| {
        if (index != 0) try buffer.append(ctx.runtime.nativeAllocator(), ',');
        if (options.gap.len != 0) {
            try buffer.append(ctx.runtime.nativeAllocator(), '\n');
            try jsonAppendIndent(ctx.runtime, buffer, options.gap, depth + 1);
        }
        const child_key = try object_ops.propertyAtomFromLengthIndex(ctx.runtime, index);
        defer deinitLengthIndexAtom(ctx.runtime, child_key);
        try jsonSerializeProperty(ctx, output, global, buffer, rooted_value, object, child_key.atom, true, stack, options, depth + 1, caller_function, caller_frame);
    }
    if (options.gap.len != 0 and length != 0) {
        try buffer.append(ctx.runtime.nativeAllocator(), '\n');
        try jsonAppendIndent(ctx.runtime, buffer, options.gap, depth);
    }
    try buffer.append(ctx.runtime.nativeAllocator(), ']');
}

pub fn jsonAppendObject(
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
    var root_frame = core.runtime.rootValues(.{&rooted_value});
    root_frame.activate(ctx.runtime);
    defer root_frame.deactivate(ctx.runtime);

    if (jsonObjectInStack(stack.items, object)) return error.TypeError;
    try array_list_erased.append(stack, ctx.runtime.nativeAllocator(), object);
    defer _ = stack.pop();
    try buffer.append(ctx.runtime.nativeAllocator(), '{');
    const owned_keys: []core.Atom = if (!options.has_property_list) try object_ops.objectRestOwnKeys(ctx, output, global, object) else &.{};
    defer if (!options.has_property_list) core.Object.freeKeys(ctx.runtime, owned_keys);
    var enumerable_keys = std.ArrayList(core.Atom).empty;
    defer enumerable_keys.deinit(ctx.runtime.nativeAllocator());
    if (!options.has_property_list) {
        for (owned_keys) |key| {
            if (ctx.runtime.atoms.isPublicSymbol(key)) continue;
            const desc = try object_ops.objectRestOwnPropertyDescriptor(ctx, output, global, object, key) orelse continue;
            if (desc.enumerable == true) try enumerable_keys.append(ctx.runtime.nativeAllocator(), key);
        }
    }
    const keys = if (options.has_property_list) options.property_list else enumerable_keys.items;
    var emitted = false;
    for (keys) |key| {
        if (ctx.runtime.atoms.isPublicSymbol(key)) continue;
        const before = buffer.items.len;
        var child = std.ArrayList(u8).empty;
        defer child.deinit(ctx.runtime.nativeAllocator());
        try jsonSerializeProperty(ctx, output, global, &child, rooted_value, object, key, false, stack, options, depth + 1, caller_function, caller_frame);
        if (child.items.len == 0) {
            buffer.shrinkRetainingCapacity(before);
            continue;
        }
        if (emitted) try buffer.append(ctx.runtime.nativeAllocator(), ',');
        if (options.gap.len != 0) {
            try buffer.append(ctx.runtime.nativeAllocator(), '\n');
            try jsonAppendIndent(ctx.runtime, buffer, options.gap, depth + 1);
        }
        emitted = true;
        try appendJsonAtomName(ctx.runtime, buffer, key);
        try buffer.appendSlice(ctx.runtime.nativeAllocator(), if (options.gap.len == 0) ":" else ": ");
        try buffer.appendSlice(ctx.runtime.nativeAllocator(), child.items);
    }
    if (options.gap.len != 0 and emitted) {
        try buffer.append(ctx.runtime.nativeAllocator(), '\n');
        try jsonAppendIndent(ctx.runtime, buffer, options.gap, depth);
    }
    try buffer.append(ctx.runtime.nativeAllocator(), '}');
}

/// Unwrap a Number/String/Boolean/BigInt/Symbol wrapper's stored primitive;
/// null for any other class (and for a wrapper with no stored data). Shared by
/// the bare and VM stringify paths, which used to carry byte-identical copies.
pub fn jsonPrimitiveWrapperValue(object: *core.Object) ?core.JSValue {
    return switch (object.class_id) {
        core.class.ids.string,
        core.class.ids.number,
        core.class.ids.boolean,
        core.class.ids.big_int,
        core.class.ids.symbol,
        => object.objectData(),
        else => null,
    };
}

pub fn jsonObjectInStack(items: []const *core.Object, object: *core.Object) bool {
    for (items) |item| {
        if (item == object) return true;
    }
    return false;
}

pub fn jsonAppendIndent(rt: *core.JSRuntime, buffer: *std.ArrayList(u8), gap: []const u8, depth: usize) !void {
    var index: usize = 0;
    while (index < depth) : (index += 1) try buffer.appendSlice(rt.nativeAllocator(), gap);
}

// TGC S3-d: allocation-point majors while the parse-record tree is being
// built. The tree is native memory on the general allocator, which the
// conservative pass does not walk; the padding tail in the source below is
// what pushes the shadowed value out of the stack slots and registers that
// pass DOES walk.
const S3DupKeyMajorProbe = struct {
    rt: *core.JSRuntime,
    active: bool = false,
    majors: usize = 0,

    fn trigger(context: ?*anyopaque, size: usize) void {
        _ = size;
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (!self.active) return;
        const saved_fn = self.rt.gc.heap_budget.probe;
        const saved_ctx = self.rt.gc.heap_budget.probe_ctx;
        self.rt.gc.heap_budget.probe = null;
        self.rt.gc.heap_budget.probe_ctx = null;
        defer {
            self.rt.gc.heap_budget.probe = saved_fn;
            self.rt.gc.heap_budget.probe_ctx = saved_ctx;
        }
        const before = self.rt.gc.block_heap.mark_epoch;
        _ = self.rt.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch {};
        if (self.rt.gc.block_heap.mark_epoch != before) self.majors += 1;
    }
};

test "TGC S3-d: a duplicate JSON key's shadowed record value survives majors taken mid-parse" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    // `findObjectEntry` returns the FIRST entry for a key (qjs
    // json_parse_record_find), so the reviver walk reads the record of the
    // SHADOWED occurrence -- whose value the second occurrence has already
    // overwritten on the object. From that overwrite to the end of the parse
    // its only holder is the native `entries` list, and the parse keeps
    // allocating (source spans, key atoms, list growth).
    const source = "{\"zjsS3DupKey\":{\"zjsS3DupInner\":\"zjsS3DupPayload\"},\"zjsS3DupKey\":1," ++
        "\"zjsS3DupPadA\":[[[[[[[[1,2,3,4],5],6],7],8],9],10],11]," ++
        "\"zjsS3DupPadB\":{\"a\":{\"b\":{\"c\":{\"d\":{\"e\":{\"f\":\"gggggggggggggggg\"}}}}}}," ++
        "\"zjsS3DupPadC\":[\"hhhhhhhhhhhhhhhh\",\"iiiiiiiiiiiiiiii\",\"jjjjjjjjjjjjjjjj\"]}";
    var text = (try core.string.String.createAscii(rt, source)).value();
    var text_roots = core.runtime.rootValues(.{&text});
    text_roots.activate(rt);
    defer text_roots.deactivate(rt);

    const saved_fn = rt.gc.heap_budget.probe;
    const saved_ctx = rt.gc.heap_budget.probe_ctx;
    var probe = S3DupKeyMajorProbe{ .rt = rt };
    rt.gc.heap_budget.probe = S3DupKeyMajorProbe.trigger;
    rt.gc.heap_budget.probe_ctx = &probe;
    defer {
        rt.gc.heap_budget.probe = saved_fn;
        rt.gc.heap_budget.probe_ctx = saved_ctx;
    }

    probe.active = true;
    var parse_result = parseWithRecord(rt, null, text) catch |err| {
        probe.active = false;
        return err;
    };
    probe.active = false;
    defer parse_result.record.deinit(rt);

    var parsed = parse_result.value;
    var parsed_roots = core.runtime.rootValues(.{&parsed});
    parsed_roots.activate(rt);
    defer parsed_roots.deactivate(rt);

    // Guard against a vacuous pass: the window has to have been crossed.
    try std.testing.expect(probe.majors > 0);

    var key = try rt.internAtom("zjsS3DupKey");
    var inner = try rt.internAtom("zjsS3DupInner");
    var key_roots = core.runtime.rootAtoms(.{ &key, &inner });
    key_roots.activate(rt);
    defer key_roots.deactivate(rt);

    // The last occurrence won as the property value...
    const parsed_object = object_ops.objectFromValue(parsed) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?i32, 1), (try parsed_object.getProperty(key)).as(.int));

    // ...while the record still names the first, and that object is still
    // live enough to read its own property back.
    const shadowed_record = parse_result.record.findObjectEntry(key) orelse return error.TestUnexpectedResult;
    const shadowed_object = object_ops.objectFromValue(shadowed_record.recordValue()) orelse
        return error.TestUnexpectedResult;
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try core.string.appendValueUtf8(rt, &bytes, try shadowed_object.getProperty(inner));
    try std.testing.expectEqualStrings("zjsS3DupPayload", bytes.items);
}
