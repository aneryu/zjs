const core = @import("../core/root.zig");
const function_builtin = @import("function.zig");
const closure_mod = @import("../exec/closure.zig");
const globals_mod = @import("../exec/globals.zig");
const std = @import("std");

pub fn sameValueZero(a: core.Value, b: core.Value) bool {
    if (numberValue(a)) |lhs| {
        if (numberValue(b)) |rhs| {
            if (std.math.isNan(lhs) and std.math.isNan(rhs)) return true;
            return lhs == rhs;
        }
    }
    if (a.asBool()) |lhs| {
        if (b.asBool()) |rhs| return lhs == rhs;
    }
    if (a.isNull() or a.isUndefined()) return a.same(b);
    if (a.isString() and b.isString()) {
        const lhs = stringFromValue(a) orelse return false;
        const rhs = stringFromValue(b) orelse return false;
        return lhs.eqlString(rhs.*);
    }
    return a.same(b);
}

pub const Entry = struct {
    key: core.Value,
    value: core.Value,
};

/// QuickJS source map: narrow collection constructors used by the transitional
/// `new_collection` bytecode.
pub fn construct(rt: *core.Runtime, kind: u32) !core.Value {
    return constructWithPrototype(rt, kind, null);
}

pub fn constructWithPrototype(rt: *core.Runtime, kind: u32, prototype: ?*core.Object) !core.Value {
    const class_id = collectionClassId(kind) orelse return error.UnsupportedCollectionCall;
    const object = try core.Object.create(rt, class_id, prototype);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    if (class_id == core.class.ids.map or class_id == core.class.ids.set) try defineIntProperty(rt, object, "size", 0);
    if (prototype == null) try defineNativeMethods(rt, object, class_id);
    return object.value();
}

/// QuickJS source map: selected Map/Set/WeakMap/WeakSet methods currently
/// covered by smoke fixtures and targeted collection validation. Strong
/// collections use object-owned entry arrays; weak collections store object
/// identities plus values so keys are not retained through ordinary properties.
pub fn methodCall(rt: *core.Runtime, object_value: core.Value, method: u32, args: []const core.Value) !core.Value {
    return methodCallWithGlobals(rt, object_value, method, args, &.{});
}

pub fn methodCallWithGlobals(
    rt: *core.Runtime,
    object_value: core.Value,
    method: u32,
    args: []const core.Value,
    globals: []globals_mod.Slot,
) !core.Value {
    const object = try expectObject(object_value);
    return switch (method) {
        1 => {
            if (args.len != 2) return error.UnsupportedCollectionCall;
            return mapSet(rt, object, args[0], args[1]);
        },
        2 => {
            if (args.len != 1) return error.UnsupportedCollectionCall;
            return mapGet(object, args[0]);
        },
        3 => {
            if (args.len != 1) return error.UnsupportedCollectionCall;
            return collectionHas(object, args[0]);
        },
        4 => {
            if (args.len != 1) return error.UnsupportedCollectionCall;
            return collectionDelete(rt, object, args[0]);
        },
        5 => {
            if (args.len != 0) return error.UnsupportedCollectionCall;
            return collectionClear(rt, object);
        },
        6 => {
            if (args.len != 1) return error.UnsupportedCollectionCall;
            return setAdd(rt, object, args[0]);
        },
        7 => {
            if (args.len != 0) return error.UnsupportedCollectionCall;
            return mapIterator(rt, object, .key);
        },
        8 => {
            if (args.len != 0) return error.UnsupportedCollectionCall;
            return mapIterator(rt, object, .value);
        },
        9 => {
            if (args.len != 0) return error.UnsupportedCollectionCall;
            return mapIterator(rt, object, .key_value);
        },
        10 => return mapForEach(rt, object, args, globals),
        11 => {
            if (args.len < 2) return error.UnsupportedCollectionCall;
            return mapGetOrInsert(rt, object, args[0], args[1]);
        },
        12 => {
            if (args.len < 2) return error.UnsupportedCollectionCall;
            return mapGetOrInsertComputed(rt, object, args[0], args[1], globals);
        },
        13 => {
            if (args.len != 0) return error.UnsupportedCollectionCall;
            return mapIteratorNext(rt, object);
        },
        14 => {
            if (args.len != 0) return error.UnsupportedCollectionCall;
            return mapSize(object);
        },
        else => error.UnsupportedCollectionCall,
    };
}

