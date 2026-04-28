//! Compilation pipeline for Phase 2/Phase 3.
//!
//! This module implements the QuickJS compilation pipeline:
//! - Phase 2: resolve_variables (resolve_variables.zig)
//! - Phase 3a: resolve_labels (resolve_labels.zig)
//! - Phase 3b: pc2line (pc2line.zig)
//! - Phase 3c: stack_size (stack_size.zig)
//! - Finalization: finalize (finalize.zig)
//!
//! Mirrors the QuickJS pipeline at:
//! - resolve_variables: quickjs.c:33622
//! - resolve_labels: quickjs.c:34197
//! - compute_pc2line_info: quickjs.c:33995
//! - compute_stack_size: quickjs.c:35167
//! - js_create_function: quickjs.c:35401

pub const resolve_variables = @import("resolve_variables.zig");
pub const resolve_labels = @import("resolve_labels.zig");
pub const pc2line = @import("pc2line.zig");
pub const stack_size = @import("stack_size.zig");
pub const finalize = @import("finalize.zig");