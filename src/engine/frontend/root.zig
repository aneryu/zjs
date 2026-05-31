pub const subsystem_name = "frontend";

pub const token = @import("token.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const ts_strip = @import("ts_strip.zig");
pub const regexp_literal = @import("regexp_literal.zig");
pub const source_pos = @import("source_pos.zig");

// QuickJS-aligned lexer (F1). Coexists with the legacy lexer until F11
// deletes the QuickParser. New parser code (F4+) consumes these.
pub const qjs_token = @import("qjs_token.zig");
pub const qjs_lexer = @import("qjs_lexer.zig");
pub const qjs_parser = @import("qjs_parser.zig");
