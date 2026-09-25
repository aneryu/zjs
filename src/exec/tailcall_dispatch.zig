//! Tail-call dispatch (architecture: `docs/stack_bytecode_vm_design.md`).
//!
//! Every opcode is its own handler `fn(pc, sp, var_buf, vm) callconv(.c) Outcome`,
//! entered via `@call(.always_tail) table[pc[0]]`. pc/sp/var_buf ride in argument
//! registers; everything else sits behind `*Vm`. Because each handler is a separate
//! function, its temporaries die at its own return instead of accumulating in one
//! monolithic dispatcher frame. `zjs_vm.zig` prepares the frame and calls
//! `runDispatchLoop`.
//!
//! INVARIANT: a handler makes no non-tail call on its own frame except the single
//! outlined helper (vm_*.zig) right before its terminal tail dispatch. Hot handlers
//! inline their fast path; cold handlers are `coldStd`-wrapped: publish, helper, tail.

const std = @import("std");
const builtin = @import("builtin");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const inline_calls = @import("inline_calls.zig");
const small_inline = @import("small_inline.zig");
const call_runtime = @import("call_runtime.zig");
const function_ops = @import("function_ops.zig");
const object_ops = @import("object_ops.zig");
const exception_ops = @import("exception_ops.zig");
const HostError = @import("exception_ops.zig").HostError;

// Op-helper modules (same aliases the VM used when dispatch lived in zjs_vm.zig).
const vm_value = @import("vm_opcodes.zig");
const vm_arith = @import("vm_opcodes.zig");
const vm_control = @import("vm_opcodes.zig");
const vm_call = @import("vm_opcodes.zig");
const vm_native = @import("vm_opcodes.zig");
const builtin_dispatch = @import("builtin_dispatch.zig");
const vm_literal = @import("vm_opcodes.zig");
const iterator_ops = @import("iterator_ops.zig");
const vm_eval_module = @import("vm_opcodes.zig");
const vm_gen_async = @import("vm_opcodes.zig");
const vm_property_globals = @import("vm_property.zig");
const vm_property_field = @import("vm_property.zig");
const property_direct = @import("property_ops.zig");
const string_ops = @import("string_ops.zig");
const array_ops = @import("array_ops.zig");
const forof_ops = @import("iterator_ops.zig");
const vm_property_locals = @import("vm_property.zig");
const value_ops = @import("value_ops.zig");
const coercion_ops = @import("value_ops.zig");
const colds = @import("tailcall_dispatch_colds.zig");

const op = bytecode.opcode.op;
const JSValue = core.JSValue;

