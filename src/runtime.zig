//! Runtime-wide ownership, allocation, GC scheduling, roots, and host policy.
//!
//! `JSRuntime` owns the atom/class/shape registries, allocation diagnostics, job FIFO,
//! contexts, host native entries, and persistent handles. It is
//! owner-thread confined except at the explicitly synchronized host seams;
//! handles and root frames keep values alive but never transfer Runtime
//! ownership. QuickJS source map: `JSRuntime` and its registries at
//! quickjs.c. This is core infrastructure: exec/runtime/binding may
//! import it, while this module must not import those higher layers.

const runtime_owner = @This();
pub const native_allocation = @import("runtime_alloc.zig");

/// Allocation tests can explicitly select standalone/slab routes before use.
pub fn createAllocationTestRuntime(allocator: std.mem.Allocator) !*JSRuntime {
    if (!builtin.is_test) @compileError("test fixture only");
    const rt = try JSRuntime.create(allocator, .{});
    rt.gc.cell_storage.block_heap = null;
    rt.gc.cell_storage.nursery = null;
    rt.gc.cell_storage.slab_enabled = false;
    return rt;
}
const std = @import("std");
const builtin = @import("builtin");

const atom = @import("core/atom.zig");
const class = @import("core/class.zig");
const AtomTable = atom.AtomTable;
const ClassTable = class.Table;
const ShapeRegistry = shape.Registry;
const gc_mod = @import("core/gc.zig");
const GC = gc_mod.Registry;
const gc_roots_mod = @import("core/gc_roots.zig");
const gc_driver = @import("core/gc_driver.zig");
const native_entry = @import("core/native_entry.zig");
const job_mod = @import("core/jobs.zig");
const object_mod = @import("core/object.zig");
const shape = @import("core/shape.zig");
const string = @import("core/string.zig");
const var_ref_mod = @import("core/var_ref.zig");
const JSValue = @import("core/value.zig").JSValue;
const Object = object_mod.Object;
const profile = @import("core/profile.zig");
const property = @import("core/property.zig");
const context_mod = @import("core/context.zig");
const context_registry = @import("core/context_registry.zig");
const errors = @import("core/errors.zig");
const thread_stack = @import("core/thread_stack.zig");

pub const default_stack_size = 1024 * 1024;
pub const default_gc_threshold = 256 * 1024;
/// Native stack budget for the recursion guard: once this many bytes have
/// been consumed below the outermost eval frame, recursion becomes a
/// catchable error. QuickJS uses 1 MiB (`JS_DEFAULT_STACK_SIZE`); a zjs
/// native call level -- a builtin calling back into JavaScript -- costs two
/// to four times a QuickJS one, so 4 MiB gives callback recursion (`map` over a deep
/// tree, replacer and comparator callbacks) about QuickJS's depth. The
/// limit never reaches past the current thread's own stack
/// (`StackBudget.armNativeLimit`), so a small-stack thread is safe too.
pub const default_native_stack_size = 4 * 1024 * 1024;
// Debug and ReleaseSafe codegen have materially larger parser/VM frames
// (about 3.4x and 1.6x ReleaseFast's per nesting level). Scale the physical
// allowance so each represents roughly the logical recursion budget of the
// shipped ReleaseFast build.
const initial_native_stack_size = switch (builtin.mode) {
    .Debug => default_native_stack_size * 4,
    .ReleaseSafe => default_native_stack_size * 2,
    .ReleaseFast, .ReleaseSmall => default_native_stack_size,
};

pub const InterruptHandler = *const fn (*JSRuntime, ?*anyopaque) bool;

/// Host interrupt callback and its borrowed context.
pub const Interrupt = struct {
    handler: InterruptHandler,
    context: ?*anyopaque,
};

/// Runtime-wide dynamic-import loader authority. A Runtime can execute many
/// Realms; the active Realm is supplied to the callback at invocation time.
pub const DynamicImportLoader = struct {
    callback: ?context_mod.DynamicImportCallback = null,
    userdata: ?*anyopaque = null,
};

