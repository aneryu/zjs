//! Runtime-wide ownership, allocation, GC scheduling, roots, and host policy.
//!
//! `JSRuntime` owns the atom/class/shape registries, memory account, job FIFO,
//! contexts, deferred native cleanup, and persistent handles. It is
//! owner-thread confined except at the explicitly synchronized host seams;
//! handles and root frames keep values alive but never transfer Runtime
//! ownership. QuickJS source map: `JSRuntime` and its registries at
//! quickjs.c. This is core infrastructure: exec/runtime/binding may
//! import it, while this module must not import those higher layers.

const mem_ops = @import("core/memory.zig");
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const platform_clock = @import("platform_clock.zig");

const memory = @import("core/memory.zig");
const alloc_trace = @import("core/alloc_trace.zig");
const atom = @import("core/atom.zig");
const class = @import("core/class.zig");
const gc = @import("core/gc.zig");
const gc_driver = @import("core/gc_driver.zig");
const host_function = @import("core/host_function.zig");
const native_entry = @import("core/native_entry.zig");
const job_mod = @import("core/jobs.zig");
const module = @import("core/module.zig");
const object_mod = @import("core/object.zig");
const shape = @import("core/shape.zig");
const string = @import("core/string.zig");
const unicode = @import("libs/unicode.zig");
const var_ref_mod = @import("core/var_ref.zig");
const JSValue = @import("core/value.zig").JSValue;
const Object = object_mod.Object;
const profile = @import("core/profile.zig");
const property = @import("core/property.zig");
const context_mod = @import("core/context.zig");
const context_registry = @import("core/context_registry.zig");
const errors = @import("core/errors.zig");

pub const default_stack_size = 1024 * 1024;
pub const default_gc_threshold = 256 * 1024;
/// Current thread's call-stack budget for the recursion guard, matching QuickJS
/// `JS_DEFAULT_STACK_SIZE` (quickjs.h). The guard trips once this many
/// bytes of native stack have been consumed below the outermost eval frame,
/// turning pathological recursion (parser/JSON tens of thousands deep) into a
/// catchable error. 1 MiB leaves ample headroom under the real thread stack
/// (the main thread has only a few MiB free below the eval entry after the CLI
/// call chain; worker threads have ~16 MiB) while sitting far above any
/// legitimate nesting depth — the same value QuickJS uses for conformance runs.
pub const default_native_stack_size = 1024 * 1024;
// Debug codegen has materially larger parser/VM frames. Scale the physical
// allowance so it represents the same logical recursion budget as optimized
// builds; Release modes retain QuickJS's exact 1 MiB native budget.
const initial_native_stack_size = if (builtin.mode == .Debug)
    default_native_stack_size * 4
else
    default_native_stack_size;

pub const InterruptHandler = *const fn (*JSRuntime, ?*anyopaque) bool;

/// Runtime-wide dynamic-import loader authority. A Runtime can execute many
/// Realms; the active Realm is supplied to the callback at invocation time.
pub const DynamicImportLoader = struct {
    callback: ?context_mod.DynamicImportCallback = null,
    userdata: ?*anyopaque = null,
};

/// Scoped loader override. Scopes are intended to be restored in LIFO order;
/// `restore`/`deinit` are idempotent so error-path defers are safe.
pub const DynamicImportLoaderScope = struct {
    runtime: *JSRuntime,
    previous: DynamicImportLoader,
    active: bool = true,

    pub fn restore(self: *DynamicImportLoaderScope) void {
        if (!self.active) return;
        self.runtime.assertOwnerThread();
        self.runtime.dynamic_import_loader = self.previous;
        self.active = false;
    }

    pub fn deinit(self: *DynamicImportLoaderScope) void {
        self.restore();
    }
};

/// Installs the standard ECMAScript global object (every builtin constructor,
/// prototype, namespace, and the `rt.internal_builtins` record table) onto a
/// freshly-created global `Object`. The implementation lives in
/// `exec/standard_globals.zig`; core only holds the function pointer so
/// bootstrap can run without a core -> exec dependency.
/// This is the engine bootstrap seam: exec's context/realm initialization calls
/// the runtime's installer through this neutral interface.
pub const StandardGlobalsInstaller = *const fn (ctx: *context_mod.JSContext, global: *Object) anyerror!void;

/// Internal implementation seam installed once, from the `engine_hooks`
/// module, when the runtime is created. Hosts do not supply or replace it.
pub const EngineHooks = struct {
    install_standard_globals: StandardGlobalsInstaller,
    standard_global_own_property_capacity: usize,
    materialize_builtin_namespace: *const fn (*JSRuntime, *Object, property.AutoInitKind) anyerror!?JSValue,
    materialize_context_global: *const fn (*context_mod.JSContext) anyerror!*Object,
    internal_builtins: []const native_entry.EntryTable,
    run_microtask: *const fn (*JSRuntime) errors.HostError!job_mod.RunOneStatus,
};

/// Operand-stack limit and current backing ownership in one machine word.
/// Runtime caches the frame-window template; each Stack copies it and changes
/// ownership when installing resident storage or growing onto its own heap buffer.
pub const VmStackStorage = packed struct(u64) {
    pub const Ownership = enum(u2) {
        /// Stack releases this allocation.
        owned = 0,
        /// Borrowed from an arena chunk or a Frame-owned heap slab.
        frame_window = 1,
        /// Borrowed from a suspended execution's resident storage.
        resident_window = 2,
    };

    limit: u62,
    ownership: Ownership = .owned,

    pub fn forLimit(limit: usize) VmStackStorage {
        return .{ .limit = @intCast(@min(limit, std.math.maxInt(u62))) };
    }

    pub fn frameWindowForLimit(limit: usize) VmStackStorage {
        var storage = forLimit(limit);
        storage.ownership = .frame_window;
        return storage;
    }
};

/// Contiguous VM value-stack arena mirroring QuickJS's `alloca`-based
/// `JS_CallInternal` frame layout. Call frames carve LIFO windows for
/// `[args | locals | operand stack]` instead of per-call heap allocations.
/// Windows are stable for their lifetime (chunks never move); release is a
/// watermark restore. Frames manage the live values and all escaping references; their teardown
/// must finish before the watermark is restored. The arena manages storage only.
pub const VmStackArena = struct {
    pub const first_chunk_bytes: usize = 4 * 1024;
    pub const first_chunk_slots: usize = first_chunk_bytes / @sizeOf(JSValue);
    pub const chunk_slots: usize = 32 * 1024;
    pub const max_chunks: usize = 64;

    comptime {
        std.debug.assert(first_chunk_bytes % @sizeOf(JSValue) == 0);
        std.debug.assert(first_chunk_slots <= chunk_slots);
    }

    pub const Mark = struct {
        chunk: usize,
        used: usize,
    };

    pub const ActiveCarve = struct {
        mark: Mark,
        window: []JSValue,
    };

    // `active` selects the corresponding entries in `used` and `chunks`;
    // `chunk_count` bounds the active chunk index.
    chunk_count: usize = 0,
    active: usize = 0,
    used: [max_chunks]usize = @splat(0),
    chunks: [max_chunks][]JSValue = @splat(&.{}),

    /// `VmStackArena{}` is zeros plus 64 empty slices whose pointer is
    /// `@alignOf(JSValue)` (Zig `&.{}`), not null. Copying that typed default
    /// materializes a 1552-byte `.rodata` template. Zero the struct, then store
    /// the empty slices so every field still equals `VmStackArena{}`.
    pub fn initDefault(self: *VmStackArena) void {
        self.* = std.mem.zeroes(VmStackArena);
        const empty: []JSValue = &.{};
        for (&self.chunks) |*chunk| {
            chunk.* = empty;
        }
    }

    pub fn mark(self: *const VmStackArena) Mark {
        return .{ .chunk = self.active, .used = if (self.chunk_count == 0) 0 else self.used[self.active] };
    }

    /// Carve `n` slots from the arena. Returns null when the request cannot
    /// be served (oversized window or arena exhausted); callers fall back to
    /// heap storage.
    pub fn carve(self: *VmStackArena, rt: *JSRuntime, n: usize) ?[]JSValue {
        if (n == 0) return self.chunks[0][0..0];
        if (n > chunk_slots) return null;
        if (self.chunk_count != 0) {
            const active = self.active;
            const used = self.used[active];
            const capacity = self.chunks[active].len;
            std.debug.assert(used <= capacity);
            if (capacity - used >= n) {
                self.used[active] = used + n;
                return self.chunks[active][used .. used + n];
            }
        }
        return self.carveSlow(rt, n);
    }

    /// Allocation-free carve from the current chunk only, returning both the
    /// original watermark and the carved window from one state snapshot.
    /// Same-Machine hot frame constructors use this after their Entry storage
    /// is warm; a miss leaves the arena unchanged so the authoritative `carve`
    /// path can switch or allocate a chunk and preserve heap/OOM semantics.
    pub inline fn carveActiveMarked(self: *VmStackArena, n: usize) ?ActiveCarve {
        if (n == 0 or self.chunk_count == 0) return null;
        const active = self.active;
        const used = self.used[active];
        const capacity = self.chunks[active].len;
        std.debug.assert(used <= capacity);
        // The active chunk's actual length is authoritative: the compact
        // first chunk is 4 KiB, while every later chunk has chunk_slots.
        // Keeping one capacity predicate also rejects oversized warm carves
        // without duplicating the arena-wide maximum check.
        if (capacity - used < n) return null;
        self.used[active] = used + n;
        return .{
            .mark = .{ .chunk = active, .used = used },
            .window = self.chunks[active][used .. used + n],
        };
    }

    /// Switch to or allocate another arena chunk.  The active chunk satisfies
    /// virtually every ordinary call after the first one; keeping backing
    /// allocation and its memory-accounting/error machinery out of `carve`
    /// lets that steady arm remain a leaf, like QJS's `alloca` bump.
    noinline fn carveSlow(self: *VmStackArena, rt: *JSRuntime, n: usize) ?[]JSValue {
        const next_index = if (self.chunk_count == 0) 0 else self.active + 1;
        if (next_index >= max_chunks) return null;
        if (next_index >= self.chunk_count) {
            // Ordinary first-entry frames need only one 4 KiB page. A large
            // first request and every later chunk retain the 32K-slot ceiling
            // so deep or unusually wide calls do not turn into incremental
            // chunk churn. Publish no arena state until allocation succeeds.
            const allocation_slots = if (next_index == 0 and n <= first_chunk_slots)
                first_chunk_slots
            else
                chunk_slots;
            const chunk = rt.allocRuntime(JSValue, allocation_slots) catch return null;
            self.chunks[next_index] = chunk;
            self.chunk_count = next_index + 1;
        }
        std.debug.assert(n <= self.chunks[next_index].len);
        self.active = next_index;
        self.used[next_index] = n;
        return self.chunks[next_index][0..n];
    }

    pub fn carveTyped(self: *VmStackArena, rt: *JSRuntime, comptime T: type, n: usize) ?[]T {
        if (n == 0) return &.{};
        if (@alignOf(T) > @alignOf(JSValue)) return null;
        const byte_count = std.math.mul(usize, @sizeOf(T), n) catch return null;
        const slot_count = std.math.divCeil(usize, byte_count, @sizeOf(JSValue)) catch return null;
        const value_window = self.carve(rt, slot_count) orelse return null;
        const bytes = std.mem.sliceAsBytes(value_window);
        return std.mem.bytesAsSlice(T, bytes[0..byte_count]);
    }

    /// Restore a watermark in LIFO order after frame/stack teardown has
    /// retired the views and preserved any escaping values. Keeps chunks for reuse.
    pub fn restore(self: *VmStackArena, m: Mark) void {
        if (self.chunk_count == 0) return;
        var index = m.chunk + 1;
        while (index <= self.active) : (index += 1) self.used[index] = 0;
        self.active = m.chunk;
        self.used[m.chunk] = m.used;
    }

    pub fn deinit(self: *VmStackArena, allocator: std.mem.Allocator) void {
        for (self.chunks[0..self.chunk_count]) |chunk| {
            if (chunk.len != 0) allocator.free(chunk);
        }
        self.initDefault();
    }
};

pub const MicrotaskPolicy = job_mod.Policy;
pub const MicrotaskScope = job_mod.Scope;
pub const MicrotaskExceptionHandler = job_mod.ExceptionHandler;

pub const RuntimeOptions = struct {
    allocator: std.mem.Allocator = std.heap.c_allocator,
    microtask_policy: MicrotaskPolicy = .auto,
    trace_writer: ?*std.Io.Writer = null,
    memory_limit: ?usize = null,
    /// Initial collection threshold; collections adjust the next threshold.
    gc_threshold: usize = default_gc_threshold,
    gc_policy: gc.Policy = .{},
    stack_size: usize = default_stack_size,
    native_stack_size: usize = initial_native_stack_size,
    interrupt_handler: ?InterruptHandler = null,
    interrupt_context: ?*anyopaque = null,
    can_block: bool = false,
};

pub const Options = RuntimeOptions;

pub const MemoryUsage = struct {
    /// Native allocation counters are unavailable when diagnostic instrumentation is off.
    allocation_tracking_enabled: bool = alloc_trace.enabled,
    heap_bytes: usize = 0,
    memory_limit: ?usize,
    allocated_bytes: usize,
    allocation_count: usize,
    peak_allocated_bytes: usize,
    peak_allocation_count: usize,
    alloc_calls: usize,
    free_calls: usize,
    create_calls: usize,
    destroy_calls: usize,
    atom_count: usize,
    /// Bytes of dynamic atom names. Predefined atoms are not copied here.
    atom_bytes: usize,
    registered_class_count: usize,
    class_record_count: usize,
};

pub const ValueRootSlice = union(enum) {
    mutable: *const []JSValue,
    /// Borrowed values whose backing storage is stable for the root frame's
    /// lifetime. The visitor traces copies and never mutates caller-owned
    /// slots; useful when a resident frame will take its own copy before the
    /// call returns.
    borrowed: []const JSValue,
    /// A register-resident operand window. `values` supplies the stack buffer
    /// pointer (so reallocations made by delegated handlers are visible), while
    /// `live_len` points at the dispatcher's register-resident operand depth.
    /// The GC traces `values.*.ptr[0..live_len.*]`, mirroring QuickJS scanning
    /// `[stack_buf, cur_sp)` without making the slice header the hot-path
    /// operand-depth authority.
    windowed: struct { values: *const []JSValue, live_len: *const usize },
    /// A slot-typed var-ref cell slice under construction (`JSVarRef **` form,
    /// VARREFS-SLOT-TYPING-BLUEPRINT phase D). Traced per cell through the
    /// cell's JSValue view — bit-identical to the pre-typed rooting of the
    /// same cells stored as JSValues.
    cells: *const []*var_ref_mod.VarRef,
    /// Borrowed counterpart of `cells`; keeps the referenced cell/value graph
    /// live without taking temporary per-cell references.
    borrowed_cells: []const *var_ref_mod.VarRef,
};

pub const ValueRootBuffer = roots_mod.ValueRootBuffer;

/// Native copy of a typed var-ref cell slice. Unlike ValueRootBuffer, this
/// storage requires an explicitly activated ValueRootFrame to keep cells live.
pub const CellRootBuffer = struct {
    cells: []*var_ref_mod.VarRef = &.{},

    pub fn initCopy(rt: *JSRuntime, source: []const *var_ref_mod.VarRef) !CellRootBuffer {
        if (source.len == 0) return .{};
        const cells = try mem_ops.alloc(rt, *var_ref_mod.VarRef, source.len);
        for (source, 0..) |cell, idx| cells[idx] = cell;
        return .{ .cells = cells };
    }

    pub fn deinit(self: *CellRootBuffer, rt: *JSRuntime) void {
        const cells = self.cells;
        self.cells = &.{};
        if (cells.len != 0) mem_ops.free(rt, *var_ref_mod.VarRef, cells);
    }

    pub fn slice(self: *CellRootBuffer) ValueRootSlice {
        return .{ .cells = &self.cells };
    }
};

/// A GC header (Shape, Module, VarRef, FunctionBytecode, realm) named as a
/// root for a mutation or construction window. Tracing does not treat a Zig
/// `*Shape` local as a root unless it is named here.
pub const HeaderRootValue = struct {
    header: *gc.Header,
};

/// TGC S3 §4 class B: an atom id held by a native frame.
///
/// An `atom.Atom` is a bare `u32`. Neither a `*JSValue` (there is no
/// JSValue) nor the conservative stack scan (an integer is not a pointer into
/// the heap) can report it, so a native frame that holds an id across a point
/// where JS can run or the allocator can collect must name it here.
pub const AtomRootSlot = union(enum) {
    /// One `atom.Atom` local, read through its address so a re-assignment
    /// inside the window is visible to the tracer.
    single: *const atom.Atom,
    /// A native `[]Atom` array under construction. The pointer is to the
    /// slice header, not to its bytes, so `appendOwnedAtom`-style reallocation
    /// mid-build stays covered and the partially filled array is traced at its
    /// current length.
    list: *const []atom.Atom,
};

/// Precise ValueRootFrame linking. Always on: tests need it because they have
/// no conservative scanner, and the CLI links container/window frames
/// (design §7.1).
pub const value_root_frames_enabled = true;

/// Production (non-test) does not list-link scalar Zig locals; those wait for
/// conservative stack/register capture. Tests link every activate.
pub const value_root_link_containers_only = !builtin.is_test;

/// Scalar scope helpers exist only when scalar frames can actually be linked.
/// In production tracing builds the policy above rejects them, so keeping their
/// storage and frame would preserve stack/TLS work without adding a root.
const value_root_scalar_scopes_enabled = value_root_frames_enabled and !value_root_link_containers_only;

pub const ValueRootFrameStats = struct {
    activate_calls: usize = 0,
    linked: usize = 0,
    container_linked: usize = 0,
    scalar_linked: usize = 0,

    pub fn reset(self: *@This()) void {
        self.* = .{};
    }
};

/// Test-only observer counters. Production builds do not maintain them, even
/// when container/window frames are linked by the tracing collector.
pub threadlocal var value_root_frame_stats: ValueRootFrameStats = .{};

