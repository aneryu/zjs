//! Shared object-property wrappers, property-key conversion, and object checks.
//!
//! Object/value inputs are borrowed; getters and value-based reads return one
//! owned JSValue, while successful definitions duplicate or transfer only as
//! the core Object contract states. Property-key conversion owns its temporary
//! atom and byte buffer locally. Observable VM/proxy dispatch remains in the
//! higher property modules; these helpers map to QuickJS's generic property
//! operations around quickjs.c.

const std = @import("std");
const core = @import("../core/root.zig");
const value_ops = @import("value_ops.zig");

pub fn getProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) !core.JSValue {
    _ = rt;
    return try object.getProperty(atom_id);
}

pub fn setProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !void {
    try object.setProperty(rt, atom_id, value);
}

pub fn defineDataProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: core.JSValue) !void {
    try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(value, .all));
}

pub fn deleteProperty(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) bool {
    return object.deleteProperty(rt, atom_id);
}

pub fn getPropertyValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) !core.JSValue {
    const object_value = try expectObject(value);
    if (object_value.isGlobal() and value_ops.atomNameEql(rt, atom_id, "globalThis")) return object_value.value();
    return try object_value.getProperty(atom_id);
}

pub fn optionalGetPropertyValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) !core.JSValue {
    _ = rt;
    if (value.is(.null_value) or value.is(.undefined_value)) return core.JSValue.undefinedValue();
    const object_value = try expectObject(value);
    return try object_value.getProperty(atom_id);
}

pub fn propertyIn(rt: *core.JSRuntime, object_value: core.JSValue, key_value: core.JSValue) !core.JSValue {
    const object = try expectObject(object_value);
    const key = try propertyKeyAtom(rt, key_value);
    var found = object.hasProperty(key);
    if (!found and value_ops.atomNameEql(rt, key, "toString")) found = true;
    return core.JSValue.boolean(found);
}

/// Allocation-free prefix of `propertyKeyAtom`: the atom when `value` is
/// already a property key that needs no interning work (a symbol, a string
/// whose atom is bound, or a non-negative int32 index); null otherwise so the
/// caller takes `propertyKeyAtom`. Keep the arms in lockstep with it.
pub fn propertyKeyAtomIfReady(value: core.JSValue) ?core.Atom {
    if (value.asSymbolAtom()) |atom_id| return atom_id;
    if (value.asStringBody()) |string_value| {
        if (string_value.atom_id != core.string.String.no_atom_id) return string_value.atom_id;
        return null;
    }
    if (value.as(.int)) |index| {
        if (index >= 0) return core.Atom.taggedInt(@intCast(index));
    }
    return null;
}

pub fn propertyKeyAtom(rt: *core.JSRuntime, value: core.JSValue) !core.Atom {
    if (value.asSymbolAtom()) |atom_id| return atom_id;
    if (value.isString()) {
        const string_value = value.asStringBody().?;
        return string_value.internAtom(rt);
    }
    if (value.as(.int)) |index| {
        if (index >= 0) return core.Atom.taggedInt(@intCast(index));
    }
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(rt.nativeAllocator());
    try value_ops.appendValueString(rt, &bytes, value);
    return rt.internAtom(bytes.items);
}

pub const expectObject = core.value_semantics.expectObject;

// ----- merged from property_direct.zig -----
// Guarded property and global fast probes that cannot invoke user code.
//
// Result types state whether a returned JSValue is borrowed; helpers named
// `Owned` consume their input only after the guarded slot write commits. The
// probes validate class, shape, flags, atom kind, and exotic/proxy exclusions
// before raw storage access. Observable getters, proxies, coercion, and generic
// property semantics remain in `property_ops.zig` and `vm_property.zig`.
const bytecode = @import("../bytecode.zig");
const objectFromValue = core.value_semantics.objectFromValueTrustedExpression;
const FastOwnDataLookup = union(enum) {
    value: BorrowedOwnDataLookup,
    missing,
    slow,
};
const BorrowedOwnDataLookup = struct {
    index: usize,
    value: core.JSValue,
};
const BorrowedProtoDataLookup = struct {
    holder: *core.Object,
    index: usize,
    value: core.JSValue,
};
const BorrowedGlobalDataLookup = struct {
    index: usize,
    value: core.JSValue,
};
const WritableGlobalDataStore = struct {
    index: usize,
    value: core.JSValue,
};
const FastProtoDataLookup = union(enum) {
    value: BorrowedProtoDataLookup,
    missing,
    slow,
};
pub const OrdinaryComputedPropertyLookup = union(enum) {
    value: core.JSValue,
    getter: core.JSValue,
    proxy: *core.Object,
    undefined,
    slow,
};
const DataSlot = struct {
    entry: *core.property.Entry,
    value: *core.JSValue,
};
pub inline fn dataPropertyValueForFastPath(
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
) ?core.JSValue {
    const object = objectFromValue(receiver) orelse return null;
    if (!cacheableNamedDataObject(rt, object, atom_id)) return null;

    if (rt.atoms.kind(atom_id) == .private) return null;

    switch (fastOwnOrdinaryDataPropertyLookupForObject(object, atom_id)) {
        .value => |lookup| return lookup.value,
        .missing, .slow => {},
    }
    switch (fastImmediatePrototypeDataPropertyLookupForObject(rt, object, atom_id)) {
        .value => |lookup| return lookup.value,
        .missing, .slow => {},
    }
    return null;
}

