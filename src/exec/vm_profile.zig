//! Per-opcode profiling support for the tail-call threaded dispatcher.
//!
//! The pre-threading design wrapped each opcode in an enter/deinit scope;
//! a scope cannot span an `always_tail` chain, so that API is retired.
//! Profiling builds instead wrap the whole hot dispatch table
//! (`tailcall_dispatch.profiledHandler`): every table dispatch calls
//! `noteDispatch`, which closes the previous opcode's wall interval
//! (delta attribution) and opens its own. The final open interval is
//! closed by `OpcodeProfile.flushPendingDispatch` before any dump.
//! Compiled out entirely in default builds — the dispatch table is built
//! without the shim and the default binary carries no per-opcode cost.

const build_options = @import("build_options");
const core = @import("../core/root.zig");

pub const enabled = build_options.zjs_enable_opcode_profile;

pub inline fn noteDispatch(rt: *core.JSRuntime, opcode: u8) void {
    if (comptime !enabled) return;
    const profile = rt.opcode_profile orelse return;
    profile.noteDispatch(opcode);
}