pub const ValueRootFrame = struct {
    previous: ?*const ValueRootFrame = null,
    slices: []const ValueRootSlice = &.{},
    values: []const *JSValue = &.{},
    objects: []const *?*Object = &.{},
    headers: if (value_root_frames_enabled) []const HeaderRootValue else void =
        if (value_root_frames_enabled) &.{} else {},
    /// TGC S3 §4 class B atom-id roots; see `AtomRootSlot`.
    atoms: if (value_root_frames_enabled) []const AtomRootSlot else void =
        if (value_root_frames_enabled) &.{} else {},

    /// True when this frame roots a native JSValue/cell array or window.
    /// Conservative scanning of the C stack sees the backing pointer, not the
    /// values stored behind it, so these must stay precise-rooted. Scalar
    /// `.values` / `.objects` slots that point at Zig locals can wait for a
    /// register/stack scanner (design §7.1).
    ///
    /// Heap-backed `.values` arrays (`RootedValueCopies`, 3 call sites) stay on
    /// `.values`. They are not a root gap: that helper builds one
    /// `*JSValue` per element, so every value already has its own exact
    /// root pointer and `traceValueRootFrames` visits each one. `.slices`
    /// would describe the same window in one descriptor instead of N pointers
    /// — an efficiency change, not a correctness one — and it moves production
    /// codegen, so it stays unconverted until something needs the density.
    pub inline fn hasNativeWindow(self: *const ValueRootFrame) bool {
        return self.slices.len != 0;
    }

    /// Atom ids can never be recovered by the conservative scanner, so a
    /// frame naming any must link even in the container-only production
    /// policy that drops scalar JSValue frames.
    pub inline fn hasAtomRoots(self: *const ValueRootFrame) bool {
        if (comptime !value_root_frames_enabled) return false;
        return self.atoms.len != 0;
    }

    /// Activate this frame at its final stack address. The matching
    /// `deactivate` must run before the frame or any referenced root storage
    /// leaves scope. Default `rc` production erases both operations at
    /// compile time. Shadow CLI skips scalar frames; tests link every frame.
    pub inline fn activate(self: *ValueRootFrame, rt: *JSRuntime) void {
        if (comptime value_root_frames_enabled) {
            const container = self.hasNativeWindow();
            if (comptime builtin.is_test) value_root_frame_stats.activate_calls += 1;
            if (comptime value_root_link_containers_only) {
                if (!container and !self.hasAtomRoots()) {
                    return;
                }
            }
            std.debug.assert(rt.active_value_roots != self);
            self.previous = rt.active_value_roots;
            rt.active_value_roots = self;
            if (comptime builtin.is_test) {
                value_root_frame_stats.linked += 1;
                if (container) {
                    value_root_frame_stats.container_linked += 1;
                } else {
                    value_root_frame_stats.scalar_linked += 1;
                }
            }
        }
    }

    /// Restore the frame that was active before `activate`. Root frames are a
    /// strict LIFO stack; the assertion localizes mismatched scope teardown at
    /// the registration seam. Shadow CLI may skip scalar activates, so a
    /// skipped frame is not the current head and deactivate is a no-op.
    pub inline fn deactivate(self: *ValueRootFrame, rt: *JSRuntime) void {
        if (comptime value_root_frames_enabled) {
            if (comptime value_root_link_containers_only) {
                if (rt.active_value_roots != self) return;
            } else {
                std.debug.assert(rt.active_value_roots == self);
            }
            rt.active_value_roots = self.previous;
            self.previous = null;
        }
    }
};

/// A `ValueRootFrame` plus the storage it points at, held in one local.
///
/// The manual spelling of this — declare a `[_]*JSValue` array, declare
/// a frame whose `.values` points at it, activate, defer deactivate — was
/// written out at every rooting site in the tree. `rootValues` collapses the
/// declarations, leaving the two operations that carry meaning:
///
///     var roots = core.runtime.rootValues(.{ &receiver, &argument });
///     roots.activate(rt);
///     defer roots.deactivate(rt);
///
/// Activation stays a separate step on purpose. The frame links itself into
/// the runtime BY ADDRESS, so it must be linked once it sits in its final
/// stack slot — not in the temporary a returning constructor builds it in.
pub fn ValueRootScope(comptime count: usize) type {
    return struct {
        const Self = @This();

        storage: if (value_root_scalar_scopes_enabled) [count]*JSValue else void =
            if (value_root_scalar_scopes_enabled) undefined else {},
        frame: if (value_root_scalar_scopes_enabled) ValueRootFrame else void =
            if (value_root_scalar_scopes_enabled) .{} else {},

        /// Point the frame at this scope's own storage, then link it. The
        /// slice is taken here rather than in `rootValues` for the same
        /// reason the link is: `storage` only has its final address now.
        pub inline fn activate(self: *Self, rt: *JSRuntime) void {
            if (comptime value_root_scalar_scopes_enabled) {
                self.frame.values = &self.storage;
                self.frame.activate(rt);
            }
        }

        pub inline fn deactivate(self: *Self, rt: *JSRuntime) void {
            if (comptime value_root_scalar_scopes_enabled) self.frame.deactivate(rt);
        }
    };
}

/// Build an inactive `ValueRootScope` over `slots`, a tuple of `*JSValue`.
/// The caller activates it; see `ValueRootScope`.
pub inline fn rootValues(slots: anytype) ValueRootScope(slots.len) {
    if (comptime value_root_scalar_scopes_enabled) {
        var scope: ValueRootScope(slots.len) = .{};
        inline for (slots, 0..) |slot, index| scope.storage[index] = slot;
        return scope;
    }
    return .{};
}

/// A `ValueRootFrame` over `*?*Object` slots, same activate discipline as
/// `rootValues`. Tracing does not treat a Zig `*Object` local as a root
/// unless it is named here.
pub fn ObjectRootScope(comptime count: usize) type {
    return struct {
        const Self = @This();

        storage: if (value_root_scalar_scopes_enabled) [count]*?*Object else void =
            if (value_root_scalar_scopes_enabled) undefined else {},
        frame: if (value_root_scalar_scopes_enabled) ValueRootFrame else void =
            if (value_root_scalar_scopes_enabled) .{} else {},

        pub inline fn activate(self: *Self, rt: *JSRuntime) void {
            if (comptime value_root_scalar_scopes_enabled) {
                self.frame.objects = &self.storage;
                self.frame.activate(rt);
            }
        }

        pub inline fn deactivate(self: *Self, rt: *JSRuntime) void {
            if (comptime value_root_scalar_scopes_enabled) self.frame.deactivate(rt);
        }
    };
}

pub inline fn rootObjects(slots: anytype) ObjectRootScope(slots.len) {
    if (comptime value_root_scalar_scopes_enabled) {
        var scope: ObjectRootScope(slots.len) = .{};
        inline for (slots, 0..) |slot, index| scope.storage[index] = slot;
        return scope;
    }
    return .{};
}

comptime {
    if (!value_root_scalar_scopes_enabled) {
        if (@sizeOf(ValueRootScope(1)) != 0) @compileError("disabled ValueRootScope must stay zero-sized");
        if (@sizeOf(ObjectRootScope(1)) != 0) @compileError("disabled ObjectRootScope must stay zero-sized");
    }
}

/// A `ValueRootFrame` carrying only `AtomRootSlot` storage, with the same
/// declare/activate/deactivate discipline as `rootValues` (TGC S3 §4 class B).
///
///     var atom_roots = core.runtime.rootAtoms(.{&key});
///     atom_roots.activate(rt);
///     defer atom_roots.deactivate(rt);
///
/// Unlike `ValueRootScope`, this is never compiled out by
/// `value_root_link_containers_only`: the conservative scanner cannot stand in
/// for it, so dropping the frame in production would drop the root itself.
pub fn AtomRootScope(comptime count: usize) type {
    return struct {
        const Self = @This();

        storage: if (value_root_frames_enabled) [count]AtomRootSlot else void =
            if (value_root_frames_enabled) undefined else {},
        frame: if (value_root_frames_enabled) ValueRootFrame else void =
            if (value_root_frames_enabled) .{} else {},

        /// Bind the frame to this scope's storage at its final stack address,
        /// then link it — same reason as `ValueRootScope.activate`.
        pub inline fn activate(self: *Self, rt: *JSRuntime) void {
            if (comptime value_root_frames_enabled) {
                self.frame.atoms = &self.storage;
                self.frame.activate(rt);
            }
        }

        pub inline fn deactivate(self: *Self, rt: *JSRuntime) void {
            if (comptime value_root_frames_enabled) self.frame.deactivate(rt);
        }
    };
}

/// Build an inactive `AtomRootScope` over `slots`, a tuple of `*const Atom`
/// (or `*Atom`). The caller activates it; see `AtomRootScope`.
pub inline fn rootAtoms(slots: anytype) AtomRootScope(slots.len) {
    if (comptime value_root_frames_enabled) {
        var scope: AtomRootScope(slots.len) = .{};
        inline for (slots, 0..) |slot, index| scope.storage[index] = .{ .single = slot };
        return scope;
    }
    return .{};
}

/// Root a native `[]Atom` array through its slice header, so appends and the
/// reallocations they cause stay covered for the whole build window.
pub inline fn rootAtomList(list: *const []atom.Atom) AtomRootScope(1) {
    if (comptime value_root_frames_enabled) {
        var scope: AtomRootScope(1) = .{};
        scope.storage[0] = .{ .list = list };
        return scope;
    }
    return .{};
}

/// Root several `[]Atom` arrays (and/or single ids) with one frame.
pub inline fn rootAtomSlots(slots: anytype) AtomRootScope(slots.len) {
    if (comptime value_root_frames_enabled) {
        var scope: AtomRootScope(slots.len) = .{};
        inline for (slots, 0..) |slot, index| scope.storage[index] = slot;
        return scope;
    }
    return .{};
}

pub const RootTraceError = std.mem.Allocator.Error || error{PayloadMarkFailed};

pub const RootVisitor = struct {
    context: *anyopaque,
    visit_value: *const fn (context: *anyopaque, slot: *JSValue) RootTraceError!void,
    visit_object: *const fn (context: *anyopaque, slot: *?*Object) RootTraceError!void,
    /// Direct GC headers (Shape, Module, VarRef, FunctionBytecode, realm).
    /// Void in default `rc` so RootVisitor constructions stay two callbacks.
    visit_header: if (value_root_frames_enabled)
        ?*const fn (context: *anyopaque, header: *const gc.Header) RootTraceError!void
    else
        void = if (value_root_frames_enabled) null else {},
    /// TGC S3 §2.2. Atom ids are bare `u32`s, so a root holding one has no
    /// value or header to report; this is the third callback and it is
    /// optional so the 17 existing `RootVisitor` constructions stay untouched.
    visit_atom: if (value_root_frames_enabled)
        ?*const fn (context: *anyopaque, id: atom.Atom) RootTraceError!void
    else
        void = if (value_root_frames_enabled) null else {},

    pub fn value(self: *RootVisitor, slot: *JSValue) RootTraceError!void {
        try self.visit_value(self.context, slot);
    }

    pub fn values(self: *RootVisitor, slots: []JSValue) RootTraceError!void {
        for (slots) |*slot| try self.value(slot);
    }

    pub fn constValue(self: *RootVisitor, stored: JSValue) RootTraceError!void {
        var slot = stored;
        try self.value(&slot);
    }

    /// A cache slot that holds a bare `*String` rather than a `JSValue`.
    ///
    /// The round trip through a `JSValue` is what makes it a real slot: a
    /// visitor that relocates the body writes the new address back into the
    /// value, and this stores it. Passing the pointer by value instead
    /// (`constValue`) leaves the cache naming the old address, which is a
    /// dangling read the moment anything moves.
    pub fn stringSlot(self: *RootVisitor, slot: *?*string.String) RootTraceError!void {
        const stored = slot.* orelse return;
        var boxed = JSValue.string(stored.header());
        try self.value(&boxed);
        slot.* = boxed.asStringBodyRaw();
    }

    /// Same contract for a slot whose `*String` sits inside a cache record.
    pub fn stringField(self: *RootVisitor, slot: *(*string.String)) RootTraceError!void {
        var boxed = JSValue.string(slot.*.header());
        try self.value(&boxed);
        if (boxed.asStringBodyRaw()) |moved| slot.* = moved;
    }

    pub fn constValues(self: *RootVisitor, stored: []const JSValue) RootTraceError!void {
        for (stored) |stored_value| try self.constValue(stored_value);
    }

    pub fn optionalObject(self: *RootVisitor, slot: *?*Object) RootTraceError!void {
        try self.visit_object(self.context, slot);
    }

    pub fn constOptionalObject(self: *RootVisitor, stored: ?*Object) RootTraceError!void {
        var slot = stored;
        try self.optionalObject(&slot);
    }

    pub fn constHeader(self: *RootVisitor, header: *const gc.Header) RootTraceError!void {
        if (comptime value_root_frames_enabled) {
            const callback = self.visit_header orelse return;
            try callback(self.context, header);
        }
    }

    /// No-op unless the visitor is a tracer that owns atom liveness.
    pub fn atomRoot(self: *RootVisitor, id: atom.Atom) RootTraceError!void {
        if (comptime value_root_frames_enabled) {
            const callback = self.visit_atom orelse return;
            try callback(self.context, id);
        }
    }

    pub fn shapeRoot(self: *RootVisitor, stored: *shape.Shape) RootTraceError!void {
        try self.constHeader(&stored.header);
    }

    pub fn moduleRoot(self: *RootVisitor, stored: *module.ModuleRecord) RootTraceError!void {
        try self.constHeader(&stored.header);
    }
};

/// Stack-local root for a Job after it has left `job_queue` and before its
/// payload is released. The FIFO already owns the canonical edge walk in
/// `Job.traceRoots`; this record only keeps that same walk published while
/// exec runs the dequeued entry.
///
/// The chain is thread-local rather than a JSRuntime field: jobs execute on
/// their Runtime's owner thread, nested drains must be LIFO, and default RC
/// must not grow JSRuntime for a tracing-only root seam. A nested drain for a
/// different Runtime is harmless; tracing filters each record by its typed
/// Runtime pointer.
pub const active_job_roots_enabled = value_root_frames_enabled;

pub const ActiveJobRoot = struct {
    previous: if (active_job_roots_enabled) ?*const ActiveJobRoot else void =
        if (active_job_roots_enabled) null else {},
    runtime: if (active_job_roots_enabled) *JSRuntime else void =
        if (active_job_roots_enabled) undefined else {},
    job: if (active_job_roots_enabled) *job_mod.Job else void =
        if (active_job_roots_enabled) undefined else {},

    pub inline fn activate(self: *ActiveJobRoot, rt: *JSRuntime, job: *job_mod.Job) void {
        if (comptime active_job_roots_enabled) {
            rt.assertOwnerThread();
            std.debug.assert(job.runtime == rt);
            std.debug.assert(active_job_root_head != self);
            self.previous = active_job_root_head;
            self.runtime = rt;
            self.job = job;
            active_job_root_head = self;
        }
    }

    pub inline fn deactivate(self: *ActiveJobRoot, rt: *JSRuntime) void {
        if (comptime active_job_roots_enabled) {
            rt.assertOwnerThread();
            std.debug.assert(self.runtime == rt);
            std.debug.assert(active_job_root_head == self);
            active_job_root_head = self.previous;
            self.previous = null;
            self.runtime = undefined;
            self.job = undefined;
        }
    }
};

threadlocal var active_job_root_head: if (active_job_roots_enabled) ?*const ActiveJobRoot else void =
    if (active_job_roots_enabled) null else {};

comptime {
    if (active_job_roots_enabled) {
        std.debug.assert(@sizeOf(ActiveJobRoot) == 3 * @sizeOf(usize));
    } else {
        std.debug.assert(@sizeOf(ActiveJobRoot) == 0);
    }
}

/// First word of the exec-owned `active_invocation` record (design §7.1).
/// Core only knows this prefix; the rest of the record is exec-private.
/// Exec fills `traceRoots` with a no-fail live-window walk. Default `rc`
/// erases the call at comptime so production `.text` stays identical.
pub const ActiveInvocationTrace = struct {
    traceRoots: *const fn (invocation: *anyopaque, visitor: *RootVisitor) RootTraceError!void,
};

/// Exec-owned snapshot of the process-global Atomics.waitAsync waiter
/// registry (design §7.1). Core calls this from `traceActiveRoots` when
/// `value_root_frames_enabled`. Default `rc` stores `void`. Exec retains
/// Promise roots under the waiter mutex, unlocks, then visits.
pub const AtomicsWaitAsyncTrace = *const fn (rt: *anyopaque, visitor: *RootVisitor) RootTraceError!void;

pub var trace_atomics_wait_async: if (value_root_frames_enabled)
    ?AtomicsWaitAsyncTrace
else
    void = if (value_root_frames_enabled) null else {};

const deferred_cleanup = @import("core/deferred_cleanup.zig");
const native_bindings = @import("core/native_bindings.zig");
const property_state = @import("core/property_state.zig");
const string_cache = @import("core/string_cache.zig");
const exception_state = @import("core/exception.zig");
const execution = @import("core/execution.zig");
const gc_weak = @import("core/gc_weak.zig");
const roots_mod = @import("core/roots.zig");
pub const RootSet = roots_mod.RootSet;
pub const RootProvider = roots_mod.RootProvider;
pub const RootSlot = roots_mod.RootSlot;
pub const WeakPersistentCallback = roots_mod.WeakPersistentCallback;
pub const WeakRootSlot = roots_mod.WeakRootSlot;
pub const JSValueHandle = roots_mod.JSValueHandle;
pub const LocalHandle = roots_mod.LocalHandle;
pub const HandleScope = roots_mod.HandleScope;
pub const WeakPersistentValue = roots_mod.WeakPersistentValue;
pub const WeakPersistent = roots_mod.WeakPersistent;
pub const NativePin = roots_mod.NativePin;
pub const pinValueForNative = roots_mod.pinValueForNative;
pub const pinHeaderForNative = roots_mod.pinHeaderForNative;

pub const NativeCleanupJob = struct {
    finalizer: host_function.ExternalFinalizer,
    ptr: *anyopaque,

    pub fn run(self: NativeCleanupJob) void {
        self.finalizer(self.ptr);
    }
};

