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

const bytecode = @import("../bytecode.zig");
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
};

pub const InlineTarget = struct {
    function_object: *core.Object,
    /// The callable closure value (becomes `frame.current_function`).
    callable: core.JSValue,
    fb: *const bytecode.FunctionBytecode,
    /// The execution view (a `bytecode.Bytecode`). VALID ONLY when
    /// `cached_view == null` (the rare fixture/synthetic FB with no debug box to
    /// cache in); otherwise it is `undefined` and readers must go through
    /// `viewPtr()`. qjs dispatches straight from `JSFunctionBytecode*`; zjs still
    /// runs the older `bytecode.Bytecode` API, so it uses a per-FB cached view
    /// (`cachedBytecodeView`) built once, avoiding the per-call rebuild+copy.
    view: bytecode.Bytecode,
    /// Pointer to the per-FB cached execution view when available (the common
    /// case). Non-null lets `pushFrame` point the entry's `function` straight at
    /// the pointer-stable cache with NO per-call copy; null means the view was
    /// rebuilt into `view` and must be copied into `view_storage`.
    cached_view: ?*const bytecode.Bytecode = null,
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

    /// The live execution view: the pointer-stable per-FB cache when present,
    /// otherwise the by-value `view` rebuilt for this call. All view readers use
    /// this so `view` may stay `undefined` on the cached path.
    inline fn viewPtr(self: *const InlineTarget) *const bytecode.Bytecode {
        return self.cached_view orelse &self.view;
    }
};

/// Resolve `func` to an inline-eligible bytecode call target for a call with
/// receiver `receiver` (`undefined` for plain calls, the property base for
/// method calls). Mirrors the plain-call leg of
/// `callValueOrBytecodeClassModeDispatch`; any condition that path
/// special-cases (class constructors, cross-realm calls, async/generator kinds)
/// disqualifies the target so the slow
/// path keeps handling it. Direct-eval bindings on the function object are
/// supported: `pushFrame` merges them into the frame's var-ref view like
/// `callFunctionBytecodeModeState` does.
///
/// Arrow targets ARE eligible: an arrow has no own `this` / `new.target`, so
/// the resolved `this_value` / `new_target` come from the lexical values
/// captured on the function object (mirroring the slow path's arrow leg) and
/// `pushFrame` boxes `this_value` through the same `coerceCallThis` primitive
/// as the recursive path — the boxing rules stay in one place.
pub inline fn resolveInlineTarget(ctx: *core.JSContext, global: *core.Object, receiver: core.JSValue, func: core.JSValue) ?InlineTarget {
    const function_object = object_ops.functionObjectFromValue(func) orelse return null;
    const function_value = function_object.functionBytecodeSlot().* orelse return null;
    const fb = call_runtime.functionBytecodeFromValue(function_value) orelse return null;
    if (fb.flags.func_kind != .normal) return null;
    if (fb.flags.is_class_constructor or fb.flags.is_derived_class_constructor) return null;
    const function_global = object_ops.objectRealmGlobal(function_object) orelse global;
    if (function_global != global) return null;
    const this_value = if (fb.flags.is_arrow_function)
        (function_object.functionLexicalThis() orelse core.JSValue.undefinedValue())
    else
        receiver;
    const new_target = if (fb.flags.is_arrow_function)
        (function_object.functionArrowNewTarget() orelse core.JSValue.undefinedValue())
    else
        core.JSValue.undefinedValue();
    const rt = ctx.runtime;
    // Point at the per-FB cached execution view (built once) with no per-call
    // copy; fall back to a per-call rebuild only when the FB has no debug box to
    // cache in. Restores the `execution_view` cache the struct-alignment program
    // removed, and — via the `cached_view` pointer threaded into `pushFrame` —
    // also drops the per-call 300B copy into `view_storage`.
    if (bytecode.cachedBytecodeView(fb, &rt.memory, &rt.atoms)) |cached| {
        return .{
            .function_object = function_object,
            .callable = func,
            .fb = fb,
            .view = undefined,
            .cached_view = cached,
            .this_value = this_value,
            .new_target = new_target,
        };
    }
    return .{
        .function_object = function_object,
        .callable = func,
        .fb = fb,
        .view = bytecode.makeBytecodeView(fb, &rt.memory, &rt.atoms),
        .cached_view = null,
        .this_value = this_value,
        .new_target = new_target,
    };
}

