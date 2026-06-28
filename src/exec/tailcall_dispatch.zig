//! Tail-call dispatch — terminal-state rewrite (TAILCALL-DISPATCH-ONESHOT-BLUEPRINT.md).
//!
//! Every opcode is its own handler `fn(pc, sp, var_buf, vm) callconv(.c) Outcome`;
//! dispatch is `@call(.always_tail) vm.tbl[pc[0]]` through a 256-entry table.
//! The 3 hottest values (pc/sp/var_buf) ride in argument registers; everything else
//! is bundled behind the `*Vm` pointer (x3). Because each handler is a separate
//! function, its JSValue temporaries live in ITS frame and die at ITS return — so the
//! dispatchLoop's stack frame collapses from `sum(per-arm spills)` (3504B, additive
//! non-coalescing, proven by comptime-delete bisection) to `max single handler`
//! (~80-150B) + the driver.
//!
//! CRITICAL INVARIANT — a handler makes ZERO non-tail calls *on its own frame*. The
//! op's real work is an OUTLINED helper (vm_*.zig, unchanged) invoked as the action
//! immediately before the final tail dispatch; a handler that emits a `bl` before its
//! terminal `b` spills the live registers and regrows the frame. Hot handlers (the
//! frame-zero fast paths: get_loc/put_loc/get_arg/push_*/dup/swap/int32 arith) inline
//! their fast path; cold handlers publish + call their helper + tail-dispatch.
//!
//! NO `op_cold` big-switch fallback — that would keep the monolithic frame. The cold
//! ops are individual handlers via the §6 template.

const std = @import("std");
const build_options = @import("build_options");
const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const inline_calls = @import("inline_calls.zig");
const call_runtime = @import("call_runtime.zig");
const HostError = @import("exceptions.zig").HostError;

// Op-helper modules (same aliases as zjs_vm.zig's dispatchLoop).
const value_vm = @import("vm_value.zig");
const arith_vm = @import("vm_arith.zig");
const control_vm = @import("vm_control.zig");
const call_vm = @import("vm_call.zig");
const class_vm = @import("object_ops.zig");
const literal_vm = @import("vm_literal.zig");
const iter_vm = @import("iterator_ops.zig");
const regexp_vm = @import("vm_regexp.zig");
const eval_module_vm = @import("vm_eval_module.zig");
const gen_async_vm = @import("vm_gen_async.zig");
const slot_ops = @import("slot_ops.zig");
const vm_property_ref = @import("vm_property_ref.zig");
const vm_property_globals = @import("vm_property_globals.zig");
const vm_property_field = @import("vm_property_field.zig");
const property_ic = @import("property_ic.zig");
const vm_property_private = @import("vm_property_private.zig");
const string_ops = @import("string_ops.zig");
const forof_ops = @import("forof_ops.zig");

const op = bytecode.opcode.op;
const JSValue = core.JSValue;