pub const DeferredClassPayloadFinalizer = struct {
    class_id: class.ClassId = class.invalid_class_id,
    generation: u64 = 0,
    finalizer: class.PayloadFinalizer,
    mark: ?class.PayloadMark = null,
    payload: class.Payload = null,
    payload_kind: class.PayloadKind = .none,
    object_identity: usize = 0,

    pub fn run(self: *DeferredClassPayloadFinalizer, rt: *JSRuntime) void {
        defer rt.classes.releaseDeferredPayloadCallbacks(self.class_id, self.generation);
        // Keep the canonical payload slot populated while the callback runs:
        // `active_deferred_class_payload_finalizer` publishes this exact job as
        // a root across callback reentry. Moving it to an unregistered local
        // before the call recreates the dequeue-to-callback root gap the active
        // slot exists to close.
        self.finalizer(@ptrCast(rt), @ptrCast(&self.object_identity), &self.payload);
        object_mod.destroyDetachedClassPayload(rt, self.class_id, self.payload_kind, &self.payload);
    }

    pub fn traceRoots(self: *DeferredClassPayloadFinalizer, rt: *JSRuntime, visitor: *RootVisitor) RootTraceError!void {
        if (self.payload == null) return;
        const mark = self.mark orelse return;
        const PayloadTraceAdaptor = struct {
            root_visitor: *RootVisitor,
            err: ?RootTraceError = null,

            pub fn visitValue(context: *anyopaque, value_ptr: *anyopaque) void {
                const adaptor: *@This() = @ptrCast(@alignCast(context));
                const value: *JSValue = @ptrCast(@alignCast(value_ptr));
                adaptor.root_visitor.value(value) catch |err| {
                    adaptor.err = err;
                };
            }

            pub fn visitObject(context: *anyopaque, object_ptr: *anyopaque) void {
                const adaptor: *@This() = @ptrCast(@alignCast(context));
                const object: *?*Object = @ptrCast(@alignCast(object_ptr));
                adaptor.root_visitor.optionalObject(object) catch |err| {
                    adaptor.err = err;
                };
            }
        };
        var adaptor = PayloadTraceAdaptor{ .root_visitor = visitor };
        var payload_visitor = class.PayloadVisitor{
            .context = @ptrCast(&adaptor),
            .visit_value = PayloadTraceAdaptor.visitValue,
            .visit_object = PayloadTraceAdaptor.visitObject,
        };
        mark(@ptrCast(rt), @ptrCast(&self.object_identity), &self.payload, &payload_visitor);
        if (adaptor.err) |err| return err;
    }
};

pub const CachedIteratorNextEntry = property_state.CachedIteratorNextEntry;

/// A Runtime and every Realm/heap structure owned by it are mutated only by
/// the thread that initialized the Runtime. Process-global facilities with
/// their own synchronization (notably ClassId allocation) are independent of
/// this contract.
pub const RuntimeMutationError = error{WrongRuntimeThread};

/// Test injection between construction stages. `none` is the production path.
/// Each armed stage returns `error.OutOfMemory` after that stage's resources
/// exist, so rollback has something real to release. The flag clears when it
/// fires.
pub const RuntimeConstructionFailpoint = enum(u8) {
    none = 0,
    after_object_cells = 1,
    after_class_table = 2,
    after_shapes = 3,
};

var runtime_construction_failpoint: RuntimeConstructionFailpoint = .none;

pub fn setRuntimeConstructionFailpointForTest(point: RuntimeConstructionFailpoint) void {
    if (comptime !builtin.is_test) return;
    runtime_construction_failpoint = point;
}

fn takeRuntimeConstructionFailure(point: RuntimeConstructionFailpoint) !void {
    if (comptime !builtin.is_test) return;
    if (runtime_construction_failpoint != point) return;
    runtime_construction_failpoint = .none;
    return error.OutOfMemory;
}
pub const RuntimeCollectionError = gc.CollectionError || RuntimeMutationError;

pub const NativeEntryFinalizer = struct {
    ptr: *anyopaque,
    finalize: *const fn (*anyopaque) void,
};

pub const Diagnostics = struct {
    trace: alloc_trace.Sink = .{},
    allocations: memory.AllocationDiagnostics = .{},
    /// Last major's marked-set census. Written only while
    /// `mark_footprint_census` is set.
    mark_footprint: @import("core/gc_trace_stw.zig").MarkFootprint = .{},
};

