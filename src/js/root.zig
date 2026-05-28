//! fun's stable facade over the zjs engine.
//!
//! All of fun (except the narrow vm/ deep layer) must import this module only
//! when they need JS engine capabilities.
//!
//! See docs/fun_zjs_subtree_architecture.md §7.

pub const api = @import("api.zig");
pub const host = @import("host.zig");

pub const Engine = api.Engine;
pub const Source = api.Source;
pub const Completion = api.Completion;
pub const Exception = api.Exception;
pub const Value = @import("value.zig").Value;
