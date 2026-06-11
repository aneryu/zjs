//! Inline bytecode-to-bytecode call machinery.
//! Same-loop frame push/pop for eligible plain bytecode calls.
//!
//! Mirrors QuickJS `JS_CallInternal`'s `OP_call` handling: when a bytecode
//! function calls another plain bytecode function, the dispatch loop pushes a
//! new frame onto this machine and keeps executing in the same loop instead
//! of recursing into a nested `runWithArgsState`. `op.return` pops the frame
//! and continues in the caller; exception unwinding walks the inline frames
//! looking for catch targets before the error escapes the loop.
//!
//! Only the common fast shape is inlined (normal function kind, no class
//! constructor, no arrow, no eval bindings, same realm, no pending special
//! `this`). Everything else keeps using the recursive slow path, which stays
//! fully supported; the two paths share all frame setup primitives.

const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const core = @import("../core/root.zig");
const exception_ops = @import("vm_exception_ops.zig");
const frame_mod = @import("frame.zig");
const object_ops = @import("object_ops.zig");
const shared_vm = @import("shared.zig");
const stack_mod = @import("stack.zig");
const vm_call = @import("vm_call.zig");

const HostError = @import("exceptions.zig").HostError;
const popCallFuncFromStack = shared_vm.popCallFuncFromStack;

/// An eligible bytecode-to-bytecode call target resolved from a callable
/// value on the operand stack. All values are borrowed from the caller's
/// (rooted) operand stack region.
pub const InlineTarget = struct {
    function_object: *core.Object,
    /// The callable closure value (becomes `frame.current_function`).
    callable: core.JSValue,
    fb: *const bytecode.FunctionBytecode,
};

/// Resolve `func` to an inline-eligible bytecode call target. Mirrors the
/// plain-call leg of `callValueOrBytecodeClassModeDispatch`; any condition
/// that path special-cases (class constructors, arrows, eval bindings,
/// cross-realm calls, simple-numeric/string fusion bodies, async/generator
/// kinds) disqualifies the target so the slow path keeps handling it.
pub fn resolveInlineTarget(global: *core.Object, func: core.JSValue) ?InlineTarget {
    const function_object = object_ops.functionObjectFromValue(func) orelse return null;
    const function_value = function_object.functionBytecodeSlot().* orelse return null;
    const fb = shared_vm.functionBytecodeFromValue(function_value) orelse return null;
    if (fb.func_kind != .normal) return null;
    if (fb.is_class_constructor or fb.is_derived_class_constructor) return null;
    // Arrow functions carry lexical this / new.target plumbing; keep them on
    // the slow path so the boxing rules stay in one place.
    if (fb.is_arrow_function) return null;
    // Fusion-recognizable bodies are handled by callSimple*Bytecode in the
    // slow path with broader matching than the pre-call fast checks.
    if (fb.simple_numeric_kind != .none or fb.simple_string_kind != .none) return null;
    if (function_object.functionEvalLocalNamesSlot().*.len != 0) return null;
    if (function_object.functionEvalLocalRefsSlot().*.len != 0) return null;
    const function_global = object_ops.objectRealmGlobal(function_object) orelse global;
    if (function_global != global) return null;
    return .{
        .function_object = function_object,
        .callable = func,
        .fb = fb,
    };
}

/// One suspended-or-active inline call level. Entries live in chunked,
/// pointer-stable storage; `frame`, `stack`, and `view` are referenced by
/// the dispatch loop, GC root scopes, and backtrace pc borrows while the
/// level is alive.
pub const Entry = struct {
    view: bytecode.Bytecode,
    frame: frame_mod.Frame,
    eval_snapshot: frame_mod.EvalVarRefSnapshot,
    frame_roots: frame_mod.FrameRootScope,
    stack: stack_mod.Stack,
    catch_target: ?usize,
    arena_mark: core.VmStackArena.Mark,
    profile_guard: vm_call.CallProfileGuard,
};

const entries_per_chunk: usize = 16;
const max_chunks: usize = 512;

