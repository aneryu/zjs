//! RegExp pattern/flags compilation for early errors.
//!
//! QuickJS source map: flag validation in `js_compile_regexp` (quickjs.c)
//! plus pattern validation via `lre_compile` (libregexp.c). The frontend uses
//! this for regexp literal early errors; builtins and `RegExp.prototype.compile`
//! use the same API so RegExp objects store compiler bytecode instead of a
//! separate flags slot plus deferred first-exec compilation.

const js_adapter = @import("js_adapter.zig");
const regexp_properties = @import("../unicode/regexp_properties.zig");
const std = @import("std");

pub const Compiled = js_adapter.Compiled;

pub fn compilePatternAndFlags(allocator: std.mem.Allocator, pattern: []const u8, flags: []const u8) !Compiled {
    return js_adapter.compile(allocator, pattern, flags);
}

pub fn isSupportedUnicodePropertyExpression(name: []const u8) bool {
    return regexp_properties.isSupportedUnicodePropertyExpression(name);
}
