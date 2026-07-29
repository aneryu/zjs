const std = @import("std");
const gc = @import("gc.zig");
const libs = @import("../libs/root.zig");
const JSRuntime = @import("runtime.zig").JSRuntime;
const JSValue = @import("value.zig").JSValue;

const Limb = libs.bigint.Limb;

/// Heap BigInt carrier.
///
/// The limbs live either in their own allocation or in a flexible array member
/// immediately after this struct. `limbs_ptr` points at whichever it is, so
/// every read path is storage-agnostic and only the ownership-changing
/// operations -- construction, in-place mutation, capacity access and destroy
/// -- have to know the difference.
///
/// The previous shape embedded a whole `libs.bigint.BigInt`, which owns its
/// slice and frees it in `deinit`. That contract cannot describe inline
/// storage: a view onto the FAM tail must never be deinit'd or realloc'd, so
/// the fields are held directly here and handed out only as an explicitly
/// borrowed view.
pub const BigInt = struct {
    pub const gc_kind_tag: u8 = @intFromEnum(gc.GcKind.big_int);

    header: gc.Header,
    /// Null only for the zero value, which owns no limbs in either mode.
    limbs_ptr: ?[*]Limb,
    /// External storage: the allocator owning `limbs_ptr[0..capacity]`.
    /// Inline storage: kept so a borrowed view can be stamped without
    /// threading a runtime allocator through every reader.
    allocator: std.mem.Allocator,
    /// Normalized live limb count, always <= capacity.
    len: u32,
    /// Allocated limb count. Destruction must use this and never `len`: an
    /// inline multiplication allocates `lhs.len + rhs.len` and may normalize to
    /// one fewer, and releasing the normalized size would free the wrong block.
    capacity: u32,
    flags: Flags,

    pub const Flags = packed struct(u8) {
        negative: bool = false,
        inline_storage: bool = false,
        reserved: u6 = 0,
    };

    comptime {
        std.debug.assert(@offsetOf(BigInt, "header") == 0);
        // The embedded-value shape was 56 bytes. The explicit fields must not
        // grow it, or every external wrapper could cross into a larger slab
        // class for no benefit.
        std.debug.assert(@sizeOf(BigInt) == 56);
        std.debug.assert(@alignOf(BigInt) == 8);
        // The FAM tail begins at `@sizeOf(BigInt)`, so that offset must be
        // limb-aligned.
        std.debug.assert(@sizeOf(BigInt) % @alignOf(Limb) == 0);
        std.debug.assert(libs.bigint.max_limbs <= std.math.maxInt(u32));
    }

    // ---- storage-agnostic reads -------------------------------------------

    pub inline fn isInline(self: *const BigInt) bool {
        return self.flags.inline_storage;
    }

    pub inline fn isExternal(self: *const BigInt) bool {
        return !self.flags.inline_storage;
    }

    pub inline fn negative(self: *const BigInt) bool {
        return self.flags.negative;
    }

    /// Live limbs in either storage mode. Deliberately does not branch on the
    /// storage flag: `limbs_ptr` already resolves it, and every reader is on
    /// this path while only the ownership operations are on the other.
    pub inline fn limbs(self: *const BigInt) []const Limb {
        if (self.len == 0) return &.{};
        return self.limbs_ptr.?[0..self.len];
    }

    pub inline fn limbsMut(self: *BigInt) []Limb {
        if (self.len == 0) return &.{};
        return self.limbs_ptr.?[0..self.len];
    }

    /// The whole allocated window, including limbs above `len`. Only a
    /// constructor writing a fresh result has business here.
    pub inline fn capacitySliceMut(self: *BigInt) []Limb {
        if (self.capacity == 0) return &.{};
        return self.limbs_ptr.?[0..self.capacity];
    }

    pub inline fn famBytes(self: *const BigInt) usize {
        return @as(usize, self.capacity) * @sizeOf(Limb);
    }

    /// Borrowed view for the read-only library operations.
    ///
    /// The caller must not `deinit`, `realloc`, or otherwise change this
    /// value's allocation: under inline storage the limbs belong to this
    /// object's own block, and freeing them through the view would release
    /// into the middle of it.
    pub inline fn borrowedValue(self: *const BigInt, allocator: std.mem.Allocator) libs.bigint.BigInt {
        return .{
            .negative = self.flags.negative,
            .limbs = @constCast(self.limbs()),
            .allocator = allocator,
        };
    }

    // ---- construction ------------------------------------------------------

    pub fn create(rt: *JSRuntime, value: i128) !*BigInt {
        var big = try libs.bigint.BigInt.fromIntAlloc(rt.memory.accountedAllocator(), value);
        errdefer big.deinit();
        return createFromOwned(rt, big);
    }

    pub fn createFromBigInt(rt: *JSRuntime, value: libs.bigint.BigInt) !*BigInt {
        var cloned = try value.cloneWithAllocator(rt.memory.accountedAllocator());
        errdefer cloned.deinit();
        return createFromOwned(rt, cloned);
    }

    pub fn createFromOwned(rt: *JSRuntime, value: libs.bigint.BigInt) !*BigInt {
        const self = try rt.memory.create(BigInt);
        errdefer rt.memory.destroy(BigInt, self);

        const accounted_allocator = rt.memory.accountedAllocator();
        var owned = value;
        if (value.allocator.ptr != accounted_allocator.ptr or value.allocator.vtable != accounted_allocator.vtable) {
            // Preserve the transfer-on-success contract: clone first while the
            // caller still owns `value`; consume it only after that fallible
            // step succeeds. No error path after value.deinit may return to a
            // caller whose errdefer still owns the original limbs.
            const migrated = try value.cloneWithAllocator(accounted_allocator);
            owned.deinit();
            owned = migrated;
        }
        self.initExternalFromOwned(owned);
        return self;
    }

    /// Adopt an owned library value as external storage. `len` equals
    /// `capacity` here because the library value has already been shrunk to its
    /// normalized length.
    ///
    /// Public because the parser allocates its BigInt literal wrapper itself,
    /// out of the function's persistent allocator rather than the runtime's,
    /// so it cannot go through `createFromOwned`.
    pub fn initExternalFromOwned(self: *BigInt, owned: libs.bigint.BigInt) void {
        std.debug.assert(owned.limbs.len <= libs.bigint.max_limbs);
        self.* = .{
            .header = .{},
            .limbs_ptr = if (owned.limbs.len == 0) null else owned.limbs.ptr,
            .allocator = owned.allocator,
            .len = @intCast(owned.limbs.len),
            .capacity = @intCast(owned.limbs.len),
            .flags = .{ .negative = owned.negative },
        };
    }

    /// Single-allocation construction: the wrapper and `capacity` limbs come
    /// from one `createWithFam`, and the limbs are left uninitialized for the
    /// caller to write. `len` starts at zero so a caller that fails before
    /// publishing still destroys a well-formed object.
    ///
    /// Not reachable from production yet -- every JS-visible constructor above
    /// still produces external storage. Exercised by the carrier tests so the
    /// inline half is not dead on arrival when multiplication starts using it.
    pub fn createInlineUninitialized(rt: *JSRuntime, capacity: usize) !*BigInt {
        if (capacity > libs.bigint.max_limbs) return error.BigIntTooLarge;
        const fam_bytes = capacity * @sizeOf(Limb);
        const self = try rt.memory.createWithFam(BigInt, fam_bytes);
        self.* = .{
            .header = .{},
            .limbs_ptr = if (capacity == 0) null else @ptrCast(@alignCast(inlineBase(self))),
            .allocator = rt.memory.accountedAllocator(),
            .len = 0,
            .capacity = @intCast(capacity),
            .flags = .{ .inline_storage = true },
        };
        return self;
    }

    inline fn inlineBase(self: *BigInt) [*]u8 {
        return @as([*]u8, @ptrCast(self)) + @sizeOf(BigInt);
    }

    /// Publish a result written through `capacitySliceMut`. `len` may be less
    /// than `capacity`; the allocation is never shrunk and destruction still
    /// uses `capacity`.
    pub inline fn publishInline(self: *BigInt, len: usize, is_negative: bool) void {
        std.debug.assert(self.flags.inline_storage);
        std.debug.assert(len <= self.capacity);
        self.len = @intCast(len);
        self.flags.negative = if (len == 0) false else is_negative;
    }

    pub fn valueRef(self: *BigInt) JSValue {
        return JSValue.bigInt(&self.header);
    }

    // ---- mutation ----------------------------------------------------------

    /// In-place add for a uniquely-referenced external BigInt.
    ///
    /// `addInPlace` may reallocate, move the limb pointer, change the length or
    /// the sign, and may leave the value empty. Inline storage survives none of
    /// that, since its limbs sit inside this object's own block, so this
    /// asserts external storage and callers route inline values to a fresh
    /// result instead. The adopt runs on the error path too, so a failed grow
    /// cannot leave the wrapper holding a stale pointer.
    pub fn addInPlaceExternal(self: *BigInt, other: libs.bigint.BigInt) !void {
        std.debug.assert(!self.flags.inline_storage);
        var owned = self.externalOwnedValue();
        defer self.initExternalFromOwned(owned);
        try owned.addInPlace(other);
    }

    /// The owning library value for external storage. Never call this on inline
    /// storage: the returned value's `deinit` would free into the FAM tail.
    fn externalOwnedValue(self: *BigInt) libs.bigint.BigInt {
        std.debug.assert(!self.flags.inline_storage);
        return .{
            .negative = self.flags.negative,
            .limbs = if (self.capacity == 0) &.{} else self.limbs_ptr.?[0..self.capacity],
            .allocator = self.allocator,
        };
    }

    // ---- destruction -------------------------------------------------------

    pub fn destroyFromHeader(rt: *JSRuntime, header: *gc.Header) void {
        const self: *BigInt = @alignCast(@fieldParentPtr("header", header));
        if (self.flags.inline_storage) {
            // Capacity, not len: an inline result normalized down from
            // `lhs.len + rhs.len` would otherwise be released at the wrong size.
            rt.memory.destroyWithFam(BigInt, self, self.famBytes());
            return;
        }
        if (self.capacity != 0) self.allocator.free(self.limbs_ptr.?[0..self.capacity]);
        rt.memory.destroy(BigInt, self);
    }
};
