const bytecode = @import("../bytecode/root.zig");

pub fn isLinked(function: bytecode.Bytecode) bool {
    return function.module_record != null;
}
