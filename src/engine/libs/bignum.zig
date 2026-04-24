pub const BigInt = struct {
    value: i128,

    pub fn fromInt(value: i128) BigInt {
        return .{ .value = value };
    }

    pub fn add(self: BigInt, other: BigInt) BigInt {
        return .{ .value = self.value + other.value };
    }

    pub fn sub(self: BigInt, other: BigInt) BigInt {
        return .{ .value = self.value - other.value };
    }

    pub fn mul(self: BigInt, other: BigInt) BigInt {
        return .{ .value = self.value * other.value };
    }

    pub fn div(self: BigInt, other: BigInt) !BigInt {
        if (other.value == 0) return error.DivisionByZero;
        return .{ .value = @divTrunc(self.value, other.value) };
    }

    pub fn rem(self: BigInt, other: BigInt) !BigInt {
        if (other.value == 0) return error.DivisionByZero;
        return .{ .value = @rem(self.value, other.value) };
    }

    pub fn compare(self: BigInt, other: BigInt) std.math.Order {
        return std.math.order(self.value, other.value);
    }
};

pub fn parseBase10(bytes: []const u8) !BigInt {
    return .{ .value = try std.fmt.parseInt(i128, bytes, 10) };
}

const std = @import("std");
