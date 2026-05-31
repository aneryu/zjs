const gc = @import("gc.zig");
const libs = @import("../libs/root.zig");
const Runtime = @import("runtime.zig").Runtime;
const Value = @import("value.zig").Value;

pub const BigInt = struct {
    header: gc.Header,
    value: libs.bignum.BigInt,

    pub fn create(rt: *Runtime, value: i128) !*BigInt {
        var big = try libs.bignum.BigInt.fromIntAlloc(rt.memory.persistent_allocator, value);
        errdefer big.deinit();
        return createFromOwned(rt, big);
    }

    pub fn createFromBigInt(rt: *Runtime, value: libs.bignum.BigInt) !*BigInt {
        var cloned = try value.cloneWithAllocator(rt.memory.persistent_allocator);
        errdefer cloned.deinit();
        return createFromOwned(rt, cloned);
    }

    pub fn createFromOwned(rt: *Runtime, value: libs.bignum.BigInt) !*BigInt {
        const self = try rt.memory.create(BigInt);
        self.* = .{
            .header = .{ .kind = .big_int },
            .value = value,
        };
        return self;
    }

    pub fn valueRef(self: *BigInt) Value {
        return Value.bigInt(&self.header);
    }

    pub fn destroyFromHeader(rt: *Runtime, header: *gc.Header) void {
        const self: *BigInt = @alignCast(@fieldParentPtr("header", header));
        self.value.deinit();
        rt.memory.destroy(BigInt, self);
    }
};