pub fn functionOwnDataPropertyValueForFastPath(value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    const object = functionOwnDataPropertyObject(value, atom_id) orelse return null;
    return object.getOwnDataPropertyValue(atom_id);
}

fn functionOwnDataPropertyObject(value: core.JSValue, atom_id: core.Atom) ?*core.Object {
    const object = objectFromValue(value) orelse return null;
    if (!isFunctionLikeClassId(object.class_id)) return null;
    if (atom_id == core.atom.ids.arguments or atom_id == core.atom.ids.caller) return null;
    return object;
}

fn isFunctionLikeClassId(class_id: core.ClassId) bool {
    return class_id == core.class.ids.c_function or
        core.class.isBytecodeFunctionClass(class_id) or
        class_id == core.class.ids.bound_function or
        class_id == core.class.ids.c_function_data or
        core.class.isAsyncFunctionResumeClass(class_id);
}

test "function-like class predicate recognizes every bytecode function class" {
    const class_ids = [_]core.ClassId{
        core.class.ids.bytecode_function,
        core.class.ids.generator_function,
        core.class.ids.async_function,
        core.class.ids.async_generator_function,
    };
    for (class_ids) |class_id| {
        try std.testing.expect(isFunctionLikeClassId(class_id));
    }
    try std.testing.expect(!isFunctionLikeClassId(core.class.ids.object));
}

inline fn cacheableNamedDataObject(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) bool {
    if (object.class_id == core.class.ids.object and
        !object.isArray() and
        !object.isGlobal() and
        !object.isProxy())
    {
        return !object.hasExoticMethods();
    }
    if (object.isProxy() or object.hasExoticMethods()) return false;
    if (object.isArray()) {
        if (atom_id == core.atom.ids.length or core.array.arrayIndexFromAtom(&rt.atoms, atom_id) != null) return false;
    } else if (object.class_id != core.class.ids.object and !object.isGlobal() and object.class_id < core.class.ids.init_count) return false;
    return true;
}

fn fastImmediatePrototypeDataPropertyLookupForObject(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) align(32) FastProtoDataLookup {
    switch (fastOwnOrdinaryDataPropertyLookupForObject(object, atom_id)) {
        .value, .slow => return .slow,
        .missing => {},
    }
    const holder = object.getPrototype() orelse return .missing;
    if (!cacheableNamedDataObject(rt, holder, atom_id)) return .slow;
    return switch (fastOwnOrdinaryDataPropertyLookupForObject(holder, atom_id)) {
        .value => |lookup| .{ .value = .{ .holder = holder, .index = lookup.index, .value = lookup.value } },
        .missing => .missing,
        .slow => .slow,
    };
}

fn fastOwnOrdinaryDataPropertyLookupForObject(object: *core.Object, atom_id: core.Atom) FastOwnDataLookup {
    const index = object.findProperty(atom_id) orelse return .missing;
    return switch (object.propKindAt(index)) {
        .data => .{ .value = .{ .index = index, .value = object.propertyEntry(index).*.slot.data } },
        .var_ref, .auto_init, .accessor => .slow,
    };
}

fn writableOwnDataPropertyLookup(object: *core.Object, lookup: BorrowedOwnDataLookup, atom_id: core.Atom) ?BorrowedOwnDataLookup {
    const slot = writableDataSlotAt(object, lookup.index, atom_id) orelse return null;
    return .{ .index = lookup.index, .value = slot.value.* };
}

fn setOwnDataPropertyLookup(rt: *core.JSRuntime, object: *core.Object, lookup: BorrowedOwnDataLookup, atom_id: core.Atom, value: core.JSValue) !bool {
    return setOwnDataPropertyAt(rt, object, lookup.index, atom_id, value);
}

fn setOwnDataPropertyAt(rt: *core.JSRuntime, object: *core.Object, index: usize, atom_id: core.Atom, value: core.JSValue) !bool {
    // `rt` is unused: under the tracing GC an in-place slot overwrite on an
    // already-published object needs no runtime hook. Kept so this stays
    // signature-compatible with the other `set*At` writers in this file.
    _ = rt;
    const slot = writableDataSlotAt(object, index, atom_id) orelse return false;
    slot.value.* = value;
    return true;
}

pub fn ordinaryDataPropertyLookup(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) OrdinaryComputedPropertyLookup {
    if (rt.atoms.kind(atom_id) == .private) return .slow;
    var cursor = objectFromValue(value) orelse return .slow;
    while (true) {
        if (cursor.proxyTarget() != null) return .{ .proxy = cursor };
        if (cursor.hasExoticMethods()) return .slow;
        if (cursor.isArray()) {
            if (atom_id == core.atom.ids.length or core.array.arrayIndexFromAtom(&rt.atoms, atom_id) != null) return .slow;
        } else if (cursor.class_id != core.class.ids.object and !cursor.isGlobal() and !cursor.flags.is_native_object) return .slow;
        if (cursor.findProperty(atom_id)) |index| {
            return switch (cursor.propKindAt(index)) {
                .data => .{ .value = cursor.propertyEntry(index).*.slot.data },
                .accessor => .{ .getter = cursor.propertyEntry(index).*.slot.accessor.getterValue() },
                .var_ref, .auto_init => .slow,
            };
        } else {
            cursor = cursor.getPrototype() orelse {
                if (cursor.isArray()) return .slow;
                return .undefined;
            };
        }
    }
}

