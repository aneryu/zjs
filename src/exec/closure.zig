//! Synthetic `c_closure` callback fixtures for collection adapters and tests.
//!
//! A fixture object stores its `Kind` and a small integer state as ordinary
//! properties; call arguments and global slots are borrowed, while returned
//! heap values carry an owned reference. This is not bytecode closure
//! construction, which lives in the core function representation and the VM
//! call machinery; the fixtures are dispatched through `call.zig` and
//! `collection_adapter.zig`.

const core = @import("../core/root.zig");
const value_ops = @import("value_ops.zig");
const globals_mod = core.global_slots;
const std = @import("std");

/// What a fixture callback does when invoked. The integer tags are the
/// property values older fixtures were created with; only the live shapes
/// remain.
pub const Kind = enum(i32) {
    /// Returns its counter, incremented on every (argument-less) call.
    counter = 2,
    throws_type_error = 7,
    throws_exception = 12,
    returns_undefined = 13,
    /// Returns its first argument.
    identity = 17,
    /// Rewrites the global `map` entry for key 1 to "mutated", then throws.
    mutates_map_key1_then_throws = 38,
    /// Rewrites the global `map` entry for key 3 to "mutated", then throws.
    mutates_map_key3_then_throws = 39,
};

pub fn create(rt: *core.JSRuntime, kind: Kind) !core.JSValue {
    const object = try core.Object.create(rt, core.class.ids.c_closure, null);
    errdefer core.Object.destroyFromHeader(rt, object.gcHeader());
    try defineIntProperty(rt, object, "__closure_kind", @intFromEnum(kind));
    try defineIntProperty(rt, object, "__closure_value", 0);
    return object.value();
}

pub fn call(rt: *core.JSRuntime, closure_value: core.JSValue, args: []const core.JSValue, globals: []globals_mod.Slot) !core.JSValue {
    return callWithThis(rt, closure_value, core.JSValue.undefinedValue(), args, globals);
}

pub fn callWithThis(rt: *core.JSRuntime, closure_value: core.JSValue, this_value: core.JSValue, args: []const core.JSValue, globals: []globals_mod.Slot) !core.JSValue {
    _ = this_value;
    const closure = try expectClosure(closure_value);
    const kind = std.enums.fromInt(Kind, try getIntProperty(rt, closure, "__closure_kind")) orelse return error.TypeError;
    switch (kind) {
        .counter => {
            if (args.len != 0) return error.TypeError;
            const value = try getIntProperty(rt, closure, "__closure_value") + 1;
            try defineIntProperty(rt, closure, "__closure_value", value);
            return core.JSValue.int32(value);
        },
        .throws_type_error => return error.TypeError,
        .throws_exception => return error.JSException,
        .returns_undefined => return core.JSValue.undefinedValue(),
        .identity => {
            if (args.len < 1) return error.TypeError;
            return args[0];
        },
        .mutates_map_key1_then_throws => {
            try setGlobalMapString(rt, globals, 1, "mutated");
            return error.JSException;
        },
        .mutates_map_key3_then_throws => {
            try setGlobalMapString(rt, globals, 3, "mutated");
            return error.JSException;
        },
    }
}

fn expectClosure(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.is(.object)) return error.TypeError;
    const closure = core.Object.fromHeader(header);
    if (closure.class_id != core.class.ids.c_closure) return error.TypeError;
    return closure;
}

fn defineIntProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8, value: i32) !void {
    const key = try rt.internAtom(name);
    try object.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(value), .all));
}

fn getIntProperty(rt: *core.JSRuntime, object: *core.Object, name: []const u8) !i32 {
    const key = try rt.internAtom(name);
    const value = try object.getProperty(key);
    return value.as(.int) orelse error.TypeError;
}

fn setGlobalMapString(rt: *core.JSRuntime, globals: []globals_mod.Slot, key_int: i32, bytes: []const u8) !void {
    const map_value = try globals_mod.getByName(rt, globals, "map");
    const map_object = try expectObject(map_value);
    if (map_object.class_id == core.class.ids.weakmap) return setGlobalWeakMapString(rt, globals, map_object, key_int, bytes);
    if (map_object.class_id != core.class.ids.map) return error.TypeError;
    const key = core.JSValue.int32(key_int);
    const value = try value_ops.createStringValue(rt, bytes);
    for (map_object.collectionEntriesSlot().items) |*entry| {
        if (!entry.active) continue;
        if (entry.key.as(.int) == key_int) {
            const next_value = value;
            entry.value = next_value;
            return;
        }
    }
    try appendUnindexedCollectionEntryAndDefineSize(rt, map_object, .{ .key = key, .value = value, .active = true });
}

fn setGlobalWeakMapString(rt: *core.JSRuntime, globals: []globals_mod.Slot, map_object: *core.Object, key_int: i32, bytes: []const u8) !void {
    var key_name_buf: [32]u8 = undefined;
    const key_name = std.fmt.bufPrint(&key_name_buf, "obj{d}", .{key_int}) catch unreachable;
    var key_value = try globals_mod.getByName(rt, globals, key_name);
    if (key_value.is(.undefined_value)) {
        key_value = try getGlobalObjectProperty(rt, globals, key_name);
    }
    const value = try value_ops.createStringValue(rt, bytes);
    try core.collection.setWeakMapEntry(rt, map_object, key_value, value);
}

fn getGlobalObjectProperty(rt: *core.JSRuntime, globals: []globals_mod.Slot, name: []const u8) !core.JSValue {
    const global = try getGlobalThisObject(rt, globals);
    const key = try rt.internAtom(name);
    return try global.getProperty(key);
}

fn getGlobalThisObject(rt: *core.JSRuntime, globals: []globals_mod.Slot) !*core.Object {
    const global_value = try globals_mod.getByName(rt, globals, "globalThis");
    const header = global_value.refHeader() orelse return error.TypeError;
    if (!global_value.is(.object)) return error.TypeError;
    return core.Object.fromHeader(header);
}

fn appendUnindexedCollectionEntryAndDefineSize(rt: *core.JSRuntime, object: *core.Object, entry: core.object.CollectionEntry) !void {
    const pending_entry = entry;

    const index = try object.appendCollectionEntryUnindexed(rt, pending_entry);
    object.collectionActiveCountSlot().* += 1;

    var inserted = true;
    errdefer if (inserted) rollbackLastUnindexedCollectionEntry(object, index);

    object.clearCollectionIndex(rt);
    try defineIntProperty(rt, object, "size", @intCast(object.collectionActiveCount()));
    inserted = false;
}

fn rollbackLastUnindexedCollectionEntry(object: *core.Object, index: usize) void {
    const entries_slot = object.collectionEntriesSlot();
    std.debug.assert(index + 1 == entries_slot.items.len);
    if (!entries_slot.items[index].active) return;
    entries_slot.items[index] = .{ .key = core.JSValue.undefinedValue(), .value = core.JSValue.undefinedValue(), .active = false };
    entries_slot.items = entries_slot.items.ptr[0..index];
    const active_count = object.collectionActiveCountSlot();
    if (active_count.* != 0) active_count.* -= 1;
}

const expectObject = core.value_semantics.expectObject;
