const std = @import("std");

const bytecode = @import("../../bytecode/root.zig");
const builtins = @import("../../builtins/root.zig");
const core = @import("../../core/root.zig");
const exceptions = @import("../exceptions.zig");
const frame_mod = @import("../frame.zig");
const value_ops = @import("../value_ops.zig");
const shared_vm = @import("shared.zig");
const HostError = exceptions.HostError;

const JsonSourceCollectError = std.mem.Allocator.Error;

const SimpleJsonStringifyError = std.mem.Allocator.Error || error{
    InvalidUtf8,
    NoSpaceLeft,
    TypeError,
};

const JsonStringifyVmOptions = struct {
    replacer: core.Value = core.Value.undefinedValue(),
    property_list: []const core.Atom = &.{},
    has_property_list: bool = false,
    gap: []const u8 = "",
};

const JsonStringifyPropertyList = struct {
    items: []core.Atom = &.{},
    has_property_list: bool = false,

    fn deinit(self: JsonStringifyPropertyList, rt: *core.Runtime) void {
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

    fn deinit(self: JsonInternalizeChildInfo, rt: *core.Runtime) void {
        if (self.key_owned) rt.atoms.free(self.key);
    }
};

const SimpleJsonResult = enum {
    appended,
    omitted,
    fallback,
};

fn deinitLengthIndexAtom(rt: *core.Runtime, atom: anytype) void {
    if (atom.owned) rt.atoms.free(atom.atom);
}

pub fn qjsJsonParseCall(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.Value {
    var input = if (args.len >= 1) args[0] else core.Value.undefinedValue();
    var reviver = if (args.len >= 2) args[1] else core.Value.undefinedValue();
    var text = core.Value.undefinedValue();
    var parsed = core.Value.undefinedValue();
    var holder_value = core.Value.undefinedValue();
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

    text = try shared_vm.toStringForAnnexB(ctx, output, global, input, caller_function, caller_frame);
    defer {
        const owned_text = text;
        text = core.Value.undefinedValue();
        owned_text.free(ctx.runtime);
    }
    parsed = try builtins.json.parse(ctx.runtime, global, text);
    errdefer {
        const owned_parsed = parsed;
        parsed = core.Value.undefinedValue();
        owned_parsed.free(ctx.runtime);
    }
    if (!shared_vm.isCallableValue(reviver)) return parsed;

    var text_bytes = std.ArrayList(u8).empty;
    defer text_bytes.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendRawString(ctx.runtime, &text_bytes, text);
    var primitive_sources = std.ArrayList([]const u8).empty;
    defer primitive_sources.deinit(ctx.runtime.memory.allocator);
    try qjsJsonCollectPrimitiveSources(ctx.runtime.memory.allocator, text_bytes.items, &primitive_sources);

    const holder = try core.Object.create(ctx.runtime, core.class.ids.object, shared_vm.objectPrototypeFromGlobal(ctx.runtime, global));
    holder_value = holder.value();
    defer {
        const owned_holder = holder_value;
        holder_value = core.Value.undefinedValue();
        owned_holder.free(ctx.runtime);
    }
    const root_key = try ctx.runtime.internAtom("");
    defer ctx.runtime.atoms.free(root_key);
    try holder.defineOwnProperty(ctx.runtime, root_key, core.Descriptor.data(parsed, true, true, true));
    const stored_parsed = parsed;
    parsed = core.Value.undefinedValue();
    stored_parsed.free(ctx.runtime);

    var source_cursor = JsonParseSourceCursor{ .sources = primitive_sources.items };
    return try qjsJsonInternalizeProperty(ctx, output, global, holder_value, root_key, reviver, &source_cursor, caller_function, caller_frame);
}

test "JSON.parse roots direct function bytecode input while coercing to string" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.Context.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-json-parse-input-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.Value, 1);
    fb.cpool[0] = core.Value.symbol(symbol_atom);
    fb.cpool_count = 1;

    var input = core.Value.functionBytecode(&fb.header);
    var input_alive = true;
    defer if (input_alive) input.free(rt);
    const args = [_]core.Value{input};

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
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    holder_value: core.Value,
    key: core.Atom,
    reviver: core.Value,
    source_cursor: ?*JsonParseSourceCursor,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !core.Value {
    var rooted_holder_value = holder_value;
    var rooted_reviver = reviver;
    var value = core.Value.undefinedValue();
    var key_value = core.Value.undefinedValue();
    var context_value = core.Value.undefinedValue();
    var scratch_value = core.Value.undefinedValue();
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

    value = try shared_vm.getValueProperty(ctx, output, global, rooted_holder_value, key, caller_function, caller_frame);
    defer {
        const owned_value = value;
        value = core.Value.undefinedValue();
        owned_value.free(ctx.runtime);
    }

    if (shared_vm.objectFromValue(value)) |object| {
        if (try builtins.array.isArrayValue(value)) {
            const length_value = try shared_vm.getValueProperty(ctx, output, global, value, core.atom.ids.length, caller_function, caller_frame);
            defer length_value.free(ctx.runtime);
            const length = try shared_vm.toLengthIndex(ctx, output, global, length_value);
            var index: usize = 0;
            var child_infos = std.ArrayList(JsonInternalizeChildInfo).empty;
            defer {
                for (child_infos.items) |info| info.deinit(ctx.runtime);
                child_infos.deinit(ctx.runtime.memory.allocator);
            }
            var child_values = std.ArrayList(core.Value).empty;
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
                const child_key = try shared_vm.propertyAtomFromLengthIndex(ctx.runtime, index);
                scratch_value = try shared_vm.getValueProperty(ctx, output, global, value, child_key.atom, caller_function, caller_frame);
                const original_index = child_values.items.len;
                child_values.append(ctx.runtime.memory.allocator, scratch_value) catch |err| {
                    const failed_child = scratch_value;
                    scratch_value = core.Value.undefinedValue();
                    failed_child.free(ctx.runtime);
                    deinitLengthIndexAtom(ctx.runtime, child_key);
                    return err;
                };
                scratch_value = core.Value.undefinedValue();
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
            const keys = try shared_vm.objectRestOwnKeys(ctx, output, global, object);
            defer core.Object.freeKeys(ctx.runtime, keys);
            var child_infos = std.ArrayList(JsonInternalizeChildInfo).empty;
            defer {
                for (child_infos.items) |info| info.deinit(ctx.runtime);
                child_infos.deinit(ctx.runtime.memory.allocator);
            }
            var child_values = std.ArrayList(core.Value).empty;
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
                if (ctx.runtime.atoms.kind(child_key) == .symbol) continue;
                const desc = try shared_vm.objectRestOwnPropertyDescriptor(ctx, output, global, object, child_key) orelse continue;
                defer desc.destroy(ctx.runtime);
                if (desc.enumerable != true) continue;
                scratch_value = try shared_vm.getValueProperty(ctx, output, global, value, child_key, caller_function, caller_frame);
                const original_index = child_values.items.len;
                child_values.append(ctx.runtime.memory.allocator, scratch_value) catch |err| {
                    const failed_child = scratch_value;
                    scratch_value = core.Value.undefinedValue();
                    failed_child.free(ctx.runtime);
                    return err;
                };
                scratch_value = core.Value.undefinedValue();
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
        key_value = core.Value.undefinedValue();
        owned_key.free(ctx.runtime);
    }
    context_value = try qjsJsonReviverContext(ctx.runtime, global, value, source_cursor);
    defer {
        const owned_context = context_value;
        context_value = core.Value.undefinedValue();
        owned_context.free(ctx.runtime);
    }
    const result = try shared_vm.callValueOrBytecode(ctx, output, global, rooted_holder_value, rooted_reviver, &.{ key_value, value, context_value }, caller_function, caller_frame);
    if (result.same(value) or result.same(key_value) or result.same(rooted_holder_value)) {
        const duplicated = result.dup();
        result.free(ctx.runtime);
        return duplicated;
    }
    return result;
}

pub fn qjsJsonInternalizeChild(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    holder_value: core.Value,
    holder: *core.Object,
    key: core.Atom,
    reviver: core.Value,
    source_cursor: ?*JsonParseSourceCursor,
    original_value: core.Value,
    source_count: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!void {
    var rooted_holder_value = holder_value;
    var rooted_reviver = reviver;
    var rooted_original_value = original_value;
    var current = core.Value.undefinedValue();
    var revived = core.Value.undefinedValue();
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
        current = try shared_vm.getValueProperty(ctx, output, global, rooted_holder_value, key, caller_function, caller_frame);
        defer {
            const owned_current = current;
            current = core.Value.undefinedValue();
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
        revived = core.Value.undefinedValue();
        owned_revived.free(ctx.runtime);
    }
    if (revived.isUndefined()) {
        _ = try shared_vm.deleteValueProperty(ctx, output, global, rooted_holder_value, holder, key, caller_function, caller_frame);
    } else {
        try qjsJsonCreateDataProperty(ctx, output, global, rooted_holder_value, holder, key, revived, caller_function, caller_frame);
    }
}

fn qjsJsonReviverContext(rt: *core.Runtime, global: *core.Object, value: core.Value, source_cursor: ?*JsonParseSourceCursor) !core.Value {
    var rooted_value = value;
    var object_value = core.Value.undefinedValue();
    var source_value = core.Value.undefinedValue();
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

    const object = try core.Object.create(rt, core.class.ids.object, shared_vm.objectPrototypeFromGlobal(rt, global));
    object_value = object.value();
    errdefer {
        const failed_object = object_value;
        object_value = core.Value.undefinedValue();
        failed_object.free(rt);
    }
    if (shared_vm.objectFromValue(rooted_value) == null) {
        if (source_cursor) |cursor| {
            if (cursor.next()) |source| {
                source_value = try value_ops.createStringValue(rt, source);
                defer {
                    const owned_source = source_value;
                    source_value = core.Value.undefinedValue();
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

fn qjsJsonSourceCountForValue(rt: *core.Runtime, value: core.Value) !usize {
    var rooted_value = value;
    var child = core.Value.undefinedValue();
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

    const object = shared_vm.objectFromValue(rooted_value) orelse return 1;
    var count: usize = 0;
    if (object.is_array) {
        var index: usize = 0;
        while (index < object.length) : (index += 1) {
            const key = try shared_vm.propertyAtomFromLengthIndex(rt, index);
            defer deinitLengthIndexAtom(rt, key);
            child = object.getProperty(key.atom);
            defer {
                const owned_child = child;
                child = core.Value.undefinedValue();
                owned_child.free(rt);
            }
            count += try qjsJsonSourceCountForValue(rt, child);
        }
        return count;
    }
    const keys = try object.ownKeys(rt);
    defer core.Object.freeKeys(rt, keys);
    for (keys) |key| {
        if (rt.atoms.kind(key) == .symbol) continue;
        const desc = object.getOwnProperty(key) orelse continue;
        defer desc.destroy(rt);
        if (desc.enumerable != true) continue;
        child = object.getProperty(key);
        defer {
            const owned_child = child;
            child = core.Value.undefinedValue();
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
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    holder_value: core.Value,
    holder: *core.Object,
    key: core.Atom,
    value: core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
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
        shared_vm.createDataPropertyOrThrow(ctx, output, global, rooted_holder_value, holder, key, rooted_value, caller_function, caller_frame) catch |err| switch (err) {
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
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    args: []const core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.Value {
    var value = if (args.len >= 1) args[0] else core.Value.undefinedValue();
    var replacer = if (args.len >= 2) args[1] else core.Value.undefinedValue();
    var space = if (args.len >= 3) args[2] else core.Value.undefinedValue();
    var holder_value = core.Value.undefinedValue();
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

    const holder = try core.Object.create(ctx.runtime, core.class.ids.object, shared_vm.objectPrototypeFromGlobal(ctx.runtime, global));
    holder_value = holder.value();
    defer {
        const owned_holder = holder_value;
        holder_value = core.Value.undefinedValue();
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
    if (buffer.items.len == 0) return core.Value.undefinedValue();
    return try builtins.json.createJsonStringValue(ctx.runtime, buffer.items);
}

test "JSON.stringify roots direct function bytecode value while creating holder" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const ctx = try core.Context.create(rt);
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);

    const fb_slice = try rt.memory.alloc(bytecode.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = bytecode.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-json-stringify-value-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.Value, 1);
    fb.cpool[0] = core.Value.symbol(symbol_atom);
    fb.cpool_count = 1;

    var value = core.Value.functionBytecode(&fb.header);
    var value_alive = true;
    defer if (value_alive) value.free(rt);
    const args = [_]core.Value{
        value,
        core.Value.undefinedValue(),
        core.Value.int32(0),
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

fn qjsJsonStringifySimpleNoOptions(rt: *core.Runtime, global: *core.Object, value: core.Value) SimpleJsonStringifyError!?core.Value {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(rt.memory.allocator);
    var stack = std.ArrayList(*core.Object).empty;
    defer stack.deinit(rt.memory.allocator);
    return switch (try qjsJsonAppendSimpleValue(rt, global, &buffer, value, false, &stack)) {
        .appended => try builtins.json.createJsonStringValue(rt, buffer.items),
        .omitted => core.Value.undefinedValue(),
        .fallback => null,
    };
}

fn qjsJsonAppendSimpleValue(
    rt: *core.Runtime,
    global: *core.Object,
    buffer: *std.ArrayList(u8),
    value: core.Value,
    array_slot: bool,
    stack: *std.ArrayList(*core.Object),
) SimpleJsonStringifyError!SimpleJsonResult {
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
        try builtins.json.appendJsonStringValue(rt, buffer, value);
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

    const object = shared_vm.objectFromValue(value) orelse {
        try buffer.appendSlice(rt.memory.allocator, "null");
        return .appended;
    };
    if (shared_vm.isCallableValue(value)) return .fallback;
    if (!qjsJsonSimplePrototypeChainHasNoToJSON(object)) return .fallback;
    if (object.is_array) return try qjsJsonAppendSimpleArray(rt, global, buffer, object, stack);
    return try qjsJsonAppendSimpleObject(rt, global, buffer, object, stack);
}

fn qjsJsonSimplePrototypeChainHasNoToJSON(object: *core.Object) bool {
    const to_json_key = core.atom.ids.toJSON;
    var cursor: ?*core.Object = object;
    while (cursor) |current| {
        if (current.exotic != null or current.is_proxy) return false;
        if (current.hasOwnProperty(to_json_key)) return false;
        cursor = current.getPrototype();
    }
    return true;
}

fn qjsJsonAppendSimpleArray(
    rt: *core.Runtime,
    global: *core.Object,
    buffer: *std.ArrayList(u8),
    object: *core.Object,
    stack: *std.ArrayList(*core.Object),
) SimpleJsonStringifyError!SimpleJsonResult {
    const start = buffer.items.len;
    if (object.exotic != null or object.arrayElementStorageMode() != .dense) return .fallback;
    if (qjsJsonObjectInStack(stack.items, object)) return error.TypeError;
    const elements = object.arrayElements();
    if (object.length > elements.len) return .fallback;
    for (object.properties) |entry| {
        if (entry.flags.deleted) continue;
        if (core.array.arrayIndexFromAtom(&rt.atoms, entry.atom_id) != null) return .fallback;
    }

    try stack.append(rt.memory.allocator, object);
    defer _ = stack.pop();
    errdefer buffer.shrinkRetainingCapacity(start);

    try buffer.append(rt.memory.allocator, '[');
    var index: usize = 0;
    while (index < object.length) : (index += 1) {
        if (index != 0) try buffer.append(rt.memory.allocator, ',');
        const element = elements[index] orelse {
            buffer.shrinkRetainingCapacity(start);
            return .fallback;
        };
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
    rt: *core.Runtime,
    global: *core.Object,
    buffer: *std.ArrayList(u8),
    object: *core.Object,
    stack: *std.ArrayList(*core.Object),
) SimpleJsonStringifyError!SimpleJsonResult {
    const start = buffer.items.len;
    if (object.exotic != null or object.is_proxy or object.class_id != core.class.ids.object) return .fallback;
    if (qjsJsonObjectInStack(stack.items, object)) return error.TypeError;

    try stack.append(rt.memory.allocator, object);
    defer _ = stack.pop();
    errdefer buffer.shrinkRetainingCapacity(start);

    try buffer.append(rt.memory.allocator, '{');
    var emitted = false;
    for (object.properties) |entry| {
        if (entry.flags.deleted or !entry.flags.enumerable) continue;
        if (rt.atoms.kind(entry.atom_id) == .symbol) continue;
        if (core.array.arrayIndexFromAtom(&rt.atoms, entry.atom_id) != null) {
            buffer.shrinkRetainingCapacity(start);
            return .fallback;
        }
        if (entry.flags.accessor) {
            buffer.shrinkRetainingCapacity(start);
            return .fallback;
        }
        const child_value = switch (entry.slot) {
            .data => |stored| stored,
            .auto_init, .accessor, .deleted => {
                buffer.shrinkRetainingCapacity(start);
                return .fallback;
            },
        };
        const property_start = buffer.items.len;
        if (emitted) try buffer.append(rt.memory.allocator, ',');
        try builtins.json.appendJsonAtomName(rt, buffer, entry.atom_id);
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
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    replacer: core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !JsonStringifyPropertyList {
    var rooted_replacer = replacer;
    var item = core.Value.undefinedValue();
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

    if (!try builtins.array.isArrayValue(rooted_replacer)) return .{};

    var list = std.ArrayList(core.Atom).empty;
    errdefer {
        for (list.items) |atom| ctx.runtime.atoms.free(atom);
        list.deinit(ctx.runtime.memory.allocator);
    }

    const length_value = try shared_vm.getValueProperty(ctx, output, global, rooted_replacer, core.atom.ids.length, caller_function, caller_frame);
    defer length_value.free(ctx.runtime);
    const length = try shared_vm.toLengthIndex(ctx, output, global, length_value);

    var index: usize = 0;
    while (index < length) : (index += 1) {
        const index_key = try shared_vm.propertyAtomFromLengthIndex(ctx.runtime, index);
        defer deinitLengthIndexAtom(ctx.runtime, index_key);
        item = try shared_vm.getValueProperty(ctx, output, global, rooted_replacer, index_key.atom, caller_function, caller_frame);
        defer {
            const owned_item = item;
            item = core.Value.undefinedValue();
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
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    value: core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !?core.Atom {
    var rooted_value = value;
    var string_value = core.Value.undefinedValue();
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

    string_value = try shared_vm.toStringForAnnexB(ctx, output, global, rooted_value, caller_function, caller_frame);
    defer {
        const owned_string = string_value;
        string_value = core.Value.undefinedValue();
        owned_string.free(ctx.runtime);
    }
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(ctx.runtime.memory.allocator);
    try value_ops.appendRawString(ctx.runtime, &bytes, string_value);
    return try ctx.runtime.internAtom(bytes.items);
}

fn qjsJsonIsStringOrNumberObject(value: core.Value) bool {
    const object = shared_vm.objectFromValue(value) orelse return false;
    return object.class_id == core.class.ids.string or object.class_id == core.class.ids.number;
}

fn qjsJsonAtomListContains(items: []const core.Atom, atom: core.Atom) bool {
    for (items) |item| {
        if (item == atom) return true;
    }
    return false;
}

pub fn qjsJsonStringifyGap(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    space: core.Value,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !std.ArrayList(u8) {
    var rooted_space = space;
    var primitive = core.Value.undefinedValue();
    var number_value = core.Value.undefinedValue();
    var string_value = core.Value.undefinedValue();
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
        if (shared_vm.objectFromValue(rooted_space)) |object| {
            if (object.class_id == core.class.ids.number) {
                primitive = try shared_vm.toPrimitiveForNumber(ctx, output, global, rooted_space);
                defer {
                    const owned_primitive = primitive;
                    primitive = core.Value.undefinedValue();
                    owned_primitive.free(ctx.runtime);
                }
                number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
                defer {
                    const owned_number = number_value;
                    number_value = core.Value.undefinedValue();
                    owned_number.free(ctx.runtime);
                }
                return qjsJsonStringifyGap(ctx, output, global, number_value, caller_function, caller_frame);
            } else if (object.class_id == core.class.ids.string) {
                string_value = try shared_vm.toStringForAnnexB(ctx, output, global, rooted_space, caller_function, caller_frame);
                defer {
                    const owned_string = string_value;
                    string_value = core.Value.undefinedValue();
                    owned_string.free(ctx.runtime);
                }
                return qjsJsonStringifyGap(ctx, output, global, string_value, caller_function, caller_frame);
            } else if (object.class_id == core.class.ids.boolean) {
                primitive = try qjsJsonPrimitiveWrapperValue(ctx.runtime, object) orelse return out;
                defer {
                    const owned_primitive = primitive;
                    primitive = core.Value.undefinedValue();
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
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    buffer: *std.ArrayList(u8),
    holder_value: core.Value,
    holder: *core.Object,
    key: core.Atom,
    array_slot: bool,
    stack: *std.ArrayList(*core.Object),
    options: JsonStringifyVmOptions,
    depth: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) HostError!void {
    var rooted_holder_value = holder_value;
    var rooted_replacer = options.replacer;
    var value = core.Value.undefinedValue();
    var key_value = core.Value.undefinedValue();
    var to_json = core.Value.undefinedValue();
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

    value = try shared_vm.getValueProperty(ctx, output, global, rooted_holder_value, key, caller_function, caller_frame);
    defer {
        const owned_value = value;
        value = core.Value.undefinedValue();
        owned_value.free(ctx.runtime);
    }
    key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, key);
    defer {
        const owned_key = key_value;
        key_value = core.Value.undefinedValue();
        owned_key.free(ctx.runtime);
    }

    if (shared_vm.objectFromValue(value) != null or value.isBigInt()) {
        to_json = try shared_vm.getValueProperty(ctx, output, global, value, core.atom.ids.toJSON, caller_function, caller_frame);
        defer {
            const owned_to_json = to_json;
            to_json = core.Value.undefinedValue();
            owned_to_json.free(ctx.runtime);
        }
        if (shared_vm.isCallableValue(to_json)) {
            const next = try shared_vm.callValueOrBytecode(ctx, output, global, value, to_json, &.{key_value}, caller_function, caller_frame);
            const old_value = value;
            value = next;
            old_value.free(ctx.runtime);
        }
    }

    if (shared_vm.isCallableValue(rooted_replacer)) {
        const next = try shared_vm.callValueOrBytecode(ctx, output, global, rooted_holder_value, rooted_replacer, &.{ key_value, value }, caller_function, caller_frame);
        const old_value = value;
        value = next;
        old_value.free(ctx.runtime);
    }

    _ = holder;
    try qjsJsonAppendValue(ctx, output, global, buffer, value, array_slot, stack, options, depth, caller_function, caller_frame);
}

pub fn qjsJsonAppendValue(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    buffer: *std.ArrayList(u8),
    value: core.Value,
    array_slot: bool,
    stack: *std.ArrayList(*core.Object),
    options: JsonStringifyVmOptions,
    depth: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
) !void {
    var rooted_value = value;
    var raw = core.Value.undefinedValue();
    var primitive = core.Value.undefinedValue();
    var number_value = core.Value.undefinedValue();
    var string_value = core.Value.undefinedValue();
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
        try builtins.json.appendJsonStringValue(ctx.runtime, buffer, rooted_value);
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
    } else if (shared_vm.objectFromValue(rooted_value)) |object| {
        if (object.class_id == core.class.ids.raw_json) {
            raw = object.getProperty(core.atom.ids.rawJSON);
            defer {
                const owned_raw = raw;
                raw = core.Value.undefinedValue();
                owned_raw.free(ctx.runtime);
            }
            var raw_bytes = std.ArrayList(u8).empty;
            defer raw_bytes.deinit(ctx.runtime.memory.allocator);
            try value_ops.appendRawString(ctx.runtime, &raw_bytes, raw);
            try buffer.appendSlice(ctx.runtime.memory.allocator, raw_bytes.items);
        } else if (shared_vm.isCallableValue(rooted_value)) {
            try buffer.appendSlice(ctx.runtime.memory.allocator, if (array_slot) "null" else "");
        } else if (object.class_id == core.class.ids.number) {
            primitive = try shared_vm.toPrimitiveForNumber(ctx, output, global, rooted_value);
            defer {
                const owned_primitive = primitive;
                primitive = core.Value.undefinedValue();
                owned_primitive.free(ctx.runtime);
            }
            number_value = try value_ops.toNumberValue(ctx.runtime, primitive);
            defer {
                const owned_number = number_value;
                number_value = core.Value.undefinedValue();
                owned_number.free(ctx.runtime);
            }
            try qjsJsonAppendValue(ctx, output, global, buffer, number_value, array_slot, stack, options, depth, caller_function, caller_frame);
        } else if (object.class_id == core.class.ids.string) {
            string_value = try shared_vm.toStringForAnnexB(ctx, output, global, rooted_value, caller_function, caller_frame);
            defer {
                const owned_string = string_value;
                string_value = core.Value.undefinedValue();
                owned_string.free(ctx.runtime);
            }
            try qjsJsonAppendValue(ctx, output, global, buffer, string_value, array_slot, stack, options, depth, caller_function, caller_frame);
        } else if (object.class_id == core.class.ids.boolean) {
            primitive = try qjsJsonPrimitiveWrapperValue(ctx.runtime, object) orelse core.Value.undefinedValue();
            defer {
                const owned_primitive = primitive;
                primitive = core.Value.undefinedValue();
                owned_primitive.free(ctx.runtime);
            }
            try qjsJsonAppendValue(ctx, output, global, buffer, primitive, array_slot, stack, options, depth, caller_function, caller_frame);
        } else if (object.class_id == core.class.ids.big_int) {
            primitive = shared_vm.primitiveWrapperStoredValue(ctx.runtime, rooted_value) orelse return error.TypeError;
            defer {
                const owned_primitive = primitive;
                primitive = core.Value.undefinedValue();
                owned_primitive.free(ctx.runtime);
            }
            try qjsJsonAppendValue(ctx, output, global, buffer, primitive, array_slot, stack, options, depth, caller_function, caller_frame);
        } else if (try builtins.array.isArrayValue(rooted_value)) {
            try qjsJsonAppendArray(ctx, output, global, buffer, rooted_value, object, stack, options, depth, caller_function, caller_frame);
        } else {
            try qjsJsonAppendObject(ctx, output, global, buffer, rooted_value, object, stack, options, depth, caller_function, caller_frame);
        }
    } else {
        try buffer.appendSlice(ctx.runtime.memory.allocator, "null");
    }
}

pub fn qjsJsonAppendArray(
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    buffer: *std.ArrayList(u8),
    value: core.Value,
    object: *core.Object,
    stack: *std.ArrayList(*core.Object),
    options: JsonStringifyVmOptions,
    depth: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
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
    const length_value = try shared_vm.getValueProperty(ctx, output, global, rooted_value, core.atom.ids.length, caller_function, caller_frame);
    defer length_value.free(ctx.runtime);
    const length = try shared_vm.toLengthIndex(ctx, output, global, length_value);
    try buffer.append(ctx.runtime.memory.allocator, '[');
    var index: usize = 0;
    while (index < length) : (index += 1) {
        if (index != 0) try buffer.append(ctx.runtime.memory.allocator, ',');
        if (options.gap.len != 0) {
            try buffer.append(ctx.runtime.memory.allocator, '\n');
            try qjsJsonAppendIndent(ctx.runtime, buffer, options.gap, depth + 1);
        }
        const child_key = try shared_vm.propertyAtomFromLengthIndex(ctx.runtime, index);
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
    ctx: *core.Context,
    output: ?*std.Io.Writer,
    global: *core.Object,
    buffer: *std.ArrayList(u8),
    value: core.Value,
    object: *core.Object,
    stack: *std.ArrayList(*core.Object),
    options: JsonStringifyVmOptions,
    depth: usize,
    caller_function: ?*const bytecode.Bytecode,
    caller_frame: ?*frame_mod.Frame,
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
    const owned_keys: []core.Atom = if (!options.has_property_list) try shared_vm.objectRestOwnKeys(ctx, output, global, object) else &.{};
    defer if (!options.has_property_list) core.Object.freeKeys(ctx.runtime, owned_keys);
    var enumerable_keys = std.ArrayList(core.Atom).empty;
    defer enumerable_keys.deinit(ctx.runtime.memory.allocator);
    if (!options.has_property_list) {
        for (owned_keys) |key| {
            if (ctx.runtime.atoms.kind(key) == .symbol) continue;
            const desc = try shared_vm.objectRestOwnPropertyDescriptor(ctx, output, global, object, key) orelse continue;
            defer desc.destroy(ctx.runtime);
            if (desc.enumerable == true) try enumerable_keys.append(ctx.runtime.memory.allocator, key);
        }
    }
    const keys = if (options.has_property_list) options.property_list else enumerable_keys.items;
    var emitted = false;
    for (keys) |key| {
        if (ctx.runtime.atoms.kind(key) == .symbol) continue;
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
        try builtins.json.appendJsonAtomName(ctx.runtime, buffer, key);
        try buffer.appendSlice(ctx.runtime.memory.allocator, if (options.gap.len == 0) ":" else ": ");
        try buffer.appendSlice(ctx.runtime.memory.allocator, child.items);
    }
    if (options.gap.len != 0 and emitted) {
        try buffer.append(ctx.runtime.memory.allocator, '\n');
        try qjsJsonAppendIndent(ctx.runtime, buffer, options.gap, depth);
    }
    try buffer.append(ctx.runtime.memory.allocator, '}');
}

pub fn qjsJsonPrimitiveWrapperValue(rt: *core.Runtime, object: *core.Object) !?core.Value {
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

pub fn qjsJsonAppendIndent(rt: *core.Runtime, buffer: *std.ArrayList(u8), gap: []const u8, depth: usize) !void {
    var index: usize = 0;
    while (index < depth) : (index += 1) try buffer.appendSlice(rt.memory.allocator, gap);
}
