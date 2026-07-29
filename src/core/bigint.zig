const std = @import("std");
const gc = @import("gc.zig");
const libs = @import("../libs/root.zig");
const JSRuntime = @import("runtime.zig").JSRuntime;
const JSValue = @import("value.zig").JSValue;

pub const BigInt = struct {
    pub const gc_kind_tag: u8 = @intFromEnum(gc.GcKind.big_int);
    comptime {
        @import("std").debug.assert(@offsetOf(@This(), "header") == 0);
    }
    header: gc.Header,
    value: libs.bigint.BigInt,

    // ---- storage accessors -------------------------------------------------
    //
    // Every consumer goes through these instead of reaching into `value`, so
    // the limb storage can later be held either in its own allocation or in a
    // flexible array member without any of them having to know which.

    pub inline fn negative(self: *const BigInt) bool {
        return self.value.negative;
    }

    pub inline fn limbs(self: *const BigInt) []const libs.bigint.Limb {
        return self.value.limbs;
    }

    pub inline fn limbsMut(self: *BigInt) []libs.bigint.Limb {
        return self.value.limbs;
    }

    /// Borrowed view for the read-only library operations.
    ///
    /// The caller must not `deinit`, `realloc`, or otherwise change this
    /// value's allocation. That is already required of the callers that used to
    /// copy `value` and stamp a fresh allocator onto it, and it is what lets a
    /// future inline storage mode hand out the same view safely.
    pub inline fn borrowedValue(self: *const BigInt, allocator: std.mem.Allocator) libs.bigint.BigInt {
        return .{
            .negative = self.value.negative,
            .limbs = @constCast(self.value.limbs),
            .allocator = allocator,
        };
    }

    /// Adopt an owned library value as this object's storage.
    ///
    /// Public because the parser allocates its BigInt literal wrapper itself,
    /// out of the function's persistent allocator rather than the runtime's, so
    /// it cannot go through `createFromOwned`.
    pub fn initExternalFromOwned(self: *BigInt, owned: libs.bigint.BigInt) void {
        self.* = .{
            .header = .{},
            .value = owned,
        };
    }

    /// In-place add for a uniquely-referenced BigInt. `addInPlace` may
    /// reallocate, move the limb pointer, change the length or the sign, and may
    /// leave the value empty, so it is the one mutation that has to know how the
    /// limbs are owned -- hence the explicit `External` in the name.
    pub fn addInPlaceExternal(self: *BigInt, other: libs.bigint.BigInt) !void {
        try self.value.addInPlace(other);
    }

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

    pub fn valueRef(self: *BigInt) JSValue {
        return JSValue.bigInt(&self.header);
    }

    pub fn destroyFromHeader(rt: *JSRuntime, header: *gc.Header) void {
        const self: *BigInt = @alignCast(@fieldParentPtr("header", header));
        self.value.deinit();
        rt.memory.destroy(BigInt, self);
    }
};
