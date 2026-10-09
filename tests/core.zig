//! Integration tests for runtime lifecycle, GC, and core heap contracts.
//!
//! Split by area under `tests/core/`. Helpers used by more than one file
//! live in `common.zig`. `tests/engine.zig` references each file from its
//! existing pull-test so the suite does not grow an empty test.
pub const value_boundary = @import("core/value_boundary.zig");
pub const roots_nursery = @import("core/roots_nursery.zig");
pub const atoms_s3 = @import("core/atoms_s3.zig");
pub const storage_s4 = @import("core/storage_s4.zig");
pub const gc_stress = @import("core/gc_stress.zig");
pub const oom_cap = @import("core/oom_cap.zig");
pub const embedding_api = @import("core/embedding_api.zig");
pub const heap_limit = @import("core/heap_limit.zig");
pub const interrupts = @import("core/interrupts.zig");
pub const runtime_lifecycle = @import("core/runtime_lifecycle.zig");
pub const microtasks = @import("core/microtasks.zig");
pub const value_root_buffer = @import("core/value_root_buffer.zig");
pub const regressions = @import("core/regressions.zig");