/// Scoped loader override, restored by `deinit` in LIFO order. `deinit` is
/// idempotent so error-path defers are safe.
pub const DynamicImportLoaderScope = struct {
    runtime: *JSRuntime,
    previous: DynamicImportLoader,
    installed: DynamicImportLoader,
    active: bool = true,

    pub fn deinit(self: *DynamicImportLoaderScope) void {
        if (!self.active) return;
        self.runtime.assertOwnerThread();
        // An inner scope still installed means scopes closed out of order;
        // restoring here would reinstate a stale loader.
        const current = self.runtime.dynamic_import_loader;
        std.debug.assert(current.callback == self.installed.callback and current.userdata == self.installed.userdata);
        self.runtime.dynamic_import_loader = self.previous;
        self.active = false;
    }
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

/// Call-depth and stack-byte budgets of one runtime (`JSRuntime.stack`).
pub const StackBudget = struct {
    /// Runtime-shared logical call depth, including zero-byte nested entries.
    call_depth: usize = 0,
    /// Limit for both logical depth and accumulated planned VM-frame bytes.
    limit: usize = default_stack_size,
    /// Planned bytes for active bytecode frames, including tail-call callers
    /// whose physical Entry storage has been reused.
    bytecode_bytes: usize = 0,
    /// Nesting count for calls admitted through `enterCallDepth`; it bounds
    /// host C-stack recursion independently of inline VM call depth.
    native_call_depth: usize = 0,
    /// Lower bound for the current thread's call stack. Zero disables the
    /// check or means it has not yet been initialized.
    native_limit: usize = 0,
    /// Address captured in an outermost JS entry frame, not the OS stack's
    /// allocation start. GC uses it if the OS stack high bound is unavailable.
    native_top: usize = 0,
    /// Configured byte budget for descending below `native_top`.
    native_size: usize = default_native_stack_size,
    /// Frame-window template derived from `limit`; see `JSRuntime.setStackSize`.
    frame_storage: VmStackStorage = VmStackStorage.frameWindowForLimit(default_stack_size),

    /// Room the guard leaves at the low end of the thread's stack for the
    /// frames between two checks and for raising the overflow error.
    pub const thread_stack_reserve = 256 * 1024;

    /// Derive `native_limit` from `native_top`; a zero budget disables it.
    /// The limit stays `thread_stack_reserve` above the low end of the
    /// thread's stack whatever the budget, so the guard's catchable error
    /// always comes before a real stack overflow.
    pub fn armNativeLimit(self: *StackBudget) void {
        if (self.native_size == 0) {
            self.native_limit = 0;
            return;
        }
        var limit = self.native_top -| self.native_size;
        if (thread_stack.bounds()) |stack| limit = @max(limit, stack.low +| thread_stack_reserve);
        self.native_limit = limit;
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
            const chunk = rt.allocNative(JSValue, allocation_slots) catch return null;
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

pub const MemoryUsage = struct {
    /// Native allocation counters are unavailable when diagnostic instrumentation is off.
    allocation_tracking_enabled: bool = native_allocation.diagnostic_accounting_enabled,
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
    /// A var-ref cell slice under construction. VarRef carriers keep stable
    /// addresses; their binding values are traced through actual cell slots.
    cells: *const []*var_ref_mod.VarRef,
    /// Borrowed counterpart of `cells`; keeps the referenced cell/value graph
    /// live without taking temporary per-cell references.
    borrowed_cells: []const *var_ref_mod.VarRef,
};

pub const ValueRootBuffer = roots_mod.ValueRootBuffer;

/// A GC header (Shape, Module, VarRef, FunctionBytecode, realm) named as a
/// root for a mutation or construction window. Tracing does not treat a Zig
/// `*Shape` local as a root unless it is named here.
/// A non-rewritable root for a stable-address carrier (for example Shape or
/// FunctionBytecode). Movable values must use writable value/object slots.
pub const HeaderRootValue = struct {
    header: *gc_mod.Header,
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
    /// slice header, not to its bytes, so `AtomListBuilder` reallocation
    /// mid-build stays covered and the partially filled array is traced at its
    /// current length.
    list: *const []atom.Atom,
    /// Fixed immutable key snapshot. Atom identities never relocate.
    borrowed: []const atom.Atom,
};

/// Production (non-test) does not list-link scalar Zig locals; those wait for
/// conservative stack/register capture. Tests link every activate.
pub const value_root_link_containers_only = !builtin.is_test;

/// Scalar scope helpers exist only when scalar frames can actually be linked.
/// In production tracing builds the policy above rejects them, so keeping their
/// storage and frame would preserve stack/TLS work without adding a root.
const value_root_scalar_scopes_enabled = !value_root_link_containers_only;

pub const ValueRootFrame = struct {
    previous: ?*const ValueRootFrame = null,
    slices: []const ValueRootSlice = &.{},
    values: []const *JSValue = &.{},
    objects: []const *?*Object = &.{},
    headers: []const HeaderRootValue = &.{},
    /// TGC S3 §4 class B atom-id roots; see `AtomRootSlot`.
    atoms: []const AtomRootSlot = &.{},
    /// Whether `activate` linked this frame. Only the container-only policy
    /// skips frames, so only it needs to remember which ones it linked.
    linked: if (value_root_link_containers_only) bool else void =
        if (value_root_link_containers_only) false else {},

    /// True when this frame roots a native JSValue/cell array or window.
    /// Conservative scanning of the C stack sees the backing pointer, not the
    /// values stored behind it, so these must stay precise-rooted. Scalar
    /// `.values` / `.objects` slots that point at Zig locals can wait for a
    /// register/stack scanner (design §7.1).
    ///
    /// A frame without any window is not linked in production, whatever its
    /// `.values` pointers name, so heap-backed values must be rooted through
    /// `.slices` (see `RootedValueCopies`).
    inline fn hasNativeWindow(self: *const ValueRootFrame) bool {
        return self.slices.len != 0;
    }

    /// Atom ids can never be recovered by the conservative scanner, so a
    /// frame naming any must link even in the container-only production
    /// policy that drops scalar JSValue frames.
    inline fn hasAtomRoots(self: *const ValueRootFrame) bool {
        return self.atoms.len != 0;
    }

    inline fn hasHeaderRoots(self: *const ValueRootFrame) bool {
        return self.headers.len != 0;
    }

    /// Activate this frame at its final stack address. The matching
    /// `deactivate` must run before the frame or any referenced root storage
    /// leaves scope. Production skips ordinary scalar value/object frames;
    /// native windows, atom roots and stable header roots always link.
    pub inline fn activate(self: *ValueRootFrame, rt: *JSRuntime) void {
        rt.roots.assertMutable();
        if (comptime value_root_link_containers_only) {
            if (!self.hasNativeWindow() and !self.hasAtomRoots() and !self.hasHeaderRoots()) {
                return;
            }
            self.linked = true;
        }
        std.debug.assert(rt.active_value_roots != self);
        self.previous = rt.active_value_roots;
        rt.active_value_roots = self;
    }

    /// Restore the frame that was active before `activate`. Root frames are a
    /// strict LIFO stack; the assertion localizes mismatched scope teardown at
    /// the registration seam. A frame the container-only policy never linked
    /// is a no-op; a linked frame that is not the head is a teardown-order bug
    /// that would leave a dead frame on the chain.
    pub inline fn deactivate(self: *ValueRootFrame, rt: *JSRuntime) void {
        rt.roots.assertMutable();
        if (comptime value_root_link_containers_only) {
            if (!self.linked) return;
            self.linked = false;
        }
        if (rt.active_value_roots != self) @panic("ValueRootFrame deactivated out of LIFO order");
        rt.active_value_roots = self.previous;
        self.previous = null;
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

        storage: [count]AtomRootSlot = undefined,
        frame: ValueRootFrame = .{},

        /// Bind the frame to this scope's storage at its final stack address,
        /// then link it — same reason as `ValueRootScope.activate`.
        pub inline fn activate(self: *Self, rt: *JSRuntime) void {
            self.frame.atoms = &self.storage;
            self.frame.activate(rt);
        }

        pub inline fn deactivate(self: *Self, rt: *JSRuntime) void {
            self.frame.deactivate(rt);
        }
    };
}

/// Build an inactive `AtomRootScope` over `slots`, a tuple of `*const Atom`
/// (or `*Atom`). The caller activates it; see `AtomRootScope`.
pub inline fn rootAtoms(slots: anytype) AtomRootScope(slots.len) {
    var scope: AtomRootScope(slots.len) = .{};
    inline for (slots, 0..) |slot, index| scope.storage[index] = .{ .single = slot };
    return scope;
}

/// Root a native `[]Atom` array through its slice header, so appends and the
/// reallocations they cause stay covered for the whole build window.
pub inline fn rootAtomList(list: *const []atom.Atom) AtomRootScope(1) {
    var scope: AtomRootScope(1) = .{};
    scope.storage[0] = .{ .list = list };
    return scope;
}

/// Root several `[]Atom` arrays (and/or single ids) with one frame.
pub inline fn rootAtomSlots(slots: anytype) AtomRootScope(slots.len) {
    var scope: AtomRootScope(slots.len) = .{};
    inline for (slots, 0..) |slot, index| scope.storage[index] = slot;
    return scope;
}

pub const RootTraceError = gc_roots_mod.RootTraceError;
pub const RootVisitor = gc_roots_mod.RootVisitor;

/// Stack-local root for a Job after it has left `job_queue` and before its
/// payload is released. The FIFO already owns the canonical edge walk in
/// `Job.traceRoots`; this record only keeps that same walk published while
/// exec runs the dequeued entry.
///
/// The chain is thread-local rather than a JSRuntime field: jobs execute on
/// their Runtime's owner thread and nested drains must be LIFO. A nested
/// drain for a different Runtime is harmless; tracing filters each record by
/// its typed Runtime pointer.
pub const ActiveJobRoot = struct {
    previous: ?*const ActiveJobRoot = null,
    runtime: *JSRuntime = undefined,
    job: *job_mod.Job = undefined,

    pub inline fn activate(self: *ActiveJobRoot, rt: *JSRuntime, job: *job_mod.Job) void {
        rt.assertOwnerThread();
        std.debug.assert(job.runtime == rt);
        std.debug.assert(active_job_root_head != self);
        self.previous = active_job_root_head;
        self.runtime = rt;
        self.job = job;
        active_job_root_head = self;
    }

    pub inline fn deactivate(self: *ActiveJobRoot, rt: *JSRuntime) void {
        rt.assertOwnerThread();
        std.debug.assert(self.runtime == rt);
        std.debug.assert(active_job_root_head == self);
        active_job_root_head = self.previous;
        self.previous = null;
        self.runtime = undefined;
        self.job = undefined;
    }
};

threadlocal var active_job_root_head: ?*const ActiveJobRoot = null;

comptime {
    std.debug.assert(@sizeOf(ActiveJobRoot) == 3 * @sizeOf(usize));
}

/// First word of the exec-owned `active_invocation` record (design §7.1).
/// Core only knows this prefix; the rest of the record is exec-private.
/// Exec fills `traceRoots` with a no-fail live-window walk.
pub const ActiveInvocationTrace = struct {
    traceRoots: *const fn (invocation: *anyopaque, visitor: *RootVisitor) RootTraceError!void,
};

/// Exec-owned snapshot of the process-global Atomics.waitAsync waiter
/// registry (design §7.1). Core calls this from `traceActiveRoots`. Exec
/// retains Promise roots under the waiter mutex, unlocks, then visits.
pub const AtomicsWaitAsyncTrace = *const fn (rt: *anyopaque, visitor: *RootVisitor) RootTraceError!void;

pub var trace_atomics_wait_async: ?AtomicsWaitAsyncTrace = null;

const native_bindings = @import("core/native_bindings.zig");
const property_state = @import("core/property_state.zig");
const string_cache = @import("core/string_cache.zig");
const exception_state = @import("core/exception.zig");
const execution = @import("core/execution.zig");
const gc_weak = @import("core/gc_weak.zig");
const roots_mod = @import("core/roots.zig");
const gc_scope = @import("core/gc_scope.zig");
pub const NoGcScope = gc_scope.NoGcScope;
pub const RootSet = roots_mod.RootSet;
pub const RootProvider = roots_mod.RootProvider;
pub const RootSlot = roots_mod.RootSlot;
pub const ExactValueRoots = roots_mod.ExactValueRoots;
pub const RootedValueRef = roots_mod.RootedValueRef;
pub const MutableRootedValueRef = roots_mod.MutableRootedValueRef;
pub const WeakPersistentCallback = roots_mod.WeakPersistentCallback;
pub const WeakRootSlot = roots_mod.WeakRootSlot;
pub const JSValueHandle = roots_mod.JSValueHandle;
pub const LocalHandle = roots_mod.LocalHandle;
pub const HandleScope = roots_mod.HandleScope;
pub const WeakPersistentValue = roots_mod.WeakPersistentValue;
pub const NativePin = roots_mod.NativePin;
pub const pinValueForNative = roots_mod.pinValueForNative;
pub const pinHeaderForNative = roots_mod.pinHeaderForNative;

/// A Runtime and every Realm/heap structure owned by it (class ids included:
/// each Runtime has its own ClassTable) are mutated only by the thread that
/// initialized the Runtime.
pub const RuntimeMutationError = error{WrongRuntimeThread};

pub const JSRuntime = struct {
    /// Iterations a long native loop runs between interrupt polls.
    pub const native_poll_interval: u32 = 4096;

    pub const Options = struct {
        /// Optional diagnostic clock. Its borrowed state must outlive the Runtime.
        diagnostic_clock: ?DiagnosticClock = null,
        microtask_policy: MicrotaskPolicy = .auto,
        memory_limit: ?usize = null,
        /// Initial collection threshold; collections adjust the next threshold.
        gc_threshold: usize = default_gc_threshold,
        gc_policy: gc_mod.Policy = .{},
        stack_size: usize = default_stack_size,
        native_stack_size: usize = initial_native_stack_size,
        interrupt_handler: ?InterruptHandler = null,
        interrupt_context: ?*anyopaque = null,
        can_block: bool = false,
    };

    /// Host-provided diagnostic time in monotonic nanoseconds. Called on the
    /// Runtime owner thread, including inside collection; must not allocate,
    /// reenter the engine, or mutate Runtime state. Never used for GC scheduling.
    pub const DiagnosticClock = struct {
        context: ?*anyopaque = null,
        nowNanos: *const fn (?*anyopaque) u64,
    };

    // Ownership and engine-wide registries.

    /// Allocator that owns this stable Runtime allocation.
    allocator: std.mem.Allocator,
    owner_thread_id: std.Thread.Id,
    gc: *GC,
    atoms: *AtomTable,
    classes: *ClassTable,
    shapes: *ShapeRegistry,
    /// Optional allocation counters and test-only failure injection.
    allocation_diagnostics: native_allocation.AllocationDiagnostics = .{},
    diagnostic_clock: ?DiagnosticClock = null,

    // Realms and host services.

    contexts: context_registry.Lists = .{},
    dynamic_import_loader: DynamicImportLoader = .{},
    native_bindings: native_bindings.Registry = .{},
    /// The regexp executor's interrupt-poll countdown, shared by every match.
    regexp_interrupt_counter: i32 = 10_000,
    /// Native-loop iterations left until the next interrupt poll
    /// (`pollNativeWork`), shared by every native loop.
    native_poll_countdown: u32 = native_poll_interval,
    interrupt: ?Interrupt = null,
    termination_requested: std.atomic.Value(bool) = .init(false),
    can_block: bool = false,
    /// Cross-thread, allocation-free wake signal for host completions that
    /// must be consumed on this Runtime's owner thread. Atomics.waitAsync is
    /// the first producer; the signal carries no JS state and is reset only
    /// while the producer registry mutex excludes a lost-wakeup race.
    host_completion_event: std.Io.Event = .unset,
    opcode_profile: ?*profile.OpcodeProfile = null,

    // Execution and stack accounting.

    stack: StackBudget = .{},
    /// Per-runtime VM value-stack arena for bytecode call frames.
    vm_stack: VmStackArena align(64) = .{},
    /// Borrowed exec-owned authority for the currently running bytecode
    /// invocation. Core deliberately keeps this opaque: synchronous native
    /// callbacks recover the concrete Machine through exec without creating
    /// a core -> exec import cycle.
    active_invocation: ?*anyopaque = null,
    /// Exec-owned native environment of the innermost native call.
    active_native_call: ?*const anyopaque = null,
    host_invocation: ?execution.HostInvocation = null,
    small_inline: execution.SmallInline = .{},
    /// Head of the stack-local observable backtrace chain. Native calls and
    /// synchronous native fences replace it on entry and restore it on return.
    current_backtrace_frame: ?*context_mod.ActiveBacktraceFrame = null,
    formatting_error_stack: bool = false,

    // Pending exception.

    exception: exception_state.Pending = .{},

    // Roots, collection, and jobs.

    /// Host handles and root providers.
    roots: roots_mod.RootSet = .{},
    active_no_gc_scope: if (gc_scope.checks_enabled) ?*NoGcScope else void = if (gc_scope.checks_enabled) null else {},
    active_value_roots: ?*const ValueRootFrame = null,
    /// Test-only root-scan override (`forcePreciseRootScanForTest`). Pacing
    /// tests call the engine-trigger entry points from a quiescent test frame
    /// with dropGcPtr-scrubbed locals; the mode-derived `.engine_active`
    /// policy would conservatively retain their ghosts and break
    /// deterministic reclamation assertions. Void outside test builds.
    test_root_scan_override: if (builtin.is_test) ?gc_mod.RootScan else void =
        if (builtin.is_test) null else {},
    job_queue: job_mod.Queue = undefined,
    microtasks: job_mod.Checkpoint = .{},
    /// WeakRef [[KeptAlive]]. Traced as a root and cleared at job end.
    weakref_kept_alive: std.ArrayListUnmanaged(JSValue) = .empty, // gc-slot: heap
    /// Weak identities of `weakref_kept_alive`'s targets, so each is kept once.
    weakref_kept_identities: std.AutoHashMapUnmanaged(usize, void) = .empty,

    // Object side tables and caches.

    weak: gc_weak.Registry = .{},
    borrowed_reference_holders: std.ArrayListUnmanaged(*Object) = .empty,
    borrowed_weak_cleanup: property_state.BorrowedWeakCleanup = .{},
    auto_init_descriptors: std.ArrayListUnmanaged(*property.AutoInit) = .empty,
    strings: string_cache.Cache = .{},

    /// Zero means timing is unavailable when no diagnostic hook was installed.
    pub fn diagnosticNanos(self: *const JSRuntime) u64 {
        const clock = self.diagnostic_clock orelse return 0;
        return clock.nowNanos(clock.context);
    }

    pub fn diagnosticElapsedSince(self: *const JSRuntime, start: u64) u64 {
        return self.diagnosticNanos() -| start;
    }

    /// Returns an owned, address-stable runtime. Caller releases it with `destroy`.
    /// The host allocator's backing state must outlive the Runtime.
    pub fn create(allocator: std.mem.Allocator, options: Options) !*JSRuntime {
        const rt = try allocator.create(JSRuntime);
        errdefer allocator.destroy(rt);
        const native_stack_top = @frameAddress();

        const gc = try GC.create(allocator, .{
            .policy = options.gc_policy,
            .threshold = options.gc_threshold,
            .memory_limit = options.memory_limit,
        });
        errdefer gc.destroy();

        // The tables below keep allocators bound to `rt` but must not allocate
        // through them before `rt` is fully initialized. Give the allocation
        // path defined state anyway, and check below that nothing allocated.
        rt.allocator = allocator;
        rt.gc = gc;
        rt.allocation_diagnostics = .{};
        const storage_allocator = rt.probedNativeAllocator();
        const native_allocator = native_allocation.nativeAllocatorWithBacking(rt, allocator);
        const atoms = try AtomTable.create(allocator, .{
            .storage_allocator = storage_allocator,
            .native_allocator = native_allocator,
            .gc_registry = gc,
        });
        errdefer atoms.destroy();
        const classes = try ClassTable.create(allocator, storage_allocator, atoms);
        errdefer classes.destroy();
        const shapes = try ShapeRegistry.create(allocator, storage_allocator, atoms, gc);
        errdefer shapes.destroy();
        std.debug.assert(std.meta.eql(rt.allocation_diagnostics, native_allocation.AllocationDiagnostics{}));

        // Establish defaults and option-derived state before any subsystem can
        // read the runtime. Every owned subsystem is already constructed;
        // GC callbacks remain disabled until the complete Runtime is activated.
        rt.* = .{
            .diagnostic_clock = options.diagnostic_clock,
            .allocator = allocator,
            .owner_thread_id = std.Thread.getCurrentId(),
            .gc = gc,
            .atoms = atoms,
            .classes = classes,
            .shapes = shapes,
            .job_queue = job_mod.Queue.init(rt),
            .microtasks = .{ .policy = options.microtask_policy },
            .stack = .{
                .limit = options.stack_size,
                .frame_storage = VmStackStorage.frameWindowForLimit(options.stack_size),
                .native_size = options.native_stack_size,
                // Outermost execution entries re-arm this construction baseline.
                .native_top = native_stack_top,
            },
            .interrupt = if (options.interrupt_handler) |handler| .{ .handler = handler, .context = options.interrupt_context } else null,
            .can_block = options.can_block,
        };

        rt.stack.armNativeLimit();

        // Every owned subsystem and root set is ready before collection can run.
        gc.activate(rt, .{
            .retry = retryHeapLimitOnce,
            .notify = triggerGCOnAllocation,
        });
        return rt;
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

    /// True while any JS or native call frame of this runtime is active.
    pub fn isExecuting(self: *const JSRuntime) bool {
        return self.stack.call_depth != 0 or self.stack.native_call_depth != 0 or self.active_invocation != null;
    }

    pub fn assertExecutionAllowed(self: *const JSRuntime) void {
        if (self.roots.isTracing()) @panic("JavaScript execution during tracing");
    }

    /// True while a collection or a collector phase (major driver, minor,
    /// destruction) is running; nested collection requests stay pending.
    pub inline fn collectorBusy(self: *const JSRuntime) bool {
        return self.gc.hot.collecting or self.gc.hot.phase != .none;
    }

    pub fn assertGCAllowed(self: *const JSRuntime) void {
        if (comptime gc_scope.checks_enabled) {
            if (self.active_no_gc_scope != null) @panic("collection during no-GC scope");
        }
    }

    fn deinit(self: *JSRuntime) void {
        self.assertOwnerThread();
        self.assertIdleForTeardown();
        // The resident host invocation (exec/call_site.zig) is only ever
        // published for the duration of a call, so an idle runtime retires it
        // here; a runtime destroyed mid-call fails the assertion above first.
        execution.retireHostInvocation(self);
        self.vm_stack.deinit(self.nativeAllocator());
        self.exception.clear();
        self.clearWeakRefKeptAlive();
        self.job_queue.deinit();
        self.strings = .{};
        native_bindings.destroyOwned(self);
        // Teardown does not own public handles: every scope/persistent/weak
        // owner must close its edge first.
        self.roots.assertNoOutstanding();
        self.gc.scheduler.host_quiescent = true;
        _ = self.collectForTeardown();
        // The collection may enqueue FinalizationRegistry cleanups for dead
        // targets; drop them so the second pass can reclaim their held values.
        self.clearPendingFinalizationJobs();
        _ = self.collectForTeardown();
        self.gc.scheduler.host_quiescent = false;
        self.borrowed_weak_cleanup.end();
        // The second pass may enqueue cleanups again, re-growing the queue
        // released at the top of teardown. No enqueue site remains reachable.
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
        context_registry.assertNoHostRealmRefs(self);
        self.gc.deinit(self);
        // Shapes and every other GC-managed atom owner are now gone. Clear
        // residual dynamic symbol bodies (notably Symbol.for's registry ref)
        // before AtomTable.deinit asserts that no materialized bodies remain.
        self.atoms.releaseValueSymbolBodiesAfterGc();
        // These native containers share the Runtime allocator for their entire
        // lifetime; parser scratch is owned separately by each compilation.
        self.borrowed_weak_cleanup.deinit(self.nativeAllocator());
        self.weak.deinit(self.nativeAllocator());
        property_state.deinit(self);
        self.shapes.destroy();
        self.classes.destroy();
        self.atoms.destroy();
        self.roots.deinit(self);

        // The Runtime body is owned by `allocator`, outside native allocation instrumentation.
        std.debug.assert(!self.hasOutstandingAllocations());
    }

    pub fn destroy(self: *JSRuntime) void {
        self.assertOwnerThread();
        const allocator = self.allocator;
        self.deinit();
        self.gc.destroy();
        allocator.destroy(self);
    }

    /// Checked teardown entry for hosts that cannot prove their call thread.
    /// On rejection the Runtime is untouched and remains owned by its creator.
    pub fn tryDestroy(self: *JSRuntime) RuntimeMutationError!void {
        try self.requireOwnerThread();
        self.destroy();
    }

    /// Ordinary native allocator with request-byte accounting and
    /// optional diagnostic instrumentation. GC cells use explicit typed helpers.
    pub inline fn nativeAllocator(self: *JSRuntime) std.mem.Allocator {
        return native_allocation.nativeAllocator(self);
    }

    // Native allocation belongs to Runtime; GC-prefixed types use Registry.
    pub const allocNative = native_allocation.alloc;
    pub const freeNative = native_allocation.free;
    pub const createNative = native_allocation.create;
    pub const createNativeNoTrigger = native_allocation.createNoTrigger;
    pub const destroyNative = native_allocation.destroy;
    pub const remapNative = native_allocation.remap;
    pub const allocNativeElements = native_allocation.allocElements;
    pub const reallocNativeElements = native_allocation.reallocElements;
    pub const allocNativeAlignedBytes = native_allocation.allocAlignedBytes;
    pub const allocNativeAlignedBytesNoTrigger = native_allocation.allocAlignedBytesNoTrigger;
    pub const freeNativeAlignedBytes = native_allocation.freeAlignedBytes;
    pub const probedNativeAllocator = native_allocation.probedAllocator;
    pub const hasOutstandingAllocations = native_allocation.hasOutstandingAllocations;
    pub const sampleAllocationPeak = native_allocation.samplePeakAtCollection;

    /// Owner-thread check for the object register/unregister hot paths
    /// (QuickJS `add_gc_object` / `remove_gc_object` have none). A bare
    /// `std.debug.assert(self.isOwnerThread())` would still read the thread id
    /// in ReleaseFast, so the whole check is compiled only with safety on.
    inline fn assertOwnerThreadInSafeBuilds(self: *const JSRuntime) void {
        if (comptime std.debug.runtime_safety) std.debug.assert(self.isOwnerThread());
    }

    /// Publish an initialized object to the GC with its allocation size
    /// supplied by the caller, which already computed the layout. The only
    /// object-creation threshold check is `collectBeforeObjectAllocation`,
    /// immediately before the body allocation (QuickJS `js_trigger_gc` in
    /// `JS_NewObjectFromShape`); registration never re-evaluates it.
    pub inline fn registerObjectWithBytes(self: *JSRuntime, object: *Object, bytes: usize) !void {
        self.assertOwnerThreadInSafeBuilds();
        try self.gc.addInitializedWithSize(object.gcHeader(), bytes);
    }

    /// GC-list unlink and free-byte accounting for an object teardown, with
    /// the allocation size supplied by `destroyFromHeader` (the sole caller),
    /// which already computed the layout. The weak/borrowed side-table links
    /// were detached earlier in `destroyFromHeader`, because they borrow
    /// payload-owned storage.
    pub fn unregisterObjectWithBytes(self: *JSRuntime, object: *Object, bytes: usize) void {
        self.assertOwnerThreadInSafeBuilds();
        if (builtin.mode == .Debug) {
            // Catch any future payload finalizer that re-registers mid-teardown.
            if (object.weakReferenceHolderLink()) |link| std.debug.assert(!link.registered);
            std.debug.assert(!object.flags.is_borrowed_reference_holder);
        }
        // The tracing sweeps detach and stamp condemned objects before their
        // resource pass. In that state the generic unlink boundary would only
        // rediscover facts already established by condemnation; retain its
        // mandatory byte debit without paying the outlined call.
        if (gc_mod.headerCondemned(object.gcHeaderConst())) {
            self.gc.recordDetachedHeapFreeWithBytes(object.gcHeader(), bytes);
            return;
        }
        self.gc.unlinkObjectWithBytes(object.gcHeader(), bytes);
    }

    pub fn registerBorrowedReferenceHolder(self: *JSRuntime, object: *Object) !void {
        return property_state.registerBorrowedHolder(self, object);
    }

    pub fn unregisterBorrowedReferenceHolder(self: *JSRuntime, object: *Object) void {
        property_state.unregisterBorrowedHolder(self, object);
    }

    pub fn firstContext(self: *const JSRuntime) ?*context_mod.JSContext {
        return self.contexts.live_head;
    }

    pub fn contextForGlobal(self: *const JSRuntime, global: *const Object) ?*context_mod.JSContext {
        return context_registry.liveForGlobal(self, global);
    }

    /// Bootstrap-only resolver. Public enumeration uses `contextForGlobal`,
    /// whose list contains published realms exclusively.
    pub fn contextForGlobalIncludingConstructing(self: *const JSRuntime, global: *const Object) ?*context_mod.JSContext {
        return context_registry.anyForGlobal(self, global);
    }

    /// Reserve a prototype slot in every realm before a class id is published.
    /// The lists are indexes; `RealmRef` keeps each realm alive across growth.
    pub fn ensureContextClassPrototypeCapacity(self: *JSRuntime, class_id: class.ClassId) !void {
        return context_registry.ensureClassPrototypeCapacity(self, class_id);
    }

    pub fn registerRootProvider(self: *JSRuntime, provider: RootProvider) !void {
        self.assertOwnerThread();
        try self.roots.register(self, provider);
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
        self.roots.beginTrace();
        defer self.roots.endTrace();
        try self.traceValueRootFrames(roots, visitor);
        try visitor.value(&self.exception.value);
        try self.roots.traceHandleSlots(visitor);
        try self.job_queue.traceRoots(visitor);
        for (self.weakref_kept_alive.items) |*kept| try visitor.value(kept);
        try self.roots.traceProviders(visitor);
        try string_cache.trace(self, visitor);
        try self.atoms.traceRoots(visitor);
        try self.traceAtomRoots(visitor);
    }

    /// Atom ids owned outside any GC header: class names. Exact --
    /// `Table.unregister` releases the same ids.
    fn traceAtomRoots(self: *JSRuntime, visitor: *RootVisitor) RootTraceError!void {
        if (visitor.visit_atom == null) return;
        for (self.classes.records) |record| {
            try visitor.atomRoot(record.class_name);
        }
    }

    pub fn traceActiveRoots(self: *JSRuntime, visitor: *RootVisitor) RootTraceError!void {
        self.roots.beginTrace();
        defer self.roots.endTrace();
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
    }

    pub fn traceValueRootFrames(self: *JSRuntime, roots: ?*const ValueRootFrame, visitor: *RootVisitor) RootTraceError!void {
        self.roots.beginTrace();
        defer self.roots.endTrace();
        var frame = roots;
        while (frame) |current| {
            for (current.objects) |root| {
                try visitor.optionalObject(root);
            }
            for (current.headers) |root| {
                try visitor.constHeader(root.header);
            }
            for (current.values) |root| {
                try visitor.value(root);
            }
            if (visitor.visit_atom != null) {
                for (current.atoms) |root| switch (root) {
                    .single => |slot| try visitor.atomRoot(slot.*),
                    // Read the slice header now: the frame may have been
                    // linked before the array had any element at all.
                    .list => |list| for (list.*) |id| try visitor.atomRoot(id),
                    .borrowed => |ids| for (ids) |id| try visitor.atomRoot(id),
                };
            }
            for (current.slices) |root| {
                switch (root) {
                    .mutable => |values| try visitor.values(values.*),
                    .borrowed => |values| try visitor.constValues(values),
                    .windowed => |w| try visitor.values(w.values.*.ptr[0..w.live_len.*]),
                    .cells => |cells| {
                        for (cells.*) |cell| try visitor.constHeader(&cell.header);
                    },
                    .borrowed_cells => |cells| {
                        for (cells) |cell| try visitor.constHeader(&cell.header);
                    },
                }
            }
            frame = current.previous;
        }
    }

    /// Stack-local execution/root records are borrowed by Runtime. They must be
    /// gone before teardown in every optimization mode; silently continuing
    /// would leave their deferred cleanup pointing into a destroyed Runtime.
    fn assertIdleForTeardown(self: *const JSRuntime) void {
        if (comptime gc_scope.checks_enabled) {
            if (self.active_no_gc_scope != null) @panic("JSRuntime destroyed during no-GC scope");
        }
        if (self.roots.isTracing()) @panic("JSRuntime destroyed during tracing");
        self.roots.assertNoOutstandingBuffers();
        const active_job_for_runtime = blk: {
            var current = active_job_root_head;
            while (current) |root| : (current = root.previous) {
                if (root.runtime == self) break :blk true;
            }
            break :blk false;
        };
        if (self.stack.call_depth != 0 or
            self.stack.native_call_depth != 0 or
            self.stack.bytecode_bytes != 0 or
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

    pub fn clearWeakRootSlot(self: *JSRuntime, slot: *WeakRootSlot) void {
        if (slot.identity == null) return;
        self.clearWeakIdentitySlot(&slot.identity);
    }

    /// Run the callbacks of weak handles a finished collection cleared. A
    /// callback may release any weak handle, including its own, and may
    /// allocate; a collection it triggers queues further callbacks for this
    /// same loop instead of nesting one.
    pub fn runPendingWeakCallbacks(self: *JSRuntime) void {
        if (self.gc.hot.collecting or self.roots.isTracing() or self.roots.weak_notify_draining) return;
        self.roots.weak_notify_draining = true;
        defer self.roots.weak_notify_draining = false;
        while (self.roots.weak_notify_queue.pop()) |slot| {
            slot.notify_pending = false;
            if (slot.callback) |callback| callback(self, slot.callback_context);
        }
    }

    /// A successful WeakRef.deref keeps its target alive through the current
    /// checkpoint, including all jobs enqueued while it drains.
    pub fn keepAliveWeakRefTarget(self: *JSRuntime, identity: usize, value: JSValue) error{OutOfMemory}!void {
        return job_mod.keepAliveWeakRef(self, identity, value);
    }

    /// Clear [[KeptAlive]] at a completed or terminated checkpoint.
    pub fn clearWeakRefKeptAlive(self: *JSRuntime) void {
        job_mod.clearKeptAlive(self);
    }

    /// Object identities are not counted: a token stays valid until its object
    /// dies, and death hands it back (`gc_weak.takeObject`). Only symbol
    /// identities, whose atom entry is kept indexed by this count, are counted.
    pub fn retainWeakIdentity(self: *JSRuntime, identity: usize) void {
        if ((identity & 1) == 0) return;
        self.atoms.retainSymbolWeakRef(weakSymbolAtom(identity) orelse return);
    }

    /// Mirror of `retainWeakIdentity`: releasing an object identity is a no-op
    /// because nothing was retained.
    pub fn releaseWeakIdentity(self: *JSRuntime, identity: usize) void {
        if ((identity & 1) == 0) return;
        self.atoms.releaseSymbolWeakRef(self, weakSymbolAtom(identity) orelse return);
    }

    /// Odd weak identities name symbols (`atom << 1 | 1`); null when the id is
    /// out of atom range.
    fn weakSymbolAtom(identity: usize) ?atom.Atom {
        const atom_id = identity >> 1;
        if (atom_id > std.math.maxInt(u32)) return null;
        return atom.Atom.fromRaw(@intCast(atom_id));
    }

    pub fn clearWeakIdentitySlot(self: *JSRuntime, slot: *?usize) void {
        const identity = slot.* orelse return;
        slot.* = null;
        self.releaseWeakIdentity(identity);
    }

    pub fn weakIdentityIsCurrentlyLive(self: *JSRuntime, identity: usize) bool {
        if ((identity & 1) != 0) {
            const symbol_atom = weakSymbolAtom(identity) orelse return false;
            return self.atoms.kind(symbol_atom) == .symbol;
        }
        return self.liveObjectFromWeakIdentity(identity) != null;
    }

    pub fn valueFromWeakIdentity(self: *JSRuntime, identity: usize) JSValue {
        if ((identity & 1) != 0) {
            const symbol_atom = weakSymbolAtom(identity) orelse return JSValue.undefinedValue();
            if (self.atoms.kind(symbol_atom) != .symbol) return JSValue.undefinedValue();
            return self.atoms.symbolValueIfLive(self, symbol_atom);
        }
        const object = self.liveObjectFromWeakIdentity(identity) orelse return JSValue.undefinedValue();
        return object.value();
    }

    /// Resolves an even weak identity (`weak_id << 1`) to its registered
    /// object in O(1). Returns null for symbol identities and for ids whose
    /// object is gone; destruction hands the id back in the same step that
    /// frees the object, so the map lookup is the whole liveness test.
    pub fn liveObjectFromWeakIdentity(self: *const JSRuntime, identity: usize) ?*Object {
        return gc_weak.objectFromIdentity(self, identity);
    }

    /// Returns the encoded weak identity for `object`, allocating a fresh
    /// monotonically increasing weak id on first registration.
    pub fn registerWeakObjectIdentity(self: *JSRuntime, object: *Object) !usize {
        return gc_weak.registerObject(self, object);
    }

    pub fn enterHandleScope(self: *JSRuntime) HandleScope {
        return HandleScope.enter(self);
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

    /// One strong persistent handle; a `JSValue` is copied by bits.
    pub fn createPersistentValue(self: *JSRuntime, value: JSValue) !JSValueHandle {
        return JSValueHandle.init(self, value);
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

    /// Precise quiescent collection for lifecycle fixtures only.
    pub fn collectForTest(self: *JSRuntime) usize {
        if (!builtin.is_test) @compileError("test-only collection helper");
        return self.collectForTeardown();
    }

    fn collectForTeardown(self: *JSRuntime) usize {
        self.assertOwnerThread();
        const result = self.collectFull(null, .declared_only) catch return 0;
        return result.freed_objects;
    }

    /// Stop-the-world full collection.
    pub fn collectFull(
        self: *JSRuntime,
        roots: ?*const ValueRootFrame,
        scan: gc_mod.RootScan,
    ) gc_mod.CollectionError!gc_mod.CollectionResult {
        self.assertOwnerThread();
        self.assertGCAllowed();
        if (self.roots.isTracing()) @panic("collection reentry during tracing");
        // Registered first so it runs last, after `collecting` is cleared.
        defer self.runPendingWeakCallbacks();
        // A collection or collector phase already on the stack (a destructor
        // that allocates, for one) leaves the request pending rather than
        // nesting a second collection or touching its morgue and cycle.
        if (self.collectorBusy()) return .{};
        if (builtin.mode == .Debug) self.gc.verifyIntrusiveList() catch unreachable;
        if (builtin.mode == .Debug) self.gc.verifyHeapAccounting(self) catch unreachable;
        defer if (builtin.mode == .Debug) {
            self.gc.verifyIntrusiveList() catch unreachable;
            self.gc.verifyHeapAccounting(self) catch unreachable;
        };
        self.gc.hot.collecting = true;
        defer self.gc.hot.collecting = false;

        // The cycle's high-water is the account right now, at trigger time.
        self.sampleAllocationPeak();
        const start_ns = self.diagnosticNanos();

        self.gc.scheduler.beginMajorCycle(self.gc.scheduler.activeMajorReason() orelse .manual);
        const freed = @import("core/gc_trace_stw.zig").collectCycles(self, roots, scan) catch |err| {
            const mapped: gc_mod.CollectionError = switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.PayloadMarkFailed => error.PayloadMarkFailed,
            };
            self.gc.recordFailure(mapped);
            self.gc.scheduler.abortMajorCycle();
            self.gc.requestGC(.collection_failed, .soon);
            return mapped;
        };
        self.gc.scheduler.setMajorPhase(.sweep);

        const elapsed = self.diagnosticElapsedSince(start_ns);
        // Charge the census to whoever asked for it, not to the pause. The
        // walks run inside this region and are enabled by the same
        // `--gc-stats` that prints the distribution, so leaving them in makes
        // the only pause instrument inflate its own subject by ~40%.
        const census = self.gc.last_census_ns;
        const result = gc_mod.CollectionResult{
            .freed_objects = freed,
            .duration_ns = elapsed -| census,
        };
        self.gc.recordSuccess(result);
        self.gc.scheduler.finishMajorCycle();
        gc_driver.resetThreshold(self);
        // Service the aged-decommit policy here too; otherwise explicit GC,
        // urgent pressure collections, and small-heap floor collections can
        // age free blocks forever without ever scanning them.
        _ = self.gc.block_heap.releaseFreeBlockPages(gc_mod.schedulingNanos());
        return result;
    }

    pub fn pollGC(
        self: *JSRuntime,
        roots: ?*const ValueRootFrame,
        mode: gc_mod.PollMode,
    ) gc_mod.CollectionError!gc_mod.CollectionResult {
        self.assertOwnerThread();
        self.assertGCAllowed();
        if (self.roots.isTracing()) @panic("collection reentry during tracing");
        return gc_driver.continuePoll(self, roots, mode);
    }

    pub fn forceGC(self: *JSRuntime, roots: ?*const ValueRootFrame) gc_mod.CollectionError!gc_mod.CollectionResult {
        self.assertOwnerThread();
        self.gc.requestGC(.manual, .urgent);
        return self.pollGC(roots, .urgent);
    }

    /// Does a collection started at this poll decide liveness with the
    /// conservative pass over the mutator's native frames?
    ///
    /// A collection destroys synchronously, so running one from an arbitrary
    /// allocation boundary is only sound while the scan covers the Zig locals the interrupted caller is holding -- the
    /// shape `Object.create` acquires before its own boundary, for one. That
    /// is exactly the promise `gc.PollMode.rootScan` makes for the engine
    /// triggers, and exactly what `test_root_scan_override` withdraws: pacing
    /// tests declare their frame quiescent so reclamation is deterministic,
    /// which an allocation boundary in the middle of a constructor is not.
    /// Those polls run a major without a preceding minor.
    pub fn pollScansConservatively(self: *const JSRuntime, mode: gc_mod.PollMode) bool {
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

    pub fn setGCThreshold(self: *JSRuntime, threshold: usize) void {
        self.assertOwnerThread();
        self.gc.heap_budget.gc_threshold = threshold;
    }

    /// Current dynamic threshold, including changes during Context bootstrap.
    pub fn gcThreshold(self: *const JSRuntime) usize {
        return self.gc.heap_budget.gc_threshold;
    }

    /// JS heap budget cap. Ordinary native allocations do not consult it.
    pub fn setMemoryLimit(self: *JSRuntime, limit: ?usize) void {
        self.assertOwnerThread();
        self.gc.heap_budget.limit = limit;
    }

    /// Test-only cap on the account's native byte counter. This is the
    /// injector for ordinary allocation failure. `setMemoryLimit` does not
    /// fail those allocations.
    pub fn setNativeBytesLimitForTest(self: *JSRuntime, limit: ?usize) void {
        if (!builtin.is_test) @compileError("test-only helper");
        native_allocation.setLimit(self, limit);
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
            self.isExecuting()) return;
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

        // The five owner allocations (Runtime, GC, atom/class/shape tables)
        // come from the host allocator, outside the instrumented account.
        const owner_count = 5;
        const owner_bytes = @sizeOf(JSRuntime) + @sizeOf(GC) + @sizeOf(AtomTable) + @sizeOf(ClassTable) + @sizeOf(ShapeRegistry);
        const tracked = native_allocation.diagnostic_accounting_enabled;
        const diag = self.allocation_diagnostics;
        return .{
            .memory_limit = self.memoryLimit(),
            .heap_bytes = self.gc.heap_budget.bytes,
            .allocated_bytes = if (tracked) diag.allocated_bytes + owner_bytes else 0,
            .allocation_count = if (tracked) diag.allocation_count + owner_count else 0,
            .peak_allocated_bytes = if (tracked) diag.peak_allocated_bytes + owner_bytes else 0,
            .peak_allocation_count = if (tracked) diag.peak_allocation_count + owner_count else 0,
            .alloc_calls = if (tracked) diag.alloc_calls else 0,
            .free_calls = if (tracked) diag.free_calls else 0,
            .create_calls = if (tracked) diag.create_calls + owner_count else 0,
            .destroy_calls = if (tracked) diag.destroy_calls else 0,
            .atom_count = atom.predefined_count + live_dynamic_atoms,
            .atom_bytes = dynamic_atom_bytes,
            .registered_class_count = registered_classes,
            .class_record_count = self.classes.records.len,
        };
    }

    pub fn reportExternalAlloc(self: *JSRuntime, bytes: usize) !gc_mod.ExternalMemoryToken {
        const token = try self.gc.reportExternalAlloc(bytes);
        if (self.gc.externalMemoryRequestReason()) |reason| {
            self.gc.requestGC(reason, self.gc.externalMemoryRequestUrgency());
        }
        return token;
    }

    /// Pause percentiles over the collector's retained round window, or null
    /// if no collection has completed. Separate from `gcStats` because it
    /// sorts a scratch copy; callers that only want counters should not pay
    /// for it.
    pub fn gcPauseDistribution(self: *const JSRuntime) ?gc_mod.PauseDistribution {
        return self.gc.pauseDistribution();
    }

    fn fillGcCounters(self: *const JSRuntime, stats: *gc_mod.Stats) void {
        stats.weak_ref_count = self.weakRootSlotCount();
        stats.finalizer_queue_length = self.job_queue.countKind(.finalization);
    }

    /// Maintained counters only. Does not walk the heap.
    pub fn gcStats(self: *const JSRuntime) gc_mod.Stats {
        var stats = self.gc.counterSnapshot(self);
        self.fillGcCounters(&stats);
        return stats;
    }

    /// One heap census. Heap bytes stay separate from external debt.
    pub fn gcDetailedStats(self: *const JSRuntime) gc_mod.DetailedStats {
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
        gc_mod.noteHeapWalk();
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
            if (self.gc.heap_budget.runProbe(size)) return self.prospectiveAllocationTotal(size);
        }
        // Destructors may allocate, but starting a nested collection from
        // inside a running one is not allowed.
        if (self.collectorBusy()) return self.prospectiveAllocationTotal(size);
        if (comptime native_allocation.force_gc_on_allocation_enabled) {
            if (self.gc.heap_budget.suspend_alloc_notify) return self.prospectiveAllocationTotal(size);
            // A no-GC scope's native allocations (atom interning, for one)
            // never collect in a normal build; the synthetic collection
            // must not start inside one either.
            if (comptime gc_scope.checks_enabled) {
                if (self.active_no_gc_scope != null) return self.prospectiveAllocationTotal(size);
            }
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
        if (self.collectorBusy()) return;
        if (!self.gc.hasPendingMajorRequest()) return;
        return self.pollGCBeforeObjectAllocation();
    }

    /// Cold tail that owns `pollGC`'s error-union return area. The common
    /// below-threshold allocation path can then remain a leaf with no saved
    /// registers or stack frame.
    noinline fn pollGCBeforeObjectAllocation(self: *JSRuntime) void {
        _ = self.pollGC(null, .normal) catch {};
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
        if (self.collectorBusy()) return;
        _ = self.collectFull(null, .engine_active) catch return;
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

    /// Return the shared single-code-unit (latin1) string for `byte`,
    /// creating it lazily on the first request. The cache slot is itself a
    /// root, so the body outlives every borrow of it; there is no per-caller
    /// retain to take.
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
        self.stack.limit = size;
        self.stack.frame_storage = VmStackStorage.frameWindowForLimit(size);
    }

    pub fn stackSize(self: *const JSRuntime) usize {
        return self.stack.limit;
    }

    pub fn nativeStackSize(self: *const JSRuntime) usize {
        return self.stack.native_size;
    }

    pub fn setNativeStackSize(self: *JSRuntime, budget_bytes: usize) void {
        self.assertOwnerThread();
        self.stack.native_size = budget_bytes;
        if (self.stack.call_depth == 0 and self.stack.native_call_depth == 0) {
            self.updateNativeStackTop();
        } else {
            self.stack.armNativeLimit();
        }
    }

    /// Capture the current native frame pointer as the recursion base and derive
    /// the lower limit (QuickJS `JS_UpdateStackTop`). Must be called at the
    /// outermost JS entry on the thread that will run the code (worker threads have their own C stack), so
    /// deeper native frames (parser / JSON / interpreter) measure against a real,
    /// same-stack base. A `native_stack_size` of 0 disables the limit.
    pub fn updateNativeStackTop(self: *JSRuntime) void {
        self.stack.native_top = @frameAddress();
        self.stack.armNativeLimit();
    }

    /// Return true if consuming `alloca_size` more native stack would cross the
    /// recursion limit (QuickJS `js_check_stack_overflow`). The stack grows
    /// down, so "below the limit" is overflow. A zero limit means "no limit"
    /// and needs no branch of its own: the saturating `sp` is never below 0.
    pub inline fn checkNativeStackOverflow(self: *const JSRuntime, alloca_size: usize) bool {
        const sp = @frameAddress() -| alloca_size;
        return sp < self.stack.native_limit;
    }

    pub fn internAtom(self: *JSRuntime, bytes: []const u8) !atom.Atom {
        return self.atoms.internString(bytes);
    }

    pub fn registerClass(self: *JSRuntime, definition: class.Definition) !class.Binding {
        return self.classes.registerDefinition(self, definition);
    }

    /// Owner thread only; `terminateExecution` is the cross-thread request.
    pub fn setInterruptHandler(self: *JSRuntime, handler: ?InterruptHandler, context: ?*anyopaque) void {
        self.assertOwnerThread();
        self.interrupt = if (handler) |h| .{ .handler = h, .context = context } else null;
    }

    pub fn installDynamicImportLoader(self: *JSRuntime, next: DynamicImportLoader) DynamicImportLoaderScope {
        self.assertOwnerThread();
        const previous = self.dynamic_import_loader;
        self.dynamic_import_loader = next;
        return .{
            .runtime = self,
            .previous = previous,
            .installed = next,
        };
    }

    /// Thread-safe request. The caller must keep this Runtime alive.
    pub fn terminateExecution(self: *JSRuntime) void {
        self.termination_requested.store(true, .release);
    }

    pub fn isExecutionTerminating(self: *const JSRuntime) bool {
        return self.termination_requested.load(.acquire);
    }

    /// Owner-only idle recovery. Requests ordered after this exchange survive.
    pub fn cancelTerminateExecution(self: *JSRuntime) (RuntimeMutationError || error{RuntimeBusy})!void {
        try self.requireOwnerThread();
        if (self.isExecuting() or self.microtasks.running) return error.RuntimeBusy;
        _ = self.termination_requested.swap(false, .acq_rel);
    }

    /// Whether an interrupt poll can stop execution: a handler is installed
    /// or termination was requested.
    pub fn mayInterrupt(self: *const JSRuntime) bool {
        return self.interrupt != null or self.isExecutionTerminating();
    }

    /// The interrupt poll of a long native loop or of code that sees only
    /// the runtime (a parser, a numeric library). Every `native_poll_interval`
    /// calls it runs the interrupt handler; a stop request returns a bare
    /// `error.Interrupted`, which the builtin seam (`materializeRuntimeError`)
    /// or `exception_ops.raiseBareInterrupt` turns into the uncatchable
    /// InternalError.
    pub inline fn pollNativeWork(self: *JSRuntime) error{Interrupted}!void {
        self.native_poll_countdown -= 1;
        if (self.native_poll_countdown != 0) return;
        self.native_poll_countdown = native_poll_interval;
        if (self.runInterruptHandler()) return error.Interrupted;
    }

    /// Bytes a bulk step (copy, fill, scan, compare) does per unit of
    /// `pollNativeWork`'s countdown: one interval is about 256 KiB.
    pub const native_bulk_bytes_per_unit = 64;

    /// `pollNativeWork` for a bulk step over `bytes` bytes: it uses up its
    /// share of the countdown, so a loop of large copies or scans polls as
    /// often as a loop of small iterations.
    pub fn pollNativeBulkWork(self: *JSRuntime, bytes: usize) error{Interrupted}!void {
        const units = bytes / native_bulk_bytes_per_unit;
        if (units < self.native_poll_countdown) {
            self.native_poll_countdown -= @intCast(units);
            return;
        }
        self.native_poll_countdown = native_poll_interval;
        if (self.runInterruptHandler()) return error.Interrupted;
    }

    pub fn runInterruptHandler(self: *JSRuntime) bool {
        if (self.isExecutionTerminating()) return true;
        const interrupt = self.interrupt orelse return false;
        return interrupt.handler(self, interrupt.context);
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

    pub fn clearPendingFinalizationJobs(self: *JSRuntime) void {
        while (self.job_queue.firstIndexOfKind(.finalization)) |index| {
            var entry = self.job_queue.takeAt(index);
            entry.deinit();
        }
    }
};

/// Gate-only check used after the CLI has finished draining jobs: every
/// collection destroys what it condemned, so the morgue must be empty. A
/// module function rather than a JSRuntime method so this internal
/// diagnostic does not enlarge the public embedder API.
pub fn auditDoomedStateForGateStats(rt: *JSRuntime) void {
    rt.assertOwnerThread();
    rt.assertIdleForTeardown();
    std.debug.assert(!rt.gc.hot.collecting);
    std.debug.assert(rt.gc.hot.phase == .none);
    @import("core/gc_trace_stw.zig").auditDoomedExitInvariant(rt);
}

test "value root frame activation restores nested scopes" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
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
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const object = try Object.create(rt, class.ids.object, null);
    var handle = try rt.createPersistentValue(object.value());
    try std.testing.expectEqual(@as(usize, 1), rt.roots.persistent_root_slots.items.len);
    try std.testing.expect(handle.get().is(.object));

    const released = handle.take();
    try std.testing.expectEqual(@as(usize, 0), rt.roots.persistent_root_slots.items.len);
    try std.testing.expect(released.is(.object));

    handle.deinit();
    try std.testing.expectEqual(@as(usize, 0), rt.roots.persistent_root_slots.items.len);
}

test "external memory accounting records debt and requests GC" {
    const rt = try JSRuntime.create(std.testing.allocator, .{
        .gc_policy = .{
            .external_weight = 2,
            .major_debt_threshold = 16,
        },
    });
    defer rt.destroy();

    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().external_bytes);
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().allocation_debt);
    try std.testing.expect(!rt.gc.hasPendingMajorRequest());

    var token = try rt.reportExternalAlloc(8);
    var duplicate_token = token;
    try std.testing.expectEqual(@as(usize, 8), rt.gcStats().external_bytes);
    try std.testing.expectEqual(@as(usize, 16), rt.gcStats().allocation_debt);
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().external_token_count);
    try std.testing.expectEqual(@as(usize, 8), rt.gcStats().external_token_bytes);
    try std.testing.expect(rt.gc.hasPendingMajorRequest());
    try std.testing.expectEqual(@as(?gc_mod.RequestReason, gc_mod.RequestReason.allocation_debt), rt.gc.stats.last_request_reason);

    const result = try rt.pollGC(null, .normal);
    try std.testing.expectEqual(@as(usize, 0), result.freed_objects);
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().allocation_debt);
    try std.testing.expectEqual(@as(usize, 8), rt.gcStats().external_bytes);
    try std.testing.expect(!rt.gc.hasPendingMajorRequest());

    token.release();
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().external_bytes);
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().external_token_count);
    duplicate_token.release();
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().external_invalid_release_count);
    try std.testing.expectEqual(@as(usize, 0), rt.gcStats().external_bytes);
    token.release();
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().external_invalid_release_count);
}

