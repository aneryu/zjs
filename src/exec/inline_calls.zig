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
//! constructor, no arrow, same realm, no pending special
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
    /// Pointer to the bytecode function payload's stable captures slice. QJS
    /// carries `p->u.func.var_refs` from target resolution into frame setup;
    /// retaining this field instead of the enclosing object avoids redispatching
    /// its payload kind on every call without increasing InlineTarget's size.
    captures: *const []*core.VarRef,
    /// The callable closure value (becomes `frame.current_function`).
    callable: core.JSValue,
    fb: *const bytecode.FunctionBytecode,
    /// The pointer-stable per-FB cached execution view (`cachedBytecodeView`,
    /// built once per FB), or null for an FB with no cache slot
    /// (fixture/synthetic, no debug box) — `setupInlineEntry` then rebuilds a
    /// per-call view into an Entry-owned heap box. qjs's OP_call hands
    /// `JS_CallInternal` only the 16B `func_obj` and the callee prologue
    /// dereferences `p->u.func.function_bytecode` (quickjs.c:17800) — zero
    /// struct freight. Keeping only pointers here keeps the target (and the
    /// `InlineCallRequest` riding through the dispatch driver) at qjs's
    /// scalars-only scale instead of dragging a by-value `Bytecode` through
    /// every call.
    view: ?*const bytecode.Bytecode,
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
/// special-cases (class constructors, cross-realm calls, async/generator kinds)
/// disqualifies the target so the slow
/// path keeps handling it. Direct eval captures use the ordinary indexed
/// var-ref cells and need no function-object binding overlay.
///
/// Arrow targets ARE eligible: an arrow has no own `this` / `new.target`, so
/// the resolved `this_value` / `new_target` come from the lexical values
/// captured on the function object (mirroring the slow path's arrow leg) and
/// `pushFrame` boxes `this_value` through the same `coerceCallThis` primitive
/// as the recursive path — the boxing rules stay in one place.
pub inline fn resolveInlineTarget(ctx: *core.JSContext, global: *core.Object, receiver: core.JSValue, func: core.JSValue) ?InlineTarget {
    const function_object = object_ops.functionObjectFromValue(func) orelse return null;
    const function_payload = function_object.bytecodeFunctionPayloadPtr();
    const fb = function_payload.functionBytecodePtr();
    if (fb.flags.func_kind != .normal) return null;
    if (fb.flags.is_class_constructor or fb.flags.is_derived_class_constructor) return null;
    // Realm gate. qjs's callee prologue reads the realm as ONE unconditional
    // load off the hot function struct (`ctx = b->realm`, quickjs.c:17871);
    // zjs's single-global inline machinery COMPARES instead of adopting, but
    // the read must keep qjs's shape: the payload-resident pointer, inline
    // (`bytecodeFunctionRealmGlobalPtr` — class_id is proven, so
    // `objectRealmGlobal`'s bound-function recursion is dead and the old
    // out-of-line `bl` + caller-saved shuffle around it are gone). A null
    // pointer falls back to the rare JSValue-slot resolution out of line,
    // which re-runs the same null ptr check and then the rare-payload leg —
    // bit-identical to the old `objectRealmGlobal(function_object)` result.
    const function_global = function_payload.realm_global_ptr orelse
        (object_ops.objectRealmGlobal(function_object) orelse global);
    if (function_global != global) return null;
    // Arrow bindings are resolved OUT OF LINE: qjs's callee prologue has no
    // arrow branch at all (an arrow's this/new.target are ordinary closure
    // vars bound at closure creation, js_closure2 quickjs.c:17297); zjs's
    // frame model keeps them on the function object, so the lookup exists —
    // but keeping it inline made LLVM hoist the `class_payload_kind` load +
    // spill above the arrow test onto every plain call, and merge
    // this/new_target through stack temp slots. The non-arrow hot path now
    // carries plain register values.
    var this_value = receiver;
    var new_target = core.JSValue.undefinedValue();
    if (fb.flags.is_arrow_function) {
        const bindings = resolveArrowBindings(function_object);
        this_value = bindings.this_value;
        new_target = bindings.new_target;
    }
    const rt = ctx.runtime;
    // Point at the per-FB cached execution view (built once, pointer-stable).
    // An FB with no cache slot (fixture/synthetic, no debug box) stays
    // inline-eligible with `view = null`: `setupInlineEntry` rebuilds a fresh
    // per-call view into an Entry-owned heap box, preserving the old
    // rebuild-per-call semantics without a by-value `Bytecode` riding through
    // the call machinery.
    return .{
        .captures = &function_payload.captures,
        .callable = func,
        .fb = fb,
        .view = bytecode.cachedBytecodeView(fb, &rt.memory, &rt.atoms),
        .this_value = this_value,
        .new_target = new_target,
    };
}

