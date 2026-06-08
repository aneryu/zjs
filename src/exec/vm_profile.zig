const core = @import("../core/root.zig");

pub const OpcodeProfileScope = struct {
    rt: *core.JSRuntime,
    opcode: u8,
    previous: core.profile.ActiveState,
    start_ns: u64,

    pub fn deinit(self: OpcodeProfileScope) void {
        if (self.rt.opcode_profile) |profile| {
            profile.recordOpcode(self.opcode, core.profile.nowNanos() - self.start_ns);
        }
        core.profile.restoreOpcode(self.previous);
    }
};

pub fn enterOpcode(rt: *core.JSRuntime, opcode: u8) OpcodeProfileScope {
    return .{
        .rt = rt,
        .opcode = opcode,
        .previous = core.profile.enterOpcode(opcode),
        .start_ns = if (rt.opcode_profile != null) core.profile.nowNanos() else 0,
    };
}