pub const JSRuntime = struct {
    pub const Options = RuntimeOptions;
    /// Runtime-shared logical call depth, including zero-byte nested entries.
    call_depth: usize = 0,
    /// Limit for both logical depth and accumulated planned VM-frame bytes.
    stack_size: usize = default_stack_size,
    /// Planned bytes for active bytecode frames, including tail-call callers
    /// whose physical Entry storage has been reused.
    active_bytecode_stack_bytes: usize = 0,
    /// Lower bound for the current thread's call stack. Zero disables the
    /// check or means it has not yet been initialized.
    native_stack_limit: usize = 0,
    /// Nesting count for calls admitted through `enterCallDepth`; it bounds
    /// host C-stack recursion independently of inline VM call depth.
    native_call_depth: usize = 0,
    /// Address captured in an outermost JS entry frame, not the OS stack's
    /// allocation start. GC uses it if the OS stack high bound is unavailable.
    native_stack_top: usize = 0,
    /// Configured byte budget for descending below `native_stack_top`.
    native_stack_size: usize = default_native_stack_size,
    /// Head of the stack-local observable backtrace chain. Native calls and
    /// synchronous native fences replace it on entry and restore it on return.
    current_backtrace_frame: ?*context_mod.ActiveBacktraceFrame = null,

    /// Borrowed exec-owned authority for the currently running bytecode
    /// invocation. Core deliberately keeps this opaque: synchronous native
    /// callbacks recover the concrete Machine through exec without creating
    /// a core -> exec import cycle. Routing reads it on every eligible native
    /// callback; this pointer is separate from the stack-accounting state.
    active_invocation: ?*anyopaque = null,
    /// Exec-owned resident execution root for embedder -> JS calls
    /// (`exec/call_site.zig`), created on first use and retired
    /// through `host_invocation_retire` before the destroy invariants run.
    host_invocation: ?*anyopaque = null,
    host_invocation_retire: ?*const fn (*JSRuntime, *anyopaque) void = null,
    /// R-1 small-function-inlining budget: published production bytecode bytes
    /// and bytes consumed by specialized copies. Exec reads these; core only
    /// accounts.
    small_inline_published_bytes: usize = 0,
    small_inline_specialized_bytes: usize = 0,
    small_inline_destroy: ?*const fn (rt: *JSRuntime, fb: *anyopaque) void = null,
    /// TGC S3 §2.2 edge H. The small-inline `CallerState` hangs off a
    /// FunctionBytecode's hot pad and holds atom ids (`callee_name`,
    /// `callee_file`, `apply_forward[].method_atom`); it lives in exec, which
    /// core must not import, so the FB trace reports those ids through this
    /// hook -- the same seam `small_inline_destroy` uses for teardown.
    small_inline_trace_atoms: ?*const fn (
        rt: *JSRuntime,
        fb: *anyopaque,
        ctx: *anyopaque,
        visit: *const fn (ctx: *anyopaque, id: atom.Atom) void,
    ) void = null,
    owner_thread_id: std.Thread.Id,
    /// Allocator that owns this stable Runtime allocation.
    allocator: std.mem.Allocator,
    /// Four-way atom-string cache cursor. Same align-1 slot the old
    /// `compact_state` packed byte occupied, so `vm_stack` stays put.
    recent_atom_string_next: u8 = 0,
    gc: gc.Registry,
    /// Trace sink and mark census. Not part of `gc.Registry`: the footprint
    /// is about 680 bytes and was measured to displace `Registry.barrier_gate`
    /// off `phase`'s pinned front line (offset 16 -> 2432) under auto layout.
    /// The trace sink and optional allocation observations have one owner.
    diagnostics: Diagnostics = .{},
    /// Allocation-debt pacing for object-boundary incremental mark/destruction
    /// assists. Scheduler/callback/idle polls bypass this counter.
    /// Account immediately after the previous major slice. During destruction,
    /// net growth catches backing/storage allocations between safe object
    /// boundaries without polling inside an unpublished backing allocation.
    /// Force a partial destruction slice in route-asserting tests. Absent
    /// from production layout and code; shipped slices always use GC policy.
    atoms: atom.AtomTable,
    classes: class.Table,
    shapes: shape.Registry,
    dynamic_import_loader: DynamicImportLoader = .{},
    auto_init_descriptors: std.ArrayListUnmanaged(*property.AutoInit) = .empty,
    materialize_builtin_namespace_cb: ?*const fn (rt: *JSRuntime, global: *Object, kind: property.AutoInitKind) anyerror!?JSValue = null,
    materialize_context_global_cb: ?*const fn (ctx: *context_mod.JSContext) anyerror!*Object = null,
    /// Immutable engine implementation installed at creation.
    hooks: *const EngineHooks,

    /// QuickJS `context_list`: intrusive membership only.  Realm ownership is
    /// carried by `RealmRef` and the GC header, never by these links.
    context_head: ?*context_mod.JSContext = null,
    context_tail: ?*context_mod.JSContext = null,
    /// Construction-only membership. These realms are deliberately absent
    /// from `context_head` and root-provider traversal until publication.
    constructing_context_head: ?*context_mod.JSContext = null,
    constructing_context_tail: ?*context_mod.JSContext = null,

    borrowed_reference_holders: std.ArrayListUnmanaged(*Object) = .empty,
    weak_reference_holder_head: ?*Object = null,
    weak_reference_holder_tail: ?*Object = null,
    /// Host handles and root providers. Bound to this runtime's final address
    /// by `roots.bindInline` in `initInPlace`.
    roots: roots_mod.RootSet = .{},
    active_value_roots: ?*const ValueRootFrame = null,
    job_queue: job_mod.Queue = undefined,
    microtasks: job_mod.Checkpoint = .{},
    /// WeakRef [[KeptAlive]]. Traced as a root
    /// and cleared at job end.
    weakref_kept_alive: std.ArrayListUnmanaged(JSValue) = .empty, // gc-slot: heap
    /// Test-only root-scan override (`forcePreciseRootScanForTest`). Pacing
    /// MACHINERY tests call the engine-trigger entry points from a quiescent
    /// test frame with dropGcPtr-scrubbed locals; the mode-derived
    /// `.engine_active` policy would conservatively retain their ghosts and
    /// break deterministic reclamation assertions. Production layout is
    /// untouched (void outside test builds).
    test_root_scan_override: if (builtin.is_test) ?gc.RootScan else void =
        if (builtin.is_test) null else {},
    /// Cross-thread, allocation-free wake signal for host completions that
    /// must be consumed on this Runtime's owner thread. Atomics.waitAsync is
    /// the first producer; the signal carries no JS state and is reset only
    /// while the producer registry mutex excludes a lost-wakeup race.
    host_completion_event: std.Io.Event = .unset,
    deferred_native_cleanups: std.ArrayListUnmanaged(NativeCleanupJob) = .empty,
    draining_deferred_native_cleanups: bool = false,
    deferred_native_cleanup_run_count: usize = 0,
    deferred_class_payload_finalizers: std.ArrayListUnmanaged(DeferredClassPayloadFinalizer) = .empty,
    /// Live wrappers whose reentrant plugin finalizer has a reserved queue
    /// slot. Root tracing visits only their declared payload edges: the
    /// wrapper itself may be condemned, but the callback's payload graph must
    /// survive until ownership transfers to the queued job.
    deferred_class_payload_roots: std.ArrayListUnmanaged(*Object) = .empty,
    reserved_deferred_class_payload_finalizer_slots: usize = 0,
    draining_deferred_class_payload_finalizers: bool = false,
    active_deferred_class_payload_finalizer: ?*DeferredClassPayloadFinalizer = null,
    deferred_class_payload_finalizer_run_count: usize = 0,
    borrowed_weak_cleanup_identities: std.ArrayListUnmanaged(usize) = .empty,
    /// O(1) membership companion for `borrowed_weak_cleanup_identities`.
    /// Only even (object) identities are inserted; symbol identities keep
    /// the slice-scan semantics of the identity list.
    borrowed_weak_cleanup_identity_set: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// Weak identity registry: maps object header addresses to monotonically
    /// increasing weak ids and back. Weak slots (WeakRef/WeakMap/WeakSet/
    /// FinalizationRegistry/WeakRootSlot) store `weak_id << 1` instead of the
    /// header address, so a recycled allocation can never alias a stale weak
    /// identity and weak lookups are O(1) instead of a full heap scan.
    /// Register, rollback, and unlink live in `gc_weak.zig`.
    weak_object_ids: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    weak_id_objects: std.AutoHashMapUnmanaged(usize, *Object) = .empty,
    /// TGC S4-c retired the `slots2_payloads` side table: a slots2 object that
    /// attaches a class payload now spills its two inline property entries into
    /// a `.property_storage` cell, which frees the arm word at body+24 to be
    /// the payload slot every other layout already has. This counter stays as
    /// the observable for that (rare) spill.
    next_weak_id: usize = 1,
    borrowed_weak_cleanup_active: bool = false,

    gc_running: bool = false,
    current_exception: JSValue = JSValue.uninitialized(),
    /// QuickJS `current_exception_is_uncatchable`. Interrupt termination owns
    /// a real pending InternalError but bytecode catch markers must not consume
    /// it. Every ordinary throw resets this flag.
    current_exception_uncatchable: bool = false,
    /// Set when the pending exception is the engine's own out-of-memory
    /// InternalError. Allocation failure is deliberately catchable (see
    /// `exception_ops.runtimeErrorInfo`), which means the native seam turns it
    /// into a JS exception and the original `error.OutOfMemory` would otherwise
    /// be lost -- an uncaught OOM would reach the embedder as a plain
    /// `error.JSException`. This flag lets `nativeHostError` restore the
    /// specific error, keeping the other half of that contract: JS may catch
    /// it, but a path with no handler still surfaces `error.OutOfMemory`.
    /// Reset by every ordinary throw, take, and clear, exactly like the
    /// uncatchable flag above.
    current_exception_out_of_memory: bool = false,
    formatting_error_stack: bool = false,
    backtrace_frames: []context_mod.BacktraceFrame = &.{},
    backtrace_capacity: usize = 0,
    active_native_call: ?*const anyopaque = null,
    vm_stack_frame_storage: VmStackStorage = VmStackStorage.frameWindowForLimit(default_stack_size),
    /// Per-runtime VM value-stack arena for bytecode call frames. Its chunk
    /// metadata and the stack-accounting state in `hot` have separate owners.
    vm_stack: VmStackArena align(64) = .{},
    termination_requested: std.atomic.Value(bool) = .init(false),
    interrupt_handler: ?InterruptHandler = null,
    interrupt_context: ?*anyopaque = null,
    can_block: bool = false,
    /// The single-code-unit string table: one shared latin1 body per code
    /// unit `0..255`, created lazily on first request via `singleByteString`
    /// and then never collected. The slot itself is the root
    /// (`traceStringCacheRoots`), so a borrow of the body needs no retain
    /// (ref-counting was deleted in TGC S1-S3) and the whole table is dropped
    /// in `JSRuntime.destroy`.
    ///
    /// Every one-code-unit producer reads it: `charAt` / `at` /
    /// `String.fromCharCode` with one argument / the string iterator /
    /// `s[i]` indexing / a length-1 `slice`. Code units `>= 0x100` still
    /// allocate. Sharing is unobservable because strings are compared by
    /// value and are immutable; latin1 storage means the byte IS the code
    /// unit, so `0x80..0xff` are as exact as the ASCII half.
    ///
    /// Hot paths like `getStringIndexValue` (`hex[i]`-style indexing in
    /// URI decode sweeps) call this thousands of times per
    /// inner iteration; reusing cached instances eliminates two heap
    /// allocations per call.
    single_byte_strings: [256]?*string.String = @splat(null),
    /// Lazy cache for the immutable empty string. This shows up during
    /// standard global setup and in common `String`/JSON paths.
    empty_string: ?*string.String = null,
    /// Single-entry cache for hot two-code-unit strings. URI stress loops
    /// compare `decodeURI("%F0...")` against
    /// `String.fromCharCode(H, L)` for each non-BMP code point; keeping
    /// the most recent pair lets both calls share one immutable string
    /// without retaining the whole sweep.
    recent_two_unit_string: ?string_cache.RecentTwoUnit = null,
    /// Tiny cache for atom-to-string materialization. This catches hot
    /// bytecode constants without retaining every atom string in the program;
    /// regexp literals in particular alternate between source and flags atoms.
    recent_atom_strings: [4]?string_cache.RecentAtom = @splat(null),
    /// Lazy cache for uppercase percent-escaped byte strings (`%00`..`%FF`).
    /// This is a general URI hot-path cache, not a fixture shortcut:
    /// ECMAScript URI helpers and decimal-to-percent harnesses both
    /// repeatedly construct these immutable three-byte strings.
    percent_hex_strings: [256]?*string.String = @splat(null),
    /// Lazy cache for small integer strings ("0".."255").
    small_int_strings: [256]?*string.String = @splat(null),
    /// Error object preallocated while memory is plentiful so the VM catch
    /// machinery can still materialize a catch value when the heap is fully
    /// exhausted (QuickJS's preallocated out-of-memory exception analogue).
    /// Populated by the exec layer at context-global bootstrap.
    performance_time_origin_ms: f64 = 0,
    opcode_profile: ?*profile.OpcodeProfile = null,
    /// NB2 (design §3.1 / §5.5): host-registered `NativeEntry`s. Each is an
    /// individually allocated, address-stable, never-freed-before-teardown
    /// record; the list only exists to free them at `deinit`.
    native_entries: std.ArrayListUnmanaged(*native_entry.NativeEntry) = .empty,
    /// Ownership registrations for entry `state` pointers (run on the
    /// runtime thread at teardown, like external record finalizers).
    native_entry_finalizers: std.ArrayListUnmanaged(NativeEntryFinalizer) = .empty,
    /// Shared dispatch record for external host functions (exec-owned
    /// trampoline, installed with the internal builtin tables). Null until
    /// exec registers it; a function published before that keeps the
    /// record-less host path.
    cached_iterator_next_entries: std.ArrayListUnmanaged(CachedIteratorNextEntry) = .empty,
    /// Static internal-builtin record table, indexed
    /// `[domain][domain-local id]` with the `NativeBuiltinDomain` enum value
    /// as the outer index (slot 0 unused). Built at comptime by
    /// `exec/internal_builtins.zig` and assigned by the standard-global install
    /// path; exec dispatches through
    /// `internalBuiltinRecord` with no compile-time knowledge of individual
    /// builtins. Empty until standard globals are installed, which is also
    /// the only path that creates native function objects carrying these ids.
    internal_builtins: []const native_entry.EntryTable = &.{},
    /// Returns an owned runtime. Caller must release it with `destroy`.
    pub fn create(options: RuntimeOptions) !*JSRuntime {
        const allocator = options.allocator;
        const rt = try allocator.create(JSRuntime);
        rt.diagnostics = .{ .trace = .{ .writer = options.trace_writer } };
        if (comptime alloc_trace.enabled) rt.diagnostics.trace.recordAlloc(@sizeOf(JSRuntime), @intFromPtr(rt));
        errdefer {
            if (comptime alloc_trace.enabled) rt.diagnostics.trace.writeFree(@intFromPtr(rt));
            allocator.destroy(rt);
        }
        try rt.initInPlace(allocator, options);
        return rt;
    }

    fn initInPlace(rt: *JSRuntime, allocator: std.mem.Allocator, options: RuntimeOptions) !void {
        rt.allocator = allocator;
        rt.owner_thread_id = std.Thread.getCurrentId();
        // Imported here, not at file scope: this file is reached while the
        // engine_hooks provider is still resolving the engine module.
        rt.hooks = @import("engine_hooks").get();
        // Undefined and recycled storage ignore struct defaults. Subsystem
        // constructors below do not write the completion event or diagnostics.
        rt.host_completion_event = .unset;
        rt.recent_atom_string_next = 0;
        rt.gc = gc.Registry.init(rt, options.gc_policy);
        rt.gc.heap_budget.gc_threshold = options.gc_threshold;
        rt.gc.heap_budget.limit = options.memory_limit;
        rt.gc.initLists();
        // Only now: the observer stores a pointer into `rt.gc`, so it has to be
        // installed after the registry reaches its stable field address.
        rt.gc.observeSlabArenas(&rt.gc.cell_storage.slab);
        errdefer {
            rt.gc.cell_storage.slab.arena_observer = null;
            rt.gc.rollbackConstruction();
        }
        try rt.gc.serveObjectCells();
        try takeRuntimeConstructionFailure(.after_object_cells);
        rt.atoms = atom.AtomTable.init(rt);
        // TGC S3: the atom table needs the collector to answer "is a major
        // marking?" and "what epoch is it?". `rt` is already at its final
        // address here (the caller allocated it before calling in).
        rt.atoms.owner_runtime = rt;
        rt.atoms.runtime = rt;
        errdefer rt.atoms.deinit();
        // `class.Table.init` deinits its own records before returning the error.
        // Register the class-table errdefer only after that success.
        rt.classes.init(rt) catch |err| return err;
        errdefer rt.classes.deinit();
        try takeRuntimeConstructionFailure(.after_class_table);
        rt.shapes = shape.Registry.init(rt, &rt.atoms, &rt.gc);
        errdefer rt.shapes.deinit();
        try takeRuntimeConstructionFailure(.after_shapes);
        rt.dynamic_import_loader = .{};
        rt.auto_init_descriptors = .empty;
        rt.materialize_builtin_namespace_cb = rt.hooks.materialize_builtin_namespace;
        rt.materialize_context_global_cb = rt.hooks.materialize_context_global;
        rt.small_inline_published_bytes = 0;
        rt.small_inline_specialized_bytes = 0;
        rt.small_inline_destroy = null;
        rt.small_inline_trace_atoms = null;
        rt.context_head = null;
        rt.context_tail = null;
        rt.constructing_context_head = null;
        rt.constructing_context_tail = null;
        rt.borrowed_reference_holders = .empty;
        rt.weak_reference_holder_head = null;
        rt.weak_reference_holder_tail = null;
        rt.roots.bindInline();
        rt.active_value_roots = null;
        rt.job_queue = job_mod.Queue.init(rt);
        rt.microtasks = .{ .policy = options.microtask_policy };
        rt.weakref_kept_alive = .empty;
        if (comptime builtin.is_test) rt.test_root_scan_override = null;
        rt.deferred_native_cleanups = .empty;
        rt.draining_deferred_native_cleanups = false;
        rt.deferred_native_cleanup_run_count = 0;
        rt.deferred_class_payload_finalizers = .empty;
        rt.deferred_class_payload_roots = .empty;
        rt.reserved_deferred_class_payload_finalizer_slots = 0;
        rt.draining_deferred_class_payload_finalizers = false;
        rt.active_deferred_class_payload_finalizer = null;
        rt.deferred_class_payload_finalizer_run_count = 0;
        rt.borrowed_weak_cleanup_identities = .empty;
        rt.borrowed_weak_cleanup_identity_set = .empty;
        rt.weak_object_ids = .empty;
        rt.weak_id_objects = .empty;
        rt.next_weak_id = 1;
        rt.borrowed_weak_cleanup_active = false;
        rt.gc_running = false;
        exception_state.clear(rt);
        rt.call_depth = 0;
        rt.native_call_depth = 0;
        rt.active_bytecode_stack_bytes = 0;
        rt.formatting_error_stack = false;
        rt.backtrace_frames = &.{};
        rt.backtrace_capacity = 0;
        rt.current_backtrace_frame = null;
        rt.active_native_call = null;
        rt.active_invocation = null;
        rt.stack_size = options.stack_size;
        rt.vm_stack_frame_storage = VmStackStorage.frameWindowForLimit(options.stack_size);
        rt.native_stack_size = options.native_stack_size;
        // Arm the native recursion guard at construction, mirroring QuickJS
        // JS_NewRuntime2 -> JS_UpdateStackTop. This covers every
        // entry path (eval / evalScript / ES module graph) even those that do not
        // re-arm; the host creates the runtime and starts execution from the same
        // shallow call level, so this baseline is valid. Outermost eval/module
        // entries additionally re-arm (JS_UpdateStackTop analogue) for a precise
        // per-thread base — required when execution runs on a different thread
        // than construction (conformance worker runtimes).
        rt.native_stack_top = @frameAddress();
        rt.native_stack_limit = if (options.native_stack_size == 0) 0 else rt.native_stack_top -| options.native_stack_size;
        rt.vm_stack.initDefault();
        rt.termination_requested = .init(false);
        rt.interrupt_handler = options.interrupt_handler;
        rt.interrupt_context = options.interrupt_context;
        rt.can_block = options.can_block;
        string_cache.bind(rt);
        rt.performance_time_origin_ms = 0;
        rt.opcode_profile = null;
        rt.native_entries = .empty;
        rt.native_entry_finalizers = .empty;
        rt.cached_iterator_next_entries = .empty;
        rt.internal_builtins = rt.hooks.internal_builtins;
        rt.host_invocation = null;
        rt.host_invocation_retire = null;
        mem_ops.useIndependentSmallObjectSlabArenaBacking(rt);
        mem_ops.enableSmallObjectSlab(rt);
        // Heap-limit retry is one callee on the budget. It stays null until
        // the registry, atoms, and shapes can survive a collection. Per-alloc
        // notify is test/force only; production does not install it.
        rt.gc.heap_budget.retry = JSRuntime.retryHeapLimitOnce;
        rt.gc.heap_budget.retry_ctx = rt;
        if (comptime memory.allocation_gc_trigger_enabled) {
            rt.gc.heap_budget.owner_notify = JSRuntime.triggerGCOnAllocation;
            rt.gc.heap_budget.owner_ctx = rt;
        }
    }

    pub fn setOpcodeProfile(self: *JSRuntime, opcode_profile: ?*profile.OpcodeProfile) void {
        self.opcode_profile = opcode_profile;
        self.diagnostics.trace.profile_alloc_count = if (opcode_profile) |prof| &prof.alloc_count else null;
    }

    pub fn isOwnerThread(self: *const JSRuntime) bool {
        return self.owner_thread_id == std.Thread.getCurrentId();
    }

    pub fn requireOwnerThread(self: *const JSRuntime) RuntimeMutationError!void {
        if (!self.isOwnerThread()) return error.WrongRuntimeThread;
    }

    pub fn assertOwnerThread(self: *const JSRuntime) void {
        if (!self.isOwnerThread()) @panic("JSRuntime mutation from non-owner thread");
    }

    fn deinit(self: *JSRuntime) void {
        self.assertOwnerThread();
        self.assertIdleForTeardown();
        // The resident host invocation (exec/call_site.zig) is only ever
        // published for the duration of a call, so an idle runtime retires it
        // here; a runtime destroyed mid-call fails the assertion above first.
        execution.retireHostInvocation(self);
        self.vm_stack.deinit(self.nativeAllocator());
        execution.releaseStoredBacktrace(self);
        exception_state.clear(self);
        self.clearWeakRefKeptAlive();
        self.job_queue.deinit();
        self.clearPendingFinalizationJobs();
        string_cache.clear(self);
        self.clearExternalHostFunctions();
        self.drainDeferredNativeCleanups();
        self.assertNoOutstandingValueHandles();
        self.drainDeferredNativeCleanups();
        self.drainDeferredClassPayloadFinalizers();
        self.gc.scheduler.host_quiescent = true;
        _ = self.collectForTeardown();
        self.drainDeferredNativeCleanups();
        self.drainDeferredClassPayloadFinalizers();
        self.clearPendingFinalizationJobs();
        _ = self.collectForTeardown();
        self.gc.scheduler.host_quiescent = false;
        self.drainDeferredNativeCleanups();
        self.drainDeferredClassPayloadFinalizers();
        self.clearBorrowedWeakCleanupIdentities();
        self.clearPendingFinalizationJobs();
        // The teardown cycle removals above sweep dead weak payloads, and a
        // FinalizationRegistry cell whose target died enqueues its cleanup
        // callback (`Object.sweepDeadWeakPayloadReferences`). That re-grows the
        // queue's backing block after the `job_queue.deinit()` performed at the
        // top of teardown, and `clearPendingFinalizationJobs` only drains the
        // entries. Release the storage once no enqueue site remains reachable.
        self.job_queue.deinit();
        // Ordinary atom-string caches own an independent string ref and can be
        // released now. Dynamic symbol bodies cannot: their rc also represents
        // property-key atoms held by shapes, which intentionally outlive objects
        // until phase 3 of gc.deinit.
        self.atoms.releaseCachedStrings();
        // The context list is borrowed enumeration, never a teardown owner.
        // Every host create-ref must have been dropped (`JSContext.destroy`)
        // before the Runtime goes; realms still on the list are heap nodes
        // the teardown cycle passes could not prove dead (conservative
        // residue, pinned holders) and `gc.deinit` tears them down with the
        // rest of the graph.
        self.assertNoHostRealmRefsForTeardown();
        self.gc.deinit(self);
        std.debug.assert(self.weak_reference_holder_head == null);
        std.debug.assert(self.weak_reference_holder_tail == null);
        self.drainDeferredNativeCleanups();
        self.drainDeferredClassPayloadFinalizers();
        // Shapes and every other GC-managed atom owner are now gone. Clear
        // residual dynamic symbol bodies (notably Symbol.for's registry ref)
        // before AtomTable.deinit asserts that no materialized bodies remain.
        self.atoms.releaseValueSymbolBodiesAfterGc();
        // These native containers share the Runtime allocator for their entire
        // lifetime; parser scratch is owned separately by each compilation.
        property_state.deinitBorrowedCleanup(self);
        gc_weak.deinitIds(self, self.nativeAllocator());
        property_state.deinitAutoInit(self);
        self.shapes.deinit();
        self.classes.deinit();
        self.atoms.deinit();
        const root_providers = self.roots.takeHeapProviderStorage();
        property_state.deinitBorrowedHolders(self);
        self.roots.deinitSlotLists(self.nativeAllocator());
        property_state.deinitIteratorNext(self);
        self.deferred_native_cleanups.deinit(self.nativeAllocator());
        self.deferred_class_payload_finalizers.deinit(self.nativeAllocator());
        self.deferred_class_payload_roots.deinit(self.nativeAllocator());
        self.reserved_deferred_class_payload_finalizer_slots = 0;
        self.active_deferred_class_payload_finalizer = null;
        if (root_providers.len != 0) mem_ops.free(self, RootProvider, root_providers);
        mem_ops.deinitSmallObjectSlab(self);
        // The Runtime body is owned by `allocator`, outside native allocation instrumentation.
        std.debug.assert(!mem_ops.hasOutstandingAllocations(self));
    }

    pub fn destroy(self: *JSRuntime) void {
        self.assertOwnerThread();
        const allocator = self.allocator;
        self.deinit();
        if (comptime alloc_trace.enabled) self.diagnostics.trace.writeFree(@intFromPtr(self));
        allocator.destroy(self);
    }

    /// Checked teardown entry for hosts that cannot prove their call thread.
    /// On rejection the Runtime is untouched and remains owned by its creator.
    pub fn tryDestroy(self: *JSRuntime) RuntimeMutationError!void {
        try self.requireOwnerThread();
        self.destroy();
    }

    /// Ordinary native allocator. Request bytes, one trace line, and the
    /// optional diagnostic instrumentation. GC cells use explicit typed helpers.
    pub inline fn nativeAllocator(self: *JSRuntime) std.mem.Allocator {
        return memory.nativeAllocator(self);
    }

    /// These runtime allocators reach `mem_ops.*NoTrigger` and therefore
    /// carry the threshold check themselves. QuickJS puts no such check in
    /// `js_malloc_rt` / `js_realloc_rt`: its single
    /// allocation-threshold site is `js_trigger_gc` from `JS_NewObjectFromShape`.
    /// Gate them on the same comptime rule as the test/force notify so both
    /// halves stay in one place — see `memory.allocation_gc_trigger_enabled`.
    const runtime_allocation_requests_gc = memory.allocation_gc_trigger_enabled;

    pub inline fn allocRuntime(self: *JSRuntime, comptime T: type, count: usize) ![]T {
        if (comptime runtime_allocation_requests_gc) {
            if (count != 0) {
                const bytes = std.math.mul(usize, @sizeOf(T), count) catch std.math.maxInt(usize);
                self.requestGCForAllocation(bytes);
            }
        }
        return mem_ops.allocNoTrigger(self, T, count);
    }

    pub inline fn freeRuntime(self: *JSRuntime, comptime T: type, slice: []T) void {
        mem_ops.free(self, T, slice);
    }

    pub inline fn remapRuntime(self: *JSRuntime, comptime T: type, slice: []T, new_count: usize) !?[]T {
        if (comptime runtime_allocation_requests_gc) {
            if (new_count > slice.len) {
                const old_bytes = std.math.mul(usize, @sizeOf(T), slice.len) catch std.math.maxInt(usize);
                const new_bytes = std.math.mul(usize, @sizeOf(T), new_count) catch std.math.maxInt(usize);
                self.requestGCForAllocation(new_bytes -| old_bytes);
            }
        }
        return mem_ops.remap(self, T, slice, new_count);
    }

    pub inline fn createRuntime(self: *JSRuntime, comptime T: type) !*T {
        if (comptime runtime_allocation_requests_gc) self.requestGCForAllocation(@sizeOf(T));
        return mem_ops.createNoTrigger(self, T);
    }

    pub inline fn destroyRuntime(self: *JSRuntime, comptime T: type, ptr: *T) void {
        mem_ops.destroy(self, T, ptr);
    }

    pub inline fn allocRuntimeAlignedBytes(self: *JSRuntime, byte_count: usize, alignment: std.mem.Alignment) ![]u8 {
        if (comptime runtime_allocation_requests_gc) {
            if (byte_count != 0) self.requestGCForAllocation(byte_count);
        }
        return mem_ops.allocAlignedBytesNoTrigger(self, byte_count, alignment);
    }

    pub inline fn freeRuntimeAlignedBytes(self: *JSRuntime, bytes: []u8, alignment: std.mem.Alignment) void {
        mem_ops.freeAlignedBytes(self, bytes, alignment);
    }

    pub fn registerObject(self: *JSRuntime, object: *Object) !void {
        self.assertOwnerThread();
        // qjs add_gc_object only links the header into
        // `lists.objects`; it never re-evaluates the GC threshold. The single
        // object-creation threshold check is js_trigger_gc(sizeof(JSObject))
        // at the top of JS_NewObjectFromShape — mirrored here
        // by collectBeforeObjectAllocation immediately before the object body
        // allocation. Property arrays and separate payloads retain their
        // existing allocRuntime* requests; a crossing they produce stays
        // pending until the next pre-allocation boundary or scheduler poll,
        // exactly like a prop-array js_malloc crossing in qjs
        // waits for the next js_trigger_gc.
        try self.registerObjectWithBytes(object, object.allocationSize(self));
    }

    /// Same as `registerObject` but with the object's allocation size supplied by
    /// the caller. `createInternal` already computes the inline-class-payload
    /// layout to size/place the allocation; reusing its `object_size` here avoids a
    /// second record-table lookup + inline-layout recompute on the object-creation
    /// hot path (mirror of `unregisterObjectWithBytes` on the free path). The
    /// stored value is identical to what `allocationSize` would recompute.
    ///
    /// Thread ownership is a safe-build assertion only: qjs `add_gc_object`
    /// has no per-registration thread check, and the release
    /// check was the single largest cost of this boundary (~18 insns: a cached
    /// TLS `getCurrentId` read pair + compare, plus the panic arm's `bl`
    /// forcing a callee-saved frame on an otherwise leaf function).
    pub inline fn registerObjectWithBytes(self: *JSRuntime, object: *Object, bytes: usize) !void {
        std.debug.assert(self.isOwnerThread());
        try self.gc.addInitializedWithSize(object.gcHeader(), bytes);
    }

    /// GC-list unlink + free-byte accounting boundary of an object teardown,
    /// with the allocation size supplied by the caller. `destroyFromHeader`
    /// (the sole caller) already computes the inline-class-payload layout (for
    /// the tail `freeObjectAllocation`); its `object_size` is bit-for-bit the
    /// value `allocationSize` would recompute here (both go through
    /// `inlineClassPayloadLayout(recordPtr(class_id))`, and `class_id` is unchanged
    /// between the two calls). Reusing it drops a redundant record-table lookup +
    /// 88-byte-stride multiply + inline-layout recompute off the hot free path —
    /// qjs `free_object` never recomputes an object's size at
    /// teardown either (the slab block carries it).
    ///
    /// The weak/borrowed side-table links were already detached at the TOP of
    /// `destroyFromHeader` (before class-payload teardown, because those links
    /// borrow payload-owned storage), and nothing during payload teardown can
    /// re-register a finalizing object — so this boundary no longer repeats the
    /// two unregister scans. qjs `free_object` keeps no such side tables at all;
    /// `remove_gc_object` is a bare `list_del`.
    ///
    /// Thread ownership is a safe-build assertion only, mirroring the register
    /// side (qjs `remove_gc_object` has no thread check either).
    pub fn unregisterObjectWithBytes(self: *JSRuntime, object: *Object, bytes: usize) void {
        // qjs remove_gc_object has no thread check. The
        // comment above says this is a safe-build assertion only;
        // `std.debug.assert(self.isOwnerThread())` still evaluates gettid
        // in ReleaseFast because the syscall is not pure. Gate the call.
        if (comptime std.debug.runtime_safety) {
            std.debug.assert(self.isOwnerThread());
        }
        if (builtin.mode == .Debug) {
            // Catch any future payload finalizer that re-registers mid-teardown.
            if (object.weakReferenceHolderLink()) |link| std.debug.assert(!link.registered);
            std.debug.assert(!object.flags.is_borrowed_reference_holder);
        }
        // The tracing sweeps detach and stamp condemned objects before their
        // resource pass. In that state the generic unlink boundary would only
        // rediscover facts already established by condemnation; retain its
        // mandatory byte debit without paying the outlined call. RC does not
        // compile this arm.
        if (gc.headerCondemned(object.gcHeaderConst())) {
            self.gc.recordDetachedHeapFreeWithBytes(object.gcHeader(), bytes);
            return;
        }
        self.gc.unlinkObjectWithBytes(object.gcHeader(), bytes);
    }

    /// Link a weak-capable payload for its full object lifetime. This is
    /// allocation-free and mirrors QuickJS's runtime weakref_list: collection
    /// emptiness changes do not mutate the list while a GC weak pass traverses
    /// it.
    pub fn registerWeakReferenceHolder(self: *JSRuntime, object: *Object) void {
        gc_weak.registerHolder(self, object);
    }

    pub fn unregisterWeakReferenceHolder(self: *JSRuntime, object: *Object) void {
        gc_weak.unregisterHolder(self, object);
    }

    pub fn registerBorrowedReferenceHolder(self: *JSRuntime, object: *Object) !void {
        return property_state.registerBorrowedHolder(self, object);
    }

    pub fn borrowedReferenceHolderRegistered(self: *const JSRuntime, object: *Object) bool {
        _ = self;
        return object.isBorrowedReferenceHolder();
    }

    pub fn unregisterBorrowedReferenceHolder(self: *JSRuntime, object: *Object) void {
        property_state.unregisterBorrowedHolder(self, object);
    }

    pub fn linkContext(self: *JSRuntime, ctx: *context_mod.JSContext) void {
        context_registry.linkLive(self, ctx);
    }

    pub fn linkConstructingContext(self: *JSRuntime, ctx: *context_mod.JSContext) void {
        context_registry.linkConstructing(self, ctx);
    }

    pub fn unlinkConstructingContext(self: *JSRuntime, ctx: *context_mod.JSContext) void {
        context_registry.unlinkConstructing(self, ctx);
    }

    pub fn unlinkContext(self: *JSRuntime, ctx: *context_mod.JSContext) void {
        context_registry.unlinkLive(self, ctx);
    }

    pub fn firstContext(self: *const JSRuntime) ?*context_mod.JSContext {
        return context_registry.firstLive(self);
    }

    fn assertNoHostRealmRefsForTeardown(self: *JSRuntime) void {
        context_registry.assertNoHostRealmRefs(self);
    }

    pub fn contextForGlobal(self: *const JSRuntime, global: *const Object) ?*context_mod.JSContext {
        return context_registry.liveForGlobal(self, global);
    }

    /// Bootstrap-only resolver. Public enumeration uses `contextForGlobal`,
    /// whose list contains published realms exclusively.
    pub fn contextForGlobalIncludingConstructing(self: *const JSRuntime, global: *const Object) ?*context_mod.JSContext {
        return context_registry.anyForGlobal(self, global);
    }

    /// Clear the owning realm's %Array.prototype% marker after a mutation of
    /// %Object.prototype%. Other realms in this runtime stay eligible.
    pub fn invalidateStandardArrayPrototypeForObjectPrototype(self: *JSRuntime, object_prototype: *Object) void {
        context_registry.invalidateStandardArrayPrototype(self, object_prototype);
    }

    pub fn initialArrayShapeForPrototype(self: *const JSRuntime, prototype: ?*const Object) ?*shape.Shape {
        return context_registry.initialArrayShape(self, prototype);
    }

    /// Reserve a prototype slot in every realm before a class id is published.
    /// The lists are indexes; `RealmRef` keeps each realm alive across growth.
    pub fn ensureContextClassPrototypeCapacity(self: *JSRuntime, class_id: class.ClassId) !void {
        return context_registry.ensureClassPrototypeCapacity(self, class_id);
    }

    /// Drop a dynamically unregistered class prototype from every realm.
    pub fn clearContextClassPrototype(self: *JSRuntime, class_id: class.ClassId) void {
        context_registry.clearClassPrototype(self, class_id);
    }

    pub fn registerRootProvider(self: *JSRuntime, provider: RootProvider) !void {
        self.assertOwnerThread();
        try self.roots.register(self, provider);
    }

    pub fn registerRootProviderChecked(self: *JSRuntime, provider: RootProvider) !void {
        try self.requireOwnerThread();
        return self.registerRootProvider(provider);
    }

    pub fn unregisterRootProvider(self: *JSRuntime, provider: RootProvider) void {
        self.assertOwnerThread();
        self.roots.unregister(self, provider);
    }

    /// Collections since this runtime started. `core.Local` compares against
    /// it to decide whether a native-held reference is still current.
    pub inline fn collectionEpoch(self: *const JSRuntime) u64 {
        return self.gc.collection_epoch;
    }

    pub fn traceRoots(self: *JSRuntime, roots: ?*const ValueRootFrame, visitor: *RootVisitor) RootTraceError!void {
        try self.traceValueRootFrames(roots, visitor);
        try visitor.value(&self.current_exception);
        try self.roots.traceHandleSlots(visitor);
        for (self.deferred_class_payload_roots.items) |object| {
            try object.traceClassPayloadRootEdges(self, visitor);
        }
        for (self.deferred_class_payload_finalizers.items) |*job| {
            try job.traceRoots(self, visitor);
        }
        if (self.active_deferred_class_payload_finalizer) |job| {
            try job.traceRoots(self, visitor);
        }
        try self.job_queue.traceRoots(visitor);
        for (self.weakref_kept_alive.items) |*kept| try visitor.value(kept);
        try self.roots.traceProviders(visitor);
        try self.traceStringCacheRoots(visitor);
        try self.traceAtomRoots(visitor);
    }

    /// TGC S3 §2.2 roots I and J: the two engine-global tables that own atom
    /// ids outside any GC header. Both are exact -- `popBacktraceFrame` and
    /// `Table.unregister` release the same ids.
    fn traceAtomRoots(self: *JSRuntime, visitor: *RootVisitor) RootTraceError!void {
        if (comptime !value_root_frames_enabled) return;
        if (visitor.visit_atom == null) return;
        for (self.backtrace_frames) |frame| {
            try visitor.atomRoot(frame.function_name);
            try visitor.atomRoot(frame.filename);
        }
        for (self.classes.records) |record| {
            try visitor.atomRoot(record.class_name);
        }
    }

    /// TGC S2: the runtime's interned/cached flat strings are roots while the
    /// string family is tracer-owned (they used to hold a +1 count each).
    fn traceStringCacheRoots(self: *JSRuntime, visitor: *RootVisitor) RootTraceError!void {
        try string_cache.trace(self, visitor);
        try self.atoms.traceRoots(visitor);
    }

    pub fn traceActiveRoots(self: *JSRuntime, visitor: *RootVisitor) RootTraceError!void {
        if (comptime value_root_frames_enabled) {
            try self.traceRoots(self.active_value_roots, visitor);
            var active_job = active_job_root_head;
            while (active_job) |root| {
                if (root.runtime == self) try root.job.traceRoots(visitor);
                active_job = root.previous;
            }
            if (self.active_invocation) |invocation| {
                const header: *const ActiveInvocationTrace = @ptrCast(@alignCast(invocation));
                try header.traceRoots(invocation, visitor);
            }
            if (trace_atomics_wait_async) |trace| try trace(@ptrCast(self), visitor);
        } else {
            try self.traceRoots(null, visitor);
        }
    }

    /// Audit the exact temporary-root populations used by deferred plugin
    /// payload finalizers. A publisher may make freed cells allocatable while
    /// the global doomed transaction is still open, so "the pointer still
    /// falls inside a mapped block" is not enough: every declared payload
    /// edge must still name a live, non-doomed allocation at publication.
    ///
    /// This is called only behind `gc.invariantChecksEnabled`; the shipped
    /// non-audit ReleaseFast path does not walk payload roots.
    pub fn verifyDeferredClassPayloadRootLiveness(self: *JSRuntime) gc.InvariantError!void {
        const Audit = struct {
            rt: *JSRuntime,
            failure: ?gc.InvariantError = null,

            fn checkHeader(audit: *@This(), header: *const gc.Header) void {
                if (audit.failure != null) return;
                if (!audit.rt.gc.containsHeader(header)) {
                    audit.failure = error.DeferredPayloadRootNotLive;
                    return;
                }
                if (header.metaConst().flags.finalizing) {
                    audit.failure = error.DeferredPayloadRootDoomed;
                    return;
                }
                const cell_addr = @intFromPtr(header) - gc.metadata_prefix_size;
                if (audit.rt.gc.block_heap.blockOf(@ptrFromInt(cell_addr))) |block| {
                    const index = block.cellIndex(cell_addr) orelse {
                        audit.failure = error.DeferredPayloadRootNotLive;
                        return;
                    };
                    if (!block.cellAllocated(index)) {
                        audit.failure = error.DeferredPayloadRootNotLive;
                    } else if (block.isDoomed(index)) {
                        audit.failure = error.DeferredPayloadRootDoomed;
                    }
                }
            }

            fn visitValue(context: *anyopaque, slot: *JSValue) RootTraceError!void {
                const audit: *@This() = @ptrCast(@alignCast(context));
                if (slot.cycleMarkHeader()) |header| audit.checkHeader(header);
            }

            fn visitObject(context: *anyopaque, slot: *?*Object) RootTraceError!void {
                const audit: *@This() = @ptrCast(@alignCast(context));
                if (slot.*) |object| audit.checkHeader(object.gcHeader());
            }

            fn visitHeader(context: *anyopaque, header: *const gc.Header) RootTraceError!void {
                const audit: *@This() = @ptrCast(@alignCast(context));
                audit.checkHeader(header);
            }
        };

        var audit = Audit{ .rt = self };
        var visitor = RootVisitor{
            .context = @ptrCast(&audit),
            .visit_value = Audit.visitValue,
            .visit_object = Audit.visitObject,
            .visit_header = Audit.visitHeader,
        };
        for (self.deferred_class_payload_roots.items) |object| {
            object.traceClassPayloadRootEdges(self, &visitor) catch
                return error.DeferredPayloadRootNotLive;
        }
        for (self.deferred_class_payload_finalizers.items) |*job| {
            job.traceRoots(self, &visitor) catch
                return error.DeferredPayloadRootNotLive;
        }
        if (self.active_deferred_class_payload_finalizer) |job| {
            job.traceRoots(self, &visitor) catch
                return error.DeferredPayloadRootNotLive;
        }
        if (audit.failure) |failure| return failure;
    }

    pub fn traceValueRootFrameChain(
        self: *JSRuntime,
        roots: ?*const ValueRootFrame,
        visitor: *RootVisitor,
    ) RootTraceError!void {
        try self.traceValueRootFrames(roots, visitor);
    }

    fn traceValueRootFrames(self: *JSRuntime, roots: ?*const ValueRootFrame, visitor: *RootVisitor) RootTraceError!void {
        _ = self;
        var frame = roots;
        while (frame) |current| {
            for (current.objects) |root| {
                try visitor.optionalObject(root);
            }
            if (comptime value_root_frames_enabled) {
                for (current.headers) |root| {
                    try visitor.constHeader(root.header);
                }
            }
            for (current.values) |root| {
                try visitor.value(root);
            }
            if (comptime value_root_frames_enabled) {
                if (visitor.visit_atom != null) {
                    for (current.atoms) |root| switch (root) {
                        .single => |slot| try visitor.atomRoot(slot.*),
                        // Read the slice header now: the frame may have been
                        // linked before the array had any element at all.
                        .list => |list| for (list.*) |id| try visitor.atomRoot(id),
                    };
                }
            }
            for (current.slices) |root| {
                switch (root) {
                    .mutable => |values| try visitor.values(values.*),
                    .borrowed => |values| try visitor.constValues(values),
                    .windowed => |w| try visitor.values(w.values.*.ptr[0..w.live_len.*]),
                    .cells => |cells| {
                        for (cells.*) |cell| {
                            var cell_value = cell.valueRef();
                            try visitor.value(&cell_value);
                        }
                    },
                    .borrowed_cells => |cells| {
                        for (cells) |cell| try visitor.constValue(cell.valueRef());
                    },
                }
            }
            frame = current.previous;
        }
    }

    /// Runtime teardown is not an owner for public handles. Clearing these
    /// arrays here would leave the caller's handle pointing into freed memory;
    /// every scope/persistent/weak owner must close its edge first.
    fn assertNoOutstandingValueHandles(self: *const JSRuntime) void {
        self.roots.assertNoOutstanding();
    }

    /// Stack-local execution/root records are borrowed by Runtime. They must be
    /// gone before teardown in every optimization mode; silently continuing
    /// would leave their deferred cleanup pointing into a destroyed Runtime.
    fn assertIdleForTeardown(self: *const JSRuntime) void {
        self.roots.assertNoOutstandingBuffers();
        const active_job_for_runtime = if (comptime active_job_roots_enabled) blk: {
            var current = active_job_root_head;
            while (current) |root| : (current = root.previous) {
                if (root.runtime == self) break :blk true;
            }
            break :blk false;
        } else false;
        if (self.call_depth != 0 or
            self.native_call_depth != 0 or
            self.active_bytecode_stack_bytes != 0 or
            self.current_backtrace_frame != null or
            self.active_native_call != null or
            self.active_invocation != null or
            self.active_value_roots != null or
            active_job_for_runtime or
            self.microtasks.running or self.microtasks.scope_depth != 0 or
            self.formatting_error_stack)
        {
            @panic("JSRuntime destroyed while execution or root frames are active");
        }
    }

    pub fn clearWeakRootSlot(self: *JSRuntime, slot: *WeakRootSlot, notify: bool) void {
        if (slot.identity == null) return;
        self.clearWeakIdentitySlot(&slot.identity);
        if (notify) {
            if (slot.callback) |callback| callback(self, slot.callback_context);
        }
    }

    pub fn sweepDeadWeakPersistentSlots(self: *JSRuntime, live_context: anytype) void {
        for (self.roots.weak_root_slots.items) |slot| {
            const identity = slot.identity orelse continue;
            if (!live_context.isWeakIdentityAlive(identity)) {
                self.clearWeakRootSlot(slot, true);
            }
        }
    }

    pub fn clearWeakPersistentIdentity(self: *JSRuntime, identity: usize, notify: bool) void {
        for (self.roots.weak_root_slots.items) |slot| {
            const slot_identity = slot.identity orelse continue;
            if (slot_identity == identity) self.clearWeakRootSlot(slot, notify);
        }
    }

    /// A successful WeakRef.deref keeps its target alive through the current
    /// checkpoint, including all jobs enqueued while it drains.
    pub fn keepAliveWeakRefTarget(self: *JSRuntime, value: JSValue) void {
        job_mod.keepAliveWeakRef(self, value);
    }

    /// Clear [[KeptAlive]] at a completed or terminated checkpoint.
    pub fn clearWeakRefKeptAlive(self: *JSRuntime) void {
        job_mod.clearKeptAlive(self);
    }

    /// TGC S4-e spec 2.5: object identities are not counted. A weak identity
    /// token stays valid until its object dies, and death hands the token back
    /// (`takeWeakObjectIdentity`); nothing about how many WeakRefs name it
    /// changes when the object is collected. Only symbol identities, whose
    /// atom entry is kept indexed by the count in `atom.zig`, still count.
    pub fn retainWeakIdentity(self: *JSRuntime, identity: usize) void {
        if ((identity & 1) == 0) return;
        const atom_id = identity >> 1;
        if (atom_id > std.math.maxInt(u32)) return;
        self.atoms.retainSymbolWeakRef(atom.Atom.fromRaw(@intCast(atom_id)));
    }

    /// Mirror of `retainWeakIdentity`: releasing an object identity is a no-op
    /// because nothing was retained (TGC S4-e spec 2.5).
    pub fn releaseWeakIdentity(self: *JSRuntime, identity: usize) void {
        if ((identity & 1) == 0) return;
        const atom_id = identity >> 1;
        if (atom_id > std.math.maxInt(u32)) return;
        self.atoms.releaseSymbolWeakRef(self, atom.Atom.fromRaw(@intCast(atom_id)));
    }

    pub fn clearWeakIdentitySlot(self: *JSRuntime, slot: *?usize) void {
        const identity = slot.* orelse return;
        slot.* = null;
        self.releaseWeakIdentity(identity);
    }

    pub fn weakIdentityIsCurrentlyLive(self: *JSRuntime, identity: usize) bool {
        if ((identity & 1) != 0) {
            const atom_id = identity >> 1;
            if (atom_id > std.math.maxInt(u32)) return false;
            return self.atoms.kind(atom.Atom.fromRaw(@intCast(atom_id))) == .symbol;
        }
        return self.liveObjectFromWeakIdentity(identity) != null;
    }

    pub fn valueFromWeakIdentity(self: *JSRuntime, identity: usize) JSValue {
        if ((identity & 1) != 0) {
            const atom_id = identity >> 1;
            if (atom_id > std.math.maxInt(u32)) return JSValue.undefinedValue();
            const symbol_atom: atom.Atom = atom.Atom.fromRaw(@intCast(atom_id));
            if (self.atoms.kind(symbol_atom) != .symbol) return JSValue.undefinedValue();
            return self.atoms.symbolValueIfLive(self, symbol_atom);
        }
        const object = self.liveObjectFromWeakIdentity(identity) orelse return JSValue.undefinedValue();
        return object.value();
    }

    /// Resolves an even weak identity (`weak_id << 1`) to its registered
    /// object in O(1). Returns null for symbol identities and for ids whose
    /// object is gone.
    ///
    /// TGC S4-e spec 2.5: "gone" used to mean two things -- unregistered, or
    /// still allocated as a resource-stripped weak husk. The husk is retired:
    /// the sweep hands the id back (`takeWeakObjectIdentity`) inside the same
    /// destruction that frees the struct, so an id that still resolves names a
    /// live object and the map lookup is the whole liveness test.
    pub fn liveObjectFromWeakIdentity(self: *const JSRuntime, identity: usize) ?*Object {
        return gc_weak.objectFromIdentity(self, identity);
    }

    /// Returns the encoded weak identity for `object`, allocating a fresh
    /// monotonically increasing weak id on first registration.
    pub fn registerWeakObjectIdentity(self: *JSRuntime, object: *Object) !usize {
        return gc_weak.registerObject(self, object);
    }

    /// Returns the encoded weak identity for `object` without registering one.
    pub fn peekWeakObjectIdentity(self: *const JSRuntime, object: *const Object) ?usize {
        return gc_weak.peekObject(self, object);
    }

    /// Removes `object` from the weak identity registry, returning its encoded
    /// weak identity (if any) so destruction can propagate it to weak slots.
    pub fn takeWeakObjectIdentity(self: *JSRuntime, object: *Object) ?usize {
        return gc_weak.takeObject(self, object);
    }

    pub fn enterHandleScope(self: *JSRuntime) HandleScope {
        return HandleScope.enter(self);
    }

    pub fn localRootCountForTest(self: *const JSRuntime) usize {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.roots.local_root_slots.items.len;
    }

    pub fn weakRootCountForTest(self: *const JSRuntime) usize {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.roots.weak_root_slots.items.len;
    }

    pub fn persistentRootCountForTest(self: *const JSRuntime) usize {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.roots.persistent_root_slots.items.len;
    }

    pub fn symbolValue(self: *JSRuntime, atom_id: atom.Atom) !JSValue {
        return self.atoms.symbolValue(self, atom_id);
    }

    pub fn takeSymbolValue(self: *JSRuntime, atom_id: atom.Atom) !JSValue {
        return self.atoms.takeSymbolValue(self, atom_id);
    }

    pub fn newSymbolValue(self: *JSRuntime, description: ?[]const u8) !JSValue {
        const atom_id = if (description) |bytes|
            try self.atoms.newValueSymbol(bytes)
        else
            try self.atoms.newValueSymbolNoDescription();
        errdefer self.atoms.abandonUnpublishedSymbol(atom_id);
        return self.takeSymbolValue(atom_id);
    }

    pub fn globalSymbolValue(self: *JSRuntime, key: []const u8) !JSValue {
        const atom_id = try self.atoms.internRegisteredValueSymbol(key);
        return self.symbolValue(atom_id);
    }

    /// One strong persistent handle. `createValueHandle` and `takeValueHandle`
    /// are the same store: a `JSValue` is copied by bits.
    pub fn createPersistentValue(self: *JSRuntime, value: JSValue) !JSValueHandle {
        return JSValueHandle.init(self, value);
    }

    pub fn createValueHandle(self: *JSRuntime, value: JSValue) !JSValueHandle {
        return self.createPersistentValue(value);
    }

    pub fn takeValueHandle(self: *JSRuntime, value: JSValue) !JSValueHandle {
        return self.createPersistentValue(value);
    }

    pub fn createWeakPersistentValue(
        self: *JSRuntime,
        value: JSValue,
        callback: ?WeakPersistentCallback,
        callback_context: ?*anyopaque,
    ) !WeakPersistentValue {
        return WeakPersistentValue.init(self, value, callback, callback_context);
    }

    /// NB2: allocate an immutable, address-stable host `NativeEntry` from a
    /// template. Never freed before `deinit` (design §5.5 lifetime rule).
    pub fn allocNativeEntry(self: *JSRuntime, template: native_entry.NativeEntry) !*const native_entry.NativeEntry {
        return native_bindings.alloc(self, template);
    }

    pub fn registerNativeEntryFinalizer(self: *JSRuntime, ptr: *anyopaque, finalize: *const fn (*anyopaque) void) !void {
        return native_bindings.registerFinalizer(self, ptr, finalize);
    }

    /// Retire a host entry in place (tombstone): callers that still hold
    /// the function object get a TypeError; nothing is freed.
    pub fn retireNativeEntry(self: *JSRuntime, entry: *const native_entry.NativeEntry) void {
        _ = self;
        native_bindings.retire(entry);
    }

    /// Internal-builtin record lookup: `domain_index` is the
    /// `NativeBuiltinDomain` enum value, `id` the domain-local method id.
    /// Returns null for the separate host domain, invalid/gap ids, and runtimes
    /// whose standard globals were never installed. Two bounds-checked loads;
    /// no hashing or string compares.
    pub fn internalBuiltinRecord(self: *const JSRuntime, domain_index: usize, id: u32) ?*const native_entry.NativeEntry {
        if (domain_index >= self.internal_builtins.len) return null;
        return self.internal_builtins[domain_index].get(id);
    }

    pub fn clearExternalHostFunctions(self: *JSRuntime) void {
        native_bindings.destroyOwned(self);
    }

    /// Precise quiescent collection for lifecycle fixtures only.
    pub fn collectForTest(self: *JSRuntime) usize {
        if (!builtin.is_test) @compileError("test-only collection helper");
        return self.collectForTeardown();
    }

    fn collectForTeardown(self: *JSRuntime) usize {
        self.assertOwnerThread();
        const result = self.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only) catch return 0;
        return result.freed_objects;
    }

    pub fn tryRunObjectCycleRemovalWithValueRoots(
        self: *JSRuntime,
        roots: ?*const ValueRootFrame,
        scan: gc.RootScan,
    ) gc.CollectionError!gc.CollectionResult {
        self.assertOwnerThread();
        // A deferred plugin callback runs only after its collector is idle,
        // but it may allocate or explicitly request another collection. Keep
        // that request pending until callback return: the active job is a root,
        // and a destruction morgue must not be recursively completed under it.
        if (self.active_deferred_class_payload_finalizer != null) return .{};
        self.drainDeferredClassPayloadFinalizersAtSafeBoundary();
        // An explicit "collect everything" supersedes an open incremental
        // cycle rather than joining it: the cycle's floating garbage --
        // objects marked during increments that have since died -- would
        // survive a finish, and this call's promise is full precision. The
        // abort discards only work; the fresh trace below re-derives the rest.
        if (!self.gc_running) {
            // Destruction is irreversible: complete it, then discard any
            // open marking cycle. Order matters only in that both must be
            // resolved before the STW collector below touches the lists.
            if (self.gc.morgue.pending) {
                self.gc_running = true;
                @import("core/gc_trace_stw.zig").finishPendingDestruction(self);
                self.gc_running = false;
                _ = self.finishDoomedCompletion(0);
            }
            self.gc.abortCycle();
        }
        // `gc_running` covers the major driver. The refcount/cycle phases also
        // invoke allocation and callback boundaries, and a previously queued
        // request must remain pending rather than nest a second collection.
        if (self.gc_running or self.gc.hot.phase != .none) return .{};
        if (builtin.mode == .Debug) self.gc.verifyIntrusiveList() catch unreachable;
        if (builtin.mode == .Debug) self.gc.verifyHeapAccounting(self) catch unreachable;
        defer if (builtin.mode == .Debug) {
            self.gc.verifyIntrusiveList() catch unreachable;
            self.gc.verifyHeapAccounting(self) catch unreachable;
        };
        self.gc_running = true;
        defer self.gc_running = false;

        // The cycle's high-water is the account right now, at trigger time.
        mem_ops.samplePeakAtCollection(self);
        const start_ns = profile.nowNanos();

        self.gc.scheduler.beginMajorCycle(self.gc.scheduler.activeMajorReason() orelse .manual);
        const freed = @import("core/gc_trace_stw.zig").collectCycles(self, roots, scan) catch |err| {
            const mapped: gc.CollectionError = switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.PayloadMarkFailed => error.PayloadMarkFailed,
            };
            self.gc.recordFailure(mapped);
            self.gc.scheduler.abortMajorCycle();
            self.gc.requestGC(.collection_failed, .soon);
            return mapped;
        };
        self.gc.scheduler.setMajorPhase(.sweep);

        const end_ns = profile.nowNanos();
        const elapsed = if (end_ns > start_ns) end_ns - start_ns else 0;
        // Charge the census to whoever asked for it, not to the pause. The
        // walks run inside this region and are enabled by the same
        // `--gc-stats` that prints the distribution, so leaving them in makes
        // the only pause instrument inflate its own subject by ~40%.
        const census = self.gc.last_census_ns;
        const result = gc.CollectionResult{
            .freed_objects = freed,
            .duration_ns = elapsed -| census,
        };
        self.gc.recordSuccess(result);
        self.gc.scheduler.finishMajorCycle();
        self.resetGCThreshold();
        // Full STW majors free the same block cells as incremental majors.
        // Service the same aged-decommit policy here; otherwise explicit GC,
        // urgent pressure collections, and small-heap floor collections can
        // age free blocks forever without ever scanning them.
        _ = self.gc.block_heap.releaseFreeBlockPages(end_ns);
        return result;
    }

    pub fn pollGC(
        self: *JSRuntime,
        roots: ?*const ValueRootFrame,
        mode: gc.PollMode,
    ) gc.CollectionError!gc.CollectionResult {
        self.assertOwnerThread();
        if (self.active_deferred_class_payload_finalizer != null) return .{};
        self.drainDeferredClassPayloadFinalizersAtSafeBoundary();
        return gc_driver.continuePoll(self, roots, mode);
    }

    fn resetGCThresholdExcludingDoomed(self: *JSRuntime) void {
        gc_driver.resetThresholdExcludingDoomed(self);
    }

    /// The morgue is empty: deliver the cycle's CollectionResult and reset the
    /// growth threshold from the account the destruction actually shrank.
    fn finishDoomedCompletion(self: *JSRuntime, last_slice_ns: u64) gc.CollectionResult {
        return gc_driver.finishDoomed(self, last_slice_ns);
    }

    /// Host-facing checked form of `pollGC`. Internal engine paths use the
    /// asserting form so the mutation-contract error does not widen ordinary
    /// JavaScript execution error sets.
    pub fn pollGCChecked(
        self: *JSRuntime,
        roots: ?*const ValueRootFrame,
        mode: gc.PollMode,
    ) RuntimeCollectionError!gc.CollectionResult {
        try self.requireOwnerThread();
        return self.pollGC(roots, mode);
    }

    pub fn gcSafepoint(self: *JSRuntime, roots: ?*const ValueRootFrame) gc.CollectionError!gc.CollectionResult {
        return self.pollGC(roots, .safepoint);
    }

    pub fn afterCallbackBoundaryGC(self: *JSRuntime, roots: ?*const ValueRootFrame) gc.CollectionError!gc.CollectionResult {
        const result = try self.pollGC(roots, .callback_boundary);
        _ = self.runDeferredNativeCleanupBudgeted(self.gc.scheduler.policy.native_cleanup_slice_jobs);
        _ = self.runDeferredClassPayloadFinalizerBudgeted(self.gc.scheduler.policy.native_cleanup_slice_jobs);
        return result;
    }

    pub fn beforeEventLoopIdleGC(self: *JSRuntime, roots: ?*const ValueRootFrame) gc.CollectionError!gc.CollectionResult {
        const result = try self.pollGC(roots, .idle);
        _ = self.runDeferredNativeCleanupBudgeted(self.gc.scheduler.policy.native_cleanup_slice_jobs);
        _ = self.runDeferredClassPayloadFinalizerBudgeted(self.gc.scheduler.policy.native_cleanup_slice_jobs);
        return result;
    }

    pub fn forceGC(self: *JSRuntime, roots: ?*const ValueRootFrame) gc.CollectionError!gc.CollectionResult {
        self.assertOwnerThread();
        self.gc.requestGC(.manual, .urgent);
        return self.pollGC(roots, .urgent);
    }

    pub fn requestGCForTest(self: *JSRuntime) void {
        if (!builtin.is_test) @compileError("test-only helper");
        self.assertOwnerThread();
        self.gc.requestGC(.manual, .soon);
    }

    /// Does a collection started at this poll decide liveness with the
    /// conservative pass over the mutator's native frames?
    ///
    /// A minor DESTROYS synchronously, unlike the threshold's major, which
    /// only opens an incremental cycle and sweeps at a later poll. Running one
    /// from an arbitrary allocation boundary is therefore only sound while the
    /// scan covers the Zig locals the interrupted caller is holding -- the
    /// shape `Object.create` acquires before its own boundary, for one. That
    /// is exactly the promise `gc.PollMode.rootScan` makes for the engine
    /// triggers, and exactly what `test_root_scan_override` withdraws: pacing
    /// tests declare their frame quiescent so reclamation is deterministic,
    /// which an allocation boundary in the middle of a constructor is not.
    /// Those polls keep the pre-S2-g order (major without a preceding minor).
    pub fn pollScansConservatively(self: *const JSRuntime, mode: gc.PollMode) bool {
        const scan = if (comptime builtin.is_test)
            self.test_root_scan_override orelse mode.rootScan()
        else
            mode.rootScan();
        return scan == .engine_active;
    }

    /// Declare that this test keeps every collectable reference either in a
    /// linked ValueRootFrame or scrubbed (dropGcPtr), so even engine-trigger
    /// collection entries may scan precisely. See `test_root_scan_override`.
    pub fn forcePreciseRootScanForTest(self: *JSRuntime) void {
        if (!builtin.is_test) @compileError("test-only helper");
        self.test_root_scan_override = .declared_only;
    }

    /// Close a `forcePreciseRootScanForTest` window: collections taken from
    /// here on derive their scan from the poll mode again. A test that wants
    /// the precise regime only over a BOUNDED window must call this before
    /// handing control back to code whose GC-visible state lives in native
    /// locals, which `.declared_only` cannot see by construction.
    pub fn restoreDefaultRootScanForTest(self: *JSRuntime) void {
        if (!builtin.is_test) @compileError("test-only helper");
        self.test_root_scan_override = null;
    }

    pub fn gcPendingForTest(self: *const JSRuntime) bool {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.gc.hasPendingMajorRequest();
    }

    pub fn gcLastRequestReasonForTest(self: *const JSRuntime) ?gc.RequestReason {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.gc.stats.last_request_reason;
    }

    pub fn setGCThreshold(self: *JSRuntime, threshold: usize) void {
        self.assertOwnerThread();
        self.gc.invalidateCycleEnvelopeBaseline();
        self.gc.heap_budget.gc_threshold = threshold;
    }

    /// Current dynamic threshold, including changes during Context bootstrap.
    pub fn gcThreshold(self: *const JSRuntime) usize {
        return self.gc.heap_budget.gc_threshold;
    }

    /// JS heap budget cap. Ordinary native allocations do not consult it.
    pub fn setMemoryLimit(self: *JSRuntime, limit: ?usize) void {
        self.gc.heap_budget.limit = limit;
    }

    /// Test-only cap on the account's native byte counter. This is the
    /// injector for ordinary allocation failure. `setMemoryLimit` does not
    /// fail those allocations.
    pub fn setNativeBytesLimitForTest(self: *JSRuntime, limit: ?usize) void {
        if (!builtin.is_test) @compileError("test-only helper");
        mem_ops.setLimit(self, limit);
    }

    /// Test-only: stop an over-limit allocation from collecting before it is
    /// rejected.
    ///
    /// The allocation-failure unwind paths are injected by setting the limit
    /// to the current footprint and expecting the very next allocation to
    /// fail. Under the tracer that allocation now gets one collection first,
    /// which is the right production behaviour -- a memory limit should mean
    /// "this much live", not "this much allocated since the last collection"
    /// -- and useless as a fault injector, because freeing a single byte turns
    /// the expected failure into a success. Tests that are exercising the
    /// unwind rather than the collector suppress it around the injection.
    pub fn suppressLimitCollectionForTest(self: *JSRuntime, suppressed: bool) void {
        if (!builtin.is_test) @compileError("test-only helper");
        self.gc.heap_budget.suppress_retry = suppressed;
    }

    pub fn memoryLimit(self: *const JSRuntime) ?usize {
        return self.gc.heap_budget.limit;
    }

    /// Drain ECMAScript jobs only. The host owns timer, I/O and signal dispatch.
    pub fn runMicrotasks(self: *JSRuntime) errors.HostError!void {
        try self.requireOwnerThread();
        try job_mod.runCheckpoint(self);
    }

    pub fn enterMicrotaskScope(self: *JSRuntime) errors.HostError!MicrotaskScope {
        try self.requireOwnerThread();
        if (self.microtasks.reporting) return error.MicrotaskReentry;
        self.microtasks.scope_depth += 1;
        return .{ .runtime = self, .depth = self.microtasks.scope_depth };
    }

    /// Called by engine execution boundaries after their VM frames unwind.
    pub fn runAutomaticMicrotasks(self: *JSRuntime) errors.HostError!void {
        if (self.microtasks.policy != .auto or self.microtasks.running or self.microtasks.scope_depth != 0 or
            self.call_depth != 0 or self.native_call_depth != 0 or self.active_invocation != null) return;
        try self.runMicrotasks();
    }

    pub fn setMicrotaskExceptionHandler(self: *JSRuntime, handler: ?job_mod.ExceptionHandler, userdata: ?*anyopaque) void {
        self.assertOwnerThread();
        self.microtasks.handler = handler;
        self.microtasks.userdata = userdata;
    }

    pub fn memoryUsage(self: *const JSRuntime) MemoryUsage {
        var live_dynamic_atoms: usize = 0;
        var dynamic_atom_bytes: usize = 0;
        for (self.atoms.entries) |entry| {
            if (!entry.isLive()) continue;
            live_dynamic_atoms += 1;
            dynamic_atom_bytes += entry.bytes.len;
        }

        var registered_classes: usize = 0;
        for (self.classes.records) |record| {
            if (record.isRegistered()) registered_classes += 1;
        }

        const class_record_count = self.classes.records.len;
        return .{
            .memory_limit = self.memoryLimit(),
            .heap_bytes = self.gc.heap_budget.bytes,
            .allocated_bytes = if (alloc_trace.enabled) self.diagnostics.allocations.allocated_bytes + @sizeOf(JSRuntime) else 0,
            .allocation_count = if (alloc_trace.enabled) self.diagnostics.allocations.allocation_count + 1 else 0,
            .peak_allocated_bytes = if (alloc_trace.enabled) self.diagnostics.allocations.peak_allocated_bytes + @sizeOf(JSRuntime) else 0,
            .peak_allocation_count = if (alloc_trace.enabled) self.diagnostics.allocations.peak_allocation_count + 1 else 0,
            .alloc_calls = if (alloc_trace.enabled) self.diagnostics.allocations.alloc_calls else 0,
            .free_calls = if (alloc_trace.enabled) self.diagnostics.allocations.free_calls else 0,
            .create_calls = if (alloc_trace.enabled) self.diagnostics.allocations.create_calls + 1 else 0,
            .destroy_calls = if (alloc_trace.enabled) self.diagnostics.allocations.destroy_calls else 0,
            .atom_count = atom.predefined_count + live_dynamic_atoms,
            .atom_bytes = dynamic_atom_bytes,
            .registered_class_count = registered_classes,
            .class_record_count = class_record_count,
        };
    }

    pub fn reportExternalAlloc(self: *JSRuntime, bytes: usize) !gc.ExternalMemoryToken {
        const token = try self.gc.reportExternalAlloc(bytes);
        if (self.gc.externalMemoryRequestReason()) |reason| {
            self.gc.requestGC(reason, self.gc.externalMemoryRequestUrgency());
        }
        return token;
    }

    /// Internal classification for inline buffer bytes that already live in
    /// mem_ops. Off-account embedders must use `reportExternalAlloc` and
    /// retain its token; this raw hook does not perform the pressure check.
    pub fn externalMemoryBytes(self: *const JSRuntime) usize {
        return self.gc.stats.external_bytes;
    }

    pub fn allocationDebtBytes(self: *const JSRuntime) usize {
        // Historical API name: this is weighted byte-debt, not a live-memory
        // byte count. `external_weight` may make it larger than the external
        // bytes allocated since the last completed major.
        return self.gc.stats.allocation_debt;
    }

    /// Pause percentiles over the collector's retained round window, or null
    /// if no collection has completed. Separate from `gcStats` because it
    /// sorts a scratch copy; callers that only want counters should not pay
    /// for it.
    pub fn gcPauseDistribution(self: *const JSRuntime) ?gc.PauseDistribution {
        return self.gc.pauseDistribution();
    }

    fn fillGcCounters(self: *const JSRuntime, stats: *gc.Stats) void {
        stats.weak_ref_count = self.weakRootSlotCount();
        const finalization_jobs = self.job_queue.countKind(.finalization);
        stats.finalizer_queue_length = finalization_jobs;
        stats.pending_finalization_job_count = finalization_jobs;
        stats.deferred_native_cleanup_count = self.deferred_native_cleanups.items.len;
        stats.deferred_native_cleanup_run_count = self.deferred_native_cleanup_run_count;
        stats.deferred_class_payload_finalizer_count = self.deferred_class_payload_finalizers.items.len;
        stats.deferred_class_payload_finalizer_run_count = self.deferred_class_payload_finalizer_run_count;
    }

    /// Maintained counters only. Does not walk the heap.
    pub fn gcStats(self: *const JSRuntime) gc.Stats {
        var stats = self.gc.counterSnapshot(self);
        self.fillGcCounters(&stats);
        return stats;
    }

    /// One heap census. Heap bytes stay separate from external debt.
    pub fn gcDetailedStats(self: *const JSRuntime) gc.DetailedStats {
        var detailed = self.gc.statsSnapshot(self);
        self.fillGcCounters(&detailed.counters);
        detailed.counters.weak_ref_count += self.weakObjectEntryCount();
        return detailed;
    }

    pub fn ownsObject(self: *const JSRuntime, object: *const Object) bool {
        return self.gc.containsHeader(object.gcHeaderConst());
    }

    fn weakRootSlotCount(self: *const JSRuntime) usize {
        var count: usize = 0;
        for (self.roots.weak_root_slots.items) |slot| {
            if (slot.identity != null) count += 1;
        }
        return count;
    }

    fn weakObjectEntryCount(self: *const JSRuntime) usize {
        gc.noteHeapWalk();
        var count: usize = 0;
        var gc_iter = self.gc.objectIterator(.all);
        while (gc_iter.next()) |header| {
            if (header.meta().flags.kind == .object) {
                const obj = Object.fromHeader(header);
                count +|= obj.weakCollectionEntries().len;
                count +|= obj.finalizationRegistryCells().len;
            }
        }
        return count;
    }

    inline fn prospectiveAllocationTotal(self: *const JSRuntime, size: usize) usize {
        return self.gc.heap_budget.bytes +| size;
    }

    /// Queue an allocation-threshold request and return the exact prospective
    /// total used for that decision. Object allocation immediately consumes
    /// the same total to retire a stale threshold request; returning it keeps
    /// `gc.requestGC`'s writes from forcing a second allocated-bytes load and
    /// overflow-checked add on every object construction.
    inline fn requestGCForAllocationTotal(self: *JSRuntime, size: usize) usize {
        if (comptime builtin.is_test) {
            if (self.gc.heap_budget.probe) |probe| {
                const budget = &self.gc.heap_budget;
                const saved = budget.suspend_alloc_notify;
                budget.suspend_alloc_notify = true;
                defer budget.suspend_alloc_notify = saved;
                probe(budget.probe_ctx, size);
                return self.prospectiveAllocationTotal(size);
            }
        }
        // Allocation is legal from class/native finalizers while the refcount
        // queue is in its decref phase, but starting a nested major collection
        // is not. `gc_running` covers the major driver; the explicit phase guard
        // also covers outer zero-ref drains that run without that flag.
        if (self.gc_running or self.gc.hot.phase != .none) return self.prospectiveAllocationTotal(size);
        if (comptime memory.force_gc_on_allocation_enabled) {
            if (self.gc.heap_budget.suspend_alloc_notify) return self.prospectiveAllocationTotal(size);
            // The force-GC build option is diagnostic instrumentation, not a
            // scheduling-policy change. Preserve an explicitly configured
            // threshold across the synthetic pre-allocation collection.
            const saved_threshold = self.gc.heap_budget.gc_threshold;
            defer self.gc.heap_budget.gc_threshold = saved_threshold;
            _ = self.forceGC(null) catch {};
            return self.prospectiveAllocationTotal(size);
        }
        // The growth bar is the heap budget, not the mixed native account.
        const total = self.prospectiveAllocationTotal(size);
        if (total > self.gc.heap_budget.gc_threshold) {
            self.gc.requestGC(.allocation_threshold, .soon);
        }
        return total;
    }

    pub inline fn requestGCForAllocation(self: *JSRuntime, size: usize) void {
        _ = self.requestGCForAllocationTotal(size);
    }

    /// QuickJS `JS_NewObjectFromShape` runs its threshold GC before entering
    /// the allocator. Object construction uses this stronger boundary instead
    /// of merely leaving a pending request for post-registration service: a
    /// memory-limit check must be allowed to reuse space from reclaimable
    /// cycles before rejecting the replacement object.
    pub fn collectBeforeObjectAllocation(self: *JSRuntime, size: usize) align(64) void {
        // Plugin callbacks are forbidden inside tracer_destroy. The first
        // object-allocation boundary after the collector becomes idle drains
        // them before publishing another object. Allocations made by a callback
        // reenter this function with `draining_...` set: they may request the
        // next GC, but cannot recursively drain the same queue.
        if (self.deferred_class_payload_finalizers.items.len != 0 and
            !self.gc_running and self.gc.hot.phase == .none and
            !self.draining_deferred_class_payload_finalizers)
        {
            @branchHint(.unlikely);
            return self.collectBeforeObjectAllocationAfterDeferredDrain(size);
        }
        self.collectBeforeObjectAllocationAfterFinalizerCheck(size);
    }

    /// Cold continuation for the callback-delivery boundary. Re-enter the
    /// allocation decision after draining, but skip the queue-ready test: a
    /// callback may have queued another job while `draining_...` was set, and
    /// recursively trying to drain it at the same boundary is forbidden.
    noinline fn collectBeforeObjectAllocationAfterDeferredDrain(self: *JSRuntime, size: usize) void {
        self.drainDeferredClassPayloadFinalizersAtSafeBoundary();
        self.collectBeforeObjectAllocationAfterFinalizerCheck(size);
    }

    /// Cold tail that owns `pollGC`'s error-union return area. The common
    /// below-threshold allocation path can then remain a leaf with no saved
    /// registers or stack frame.
    noinline fn pollGCBeforeObjectAllocation(self: *JSRuntime) void {
        _ = self.pollGC(null, .normal) catch {};
    }

    inline fn collectBeforeObjectAllocationAfterFinalizerCheck(self: *JSRuntime, size: usize) void {
        const prospective = self.requestGCForAllocationTotal(size);
        // Scratch allocation can cross the threshold and queue a request, then
        // fall back below it before the next qjs-style object boundary. The
        // threshold condition is level-triggered: discard only that ordinary
        // stale request. Registry request coalescing preserves manual/external/
        // pressure reasons so they cannot be cancelled here.
        if (prospective <= self.gc.heap_budget.gc_threshold) {
            _ = self.gc.scheduler.clearStaleAllocationThresholdRequest();
        }
        // §8.6: allocation debt buys bounded slices of the collector's work.
        // The time budget bounds one slice; the byte interval below also
        // bounds how many allocation-boundary slices one burst can concatenate
        // into a mutator-visible operation. Scheduler/callback/idle polls call
        // pollGC directly and remain unpaced.
        if (self.gc_running or self.gc.hot.phase != .none) return;
        // While marking is open the account is over the (not yet reset)
        // threshold, so each boundary re-records `.allocation_threshold` above
        // and this gate stays open for the increments unaided. Destruction is
        // different: the threshold resets at condemn time (net of corpses), so
        // the account may be UNDER it while the morgue still holds memory --
        // the explicit `doomed_pending` term is what keeps the slices moving.
        if (!self.gc.morgue.pending and !self.gc.hasPendingMajorRequest()) return;
        return self.pollGCBeforeObjectAllocation();
    }

    fn triggerGCOnAllocation(ctx: ?*anyopaque, size: usize) void {
        const self: *JSRuntime = @ptrCast(@alignCast(ctx));
        self.requestGCForAllocation(size);
    }

    /// One heap-limit retry. The mutator's native frames are live here, so the
    /// scan stays `.engine_active`; `declared_only` would sweep objects the
    /// caller still holds in Zig locals. `Budget.retrying` stops a nested
    /// admit from collecting again, and this guard is the same exit when a
    /// collection is already running.
    fn retryHeapLimitOnce(ctx: *anyopaque) void {
        const self: *JSRuntime = @ptrCast(@alignCast(ctx));
        if (self.gc_running or self.gc.hot.phase != .none) return;
        _ = self.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch return;
    }

    /// Admit `bytes` against the JS heap limit, collecting at most once.
    /// Callers that already hold an unpublished cell must not use this: the
    /// retry can run, and a precise scan cannot name that cell. A rejected
    /// admit is left for the following `checkOnly` to report.
    pub inline fn prepareHeapCharge(self: *JSRuntime, bytes: usize) void {
        if (self.gc.heap_budget.limit == null) {
            @branchHint(.likely);
            return;
        }
        self.prepareHeapChargeSlow(bytes);
    }

    noinline fn prepareHeapChargeSlow(self: *JSRuntime, bytes: usize) void {
        self.gc.heap_budget.admit(bytes) catch {};
    }

    fn resetGCThreshold(self: *JSRuntime) void {
        gc_driver.resetThreshold(self);
    }

    /// Return the shared single-code-unit (latin1) string for `byte`,
    /// creating it lazily on the first request. The cache slot is itself a
    /// root, so the body outlives every borrow of it; there is no per-caller
    /// retain to take (ref-counting was deleted in TGC S1-S3).
    ///
    /// Inline load + branch; the one-shot creation is outlined so a hit costs
    /// nothing more than the table read.
    pub inline fn singleByteString(self: *JSRuntime, byte: u8) !*string.String {
        return string_cache.singleByte(self, byte);
    }

    /// Non-allocating probe: null when the slot has not been filled yet.
    pub inline fn cachedSingleByteString(self: *JSRuntime, byte: u8) ?*string.String {
        return string_cache.cachedSingleByte(self, byte);
    }

    pub fn emptyString(self: *JSRuntime) !*string.String {
        return string_cache.empty(self);
    }

    /// Return a borrowed cached string for a two-code-unit sequence.
    pub fn recentTwoUnitString(self: *JSRuntime, first: u16, second: u16) !*string.String {
        return string_cache.recentTwoUnit(self, first, second);
    }

    /// Return a borrowed cached string for a recently materialized atom.
    pub fn recentAtomString(self: *JSRuntime, atom_id: atom.Atom, bytes: []const u8) !*string.String {
        return string_cache.recentAtom(self, atom_id, bytes);
    }

    /// Return a borrowed cached decimal string ("0".."255") for a byte.
    pub fn smallIntString(self: *JSRuntime, value: u8) !*string.String {
        return string_cache.smallInt(self, value);
    }

    pub fn percentHexString(self: *JSRuntime, value: u8) !*string.String {
        return string_cache.percentHex(self, value);
    }

    pub fn setStackSize(self: *JSRuntime, size: usize) void {
        self.assertOwnerThread();
        self.stack_size = size;
        self.vm_stack_frame_storage = VmStackStorage.frameWindowForLimit(size);
    }

    pub fn stackSize(self: *const JSRuntime) usize {
        return self.stack_size;
    }

    pub fn nativeStackSize(self: *const JSRuntime) usize {
        return self.native_stack_size;
    }

    pub fn setNativeStackSize(self: *JSRuntime, budget_bytes: usize) void {
        self.assertOwnerThread();
        self.native_stack_size = budget_bytes;
        if (self.call_depth == 0 and self.native_call_depth == 0) {
            self.updateNativeStackTop();
        } else {
            self.native_stack_limit = if (budget_bytes == 0) 0 else self.native_stack_top -| budget_bytes;
        }
    }

    /// Capture the current native frame pointer as the recursion base and derive
    /// the lower limit. Mirrors QuickJS `JS_UpdateStackTop` + `update_stack_limit`
    ///. Must be called at the outermost JS entry on the
    /// thread that will run the code (worker threads have their own C stack), so
    /// deeper native frames (parser / JSON / interpreter) measure against a real,
    /// same-stack base. A `native_stack_size` of 0 disables the limit.
    pub fn updateNativeStackTop(self: *JSRuntime) void {
        self.native_stack_top = @frameAddress();
        self.native_stack_limit = if (self.native_stack_size == 0)
            0
        else
            self.native_stack_top -| self.native_stack_size;
    }

    /// Return true if consuming `alloca_size` more native stack would cross the
    /// recursion limit. Direct port of QuickJS `js_check_stack_overflow`
    ///: `sp = frame_address - alloca_size; sp < limit`.
    /// Stack grows down, so "below the limit" is overflow.
    ///
    /// The unset limit needs no branch of its own: qjs encodes "no limit" as
    /// `rt->stack_limit = 0` (`update_stack_limit`, quickjs.c) and
    /// lets the same unsigned compare answer it, because no stack pointer is
    /// ever below zero. `native_stack_limit` uses that identical encoding, and
    /// the saturating subtraction keeps `sp` non-negative, so `sp < 0` is
    /// already constant-false. An explicit `limit == 0` pre-test is a zjs-only
    /// extra load-compare-branch on the parser's per-token guard path
    /// (parser.zig `advance`, mirroring qjs guarding `next_token`,
    /// quickjs.c) and LLVM does not fold it away.
    pub inline fn checkNativeStackOverflow(self: *const JSRuntime, alloca_size: usize) bool {
        const sp = @frameAddress() -| alloca_size;
        return sp < self.native_stack_limit;
    }

    pub fn internAtom(self: *JSRuntime, bytes: []const u8) !atom.Atom {
        return self.atoms.internString(bytes);
    }

    pub fn registerClass(self: *JSRuntime, definition: class.Definition) !class.Binding {
        return self.classes.registerDefinition(definition);
    }

    pub fn setInterruptHandler(self: *JSRuntime, handler: ?*const fn (*JSRuntime, ?*anyopaque) bool, context: ?*anyopaque) void {
        self.interrupt_handler = handler;
        self.interrupt_context = context;
    }

    pub fn getDynamicImportLoader(self: *const JSRuntime) DynamicImportLoader {
        return self.dynamic_import_loader;
    }

    pub fn installDynamicImportLoader(self: *JSRuntime, next: DynamicImportLoader) DynamicImportLoaderScope {
        self.assertOwnerThread();
        const previous = self.dynamic_import_loader;
        self.dynamic_import_loader = next;
        return .{
            .runtime = self,
            .previous = previous,
        };
    }

    pub fn standardGlobalOwnPropertyCapacity(self: *const JSRuntime) usize {
        return self.hooks.standard_global_own_property_capacity;
    }

    /// Thread-safe request. The caller must keep this Runtime alive.
    pub fn terminateExecution(self: *JSRuntime) void {
        self.termination_requested.store(true, .release);
    }

    pub fn isExecutionTerminating(self: *const JSRuntime) bool {
        return self.termination_requested.load(.acquire);
    }

    /// Owner-only idle recovery. Requests ordered after this exchange survive.
    pub fn cancelTerminateExecution(self: *JSRuntime) !void {
        try self.requireOwnerThread();
        if (self.call_depth != 0 or self.native_call_depth != 0 or self.active_invocation != null or self.microtasks.running)
            return error.RuntimeBusy;
        _ = self.termination_requested.swap(false, .acq_rel);
    }

    pub fn hasInterruptHandler(self: *const JSRuntime) bool {
        return self.interrupt_handler != null or self.isExecutionTerminating();
    }

    pub fn runInterruptHandler(self: *JSRuntime) bool {
        if (self.isExecutionTerminating()) return true;
        const handler = self.interrupt_handler orelse return false;
        return handler(self, self.interrupt_context);
    }

    pub fn setCanBlock(self: *JSRuntime, can_block: bool) void {
        self.can_block = can_block;
    }

    pub fn canBlock(self: *const JSRuntime) bool {
        return self.can_block;
    }

    pub fn signalHostCompletion(self: *JSRuntime, io: std.Io) void {
        self.host_completion_event.set(io);
    }

    pub fn resetHostCompletionSignal(self: *JSRuntime) void {
        self.host_completion_event.reset();
    }

    pub fn waitForHostCompletion(self: *JSRuntime, io: std.Io) void {
        self.host_completion_event.waitUncancelable(io);
    }

    pub fn waitForHostCompletionUntil(self: *JSRuntime, io: std.Io, deadline: std.Io.Timestamp) bool {
        self.host_completion_event.waitTimeout(io, .{ .deadline = deadline.withClock(.awake) }) catch |err| switch (err) {
            error.Timeout, error.Canceled => return false,
        };
        return true;
    }

    pub fn enqueueFinalizationJobForRealm(self: *JSRuntime, realm: *context_mod.JSContext, callback: JSValue, held_value: JSValue) !void {
        std.debug.assert(realm.runtime == self);
        try self.job_queue.enqueueFinalization(realm, callback, held_value);
    }

    /// Commit a FinalizationRegistry cleanup against a slot reserved at cell
    /// registration. No allocation.
    pub fn enqueueFinalizationJobReserved(
        self: *JSRuntime,
        realm: *context_mod.JSContext,
        callback: JSValue,
        held_value: JSValue,
    ) void {
        std.debug.assert(realm.runtime == self);
        self.job_queue.enqueueReserved(job_mod.Job.initFinalization(realm, callback, held_value));
    }

    pub fn clearPendingFinalizationJobs(self: *JSRuntime) void {
        while (self.job_queue.firstIndexOfKind(.finalization)) |index| {
            var entry = self.job_queue.takeAt(index);
            entry.deinit();
        }
    }

    pub fn pendingFinalizationJobCountForTest(self: *const JSRuntime) usize {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.job_queue.countKind(.finalization);
    }

    pub fn enqueueDeferredNativeCleanup(self: *JSRuntime, finalizer: host_function.ExternalFinalizer, ptr: *anyopaque) !void {
        return deferred_cleanup.enqueueNative(self, finalizer, ptr);
    }

    pub fn enqueueDeferredClassPayloadFinalizer(self: *JSRuntime, class_id: class.ClassId, payload: class.Payload, payload_kind: class.PayloadKind, object_identity: usize) !bool {
        return deferred_cleanup.enqueueClassPayload(self, class_id, payload, payload_kind, object_identity);
    }

    pub fn reserveDeferredClassPayloadFinalizerSlot(self: *JSRuntime) !void {
        return deferred_cleanup.reserveClassPayloadSlot(self);
    }

    pub fn releaseDeferredClassPayloadFinalizerSlot(self: *JSRuntime) void {
        deferred_cleanup.releaseClassPayloadSlot(self);
    }

    /// Publish a wrapper's declared payload edges as roots after its payload
    /// is fully initialized. The reservation remains outstanding until the
    /// wrapper finalizer atomically transfers the payload to a queued job.
    pub fn registerReservedDeferredClassPayloadRoot(self: *JSRuntime, object: *Object) void {
        deferred_cleanup.registerReservedRoot(self, object);
    }

    /// End the pre-enqueue root lifetime after the queued node has copied the
    /// payload and mark callback. Queue roots take over before this removal.
    pub fn unregisterDeferredClassPayloadRoot(self: *JSRuntime, object: *Object) void {
        deferred_cleanup.unregisterRoot(self, object);
    }

    pub fn enqueueReservedDeferredClassPayloadFinalizer(self: *JSRuntime, class_id: class.ClassId, generation: u64, payload: class.Payload, payload_kind: class.PayloadKind, object_identity: usize) bool {
        return deferred_cleanup.enqueueReservedClassPayload(self, class_id, generation, payload, payload_kind, object_identity);
    }

    pub fn hasDeferredNativeCleanups(self: *const JSRuntime) bool {
        return deferred_cleanup.hasNative(self);
    }

    pub fn hasPendingDeferredClassPayloadFinalizers(self: *const JSRuntime) bool {
        return deferred_cleanup.hasPendingClassPayload(self);
    }

    pub fn isActiveDeferredClassPayloadFinalizerCallback(self: *const JSRuntime, object_identity: *anyopaque) bool {
        return deferred_cleanup.isActiveClassPayloadCallback(self, object_identity);
    }

    pub fn runDeferredNativeCleanupBudgeted(self: *JSRuntime, max_jobs: usize) usize {
        return deferred_cleanup.runNativeBudgeted(self, max_jobs);
    }

    pub fn runDeferredClassPayloadFinalizerBudgeted(self: *JSRuntime, max_jobs: usize) usize {
        return deferred_cleanup.runClassPayloadBudgeted(self, max_jobs);
    }

    pub fn drainDeferredNativeCleanups(self: *JSRuntime) void {
        deferred_cleanup.drainNative(self);
    }

    pub fn drainDeferredClassPayloadFinalizers(self: *JSRuntime) void {
        deferred_cleanup.drainClassPayload(self);
    }

    /// Deliver user callbacks only after the collector phase has returned to
    /// idle. Reentry from the callback is rejected while its GC request remains
    /// pending.
    inline fn drainDeferredClassPayloadFinalizersAtSafeBoundary(self: *JSRuntime) void {
        deferred_cleanup.drainClassPayloadAtSafeBoundary(self);
    }

    pub fn pendingDeferredNativeCleanupCountForTest(self: *const JSRuntime) usize {
        if (!builtin.is_test) @compileError("test-only helper");
        return deferred_cleanup.pendingNativeCount(self);
    }

    pub fn pendingDeferredClassPayloadFinalizerCountForTest(self: *const JSRuntime) usize {
        if (!builtin.is_test) @compileError("test-only helper");
        return deferred_cleanup.pendingClassPayloadCount(self);
    }

    pub fn beginBorrowedWeakCleanup(self: *JSRuntime) void {
        property_state.beginBorrowedCleanup(self);
    }

    pub fn endBorrowedWeakCleanup(self: *JSRuntime) void {
        property_state.endBorrowedCleanup(self);
    }

    pub fn borrowedWeakCleanupActive(self: *const JSRuntime) bool {
        return self.borrowed_weak_cleanup_active;
    }

    pub fn borrowedWeakCleanupIdentityCount(self: *const JSRuntime) usize {
        return self.borrowed_weak_cleanup_identities.items.len;
    }

    pub fn enqueueBorrowedWeakCleanupIdentity(self: *JSRuntime, identity: usize) !void {
        return property_state.enqueueBorrowedCleanupIdentity(self, identity);
    }

    pub fn borrowedWeakCleanupIdentityMatches(self: *const JSRuntime, identity: usize) bool {
        return property_state.borrowedCleanupIdentityMatches(self, identity);
    }

    pub inline fn borrowedWeakCleanupIdentityMatchesSlice(self: *const JSRuntime, start_index: usize, identity: usize) bool {
        return property_state.borrowedCleanupIdentityMatchesSlice(self, start_index, identity);
    }

    pub fn clearBorrowedWeakCleanupIdentities(self: *JSRuntime) void {
        property_state.clearBorrowedCleanup(self);
    }
};