test "external hard memory pressure requests urgent major gc" {
    const rt = try JSRuntime.create(std.testing.allocator, .{
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
    try std.testing.expectEqual(@as(?gc_mod.RequestReason, gc_mod.RequestReason.external_memory), pending.pending_request_reason);
    try std.testing.expectEqual(@as(?gc_mod.RequestUrgency, gc_mod.RequestUrgency.urgent), pending.pending_request_urgency);

    _ = try rt.pollGC(null, .callback_boundary);
    if (comptime native_allocation.force_gc_on_allocation_enabled) {
        try std.testing.expect(rt.gcStats().major_gc_count >= 1);
    } else {
        try std.testing.expectEqual(@as(usize, 1), rt.gcStats().major_gc_count);
    }
    try std.testing.expect(!rt.gc.hasPendingMajorRequest());
}

test "atom table growth requests a major that the interpreter safepoint serves" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const before = rt.memoryUsage().atom_count;
    var buf: [32]u8 = undefined;
    for (0..AtomTable.sweep_growth_floor) |i| {
        _ = try rt.internAtom(try std.fmt.bufPrint(&buf, "growth-{d}", .{i}));
    }
    const pending = rt.gcStats();
    try std.testing.expect(pending.pending_major);
    try std.testing.expectEqual(@as(?gc_mod.RequestReason, gc_mod.RequestReason.atom_growth), pending.pending_request_reason);

    _ = try rt.pollGC(null, .safepoint);
    try std.testing.expect(!rt.gc.hasPendingMajorRequest());
    try std.testing.expect(rt.memoryUsage().atom_count < before + AtomTable.sweep_growth_floor / 2);
    try std.testing.expectEqual(@as(u32, 0), rt.atoms.interned_since_sweep);
}

test "an atom interned across an atom-hash resize is live when intern returns" {
    // The resize allocates, and an allocation may collect: a new entry
    // nothing holds yet must not exist while it does. Only a
    // `-Dzjs_force_gc=true` build collects inside that allocation.
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    var ids: [3000]atom.Atom = undefined;
    var buf: [32]u8 = undefined;
    for (&ids, 0..) |*id, i| {
        id.* = try rt.internAtom(try std.fmt.bufPrint(&buf, "resize-{d}", .{i}));
        try std.testing.expect(rt.atoms.name(id.*) != null);
        rt.atoms.pinForHost(id.*);
    }
    for (ids) |id| rt.atoms.unpinForHost(id);
}

test "VM stack arena default fill matches VmStackArena{}" {
    var arena: VmStackArena = undefined;
    arena.initDefault();
    try std.testing.expectEqualDeep(VmStackArena{}, arena);
    try std.testing.expectEqual(@as(usize, 1552), @sizeOf(VmStackArena));
    const empty: []JSValue = &.{};
    try std.testing.expectEqual(empty.ptr, arena.chunks[0].ptr);
    try std.testing.expectEqual(@as(usize, 0), arena.chunks[0].len);

    const account = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
    defer account.destroy();
    arena.deinit(account.nativeAllocator());
    try std.testing.expectEqualDeep(VmStackArena{}, arena);
    try std.testing.expect(!account.hasOutstandingAllocations());
}

test "VM stack arena allocates and reuses a compact first chunk" {
    try std.testing.expectEqual(
        VmStackArena.first_chunk_bytes / @sizeOf(JSValue),
        VmStackArena.first_chunk_slots,
    );

    const account = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
    defer account.destroy();
    var arena: VmStackArena = .{};
    defer arena.deinit(account.nativeAllocator());

    const initial_mark = arena.mark();
    const first = arena.carve(account, 3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), first.len);
    try std.testing.expectEqual(@as(usize, 1), arena.chunk_count);
    try std.testing.expectEqual(@as(usize, 0), arena.active);
    try std.testing.expectEqual(VmStackArena.first_chunk_slots, arena.chunks[0].len);
    try std.testing.expectEqual(VmStackArena.first_chunk_bytes, account.allocation_diagnostics.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), account.allocation_diagnostics.allocation_count);

    arena.restore(initial_mark);
    const allocations_before_reuse = account.allocation_diagnostics.allocation_count;
    const reused = arena.carve(account, 3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(reused.ptr));
    try std.testing.expectEqual(allocations_before_reuse, account.allocation_diagnostics.allocation_count);
    try std.testing.expectEqual(VmStackArena.first_chunk_bytes, account.allocation_diagnostics.allocated_bytes);
}

