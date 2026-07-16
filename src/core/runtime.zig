const std = @import("std");
const builtin = @import("builtin");

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

/// Contiguous VM value-stack arena mirroring QuickJS's `alloca`-based
/// `JS_CallInternal` frame layout. Call frames carve LIFO windows for
/// `[args | locals | operand stack]` instead of per-call heap allocations.
/// Windows are stable for their lifetime (chunks never move); release is a
/// watermark restore. Values inside windows are owned by the frames using
/// them and must be released before the watermark is restored.
pub const VmStackArena = struct {
    pub const chunk_slots: usize = 32 * 1024;
    pub const max_chunks: usize = 64;

    pub const Mark = struct {
        chunk: usize,
        used: usize,
    };

    chunks: [max_chunks][]JSValue = @splat(&.{}),
    used: [max_chunks]usize = @splat(0),
    chunk_count: usize = 0,
    active: usize = 0,

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
            const used = self.used[self.active];
            if (chunk_slots - used >= n) {
                self.used[self.active] = used + n;
                return self.chunks[self.active][used .. used + n];
            }
        }
        return self.carveSlow(account, n);
    }

    /// Switch to or allocate another arena chunk.  The active chunk satisfies
    /// virtually every ordinary call after the first one; keeping backing
    /// allocation and its memory-accounting/error machinery out of `carve`
    /// lets that steady arm remain a leaf, like QJS's `alloca` bump.
    noinline fn carveSlow(self: *VmStackArena, account: *memory.MemoryAccount, n: usize) ?[]JSValue {
        const next_index = if (self.chunk_count == 0) 0 else self.active + 1;
        if (next_index >= max_chunks) return null;
        if (next_index >= self.chunk_count) {
            const chunk = account.alloc(JSValue, chunk_slots) catch return null;
            self.chunks[next_index] = chunk;
            self.chunk_count = next_index + 1;
        }
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

pub const ValueRootFrame = struct {
    previous: ?*const ValueRootFrame = null,
    slices: []const ValueRootSlice = &.{},
    values: []const ValueRootValue = &.{},
    objects: []const ObjectRootValue = &.{},
};

pub const RootTraceError = std.mem.Allocator.Error || error{PayloadMarkFailed};

pub const RootVisitor = struct {
    context: *anyopaque,
    visit_value: *const fn (context: *anyopaque, slot: *JSValue) RootTraceError!void,
    visit_object: *const fn (context: *anyopaque, slot: *?*Object) RootTraceError!void,

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
};

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

pub const FinalizationJob = struct {
    sequence: u64 = 0,
    callback: JSValue = JSValue.undefinedValue(),
    held_value: JSValue = JSValue.undefinedValue(),
    symbol_root_mask: u2 = 0,

    pub fn init(rt: *JSRuntime, sequence: u64, callback: JSValue, held_value: JSValue) !FinalizationJob {
        var job = FinalizationJob{
            .sequence = sequence,
            .callback = callback.dup(),
            .held_value = held_value.dup(),
        };
        errdefer {
            job.callback.free(rt);
            job.held_value.free(rt);
        }
        errdefer job.unregisterSymbolRoots(rt);
        if (try rt.registerExternalValueSymbolRoot(callback)) job.symbol_root_mask |= 0b01;
        if (try rt.registerExternalValueSymbolRoot(held_value)) job.symbol_root_mask |= 0b10;
        return job;
    }

    pub fn deinit(self: FinalizationJob, rt: *JSRuntime) void {
        self.unregisterSymbolRoots(rt);
        self.callback.free(rt);
        self.held_value.free(rt);
    }

    fn unregisterSymbolRoots(self: FinalizationJob, rt: *JSRuntime) void {
        if ((self.symbol_root_mask & 0b01) != 0) rt.unregisterExternalValueSymbolRoot(self.callback);
        if ((self.symbol_root_mask & 0b10) != 0) rt.unregisterExternalValueSymbolRoot(self.held_value);
    }

    pub fn traceRoots(self: *FinalizationJob, visitor: *RootVisitor) RootTraceError!void {
        try visitor.value(&self.callback);
        try visitor.value(&self.held_value);
    }
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

    /// Compatibility spelling for the previous persistent handle API.
    pub fn destroy(self: JSValueHandle, rt: *JSRuntime) void {
        if (self.runtime) |runtime| std.debug.assert(runtime == rt);
        var owned = self;
        owned.deinit();
    }

    pub fn release(self: *JSValueHandle) JSValue {
        const runtime = self.runtime orelse return JSValue.undefinedValue();
        const slot = self.slot orelse return JSValue.undefinedValue();
        const value = runtime.takePersistentRootSlot(slot);
        self.runtime = null;
        self.slot = null;
        return value;
    }
};

const PersistentValue = JSValueHandle;

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
        self.exit();
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

    pub fn exit(self: *HandleScope) void {
        if (!self.active) return;
        std.debug.assert(self.start <= self.runtime.local_root_slots.len);
        self.runtime.clearLocalRootSlotsFrom(self.start);
        self.active = false;
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

    pub fn release(self: *NativePin) void {
        const runtime = self.runtime orelse return;
        const header = self.header orelse return;
        self.runtime = null;
        self.header = null;
        runtime.gc.unpinHeader(header);
        gc.release(runtime, header);
    }

    pub fn deinit(self: *NativePin) void {
        self.release();
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
    finalizer: class.PayloadFinalizer,
    payload: class.Payload = null,
    payload_kind: class.PayloadKind = .none,
    object_identity: usize = 0,

    pub fn run(self: *DeferredClassPayloadFinalizer, rt: *JSRuntime) void {
        var payload = self.payload;
        self.payload = null;
        self.finalizer(@ptrCast(rt), @ptrCast(&self.object_identity), &payload);
        object_mod.destroyDetachedClassPayload(rt, self.class_id, self.payload_kind, &payload);
    }

    pub fn traceRoots(self: *DeferredClassPayloadFinalizer, rt: *JSRuntime, visitor: *RootVisitor) RootTraceError!void {
        if (self.payload == null) return;
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
        _ = rt.classes.markPayload(self.class_id, @ptrCast(rt), @ptrCast(&self.object_identity), &self.payload, &payload_visitor);
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

pub const shared_lazy_native_function_slots = 12;
pub const internal_destructuring_helper_slots = 14;
const root_provider_inline_capacity = 1;

pub const JSRuntime = struct {
    pub const Options = RuntimeOptions;

    memory: memory.MemoryAccount,
    owns_self_allocation: bool = false,
    gc: gc.Registry,
    atoms: atom.AtomTable,
    classes: class.Table,
    shapes: shape.Registry,
    modules: module.Registry,
    auto_init_table: std.ArrayListUnmanaged(property.AutoInit) = .empty,
    /// Shared, interned-once descriptor id for the lazy `function.prototype`
    /// auto-init placeholder (`property.AutoInitKind.function_prototype`). All
    /// functions reuse this single table entry; the materializer derives the
    /// realm + constructor from the owner function object, so no per-function
    /// descriptor is needed (avoids unbounded `auto_init_table` growth).
    function_prototype_auto_init: ?property.AutoInitRef = null,
    materialize_builtin_namespace_cb: ?*const fn (rt: *JSRuntime, global: *Object, kind: property.AutoInitKind) anyerror!?JSValue = null,
    materialize_context_global_cb: ?*const fn (ctx: *context_mod.JSContext) anyerror!*Object = null,
    /// Bootstrap install seam: builds the standard global object. Seeded from the
    /// process-global default at `init`; `exec/standard_globals.zig` registers
    /// that default. Core invokes it through this callback seam.
    install_standard_globals_cb: ?StandardGlobalsInstaller = null,
    /// Own-property count to reserve on a global object before running
    /// `install_standard_globals_cb`. Seeded alongside the installer at `init`.
    standard_global_own_property_capacity: usize = 0,

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
    pending_finalization_jobs: []FinalizationJob = &.{},
    pending_finalization_jobs_capacity: usize = 0,
    job_queue: job_mod.Queue = undefined,
    deferred_native_cleanups: []NativeCleanupJob = &.{},
    deferred_native_cleanups_capacity: usize = 0,
    draining_deferred_native_cleanups: bool = false,
    deferred_native_cleanup_run_count: usize = 0,
    deferred_class_payload_finalizers: []DeferredClassPayloadFinalizer = &.{},
    deferred_class_payload_finalizers_capacity: usize = 0,
    reserved_deferred_class_payload_finalizer_slots: usize = 0,
    draining_deferred_class_payload_finalizers: bool = false,
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
    next_job_sequence: u64 = 0,
    malloc_gc_threshold: usize = default_gc_threshold,
    gc_running: bool = false,
    current_exception: JSValue = JSValue.uninitialized(),
    stack_size: usize = default_stack_size,
    /// Native (machine C-stack) recursion guard, mirroring QuickJS
    /// `rt->stack_top`/`rt->stack_limit` (quickjs.c:349-350, 2841-2860). Captured
    /// via `@frameAddress()` at the outermost eval entry (`updateNativeStackTop`,
    /// the JS_UpdateStackTop analogue — refreshed per thread because worker
    /// threads run on a different C stack than where the runtime was
    /// constructed). Zero limit means "no limit yet". `native_stack_limit` is the
    /// lower address bound (`native_stack_top - native_stack_size`); a native
    /// frame pointer below it is an overflow. See `checkNativeStackOverflow`.
    native_stack_top: usize = 0,
    native_stack_limit: usize = 0,
    native_stack_size: usize = default_native_stack_size,
    /// Per-runtime VM value-stack arena for bytecode call frames.
    vm_stack: VmStackArena = .{},
    interrupt_handler: ?InterruptHandler = null,
    interrupt_context: ?*anyopaque = null,
    can_block: bool = false,
    random_state: u64 = 0x1234_5678_9abc_def0,
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
    recent_atom_string_next: usize = 0,
    /// Lazy cache for uppercase percent-escaped byte strings (`%00`..`%FF`).
    /// This is a general URI hot-path cache, not a fixture shortcut:
    /// ECMAScript URI helpers and decimal-to-percent harnesses both
    /// repeatedly construct these immutable three-byte strings.
    percent_hex_strings: [256]?*string.String = @splat(null),
    /// Lazy cache for small integer strings ("0".."255").
    small_int_strings: [256]?*string.String = @splat(null),
    /// JSRuntime-owned internal destructuring helper functions. Parser-emitted
    /// destructuring bytecode uses these as stack-only callees instead of
    /// resolving pseudo-private `__zjs_dstr_*` globals.
    internal_destructuring_helpers: [internal_destructuring_helper_slots]?JSValue = @splat(null),
    /// Error object preallocated while memory is plentiful so the VM catch
    /// machinery can still materialize a catch value when the heap is fully
    /// exhausted (QuickJS's preallocated out-of-memory exception analogue).
    /// Populated by the exec layer at context-global bootstrap.
    preallocated_oom_error: ?JSValue = null,
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
    internal_builtins: []const []const host_function.InternalRecord = &.{},
    any_prototype_may_have_indexed_properties: bool = false,
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
        rt.memory = account;
        rt.owns_self_allocation = owns_self_allocation;
        // MemoryAccount's std.mem.Allocator facade stores a pointer to the
        // account, so bind it only after the account reaches this stable field
        // address. All runtime `.allocator` / `.persistent_allocator` users now
        // participate in the same limit and live-byte accounting.
        rt.memory.activateRuntimeAccounting();
        rt.memory.trigger_gc_fn = null;
        rt.memory.trigger_gc_ctx = null;
        rt.memory.setLimit(options.memory_limit);
        rt.gc = gc.Registry.init(&rt.memory, options.gc_policy);
        rt.atoms = atom.AtomTable.init(&rt.memory);
        rt.atoms.runtime = rt;
        try rt.classes.initInPlace(&rt.memory, &rt.atoms);
        errdefer {
            rt.classes.deinit();
        }
        rt.shapes = shape.Registry.init(rt, &rt.memory, &rt.atoms, &rt.gc);
        rt.modules = module.Registry.init(&rt.memory, &rt.atoms);
        rt.auto_init_table = .empty;
        rt.materialize_builtin_namespace_cb = null;
        rt.materialize_context_global_cb = null;
        rt.install_standard_globals_cb = default_standard_globals_installer;
        rt.standard_global_own_property_capacity = default_standard_global_own_property_capacity;
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
        rt.pending_finalization_jobs = &.{};
        rt.pending_finalization_jobs_capacity = 0;
        rt.job_queue = job_mod.Queue.init(&rt.memory);
        rt.deferred_native_cleanups = &.{};
        rt.deferred_native_cleanups_capacity = 0;
        rt.draining_deferred_native_cleanups = false;
        rt.deferred_native_cleanup_run_count = 0;
        rt.deferred_class_payload_finalizers = &.{};
        rt.deferred_class_payload_finalizers_capacity = 0;
        rt.reserved_deferred_class_payload_finalizer_slots = 0;
        rt.draining_deferred_class_payload_finalizers = false;
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
        rt.next_job_sequence = 0;
        rt.malloc_gc_threshold = options.gc_threshold;
        rt.gc_running = false;
        rt.current_exception = JSValue.uninitialized();
        rt.stack_size = options.stack_size;
        rt.native_stack_size = initial_native_stack_size;
        // Arm the native recursion guard at construction, mirroring QuickJS
        // JS_NewRuntime2 -> JS_UpdateStackTop (quickjs.c:2116). This covers every
        // entry path (eval / evalScript / ES module graph) even those that do not
        // re-arm; the host creates the runtime and starts execution from the same
        // shallow call level, so this baseline is valid. Outermost eval/module
        // entries additionally re-arm (JS_UpdateStackTop analogue) for a precise
        // per-thread base — required when execution runs on a different thread
        // than construction (conformance worker runtimes).
        rt.native_stack_top = @frameAddress();
        rt.native_stack_limit = if (initial_native_stack_size == 0) 0 else rt.native_stack_top -| initial_native_stack_size;
        rt.vm_stack = .{};
        rt.interrupt_handler = options.interrupt_handler;
        rt.interrupt_context = options.interrupt_context;
        rt.can_block = options.can_block;
        // Seed the Math.random xorshift state from wall-clock microseconds,
        // mirroring qjs js_random_init (quickjs.c:47373); the state must be
        // non-zero or xorshift64star degenerates to all-zeros.
        rt.random_state = randomSeedMicros();
        if (rt.random_state == 0) rt.random_state = 1;
        rt.single_byte_strings = @splat(null);
        rt.empty_string = null;
        rt.recent_two_unit_string = null;
        rt.recent_atom_strings = @splat(null);
        rt.recent_atom_string_next = 0;
        rt.percent_hex_strings = @splat(null);
        rt.small_int_strings = @splat(null);
        rt.internal_destructuring_helpers = @splat(null);
        rt.preallocated_oom_error = null;
        rt.performance_time_origin_ms = 0;
        rt.opcode_profile = null;
        rt.external_host_functions = &.{};
        rt.external_host_functions_capacity = 0;
        rt.cached_iterator_next_entries = &.{};
        rt.cached_iterator_next_entries_capacity = 0;
        rt.internal_builtins = &.{};
        rt.any_prototype_may_have_indexed_properties = false;
        rt.memory.profile_alloc_count = null;
        rt.memory.enableSmallObjectSlab();
        rt.memory.trigger_gc_fn = JSRuntime.triggerGCOnAllocation;
        rt.memory.trigger_gc_ctx = rt;
    }

    pub fn setOpcodeProfile(self: *JSRuntime, opcode_profile: ?*profile.OpcodeProfile) void {
        self.opcode_profile = opcode_profile;
        self.memory.profile_alloc_count = if (opcode_profile) |prof| &prof.alloc_count else null;
    }

    pub fn deinit(self: *JSRuntime) void {
        self.vm_stack.deinit(&self.memory);
        const current_exception = self.current_exception;
        self.current_exception = JSValue.uninitialized();
        current_exception.free(self);
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
        self.recent_atom_string_next = 0;
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
        for (&self.internal_destructuring_helpers) |*slot| {
            const cached = slot.*;
            slot.* = null;
            if (cached) |stored| stored.free(self);
        }
        if (self.preallocated_oom_error) |stored| {
            self.preallocated_oom_error = null;
            stored.free(self);
        }
        self.clearExternalHostFunctions();
        self.drainDeferredNativeCleanups();
        self.clearLocalRootSlots();
        self.clearPersistentRootSlots();
        self.clearWeakRootSlots(false);
        self.drainDeferredNativeCleanups();
        self.drainDeferredClassPayloadFinalizers();
        self.modules.deinit(self);
        _ = self.runObjectCycleRemoval();
        self.drainDeferredWeakValueFrees();
        self.drainDeferredNativeCleanups();
        self.drainDeferredClassPayloadFinalizers();
        self.clearPendingFinalizationJobs();
        Object.releaseCallbackOwnedFunctionBytecodeCycles(self);
        _ = self.runObjectCycleRemoval();
        self.drainDeferredWeakValueFrees();
        self.drainDeferredNativeCleanups();
        self.drainDeferredClassPayloadFinalizers();
        self.clearBorrowedWeakCleanupIdentities();
        self.clearPendingFinalizationJobs();
        // Ordinary atom-string caches own an independent string ref and can be
        // released now. Dynamic symbol bodies cannot: their rc also represents
        // property-key atoms held by shapes, which intentionally outlive objects
        // until phase 3 of gc.deinit.
        self.atoms.releaseCachedStrings(self);
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
        self.auto_init_table.deinit(self.memory.persistent_allocator);
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
        self.reserved_deferred_class_payload_finalizer_slots = 0;
        if (borrowed_reference_holders.len != 0) self.memory.free(*Object, borrowed_reference_holders);
        if (root_providers.len != 0) self.memory.free(RootProvider, root_providers);
        if (local_root_slots.len != 0) self.memory.free(*RootSlot, local_root_slots);
        if (persistent_root_slots.len != 0) self.memory.free(*RootSlot, persistent_root_slots);
        if (weak_root_slots.len != 0) self.memory.free(*WeakRootSlot, weak_root_slots);
        if (external_host_functions.len != 0) self.memory.free(host_function.ExternalRecord, external_host_functions);
        if (cached_iterator_next_entries.len != 0) self.memory.free(CachedIteratorNextEntry, cached_iterator_next_entries);
        if (deferred_native_cleanups.len != 0) self.memory.free(NativeCleanupJob, deferred_native_cleanups);
        if (deferred_class_payload_finalizers.len != 0) self.memory.free(DeferredClassPayloadFinalizer, deferred_class_payload_finalizers);
        self.memory.deinitSmallObjectSlab();
        if (self.owns_self_allocation) {
            std.debug.assert(self.memory.allocation_count == 1);
            std.debug.assert(self.memory.allocated_bytes == @sizeOf(JSRuntime));
        } else {
            std.debug.assert(!self.memory.hasOutstandingAllocations());
        }
    }

    pub fn destroy(self: *JSRuntime) void {
        self.deinit();
        var account = self.memory;
        account.destroy(JSRuntime, self);
        std.debug.assert(!account.hasOutstandingAllocations());
    }

    pub inline fn allocRuntime(self: *JSRuntime, comptime T: type, count: usize) ![]T {
        if (count != 0) {
            const bytes = std.math.mul(usize, @sizeOf(T), count) catch std.math.maxInt(usize);
            self.requestGCForAllocation(bytes);
        }
        return self.memory.allocNoTrigger(T, count);
    }

    pub inline fn freeRuntime(self: *JSRuntime, comptime T: type, slice: []T) void {
        self.memory.free(T, slice);
    }

    pub inline fn remapRuntime(self: *JSRuntime, comptime T: type, slice: []T, new_count: usize) !?[]T {
        if (new_count > slice.len) {
            const old_bytes = std.math.mul(usize, @sizeOf(T), slice.len) catch std.math.maxInt(usize);
            const new_bytes = std.math.mul(usize, @sizeOf(T), new_count) catch std.math.maxInt(usize);
            self.requestGCForAllocation(new_bytes -| old_bytes);
        }
        return self.memory.remap(T, slice, new_count);
    }

    pub inline fn createRuntime(self: *JSRuntime, comptime T: type) !*T {
        self.requestGCForAllocation(@sizeOf(T));
        return self.memory.createNoTrigger(T);
    }

    pub inline fn destroyRuntime(self: *JSRuntime, comptime T: type, ptr: *T) void {
        self.memory.destroy(T, ptr);
    }

    pub inline fn allocRuntimeAlignedBytes(self: *JSRuntime, byte_count: usize, alignment: std.mem.Alignment) ![]u8 {
        if (byte_count != 0) self.requestGCForAllocation(byte_count);
        return self.memory.allocAlignedBytesNoTrigger(byte_count, alignment);
    }

    /// QJS runs its allocation-threshold GC trigger from object creation, not
    /// from JSString/JSStringRope allocation. Production string churn therefore
    /// bypasses the per-allocation threshold bookkeeping. Test builds must keep
    /// the injected allocation callback, and force-GC builds must still collect
    /// before every runtime allocation, so those comptime modes retain the full
    /// request path.
    pub inline fn allocStringAlignedBytes(self: *JSRuntime, byte_count: usize, alignment: std.mem.Alignment) ![]u8 {
        if (comptime builtin.is_test or memory.force_gc_on_allocation_enabled) {
            if (byte_count != 0) self.requestGCForAllocation(byte_count);
        }
        return self.memory.allocAlignedBytesNoTrigger(byte_count, alignment);
    }

    pub inline fn freeRuntimeAlignedBytes(self: *JSRuntime, bytes: []u8, alignment: std.mem.Alignment) void {
        self.memory.freeAlignedBytes(bytes, alignment);
    }

    pub fn registerObject(self: *JSRuntime, object: *Object) !void {
        // qjs add_gc_object (quickjs.c:6540) only links the header into
        // gc_obj_list; it never re-evaluates the GC threshold. The single
        // object-creation threshold check is js_trigger_gc(sizeof(JSObject))
        // at the top of JS_NewObjectFromShape (quickjs.c:5619) — mirrored here
        // by createInternal's collectBeforeObjectAllocation immediately before
        // the object body allocation. Property arrays and separate payloads
        // retain their existing allocRuntime* requests. By the time we link,
        // those sub-allocations have observed the final allocated_bytes and set
        // major_request.pending iff over threshold, so re-loading allocated_bytes
        // here is pure redundant work. Keep addWithSize (the faithful
        // add_gc_object) and only service an already-pending request.
        try self.registerObjectWithBytes(object, object.allocationSize(self));
    }

    /// Same as `registerObject` but with the object's allocation size supplied by
    /// the caller. `createInternal` already computes the inline-class-payload
    /// layout to size/place the allocation; reusing its `object_size` here avoids a
    /// second record-table lookup + inline-layout recompute on the object-creation
    /// hot path (mirror of `unregisterObjectWithBytes` on the free path). The
    /// stored value is identical to what `allocationSize` would recompute.
    pub fn registerObjectWithBytes(self: *JSRuntime, object: *Object, bytes: usize) !void {
        try self.gc.addInitializedWithSize(&object.header, bytes);
        if (self.gc.hasPendingMajorRequest()) {
            _ = self.pollGC(null, .normal) catch {};
        }
    }

    pub fn unregisterObject(self: *JSRuntime, object: *Object) void {
        self.unregisterObjectWithBytes(object, object.allocationSize(self));
    }

    /// Same as `unregisterObject` but with the object's allocation size supplied
    /// by the caller. `destroyFromHeader` already computes the inline-class-payload
    /// layout (for the tail `freeObjectAllocation`); its `object_size` is bit-for-bit
    /// the value `allocationSize` would recompute here (both go through
    /// `inlineClassPayloadLayout(recordPtr(class_id))`, and `class_id` is unchanged
    /// between the two calls). Reusing it drops a redundant record-table lookup +
    /// 88-byte-stride multiply + inline-layout recompute off the hot free path —
    /// qjs `free_object` (quickjs.c:6340) never recomputes an object's size at
    /// teardown either (the slab block carries it).
    pub fn unregisterObjectWithBytes(self: *JSRuntime, object: *Object, bytes: usize) void {
        self.unregisterWeakReferenceHolder(object);
        self.unregisterBorrowedReferenceHolder(object);
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

    pub fn registerRootProvider(self: *JSRuntime, provider: RootProvider) !void {
        for (self.root_providers) |registered| {
            if (registered.context == provider.context and registered.trace == provider.trace) return;
        }
        try self.appendRootProvider(provider);
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
        for (&self.internal_destructuring_helpers) |*maybe_helper| {
            try visitor.optionalValue(maybe_helper);
        }
        try visitor.optionalValue(&self.preallocated_oom_error);
        for (self.local_root_slots) |slot| {
            try visitor.value(&slot.value);
        }
        for (self.persistent_root_slots) |slot| {
            try visitor.value(&slot.value);
        }
        for (self.pending_finalization_jobs) |*job| {
            try job.traceRoots(visitor);
        }
        for (self.deferred_class_payload_finalizers) |*job| {
            try job.traceRoots(self, visitor);
        }
        for (self.deferred_weak_value_frees) |*item| {
            try visitor.value(&item.value);
        }
        try self.job_queue.traceRoots(visitor);
        for (self.root_providers) |provider| {
            try provider.trace(provider.context, visitor);
        }
    }

    pub fn traceActiveRoots(self: *JSRuntime, visitor: *RootVisitor) RootTraceError!void {
        try self.traceRoots(null, visitor);
    }

    fn traceValueRootFrames(self: *JSRuntime, roots: ?*const ValueRootFrame, visitor: *RootVisitor) RootTraceError!void {
        _ = self;
        var frame = roots;
        while (frame) |current| {
            for (current.objects) |root| {
                try visitor.optionalObject(root.object);
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

    pub fn clearPersistentRootSlots(self: *JSRuntime) void {
        const slots = self.persistent_root_slots;
        const capacity = self.persistent_root_slots_capacity;
        self.persistent_root_slots = &.{};
        self.persistent_root_slots_capacity = 0;

        for (slots) |slot| {
            const value = slot.value;
            slot.value = JSValue.undefinedValue();
            value.free(self);
            self.memory.destroy(RootSlot, slot);
        }
        if (capacity != 0) self.memory.free(*RootSlot, slots.ptr[0..capacity]);
    }

    fn clearWeakRootSlots(self: *JSRuntime, notify: bool) void {
        const slots = self.weak_root_slots;
        const capacity = self.weak_root_slots_capacity;
        self.weak_root_slots = &.{};
        self.weak_root_slots_capacity = 0;

        for (slots) |slot| {
            self.clearWeakRootSlot(slot, notify);
            self.memory.destroy(WeakRootSlot, slot);
        }
        if (capacity != 0) self.memory.free(*WeakRootSlot, slots.ptr[0..capacity]);
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

    pub fn retainWeakIdentity(self: *JSRuntime, identity: usize) void {
        if ((identity & 1) == 0) {
            const object = self.objectFromWeakIdentity(identity) orelse return;
            std.debug.assert(object.header.meta().rc > 0);
            object.weakref_count += 1;
            return;
        }
        const atom_id = identity >> 1;
        if (atom_id > std.math.maxInt(atom.Atom)) return;
        self.atoms.retainSymbolWeakRef(@intCast(atom_id));
    }

    pub fn releaseWeakIdentity(self: *JSRuntime, identity: usize) void {
        if ((identity & 1) == 0) {
            const object = self.objectFromWeakIdentity(identity) orelse return;
            std.debug.assert(object.weakref_count > 0);
            object.weakref_count -= 1;
            if (object.weakref_count == 0 and object.header.meta().rc == 0 and !object.header.meta().flags.mark) {
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
        if (object.header.meta().rc == 0) return null;
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
        if (object.header.meta().flags.has_weak_id) {
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
        object.header.meta().flags.has_weak_id = true;
        return weak_id << 1;
    }

    /// Returns the encoded weak identity for `object` without registering one.
    pub fn peekWeakObjectIdentity(self: *const JSRuntime, object: *const Object) ?usize {
        if (!object.header.metaConst().flags.has_weak_id) return null;
        const address = @intFromPtr(&object.header) & ~@as(usize, 1);
        const weak_id = self.weak_object_ids.get(address) orelse return null;
        return weak_id << 1;
    }

    /// Removes `object` from the weak identity registry, returning its encoded
    /// weak identity (if any) so destruction can propagate it to weak slots.
    pub fn takeWeakObjectIdentity(self: *JSRuntime, object: *Object) ?usize {
        if (!object.header.meta().flags.has_weak_id) return null;
        object.header.meta().flags.has_weak_id = false;
        const address = @intFromPtr(&object.header) & ~@as(usize, 1);
        const weak_id = self.weak_object_ids.get(address) orelse return null;
        _ = self.weak_object_ids.remove(address);
        _ = self.weak_id_objects.remove(weak_id);
        return weak_id << 1;
    }

    fn clearLocalRootSlots(self: *JSRuntime) void {
        self.clearLocalRootSlotsFrom(0);
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

    pub fn registerExternalSymbolRoot(self: *JSRuntime, atom_id: atom.Atom) !void {
        _ = self;
        _ = atom_id;
    }

    /// Compatibility shim for host records that used to participate in zjs's
    /// symbol-root scan. S2 made symbol values refcounted, so the stored
    /// JSValue itself now owns any symbol body it needs.
    pub fn registerExternalValueSymbolRoot(self: *JSRuntime, value: JSValue) !bool {
        _ = self;
        _ = value;
        return false;
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

    pub fn unregisterExternalSymbolRoot(self: *JSRuntime, atom_id: atom.Atom) void {
        _ = self;
        _ = atom_id;
    }

    pub fn unregisterExternalValueSymbolRoot(self: *JSRuntime, value: JSValue) void {
        _ = self;
        _ = value;
    }

    pub fn registerExternalHostFunction(self: *JSRuntime, record: host_function.ExternalRecord) !u32 {
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
        const records = self.internal_builtins[domain_index];
        if (id >= records.len) return null;
        const record = &records[id];
        if (!record.hasCallable()) return null;
        return record;
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
        return self.runObjectCycleRemovalWithValueRoots(null);
    }

    pub fn runObjectCycleRemovalWithValueRoots(self: *JSRuntime, roots: ?*const ValueRootFrame) usize {
        const result = self.tryRunObjectCycleRemovalWithValueRoots(roots) catch return 0;
        return result.freed_objects;
    }

    pub fn tryRunObjectCycleRemoval(self: *JSRuntime) gc.CollectionError!gc.CollectionResult {
        return self.tryRunObjectCycleRemovalWithValueRoots(null);
    }

    pub fn tryRunObjectCycleRemovalWithValueRoots(
        self: *JSRuntime,
        roots: ?*const ValueRootFrame,
    ) gc.CollectionError!gc.CollectionResult {
        if (self.gc_running) return .{};
        if (builtin.mode == .Debug) self.gc.verifyIntrusiveList() catch unreachable;
        if (builtin.mode == .Debug) self.gc.verifyHeapAccounting(self) catch unreachable;
        defer if (builtin.mode == .Debug) {
            self.gc.verifyIntrusiveList() catch unreachable;
            self.gc.verifyHeapAccounting(self) catch unreachable;
        };
        self.gc_running = true;
        defer self.gc_running = false;

        const start_ns = profile.nowNanos();
        self.gc.beginMajorCycle(self.gc.activeMajorReason() orelse .manual, start_ns);
        self.gc.setMajorPhase(.mark_incremental);
        const freed = Object.destroyRuntimeCyclesWithValueRoots(self, roots) catch |err| {
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

        const result = gc.CollectionResult{
            .freed_objects = freed,
            .duration_ns = blk: {
                const end_ns = profile.nowNanos();
                break :blk if (end_ns > start_ns) end_ns - start_ns else 0;
            },
        };
        self.gc.recordSuccess(result);
        self.gc.finishMajorCycle(result);
        self.resetGCThreshold();
        return result;
    }

    pub fn pollGC(
        self: *JSRuntime,
        roots: ?*const ValueRootFrame,
        mode: GCPollMode,
    ) gc.CollectionError!gc.CollectionResult {
        _ = roots;
        if (self.gc_running) return .{};
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
        const over_threshold = self.memory.allocated_bytes > self.malloc_gc_threshold;
        const run_major = self.gc.shouldRunMajorAt(scheduler_point, over_threshold);
        if (!run_major) return .{};

        const major_request = self.gc.pendingMajorRequest();
        if (major_request != null) _ = self.gc.clearMajorRequest();
        const reason = if (major_request) |request|
            request.reason orelse gc.RequestReason.manual
        else if (over_threshold)
            gc.RequestReason.allocation_threshold
        else
            gc.RequestReason.manual;
        self.gc.beginMajorCycle(reason, profile.nowNanos());
        return try self.tryRunObjectCycleRemovalWithValueRoots(null);
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
        self.gc.requestGC(.manual, .urgent);
        return self.pollGC(roots, .urgent);
    }

    pub fn forceMajorGC(self: *JSRuntime, roots: ?*const ValueRootFrame) gc.CollectionError!gc.CollectionResult {
        return self.forceGC(roots);
    }

    pub fn requestGCForTest(self: *JSRuntime) void {
        if (!builtin.is_test) @compileError("test-only helper");
        self.gc.requestGC(.manual, .soon);
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
        self.malloc_gc_threshold = threshold;
    }

    pub fn gcThreshold(self: JSRuntime) usize {
        return self.malloc_gc_threshold;
    }

    pub fn setMemoryLimit(self: *JSRuntime, limit: ?usize) void {
        self.memory.setLimit(limit);
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

        const object_count = self.gc.liveCount();
        const shape_count = self.shapes.live_shape_count;
        const module_count = self.modules.modules.len;
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

    pub fn reportExternalAllocUntracked(self: *JSRuntime, bytes: usize) void {
        self.gc.reportExternalAllocUntracked(bytes);
    }

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
        return self.gc.stats.allocation_debt;
    }

    /// Interned-once shared descriptor for the lazy `function.prototype`
    /// auto-init placeholder. Created on first use and cached on the runtime.
    pub fn functionPrototypeAutoInitRef(self: *JSRuntime) !property.AutoInitRef {
        if (self.function_prototype_auto_init) |ref| return ref;
        const ref = try property.internAutoInit(self, .{
            .name = "",
            .length = 0,
            .rt = self,
            .kind = .function_prototype,
        });
        self.function_prototype_auto_init = ref;
        return ref;
    }

    pub fn gcStats(self: JSRuntime) gc.Stats {
        var stats = self.gc.statsSnapshot(&self);
        stats.weak_ref_count = self.weakReferenceCount();
        stats.finalizer_queue_length = self.pending_finalization_jobs.len;
        stats.pending_finalization_job_count = self.pending_finalization_jobs.len;
        stats.deferred_native_cleanup_count = self.deferred_native_cleanups.len;
        stats.deferred_native_cleanup_run_count = self.deferred_native_cleanup_run_count;
        stats.deferred_class_payload_finalizer_count = self.deferred_class_payload_finalizers.len;
        stats.deferred_class_payload_finalizer_run_count = self.deferred_class_payload_finalizer_run_count;
        stats.rss_bytes = currentRssBytes();
        stats.cgroup_limit_bytes = cgroupLimitBytes();
        return stats;
    }

    pub fn ownsObject(self: JSRuntime, object: *const Object) bool {
        return self.gc.containsHeader(&object.header);
    }

    fn requestGCForProcessMemoryPressure(self: *JSRuntime) void {
        const rss_bytes = currentRssBytes();
        const cgroup_limit_bytes = cgroupLimitBytes();
        if (self.gc.processMemoryRequest(rss_bytes, cgroup_limit_bytes)) |request| {
            if (request.urgency == .urgent) self.gc.decommitEmptyPagesNow();
            self.gc.requestGC(request.reason, request.urgency);
        }
    }

    fn weakReferenceCount(self: JSRuntime) usize {
        var count: usize = 0;
        for (self.weak_root_slots) |slot| {
            if (slot.identity != null) count += 1;
        }
        var gc_iter = self.gc.objectIterator();
        while (gc_iter.next()) |header| {
            if (header.meta().kind == .object) {
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
        if (comptime memory.force_gc_on_allocation_enabled) {
            if (self.memory.trigger_gc_fn == null) return;
            if (self.gc_running) return;
            // The force-GC build option is diagnostic instrumentation, not a
            // scheduling-policy change. Preserve an explicitly configured
            // threshold across the synthetic pre-allocation collection.
            const saved_threshold = self.malloc_gc_threshold;
            defer self.malloc_gc_threshold = saved_threshold;
            _ = self.forceGC(null) catch {};
            return;
        }
        if (self.gc_running) return;
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
        self.requestGCForAllocation(size);
        if (self.gc_running or !self.gc.hasPendingMajorRequest()) return;
        _ = self.pollGC(null, .normal) catch {};
    }

    fn triggerGCOnAllocation(ctx: ?*anyopaque, size: usize) void {
        const self: *JSRuntime = @ptrCast(@alignCast(ctx));
        self.requestGCForAllocation(size);
    }

    fn resetGCThreshold(self: *JSRuntime) void {
        self.malloc_gc_threshold = std.math.add(usize, self.memory.allocated_bytes, self.memory.allocated_bytes >> 1) catch std.math.maxInt(usize);
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
        const slot_index = self.recent_atom_string_next % self.recent_atom_strings.len;
        const old = self.recent_atom_strings[slot_index];
        self.recent_atom_strings[slot_index] = .{
            .atom_id = atom_id,
            .string = created,
        };
        self.recent_atom_string_next = (slot_index + 1) % self.recent_atom_strings.len;
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
        self.stack_size = size;
    }

    pub fn stackSize(self: JSRuntime) usize {
        return self.stack_size;
    }

    pub fn setNativeStackSize(self: *JSRuntime, size: usize) void {
        self.native_stack_size = size;
        self.updateNativeStackTop();
    }

    /// Capture the current native frame pointer as the recursion base and derive
    /// the lower limit. Mirrors QuickJS `JS_UpdateStackTop` + `update_stack_limit`
    /// (quickjs.c:2841-2860). Must be called at the outermost JS entry on the
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
    /// (quickjs.c:2059-2064): `sp = frame_address - alloca_size; sp < limit`.
    /// Stack grows down, so "below the limit" is overflow. Returns false when the
    /// limit is unset (0), matching the no-limit build.
    pub inline fn checkNativeStackOverflow(self: *const JSRuntime, alloca_size: usize) bool {
        if (self.native_stack_limit == 0) return false;
        const sp = @frameAddress() -| alloca_size;
        return sp < self.native_stack_limit;
    }

    pub fn internAtom(self: *JSRuntime, bytes: []const u8) !atom.Atom {
        return self.atoms.internString(bytes);
    }

    pub fn newClassId(self: *JSRuntime, requested: class.ClassId) class.ClassId {
        return self.classes.newClassId(requested);
    }

    pub fn setInterruptHandler(self: *JSRuntime, handler: ?*const fn (*JSRuntime, ?*anyopaque) bool, context: ?*anyopaque) void {
        self.interrupt_handler = handler;
        self.interrupt_context = context;
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
    /// narrow the result back to the engine-wide `DynamicImportError` set so the
    /// bounded-error callers of `installHostGlobals`/`contextGlobal` (notably the
    /// `DynamicImportCallback` host hook) keep a concrete error set.
    pub fn installStandardGlobals(self: *JSRuntime, global: *Object) context_mod.DynamicImportError!void {
        const installer = self.install_standard_globals_cb orelse return error.InvalidBuiltinRegistry;
        installer(self, global) catch |err| return @errorCast(err);
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

    pub fn nextJobSequence(self: *JSRuntime) u64 {
        const sequence = self.next_job_sequence;
        self.next_job_sequence +%= 1;
        return sequence;
    }

    pub fn enqueueFinalizationJob(self: *JSRuntime, callback: JSValue, held_value: JSValue) !void {
        const index = self.pending_finalization_jobs.len;
        try self.ensurePendingFinalizationJobCapacity(index + 1);
        var job = try FinalizationJob.init(self, self.nextJobSequence(), callback, held_value);
        errdefer job.deinit(self);
        self.pending_finalization_jobs = self.pending_finalization_jobs.ptr[0 .. index + 1];
        self.pending_finalization_jobs[index] = job;
    }

    pub fn peekPendingFinalizationJobSequence(self: JSRuntime) ?u64 {
        if (self.pending_finalization_jobs.len == 0) return null;
        return self.pending_finalization_jobs[0].sequence;
    }

    pub fn takePendingFinalizationJob(self: *JSRuntime) ?FinalizationJob {
        if (self.pending_finalization_jobs.len == 0) return null;
        const job = self.pending_finalization_jobs[0];
        const old_len = self.pending_finalization_jobs.len;
        if (old_len == 1) {
            const old_jobs = self.pending_finalization_jobs.ptr[0..self.pending_finalization_jobs_capacity];
            self.pending_finalization_jobs = &.{};
            self.pending_finalization_jobs_capacity = 0;
            self.memory.free(FinalizationJob, old_jobs);
            return job;
        }
        @memmove(self.pending_finalization_jobs[0 .. old_len - 1], self.pending_finalization_jobs[1..old_len]);
        self.pending_finalization_jobs = self.pending_finalization_jobs.ptr[0 .. old_len - 1];
        return job;
    }

    pub fn clearPendingFinalizationJobs(self: *JSRuntime) void {
        const jobs = self.pending_finalization_jobs;
        const capacity = self.pending_finalization_jobs_capacity;
        self.pending_finalization_jobs = &.{};
        self.pending_finalization_jobs_capacity = 0;
        for (jobs) |job| job.deinit(self);
        if (capacity != 0) {
            self.memory.free(FinalizationJob, jobs.ptr[0..capacity]);
        }
    }

    pub fn pendingFinalizationJobCountForTest(self: JSRuntime) usize {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.pending_finalization_jobs.len;
    }

    fn ensurePendingFinalizationJobCapacity(self: *JSRuntime, min_capacity: usize) !void {
        if (self.pending_finalization_jobs_capacity >= min_capacity) return;
        var next_capacity = if (self.pending_finalization_jobs_capacity == 0) @as(usize, 4) else self.pending_finalization_jobs_capacity * 2;
        while (next_capacity < min_capacity) : (next_capacity *= 2) {}
        const next = try self.memory.alloc(FinalizationJob, next_capacity);
        errdefer self.memory.free(FinalizationJob, next);
        const old_jobs = self.pending_finalization_jobs;
        const old_capacity = self.pending_finalization_jobs_capacity;
        @memcpy(next[0..old_jobs.len], old_jobs);
        self.pending_finalization_jobs = next[0..old_jobs.len];
        self.pending_finalization_jobs_capacity = next_capacity;
        if (old_capacity != 0) {
            self.memory.free(FinalizationJob, old_jobs.ptr[0..old_capacity]);
        }
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
        const record = self.classes.record(class_id) orelse return false;
        const finalizer = record.payload_finalizer orelse return false;
        const index = self.deferred_class_payload_finalizers.len;
        try self.ensureDeferredClassPayloadFinalizerCapacity(index + self.reserved_deferred_class_payload_finalizer_slots + 1);
        self.deferred_class_payload_finalizers = self.deferred_class_payload_finalizers.ptr[0 .. index + 1];
        self.deferred_class_payload_finalizers[index] = .{
            .class_id = class_id,
            .finalizer = finalizer,
            .payload = payload,
            .payload_kind = payload_kind,
            .object_identity = object_identity,
        };
        return true;
    }

    pub fn reserveDeferredClassPayloadFinalizerSlot(self: *JSRuntime) !void {
        try self.ensureDeferredClassPayloadFinalizerCapacity(self.deferred_class_payload_finalizers.len + self.reserved_deferred_class_payload_finalizer_slots + 1);
        self.reserved_deferred_class_payload_finalizer_slots +|= 1;
    }

    pub fn releaseDeferredClassPayloadFinalizerSlot(self: *JSRuntime) void {
        std.debug.assert(self.reserved_deferred_class_payload_finalizer_slots != 0);
        self.reserved_deferred_class_payload_finalizer_slots -= 1;
        self.releaseEmptyDeferredClassPayloadFinalizerBuffer();
    }

    pub fn enqueueReservedDeferredClassPayloadFinalizer(self: *JSRuntime, class_id: class.ClassId, payload: class.Payload, payload_kind: class.PayloadKind, object_identity: usize) bool {
        std.debug.assert(self.reserved_deferred_class_payload_finalizer_slots != 0);
        self.reserved_deferred_class_payload_finalizer_slots -= 1;

        const record = self.classes.record(class_id) orelse {
            self.releaseEmptyDeferredClassPayloadFinalizerBuffer();
            return false;
        };
        const finalizer = record.payload_finalizer orelse {
            self.releaseEmptyDeferredClassPayloadFinalizerBuffer();
            return false;
        };
        const index = self.deferred_class_payload_finalizers.len;
        std.debug.assert(index + 1 <= self.deferred_class_payload_finalizers_capacity);
        self.deferred_class_payload_finalizers = self.deferred_class_payload_finalizers.ptr[0 .. index + 1];
        self.deferred_class_payload_finalizers[index] = .{
            .class_id = class_id,
            .finalizer = finalizer,
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
        return self.deferred_class_payload_finalizers.len != 0;
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
            job.run(self);
            self.deferred_class_payload_finalizer_run_count +|= 1;
        }

        self.releaseEmptyDeferredClassPayloadFinalizerBuffer();
        if (ran != 0 and self.deferred_class_payload_finalizers.len == 0) object_mod.Object.drainCycleDeferredFrees(self);
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
                if (header.meta().rc == 0) {
                    const already_consumed_prepared_object =
                        header.meta().kind == .object and
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
        if (!self.borrowed_weak_cleanup_active) return null;
        const object = objectFromLastRefValue(value) orelse return null;
        const identity = @intFromPtr(&object.header) & ~@as(usize, 1);
        const weak_identity = self.peekWeakObjectIdentity(object);
        if (!object.isGlobal() and weak_identity == null) return identity;
        if (self.borrowed_weak_cleanup_seen_holder) self.markBorrowedWeakCleanupNeedsRescan();
        if (object.isGlobal()) {
            self.enqueueBorrowedWeakCleanupRealmIdentity(identity);
            self.enqueueBorrowedWeakCleanupIdentity(identity) catch return null;
        }
        if (weak_identity) |stored_weak_identity| {
            self.enqueueBorrowedWeakCleanupIdentity(stored_weak_identity) catch return null;
        }
        return identity;
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

fn objectFromLastRefValue(value: JSValue) ?*Object {
    const header = value.refHeader() orelse return null;
    if (header.meta().kind != .object) return null;
    if (header.meta().rc != 1) return null;
    return @alignCast(@fieldParentPtr("header", header));
}

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

test "value handle uses runtime persistent root slot" {
    var rt: JSRuntime = undefined;
    try rt.init(std.testing.allocator, .{});
    defer rt.deinit();

    const object = try Object.create(&rt, class.ids.object, null);
    var handle = try rt.takeValueHandle(object.value());
    try std.testing.expectEqual(@as(usize, 1), rt.persistentRootCountForTest());
    try std.testing.expect(handle.get().isObject());

    const released = handle.release();
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
        try std.testing.expect(rt.gcStats().major_slice_count >= 1);
    } else {
        try std.testing.expectEqual(@as(usize, 1), rt.gcStats().major_gc_count);
        try std.testing.expectEqual(@as(usize, 1), rt.gcStats().major_slice_count);
    }
    try std.testing.expect(!rt.gcPendingForTest());
}

/// Wall-clock microseconds for the Math.random seed (qjs js_random_init,
/// quickjs.c:47373, gettimeofday-based). Falls back to 1 on clock failure.
fn randomSeedMicros() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 1;
    const micros = @as(i128, ts.sec) * std.time.us_per_s + @divTrunc(@as(i128, ts.nsec), std.time.ns_per_us);
    return @truncate(@as(u128, @bitCast(micros)));
}
