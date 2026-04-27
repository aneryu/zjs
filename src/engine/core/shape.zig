const atom = @import("atom.zig");
const memory = @import("memory.zig");

pub const initial_prop_size = 2;
pub const initial_hash_size = 4;
pub const initial_shape_hash_bits: u6 = 6;

pub const Property = struct {
    hash_next: u32 = 0,
    flags: u6 = 0,
    atom_id: atom.Atom = atom.null_atom,
};

pub const Shape = struct {
    ref_count: usize = 1,
    is_hashed: bool = false,
    hash: u32 = 0,
    prop_hash_mask: u32 = initial_hash_size - 1,
    prop_count: usize = 0,
    deleted_prop_count: usize = 0,
    proto_id: ?usize = null,
    props: []Property = &.{},

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
};

pub const Registry = struct {
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    shape_hash_bits: u6 = initial_shape_hash_bits,
    shape_hash_count: usize = 0,
    shapes: []*Shape = &.{},
    shapes_capacity: usize = 0,

    pub fn init(account: *memory.MemoryAccount, atoms: *atom.AtomTable) Registry {
        return .{ .memory = account, .atoms = atoms };
    }

    pub fn deinit(self: *Registry) void {
        while (self.shapes.len != 0) {
            self.release(self.shapes[self.shapes.len - 1]);
        }
        if (self.shapes_capacity != 0) self.memory.free(*Shape, self.shapes.ptr[0..self.shapes_capacity]);
        self.shapes = &.{};
        self.shapes_capacity = 0;
    }

    pub fn create(self: *Registry, proto_id: ?usize) !*Shape {
        const shape = try self.memory.create(Shape);
        errdefer self.memory.destroy(Shape, shape);
        shape.* = .{
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

    pub fn addProperty(self: *Registry, shape: *Shape, atom_id: atom.Atom, flags: u6) !void {
        if (shape.prop_count == shape.props.len) try self.grow(shape);
        const retained_atom = self.atoms.dup(atom_id);
        shape.props[shape.prop_count] = .{
            .hash_next = 0,
            .flags = flags,
            .atom_id = retained_atom,
        };
        shape.prop_count += 1;
        shape.hash = transitionHash(shape.hash, atom_id, flags);
    }

    pub fn release(self: *Registry, shape: *Shape) void {
        std.debug.assert(shape.ref_count > 0);
        shape.ref_count -= 1;
        if (shape.ref_count != 0) return;

        self.unlink(shape);
        for (shape.props[0..shape.prop_count]) |prop| {
            if (prop.atom_id != atom.null_atom) self.atoms.free(prop.atom_id);
        }
        self.memory.free(Property, shape.props);
        self.memory.destroy(Shape, shape);
    }

    fn grow(self: *Registry, shape: *Shape) !void {
        const next = try self.memory.alloc(Property, shape.props.len * 2);
        errdefer self.memory.free(Property, next);
        @memset(next, .{});
        @memcpy(next[0..shape.props.len], shape.props);
        self.memory.free(Property, shape.props);
        shape.props = next;
    }

    fn link(self: *Registry, shape: *Shape) !void {
        if (self.shapes.len == self.shapes_capacity) {
            const next_capacity = if (self.shapes_capacity == 0) 4 else self.shapes_capacity * 2;
            const next = try self.memory.alloc(*Shape, next_capacity);
            errdefer self.memory.free(*Shape, next);
            @memcpy(next[0..self.shapes.len], self.shapes);
            if (self.shapes_capacity != 0) self.memory.free(*Shape, self.shapes.ptr[0..self.shapes_capacity]);
            self.shapes = next[0..self.shapes.len];
            self.shapes_capacity = next_capacity;
        }
        const len = self.shapes.len;
        self.shapes = self.shapes.ptr[0 .. len + 1];
        self.shapes[len] = shape;
        self.shape_hash_count += 1;
    }

    fn unlink(self: *Registry, shape: *Shape) void {
        var index: ?usize = null;
        for (self.shapes, 0..) |candidate, i| {
            if (candidate == shape) {
                index = i;
                break;
            }
        }
        const i = index orelse return;
        if (i + 1 < self.shapes.len) {
            std.mem.copyForwards(*Shape, self.shapes[i .. self.shapes.len - 1], self.shapes[i + 1 ..]);
        }
        self.shapes = self.shapes[0 .. self.shapes.len - 1];
        self.shape_hash_count -= 1;
    }
};

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

pub fn shapeHash(seed: u32, value: u32) u32 {
    return (seed +% value) *% 0x9e37_0001;
}

const std = @import("std");