pub fn ordinaryDataPropertyValueOrUndefinedForFastPath(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    return switch (ordinaryDataPropertyLookup(rt, value, atom_id)) {
        .value => |property_value| property_value,
        .undefined => core.JSValue.undefinedValue(),
        .getter, .proxy, .slow => null,
    };
}

fn declaredGlobalVarDataBorrowedLookup(global: *core.Object, function: *const bytecode.FunctionBytecode, atom_id: core.Atom) ?BorrowedGlobalDataLookup {
    for (function.closureVar()) |cv| {
        if (cv.closureType() != .global_decl or cv.var_name != atom_id) continue;
        return globalOwnDataPropertyBorrowedLookup(global, atom_id);
    }
    return null;
}

fn globalOwnDataPropertyBorrowedLookup(global: *core.Object, atom_id: core.Atom) ?BorrowedGlobalDataLookup {
    if (global.hasExoticMethods()) return null;
    for (global.shapeProps(), 0..) |prop, index| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted or prop.atom_id != atom_id) continue;
        if (prop_flags.isAccessor()) return null;
        if (prop_flags.kind != .data) return null;
        return .{ .index = index, .value = global.propertyEntry(index).*.slot.data };
    }
    return null;
}

pub fn globalOwnDataPropertyValue(global: *core.Object, atom_id: core.Atom) ?core.JSValue {
    const lookup = globalOwnDataPropertyBorrowedLookup(global, atom_id) orelse return null;
    return lookup.value;
}

fn globalOwnDataPropertyBorrowedAt(global: *core.Object, index: usize, atom_id: core.Atom) ?core.JSValue {
    const slot = dataSlotAt(global, index, atom_id) orelse return null;
    return slot.value.*;
}

fn globalOwnWritableDataPropertyLookup(global: *core.Object, atom_id: core.Atom) ?WritableGlobalDataStore {
    const lookup = globalOwnDataPropertyBorrowedLookup(global, atom_id) orelse return null;
    return globalWritableDataPropertyLookupAt(global, lookup.index, atom_id);
}

fn globalDataPropertyLookupForFastPath(
    rt: *core.JSRuntime,
    global: *core.Object,
    function: *const bytecode.FunctionBytecode,
    site_pc: usize,
    atom_id: core.Atom,
) ?BorrowedGlobalDataLookup {
    return installableGlobalDataPropertyLookup(rt, global, function, site_pc, atom_id);
}

pub fn globalDataPropertyValueForFastPath(
    rt: *core.JSRuntime,
    global: *core.Object,
    function: *const bytecode.FunctionBytecode,
    site_pc: usize,
    atom_id: core.Atom,
) ?core.JSValue {
    const lookup = globalDataPropertyLookupForFastPath(rt, global, function, site_pc, atom_id) orelse return null;
    return lookup.value;
}

/// The profiled and unprofiled global lookups became the same call once the
/// site profile moved out of this file; keep the second name as an alias so
/// the two `globalDataPropertyValueForFastPath*` entry points stay distinct.
const globalDataPropertyLookupForFastPathNoProfile = globalDataPropertyLookupForFastPath;
pub fn globalDataPropertyValueForFastPathNoProfile(
    rt: *core.JSRuntime,
    global: *core.Object,
    function: *const bytecode.FunctionBytecode,
    site_pc: usize,
    atom_id: core.Atom,
) ?core.JSValue {
    const lookup = globalDataPropertyLookupForFastPathNoProfile(rt, global, function, site_pc, atom_id) orelse return null;
    return lookup.value;
}

fn globalWritableDataStoreIndexForFastPath(
    rt: *core.JSRuntime,
    lexicals: ?*core.Object,
    global: *core.Object,
    function: *const bytecode.FunctionBytecode,
    site_pc: usize,
    atom_id: core.Atom,
) ?usize {
    const lookup = globalWritableDataStoreLookupForFastPath(rt, lexicals, global, function, site_pc, atom_id) orelse return null;
    return lookup.index;
}

fn globalWritableDataStoreLookupForFastPath(
    rt: *core.JSRuntime,
    lexicals: ?*core.Object,
    global: *core.Object,
    function: *const bytecode.FunctionBytecode,
    site_pc: usize,
    atom_id: core.Atom,
) ?WritableGlobalDataStore {
    _ = rt;
    _ = site_pc;
    if (lexicals) |env| {
        if (env.hasOwnProperty(atom_id)) return null;
    }
    if (declaredGlobalVarDataBorrowedLookup(global, function, atom_id)) |lookup| {
        return globalWritableDataPropertyLookupAt(global, lookup.index, atom_id);
    }
    const lookup = globalOwnDataPropertyBorrowedLookup(global, atom_id) orelse return null;
    return globalWritableDataPropertyLookupAt(global, lookup.index, atom_id);
}