/// Gate-only settlement boundary used after the CLI has finished draining
/// jobs. It is a module function rather than a JSRuntime method so this
/// internal diagnostic does not enlarge the public embedder API. It does not
/// start a fresh collection or hide an open marking cycle; it only completes
/// an irreversible destruction transaction so the gate can assert the
/// morgue's real exit invariant separately from the naturally timed endpoint.
pub fn settlePendingDestructionForGateStats(rt: *JSRuntime) void {
    rt.assertOwnerThread();
    rt.assertIdleForTeardown();
    std.debug.assert(!rt.gc_running);
    std.debug.assert(rt.gc.hot.phase == .none);
    std.debug.assert(rt.active_deferred_class_payload_finalizer == null);
    if (!rt.gc.morgue.pending) {
        @import("core/gc_trace_stw.zig").auditDoomedExitInvariant(rt);
        return;
    }

    rt.gc_running = true;
    defer rt.gc_running = false;
    @import("core/gc_trace_stw.zig").finishPendingDestruction(rt);
    _ = rt.finishDoomedCompletion(0);
}

test "value root frame activation restores nested scopes" {
    const rt = try JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    try std.testing.expect(rt.active_value_roots == null);
    {
        var outer = ValueRootFrame{};
        outer.activate(rt);
        defer outer.deactivate(rt);
        try std.testing.expect(rt.active_value_roots == &outer);

        {
            var inner = ValueRootFrame{};
            inner.activate(rt);
            defer inner.deactivate(rt);
            try std.testing.expect(rt.active_value_roots == &inner);
        }

        try std.testing.expect(rt.active_value_roots == &outer);
    }
    try std.testing.expect(rt.active_value_roots == null);
}