test "VM stack arena active miss is pure before authoritative second chunk carve" {
    const account = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
    defer account.destroy();
    var arena: VmStackArena = .{};
    defer arena.deinit(account.nativeAllocator());

    _ = arena.carve(account, VmStackArena.first_chunk_slots) orelse
        return error.TestUnexpectedResult;
    const full_mark = arena.mark();
    const bytes_before_miss = account.allocation_diagnostics.allocated_bytes;
    const allocations_before_miss = account.allocation_diagnostics.allocation_count;

    try std.testing.expect(arena.carveActiveMarked(1) == null);
    try std.testing.expectEqual(full_mark, arena.mark());
    try std.testing.expectEqual(bytes_before_miss, account.allocation_diagnostics.allocated_bytes);
    try std.testing.expectEqual(allocations_before_miss, account.allocation_diagnostics.allocation_count);
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
        account.allocation_diagnostics.allocated_bytes,
    );
    try std.testing.expectEqual(allocations_before_miss + 1, account.allocation_diagnostics.allocation_count);
}

test "VM stack arena large first carve retains the maximum chunk size" {
    const account = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
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
        account.allocation_diagnostics.allocated_bytes,
    );
    try std.testing.expectEqual(@as(usize, 1), account.allocation_diagnostics.allocation_count);
}

