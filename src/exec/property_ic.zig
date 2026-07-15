const std = @import("std");
const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const value_ops = @import("value_ops.zig");

inline fn objectFromValue(value: core.JSValue) ?*core.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

const FastOwnDataResult = union(enum) {
    value: core.JSValue,
    missing,
    slow,
};

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

pub const PlainObjectInt32DataProperties = struct {
    writable: i32,
    b: i32,
    c: i32,
};

const DataSlot = struct {
    entry: *core.property.Entry,
    value: *core.JSValue,
};

pub inline fn dataPropertyValueForFastPath(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
) ?core.JSValue {
    _ = function;
    _ = site_pc;
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

/// Formerly a monomorphic OWN-data-property IC fast path for the lean inline
/// get_field handler. With the inline cache removed (qjs has none), there is no
/// per-call-site cache to hit, so this always returns null and the lean handler
/// falls through to the cold `field` handler, which performs the full shape-hash
/// lookup directly. The signature is retained for ABI stability with callers.
pub inline fn cachedDataPropertyValueForFastPath(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
) ?core.JSValue {
    _ = function;
    _ = site_pc;
    _ = rt;
    _ = receiver;
    _ = atom_id;
    return null;
}

pub fn functionOwnDataPropertyValueForFastPath(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    const object = functionOwnDataPropertyObject(rt, value, atom_id) orelse return null;
    return object.getOwnDataPropertyValue(atom_id);
}

pub fn functionOwnNativeBuiltinRefForFastPath(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    value: core.JSValue,
    atom_id: core.Atom,
) ?core.function.NativeBuiltinRef {
    _ = function;
    _ = site_pc;
    const object = functionOwnDataPropertyObject(rt, value, atom_id) orelse return null;
    if (object.hasExoticMethods()) return null;

    for (object.shapeProps(), 0..) |prop, index| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted or prop.atom_id != atom_id) continue;
        if (prop_flags.isAccessor()) return null;
        switch (object.propKindAt(index)) {
            .data => {
                return nativeBuiltinRefFromFunctionValue(object.prop_values[index].slot.data);
            },
            .auto_init => {
                const materialized = object.getProperty(atom_id);
                defer materialized.free(rt);
                return nativeBuiltinRefFromFunctionValue(materialized);
            },
            .var_ref, .accessor => return null,
        }
    }
    return null;
}

