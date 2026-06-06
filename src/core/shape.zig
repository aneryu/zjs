const atom = @import("atom.zig");
const memory = @import("memory.zig");

pub const initial_prop_size = 4;
pub const initial_hash_size = 4;
pub const initial_shape_hash_bits: u6 = 6;
pub const small_shape_linear_limit = 4;
pub const no_property_hash: u32 = 0;
pub const no_property_index: u32 = std.math.maxInt(u32);
pub const no_registry_index: usize = std.math.maxInt(usize);

pub const Property = struct {
    hash_next: u32 = no_property_index,
    flags: u6 = 0,
    atom_id: atom.Atom = atom.null_atom,
};

pub const Transition = struct {
    atom_id: atom.Atom = atom.null_atom,
    flags: u6 = 0,
    child: *Shape,
};

pub const Shape = struct {
    ref_count: usize = 1,
    is_hashed: bool = false,
    is_transition_cacheable: bool = false,
    parent: ?*Shape = null,
    transition_atom: atom.Atom = atom.null_atom,
    transition_flags: u6 = 0,
    version: u32 = 0,
    hash: u32 = 0,
    registry_index: usize = no_registry_index,
    registry_hash_next: ?*Shape = null,
    prop_hash_mask: u32 = no_property_hash,
    prop_count: usize = 0,
    deleted_prop_count: usize = 0,
    proto_id: ?usize = null,
    hash_buckets: []u32 = &.{},
    props: []Property = &.{},
    transitions: []Transition = &.{},
    transitions_capacity: usize = 0,

    pub fn retain(self: *Shape) void {
        self.ref_count += 1;
    }

    pub fn sameTransition(self: Shape, other: Shape) bool {
        if (self.proto_id != other.proto_id or self.prop_count != other.prop_count) return false;
        for (self.props[0..self.prop_count], other.props[0..other.prop_count]) |a, b| {
            if (a.atom_id != b.atom_id or a.flags != b.flags) return false;
        }
        return true;
    }

    pub fn hasPropertyHash(self: Shape) bool {
        return self.prop_hash_mask != no_property_hash and self.hash_buckets.len != 0;
    }

    pub fn firstPropertyIndex(self: Shape, atom_id: atom.Atom) u32 {
        if (!self.hasPropertyHash()) return no_property_index;
        const bucket = propertyBucketIndex(self.hash, atom_id, self.prop_hash_mask);
        return self.hash_buckets[bucket];
    }
};

