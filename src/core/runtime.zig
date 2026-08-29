//! Runtime-wide ownership, allocation, GC scheduling, roots, and host policy.
//!
//! `JSRuntime` owns the atom/class/shape registries, memory account, job FIFO,
//! contexts, deferred native cleanup, and persistent handles. It is
//! owner-thread confined except at the explicitly synchronized host seams;
//! handles and root frames keep values alive but never transfer Runtime
//! ownership. QuickJS source map: `JSRuntime` and its registries at
//! quickjs.c:319-396. This is core infrastructure: exec/runtime/binding may
//! import it, while this module must not import those higher layers.

const std = @import("std");
const builtin = @import("builtin");
const platform_clock = @import("../platform_clock.zig");

const memory = @import("memory.zig");
const atom = @import("atom.zig");
const class = @import("class.zig");
const gc = @import("gc.zig");
const host_function = @import("host_function.zig");
const job_mod = @import("jobs.zig");
const function_bytecode_mod = @import("../bytecode.zig").function_bytecode;
const FunctionBytecode = function_bytecode_mod.FunctionBytecode;
const module = @import("module.zig");
const object_mod = @import("object.zig");
const shape = @import("shape.zig");
const string = @import("string.zig");
const unicode = @import("../libs/unicode.zig");
const var_ref_mod = @import("var_ref.zig");
const JSValue = @import("value.zig").JSValue;
const Object = object_mod.Object;
const profile = @import("profile.zig");
const property = @import("property.zig");
const context_mod = @import("context.zig");
const errors = @import("errors.zig");

extern "c" fn pclose(stream: *std.c.FILE) c_int;

const DeferredStdFileClose = struct {
    runtime: *JSRuntime,
    file: *std.c.FILE,
    is_popen: bool = false,

    fn run(ptr: *anyopaque) void {
        const job: *DeferredStdFileClose = @ptrCast(@alignCast(ptr));
        const rt = job.runtime;
        _ = closeStdFileHandle(job.file, job.is_popen);
        rt.memory.destroy(DeferredStdFileClose, job);
    }
};

pub fn closeStdFileHandle(file: *std.c.FILE, is_popen: bool) c_int {
    if (is_popen) {
        const rc = pclose(file);
        return if (rc == -1) -@as(c_int, @intCast(@intFromEnum(std.c.errno(-1)))) else rc;
    }
    const rc = std.c.fclose(file);
    return if (rc == -1) -@as(c_int, @intCast(@intFromEnum(std.c.errno(-1)))) else rc;
}

pub fn enqueueDeferredStdFileClose(rt: *JSRuntime, file: *std.c.FILE, is_popen: bool) void {
    const job = rt.createRuntime(DeferredStdFileClose) catch {
        _ = closeStdFileHandle(file, is_popen);
        return;
    };
    job.* = .{
        .runtime = rt,
        .file = file,
        .is_popen = is_popen,
    };
    rt.enqueueDeferredNativeCleanup(DeferredStdFileClose.run, @ptrCast(job)) catch {
        _ = closeStdFileHandle(file, is_popen);
        rt.memory.destroy(DeferredStdFileClose, job);
    };
}

pub const default_stack_size = 1024 * 1024;
pub const default_gc_threshold = 256 * 1024;
/// Native C-stack budget for the recursion guard, matching QuickJS
/// `JS_DEFAULT_STACK_SIZE` (quickjs.h:328, 1 MiB). The guard trips once this many
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
pub const StandardGlobalsInstaller = *const fn (rt: *JSRuntime, global: *Object) anyerror!void;

/// Process-global default standard-globals installer, registered once by the
/// exec bootstrap (`standard_globals.registerStandardGlobalsDefault`). New
/// runtimes copy this into their per-runtime `install_standard_globals_cb` at
/// `init`, so a bare `core.JSRuntime.create` (e.g. in engine unit tests) still
/// gets the installer wired without the creator naming builtins. Mirrors the
/// `profile.setOpcodeNameProvider` process-global registration pattern.
var default_standard_globals_installer: ?StandardGlobalsInstaller = null;
var default_standard_global_own_property_capacity: usize = 0;

/// Register (or clear, with `null`) the process-global standard-globals
/// installer and the own-property capacity its global object reserves. Called by
/// exec bootstrap during engine setup; idempotent and safe to call more
/// than once with the same values.
pub fn setDefaultStandardGlobalsInstaller(
    installer: ?StandardGlobalsInstaller,
    own_property_capacity: usize,
) void {
    default_standard_globals_installer = installer;
    default_standard_global_own_property_capacity = own_property_capacity;
}

/// Canonical operand-stack backing policy shared by Runtime and the execution
/// Stack. Runtime owns the configured limit and precomputes the arena-window
/// form when that limit changes; frame construction can then publish the one
/// packed word instead of re-saturating the same immutable limit per call.
pub const VmStackWindowPolicy = packed struct(u64) {
    limit: u62,
    arena_window: bool = false,
    resident_window: bool = false,

    pub fn forLimit(limit: usize) VmStackWindowPolicy {
        return .{ .limit = @intCast(@min(limit, std.math.maxInt(u62))) };
    }

    pub fn arenaForLimit(limit: usize) VmStackWindowPolicy {
        var policy = forLimit(limit);
        policy.arena_window = true;
        return policy;
    }
};

/// Contiguous VM value-stack arena mirroring QuickJS's `alloca`-based
/// `JS_CallInternal` frame layout. Call frames carve LIFO windows for
/// `[args | locals | operand stack]` instead of per-call heap allocations.
/// Windows are stable for their lifetime (chunks never move); release is a
/// watermark restore. Values inside windows are owned by the frames using
/// them and must be released before the watermark is restored.
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

    // K4 hot head: `mark`/`carveActiveMarked`/`restore` read chunk_count,
    // active, and used[active] on every bytecode call and return, and
    // active == 0 for virtually every frame (deeper chunks are the slow
    // path). Declared first so the scalar head and the front of `used`
    // share the arena's first cache line; `chunks[active]` is the only
    // remaining second-line load. Mirrors QuickJS keeping its hot stack
    // state (`stack_top`/`stack_limit`, quickjs.c:348-351) in the runtime
    // struct head. Layout verified by @offsetOf probe (K4 dossier).
    chunk_count: usize = 0,
    active: usize = 0,
    used: [max_chunks]usize = @splat(0),
    chunks: [max_chunks][]JSValue = @splat(&.{}),

    pub fn mark(self: *const VmStackArena) Mark {
        return .{ .chunk = self.active, .used = if (self.chunk_count == 0) 0 else self.used[self.active] };
    }

    /// Carve `n` slots from the arena. Returns null when the request cannot
    /// be served (oversized window or arena exhausted); callers fall back to
    /// heap storage.
    pub fn carve(self: *VmStackArena, account: *memory.MemoryAccount, n: usize) ?[]JSValue {
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
        return self.carveSlow(account, n);
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
    noinline fn carveSlow(self: *VmStackArena, account: *memory.MemoryAccount, n: usize) ?[]JSValue {
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
            const chunk = account.alloc(JSValue, allocation_slots) catch return null;
            self.chunks[next_index] = chunk;
            self.chunk_count = next_index + 1;
        }
        std.debug.assert(n <= self.chunks[next_index].len);
        self.active = next_index;
        self.used[next_index] = n;
        return self.chunks[next_index][0..n];
    }

    pub fn carveTyped(self: *VmStackArena, account: *memory.MemoryAccount, comptime T: type, n: usize) ?[]T {
        if (n == 0) return &.{};
        if (@alignOf(T) > @alignOf(JSValue)) return null;
        const byte_count = std.math.mul(usize, @sizeOf(T), n) catch return null;
        const slot_count = std.math.divCeil(usize, byte_count, @sizeOf(JSValue)) catch return null;
        const value_window = self.carve(account, slot_count) orelse return null;
        const bytes = std.mem.sliceAsBytes(value_window);
        return std.mem.bytesAsSlice(T, bytes[0..byte_count]);
    }

    /// Restore the watermark taken by `mark`. All values stored in the
    /// released region must already have been freed by frame/stack teardown.
    pub fn restore(self: *VmStackArena, m: Mark) void {
        if (self.chunk_count == 0) return;
        var index = m.chunk + 1;
        while (index <= self.active) : (index += 1) self.used[index] = 0;
        self.active = m.chunk;
        self.used[m.chunk] = m.used;
    }

    pub fn deinit(self: *VmStackArena, account: *memory.MemoryAccount) void {
        for (self.chunks[0..self.chunk_count]) |chunk| {
            if (chunk.len != 0) account.free(JSValue, chunk);
        }
        self.chunks = @splat(&.{});
        self.used = @splat(0);
        self.chunk_count = 0;
        self.active = 0;
    }
};

pub const RuntimeOptions = struct {
    trace_writer: ?*std.Io.Writer = null,
    memory_limit: ?usize = null,
    gc_threshold: usize = default_gc_threshold,
    gc_policy: gc.Policy = .{},
    stack_size: usize = default_stack_size,
    interrupt_handler: ?InterruptHandler = null,
    interrupt_context: ?*anyopaque = null,
    can_block: bool = false,
};

pub const Options = RuntimeOptions;

pub const MemoryUsage = struct {
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
    atom_bytes: usize,
    object_count: usize,
    object_bytes: usize,
    shape_count: usize,
    shape_bytes: usize,
    module_count: usize,
    module_bytes: usize,
    registered_class_count: usize,
    class_record_count: usize,
    class_bytes: usize,
};

pub const GCPollMode = enum {
    normal,
    callback_boundary,
    idle,
    safepoint,
    urgent,

    /// Whether this poll may be answered with a minor collection.
    ///
    /// A minor only proves young objects dead, so it is progress rather than
    /// a full collection. Modes that exist to make progress can take it;
    /// `urgent` cannot, because its caller is out of headroom and needs the
    /// whole heap examined. `normal` cannot either: it is the allocation
    /// threshold, and answering that with a young-only pass would quietly
    /// weaken what every existing caller of a threshold collection receives.
    pub fn acceptsMinor(self: GCPollMode) bool {
        return switch (self) {
            .idle, .safepoint, .callback_boundary => true,
            .normal, .urgent => false,
        };
    }

    /// Root-scan policy for the collection this poll may run. Engine-internal
    /// triggers fire with mutator native frames live on the stack; those
    /// frames are entitled to hold rc references without a ValueRootFrame
    /// (the conservative scanner is the covering mechanism), so they must
    /// scan conservatively even in test builds. Host-quiescent triggers
    /// (explicit forceGC, event-loop idle) keep the precise-only test split
    /// that makes liveness tests deterministic and keeps the missing-root
    /// forcing function alive.
    pub fn rootScan(self: GCPollMode) GCRootScan {
        return switch (self) {
            .normal, .safepoint, .callback_boundary => .engine_active,
            .urgent, .idle => .declared_only,
        };
    }
};

/// See `GCPollMode.rootScan`. `declared_only` is only honoured in test
/// builds; CLI/production collections always add the conservative pass.
pub const GCRootScan = enum { engine_active, declared_only };

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

pub const ValueRootBuffer = struct {
    values: []JSValue = &.{},

    pub fn initCopy(rt: *JSRuntime, source: []const JSValue) !ValueRootBuffer {
        if (source.len == 0) return .{};

        const values = try rt.memory.alloc(JSValue, source.len);
        var initialized: usize = 0;
        errdefer {
            for (values[0..initialized]) |value| value.free(rt);
            rt.memory.free(JSValue, values);
        }
        for (source, 0..) |value, idx| {
            values[idx] = value.dup();
            initialized += 1;
        }
        return .{ .values = values };
    }

    pub fn deinit(self: *ValueRootBuffer, rt: *JSRuntime) void {
        const values = self.values;
        self.values = &.{};
        for (values) |*slot| {
            const value = slot.*;
            slot.* = JSValue.undefinedValue();
            value.free(rt);
        }
        if (values.len != 0) rt.memory.free(JSValue, values);
    }

    pub fn slice(self: *ValueRootBuffer) ValueRootSlice {
        return .{ .mutable = &self.values };
    }
};

/// `ValueRootBuffer` for slot-typed var-ref cell slices (`[]*VarRef`,
/// VARREFS-SLOT-TYPING-BLUEPRINT phase D): a rooted, refcount-holding copy of
/// a cell slice, refcount behavior identical to the pre-typed initCopy of the
/// same cells as JSValues.
pub const CellRootBuffer = struct {
    cells: []*var_ref_mod.VarRef = &.{},

    pub fn initCopy(rt: *JSRuntime, source: []const *var_ref_mod.VarRef) !CellRootBuffer {
        if (source.len == 0) return .{};
        const cells = try rt.memory.alloc(*var_ref_mod.VarRef, source.len);
        for (source, 0..) |cell, idx| cells[idx] = cell.dupCell();
        return .{ .cells = cells };
    }

    pub fn deinit(self: *CellRootBuffer, rt: *JSRuntime) void {
        const cells = self.cells;
        self.cells = &.{};
        for (cells) |cell| cell.freeCell(rt);
        if (cells.len != 0) rt.memory.free(*var_ref_mod.VarRef, cells);
    }

    pub fn slice(self: *CellRootBuffer) ValueRootSlice {
        return .{ .cells = &self.cells };
    }
};

pub const ValueRootValue = struct {
    value: *JSValue,
};

pub const ObjectRootValue = struct {
    object: *?*Object,
};

