//! Shared language libraries for Unicode, regexp, number formatting, and bigint.
pub const subsystem_name = "libs";
pub const unicode = @import("unicode.zig");
pub const regexp = @import("regexp.zig");
pub const number_format = @import("number_format.zig");
pub const bigint = @import("bigint.zig");
