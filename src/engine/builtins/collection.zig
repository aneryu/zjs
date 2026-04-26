const core = @import("../core/root.zig");
const function_builtin = @import("function.zig");
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
    const class_id = collectionClassId(kind) orelse return error.UnsupportedCollectionCall;
    const object = try core.Object.create(rt, class_id, null);
    errdefer core.Object.destroyFromHeader(rt, &object.header);
    if (class_id == core.class.ids.map or class_id == core.class.ids.set) try defineIntProperty(rt, object, "size", 0);
    try defineNativeMethods(rt, object, class_id);
    return object.value();
}

/// QuickJS source map: selected Map/Set/WeakMap/WeakSet methods currently
/// covered by smoke fixtures. Storage intentionally remains the existing
/// single-entry transitional representation.
pub fn methodCall(rt: *core.Runtime, object_value: core.Value, method: u32, args: []const core.Value) !core.Value {
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
        else => error.UnsupportedCollectionCall,
    };
}

fn mapSet(rt: *core.Runtime, object: *core.Object, key: core.Value, value: core.Value) !core.Value {
    try defineValueProperty(rt, object, "__map_key", key);
    try defineValueProperty(rt, object, "__map_value", value);
    try defineIntProperty(rt, object, "size", 1);
    return core.Value.undefinedValue();
}

fn mapGet(rt: *core.Runtime, object: *core.Object, key: core.Value) !core.Value {
    if (try collectionKeyMatches(rt, object, key, "__map_key")) return getNamedProperty(rt, object, "__map_value");
    return core.Value.undefinedValue();
}

fn collectionHas(rt: *core.Runtime, object: *core.Object, key: core.Value) !core.Value {
    const prop_name: []const u8 = if (object.class_id == core.class.ids.set or object.class_id == core.class.ids.weakset) "__set_value" else "__map_key";
    return core.Value.boolean(try collectionKeyMatches(rt, object, key, prop_name));
}

fn collectionDelete(rt: *core.Runtime, object: *core.Object, key: core.Value) !core.Value {
    const prop_name: []const u8 = if (object.class_id == core.class.ids.set or object.class_id == core.class.ids.weakset) "__set_value" else "__map_key";
    const matched = try collectionKeyMatches(rt, object, key, prop_name);
    if (matched) {
        try defineValueProperty(rt, object, prop_name, core.Value.undefinedValue());
        if (object.class_id == core.class.ids.map or object.class_id == core.class.ids.weakmap) {
            try defineValueProperty(rt, object, "__map_value", core.Value.undefinedValue());
        }
    }
    try defineIntProperty(rt, object, "size", 0);
    return core.Value.boolean(matched);
}

fn collectionClear(rt: *core.Runtime, object: *core.Object) !core.Value {
    try defineIntProperty(rt, object, "size", 0);
    return core.Value.undefinedValue();
}

fn setAdd(rt: *core.Runtime, object: *core.Object, value: core.Value) !core.Value {
    try defineValueProperty(rt, object, "__set_value", value);
    try defineIntProperty(rt, object, "size", 1);
    return core.Value.undefinedValue();
}

fn collectionKeyMatches(rt: *core.Runtime, object: *core.Object, key: core.Value, property_name: []const u8) !bool {
    const stored = try getNamedProperty(rt, object, property_name);
    defer stored.free(rt);
    return sameValueZero(stored, key);
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

fn getNamedProperty(rt: *core.Runtime, object: *core.Object, name: []const u8) !core.Value {
    const key = try rt.internAtom(name);
    defer rt.atoms.free(key);
    return object.getProperty(key);
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
