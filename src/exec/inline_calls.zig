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

/// An eligible bytecode-to-bytecode call target resolved from a callable
/// value on the operand stack. All values are borrowed from the caller's
/// (rooted) operand stack region.
/// Operand-stack layout of an inline call's region, as seen by `pushFrame`.
pub const RegionLayout = enum {
    /// `[callable, args...]` — plain call; `this` defaults to undefined.
    plain,
    /// `[receiver, callable, args...]` — method call; receiver becomes `this`.
    method,
    /// `[receiver, args..., callable]` — prepared property call: the callable
    /// was resolved off-stack (a prepared IC target) and pushed back on top,
    /// receiver becomes `this`. Only valid for non-tail `pushCall`.
    prepared,
};

pub const InlineTarget = struct {
    function_object: *core.Object,
    /// The callable closure value (becomes `frame.current_function`).
    callable: core.JSValue,
    fb: *const bytecode.FunctionBytecode,
    /// Raw receiver before [[Call]] `this` boxing: an arrow target's lexical
    /// `this` (arrows ignore any provided receiver), otherwise the call
    /// receiver — `undefined` for plain calls, the property base for method
    /// calls. `pushFrame` applies `coerceCallThis` to it. Borrowed; stays
    /// valid while `callable` is rooted (the lexical `this` is owned by the
    /// function object; a method receiver is co-owned with the operand
    /// region).
    this_value: core.JSValue,
    /// Lexical `new.target` for arrow targets, `undefined` otherwise.
    /// Borrowed; valid while `callable` is rooted.
    new_target: core.JSValue,
};