/// One suspended-or-active inline call level. Entries live in chunked,
/// pointer-stable storage; `frame`, `stack`, and `view` are referenced by
/// the dispatch loop and backtrace pc borrows while the
/// level is alive.
pub const Entry = struct {
    /// Entry-owned backing store for the execution view built from the target's
    /// FunctionBytecode. `function` points here for a plain call (the Entry slots
    /// are pointer-stable chunked storage, so `&view_storage` stays valid for the
    /// whole call). qjs dispatches straight from `JSFunctionBytecode*`; zjs runs
    /// the older `bytecode.Bytecode` API and rebuilds this view per call.
    view_storage: bytecode.Bytecode,
    function: *const bytecode.Bytecode,
    /// Eval-only side view used when direct-eval bindings extend
    /// `function.var_ref_names`. Common calls point `function` at `view_storage`.
    eval_function_view: ?*bytecode.Bytecode,
    frame: frame_mod.Frame,
    eval_snapshot: frame_mod.EvalVarRefSnapshot,
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
    /// True when the callee carries no direct-eval bindings: `eval_snapshot`
    /// stays the empty default, `merged_*` stay empty, and `eval_function_view`
    /// stays null. Teardown then skips `eval_snapshot.deinit` / `freeEvalResources`
    /// entirely — both are provably no-ops for such a frame, but each is a
    /// non-inlined call paid on every plain call. Mirrors qjs's `done:` epilogue
    /// (quickjs.c:20698) freeing only what the frame actually allocated.
    simple_frame: bool,
};

const entries_per_chunk: usize = 16;
const max_chunks: usize = 512;

/// One backtrace node per VM invocation — qjs's `current_stack_frame`
/// granularity. It walks this invocation's whole frame group: the inline
/// Machine Entry chain (innermost first) then the L0 frame. `machine` is null
/// during pre-dispatch frame setup (depth 0); the L0 frame alone covers it.
/// Replaces the former per-call `ActiveBacktraceFrame` push/pop, faithful to
/// qjs walking the same frame chain it executes on (quickjs.c:7571).
pub const MachineBacktrace = struct {
    l0_frame: *frame_mod.Frame,
    machine: ?*Machine = null,
};