const ArrowBindings = struct {
    this_value: core.JSValue,
    new_target: core.JSValue,
};

/// Cold arrow leg of `resolveInlineTarget`: the lexical `this` / `new.target`
/// captured on an arrow's function object (both borrowed; see the
/// `InlineTarget` field docs). `noinline` is load-bearing — inline, the rare
/// payload lookups leaked a `class_payload_kind` load + spill onto the
/// non-arrow hot path (see the call-site comment).
noinline fn resolveArrowBindings(function_object: *core.Object) ArrowBindings {
    return .{
        .this_value = function_object.functionLexicalThis() orelse core.JSValue.undefinedValue(),
        .new_target = function_object.functionArrowNewTarget() orelse core.JSValue.undefinedValue(),
    };
}

/// One suspended-or-active inline call level. Entries live in chunked,
/// pointer-stable storage; `frame`, `stack`, and `view` are referenced by
/// the dispatch loop and backtrace pc borrows while the
/// level is alive.
pub const Entry = struct {
    /// The live execution view: the pointer-stable per-FB cache (common), or
    /// `owned_view` for a cache-less FB. qjs dispatches straight from
    /// `JSFunctionBytecode*`; this is the analogous single pointer.
    function: *const bytecode.Bytecode,
    /// Heap box for the per-call view rebuilt when the FB has no cache slot
    /// (fixture/synthetic, no debug box). Null on the common cached path;
    /// freed at teardown.
    owned_view: ?*bytecode.Bytecode,
    frame: frame_mod.Frame,
    stack: stack_mod.Stack,
    catch_target: ?usize,
    arena_mark: core.VmStackArena.Mark,
    profile_guard: vm_call.CallProfileGuard,
    /// True ONLY for a `setupSimpleInlineEntry` frame (borrowed this/args/
    /// var_refs, no owned view): the STATIC half of the `teardownSimpleEntry`
    /// eligibility. General-path frames still need the full teardown.
    fast_teardown: bool,
    /// Native Function.call record skipped by transparent forwarding. Owned by
    /// this entry so a stack captured inside the bytecode target still sees the
    /// qjs frame order `target -> call (native) -> caller`.
    native_caller: core.JSValue,
    /// Caller's Entry, or null when the caller is the L0 frame — qjs
    /// `JSStackFrame.prev_frame` (quickjs.c:408, "NULL if first stack
    /// frame"). Together with `Machine.top` (≅ rt->current_stack_frame)
    /// this is the frame-navigation mechanism: qjs never derives a frame
    /// address from an index, it follows this pointer pair (set at
    /// quickjs.c:17869-17870, restored at the done: epilogue 20709).
    prev: ?*Entry,
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
        var remaining = index;
        var cursor = machine.top;
        while (cursor) |entry| {
            if (remaining == 0) return exception_ops.frameBacktraceSnapshot(&entry.frame);
            remaining -= 1;
            if (!entry.native_caller.isUndefined()) {
                if (remaining == 0) return nativeBacktraceSnapshot(entry.native_caller);
                remaining -= 1;
            }
            cursor = entry.prev;
        }
        if (remaining == 0) return exception_ops.frameBacktraceSnapshot(holder.l0_frame);
        return null;
    }
    if (index == 0) return exception_ops.frameBacktraceSnapshot(holder.l0_frame);
    return null;
}