fn readInt(comptime T: type, bytes: [*]const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

// ===========================================================================
// Outcome — the single u32 (x0) a handler chain returns to the driver
// ===========================================================================

pub const Outcome = enum(u32) {
    /// return / return_undef / return_async / fall-off produced `vm.return_value`.
    returned,
    /// Uncaught error: re-raise `vm.pending_error`.
    threw,
    /// A call/tail_call eligible for inline frame reuse: `vm.tail_request` is set;
    /// the driver does pushCall/tailCallReuse + rebuilds pc/sp/var_buf + re-enters.
    tail,
    /// generator yield / await: state already persisted; unwind to the resume driver.
    suspended,
    /// A cold callee (native / generator / class-ctor / cross-realm) needs the full
    /// prologue: the driver runs the cold call path and re-enters.
    reenter,
};

// ===========================================================================
// Vm — the lean bundle (everything not pc/sp/var_buf), reached via the x3 pointer
// ===========================================================================

pub const Vm = struct {
    ctx: *core.JSContext,
    function: *const bytecode.Bytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    machine: *inline_calls.Machine,
    output: ?*std.Io.Writer,

    /// `function.code.ptr` and one-past-end, cached so the hot `next` bounds check
    /// and operand reads avoid re-loading the slice through `function`.
    code_base: [*]const u8,
    code_end: [*]const u8,
    /// Frame-constant operand-stack base (== stack.values.ptr); reg_base is gone, so
    /// cold handlers re-derive sp from here after a helper grows the stack.
    stack_base: [*]JSValue,
    arg_buf: [*]JSValue,
    /// Dispatch table base. Reached via the Vm pointer so the dispatch is `ldr vm.tbl
    /// + ldr [tbl, op<<3] + br` instead of recomputing the const table address with
    /// `adrp+add` at EVERY dispatch site (the table-base-remat tax — see
    /// dispatch-table-base-remat-rootcause). EXPERIMENT to measure that tax.
    tbl: [*]const Handler = undefined,
    /// Frame-constant `(depth==0 and l0.stop_before_pc != null)` — the generator
    /// stop-boundary guard that blocks the local/var fast paths. Hoisted here (set
    /// once per frame in the driver/reloadTop) so each loc op checks ONE bool load
    /// instead of re-deriving machine.depth + l0.stop_before_pc per op (mirrors
    /// dispatchLoop's `local_fast_blocked_by_generator`).
    local_fast_blocked: bool = false,

    /// Pointer to the CURRENT frame's catch-target slot (L0: loop_state.catch_target_storage;
    /// inline: &entry.catch_target). reloadTop re-points it on every frame switch, so a
    /// catch handler set in one frame doesn't leak into another.
    catch_target: *?usize,

    /// The L0 (depth-0) frame, captured at entry. When a return pops the last inline
    /// frame (depth back to 0), reloadTop restores THESE (topEntry() is invalid at
    /// depth 0 — the L0 frame is loop_state.frame_storage, not a Machine Entry).
    l0_function: *const bytecode.Bytecode,
    l0_frame: *frame_mod.Frame,
    l0_stack: *stack_mod.Stack,
    l0_catch_target: *?usize,

    /// Outcome payloads (ride here, not in the u32 return).
    return_value: JSValue = JSValue.undefinedValue(),
    pending_error: HostError = error.OutOfMemory,
    tail_request: call_runtime.InlineCallRequest = undefined,
    /// On `.tail`: true => `tailCallReuse` (op.tail_call*/eval-tail), false => `pushCall`
    /// (op.call*/call_method). The driver branches on it.
    tail_is_reuse: bool = false,

    /// L0-only (depth==0) eval/generator entry state. Inline frames inherit theirs
    /// from `frame`; these mirror the dispatchLoop's `entry_*` depth-conditional
    /// locals so a cold handler reads them from one place. Populated by the driver at
    /// the L0 boundary; the depth==0 check is `machine.depth == 0`.
    l0: L0Entry,

    pub const L0Entry = struct {
        is_eval_code: bool = false,
        eval_local_names: []const core.Atom = &.{},
        eval_local_slots: []JSValue = &.{},
        eval_with_object: JSValue = JSValue.undefinedValue(),
        eval_global_var_bindings: bool = false,
        strict_unresolved_get_var: bool = false,
        generator_state: ?*core.Object = null,
        stop_on_yield: bool = false,
        stop_before_pc: ?usize = null,
        suspend_on_module_await: bool = false,
    };

    /// syncDown analog: publish the register-resident pc/sp back to frame.pc /
    /// stack.values so a cold helper sees live state. `pc` points at the opcode byte;
    /// cold handlers want frame.pc one past it (the operand cursor), matching the
    /// monolith's per-arm `reg_ip += 1` before the slow path.
    pub inline fn publish(self: *Vm, pc: [*]const u8, sp: [*]JSValue) void {
        self.frame.pc = (@intFromPtr(pc) - @intFromPtr(self.code_base)) + 1;
        self.stack.values = self.stack_base[0 .. (@intFromPtr(sp) - @intFromPtr(self.stack_base)) / @sizeOf(JSValue)];
    }

    /// Publish ONLY frame.pc (qjs's `sf->cur_pc = pc`, set unconditionally before
    /// every slow op). A register-resident cold handler that runs user coercion
    /// (valueOf/toString) must do this BEFORE the helper: a backtrace is captured at
    /// throw/Error()-construction time inside the user code, so frame.pc has to be
    /// live THEN — the error-path `publish` runs only while unwinding, too late.
    /// `advance` = bytes from the opcode to the next op (operand size + 1). Unlike
    /// `publish` it leaves stack.values alone and is never re-read for dispatch, so
    /// it is a fire-and-forget store off the hot dependency chain.
    pub inline fn syncPc(self: *Vm, pc: [*]const u8, advance: usize) void {
        self.frame.pc = (@intFromPtr(pc) - @intFromPtr(self.code_base)) + advance;
    }

    /// Re-derive sp after a cold helper mutated stack.values (push/pop/grow).
    pub inline fn reloadSp(self: *Vm) [*]JSValue {
        return self.stack.values.ptr + self.stack.values.len;
    }

    /// pc at the start of the next opcode (cold helper advanced frame.pc).
    pub inline fn reloadPc(self: *Vm) [*]const u8 {
        return self.code_base + self.frame.pc;
    }

    pub inline fn fail(self: *Vm, err: HostError) Outcome {
        self.pending_error = err;
        return .threw;
    }
};

// ===========================================================================
// Dispatch primitive
// ===========================================================================

pub const Handler = *const fn (pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome;

/// Computed-goto: tail-call the handler for the opcode at `pc[0]`. A forward dispatch
/// reaching code_end is a fall-off (implicit return of the stack top / undefined).
/// `callconv(.c)` + non-inline so its `always_tail` to a handler matches signatures
/// (the driver calls it as a normal entry; handlers tail-chain via `coldNext`).
fn next(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (@intFromPtr(pc) >= @intFromPtr(vm.code_end))
        return @call(.always_tail, op_falloff, .{ pc, sp, var_buf, vm });
    return @call(.always_tail, vm.tbl[pc[0]], .{ pc, sp, var_buf, vm });
}

// ===========================================================================
// Cold-handler infrastructure — every cold op is `publish -> helper -> coldNext`.
// The comptime generators below collapse the ~150 cold arms to one-liner bodies.
// ===========================================================================

/// After a cold helper ran (frame.pc advanced, stack.values mutated), re-dispatch
/// at the next opcode — or fall off the end (implicit return of the stack top).
/// Generator/eval stop-boundary (`stop_before_pc`): when frame.pc reaches the
/// generator body start, suspend (save state) and return — the param-init phase
/// runs `[0, generator_body_pc)` then stops. Mirrors zjs_vm.zig:921's stopBeforePc.
inline fn maybeStop(vm: *Vm) ?Outcome {
    if (vm.machine.depth == 0 and vm.l0.stop_before_pc != null) {
        const r = gen_async_vm.stopBeforePc(vm.ctx, vm.stack, vm.frame, vm.l0.generator_state, vm.l0.stop_before_pc) catch |e| return vm.fail(e);
        if (r) |v| {
            vm.return_value = v;
            return .returned;
        }
    }
    return null;
}

/// End-of-code fall-through: the implicit completion value is the stack top.
/// MUST dup (stack.peek) — the value stays on the stack and is freed at frame
/// teardown, so returning the RAW slot hands the caller a to-be-freed value
/// (use-after-free → heap corruption surfacing as a garbage callee in a later
/// op.call). Mirrors dispatchLoop's stack.peek() + finishFunctionReturn
/// (zjs_vm.zig:916-917 L0-break path and :2616-2617 post-loop).
inline fn falloffReturn(vm: *Vm) Outcome {
    const fallthrough_value = vm.stack.peek() orelse JSValue.undefinedValue();
    vm.return_value = control_vm.finishFunctionReturn(vm.ctx, vm.frame, fallthrough_value) catch |e| return vm.fail(e);
    return .returned;
}

inline fn coldNext(vb: [*]JSValue, vm: *Vm) Outcome {
    if (vm.frame.pc >= vm.function.code.len) return falloffReturn(vm);
    if (maybeStop(vm)) |o| return o;
    // A cold helper may have GROWN a heap stack (eval/generator/cold-call), which
    // reallocates stack.values.ptr. Refresh stack_base so the next handler's
    // `publish` (sp - stack_base) and falloff checks use the LIVE buffer base, not
    // a dangling pre-realloc pointer (the source of non-deterministic heap corruption).
    vm.stack_base = vm.stack.values.ptr;
    const npc = vm.code_base + vm.frame.pc;
    return @call(.always_tail, vm.tbl[npc[0]], .{ npc, vm.stack.values.ptr + vm.stack.values.len, vb, vm });
}

/// `Step`-returning helper (`.done`/`.continue_loop` — both re-dispatch in the
/// tail-call model). The d==0 entry guards are baked into `body`.
pub fn coldStd(comptime body: fn (vm: *Vm, pc: [*]const u8) HostError!void) Handler {
    return struct {
        fn h(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
            vm.publish(pc, sp);
            body(vm, pc) catch |e| return vm.fail(e);
            return coldNext(vb, vm);
        }
    }.h;
}

/// Plain `try helper(...)` arm (no result union) — identical shell to coldStd; the
/// distinction is only at the body (no `switch`). Kept separate for readability.
const coldPlain = coldStd;

/// Generator/await arm `{ .none, .continue_loop, .return_value }` — `.return_value`
/// exits the whole chain (a yield/await suspends the frame).
pub fn coldGen(comptime body: fn (vm: *Vm, pc: [*]const u8) HostError!?JSValue) Handler {
    return struct {
        fn h(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
            vm.publish(pc, sp);
            if (body(vm, pc) catch |e| return vm.fail(e)) |value| {
                vm.return_value = value;
                return .returned;
            }
            return coldNext(vb, vm);
        }
    }.h;
}

// ---- d==0 entry-guard accessors (mirror the dispatchLoop `(if depth==0 ...)`) ----
inline fn evLocalNames(vm: *Vm) []const core.Atom {
    return if (vm.machine.depth == 0) vm.l0.eval_local_names else &.{};
}
inline fn evWithObject(vm: *Vm) JSValue {
    return if (vm.machine.depth == 0) vm.l0.eval_with_object else JSValue.undefinedValue();
}
inline fn evIsEval(vm: *Vm) bool {
    return if (vm.machine.depth == 0) vm.l0.is_eval_code else false;
}

// ===========================================================================
// Endpoint handlers
// ===========================================================================

fn op_falloff(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    _ = pc;
    _ = var_buf;
    // Sync stack.values from the register sp so falloffReturn's stack.peek() sees
    // the live top, then dup the completion value (see falloffReturn).
    vm.stack.values = vm.stack_base[0 .. (@intFromPtr(sp) - @intFromPtr(vm.stack_base)) / @sizeOf(JSValue)];
    return falloffReturn(vm);
}

fn op_invalid(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    _ = sp;
    _ = var_buf;
    const pc_off = @intFromPtr(pc) - @intFromPtr(vm.code_base);
    std.debug.panic("tailcall: invalid opcode {d} at pc_off={d}", .{ pc[0], pc_off });
}

// ===========================================================================
// Cold handlers + specials. v1 routes every op (incl. would-be hot ones) through a
// cold handler for correctness; the frame-zero fast paths (get_loc/put_loc/arith)
// are a perf follow-up — they do NOT change the frame story (each op is its own
// function regardless). The catch_target field model is a single `?usize`; the
// per-frame save/restore on call/return is a TODO for the integration-debug phase.
// ===========================================================================

const vm_property_locals = @import("vm_property_locals.zig");

const eval_class_field_initializer_flag: u16 = 0x8000;
const eval_parameter_initializer_flag: u16 = 0x4000;

// ---- SPECIAL handlers (call / return / tail / drop / throw / eval / generator) ----

fn op_return(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    _ = vb;
    vm.publish(pc, sp);
    vm.return_value = control_vm.returnTop(vm.ctx, vm.stack, vm.frame, if (vm.machine.depth == 0) vm.l0.generator_state else null) catch |e| return vm.fail(e);
    return .returned;
}
fn op_return_undef(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    _ = vb;
    vm.publish(pc, sp);
    vm.return_value = control_vm.returnUndefined(vm.ctx, vm.frame, if (vm.machine.depth == 0) vm.l0.generator_state else null) catch |e| return vm.fail(e);
    return .returned;
}

fn op_call(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    vm.publish(pc, sp);
    switch (call_vm.call(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, pc[0], &vm.tail_request) catch |e| return vm.fail(e)) {
        .done, .continue_loop => return coldNext(vb, vm),
        .inline_call => {
            vm.tail_is_reuse = false;
            return .tail;
        },
    }
}
fn op_call_method(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    vm.publish(pc, sp);
    switch (call_vm.callMethod(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, true, &vm.tail_request) catch |e| return vm.fail(e)) {
        .done, .continue_loop => return coldNext(vb, vm),
        .inline_call => {
            vm.tail_is_reuse = false;
            return .tail;
        },
    }
}
fn op_tail_call(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    vm.publish(pc, sp);
    switch (call_vm.tailCall(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, vm.machine.depth > 0, &vm.tail_request) catch |e| return vm.fail(e)) {
        .handled => return coldNext(vb, vm),
        .return_value => |value| {
            vm.return_value = value;
            return .returned;
        },
        .tail_inline => {
            vm.tail_is_reuse = true;
            return .tail;
        },
    }
}
fn op_tail_call_method(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    vm.publish(pc, sp);
    switch (call_vm.tailCallMethod(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, vm.machine.depth > 0, &vm.tail_request) catch |e| return vm.fail(e)) {
        .handled => return coldNext(vb, vm),
        .return_value => |value| {
            vm.return_value = value;
            return .returned;
        },
        .tail_inline => {
            vm.tail_is_reuse = true;
            return .tail;
        },
    }
}
fn op_eval(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    vm.publish(pc, sp);
    switch (eval_module_vm.directEval(vm.ctx, vm.stack, vm.function, vm.frame, vm.catch_target, vm.output, vm.global, eval_class_field_initializer_flag, eval_parameter_initializer_flag, vm.machine.depth > 0) catch |e| return vm.fail(e)) {
        .done, .continue_loop => return coldNext(vb, vm),
        .tail_inline => |request| {
            vm.tail_request = request;
            vm.tail_is_reuse = true;
            return .tail;
        },
    }
}
fn op_drop(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    vm.publish(pc, sp);
    switch (value_vm.drop(vm.ctx.runtime, vm.stack) catch |e| return vm.fail(e)) {
        .value => return coldNext(vb, vm),
        .catch_target => |target| {
            vm.catch_target.* = target;
            return coldNext(vb, vm);
        },
    }
}
fn op_throw(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    vm.publish(pc, sp);
    switch (control_vm.throwTop(vm.ctx, vm.output, vm.global, vm.stack, vm.frame, vm.catch_target) catch |e| return vm.fail(e)) {
        .handled => return coldNext(vb, vm),
    }
}
fn op_throw_error(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    vm.publish(pc, sp);
    switch (control_vm.throwErrorVm(vm.ctx, vm.stack, vm.function, vm.frame, vm.catch_target, vm.global) catch |e| return vm.fail(e)) {
        .handled => return coldNext(vb, vm),
    }
}

const h_initial_yield = coldGen(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!?JSValue {
        _ = pc;
        switch (try gen_async_vm.initialYield(vm.ctx, vm.stack, vm.frame, if (vm.machine.depth == 0) vm.l0.generator_state else null, if (vm.machine.depth == 0) vm.l0.stop_on_yield else false)) {
            .none, .continue_loop => return null,
            .return_value => |v| return v,
        }
    }
}.b);
const h_yield = coldGen(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!?JSValue {
        _ = pc;
        switch (try gen_async_vm.yieldValue(vm.ctx, vm.stack, vm.frame, if (vm.machine.depth == 0) vm.l0.generator_state else null, if (vm.machine.depth == 0) vm.l0.stop_on_yield else false)) {
            .none, .continue_loop => return null,
            .return_value => |v| return v,
        }
    }
}.b);
const h_yield_star = coldGen(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!?JSValue {
        _ = pc;
        switch (try gen_async_vm.yieldStar(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, if (vm.machine.depth == 0) vm.l0.generator_state else null, if (vm.machine.depth == 0) vm.l0.stop_on_yield else false, vm.catch_target)) {
            .none, .continue_loop => return null,
            .return_value => |v| return v,
        }
    }
}.b);
const h_await = coldGen(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!?JSValue {
        _ = pc;
        switch (try gen_async_vm.awaitValue(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, if (vm.machine.depth == 0) vm.l0.generator_state else null, if (vm.machine.depth == 0) vm.l0.suspend_on_module_await else false, if (vm.machine.depth == 0) vm.l0.stop_on_yield else false, vm.catch_target)) {
            .none, .continue_loop => return null,
            .return_value => |v| return v,
        }
    }
}.b);

