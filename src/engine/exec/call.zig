const Value = @import("../core/value.zig").Value;

pub fn returnThis(this_value: Value) Value {
    return this_value.dup();
}
