//! `JSRuntime`: the stable-address resource owner and lifecycle coordinator.
//!
//! Runtime owns the atom/class/shape registries, the collector, allocation
//! diagnostics, and one embedded state per subsystem (roots, jobs and
//! checkpoint, execution records, interrupt and host wait, property side
//! tables, weak identities, string caches, native bindings, contexts). The
//! operations live with each subsystem's module; Runtime aggregates the
//! built-in strong roots (`traceActiveRoots`), orders teardown (`deinit`),
//! and carries the owner-checked host API. It is owner-thread confined
//! except at the explicitly synchronized host seams. QuickJS source map:
//! `JSRuntime` and its registries at quickjs.c. Fixed execution services
//! are reached only through `engine_services.zig`.

pub const native_allocation = @import("runtime_alloc.zig");

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
const JSValue = @import("core/value.zig").JSValue;
const Object = object_mod.Object;
const profile = @import("core/profile.zig");
const property = @import("core/property.zig");
const context_mod = @import("core/context.zig");
const context_registry = @import("core/context_registry.zig");
const errors = @import("core/errors.zig");
const vm_stack = @import("core/vm_stack.zig");

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

pub const InterruptHandler = interrupt_mod.Handler;
pub const Interrupt = interrupt_mod.Hook;

/// Runtime-wide dynamic-import loader authority. A Runtime can execute many
/// Realms; the active Realm is supplied to the callback at invocation time.
pub const DynamicImportLoader = struct {
    callback: ?context_mod.DynamicImportCallback = null,
    userdata: ?*anyopaque = null,
};

/// Scoped loader override, restored by `deinit` in LIFO order. `deinit` is
/// idempotent so error-path defers are safe. Every scope must close before
/// the Runtime is destroyed.
pub const DynamicImportLoaderScope = struct {
    runtime: *JSRuntime,
    previous: DynamicImportLoader,
    /// Nesting depth; scopes must close innermost first.
    depth: usize,
    active: bool = true,

    pub fn deinit(self: *DynamicImportLoaderScope) void {
        if (!self.active) return;
        const rt = self.runtime;
        rt.assertOwnerThread();
        // An inner scope still open means scopes closed out of order;
        // restoring here would reinstate a stale loader.
        if (rt.dynamic_import_loader_depth != self.depth) @panic("dynamic import loader scopes closed out of order");
        rt.dynamic_import_loader = self.previous;
        rt.dynamic_import_loader_depth -= 1;
        self.active = false;
    }
};

pub const VmStackStorage = vm_stack.VmStackStorage;
pub const StackBudget = vm_stack.StackBudget;
pub const VmStackArena = vm_stack.VmStackArena;

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

pub const ValueRootBuffer = roots_mod.ValueRootBuffer;
pub const ValueRootSlice = roots_mod.ValueRootSlice;
pub const HeaderRootValue = roots_mod.HeaderRootValue;
pub const AtomRootSlot = roots_mod.AtomRootSlot;
pub const value_root_link_containers_only = roots_mod.value_root_link_containers_only;
pub const ValueRootFrame = roots_mod.ValueRootFrame;
pub const ValueRootScope = roots_mod.ValueRootScope;
pub const rootValues = roots_mod.rootValues;
pub const rootObjects = roots_mod.rootObjects;
pub const rootAtoms = roots_mod.rootAtoms;
pub const rootAtomList = roots_mod.rootAtomList;
pub const rootAtomSlots = roots_mod.rootAtomSlots;

pub const RootTraceError = gc_roots_mod.RootTraceError;
pub const RootVisitor = gc_roots_mod.RootVisitor;

const native_bindings = @import("core/native_bindings.zig");
const interrupt_mod = @import("core/interrupt.zig");
const engine_services = @import("engine_services.zig");
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

/// A Runtime and every Realm/heap structure owned by it (class ids included:
/// each Runtime has its own ClassTable) are mutated only by the thread that
/// initialized the Runtime.
pub const RuntimeMutationError = error{WrongRuntimeThread};