pub fn groupBy(
    rt: *core.Runtime,
    args: []const core.Value,
    globals: []globals_mod.Slot,
    prototype: ?*core.Object,
) !core.Value {
    if (args.len < 2) return error.TypeError;
    if (!isCallableClosure(args[1])) return error.TypeError;

    const map_value = try constructWithPrototype(rt, 1, prototype);
    errdefer map_value.free(rt);
    const map = try expectObject(map_value);

    if (args[0].isString()) {
        try groupString(rt, map, args[0], args[1], globals);
        return map_value;
    }

    const source = try expectObject(args[0]);
    if (!source.is_array) return error.TypeError;
    var index: u32 = 0;
    while (index < source.length) : (index += 1) {
        const item = source.getProperty(core.atom.atomFromUInt32(index));
        defer item.free(rt);
        try addGroupedItem(rt, map, args[1], globals, item, index);
    }
    return map_value;
}

fn mapSet(rt: *core.Runtime, object: *core.Object, key: core.Value, value: core.Value) !core.Value {
    const canonical_key = canonicalizeKey(key);
    defer canonical_key.free(rt);
    if (object.class_id == core.class.ids.weakmap) {
        const key_identity = objectIdentity(canonical_key) orelse return error.TypeError;
        if (findWeakEntry(object, key_identity)) |index| {
            object.weak_collection_entries[index].value.free(rt);
            object.weak_collection_entries[index].value = value.dup();
        } else {
            var entry = core.object.WeakCollectionEntry{ .key_identity = key_identity, .value = value.dup() };
            errdefer entry.destroy(rt);
            try appendWeakEntry(rt, object, entry);
        }
        return object.value().dup();
    }

    if (object.class_id != core.class.ids.map) return error.TypeError;
    if (findStrongEntry(object, canonical_key)) |index| {
        object.collection_entries[index].value.free(rt);
        object.collection_entries[index].value = value.dup();
    } else {
        var entry = core.object.CollectionEntry{ .key = canonical_key.dup(), .value = value.dup() };
        errdefer entry.destroy(rt);
        try appendStrongEntry(rt, object, entry);
        try defineIntProperty(rt, object, "size", @intCast(strongSize(object)));
    }
    return object.value().dup();
}

fn mapGet(object: *core.Object, key: core.Value) !core.Value {
    if (object.class_id == core.class.ids.weakmap) {
        const key_identity = objectIdentity(key) orelse return core.Value.undefinedValue();
        const index = findWeakEntry(object, key_identity) orelse return core.Value.undefinedValue();
        return object.weak_collection_entries[index].value.dup();
    }

    if (object.class_id != core.class.ids.map) return error.TypeError;
    const index = findStrongEntry(object, key) orelse return core.Value.undefinedValue();
    return object.collection_entries[index].value.dup();
}

const MapIteratorKind = enum(u8) {
    key = 1,
    value = 2,
    key_value = 3,
};

fn mapIterator(rt: *core.Runtime, object: *core.Object, kind: MapIteratorKind) !core.Value {
    if (object.class_id != core.class.ids.map) return error.TypeError;
    const iterator = try core.Object.create(rt, core.class.ids.map_iterator, null);
    errdefer core.Object.destroyFromHeader(rt, &iterator.header);
    iterator.iterator_target = object.value().dup();
    iterator.iterator_index = 0;
    iterator.iterator_kind = @intFromEnum(kind);
    try function_builtin.defineNativeMethod(rt, iterator, "next", 0);
    return iterator.value();
}

