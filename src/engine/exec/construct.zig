const core = @import("../core/root.zig");

pub fn ordinaryObject(rt: *core.Runtime) !*core.Object {
    return core.Object.create(rt, core.class.ids.object, null);
}