pub const JSRuntime = struct {
    /// Iterations a long native loop runs between interrupt polls.
    pub const native_poll_interval = interrupt_mod.native_poll_interval;

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
    /// Open `DynamicImportLoaderScope`s.
    dynamic_import_loader_depth: usize = 0,
    native_bindings: native_bindings.Registry = .{},
    /// Host handler, termination request, and poll countdowns.
    interrupt: interrupt_mod.State = .{},
    /// Whether this thread may block, and the host-completion wake signal.
    host_wait: interrupt_mod.HostWait = .{},
    opcode_profile: ?*profile.OpcodeProfile = null,

    // Execution and stack accounting.

    stack: StackBudget = .{},
    /// Per-runtime VM value-stack arena for bytecode call frames.
    vm_stack: VmStackArena align(64) = .{},
    /// Live invocation records, backtrace chain, and exec feature state.
    execution: execution.State = .{},

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

    // Object side tables and caches.

    weak: gc_weak.Registry = .{},
    property_tables: property_state.State = .{},
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

        // Every field is defined before any subsystem can see `rt`; only the
        // three registry pointers are filled in as their tables are built.
        // GC callbacks remain disabled until the complete Runtime is activated.
        rt.* = .{
            .diagnostic_clock = options.diagnostic_clock,
            .allocator = allocator,
            .owner_thread_id = std.Thread.getCurrentId(),
            .gc = gc,
            .atoms = undefined,
            .classes = undefined,
            .shapes = undefined,
            .job_queue = job_mod.Queue.init(rt),
            .microtasks = .{ .policy = options.microtask_policy },
            .stack = .{
                .limit = options.stack_size,
                .frame_storage = VmStackStorage.frameWindowForLimit(options.stack_size),
                .native_size = options.native_stack_size,
                // Outermost execution entries re-arm this construction baseline.
                .native_top = native_stack_top,
            },
            .interrupt = .{ .hook = if (options.interrupt_handler) |handler| .{ .handler = handler, .context = options.interrupt_context } else null },
            .host_wait = .{ .can_block = options.can_block },
        };

        // The tables keep allocators bound to `rt` but must not allocate
        // through them during construction; check that nothing did.
        const storage_allocator = rt.probedNativeAllocator();
        const native_allocator = native_allocation.nativeAllocatorWithBacking(rt, allocator);
        rt.atoms = try AtomTable.create(allocator, .{
            .storage_allocator = storage_allocator,
            .native_allocator = native_allocator,
            .gc_registry = gc,
        });
        errdefer rt.atoms.destroy();
        rt.classes = try ClassTable.create(allocator, storage_allocator, rt.atoms);
        errdefer rt.classes.destroy();
        rt.shapes = try ShapeRegistry.create(allocator, storage_allocator, rt.atoms, gc);
        errdefer rt.shapes.destroy();
        std.debug.assert(std.meta.eql(rt.allocation_diagnostics, native_allocation.AllocationDiagnostics{}));

        rt.stack.armNativeLimit();

        // Every owned subsystem and root set is ready before collection can run.
        gc.activate(rt);
        return rt;
    }

    pub fn isOwnerThread(self: *const JSRuntime) bool {
        return self.owner_thread_id == std.Thread.getCurrentId();
    }

    pub fn requireOwnerThread(self: *const JSRuntime) RuntimeMutationError!void {
        if (!self.isOwnerThread()) return error.WrongRuntimeThread;
    }

    /// Host entry points check the owner thread in every build mode.
    pub fn assertOwnerThread(self: *const JSRuntime) void {
        if (!self.isOwnerThread()) @panic("JSRuntime mutation from non-owner thread");
    }

    /// Engine primitives that are also hot internal paths (atom interning,
    /// symbol materialization) check only in safety-checked builds, like
    /// `ClassTable.assertOwnerThread`.
    inline fn debugAssertOwnerThread(self: *const JSRuntime) void {
        if (comptime std.debug.runtime_safety) self.assertOwnerThread();
    }

    /// True while any JS or native call frame of this runtime is active.
    pub fn isExecuting(self: *const JSRuntime) bool {
        return self.stack.call_depth != 0 or self.stack.native_call_depth != 0 or self.execution.active_invocation != null;
    }

    pub fn assertExecutionAllowed(self: *const JSRuntime) void {
        if (self.roots.isTracing()) @panic("JavaScript execution during tracing");
    }

    pub fn assertGCAllowed(self: *const JSRuntime) void {
        if (comptime gc_scope.checks_enabled) {
            if (self.active_no_gc_scope != null) @panic("collection during no-GC scope");
        }
    }

    fn deinit(self: *JSRuntime) void {
        self.assertOwnerThread();
        if (self.teardownRefusal()) |reason| @panic(reason);
        // The resident host invocation (exec/call_site.zig) is only ever
        // published for the duration of a call, so an idle runtime retires it
        // here; a runtime destroyed mid-call fails the assertion above first.
        execution.retireHostInvocation(self);
        // Pending waitAsync nodes live in a process-wide list that foreign
        // threads walk; none may outlive this Runtime, including those of
        // child realms no host Context ever cleaned up.
        engine_services.retireAtomicsWaiters(self);
        self.vm_stack.deinit(self.nativeAllocator());
        self.exception.clear();
        self.microtasks.clearKeptObjects(self.nativeAllocator());
        self.job_queue.deinit();
        self.strings = .{};
        // Teardown does not own public handles or root providers: every
        // scope/persistent/weak/provider owner must close its edge first.
        self.roots.assertNoOutstanding();
        self.gc.scheduler.host_quiescent = true;
        _ = gc_driver.collectForTeardown(self);
        // The collection may enqueue FinalizationRegistry cleanups for dead
        // targets; drop them so the second pass can reclaim their held values.
        self.job_queue.discardKind(.finalization);
        _ = gc_driver.collectForTeardown(self);
        self.gc.scheduler.host_quiescent = false;
        self.property_tables.weak_cleanup.end();
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
        // Host function `state` finalizers run only after every managed
        // object -- including NativeObject payload finalizers that may share
        // that state -- has been finalized. The entries go with them.
        native_bindings.destroyOwned(self);
        // These native containers share the Runtime allocator for their entire
        // lifetime; parser scratch is owned separately by each compilation.
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

    /// Checked teardown entry for hosts that cannot prove their call thread
    /// or that the Runtime is idle: `WrongRuntimeThread` off the owner thread,
    /// `RuntimeBusy` while execution, a scope, a root frame or a host root
    /// edge (handle, root provider, undestroyed Context) is still open. On
    /// rejection the Runtime is untouched and remains owned by its creator.
    pub fn tryDestroy(self: *JSRuntime) (RuntimeMutationError || error{RuntimeBusy})!void {
        try self.requireOwnerThread();
        if (self.teardownRefusal() != null or
            self.roots.firstOutstanding() != null or
            context_registry.anyHostRealmRef(self)) return error.RuntimeBusy;
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

    pub fn firstContext(self: *const JSRuntime) ?*context_mod.JSContext {
        return self.contexts.live_head;
    }

    /// The published realm whose global object is `global`.
    pub fn contextForGlobal(self: *const JSRuntime, global: *const Object) ?*context_mod.JSContext {
        return self.contexts.forGlobal(global, .live_only);
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

    /// Every strong root of this Runtime, in one trace window: stack frames,
    /// the pending exception, handles, queued and running jobs, WeakRef
    /// [[KeptAlive]], providers, caches, atoms, class names, running
    /// invocations and waitAsync waiters.
    pub fn traceActiveRoots(self: *JSRuntime, visitor: *RootVisitor) RootTraceError!void {
        self.roots.beginTrace();
        defer self.roots.endTrace();
        try ValueRootFrame.traceChain(self.active_value_roots, visitor);
        try visitor.value(&self.exception.value);
        try self.roots.traceHandleSlots(visitor);
        try self.job_queue.traceRoots(visitor);
        try self.microtasks.traceKeptAlive(visitor);
        try self.roots.traceProviders(visitor);
        try string_cache.trace(self, visitor);
        try self.atoms.traceRoots(visitor);
        try self.traceAtomRoots(visitor);
        try job_mod.ActiveJobRoot.traceFor(self, visitor);
        if (self.execution.active_invocation) |invocation| try engine_services.traceActiveInvocations(invocation, visitor);
        // Exec snapshots this Runtime's waiters under the registry mutex,
        // unlocks, then visits their Promise roots (design §7.1).
        if (self.execution.wait_async_used) try engine_services.traceAtomicsWaitAsyncRoots(self, visitor);
    }

    /// Atom ids owned outside any GC header: class names. Exact --
    /// `Table.unregister` releases the same ids.
    fn traceAtomRoots(self: *JSRuntime, visitor: *RootVisitor) RootTraceError!void {
        if (visitor.visit_atom == null) return;
        for (self.classes.records) |record| {
            try visitor.atomRoot(record.class_name);
        }
    }

    /// Idle-execution refusal, then an open host scope. `deinit` panics with
    /// the text; `tryDestroy` treats it as busy. Outstanding host roots and
    /// realm refs are not included: deinit checks those later, and the realm
    /// ref assert is debug-only. Gate audits call `assertIdleForTeardown`
    /// alone so an open host scope can remain.
    fn teardownRefusal(self: *const JSRuntime) ?[]const u8 {
        if (self.teardownBlocker()) |reason| return reason;
        return self.openHostScope();
    }

    /// Stack-local execution/root records are borrowed by Runtime. They must be
    /// gone before teardown in every optimization mode; silently continuing
    /// would leave their deferred cleanup pointing into a destroyed Runtime.
    fn assertIdleForTeardown(self: *const JSRuntime) void {
        if (self.teardownBlocker()) |reason| @panic(reason);
    }

    /// Why teardown cannot start now, or null when the Runtime is idle.
    fn teardownBlocker(self: *const JSRuntime) ?[]const u8 {
        if (comptime gc_scope.checks_enabled) {
            if (self.active_no_gc_scope != null) return "JSRuntime destroyed during no-GC scope";
        }
        if (self.roots.isTracing()) return "JSRuntime destroyed during tracing";
        if (self.roots.active_exact_roots != null) return "JSRuntime destroyed with active exact roots";
        if (self.roots.value_root_buffers != 0) return "JSRuntime destroyed with outstanding value root buffers";
        if (self.stack.call_depth != 0 or
            self.stack.native_call_depth != 0 or
            self.stack.bytecode_bytes != 0 or
            self.execution.hasLiveRecords() or
            self.active_value_roots != null or
            job_mod.ActiveJobRoot.anyFor(self) or
            self.microtasks.running or self.microtasks.scope_depth != 0)
        {
            return "JSRuntime destroyed while execution or root frames are active";
        }
        return null;
    }

    /// Host scopes that hold this Runtime and would touch it on close. Not
    /// part of `teardownBlocker`: an idle Runtime (gate audits) may keep them.
    fn openHostScope(self: *const JSRuntime) ?[]const u8 {
        if (self.roots.handle_scope_depth != 0) return "JSRuntime destroyed with an open handle scope";
        if (self.dynamic_import_loader_depth != 0) return "JSRuntime destroyed with an open dynamic import loader scope";
        return null;
    }

    /// Resolves an even weak identity (`weak_id << 1`) to its registered
    /// object in O(1). Returns null for symbol identities and for ids whose
    /// object is gone; destruction hands the id back in the same step that
    /// frees the object, so the map lookup is the whole liveness test.
    pub const liveObjectFromWeakIdentity = gc_weak.objectFromIdentity;

    /// Returns the encoded weak identity for `object`, allocating a fresh
    /// monotonically increasing weak id on first registration.
    pub const registerWeakObjectIdentity = gc_weak.registerObject;

    pub fn enterHandleScope(self: *JSRuntime) HandleScope {
        self.assertOwnerThread();
        return HandleScope.enter(self);
    }

    pub fn symbolValue(self: *JSRuntime, atom_id: atom.Atom) !JSValue {
        self.debugAssertOwnerThread();
        return self.atoms.symbolValue(self, atom_id);
    }

    pub fn newSymbolValue(self: *JSRuntime, description: ?[]const u8) !JSValue {
        self.assertOwnerThread();
        const atom_id = if (description) |bytes|
            try self.atoms.newValueSymbol(bytes)
        else
            try self.atoms.newValueSymbolNoDescription();
        errdefer self.atoms.abandonUnpublishedSymbol(atom_id);
        return self.symbolValue(atom_id);
    }

    pub fn globalSymbolValue(self: *JSRuntime, key: []const u8) !JSValue {
        self.assertOwnerThread();
        const atom_id = try self.atoms.internRegisteredValueSymbol(key);
        return self.symbolValue(atom_id);
    }

    /// One strong persistent handle; a `JSValue` is copied by bits.
    pub fn createPersistentValue(self: *JSRuntime, value: JSValue) !JSValueHandle {
        self.assertOwnerThread();
        return JSValueHandle.init(self, value);
    }

    pub fn createWeakPersistentValue(
        self: *JSRuntime,
        value: JSValue,
        callback: ?WeakPersistentCallback,
        callback_context: ?*anyopaque,
    ) !WeakPersistentValue {
        self.assertOwnerThread();
        return WeakPersistentValue.init(self, value, callback, callback_context);
    }

    /// NB2: allocate an immutable, address-stable host `NativeEntry` from a
    /// template. Never freed before `deinit` (design §5.5 lifetime rule).
    pub const allocNativeEntry = native_bindings.alloc;

    pub const registerNativeEntryFinalizer = native_bindings.registerFinalizer;

    /// Precise full collection for test fixtures: only declared roots (and
    /// the active chain) keep objects alive.
    pub fn collectForTest(self: *JSRuntime) gc_mod.CollectionError!gc_mod.CollectionResult {
        if (!builtin.is_test) @compileError("test-only collection helper");
        return gc_driver.collectWithScanForTest(self, .declared_only);
    }

    /// Stop-the-world full collection from an engine-internal trigger.
    pub const collectFull = gc_driver.collectFull;
    /// Service pending collection requests at a poll of the given mode.
    pub const pollGC = gc_driver.pollGC;
    /// Host-requested full collection.
    pub const forceGC = gc_driver.forceGC;

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
        self.assertOwnerThread();
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

    /// Pause percentiles over the collector's retained round window, or null
    /// if no collection has completed. Separate from `gcStats` because it
    /// sorts a scratch copy; callers that only want counters should not pay
    /// for it.
    pub fn gcPauseDistribution(self: *const JSRuntime) ?gc_mod.PauseDistribution {
        self.assertOwnerThread();
        return self.gc.pauseDistribution();
    }

    fn fillGcCounters(self: *const JSRuntime, stats: *gc_mod.Stats) void {
        stats.weak_ref_count = self.weakRootSlotCount();
        stats.finalizer_queue_length = self.job_queue.countKind(.finalization);
    }

    /// Maintained counters only. Does not walk the heap.
    pub fn gcStats(self: *const JSRuntime) gc_mod.Stats {
        self.assertOwnerThread();
        var stats = self.gc.counterSnapshot(self);
        self.fillGcCounters(&stats);
        return stats;
    }

    /// One heap census. Heap bytes stay separate from external debt.
    pub fn gcDetailedStats(self: *const JSRuntime) gc_mod.DetailedStats {
        self.assertOwnerThread();
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

    pub const requestGCForAllocation = gc_driver.requestGCForAllocation;

    pub const collectBeforeObjectAllocation = gc_driver.collectBeforeObjectAllocation;

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
        gc_driver.admitHeapCharge(self, bytes) catch |err| switch (err) {
            error.OutOfMemory => {},
        };
    }

    /// Return the shared single-code-unit (latin1) string for `byte`,
    /// creating it lazily on the first request. The cache slot is itself a
    /// root, so the body outlives every borrow of it; there is no per-caller
    /// retain to take.
    ///
    /// Inline load + branch; the one-shot creation is outlined so a hit costs
    /// nothing more than the table read.
    pub const singleByteString = string_cache.singleByte;

    /// Non-allocating probe: null when the slot has not been filled yet.
    pub const cachedSingleByteString = string_cache.cachedSingleByte;

    pub const emptyString = string_cache.empty;

    /// Return a borrowed cached string for a two-code-unit sequence.
    pub const recentTwoUnitString = string_cache.recentTwoUnit;

    /// Return a borrowed cached string for a recently materialized atom.
    pub const recentAtomString = string_cache.recentAtom;

    /// Return a borrowed cached decimal string ("0".."255") for a byte.
    pub const smallIntString = string_cache.smallInt;

    pub const percentHexString = string_cache.percentHex;

    pub fn setStackSize(self: *JSRuntime, size: usize) void {
        self.assertOwnerThread();
        self.stack.setLimit(size);
    }

    pub fn stackSize(self: *const JSRuntime) usize {
        return self.stack.limit;
    }

    pub fn nativeStackSize(self: *const JSRuntime) usize {
        return self.stack.native_size;
    }

    pub fn setNativeStackSize(self: *JSRuntime, budget_bytes: usize) void {
        self.assertOwnerThread();
        self.stack.setNativeSize(budget_bytes);
    }

    pub fn internAtom(self: *JSRuntime, bytes: []const u8) !atom.Atom {
        self.debugAssertOwnerThread();
        return self.atoms.internString(bytes);
    }

    pub fn registerClass(self: *JSRuntime, definition: class.Definition) !class.Binding {
        return self.classes.registerDefinition(self, definition);
    }

    /// Owner thread only; `terminateExecution` is the cross-thread request.
    pub fn setInterruptHandler(self: *JSRuntime, handler: ?InterruptHandler, context: ?*anyopaque) void {
        self.assertOwnerThread();
        self.interrupt.hook = if (handler) |h| .{ .handler = h, .context = context } else null;
    }

    pub fn installDynamicImportLoader(self: *JSRuntime, next: DynamicImportLoader) DynamicImportLoaderScope {
        self.assertOwnerThread();
        const previous = self.dynamic_import_loader;
        self.dynamic_import_loader = next;
        self.dynamic_import_loader_depth += 1;
        return .{
            .runtime = self,
            .previous = previous,
            .depth = self.dynamic_import_loader_depth,
        };
    }

    /// Thread-safe request. The caller must keep this Runtime alive.
    pub fn terminateExecution(self: *JSRuntime) void {
        self.interrupt.termination_requested.store(true, .release);
    }

    pub fn isExecutionTerminating(self: *const JSRuntime) bool {
        return self.interrupt.isTerminating();
    }

    /// Owner-only idle recovery. Requests ordered after this exchange survive.
    pub fn cancelTerminateExecution(self: *JSRuntime) (RuntimeMutationError || error{RuntimeBusy})!void {
        try self.requireOwnerThread();
        if (self.isExecuting() or self.microtasks.running) return error.RuntimeBusy;
        _ = self.interrupt.termination_requested.swap(false, .acq_rel);
    }
};

/// Gate-only check used after the CLI has finished draining jobs: every
/// collection destroys what it condemned, so the morgue must be empty. A
/// module function rather than a JSRuntime method so this internal
/// diagnostic does not enlarge the public embedder API.
pub fn auditDoomedStateForGateStats(rt: *JSRuntime) void {
    rt.assertOwnerThread();
    rt.assertIdleForTeardown();
    std.debug.assert(!rt.gc.isBusy());
    @import("core/gc_trace_stw.zig").auditDoomedExitInvariant(rt);
}

/// Allocation tests can explicitly select standalone/slab routes before use.
pub fn createAllocationTestRuntime(allocator: std.mem.Allocator) !*JSRuntime {
    if (!builtin.is_test) @compileError("test fixture only");
    const rt = try JSRuntime.create(allocator, .{});
    rt.gc.cell_storage.block_heap = null;
    rt.gc.cell_storage.nursery = null;
    rt.gc.cell_storage.slab_enabled = false;
    return rt;
}

test {
    // Unit tests of the subsystem modules Runtime embeds.
    _ = vm_stack;
    _ = interrupt_mod;
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

    var token = try rt.gc.reportExternalAlloc(8);
    var duplicate_token = token;
    try std.testing.expectEqual(@as(usize, 8), rt.gcStats().external_bytes);
    try std.testing.expectEqual(@as(usize, 16), rt.gcStats().allocation_debt);
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().external_token_count);
    try std.testing.expectEqual(@as(usize, 8), rt.gcStats().external_token_bytes);
    try std.testing.expect(rt.gc.hasPendingMajorRequest());
    try std.testing.expectEqual(@as(?gc_mod.RequestReason, gc_mod.RequestReason.allocation_debt), rt.gc.stats.last_request_reason);

    const result = try rt.pollGC(.normal);
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

    var token = try rt.gc.reportExternalAlloc(8);
    defer token.release();

    const pending = rt.gcStats();
    try std.testing.expect(pending.pending_major);
    try std.testing.expectEqual(@as(?gc_mod.RequestReason, gc_mod.RequestReason.external_memory), pending.pending_request_reason);
    try std.testing.expectEqual(@as(?gc_mod.RequestUrgency, gc_mod.RequestUrgency.urgent), pending.pending_request_urgency);

    _ = try rt.pollGC(.callback_boundary);
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

    _ = try rt.pollGC(.safepoint);
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
    try std.testing.expectEqual(@as(usize, 2), rt.dynamic_import_loader_depth);
    inner.deinit();
    inner.deinit(); // idempotent
    try std.testing.expectEqual(@as(?*anyopaque, &outer_data), rt.dynamic_import_loader.userdata);
    // Re-installing the same loader is still a distinct, ordered scope.
    var same = rt.installDynamicImportLoader(.{ .userdata = &outer_data });
    try std.testing.expectEqual(@as(usize, 2), same.depth);
    same.deinit();
    outer.deinit();
    try std.testing.expectEqual(@as(?*anyopaque, null), rt.dynamic_import_loader.userdata);
    try std.testing.expectEqual(@as(usize, 0), rt.dynamic_import_loader_depth);
}

test "tryDestroy rejects a busy runtime and leaves it intact" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    var destroyed = false;
    defer if (!destroyed) rt.destroy();

    const Probe = struct {
        fn trace(_: *anyopaque, _: *RootVisitor) RootTraceError!void {}
    };
    var provider_state: u8 = 0;
    const provider = RootProvider{ .context = &provider_state, .trace = Probe.trace };
    try rt.registerRootProvider(provider);
    try std.testing.expectEqual(@as(?RootSet.Outstanding, .root_providers), rt.roots.firstOutstanding());
    try std.testing.expectError(error.RuntimeBusy, rt.tryDestroy());
    rt.unregisterRootProvider(provider);

    var handle = try rt.createPersistentValue(JSValue.int32(1));
    try std.testing.expectEqual(@as(?RootSet.Outstanding, .value_handles), rt.roots.firstOutstanding());
    try std.testing.expectError(error.RuntimeBusy, rt.tryDestroy());
    handle.deinit();

    var scope = rt.enterHandleScope();
    try std.testing.expectError(error.RuntimeBusy, rt.tryDestroy());
    scope.deinit();

    var loader = rt.installDynamicImportLoader(.{});
    try std.testing.expectError(error.RuntimeBusy, rt.tryDestroy());
    loader.deinit();

    var microtasks = try rt.enterMicrotaskScope();
    try std.testing.expectError(error.RuntimeBusy, rt.tryDestroy());
    try microtasks.finish();

    const ctx = try context_mod.JSContext.create(rt, .{});
    try std.testing.expectError(error.RuntimeBusy, rt.tryDestroy());
    ctx.destroy();

    try std.testing.expectEqual(@as(?RootSet.Outstanding, null), rt.roots.firstOutstanding());
    try rt.tryDestroy();
    destroyed = true;
}

