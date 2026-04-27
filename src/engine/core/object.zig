const array = @import("array.zig");
const atom = @import("atom.zig");
const class = @import("class.zig");
const descriptor = @import("descriptor.zig");
const gc = @import("gc.zig");
const property = @import("property.zig");
const shape = @import("shape.zig");
const Runtime = @import("runtime.zig").Runtime;
const Value = @import("value.zig").Value;

pub const Error = error{
    NotExtensible,
    IncompatibleDescriptor,
    ReadOnly,
    AccessorWithoutSetter,
    PrototypeCycle,
    InvalidLength,
};

pub const ExoticMethods = struct {
    get_own_property: ?*const fn (*Object, atom.Atom) ?descriptor.Descriptor = null,
    define_own_property: ?*const fn (*Object, atom.Atom, descriptor.Descriptor) bool = null,
    delete_property: ?*const fn (*Object, atom.Atom) bool = null,
    own_keys: ?*const fn (*Object, *Runtime) anyerror![]atom.Atom = null,
};

pub const ArrayStorageMode = enum {
    dense,
    sparse,
};

pub const CollectionEntry = struct {
    key: Value,
    value: Value,
    active: bool = true,

    pub fn destroy(self: CollectionEntry, rt: *Runtime) void {
        self.key.free(rt);
        self.value.free(rt);
    }
};

pub const WeakCollectionEntry = struct {
    key_identity: usize,
    value: Value,

    pub fn destroy(self: WeakCollectionEntry, rt: *Runtime) void {
        self.value.free(rt);
    }
};