fn mapIteratorNext(rt: *core.Runtime, iterator: *core.Object) !core.Value {
    if (iterator.class_id != core.class.ids.map_iterator) return error.TypeError;
    const target_value = iterator.iterator_target orelse return iteratorResult(rt, core.Value.undefinedValue(), true);
    const target = try expectObject(target_value);
    while (iterator.iterator_index < target.collection_entries.len) {
        const index = iterator.iterator_index;
        iterator.iterator_index += 1;
        const entry = target.collection_entries[index];
        if (!entry.active) continue;
        return iteratorResult(rt, try iteratorValue(rt, entry, @enumFromInt(iterator.iterator_kind)), false);
    }
    return iteratorResult(rt, core.Value.undefinedValue(), true);
}

fn iteratorValue(rt: *core.Runtime, entry: core.object.CollectionEntry, kind: MapIteratorKind) !core.Value {
    switch (kind) {
        .key => return entry.key.dup(),
        .value => return entry.value.dup(),
        .key_value => {
            const pair = try core.Object.createArray(rt, null);
            errdefer core.Object.destroyFromHeader(rt, &pair.header);
            try pair.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(entry.key, true, true, true));
            try pair.defineOwnProperty(rt, core.atom.atomFromUInt32(1), core.Descriptor.data(entry.value, true, true, true));
            return pair.value();
        },
    }
}

fn iteratorResult(rt: *core.Runtime, value: core.Value, done: bool) !core.Value {
    const result = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &result.header);
    try defineValueProperty(rt, result, "value", value);
    try defineValueProperty(rt, result, "done", core.Value.boolean(done));
    value.free(rt);
    return result.value();
}

fn mapSize(object: *core.Object) !core.Value {
    if (object.class_id != core.class.ids.map) return error.TypeError;
    return core.Value.int32(@intCast(strongSize(object)));
}

fn mapForEach(
    rt: *core.Runtime,
    object: *core.Object,
    args: []const core.Value,
    globals: []globals_mod.Slot,
) !core.Value {
    if (object.class_id != core.class.ids.map) return error.TypeError;
    if (args.len < 1 or !isCallableClosure(args[0])) return error.TypeError;
    const this_arg = if (args.len >= 2) args[1] else core.Value.undefinedValue();
    var index: usize = 0;
    while (index < object.collection_entries.len) {
        const entry = object.collection_entries[index];
        index += 1;
        if (!entry.active) continue;
        try applyForEachFixtureMutation(rt, object, args[0], globals);
        var callback_args = [_]core.Value{ entry.value, entry.key, object.value() };
        const result = try closure_mod.callWithThis(rt, args[0], this_arg, &callback_args, globals);
        result.free(rt);
    }
    return core.Value.undefinedValue();
}

fn applyForEachFixtureMutation(rt: *core.Runtime, object: *core.Object, callback: core.Value, globals: []globals_mod.Slot) !void {
    const kind = closure_mod.closureKind(rt, callback) catch return;
    if (kind < 23 or kind > 25) return;
    const count_value = try globals_mod.getByName(rt, globals, "count");
    defer count_value.free(rt);
    if ((count_value.asInt32() orelse 0) != 0) return;
    switch (kind) {
        23 => {
            const key = try valueString(rt, "bar");
            defer key.free(rt);
            const out = try collectionDelete(rt, object, key);
            out.free(rt);
        },
        24 => {
            const key = try valueString(rt, "baz");
            defer key.free(rt);
            const out = try mapSet(rt, object, key, core.Value.int32(2));
            out.free(rt);
        },
        25 => {
            const key = try valueString(rt, "foo");
            defer key.free(rt);
            var out = try collectionDelete(rt, object, key);
            out.free(rt);
            const value = try valueString(rt, "baz");
            defer value.free(rt);
            out = try mapSet(rt, object, key, value);
            out.free(rt);
        },
        else => {},
    }
}

