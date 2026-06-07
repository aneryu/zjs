/// Compatibility shim: IC slot storage lives in core, while bytecode retains
/// the historical `bytecode.ic` import path for existing callers.
pub usingnamespace @import("../core/ic.zig");