test "value handle uses runtime persistent root slot" {
    const rt = try JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const object = try Object.create(rt, class.ids.object, null);
    var handle = try rt.takeValueHandle(object.value());
    try std.testing.expectEqual(@as(usize, 1), rt.persistentRootCountForTest());
    try std.testing.expect(handle.get().is(.object));

    const released = handle.take();
    try std.testing.expectEqual(@as(usize, 0), rt.persistentRootCountForTest());
    try std.testing.expect(released.is(.object));

    handle.deinit();
    try std.testing.expectEqual(@as(usize, 0), rt.persistentRootCountForTest());
}

test "external memory accounting records debt and requests GC" {
    const rt = try JSRuntime.create(.{
        .allocator = std.testing.allocator,
        .gc_policy = .{
            .external_weight = 2,
            .major_debt_threshold = 16,
        },
    });
    defer rt.destroy();

    try std.testing.expectEqual(@as(usize, 0), rt.externalMemoryBytes());
    try std.testing.expectEqual(@as(usize, 0), rt.allocationDebtBytes());
    try std.testing.expect(!rt.gcPendingForTest());

    var token = try rt.reportExternalAlloc(8);
    var duplicate_token = token;
    try std.testing.expectEqual(@as(usize, 8), rt.externalMemoryBytes());
    try std.testing.expectEqual(@as(usize, 16), rt.allocationDebtBytes());
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().external_token_count);
    try std.testing.expectEqual(@as(usize, 8), rt.gcStats().external_token_bytes);
    try std.testing.expect(rt.gcPendingForTest());
    try std.testing.expectEqual(@as(?gc.RequestReason, gc.RequestReason.allocation_debt), rt.gcLastRequestReasonForTest());

    const result = try rt.pollGC(null, .normal);
    try std.testing.expectEqual(@as(usize, 0), result.freed_objects);
    try std.testing.expectEqual(@as(usize, 0), rt.allocationDebtBytes());
    try std.testing.expectEqual(@as(usize, 8), rt.externalMemoryBytes());
    try std.testing.expect(!rt.gcPendingForTest());

    token.release();
    try std.testing.expectEqual(@as(usize, 0), rt.externalMemoryBytes());
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().external_token_count);
    duplicate_token.release();
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().external_invalid_release_count);
    try std.testing.expectEqual(@as(usize, 0), rt.externalMemoryBytes());
    token.release();
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().external_invalid_release_count);
}

