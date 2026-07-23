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

pub const InitialProperty = struct {
    atom_id: atom.Atom,
    flags: u6,
};

/// Byte size of a shape's inline FAM region (hash table + prop array) for a
/// given allocated prop capacity and bucket count. Mirrors qjs get_shape_size
/// minus `sizeof(JSShape)` (quickjs.c:5121): `hash_size*4 + prop_size*8`, with
/// the prop array aligned to 8 after the (4-byte) hash buckets. `prop_size` is
/// u32 and bucket_count derives from a u32 mask, so on 64-bit the products and
/// sum cannot overflow usize.
fn famRegionBytes(prop_capacity: usize, bucket_count: usize) usize {
    const bucket_bytes = @sizeOf(u32) * bucket_count;
    const props_offset = std.mem.alignForward(usize, bucket_bytes, @alignOf(Property));
    return props_offset + @sizeOf(Property) * prop_capacity;
}

pub const Shape = extern struct {
    pub const gc_kind_tag: u8 = @intFromEnum(gc.GcKind.shape);
    comptime {
        // header at offset 0 is load-bearing: BlockHeader.meta() reads ptr-8 and
        // GC tracing recovers the Shape via @fieldParentPtr("header", ...).
        std.debug.assert(@offsetOf(@This(), "header") == 0);
        // Faithful to qjs JSShape (quickjs.c:974, 56B on aarch64): a 16-byte
        // intrusive header, scalar capacity/count fields, shape_hash_next, proto,
        // then the hash table + prop[] inlined as a flexible array member right
        // after the struct fields (qjs get_shape_prop). `prop_size` (allocated
        // prop capacity, qjs JSShape.prop_size) replaces the old 16-byte
        // `property_storage: []u8` slice — the storage is no longer a second
        // heap allocation. `extern` pins the field order so the FAM begins at
        // exactly `@sizeOf(Shape)`.
        std.debug.assert(@sizeOf(@This()) == 56);
    }
    header: gc.GCObjectHeader = .{},
    is_hashed: bool = false,
    hash: u32 = 0,
    prop_hash_mask: u32 = no_property_hash,
    prop_size: u32 = 0,
    prop_count: u32 = 0,
    deleted_prop_count: u32 = 0,
    registry_hash_next: ?*Shape = null,
    proto: ?*Object = null,
    // Inline flexible array member follows at `@sizeOf(Shape)`:
    //   [hash buckets: u32 × bucketCount()] [props: Property × prop_size]
    // Every live shape has a power-of-two bucket count >= 4, so the bucket
    // region is already aligned for the 8-byte Property records.
    // addressed through famBase()/hashBuckets()/props().

    /// Base of the inline FAM region (just past the struct fields). Mirrors qjs
    /// `(uint32_t *)(sh + 1)` (get_shape_prop, quickjs.c:5128).
    inline fn famBase(self: *const Shape) [*]u8 {
        const bytes: [*]u8 = @ptrCast(@constCast(self));
        return bytes + @sizeOf(Shape);
    }

    inline fn bucketCount(self: *const Shape) usize {
        return if (self.prop_hash_mask == no_property_hash) 0 else @as(usize, self.prop_hash_mask) + 1;
    }

    pub inline fn hashBuckets(self: *const Shape) []u32 {
        const n = self.bucketCount();
        if (n == 0) return &.{};
        const ptr: [*]u32 = @ptrCast(@alignCast(self.famBase()));
        return ptr[0..n];
    }

    pub inline fn props(self: *const Shape) []Property {
        // qjs `get_shape_prop` is just `(sh + 1) + hash_size`: its hash table
        // is always large enough to leave the following 8-byte property array
        // aligned. zjs maintains the same invariant in every shape constructor
        // and relocation (bucket_count is a power of two and at least 4).
        // Avoid recomputing a dynamic alignForward on every property lookup.
        std.debug.assert(self.prop_size != 0);
        const bucket_bytes = @sizeOf(u32) * self.bucketCount();
        std.debug.assert(bucket_bytes == std.mem.alignForward(usize, bucket_bytes, @alignOf(Property)));
        const ptr: [*]Property = @ptrCast(@alignCast(self.famBase() + bucket_bytes));
        return ptr[0..self.prop_size];
    }

    /// Byte size of this shape's inline FAM region (hash table + prop array).
    pub inline fn famByteSize(self: *const Shape) usize {
        return famRegionBytes(self.prop_size, self.bucketCount());
    }

    /// Total heap footprint reported to the GC: struct fields + inline FAM,
    /// excluding the 8-byte metadata prefix (consistent with the .object arm's
    /// `Object.allocationSize`). Mirrors qjs `get_shape_size` accounting.
    pub inline fn allocationSize(self: *const Shape) usize {
        return @sizeOf(Shape) + self.famByteSize();
    }

    pub fn retain(self: *Shape) void {
        gc.retain(&self.header);
    }

    pub fn refCount(self: *const Shape) usize {
        return @intCast(self.header.metaConst().rc);
    }

    pub fn sameTransition(self: *const Shape, other: *const Shape) bool {
        if (self.proto != other.proto or self.prop_count != other.prop_count) return false;
        for (self.props()[0..self.prop_count], other.props()[0..other.prop_count]) |a, b| {
            if (a.atom_id != b.atom_id or a.flags != b.flags) return false;
        }
        return true;
    }

    pub fn hasPropertyHash(self: *const Shape) bool {
        return self.prop_hash_mask != no_property_hash;
    }

    pub fn firstPropertyIndex(self: *const Shape, atom_id: atom.Atom) u32 {
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
        var current = self.firstShapeWithHash(initialHash(proto));
        while (current) |shape| : (current = shape.registry_hash_next) {
            // The owning Object allocates a value buffer with exactly this
            // capacity. Reusing a larger root would make shape.prop_size exceed
            // the real buffer length, corrupting later appends and teardown.
            // qjs shape transition reuse likewise requires equal prop_size.
            if (shape.prop_count != 0 or shape.proto != proto or shape.prop_size != property_capacity) continue;
            shape.retain();
            return shape;
        }
        return self.createShapeWithPropertyCapacity(proto, property_capacity);
    }

    /// Build one context-owned initial shape without ever materializing a
    /// hidden template Object. The returned reference belongs to the caller.
    pub fn createInitialShape(self: *Registry, proto: ?*Object, properties: []const InitialProperty) !*Shape {
        // Preserve the object/value-buffer invariant used by mutation clones:
        // every non-empty shape has at least `initial_prop_size` slots.
        var result = try self.createObjectRootWithPropertyCapacity(proto, propertyCapacityForNeeded(properties.len));
        var owned = true;
        errdefer if (owned) self.release(result);
        try self.prepareUpdate(&result);
        for (properties) |prop| try self.addProperty(&result, prop.atom_id, prop.flags);
        owned = false;
        return result;
    }

    fn createShape(self: *Registry, proto: ?*Object) !*Shape {
        // Single GC allocation = struct + inline FAM (qjs js_new_shape).
        // createWithFam initializes metadata once; the constructor initializes
        // the intrusive links before registration below.
        const fam_bytes = famRegionBytes(initial_prop_size, initial_hash_size);
        const shape = try self.memory.createWithFam(Shape, fam_bytes);
        errdefer self.memory.destroyWithFam(Shape, shape, fam_bytes);
        shape.* = .{
            .header = .{},
            .proto = proto,
            .prop_hash_mask = @intCast(initial_hash_size - 1),
            .prop_size = initial_prop_size,
            .hash = initialHash(proto),
        };
        @memset(shape.hashBuckets(), no_property_index);
        @memset(shape.props(), .{});
        try self.link(shape, true);
        errdefer self.unlink(shape);
        try self.gc_registry.addInitializedWithSize(&shape.header, shape.allocationSize());
        if (proto) |object| gc.retain(&object.header);
        return shape;
    }

    fn createShapeWithPropertyCapacity(
        self: *Registry,
        proto: ?*Object,
        property_capacity: usize,
    ) !*Shape {
        std.debug.assert(property_capacity != 0);
        const bucket_count: usize = @max(initial_hash_size, nextPowerOfTwo(property_capacity + 1));
        const fam_bytes = famRegionBytes(property_capacity, bucket_count);
        const shape = try self.memory.createWithFam(Shape, fam_bytes);
        errdefer self.memory.destroyWithFam(Shape, shape, fam_bytes);
        shape.* = .{
            .header = .{},
            .proto = proto,
            .prop_size = @intCast(property_capacity),
            .prop_hash_mask = if (bucket_count == 0) no_property_hash else @as(u32, @intCast(bucket_count - 1)),
            .hash = initialHash(proto),
        };
        @memset(shape.props(), .{});
        if (shape.hashBuckets().len != 0) {
            @memset(shape.hashBuckets(), no_property_index);
        }
        try self.link(shape, true);
        errdefer self.unlink(shape);
        try self.gc_registry.addInitializedWithSize(&shape.header, shape.allocationSize());
        if (proto) |object| gc.retain(&object.header);
        return shape;
    }

    /// Apply a named-property transition to the shape owned by one object.
    ///
    /// Mirrors qjs `add_property`: reuse a cached transition when present,
    /// clone a shared miss, and append an rc==1 miss in place. `shape_ptr` is
    /// threaded through the operation because either the cache/clone branch or
    /// inline-FAM growth can replace the allocation. This function owns every
    /// old-shape release required by a replacement; the in-place branch never
    /// releases the shape whose ownership merely moved during relocation.
    pub fn transitionProperty(self: *Registry, shape_ptr: **Shape, atom_id: atom.Atom, flags: u6, property_capacity: usize) !void {
        const parent = shape_ptr.*;
        if (self.findHashedShapeProperty(parent, atom_id, flags, property_capacity)) |shape| {
            shape.retain();
            shape_ptr.* = shape;
            self.release(parent);
            return;
        }
        if (parent.header.meta().rc != 1) {
            var child = try self.cloneShape(parent, parent.proto, @max(parent.prop_size, property_capacity), true);
            var child_owned = true;
            errdefer if (child_owned) self.release(child);
            // appendProperty may relocate `child` (inline FAM grow moves the
            // shape); thread &child so the fresh pointer flows back before hash.
            try self.appendProperty(&child, atom_id, flags);
            const old_hash = child.hash;
            child.hash = transitionHash(parent.hash, atom_id, flags);
            self.rehashShape(child, old_hash);
            shape_ptr.* = child;
            child_owned = false;
            self.release(parent);
            return;
        }

        // A unique miss is safe to mutate directly. Reserve the final property
        // and deleted-inclusive hash layout in one relocation: after that
        // succeeds appendProperty has no fallible step that could leave a moved
        // shape committed while the owning object's value buffer rolls back.
        const old_hash = parent.hash;
        try self.reservePropertyAppend(shape_ptr, property_capacity);
        try self.appendProperty(shape_ptr, atom_id, flags);
        const shape = shape_ptr.*;
        if (shape.is_hashed) {
            shape.hash = transitionHash(old_hash, atom_id, flags);
            self.rehashShape(shape, old_hash);
        }
    }

    fn findHashedShapeProperty(self: *Registry, parent: *Shape, atom_id: atom.Atom, flags: u6, property_capacity: usize) ?*Shape {
        if (!parent.is_hashed) return null;
        const expected_hash = transitionHash(parent.hash, atom_id, flags);
        const n = parent.prop_count;
        const parent_props = parent.props();
        var current = self.firstShapeWithHash(expected_hash);
        while (current) |candidate| : (current = candidate.registry_hash_next) {
            if (candidate.hash != expected_hash) continue;
            if (candidate.proto != parent.proto) continue;
            if (candidate.prop_count != n + 1) continue;
            if (candidate.prop_size != property_capacity) continue;
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
        const clone = try self.cloneShape(source, source.proto, source.prop_size, false);
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

    /// Grow-by-relocation: the inline FAM cannot grow in place, so a larger
    /// shape requires a brand-new allocation. Mirrors qjs `resize_properties`
    /// (quickjs.c:5334): allocate a NEW block sized for (new_prop_size,
    /// new_bucket_count), copy struct fields + proto/atom ownership + the prop
    /// array, splice the new block into the GC object list and (if hashed) the
    /// shape-hash chain in the OLD shape's place, free the old block, and write
    /// the new pointer back through `shape_ptr`. A fresh allocation (NOT realloc)
    /// is mandatory so a GC triggered mid-allocation never observes a half-moved
    /// shape — the old shape stays fully live and reachable until the swap.
    ///
    /// PRECONDITION (clone-before-mutate, qjs add_property:9223): the shape is
    /// rc==1 with a single `Object.shape_ref` owner = `shape_ptr.*`. Enforced by
    /// the callers' `ensureUniqueShapeForMutation` / `prepareUpdate` gating, so
    /// only that one pointer (plus the GC list + shape-hash chain) needs fixing.
    fn relocateShape(self: *Registry, shape_ptr: **Shape, new_prop_size: u32, new_bucket_count: usize) !void {
        const old = shape_ptr.*;
        std.debug.assert(old.header.meta().rc == 1);
        const old_prop_count = old.prop_count;
        const old_bucket_count = old.bucketCount();
        const old_fam_bytes = old.famByteSize();
        const old_allocation_size = old.allocationSize();

        // The ONLY fallible / GC-triggering step. On failure `shape_ptr.*` (old)
        // is untouched — correct rollback with nothing to undo.
        const new_shape = try self.memory.createWithFam(Shape, famRegionBytes(new_prop_size, new_bucket_count));
        // No further allocation below: the transient two-copy window is GC-safe.

        new_shape.* = .{
            .header = .{},
            .is_hashed = old.is_hashed,
            .hash = old.hash,
            .prop_hash_mask = if (new_bucket_count == 0) no_property_hash else @as(u32, @intCast(new_bucket_count - 1)),
            .prop_size = new_prop_size,
            .prop_count = old_prop_count,
            .deleted_prop_count = old.deleted_prop_count,
            .registry_hash_next = null, // re-established by insertShapeHash below
            .proto = old.proto, // proto ref MOVES to the new shape (old freed w/o proto cleanup)
        };

        // Copy the prop descriptors (atom ownership moves with them).
        const new_props = new_shape.props();
        @memset(new_props, .{});
        @memcpy(new_props[0..old_prop_count], old.props()[0..old_prop_count]);

        // Lay out the hash table: rebuild when the bucket count changed (indices
        // shift with the mask), else copy verbatim (prop indices are preserved).
        const new_buckets = new_shape.hashBuckets();
        if (new_bucket_count == old_bucket_count) {
            if (new_buckets.len != 0) @memcpy(new_buckets, old.hashBuckets());
        } else {
            if (new_buckets.len != 0) @memset(new_buckets, no_property_index);
            if (new_shape.hasPropertyHash()) {
                for (new_props[0..old_prop_count], 0..) |*prop, index| {
                    prop.hash_next = no_property_index;
                    if (prop.atom_id == atom.null_atom) continue;
                    self.linkPropertyHash(new_shape, index);
                }
            }
        }

        // Splice the new block into the registries in the old shape's place.
        if (old.is_hashed) self.removeShapeHash(old);
        self.gc_registry.unlinkObjectWithBytes(&old.header, old_allocation_size);
        // Registration only links/accountes the already initialized header.
        self.gc_registry.addInitializedWithSize(&new_shape.header, new_shape.allocationSize()) catch unreachable;
        if (new_shape.is_hashed) self.insertShapeHash(new_shape);

        // Free the OLD block's raw memory only — proto + atoms have moved.
        self.memory.destroyWithFam(Shape, old, old_fam_bytes);

        shape_ptr.* = new_shape;
    }

    // `inline` collapses the object-literal define stack toward qjs's tight
    // 2-frame add_property -> add_shape_property. zjs's shape-build spans
    // Object.appendPreparedPropertyEntry -> adoptShapeForNewProperty (inlined)
    // -> Registry.addProperty -> Registry.appendProperty; folding this thin
    // hash-transition wrapper and appendProperty into the caller removes the
    // per-property call-frame prologue/epilogue + arg marshaling (3M+ crossings
    // on `o={a,b,c}` loops). Pure codegen hint — semantically identical, faithful
    // to qjs where add_shape_property is a leaf the compiler folds hot.
    pub inline fn addProperty(self: *Registry, shape_ptr: **Shape, atom_id: atom.Atom, flags: u6) !void {
        try self.appendProperty(shape_ptr, atom_id, flags);
        const shape = shape_ptr.*;
        const old_hash = shape.hash;
        shape.hash = transitionHash(shape.hash, atom_id, flags);
        self.rehashShape(shape, old_hash);
    }

    pub fn markPropertyDeleted(self: *Registry, shape: *Shape, index: usize, flags: u6) void {
        std.debug.assert(index < shape.prop_count);
        const props = shape.props();
        const prop = &props[index];
        const removed_atom = prop.atom_id;
        std.debug.assert(removed_atom != atom.null_atom);

        // QuickJS `delete_property` removes the tombstone from the shape hash
        // chain before clearing its atom. Keeping deleted entries linked makes
        // every later `find_own_property` decode and test a deleted flag even
        // though the hash table can never legitimately resolve to a tombstone.
        const bucket = propertyBucketIndex(shape.hash, removed_atom, shape.prop_hash_mask);
        var current = shape.hashBuckets()[bucket];
        var previous: ?usize = null;
        while (current != no_property_index) {
            const current_index: usize = @intCast(current);
            if (current_index == index) {
                if (previous) |previous_index| {
                    props[previous_index].hash_next = prop.hash_next;
                } else {
                    shape.hashBuckets()[bucket] = prop.hash_next;
                }
                break;
            }
            previous = current_index;
            current = props[current_index].hash_next;
        } else unreachable;

        prop.hash_next = no_property_index;
        prop.flags = flags;
        prop.atom_id = atom.null_atom;
        shape.deleted_prop_count += 1;
        self.atoms.free(removed_atom);
    }

    pub fn updatePropertyFlags(self: *Registry, shape: *Shape, index: usize, flags: u6) void {
        _ = self;
        std.debug.assert(index < shape.prop_count);
        if (shape.props()[index].flags == flags) return;
        shape.props()[index].flags = flags;
    }

    pub fn restorePropertyLayout(self: *Registry, shape_ptr: **Shape, baseline_props: []const Property, baseline_hash: u32, baseline_deleted_count: usize) !void {
        const old = shape_ptr.*;
        // The relocation updates only this single owner's pointer (shape_ptr),
        // so the layout being restored must not be shared (qjs clone-before-mutate).
        std.debug.assert(old.header.meta().rc == 1);
        var target_capacity: usize = if (old.prop_size == 0) initial_prop_size else old.prop_size;
        while (target_capacity < baseline_props.len) : (target_capacity *= 2) {}
        // Keep bucket_count >= prop_size (qjs resize_properties invariant): size the
        // table for the deleted-inclusive baseline, then lockstep-grow it to cover
        // the (possibly larger) retained prop capacity so a later append needs no
        // rehash.
        const bucket_count: usize = lockstepBucketCount(
            @max(initial_hash_size, nextPowerOfTwo(baseline_props.len + baseline_deleted_count + 1)),
            target_capacity,
        );

        // Build a fresh shape block holding the baseline layout (dup'd atoms);
        // the inline FAM forces an allocate-new + swap rather than an in-place
        // storage replacement.
        const fam_bytes = famRegionBytes(target_capacity, bucket_count);
        const new_shape = try self.memory.createWithFam(Shape, fam_bytes);
        errdefer self.memory.destroyWithFam(Shape, new_shape, fam_bytes);
        new_shape.* = .{
            .header = .{},
            .is_hashed = old.is_hashed,
            .hash = baseline_hash,
            .prop_hash_mask = if (bucket_count == 0) no_property_hash else @as(u32, @intCast(bucket_count - 1)),
            .prop_size = @intCast(target_capacity),
            .prop_count = @intCast(baseline_props.len),
            .deleted_prop_count = @intCast(baseline_deleted_count),
            .registry_hash_next = null,
            .proto = old.proto, // proto ref moves to the new shape
        };
        @memset(new_shape.props(), .{});
        if (new_shape.hashBuckets().len != 0) @memset(new_shape.hashBuckets(), no_property_index);
        for (baseline_props, 0..) |prop, index| {
            new_shape.props()[index] = .{
                .hash_next = no_property_index,
                .flags = prop.flags,
                .atom_id = if (prop.atom_id == atom.null_atom) atom.null_atom else self.atoms.dup(prop.atom_id),
            };
        }
        errdefer self.freePropertyAtoms(new_shape.props()[0..baseline_props.len]);
        if (new_shape.hasPropertyHash()) {
            for (new_shape.props()[0..new_shape.prop_count], 0..) |*prop, index| {
                prop.hash_next = no_property_index;
                if (prop.atom_id == atom.null_atom) continue;
                self.linkPropertyHash(new_shape, index);
            }
        }

        // Swap registries old->new (no more fallible / GC-triggering ops below).
        if (old.is_hashed) self.removeShapeHash(old);
        self.gc_registry.unlinkObjectWithBytes(&old.header, old.allocationSize());
        self.gc_registry.addInitializedWithSize(&new_shape.header, new_shape.allocationSize()) catch unreachable;
        if (new_shape.is_hashed) self.insertShapeHash(new_shape);

        // Discard the OLD layout: free its prop atoms (NOT carried over) + block.
        const old_fam_bytes = old.famByteSize();
        const old_prop_count = old.prop_count;
        for (old.props()[0..old_prop_count]) |prop| {
            if (prop.atom_id != atom.null_atom) self.atoms.free(prop.atom_id);
        }
        self.memory.destroyWithFam(Shape, old, old_fam_bytes);

        shape_ptr.* = new_shape;
    }

    pub fn reserveProperties(self: *Registry, shape_ptr: **Shape, needed: usize) !void {
        const shape = shape_ptr.*;
        if (needed <= shape.prop_size) return;
        var next_capacity: usize = shape.prop_size;
        while (next_capacity < needed) : (next_capacity *= 2) {}
        // Grow the hash table alongside the prop array (qjs resize_properties,
        // quickjs.c:5354-5356) so bucket_count >= prop_size continues to hold and
        // a subsequent appendProperty needs no hash rebuild.
        try self.relocateShape(shape_ptr, @intCast(next_capacity), lockstepBucketCount(shape.bucketCount(), next_capacity));
    }

    /// Preflight one property append as a single transactional relocation.
    /// `deleted_prop_count` participates in hash capacity even though tombstone
    /// slots remain in `prop_count`; otherwise a property-FAM grow can commit and
    /// a second hash-only grow can fail after the owner has already changed size.
    fn reservePropertyAppend(self: *Registry, shape_ptr: **Shape, requested_property_capacity: usize) !void {
        const shape = shape_ptr.*;
        const post_append_count = @as(usize, shape.prop_count) + 1;
        const needed_properties = @max(requested_property_capacity, post_append_count);

        var property_capacity: usize = if (shape.prop_size == 0) initial_prop_size else shape.prop_size;
        while (property_capacity < needed_properties) : (property_capacity *= 2) {}

        const minimum_hash_capacity = post_append_count + @as(usize, shape.deleted_prop_count);
        var bucket_count = lockstepBucketCount(shape.bucketCount(), property_capacity);
        while (bucket_count < minimum_hash_capacity) : (bucket_count *= 2) {}

        if (property_capacity == shape.prop_size and bucket_count == shape.bucketCount()) return;
        try self.relocateShape(shape_ptr, @intCast(property_capacity), bucket_count);
    }

    pub fn reservePropertyHash(self: *Registry, shape_ptr: **Shape, needed: usize) !void {
        const shape = shape_ptr.*;
        const minimum = needed + shape.deleted_prop_count;
        if (shape.hasPropertyHash() and minimum <= shape.prop_hash_mask + 1) return;
        try self.rebuildPropertyHash(shape_ptr, @max(initial_hash_size, nextPowerOfTwo(minimum + 1)));
    }

    pub fn hasReservedOwnPropertyCapacity(self: *Registry, shape: *const Shape, needed: usize) bool {
        _ = self;
        if (needed > shape.prop_size) return false;
        const minimum = needed + shape.deleted_prop_count;
        return shape.hasPropertyHash() and minimum <= shape.prop_hash_mask + 1;
    }

    pub fn release(self: *Registry, shape: *Shape) void {
        std.debug.assert(shape.header.meta().rc > 0);
        shape.header.meta().rc -= 1;
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
        self.gc_registry.unlinkObjectWithBytes(&shape.header, shape.allocationSize());
        self.unlink(shape);
        // Capture the FAM size + prop atoms while the capacity fields are intact;
        // the inline storage lives in the single block freed below (qjs
        // js_free_shape0 releases atoms + proto, then the one allocation).
        const fam_bytes = shape.famByteSize();
        const old_proto = shape.proto;
        const prop_count = shape.prop_count;
        for (shape.props()[0..prop_count]) |prop| {
            if (prop.atom_id != atom.null_atom) self.atoms.free(prop.atom_id);
        }
        if (old_proto) |proto| {
            if (self.gc_registry.phase != .deinit) proto.value().free(self.runtime);
        }
        self.memory.destroyWithFam(Shape, shape, fam_bytes);
    }

    fn cloneShape(
        self: *Registry,
        source: *Shape,
        proto: ?*Object,
        needed: usize,
        hashed: bool,
    ) !*Shape {
        const capacity: u32 = @intCast(@max(initial_prop_size, needed));
        // qjs js_clone_shape copies hash_size = prop_hash_mask+1 verbatim because
        // the source already satisfies hash_size >= prop_size (resize_properties
        // grows both in lockstep). zjs can bump `capacity` above source.prop_size
        // here (propertyCapacityForNeeded on the transition), so grow the bucket
        // count in lockstep too (resize_properties, quickjs.c:5354-5356) to keep
        // the same bucket_count >= prop_size invariant on the clone.
        const bucket_count: usize = if (source.bucketCount() != 0)
            lockstepBucketCount(source.bucketCount(), capacity)
        else
            lockstepBucketCount(@max(initial_hash_size, nextPowerOfTwo(source.prop_count + source.deleted_prop_count + 1)), capacity);
        // Single contiguous block (struct + inline FAM) = qjs js_clone_shape's
        // js_malloc(get_shape_size(...)) (quickjs.c:5276).
        const fam_bytes = famRegionBytes(capacity, bucket_count);
        const shape = try self.memory.createWithFam(Shape, fam_bytes);
        errdefer self.memory.destroyWithFam(Shape, shape, fam_bytes);
        shape.* = .{
            .header = .{},
            .hash = source.hash,
            .prop_count = source.prop_count,
            .deleted_prop_count = source.deleted_prop_count,
            .proto = proto,
            .prop_size = capacity,
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
                if (prop.atom_id == atom.null_atom) continue;
                self.linkPropertyHash(shape, index);
            }
        }
        try self.link(shape, hashed);
        errdefer self.unlink(shape);
        try self.gc_registry.addInitializedWithSize(&shape.header, shape.allocationSize());
        if (proto) |object| gc.retain(&object.header);
        return shape;
    }

    inline fn appendProperty(self: *Registry, shape_ptr: **Shape, atom_id: atom.Atom, flags: u6) !void {
        // All allocation happens before the atom/property commit. Callers that
        // already preflight a larger owner capacity hit this as a no-op.
        try self.reservePropertyAppend(shape_ptr, @as(usize, shape_ptr.*.prop_count) + 1);

        const retained_atom = self.atoms.dup(atom_id);
        var retained_atom_owned = true;
        errdefer if (retained_atom_owned) self.atoms.free(retained_atom);

        const shape = shape_ptr.*;
        const index = shape.prop_count;
        shape.props()[index] = .{
            .hash_next = no_property_index,
            .flags = flags,
            .atom_id = retained_atom,
        };
        retained_atom_owned = false;
        shape.prop_count += 1;
        // reservePropertyAppend guarantees the deleted-inclusive hash capacity,
        // so linking is infallible and the shape/value-storage commit is atomic.
        std.debug.assert(@as(usize, shape.prop_count) + @as(usize, shape.deleted_prop_count) <= shape.bucketCount());
        if (shape.hasPropertyHash()) self.linkPropertyHash(shape, index);
    }

    fn freePropertyAtoms(self: *Registry, props: []const Property) void {
        for (props) |prop| {
            if (prop.atom_id != atom.null_atom) self.atoms.free(prop.atom_id);
        }
    }

    fn ensurePropertyHash(self: *Registry, shape_ptr: **Shape) !bool {
        const shape = shape_ptr.*;
        const minimum = shape.prop_count + shape.deleted_prop_count;
        if (shape.hasPropertyHash() and minimum <= shape.prop_hash_mask + 1) return false;
        var bucket_count: usize = if (shape.hasPropertyHash()) shape.bucketCount() * 2 else initial_hash_size;
        while (bucket_count <= minimum) : (bucket_count *= 2) {}
        try self.rebuildPropertyHash(shape_ptr, bucket_count);
        return true;
    }

    fn rebuildPropertyHash(self: *Registry, shape_ptr: **Shape, bucket_count: usize) !void {
        std.debug.assert(std.math.isPowerOfTwo(bucket_count));
        // Same prop capacity, larger hash table: the relocation rebuilds the
        // hash chains (bucket indices shift with the new mask).
        try self.relocateShape(shape_ptr, shape_ptr.*.prop_size, bucket_count);
    }

    fn linkPropertyHash(self: *Registry, shape: *Shape, index: usize) void {
        _ = self;
        std.debug.assert(shape.hasPropertyHash());
        std.debug.assert(index < shape.prop_count);
        const prop = &shape.props()[index];
        std.debug.assert(prop.atom_id != atom.null_atom);
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

/// Bucket count that keeps the property hash table covering the property array,
/// mirroring qjs `resize_properties` (quickjs.c:5354-5356): start from the
/// current hash size and double until it is at least `new_prop_size`. Keeping
/// `bucket_count >= prop_size` for every grow / clone means an appended property
/// (which lands at `prop_count <= prop_size`) is always representable in the
/// existing table without a rebuild — the hash never lags the props the way qjs
/// avoids by growing both in the same `resize_properties` call.
fn lockstepBucketCount(current_bucket_count: usize, new_prop_size: usize) usize {
    var hash_size = @max(current_bucket_count, initial_hash_size);
    while (hash_size < new_prop_size) : (hash_size *= 2) {}
    return hash_size;
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