// ===========================================================================
// Hot fast-path handlers — the op's work inlined on the register-resident
// sp/var_buf/arg_buf, advancing pc + tail-dispatching via `next` with NO
// publish/helper/coldNext. Mirrors dispatchLoop's `if (comptime thread_dispatch)`
// threaded arms (zjs_vm.zig). On a guard miss (var-ref cell / non-int operand /
// generator stop boundary) the handler tail-calls its COLD counterpart with the
// ORIGINAL pc/sp so the cold `publish` syncs stack.values/frame.pc from the live
// sp — exactly dispatchLoop's reg_sp/reg_ip-with-lazy-syncDown model.
// ===========================================================================
const value_ops = @import("value_ops.zig");

const LocalOperand = struct { idx: u16, consume: usize };

inline fn decodeLocalOperand(opc: u8, operand: [*]const u8) LocalOperand {
    return switch (opc) {
        op.get_loc, op.put_loc, op.set_loc => .{ .idx = readInt(u16, operand), .consume = 2 },
        op.get_loc8, op.put_loc8, op.set_loc8 => .{ .idx = @intCast(operand[0]), .consume = 1 },
        op.get_loc0, op.get_loc1, op.get_loc2, op.get_loc3 => .{ .idx = @intCast(opc - op.get_loc0), .consume = 0 },
        op.put_loc0, op.put_loc1, op.put_loc2, op.put_loc3 => .{ .idx = @intCast(opc - op.put_loc0), .consume = 0 },
        op.set_loc0, op.set_loc1, op.set_loc2, op.set_loc3 => .{ .idx = @intCast(opc - op.set_loc0), .consume = 0 },
        else => unreachable,
    };
}

