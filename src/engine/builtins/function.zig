const Value = @import("../core/value.zig").Value;

pub const BuiltinFunction = struct {
    name: []const u8,
    length: u16,
};

pub fn applyReturnThis(this_value: Value) Value {
    return this_value.dup();
}
