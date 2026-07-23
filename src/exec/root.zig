const std = @import("std");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const globals_mod = core.global_slots;
const stack_mod = @import("stack.zig");

pub const subsystem_name = "exec";

pub const zjs_vm = @import("zjs_vm.zig");
pub const frame = @import("frame.zig");
pub const stack = @import("stack.zig");
pub const inline_calls = @import("inline_calls.zig");
pub const call = @import("call.zig");
pub const construct = @import("construct.zig");
pub const property_ops = @import("property_ops.zig");
pub const exceptions = @import("exceptions.zig");
pub const exception_ops = @import("vm_exception_ops.zig");
pub const iterator = @import("iterator.zig");
pub const iterator_builtin_ops = @import("iterator_builtin_ops.zig");
pub const eval = @import("eval_entry.zig");
pub const eval_entry = @import("eval_entry.zig");
pub const module = @import("module.zig");
pub const module_graph = @import("module_graph.zig");
pub const jobs = @import("../core/jobs.zig");
pub const value_ops = @import("value_ops.zig");
pub const globals = core.global_slots;
pub const closure = @import("closure.zig");
pub const collection_adapter = @import("collection_adapter.zig");
pub const collection_ops = @import("collection_ops.zig");
pub const call_runtime = @import("call_runtime.zig");
pub const async_generator = @import("async_generator.zig");
pub const host_dispatch_stats = @import("host_dispatch_stats.zig");
pub const string_ops = @import("string_ops.zig");
pub const math_ops = @import("math_ops.zig");
pub const json_ops = @import("json_ops.zig");
pub const uri_ops = @import("uri_ops.zig");
pub const number_ops = @import("number_ops.zig");
pub const primitive_ops = @import("primitive_ops.zig");
pub const function_ops = @import("function_ops.zig");
pub const error_ops = @import("error_ops.zig");
pub const date_ops = @import("date_ops.zig");
pub const object_builtin_ops = @import("object_builtin_ops.zig");
pub const object_ops = @import("object_ops.zig");
pub const reflect_proxy_ops = @import("reflect_proxy_ops.zig");
pub const reflect_ops = @import("reflect_ops.zig");
pub const string_builtin_ops = @import("string_builtin_ops.zig");
pub const regexp_ops = @import("regexp_ops.zig");
pub const array_builtin_ops = @import("array_builtin_ops.zig");
pub const array_ops = @import("array_ops.zig");
pub const coercion_ops = @import("coercion_ops.zig");
pub const promise_ops = @import("promise_ops.zig");
pub const typed_array_construct = @import("typed_array_construct.zig");
pub const buffer_ops = @import("buffer_ops.zig");
pub const atomics_ops = @import("atomics_ops.zig");
pub const standard_globals = @import("standard_globals.zig");

pub fn opcodeName(opcode: u8) []const u8 {
    return bytecode.opcode.nameOf(opcode);
}

pub const Vm = struct {
    ctx: *core.JSContext,
    stack: stack_mod.Stack,
    output: ?*std.Io.Writer = null,
    globals: []globals_mod.Slot = &.{},
    global_object: ?*core.Object = null,

    pub fn init(ctx: *core.JSContext) Vm {
        return .{
            .ctx = ctx,
            .stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.stackLimit()),
        };
    }

    pub fn initWithOutput(ctx: *core.JSContext, output: *std.Io.Writer) Vm {
        return .{
            .ctx = ctx,
            .stack = stack_mod.Stack.init(&ctx.runtime.memory, ctx.stackLimit()),
            .output = output,
        };
    }

    pub fn deinit(self: *Vm) void {
        const owned_globals = self.globals;
        self.globals = &.{};
        for (owned_globals) |*slot| {
            const value = slot.value;
            slot.value = core.JSValue.undefinedValue();
            value.free(self.ctx.runtime);
        }
        if (owned_globals.len != 0) self.ctx.runtime.memory.free(globals_mod.Slot, owned_globals);
        const old_global = self.global_object;
        self.global_object = null;
        if (old_global) |global| global.value().free(self.ctx.runtime);
        self.stack.deinit(self.ctx.runtime);
    }

    pub fn run(self: *Vm, function: *const bytecode.FunctionBytecode) !core.JSValue {
        try self.stack.reserveAdditional(function.stack_size);
        return zjs_vm.runWithOutput(self.ctx, &self.stack, function, self.output);
    }

    pub fn runWithVarRefs(self: *Vm, function: *const bytecode.FunctionBytecode, var_refs: []const *core.VarRef) !core.JSValue {
        try self.stack.reserveAdditional(function.stack_size);
        return zjs_vm.runWithOutputAndVarRefs(self.ctx, &self.stack, function, self.output, var_refs);
    }
};