/// Register-resident int32 binary (mirrors zjs_vm.dispatchFastBinaryInt32). `null`
/// → not int32-representable / unsupported op → caller falls to the cold helper.
inline fn fastBinaryInt32(binop: u8, a: i32, b: i32) ?JSValue {
    return switch (binop) {
        op.add => blk: {
            const r = @addWithOverflow(a, b);
            break :blk if (r[1] == 0) JSValue.int32(r[0]) else value_ops.numberToValue(@as(f64, @floatFromInt(a)) + @as(f64, @floatFromInt(b)));
        },
        op.sub => blk: {
            const r = @subWithOverflow(a, b);
            break :blk if (r[1] == 0) JSValue.int32(r[0]) else value_ops.numberToValue(@as(f64, @floatFromInt(a)) - @as(f64, @floatFromInt(b)));
        },
        op.mul => blk: {
            if ((a == 0 and b < 0) or (b == 0 and a < 0)) break :blk JSValue.float64(-0.0);
            const r = @mulWithOverflow(a, b);
            break :blk if (r[1] == 0) JSValue.int32(r[0]) else value_ops.numberToValue(@as(f64, @floatFromInt(a)) * @as(f64, @floatFromInt(b)));
        },
        op.div => value_ops.numberToValue(@as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b))),
        op.mod => blk: {
            if (b == 0) break :blk JSValue.float64(std.math.nan(f64));
            if (b == -1) break :blk if (a < 0) JSValue.float64(-0.0) else JSValue.int32(0);
            const r = @rem(a, b);
            break :blk if (r == 0 and a < 0) JSValue.float64(-0.0) else JSValue.int32(r);
        },
        op.shl => JSValue.int32(a << @intCast(b & 31)),
        op.sar => JSValue.int32(a >> @intCast(b & 31)),
        op.shr => value_ops.numberToValue(@floatFromInt(@as(u32, @bitCast(a)) >> @intCast(b & 31))),
        op.@"and" => JSValue.int32(a & b),
        op.@"or" => JSValue.int32(a | b),
        op.xor => JSValue.int32(a ^ b),
        else => null,
    };
}

/// Direct dispatch to the handler for the opcode at `npc[0]`, SKIPPING `next`'s
/// fall-off bounds check + the `b next` indirection. Sound for linear ops: a fast
/// op is never the last instruction (the compiler always terminates a body with
/// return/return_undef), so `npc` never reaches code_end. Jumps (goto8/if_*8) keep
/// `next` because their target CAN be code_end (forward branch-to-end → fall-off).
inline fn cont(npc: [*]const u8, nsp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) Outcome {
    return @call(.always_tail, vm.tbl[npc[0]], .{ npc, nsp, var_buf, vm });
}

/// Per-variant local-access handler (qjs has OP_get_loc0..3 etc. as distinct labels).
/// `idx_src` resolves the local index at COMPILE time — no decodeLocalOperand csel
/// chain — and the handler direct-dispatches via `cont`. Replaces the one-handler-
/// for-18-variants op_loc whose runtime decode cost ~15 insn/op (measured).
const LocKind = enum { get, put, set };
const LocIdx = enum { c0, c1, c2, c3, byte, half };
pub fn opLoc(comptime kind: LocKind, comptime idx_src: LocIdx) Handler {
    return struct {
        fn h(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
            if (vm.local_fast_blocked) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
            const idx: u16 = switch (idx_src) {
                .c0 => 0,
                .c1 => 1,
                .c2 => 2,
                .c3 => 3,
                .byte => pc[1],
                .half => readInt(u16, pc + 1),
            };
            const advance: usize = switch (idx_src) {
                .c0, .c1, .c2, .c3 => 1,
                .byte => 2,
                .half => 3,
            };
            const old_v = var_buf[idx];
            if (slot_ops.varRefCellFromValue(old_v) != null) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
            switch (kind) {
                .get => {
                    sp[0] = old_v.dup();
                    return cont(pc + advance, sp + 1, var_buf, vm);
                },
                .put => {
                    const value = (sp - 1)[0];
                    if (slot_ops.varRefCellFromValue(value) != null) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
                    var_buf[idx] = value;
                    old_v.free(vm.ctx.runtime);
                    return cont(pc + advance, sp - 1, var_buf, vm);
                },
                .set => {
                    const value = (sp - 1)[0];
                    if (slot_ops.varRefCellFromValue(value) != null) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
                    const assigned = value.dup();
                    var_buf[idx] = assigned;
                    old_v.free(vm.ctx.runtime);
                    return cont(pc + advance, sp, var_buf, vm);
                },
            }
        }
    }.h;
}

/// Closure/global var-ref read (qjs OP_get_var_ref0..3 distinct labels). The `fib`
/// recursive self-reference is get_var_ref0 — fib's per-call hottest non-call op.
/// Deleted / TDZ-uninitialized / chained-import-cell route to the cold resolver.
const VarRefIdx = enum { c0, c1, c2, c3, half };
pub fn opGetVarRef(comptime idx_src: VarRefIdx) Handler {
    return struct {
        fn h(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
            const idx: u16 = switch (idx_src) {
                .c0 => 0,
                .c1 => 1,
                .c2 => 2,
                .c3 => 3,
                .half => readInt(u16, pc + 1),
            };
            const advance: usize = switch (idx_src) {
                .c0, .c1, .c2, .c3 => 1,
                .half => 3,
            };
            if (idx >= vm.frame.var_refs.len) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
            const cell = slot_ops.varRefCellFromValue(vm.frame.var_refs.ptr[idx]) orelse return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
            if (cell.is_deleted) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
            const v = cell.pvalue.*;
            if (v.isUninitialized()) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
            if (core.VarRef.fromValue(v) != null) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
            sp[0] = v.dup();
            return cont(pc + advance, sp + 1, var_buf, vm);
        }
    }.h;
}