/// A GC header (Shape, Module, VarRef, FunctionBytecode, realm) named as a
/// root for a mutation or construction window. Tracing does not treat a Zig
/// `*Shape` local as a root unless it is named here.
pub const HeaderRootValue = struct {
    header: *gc.Header,
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
    scalar_skipped: usize = 0,

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
    values: []const ValueRootValue = &.{},
    objects: []const ObjectRootValue = &.{},
    headers: if (value_root_frames_enabled) []const HeaderRootValue else void =
        if (value_root_frames_enabled) &.{} else {},

    /// True when this frame roots a native JSValue/cell array or window.
    /// Conservative scanning of the C stack sees the backing pointer, not the
    /// values stored behind it, so these must stay precise-rooted. Scalar
    /// `.values` / `.objects` slots that point at Zig locals can wait for a
    /// register/stack scanner (design §7.1).
    ///
    /// Heap-backed `.values` arrays (`RootedValueCopies`, 3 call sites) stay on
    /// `.values`. They are not a root gap: that helper builds one
    /// `ValueRootValue` per element, so every value already has its own exact
    /// root pointer and `traceValueRootFrames` visits each one. `.slices`
    /// would describe the same window in one descriptor instead of N pointers
    /// — an efficiency change, not a correctness one — and it moves production
    /// codegen, so it stays unconverted until something needs the density.
    pub inline fn hasNativeWindow(self: *const ValueRootFrame) bool {
        return self.slices.len != 0;
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
                if (!container) {
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

    /// Test/measurement helper: link only if this is a container/window,
    /// regardless of the compile-time policy. Used to quantify all-on vs
    /// containers-only against the same frame set.
    pub fn activateContainersOnly(self: *ValueRootFrame, rt: *JSRuntime) void {
        if (comptime !value_root_frames_enabled) return;
        if (!self.hasNativeWindow()) {
            if (comptime builtin.is_test) {
                value_root_frame_stats.activate_calls += 1;
                value_root_frame_stats.scalar_skipped += 1;
            }
            return;
        }
        self.activate(rt);
    }
};

/// A `ValueRootFrame` plus the storage it points at, held in one local.
///
/// The manual spelling of this — declare a `[_]ValueRootValue` array, declare
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

        storage: if (value_root_scalar_scopes_enabled) [count]ValueRootValue else void =
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
        inline for (slots, 0..) |slot, index| scope.storage[index] = .{ .value = slot };
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

        storage: if (value_root_scalar_scopes_enabled) [count]ObjectRootValue else void =
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
        inline for (slots, 0..) |slot, index| scope.storage[index] = .{ .object = slot };
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

    pub fn constValues(self: *RootVisitor, stored: []const JSValue) RootTraceError!void {
        for (stored) |stored_value| try self.constValue(stored_value);
    }

    pub fn optionalValue(self: *RootVisitor, slot: *?JSValue) RootTraceError!void {
        if (slot.*) |stored| {
            var value_slot = stored;
            try self.value(&value_slot);
            slot.* = value_slot;
        }
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

pub const RootProvider = struct {
    context: *anyopaque,
    trace: *const fn (context: *anyopaque, visitor: *RootVisitor) RootTraceError!void,
};

pub const RootSlot = struct {
    value: JSValue = JSValue.undefinedValue(),
};

pub const WeakPersistentCallback = *const fn (runtime: *JSRuntime, context: ?*anyopaque) void;

pub const WeakRootSlot = struct {
    identity: ?usize = null,
    callback: ?WeakPersistentCallback = null,
    callback_context: ?*anyopaque = null,
};

pub const JSValueHandle = struct {
    runtime: ?*JSRuntime = null,
    slot: ?*RootSlot = null,

    /// Takes ownership of `value`.
    pub fn init(runtime: *JSRuntime, value: JSValue) !JSValueHandle {
        const slot = runtime.createPersistentRootSlot(value) catch |err| {
            value.free(runtime);
            return err;
        };
        return .{
            .runtime = runtime,
            .slot = slot,
        };
    }

    /// Duplicates `value` before storing it.
    pub fn initDup(runtime: *JSRuntime, value: JSValue) !JSValueHandle {
        const retained = value.dup();
        return init(runtime, retained);
    }

    pub fn get(self: JSValueHandle) JSValue {
        const slot = self.slot orelse return JSValue.undefinedValue();
        return slot.value;
    }

    pub fn deinit(self: *JSValueHandle) void {
        const runtime = self.runtime orelse return;
        const slot = self.slot orelse return;
        self.runtime = null;
        self.slot = null;
        runtime.destroyPersistentRootSlot(slot);
    }

    /// Compatibility spelling: by-value wrapper that asserts `rt` matches the
    /// handle's runtime, then drops the root. Prefer `deinit` on a mutable handle.
    pub fn destroy(self: JSValueHandle, rt: *JSRuntime) void {
        if (self.runtime) |runtime| std.debug.assert(runtime == rt);
        var owned = self;
        owned.deinit();
    }

    /// Transfer ownership of the rooted value out of the handle.
    pub fn take(self: *JSValueHandle) JSValue {
        const runtime = self.runtime orelse return JSValue.undefinedValue();
        const slot = self.slot orelse return JSValue.undefinedValue();
        const value = runtime.takePersistentRootSlot(slot);
        self.runtime = null;
        self.slot = null;
        return value;
    }
};

pub const LocalHandle = struct {
    slot: *RootSlot,

    pub fn get(self: LocalHandle) JSValue {
        return self.slot.value;
    }

    pub fn valueSlot(self: LocalHandle) *JSValue {
        return &self.slot.value;
    }
};

pub const HandleScope = struct {
    runtime: *JSRuntime,
    start: usize,
    active: bool = true,

    pub fn enter(runtime: *JSRuntime) HandleScope {
        return .{
            .runtime = runtime,
            .start = runtime.local_root_slots.len,
        };
    }

    pub fn deinit(self: *HandleScope) void {
        if (!self.active) return;
        std.debug.assert(self.start <= self.runtime.local_root_slots.len);
        self.runtime.clearLocalRootSlotsFrom(self.start);
        self.active = false;
    }

    /// Takes ownership of `value`.
    pub fn local(self: *HandleScope, value: JSValue) !LocalHandle {
        std.debug.assert(self.active);
        const slot = self.runtime.createLocalRootSlot(value) catch |err| {
            value.free(self.runtime);
            return err;
        };
        return .{ .slot = slot };
    }

    /// Duplicates `value` before storing it.
    pub fn localDup(self: *HandleScope, value: JSValue) !LocalHandle {
        return self.local(value.dup());
    }
};

pub const WeakPersistentValue = struct {
    runtime: ?*JSRuntime = null,
    slot: ?*WeakRootSlot = null,

    pub fn init(
        runtime: *JSRuntime,
        value: JSValue,
        callback: ?WeakPersistentCallback,
        callback_context: ?*anyopaque,
    ) !WeakPersistentValue {
        const identity = (try object_mod.Object.weakIdentityFromValue(runtime, value)) orelse return error.InvalidWeakTarget;
        const slot = try runtime.createWeakRootSlot(identity, callback, callback_context);
        runtime.retainWeakIdentity(identity);
        return .{
            .runtime = runtime,
            .slot = slot,
        };
    }

    pub fn get(self: WeakPersistentValue) JSValue {
        const runtime = self.runtime orelse return JSValue.undefinedValue();
        const slot = self.slot orelse return JSValue.undefinedValue();
        const identity = slot.identity orelse return JSValue.undefinedValue();
        return runtime.valueFromWeakIdentity(identity);
    }

    pub fn isAlive(self: WeakPersistentValue) bool {
        const runtime = self.runtime orelse return false;
        const slot = self.slot orelse return false;
        const identity = slot.identity orelse return false;
        return runtime.weakIdentityIsCurrentlyLive(identity);
    }

    pub fn deinit(self: *WeakPersistentValue) void {
        const runtime = self.runtime orelse return;
        const slot = self.slot orelse return;
        self.runtime = null;
        self.slot = null;
        runtime.destroyWeakRootSlot(slot);
    }

    pub fn destroy(self: WeakPersistentValue, rt: *JSRuntime) void {
        if (self.runtime) |runtime| std.debug.assert(runtime == rt);
        var owned = self;
        owned.deinit();
    }
};

pub const WeakPersistent = WeakPersistentValue;

pub const NativePin = struct {
    runtime: ?*JSRuntime = null,
    header: ?*gc.Header = null,

    pub fn deinit(self: *NativePin) void {
        const runtime = self.runtime orelse return;
        const header = self.header orelse return;
        self.runtime = null;
        self.header = null;
        runtime.gc.unpinHeader(header);
        gc.release(runtime, header);
    }
};

pub fn pinValueForNative(runtime: *JSRuntime, value: JSValue) !?NativePin {
    const header = value.refHeader() orelse value.objectHeader() orelse return null;
    return try pinHeaderForNative(runtime, header);
}

pub fn pinHeaderForNative(runtime: *JSRuntime, header: *gc.Header) !NativePin {
    gc.retain(header);
    errdefer gc.release(runtime, header);
    try runtime.gc.pinHeader(header);
    return .{
        .runtime = runtime,
        .header = header,
    };
}

pub const DeferredWeakValueFree = struct {
    value: JSValue,
    prepared_identity: ?usize = null,
};

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

pub const CachedIteratorNextEntry = struct {
    object: *Object,
    value: ?JSValue = null,
};

const RecentTwoUnitString = struct {
    first: u16,
    second: u16,
    string: *string.String,
};

const RecentAtomString = struct {
    atom_id: atom.Atom,
    string: *string.String,
};

const root_provider_inline_capacity = 1;

/// A Runtime and every Realm/heap structure owned by it are mutated only by
/// the thread that initialized the Runtime. Process-global facilities with
/// their own synchronization (notably ClassId allocation) are independent of
/// this contract.
pub const RuntimeMutationError = error{WrongRuntimeThread};
pub const RuntimeCollectionError = gc.CollectionError || RuntimeMutationError;

/// Cold runtime bookkeeping whose ranges fit in one byte. The atom-string
/// cache is four-way, so its cursor needs only two bits; combining it with the
/// runtime-allocation ownership bit preserves both semantics while freeing the
/// former usize cursor word for hot VM stack policy state.
const RuntimeCompactState = packed struct(u8) {
    recent_atom_string_next: u2 = 0,
    owns_self_allocation: bool = false,
    _padding: u5 = 0,
};

pub const JSRuntime = struct {
    pub const Options = RuntimeOptions;

    /// K4 hot-state cluster: the per-call/per-return execution scalars that
    /// call admission (`canEnterInlineCallDepthBytes`), commit
    /// (`commitInlineCallDepthBytes`), release (`leaveInlineCallDepthBytesRt`)
    /// and the native recursion guard (`checkNativeStackOverflow`) touch on
    /// every bytecode call. QuickJS keeps this state in the first cache lines
    /// of its JSRuntime (`stack_size`/`stack_top`/`stack_limit`,
    /// quickjs.c:348-351, plus `gc_phase`/`current_stack_frame` in the same
    /// head, quickjs.c:319-360); zjs's auto struct layout had scattered these
    /// fields across the 18-26KB tail of JSRuntime, so every call/return
    /// walked 5-6 distant cache lines (M1 dossier K4). `extern struct`
    /// guarantees declaration-order layout (auto layout scrambles same-
    /// alignment buckets); `align(64)` on the field pins the cluster into the
    /// highest-alignment bucket, i.e. the lowest offsets of JSRuntime. All
    /// eight words fit one cache line (64 bytes).
    pub const HotExecState = extern struct {
        /// QuickJS runtime execution state. These fields describe the
        /// currently executing stack, not a Realm, and are shared by every
        /// context belonging to this runtime.
        call_depth: usize = 0,
        native_call_depth: usize = 0,
        /// Planned QuickJS bytecode-frame bytes for every active bytecode
        /// call, including tail-call callers whose physical zjs Entry storage
        /// has been reused. This Runtime owner survives nested Machines and
        /// Realm switches. It remains separate from Realm interrupt cadence
        /// and native call depth.
        active_bytecode_stack_bytes: usize = 0,
        /// Logical stack budget (`rt->stack_size` analogue); the data source
        /// for both call-depth ceilings (`maxLogicalJsCallDepth` /
        /// `maxNativeJsCallDepth`).
        stack_size: usize = default_stack_size,
        /// Native (machine C-stack) recursion guard, mirroring QuickJS
        /// `rt->stack_top`/`rt->stack_limit` (quickjs.c:349-350, 2841-2860).
        /// Captured via `@frameAddress()` at the outermost eval entry
        /// (`updateNativeStackTop`, the JS_UpdateStackTop analogue — refreshed
        /// per thread because worker threads run on a different C stack than
        /// where the runtime was constructed). Zero limit means "no limit
        /// yet". `native_stack_limit` is the lower address bound
        /// (`native_stack_top - native_stack_size`); a native frame pointer
        /// below it is an overflow. See `checkNativeStackOverflow`.
        native_stack_top: usize = 0,
        native_stack_limit: usize = 0,
        native_stack_size: usize = default_native_stack_size,
        /// Head of the stack-local observable backtrace chain. Native calls
        /// and synchronous native fences both replace this pointer on entry
        /// and restore it on return, so use the eighth and final word of the
        /// first runtime cache line instead of the cold registry tail.
        current_backtrace_frame: ?*context_mod.ActiveBacktraceFrame = null,
    };

    hot: HotExecState align(64) = .{},
    /// Borrowed exec-owned authority for the currently running bytecode
    /// invocation. Core deliberately keeps this opaque: synchronous native
    /// callbacks recover the concrete Machine through exec without creating
    /// a core -> exec import cycle. Routing reads it on every eligible native
    /// callback, so keep it adjacent to the hot execution cache line.
    active_invocation: ?*anyopaque = null,
    /// R-1 small-function-inlining budget: published production bytecode bytes
    /// and bytes consumed by specialized copies. Exec reads these; core only
    /// accounts.
    small_inline_published_bytes: usize = 0,
    small_inline_specialized_bytes: usize = 0,
    small_inline_destroy: ?*const fn (rt: *JSRuntime, fb: *anyopaque) void = null,
    owner_thread_id: std.Thread.Id,
    memory: memory.MemoryAccount,
    compact_state: RuntimeCompactState = .{},
    gc: gc.Registry,
    /// Parallel STW mark pool. Lazy: threads spawn on the first slice whose
    /// frontier crosses the parallel threshold, so runtimes that never build a
    /// big heap never pay.
    gc_mark_pool: @import("gc_parallel_mark.zig").Pool = .{},
    atoms: atom.AtomTable,
    classes: class.Table,
    shapes: shape.Registry,
    dynamic_import_loader: DynamicImportLoader = .{},
    auto_init_descriptors: std.ArrayListUnmanaged(*property.AutoInit) = .empty,
    materialize_builtin_namespace_cb: ?*const fn (rt: *JSRuntime, global: *Object, kind: property.AutoInitKind) anyerror!?JSValue = null,
    materialize_context_global_cb: ?*const fn (ctx: *context_mod.JSContext) anyerror!*Object = null,
    /// Bootstrap install seam: builds the standard global object. Seeded from the
    /// process-global default at `init`; `exec/standard_globals.zig` registers
    /// that default. Core invokes it through this callback seam.
    install_standard_globals_cb: ?StandardGlobalsInstaller = null,
    /// Own-property count to reserve on a global object before running
    /// `install_standard_globals_cb`. Seeded alongside the installer at `init`.
    standard_global_own_property_capacity: usize = 0,

    /// QuickJS `context_list`: intrusive membership only.  Realm ownership is
    /// carried by `RealmRef` and the GC header, never by these links.
    context_head: ?*context_mod.JSContext = null,
    context_tail: ?*context_mod.JSContext = null,
    /// Construction-only membership. These realms are deliberately absent
    /// from `context_head` and root-provider traversal until publication.
    constructing_context_head: ?*context_mod.JSContext = null,
    constructing_context_tail: ?*context_mod.JSContext = null,

    borrowed_reference_holders: []*Object = &.{},
    borrowed_reference_holders_capacity: usize = 0,
    weak_reference_holder_head: ?*Object = null,
    weak_reference_holder_tail: ?*Object = null,
    root_providers: []RootProvider = &.{},
    root_providers_capacity: usize = 0,
    root_providers_inline: [root_provider_inline_capacity]RootProvider = undefined,
    local_root_slots: []*RootSlot = &.{},
    local_root_slots_capacity: usize = 0,
    persistent_root_slots: []*RootSlot = &.{},
    persistent_root_slots_capacity: usize = 0,
    weak_root_slots: []*WeakRootSlot = &.{},
    weak_root_slots_capacity: usize = 0,
    active_value_roots: ?*const ValueRootFrame = null,
    job_queue: job_mod.Queue = undefined,
    /// WeakRef [[KeptAlive]] (tracing-gc-design.md §9.2). Traced as a root
    /// and cleared at job end.
    weakref_kept_alive: []JSValue = &.{},
    weakref_kept_alive_capacity: usize = 0,
    /// Test-only root-scan override (`forcePreciseRootScanForTest`). Pacing
    /// MACHINERY tests call the engine-trigger entry points from a quiescent
    /// test frame with dropGcPtr-scrubbed locals; the mode-derived
    /// `.engine_active` policy would conservatively retain their ghosts and
    /// break deterministic reclamation assertions. Production layout is
    /// untouched (void outside test builds).
    test_root_scan_override: if (builtin.is_test) ?GCRootScan else void =
        if (builtin.is_test) null else {},
    /// Cross-thread, allocation-free wake signal for host completions that
    /// must be consumed on this Runtime's owner thread. Atomics.waitAsync is
    /// the first producer; the signal carries no JS state and is reset only
    /// while the producer registry mutex excludes a lost-wakeup race.
    host_completion_event: std.Io.Event = .unset,
    deferred_native_cleanups: []NativeCleanupJob = &.{},
    deferred_native_cleanups_capacity: usize = 0,
    draining_deferred_native_cleanups: bool = false,
    deferred_native_cleanup_run_count: usize = 0,
    deferred_class_payload_finalizers: []DeferredClassPayloadFinalizer = &.{},
    deferred_class_payload_finalizers_capacity: usize = 0,
    /// Live wrappers whose reentrant plugin finalizer has a reserved queue
    /// slot. Root tracing visits only their declared payload edges: the
    /// wrapper itself may be condemned, but the callback's payload graph must
    /// survive until ownership transfers to the queued job.
    deferred_class_payload_roots: []*Object = &.{},
    deferred_class_payload_roots_capacity: usize = 0,
    reserved_deferred_class_payload_finalizer_slots: usize = 0,
    draining_deferred_class_payload_finalizers: bool = false,
    active_deferred_class_payload_finalizer: ?*DeferredClassPayloadFinalizer = null,
    deferred_class_payload_finalizer_run_count: usize = 0,
    deferred_weak_value_frees: []DeferredWeakValueFree = &.{},
    deferred_weak_value_frees_capacity: usize = 0,
    draining_deferred_weak_value_frees: bool = false,
    borrowed_weak_cleanup_identities: []usize = &.{},
    borrowed_weak_cleanup_identities_capacity: usize = 0,
    /// O(1) membership companion for `borrowed_weak_cleanup_identities`.
    /// Only even (object) identities are inserted; symbol identities keep
    /// the slice-scan semantics of the identity list.
    borrowed_weak_cleanup_identity_set: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// Weak identity registry: maps object header addresses to monotonically
    /// increasing weak ids and back. Weak slots (WeakRef/WeakMap/WeakSet/
    /// FinalizationRegistry/WeakRootSlot) store `weak_id << 1` instead of the
    /// header address, so a recycled allocation can never alias a stale weak
    /// identity and weak lookups are O(1) instead of a full heap scan.
    weak_object_ids: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    weak_id_objects: std.AutoHashMapUnmanaged(usize, *Object) = .empty,
    next_weak_id: usize = 1,
    borrowed_weak_cleanup_realm_identities: []usize = &.{},
    borrowed_weak_cleanup_realm_identities_capacity: usize = 0,
    borrowed_weak_cleanup_active: bool = false,
    borrowed_weak_cleanup_realm_identity_fallback: bool = false,
    borrowed_weak_cleanup_seen_holder: bool = false,
    borrowed_weak_cleanup_needs_rescan: bool = false,
    current_deferred_weak_value_free_identity: ?usize = null,
    malloc_gc_threshold: usize = default_gc_threshold,
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
    vm_stack_arena_policy: VmStackWindowPolicy = VmStackWindowPolicy.arenaForLimit(default_stack_size),
    /// Per-runtime VM value-stack arena for bytecode call frames. Pinned
    /// `align(64)` alongside `hot` so its scalar head (chunk_count/active/
    /// used[active], touched by every call's carve and every return's
    /// restore) stays in the runtime's front cache lines instead of the
    /// auto-layout 24-26KB tail (M1 dossier K4).
    vm_stack: VmStackArena align(64) = .{},
    interrupt_handler: ?InterruptHandler = null,
    interrupt_context: ?*anyopaque = null,
    can_block: bool = false,
    /// Lazy cache of single-byte (latin1) strings for ASCII code units.
    /// Populated on first request via `singleByteString`. Each cached
    /// String holds a permanent ref-count + 1 contributed by the cache;
    /// borrowers `retain` and `free` normally, and the cache slot is
    /// torn down on `JSRuntime.destroy`.
    ///
    /// Hot paths like `getStringIndexValue` (`hex[i]`-style indexing in
    /// URI decode sweeps) call this thousands of times per
    /// inner iteration; reusing cached instances eliminates two heap
    /// allocations per call.
    single_byte_strings: [128]?*string.String = @splat(null),
    /// Lazy cache for the immutable empty string. This shows up during
    /// standard global setup and in common `String`/JSON paths.
    empty_string: ?*string.String = null,
    /// Single-entry cache for hot two-code-unit strings. URI stress loops
    /// compare `decodeURI("%F0...")` against
    /// `String.fromCharCode(H, L)` for each non-BMP code point; keeping
    /// the most recent pair lets both calls share one immutable string
    /// without retaining the whole sweep.
    recent_two_unit_string: ?RecentTwoUnitString = null,
    /// Tiny cache for atom-to-string materialization. This catches hot
    /// bytecode constants without retaining every atom string in the program;
    /// regexp literals in particular alternate between source and flags atoms.
    recent_atom_strings: [4]?RecentAtomString = @splat(null),
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
    external_host_functions: []host_function.ExternalRecord = &.{},
    external_host_functions_capacity: usize = 0,
    cached_iterator_next_entries: []CachedIteratorNextEntry = &.{},
    cached_iterator_next_entries_capacity: usize = 0,
    /// Static internal-builtin record table, indexed
    /// `[domain][domain-local id]` with the `NativeBuiltinDomain` enum value
    /// as the outer index (slot 0 unused). Built at comptime by
    /// `exec/internal_builtins.zig` and assigned by the standard-global install
    /// path; exec dispatches through
    /// `internalBuiltinRecord` with no compile-time knowledge of individual
    /// builtins. Empty until standard globals are installed, which is also
    /// the only path that creates native function objects carrying these ids.
    internal_builtins: []const host_function.InternalRecordTable = &.{},
    pub fn init(self: *JSRuntime, allocator: std.mem.Allocator, options: RuntimeOptions) !void {
        const account = if (options.trace_writer) |writer|
            memory.MemoryAccount.initWithTrace(allocator, writer)
        else
            memory.MemoryAccount.init(allocator);
        try self.initWithAccount(account, options, false);
    }

    /// Returns an owned runtime. Caller must release it with `destroy`.
    pub fn create(allocator: std.mem.Allocator) !*JSRuntime {
        return createWithOptions(allocator, .{});
    }

    /// Returns an owned runtime. Caller must release it with `destroy`.
    pub fn createWithOptions(allocator: std.mem.Allocator, options: RuntimeOptions) !*JSRuntime {
        var account = if (options.trace_writer) |writer|
            memory.MemoryAccount.initWithTrace(allocator, writer)
        else
            memory.MemoryAccount.init(allocator);
        const rt = try account.create(JSRuntime);
        errdefer account.destroy(JSRuntime, rt);
        try rt.initWithAccount(account, options, true);
        return rt;
    }

    /// Returns an owned runtime with optional allocation tracing.
    /// Caller must release it with `destroy`.
    pub fn createWithTrace(allocator: std.mem.Allocator, trace_writer: ?*std.Io.Writer) !*JSRuntime {
        return createWithOptions(allocator, .{ .trace_writer = trace_writer });
    }

    fn initWithAccount(rt: *JSRuntime, account: memory.MemoryAccount, options: RuntimeOptions, owns_self_allocation: bool) !void {
        rt.owner_thread_id = std.Thread.getCurrentId();
        rt.memory = account;
        rt.compact_state = .{ .owns_self_allocation = owns_self_allocation };
        // MemoryAccount's std.mem.Allocator facade stores a pointer to the
        // account, so bind it only after the account reaches this stable field
        // address. All runtime `.allocator` / `.persistent_allocator` users now
        // participate in the same limit and live-byte accounting.
        rt.memory.activateRuntimeAccounting();
        rt.memory.trigger_gc_fn = null;
        rt.memory.trigger_gc_ctx = null;
        rt.memory.limit_gc_fn = null;
        rt.memory.limit_gc_ctx = null;
        rt.memory.setLimit(options.memory_limit);
        rt.gc = gc.Registry.init(&rt.memory, options.gc_policy);
        rt.gc.initLists();
        // Only now: the observer stores a pointer into `rt.gc`, so it has to be
        // installed after the registry reaches its stable field address, for
        // the same reason `activateRuntimeAccounting` waits above.
        rt.gc.observeSlabArenas(&rt.memory.small_slab);
        rt.gc.serveObjectCells(&rt.memory);
        rt.atoms = atom.AtomTable.init(&rt.memory);
        rt.atoms.runtime = rt;
        try rt.classes.initInPlace(&rt.memory, &rt.atoms);
        errdefer {
            rt.classes.deinit();
        }
        rt.shapes = shape.Registry.init(rt, &rt.memory, &rt.atoms, &rt.gc);
        rt.dynamic_import_loader = .{};
        rt.auto_init_descriptors = .empty;
        rt.materialize_builtin_namespace_cb = null;
        rt.materialize_context_global_cb = null;
        rt.small_inline_published_bytes = 0;
        rt.small_inline_specialized_bytes = 0;
        rt.small_inline_destroy = null;
        rt.install_standard_globals_cb = default_standard_globals_installer;
        rt.standard_global_own_property_capacity = default_standard_global_own_property_capacity;
        rt.context_head = null;
        rt.context_tail = null;
        rt.constructing_context_head = null;
        rt.constructing_context_tail = null;
        rt.borrowed_reference_holders = &.{};
        rt.borrowed_reference_holders_capacity = 0;
        rt.weak_reference_holder_head = null;
        rt.weak_reference_holder_tail = null;
        rt.root_providers_inline = undefined;
        rt.root_providers = rt.root_providers_inline[0..0];
        rt.root_providers_capacity = rt.root_providers_inline.len;
        rt.local_root_slots = &.{};
        rt.local_root_slots_capacity = 0;
        rt.persistent_root_slots = &.{};
        rt.persistent_root_slots_capacity = 0;
        rt.weak_root_slots = &.{};
        rt.weak_root_slots_capacity = 0;
        rt.active_value_roots = null;
        rt.job_queue = job_mod.Queue.init(&rt.memory);
        rt.weakref_kept_alive = &.{};
        rt.weakref_kept_alive_capacity = 0;
        if (comptime builtin.is_test) rt.test_root_scan_override = null;
        rt.deferred_native_cleanups = &.{};
        rt.deferred_native_cleanups_capacity = 0;
        rt.draining_deferred_native_cleanups = false;
        rt.deferred_native_cleanup_run_count = 0;
        rt.deferred_class_payload_finalizers = &.{};
        rt.deferred_class_payload_finalizers_capacity = 0;
        rt.deferred_class_payload_roots = &.{};
        rt.deferred_class_payload_roots_capacity = 0;
        rt.reserved_deferred_class_payload_finalizer_slots = 0;
        rt.draining_deferred_class_payload_finalizers = false;
        rt.active_deferred_class_payload_finalizer = null;
        rt.deferred_class_payload_finalizer_run_count = 0;
        rt.deferred_weak_value_frees = &.{};
        rt.deferred_weak_value_frees_capacity = 0;
        rt.draining_deferred_weak_value_frees = false;
        rt.borrowed_weak_cleanup_identities = &.{};
        rt.borrowed_weak_cleanup_identities_capacity = 0;
        rt.borrowed_weak_cleanup_identity_set = .empty;
        rt.weak_object_ids = .empty;
        rt.weak_id_objects = .empty;
        rt.next_weak_id = 1;
        rt.borrowed_weak_cleanup_realm_identities = &.{};
        rt.borrowed_weak_cleanup_realm_identities_capacity = 0;
        rt.borrowed_weak_cleanup_active = false;
        rt.borrowed_weak_cleanup_realm_identity_fallback = false;
        rt.borrowed_weak_cleanup_seen_holder = false;
        rt.borrowed_weak_cleanup_needs_rescan = false;
        rt.current_deferred_weak_value_free_identity = null;
        rt.malloc_gc_threshold = options.gc_threshold;
        rt.gc_running = false;
        rt.current_exception = JSValue.uninitialized();
        rt.current_exception_uncatchable = false;
        rt.current_exception_out_of_memory = false;
        rt.hot.call_depth = 0;
        rt.hot.native_call_depth = 0;
        rt.hot.active_bytecode_stack_bytes = 0;
        rt.formatting_error_stack = false;
        rt.backtrace_frames = &.{};
        rt.backtrace_capacity = 0;
        rt.hot.current_backtrace_frame = null;
        rt.active_native_call = null;
        rt.active_invocation = null;
        rt.hot.stack_size = options.stack_size;
        rt.vm_stack_arena_policy = VmStackWindowPolicy.arenaForLimit(options.stack_size);
        rt.hot.native_stack_size = initial_native_stack_size;
        // Arm the native recursion guard at construction, mirroring QuickJS
        // JS_NewRuntime2 -> JS_UpdateStackTop (quickjs.c:2116). This covers every
        // entry path (eval / evalScript / ES module graph) even those that do not
        // re-arm; the host creates the runtime and starts execution from the same
        // shallow call level, so this baseline is valid. Outermost eval/module
        // entries additionally re-arm (JS_UpdateStackTop analogue) for a precise
        // per-thread base — required when execution runs on a different thread
        // than construction (conformance worker runtimes).
        rt.hot.native_stack_top = @frameAddress();
        rt.hot.native_stack_limit = if (initial_native_stack_size == 0) 0 else rt.hot.native_stack_top -| initial_native_stack_size;
        rt.vm_stack = .{};
        rt.interrupt_handler = options.interrupt_handler;
        rt.interrupt_context = options.interrupt_context;
        rt.can_block = options.can_block;
        rt.single_byte_strings = @splat(null);
        rt.empty_string = null;
        rt.recent_two_unit_string = null;
        rt.recent_atom_strings = @splat(null);
        rt.percent_hex_strings = @splat(null);
        rt.small_int_strings = @splat(null);
        rt.performance_time_origin_ms = 0;
        rt.opcode_profile = null;
        rt.external_host_functions = &.{};
        rt.external_host_functions_capacity = 0;
        rt.cached_iterator_next_entries = &.{};
        rt.cached_iterator_next_entries_capacity = 0;
        rt.internal_builtins = &.{};
        rt.memory.profile_alloc_count = null;
        rt.memory.useIndependentSmallObjectSlabArenaBacking();
        rt.memory.enableSmallObjectSlab();
        rt.memory.trigger_gc_fn = JSRuntime.triggerGCOnAllocation;
        rt.memory.trigger_gc_ctx = rt;
        rt.memory.limit_gc_fn = JSRuntime.collectBeforeLimitRejection;
        rt.memory.limit_gc_ctx = rt;
    }

    pub fn setOpcodeProfile(self: *JSRuntime, opcode_profile: ?*profile.OpcodeProfile) void {
        self.opcode_profile = opcode_profile;
        self.memory.profile_alloc_count = if (opcode_profile) |prof| &prof.alloc_count else null;
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

    pub fn deinit(self: *JSRuntime) void {
        self.assertOwnerThread();
        self.assertIdleForTeardown();
        self.vm_stack.deinit(&self.memory);
        const backtrace_frames = self.backtrace_frames;
        const backtrace_capacity = self.backtrace_capacity;
        self.backtrace_frames = &.{};
        self.backtrace_capacity = 0;
        for (backtrace_frames) |frame| {
            self.atoms.free(frame.function_name);
            self.atoms.free(frame.filename);
            frame.function_value.free(self);
        }
        if (backtrace_capacity != 0) {
            self.memory.free(context_mod.BacktraceFrame, backtrace_frames.ptr[0..backtrace_capacity]);
        }
        const current_exception = self.current_exception;
        self.current_exception = JSValue.uninitialized();
        self.current_exception_uncatchable = false;
        self.current_exception_out_of_memory = false;
        current_exception.free(self);
        self.clearWeakRefKeptAlive();
        self.job_queue.deinit();
        self.drainDeferredWeakValueFrees();
        self.clearPendingFinalizationJobs();
        const recent_two_unit_string = self.recent_two_unit_string;
        self.recent_two_unit_string = null;
        if (recent_two_unit_string) |cached| JSValue.string(cached.string.header()).free(self);
        for (&self.recent_atom_strings) |*slot| {
            const cached = slot.*;
            slot.* = null;
            if (cached) |stored| JSValue.string(stored.string.header()).free(self);
        }
        self.compact_state.recent_atom_string_next = 0;
        const empty_string = self.empty_string;
        self.empty_string = null;
        if (empty_string) |cached| JSValue.string(cached.header()).free(self);
        for (&self.single_byte_strings) |*slot| {
            const cached = slot.*;
            slot.* = null;
            if (cached) |stored| JSValue.string(stored.header()).free(self);
        }
        for (&self.percent_hex_strings) |*slot| {
            const cached = slot.*;
            slot.* = null;
            if (cached) |stored| JSValue.string(stored.header()).free(self);
        }
        for (&self.small_int_strings) |*slot| {
            const cached = slot.*;
            slot.* = null;
            if (cached) |stored| JSValue.string(stored.header()).free(self);
        }
        self.clearExternalHostFunctions();
        self.drainDeferredNativeCleanups();
        self.assertNoOutstandingValueHandles();
        self.drainDeferredNativeCleanups();
        self.drainDeferredClassPayloadFinalizers();
        self.releaseNativeFunctionRealmsForTeardown();
        self.gc.host_quiescent = true;
        _ = self.runObjectCycleRemoval();
        self.drainDeferredWeakValueFrees();
        self.drainDeferredNativeCleanups();
        self.drainDeferredClassPayloadFinalizers();
        self.clearPendingFinalizationJobs();
        _ = self.runObjectCycleRemoval();
        self.gc.host_quiescent = false;
        self.drainDeferredWeakValueFrees();
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
        self.atoms.releaseCachedStrings(self);
        // The context list is borrowed enumeration, never a teardown owner.
        // Named host/harness owners are released above; public RealmRefs must
        // be released by their callers before destroying the Runtime.
        std.debug.assert(self.context_head == null);
        std.debug.assert(self.context_tail == null);
        std.debug.assert(self.constructing_context_head == null);
        std.debug.assert(self.constructing_context_tail == null);
        self.gc.deinit(self);
        std.debug.assert(self.weak_reference_holder_head == null);
        std.debug.assert(self.weak_reference_holder_tail == null);
        self.drainDeferredNativeCleanups();
        self.drainDeferredClassPayloadFinalizers();
        // Shapes and every other GC-managed atom owner are now gone. Clear
        // residual dynamic symbol bodies (notably Symbol.for's registry ref)
        // before AtomTable.deinit asserts that no materialized bodies remain.
        self.atoms.releaseValueSymbolBodiesAfterGc(self);
        // These containers live for the whole runtime. `memory.allocator` may
        // temporarily point at a parser arena, so both allocation and teardown
        // must use the stable backing allocator that owns runtime state.
        self.borrowed_weak_cleanup_identity_set.deinit(self.memory.persistent_allocator);
        self.weak_object_ids.deinit(self.memory.persistent_allocator);
        self.weak_id_objects.deinit(self.memory.persistent_allocator);
        for (self.auto_init_descriptors.items) |stored| self.destroyRuntime(property.AutoInit, stored);
        self.auto_init_descriptors.deinit(self.memory.persistent_allocator);
        self.shapes.deinit();
        self.classes.deinit();
        self.atoms.deinit();
        const borrowed_reference_holders: []*Object = if (self.borrowed_reference_holders_capacity != 0) self.borrowed_reference_holders.ptr[0..self.borrowed_reference_holders_capacity] else self.borrowed_reference_holders[0..0];
        const root_providers: []RootProvider = if (self.root_providers_capacity != 0 and !self.rootProvidersUsingInline()) self.root_providers.ptr[0..self.root_providers_capacity] else self.root_providers[0..0];
        const local_root_slots: []*RootSlot = if (self.local_root_slots_capacity != 0) self.local_root_slots.ptr[0..self.local_root_slots_capacity] else self.local_root_slots[0..0];
        const persistent_root_slots: []*RootSlot = if (self.persistent_root_slots_capacity != 0) self.persistent_root_slots.ptr[0..self.persistent_root_slots_capacity] else self.persistent_root_slots[0..0];
        const weak_root_slots: []*WeakRootSlot = if (self.weak_root_slots_capacity != 0) self.weak_root_slots.ptr[0..self.weak_root_slots_capacity] else self.weak_root_slots[0..0];
        const external_host_functions: []host_function.ExternalRecord = if (self.external_host_functions_capacity != 0) self.external_host_functions.ptr[0..self.external_host_functions_capacity] else self.external_host_functions[0..0];
        const cached_iterator_next_entries: []CachedIteratorNextEntry = if (self.cached_iterator_next_entries_capacity != 0) self.cached_iterator_next_entries.ptr[0..self.cached_iterator_next_entries_capacity] else self.cached_iterator_next_entries[0..0];
        const deferred_native_cleanups: []NativeCleanupJob = if (self.deferred_native_cleanups_capacity != 0) self.deferred_native_cleanups.ptr[0..self.deferred_native_cleanups_capacity] else self.deferred_native_cleanups[0..0];
        const deferred_class_payload_finalizers: []DeferredClassPayloadFinalizer = if (self.deferred_class_payload_finalizers_capacity != 0) self.deferred_class_payload_finalizers.ptr[0..self.deferred_class_payload_finalizers_capacity] else self.deferred_class_payload_finalizers[0..0];
        const deferred_class_payload_roots: []*Object = if (self.deferred_class_payload_roots_capacity != 0) self.deferred_class_payload_roots.ptr[0..self.deferred_class_payload_roots_capacity] else self.deferred_class_payload_roots[0..0];
        self.borrowed_reference_holders = &.{};
        self.borrowed_reference_holders_capacity = 0;
        self.root_providers = &.{};
        self.root_providers_capacity = 0;
        self.local_root_slots = &.{};
        self.local_root_slots_capacity = 0;
        self.persistent_root_slots = &.{};
        self.persistent_root_slots_capacity = 0;
        self.weak_root_slots = &.{};
        self.weak_root_slots_capacity = 0;
        self.external_host_functions = &.{};
        self.external_host_functions_capacity = 0;
        self.cached_iterator_next_entries = &.{};
        self.cached_iterator_next_entries_capacity = 0;
        self.deferred_native_cleanups = &.{};
        self.deferred_native_cleanups_capacity = 0;
        self.deferred_class_payload_finalizers = &.{};
        self.deferred_class_payload_finalizers_capacity = 0;
        self.deferred_class_payload_roots = &.{};
        self.deferred_class_payload_roots_capacity = 0;
        self.reserved_deferred_class_payload_finalizer_slots = 0;
        self.active_deferred_class_payload_finalizer = null;
        if (borrowed_reference_holders.len != 0) self.memory.free(*Object, borrowed_reference_holders);
        if (root_providers.len != 0) self.memory.free(RootProvider, root_providers);
        if (local_root_slots.len != 0) self.memory.free(*RootSlot, local_root_slots);
        if (persistent_root_slots.len != 0) self.memory.free(*RootSlot, persistent_root_slots);
        if (weak_root_slots.len != 0) self.memory.free(*WeakRootSlot, weak_root_slots);
        if (external_host_functions.len != 0) self.memory.free(host_function.ExternalRecord, external_host_functions);
        if (cached_iterator_next_entries.len != 0) self.memory.free(CachedIteratorNextEntry, cached_iterator_next_entries);
        if (deferred_native_cleanups.len != 0) self.memory.free(NativeCleanupJob, deferred_native_cleanups);
        if (deferred_class_payload_finalizers.len != 0) self.memory.free(DeferredClassPayloadFinalizer, deferred_class_payload_finalizers);
        if (deferred_class_payload_roots.len != 0) self.memory.free(*Object, deferred_class_payload_roots);
        self.memory.deinitSmallObjectSlab();
        if (self.compact_state.owns_self_allocation) {
            std.debug.assert(self.memory.allocation_count == 1);
            std.debug.assert(self.memory.allocated_bytes == memory.MemoryAccount.accountedMallocSize(@sizeOf(JSRuntime), null));
        } else {
            std.debug.assert(!self.memory.hasOutstandingAllocations());
        }
    }

    pub fn destroy(self: *JSRuntime) void {
        self.assertOwnerThread();
        self.gc_mark_pool.shutdown();
        self.deinit();
        var account = self.memory;
        account.destroy(JSRuntime, self);
        std.debug.assert(!account.hasOutstandingAllocations());
    }

    /// Checked teardown entry for hosts that cannot prove their call thread.
    /// On rejection the Runtime is untouched and remains owned by its creator.
    pub fn tryDestroy(self: *JSRuntime) RuntimeMutationError!void {
        try self.requireOwnerThread();
        self.destroy();
    }

    /// These runtime allocators reach `MemoryAccount.*NoTrigger` and therefore
    /// carry the threshold check themselves. QuickJS puts no such check in
    /// `js_malloc_rt` / `js_realloc_rt` (quickjs.c:1799-1812): its single
    /// allocation-threshold site is `js_trigger_gc` from `JS_NewObjectFromShape`
    /// (quickjs.c:5619). Gate them on the same comptime rule as the trigger
    /// callback so both halves of the mechanism stay in one place — see
    /// `memory.allocation_gc_trigger_enabled` for the full argument.
    const runtime_allocation_requests_gc = memory.allocation_gc_trigger_enabled;

    pub inline fn allocRuntime(self: *JSRuntime, comptime T: type, count: usize) ![]T {
        if (comptime runtime_allocation_requests_gc) {
            if (count != 0) {
                const bytes = std.math.mul(usize, @sizeOf(T), count) catch std.math.maxInt(usize);
                self.requestGCForAllocation(bytes);
            }
        }
        return self.memory.allocNoTrigger(T, count);
    }

    pub inline fn freeRuntime(self: *JSRuntime, comptime T: type, slice: []T) void {
        self.memory.free(T, slice);
    }

    pub inline fn remapRuntime(self: *JSRuntime, comptime T: type, slice: []T, new_count: usize) !?[]T {
        if (comptime runtime_allocation_requests_gc) {
            if (new_count > slice.len) {
                const old_bytes = std.math.mul(usize, @sizeOf(T), slice.len) catch std.math.maxInt(usize);
                const new_bytes = std.math.mul(usize, @sizeOf(T), new_count) catch std.math.maxInt(usize);
                self.requestGCForAllocation(new_bytes -| old_bytes);
            }
        }
        return self.memory.remap(T, slice, new_count);
    }

    pub inline fn createRuntime(self: *JSRuntime, comptime T: type) !*T {
        if (comptime runtime_allocation_requests_gc) self.requestGCForAllocation(@sizeOf(T));
        return self.memory.createNoTrigger(T);
    }

    pub inline fn destroyRuntime(self: *JSRuntime, comptime T: type, ptr: *T) void {
        self.memory.destroy(T, ptr);
    }

    pub inline fn allocRuntimeAlignedBytes(self: *JSRuntime, byte_count: usize, alignment: std.mem.Alignment) ![]u8 {
        if (comptime runtime_allocation_requests_gc) {
            if (byte_count != 0) self.requestGCForAllocation(byte_count);
        }
        return self.memory.allocAlignedBytesNoTrigger(byte_count, alignment);
    }

    /// QJS runs its allocation-threshold GC trigger from object creation, not
    /// from JSString/JSStringRope allocation. Production string churn therefore
    /// bypasses the per-allocation threshold bookkeeping. Test builds must keep
    /// the injected allocation callback, and force-GC builds must still collect
    /// before every runtime allocation, so those comptime modes retain the full
    /// request path.
    pub inline fn allocStringAlignedBytes(self: *JSRuntime, byte_count: usize, alignment: std.mem.Alignment) ![]u8 {
        if (comptime runtime_allocation_requests_gc) {
            if (byte_count != 0) self.requestGCForAllocation(byte_count);
        }
        return self.memory.allocAlignedBytesNoTrigger(byte_count, alignment);
    }

    pub inline fn freeRuntimeAlignedBytes(self: *JSRuntime, bytes: []u8, alignment: std.mem.Alignment) void {
        self.memory.freeAlignedBytes(bytes, alignment);
    }

    pub fn registerObject(self: *JSRuntime, object: *Object) !void {
        self.assertOwnerThread();
        // qjs add_gc_object (quickjs.c:6540) only links the header into
        // gc_obj_list; it never re-evaluates the GC threshold. The single
        // object-creation threshold check is js_trigger_gc(sizeof(JSObject))
        // at the top of JS_NewObjectFromShape (quickjs.c:5619) — mirrored here
        // by collectBeforeObjectAllocation immediately before the object body
        // allocation. Property arrays and separate payloads retain their
        // existing allocRuntime* requests; a crossing they produce stays
        // pending until the next pre-allocation boundary or scheduler poll,
        // exactly like a prop-array js_malloc crossing in qjs
        // (quickjs.c:5636) waits for the next js_trigger_gc.
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
    /// (quickjs.c:6540) has no per-registration thread check, and the release
    /// check was the single largest cost of this boundary (~18 insns: a cached
    /// TLS `getCurrentId` read pair + compare, plus the panic arm's `bl`
    /// forcing a callee-saved frame on an otherwise leaf function).
    pub fn registerObjectWithBytes(self: *JSRuntime, object: *Object, bytes: usize) !void {
        std.debug.assert(self.isOwnerThread());
        try self.gc.addInitializedWithSize(&object.header, bytes);
    }

    /// GC-list unlink + free-byte accounting boundary of an object teardown,
    /// with the allocation size supplied by the caller. `destroyFromHeader`
    /// (the sole caller) already computes the inline-class-payload layout (for
    /// the tail `freeObjectAllocation`); its `object_size` is bit-for-bit the
    /// value `allocationSize` would recompute here (both go through
    /// `inlineClassPayloadLayout(recordPtr(class_id))`, and `class_id` is unchanged
    /// between the two calls). Reusing it drops a redundant record-table lookup +
    /// 88-byte-stride multiply + inline-layout recompute off the hot free path —
    /// qjs `free_object` (quickjs.c:6340) never recomputes an object's size at
    /// teardown either (the slab block carries it).
    ///
    /// The weak/borrowed side-table links were already detached at the TOP of
    /// `destroyFromHeader` (before class-payload teardown, because those links
    /// borrow payload-owned storage), and nothing during payload teardown can
    /// re-register a finalizing object — so this boundary no longer repeats the
    /// two unregister scans. qjs `free_object` keeps no such side tables at all;
    /// `remove_gc_object` (quickjs.c:6548) is a bare `list_del`.
    ///
    /// Thread ownership is a safe-build assertion only, mirroring the register
    /// side (qjs `remove_gc_object` has no thread check either).
    pub fn unregisterObjectWithBytes(self: *JSRuntime, object: *Object, bytes: usize) void {
        // qjs remove_gc_object (quickjs.c:6548) has no thread check. The
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
        if (object.header.metaConst().flags.cycle_visited) {
            self.gc.recordDetachedHeapFreeWithBytes(&object.header, bytes);
            return;
        }
        self.gc.unlinkObjectWithBytes(&object.header, bytes);
    }

    /// Link a weak-capable payload for its full object lifetime. This is
    /// allocation-free and mirrors QuickJS's runtime weakref_list: collection
    /// emptiness changes do not mutate the list while a GC weak pass traverses
    /// it.
    pub fn registerWeakReferenceHolder(self: *JSRuntime, object: *Object) void {
        std.debug.assert(object.isWeakReferenceHolderClass());
        const link = object.weakReferenceHolderLink() orelse unreachable;
        std.debug.assert(!link.registered);
        std.debug.assert(link.previous == null);
        std.debug.assert(link.next == null);

        link.previous = self.weak_reference_holder_tail;
        if (self.weak_reference_holder_tail) |tail| {
            const tail_link = tail.weakReferenceHolderLink() orelse unreachable;
            std.debug.assert(tail_link.registered);
            tail_link.next = object;
        } else {
            self.weak_reference_holder_head = object;
        }
        self.weak_reference_holder_tail = object;
        link.registered = true;
    }

    pub fn unregisterWeakReferenceHolder(self: *JSRuntime, object: *Object) void {
        if (!object.isWeakReferenceHolderClass()) return;
        const link = object.weakReferenceHolderLink() orelse return;
        if (!link.registered) return;

        if (link.previous) |previous| {
            const previous_link = previous.weakReferenceHolderLink() orelse unreachable;
            std.debug.assert(previous_link.registered);
            previous_link.next = link.next;
        } else {
            std.debug.assert(self.weak_reference_holder_head == object);
            self.weak_reference_holder_head = link.next;
        }
        if (link.next) |next| {
            const next_link = next.weakReferenceHolderLink() orelse unreachable;
            std.debug.assert(next_link.registered);
            next_link.previous = link.previous;
        } else {
            std.debug.assert(self.weak_reference_holder_tail == object);
            self.weak_reference_holder_tail = link.previous;
        }
        link.previous = null;
        link.next = null;
        link.registered = false;
    }

    pub fn registerBorrowedReferenceHolder(self: *JSRuntime, object: *Object) !void {
        if (object.flags.is_borrowed_reference_holder) return;
        const index = self.borrowed_reference_holders.len;
        try appendRuntimeObject(&self.memory, &self.borrowed_reference_holders, &self.borrowed_reference_holders_capacity, object);
        object.setBorrowedReferenceHolderIndex(index);
        object.flags.is_borrowed_reference_holder = true;
        // This table is lifetime bookkeeping only. A borrowed realm/weak
        // pointer does not add exotic [[Get]]/[[Set]] semantics, so it must not
        // poison the object's ordinary shape fast paths. Semantic slow-path
        // eligibility is established by the class/exotic flags at creation.
    }

    pub fn borrowedReferenceHolderRegistered(self: *const JSRuntime, object: *Object) bool {
        _ = self;
        return object.flags.is_borrowed_reference_holder;
    }

    pub fn unregisterBorrowedReferenceHolder(self: *JSRuntime, object: *Object) void {
        if (!object.flags.is_borrowed_reference_holder) return;
        if (object.borrowedReferenceHolderIndex()) |cached_index| {
            if (cached_index < self.borrowed_reference_holders.len and self.borrowed_reference_holders[cached_index] == object) {
                self.removeBorrowedReferenceHolderAt(cached_index);
                return;
            }
        }
        var found: ?usize = null;
        for (self.borrowed_reference_holders, 0..) |candidate, index| {
            if (candidate == object) {
                found = index;
                break;
            }
        }
        const index = found orelse return;
        self.removeBorrowedReferenceHolderAt(index);
    }

    fn removeBorrowedReferenceHolderAt(self: *JSRuntime, index: usize) void {
        std.debug.assert(index < self.borrowed_reference_holders.len);
        const removed = self.borrowed_reference_holders[index];
        const last_index = self.borrowed_reference_holders.len - 1;
        if (index != last_index) {
            const moved = self.borrowed_reference_holders[last_index];
            self.borrowed_reference_holders[index] = moved;
            moved.setBorrowedReferenceHolderIndex(index);
        }
        self.borrowed_reference_holders = self.borrowed_reference_holders[0..last_index];
        removed.setBorrowedReferenceHolderIndex(null);
        removed.flags.is_borrowed_reference_holder = false;
    }

    pub fn linkContext(self: *JSRuntime, ctx: *context_mod.JSContext) void {
        self.assertOwnerThread();
        std.debug.assert(ctx.runtime == self);
        std.debug.assert(ctx.runtime_prev == null and ctx.runtime_next == null);
        ctx.runtime_prev = self.context_tail;
        if (self.context_tail) |tail| {
            tail.runtime_next = ctx;
        } else {
            self.context_head = ctx;
        }
        self.context_tail = ctx;
    }

    pub fn linkConstructingContext(self: *JSRuntime, ctx: *context_mod.JSContext) void {
        self.assertOwnerThread();
        std.debug.assert(ctx.runtime == self);
        std.debug.assert(ctx.construction_prev == null and ctx.construction_next == null);
        ctx.construction_prev = self.constructing_context_tail;
        if (self.constructing_context_tail) |tail| {
            tail.construction_next = ctx;
        } else {
            self.constructing_context_head = ctx;
        }
        self.constructing_context_tail = ctx;
    }

    pub fn unlinkConstructingContext(self: *JSRuntime, ctx: *context_mod.JSContext) void {
        self.assertOwnerThread();
        if (ctx.construction_prev == null and ctx.construction_next == null and self.constructing_context_head != ctx) return;
        if (ctx.construction_prev) |prev| {
            prev.construction_next = ctx.construction_next;
        } else {
            std.debug.assert(self.constructing_context_head == ctx);
            self.constructing_context_head = ctx.construction_next;
        }
        if (ctx.construction_next) |next| {
            next.construction_prev = ctx.construction_prev;
        } else {
            std.debug.assert(self.constructing_context_tail == ctx);
            self.constructing_context_tail = ctx.construction_prev;
        }
        ctx.construction_prev = null;
        ctx.construction_next = null;
    }

    pub fn unlinkContext(self: *JSRuntime, ctx: *context_mod.JSContext) void {
        self.assertOwnerThread();
        if (ctx.runtime_prev == null and ctx.runtime_next == null and self.context_head != ctx) return;
        if (ctx.runtime_prev) |prev| {
            prev.runtime_next = ctx.runtime_next;
        } else {
            std.debug.assert(self.context_head == ctx);
            self.context_head = ctx.runtime_next;
        }
        if (ctx.runtime_next) |next| {
            next.runtime_prev = ctx.runtime_prev;
        } else {
            std.debug.assert(self.context_tail == ctx);
            self.context_tail = ctx.runtime_prev;
        }
        ctx.runtime_prev = null;
        ctx.runtime_next = null;
    }

    pub fn firstContext(self: *const JSRuntime) ?*context_mod.JSContext {
        return self.context_head;
    }

    /// Runtime destruction invalidates every remaining JS object, so finalize
    /// true C_FUNCTION realm owners before the last cycle passes. This mirrors
    /// QuickJS's runtime-final GC driving `js_c_function_finalizer`, which calls
    /// `JS_FreeContext` (quickjs.c:2405-2424, 6222-6227). Retaining one context
    /// at a time keeps its object graph stable until that context's scan ends;
    /// releasing the guard then runs the ordinary JSContext resource ordering.
    fn releaseNativeFunctionRealmsForTeardown(self: *JSRuntime) void {
        var live_owner = if (self.context_head) |head| context_mod.RealmRef.retain(head) else context_mod.RealmRef{};
        defer live_owner.deinit();
        while (live_owner.borrow()) |ctx| {
            var next_owner = if (ctx.runtime_next) |next| context_mod.RealmRef.retain(next) else context_mod.RealmRef{};
            self.releaseNativeFunctionRealmsForContext(ctx);
            live_owner.deinit();
            live_owner = next_owner;
            next_owner = .{};
        }

        var constructing_owner = if (self.constructing_context_head) |head| context_mod.RealmRef.retain(head) else context_mod.RealmRef{};
        defer constructing_owner.deinit();
        while (constructing_owner.borrow()) |ctx| {
            var next_owner = if (ctx.construction_next) |next| context_mod.RealmRef.retain(next) else context_mod.RealmRef{};
            self.releaseNativeFunctionRealmsForContext(ctx);
            constructing_owner.deinit();
            constructing_owner = next_owner;
            next_owner = .{};
        }
    }

    fn releaseNativeFunctionRealmsForContext(self: *JSRuntime, ctx: *context_mod.JSContext) void {
        var iter = self.gc.objectIterator();
        while (iter.next()) |header| {
            if (header.metaConst().flags.kind != .object) continue;
            const candidate: *Object = @alignCast(@fieldParentPtr("header", header));
            candidate.releaseNativeFunctionRealmForRuntimeTeardown(ctx);
        }
    }

    pub fn contextForGlobal(self: *const JSRuntime, global: *const Object) ?*context_mod.JSContext {
        var current = self.context_head;
        while (current) |ctx| : (current = ctx.runtime_next) {
            if (ctx.global == global) return ctx;
        }
        return null;
    }

    /// Bootstrap-only resolver. Public/runtime enumeration intentionally uses
    /// `contextForGlobal`, whose list contains published realms exclusively.
    pub fn contextForGlobalIncludingConstructing(self: *const JSRuntime, global: *const Object) ?*context_mod.JSContext {
        if (self.contextForGlobal(global)) |ctx| return ctx;
        var current = self.constructing_context_head;
        while (current) |ctx| : (current = ctx.construction_next) {
            if (ctx.global == global) return ctx;
        }
        return null;
    }

    /// QuickJS `add_property` invalidation for a tagged-integer mutation of
    /// the immutable intrinsic %Object.prototype%. Find only the owning
    /// realm(s) and clear their exact %Array.prototype% marker; unrelated
    /// realms in the same Runtime remain eligible for dense extension.
    pub fn invalidateStandardArrayPrototypeForObjectPrototype(self: *JSRuntime, object_prototype: *Object) void {
        self.assertOwnerThread();
        var live = self.context_head;
        while (live) |ctx| : (live = ctx.runtime_next) {
            invalidateContextStandardArrayPrototype(ctx, object_prototype);
        }
        var constructing = self.constructing_context_head;
        while (constructing) |ctx| : (constructing = ctx.construction_next) {
            invalidateContextStandardArrayPrototype(ctx, object_prototype);
        }
    }

    fn invalidateContextStandardArrayPrototype(ctx: *context_mod.JSContext, object_prototype: *Object) void {
        const object_value = ctx.cached_values[@intFromEnum(object_mod.RealmValueSlot.object_prototype)] orelse return;
        // Standard-realm bootstrap fills these two cache slots only from the
        // corresponding constructor prototype objects, so a present value has
        // already discharged Object.expect's type check.
        const realm_object_prototype = Object.expect(object_value) catch unreachable;
        if (realm_object_prototype != object_prototype) return;
        const array_value = ctx.cached_values[@intFromEnum(object_mod.RealmValueSlot.array_prototype)] orelse return;
        const array_prototype = Object.expect(array_value) catch unreachable;
        array_prototype.flags.is_std_array_prototype = false;
    }

    pub fn initialArrayShapeForPrototype(self: *const JSRuntime, prototype: ?*const Object) ?*shape.Shape {
        var current = self.context_head;
        while (current) |ctx| : (current = ctx.runtime_next) {
            const initial = ctx.array_shape orelse continue;
            if (initial.proto == prototype) return initial;
        }
        var constructing = self.constructing_context_head;
        while (constructing) |ctx| : (constructing = ctx.construction_next) {
            const initial = ctx.array_shape orelse continue;
            if (initial.proto == prototype) return initial;
        }
        return null;
    }

    /// Reserve a prototype slot in every live realm before a class id is
    /// published to callers.  This closes the old "registered after context
    /// creation" hole without making the runtime list an ownership edge.
    pub fn ensureContextClassPrototypeCapacity(self: *JSRuntime, class_id: class.ClassId) !void {
        try self.requireOwnerThread();
        var current_owner = if (self.context_head) |head| context_mod.RealmRef.retain(head) else context_mod.RealmRef{};
        defer current_owner.deinit();
        while (current_owner.borrow()) |ctx| {
            var next_owner = if (ctx.runtime_next) |next| context_mod.RealmRef.retain(next) else context_mod.RealmRef{};
            errdefer next_owner.deinit();
            _ = try ctx.ensureClassPrototypeSlot(class_id);
            current_owner.deinit();
            current_owner = next_owner;
            next_owner = .{};
        }

        var constructing_owner = if (self.constructing_context_head) |head| context_mod.RealmRef.retain(head) else context_mod.RealmRef{};
        defer constructing_owner.deinit();
        while (constructing_owner.borrow()) |ctx| {
            var next_owner = if (ctx.construction_next) |next| context_mod.RealmRef.retain(next) else context_mod.RealmRef{};
            errdefer next_owner.deinit();
            _ = try ctx.ensureClassPrototypeSlot(class_id);
            constructing_owner.deinit();
            constructing_owner = next_owner;
            next_owner = .{};
        }
    }

    const ClassPrototypeContextList = enum {
        live,
        constructing,
    };

    fn nextRetainableClassPrototypeContext(
        self: *JSRuntime,
        start: ?*context_mod.JSContext,
        comptime list: ClassPrototypeContextList,
    ) context_mod.RealmRef {
        var cursor = start;
        while (cursor) |ctx| {
            // Condemned Realm structs and their links stay allocated until the
            // cycle collector's resource pass. Snapshot the borrowed link
            // before deciding whether this node can still be retained. A
            // condemned Realm already has trial rc zero; its own resource pass
            // clears its class slots, so traversal must neither retain nor
            // recursively clear it here.
            const next = switch (list) {
                .live => ctx.runtime_next,
                .constructing => ctx.construction_next,
            };
            if (!gc.phaseIsTwoPassTeardown(self.gc.phase) or
                !ctx.header.metaConst().flags.cycle_visited)
            {
                return context_mod.RealmRef.retain(ctx);
            }
            cursor = next;
        }
        return .{};
    }

    /// Drop a dynamically unregistered class prototype from every live realm
    /// before its runtime definition (and possibly its plugin DSO) disappears.
    pub fn clearContextClassPrototype(self: *JSRuntime, class_id: class.ClassId) void {
        self.assertOwnerThread();
        var current_owner = self.nextRetainableClassPrototypeContext(self.context_head, .live);
        defer current_owner.deinit();
        while (current_owner.borrow()) |ctx| {
            var next_owner = self.nextRetainableClassPrototypeContext(ctx.runtime_next, .live);
            ctx.clearClassPrototype(class_id);
            current_owner.deinit();
            current_owner = next_owner;
            next_owner = .{};
        }

        var constructing_owner = self.nextRetainableClassPrototypeContext(self.constructing_context_head, .constructing);
        defer constructing_owner.deinit();
        while (constructing_owner.borrow()) |ctx| {
            var next_owner = self.nextRetainableClassPrototypeContext(ctx.construction_next, .constructing);
            ctx.clearClassPrototype(class_id);
            constructing_owner.deinit();
            constructing_owner = next_owner;
            next_owner = .{};
        }
    }

    pub fn registerRootProvider(self: *JSRuntime, provider: RootProvider) !void {
        self.assertOwnerThread();
        for (self.root_providers) |registered| {
            if (registered.context == provider.context and registered.trace == provider.trace) return;
        }
        try self.appendRootProvider(provider);
    }

    pub fn registerRootProviderChecked(self: *JSRuntime, provider: RootProvider) !void {
        try self.requireOwnerThread();
        return self.registerRootProvider(provider);
    }

    fn rootProvidersUsingInline(self: *const JSRuntime) bool {
        return self.root_providers.ptr == self.root_providers_inline[0..].ptr;
    }

    fn appendRootProvider(self: *JSRuntime, provider: RootProvider) !void {
        if (self.root_providers.len == self.root_providers_capacity) {
            const next_capacity = if (self.root_providers_capacity == 0) root_provider_inline_capacity else self.root_providers_capacity * 2;
            const next = try self.memory.alloc(RootProvider, next_capacity);
            errdefer self.memory.free(RootProvider, next);
            @memcpy(next[0..self.root_providers.len], self.root_providers);
            const old_capacity = self.root_providers_capacity;
            const old_using_inline = self.rootProvidersUsingInline();
            const old = if (!old_using_inline and old_capacity != 0) self.root_providers.ptr[0..old_capacity] else self.root_providers[0..0];
            self.root_providers = next[0..self.root_providers.len];
            self.root_providers_capacity = next_capacity;
            if (old.len != 0) self.memory.free(RootProvider, old);
        }
        const len = self.root_providers.len;
        self.root_providers = self.root_providers.ptr[0 .. len + 1];
        self.root_providers[len] = provider;
    }

    pub fn unregisterRootProvider(self: *JSRuntime, provider: RootProvider) void {
        self.assertOwnerThread();
        var found: ?usize = null;
        for (self.root_providers, 0..) |registered, index| {
            if (registered.context == provider.context and registered.trace == provider.trace) {
                found = index;
                break;
            }
        }
        const index = found orelse return;
        if (index + 1 < self.root_providers.len) {
            std.mem.copyForwards(RootProvider, self.root_providers[index .. self.root_providers.len - 1], self.root_providers[index + 1 ..]);
        }
        self.root_providers = self.root_providers[0 .. self.root_providers.len - 1];
        if (self.root_providers.len == 0 and self.root_providers_capacity != 0) {
            if (self.rootProvidersUsingInline()) {
                self.root_providers = self.root_providers_inline[0..0];
                self.root_providers_capacity = self.root_providers_inline.len;
                return;
            }
            const old_providers = self.root_providers.ptr[0..self.root_providers_capacity];
            self.root_providers = self.root_providers_inline[0..0];
            self.root_providers_capacity = self.root_providers_inline.len;
            self.memory.free(RootProvider, old_providers);
        }
    }

    pub fn traceRoots(self: *JSRuntime, roots: ?*const ValueRootFrame, visitor: *RootVisitor) RootTraceError!void {
        try self.traceValueRootFrames(roots, visitor);
        try visitor.value(&self.current_exception);
        for (self.local_root_slots) |slot| {
            try visitor.value(&slot.value);
        }
        for (self.persistent_root_slots) |slot| {
            try visitor.value(&slot.value);
        }
        for (self.deferred_class_payload_roots) |object| {
            try object.traceClassPayloadRootEdges(self, visitor);
        }
        for (self.deferred_class_payload_finalizers) |*job| {
            try job.traceRoots(self, visitor);
        }
        if (self.active_deferred_class_payload_finalizer) |job| {
            try job.traceRoots(self, visitor);
        }
        for (self.deferred_weak_value_frees) |*item| {
            try visitor.value(&item.value);
        }
        try self.job_queue.traceRoots(visitor);
        for (self.weakref_kept_alive) |*kept| try visitor.value(kept);
        for (self.root_providers) |provider| {
            try provider.trace(provider.context, visitor);
        }
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
                if (comptime gc.block_heap_enabled) {
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
            }

            fn visitValue(context: *anyopaque, slot: *JSValue) RootTraceError!void {
                const audit: *@This() = @ptrCast(@alignCast(context));
                if (slot.cycleMarkHeader()) |header| audit.checkHeader(header);
            }

            fn visitObject(context: *anyopaque, slot: *?*Object) RootTraceError!void {
                const audit: *@This() = @ptrCast(@alignCast(context));
                if (slot.*) |object| audit.checkHeader(&object.header);
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
        for (self.deferred_class_payload_roots) |object| {
            object.traceClassPayloadRootEdges(self, &visitor) catch
                return error.DeferredPayloadRootNotLive;
        }
        for (self.deferred_class_payload_finalizers) |*job| {
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
                try visitor.optionalObject(root.object);
            }
            if (comptime value_root_frames_enabled) {
                for (current.headers) |root| {
                    try visitor.constHeader(root.header);
                }
            }
            for (current.values) |root| {
                try visitor.value(root.value);
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

    fn createPersistentRootSlot(self: *JSRuntime, value: JSValue) !*RootSlot {
        return self.createRootSlot(value, &self.persistent_root_slots, &self.persistent_root_slots_capacity);
    }

    fn createLocalRootSlot(self: *JSRuntime, value: JSValue) !*RootSlot {
        return self.createRootSlot(value, &self.local_root_slots, &self.local_root_slots_capacity);
    }

    fn createWeakRootSlot(
        self: *JSRuntime,
        identity: usize,
        callback: ?WeakPersistentCallback,
        callback_context: ?*anyopaque,
    ) !*WeakRootSlot {
        const saved_trigger_fn = self.memory.trigger_gc_fn;
        const saved_trigger_ctx = self.memory.trigger_gc_ctx;
        self.memory.trigger_gc_fn = null;
        self.memory.trigger_gc_ctx = null;
        defer {
            self.memory.trigger_gc_fn = saved_trigger_fn;
            self.memory.trigger_gc_ctx = saved_trigger_ctx;
        }

        const slot = try self.memory.create(WeakRootSlot);
        errdefer self.memory.destroy(WeakRootSlot, slot);
        slot.* = .{
            .identity = identity,
            .callback = callback,
            .callback_context = callback_context,
        };
        try appendRuntimeWeakRootSlot(&self.memory, &self.weak_root_slots, &self.weak_root_slots_capacity, slot);
        return slot;
    }

    fn createRootSlot(self: *JSRuntime, value: JSValue, slots: *[]*RootSlot, capacity: *usize) !*RootSlot {
        const saved_trigger_fn = self.memory.trigger_gc_fn;
        const saved_trigger_ctx = self.memory.trigger_gc_ctx;
        self.memory.trigger_gc_fn = null;
        self.memory.trigger_gc_ctx = null;
        defer {
            self.memory.trigger_gc_fn = saved_trigger_fn;
            self.memory.trigger_gc_ctx = saved_trigger_ctx;
        }

        const slot = try self.memory.create(RootSlot);
        errdefer self.memory.destroy(RootSlot, slot);
        slot.* = .{ .value = JSValue.undefinedValue() };
        try appendRuntimeRootSlot(&self.memory, slots, capacity, slot);
        slot.value = value;
        return slot;
    }

    fn destroyWeakRootSlot(self: *JSRuntime, slot: *WeakRootSlot) void {
        self.removeWeakRootSlot(slot);
        self.clearWeakRootSlot(slot, false);
        slot.* = .{};
        self.memory.destroy(WeakRootSlot, slot);
    }

    fn removeWeakRootSlot(self: *JSRuntime, slot: *WeakRootSlot) void {
        var found: ?usize = null;
        for (self.weak_root_slots, 0..) |registered, index| {
            if (registered == slot) {
                found = index;
                break;
            }
        }
        const index = found orelse unreachable;
        if (index + 1 < self.weak_root_slots.len) {
            std.mem.copyForwards(*WeakRootSlot, self.weak_root_slots[index .. self.weak_root_slots.len - 1], self.weak_root_slots[index + 1 ..]);
        }
        self.weak_root_slots = self.weak_root_slots[0 .. self.weak_root_slots.len - 1];
        if (self.weak_root_slots.len == 0 and self.weak_root_slots_capacity != 0) {
            const old_slots = self.weak_root_slots.ptr[0..self.weak_root_slots_capacity];
            self.weak_root_slots = &.{};
            self.weak_root_slots_capacity = 0;
            self.memory.free(*WeakRootSlot, old_slots);
        }
    }

    fn destroyPersistentRootSlot(self: *JSRuntime, slot: *RootSlot) void {
        const value = self.takePersistentRootSlot(slot);
        value.free(self);
    }

    fn takePersistentRootSlot(self: *JSRuntime, slot: *RootSlot) JSValue {
        self.removePersistentRootSlot(slot);
        const value = slot.value;
        slot.value = JSValue.undefinedValue();
        self.memory.destroy(RootSlot, slot);
        return value;
    }

    fn removePersistentRootSlot(self: *JSRuntime, slot: *RootSlot) void {
        var found: ?usize = null;
        for (self.persistent_root_slots, 0..) |registered, index| {
            if (registered == slot) {
                found = index;
                break;
            }
        }
        const index = found orelse unreachable;
        if (index + 1 < self.persistent_root_slots.len) {
            std.mem.copyForwards(*RootSlot, self.persistent_root_slots[index .. self.persistent_root_slots.len - 1], self.persistent_root_slots[index + 1 ..]);
        }
        self.persistent_root_slots = self.persistent_root_slots[0 .. self.persistent_root_slots.len - 1];
        if (self.persistent_root_slots.len == 0 and self.persistent_root_slots_capacity != 0) {
            const old_slots = self.persistent_root_slots.ptr[0..self.persistent_root_slots_capacity];
            self.persistent_root_slots = &.{};
            self.persistent_root_slots_capacity = 0;
            self.memory.free(*RootSlot, old_slots);
        }
    }

    /// Runtime teardown is not an owner for public handles. Clearing these
    /// arrays here would leave the caller's handle pointing into freed memory;
    /// every scope/persistent/weak owner must close its edge first.
    fn assertNoOutstandingValueHandles(self: *const JSRuntime) void {
        if (self.local_root_slots.len != 0 or
            self.persistent_root_slots.len != 0 or
            self.weak_root_slots.len != 0)
        {
            @panic("JSRuntime destroyed with outstanding value handles");
        }
    }

    /// Stack-local execution/root records are borrowed by Runtime. They must be
    /// gone before teardown in every optimization mode; silently continuing
    /// would leave their deferred cleanup pointing into a destroyed Runtime.
    fn assertIdleForTeardown(self: *const JSRuntime) void {
        const active_job_for_runtime = if (comptime active_job_roots_enabled) blk: {
            var current = active_job_root_head;
            while (current) |root| : (current = root.previous) {
                if (root.runtime == self) break :blk true;
            }
            break :blk false;
        } else false;
        if (self.hot.call_depth != 0 or
            self.hot.native_call_depth != 0 or
            self.hot.active_bytecode_stack_bytes != 0 or
            self.hot.current_backtrace_frame != null or
            self.active_native_call != null or
            self.active_invocation != null or
            self.active_value_roots != null or
            active_job_for_runtime or
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
        for (self.weak_root_slots) |slot| {
            const identity = slot.identity orelse continue;
            if (!live_context.isWeakIdentityAlive(identity)) {
                self.clearWeakRootSlot(slot, true);
            }
        }
    }

    pub fn clearWeakPersistentIdentity(self: *JSRuntime, identity: usize, notify: bool) void {
        for (self.weak_root_slots) |slot| {
            const slot_identity = slot.identity orelse continue;
            if (slot_identity == identity) self.clearWeakRootSlot(slot, notify);
        }
    }

    /// §9.2: a successful WeakRef.deref promotes the target into the current
    /// job's keep-alive set. No-op in default `rc`.
    pub fn keepAliveWeakRefTarget(self: *JSRuntime, value: JSValue) void {
        const len = self.weakref_kept_alive.len;
        if (len == self.weakref_kept_alive_capacity) {
            const next_capacity: usize = if (self.weakref_kept_alive_capacity == 0) 4 else self.weakref_kept_alive_capacity * 2;
            const next = self.memory.alloc(JSValue, next_capacity) catch return;
            @memcpy(next[0..len], self.weakref_kept_alive);
            const old_capacity = self.weakref_kept_alive_capacity;
            const old: []JSValue = if (old_capacity != 0) self.weakref_kept_alive.ptr[0..old_capacity] else self.weakref_kept_alive[0..0];
            self.weakref_kept_alive = next[0..len];
            self.weakref_kept_alive_capacity = next_capacity;
            if (old.len != 0) self.memory.free(JSValue, old);
        }
        self.weakref_kept_alive = self.weakref_kept_alive.ptr[0 .. len + 1];
        self.weakref_kept_alive[len] = value.dup();
    }

    /// Clear [[KeptAlive]] at job end, not at an arbitrary safepoint.
    pub fn clearWeakRefKeptAlive(self: *JSRuntime) void {
        const values = self.weakref_kept_alive;
        const capacity = self.weakref_kept_alive_capacity;
        self.weakref_kept_alive = &.{};
        self.weakref_kept_alive_capacity = 0;
        for (values) |stored| stored.free(self);
        if (capacity != 0) self.memory.free(JSValue, values.ptr[0..capacity]);
    }

    pub fn retainWeakIdentity(self: *JSRuntime, identity: usize) void {
        if ((identity & 1) == 0) {
            const object = self.objectFromWeakIdentity(identity) orelse return;
            object.retainWeakReference();
            return;
        }
        const atom_id = identity >> 1;
        if (atom_id > std.math.maxInt(atom.Atom)) return;
        self.atoms.retainSymbolWeakRef(@intCast(atom_id));
    }

    pub fn releaseWeakIdentity(self: *JSRuntime, identity: usize) void {
        if ((identity & 1) == 0) {
            const object = self.objectFromWeakIdentity(identity) orelse return;
            object.releaseWeakReference();
            // A husk is an object the collector already stripped of resources
            // but kept allocated because a WeakRef still names it; dropping the
            // The last WeakRef is what finally frees the struct. trace_stw has
            // an explicit husk bit; RC keeps its historical rc==0 + !mark
            // distinction between a finished husk and in-progress teardown.
            const husk_dead = gc.headerIsReclaimableWeakHusk(&object.header);
            if (object.weakReferenceCount() == 0 and husk_dead) {
                Object.destroyDeadWeakHusk(self, object);
            }
            return;
        }
        const atom_id = identity >> 1;
        if (atom_id > std.math.maxInt(atom.Atom)) return;
        self.atoms.releaseSymbolWeakRef(self, @intCast(atom_id));
    }

    pub fn clearWeakIdentitySlot(self: *JSRuntime, slot: *?usize) void {
        const identity = slot.* orelse return;
        slot.* = null;
        self.releaseWeakIdentity(identity);
    }

    fn weakIdentityIsCurrentlyLive(self: *JSRuntime, identity: usize) bool {
        if ((identity & 1) != 0) {
            const atom_id = identity >> 1;
            if (atom_id > std.math.maxInt(atom.Atom)) return false;
            return self.atoms.kind(@intCast(atom_id)) == .symbol;
        }
        return self.liveObjectFromWeakIdentity(identity) != null;
    }

    fn valueFromWeakIdentity(self: *JSRuntime, identity: usize) JSValue {
        if ((identity & 1) != 0) {
            const atom_id = identity >> 1;
            if (atom_id > std.math.maxInt(atom.Atom)) return JSValue.undefinedValue();
            const symbol_atom: atom.Atom = @intCast(atom_id);
            if (self.atoms.kind(symbol_atom) != .symbol) return JSValue.undefinedValue();
            return self.atoms.symbolValueIfLive(self, symbol_atom) catch JSValue.undefinedValue();
        }
        const object = self.liveObjectFromWeakIdentity(identity) orelse return JSValue.undefinedValue();
        return object.value().dup();
    }

    /// Resolves an even weak identity (`weak_id << 1`) to its registered
    /// object in O(1). Returns null for symbol identities, unregistered ids,
    /// and objects that are currently being destroyed.
    pub fn liveObjectFromWeakIdentity(self: *const JSRuntime, identity: usize) ?*Object {
        if ((identity & 1) != 0) return null;
        const object = self.objectFromWeakIdentity(identity) orelse return null;
        if (gc.headerRefCountIsZeroOrHusk(&object.header)) return null;
        return object;
    }

    fn objectFromWeakIdentity(self: *const JSRuntime, identity: usize) ?*Object {
        if ((identity & 1) != 0) return null;
        return self.weak_id_objects.get(identity >> 1);
    }

    /// Returns the encoded weak identity for `object`, allocating a fresh
    /// monotonically increasing weak id on first registration.
    pub fn registerWeakObjectIdentity(self: *JSRuntime, object: *Object) !usize {
        const address = @intFromPtr(&object.header) & ~@as(usize, 1);
        if (object.flags.has_weak_id) {
            const weak_id = self.weak_object_ids.get(address) orelse unreachable;
            return weak_id << 1;
        }
        const weak_id = self.next_weak_id;
        try self.weak_object_ids.put(self.memory.persistent_allocator, address, weak_id);
        self.weak_id_objects.put(self.memory.persistent_allocator, weak_id, object) catch |err| {
            _ = self.weak_object_ids.remove(address);
            return err;
        };
        self.next_weak_id += 1;
        object.flags.has_weak_id = true;
        return weak_id << 1;
    }

    /// Returns the encoded weak identity for `object` without registering one.
    pub fn peekWeakObjectIdentity(self: *const JSRuntime, object: *const Object) ?usize {
        if (!object.flags.has_weak_id) return null;
        const address = @intFromPtr(&object.header) & ~@as(usize, 1);
        const weak_id = self.weak_object_ids.get(address) orelse return null;
        return weak_id << 1;
    }

    /// Removes `object` from the weak identity registry, returning its encoded
    /// weak identity (if any) so destruction can propagate it to weak slots.
    pub fn takeWeakObjectIdentity(self: *JSRuntime, object: *Object) ?usize {
        if (!object.flags.has_weak_id) return null;
        object.flags.has_weak_id = false;
        const address = @intFromPtr(&object.header) & ~@as(usize, 1);
        const weak_id = self.weak_object_ids.get(address) orelse return null;
        _ = self.weak_object_ids.remove(address);
        _ = self.weak_id_objects.remove(weak_id);
        return weak_id << 1;
    }

    fn clearLocalRootSlotsFrom(self: *JSRuntime, start: usize) void {
        std.debug.assert(start <= self.local_root_slots.len);
        var index = self.local_root_slots.len;
        while (index > start) {
            index -= 1;
            const slot = self.local_root_slots[index];
            const value = slot.value;
            slot.value = JSValue.undefinedValue();
            value.free(self);
            self.memory.destroy(RootSlot, slot);
        }
        self.local_root_slots = self.local_root_slots[0..start];
        if (self.local_root_slots.len == 0 and self.local_root_slots_capacity != 0) {
            const old_slots = self.local_root_slots.ptr[0..self.local_root_slots_capacity];
            self.local_root_slots = &.{};
            self.local_root_slots_capacity = 0;
            self.memory.free(*RootSlot, old_slots);
        }
    }

    pub fn enterHandleScope(self: *JSRuntime) HandleScope {
        return HandleScope.enter(self);
    }

    pub fn localRootCountForTest(self: JSRuntime) usize {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.local_root_slots.len;
    }

    pub fn weakRootCountForTest(self: JSRuntime) usize {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.weak_root_slots.len;
    }

    pub fn persistentRootCountForTest(self: JSRuntime) usize {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.persistent_root_slots.len;
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
        return self.takeSymbolValue(atom_id);
    }

    pub fn globalSymbolValue(self: *JSRuntime, key: []const u8) !JSValue {
        const atom_id = try self.atoms.internRegisteredValueSymbol(key);
        return self.symbolValue(atom_id);
    }

    pub fn dupValue(self: *JSRuntime, value: JSValue) JSValue {
        _ = self;
        return value.dup();
    }

    pub fn freeValue(self: *JSRuntime, value: JSValue) void {
        value.free(self);
    }

    pub fn createValueHandle(self: *JSRuntime, value: JSValue) !JSValueHandle {
        return JSValueHandle.initDup(self, value);
    }

    pub fn takeValueHandle(self: *JSRuntime, value: JSValue) !JSValueHandle {
        return JSValueHandle.init(self, value);
    }

    pub fn createPersistentValue(self: *JSRuntime, value: JSValue) !JSValueHandle {
        return self.createValueHandle(value);
    }

    pub fn createWeakPersistentValue(
        self: *JSRuntime,
        value: JSValue,
        callback: ?WeakPersistentCallback,
        callback_context: ?*anyopaque,
    ) !WeakPersistentValue {
        return WeakPersistentValue.init(self, value, callback, callback_context);
    }

    pub fn registerExternalHostFunction(self: *JSRuntime, record: host_function.ExternalRecord) !u32 {
        // A finalizer-free record is a pure dispatch tuple: sharing its id is
        // unobservable and keeps repeated Realm/host installation idempotent.
        // Finalized records are ownership registrations, so each one keeps a
        // distinct id and cleanup obligation even when the tuple is identical.
        if (record.finalizer == null) {
            for (self.external_host_functions, 0..) |existing, index| {
                if (existing.finalizer == null and existing.ptr == record.ptr and existing.call == record.call) {
                    return @intCast(index + 1);
                }
            }
        }
        try appendRuntimeExternalHostFunction(&self.memory, &self.external_host_functions, &self.external_host_functions_capacity, record);
        return @intCast(self.external_host_functions.len);
    }

    pub fn externalHostFunction(self: *JSRuntime, id: u32) ?host_function.ExternalRecord {
        if (id == 0) return null;
        const index: usize = @intCast(id - 1);
        if (index >= self.external_host_functions.len) return null;
        return self.external_host_functions[index];
    }

    /// Internal-builtin record lookup: `domain_index` is the
    /// `NativeBuiltinDomain` enum value, `id` the domain-local method id.
    /// Returns null for the separate host domain, invalid/gap ids, and runtimes
    /// whose standard globals were never installed. Two bounds-checked loads;
    /// no hashing or string compares.
    pub fn internalBuiltinRecord(self: *const JSRuntime, domain_index: usize, id: u32) ?*const host_function.InternalRecord {
        if (domain_index >= self.internal_builtins.len) return null;
        return self.internal_builtins[domain_index].get(id);
    }

    pub fn replaceExternalHostFunction(self: *JSRuntime, id: u32, record: host_function.ExternalRecord) ?host_function.ExternalRecord {
        if (id == 0) return null;
        const index: usize = @intCast(id - 1);
        if (index >= self.external_host_functions.len) return null;
        const old = self.external_host_functions[index];
        self.external_host_functions[index] = record;
        return old;
    }

    pub fn clearExternalHostFunctions(self: *JSRuntime) void {
        const records = self.external_host_functions;
        const capacity = self.external_host_functions_capacity;
        self.external_host_functions = &.{};
        self.external_host_functions_capacity = 0;

        for (records) |record| {
            if (record.finalizer) |finalizer| {
                self.enqueueDeferredNativeCleanup(finalizer, record.ptr) catch {
                    finalizer(record.ptr);
                };
            }
        }
        if (capacity != 0) self.memory.free(host_function.ExternalRecord, records.ptr[0..capacity]);
    }

    pub fn runObjectCycleRemoval(self: *JSRuntime) usize {
        self.assertOwnerThread();
        return self.runObjectCycleRemovalWithValueRoots(null);
    }

    pub fn runObjectCycleRemovalWithValueRoots(self: *JSRuntime, roots: ?*const ValueRootFrame) usize {
        self.assertOwnerThread();
        // Host-explicit "collect everything" (including runtime teardown):
        // the caller's contract is a quiescent engine, and teardown
        // correctness requires ignoring stale test-stack slots so the final
        // sweep can actually reclaim host-released realms.
        const result = self.tryRunObjectCycleRemovalWithValueRoots(roots, .declared_only) catch return 0;
        return result.freed_objects;
    }

    pub fn tryRunObjectCycleRemoval(self: *JSRuntime) gc.CollectionError!gc.CollectionResult {
        return self.tryRunObjectCycleRemovalWithValueRoots(null, .declared_only);
    }

    pub fn tryRunObjectCycleRemovalWithValueRoots(
        self: *JSRuntime,
        roots: ?*const ValueRootFrame,
        scan: GCRootScan,
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
            if (self.gc.doomed_pending) {
                self.gc_running = true;
                @import("gc_trace_stw.zig").finishPendingDestruction(self);
                self.gc_running = false;
                _ = self.finishDoomedCompletion(0);
            }
            self.gc.abortIncrementalCycle();
        }
        // `gc_running` covers the major driver. The refcount/cycle phases also
        // invoke allocation and callback boundaries, and a previously queued
        // request must remain pending rather than nest a second collection.
        if (self.gc_running or self.gc.phase != .none) return .{};
        if (builtin.mode == .Debug) self.gc.verifyIntrusiveList() catch unreachable;
        if (builtin.mode == .Debug) self.gc.verifyHeapAccounting(self) catch unreachable;
        defer if (builtin.mode == .Debug) {
            self.gc.verifyIntrusiveList() catch unreachable;
            self.gc.verifyHeapAccounting(self) catch unreachable;
        };
        self.gc_running = true;
        defer self.gc_running = false;

        // The cycle's high-water is the account right now, at trigger time.
        self.memory.samplePeakAtCollection();
        const start_ns = profile.nowNanos();

        self.gc.beginMajorCycle(self.gc.activeMajorReason() orelse .manual);
        const freed = @import("gc_trace_stw.zig").collectCycles(self, roots, scan) catch |err| {
            const mapped: gc.CollectionError = switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.PayloadMarkFailed => error.PayloadMarkFailed,
            };
            self.gc.recordFailure(mapped);
            self.gc.abortMajorCycle();
            self.gc.requestGC(.collection_failed, .soon);
            return mapped;
        };
        self.gc.setMajorPhase(.sweep);

        const end_ns = profile.nowNanos();
        const elapsed = if (end_ns > start_ns) end_ns - start_ns else 0;
        // Charge the census to whoever asked for it, not to the pause. The
        // walks run inside this region and are enabled by the same
        // `--gc-stats` that prints the distribution, so leaving them in makes
        // the only pause instrument inflate its own subject by ~40%.
        const census = @import("gc_trace_stw.zig").last_census_ns;
        const result = gc.CollectionResult{
            .freed_objects = freed,
            .duration_ns = elapsed -| census,
        };
        self.gc.recordSuccess(result);
        self.gc.finishMajorCycle();
        self.resetGCThreshold();
        self.gc.noteFullCollectionSettled(
            self.memory.allocated_bytes,
            self.malloc_gc_threshold,
            if (comptime gc.sticky_major_enabled)
                !@import("gc_trace_stw.zig").last_report.skipped_sweep_incomplete_arenas
            else
                true,
        );
        // Full STW majors free the same block cells as incremental majors.
        // Service the same aged-decommit policy here; otherwise explicit GC,
        // urgent pressure collections, and small-heap floor collections can
        // age free blocks forever without ever scanning them.
        if (comptime gc.block_heap_enabled) _ = self.gc.block_heap.releaseFreeBlockPages(end_ns);
        return result;
    }

    pub fn pollGC(
        self: *JSRuntime,
        roots: ?*const ValueRootFrame,
        mode: GCPollMode,
    ) gc.CollectionError!gc.CollectionResult {
        self.assertOwnerThread();
        if (self.active_deferred_class_payload_finalizer != null) return .{};
        self.drainDeferredClassPayloadFinalizersAtSafeBoundary();
        // An incremental major cycle in progress claims every ordinary poll as
        // a marking increment (§8.6: "allocation debt causes bounded mutator
        // mark assist on slow paths/polls"). Urgent polls abort the cycle
        // instead and fall through to the full STW collector: urgency means
        // maximum reclaim now, and a finished-early cycle would honor its
        // floating garbage.
        // Sliced destruction first: a morgue can only exist after a cycle
        // finished, so the two branches are mutually exclusive, and the
        // reclaim in progress should complete before anything new begins.
        // Destruction is irreversible, so urgency FINISHES it (one pause)
        // where it merely aborts an open marking cycle.
        if (self.gc.doomed_pending and !self.gc_running and self.gc.phase == .none) {
            if (mode == .urgent) {
                self.gc_running = true;
                @import("gc_trace_stw.zig").finishPendingDestruction(self);
                self.gc_running = false;
                _ = self.finishDoomedCompletion(0);
            } else {
                return self.destroySlicePoll();
            }
        }
        if (self.gc.concurrent.markingActive() and !self.gc_running and self.gc.phase == .none) {
            if (mode == .urgent) {
                self.gc.abortIncrementalCycle();
            } else {
                return self.incrementalMarkPoll(roots, mode);
            }
        }
        // Is the whole-heap threshold already crossed? Asked BEFORE the minor
        // is offered, because a minor cannot answer this question: it does not
        // reach the old generation, which is where a heap over its threshold
        // has put its garbage. Offering the minor first let it free a handful
        // of young objects, report success, and return -- and the major check
        // below was never reached. Nothing then ever collected the old
        // generation: earley-boyer performed 13,642 minors and zero majors,
        // promoted 6.8M objects, and finished holding 435MB where refcounting
        // held 3MB, with every one of those minors paying 1.12ms to trace a
        // heap that large. See `docs/tracing-gc-design.md` §8.5.
        const over_threshold = self.memory.allocated_bytes > self.malloc_gc_threshold;
        // §8.5: an automatic poll prefers a minor. A minor only reaches the
        // young set, so allocation churn is reclaimed without a whole-heap
        // trace -- but only here. An explicit `runObjectCycleRemoval` means
        // "collect everything", and answering it with a minor would silently
        // change what that call promises.
        if (comptime gc.generation_enabled) {
            if (!over_threshold and mode.acceptsMinor() and !self.gc_running and self.gc.shouldTryMinor()) {
                self.gc_running = true;
                defer self.gc_running = false;
                self.memory.samplePeakAtCollection();
                const started = profile.nowNanos();
                if (@import("gc_trace_stw.zig").collectMinor(self, roots, mode.rootScan()) catch null) |freed| {
                    self.gc.stats.collections += 1;
                    const ended = profile.nowNanos();
                    const elapsed = if (ended > started) ended - started else 0;
                    // Tracked separately from the major distribution: a minor
                    // is judged on being short, and averaging it with
                    // whole-heap pauses hides exactly that.
                    //
                    // Counted whether or not it reclaimed anything. A minor
                    // that frees nothing is the EXPENSIVE case, not a
                    // non-event: it walked its roots and every remembered
                    // owner and came back empty. Pricing those at zero made
                    // the panel report `minor pause mean 0 ns, max 0 ns` for a
                    // run that performed 320 of them, which is precisely the
                    // shape anyone optimising the minor needs to see.
                    self.gc.generation.recordMinorPause(
                        gc.Registry.markQueueAllocator(),
                        elapsed,
                        @import("gc_trace_stw.zig").detailed_reports,
                    );
                    if (freed > 0) {
                        const result: gc.CollectionResult = .{
                            .freed_objects = freed,
                            .duration_ns = elapsed,
                        };
                        // NOT `recordSuccess`: that would push a minor's
                        // duration into the major pause ring and count it as a
                        // whole-heap cycle. The minor's own pause accounting is
                        // the `generation.stats` update just above.
                        self.gc.recordMinorSuccess(result);
                        // Deliberately NOT `resetGCThreshold()`. That sets the
                        // major threshold to 1.5x the CURRENT footprint and
                        // clears the allocation debt, and a minor has no claim
                        // to either: it did not look at the old generation, so
                        // the footprint it is measuring is mostly old garbage
                        // it cannot see. Resetting here raised the bar by half
                        // on every minor, so the more garbage accumulated the
                        // further the major receded -- the threshold outran the
                        // heap it was meant to bound. Both belong to the major.
                        return result;
                    }
                }
            }
        }
        if (self.gc_running or self.gc.phase != .none) return .{};
        const scheduler_point: gc.SchedulerPoint = switch (mode) {
            .normal => .allocation_slow_path,
            .callback_boundary => .callback_boundary,
            .idle => .idle,
            .safepoint => .safepoint,
            .urgent => .urgent,
        };
        switch (scheduler_point) {
            .allocation_slow_path, .idle, .urgent => self.requestGCForProcessMemoryPressure(),
            .callback_boundary, .safepoint => {},
        }
        const over_full_pressure = self.gc.stickyMajorFullPressureExceeded();
        const over_collection_threshold = over_threshold or over_full_pressure;
        const run_major = self.gc.shouldRunMajorAt(scheduler_point, over_collection_threshold);
        if (!run_major) return .{};

        const major_request = self.gc.pendingMajorRequest();
        if (major_request != null) _ = self.gc.clearMajorRequest();
        const reason = if (major_request) |request|
            request.reason orelse gc.RequestReason.manual
        else if (over_collection_threshold)
            gc.RequestReason.allocation_threshold
        else
            gc.RequestReason.manual;
        // A pure threshold crossing opens an incremental cycle and returns;
        // the collection's result arrives at the poll whose increment empties
        // the frontier. Everything with a REQUEST behind it -- host manual,
        // memory pressure, collection-failed retries, any urgency -- keeps the
        // STW collector and its complete-at-this-poll semantics: a request is
        // a promise to someone, and "begun" is not "kept". The threshold has
        // no requester; it is the collector pacing itself, which is exactly
        // the case incrementality exists for.
        // "Pure threshold" includes the request form: an over-threshold
        // allocation boundary records `.allocation_threshold`/`.soon`
        // before any poll can see the crossing, and that request is still
        // the collector pacing itself, not a promise to a host. Manual,
        // pressure, failure-retry, and anything urgent keep STW.
        const self_paced = major_request == null or
            ((major_request.?.reason orelse .manual) == .allocation_threshold and
                major_request.?.urgency != .urgent);
        if (mode != .urgent and self_paced) {
            self.gc_running = true;
            self.gc.beginCycleEnvelope(self.malloc_gc_threshold);
            const began = profile.nowNanos();
            @import("gc_trace_stw.zig").beginIncrementalCycle(self, null, mode.rootScan()) catch |err| {
                self.gc_running = false;
                self.gc.abortIncrementalCycle();
                const mapped: gc.CollectionError = switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.PayloadMarkFailed => error.PayloadMarkFailed,
                };
                self.gc.recordFailure(mapped);
                self.gc.requestGC(.collection_failed, .soon);
                return mapped;
            };
            self.gc_running = false;
            const ended = profile.nowNanos();
            self.gc.recordMajorSlicePause(if (ended > began) ended - began else 0, .begin);
            return .{};
        }
        self.gc.beginMajorCycle(reason);
        return try self.tryRunObjectCycleRemovalWithValueRoots(null, mode.rootScan());
    }

    /// One bounded marking increment, and the final remark when the frontier
    /// runs dry. The safety valve: once the account outgrows the threshold by
    /// half again, the cycle finishes in this poll regardless of budget --
    /// one large pause, counted, instead of an unbounded heap.
    fn incrementalMarkPoll(
        self: *JSRuntime,
        roots: ?*const ValueRootFrame,
        mode: GCPollMode,
    ) gc.CollectionError!gc.CollectionResult {
        const stw = @import("gc_trace_stw.zig");
        self.gc_running = true;
        defer self.gc_running = false;

        const forced = self.memory.allocated_bytes >
            std.math.add(usize, self.malloc_gc_threshold, self.malloc_gc_threshold >> 1) catch std.math.maxInt(usize);
        const began = profile.nowNanos();
        var frontier_empty = stw.incrementalMarkStep(self, gc.incremental_mark_budget_ns) catch |err| {
            self.gc.abortIncrementalCycle();
            const mapped: gc.CollectionError = switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.PayloadMarkFailed => error.PayloadMarkFailed,
            };
            self.gc.recordFailure(mapped);
            self.gc.requestGC(.collection_failed, .soon);
            return mapped;
        };
        if (forced and !frontier_empty) {
            self.gc.concurrent.stats.forced_finishes += 1;
            while (!frontier_empty) {
                frontier_empty = stw.incrementalMarkStep(self, std.math.maxInt(u64)) catch |err| {
                    self.gc.abortIncrementalCycle();
                    const mapped: gc.CollectionError = switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        error.PayloadMarkFailed => error.PayloadMarkFailed,
                    };
                    self.gc.recordFailure(mapped);
                    self.gc.requestGC(.collection_failed, .soon);
                    return mapped;
                };
            }
        }
        // Marking time is marking time whether or not this slice happened to
        // empty the frontier. Attributing the emptying slice's marking to
        // `.finish` made earley-boyer read as 64 ms of marking against 1.44 s
        // of finish, when in fact most of that finish WAS marking -- and a
        // decision about concurrent marking turns on exactly that split.
        const marked_until = profile.nowNanos();
        if (!frontier_empty) {
            self.gc.recordMajorSlicePause(marked_until -| began, .increment);
            return .{};
        }

        // The final poll is one PAUSE with two attributable phase segments:
        // marking followed by finish. Keep it one sample in the pause ring,
        // but give both phases time/count/max ownership below.
        const mark_ns = marked_until -| began;
        const increment_index = @intFromEnum(gc.Registry.SliceKind.increment);
        self.gc.concurrent.stats.total_stw_by_kind[increment_index] +|= mark_ns;
        self.gc.concurrent.stats.total_segments_by_kind[increment_index] +|= 1;
        self.gc.concurrent.stats.segment_max_ns[increment_index] =
            @max(self.gc.concurrent.stats.segment_max_ns[increment_index], mark_ns);

        // Frontier empty: final remark and weak processing, then CONDEMN --
        // destruction runs in bounded slices at later polls, because the
        // phase probe put it at 99.5% of this slice's cost. The cycle's
        // result and the threshold reset land at the destruction-completion
        // poll; the account has not shrunk yet, so resetting here would price
        // the next cycle off a heap full of corpses.
        self.memory.samplePeakAtCollection();
        _ = stw.finishIncrementalCycle(self, roots, mode.rootScan()) catch |err| {
            self.gc.abortIncrementalCycle();
            const mapped: gc.CollectionError = switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.PayloadMarkFailed => error.PayloadMarkFailed,
            };
            self.gc.recordFailure(mapped);
            self.gc.requestGC(.collection_failed, .soon);
            return mapped;
        };
        if (forced) {
            // The safety valve wanted memory back, not a promise: destroy now.
            stw.finishPendingDestruction(self);
        }
        const ended = profile.nowNanos();
        const slice = if (ended > began) ended - began else 0;
        // The slice's own pause sample is the whole stop, which is what the
        // pause gate measures; the cumulative-by-kind account splits the
        // marking out of it (added above) so the two questions -- "how long
        // is one stop" and "which phase owns the stopped time" -- get
        // different, correct answers.
        const finish_index = @intFromEnum(gc.Registry.SliceKind.finish);
        const prior_finish_max = self.gc.concurrent.stats.segment_max_ns[finish_index];
        self.gc.recordMajorSlicePause(slice, .finish);
        self.gc.concurrent.stats.total_stw_by_kind[finish_index] -|= mark_ns;
        // `recordMajorSlicePause` sees the whole pause so the pause ring and
        // per-cycle STW stay honest. Its generic max update therefore also
        // sees the whole pause; restore the prior maximum and compare it with
        // only the finish-owned tail, just as the cumulative row does above.
        self.gc.concurrent.stats.segment_max_ns[finish_index] =
            @max(prior_finish_max, slice -| mark_ns);
        if (!self.gc.doomed_pending) return self.finishDoomedCompletion(slice);
        // Reset the threshold NOW, pricing the morgue's bytes as already
        // reclaimed. Waiting for the destruction slices left the account
        // over-threshold for the whole window, and worse, the eventual reset
        // included every byte the window allocated: the 1.75x factor
        // amplified that into a compounding loop that peaked an 841 MB heap
        // over a ~50 MB live set. The completion poll refines this from the
        // truly-shrunk account.
        self.resetGCThresholdExcludingDoomed();
        return .{};
    }

    fn resetGCThresholdExcludingDoomed(self: *JSRuntime) void {
        const settled = self.memory.allocated_bytes -| self.gc.doomed_bytes;
        const saved = self.memory.allocated_bytes;
        // Reuse the one rule rather than duplicating it: present the account
        // net of corpses, compute, restore. Single-threaded, no observer.
        self.memory.allocated_bytes = settled;
        self.resetGCThreshold();
        self.memory.allocated_bytes = saved;
    }

    /// One bounded destruction slice; the cycle's result lands at the poll
    /// whose slice empties the morgue.
    fn destroySlicePoll(self: *JSRuntime) gc.CollectionError!gc.CollectionResult {
        const stw = @import("gc_trace_stw.zig");
        self.gc_running = true;
        defer self.gc_running = false;
        const began = profile.nowNanos();
        _ = stw.destroyDoomedSlice(self, gc.incremental_mark_budget_ns);
        const ended = profile.nowNanos();
        const slice = if (ended > began) ended - began else 0;
        self.gc.recordMajorSlicePause(slice, .destroy);
        if (!self.gc.doomed_pending) return self.finishDoomedCompletion(slice);
        return .{};
    }

    /// The morgue is empty: deliver the cycle's CollectionResult and reset the
    /// growth threshold from the account the destruction actually shrank.
    fn finishDoomedCompletion(self: *JSRuntime, last_slice_ns: u64) gc.CollectionResult {
        std.debug.assert(!self.gc.doomed_pending);
        @import("gc_trace_stw.zig").auditDoomedExitInvariant(self);
        const result: gc.CollectionResult = .{
            .freed_objects = self.gc.doomed_destroyed,
            .duration_ns = last_slice_ns,
        };
        self.gc.doomed_destroyed = 0;
        self.gc.recordIncrementalCycleSuccess(result);
        self.resetGCThreshold();
        self.gc.noteIncrementalCollectionSettled(
            self.memory.allocated_bytes,
            self.malloc_gc_threshold,
            if (comptime gc.sticky_major_enabled)
                !@import("gc_trace_stw.zig").last_report.skipped_sweep_incomplete_arenas
            else
                true,
        );
        if (comptime gc.block_heap_enabled) _ = self.gc.block_heap.releaseFreeBlockPages(profile.nowNanos());
        return result;
    }

    /// Host-facing checked form of `pollGC`. Internal engine paths use the
    /// asserting form so the mutation-contract error does not widen ordinary
    /// JavaScript execution error sets.
    pub fn pollGCChecked(
        self: *JSRuntime,
        roots: ?*const ValueRootFrame,
        mode: GCPollMode,
    ) RuntimeCollectionError!gc.CollectionResult {
        try self.requireOwnerThread();
        return self.pollGC(roots, mode);
    }

    pub fn gcSafepoint(self: *JSRuntime, roots: ?*const ValueRootFrame) gc.CollectionError!gc.CollectionResult {
        return self.pollGC(roots, .safepoint);
    }

    pub fn afterCallbackBoundaryGC(self: *JSRuntime, roots: ?*const ValueRootFrame) gc.CollectionError!gc.CollectionResult {
        const result = try self.pollGC(roots, .callback_boundary);
        _ = self.runDeferredNativeCleanupBudgeted(self.gc.policy.native_cleanup_slice_jobs);
        _ = self.runDeferredClassPayloadFinalizerBudgeted(self.gc.policy.native_cleanup_slice_jobs);
        return result;
    }

    pub fn beforeEventLoopIdleGC(self: *JSRuntime, roots: ?*const ValueRootFrame) gc.CollectionError!gc.CollectionResult {
        const result = try self.pollGC(roots, .idle);
        _ = self.runDeferredNativeCleanupBudgeted(self.gc.policy.native_cleanup_slice_jobs);
        _ = self.runDeferredClassPayloadFinalizerBudgeted(self.gc.policy.native_cleanup_slice_jobs);
        return result;
    }

    pub fn forceGC(self: *JSRuntime, roots: ?*const ValueRootFrame) gc.CollectionError!gc.CollectionResult {
        self.assertOwnerThread();
        self.gc.requestGC(.manual, .urgent);
        return self.pollGC(roots, .urgent);
    }

    pub fn forceMajorGC(self: *JSRuntime, roots: ?*const ValueRootFrame) gc.CollectionError!gc.CollectionResult {
        return self.forceGC(roots);
    }

    pub fn requestGCForTest(self: *JSRuntime) void {
        if (!builtin.is_test) @compileError("test-only helper");
        self.assertOwnerThread();
        self.gc.requestGC(.manual, .soon);
    }

    /// Declare that this test keeps every collectable reference either in a
    /// linked ValueRootFrame or scrubbed (dropGcPtr), so even engine-trigger
    /// collection entries may scan precisely. See `test_root_scan_override`.
    pub fn forcePreciseRootScanForTest(self: *JSRuntime) void {
        if (!builtin.is_test) @compileError("test-only helper");
        self.test_root_scan_override = .declared_only;
    }

    pub fn gcPendingForTest(self: JSRuntime) bool {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.gc.hasPendingRequest();
    }

    pub fn gcLastRequestReasonForTest(self: JSRuntime) ?gc.RequestReason {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.gc.stats.last_request_reason;
    }

    pub fn setGCThreshold(self: *JSRuntime, threshold: usize) void {
        self.gc.invalidateCycleEnvelopeBaseline();
        self.malloc_gc_threshold = threshold;
    }

    pub fn gcThreshold(self: JSRuntime) usize {
        return self.malloc_gc_threshold;
    }

    pub fn setMemoryLimit(self: *JSRuntime, limit: ?usize) void {
        self.memory.setLimit(limit);
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
        self.memory.limit_gc_fn = if (suppressed) null else JSRuntime.collectBeforeLimitRejection;
    }

    pub fn memoryLimit(self: JSRuntime) ?usize {
        return self.memory.getLimit();
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

        const object_count = self.gc.liveCountKind(.object);
        const shape_count = self.gc.liveCountKind(.shape);
        // Count heap nodes, not Realm registry membership: an externally
        // retained record remains live and reportable after its Realm unlinks.
        const module_count = self.gc.liveCountKind(.module);
        const class_record_count = self.classes.records.len;
        return .{
            .memory_limit = self.memoryLimit(),
            .allocated_bytes = self.memory.allocated_bytes,
            .allocation_count = self.memory.allocation_count,
            .peak_allocated_bytes = self.memory.peak_allocated_bytes,
            .peak_allocation_count = self.memory.peak_allocation_count,
            .alloc_calls = self.memory.alloc_calls,
            .free_calls = self.memory.free_calls,
            .create_calls = self.memory.create_calls,
            .destroy_calls = self.memory.destroy_calls,
            .atom_count = atom.predefined_count + live_dynamic_atoms,
            .atom_bytes = dynamic_atom_bytes,
            .object_count = object_count,
            .object_bytes = object_count * @sizeOf(Object),
            .shape_count = shape_count,
            .shape_bytes = shape_count * @sizeOf(shape.Shape),
            .module_count = module_count,
            .module_bytes = module_count * @sizeOf(module.ModuleRecord),
            .registered_class_count = registered_classes,
            .class_record_count = class_record_count,
            .class_bytes = class_record_count * @sizeOf(class.Record),
        };
    }

    pub fn reportExternalAlloc(self: *JSRuntime, bytes: usize) !gc.ExternalMemoryToken {
        const token = try self.gc.reportExternalAlloc(bytes);
        if (self.gc.externalMemoryRequestReason()) |reason| {
            self.gc.requestGC(reason, self.gc.externalMemoryRequestUrgency());
        }
        self.requestGCForProcessMemoryPressure();
        return token;
    }

    /// Internal classification for inline buffer bytes that already live in
    /// MemoryAccount. Off-account embedders must use `reportExternalAlloc` and
    /// retain its token; this raw hook does not perform the pressure check.
    pub fn reportExternalAllocUntracked(self: *JSRuntime, bytes: usize) void {
        self.gc.reportExternalAllocUntracked(bytes);
    }

    /// Legacy raw live-ledger decrement. Releasing a tracked allocation must
    /// use the `ExternalMemoryToken` returned by `reportExternalAlloc`.
    pub fn reportExternalFree(self: *JSRuntime, bytes: usize) void {
        self.gc.reportExternalFree(bytes);
    }

    pub fn reportExternalFreeUntracked(self: *JSRuntime, bytes: usize) void {
        self.gc.reportExternalFreeUntracked(bytes);
    }

    pub fn externalMemoryBytes(self: JSRuntime) usize {
        return self.gc.stats.external_bytes;
    }

    pub fn allocationDebtBytes(self: JSRuntime) usize {
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

    pub fn gcStats(self: *const JSRuntime) gc.Stats {
        var stats = self.gc.statsSnapshot(self);
        stats.weak_ref_count = self.weakReferenceCount();
        const finalization_jobs = self.job_queue.countKind(.finalization);
        stats.finalizer_queue_length = finalization_jobs;
        stats.pending_finalization_job_count = finalization_jobs;
        stats.deferred_native_cleanup_count = self.deferred_native_cleanups.len;
        stats.deferred_native_cleanup_run_count = self.deferred_native_cleanup_run_count;
        stats.deferred_class_payload_finalizer_count = self.deferred_class_payload_finalizers.len;
        stats.deferred_class_payload_finalizer_run_count = self.deferred_class_payload_finalizer_run_count;
        stats.rss_bytes = currentRssBytes();
        stats.cgroup_limit_bytes = cgroupLimitBytes();
        return stats;
    }

    pub fn ownsObject(self: *const JSRuntime, object: *const Object) bool {
        return self.gc.containsHeader(&object.header);
    }

    /// Sampling process memory costs three `openat` plus a `read` and a `close`
    /// per call -- `/proc/self/statm`, then the cgroup v2 and v1 limit files,
    /// the latter two normally returning ENOENT. Under a policy that sets none
    /// of the four fields `processMemoryRequest` reads, every gate in it is
    /// disabled and it can only return null, so the whole snapshot is
    /// discarded. Skip it in that case.
    ///
    /// The gate is expanded at the call site and the sampling body kept out of
    /// line, so a runtime with no pressure policy does not even pay a call
    /// boundary to discover it has nothing to do. Nothing else moves: the
    /// external-byte accounting, the allocation debt and the internal
    /// threshold triggers in `reportExternalAlloc` all run first and unchanged,
    /// and any policy that does consume the snapshot reaches the identical
    /// slow path.
    inline fn requestGCForProcessMemoryPressure(self: *JSRuntime) void {
        if (!self.gc.policy.needsProcessMemorySnapshot()) return;
        self.requestGCForProcessMemoryPressureSlow();
    }

    noinline fn requestGCForProcessMemoryPressureSlow(self: *JSRuntime) void {
        const rss_bytes = currentRssBytes();
        const cgroup_limit_bytes = cgroupLimitBytes();
        if (self.gc.processMemoryRequest(rss_bytes, cgroup_limit_bytes)) |request| {
            self.gc.requestGC(request.reason, request.urgency);
        }
    }

    fn weakReferenceCount(self: *const JSRuntime) usize {
        var count: usize = 0;
        for (self.weak_root_slots) |slot| {
            if (slot.identity != null) count += 1;
        }
        var gc_iter = self.gc.objectIterator();
        while (gc_iter.next()) |header| {
            if (header.meta().flags.kind == .object) {
                const obj: *Object = @alignCast(@fieldParentPtr("header", header));
                count +|= obj.weakCollectionEntries().len;
                count +|= obj.finalizationRegistryCells().len;
            }
        }
        return count;
    }

    fn currentRssBytes() usize {
        if (builtin.os.tag != .linux) return 0;
        var buf: [128]u8 = undefined;
        const contents = readLinuxFile("/proc/self/statm", &buf) orelse return 0;
        var tokens = std.mem.tokenizeAny(u8, contents, " \t\r\n");
        _ = tokens.next() orelse return 0;
        const resident_pages = parseUnsignedToken(tokens.next() orelse return 0) orelse return 0;
        return std.math.mul(usize, resident_pages, std.heap.pageSize()) catch std.math.maxInt(usize);
    }

    fn cgroupLimitBytes() usize {
        if (builtin.os.tag != .linux) return 0;
        var buf: [128]u8 = undefined;
        if (readLinuxFile("/sys/fs/cgroup/memory.max", &buf)) |contents| {
            if (parseUnsignedToken(firstToken(contents))) |limit| return limit;
        }
        if (readLinuxFile("/sys/fs/cgroup/memory/memory.limit_in_bytes", &buf)) |contents| {
            if (parseUnsignedToken(firstToken(contents))) |limit| return limit;
        }
        return 0;
    }

    fn readLinuxFile(path: []const u8, buf: []u8) ?[]const u8 {
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
        defer _ = std.os.linux.close(fd);
        const len = std.posix.read(fd, buf) catch return null;
        return buf[0..len];
    }

    fn firstToken(contents: []const u8) []const u8 {
        var tokens = std.mem.tokenizeAny(u8, contents, " \t\r\n");
        return tokens.next() orelse "";
    }

    fn parseUnsignedToken(token: []const u8) ?usize {
        if (token.len == 0 or std.mem.eql(u8, token, "max")) return null;
        return std.fmt.parseInt(usize, token, 10) catch null;
    }

    fn maybeRunObjectCycleRemoval(self: *JSRuntime) void {
        if (self.gc_running) return;
        if (self.memory.allocated_bytes <= self.malloc_gc_threshold) return;
        _ = self.runObjectCycleRemoval();
    }

    pub inline fn requestGCForAllocation(self: *JSRuntime, size: usize) void {
        if (comptime builtin.is_test) {
            if (self.memory.trigger_gc_fn) |trigger| {
                if (trigger != JSRuntime.triggerGCOnAllocation) {
                    trigger(self.memory.trigger_gc_ctx, size);
                    return;
                }
            }
        }
        // Allocation is legal from class/native finalizers while the refcount
        // queue is in its decref phase, but starting a nested major collection
        // is not. `gc_running` covers the major driver; the explicit phase guard
        // also covers outer zero-ref drains that run without that flag.
        if (self.gc_running or self.gc.phase != .none) return;
        if (comptime memory.force_gc_on_allocation_enabled) {
            if (self.memory.trigger_gc_fn == null) return;
            // The force-GC build option is diagnostic instrumentation, not a
            // scheduling-policy change. Preserve an explicitly configured
            // threshold across the synthetic pre-allocation collection.
            const saved_threshold = self.malloc_gc_threshold;
            defer self.malloc_gc_threshold = saved_threshold;
            _ = self.forceGC(null) catch {};
            return;
        }
        // qjs js_trigger_gc (quickjs.c:1780-1788):
        //   force_gc = (malloc_size + size) > malloc_gc_threshold
        // malloc_size is allocated_bytes (usable+MALLOC_OVERHEAD, quickjs.c:2168).
        const total = std.math.add(usize, self.memory.allocated_bytes, size) catch std.math.maxInt(usize);
        if (total > self.malloc_gc_threshold) {
            self.gc.requestGC(.allocation_threshold, .soon);
        }
    }

    /// QuickJS `JS_NewObjectFromShape` runs its threshold GC before entering
    /// the allocator. Object construction uses this stronger boundary instead
    /// of merely leaving a pending request for post-registration service: a
    /// memory-limit check must be allowed to reuse space from reclaimable
    /// cycles before rejecting the replacement object.
    pub fn collectBeforeObjectAllocation(self: *JSRuntime, size: usize) void {
        // Plugin callbacks are forbidden inside tracer_destroy. The first
        // object-allocation boundary after the collector becomes idle drains
        // them before publishing another object. Allocations made by a callback
        // reenter this function with `draining_...` set: they may request the
        // next GC, but cannot recursively drain the same queue.
        self.drainDeferredClassPayloadFinalizersAtSafeBoundary();
        self.requestGCForAllocation(size);
        // Scratch allocation can cross the threshold and queue a request, then
        // fall back below it before the next qjs-style object boundary. The
        // threshold condition is level-triggered: discard only that ordinary
        // stale request. Registry request coalescing preserves manual/external/
        // pressure reasons so they cannot be cancelled here.
        const prospective = std.math.add(usize, self.memory.allocated_bytes, size) catch std.math.maxInt(usize);
        if (prospective <= self.malloc_gc_threshold) {
            _ = self.gc.clearStaleAllocationThresholdRequest();
        }
        // §8.6: allocation debt buys a bounded slice of the marker's work.
        // Bounded is the whole point -- an unbounded assist turns one
        // allocation into an arbitrary pause, which is what a concurrent
        // collector exists to prevent.
        if (self.gc_running or self.gc.phase != .none) return;
        // While marking is open the account is over the (not yet reset)
        // threshold, so each boundary re-records `.allocation_threshold` above
        // and this gate stays open for the increments unaided. Destruction is
        // different: the threshold resets at condemn time (net of corpses), so
        // the account may be UNDER it while the morgue still holds memory --
        // the explicit `doomed_pending` term is what keeps the slices moving.
        if (!self.gc.doomed_pending and !self.gc.hasPendingMajorRequest()) return;
        _ = self.pollGC(null, .normal) catch {};
    }

    fn triggerGCOnAllocation(ctx: ?*anyopaque, size: usize) void {
        const self: *JSRuntime = @ptrCast(@alignCast(ctx));
        self.requestGCForAllocation(size);
    }

    /// Last chance before an allocation is rejected for crossing the memory
    /// limit. The mutator's native frames are live here -- this runs from the
    /// middle of an arbitrary allocation -- so the scan must be the
    /// conservative one; `declared_only` would sweep objects the caller is
    /// still holding in Zig locals. Reentrancy is already handled:
    /// `tryRunObjectCycleRemovalWithValueRoots` returns immediately if a
    /// collection is in flight, so a collection that allocates cannot recurse.
    fn collectBeforeLimitRejection(ctx: *anyopaque) void {
        const self: *JSRuntime = @ptrCast(@alignCast(ctx));
        _ = self.tryRunObjectCycleRemovalWithValueRoots(null, .engine_active) catch return;
    }

    fn resetGCThreshold(self: *JSRuntime) void {
        // Refcounting keeps qjs's rule verbatim (js_trigger_gc after JS_RunGC,
        // quickjs.c:1795-1796): threshold = malloc_size + (malloc_size >> 1).
        //
        // The tracer gets 2x, and the divergence is deliberate: qjs's 1.5x
        // governs a CYCLE collector running over a heap where refcounting has
        // already freed every acyclic object, so each round handles residue.
        // A tracer must trace the whole live set to free anything at all --
        // the cost of a collection is proportional to what survives, not to
        // what dies -- so the same constant buys far less allocation per
        // whole-heap trace. Copying it across that semantic change was
        // faithfulness to the wrong collector: splay completed in 16 rounds
        // under rc and paid ~41 whole-heap majors under the tracer at 1.5x.
        // JSC's precedent for a full-tracing heap is a growth factor of 2 on
        // small heaps (smallHeapGrowthFactor, OptionsList.h:219; "small" is
        // heap < 25% of RAM). The factor here was 1.75 while §1.3 capped
        // cycle peak/live at 1.8; the owner renegotiated that cap to 2.0 on
        // 2026-08-29 (ABBA n=16 pricing: splay cycles -7.25%, six-benchmark
        // geomean 0.9867, peak RSS +10-13%; docs/slab-reuse-2026-08-29.md).
        // Steady-state cycle peak/live equals this factor by construction,
        // so the constant and the §1.3 cap must move together.
        const grown = grown_blk: {
            const live_now = self.memory.allocated_bytes;
            if (gc.growth_percent_override != 0) {
                // The parser refuses anything below 100. Without that floor
                // the subtraction wraps and `grown` lands *under* the live
                // set, which the `@max` with `floored` would hide -- the
                // threshold would look sane while the growth rule had
                // silently stopped existing.
                std.debug.assert(gc.growth_percent_override >= 100);
                const extra = live_now / 100 * (gc.growth_percent_override - 100);
                break :grown_blk std.math.add(usize, live_now, extra) catch std.math.maxInt(usize);
            }
            break :grown_blk std.math.add(usize, live_now, live_now) catch std.math.maxInt(usize);
        };
        // ...plus room for one nursery. Half of a small live set is less than
        // a nursery, and since the threshold is tested before a minor is
        // offered, such a threshold would be crossed first every time and
        // every collection would be a major. raytrace lives in 288KB, so the
        // qjs rule alone gives it 144KB of headroom to fill a nursery that
        // wants an order of magnitude more.
        const headroom = if (gc.headroom_override != 0) gc.headroom_override else gc.small_heap_major_headroom_bytes;
        const floored = std.math.add(usize, self.memory.allocated_bytes, headroom) catch std.math.maxInt(usize);
        self.malloc_gc_threshold = @max(grown, floored);
        // Both rules add to the live set, so the threshold can never sit below
        // it. Stated here because the growth arm is now arithmetic on a
        // runtime-supplied percentage: a threshold under `allocated_bytes`
        // would make the very next allocation trigger a collection, which
        // reads as a pathologically slow build rather than as a broken rule.
        std.debug.assert(self.malloc_gc_threshold >= self.memory.allocated_bytes);
        // Which rule set the cadence. Without this the claim "raytrace's
        // majors are paced by the floor, not by growth" stays an inference
        // from arithmetic; with it, it is a reading.
        if (floored > grown) {
            self.gc.stats.threshold_floor_hits +|= 1;
        } else {
            self.gc.stats.threshold_growth_hits +|= 1;
        }
        // Diagnostic only; zero in every shipped configuration.
        self.malloc_gc_threshold = @max(self.malloc_gc_threshold, gc.min_major_threshold);
        // A pending morgue uses a provisional threshold net of doomed bytes;
        // no new cycle may begin before destruction completes, and the final
        // reset below will publish the actual settled pair.
        if (!self.gc.doomed_pending) {
            self.gc.noteCycleEnvelopeBaseline(self.memory.allocated_bytes, self.malloc_gc_threshold);
        }
        self.gc.resetAllocationDebt();
    }

    /// Return a cached single-byte (latin1) string for an ASCII byte
    /// (0..127), creating it lazily on the first request. The returned
    /// pointer is borrowed; callers that need to participate in normal
    /// ref-counting should call `gc.retain(&result.header)` themselves.
    /// Returns `null` for non-ASCII bytes (the caller must allocate).
    pub fn singleByteString(self: *JSRuntime, byte: u8) !?*string.String {
        if (byte > 0x7f) return null;
        if (self.single_byte_strings[byte]) |cached| return cached;
        const created = try string.String.createAscii(self, &.{byte});
        self.single_byte_strings[byte] = created;
        return created;
    }

    pub fn cachedSingleByteString(self: *JSRuntime, byte: u8) ?*string.String {
        if (byte > 0x7f) return null;
        return self.single_byte_strings[byte];
    }

    pub fn emptyString(self: *JSRuntime) !*string.String {
        if (self.empty_string) |cached| return cached;
        const created = try string.String.createAscii(self, "");
        self.empty_string = created;
        return created;
    }

    /// Return a borrowed cached string for a two-code-unit sequence. Callers
    /// that return the value must `dup` it, matching `singleByteString`.
    pub fn recentTwoUnitString(self: *JSRuntime, first: u16, second: u16) !*string.String {
        if (self.recent_two_unit_string) |cached| {
            if (cached.first == first and cached.second == second) return cached.string;
        }

        const created = try string.String.createUtf16Pair(self, first, second);
        const old = self.recent_two_unit_string;
        self.recent_two_unit_string = .{
            .first = first,
            .second = second,
            .string = created,
        };
        if (old) |stored| JSValue.string(stored.string.header()).free(self);
        return created;
    }

    /// Return a borrowed cached string for a recently materialized atom.
    /// Callers that return the value must `dup` it.
    pub fn recentAtomString(self: *JSRuntime, atom_id: atom.Atom, bytes: []const u8) !*string.String {
        for (self.recent_atom_strings) |slot| {
            if (slot) |cached| {
                if (cached.atom_id == atom_id) return cached.string;
            }
        }

        const created = try string.String.createUtf8(self, bytes);
        // Seeds the weak back-pointer (and, for non-tagged string atoms,
        // the table-side cache); no-op for symbol atoms.
        self.atoms.cacheString(atom_id, created);
        const slot_index: usize = self.compact_state.recent_atom_string_next;
        const old = self.recent_atom_strings[slot_index];
        self.recent_atom_strings[slot_index] = .{
            .atom_id = atom_id,
            .string = created,
        };
        self.compact_state.recent_atom_string_next = @intCast((slot_index + 1) % self.recent_atom_strings.len);
        if (old) |stored| JSValue.string(stored.string.header()).free(self);
        return created;
    }

    /// Return a borrowed cached uppercase `%XX` string for a byte. Callers
    /// that return the value must `dup` it.
    pub fn smallIntString(self: *JSRuntime, value: u8) !*string.String {
        if (self.small_int_strings[value]) |s| return s;
        var buf: [4]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        const s = try string.String.createLatin1(self, text);
        // The cache owns the string's initial reference and releases it in
        // JSRuntime.destroy; callers receive a borrowed pointer.
        self.small_int_strings[value] = s;
        return s;
    }

    pub fn percentHexString(self: *JSRuntime, value: u8) !*string.String {
        if (self.percent_hex_strings[value]) |cached| return cached;
        const bytes: [3]u8 = .{
            '%',
            unicode.asciiUpperHexDigitChar(value >> 4),
            unicode.asciiUpperHexDigitChar(value & 0x0f),
        };
        const created = try string.String.createAscii(self, &bytes);
        self.percent_hex_strings[value] = created;
        return created;
    }

    pub fn setStackSize(self: *JSRuntime, size: usize) void {
        self.hot.stack_size = size;
        self.vm_stack_arena_policy = VmStackWindowPolicy.arenaForLimit(size);
    }

    pub fn stackSize(self: JSRuntime) usize {
        return self.hot.stack_size;
    }

    pub fn setNativeStackSize(self: *JSRuntime, size: usize) void {
        self.hot.native_stack_size = size;
        self.updateNativeStackTop();
    }

    /// Capture the current native frame pointer as the recursion base and derive
    /// the lower limit. Mirrors QuickJS `JS_UpdateStackTop` + `update_stack_limit`
    /// (quickjs.c:2841-2860). Must be called at the outermost JS entry on the
    /// thread that will run the code (worker threads have their own C stack), so
    /// deeper native frames (parser / JSON / interpreter) measure against a real,
    /// same-stack base. A `native_stack_size` of 0 disables the limit.
    pub fn updateNativeStackTop(self: *JSRuntime) void {
        self.hot.native_stack_top = @frameAddress();
        self.hot.native_stack_limit = if (self.hot.native_stack_size == 0)
            0
        else
            self.hot.native_stack_top -| self.hot.native_stack_size;
    }

    /// Return true if consuming `alloca_size` more native stack would cross the
    /// recursion limit. Direct port of QuickJS `js_check_stack_overflow`
    /// (quickjs.c:2059-2064): `sp = frame_address - alloca_size; sp < limit`.
    /// Stack grows down, so "below the limit" is overflow.
    ///
    /// The unset limit needs no branch of its own: qjs encodes "no limit" as
    /// `rt->stack_limit = 0` (`update_stack_limit`, quickjs.c:2841-2846) and
    /// lets the same unsigned compare answer it, because no stack pointer is
    /// ever below zero. `native_stack_limit` uses that identical encoding, and
    /// the saturating subtraction keeps `sp` non-negative, so `sp < 0` is
    /// already constant-false. An explicit `limit == 0` pre-test is a zjs-only
    /// extra load-compare-branch on the parser's per-token guard path
    /// (parser.zig `advance`, mirroring qjs guarding `next_token`,
    /// quickjs.c:22836) and LLVM does not fold it away.
    pub inline fn checkNativeStackOverflow(self: *const JSRuntime, alloca_size: usize) bool {
        const sp = @frameAddress() -| alloca_size;
        return sp < self.hot.native_stack_limit;
    }

    pub fn internAtom(self: *JSRuntime, bytes: []const u8) !atom.Atom {
        return self.atoms.internString(bytes);
    }

    pub fn newClassId(self: *JSRuntime, requested: class.ClassId) (error{ClassIdExhausted} || RuntimeMutationError)!class.ClassId {
        try self.requireOwnerThread();
        if (requested != class.invalid_class_id) return requested;
        return class.allocateDynamicClassId();
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

    /// Reserve count for a global object's own-property table prior to running
    /// the standard-globals installer. Returns the count registered with the
    /// installer (0 if none is wired, in which case `installStandardGlobals`
    /// will fail).
    pub fn standardGlobalOwnPropertyCapacity(self: *const JSRuntime) usize {
        return self.standard_global_own_property_capacity;
    }

    /// Bootstrap the standard ECMAScript global object onto `global` via the
    /// registered installer. Fails with `error.InvalidBuiltinRegistry` if the
    /// exec bootstrap never registered one (the installer also wires
    /// `internal_builtins` and `materialize_builtin_namespace_cb`).
    ///
    /// The installer callback is typed `anyerror` so core need not name the
    /// exec's error set, but the install only ever produces engine errors;
    /// narrow the result back to the engine runtime-error set so bounded-error
    /// bootstrap callers keep a concrete operation-specific surface.
    pub fn installStandardGlobals(self: *JSRuntime, global: *Object) errors.RuntimeError!void {
        const installer = self.install_standard_globals_cb orelse return error.InvalidBuiltinRegistry;
        var adopted_context: ?*context_mod.JSContext = null;
        if (self.contextForGlobalIncludingConstructing(global) == null) {
            var candidate = self.context_head;
            while (candidate) |ctx| : (candidate = ctx.runtime_next) {
                if (ctx.global != null) continue;
                global.class_id = class.ids.global_object;
                gc.retain(&global.header);
                ctx.global = global;
                _ = global.ensureGlobalPayload(self) catch |err| {
                    ctx.rollbackIntrinsicBootstrap();
                    ctx.global = null;
                    global.value().free(self);
                    return @errorCast(err);
                };
                adopted_context = ctx;
                break;
            }
            if (adopted_context == null) return error.InvalidBuiltinRegistry;
        }
        installer(self, global) catch |err| {
            if (adopted_context) |ctx| {
                ctx.rollbackIntrinsicBootstrap();
                ctx.global = null;
                global.value().free(self);
            }
            return @errorCast(err);
        };
    }

    pub fn hasInterruptHandler(self: JSRuntime) bool {
        return self.interrupt_handler != null;
    }

    pub fn runInterruptHandler(self: *JSRuntime) bool {
        const handler = self.interrupt_handler orelse return false;
        return handler(self, self.interrupt_context);
    }

    pub fn setCanBlock(self: *JSRuntime, can_block: bool) void {
        self.can_block = can_block;
    }

    pub fn canBlock(self: JSRuntime) bool {
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

    pub fn pendingFinalizationJobCountForTest(self: JSRuntime) usize {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.job_queue.countKind(.finalization);
    }

    pub fn enqueueDeferredNativeCleanup(self: *JSRuntime, finalizer: host_function.ExternalFinalizer, ptr: *anyopaque) !void {
        const index = self.deferred_native_cleanups.len;
        try self.ensureDeferredNativeCleanupCapacity(index + 1);
        self.deferred_native_cleanups = self.deferred_native_cleanups.ptr[0 .. index + 1];
        self.deferred_native_cleanups[index] = .{
            .finalizer = finalizer,
            .ptr = ptr,
        };
    }

    pub fn enqueueDeferredClassPayloadFinalizer(self: *JSRuntime, class_id: class.ClassId, payload: class.Payload, payload_kind: class.PayloadKind, object_identity: usize) !bool {
        const definition = self.classes.destructionPlan(class_id) orelse return false;
        const index = self.deferred_class_payload_finalizers.len;
        try self.ensureDeferredClassPayloadFinalizerCapacity(index + self.reserved_deferred_class_payload_finalizer_slots + 1);
        const callbacks = self.classes.pinDeferredPayloadCallbacks(class_id, definition.generation) orelse return false;
        self.deferred_class_payload_finalizers = self.deferred_class_payload_finalizers.ptr[0 .. index + 1];
        self.deferred_class_payload_finalizers[index] = .{
            .class_id = class_id,
            .generation = callbacks.generation,
            .finalizer = callbacks.finalizer,
            .mark = callbacks.mark,
            .payload = payload,
            .payload_kind = payload_kind,
            .object_identity = object_identity,
        };
        return true;
    }

    pub fn reserveDeferredClassPayloadFinalizerSlot(self: *JSRuntime) !void {
        try self.ensureDeferredClassPayloadFinalizerCapacity(self.deferred_class_payload_finalizers.len + self.reserved_deferred_class_payload_finalizer_slots + 1);
        errdefer self.releaseEmptyDeferredClassPayloadFinalizerBuffer();
        // The same reservation owns one entry in the pre-enqueue payload-root
        // registry. Reserve both allocations before publishing the wrapper's
        // payload so destruction can transfer ownership without failure.
        // `reserved_...` already counts every registered root plus any
        // construction whose payload has not been published yet.
        try self.ensureDeferredClassPayloadRootCapacity(self.reserved_deferred_class_payload_finalizer_slots + 1);
        self.reserved_deferred_class_payload_finalizer_slots +|= 1;
    }

    pub fn releaseDeferredClassPayloadFinalizerSlot(self: *JSRuntime) void {
        std.debug.assert(self.reserved_deferred_class_payload_finalizer_slots != 0);
        self.reserved_deferred_class_payload_finalizer_slots -= 1;
        self.releaseEmptyDeferredClassPayloadFinalizerBuffer();
        self.releaseEmptyDeferredClassPayloadRootBuffer();
    }

    /// Publish a wrapper's declared payload edges as roots after its payload
    /// is fully initialized. The reservation remains outstanding until the
    /// wrapper finalizer atomically transfers the payload to a queued job.
    pub fn registerReservedDeferredClassPayloadRoot(self: *JSRuntime, object: *Object) void {
        std.debug.assert(self.reserved_deferred_class_payload_finalizer_slots != 0);
        std.debug.assert(self.deferred_class_payload_roots.len < self.reserved_deferred_class_payload_finalizer_slots);
        std.debug.assert(self.deferred_class_payload_roots.len < self.deferred_class_payload_roots_capacity);
        const index = self.deferred_class_payload_roots.len;
        self.deferred_class_payload_roots = self.deferred_class_payload_roots.ptr[0 .. index + 1];
        self.deferred_class_payload_roots[index] = object;
    }

    /// End the pre-enqueue root lifetime after the queued node has copied the
    /// payload and mark callback. Queue roots take over before this removal.
    pub fn unregisterDeferredClassPayloadRoot(self: *JSRuntime, object: *Object) void {
        var found: ?usize = null;
        for (self.deferred_class_payload_roots, 0..) |registered, index| {
            if (registered == object) {
                found = index;
                break;
            }
        }
        const index = found orelse unreachable;
        const last = self.deferred_class_payload_roots.len - 1;
        if (index != last) self.deferred_class_payload_roots[index] = self.deferred_class_payload_roots[last];
        self.deferred_class_payload_roots = self.deferred_class_payload_roots.ptr[0..last];
        self.releaseEmptyDeferredClassPayloadRootBuffer();
    }

    pub fn enqueueReservedDeferredClassPayloadFinalizer(self: *JSRuntime, class_id: class.ClassId, generation: u64, payload: class.Payload, payload_kind: class.PayloadKind, object_identity: usize) bool {
        std.debug.assert(self.reserved_deferred_class_payload_finalizer_slots != 0);
        self.reserved_deferred_class_payload_finalizer_slots -= 1;

        const callbacks = self.classes.pinDeferredPayloadCallbacks(class_id, generation) orelse {
            self.releaseEmptyDeferredClassPayloadFinalizerBuffer();
            return false;
        };
        const index = self.deferred_class_payload_finalizers.len;
        std.debug.assert(index + 1 <= self.deferred_class_payload_finalizers_capacity);
        self.deferred_class_payload_finalizers = self.deferred_class_payload_finalizers.ptr[0 .. index + 1];
        self.deferred_class_payload_finalizers[index] = .{
            .class_id = class_id,
            .generation = callbacks.generation,
            .finalizer = callbacks.finalizer,
            .mark = callbacks.mark,
            .payload = payload,
            .payload_kind = payload_kind,
            .object_identity = object_identity,
        };
        return true;
    }

    pub fn hasDeferredNativeCleanups(self: *const JSRuntime) bool {
        return self.deferred_native_cleanups.len != 0 or self.deferred_class_payload_finalizers.len != 0;
    }

    pub fn hasPendingDeferredClassPayloadFinalizers(self: JSRuntime) bool {
        return self.deferred_class_payload_finalizers.len != 0 or
            self.active_deferred_class_payload_finalizer != null;
    }

    pub fn isActiveDeferredClassPayloadFinalizerCallback(self: *const JSRuntime, object_identity: *anyopaque) bool {
        const active = self.active_deferred_class_payload_finalizer orelse return false;
        return object_identity == @as(*anyopaque, @ptrCast(&active.object_identity));
    }

    pub fn runDeferredNativeCleanupBudgeted(self: *JSRuntime, max_jobs: usize) usize {
        if (max_jobs == 0) return 0;
        if (self.draining_deferred_native_cleanups) return 0;
        self.draining_deferred_native_cleanups = true;
        defer self.draining_deferred_native_cleanups = false;

        var ran: usize = 0;
        while (ran < max_jobs and self.deferred_native_cleanups.len != 0) : (ran += 1) {
            const job = self.deferred_native_cleanups[0];
            const old_len = self.deferred_native_cleanups.len;
            if (old_len > 1) {
                @memmove(self.deferred_native_cleanups[0 .. old_len - 1], self.deferred_native_cleanups[1..old_len]);
            }
            self.deferred_native_cleanups = self.deferred_native_cleanups.ptr[0 .. old_len - 1];
            job.run();
            self.deferred_native_cleanup_run_count +|= 1;
        }

        self.releaseEmptyDeferredNativeCleanupBuffer();
        return ran;
    }

    pub fn runDeferredClassPayloadFinalizerBudgeted(self: *JSRuntime, max_jobs: usize) usize {
        if (max_jobs == 0) return 0;
        if (self.draining_deferred_class_payload_finalizers) return 0;
        self.draining_deferred_class_payload_finalizers = true;
        defer self.draining_deferred_class_payload_finalizers = false;

        var ran: usize = 0;
        while (ran < max_jobs and self.deferred_class_payload_finalizers.len != 0) : (ran += 1) {
            var job = self.deferred_class_payload_finalizers[0];
            const old_len = self.deferred_class_payload_finalizers.len;
            if (old_len > 1) {
                @memmove(self.deferred_class_payload_finalizers[0 .. old_len - 1], self.deferred_class_payload_finalizers[1..old_len]);
            }
            self.deferred_class_payload_finalizers = self.deferred_class_payload_finalizers.ptr[0 .. old_len - 1];
            self.runDeferredClassPayloadFinalizerJob(&job);
            self.deferred_class_payload_finalizer_run_count +|= 1;
        }

        self.releaseEmptyDeferredClassPayloadFinalizerBuffer();
        // An incremental morgue may still have later resource destructors.
        // Draining its parked structs here would collapse Pass B into the
        // middle of Pass A. The next destruction slice owns closing that
        // transaction after the callback prerequisite has cleared.
        if (ran != 0 and self.deferred_class_payload_finalizers.len == 0 and
            !self.gc.doomed_pending)
        {
            object_mod.Object.drainCycleDeferredFrees(self);
        }
        return ran;
    }

    pub fn drainDeferredNativeCleanups(self: *JSRuntime) void {
        while (self.runDeferredNativeCleanupBudgeted(std.math.maxInt(usize)) != 0) {}
        self.releaseEmptyDeferredNativeCleanupBuffer();
    }

    pub fn drainDeferredClassPayloadFinalizers(self: *JSRuntime) void {
        while (self.runDeferredClassPayloadFinalizerBudgeted(std.math.maxInt(usize)) != 0) {}
        self.releaseEmptyDeferredClassPayloadFinalizerBuffer();
    }

    /// Deliver user callbacks only after the collector phase has returned to
    /// idle. Every entry capable of starting another collection calls this
    /// first, so a queued payload and its parked destruction morgue cannot be
    /// carried into a fresh mark cycle. Reentry from the callback is rejected
    /// by the active-job guard above while its GC request remains pending.
    inline fn drainDeferredClassPayloadFinalizersAtSafeBoundary(self: *JSRuntime) void {
        if (self.deferred_class_payload_finalizers.len == 0) return;
        if (self.gc_running or self.gc.phase != .none) return;
        if (self.draining_deferred_class_payload_finalizers) return;
        self.drainDeferredClassPayloadFinalizers();
    }

    fn runDeferredClassPayloadFinalizerJob(self: *JSRuntime, job: *DeferredClassPayloadFinalizer) void {
        std.debug.assert(self.active_deferred_class_payload_finalizer == null);
        self.active_deferred_class_payload_finalizer = job;
        defer self.active_deferred_class_payload_finalizer = null;
        job.run(self);
    }

    pub fn pendingDeferredNativeCleanupCountForTest(self: JSRuntime) usize {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.deferred_native_cleanups.len;
    }

    pub fn pendingDeferredClassPayloadFinalizerCountForTest(self: JSRuntime) usize {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.deferred_class_payload_finalizers.len;
    }

    fn ensureDeferredNativeCleanupCapacity(self: *JSRuntime, min_capacity: usize) !void {
        if (self.deferred_native_cleanups_capacity >= min_capacity) return;
        var next_capacity = if (self.deferred_native_cleanups_capacity == 0) @as(usize, 8) else self.deferred_native_cleanups_capacity * 2;
        while (next_capacity < min_capacity) : (next_capacity *= 2) {}
        const next = try self.memory.alloc(NativeCleanupJob, next_capacity);
        errdefer self.memory.free(NativeCleanupJob, next);
        const old_items = self.deferred_native_cleanups;
        const old_capacity = self.deferred_native_cleanups_capacity;
        @memcpy(next[0..old_items.len], old_items);
        self.deferred_native_cleanups = next[0..old_items.len];
        self.deferred_native_cleanups_capacity = next_capacity;
        if (old_capacity != 0) {
            self.memory.free(NativeCleanupJob, old_items.ptr[0..old_capacity]);
        }
    }

    fn releaseEmptyDeferredNativeCleanupBuffer(self: *JSRuntime) void {
        if (self.deferred_native_cleanups.len != 0) return;
        if (self.deferred_native_cleanups_capacity == 0) {
            self.deferred_native_cleanups = &.{};
            return;
        }
        const old_items = self.deferred_native_cleanups.ptr[0..self.deferred_native_cleanups_capacity];
        self.deferred_native_cleanups = &.{};
        self.deferred_native_cleanups_capacity = 0;
        self.memory.free(NativeCleanupJob, old_items);
    }

    fn ensureDeferredClassPayloadFinalizerCapacity(self: *JSRuntime, min_capacity: usize) !void {
        if (self.deferred_class_payload_finalizers_capacity >= min_capacity) return;
        var next_capacity = if (self.deferred_class_payload_finalizers_capacity == 0) @as(usize, 8) else self.deferred_class_payload_finalizers_capacity * 2;
        while (next_capacity < min_capacity) next_capacity *= 2;
        const next = try self.memory.alloc(DeferredClassPayloadFinalizer, next_capacity);
        errdefer self.memory.free(DeferredClassPayloadFinalizer, next);
        const old_items = self.deferred_class_payload_finalizers;
        const old_capacity = self.deferred_class_payload_finalizers_capacity;
        @memcpy(next[0..old_items.len], old_items);
        self.deferred_class_payload_finalizers = next[0..old_items.len];
        self.deferred_class_payload_finalizers_capacity = next_capacity;
        if (old_capacity != 0) {
            self.memory.free(DeferredClassPayloadFinalizer, old_items.ptr[0..old_capacity]);
        }
    }

    fn ensureDeferredClassPayloadRootCapacity(self: *JSRuntime, min_capacity: usize) !void {
        if (self.deferred_class_payload_roots_capacity >= min_capacity) return;
        var next_capacity = if (self.deferred_class_payload_roots_capacity == 0) @as(usize, 8) else self.deferred_class_payload_roots_capacity * 2;
        while (next_capacity < min_capacity) next_capacity *= 2;
        const next = try self.memory.alloc(*Object, next_capacity);
        errdefer self.memory.free(*Object, next);
        const old_items = self.deferred_class_payload_roots;
        const old_capacity = self.deferred_class_payload_roots_capacity;
        @memcpy(next[0..old_items.len], old_items);
        self.deferred_class_payload_roots = next[0..old_items.len];
        self.deferred_class_payload_roots_capacity = next_capacity;
        if (old_capacity != 0) self.memory.free(*Object, old_items.ptr[0..old_capacity]);
    }

    fn releaseEmptyDeferredClassPayloadFinalizerBuffer(self: *JSRuntime) void {
        if (self.deferred_class_payload_finalizers.len != 0) return;
        if (self.reserved_deferred_class_payload_finalizer_slots != 0) return;
        if (self.deferred_class_payload_finalizers_capacity == 0) {
            self.deferred_class_payload_finalizers = &.{};
            return;
        }
        const old_items = self.deferred_class_payload_finalizers.ptr[0..self.deferred_class_payload_finalizers_capacity];
        self.deferred_class_payload_finalizers = &.{};
        self.deferred_class_payload_finalizers_capacity = 0;
        self.memory.free(DeferredClassPayloadFinalizer, old_items);
    }

    fn releaseEmptyDeferredClassPayloadRootBuffer(self: *JSRuntime) void {
        if (self.deferred_class_payload_roots.len != 0) return;
        if (self.reserved_deferred_class_payload_finalizer_slots != 0) return;
        if (self.deferred_class_payload_roots_capacity == 0) {
            self.deferred_class_payload_roots = &.{};
            return;
        }
        const old_items = self.deferred_class_payload_roots.ptr[0..self.deferred_class_payload_roots_capacity];
        self.deferred_class_payload_roots = &.{};
        self.deferred_class_payload_roots_capacity = 0;
        self.memory.free(*Object, old_items);
    }

    pub fn enqueueDeferredWeakValueFree(self: *JSRuntime, value: JSValue) !void {
        try self.enqueueDeferredWeakValueFreeWithPreparedIdentity(value, null);
    }

    pub fn enqueueDeferredWeakValueFreeWithPreparedIdentity(self: *JSRuntime, value: JSValue, prepared_identity: ?usize) !void {
        const index = self.deferred_weak_value_frees.len;
        try self.ensureDeferredWeakValueFreeCapacity(index + 1);
        self.deferred_weak_value_frees = self.deferred_weak_value_frees.ptr[0 .. index + 1];
        self.deferred_weak_value_frees[index] = .{ .value = value, .prepared_identity = prepared_identity };
    }

    pub fn hasDeferredWeakValueFrees(self: *const JSRuntime) bool {
        return self.deferred_weak_value_frees.len != 0;
    }

    pub fn drainDeferredWeakValueFrees(self: *JSRuntime) void {
        if (self.draining_deferred_weak_value_frees) return;
        self.draining_deferred_weak_value_frees = true;
        defer self.draining_deferred_weak_value_frees = false;

        while (self.deferred_weak_value_frees.len != 0) {
            const old_len = self.deferred_weak_value_frees.len;
            const item = self.deferred_weak_value_frees[old_len - 1];
            self.deferred_weak_value_frees = self.deferred_weak_value_frees.ptr[0 .. old_len - 1];
            var skip_identity = item.prepared_identity;
            if (skip_identity == null) {
                skip_identity = self.prepareBorrowedWeakCleanupForLastRefValue(item.value);
            }
            const previous_skip_identity = self.current_deferred_weak_value_free_identity;
            self.current_deferred_weak_value_free_identity = skip_identity;
            defer self.current_deferred_weak_value_free_identity = previous_skip_identity;
            if (item.value.refCountHeader()) |header| {
                if (gc.headerRefCountIsZeroOrHusk(header)) {
                    const already_consumed_prepared_object =
                        header.meta().flags.kind == .object and
                        skip_identity != null and
                        skip_identity.? == (@intFromPtr(header) & ~@as(usize, 1));
                    std.debug.assert(already_consumed_prepared_object);
                    if (already_consumed_prepared_object) continue;
                }
            }
            item.value.free(self);
        }
        if (self.deferred_weak_value_frees_capacity != 0) {
            const old_items = self.deferred_weak_value_frees.ptr[0..self.deferred_weak_value_frees_capacity];
            self.deferred_weak_value_frees = &.{};
            self.deferred_weak_value_frees_capacity = 0;
            self.memory.free(DeferredWeakValueFree, old_items);
        }
    }

    fn ensureDeferredWeakValueFreeCapacity(self: *JSRuntime, min_capacity: usize) !void {
        if (self.deferred_weak_value_frees_capacity >= min_capacity) return;
        var next_capacity = if (self.deferred_weak_value_frees_capacity == 0) @as(usize, 16) else self.deferred_weak_value_frees_capacity * 2;
        while (next_capacity < min_capacity) : (next_capacity *= 2) {}
        const next = try self.memory.alloc(DeferredWeakValueFree, next_capacity);
        errdefer self.memory.free(DeferredWeakValueFree, next);
        const old_items = self.deferred_weak_value_frees;
        const old_capacity = self.deferred_weak_value_frees_capacity;
        @memcpy(next[0..old_items.len], old_items);
        self.deferred_weak_value_frees = next[0..old_items.len];
        self.deferred_weak_value_frees_capacity = next_capacity;
        if (old_capacity != 0) {
            self.memory.free(DeferredWeakValueFree, old_items.ptr[0..old_capacity]);
        }
    }

    pub fn beginBorrowedWeakCleanup(self: *JSRuntime) void {
        std.debug.assert(!self.borrowed_weak_cleanup_active);
        self.borrowed_weak_cleanup_active = true;
        self.borrowed_weak_cleanup_realm_identity_fallback = false;
        self.borrowed_weak_cleanup_seen_holder = false;
        self.borrowed_weak_cleanup_needs_rescan = false;
        self.current_deferred_weak_value_free_identity = null;
        self.borrowed_weak_cleanup_identity_set.clearRetainingCapacity();
        self.borrowed_weak_cleanup_identities = if (self.borrowed_weak_cleanup_identities_capacity == 0)
            &.{}
        else
            self.borrowed_weak_cleanup_identities.ptr[0..0];
        self.borrowed_weak_cleanup_realm_identities = if (self.borrowed_weak_cleanup_realm_identities_capacity == 0)
            &.{}
        else
            self.borrowed_weak_cleanup_realm_identities.ptr[0..0];
    }

    pub fn endBorrowedWeakCleanup(self: *JSRuntime) void {
        self.borrowed_weak_cleanup_active = false;
        self.borrowed_weak_cleanup_realm_identity_fallback = false;
        self.borrowed_weak_cleanup_seen_holder = false;
        self.borrowed_weak_cleanup_needs_rescan = false;
        self.current_deferred_weak_value_free_identity = null;
        self.borrowed_weak_cleanup_identity_set.clearRetainingCapacity();
        self.borrowed_weak_cleanup_identities = if (self.borrowed_weak_cleanup_identities_capacity == 0)
            &.{}
        else
            self.borrowed_weak_cleanup_identities.ptr[0..0];
        self.borrowed_weak_cleanup_realm_identities = if (self.borrowed_weak_cleanup_realm_identities_capacity == 0)
            &.{}
        else
            self.borrowed_weak_cleanup_realm_identities.ptr[0..0];
    }

    pub fn borrowedWeakCleanupActive(self: *const JSRuntime) bool {
        return self.borrowed_weak_cleanup_active;
    }

    pub fn markBorrowedWeakCleanupHolderSeen(self: *JSRuntime) void {
        self.borrowed_weak_cleanup_seen_holder = true;
    }

    pub fn borrowedWeakCleanupSeenHolder(self: *const JSRuntime) bool {
        return self.borrowed_weak_cleanup_seen_holder;
    }

    pub fn markBorrowedWeakCleanupNeedsRescan(self: *JSRuntime) void {
        self.borrowed_weak_cleanup_needs_rescan = true;
    }

    pub fn takeBorrowedWeakCleanupNeedsRescan(self: *JSRuntime) bool {
        const needs_rescan = self.borrowed_weak_cleanup_needs_rescan;
        self.borrowed_weak_cleanup_needs_rescan = false;
        return needs_rescan;
    }

    pub fn enqueueBorrowedWeakCleanupRealmIdentity(self: *JSRuntime, identity: usize) void {
        const index = self.borrowed_weak_cleanup_realm_identities.len;
        self.ensureBorrowedWeakCleanupRealmIdentityCapacity(index + 1) catch {
            self.borrowed_weak_cleanup_realm_identity_fallback = true;
            return;
        };
        self.borrowed_weak_cleanup_realm_identities = self.borrowed_weak_cleanup_realm_identities.ptr[0 .. index + 1];
        self.borrowed_weak_cleanup_realm_identities[index] = identity;
    }

    pub fn borrowedWeakCleanupRealmIdentityMatches(self: *const JSRuntime, identity: usize) bool {
        if (self.borrowed_weak_cleanup_realm_identity_fallback) return self.borrowedWeakCleanupIdentityMatches(identity);
        var index = self.borrowed_weak_cleanup_realm_identities.len;
        while (index != 0) {
            index -= 1;
            if (self.borrowed_weak_cleanup_realm_identities[index] == identity) return true;
        }
        return false;
    }

    pub fn borrowedWeakCleanupMayMatchRealmIdentity(self: *const JSRuntime) bool {
        return self.borrowed_weak_cleanup_realm_identity_fallback or self.borrowed_weak_cleanup_realm_identities.len != 0;
    }

    pub fn borrowedWeakCleanupIdentityCount(self: *const JSRuntime) usize {
        return self.borrowed_weak_cleanup_identities.len;
    }

    pub fn enqueueBorrowedWeakCleanupIdentity(self: *JSRuntime, identity: usize) !void {
        const index = self.borrowed_weak_cleanup_identities.len;
        try self.ensureBorrowedWeakCleanupIdentityCapacity(index + 1);
        if ((identity & 1) == 0) {
            try self.borrowed_weak_cleanup_identity_set.put(self.memory.persistent_allocator, identity, {});
        }
        self.borrowed_weak_cleanup_identities = self.borrowed_weak_cleanup_identities.ptr[0 .. index + 1];
        self.borrowed_weak_cleanup_identities[index] = identity;
    }

    /// Prepare borrowed-pointer cleanup before a last-ref value is released.
    /// The raw identity is also returned when no holder can reference the
    /// ordinary object; that records the completed liveness check so the
    /// deferred free does not conservatively enqueue an irrelevant full-table
    /// cleanup later.
    pub fn prepareBorrowedWeakCleanupForLastRefValue(self: *JSRuntime, value: JSValue) ?usize {
        _ = value;
        if (!self.borrowed_weak_cleanup_active) return null;
        // `objectFromLastRefValue` inferred "this release is the last one" from
        // the refcount. The tracer maintains no such count for objects, so
        // there is nothing to infer and the preparation has no work to do; it
        // retired with the collector that could answer the question.
        return null;
    }

    pub fn borrowedWeakCleanupIdentityMatches(self: *const JSRuntime, identity: usize) bool {
        if (identity == 0) return false;
        if ((identity & 1) == 0) {
            return self.borrowed_weak_cleanup_identity_set.contains(identity);
        }
        var index = self.borrowed_weak_cleanup_identities.len;
        while (index != 0) {
            index -= 1;
            if (self.borrowed_weak_cleanup_identities[index] == identity) return true;
        }
        return false;
    }

    pub inline fn borrowedWeakCleanupIdentityMatchesSlice(self: *const JSRuntime, start_index: usize, identity: usize) bool {
        if (identity == 0) return false;
        if ((identity & 1) == 0) {
            return self.borrowed_weak_cleanup_identity_set.contains(identity);
        }
        var index = self.borrowed_weak_cleanup_identities.len;
        while (index > start_index) {
            index -= 1;
            if (self.borrowed_weak_cleanup_identities[index] == identity) return true;
        }
        return false;
    }

    pub fn isCurrentDeferredWeakValueFreeIdentity(self: *const JSRuntime, identity: usize) bool {
        return self.current_deferred_weak_value_free_identity == identity;
    }

    pub fn clearBorrowedWeakCleanupIdentities(self: *JSRuntime) void {
        const identities: []usize = if (self.borrowed_weak_cleanup_identities_capacity != 0) self.borrowed_weak_cleanup_identities.ptr[0..self.borrowed_weak_cleanup_identities_capacity] else self.borrowed_weak_cleanup_identities[0..0];
        const realm_identities: []usize = if (self.borrowed_weak_cleanup_realm_identities_capacity != 0) self.borrowed_weak_cleanup_realm_identities.ptr[0..self.borrowed_weak_cleanup_realm_identities_capacity] else self.borrowed_weak_cleanup_realm_identities[0..0];
        self.borrowed_weak_cleanup_identity_set.clearRetainingCapacity();
        self.borrowed_weak_cleanup_identities = &.{};
        self.borrowed_weak_cleanup_identities_capacity = 0;
        self.borrowed_weak_cleanup_realm_identities = &.{};
        self.borrowed_weak_cleanup_realm_identities_capacity = 0;
        self.borrowed_weak_cleanup_active = false;
        self.borrowed_weak_cleanup_realm_identity_fallback = false;
        self.borrowed_weak_cleanup_seen_holder = false;
        self.borrowed_weak_cleanup_needs_rescan = false;
        self.current_deferred_weak_value_free_identity = null;
        if (identities.len != 0) self.memory.free(usize, identities);
        if (realm_identities.len != 0) self.memory.free(usize, realm_identities);
    }

    fn ensureBorrowedWeakCleanupIdentityCapacity(self: *JSRuntime, min_capacity: usize) !void {
        if (self.borrowed_weak_cleanup_identities_capacity >= min_capacity) return;
        var next_capacity = if (self.borrowed_weak_cleanup_identities_capacity == 0) @as(usize, 16) else self.borrowed_weak_cleanup_identities_capacity * 2;
        while (next_capacity < min_capacity) : (next_capacity *= 2) {}
        const next = try self.memory.alloc(usize, next_capacity);
        errdefer self.memory.free(usize, next);
        const old_items = self.borrowed_weak_cleanup_identities;
        const old_capacity = self.borrowed_weak_cleanup_identities_capacity;
        @memcpy(next[0..old_items.len], old_items);
        self.borrowed_weak_cleanup_identities = next[0..old_items.len];
        self.borrowed_weak_cleanup_identities_capacity = next_capacity;
        if (old_capacity != 0) {
            self.memory.free(usize, old_items.ptr[0..old_capacity]);
        }
    }

    fn ensureBorrowedWeakCleanupRealmIdentityCapacity(self: *JSRuntime, min_capacity: usize) !void {
        if (self.borrowed_weak_cleanup_realm_identities_capacity >= min_capacity) return;
        var next_capacity = if (self.borrowed_weak_cleanup_realm_identities_capacity == 0) @as(usize, 4) else self.borrowed_weak_cleanup_realm_identities_capacity * 2;
        while (next_capacity < min_capacity) : (next_capacity *= 2) {}
        const next = try self.memory.alloc(usize, next_capacity);
        errdefer self.memory.free(usize, next);
        const old_items = self.borrowed_weak_cleanup_realm_identities;
        const old_capacity = self.borrowed_weak_cleanup_realm_identities_capacity;
        @memcpy(next[0..old_items.len], old_items);
        self.borrowed_weak_cleanup_realm_identities = next[0..old_items.len];
        self.borrowed_weak_cleanup_realm_identities_capacity = next_capacity;
        if (old_capacity != 0) {
            self.memory.free(usize, old_items.ptr[0..old_capacity]);
        }
    }
};

fn appendRuntimeObject(account: *memory.MemoryAccount, slice: *[]*Object, capacity: *usize, item: *Object) !void {
    if (slice.*.len == capacity.*) {
        const next_capacity = if (capacity.* == 0) 64 else capacity.* * 2;
        const next = try account.alloc(*Object, next_capacity);
        errdefer account.free(*Object, next);
        @memcpy(next[0..slice.*.len], slice.*);
        const old_capacity = capacity.*;
        const old = if (old_capacity != 0) slice.*.ptr[0..old_capacity] else slice.*[0..0];
        slice.* = next[0..slice.*.len];
        capacity.* = next_capacity;
        if (old_capacity != 0) account.free(*Object, old);
    }
    const len = slice.*.len;
    slice.* = slice.*.ptr[0 .. len + 1];
    slice.*[len] = item;
}

fn appendRuntimeExternalHostFunction(
    account: *memory.MemoryAccount,
    slice: *[]host_function.ExternalRecord,
    capacity: *usize,
    item: host_function.ExternalRecord,
) !void {
    if (slice.*.len == capacity.*) {
        const next_capacity = if (capacity.* == 0) 4 else capacity.* * 2;
        const next = try account.alloc(host_function.ExternalRecord, next_capacity);
        errdefer account.free(host_function.ExternalRecord, next);
        @memcpy(next[0..slice.*.len], slice.*);
        const old_capacity = capacity.*;
        const old = if (old_capacity != 0) slice.*.ptr[0..old_capacity] else slice.*[0..0];
        slice.* = next[0..slice.*.len];
        capacity.* = next_capacity;
        if (old_capacity != 0) account.free(host_function.ExternalRecord, old);
    }
    const len = slice.*.len;
    slice.* = slice.*.ptr[0 .. len + 1];
    slice.*[len] = item;
}

fn appendRuntimeRootSlot(account: *memory.MemoryAccount, slice: *[]*RootSlot, capacity: *usize, item: *RootSlot) !void {
    if (slice.*.len == capacity.*) {
        const next_capacity = if (capacity.* == 0) 4 else capacity.* * 2;
        const next = try account.alloc(*RootSlot, next_capacity);
        errdefer account.free(*RootSlot, next);
        @memcpy(next[0..slice.*.len], slice.*);
        const old_capacity = capacity.*;
        const old = if (old_capacity != 0) slice.*.ptr[0..old_capacity] else slice.*[0..0];
        slice.* = next[0..slice.*.len];
        capacity.* = next_capacity;
        if (old_capacity != 0) account.free(*RootSlot, old);
    }
    const len = slice.*.len;
    slice.* = slice.*.ptr[0 .. len + 1];
    slice.*[len] = item;
}

fn appendRuntimeWeakRootSlot(account: *memory.MemoryAccount, slice: *[]*WeakRootSlot, capacity: *usize, item: *WeakRootSlot) !void {
    if (slice.*.len == capacity.*) {
        const next_capacity = if (capacity.* == 0) 4 else capacity.* * 2;
        const next = try account.alloc(*WeakRootSlot, next_capacity);
        errdefer account.free(*WeakRootSlot, next);
        @memcpy(next[0..slice.*.len], slice.*);
        const old_capacity = capacity.*;
        const old = if (old_capacity != 0) slice.*.ptr[0..old_capacity] else slice.*[0..0];
        slice.* = next[0..slice.*.len];
        capacity.* = next_capacity;
        if (old_capacity != 0) account.free(*WeakRootSlot, old);
    }
    const len = slice.*.len;
    slice.* = slice.*.ptr[0 .. len + 1];
    slice.*[len] = item;
}

test "value root frame activation restores nested scopes" {
    var rt: JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{});
    defer rt.deinit();

    try std.testing.expect(rt.active_value_roots == null);
    {
        var outer = ValueRootFrame{};
        outer.activate(&rt);
        defer outer.deactivate(&rt);
        try std.testing.expect(rt.active_value_roots == &outer);

        {
            var inner = ValueRootFrame{};
            inner.activate(&rt);
            defer inner.deactivate(&rt);
            try std.testing.expect(rt.active_value_roots == &inner);
        }

        try std.testing.expect(rt.active_value_roots == &outer);
    }
    try std.testing.expect(rt.active_value_roots == null);
}

test "value handle uses runtime persistent root slot" {
    var rt: JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{});
    defer rt.deinit();

    const object = try Object.create(&rt, class.ids.object, null);
    var handle = try rt.takeValueHandle(object.value());
    try std.testing.expectEqual(@as(usize, 1), rt.persistentRootCountForTest());
    try std.testing.expect(handle.get().isObject());

    const released = handle.take();
    defer released.free(&rt);
    try std.testing.expectEqual(@as(usize, 0), rt.persistentRootCountForTest());
    try std.testing.expect(released.isObject());

    handle.deinit();
    try std.testing.expectEqual(@as(usize, 0), rt.persistentRootCountForTest());
}

test "external memory accounting records debt and requests GC" {
    var rt: JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{
        .gc_policy = .{
            .external_weight = 2,
            .major_debt_threshold = 16,
        },
    });
    defer rt.deinit();

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
    var rt: JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{
        .gc_policy = .{
            .external_hard_limit = 8,
            .major_debt_threshold = std.math.maxInt(usize),
        },
    });
    defer rt.deinit();

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

/// Wall-clock microseconds for the Math.random seed (qjs js_random_init,
/// quickjs.c:47373, gettimeofday-based). Falls back to 1 on clock failure.
pub fn newRealmRandomSeed() u64 {
    const seed: u64 = @bitCast(platform_clock.realtimeMicros());
    return if (seed == 0) 1 else seed;
}
