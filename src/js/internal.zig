//! Internal zjs facade. ONLY src/runtime/vm/, tests/js/, benches/js/ may import this.
//!
//! See docs/fun_zjs_subtree_architecture.md §7.3 and §20 (import guard).

pub const zjs = @import("zjs_engine");

// Re-export only what vm/ truly needs. Do not expose everything.