/// Indexed `ActiveBacktraceResolver` for `MachineBacktrace`: index 0 is the
/// innermost inline frame, walking outward to the L0 frame; null past the end.
pub fn resolveMachineBacktrace(data: ?*const anyopaque, index: usize) ?core.ActiveBacktraceSnapshot {
    const holder: *const MachineBacktrace = @ptrCast(@alignCast(data.?));
    if (holder.machine) |machine| {
        const depth = machine.depth;
        if (index < depth) return exception_ops.frameBacktraceSnapshot(&machine.entryAt(depth - 1 - index).frame);
        if (index == depth) return exception_ops.frameBacktraceSnapshot(holder.l0_frame);
        return null;
    }
    if (index == 0) return exception_ops.frameBacktraceSnapshot(holder.l0_frame);
    return null;
}

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
    /// The chunk-pointer array is heap-allocated lazily on the first inline
    /// push (capacity `max_chunks`), so a Machine that never pushes carries
    /// only a 16-byte empty slice instead of a 4 KiB inline array — keeping
    /// `Machine.init`'s by-value return from memcpy-ing 4 KiB of (undefined)
    /// chunk-pointer storage on every interpreter entry.
    chunks: []*[entries_per_chunk]Entry = &.{},
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
        if (self.chunks.len != 0) {
            self.ctx.runtime.memory.free(*[entries_per_chunk]Entry, self.chunks);
            self.chunks = &.{};
        }
    }

    pub fn topEntry(self: *Machine) *Entry {
        std.debug.assert(self.depth > 0);
        return self.entryAt(self.depth - 1);
    }

    pub fn entryAt(self: *Machine, index: usize) *Entry {
        return &self.chunks[index / entries_per_chunk][index % entries_per_chunk];
    }

    fn acquireSlot(self: *Machine, global: *core.Object) HostError!*Entry {
        const index = self.depth;
        const chunk_index = index / entries_per_chunk;
        if (chunk_index >= max_chunks) {
            // QuickJS throws InternalError "stack overflow" for call-depth
            // exhaustion (JS_ThrowStackOverflow at the JS_CallInternal guard,
            // quickjs.c:17837/7789), not a RangeError.
            _ = exception_ops.throwInternalErrorMessage(self.ctx, global, "stack overflow") catch |err| return err;
            return error.StackOverflow;
        }
        if (chunk_index == self.chunk_count) {
            if (self.chunks.len == 0) {
                self.chunks = try self.ctx.runtime.memory.alloc(*[entries_per_chunk]Entry, max_chunks);
            }
            const chunk = try self.ctx.runtime.memory.create([entries_per_chunk]Entry);
            self.chunks[chunk_index] = chunk;
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
    };

    /// Push an inline call frame for `target`. Shared between plain inline
    /// calls (`pushCall`) and tail-call frame reuse (`tailCallReuse`).
    fn pushFrame(self: *Machine, global: *core.Object, target: InlineTarget, source: ArgsSource) HostError!void {
        try vm_call.enterInlineCallDepth(self.ctx, global);
        errdefer self.ctx.call_depth -= 1;
        const entry = try self.acquireSlot(global);
        if (isSimpleInlineFrame(&target, source))
            try setupSimpleInlineEntry(self.ctx, global, entry, &target, source)
        else
            try setupInlineEntry(self.ctx, global, entry, &target, source);
        self.depth += 1;
        self.switched = true;
    }

    /// True when the frame takes the straight-line `setupSimpleInlineEntry` path:
    /// a sloppy, non-arrow plain call (no receiver, undefined `this` → global)
    /// with simple parameters (no original-args snapshot), no direct-eval bindings
    /// / eval-call / global-var rebinds, args that can be borrowed in place, and
    /// all-cell closure captures (borrowable as `var_refs`). Each rejected
    /// condition is exactly a branch the lean path elides; the general
    /// `setupInlineEntry` stays the authority for everything else (strict, arrow,
    /// method receiver, eval, arity pad, non-cell captures).
    fn isSimpleInlineFrame(target: *const InlineTarget, source: ArgsSource) bool {
        const function = target.viewPtr();
        // fb-derived half (normal, non-arrow, sloppy, simple params, no
        // eval-call, no global-var rebinds) is precomputed at view build:
        // one byte test instead of ~6 scattered FunctionBytecode bool loads
        // (the `ldrb [fb,#…]` cluster that dominated op_call). The remaining
        // checks below depend on the call site, not the bytecode.
        if (!function.simple_inline_eligible) return false;
        if (target.function_object.functionEvalLocalNames().len != 0) return false;
        if (target.function_object.functionEvalLocalRefs().len != 0) return false;
        switch (source) {
            .stack_region => |region| if (region.has_receiver) return false,
            .moved => return false, // tail-call reuse keeps the general path
        }
        if (!target.this_value.isUndefined()) return false;
        if (!canBorrowSourceArgs(function, source)) return false;
        const captures = target.function_object.functionCapturesSlot().*;
        if (captures.len > 0 and !allCapturesAreCellsCached(target.function_object, captures)) return false;
        return true;
    }

    /// Straight-line frame setup for the `isSimpleInlineFrame` shape — the hot
    /// fib/closure-call path. It calls the SAME shared primitives as
    /// `setupInlineEntry` (FrameSlab.carve, Frame.init, initFrameLocals,
    /// initArgumentsBorrowedSlots) but with every simple-case branch resolved at
    /// compile time: no eval merge/snapshot, `this = global` (borrowed), no
    /// original-args snapshot, borrowed args, borrowed all-cell var_refs. Lives in
    /// its OWN function so its register allocation is not coupled to the 220-line
    /// general path (whose register pressure spilled the hot fields). Ownership
    /// flags MUST mirror the general path exactly: current_function .take, this
    /// .borrow, new_target borrowed, args borrowed (cleanup_source .non_args),
    /// var_refs borrowed.
    ///
    /// `noinline` is LOAD-BEARING: the whole point is to keep this register
    /// allocation OFF the general `setupInlineEntry`/`pushFrame` chain. If LLVM
    /// inlines it back into `pushFrame`, the simple path's spills re-couple with
    /// the general path and the win evaporates (measured: 3.09x→3.26x qjs on fib).
    noinline fn setupSimpleInlineEntry(ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource) HostError!void {
        const rt = ctx.runtime;
        // Point straight at the pointer-stable per-FB cached view (no copy); the
        // simple frame is provably eval-free, so the shared view is never
        // mutated. Only the rare uncached FB copies into the entry's storage.
        if (target.cached_view) |cached| {
            entry.function = cached;
        } else {
            entry.view_storage = target.view;
            entry.function = &entry.view_storage;
        }
        entry.catch_target = null;
        entry.eval_function_view = null;
        entry.merged_var_ref_names = &.{};
        entry.merged_var_refs = &.{};
        entry.simple_frame = true;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        errdefer entry.profile_guard.deinit();

        const callable_slot = sourceCallableSlot(source);

        entry.arena_mark = rt.vm_stack.mark();
        errdefer rt.vm_stack.restore(entry.arena_mark);

        entry.frame = frame_mod.Frame.init(entry.function);
        errdefer entry.frame.deinit(&rt.memory, rt);

        var cleanup_source: SourceCleanupMode = .full;
        errdefer cleanupSource(rt, source, cleanup_source);

        // Sloppy plain-call receiver coerces to the global object (borrowed). qjs
        // inline prologue: `this_obj = global_obj` (quickjs.c:17933, sloppy leg).
        entry.frame.current_function = takeSourceSlot(callable_slot);
        entry.frame.new_target = target.new_target;
        entry.frame.this_value = global.value();
        entry.frame.this_value_owned = false;

        entry.eval_snapshot = .{};
        const argc = sourceArgCount(source);
        const frame_arg_count = frame_mod.frameArgCount(entry.function, argc);
        const open_var_ref_count = frame_mod.frameOpenVarRefStorageCount(entry.function, frame_arg_count);
        const stack_count = @as(usize, entry.function.stack_size) + 1;
        const slab = frame_mod.FrameSlab.carve(&rt.memory, &rt.vm_stack, 0, 0, entry.function.var_count, stack_count, 0, open_var_ref_count) orelse blk: {
            const heap_windows = try frame_mod.FrameSlab.allocHeap(&rt.memory, 0, 0, entry.function.var_count, stack_count, 0, open_var_ref_count);
            entry.frame.installOwnedStorage(heap_windows.storage);
            break :blk heap_windows;
        };
        const frame_windows = frame_mod.FrameStorageWindows{
            .args = if (slab.args.len != 0) slab.args else null,
            .original_args = null,
            .locals = if (slab.locals.len != 0) slab.locals else null,
            .var_refs = null,
            .open_var_refs = if (slab.open_var_refs.len != 0) slab.open_var_refs else null,
        };
        entry.stack = stack_mod.Stack.initArenaWindow(&rt.memory, rt.stack_size, slab.stack);
        errdefer entry.stack.deinit(rt);

        try vm_call.initFrameLocals(ctx, entry.function, &entry.frame, &.{}, &.{}, true, frame_windows);
        try entry.frame.initArgumentsBorrowedSlots(&rt.memory, sourceArgs(source), true, false, frame_windows);
        cleanup_source = .non_args;
        cleanupSource(rt, source, cleanup_source);
        cleanup_source = .none;

        if (frame_windows.open_var_refs) |open_refs| {
            entry.frame.installOpenVarRefSlots(open_refs);
        } else if (open_var_ref_count != 0) {
            try entry.frame.ensureOpenVarRefSlots(&rt.memory, &rt.vm_stack, true);
        }
        const captures = target.function_object.functionCapturesSlot().*;
        if (captures.len > 0) {
            entry.frame.var_refs = captures;
            entry.frame.var_refs_borrowed = true;
        }
    }

    /// Optimized inline-call frame setup, factored out of `pushFrame` so the
    /// Machine shares the zero-copy arg move (`initArgumentsMoved`), eval-binding
    /// merge, this-boxing and arena carve — NOT the dup-heavy
    /// `callFunctionBytecodeModeState` path.
    /// The caller owns depth accounting (enterInlineCallDepth / enterCallDepth)
    /// and any push/pop bookkeeping; on error every partially-initialized
    /// resource is released via the errdefers below.
    pub fn setupInlineEntry(ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource) HostError!void {
        const rt = ctx.runtime;
        // Point at the pointer-stable per-FB cached view (no copy) when present;
        // the eval-overlay branch below still builds its own mutable copy, so the
        // shared cache is never mutated. Only the rare uncached FB copies here.
        if (target.cached_view) |cached| {
            entry.function = cached;
        } else {
            entry.view_storage = target.view;
            entry.function = &entry.view_storage;
        }
        entry.catch_target = null;
        entry.eval_function_view = null;
        entry.merged_var_ref_names = &.{};
        entry.merged_var_refs = &.{};
        entry.simple_frame = true;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        errdefer entry.profile_guard.deinit();
        errdefer freeEvalResources(rt, entry);

        const callable_slot = sourceCallableSlot(source);
        const callable = callable_slot.*;

        // Direct-eval bindings extend the callee's var-ref view, mirroring
        // the combined slices `callFunctionBytecodeModeState` builds on the
        // recursive path. Contents are borrowed; storage is entry-owned.
        const eval_names = target.function_object.functionEvalLocalNames();
        const eval_refs = target.function_object.functionEvalLocalRefs();
        var frame_var_refs: []const core.JSValue = target.function_object.functionCapturesSlot().*;
        if (eval_names.len > 0 and eval_refs.len > 0) {
            const eval_view = try rt.memory.create(bytecode.Bytecode);
            eval_view.* = target.viewPtr().*;
            entry.eval_function_view = eval_view;
            entry.function = eval_view;
            try mergeEvalBindings(rt, entry, frame_var_refs, eval_names, eval_refs);
            frame_var_refs = entry.merged_var_refs;
        }

        entry.arena_mark = rt.vm_stack.mark();
        errdefer rt.vm_stack.restore(entry.arena_mark);

        entry.frame = frame_mod.Frame.init(entry.function);
        errdefer entry.frame.deinit(&rt.memory, rt);
        // No per-call backtrace node: the invocation's single MachineBacktrace
        // (zjs_vm.runWithArgsState) walks this Entry directly via the chain.

        // Mirror qjs's inline prologue for the common plain-call receiver:
        // strict keeps undefined, sloppy uses the global object. Arrow,
        // method, and primitive receivers stay on the shared coercion path.
        var boxed_this: ?core.JSValue = null;
        defer if (boxed_this) |value| value.free(rt);
        const fb_strict = target.fb.flags.is_strict_mode or target.fb.flags.runtime_strict_mode;
        const receiver_slot = sourceReceiverSlot(source);
        const plain_undefined_this = !target.fb.flags.is_arrow_function and receiver_slot == null and target.this_value.isUndefined();
        const effective_this = if (plain_undefined_this)
            if (fb_strict) core.JSValue.undefinedValue() else global.value()
        else
            try call_runtime.coerceCallThis(ctx, global, fb_strict, target.this_value, &boxed_this);

        var take_receiver_as_this = false;
        if (boxed_this == null and !target.fb.flags.is_arrow_function) {
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
        //   current_function .take -> owns the callable's transferred ref
        //   new_target .borrow -> not owned
        //   constructor_this keeps Frame.init's undefined/unowned default
        //   this .borrow, unless boxed (sloppy primitive `this`) or taken from
        //   the receiver slot (method call) -> then .take/owned.
        // `takeSourceSlot` nulls the source slot so the popped stack region
        // never double-frees the value (the leak guard the method-call comment
        // below describes).
        entry.frame.current_function = takeSourceSlot(callable_slot);
        entry.frame.new_target = target.new_target;
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
        const argc = sourceArgCount(source);
        const frame_arg_count = frame_mod.frameArgCount(entry.function, argc);
        const need_original_snapshot = frame_mod.argumentsNeedsOriginalSnapshot(entry.function);
        const borrow_source_args = canBorrowSourceArgs(entry.function, source);
        const storage_arg_count: usize = if (borrow_source_args) 0 else frame_arg_count;
        const need_eval_var_refs = eval_names.len != 0 or eval_refs.len != 0;
        // `eval_function_view` is only built when BOTH eval_names and eval_refs
        // are non-empty, so `!need_eval_var_refs` (the OR) already implies the
        // view is null and no merged slices exist — exactly the precondition
        // under which `eval_snapshot.deinit` / `freeEvalResources` are no-ops.
        entry.simple_frame = !need_eval_var_refs;
        // qjs `var_refs = p->u.func.var_refs` (quickjs.c:17844): borrow the callee's
        // closure captures array directly instead of carving + dup-ing a per-frame
        // copy. Only when every mutation of `frame.var_refs` is provably routed
        // through a cell (never the array element) and the shared array is never
        // realloced. The conjuncts gate exactly those escapes:
        //   simple_frame        — branch-1 captures (no merged eval var-ref view)
        //   !has_eval_call      — no `replaceFrameVarRefBinding` direct element write,
        //                         no eval-introduced refs growing the array
        //   global_vars.len==0  — no `defineGlobalDecl{Var,Lexical}Cell` rebind
        //   all captures cells  — `setSlotValue` always writes into the cell, never
        //                         `frame.var_refs[idx] = v` (no non-cell element)
        // Captures.len == closure_var.len ≥ every bytecode var_ref idx, so
        // `ensureVarRefsCapacity` never fires either. Teardown skips the per-element
        // free (the still-live function object owns the cells).
        const borrow_var_refs = entry.simple_frame and
            !entry.function.flags.has_eval_call and
            entry.function.global_vars.len == 0 and
            frame_var_refs.len > 0 and
            allVarRefCells(frame_var_refs);
        const var_ref_storage_count: usize = if (borrow_var_refs) 0 else frame_mod.frameVarRefStorageCount(entry.function, frame_var_refs);
        const open_var_ref_count = frame_mod.frameOpenVarRefStorageCount(entry.function, frame_arg_count);
        const slab = frame_mod.FrameSlab.carve(
            &rt.memory,
            &rt.vm_stack,
            storage_arg_count,
            frame_mod.originalArgCount(argc, need_original_snapshot),
            entry.function.var_count,
            @as(usize, entry.function.stack_size) + 1,
            var_ref_storage_count,
            open_var_ref_count,
        ) orelse blk: {
            const heap_windows = try frame_mod.FrameSlab.allocHeap(
                &rt.memory,
                storage_arg_count,
                frame_mod.originalArgCount(argc, need_original_snapshot),
                entry.function.var_count,
                @as(usize, entry.function.stack_size) + 1,
                var_ref_storage_count,
                open_var_ref_count,
            );
            entry.frame.installOwnedStorage(heap_windows.storage);
            break :blk heap_windows;
        };
        const frame_windows = frame_mod.FrameStorageWindows{
            .args = if (slab.args.len != 0) slab.args else null,
            .original_args = if (slab.original_args.len != 0) slab.original_args else null,
            .locals = if (slab.locals.len != 0) slab.locals else null,
            .var_refs = if (slab.var_refs.len != 0) slab.var_refs else null,
            .open_var_refs = if (slab.open_var_refs.len != 0) slab.open_var_refs else null,
        };
        entry.stack = stack_mod.Stack.initArenaWindow(&rt.memory, rt.stack_size, slab.stack);
        errdefer entry.stack.deinit(rt);

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

        try vm_call.initFrameLocals(ctx, entry.function, &entry.frame, &.{}, &.{}, true, frame_windows);
        if (borrow_source_args) {
            try entry.frame.initArgumentsBorrowedSlots(
                &rt.memory,
                sourceArgs(source),
                true,
                need_original_snapshot,
                frame_windows,
            );
            cleanup_source = .non_args;
        } else {
            try entry.frame.initArgumentsMoved(
                &rt.memory,
                &rt.vm_stack,
                sourceArgs(source),
                true,
                need_original_snapshot,
                frame_windows,
            );
        }
        cleanupSource(rt, source, cleanup_source);
        cleanup_source = .none;

        if (frame_windows.open_var_refs) |open_refs| {
            entry.frame.installOpenVarRefSlots(open_refs);
        } else if (open_var_ref_count != 0) {
            try entry.frame.ensureOpenVarRefSlots(&rt.memory, &rt.vm_stack, true);
        }
        if (borrow_var_refs) {
            // Alias the closure's captures (mutable slice; `simple_frame` guarantees
            // no merge replaced it). The function object stays alive via
            // `frame.current_function`, so the cells outlive the frame.
            entry.frame.var_refs = target.function_object.functionCapturesSlot().*;
            entry.frame.var_refs_borrowed = true;
        } else if (frame_var_refs.len != 0 or entry.function.var_ref_names.len != 0) {
            try vm_call.initFrameVarRefs(ctx, global, entry.function, &entry.frame, frame_var_refs, true, frame_windows);
        }
    }

    fn sourceCallableSlot(source: ArgsSource) *core.JSValue {
        return switch (source) {
            .stack_region => |region| &region.stack.values[region.region_base + @as(usize, @intFromBool(region.has_receiver))],
            .moved => |moved| &moved.values[if (moved.has_receiver) 1 else 0],
        };
    }

    fn sourceReceiverSlot(source: ArgsSource) ?*core.JSValue {
        return switch (source) {
            .stack_region => |region| if (region.has_receiver) &region.stack.values[region.region_base] else null,
            .moved => |moved| if (moved.has_receiver) &moved.values[0] else null,
        };
    }

    fn takeSourceSlot(slot: *core.JSValue) core.JSValue {
        const value = slot.*;
        slot.* = core.JSValue.undefinedValue();
        return value;
    }

    fn sourceHasStackRegion(source: ArgsSource) bool {
        return switch (source) {
            .stack_region => true,
            .moved => false,
        };
    }

    fn sourceArgCount(source: ArgsSource) usize {
        return switch (source) {
            .stack_region => |region| region.argc,
            .moved => |moved| moved.values.len - if (moved.has_receiver) @as(usize, 2) else @as(usize, 1),
        };
    }

    fn sourceArgs(source: ArgsSource) []core.JSValue {
        return switch (source) {
            .stack_region => |region| blk: {
                const args_start = region.region_base + 1 + @as(usize, @intFromBool(region.has_receiver));
                break :blk region.stack.values[args_start..][0..region.argc];
            },
            .moved => |moved| moved.values[if (moved.has_receiver) 2 else 1..],
        };
    }

    /// Every capture is a VarRef cell — the precondition for borrowing the
    /// closure captures array as `frame.var_refs`: with all-cells, every
    /// `setSlotValue(&frame.var_refs[idx], ...)` writes through the cell and
    /// never overwrites the array element, so the shared array is never mutated.
    /// Cheaper than the dup loop it replaces (a tag test vs tag test + retain).
    fn allVarRefCells(captures: []const core.JSValue) bool {
        for (captures) |cap| {
            if (core.VarRef.fromValue(cap) == null) return false;
        }
        return true;
    }

    /// `allVarRefCells` memoized on the function object — captures are fixed at
    /// closure creation, so the cold header-load loop runs once per closure.
    fn allCapturesAreCellsCached(function_object: *core.Object, captures: []const core.JSValue) bool {
        return switch (function_object.functionCapturesCellState()) {
            1 => true,
            2 => false,
            else => blk: {
                const all = allVarRefCells(captures);
                function_object.setFunctionCapturesCellState(if (all) 1 else 2);
                break :blk all;
            },
        };
    }

    fn canBorrowSourceArgs(function: *const bytecode.Bytecode, source: ArgsSource) bool {
        const argc = sourceArgCount(source);
        if (argc == 0) return false;
        if (@max(argc, @as(usize, @intCast(function.arg_count))) != argc) return false;
        return switch (source) {
            .stack_region => true,
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
            .moved => {},
        }
    }

    inline fn freeSourceSlot(rt: *core.JSRuntime, slot: *core.JSValue) void {
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
        const old_len = entry.function.varRefNamesLen();
        const names = try rt.memory.alloc(core.Atom, old_len + add_len);
        errdefer rt.memory.free(core.Atom, names);
        var i: usize = 0;
        while (i < old_len) : (i += 1) names[i] = entry.function.varRefName(i);
        @memcpy(names[old_len..], eval_names[0..add_len]);
        const refs = try rt.memory.alloc(core.JSValue, captures.len + add_len);
        @memcpy(refs[0..captures.len], captures);
        @memcpy(refs[captures.len..], eval_refs[0..add_len]);
        entry.merged_var_ref_names = names;
        entry.merged_var_refs = refs;
        entry.eval_function_view.?.var_ref_names = names;
    }

    fn freeMergedSlices(rt: *core.JSRuntime, entry: *Entry) void {
        if (entry.merged_var_ref_names.len != 0) rt.memory.free(core.Atom, entry.merged_var_ref_names);
        if (entry.merged_var_refs.len != 0) rt.memory.free(core.JSValue, entry.merged_var_refs);
        entry.merged_var_ref_names = &.{};
        entry.merged_var_refs = &.{};
    }

    fn freeEvalFunctionView(rt: *core.JSRuntime, entry: *Entry) void {
        if (entry.eval_function_view) |view| {
            rt.memory.destroy(bytecode.Bytecode, view);
            entry.eval_function_view = null;
        }
    }

    fn freeEvalResources(rt: *core.JSRuntime, entry: *Entry) void {
        freeMergedSlices(rt, entry);
        freeEvalFunctionView(rt, entry);
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
    /// path (eval snapshot, frame, operand stack, arena watermark,
    /// backtrace, profile scope, call depth).
    inline fn popTeardown(self: *Machine) void {
        teardownInlineEntry(self.ctx, self.topEntry());
        self.ctx.call_depth -= 1;
        self.depth -= 1;
        self.switched = true;
    }

    /// Release every resource `setupInlineEntry` acquired for `entry` (eval
    /// snapshot, frame, operand stack, merged slices, arena watermark,
    /// backtrace, profile scope). The caller owns depth accounting + push/pop
    /// bookkeeping. Shared by the Machine (popTeardown) and the recursion path.
    pub fn teardownInlineEntry(ctx: *core.JSContext, entry: *Entry) void {
        const rt = ctx.runtime;
        // For a simple frame (no direct-eval bindings) the snapshot and eval
        // resources are the empty defaults — skip both non-inlined calls.
        if (!entry.simple_frame) entry.eval_snapshot.deinit(rt);
        entry.stack.deinit(rt);
        entry.frame.deinitInlineCall(&rt.memory, rt);
        if (!entry.simple_frame) freeEvalResources(rt, entry);
        rt.vm_stack.restore(entry.arena_mark);
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
