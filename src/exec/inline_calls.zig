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
    /// qjs `p->u.func.var_refs`, resolved once while the callable Object is hot.
    /// The callable below roots the owning Object; the immutable count lives on
    /// `fb`, exactly like qjs's `closure_var_count`. Keeping the bare pointer in
    /// the target avoids reloading the whole on-object union arm in each frame
    /// setup specialization.
    var_refs: [*]*core.VarRef,
    /// The callable closure value (becomes `frame.current_function`).
    callable: core.JSValue,
    fb: *const bytecode.FunctionBytecode,
    /// The pointer-stable per-FB cached execution view (`cachedBytecodeView`,
    /// built once per FB). Cache construction failure declines the same-Machine
    /// path before an InlineTarget exists; the authoritative generic call can
    /// execute the FB without this compatibility cache. qjs's OP_call hands
    /// `JS_CallInternal` only the 16B `func_obj` and the callee prologue
    /// dereferences `p->u.func.function_bytecode` (quickjs.c:17800) — zero
    /// struct freight. Keeping only pointers here keeps the target (and the
    /// `InlineCallRequest` riding through the dispatch driver) at qjs's
    /// scalars-only scale instead of dragging a by-value `Bytecode` through
    /// every call.
    view: *const bytecode.Bytecode,
    /// Raw receiver before [[Call]] `this` boxing: an arrow target's lexical
    /// `this` (arrows ignore any provided receiver), otherwise the call
    /// receiver — `undefined` for plain calls, the property base for method
    /// calls. Normal frames keep it raw until OP_push_this, arrow capture, or
    /// direct eval observes the binding. Borrowed; stays valid while `callable`
    /// is rooted (the lexical `this` is owned by the function object; a method
    /// receiver is co-owned with the operand region).
    this_value: core.JSValue,
    /// Lexical `new.target` for arrow targets, `undefined` otherwise.
    /// Borrowed; valid while `callable` is rooted.
    new_target: core.JSValue,

    pub inline fn captureSlice(self: InlineTarget) []*core.VarRef {
        return self.var_refs[0..self.fb.var_refs_len];
    }
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
/// captured on the function object (mirroring the slow path's arrow leg).
/// That lexical `this` was materialized, when necessary, in the enclosing
/// frame at arrow creation and is preserved verbatim here.
pub inline fn resolveInlineTarget(ctx: *core.JSContext, global: *core.Object, receiver: core.JSValue, func: core.JSValue) ?InlineTarget {
    const function_object = object_ops.functionObjectFromValue(func) orelse return null;
    const function_data = function_object.bytecodeFunctionStoragePtr();
    const fb = function_data.function_bytecode orelse return null;
    std.debug.assert(function_data.captureSlice().len == fb.var_refs_len);
    const var_refs = function_data.var_refs;
    if (fb.flags.func_kind != .normal) return null;
    if (fb.flags.is_class_constructor or fb.flags.is_derived_class_constructor) return null;
    // Realm gate: qjs reads `ctx = b->realm` from the shared FB. With FB now
    // resident directly in Object.u.func this is one dependent load, without a
    // per-closure realm cache or borrowed-holder registration.
    const function_global = if (fb.realm_global_header) |realm_header|
        @as(*core.Object, @fieldParentPtr("header", realm_header))
    else
        global;
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
    // qjs executes FB directly. ZJS's compatibility Bytecode view is shared by
    // the FB, never memoized once per closure.
    const view = bytecode.cachedBytecodeView(fb, &rt.memory, &rt.atoms) orelse return null;
    return .{
        .var_refs = var_refs,
        .callable = func,
        .fb = fb,
        .view = view,
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

/// One active inline call level. Entries live in chunked, pointer-stable
/// storage; `frame`, `stack`, and the frame's execution view are referenced by
/// the dispatch loop and backtrace pc borrows while the level is alive.
/// Work the caller must finish after an inline callee returns. Ordinary calls
/// push the result and resume immediately. Proxy `get` validates the trap
/// result against the target's post-call descriptor; generic for-of consumes
/// the returned iterator-result object before resuming the loop body.
pub const ReturnAction = enum(u8) {
    next,
    proxy_get,
    for_of_next,
};

pub const ReturnContinuation = struct {
    action: ReturnAction,
    /// Tagged by `action`: an owned Atom for `.proxy_get`, the for-of bytecode
    /// depth operand for `.for_of_next`, and zero for `.next`.
    payload: u32,

    pub fn deinit(self: *ReturnContinuation, rt: *core.JSRuntime) void {
        if (self.action == .proxy_get and self.payload != core.atom.null_atom) {
            rt.atoms.free(@intCast(self.payload));
        }
        self.action = .next;
        self.payload = 0;
    }

    /// Move the owned atom into the caller's continuation slot.
    pub fn takeAtom(self: *ReturnContinuation) core.Atom {
        std.debug.assert(self.action == .proxy_get);
        std.debug.assert(self.payload != core.atom.null_atom);
        const atom_id: core.Atom = @intCast(self.payload);
        self.payload = 0;
        return atom_id;
    }

    pub fn takeForOfDepth(self: *ReturnContinuation) u8 {
        std.debug.assert(self.action == .for_of_next);
        const depth: u8 = @intCast(self.payload);
        self.payload = 0;
        return depth;
    }
};

pub const Entry = struct {
    /// The Entry's sole persistent execution-view source is `frame.function`;
    /// `Vm.function` is only a reloadable hot dispatch cache. qjs likewise
    /// dispatches through one `JSFunctionBytecode *b` instead of mirroring it
    /// in an outer frame wrapper.
    frame: frame_mod.Frame,
    /// Keep the default NaN-boxed Entry at its 256-byte power-of-two stride
    /// after removing the obsolete per-call owned Bytecode view. `entryAt` can
    /// then retain shift-only element addressing on the production layout. The
    /// 16-byte reference representation needs no replacement padding; this
    /// field carries no state and is never initialized in either mode.
    _stride_padding: [if (core.value.nan_boxing) @sizeOf(usize) else 0]u8,
    stack: stack_mod.Stack,
    catch_target: ?usize,
    arena_mark: core.VmStackArena.Mark,
    profile_guard: vm_call.CallProfileGuard,
    /// True ONLY for a `setupSimpleInlineEntry` frame (borrowed
    /// var_refs, borrowed exact-arity args or slab-backed padded args, no owned
    /// view): the STATIC half of simple teardown eligibility. The frame's
    /// `OwnershipDisposition` is now the single source of truth for whether
    /// `this` is borrowed or owned; this flag records only teardown shape.
    simple_teardown: bool,
    return_action: ReturnAction,
    continuation_payload: u32,
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

    /// Move the post-call work out before this frame releases its resources.
    /// The returned value owns its action-tagged payload. The retired Entry keeps
    /// stale, non-owning bits until its slot is initialized by the next push;
    /// clearing them here only added two stores to every ordinary return.
    fn takeContinuation(self: *Entry) ReturnContinuation {
        return .{
            .action = self.return_action,
            .payload = self.continuation_payload,
        };
    }

    /// Move post-call work from a retired frame into its tail-call replacement.
    fn adoptContinuation(self: *Entry, continuation: *ReturnContinuation) void {
        std.debug.assert(self.return_action == .next);
        std.debug.assert(self.continuation_payload == 0);
        self.return_action = continuation.action;
        self.continuation_payload = continuation.payload;
        continuation.action = .next;
        continuation.payload = 0;
    }

    inline fn canUseSimpleTeardown(self: *const Entry) bool {
        return self.simple_teardown and self.frame.cold == null and
            self.frame.ownership.storage == .borrowed and self.stack.arena_window;
    }

    /// Release this frame after its continuation has been moved out. This is
    /// the single owner of the simple/general teardown decision.
    inline fn deinit(self: *Entry, ctx: *core.JSContext) void {
        if (self.canUseSimpleTeardown())
            self.deinitSimple(ctx)
        else
            self.deinitGeneral(ctx);
    }

    /// Straight-line qjs `done:` epilogue for the common arena-backed frame.
    inline fn deinitSimple(self: *Entry, ctx: *core.JSContext) void {
        const rt = ctx.runtime;
        const frame = &self.frame;
        std.debug.assert(self.canUseSimpleTeardown());
        std.debug.assert(frame.ownership.var_refs == .borrowed or frame.var_refs.len == 0);
        std.debug.assert(frame.locals.ptr + frame.locals.len == self.stack.values.ptr);
        if (frame.ownership.this_value == .owned) frame.this_value.free(rt);
        if (frame.ownership.current_function == .owned) frame.current_function.free(rt);
        self.native_caller.free(rt);
        if (frame.open_var_refs.len != 0) frame.closeOpenVarRefs(rt);
        // qjs done: close var refs first, then free local_buf..sp (quickjs.c:20701-20706).
        const live_values = frame.locals.ptr[0 .. frame.locals.len + self.stack.values.len];
        for (live_values) |v| v.free(rt);
        for (frame.args) |v| v.free(rt);
        rt.vm_stack.restore(self.arena_mark);
        self.profile_guard.deinit();
    }

    /// General teardown for frames whose stack, cold state, or storage escaped
    /// the common arena-backed shape.
    fn deinitGeneral(self: *Entry, ctx: *core.JSContext) void {
        const rt = ctx.runtime;
        self.native_caller.free(rt);
        self.stack.deinit(rt);
        self.frame.deinitInlineCall(&rt.memory, rt);
        rt.vm_stack.restore(self.arena_mark);
        self.profile_guard.deinit();
    }
};

comptime {
    const expected_size: usize = if (core.value.nan_boxing) 256 else 280;
    if (@sizeOf(Entry) != expected_size) @compileError(std.fmt.comptimePrint(
        "inline Entry layout drifted: expected {d} bytes, found {d}",
        .{ expected_size, @sizeOf(Entry) },
    ));
}

/// The mutable execution resources for one active bytecode level. `frame`
/// owns the authoritative execution view (`frame.function`); the operand
/// stack and catch slot stay separate only because their storage lifetimes
/// differ from the frame slab. The struct itself is a borrowed view.
pub const ExecutionLevel = struct {
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    catch_target: *?usize,

    pub inline fn function(self: ExecutionLevel) *const bytecode.Bytecode {
        return self.frame.function;
    }
};

/// Invocation-root state shared by the inline-frame Machine and the dispatch
/// driver. There is exactly one instance per `runWithArgsState` invocation;
/// Machine and Vm borrow it instead of mirroring the L0 frame/stack/catch
/// pointers and entry policy in parallel fields.
pub const L0State = struct {
    level: ExecutionLevel,
    is_eval_code: bool = false,
    eval_global_var_bindings: bool = false,
    strict_unresolved_get_var: bool = false,
    generator_state: ?*core.Object = null,
    stop_on_yield: bool = false,
    stop_before_pc: ?usize = null,
    suspend_on_module_await: bool = false,
};

const entries_per_chunk: usize = 16;
const max_chunks: usize = 512;

/// Indexed resolver for an invocation node backed directly by Machine: index
/// 0 is the innermost inline frame, walking outward through Entry.prev to the
/// L0 frame; null past the end. Machine is initialized at its final address
/// before this resolver is published, so `data` has no parallel holder state.
pub fn resolveMachineBacktrace(data: ?*const anyopaque, index: usize) ?core.ActiveBacktraceSnapshot {
    const machine: *const Machine = @ptrCast(@alignCast(data.?));
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
    if (remaining == 0) return exception_ops.frameBacktraceSnapshot(machine.l0.level.frame);
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
    /// Borrowed invocation root, used when the inline chain reaches depth 0.
    l0: *const L0State,
    /// Chunked entry storage; only the first `chunk_count` slots are valid.
    /// The chunk-pointer array is heap-allocated lazily on the first inline
    /// push (capacity `max_chunks`), so a Machine that never pushes carries
    /// only a 16-byte empty slice instead of a 4 KiB inline array.
    chunks: []*[entries_per_chunk]Entry = &.{},
    chunk_count: usize = 0,
    depth: usize = 0,
    /// Current (innermost) live Entry, or null at depth 0 — qjs
    /// `rt->current_stack_frame` (quickjs.c:358). All frame ADDRESSES come
    /// from this pointer and the `Entry.prev` chain; `depth` stays purely
    /// for accounting (L0 boundary tests, backtrace length, slot reuse).
    /// Maintained in lockstep with `depth` by pushFrame/popFrame.
    top: ?*Entry = null,
    pub fn init(ctx: *core.JSContext, output: ?*std.Io.Writer, global: *core.Object, l0: *const L0State) Machine {
        return .{
            .ctx = ctx,
            .output = output,
            .global = global,
            .l0 = l0,
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
            var continuation = self.popFrame();
            continuation.deinit(self.ctx.runtime);
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

    /// Load the current execution resources without materializing a 24-byte
    /// aggregate. This shape is load-bearing for the tail-call driver, which
    /// refreshes these caches on every reused frame.
    pub inline fn loadCurrentLevel(
        self: *Machine,
        frame: **frame_mod.Frame,
        stack: **stack_mod.Stack,
        catch_target: **?usize,
    ) void {
        if (self.depth == 0) {
            frame.* = self.l0.level.frame;
            stack.* = self.l0.level.stack;
            catch_target.* = self.l0.level.catch_target;
        } else {
            const entry = self.topEntry();
            frame.* = &entry.frame;
            stack.* = &entry.stack;
            catch_target.* = &entry.catch_target;
        }
    }

    /// Borrowed current-level view for cold setup, return, and unwind paths.
    pub inline fn currentLevel(self: *Machine) ExecutionLevel {
        var level: ExecutionLevel = undefined;
        self.loadCurrentLevel(&level.frame, &level.stack, &level.catch_target);
        return level;
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
        /// Region still live on the caller's operand stack; it is popped during
        /// frame setup after receiver/callable ownership and argument slots
        /// have transferred into the callee. Layout is `[callable, args...]`, or
        /// `[receiver, callable, args...]` when `has_receiver` (a non-tail
        /// method call; the receiver becomes the new frame's `this`).
        stack_region: struct {
            stack: *stack_mod.Stack,
            region_base: usize,
            argc: u16,
            has_receiver: bool,
        },
        /// Owned temporary region used by tail-call frame reuse and post-call
        /// continuations. Layout is `[callable, args...]`, or
        /// `[receiver, callable, args...]` when `has_receiver`. Entries
        /// transfer to the new frame and are replaced with undefined as they
        /// move; the caller frees whatever is left.
        moved: struct {
            values: []core.JSValue,
            has_receiver: bool,
        },
    };

    const FrameSetupPath = enum {
        generic,
        moved_method,
        borrowed_iterator,
    };

    /// Push an inline call frame for `target`. Shared between plain inline
    /// calls (`pushCall`) and tail-call frame reuse (`tailCallReuse`).
    /// `target` rides by pointer end-to-end (qjs OP_call passes only the 16B
    /// func_obj; nothing struct-sized is copied per call).
    /// Returns the new top entry so the caller can enter it directly — qjs's
    /// callee frame address is the `alloca` result already in a register
    /// (quickjs.c:17846); re-deriving it from the depth index (`topEntry()`)
    /// would redo the chunk multiply for nothing.
    fn pushFrame(self: *Machine, comptime setup_path: FrameSetupPath, global: *core.Object, target: *const InlineTarget, source: ArgsSource) align(64) HostError!*Entry {
        try vm_call.enterInlineCallDepth(self.ctx, global);
        errdefer self.ctx.call_depth -= 1;
        const entry = try self.acquireSlot(global);
        entry.native_caller = core.JSValue.undefinedValue();
        // Generic calls own an ordinary `.next` continuation immediately.
        // The moved-method and borrowed-iterator instances are reached only
        // through scoped push helpers, which publish their real action/payload
        // after setup succeeds. Until then the Entry is unlinked, so
        // initializing `.next/0` here merely writes two values that its sole
        // owner overwrites before any read.
        if (setup_path == .generic) {
            entry.return_action = .next;
            entry.continuation_payload = 0;
        }
        if (setup_path == .borrowed_iterator) {
            try setupBorrowedIteratorEntry(self.ctx, entry, target);
        } else if (setup_path == .moved_method) {
            if (methodSimpleInlineMode(target, source)) |mode| switch (mode) {
                .moved_exact => try setupSimpleInlineEntry(false, false, false, true, true, self.ctx, global, entry, target, source),
                .moved_padded => try setupSimpleInlineEntry(false, false, true, true, true, self.ctx, global, entry, target, source),
                .moved_snapshot_exact => try setupSimpleInlineEntry(false, true, false, true, true, self.ctx, global, entry, target, source),
                .moved_snapshot_padded => try setupSimpleInlineEntry(false, true, true, true, true, self.ctx, global, entry, target, source),
                .stack_exact, .stack_padded, .stack_snapshot_exact, .stack_snapshot_padded => unreachable,
            } else {
                try setupInlineEntry(self.ctx, global, entry, target, source);
            }
        } else if (isSimpleInlineFrame(target, source)) {
            try setupSimpleInlineEntry(false, false, false, false, false, self.ctx, global, entry, target, source);
        } else if (isStrictSimpleInlineFrame(false, target, source)) {
            try setupSimpleInlineEntry(true, false, false, false, false, self.ctx, global, entry, target, source);
        } else {
            try setupFallbackInlineEntry(self.ctx, global, entry, target, source);
        }
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
    /// args that can be borrowed in place, and all-cell closure captures
    /// (borrowable as `var_refs`). Each rejected condition is exactly a branch
    /// the lean path elides; method, moved-method, arity-padding, and snapshot
    /// variants are selected by the outlined fallback. `setupInlineEntry`
    /// remains authoritative for arrows and non-simple parameters.
    fn isSimpleInlineFrame(target: *const InlineTarget, source: ArgsSource) bool {
        const function = target.view;
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

    const PaddedSimpleInlineMode = enum {
        sloppy,
        strict,
        strict_snapshot,
    };

    const MethodSimpleInlineMode = enum {
        stack_exact,
        stack_padded,
        stack_snapshot_exact,
        stack_snapshot_padded,
        moved_exact,
        moved_padded,
        moved_snapshot_exact,
        moved_snapshot_padded,
    };

    /// Select the qjs `argc < arg_count` twin of a simple frame. qjs does not
    /// switch to a second frame constructor for this case: it prefixes the
    /// existing alloca region with `arg_count` slots, moves the supplied argv,
    /// and fills the missing tail with undefined (quickjs.c:17828-17861).
    /// Keep this call-site-dependent classification in the outlined fallback
    /// so exact-arity `pushFrame` retains its established hot shape.
    fn paddedSimpleInlineMode(target: *const InlineTarget, source: ArgsSource) ?PaddedSimpleInlineMode {
        const function = target.view;
        const region = switch (source) {
            .stack_region => |region| region,
            .moved => return null,
        };
        if (region.has_receiver) return null;
        if (!target.this_value.isUndefined()) return null;
        if (region.argc >= function.arg_count) return null;
        if (function.simple_inline_eligible) return .sloppy;
        if (function.strict_simple_inline_eligible) return .strict;
        if (function.strict_simple_snapshot_inline_eligible) return .strict_snapshot;
        return null;
    }

    /// Select a simple frame for `[receiver, callable, args...]`, whether the
    /// region still occupies the caller stack or was moved aside for a Proxy
    /// continuation/tail-call reuse. Object and primitive receivers both
    /// transfer verbatim: qjs stores raw `this_obj` in this same
    /// JS_CallInternal frame and performs sloppy substitution or boxing only
    /// at OP_push_this (quickjs.c:17924-17944).
    fn methodSimpleInlineMode(target: *const InlineTarget, source: ArgsSource) ?MethodSimpleInlineMode {
        const function = target.view;
        const source_kind: enum { stack, moved } = switch (source) {
            .stack_region => |region| blk: {
                if (!region.has_receiver) return null;
                const receiver = region.stack.values[region.region_base];
                if (!target.this_value.same(receiver)) return null;
                break :blk .stack;
            },
            .moved => |moved| blk: {
                if (!moved.has_receiver) return null;
                const receiver = moved.values[0];
                if (!target.this_value.same(receiver)) return null;
                break :blk .moved;
            },
        };

        const snapshot = function.strict_simple_snapshot_inline_eligible;
        const no_snapshot = function.simple_inline_eligible or function.strict_simple_inline_eligible;
        if (!snapshot and !no_snapshot) return null;
        const padded = sourceArgCount(source) < function.arg_count;
        return switch (source_kind) {
            .stack => if (snapshot)
                if (padded) .stack_snapshot_padded else .stack_snapshot_exact
            else if (padded)
                .stack_padded
            else
                .stack_exact,
            .moved => if (snapshot)
                if (padded) .moved_snapshot_padded else .moved_snapshot_exact
            else if (padded)
                .moved_padded
            else
                .moved_exact,
        };
    }

    /// Strict-mode twin of `isSimpleInlineFrame`. qjs uses the same
    /// JS_CallInternal frame layout for strict and sloppy functions; the only
    /// plain-call difference is that strict preserves undefined `this` while
    /// sloppy substitutes the realm global. A separate precomputed flag and
    /// setup instantiation keep that choice off the established sloppy path.
    fn isStrictSimpleInlineFrame(comptime snapshot_args: bool, target: *const InlineTarget, source: ArgsSource) bool {
        const function = target.view;
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
    /// All setup callees are noinline and this function only returns their
    /// result, allowing ReleaseFast to use a tail branch rather than another
    /// frame.
    noinline fn setupFallbackInlineEntry(ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource) HostError!void {
        if (methodSimpleInlineMode(target, source)) |mode| switch (mode) {
            .stack_exact => return setupSimpleInlineEntry(false, false, false, true, false, ctx, global, entry, target, source),
            .stack_padded => return setupSimpleInlineEntry(false, false, true, true, false, ctx, global, entry, target, source),
            .stack_snapshot_exact => return setupSimpleInlineEntry(false, true, false, true, false, ctx, global, entry, target, source),
            .stack_snapshot_padded => return setupSimpleInlineEntry(false, true, true, true, false, ctx, global, entry, target, source),
            .moved_exact => return setupSimpleInlineEntry(false, false, false, true, true, ctx, global, entry, target, source),
            .moved_padded => return setupSimpleInlineEntry(false, false, true, true, true, ctx, global, entry, target, source),
            .moved_snapshot_exact => return setupSimpleInlineEntry(false, true, false, true, true, ctx, global, entry, target, source),
            .moved_snapshot_padded => return setupSimpleInlineEntry(false, true, true, true, true, ctx, global, entry, target, source),
        };
        if (paddedSimpleInlineMode(target, source)) |mode| switch (mode) {
            .sloppy => return setupSimpleInlineEntry(false, false, true, false, false, ctx, global, entry, target, source),
            .strict => return setupSimpleInlineEntry(true, false, true, false, false, ctx, global, entry, target, source),
            .strict_snapshot => return setupSimpleInlineEntry(true, true, true, false, false, ctx, global, entry, target, source),
        };
        if (isStrictSimpleInlineFrame(true, target, source)) {
            return setupSimpleInlineEntry(true, true, false, false, false, ctx, global, entry, target, source);
        }
        return setupInlineEntry(ctx, global, entry, target, source);
    }

    /// Straight-line frame setup for the plain/method simple-inline shapes —
    /// the hot fib/closure/method-call paths, a line-for-line mirror of qjs
    /// `JS_CallInternal`'s
    /// prologue (quickjs.c:17828-17871): compute the storage need, carve ONE
    /// contiguous slab, partition it by pointer arithmetic, bind every frame
    /// field exactly once. No shared-primitive calls, no `Frame.init`
    /// default-then-overwrite pass, no by-value `FrameSlab` /
    /// `FrameStorageWindows` round-trips. Every simple-case branch is resolved
    /// at compile time: a plain call borrows global/undefined `this`, while a
    /// method moves its receiver into the frame; original-args snapshot absent
    /// or arena-backed, exact-arity args borrowed or missing args padded at the
    /// slab front, borrowed all-cell var_refs. Lives
    /// in its OWN function so its register allocation is not coupled to the
    /// general path (whose register pressure spilled the hot fields). Ownership
    /// flags MUST mirror the general path exactly: current_function .take,
    /// plain this .borrow / method this .take, new_target borrowed, stack exact
    /// args borrowed / padded and temporary-region args moved, var_refs
    /// borrowed.
    ///
    /// `noinline` is LOAD-BEARING: the whole point is to keep this register
    /// allocation OFF the general `setupInlineEntry`/`pushFrame` chain. If LLVM
    /// inlines it back into `pushFrame`, the simple path's spills re-couple with
    /// the general path and the win evaporates (measured: 3.09x→3.26x qjs on fib).
    noinline fn setupSimpleInlineEntry(comptime strict_this: bool, comptime snapshot_args: bool, comptime pad_args: bool, comptime method_receiver: bool, comptime move_args: bool, ctx: *core.JSContext, global: *core.Object, entry: *Entry, target: *const InlineTarget, source: ArgsSource) HostError!void {
        const rt = ctx.runtime;
        const function = target.view;
        entry.catch_target = null;
        entry.simple_teardown = true;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        errdefer entry.profile_guard.deinit();

        // `move_args` makes the source variant compile-time fixed: ordinary
        // calls borrow/move out of their caller stack region, while Proxy
        // continuations and tail-call reuse consume a temporary owned region.
        // Both share `[receiver, callable, args...]` for method calls.
        comptime std.debug.assert(!move_args or method_receiver);
        const region = if (move_args)
            switch (source) {
                .moved => |r| r,
                .stack_region => unreachable,
            }
        else switch (source) {
            .stack_region => |r| r,
            .moved => unreachable,
        };
        std.debug.assert(region.has_receiver == method_receiver);
        const receiver_count: usize = @intFromBool(method_receiver);
        const region_base: usize = if (move_args) 0 else region.region_base;
        const argc: usize = if (move_args) region.values.len - receiver_count - 1 else region.argc;
        const source_value_count = region_base + receiver_count + 1 + argc;
        if (!move_args) std.debug.assert(region.stack.values.len >= source_value_count);
        const actual_arg_count = argc;
        const frame_arg_count: usize = if (pad_args) @intCast(function.arg_count) else actual_arg_count;
        const arg_storage_count: usize = if (pad_args or move_args) frame_arg_count else 0;
        const snapshot_count: usize = if (snapshot_args) actual_arg_count else 0;
        if (pad_args) {
            std.debug.assert(actual_arg_count < frame_arg_count);
        } else {
            std.debug.assert(actual_arg_count >= @as(usize, @intCast(function.arg_count)));
        }
        // Retreat the caller's operand region NOW, before the slab carve — qjs
        // borrows the caller slots equally early (`arg_buf = argv`, 17841) and
        // the caller sp is dead from here on. Doing it at the tail put the
        // store at the end of the whole setup dependency chain (measured 18%
        // of this function); only the slice len shrinks, so `callable_slot`
        // and `args` still point at live capacity-region memory (the arena
        // watermark is untouched — the new slab below cannot overlap them),
        // and the values keep their refcounts (the cycle collector roots by
        // rc, it never scans operand-stack slices).
        if (!move_args) region.stack.values = region.stack.values.ptr[0..region.region_base];
        // On failure below nothing has been bound yet (`takeSourceSlot` runs
        // in the frame literal, after the last failable point): restore the
        // pre-truncation len — the region layout pins it at
        // `region_base + receiver? + callable(1) + argc` — so
        // popOwnedStackRegion sees and frees the whole region, matching the
        // general path's `.full` cleanup.
        errdefer if (!move_args) {
            region.stack.values = region.stack.values.ptr[0 .. region.region_base + receiver_count + 1 + region.argc];
            cleanupStackSource(rt, source);
        };

        // alloca_size (quickjs.c:17834-17836): optional padded args | locals |
        // operand stack | open var-ref slots | zjs original-args snapshot.
        // Exact args are borrowed in place (`arg_buf = argv`, 17841). Missing
        // args use qjs's `arg_allocated_size = b->arg_count` prefix (17828,
        // 17848-17857). var_refs remain borrowed from the closure (17844).
        const var_count: usize = function.var_count;
        const stack_count = @as(usize, function.stack_size) + 1;
        const open_var_ref_count = frame_mod.frameOpenVarRefStorageCount(function);
        const open_slots = if (open_var_ref_count == 0)
            0
        else
            (open_var_ref_count * @sizeOf(?*core.VarRef) + (@sizeOf(core.JSValue) - 1)) / @sizeOf(core.JSValue);
        const total = arg_storage_count + var_count + stack_count + open_slots + snapshot_count;

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

        // Pointer-arithmetic partition (17855-17866). Padded args occupy the
        // prefix exactly as qjs's `arg_buf = local_buf`; the zero-sized exact
        // specialization retains the prior locals-first layout.
        const arg_storage = slab_values[0..arg_storage_count];
        const locals_start = arg_storage_count;
        const stack_start = locals_start + var_count;
        const open_start = stack_start + stack_count;
        const snapshot_start = open_start + open_slots;
        const locals = slab_values[locals_start..][0..var_count];
        const stack_window = slab_values[stack_start..][0..stack_count];
        const open_var_refs: []?*core.VarRef = if (open_slots == 0)
            &.{}
        else
            std.mem.bytesAsSlice(?*core.VarRef, std.mem.sliceAsBytes(slab_values[open_start..][0..open_slots]))[0..open_var_ref_count];
        const original_args = slab_values[snapshot_start..][0..snapshot_count];

        @memset(locals, core.JSValue.undefinedValue()); // 17859-17860
        if (open_var_refs.len != 0) @memset(open_var_refs, null); // 17866-17867

        // The source slots stay live in the caller's arena capacity after its
        // logical stack length retreats. Rebuild their view only after the
        // slab carve, matching qjs's late argv consumption and avoiding an
        // args-start scalar live across every failable allocation point.
        const values = if (move_args)
            region.values
        else
            region.stack.values.ptr[0..source_value_count];
        const receiver_slot: ?*core.JSValue = if (method_receiver) &values[region_base] else null;
        const callable_slot = &values[region_base + receiver_count];
        const args = values[region_base + receiver_count + 1 ..][0..actual_arg_count];

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

        // All failable setup is complete. Transfer supplied argument ownership
        // into the padded/moved prefix, clear the source slots, then initialize
        // only a missing tail. Exact caller-stack args continue borrowing the
        // original operand slots.
        const frame_args = if (pad_args or move_args) arg_storage else args;
        if (pad_args or move_args) {
            @memcpy(frame_args[0..actual_arg_count], args);
            @memset(args, core.JSValue.undefinedValue());
            if (pad_args) @memset(frame_args[actual_arg_count..], core.JSValue.undefinedValue());
        }

        const captures = target.captureSlice();
        // Bind the frame in ONE shot — qjs sets sf's handful of fields
        // (17838-17845) with no default-init-then-overwrite pass. The setup
        // instantiation makes the receiver choice at compile time: a method
        // takes the operand receiver; a strict plain call preserves undefined;
        // a sloppy plain call borrows the global (17933, sloppy leg). `pc`
        // keeps its struct default; `cold` is either null or the prebuilt
        // original-args snapshot box.
        entry.frame = .{
            .function = function,
            .this_value = if (method_receiver)
                takeSourceSlot(receiver_slot.?)
            else if (strict_this)
                core.JSValue.undefinedValue()
            else
                global.value(),
            .current_function = takeSourceSlot(callable_slot),
            .new_target = target.new_target,
            .actual_arg_count = actual_arg_count,
            .locals = locals,
            .args = frame_args,
            .var_refs = captures,
            .open_var_refs = open_var_refs,
            .storage_values = if (storage_on_heap) slab_values else &.{},
            .ownership = .{
                .this_value = if (method_receiver) .owned else .borrowed,
                .var_refs = if (captures.len > 0) .borrowed else .owned,
                .storage = if (storage_on_heap) .owned else .borrowed,
            },
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
        // Point at the pointer-stable per-FB cached view (no copy). Target
        // resolution declines this same-Machine path if the once-per-FB cache
        // allocation fails, so general frame setup has no nullable-view arm.
        const function = target.view;
        entry.catch_target = null;
        entry.simple_teardown = false;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        errdefer entry.profile_guard.deinit();

        const callable_slot = sourceCallableSlot(source);
        const frame_var_refs: []const *core.VarRef = target.captureSlice();

        entry.arena_mark = rt.vm_stack.mark();
        errdefer rt.vm_stack.restore(entry.arena_mark);

        entry.frame = frame_mod.Frame.init(function);
        errdefer entry.frame.deinit(&rt.memory, rt);
        // No per-call backtrace node: the invocation's Machine-owned node
        // walks this Entry directly through the execution chain.

        // Keep qjs's raw `this_obj` for method receivers, including sloppy
        // primitives. The established plain-undefined specialization remains
        // allocation-free (strict undefined / sloppy global); observed method
        // bindings materialize later through OP_push_this/arrow/eval.
        const fb_strict = target.fb.flags.is_strict_mode or target.fb.flags.runtime_strict_mode;
        const receiver_slot = sourceReceiverSlot(source);
        const plain_undefined_this = !target.fb.flags.is_arrow_function and receiver_slot == null and target.this_value.isUndefined();
        const effective_this = if (plain_undefined_this)
            if (fb_strict) core.JSValue.undefinedValue() else global.value()
        else
            target.this_value;

        var take_receiver_as_this = false;
        if (!target.fb.flags.is_arrow_function) {
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
        //   this .borrow, unless taken raw from the receiver slot (method call)
        //   -> then .take/owned. Lazy materialization updates this slot once.
        // `takeSourceSlot` nulls the source slot so the popped stack region
        // never double-frees the value (the leak guard the method-call comment
        // below describes).
        entry.frame.current_function = takeSourceSlot(callable_slot);
        entry.frame.new_target = target.new_target;
        if (take_receiver_as_this) {
            entry.frame.this_value = takeSourceSlot(receiver_slot.?);
            entry.frame.ownership.this_value = .owned;
        } else {
            entry.frame.this_value = effective_this;
            entry.frame.ownership.this_value = .borrowed;
        }

        const argc = sourceArgCount(source);
        const frame_arg_count = frame_mod.frameArgCount(function, argc);
        const need_original_snapshot = frame_mod.argumentsNeedsOriginalSnapshot(function);
        const borrow_source_args = canBorrowSourceArgs(function, source);
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
        const borrow_var_refs = function.global_vars.len == 0 and
            frame_var_refs.len > 0;
        const var_ref_storage_count: usize = if (borrow_var_refs) 0 else frame_mod.frameVarRefStorageCount(function, frame_var_refs);
        const open_var_ref_count = frame_mod.frameOpenVarRefStorageCount(function);
        const slab = frame_mod.FrameSlab.carve(
            &rt.memory,
            &rt.vm_stack,
            storage_arg_count,
            frame_mod.originalArgCount(argc, need_original_snapshot),
            function.var_count,
            @as(usize, function.stack_size) + 1,
            var_ref_storage_count,
            open_var_ref_count,
        ) orelse blk: {
            const heap_windows = try frame_mod.FrameSlab.allocHeap(
                &rt.memory,
                storage_arg_count,
                frame_mod.originalArgCount(argc, need_original_snapshot),
                function.var_count,
                @as(usize, function.stack_size) + 1,
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

        try vm_call.initFrameLocals(ctx, function, &entry.frame, true, frame_windows);
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
            try entry.frame.installOpenVarRefSlots(open_refs);
        } else if (open_var_ref_count != 0) {
            try entry.frame.ensureOpenVarRefSlots(&rt.memory, &rt.vm_stack, true);
        }
        try vm_call.linkDerivedConstructorThisLocal(ctx, function, &entry.frame);
        if (borrow_var_refs) {
            // Alias the closure's captures (mutable slice; no merge replaced it).
            // The function object stays alive via
            // `frame.current_function`, so the cells outlive the frame.
            entry.frame.var_refs = target.captureSlice();
            entry.frame.ownership.var_refs = .borrowed;
        } else if (frame_var_refs.len != 0 or function.var_ref_names.len != 0) {
            try vm_call.initFrameVarRefs(ctx, global, function, &entry.frame, frame_var_refs, true, frame_windows);
        }
    }

    /// Eligibility for the qjs internal-IteratorNext binding contract. The
    /// ordinary method selector proves the same FB conditions; this form has no
    /// source-union switch because argc is statically zero and the receiver and
    /// callable remain rooted in the suspended caller's iterator record.
    inline fn isBorrowedIteratorSimpleInlineFrame(target: *const InlineTarget, iterator_record: []const core.JSValue) bool {
        if (iterator_record.len != 2) return false;
        if (!target.this_value.same(iterator_record[0])) return false;
        if (!target.callable.same(iterator_record[1])) return false;
        const function = target.view;
        return function.simple_inline_eligible or
            function.strict_simple_inline_eligible or
            function.strict_simple_snapshot_inline_eligible;
    }

    /// Zero-argument method prologue for an iterator record borrowed from the
    /// suspended caller. qjs's JS_CallInternal assigns `sf->cur_func = func_obj`
    /// and reads `this_obj` without retaining either value; the caller operand
    /// stack remains their owner. Keep this body separate from the established
    /// plain/method setup instances so a narrow iterator optimization cannot
    /// perturb their selector or register allocation.
    noinline fn setupBorrowedIteratorEntry(ctx: *core.JSContext, entry: *Entry, target: *const InlineTarget) HostError!void {
        const rt = ctx.runtime;
        const function = target.view;
        entry.catch_target = null;
        entry.simple_teardown = true;
        entry.profile_guard = vm_call.enterCallProfile(rt);
        errdefer entry.profile_guard.deinit();

        const frame_arg_count: usize = @intCast(function.arg_count);
        const var_count: usize = function.var_count;
        const stack_count = @as(usize, function.stack_size) + 1;
        const open_var_ref_count = frame_mod.frameOpenVarRefStorageCount(function);
        const open_slots = if (open_var_ref_count == 0)
            0
        else
            (open_var_ref_count * @sizeOf(?*core.VarRef) + (@sizeOf(core.JSValue) - 1)) / @sizeOf(core.JSValue);
        const total = frame_arg_count + var_count + stack_count + open_slots;

        entry.arena_mark = rt.vm_stack.mark();
        errdefer rt.vm_stack.restore(entry.arena_mark);

        var storage_on_heap = false;
        const slab_values = rt.vm_stack.carve(&rt.memory, total) orelse blk: {
            const heap = try rt.memory.alloc(core.JSValue, total);
            storage_on_heap = true;
            break :blk heap;
        };
        errdefer if (storage_on_heap) rt.memory.free(core.JSValue, slab_values);

        const args = slab_values[0..frame_arg_count];
        const locals_start = frame_arg_count;
        const stack_start = locals_start + var_count;
        const open_start = stack_start + stack_count;
        const locals = slab_values[locals_start..][0..var_count];
        const stack_window = slab_values[stack_start..][0..stack_count];
        const open_var_refs: []?*core.VarRef = if (open_slots == 0)
            &.{}
        else
            std.mem.bytesAsSlice(?*core.VarRef, std.mem.sliceAsBytes(slab_values[open_start..][0..open_slots]))[0..open_var_ref_count];

        @memset(args, core.JSValue.undefinedValue());
        @memset(locals, core.JSValue.undefinedValue());
        if (open_var_refs.len != 0) @memset(open_var_refs, null);

        const captures = target.captureSlice();
        // All failable work is complete. Both call bindings borrow the caller
        // iterator record; only the slab contents belong to this frame.
        entry.frame = .{
            .function = function,
            .this_value = target.this_value,
            .current_function = target.callable,
            .new_target = target.new_target,
            .actual_arg_count = 0,
            .locals = locals,
            .args = args,
            .var_refs = captures,
            .open_var_refs = open_var_refs,
            .storage_values = if (storage_on_heap) slab_values else &.{},
            .ownership = .{
                .this_value = .borrowed,
                .current_function = .borrowed,
                .var_refs = if (captures.len > 0) .borrowed else .owned,
                .storage = if (storage_on_heap) .owned else .borrowed,
            },
        };
        entry.stack = stack_mod.Stack.initArenaWindow(&rt.memory, rt.stack_size, stack_window);
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
        return self.pushFrame(.generic, global, target, switch (layout) {
            .plain, .method => .{ .stack_region = .{
                .stack = caller_stack,
                .region_base = region_base,
                .argc = argc,
                .has_receiver = layout == .method,
            } },
        });
    }

    /// Push a call whose owned receiver/callable/arguments already live in a
    /// temporary moved region. The frame setup consumes entries by replacing
    /// them with undefined; the caller remains responsible for freeing any
    /// entries left behind on setup failure.
    pub fn pushMovedCall(
        self: *Machine,
        global: *core.Object,
        target: *const InlineTarget,
        moved_values: []core.JSValue,
        layout: RegionLayout,
        return_action: ReturnAction,
        continuation_payload: u32,
    ) HostError!*Entry {
        const source: ArgsSource = .{ .moved = .{
            .values = moved_values,
            .has_receiver = layout == .method,
        } };
        const entry = if (layout == .method)
            try self.pushFrame(.moved_method, global, target, source)
        else
            try self.pushFrame(.generic, global, target, source);
        entry.return_action = return_action;
        entry.continuation_payload = switch (return_action) {
            .next => 0,
            .proxy_get => self.ctx.runtime.atoms.dup(@intCast(continuation_payload)),
            .for_of_next => continuation_payload,
        };
        return entry;
    }

    /// Try to push a simple bytecode iterator `next()` while borrowing the
    /// persistent `[iterator, next]` record from the suspended caller frame.
    /// A non-simple target returns null and retains the established dup/move
    /// path, whose general setup may outlive or mutate its source bindings.
    pub fn pushBorrowedIteratorNext(
        self: *Machine,
        global: *core.Object,
        target: *const InlineTarget,
        iterator_record: []core.JSValue,
        depth: u8,
    ) HostError!?*Entry {
        if (!isBorrowedIteratorSimpleInlineFrame(target, iterator_record)) return null;
        // The borrowed setup path ignores ArgsSource; pass the caller record as
        // a diagnostic witness without changing or taking either slot.
        const entry = try self.pushFrame(.borrowed_iterator, global, target, .{ .moved = .{
            .values = iterator_record,
            .has_receiver = true,
        } });
        entry.return_action = .for_of_next;
        entry.continuation_payload = depth;
        return entry;
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
        const entry = try self.pushFrame(.generic, global, target, .{ .stack_region = .{
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

        var continuation = self.popFrame();
        defer continuation.deinit(rt);
        const entry = try self.pushFrame(.generic, global, target, .{ .moved = .{ .values = moved, .has_receiver = has_receiver } });
        entry.adoptContinuation(&continuation);
        return entry;
    }

    /// Retire the top inline frame through the single qjs-style `done:`
    /// epilogue. The returned continuation owns its atom until it is consumed,
    /// transferred to a tail-call replacement, or explicitly deinitialized.
    pub inline fn popFrame(self: *Machine) ReturnContinuation {
        const dying = self.topEntry();
        const continuation = dying.takeContinuation();
        dying.deinit(self.ctx);
        self.ctx.call_depth -= 1;
        self.depth -= 1;
        // Unlink — qjs `rt->current_stack_frame = sf->prev_frame;` at the
        // done: epilogue (quickjs.c:20709).
        self.top = dying.prev;
        return continuation;
    }

    /// Pop the top inline frame after a completed return. Ordinary calls push
    /// `result` onto the caller stack; continuations retain it in the driver's
    /// return slot until their post-call action runs. Takes ownership of
    /// `result` either way and returns the selected action.
    pub fn popReturn(self: *Machine, result: core.JSValue) ReturnContinuation {
        const continuation = self.popFrame();
        if (continuation.action == .next) {
            std.debug.assert(continuation.payload == 0);
            self.currentLevel().stack.pushOwnedAssumeCapacity(result);
        }
        return continuation;
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
            var continuation = self.popFrame();
            const iterator_next_abrupt = continuation.action == .for_of_next;
            continuation.deinit(ctx.runtime);

            const level = self.currentLevel();
            // A throw from IteratorNext propagates directly; IteratorClose is
            // required for abrupt loop-body completion, not for a failing
            // `next()` call itself. The continuation survives proper-tail-call
            // replacement, so this remains exact even when next tail-calls.
            if (!iterator_next_abrupt) {
                try forof_ops.closeStackTopForOfIteratorForPendingError(ctx, self.output, global, level.stack);
            }
            if (try call_runtime.tryCatchInFrame(ctx, level.stack, level.frame, level.catch_target, global, err)) return true;
            if (self.depth == 0) return false;
        }
        return false;
    }
};