pub fn setGlobalWritableDataStoreForFastPathOwned(
    rt: *core.JSRuntime,
    lexicals: ?*core.Object,
    global: *core.Object,
    function: *const bytecode.FunctionBytecode,
    site_pc: usize,
    atom_id: core.Atom,
    new_value: core.JSValue,
) bool {
    const lookup = globalWritableDataStoreLookupForFastPath(rt, lexicals, global, function, site_pc, atom_id) orelse return false;
    return setGlobalOwnWritableDataPropertyAtOwned(rt, global, lookup.index, atom_id, new_value);
}

fn setGlobalWritableDataStoreLookupOwned(
    rt: *core.JSRuntime,
    global: *core.Object,
    lookup: WritableGlobalDataStore,
    atom_id: core.Atom,
    new_value: core.JSValue,
) bool {
    return setGlobalOwnWritableDataPropertyAtOwned(rt, global, lookup.index, atom_id, new_value);
}

fn setGlobalDataPropertyLookup(
    rt: *core.JSRuntime,
    global: *core.Object,
    lookup: BorrowedGlobalDataLookup,
    atom_id: core.Atom,
    new_value: core.JSValue,
) bool {
    return setGlobalOwnWritableDataPropertyAt(rt, global, lookup.index, atom_id, new_value);
}

fn installableGlobalDataPropertyLookup(
    rt: *core.JSRuntime,
    global: *core.Object,
    function: *const bytecode.FunctionBytecode,
    site_pc: usize,
    atom_id: core.Atom,
) ?BorrowedGlobalDataLookup {
    _ = rt;
    _ = site_pc;
    if (declaredGlobalVarDataBorrowedLookup(global, function, atom_id)) |lookup| {
        return lookup;
    }
    return globalOwnDataPropertyBorrowedLookup(global, atom_id);
}

fn setGlobalOwnWritableDataPropertyAt(rt: *core.JSRuntime, global: *core.Object, index: usize, atom_id: core.Atom, new_value: core.JSValue) bool {
    const slot = writableDataSlotAt(global, index, atom_id) orelse return false;
    slot.entry.slot = .{ .data = new_value };
    // Updating an existing global var is a heap store like any other: the
    // global object is long-lived, so a fresh value stored into it is an
    // old-to-young edge the minor cannot see without the remembered set.
    rt.gc.generationalBarrier(global.gcHeader(), new_value.cycleMarkHeader());
    return true;
}

/// `Owned` is historical: under the tracing GC the caller hands over no
/// reference, so this is literally the borrowed writer.
const setGlobalOwnWritableDataPropertyAtOwned = setGlobalOwnWritableDataPropertyAt;
fn writableDataSlotAt(object: *core.Object, index: usize, atom_id: core.Atom) ?DataSlot {
    const slot = dataSlotAt(object, index, atom_id) orelse return null;
    if (!object.propFlagsAt(index).writable) return null;
    return slot;
}

fn globalWritableDataPropertyLookupAt(global: *core.Object, index: usize, atom_id: core.Atom) ?WritableGlobalDataStore {
    const slot = writableDataSlotAt(global, index, atom_id) orelse return null;
    return .{ .index = index, .value = slot.value.* };
}

fn dataSlotAt(object: *core.Object, index: usize, atom_id: core.Atom) ?DataSlot {
    if (object.hasExoticMethods() or index >= object.shapeProps().len) return null;
    const prop = object.shapeProps()[index];
    const prop_flags = core.property.Flags.fromBits(prop.flags);
    if (prop.atom_id != atom_id or prop_flags.deleted or prop_flags.kind != .data) return null;
    const entry = object.propertyEntry(index);
    return .{ .entry = entry, .value = &entry.slot.data };
}

test "fast own data property replacement retains private brand atom" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    const object = try core.Object.create(rt, core.class.ids.object, null);

    const brand = try rt.atoms.newSymbol("fastPrivateBrandReplacement", .private);
    {
        const initial = try rt.symbolValue(brand);
        try object.defineOwnProperty(
            rt,
            core.atom.ids.Private_brand,
            core.Descriptor.data(initial, .all),
        );
    }
    try std.testing.expect(rt.atoms.name(brand) != null);

    const lookup_value = try rt.symbolValue(brand);
    const lookup = writableOwnDataPropertyLookup(
        object,
        .{ .index = 0, .value = lookup_value },
        core.atom.ids.Private_brand,
    ).?;
    const replacement = try rt.symbolValue(brand);
    try std.testing.expect(try setOwnDataPropertyLookup(rt, object, lookup, core.atom.ids.Private_brand, replacement));
    try std.testing.expect(rt.atoms.name(brand) != null);
    const stored = try object.getProperty(core.atom.ids.Private_brand);
    try std.testing.expectEqual(@as(?core.Atom, brand), stored.asSymbolAtom());
}

