const core_array = @import("../core/array.zig");

pub fn isArrayIndex(bytes: []const u8) bool {
    return core_array.isArrayIndexName(bytes);
}

pub fn lengthAfterSet(index: u32, current: u32) u32 {
    if (index >= current) return index + 1;
    return current;
}