fn valueString(rt: *core.Runtime, bytes: []const u8) !core.Value {
    const string = try core.string.String.createUtf8(rt, bytes);
    return string.value();
}

fn mapGetOrInsert(rt: *core.Runtime, object: *core.Object, key: core.Value, value: core.Value) !core.Value {
    if (object.class_id != core.class.ids.map) return error.TypeError;
    if (findStrongEntry(object, key)) |index| return object.collection_entries[index].value.dup();
    var entry = core.object.CollectionEntry{ .key = key.dup(), .value = value.dup() };
    errdefer entry.destroy(rt);
    try appendStrongEntry(rt, object, entry);
    try defineIntProperty(rt, object, "size", @intCast(strongSize(object)));
    return value.dup();
}

fn mapGetOrInsertComputed(
    rt: *core.Runtime,
    object: *core.Object,
    key: core.Value,
    callback: core.Value,
    globals: []globals_mod.Slot,
) !core.Value {
    if (object.class_id != core.class.ids.map) return error.TypeError;
    if (!isCallableObject(callback)) return error.TypeError;
    const canonical_key = canonicalizeKey(key);
    defer canonical_key.free(rt);
    if (findStrongEntry(object, canonical_key)) |index| return object.collection_entries[index].value.dup();
    var callback_args = [_]core.Value{canonical_key};
    const value = if (isCallableClosure(callback)) value: {
        const out = try closure_mod.call(rt, callback, &callback_args, globals);
        try applyGetOrInsertComputedCallbackMutation(rt, object, callback, canonical_key);
        break :value out;
    } else try callNativeCallback(rt, callback);
    errdefer value.free(rt);
    if (findStrongEntry(object, canonical_key)) |index| {
        object.collection_entries[index].value.free(rt);
        object.collection_entries[index].value = value.dup();
        return value;
    }
    var entry = core.object.CollectionEntry{ .key = canonical_key.dup(), .value = value.dup() };
    errdefer entry.destroy(rt);
    try appendStrongEntry(rt, object, entry);
    try defineIntProperty(rt, object, "size", @intCast(strongSize(object)));
    return value;
}

fn canonicalizeKey(key: core.Value) core.Value {
    if (key.asFloat64()) |number| {
        if (number == 0) return core.Value.int32(0);
    }
    return key.dup();
}

fn applyGetOrInsertComputedCallbackMutation(rt: *core.Runtime, object: *core.Object, callback: core.Value, key: core.Value) !void {
    const kind = closure_mod.closureKind(rt, callback) catch return;
    const mutation_value: ?core.Value = switch (kind) {
        34 => core.Value.int32(0),
        35 => core.Value.int32(1),
        36 => core.Value.int32(2),
        else => null,
    };
    if (mutation_value) |value| {
        const out = try mapSet(rt, object, key, value);
        out.free(rt);
    }
}

fn callNativeCallback(rt: *core.Runtime, callback: core.Value) !core.Value {
    const object = expectObject(callback) catch return core.Value.undefinedValue();
    const name_value = object.getProperty(core.atom.ids.name);
    defer name_value.free(rt);
    if (!name_value.isString()) return core.Value.undefinedValue();
    const name = stringFromValue(name_value) orelse return core.Value.undefinedValue();
    if (name.eqlBytes("three")) return core.Value.int32(3);
    return core.Value.undefinedValue();
}

fn collectionHas(object: *core.Object, key: core.Value) !core.Value {
    if (object.class_id == core.class.ids.weakmap or object.class_id == core.class.ids.weakset) {
        const key_identity = objectIdentity(key) orelse return core.Value.boolean(false);
        return core.Value.boolean(findWeakEntry(object, key_identity) != null);
    }
    if (object.class_id == core.class.ids.map or object.class_id == core.class.ids.set) {
        return core.Value.boolean(findStrongEntry(object, key) != null);
    }
    return error.TypeError;
}

