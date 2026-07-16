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
const builtin = @import("builtin");
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
const value_slot = @import("value_slot.zig");
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
    /// Property-specialized handlers live behind a resident table pointer for the
    /// same reason cold_table does: the indirect tail call keeps their shape walks
    /// out of the already-hot object/array handlers without adding a non-tail frame.
    property_tail_tbl: [*]const Handler = undefined,
    /// Borrowed holder selected by the immediately preceding property tail
    /// handler. The receiver operand keeps its prototype chain rooted until the
    /// specialized cold handler publishes the stack and enters observable code.
    property_holder: *core.Object = undefined,
    /// Static-field atom paired with `property_holder` for the immediately
    /// following Proxy action. Duplicated by that action before re-entry.
    property_atom: core.Atom = core.atom.null_atom,
    /// Frame-constant `(depth==0 and l0.stop_before_pc != null)` — the generator
    /// stop-boundary guard that blocks the local/var fast paths. Hoisted here (set
    /// once per frame in the driver/reloadTop) so each loc op checks ONE bool load
    /// instead of re-deriving machine.depth + l0.stop_before_pc per op (mirrors
    /// dispatchLoop's `local_fast_blocked_by_generator`).
    local_fast_blocked: bool = false,

    /// Pointer to the CURRENT frame's catch-target slot. `reloadTop` re-points
    /// it through `Machine.loadCurrentLevel` on every frame switch, so a catch
    /// handler set in one frame doesn't leak into another.
    catch_target: *?usize,

    /// Interrupt poll state — qjs polls on every OP_goto (quickjs.c:18822,
    /// `js_poll_interrupts`) and at JS_CallInternal entry (17787). Gated on an
    /// installed handler (`poller.active`) like the old dispatchLoop leg: with
    /// none installed the jump handlers stay poll-free.
    poller: control_vm.InterruptPoller,

    /// Outcome payloads (ride here, not in the u32 return).
    return_value: JSValue = JSValue.undefinedValue(),
    return_action: inline_calls.ReturnAction = .next,
    return_payload: u32 = 0,
    pending_error: HostError = error.OutOfMemory,
    tail_request: call_runtime.InlineCallRequest = undefined,
    /// On `.tail`: true => `tailCallReuse` (op.tail_call*/eval-tail), false => `pushCall`
    /// (op.call*/call_method). The driver branches on it.
    tail_is_reuse: bool = false,

    /// syncDown analog: publish the register-resident pc/sp back to frame.pc /
    /// stack.values so a cold helper sees live state. `pc` points at the opcode byte;
    /// cold handlers want frame.pc one past it (the operand cursor), matching the
    /// monolith's per-arm `reg_ip += 1` before the slow path.
    pub inline fn publish(self: *Vm, pc: [*]const u8, sp: [*]JSValue) void {
        self.frame.pc = (@intFromPtr(pc) - @intFromPtr(self.code_base)) + 1;
        self.stack.values = self.stack_base[0 .. (@intFromPtr(sp) - @intFromPtr(self.stack_base)) / @sizeOf(JSValue)];
    }

    /// Publish only the register-resident operand length. Normal inline
    /// returns immediately destroy the callee frame, and QJS's OP_return goes
    /// straight to `done` without updating `sf->cur_pc`; teardown still needs
    /// the precise live stack boundary.
    pub inline fn syncSp(self: *Vm, sp: [*]JSValue) void {
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

const PropertyTailSlot = enum(usize) {
    get_field_primitive,
    get_field2_primitive,
    get_array_el_cached_string,
    get_array_el_cached_getter,
    get_array_el_cached_proxy,
    get_field_cached_getter,
    get_field_property,
    get_static_cached_proxy,
    get_length_property,
    get_field_typed_property,
};

inline fn propertyTailHandler(vm: *const Vm, comptime slot: PropertyTailSlot) Handler {
    return vm.property_tail_tbl[@intFromEnum(slot)];
}

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
        const stop_before_pc = vm.machine.l0.stop_before_pc orelse return false;
        const r = gen_async_vm.stopBeforePc(vm.ctx, vm.stack, vm.frame, vm.machine.l0.generator_state, vm.catch_target.*, stop_before_pc) catch |e| {
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
pub inline fn isEvalCode(vm: *Vm) bool {
    return if (vm.machine.depth == 0) vm.machine.l0.is_eval_code else false;
}
pub inline fn evalGlobalVarBindings(vm: *Vm) bool {
    return if (vm.machine.depth == 0) vm.machine.l0.eval_global_var_bindings else false;
}
pub inline fn strictUnresolvedGetVar(vm: *Vm) bool {
    return if (vm.machine.depth == 0) vm.machine.l0.strict_unresolved_get_var else (vm.function.flags.is_strict or vm.function.flags.runtime_strict);
}

inline fn evIsEval(vm: *Vm) bool {
    return isEvalCode(vm);
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

/// `IteratorNext` itself is outside the IteratorClose-on-abrupt region (qjs
/// `JS_IteratorNext2` propagates a failing `next()` directly). A same-Machine
/// setup failure for that method therefore tries the caller catch without
/// closing the iterator record first.
noinline fn iteratorNextCallSetupRecover(vm: *Vm, err: HostError) bool {
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
    vm.function = entry.frame.function;
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

/// Same-Machine entry for a call region already moved out of the caller's
/// operand layout. Proxy `get` uses this because its semantic arguments are
/// `[target, key, receiver]`, while the caller must retain `[target, key]` for
/// the post-trap invariant continuation.
inline fn pushMovedAndEnter(
    vb: [*]JSValue,
    vm: *Vm,
    target: *const inline_calls.InlineTarget,
    moved_values: []JSValue,
    return_action: inline_calls.ReturnAction,
    continuation_payload: u32,
) Outcome {
    const entry = vm.machine.pushMovedCall(vm.global, target, moved_values, .method, return_action, continuation_payload) catch |err| {
        const recovered = if (return_action == .for_of_next)
            iteratorNextCallSetupRecover(vm, err)
        else
            callSetupRecover(vm, err);
        if (!recovered) return .threw;
        return coldNext(vb, vm);
    };
    if (vm.poller.active) {
        vm.poller.poll(vm.ctx.runtime) catch |err| return vm.fail(err);
    }
    vm.function = entry.frame.function;
    vm.frame = &entry.frame;
    vm.stack = &entry.stack;
    vm.catch_target = &entry.catch_target;
    vm.code_base = vm.function.code.ptr;
    vm.code_end = vm.function.code.ptr + vm.function.code.len;
    vm.stack_base = vm.stack.values.ptr;
    vm.arg_buf = vm.frame.args.ptr;
    vm.local_fast_blocked = false;
    const pc2: [*]const u8 = vm.code_base;
    const sp2: [*]JSValue = vm.stack.values.ptr + vm.stack.values.len;
    const vb2: [*]JSValue = vm.frame.locals.ptr;
    return @call(.always_tail, next, .{ pc2, sp2, vb2, vm });
}

/// qjs internal IteratorNext borrows `enum_obj` and `method` from the caller's
/// persistent iterator record. Keep the caller stack untouched and enter the
/// child frame with borrowed call bindings; its continuation returns here
/// before those two slots can be released or reused.
inline fn pushBorrowedIteratorAndEnter(
    vb: [*]JSValue,
    vm: *Vm,
    target: *const inline_calls.InlineTarget,
    iterator_record: []JSValue,
    depth: u8,
) Outcome {
    const maybe_entry = vm.machine.pushBorrowedIteratorNext(vm.global, target, iterator_record, depth) catch |err| {
        if (!iteratorNextCallSetupRecover(vm, err)) return .threw;
        return coldNext(vb, vm);
    };
    const entry = maybe_entry orelse {
        var moved = [2]JSValue{ iterator_record[0].dup(), iterator_record[1].dup() };
        defer for (moved) |value| value.free(vm.ctx.runtime);
        return pushMovedAndEnter(vb, vm, target, &moved, .for_of_next, depth);
    };
    if (vm.poller.active) {
        vm.poller.poll(vm.ctx.runtime) catch |err| return vm.fail(err);
    }
    vm.function = entry.frame.function;
    vm.frame = &entry.frame;
    vm.stack = &entry.stack;
    vm.catch_target = &entry.catch_target;
    vm.code_base = vm.function.code.ptr;
    vm.code_end = vm.function.code.ptr + vm.function.code.len;
    vm.stack_base = vm.stack.values.ptr;
    vm.arg_buf = vm.frame.args.ptr;
    vm.local_fast_blocked = false;
    const pc2: [*]const u8 = vm.code_base;
    const sp2: [*]JSValue = vm.stack.values.ptr + vm.stack.values.len;
    const vb2: [*]JSValue = vm.frame.locals.ptr;
    return @call(.always_tail, next, .{ pc2, sp2, vb2, vm });
}

inline fn isForwardingCallRecord(ctx: *core.JSContext, method: JSValue) bool {
    const function_object = class_vm.callableObjectFromValue(method) orelse return false;
    if (function_object.flags.class_payload_kind != core.class.PayloadKind.function) return false;
    const record = function_object.nativeRecord() orelse blk: {
        const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse return false;
        const resolved = ctx.runtime.internalBuiltinRecord(@intCast(@intFromEnum(native_ref.domain)), native_ref.id) orelse return false;
        function_object.nativeRecordSlot().* = resolved;
        break :blk resolved;
    };
    return record.forwards_call;
}

/// Function.prototype.call forwards an eligible bytecode target into the same
/// Machine. The operand region starts as
/// `[target, call, thisArg?, targetArgs...]`; rewrite it in place to the normal
/// plain/method call layout and transfer the skipped native `call` function to
/// the callee Entry for observable backtraces.
inline fn pushForwardedAndEnter(
    vb: [*]JSValue,
    vm: *Vm,
    target: *const inline_calls.InlineTarget,
    region_base: usize,
    outer_argc: u16,
) Outcome {
    // Arrow functions ignore Function.prototype.call's thisArg. Their resolved
    // InlineTarget carries the lexical this instead, so it cannot describe the
    // operand-region layout below. Keep arrows on the authoritative generic
    // call path rather than guessing a layout from target.this_value.
    std.debug.assert(!target.fb.flags.is_arrow_function);
    const stack = vm.stack;
    const target_argc: u16 = if (outer_argc == 0) 0 else outer_argc - 1;
    const native_caller = stack.values[region_base + 1];
    const target_function = stack.values[region_base];
    const plain_layout = target.this_value.isUndefined();
    const layout: inline_calls.RegionLayout = if (plain_layout) .plain else .method;

    if (plain_layout) {
        if (target_argc != 0) {
            std.mem.copyForwards(
                JSValue,
                stack.values[region_base + 1 ..][0..target_argc],
                stack.values[region_base + 3 ..][0..target_argc],
            );
        }
        const removed: usize = if (outer_argc == 0) 1 else 2;
        const new_len = stack.values.len - removed;
        @memset(stack.values[new_len..], JSValue.undefinedValue());
        stack.values = stack.values.ptr[0..new_len];
    } else {
        const this_arg = stack.values[region_base + 2];
        stack.values[region_base] = this_arg;
        stack.values[region_base + 1] = target_function;
        if (target_argc != 0) {
            std.mem.copyForwards(
                JSValue,
                stack.values[region_base + 2 ..][0..target_argc],
                stack.values[region_base + 3 ..][0..target_argc],
            );
        }
        const new_len = stack.values.len - 1;
        stack.values[new_len] = JSValue.undefinedValue();
        stack.values = stack.values.ptr[0..new_len];
    }

    const entry = vm.machine.pushForwardedCall(vm.global, stack, target, region_base, target_argc, layout, native_caller) catch |err| {
        native_caller.free(vm.ctx.runtime);
        if (!callSetupRecover(vm, err)) return .threw;
        return coldNext(vb, vm);
    };
    if (vm.poller.active) {
        vm.poller.poll(vm.ctx.runtime) catch |err| return vm.fail(err);
    }
    vm.function = entry.frame.function;
    vm.frame = &entry.frame;
    vm.stack = &entry.stack;
    vm.catch_target = &entry.catch_target;
    vm.code_base = vm.function.code.ptr;
    vm.code_end = vm.function.code.ptr + vm.function.code.len;
    vm.stack_base = vm.stack.values.ptr;
    vm.arg_buf = vm.frame.args.ptr;
    vm.local_fast_blocked = false;
    const pc2: [*]const u8 = vm.code_base;
    const sp2: [*]JSValue = vm.stack.values.ptr + vm.stack.values.len;
    const vb2: [*]JSValue = vm.frame.locals.ptr;
    return @call(.always_tail, next, .{ pc2, sp2, vb2, vm });
}

/// Complete the qjs `js_proxy_get` work that must happen *after* a bytecode
/// trap returns. The caller stack ends in `[target, key]`; temporarily rooting
/// `result` with an explicit runtime root makes all three values survive a
/// nested exotic descriptor probe without assuming spare operand capacity. On
/// success the pair contracts to the property result; on error it is removed
/// before the caller's catch machinery runs.
fn completeProxyGetContinuation(vm: *Vm, result: JSValue, atom_id: core.Atom) HostError!void {
    defer vm.ctx.runtime.atoms.free(atom_id);
    const rt = vm.ctx.runtime;
    var rooted_result = result;
    var root_values = [_]core.runtime.ValueRootValue{
        .{ .value = &rooted_result },
    };
    const root_frame = core.runtime.ValueRootFrame{
        .previous = rt.active_value_roots,
        .values = &root_values,
    };
    rt.active_value_roots = &root_frame;
    defer rt.active_value_roots = root_frame.previous;

    const stack = vm.stack;
    std.debug.assert(stack.values.len >= 2);
    const region_base = stack.values.len - 2;
    const target_value = stack.values[region_base];
    const key = stack.values[region_base + 1];

    const target = class_vm.objectFromValue(target_value) orelse unreachable;
    class_vm.validateProxyGetResult(
        vm.ctx,
        vm.output,
        vm.global,
        target,
        atom_id,
        rooted_result,
        vm.function,
        vm.frame,
    ) catch |err| {
        stack.values = stack.values.ptr[0..region_base];
        const failed_result = rooted_result;
        rooted_result = JSValue.undefinedValue();
        failed_result.free(rt);
        key.free(rt);
        target_value.free(rt);
        const caught = call_runtime.handleCatchableRuntimeError(vm.ctx, stack, vm.frame, vm.catch_target, vm.global, err) catch |e2| return e2;
        if (!caught) return err;
        return;
    };

    target_value.free(rt);
    key.free(rt);
    const values = stack.values.ptr;
    values[region_base] = rooted_result;
    values[region_base + 1] = JSValue.undefinedValue();
    stack.values = values[0 .. region_base + 1];
}

/// Cold post-return dispatcher. Keeping both continuation bodies out of
/// `popAndResume` preserves the ordinary return's original one-compare shape;
/// only calls that actually carry post-call work publish these fields.
fn op_post_call_continuation(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    _ = pc;
    _ = sp;
    const result = vm.return_value;
    const action = vm.return_action;
    const payload = vm.return_payload;
    vm.return_value = JSValue.undefinedValue();
    vm.return_action = .next;
    vm.return_payload = 0;
    switch (action) {
        .proxy_get => completeProxyGetContinuation(vm, result, @intCast(payload)) catch |err| return vm.fail(err),
        .for_of_next => completeForOfNextContinuation(vm, result, @intCast(payload)) catch |err| return vm.fail(err),
        .next => unreachable,
    }
    return coldNext(var_buf, vm);
}

fn completeForOfNextContinuation(vm: *Vm, result: JSValue, depth: u8) HostError!void {
    iter_vm.finishForOfNextResult(
        vm.ctx,
        vm.output,
        vm.global,
        vm.stack,
        vm.function,
        vm.frame,
        depth,
        result,
    ) catch |err| {
        const caught = try call_runtime.handleCatchableRuntimeError(
            vm.ctx,
            vm.stack,
            vm.frame,
            vm.catch_target,
            vm.global,
            err,
        );
        if (!caught) return err;
    };
}

/// Fused popFrame + reload for an in-handler return to an inline caller —
/// qjs OP_return + the done: epilogue (quickjs.c:18266, 20698-20710):
/// teardown, unlink the frame (`rt->current_stack_frame = sf->prev_frame`,
/// quickjs.c:20709), deliver the result into the caller's operand stack,
/// resume the caller — all in the handler. Frame ownership and the
/// simple/general teardown choice stay behind Machine.popFrame.
inline fn popAndResume(vm: *Vm, value: JSValue) Outcome {
    const machine = vm.machine;
    var continuation = machine.popFrame();
    var pc2: [*]const u8 = undefined;
    var sp2: [*]JSValue = undefined;
    var vb2: [*]JSValue = undefined;
    // popFrame just installed qjs's `sf->prev_frame` in Machine.top. Its null
    // state already distinguishes L0, so do not reload and test depth as well.
    reloadAfterPop(vm, machine.top, &pc2, &sp2, &vb2);
    if (continuation.action == .next) {
        std.debug.assert(continuation.payload == 0);
        // Deliver the result on the (now-current) caller stack. AssumeCapacity
        // never reallocs, so the stack_base reloadAfterPop captured stays
        // valid; sp just advances past the pushed slot.
        vm.stack.pushOwnedAssumeCapacity(value);
        sp2 += 1;
        return @call(.always_tail, next, .{ pc2, sp2, vb2, vm });
    }
    vm.return_value = value;
    vm.return_action = continuation.action;
    vm.return_payload = continuation.payload;
    continuation.action = .next;
    continuation.payload = 0;
    return @call(.always_tail, op_post_call_continuation, .{ pc2, sp2, vb2, vm });
}

fn op_return(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    // qjs OP_return (quickjs.c:18266) is check-free and infallible: `ret_val =
    // *--sp; goto done;` — ret_val is a plain local carried in registers to the
    // done: epilogue. Derived-ctor return legality is a SEPARATE opcode there
    // (OP_check_ctor_return, quickjs.c:18273, emitted at parse time 28459) and
    // the depth-0/generator hand-off lives at the JS_CallInternal boundary —
    // neither is ever inline in OP_return's value dataflow. zjs's compiler does
    // not yet emit the qjs check-ctor sequence for every derived return, so the
    // depth-0 cold helper retains that legality check. InlineTarget rejects
    // class and derived constructors before a Machine frame is pushed, leaving
    // the hot leg to carry the value as a plain JSValue (no `!JSValue` error
    // union, no memory phi) into popAndResume.
    if (vm.machine.depth == 0)
        return @call(.always_tail, op_return_cold, .{ pc, sp, vb, vm });
    std.debug.assert(!vm.frame.function.flags.is_derived_class_constructor);
    // qjs moves the result out of the operand region before the done: cleanup
    // with the check-free `ret_val = *--sp` (quickjs.c:18266). Valid `return`
    // bytecode always has one result; valueless returns use `return_undef`.
    // Keep that compiler/verifier contract explicit in Debug instead of
    // cloning the complete teardown path for malformed bytecode in production.
    std.debug.assert(@intFromPtr(sp) > @intFromPtr(vm.stack_base));
    const result_sp = sp - 1;
    const value = result_sp[0];
    vm.syncSp(result_sp);
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
    const value = control_vm.returnTop(vm.ctx, vm.stack, vm.frame, if (depth0) vm.machine.l0.generator_state else null) catch |e| return vm.fail(e);
    if (depth0) {
        vm.return_value = value;
        return .returned; // L0 exit stays on the driver
    }
    return popAndResume(vm, value);
}
fn op_return_undef(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    // Same split as op_return — qjs OP_return_undef (quickjs.c:18270) is
    // `ret_val = JS_UNDEFINED; goto done;`, check-free and infallible.
    if (vm.machine.depth == 0)
        return @call(.always_tail, op_return_undef_cold, .{ pc, sp, vb, vm });
    std.debug.assert(!vm.frame.function.flags.is_derived_class_constructor);
    vm.syncSp(sp);
    return popAndResume(vm, JSValue.undefinedValue());
}
/// Cold sibling of op_return_undef (see op_return_cold).
fn op_return_undef_cold(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    _ = vb;
    vm.publish(pc, sp);
    const depth0 = vm.machine.depth == 0;
    const value = control_vm.returnUndefined(vm.ctx, vm.frame, if (depth0) vm.machine.l0.generator_state else null) catch |e| return vm.fail(e);
    if (depth0) {
        vm.return_value = value;
        return .returned;
    }
    return popAndResume(vm, value);
}

fn op_call(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    // Decode argc + advance the resume pc (op.call carries a 2-byte operand; the
    // call0..3 singletons carry none), matching call_vm.call's prologue.
    const argc: u16 = switch (pc[0]) {
        op.call => readInt(u16, pc + 1),
        op.call0 => 0,
        op.call1 => 1,
        op.call2 => 2,
        op.call3 => 3,
        else => unreachable,
    };
    vm.syncPc(pc, if (pc[0] == op.call) 3 else 1);
    const stack_len = (@intFromPtr(sp) - @intFromPtr(vm.stack_base)) / @sizeOf(JSValue);
    vm.stack.values = vm.stack_base[0..stack_len];
    // Inline the common bytecode-to-bytecode resolution here instead of paying
    // execCall's 10-argument call boundary every iteration: resolveInlineTarget
    // (an inline fn) reads the callable off the operand region exactly as
    // execCall's inline leg does and, on a hit, completes the call in the
    // handler (qjs CASE(OP_call)). A miss (host fn / ctor / cross-realm /
    // underflow) falls to execCall with allow_inline=false.
    const total = @as(usize, argc) + 1;
    if (stack_len >= total) {
        const region_base = stack_len - total;
        const func = (sp - total)[0];
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
// This is a high-frequency tail-dispatch target. Keep its entry on an I-cache
// boundary so unrelated source/layout changes cannot move the prologue across
// a cache line and swing the method-call loop cost.
fn op_call_method(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) align(64) callconv(.c) Outcome {
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
        if (class_vm.functionObjectFromValue(receiver) != null and isForwardingCallRecord(vm.ctx, method)) {
            const this_arg = if (argc == 0) JSValue.undefinedValue() else vm.stack.values[region_base + 2];
            if (inline_calls.resolveInlineTarget(vm.ctx, vm.global, this_arg, receiver)) |target| {
                // Arrow targets require lexical-this handling and ignore the
                // supplied thisArg. The forwarded layout cannot represent both
                // facts safely, so let callMethod use the generic call path.
                if (!target.fb.flags.is_arrow_function) {
                    vm.frame.pc += 2;
                    return pushForwardedAndEnter(vb, vm, &target, region_base, argc);
                }
            }
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

/// Generic for-of calls a bytecode iterator's zero-argument `next` method in
/// the resident Machine, just like qjs's internal JS_CallInternal path. The
/// iterator record itself remains on the suspended caller stack and roots the
/// receiver/callable borrowed by the callee; the tagged continuation consumes
/// `{ value, done }` after return. Native, cross-realm, async/generator and
/// malformed records retain the authoritative helper.
fn op_for_of_next(pc: [*]const u8, sp: [*]JSValue, vb: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    vm.publish(pc, sp);
    if (@intFromPtr(pc + 1) < @intFromPtr(vm.code_end)) {
        const depth = pc[1];
        const stack_len = vm.stack.values.len;
        if (stack_len >= @as(usize, depth) + 3) {
            const iterator_index = stack_len - @as(usize, depth) - 3;
            const receiver = vm.stack.values[iterator_index];
            const method = vm.stack.values[iterator_index + 1];
            if (!receiver.isUndefined()) {
                if (inline_calls.resolveInlineTarget(vm.ctx, vm.global, receiver, method)) |target| {
                    vm.frame.pc += 1;
                    const iterator_record = vm.stack.values[iterator_index..][0..2];
                    return pushBorrowedIteratorAndEnter(vb, vm, &target, iterator_record, depth);
                }
            }
        }
    }
    _ = iter_vm.forOfNextVm(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target) catch |err| return vm.fail(err);
    return coldNext(vb, vm);
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
        switch (try gen_async_vm.initialYield(vm.ctx, vm.stack, vm.frame, if (vm.machine.depth == 0) vm.machine.l0.generator_state else null, vm.catch_target.*, if (vm.machine.depth == 0) vm.machine.l0.stop_on_yield else false)) {
            .none, .continue_loop => return null,
            .return_value => |v| return v,
        }
    }
}.b);
const h_yield = coldGen(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!?JSValue {
        _ = pc;
        switch (try gen_async_vm.yieldValue(vm.ctx, vm.stack, vm.frame, if (vm.machine.depth == 0) vm.machine.l0.generator_state else null, vm.catch_target.*, if (vm.machine.depth == 0) vm.machine.l0.stop_on_yield else false)) {
            .none, .continue_loop => return null,
            .return_value => |v| return v,
        }
    }
}.b);
const h_yield_star = coldGen(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!?JSValue {
        _ = pc;
        switch (try gen_async_vm.yieldStar(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, if (vm.machine.depth == 0) vm.machine.l0.generator_state else null, if (vm.machine.depth == 0) vm.machine.l0.stop_on_yield else false, vm.catch_target)) {
            .none, .continue_loop => return null,
            .return_value => |v| return v,
        }
    }
}.b);
const h_await = coldGen(struct {
    fn b(vm: *Vm, pc: [*]const u8) HostError!?JSValue {
        _ = pc;
        switch (try gen_async_vm.awaitValue(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, if (vm.machine.depth == 0) vm.machine.l0.generator_state else null, if (vm.machine.depth == 0) vm.machine.l0.suspend_on_module_await else false, if (vm.machine.depth == 0) vm.machine.l0.stop_on_yield else false, vm.catch_target)) {
            .none, .continue_loop => return null,
            .return_value => |v| return v,
        }
    }
}.b);

// ===========================================================================
// Hot fast-path handlers — the op's work inlined on the register-resident
// sp/var_buf/arg_buf, advancing pc + tail-dispatching via `next` with NO
// publish/helper/coldNext. Mirrors dispatchLoop's `if (comptime thread_dispatch)`
// threaded arms (zjs_vm.zig). On a guard miss (TDZ / non-int operand / generator
// stop boundary) the handler tail-calls its COLD counterpart with the
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
                    (sp - 2)[0].setInt32AssumeInt(r32);
                },
                // qjs OP_sub int leg (19797-19805), same int64-widen form.
                .sub => {
                    const r: i64 = @as(i64, a) - b;
                    const r32: i32 = @truncate(r);
                    if (r32 != r) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
                    (sp - 2)[0].setInt32AssumeInt(r32);
                },
                // qjs OP_mul int leg (19836-19852): 64-bit product truncation
                // check, then the `r == 0 && (v1|v2) < 0` -0 test — both special
                // cases route cold (fastInt32Mul reproduces qjs's mul_fp_res).
                .mul => {
                    const r: i64 = @as(i64, a) * b;
                    const r32: i32 = @truncate(r);
                    if (r32 != r) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
                    if (r == 0 and (a | b) < 0) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
                    (sp - 2)[0].setInt32AssumeInt(r32);
                },
                // qjs OP_div int leg (19884-19889): always the double quotient,
                // through the canonicalizing JS_NewFloat64 (= numberToValue).
                .div => (sp - 2)[0] = value_ops.numberToValue(@as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b))),
                // qjs OP_mod int leg (19900-19910): `v1 < 0 || v2 <= 0` goes
                // slow (avoids v2==0, INT32_MIN%-1 and -0 results); the hot
                // remainder is nonnegative % positive — plain int32.
                .mod => {
                    if (a < 0 or b <= 0) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
                    (sp - 2)[0].setInt32AssumeInt(@rem(a, b));
                },
                // qjs OP_shl int leg (20118-20124).
                .shl => (sp - 2)[0].setInt32AssumeInt(a << @intCast(b & 31)),
                // qjs OP_sar int leg (20159-20164).
                .sar => (sp - 2)[0].setInt32AssumeInt(a >> @intCast(b & 31)),
                // qjs OP_shr int leg (20138-20145): JS_NewUint32 — result keeps
                // the int tag while it fits int32, else the exact double (bare
                // __JS_NewFloat64; >INT32_MAX is never int32-canonicalizable, so
                // this equals the old numberToValue bits without its scan). The
                // legs store separately: an if/else JSValue *value* merge would
                // reintroduce the stack-slot + q-register round-trip.
                .shr => {
                    const r = @as(u32, @bitCast(a)) >> @intCast(b & 31);
                    if (r <= std.math.maxInt(i32)) {
                        (sp - 2)[0].setInt32AssumeInt(@intCast(r));
                    } else {
                        (sp - 2)[0] = JSValue.float64(@floatFromInt(r));
                    }
                },
                // qjs OP_and/OP_or/OP_xor int legs (20179-20182/20197-20200/20215-20218).
                .band => (sp - 2)[0].setInt32AssumeInt(a & b),
                .bor => (sp - 2)[0].setInt32AssumeInt(a | b),
                .bxor => (sp - 2)[0].setInt32AssumeInt(a ^ b),
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
            if (comptime kind == .add) {
                const lhs = (sp - 2)[0];
                const rhs = (sp - 1)[0];
                // qjs OP_add has a direct `JS_IsString(op1) &&
                // JS_IsString(op2)` arm before js_add_slow. Both values are
                // already primitive strings, so no observable coercion can run
                // here; consume them in the concat helper and keep pc/sp in
                // registers on success.
                if (lhs.isString() and rhs.isString()) {
                    const result = value_ops.addStringsOwned(vm.ctx.runtime, lhs, rhs) catch |err| {
                        // addStringsOwned consumed both operands. Publish the
                        // shortened stack only on the exceptional path, then
                        // use the same catch materialization as h_binary.
                        vm.publish(pc, sp - 2);
                        const caught = call_runtime.handleCatchableRuntimeError(vm.ctx, vm.stack, vm.frame, vm.catch_target, vm.global, err) catch |e2| return vm.fail(e2);
                        if (!caught) return vm.fail(err);
                        return coldNext(var_buf, vm);
                    };
                    (sp - 2)[0] = result;
                    return cont(pc + 1, sp - 1, var_buf, vm);
                }
            }
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
            switch (kind) {
                .get => {
                    sp[0] = value_slot.loadOwned(&var_buf[idx]);
                    return cont(pc + advance, sp + 1, var_buf, vm);
                },
                .put => {
                    const value = (sp - 1)[0];
                    value_slot.replaceOwned(vm.ctx.runtime, &var_buf[idx], value);
                    return cont(pc + advance, sp - 1, var_buf, vm);
                },
                .set => {
                    const value = (sp - 1)[0];
                    value_slot.replaceBorrowed(vm.ctx.runtime, &var_buf[idx], value);
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
/// `opLoc` plus qjs's `JS_IsUninitialized(var_buf[idx])` TDZ guard. An
/// uninitialized slot routes cold so checkedLocVm can throw the TDZ
/// ReferenceError; captured bindings remain plain ValueSlots here.
/// Const writes never reach this handler: resolve_variables emits throw_error
/// directly, matching qjs resolve_scope_var.
/// The checked encodings only exist in the u16 operand form (no short variants —
/// bytecode.zig:442-445), so one handler per kind covers them.
pub fn opLocCheck(comptime kind: LocKind) Handler {
    if (comptime JSValue.has_fast_int32_slot_move) return opLocCheckWithInt32SlotMove(kind);
    return opLocCheckGeneric(kind);
}

/// Keep adapters without a cheaper same-tag move on the original handler body.
/// This is deliberately a separate instantiation rather than a comptime-false
/// branch inside the wide handler: even a dead pointer-shaped branch perturbed
/// the packed adapter's code layout and cost about 2% on the loop control.
fn opLocCheckGeneric(comptime kind: LocKind) Handler {
    return struct {
        fn h(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
            if (vm.local_fast_blocked) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
            const idx: u16 = readInt(u16, pc + 1);
            const old_v = var_buf[idx];
            if (old_v.isUninitialized()) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
            switch (kind) {
                .get => {
                    sp[0] = value_slot.loadOwned(&var_buf[idx]);
                    return cont(pc + 3, sp + 1, var_buf, vm);
                },
                .put => {
                    const value = (sp - 1)[0];
                    value_slot.replaceOwned(vm.ctx.runtime, &var_buf[idx], value);
                    return cont(pc + 3, sp - 1, var_buf, vm);
                },
                .set => {
                    const value = (sp - 1)[0];
                    value_slot.replaceBorrowed(vm.ctx.runtime, &var_buf[idx], value);
                    return cont(pc + 3, sp, var_buf, vm);
                },
            }
        }
    }.h;
}

/// 16-byte adapter specialization: checked int-to-int writes preserve the
/// destination tag and move only the payload. The generic ownership path stays
/// immediately available for every other tag pair.
fn opLocCheckWithInt32SlotMove(comptime kind: LocKind) Handler {
    return struct {
        fn h(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
            if (vm.local_fast_blocked) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
            const idx: u16 = readInt(u16, pc + 1);
            const old_v = var_buf[idx];
            if (old_v.isUninitialized()) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
            switch (kind) {
                .get => {
                    sp[0] = value_slot.loadOwned(&var_buf[idx]);
                    return cont(pc + 3, sp + 1, var_buf, vm);
                },
                .put => {
                    const source = sp - 1;
                    if (var_buf[idx].trySetInt32FromSlot(&source[0]))
                        return cont(pc + 3, sp - 1, var_buf, vm);
                    const value = source[0];
                    value_slot.replaceOwned(vm.ctx.runtime, &var_buf[idx], value);
                    return cont(pc + 3, sp - 1, var_buf, vm);
                },
                .set => {
                    const source = sp - 1;
                    if (var_buf[idx].trySetInt32FromSlot(&source[0]))
                        return cont(pc + 3, sp, var_buf, vm);
                    const value = source[0];
                    value_slot.replaceBorrowed(vm.ctx.runtime, &var_buf[idx], value);
                    return cont(pc + 3, sp, var_buf, vm);
                },
            }
        }
    }.h;
}

/// TDZ state reset for a plain lexical local (qjs CASE(OP_set_loc_uninitialized),
/// quickjs.c:18696-18702). The generator/eval stop-boundary and var-ref-cell guards
/// keep the cold checkedLocVm path for the cases that must publish/rewrite through a
/// cell; a plain slot is exactly qjs's store-then-JS_FreeValue sequence.
pub fn op_set_loc_uninitialized(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (vm.local_fast_blocked) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    const idx = readInt(u16, pc + 1);
    value_slot.replaceOwned(vm.ctx.runtime, &var_buf[idx], JSValue.uninitialized());
    return cont(pc + 3, sp, var_buf, vm);
}

/// Initializing plain lexical locals (qjs CASE(OP_put_loc_check_init),
/// quickjs.c:18755-18766). Derived constructors keep the cold path because its
/// derived-`this` double-init check and explicit this_value Adapter are observable.
pub fn op_put_loc_check_init(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (vm.local_fast_blocked) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    if (vm.function.flags.is_derived_class_constructor) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    const idx = readInt(u16, pc + 1);
    const value = (sp - 1)[0];
    value_slot.replaceOwned(vm.ctx.runtime, &var_buf[idx], value);
    return cont(pc + 3, sp - 1, var_buf, vm);
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
            // Keep Zig's boundary check for synthetic/legacy bytecode; normal
            // parser output has construction-fixed length like qjs.
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

/// qjs OP_push_atom_value: decode the atom and push its retained string/symbol
/// value directly in the register-resident dispatcher. A cached atom conversion
/// cannot run user code; only the allocation/error path needs published state.
pub fn op_push_atom_value(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (vm.local_fast_blocked) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    const atom_id = readInt(u32, pc + 1);
    const value = vm.ctx.runtime.atoms.toStringValueForPush(vm.ctx.runtime, atom_id) catch |err| {
        vm.publish(pc, sp);
        return vm.fail(err);
    };
    sp[0] = value;
    return cont(pc + 5, sp + 1, var_buf, vm);
}

/// QJS OP_special_object/THIS_FUNC is a register-resident
/// `JS_DupValue(ctx, sf->cur_func)` (quickjs.c:17966). Named function
/// expressions execute this two-op prologue on every call to initialize their
/// immutable self binding. Keep the allocating/observable special-object
/// subtypes on the cold helper; the current-function arm is only one retained
/// value push and cannot fail.
pub fn op_special_object(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (vm.local_fast_blocked or pc[1] != bytecode.opcode.special_object_subtype.current_function)
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    sp[0] = vm.frame.current_function.dup();
    return cont(pc + 2, sp + 1, var_buf, vm);
}

/// Frameless primitive constant pushes. QuickJS's `CASE(OP_null)` is the direct
/// `*sp++ = JS_NULL; BREAK;` form; undefined, booleans, and immediate integers
/// are the same register-resident primitive stores. `pushSmallIntMaybeFuse` is a
/// plain `JSValue.int32` push (vm_value.zig:58-75), so the small-int handlers do
/// not omit a runtime fusion or bytecode-patching step.
///
/// Stack-capacity contract: zjs_vm.reserveEntryFrameCapacity reserves the verified
/// `function.stack_size` before dispatch (zjs_vm.zig:469-480), matching opLoc's
/// unchecked `sp[0]` write. The GC-traced `stack.values.len` stays stale until the
/// next publish because these handlers advance only register `sp`; that window is
/// safe here because null, undefined, booleans, and int32s are non-refcounted
/// primitives, so the new slot needs no tracing. The atom-value handler above
/// retains its value before advancing `sp`. The blocked guard is first because coldNext runs maybeStop at a generator
/// parameter-init suspension boundary; cont would otherwise skip that boundary.
pub fn op_undefined_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (vm.local_fast_blocked) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    sp[0] = JSValue.undefinedValue();
    return cont(pc + 1, sp + 1, var_buf, vm);
}

pub fn op_null_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (vm.local_fast_blocked) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    sp[0] = JSValue.nullValue();
    return cont(pc + 1, sp + 1, var_buf, vm);
}

pub fn op_push_false_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (vm.local_fast_blocked) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    sp[0] = JSValue.boolean(false);
    return cont(pc + 1, sp + 1, var_buf, vm);
}

pub fn op_push_true_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (vm.local_fast_blocked) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    sp[0] = JSValue.boolean(true);
    return cont(pc + 1, sp + 1, var_buf, vm);
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
    sp[0] = v.dup();
    return cont(pc + 1, sp + 1, var_buf, vm);
}

