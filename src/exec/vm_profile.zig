//! Per-opcode profiling support for the tail-call threaded dispatcher.
//!
//! The pre-threading design wrapped each opcode in an enter/deinit scope;
//! a scope cannot span an `always_tail` chain, so that API is retired.
//! A later 256-entry table shim (`profiledHandler` in `.op_handlers`)
//! slid the L-1 island and broke `op_return`'s musttail ABI on zlib
//! (SIGSEGV, `sp == 0`). Profiling builds now call `noteDispatch` from
//! `cont`/`next` only — handler bodies stay unwrapped. The final open
//! interval is closed by `OpcodeProfile.flushPendingDispatch` before any
//! dump. Compiled out entirely in default builds.

const build_options = @import("build_options");
const core = @import("../core/root.zig");

pub const enabled = build_options.zjs_enable_opcode_profile;

pub inline fn noteDispatch(rt: *core.JSRuntime, pc: [*]const u8) void {
    if (comptime !enabled) return;
    const profile = rt.opcode_profile orelse return;
    const opcode = pc[0];
    profile.noteDispatch(opcode);
    // Memory-only, no syscall: safe on the musttail path (the crash
    // precedent in the header was clock_gettime's frame, not a store).
    const bc = @import("../bytecode.zig");
    if (opcode == comptime @intFromEnum(bc.opcode.logical.LogicalOpcode.using))
        profile.noteCarrierSub(pc[1]);
}
