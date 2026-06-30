const atom = @import("atom.zig");
const gc = @import("gc.zig");
const memory = @import("memory.zig");
const Object = @import("object.zig").Object;
const JSRuntime = @import("runtime.zig").JSRuntime;

pub const initial_prop_size = 4;
pub const initial_hash_size = 4;
pub const initial_shape_hash_bits: u6 = 6;
pub const no_property_hash: u32 = 0;
/// End-of-chain / not-found sentinel for the property hash list. Mirrors qjs's
/// 8-byte JSShapeProperty packing (quickjs.c:968 `hash_next:26`): the chain index
/// is a 26-bit field, so the sentinel is `maxInt(u26)` rather than `maxInt(u32)`.
/// Real property indices stay 0-based and are always `< prop_count < maxInt(u26)`.
pub const no_property_index: u26 = std.math.maxInt(u26);

pub fn propertyCapacityForNeeded(needed: usize) usize {
    if (needed == 0) return 0;
    var capacity: usize = initial_prop_size;
    while (capacity < needed) : (capacity *= 2) {}
    return capacity;
}

/// 8-byte property record, bit-for-bit faithful to qjs `JSShapeProperty`
/// (quickjs.c:968-972): `hash_next:26` and `flags:6` share one 32-bit word,
/// followed by the 32-bit atom. `packed struct(u64)` keeps `hash_next`/`flags`/
/// `atom_id` as direct field accesses (no nested `.hf.` rename) while collapsing
/// the prior 12-byte layout to 8. `atom_id` lands at bit offset 32 (byte 4) so a
/// byte-aligned `*u32` is recoverable for GC symbol visiting via a local copy.
pub const Property = packed struct(u64) {
    hash_next: u26 = no_property_index,
    flags: u6 = 0,
    atom_id: atom.Atom = atom.null_atom,
};

const property_storage_alignment = blk: {
    const property_alignment = std.mem.Alignment.of(Property);
    const bucket_alignment = std.mem.Alignment.of(u32);
    break :blk if (property_alignment.compare(.gt, bucket_alignment)) property_alignment else bucket_alignment;
};

const PropertyStorage = struct {
    bytes: []u8 = &.{},
    hash_buckets: []u32 = &.{},
    props: []Property = &.{},
};

