const core = @import("../core/root.zig");

pub fn create(rt: *core.Runtime, prototype: ?*core.Object) !*core.Object {
    return core.Object.create(rt, core.class.ids.object, prototype);
}

pub fn keys(rt: *core.Runtime, object: *core.Object) ![]core.Atom {
    return object.ownKeys(rt);
}
