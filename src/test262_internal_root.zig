//! zjs internal test262 runner module root; governed by docs/architecture.md public/internal API split.

pub const kernel = @import("kernel/root.zig");
pub const runtime = @import("runtime/public.zig");