pub const Machine = struct {
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    /// Level-0 (recursive entry) context, used when unwinding reaches the
    /// bottom of the inline stack.
    l0_frame: *frame_mod.Frame,
    l0_stack: *stack_mod.Stack,
    l0_catch_target: *?usize,
    /// Owned bytecode view for level-0 tail-call frame reuse.
    l0_tail_view: bytecode.Bytecode = undefined,
    l0_tail_view_active: bool = false,
    /// Chunked entry storage; only the first `chunk_count` slots are valid.
    /// Left undefined so machine construction is O(1) per interpreter entry.
    chunks: [max_chunks]*[entries_per_chunk]Entry = undefined,
    chunk_count: usize = 0,
    depth: usize = 0,
    /// Set whenever the current execution level changed (push, pop, unwind);
    /// tells the dispatch loop to refresh its cached per-level locals.
    switched: bool = false,

    pub fn init(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, l0_frame: *frame_mod.Frame, l0_stack: *stack_mod.Stack, l0_catch_target: *?usize) Machine {
        return .{
            .ctx = ctx,
            .output = output,
            .global = global,
            .l0_frame = l0_frame,
            .l0_stack = l0_stack,
            .l0_catch_target = l0_catch_target,
        };
    }

    /// Drains any leftover inline frames (error propagation out of the
    /// dispatch loop without a catch handler) and releases chunk storage.
    /// Draining mirrors the per-level `errdefer` of the recursive path:
    /// abrupt-completion destructuring iterators are closed before each
    /// frame is torn down.
    pub fn deinit(self: *Machine) void {
        while (self.depth > 0) {
            const entry = self.topEntry();
            shared_vm.closeFrameDestructuringIteratorsForAbruptCompletion(self.ctx, self.output, self.global, &entry.stack, &entry.frame);
            self.popTeardown();
        }
        for (self.chunks[0..self.chunk_count]) |chunk| {
            self.ctx.runtime.memory.destroy(@TypeOf(chunk.*), chunk);
        }
        self.chunk_count = 0;
        if (self.l0_tail_view_active) {
            self.l0_tail_view.deinit(self.ctx.runtime);
            self.l0_tail_view_active = false;
        }
    }

    pub fn l0Function(self: *const Machine, entry_function: *const bytecode.Bytecode) *const bytecode.Bytecode {
        if (self.l0_tail_view_active) return &self.l0_tail_view;
        return entry_function;
    }

    pub fn topEntry(self: *Machine) *Entry {
        std.debug.assert(self.depth > 0);
        return self.entryAt(self.depth - 1);
    }

    fn entryAt(self: *Machine, index: usize) *Entry {
        return &self.chunks[index / entries_per_chunk][index % entries_per_chunk];
    }

    fn acquireSlot(self: *Machine, global: *core.Object) HostError!*Entry {
        const index = self.depth;
        const chunk_index = index / entries_per_chunk;
        if (chunk_index >= max_chunks) {
            _ = shared_vm.throwRangeErrorMessage(self.ctx, global, "Maximum call stack size exceeded") catch |err| return err;
            return error.RangeError;
        }
        if (chunk_index == self.chunk_count) {
            self.chunks[chunk_index] = try self.ctx.runtime.memory.create([entries_per_chunk]Entry);
            self.chunk_count += 1;
        }
        return self.entryAt(index);
    }

    /// Push an inline call frame for `target` whose `func | args...` region
    /// starts at `region_base` on `caller_stack`. On success the region has
    /// been popped from the caller stack and the machine's top entry is the
    /// new current execution level. On error the caller stack is untouched.
    pub fn pushCall(
        self: *Machine,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        target: InlineTarget,
        region_base: usize,
        argc: u16,
    ) HostError!void {
        const ctx = self.ctx;
        const rt = ctx.runtime;

        try vm_call.enterInlineCallDepth(ctx, global);
        errdefer ctx.call_depth -= 1;

        const entry = try self.acquireSlot(global);
        entry.view = bytecode.function.asBytecodeView(target.fb, rt);
        entry.catch_target = null;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        errdefer entry.profile_guard.deinit();

        try ctx.pushBacktraceFrameLazyName(
            entry.view.name,
            entry.view.filename,
            entry.view.line_num,
            entry.view.col_num,
            &entry.view,
            exception_ops.resolveBacktraceLocation,
            target.callable,
        );
        errdefer ctx.popBacktraceFrame();

        entry.arena_mark = rt.vm_stack.mark();
        errdefer rt.vm_stack.restore(entry.arena_mark);

        const operand_window = rt.vm_stack.carve(&rt.memory, @as(usize, entry.view.stack_size) + 1);
        entry.stack = if (operand_window) |window|
            stack_mod.Stack.initArenaWindow(&rt.memory, rt.stack_size, window)
        else
            stack_mod.Stack.init(&rt.memory, rt.stack_size);
        errdefer entry.stack.deinit(rt);

        entry.frame = frame_mod.Frame.init(&entry.view);
        errdefer entry.frame.deinit(&rt.memory, rt);
        ctx.borrowBacktracePc(&entry.frame.pc);

        const fb_strict = entry.view.flags.is_strict or entry.view.flags.runtime_strict;
        const effective_this = if (fb_strict) core.JSValue.undefinedValue() else global.value();
        entry.eval_snapshot = try entry.frame.initCallBindings(rt, .{
            .initial_this_value = effective_this,
            .current_function_value = target.callable,
            .new_target_value = core.JSValue.undefinedValue(),
            .constructor_this_value = core.JSValue.undefinedValue(),
            .eval_local_names = &.{},
            .eval_local_slots = &.{},
            .input_eval_var_ref_names = &.{},
            .input_eval_var_refs = &.{},
            .inherited_eval_local_names = &.{},
            .inherited_eval_local_slots = &.{},
            .inherited_eval_var_ref_names = &.{},
            .inherited_eval_var_refs = &.{},
        });
        errdefer entry.eval_snapshot.deinit(rt);

        entry.frame_roots = .{};
        entry.frame_roots.init(rt, &entry.stack, &entry.frame, &entry.eval_snapshot);
        errdefer entry.frame_roots.deinit();

        try vm_call.initFrameLocals(ctx, &entry.view, &entry.frame, &.{}, &.{}, true);
        popCallFuncFromStack(rt, caller_stack, region_base);
        try entry.frame.initArgumentsFromStack(
            &rt.memory,
            &rt.vm_stack,
            caller_stack,
            argc,
            true,
            frame_mod.argumentsNeedsOriginalSnapshot(&entry.view),
        );
        try vm_call.initFrameVarRefs(ctx, global, &entry.view, &entry.frame, target.function_object.functionCapturesSlot().*, true);

        self.depth += 1;
        self.switched = true;
    }

    fn reinitEntry(
        self: *Machine,
        global: *core.Object,
        entry: *Entry,
        caller_stack: *stack_mod.Stack,
        target: InlineTarget,
        region_base: usize,
        argc: u16,
    ) HostError!void {
        const ctx = self.ctx;
        const rt = ctx.runtime;

        entry.stack.deinit(rt);
        entry.eval_snapshot.deinit(rt);
        entry.frame.deinit(&rt.memory, rt);
        rt.vm_stack.restore(entry.arena_mark);

        entry.view = bytecode.function.asBytecodeView(target.fb, rt);
        entry.catch_target = null;
        entry.arena_mark = rt.vm_stack.mark();

        const operand_window = rt.vm_stack.carve(&rt.memory, @as(usize, entry.view.stack_size) + 1);
        entry.stack = if (operand_window) |window|
            stack_mod.Stack.initArenaWindow(&rt.memory, rt.stack_size, window)
        else
            stack_mod.Stack.init(&rt.memory, rt.stack_size);
        errdefer entry.stack.deinit(rt);

        entry.frame = frame_mod.Frame.init(&entry.view);
        errdefer entry.frame.deinit(&rt.memory, rt);
        ctx.borrowBacktracePc(&entry.frame.pc);

        const fb_strict = entry.view.flags.is_strict or entry.view.flags.runtime_strict;
        const effective_this = if (fb_strict) core.JSValue.undefinedValue() else global.value();
        entry.eval_snapshot = try entry.frame.initCallBindings(rt, .{
            .initial_this_value = effective_this,
            .current_function_value = target.callable,
            .new_target_value = core.JSValue.undefinedValue(),
            .constructor_this_value = core.JSValue.undefinedValue(),
            .eval_local_names = &.{},
            .eval_local_slots = &.{},
            .input_eval_var_ref_names = &.{},
            .input_eval_var_refs = &.{},
            .inherited_eval_local_names = &.{},
            .inherited_eval_local_slots = &.{},
            .inherited_eval_var_ref_names = &.{},
            .inherited_eval_var_refs = &.{},
        });
        errdefer entry.eval_snapshot.deinit(rt);

        entry.frame_roots.deinit();
        entry.frame_roots = .{};
        entry.frame_roots.init(rt, &entry.stack, &entry.frame, &entry.eval_snapshot);

        try vm_call.initFrameLocals(ctx, &entry.view, &entry.frame, &.{}, &.{}, true);
        popCallFuncFromStack(rt, caller_stack, region_base);
        try entry.frame.initArgumentsFromStack(
            &rt.memory,
            &rt.vm_stack,
            caller_stack,
            argc,
            true,
            frame_mod.argumentsNeedsOriginalSnapshot(&entry.view),
        );
        try vm_call.initFrameVarRefs(ctx, global, &entry.view, &entry.frame, target.function_object.functionCapturesSlot().*, true);
        entry.frame.pc = 0;
    }

    /// Reuse the current inline frame for a tail call instead of growing the
    /// inline stack. Falls back to `pushCall` when no inline frame is active.
    pub fn tailCallReuse(
        self: *Machine,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        target: InlineTarget,
        region_base: usize,
        argc: u16,
    ) HostError!void {
        std.debug.assert(self.depth > 0);
        try self.reinitEntry(global, self.topEntry(), caller_stack, target, region_base, argc);
        self.switched = true;
    }

    /// Tear down the top inline frame. Mirrors the defer chain of the
    /// recursive `runWithArgsState` + `callFunctionBytecodeModeState` exit
    /// path (roots, eval snapshot, frame, operand stack, arena watermark,
    /// backtrace, profile scope, call depth).
    fn popTeardown(self: *Machine) void {
        const ctx = self.ctx;
        const rt = ctx.runtime;
        const entry = self.topEntry();
        entry.frame_roots.deinit();
        entry.eval_snapshot.deinit(rt);
        entry.frame.deinit(&rt.memory, rt);
        entry.stack.deinit(rt);
        rt.vm_stack.restore(entry.arena_mark);
        ctx.popBacktraceFrame();
        entry.profile_guard.deinit();
        ctx.call_depth -= 1;
        self.depth -= 1;
        self.switched = true;
    }

    /// Pop the top inline frame after a completed return, pushing `result`
    /// onto the caller's operand stack. Takes ownership of `result`.
    pub fn popReturn(self: *Machine, result: core.JSValue) HostError!void {
        self.popTeardown();
        const caller_stack = if (self.depth == 0) self.l0_stack else &self.topEntry().stack;
        caller_stack.pushOwned(result) catch |err| {
            result.free(self.ctx.runtime);
            return err;
        };
    }

    /// Unwind inline frames looking for a catch handler for `err`. The top
    /// (faulting) frame has already had its in-frame catch attempt fail.
    /// Returns true when some lower frame caught the error; the machine's
    /// current level is then the handling frame. Returns false when the
    /// error must propagate out of the dispatch loop (all inline frames are
    /// then already torn down).
    pub fn unwindForError(self: *Machine, global: *core.Object, err: anyerror) HostError!bool {
        const ctx = self.ctx;
        while (self.depth > 0) {
            {
                const failing = self.topEntry();
                shared_vm.closeFrameDestructuringIteratorsForAbruptCompletion(ctx, self.output, global, &failing.stack, &failing.frame);
            }
            self.popTeardown();

            const stack = if (self.depth == 0) self.l0_stack else &self.topEntry().stack;
            const frame = if (self.depth == 0) self.l0_frame else &self.topEntry().frame;
            const catch_target = if (self.depth == 0) self.l0_catch_target else &self.topEntry().catch_target;
            try shared_vm.closeStackTopForOfIteratorForPendingError(ctx, self.output, global, stack);
            if (try shared_vm.tryCatchInFrame(ctx, stack, frame, catch_target, global, err)) return true;
            if (self.depth == 0) return false;
        }
        return false;
    }
};
