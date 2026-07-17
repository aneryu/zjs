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
        self.* = .{
            .header = .{},
            .value = owned,
        };
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