pub const Object = struct {
    header: gc.Header,
    class_id: class.ClassId,
    shape_ref: *shape.Shape,
    prototype: ?*Object = null,
    extensible: bool = true,
    is_array: bool = false,
    is_global: bool = false,
    array_storage_mode: ArrayStorageMode = .dense,
    length: u32 = 0,
    length_writable: bool = true,
    properties: []property.Entry = &.{},
    exotic: ?ExoticMethods = null,
    byte_storage: []u8 = &.{},
    string_data: ?Value = null,
    function_source: ?Value = null,
    collection_entries: []CollectionEntry = &.{},
    weak_collection_entries: []WeakCollectionEntry = &.{},
    iterator_target: ?Value = null,
    iterator_index: usize = 0,
    iterator_kind: u8 = 0,
    weak_constructor: ?*Object = null,

    pub fn create(rt: *Runtime, class_id: class.ClassId, prototype: ?*Object) !*Object {
        const self = try rt.memory.create(Object);
        errdefer rt.memory.destroy(Object, self);
        const proto_id = if (prototype) |proto| @intFromPtr(proto) else null;
        const shape_ref = try rt.shapes.create(proto_id);
        errdefer rt.shapes.release(shape_ref);
        self.* = .{
            .header = .{ .kind = .object },
            .class_id = class_id,
            .shape_ref = shape_ref,
            .prototype = prototype,
        };
        return self;
    }

    pub fn createArray(rt: *Runtime, prototype: ?*Object) !*Object {
        const self = try create(rt, class.ids.array, prototype);
        self.is_array = true;
        return self;
    }

    pub fn value(self: *Object) Value {
        return Value.object(&self.header);
    }

    pub fn destroyFromHeader(rt: *Runtime, header: *gc.Header) void {
        const self: *Object = @fieldParentPtr("header", header);
        for (self.properties) |entry| {
            if (entry.atom_id != atom.null_atom) rt.atoms.free(entry.atom_id);
            entry.slot.destroy(rt);
        }
        if (self.properties.len != 0) rt.memory.free(property.Entry, self.properties);
        if (self.byte_storage.len != 0) rt.memory.free(u8, self.byte_storage);
        if (self.string_data) |stored| stored.free(rt);
        if (self.function_source) |stored| stored.free(rt);
        for (self.collection_entries) |entry| entry.destroy(rt);
        if (self.collection_entries.len != 0) rt.memory.free(CollectionEntry, self.collection_entries);
        for (self.weak_collection_entries) |entry| entry.destroy(rt);
        if (self.weak_collection_entries.len != 0) rt.memory.free(WeakCollectionEntry, self.weak_collection_entries);
        if (self.iterator_target) |stored| stored.free(rt);
        rt.shapes.release(self.shape_ref);
        rt.memory.destroy(Object, self);
    }

    pub fn getPrototype(self: Object) ?*Object {
        return self.prototype;
    }

    pub fn setPrototype(self: *Object, prototype: ?*Object) Error!void {
        var cursor = prototype;
        while (cursor) |candidate| {
            if (candidate == self) return error.PrototypeCycle;
            cursor = candidate.prototype;
        }
        self.prototype = prototype;
        self.shape_ref.proto_id = if (prototype) |proto| @intFromPtr(proto) else null;
    }

    pub fn preventExtensions(self: *Object) void {
        self.extensible = false;
    }

    pub fn isExtensible(self: Object) bool {
        return self.extensible;
    }

    pub fn getOwnProperty(self: Object, atom_id: atom.Atom) ?descriptor.Descriptor {
        if (atom_id == atom.ids.constructor) {
            if (self.weak_constructor) |constructor| return descriptor.Descriptor.data(constructor.value().dup(), true, false, true);
        }
        if (self.exotic) |methods| {
            if (methods.get_own_property) |hook| {
                if (hook(@constCast(&self), atom_id)) |desc| return desc;
            }
        }
        const index = self.findProperty(atom_id) orelse return null;
        const entry = self.properties[index];
        if (entry.flags.deleted) return null;
        return descriptor.Descriptor.fromEntry(entry);
    }

    pub fn hasOwnProperty(self: Object, atom_id: atom.Atom) bool {
        return self.findProperty(atom_id) != null;
    }

    pub fn hasProperty(self: Object, atom_id: atom.Atom) bool {
        if (self.hasOwnProperty(atom_id)) return true;
        if (self.prototype) |proto| return proto.hasProperty(atom_id);
        return false;
    }

    pub fn getProperty(self: Object, atom_id: atom.Atom) Value {
        if (atom_id == atom.ids.constructor) {
            if (self.weak_constructor) |constructor| return constructor.value().dup();
        }
        if (self.findProperty(atom_id)) |index| {
            const entry = self.properties[index];
            return switch (entry.slot) {
                .data => |stored_value| stored_value.dup(),
                .accessor => |accessor| accessor.getter.dup(),
                .deleted => Value.undefinedValue(),
            };
        }
        if (self.prototype) |proto| return proto.getProperty(atom_id);
        return Value.undefinedValue();
    }

    pub fn defineOwnProperty(self: *Object, rt: *Runtime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        if (self.exotic) |methods| {
            if (methods.define_own_property) |hook| {
                if (!hook(self, atom_id, desc)) return error.IncompatibleDescriptor;
                return;
            }
        }

        if (self.is_array and atom_id == atom.ids.length) {
            try self.defineArrayLength(rt, desc);
            return;
        }

        if (self.is_array) {
            if (array.arrayIndexFromAtom(&rt.atoms, atom_id)) |index| {
                if (index >= self.length and !self.length_writable) return error.ReadOnly;
                try self.defineOrdinaryOwnProperty(rt, atom_id, desc);
                if (index >= self.length) self.length = index + 1;
                self.updateArrayStorageMode(index);
                return;
            }
        }

        try self.defineOrdinaryOwnProperty(rt, atom_id, desc);
    }

    pub fn setProperty(self: *Object, rt: *Runtime, atom_id: atom.Atom, new_value: Value) !void {
        if (self.findProperty(atom_id)) |index| {
            var entry = &self.properties[index];
            if (entry.flags.accessor) {
                if (entry.slot.accessor.setter.isUndefined()) return error.AccessorWithoutSetter;
                return;
            }
            if (!entry.flags.writable) return error.ReadOnly;
            entry.slot.destroy(rt);
            entry.slot = .{ .data = new_value.dup() };
            return;
        }

        if (self.prototype) |proto| {
            if (proto.findProperty(atom_id)) |index| {
                const inherited = proto.properties[index];
                if (inherited.flags.accessor and inherited.slot.accessor.setter.isUndefined()) return error.AccessorWithoutSetter;
                if (!inherited.flags.accessor and !inherited.flags.writable) return error.ReadOnly;
            }
        }

        try self.defineOwnProperty(rt, atom_id, descriptor.Descriptor.data(new_value, true, true, true));
    }

    pub fn deleteProperty(self: *Object, rt: *Runtime, atom_id: atom.Atom) bool {
        if (self.exotic) |methods| {
            if (methods.delete_property) |hook| return hook(self, atom_id);
        }

        const index = self.findProperty(atom_id) orelse return true;
        var entry = &self.properties[index];
        if (!entry.flags.configurable) return false;
        entry.slot.destroy(rt);
        entry.slot = .deleted;
        entry.flags.deleted = true;
        entry.flags.accessor = false;
        entry.flags.writable = false;
        return true;
    }

    pub fn ownKeys(self: Object, rt: *Runtime) ![]atom.Atom {
        if (self.exotic) |methods| {
            if (methods.own_keys) |hook| return try hook(@constCast(&self), rt);
        }

        var keys: []atom.Atom = &.{};
        errdefer freeKeys(rt, keys);

        var emitted_indices: usize = 0;
        while (true) {
            var best_index: ?u32 = null;
            var best_atom: atom.Atom = atom.null_atom;
            for (self.properties) |entry| {
                if (entry.flags.deleted) continue;
                const index = array.arrayIndexFromAtom(&rt.atoms, entry.atom_id) orelse continue;
                if (countLowerIndices(self, rt, index) != emitted_indices) continue;
                if (best_index == null or index < best_index.?) {
                    best_index = index;
                    best_atom = entry.atom_id;
                }
            }
            if (best_index == null) break;
            try appendAtom(rt, &keys, best_atom);
            emitted_indices += 1;
        }

        for (self.properties) |entry| {
            if (entry.flags.deleted) continue;
            if (array.arrayIndexFromAtom(&rt.atoms, entry.atom_id) != null) continue;
            if (rt.atoms.kind(entry.atom_id) == .symbol) continue;
            try appendAtom(rt, &keys, entry.atom_id);
        }

        for (self.properties) |entry| {
            if (entry.flags.deleted) continue;
            if (rt.atoms.kind(entry.atom_id) != .symbol) continue;
            try appendAtom(rt, &keys, entry.atom_id);
        }

        return keys;
    }

    pub fn freeKeys(rt: *Runtime, keys: []atom.Atom) void {
        for (keys) |key| rt.atoms.free(key);
        if (keys.len != 0) rt.memory.free(atom.Atom, keys);
    }

    pub fn seal(self: *Object) void {
        self.extensible = false;
        for (self.properties) |*entry| {
            if (!entry.flags.deleted) entry.flags.configurable = false;
        }
    }

    pub fn freeze(self: *Object) void {
        self.seal();
        for (self.properties) |*entry| {
            if (!entry.flags.deleted and !entry.flags.accessor) entry.flags.writable = false;
        }
        if (self.is_array) self.length_writable = false;
    }

    pub fn arrayElementStorageMode(self: Object) ArrayStorageMode {
        return self.array_storage_mode;
    }

    fn defineOrdinaryOwnProperty(self: *Object, rt: *Runtime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        if (self.findProperty(atom_id)) |index| {
            if (!isCompatible(self.properties[index], desc)) return error.IncompatibleDescriptor;
            try self.replaceProperty(rt, index, desc);
            return;
        }

        if (!self.extensible) return error.NotExtensible;
        try self.addProperty(rt, atom_id, desc);
    }

    fn defineArrayLength(self: *Object, rt: *Runtime, desc: descriptor.Descriptor) !void {
        if (desc.kind != .data) return error.IncompatibleDescriptor;
        const new_len_i32 = desc.value.asInt32() orelse return error.InvalidLength;
        if (new_len_i32 < 0) return error.InvalidLength;
        const new_len: u32 = @intCast(new_len_i32);
        if (new_len > self.length and !self.length_writable) return error.ReadOnly;
        if (new_len < self.length) {
            var i = self.properties.len;
            while (i > 0) {
                i -= 1;
                const entry = self.properties[i];
                if (entry.flags.deleted) continue;
                const index = array.arrayIndexFromAtom(&rt.atoms, entry.atom_id) orelse continue;
                if (index >= new_len and !self.deleteProperty(rt, entry.atom_id)) return error.IncompatibleDescriptor;
            }
        }
        self.length = new_len;
        self.recomputeArrayStorageMode(rt);
        if (desc.writable) |writable| self.length_writable = writable;
    }

    fn updateArrayStorageMode(self: *Object, index: u32) void {
        if (!self.is_array) return;
        if (index > self.properties.len * 2 + 8) self.array_storage_mode = .sparse;
    }

    fn recomputeArrayStorageMode(self: *Object, rt: *Runtime) void {
        if (!self.is_array) return;
        self.array_storage_mode = .dense;
        for (self.properties) |entry| {
            if (entry.flags.deleted) continue;
            const index = array.arrayIndexFromAtom(&rt.atoms, entry.atom_id) orelse continue;
            self.updateArrayStorageMode(index);
        }
    }

    fn addProperty(self: *Object, rt: *Runtime, atom_id: atom.Atom, desc: descriptor.Descriptor) !void {
        const entry = try entryFromDescriptor(&rt.atoms, atom_id, desc);
        errdefer entry.slot.destroy(rt);
        const next = try rt.memory.alloc(property.Entry, self.properties.len + 1);
        errdefer rt.memory.free(property.Entry, next);
        @memcpy(next[0..self.properties.len], self.properties);
        next[self.properties.len] = entry;
        if (self.properties.len != 0) rt.memory.free(property.Entry, self.properties);
        self.properties = next;
        try rt.shapes.addProperty(self.shape_ref, atom_id, entry.flags.bits());
    }

    fn replaceProperty(self: *Object, rt: *Runtime, index: usize, desc: descriptor.Descriptor) !void {
        const atom_id = self.properties[index].atom_id;
        var next = try entryFromDescriptor(&rt.atoms, atom_id, mergeDescriptor(self.properties[index], desc));
        errdefer next.slot.destroy(rt);
        self.properties[index].slot.destroy(rt);
        rt.atoms.free(self.properties[index].atom_id);
        self.properties[index] = next;
        self.shape_ref.props[index].flags = next.flags.bits();
    }

    fn findProperty(self: Object, atom_id: atom.Atom) ?usize {
        for (self.properties, 0..) |entry, index| {
            if (!entry.flags.deleted and entry.atom_id == atom_id) return index;
        }
        return null;
    }
};

