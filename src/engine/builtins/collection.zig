const Value = @import("../core/value.zig").Value;

pub fn sameValueZero(a: Value, b: Value) bool {
    return a.same(b);
}

pub const Entry = struct {
    key: Value,
    value: Value,
};
