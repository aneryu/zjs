//! GC-managed BigInt storage bridging JSValue and the allocation-free bigint library.
//!
//! A `BigInt` owns either an external limb allocation or the inline FAM tail of
//! its own GC block; borrowed library views must never deinit or realloc those
//! limbs. Header offset, total size, alignment, and limb geometry are comptime
//! pins used by JSValue decoding and GC accounting. QuickJS map: `JSBigInt` and
//! its limb tail around quickjs.c. Core and higher layers may import
//! this module; it depends only on core/libs, never exec/runtime/binding.

const mem_ops = @import("memory.zig");
const std = @import("std");
const builtin = @import("builtin");
const gc = @import("gc.zig");
const memory = @import("memory.zig");
const libs = @import("../libs/root.zig");
const JSRuntime = @import("../runtime.zig").JSRuntime;
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
        std.debug.assert(@sizeOf(BigInt) == 48);
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
        var big = try libs.bigint.BigInt.fromIntAlloc(rt.nativeAllocator(), value);
        errdefer big.deinit();
        return createFromOwned(rt, big);
    }

    pub fn createFromBigInt(rt: *JSRuntime, value: libs.bigint.BigInt) !*BigInt {
        var cloned = try value.cloneWithAllocator(rt.nativeAllocator());
        errdefer cloned.deinit();
        return createFromOwned(rt, cloned);
    }

    pub fn createFromOwned(rt: *JSRuntime, value: libs.bigint.BigInt) !*BigInt {
        const self = try createFromOwnedReserved(rt, value);
        self.register(rt);
        return self;
    }

    /// `createFromOwned` without the GC publication: the wrapper is on no
    /// list and the tracer neither marks nor sweeps it until `register`.
    pub fn createFromOwnedReserved(rt: *JSRuntime, value: libs.bigint.BigInt) !*BigInt {
        const self = try mem_ops.create(rt, BigInt);
        errdefer mem_ops.destroy(rt, BigInt, self);

        const accounted_allocator = rt.nativeAllocator();
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
        const self = try mem_ops.createWithFam(rt, BigInt, fam_bytes);
        self.* = .{
            .header = .{},
            .limbs_ptr = if (capacity == 0) null else @ptrCast(@alignCast(inlineBase(self))),
            .allocator = rt.nativeAllocator(),
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

    pub inline fn fromHeader(header: *gc.Header) *BigInt {
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// Bytes this wrapper (plus inline limbs) is registered with. External
    /// limbs are charged separately through the native allocator.
    pub fn accountedAllocationSize(self: *const BigInt) usize {
        return mem_ops.gcSlabAccountedPayload(self) orelse
            (@sizeOf(BigInt) + if (self.flags.inline_storage) self.famBytes() else 0);
    }

    /// Publish onto the GC list: from here the tracer owns the wrapper
    /// (marked through `cycleMarkHeader`, swept in the doomed pass).
    /// Constructors publish before returning; the parser's constant-pool
    /// literals stay reserved until their FunctionBytecode is published
    /// (`registerReservedValue`), and are destroyed by hand if that never
    /// happens (`destroyIfReservedValue`).
    pub fn register(self: *BigInt, rt: *JSRuntime) void {
        rt.gc.addInitializedWithSizeNoFail(&self.header, self.accountedAllocationSize());
    }

    pub inline fn isRegistered(self: *const BigInt) bool {
        return self.header.metaConst().alloc_info.heap_accounted;
    }

    /// Test seam: free a BigInt this frame owns outright, whether it is still
    /// reserved or already registered (unlinked first, as the sweep would).
    /// Production never frees a registered BigInt outside the collector.
    pub fn releaseForTest(self: *BigInt, rt: *JSRuntime) void {
        if (comptime !builtin.is_test) @compileError("test-only");
        if (self.isRegistered()) {
            rt.gc.unlinkObjectWithBytes(&self.header, gc.Registry.heapByteSizeFromHeader(rt, &self.header));
        }
        destroyFromHeader(rt, &self.header);
    }

    pub fn registerReservedValue(rt: *JSRuntime, value: JSValue) void {
        if (!value.isBigInt()) return;
        const header = value.refHeader() orelse return;
        const self = fromHeader(header);
        if (!self.isRegistered()) self.register(rt);
    }

    /// True when `value` was a reserved (never registered) heap BigInt and
    /// has now been freed; false leaves the value to its ordinary owner.
    pub fn destroyIfReservedValue(rt: *JSRuntime, value: JSValue) bool {
        if (!value.isBigInt()) return false;
        const header = value.refHeader() orelse return false;
        const self = fromHeader(header);
        if (self.isRegistered()) return false;
        destroyFromHeader(rt, header);
        return true;
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
    /// quickjs.c, collapsing at `len == 1`), so skipping that collapse
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
    /// quickjs.c), replacing zjs's separate `mulAlloc` limb block plus
    /// `createFromOwned` wrapper.
    ///
    /// Everything after the allocation is infallible, so OOM has exactly one
    /// boundary. The object is fully initialized before the caller can publish
    /// it as a JSValue.
    pub fn createMulInline(rt: *JSRuntime, lhs: *const BigInt, rhs: *const BigInt) !*BigInt {
        std.debug.assert(mulResultCannotCompactToShort(lhs, rhs));

        // Mirrors the js_bigint_new cap that bounds mulAlloc
        //. `capacity` cannot overflow before the check:
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
        // quickjs.c), and each row's top carry slot is a pure write.
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
        self.register(rt);
        return self;
    }

    // ---- destruction -------------------------------------------------------

    pub fn destroyFromHeader(rt: *JSRuntime, header: *gc.Header) void {
        fromHeader(header).destroyReserved(rt);
    }

    /// Free the wrapper (and inline limbs) through the account that created
    /// it. The parser allocates constant-pool literals from the function's
    /// account before any runtime publication, so it frees them here too.
    /// Reserved cell for a parser that may not have stored a runtime. The
    /// native allocator's context is the account that owns the cell.
    pub fn createExternalReserved(runtime: *JSRuntime) !*BigInt {
        return mem_ops.create(runtime, BigInt);
    }

    pub fn destroyExternalReserved(self: *BigInt, runtime: *JSRuntime) void {
        self.destroyReserved(runtime);
    }

    pub fn destroyReserved(self: *BigInt, account: *@import("../runtime.zig").JSRuntime) void {
        if (self.flags.inline_storage) {
            // Capacity, not len: an inline result normalized down from
            // `lhs.len + rhs.len` would otherwise be released at the wrong size.
            mem_ops.destroyWithFam(account, BigInt, self, self.famBytes());
            return;
        }
        if (self.capacity != 0) self.allocator.free(self.limbs_ptr.?[0..self.capacity]);
        mem_ops.destroy(account, BigInt, self);
    }
};

/// Deterministic limb patterns for the lockstep test. Index selects a shape
/// family; the offset keeps the two operands from being identical.
fn lockstepLimb(pattern: usize, index: usize, offset: usize) Limb {
    const i = index + offset;
    return switch (pattern) {
        // Saturated: maximal carry propagation, top carry non-zero.
        0 => std.math.maxInt(Limb),
        // Single high bit: top carry zero, so the product normalizes one limb
        // below capacity.
        1 => if (index == 0) @as(Limb, 1) << 63 else 0,
        // Sparse.
        2 => if (i % 3 == 0) 1 else 0,
        // Alternating bit stripes.
        3 => if (i % 2 == 0) 0xAAAA_AAAA_AAAA_AAAA else 0x5555_5555_5555_5555,
        // Low-entropy ramp.
        4 => @as(Limb, @intCast(i)) *% 0x9E37_79B9_7F4A_7C15 +% 1,
        else => unreachable,
    };
}

/// Runs one multiply through both kernels and asserts the results agree in
/// sign, length and every limb. Each operand is built once as external storage
/// and once as inline storage, so all four storage combinations are covered.
fn expectLockstepMul(
    rt: *JSRuntime,
    lhs_limbs: []const libs.bigint.Limb,
    lhs_negative: bool,
    rhs_limbs: []const libs.bigint.Limb,
    rhs_negative: bool,
) !void {
    const bigint = libs.bigint;
    const allocator = rt.nativeAllocator();

    const lhs_value = bigint.BigInt{
        .negative = lhs_negative,
        .limbs = @constCast(lhs_limbs),
        .allocator = allocator,
    };
    const rhs_value = bigint.BigInt{
        .negative = rhs_negative,
        .limbs = @constCast(rhs_limbs),
        .allocator = allocator,
    };
    var expected = try bigint.mulAlloc(allocator, lhs_value, rhs_value);
    defer expected.deinit();

    inline for (.{ false, true }) |lhs_inline| {
        inline for (.{ false, true }) |rhs_inline| {
            const lhs = try makeLockstepOperand(rt, lhs_limbs, lhs_negative, lhs_inline);
            defer lhs.releaseForTest(rt);
            const rhs = try makeLockstepOperand(rt, rhs_limbs, rhs_negative, rhs_inline);
            defer rhs.releaseForTest(rt);
            try std.testing.expectEqual(lhs_inline, lhs.isInline());
            try std.testing.expectEqual(rhs_inline, rhs.isInline());
            try std.testing.expect(BigInt.mulResultCannotCompactToShort(lhs, rhs));

            const product = try BigInt.createMulInline(rt, lhs, rhs);
            defer product.releaseForTest(rt);

            try std.testing.expect(product.isInline());
            try std.testing.expectEqual(expected.negative, product.negative());
            try std.testing.expectEqualSlices(bigint.Limb, expected.limbs, product.limbs());
            // The allocation is never shrunk, so destruction still has to use
            // the full capacity even when normalization dropped the top limb.
            try std.testing.expectEqual(lhs_limbs.len + rhs_limbs.len, product.capacitySliceMut().len);
            try std.testing.expect(product.limbs().len == product.capacitySliceMut().len or
                product.limbs().len + 1 == product.capacitySliceMut().len);
        }
    }
}

fn makeLockstepOperand(
    rt: *JSRuntime,
    limbs: []const libs.bigint.Limb,
    negative: bool,
    comptime want_inline: bool,
) !*BigInt {
    const bigint = libs.bigint;
    if (want_inline) {
        const big = try BigInt.createInlineUninitialized(rt, limbs.len);
        @memcpy(big.capacitySliceMut(), limbs);
        big.publishInline(limbs.len, negative);
        return big;
    }
    const owned = bigint.BigInt{
        .negative = negative,
        .limbs = @constCast(limbs),
        .allocator = rt.nativeAllocator(),
    };
    return BigInt.createFromBigInt(rt, owned);
}

test "heap BigInt value uses reserved QuickJS tag" {
    const rt = try JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const big = try BigInt.create(rt, @as(i128, 1) << 90);
    const value = big.valueRef();

    try std.testing.expect(value.isBigInt());
    try std.testing.expectEqual(gc.RefKind.big_int, value.refHeader().?.meta().flags.kind);
}

test "heap BigInt limbs participate in runtime memory limit and accounting" {
    const rt = try JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    var source = try libs.bigint.pow2(std.testing.allocator, 512 * 1024);
    defer source.deinit();
    const limb_bytes = source.limbs.len * @sizeOf(libs.bigint.Limb);
    const baseline = rt.diagnostics.allocations.allocated_bytes;

    // Leave room for the wrapper and a small margin, but not the retained limb
    // storage. A raw Runtime native allocator clone used to bypass this limit.
    rt.setNativeBytesLimitForTest(baseline + @sizeOf(BigInt) + 1024);
    defer rt.setNativeBytesLimitForTest(null);
    if (BigInt.createFromBigInt(rt, source)) |unexpected| {
        unexpected.releaseForTest(rt);
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }

    rt.setNativeBytesLimitForTest(null);
    const stored = try BigInt.createFromBigInt(rt, source);
    try std.testing.expect(rt.diagnostics.allocations.allocated_bytes >= baseline + @sizeOf(BigInt) + limb_bytes);
    stored.releaseForTest(rt);
    try std.testing.expectEqual(baseline, rt.diagnostics.allocations.allocated_bytes);
}

test "heap BigInt external storage reads through the storage accessors" {
    const rt = try JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    const baseline = rt.diagnostics.allocations.allocated_bytes;

    // Zero owns no limbs in either storage mode, so `limbs_ptr` is null and the
    // accessors must still hand back an empty slice rather than deref it.
    const zero = try BigInt.create(rt, 0);
    try std.testing.expect(zero.isExternal());
    try std.testing.expect(!zero.isInline());
    try std.testing.expect(!zero.negative());
    try std.testing.expectEqual(@as(usize, 0), zero.limbs().len);
    try std.testing.expectEqual(@as(usize, 0), zero.famBytes());
    zero.releaseForTest(rt);

    const negative_multi = try BigInt.create(rt, -(@as(i128, 1) << 90));
    try std.testing.expect(negative_multi.isExternal());
    try std.testing.expect(negative_multi.negative());
    try std.testing.expectEqual(@as(usize, 2), negative_multi.limbs().len);
    try std.testing.expectEqual(@as(libs.bigint.Limb, 0), negative_multi.limbs()[0]);
    try std.testing.expectEqual(@as(libs.bigint.Limb, 1) << 26, negative_multi.limbs()[1]);
    // External storage is adopted from an already-normalized library value, so
    // the whole allocation is live.
    try std.testing.expectEqual(negative_multi.limbs().len, negative_multi.capacitySliceMut().len);
    try std.testing.expectEqual(@as(usize, 2 * @sizeOf(libs.bigint.Limb)), negative_multi.famBytes());

    const borrowed = negative_multi.borrowedValue(rt.nativeAllocator());
    try std.testing.expect(borrowed.negative);
    try std.testing.expectEqualSlices(libs.bigint.Limb, negative_multi.limbs(), borrowed.limbs);

    negative_multi.releaseForTest(rt);
    try std.testing.expectEqual(baseline, rt.diagnostics.allocations.allocated_bytes);
}

test "heap BigInt inline storage destroys by capacity across the slab boundary" {
    const bigint = libs.bigint;
    const rt = try JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    const baseline = rt.diagnostics.allocations.allocated_bytes;

    const slab = memory.SmallObjectSlab;
    const wrapper = @sizeOf(BigInt);
    const limb_bytes = @sizeOf(bigint.Limb);
    const max_slab_payload = slab.max_size - slab.block_header_bytes;
    const last_slab_capacity = (max_slab_payload - wrapper) / limb_bytes;
    comptime std.debug.assert(last_slab_capacity > 4);
    // Derive the boundary from the active representation: trace and RC keep
    // different BigInt wrapper sizes, but this test must cross the allocator
    // boundary in both configurations. Both destroy paths have to release
    // `capacity` limbs even when the published length is shorter.
    const capacities = [_]usize{
        0,
        1,
        2,
        4,
        last_slab_capacity - 1,
        last_slab_capacity,
        last_slab_capacity + 1,
        last_slab_capacity + 8,
    };
    try std.testing.expect(slab.canUse(wrapper + last_slab_capacity * limb_bytes, .@"8"));
    try std.testing.expect(!slab.canUse(wrapper + (last_slab_capacity + 1) * limb_bytes, .@"8"));

    for (capacities) |capacity| {
        const big = try BigInt.createInlineUninitialized(rt, capacity);
        try std.testing.expectEqual(
            slab.canUse(wrapper + capacity * limb_bytes, .@"8"),
            capacity <= last_slab_capacity,
        );
        try std.testing.expect(big.isInline());
        try std.testing.expect(!big.isExternal());
        try std.testing.expectEqual(@as(usize, 0), big.limbs().len);
        try std.testing.expectEqual(capacity, big.capacitySliceMut().len);
        try std.testing.expectEqual(capacity * @sizeOf(bigint.Limb), big.famBytes());

        // The FAM tail must start right after the struct and be limb-aligned.
        if (capacity != 0) {
            const expected_base = @intFromPtr(big) + @sizeOf(BigInt);
            try std.testing.expectEqual(expected_base, @intFromPtr(big.capacitySliceMut().ptr));
            try std.testing.expectEqual(@as(usize, 0), expected_base % @alignOf(bigint.Limb));
        }

        const window = big.capacitySliceMut();
        for (window, 0..) |*limb, i| limb.* = @as(bigint.Limb, @intCast(i)) + 1;
        // Publish one limb short of capacity where possible: that is exactly the
        // shape an inline product takes when it normalizes away a leading zero,
        // and the case where destroying by `len` would free the wrong size.
        const published = if (capacity == 0) 0 else capacity - 1;
        big.publishInline(published, true);
        try std.testing.expectEqual(published, big.limbs().len);
        try std.testing.expectEqual(capacity, big.capacitySliceMut().len);
        try std.testing.expectEqual(published != 0, big.negative());
        for (big.limbs(), 0..) |limb, i| {
            try std.testing.expectEqual(@as(bigint.Limb, @intCast(i)) + 1, limb);
        }
        const borrowed = big.borrowedValue(rt.nativeAllocator());
        try std.testing.expectEqualSlices(bigint.Limb, big.limbs(), borrowed.limbs);

        big.releaseForTest(rt);
        try std.testing.expectEqual(baseline, rt.diagnostics.allocations.allocated_bytes);
    }

    // len == capacity is the ordinary published shape.
    const full = try BigInt.createInlineUninitialized(rt, 3);
    for (full.capacitySliceMut()) |*limb| limb.* = std.math.maxInt(bigint.Limb);
    full.publishInline(3, false);
    try std.testing.expectEqual(@as(usize, 3), full.limbs().len);
    try std.testing.expect(!full.negative());
    full.releaseForTest(rt);
    try std.testing.expectEqual(baseline, rt.diagnostics.allocations.allocated_bytes);

    try std.testing.expectError(
        error.BigIntTooLarge,
        BigInt.createInlineUninitialized(rt, bigint.max_limbs + 1),
    );
    try std.testing.expectEqual(baseline, rt.diagnostics.allocations.allocated_bytes);
}

test "inline FAM multiplication matches the external kernel limb for limb" {
    const bigint = libs.bigint;
    const rt = try JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    const baseline = rt.diagnostics.allocations.allocated_bytes;
    const slab = memory.SmallObjectSlab;
    const max_slab_payload = slab.max_size - slab.block_header_bytes;
    const last_slab_capacity =
        (max_slab_payload - @sizeOf(BigInt)) / @sizeOf(bigint.Limb);

    // Ordered shapes: the basecase loop takes the shorter operand as its outer
    // row, so AxB and BxA exercise different nestings.
    const shapes = [_][2]usize{
        .{ 1, 2 },                                                                .{ 2, 1 },                                                                    .{ 2, 2 },                                                                              .{ 1, 8 }, .{ 8, 1 },
        .{ 3, 5 },                                                                .{ 5, 3 },                                                                    .{ 4, 4 },                                                                              .{ 8, 8 }, .{ 16, 16 },
        // Pin the allocator boundary for the active RC/trace representation:
        // one last slab FAM followed by two standalone FAM capacities.
        .{ last_slab_capacity / 2, last_slab_capacity - last_slab_capacity / 2 }, .{ last_slab_capacity / 2, last_slab_capacity + 1 - last_slab_capacity / 2 }, .{ last_slab_capacity / 2 + 1, last_slab_capacity + 2 - (last_slab_capacity / 2 + 1) },
    };

    var prng = std.Random.DefaultPrng.init(0x6D03C);
    const random = prng.random();

    for (shapes) |shape| {
        for (0..5) |pattern| {
            inline for (.{ false, true }) |lhs_negative| {
                inline for (.{ false, true }) |rhs_negative| {
                    const lhs_limbs = try std.testing.allocator.alloc(bigint.Limb, shape[0]);
                    defer std.testing.allocator.free(lhs_limbs);
                    const rhs_limbs = try std.testing.allocator.alloc(bigint.Limb, shape[1]);
                    defer std.testing.allocator.free(rhs_limbs);
                    for (lhs_limbs, 0..) |*l, i| l.* = lockstepLimb(pattern, i, 0);
                    for (rhs_limbs, 0..) |*l, i| l.* = lockstepLimb(pattern, i, 1);
                    // Both operands must stay normalized and non-zero, which is
                    // what the heap x heap route guarantees its callee.
                    lhs_limbs[shape[0] - 1] |= 1;
                    rhs_limbs[shape[1] - 1] |= 1;

                    try expectLockstepMul(rt, lhs_limbs, lhs_negative, rhs_limbs, rhs_negative);
                    try std.testing.expectEqual(baseline, rt.diagnostics.allocations.allocated_bytes);
                }
            }
        }
    }

    // Random widths, both signs, so the fixed patterns above are not the only
    // carry chains covered.
    for (0..400) |_| {
        const lhs_len = random.intRangeAtMost(usize, 1, 16);
        const rhs_len = random.intRangeAtMost(usize, 1, 16);
        if (lhs_len + rhs_len < 3) continue;
        const lhs_limbs = try std.testing.allocator.alloc(bigint.Limb, lhs_len);
        defer std.testing.allocator.free(lhs_limbs);
        const rhs_limbs = try std.testing.allocator.alloc(bigint.Limb, rhs_len);
        defer std.testing.allocator.free(rhs_limbs);
        for (lhs_limbs) |*l| l.* = random.int(bigint.Limb);
        for (rhs_limbs) |*l| l.* = random.int(bigint.Limb);
        lhs_limbs[lhs_len - 1] |= 1;
        rhs_limbs[rhs_len - 1] |= 1;
        try expectLockstepMul(rt, lhs_limbs, random.boolean(), rhs_limbs, random.boolean());
        try std.testing.expectEqual(baseline, rt.diagnostics.allocations.allocated_bytes);
    }
}

test "heap multiplication costs one allocation and one block" {
    const bigint = libs.bigint;
    const rt = try JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    // 2x2 limbs: the shape the JS-level benchmark uses.
    const operand_limbs = [_]bigint.Limb{ 1, @as(bigint.Limb, 1) << 63 };
    const lhs = try makeLockstepOperand(rt, &operand_limbs, false, false);
    defer lhs.releaseForTest(rt);
    const rhs = try makeLockstepOperand(rt, &operand_limbs, false, false);
    defer rhs.releaseForTest(rt);

    const count_before = rt.diagnostics.allocations.allocation_count;
    const bytes_before = rt.diagnostics.allocations.allocated_bytes;
    const product = try BigInt.createMulInline(rt, lhs, rhs);

    // One allocation per multiply, matching qjs's single js_bigint_new. The old
    // topology was two: mulAlloc's limb block plus createFromOwned's wrapper.
    try std.testing.expectEqual(count_before + 1, rt.diagnostics.allocations.allocation_count);

    const payload = @sizeOf(BigInt) + 4 * @sizeOf(bigint.Limb);
    try std.testing.expectEqual(
        bytes_before + mem_ops.accountedSizeForRequest(payload, .@"8"),
        rt.diagnostics.allocations.allocated_bytes,
    );
    // The fused wrapper+limbs payload remains slab-backed in both the RC and
    // compact trace representations.
    try std.testing.expect(memory.SmallObjectSlab.canUse(payload, .@"8"));

    product.releaseForTest(rt);
    try std.testing.expectEqual(count_before, rt.diagnostics.allocations.allocation_count);
    try std.testing.expectEqual(bytes_before, rt.diagnostics.allocations.allocated_bytes);
}

test "heap multiplication crosses the slab boundary into standalone blocks" {
    const bigint = libs.bigint;
    const rt = try JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const slab = memory.SmallObjectSlab;
    const max_slab_payload = slab.max_size - slab.block_header_bytes;
    const last_slab_capacity =
        (max_slab_payload - @sizeOf(BigInt)) / @sizeOf(bigint.Limb);
    const half = last_slab_capacity / 2;
    // Cross the allocator boundary of the active RC/trace representation;
    // all three products must allocate once and release cleanly.
    const cases = [_][2]usize{
        .{ half, last_slab_capacity - half },
        .{ half, last_slab_capacity + 1 - half },
        .{ half + 1, last_slab_capacity + 2 - (half + 1) },
    };
    for (cases) |shape| {
        const lhs_limbs = try std.testing.allocator.alloc(bigint.Limb, shape[0]);
        defer std.testing.allocator.free(lhs_limbs);
        const rhs_limbs = try std.testing.allocator.alloc(bigint.Limb, shape[1]);
        defer std.testing.allocator.free(rhs_limbs);
        for (lhs_limbs) |*l| l.* = std.math.maxInt(bigint.Limb);
        for (rhs_limbs) |*l| l.* = std.math.maxInt(bigint.Limb);

        const lhs = try makeLockstepOperand(rt, lhs_limbs, false, false);
        defer lhs.releaseForTest(rt);
        const rhs = try makeLockstepOperand(rt, rhs_limbs, false, false);
        defer rhs.releaseForTest(rt);

        const count_before = rt.diagnostics.allocations.allocation_count;
        const bytes_before = rt.diagnostics.allocations.allocated_bytes;
        const product = try BigInt.createMulInline(rt, lhs, rhs);

        const payload = @sizeOf(BigInt) + (shape[0] + shape[1]) * @sizeOf(bigint.Limb);
        try std.testing.expectEqual(count_before + 1, rt.diagnostics.allocations.allocation_count);
        try std.testing.expectEqual(
            slab.canUse(payload, .@"8"),
            shape[0] + shape[1] <= last_slab_capacity,
        );

        product.releaseForTest(rt);
        try std.testing.expectEqual(count_before, rt.diagnostics.allocations.allocation_count);
        try std.testing.expectEqual(bytes_before, rt.diagnostics.allocations.allocated_bytes);
    }
}

test "heap multiplication reports its single allocation failure cleanly" {
    const bigint = libs.bigint;
    const rt = try JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const lhs_limbs = try std.testing.allocator.alloc(bigint.Limb, 16);
    defer std.testing.allocator.free(lhs_limbs);
    const rhs_limbs = try std.testing.allocator.alloc(bigint.Limb, 16);
    defer std.testing.allocator.free(rhs_limbs);
    for (lhs_limbs) |*l| l.* = std.math.maxInt(bigint.Limb);
    for (rhs_limbs) |*l| l.* = std.math.maxInt(bigint.Limb);

    const lhs = try makeLockstepOperand(rt, lhs_limbs, false, false);
    defer lhs.releaseForTest(rt);
    const rhs = try makeLockstepOperand(rt, rhs_limbs, true, false);
    defer rhs.releaseForTest(rt);

    // Fusing the wrapper and the limbs moves the limit check and the GC trigger
    // from a 56-byte wrapper allocation to the whole 312-byte block. Leave room
    // for a wrapper but not for the block, so the fused allocation is the one
    // that has to fail.
    const count_before = rt.diagnostics.allocations.allocation_count;
    const bytes_before = rt.diagnostics.allocations.allocated_bytes;
    rt.setNativeBytesLimitForTest(bytes_before + @sizeOf(BigInt) + 16);
    defer rt.setNativeBytesLimitForTest(null);
    if (BigInt.createMulInline(rt, lhs, rhs)) |unexpected| {
        unexpected.releaseForTest(rt);
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
    }
    // The multiply has exactly one failure point, so a rejected allocation
    // leaves nothing behind at all.
    try std.testing.expectEqual(count_before, rt.diagnostics.allocations.allocation_count);
    try std.testing.expectEqual(bytes_before, rt.diagnostics.allocations.allocated_bytes);

    rt.setNativeBytesLimitForTest(null);
    const product = try BigInt.createMulInline(rt, lhs, rhs);
    try std.testing.expect(product.negative());
    try std.testing.expectEqual(@as(usize, 32), product.capacitySliceMut().len);
    product.releaseForTest(rt);
    try std.testing.expectEqual(bytes_before, rt.diagnostics.allocations.allocated_bytes);
}

test "heap multiplication rejects an oversize product before allocating" {
    const bigint = libs.bigint;
    const rt = try JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    // max_limbs is the js_bigint_new cap. Two operands
    // just over half of it produce a product that exceeds it, and the check has
    // to happen before the FAM allocation.
    const half = bigint.max_limbs / 2 + 1;
    const limbs = try std.testing.allocator.alloc(bigint.Limb, half);
    defer std.testing.allocator.free(limbs);
    for (limbs) |*l| l.* = std.math.maxInt(bigint.Limb);

    const lhs = try makeLockstepOperand(rt, limbs, false, false);
    defer lhs.releaseForTest(rt);
    const rhs = try makeLockstepOperand(rt, limbs, false, false);
    defer rhs.releaseForTest(rt);

    const bytes_before = rt.diagnostics.allocations.allocated_bytes;
    try std.testing.expectError(error.BigIntTooLarge, BigInt.createMulInline(rt, lhs, rhs));
    try std.testing.expectEqual(bytes_before, rt.diagnostics.allocations.allocated_bytes);
}

test "repeated heap multiplication retains nothing as the count grows" {
    const bigint = libs.bigint;
    const operand_limbs = [_]bigint.Limb{ 3, @as(bigint.Limb, 1) << 63 };

    // P6-03e: the single-allocation topology has to be flat in the iteration
    // count. Both the live account and the peak live-allocation count are
    // checked, because a leak would show in the first and a retained temporary
    // in the second.
    var previous_peak: ?usize = null;
    for ([_]usize{ 0, 1, 10, 1000 }) |n| {
        const rt = try JSRuntime.create(.{ .allocator = std.testing.allocator });
        defer rt.destroy();
        const lhs = try makeLockstepOperand(rt, &operand_limbs, false, false);
        defer lhs.releaseForTest(rt);
        const rhs = try makeLockstepOperand(rt, &operand_limbs, true, false);
        defer rhs.releaseForTest(rt);

        const bytes_before = rt.diagnostics.allocations.allocated_bytes;
        const count_before = rt.diagnostics.allocations.allocation_count;
        const peak_before = rt.diagnostics.allocations.peak_allocation_count;

        for (0..n) |_| {
            const product = try BigInt.createMulInline(rt, lhs, rhs);
            product.releaseForTest(rt);
        }

        try std.testing.expectEqual(bytes_before, rt.diagnostics.allocations.allocated_bytes);
        try std.testing.expectEqual(count_before, rt.diagnostics.allocations.allocation_count);
        // One live product at a time regardless of n: the peak rises by exactly
        // one over the pre-loop state on the first iteration and never again.
        const expected_peak = if (n == 0) peak_before else @max(peak_before, count_before + 1);
        try std.testing.expectEqual(expected_peak, rt.diagnostics.allocations.peak_allocation_count);
        if (previous_peak) |p| if (n != 0) try std.testing.expectEqual(p, rt.diagnostics.allocations.peak_allocation_count);
        if (n != 0) previous_peak = rt.diagnostics.allocations.peak_allocation_count;
    }
}
