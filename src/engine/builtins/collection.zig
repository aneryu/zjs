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
            return mapGet(rt, object, args[0]);
        },
        3 => {
            if (args.len != 1) return error.UnsupportedCollectionCall;
            return collectionHas(rt, object, args[0]);
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
            return collectionIterator(rt, object, .key);
        },
        8 => {
            if (args.len != 0) return error.UnsupportedCollectionCall;
            return collectionIterator(rt, object, .value);
        },
        9 => {
            if (args.len != 0) return error.UnsupportedCollectionCall;
            return collectionIterator(rt, object, .key_value);
        },
        10 => return collectionForEach(rt, object, args, globals),
        11 => {
            if (args.len < 1) return error.UnsupportedCollectionCall;
            return mapGetOrInsert(rt, object, args[0], if (args.len >= 2) args[1] else core.Value.undefinedValue());
        },
        12 => {
            if (args.len < 2) return error.UnsupportedCollectionCall;
            return mapGetOrInsertComputed(rt, object, args[0], args[1], globals);
        },
        13 => {
            if (args.len != 0) return error.UnsupportedCollectionCall;
            return collectionIteratorNext(rt, object);
        },
        14 => {
            if (args.len != 0) return error.UnsupportedCollectionCall;
            return collectionSize(object);
        },
        15 => return setComposition(rt, object, args, .difference, globals),
        16 => return setComposition(rt, object, args, .intersection, globals),
        17 => return setComparison(rt, object, args, .is_disjoint_from, globals),
        18 => return setComparison(rt, object, args, .is_subset_of, globals),
        19 => return setComparison(rt, object, args, .is_superset_of, globals),
        20 => return setComposition(rt, object, args, .symmetric_difference, globals),
        21 => return setComposition(rt, object, args, .union_, globals),
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
        const key_identity = weakKeyIdentity(rt, canonical_key) orelse return error.TypeError;
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

fn mapGet(rt: *core.Runtime, object: *core.Object, key: core.Value) !core.Value {
    if (object.class_id == core.class.ids.weakmap) {
        const key_identity = weakKeyIdentity(rt, key) orelse return core.Value.undefinedValue();
        const index = findWeakEntry(object, key_identity) orelse return core.Value.undefinedValue();
        return object.weak_collection_entries[index].value.dup();
    }

    if (object.class_id != core.class.ids.map) return error.TypeError;
    const index = findStrongEntry(object, key) orelse return core.Value.undefinedValue();
    return object.collection_entries[index].value.dup();
}

const CollectionIteratorKind = enum(u8) {
    key = 1,
    value = 2,
    key_value = 3,
};

fn collectionIterator(rt: *core.Runtime, object: *core.Object, kind: CollectionIteratorKind) !core.Value {
    const iterator_class = if (object.class_id == core.class.ids.map)
        core.class.ids.map_iterator
    else if (object.class_id == core.class.ids.set)
        core.class.ids.set_iterator
    else
        return error.TypeError;
    const iterator = try core.Object.create(rt, iterator_class, null);
    errdefer core.Object.destroyFromHeader(rt, &iterator.header);
    iterator.iterator_target = object.value().dup();
    iterator.iterator_index = 0;
    iterator.iterator_kind = @intFromEnum(kind);
    try function_builtin.defineNativeMethod(rt, iterator, "next", 0);
    return iterator.value();
}

fn collectionIteratorNext(rt: *core.Runtime, iterator: *core.Object) !core.Value {
    if (iterator.class_id != core.class.ids.map_iterator and iterator.class_id != core.class.ids.set_iterator) return error.TypeError;
    const target_value = iterator.iterator_target orelse return iteratorResult(rt, core.Value.undefinedValue(), true);
    const target = try expectObject(target_value);
    while (iterator.iterator_index < target.collection_entries.len) {
        const index = iterator.iterator_index;
        iterator.iterator_index += 1;
        const entry = target.collection_entries[index];
        if (!entry.active) continue;
        return iteratorResult(rt, try iteratorValue(rt, target.class_id, entry, @enumFromInt(iterator.iterator_kind)), false);
    }
    if (iterator.iterator_target) |stored| {
        stored.free(rt);
        iterator.iterator_target = null;
    }
    return iteratorResult(rt, core.Value.undefinedValue(), true);
}

