pub const subsystem_name = "frontend";

pub const parser = @import("parser.zig");
pub const source_pos = @import("source_pos.zig");

// QuickJS-aligned lexer (F1). Coexists with the legacy lexer until F11
// deletes the QuickParser. New parser code (F4+) consumes these.
pub const zjs_token = @import("zjs_token.zig");
pub const zjs_lexer = @import("zjs_lexer.zig");
pub const zjs_parser = @import("zjs_parser.zig");
