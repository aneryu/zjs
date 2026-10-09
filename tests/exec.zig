//! Integration tests for VM execution, calls, jobs, modules, and eval.
//!
//! Split by area under `tests/exec/`. Helpers used by more than one file
//! live in `common.zig`. `tests/engine.zig` references each file from its
//! existing pull-test so the suite does not grow an empty test.
pub const string_boundary = @import("exec/string_boundary.zig");
pub const interrupts_spread = @import("exec/interrupts_spread.zig");
pub const native_dispatch = @import("exec/native_dispatch.zig");
pub const runtime_tails_jobs = @import("exec/runtime_tails_jobs.zig");
pub const calls_generators_classes = @import("exec/calls_generators_classes.zig");
pub const realms_modules = @import("exec/realms_modules.zig");
pub const vm_branches_inlining = @import("exec/vm_branches_inlining.zig");
pub const gc_rooting = @import("exec/gc_rooting.zig");
pub const typescript = @import("exec/typescript.zig");
pub const builtins = @import("exec/builtins.zig");
pub const regressions = @import("exec/regressions.zig");