/// Resolve `func` to an inline-eligible bytecode call target for a call with
/// receiver `receiver` (`undefined` for plain calls, the property base for
/// method calls). Mirrors the plain-call leg of
/// `callValueOrBytecodeClassModeDispatch`; any condition that path
/// special-cases (class constructors, cross-realm calls, simple-numeric/string
/// fusion bodies, async/generator kinds) disqualifies the target so the slow
/// path keeps handling it. Direct-eval bindings on the function object are
/// supported: `pushFrame` merges them into the frame's var-ref view like
/// `callFunctionBytecodeModeState` does.
///
/// Arrow targets ARE eligible: an arrow has no own `this` / `new.target`, so
/// the resolved `this_value` / `new_target` come from the lexical values
/// captured on the function object (mirroring the slow path's arrow leg) and
/// `pushFrame` boxes `this_value` through the same `coerceCallThis` primitive
/// as the recursive path — the boxing rules stay in one place. Fusion arrows
/// (`x => x + 1`) are still caught by the fusion check below and routed to the
/// faster `callSimple*Bytecode` path.
pub fn resolveInlineTarget(global: *core.Object, receiver: core.JSValue, func: core.JSValue) ?InlineTarget {
    const function_object = object_ops.functionObjectFromValue(func) orelse return null;
    const function_value = function_object.functionBytecodeSlot().* orelse return null;
    const fb = call_runtime.functionBytecodeFromValue(function_value) orelse return null;
    if (fb.func_kind != .normal) return null;
    if (fb.is_class_constructor or fb.is_derived_class_constructor) return null;
    // Fusion-recognizable bodies are handled by callSimple*Bytecode in the
    // slow path with broader matching than the pre-call fast checks.
    if (fb.simple_numeric_kind != .none or fb.simple_string_kind != .none) return null;
    const function_global = object_ops.objectRealmGlobal(function_object) orelse global;
    if (function_global != global) return null;
    const this_value = if (fb.is_arrow_function)
        (function_object.functionLexicalThis() orelse core.JSValue.undefinedValue())
    else
        receiver;
    const new_target = if (fb.is_arrow_function)
        (function_object.functionArrowNewTarget() orelse core.JSValue.undefinedValue())
    else
        core.JSValue.undefinedValue();
    return .{
        .function_object = function_object,
        .callable = func,
        .fb = fb,
        .this_value = this_value,
        .new_target = new_target,
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
    backtrace_mode: BacktraceMode,
    /// Owned merged slices backing `view.var_ref_names` / the frame's
    /// var-ref initialization when the callee carries direct-eval bindings
    /// (mirrors `callFunctionBytecodeModeState`'s combined slices). The
    /// contents are borrowed (atoms from the function bytecode and the
    /// function object's eval-binding slots stay alive via the frame's
    /// `current_function` reference); only the slice storage is owned.
    merged_var_ref_names: []core.Atom,
    merged_var_refs: []core.JSValue,
};

const BacktraceMode = enum { owned, borrowed_atoms };

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
    pub const ArgsSource = union(enum) {
        /// Region still live on the caller's operand stack; it is popped
        /// (receiver/func freed, args moved) during frame setup, after the
        /// bindings have duplicated them. Layout is `[callable, args...]`, or
        /// `[receiver, callable, args...]` when `has_receiver` (a non-tail
        /// method call; the receiver becomes the new frame's `this`).
        stack_region: struct {
            stack: *stack_mod.Stack,
            region_base: usize,
            argc: u16,
            has_receiver: bool,
        },
        /// Region already moved off a torn-down frame's operand stack for
        /// tail-call frame reuse. Layout is `[callable, args...]`, or
        /// `[receiver, callable, args...]` when `has_receiver` (a method tail
        /// call). Entries transfer to the new frame and are replaced with
        /// undefined as they move; the caller frees whatever is left.
        moved: struct {
            values: []core.JSValue,
            has_receiver: bool,
        },
        /// Prepared property call still live on the caller's operand stack as
        /// `[receiver, args..., callable]`: the callable (an off-stack prepared
        /// IC target) was pushed back on top so it stays rooted until the frame
        /// duplicates it. Frame setup pops+frees the callable, drops the
        /// receiver (now the frame's `this`), and moves the args.
        prepared: struct {
            stack: *stack_mod.Stack,
            region_base: usize,
            argc: u16,
        },
    };

    /// Push an inline call frame for `target`. Shared between plain inline
    /// calls (`pushCall`) and tail-call frame reuse (`tailCallReuse`).
    fn pushFrame(self: *Machine, global: *core.Object, target: InlineTarget, source: ArgsSource) HostError!void {
        try vm_call.enterInlineCallDepth(self.ctx, global);
        errdefer self.ctx.call_depth -= 1;
        const entry = try self.acquireSlot(global);
        try setupInlineEntry(self.ctx, global, entry, target, source);
        self.depth += 1;
        self.switched = true;
    }

    /// Optimized inline-call frame setup, factored out of `pushFrame` so the
    /// Machine shares the zero-copy arg move (`initArgumentsMoved`), eval-binding
    /// merge, this-boxing and arena carve — NOT the dup-heavy
    /// `callFunctionBytecodeModeState` path.
    /// The caller owns depth accounting (enterInlineCallDepth / enterCallDepth)
    /// and any push/pop bookkeeping; on error every partially-initialized
    /// resource is released via the errdefers below.
    pub fn setupInlineEntry(ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: InlineTarget, source: ArgsSource) HostError!void {
        const rt = ctx.runtime;
        entry.view = bytecode.function.asBytecodeView(target.fb, rt);
        entry.catch_target = null;
        entry.merged_var_ref_names = &.{};
        entry.merged_var_refs = &.{};
        entry.profile_guard = vm_call.enterCallProfile(rt);
        errdefer entry.profile_guard.deinit();

        const callable_slot = sourceCallableSlot(source);
        const callable = callable_slot.*;

        // Direct-eval bindings extend the callee's var-ref view, mirroring
        // the combined slices `callFunctionBytecodeModeState` builds on the
        // recursive path. Contents are borrowed; storage is entry-owned.
        const eval_names = target.function_object.functionEvalLocalNames();
        const eval_refs = target.function_object.functionEvalLocalRefs();
        var frame_var_refs: []const core.JSValue = target.function_object.functionCapturesSlot().*;
        if (eval_names.len > 0 and eval_refs.len > 0) {
            try mergeEvalBindings(rt, entry, frame_var_refs, eval_names, eval_refs);
            frame_var_refs = entry.merged_var_refs;
        }
        errdefer freeMergedSlices(rt, entry);

        entry.backtrace_mode = try pushInlineBacktraceFrame(
            ctx,
            entry.view.name,
            entry.view.filename,
            entry.view.line_num,
            entry.view.col_num,
            &entry.view,
            exception_ops.resolveBacktraceLocation,
            callable,
        );
        errdefer popInlineBacktraceFrame(ctx, entry.backtrace_mode);

        entry.arena_mark = rt.vm_stack.mark();
        errdefer rt.vm_stack.restore(entry.arena_mark);

        const operand_window = rt.vm_stack.carve(&rt.memory, @as(usize, entry.view.stack_size) + 1);
        entry.stack = if (operand_window) |window|
            stack_mod.Stack.initArenaWindow(&rt.memory, rt.stack_size, window)
        else
            stack_mod.Stack.init(&rt.memory, rt.stack_size);
        try entry.stack.reserveFrameCapacity(entry.view.stack_size);
        errdefer entry.stack.deinit(rt);

        entry.frame = frame_mod.Frame.init(&entry.view);
        errdefer entry.frame.deinit(&rt.memory, rt);
        ctx.borrowBacktracePc(&entry.frame.pc);

        // Box `this` through the same primitive the recursive slow path uses
        // (`callFunctionBytecodeModeState`): for a plain non-arrow call
        // `target.this_value` is undefined and boxes to global / undefined by
        // strictness, exactly as before; arrow targets carry their lexical
        // `this`, and method tail calls carry the receiver. `initCallBindings`
        // dups the result, so the freshly boxed primitive wrapper (if any) is
        // released after the frame has captured it.
        var boxed_this: ?core.JSValue = null;
        defer if (boxed_this) |value| value.free(rt);
        const fb_strict = target.fb.is_strict_mode or target.fb.runtime_strict_mode;
        const effective_this = try call_runtime.coerceCallThis(ctx, global, fb_strict, target.this_value, &boxed_this);

        const receiver_slot = sourceReceiverSlot(source);
        var take_receiver_as_this = false;
        if (boxed_this == null and !target.fb.is_arrow_function) {
            if (receiver_slot) |slot| {
                if (effective_this.same(slot.*)) {
                    take_receiver_as_this = true;
                }
            }
        }

        var cleanup_source: SourceCleanupMode = if (sourceHasStackRegion(source)) .full else .none;
        errdefer cleanupSource(rt, source, cleanup_source);

        // Bind the frame values INLINE — qjs's JS_CallInternal sets cur_func /
        // this / new_target directly rather than threading a 14-field
        // CallBindingInputs descriptor through initCallBindingValues. This is
        // the common-path equivalent; ownership flags must mirror the old
        // bindCallValue/modeOwnsValue result EXACTLY (Frame.deinit frees by
        // these flags, and the frame.deinit errdefer above covers a later
        // failure):
        //   current_function .take  -> owns the callable's transferred ref
        //   new_target / constructor_this .borrow -> not owned
        //   this .borrow, unless boxed (sloppy primitive `this`) or taken from
        //   the receiver slot (method call) -> then .take/owned.
        // `takeSourceSlot` nulls the source slot so the popped stack region
        // never double-frees the value (the leak guard the method-call comment
        // below describes).
        entry.frame.current_function = takeSourceSlot(callable_slot);
        entry.frame.current_function_owned = true;
        entry.frame.new_target = target.new_target;
        entry.frame.new_target_owned = false;
        entry.frame.constructor_this_value = core.JSValue.undefinedValue();
        entry.frame.constructor_this_value_owned = false;
        if (boxed_this) |boxed| {
            entry.frame.this_value = boxed;
            entry.frame.this_value_owned = true;
            boxed_this = null;
        } else if (take_receiver_as_this) {
            entry.frame.this_value = takeSourceSlot(receiver_slot.?);
            entry.frame.this_value_owned = true;
        } else {
            entry.frame.this_value = effective_this;
            entry.frame.this_value_owned = false;
        }

        entry.eval_snapshot = .{};
        entry.frame_roots = .{};
        const argc = sourceArgCount(source);
        const frame_arg_count = @max(argc, @as(usize, @intCast(entry.view.arg_count)));
        const need_original_args = argc > 0 and frame_mod.argumentsNeedsOriginalSnapshot(&entry.view);
        const need_eval_var_refs = eval_names.len != 0 or eval_refs.len != 0;
        entry.frame_roots.initWithOptions(rt, &entry.stack, &entry.frame, &entry.eval_snapshot, .{
            .locals = entry.view.var_count != 0,
            .args = frame_arg_count != 0,
            .original_args = need_original_args,
            .var_refs = frame_var_refs.len != 0 or entry.view.var_ref_names.len != 0,
            .eval_local_slots = false,
            .eval_var_refs = need_eval_var_refs,
            .prepared_call_values = true,
        });
        errdefer entry.frame_roots.deinit();

        // Direct-eval bindings are COLD: only build the snapshot when the callee
        // actually carries eval-introduced var refs. The common call leaves
        // `eval_snapshot` empty (its deinit is a no-op) and the frame's eval_*
        // fields keep their empty Frame.init defaults — byte-identical to what
        // the old unconditional initCallEvalBindings produced for no-eval.
        if (need_eval_var_refs) {
            entry.eval_snapshot = try entry.frame.initCallEvalBindings(rt, .{
                .initial_this_value = effective_this,
                .current_function_value = callable,
                .new_target_value = target.new_target,
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
        }
        errdefer entry.eval_snapshot.deinit(rt);

        try vm_call.initFrameLocals(ctx, &entry.view, &entry.frame, &.{}, &.{}, true);
        const need_original_snapshot = frame_mod.argumentsNeedsOriginalSnapshot(&entry.view);
        if (canBorrowSourceArgs(&entry.view, source)) {
            try entry.frame.initArgumentsBorrowedSlots(
                &rt.memory,
                sourceArgs(source),
                true,
                need_original_snapshot,
            );
            cleanup_source = .non_args;
        } else {
            try entry.frame.initArgumentsMoved(
                &rt.memory,
                &rt.vm_stack,
                sourceArgs(source),
                true,
                need_original_snapshot,
            );
        }
        cleanupSource(rt, source, cleanup_source);
        cleanup_source = .none;

        if (frame_var_refs.len != 0 or entry.view.var_ref_names.len != 0) {
            try vm_call.initFrameVarRefs(ctx, global, &entry.view, &entry.frame, frame_var_refs, true);
        }
    }

    fn sourceCallableSlot(source: ArgsSource) *core.JSValue {
        return switch (source) {
            .stack_region => |region| &region.stack.values[region.region_base + @as(usize, @intFromBool(region.has_receiver))],
            .moved => |moved| &moved.values[if (moved.has_receiver) 1 else 0],
            .prepared => |region| &region.stack.values[region.region_base + 1 + @as(usize, region.argc)],
        };
    }

    fn sourceReceiverSlot(source: ArgsSource) ?*core.JSValue {
        return switch (source) {
            .stack_region => |region| if (region.has_receiver) &region.stack.values[region.region_base] else null,
            .moved => |moved| if (moved.has_receiver) &moved.values[0] else null,
            .prepared => |region| &region.stack.values[region.region_base],
        };
    }

    fn takeSourceSlot(slot: *core.JSValue) core.JSValue {
        const value = slot.*;
        slot.* = core.JSValue.undefinedValue();
        return value;
    }

    fn sourceHasStackRegion(source: ArgsSource) bool {
        return switch (source) {
            .stack_region, .prepared => true,
            .moved => false,
        };
    }

    fn sourceArgCount(source: ArgsSource) usize {
        return switch (source) {
            .stack_region => |region| region.argc,
            .moved => |moved| moved.values.len - if (moved.has_receiver) @as(usize, 2) else @as(usize, 1),
            .prepared => |region| region.argc,
        };
    }

    fn sourceArgs(source: ArgsSource) []core.JSValue {
        return switch (source) {
            .stack_region => |region| blk: {
                const args_start = region.region_base + 1 + @as(usize, @intFromBool(region.has_receiver));
                break :blk region.stack.values[args_start..][0..region.argc];
            },
            .moved => |moved| moved.values[if (moved.has_receiver) 2 else 1..],
            .prepared => |region| region.stack.values[region.region_base + 1 ..][0..region.argc],
        };
    }

    fn canBorrowSourceArgs(function: *const bytecode.Bytecode, source: ArgsSource) bool {
        const argc = sourceArgCount(source);
        if (argc == 0) return false;
        if (@max(argc, @as(usize, @intCast(function.arg_count))) != argc) return false;
        return switch (source) {
            .stack_region, .prepared => true,
            .moved => false,
        };
    }

    const SourceCleanupMode = enum {
        none,
        full,
        non_args,
    };

    fn cleanupSource(rt: *core.JSRuntime, source: ArgsSource, mode: SourceCleanupMode) void {
        switch (mode) {
            .none => {},
            .full => cleanupStackSource(rt, source),
            .non_args => cleanupStackSourcePreserveArgs(rt, source),
        }
    }

    fn cleanupStackSource(rt: *core.JSRuntime, source: ArgsSource) void {
        switch (source) {
            .stack_region => |region| call_runtime.popOwnedStackRegion(rt, region.stack, region.region_base),
            .prepared => |region| call_runtime.popOwnedStackRegion(rt, region.stack, region.region_base),
            .moved => {},
        }
    }

    fn cleanupStackSourcePreserveArgs(rt: *core.JSRuntime, source: ArgsSource) void {
        switch (source) {
            .stack_region => |region| {
                if (region.has_receiver) freeSourceSlot(rt, &region.stack.values[region.region_base]);
                freeSourceSlot(rt, &region.stack.values[region.region_base + @as(usize, @intFromBool(region.has_receiver))]);
                region.stack.values = region.stack.values.ptr[0..region.region_base];
            },
            .prepared => |region| {
                freeSourceSlot(rt, &region.stack.values[region.region_base]);
                freeSourceSlot(rt, &region.stack.values[region.region_base + 1 + @as(usize, region.argc)]);
                region.stack.values = region.stack.values.ptr[0..region.region_base];
            },
            .moved => {},
        }
    }

    fn freeSourceSlot(rt: *core.JSRuntime, slot: *core.JSValue) void {
        const value = slot.*;
        slot.* = core.JSValue.undefinedValue();
        value.free(rt);
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

    /// Push an inline call frame for `target` whose operand region starts at
    /// `region_base` on `caller_stack`, shaped by `layout` (see `RegionLayout`).
    /// On success the region has been popped from the caller stack and the
    /// machine's top entry is the new current execution level.
    pub fn pushCall(
        self: *Machine,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        target: InlineTarget,
        region_base: usize,
        argc: u16,
        layout: RegionLayout,
    ) HostError!void {
        return self.pushFrame(global, target, switch (layout) {
            .plain, .method => .{ .stack_region = .{
                .stack = caller_stack,
                .region_base = region_base,
                .argc = argc,
                .has_receiver = layout == .method,
            } },
            .prepared => .{ .prepared = .{
                .stack = caller_stack,
                .region_base = region_base,
                .argc = argc,
            } },
        });
    }

    /// Proper tail call: replace the top inline frame with a fresh frame
    /// for `target`, keeping the logical call depth constant. The operand
    /// region starting at `region_base` lives on the dying frame's own
    /// operand stack, so it is moved into a scratch buffer before the frame
    /// (and the arena window backing its stack) is torn down. The region is
    /// `[callable, args...]`, or `[receiver, callable, args...]` when
    /// `has_receiver` (a tail-positioned method call, where the receiver
    /// becomes the reused frame's `this`). On error the dying frame is
    /// already gone; the error propagates as if thrown by the callee before
    /// executing any code.
    pub fn tailCallReuse(
        self: *Machine,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        target: InlineTarget,
        region_base: usize,
        argc: u16,
        layout: RegionLayout,
    ) HostError!void {
        std.debug.assert(self.depth > 0);
        // Tail calls are never the off-stack prepared shape; only op.call /
        // op.call_method get rewritten to the prepared IC path, and those are
        // not tail positions.
        std.debug.assert(layout != .prepared);
        const has_receiver = layout == .method;
        const rt = self.ctx.runtime;

        const total = @as(usize, argc) + 1 + @as(usize, @intFromBool(has_receiver));
        var inline_buf: [10]core.JSValue = undefined;
        const moved: []core.JSValue = if (total <= inline_buf.len)
            inline_buf[0..total]
        else
            try rt.memory.alloc(core.JSValue, total);
        defer if (total > inline_buf.len) rt.memory.free(core.JSValue, moved);
        @memcpy(moved, caller_stack.values[region_base..][0..total]);
        caller_stack.values = caller_stack.values.ptr[0..region_base];
        // `moved` now owns the call region (the receiver and callable plus any
        // args not yet transferred into the new frame).
        defer for (moved) |value| value.free(rt);

        self.popTeardown();
        try self.pushFrame(global, target, .{ .moved = .{ .values = moved, .has_receiver = has_receiver } });
    }

    /// Tear down the top inline frame. Mirrors the defer chain of the
    /// recursive `runWithArgsState` + `callFunctionBytecodeModeState` exit
    /// path (roots, eval snapshot, frame, operand stack, arena watermark,
    /// backtrace, profile scope, call depth).
    fn popTeardown(self: *Machine) void {
        teardownInlineEntry(self.ctx, self.topEntry());
        self.ctx.call_depth -= 1;
        self.depth -= 1;
        self.switched = true;
    }

    /// Release every resource `setupInlineEntry` acquired for `entry` (roots,
    /// eval snapshot, frame, operand stack, merged slices, arena watermark,
    /// backtrace, profile scope). The caller owns depth accounting + push/pop
    /// bookkeeping. Shared by the Machine (popTeardown) and the recursion path.
    pub fn teardownInlineEntry(ctx: *core.JSContext, entry: *Entry) void {
        const rt = ctx.runtime;
        entry.frame_roots.deinit();
        entry.eval_snapshot.deinit(rt);
        entry.frame.deinit(&rt.memory, rt);
        entry.stack.deinit(rt);
        freeMergedSlices(rt, entry);
        rt.vm_stack.restore(entry.arena_mark);
        popInlineBacktraceFrame(ctx, entry.backtrace_mode);
        entry.profile_guard.deinit();
    }

    /// Pop the top inline frame after a completed return, pushing `result`
    /// onto the caller's operand stack. Takes ownership of `result`.
    pub fn popReturn(self: *Machine, result: core.JSValue) HostError!void {
        self.popTeardown();
        const caller_stack = if (self.depth == 0) self.l0_stack else &self.topEntry().stack;
        caller_stack.pushOwnedAssumeCapacity(result);
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

fn pushInlineBacktraceFrame(
    ctx: *core.JSContext,
    function_name: core.Atom,
    filename: core.Atom,
    line_num: i32,
    col_num: i32,
    location_data: ?*const anyopaque,
    location_resolver: core.context.BacktraceLocationResolver,
    function_value: core.JSValue,
) !BacktraceMode {
    const name = ctx.runtime.atoms.name(function_name) orelse "";
    const file = ctx.runtime.atoms.name(filename) orelse "";
    if (name.len == 0 or std.mem.eql(u8, name, file)) {
        try ctx.pushBacktraceFrameLazyName(function_name, filename, line_num, col_num, location_data, location_resolver, function_value);
        return .owned;
    }

    if (ctx.backtrace_frames.len == ctx.backtrace_capacity) {
        var next_capacity: usize = if (ctx.backtrace_capacity == 0) 16 else ctx.backtrace_capacity * 2;
        if (next_capacity < ctx.backtrace_frames.len + 1) next_capacity = ctx.backtrace_frames.len + 1;
        const next = try ctx.runtime.memory.alloc(core.BacktraceFrame, next_capacity);
        const old_frames = ctx.backtrace_frames;
        const old_capacity = ctx.backtrace_capacity;
        @memcpy(next[0..old_frames.len], old_frames);
        ctx.backtrace_frames = next[0..old_frames.len];
        ctx.backtrace_capacity = next_capacity;
        if (old_capacity != 0) ctx.runtime.memory.free(core.BacktraceFrame, old_frames.ptr[0..old_capacity]);
    }
    ctx.backtrace_frames.ptr[ctx.backtrace_frames.len] = .{
        .function_name = function_name,
        .filename = filename,
        .line_num = line_num,
        .col_num = col_num,
        .location_data = location_data,
        .location_resolver = location_resolver,
        .function_value = core.JSValue.undefinedValue(),
    };
    ctx.backtrace_frames = ctx.backtrace_frames.ptr[0 .. ctx.backtrace_frames.len + 1];
    return .borrowed_atoms;
}

fn popInlineBacktraceFrame(ctx: *core.JSContext, mode: BacktraceMode) void {
    switch (mode) {
        .owned => ctx.popBacktraceFrame(),
        .borrowed_atoms => {
            if (ctx.backtrace_frames.len == 0) return;
            ctx.backtrace_frames = ctx.backtrace_frames.ptr[0 .. ctx.backtrace_frames.len - 1];
        },
    }
}