fn entryFromDescriptor(atoms: *atom.AtomTable, atom_id: atom.Atom, desc: descriptor.Descriptor) !property.Entry {
    const retained_atom = atoms.dup(atom_id);
    return switch (desc.kind) {
        .generic => .{
            .atom_id = retained_atom,
            .flags = property.Flags.data(false, desc.enumerable orelse false, desc.configurable orelse false),
            .slot = .{ .data = Value.undefinedValue() },
        },
        .data => .{
            .atom_id = retained_atom,
            .flags = property.Flags.data(desc.writable orelse false, desc.enumerable orelse false, desc.configurable orelse false),
            .slot = .{ .data = desc.value.dup() },
        },
        .accessor => .{
            .atom_id = retained_atom,
            .flags = property.Flags.accessorFlags(desc.enumerable orelse false, desc.configurable orelse false),
            .slot = .{ .accessor = .{
                .getter = desc.getter.dup(),
                .setter = desc.setter.dup(),
            } },
        },
    };
}

fn isCompatible(current: property.Entry, desc: descriptor.Descriptor) bool {
    if (current.flags.configurable) return true;
    if (desc.configurable orelse false) return false;
    if (desc.enumerable) |enumerable| {
        if (enumerable != current.flags.enumerable) return false;
    }
    if (desc.kind == .generic) return true;

    const current_is_accessor = current.flags.accessor;
    if ((desc.kind == .accessor) != current_is_accessor) return false;
    if (!current_is_accessor and !current.flags.writable) {
        if (desc.writable orelse false) return false;
        if (desc.kind == .data and !sameValue(current.slot.data, desc.value)) return false;
    }
    if (current_is_accessor and desc.kind == .accessor) {
        if (!sameValue(current.slot.accessor.getter, desc.getter)) return false;
        if (!sameValue(current.slot.accessor.setter, desc.setter)) return false;
    }
    return true;
}