fn readInt(comptime T: type, bytes: [*]const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

// ===========================================================================
// Outcome — the single u32 (x0) a handler chain returns to the driver
// ===========================================================================

/// Driver entry mode for a `.tail` outcome; see `Vm.tail_mode`.
pub const TailMode = enum(u8) { push, reuse_chain, reuse_release };

pub const Outcome = enum(u32) {
    /// return / return_undef / return_async produced `vm.return_value`.
    returned,
    /// Uncaught error: re-raise `vm.pending_error`.
    threw,
    /// call/tail_call eligible for inline frame reuse: `vm.tail_request` is set.
    tail,
    /// generator yield / await: state already persisted; unwind to the resume driver.
    suspended,
    /// A cold callee needs the full prologue; the driver runs it and re-enters.
    reenter,
    /// A bytecode callback reached the native fence that entered it; the nested
    /// driver hands the result back to the still-running builtin.
    native_returned,
};

// ===========================================================================
// Vm — the lean bundle (everything not pc/sp/var_buf), reached via the x3 pointer
// ===========================================================================

pub const Vm = struct {
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    machine: *inline_calls.Machine,
    output: ?*std.Io.Writer,

    /// `function.byteCode().ptr` mirror: pc<->frame.pc derivation and jump
    /// arithmetic read it on every cold publish and every jump, so it is
    /// republished eagerly at each frame switch.
    code_base: [*]const u8,
    /// Current dispatch table: the guardless fast table, or the all-cold table
    /// for an L0 frame with an armed `stop_before_pc` (so `maybeStop` runs).
    active_dispatch_tbl: [*]const Handler = undefined,
    /// `frame.var_refs.ptr` mirror (qjs keeps `var_refs` in a JS_CallInternal
    /// local) so OP_get_var_ref skips the frame load. Republished wherever
    /// `vm.frame` is; hot readers assert it matches, so ReleaseSafe catches a missed seam.
    var_refs_base: [*]*core.VarRef = undefined,
    /// `FunctionBytecode.prop_sites`/`prop_site_count` mirror (property cache).
    /// An `atom_cache_u8` site must be reachable in one load; walking to it
    /// through `function` pushed the field handlers out of leaf shape.
    /// Republished (lazily, see `publishPropSites`) wherever `code_base` is.
    prop_sites: [*]bytecode.PropSiteCache = undefined,
    prop_site_count: u16 = 0,

    /// Resident `ctx.runtime`, invariant for the Vm's lifetime and set once at
    /// entry so the call/return legs need no machine->ctx->runtime chain (qjs
    /// likewise keeps `rt` in a JS_CallInternal local).
    rt: *core.JSRuntime,
    /// Resident cold continuations (`ResidentTailSlot`), entered only after a
    /// specific fast-path miss. The indirect tail keeps their helper freight
    /// out of the fast handler while keeping the normal Handler signature.
    resident_tail_tbl: [*]const Handler = undefined,
    /// Property-specialized handlers (`PropertyTailSlot`), behind a table pointer
    /// for the same reason as `cold_table`: the indirect tail keeps their shape
    /// walks out of the hot object/array handlers.
    property_tail_tbl: [*]const Handler = undefined,
    /// Borrowed holder selected by the preceding property tail handler; rooted
    /// via the receiver operand until the cold handler publishes the stack.
    property_holder: *core.Object = undefined,
    /// Static-field atom paired with `property_holder` for the following Proxy action.
    property_atom: core.Atom = core.atom.null_atom,
    /// Frame-constant `(depth==0 and l0.stop_before_pc != null)`; selects
    /// `active_dispatch_tbl` at frame entry.
    local_fast_blocked: bool = false,
    /// The current frame's catch-target slot; re-pointed on every frame switch.
    catch_target: *?usize,

    /// Outcome payloads (ride here, not in the u32 return).
    return_value: JSValue = JSValue.undefinedValue(),
    return_action: inline_calls.ReturnAction = .next,
    return_payload: u32 = 0,
    pending_error: HostError = error.OutOfMemory,
    tail_request: call_runtime.InlineCallRequest = undefined,
    /// On `.tail`: `.push` pushes normally; `.reuse_chain` (eval tail) reuses the
    /// Entry but still charges the logical budget; `.reuse_release` (strict
    /// tail_call, PTC) reuses the Entry and releases the dying frame's charge.
    tail_mode: TailMode = .push,

    /// Invalidate the property-site mirror for a newly published `function`.
    /// One store here; `propSite`'s cold leg refills it on first use, so an
    /// activation that touches no property never pays for the mirror.
    pub inline fn publishPropSites(self: *Vm, function: *const bytecode.FunctionBytecode) void {
        _ = function;
        self.prop_site_count = 0;
    }

    /// The site an `atom_cache_u8` instruction's `cache_idx` names: one bound
    /// test and one indexed address on the hot leg. The cold leg refills an
    /// unpublished mirror inline (no call, so field handlers stay leaves); an
    /// index past a published count, or a function without sites, resolves to
    /// the shared retired site.
    pub inline fn propSite(self: *Vm, idx: u8) *bytecode.PropSiteCache {
        if (idx < self.prop_site_count) return &self.prop_sites[idx];
        return self.propSiteCold(idx);
    }

    inline fn propSiteCold(self: *Vm, idx: u8) *bytecode.PropSiteCache {
        @branchHint(.cold);
        if (self.prop_site_count != 0) return vm_property_field.noPropSite();
        if (self.function.hotExtensionCanonical()) |hot| {
            if (hot.prop_sites) |sites| {
                self.prop_sites = sites;
                self.prop_site_count = hot.prop_site_count;
                if (idx < hot.prop_site_count) return &sites[idx];
                return vm_property_field.noPropSite();
            }
        }
        self.prop_sites = vm_property_field.noPropSiteBase();
        self.prop_site_count = 256;
        return vm_property_field.noPropSite();
    }

    /// Publish pc/sp to frame.pc / stack.top_ptr for a cold helper. `pc` is the
    /// opcode byte; frame.pc becomes the operand cursor (one past it).
    pub inline fn publish(self: *Vm, pc: [*]const u8, sp: [*]JSValue) void {
        self.frame.pc = (@intFromPtr(pc) - @intFromPtr(self.code_base)) + 1;
        self.stack.setTopPtr(sp);
    }

    /// Publish only sp. Inline returns destroy the callee frame without
    /// updating pc (like qjs OP_return), but teardown needs the live stack top.
    pub inline fn syncSp(self: *Vm, sp: [*]JSValue) void {
        self.stack.setTopPtr(sp);
    }

    /// Publish only frame.pc (qjs `sf->cur_pc = pc`). Handlers that may run user
    /// code must do this BEFORE the helper: backtraces are captured inside that
    /// code, and the error-path `publish` comes too late. `advance` = opcode + operands.
    pub inline fn syncPc(self: *Vm, pc: [*]const u8, advance: usize) void {
        self.frame.pc = (@intFromPtr(pc) - @intFromPtr(self.code_base)) + advance;
    }

    /// Re-derive sp after a cold helper mutated the Stack (push/pop/grow).
    pub inline fn reloadSp(self: *Vm) [*]JSValue {
        return self.stack.topPtr();
    }

    pub inline fn fail(self: *Vm, err: HostError) Outcome {
        self.pending_error = err;
        return .threw;
    }

    /// Resident initialization: the Vm lives inside its Machine, so the
    /// invariant fields (ctx, rt, global, output, the two resident tables) are
    /// written once here and re-targeted via `retarget`. Per-entry fields are
    /// published by `zjs_vm.runTC` / `publishPushedEntry` and the driver
    /// prologue; outcome payloads are always written before being read.
    pub fn initResident(self: *Vm, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) void {
        self.ctx = ctx;
        self.rt = ctx.runtime;
        self.global = global;
        self.output = output;
        self.resident_tail_tbl = &resident_tail_table;
        self.property_tail_tbl = &property_tail_table;
        self.machine = undefined;
        self.function = undefined;
        self.var_refs_base = undefined;
        self.prop_sites = vm_property_field.noPropSiteBase();
        self.prop_site_count = 0;
        self.frame = undefined;
        self.stack = undefined;
        self.code_base = undefined;
        self.catch_target = undefined;
        self.active_dispatch_tbl = undefined;
        self.property_holder = undefined;
        self.property_atom = undefined;
        self.local_fast_blocked = undefined;
        // Traced from the owning Machine (`inline_calls.traceMachine`).
        self.return_value = JSValue.undefinedValue();
        self.return_action = undefined;
        self.return_payload = undefined;
        self.pending_error = undefined;
        self.tail_request = undefined;
        self.tail_mode = undefined;
    }

    /// Re-target an idle resident Vm to another context of the same runtime.
    pub inline fn retarget(self: *Vm, ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object) void {
        std.debug.assert(self.rt == ctx.runtime);
        self.ctx = ctx;
        self.global = global;
        self.output = output;
    }

    /// Move the completed loop's `return_value` into the native caller's slot
    /// as 64-bit words. The AArch64 asm stops LLVM from merging the copy into a
    /// `q` access, which would not store-forward against the 64-bit stores the
    /// return arms made.
    pub inline fn takeNativeReturnInto(self: *const Vm, out: *JSValue) void {
        if (comptime builtin.cpu.arch == .aarch64) {
            asm volatile (
                \\ldr x9, [%[src]]
                \\str x9, [%[dst]]
                :
                : [src] "r" (&self.return_value),
                  [dst] "r" (out),
                : .{ .x9 = true, .memory = true });
            return;
        }
        storeValueAsIntPair(out, loadValueAsIntPair(&self.return_value));
    }

    /// Per-level fields a nested native-boundary entry overwrites while the
    /// outer handler is suspended holding only pc/sp/var_buf;
    /// `inline_calls.NativeBoundaryScope` snapshots and restores them.
    pub const EntryState = struct {
        function: *const bytecode.FunctionBytecode,
        prop_sites: [*]bytecode.PropSiteCache,
        prop_site_count: u16,
        frame: *frame_mod.Frame,
        stack: *stack_mod.Stack,
        code_base: [*]const u8,
        catch_target: *?usize,
        var_refs_base: [*]*core.VarRef,
        active_dispatch_tbl: [*]const Handler,
        local_fast_blocked: bool,
    };

    pub inline fn saveEntryState(self: *const Vm) EntryState {
        return .{
            .function = self.function,
            .prop_sites = self.prop_sites,
            .prop_site_count = self.prop_site_count,
            .frame = self.frame,
            .stack = self.stack,
            .code_base = self.code_base,
            .catch_target = self.catch_target,
            .var_refs_base = self.var_refs_base,
            .active_dispatch_tbl = self.active_dispatch_tbl,
            .local_fast_blocked = self.local_fast_blocked,
        };
    }

    pub inline fn restoreEntryState(self: *Vm, state: *const EntryState) void {
        self.function = state.function;
        self.prop_sites = state.prop_sites;
        self.prop_site_count = state.prop_site_count;
        self.frame = state.frame;
        self.stack = state.stack;
        self.code_base = state.code_base;
        self.catch_target = state.catch_target;
        self.var_refs_base = state.var_refs_base;
        self.active_dispatch_tbl = state.active_dispatch_tbl;
        self.local_fast_blocked = state.local_fast_blocked;
    }

    /// Publish a just-pushed Entry as the current level straight from the
    /// pusher's registers (what `enterEntry` does for an in-handler call), so a
    /// native-boundary entry does not re-derive the frame through the machine.
    /// Returns the entry pc (a fresh frame starts at pc 0 == `code_base`).
    /// Unconditional stores are cheaper here than a same-callee short circuit.
    pub inline fn publishPushedEntry(self: *Vm, machine: *inline_calls.Machine, entry: *inline_calls.Entry, target: *const inline_calls.InlineTarget) [*]const u8 {
        const function = target.fb;
        std.debug.assert(machine.top == entry);
        std.debug.assert(machine.depth > 0);
        std.debug.assert(entry.frame.function == function);
        std.debug.assert(entry.frame.var_refs.ptr == target.var_refs or entry.frame.var_refs.len == 0);
        std.debug.assert(entry.frame.pc == 0);
        const var_refs_base = entry.frame.var_refs.ptr;
        self.machine = machine;
        self.publishPropSites(function);
        self.frame = &entry.frame;
        self.stack = &entry.stack;
        self.catch_target = &entry.catch_target;
        // A pushed frame is at depth > 0: fast table, no L0 stop.
        self.local_fast_blocked = false;
        self.active_dispatch_tbl = &dispatch_table;
        // A resolved InlineTarget's FB is already materialized.
        const code_base = function.byteCodeAssumeMaterialized().ptr;
        self.function = function;
        self.code_base = code_base;
        self.var_refs_base = var_refs_base;
        return code_base;
    }
};

// ===========================================================================
// Dispatch primitive
// ===========================================================================

pub const Handler = *const fn (pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome;

/// Every dispatch Handler lives in this one section, in source order, so the
/// hot bodies pack into a compact island (`tail_hot_layout_aarch64.ld`).
/// Default align(16); the hottest handlers use align(32)/align(64) as I-cache pins.
// Zig rejects an empty `linksection`; only ELF gets the custom section.
const op_handler_section = if (builtin.target.ofmt == .elf)
    ".text.zjs.op_handlers"
else if (builtin.target.ofmt == .macho)
    "__TEXT,__text"
else
    ".text";
/// Later-added handlers go here so they append after the established island
/// (the ld script KEEPs `.op_handlers` before `.op_handlers.*`).
const op_handler_section_tail = if (builtin.target.ofmt == .elf)
    ".text.zjs.op_handlers.tail"
else if (builtin.target.ofmt == .macho)
    "__TEXT,__text"
else
    ".text";

/// A handler reached only through a slot LLVM cannot see through: it is
/// neither inlined into the fast handler nor folded back into it, and the tail
/// dispatch keeps the exact Handler signature.
fn Opaque(comptime target: Handler) type {
    return struct {
        var slot: Handler = target;
        inline fn get() Handler {
            const p: *volatile Handler = &slot;
            return p.*;
        }
    };
}

/// Size pad keeping the handler island layout stable: the keep flag is never
/// set, so the pad is dead code the linker still has to place. Remove after
/// re-measuring.
export var zjs_f_tombstone_keep: u8 = 0;
inline fn sizePad(comptime bytes: usize) void {
    if (zjs_f_tombstone_keep != 0) {
        asm volatile (std.fmt.comptimePrint(".space 0x{x}", .{bytes}));
        unreachable;
    }
}

const PropertyTailSlot = enum(usize) {
    get_field_primitive,
    get_field2_primitive,
    get_array_el_atom_key,
    get_array_el_atom_key_getter,
    get_array_el_atom_key_proxy,
    get_field_cached_getter,
    get_field_property,
    get_field_after_own_miss,
    get_static_cached_proxy,
    get_length_property,
    get_field_typed_property,
    get_field_absent,
    get_field_native_getter,
    prop_site_indirect,
    prop_site_capture,
    put_field_add,
    put_array_el_rest,
};

const ResidentTailSlot = enum(usize) {
    add_strings,
    special_arguments,
    if_false8_complex,
};

inline fn propertyTailHandler(vm: *const Vm, comptime slot: PropertyTailSlot) Handler {
    return vm.property_tail_tbl[@intFromEnum(slot)];
}

inline fn residentTailHandler(vm: *const Vm, comptime slot: ResidentTailSlot) Handler {
    return vm.resident_tail_tbl[@intFromEnum(slot)];
}

/// Computed goto through `vm.active_dispatch_tbl` for the opcode at `pc[0]`.
/// No bounds check: emission guarantees a terminator on every path (Debug asserts).
/// Driver and jump entry point; opcode-to-opcode transitions use `cont`.
fn next(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    if (comptime builtin.mode == .Debug)
        std.debug.assert(@intFromPtr(pc) < @intFromPtr(vm.function.byteCode().ptr + vm.function.byteCode().len));
    if (comptime enabled) noteDispatch(vm.ctx.runtime, pc);
    return @call(.always_tail, vm.active_dispatch_tbl[pc[0]], .{ pc, sp, var_buf, vm });
}

// ===========================================================================
// Cold-handler infrastructure — every cold op is `publish -> helper -> coldNext`.
// ===========================================================================

/// Deliver a catchable runtime error to the CURRENT frame: true when this
/// frame caught it (`frame.pc` is at the handler, so re-dispatch through
/// `coldNext`), false when it must propagate. Two cold arms deliver onto a
/// stack other than `vm.stack` and spell the call out instead.
inline fn deliverCatchable(vm: *Vm, err: HostError) HostError!bool {
    return call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err);
}

/// Invoke a resolved native accessor entry. The caller function and frame ride
/// along so a throw inside the accessor gets the right backtrace position.
inline fn callNativeAccessor(
    vm: *Vm,
    target: builtin_dispatch.NativeAccessorTarget,
    receiver: JSValue,
    args: []const JSValue,
    comptime kind: core.native_entry.Kind,
) HostError!JSValue {
    return builtin_dispatch.callNativeAccessorTarget(vm.ctx, vm.output, vm.global, target, receiver, args, vm.function, vm.frame, kind);
}

/// L0 stop boundary (`stop_before_pc`): suspend and save state when frame.pc
/// reaches the requested fixture boundary. Generators use OP_initial_yield.
inline fn maybeStop(vm: *Vm, out: *Outcome) bool {
    if (vm.machine.depth == 0) {
        const stop_before_pc = vm.machine.l0.stop_before_pc orelse return false;
        const r = vm_gen_async.stopBeforePc(vm.ctx, vm.stack, vm.frame, vm.machine.l0.generator_state, vm.catch_target.*, stop_before_pc) catch |e| {
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

inline fn coldNext(var_buf: [*]JSValue, vm: *Vm) Outcome {
    if (vm.frame.pc >= vm.function.byteCode().len) return vm.fail(error.InvalidBytecode);
    var stop_out: Outcome = undefined;
    if (maybeStop(vm, &stop_out)) return stop_out;
    // The helper may have reallocated the stack; re-read the top from `vm.stack`.
    const npc = vm.code_base + vm.frame.pc;
    return @call(.always_tail, vm.active_dispatch_tbl[npc[0]], .{ npc, vm.stack.topPtr(), var_buf, vm });
}

/// Tail of an inline managed native call: the value lands where the call
/// window began and dispatch continues at `npc`. An exception sentinel routes
/// to `vm_native.failure` on the published frame; an armed L0 stop boundary
/// takes `coldNext` with the value pushed.
inline fn managedInlineFinish(vm: *Vm, value: JSValue, region_start: [*]JSValue, npc: [*]const u8, var_buf: [*]JSValue) Outcome {
    if (value.is(.exception)) {
        const region_base: usize = (@intFromPtr(region_start) - @intFromPtr(vm.stack.values)) / @sizeOf(JSValue);
        switch (vm_native.failure(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, region_base, builtin_dispatch.nativeHostError(vm.ctx)) catch |e| return vm.fail(e)) {
            .caught => return coldNext(var_buf, vm),
            else => unreachable,
        }
    }
    storeValueAsIntPair(&region_start[0], value);
    if (vm.machine.depth == 0 and vm.machine.l0.stop_before_pc != null) {
        vm.stack.setTopPtr(region_start + 1);
        return coldNext(var_buf, vm);
    }
    return @call(.always_tail, next, .{ npc, region_start + 1, var_buf, vm });
}

/// Continue after a native call that completed normally (`frame.pc` already synced).
inline fn nativeHitNext(var_buf: [*]JSValue, vm: *Vm) Outcome {
    if (vm.machine.depth == 0 and vm.machine.l0.stop_before_pc != null) return coldNext(var_buf, vm);
    const npc = vm.code_base + vm.frame.pc;
    return @call(.always_tail, next, .{ npc, vm.stack.topPtr(), var_buf, vm });
}

/// Cold-handler adapters. A cold opcode's whole body is an out-of-line
/// helper in a `vm_*.zig` module taking `*Vm` (plus the opcode byte when the
/// helper serves several opcodes); the adapter publishes pc/sp, runs it, and
/// re-dispatches through `coldNext`. Three helper shapes are accepted:
/// `cold` for `fn (vm)`, `coldOp` for `fn (vm, opc)`, `coldStd` for
/// `fn (vm, pc)`.
pub fn cold(comptime body: fn (vm: *Vm) HostError!void) Handler {
    return coldStd(struct {
        fn withPc(vm: *Vm, pc: [*]const u8) HostError!void {
            _ = pc;
            try body(vm);
        }
    }.withPc);
}

pub fn coldOp(comptime body: fn (vm: *Vm, opc: u8) HostError!void) Handler {
    return coldStd(struct {
        fn withPc(vm: *Vm, pc: [*]const u8) HostError!void {
            try body(vm, pc[0]);
        }
    }.withPc);
}

/// Cold handler shell: publish, run `body`, re-dispatch via `coldNext`.
pub fn coldStd(comptime body: fn (vm: *Vm, pc: [*]const u8) HostError!void) Handler {
    return struct {
        fn handler(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
            vm.publish(pc, sp);
            body(vm, pc) catch |e| return vm.fail(e);
            return coldNext(var_buf, vm);
        }
    }.handler;
}

/// Cold handler shell for generator/await ops: a returned value exits the
/// whole chain (yield/await suspends the frame).
pub fn coldGen(comptime body: fn (vm: *Vm, pc: [*]const u8) HostError!?JSValue) Handler {
    return struct {
        fn handler(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
            vm.publish(pc, sp);
            if (body(vm, pc) catch |e| return vm.fail(e)) |value| {
                vm.return_value = value;
                return .returned;
            }
            return coldNext(var_buf, vm);
        }
    }.handler;
}

// ---- depth==0 entry-guard accessors ----
pub inline fn isEvalCode(vm: *Vm) bool {
    return if (vm.machine.depth == 0) vm.machine.l0.is_eval_code else false;
}
pub inline fn evalGlobalVarBindings(vm: *Vm) bool {
    return if (vm.machine.depth == 0) vm.machine.l0.eval_global_var_bindings else false;
}
pub inline fn directEvalVarsReachGlobal(vm: *Vm) bool {
    return if (vm.machine.depth == 0) vm.machine.l0.direct_eval_vars_reach_global else false;
}
pub inline fn strictUnresolvedGetVar(vm: *Vm) bool {
    return if (vm.machine.depth == 0) vm.machine.l0.strict_unresolved_get_var else (vm.function.isStrictMode() or vm.function.runtimeStrictMode());
}
pub inline fn generatorState(vm: *Vm) ?*core.Object {
    return if (vm.machine.depth == 0) vm.machine.l0.generator_state else null;
}
pub inline fn stopOnYield(vm: *Vm) bool {
    return if (vm.machine.depth == 0) vm.machine.l0.stop_on_yield else false;
}
pub inline fn suspendOnModuleAwait(vm: *Vm) bool {
    return if (vm.machine.depth == 0) vm.machine.l0.suspend_on_module_await else false;
}

// ===========================================================================
// Endpoint handlers
// ===========================================================================

fn op_invalid(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    _ = pc;
    _ = sp;
    _ = var_buf;
    vm.pending_error = error.InvalidBytecode;
    return .threw;
}

// ===========================================================================
// Cold handlers + specials. Every op has its own cold handler; the fast
// handlers further down override a subset of table entries.
// ===========================================================================

// ---- SPECIAL handlers (call / return / tail / drop / throw / eval / generator) ----

/// op.call setup-failure recovery: close a pending for-of iterator, then try
/// to convert the failure (OOM-class) into a JS-catchable error in the CALLER
/// frame. True when the caller caught it (frame.pc is at the handler;
/// re-dispatch via coldNext), false when it must propagate
/// (`vm.pending_error` set). noinline keeps it off the hot path's registers.
noinline fn callSetupRecover(vm: *Vm, err: HostError) bool {
    forof_ops.closeStackTopForOfIteratorForPendingError(vm.ctx, vm.output, vm.global, vm.stack) catch |e2| {
        vm.pending_error = e2;
        return false;
    };
    const caught = deliverCatchable(vm, err) catch |e2| {
        vm.pending_error = e2;
        return false;
    };
    if (!caught) {
        vm.pending_error = err;
        return false;
    }
    return true;
}

/// Constructor setup recovery matching vm_call.constructor: the caller's
/// constructor operand region has already been consumed, so only deliver the
/// pending exception to the intact caller frame. Unlike ordinary OP_call,
/// OP_call_constructor has no implicit IteratorClose step here.
noinline fn constructorSetupRecover(vm: *Vm, err: HostError) bool {
    const caught = deliverCatchable(vm, err) catch |e2| {
        vm.pending_error = e2;
        return false;
    };
    if (!caught) {
        vm.pending_error = err;
        return false;
    }
    return true;
}

/// An error before same-Machine constructor setup still owns the complete
/// `[func, new_target, args...]` caller region: release it, then deliver
/// through `constructorSetupRecover`.
noinline fn constructorRegionRecover(vm: *Vm, region_base: usize, err: HostError) bool {
    call_runtime.popOwnedStackRegion(vm.stack, region_base);
    return constructorSetupRecover(vm, err);
}

/// `IteratorNext` itself is outside the IteratorClose-on-abrupt region (qjs
/// `JS_IteratorNext2` propagates a failing `next()` directly). A same-Machine
/// setup failure for that method therefore tries the caller catch without
/// closing the iterator record first.
noinline fn iteratorNextCallSetupRecover(vm: *Vm, depth: u8, err: HostError) bool {
    forof_ops.abandonForOfIteratorAtDepth(vm.ctx.runtime, vm.stack, depth) catch |abandon_err| {
        vm.pending_error = abandon_err;
        return false;
    };
    const caught = deliverCatchable(vm, err) catch |e2| {
        vm.pending_error = e2;
        return false;
    };
    if (!caught) {
        vm.pending_error = err;
        return false;
    }
    return true;
}

/// Record the skipped Function.prototype.apply builtin in
/// `Entry.native_caller` so backtraces keep qjs's frame order. Must run while
/// `vm.function` is still the caller. Does not insert an InlinedSite ghost
/// (consumeInlineThenPhysical would double-print apply).
noinline fn attachApplyForwardNativeCaller(vm: *Vm, entry: *inline_calls.Entry) void {
    if (entry.teardown.has_native_caller) return;
    if (entry.teardown.empty_leaf or entry.teardown.exact_args_leaf) return;
    if (entry.teardown.constructor_completion) return;
    if (small_inline.applyForwardSiteAfterCall(vm.function, @intCast(vm.frame.pc)) == null) return;
    const apply_obj = small_inline.realmApplyBuiltin(vm.rt, vm.global) orelse return;
    entry.native_caller = apply_obj.value();
    entry.teardown.has_native_caller = true;
}

/// Complete an inline call inside the handler (qjs CASE(OP_call) shape):
/// publish the just-pushed entry as the current level and tail-dispatch into
/// the callee's first opcode, with no driver round-trip. `code_ptr` is the
/// callee's first pc read off the shared FunctionBytecode. Inline so the tail
/// call stays legal in the Handler-signature caller.
inline fn enterEntry(vm: *Vm, entry: *inline_calls.Entry, code_ptr: [*]const u8) Outcome {
    std.debug.assert(code_ptr == entry.frame.function.byteCode().ptr);
    vm.function = entry.frame.function;
    vm.publishPropSites(vm.function);
    vm.frame = &entry.frame;
    vm.var_refs_base = entry.frame.var_refs.ptr;
    vm.stack = &entry.stack;
    vm.catch_target = &entry.catch_target;
    vm.code_base = code_ptr;
    // Just pushed, so depth > 0 and the L0-only generator stop mode is off.
    // Only a blocked L0 caller switches the callee to the fast table;
    // reloadAfterPop re-arms the cold table on return.
    if (vm.local_fast_blocked) {
        @branchHint(.unlikely);
        std.debug.assert(entry.prev == null and vm.machine.l0.stop_before_pc != null);
        vm.local_fast_blocked = false;
        vm.active_dispatch_tbl = &dispatch_table;
    }
    const pc2: [*]const u8 = code_ptr; // fresh frame: frame.pc == 0
    const sp2: [*]JSValue = vm.stack.topPtr();
    const vb2: [*]JSValue = vm.frame.locals.ptr;
    return @call(.always_tail, next, .{ pc2, sp2, vb2, vm });
}

/// Call-entry interrupt poll for a region whose caller-visible top has already
/// retreated (ownership transfers without copies). The warm body keeps only
/// qjs js_poll_interrupts' cadence tick; the cold half re-polls (still <= 0)
/// and runs the handler leg once per cadence hit. Returns true when the poll
/// threw (`pending_error` published): the caller must `return .threw`. A bool
/// keeps the result in one register; an `?Outcome` materialized through memory.
inline fn pollRetreatedCallRegion(
    vm: *Vm,
    region_start: [*]JSValue,
    value_count: usize,
) bool {
    if (!vm.ctx.pollInterruptTick()) return false;
    return pollRetreatedCallRegionCold(vm, region_start, value_count);
}

/// Cold half of the call-entry poll. An uncatchable interruption before the
/// callee runs leaves ownership with the caller, so the retreated top is
/// restored before failing. noinline keeps the throw machinery off the warm body.
noinline fn pollRetreatedCallRegionCold(
    vm: *Vm,
    region_start: [*]JSValue,
    value_count: usize,
) bool {
    exception_ops.pollInterrupt(vm.ctx, vm.global) catch |err| {
        vm.stack.setTopPtr(region_start + value_count);
        _ = vm.fail(err);
        return true;
    };
    return false;
}

inline fn pushAndEnter(var_buf: [*]JSValue, vm: *Vm, target: *const inline_calls.InlineTarget, region_start: [*]JSValue, argc: u16, comptime layout: inline_calls.RegionLayout) Outcome {
    const source_count = @as(usize, argc) + 1 + @as(usize, @intFromBool(layout == .method));
    if (pollRetreatedCallRegion(vm, region_start, source_count)) return .threw;
    const entry = switch (layout) {
        .plain => vm.machine.pushPlainCall(vm.global, vm.stack, target, region_start, argc),
        .method => vm.machine.pushMethodCall(vm.global, vm.stack, target, region_start, argc),
    } catch |err| {
        if (!callSetupRecover(vm, err)) return .threw;
        return coldNext(var_buf, vm);
    };
    return enterEntry(vm, entry, target.fb.byteCodeAssumeMaterialized().ptr);
}

/// Apply-forward setup, outlined so neither `op_call_method` nor the dedicated
/// handler grows a frame around it. `enterEntry` / `coldNext` stay in the
/// Handler because `@call(.always_tail)` requires that signature.
noinline fn pushApplyForwardEntry(
    vm: *Vm,
    target: *const inline_calls.InlineTarget,
    region_start: [*]JSValue,
    argc: u16,
) PushResult {
    const source_count = @as(usize, argc) + 2;
    if (pollRetreatedCallRegion(vm, region_start, source_count)) return .threw;
    const entry = vm.machine.pushMethodCall(vm.global, vm.stack, target, region_start, argc) catch |err| {
        if (!callSetupRecover(vm, err)) return .threw;
        return .caught;
    };
    attachApplyForwardNativeCaller(vm, entry);
    return .{ .entry = entry };
}

/// `op.call_method_apply_fwd`: only runs on a specialized constructor
/// initialize site, so it stays out of the hot handler section. Not
/// `noinline` (that is part of the fn type and breaks `@call(.always_tail)`).
fn applyForwardCallMethod(
    pc: [*]const u8,
    sp: [*]JSValue,
    var_buf: [*]JSValue,
    vm: *Vm,
) callconv(.c) Outcome {
    vm.syncPc(pc, 1);
    const argc = readInt(u16, pc + 1);
    const total = @as(usize, argc) + 2;
    const live_bytes = @intFromPtr(sp) - @intFromPtr(vm.stack.values);
    if (live_bytes < total * @sizeOf(JSValue)) return .threw;
    const region_start = sp - total;
    vm.frame.pc += 2;
    vm.stack.retreatToCallRegionFrom(&vm.machine.pending_call_region, sp, region_start);
    const receiver = region_start[0];
    const method = region_start[1];
    const method_obj = object_ops.objectFromValue(method) orelse return .threw;
    // The specialize-time guard is never re-validated, so a native/bound
    // replacement can land here; `resolveInlineFunctionFromObject` requires a
    // verified bytecode-function class.
    if (method_obj.class_id != core.class.ids.bytecode_function) return .threw;
    const resolved = inline_calls.resolveInlineFunctionFromObject(vm.global, method_obj) orelse return .threw;
    const target = resolved.bind(receiver, method);
    return switch (pushApplyForwardEntry(vm, &target, region_start, argc)) {
        .entry => |entry| enterEntry(vm, entry, resolved.fb.byteCodeAssumeMaterialized().ptr),
        .caught => coldNext(var_buf, vm),
        .threw => .threw,
    };
}

/// Warm zero-arg entry for a published empty-leaf callee. `resume_pc` (the
/// caller's post-operand pc) rides into the entry's resume record so the
/// return arm restores pc/sp with one load. The receiver instantiation's
/// region is `[receiver, callable]` and the receiver becomes the frame's raw
/// `this`; plain instantiations use the realm global (sloppy) or undefined.
inline fn pushWarmEmptyLeafAndEnter(comptime leaf_this: inline_calls.LeafThis, var_buf: [*]JSValue, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, region_start: [*]JSValue, resume_pc: [*]const u8, code_ptr: [*]const u8) Outcome {
    const source_count = 1 + @as(usize, @intFromBool(leaf_this == .receiver));
    if (pollRetreatedCallRegion(vm, region_start, source_count)) return .threw;
    const entry = vm.machine.tryPushEmptyLeafCallFast(leaf_this, vm.rt, vm.global, vm.stack, function, call_facts, region_start, resume_pc) orelse switch (pushEmptyLeafMiss(leaf_this, vm, function, call_facts, region_start)) {
        .entry => |slow_entry| slow_entry,
        .threw => return .threw,
        .caught => return coldNext(var_buf, vm),
    };
    return enterEntry(vm, entry, code_ptr);
}

/// Exact-args twin of the warm empty-leaf adapter: the caller-region args
/// window is borrowed in place. The miss constructor keeps first-use Entry
/// allocation, chunk switching, heap fallback and error recovery out of the
/// handler body.
inline fn pushWarmExactArgsLeafAndEnter(comptime leaf_this: inline_calls.LeafThis, comptime return_action: inline_calls.ReturnAction, var_buf: [*]JSValue, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue, argc: u16, resume_pc: [*]const u8, code_ptr: [*]const u8) Outcome {
    comptime std.debug.assert(return_action == .next or return_action == .to_boolean);
    const source_count = @as(usize, argc) + 1 + @as(usize, @intFromBool(leaf_this == .receiver));
    if (pollRetreatedCallRegion(vm, region_start, source_count)) return .threw;
    const entry = vm.machine.tryPushExactArgsLeafCallFast(leaf_this, vm.rt, vm.global, vm.stack, function, call_facts, captures, region_start, argc, resume_pc) orelse switch (pushExactArgsLeafMiss(leaf_this, vm, function, call_facts, captures, region_start, argc)) {
        .entry => |slow_entry| slow_entry,
        .threw => return .threw,
        .caught => return coldNext(var_buf, vm),
    };
    if (comptime return_action != .next) entry.return_action = return_action;
    return enterEntry(vm, entry, code_ptr);
}

/// Result of an out-of-line frame push: the entry to dispatch into, a
/// setup failure the caller frame caught (re-dispatch via `coldNext`), or one
/// that must propagate (`vm.pending_error` is set).
const PushResult = union(enum) {
    entry: *inline_calls.Entry,
    threw,
    caught,
};

noinline fn pushEmptyLeafMiss(comptime leaf_this: inline_calls.LeafThis, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, region_start: [*]JSValue) PushResult {
    const entry = vm.machine.pushEmptyLeafCall(leaf_this, vm.global, vm.stack, function, call_facts, region_start) catch |err| {
        if (!callSetupRecover(vm, err)) return .threw;
        return .caught;
    };
    return .{ .entry = entry };
}

/// Handler-side adapter for the outline warm constructor above.
inline fn pushWarmOutlineExactArgsLeafAndEnter(comptime leaf_this: inline_calls.LeafThis, var_buf: [*]JSValue, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue, argc: u16, resume_pc: [*]const u8, code_ptr: [*]const u8) Outcome {
    const source_count = @as(usize, argc) + 1 + @as(usize, @intFromBool(leaf_this == .receiver));
    if (pollRetreatedCallRegion(vm, region_start, source_count)) return .threw;
    const entry = switch (warmExactArgsLeafOutline(leaf_this, vm, function, call_facts, captures, region_start, argc, resume_pc)) {
        .entry => |e| e,
        .threw => return .threw,
        .caught => return coldNext(var_buf, vm),
    };
    return enterEntry(vm, entry, code_ptr);
}

/// Out-of-line empty-leaf entry (dynamic-argc plain calls and the strict
/// method arm). The caller has already published the post-operand frame.pc,
/// which the constructor captures as the resume record.
inline fn pushEmptyLeafAndEnter(comptime leaf_this: inline_calls.LeafThis, var_buf: [*]JSValue, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, region_start: [*]JSValue, code_ptr: [*]const u8) Outcome {
    const source_count = 1 + @as(usize, @intFromBool(leaf_this == .receiver));
    if (pollRetreatedCallRegion(vm, region_start, source_count)) return .threw;
    const entry = vm.machine.pushEmptyLeafCall(leaf_this, vm.global, vm.stack, function, call_facts, region_start) catch |err| {
        if (!callSetupRecover(vm, err)) return .threw;
        return coldNext(var_buf, vm);
    };
    return enterEntry(vm, entry, code_ptr);
}

/// Out-of-line exact-args leaf entry (raw-`this` twin). A second warm inline
/// body would be instruction-identical to the sloppy one and could tail-merge
/// with it, so this arm calls the authoritative constructor instead.
inline fn pushExactArgsLeafAndEnter(comptime leaf_this: inline_calls.LeafThis, comptime return_action: inline_calls.ReturnAction, var_buf: [*]JSValue, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue, argc: u16, code_ptr: [*]const u8) Outcome {
    comptime std.debug.assert(return_action == .next or return_action == .to_boolean);
    const source_count = @as(usize, argc) + 1 + @as(usize, @intFromBool(leaf_this == .receiver));
    if (pollRetreatedCallRegion(vm, region_start, source_count)) return .threw;
    const entry = vm.machine.pushExactArgsLeafCall(leaf_this, vm.global, vm.stack, function, call_facts, captures, region_start, argc) catch |err| {
        if (!callSetupRecover(vm, err)) return .threw;
        return coldNext(var_buf, vm);
    };
    if (comptime return_action != .next) entry.return_action = return_action;
    return enterEntry(vm, entry, code_ptr);
}

/// Warm capture-leaf entry for zero-arg callees over captured state
/// (`() => this.x`). Same warm/miss split as the empty-leaf adapter; the warm
/// constructor adds only the borrowed capture binding.
inline fn pushWarmCaptureLeafAndEnter(comptime leaf_this: inline_calls.LeafThis, var_buf: [*]JSValue, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue, resume_pc: [*]const u8, code_ptr: [*]const u8) Outcome {
    const source_count = 1 + @as(usize, @intFromBool(leaf_this == .receiver));
    if (pollRetreatedCallRegion(vm, region_start, source_count)) return .threw;
    const entry = vm.machine.tryPushCaptureLeafCallFast(leaf_this, vm.rt, vm.global, vm.stack, function, call_facts, captures, region_start, resume_pc) orelse switch (pushCaptureLeafMiss(leaf_this, vm, function, call_facts, captures, region_start)) {
        .entry => |slow_entry| slow_entry,
        .threw => return .threw,
        .caught => return coldNext(var_buf, vm),
    };
    return enterEntry(vm, entry, code_ptr);
}

/// Handler-side adapter for the outline warm capture-leaf constructor (the
/// non-pivot sloppy plain twin; see `warmCaptureLeafOutline`).
inline fn pushWarmOutlineCaptureLeafAndEnter(comptime leaf_this: inline_calls.LeafThis, var_buf: [*]JSValue, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue, resume_pc: [*]const u8, code_ptr: [*]const u8) Outcome {
    const source_count = 1 + @as(usize, @intFromBool(leaf_this == .receiver));
    if (pollRetreatedCallRegion(vm, region_start, source_count)) return .threw;
    const entry = switch (warmCaptureLeafOutline(leaf_this, vm, function, call_facts, captures, region_start, resume_pc)) {
        .entry => |e| e,
        .threw => return .threw,
        .caught => return coldNext(var_buf, vm),
    };
    return enterEntry(vm, entry, code_ptr);
}

/// Out-of-line capture-leaf entry (dynamic-argc plain calls and the method
/// receiver arm); see `pushExactArgsLeafAndEnter` for why it is not inlined.
inline fn pushCaptureLeafAndEnter(comptime leaf_this: inline_calls.LeafThis, var_buf: [*]JSValue, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue, code_ptr: [*]const u8) Outcome {
    const source_count = 1 + @as(usize, @intFromBool(leaf_this == .receiver));
    if (pollRetreatedCallRegion(vm, region_start, source_count)) return .threw;
    const entry = vm.machine.pushCaptureLeafCall(leaf_this, vm.global, vm.stack, function, call_facts, captures, region_start) catch |err| {
        if (!callSetupRecover(vm, err)) return .threw;
        return coldNext(var_buf, vm);
    };
    return enterEntry(vm, entry, code_ptr);
}

/// Cold half of the moved/borrowed-region entry polls: like
/// `pollRetreatedCallRegionCold` but without region restore, since moved and
/// borrowed sources keep ownership in the caller's scoped cleanup. Returns true
/// when the poll threw (caller must `return .threw`).
noinline fn pollCallEntryCold(vm: *Vm) bool {
    exception_ops.pollInterrupt(vm.ctx, vm.global) catch |err| {
        _ = vm.fail(err);
        return true;
    };
    return false;
}

/// Same-Machine entry for a call region already moved out of the caller's
/// operand layout. Proxy `get` uses this because its semantic arguments are
/// `[target, key, receiver]`, while the caller must retain `[target, key]` for
/// the post-trap invariant continuation.
inline fn pushMovedAndEnter(
    var_buf: [*]JSValue,
    vm: *Vm,
    target: *const inline_calls.InlineTarget,
    moved_values: []JSValue,
    return_action: inline_calls.ReturnAction,
    continuation_payload: u32,
    comptime interrupt_polled: bool,
) Outcome {
    if (!interrupt_polled) {
        if (vm.ctx.pollInterruptTick()) {
            if (pollCallEntryCold(vm)) return .threw;
        }
    }
    const entry = vm.machine.pushMovedCall(vm.global, target, moved_values, .method, return_action, continuation_payload) catch |err| {
        const recovered = if (return_action == .for_of_next)
            iteratorNextCallSetupRecover(vm, @intCast(continuation_payload), err)
        else
            callSetupRecover(vm, err);
        if (!recovered) return .threw;
        return coldNext(var_buf, vm);
    };
    return enterEntry(vm, entry, target.fb.byteCodeAssumeMaterialized().ptr);
}

/// qjs internal IteratorNext borrows `enum_obj` and `method` from the caller's
/// persistent iterator record. Keep the caller stack untouched and enter the
/// child frame with borrowed call bindings; its continuation returns here
/// before those two slots can be released or reused.
inline fn pushBorrowedIteratorAndEnter(
    var_buf: [*]JSValue,
    vm: *Vm,
    target: *const inline_calls.InlineTarget,
    iterator_record: []JSValue,
    depth: u8,
) Outcome {
    // Borrowed bindings stay rooted on the suspended caller stack, so a poll
    // throw needs no ownership restore. This is the single semantic call poll
    // on both legs (the miss fallback passes interrupt_polled=true).
    if (vm.ctx.pollInterruptTick()) {
        if (pollCallEntryCold(vm)) return .threw;
    }
    const maybe_entry = vm.machine.pushBorrowedIteratorNext(vm.global, target, iterator_record, depth) catch |err| {
        if (!iteratorNextCallSetupRecover(vm, depth, err)) return .threw;
        return coldNext(var_buf, vm);
    };
    const entry = maybe_entry orelse {
        var moved = [2]JSValue{ iterator_record[0], iterator_record[1] };
        return pushMovedAndEnter(var_buf, vm, target, &moved, .for_of_next, depth, true);
    };
    return enterEntry(vm, entry, target.fb.byteCodeAssumeMaterialized().ptr);
}

const ForwardedEntryResult = union(enum) {
    entry: struct { entry: *inline_calls.Entry, code_ptr: [*]const u8 },
    caught,
    threw,
    /// Nothing was touched (window, pc, top): take the generic call path.
    generic,
};

/// Function.prototype.call / apply window-rewrite arms. The operand region
/// `[f, call|apply, thisArg?, rest...]` is rewritten in place to the ordinary
/// method layout `[thisArg, f, args...]` when `f` is a same-Realm plain
/// bytecode function, then pushed through `pushMethodCall` like `recv.m()`.
///
/// `call` (qjs `js_function_call`) shifts args down one slot. `apply` (qjs
/// `js_function_apply` / `build_arg_list`) spreads a dense list into the
/// window; `array_ops.fastApplyArgs` admits only shapes copied without an
/// observable [[Get]], everything else stays generic. The skipped native
/// record rides in `Entry.native_caller` so backtraces keep qjs's frame order
/// `target -> call (native) -> caller`.
///
/// One outlined body per builtin keeps the spread loops out of
/// `op_call_method`; `enterEntry` / `coldNext` stay in the handler because
/// `@call(.always_tail)` needs the Handler signature.
noinline fn pushForwardedCallEntry(
    vm: *Vm,
    region_start: [*]JSValue,
    argc: u16,
) ForwardedEntryResult {
    const target_value = region_start[0];
    const resolved = resolveForwardedTarget(vm, target_value) orelse return .generic;
    const native_caller = region_start[1];
    const this_arg = if (argc >= 1) region_start[2] else JSValue.undefinedValue();
    const target_argc: usize = if (argc >= 1) argc - 1 else 0;
    region_start[0] = this_arg;
    region_start[1] = target_value;
    if (target_argc != 0) {
        std.mem.copyForwards(JSValue, region_start[2..][0..target_argc], region_start[3..][0..target_argc]);
    }
    return finishForwardedEntry(vm, region_start, target_argc, @as(usize, argc) + 2, resolved, this_arg, target_value, native_caller);
}

noinline fn pushForwardedApplyEntry(
    vm: *Vm,
    sp: [*]JSValue,
    region_start_in: [*]JSValue,
    argc: u16,
) ForwardedEntryResult {
    var region_start = region_start_in;
    const target_value = region_start[0];
    const resolved = resolveForwardedTarget(vm, target_value) orelse return .generic;
    const native_caller = region_start[1];
    const this_arg = if (argc >= 1) region_start[2] else JSValue.undefinedValue();
    const list_value = if (argc >= 2) region_start[3] else JSValue.undefinedValue();
    const old_total: usize = @as(usize, argc) + 2;
    // qjs js_function_apply: an undefined/null list calls with no arguments.
    const list: ?array_ops.FastApplyArgs = if (list_value.is(.undefined_value) or list_value.is(.null_value))
        null
    else
        (array_ops.fastApplyArgs(list_value) orelse return .generic);
    const target_argc: usize = if (list) |view| view.len() else 0;
    if (target_argc + 2 > old_total) {
        region_start = growForwardedWindow(vm, sp, region_start, old_total, target_argc + 2) orelse return .generic;
    }
    region_start[0] = this_arg;
    region_start[1] = target_value;
    if (list) |view| view.copyTo(region_start[2..][0..target_argc]);
    return finishForwardedEntry(vm, region_start, target_argc, old_total, resolved, this_arg, target_value, native_caller);
}

inline fn resolveForwardedTarget(vm: *Vm, target_value: JSValue) ?inline_calls.ResolvedInlineFunction {
    const target_obj = object_ops.objectFromValue(target_value) orelse return null;
    if (target_obj.class_id != core.class.ids.bytecode_function) return null;
    return inline_calls.resolveInlineFunctionFromObject(vm.global, target_obj);
}

/// Cold: the spread does not fit the caller's operand window. Grow the stack
/// (the list view is a borrowed heap pointer and the window relocates with
/// `stack.values`). Null when the reservation fails: nothing was touched and
/// the generic apply body reports the overflow.
noinline fn growForwardedWindow(vm: *Vm, sp: [*]JSValue, region_start: [*]JSValue, old_total: usize, new_total: usize) ?[*]JSValue {
    const region_base = (@intFromPtr(region_start) - @intFromPtr(vm.stack.values)) / @sizeOf(JSValue);
    if (region_base + new_total <= vm.stack.capacity) return region_start;
    vm.stack.setTopPtr(sp);
    vm.stack.reserveAdditional(new_total - old_total) catch return null;
    return vm.stack.values + region_base;
}

inline fn finishForwardedEntry(
    vm: *Vm,
    region_start: [*]JSValue,
    target_argc: usize,
    old_total: usize,
    resolved: inline_calls.ResolvedInlineFunction,
    this_arg: JSValue,
    target_value: JSValue,
    native_caller: JSValue,
) ForwardedEntryResult {
    const new_total = target_argc + 2;
    // Clear vacated slots above the rewritten window so no stale copy
    // looks like a live root.
    if (new_total < old_total) @memset(region_start[new_total..old_total], JSValue.undefinedValue());
    vm.frame.pc += 2;
    vm.stack.retreatToCallRegionFrom(&vm.machine.pending_call_region, region_start + new_total, region_start);
    if (pollRetreatedCallRegion(vm, region_start, new_total)) return .threw;
    // The rewritten window is already the method layout the exact-args leaf
    // constructor takes, so `f.call(this, x)` on a published leaf builds the
    // same frame `holder.f(x)` would. The native record still rides in
    // `Entry.native_caller` (see `tryPushForwardedExactArgsLeafFast`).
    const function = resolved.fb;
    const execution = resolved.call_facts.execution;
    if (execution.exact_args_leaf_kind != .none and target_argc == function.arg_count and target_argc != 0) {
        if (vm.machine.tryPushForwardedExactArgsLeafFast(
            vm.rt,
            vm.global,
            vm.stack,
            function,
            resolved.call_facts,
            resolved.var_refs[0..function.closureVarCount()],
            region_start,
            @intCast(target_argc),
            native_caller,
        )) |entry| {
            return .{ .entry = .{ .entry = entry, .code_ptr = function.byteCodeAssumeMaterialized().ptr } };
        }
    }
    const target = resolved.bind(this_arg, target_value);
    const entry = vm.machine.pushMethodCall(vm.global, vm.stack, &target, region_start, @intCast(target_argc)) catch |err| {
        if (!callSetupRecover(vm, err)) return .threw;
        return .caught;
    };
    // pushMethodCall never builds a leaf frame, so the native_caller slot
    // (overlaid by the leaf resume record) is free.
    std.debug.assert(!entry.teardown.empty_leaf and !entry.teardown.exact_args_leaf);
    std.debug.assert(!entry.teardown.constructor_completion);
    entry.native_caller = native_caller;
    entry.teardown.has_native_caller = true;
    return .{ .entry = .{ .entry = entry, .code_ptr = resolved.fb.byteCodeAssumeMaterialized().ptr } };
}

/// qjs `js_proxy_get` work that runs *after* a bytecode trap returns. The
/// caller stack ends in `[target, key]`; `result` is rooted explicitly so all
/// three survive a nested descriptor probe. On success the pair contracts to
/// the result; on error it is removed before the caller's catch runs.
fn completeProxyGetContinuation(vm: *Vm, result: JSValue, atom_id: core.Atom) HostError!void {
    const rt = vm.ctx.runtime;
    var rooted_result = result;
    var root_frame = core.runtime.rootValues(.{&rooted_result});
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);
    // The key was moved out of the Entry, so this native local is its only
    // holder, and the invariant walk below can re-enter JS.
    var atom_roots = core.runtime.rootAtoms(.{&atom_id});
    atom_roots.activate(rt);
    defer atom_roots.deactivate(rt);

    const stack = vm.stack;
    std.debug.assert(stack.len() >= 2);
    const region_base = stack.len() - 2;
    const target_value = stack.values[region_base];

    const target = object_ops.objectFromValue(target_value).?;
    object_ops.validateProxyGetResult(
        vm.ctx,
        vm.output,
        vm.global,
        target,
        atom_id,
        rooted_result,
        vm.function,
        vm.frame,
    ) catch |err| {
        stack.setLen(region_base);
        rooted_result = JSValue.undefinedValue();
        const caught = call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, stack, vm.frame, vm.catch_target, vm.global, err) catch |e2| return e2;
        if (!caught) return err;
        return;
    };

    const values = stack.values;
    values[region_base] = rooted_result;
    values[region_base + 1] = JSValue.undefinedValue();
    stack.setLen(region_base + 1);
}

/// Cold post-return dispatcher; keeping the continuation bodies out of
/// `popAndResume` keeps the ordinary return a single compare.
///
/// The `.for_of_next` arm inlines the dominant iterator-result shape (qjs
/// JS_IteratorNext's done tail plus js_for_of_next's `sp[0] = value;
/// sp[1] = done` layout). `pc`/`sp` are already the caller's resume state.
/// Eligibility mirrors `iteratorResultProperty`'s fast leg: ordinary receiver
/// with own data slots and a plain-bool `done`. Everything else (exotic
/// receivers, prototype misses, done==true, capacity shortfall, the L0 stop
/// seam) takes the authoritative completion. The borrowed-entry invariant
/// (the caller stack is untouched while the method frame runs,
/// finishForOfNextResult) is what makes operand re-validation unnecessary.
fn op_post_call_continuation(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const result = loadValueAsIntPair(&vm.return_value);
    const action = vm.return_action;
    const payload = vm.return_payload;
    vm.return_value = JSValue.undefinedValue();
    vm.return_action = .next;
    vm.return_payload = 0;
    switch (action) {
        .async_complete => {
            vm.machine.async_completions.at(payload).value = result;
            const promise = vm.machine.completeAsync(payload, false) catch |err| {
                if (!callSetupRecover(vm, err)) return .threw;
                return coldNext(var_buf, vm);
            };
            vm.stack.pushOwnedAssumeCapacity(promise);
        },
        .proxy_get => completeProxyGetContinuation(vm, result, core.Atom.fromRaw(payload)) catch |err| return vm.fail(err),
        .to_boolean => {
            std.debug.assert(payload == 0);
            const bool_result = JSValue.boolean(coercion_ops.valueTruthy(result));
            sp[0] = bool_result;
            vm.stack.setTopPtr(sp + 1);
            if (!vm.local_fast_blocked) return @call(.always_tail, next, .{ pc, sp + 1, var_buf, vm });
        },
        .for_of_next => {
            fast: {
                // Stop-boundary frames must suspend through coldNext's maybeStop.
                if (vm.local_fast_blocked) break :fast;
                const next_object = object_ops.objectFromValue(result) orelse break :fast;
                if (next_object.proxyTarget() != null or next_object.hasExoticMethods()) break :fast;
                const stack = vm.stack;
                std.debug.assert(sp == stack.topPtr());
                // Same capacity contract as finishForOfNextResult.
                if (stack.len() > stack.capacity or stack.capacity - stack.len() < 2) break :fast;
                var slow_property = false;
                // Integer-pair reloads: the callee just wrote `result.value`
                // as two 64-bit stores, and a 128-bit re-read would stall on
                // store-to-load forwarding.
                const done_slot = next_object.findOwnDataSlotFast(core.atom.ids.done, &slow_property) orelse break :fast;
                const done = loadValueAsIntPair(done_slot).as(.boolean) orelse break :fast;
                if (done) break :fast;
                const result_value_slot = next_object.findOwnDataSlotFast(core.atom.ids.value, &slow_property) orelse break :fast;
                const value = loadValueAsIntPair(result_value_slot);
                // Deliver `[value, done]` as split stores (same forwarding reason).
                storeValueAsIntPair(&sp[0], value);
                storeValueAsIntPair(&sp[1], JSValue.boolean(false));
                stack.setTopPtr(sp + 2);
                return @call(.always_tail, next, .{ pc, sp + 2, var_buf, vm });
            }
            completeForOfNextContinuation(vm, result, @intCast(payload)) catch |err| return vm.fail(err);
        },
        .constructor => unreachable,
        .native_boundary => {
            storeValueAsIntPair(&vm.return_value, result);
            return .native_returned;
        },
        .next => unreachable,
    }
    return coldNext(var_buf, vm);
}

fn completeForOfNextContinuation(vm: *Vm, result: JSValue, depth: u8) HostError!void {
    iterator_ops.finishForOfNextResult(
        vm.ctx,
        vm.output,
        vm.global,
        vm.stack,
        vm.function,
        vm.frame,
        depth,
        result,
    ) catch |err| {
        const caught = try deliverCatchable(vm, err);
        if (!caught) return err;
    };
}

/// Read an operand-stack slot.
inline fn loadValueAsIntPair(slot: *const JSValue) JSValue {
    return slot.*;
}

/// `loadValueAsIntPair` with the load pinned as `ldr` on AArch64.
inline fn loadValueAsSplitPair(slot: *const JSValue) JSValue {
    if (comptime builtin.cpu.arch == .aarch64) {
        var bits: u64 = undefined;
        asm volatile ("ldr %[bits], [%[p]]"
            : [bits] "=r" (bits),
            : [p] "r" (slot),
        );
        return .{ .bits = bits };
    }
    return slot.*;
}

/// Store twin of `loadValueAsIntPair`.
inline fn storeValueAsIntPair(slot: *JSValue, value: JSValue) void {
    slot.* = value;
}

/// Publish `caller` as the current level after a leaf frame popped: the same
/// fields `reloadAfterPop`'s entry arm writes, minus pc/sp, which the leaf arms
/// take from their resume record instead. Returns the caller's local base.
inline fn republishCaller(vm: *Vm, caller: *inline_calls.Entry) [*]JSValue {
    const caller_function = caller.frame.function;
    vm.frame = &caller.frame;
    vm.var_refs_base = caller.frame.var_refs.ptr;
    vm.stack = &caller.stack;
    vm.catch_target = &caller.catch_target;
    vm.function = caller_function;
    vm.publishPropSites(caller_function);
    vm.code_base = caller_function.byteCodeAssumeMaterialized().ptr;
    return caller.frame.locals.ptr;
}

/// A popped leaf whose predecessor is the L0 level (a direct driver call has no
/// Entry): authoritative reload, then deliver the result.
inline fn resumeAtL0(vm: *Vm, value: JSValue) Outcome {
    const regs = reloadAfterPop(vm, null);
    vm.stack.pushOwnedAssumeCapacity(value);
    return @call(.always_tail, next, .{ regs.pc, regs.sp + 1, regs.var_buf, vm });
}

/// In-handler return to an inline caller (qjs OP_return + the done: epilogue):
/// tear down, unlink, deliver the result into the caller's operand stack and
/// resume it. Frame ownership and the teardown choice stay behind Machine.
inline fn popAndResume(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm, value: JSValue) Outcome {
    const machine = vm.machine;
    // Every vm.frame writer publishes &machine.top.?.frame in lockstep with
    // Machine.top, so the dying Entry is derived from the register-resident
    // frame pointer (as qjs reads `sf`) instead of the machine->top chain.
    const dying: *inline_calls.Entry = @alignCast(@fieldParentPtr("frame", vm.frame));
    std.debug.assert(dying == machine.topEntry());
    // One masked test on the teardown byte decides the whole completion shape;
    // the plain case pays this single test and the special arms follow.
    if (dying.isOrdinaryReturn()) {
        machine.popOrdinaryFrame();
        const regs = reloadAfterPop(vm, machine.top);
        // AssumeCapacity never reallocs, so the reloaded sp stays valid.
        vm.stack.pushOwnedAssumeCapacity(value);
        return @call(.always_tail, next, .{ regs.pc, regs.sp + 1, regs.var_buf, vm });
    }
    // Native-boundary return (builtin callback / embedder call): hand the
    // value straight back to the driver. Two 64-bit stores, because the
    // driver reads the slot as an integer pair (`Vm.takeNativeReturnInto`).
    if (dying.isNativeBoundaryReturn()) {
        machine.popReturnedNativeBoundary(vm.rt);
        storeValueAsIntPair(&vm.return_value, value);
        return .native_returned;
    }
    if (dying.isEmptyLeaf()) {
        // No operand-window guard: empty-leaf publication requires the static
        // return-balance proof (`codeProvesLeafReturnBalance`), so every
        // return of a published body leaves an empty callee window. The
        // resume {pc, sp} is read first so the dispatch chain starts while
        // the teardown and field publication run beside it.
        const resume_pc = dying.emptyLeafResumePc();
        const resume_sp = dying.emptyLeafResumeSp();
        const caller_opt = dying.prev;
        machine.popReturnedEmptyLeaf(vm.rt);
        if (caller_opt) |caller| {
            // Flat caller republication: the same fields reloadAfterPop's
            // entry arm publishes, with pc/sp taken from the resume record.
            std.debug.assert(caller == machine.top.?);
            std.debug.assert(resume_pc == caller.frame.function.byteCodeAssumeMaterialized().ptr + caller.frame.pc);
            std.debug.assert(resume_sp == caller.stack.topPtr());
            const caller_vb = republishCaller(vm, caller);
            resume_sp[0] = value;
            caller.stack.setTopPtr(resume_sp + 1);
            return @call(.always_tail, next, .{ resume_pc, resume_sp + 1, caller_vb, vm });
        }
        // L0 caller: authoritative reload (stop-boundary republication).
        return resumeAtL0(vm, value);
    }
    if (dying.isExactArgsLeaf() and dying.stack.len() == 0) {
        // Exact-args leaf return: the zero-arg resume plus the caller-region
        // args release inside `popReturnedExactArgsLeaf`. The freed args sit
        // above the delivered result, so release and store touch disjoint slots.
        //
        // The len==0 guard is the leaf form of qjs's done: release-loop entry:
        // the parser elides trailing expression-statement drops and leaves
        // switch discriminants on the operand stack at `return`, so a return
        // may carry live operands; those take the general path below, which
        // releases the remaining window exactly once. This family keeps a
        // RUNTIME guard (unlike the empty-leaf arm's static proof) because
        // bodies with args/captures must stay leaf-eligible with leftovers.
        const resume_pc = dying.emptyLeafResumePc();
        const resume_sp = dying.emptyLeafResumeSp();
        const caller_opt = dying.prev;
        const return_action = dying.return_action;
        std.debug.assert(return_action == .next or return_action == .to_boolean);
        const delivered_value = if (return_action == .to_boolean) blk: {
            @branchHint(.unlikely);
            const boolean = JSValue.boolean(coercion_ops.valueTruthy(value));
            break :blk boolean;
        } else value;
        machine.popReturnedExactArgsLeaf(vm.rt);
        if (caller_opt) |caller| {
            // Direct calls from the L0 driver have no Entry predecessor; keep
            // that leg linear into result delivery.
            @branchHint(.unlikely);
            std.debug.assert(caller == machine.top.?);
            std.debug.assert(resume_pc == caller.frame.function.byteCodeAssumeMaterialized().ptr + caller.frame.pc);
            std.debug.assert(resume_sp == caller.stack.topPtr());
            const caller_vb = republishCaller(vm, caller);
            resume_sp[0] = delivered_value;
            caller.stack.setTopPtr(resume_sp + 1);
            return @call(.always_tail, next, .{ resume_pc, resume_sp + 1, caller_vb, vm });
        }
        return resumeAtL0(vm, delivered_value);
    }
    if (dying.isForwardedLeaf() and dying.stack.len() == 0) {
        // Forwarded-leaf return (`f.call(...)` / `f.apply(...)` on a same-Realm
        // bytecode `f`). No resume record exists: its slot holds the skipped
        // native record for the backtrace, so resume {pc, sp} is re-derived
        // through `prev` as `reloadAfterPop` does. Same len==0 guard as the
        // exact-args arm. Duplicated in `op_return_slow` for driver-side entries.
        const caller_opt = dying.prev;
        machine.popReturnedForwardedLeaf(vm.rt);
        if (caller_opt) |caller| {
            std.debug.assert(caller == machine.top.?);
            const resume_pc = caller.frame.function.byteCodeAssumeMaterialized().ptr + caller.frame.pc;
            const resume_sp = caller.stack.topPtr();
            const caller_vb = republishCaller(vm, caller);
            // The retired receiver slot at the caller's top is dead (moved into
            // the callee frame at push): the result lands there.
            resume_sp[0] = value;
            caller.stack.setTopPtr(resume_sp + 1);
            return @call(.always_tail, next, .{ resume_pc, resume_sp + 1, caller_vb, vm });
        }
        return resumeAtL0(vm, value);
    }
    // Remaining (cold, larger) completion shapes: carry the result through the
    // frame's guaranteed stack_size + 1 scratch slot and tail into one shared
    // body. The exported slot stops LLVM folding it back into both return handlers.
    storeValueAsIntPair(&sp[0], value);
    return @call(.always_tail, Opaque(op_return_slow).get(), .{ pc, sp + 1, var_buf, vm });
}

/// Shared completion tail for special, constructor, and general frames. The
/// caller has already ruled out ordinary and hot leaf shapes and placed the
/// owned result in the otherwise-dead extra operand slot.
fn op_return_slow(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    _ = pc;
    _ = var_buf;
    std.debug.assert(@intFromPtr(sp) > @intFromPtr(vm.stack.values));
    const result_sp = sp - 1;
    const value = loadValueAsIntPair(&result_sp[0]);
    vm.syncSp(result_sp);

    const machine = vm.machine;
    const dying: *inline_calls.Entry = @alignCast(@fieldParentPtr("frame", vm.frame));
    std.debug.assert(dying == machine.topEntry());

    if (dying.hasSpecialReturn()) {
        if (dying.return_action == .async_complete) {
            const id = dying.continuation_payload;
            machine.async_completions.at(id).value = value;
            _ = machine.popReturnedFrame();
            const regs = reloadAfterPop(vm, machine.top);
            const promise = machine.completeAsync(id, false) catch |err| {
                if (!callSetupRecover(vm, err)) return .threw;
                return coldNext(regs.var_buf, vm);
            };
            vm.stack.pushOwnedAssumeCapacity(promise);
            return coldNext(regs.var_buf, vm);
        }
        if (dying.isNativeBoundaryReturn()) {
            machine.popReturnedNativeBoundary(vm.rt);
            storeValueAsIntPair(&vm.return_value, value);
            return .native_returned;
        }
        if (dying.isForwardedLeaf() and dying.stack.len() == 0) {
            // Forwarded-leaf return for driver-side entries; see the
            // identical arm in `popAndResume`.
            const caller_opt = dying.prev;
            machine.popReturnedForwardedLeaf(vm.rt);
            if (caller_opt) |caller| {
                std.debug.assert(caller == machine.top.?);
                const resume_pc = caller.frame.function.byteCodeAssumeMaterialized().ptr + caller.frame.pc;
                const resume_sp = caller.stack.topPtr();
                const caller_vb = republishCaller(vm, caller);
                resume_sp[0] = value;
                caller.stack.setTopPtr(resume_sp + 1);
                return @call(.always_tail, next, .{ resume_pc, resume_sp + 1, caller_vb, vm });
            }
            return resumeAtL0(vm, value);
        }
    }
    if (dying.completesConstructor()) {
        const completed = machine.popConstructorReturn(value);
        const regs = reloadAfterPop(vm, machine.top);
        vm.stack.pushOwnedAssumeCapacity(completed);
        return @call(.always_tail, next, .{ regs.pc, regs.sp + 1, regs.var_buf, vm });
    }
    var continuation = machine.popReturnedFrame();
    // popFrame installed the caller (qjs `sf->prev_frame`) in Machine.top;
    // null already names L0.
    const regs = reloadAfterPop(vm, machine.top);
    if (continuation.action == .next) {
        std.debug.assert(continuation.payload == 0);
        vm.stack.pushOwnedAssumeCapacity(value);
        return @call(.always_tail, next, .{ regs.pc, regs.sp + 1, regs.var_buf, vm });
    }
    vm.return_value = value;
    vm.return_action = continuation.action;
    vm.return_payload = continuation.payload;
    continuation.action = .next;
    continuation.payload = 0;
    return @call(.always_tail, op_post_call_continuation, .{ regs.pc, regs.sp, regs.var_buf, vm });
}

/// Lean native-boundary return (`inline_calls.LeanFrame`): arena restore,
/// budget release, unlink and the two-word result hand-off. `op_return` /
/// `op_return_undef` test for it BEFORE tailing into their general body, so
/// both keep an empty prologue (the general body is an exported tail slot
/// with its own callee-saved set).
inline fn returnLeanTail(vm: *Vm, dying: *inline_calls.Entry, result_sp: [*]JSValue, value: JSValue) Outcome {
    vm.syncSp(result_sp);
    vm.machine.popReturnedLean(vm.rt, dying);
    storeValueAsIntPair(&vm.return_value, value);
    return .native_returned;
}

/// Shared general body of `op_return`: everything that is not a lean
/// native-boundary return. Reached through an exported Handler slot so the
/// two hot return opcodes carry only the lean decision.
fn op_return_general(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) linksection(op_handler_section_tail) callconv(.c) Outcome {
    const result_sp = sp - 1;
    const value = loadValueAsSplitPair(&result_sp[0]);
    vm.syncSp(result_sp);
    return popAndResume(pc, result_sp, var_buf, vm, value);
}

fn op_return_undef_general(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) linksection(op_handler_section_tail) callconv(.c) Outcome {
    vm.syncSp(sp);
    return popAndResume(pc, sp, var_buf, vm, JSValue.undefinedValue());
}

/// I-cache pinned (align 64): every call's return rides this handler and its
/// entry alignment must not drift when neighbouring bodies change size.
fn op_return(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
    // qjs OP_return is check-free (`ret_val = *--sp; goto done`): derived-ctor
    // legality is OP_check_ctor_return, emitted before this opcode, and the
    // depth-0/generator hand-off lives at the driver boundary.
    if (vm.machine.depth == 0)
        return @call(.always_tail, Opaque(op_return_depth0).get(), .{ pc, sp, var_buf, vm });
    // Valid `return` bytecode always has one result (valueless returns use
    // `return_undef`); Debug checks that contract instead of production code.
    std.debug.assert(@intFromPtr(sp) > @intFromPtr(vm.stack.values));
    const dying: *inline_calls.Entry = @alignCast(@fieldParentPtr("frame", vm.frame));
    std.debug.assert(dying == vm.machine.topEntry());
    if (!dying.isLeanBoundaryReturn())
        return @call(.always_tail, Opaque(op_return_general).get(), .{ pc, sp, var_buf, vm });
    const result_sp = sp - 1;
    return returnLeanTail(vm, dying, result_sp, loadValueAsSplitPair(&result_sp[0]));
}
/// Depth-0 sibling of op_return: finish the optional generator, publish the
/// value, and return to the driver. Reached through an exported Handler slot
/// so LLVM cannot fold this error-union path into the hot handler.
fn op_return_depth0(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    _ = var_buf;
    vm.publish(pc, sp);
    const value = vm_control.returnTop(vm) catch |e| return vm.fail(e);
    vm.return_value = value;
    return .returned; // L0 exit stays on the driver
}
/// Pinned with op_return (same rationale); same split as op_return.
fn op_return_undef(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
    if (vm.machine.depth == 0)
        return @call(.always_tail, Opaque(op_return_undef_depth0).get(), .{ pc, sp, var_buf, vm });

    const dying: *inline_calls.Entry = @alignCast(@fieldParentPtr("frame", vm.frame));
    std.debug.assert(dying == vm.machine.topEntry());
    if (!dying.isLeanBoundaryReturn())
        return @call(.always_tail, Opaque(op_return_undef_general).get(), .{ pc, sp, var_buf, vm });
    return returnLeanTail(vm, dying, sp, JSValue.undefinedValue());
}
/// Depth-0 sibling of op_return_undef (see op_return_depth0).
fn op_return_undef_depth0(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    _ = var_buf;
    vm.publish(pc, sp);
    const value = vm_control.returnUndefined(vm.ctx, vm.frame, vm.machine.l0.generator_state) catch |e| return vm.fail(e);
    vm.return_value = value;
    return .returned;
}

const CallArgcSource = enum { operand, zero, one, two, three };

/// `f(...)` where `f` resolved to a same-Machine bytecode function: enter it
/// in-handler through the empty-leaf / capture-leaf / exact-args / generic
/// constructors. Arm order is a single test per miss: the sloppy bit, then the
/// raw-`this` bit (strict plain functions and arrows, whose bytecode reads
/// lexical this/new.target through closure cells), then the capture kind, then
/// the exact-args kind before the arity compare, so padded (`argc <
/// arg_count`) siblings fall through to the generic constructor.
inline fn callBytecodeCallee(
    comptime argc_source: CallArgcSource,
    pc: [*]const u8,
    var_buf: [*]JSValue,
    vm: *Vm,
    resolved: *const inline_calls.ResolvedInlineFunction,
    func: JSValue,
    sp: [*]JSValue,
    region_start: [*]JSValue,
    argc: u16,
) Outcome {
    const insn_len: usize = if (argc_source == .operand) 3 else 1;
    vm.stack.retreatToCallRegionFrom(&vm.machine.pending_call_region, sp, region_start);
    const execution = resolved.call_facts.execution;
    if (argc == 0 and execution.simple_inline_empty_leaf) {
        if (comptime argc_source == .zero) {
            return pushWarmEmptyLeafAndEnter(.sloppy_global, var_buf, vm, resolved.fb, resolved.call_facts, region_start, pc + insn_len, resolved.fb.byteCode().ptr);
        }
        return pushEmptyLeafAndEnter(.sloppy_global, var_buf, vm, resolved.fb, resolved.call_facts, region_start, resolved.fb.byteCode().ptr);
    }
    // Raw-`this` twin: strict plain functions and arrows (arrow
    // bytecode reads lexical this/new.target through closure
    // cells, so the frame keeps the raw undefined word).
    // Tested after the sloppy bit so that arm keeps a single test.
    if (argc == 0 and execution.raw_this_inline_empty_leaf) {
        if (comptime argc_source == .zero) {
            return pushWarmEmptyLeafAndEnter(.raw_undefined, var_buf, vm, resolved.fb, resolved.call_facts, region_start, pc + insn_len, resolved.fb.byteCode().ptr);
        }
        return pushEmptyLeafAndEnter(.raw_undefined, var_buf, vm, resolved.fb, resolved.call_facts, region_start, resolved.fb.byteCode().ptr);
    }
    // Capture-leaf arms: zero-arg callees whose only frame
    // window is the inherited capture array. Raw-`this`
    // (arrow) keeps the warm inline body; the sloppy twin
    // calls the outline warm constructor so a second inline
    // body cannot disturb the neighbouring arms.
    if (argc == 0) {
        const capture_kind = execution.capture_leaf_kind;
        if (capture_kind != .none) {
            const captures = resolved.var_refs[0..resolved.fb.closureVarCount()];
            if (comptime argc_source == .zero) {
                if (capture_kind == .raw_this) {
                    return pushWarmCaptureLeafAndEnter(.raw_undefined, var_buf, vm, resolved.fb, resolved.call_facts, captures, region_start, pc + insn_len, resolved.fb.byteCode().ptr);
                }
                return pushWarmOutlineCaptureLeafAndEnter(.sloppy_global, var_buf, vm, resolved.fb, resolved.call_facts, captures, region_start, pc + insn_len, resolved.fb.byteCode().ptr);
            }
            if (capture_kind == .raw_this) {
                return pushCaptureLeafAndEnter(.raw_undefined, var_buf, vm, resolved.fb, resolved.call_facts, captures, region_start, resolved.fb.byteCode().ptr);
            }
            return pushCaptureLeafAndEnter(.sloppy_global, var_buf, vm, resolved.fb, resolved.call_facts, captures, region_start, resolved.fb.byteCode().ptr);
        }
    }
    // Exact-args leaf arms, fixed nonzero arity only (fib's
    // call1, add(a,b)'s call2). Kind byte first so a leaf miss
    // fails one test; arity second so padded (`argc <
    // arg_count`) siblings fall through. Sloppy keeps the warm
    // inline body, raw calls the outline warm constructor.
    const wire_exact_args_leaf = comptime switch (argc_source) {
        .one, .two, .three => true,
        .operand, .zero => false,
    };
    if (wire_exact_args_leaf) {
        const leaf_kind = execution.exact_args_leaf_kind;
        if (leaf_kind != .none) {
            if (argc == resolved.fb.arg_count) {
                if (leaf_kind == .sloppy) {
                    return pushWarmExactArgsLeafAndEnter(.sloppy_global, .next, var_buf, vm, resolved.fb, resolved.call_facts, resolved.var_refs[0..resolved.fb.closureVarCount()], region_start, argc, pc + insn_len, resolved.fb.byteCode().ptr);
                }
                return pushWarmOutlineExactArgsLeafAndEnter(.raw_undefined, var_buf, vm, resolved.fb, resolved.call_facts, resolved.var_refs[0..resolved.fb.closureVarCount()], region_start, argc, pc + insn_len, resolved.fb.byteCode().ptr);
            }
        }
    }
    // Padded (`argc < arg_count`) shapes take the generic
    // constructor, which pads through `setupSimpleInlineEntry`.
    const target = resolved.bind(JSValue.undefinedValue(), func);
    return pushAndEnter(var_buf, vm, &target, region_start, argc, .plain);
}

/// qjs gives OP_call and OP_call0..3 distinct CASE labels; one comptime body
/// per arity keeps the fixed forms from re-decoding their opcode. Only argc
/// and the pc advance specialize.
fn opCall(comptime argc_source: CallArgcSource) Handler {
    return struct {
        // I-cache pin (see op_return).
        fn handler(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
            const argc: u16 = switch (argc_source) {
                .operand => readInt(u16, pc + 1),
                .zero => 0,
                .one => 1,
                .two => 2,
                .three => 3,
            };
            const insn_len: usize = if (argc_source == .operand) 3 else 1;
            vm.syncPc(pc, insn_len);
            // Bytecode-to-bytecode calls resolve and complete in the handler
            // (qjs CASE(OP_call)); a miss (host fn / ctor / cross-realm /
            // underflow) falls to execCall with allow_inline=false.
            const total = @as(usize, argc) + 1;
            const live_bytes = @intFromPtr(sp) - @intFromPtr(vm.stack.values);
            if (live_bytes >= total * @sizeOf(JSValue)) {
                const region_start = sp - total;
                const func = region_start[0];
                // One objectFromValue, then branch on class_id.
                const func_obj_opt = object_ops.objectFromValue(func);
                const resolved_opt: ?inline_calls.ResolvedInlineFunction = if (func_obj_opt) |o|
                    (if (o.class_id == core.class.ids.bytecode_function) inline_calls.resolveInlineFunctionFromObject(vm.global, o) else null)
                else
                    null;
                if (resolved_opt) |resolved| {
                    return callBytecodeCallee(argc_source, pc, var_buf, vm, &resolved, func, sp, region_start, argc);
                }
                // Native callee arm (mirrors op_call_method's c_function arm):
                // resolve the record and dispatch directly; misses continue below.
                if (func_obj_opt) |func_obj| {
                    if (func_obj.class_id == core.class.ids.c_function) {
                        // Leaf entries run right here: no dispatcher call,
                        // realm, frame or environment.
                        if (func_obj.nativeCallTargetAssumeCFunction()) |target| {
                            const entry = target.entry;
                            const args: []const JSValue = region_start[1..][0..argc];
                            if (entry.kind == .leaf) {
                                if (builtin_dispatch.invokeLeafFastEntry(entry, args)) |value| {
                                    storeValueAsIntPair(&region_start[0], value);
                                    return @call(.always_tail, next, .{ pc + insn_len, region_start + 1, var_buf, vm });
                                }
                            } else if (vm_native.managedInlineEligible(vm.rt, entry)) {
                                // Managed entry without an environment: one
                                // call from the handler (qjs js_call_c_function).
                                vm.stack.setTopPtr(sp);
                                const value = builtin_dispatch.callManagedFromWindow(vm.rt, target.realm, entry, func_obj, JSValue.undefinedValue(), args);
                                return managedInlineFinish(vm, value, region_start, pc + insn_len, var_buf);
                            }
                        }
                        vm.stack.setTopPtr(sp);
                        switch (vm_native.dispatchNativeCall(vm, func_obj, argc, .plain) catch |e| return vm.fail(e)) {
                            .hit => return nativeHitNext(var_buf, vm),
                            .caught => return coldNext(var_buf, vm),
                            .miss => {},
                        }
                    } else if (func_obj.class_id == core.class.ids.async_function) {
                        return @call(.always_tail, async_call_handlers.get(@intFromEnum(argc_source)), .{ pc, sp, var_buf, vm });
                    }
                }
            }
            vm.stack.setTopPtr(sp);
            switch (call_runtime.execCall(vm.ctx, vm.stack, vm.function, vm.frame, vm.catch_target, argc, vm.output, vm.global, false, &vm.tail_request) catch |e| return vm.fail(e)) {
                .done, .continue_loop => return coldNext(var_buf, vm),
                .inline_call => {
                    vm.tail_mode = .push;
                    return .tail;
                },
            }
        }
    }.handler;
}

/// Scope publication precedes allocation, and operand ownership changes only
/// once the Promise/boundary are rooted. No user code is replayed on failure.
inline fn enterNoSuspendAsync(vm: *Vm, var_buf: [*]JSValue, sp: [*]JSValue, region: [*]JSValue, argc: u16, comptime layout: inline_calls.RegionLayout, resolved: inline_calls.InlineTarget) Outcome {
    vm.stack.setTopPtr(sp);
    exception_ops.pollInterrupt(vm.ctx, vm.global) catch |err| {
        if (!callSetupRecover(vm, err)) return .threw;
        return coldNext(var_buf, vm);
    };
    const store = &vm.machine.async_completions;
    const id = store.begin(vm.rt, resolved.callable) catch |err| {
        if (!callSetupRecover(vm, err)) return .threw;
        return coldNext(var_buf, vm);
    };
    const boundary = store.at(id);
    boundary.promise = core.promise.constructWithPrototype(vm.ctx, @import("promise_ops.zig").promisePrototypeFromGlobal(vm.rt, vm.global)) catch |err| {
        store.release(id);
        if (!callSetupRecover(vm, err)) return .threw;
        return coldNext(var_buf, vm);
    };
    var target = resolved;
    if (layout == .method) target.this_value = region[0];
    vm.stack.retreatToCallRegionFrom(&vm.machine.pending_call_region, sp, region);
    const entry = vm.machine.pushAsyncMovedCall(&target, region[0 .. @as(usize, argc) + (if (layout == .method) @as(usize, 2) else 1)], layout, id) catch |err| {
        store.release(id);
        if (!callSetupRecover(vm, err)) return .threw;
        return coldNext(var_buf, vm);
    };
    return enterEntry(vm, entry, target.fb.byteCode().ptr);
}

/// Async setup owns many more native temporaries than ordinary call dispatch;
/// it sits behind its own tail handler so opCall's frame does not inherit them.
fn opAsyncCall(comptime argc_source: CallArgcSource) Handler {
    return struct {
        fn handler(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
            const argc: u16 = switch (argc_source) {
                .operand => readInt(u16, pc + 1),
                .zero => 0,
                .one => 1,
                .two => 2,
                .three => 3,
            };
            const region = sp - (@as(usize, argc) + 1);
            if (inline_calls.resolveNoSuspendAsync(vm.ctx, vm.global, region[0])) |target|
                return enterNoSuspendAsync(vm, var_buf, sp, region, argc, .plain, target);
            // opCall already advanced the caller PC and proved the operands.
            vm.stack.setTopPtr(sp);
            switch (call_runtime.execCall(vm.ctx, vm.stack, vm.function, vm.frame, vm.catch_target, argc, vm.output, vm.global, false, &vm.tail_request) catch |err| return vm.fail(err)) {
                .done, .continue_loop => return coldNext(var_buf, vm),
                .inline_call => {
                    vm.tail_mode = .push;
                    return .tail;
                },
            }
        }
    }.handler;
}

fn op_async_call_method(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    const argc = readInt(u16, pc + 1);
    const region = sp - (@as(usize, argc) + 2);
    if (inline_calls.resolveNoSuspendAsync(vm.ctx, vm.global, region[1])) |target| {
        vm.frame.pc += 2;
        return enterNoSuspendAsync(vm, var_buf, sp, region, argc, .method, target);
    }
    // On a miss the method PC still points to argc, as callMethod requires.
    vm.stack.setTopPtr(sp);
    switch (vm_call.callMethod(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, false, &vm.tail_request) catch |err| return vm.fail(err)) {
        .done, .continue_loop => return coldNext(var_buf, vm),
        .inline_call => {
            vm.tail_mode = .push;
            return .tail;
        },
        .inline_constructor => unreachable,
    }
}

/// Opaque slots (see `Opaque`) for the five async-call arity forms.
const async_call_handlers = struct {
    var table: [5]Handler = .{
        opAsyncCall(.operand), opAsyncCall(.zero),  opAsyncCall(.one),
        opAsyncCall(.two),     opAsyncCall(.three),
    };
    inline fn get(index: usize) Handler {
        const p: *volatile [5]Handler = &table;
        return p[index];
    }
};

const op_call = opCall(.operand);
const op_call0 = opCall(.zero);
const op_call1 = opCall(.one);
const op_call2 = opCall(.two);
const op_call3 = opCall(.three);

fn op_apply(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    vm.publish(pc, sp);
    switch (vm_call.apply(
        vm.ctx,
        vm.output,
        vm.global,
        vm.stack,
        vm.function,
        vm.frame,
        vm.catch_target,
        &vm.tail_request,
    ) catch |e| return vm.fail(e)) {
        .done, .continue_loop => return coldNext(var_buf, vm),
        .inline_call => {
            vm.tail_mode = .push;
            return .tail;
        },
        .inline_constructor => {
            const req = &vm.tail_request;
            const region_start = vm.stack.values + req.region_base;
            const func = region_start[0];
            const new_target = region_start[1];
            if (call_runtime.resolveSameMachineSpreadConstructor(vm.global, func, new_target)) |candidate| {
                const entered = enterSameMachineSpreadConstructor(
                    vm,
                    req.region_base,
                    req.argc,
                    &candidate,
                );
                return switch (entered) {
                    .entry => |entry| enterEntry(
                        vm,
                        entry,
                        candidate.resolved.fb.byteCodeAssumeMaterialized().ptr,
                    ),
                    .caught => coldNext(var_buf, vm),
                    .threw => .threw,
                };
            }

            // Defensive: admission is decided from immutable facts before the
            // operand transaction commits. The materialized region still
            // enters the authoritative constructor without the spread array.
            const args = (region_start + 2)[0..req.argc];
            const result = call_runtime.constructValueOrBytecodeWithNewTarget(
                vm.ctx,
                vm.output,
                vm.global,
                func,
                args,
                vm.function,
                vm.frame,
                new_target,
            ) catch |err| {
                if (!constructorRegionRecover(vm, req.region_base, err)) return .threw;
                return coldNext(var_buf, vm);
            };
            call_runtime.popOwnedStackRegion(vm.stack, req.region_base);
            vm.stack.pushOwnedAssumeCapacity(result);
            return coldNext(var_buf, vm);
        },
    }
}

/// I-cache pinned (see op_return).
fn op_call_method(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
    vm.syncPc(pc, 1); // frame.pc now at the argc:u16 operand
    const argc = readInt(u16, pc + 1);
    // Region is [receiver, callable, args...]; the receiver becomes the
    // callee's `this`. On a HIT frame.pc advances past the operand; on a MISS
    // it stays AT the operand so callMethod's own decode reads it.
    const total = @as(usize, argc) + 2;
    const live_bytes = @intFromPtr(sp) - @intFromPtr(vm.stack.values);
    if (live_bytes >= total * @sizeOf(JSValue)) {
        const region_start = sp - total;
        const receiver = loadValueAsIntPair(&region_start[0]);
        const method = region_start[1];
        // One objectFromValue, then branch on class_id. `method` is an
        // evaluated expression, so compiler stack discipline excludes the
        // internal VarRef wrapper sharing the object tag (Debug checks it).
        if (object_ops.objectFromValueTrustedExpression(method)) |method_obj| {
            if (method_obj.class_id == core.class.ids.bytecode_function) {
                if (inline_calls.resolveInlineFunctionFromObject(vm.global, method_obj)) |resolved| {
                    return callBytecodeMethod(pc, sp, var_buf, vm, &resolved, receiver, method, region_start, argc);
                }
            } else if (method_obj.class_id == core.class.ids.c_function) {
                // Arm order: the two typed-leaf kinds, then the forwarding bit,
                // then the two managed-inline predicates. `rec` must not stay
                // live across the vm_native.dispatch call (it re-resolves).
                if (vm_call.resolvedNativeMethodRecordAssumeCFunction(vm.ctx, method_obj)) |rec| {
                    if (rec.kind == .leaf) {
                        // Leaf arm, method form (`Math.abs(x)`).
                        const region_base_ptr = sp - (@as(usize, argc) + 2);
                        const args: []const JSValue = region_base_ptr[2..][0..argc];
                        if (builtin_dispatch.invokeLeafFastEntry(rec, args)) |value| {
                            storeValueAsIntPair(&region_base_ptr[0], value);
                            return @call(.always_tail, next, .{ pc + 3, region_base_ptr + 1, var_buf, vm });
                        }
                    } else if (rec.kind == .method_leaf) {
                        // Primitive-receiver leaf (`str.charCodeAt(i)`): the
                        // window receiver is `this`; body outlined for size.
                        const region_base_ptr = sp - (@as(usize, argc) + 2);
                        if (builtin_dispatch.invokeMethodLeafFastEntry(vm.ctx, rec, region_base_ptr[0], region_base_ptr[2..][0..argc])) |value| {
                            storeValueAsIntPair(&region_base_ptr[0], value);
                            return @call(.always_tail, next, .{ pc + 3, region_base_ptr + 1, var_buf, vm });
                        }
                    } else if (rec.flags.forwards_call) {
                        // Window-rewrite arms: `f.call(...)` / `f.apply(...)`
                        // on a same-Realm bytecode `f` become a bytecode
                        // method call on `f` itself (no native frame). The two
                        // entries are told apart by target identity (qjs
                        // compares the C function pointer); other shapes leave
                        // the window untouched for the generic path. A
                        // forwarding entry is always `.managed`, so it is
                        // tested before the managed predicates that reject it.
                        const forwarded = if (rec.target == function_ops.call_entry_target)
                            pushForwardedCallEntry(vm, region_start, argc)
                        else if (rec.target == function_ops.apply_entry_target)
                            pushForwardedApplyEntry(vm, sp, region_start, argc)
                        else
                            ForwardedEntryResult.generic;
                        switch (forwarded) {
                            .entry => |pushed| return enterEntry(vm, pushed.entry, pushed.code_ptr),
                            .caught => return coldNext(var_buf, vm),
                            .threw => return .threw,
                            .generic => {},
                        }
                    } else if (vm_native.managedInlineEligible(vm.rt, rec)) {
                        // Managed arm, method form (`console.log(x)`).
                        if (method_obj.nativeCallTargetAssumeCFunction()) |target| {
                            const region_base_ptr = sp - (@as(usize, argc) + 2);
                            vm.frame.pc += 2; // argc, as dispatch does
                            vm.stack.setTopPtr(sp);
                            const value = builtin_dispatch.callManagedFromWindow(vm.rt, target.realm, rec, method_obj, loadValueAsIntPair(&region_base_ptr[0]), region_base_ptr[2..][0..argc]);
                            return managedInlineFinish(vm, value, region_base_ptr, pc + 3, var_buf);
                        }
                    } else if (vm_native.methodManagedInlineEligible(vm.rt, rec)) {
                        // Managed native-class method (`world.query(i)`):
                        // receiver class check + `self` unwrap here; a foreign
                        // or disposed receiver takes the dispatcher's TypeError.
                        const region_base_ptr = sp - (@as(usize, argc) + 2);
                        const this_value = loadValueAsIntPair(&region_base_ptr[0]);
                        if (builtin_dispatch.nativeReceiverSelf(this_value, rec)) |self_ptr| {
                            if (method_obj.nativeCallTargetAssumeCFunction()) |target| {
                                vm.frame.pc += 2;
                                vm.stack.setTopPtr(sp);
                                const value = builtin_dispatch.callMethodManagedFromWindow(vm.rt, target.realm, rec, method_obj, self_ptr, this_value, region_base_ptr[2..][0..argc]);
                                return managedInlineFinish(vm, value, region_base_ptr, pc + 3, var_buf);
                            }
                        }
                    }
                    if (!rec.flags.forwards_call) {
                        vm.stack.setTopPtr(sp);
                        switch (vm_native.dispatchNativeCall(vm, method_obj, argc, .method) catch |e| return vm.fail(e)) {
                            .hit => return nativeHitNext(var_buf, vm),
                            .caught => return coldNext(var_buf, vm),
                            .miss => {},
                        }
                    }
                }
            } else if (method_obj.class_id == core.class.ids.async_function) {
                return @call(.always_tail, Opaque(op_async_call_method).get(), .{ pc, sp, var_buf, vm });
            }
        }
    }
    vm.stack.setTopPtr(sp);
    switch (vm_call.callMethod(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, false, &vm.tail_request) catch |e| return vm.fail(e)) {
        .done, .continue_loop => return coldNext(var_buf, vm),
        .inline_call => {
            vm.tail_mode = .push;
            return .tail;
        },
        .inline_constructor => unreachable,
    }
}

/// `recv.m(...)` where `m` resolved to a same-Machine bytecode function:
/// enter it in-handler through the leaf / exact-args / generic constructors,
/// in the same order and with the same warm/outline split as `opCall`.
inline fn callBytecodeMethod(
    pc: [*]const u8,
    sp: [*]JSValue,
    var_buf: [*]JSValue,
    vm: *Vm,
    resolved: *const inline_calls.ResolvedInlineFunction,
    receiver: JSValue,
    method: JSValue,
    region_start: [*]JSValue,
    argc: u16,
) Outcome {
    vm.frame.pc += 2;
    vm.stack.retreatToCallRegionFrom(&vm.machine.pending_call_region, sp, region_start);
    const execution = resolved.call_facts.execution;
    // Method twin of the OP_call0 empty-leaf warm arm; the receiver becomes
    // the frame's raw `this` and `pc + 3` (opcode + argc:u16) is the resume pc.
    if (argc == 0 and execution.simple_inline_empty_leaf) {
        return pushWarmEmptyLeafAndEnter(.receiver, var_buf, vm, resolved.fb, resolved.call_facts, region_start, pc + 3, resolved.fb.byteCode().ptr);
    }
    // Strict methods and arrow-valued properties: the raw receiver transfers
    // verbatim (sloppy coercion is deferred to the this-reading opcodes).
    // Out-of-line constructor so a second inline body cannot tail-merge with
    // the first.
    if (argc == 0 and execution.raw_this_inline_empty_leaf) {
        return pushEmptyLeafAndEnter(.receiver, var_buf, vm, resolved.fb, resolved.call_facts, region_start, resolved.fb.byteCode().ptr);
    }
    // Capture-leaf method twin (`recv.cb()` over captured state).
    if (argc == 0 and execution.capture_leaf_kind != .none) {
        return pushCaptureLeafAndEnter(.receiver, var_buf, vm, resolved.fb, resolved.call_facts, resolved.var_refs[0..resolved.fb.closureVarCount()], region_start, resolved.fb.byteCode().ptr);
    }
    // Exact-args method arms (`recv.m(x)` on a published leaf); same
    // warm/outline split and test order as the opCall arm. Padded siblings
    // fall through to the generic constructor.
    const leaf_kind = execution.exact_args_leaf_kind;
    if (leaf_kind != .none) {
        if (argc == resolved.fb.arg_count) {
            if (leaf_kind == .sloppy) {
                return pushWarmExactArgsLeafAndEnter(.receiver, .next, var_buf, vm, resolved.fb, resolved.call_facts, resolved.var_refs[0..resolved.fb.closureVarCount()], region_start, argc, pc + 3, resolved.fb.byteCode().ptr);
            }
            return pushExactArgsLeafAndEnter(.receiver, .next, var_buf, vm, resolved.fb, resolved.call_facts, resolved.var_refs[0..resolved.fb.closureVarCount()], region_start, argc, resolved.fb.byteCode().ptr);
        }
    }
    const target = resolved.bind(receiver, method);
    return pushAndEnter(var_buf, vm, &target, region_start, argc, .method);
}

/// Same-Realm direct derived bytecode construction in the active Machine
/// (general [[Construct]] policy stays authoritative for base classes, proxy,
/// bound, native, cross-Realm and differing-new-target cases). Outlined so the
/// ordinary constructor handler keeps its shape. No instance-creation phase,
/// but the same two qjs interrupt polls: JS_CallConstructorInternal entry,
/// then JS_CallInternal bytecode entry before stack preflight.
noinline fn pushDerivedConstructorEntry(
    vm: *Vm,
    region_base: usize,
    region_start: [*]JSValue,
    func: JSValue,
    candidate: *const call_runtime.SameMachineConstructorTarget,
    argc: u16,
) PushResult {
    exception_ops.pollInterrupt(vm.ctx, vm.global) catch |err| {
        if (!constructorRegionRecover(vm, region_base, err)) return .threw;
        return .caught;
    };
    const interrupt_global = vm.ctx.global orelse vm.global;
    exception_ops.pollInterrupt(vm.ctx, interrupt_global) catch |err| {
        if (!constructorRegionRecover(vm, region_base, err)) return .threw;
        return .caught;
    };

    vm.frame.pc += 2;
    const constructor_this = JSValue.uninitialized();
    region_start[0] = constructor_this;
    const target = candidate.resolved.bind(constructor_this, func);
    vm.stack.retreatToCallRegion(&vm.machine.pending_call_region, region_start);
    const entry = vm.machine.pushDerivedConstructorCall(
        vm.global,
        vm.stack,
        &target,
        region_start,
        argc,
        null,
    ) catch |err| {
        if (!constructorSetupRecover(vm, err)) return .threw;
        return .caught;
    };
    return .{ .entry = entry };
}

/// Derived spread preserves an independently-owned new.target and has already
/// advanced OP_apply's operand before reaching this adapter.
noinline fn pushSpreadDerivedConstructorEntry(
    vm: *Vm,
    region_base: usize,
    region_start: [*]JSValue,
    func: JSValue,
    candidate: *const call_runtime.SameMachineConstructorTarget,
    argc: u16,
) PushResult {
    exception_ops.pollInterrupt(vm.ctx, vm.global) catch |err| {
        if (!constructorRegionRecover(vm, region_base, err)) return .threw;
        return .caught;
    };
    const interrupt_global = vm.ctx.global orelse vm.global;
    exception_ops.pollInterrupt(vm.ctx, interrupt_global) catch |err| {
        if (!constructorRegionRecover(vm, region_base, err)) return .threw;
        return .caught;
    };

    const constructor_func = region_start[0];
    const owned_new_target = region_start[1];
    const constructor_this = JSValue.uninitialized();
    region_start[0] = constructor_this;
    region_start[1] = constructor_func;
    const target = candidate.resolved.bind(constructor_this, func);
    vm.stack.retreatToCallRegion(&vm.machine.pending_call_region, region_start);
    const entry = vm.machine.pushDerivedConstructorCall(
        vm.global,
        vm.stack,
        &target,
        region_start,
        argc,
        owned_new_target,
    ) catch |err| {
        if (!constructorSetupRecover(vm, err)) return .threw;
        return .caught;
    };
    return .{ .entry = entry };
}

/// Enter constructor spread from its committed owned
/// `[func, new_target, args...]` operand transaction.
fn enterSameMachineSpreadConstructor(
    vm: *Vm,
    region_base: usize,
    argc: u16,
    candidate: *const call_runtime.SameMachineConstructorTarget,
) PushResult {
    const region_start = vm.stack.values + region_base;
    const func = region_start[0];
    const new_target = region_start[1];
    if (candidate.resolved.fb.isDerivedClassConstructor()) {
        return pushSpreadDerivedConstructorEntry(
            vm,
            region_base,
            region_start,
            func,
            candidate,
            argc,
        );
    }

    // First JS_CallConstructorInternal poll: before instance creation,
    // constructibility effects, and the inner bytecode-call poll.
    exception_ops.pollInterrupt(vm.ctx, vm.global) catch |err| {
        if (!constructorRegionRecover(vm, region_base, err)) return .threw;
        return .caught;
    };
    const args = (region_start + 2)[0..argc];
    const prepared = call_runtime.prepareSameMachineConstructorAfterFirstPoll(
        vm.ctx,
        vm.output,
        vm.global,
        func,
        new_target,
        candidate,
        args,
        vm.function,
        vm.frame,
    ) catch |err| {
        if (!constructorRegionRecover(vm, region_base, err)) return .threw;
        return .caught;
    };
    switch (prepared) {
        .completed => |result| {
            call_runtime.popOwnedStackRegion(vm.stack, region_base);
            vm.stack.pushOwnedAssumeCapacity(result);
            return .caught;
        },
        .instance => |instance| {
            // Move both bindings out of the region: func becomes the
            // method-shaped callable, new.target moves into the callee frame.
            const constructor_func = region_start[0];
            const owned_new_target = region_start[1];
            region_start[0] = instance;
            region_start[1] = constructor_func;
            const target = candidate.resolved.bind(instance, func);
            vm.stack.retreatToCallRegion(&vm.machine.pending_call_region, region_start);
            const entry = vm.machine.pushConstructorCall(
                vm.global,
                vm.stack,
                &target,
                region_start,
                argc,
                owned_new_target,
            ) catch |err| {
                if (!constructorSetupRecover(vm, err)) return .threw;
                return .caught;
            };
            return .{ .entry = entry };
        },
    }
}

/// Enter a specialized constructor site's inline window: the CALLER's own
/// bytecode continues at `site.pc_lo` with the fresh instance and the argument
/// values installed in its frame, so no callee frame is pushed at all. The
/// operand region is dropped because ownership moved into the window.
inline fn enterInlineConstructorWindow(
    vm: *Vm,
    var_buf: [*]JSValue,
    site: *const small_inline.InlinedSite,
    instance: JSValue,
    args: []JSValue,
    region_base: usize,
) Outcome {
    small_inline.installInlineWindow(vm.frame, vm.function, site, instance, args);
    vm.stack.setLen(region_base);
    vm.frame.pc = site.pc_lo;
    const npc = vm.code_base + site.pc_lo;
    return @call(.always_tail, vm.active_dispatch_tbl[npc[0]], .{ npc, vm.stack.topPtr(), var_buf, vm });
}

/// A same-Machine [[Construct]] whose instance creation already ran: take the
/// caller's inline window when its specialized site still matches, otherwise
/// note the site as monomorphic (so a later activation can specialize it) and
/// push an ordinary constructor frame.
inline fn enterSameMachineConstruction(
    var_buf: [*]JSValue,
    vm: *Vm,
    candidate: *const call_runtime.SameMachineConstructorTarget,
    func: JSValue,
    instance: JSValue,
    call_pc: u32,
    region_base: usize,
    region_start: [*]JSValue,
    args: []JSValue,
    argc: u16,
) Outcome {
    const callee_fb = candidate.resolved.fb;
    if (small_inline.findInlinedSite(vm.function, call_pc)) |site| {
        small_inline.probe_prep += 1;
        if (site.kind == .constructor and small_inline.calleeMatches(site, func) and
            small_inline.windowFits(vm.frame, vm.function, site) and
            small_inline.applyForwardTakeOk(vm.rt, vm.global, vm.function, site, func))
        {
            small_inline.probe_take += 1;
            return enterInlineConstructorWindow(vm, var_buf, site, instance, args, region_base);
        }
    }
    if (object_ops.plainBytecodeFunctionObjectFromValue(func)) |callee_fn_obj| {
        if (small_inline.noteMonomorphic(
            vm.rt,
            @constCast(vm.function),
            call_pc,
            @constCast(callee_fb),
            callee_fn_obj,
        )) {
            if (object_ops.objectFromValue(vm.frame.current_function)) |caller_obj| {
                small_inline.specializeCallSite(
                    vm.rt,
                    caller_obj,
                    @constCast(vm.function),
                    call_pc,
                    @constCast(callee_fb),
                    callee_fn_obj,
                    .constructor,
                    argc,
                );
            }
        }
    }
    // Recast the region as method-shaped: instance into slot 0.
    region_start[0] = instance;
    const target = candidate.resolved.bind(instance, func);
    vm.stack.retreatToCallRegion(&vm.machine.pending_call_region, region_start);
    const entry = vm.machine.pushConstructorCall(
        vm.global,
        vm.stack,
        &target,
        region_start,
        argc,
        null,
    ) catch |err| {
        if (!constructorSetupRecover(vm, err)) return .threw;
        return coldNext(var_buf, vm);
    };
    return enterEntry(vm, entry, target.fb.byteCodeAssumeMaterialized().ptr);
}

fn op_call_constructor(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    vm.publish(pc, sp); // frame.pc points at the u16 argc operand
    const argc = readInt(u16, pc + 1);
    const total = @as(usize, argc) + 2;
    if (vm.stack.len() >= total) {
        const region_base = vm.stack.len() - total;
        const region_start = vm.stack.values + region_base;
        const func = region_start[0];
        const new_target = region_start[1];
        const call_pc: u32 = @intCast(@intFromPtr(pc) - @intFromPtr(vm.code_base));
        var entry_polled = false;
        // Fused create-this for a specialized site: poll first (qjs
        // JS_CallConstructorInternal entry), then skip resolve / proto lookup.
        if (small_inline.findInlinedSite(vm.function, call_pc)) |site| {
            if (site.kind == .constructor and
                small_inline.applyForwardTakeOk(vm.rt, vm.global, vm.function, site, func))
            {
                exception_ops.pollInterrupt(vm.ctx, vm.global) catch |err| {
                    if (!constructorRegionRecover(vm, region_base, err)) return .threw;
                    return coldNext(var_buf, vm);
                };
                entry_polled = true;
                if (small_inline.tryFusedConstructor(vm.rt, site, func)) |instance| {
                    const live_code = vm.function.byteCodeAssumeMaterialized();
                    if (small_inline.windowFits(vm.frame, vm.function, site) and site.pc_lo < live_code.len) {
                        small_inline.probe_prep += 1;
                        small_inline.probe_take += 1;
                        const fused_args = (region_start + 2)[0..argc];
                        vm.frame.pc += 2;
                        vm.code_base = live_code.ptr;
                        return enterInlineConstructorWindow(vm, var_buf, site, instance, fused_args, region_base);
                    }
                }
            }
        }
        if (call_runtime.resolveSameMachineConstructor(vm.global, func, new_target)) |candidate| {
            if (candidate.resolved.fb.isDerivedClassConstructor()) {
                return switch (pushDerivedConstructorEntry(
                    vm,
                    region_base,
                    region_start,
                    func,
                    &candidate,
                    argc,
                )) {
                    .entry => |entry| enterEntry(
                        vm,
                        entry,
                        candidate.resolved.fb.byteCodeAssumeMaterialized().ptr,
                    ),
                    .caught => coldNext(var_buf, vm),
                    .threw => .threw,
                };
            }
            // qjs JS_CallConstructorInternal entry poll, unless already paid.
            if (!entry_polled) {
                exception_ops.pollInterrupt(vm.ctx, vm.global) catch |err| {
                    if (!constructorRegionRecover(vm, region_base, err)) return .threw;
                    return coldNext(var_buf, vm);
                };
            }
            const args = (region_start + 2)[0..argc];
            const prepared = call_runtime.prepareSameMachineConstructorAfterFirstPoll(
                vm.ctx,
                vm.output,
                vm.global,
                func,
                func,
                &candidate,
                args,
                vm.function,
                vm.frame,
            ) catch |err| {
                if (!constructorRegionRecover(vm, region_base, err)) return .threw;
                return coldNext(var_buf, vm);
            };
            vm.frame.pc += 2;
            switch (prepared) {
                .completed => |result| {
                    call_runtime.popOwnedStackRegion(vm.stack, region_base);
                    vm.stack.pushOwnedAssumeCapacity(result);
                    return coldNext(var_buf, vm);
                },
                .instance => |instance| return enterSameMachineConstruction(
                    var_buf,
                    vm,
                    &candidate,
                    func,
                    instance,
                    call_pc,
                    region_base,
                    region_start,
                    args,
                    argc,
                ),
            }
        }
    }

    // Slow path expects frame.pc at the argc operand.
    _ = vm_call.constructor(
        vm.ctx,
        vm.output,
        vm.global,
        vm.stack,
        vm.function,
        vm.frame,
        vm.catch_target,
    ) catch |e| return vm.fail(e);
    return coldNext(var_buf, vm);
}

/// for-of calls a bytecode iterator's zero-argument `next` in the resident
/// Machine. The iterator record stays on the suspended caller stack and roots
/// the borrowed receiver/callable; the tagged continuation consumes
/// `{ value, done }` after return. Other records take the authoritative helper.
fn op_for_of_next(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    vm.publish(pc, sp);
    // Operand-existence guard for hand-built bytecode ending in this opcode.
    if (@intFromPtr(pc + 1) < @intFromPtr(vm.function.byteCode().ptr + vm.function.byteCode().len)) {
        const depth = pc[1];
        if (iterator_ops.forOfIteratorIndex(vm.stack, depth)) |iterator_index| {
            const iterator_record = vm.stack.values[iterator_index..][0..2];
            // Integer-pair loads so the two slots are not merged into one
            // 128-bit load that stalls on forwarding. These copies die at the
            // eligibility checks; the cold arms re-read the record slots (the
            // record stays untouched on the suspended caller stack).
            const receiver = loadValueAsIntPair(&iterator_record[0]);
            const method = loadValueAsIntPair(&iterator_record[1]);
            if (!receiver.is(.undefined_value)) {
                if (inline_calls.resolveInlineFunction(vm.global, method)) |resolved| {
                    vm.frame.pc += 1;
                    // Warm borrowed-iterator arm: a borrowed-eligible callee
                    // with no open var refs has a frame that is one contiguous
                    // args/locals/operand carve, so a warm hit is poll ->
                    // carve -> tail-jump. A warm miss (first use, chunk
                    // boundary, budget shortfall) takes one outlined call into
                    // the authoritative constructor; open-binding targets keep
                    // the generic path below.
                    const execution = resolved.call_facts.execution;
                    const borrowed_simple = execution.simple_inline_eligible or
                        execution.strict_simple_inline_eligible or
                        execution.strict_simple_snapshot_inline_eligible;
                    if (borrowed_simple and resolved.fb.openVarRefCount() == 0) {
                        // A cadence hit resolves fully before the carve attempt,
                        // so the warm-miss constructor below needs no poll.
                        if (vm.ctx.pollInterruptTick()) {
                            if (pollCallEntryCold(vm)) return .threw;
                        }
                        const captures = resolved.var_refs[0..resolved.fb.closureVarCount()];
                        if (vm.machine.tryPushBorrowedIteratorNextFast(resolved.fb, resolved.call_facts, captures, iterator_record, depth)) |entry| {
                            return enterEntry(vm, entry, resolved.fb.byteCodeAssumeMaterialized().ptr);
                        }
                        // Re-read the record slots so `receiver`/`method` are
                        // not kept live across the calls.
                        switch (pushBorrowedIteratorMiss(vm, &resolved, iterator_record[0], iterator_record[1], iterator_record, depth)) {
                            .entry => |entry| return enterEntry(vm, entry, resolved.fb.byteCodeAssumeMaterialized().ptr),
                            .threw => return .threw,
                            .caught => return coldNext(var_buf, vm),
                        }
                    }
                    const target = resolved.bind(iterator_record[0], iterator_record[1]);
                    return pushBorrowedIteratorAndEnter(var_buf, vm, &target, iterator_record, depth);
                }
            }
        } else |_| {}
    }
    iterator_ops.forOfNextVm(vm) catch |err| return vm.fail(err);
    return coldNext(var_buf, vm);
}
// The compiler emits tail_call* followed by a leftover `return`.
// `tail_call_method` MUST stay an alias of op_call_method so method tails keep
// its full admission chain (QuickJS grows a logical frame for them anyway).
//
// Plain `tail_call` is emitted ONLY inside strict functions, as an ES2015
// proper tail call: a deliberate divergence from QuickJS (see LIMITATIONS.md).
// The callee reuses the caller frame via `.reuse_release`, so direct/mutual
// tail recursion stays in constant stack. Native / non-inline callees complete
// through execCall and the leftover `return` stub.
fn op_tail_call(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome {
    const argc = readInt(u16, pc + 1);
    vm.syncPc(pc, 3); // argc:u16
    vm.stack.setTopPtr(sp);
    switch (call_runtime.execCall(
        vm.ctx,
        vm.stack,
        vm.function,
        vm.frame,
        vm.catch_target,
        argc,
        vm.output,
        vm.global,
        true,
        &vm.tail_request,
    ) catch |e| return vm.fail(e)) {
        .done, .continue_loop => return coldNext(var_buf, vm),
        .inline_call => {
            vm.tail_mode = .reuse_release;
            return .tail;
        },
    }
}
const op_tail_call_method = op_call_method;
fn op_eval(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    vm.publish(pc, sp);
    switch (vm_eval_module.directEval(vm.ctx, vm.stack, vm.function, vm.frame, vm.catch_target, vm.output, vm.global, directEvalVarsReachGlobal(vm), vm.machine.depth > 0) catch |e| return vm.fail(e)) {
        .done, .continue_loop => return coldNext(var_buf, vm),
        .tail_inline => |request| {
            vm.tail_request = request;
            vm.tail_mode = .reuse_chain;
            return .tail;
        },
    }
}
/// Frameless OP_drop (qjs CASE(OP_drop): `JS_FreeValue(ctx, sp[-1]); sp--`).
///
/// GC-window contract: the collector traces `stack.values[0..stack.len()]`
/// and fast handlers advance only the register `sp`, so `stack.len()` is
/// stale until a publish. Non-freeing ops (dup/swap) can live with that, but
/// `drop` releases sp[-1]: the post-drop top is published FIRST so the dropped
/// slot is outside the traced window if a collection runs.
///
/// A `catch_offset` marker on top (the `try`/finally sentinel that mutates
/// `vm.catch_target.*`) takes the indirect `cold_table[pc[0]]` hop, which LLVM
/// cannot devirtualize, so the fast leaf stays prologue-free.
pub fn op_drop_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome {
    // Generator parameter-init stop boundaries suspend through coldNext's
    // maybeStop; blocked frame chains reach this opcode through `cold_table`.
    const v = (sp - 1)[0];
    if (v.is(.catch_offset)) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    const nsp = sp - 1;
    vm.stack.setTopPtr(nsp);
    return cont(pc + 1, nsp, var_buf, vm);
}
fn op_drop(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    vm.publish(pc, sp);
    switch (vm_value.drop(vm.ctx.runtime, vm.stack) catch |e| return vm.fail(e)) {
        .value => return coldNext(var_buf, vm),
        .catch_target => |target| {
            vm.catch_target.* = target;
            return coldNext(var_buf, vm);
        },
    }
}
fn op_throw(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    vm.publish(pc, sp);
    switch (vm_control.throwTop(vm) catch |e| return vm.fail(e)) {
        .handled => return coldNext(var_buf, vm),
    }
}
fn op_throw_error(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    vm.publish(pc, sp);
    switch (vm_control.throwErrorVm(vm) catch |e| return vm.fail(e)) {
        .handled => return coldNext(var_buf, vm),
    }
}

const h_initial_yield = coldGen(struct {
    fn body(vm: *Vm, pc: [*]const u8) HostError!?JSValue {
        _ = pc;
        switch (try vm_gen_async.initialYield(vm)) {
            .none, .continue_loop => return null,
            .return_value => |v| return v,
        }
    }
}.body);
const h_yield = coldGen(struct {
    fn body(vm: *Vm, pc: [*]const u8) HostError!?JSValue {
        _ = pc;
        switch (try vm_gen_async.yieldValue(vm)) {
            .none, .continue_loop => return null,
            .return_value => |v| return v,
        }
    }
}.body);
const h_yield_star = coldGen(struct {
    fn body(vm: *Vm, pc: [*]const u8) HostError!?JSValue {
        _ = pc;
        switch (try vm_gen_async.yieldStar(vm)) {
            .none, .continue_loop => return null,
            .return_value => |v| return v,
        }
    }
}.body);
const h_await = coldGen(struct {
    fn body(vm: *Vm, pc: [*]const u8) HostError!?JSValue {
        _ = pc;
        switch (try vm_gen_async.awaitValue(vm)) {
            .none, .continue_loop => return null,
            .return_value => |v| return v,
        }
    }
}.body);

// ===========================================================================
// Hot fast-path handlers — the op's work inlined on the register-resident
// sp/var_buf, advancing pc and tail-dispatching via `cont` with no
// publish/helper/coldNext. On a guard miss (TDZ / non-int operand / stop
// boundary) the handler tail-calls its cold counterpart with the ORIGINAL
// pc/sp so the cold `publish` syncs frame.pc/stack.top from the live sp.
// ===========================================================================

/// Per-op binary-arithmetic handlers: like qjs, every op gets its own label
/// with its own JS_VALUE_IS_BOTH_INT fast leg (OP_pow has none; it stays on
/// the cold h_binary). One handler per op keeps each body a pure-register
/// straight line. Guard misses take an indirect tail (`opBinaryFloat`, then
/// `cold_table[pc[0]]` / `resident_tail_tbl`) so LLVM cannot inline the slow
/// freight back into the integer handler and give every int add a stack frame.
/// Add/sub/mul overflow and mul's -0 stay on this arm, as in qjs.
const BinOp = enum { add, sub, mul, div, mod, shl, sar, shr, band, bor, bxor };

pub fn opBinary(comptime kind: BinOp) Handler {
    return struct {
        // I-cache pin (see op_return).
        fn handler(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
            // qjs JS_VALUE_IS_BOTH_INT — one fused (tag1|tag2)==0 test.
            const ints = JSValue.asInt32Pair((sp - 2)[0], (sp - 1)[0]) orelse
                return @call(.always_tail, opBinaryFloat(kind), .{ pc, sp, var_buf, vm });
            const a = ints.lhs;
            const b = ints.rhs;
            // Each arm stores its own result into sp[-2]: a shared merge point
            // makes LLVM spill the 16-byte JSValue phi through the stack.
            switch (kind) {
                // qjs OP_add int leg: int64 widen; overflow stores a float64 in-CASE.
                .add => {
                    const r: i64 = @as(i64, a) + b;
                    const r32: i32 = @truncate(r);
                    if (r32 != r) {
                        (sp - 2)[0] = JSValue.float64(@floatFromInt(r));
                    } else {
                        (sp - 2)[0].setInt32AssumeInt(r32);
                    }
                },
                // qjs OP_sub int leg, same in-CASE float store.
                .sub => {
                    const r: i64 = @as(i64, a) - b;
                    const r32: i32 = @truncate(r);
                    if (r32 != r) {
                        (sp - 2)[0] = JSValue.float64(@floatFromInt(r));
                    } else {
                        (sp - 2)[0].setInt32AssumeInt(r32);
                    }
                },
                // qjs OP_mul int leg: overflow and -0 both become float64 in-CASE.
                .mul => {
                    const r: i64 = @as(i64, a) * b;
                    const r32: i32 = @truncate(r);
                    if (r32 != r) {
                        (sp - 2)[0] = JSValue.float64(@floatFromInt(r));
                    } else if (r == 0 and (a | b) < 0) {
                        (sp - 2)[0] = JSValue.float64(-0.0);
                    } else {
                        (sp - 2)[0].setInt32AssumeInt(r32);
                    }
                },
                // qjs OP_div int leg: always the canonicalized double quotient.
                .div => (sp - 2)[0] = value_ops.numberToValue(@as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b))),
                // qjs OP_mod int leg: `v1 < 0 || v2 <= 0` goes slow (v2==0,
                // INT32_MIN%-1, -0); the hot remainder is plain int32.
                .mod => {
                    if (a < 0 or b <= 0) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
                    (sp - 2)[0].setInt32AssumeInt(@rem(a, b));
                },
                // qjs OP_shl int leg.
                .shl => (sp - 2)[0].setInt32AssumeInt(a << @intCast(b & 31)),
                // qjs OP_sar int leg.
                .sar => (sp - 2)[0].setInt32AssumeInt(a >> @intCast(b & 31)),
                // qjs OP_shr int leg (JS_NewUint32): int32 if it fits, else float64.
                .shr => {
                    const r = @as(u32, @bitCast(a)) >> @intCast(b & 31);
                    if (r <= std.math.maxInt(i32)) {
                        (sp - 2)[0].setInt32AssumeInt(@intCast(r));
                    } else {
                        (sp - 2)[0] = JSValue.float64(@floatFromInt(r));
                    }
                },
                // qjs OP_and/OP_or/OP_xor int legs.
                .band => (sp - 2)[0].setInt32AssumeInt(a & b),
                .bor => (sp - 2)[0].setInt32AssumeInt(a | b),
                .bxor => (sp - 2)[0].setInt32AssumeInt(a ^ b),
            }
            return cont(pc + 1, sp - 1, var_buf, vm);
        }
    }.handler;
}

/// Float64 leg for a binary op whose both-int32 fast path missed: add/sub/mul
/// take int32-or-float64 operands (anything else goes cold) and store a bare
/// float64. div/mod (zero / sign / -0 cases) and the bitwise ops route cold.
fn opBinaryFloat(comptime kind: BinOp) Handler {
    return struct {
        fn handler(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
            if (comptime kind == .add) {
                const lhs = (sp - 2)[0];
                const rhs = (sp - 1)[0];
                // qjs OP_add's string-string arm: indirect-tail into its resident
                // helper so its call/exception frame is not inherited by the hot
                // int and float legs.
                if (lhs.isString() and rhs.isString())
                    return @call(.always_tail, residentTailHandler(vm, .add_strings), .{ pc, sp, var_buf, vm });
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
    }.handler;
}

/// Resident body for qjs OP_add's string-string arm: both operands are proven
/// strings, so no coercion is skipped; `addStringsOwned` consumes both.
fn op_add_strings(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    // `addStringsOwned` allocates and can collect; `Stack.liveValues` stops at
    // the published `top_ptr`, so publish first to root the operands.
    vm.publish(pc, sp);
    const result = value_ops.addStringsOwned(vm.ctx.runtime, (sp - 2)[0], (sp - 1)[0]) catch |err| {
        // Both operands were consumed: publish the shortened stack, then
        // deliver the error.
        vm.publish(pc, sp - 2);
        const caught = deliverCatchable(vm, err) catch |e2| return vm.fail(e2);
        if (!caught) return vm.fail(err);
        return coldNext(var_buf, vm);
    };
    (sp - 2)[0] = result;
    return cont(pc + 1, sp - 1, var_buf, vm);
}

/// Direct dispatch to the handler for the opcode at `npc[0]`. Same as `next`
/// (emission guarantees every dispatch lands on a real opcode) minus the Debug
/// bound assert; `next` remains the driver/jump entry point.
inline fn cont(npc: [*]const u8, nsp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) Outcome {
    if (comptime enabled) noteDispatch(vm.ctx.runtime, npc);
    return @call(.always_tail, dispatch_table[npc[0]], .{ npc, nsp, var_buf, vm });
}

/// Per-variant local-access handler (qjs has OP_get_loc0..3 etc. as distinct
/// labels). `idx_src` resolves the local index at comptime, so there is no
/// runtime operand decode.
const LocKind = enum { get, put, set };
const LocIdx = enum { c0, c1, c2, c3, byte, half };

pub fn opLoc(comptime kind: LocKind, comptime idx_src: LocIdx) Handler {
    return struct {
        // I-cache pin (see op_return).
        fn handler(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
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
                    sp[0] = var_buf[idx];
                    return cont(pc + advance, sp + 1, var_buf, vm);
                },
                .put => {
                    const value = (sp - 1)[0];
                    var_buf[idx] = value;
                    return cont(pc + advance, sp - 1, var_buf, vm);
                },
                .set => {
                    const value = (sp - 1)[0];
                    var_buf[idx] = value;
                    return cont(pc + advance, sp, var_buf, vm);
                },
            }
        }
    }.handler;
}

/// TDZ-checked local access (qjs OP_get/put/set_loc_check). Lexical loop
/// counters are always emitted in these forms, so they are the hot loc ops of
/// every counting loop. `opLoc` plus the uninitialized guard; a TDZ slot routes
/// cold so checkedLocVm throws. Const writes never reach here (lowered to
/// throw_error). Only the u16 form exists. Int-to-int writes move only the payload.
pub fn opLocCheck(comptime kind: LocKind) Handler {
    return struct {
        // I-cache pin (see op_return).
        fn handler(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
            const idx: u16 = readInt(u16, pc + 1);
            const old_v = var_buf[idx];
            if (old_v.is(.uninitialized)) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
            switch (kind) {
                .get => {
                    sp[0] = var_buf[idx];
                    return cont(pc + 3, sp + 1, var_buf, vm);
                },
                .put => {
                    const source = sp - 1;
                    if (var_buf[idx].trySetInt32FromSlot(&source[0]))
                        return cont(pc + 3, sp - 1, var_buf, vm);
                    const value = source[0];
                    var_buf[idx] = value;
                    return cont(pc + 3, sp - 1, var_buf, vm);
                },
                .set => {
                    const source = sp - 1;
                    if (var_buf[idx].trySetInt32FromSlot(&source[0]))
                        return cont(pc + 3, sp, var_buf, vm);
                    const value = source[0];
                    var_buf[idx] = value;
                    return cont(pc + 3, sp, var_buf, vm);
                },
            }
        }
    }.handler;
}

/// TDZ state reset for a plain lexical local (qjs OP_set_loc_uninitialized).
/// Var-ref-cell cases stay on cold checkedLocVm; a plain slot is qjs's
/// store-then-free sequence.
pub fn op_set_loc_uninitialized(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const idx = readInt(u16, pc + 1);
    var_buf[idx] = JSValue.uninitialized();
    return cont(pc + 3, sp, var_buf, vm);
}

/// Initializing plain lexical locals (qjs OP_put_loc_check_init). Derived
/// constructors stay cold because the once-only `this` init check is
/// observable; every other form just writes the local.
pub fn op_put_loc_check_init(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    if (vm.function.isDerivedClassConstructor()) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    const idx = readInt(u16, pc + 1);
    const value = (sp - 1)[0];
    var_buf[idx] = value;
    return cont(pc + 3, sp - 1, var_buf, vm);
}

/// Closure/global var-ref read (qjs OP_get_var_ref0..3 as distinct labels).
/// An uninitialized cell (TDZ, or a deleted global binding) routes to the cold
/// resolver.
const VarRefIdx = enum { c0, c1, c2, c3, half };
pub fn opGetVarRef(comptime idx_src: VarRefIdx) Handler {
    return struct {
        // I-cache pin (see op_return): a 4-hop dependent load chain whose
        // cycle cost is entry-alignment sensitive.
        fn handler(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
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
            // Bounds are a compile-time contract: finalize validates every
            // var-ref operand against closure_var_count and frames carry exactly
            // that many cells, so the read is unchecked like qjs.
            std.debug.assert(idx < vm.frame.var_refs.len);
            // Seam-leak detector: live in Debug AND ReleaseSafe.
            std.debug.assert(vm.var_refs_base == vm.frame.var_refs.ptr);
            // The slot is a cell by type, so this is qjs's bare
            // `*var_refs[idx]->pvalue` through the Vm-resident base mirror.
            const cell = vm.var_refs_base[idx];
            const v = cell.pvalue.*;
            // qjs OP_get_var_ref has no TDZ probe; only OP_get_var_ref_check
            // does. `.half` also serves that opcode, so it keeps the probe.
            if (comptime idx_src == .half) {
                if (v.is(.uninitialized)) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
            }
            // A cell's value is never itself a cell (the direct-eval const view
            // aliases its target), so `pvalue.*` is the plain value.
            sp[0] = v;
            return cont(pc + advance, sp + 1, var_buf, vm);
        }
    }.handler;
}

/// Plain closure/global var-ref write (qjs OP_put_var_ref0..3 / OP_put_var_ref).
/// Read-only bindings never reach here (lowered to throw_error / drop), so the
/// resident path is qjs set_value exactly. TDZ/init forms stay cold.
pub fn opPutVarRef(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const wide = pc[0] == op.put_var_ref;
    const idx: u16 = if (wide) readInt(u16, pc + 1) else switch (pc[0]) {
        op.put_var_ref0 => 0,
        op.put_var_ref1 => 1,
        op.put_var_ref2 => 2,
        op.put_var_ref3 => 3,
        else => unreachable,
    };
    const advance: usize = if (wide) 3 else 1;
    // Bounds are a compile-time contract (see opGetVarRef).
    std.debug.assert(idx < vm.frame.var_refs.len);
    // Seam-leak detector: live in Debug AND ReleaseSafe.
    std.debug.assert(vm.var_refs_base == vm.frame.var_refs.ptr);
    const cell = vm.var_refs_base[idx];
    cell.pvalue.* = (sp - 1)[0];
    // The same barrier `VarRef.setVarRefValue` takes, written directly here.
    vm.ctx.runtime.gc.generationalBarrier(cell.slotOwner(), (sp - 1)[0].cycleMarkHeader());
    return cont(pc + advance, sp - 1, var_buf, vm);
}

/// TDZ-checked closure var-ref write (qjs OP_put_var_ref_check): OP_put_var_ref
/// plus the uninitialized probe; the throw leg falls to the cold op. Separate
/// from opPutVarRef because put_var_ref is also the lexical-init opcode, and a
/// shared probe would send every closure `let` initialization cold.
pub fn op_put_var_ref_check(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const idx = readInt(u16, pc + 1);
    // Bounds are a compile-time contract (see opGetVarRef).
    std.debug.assert(idx < vm.frame.var_refs.len);
    // Seam-leak detector: live in Debug AND ReleaseSafe.
    std.debug.assert(vm.var_refs_base == vm.frame.var_refs.ptr);
    const cell = vm.var_refs_base[idx];
    // qjs: JS_IsUninitialized(*var_refs[idx]->pvalue) -> throw.
    if (cell.pvalue.*.is(.uninitialized)) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    // qjs set_value: the displaced value is the OLD cell value, never the
    // operand slot, so no stack shrink is needed before it dies.
    cell.pvalue.* = (sp - 1)[0];
    // The same barrier `VarRef.setVarRefValue` takes, written directly here.
    vm.ctx.runtime.gc.generationalBarrier(cell.slotOwner(), (sp - 1)[0].cycleMarkHeader());
    return cont(pc + 3, sp - 1, var_buf, vm);
}

/// Assignment-expression closure/global var-ref write (qjs OP_set_var_ref0..3 /
/// OP_set_var_ref). Unlike put_var_ref, TOS stays as the expression result.
/// Bounds are a compile-time contract (see opGetVarRef).
pub fn opSetVarRef(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const wide = pc[0] == op.set_var_ref;
    const idx: u16 = if (wide) readInt(u16, pc + 1) else switch (pc[0]) {
        op.set_var_ref0 => 0,
        op.set_var_ref1 => 1,
        op.set_var_ref2 => 2,
        op.set_var_ref3 => 3,
        else => unreachable,
    };
    const advance: usize = if (wide) 3 else 1;
    // Bounds are a compile-time contract (see opGetVarRef).
    std.debug.assert(idx < vm.frame.var_refs.len);
    // Seam-leak detector: live in Debug AND ReleaseSafe.
    std.debug.assert(vm.var_refs_base == vm.frame.var_refs.ptr);
    const cell = vm.var_refs_base[idx];
    cell.pvalue.* = (sp - 1)[0];
    // The same barrier `VarRef.setVarRefValue` takes, written directly here.
    vm.ctx.runtime.gc.generationalBarrier(cell.slotOwner(), (sp - 1)[0].cycleMarkHeader());
    return cont(pc + advance, sp, var_buf, vm);
}

// I-cache pin (see op_return).
pub fn op_push_i32(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
    sp[0] = JSValue.int32(readInt(i32, pc + 1));
    return cont(pc + 5, sp + 1, var_buf, vm);
}

/// qjs OP_push_const / OP_push_const8: a direct constant-pool load. Malformed
/// bytecode routes cold.
pub fn op_push_const(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const value = vm.function.constantAt(readInt(u32, pc + 1)) orelse
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    sp[0] = value;
    return cont(pc + 5, sp + 1, var_buf, vm);
}

pub fn op_push_const8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const value = vm.function.constantAt(pc[1]) orelse
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    sp[0] = value;
    return cont(pc + 2, sp + 1, var_buf, vm);
}