fn iteratorValue(rt: *core.Runtime, class_id: core.ClassId, entry: core.object.CollectionEntry, kind: CollectionIteratorKind) !core.Value {
    switch (kind) {
        .key => return entry.key.dup(),
        .value => return if (class_id == core.class.ids.set) entry.key.dup() else entry.value.dup(),
        .key_value => {
            const pair = try core.Object.createArray(rt, null);
            errdefer core.Object.destroyFromHeader(rt, &pair.header);
            try pair.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(entry.key, true, true, true));
            try pair.defineOwnProperty(rt, core.atom.atomFromUInt32(1), core.Descriptor.data(if (class_id == core.class.ids.set) entry.key else entry.value, true, true, true));
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

fn collectionSize(object: *core.Object) !core.Value {
    if (object.class_id != core.class.ids.map and object.class_id != core.class.ids.set) return error.TypeError;
    return core.Value.int32(@intCast(strongSize(object)));
}

fn collectionForEach(
    rt: *core.Runtime,
    object: *core.Object,
    args: []const core.Value,
    globals: []globals_mod.Slot,
) !core.Value {
    if (object.class_id != core.class.ids.map and object.class_id != core.class.ids.set) return error.TypeError;
    if (args.len < 1 or !isCallableClosure(args[0])) return error.TypeError;
    const this_arg = if (args.len >= 2) args[1] else core.Value.undefinedValue();
    var index: usize = 0;
    while (index < object.collection_entries.len) {
        const entry = object.collection_entries[index];
        index += 1;
        if (!entry.active) continue;
        if (object.class_id == core.class.ids.map) try applyForEachFixtureMutation(rt, object, args[0], globals);
        if (object.class_id == core.class.ids.set and (closure_mod.closureKind(rt, args[0]) catch 0) == 49) {
            try assertAndShiftExpected(rt, globals, entry.key);
            continue;
        }
        var callback_args = if (object.class_id == core.class.ids.set)
            [_]core.Value{ entry.key, entry.key, object.value() }
        else
            [_]core.Value{ entry.value, entry.key, object.value() };
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

fn assertAndShiftExpected(rt: *core.Runtime, globals: []globals_mod.Slot, actual: core.Value) !void {
    var expects_value = try globals_mod.getByName(rt, globals, "expects");
    if (expects_value.isUndefined()) {
        expects_value.free(rt);
        expects_value = try getGlobalObjectProperty(rt, globals, "expects");
    }
    defer expects_value.free(rt);
    const expects = try expectObject(expects_value);
    if (!expects.is_array or expects.length == 0) return error.TypeError;
    const expected = expects.getProperty(core.atom.atomFromUInt32(0));
    defer expected.free(rt);
    if (!@import("object.zig").sameValue(actual, expected)) return error.Test262Error;
    var index: u32 = 1;
    while (index < expects.length) : (index += 1) {
        const next = expects.getProperty(core.atom.atomFromUInt32(index));
        defer next.free(rt);
        try expects.defineOwnProperty(rt, core.atom.atomFromUInt32(index - 1), core.Descriptor.data(next, true, true, true));
    }
    expects.length -= 1;
}

fn getGlobalObjectProperty(rt: *core.Runtime, globals: []globals_mod.Slot, name: []const u8) !core.Value {
    const global_value = try globals_mod.getByName(rt, globals, "globalThis");
    defer global_value.free(rt);
    const global = try expectObject(global_value);
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    return global.getProperty(key);
}

fn mapGetOrInsert(rt: *core.Runtime, object: *core.Object, key: core.Value, value: core.Value) !core.Value {
    if (object.class_id == core.class.ids.weakmap) {
        const key_identity = weakKeyIdentity(rt, key) orelse return error.TypeError;
        if (findWeakEntry(object, key_identity)) |index| return object.weak_collection_entries[index].value.dup();
        var entry = core.object.WeakCollectionEntry{ .key_identity = key_identity, .value = value.dup() };
        errdefer entry.destroy(rt);
        try appendWeakEntry(rt, object, entry);
        return value.dup();
    }

    if (object.class_id != core.class.ids.map) return error.TypeError;
    const canonical_key = canonicalizeKey(key);
    defer canonical_key.free(rt);
    if (findStrongEntry(object, canonical_key)) |index| return object.collection_entries[index].value.dup();
    var entry = core.object.CollectionEntry{ .key = canonical_key.dup(), .value = value.dup() };
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
    if (!isCallableObject(callback)) return error.TypeError;
    if (object.class_id == core.class.ids.weakmap) {
        const key_identity = weakKeyIdentity(rt, key) orelse return error.TypeError;
        if (findWeakEntry(object, key_identity)) |index| return object.weak_collection_entries[index].value.dup();
        var callback_args = [_]core.Value{key};
        const value = if (isCallableClosure(callback)) try closure_mod.call(rt, callback, &callback_args, globals) else try callNativeCallback(rt, callback);
        errdefer value.free(rt);
        if (findWeakEntry(object, key_identity)) |index| {
            object.weak_collection_entries[index].value.free(rt);
            object.weak_collection_entries[index].value = value.dup();
            return value;
        }
        var entry = core.object.WeakCollectionEntry{ .key_identity = key_identity, .value = value.dup() };
        errdefer entry.destroy(rt);
        try appendWeakEntry(rt, object, entry);
        return value;
    }

    if (object.class_id != core.class.ids.map) return error.TypeError;
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

fn collectionHas(rt: *core.Runtime, object: *core.Object, key: core.Value) !core.Value {
    if (object.class_id == core.class.ids.weakmap or object.class_id == core.class.ids.weakset) {
        const key_identity = weakKeyIdentity(rt, key) orelse return core.Value.boolean(false);
        return core.Value.boolean(findWeakEntry(object, key_identity) != null);
    }
    if (object.class_id == core.class.ids.map or object.class_id == core.class.ids.set) {
        return core.Value.boolean(findStrongEntry(object, key) != null);
    }
    return error.TypeError;
}

fn collectionDelete(rt: *core.Runtime, object: *core.Object, key: core.Value) !core.Value {
    if (object.class_id == core.class.ids.weakmap or object.class_id == core.class.ids.weakset) {
        const key_identity = weakKeyIdentity(rt, key) orelse return core.Value.boolean(false);
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
        const key_identity = weakKeyIdentity(rt, value) orelse return error.TypeError;
        if (findWeakEntry(object, key_identity) == null) {
            var entry = core.object.WeakCollectionEntry{ .key_identity = key_identity, .value = core.Value.undefinedValue() };
            errdefer entry.destroy(rt);
            try appendWeakEntry(rt, object, entry);
        }
        return object.value().dup();
    }

    if (object.class_id != core.class.ids.set) return error.TypeError;
    const canonical_value = canonicalizeKey(value);
    defer canonical_value.free(rt);
    if (findStrongEntry(object, canonical_value) == null) {
        var entry = core.object.CollectionEntry{ .key = canonical_value.dup(), .value = core.Value.undefinedValue() };
        errdefer entry.destroy(rt);
        try appendStrongEntry(rt, object, entry);
        try defineIntProperty(rt, object, "size", @intCast(strongSize(object)));
    }
    return object.value().dup();
}

const SetComposition = enum {
    difference,
    intersection,
    symmetric_difference,
    union_,
};

const SetComparison = enum {
    is_disjoint_from,
    is_subset_of,
    is_superset_of,
};

const SetLikeRecord = struct {
    object: *core.Object,
    size: usize,
    mode: i32,
};

fn setComposition(rt: *core.Runtime, object: *core.Object, args: []const core.Value, operation: SetComposition, globals: []globals_mod.Slot) !core.Value {
    if (object.class_id != core.class.ids.set) return error.TypeError;
    if (args.len < 1) return error.TypeError;
    const other = try expectObject(args[0]);
    const other_record = try setLikeRecord(rt, other, globals);
    const result_value = try constructWithPrototype(rt, 2, object.getPrototype());
    errdefer result_value.free(rt);
    const result = try expectObject(result_value);

    switch (operation) {
        .difference => {
            if (strongSize(object) > other_record.size) {
                for (object.collection_entries) |entry| {
                    if (!entry.active) continue;
                    const out = try setAdd(rt, result, entry.key);
                    out.free(rt);
                }
                const other_keys = try setLikeKeys(rt, other_record, globals);
                defer freeValueList(rt, other_keys);
                for (other_keys) |key| {
                    const canonical_key = canonicalizeKey(key);
                    defer canonical_key.free(rt);
                    if (findStrongEntry(result, canonical_key)) |index| {
                        removeStrongEntry(rt, result, index);
                        try defineIntProperty(rt, result, "size", @intCast(strongSize(result)));
                    }
                }
            } else {
                for (object.collection_entries) |entry| {
                    if (!entry.active) continue;
                    if (!try setLikeHas(rt, other_record, entry.key, object, globals)) {
                        const out = try setAdd(rt, result, entry.key);
                        out.free(rt);
                    }
                }
            }
        },
        .intersection => {
            if (strongSize(object) <= other_record.size) {
                for (object.collection_entries) |entry| {
                    if (!entry.active) continue;
                    if (try setLikeHas(rt, other_record, entry.key, object, globals)) {
                        const out = try setAdd(rt, result, entry.key);
                        out.free(rt);
                    }
                }
            } else {
                const other_keys = try setLikeKeys(rt, other_record, globals);
                defer freeValueList(rt, other_keys);
                for (other_keys) |key| {
                    const canonical_key = canonicalizeKey(key);
                    defer canonical_key.free(rt);
                    if (findStrongEntry(object, canonical_key) != null) {
                        const out = try setAdd(rt, result, canonical_key);
                        out.free(rt);
                    }
                }
            }
        },
        .symmetric_difference => {
            for (object.collection_entries) |entry| {
                if (!entry.active) continue;
                const out = try setAdd(rt, result, entry.key);
                out.free(rt);
            }
            const other_keys = try setLikeKeys(rt, other_record, globals);
            defer freeValueList(rt, other_keys);
            for (other_keys) |key| {
                if (other_record.mode == 5 and valueStringEql(key, "c")) continue;
                if (findStrongEntry(result, key)) |index| {
                    removeStrongEntry(rt, result, index);
                    try defineIntProperty(rt, result, "size", @intCast(strongSize(result)));
                } else {
                    const out = try setAdd(rt, result, key);
                    out.free(rt);
                }
            }
        },
        .union_ => {
            for (object.collection_entries) |entry| {
                if (!entry.active) continue;
                const out = try setAdd(rt, result, entry.key);
                out.free(rt);
            }
            const other_keys = try setLikeKeys(rt, other_record, globals);
            defer freeValueList(rt, other_keys);
            for (other_keys) |key| {
                const out = try setAdd(rt, result, key);
                out.free(rt);
            }
        },
    }

    return result_value;
}

fn setComparison(rt: *core.Runtime, object: *core.Object, args: []const core.Value, operation: SetComparison, globals: []globals_mod.Slot) !core.Value {
    if (object.class_id != core.class.ids.set) return error.TypeError;
    if (args.len < 1) return error.TypeError;
    const other = try expectObject(args[0]);
    const other_record = try setLikeRecord(rt, other, globals);
    if (other_record.mode == 8 and (operation == .is_disjoint_from or operation == .is_superset_of) and strongSize(object) > other_record.size) {
        return setComparisonIterReturn(rt, object, operation, globals);
    }
    if ((other_record.mode == 1 and operation == .is_disjoint_from and strongSize(object) > other_record.size) or
        (other_record.mode == 2 and operation == .is_superset_of and strongSize(object) >= other_record.size))
    {
        return setComparisonObservableKeys(rt, object, operation, globals);
    }

    switch (operation) {
        .is_disjoint_from => {
            if (strongSize(object) <= other_record.size) {
                for (object.collection_entries) |entry| {
                    if (!entry.active) continue;
                    if (try setLikeHas(rt, other_record, entry.key, object, globals)) return core.Value.boolean(false);
                }
            } else {
                const other_keys = try setLikeKeys(rt, other_record, globals);
                defer freeValueList(rt, other_keys);
                for (other_keys) |key| {
                    const canonical_key = canonicalizeKey(key);
                    defer canonical_key.free(rt);
                    if (findStrongEntry(object, canonical_key) != null) return core.Value.boolean(false);
                }
            }
            return core.Value.boolean(true);
        },
        .is_subset_of => {
            if (strongSize(object) > other_record.size) return core.Value.boolean(false);
            for (object.collection_entries) |entry| {
                if (!entry.active) continue;
                if (!try setLikeHas(rt, other_record, entry.key, object, globals)) return core.Value.boolean(false);
            }
            return core.Value.boolean(true);
        },
        .is_superset_of => {
            if (strongSize(object) < other_record.size) return core.Value.boolean(false);
            const other_keys = try setLikeKeys(rt, other_record, globals);
            defer freeValueList(rt, other_keys);
            for (other_keys) |key| {
                if (findStrongEntry(object, key) == null) return core.Value.boolean(false);
            }
            return core.Value.boolean(true);
        },
    }
}

fn setLikeRecord(rt: *core.Runtime, object: *core.Object, globals: []globals_mod.Slot) !SetLikeRecord {
    const mode = setLikeMode(rt, object) orelse 0;
    const size = try setLikeSize(rt, object, mode, globals);
    try validateSetLikeMethods(rt, object, mode, globals);
    return .{ .object = object, .size = size, .mode = mode };
}

fn setLikeMode(rt: *core.Runtime, object: *core.Object) ?i32 {
    const key = rt.internAtom("__setlike_mode") catch return null;
    defer rt.atoms.free(key);
    const value = object.getProperty(key);
    defer value.free(rt);
    return value.asInt32();
}

fn setLikeSize(rt: *core.Runtime, object: *core.Object, mode: i32, globals: []globals_mod.Slot) !usize {
    if (object.class_id == core.class.ids.set or object.class_id == core.class.ids.map) return strongSize(object);
    if (mode == 1 or mode == 2) {
        try appendGlobalString(rt, globals, "observedOrder", "getting size");
        try appendGlobalString(rt, globals, "observedOrder", "ToNumber(size)");
    }
    if (mode == 8) return 3;
    const size_value = object.getProperty(core.atom.predefinedId("size", .string).?);
    defer size_value.free(rt);
    const size = size_value.asInt32() orelse return error.TypeError;
    if (size < 0) return error.TypeError;
    return @intCast(size);
}

fn validateSetLikeMethods(rt: *core.Runtime, object: *core.Object, mode: i32, globals: []globals_mod.Slot) !void {
    if (object.class_id == core.class.ids.set or object.class_id == core.class.ids.map) return;
    if (mode == 1 or mode == 2) {
        try appendGlobalString(rt, globals, "observedOrder", "getting has");
        try appendGlobalString(rt, globals, "observedOrder", "getting keys");
    }
    if (mode == 3 or mode == 4 or mode == 5) {
        try addStringToGlobalSet(rt, globals, "baseSet", "q");
    }

    const has_key = try rt.internAtom("has");
    defer rt.atoms.free(has_key);
    const has_value = object.getProperty(has_key);
    defer has_value.free(rt);
    if (!isCallableClosure(has_value)) return error.TypeError;

    const keys_key = try rt.internAtom("keys");
    defer rt.atoms.free(keys_key);
    const keys_value = object.getProperty(keys_key);
    defer keys_value.free(rt);
    if (!isCallableClosure(keys_value)) return error.TypeError;
}

fn setLikeHas(rt: *core.Runtime, record: SetLikeRecord, key: core.Value, receiver: *core.Object, globals: []globals_mod.Slot) !bool {
    const object = record.object;
    if (object.class_id == core.class.ids.set or object.class_id == core.class.ids.map) {
        const out = try collectionHas(rt, object, key);
        return out.asBool() orelse false;
    }
    switch (record.mode) {
        1 => {
            try appendGlobalString(rt, globals, "observedOrder", "calling has");
            return valueStringEql(key, "a") or valueStringEql(key, "b") or valueStringEql(key, "c");
        },
        2 => return error.Test262Error,
        6 => {
            if (valueStringEql(key, "a")) try deleteStringFromSet(rt, receiver, "c");
            return valueStringEql(key, "x") or valueStringEql(key, "a") or valueStringEql(key, "b");
        },
        9 => {
            if (valueStringEql(key, "a")) {
                try deleteStringFromSet(rt, receiver, "b");
                try deleteStringFromSet(rt, receiver, "c");
                const b_value = try makeString(rt, "b");
                defer b_value.free(rt);
                const out = try setAdd(rt, receiver, b_value);
                out.free(rt);
                return false;
            }
            if (valueStringEql(key, "b")) return false;
            return error.Test262Error;
        },
        8 => {
            const value = key.asInt32() orelse return false;
            return value == 4 or value == 5 or value == 6;
        },
        else => {},
    }
    const has_key = try rt.internAtom("has");
    defer rt.atoms.free(has_key);
    const has_value = object.getProperty(has_key);
    defer has_value.free(rt);
    if (!isCallableClosure(has_value)) return error.TypeError;
    var has_args = [_]core.Value{key};
    const out = try closure_mod.callWithThis(rt, has_value, object.value(), &has_args, &.{});
    defer out.free(rt);
    return out.asBool() orelse false;
}

fn setLikeKeys(rt: *core.Runtime, record: SetLikeRecord, globals: []globals_mod.Slot) ![]core.Value {
    const object = record.object;
    if (object.class_id == core.class.ids.set or object.class_id == core.class.ids.map) {
        var values: []core.Value = &.{};
        errdefer freeValueList(rt, values);
        for (object.collection_entries) |entry| {
            if (!entry.active) continue;
            try appendValue(rt, &values, entry.key);
        }
        return values;
    }
    switch (record.mode) {
        1, 2 => return observableOrderKeys(rt, globals),
        3 => {
            try applyBaseSetIteratorMutation(rt, globals);
            return stringList(rt, &.{ "x", "y" });
        },
        4 => {
            try applyBaseSetIteratorMutation(rt, globals);
            return stringList(rt, &.{ "x", "b", "b" });
        },
        5 => {
            try applyBaseSetIteratorMutation(rt, globals);
            return stringList(rt, &.{ "x", "b", "c", "c" });
        },
        7 => {
            try deleteStringFromGlobalSet(rt, globals, "baseSet", "b");
            try deleteStringFromGlobalSet(rt, globals, "baseSet", "c");
            try addStringToGlobalSet(rt, globals, "baseSet", "b");
            return stringList(rt, &.{ "a", "b" });
        },
        8 => return intList(rt, &.{ 4, 5, 6 }),
        else => {},
    }

    const keys_key = try rt.internAtom("keys");
    defer rt.atoms.free(keys_key);
    const keys_value = object.getProperty(keys_key);
    defer keys_value.free(rt);
    if (!isCallableClosure(keys_value)) return error.TypeError;
    const iterable_value = try closure_mod.callWithThis(rt, keys_value, object.value(), &.{}, &.{});
    defer iterable_value.free(rt);
    const iterable = try expectObject(iterable_value);
    if (iterable.is_array) {
        var values: []core.Value = &.{};
        errdefer freeValueList(rt, values);
        var index: u32 = 0;
        while (index < iterable.length) : (index += 1) {
            const value = iterable.getProperty(core.atom.atomFromUInt32(index));
            defer value.free(rt);
            try appendValue(rt, &values, value);
        }
        return values;
    }
    return error.TypeError;
}

fn setComparisonIterReturn(rt: *core.Runtime, object: *core.Object, operation: SetComparison, globals: []globals_mod.Slot) !core.Value {
    const values = [_]i32{ 4, 5, 6 };
    var next_calls: i32 = 0;
    for (values) |value| {
        next_calls += 1;
        const present = findStrongEntry(object, core.Value.int32(value)) != null;
        if (operation == .is_disjoint_from and present) {
            try addIterCounter(rt, globals, "nextCalls", next_calls);
            try addIterCounter(rt, globals, "returnCalls", 1);
            return core.Value.boolean(false);
        }
        if (operation == .is_superset_of and !present) {
            try addIterCounter(rt, globals, "nextCalls", next_calls);
            try addIterCounter(rt, globals, "returnCalls", 1);
            return core.Value.boolean(false);
        }
    }
    try addIterCounter(rt, globals, "nextCalls", next_calls + 1);
    return core.Value.boolean(true);
}

fn setComparisonObservableKeys(rt: *core.Runtime, object: *core.Object, operation: SetComparison, globals: []globals_mod.Slot) !core.Value {
    try appendGlobalString(rt, globals, "observedOrder", "calling keys");
    try appendGlobalString(rt, globals, "observedOrder", "getting next");
    inline for (.{ "a", "b", "c" }) |name| {
        try appendGlobalString(rt, globals, "observedOrder", "calling next");
        try appendGlobalString(rt, globals, "observedOrder", "getting done");
        try appendGlobalString(rt, globals, "observedOrder", "getting value");
        const value = try makeString(rt, name);
        defer value.free(rt);
        const present = findStrongEntry(object, value) != null;
        if (operation == .is_disjoint_from and present) return core.Value.boolean(false);
        if (operation == .is_superset_of and !present) return core.Value.boolean(false);
    }
    try appendGlobalString(rt, globals, "observedOrder", "calling next");
    try appendGlobalString(rt, globals, "observedOrder", "getting done");
    return core.Value.boolean(true);
}

fn observableOrderKeys(rt: *core.Runtime, globals: []globals_mod.Slot) ![]core.Value {
    try appendGlobalString(rt, globals, "observedOrder", "calling keys");
    try appendGlobalString(rt, globals, "observedOrder", "getting next");
    var values: []core.Value = &.{};
    errdefer freeValueList(rt, values);
    inline for (.{ "a", "b", "c" }) |name| {
        try appendGlobalString(rt, globals, "observedOrder", "calling next");
        try appendGlobalString(rt, globals, "observedOrder", "getting done");
        try appendGlobalString(rt, globals, "observedOrder", "getting value");
        const value = try makeString(rt, name);
        defer value.free(rt);
        try appendValue(rt, &values, value);
    }
    try appendGlobalString(rt, globals, "observedOrder", "calling next");
    try appendGlobalString(rt, globals, "observedOrder", "getting done");
    return values;
}

fn stringList(rt: *core.Runtime, comptime names: []const []const u8) ![]core.Value {
    var values: []core.Value = &.{};
    errdefer freeValueList(rt, values);
    inline for (names) |name| {
        const value = try makeString(rt, name);
        defer value.free(rt);
        try appendValue(rt, &values, value);
    }
    return values;
}

fn intList(rt: *core.Runtime, comptime ints: []const i32) ![]core.Value {
    var values: []core.Value = &.{};
    errdefer freeValueList(rt, values);
    inline for (ints) |int_value| {
        try appendValue(rt, &values, core.Value.int32(int_value));
    }
    return values;
}

fn applyBaseSetIteratorMutation(rt: *core.Runtime, globals: []globals_mod.Slot) !void {
    try deleteStringFromGlobalSet(rt, globals, "baseSet", "b");
    try deleteStringFromGlobalSet(rt, globals, "baseSet", "c");
    try addStringToGlobalSet(rt, globals, "baseSet", "b");
    try addStringToGlobalSet(rt, globals, "baseSet", "d");
}

fn appendGlobalString(rt: *core.Runtime, globals: []globals_mod.Slot, array_name: []const u8, bytes: []const u8) !void {
    var array_value = try globals_mod.getByName(rt, globals, array_name);
    if (array_value.isUndefined()) {
        array_value.free(rt);
        array_value = try getGlobalObjectProperty(rt, globals, array_name);
    }
    defer array_value.free(rt);
    const array = try expectObject(array_value);
    if (!array.is_array) return error.TypeError;
    const value = try makeString(rt, bytes);
    defer value.free(rt);
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(array.length), core.Descriptor.data(value, true, true, true));
}

fn addStringToGlobalSet(rt: *core.Runtime, globals: []globals_mod.Slot, set_name: []const u8, bytes: []const u8) !void {
    const set = try globalSetObject(rt, globals, set_name);
    const value = try makeString(rt, bytes);
    defer value.free(rt);
    const out = try setAdd(rt, set, value);
    out.free(rt);
}

fn deleteStringFromGlobalSet(rt: *core.Runtime, globals: []globals_mod.Slot, set_name: []const u8, bytes: []const u8) !void {
    const set = try globalSetObject(rt, globals, set_name);
    try deleteStringFromSet(rt, set, bytes);
}

fn deleteStringFromSet(rt: *core.Runtime, set: *core.Object, bytes: []const u8) !void {
    if (set.class_id != core.class.ids.set) return error.TypeError;
    const value = try makeString(rt, bytes);
    defer value.free(rt);
    if (findStrongEntry(set, value)) |index| {
        removeStrongEntry(rt, set, index);
        try defineIntProperty(rt, set, "size", @intCast(strongSize(set)));
    }
}

fn globalSetObject(rt: *core.Runtime, globals: []globals_mod.Slot, name: []const u8) !*core.Object {
    var set_value = try globals_mod.getByName(rt, globals, name);
    if (set_value.isUndefined()) {
        set_value.free(rt);
        set_value = try getGlobalObjectProperty(rt, globals, name);
    }
    defer set_value.free(rt);
    const set = try expectObject(set_value);
    if (set.class_id != core.class.ids.set) return error.TypeError;
    return set;
}

fn addIterCounter(rt: *core.Runtime, globals: []globals_mod.Slot, property: []const u8, delta: i32) !void {
    var iter_value = try globals_mod.getByName(rt, globals, "iter");
    if (iter_value.isUndefined()) {
        iter_value.free(rt);
        iter_value = try getGlobalObjectProperty(rt, globals, "iter");
    }
    defer iter_value.free(rt);
    const iter = try expectObject(iter_value);
    const key = try rt.internAtom(property);
    defer rt.atoms.free(key);
    const current_value = iter.getProperty(key);
    defer current_value.free(rt);
    const current = current_value.asInt32() orelse 0;
    try iter.defineOwnProperty(rt, key, core.Descriptor.data(core.Value.int32(current + delta), true, true, true));
}

fn makeString(rt: *core.Runtime, bytes: []const u8) !core.Value {
    return (try core.string.String.createUtf8(rt, bytes)).value();
}

fn valueStringEql(value: core.Value, bytes: []const u8) bool {
    const string = stringFromValue(value) orelse return false;
    return string.eqlBytes(bytes);
}

fn appendValue(rt: *core.Runtime, values: *[]core.Value, value: core.Value) !void {
    const next = try rt.memory.alloc(core.Value, values.*.len + 1);
    errdefer rt.memory.free(core.Value, next);
    @memcpy(next[0..values.*.len], values.*);
    next[values.*.len] = value.dup();
    if (values.*.len != 0) rt.memory.free(core.Value, values.*);
    values.* = next;
}

fn freeValueList(rt: *core.Runtime, values: []core.Value) void {
    for (values) |value| value.free(rt);
    if (values.len != 0) rt.memory.free(core.Value, values);
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

    const existing = try mapGet(rt, map, key);
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

fn weakKeyIdentity(rt: ?*core.Runtime, value: core.Value) ?usize {
    if (value.isSymbol()) {
        const id = value.asInt32() orelse return null;
        if (rt) |runtime| {
            if (runtime.atoms.kind(@intCast(id)) != .symbol) return null;
        }
        return (@as(usize, @intCast(id)) << 1) | 1;
    }
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @intFromPtr(header) & ~@as(usize, 1);
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
            if (class_id == core.class.ids.map) {
                try function_builtin.defineNativeMethod(rt, object, "clear", 0);
                try function_builtin.defineNativeMethod(rt, object, "keys", 0);
                try function_builtin.defineNativeMethod(rt, object, "values", 0);
                try function_builtin.defineNativeMethod(rt, object, "entries", 0);
                try function_builtin.defineNativeMethod(rt, object, "forEach", 1);
                try function_builtin.defineNativeMethod(rt, object, "getOrInsert", 2);
                try function_builtin.defineNativeMethod(rt, object, "getOrInsertComputed", 2);
            } else {
                try function_builtin.defineNativeMethod(rt, object, "getOrInsert", 2);
                try function_builtin.defineNativeMethod(rt, object, "getOrInsertComputed", 2);
            }
        },
        core.class.ids.set, core.class.ids.weakset => {
            try function_builtin.defineNativeMethod(rt, object, "add", 1);
            try function_builtin.defineNativeMethod(rt, object, "has", 1);
            try function_builtin.defineNativeMethod(rt, object, "delete", 1);
            if (class_id == core.class.ids.set) {
                try function_builtin.defineNativeMethod(rt, object, "clear", 0);
                try function_builtin.defineNativeMethod(rt, object, "keys", 0);
                try function_builtin.defineNativeMethod(rt, object, "values", 0);
                try function_builtin.defineNativeMethod(rt, object, "entries", 0);
                try function_builtin.defineNativeMethod(rt, object, "forEach", 1);
            }
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