fn mergeDescriptor(current: property.Entry, desc: descriptor.Descriptor) descriptor.Descriptor {
    if (desc.kind != .generic) return desc;
    return switch (current.slot) {
        .data => |value| descriptor.Descriptor.data(
            value,
            current.flags.writable,
            desc.enumerable orelse current.flags.enumerable,
            desc.configurable orelse current.flags.configurable,
        ),
        .accessor => |accessor| descriptor.Descriptor.accessor(
            accessor.getter,
            accessor.setter,
            desc.enumerable orelse current.flags.enumerable,
            desc.configurable orelse current.flags.configurable,
        ),
        .deleted => desc,
    };
}

fn sameValue(a: Value, b: Value) bool {
    return a.same(b);
}

fn appendAtom(rt: *Runtime, keys: *[]atom.Atom, atom_id: atom.Atom) !void {
    const next = try rt.memory.alloc(atom.Atom, keys.*.len + 1);
    errdefer rt.memory.free(atom.Atom, next);
    @memcpy(next[0..keys.*.len], keys.*);
    next[keys.*.len] = rt.atoms.dup(atom_id);
    if (keys.*.len != 0) rt.memory.free(atom.Atom, keys.*);
    keys.* = next;
}

fn countLowerIndices(self: Object, rt: *Runtime, index: u32) usize {
    var count: usize = 0;
    for (self.properties) |entry| {
        if (entry.flags.deleted) continue;
        const other = array.arrayIndexFromAtom(&rt.atoms, entry.atom_id) orelse continue;
        if (other < index) count += 1;
    }
    return count;
}