/// qjs OP_fclosure/OP_fclosure8: `*sp++ = js_closure(...)`. The constructor may
/// allocate and collect, so pc and the live stack are published first.
pub fn opFclosure(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const wide_index = pc[0] == op.fclosure;
    const advance: usize = if (wide_index) 5 else 2;
    const index: usize = if (wide_index) readInt(u32, pc + 1) else pc[1];
    vm.syncPc(pc, advance);
    vm.syncSp(sp);
    const bytecode_value = vm.function.constantAt(index) orelse return vm.fail(error.InvalidBytecode);
    const closure_value = object_ops.createBytecodeFunctionObject(vm.ctx, vm.frame, vm.global, bytecode_value) catch |err|
        return vm.fail(err);
    // zjs's Stack can relocate (unlike qjs's alloca'd one) and the constructor
    // allocates, so the published top is the authority for the result slot.
    const result_sp = vm.stack.topPtr();
    result_sp[0] = closure_value;
    return cont(pc + advance, result_sp + 1, var_buf, vm);
}

/// qjs OP_push_atom_value. Only the CACHED conversion may run unpublished:
/// `Stack.liveValues` stops at `stack.top_ptr`, so values pushed since the last
/// publish are unrooted. The miss arm allocates and can collect, so it
/// publishes first (an array literal is a run of these pushes).
pub fn op_push_atom_value(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const atom_id = core.Atom.fromRaw(readInt(u32, pc + 1));
    if (vm.ctx.runtime.atoms.cachedPushValue(atom_id)) |cached| {
        sp[0] = cached;
        return cont(pc + 5, sp + 1, var_buf, vm);
    }
    vm.publish(pc, sp);
    const value = vm.ctx.runtime.atoms.toStringValue(vm.ctx.runtime, atom_id) catch |err| {
        return vm.fail(err);
    };
    const live_sp = vm.stack.topPtr();
    live_sp[0] = value;
    return cont(pc + 5, live_sp + 1, var_buf, vm);
}