test "VM stack arena oversized carve is rejected without state or accounting changes" {
    const account = try runtime_owner.createAllocationTestRuntime(std.testing.allocator);
    defer account.destroy();
    var arena: VmStackArena = .{};
    defer arena.deinit(account.nativeAllocator());

    const before = arena.mark();
    try std.testing.expect(arena.carve(account, VmStackArena.chunk_slots + 1) == null);
    try std.testing.expectEqual(before, arena.mark());
    try std.testing.expectEqual(@as(usize, 0), arena.chunk_count);
    try std.testing.expectEqual(@as(usize, 0), account.allocation_diagnostics.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), account.allocation_diagnostics.allocation_count);
}

test "VM stack arena allocation failure is retryable and keeps accounting balanced" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const account = try runtime_owner.createAllocationTestRuntime(failing_allocator.allocator());
    defer account.destroy();
    var arena: VmStackArena = .{};
    defer arena.deinit(account.nativeAllocator());

    failing_allocator.fail_index = failing_allocator.alloc_index;
    const before = arena.mark();
    try std.testing.expect(arena.carve(account, 1) == null);
    try std.testing.expectEqual(before, arena.mark());
    try std.testing.expectEqual(@as(usize, 0), arena.chunk_count);
    try std.testing.expectEqual(@as(usize, 0), account.allocation_diagnostics.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), account.allocation_diagnostics.allocation_count);

    failing_allocator.fail_index = std.math.maxInt(usize);
    const retry = arena.carve(account, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), retry.len);
    try std.testing.expectEqual(@as(usize, 1), arena.chunk_count);
    try std.testing.expectEqual(VmStackArena.first_chunk_bytes, account.allocation_diagnostics.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), account.allocation_diagnostics.allocation_count);

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
    try std.testing.expectEqual(VmStackArena.first_chunk_bytes, account.allocation_diagnostics.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), account.allocation_diagnostics.allocation_count);

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
        account.allocation_diagnostics.allocated_bytes,
    );
    try std.testing.expectEqual(@as(usize, 2), account.allocation_diagnostics.allocation_count);

    arena.deinit(account.nativeAllocator());
    try std.testing.expectEqual(@as(usize, 0), account.allocation_diagnostics.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), account.allocation_diagnostics.allocation_count);
}