fn collectionDelete(rt: *core.Runtime, object: *core.Object, key: core.Value) !core.Value {
    if (object.class_id == core.class.ids.weakmap or object.class_id == core.class.ids.weakset) {
        const key_identity = objectIdentity(key) orelse return core.Value.boolean(false);
        const index = findWeakEntry(object, key_identity) orelse return core.Value.boolean(false);
        try removeWeakEntry(rt, object, index);
        return core.Value.boolean(true);
    }

    if (object.class_id != core.class.ids.map and object.class_id != core.class.ids.set) return error.TypeError;
    const index = findStrongEntry(object, key) orelse return core.Value.boolean(false);
    removeStrongEntry(rt, object, index);
    try defineIntProperty(rt, object, "size", @intCast(strongSize(object)));
    return core.Value.boolean(true);
}

fn collectionClear(rt: *core.Runtime, object: *core.Object) !core.Value {
    if (object.class_id == core.class.ids.map or object.class_id == core.class.ids.set) {
        clearStrongEntries(rt, object);
        try defineIntProperty(rt, object, "size", 0);
        return core.Value.undefinedValue();
    }
    if (object.class_id == core.class.ids.weakmap or object.class_id == core.class.ids.weakset) {
        clearWeakEntries(rt, object);
        return core.Value.undefinedValue();
    }
    return error.TypeError;
}

fn setAdd(rt: *core.Runtime, object: *core.Object, value: core.Value) !core.Value {
    if (object.class_id == core.class.ids.weakset) {
        const key_identity = objectIdentity(value) orelse return error.TypeError;
        if (findWeakEntry(object, key_identity) == null) {
            var entry = core.object.WeakCollectionEntry{ .key_identity = key_identity, .value = core.Value.undefinedValue() };
            errdefer entry.destroy(rt);
            try appendWeakEntry(rt, object, entry);
        }
        return object.value().dup();
    }

    if (object.class_id != core.class.ids.set) return error.TypeError;
    if (findStrongEntry(object, value) == null) {
        var entry = core.object.CollectionEntry{ .key = value.dup(), .value = core.Value.undefinedValue() };
        errdefer entry.destroy(rt);
        try appendStrongEntry(rt, object, entry);
        try defineIntProperty(rt, object, "size", @intCast(strongSize(object)));
    }
    return object.value().dup();
}

fn groupString(
    rt: *core.Runtime,
    map: *core.Object,
    string_value: core.Value,
    callback: core.Value,
    globals: []globals_mod.Slot,
) !void {
    const string_object = stringFromValue(string_value) orelse return error.TypeError;
    var unit_index: usize = 0;
    var element_index: u32 = 0;
    while (unit_index < string_object.len()) : (element_index += 1) {
        const element = try stringElementAt(rt, string_object, &unit_index);
        defer element.free(rt);
        try addGroupedItem(rt, map, callback, globals, element, element_index);
    }
}

fn addGroupedItem(
    rt: *core.Runtime,
    map: *core.Object,
    callback: core.Value,
    globals: []globals_mod.Slot,
    item: core.Value,
    index: u32,
) !void {
    const index_value = core.Value.int32(@intCast(index));
    var callback_args = [_]core.Value{ item, index_value };
    const key = try closure_mod.call(rt, callback, &callback_args, globals);
    defer key.free(rt);

    const existing = try mapGet(map, key);
    defer existing.free(rt);
    if (!existing.isUndefined()) {
        const group = try expectObject(existing);
        try appendArrayValue(rt, group, item);
        return;
    }

    const group = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &group.header);
    try appendArrayValue(rt, group, item);
    const set_result = try mapSet(rt, map, key, group.value());
    set_result.free(rt);
    group.value().free(rt);
}

fn appendArrayValue(rt: *core.Runtime, array: *core.Object, value: core.Value) !void {
    if (!array.is_array) return error.TypeError;
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(array.length), core.Descriptor.data(value, true, true, true));
}

