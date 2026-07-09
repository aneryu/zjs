//! Tail-call dispatch — terminal-state rewrite (docs/qjs-align/CALL-MACHINERY-FAITHFUL-FRONTIER.md).
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
const bytecode = @import("../bytecode.zig");
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
const property_vm = @import("vm_property.zig");
const vm_property_field = @import("vm_property_field.zig");
const property_ic = @import("property_ic.zig");
const vm_property_private = @import("vm_property_private.zig");
const string_ops = @import("string_ops.zig");
const array_ops = @import("array_ops.zig");
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

    /// Interrupt poll state — qjs polls on every OP_goto (quickjs.c:18822,
    /// `js_poll_interrupts`) and at JS_CallInternal entry (17787). Gated on an
    /// installed handler (`poller.active`) like the old dispatchLoop leg: with
    /// none installed the jump handlers stay poll-free.
    poller: control_vm.InterruptPoller,

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
inline fn maybeStop(vm: *Vm, out: *Outcome) bool {
    if (vm.machine.depth == 0) {
        const stop_before_pc = vm.l0.stop_before_pc orelse return false;
        const r = gen_async_vm.stopBeforePc(vm.ctx, vm.stack, vm.frame, vm.l0.generator_state, stop_before_pc) catch |e| {
            out.* = vm.fail(e);
            return true;
        };
        if (r) |v| {
            vm.return_value = v;
            out.* = .returned;
            return true;
        }
    }
    return false;
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
    var stop_out: Outcome = undefined;
    if (maybeStop(vm, &stop_out)) return stop_out;
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
    _ = pc;
    _ = sp;
    _ = var_buf;
    vm.pending_error = error.InvalidBytecode;
    return .threw;
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

/// op.call's `catch |err|` recovery, shared by the in-handler push (below)
/// and kept verbatim from the driver's old `.tail` arm: close a pending
/// for-of iterator, then try to convert the setup failure (OOM-class) into a
/// JS-catchable error in the CALLER frame. Returns true when the caller frame
/// caught it (frame.pc is at the handler — re-dispatch via coldNext); false
/// when it must propagate (vm.pending_error is set). Kept OUT of the handler
/// (noinline) so the cold recovery never touches the hot path's registers.
noinline fn callSetupRecover(vm: *Vm, err: HostError) bool {
    forof_ops.closeStackTopForOfIteratorForPendingError(vm.ctx, vm.output, vm.global, vm.stack) catch |e2| {
        vm.pending_error = e2;
        return false;
    };
    const caught = call_runtime.handleCatchableRuntimeError(vm.ctx, vm.stack, vm.frame, vm.catch_target, vm.global, err) catch |e2| {
        vm.pending_error = e2;
        return false;
    };
    if (!caught) {
        vm.pending_error = err;
        return false;
    }
    return true;
}

/// Complete an inline call INSIDE the handler — qjs's CASE(OP_call) shape
/// (quickjs.c:18182-18202): push the callee frame, poll interrupts at call
/// entry (17787), reload the per-frame registers, and tail-dispatch straight
/// into the callee's first opcode. No driver round-trip: no Outcome encode,
/// no tail_request staging, no driver-side spill/reload detour. Expanded
/// inline into the (Handler-signature) caller so the tail calls are legal.
inline fn pushAndEnter(vb: [*]JSValue, vm: *Vm, target: *const inline_calls.InlineTarget, region_base: usize, argc: u16, layout: inline_calls.RegionLayout) Outcome {
    const entry = vm.machine.pushCall(vm.global, vm.stack, target, region_base, argc, layout) catch |err| {
        if (!callSetupRecover(vm, err)) return .threw;
        return coldNext(vb, vm);
    };
    if (vm.poller.active) {
        vm.poller.poll(vm.ctx.runtime) catch |err| return vm.fail(err);
    }
    // Enter the entry pushCall handed back instead of reloading
    // `machine.top` — qjs enters the callee via the alloca result pointer
    // already in a register (quickjs.c:17846); this is the equivalent
    // pointer pass-through (pushFrame just stored the same pointer into
    // `machine.top`, quickjs.c:17870). The manual expansion below is
    // reloadTop's depth>0 arm verbatim.
    vm.function = entry.function;
    vm.frame = &entry.frame;
    vm.stack = &entry.stack;
    vm.catch_target = &entry.catch_target;
    vm.code_base = vm.function.code.ptr;
    vm.code_end = vm.function.code.ptr + vm.function.code.len;
    vm.stack_base = vm.stack.values.ptr;
    vm.arg_buf = vm.frame.args.ptr;
    // Just pushed, so depth > 0; the generator stop-boundary guard is L0-only.
    vm.local_fast_blocked = false;
    const pc2: [*]const u8 = vm.code_base; // fresh frame: frame.pc == 0
    const sp2: [*]JSValue = vm.stack.values.ptr + vm.stack.values.len;
    const vb2: [*]JSValue = vm.frame.locals.ptr;
    return @call(.always_tail, next, .{ pc2, sp2, vb2, vm });
}

/// Fused popReturn + reload for an in-handler return to an inline caller —
/// qjs OP_return + the done: epilogue (quickjs.c:18266, 20698-20710):
/// teardown, unlink the frame (`rt->current_stack_frame = sf->prev_frame`,
/// quickjs.c:20709), deliver the result into the caller's operand stack,
/// resume the caller — all in the handler. Expanded inline into the
/// Handler-signature caller so the tail call is legal.
inline fn popAndResume(vm: *Vm, value: JSValue) Outcome {
    const machine = vm.machine;
    const dying = machine.topEntry();
    // Straight-line teardown (qjs done: epilogue) unless execution escaped
    // the simple shape: grew the operand stack to the heap, materialized the
    // cold box (arguments object), or moved frame storage to the heap.
    if (dying.fast_teardown and dying.frame.cold == null and
        !dying.frame.storage_on_heap and dying.stack.arena_window)
    {
        inline_calls.Machine.teardownSimpleEntry(vm.ctx, dying);
    } else {
        inline_calls.Machine.teardownInlineEntry(vm.ctx, dying);
    }
    vm.ctx.call_depth -= 1;
    machine.depth -= 1;
    // qjs done: `rt->current_stack_frame = sf->prev_frame;` (quickjs.c:20709)
    // — the caller's Entry address comes from the chain, not from re-deriving
    // entryAt(depth-1) chunk arithmetic; reloadTop below reads it back.
    machine.top = dying.prev;
    machine.switched = true;
    var pc2: [*]const u8 = undefined;
    var sp2: [*]JSValue = undefined;
    var vb2: [*]JSValue = undefined;
    reloadTop(vm, &pc2, &sp2, &vb2);
    // Deliver the result on the (now-current) caller stack. AssumeCapacity
    // never reallocs, so the stack_base reloadTop captured stays valid; sp
    // just advances past the pushed slot.
    vm.stack.pushOwnedAssumeCapacity(value);
    sp2 += 1;
    return @call(.always_tail, next, .{ pc2, sp2, vb2, vm });
}

fn op_return(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    // qjs OP_return (quickjs.c:18266) is check-free and infallible: `ret_val =
    // *--sp; goto done;` — ret_val is a plain local carried in registers to the
    // done: epilogue. Derived-ctor return legality is a SEPARATE opcode there
    // (OP_check_ctor_return, quickjs.c:18273, emitted at parse time 28459) and
    // the depth-0/generator hand-off lives at the JS_CallInternal boundary —
    // neither is ever inline in OP_return's value dataflow. zjs's compiler does
    // not emit a check-ctor op, so the flag test must remain, but only as a
    // branch off to the cold sibling handler below: the hot leg carries the
    // value as a plain JSValue (no `!JSValue` error union, no memory phi)
    // straight into popAndResume.
    if (vm.frame.function.flags.is_derived_class_constructor or vm.machine.depth == 0)
        return @call(.always_tail, op_return_cold, .{ pc, sp, vb, vm });
    vm.publish(pc, sp);
    // returnTop's value grab minus the generator/ctor legs: dup the stack top
    // (the raw slot is freed by the frame teardown inside popAndResume).
    const value = vm.stack.peek() orelse JSValue.undefinedValue();
    return popAndResume(vm, value);
}
/// Cold sibling of op_return — the depth-0 exit (generator done-slot + driver
/// hand-off) and the derived-ctor return-legality machinery (qjs
/// OP_check_ctor_return, quickjs.c:18273; a flag-guarded cold handler here
/// because zjs has no separate opcode). Reached by tail call. (No `noinline`
/// keyword — it would change the fn type and break the always_tail match.
/// LLVM inlines it back as the flag-taken branch, which is fine: disassembly
/// shows the error-union spill slots confined to the cold branch while the
/// hot leg's value rides x8/x9 into the teardown with no strh/q0 round-trip.)
fn op_return_cold(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    _ = vb;
    vm.publish(pc, sp);
    const depth0 = vm.machine.depth == 0;
    const value = control_vm.returnTop(vm.ctx, vm.stack, vm.frame, if (depth0) vm.l0.generator_state else null) catch |e| return vm.fail(e);
    if (depth0) {
        vm.return_value = value;
        return .returned; // L0 exit stays on the driver
    }
    return popAndResume(vm, value);
}
fn op_return_undef(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    // Same split as op_return — qjs OP_return_undef (quickjs.c:18270) is
    // `ret_val = JS_UNDEFINED; goto done;`, check-free and infallible.
    if (vm.frame.function.flags.is_derived_class_constructor or vm.machine.depth == 0)
        return @call(.always_tail, op_return_undef_cold, .{ pc, sp, vb, vm });
    vm.publish(pc, sp);
    return popAndResume(vm, JSValue.undefinedValue());
}
/// Cold sibling of op_return_undef (see op_return_cold).
fn op_return_undef_cold(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    _ = vb;
    vm.publish(pc, sp);
    const depth0 = vm.machine.depth == 0;
    const value = control_vm.returnUndefined(vm.ctx, vm.frame, if (depth0) vm.l0.generator_state else null) catch |e| return vm.fail(e);
    if (depth0) {
        vm.return_value = value;
        return .returned;
    }
    return popAndResume(vm, value);
}

fn op_call(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    vm.publish(pc, sp);
    // Decode argc + advance the resume pc (op.call carries a 2-byte operand; the
    // call0..3 singletons carry none), matching call_vm.call's prologue.
    const argc: u16 = switch (pc[0]) {
        op.call => blk: {
            vm.frame.pc += 2;
            break :blk readInt(u16, pc + 1);
        },
        op.call0 => 0,
        op.call1 => 1,
        op.call2 => 2,
        op.call3 => 3,
        else => unreachable,
    };
    // Inline the common bytecode-to-bytecode resolution here instead of paying
    // execCall's 10-argument call boundary every iteration: resolveInlineTarget
    // (an inline fn) reads the callable off the operand region exactly as
    // execCall's inline leg does and, on a hit, completes the call in the
    // handler (qjs CASE(OP_call)). A miss (host fn / ctor / cross-realm /
    // underflow) falls to execCall with allow_inline=false.
    const total = @as(usize, argc) + 1;
    if (vm.stack.values.len >= total) {
        const region_base = vm.stack.values.len - total;
        const func = vm.stack.values[region_base];
        if (inline_calls.resolveInlineTarget(vm.ctx, vm.global, JSValue.undefinedValue(), func)) |target| {
            return pushAndEnter(vb, vm, &target, region_base, argc, .plain);
        }
    }
    switch (call_runtime.execCall(vm.ctx, vm.stack, vm.function, vm.frame, vm.catch_target, argc, vm.output, vm.global, false, &vm.tail_request) catch |e| return vm.fail(e)) {
        .done, .continue_loop => return coldNext(vb, vm),
        .inline_call => {
            vm.tail_is_reuse = false;
            return .tail;
        },
    }
}
fn op_call_method(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    vm.publish(pc, sp); // frame.pc now at the 2-byte argc operand
    const argc = readInt(u16, pc + 1);
    // Inline the bytecode-method resolution (recv.method() where method is a plain
    // bytecode function — OOP recursion, chained calls) instead of paying
    // callMethod's call boundary. Region is [receiver, callable, args...]; the
    // receiver becomes the callee's `this`. On a HIT advance the resume pc past the
    // operand and hand the driver a pushCall. On a MISS leave frame.pc AT the
    // operand so callMethod's own decode (native builtin dispatch, allow_inline
    // already tried here) reads it correctly.
    const total = @as(usize, argc) + 2;
    if (vm.stack.values.len >= total) {
        const region_base = vm.stack.values.len - total;
        const receiver = vm.stack.values[region_base];
        const method = vm.stack.values[region_base + 1];
        if (inline_calls.resolveInlineTarget(vm.ctx, vm.global, receiver, method)) |target| {
            vm.frame.pc += 2;
            return pushAndEnter(vb, vm, &target, region_base, argc, .method);
        }
    }
    switch (call_vm.callMethod(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, false, &vm.tail_request) catch |e| return vm.fail(e)) {
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
/// Frameless OP_drop (qjs CASE(OP_drop):17968 — `JS_FreeValue(ctx, sp[-1]); sp--`,
/// register-resident, no pc-publish / backtrace round-trip). Without this the
/// per-iteration `o = {…}` / `s = …` / `a = […]` loops route their trailing `drop`
/// (the stack copy left after `dup; put_loc_check`) through the 416-byte publishing
/// coldStd shell EVERY iteration — the ONLY hot op still cold in all four
/// object/array/string-literal benchmarks (see dispatch-audit).
///
/// GC-window contract (why this MUST shrink stack.values before free, unlike the
/// non-freeing op_dup/op_swap): the collector traces the operand roots as
/// `stack.values.ptr[0..stack.values.len]` (runtime.zig:1276). Fast handlers advance
/// only the register `sp`; `stack.values.len` is stale until a publish/syncDown (see
/// zjs_vm.syncDown — "fast paths advance only reg_sp"). op_dup/op_swap never free, so
/// a slot inside that window is always still live and a stale len is harmless. But
/// `drop` FREES sp[-1]: if that slot is still inside the traced window when a GC fires
/// during free() (rc→0 destroy → …, or a later alloc before the next publish), the
/// collector scans a freed value → use-after-free (nondeterministic in-process crash;
/// the cold path is safe only because value_vm.drop's `stack.pop()` shrinks
/// stack.values BEFORE free). So publish the post-drop operand length here first, then
/// free — the freed slot is then outside `[0..len]`. This is a single store off the
/// hot dependency chain (no pc write, no coldNext/maybeStop round-trip, no 416B frame).
///   - plain data value (int/bool/undefined): free is a tag-test no-op (requiresRefCount
///     early-out); the store+sp-- is the whole cost.
///   - still-live object/rope (`o`/`s` holds the other ref): register-resident refcount
///     decrement, now GC-safe against the shrunk window.
/// A `catch_offset` marker on top (the `try`/finally sentinel, drop's `.catch_target`
/// leg → mutates vm.catch_target.*) falls to the cold op via the indirect
/// `cold_table[pc[0]]` hop (op_if_false8 pattern — LLVM can't devirtualize it, so the
/// fast leaf stays prologue-free).
pub fn op_drop_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    // Generator/eval stop boundary: during a generator's parameter-init phase the
    // cold path's coldNext runs maybeStop (suspend at the body-start pc). `cont`
    // skips that check, so a `drop` that is the last param-init op would blow past the
    // suspend and execute the generator body eagerly (corrupting generator state — the
    // runGeneratorParameterInit crash). Fall to the publishing cold op when blocked,
    // exactly as opLoc/opLocCheck/op_update_loc do.
    if (vm.local_fast_blocked) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    const v = (sp - 1)[0];
    if (v.isCatchOffset()) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    // Shrink the GC-traced operand window to exclude the slot we are about to free
    // (mirrors value_vm.drop's stack.pop()-before-free); the freed slot must not be
    // reachable from stack.values[0..len] if free() triggers a collection.
    const nsp = sp - 1;
    vm.stack.values = vm.stack_base[0 .. (@intFromPtr(nsp) - @intFromPtr(vm.stack_base)) / @sizeOf(JSValue)];
    v.free(vm.ctx.runtime);
    return cont(pc + 1, nsp, var_buf, vm);
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

/// Per-op binary-arithmetic handlers — qjs gives every binary op its own CASE
/// label with its own JS_VALUE_IS_BOTH_INT fast leg (quickjs.c:19696 OP_add,
/// 19792 OP_sub, 19830 OP_mul, 19879 OP_div, 19895 OP_mod, 20113 OP_shl, 20133
/// OP_shr, 20154 OP_sar, 20174 OP_and, 20192 OP_or, 20210 OP_xor); OP_pow has
/// NO fast leg (19916 falls straight to js_binary_arith_slow — its table entry
/// stays the cold h_binary). The previous single op_binary handler fused all
/// eleven ops through one runtime `switch` returning `?JSValue`: LLVM gave each
/// arm's optional result a distinct stack slot (0x1e0 frame, non-coalescing) and
/// merged them through memory (`ldr q0/str q0` round-trip), and the float-mod
/// arm's `bl fmod` forced lr + 4 callee-saved pairs onto every int add — 44
/// insn/op against qjs's 22. Splitting per op (same knife as opLoc vs the fused
/// op_loc) leaves each handler a pure-register straight line: both-int tag fold
/// → int op (+overflow check) → 16-byte scalar store into sp[-2] → tail dispatch.
///
/// Guard misses take the INDIRECT `cold_table[pc[0]]` hop (op_if_false8 pattern:
/// the runtime index defeats devirtualization so the cold publish+helper is not
/// inlined back). Everything the qjs int leg does not fully resolve inline is
/// routed there rather than re-implemented: int overflow on add/sub/mul and
/// mul's -0 (qjs handles those in-CASE via __JS_NewFloat64, 19704/19800/19842/
/// 19847 — the cold path's vm_arith.fastInt32Add/Sub/Mul computes bit-identical
/// results), mod's `v1 < 0 || v2 <= 0` (qjs 19906 also goes slow), and every
/// non-(both-int) pairing. qjs OP_add/sub/mul additionally inline a float leg
/// (19710-19728) and OP_add a string leg (19729): those stay cold here — this
/// knife is int-only (the reverted op_add_loc float-inline precedent), and the
/// cold h_binary already carries the full float/string/object/BigInt protocol.
const BinOp = enum { add, sub, mul, div, mod, shl, sar, shr, band, bor, bxor };

pub fn opBinary(comptime kind: BinOp) Handler {
    return struct {
        fn hnd(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
            // qjs JS_VALUE_IS_BOTH_INT — one fused (tag1|tag2)==0 test.
            const ints = JSValue.asInt32Pair((sp - 2)[0], (sp - 1)[0]) orelse
                return @call(.always_tail, opBinaryFloat(kind), .{ pc, sp, var_buf, vm });
            const a = ints.lhs;
            const b = ints.rhs;
            // Each arm stores its own result into sp[-2] (qjs: every CASE writes
            // sp[-2] then BREAKs) — a shared `result` merge point would make LLVM
            // spill the 16-byte JSValue phi to a stack slot and reload it as a q
            // register (the old fused handler's ldr q0/str q0 round-trip).
            switch (kind) {
                // qjs OP_add int leg (19701-19709): `r = (int64_t)v1 + v2; if
                // ((int)r != r)` — the int64-widen + truncation check, NOT
                // @addWithOverflow (whose result tuple makes LLVM materialize
                // the overflow flag into a stack byte — a dead cset+strb and a
                // 16B frame; same finding as vm_arith.fastInt32Add). The
                // overflow (double) result comes from the cold side instead of
                // an in-line scvtf so the hot line stays integer-register only.
                .add => {
                    const r: i64 = @as(i64, a) + b;
                    const r32: i32 = @truncate(r);
                    if (r32 != r) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
                    (sp - 2)[0] = JSValue.int32(r32);
                },
                // qjs OP_sub int leg (19797-19805), same int64-widen form.
                .sub => {
                    const r: i64 = @as(i64, a) - b;
                    const r32: i32 = @truncate(r);
                    if (r32 != r) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
                    (sp - 2)[0] = JSValue.int32(r32);
                },
                // qjs OP_mul int leg (19836-19852): 64-bit product truncation
                // check, then the `r == 0 && (v1|v2) < 0` -0 test — both special
                // cases route cold (fastInt32Mul reproduces qjs's mul_fp_res).
                .mul => {
                    const r: i64 = @as(i64, a) * b;
                    const r32: i32 = @truncate(r);
                    if (r32 != r) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
                    if (r == 0 and (a | b) < 0) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
                    (sp - 2)[0] = JSValue.int32(r32);
                },
                // qjs OP_div int leg (19884-19889): always the double quotient,
                // through the canonicalizing JS_NewFloat64 (= numberToValue).
                .div => (sp - 2)[0] = value_ops.numberToValue(@as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b))),
                // qjs OP_mod int leg (19900-19910): `v1 < 0 || v2 <= 0` goes
                // slow (avoids v2==0, INT32_MIN%-1 and -0 results); the hot
                // remainder is nonnegative % positive — plain int32.
                .mod => {
                    if (a < 0 or b <= 0) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
                    (sp - 2)[0] = JSValue.int32(@rem(a, b));
                },
                // qjs OP_shl int leg (20118-20124).
                .shl => (sp - 2)[0] = JSValue.int32(a << @intCast(b & 31)),
                // qjs OP_sar int leg (20159-20164).
                .sar => (sp - 2)[0] = JSValue.int32(a >> @intCast(b & 31)),
                // qjs OP_shr int leg (20138-20145): JS_NewUint32 — result keeps
                // the int tag while it fits int32, else the exact double (bare
                // __JS_NewFloat64; >INT32_MAX is never int32-canonicalizable, so
                // this equals the old numberToValue bits without its scan). The
                // legs store separately: an if/else JSValue *value* merge would
                // reintroduce the stack-slot + q-register round-trip.
                .shr => {
                    const r = @as(u32, @bitCast(a)) >> @intCast(b & 31);
                    if (r <= std.math.maxInt(i32)) {
                        (sp - 2)[0] = JSValue.int32(@intCast(r));
                    } else {
                        (sp - 2)[0] = JSValue.float64(@floatFromInt(r));
                    }
                },
                // qjs OP_and/OP_or/OP_xor int legs (20179-20182/20197-20200/20215-20218).
                .band => (sp - 2)[0] = JSValue.int32(a & b),
                .bor => (sp - 2)[0] = JSValue.int32(a | b),
                .bxor => (sp - 2)[0] = JSValue.int32(a ^ b),
            }
            return cont(pc + 1, sp - 1, var_buf, vm);
        }
    }.hnd;
}

/// Inline float64 leg for a generic binary op whose both-int32 fast path missed
/// (opBinary tail-jumps here). Mirrors qjs OP_add's float leg (quickjs.c:19710-19728):
/// add/sub/mul extract each operand as a double (float64 OR int32; any other tag —
/// string/object/BigInt — falls to the cold slow path), then store a bare float64
/// result exactly like the both-float leg op_add_loc already inlines (tailcall_dispatch
/// :1296-1300). This keeps float-heavy generic binaries — e.g. `s += arr[i]` numeric
/// reductions, which compile to a non-fused OP_add and previously fell all the way to
/// binaryVm/value_ops.binary — on a register-resident path. div/mod are excluded (they
/// carry qjs's zero / sign / -0 special-cases and canonicalizing quotient) and the
/// bitwise ops ToInt32 their operands, so both keep routing cold.
fn opBinaryFloat(comptime kind: BinOp) Handler {
    return struct {
        fn hnd(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
            switch (kind) {
                .add, .sub, .mul => {
                    if (value_ops.numberValue((sp - 2)[0])) |d1| {
                        if (value_ops.numberValue((sp - 1)[0])) |d2| {
                            const d = switch (kind) {
                                .add => d1 + d2,
                                .sub => d1 - d2,
                                .mul => d1 * d2,
                                else => unreachable,
                            };
                            (sp - 2)[0] = JSValue.float64(d);
                            return cont(pc + 1, sp - 1, var_buf, vm);
                        }
                    }
                },
                else => {},
            }
            return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
        }
    }.hnd;
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

/// TDZ-checked local access (qjs OP_get_loc_check/OP_put_loc_check/OP_set_loc_check,
/// quickjs.c:18704/18730/18743). The lexical `let`/`const` loop counter and
/// block-scoped result in `for (let i…)` bodies are ALWAYS emitted as these checked
/// forms (quickjs.c:33072-33078 emits OP_get_loc_check for every `is_lexical` var —
/// there is no downgrade to plain OP_get_loc), so these are the per-iteration hot
/// loc ops in every counting loop; without this handler they route to the 192-byte-
/// frame `checkedLocVm` cold path (the four-benchmark self%-#1). Same shape as
/// `opLoc` plus qjs's `JS_IsUninitialized(var_buf[idx])` TDZ guard:
///   - a var-ref cell slot (captured binding) → cold: checkedLocVm unwraps the cell,
///   - an uninitialized plain slot → cold: checkedLocVm throws the TDZ ReferenceError,
///   - (put) a `const` slot → cold: checkedLocVm throws the const-reassign TypeError.
/// The checked encodings only exist in the u16 operand form (no short variants —
/// bytecode.zig:442-445), so one handler per kind covers them.
pub fn opLocCheck(comptime kind: LocKind) Handler {
    return struct {
        fn h(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
            if (vm.local_fast_blocked) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
            const idx: u16 = readInt(u16, pc + 1);
            const old_v = var_buf[idx];
            // A `var_buf` local can hold a var-ref cell only in a function whose
            // locals may be boxed (closure capture / make_loc_ref / derived-ctor
            // `this` / direct-eval). `locals_never_boxed` is precomputed at
            // finalize (bytecode.computeLocalsNeverBoxed); when set, no cell can
            // reach either the slot or the operand stack, so both per-op
            // `varRefCellFromValue` guards are dropped — qjs reads `var_buf[idx]`
            // as a plain value with no cell test at all (quickjs.c:18704). When
            // clear, the guards run exactly as before (captured binding → cold).
            const may_box = !vm.function.locals_never_boxed;
            // Cell slot OR plain-uninitialized (TDZ) slot both fall to the cold
            // checkedLocVm: `varRefCellFromValue` catches the captured-binding case
            // and `isUninitialized` the plain-TDZ case (qjs 18709 tag test).
            if (may_box and slot_ops.varRefCellFromValue(old_v) != null) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
            if (old_v.isUninitialized()) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
            switch (kind) {
                .get => {
                    sp[0] = old_v.dup();
                    return cont(pc + 3, sp + 1, var_buf, vm);
                },
                .put => {
                    if (idx < vm.function.vardefs.len and vm.function.vardefs[idx].is_const) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
                    const value = (sp - 1)[0];
                    if (may_box and slot_ops.varRefCellFromValue(value) != null) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
                    var_buf[idx] = value;
                    old_v.free(vm.ctx.runtime);
                    return cont(pc + 3, sp - 1, var_buf, vm);
                },
                .set => {
                    const value = (sp - 1)[0];
                    if (may_box and slot_ops.varRefCellFromValue(value) != null) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
                    const assigned = value.dup();
                    var_buf[idx] = assigned;
                    old_v.free(vm.ctx.runtime);
                    return cont(pc + 3, sp, var_buf, vm);
                },
            }
        }
    }.h;
}

/// Closure/global var-ref read (qjs OP_get_var_ref0..3 distinct labels). The `fib`
/// recursive self-reference is get_var_ref0 — fib's per-call hottest non-call op.
/// Uninitialized (TDZ or deleted binding parked at UNINITIALIZED, qjs
/// remove_global_object_property) routes to the cold resolver.
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
            // Bounds check stays: zjs still grows var_refs dynamically for
            // eval-introduced refs (ensureVarRefsCapacity; qjs sizes once at
            // 17277 and reads unchecked, 18627) — deletion is phase-E gated
            // on construction-fixed length.
            if (idx >= vm.frame.var_refs.len) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
            // Slot is a cell by type (`[]*core.VarRef`): the pre-typed
            // "is this slot a cell" header load (guard #4) is deleted —
            // qjs OP_get_var_ref is a bare `*var_refs[idx]->pvalue` (18627).
            const cell = slot_ops.varRefSlotCellUnchecked(vm.frame, idx);
            const v = cell.pvalue.*;
            if (v.isUninitialized()) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
            // Guard #7 (nested-cell check) retired: a cell's VALUE is never
            // itself a cell — the direct-eval const view now pvalue-ALIASES
            // its target (eval_ops.directEvalOuterVarRefView) instead of
            // nesting it, so `*var_refs[idx]->pvalue` is the plain value,
            // exactly qjs OP_get_var_ref (quickjs.c:18627-18636).
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
    // qjs OP_get_field does an inline find_own_property on each access (no cache).
    // Walk self+prototype for a plain data property; on a hit the value is BORROWED
    // from the holder slot, so dup onto the stack (which owns its entries) and free
    // the receiver. Exotic/private/non-object/prototype-fallback falls to cold field().
    if (vm_property_field.qjsGetFieldFast(vm.ctx.runtime, receiver, atom_id)) |value| {
        const stack_value = if (value.requiresRefCount()) value.dup() else value;
        (sp - 1)[0] = stack_value;
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
        const stack_value = if (value.requiresRefCount()) value.dup() else value;
        sp[0] = stack_value;
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

// Hot inline put_array_el — qjs OP_put_array_el's dense fast path: a[i] = v on a
// fast array with a non-negative int32 index writes the (dup'd) value into the
// dense slot (or appends), then pops the [obj, key, value] triple. The value is
// dup'd into the array (setFastArrayElementDup), so all three operands are freed
// here exactly as the cold path's defers do. Typed arrays (not is_array), string
// keys, out-of-range / holey, and exotic receivers fall to the cold h_array_element.
pub fn op_put_array_el(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    const key = (sp - 2)[0];
    const obj = (sp - 3)[0];
    const rt = vm.ctx.runtime;
    if (array_ops.putDenseArrayElementFast(rt, obj, key, value) catch |e| return vm.fail(e)) {
        value.free(rt);
        key.free(rt);
        obj.free(rt);
        return cont(pc + 1, sp - 3, var_buf, vm);
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
    // qjs OP_put_field inline: find_own_property on the receiver, write the slot
    // (consuming `value`) and free the old value. Shape-changing adds, exotic, and
    // non-object receivers fall to cold field().
    if (vm_property_field.qjsPutFieldFast(vm.ctx.runtime, obj, atom_id, value)) {
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
        // `stringValueLen` reads a rope's logical length off the node WITHOUT
        // flattening (qjs `JSStringRope.len`). Using `asStringBody().len()` here
        // would materialize the rope, turning an `s = s + x; s.length`
        // accumulator loop into O(n) per iteration.
        const len_val = JSValue.int32(@intCast(core.string.stringValueLen(value)));
        value.free(vm.ctx.runtime);
        (sp - 1)[0] = len_val;
        return cont(pc + 1, sp, var_buf, vm);
    }
    // Plain fast array `.length` — the `for (i=0;i<arr.length;i++)` hot read,
    // read inline instead of via the cold getLength's getValueProperty.
    // Exotic/subclassed arrays, typed arrays, and length-getter objects fall cold.
    if (vm_property_field.fastArrayLengthValue(value)) |len_val| {
        value.free(vm.ctx.runtime);
        (sp - 1)[0] = len_val;
        return cont(pc + 1, sp, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

// Frameless OP_object — qjs CASE(OP_object): `*sp++ = JS_NewObject(ctx)`
// (quickjs.c:17961), the per-iteration hottest op of `o = {}` / every object literal.
// The cold h_object shell paid the full 224-byte coldStd publish+spill tax every
// iteration for a op that runs no user code and captures no backtrace; this handler
// creates the bare `{}` register-resident and pushes it, exactly qjs's one-`bl`
// inline. Only OOM (create returns error) routes to the cold shell (which re-derives
// sp from the published stack — no state was mutated here, so the fall-through is
// clean). No pc/sp publish, no coldNext round-trip.
pub fn op_object(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const value = literal_vm.newPlainObjectValue(vm.ctx, vm.global) catch
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    sp[0] = value; // owned
    return cont(pc + 1, sp + 1, var_buf, vm);
}

// Frameless OP_define_field — qjs CASE(OP_define_field): one JS_DefinePropertyValue on
// sp[-2] with sp[-1] (quickjs.c:19269), the 3-per-iteration hot op of `o={a:i,b:i,c:i}`
// object literals. The cold h_field shell paid the 224-byte coldStd publish+spill tax
// each of those three times per iteration. `defineFieldFast` handles the plain-data-add
// case (non-refcounted value, ordinary extensible non-array non-exotic non-proxy obj —
// the same in-CASE fast leg the cold defineField itself runs first); on a hit the value
// is consumed into the slot, so pop it and free the popped obj slot at sp[-2]. Arrays,
// private atoms, proxies, non-extensible, setters, and refcounted values (every
// backtrace/user-code-capable case) fall to the cold shell (which publishes frame.pc at
// the u32 atom operand — this handler left frame.pc untouched, so the decode matches).
// 5-byte op (u32 atom).
pub fn op_define_field(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    const obj = (sp - 2)[0];
    const atom_id = readInt(u32, pc + 1);
    if (literal_vm.defineFieldFast(vm.ctx.runtime, obj, atom_id, value)) {
        // value consumed into the property slot; obj stays on the stack as the
        // literal's running receiver (qjs leaves sp[-2] in place, only sp--).
        return cont(pc + 5, sp - 1, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

// Frameless OP_array_from — qjs CASE(OP_array_from): `js_create_array_free(ctx,
// argc, sp - argc)` building the dense array in one call (quickjs.c:18239), the
// per-iteration hot op of `a = [i, i+1, i+2]` and every non-spread array literal. The
// cold h_array_from shell paid the 224-byte coldStd publish+spill tax plus a heap temp
// buffer + per-element stack.pop every iteration. `constructLiteralWithPrototype`
// DUPS the values slice into the array (initDenseArrayLiteralValuesAssumingEmpty) and
// roots it during the create (GC-safe), so this handler hands it the register-resident
// operand window `(sp-argc)[0..argc]` directly — no temp buffer, no per-element pop —
// then frees the argc popped originals (balancing the dup, exactly the cold arrayFrom's
// trailing free) and pushes the array. OOM routes to the cold shell (values untouched
// on the stack, frame.pc left at the u16 argc operand for its own decode). 3-byte op.
pub fn op_array_from(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const argc: usize = readInt(u16, pc + 1);
    const rt = vm.ctx.runtime;
    const values = (sp - argc)[0..argc];
    const array = core.array.constructLiteralWithPrototype(rt, values, array_ops.arrayPrototypeFromGlobal(rt, vm.global)) catch
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    // Free the popped originals (the array dup'd them); then the array replaces the
    // whole [v0..v_argc) window at sp-argc, so the net stack effect is -argc+1.
    for (values) |v| v.free(rt);
    const nsp = sp - argc;
    nsp[0] = array; // owned
    return cont(pc + 3, nsp + 1, var_buf, vm);
}

/// Per-op comparison handler generator (qjs OP_CMP / OP_CMP_EQ / OP_CMP_STRICT_EQ
/// each expand to an INDEPENDENT CASE label per opcode — quickjs.c:20230-20271
/// (OP_CMP → OP_lt/OP_lte/OP_gt/OP_gte), 20273-20341 (OP_CMP_EQ → OP_eq/OP_neq),
/// 20343-20398 (OP_CMP_STRICT_EQ → OP_strict_eq/OP_strict_neq) — so OP_lt's
/// both-int fast path is a single cmp+cset with no runtime predicate select).
/// The former shared op_compare handler decoded pc[0] into the predicate through
/// a cmp+cset+csel selection chain (~30 insn/compare measured vs qjs's 17). With
/// `opc` comptime the switches below fold away and each handler compiles to:
/// two tag checks + one cmp + one cset + write sp[-2] + tail-jump next —
/// qjs's exact int fast-path shape. Non-number operands fall INDIRECTLY to
/// cold_table[pc[0]] (op_compare_cold → full js_relational_slow/js_eq_slow
/// semantics), the same routing discipline the shared handler used.
pub fn opCompare(comptime opc: u8) Handler {
    return struct {
        fn h(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
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
            // a float-counter `x < n` not pay the cold hop every iteration. (Relational ops
            // only — same coverage the shared handler had; the eq family keeps its existing
            // int-int fast arm and falls cold otherwise.)
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
    }.h;
}

/// Dedicated cold handler for OP_lt/OP_le/…/OP_eq's non-(both-int32) operands — the
/// float-vs-int / float / object / loose-eq cases (qjs js_relational_slow /
/// js_eq_slow). Installed as the cold_table entry for the compare ops, so the
/// opCompare handlers reach it through the same indirect `cold_table[pc[0]]` dispatch
/// (a DIRECT tail-call here would perturb the int32 fast-path codegen — the
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
    // qjs CASE(OP_goto) polls interrupts on every unconditional jump — the
    // loop back edge (quickjs.c:18822-18826). Without this, a pure loop never
    // reaches a poll point and an installed interrupt handler can't abort it.
    if (vm.poller.active) {
        @branchHint(.unlikely);
        vm.publish(pc, sp);
        vm.poller.poll(vm.ctx.runtime) catch |e| return vm.fail(e);
    }
    return @call(.always_tail, next, .{ jump8Target(pc, vm), sp, var_buf, vm });
}
// The boolean fast path (a comparison result — the hot loop condition) inlines; a
// non-boolean condition routes to cold_table[pc[0]] (the generic branch8 handler).
// That routing is INDIRECT, which LLVM cannot inline back — so the hot handler stays
// prologue-free (a direct tail-call to a local slow shell got re-inlined, dragging in
// its 64B frame + callee-saved spills, which pressured the store buffer and stalled
// the boolean's store→load forward from opCompare). Booleans need no free / no call.
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
// — the per-call `fib` lookup in recursive code. Any dynamic-overlay / shadow /
// uninitialized (TDZ or deleted binding parked at UNINITIALIZED, qjs
// remove_global_object_property) condition falls back to the cold getVar resolver.
pub fn op_get_var(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (vm.local_fast_blocked) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    if (vm_property_globals.hasDynamicGlobalOverlay(vm.frame, evLocalNames(vm), vm.frame.evalVarRefNames(), evWithObject(vm))) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    // A closure created inside direct eval may have parent eval bindings that
    // shadow global names. qjs keeps OP_get_var as a direct var-ref cell read;
    // zjs's frame model resolves this through the cold scope walker. The
    // frame-level check avoids a hot per-name walk without caching mutable
    // eval/with state.
    if (property_vm.frameClosureHasEvalParent(vm.frame)) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    const idx = readInt(u16, pc + 1);
    // Bounds check stays (dynamic eval growth; phase-E deletion is gated on
    // construction-fixed length — qjs reads unchecked, 18461).
    if (idx >= vm.frame.var_refs.len) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    // Slot is a cell by type: guard #4 (slot header load) deleted — qjs
    // OP_get_var is `*var_refs[idx]->pvalue` + one uninitialized check
    // (18461-18488).
    const cell = slot_ops.varRefSlotCellUnchecked(vm.frame, idx);
    const v = cell.pvalue.*;
    if (v.isUninitialized()) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    // Guard #7 (nested-cell check) and global-lexical shadow checks are not
    // part of qjs's hot OP_get_var. They are folded into the cell at
    // definition/mutation time.
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
                // Read the request in place — no by-value copy of the target.
                const req = &vm.tail_request;
                if (vm.tail_is_reuse) {
                    _ = try vm.machine.tailCallReuse(vm.global, vm.stack, &req.target, req.region_base, req.argc, req.layout);
                } else {
                    _ = vm.machine.pushCall(vm.global, vm.stack, &req.target, req.region_base, req.argc, req.layout) catch |err| {
                        // op.call's `catch |err|` leg (the old dispatchLoop's
                        // push-failure path): close a pending for-of iterator,
                        // then convert a setup failure (OOM-class) into a
                        // JS-catchable error in the CALLER frame — qjs delivers
                        // the preallocated InternalError to the frame's catch.
                        // Only an uncaught error propagates out of the loop.
                        try forof_ops.closeStackTopForOfIteratorForPendingError(vm.ctx, vm.output, vm.global, vm.stack);
                        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.stack, vm.frame, vm.catch_target, vm.global, err)) {
                            reloadTop(vm, &pc, &sp, &var_buf);
                            continue;
                        }
                        return err;
                    };
                }
                // qjs polls at call entry (js_poll_interrupts, quickjs.c:17787),
                // so unbounded recursion is also abortable.
                if (vm.poller.active) try vm.poller.poll(vm.ctx.runtime);
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