pub fn op_push_i32(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    sp[0] = JSValue.int32(readInt(i32, pc + 1));
    return cont(pc + 5, sp + 1, var_buf, vm);
}
pub fn op_push_i16(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    sp[0] = JSValue.int32(readInt(i16, pc + 1));
    return cont(pc + 3, sp + 1, var_buf, vm);
}
pub fn op_push_i8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    sp[0] = JSValue.int32(@as(i8, @bitCast(pc[1])));
    return cont(pc + 2, sp + 1, var_buf, vm);
}
pub fn op_push_small(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const value: i32 = switch (pc[0]) {
        op.push_minus1 => -1,
        op.push_0 => 0,
        op.push_1 => 1,
        op.push_2 => 2,
        op.push_3 => 3,
        op.push_4 => 4,
        op.push_5 => 5,
        op.push_6 => 6,
        op.push_7 => 7,
        else => unreachable,
    };
    sp[0] = JSValue.int32(value);
    return cont(pc + 1, sp + 1, var_buf, vm);
}

pub fn op_get_arg_short(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const v = vm.arg_buf[pc[0] - op.get_arg0];
    if (slot_ops.varRefCellFromValue(v) != null) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    sp[0] = v.dup();
    return cont(pc + 1, sp + 1, var_buf, vm);
}

