pub const Result = struct {
    value_index: usize,
    done: bool,
};

pub fn next(index: *usize, length: usize) Result {
    if (index.* >= length) return .{ .value_index = index.*, .done = true };
    const current = index.*;
    index.* += 1;
    return .{ .value_index = current, .done = false };
}
