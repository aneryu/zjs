pub const subsystem_name = "bytecode";

pub const opcode = @import("opcode.zig");
pub const format = @import("format.zig");
pub const function = @import("function.zig");
pub const constant = @import("constant.zig");
pub const scope = @import("scope.zig");
pub const module = @import("module.zig");
pub const debug = @import("debug.zig");
pub const emitter = @import("emitter.zig");
pub const pipeline = @import("pipeline/root.zig");
pub const function_def = @import("function_def.zig");

pub const Bytecode = function.Bytecode;
pub const OpcodeFormat = function.OpcodeFormat;
