//! zjs internal test262 runner module root; governed by docs/architecture.md public/internal API split.

pub const binding_root = @import("binding/root.zig");
pub const runtime = @import("runtime/public.zig");