fn nativeBacktraceSnapshot(function_value: core.JSValue) core.ActiveBacktraceSnapshot {
    return .{
        .function_name = core.atom.null_atom,
        .filename = core.atom.null_atom,
        .line_num = 0,
        .col_num = 0,
        .function_value = function_value,
        .is_native = true,
    };
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
    /// Current (innermost) live Entry, or null at depth 0 — qjs
    /// `rt->current_stack_frame` (quickjs.c:358). All frame ADDRESSES come
    /// from this pointer and the `Entry.prev` chain; `depth` stays purely
    /// for accounting (L0 boundary tests, backtrace length, slot reuse).
    /// Maintained in lockstep with `depth` by pushFrame/popTeardown (and
    /// the dispatch loop's fused popAndResume).
    top: ?*Entry = null,
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

    /// The current Entry — the cached `top` pointer (qjs reads
    /// `rt->current_stack_frame` directly, quickjs.c:2864), NOT re-derived
    /// from the depth index: `entryAt`'s chunk math costs a umaddl chain on
    /// every use, and qjs never computes a frame address from an index.
    pub fn topEntry(self: *Machine) *Entry {
        std.debug.assert(self.depth > 0);
        return self.top.?;
    }

    pub fn entryAt(self: *Machine, index: usize) *Entry {
        return &self.chunks[index / entries_per_chunk][index % entries_per_chunk];
    }

    fn acquireSlot(self: *Machine, global: *core.Object) HostError!*Entry {
        const index = self.depth;
        const chunk_index = index / entries_per_chunk;
        if (chunk_index < self.chunk_count) return self.entryAt(index);
        return self.acquireSlotSlow(global, index, chunk_index);
    }

    /// Allocate the first slot in a new chunk, or report logical stack
    /// exhaustion.  Once a depth has been visited, `acquireSlot` stays entirely
    /// on its pointer-arithmetic fast arm; keeping allocation/error construction
    /// here prevents their register pressure from entering every call frame.
    noinline fn acquireSlotSlow(self: *Machine, global: *core.Object, index: usize, chunk_index: usize) HostError!*Entry {
        if (chunk_index >= max_chunks) {
            // QuickJS throws InternalError "stack overflow" for call-depth
            // exhaustion (JS_ThrowStackOverflow at the JS_CallInternal guard,
            // quickjs.c:17837/7789), not a RangeError.
            _ = exception_ops.throwInternalErrorMessage(self.ctx, global, "stack overflow") catch |err| return err;
            return error.StackOverflow;
        }
        std.debug.assert(chunk_index == self.chunk_count);
        if (self.chunks.len == 0) {
            self.chunks = try self.ctx.runtime.memory.alloc(*[entries_per_chunk]Entry, max_chunks);
        }
        const chunk = try self.ctx.runtime.memory.create([entries_per_chunk]Entry);
        self.chunks[chunk_index] = chunk;
        self.chunk_count += 1;
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
    /// `target` rides by pointer end-to-end (qjs OP_call passes only the 16B
    /// func_obj; nothing struct-sized is copied per call).
    /// Returns the new top entry so the caller can enter it directly — qjs's
    /// callee frame address is the `alloca` result already in a register
    /// (quickjs.c:17846); re-deriving it from the depth index (`topEntry()`)
    /// would redo the chunk multiply for nothing.
    fn pushFrame(self: *Machine, global: *core.Object, target: *const InlineTarget, source: ArgsSource) HostError!*Entry {
        try vm_call.enterInlineCallDepth(self.ctx, global);
        errdefer self.ctx.call_depth -= 1;
        const entry = try self.acquireSlot(global);
        entry.native_caller = core.JSValue.undefinedValue();
        if (isSimpleInlineFrame(target, source))
            try setupSimpleInlineEntry(false, false, self.ctx, global, entry, target, source)
        else if (isStrictSimpleInlineFrame(false, target, source))
            try setupSimpleInlineEntry(true, false, self.ctx, global, entry, target, source)
        else
            try setupFallbackInlineEntry(self.ctx, global, entry, target, source);
        // Link the new frame into the chain — qjs `sf->prev_frame =
        // rt->current_stack_frame; rt->current_stack_frame = sf;`
        // (quickjs.c:17869-17870).
        entry.prev = self.top;
        self.top = entry;
        self.depth += 1;
        return entry;
    }

    /// True when the frame takes the straight-line `setupSimpleInlineEntry` path:
    /// a sloppy, non-arrow plain call (no receiver, undefined `this` → global)
    /// with simple parameters (no original-args snapshot), no global-var rebinds,
    /// args that can be borrowed in place, and
    /// all-cell closure captures (borrowable as `var_refs`). Each rejected
    /// condition is exactly a branch the lean path elides; the general
    /// `setupInlineEntry` stays the authority for everything else (strict, arrow,
    /// method receiver, arity pad, non-cell captures).
    fn isSimpleInlineFrame(target: *const InlineTarget, source: ArgsSource) bool {
        // A cache-less FB (view == null) needs the general path's per-call
        // view rebuild.
        const function = target.view orelse return false;
        // fb-derived half (normal, non-arrow, sloppy, simple params, no
        // global-var rebinds) is precomputed at view build:
        // one byte test instead of ~6 scattered FunctionBytecode bool loads
        // (the `ldrb [fb,#…]` cluster that dominated op_call). The remaining
        // checks below depend on the call site, not the bytecode.
        if (!function.simple_inline_eligible) return false;
        switch (source) {
            .stack_region => |region| if (region.has_receiver) return false,
            .moved => return false, // tail-call reuse keeps the general path
        }
        if (!target.this_value.isUndefined()) return false;
        if (!canBorrowSourceArgs(function, source)) return false;
        // No captures check: `[]*core.VarRef` makes "every capture is a cell"
        // a type invariant (qjs js_closure2 slots are always JSVarRef*,
        // quickjs.c:17297-17331) — the allCapturesAreCellsCached memo and its
        // per-closure header-load loop are deleted by the phase-D flip.
        return true;
    }

    /// Strict-mode twin of `isSimpleInlineFrame`. qjs uses the same
    /// JS_CallInternal frame layout for strict and sloppy functions; the only
    /// plain-call difference is that strict preserves undefined `this` while
    /// sloppy substitutes the realm global. A separate precomputed flag and
    /// setup instantiation keep that choice off the established sloppy path.
    fn isStrictSimpleInlineFrame(comptime snapshot_args: bool, target: *const InlineTarget, source: ArgsSource) bool {
        const function = target.view orelse return false;
        const eligible = if (snapshot_args)
            function.strict_simple_snapshot_inline_eligible
        else
            function.strict_simple_inline_eligible;
        if (!eligible) return false;
        switch (source) {
            .stack_region => |region| if (region.has_receiver) return false,
            .moved => return false,
        }
        if (!target.this_value.isUndefined()) return false;
        if (!canBorrowSourceArgs(function, source)) return false;
        return true;
    }

    /// Keep the arguments-snapshot specialization out of `pushFrame`: it is
    /// cold relative to the established sloppy and strict/no-arguments paths,
    /// and inlining its eligibility block grew the common dispatcher by 84B.
    /// Both callees are noinline and this function only returns their result,
    /// allowing ReleaseFast to use a tail branch rather than another frame.
    noinline fn setupFallbackInlineEntry(ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource) HostError!void {
        if (isStrictSimpleInlineFrame(true, target, source)) {
            return setupSimpleInlineEntry(true, true, ctx, global, entry, target, source);
        }
        return setupInlineEntry(ctx, global, entry, target, source);
    }

    /// Straight-line frame setup for the sloppy/strict simple-inline shapes —
    /// the hot fib/closure-call path and its strict twin, a line-for-line mirror
    /// of qjs `JS_CallInternal`'s
    /// prologue (quickjs.c:17828-17871): compute the storage need, carve ONE
    /// contiguous slab, partition it by pointer arithmetic, bind every frame
    /// field exactly once. No shared-primitive calls, no `Frame.init`
    /// default-then-overwrite pass, no by-value `FrameSlab` /
    /// `FrameStorageWindows` round-trips. Every simple-case branch is resolved
    /// at compile time: `this = global` for sloppy or undefined for strict
    /// (both borrowed), original-args snapshot absent or arena-backed, borrowed
    /// args, borrowed all-cell var_refs. Lives
    /// in its OWN function so its register allocation is not coupled to the
    /// general path (whose register pressure spilled the hot fields). Ownership
    /// flags MUST mirror the general path exactly: current_function .take, this
    /// .borrow, new_target borrowed, args borrowed, var_refs borrowed.
    ///
    /// `noinline` is LOAD-BEARING: the whole point is to keep this register
    /// allocation OFF the general `setupInlineEntry`/`pushFrame` chain. If LLVM
    /// inlines it back into `pushFrame`, the simple path's spills re-couple with
    /// the general path and the win evaporates (measured: 3.09x→3.26x qjs on fib).
    noinline fn setupSimpleInlineEntry(comptime strict_this: bool, comptime snapshot_args: bool, ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource) HostError!void {
        const rt = ctx.runtime;
        const function = target.view.?; // isSimpleInlineFrame requires a cached view
        entry.function = function;
        entry.owned_view = null;
        entry.catch_target = null;
        entry.fast_teardown = true;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        errdefer entry.profile_guard.deinit();

        // isSimpleInlineFrame admits only a receiver-less .stack_region source,
        // so the region layout is statically `[callable, args...]`.
        const region = switch (source) {
            .stack_region => |r| r,
            .moved => unreachable,
        };
        const callable_slot = &region.stack.values[region.region_base];
        const args = region.stack.values[region.region_base + 1 ..][0..region.argc];
        const snapshot_count: usize = if (snapshot_args) args.len else 0;
        // Retreat the caller's operand region NOW, before the slab carve — qjs
        // borrows the caller slots equally early (`arg_buf = argv`, 17841) and
        // the caller sp is dead from here on. Doing it at the tail put the
        // store at the end of the whole setup dependency chain (measured 18%
        // of this function); only the slice len shrinks, so `callable_slot`
        // and `args` still point at live capacity-region memory (the arena
        // watermark is untouched — the new slab below cannot overlap them),
        // and the values keep their refcounts (the cycle collector roots by
        // rc, it never scans operand-stack slices).
        region.stack.values = region.stack.values.ptr[0..region.region_base];
        // On failure below nothing has been bound yet (`takeSourceSlot` runs
        // in the frame literal, after the last failable point): restore the
        // pre-truncation len — the region layout pins it at
        // `region_base + callable(1) + argc` — so popOwnedStackRegion sees
        // and frees the callable + args, matching the general path's `.full`
        // cleanup.
        errdefer {
            region.stack.values = region.stack.values.ptr[0 .. region.region_base + 1 + region.argc];
            cleanupStackSource(rt, source);
        }

        // alloca_size (quickjs.c:17834-17836): locals | operand stack | open
        // var-ref slots. Args are borrowed in place (`arg_buf = argv`, 17841)
        // and var_refs are borrowed from the closure (17844), so neither
        // occupies slab space. The borrow precondition (canBorrowSourceArgs)
        // pins frame_arg_count == argc.
        const var_count: usize = function.var_count;
        const stack_count = @as(usize, function.stack_size) + 1;
        const open_var_ref_count = frame_mod.frameOpenVarRefStorageCount(function, args.len);
        const open_slots = if (open_var_ref_count == 0)
            0
        else
            (open_var_ref_count * @sizeOf(?*core.VarRef) + (@sizeOf(core.JSValue) - 1)) / @sizeOf(core.JSValue);
        const total = var_count + stack_count + open_slots + snapshot_count;

        entry.arena_mark = rt.vm_stack.mark();
        errdefer rt.vm_stack.restore(entry.arena_mark);

        // `local_buf = alloca(alloca_size)` (17846); the VM stack arena is
        // zjs's C stack. Heap fallback only when the arena is exhausted.
        var storage_on_heap = false;
        const slab_values = rt.vm_stack.carve(&rt.memory, total) orelse blk: {
            const heap = try rt.memory.alloc(core.JSValue, total);
            storage_on_heap = true;
            break :blk heap;
        };
        errdefer if (storage_on_heap) rt.memory.free(core.JSValue, slab_values);

        // Pointer-arithmetic partition (17855-17866).
        const locals = slab_values[0..var_count];
        const stack_window = slab_values[var_count..][0..stack_count];
        const open_var_refs: []?*core.VarRef = if (open_slots == 0)
            &.{}
        else
            std.mem.bytesAsSlice(?*core.VarRef, std.mem.sliceAsBytes(slab_values[var_count + stack_count ..][0..open_slots]))[0..open_var_ref_count];
        const original_args = slab_values[var_count + stack_count + open_slots ..][0..snapshot_count];

        @memset(locals, core.JSValue.undefinedValue()); // 17859-17860
        if (open_var_refs.len != 0) @memset(open_var_refs, null); // 17866-17867

        // zjs parameter writes update frame.args in place. An unmapped strict
        // arguments object must nevertheless expose the incoming values, so
        // its dedicated specialization snapshots them before the frame starts.
        // Allocate the cold box before takeSourceSlot: this is the final
        // failable point, preserving the source-restoration errdefer above.
        const cold: ?*frame_mod.Frame.FrameCold = if (snapshot_count == 0) null else blk: {
            const box = try rt.memory.create(frame_mod.Frame.FrameCold);
            for (args, 0..) |arg, index| original_args[index] = arg.dup();
            box.* = .{ .original_args = original_args };
            break :blk box;
        };

        const captures = target.captures.*;
        // Bind the frame in ONE shot — qjs sets sf's handful of fields
        // (17838-17845) with no default-init-then-overwrite pass. The setup
        // instantiation makes the plain-call receiver choice at compile time:
        // strict preserves undefined; sloppy uses the borrowed global object
        // (17933, sloppy leg). `pc` keeps its struct default; `cold` is either
        // null or the prebuilt original-args snapshot box.
        entry.frame = .{
            .function = function,
            .this_value = if (strict_this) core.JSValue.undefinedValue() else global.value(),
            .this_value_owned = false,
            .current_function = takeSourceSlot(callable_slot),
            .new_target = target.new_target,
            .actual_arg_count = args.len,
            .locals = locals,
            .args = args,
            .var_refs = captures,
            .var_refs_borrowed = captures.len > 0,
            .open_var_refs = open_var_refs,
            .storage_values = if (storage_on_heap) slab_values else &.{},
            .storage_on_heap = storage_on_heap,
            .cold = cold,
        };
        entry.stack = stack_mod.Stack.initArenaWindow(&rt.memory, rt.stack_size, stack_window);
    }

    /// Optimized inline-call frame setup, factored out of `pushFrame` so the
    /// Machine shares the zero-copy arg move (`initArgumentsMoved`), this-boxing
    /// and arena carve — NOT the dup-heavy
    /// `callFunctionBytecodeModeState` path.
    /// The caller owns depth accounting (enterInlineCallDepth / enterCallDepth)
    /// and any push/pop bookkeeping; on error every partially-initialized
    /// resource is released via the errdefers below.
    pub noinline fn setupInlineEntry(ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource) HostError!void {
        const rt = ctx.runtime;
        // Point at the pointer-stable per-FB cached view (no copy); a
        // cache-less FB (fixture/synthetic, no debug box) gets a fresh
        // per-call view in an Entry-owned heap box — the old
        // rebuild-per-call semantics.
        if (target.view) |cached| {
            entry.function = cached;
            entry.owned_view = null;
        } else {
            const rebuilt = try rt.memory.create(bytecode.Bytecode);
            rebuilt.* = bytecode.makeBytecodeView(target.fb, &rt.memory, &rt.atoms);
            entry.owned_view = rebuilt;
            entry.function = rebuilt;
        }
        errdefer freeOwnedView(rt, entry);
        entry.catch_target = null;
        entry.fast_teardown = false;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        errdefer entry.profile_guard.deinit();

        const callable_slot = sourceCallableSlot(source);
        const frame_var_refs: []const *core.VarRef = target.captures.*;

        entry.arena_mark = rt.vm_stack.mark();
        errdefer rt.vm_stack.restore(entry.arena_mark);

        entry.frame = frame_mod.Frame.init(entry.function);
        errdefer entry.frame.deinit(&rt.memory, rt);
        // No per-call backtrace node: the invocation's single MachineBacktrace
        // (zjs_vm.runWithCallEnv) walks this Entry directly via the chain.

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

        const argc = sourceArgCount(source);
        const frame_arg_count = frame_mod.frameArgCount(entry.function, argc);
        const need_original_snapshot = frame_mod.argumentsNeedsOriginalSnapshot(entry.function);
        const borrow_source_args = canBorrowSourceArgs(entry.function, source);
        const storage_arg_count: usize = if (borrow_source_args) 0 else frame_arg_count;
        // qjs `var_refs = p->u.func.var_refs` (quickjs.c:17844): borrow the callee's
        // closure captures array directly instead of carving + dup-ing a per-frame
        // copy. Only when every mutation of `frame.var_refs` is provably routed
        // through a cell (never the array element) and the shared array is never
        // realloced. Global declarations are the remaining element-rebinding
        // escape; direct eval captures only alias the existing indexed cells.
        // "All captures are cells" is now the `[]*core.VarRef` type invariant
        // (phase-D flip; qjs js_closure2, quickjs.c:17297-17331), so writes
        // always go through the cell — the former allVarRefCells scan is gone.
        // Captures.len == closure_var.len ≥ every bytecode var_ref idx, so
        // `ensureVarRefsCapacity` never fires either. Teardown skips the per-element
        // free (the still-live function object owns the cells).
        const borrow_var_refs = entry.function.global_vars.len == 0 and
            frame_var_refs.len > 0;
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

        try vm_call.initFrameLocals(ctx, entry.function, &entry.frame, true, frame_windows);
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
            // Alias the closure's captures (mutable slice; no merge replaced it).
            // The function object stays alive via
            // `frame.current_function`, so the cells outlive the frame.
            entry.frame.var_refs = target.captures.*;
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

    fn canBorrowSourceArgs(function: *const bytecode.Bytecode, source: ArgsSource) bool {
        const argc = sourceArgCount(source);
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

    /// Free the per-call rebuilt view of a cache-less FB. The view is
    /// non-owning (its slices borrow the FB), so only the box is freed.
    fn freeOwnedView(rt: *core.JSRuntime, entry: *Entry) void {
        if (entry.owned_view) |view| {
            rt.memory.destroy(bytecode.Bytecode, view);
            entry.owned_view = null;
        }
    }

    /// Push an inline call frame for `target` whose operand region starts at
    /// `region_base` on `caller_stack`, shaped by `layout` (see `RegionLayout`).
    /// On success the region has been popped from the caller stack and the
    /// machine's top entry — returned, so hot callers skip the `topEntry()`
    /// index arithmetic — is the new current execution level.
    pub fn pushCall(
        self: *Machine,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        target: *const InlineTarget,
        region_base: usize,
        argc: u16,
        layout: RegionLayout,
    ) HostError!*Entry {
        return self.pushFrame(global, target, switch (layout) {
            .plain, .method => .{ .stack_region = .{
                .stack = caller_stack,
                .region_base = region_base,
                .argc = argc,
                .has_receiver = layout == .method,
            } },
        });
    }

    /// Push a bytecode target reached through Function.prototype.call. Takes
    /// ownership of `native_caller` only on success; the caller retains and
    /// frees it when frame setup fails.
    pub fn pushForwardedCall(
        self: *Machine,
        global: *core.Object,
        caller_stack: *stack_mod.Stack,
        target: *const InlineTarget,
        region_base: usize,
        argc: u16,
        layout: RegionLayout,
        native_caller: core.JSValue,
    ) HostError!*Entry {
        const entry = try self.pushFrame(global, target, .{ .stack_region = .{
            .stack = caller_stack,
            .region_base = region_base,
            .argc = argc,
            .has_receiver = layout == .method,
        } });
        entry.native_caller = native_caller;
        return entry;
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
        target: *const InlineTarget,
        region_base: usize,
        argc: u16,
        layout: RegionLayout,
    ) HostError!*Entry {
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
        return self.pushFrame(global, target, .{ .moved = .{ .values = moved, .has_receiver = has_receiver } });
    }

    /// Tear down the top inline frame. Mirrors the defer chain of the
    /// recursive `runWithArgsState` + `callFunctionBytecodeModeState` exit
    /// path (frame, operand stack, arena watermark, profile scope, call depth).
    inline fn popTeardown(self: *Machine) void {
        const dying = self.topEntry();
        teardownInlineEntry(self.ctx, dying);
        self.ctx.call_depth -= 1;
        self.depth -= 1;
        // Unlink — qjs `rt->current_stack_frame = sf->prev_frame;` at the
        // done: epilogue (quickjs.c:20709).
        self.top = dying.prev;
    }

    /// Straight-line teardown for the common simple frame — qjs's `done:`
    /// epilogue (quickjs.c:20698-20710): free the operand-stack residue,
    /// close the frame's own open var refs, free locals + args, release the
    /// callable, restore the arena watermark. Every simple-frame gate is
    /// pre-resolved; the CALLER must have checked the dynamic escapes
    /// (`frame.cold == null`, `!frame.storage_on_heap`, `stack.arena_window`)
    /// — execution can grow the stack to the heap or
    /// materialize the cold box (arguments object), which needs the general
    /// teardown below.
    pub inline fn teardownSimpleEntry(ctx: *core.JSContext, entry: *Entry) void {
        const rt = ctx.runtime;
        const frame = &entry.frame;
        frame.current_function.free(rt);
        entry.native_caller.free(rt);
        if (frame.open_var_refs.len != 0) frame.closeOpenVarRefs(rt);
        // qjs done: close var refs first, then free local_buf..sp (quickjs.c:20701-20706).
        const live_values = frame.locals.ptr[0 .. frame.locals.len + entry.stack.values.len];
        for (live_values) |v| v.free(rt);
        for (frame.args) |v| v.free(rt);
        rt.vm_stack.restore(entry.arena_mark);
        entry.profile_guard.deinit();
    }

    /// Release every resource `setupInlineEntry` acquired for `entry` (frame,
    /// operand stack, arena watermark, and profile scope). The caller owns
    /// depth accounting + push/pop bookkeeping. Shared by the Machine
    /// (popTeardown) and the recursion path.
    pub fn teardownInlineEntry(ctx: *core.JSContext, entry: *Entry) void {
        const rt = ctx.runtime;
        entry.native_caller.free(rt);
        entry.stack.deinit(rt);
        entry.frame.deinitInlineCall(&rt.memory, rt);
        if (entry.owned_view != null) freeOwnedView(rt, entry);
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
