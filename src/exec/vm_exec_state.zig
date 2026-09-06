//! `VmExecState`: the execution-state ABI shared by the interpreter, the
//! native-call helpers and the future baseline JIT (engine-evolution-plan
//! §5.3, §5.4; NB2 design §15 R4, D9). This file delivers the native-call
//! subset first: the helper signatures in `vm_native.zig` take a
//! `*VmExecState` instead of the interpreter-private `*Vm`, so a JIT can call
//! the same helpers on day one.
//!
//! Offsets are part of the ABI (`VM_ABI_VERSION`); generated `.inc` files are
//! FN-M6 / PERF-JIT scope and must be produced from this struct, never hand
//! written.

const std = @import("std");
const core = @import("../core/root.zig");
const bytecode = @import("../bytecode.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const inline_calls = @import("inline_calls.zig");

pub const VM_ABI_VERSION: u32 = 1;

/// Engine plan §5.4: helper status word. `tail` / `reenter` /
/// `native_returned` stay interpreter-internal control flow and never cross
/// this boundary.
pub const VmHelperStatus = enum(u8) {
    continue_execution = 0,
    exception = 1,
    function_return = 2,
    suspended = 3,
    interrupted = 4,
    bailout = 5,
};

pub const VmExitReason = enum(u8) {
    none = 0,
    returned = 1,
    threw = 2,
    suspended = 3,
};

/// Native-call subset of the engine plan's `VmExecState`. Field order is the
/// plan's order; fields the native helpers do not consume yet are present so
/// the layout does not shift when they are filled in.
pub const VmExecState = extern struct {
    /// Interpreter-private state (`tailcall_dispatch.Vm`); the JIT passes its
    /// own equivalent. Helpers reach `ctx`, `rt`, `global`, `output` through
    /// the typed accessors below, never through this pointer.
    vm: *anyopaque,

    pc: [*]const u8,
    sp: [*]core.JSValue,
    fp: [*]core.JSValue,
    var_base: [*]core.JSValue,

    function: *const bytecode.FunctionBytecode,

    exit_reason: VmExitReason = .none,
    exit_value: core.JSValue = core.JSValue.undefinedValue(),

    // ---- native-call subset (NB2) ----------------------------------------
    ctx: *core.JSContext,
    rt: *core.JSRuntime,
    global: *core.Object,
    output: ?*std.Io.Writer,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    machine: *inline_calls.Machine,
    catch_target: *?usize,
};

comptime {
    std.debug.assert(@offsetOf(VmExecState, "vm") == 0);
    std.debug.assert(@offsetOf(VmExecState, "pc") == 8);
    std.debug.assert(@offsetOf(VmExecState, "sp") == 16);
    std.debug.assert(@offsetOf(VmExecState, "fp") == 24);
    std.debug.assert(@offsetOf(VmExecState, "var_base") == 32);
    std.debug.assert(@offsetOf(VmExecState, "function") == 40);
}
