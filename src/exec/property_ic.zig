const std = @import("std");
const bytecode = @import("../bytecode/root.zig");
const builtins = @import("../builtins/root.zig");
const core = @import("../core/root.zig");
const value_ops = @import("value_ops.zig");

fn objectFromValue(value: core.JSValue) ?*core.Object {
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

const OrdinaryDataPropertyLookup = union(enum) {
    value: core.JSValue,
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

fn cachedOwnDataPropertyValue(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
) ?core.JSValue {
    const object = cacheableOwnDataReceiver(rt, receiver, atom_id) orelse return null;
    const lookup = cachedOwnDataPropertyLookupForObject(function, site_pc, rt, object, atom_id) orelse return null;
    return lookup.value;
}

fn cachedProtoDataPropertyValue(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
) ?core.JSValue {
    const object = cacheableOwnDataReceiver(rt, receiver, atom_id) orelse return null;
    const lookup = cachedProtoDataPropertyLookupForObject(function, site_pc, rt, object, atom_id) orelse return null;
    return lookup.value;
}

pub fn dataPropertyValueForFastPath(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
) ?core.JSValue {
    if (cachedOwnDataPropertyValue(function, site_pc, rt, receiver, atom_id)) |value| return value;
    if (cachedProtoDataPropertyValue(function, site_pc, rt, receiver, atom_id)) |value| return value;
    switch (fastOwnOrdinaryDataPropertyLookup(rt, receiver, atom_id)) {
        .value => |lookup| {
            installOwnDataIc(function, site_pc, rt, receiver, atom_id, lookup.index);
            return lookup.value;
        },
        .missing, .slow => {},
    }
    switch (fastImmediatePrototypeDataPropertyLookup(rt, receiver, atom_id)) {
        .value => |lookup| {
            installProtoDataIc(function, site_pc, rt, receiver, atom_id, lookup.holder, lookup.index);
            return lookup.value;
        },
        .missing, .slow => {},
    }
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
    const object = functionOwnDataPropertyObject(rt, value, atom_id) orelse return null;
    if (object.exotic != null) return null;

    if (cachedOwnDataPropertyLookupForObjectNoProfile(function, site_pc, object, atom_id)) |lookup| {
        return nativeBuiltinRefFromFunctionValue(lookup.value);
    }

    for (object.properties, 0..) |entry, index| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        if (entry.flags.accessor) return null;
        switch (entry.slot) {
            .data => |stored| {
                const native_ref = nativeBuiltinRefFromFunctionValue(stored) orelse return null;
                installOwnDataIcForObject(function, site_pc, rt, object, atom_id, index);
                return native_ref;
            },
            .auto_init => {
                const materialized = object.getProperty(atom_id);
                defer materialized.free(rt);
                const native_ref = nativeBuiltinRefFromFunctionValue(materialized) orelse return null;
                if (index < object.properties.len) {
                    const current = object.properties[index];
                    if (!current.flags.deleted and
                        !current.flags.accessor and
                        current.atom_id == atom_id)
                    {
                        switch (current.slot) {
                            .data => installOwnDataIcForObject(function, site_pc, rt, object, atom_id, index),
                            .auto_init, .accessor, .deleted => {},
                        }
                    }
                }
                return native_ref;
            },
            .accessor, .deleted => return null,
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

fn installOwnDataIc(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
    index: usize,
) void {
    const object = cacheableOwnDataReceiver(rt, receiver, atom_id) orelse return;
    installOwnDataIcForObject(function, site_pc, rt, object, atom_id, index);
}

fn installOwnDataIcAfterWrite(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
) void {
    switch (fastOwnOrdinaryDataPropertyLookup(rt, receiver, atom_id)) {
        .value => |lookup| installOwnDataIc(function, site_pc, rt, receiver, atom_id, lookup.index),
        .missing, .slow => {},
    }
}

fn installProtoDataIc(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
    holder: *core.Object,
    index: usize,
) void {
    const object = cacheableOwnDataReceiver(rt, receiver, atom_id) orelse return;
    if (!cacheableNamedDataObject(rt, holder, atom_id)) return;
    const slot = icSlot(function, site_pc) orelse return;
    recordOwnDataIcInstall(rt, slot.installProtoData(&rt.shapes, object, holder, atom_id, index));
}

pub fn setObjectDataPropertyForPutFieldFastPath(
    rt: *core.JSRuntime,
    function: *const bytecode.Bytecode,
    site_pc: usize,
    receiver: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
) !bool {
    if (try setCachedOwnDataProperty(rt, function, site_pc, receiver, atom_id, value)) return true;
    if (try setObjectDataPropertyForSimplePutField(rt, receiver, atom_id, value)) {
        installOwnDataIcAfterWrite(function, site_pc, rt, receiver, atom_id);
        return true;
    }
    return false;
}

fn setCachedOwnDataProperty(
    rt: *core.JSRuntime,
    function: *const bytecode.Bytecode,
    site_pc: usize,
    receiver: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
) !bool {
    const object = cacheableOwnDataReceiver(rt, receiver, atom_id) orelse return false;
    const cached = cachedOwnDataPropertyLookupForObject(function, site_pc, rt, object, atom_id) orelse return false;
    return try setOwnDataPropertyLookup(rt, object, cached, atom_id, value);
}

fn setObjectDataPropertyForSimplePutField(rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom, value: core.JSValue) !bool {
    if (rt.atoms.kind(atom_id) == .private) return false;
    const object = objectFromValue(receiver) orelse return false;
    if (object.proxyTarget() != null or object.exotic != null) return false;
    if (builtins.buffer.isTypedArrayObject(object)) return false;
    if (object.flags.is_array) {
        if (atom_id == core.atom.ids.length or core.array.arrayIndexFromAtom(&rt.atoms, atom_id) != null) return false;
    }
    if (object.class_id == core.class.ids.regexp and atom_id == core.atom.ids.lastIndex and object.regexpLastIndex() != null) return false;
    return try object.setOrDefineOwnDataPropertyForSimpleSet(rt, atom_id, value);
}

fn cachedOwnDataPropertyLookupForObject(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    object: *core.Object,
    atom_id: core.Atom,
) ?BorrowedOwnDataLookup {
    const slot = icSlot(function, site_pc) orelse return null;
    const index = switch (slot.lookupOwnDataResult(object, atom_id)) {
        .hit => |index| index,
        .miss => {
            recordOwnDataIcMiss(rt);
            return null;
        },
        .invalidated => {
            recordOwnDataIcInvalidate(rt);
            return null;
        },
    };
    const value = ownDataPropertyBorrowedAt(object, index, atom_id) orelse {
        recordOwnDataIcInvalidate(rt);
        return null;
    };
    recordOwnDataIcHit(rt);
    return .{ .index = index, .value = value };
}

fn cachedOwnDataPropertyLookupForObjectNoProfile(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    object: *core.Object,
    atom_id: core.Atom,
) ?BorrowedOwnDataLookup {
    const slot = icSlot(function, site_pc) orelse return null;
    const index = switch (slot.lookupOwnDataResult(object, atom_id)) {
        .hit => |index| index,
        .miss, .invalidated => return null,
    };
    const value = ownDataPropertyBorrowedAt(object, index, atom_id) orelse return null;
    return .{ .index = index, .value = value };
}

fn cachedProtoDataPropertyLookupForObject(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    object: *core.Object,
    atom_id: core.Atom,
) ?BorrowedProtoDataLookup {
    const slot = icSlot(function, site_pc) orelse return null;
    const hit = switch (slot.lookupProtoDataResult(object, atom_id)) {
        .hit => |hit| hit,
        .miss => {
            recordOwnDataIcMiss(rt);
            return null;
        },
        .invalidated => {
            recordOwnDataIcInvalidate(rt);
            return null;
        },
    };
    const value = ownDataPropertyBorrowedAt(hit.holder, hit.slot_index, atom_id) orelse {
        recordOwnDataIcInvalidate(rt);
        return null;
    };
    recordOwnDataIcHit(rt);
    return .{ .holder = hit.holder, .index = hit.slot_index, .value = value };
}

fn installOwnDataIcForObject(
    function: *const bytecode.Bytecode,
    site_pc: usize,
    rt: *core.JSRuntime,
    object: *core.Object,
    atom_id: core.Atom,
    index: usize,
) void {
    if (rt.atoms.kind(atom_id) == .private) return;
    const slot = icSlot(function, site_pc) orelse return;
    recordOwnDataIcInstall(rt, slot.installOwnData(&rt.shapes, object, atom_id, index));
}

fn recordOwnDataIcHit(rt: *core.JSRuntime) void {
    const profile = rt.opcode_profile orelse return;
    profile.recordIcHit(core.profile.activeOpcode());
}

fn recordOwnDataIcMiss(rt: *core.JSRuntime) void {
    const profile = rt.opcode_profile orelse return;
    profile.recordIcMiss(core.profile.activeOpcode());
}

fn recordOwnDataIcInvalidate(rt: *core.JSRuntime) void {
    const profile = rt.opcode_profile orelse return;
    profile.recordIcInvalidate(core.profile.activeOpcode());
}

fn recordOwnDataIcInstall(rt: *core.JSRuntime, result: bytecode.ic.InstallResult) void {
    _ = rt;
    const profile = core.profile.active() orelse return;
    const opcode = core.profile.activeOpcode();
    switch (result) {
        .unchanged, .installed_mono, .updated => {},
        .promoted_poly => profile.recordIcPromotePoly(opcode),
        .promoted_mega => profile.recordIcPromoteMega(opcode),
    }
}

fn icSlot(function: *const bytecode.Bytecode, site_pc: usize) ?*bytecode.ic.Slot {
    return function.icSlotForPc(site_pc);
}

fn cacheableOwnDataReceiver(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?*core.Object {
    if (rt.atoms.kind(atom_id) == .private) return null;
    const object = objectFromValue(value) orelse return null;
    if (!cacheableNamedDataObject(rt, object, atom_id)) return null;
    return object;
}

fn cacheableNamedDataObject(rt: *core.JSRuntime, object: *core.Object, atom_id: core.Atom) bool {
    if (object.proxyTarget() != null or object.exotic != null) return false;
    if (object.flags.is_array) {
        if (atom_id == core.atom.ids.length or core.array.arrayIndexFromAtom(&rt.atoms, atom_id) != null) return false;
    } else if (object.class_id != core.class.ids.object and !object.flags.is_global and object.class_id < core.class.ids.init_count) return false;
    return true;
}

fn fastOwnOrdinaryDataPropertyLookup(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) FastOwnDataLookup {
    const object = cacheableOwnDataReceiver(rt, value, atom_id) orelse return .slow;
    return fastOwnOrdinaryDataPropertyLookupForObject(object, atom_id);
}

fn fastImmediatePrototypeDataPropertyLookup(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) FastProtoDataLookup {
    const object = cacheableOwnDataReceiver(rt, value, atom_id) orelse return .slow;
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
    for (object.properties, 0..) |*entry, index| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        if (entry.flags.accessor) return .slow;
        return switch (entry.slot) {
            .data => |stored| .{ .value = .{ .index = index, .value = stored } },
            .auto_init, .accessor => .slow,
            .deleted => .missing,
        };
    }
    return .missing;
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
    if (object.proxyTarget() != null or object.exotic != null) return false;
    return object.class_id == core.class.ids.object and !object.flags.is_array and !object.flags.is_global;
}

pub fn ownDataPropertyValueMaterializedForFastPath(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    if (rt.atoms.kind(atom_id) == .private) return null;
    const object = objectFromValue(value) orelse return null;
    if (object.proxyTarget() != null or object.exotic != null) return null;
    if (object.class_id != core.class.ids.object and !object.flags.is_global) return null;

    switch (fastOwnOrdinaryDataPropertyBorrowedValue(object, atom_id)) {
        .value => |stored| return stored,
        .missing => return null,
        .slow => {},
    }

    const desc = object.getOwnProperty(atom_id) orelse return null;
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

fn setOwnDataPropertyAt(rt: *core.JSRuntime, object: *core.Object, index: usize, atom_id: core.Atom, value: core.JSValue) !bool {
    const slot = writableDataSlotAt(object, index, atom_id) orelse return false;
    if (atom_id != core.atom.ids.Private_brand and !slot.value.requiresRefCount() and !value.requiresRefCount()) {
        slot.value.* = value;
        return true;
    }
    const next_value = core.object.dupPropertyDataValue(&rt.atoms, atom_id, value);
    errdefer core.object.destroyPropertySlot(rt, slot.entry.atom_id, .{ .data = next_value });
    const old_value = slot.value.*;
    slot.value.* = next_value;
    core.object.destroyPropertySlot(rt, slot.entry.atom_id, .{ .data = old_value });
    return true;
}

fn fastOwnOrdinaryDataPropertyBorrowedValue(object: *core.Object, atom_id: core.Atom) FastOwnDataResult {
    for (object.properties) |*entry| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        if (entry.flags.accessor) return .slow;
        return switch (entry.slot) {
            .data => |stored| .{ .value = stored },
            .auto_init, .accessor => .slow,
            .deleted => .missing,
        };
    }
    return .missing;
}

fn ordinaryDataPropertyLookup(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) OrdinaryDataPropertyLookup {
    if (rt.atoms.kind(atom_id) == .private) return .slow;
    var cursor = objectFromValue(value) orelse return .slow;
    while (true) {
        if (cursor.proxyTarget() != null or cursor.exotic != null) return .slow;
        if (cursor.flags.is_array) {
            if (atom_id == core.atom.ids.length or core.array.arrayIndexFromAtom(&rt.atoms, atom_id) != null) return .slow;
        } else if (cursor.class_id != core.class.ids.object and !cursor.flags.is_global) return .slow;
        switch (fastOwnOrdinaryDataPropertyBorrowedValue(cursor, atom_id)) {
            .value => |property_value| return .{ .value = property_value },
            .missing => cursor = cursor.getPrototype() orelse {
                if (cursor.flags.is_array) return .slow;
                return .undefined;
            },
            .slow => return .slow,
        }
    }
}

pub fn ordinaryDataPropertyBorrowedValueForFastPath(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    return switch (ordinaryDataPropertyLookup(rt, value, atom_id)) {
        .value => |property_value| property_value,
        .undefined, .slow => null,
    };
}

pub fn ordinaryDataPropertyValueOrUndefinedForFastPath(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    return switch (ordinaryDataPropertyLookup(rt, value, atom_id)) {
        .value => |property_value| property_value,
        .undefined => core.JSValue.undefinedValue(),
        .slow => null,
    };
}

pub fn ordinaryDataPropertyIsUndefinedForFastPath(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?bool {
    return switch (ordinaryDataPropertyLookup(rt, value, atom_id)) {
        .value => |property_value| property_value.isUndefined(),
        .undefined => true,
        .slow => null,
    };
}

fn declaredGlobalVarDataBorrowedLookup(global: *core.Object, function: *const bytecode.Bytecode, atom_id: core.Atom) ?BorrowedGlobalDataLookup {
    for (function.global_var_names) |name| {
        if (name != atom_id) continue;
        return globalOwnDataPropertyBorrowedLookup(global, atom_id);
    }
    return null;
}

fn globalOwnDataPropertyBorrowedLookup(global: *core.Object, atom_id: core.Atom) ?BorrowedGlobalDataLookup {
    if (global.exotic != null) return null;
    for (global.properties, 0..) |*entry, index| {
        if (entry.flags.deleted or entry.atom_id != atom_id) continue;
        if (entry.flags.accessor) return null;
        return switch (entry.slot) {
            .data => |stored| .{ .index = index, .value = stored },
            .auto_init, .accessor, .deleted => null,
        };
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
    if (cachedOwnDataPropertyLookupForObject(function, site_pc, rt, global, atom_id)) |cached| {
        return .{ .index = cached.index, .value = cached.value };
    }
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
    if (cachedOwnDataPropertyLookupForObjectNoProfile(function, site_pc, global, atom_id)) |cached| {
        return .{ .index = cached.index, .value = cached.value };
    }
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
    if (lexicals) |env| {
        if (env.hasOwnProperty(atom_id)) return null;
    }
    if (cachedOwnDataPropertyLookupForObject(function, site_pc, rt, global, atom_id)) |cached| {
        return globalWritableDataPropertyLookupAt(global, cached.index, atom_id);
    }
    if (declaredGlobalVarDataBorrowedLookup(global, function, atom_id)) |lookup| {
        const writable = globalWritableDataPropertyLookupAt(global, lookup.index, atom_id) orelse return null;
        installOwnDataIcForObject(function, site_pc, rt, global, atom_id, lookup.index);
        return writable;
    }
    const lookup = globalOwnDataPropertyBorrowedLookup(global, atom_id) orelse return null;
    const writable = globalWritableDataPropertyLookupAt(global, lookup.index, atom_id) orelse return null;
    installOwnDataIcForObject(function, site_pc, rt, global, atom_id, lookup.index);
    return writable;
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
    if (declaredGlobalVarDataBorrowedLookup(global, function, atom_id)) |lookup| {
        installOwnDataIcForObject(function, site_pc, rt, global, atom_id, lookup.index);
        return lookup;
    }
    const lookup = globalOwnDataPropertyBorrowedLookup(global, atom_id) orelse return null;
    installOwnDataIcForObject(function, site_pc, rt, global, atom_id, lookup.index);
    return lookup;
}

fn setGlobalOwnWritableDataPropertyAt(rt: *core.JSRuntime, global: *core.Object, index: usize, atom_id: core.Atom, new_value: core.JSValue) bool {
    const slot = writableDataSlotAt(global, index, atom_id) orelse return false;
    const next_value = core.object.dupPropertyDataValue(&rt.atoms, atom_id, new_value);
    const old_slot = slot.entry.slot;
    slot.entry.slot = .{ .data = next_value };
    core.object.destroyPropertySlot(rt, slot.entry.atom_id, old_slot);
    return true;
}

fn setGlobalOwnWritableDataPropertyAtOwned(rt: *core.JSRuntime, global: *core.Object, index: usize, atom_id: core.Atom, new_value: core.JSValue) bool {
    const slot = writableDataSlotAt(global, index, atom_id) orelse return false;
    const old_slot = slot.entry.slot;
    slot.entry.slot = .{ .data = new_value };
    core.object.destroyPropertySlot(rt, slot.entry.atom_id, old_slot);
    return true;
}

fn writableDataSlotAt(object: *core.Object, index: usize, atom_id: core.Atom) ?DataSlot {
    const slot = dataSlotAt(object, index, atom_id) orelse return null;
    if (!slot.entry.flags.writable) return null;
    return slot;
}

fn globalWritableDataPropertyLookupAt(global: *core.Object, index: usize, atom_id: core.Atom) ?WritableGlobalDataStore {
    const slot = writableDataSlotAt(global, index, atom_id) orelse return null;
    return .{ .index = index, .value = slot.value.* };
}

fn dataSlotAt(object: *core.Object, index: usize, atom_id: core.Atom) ?DataSlot {
    if (object.exotic != null or index >= object.properties.len) return null;
    const entry = &object.properties[index];
    if (entry.atom_id != atom_id or entry.flags.deleted or entry.flags.accessor) return null;
    return switch (entry.slot) {
        .data => |*stored| .{ .entry = entry, .value = stored },
        .auto_init, .accessor, .deleted => null,
    };
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
        core.Descriptor.data(core.JSValue.symbol(brand), true, true, true),
    );
    rt.atoms.free(brand);
    try std.testing.expect(rt.atoms.name(brand) != null);

    const lookup = writableOwnDataPropertyLookup(
        object,
        .{ .index = 0, .value = core.JSValue.symbol(brand) },
        core.atom.ids.Private_brand,
    ).?;
    try std.testing.expect(try setOwnDataPropertyLookup(rt, object, lookup, core.atom.ids.Private_brand, core.JSValue.symbol(brand)));
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
    try std.testing.expectEqual(@as(i32, 1), initial.header.rc);

    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name);
    defer function.deinit(rt);
    function.global_var_names = try rt.memory.alloc(core.Atom, 1);
    function.global_var_names[0] = rt.atoms.dup(key);

    const lookup = globalOwnDataPropertyBorrowedLookup(global, key).?;
    try std.testing.expectEqual(@as(usize, 0), lookup.index);
    try std.testing.expectEqual(&initial.header, lookup.value.refHeader().?);
    try std.testing.expectEqual(&initial.header, globalOwnDataPropertyValue(global, key).?.refHeader().?);
    try std.testing.expect(globalOwnDataPropertyValue(global, other_key) == null);
    try std.testing.expectEqual(&initial.header, globalOwnWritableDataPropertyLookup(global, key).?.value.refHeader().?);
    const writable_lookup = globalWritableDataPropertyLookupAt(global, lookup.index, key).?;
    try std.testing.expectEqual(lookup.index, writable_lookup.index);
    try std.testing.expectEqual(&initial.header, writable_lookup.value.refHeader().?);
    try std.testing.expectEqual(@as(?usize, lookup.index), globalWritableDataStoreIndexForFastPath(rt, null, global, &function, 0, key));
    const store_lookup = globalWritableDataStoreLookupForFastPath(rt, null, global, &function, 0, key).?;
    try std.testing.expectEqual(lookup.index, store_lookup.index);
    try std.testing.expectEqual(&initial.header, store_lookup.value.refHeader().?);
    try std.testing.expectEqual(&initial.header, globalOwnDataPropertyBorrowedAt(global, lookup.index, key).?.refHeader().?);
    try std.testing.expectEqual(&initial.header, declaredGlobalVarDataBorrowedLookup(global, &function, key).?.value.refHeader().?);
    try std.testing.expect(declaredGlobalVarDataBorrowedLookup(global, &function, other_key) == null);
    try std.testing.expectEqual(&initial.header, globalDataPropertyLookupForFastPath(rt, global, &function, 0, key).?.value.refHeader().?);
    try std.testing.expectEqual(&initial.header, globalDataPropertyValueForFastPath(rt, global, &function, 0, key).?.refHeader().?);
    try std.testing.expectEqual(&initial.header, globalDataPropertyLookupForFastPathNoProfile(rt, global, &function, 0, key).?.value.refHeader().?);
    try std.testing.expectEqual(&initial.header, globalDataPropertyValueForFastPathNoProfile(rt, global, &function, 0, key).?.refHeader().?);
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
    try std.testing.expectEqual(@as(i32, 1), shadowed_owned.header.rc);
    shadowed_owned.value().free(rt);
    shadowed_transferred = true;

    const copied = copied: {
        const value = try core.string.String.createAscii(rt, "copied");
        errdefer value.value().free(rt);
        try std.testing.expect(setGlobalDataPropertyLookup(rt, global, lookup, key, value.value()));
        break :copied value;
    };
    try std.testing.expectEqual(@as(i32, 2), copied.header.rc);
    copied.value().free(rt);
    try std.testing.expectEqual(@as(i32, 1), copied.header.rc);
    try std.testing.expectEqual(&copied.header, globalOwnDataPropertyBorrowedAt(global, lookup.index, key).?.refHeader().?);

    const owned = try core.string.String.createAscii(rt, "owned");
    var owned_transferred = false;
    errdefer if (!owned_transferred) owned.value().free(rt);
    try std.testing.expect(setGlobalOwnWritableDataPropertyAtOwned(rt, global, lookup.index, key, owned.value()));
    owned_transferred = true;
    try std.testing.expectEqual(@as(i32, 1), owned.header.rc);
    try std.testing.expectEqual(&owned.header, globalOwnDataPropertyBorrowedAt(global, lookup.index, key).?.refHeader().?);

    const lookup_owned = try core.string.String.createAscii(rt, "lookup-owned");
    var lookup_transferred = false;
    errdefer if (!lookup_transferred) lookup_owned.value().free(rt);
    const writable_store = globalWritableDataStoreLookupForFastPath(rt, null, global, &function, 0, key).?;
    try std.testing.expect(setGlobalWritableDataStoreLookupOwned(rt, global, writable_store, key, lookup_owned.value()));
    lookup_transferred = true;
    try std.testing.expectEqual(@as(i32, 1), lookup_owned.header.rc);
    try std.testing.expectEqual(&lookup_owned.header, globalOwnDataPropertyBorrowedAt(global, lookup.index, key).?.refHeader().?);

    const fast_path_owned = try core.string.String.createAscii(rt, "fast-path-owned");
    var fast_path_transferred = false;
    errdefer if (!fast_path_transferred) fast_path_owned.value().free(rt);
    try std.testing.expect(setGlobalWritableDataStoreForFastPathOwned(rt, null, global, &function, 0, key, fast_path_owned.value()));
    fast_path_transferred = true;
    try std.testing.expectEqual(@as(i32, 1), fast_path_owned.header.rc);
    try std.testing.expectEqual(&fast_path_owned.header, globalOwnDataPropertyBorrowedAt(global, lookup.index, key).?.refHeader().?);
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

    const getter = try core.string.String.createAscii(rt, "getter");
    const setter = try core.string.String.createAscii(rt, "setter");
    try global.defineOwnProperty(rt, accessor_key, core.Descriptor.accessor(getter.value(), setter.value(), true, true));
    getter.value().free(rt);
    setter.value().free(rt);

    const accessor_index = accessor_index: {
        for (global.properties, 0..) |entry, index| {
            if (!entry.flags.deleted and entry.atom_id == accessor_key) break :accessor_index index;
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
