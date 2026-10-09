//! Interrupt probe shared by core and exec integration tests.
//!
//! `hits` counts every poll. `remaining == null` returns `stop`.
//! A non-null `remaining` returns false, then decrements, until it
//! is zero and the poll returns true.
const core = @import("zjs").core;

pub const State = struct {
    hits: usize = 0,
    stop: bool = false,
    remaining: ?usize = null,

    pub fn poll(_: *core.JSRuntime, userdata: ?*anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(userdata.?));
        self.hits += 1;
        if (self.remaining) |left| {
            if (left == 0) return true;
            self.remaining = left - 1;
            return false;
        }
        return self.stop;
    }
};