/// qjs OP_special_object: THIS_FUNC is a resident dup of `sf->cur_func`; the
/// arguments subtypes take a resident continuation that publishes once; other
/// subtypes stay on the cold helper.
pub fn op_special_object(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const subtype = pc[1];
    if (subtype == bytecode.opcode.special_object_subtype.current_function) {
        sp[0] = vm.frame.current_function;
        return cont(pc + 2, sp + 1, var_buf, vm);
    }
    if (subtype == bytecode.opcode.special_object_subtype.arguments or
        subtype == bytecode.opcode.special_object_subtype.mapped_arguments)
    {
        return @call(.always_tail, residentTailHandler(vm, .special_arguments), .{ pc, sp, var_buf, vm });
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

fn op_special_arguments(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const subtype = pc[1];
    // The builder allocates and may collect, so publish the live stack; the
    // owned result lands in the reserved slot and pc/sp continue in registers.
    vm.syncPc(pc, 2);
    vm.syncSp(sp);
    const arguments = object_ops.frameArgumentsObjectForSpecialObject(vm.ctx, vm.global, vm.frame, subtype) catch |err|
        return vm.fail(err);
    sp[0] = arguments;
    return cont(pc + 2, sp + 1, var_buf, vm);
}

/// qjs OP_push_this. An object `this` dups directly (mode-independent, so the
/// mode flags load only after this arm misses); a sloppy undefined/null
/// receiver substitutes the realm global without writing the frame slot back
/// (qjs does not either; direct-eval materialization substitutes the same
/// singleton); a strict non-object receiver is qjs `normal_this`. The sloppy
/// primitive ToObject arm (must cache the wrapper in the frame slot) and the
/// derived-ctor uninitialized check stay cold.
pub fn op_push_this(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const v = vm.frame.this_value;
    if (v.is(.object)) {
        sp[0] = v;
        return cont(pc + 1, sp + 1, var_buf, vm);
    }
    if (vm.function.isStrictMode() or vm.function.runtimeStrictMode()) {
        if (!v.is(.uninitialized)) {
            sp[0] = v;
            return cont(pc + 1, sp + 1, var_buf, vm);
        }
    } else if (v.is(.undefined_value) or v.is(.null_value)) {
        sp[0] = vm.global.value();
        return cont(pc + 1, sp + 1, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

/// Frameless primitive constant pushes (qjs `*sp++ = JS_NULL; BREAK;`). The
/// entry frame reserves `function.stack_size`, so `sp[0]` is unchecked; the
/// GC-traced `stack.len()` stays stale until the next publish, which is safe
/// because these values are untraced primitives. Stop-boundary frames use the
/// all-cold table, so these guardless bodies are normal-frame-only.
pub fn op_undefined_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    sp[0] = JSValue.undefinedValue();
    return cont(pc + 1, sp + 1, var_buf, vm);
}

pub fn op_null_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    sp[0] = JSValue.nullValue();
    return cont(pc + 1, sp + 1, var_buf, vm);
}

pub fn op_push_false_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    sp[0] = JSValue.boolean(false);
    return cont(pc + 1, sp + 1, var_buf, vm);
}

pub fn op_push_true_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    sp[0] = JSValue.boolean(true);
    return cont(pc + 1, sp + 1, var_buf, vm);
}

pub fn op_push_i16(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    sp[0] = JSValue.int32(readInt(i16, pc + 1));
    return cont(pc + 3, sp + 1, var_buf, vm);
}
pub fn op_push_i8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    sp[0] = JSValue.int32(@as(i8, @bitCast(pc[1])));
    return cont(pc + 2, sp + 1, var_buf, vm);
}
// I-cache pin (see op_return).
pub fn op_push_small(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
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

// I-cache pin (see op_return).
/// qjs OP_get_arg: dup `arg_buf[idx]`. Frames pad `args` to `function.arg_count`
/// and operands come from that range, so the bound is a trusted-bytecode
/// contract. Resident so a fifth-or-later parameter does not publish per read.
pub fn op_get_arg(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
    const idx = readInt(u16, pc + 1);
    std.debug.assert(idx < vm.frame.args.len);
    const v = vm.frame.args.ptr[idx];
    sp[0] = v;
    return cont(pc + 3, sp + 1, var_buf, vm);
}

inline fn getArgShort(comptime index: usize, pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) Outcome {
    const v = vm.frame.args.ptr[index];
    sp[0] = v;
    return cont(pc + 1, sp + 1, var_buf, vm);
}

// qjs gives OP_get_arg0..3 distinct labels. Besides removing the runtime
// opcode decode, distinct handlers preserve one terminal indirect-branch PC
// per source opcode so the predictor can learn each successor distribution.
pub fn op_get_arg0_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome {
    return getArgShort(0, pc, sp, var_buf, vm);
}

pub fn op_get_arg1_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    return getArgShort(1, pc, sp, var_buf, vm);
}

pub fn op_get_arg2_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    return getArgShort(2, pc, sp, var_buf, vm);
}

pub fn op_get_arg3_fast(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    return getArgShort(3, pc, sp, var_buf, vm);
}

/// qjs OP_put_arg / OP_set_arg and their short forms replace `arg_buf[idx]`.
/// Same trusted bound as op_get_arg; wide and short encodings share a handler
/// per ownership contract.
const ArgStoreKind = enum { put, set };

pub fn opArgStore(comptime kind: ArgStoreKind) Handler {
    return struct {
        fn handler(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
            const wide_op = switch (kind) {
                .put => op.put_arg,
                .set => op.set_arg,
            };
            const short_base = switch (kind) {
                .put => op.put_arg0,
                .set => op.set_arg0,
            };
            const wide = pc[0] == wide_op;
            const idx: u16 = if (wide) readInt(u16, pc + 1) else pc[0] - short_base;
            const advance: usize = if (wide) 3 else 1;
            std.debug.assert(idx < vm.frame.args.len);
            const value = (sp - 1)[0];
            switch (kind) {
                .put => {
                    vm.frame.args.ptr[idx] = value;
                    return cont(pc + advance, sp - 1, var_buf, vm);
                },
                .set => {
                    vm.frame.args.ptr[idx] = value;
                    return cont(pc + advance, sp, var_buf, vm);
                },
            }
        }
    }.handler;
}

/// Property-site cache (native-boundary design 8.2). The resident field
/// handlers carry ONLY the own-slot arm (identity compare, `proto_key == 0`,
/// indexed load); the prototype / native-getter arms and capture take one
/// indirect tail (`op_prop_site_indirect_tail` / `op_prop_site_capture_tail`),
/// because inlining their guards pushed `op_get_field` over the register
/// budget and gave every hit a frame.
///
/// Guards: `Shape.identity` is monotonic, refreshed before every in-place
/// mutation and never reused, so a recycled Shape address cannot re-match (a
/// pointer guard would be unsound). `proto_key == 0` means own; prototype arms
/// re-check `class_id` because a Shape does not pin the class.
// Primitive receivers and own misses tail-dispatch to separate walkers so
// their qualification code does not inflate the own-hit path. 6-byte op.
fn op_get_field_primitive(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const receiver = (sp - 1)[0];
    const atom_id = core.Atom.fromRaw(readInt(u32, pc + 1));
    if (vm_property_field.primitivePrototypeDataPropertyValueForFastPath(vm.ctx.runtime, vm.global, receiver, atom_id)) |value| {
        const stack_value = value;
        (sp - 1)[0] = stack_value;
        return cont(pc + 6, sp, var_buf, vm);
    }
    return @call(.always_tail, propertyTailHandler(vm, .get_field_property), .{ pc, sp, var_buf, vm });
}

/// `get_loc0` then musttail `op_get_field` at the following `get_field` (which
/// stays in the stream so it still sees its own opcode for throw/pc/cold).
pub fn op_get_loc0_field(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
    sp[0] = var_buf[0];
    return @call(.always_tail, op_get_field, .{ pc + 1, sp + 1, var_buf, vm });
}

/// All-cold / L0-stop: do `get_loc0` only, then `coldNext` onto the surviving
/// `get_field` so stop-before-pc between the two ops is preserved.
pub fn op_get_loc0_field_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    vm.publish(pc, sp);
    vm_property_locals.loc(vm, op.get_loc0) catch |e| return vm.fail(e);
    return coldNext(var_buf, vm);
}