test "external hard memory pressure requests urgent major gc" {
    const rt = try JSRuntime.create(.{
        .allocator = std.testing.allocator,
        .gc_policy = .{
            .external_hard_limit = 8,
            .major_debt_threshold = std.math.maxInt(usize),
        },
    });
    defer rt.destroy();

    var token = try rt.reportExternalAlloc(8);
    defer token.release();

    const pending = rt.gcStats();
    try std.testing.expect(pending.pending_major);
    try std.testing.expectEqual(@as(?gc.RequestReason, gc.RequestReason.external_memory), pending.pending_request_reason);
    try std.testing.expectEqual(@as(?gc.RequestUrgency, gc.RequestUrgency.urgent), pending.pending_request_urgency);

    _ = try rt.pollGC(null, .callback_boundary);
    if (comptime memory.force_gc_on_allocation_enabled) {
        try std.testing.expect(rt.gcStats().major_gc_count >= 1);
    } else {
        try std.testing.expectEqual(@as(usize, 1), rt.gcStats().major_gc_count);
    }
    try std.testing.expect(!rt.gcPendingForTest());
}

test "VM stack arena default fill matches VmStackArena{}" {
    var arena: VmStackArena = undefined;
    arena.initDefault();
    try std.testing.expectEqualDeep(VmStackArena{}, arena);
    try std.testing.expectEqual(@as(usize, 1552), @sizeOf(VmStackArena));
    const empty: []JSValue = &.{};
    try std.testing.expectEqual(empty.ptr, arena.chunks[0].ptr);
    try std.testing.expectEqual(@as(usize, 0), arena.chunks[0].len);

    const account = try mem_ops.createTestRuntime(std.testing.allocator);
    defer account.destroy();
    arena.deinit(account.nativeAllocator());
    try std.testing.expectEqualDeep(VmStackArena{}, arena);
    try std.testing.expect(!mem_ops.hasOutstandingAllocations(account));
}

