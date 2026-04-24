const regexp_lib = @import("../libs/regexp.zig");

pub fn matches(program: regexp_lib.Program, input: []const u8) bool {
    return program.exec(input) != null;
}