/// `get_loc2` then musttail `op_get_field`. Same contract as `get_loc0_field`.
pub fn op_get_loc2_field(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
    sp[0] = var_buf[2];
    return @call(.always_tail, op_get_field, .{ pc + 1, sp + 1, var_buf, vm });
}

pub fn op_get_loc2_field_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    vm.publish(pc, sp);
    vm_property_locals.loc(vm, op.get_loc2) catch |e| return vm.fail(e);
    return coldNext(var_buf, vm);
}

/// get_field2, then musttail into `op_call_method` so the fused form shares
/// its leaf / exact-args / native-method chain.
pub fn op_get_field2_call_method(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
    const receiver = (sp - 1)[0];
    const atom_id = core.Atom.fromRaw(readInt(u32, pc + 1));
    if (!receiver.is(.object)) {
        sizePad(0x140);
        return @call(.always_tail, propertyTailHandler(vm, .get_field2_primitive), .{ pc, sp, var_buf, vm });
    }
    if (object_ops.objectFromValueTrustedExpression(receiver)) |object| {
        const site = vm.propSite(pc[5]);
        if (object.shape_ref.identity == site.guard_key) {
            if (site.proto_key == 0) {
                const value = loadValueAsIntPair(&object.propertyEntry(site.slot).slot.data);
                storeValueAsIntPair(&sp[0], value);
                return @call(.always_tail, op_call_method, .{ pc + 6, sp + 1, var_buf, vm });
            }
            return @call(.always_tail, propertyTailHandler(vm, .prop_site_indirect), .{ pc, sp, var_buf, vm });
        }
        if (object.shape_ref.identity == site.secondary_guard_key) {
            const value = loadValueAsIntPair(&object.propertyEntry(site.secondary_slot).slot.data);
            storeValueAsIntPair(&sp[0], value);
            return @call(.always_tail, op_call_method, .{ pc + 6, sp + 1, var_buf, vm });
        }
        if (vm_property_field.siteCapturable(site))
            return @call(.always_tail, propertyTailHandler(vm, .prop_site_capture), .{ pc, sp, var_buf, vm });
    }
    var absent = false;
    if (vm_property_field.getFieldFastSlotOrAbsent(vm.ctx.runtime, receiver, atom_id, &absent)) |slot| {
        const value = loadValueAsIntPair(slot);
        storeValueAsIntPair(&sp[0], value);
        return @call(.always_tail, op_call_method, .{ pc + 6, sp + 1, var_buf, vm });
    }
    if (absent) {
        sp[0] = JSValue.undefinedValue();
        return @call(.always_tail, op_call_method, .{ pc + 6, sp + 1, var_buf, vm });
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

pub fn op_get_field2_call_method_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    vm.publish(pc, sp);
    vm_property_field.field(vm, op.get_field2_call_method) catch |e| return vm.fail(e);
    return coldNext(var_buf, vm);
}

fn op_get_field_property_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const receiver = (sp - 1)[0];
    const atom_id = core.Atom.fromRaw(readInt(u32, pc + 1));
    if (vm_property_field.atomPropertyValueForFastPath(vm.ctx.runtime, vm.global, receiver, atom_id)) |result| {
        const stack_value = switch (result) {
            .borrowed => |value| value,
            .owned => |value| value,
            .getter => |getter| blk: {
                if (!getter.is(.undefined_value)) {
                    // Native getter in place: the receiver at (sp - 1) is the root
                    // window; one native call, then the ordinary continuation.
                    if (builtin_dispatch.nativeAccessorTarget(getter, .getter)) |target| {
                        vm.syncPc(pc, 6);
                        vm.stack.setTopPtr(sp);
                        const value = callNativeAccessor(vm, target, receiver, &.{}, .getter) catch |err| {
                            const operand_len = (@intFromPtr(sp) - @intFromPtr(vm.stack.values)) / @sizeOf(JSValue);
                            vm.stack.setLen(operand_len - 1);
                            const caught = deliverCatchable(vm, err) catch |e2| return vm.fail(e2);
                            if (!caught) return vm.fail(err);
                            return coldNext(var_buf, vm);
                        };
                        (sp - 1)[0] = value;
                        return cont(pc + 6, sp, var_buf, vm);
                    }
                    sp[0] = getter;
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
        (sp - 1)[0] = stack_value;
        return cont(pc + 6, sp, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

/// Prototype/exotic continuation after `op_get_field` has already completed
/// the shape probe of `property_holder` (the receiver, or its direct
/// prototype). The receiver stays in `(sp - 1)` and roots the chain.
fn op_get_field_after_own_miss_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const receiver = (sp - 1)[0];
    const atom_id = core.Atom.fromRaw(readInt(u32, pc + 1));
    var absent = false;
    if (vm_property_field.getFieldFastSlotOrAbsentAfterOwnMiss(
        vm.ctx.runtime,
        vm.property_holder,
        atom_id,
        &absent,
    )) |slot| {
        const value = loadValueAsIntPair(slot);
        storeValueAsIntPair(&(sp - 1)[0], value);
        return cont(pc + 6, sp, var_buf, vm);
    }
    if (absent) return @call(.always_tail, propertyTailHandler(vm, .get_field_absent), .{ pc, sp, var_buf, vm });
    // Native accessor on an ordinary link: the walk stopped on a non-data
    // slot; re-probe from the same holder and call a native getter in place.
    if (vm_property_field.ordinaryAccessorGetterAfterOwnMiss(vm.property_holder, atom_id)) |getter| {
        if (builtin_dispatch.nativeAccessorTarget(getter, .getter)) |target| {
            vm.syncPc(pc, 6);
            vm.stack.setTopPtr(sp);
            const value = callNativeAccessor(vm, target, receiver, &.{}, .getter) catch |err| {
                const operand_len = (@intFromPtr(sp) - @intFromPtr(vm.stack.values)) / @sizeOf(JSValue);
                vm.stack.setLen(operand_len - 1);
                const caught = deliverCatchable(vm, err) catch |e2| return vm.fail(e2);
                if (!caught) return vm.fail(err);
                return coldNext(var_buf, vm);
            };
            storeValueAsIntPair(&(sp - 1)[0], value);
            return cont(pc + 6, sp, var_buf, vm);
        }
    }
    if (vm_property_field.isTypedArrayPayloadAtomForFastPath(atom_id)) {
        if (vm_property_field.typedArrayReceiverForFastPath(receiver)) |object| {
            vm.property_holder = object;
            return @call(.always_tail, propertyTailHandler(vm, .get_field_typed_property), .{ pc, sp, var_buf, vm });
        }
    }
    return @call(.always_tail, propertyTailHandler(vm, .get_field_property), .{ pc, sp, var_buf, vm });
}

/// Definite-absence tail for op_get_field: every link of the chain was
/// absence-authoritative, so the result is `undefined`; the receiver is consumed.
fn op_get_field_absent_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    (sp - 1)[0] = JSValue.undefinedValue();
    return cont(pc + 6, sp, var_buf, vm);
}

/// Native-getter site arm: the site guards receiver and holder shape identity
/// and names the accessor slot one prototype link up. The `NativeEntry` is NOT
/// cached — `defineProperty` can replace a getter without touching any shape
/// flag — so the accessor is re-read from the guarded slot. A typed getter is
/// one direct call; an untyped one takes the ordinary native terminal.
fn op_get_field_native_getter_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const receiver = (sp - 1)[0];
    const object = object_ops.objectFromValueTrustedExpression(receiver) orelse
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    const site = vm.propSite(pc[5]);
    const holder = object.shape_ref.proto orelse
        return @call(.always_tail, propertyTailHandler(vm, .get_field_property), .{ pc, sp, var_buf, vm });
    if (object.class_id != site.class_id or holder.shape_ref.identity != site.proto_key)
        return @call(.always_tail, propertyTailHandler(vm, .get_field_property), .{ pc, sp, var_buf, vm });
    const accessor = holder.propertyEntry(site.slot).slot.accessor.getterValue();
    const target = builtin_dispatch.nativeAccessorTarget(accessor, .getter) orelse
        return @call(.always_tail, propertyTailHandler(vm, .get_field_property), .{ pc, sp, var_buf, vm });
    if (target.entry.sig != .none) {
        if (builtin_dispatch.invokeTypedGetterFast(target.entry, receiver)) |value| {
            storeValueAsIntPair(&(sp - 1)[0], value);
            return cont(pc + 6, sp, var_buf, vm);
        }
    } else if (vm_native.getterInlineEligible(vm.rt, target.entry)) {
        // Managed getter: publish pc and stack top (it may throw or re-enter
        // JS), one `bl`; a sentinel takes the catch leg below.
        vm.syncPc(pc, 6);
        vm.stack.setTopPtr(sp);
        const raw = builtin_dispatch.callGetterFromWindow(vm.rt, target.realm, target.entry, target.func_obj, receiver);
        if (!raw.is(.exception)) {
            storeValueAsIntPair(&(sp - 1)[0], raw);
            return cont(pc + 6, sp, var_buf, vm);
        }
        const operand_len = (@intFromPtr(sp) - @intFromPtr(vm.stack.values)) / @sizeOf(JSValue);
        vm.stack.setLen(operand_len - 1);
        const err = builtin_dispatch.nativeHostError(vm.ctx);
        const caught = deliverCatchable(vm, err) catch |e2| return vm.fail(e2);
        if (!caught) return vm.fail(err);
        return coldNext(var_buf, vm);
    }
    vm.syncPc(pc, 6);
    vm.stack.setTopPtr(sp);
    const value = callNativeAccessor(vm, target, receiver, &.{}, .getter) catch |err| {
        const operand_len = (@intFromPtr(sp) - @intFromPtr(vm.stack.values)) / @sizeOf(JSValue);
        vm.stack.setLen(operand_len - 1);
        const caught = deliverCatchable(vm, err) catch |e2| return vm.fail(e2);
        if (!caught) return vm.fail(err);
        return coldNext(var_buf, vm);
    };
    storeValueAsIntPair(&(sp - 1)[0], value);
    return cont(pc + 6, sp, var_buf, vm);
}

/// Prototype / native-getter site arm, tail-called from a resident field
/// handler whose site matched with a non-zero `proto_key`; re-checks class and
/// holder identity, then answers with the guarded slot via the opcode's own
/// continuation. A guard-detail miss re-captures and re-enters; that terminates
/// because `captureFieldSite` either sets `guard_key` to this receiver or
/// retires the site.
fn op_prop_site_indirect_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const receiver = (sp - 1)[0];
    const object = object_ops.objectFromValueTrustedExpression(receiver) orelse
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    const site = vm.propSite(pc[5]);
    const holder: ?*core.Object = blk: {
        if (object.class_id != site.class_id) break :blk null;
        const h = object.shape_ref.proto orelse break :blk null;
        if (h.shape_ref.identity != site.proto_key) break :blk null;
        break :blk h;
    };
    if (holder) |h| {
        if (site.state == vm_property_field.site_proto) {
            const value = loadValueAsIntPair(&h.propertyEntry(site.slot).slot.data);
            switch (pc[0]) {
                op.get_field => {
                    storeValueAsIntPair(&(sp - 1)[0], value);
                    return cont(pc + 6, sp, var_buf, vm);
                },
                op.get_field_field2 => {
                    storeValueAsIntPair(&(sp - 1)[0], value);
                    return @call(.always_tail, op_get_field2, .{ pc + 6, sp, var_buf, vm });
                },
                op.get_field2 => {
                    storeValueAsIntPair(&sp[0], value);
                    return cont(pc + 6, sp + 1, var_buf, vm);
                },
                op.get_field2_call_method => {
                    storeValueAsIntPair(&sp[0], value);
                    return @call(.always_tail, op_call_method, .{ pc + 6, sp + 1, var_buf, vm });
                },
                else => unreachable,
            }
        }
        // `.native_getter` is only ever captured from a `get_field` site (see
        // the capture leg), so no other opcode can reach this line.
        return @call(.always_tail, propertyTailHandler(vm, .get_field_native_getter), .{ pc, sp, var_buf, vm });
    }
    // No `.deferred` arm here, deliberately: this is the hot prototype hit
    // path. A deferral reached from here re-enters the instruction, misses
    // again and routes to `op_prop_site_capture_tail`, which has the arm.
    _ = vm_property_field.captureFieldSite(site, object, core.Atom.fromRaw(readInt(u32, pc + 1)), pc[0] == op.get_field);
    return @call(.always_tail, vm.active_dispatch_tbl[pc[0]], .{ pc, sp, var_buf, vm });
}

/// Capture leg. Out of line so the resident field handlers stay leaves, and
/// entered by tail call so they keep no frame; fills (or retires) the site and
/// re-enters the same instruction.
fn op_prop_site_capture_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const is_put = pc[0] == op.put_field;
    const receiver = if (is_put) (sp - 2)[0] else (sp - 1)[0];
    if (object_ops.objectFromValueTrustedExpression(receiver)) |object| {
        const site = vm.propSite(pc[5]);
        const atom_id = core.Atom.fromRaw(readInt(u32, pc + 1));
        if (is_put) {
            vm_property_field.capturePutSite(site, object, atom_id);
        } else {
            // The `.native_getter` arm has a continuation only in the
            // `get_field` shape, so only `get_field` sites may hold it.
            switch (vm_property_field.captureFieldSite(site, object, atom_id, pc[0] == op.get_field)) {
                .settled => {},
                // See `op_prop_site_indirect_tail`: the site is still
                // capturable, so re-entering would loop. Read cold once.
                .deferred => return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm }),
            }
        }
    }
    return @call(.always_tail, vm.active_dispatch_tbl[pc[0]], .{ pc, sp, var_buf, vm });
}

