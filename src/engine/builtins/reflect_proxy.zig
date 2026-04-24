const core = @import("../core/root.zig");

pub fn ownKeys(rt: *core.Runtime, object: *core.Object) ![]core.Atom {
    return object.ownKeys(rt);
}

pub const RevocableProxy = struct {
    revoked: bool = false,

    pub fn revoke(self: *RevocableProxy) void {
        self.revoked = true;
    }
};
