const opcode = @import("regexp_opcode.zig");

pub const Flags = packed struct(u8) {
    global: bool = false,
    ignore_case: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
    unicode: bool = false,
    sticky: bool = false,
    reserved: u2 = 0,
};

pub const Program = struct {
    pattern: []const u8,
    flags: Flags = .{},
    instructions: []const opcode.Instruction = &.{},

    pub fn exec(self: Program, input: []const u8) ?Match {
        if (self.pattern.len == 0) return .{ .start = 0, .end = 0 };
        if (self.flags.ignore_case) {
            return findIgnoreCase(input, self.pattern);
        }
        if (std.mem.indexOf(u8, input, self.pattern)) |start| {
            return .{ .start = start, .end = start + self.pattern.len };
        }
        return null;
    }
};

pub const Match = struct {
    start: usize,
    end: usize,
};

pub fn compile(pattern: []const u8, flags: Flags) !Program {
    if (std.mem.indexOfScalar(u8, pattern, '[') != null and std.mem.indexOfScalar(u8, pattern, ']') == null) {
        return error.InvalidPattern;
    }
    return .{ .pattern = pattern, .flags = flags };
}

fn findIgnoreCase(input: []const u8, pattern: []const u8) ?Match {
    if (pattern.len > input.len) return null;
    var i: usize = 0;
    while (i + pattern.len <= input.len) : (i += 1) {
        if (@import("unicode.zig").equalsIgnoreAsciiCase(input[i .. i + pattern.len], pattern)) {
            return .{ .start = i, .end = i + pattern.len };
        }
    }
    return null;
}

const std = @import("std");