test "VM stack arena allocates and reuses a compact first chunk" {
    try std.testing.expectEqual(
        VmStackArena.first_chunk_bytes / @sizeOf(JSValue),
        VmStackArena.first_chunk_slots,
    );

    const account = try mem_ops.createTestRuntime(std.testing.allocator);
    defer account.destroy();
    var arena: VmStackArena = .{};
    defer arena.deinit(account.nativeAllocator());

    const initial_mark = arena.mark();
    const first = arena.carve(account, 3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), first.len);
    try std.testing.expectEqual(@as(usize, 1), arena.chunk_count);
    try std.testing.expectEqual(@as(usize, 0), arena.active);
    try std.testing.expectEqual(VmStackArena.first_chunk_slots, arena.chunks[0].len);
    try std.testing.expectEqual(VmStackArena.first_chunk_bytes, account.diagnostics.allocations.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), account.diagnostics.allocations.allocation_count);

    arena.restore(initial_mark);
    const allocations_before_reuse = account.diagnostics.allocations.allocation_count;
    const reused = arena.carve(account, 3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(reused.ptr));
    try std.testing.expectEqual(allocations_before_reuse, account.diagnostics.allocations.allocation_count);
    try std.testing.expectEqual(VmStackArena.first_chunk_bytes, account.diagnostics.allocations.allocated_bytes);
}

test "VM stack arena active miss is pure before authoritative second chunk carve" {
    const account = try mem_ops.createTestRuntime(std.testing.allocator);
    defer account.destroy();
    var arena: VmStackArena = .{};
    defer arena.deinit(account.nativeAllocator());

    _ = arena.carve(account, VmStackArena.first_chunk_slots) orelse
        return error.TestUnexpectedResult;
    const full_mark = arena.mark();
    const bytes_before_miss = account.diagnostics.allocations.allocated_bytes;
    const allocations_before_miss = account.diagnostics.allocations.allocation_count;

    try std.testing.expect(arena.carveActiveMarked(1) == null);
    try std.testing.expectEqual(full_mark, arena.mark());
    try std.testing.expectEqual(bytes_before_miss, account.diagnostics.allocations.allocated_bytes);
    try std.testing.expectEqual(allocations_before_miss, account.diagnostics.allocations.allocation_count);
    try std.testing.expectEqual(@as(usize, 1), arena.chunk_count);

    const second = arena.carve(account, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqual(@as(usize, 2), arena.chunk_count);
    try std.testing.expectEqual(@as(usize, 1), arena.active);
    try std.testing.expectEqual(VmStackArena.chunk_slots, arena.chunks[1].len);
    try std.testing.expectEqual(@as(usize, 1), arena.used[1]);
    try std.testing.expectEqual(
        VmStackArena.first_chunk_bytes +
            VmStackArena.chunk_slots * @sizeOf(JSValue),
        account.diagnostics.allocations.allocated_bytes,
    );
    try std.testing.expectEqual(allocations_before_miss + 1, account.diagnostics.allocations.allocation_count);
}

test "VM stack arena large first carve retains the maximum chunk size" {
    const account = try mem_ops.createTestRuntime(std.testing.allocator);
    defer account.destroy();
    var arena: VmStackArena = .{};
    defer arena.deinit(account.nativeAllocator());

    const requested = VmStackArena.first_chunk_slots + 1;
    const window = arena.carve(account, requested) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(requested, window.len);
    try std.testing.expectEqual(@as(usize, 1), arena.chunk_count);
    try std.testing.expectEqual(VmStackArena.chunk_slots, arena.chunks[0].len);
    try std.testing.expectEqual(
        VmStackArena.chunk_slots * @sizeOf(JSValue),
        account.diagnostics.allocations.allocated_bytes,
    );
    try std.testing.expectEqual(@as(usize, 1), account.diagnostics.allocations.allocation_count);
}

test "VM stack arena oversized carve is rejected without state or accounting changes" {
    const account = try mem_ops.createTestRuntime(std.testing.allocator);
    defer account.destroy();
    var arena: VmStackArena = .{};
    defer arena.deinit(account.nativeAllocator());

    const before = arena.mark();
    try std.testing.expect(arena.carve(account, VmStackArena.chunk_slots + 1) == null);
    try std.testing.expectEqual(before, arena.mark());
    try std.testing.expectEqual(@as(usize, 0), arena.chunk_count);
    try std.testing.expectEqual(@as(usize, 0), account.diagnostics.allocations.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), account.diagnostics.allocations.allocation_count);
}

test "VM stack arena allocation failure is retryable and keeps accounting balanced" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const account = try mem_ops.createTestRuntime(failing_allocator.allocator());
    defer account.destroy();
    var arena: VmStackArena = .{};
    defer arena.deinit(account.nativeAllocator());

    failing_allocator.fail_index = failing_allocator.alloc_index;
    const before = arena.mark();
    try std.testing.expect(arena.carve(account, 1) == null);
    try std.testing.expectEqual(before, arena.mark());
    try std.testing.expectEqual(@as(usize, 0), arena.chunk_count);
    try std.testing.expectEqual(@as(usize, 0), account.diagnostics.allocations.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), account.diagnostics.allocations.allocation_count);

    failing_allocator.fail_index = std.math.maxInt(usize);
    const retry = arena.carve(account, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), retry.len);
    try std.testing.expectEqual(@as(usize, 1), arena.chunk_count);
    try std.testing.expectEqual(VmStackArena.first_chunk_bytes, account.diagnostics.allocations.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), account.diagnostics.allocations.allocation_count);

    _ = arena.carve(account, VmStackArena.first_chunk_slots - 1) orelse
        return error.TestUnexpectedResult;
    const full_first_mark = arena.mark();
    failing_allocator.fail_index = failing_allocator.alloc_index;
    try std.testing.expect(arena.carve(account, 1) == null);
    try std.testing.expectEqual(full_first_mark, arena.mark());
    try std.testing.expectEqual(@as(usize, 1), arena.chunk_count);
    try std.testing.expectEqual(@as(usize, 0), arena.active);
    try std.testing.expectEqual(@as(usize, 0), arena.chunks[1].len);
    try std.testing.expectEqual(@as(usize, 0), arena.used[1]);
    try std.testing.expectEqual(VmStackArena.first_chunk_bytes, account.diagnostics.allocations.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), account.diagnostics.allocations.allocation_count);

    failing_allocator.fail_index = std.math.maxInt(usize);
    const second_retry = arena.carve(account, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), second_retry.len);
    try std.testing.expectEqual(@as(usize, 2), arena.chunk_count);
    try std.testing.expectEqual(@as(usize, 1), arena.active);
    try std.testing.expectEqual(VmStackArena.chunk_slots, arena.chunks[1].len);
    try std.testing.expectEqual(@as(usize, 1), arena.used[1]);
    try std.testing.expectEqual(
        VmStackArena.first_chunk_bytes +
            VmStackArena.chunk_slots * @sizeOf(JSValue),
        account.diagnostics.allocations.allocated_bytes,
    );
    try std.testing.expectEqual(@as(usize, 2), account.diagnostics.allocations.allocation_count);

    arena.deinit(account.nativeAllocator());
    try std.testing.expectEqual(@as(usize, 0), account.diagnostics.allocations.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), account.diagnostics.allocations.allocation_count);
}

test "runtime allocator facades share memory accounting" {
    const rt = try JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();

    const baseline = rt.diagnostics.allocations.allocated_bytes;
    const current = try rt.nativeAllocator().alloc(u8, 2048);
    var current_live = true;
    defer if (current_live) rt.nativeAllocator().free(current);
    try std.testing.expectEqual(baseline + current.len, rt.diagnostics.allocations.allocated_bytes);

    const persistent = try rt.nativeAllocator().alloc(u8, 4096);
    var persistent_live = true;
    defer if (persistent_live) rt.nativeAllocator().free(persistent);
    try std.testing.expectEqual(baseline + current.len + persistent.len, rt.diagnostics.allocations.allocated_bytes);

    rt.nativeAllocator().free(persistent);
    persistent_live = false;
    try std.testing.expectEqual(baseline + current.len, rt.diagnostics.allocations.allocated_bytes);
    rt.nativeAllocator().free(current);
    current_live = false;
    try std.testing.expectEqual(baseline, rt.diagnostics.allocations.allocated_bytes);
}

test "runtime and context init-deinit are leak free" {
    for (0..3) |_| {
        const rt = try JSRuntime.create(.{ .allocator = std.testing.allocator });
        const ctx1 = try context_mod.JSContext.create(rt, .{});
        const ctx2 = try context_mod.JSContext.create(rt, .{});
        ctx2.destroy();
        ctx1.destroy();
        rt.destroy();
    }
}
