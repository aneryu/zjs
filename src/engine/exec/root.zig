pub const subsystem_name = "exec";

pub const vm = @import("vm.zig");
pub const qjs_vm = @import("qjs_vm.zig");
pub const frame = @import("frame.zig");
pub const stack = @import("stack.zig");
pub const call = @import("call.zig");
pub const construct = @import("construct.zig");
pub const property_ops = @import("property_ops.zig");
pub const exceptions = @import("exceptions.zig");
pub const iterator = @import("iterator.zig");
pub const eval = @import("eval.zig");
pub const module = @import("module.zig");
pub const promise = @import("promise.zig");
pub const jobs = @import("jobs.zig");
pub const value_ops = @import("value_ops.zig");
pub const globals = @import("globals.zig");
pub const closure = @import("closure.zig");
pub const test262_helpers = @import("test262_helpers.zig");

pub const Vm = vm.Vm;