pub const Shape = struct {
    pub const gc_kind_tag: u8 = @intFromEnum(gc.GcKind.shape);
    comptime {
        std.debug.assert(@offsetOf(@This(), "header") == 0);
    }
    header: gc.GCObjectHeader = .{},
    is_hashed: bool = false,
    hash: u32 = 0,
    registry_hash_next: ?*Shape = null,
    prop_hash_mask: u32 = no_property_hash,
    prop_count: u32 = 0,
    deleted_prop_count: u32 = 0,
    proto: ?*Object = null,
    property_storage: []u8 = &.{},

    inline fn bucketCount(self: *const Shape) usize {
        return if (self.prop_hash_mask == no_property_hash) 0 else @as(usize, self.prop_hash_mask) + 1;
    }

    pub inline fn hashBuckets(self: *const Shape) []u32 {
        const n = self.bucketCount();
        if (n == 0) return &.{};
        const ptr: [*]u32 = @ptrCast(@alignCast(self.property_storage.ptr));
        return ptr[0..n];
    }

    pub inline fn props(self: *const Shape) []Property {
        if (self.property_storage.len == 0) return &.{};
        const bucket_bytes = @sizeOf(u32) * self.bucketCount();
        const offset = std.mem.alignForward(usize, bucket_bytes, @alignOf(Property));
        const cap = (self.property_storage.len - offset) / @sizeOf(Property);
        const ptr: [*]Property = @ptrCast(@alignCast(self.property_storage.ptr + offset));
        return ptr[0..cap];
    }

    pub fn retain(self: *Shape) void {
        gc.retain(&self.header);
    }

    pub fn refCount(self: *const Shape) usize {
        return @intCast(self.header.metaConst().rc);
    }

    pub fn sameTransition(self: Shape, other: Shape) bool {
        if (self.proto != other.proto or self.prop_count != other.prop_count) return false;
        for (self.props()[0..self.prop_count], other.props()[0..other.prop_count]) |a, b| {
            if (a.atom_id != b.atom_id or a.flags != b.flags) return false;
        }
        return true;
    }

    pub fn hasPropertyHash(self: Shape) bool {
        return self.prop_hash_mask != no_property_hash;
    }

    pub fn firstPropertyIndex(self: Shape, atom_id: atom.Atom) u32 {
        if (!self.hasPropertyHash()) return no_property_index;
        const bucket = propertyBucketIndex(self.hash, atom_id, self.prop_hash_mask);
        return self.hashBuckets()[bucket];
    }

    pub inline fn traceChildEdgesFallible(self: *Shape, rt: *JSRuntime, visitor: anytype) !void {
        _ = rt;
        const Helper = struct {
            inline fn callVisitObject(vis: anytype, obj_ptr: anytype) !void {
                const VisType = @TypeOf(vis);
                const CleanType = comptime if (@typeInfo(VisType) == .pointer) @typeInfo(VisType).pointer.child else VisType;
                if (comptime @hasDecl(CleanType, "visitObject")) {
                    const ReturnType = @typeInfo(@TypeOf(CleanType.visitObject)).@"fn".return_type.?;
                    if (comptime @typeInfo(ReturnType) == .error_union) {
                        try vis.visitObject(obj_ptr);
                    } else {
                        vis.visitObject(obj_ptr);
                    }
                }
            }

            inline fn callVisitShape(vis: anytype, shape_ptr: anytype) !void {
                const VisType = @TypeOf(vis);
                const CleanType = comptime if (@typeInfo(VisType) == .pointer) @typeInfo(VisType).pointer.child else VisType;
                if (comptime @hasDecl(CleanType, "visitShape")) {
                    const ReturnType = @typeInfo(@TypeOf(CleanType.visitShape)).@"fn".return_type.?;
                    if (comptime @typeInfo(ReturnType) == .error_union) {
                        try vis.visitShape(shape_ptr);
                    } else {
                        vis.visitShape(shape_ptr);
                    }
                }
            }
        };

        try Helper.callVisitObject(visitor, &self.proto);
    }

    pub inline fn traceChildEdgesNoFail(self: *Shape, rt: *JSRuntime, visitor: anytype) void {
        self.traceChildEdgesFallible(rt, visitor) catch unreachable;
    }
};

