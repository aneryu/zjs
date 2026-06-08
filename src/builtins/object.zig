const core = @import("../core/root.zig");
const std = @import("std");

pub const EntriesMode = enum {
    keys,
    values,
    entries,
};

const RootedValueCopies = struct {
    values: []core.JSValue,
    roots: []core.runtime.ValueRootValue,

    fn init(rt: *core.JSRuntime, source: []const core.JSValue) !RootedValueCopies {
        const values = try rt.memory.alloc(core.JSValue, source.len);
        errdefer rt.memory.free(core.JSValue, values);
        @memcpy(values, source);

        const roots = try rt.memory.alloc(core.runtime.ValueRootValue, source.len);
        errdefer rt.memory.free(core.runtime.ValueRootValue, roots);
        for (values, 0..) |*value, index| {
            roots[index] = .{ .value = value };
        }

        return .{ .values = values, .roots = roots };
    }

    fn deinit(self: RootedValueCopies, rt: *core.JSRuntime) void {
        rt.memory.free(core.runtime.ValueRootValue, self.roots);
        rt.memory.free(core.JSValue, self.values);
    }
};

pub const StaticMethod = enum(u32) {
    assign = 1,
    create = 2,
    define_property = 3,
    define_properties = 4,
    get_own_property_descriptor = 5,
    get_own_property_descriptors = 6,
    get_own_property_names = 7,
    get_own_property_symbols = 8,
    get_prototype_of = 9,
    has_own = 10,
    is_extensible = 11,
    keys = 12,
    prevent_extensions = 13,
    seal = 14,
    is_sealed = 15,
    is_frozen = 16,
    set_prototype_of = 17,
    values = 18,
    entries = 19,
    is = 20,
    freeze = 21,
    from_entries = 22,
    group_by = 23,
};

pub const PrototypeMethod = enum(u32) {
    to_string = 101,
    to_locale_string = 102,
    value_of = 103,
    has_own_property = 104,
    is_prototype_of = 105,
    property_is_enumerable = 106,
    define_getter = 107,
    define_setter = 108,
    lookup_getter = 109,
    lookup_setter = 110,
};

pub fn staticMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "assign")) return @intFromEnum(StaticMethod.assign);
    if (std.mem.eql(u8, name, "create")) return @intFromEnum(StaticMethod.create);
    if (std.mem.eql(u8, name, "defineProperty")) return @intFromEnum(StaticMethod.define_property);
    if (std.mem.eql(u8, name, "defineProperties")) return @intFromEnum(StaticMethod.define_properties);
    if (std.mem.eql(u8, name, "getOwnPropertyDescriptor")) return @intFromEnum(StaticMethod.get_own_property_descriptor);
    if (std.mem.eql(u8, name, "getOwnPropertyDescriptors")) return @intFromEnum(StaticMethod.get_own_property_descriptors);
    if (std.mem.eql(u8, name, "getOwnPropertyNames")) return @intFromEnum(StaticMethod.get_own_property_names);
    if (std.mem.eql(u8, name, "getOwnPropertySymbols")) return @intFromEnum(StaticMethod.get_own_property_symbols);
    if (std.mem.eql(u8, name, "getPrototypeOf")) return @intFromEnum(StaticMethod.get_prototype_of);
    if (std.mem.eql(u8, name, "hasOwn")) return @intFromEnum(StaticMethod.has_own);
    if (std.mem.eql(u8, name, "isExtensible")) return @intFromEnum(StaticMethod.is_extensible);
    if (std.mem.eql(u8, name, "keys")) return @intFromEnum(StaticMethod.keys);
    if (std.mem.eql(u8, name, "preventExtensions")) return @intFromEnum(StaticMethod.prevent_extensions);
    if (std.mem.eql(u8, name, "seal")) return @intFromEnum(StaticMethod.seal);
    if (std.mem.eql(u8, name, "isSealed")) return @intFromEnum(StaticMethod.is_sealed);
    if (std.mem.eql(u8, name, "isFrozen")) return @intFromEnum(StaticMethod.is_frozen);
    if (std.mem.eql(u8, name, "setPrototypeOf")) return @intFromEnum(StaticMethod.set_prototype_of);
    if (std.mem.eql(u8, name, "values")) return @intFromEnum(StaticMethod.values);
    if (std.mem.eql(u8, name, "entries")) return @intFromEnum(StaticMethod.entries);
    if (std.mem.eql(u8, name, "is")) return @intFromEnum(StaticMethod.is);
    if (std.mem.eql(u8, name, "freeze")) return @intFromEnum(StaticMethod.freeze);
    if (std.mem.eql(u8, name, "fromEntries")) return @intFromEnum(StaticMethod.from_entries);
    if (std.mem.eql(u8, name, "groupBy")) return @intFromEnum(StaticMethod.group_by);
    return null;
}