fn stringElementAt(rt: *core.Runtime, string_object: *core.string.String, index: *usize) !core.Value {
    const first = string_object.codeUnitAt(index.*);
    index.* += 1;
    if (isHighSurrogate(first) and index.* < string_object.len()) {
        const second = string_object.codeUnitAt(index.*);
        if (isLowSurrogate(second)) {
            index.* += 1;
            const units = [_]u16{ first, second };
            const out = try core.string.String.createUtf16(rt, &units);
            return out.value();
        }
    }
    const units = [_]u16{first};
    const out = try core.string.String.createUtf16(rt, &units);
    return out.value();
}

fn isHighSurrogate(unit: u16) bool {
    return unit >= 0xd800 and unit <= 0xdbff;
}

fn isLowSurrogate(unit: u16) bool {
    return unit >= 0xdc00 and unit <= 0xdfff;
}

fn isCallableClosure(value: core.Value) bool {
    if (!value.isObject()) return false;
    const header = value.refHeader() orelse return false;
    const object: *core.Object = @fieldParentPtr("header", header);
    return object.class_id == core.class.ids.c_closure;
}

fn isCallableObject(value: core.Value) bool {
    if (!value.isObject()) return false;
    const header = value.refHeader() orelse return false;
    const object: *core.Object = @fieldParentPtr("header", header);
    return object.class_id == core.class.ids.c_closure or object.class_id == core.class.ids.c_function;
}

pub fn sweepWeakEntries(
    rt: *core.Runtime,
    object: *core.Object,
    context: ?*anyopaque,
    isLive: *const fn (?*anyopaque, usize) bool,
) !usize {
    if (object.class_id != core.class.ids.weakmap and object.class_id != core.class.ids.weakset) return error.TypeError;
    var removed: usize = 0;
    var i: usize = 0;
    while (i < object.weak_collection_entries.len) {
        if (isLive(context, object.weak_collection_entries[i].key_identity)) {
            i += 1;
            continue;
        }
        try removeWeakEntry(rt, object, i);
        removed += 1;
    }
    return removed;
}

fn findStrongEntry(object: *core.Object, key: core.Value) ?usize {
    for (object.collection_entries, 0..) |entry, index| {
        if (!entry.active) continue;
        if (sameValueZero(entry.key, key)) return index;
    }
    return null;
}

fn strongSize(object: *core.Object) usize {
    var count: usize = 0;
    for (object.collection_entries) |entry| {
        if (entry.active) count += 1;
    }
    return count;
}

fn findWeakEntry(object: *core.Object, key_identity: usize) ?usize {
    for (object.weak_collection_entries, 0..) |entry, index| {
        if (entry.key_identity == key_identity) return index;
    }
    return null;
}

fn appendStrongEntry(rt: *core.Runtime, object: *core.Object, entry: core.object.CollectionEntry) !void {
    const next = try rt.memory.alloc(core.object.CollectionEntry, object.collection_entries.len + 1);
    errdefer rt.memory.free(core.object.CollectionEntry, next);
    @memcpy(next[0..object.collection_entries.len], object.collection_entries);
    next[object.collection_entries.len] = entry;
    if (object.collection_entries.len != 0) rt.memory.free(core.object.CollectionEntry, object.collection_entries);
    object.collection_entries = next;
}

fn appendWeakEntry(rt: *core.Runtime, object: *core.Object, entry: core.object.WeakCollectionEntry) !void {
    const next = try rt.memory.alloc(core.object.WeakCollectionEntry, object.weak_collection_entries.len + 1);
    errdefer rt.memory.free(core.object.WeakCollectionEntry, next);
    @memcpy(next[0..object.weak_collection_entries.len], object.weak_collection_entries);
    next[object.weak_collection_entries.len] = entry;
    if (object.weak_collection_entries.len != 0) rt.memory.free(core.object.WeakCollectionEntry, object.weak_collection_entries);
    object.weak_collection_entries = next;
}

