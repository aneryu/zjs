//! GC-managed BigInt storage bridging JSValue and the allocation-free bigint library.
//!
//! A `BigInt` owns either an external limb allocation or the inline FAM tail of
//! its own GC block; borrowed library views must never deinit or realloc those
//! limbs. Header offset, total size, alignment, and limb geometry are comptime
//! pins used by JSValue decoding and GC accounting. QuickJS map: `JSBigInt` and
//! its limb tail around quickjs.c:611-617. Core and higher layers may import
//! this module; it depends only on core/libs, never exec/runtime/binding.

const std = @import("std");
const gc = @import("gc.zig");
const libs = @import("../libs/root.zig");
const JSRuntime = @import("runtime.zig").JSRuntime;
const JSValue = @import("value.zig").JSValue;

const Limb = libs.bigint.Limb;
const DoubleLimb = u128;
const limb_bits = 64;

comptime {
    // The duplicated multiplication kernel below relies on these matching the
    // library's own limb geometry.
    std.debug.assert(@bitSizeOf(Limb) == limb_bits);
    std.debug.assert(@bitSizeOf(DoubleLimb) == 2 * limb_bits);
}

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
        std.debug.assert(@sizeOf(BigInt) == if (gc.trace_stw_enabled) 48 else 56);
        std.debug.assert(@alignOf(BigInt) == 8);
        const header_bytes = @sizeOf(gc.Header);
        std.debug.assert(@offsetOf(BigInt, "limbs_ptr") == header_bytes);
        std.debug.assert(@offsetOf(BigInt, "allocator") == header_bytes + 8);
        std.debug.assert(@offsetOf(BigInt, "len") == header_bytes + 24);
        std.debug.assert(@offsetOf(BigInt, "capacity") == header_bytes + 28);
        std.debug.assert(@offsetOf(BigInt, "flags") == header_bytes + 32);
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
    /// `createMulInline` is the one production caller; the carrier tests drive
    /// the remaining shapes directly.
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

    // ---- single-allocation multiplication -----------------------------------

    /// True when the product of two heap BigInts provably cannot compact to a
    /// short BigInt, which is the precondition for routing to
    /// `createMulInline`.
    ///
    /// **Heap representation does not imply a magnitude above the short-BigInt
    /// range.** The parser only folds literals inside the i32 range
    /// (`parseBigIntI32`) while short BigInts cover all of i64, so
    /// `3000000000n` is a one-limb heap BigInt and `3000000000n *
    /// 3000000000n` is `9e18 < 2^63` -- a product that does fit a short. qjs
    /// compacts every multiplication result (`JS_CompactBigInt` at
    /// quickjs.c:15054, collapsing at `len == 1`), so skipping that collapse
    /// would be an alignment divergence. The FAM path therefore runs only
    /// where the collapse is provably impossible; everything else keeps the
    /// old path and its `createBigIntOwned` collapse.
    ///
    /// Two conditions, both required:
    ///
    /// * both operands own limbs, so the product is not zero. A zero heap
    ///   BigInt should not exist -- every collapsing constructor turns zero
    ///   into a short BigInt -- but the predicate must be total on its own
    ///   terms rather than on that invariant;
    /// * the product needs at least two limbs. A normalized `p`-limb value is
    ///   at least `2^(64*(p-1))`, so the product of a `p`- and a `q`-limb value
    ///   is at least `2^(64*(p+q-2))` and therefore occupies `p+q-1` or `p+q`
    ///   limbs. Requiring `p+q >= 3` makes the result at least two limbs, i.e.
    ///   at least `2^64`, which never fits a short BigInt.
    ///
    /// Conservative by construction: it rejects one-limb x one-limb outright
    /// instead of computing the product and testing it, so a future change to
    /// the parser or to literal folding can only cost this route coverage, not
    /// correctness.
    pub inline fn mulResultCannotCompactToShort(lhs: *const BigInt, rhs: *const BigInt) bool {
        if (lhs.len == 0 or rhs.len == 0) return false;
        return lhs.len + rhs.len >= 3;
    }

    /// Multiply two heap BigInts into a single allocation: the wrapper and the
    /// product's limbs come from one `createWithFam`, and the basecase loop
    /// writes straight into the trailing limbs. This is the topology qjs has
    /// (`js_bigint_new` is `js_malloc(sizeof(JSBigInt) + len * sizeof(limb))`,
    /// quickjs.c:11860), replacing zjs's separate `mulAlloc` limb block plus
    /// `createFromOwned` wrapper.
    ///
    /// Everything after the allocation is infallible, so OOM has exactly one
    /// boundary. The object is fully initialized before the caller can publish
    /// it as a JSValue.
    pub fn createMulInline(rt: *JSRuntime, lhs: *const BigInt, rhs: *const BigInt) !*BigInt {
        std.debug.assert(mulResultCannotCompactToShort(lhs, rhs));

        // Mirrors the js_bigint_new cap that bounds mulAlloc
        // (quickjs.c:11592-11596). `capacity` cannot overflow before the check:
        // both lengths are already <= max_limbs, which is 16384.
        const capacity = @as(usize, lhs.len) + @as(usize, rhs.len);
        const self = try createInlineUninitialized(rt, capacity);

        const product = self.capacitySliceMut();
        const lhs_limbs = lhs.limbs();
        const rhs_limbs = rhs.limbs();

        // Algorithmically synchronized with libs.bigint.mulAlloc.
        // Deliberately duplicated to isolate hot-path code generation.
        //
        // P6-03a measured four ways of sharing one kernel between the two
        // callers (a shared `mulInto`, a comptime-parameterized body, a
        // destination-slice wrapper, an inline-forced helper); every one of
        // them missed the direct-core neutrality gate by +2.4% to +4.4%, with
        // the regressing shapes drifting between variants. The duplication is
        // the measured-cheaper option, and the lockstep test is what keeps the
        // two bodies equal.
        //
        // Shorter operand as the outer row (P6-01c), first row overwrites so no
        // pre-zeroing pass exists (P6-01, mirroring qjs mp_mul_basecase at
        // quickjs.c:11401-11413), and each row's top carry slot is a pure write.
        const outer = if (lhs_limbs.len <= rhs_limbs.len) lhs_limbs else rhs_limbs;
        const inner = if (lhs_limbs.len <= rhs_limbs.len) rhs_limbs else lhs_limbs;
        for (outer, 0..) |a, i| {
            var carry: DoubleLimb = 0;
            if (i == 0) {
                for (inner, 0..) |b, j| {
                    const current: DoubleLimb = @as(DoubleLimb, a) * b + carry;
                    product[j] = @truncate(current);
                    carry = current >> limb_bits;
                }
            } else {
                for (inner, 0..) |b, j| {
                    const index = i + j;
                    const current: DoubleLimb = @as(DoubleLimb, a) * b + product[index] + carry;
                    product[index] = @truncate(current);
                    carry = current >> limb_bits;
                }
            }
            product[i + inner.len] = @intCast(carry);
        }

        // Not `libs.bigint.normalize`: that shrinks through the allocator, and
        // the FAM tail cannot be reallocated on its own. Compute the live
        // length and leave `capacity` -- and therefore the destroy size --
        // alone. For two normalized non-zero operands only the top limb can be
        // zero, but the general downward scan costs nothing here.
        var len = product.len;
        while (len != 0 and product[len - 1] == 0) : (len -= 1) {}
        std.debug.assert(len >= 2);

        self.publishInline(len, lhs.negative() != rhs.negative());
        return self;
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
