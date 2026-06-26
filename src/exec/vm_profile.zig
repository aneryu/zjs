const build_options = @import("build_options");
const core = @import("../core/root.zig");

/// When opcode profiling is compiled out (the default), this is a zero-size
/// struct whose `deinit` is a no-op the optimizer elides entirely — the dispatch
/// prologue pays nothing per cold re-entry. Only the profiling build carries the
/// real 5-field timing scope. (Constructing the 5-field inactive struct per cold
/// re-entry cost ~3% of fib; a zero-size struct removes it.)
pub const OpcodeProfileScope = if (build_options.zjs_enable_opcode_profile) struct {
    rt: *core.JSRuntime,
    opcode: u8,
    previous: core.profile.ActiveState,
    start_ns: u64,
    active: bool,

    pub fn deinit(self: OpcodeProfileScope) void {
        if (!self.active) return;
        if (self.rt.opcode_profile) |profile| {
            profile.recordOpcode(self.opcode, core.profile.nowNanos() - self.start_ns);
        }
        core.profile.restoreOpcode(self.previous);
    }
} else struct {
    pub inline fn deinit(self: OpcodeProfileScope) void {
        _ = self;
    }
};

pub fn enterOpcode(rt: *core.JSRuntime, opcode: u8) OpcodeProfileScope {
    if (comptime !build_options.zjs_enable_opcode_profile) return .{};
    // Touch the thread-local profile state only when a profile is attached;
    // TLV access is expensive on the per-opcode hot path.
    if (rt.opcode_profile == null) {
        return .{
            .rt = rt,
            .opcode = opcode,
            .previous = .{ .profile = null, .opcode = null },
            .start_ns = 0,
            .active = false,
        };
    }
    return .{
        .rt = rt,
        .opcode = opcode,
        .previous = core.profile.enterOpcode(opcode),
        .start_ns = core.profile.nowNanos(),
        .active = true,
    };
}