// Hot inline get_field — qjs OP_get_field's inline-cache fast path. On a monomorphic
// IC hit (the cached shape still matches the receiver) reads the property's data slot
// directly and dispatches, skipping the cold field()'s publish→helper→coldNext shell.
// IC miss / first access / non-object / profiling falls to the cold field, which runs
// the full lookup AND installs the IC for the next time around. 5-byte op (atom u32).
pub fn op_get_field(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const receiver = (sp - 1)[0];
    const atom_id = readInt(u32, pc + 1);
    const site_pc = @intFromPtr(pc) - @intFromPtr(vm.code_base);
    if (property_ic.cachedDataPropertyValueForFastPath(vm.function, site_pc, vm.ctx.runtime, receiver, atom_id)) |value| {
        // IC hit: the value is BORROWED from the object's slot — dup onto the stack
        // (which owns its entries) and free the receiver, exactly like replaceTopBorrowed.
        (sp - 1)[0] = if (value.requiresRefCount()) value.dup() else value;
        receiver.free(vm.ctx.runtime);
        return cont(pc + 5, sp, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

// Hot inline get_field2 for primitive-string method resolution — the receiver of
// a `"...".method(...)` call (and every template literal, which compiles to
// `head.concat(...)`). get_field2 keeps the receiver on the stack and pushes the
// resolved method on top. A standard String.prototype method resolves directly
// (getFastStringPrimitiveDataProperty returns it dup'd/owned), skipping the cold
// get_field2's getValueProperty -> getPrimitiveProperty detour. Non-string
// receivers, non-standard names, and object/IC/prototype-method cases fall to the
// cold h_field (whose borrowed-vs-owned push distinctions stay in one place).
pub fn op_get_field2(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const receiver = (sp - 1)[0];
    const atom_id = readInt(u32, pc + 1);
    // Object receiver: own-or-prototype data/method via the same self+prototype
    // walk the cold get_field2 runs first (e.g. arr.push, map.get). The value is
    // BORROWED from its holder slot, so dup it onto the stack exactly as the cold
    // path's `pushAssumeCapacity` does; the receiver stays beneath as `this`.
    if (vm_property_field.qjsGetFieldFast(vm.ctx.runtime, receiver, atom_id)) |value| {
        sp[0] = if (value.requiresRefCount()) value.dup() else value;
        return cont(pc + 5, sp + 1, var_buf, vm);
    }
    // Primitive string receiver: standard String.prototype method (and every
    // template literal, compiled to head.concat(...)). Returned value is owned.
    if (receiver.isString()) {
        const resolved = string_ops.getFastStringPrimitiveDataProperty(vm.ctx, vm.global, receiver, atom_id) catch |e| return vm.fail(e);
        if (resolved) |value| {
            sp[0] = value; // owned; receiver stays at sp-1 as the call's `this`
            return cont(pc + 5, sp + 1, var_buf, vm);
        }
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

// Hot inline put_field — qjs OP_put_field's monomorphic IC: o.x = v writes the
// value straight into the cached slot when the receiver's shape matches the site's
// monomorphic IC entry (no allocation, no shape transition). IC miss / new property /
// setter / exotic receiver fall to the cold h_field, which runs the full put fast
// path (simple-put + IC install) then the slow setValueProperty. Stack is
// [obj, value]; on a hit value is consumed by the slot write and obj is freed.
pub fn op_put_field(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    const obj = (sp - 2)[0];
    const atom_id = readInt(u32, pc + 1);
    const site_pc = @intFromPtr(pc) - @intFromPtr(vm.code_base);
    if (property_ic.cachedSetObjectDataPropertyForPutFastPath(vm.function, site_pc, vm.ctx.runtime, obj, atom_id, value)) {
        obj.free(vm.ctx.runtime); // value consumed by the slot write
        return cont(pc + 5, sp - 2, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

// Hot inline get_array_el — qjs OP_get_array_el's dense fast path: a[i] on a fast
// array with a non-negative int32 index reads the element directly (dup'd) and pops
// the [obj, key] pair to [value]. Holey/out-of-range/string-key/typed-array/proxy/
// negative falls to the cold arrayElement. 1-byte op (operands are on the stack).
pub fn op_get_array_el(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const key = (sp - 1)[0];
    const obj = (sp - 2)[0];
    if (vm_property_field.fastDenseArrayElementValue(obj, key)) |value| {
        obj.free(vm.ctx.runtime);
        key.free(vm.ctx.runtime);
        (sp - 2)[0] = value; // owned (fastArrayElementDup dups)
        return cont(pc + 1, sp - 1, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

// Hot inline get_length — qjs reads a primitive string's `.length` inline
// (`OP_get_field` length fast leg: `JS_VALUE_GET_STRING(sp[-1])->len`) instead of
// routing through the general property machinery. A string operand (flat or rope —
// `len()` reads the rope's logical length without flattening) pushes its character
// count directly, replacing the popped string. String WRAPPER objects, arrays,
// typed arrays, and everything else fall to the cold getLength (full getValueProperty).
// 1-byte op (operand on the stack).
pub fn op_get_length(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    if (value.isString()) {
        const len_val = JSValue.int32(@intCast(value.asStringBody().?.len()));
        value.free(vm.ctx.runtime);
        (sp - 1)[0] = len_val;
        return cont(pc + 1, sp, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

pub fn op_binary(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const opc = pc[0];
    if (opc != op.pow) {
        if ((sp - 2)[0].asInt32()) |a| {
            if ((sp - 1)[0].asInt32()) |b| {
                if (fastBinaryInt32(opc, a, b)) |result| {
                    (sp - 2)[0] = result;
                    return cont(pc + 1, sp - 1, var_buf, vm);
                }
            }
        }
    }
    switch (opc) {
        op.add, op.sub, op.mul, op.div, op.mod => {
            if ((sp - 2)[0].asNumber()) |fa| {
                if ((sp - 1)[0].asNumber()) |fb| {
                    const fout = switch (opc) {
                        op.add => fa + fb,
                        op.sub => fa - fb,
                        op.mul => fa * fb,
                        op.div => fa / fb,
                        op.mod => @rem(fa, fb),
                        else => unreachable,
                    };
                    (sp - 2)[0] = value_ops.numberToValue(fout);
                    return cont(pc + 1, sp - 1, var_buf, vm);
                }
            }
        },
        else => {},
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

pub fn op_compare(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const opc = pc[0];
    if ((sp - 2)[0].asInt32()) |a| {
        if ((sp - 1)[0].asInt32()) |b| {
            const r = switch (opc) {
                op.lt => a < b,
                op.lte => a <= b,
                op.gt => a > b,
                op.gte => a >= b,
                op.eq, op.strict_eq => a == b,
                op.neq, op.strict_neq => a != b,
                else => unreachable,
            };
            (sp - 2)[0] = JSValue.boolean(r);
            return cont(pc + 1, sp - 1, var_buf, vm);
        }
    }
    // qjs OP_CMP inlines the float64/int relational compare too (FLOAT64(a)||FLOAT64(b)
    // → convert both to double, compare) before falling to js_relational_slow. Both
    // operands are non-refcounted numbers here, so nothing to free. This is what makes
    // a float-counter `x < n` not pay the cold hop every iteration.
    switch (opc) {
        op.lt, op.lte, op.gt, op.gte => {
            if ((sp - 2)[0].asNumber()) |fa| {
                if ((sp - 1)[0].asNumber()) |fb| {
                    const r = switch (opc) {
                        op.lt => fa < fb,
                        op.lte => fa <= fb,
                        op.gt => fa > fb,
                        op.gte => fa >= fb,
                        else => unreachable,
                    };
                    (sp - 2)[0] = JSValue.boolean(r);
                    return cont(pc + 1, sp - 1, var_buf, vm);
                }
            }
        },
        else => {},
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

/// Dedicated cold handler for OP_lt/OP_le/…/OP_eq's non-(both-int32) operands — the
/// float-vs-int / float / object / loose-eq cases (qjs js_relational_slow /
/// js_eq_slow). Installed as the cold_table entry for the compare ops, so op_compare
/// reaches it through the same indirect `cold_table[pc[0]]` dispatch it always used
/// (a DIRECT tail-call here would perturb op_compare's int32 fast-path codegen — the
/// canonical `s=s+i` loop regressed +37 insn/iter when routed directly).
///
/// `compareAt` runs register-resident (no publish round-trip) and the handler writes
/// the result into sp[-2] + pops one, exactly like the int32 fast arm. The win
/// matters for float-counter loops (`for (var x=0.5; x<n; x++)`), whose `x < n`
/// misses the int32 arm every iteration. At a generator/eval stop boundary
/// (local_fast_blocked) it falls back to the publishing path so coldNext's maybeStop
/// can still suspend at stop_before_pc.
pub fn op_compare_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (vm.local_fast_blocked) {
        vm.publish(pc, sp);
        _ = arith_vm.compareVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, pc[0], vm.output, vm.global) catch |e| return vm.fail(e);
        return coldNext(var_buf, vm);
    }
    const lhs = (sp - 2)[0];
    const rhs = (sp - 1)[0];
    vm.syncPc(pc, 1); // qjs sf->cur_pc — backtrace fidelity through ToPrimitive valueOf (compare ops are 1 byte)
    const result = arith_vm.compareAt(vm.ctx, vm.global, vm.output, pc[0], lhs, rhs) catch |err| {
        // Error only: compareAt freed both operands, so publish the doubly-popped sp
        // (frame.pc → next op) for a consistent catch stack.
        vm.publish(pc, sp - 2);
        const caught = call_runtime.handleCatchableRuntimeError(vm.ctx, vm.stack, vm.frame, vm.catch_target, vm.global, err) catch |e2| return vm.fail(e2);
        if (!caught) return vm.fail(err);
        return coldNext(var_buf, vm);
    };
    (sp - 2)[0] = result;
    return cont(pc + 1, sp - 1, var_buf, vm);
}

pub fn op_inc_dec(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const opc = pc[0];
    if ((sp - 1)[0].asInt32()) |iv| {
        const res = if (opc == op.inc) @addWithOverflow(iv, 1) else @subWithOverflow(iv, 1);
        if (res[1] == 0) {
            (sp - 1)[0] = JSValue.int32(res[0]);
            return cont(pc + 1, sp, var_buf, vm);
        }
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

pub fn op_dup(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const v = (sp - 1)[0];
    sp[0] = if (v.requiresRefCount()) v.dup() else v;
    return cont(pc + 1, sp + 1, var_buf, vm);
}
pub fn op_swap(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const tmp = (sp - 2)[0];
    (sp - 2)[0] = (sp - 1)[0];
    (sp - 1)[0] = tmp;
    return cont(pc + 1, sp, var_buf, vm);
}

// Control flow (8-bit displacement). The displacement is relative to the operand
// byte (pc+1), matching dispatchLoop's `operand_pc = reg_ip - code.ptr`. Jumping to
// a target ≥ code_end (forward branch-to-end) is handled by `next`'s own fall-off
// check, so no explicit branch-to-end test is needed here. NOTE: the interrupt poll
// dispatchLoop runs on backward jumps is intentionally omitted — this dispatcher
// does not poll anywhere yet (a runtime-wide faithfulness follow-up, irrelevant to
// test262 which installs no interrupt handler).
inline fn jump8Target(pc: [*]const u8, vm: *Vm) [*]const u8 {
    const operand_pc = @intFromPtr(pc + 1) - @intFromPtr(vm.code_base);
    const diff: i8 = @bitCast(pc[1]);
    return vm.code_base + @as(usize, @intCast(@as(i64, @intCast(operand_pc)) + @as(i64, diff)));
}
pub fn op_goto8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return @call(.always_tail, next, .{ jump8Target(pc, vm), sp, var_buf, vm });
}
// The boolean fast path (a comparison result — the hot loop condition) inlines; a
// non-boolean condition routes to cold_table[pc[0]] (the generic branch8 handler).
// That routing is INDIRECT, which LLVM cannot inline back — so the hot handler stays
// prologue-free (a direct tail-call to a local slow shell got re-inlined, dragging in
// its 64B frame + callee-saved spills, which pressured the store buffer and stalled
// the boolean's store→load forward from op_compare). Booleans need no free / no call.
pub fn op_if_false8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if ((sp - 1)[0].asBool()) |b| {
        if (!b) return @call(.always_tail, next, .{ jump8Target(pc, vm), sp - 1, var_buf, vm });
        return cont(pc + 2, sp - 1, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}
pub fn op_if_true8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if ((sp - 1)[0].asBool()) |b| {
        if (b) return @call(.always_tail, next, .{ jump8Target(pc, vm), sp - 1, var_buf, vm });
        return cont(pc + 2, sp - 1, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

// Fused local-update ops (1-byte local index). qjs OP_inc_loc/OP_add_loc — the
// hottest loop ops (`i++`, `s += i`), so a cold miss here dominates loop regression.
// int32-only; var-ref cell / non-int / generator-boundary fall back to the cold op.
pub fn op_update_loc(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (vm.local_fast_blocked) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    const idx: u16 = pc[1];
    const old_v = var_buf[idx];
    // No explicit var-ref cell check: a cell is an object, so `asInt32` below fails on
    // it and routes to the cold op (op_update_loc_cold → updateLocalAt, which walks the
    // cell) — the check is redundant. (Cells DO occur here: an eval `var x` boxed by a
    // nested closure is reached by inc_loc; only normal-function locals are guaranteed
    // non-captured.)
    const iv = old_v.asInt32() orelse return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    // qjs OP_inc_loc/OP_dec_loc: branch on the single overflow value (INT32_MAX/MIN),
    // then a plain int add — NOT the int64-widen + range-check that fastInt32Add (=
    // qjs's OP_add path) compiles to a branchless scvtf/fcsel. The scvtf computes the
    // float fallback unconditionally and sits on the loop-carried counter chain; the
    // predicted-not-taken overflow branch keeps the chain to load→add→store. Overflow
    // (rare) falls to the cold op, whose updateLocalAt redoes it with the float box.
    if (pc[0] == op.inc_loc) {
        if (iv == std.math.maxInt(i32)) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
        var_buf[idx] = JSValue.int32(iv + 1);
    } else {
        if (iv == std.math.minInt(i32)) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
        var_buf[idx] = JSValue.int32(iv - 1);
    }
    return cont(pc + 2, sp, var_buf, vm);
}

/// Dedicated cold handler for OP_inc_loc/OP_dec_loc's non-int32 operand (float /
/// BigInt / object counter — the `for (var x=0.5; …; x++)` shape). Installed as the
/// cold_table entry for inc_loc/dec_loc, so op_update_loc reaches it via the same
/// indirect `cold_table[pc[0]]` dispatch (a direct tail-call would perturb the int32
/// fast-path codegen, like op_compare_cold). `updateLocalAt` runs register-resident
/// (no publish round-trip); inc/dec is stack-neutral so sp is unchanged. At a
/// generator/eval stop boundary (local_fast_blocked — op_update_loc routes blocked
/// AND cell here) it uses the publishing path so coldNext's maybeStop still fires.
pub fn op_update_loc_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (vm.local_fast_blocked) {
        vm.publish(pc, sp);
        _ = arith_vm.updateLocalVm(vm.ctx, vm.stack, vm.function, vm.global, vm.frame, vm.catch_target, pc[0], vm.output) catch |e| return vm.fail(e);
        return coldNext(var_buf, vm);
    }
    const idx: u16 = pc[1];
    vm.syncPc(pc, 2); // qjs sf->cur_pc — backtrace fidelity through valueOf (see op_add_loc_cold)
    arith_vm.updateLocalAt(vm.ctx, vm.global, vm.output, &var_buf[idx], pc[0]) catch |err| {
        vm.publish(pc + 1, sp);
        const caught = call_runtime.handleCatchableRuntimeError(vm.ctx, vm.stack, vm.frame, vm.catch_target, vm.global, err) catch |e2| return vm.fail(e2);
        if (!caught) return vm.fail(err);
        return coldNext(var_buf, vm);
    };
    return cont(pc + 2, sp, var_buf, vm);
}
pub fn op_add_loc(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (vm.local_fast_blocked) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    const idx: u16 = pc[1];
    const old_v = var_buf[idx];
    // No explicit var-ref cell check: a cell is an object, so it misses both asInt32
    // and asFloat64 below and falls to op_add_loc_cold (== cold_table[add_loc], whose
    // addLocalAt walks the cell) — the check is redundant. (Cells DO occur here: an
    // eval `var x` boxed by a nested closure is reached by add_loc.)
    const rhs_v = (sp - 1)[0];
    // qjs OP_add_loc inlines exactly JS_VALUE_IS_BOTH_INT and JS_VALUE_IS_BOTH_FLOAT
    // (and both-string) before falling to js_add_slow. Match the two numeric ones:
    // int32 (overflow→float via fastInt32Add) and float64+float64 (bare
    // __JS_NewFloat64, no int32 renormalization). Both operands are non-refcounted
    // here, so the store is a bare overwrite and the popped rhs needs no free.
    // A mixed int+float (or any other operand) deliberately misses both and falls
    // to the cold js_add_slow shell, exactly as qjs routes it.
    if (old_v.asInt32()) |lhs| {
        if (rhs_v.asInt32()) |rhs| {
            var_buf[idx] = arith_vm.fastInt32Add(lhs, rhs);
            return cont(pc + 2, sp - 1, var_buf, vm);
        }
    }
    if (old_v.asFloat64()) |lhs| {
        if (rhs_v.asFloat64()) |rhs| {
            var_buf[idx] = core.JSValue.float64(lhs + rhs);
            return cont(pc + 2, sp - 1, var_buf, vm);
        }
    }
    return @call(.always_tail, op_add_loc_cold, .{ pc, sp, var_buf, vm });
}

/// Dedicated cold handler for OP_add_loc's non-(both-int/both-float) operands — the
/// int+float / string / object / BigInt path that qjs routes to js_add_slow.
/// Collapses the generic `coldStd → addLocalVm` two-function chain into ONE: the
/// `addLocal` slow body inlines here, so the critical path is `op_add_loc → this →
/// store` (one cold hop, like qjs OP_add_loc→js_add_slow) instead of crossing an
/// extra noinline `addLocalVm` call boundary every iteration — which the backend
/// stalled on (int+float 29.7% idle cycles, measured). NOT a numeric fast path: it
/// runs the exact same full `addLocal` (int+float stays with object/BigInt), unhopped.
pub fn op_add_loc_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const idx: u16 = pc[1];
    const rhs = (sp - 1)[0];
    // qjs OP_add_loc → js_add_loc_slow(ctx, pv, sp): hand the local slot pointer and
    // the rhs VALUE straight to the slow add, pc/sp staying register-resident. No
    // `publish` on the hot path — `addLocalAt` neither re-reads frame.pc for the
    // operand nor pops the stack, so the per-iteration frame.pc memory round-trip
    // (publish→re-read→coldNext) that the backend stalled on is gone. On success we
    // fall straight through to the next op with sp popped by one (the consumed rhs),
    // exactly like the both-int/both-float fast arms above.
    // qjs `sf->cur_pc = pc` (set before js_add_loc_slow): keep frame.pc live so a
    // backtrace captured inside an object operand's valueOf/toString reports this op.
    vm.syncPc(pc, 2);
    arith_vm.addLocalAt(vm.ctx, vm.global, vm.output, &var_buf[idx], rhs) catch |err| {
        // Error only: also sync the popped sp so the catch unwinder sees consistent
        // state. addLocalAt already freed rhs, so the published length excludes the
        // dead slot — no double free.
        vm.publish(pc + 1, sp - 1);
        const caught = call_runtime.handleCatchableRuntimeError(vm.ctx, vm.stack, vm.frame, vm.catch_target, vm.global, err) catch |e2| return vm.fail(e2);
        if (!caught) return vm.fail(err);
        return coldNext(var_buf, vm);
    };
    return cont(pc + 2, sp - 1, var_buf, vm);
}

// Global var read (2-byte var-ref index). qjs OP_get_var_ref-backed global cell read
// — the per-call `fib` lookup in recursive code. Any dynamic-overlay / shadow / TDZ /
// deleted / nested-var-ref condition falls back to the cold getVar resolver.
pub fn op_get_var(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (vm.local_fast_blocked) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    if (vm_property_globals.hasDynamicGlobalOverlay(vm.frame, evLocalNames(vm), vm.frame.evalVarRefNames(), evWithObject(vm))) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    const idx = readInt(u16, pc + 1);
    if (idx >= vm.frame.var_refs.len) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    const cell = slot_ops.varRefCellFromValue(vm.frame.var_refs.ptr[idx]) orelse return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    if (cell.is_deleted) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    const v = cell.pvalue.*;
    if (v.isUninitialized()) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    if (core.VarRef.fromValue(v) != null) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    if (vm_property_globals.globalLexicalShadowsGlobalForIdx(vm.ctx, vm.global, vm.function, idx)) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    if (vm_property_globals.parentEvalShadowsGlobalForIdx(vm.ctx.runtime, vm.frame, vm.function, idx)) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    sp[0] = v.dup();
    return cont(pc + 3, sp + 1, var_buf, vm);
}

// ---- COLD handlers (the migration table, transcribed). dispatch_table assembled
//      at the end references these. The bulk lives in colds.zig via @import to keep
//      this file readable; see the comptime-included block below. ----
const colds = @import("tailcall_dispatch_colds.zig");

const specials: colds.SpecialHandlers = .{
    .op_return = op_return,
    .op_return_undef = op_return_undef,
    .op_call = op_call,
    .op_call_method = op_call_method,
    .op_tail_call = op_tail_call,
    .op_tail_call_method = op_tail_call_method,
    .op_eval = op_eval,
    .op_drop = op_drop,
    .op_throw = op_throw,
    .op_throw_error = op_throw_error,
    .h_initial_yield = h_initial_yield,
    .h_yield = h_yield,
    .h_yield_star = h_yield_star,
    .h_await = h_await,
    .op_invalid = op_invalid,
};
/// All-cold table (no fast overrides): the fast handlers tail-call THROUGH
/// `cold_table[pc[0]]` on a guard miss. The runtime index defeats devirtualization,
/// so the cold publish+helper is NOT inlined into the lean fast handler.
const cold_table: [256]Handler = colds.buildTable(specials, false);
const dispatch_table: [256]Handler = colds.buildTable(specials, true);

// ===========================================================================
// Driver — the Outcome loop. Replaces dispatchLoop's switch; reuses the Machine +
// the existing per-frame reload (reloadInlineTopFrame's arithmetic, inlined).
// ===========================================================================

fn reloadTop(vm: *Vm, pc: *[*]const u8, sp: *[*]JSValue, var_buf: *[*]JSValue) void {
    if (vm.machine.depth == 0) {
        // Returned to L0 — topEntry() is invalid; restore the captured L0 frame.
        vm.function = vm.l0_function;
        vm.frame = vm.l0_frame;
        vm.stack = vm.l0_stack;
        vm.catch_target = vm.l0_catch_target;
    } else {
        const entry = vm.machine.topEntry();
        vm.function = entry.function;
        vm.frame = &entry.frame;
        vm.stack = &entry.stack;
        vm.catch_target = &entry.catch_target;
    }
    vm.code_base = vm.function.code.ptr;
    vm.code_end = vm.function.code.ptr + vm.function.code.len;
    vm.stack_base = vm.stack.values.ptr;
    vm.arg_buf = vm.frame.args.ptr;
    vm.local_fast_blocked = vm.machine.depth == 0 and vm.l0.stop_before_pc != null;
    // NO `frame.pc += 1`: unlike reloadInlineTopFrame (which read+consumed the resume
    // opcode), our handlers read `pc[0]` themselves, so pc must point AT the resume op.
    pc.* = vm.code_base + vm.frame.pc;
    sp.* = vm.stack.values.ptr + vm.stack.values.len;
    var_buf.* = vm.frame.locals.ptr;
}

/// Run the tail-call chain to completion for the current top frame.
pub fn run(vm: *Vm) HostError!JSValue {
    vm.tbl = &dispatch_table; // resident table base (avoids per-dispatch adrp+add)
    vm.local_fast_blocked = vm.machine.depth == 0 and vm.l0.stop_before_pc != null;
    var pc = vm.code_base + vm.frame.pc;
    var sp = vm.reloadSp();
    var var_buf = vm.frame.locals.ptr;
    while (true) {
        switch (next(pc, sp, var_buf, vm)) {
            .returned => {
                if (vm.machine.depth == 0) return vm.return_value;
                try vm.machine.popReturn(vm.return_value);
                reloadTop(vm, &pc, &sp, &var_buf);
            },
            .threw => return vm.pending_error,
            .tail => {
                const req = vm.tail_request;
                if (vm.tail_is_reuse) {
                    try vm.machine.tailCallReuse(vm.global, vm.stack, req.target, req.region_base, req.argc, req.layout);
                } else {
                    // TODO(debug-phase): pushCall-setup failure must run
                    // closeStackTopForOfIteratorForPendingError + handleCatchableRuntimeError
                    // (op.call's `catch |err|` leg) before re-dispatching.
                    try vm.machine.pushCall(vm.global, vm.stack, req.target, req.region_base, req.argc, req.layout);
                }
                reloadTop(vm, &pc, &sp, &var_buf);
            },
            .suspended => return vm.return_value,
            .reenter => unreachable, // cold callees complete inside call_vm.call.
        }
    }
}

comptime {
    _ = &next;
    _ = &readInt;
    _ = &coldPlain;
    _ = &coldGen;
    _ = &coldStd;
    _ = &coldNext;
    _ = &evIsEval;
    _ = &evLocalNames;
    _ = &evWithObject;
    _ = &op_falloff;
    _ = &run;
    _ = dispatch_table;
}