test "global own data slot helpers preserve lookup and write ownership" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);

    const name = try rt.internAtom("globalSlotFunction");
    const key = try rt.internAtom("globalSlotAdapter");
    const other_key = try rt.internAtom("globalSlotOther");

    const initial = try core.string.String.createAscii(rt, "initial");
    try global.defineOwnProperty(rt, key, core.Descriptor.data(initial.value(), .all));

    const execution_function = try bytecode.FunctionBytecode.createFixture(rt, .{ .name = name, .closure_var_count = 1 });
    defer execution_function.destroyUnpublishedFixture(rt);
    execution_function.closureVar()[0] = bytecode.function_bytecode.BytecodeClosureVar.init(.{
        .closure_type = .global_decl,
        .var_idx = 0,
        .var_name = key,
    });

    const lookup = globalOwnDataPropertyBorrowedLookup(global, key).?;
    try std.testing.expectEqual(@as(usize, 0), lookup.index);
    try std.testing.expectEqual(initial.header(), lookup.value.stringHeader().?);
    try std.testing.expectEqual(initial.header(), globalOwnDataPropertyValue(global, key).?.stringHeader().?);
    try std.testing.expect(globalOwnDataPropertyValue(global, other_key) == null);
    try std.testing.expectEqual(initial.header(), globalOwnWritableDataPropertyLookup(global, key).?.value.stringHeader().?);
    const writable_lookup = globalWritableDataPropertyLookupAt(global, lookup.index, key).?;
    try std.testing.expectEqual(lookup.index, writable_lookup.index);
    try std.testing.expectEqual(initial.header(), writable_lookup.value.stringHeader().?);
    try std.testing.expectEqual(@as(?usize, lookup.index), globalWritableDataStoreIndexForFastPath(rt, null, global, execution_function, 0, key));
    const store_lookup = globalWritableDataStoreLookupForFastPath(rt, null, global, execution_function, 0, key).?;
    try std.testing.expectEqual(lookup.index, store_lookup.index);
    try std.testing.expectEqual(initial.header(), store_lookup.value.stringHeader().?);
    try std.testing.expectEqual(initial.header(), globalOwnDataPropertyBorrowedAt(global, lookup.index, key).?.stringHeader().?);
    try std.testing.expectEqual(initial.header(), declaredGlobalVarDataBorrowedLookup(global, execution_function, key).?.value.stringHeader().?);
    try std.testing.expect(declaredGlobalVarDataBorrowedLookup(global, execution_function, other_key) == null);
    try std.testing.expectEqual(initial.header(), globalDataPropertyLookupForFastPath(rt, global, execution_function, 0, key).?.value.stringHeader().?);
    try std.testing.expectEqual(initial.header(), globalDataPropertyValueForFastPath(rt, global, execution_function, 0, key).?.stringHeader().?);
    try std.testing.expectEqual(initial.header(), globalDataPropertyLookupForFastPathNoProfile(rt, global, execution_function, 0, key).?.value.stringHeader().?);
    try std.testing.expectEqual(initial.header(), globalDataPropertyValueForFastPathNoProfile(rt, global, execution_function, 0, key).?.stringHeader().?);
    try std.testing.expect(globalDataPropertyLookupForFastPath(rt, global, execution_function, 0, other_key) == null);
    try std.testing.expect(globalDataPropertyValueForFastPath(rt, global, execution_function, 0, other_key) == null);

    const lexicals = try core.Object.create(rt, core.class.ids.object, null);
    try lexicals.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(7), .all));
    try std.testing.expect(globalWritableDataStoreIndexForFastPath(rt, lexicals, global, execution_function, 0, key) == null);
    try std.testing.expect(globalWritableDataStoreLookupForFastPath(rt, lexicals, global, execution_function, 0, key) == null);
    const shadowed_owned = try core.string.String.createAscii(rt, "shadowed-owned");
    var shadowed_transferred = false;
    const shadowed_store = setGlobalWritableDataStoreForFastPathOwned(rt, lexicals, global, execution_function, 0, key, shadowed_owned.value());
    if (shadowed_store) shadowed_transferred = true;
    try std.testing.expect(!shadowed_store);
    shadowed_transferred = true;

    const copied = copied: {
        const value = try core.string.String.createAscii(rt, "copied");
        try std.testing.expect(setGlobalDataPropertyLookup(rt, global, lookup, key, value.value()));
        break :copied value;
    };
    try std.testing.expectEqual(copied.header(), globalOwnDataPropertyBorrowedAt(global, lookup.index, key).?.stringHeader().?);

    const owned = try core.string.String.createAscii(rt, "owned");
    var owned_transferred = false;
    try std.testing.expect(setGlobalOwnWritableDataPropertyAtOwned(rt, global, lookup.index, key, owned.value()));
    owned_transferred = true;
    try std.testing.expectEqual(owned.header(), globalOwnDataPropertyBorrowedAt(global, lookup.index, key).?.stringHeader().?);

    const lookup_owned = try core.string.String.createAscii(rt, "lookup-owned");
    var lookup_transferred = false;
    const writable_store = globalWritableDataStoreLookupForFastPath(rt, null, global, execution_function, 0, key).?;
    try std.testing.expect(setGlobalWritableDataStoreLookupOwned(rt, global, writable_store, key, lookup_owned.value()));
    lookup_transferred = true;
    try std.testing.expectEqual(lookup_owned.header(), globalOwnDataPropertyBorrowedAt(global, lookup.index, key).?.stringHeader().?);

    const fast_path_owned = try core.string.String.createAscii(rt, "fast-path-owned");
    var fast_path_transferred = false;
    try std.testing.expect(setGlobalWritableDataStoreForFastPathOwned(rt, null, global, execution_function, 0, key, fast_path_owned.value()));
    fast_path_transferred = true;
    try std.testing.expectEqual(fast_path_owned.header(), globalOwnDataPropertyBorrowedAt(global, lookup.index, key).?.stringHeader().?);
}