// Hot get_field mirrors qjs GET_FIELD_INLINE: ordinary objects walk shape data
// properties in this handler, while misses and primitive receivers tail-dispatch to
// a separate ordinary-property walker so their uncommon qualification code does not
// inflate the object data path. Exotics keep the full cold resolver.
// 5-byte op (atom u32).
fn op_get_field_primitive(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const receiver = (sp - 1)[0];
    const atom_id = readInt(u32, pc + 1);
    if (vm_property_field.primitivePrototypeDataPropertyValueForFastPath(vm.ctx.runtime, vm.global, receiver, atom_id)) |value| {
        const stack_value = if (value.requiresRefCount()) value.dup() else value;
        (sp - 1)[0] = stack_value;
        receiver.free(vm.ctx.runtime);
        return cont(pc + 5, sp, var_buf, vm);
    }
    return @call(.always_tail, propertyTailHandler(vm, .get_field_property), .{ pc, sp, var_buf, vm });
}

fn op_get_field_property_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const receiver = (sp - 1)[0];
    const atom_id = readInt(u32, pc + 1);
    if (vm_property_field.atomPropertyValueForFastPath(vm.ctx.runtime, vm.global, receiver, atom_id)) |result| {
        const stack_value = switch (result) {
            .borrowed => |value| if (value.requiresRefCount()) value.dup() else value,
            .owned => |value| value,
            .getter => |getter| blk: {
                if (!getter.isUndefined()) {
                    sp[0] = getter.dup();
                    return @call(.always_tail, propertyTailHandler(vm, .get_field_cached_getter), .{ pc, sp + 1, var_buf, vm });
                }
                break :blk JSValue.undefinedValue();
            },
            .proxy => |proxy| {
                vm.property_holder = proxy;
                vm.property_atom = atom_id;
                return @call(.always_tail, propertyTailHandler(vm, .get_static_cached_proxy), .{ pc, sp, var_buf, vm });
            },
        };
        receiver.free(vm.ctx.runtime);
        (sp - 1)[0] = stack_value;
        return cont(pc + 5, sp, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

fn op_get_field_typed_property_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const receiver = (sp - 1)[0];
    const atom_id = readInt(u32, pc + 1);
    if (vm_property_field.typedArrayPropertyValueForFastPath(vm.ctx.runtime, vm.property_holder, atom_id)) |result| {
        const stack_value = switch (result) {
            .borrowed => |value| if (value.requiresRefCount()) value.dup() else value,
            .owned => |value| value,
            .getter => |getter| blk: {
                if (!getter.isUndefined()) {
                    sp[0] = getter.dup();
                    return @call(.always_tail, propertyTailHandler(vm, .get_field_cached_getter), .{ pc, sp + 1, var_buf, vm });
                }
                break :blk JSValue.undefinedValue();
            },
            .proxy => |proxy| {
                vm.property_holder = proxy;
                vm.property_atom = atom_id;
                return @call(.always_tail, propertyTailHandler(vm, .get_static_cached_proxy), .{ pc, sp, var_buf, vm });
            },
        };
        receiver.free(vm.ctx.runtime);
        (sp - 1)[0] = stack_value;
        return cont(pc + 5, sp, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

pub fn op_get_field(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const receiver = (sp - 1)[0];
    const atom_id = readInt(u32, pc + 1);
    if (!receiver.isObject()) return @call(.always_tail, propertyTailHandler(vm, .get_field_primitive), .{ pc, sp, var_buf, vm });
    // qjs OP_get_field does an inline find_own_property on each access (no cache).
    // Walk self+prototype for a plain data property; on a hit the value is BORROWED
    // from the holder slot, so dup onto the stack (which owns its entries) and free
    // the receiver. Accessor/missing/private/exotic misses stay out of this handler.
    if (vm_property_field.qjsGetFieldFast(vm.ctx.runtime, receiver, atom_id)) |value| {
        const stack_value = if (value.requiresRefCount()) value.dup() else value;
        (sp - 1)[0] = stack_value;
        receiver.free(vm.ctx.runtime);
        return cont(pc + 5, sp, var_buf, vm);
    }
    if (vm_property_field.isTypedArrayPayloadAtomForFastPath(atom_id)) {
        if (vm_property_field.typedArrayReceiverForFastPath(receiver)) |object| {
            vm.property_holder = object;
            return @call(.always_tail, propertyTailHandler(vm, .get_field_typed_property), .{ pc, sp, var_buf, vm });
        }
    }
    return @call(.always_tail, propertyTailHandler(vm, .get_field_property), .{ pc, sp, var_buf, vm });
}

// Primitive get_field2 keeps the raw receiver on the stack and pushes the resolved
// realm-prototype data property above it. String auto-init methods retain their
// materializing resolver. Accessors/exotics and other misses tail to the full cold
// handler, preserving observable receiver and ownership semantics there.
fn op_get_field2_primitive(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const receiver = (sp - 1)[0];
    const atom_id = readInt(u32, pc + 1);
    if (vm_property_field.primitivePrototypeDataPropertyValueForFastPath(vm.ctx.runtime, vm.global, receiver, atom_id)) |value| {
        const stack_value = if (value.requiresRefCount()) value.dup() else value;
        sp[0] = stack_value;
        return cont(pc + 5, sp + 1, var_buf, vm);
    }
    // Auto-init String.prototype entries need the allocating/materializing
    // resolver; keep that existing cold call off the object get_field2 body.
    if (receiver.isString()) {
        const resolved = string_ops.getFastStringPrimitiveDataProperty(vm.ctx, vm.global, receiver, atom_id) catch |e| return vm.fail(e);
        if (resolved) |value| {
            sp[0] = value;
            return cont(pc + 5, sp + 1, var_buf, vm);
        }
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

pub fn op_get_field2(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const receiver = (sp - 1)[0];
    const atom_id = readInt(u32, pc + 1);
    if (!receiver.isObject()) return @call(.always_tail, propertyTailHandler(vm, .get_field2_primitive), .{ pc, sp, var_buf, vm });
    // Object receiver: own-or-prototype data/method via the same self+prototype
    // walk the cold get_field2 runs first (e.g. arr.push, map.get). The value is
    // BORROWED from its holder slot, so dup it onto the stack exactly as the cold
    // path's `pushAssumeCapacity` does; the receiver stays beneath as `this`.
    if (vm_property_field.qjsGetFieldFast(vm.ctx.runtime, receiver, atom_id)) |value| {
        const stack_value = if (value.requiresRefCount()) value.dup() else value;
        sp[0] = stack_value;
        return cont(pc + 5, sp + 1, var_buf, vm);
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

fn op_get_array_el_cached_string(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const key = (sp - 1)[0];
    const obj = (sp - 2)[0];
    if (vm_property_field.cachedStringPropertyValueForFastPath(vm.ctx.runtime, vm.global, obj, key)) |result| {
        const stack_value = switch (result) {
            .borrowed => |value| if (value.requiresRefCount()) value.dup() else value,
            .owned => |value| value,
            .getter => |getter| blk: {
                if (!getter.isUndefined()) {
                    const owned_getter = getter.dup();
                    key.free(vm.ctx.runtime);
                    (sp - 1)[0] = owned_getter;
                    return @call(.always_tail, propertyTailHandler(vm, .get_array_el_cached_getter), .{ pc, sp, var_buf, vm });
                }
                break :blk JSValue.undefinedValue();
            },
            .proxy => |proxy| {
                vm.property_holder = proxy;
                return @call(.always_tail, propertyTailHandler(vm, .get_array_el_cached_proxy), .{ pc, sp, var_buf, vm });
            },
        };
        obj.free(vm.ctx.runtime);
        key.free(vm.ctx.runtime);
        (sp - 2)[0] = stack_value;
        return cont(pc + 1, sp - 1, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

inline fn op_get_property_cached_getter(comptime pc_advance: usize, pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) Outcome {
    vm.syncPc(pc, pc_advance);
    const operand_len = (@intFromPtr(sp) - @intFromPtr(vm.stack_base)) / @sizeOf(JSValue);
    vm.stack.values = vm.stack_base[0..operand_len];
    const getter = vm.stack.values[operand_len - 1];
    const receiver = vm.stack.values[operand_len - 2];
    // qjs invokes an accessor through the same JS_CallInternal path as an
    // ordinary method call. Keep an eligible bytecode getter in this Machine
    // as well: the caller arranged the live operand region as
    // `[receiver, getter]`, exactly the zero-argument `.method` layout expected
    // by pushAndEnter. frame.pc already names the opcode after this property
    // read, so normal return/throw resumes at the correct instruction.
    if (inline_calls.resolveInlineTarget(vm.ctx, vm.global, receiver, getter)) |target| {
        return pushAndEnter(var_buf, vm, &target, operand_len - 2, 0, .method);
    }
    const value = call_runtime.callValueOrBytecodeClassModePreRooted(
        vm.ctx,
        vm.output,
        vm.global,
        receiver,
        getter,
        &.{},
        vm.function,
        vm.frame,
        false,
    ) catch |err| {
        vm.stack.values = vm.stack.values.ptr[0 .. operand_len - 2];
        getter.free(vm.ctx.runtime);
        receiver.free(vm.ctx.runtime);
        const caught = call_runtime.handleCatchableRuntimeError(vm.ctx, vm.stack, vm.frame, vm.catch_target, vm.global, err) catch |e2| return vm.fail(e2);
        if (!caught) return vm.fail(err);
        return coldNext(var_buf, vm);
    };
    getter.free(vm.ctx.runtime);
    receiver.free(vm.ctx.runtime);
    vm.stack.values[operand_len - 2] = value;
    vm.stack.values = vm.stack.values.ptr[0 .. operand_len - 1];
    return coldNext(var_buf, vm);
}

fn op_get_array_el_cached_getter(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return op_get_property_cached_getter(1, pc, sp, var_buf, vm);
}

fn op_get_field_cached_getter(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return op_get_property_cached_getter(5, pc, sp, var_buf, vm);
}

fn op_get_static_cached_proxy(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const pc_advance: usize = if (pc[0] == op.get_length) 1 else 5;
    vm.syncPc(pc, pc_advance);
    const operand_len = (@intFromPtr(sp) - @intFromPtr(vm.stack_base)) / @sizeOf(JSValue);
    vm.stack.values = vm.stack_base[0..operand_len];
    const receiver = vm.stack.values[operand_len - 1];
    if (tryInlineProxyTrap(false, var_buf, vm, vm.property_holder, vm.property_atom)) |outcome| return outcome;
    const retained_atom = vm.ctx.runtime.atoms.dup(vm.property_atom);
    defer vm.ctx.runtime.atoms.free(retained_atom);
    const value = class_vm.getProxyProperty(
        vm.ctx,
        vm.output,
        vm.global,
        receiver,
        vm.property_holder,
        retained_atom,
        vm.function,
        vm.frame,
    ) catch |err| {
        vm.stack.values = vm.stack.values.ptr[0 .. operand_len - 1];
        receiver.free(vm.ctx.runtime);
        const caught = call_runtime.handleCatchableRuntimeError(vm.ctx, vm.stack, vm.frame, vm.catch_target, vm.global, err) catch |e2| return vm.fail(e2);
        if (!caught) return vm.fail(err);
        return coldNext(var_buf, vm);
    };
    receiver.free(vm.ctx.runtime);
    vm.stack.values[operand_len - 1] = value;
    return coldNext(var_buf, vm);
}

/// Enter an ordinary bytecode Proxy `get` trap without recursively invoking a
/// second VM. This deliberately accepts only a plain data `handler.get` hit;
/// accessor/Proxy/exotic trap lookup remains on getProxyProperty so its
/// observable lookup is not repeated. The caller's static `[receiver]` or
/// computed `[receiver,key]` region becomes `[target,key]`: the original
/// receiver moves into argv, while target/key and a strong atom reference stay
/// rooted for the post-call invariant continuation.
inline fn tryInlineProxyTrap(comptime computed_key: bool, var_buf: [*]JSValue, vm: *Vm, proxy: *core.Object, atom_id: core.Atom) ?Outcome {
    const target_value = proxy.proxyTarget() orelse return null;
    const handler_value = proxy.proxyHandler() orelse return null;
    const trap = property_ic.ordinaryDataPropertyValueOrUndefinedForFastPath(vm.ctx.runtime, handler_value, core.atom.ids.get) orelse return null;
    const stack = vm.stack;
    const operand_len = stack.values.len;
    const operand_count: usize = if (computed_key) 2 else 1;
    std.debug.assert(operand_len >= operand_count);
    const region_base = operand_len - operand_count;
    const receiver = stack.values[region_base];
    const computed_key_value: JSValue = if (computed_key) stack.values[region_base + 1] else undefined;
    if (trap.isUndefined() or trap.isNull()) {
        if (property_ic.ordinaryDataPropertyValueOrUndefinedForFastPath(vm.ctx.runtime, target_value, atom_id)) |borrowed| {
            const result = if (borrowed.requiresRefCount()) borrowed.dup() else borrowed;
            receiver.free(vm.ctx.runtime);
            if (computed_key) computed_key_value.free(vm.ctx.runtime);
            stack.values[region_base] = result;
            stack.values = stack.values.ptr[0 .. region_base + 1];
            return coldNext(var_buf, vm);
        }
        return null;
    }
    const target = inline_calls.resolveInlineTarget(vm.ctx, vm.global, handler_value, trap) orelse return null;

    const key = if (computed_key)
        computed_key_value
    else
        class_vm.proxyTrapKeyValue(vm.ctx.runtime, atom_id) catch |err| {
            stack.values = stack.values.ptr[0..region_base];
            receiver.free(vm.ctx.runtime);
            const caught = call_runtime.handleCatchableRuntimeError(vm.ctx, stack, vm.frame, vm.catch_target, vm.global, err) catch |e2| return vm.fail(e2);
            if (!caught) return vm.fail(err);
            return coldNext(var_buf, vm);
        };
    var moved = [_]JSValue{
        handler_value.dup(),
        trap.dup(),
        target_value.dup(),
        key.dup(),
        receiver,
    };
    defer for (moved) |value| value.free(vm.ctx.runtime);

    stack.values[region_base] = target_value.dup();
    if (!computed_key) stack.pushOwnedAssumeCapacity(key);
    return pushMovedAndEnter(var_buf, vm, &target, &moved, .proxy_get, atom_id);
}

fn op_get_array_el_cached_proxy(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    vm.publish(pc, sp);
    const operand_len = vm.stack.values.len;
    const key = vm.stack.values[operand_len - 1];
    const receiver = vm.stack.values[operand_len - 2];
    const atom_id = vm_property_field.cachedStringAtomForFastPath(key) orelse unreachable;
    if (tryInlineProxyTrap(true, var_buf, vm, vm.property_holder, atom_id)) |outcome| return outcome;
    const retained_atom = vm.ctx.runtime.atoms.dup(atom_id);
    defer vm.ctx.runtime.atoms.free(retained_atom);
    const value = class_vm.getProxyProperty(
        vm.ctx,
        vm.output,
        vm.global,
        receiver,
        vm.property_holder,
        retained_atom,
        vm.function,
        vm.frame,
    ) catch |err| {
        vm.stack.values = vm.stack.values.ptr[0 .. operand_len - 2];
        key.free(vm.ctx.runtime);
        receiver.free(vm.ctx.runtime);
        const caught = call_runtime.handleCatchableRuntimeError(vm.ctx, vm.stack, vm.frame, vm.catch_target, vm.global, err) catch |e2| return vm.fail(e2);
        if (!caught) return vm.fail(err);
        return coldNext(var_buf, vm);
    };
    key.free(vm.ctx.runtime);
    receiver.free(vm.ctx.runtime);
    vm.stack.values[operand_len - 2] = value;
    vm.stack.values = vm.stack.values.ptr[0 .. operand_len - 1];
    return coldNext(var_buf, vm);
}

// Hot inline get_array_el — qjs OP_get_array_el's dense fast path: a[i] on a fast
// array with a non-negative int32 index reads the element directly (dup'd) and pops
// the [obj, key] pair to [value]. Holey/out-of-range/string-key/typed-array/proxy/
// negative falls to the cold arrayElement. Atom-backed string keys tail-dispatch to
// a separate ordinary-data shape walker before that cold resolver, mirroring qjs's
// string-as-atom JS_GetProperty leg without inflating the dense-array handler.
// 1-byte op (operands are on the stack).
pub fn op_get_array_el(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const key = (sp - 1)[0];
    const obj = (sp - 2)[0];
    if (vm_property_field.fastDenseArrayElementValue(obj, key)) |value| {
        obj.free(vm.ctx.runtime);
        key.free(vm.ctx.runtime);
        (sp - 2)[0] = value; // owned (fastArrayElementDup dups)
        return cont(pc + 1, sp - 1, var_buf, vm);
    }
    if (key.isString()) return @call(.always_tail, propertyTailHandler(vm, .get_array_el_cached_string), .{ pc, sp, var_buf, vm });
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

// Hot inline get_length — qjs reads a primitive string's `.length` inline
// (`OP_get_field` length fast leg: `JS_VALUE_GET_STRING(sp[-1])->len`) instead of
// routing through the general property machinery. A string operand (flat or rope —
// `len()` reads the rope's logical length without flattening) pushes its character
// count directly, replacing the popped string. Arrays keep their synthetic length
// arm; every other object gets the same ordinary shape walk as qjs
// `GET_FIELD_INLINE(..., JS_ATOM_length)`. Data stays in this hot handler;
// accessors, Proxies, and typed-array payloads tail to resident action handlers,
// while unsupported class exotics retain getLength's full resolver.
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
    // Exotic/subclassed arrays and all non-Array objects continue to the qjs
    // shape/action walk below.
    if (vm_property_field.fastArrayLengthValue(value)) |len_val| {
        value.free(vm.ctx.runtime);
        (sp - 1)[0] = len_val;
        return cont(pc + 1, sp, var_buf, vm);
    }
    // qjs OP_get_length is the ordinary GET_FIELD_INLINE macro with a constant
    // `length` atom: an Arguments object (and any other ordinary object with an
    // own/inherited data property) stays in the interpreter loop and duplicates
    // the borrowed slot before releasing the receiver. zjs previously sent every
    // non-string/non-Array object through the published cold resolver.
    if (vm_property_field.qjsGetLengthFieldFast(vm.ctx.runtime, value)) |borrowed| {
        const len_val = if (borrowed.requiresRefCount()) borrowed.dup() else borrowed;
        value.free(vm.ctx.runtime);
        (sp - 1)[0] = len_val;
        return cont(pc + 1, sp, var_buf, vm);
    }
    return @call(.always_tail, propertyTailHandler(vm, .get_length_property), .{ pc, sp, var_buf, vm });
}

fn op_get_length_property_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    // A data miss can still be an ordinary accessor or meet a Proxy in the
    // prototype walk. Reuse the same resident action classifier and same-Machine
    // continuations as static get_field; only the opcode width differs.
    const action = vm_property_field.qjsGetLengthActionForFastPath(vm.ctx.runtime, value) orelse
        vm_property_field.atomPropertyValueForFastPath(vm.ctx.runtime, vm.global, value, core.atom.ids.length);
    if (action) |result| {
        const len_val = switch (result) {
            .borrowed => |borrowed| if (borrowed.requiresRefCount()) borrowed.dup() else borrowed,
            .owned => |owned| owned,
            .getter => |getter| blk: {
                if (!getter.isUndefined()) {
                    sp[0] = getter.dup();
                    return @call(.always_tail, propertyTailHandler(vm, .get_array_el_cached_getter), .{ pc, sp + 1, var_buf, vm });
                }
                break :blk JSValue.undefinedValue();
            },
            .proxy => |proxy| {
                vm.property_holder = proxy;
                vm.property_atom = core.atom.ids.length;
                return @call(.always_tail, propertyTailHandler(vm, .get_static_cached_proxy), .{ pc, sp, var_buf, vm });
            },
        };
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

/// Dedicated cold-table handler for OP_mod after its positive-int32 CASE misses.
/// QJS `js_binary_arith_slow` tests the both-number case first and calls fmod
/// before ToNumeric / BigInt classification. Keep the same ordering without
/// publishing register-resident pc/sp. Generator/eval stop boundaries and
/// non-number operands retain the generic binary VM path.
pub fn op_mod_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (!vm.local_fast_blocked) {
        if (value_ops.numberValue((sp - 2)[0])) |lhs| {
            if (value_ops.numberValue((sp - 1)[0])) |rhs| {
                (sp - 2)[0] = JSValue.float64(@rem(lhs, rhs));
                return cont(pc + 1, sp - 1, var_buf, vm);
            }
        }
    }
    vm.publish(pc, sp);
    _ = arith_vm.binaryVm(vm.ctx, vm.stack, vm.frame, vm.catch_target, pc[0], vm.output, vm.global) catch |err| return vm.fail(err);
    return coldNext(var_buf, vm);
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
            (sp - 1)[0].setInt32AssumeInt(res[0]);
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
// check, so no explicit branch-to-end test is needed here. When an interrupt
// handler is installed, the conditional fast paths route to their cold handlers;
// those consume the condition, update the pc, and then poll in the same order as
// QuickJS OP_if_{true,false}{,8}.
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
// Plain objects take qjs JS_ToBoolFree's object leg inline (quickjs.c:11205-11211,
// called by OP_if_{true,false}8 at 18881-18919); HTMLDDA objects stay cold because
// `core.value_semantics.toBoolean` makes their is_html_dda flag falsy.
pub fn op_if_false8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (vm.poller.active) {
        @branchHint(.unlikely);
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    }
    const value = (sp - 1)[0];
    if (value.asBool()) |b| {
        if (!b) return @call(.always_tail, next, .{ jump8Target(pc, vm), sp - 1, var_buf, vm });
        return cont(pc + 2, sp - 1, var_buf, vm);
    }
    if (value.isObject()) {
        // Guard before mutation so the cold handler re-executes the HTMLDDA case
        // from the original pc/sp; branch8 consumes its operand, so shrink the GC
        // root window before the inline free just as stack.pop() does there.
        if (core.value_semantics.isHTMLDDA(value)) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
        const nsp = sp - 1;
        vm.stack.values = vm.stack_base[0 .. (@intFromPtr(nsp) - @intFromPtr(vm.stack_base)) / @sizeOf(JSValue)];
        value.free(vm.ctx.runtime);
        return cont(pc + 2, nsp, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}
pub fn op_if_true8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (vm.poller.active) {
        @branchHint(.unlikely);
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    }
    const value = (sp - 1)[0];
    if (value.asBool()) |b| {
        if (b) return @call(.always_tail, next, .{ jump8Target(pc, vm), sp - 1, var_buf, vm });
        return cont(pc + 2, sp - 1, var_buf, vm);
    }
    if (value.isObject()) {
        // See op_if_false8: non-HTMLDDA objects are truthy, and the consumed
        // operand's root must be removed before its inline rc==1 destruction.
        if (core.value_semantics.isHTMLDDA(value)) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
        const nsp = sp - 1;
        vm.stack.values = vm.stack_base[0 .. (@intFromPtr(nsp) - @intFromPtr(vm.stack_base)) / @sizeOf(JSValue)];
        value.free(vm.ctx.runtime);
        return @call(.always_tail, next, .{ jump8Target(pc, vm), nsp, var_buf, vm });
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

// Fused local-update ops (1-byte local index). qjs OP_inc_loc/OP_add_loc — the
// hottest loop ops (`i++`, `s += i`), so a cold miss here dominates loop regression.
// int32-only; non-int / generator-boundary cases fall back to the cold op.
pub fn op_update_loc(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (vm.local_fast_blocked) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    const idx: u16 = pc[1];
    const old_v = var_buf[idx];
    // Frame locals are always plain ValueSlots, including captured bindings;
    // `asInt32` guards only the numeric specialization.
    const iv = old_v.asInt32() orelse return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    // qjs OP_inc_loc/OP_dec_loc: branch on the single overflow value (INT32_MAX/MIN),
    // then a plain int add — NOT the int64-widen + range-check that fastInt32Add (=
    // qjs's OP_add path) compiles to a branchless scvtf/fcsel. The scvtf computes the
    // float fallback unconditionally and sits on the loop-carried counter chain; the
    // predicted-not-taken overflow branch keeps the chain to load→add→store. Overflow
    // (rare) falls to the cold op, whose updateLocalAt redoes it with the float box.
    if (pc[0] == op.inc_loc) {
        if (iv == std.math.maxInt(i32)) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
        var_buf[idx].setInt32AssumeInt(iv + 1);
    } else {
        if (iv == std.math.minInt(i32)) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
        var_buf[idx].setInt32AssumeInt(iv - 1);
    }
    return cont(pc + 2, sp, var_buf, vm);
}

/// Dedicated cold handler for OP_inc_loc/OP_dec_loc's non-int32 operand (float /
/// BigInt / object counter — the `for (var x=0.5; …; x++)` shape). Installed as the
/// cold_table entry for inc_loc/dec_loc, so op_update_loc reaches it via the same
/// indirect `cold_table[pc[0]]` dispatch (a direct tail-call would perturb the int32
/// fast-path codegen, like op_compare_cold). `updateLocalAt` runs register-resident
/// (no publish round-trip); inc/dec is stack-neutral so sp is unchanged. At a
/// generator/eval stop boundary (`local_fast_blocked`) it uses the publishing
/// path so coldNext's maybeStop still fires.
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
    // Frame locals are always plain ValueSlots; these checks select only qjs's
    // two numeric specializations before the generic addLocalAt path.
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
            const r: i64 = @as(i64, lhs) + rhs;
            const r32: i32 = @truncate(r);
            if (r32 == r) {
                var_buf[idx].setInt32AssumeInt(r32);
            } else {
                var_buf[idx] = core.JSValue.float64(@floatFromInt(r));
            }
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
// — the per-call `fib` lookup in recursive code. Any shadow / uninitialized
// (TDZ or deleted binding parked at UNINITIALIZED, qjs
// remove_global_object_property) condition falls back to the cold getVar resolver.
pub fn op_get_var(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    if (vm.local_fast_blocked) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    const idx = readInt(u16, pc + 1);
    // Keep Zig's boundary check for synthetic/legacy bytecode; normal parser
    // output has construction-fixed length (qjs reads unchecked, 18461).
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
    .op_for_of_next = op_for_of_next,
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
const property_tail_table = [10]Handler{
    op_get_field_primitive,
    op_get_field2_primitive,
    op_get_array_el_cached_string,
    op_get_array_el_cached_getter,
    op_get_array_el_cached_proxy,
    op_get_field_cached_getter,
    op_get_field_property_tail,
    op_get_static_cached_proxy,
    op_get_length_property_tail,
    op_get_field_typed_property_tail,
};

// ===========================================================================
// Driver — the Outcome loop. Replaces dispatchLoop's switch; reuses the Machine +
// the existing per-frame reload (reloadInlineTopFrame's arithmetic, inlined).
// ===========================================================================

fn reloadTop(vm: *Vm, pc: *[*]const u8, sp: *[*]JSValue, var_buf: *[*]JSValue) void {
    vm.machine.loadCurrentLevel(&vm.frame, &vm.stack, &vm.catch_target);
    vm.function = vm.frame.function;
    vm.code_base = vm.function.code.ptr;
    vm.code_end = vm.function.code.ptr + vm.function.code.len;
    vm.stack_base = vm.stack.values.ptr;
    vm.arg_buf = vm.frame.args.ptr;
    vm.local_fast_blocked = vm.machine.depth == 0 and vm.machine.l0.stop_before_pc != null;
    // NO `frame.pc += 1`: unlike reloadInlineTopFrame (which read+consumed the resume
    // opcode), our handlers read `pc[0]` themselves, so pc must point AT the resume op.
    pc.* = vm.code_base + vm.frame.pc;
    sp.* = vm.stack.values.ptr + vm.stack.values.len;
    var_buf.* = vm.frame.locals.ptr;
}

/// Return-only reload using the caller pointer popFrame already published in
/// Machine.top. Null names L0, exactly like qjs's `prev_frame == NULL`; a
/// non-null pointer names the caller directly and needs no depth/index lookup.
inline fn reloadAfterPop(
    vm: *Vm,
    caller_entry: ?*inline_calls.Entry,
    pc: *[*]const u8,
    sp: *[*]JSValue,
    var_buf: *[*]JSValue,
) void {
    if (caller_entry) |entry| {
        vm.frame = &entry.frame;
        vm.stack = &entry.stack;
        vm.catch_target = &entry.catch_target;
        vm.local_fast_blocked = false;
    } else {
        vm.frame = vm.machine.l0.level.frame;
        vm.stack = vm.machine.l0.level.stack;
        vm.catch_target = vm.machine.l0.level.catch_target;
        vm.local_fast_blocked = vm.machine.l0.stop_before_pc != null;
    }
    vm.function = vm.frame.function;
    vm.code_base = vm.function.code.ptr;
    vm.code_end = vm.function.code.ptr + vm.function.code.len;
    vm.stack_base = vm.stack.values.ptr;
    vm.arg_buf = vm.frame.args.ptr;
    pc.* = vm.code_base + vm.frame.pc;
    sp.* = vm.stack.values.ptr + vm.stack.values.len;
    var_buf.* = vm.frame.locals.ptr;
}

/// Run the tail-call chain to completion for the current top frame.
pub fn run(vm: *Vm) HostError!JSValue {
    vm.tbl = &dispatch_table; // resident table base (avoids per-dispatch adrp+add)
    vm.property_tail_tbl = &property_tail_table;
    vm.local_fast_blocked = vm.machine.depth == 0 and vm.machine.l0.stop_before_pc != null;
    var pc = vm.code_base + vm.frame.pc;
    var sp = vm.reloadSp();
    var var_buf = vm.frame.locals.ptr;
    while (true) {
        switch (next(pc, sp, var_buf, vm)) {
            .returned => {
                if (vm.machine.depth == 0) return vm.return_value;
                var continuation = vm.machine.popReturn(vm.return_value);
                reloadTop(vm, &pc, &sp, &var_buf);
                if (continuation.action == .next) {
                    std.debug.assert(continuation.payload == 0);
                    continue;
                }
                const result = vm.return_value;
                vm.return_value = JSValue.undefinedValue();
                switch (continuation.action) {
                    .proxy_get => try completeProxyGetContinuation(vm, result, continuation.takeAtom()),
                    .for_of_next => try completeForOfNextContinuation(vm, result, continuation.takeForOfDepth()),
                    .next => unreachable,
                }
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
    _ = &op_falloff;
    _ = &run;
    _ = dispatch_table;
}