pub const Registry = struct {
    runtime: *JSRuntime,
    memory: *memory.MemoryAccount,
    atoms: *atom.AtomTable,
    gc_registry: *gc.Registry,
    shape_hash_bits: u6 = initial_shape_hash_bits,
    // qjs only counts *hashed* shapes (quickjs.c:388 `shape_hash_count`); every
    // shape lives on the GC object list, never a separate registry array.
    shape_hash_count: usize = 0,
    shape_hash_buckets: []?*Shape = &.{},
    // Total live shapes (hashed + unhashed). qjs has no such counter — it walks
    // gc_obj_list when it needs one — but `memoryUsage()` introspection wants an
    // O(1) read, so we maintain it in `link`/`unlink`.
    live_shape_count: usize = 0,

    pub fn init(runtime: *JSRuntime, account: *memory.MemoryAccount, atoms: *atom.AtomTable, gc_registry: *gc.Registry) Registry {
        return .{ .runtime = runtime, .memory = account, .atoms = atoms, .gc_registry = gc_registry };
    }

    fn allocPropertyStorage(self: *Registry, prop_capacity: usize, bucket_count: usize) !PropertyStorage {
        const layout = try propertyStorageLayout(prop_capacity, bucket_count);
        const bytes = try self.memory.allocAlignedBytes(layout.byte_len, property_storage_alignment);
        errdefer self.memory.freeAlignedBytes(bytes, property_storage_alignment);

        const hash_buckets: []u32 = if (bucket_count == 0)
            &.{}
        else buckets: {
            const ptr: [*]u32 = @ptrCast(@alignCast(bytes.ptr));
            break :buckets ptr[0..bucket_count];
        };

        const props: []Property = if (prop_capacity == 0)
            &.{}
        else props: {
            const ptr: [*]Property = @ptrCast(@alignCast(bytes.ptr + layout.props_offset));
            break :props ptr[0..prop_capacity];
        };

        return .{ .bytes = bytes, .hash_buckets = hash_buckets, .props = props };
    }

    fn freePropertyStorage(self: *Registry, bytes: []u8) void {
        if (bytes.len != 0) self.memory.freeAlignedBytes(bytes, property_storage_alignment);
    }

    pub fn deinit(self: *Registry) void {
        // Live shapes are torn down by `gc.Registry.deinit`, which walks the GC
        // object list — the same way qjs `JS_FreeRuntime` relies on `gc_obj_list`.
        // Here we only release the shape-hash bucket array, mirroring qjs's
        // `js_free_rt(rt, rt->shape_hash)`.
        const buckets = self.shape_hash_buckets;
        self.shape_hash_buckets = &.{};
        self.shape_hash_bits = initial_shape_hash_bits;
        self.shape_hash_count = 0;
        self.live_shape_count = 0;
        if (buckets.len != 0) self.memory.free(?*Shape, buckets);
    }

    pub fn create(self: *Registry, proto: ?*Object) !*Shape {
        return self.createShape(proto);
    }

    pub fn createObjectRoot(self: *Registry, proto: ?*Object) !*Shape {
        var current = self.firstShapeWithHash(initialHash(proto));
        while (current) |shape| : (current = shape.registry_hash_next) {
            if (shape.prop_count != 0 or shape.proto != proto) continue;
            shape.retain();
            return shape;
        }
        return self.createShape(proto);
    }

    pub fn createObjectRootWithPropertyCapacity(self: *Registry, proto: ?*Object, property_capacity: usize) !*Shape {
        if (property_capacity == 0) return self.createObjectRoot(proto);
        return self.createShapeWithPropertyCapacity(proto, property_capacity);
    }

    fn createShape(self: *Registry, proto: ?*Object) !*Shape {
        const shape = try self.memory.create(Shape);
        errdefer self.memory.destroy(Shape, shape);
        shape.header.meta().* = .{ .kind = .shape };
        const storage = try self.allocPropertyStorage(initial_prop_size, initial_hash_size);
        errdefer self.freePropertyStorage(storage.bytes);
        shape.* = .{
            .header = .{},
            .proto = proto,
            .property_storage = storage.bytes,
            .prop_hash_mask = @intCast(initial_hash_size - 1),
            .hash = initialHash(proto),
        };
        @memset(shape.hashBuckets(), no_property_index);
        @memset(shape.props(), .{});
        try self.link(shape, true);
        errdefer self.unlink(shape);
        try self.gc_registry.addWithSize(&shape.header, @sizeOf(Shape));
        if (proto) |object| gc.retain(&object.header);
        return shape;
    }

    fn createShapeWithPropertyCapacity(
        self: *Registry,
        proto: ?*Object,
        property_capacity: usize,
    ) !*Shape {
        std.debug.assert(property_capacity != 0);
        const shape = try self.memory.create(Shape);
        errdefer self.memory.destroy(Shape, shape);
        shape.header.meta().* = .{ .kind = .shape };
        const bucket_count: usize = @max(initial_hash_size, nextPowerOfTwo(property_capacity + 1));
        const storage = try self.allocPropertyStorage(property_capacity, bucket_count);
        errdefer self.freePropertyStorage(storage.bytes);
        shape.* = .{
            .header = .{},
            .proto = proto,
            .property_storage = storage.bytes,
            .prop_hash_mask = if (bucket_count == 0) no_property_hash else @as(u32, @intCast(bucket_count - 1)),
            .hash = initialHash(proto),
        };
        @memset(shape.props(), .{});
        if (shape.hashBuckets().len != 0) {
            @memset(shape.hashBuckets(), no_property_index);
        }
        try self.link(shape, true);
        errdefer self.unlink(shape);
        try self.gc_registry.addWithSize(&shape.header, @sizeOf(Shape));
        if (proto) |object| gc.retain(&object.header);
        return shape;
    }

    pub fn transitionProperty(self: *Registry, parent: *Shape, atom_id: atom.Atom, flags: u6) !*Shape {
        if (self.findHashedShapeProperty(parent, atom_id, flags)) |shape| {
            shape.retain();
            return shape;
        }
        const child = try self.cloneShape(parent, parent.proto, propertyCapacityForNeeded(parent.prop_count + 1), true);
        errdefer self.release(child);
        try self.appendProperty(child, atom_id, flags);
        const old_hash = child.hash;
        child.hash = transitionHash(parent.hash, atom_id, flags);
        self.rehashShape(child, old_hash);
        return child;
    }

    fn findHashedShapeProperty(self: *Registry, parent: *Shape, atom_id: atom.Atom, flags: u6) ?*Shape {
        if (!parent.is_hashed) return null;
        const expected_hash = transitionHash(parent.hash, atom_id, flags);
        const n = parent.prop_count;
        const parent_props = parent.props();
        var current = self.firstShapeWithHash(expected_hash);
        while (current) |candidate| : (current = candidate.registry_hash_next) {
            if (candidate.hash != expected_hash) continue;
            if (candidate.proto != parent.proto) continue;
            if (candidate.prop_count != n + 1) continue;
            const cand_props = candidate.props();
            var matched = true;
            for (0..n) |i| {
                if (cand_props[i].atom_id != parent_props[i].atom_id or cand_props[i].flags != parent_props[i].flags) {
                    matched = false;
                    break;
                }
            }
            if (!matched) continue;
            if (cand_props[n].atom_id != atom_id or cand_props[n].flags != flags) continue;
            return candidate;
        }
        return null;
    }

    pub fn cloneForMutation(self: *Registry, source: *Shape) !*Shape {
        const clone = try self.cloneShape(source, source.proto, source.props().len, false);
        return clone;
    }

    pub fn prepareUpdate(self: *Registry, shape_ptr: **Shape) !void {
        const current = shape_ptr.*;
        if (current.is_hashed and current.header.meta().rc == 1) {
            self.removeShapeHash(current);
            current.is_hashed = false;
            std.debug.assert(self.shape_hash_count != 0);
            self.shape_hash_count -= 1;
            return;
        }
        if (current.header.meta().rc == 1) return;
        const clone = try self.cloneForMutation(current);
        shape_ptr.* = clone;
        self.release(current);
    }

    pub fn replacePrototypeAssumePrepared(self: *Registry, shape: *Shape, proto: ?*Object) ?*Object {
        std.debug.assert(!shape.is_hashed);
        if (shape.proto == proto) return null;
        const old_proto = shape.proto;
        shape.proto = proto;
        const old_hash = shape.hash;
        shape.hash = initialHash(proto);
        for (shape.props()[0..shape.prop_count]) |prop| {
            shape.hash = transitionHash(shape.hash, prop.atom_id, prop.flags);
        }
        self.rehashShape(shape, old_hash);
        return old_proto;
    }

    pub fn addProperty(self: *Registry, shape: *Shape, atom_id: atom.Atom, flags: u6) !void {
        try self.appendProperty(shape, atom_id, flags);
        const old_hash = shape.hash;
        shape.hash = transitionHash(shape.hash, atom_id, flags);
        self.rehashShape(shape, old_hash);
    }

    pub fn markPropertyDeleted(self: *Registry, shape: *Shape, index: usize, flags: u6) void {
        _ = self;
        std.debug.assert(index < shape.prop_count);
        shape.props()[index].flags = flags;
        shape.deleted_prop_count += 1;
    }

    pub fn updatePropertyFlags(self: *Registry, shape: *Shape, index: usize, flags: u6) void {
        _ = self;
        std.debug.assert(index < shape.prop_count);
        if (shape.props()[index].flags == flags) return;
        shape.props()[index].flags = flags;
    }

    pub fn restorePropertyLayout(self: *Registry, shape: *Shape, baseline_props: []const Property, baseline_hash: u32, baseline_deleted_count: usize) !void {
        var target_capacity = if (shape.props().len == 0) initial_prop_size else shape.props().len;
        while (target_capacity < baseline_props.len) : (target_capacity *= 2) {}
        const bucket_count: usize = @max(initial_hash_size, nextPowerOfTwo(baseline_props.len + baseline_deleted_count + 1));
        const storage = try self.allocPropertyStorage(target_capacity, bucket_count);
        errdefer self.freePropertyStorage(storage.bytes);
        @memset(storage.props, .{});
        if (storage.hash_buckets.len != 0) @memset(storage.hash_buckets, no_property_index);
        for (baseline_props, 0..) |prop, index| {
            storage.props[index] = .{
                .hash_next = no_property_index,
                .flags = prop.flags,
                .atom_id = if (prop.atom_id == atom.null_atom) atom.null_atom else self.atoms.dup(prop.atom_id),
            };
        }

        const old_props = shape.props();
        const old_prop_count = shape.prop_count;
        const old_storage = shape.property_storage;
        shape.property_storage = storage.bytes;
        shape.prop_hash_mask = if (bucket_count == 0) no_property_hash else @as(u32, @intCast(bucket_count - 1));
        shape.prop_count = @intCast(baseline_props.len);
        shape.deleted_prop_count = @intCast(baseline_deleted_count);

        const old_hash = shape.hash;
        shape.hash = baseline_hash;
        self.rehashShape(shape, old_hash);

        for (old_props[0..old_prop_count]) |prop| {
            if (prop.atom_id != atom.null_atom) self.atoms.free(prop.atom_id);
        }
        self.freePropertyStorage(old_storage);

        if (shape.hasPropertyHash()) {
            for (shape.props()[0..shape.prop_count], 0..) |*prop, index| {
                prop.hash_next = no_property_index;
                self.linkPropertyHash(shape, index);
            }
        }
    }

    pub fn reserveProperties(self: *Registry, shape: *Shape, needed: usize) !void {
        if (needed <= shape.props().len) return;
        var next_capacity = shape.props().len;
        while (next_capacity < needed) : (next_capacity *= 2) {}
        const storage = try self.allocPropertyStorage(next_capacity, shape.hashBuckets().len);
        errdefer self.freePropertyStorage(storage.bytes);
        @memset(storage.props, .{});
        @memcpy(storage.props[0..shape.props().len], shape.props());
        if (shape.hashBuckets().len != 0) @memcpy(storage.hash_buckets, shape.hashBuckets());
        const old_storage = shape.property_storage;
        shape.property_storage = storage.bytes;
        self.freePropertyStorage(old_storage);
    }

    pub fn reservePropertyHash(self: *Registry, shape: *Shape, needed: usize) !void {
        const minimum = needed + shape.deleted_prop_count;
        if (shape.hasPropertyHash() and minimum <= shape.prop_hash_mask + 1) return;
        try self.rebuildPropertyHash(shape, @max(initial_hash_size, nextPowerOfTwo(minimum + 1)));
    }

    pub fn hasReservedOwnPropertyCapacity(self: *Registry, shape: *const Shape, needed: usize) bool {
        _ = self;
        if (needed > shape.props().len) return false;
        const minimum = needed + shape.deleted_prop_count;
        return shape.hasPropertyHash() and minimum <= shape.prop_hash_mask + 1;
    }

    pub fn release(self: *Registry, shape: *Shape) void {
        std.debug.assert(shape.header.meta().rc > 0);
        shape.header.meta().rc -= 1;
        self.gc_registry.stats.rc_dec += 1;
        if (shape.header.meta().rc != 0) return;

        // During runtime teardown, shapes are destroyed in a single dedicated
        // pass by `gc.Registry.deinit` (which walks the GC object list). If we
        // freed the shape here too, that pass — operating on a snapshot of the
        // list taken before this release — would double-free it. Mirror the
        // deinit guard in `gc.releaseAndDestroy`: only decrement, defer the free.
        if (self.gc_registry.phase == .deinit) return;

        self.destroyShape(shape);
    }

    pub fn destroyFromHeader(self: *Registry, header: *gc.Header) void {
        const shape: *Shape = @alignCast(@fieldParentPtr("header", header));
        self.destroyShape(shape);
    }

    fn destroyShape(self: *Registry, shape: *Shape) void {
        self.gc_registry.unlinkObjectWithBytes(&shape.header, @sizeOf(Shape));
        self.unlink(shape);
        const old_proto = shape.proto;
        const shape_props = shape.props();
        const prop_count = shape.prop_count;
        const property_storage = shape.property_storage;
        shape.proto = null;
        shape.property_storage = &.{};
        shape.prop_count = 0;
        shape.deleted_prop_count = 0;
        shape.prop_hash_mask = no_property_hash;
        if (old_proto) |proto| {
            if (self.gc_registry.phase != .deinit) proto.value().free(self.runtime);
        }
        for (shape_props[0..prop_count]) |prop| {
            if (prop.atom_id != atom.null_atom) self.atoms.free(prop.atom_id);
        }
        self.freePropertyStorage(property_storage);
        self.memory.destroy(Shape, shape);
    }

    fn cloneShape(
        self: *Registry,
        source: *Shape,
        proto: ?*Object,
        needed: usize,
        hashed: bool,
    ) !*Shape {
        const capacity = @max(initial_prop_size, needed);
        const shape = try self.memory.create(Shape);
        errdefer self.memory.destroy(Shape, shape);
        shape.header.meta().* = .{ .kind = .shape };
        const bucket_count: usize = if (source.hashBuckets().len != 0)
            source.hashBuckets().len
        else
            @max(initial_hash_size, nextPowerOfTwo(source.prop_count + source.deleted_prop_count + 1));
        const storage = try self.allocPropertyStorage(capacity, bucket_count);
        errdefer self.freePropertyStorage(storage.bytes);
        shape.* = .{
            .header = .{},
            .hash = source.hash,
            .prop_count = source.prop_count,
            .deleted_prop_count = source.deleted_prop_count,
            .proto = proto,
            .property_storage = storage.bytes,
            .prop_hash_mask = if (bucket_count == 0) no_property_hash else @as(u32, @intCast(bucket_count - 1)),
        };
        @memset(shape.props(), .{});
        if (shape.hashBuckets().len != 0) @memset(shape.hashBuckets(), no_property_index);
        for (source.props()[0..source.prop_count], 0..) |prop, index| {
            shape.props()[index] = .{
                .hash_next = no_property_index,
                .flags = prop.flags,
                .atom_id = if (prop.atom_id == atom.null_atom) atom.null_atom else self.atoms.dup(prop.atom_id),
            };
        }
        errdefer self.freePropertyAtoms(shape.props()[0..shape.prop_count]);
        if (shape.hasPropertyHash()) {
            for (shape.props()[0..shape.prop_count], 0..) |*prop, index| {
                prop.hash_next = no_property_index;
                self.linkPropertyHash(shape, index);
            }
        }
        try self.link(shape, hashed);
        errdefer self.unlink(shape);
        try self.gc_registry.addWithSize(&shape.header, @sizeOf(Shape));
        if (proto) |object| gc.retain(&object.header);
        return shape;
    }

    fn appendProperty(self: *Registry, shape: *Shape, atom_id: atom.Atom, flags: u6) !void {
        const retained_atom = self.atoms.dup(atom_id);
        var retained_atom_owned = true;
        errdefer if (retained_atom_owned) self.atoms.free(retained_atom);
        const old_storage = shape.property_storage;
        var grew_props = false;
        if (shape.prop_count == shape.props().len) {
            const storage = try self.allocPropertyStorage(shape.props().len * 2, shape.hashBuckets().len);
            @memset(storage.props, .{});
            @memcpy(storage.props[0..shape.props().len], shape.props());
            if (shape.hashBuckets().len != 0) @memcpy(storage.hash_buckets, shape.hashBuckets());
            shape.property_storage = storage.bytes;
            grew_props = true;
        }

        const index = shape.prop_count;
        shape.props()[index] = .{
            .hash_next = no_property_index,
            .flags = flags,
            .atom_id = retained_atom,
        };
        retained_atom_owned = false;
        shape.prop_count += 1;
        var appended = true;
        errdefer if (appended) {
            shape.prop_count -= 1;
            const appended_atom = shape.props()[index].atom_id;
            shape.props()[index] = .{};
            if (appended_atom != atom.null_atom) self.atoms.free(appended_atom);
            if (grew_props) {
                const new_storage = shape.property_storage;
                shape.property_storage = old_storage;
                self.freePropertyStorage(new_storage);
            }
        };
        const rebuilt = try self.ensurePropertyHash(shape);
        if (shape.hasPropertyHash() and !rebuilt) self.linkPropertyHash(shape, index);
        if (grew_props) self.freePropertyStorage(old_storage);
        appended = false;
    }

    fn freePropertyAtoms(self: *Registry, props: []const Property) void {
        for (props) |prop| {
            if (prop.atom_id != atom.null_atom) self.atoms.free(prop.atom_id);
        }
    }

    fn ensurePropertyHash(self: *Registry, shape: *Shape) !bool {
        const minimum = shape.prop_count + shape.deleted_prop_count;
        if (shape.hasPropertyHash() and minimum <= shape.prop_hash_mask + 1) return false;
        var bucket_count: usize = if (shape.hasPropertyHash()) shape.hashBuckets().len * 2 else initial_hash_size;
        while (bucket_count <= minimum) : (bucket_count *= 2) {}
        try self.rebuildPropertyHash(shape, bucket_count);
        return true;
    }

    fn rebuildPropertyHash(self: *Registry, shape: *Shape, bucket_count: usize) !void {
        std.debug.assert(std.math.isPowerOfTwo(bucket_count));
        const storage = try self.allocPropertyStorage(shape.props().len, bucket_count);
        errdefer self.freePropertyStorage(storage.bytes);
        @memset(storage.props, .{});
        @memcpy(storage.props[0..shape.props().len], shape.props());
        @memset(storage.hash_buckets, no_property_index);
        const old_storage = shape.property_storage;
        shape.property_storage = storage.bytes;
        shape.prop_hash_mask = @intCast(bucket_count - 1);
        self.freePropertyStorage(old_storage);
        for (shape.props()[0..shape.prop_count], 0..) |*prop, index| {
            prop.hash_next = no_property_index;
            self.linkPropertyHash(shape, index);
        }
    }

    fn linkPropertyHash(self: *Registry, shape: *Shape, index: usize) void {
        _ = self;
        std.debug.assert(shape.hasPropertyHash());
        std.debug.assert(index < shape.prop_count);
        const prop = &shape.props()[index];
        const bucket = propertyBucketIndex(shape.hash, prop.atom_id, shape.prop_hash_mask);
        prop.hash_next = @intCast(shape.hashBuckets()[bucket]);
        shape.hashBuckets()[bucket] = @intCast(index);
    }

    fn link(self: *Registry, shape: *Shape, hashed: bool) !void {
        // Shapes are tracked solely through the GC object list (added by the
        // caller via `gc_registry.addWithSize`), exactly like qjs `add_gc_object`.
        // The only per-shape bookkeeping here is hash-table insertion.
        if (hashed) {
            try self.ensureShapeHashCapacity(1);
            shape.is_hashed = true;
            self.insertShapeHash(shape);
            self.shape_hash_count += 1;
        } else {
            shape.is_hashed = false;
        }
        self.live_shape_count += 1;
    }

    fn unlink(self: *Registry, shape: *Shape) void {
        if (shape.is_hashed) {
            self.removeShapeHash(shape);
            shape.is_hashed = false;
            std.debug.assert(self.shape_hash_count != 0);
            self.shape_hash_count -= 1;
        }
        std.debug.assert(self.live_shape_count != 0);
        self.live_shape_count -= 1;
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
        // Re-link every hashed shape by walking the OLD buckets, not a separate
        // shapes array — faithful to qjs `resize_shape_hash` (quickjs.c:5165).
        const old_buckets = self.shape_hash_buckets;
        for (old_buckets) |bucket| {
            var current = bucket;
            while (current) |shape| {
                const sh_next = shape.registry_hash_next;
                const idx = hashIndex(shape.hash, next_bits);
                shape.registry_hash_next = next[idx];
                next[idx] = shape;
                current = sh_next;
            }
        }
        self.shape_hash_buckets = next;
        self.shape_hash_bits = next_bits;
        self.memory.free(?*Shape, old_buckets);
    }

    fn firstShapeWithHash(self: *Registry, hash: u32) ?*Shape {
        if (self.shape_hash_buckets.len == 0) return null;
        return self.shape_hash_buckets[hashIndex(hash, self.shape_hash_bits)];
    }

    fn insertShapeHash(self: *Registry, shape: *Shape) void {
        std.debug.assert(self.shape_hash_buckets.len != 0);
        const bucket = hashIndex(shape.hash, self.shape_hash_bits);
        const bucket_link = &self.shape_hash_buckets[bucket];
        shape.registry_hash_next = bucket_link.*;
        bucket_link.* = shape;
    }

    fn removeShapeHash(self: *Registry, shape: *Shape) void {
        // qjs shape_hash is singly-linked (quickjs.c:984 `shape_hash_next`);
        // js_shape_hash_unlink re-walks the bucket rather than keeping a back
        // pointer. Re-walk the current-hash bucket, falling back to a full scan
        // if the shape was filed under a stale hash.
        if (!self.removeShapeHashFromBucket(shape, shape.hash)) self.removeShapeHashEverywhere(shape);
    }

    fn rehashShape(self: *Registry, shape: *Shape, old_hash: u32) void {
        if (old_hash == shape.hash) return;
        if (!shape.is_hashed) return;
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

fn propertyStorageLayout(prop_capacity: usize, bucket_count: usize) !struct { props_offset: usize, byte_len: usize } {
    const bucket_bytes = std.math.mul(usize, @sizeOf(u32), bucket_count) catch return error.OutOfMemory;
    const props_offset = std.mem.alignForward(usize, bucket_bytes, @alignOf(Property));
    const prop_bytes = std.math.mul(usize, @sizeOf(Property), prop_capacity) catch return error.OutOfMemory;
    const byte_len = std.math.add(usize, props_offset, prop_bytes) catch return error.OutOfMemory;
    return .{ .props_offset = props_offset, .byte_len = byte_len };
}

pub fn initialHash(proto: ?*Object) u32 {
    const value: u32 = @truncate(if (proto) |object| @intFromPtr(object) else 0);
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

pub inline fn propertyBucketIndex(shape_hash: u32, atom_id: atom.Atom, mask: u32) usize {
    std.debug.assert(mask != no_property_hash);
    std.debug.assert(std.math.isPowerOfTwo(@as(usize, mask) + 1));
    _ = shape_hash;
    return @intCast(atom_id & mask);
}

pub fn shapeHash(seed: u32, value: u32) u32 {
    return (seed +% value) *% 0x9e37_0001;
}

const std = @import("std");