test "global own data slot helpers reject readonly and accessor writes" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);

    const readonly_key = try rt.internAtom("readonlyGlobalSlot");
    const accessor_key = try rt.internAtom("accessorGlobalSlot");

    try global.defineOwnProperty(rt, readonly_key, core.Descriptor.data(core.JSValue.int32(1), .{ .enumerable = true, .configurable = true }));
    const readonly_lookup = globalOwnDataPropertyBorrowedLookup(global, readonly_key).?;
    try std.testing.expectEqual(@as(?i32, 1), readonly_lookup.value.as(.int));
    try std.testing.expect(globalOwnWritableDataPropertyLookup(global, readonly_key) == null);
    try std.testing.expect(globalWritableDataPropertyLookupAt(global, readonly_lookup.index, readonly_key) == null);
    try std.testing.expect(!setGlobalDataPropertyLookup(rt, global, readonly_lookup, readonly_key, core.JSValue.int32(2)));
    try std.testing.expect(!setGlobalOwnWritableDataPropertyAtOwned(rt, global, readonly_lookup.index, readonly_key, core.JSValue.int32(2)));
    try std.testing.expectEqual(@as(?i32, 1), globalOwnDataPropertyBorrowedAt(global, readonly_lookup.index, readonly_key).?.as(.int));

    // Accessor get/set are stored as object headers (qjs `JSObject*`); use
    // object values (the old loose JSValue accessor cell that allowed string
    // placeholders was replaced by L2's object-header pointers).
    const getter = try core.Object.create(rt, core.class.ids.object, null);
    const setter = try core.Object.create(rt, core.class.ids.object, null);
    try global.defineOwnProperty(rt, accessor_key, core.Descriptor.accessor(getter.value(), setter.value(), .{ .enumerable = true, .configurable = true }));

    const accessor_index = accessor_index: {
        for (global.shapeProps(), 0..) |prop, index| {
            if (!core.property.Flags.fromBits(prop.flags).deleted and prop.atom_id == accessor_key) break :accessor_index index;
        }
        unreachable;
    };
    try std.testing.expect(globalOwnDataPropertyBorrowedLookup(global, accessor_key) == null);
    try std.testing.expect(globalOwnWritableDataPropertyLookup(global, accessor_key) == null);
    try std.testing.expect(globalOwnDataPropertyBorrowedAt(global, accessor_index, accessor_key) == null);
    try std.testing.expect(globalWritableDataPropertyLookupAt(global, accessor_index, accessor_key) == null);
    const accessor_lookup: BorrowedGlobalDataLookup = .{ .index = accessor_index, .value = core.JSValue.undefinedValue() };
    try std.testing.expect(!setGlobalDataPropertyLookup(rt, global, accessor_lookup, accessor_key, core.JSValue.int32(3)));
    try std.testing.expect(!setGlobalOwnWritableDataPropertyAtOwned(rt, global, accessor_index, accessor_key, core.JSValue.int32(3)));
}

// ----- merged from slot_ops.zig -----
// Local, argument, var-ref and global-lexical slot operations shared between the VM and call runtime.
const builtin = @import("builtin");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const call_runtime = @import("call_runtime.zig");
const exception_ops = @import("exception_ops.zig");
const ensureVarRefsCapacity = frame_mod.ensureVarRefsCapacity;
const globalLexicalValueForGlobal = call_runtime.globalLexicalValueForGlobal;
const handleCatchableRuntimeError = call_runtime.handleCatchableRuntimeError;
const throwTdzReferenceError = exception_ops.throwTdzReferenceError;
const throwTypeErrorMessage = exception_ops.throwTypeErrorMessage;
const op = bytecode.opcode.op;
pub fn execGetLoc(
    _: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = opc;
    // No runtime bounds check: `resolve_variables` only emits get_loc with
    // idx < var_count, and `frame.locals` is sized to exactly var_count
    // (vm_call.initFrameLocals). idx < var_count == frame.locals.len holds for
    // every dispatched frame — the same trusted-compiler model as QuickJS's
    // bare `var_buf[idx]`. The stack is pre-sized (reserveEntryFrameCapacity),
    // so the push skips reserveAdditional, mirroring qjs's `*sp++`.
    stack.pushOwnedAssumeCapacity(frame.locals[idx]);
}

pub noinline fn execPutLoc(
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = opc;
    // idx < var_count == frame.locals.len by construction (see execGetLoc).
    const value = try stack.pop();
    frame.locals[idx] = value;
}

pub fn execSetLoc(
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = opc;
    // idx < var_count == frame.locals.len by construction (see execGetLoc).
    // set_loc leaves the operand on the stack; borrow it and let the
    // ValueSlot take exactly one retained reference.
    const value = stack.peekBorrowed() orelse return error.StackUnderflow;
    frame.locals[idx] = value;
}

pub fn execGetArg(
    _: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = opc;
    if (idx >= frame.args.len) {
        try stack.pushOwned(core.JSValue.undefinedValue());
        return;
    }
    const owned = frame.args[idx];
    try stack.pushOwned(owned);
}

