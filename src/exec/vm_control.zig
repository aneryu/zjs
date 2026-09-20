//! VM control-transfer helpers: return, jump, throw, catch, and iterator close.
//!
//! Stack pops are ownership moves, matching QuickJS opcode semantics; handled
//! throws install or route the pending exception before execution resumes.
//! Hot dispatch remains outside this file and calls these focused helpers.

const std = @import("std");
const builtin = @import("builtin");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const call_runtime = @import("call_runtime.zig");
const exception_ops = @import("exception_ops.zig");
const forof_ops = @import("forof_ops.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const array_ops = @import("array_ops.zig");
const HostError = @import("exceptions.zig").HostError;
const Vm = @import("tailcall_dispatch.zig").Vm;

const op = bytecode.opcode.op;

pub const ThrowResult = enum {
    handled,
};

pub inline fn returnTop(vm: *Vm) !core.JSValue {
    const ctx = vm.ctx;
    const stack = vm.stack;
    if (vm.machine.l0.generator_state) |generator_object| generator_object.completeGeneratorExecution(ctx.runtime);
    // qjs OP_return is an ownership MOVE off the operand stack, never a dup:
    // `ret_val = *--sp;`. The done: epilogue then frees
    // only local_buf..sp, which no longer includes the
    // popped ret_val — zero refcount traffic on the returned value. Mirror
    // that: take the top slot by value and shrink, so frame teardown
    // (Entry.deinitSimple / stack.deinit) never touches it.
    const values = stack.liveValues();
    const value = if (values.len != 0) blk: {
        stack.setLen(values.len - 1);
        break :blk values[values.len - 1];
    } else core.JSValue.undefinedValue();
    return finishFunctionReturn(ctx, vm.frame, value);
}

pub inline fn returnUndefined(ctx: *core.JSContext, frame: *frame_mod.Frame, generator: ?*core.Object) !core.JSValue {
    if (generator) |generator_object| generator_object.completeGeneratorExecution(ctx.runtime);
    return finishFunctionReturn(ctx, frame, core.JSValue.undefinedValue());
}

// Hot return-path passthrough: a non-derived-ctor frame returns the value verbatim.
// Inlined so the per-return arm pays no call (it was ~1% of fib as a separate fn).
pub inline fn finishFunctionReturn(_: *core.JSContext, frame: *frame_mod.Frame, value: core.JSValue) !core.JSValue {
    if (!frame.function.isDerivedClassConstructor()) return value;
    if (value.is(.object)) return value;
    if (!value.is(.undefined_value)) return error.DerivedConstructorReturn;
    if (adapterValueBorrow(frame.this_value).is(.uninitialized)) return error.DerivedThisUninitialized;
    return adapterValueBorrow(frame.this_value);
}

pub fn jump32(function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) void {
    const operand_pc = frame.pc;
    const diff = readInt(i32, function.byteCode()[frame.pc..][0..4]);
    frame.pc = relativePc(operand_pc, diff);
}

pub fn jump16(function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) void {
    const operand_pc = frame.pc;
    const diff = readInt(i16, function.byteCode()[frame.pc..][0..2]);
    frame.pc = relativePc(operand_pc, diff);
}

pub fn jump8(function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame) void {
    const operand_pc = frame.pc;
    const diff: i8 = @bitCast(function.byteCode()[frame.pc]);
    frame.pc = relativePc(operand_pc, diff);
}

/// `goto*` cold bodies: take the jump, then poll (qjs polls interrupts on
/// every goto; the back edge is a pure loop's only poll point).
pub fn gotoPoll32(vm: *Vm) HostError!void {
    jump32(vm.function, vm.frame);
    try exception_ops.pollInterrupt(vm.ctx, vm.global);
}

pub fn gotoPoll16(vm: *Vm) HostError!void {
    jump16(vm.function, vm.frame);
    try exception_ops.pollInterrupt(vm.ctx, vm.global);
}

pub fn gotoPoll8(vm: *Vm) HostError!void {
    jump8(vm.function, vm.frame);
    try exception_ops.pollInterrupt(vm.ctx, vm.global);
}

/// `if_false` / `if_true` cold bodies: branch, then poll.
pub fn branchPoll32(vm: *Vm, opc: u8) HostError!void {
    try branch32(vm.ctx, vm.stack, vm.function, vm.frame, opc == op.if_true);
    try exception_ops.pollInterrupt(vm.ctx, vm.global);
}

/// `if_false8` / `if_true8` cold bodies: branch, then poll.
pub fn branchPoll8(vm: *Vm, opc: u8) HostError!void {
    try branch8(vm.ctx, vm.stack, vm.function, vm.frame, opc == op.if_true8);
    try exception_ops.pollInterrupt(vm.ctx, vm.global);
}

pub fn branch32(_: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, branch_if_true: bool) !void {
    const operand_pc = frame.pc;
    const diff = readInt(i32, function.byteCode()[frame.pc..][0..4]);
    frame.pc += 4;
    const value = try stack.pop();
    const truthy = value.as(.boolean) orelse value_ops.isTruthy(value);
    if (truthy == branch_if_true) {
        frame.pc = relativePc(operand_pc, diff);
    }
}

pub fn branch8(_: *core.JSContext, stack: *stack_mod.Stack, function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, branch_if_true: bool) !void {
    const operand_pc = frame.pc;
    const diff: i8 = @bitCast(function.byteCode()[frame.pc]);
    frame.pc += 1;
    const value = try stack.pop();
    const truthy = value.as(.boolean) orelse value_ops.isTruthy(value);
    if (truthy == branch_if_true) {
        frame.pc = relativePc(operand_pc, diff);
    }
}

pub noinline fn throwTop(vm: *Vm) !ThrowResult {
    const ctx = vm.ctx;
    const stack = vm.stack;
    const catch_target = vm.catch_target;
    const value = try stack.pop();
    try forof_ops.closeStackTopForOfIteratorForPendingError(ctx, vm.output, vm.global, stack);
    try stack.reserveAdditional(1);
    if (catch_target.* == null) {
        if (try array_ops.popCatchMarker(ctx.runtime, stack)) |restored| {
            catch_target.* = restored;
        }
    }
    if (catch_target.*) |target| {
        const restored = (try array_ops.popCatchMarker(ctx.runtime, stack)) orelse null;
        stack.pushOwnedAssumeCapacity(value);
        vm.frame.pc = target;
        catch_target.* = restored;
        return .handled;
    }
    _ = ctx.throwValue(value);
    return error.JSException;
}

fn createAtomError(
    ctx: *core.JSContext,
    global: *core.Object,
    error_name: []const u8,
    atom_id: core.Atom,
    prefix: []const u8,
    suffix: []const u8,
) !core.JSValue {
    const atom_name = ctx.runtime.atoms.name(atom_id) orelse "lexical variable";
    const prefix_name_len = std.math.add(usize, prefix.len, atom_name.len) catch return error.OutOfMemory;
    const message_len = std.math.add(usize, prefix_name_len, suffix.len) catch return error.OutOfMemory;
    const message = try ctx.runtime.allocRuntime(u8, message_len);
    defer ctx.runtime.memory.free(u8, message);
    @memcpy(message[0..prefix.len], prefix);
    @memcpy(message[prefix.len..prefix_name_len], atom_name);
    @memcpy(message[prefix_name_len..], suffix);
    return exception_ops.createNamedError(ctx, global, error_name, message);
}

fn createThrowErrorValue(ctx: *core.JSContext, global: *core.Object, atom_id: core.Atom, error_type: u8) !core.JSValue {
    return switch (error_type) {
        0 => createAtomError(ctx, global, "TypeError", atom_id, "'", "' is read-only"),
        1 => createAtomError(ctx, global, "SyntaxError", atom_id, "redeclaration of '", "'"),
        2 => createAtomError(ctx, global, "ReferenceError", atom_id, "", " is not initialized"),
        3 => exception_ops.createNamedError(ctx, global, "ReferenceError", "unsupported reference to 'super'"),
        4 => exception_ops.createNamedError(ctx, global, "TypeError", "iterator does not have a throw method"),
        5 => exception_ops.createNamedError(ctx, global, "ReferenceError", "invalid assignment target"),
        else => blk: {
            var message_buffer: [64]u8 = undefined;
            const message = std.fmt.bufPrint(&message_buffer, "invalid throw var type {d}", .{error_type}) catch unreachable;
            break :blk exception_ops.createNamedError(ctx, global, "InternalError", message);
        },
    };
}

fn deliverPendingThrow(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    global: *core.Object,
    comptime err: anytype,
) !ThrowResult {
    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .handled;
    return err;
}

pub noinline fn throwErrorVm(vm: *Vm) !ThrowResult {
    const ctx = vm.ctx;
    const output = vm.output;
    const stack = vm.stack;
    const frame = vm.frame;
    const catch_target = vm.catch_target;
    const global = vm.global;
    const atom_id = core.Atom.fromRaw(std.mem.readInt(u32, vm.function.byteCode()[frame.pc..][0..4], .little));
    const error_type = vm.function.byteCode()[frame.pc + 4];
    frame.pc += 5;
    const error_value = try createThrowErrorValue(ctx, global, atom_id, error_type);
    _ = ctx.throwValue(error_value);
    // Preserve the typed sentinel while carrying the richer pending exception.
    // Inline-call unwinding uses the sentinel to find a catch in an outer frame;
    // pendingExceptionMatchesError then transfers this exact Error object.
    return switch (error_type) {
        0, 4 => deliverPendingThrow(ctx, output, stack, frame, catch_target, global, error.TypeError),
        1 => deliverPendingThrow(ctx, output, stack, frame, catch_target, global, error.SyntaxError),
        2, 3, 5 => deliverPendingThrow(ctx, output, stack, frame, catch_target, global, error.ReferenceError),
        else => deliverPendingThrow(ctx, output, stack, frame, catch_target, global, error.JSException),
    };
}

pub noinline fn catchTarget(function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, stack: *stack_mod.Stack, catch_target: *?usize) !void {
    const operand_pc = frame.pc;
    const diff = readInt(i32, function.byteCode()[frame.pc..][0..4]);
    frame.pc += 4;
    const previous_target: i32 = if (catch_target.*) |target| @intCast(target) else -1;
    catch_target.* = relativePc(operand_pc, diff);
    try stack.pushOwned(core.JSValue.catchOffset(previous_target));
}

pub fn gosub(vm: *Vm) HostError!void {
    const frame = vm.frame;
    const operand_pc = frame.pc;
    const diff = readInt(i32, vm.function.byteCode()[frame.pc..][0..4]);
    const return_pc = frame.pc + 4;
    if (return_pc > @as(usize, @intCast(std.math.maxInt(i32)))) return error.InvalidBytecode;
    try vm.stack.pushOwned(core.JSValue.int32(@intCast(return_pc)));
    frame.pc = relativePc(operand_pc, diff);
}

pub fn ret(vm: *Vm) HostError!void {
    const target = try vm.stack.pop();
    const pc_i32 = target.as(.int) orelse return error.InvalidBytecode;
    if (pc_i32 < 0) return error.InvalidBytecode;
    const pc: usize = @intCast(pc_i32);
    if (pc >= vm.function.byteCode().len) return error.InvalidBytecode;
    vm.frame.pc = pc;
}

fn relativePc(operand_pc: usize, diff: anytype) usize {
    return @intCast(@as(i64, @intCast(operand_pc)) + @as(i64, diff));
}

fn adapterValueBorrow(slot: core.JSValue) core.JSValue {
    const cell = varRefCellFromValue(slot) orelse return slot;
    const value = cell.varRefValue();
    if (comptime builtin.mode == .Debug) {
        std.debug.assert(varRefCellFromValue(value) == null);
    }
    return value;
}

fn varRefCellFromValue(value: core.JSValue) ?*core.VarRef {
    return core.VarRef.fromValue(value);
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