fn op_get_field_typed_property_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const atom_id = core.Atom.fromRaw(readInt(u32, pc + 1));
    if (vm_property_field.typedArrayPropertyValueForFastPath(vm.ctx.runtime, vm.property_holder, atom_id)) |result| {
        const stack_value = switch (result) {
            .borrowed => |value| value,
            .owned => |value| value,
            .getter => |getter| blk: {
                if (!getter.is(.undefined_value)) {
                    sp[0] = getter;
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
        (sp - 1)[0] = stack_value;
        return cont(pc + 6, sp, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

pub fn op_get_field(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome {
    const receiver = (sp - 1)[0];
    if (!receiver.is(.object)) {
        sizePad(0x100);
        return @call(.always_tail, propertyTailHandler(vm, .get_field_primitive), .{ pc, sp, var_buf, vm });
    }
    // qjs OP_get_field: inline find_own_property, then the prototype walk.
    // Slots move as two 64-bit words (loadValueAsIntPair): the by-value form
    // round-tripped the hit through a stack slot and defeated store forwarding.
    const object = object_ops.objectFromValueTrustedExpression(receiver).?;
    // Site hit arm: guard + indexed load ahead of the probe chain. Only the
    // OWN arm is resident (see the section comment).
    const site = vm.propSite(pc[5]);
    if (object.shape_ref.identity == site.guard_key) {
        if (site.proto_key == 0) {
            const value = loadValueAsIntPair(&object.propertyEntry(site.slot).slot.data);
            storeValueAsIntPair(&(sp - 1)[0], value);
            return cont(pc + 6, sp, var_buf, vm);
        }
        return @call(.always_tail, propertyTailHandler(vm, .prop_site_indirect), .{ pc, sp, var_buf, vm });
    }
    if (object.shape_ref.identity == site.secondary_guard_key) {
        const value = loadValueAsIntPair(&object.propertyEntry(site.secondary_slot).slot.data);
        storeValueAsIntPair(&(sp - 1)[0], value);
        return cont(pc + 6, sp, var_buf, vm);
    }
    if (vm_property_field.siteCapturable(site))
        return @call(.always_tail, propertyTailHandler(vm, .prop_site_capture), .{ pc, sp, var_buf, vm });
    const atom_id = core.Atom.fromRaw(readInt(u32, pc + 1));
    var slow_property = false;
    if (object.findOwnDataSlotFast(atom_id, &slow_property)) |slot| {
        const value = loadValueAsIntPair(slot);
        storeValueAsIntPair(&(sp - 1)[0], value);
        return cont(pc + 6, sp, var_buf, vm);
    }
    if (slow_property)
        return @call(.always_tail, propertyTailHandler(vm, .get_field_property), .{ pc, sp, var_buf, vm });
    // The common miss is a plain instance reading a method from its direct
    // prototype; keep that one link resident (an indirect tail here saved
    // instructions but lost more IPC). Deeper chains and exotics take the tails.
    if (object.class_id == core.class.ids.object or object.isGlobal()) {
        if (object.hasExoticMethods())
            return @call(.always_tail, propertyTailHandler(vm, .get_field_property), .{ pc, sp, var_buf, vm });
        const prototype = object.getPrototype() orelse
            return @call(.always_tail, propertyTailHandler(vm, .get_field_absent), .{ pc, sp, var_buf, vm });
        var prototype_slow = false;
        if (prototype.findOwnDataSlotFast(atom_id, &prototype_slow)) |slot| {
            const value = loadValueAsIntPair(slot);
            storeValueAsIntPair(&(sp - 1)[0], value);
            return cont(pc + 6, sp, var_buf, vm);
        }
        if (prototype_slow)
            return @call(.always_tail, propertyTailHandler(vm, .get_field_property), .{ pc, sp, var_buf, vm });
        vm.property_holder = prototype;
        return @call(.always_tail, propertyTailHandler(vm, .get_field_after_own_miss), .{ pc, sp, var_buf, vm });
    }
    vm.property_holder = object;
    return @call(.always_tail, propertyTailHandler(vm, .get_field_after_own_miss), .{ pc, sp, var_buf, vm });
}

// Primitive get_field2 keeps the raw receiver and pushes the realm-prototype
// data property above it. String auto-init methods use their materializing
// resolver; accessors/exotics/misses tail to the cold handler.
fn op_get_field2_primitive(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const receiver = (sp - 1)[0];
    const atom_id = core.Atom.fromRaw(readInt(u32, pc + 1));
    if (vm_property_field.primitivePrototypeDataPropertyValueForFastPath(vm.ctx.runtime, vm.global, receiver, atom_id)) |value| {
        const stack_value = value;
        sp[0] = stack_value;
        return cont(pc + 6, sp + 1, var_buf, vm);
    }
    // Auto-init String.prototype entries need the materializing resolver.
    if (receiver.isString()) {
        // It allocates and can collect; sync the stack boundary first so the
        // receiver in `sp - 1` is rooted.
        vm.syncSp(sp);
        const resolved = string_ops.getFastStringPrimitiveDataProperty(vm.ctx, vm.global, receiver, atom_id) catch |e| return vm.fail(e);
        if (resolved) |value| {
            sp[0] = value;
            return cont(pc + 6, sp + 1, var_buf, vm);
        }
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

pub fn op_get_field2(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome {
    const receiver = (sp - 1)[0];
    const atom_id = core.Atom.fromRaw(readInt(u32, pc + 1));
    if (!receiver.is(.object)) {
        sizePad(0x138);
        return @call(.always_tail, propertyTailHandler(vm, .get_field2_primitive), .{ pc, sp, var_buf, vm });
    }
    // Object receiver: the value is copied from its holder slot and the
    // receiver stays beneath as `this`. Own site arm resident; the prototype
    // arm (`obj.m()`) is one indirect tail away.
    if (object_ops.objectFromValueTrustedExpression(receiver)) |object| {
        const site = vm.propSite(pc[5]);
        if (object.shape_ref.identity == site.guard_key) {
            if (site.proto_key == 0) {
                const value = loadValueAsIntPair(&object.propertyEntry(site.slot).slot.data);
                storeValueAsIntPair(&sp[0], value);
                return cont(pc + 6, sp + 1, var_buf, vm);
            }
            return @call(.always_tail, propertyTailHandler(vm, .prop_site_indirect), .{ pc, sp, var_buf, vm });
        }
        if (object.shape_ref.identity == site.secondary_guard_key) {
            const value = loadValueAsIntPair(&object.propertyEntry(site.secondary_slot).slot.data);
            storeValueAsIntPair(&sp[0], value);
            return cont(pc + 6, sp + 1, var_buf, vm);
        }
        if (vm_property_field.siteCapturable(site))
            return @call(.always_tail, propertyTailHandler(vm, .prop_site_capture), .{ pc, sp, var_buf, vm });
    }
    var absent = false;
    if (vm_property_field.getFieldFastSlotOrAbsent(vm.ctx.runtime, receiver, atom_id, &absent)) |slot| {
        const value = loadValueAsIntPair(slot);
        storeValueAsIntPair(&sp[0], value);
        return cont(pc + 6, sp + 1, var_buf, vm);
    }
    // Definite absence: get_field2 keeps the receiver beneath, so push a bare
    // `undefined`, as the cold path does.
    if (absent) {
        sp[0] = JSValue.undefinedValue();
        return cont(pc + 6, sp + 1, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

/// Island-tail typed-array `a[i] = v` arm, musttailed from `op_put_array_el`
/// so the dense ARRAY path does not inherit this frame. Int32 RHS stores inline;
/// observable conversions and non-int primitives musttail the rest handler.
pub fn op_put_array_el_ta(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    const key = (sp - 2)[0];
    const obj = (sp - 3)[0];
    if (value.is(.object) or value.isBigInt() or value.is(.symbol))
        return @call(.always_tail, propertyTailHandler(vm, .put_array_el_rest), .{ pc, sp, var_buf, vm });
    const integer = value.as(.int) orelse
        return @call(.always_tail, propertyTailHandler(vm, .put_array_el_rest), .{ pc, sp, var_buf, vm });
    const object = object_ops.objectFromValueTrustedExpression(obj) orelse
        return @call(.always_tail, propertyTailHandler(vm, .put_array_el_rest), .{ pc, sp, var_buf, vm });
    const key_int = key.as(.int) orelse
        return @call(.always_tail, propertyTailHandler(vm, .put_array_el_rest), .{ pc, sp, var_buf, vm });
    const index: u32 = @bitCast(key_int);
    // The dispatch point admits only numeric TypedArray classes; that class
    // registration contract discharges the raw payload-union read below.
    std.debug.assert(core.class.isNumericTypedArrayClass(object.class_id));
    std.debug.assert(object.flags.class_payload_kind == .typed_array);
    if (object.payloadArm().*) |raw| {
        const payload: *const core.object.TypedArrayPayload = @ptrCast(@alignCast(raw));
        const backing = payload.backing_payload orelse {
            return cont(pc + 1, sp - 3, var_buf, vm);
        };
        if (!backing.immutable and index < payload.live_length) {
            if (payload.data) |data| {
                core.typed_array.writeInt32NumericElementByClass(object.class_id, data, index, integer);
            }
        }
    }
    return cont(pc + 1, sp - 3, var_buf, vm);
}

/// Hot inline put_array_el (qjs OP_put_array_el): `a[i] = v` on a fast array
/// with an int32 index stores or appends, then drops the triple. Everything
/// that needs an operand ADDRESS lives in `op_put_array_el_cold`: LLVM hoists
/// that frame materialization above every branch and would tax the hot arm.
pub fn op_put_array_el(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome {
    const obj = (sp - 3)[0];
    // qjs CASE: class==ARRAY → dense, else typed-array dispatch. The dense
    // path stays inside the ARRAY arm so the object is not re-derived after
    // class_id is proven.
    if (obj.is(.object)) {
        if (object_ops.objectFromValueTrustedExpression(obj)) |object| {
            if (object.class_id == core.class.ids.array) {
                @branchHint(.likely);
                // qjs: `idx = JS_VALUE_GET_INT(sp[-2])` as uint32 — a negative
                // index is huge and dies on the bounds test; no sign guard.
                if ((sp - 2)[0].as(.int)) |index_i32| {
                    const index: u32 = @bitCast(index_i32);
                    if (object.isFastArrayIndexInBounds(index)) {
                        const rt = vm.ctx.runtime;
                        const slot = object.fastArraySlotAssumeCapacity(index);
                        storeValueAsIntPair(slot, loadValueAsIntPair(&(sp - 1)[0]));
                        // This arm writes the dense slot itself, so it needs its
                        // own barrier: `a[i] = obj` on a long-lived array is an
                        // old-to-young edge.
                        rt.gc.generationalBarrier(object.gcHeader(), (sp - 1)[0].cycleMarkHeader());
                        return cont(pc + 1, sp - 3, var_buf, vm);
                    }
                    // qjs append arm: idx == count, fast_array, can_extend,
                    // new_len <= size. Growing `.length` needs it writable;
                    // filling a hole at `count` while `count < length` does not.
                    if (object.flags.fast_array and index == object.arrayArm().*.count) {
                        const new_count = index +% 1;
                        if (new_count > index and
                            new_count <= object.arrayArm().*.capacity and
                            object.canExtendFastArray() and
                            (new_count <= object.arrayArm().*.length or
                                object.flags.length_writable))
                        {
                            const slot = object.fastArraySlotAssumeCapacity(index);
                            storeValueAsIntPair(slot, loadValueAsIntPair(&(sp - 1)[0]));
                            vm.ctx.runtime.gc.generationalBarrier(object.gcHeader(), (sp - 1)[0].cycleMarkHeader());
                            object.arrayArm().*.count = new_count;
                            if (new_count > object.arrayArm().*.length)
                                object.arrayArm().*.length = new_count;
                            object.flags.may_have_indexed_properties = true;
                            return cont(pc + 1, sp - 3, var_buf, vm);
                        }
                    }
                }
            } else if ((sp - 2)[0].is(.int) and core.class.isNumericTypedArrayClass(object.class_id)) {
                return @call(.always_tail, Opaque(op_put_array_el_ta).get(), .{ pc, sp, var_buf, vm });
            }
        }
    }
    // Reached through the property-tail table: an indirect transfer LLVM cannot
    // inline, which keeps the address-taking slow legs (and their frame) out
    // of this handler.
    sizePad(0x100);
    return @call(.always_tail, propertyTailHandler(vm, .put_array_el_rest), .{ pc, sp, var_buf, vm });
}

/// Every leg that needs an operand address, kept out of the hot handler. Not
/// marked `noinline` because that would break the `musttail` transfers below;
/// its size keeps LLVM from inlining it anyway.
fn op_put_array_el_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const value = loadValueAsIntPair(&(sp - 1)[0]);
    const key = loadValueAsIntPair(&(sp - 2)[0]);
    const obj = loadValueAsIntPair(&(sp - 3)[0]);
    const rt = vm.ctx.runtime;
    // Every leg below can allocate, so publish the live operand boundary once;
    // the legs neither push nor pop, so the register `sp` stays authoritative.
    vm.syncSp(sp);
    // Inline Array check: non-Array receivers (typed arrays, plain objects)
    // skip the noinline dense probes, which would only re-test isArray().
    const array_ptr: ?*core.Object = if (obj.is(.object)) blk: {
        const obj_ptr = object_ops.objectFromValue(obj) orelse break :blk null;
        break :blk if (obj_ptr.isArray()) obj_ptr else null;
    } else null;
    if (array_ptr) |array_object| {
        // In-range overwrite inline (qjs: bounds test + set_value), keeping the
        // dominant arm off the noinline probe that re-tests isArray().
        if (key.as(.int)) |index_i32| {
            if (index_i32 >= 0 and
                array_object.setFastArrayElementOwnedDuringActiveBytecode(rt, @intCast(index_i32), value))
            {
                return cont(pc + 1, sp - 3, var_buf, vm);
            }
        }
        const overwrite_result = array_ops.putDenseArrayElementOverwriteOwnedFast(rt, obj, key, value);
        if (overwrite_result == .handled) {
            return cont(pc + 1, sp - 3, var_buf, vm);
        }
        if (overwrite_result == .append_candidate) {
            switch (array_ops.putDenseArrayElementAppendOwnedFast(rt, obj, key, value)) {
                .handled => {
                    return cont(pc + 1, sp - 3, var_buf, vm);
                },
                .out_of_memory => return vm.fail(error.OutOfMemory),
                .miss => {},
            }
        }
    }
    if (key.is(.int) and obj.is(.object)) {
        // Existing own integer element on a slow/sparse Array (qjs: one
        // find_own_property + set_value), before the typed-array probe. New /
        // non-writable / accessor slots fall through.
        if (vm_property_field.fastArrayOwnIntElementSet(rt, obj, key, value) catch |e| return vm.fail(e)) {
            return cont(pc + 1, sp - 3, var_buf, vm);
        }
        // Typed-array integer write: convert, bounds-recheck, store. Object /
        // BigInt / Symbol values (observable conversion) return .not_typed_array
        // and fall through; OOB/detached is a silent no-op.
        switch (vm_property_field.putTypedArrayElementFast(rt, obj, key, value) catch |e| return vm.fail(e)) {
            .handled => {
                return cont(pc + 1, sp - 3, var_buf, vm);
            },
            .not_typed_array => {},
        }
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

// Hot inline put_field (qjs OP_put_field's inline window): find_own_property,
// plain-writable-data test, set_value, sp -= 2. Adds, accessors/read-only and
// non-object receivers go cold. Slot moves are integer pairs (forwarding).
pub fn op_put_field(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome {
    const receiver = (sp - 2)[0];
    const atom_id = core.Atom.fromRaw(readInt(u32, pc + 1));
    const rt = vm.ctx.runtime;
    // Site write arm: own writable data slot only. `capturePutSite` fills the
    // site from `findWritableOwnDataSlotFast`, so the identity guard alone
    // proves the direct store legal.
    if (object_ops.objectFromValueTrustedExpression(receiver)) |owner| {
        const site = vm.propSite(pc[5]);
        // Unlike the read arm, the write arm is class-dependent (mapped
        // `arguments` stores must reach the binding) and a Shape does not pin
        // the class, so it carries the class check.
        if (owner.shape_ref.identity == site.guard_key and owner.class_id == site.class_id) {
            const slot = &owner.propertyEntry(site.slot).slot.data;
            const value = loadValueAsIntPair(&(sp - 1)[0]);
            storeValueAsIntPair(slot, value);
            rt.gc.generationalBarrierValue(owner.gcHeader(), (sp - 1)[0]);
            return cont(pc + 6, sp - 2, var_buf, vm);
        }
        if (vm_property_field.siteCapturable(site) and owner.shape_ref.identity != site.guard_key)
            return @call(.always_tail, propertyTailHandler(vm, .prop_site_capture), .{ pc, sp, var_buf, vm });
    }
    if (vm_property_field.putFieldFastSlot(rt, receiver, atom_id)) |slot| {
        const value = loadValueAsIntPair(&(sp - 1)[0]);
        storeValueAsIntPair(slot, value); // consumes the stack's ref on value
        // This arm writes the slot itself, so it needs its own barrier:
        // `node.left = child` on a long-lived object is an old-to-young edge.
        if (object_ops.objectFromValueTrustedExpression(receiver)) |owner| {
            rt.gc.generationalBarrierValue(owner.gcHeader(), (sp - 1)[0]);
        }
        return cont(pc + 6, sp - 2, var_buf, vm);
    }
    sizePad(0x8);
    return @call(.always_tail, propertyTailHandler(vm, .put_field_add), .{ pc, sp, var_buf, vm });
}

/// Resident add-tail for the hot put_field miss: decode the atom off the live
/// pc and call the single-walk core the cold arm uses (qjs's slow leg is one
/// JS_SetPropertyInternal call). Forms needing the full resolver decline with
/// nothing mutated and re-tail to the cold twin.
///
/// The stack boundary is synced to sp - 2 BEFORE the helper so a GC during the
/// append does not re-walk the operand slots. `.done`: `value` consumed, both
/// operands popped. `.slow`: nothing mutated, the cold twin's publish re-covers
/// both operands (OOM is also `.slow`).
fn op_put_field_add_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    if (comptime builtin.mode == .Debug) std.debug.assert(pc[0] == op.put_field);
    const receiver_value = (sp - 2)[0];
    const receiver = object_ops.objectFromValueTrustedExpression(receiver_value) orelse
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    const atom_id = core.Atom.fromRaw(readInt(u32, pc + 1));
    const value = (sp - 1)[0];
    const rt = vm.ctx.runtime;
    vm.syncSp(sp - 2);
    switch (receiver.setOrDefineOwnDataPropertyForPutFieldOwned(rt, atom_id, value)) {
        .done => {
            return cont(pc + 6, sp - 2, var_buf, vm);
        },
        .slow => {
            return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
        },
    }
}

fn op_get_array_el_atom_key(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const key = (sp - 1)[0];
    const obj = (sp - 2)[0];
    if (vm_property_field.existingPropertyKeyValueForFastPath(vm.ctx.runtime, vm.global, obj, key)) |result| {
        const stack_value = switch (result) {
            .borrowed => |value| value,
            .owned => |value| value,
            .getter => |getter| blk: {
                if (!getter.is(.undefined_value)) {
                    const owned_getter = getter;
                    (sp - 1)[0] = owned_getter;
                    return @call(.always_tail, propertyTailHandler(vm, .get_array_el_atom_key_getter), .{ pc, sp, var_buf, vm });
                }
                break :blk JSValue.undefinedValue();
            },
            .proxy => |proxy| {
                vm.property_holder = proxy;
                return @call(.always_tail, propertyTailHandler(vm, .get_array_el_atom_key_proxy), .{ pc, sp, var_buf, vm });
            },
        };
        (sp - 2)[0] = stack_value;
        return cont(pc + 1, sp - 1, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

inline fn op_get_property_cached_getter(comptime pc_advance: usize, pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) Outcome {
    vm.syncPc(pc, pc_advance);
    const operand_len = (@intFromPtr(sp) - @intFromPtr(vm.stack.values)) / @sizeOf(JSValue);
    const getter = vm.stack.values[operand_len - 1];
    const receiver = vm.stack.values[operand_len - 2];
    // qjs invokes an accessor through the ordinary call path. An eligible
    // bytecode getter enters this Machine: the live region `[receiver, getter]`
    // is exactly the zero-argument `.method` layout, and frame.pc already
    // names the next opcode.
    if (inline_calls.resolveInlineTarget(vm.global, receiver, getter)) |target| {
        const region_start = sp - 2;
        vm.stack.retreatToCallRegionFrom(&vm.machine.pending_call_region, sp, region_start);
        return pushAndEnter(var_buf, vm, &target, region_start, 0, .method);
    }
    vm.stack.setTopPtr(sp);
    // Native getter: one native call, no generic call machinery;
    // `[receiver, getter]` stays on the stack as the root window.
    if (builtin_dispatch.tryNativeAccessorCall(vm.ctx, vm.output, vm.global, receiver, getter, &.{}, vm.function, vm.frame, .getter)) |native_result| {
        const value = native_result catch |err| {
            vm.stack.setLen(operand_len - 2);
            const caught = deliverCatchable(vm, err) catch |e2| return vm.fail(e2);
            if (!caught) return vm.fail(err);
            return coldNext(var_buf, vm);
        };
        vm.stack.values[operand_len - 2] = value;
        vm.stack.setLen(operand_len - 1);
        return coldNext(var_buf, vm);
    }
    const value = call_runtime.callValueOrBytecodeRootPreRooted(
        vm.ctx,
        vm.output,
        vm.global,
        receiver,
        getter,
        &.{},
        vm.function,
        vm.frame,
    ) catch |err| {
        vm.stack.setLen(operand_len - 2);
        const caught = deliverCatchable(vm, err) catch |e2| return vm.fail(e2);
        if (!caught) return vm.fail(err);
        return coldNext(var_buf, vm);
    };
    vm.stack.values[operand_len - 2] = value;
    vm.stack.setLen(operand_len - 1);
    return coldNext(var_buf, vm);
}

fn op_get_array_el_atom_key_getter(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    return op_get_property_cached_getter(1, pc, sp, var_buf, vm);
}

fn op_get_field_cached_getter(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    return op_get_property_cached_getter(6, pc, sp, var_buf, vm);
}

fn op_get_static_cached_proxy(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    // The field family is a 6-byte op; `get_length` is 1.
    const pc_advance: usize = if (pc[0] == op.get_length) 1 else 6;
    vm.syncPc(pc, pc_advance);
    const operand_len = (@intFromPtr(sp) - @intFromPtr(vm.stack.values)) / @sizeOf(JSValue);
    vm.stack.setTopPtr(sp);
    const receiver = vm.stack.values[operand_len - 1];
    if (tryInlineProxyTrap(false, var_buf, vm, vm.property_holder, vm.property_atom)) |outcome| return outcome;
    const retained_atom = vm.property_atom;
    const value = object_ops.getProxyProperty(
        vm.ctx,
        vm.output,
        vm.global,
        receiver,
        vm.property_holder,
        retained_atom,
        vm.function,
        vm.frame,
    ) catch |err| {
        vm.stack.setLen(operand_len - 1);
        const caught = deliverCatchable(vm, err) catch |e2| return vm.fail(e2);
        if (!caught) return vm.fail(err);
        return coldNext(var_buf, vm);
    };
    vm.stack.values[operand_len - 1] = value;
    return coldNext(var_buf, vm);
}

/// Enter an ordinary bytecode Proxy `get` trap without a nested VM. Accepts
/// only a plain data `handler.get` hit; accessor/Proxy/exotic trap lookup stays
/// on getProxyProperty so its observable lookup is not repeated. The caller's
/// `[receiver]` / `[receiver,key]` region becomes `[target,key]`; the receiver
/// moves into argv.
inline fn tryInlineProxyTrap(comptime computed_key: bool, var_buf: [*]JSValue, vm: *Vm, proxy: *core.Object, atom_id: core.Atom) ?Outcome {
    const target_value = proxy.proxyTarget() orelse return null;
    const handler_value = proxy.proxyHandler() orelse return null;
    const trap = property_direct.ordinaryDataPropertyValueOrUndefinedForFastPath(vm.ctx.runtime, handler_value, core.atom.ids.get) orelse return null;
    const stack = vm.stack;
    const operand_len = stack.len();
    const operand_count: usize = if (computed_key) 2 else 1;
    std.debug.assert(operand_len >= operand_count);
    const region_base = operand_len - operand_count;
    const receiver = stack.values[region_base];
    const computed_key_value: JSValue = if (computed_key) stack.values[region_base + 1] else undefined;
    if (trap.is(.undefined_value) or trap.is(.null_value)) {
        if (property_direct.ordinaryDataPropertyValueOrUndefinedForFastPath(vm.ctx.runtime, target_value, atom_id)) |borrowed| {
            const result = borrowed;
            stack.values[region_base] = result;
            stack.setLen(region_base + 1);
            return coldNext(var_buf, vm);
        }
        return null;
    }
    const target = inline_calls.resolveInlineTarget(vm.global, handler_value, trap) orelse return null;

    const key = if (computed_key)
        computed_key_value
    else
        object_ops.proxyTrapKeyValue(vm.ctx.runtime, atom_id) catch |err| {
            stack.setLen(region_base);
            const caught = call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, stack, vm.frame, vm.catch_target, vm.global, err) catch |e2| return vm.fail(e2);
            if (!caught) return vm.fail(err);
            return coldNext(var_buf, vm);
        };
    var moved = [_]JSValue{
        handler_value,
        trap,
        target_value,
        key,
        receiver,
    };

    stack.values[region_base] = target_value;
    if (!computed_key) stack.pushOwnedAssumeCapacity(key);
    return pushMovedAndEnter(var_buf, vm, &target, &moved, .proxy_get, atom_id.raw(), false);
}

fn op_get_array_el_atom_key_proxy(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    vm.publish(pc, sp);
    const operand_len = vm.stack.len();
    const key = vm.stack.values[operand_len - 1];
    const receiver = vm.stack.values[operand_len - 2];
    const atom_id = vm_property_field.existingPropertyKeyAtomForFastPath(key).?;
    if (tryInlineProxyTrap(true, var_buf, vm, vm.property_holder, atom_id)) |outcome| return outcome;
    const retained_atom = atom_id;
    const value = object_ops.getProxyProperty(
        vm.ctx,
        vm.output,
        vm.global,
        receiver,
        vm.property_holder,
        retained_atom,
        vm.function,
        vm.frame,
    ) catch |err| {
        vm.stack.setLen(operand_len - 2);
        const caught = deliverCatchable(vm, err) catch |e2| return vm.fail(e2);
        if (!caught) return vm.fail(err);
        return coldNext(var_buf, vm);
    };
    vm.stack.values[operand_len - 2] = value;
    vm.stack.setLen(operand_len - 1);
    return coldNext(var_buf, vm);
}

/// Island-tail typed-array `a[i]` arm, musttailed from `op_get_array_el` so the
/// dense ARRAY path does not inherit this frame. Called through the exported
/// `Handler` slot so LLVM cannot merge it back (`noinline` on the callee breaks
/// Zig's always_tail type match).
pub fn op_get_array_el_ta(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome {
    const key = (sp - 1)[0];
    const obj = (sp - 2)[0];
    const object = object_ops.objectFromValueTrustedExpression(obj) orelse
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    const key_int = key.as(.int) orelse
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    // qjs treats a negative int32 index as a huge unsigned idx: undefined, no cold.
    const index: u32 = @bitCast(key_int);
    // One JSValue home: a per-kind `blk`/`switch` result grows the frame.
    var result = JSValue.undefinedValue();
    // class_id already proved numeric TA: skip the payload-kind reload.
    std.debug.assert(core.class.isNumericTypedArrayClass(object.class_id));
    std.debug.assert(object.flags.class_payload_kind == .typed_array);
    if (object.payloadArm().*) |raw| {
        const payload: *const core.object.TypedArrayPayload = @ptrCast(@alignCast(raw));
        if (index < payload.live_length) {
            result = core.typed_array.decodeNumericElementByClass(object.class_id, payload.data.?, index);
        }
    }
    (sp - 2)[0] = result;
    return cont(pc + 1, sp - 1, var_buf, vm);
}

pub fn op_get_array_el(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome {
    const key = (sp - 1)[0];
    const obj = (sp - 2)[0];
    // Same shape as `op_put_array_el`: class==ARRAY first, then the typed-array
    // mask. Wrapping this in `key.is(.int)` made LLVM fold ARRAY into the miss.
    if (obj.is(.object)) {
        if (object_ops.objectFromValueTrustedExpression(obj)) |object| {
            if (object.class_id == core.class.ids.array) {
                @branchHint(.likely);
                // qjs keeps the ARRAY+INT+bounds arm inside the class switch;
                // the generic helper below also serves unmapped arguments and
                // would repeat the tag and class tests.
                if (key.as(.int)) |index_i32| {
                    const index: u32 = @bitCast(index_i32);
                    if (object.fastArrayElementDup(index)) |value| {
                        (sp - 2)[0] = value;
                        return cont(pc + 1, sp - 1, var_buf, vm);
                    }
                }
            } else if (key.is(.int) and core.class.isNumericTypedArrayClass(object.class_id)) {
                return @call(.always_tail, Opaque(op_get_array_el_ta).get(), .{ pc, sp, var_buf, vm });
            } else if (key.is(.int) and object.class_id == core.class.ids.mapped_arguments) {
                // Mapped-arguments slots live in var-ref cells, so the dense
                // arm cannot serve them.
                if (key.as(.int)) |idx| {
                    if (idx >= 0) {
                        if (object.mappedArgumentsIntElementDup(@intCast(idx))) |el| {
                            (sp - 2)[0] = el;
                            return cont(pc + 1, sp - 1, var_buf, vm);
                        }
                    }
                }
            }
        }
    }
    if (vm_property_field.fastDenseArrayElementValue(obj, key)) |value| {
        (sp - 2)[0] = value;
        return cont(pc + 1, sp - 1, var_buf, vm);
    }
    if (key.is(.int) and obj.is(.object)) {
        if (vm_property_field.fastArrayOwnIntElementValue(obj, key)) |value| {
            (sp - 2)[0] = value;
            return cont(pc + 1, sp - 1, var_buf, vm);
        }
    }
    if (key.isString() or key.is(.symbol)) {
        return @call(.always_tail, propertyTailHandler(vm, .get_array_el_atom_key), .{ pc, sp, var_buf, vm });
    }
    sizePad(0x20);
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

/// Hot `OP_get_array_el2` (qjs `GET_ARRAY_EL_INLINE(keep=1)`): same dense
/// predicate as `op_get_array_el`; `[obj, key] → [obj, value]` so `obj[i](...)`
/// can `call_method`. Other arms stay cold: their non-leaf helpers would tax
/// the dense hit with a prologue.
pub fn op_get_array_el2(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
    const key = (sp - 1)[0];
    const obj = (sp - 2)[0];
    if (vm_property_field.fastDenseArrayElementValue(obj, key)) |value| {
        // key is TAG_INT (fastDenseArrayElementValue requires asInt32); no free.
        (sp - 1)[0] = value;
        return cont(pc + 1, sp, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

// Inline `.length` (qjs OP_get_length): a string operand (flat or rope) pushes
// its logical length without flattening; a fast array reads its length inline;
// Arguments and other ordinary objects with a plain data `length` stay resident.
// Accessors, Proxies and typed arrays tail to the resident action handlers.
pub fn op_get_length(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    if (value.isString()) {
        // Read the rope's logical length without flattening; materializing it
        // would make an `s = s + x; s.length` loop O(n) per iteration.
        const len_val = JSValue.int32(@intCast(core.string.stringValueLen(value)));
        (sp - 1)[0] = len_val;
        return cont(pc + 1, sp, var_buf, vm);
    }
    // Plain fast array `.length` (the `i < arr.length` loop read).
    if (vm_property_field.fastArrayLengthValue(value)) |len_val| {
        (sp - 1)[0] = len_val;
        return cont(pc + 1, sp, var_buf, vm);
    }
    // arguments.length is an own int32 data property; a class gate keeps
    // Arguments off the exotic tail classNeedsSlowPropertyAccess would force.
    if (object_ops.objectFromValueTrustedExpression(value)) |object| {
        if (object.class_id == core.class.ids.mapped_arguments or
            object.class_id == core.class.ids.arguments)
        {
            var slow_property = false;
            if (object.findOwnDataSlotFast(core.atom.ids.length, &slow_property)) |slot| {
                const len_val = slot.*;
                (sp - 1)[0] = len_val;
                return cont(pc + 1, sp, var_buf, vm);
            }
        }
    }
    // Any other object with an own/inherited plain data `length` stays resident.
    if (vm_property_field.getLengthFieldFast(vm.ctx.runtime, value)) |borrowed| {
        const len_val = borrowed;
        (sp - 1)[0] = len_val;
        return cont(pc + 1, sp, var_buf, vm);
    }
    return @call(.always_tail, propertyTailHandler(vm, .get_length_property), .{ pc, sp, var_buf, vm });
}

fn op_get_length_property_tail(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    // A data miss can still be an accessor or meet a Proxy in the prototype
    // walk; reuse static get_field's resident classifier and continuations.
    const action = vm_property_field.getLengthActionForFastPath(vm.ctx.runtime, value) orelse
        vm_property_field.atomPropertyValueForFastPath(vm.ctx.runtime, vm.global, value, core.atom.ids.length);
    if (action) |result| {
        const len_val = switch (result) {
            .borrowed => |borrowed| borrowed,
            .owned => |owned| owned,
            .getter => |getter| blk: {
                if (!getter.is(.undefined_value)) {
                    sp[0] = getter;
                    return @call(.always_tail, propertyTailHandler(vm, .get_array_el_atom_key_getter), .{ pc, sp + 1, var_buf, vm });
                }
                break :blk JSValue.undefinedValue();
            },
            .proxy => |proxy| {
                vm.property_holder = proxy;
                vm.property_atom = core.atom.ids.length;
                return @call(.always_tail, propertyTailHandler(vm, .get_static_cached_proxy), .{ pc, sp, var_buf, vm });
            },
        };
        (sp - 1)[0] = len_val;
        return cont(pc + 1, sp, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

// Frameless OP_object: create the bare `{}` register-resident and push it. Only
// OOM routes to the cold shell (no state was mutated, so re-execution is clean).
pub fn op_object(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    vm.syncSp(sp);
    const value = vm_literal.newPlainObjectValue(vm.ctx, vm.global) catch
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    sp[0] = value;
    return cont(pc + 1, sp + 1, var_buf, vm);
}

// Same frameless literal-create contract as OP_object, but the parser proved
// that the final Shape has one or two unique static named properties. Allocate
// the matching two-entry trailing property region up front; computed/spread or
// larger literals never reach this opcode.
pub fn op_object_slots2(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    vm.syncSp(sp);
    const value = vm_literal.newPlainObjectReserved2Value(vm.ctx, vm.global) catch
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    sp[0] = value;
    return cont(pc + 1, sp + 1, var_buf, vm);
}

// Frameless OP_define_field: one plain-data define of sp[-1] on sp[-2].
// `defineFieldFast` consumes the value on a hit (pop it; the object stays as the
// literal's receiver). On `false` nothing was consumed, so the cold shell
// re-executes with stack ownership intact. Arrays, private atoms, proxies,
// non-extensible objects and setters all take the cold shell. 5-byte op (u32 atom).
pub fn op_define_field(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    vm.syncSp(sp);
    const value = (sp - 1)[0];
    const obj = (sp - 2)[0];
    const atom_id = core.Atom.fromRaw(readInt(u32, pc + 1));
    if (vm_literal.defineFieldFast(vm.ctx.runtime, obj, atom_id, value)) {
        return cont(pc + 5, sp - 1, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

// Frameless OP_array_from: build the dense array from the operand window in one
// call using the realm's prepared initial array shape. Element values MOVE from
// `(sp-argc)[0..argc]` into dense storage (no dup, no balancing free); the array
// replaces the window. OOM or a realm without its initial shape routes to the
// cold shell with the values untouched and frame.pc at the u16 operand. 3-byte op.
pub fn op_array_from(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const argc: usize = readInt(u16, pc + 1);
    const rt = vm.ctx.runtime;
    const values = (sp - argc)[0..argc];
    const initial_shape = vm.ctx.array_shape orelse
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    // Frameless dispatch keeps `sp` in a register; the collector's
    // `liveValues()` reads `stack.top_ptr`. Publish before the literal
    // allocation so already-evaluated elements below argc stay marked.
    vm.syncSp(sp);
    const array = core.array.constructLiteralOwnedDenseFromShape(rt, values, initial_shape) catch
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    const nsp = sp - argc;
    nsp[0] = array;
    return cont(pc + 3, nsp + 1, var_buf, vm);
}

/// Per-op comparison handler (qjs OP_CMP / OP_CMP_EQ / OP_CMP_STRICT_EQ expand to
/// one CASE per opcode). With `opc` comptime each handler is the int fast path:
/// one fused both-int tag fold, cmp, cset, store sp[-2], tail-dispatch. Relational
/// misses keep the in-handler float64 compare and then hop `cold_table[pc[0]]`.
/// The eq family's remaining shapes live in `opCompareEq`, reached by a
/// PC-relative tail through an `export fn` boundary: a same-file inlinable tail
/// would fold the release ladder back and regrow a frame on the int leaf, and the
/// leftover `eq_if_false8` needs a direct entry that does not switch on `pc[0]`.
pub fn opCompare(comptime opc: u8) Handler {
    return struct {
        // I-cache pin (see op_return).
        fn handler(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
            const ints = JSValue.asInt32Pair((sp - 2)[0], (sp - 1)[0]) orelse {
                switch (comptime opc) {
                    op.lt, op.lte, op.gt, op.gte => {
                        // qjs OP_CMP inlines the float64/int relational compare
                        // before js_relational_slow; both operands are non-refcounted.
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
                        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
                    },
                    else => return @call(.always_tail, compareEqExport(opc), .{ pc, sp, var_buf, vm }),
                }
            };
            const r = switch (opc) {
                op.lt => ints.lhs < ints.rhs,
                op.lte => ints.lhs <= ints.rhs,
                op.gt => ints.lhs > ints.rhs,
                op.gte => ints.lhs >= ints.rhs,
                op.eq, op.strict_eq => ints.lhs == ints.rhs,
                op.neq, op.strict_neq => ints.lhs != ints.rhs,
                else => unreachable,
            };
            (sp - 2)[0] = JSValue.boolean(r);
            return cont(pc + 1, sp - 1, var_buf, vm);
        }
    }.handler;
}

/// The eq family's operand-shape arms (qjs OP_CMP_EQ / OP_CMP_STRICT_EQ resolve
/// int/int, int/f64, f64/int, f64/f64, obj/(null|undefined), obj/obj,
/// (null|undefined)/(null|undefined), (null|undefined)/obj and str/str inline and
/// reach js_eq_slow / js_strict_eq2 only for mixed operands).
///
/// Reached only through the `zjs_cmp_*_framed` / `zjs_cmp_*_mixed` `export fn`
/// boundary below; that hop is what stops LLVM from folding this body back into
/// the int leaf. Unresolved shapes fall to `cold_table[pc[0]]`, so string/number
/// coercion, ToPrimitive, BigInt and Symbol/object operands keep the full protocol.
///
/// Ownership: the result is stored and the traced operand window shrunk BEFORE
/// releasing, so a collection triggered by the release cannot see the dead slot.
fn opCompareEq(comptime opc: u8) Handler {
    return struct {
        fn handler(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome {
            const strict = comptime (opc == op.strict_eq or opc == op.strict_neq);
            const inv = comptime (opc == op.neq or opc == op.strict_neq);
            const lhs = (sp - 2)[0];
            const rhs = (sp - 1)[0];

            // null ⇒ no arm matched ⇒ keep the generic path.
            const resolved: ?bool = blk: {
                // int/int is already resolved by opCompare's leading arm.
                if (lhs.as(.int)) |a| {
                    if (rhs.as(.float64)) |d2| break :blk @as(f64, @floatFromInt(a)) == d2;
                    // qjs strict compares tags first: a number against any other tag
                    // is FALSE with no coercion.
                    break :blk if (comptime strict) false else null;
                }
                if (lhs.as(.float64)) |d1| {
                    if (rhs.as(.int)) |b| break :blk d1 == @as(f64, @floatFromInt(b));
                    if (rhs.as(.float64)) |d2| break :blk d1 == d2;
                    break :blk if (comptime strict) false else null;
                }
                if (lhs.is(.object)) {
                    if (rhs.is(.object)) break :blk lhs.same(rhs); // qjs: JS_VALUE_GET_OBJ(op1) == JS_VALUE_GET_OBJ(op2)
                    if (comptime strict) break :blk false; // qjs 20372-20375
                    // Loose object vs null/undefined is exactly the IsHTMLDDA test
                    // — `document.all == null` is true.
                    if (rhs.is(.null_value) or rhs.is(.undefined_value)) break :blk value_ops.isHTMLDDA(lhs);
                    break :blk null;
                }
                // Two booleans reduce to strict equality (ECMA-262 7.2.14 step 1);
                // qjs resolves this in js_strict_eq2's first case. Kept resident
                // because zjs's equivalent of that leaf is the publishing cold shell.
                if (lhs.as(.boolean)) |a| {
                    if (rhs.as(.boolean)) |b| break :blk a == b;
                    if (comptime strict) break :blk false; // js_strict_eq2: tag1 != tag2 ⇒ FALSE
                    break :blk null; // loose bool vs non-bool needs ToNumber
                }
                if (lhs.is(.null_value) or lhs.is(.undefined_value)) {
                    // qjs strict: null===null and undefined===undefined, but null!==undefined.
                    if (comptime strict) break :blk lhs.tagOf() == rhs.tagOf();
                    // Loose: null==undefined is TRUE.
                    if (rhs.is(.null_value) or rhs.is(.undefined_value)) break :blk true;
                    if (rhs.is(.object)) break :blk value_ops.isHTMLDDA(rhs); // qjs 20324-20327
                    break :blk null;
                }
                // qjs js_string_eq: loose and strict agree for two strings; `same`
                // short-circuits the shared-body case.
                if (lhs.isString() and rhs.isString()) {
                    if (lhs.same(rhs)) break :blk true;
                    // Flat pair is qjs's inline arm (length, identity, one memcmp);
                    // ropes never reach it there. compareStringValues opens two
                    // iterators before it can compare lengths, so keep it for ropes.
                    if (lhs.tagOf() == core.Tag.string and rhs.tagOf() == core.Tag.string) {
                        break :blk core.string.flatStringsEq(
                            core.string.String.fromHeader(lhs.stringHeaderAssumeStringLike()),
                            core.string.String.fromHeader(rhs.stringHeaderAssumeStringLike()),
                        );
                    }
                    break :blk (core.string.compareStringValues(lhs, rhs, true) orelse 1) == 0;
                }
                break :blk null;
            };

            const res = resolved orelse
                return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });

            (sp - 2)[0] = JSValue.boolean(res != inv); // qjs JS_NewBool(ctx, res ^ inv)
            const nsp = sp - 1;
            vm.stack.setTopPtr(nsp);
            return cont(pc + 1, nsp, var_buf, vm);
        }
    }.handler;
}

/// No-`bl` mixed body: the int leaf and `eq_if_false8` tail here through the
/// `zjs_cmp_*_mixed` export. Flat same-width string pairs compare in-leaf (qjs
/// js_strict_eq2 → js_string_eq: length, identity, unit scan); ropes, cross-width
/// pairs and last-reference releases tail the framed export instead.
fn opCompareEqFast(comptime opc: u8) Handler {
    return struct {
        fn handler(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome {
            const strict = comptime (opc == op.strict_eq or opc == op.strict_neq);
            const inv = comptime (opc == op.neq or opc == op.strict_neq);
            const lhs = (sp - 2)[0];
            const rhs = (sp - 1)[0];

            const resolved: ?bool = blk: {
                // qjs string arm: JS_TAG_STRING × JS_TAG_STRING calls js_string_eq in
                // the dispatch loop; a rope carries a different tag and never reaches it.
                if (lhs.tagOf() == core.Tag.string and rhs.tagOf() == core.Tag.string) {
                    break :blk core.string.flatStringsEqNear(
                        core.string.String.fromHeader(lhs.stringHeaderAssumeStringLike()),
                        core.string.String.fromHeader(rhs.stringHeaderAssumeStringLike()),
                    ) orelse
                        return @call(.always_tail, compareEqFramedExport(opc), .{ pc, sp, var_buf, vm });
                }
                if (lhs.isString() and rhs.isString()) {
                    return @call(.always_tail, compareEqFramedExport(opc), .{ pc, sp, var_buf, vm });
                }
                if (lhs.as(.int)) |a| {
                    if (rhs.as(.float64)) |d2| break :blk @as(f64, @floatFromInt(a)) == d2;
                    break :blk if (comptime strict) false else null;
                }
                if (lhs.as(.float64)) |d1| {
                    if (rhs.as(.int)) |b| break :blk d1 == @as(f64, @floatFromInt(b));
                    if (rhs.as(.float64)) |d2| break :blk d1 == d2;
                    break :blk if (comptime strict) false else null;
                }
                if (lhs.is(.object)) {
                    if (rhs.is(.object)) {
                        break :blk lhs.refHeaderAssumeObject() == rhs.refHeaderAssumeObject();
                    }
                    if (comptime strict) break :blk false;
                    if (rhs.is(.null_value) or rhs.is(.undefined_value)) break :blk core.value_semantics.isHTMLDDA(lhs);
                    break :blk null;
                }
                if (lhs.as(.boolean)) |a| {
                    if (rhs.as(.boolean)) |b| break :blk a == b;
                    if (comptime strict) break :blk false;
                    break :blk null;
                }
                if (lhs.is(.null_value) or lhs.is(.undefined_value)) {
                    if (comptime strict) break :blk lhs.tagOf() == rhs.tagOf();
                    if (rhs.is(.null_value) or rhs.is(.undefined_value)) break :blk true;
                    if (rhs.is(.object)) break :blk core.value_semantics.isHTMLDDA(rhs);
                    break :blk null;
                }
                // Same-type Symbols compare by identity (qjs js_strict_eq2). Loose
                // Symbol/object equality needs ToPrimitive on the cold path.
                if (lhs.is(.symbol)) {
                    if (rhs.is(.symbol)) break :blk lhs.same(rhs);
                    if (comptime strict) break :blk false;
                }
                break :blk null;
            };

            const res = resolved orelse
                return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });

            (sp - 2)[0] = JSValue.boolean(res != inv);
            const nsp = sp - 1;
            vm.stack.setTopPtr(nsp);
            return cont(pc + 1, nsp, var_buf, vm);
        }
    }.handler;
}

/// ELF-visible mixed-type entries so the int leaf can tail a PC-relative `b`
/// without a table load. Same `callconv(.c)` as `Handler` (`noinline` would break
/// `always_tail`). `eq_if_false8` jumps `zjs_cmp_eq_mixed` directly.
fn compareEqExport(comptime opc: u8) Handler {
    return switch (opc) {
        op.eq => &zjs_cmp_eq_mixed,
        op.neq => &zjs_cmp_neq_mixed,
        op.strict_eq => &zjs_cmp_strict_eq_mixed,
        op.strict_neq => &zjs_cmp_strict_neq_mixed,
        else => unreachable,
    };
}

fn compareEqFramedExport(comptime opc: u8) Handler {
    return switch (opc) {
        op.eq => &zjs_cmp_eq_framed,
        op.neq => &zjs_cmp_neq_framed,
        op.strict_eq => &zjs_cmp_strict_eq_framed,
        op.strict_neq => &zjs_cmp_strict_neq_framed,
        else => unreachable,
    };
}

export fn zjs_cmp_eq_mixed(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return @call(.always_tail, opCompareEqFast(op.eq), .{ pc, sp, var_buf, vm });
}
export fn zjs_cmp_neq_mixed(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return @call(.always_tail, opCompareEqFast(op.neq), .{ pc, sp, var_buf, vm });
}
export fn zjs_cmp_strict_eq_mixed(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return @call(.always_tail, opCompareEqFast(op.strict_eq), .{ pc, sp, var_buf, vm });
}
export fn zjs_cmp_strict_neq_mixed(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return @call(.always_tail, opCompareEqFast(op.strict_neq), .{ pc, sp, var_buf, vm });
}

export fn zjs_cmp_eq_framed(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return @call(.always_tail, opCompareEq(op.eq), .{ pc, sp, var_buf, vm });
}
export fn zjs_cmp_neq_framed(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return @call(.always_tail, opCompareEq(op.neq), .{ pc, sp, var_buf, vm });
}
export fn zjs_cmp_strict_eq_framed(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return @call(.always_tail, opCompareEq(op.strict_eq), .{ pc, sp, var_buf, vm });
}
export fn zjs_cmp_strict_neq_framed(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) callconv(.c) Outcome {
    return @call(.always_tail, opCompareEq(op.strict_neq), .{ pc, sp, var_buf, vm });
}

/// Cold-table handler for OP_mod after its positive-int32 arm misses. qjs
/// js_binary_arith_slow tests both-number first and calls fmod before ToNumeric;
/// keep that order without publishing. Stop boundaries and non-numbers go generic.
pub fn op_mod_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    if (!vm.local_fast_blocked) {
        if (value_ops.numberValue((sp - 2)[0])) |lhs| {
            if (value_ops.numberValue((sp - 1)[0])) |rhs| {
                (sp - 2)[0] = JSValue.float64(@rem(lhs, rhs));
                return cont(pc + 1, sp - 1, var_buf, vm);
            }
        }
    }
    vm.publish(pc, sp);
    vm_arith.binaryVm(vm, pc[0]) catch |err| return vm.fail(err);
    return coldNext(var_buf, vm);
}

/// Cold-table handler for OP_div after its both-int32 arm misses. qjs's slow path
/// stores a BARE float64 quotient (no int canonicalization; the both-int leg
/// already ran in opBinary), so a plain float divide stays register-resident.
/// numberValue rejects BigInt/string/object, which keep the generic path.
pub fn op_div_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    if (!vm.local_fast_blocked) {
        if (value_ops.numberValue((sp - 2)[0])) |lhs| {
            if (value_ops.numberValue((sp - 1)[0])) |rhs| {
                (sp - 2)[0] = JSValue.float64(lhs / rhs);
                return cont(pc + 1, sp - 1, var_buf, vm);
            }
        }
    }
    vm.publish(pc, sp);
    vm_arith.binaryVm(vm, pc[0]) catch |err| return vm.fail(err);
    return coldNext(var_buf, vm);
}

/// ToInt32 for the tags whose ToNumeric is total, pure and allocation-free
/// (int, bool, float64 — qjs JS_ToNumericFree is the identity or a 0/1 widen).
/// Every other tag returns null and keeps the generic shell: string parses, object
/// runs user code, symbol throws, BigInt takes its own arm. The float leg uses the
/// same modulo-2^32 wrap as `value_ops.toInt32`, so results are bit-identical.
inline fn logicOperandInt32(v: JSValue) ?i32 {
    if (v.as(.int)) |i| return i;
    if (v.as(.boolean)) |b| return @intFromBool(b);
    if (v.as(.float64)) |d| return @bitCast(coercion_ops.toUint32Number(d));
    return null;
}

/// Cold-table handler for the six bitwise / shift ops after their both-int32 arm
/// missed (qjs js_binary_logic_slow / js_shr_slow, which work in place on sp[-2]).
/// With both operands resolved by `logicOperandInt32` this is qjs's closing
/// `JS_ToInt32Free` + `switch(op)` leg; the expressions match `value_ops.binary`'s
/// bitwise leg so fast and shell results are bit-identical, and all accepted tags
/// are non-refcounted. BigInt/string/object/symbol and the generator stop boundary
/// (`local_fast_blocked`) fall to the publishing shell. One shared handler reads
/// `pc[0]`; the miss path already forwards it to `binaryVm`.
pub fn opLogicCold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    if (!vm.local_fast_blocked) {
        if (logicOperandInt32((sp - 2)[0])) |v1| {
            if (logicOperandInt32((sp - 1)[0])) |v2| {
                switch (pc[0]) {
                    // qjs js_shr_slow → JS_NewUint32: int32 while the u32 fits, else
                    // the exact double (same split as OP_shr's int leg).
                    op.shr => {
                        const r = @as(u32, @bitCast(v1)) >> @intCast(v2 & 31);
                        if (r <= std.math.maxInt(i32)) {
                            (sp - 2)[0] = JSValue.int32(@intCast(r));
                        } else {
                            (sp - 2)[0] = JSValue.float64(@floatFromInt(r));
                        }
                    },
                    op.shl => (sp - 2)[0] = JSValue.int32(v1 << @intCast(v2 & 31)),
                    op.sar => (sp - 2)[0] = JSValue.int32(v1 >> @intCast(v2 & 31)),
                    op.@"and" => (sp - 2)[0] = JSValue.int32(v1 & v2),
                    op.@"or" => (sp - 2)[0] = JSValue.int32(v1 | v2),
                    op.xor => (sp - 2)[0] = JSValue.int32(v1 ^ v2),
                    else => unreachable,
                }
                return cont(pc + 1, sp - 1, var_buf, vm);
            }
        }
    }
    vm.publish(pc, sp);
    vm_arith.binaryVm(vm, pc[0]) catch |err| return vm.fail(err);
    return coldNext(var_buf, vm);
}

/// Cold handler for the compare ops' non-(both-int32) operands (qjs
/// js_relational_slow / js_eq_slow). Installed as the cold_table entry so the
/// opCompare handlers reach it through the indirect `cold_table[pc[0]]` dispatch;
/// a direct tail call would let LLVM fold it back into the int32 leaf.
/// `compareAt` runs register-resident and writes sp[-2] + pops one like the int
/// arm; at the generator stop boundary (`local_fast_blocked`) it takes the
/// publishing path so coldNext's maybeStop still fires. Generated per opcode so
/// the predicate is comptime.
pub fn opCompareCold(comptime opc: u8) Handler {
    return struct {
        fn handler(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
            if (vm.local_fast_blocked) {
                vm.publish(pc, sp);
                vm_arith.compareVm(vm, opc) catch |e| return vm.fail(e);
                return coldNext(var_buf, vm);
            }
            const lhs = (sp - 2)[0];
            const rhs = (sp - 1)[0];
            vm.syncPc(pc, 1); // qjs sf->cur_pc — backtrace fidelity through ToPrimitive valueOf (compare ops are 1 byte)
            // `compareAt` runs ToPrimitive (user code that allocates and can
            // collect); sync the operand boundary so both operands and everything
            // pushed since the last publish are rooted.
            vm.syncSp(sp);
            const result = vm_arith.compareAt(opc, vm.ctx, vm.global, vm.output, lhs, rhs) catch |err| {
                // Error only: compareAt freed both operands, so publish the doubly-popped sp
                // (frame.pc → next op) for a consistent catch stack.
                vm.publish(pc, sp - 2);
                const caught = deliverCatchable(vm, err) catch |e2| return vm.fail(e2);
                if (!caught) return vm.fail(err);
                return coldNext(var_buf, vm);
            };
            (sp - 2)[0] = result;
            return cont(pc + 1, sp - 1, var_buf, vm);
        }
    }.handler;
}

/// Delivery of an instanceof method-lookup error: pop the two operands and try
/// the caller-frame catch, without the generic cold shell's pop/defer/push.
fn op_instanceof_lookup_error(
    pc: [*]const u8,
    sp: [*]JSValue,
    var_buf: [*]JSValue,
    vm: *Vm,
) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    _ = sp;
    const err = vm.pending_error;
    call_runtime.popOwnedStackRegion(vm.stack, vm.stack.len() - 2);
    const caught = deliverCatchable(vm, err) catch |e2| return vm.fail(e2);
    if (!caught) return vm.fail(err);
    _ = pc;
    return coldNext(var_buf, vm);
}

const InternalMethodDispatch = enum { completed, caught, threw };

inline fn transformInternalCallResult(
    comptime return_action: inline_calls.ReturnAction,
    result: JSValue,
) JSValue {
    comptime std.debug.assert(return_action == .next or return_action == .to_boolean);
    if (comptime return_action == .to_boolean) {
        if (result.is(.boolean)) return result;
        const boolean = JSValue.boolean(coercion_ops.valueTruthy(result));
        return boolean;
    }
    return result;
}

noinline fn recoverOwnedInternalCallRegion(
    vm: *Vm,
    region_base: usize,
    err: HostError,
) InternalMethodDispatch {
    call_runtime.popOwnedStackRegion(vm.stack, region_base);
    const caught = deliverCatchable(vm, err) catch |e2| {
        vm.pending_error = e2;
        return .threw;
    };
    if (caught) return .caught;
    vm.pending_error = err;
    return .threw;
}

/// Native adapter behind the internal method-call seam. The caller supplies an
/// owned method region `[receiver, callable, args...]`; the wide call environment
/// and error union stay inside this outlined body so resident handlers keep the
/// compact single-enum ABI. The miss arm is outlined separately so its stores
/// cannot enlarge this shell.
noinline fn dispatchInternalNativeMethod(
    comptime return_action: inline_calls.ReturnAction,
    comptime argc: u16,
    vm: *Vm,
    method_object: *core.Object,
    record: *const core.NativeEntry,
    region_base: usize,
) InternalMethodDispatch {
    comptime std.debug.assert(return_action == .next or return_action == .to_boolean);
    const stack = vm.stack;
    const region_count = @as(usize, argc) + 2;
    if (stack.len() != region_base + region_count) {
        vm.pending_error = error.InvalidBytecode;
        return .threw;
    }
    const receiver = stack.values[region_base];
    const args = stack.values[region_base + 2 ..][0..argc];
    exception_ops.pollInterrupt(vm.ctx, vm.global) catch |err| {
        return recoverOwnedInternalCallRegion(vm, region_base, err);
    };
    return dispatchInternalNativeMethodSlow(return_action, argc, vm, method_object, record, region_base, receiver, args);
}

/// Miss/cold arm: records without exec_direct take `callResolvedNativeMethod`
/// plus the ToBoolean wrapper. `noinline` keeps its environment stores out of
/// `dispatchInternalNativeMethod`.
noinline fn dispatchInternalNativeMethodSlow(
    comptime return_action: inline_calls.ReturnAction,
    comptime argc: u16,
    vm: *Vm,
    method_object: *core.Object,
    record: *const core.NativeEntry,
    region_base: usize,
    receiver: JSValue,
    args: []const JSValue,
) InternalMethodDispatch {
    _ = argc;
    const native_result = vm_call.callResolvedNativeMethod(
        vm.ctx,
        vm.output,
        vm.global,
        method_object,
        record,
        receiver,
        args,
        vm.function,
        vm.frame,
    ) catch |err| {
        return recoverOwnedInternalCallRegion(vm, region_base, err);
    };
    const result = transformInternalCallResult(return_action, native_result);
    call_runtime.popOwnedStackRegion(vm.stack, region_base);
    vm.stack.pushOwnedAssumeCapacity(result);
    return .completed;
}

/// Enter a same-Machine bytecode method whose source already occupies the
/// standard retreated `[receiver, callable, args...]` region. The call frame
/// remains authoritative; this adapter adds only semantic post-call work.
inline fn pushInternalMethodAndEnter(
    comptime return_action: inline_calls.ReturnAction,
    comptime argc: u16,
    var_buf: [*]JSValue,
    vm: *Vm,
    target: *const inline_calls.InlineTarget,
    region_start: [*]JSValue,
) Outcome {
    comptime std.debug.assert(return_action != .next);
    const source_count = @as(usize, argc) + 2;
    if (pollRetreatedCallRegion(vm, region_start, source_count)) return .threw;
    const entry = vm.machine.pushMethodCall(vm.global, vm.stack, target, region_start, argc) catch |err| {
        if (!callSetupRecover(vm, err)) return .threw;
        return coldNext(var_buf, vm);
    };
    entry.return_action = return_action;
    return enterEntry(vm, entry, target.fb.byteCodeAssumeMaterialized().ptr);
}

/// Deep remainder for one internal method-call shape after a resident caller
/// tried the generic resolved-native leg. Result action and arity are comptime;
/// every instance keeps the exact `Handler` ABI for stackless must-tail dispatch.
fn internalMethodRemainderHandler(
    comptime return_action: inline_calls.ReturnAction,
    comptime argc: u16,
) Handler {
    comptime std.debug.assert(return_action != .next);
    return struct {
        fn handler(resume_pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
            const stack = vm.stack;
            const region_count = @as(usize, argc) + 2;
            const region_start = sp - region_count;
            std.debug.assert(stack.topPtr() == sp);
            const region_base = stack.len() - region_count;
            const receiver = region_start[0];
            const method = region_start[1];

            if (object_ops.objectFromValue(method)) |method_object| {
                if (method_object.class_id == core.class.ids.bytecode_function) {
                    if (inline_calls.resolveInlineFunctionFromObject(vm.global, method_object)) |resolved| {
                        stack.retreatToCallRegion(&vm.machine.pending_call_region, region_start);
                        const execution = resolved.call_facts.execution;
                        const leaf_kind = execution.exact_args_leaf_kind;
                        if (leaf_kind != .none and argc == resolved.fb.arg_count) {
                            const captures = resolved.var_refs[0..resolved.fb.closureVarCount()];
                            if (leaf_kind == .sloppy) {
                                return pushWarmExactArgsLeafAndEnter(.receiver, return_action, var_buf, vm, resolved.fb, resolved.call_facts, captures, region_start, argc, resume_pc, resolved.fb.byteCode().ptr);
                            }
                            return pushExactArgsLeafAndEnter(.receiver, return_action, var_buf, vm, resolved.fb, resolved.call_facts, captures, region_start, argc, resolved.fb.byteCode().ptr);
                        }
                        const target = resolved.bind(receiver, method);
                        return pushInternalMethodAndEnter(return_action, argc, var_buf, vm, &target, region_start);
                    }
                }
            }

            const args = region_start[2..][0..argc];
            const call_result = call_runtime.callValueOrBytecodeRoot(vm.ctx, vm.output, vm.global, receiver, method, args, vm.function, vm.frame) catch |err| {
                return switch (recoverOwnedInternalCallRegion(vm, region_base, err)) {
                    .caught => coldNext(var_buf, vm),
                    .threw => .threw,
                    .completed => unreachable,
                };
            };
            const result = transformInternalCallResult(return_action, call_result);
            call_runtime.popOwnedStackRegion(stack, region_base);
            stack.pushOwnedAssumeCapacity(result);
            return cont(resume_pc, stack.topPtr(), var_buf, vm);
        }
    }.handler;
}

/// qjs js_operator_instanceof epilogue after a successful JS_IsInstanceOf: free
/// both operands and write the bool at sp[-2]. When Get resolved the default
/// `Function.prototype[@@hasInstance]`, invoke OrdinaryHasInstance directly.
noinline fn completeOrdinaryInstanceof(vm: *Vm) InternalMethodDispatch {
    const region_base = vm.stack.len() - 2;
    const lhs = vm.stack.values[region_base];
    const rhs = vm.stack.values[region_base + 1];
    const result = call_runtime.ordinaryHasInstance(
        vm.ctx,
        vm.output,
        vm.global,
        rhs,
        lhs,
        vm.function,
        vm.frame,
    ) catch |err| {
        return recoverOwnedInternalCallRegion(vm, region_base, err);
    };
    call_runtime.popOwnedStackRegion(vm.stack, region_base);
    vm.stack.pushOwnedAssumeCapacity(JSValue.boolean(result));
    return .completed;
}

/// Authoritative slow completion for a null/undefined `@@hasInstance`, primitive
/// RHS rejection, and the rare stack-without-a-spare-slot case.
noinline fn completeInstanceofSlow(vm: *Vm, has_instance: JSValue) InternalMethodDispatch {
    const region_base = vm.stack.len() - 2;
    const lhs = vm.stack.values[region_base];
    const rhs = vm.stack.values[region_base + 1];
    const result = call_runtime.instanceofValueWithMethod(vm.ctx, vm.output, vm.global, lhs, rhs, has_instance, vm.function, vm.frame) catch |err| {
        return recoverOwnedInternalCallRegion(vm, region_base, err);
    };
    call_runtime.popOwnedStackRegion(vm.stack, region_base);
    vm.stack.pushOwnedAssumeCapacity(JSValue.boolean(result));
    return .completed;
}

/// qjs JS_IsInstanceOf probe (GetProperty of Symbol.hasInstance) plus the
/// Ordinary walk when the method is the realm default
/// `Function.prototype[@@hasInstance]`. Mirrors qjs's lookup shape: own-hash
/// miss, one proto hop, slot vs default record, no generic probe loop. An own or
/// intermediate custom `@@hasInstance` returns null so the published remainder Calls.
inline fn tryFastDefaultInstanceof(lhs: JSValue, ctor: *core.Object, vm: *Vm) ?bool {
    if (ctor.isProxy()) return null;
    if (ctor.class_id == core.class.ids.bound_function) return null;

    const has_instance_atom = comptime core.atom.predefinedId("Symbol.hasInstance", .symbol).?;
    var slow = false;
    const method_slot: *const JSValue = blk: {
        if (ctor.findOwnDataSlotFast(has_instance_atom, &slow)) |slot| break :blk slot;
        if (slow or ctor.flags.has_exotic_methods) return null;
        const proto = ctor.getPrototype() orelse return null;
        if (proto.flags.has_exotic_methods) return null;
        slow = false;
        break :blk proto.findOwnDataSlotFast(has_instance_atom, &slow) orelse return null;
    };
    if (slow) return null;

    const method_object = object_ops.objectFromValue(loadValueAsIntPair(method_slot)) orelse return null;
    if (method_object.class_id != core.class.ids.c_function) return null;
    const record = method_object.nativeEntryAssumeCFunction() orelse
        vm_call.resolvedNativeMethodRecordAssumeCFunction(vm.ctx, method_object) orelse return null;
    if (!function_ops.recordIsDefaultHasInstance(record)) return null;

    // qjs: JS_IsFunction, then GetProperty(prototype).
    if (!call_runtime.isFunctionLikeClass(ctor.class_id)) return false;
    var proto_slow = false;
    const proto_slot = ctor.findOwnDataSlotFast(core.atom.ids.prototype, &proto_slow) orelse return null;
    if (proto_slow) return null;
    const proto = object_ops.objectFromValue(loadValueAsIntPair(proto_slot)) orelse return null;

    const start = object_ops.objectFromValue(lhs) orelse return false;
    if (start.isProxy()) return null;
    var walk = start.getPrototype();
    while (walk) |parent| {
        if (parent.isProxy()) return null;
        if (parent == proto) return true;
        walk = parent.getPrototype();
    }
    return false;
}

/// Published remainder of OP_instanceof (qjs `sf->cur_pc = pc` then
/// js_operator_instanceof). Reached only when the default hasInstance walk cannot
/// finish resident: non-object RHS, exotic / Proxy / bound, missing own-data
/// `.prototype`, or a non-default `@@hasInstance`.
fn op_instanceof_published(
    pc: [*]const u8,
    sp: [*]JSValue,
    var_buf: [*]JSValue,
    vm: *Vm,
) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome {
    vm.publish(pc, sp);
    const rhs = loadValueAsIntPair(&(sp - 1)[0]);
    const rhs_object = object_ops.objectFromValue(rhs) orelse {
        switch (completeInstanceofSlow(vm, JSValue.undefinedValue())) {
            .completed => return cont(pc + 1, vm.stack.topPtr(), var_buf, vm),
            .caught => return coldNext(var_buf, vm),
            .threw => return .threw,
        }
    };
    const has_instance_atom = comptime core.atom.predefinedId("Symbol.hasInstance", .symbol).?;
    const fast_method = object_ops.probePublicNamedDataPropertyFromObject(rhs_object, has_instance_atom);
    const has_instance = if (fast_method.slot) |slot|
        loadValueAsIntPair(slot)
    else if (!fast_method.needs_slow)
        JSValue.undefinedValue()
    else
        call_runtime.instanceofMethodSlow(vm.ctx, vm.output, vm.global, rhs, vm.function, vm.frame) catch |err| {
            vm.pending_error = err;
            return @call(.always_tail, op_instanceof_lookup_error, .{ pc, sp, var_buf, vm });
        };
    if (has_instance.is(.undefined_value) or has_instance.is(.null_value) or vm.stack.len() == vm.stack.capacity) {
        switch (completeInstanceofSlow(vm, has_instance)) {
            .completed => return cont(pc + 1, vm.stack.topPtr(), var_buf, vm),
            .caught => return coldNext(var_buf, vm),
            .threw => return .threw,
        }
    }
    if (object_ops.objectFromValue(has_instance)) |method_object| {
        if (vm_call.resolvedNativeMethodRecord(vm.ctx, method_object)) |record| {
            if (function_ops.isDefaultHasInstanceRecord(vm.ctx.runtime, record)) {
                switch (completeOrdinaryInstanceof(vm)) {
                    .completed => return cont(pc + 1, vm.stack.topPtr(), var_buf, vm),
                    .caught => return coldNext(var_buf, vm),
                    .threw => return .threw,
                }
            }
        }
    }
    // Transfer `[lhs, rhs]` plus the owned method into the one standard method
    // region used by native, exact-leaf, and general same-Machine calls. Each
    // owner moves once; no result or method is cached across the operation.
    const region_start = sp - 2;
    const lhs = region_start[0];
    region_start[0] = rhs;
    region_start[1] = has_instance;
    region_start[2] = lhs;
    vm.stack.setTopPtr(region_start + 3);
    if (object_ops.objectFromValue(has_instance)) |method_object| {
        if (vm_call.resolvedNativeMethodRecord(vm.ctx, method_object)) |record| {
            switch (dispatchInternalNativeMethod(.to_boolean, 1, vm, method_object, record, vm.stack.len() - 3)) {
                .completed => return cont(pc + 1, vm.stack.topPtr(), var_buf, vm),
                .caught => return coldNext(var_buf, vm),
                .threw => return .threw,
            }
        }
    }
    return @call(.always_tail, Opaque(internalMethodRemainderHandler(.to_boolean, 1)).get(), .{ pc + 1, region_start + 3, var_buf, vm });
}

pub fn op_instanceof(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
    if (vm.local_fast_blocked) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    // qjs OP_instanceof: JS_IsInstanceOf then in-place free/replace of the two
    // operand slots. The default Function.prototype[@@hasInstance] walk cannot
    // throw for ordinary objects with an own-data object `.prototype`, so it needs
    // no pc publish; hop to the published remainder only when the path can throw
    // or must Call a non-default method.
    const rhs = loadValueAsIntPair(&(sp - 1)[0]);
    const rhs_object = object_ops.objectFromValue(rhs) orelse
        return @call(.always_tail, op_instanceof_published, .{ pc, sp, var_buf, vm });
    if (tryFastDefaultInstanceof((sp - 2)[0], rhs_object, vm)) |hit| {
        const nsp = sp - 1;
        (sp - 2)[0] = JSValue.boolean(hit);
        vm.stack.setTopPtr(nsp);
        return cont(pc + 1, nsp, var_buf, vm);
    }
    return @call(.always_tail, op_instanceof_published, .{ pc, sp, var_buf, vm });
}

/// qjs OP_neg's local numeric arms: int, bool and null share the integer arm
/// (zero and INT32_MIN promote to float64); float64 negates in place. Values
/// needing ToNumeric (string/object/BigInt/Symbol/undefined) take the generic shell.
pub fn op_neg(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    if (value.as(.int)) |iv| {
        if (iv == 0) {
            (sp - 1)[0] = JSValue.float64(-0.0);
        } else if (iv == std.math.minInt(i32)) {
            (sp - 1)[0] = JSValue.float64(-@as(f64, @floatFromInt(iv)));
        } else {
            (sp - 1)[0].setInt32AssumeInt(-iv);
        }
        return cont(pc + 1, sp, var_buf, vm);
    }
    if (value.as(.boolean)) |b| {
        (sp - 1)[0] = if (b) JSValue.int32(-1) else JSValue.float64(-0.0);
        return cont(pc + 1, sp, var_buf, vm);
    }
    if (value.is(.null_value)) {
        (sp - 1)[0] = JSValue.float64(-0.0);
        return cont(pc + 1, sp, var_buf, vm);
    }
    if (value.as(.float64)) |d| {
        (sp - 1)[0] = JSValue.float64(-d);
        return cont(pc + 1, sp, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

// I-cache pin (see op_return).
pub fn op_inc_dec(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
    const opc = pc[0];
    if ((sp - 1)[0].as(.int)) |iv| {
        const res = if (opc == op.inc) @addWithOverflow(iv, 1) else @subWithOverflow(iv, 1);
        if (res[1] == 0) {
            (sp - 1)[0].setInt32AssumeInt(res[0]);
            return cont(pc + 1, sp, var_buf, vm);
        }
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

// qjs OP_post_inc/OP_post_dec int fast leg: the old int stays at sp[-1], the
// stepped int lands at sp[0] (the emitter's n_push=2 covers the slot). Overflow
// and non-int operands fall to the cold shell with the stack untouched.
pub fn op_post_inc_dec(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const opc = pc[0];
    if ((sp - 1)[0].as(.int)) |iv| {
        const res = if (opc == op.post_inc) @addWithOverflow(iv, 1) else @subWithOverflow(iv, 1);
        if (res[1] == 0) {
            sp[0] = JSValue.int32(res[0]);
            return cont(pc + 1, sp + 1, var_buf, vm);
        }
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

pub fn op_dup(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome {
    const v = (sp - 1)[0];
    // JSValue.dup owns the refcount-tag gate (qjs JS_DupValue); a caller-side
    // gate would only materialize a selection temporary.
    sp[0] = v;
    return cont(pc + 1, sp + 1, var_buf, vm);
}

/// qjs OP_insert2: `obj value -> value obj value`. The top slot moves to the new
/// top and exactly one duplicate owns the new bottom copy; nothing is released.
pub fn op_insert2(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    sp[0] = value;
    (sp - 1)[0] = (sp - 2)[0];
    (sp - 2)[0] = value;
    return cont(pc + 1, sp + 1, var_buf, vm);
}

/// qjs OP_insert3: `obj key value -> value obj key value`. As with OP_insert2,
/// only the copied value gains an owner; the other slots are raw moves.
pub fn op_insert3(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    sp[0] = value;
    (sp - 1)[0] = (sp - 2)[0];
    (sp - 2)[0] = (sp - 3)[0];
    (sp - 3)[0] = value;
    return cont(pc + 1, sp + 1, var_buf, vm);
}

/// qjs OP_perm3: `obj old value -> old obj value`, a pure two-slot move.
pub fn op_perm3(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    // Keep both 16-byte values in integer pairs: whole-JSValue assignment makes
    // LLVM use q registers and spill a temporary to the native stack for this swap.
    const old = loadValueAsIntPair(&(sp - 2)[0]);
    const object = loadValueAsIntPair(&(sp - 3)[0]);
    storeValueAsIntPair(&(sp - 2)[0], object);
    storeValueAsIntPair(&(sp - 3)[0], old);
    return cont(pc + 1, sp, var_buf, vm);
}

pub fn op_swap(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const tmp = (sp - 2)[0];
    (sp - 2)[0] = (sp - 1)[0];
    (sp - 1)[0] = tmp;
    return cont(pc + 1, sp, var_buf, vm);
}

// Control flow (8-bit displacement, relative to the operand byte pc+1). Branch
// targets never reach code_end: the jump-aware epilogues terminate every
// branch-to-end path with a real return op and finalize rejects reachable
// falloff, so no bounds test is needed.
inline fn jump8Target(pc: [*]const u8, vm: *Vm) [*]const u8 {
    const operand_pc = @intFromPtr(pc + 1) - @intFromPtr(vm.code_base);
    const diff: i8 = @bitCast(pc[1]);
    return vm.code_base + @as(usize, @intCast(@as(i64, @intCast(operand_pc)) + @as(i64, diff)));
}
// I-cache pin (see op_return).
pub fn op_goto8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
    // qjs OP_goto polls interrupts on every unconditional jump (the loop back
    // edge). The inline leg is a bare cadence decrement; a hit re-executes this
    // op through cold_table (an indirect route LLVM cannot fold back), whose
    // publishing poll decrements again, still lands at <=0 and runs the handler.
    if (vm.ctx.pollInterruptTick())
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    return cont(jump8Target(pc, vm), sp, var_buf, vm);
}

/// 16-bit twin of `jump8Target` (displacement relative to the operand byte).
inline fn jump16Target(pc: [*]const u8, vm: *Vm) [*]const u8 {
    const operand_pc = @intFromPtr(pc + 1) - @intFromPtr(vm.code_base);
    const diff = readInt(i16, pc + 1);
    return vm.code_base + @as(usize, @intCast(@as(i64, @intCast(operand_pc)) + @as(i64, diff)));
}

/// Wide `goto16` (qjs OP_goto16). Same tick / cold-poll contract as `op_goto8`.
pub fn op_goto16(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
    if (vm.ctx.pollInterruptTick())
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    return cont(jump16Target(pc, vm), sp, var_buf, vm);
}

/// Wide `goto` (4-byte label, qjs OP_goto). Same tick / cold-poll contract as `op_goto8`.
pub fn op_goto(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
    if (vm.ctx.pollInterruptTick())
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    return cont(jump32Target(pc, vm), sp, var_buf, vm);
}
// Immediate scalars (int/bool/null/undefined) branch inline. Values needing
// JS_ToBoolFree tail through the resident continuation table after the interrupt
// tick, carrying the original pc/sp instead of publishing and reloading them.
// Plain objects take qjs JS_ToBoolFree's object leg inline; HTMLDDA objects use
// the same narrow continuation because their flag is falsy.
// I-cache pin (see op_return).
pub fn op_if_false8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    if (value.asBranchImmediateBool()) |b| {
        // Cadence tick only; a hit routes to the cold branch8, which re-executes
        // the untouched operand with the publishing poll (see op_goto8).
        if (vm.ctx.pollInterruptTick())
            return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
        if (!b) return cont(jump8Target(pc, vm), sp - 1, var_buf, vm);
        return cont(pc + 2, sp - 1, var_buf, vm);
    }
    if (value.is(.object)) {
        // HTMLDDA falls through to the resident complex handler. branch8 consumes
        // its operand, so shrink the GC root window before the inline release,
        // just as stack.pop() does in the generic helper.
        if (!core.value_semantics.isHTMLDDA(value)) {
            if (vm.ctx.pollInterruptTick())
                return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
            const nsp = sp - 1;
            vm.stack.setTopPtr(nsp);
            return cont(pc + 2, nsp, var_buf, vm);
        }
    }
    // qjs performs JS_ToBoolFree before its poll. Tick here so the continuation
    // stays state-local; only a cadence hit uses the publishing shell.
    if (vm.ctx.pollInterruptTick())
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    return @call(.always_tail, residentTailHandler(vm, .if_false8_complex), .{ pc, sp, var_buf, vm });
}

fn op_if_false8_complex(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    const truthy = core.value_semantics.toBoolean(value);
    const nsp = sp - 1;
    // The consumed value may own an object/string/heap BigInt. Publish only
    // the shorter GC root window needed by its destructor; pc and the next sp
    // stay register-resident and coldNext is never entered.
    vm.stack.setTopPtr(nsp);
    if (!truthy) return cont(jump8Target(pc, vm), nsp, var_buf, vm);
    return cont(pc + 2, nsp, var_buf, vm);
}
pub fn op_if_true8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    if (value.asBranchImmediateBool()) |b| {
        if (vm.ctx.pollInterruptTick())
            return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
        if (b) return cont(jump8Target(pc, vm), sp - 1, var_buf, vm);
        return cont(pc + 2, sp - 1, var_buf, vm);
    }
    if (value.is(.object)) {
        // See op_if_false8: non-HTMLDDA objects are truthy, and the consumed
        // operand's root must be removed before its inline rc==1 destruction.
        if (core.value_semantics.isHTMLDDA(value)) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
        if (vm.ctx.pollInterruptTick())
            return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
        const nsp = sp - 1;
        vm.stack.setTopPtr(nsp);
        return cont(jump8Target(pc, vm), nsp, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

// 32-bit twin of jump8Target (qjs OP_if_false: displacement relative to the
// operand byte, the same convention branch32 uses in the cold shell).
inline fn jump32Target(pc: [*]const u8, vm: *Vm) [*]const u8 {
    const operand_pc = @intFromPtr(pc + 1) - @intFromPtr(vm.code_base);
    const diff = readInt(i32, pc + 1);
    return vm.code_base + @as(usize, @intCast(@as(i64, @intCast(operand_pc)) + diff));
}
// Long-form conditional branch (4-byte label): the op_if_false8 body with the
// wide displacement. qjs OP_if_false classifies with the same unsigned tag
// comparison and polls on every execution; a cadence hit routes to the cold
// branch32 shell. Plain objects take JS_ToBoolFree's object leg inline; HTMLDDA
// and every remaining tag fall to the cold shell from the original pc/sp.
pub fn op_if_false(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    if (value.asBranchImmediateBool()) |b| {
        if (vm.ctx.pollInterruptTick())
            return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
        if (!b) return @call(.always_tail, next, .{ jump32Target(pc, vm), sp - 1, var_buf, vm });
        return cont(pc + 5, sp - 1, var_buf, vm);
    }
    if (value.is(.object)) {
        // See op_if_false8: guard before mutation so the cold handler re-executes
        // HTMLDDA from the original pc/sp; shrink the root window before the release.
        if (core.value_semantics.isHTMLDDA(value)) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
        if (vm.ctx.pollInterruptTick())
            return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
        const nsp = sp - 1;
        vm.stack.setTopPtr(nsp);
        return cont(pc + 5, nsp, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

/// `lt` then musttail `op_if_false8` at the following `if_false8`. Poll is
/// therefore the same function as the unfused `if_false8` (qjs CASE poll).
pub fn op_cmp_if_false8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
    if (JSValue.asInt32Pair((sp - 2)[0], (sp - 1)[0])) |ints| {
        (sp - 2)[0] = JSValue.boolean(ints.lhs < ints.rhs);
        return @call(.always_tail, op_if_false8, .{ pc + 1, sp - 1, var_buf, vm });
    }
    if ((sp - 2)[0].asNumber()) |fa| {
        if ((sp - 1)[0].asNumber()) |fb| {
            (sp - 2)[0] = JSValue.boolean(fa < fb);
            return @call(.always_tail, op_if_false8, .{ pc + 1, sp - 1, var_buf, vm });
        }
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

/// `eq` then musttail `op_if_false8`. The int32 hit stays on this leaf and tails
/// into `op_if_false8` (the poll lives there). Every other shape tails through
/// the `zjs_cmp_eq_mixed` export into the `opCompareEq(eq)` body, which `cont`s
/// onto the leftover `if_false8`; that entry must not switch on `pc[0]`.
pub fn op_eq_if_false8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
    const ints = JSValue.asInt32Pair((sp - 2)[0], (sp - 1)[0]) orelse
        return @call(.always_tail, zjs_cmp_eq_mixed, .{ pc, sp, var_buf, vm });
    (sp - 2)[0] = JSValue.boolean(ints.lhs == ints.rhs);
    return @call(.always_tail, op_if_false8, .{ pc + 1, sp - 1, var_buf, vm });
}

pub fn op_eq_if_false8_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    if (vm.local_fast_blocked) {
        vm.publish(pc, sp);
        vm_arith.compareVm(vm, op.eq) catch |e| return vm.fail(e);
        return coldNext(var_buf, vm);
    }
    const lhs = (sp - 2)[0];
    const rhs = (sp - 1)[0];
    vm.syncPc(pc, 1);
    vm.syncSp(sp); // see opCompareCold: ToPrimitive allocates, so the operand window must be live
    const result = vm_arith.compareAt(op.eq, vm.ctx, vm.global, vm.output, lhs, rhs) catch |err| {
        vm.publish(pc, sp - 2);
        const caught = deliverCatchable(vm, err) catch |e2| return vm.fail(e2);
        if (!caught) return vm.fail(err);
        return coldNext(var_buf, vm);
    };
    (sp - 2)[0] = result;
    return @call(.always_tail, op_if_false8, .{ pc + 1, sp - 1, var_buf, vm });
}

/// Slow `lt` then musttail `op_if_false8`. Indirect from the hot fused
/// handler via `cold_table` so the int32 arm stays a leaf (opCompareCold).
pub fn op_cmp_if_false8_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    if (vm.local_fast_blocked) {
        vm.publish(pc, sp);
        vm_arith.compareVm(vm, op.lt) catch |e| return vm.fail(e);
        return coldNext(var_buf, vm);
    }
    const lhs = (sp - 2)[0];
    const rhs = (sp - 1)[0];
    vm.syncPc(pc, 1);
    vm.syncSp(sp); // see opCompareCold: ToPrimitive allocates, so the operand window must be live
    const result = vm_arith.compareAt(op.lt, vm.ctx, vm.global, vm.output, lhs, rhs) catch |err| {
        vm.publish(pc, sp - 2);
        const caught = deliverCatchable(vm, err) catch |e2| return vm.fail(e2);
        if (!caught) return vm.fail(err);
        return coldNext(var_buf, vm);
    };
    (sp - 2)[0] = result;
    return @call(.always_tail, op_if_false8, .{ pc + 1, sp - 1, var_buf, vm });
}

// qjs OP_is_null: a null top slot becomes true; every other value releases only
// if owning, then becomes false. Stack-neutral and cannot throw, so it stays
// resident. An owning value is overwritten first (no longer a GC root), then the
// stack window is pinned at the unchanged sp before the release — the same
// ordering as op_lnot's object leg. No interrupt poll: qjs's CASE has none.
pub fn op_is_null(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    if (value.is(.null_value)) {
        (sp - 1)[0] = JSValue.boolean(true);
        return cont(pc + 1, sp, var_buf, vm);
    }
    (sp - 1)[0] = JSValue.boolean(false);
    return cont(pc + 1, sp, var_buf, vm);
}

// qjs OP_lnot classifies with the same unsigned tag comparison as OP_if_*: the
// immediate arm overwrites the top slot in place (none of the four immediate tags
// is reference-counted), and the object arm takes JS_ToBoolFree's object leg
// inline as op_if_false8 does — a non-HTMLDDA object is truthy, so `!obj` is
// false and the dying operand is released after the boolean overwrite removes it
// from the root window. HTMLDDA and the remaining tags (float/string/BigInt) fall
// to the cold logicalNot with pc/sp untouched.
//
// No interrupt poll: OP_lnot is not a back edge and neither qjs nor the cold
// route polls here. The fallback keeps the INDIRECT cold_table[pc[0]] hop; a
// direct tail call gets re-inlined and drags the cold shell's frame onto this body.
pub fn op_lnot(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    if (value.asBranchImmediateBool()) |truthy| {
        (sp - 1)[0] = JSValue.boolean(!truthy);
        return cont(pc + 1, sp, var_buf, vm);
    }
    if (value.is(.object)) {
        if (core.value_semantics.isHTMLDDA(value)) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
        // Overwrite before the free: the boolean takes the slot out of the GC root
        // window, then setTopPtr pins the exact window end for the inline rc==1
        // destruction (see op_if_false8's object arm).
        (sp - 1)[0] = JSValue.boolean(false);
        vm.stack.setTopPtr(sp);
        return cont(pc + 1, sp, var_buf, vm);
    }
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

// Fused local-update ops (1-byte local index; qjs OP_inc_loc/OP_dec_loc), the
// hottest loop ops. int32-only; non-int / stop-boundary cases fall to the cold op.
pub fn op_update_loc(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const idx: u16 = pc[1];
    const old_v = var_buf[idx];
    // Frame locals are always plain ValueSlots, including captured bindings;
    // `asInt32` guards only the numeric specialization.
    const iv = old_v.as(.int) orelse return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    // qjs OP_inc_loc: branch on the single overflow value, then a plain int add —
    // NOT the int64-widen + range-check, whose unconditional scvtf would sit on
    // the loop-carried counter chain. Overflow falls to the cold op's float box.
    if (pc[0] == op.inc_loc) {
        if (iv == std.math.maxInt(i32)) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
        var_buf[idx].setInt32AssumeInt(iv + 1);
    } else {
        if (iv == std.math.minInt(i32)) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
        var_buf[idx].setInt32AssumeInt(iv - 1);
    }
    return cont(pc + 2, sp, var_buf, vm);
}

/// `put_loc8` then musttail the surviving `get_loc8` (B stays in the stream).
/// Values are trace-owned, so overwriting the local has no release tail.
pub fn op_put_loc8_get_loc8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
    const idx: u16 = pc[1];
    var_buf[idx] = (sp - 1)[0];
    return @call(.always_tail, opLoc(.get, .byte), .{ pc + 2, sp - 1, var_buf, vm });
}

/// All-cold / L0-stop: do `put_loc8` only, then `coldNext` onto `get_loc8`.
pub fn op_put_loc8_get_loc8_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    vm.publish(pc, sp);
    vm_property_locals.loc(vm, op.put_loc8) catch |e| return vm.fail(e);
    return coldNext(var_buf, vm);
}

/// `push_this` then `put_loc0`. B stays in the stream; store `this` straight
/// into loc0 to avoid a temporary JSValue spill.
pub fn op_push_this_put_loc0(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section) callconv(.c) Outcome {
    if (!storeThisInLoc0(var_buf, vm)) {
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    }
    return cont(pc + 2, sp, var_buf, vm);
}

inline fn storeThisInLoc0(var_buf: [*]JSValue, vm: *Vm) bool {
    const v = vm.frame.this_value;
    if (v.is(.object)) {
        var_buf[0] = v;
        return true;
    }
    if (vm.function.isStrictMode() or vm.function.runtimeStrictMode()) {
        if (v.is(.uninitialized)) return false;
        var_buf[0] = v;
        return true;
    }
    if (v.is(.undefined_value) or v.is(.null_value)) {
        var_buf[0] = vm.global.value();
        return true;
    }
    return false;
}

pub fn op_push_this_put_loc0_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    vm.publish(pc, sp);
    vm_value.pushThisVm(vm) catch |e| return vm.fail(e);
    return coldNext(var_buf, vm);
}

/// Cold handler for OP_inc_loc/OP_dec_loc's non-int32 operand (float / BigInt /
/// object counter). Reached through the indirect `cold_table[pc[0]]` dispatch so
/// the int32 leaf is not perturbed. `updateLocalAt` runs register-resident and
/// inc/dec is stack-neutral; at the stop boundary (`local_fast_blocked`) it uses
/// the publishing path so coldNext's maybeStop still fires.
pub fn op_update_loc_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    if (vm.local_fast_blocked) {
        vm.publish(pc, sp);
        vm_arith.updateLocalVm(vm, pc[0]) catch |e| return vm.fail(e);
        return coldNext(var_buf, vm);
    }
    const idx: u16 = pc[1];
    vm.syncPc(pc, 2); // qjs sf->cur_pc — backtrace fidelity through valueOf (see op_add_loc_cold)
    // ToNumeric on the local can run user valueOf/toString, which allocates; sync
    // the operand window so values pushed since the last publish are rooted.
    vm.syncSp(sp);
    vm_arith.updateLocalAt(vm, pc[0], &var_buf[idx]) catch |err| {
        vm.publish(pc + 1, sp);
        const caught = deliverCatchable(vm, err) catch |e2| return vm.fail(e2);
        if (!caught) return vm.fail(err);
        return coldNext(var_buf, vm);
    };
    return cont(pc + 2, sp, var_buf, vm);
}
pub fn op_add_loc(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome {
    const idx: u16 = pc[1];
    const old_v = var_buf[idx];
    // Frame locals are always plain ValueSlots; these checks select only qjs's
    // two numeric specializations before the generic addLocalAt path.
    const rhs_v = (sp - 1)[0];
    // qjs OP_add_loc inlines exactly JS_VALUE_IS_BOTH_INT and JS_VALUE_IS_BOTH_FLOAT
    // before js_add_slow: int32 (overflow → float) and float64+float64 (bare
    // float64, no int32 renormalization). Both operands are non-refcounted here,
    // so the store is a bare overwrite. Mixed int+float deliberately misses both.
    if (old_v.as(.int)) |lhs| {
        if (rhs_v.as(.int)) |rhs| {
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
    if (old_v.as(.float64)) |lhs| {
        if (rhs_v.as(.float64)) |rhs| {
            var_buf[idx] = core.JSValue.float64(lhs + rhs);
            return cont(pc + 2, sp - 1, var_buf, vm);
        }
    }
    return @call(.always_tail, op_add_loc_cold, .{ pc, sp, var_buf, vm });
}

/// Cold handler for OP_add_loc's non-(both-int/both-float) operands (qjs
/// js_add_slow). The `addLocal` slow body inlines here so the path is one cold
/// hop instead of crossing an extra noinline call boundary every iteration.
/// NOT a numeric fast path: int+float runs the same full `addLocal` as object/BigInt.
pub fn op_add_loc_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    if (vm.local_fast_blocked) {
        // Generator stop boundary (same arm as op_update_loc_cold / op_mod_cold /
        // op_compare_cold): the publishing path lets coldNext's maybeStop fire
        // when this op ends exactly at stop_before_pc.
        vm.publish(pc, sp);
        vm_arith.addLocalVm(vm) catch |e| return vm.fail(e);
        return coldNext(var_buf, vm);
    }
    const idx: u16 = pc[1];
    const rhs = (sp - 1)[0];
    // qjs js_add_loc_slow(ctx, pv, sp): hand the local slot pointer and the rhs
    // value straight to the slow add with pc/sp register-resident; `addLocalAt`
    // neither re-reads frame.pc nor pops the stack. Keep frame.pc live (qjs
    // `sf->cur_pc = pc`) so a backtrace captured inside valueOf/toString reports this op.
    vm.syncPc(pc, 2);
    // js_add_loc_slow's ToPrimitive/concat allocates, so the whole live operand
    // window (rhs included) has to be inside `Stack.liveValues` first.
    vm.syncSp(sp);
    vm_arith.addLocalAt(vm, &var_buf[idx], rhs) catch |err| {
        // Error only: publish the popped sp so the catch unwinder sees consistent
        // state; addLocalAt already released rhs, so the dead slot is excluded.
        vm.publish(pc + 1, sp - 1);
        const caught = deliverCatchable(vm, err) catch |e2| return vm.fail(e2);
        if (!caught) return vm.fail(err);
        return coldNext(var_buf, vm);
    };
    return cont(pc + 2, sp - 1, var_buf, vm);
}

/// The op_get_var uninitialized-cell arm (qjs OP_get_var): a non-lexical
/// closure var parked at UNINITIALIZED — an undeclared global such as the frozen
/// `undefined` data property — resolves via a property read on the global
/// OBJECT. Mirror the plain-data own-property hit inline: pure own-shape hash
/// probe, no getter, no proto walk, no allocation, no throw, so it stays
/// publish-free. Shared by op_get_var and the get_var_field superinstruction.
/// Forced inline: one outlined bl would grow a prologue on the WHOLE handler.
///
/// Private frameless twin of Object.findProperty + the data test: the shared
/// helpers' Flags.fromBits bitcast materializes through a stack slot when
/// inlined here, which grew a scratch frame on the whole handler. Raw-bits
/// probe: atom match + !deleted (bit 5) + kind == .data (bits 3-4). Every other
/// outcome (lexical TDZ, runtime_strict preference, missing binding,
/// accessor/proto reads) keeps the cold waterfall, which starts with this probe.
inline fn getVarGlobalOwnDataInline(vm: *Vm, idx: u16) ?JSValue {
    const function = vm.function;
    // idx < closureVarCount is finalize-validated, so the read is unchecked; the
    // assert covers the test-only adapter bridge.
    std.debug.assert(idx < function.closureVar().len);
    const cv = function.closureVar()[idx];
    if (!cv.isLexical() and !function.runtimeStrictMode()) {
        const global = vm.global;
        if (!global.hasExoticMethods()) {
            const shape_ref = global.shape_ref;
            const props = global.shapeProps();
            var shape_index: u32 = @call(.always_inline, core.Shape.firstPropertyIndex, .{ shape_ref, cv.var_name });
            var steps: usize = 0;
            while (shape_index != core.shape.no_property_index and steps < shape_ref.prop_count) : (steps += 1) {
                const prop_index: usize = @intCast(shape_index);
                if (prop_index >= shape_ref.prop_count) break;
                const prop = shape_ref.props()[prop_index];
                shape_index = prop.hash_next;
                if (prop_index >= props.len) continue;
                if (prop.atom_id == cv.var_name and (prop.flags & 0b100000) == 0) {
                    if ((prop.flags & 0b011000) == 0) {
                        return global.propertyEntry(prop_index).*.slot.data;
                    }
                    break; // found, but not a plain data slot → cold waterfall
                }
            }
        }
    }
    return null;
}

pub fn op_get_var(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(32) linksection(op_handler_section) callconv(.c) Outcome {
    const idx = readInt(u16, pc + 1);
    // get_var / get_var_undef are .var_ref-format ops: finalize validates their
    // operands against closure_var_count and frame construction sizes var_refs
    // to exactly that count, so the read is unchecked like qjs OP_get_var.
    std.debug.assert(idx < vm.frame.var_refs.len);
    // Seam-leak detector: live in Debug AND ReleaseSafe.
    std.debug.assert(vm.var_refs_base == vm.frame.var_refs.ptr);
    // qjs OP_get_var is `*var_refs[idx]->pvalue` + one uninitialized check, read
    // through the Vm-resident base mirror (qjs's hoisted `var_refs` local).
    const cell = vm.var_refs_base[idx];
    const v = cell.pvalue.*;
    if (v.is(.uninitialized)) {
        // qjs keeps the uninitialized arm (a global-object property read) INSIDE
        // the handler; mirror the plain-data own-property hit inline (see
        // getVarGlobalOwnDataInline). Everything else takes the cold waterfall.
        if (getVarGlobalOwnDataInline(vm, idx)) |value| {
            sp[0] = value;
            return cont(pc + 3, sp + 1, var_buf, vm);
        }
        return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    }
    // Guard #7 (nested-cell check) and global-lexical shadow checks are not
    // part of qjs's hot OP_get_var. They are folded into the cell at
    // definition/mutation time.
    sp[0] = v;
    return cont(pc + 3, sp + 1, var_buf, vm);
}

/// Global var write (2-byte var-ref index), the resident twin of `op_get_var`.
/// qjs keeps OP_put_var's write-through arm inside JS_CallInternal; only the
/// exceptional arms reach out.
///
/// Every arm other than the plain cell write-through — lexical TDZ, const
/// violation, indirect cell, function-name slot, out-of-range operand, and the
/// undeclared/deleted-binding fall-through to the global OBJECT — tail-calls the
/// `cold_table` shell. Nothing is consumed or published before that hand-off, so
/// the shell observes exactly the entry state.
pub fn op_put_var(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section) callconv(.c) Outcome {
    const idx = readInt(u16, pc + 1);
    // Keep the operand bounds test: putVar's `ref_idx < var_refs.len` branch is a
    // live semantic arm (an unbound name goes to the global object), not a guard.
    if (idx >= vm.frame.var_refs.len) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    // Seam-leak detector: live in Debug AND ReleaseSafe.
    std.debug.assert(vm.var_refs_base == vm.frame.var_refs.ptr);
    const cell = vm.var_refs_base[idx];
    const current = cell.pvalue.*;
    // Same predicate as putVar's write-through arm, in the same order: not
    // uninitialized, not const, not an indirect var-ref, not a function-name slot.
    // A shadowing global lexical did cell surgery at definition time, so the bound
    // cell IS the binding (see vm_property_globals.putVar).
    if (current.is(.uninitialized) or cell.varRefIsConstSlot().*) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    if (core.VarRef.fromValue(current) != null) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    if (cell.varRefIsFunctionNameSlot().*) return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
    // Ownership moves from the stack slot into the cell, matching the cold arm's
    // `stack.pop()`. `setVarRefValue` releases the displaced value, which can run a
    // native finalizer but cannot throw, allocate or re-enter the VM, so this arm
    // stays publish-free. Forced inline: otherwise the backend outlines the
    // store+release as a call and shrink-wraps a frame onto the hit leg.
    @call(.always_inline, core.VarRef.setVarRefValue, .{ cell, vm.ctx.runtime, (sp - 1)[0] });
    return cont(pc + 3, sp - 1, var_buf, vm);
}

// ---- Cold handlers: the bulk lives in tailcall_dispatch_colds.zig; the special
//      handlers defined in this file are handed over here. ----

const specials: colds.SpecialHandlers = .{
    .op_return = op_return,
    .op_return_undef = op_return_undef,
    .op_call = op_call,
    .op_call0 = op_call0,
    .op_call1 = op_call1,
    .op_call2 = op_call2,
    .op_call3 = op_call3,
    .op_call_method = op_call_method,
    .op_call_method_apply_fwd = applyForwardCallMethod,
    .op_apply = op_apply,
    .op_call_constructor = op_call_constructor,
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
const cold_built = colds.buildTable(specials, false);
const cold_table: [256]Handler = cold_built.table;
// Out-of-line leaf-call constructors. Defined AFTER the handler cluster so their
// machine code lands past the established opcode bodies; inserting them
// mid-cluster shifts every subsequent handler address (BTB/fetch aliasing).
/// Exact-args twin of `pushEmptyLeafMiss`.
noinline fn pushExactArgsLeafMiss(comptime leaf_this: inline_calls.LeafThis, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue, argc: u16) align(32) PushResult {
    const entry = vm.machine.pushExactArgsLeafCall(leaf_this, vm.global, vm.stack, function, call_facts, captures, region_start, argc) catch |err| {
        if (!callSetupRecover(vm, err)) return .threw;
        return .caught;
    };
    return .{ .entry = entry };
}

/// Outlined warm exact-args constructor for the raw-`this` plain arm. The
/// fixed-arity handlers keep exactly ONE inline warm body (the sloppy arm); a
/// second inline twin re-registered the neighboring handler. One bl here still
/// skips the InlineTarget freight and the three-deep constructor chain.
noinline fn warmExactArgsLeafOutline(comptime leaf_this: inline_calls.LeafThis, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue, argc: u16, resume_pc: [*]const u8) PushResult {
    const entry = vm.machine.tryPushExactArgsLeafCallFast(leaf_this, vm.rt, vm.global, vm.stack, function, call_facts, captures, region_start, argc, resume_pc) orelse {
        const slow = vm.machine.pushExactArgsLeafCall(leaf_this, vm.global, vm.stack, function, call_facts, captures, region_start, argc) catch |err| {
            if (!callSetupRecover(vm, err)) return .threw;
            return .caught;
        };
        return .{ .entry = slow };
    };
    return .{ .entry = entry };
}

/// Capture-leaf twin of `pushEmptyLeafMiss` (same after-the-cluster placement).
noinline fn pushCaptureLeafMiss(comptime leaf_this: inline_calls.LeafThis, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue) PushResult {
    const entry = vm.machine.pushCaptureLeafCall(leaf_this, vm.global, vm.stack, function, call_facts, captures, region_start) catch |err| {
        if (!callSetupRecover(vm, err)) return .threw;
        return .caught;
    };
    return .{ .entry = entry };
}

/// Outlined warm capture-leaf constructor for the sloppy plain arm. The zero-arg
/// handlers keep exactly ONE inline warm body (the raw-`this` arm); see
/// `warmExactArgsLeafOutline` for the same rationale.
noinline fn warmCaptureLeafOutline(comptime leaf_this: inline_calls.LeafThis, vm: *Vm, function: *const bytecode.FunctionBytecode, call_facts: bytecode.CallFacts, captures: []*core.VarRef, region_start: [*]JSValue, resume_pc: [*]const u8) PushResult {
    const entry = vm.machine.tryPushCaptureLeafCallFast(leaf_this, vm.rt, vm.global, vm.stack, function, call_facts, captures, region_start, resume_pc) orelse {
        const slow = vm.machine.pushCaptureLeafCall(leaf_this, vm.global, vm.stack, function, call_facts, captures, region_start) catch |err| {
            if (!callSetupRecover(vm, err)) return .threw;
            return .caught;
        };
        return .{ .entry = slow };
    };
    return .{ .entry = entry };
}

/// Authoritative fallback for a borrowed-iterator warm miss (first-use Entry
/// allocation, chunk switching, heap fallback, OOM, stack overflow); same
/// after-the-cluster placement. The dispatch arm already paid the interrupt poll.
/// The warm gate implies the eligibility `pushBorrowedIteratorNext` re-proves,
/// so its null fallback is unreachable here; keep the dup/move arm anyway so an
/// eligibility drift fails safe.
noinline fn pushBorrowedIteratorMiss(vm: *Vm, resolved: *const inline_calls.ResolvedInlineFunction, receiver: JSValue, method: JSValue, iterator_record: []JSValue, depth: u8) PushResult {
    const target = resolved.bind(receiver, method);
    const maybe_entry = vm.machine.pushBorrowedIteratorNext(vm.global, &target, iterator_record, depth) catch |err| {
        if (!iteratorNextCallSetupRecover(vm, depth, err)) return .threw;
        return .caught;
    };
    const entry = maybe_entry orelse {
        var moved = [2]JSValue{ iterator_record[0], iterator_record[1] };
        const moved_entry = vm.machine.pushMovedCall(vm.global, &target, &moved, .method, .for_of_next, depth) catch |err| {
            if (!iteratorNextCallSetupRecover(vm, depth, err)) return .threw;
            return .caught;
        };
        return .{ .entry = moved_entry };
    };
    return .{ .entry = entry };
}

/// The hot table is never wrapped: a per-entry profiling shim in the handler
/// section slid the island and broke the `op_return` musttail ABI. Profiling
/// builds count in `cont`/`next` instead, so handler bodies stay identical.
const dispatch_table: [256]Handler = colds.buildTable(specials, true).table;
const property_tail_table = [17]Handler{
    op_get_field_primitive,
    op_get_field2_primitive,
    op_get_array_el_atom_key,
    op_get_array_el_atom_key_getter,
    op_get_array_el_atom_key_proxy,
    op_get_field_cached_getter,
    op_get_field_property_tail,
    op_get_field_after_own_miss_tail,
    op_get_static_cached_proxy,
    op_get_length_property_tail,
    op_get_field_typed_property_tail,
    op_get_field_absent_tail,
    op_get_field_native_getter_tail,
    op_prop_site_indirect_tail,
    op_prop_site_capture_tail,
    op_put_field_add_tail,
    op_put_array_el_cold,
};
const resident_tail_table = [3]Handler{
    op_add_strings,
    op_special_arguments,
    op_if_false8_complex,
};

// ===========================================================================
// Driver — the Outcome loop. `zjs_vm.zig` prepares the frame, then calls
// `runDispatchLoop`; frames are reloaded from the Machine between outcomes.
// ===========================================================================

inline fn reloadTop(vm: *Vm, pc: *[*]const u8, sp: *[*]JSValue, var_buf: *[*]JSValue) void {
    vm.machine.loadCurrentLevel(&vm.frame, &vm.stack, &vm.catch_target);
    vm.var_refs_base = vm.frame.var_refs.ptr;
    vm.function = vm.frame.function;
    vm.publishPropSites(vm.function);
    vm.code_base = vm.function.byteCode().ptr;
    vm.local_fast_blocked = vm.machine.depth == 0 and vm.machine.l0.stop_before_pc != null;
    vm.active_dispatch_tbl = if (vm.local_fast_blocked) &cold_table else &dispatch_table;
    // Handlers read `pc[0]` themselves, so pc points AT the resume opcode (no +1).
    pc.* = vm.code_base + vm.frame.pc;
    sp.* = vm.stack.topPtr();
    var_buf.* = vm.frame.locals.ptr;
}

/// The register triple a handler resumes with after a frame pop. In
/// `reloadAfterPop` a null caller entry names L0 (qjs `prev_frame == NULL`);
/// a non-null entry names the caller directly, no depth/index lookup.
const Regs = struct { pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue };

inline fn reloadAfterPop(vm: *Vm, caller_entry: ?*inline_calls.Entry) Regs {
    if (caller_entry) |entry| {
        vm.frame = &entry.frame;
        vm.var_refs_base = entry.frame.var_refs.ptr;
        vm.stack = &entry.stack;
        vm.catch_target = &entry.catch_target;
    } else {
        vm.frame = vm.machine.l0.level.frame;
        vm.var_refs_base = vm.machine.l0.level.frame.var_refs.ptr;
        vm.stack = vm.machine.l0.level.stack;
        vm.catch_target = vm.machine.l0.level.catch_target;
        // Inline callees enter with this cache false; only the L0 stop seam
        // carries new information that must be published on return.
        std.debug.assert(!vm.local_fast_blocked);
        if (vm.machine.l0.stop_before_pc != null) {
            vm.local_fast_blocked = true;
            vm.active_dispatch_tbl = &cold_table;
        }
    }
    vm.function = vm.frame.function;
    vm.publishPropSites(vm.function);
    vm.code_base = vm.function.byteCode().ptr;
    return .{ .pc = vm.code_base + vm.frame.pc, .sp = vm.stack.topPtr(), .var_buf = vm.frame.locals.ptr };
}

/// Run the tail-call chain to completion for the current top frame. Only the
/// outcome switch stays inline; the `.returned` / `.tail` arms are outlined so
/// their temporaries do not enlarge every driver entry.
pub fn runDispatchLoop(vm: *Vm) HostError!void {
    // qjs prologue hoist: `var_refs = p->u.func.var_refs`.
    vm.var_refs_base = vm.frame.var_refs.ptr;
    vm.local_fast_blocked = vm.machine.depth == 0 and vm.machine.l0.stop_before_pc != null;
    vm.active_dispatch_tbl = if (vm.local_fast_blocked) &cold_table else &dispatch_table;
    return runDispatchLoopPublished(vm, vm.code_base + vm.frame.pc);
}

/// Loop entry for a Vm whose prologue facts and first `pc` the caller already
/// published (`Vm.publishPushedEntry`).
pub inline fn runDispatchLoopPublished(vm: *Vm, entry_pc: [*]const u8) HostError!void {
    // The two resident handler tables were published by `Vm.initResident`.
    std.debug.assert(vm.resident_tail_tbl == &resident_tail_table);
    std.debug.assert(vm.property_tail_tbl == &property_tail_table);
    std.debug.assert(vm.var_refs_base == vm.frame.var_refs.ptr);
    std.debug.assert(vm.local_fast_blocked == (vm.machine.depth == 0 and vm.machine.l0.stop_before_pc != null));
    std.debug.assert(entry_pc == vm.code_base + vm.frame.pc);
    var pc = entry_pc;
    var sp = vm.reloadSp();
    var var_buf = vm.frame.locals.ptr;
    while (true) {
        // Every completed exit leaves its value in `vm.return_value`.
        switch (next(pc, sp, var_buf, vm)) {
            .returned => {
                if (vm.machine.depth == 0) return;
                if (try driveReturnedContinuation(vm)) return;
            },
            .threw => return vm.pending_error,
            .tail => try driveTailRequest(vm),
            .suspended => return,
            .reenter => unreachable, // cold callees complete inside vm_call.call.
            .native_returned => return,
        }
        reloadTop(vm, &pc, &sp, &var_buf);
    }
}

/// `.returned` at depth > 0: retire the frame and run its post-call continuation.
/// Returns true for `.native_boundary` (the value stays in `vm.return_value` for
/// the driver's caller); false resumes the caller level.
noinline fn driveReturnedContinuation(vm: *Vm) HostError!bool {
    var continuation = vm.machine.popReturn(vm.return_value);
    if (continuation.action == .next) {
        std.debug.assert(continuation.payload == 0);
        return false;
    }
    if (continuation.action == .native_boundary) {
        storeValueAsIntPair(&vm.return_value, vm.return_value);
        return true;
    }
    // The continuation body runs on the caller level; publish it first.
    var pc: [*]const u8 = undefined;
    var sp: [*]JSValue = undefined;
    var var_buf: [*]JSValue = undefined;
    reloadTop(vm, &pc, &sp, &var_buf);
    const result = vm.return_value;
    vm.return_value = JSValue.undefinedValue();
    switch (continuation.action) {
        .async_complete => {
            const promise = vm.machine.completeAsync(continuation.payload, false) catch |err| {
                if (!callSetupRecover(vm, err)) return vm.pending_error;
                return false;
            };
            vm.stack.pushOwnedAssumeCapacity(promise);
        },
        .proxy_get => try completeProxyGetContinuation(vm, result, continuation.takeAtom()),
        .for_of_next => try completeForOfNextContinuation(vm, result, continuation.takeForOfDepth()),
        .to_boolean => {
            std.debug.assert(continuation.payload == 0);
            const bool_result = JSValue.boolean(coercion_ops.valueTruthy(result));
            vm.stack.pushOwnedAssumeCapacity(bool_result);
        },
        .native_boundary => unreachable,
        .constructor => unreachable,
        .next => unreachable,
    }
    return false;
}

/// `.tail`: enter the requested frame (push, or reuse for eval-tail / PTC). Errors
/// the tail caller catches are delivered into that caller before returning.
noinline fn driveTailRequest(vm: *Vm) HostError!void {
    const req = &vm.tail_request;
    // qjs polls at JS_CallInternal entry, before any caller-frame mutation.
    try exception_ops.pollInterrupt(vm.ctx, vm.global);
    const reuse = switch (vm.tail_mode) {
        .push => false,
        // eval-tail: reuse only at depth > 0; constructor and async completions
        // keep their own frame.
        .reuse_chain => !(vm.machine.depth > 0 and
            (vm.machine.topEntry().completesConstructor() or vm.machine.topEntry().return_action == .async_complete)),
        // strict PTC also needs no live catch handler (a protected call is not in
        // tail position) and a real machine frame to retire.
        .reuse_release => vm.machine.depth > 0 and
            !vm.machine.topEntry().completesConstructor() and
            vm.machine.topEntry().return_action != .async_complete and
            vm.catch_target.* == null,
    };
    if (reuse) {
        _ = vm.machine.tailCallReuse(
            vm.global,
            vm.stack,
            &req.target,
            req.region_base,
            req.argc,
            req.layout,
            if (vm.tail_mode == .reuse_release) .release else .chain,
        ) catch |err| {
            // Setup fails while the tail caller is still current, so its own catch
            // handler sees the error, like qjs OP_tail_call.
            if (callSetupRecover(vm, err)) return;
            return vm.pending_error;
        };
        return;
    }
    vm.stack.setLen(req.region_base);
    _ = vm.machine.pushCall(vm.global, vm.stack, &req.target, vm.stack.topPtr(), req.argc, req.layout) catch |err| {
        // Push-failure path: close a pending for-of iterator, then try to deliver
        // the setup failure (OOM-class) as a JS-catchable error in the caller
        // frame. Only an uncaught error propagates out of the loop.
        try forof_ops.closeStackTopForOfIteratorForPendingError(vm.ctx, vm.output, vm.global, vm.stack);
        if (try deliverCatchable(vm, err)) return;
        return err;
    };
}

// ---------------------------------------------------------------------------
// Handlers added after the main island live in `op_handler_section_tail` so
// they cannot shift the established handler addresses.
// ---------------------------------------------------------------------------

/// Fast `op.ext0`: type-test subs tail into the leaves below; the other subs
/// stay on the cold `using` shell.
pub fn op_using(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome {
    const sub = pc[1];
    if (sub == bytecode.opcode.ext0_sub.is_undefined)
        return @call(.always_tail, op_using_is_undefined, .{ pc, sp, var_buf, vm });
    if (sub == bytecode.opcode.ext0_sub.typeof_is_undefined)
        return @call(.always_tail, op_using_typeof_is_undefined, .{ pc, sp, var_buf, vm });
    if (sub == bytecode.opcode.ext0_sub.typeof_is_function)
        return @call(.always_tail, op_using_typeof_is_function, .{ pc, sp, var_buf, vm });
    return @call(.always_tail, cold_table[pc[0]], .{ pc, sp, var_buf, vm });
}

pub fn op_using_is_undefined(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    if (value.is(.undefined_value)) {
        (sp - 1)[0] = JSValue.boolean(true);
        return cont(pc + 2, sp, var_buf, vm);
    }
    (sp - 1)[0] = JSValue.boolean(false);
    return cont(pc + 2, sp, var_buf, vm);
}

pub fn op_using_typeof_is_undefined(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome {
    const value = (sp - 1)[0];
    const yes = value.is(.undefined_value) or value_ops.isHTMLDDA(value);
    (sp - 1)[0] = JSValue.boolean(yes);
    return cont(pc + 2, sp, var_buf, vm);
}

pub fn op_using_typeof_is_function(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome {
    // publish left frame.pc on the sub byte; skip it so coldNext resumes after it.
    vm.publish(pc, sp);
    vm.frame.pc += 1;
    vm_value.typeOfIsFunction(vm.ctx.runtime, vm.stack) catch |e| return vm.fail(e);
    return coldNext(var_buf, vm);
}

/// `get_field` then `b` `op_get_field2`. Leftover B stays.
pub fn op_get_field_field2(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome {
    const receiver = (sp - 1)[0];
    const atom_id = core.Atom.fromRaw(readInt(u32, pc + 1));
    if (!receiver.is(.object))
        return @call(.always_tail, propertyTailHandler(vm, .get_field_primitive), .{ pc, sp, var_buf, vm });
    const rt = vm.ctx.runtime;
    if (object_ops.objectFromValueTrustedExpression(receiver)) |object| {
        const site = vm.propSite(pc[5]);
        if (object.shape_ref.identity == site.guard_key) {
            if (site.proto_key == 0) {
                const value = loadValueAsIntPair(&object.propertyEntry(site.slot).slot.data);
                storeValueAsIntPair(&(sp - 1)[0], value);
                return @call(.always_tail, op_get_field2, .{ pc + 6, sp, var_buf, vm });
            }
            return @call(.always_tail, propertyTailHandler(vm, .prop_site_indirect), .{ pc, sp, var_buf, vm });
        }
        if (object.shape_ref.identity == site.secondary_guard_key) {
            const value = loadValueAsIntPair(&object.propertyEntry(site.secondary_slot).slot.data);
            storeValueAsIntPair(&(sp - 1)[0], value);
            return @call(.always_tail, op_get_field2, .{ pc + 6, sp, var_buf, vm });
        }
        if (vm_property_field.siteCapturable(site))
            return @call(.always_tail, propertyTailHandler(vm, .prop_site_capture), .{ pc, sp, var_buf, vm });
    }
    var absent = false;
    if (vm_property_field.getFieldFastSlotOrAbsent(rt, receiver, atom_id, &absent)) |slot| {
        const value = loadValueAsIntPair(slot);
        storeValueAsIntPair(&(sp - 1)[0], value);
        return @call(.always_tail, op_get_field2, .{ pc + 6, sp, var_buf, vm });
    }
    if (absent) return @call(.always_tail, propertyTailHandler(vm, .get_field_absent), .{ pc, sp, var_buf, vm });
    // The walk stopped on a non-data slot (this fused handler never sets
    // `property_holder`): re-probe from the receiver and call a native getter in place.
    if (vm_property_field.ordinaryAccessorGetterAfterOwnMiss(object_ops.objectFromValueTrustedExpression(receiver).?, atom_id)) |getter| {
        if (builtin_dispatch.nativeAccessorTarget(getter, .getter)) |target| {
            vm.syncPc(pc, 6);
            vm.stack.setTopPtr(sp);
            const value = callNativeAccessor(vm, target, receiver, &.{}, .getter) catch |err| {
                const operand_len = (@intFromPtr(sp) - @intFromPtr(vm.stack.values)) / @sizeOf(JSValue);
                vm.stack.setLen(operand_len - 1);
                const caught = deliverCatchable(vm, err) catch |e2| return vm.fail(e2);
                if (!caught) return vm.fail(err);
                return coldNext(var_buf, vm);
            };
            storeValueAsIntPair(&(sp - 1)[0], value);
            return cont(pc + 6, sp, var_buf, vm);
        }
    }
    if (vm_property_field.isTypedArrayPayloadAtomForFastPath(atom_id)) {
        if (vm_property_field.typedArrayReceiverForFastPath(receiver)) |object| {
            vm.property_holder = object;
            return @call(.always_tail, propertyTailHandler(vm, .get_field_typed_property), .{ pc, sp, var_buf, vm });
        }
    }
    return @call(.always_tail, propertyTailHandler(vm, .get_field_property), .{ pc, sp, var_buf, vm });
}

pub fn op_get_field_field2_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome {
    vm.publish(pc, sp);
    vm_property_field.field(vm, op.get_field_field2) catch |e| return vm.fail(e);
    return coldNext(var_buf, vm);
}

/// `get_var` then `b` `op_get_field`. Leftover B stays.
pub fn op_get_var_field(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome {
    const idx = readInt(u16, pc + 1);
    std.debug.assert(idx < vm.frame.var_refs.len);
    const cell = vm.var_refs_base[idx];
    const v = cell.pvalue.*;
    if (v.is(.uninitialized))
        return @call(.always_tail, op_get_var_field_cold, .{ pc, sp, var_buf, vm });
    sp[0] = v;
    return @call(.always_tail, op_get_field, .{ pc + 3, sp + 1, var_buf, vm });
}

/// Uninitialized-cell leg: run the same inline global-object own-data probe as
/// op_get_var, then enter op_get_field directly; other outcomes take the `getVar`
/// waterfall plus coldNext. Kept cold so the fused hot body stays two loads.
pub fn op_get_var_field_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome {
    const idx = readInt(u16, pc + 1);
    if (getVarGlobalOwnDataInline(vm, idx)) |value| {
        sp[0] = value;
        return @call(.always_tail, op_get_field, .{ pc + 3, sp + 1, var_buf, vm });
    }
    vm.publish(pc, sp);
    vm_property_globals.getVar(vm, op.get_var) catch |e| return vm.fail(e);
    return coldNext(var_buf, vm);
}

/// `get_loc2` then `b` `op_get_field2`. Same shape as `get_loc2_field`.
pub fn op_get_loc2_field2(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome {
    sp[0] = var_buf[2];
    return @call(.always_tail, op_get_field2, .{ pc + 1, sp + 1, var_buf, vm });
}

pub fn op_get_loc2_field2_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome {
    vm.publish(pc, sp);
    vm_property_locals.loc(vm, op.get_loc2) catch |e| return vm.fail(e);
    return coldNext(var_buf, vm);
}

/// `push_0` then musttail `or`. Leftover B stays.
pub fn op_push_0_or(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome {
    sp[0] = JSValue.int32(0);
    return @call(.always_tail, opBinary(.bor), .{ pc + 1, sp + 1, var_buf, vm });
}

/// `push_0_or` is a one-byte opcode, so `publish` already left `frame.pc` on the
/// leftover `or`; advancing again would skip it (two-byte fusions do need the step).
pub fn op_push_0_or_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome {
    vm.publish(pc, sp);
    sp[0] = JSValue.int32(0);
    vm.stack.setTopPtr(sp + 1);
    return coldNext(var_buf, vm);
}

/// `sar` then musttail `get_array_el`. Leftover B stays.
pub fn op_sar_get_array_el(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome {
    const ints = JSValue.asInt32Pair((sp - 2)[0], (sp - 1)[0]) orelse
        return @call(.always_tail, op_sar_get_array_el_cold, .{ pc, sp, var_buf, vm });
    (sp - 2)[0].setInt32AssumeInt(ints.lhs >> @intCast(ints.rhs & 31));
    return @call(.always_tail, op_get_array_el, .{ pc + 1, sp - 1, var_buf, vm });
}

pub fn op_sar_get_array_el_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome {
    vm.publish(pc, sp);
    vm_arith.binaryVm(vm, op.sar) catch |e| return vm.fail(e);
    return coldNext(var_buf, vm);
}

/// `push_2` then musttail leftover `sar`. A leftover re-fused to `sar_get_array_el`
/// must enter that handler, never plain `sar` with a fused `pc[0]`.
pub fn op_push_2_sar(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome {
    sp[0] = JSValue.int32(2);
    if (pc[1] == op.sar_get_array_el)
        return @call(.always_tail, op_sar_get_array_el, .{ pc + 1, sp + 1, var_buf, vm });
    return @call(.always_tail, opBinary(.sar), .{ pc + 1, sp + 1, var_buf, vm });
}

/// One-byte opcode: `publish` already points `frame.pc` at the leftover `sar`.
pub fn op_push_2_sar_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome {
    vm.publish(pc, sp);
    sp[0] = JSValue.int32(2);
    vm.stack.setTopPtr(sp + 1);
    return coldNext(var_buf, vm);
}

/// `get_loc8` then musttail leftover `push_2` / `push_0_*`. The leftover may
/// already be fused (`push_0_shr`/`push_0_or`/`push_2_sar`); fused leftovers sit
/// at low opcodes, raw `push_0..7` high. Test the high range first so the common
/// `get_loc8 -> push_2` arm stays one taken branch.
inline fn tailPush2(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) Outcome {
    const b = pc[2];
    if (b > op.get_loc8_push_2)
        return @call(.always_tail, op_push_small, .{ pc + 2, sp, var_buf, vm });
    if (b == op.push_2_sar)
        return @call(.always_tail, op_push_2_sar, .{ pc + 2, sp, var_buf, vm });
    if (b == op.push_0_shr)
        return @call(.always_tail, op_push_0_shr, .{ pc + 2, sp, var_buf, vm });
    if (b == op.push_0_or)
        return @call(.always_tail, op_push_0_or, .{ pc + 2, sp, var_buf, vm });
    return @call(.always_tail, op_push_small, .{ pc + 2, sp, var_buf, vm });
}

pub fn op_get_loc8_push_2(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome {
    sp[0] = var_buf[pc[1]];
    return tailPush2(pc, sp + 1, var_buf, vm);
}

pub fn op_get_loc8_push_2_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome {
    vm.publish(pc, sp);
    vm_property_locals.loc(vm, op.get_loc8) catch |e| return vm.fail(e);
    return coldNext(var_buf, vm);
}

/// `push_0` then musttail leftover `shr`.
pub fn op_push_0_shr(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome {
    sp[0] = JSValue.int32(0);
    return @call(.always_tail, opBinary(.shr), .{ pc + 1, sp + 1, var_buf, vm });
}

pub fn op_push_0_shr_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome {
    vm.publish(pc, sp);
    sp[0] = JSValue.int32(0);
    vm.stack.setTopPtr(sp + 1);
    return coldNext(var_buf, vm);
}

/// `get_loc8` then musttail leftover `push_1`.
pub fn op_get_loc8_push_1(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome {
    sp[0] = var_buf[pc[1]];
    return @call(.always_tail, op_push_small, .{ pc + 2, sp + 1, var_buf, vm });
}

pub fn op_get_loc8_push_1_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome {
    vm.publish(pc, sp);
    vm_property_locals.loc(vm, op.get_loc8) catch |e| return vm.fail(e);
    return coldNext(var_buf, vm);
}

/// Leftover `get_loc8` may already be a push fusion; the hottest leftover
/// (`get_loc8_push_2`) is tested first so the common arm is one compare.
inline fn tailGetLoc8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) Outcome {
    const b = pc[0];
    if (b == op.get_loc8_push_2) {
        @branchHint(.likely);
        return @call(.always_tail, op_get_loc8_push_2, .{ pc, sp, var_buf, vm });
    }
    if (b == op.get_loc8_push_1)
        return @call(.always_tail, op_get_loc8_push_1, .{ pc, sp, var_buf, vm });
    if (b == op.get_loc8_push_i8)
        return @call(.always_tail, op_get_loc8_push_i8, .{ pc, sp, var_buf, vm });
    return @call(.always_tail, opLoc(.get, .byte), .{ pc, sp, var_buf, vm });
}

/// `get_var_ref0` then musttail leftover `get_loc8` (possibly already fused).
pub fn op_get_var_ref0_get_loc8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome {
    std.debug.assert(0 < vm.frame.var_refs.len);
    const cell = vm.var_refs_base[0];
    const v = cell.pvalue.*;
    if (v.is(.uninitialized))
        return @call(.always_tail, op_get_var_ref0_get_loc8_cold, .{ pc, sp, var_buf, vm });
    sp[0] = v;
    return tailGetLoc8(pc + 1, sp + 1, var_buf, vm);
}

pub fn op_get_var_ref0_get_loc8_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome {
    vm.publish(pc, sp);
    vm_property_locals.varRefVm(vm, op.get_var_ref0) catch |e| return vm.fail(e);
    return coldNext(var_buf, vm);
}

/// `push_i8` then musttail leftover `add`.
pub fn op_push_i8_add(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome {
    sp[0] = JSValue.int32(@as(i8, @bitCast(pc[1])));
    return @call(.always_tail, opBinary(.add), .{ pc + 2, sp + 1, var_buf, vm });
}

pub fn op_push_i8_add_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome {
    vm.publish(pc, sp);
    sp[0] = JSValue.int32(@as(i8, @bitCast(pc[1])));
    vm.stack.setTopPtr(sp + 1);
    vm.frame.pc += 1;
    return coldNext(var_buf, vm);
}

/// `get_loc8` then musttail leftover `push_i8` (possibly already fused to `push_i8_add`).
pub fn op_get_loc8_push_i8(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(64) linksection(op_handler_section_tail) callconv(.c) Outcome {
    sp[0] = var_buf[pc[1]];
    if (pc[2] == op.push_i8_add)
        return @call(.always_tail, op_push_i8_add, .{ pc + 2, sp + 1, var_buf, vm });
    return @call(.always_tail, op_push_i8, .{ pc + 2, sp + 1, var_buf, vm });
}

pub fn op_get_loc8_push_i8_cold(pc: [*]const u8, sp: [*]JSValue, var_buf: [*]JSValue, vm: *Vm) align(16) linksection(op_handler_section_tail) callconv(.c) Outcome {
    vm.publish(pc, sp);
    vm_property_locals.loc(vm, op.get_loc8) catch |e| return vm.fail(e);
    return coldNext(var_buf, vm);
}

comptime {
    _ = &next;
    _ = &readInt;
    _ = &coldGen;
    _ = &coldStd;
    _ = &coldNext;
    _ = &runDispatchLoop;
    _ = dispatch_table;
}

// ----- merged from vm_profile.zig -----
// Per-opcode profiling support for the tail-call threaded dispatcher.
//
// The pre-threading design wrapped each opcode in an enter/deinit scope;
// a scope cannot span an `always_tail` chain, so that API is retired.
// A later 256-entry table shim (`profiledHandler` in `.op_handlers`)
// slid the L-1 island and broke `op_return`'s musttail ABI on zlib
// (SIGSEGV, `sp == 0`). Profiling builds now call `noteDispatch` from
// `cont`/`next` only — handler bodies stay unwrapped. The final open
// interval is closed by `OpcodeProfile.flushPendingDispatch` before any
// dump. Compiled out entirely in default builds.
const build_options = @import("build_options");
pub const enabled = build_options.zjs_enable_opcode_profile;
pub inline fn noteDispatch(rt: *core.JSRuntime, pc: [*]const u8) void {
    if (comptime !enabled) return;
    const profile = rt.opcode_profile orelse return;
    const opcode = pc[0];
    profile.noteDispatch(opcode);
    // Memory-only, no syscall: safe on the musttail path (the crash
    // precedent in the header was clock_gettime's frame, not a store).
    const bc = @import("../bytecode.zig");
    if (opcode == comptime @intFromEnum(bc.opcode.logical.LogicalOpcode.ext0))
        profile.noteCarrierSub(pc[1]);
}