pub fn execPutArg(
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = opc;
    if (idx >= frame.args.len) return error.InvalidBytecode;
    const value = try stack.pop();
    frame.args[idx] = value;
}

pub fn execSetArg(
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    _ = opc;
    if (idx >= frame.args.len) return error.InvalidBytecode;
    // set_arg has the same non-consuming ownership contract as set_loc.
    const value = stack.peekBorrowed() orelse return error.StackUnderflow;
    frame.args[idx] = value;
}

pub fn execGetVarRefMaybeTdz(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    catch_target: *?usize,
    global: *core.Object,
) !bool {
    frame.pc += consume;
    if (idx >= frame.var_refs.len) try ensureVarRefsCapacity(ctx, frame, idx);
    if (idx < function.varRefNamesLen()) {
        const atom_id = function.varRefName(idx);
        // Only a genuine top-level global_decl var-ref (qjs JS_CLOSURE_GLOBAL_DECL)
        // reads through the global lexical cell by name. A captured block/loop
        // lexical (.ref/.local) that merely shares a name must fall through to the
        // real frame.var_refs cell below so its TDZ check is honored — otherwise a
        // same-named outer top-level `let` shadows the captured per-iteration TDZ slot.
        const is_global_decl_ref = function.varRefIsGlobalDeclAt(idx);
        if (is_global_decl_ref) {
            if (globalLexicalValueForGlobal(ctx, global, atom_id)) |lexical_value| {
                if (lexical_value.is(.uninitialized)) {
                    const err = throwTdzReferenceError(ctx);
                    if (try handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) {
                        return true;
                    }
                    return err;
                }
                try stack.pushOwned(lexical_value);
                return false;
            }
        }
        if (call_runtime.closureVarIsNonLexicalGlobalSentinel(function, idx)) {
            const value = try global.getProperty(atom_id);
            try stack.pushOwned(value);
            return false;
        }
    }
    // Slot is a cell by type (qjs OP_get_var_ref_check, quickjs.c);
    // the pre-typed raw-slot arm is gone with the type flip.
    const cell = varRefSlotCell(frame, idx);
    const value = cell.varRefValue();
    if (value.is(.uninitialized)) {
        // A deletable cell parked at UNINITIALIZED is a deleted
        // eval-created binding (qjs remove_global_object_property):
        // plain ReferenceError, not the TDZ message.
        if (cell.varRefIsDeletableSlot().*) {
            if (try handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.ReferenceError)) {
                return true;
            }
            return error.ReferenceError;
        }
        // Captured derived `this` uses ordinary get_var_ref_check in QuickJS,
        // so it remains catchable in the current (callee) realm while keeping
        // the constructor-specific message.
        const err = if (idx < function.varRefNamesLen() and function.varRefName(idx) == core.atom.ids.this_) blk: {
            _ = exception_ops.throwReferenceErrorMessage(ctx, global, "this is not initialized") catch |err| break :blk err;
            unreachable;
        } else throwTdzReferenceError(ctx);
        if (try handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) {
            return true;
        }
        return err;
    }
    try stack.push(value);
    return false;
}

pub fn execPutVarRef(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    if (idx >= frame.var_refs.len) try ensureVarRefsCapacity(ctx, frame, idx);
    const value = try stack.pop();
    // Slot is a cell by type (qjs OP_put_var_ref set_value into
    // var_refs[idx]->pvalue, quickjs.c); the raw-slot arm — including
    // its global-lexical/sentinel fallbacks, which post phase-B could never
    // execute (every slot was already a cell) — is deleted with the type.
    const cell = varRefSlotCell(frame, idx);
    if (opc == op.put_var_ref_check_init) {
        const current = cell.varRefValue();
        if (!current.is(.uninitialized)) {
            _ = exception_ops.throwReferenceErrorMessage(ctx, global, "this is not initialized") catch |err| return err;
            unreachable;
        }
    }
    if (opc == op.put_var_ref_check) {
        const current = cell.varRefValue();
        if (current.is(.uninitialized)) {
            return throwTdzReferenceError(ctx);
        }
    }
    const capture_is_function_name = idx < function.closureVar().len and
        function.closureVar()[idx].varKind() == .function_name;
    const capture_is_const = idx < function.closureVar().len and
        function.closureVar()[idx].isConst();
    if (cell.varRefIsFunctionNameSlot().* or capture_is_function_name) {
        if (function.isStrictMode()) return error.TypeError;
        return;
    }
    if ((cell.varRefIsConstSlot().* or capture_is_const) and !constVarRefWriteAllowed(cell, opc)) {
        _ = throwTypeErrorMessage(ctx, global, "invalid assignment to const variable") catch |err| return err;
        return error.TypeError;
    }
    var assigned = value;
    if (varRefCellFromValue(value) != null) {
        assigned = adapterValueBorrow(value);
    }
    cell.setVarRefValue(ctx.runtime, assigned);
}

pub fn isVarRefInitOpcode(opc: u8) bool {
    return opc == op.put_var_ref or
        opc == op.put_var_ref_check_init or
        opc == op.put_var_ref0 or
        opc == op.put_var_ref1 or
        opc == op.put_var_ref2 or
        opc == op.put_var_ref3;
}

pub fn constVarRefWriteAllowed(cell: *core.VarRef, opc: u8) bool {
    _ = cell;
    return isVarRefInitOpcode(opc);
}