test "runtime allocator facades share memory accounting" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const baseline = rt.allocation_diagnostics.allocated_bytes;
    const current = try rt.nativeAllocator().alloc(u8, 2048);
    var current_live = true;
    defer if (current_live) rt.nativeAllocator().free(current);
    try std.testing.expectEqual(baseline + current.len, rt.allocation_diagnostics.allocated_bytes);

    const persistent = try rt.nativeAllocator().alloc(u8, 4096);
    var persistent_live = true;
    defer if (persistent_live) rt.nativeAllocator().free(persistent);
    try std.testing.expectEqual(baseline + current.len + persistent.len, rt.allocation_diagnostics.allocated_bytes);

    rt.nativeAllocator().free(persistent);
    persistent_live = false;
    try std.testing.expectEqual(baseline + current.len, rt.allocation_diagnostics.allocated_bytes);
    rt.nativeAllocator().free(current);
    current_live = false;
    try std.testing.expectEqual(baseline, rt.allocation_diagnostics.allocated_bytes);
}

test "runtime and context init-deinit are leak free" {
    for (0..3) |_| {
        const rt = try JSRuntime.create(std.testing.allocator, .{});
        const ctx1 = try context_mod.JSContext.create(rt, .{});
        const ctx2 = try context_mod.JSContext.create(rt, .{});
        ctx2.destroy();
        ctx1.destroy();
        rt.destroy();
    }
}

test "nested dynamic import loader scopes restore in LIFO order" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    var outer_data: u8 = 1;
    var inner_data: u8 = 2;

    var outer = rt.installDynamicImportLoader(.{ .userdata = &outer_data });
    var inner = rt.installDynamicImportLoader(.{ .userdata = &inner_data });
    try std.testing.expectEqual(@as(?*anyopaque, &inner_data), rt.dynamic_import_loader.userdata);
    inner.deinit();
    inner.deinit(); // idempotent
    try std.testing.expectEqual(@as(?*anyopaque, &outer_data), rt.dynamic_import_loader.userdata);
    outer.deinit();
    try std.testing.expectEqual(@as(?*anyopaque, null), rt.dynamic_import_loader.userdata);
}
