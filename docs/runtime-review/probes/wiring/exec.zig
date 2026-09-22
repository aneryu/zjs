const core = @import("core.zig");
pub fn invoke(rt: *core.Runtime) usize {
    return rt.value + 1;
}