test "persistent handles release in any order" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    var handles: [3]JSValueHandle = undefined;
    for (&handles, 0..) |*handle, index| handle.* = try rt.createPersistentValue(JSValue.int32(@intCast(index)));
    handles[0].deinit();
    try std.testing.expectEqual(@as(usize, 2), rt.roots.persistent_root_slots.items.len);
    try std.testing.expectEqual(@as(?i32, 1), handles[1].get().as(.int));
    try std.testing.expectEqual(@as(?i32, 2), handles[2].get().as(.int));
    handles[2].deinit();
    handles[1].deinit();
    try std.testing.expectEqual(@as(usize, 0), rt.roots.persistent_root_slots.items.len);
}

test "an abandoned native entry is returned to the runtime" {
    const rt = try JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();

    const kept = try rt.allocNativeEntry(native_entry.retired_entry);
    const before = rt.allocation_diagnostics.allocated_bytes;
    const abandoned = try rt.allocNativeEntry(native_entry.retired_entry);
    native_bindings.abandon(rt, abandoned);
    try std.testing.expectEqual(before, rt.allocation_diagnostics.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), rt.native_bindings.entries.items.len);
    try std.testing.expectEqual(@as(*const native_entry.NativeEntry, kept), rt.native_bindings.entries.items[0]);
}

test "host state finalizers run after managed objects are finalized" {
    const native_object = @import("core/native_object.zig");
    const Log = struct {
        var events: [2]u8 = undefined;
        var len: usize = 0;

        fn record(event: u8) void {
            events[len] = event;
            len += 1;
        }
        fn object(_: *anyopaque) callconv(.c) void {
            record('o');
        }
        fn state(_: *anyopaque) void {
            record('s');
        }
    };
    Log.len = 0;
    var shared: u8 = 0;
    {
        const rt = try JSRuntime.create(std.testing.allocator, .{});
        defer rt.destroy();
        const native_type = try native_object.registerType(rt, "OrderProbe", Log.object);
        _ = try native_object.create(rt, native_type, null, &shared);
        try rt.registerNativeEntryFinalizer(&shared, Log.state);
    }
    try std.testing.expectEqualSlices(u8, "os", Log.events[0..Log.len]);
}
