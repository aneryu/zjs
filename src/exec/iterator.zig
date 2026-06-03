const core = @import("../core/root.zig");

pub const Cursor = struct {
    index: usize = 0,
    done: bool = false,
};

pub fn nextArrayIndex(cursor: *Cursor, array_object: *core.Object) ?u32 {
    if (cursor.done) return null;
    if (cursor.index >= array_object.length) {
        cursor.done = true;
        return null;
    }
    const current: u32 = @intCast(cursor.index);
    cursor.index += 1;
    return current;
}
