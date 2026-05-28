//! The sole deep-coupling layer with the zjs engine.
//!
//! See docs/fun_zjs_subtree_architecture.md §4.3 and §9.

pub const VM = @import("VM.zig");
pub const Global = @import("Global.zig");
pub const JSValue = @import("JSValue.zig");
pub const NativeFunction = @import("NativeFunction.zig");
pub const Exception = @import("Exception.zig");
pub const Promise = @import("Promise.zig");
pub const ModuleRecord = @import("ModuleRecord.zig");
pub const Microtask = @import("Microtask.zig");
pub const bindings = @import("bindings.zig");