pub fn execSetVarRef(
    ctx: *core.JSContext,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    idx: u16,
    consume: u8,
    opc: u8,
) !void {
    frame.pc += consume;
    if (idx >= frame.var_refs.len) try ensureVarRefsCapacity(ctx, frame, idx);
    _ = opc;
    const value = stack.peek() orelse return error.StackUnderflow;
    replaceVarRefValueOwned(ctx, frame, idx, value);
}

pub fn adapterValueBorrow(slot: core.JSValue) callconv(.c) core.JSValue {
    // Terminal-state invariant: a cell's VALUE is never itself a cell — the
    // last nesting producer (the direct-eval const view) now pvalue-aliases
    // its target (eval_ops.directEvalOuterVarRefView) — so ONE unwrap reaches
    // the plain value (qjs bare `*var_ref->pvalue`, quickjs.c).
    const cell = varRefCellFromValue(slot) orelse return slot;
    const value = cell.varRefValue();
    if (comptime builtin.mode == .Debug) {
        std.debug.assert(varRefCellFromValue(value) == null);
    }
    return value;
}

pub fn adapterValueIsUninitialized(slot: core.JSValue) bool {
    return adapterValueBorrow(slot).is(.uninitialized);
}

/// A deleted eval-created binding: its deletable cell was parked at
/// UNINITIALIZED by ordinary global property deletion (qjs
/// remove_global_object_property, quickjs.c). Distinct from a TDZ
/// cell, which is uninitialized but NOT deletable.
pub fn adapterIsDeletedEvalBinding(slot: core.JSValue) bool {
    const cell = varRefCellFromValue(slot) orelse return false;
    if (!cell.varRefIsDeletableSlot().*) return false;
    return cell.varRefValue().is(.uninitialized);
}

/// Replace an owned JSValue Adapter slot. This cold boundary accepts a VarRef
/// handle on either side and preserves its
/// write-through semantics. It must not be used for frame locals or arguments.
pub inline fn replaceAdapterOwned(ctx: *core.JSContext, slot: *core.JSValue, value: core.JSValue) void {
    if (!slot.isTracerOwned() and !value.isTracerOwned()) {
        slot.* = value;
        return;
    }
    replaceAdapterRefCounted(ctx, slot, value);
}

noinline fn replaceAdapterRefCounted(ctx: *core.JSContext, slot: *core.JSValue, value: core.JSValue) void {
    var assigned = value;
    if (varRefCellFromValue(value) != null) {
        assigned = adapterValueBorrow(value);
    }
    if (varRefCellFromValue(slot.*)) |cell| {
        cell.setVarRefValue(ctx.runtime, assigned);
        return;
    }
    slot.* = assigned;
}

pub fn varRefCellFromValue(value: core.JSValue) ?*core.VarRef {
    return core.VarRef.fromValue(value);
}

// ---- frame.var_refs slot accessors (VARREFS-SLOT-TYPING-BLUEPRINT, phase D) ----
//
// Single funnel for every ELEMENT access of `frame.var_refs: []*core.VarRef`
// (qjs `JSVarRef **var_refs`: JSObject.u.func.var_refs alloc, quickjs.c;
// JS_CallInternal prologue `var_refs = p->u.func.var_refs`). Every slot
// is a live cell by the type; the phase-A/B "is this slot a cell" runtime
// discrimination and its debug canary are gone. `varRefSlot*` returning
// JSValue are the boundary views for the JSValue-typed domains (eval name
// tables, property cells) — they wrap the cell, they do not chase its value.

/// Bounds-checked cell read: `frame.var_refs[idx]`.
pub inline fn varRefSlotCell(frame: *const frame_mod.Frame, idx: usize) *core.VarRef {
    return frame.var_refs[idx];
}

/// Bounds-checked element read in JSValue form (the cell's value view).
/// Borrowed: callers dup when they need ownership.
pub inline fn varRefSlot(frame: *const frame_mod.Frame, idx: usize) core.JSValue {
    return frame.var_refs[idx].valueRef();
}

/// Cell store — slot REBIND, not value write-through. The only users are the
/// element-level replacement points (global-decl PASS2 cell surgery and
/// module prologue fill): the caller owns the
/// refcount choreography for both the incoming cell and the displaced one.
/// The JSValue parameter is the boundary form those callers hold (an owned
/// ref to a cell by construction); the transfer keeps its refcount.
pub inline fn storeVarRefSlot(frame: *frame_mod.Frame, idx: usize, slot: core.JSValue) void {
    frame.var_refs[idx] = varRefCellFromValue(slot).?;
}

/// Write-through store into the slot's cell (qjs OP_put_var_ref
/// `set_value(ctx, var_refs[idx]->pvalue,...)`, quickjs.c). Preserves
/// the Adapter replacement unwrap: an incoming cell VALUE is dereferenced
/// before the store so cell values never nest through writes.
pub inline fn replaceVarRefValueOwned(ctx: *core.JSContext, frame: *frame_mod.Frame, idx: usize, value: core.JSValue) void {
    var assigned = value;
    if (varRefCellFromValue(value) != null) {
        assigned = adapterValueBorrow(value);
    }
    frame.var_refs[idx].setVarRefValue(ctx.runtime, assigned);
}