pub fn staticMethodName(id: u32) ?[]const u8 {
    return switch (id) {
        @intFromEnum(StaticMethod.assign) => "assign",
        @intFromEnum(StaticMethod.create) => "create",
        @intFromEnum(StaticMethod.define_property) => "defineProperty",
        @intFromEnum(StaticMethod.define_properties) => "defineProperties",
        @intFromEnum(StaticMethod.get_own_property_descriptor) => "getOwnPropertyDescriptor",
        @intFromEnum(StaticMethod.get_own_property_descriptors) => "getOwnPropertyDescriptors",
        @intFromEnum(StaticMethod.get_own_property_names) => "getOwnPropertyNames",
        @intFromEnum(StaticMethod.get_own_property_symbols) => "getOwnPropertySymbols",
        @intFromEnum(StaticMethod.get_prototype_of) => "getPrototypeOf",
        @intFromEnum(StaticMethod.has_own) => "hasOwn",
        @intFromEnum(StaticMethod.is_extensible) => "isExtensible",
        @intFromEnum(StaticMethod.keys) => "keys",
        @intFromEnum(StaticMethod.prevent_extensions) => "preventExtensions",
        @intFromEnum(StaticMethod.seal) => "seal",
        @intFromEnum(StaticMethod.is_sealed) => "isSealed",
        @intFromEnum(StaticMethod.is_frozen) => "isFrozen",
        @intFromEnum(StaticMethod.set_prototype_of) => "setPrototypeOf",
        @intFromEnum(StaticMethod.values) => "values",
        @intFromEnum(StaticMethod.entries) => "entries",
        @intFromEnum(StaticMethod.is) => "is",
        @intFromEnum(StaticMethod.freeze) => "freeze",
        @intFromEnum(StaticMethod.from_entries) => "fromEntries",
        @intFromEnum(StaticMethod.group_by) => "groupBy",
        else => null,
    };
}

pub fn prototypeMethodId(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "toString")) return @intFromEnum(PrototypeMethod.to_string);
    if (std.mem.eql(u8, name, "toLocaleString")) return @intFromEnum(PrototypeMethod.to_locale_string);
    if (std.mem.eql(u8, name, "valueOf")) return @intFromEnum(PrototypeMethod.value_of);
    if (std.mem.eql(u8, name, "hasOwnProperty")) return @intFromEnum(PrototypeMethod.has_own_property);
    if (std.mem.eql(u8, name, "isPrototypeOf")) return @intFromEnum(PrototypeMethod.is_prototype_of);
    if (std.mem.eql(u8, name, "propertyIsEnumerable")) return @intFromEnum(PrototypeMethod.property_is_enumerable);
    if (std.mem.eql(u8, name, "__defineGetter__")) return @intFromEnum(PrototypeMethod.define_getter);
    if (std.mem.eql(u8, name, "__defineSetter__")) return @intFromEnum(PrototypeMethod.define_setter);
    if (std.mem.eql(u8, name, "__lookupGetter__")) return @intFromEnum(PrototypeMethod.lookup_getter);
    if (std.mem.eql(u8, name, "__lookupSetter__")) return @intFromEnum(PrototypeMethod.lookup_setter);
    return null;
}

pub fn prototypeMethodOrdinal(id: u32) ?i32 {
    return switch (id) {
        @intFromEnum(PrototypeMethod.to_string) => 1,
        @intFromEnum(PrototypeMethod.to_locale_string) => 2,
        @intFromEnum(PrototypeMethod.value_of) => 3,
        @intFromEnum(PrototypeMethod.has_own_property) => 4,
        @intFromEnum(PrototypeMethod.is_prototype_of) => 5,
        @intFromEnum(PrototypeMethod.property_is_enumerable) => 6,
        @intFromEnum(PrototypeMethod.define_getter) => 7,
        @intFromEnum(PrototypeMethod.define_setter) => 8,
        @intFromEnum(PrototypeMethod.lookup_getter) => 9,
        @intFromEnum(PrototypeMethod.lookup_setter) => 10,
        else => null,
    };
}

pub fn create(rt: *core.JSRuntime, prototype: ?*core.Object) !*core.Object {
    return core.Object.create(rt, core.class.ids.object, prototype);
}

pub fn keys(rt: *core.JSRuntime, object: *core.Object) ![]core.Atom {
    return object.ownKeys(rt);
}

/// QuickJS source map: narrow object-literal helper used by transitional
/// `new_object` bytecode.
pub fn literal(rt: *core.JSRuntime, names: []const core.Atom, values: []const core.JSValue) !core.JSValue {
    if (names.len != values.len) return error.TypeError;
    const rooted = try RootedValueCopies.init(rt, values);
    defer rooted.deinit(rt);
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = rooted.roots,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const object = try core.Object.create(rt, core.class.ids.object, null);
    errdefer core.Object.destroyFromHeader(rt, &object.header);

    for (names, rooted.values) |name, value| {
        try object.defineOwnProperty(rt, name, core.Descriptor.data(value, true, true, true));
    }
    return object.value();
}