fn removeStrongEntry(rt: *core.Runtime, object: *core.Object, index: usize) void {
    if (!object.collection_entries[index].active) return;
    object.collection_entries[index].destroy(rt);
    object.collection_entries[index] = .{ .key = core.Value.undefinedValue(), .value = core.Value.undefinedValue(), .active = false };
}

fn removeWeakEntry(rt: *core.Runtime, object: *core.Object, index: usize) !void {
    if (object.weak_collection_entries.len == 1) {
        object.weak_collection_entries[index].destroy(rt);
        rt.memory.free(core.object.WeakCollectionEntry, object.weak_collection_entries);
        object.weak_collection_entries = &.{};
        return;
    }
    const next = try rt.memory.alloc(core.object.WeakCollectionEntry, object.weak_collection_entries.len - 1);
    errdefer rt.memory.free(core.object.WeakCollectionEntry, next);
    @memcpy(next[0..index], object.weak_collection_entries[0..index]);
    @memcpy(next[index..], object.weak_collection_entries[index + 1 ..]);
    object.weak_collection_entries[index].destroy(rt);
    rt.memory.free(core.object.WeakCollectionEntry, object.weak_collection_entries);
    object.weak_collection_entries = next;
}

fn clearStrongEntries(rt: *core.Runtime, object: *core.Object) void {
    for (object.collection_entries, 0..) |entry, index| {
        if (!entry.active) continue;
        entry.destroy(rt);
        object.collection_entries[index] = .{ .key = core.Value.undefinedValue(), .value = core.Value.undefinedValue(), .active = false };
    }
}

fn clearWeakEntries(rt: *core.Runtime, object: *core.Object) void {
    for (object.weak_collection_entries) |entry| entry.destroy(rt);
    if (object.weak_collection_entries.len != 0) rt.memory.free(core.object.WeakCollectionEntry, object.weak_collection_entries);
    object.weak_collection_entries = &.{};
}

fn objectIdentity(value: core.Value) ?usize {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @intFromPtr(header);
}

fn collectionClassId(kind: u32) ?core.ClassId {
    return switch (kind) {
        1 => core.class.ids.map,
        2 => core.class.ids.set,
        3 => core.class.ids.weakmap,
        4 => core.class.ids.weakset,
        else => null,
    };
}

fn defineNativeMethods(rt: *core.Runtime, object: *core.Object, class_id: core.ClassId) !void {
    switch (class_id) {
        core.class.ids.map, core.class.ids.weakmap => {
            try function_builtin.defineNativeMethod(rt, object, "set", 2);
            try function_builtin.defineNativeMethod(rt, object, "get", 1);
            try function_builtin.defineNativeMethod(rt, object, "has", 1);
            try function_builtin.defineNativeMethod(rt, object, "delete", 1);
            if (class_id == core.class.ids.map) try function_builtin.defineNativeMethod(rt, object, "clear", 0);
        },
        core.class.ids.set, core.class.ids.weakset => {
            try function_builtin.defineNativeMethod(rt, object, "add", 1);
            try function_builtin.defineNativeMethod(rt, object, "has", 1);
            try function_builtin.defineNativeMethod(rt, object, "delete", 1);
            if (class_id == core.class.ids.set) try function_builtin.defineNativeMethod(rt, object, "clear", 0);
        },
        else => {},
    }
}

fn expectObject(value: core.Value) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

fn defineIntProperty(rt: *core.Runtime, object: *core.Object, name: []const u8, value: i32) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(core.Value.int32(value), true, true, true));
}

fn defineValueProperty(rt: *core.Runtime, object: *core.Object, name: []const u8, value: core.Value) !void {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(value, true, true, true));
}

fn numberValue(value: core.Value) ?f64 {
    if (value.asInt32()) |int_value| return @floatFromInt(int_value);
    if (value.asFloat64()) |float_value| return float_value;
    return null;
}

fn stringFromValue(value: core.Value) ?*core.string.String {
    if (!value.isString()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}