pub const Registry = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    shape_hash_bits: u6 = initial_shape_hash_bits,
    shape_hash_count: usize = 0,
    shape_hash_buckets: []?*Shape = &.{},
    shapes: []*Shape = &.{},
    shapes_capacity: usize = 0,

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable) Registry {
        return .{ .memory = account, .atoms = atoms };
    }

    pub fn deinit(self: *Registry) void {
        for (self.shapes) |shape| {
            const transitions: []Transition = if (shape.transitions_capacity != 0) shape.transitions.ptr[0..shape.transitions_capacity] else shape.transitions[0..0];
            const transition_atom = shape.transition_atom;
            const props = shape.props;
            const prop_count = shape.prop_count;
            const hash_buckets = shape.hash_buckets;

            shape.transitions = &.{};
            shape.transitions_capacity = 0;
            shape.transition_atom = atom.null_atom;
            shape.props = &.{};
            shape.prop_count = 0;
            shape.deleted_prop_count = 0;
            shape.hash_buckets = &.{};
            shape.prop_hash_mask = no_property_hash;

            if (transitions.len != 0) self.memory.free(Transition, transitions);
            if (transition_atom != atom.null_atom) self.atoms.free(transition_atom);
            for (props[0..prop_count]) |prop| {
                if (prop.atom_id != atom.null_atom) self.atoms.free(prop.atom_id);
            }
            if (hash_buckets.len != 0) self.memory.free(u32, hash_buckets);
            self.memory.free(Property, props);
            self.memory.destroy(Shape, shape);
        }

        const buckets = self.shape_hash_buckets;
        const shapes: []*Shape = if (self.shapes_capacity != 0) self.shapes.ptr[0..self.shapes_capacity] else self.shapes[0..0];
        self.shape_hash_buckets = &.{};
        self.shapes = &.{};
        self.shapes_capacity = 0;
        if (buckets.len != 0) self.memory.free(?*Shape, buckets);
        if (shapes.len != 0) self.memory.free(*Shape, shapes);
    }

    pub fn create(self: *Registry, proto_id: ?usize) !*Shape {
        return self.createShape(proto_id, false);
    }

    pub fn createObjectRoot(self: *Registry, proto_id: ?usize) !*Shape {
        var current = self.firstShapeWithHash(initialHash(proto_id));
        while (current) |shape| : (current = shape.registry_hash_next) {
            if (!shape.is_transition_cacheable) continue;
            if (shape.parent != null or shape.prop_count != 0 or shape.proto_id != proto_id) continue;
            shape.retain();
            return shape;
        }
        return self.createShape(proto_id, true);
    }

    fn createShape(self: *Registry, proto_id: ?usize, is_transition_cacheable: bool) !*Shape {
        const shape = try self.memory.create(Shape);
        errdefer self.memory.destroy(Shape, shape);
        shape.* = .{
            .is_transition_cacheable = is_transition_cacheable,
            .proto_id = proto_id,
            .props = try self.memory.alloc(Property, initial_prop_size),
            .hash = initialHash(proto_id),
        };
        @memset(shape.props, .{});
        errdefer self.memory.free(Property, shape.props);
        try self.link(shape);
        shape.is_hashed = true;
        return shape;
    }

    pub fn transitionProperty(self: *Registry, parent: *Shape, atom_id: atom.Atom, flags: u6) !*Shape {
        if (parent.is_transition_cacheable) {
            for (parent.transitions) |transition| {
                if (transition.atom_id == atom_id and transition.flags == flags) {
                    transition.child.retain();
                    return transition.child;
                }
            }
        }

        const child = try self.cloneShape(parent, parent.proto_id, true, parent.prop_count + 1);
        errdefer self.release(child);
        child.parent = parent;
        parent.retain();
        child.transition_atom = self.atoms.dup(atom_id);
        child.transition_flags = flags;
        try self.appendProperty(child, atom_id, flags);
        const old_hash = child.hash;
        child.hash = transitionHash(parent.hash, atom_id, flags);
        self.rehashShape(child, old_hash);
        child.version = parent.version +% 1;
        child.is_transition_cacheable = true;
        if (parent.is_transition_cacheable) try self.addTransition(parent, atom_id, flags, child);
        return child;
    }

    pub fn cloneForMutation(self: *Registry, source: *Shape) !*Shape {
        const clone = try self.cloneShape(source, source.proto_id, false, source.prop_count);
        clone.version = source.version +% 1;
        return clone;
    }

    pub fn cloneWithPrototype(self: *Registry, source: *Shape, proto_id: ?usize) !*Shape {
        const clone = try self.cloneShape(source, proto_id, false, source.prop_count);
        const old_hash = clone.hash;
        clone.hash = initialHash(proto_id);
        for (clone.props[0..clone.prop_count]) |prop| {
            clone.hash = transitionHash(clone.hash, prop.atom_id, prop.flags);
        }
        self.rehashShape(clone, old_hash);
        clone.version = source.version +% 1;
        return clone;
    }

    pub fn updatePrototype(self: *Registry, shape: *Shape, proto_id: ?usize) void {
        const old_hash = shape.hash;
        shape.proto_id = proto_id;
        shape.hash = initialHash(proto_id);
        for (shape.props[0..shape.prop_count]) |prop| {
            shape.hash = transitionHash(shape.hash, prop.atom_id, prop.flags);
        }
        self.rehashShape(shape, old_hash);
        shape.version +%= 1;
    }

    pub fn addProperty(self: *Registry, shape: *Shape, atom_id: atom.Atom, flags: u6) !void {
        try self.appendProperty(shape, atom_id, flags);
        const old_hash = shape.hash;
        shape.hash = transitionHash(shape.hash, atom_id, flags);
        self.rehashShape(shape, old_hash);
        shape.version +%= 1;
    }

    pub fn markPropertyDeleted(self: *Registry, shape: *Shape, index: usize, flags: u6) void {
        _ = self;
        std.debug.assert(index < shape.prop_count);
        shape.props[index].flags = flags;
        shape.deleted_prop_count += 1;
        shape.version +%= 1;
    }

    pub fn updatePropertyFlags(self: *Registry, shape: *Shape, index: usize, flags: u6) void {
        _ = self;
        std.debug.assert(index < shape.prop_count);
        if (shape.props[index].flags == flags) return;
        shape.props[index].flags = flags;
        shape.version +%= 1;
    }

    pub fn bumpVersion(self: *Registry, shape: *Shape) void {
        _ = self;
        shape.version +%= 1;
    }

    pub fn reserveProperties(self: *Registry, shape: *Shape, needed: usize) !void {
        if (needed <= shape.props.len) return;
        var next_capacity = shape.props.len;
        while (next_capacity < needed) : (next_capacity *= 2) {}
        const next = try self.memory.alloc(Property, next_capacity);
        errdefer self.memory.free(Property, next);
        @memset(next, .{});
        @memcpy(next[0..shape.props.len], shape.props);
        const old_props = shape.props;
        shape.props = next;
        self.memory.free(Property, old_props);
    }

    pub fn reservePropertyHash(self: *Registry, shape: *Shape, needed: usize) !void {
        if (needed < small_shape_linear_limit) return;
        const minimum = needed + shape.deleted_prop_count;
        if (shape.hasPropertyHash() and minimum <= shape.prop_hash_mask + 1) return;
        try self.rebuildPropertyHash(shape, @max(initial_hash_size, nextPowerOfTwo(minimum + 1)));
    }

    pub fn release(self: *Registry, shape: *Shape) void {
        std.debug.assert(shape.ref_count > 0);
        shape.ref_count -= 1;
        if (shape.ref_count != 0) return;

        self.unlink(shape);
        if (shape.parent) |parent| {
            self.removeTransition(parent, shape);
            self.release(parent);
        }
        const transitions: []Transition = if (shape.transitions_capacity != 0) shape.transitions.ptr[0..shape.transitions_capacity] else shape.transitions[0..0];
        const transition_atom = shape.transition_atom;
        const props = shape.props;
        const prop_count = shape.prop_count;
        const hash_buckets = shape.hash_buckets;
        shape.transitions = &.{};
        shape.transitions_capacity = 0;
        shape.transition_atom = atom.null_atom;
        shape.props = &.{};
        shape.prop_count = 0;
        shape.deleted_prop_count = 0;
        shape.hash_buckets = &.{};
        shape.prop_hash_mask = no_property_hash;
        if (transitions.len != 0) self.memory.free(Transition, transitions);
        if (transition_atom != atom.null_atom) self.atoms.free(transition_atom);
        for (props[0..prop_count]) |prop| {
            if (prop.atom_id != atom.null_atom) self.atoms.free(prop.atom_id);
        }
        if (hash_buckets.len != 0) self.memory.free(u32, hash_buckets);
        self.memory.free(Property, props);
        self.memory.destroy(Shape, shape);
    }

    fn cloneShape(
        self: *Registry,
        source: *Shape,
        proto_id: ?usize,
        is_transition_cacheable: bool,
        needed: usize,
    ) !*Shape {
        const capacity = @max(initial_prop_size, needed);
        const shape = try self.memory.create(Shape);
        errdefer self.memory.destroy(Shape, shape);
        shape.* = .{
            .is_transition_cacheable = is_transition_cacheable,
            .version = source.version,
            .hash = source.hash,
            .prop_count = source.prop_count,
            .deleted_prop_count = source.deleted_prop_count,
            .proto_id = proto_id,
            .props = try self.memory.alloc(Property, capacity),
        };
        errdefer self.memory.free(Property, shape.props);
        errdefer if (shape.hash_buckets.len != 0) self.memory.free(u32, shape.hash_buckets);
        @memset(shape.props, .{});
        for (source.props[0..source.prop_count], 0..) |prop, index| {
            shape.props[index] = .{
                .hash_next = no_property_index,
                .flags = prop.flags,
                .atom_id = if (prop.atom_id == atom.null_atom) atom.null_atom else self.atoms.dup(prop.atom_id),
            };
        }
        errdefer self.freePropertyAtoms(shape.props[0..shape.prop_count]);
        if (shape.prop_count >= small_shape_linear_limit) try self.rebuildPropertyHash(shape, @max(initial_hash_size, nextPowerOfTwo(shape.prop_count + shape.deleted_prop_count + 1)));
        try self.link(shape);
        shape.is_hashed = true;
        return shape;
    }

    fn appendProperty(self: *Registry, shape: *Shape, atom_id: atom.Atom, flags: u6) !void {
        const old_props = shape.props;
        var grew_props = false;
        if (shape.prop_count == shape.props.len) {
            const next = try self.memory.alloc(Property, shape.props.len * 2);
            errdefer self.memory.free(Property, next);
            @memset(next, .{});
            @memcpy(next[0..shape.props.len], shape.props);
            shape.props = next;
            grew_props = true;
        }

        const retained_atom = self.atoms.dup(atom_id);
        const index = shape.prop_count;
        shape.props[index] = .{
            .hash_next = no_property_index,
            .flags = flags,
            .atom_id = retained_atom,
        };
        shape.prop_count += 1;
        var appended = true;
        errdefer if (appended) {
            shape.prop_count -= 1;
            const appended_atom = shape.props[index].atom_id;
            shape.props[index] = .{};
            if (appended_atom != atom.null_atom) self.atoms.free(appended_atom);
            if (grew_props) {
                const new_props = shape.props;
                shape.props = old_props;
                self.memory.free(Property, new_props);
            }
        };
        const rebuilt = if (shape.prop_count >= small_shape_linear_limit)
            try self.ensurePropertyHash(shape)
        else
            false;
        if (shape.hasPropertyHash() and !rebuilt) self.linkPropertyHash(shape, index);
        if (grew_props) self.memory.free(Property, old_props);
        appended = false;
    }

    fn freePropertyAtoms(self: *Registry, props: []const Property) void {
        for (props) |prop| {
            if (prop.atom_id != atom.null_atom) self.atoms.free(prop.atom_id);
        }
    }

    fn addTransition(self: *Registry, parent: *Shape, atom_id: atom.Atom, flags: u6, child: *Shape) !void {
        if (parent.transitions.len < parent.transitions_capacity) {
            const len = parent.transitions.len;
            parent.transitions = parent.transitions.ptr[0 .. len + 1];
            parent.transitions[len] = .{ .atom_id = atom_id, .flags = flags, .child = child };
            return;
        }
        const next_capacity = if (parent.transitions_capacity == 0) 4 else parent.transitions_capacity * 2;
        const next = try self.memory.alloc(Transition, next_capacity);
        errdefer self.memory.free(Transition, next);
        @memcpy(next[0..parent.transitions.len], parent.transitions);
        next[parent.transitions.len] = .{ .atom_id = atom_id, .flags = flags, .child = child };
        const old_capacity = parent.transitions_capacity;
        const old_transitions: []Transition = if (old_capacity != 0) parent.transitions.ptr[0..old_capacity] else parent.transitions[0..0];
        parent.transitions_capacity = next_capacity;
        parent.transitions = next[0 .. parent.transitions.len + 1];
        if (old_capacity != 0) self.memory.free(Transition, old_transitions);
    }

    fn removeTransition(self: *Registry, parent: *Shape, child: *Shape) void {
        _ = self;
        var i: usize = 0;
        while (i < parent.transitions.len) : (i += 1) {
            if (parent.transitions[i].child != child) continue;
            parent.transitions[i] = parent.transitions[parent.transitions.len - 1];
            parent.transitions = parent.transitions[0 .. parent.transitions.len - 1];
            return;
        }
    }

    fn grow(self: *Registry, shape: *Shape) !void {
        const next = try self.memory.alloc(Property, shape.props.len * 2);
        errdefer self.memory.free(Property, next);
        @memset(next, .{});
        @memcpy(next[0..shape.props.len], shape.props);
        const old_props = shape.props;
        shape.props = next;
        self.memory.free(Property, old_props);
    }

    fn ensurePropertyHash(self: *Registry, shape: *Shape) !bool {
        const minimum = shape.prop_count + shape.deleted_prop_count;
        if (shape.hasPropertyHash() and minimum <= shape.prop_hash_mask + 1) return false;
        var bucket_count: usize = if (shape.hasPropertyHash()) shape.hash_buckets.len * 2 else initial_hash_size;
        while (bucket_count <= minimum) : (bucket_count *= 2) {}
        try self.rebuildPropertyHash(shape, bucket_count);
        return true;
    }

    fn rebuildPropertyHash(self: *Registry, shape: *Shape, bucket_count: usize) !void {
        std.debug.assert(std.math.isPowerOfTwo(bucket_count));
        const buckets = try self.memory.alloc(u32, bucket_count);
        errdefer self.memory.free(u32, buckets);
        @memset(buckets, no_property_index);
        const old_buckets = shape.hash_buckets;
        shape.hash_buckets = buckets;
        shape.prop_hash_mask = @intCast(bucket_count - 1);
        if (old_buckets.len != 0) self.memory.free(u32, old_buckets);
        for (shape.props[0..shape.prop_count], 0..) |*prop, index| {
            prop.hash_next = no_property_index;
            self.linkPropertyHash(shape, index);
        }
        shape.version +%= 1;
    }

    fn linkPropertyHash(self: *Registry, shape: *Shape, index: usize) void {
        _ = self;
        std.debug.assert(shape.hasPropertyHash());
        std.debug.assert(index < shape.prop_count);
        const prop = &shape.props[index];
        const bucket = propertyBucketIndex(shape.hash, prop.atom_id, shape.prop_hash_mask);
        prop.hash_next = shape.hash_buckets[bucket];
        shape.hash_buckets[bucket] = @intCast(index);
    }

    fn link(self: *Registry, shape: *Shape) !void {
        try self.ensureShapeHashCapacity(1);
        if (self.shapes.len == self.shapes_capacity) {
            const next_capacity = if (self.shapes_capacity == 0) 4 else self.shapes_capacity * 2;
            const next = try self.memory.alloc(*Shape, next_capacity);
            errdefer self.memory.free(*Shape, next);
            @memcpy(next[0..self.shapes.len], self.shapes);
            const old_capacity = self.shapes_capacity;
            const old_shapes: []*Shape = if (old_capacity != 0) self.shapes.ptr[0..old_capacity] else self.shapes[0..0];
            self.shapes = next[0..self.shapes.len];
            self.shapes_capacity = next_capacity;
            if (old_capacity != 0) self.memory.free(*Shape, old_shapes);
        }
        const len = self.shapes.len;
        self.shapes = self.shapes.ptr[0 .. len + 1];
        self.shapes[len] = shape;
        shape.registry_index = len;
        self.insertShapeHash(shape);
        self.shape_hash_count += 1;
    }

    fn unlink(self: *Registry, shape: *Shape) void {
        const i = shape.registry_index;
        if (i == no_registry_index or i >= self.shapes.len or self.shapes[i] != shape) return;
        self.removeShapeHash(shape);
        const last_index = self.shapes.len - 1;
        if (i != last_index) {
            const moved = self.shapes[last_index];
            self.shapes[i] = moved;
            moved.registry_index = i;
        }
        self.shapes = self.shapes[0 .. self.shapes.len - 1];
        shape.registry_index = no_registry_index;
        self.shape_hash_count -= 1;
    }

    fn ensureShapeHashCapacity(self: *Registry, additional: usize) !void {
        if (self.shape_hash_buckets.len == 0) {
            const bucket_count = @as(usize, 1) << self.shape_hash_bits;
            self.shape_hash_buckets = try self.memory.alloc(?*Shape, bucket_count);
            @memset(self.shape_hash_buckets, null);
        }
        if (self.shape_hash_count + additional <= self.shape_hash_buckets.len) return;
        if (self.shape_hash_bits == 32) return;
        const next_bits = self.shape_hash_bits + 1;
        const bucket_count = @as(usize, 1) << next_bits;
        const next = try self.memory.alloc(?*Shape, bucket_count);
        errdefer self.memory.free(?*Shape, next);
        @memset(next, null);
        const old_buckets = self.shape_hash_buckets;
        self.shape_hash_buckets = next;
        self.shape_hash_bits = next_bits;
        for (self.shapes) |shape| {
            shape.registry_hash_next = null;
            self.insertShapeHash(shape);
        }
        self.memory.free(?*Shape, old_buckets);
    }

    fn firstShapeWithHash(self: *Registry, hash: u32) ?*Shape {
        if (self.shape_hash_buckets.len == 0) return null;
        return self.shape_hash_buckets[hashIndex(hash, self.shape_hash_bits)];
    }

    fn insertShapeHash(self: *Registry, shape: *Shape) void {
        std.debug.assert(self.shape_hash_buckets.len != 0);
        const bucket = hashIndex(shape.hash, self.shape_hash_bits);
        shape.registry_hash_next = self.shape_hash_buckets[bucket];
        self.shape_hash_buckets[bucket] = shape;
    }

    fn removeShapeHash(self: *Registry, shape: *Shape) void {
        if (!self.removeShapeHashFromBucket(shape, shape.hash)) {
            self.removeShapeHashEverywhere(shape);
        }
    }

    fn rehashShape(self: *Registry, shape: *Shape, old_hash: u32) void {
        if (old_hash == shape.hash) return;
        if (!self.removeShapeHashFromBucket(shape, old_hash)) {
            self.removeShapeHashEverywhere(shape);
        }
        self.insertShapeHash(shape);
    }

    fn removeShapeHashEverywhere(self: *Registry, shape: *Shape) void {
        if (self.shape_hash_buckets.len == 0) return;
        for (self.shape_hash_buckets) |*bucket| {
            var cursor: *?*Shape = bucket;
            while (cursor.*) |candidate| {
                if (candidate == shape) {
                    cursor.* = candidate.registry_hash_next;
                    candidate.registry_hash_next = null;
                    break;
                }
                cursor = &candidate.registry_hash_next;
            }
        }
    }

    fn removeShapeHashFromBucket(self: *Registry, shape: *Shape, hash: u32) bool {
        if (self.shape_hash_buckets.len == 0) return false;
        const bucket = &self.shape_hash_buckets[hashIndex(hash, self.shape_hash_bits)];
        var cursor: *?*Shape = bucket;
        while (cursor.*) |candidate| {
            if (candidate == shape) {
                cursor.* = candidate.registry_hash_next;
                candidate.registry_hash_next = null;
                return true;
            }
            cursor = &candidate.registry_hash_next;
        }
        return false;
    }
};

fn nextPowerOfTwo(value: usize) usize {
    var n: usize = 1;
    while (n < value) : (n *= 2) {}
    return n;
}

pub fn initialHash(proto_id: ?usize) u32 {
    const value: u32 = @truncate(proto_id orelse 0);
    return shapeHash(1, value);
}

pub fn transitionHash(seed: u32, atom_id: atom.Atom, flags: u6) u32 {
    return shapeHash(shapeHash(seed, atom_id), flags);
}

pub fn hashIndex(hash: u32, bits: u6) u32 {
    std.debug.assert(bits > 0 and bits <= 32);
    const shift: u5 = @intCast(31 - (bits - 1));
    return hash >> shift;
}

pub fn propertyBucketIndex(shape_hash: u32, atom_id: atom.Atom, mask: u32) usize {
    std.debug.assert(mask != no_property_hash);
    _ = shape_hash;
    const mixed = shapeHash(0, atom_id);
    return @intCast(mixed & mask);
}

pub fn shapeHash(seed: u32, value: u32) u32 {
    return (seed +% value) *% 0x9e37_0001;
}

const std = @import("std");