test "object literal roots direct function bytecode values while creating object" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const key = try rt.internAtom("value");
    defer rt.atoms.free(key);
    const names = [_]core.Atom{key};

    const fb_slice = try rt.memory.alloc(core.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = core.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-object-literal-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

    var literal_value = core.JSValue.functionBytecode(&fb.header);
    var literal_alive = true;
    defer if (literal_alive) literal_value.free(rt);
    const values = [_]core.JSValue{literal_value};

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const object_value = try literal(rt, &names, &values);
    var object_alive = true;
    defer if (object_alive) object_value.free(rt);
    const object = try expectObject(object_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = object.getProperty(key);
    defer stored.free(rt);
    try std.testing.expect(stored.same(literal_value));

    object_value.free(rt);
    object_alive = false;
    literal_value.free(rt);
    literal_alive = false;

    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

pub fn ownEntriesArray(rt: *core.JSRuntime, value: core.JSValue, mode: EntriesMode) !core.JSValue {
    var rooted_value = value;
    var out_value = core.JSValue.undefinedValue();
    var element_val = core.JSValue.undefinedValue();
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
        .{ .value = &out_value },
        .{ .value = &element_val },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const object = try expectObject(rooted_value);
    const owned_keys = try object.ownKeys(rt);
    defer core.Object.freeKeys(rt, owned_keys);

    const out = try core.Object.createArray(rt, null);
    out_value = out.value();
    errdefer {
        core.Object.destroyFromHeader(rt, &out.header);
        out_value = core.JSValue.undefinedValue();
    }
    var out_index: u32 = 0;
    for (owned_keys) |key| {
        if (rt.atoms.kind(key) == .symbol) continue;
        const desc = object.getOwnProperty(key) orelse continue;
        defer desc.destroy(rt);
        if (!(desc.enumerable orelse false)) continue;
        element_val = switch (mode) {
            .keys => try atomToStringValue(rt, key),
            .values => object.getProperty(key),
            .entries => try entryArrayValue(rt, key, object.getProperty(key)),
        };
        defer {
            element_val.free(rt);
            element_val = core.JSValue.undefinedValue();
        }
        try out.defineOwnProperty(rt, core.atom.atomFromUInt32(out_index), core.Descriptor.data(element_val, true, true, true));
        out_index += 1;
    }
    return out_value;
}

pub fn sameValue(a: core.JSValue, b: core.JSValue) bool {
    return a.sameValue(b);
}

fn expectObject(value: core.JSValue) !*core.Object {
    const header = value.refHeader() orelse return error.TypeError;
    if (!value.isObject()) return error.TypeError;
    return @fieldParentPtr("header", header);
}

fn entryArrayValue(rt: *core.JSRuntime, key: core.Atom, value: core.JSValue) !core.JSValue {
    var rooted_value = value;
    defer rooted_value.free(rt);
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_value },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const array = try core.Object.createArray(rt, null);
    errdefer core.Object.destroyFromHeader(rt, &array.header);
    const key_value = try atomToStringValue(rt, key);
    defer key_value.free(rt);
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(key_value, true, true, true));
    try array.defineOwnProperty(rt, core.atom.atomFromUInt32(1), core.Descriptor.data(rooted_value, true, true, true));
    return array.value();
}

test "object entryArrayValue roots direct function bytecode value while creating entry array" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const key = try rt.internAtom("entryKey");
    defer rt.atoms.free(key);

    const fb_slice = try rt.memory.alloc(core.FunctionBytecode, 1);
    const fb = &fb_slice[0];
    fb.* = core.FunctionBytecode.init(&rt.memory, &rt.atoms, core.atom.ids.empty_string);
    try rt.gc.add(&fb.header);

    const symbol_atom = try rt.atoms.newValueSymbol("gc-object-entry-array-value-bytecode-symbol");
    fb.cpool = try rt.memory.alloc(core.JSValue, 1);
    fb.cpool[0] = core.JSValue.symbol(symbol_atom);
    fb.cpool_count = 1;

    var entry_value = core.JSValue.functionBytecode(&fb.header);
    var entry_value_alive = true;
    defer if (entry_value_alive) entry_value.free(rt);

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const pair_value = try entryArrayValue(rt, key, entry_value.dup());
    var pair_alive = true;
    defer if (pair_alive) pair_value.free(rt);
    const pair = try expectObject(pair_value);

    try std.testing.expect(rt.atoms.name(symbol_atom) != null);
    const stored = pair.getProperty(core.atom.atomFromUInt32(1));
    defer stored.free(rt);
    try std.testing.expect(stored.same(entry_value));

    pair_value.free(rt);
    pair_alive = false;
    entry_value.free(rt);
    entry_value_alive = false;
    _ = rt.runObjectCycleRemoval();
    try std.testing.expect(rt.atoms.name(symbol_atom) == null);
}

fn atomToStringValue(rt: *core.JSRuntime, atom_id: core.Atom) !core.JSValue {
    return rt.atoms.toStringValue(rt, atom_id);
}