fn functionOwnDataPropertyObject(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?*core.Object {
    const object = objectFromValue(value) orelse return null;
    if (!isFunctionLikeClassId(object.class_id)) return null;
    if (atom_id == core.atom.ids.arguments or value_ops.atomNameEql(rt, atom_id, "caller")) return null;
    return object;
}

fn nativeBuiltinRefFromFunctionValue(value: core.JSValue) ?core.function.NativeBuiltinRef {
    const function_object = objectFromValue(value) orelse return null;
    return core.function.decodeNativeBuiltinId(function_object.nativeFunctionId());
}

fn isFunctionLikeClassId(class_id: core.ClassId) bool {
    return class_id == core.class.ids.c_function or
        class_id == core.class.ids.bytecode_function or
        class_id == core.class.ids.bound_function or
        class_id == core.class.ids.c_function_data or
        class_id == core.class.ids.c_closure;
}

pub fn setObjectDataPropertyForPutFieldFastPath(
    rt: *core.JSRuntime,
    function: *const bytecode.Bytecode,
    site_pc: usize,
    receiver: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
) !bool {
    _ = function;
    _ = site_pc;
    return setObjectDataPropertyForSimplePutFieldOwned(rt, receiver, atom_id, value);
}

/// Formerly an IC-hit-only put for the lean `op_put_field` fast handler. With the
/// inline cache removed (qjs has none), there is no cached slot to write, so this
/// always returns false and the lean handler defers to the cold handler's full
/// `setObjectDataPropertyForPutFieldFastPath` (simple-put + slow path). The
/// signature is retained for ABI stability with callers.
pub inline fn cachedSetObjectDataPropertyForPutFastPath(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
) bool {
    _ = function;
    _ = site_pc;
    _ = rt;
    _ = receiver;
    _ = atom_id;
    _ = value;
    return false;
}

fn setObjectDataPropertyForSimplePutFieldOwned(rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom, value: core.JSValue) bool {
    if (rt.atoms.kind(atom_id) == .private) return false;
    const object = objectFromValue(receiver) orelse return false;
    if (object.needsSlowPropertyAccess()) return false;
    if (object.proxyTarget() != null or object.hasExoticMethods()) return false;
    if (object.class_id == core.class.ids.module_ns) return false;
    if (core.object.isTypedArrayObject(object)) return false;
    if (object.isArray()) {
        if (atom_id == core.atom.ids.length or core.array.arrayIndexFromAtom(&rt.atoms, atom_id) != null) return false;
    }
    if (object.class_id == core.class.ids.regexp and atom_id == core.atom.ids.lastIndex and object.regexpLastIndex() != null) return false;
    const lookup = writableOwnDataPropertyLookupForObject(object, atom_id) orelse return false;
    return setOwnDataPropertyLookupOwned(rt, object, lookup, atom_id, value);
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

fn fastImmediatePrototypeDataPropertyLookupForObject(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) FastProtoDataLookup {
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
        .data => .{ .value = .{ .index = index, .value = object.prop_values[index].slot.data } },
        .var_ref, .auto_init, .accessor => .slow,
    };
}

fn ownDataPropertyLookupForFastPath(object: *core.Object, atom_id: core.Atom) ?BorrowedOwnDataLookup {
    return switch (fastOwnOrdinaryDataPropertyLookupForObject(object, atom_id)) {
        .value => |lookup| lookup,
        .missing, .slow => null,
    };
}

pub fn plainObjectInt32DataPropertiesForFastPath(
    object: *core.Object,
    writable_atom: core.Atom,
    b_atom: core.Atom,
    c_atom: core.Atom,
) ?PlainObjectInt32DataProperties {
    if (!plainObjectDataPropertyFastPathReceiver(object)) return null;
    const writable = writableOwnDataPropertyLookupForObject(object, writable_atom) orelse return null;
    const b = ownDataPropertyLookupForFastPath(object, b_atom) orelse return null;
    const c = ownDataPropertyLookupForFastPath(object, c_atom) orelse return null;
    return .{
        .writable = writable.value.asInt32() orelse return null,
        .b = b.value.asInt32() orelse return null,
        .c = c.value.asInt32() orelse return null,
    };
}

pub fn setPlainObjectInt32DataPropertyForFastPath(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom, value: i32) !bool {
    if (!plainObjectDataPropertyFastPathReceiver(object)) return false;
    const lookup = writableOwnDataPropertyLookupForObject(object, atom_id) orelse return false;
    return try setOwnDataPropertyLookup(rt, object, lookup, atom_id, core.JSValue.int32(value));
}

fn plainObjectDataPropertyFastPathReceiver(object: *core.Object) bool {
    if (object.proxyTarget() != null or object.hasExoticMethods()) return false;
    return object.class_id == core.class.ids.object and !object.isArray() and !object.isGlobal();
}

pub fn ownDataPropertyValueMaterializedForFastPath(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    if (rt.atoms.kind(atom_id) == .private) return null;
    const object = objectFromValue(value) orelse return null;
    if (object.proxyTarget() != null or object.hasExoticMethods()) return null;
    if (object.class_id != core.class.ids.object and !object.isGlobal()) return null;

    switch (fastOwnOrdinaryDataPropertyBorrowedValue(object, atom_id)) {
        .value => |stored| return stored,
        .missing => return null,
        .slow => {},
    }

    const desc = object.getOwnProperty(rt, atom_id) orelse return null;
    defer desc.destroy(rt);
    if (desc.kind != .data or !desc.value_present) return null;

    return switch (fastOwnOrdinaryDataPropertyBorrowedValue(object, atom_id)) {
        .value => |stored| stored,
        .missing, .slow => null,
    };
}

fn ownDataPropertyBorrowedAt(object: *core.Object, index: usize, atom_id: core.Atom) ?core.JSValue {
    const slot = dataSlotAt(object, index, atom_id) orelse return null;
    return slot.value.*;
}

fn writableOwnDataPropertyLookupForObject(object: *core.Object, atom_id: core.Atom) ?BorrowedOwnDataLookup {
    const lookup = ownDataPropertyLookupForFastPath(object, atom_id) orelse return null;
    return writableOwnDataPropertyLookup(object, lookup, atom_id);
}

fn writableOwnDataPropertyLookup(object: *core.Object, lookup: BorrowedOwnDataLookup, atom_id: core.Atom) ?BorrowedOwnDataLookup {
    const slot = writableDataSlotAt(object, lookup.index, atom_id) orelse return null;
    return .{ .index = lookup.index, .value = slot.value.* };
}

fn setOwnDataPropertyLookup(rt: *core.JSRuntime, object: *core.Object, lookup: BorrowedOwnDataLookup, atom_id: core.Atom, value: core.JSValue) !bool {
    return setOwnDataPropertyAt(rt, object, lookup.index, atom_id, value);
}

fn setOwnDataPropertyLookupOwned(rt: *core.JSRuntime, object: *core.Object, lookup: BorrowedOwnDataLookup, atom_id: core.Atom, value: core.JSValue) bool {
    return setOwnDataPropertyAtOwned(rt, object, lookup.index, atom_id, value);
}

fn setOwnDataPropertyAt(rt: *core.JSRuntime, object: *core.Object, index: usize, atom_id: core.Atom, value: core.JSValue) !bool {
    const slot = writableDataSlotAt(object, index, atom_id) orelse return false;
    if (atom_id != core.atom.ids.Private_brand and !slot.value.requiresRefCount() and !value.requiresRefCount()) {
        slot.value.* = value;
        return true;
    }
    const next_value = core.object.dupPropertyDataValue(&rt.atoms, atom_id, value);
    errdefer core.object.destroyPropertySlot(rt, atom_id, data_flags, .{ .data = next_value });
    const old_value = slot.value.*;
    slot.value.* = next_value;
    core.object.destroyPropertySlot(rt, atom_id, data_flags, .{ .data = old_value });
    return true;
}

/// `writableDataSlotAt` guarantees the slot is `.data`; destroy with a
/// data-kind flag (the w/e/c bits are irrelevant to `destroyPropertySlot`).
const data_flags = core.property.Flags{ .kind = .data, .writable = true };

fn setOwnDataPropertyAtOwned(rt: *core.JSRuntime, object: *core.Object, index: usize, atom_id: core.Atom, value: core.JSValue) bool {
    const slot = writableDataSlotAt(object, index, atom_id) orelse return false;
    const old_slot = slot.entry.slot;
    slot.entry.slot = .{ .data = value };
    core.object.destroyPropertySlot(rt, atom_id, data_flags, old_slot);
    return true;
}

fn fastOwnOrdinaryDataPropertyBorrowedValue(object: *core.Object, atom_id: core.Atom) FastOwnDataResult {
    const index = object.findProperty(atom_id) orelse return .missing;
    return switch (object.propKindAt(index)) {
        .data => .{ .value = object.prop_values[index].slot.data },
        .var_ref, .auto_init, .accessor => .slow,
    };
}

fn ordinaryDataPropertyLookup(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) OrdinaryComputedPropertyLookup {
    if (rt.atoms.kind(atom_id) == .private) return .slow;
    var cursor = objectFromValue(value) orelse return .slow;
    while (true) {
        if (cursor.proxyTarget() != null) return .{ .proxy = cursor };
        if (cursor.hasExoticMethods()) return .slow;
        if (cursor.isArray()) {
            if (atom_id == core.atom.ids.length or core.array.arrayIndexFromAtom(&rt.atoms, atom_id) != null) return .slow;
        } else if (cursor.class_id != core.class.ids.object and !cursor.isGlobal()) return .slow;
        if (cursor.findProperty(atom_id)) |index| {
            return switch (cursor.propKindAt(index)) {
                .data => .{ .value = cursor.prop_values[index].slot.data },
                .accessor => .{ .getter = cursor.prop_values[index].slot.accessor.getterValue() },
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

pub fn ordinaryComputedPropertyLookupForFastPath(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) OrdinaryComputedPropertyLookup {
    return ordinaryDataPropertyLookup(rt, value, atom_id);
}

pub fn ordinaryDataPropertyBorrowedValueForFastPath(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    return switch (ordinaryDataPropertyLookup(rt, value, atom_id)) {
        .value => |property_value| property_value,
        .getter, .proxy, .undefined, .slow => null,
    };
}

pub fn ordinaryDataPropertyValueOrUndefinedForFastPath(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    return switch (ordinaryDataPropertyLookup(rt, value, atom_id)) {
        .value => |property_value| property_value,
        .undefined => core.JSValue.undefinedValue(),
        .getter, .proxy, .slow => null,
    };
}

pub fn ordinaryDataPropertyIsUndefinedForFastPath(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?bool {
    return switch (ordinaryDataPropertyLookup(rt, value, atom_id)) {
        .value => |property_value| property_value.isUndefined(),
        .undefined => true,
        .getter, .proxy, .slow => null,
    };
}

fn declaredGlobalVarDataBorrowedLookup(global: *core.Object, function: *const bytecode.Bytecode, atom_id: core.Atom) ?BorrowedGlobalDataLookup {
    for (function.global_vars) |gv| {
        if (gv.var_name != atom_id) continue;
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
        return .{ .index = index, .value = global.prop_values[index].slot.data };
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
    function: *const bytecode.Bytecode,
    site_pc: usize,
    atom_id: core.Atom,
) ?BorrowedGlobalDataLookup {
    return installableGlobalDataPropertyLookup(rt, global, function, site_pc, atom_id);
}

pub fn globalDataPropertyValueForFastPath(
    rt: *core.JSRuntime,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    site_pc: usize,
    atom_id: core.Atom,
) ?core.JSValue {
    const lookup = globalDataPropertyLookupForFastPath(rt, global, function, site_pc, atom_id) orelse return null;
    return lookup.value;
}

fn globalDataPropertyLookupForFastPathNoProfile(
    rt: *core.JSRuntime,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    site_pc: usize,
    atom_id: core.Atom,
) ?BorrowedGlobalDataLookup {
    return installableGlobalDataPropertyLookup(rt, global, function, site_pc, atom_id);
}

pub fn globalDataPropertyValueForFastPathNoProfile(
    rt: *core.JSRuntime,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    site_pc: usize,
    atom_id: core.Atom,
) ?core.JSValue {
    const lookup = globalDataPropertyLookupForFastPathNoProfile(rt, global, function, site_pc, atom_id) orelse return null;
    return lookup.value;
}

pub fn setGlobalDataPropertyForFastPath(
    rt: *core.JSRuntime,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    site_pc: usize,
    atom_id: core.Atom,
    new_value: core.JSValue,
) bool {
    const lookup = globalDataPropertyLookupForFastPathNoProfile(rt, global, function, site_pc, atom_id) orelse return false;
    return setGlobalDataPropertyLookup(rt, global, lookup, atom_id, new_value);
}

fn globalWritableDataStoreIndexForFastPath(
    rt: *core.JSRuntime,
    lexicals: ?*core.Object,
    global: *core.Object,
    function: *const bytecode.Bytecode,
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
    function: *const bytecode.Bytecode,
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

pub fn globalWritableDataStoreInt32ForFastPath(
    rt: *core.JSRuntime,
    lexicals: ?*core.Object,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    site_pc: usize,
    atom_id: core.Atom,
) ?i32 {
    const lookup = globalWritableDataStoreLookupForFastPath(rt, lexicals, global, function, site_pc, atom_id) orelse return null;
    return lookup.value.asInt32();
}

pub fn globalWritableDataStoreAvailableForFastPath(
    rt: *core.JSRuntime,
    lexicals: ?*core.Object,
    global: *core.Object,
    function: *const bytecode.Bytecode,
    site_pc: usize,
    atom_id: core.Atom,
) bool {
    return globalWritableDataStoreLookupForFastPath(rt, lexicals, global, function, site_pc, atom_id) != null;
}

pub fn setGlobalWritableDataStoreForFastPathOwned(
    rt: *core.JSRuntime,
    lexicals: ?*core.Object,
    global: *core.Object,
    function: *const bytecode.Bytecode,
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
    function: *const bytecode.Bytecode,
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
    const next_value = core.object.dupPropertyDataValue(&rt.atoms, atom_id, new_value);
    const old_slot = slot.entry.slot;
    slot.entry.slot = .{ .data = next_value };
    core.object.destroyPropertySlot(rt, atom_id, data_flags, old_slot);
    return true;
}

fn setGlobalOwnWritableDataPropertyAtOwned(rt: *core.JSRuntime, global: *core.Object, index: usize, atom_id: core.Atom, new_value: core.JSValue) bool {
    const slot = writableDataSlotAt(global, index, atom_id) orelse return false;
    const old_slot = slot.entry.slot;
    slot.entry.slot = .{ .data = new_value };
    core.object.destroyPropertySlot(rt, atom_id, data_flags, old_slot);
    return true;
}

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
    const entry = &object.prop_values[index];
    return .{ .entry = entry, .value = &entry.slot.data };
}

inline fn trustedDataPropertyBorrowedAt(object: *core.Object, index: usize) ?core.JSValue {
    if (index >= object.shape_ref.prop_count) return null;
    if (object.propFlagsAt(index).kind != .data) return null;
    return object.prop_values[index].slot.data;
}

test "fast own data property replacement retains private brand atom" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const object = try core.Object.create(rt, core.class.ids.object, null);
    defer object.value().free(rt);

    const brand = try rt.atoms.newSymbol("fastPrivateBrandReplacement", .private);
    try object.defineOwnProperty(
        rt,
        core.atom.ids.Private_brand,
        core.Descriptor.data(try rt.symbolValue(brand), true, true, true),
    );
    rt.atoms.free(brand);
    try std.testing.expect(rt.atoms.name(brand) != null);

    const lookup = writableOwnDataPropertyLookup(
        object,
        .{ .index = 0, .value = try rt.symbolValue(brand) },
        core.atom.ids.Private_brand,
    ).?;
    try std.testing.expect(try setOwnDataPropertyLookup(rt, object, lookup, core.atom.ids.Private_brand, try rt.symbolValue(brand)));
    try std.testing.expect(rt.atoms.name(brand) != null);
    const stored = object.getProperty(core.atom.ids.Private_brand);
    try std.testing.expectEqual(@as(?core.Atom, brand), stored.asSymbolAtom());
}

test "global own data slot helpers preserve lookup and write ownership" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);

    const name = try rt.internAtom("globalSlotFunction");
    const key = try rt.internAtom("globalSlotAdapter");
    const other_key = try rt.internAtom("globalSlotOther");
    defer rt.atoms.free(name);
    defer rt.atoms.free(key);
    defer rt.atoms.free(other_key);

    const initial = try core.string.String.createAscii(rt, "initial");
    try global.defineOwnProperty(rt, key, core.Descriptor.data(initial.value(), true, true, true));
    initial.value().free(rt);
    try std.testing.expectEqual(@as(i32, 1), initial.header().rc);

    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    function.global_vars = try rt.memory.alloc(bytecode.function_def.GlobalVar, 1);
    function.global_vars[0] = .{ .cpool_idx = -1, .scope_level = 0, .var_name = rt.atoms.dup(key) };

    const lookup = globalOwnDataPropertyBorrowedLookup(global, key).?;
    try std.testing.expectEqual(@as(usize, 0), lookup.index);
    try std.testing.expectEqual(initial.header(), lookup.value.stringHeader().?);
    try std.testing.expectEqual(initial.header(), globalOwnDataPropertyValue(global, key).?.stringHeader().?);
    try std.testing.expect(globalOwnDataPropertyValue(global, other_key) == null);
    try std.testing.expectEqual(initial.header(), globalOwnWritableDataPropertyLookup(global, key).?.value.stringHeader().?);
    const writable_lookup = globalWritableDataPropertyLookupAt(global, lookup.index, key).?;
    try std.testing.expectEqual(lookup.index, writable_lookup.index);
    try std.testing.expectEqual(initial.header(), writable_lookup.value.stringHeader().?);
    try std.testing.expectEqual(@as(?usize, lookup.index), globalWritableDataStoreIndexForFastPath(rt, null, global, &function, 0, key));
    const store_lookup = globalWritableDataStoreLookupForFastPath(rt, null, global, &function, 0, key).?;
    try std.testing.expectEqual(lookup.index, store_lookup.index);
    try std.testing.expectEqual(initial.header(), store_lookup.value.stringHeader().?);
    try std.testing.expectEqual(initial.header(), globalOwnDataPropertyBorrowedAt(global, lookup.index, key).?.stringHeader().?);
    try std.testing.expectEqual(initial.header(), declaredGlobalVarDataBorrowedLookup(global, &function, key).?.value.stringHeader().?);
    try std.testing.expect(declaredGlobalVarDataBorrowedLookup(global, &function, other_key) == null);
    try std.testing.expectEqual(initial.header(), globalDataPropertyLookupForFastPath(rt, global, &function, 0, key).?.value.stringHeader().?);
    try std.testing.expectEqual(initial.header(), globalDataPropertyValueForFastPath(rt, global, &function, 0, key).?.stringHeader().?);
    try std.testing.expectEqual(initial.header(), globalDataPropertyLookupForFastPathNoProfile(rt, global, &function, 0, key).?.value.stringHeader().?);
    try std.testing.expectEqual(initial.header(), globalDataPropertyValueForFastPathNoProfile(rt, global, &function, 0, key).?.stringHeader().?);
    try std.testing.expect(globalDataPropertyLookupForFastPath(rt, global, &function, 0, other_key) == null);
    try std.testing.expect(globalDataPropertyValueForFastPath(rt, global, &function, 0, other_key) == null);

    const lexicals = try core.Object.create(rt, core.class.ids.object, null);
    defer lexicals.value().free(rt);
    try lexicals.defineOwnProperty(rt, key, core.Descriptor.data(core.JSValue.int32(7), true, true, true));
    try std.testing.expect(globalWritableDataStoreIndexForFastPath(rt, lexicals, global, &function, 0, key) == null);
    try std.testing.expect(globalWritableDataStoreLookupForFastPath(rt, lexicals, global, &function, 0, key) == null);
    const shadowed_owned = try core.string.String.createAscii(rt, "shadowed-owned");
    var shadowed_transferred = false;
    errdefer if (!shadowed_transferred) shadowed_owned.value().free(rt);
    const shadowed_store = setGlobalWritableDataStoreForFastPathOwned(rt, lexicals, global, &function, 0, key, shadowed_owned.value());
    if (shadowed_store) shadowed_transferred = true;
    try std.testing.expect(!shadowed_store);
    try std.testing.expectEqual(@as(i32, 1), shadowed_owned.header().rc);
    shadowed_owned.value().free(rt);
    shadowed_transferred = true;

    const copied = copied: {
        const value = try core.string.String.createAscii(rt, "copied");
        errdefer value.value().free(rt);
        try std.testing.expect(setGlobalDataPropertyLookup(rt, global, lookup, key, value.value()));
        break :copied value;
    };
    try std.testing.expectEqual(@as(i32, 2), copied.header().rc);
    copied.value().free(rt);
    try std.testing.expectEqual(@as(i32, 1), copied.header().rc);
    try std.testing.expectEqual(copied.header(), globalOwnDataPropertyBorrowedAt(global, lookup.index, key).?.stringHeader().?);

    const owned = try core.string.String.createAscii(rt, "owned");
    var owned_transferred = false;
    errdefer if (!owned_transferred) owned.value().free(rt);
    try std.testing.expect(setGlobalOwnWritableDataPropertyAtOwned(rt, global, lookup.index, key, owned.value()));
    owned_transferred = true;
    try std.testing.expectEqual(@as(i32, 1), owned.header().rc);
    try std.testing.expectEqual(owned.header(), globalOwnDataPropertyBorrowedAt(global, lookup.index, key).?.stringHeader().?);

    const lookup_owned = try core.string.String.createAscii(rt, "lookup-owned");
    var lookup_transferred = false;
    errdefer if (!lookup_transferred) lookup_owned.value().free(rt);
    const writable_store = globalWritableDataStoreLookupForFastPath(rt, null, global, &function, 0, key).?;
    try std.testing.expect(setGlobalWritableDataStoreLookupOwned(rt, global, writable_store, key, lookup_owned.value()));
    lookup_transferred = true;
    try std.testing.expectEqual(@as(i32, 1), lookup_owned.header().rc);
    try std.testing.expectEqual(lookup_owned.header(), globalOwnDataPropertyBorrowedAt(global, lookup.index, key).?.stringHeader().?);

    const fast_path_owned = try core.string.String.createAscii(rt, "fast-path-owned");
    var fast_path_transferred = false;
    errdefer if (!fast_path_transferred) fast_path_owned.value().free(rt);
    try std.testing.expect(setGlobalWritableDataStoreForFastPathOwned(rt, null, global, &function, 0, key, fast_path_owned.value()));
    fast_path_transferred = true;
    try std.testing.expectEqual(@as(i32, 1), fast_path_owned.header().rc);
    try std.testing.expectEqual(fast_path_owned.header(), globalOwnDataPropertyBorrowedAt(global, lookup.index, key).?.stringHeader().?);
}

test "global own data slot helpers reject readonly and accessor writes" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const global = try core.Object.create(rt, core.class.ids.object, null);
    defer global.value().free(rt);

    const readonly_key = try rt.internAtom("readonlyGlobalSlot");
    const accessor_key = try rt.internAtom("accessorGlobalSlot");
    defer rt.atoms.free(readonly_key);
    defer rt.atoms.free(accessor_key);

    try global.defineOwnProperty(rt, readonly_key, core.Descriptor.data(core.JSValue.int32(1), false, true, true));
    const readonly_lookup = globalOwnDataPropertyBorrowedLookup(global, readonly_key).?;
    try std.testing.expectEqual(@as(?i32, 1), readonly_lookup.value.asInt32());
    try std.testing.expect(globalOwnWritableDataPropertyLookup(global, readonly_key) == null);
    try std.testing.expect(globalWritableDataPropertyLookupAt(global, readonly_lookup.index, readonly_key) == null);
    try std.testing.expect(!setGlobalDataPropertyLookup(rt, global, readonly_lookup, readonly_key, core.JSValue.int32(2)));
    try std.testing.expect(!setGlobalOwnWritableDataPropertyAtOwned(rt, global, readonly_lookup.index, readonly_key, core.JSValue.int32(2)));
    try std.testing.expectEqual(@as(?i32, 1), globalOwnDataPropertyBorrowedAt(global, readonly_lookup.index, readonly_key).?.asInt32());

    // Accessor get/set are stored as object headers (qjs `JSObject*`); use
    // object values (the old loose JSValue accessor cell that allowed string
    // placeholders was replaced by L2's object-header pointers).
    const getter = try core.Object.create(rt, core.class.ids.object, null);
    const setter = try core.Object.create(rt, core.class.ids.object, null);
    try global.defineOwnProperty(rt, accessor_key, core.Descriptor.accessor(getter.value(), setter.value(), true, true));
    getter.value().free(rt);
    setter.value().free(rt);

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
