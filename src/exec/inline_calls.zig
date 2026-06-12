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
const call_runtime = @import("call_runtime.zig");
const forof_ops = @import("forof_ops.zig");
const stack_mod = @import("stack.zig");
const vm_call = @import("vm_call.zig");

const HostError = @import("exceptions.zig").HostError;
const popCallFuncFromStack = call_runtime.popCallFuncFromStack;

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
/// that path special-cases (class constructors, arrows, cross-realm calls,
/// simple-numeric/string fusion bodies, async/generator kinds) disqualifies
/// the target so the slow path keeps handling it. Direct-eval bindings on
/// the function object are supported: `pushFrame` merges them into the
/// frame's var-ref view like `callFunctionBytecodeModeState` does.
pub fn resolveInlineTarget(global: *core.Object, func: core.JSValue) ?InlineTarget {
    const function_object = object_ops.functionObjectFromValue(func) orelse return null;
    const function_value = function_object.functionBytecodeSlot().* orelse return null;
    const fb = call_runtime.functionBytecodeFromValue(function_value) orelse return null;
    if (fb.func_kind != .normal) return null;
    if (fb.is_class_constructor or fb.is_derived_class_constructor) return null;
    // Arrow functions carry lexical this / new.target plumbing; keep them on
    // the slow path so the boxing rules stay in one place.
    if (fb.is_arrow_function) return null;
    // Fusion-recognizable bodies are handled by callSimple*Bytecode in the
    // slow path with broader matching than the pre-call fast checks.
    if (fb.simple_numeric_kind != .none or fb.simple_string_kind != .none) return null;
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
    /// Owned merged slices backing `view.var_ref_names` / the frame's
    /// var-ref initialization when the callee carries direct-eval bindings
    /// (mirrors `callFunctionBytecodeModeState`'s combined slices). The
    /// contents are borrowed (atoms from the function bytecode and the
    /// function object's eval-binding slots stay alive via the frame's
    /// `current_function` reference); only the slice storage is owned.
    merged_var_ref_names: []core.Atom,
    merged_var_refs: []core.JSValue,
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
            call_runtime.closeFrameDestructuringIteratorsForAbruptCompletion(self.ctx, self.output, self.global, &entry.stack, &entry.frame);
            self.popTeardown();
        }
        for (self.chunks[0..self.chunk_count]) |chunk| {
            self.ctx.runtime.memory.destroy(@TypeOf(chunk.*), chunk);
        }
        self.chunk_count = 0;
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
            _ = exception_ops.throwRangeErrorMessage(self.ctx, global, "Maximum call stack size exceeded") catch |err| return err;
            return error.RangeError;
        }
        if (chunk_index == self.chunk_count) {
            self.chunks[chunk_index] = try self.ctx.runtime.memory.create([entries_per_chunk]Entry);
            self.chunk_count += 1;
        }
        return self.entryAt(index);
    }

    /// Where the new frame's `func | args...` call region comes from.
    const ArgsSource = union(enum) {
        /// Region still live on the caller's operand stack; it is popped
        /// (func freed, args moved) during frame setup, after the bindings
        /// have duplicated the callable.
        stack_region: struct {
            stack: *stack_mod.Stack,
            region_base: usize,
            argc: u16,
        },
        /// Region already moved off a torn-down frame's operand stack for
        /// tail-call frame reuse; slot 0 is the callable, the rest are the
        /// args. Entries transfer to the new frame and are replaced with
        /// undefined as they move; the caller frees whatever is left.
        moved: []core.JSValue,
    };

    /// Push an inline call frame for `target`. Shared between plain inline
    /// calls (`pushCall`) and tail-call frame reuse (`tailCallReuse`).
    fn pushFrame(self: *Machine, global: *core.Object, target: InlineTarget, source: ArgsSource) HostError!void {
        const ctx = self.ctx;
        const rt = ctx.runtime;

        try vm_call.enterInlineCallDepth(ctx, global);
        errdefer ctx.call_depth -= 1;

        const entry = try self.acquireSlot(global);
        entry.view = bytecode.function.asBytecodeView(target.fb, rt);
        entry.catch_target = null;
        entry.merged_var_ref_names = &.{};
        entry.merged_var_refs = &.{};
        entry.profile_guard = vm_call.enterCallProfile(rt);
        errdefer entry.profile_guard.deinit();

        const callable = switch (source) {
            .stack_region => target.callable,
            .moved => |moved| moved[0],
        };

        // Direct-eval bindings extend the callee's var-ref view, mirroring
        // the combined slices `callFunctionBytecodeModeState` builds on the
        // recursive path. Contents are borrowed; storage is entry-owned.
        const eval_names = target.function_object.functionEvalLocalNamesSlot().*;
        const eval_refs = target.function_object.functionEvalLocalRefsSlot().*;
        var frame_var_refs: []const core.JSValue = target.function_object.functionCapturesSlot().*;
        if (eval_names.len > 0 and eval_refs.len > 0) {
            try mergeEvalBindings(rt, entry, frame_var_refs, eval_names, eval_refs);
            frame_var_refs = entry.merged_var_refs;
        }
        errdefer freeMergedSlices(rt, entry);

        try ctx.pushBacktraceFrameLazyName(
            entry.view.name,
            entry.view.filename,
            entry.view.line_num,
            entry.view.col_num,
            &entry.view,
            exception_ops.resolveBacktraceLocation,
            callable,
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
            .current_function_value = callable,
            .new_target_value = core.JSValue.undefinedValue(),
            .constructor_this_value = core.JSValue.undefinedValue(),
            .eval_local_names = &.{},
            .eval_local_slots = &.{},
            .input_eval_var_ref_names = eval_names,
            .input_eval_var_refs = eval_refs,
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
        switch (source) {
            .stack_region => |region| {
                popCallFuncFromStack(rt, region.stack, region.region_base);
                try entry.frame.initArgumentsFromStack(
                    &rt.memory,
                    &rt.vm_stack,
                    region.stack,
                    region.argc,
                    true,
                    frame_mod.argumentsNeedsOriginalSnapshot(&entry.view),
                );
            },
            .moved => |moved| try entry.frame.initArgumentsMoved(
                &rt.memory,
                &rt.vm_stack,
                moved[1..],
                true,
                frame_mod.argumentsNeedsOriginalSnapshot(&entry.view),
            ),
        }
        try vm_call.initFrameVarRefs(ctx, global, &entry.view, &entry.frame, frame_var_refs, true);

        self.depth += 1;
        self.switched = true;
    }

    /// Build the entry-owned merged `var_ref_names` / var_refs slices for a
    /// callee with direct-eval bindings. On success ownership of both
    /// slices is with `entry` (released by `freeMergedSlices`).
    fn mergeEvalBindings(
        rt: *core.JSRuntime,
        entry: *Entry,
        captures: []const core.JSValue,
        eval_names: []const core.Atom,
        eval_refs: []const core.JSValue,
    ) HostError!void {
        const add_len = @min(eval_names.len, eval_refs.len);
        const old_names = entry.view.var_ref_names;
        const names = try rt.memory.alloc(core.Atom, old_names.len + add_len);
        errdefer rt.memory.free(core.Atom, names);
        @memcpy(names[0..old_names.len], old_names);
        @memcpy(names[old_names.len..], eval_names[0..add_len]);
        const refs = try rt.memory.alloc(core.JSValue, captures.len + add_len);
        @memcpy(refs[0..captures.len], captures);
        @memcpy(refs[captures.len..], eval_refs[0..add_len]);
        entry.merged_var_ref_names = names;
        entry.merged_var_refs = refs;
        entry.view.var_ref_names = names;
    }

    fn freeMergedSlices(rt: *core.JSRuntime, entry: *Entry) void {
        if (entry.merged_var_ref_names.len != 0) rt.memory.free(core.Atom, entry.merged_var_ref_names);
        if (entry.merged_var_refs.len != 0) rt.memory.free(core.JSValue, entry.merged_var_refs);
        entry.merged_var_ref_names = &.{};
        entry.merged_var_refs = &.{};
    }

    /// Push an inline call frame for `target` whose `func | args...` region
    /// starts at `region_base` on `caller_stack`. On success the region has
    /// been popped from the caller stack and the machine's top entry is the
    /// new current execution level.
    pub fn pushCall(
        self: *Machine,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        target: InlineTarget,
        region_base: usize,
        argc: u16,
    ) HostError!void {
        return self.pushFrame(global, target, .{ .stack_region = .{
            .stack = caller_stack,
            .region_base = region_base,
            .argc = argc,
        } });
    }

    /// Proper tail call: replace the top inline frame with a fresh frame
    /// for `target`, keeping the logical call depth constant. The
    /// `func | args...` region starting at `region_base` lives on the dying
    /// frame's own operand stack, so it is moved into a scratch buffer
    /// before the frame (and the arena window backing its stack) is torn
    /// down. On error the dying frame is already gone; the error propagates
    /// as if thrown by the callee before executing any code.
    pub fn tailCallReuse(
        self: *Machine,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        target: InlineTarget,
        region_base: usize,
        argc: u16,
    ) HostError!void {
        std.debug.assert(self.depth > 0);
        const rt = self.ctx.runtime;

        const total = @as(usize, argc) + 1;
        var inline_buf: [9]core.JSValue = undefined;
        const moved: []core.JSValue = if (total <= inline_buf.len)
            inline_buf[0..total]
        else
            try rt.memory.alloc(core.JSValue, total);
        defer if (total > inline_buf.len) rt.memory.free(core.JSValue, moved);
        @memcpy(moved, caller_stack.values[region_base..][0..total]);
        caller_stack.values = caller_stack.values.ptr[0..region_base];
        // `moved` now owns the call region (the callable plus any args not
        // yet transferred into the new frame).
        defer for (moved) |value| value.free(rt);

        self.popTeardown();
        try self.pushFrame(global, target, .{ .moved = moved });
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
        freeMergedSlices(rt, entry);
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
                call_runtime.closeFrameDestructuringIteratorsForAbruptCompletion(ctx, self.output, global, &failing.stack, &failing.frame);
            }
            self.popTeardown();

            const stack = if (self.depth == 0) self.l0_stack else &self.topEntry().stack;
            const frame = if (self.depth == 0) self.l0_frame else &self.topEntry().frame;
            const catch_target = if (self.depth == 0) self.l0_catch_target else &self.topEntry().catch_target;
            try forof_ops.closeStackTopForOfIteratorForPendingError(ctx, self.output, global, stack);
            if (try call_runtime.tryCatchInFrame(ctx, stack, frame, catch_target, global, err)) return true;
            if (self.depth == 0) return false;
        }
        return false;
    }
};
