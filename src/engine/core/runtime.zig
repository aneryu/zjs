const std = @import("std");
const builtin = @import("builtin");

const memory = @import("memory.zig");
const atom = @import("atom.zig");
const class = @import("class.zig");
const gc = @import("gc.zig");
const host_function = @import("host_function.zig");
const job_mod = @import("../exec/jobs.zig");
const bytecode_function = @import("../bytecode/function.zig");
const module = @import("module.zig");
const object_mod = @import("object.zig");
const shape = @import("shape.zig");
const string = @import("string.zig");
const JSValue = @import("value.zig").JSValue;
const Object = object_mod.Object;
const profile = @import("profile.zig");

pub const default_stack_size = 1024 * 1024;
pub const default_gc_threshold = 256 * 1024;

pub const InterruptHandler = *const fn (*JSRuntime, ?*anyopaque) bool;

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

pub const GCPollMode = enum {
    normal,
    callback_boundary,
    idle,
    urgent,
};

pub const ValueRootSlice = union(enum) {
    mutable: *const []JSValue,
};

pub const ValueRootBuffer = struct {
    values: []JSValue = &.{},

    pub fn initCopy(rt: *JSRuntime, source: []const JSValue) !ValueRootBuffer {
        if (source.len == 0) return .{};

        const saved_trigger_fn = rt.memory.trigger_gc_fn;
        const saved_trigger_ctx = rt.memory.trigger_gc_ctx;
        rt.memory.trigger_gc_fn = null;
        rt.memory.trigger_gc_ctx = null;
        defer {
            rt.memory.trigger_gc_fn = saved_trigger_fn;
            rt.memory.trigger_gc_ctx = saved_trigger_ctx;
        }

        const values = try rt.memory.alloc(JSValue, source.len);
        @memcpy(values, source);
        return .{ .values = values };
    }

    pub fn deinit(self: *ValueRootBuffer, rt: *JSRuntime) void {
        const values = self.values;
        self.values = &.{};
        if (values.len != 0) rt.memory.free(JSValue, values);
    }

    pub fn slice(self: *ValueRootBuffer) ValueRootSlice {
        return .{ .mutable = &self.values };
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

pub const DeferredWeakValueFree = struct {
    value: JSValue,
    prequeued_identity: ?usize = null,
};

pub const NativeCleanupJob = struct {
    finalizer: host_function.ExternalFinalizer,
    ptr: *anyopaque,

    pub fn run(self: NativeCleanupJob) void {
        self.finalizer(self.ptr);
    }
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

const RegExpSimpleClassAlternationCacheEntry = struct {
    source_atom: atom.Atom = atom.null_atom,
    flags_atom: atom.Atom = atom.null_atom,
    pattern: object_mod.RegExpSimpleClassAlternationPattern = .{},
};

pub const shared_lazy_native_function_slots = 8;
pub const internal_destructuring_helper_slots = 14;

pub const JSRuntime = struct {
    pub const Options = RuntimeOptions;

    memory: memory.MemoryAccount,
    owns_self_allocation: bool = false,
    gc: gc.Registry,
    atoms: atom.AtomTable,
    classes: class.Table,
    shapes: shape.Registry,
    modules: module.Registry,

    borrowed_reference_holders: []*Object = &.{},
    borrowed_reference_holders_capacity: usize = 0,
    root_providers: []RootProvider = &.{},
    root_providers_capacity: usize = 0,
    persistent_root_slots: []*RootSlot = &.{},
    persistent_root_slots_capacity: usize = 0,
    external_symbol_roots: []atom.Atom = &.{},
    external_symbol_roots_capacity: usize = 0,
    external_value_roots: []JSValue = &.{},
    external_value_roots_capacity: usize = 0,
    active_value_roots: ?*const ValueRootFrame = null,
    pending_finalization_jobs: []FinalizationJob = &.{},
    pending_finalization_jobs_capacity: usize = 0,
    job_queue: job_mod.Queue = undefined,
    deferred_native_cleanups: []NativeCleanupJob = &.{},
    deferred_native_cleanups_capacity: usize = 0,
    draining_deferred_native_cleanups: bool = false,
    deferred_native_cleanup_run_count: usize = 0,
    deferred_weak_value_frees: []DeferredWeakValueFree = &.{},
    deferred_weak_value_frees_capacity: usize = 0,
    draining_deferred_weak_value_frees: bool = false,
    borrowed_weak_cleanup_identities: []usize = &.{},
    borrowed_weak_cleanup_identities_capacity: usize = 0,
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
    /// the test262 `decodeURI` sweep) call this thousands of times per
    /// inner iteration; reusing cached instances eliminates two heap
    /// allocations per call.
    single_byte_strings: [128]?*string.String = @splat(null),
    /// Lazy cache for the immutable empty string. This shows up during
    /// standard global setup and in common `String`/JSON paths.
    empty_string: ?*string.String = null,
    /// Single-entry cache for hot two-code-unit strings. The terminal
    /// test262 URI sweep compares `decodeURI("%F0...")` against
    /// `String.fromCharCode(H, L)` for each non-BMP code point; keeping
    /// the most recent pair lets both calls share one immutable string
    /// without retaining the whole sweep.
    recent_two_unit_string: ?RecentTwoUnitString = null,
    /// Tiny cache for atom-to-string materialization. This catches hot
    /// bytecode constants without retaining every atom string in the program;
    /// regexp literals in particular alternate between source and flags atoms.
    recent_atom_strings: [4]?RecentAtomString = @splat(null),
    recent_atom_string_next: usize = 0,
    regexp_simple_class_alternation_cache: [8]?RegExpSimpleClassAlternationCacheEntry = @splat(null),
    regexp_simple_class_alternation_cache_next: usize = 0,
    /// Lazy cache for uppercase percent-escaped byte strings (`%00`..`%FF`).
    /// This is a general URI hot-path cache, not a test fixture shortcut:
    /// ECMAScript URI helpers and the test262 decimal-to-percent harness both
    /// repeatedly construct these immutable three-byte strings.
    percent_hex_strings: [256]?*string.String = @splat(null),
    /// Lazy cache for small integer strings ("0".."255").
    small_int_strings: [256]?*string.String = @splat(null),
    /// JSRuntime-owned internal destructuring helper functions. Parser-emitted
    /// destructuring bytecode uses these as stack-only callees instead of
    /// resolving pseudo-private `__zjs_dstr_*` globals.
    internal_destructuring_helpers: [internal_destructuring_helper_slots]?JSValue = @splat(null),
    performance_time_origin_ms: f64 = 0,
    opcode_profile: ?*profile.OpcodeProfile = null,
    cli_argv0: []const u8 = "",
    cli_exec_argv: []const []const u8 = &.{},
    cli_script_args: []const []const u8 = &.{},
    external_host_functions: []host_function.ExternalRecord = &.{},
    external_host_functions_capacity: usize = 0,
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
        rt.memory.trigger_gc_fn = null;
        rt.memory.trigger_gc_ctx = null;
        rt.memory.setLimit(options.memory_limit);
        rt.gc = gc.Registry.init(&rt.memory, options.gc_policy);
        rt.atoms = atom.AtomTable.init(&rt.memory);
        rt.classes = try class.Table.init(&rt.memory, &rt.atoms);
        errdefer {
            rt.classes.deinit();
        }
        rt.shapes = shape.Registry.init(&rt.memory, &rt.atoms);
        rt.modules = module.Registry.init(&rt.memory, &rt.atoms);
        rt.borrowed_reference_holders = &.{};
        rt.borrowed_reference_holders_capacity = 0;
        rt.root_providers = &.{};
        rt.root_providers_capacity = 0;
        rt.persistent_root_slots = &.{};
        rt.persistent_root_slots_capacity = 0;
        rt.external_symbol_roots = &.{};
        rt.external_symbol_roots_capacity = 0;
        rt.external_value_roots = &.{};
        rt.external_value_roots_capacity = 0;
        rt.active_value_roots = null;
        rt.pending_finalization_jobs = &.{};
        rt.pending_finalization_jobs_capacity = 0;
        rt.job_queue = job_mod.Queue.init(&rt.memory);
        rt.deferred_native_cleanups = &.{};
        rt.deferred_native_cleanups_capacity = 0;
        rt.draining_deferred_native_cleanups = false;
        rt.deferred_native_cleanup_run_count = 0;
        rt.deferred_weak_value_frees = &.{};
        rt.deferred_weak_value_frees_capacity = 0;
        rt.draining_deferred_weak_value_frees = false;
        rt.borrowed_weak_cleanup_identities = &.{};
        rt.borrowed_weak_cleanup_identities_capacity = 0;
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
        rt.interrupt_handler = options.interrupt_handler;
        rt.interrupt_context = options.interrupt_context;
        rt.can_block = options.can_block;
        rt.random_state = 0x1234_5678_9abc_def0;
        rt.single_byte_strings = @splat(null);
        rt.empty_string = null;
        rt.recent_two_unit_string = null;
        rt.recent_atom_strings = @splat(null);
        rt.recent_atom_string_next = 0;
        rt.regexp_simple_class_alternation_cache = @splat(null);
        rt.regexp_simple_class_alternation_cache_next = 0;
        rt.percent_hex_strings = @splat(null);
        rt.small_int_strings = @splat(null);
        rt.internal_destructuring_helpers = @splat(null);
        rt.performance_time_origin_ms = 0;
        rt.opcode_profile = null;
        rt.cli_argv0 = "";
        rt.cli_exec_argv = &.{};
        rt.cli_script_args = &.{};
        rt.external_host_functions = &.{};
        rt.external_host_functions_capacity = 0;
        rt.any_prototype_may_have_indexed_properties = false;
        rt.memory.profile_alloc_count = null;
        rt.memory.trigger_gc_fn = JSRuntime.triggerGCOnAllocation;
        rt.memory.trigger_gc_ctx = rt;
    }

    pub fn setOpcodeProfile(self: *JSRuntime, opcode_profile: ?*profile.OpcodeProfile) void {
        self.opcode_profile = opcode_profile;
        self.memory.profile_alloc_count = if (opcode_profile) |prof| &prof.alloc_count else null;
    }

    pub fn deinit(self: *JSRuntime) void {
        const current_exception = self.current_exception;
        self.current_exception = JSValue.uninitialized();
        current_exception.free(self);
        self.job_queue.deinit();
        self.drainDeferredWeakValueFrees();
        self.clearPendingFinalizationJobs();
        const recent_two_unit_string = self.recent_two_unit_string;
        self.recent_two_unit_string = null;
        if (recent_two_unit_string) |cached| JSValue.string(&cached.string.header).free(self);
        for (&self.recent_atom_strings) |*slot| {
            const cached = slot.*;
            slot.* = null;
            if (cached) |stored| JSValue.string(&stored.string.header).free(self);
        }
        self.recent_atom_string_next = 0;
        for (&self.regexp_simple_class_alternation_cache) |*slot| {
            if (slot.*) |entry| {
                slot.* = null;
                self.atoms.free(entry.source_atom);
                self.atoms.free(entry.flags_atom);
            }
        }
        self.regexp_simple_class_alternation_cache_next = 0;
        const empty_string = self.empty_string;
        self.empty_string = null;
        if (empty_string) |cached| JSValue.string(&cached.header).free(self);
        for (&self.single_byte_strings) |*slot| {
            const cached = slot.*;
            slot.* = null;
            if (cached) |stored| JSValue.string(&stored.header).free(self);
        }
        for (&self.percent_hex_strings) |*slot| {
            const cached = slot.*;
            slot.* = null;
            if (cached) |stored| JSValue.string(&stored.header).free(self);
        }
        for (&self.small_int_strings) |*slot| {
            const cached = slot.*;
            slot.* = null;
            if (cached) |stored| JSValue.string(&stored.header).free(self);
        }
        for (&self.internal_destructuring_helpers) |*slot| {
            const cached = slot.*;
            slot.* = null;
            if (cached) |stored| stored.free(self);
        }
        self.clearPersistentRootSlots();
        self.clearExternalSymbolRoots();
        self.clearExternalValueRoots();
        self.clearExternalHostFunctions();
        self.drainDeferredNativeCleanups();
        self.modules.deinit(self);
        _ = self.runObjectCycleRemoval();
        self.drainDeferredWeakValueFrees();
        self.drainDeferredNativeCleanups();
        self.clearPendingFinalizationJobs();
        Object.releaseCallbackOwnedFunctionBytecodeCycles(self);
        _ = self.runObjectCycleRemoval();
        self.drainDeferredWeakValueFrees();
        self.drainDeferredNativeCleanups();
        self.clearBorrowedWeakCleanupIdentities();
        self.clearPendingFinalizationJobs();
        self.gc.deinit(self);
        self.shapes.deinit();
        self.classes.deinit();
        self.atoms.deinit();
        const borrowed_reference_holders: []*Object = if (self.borrowed_reference_holders_capacity != 0) self.borrowed_reference_holders.ptr[0..self.borrowed_reference_holders_capacity] else self.borrowed_reference_holders[0..0];
        const root_providers: []RootProvider = if (self.root_providers_capacity != 0) self.root_providers.ptr[0..self.root_providers_capacity] else self.root_providers[0..0];
        const persistent_root_slots: []*RootSlot = if (self.persistent_root_slots_capacity != 0) self.persistent_root_slots.ptr[0..self.persistent_root_slots_capacity] else self.persistent_root_slots[0..0];
        const external_symbol_roots: []atom.Atom = if (self.external_symbol_roots_capacity != 0) self.external_symbol_roots.ptr[0..self.external_symbol_roots_capacity] else self.external_symbol_roots[0..0];
        const external_value_roots: []JSValue = if (self.external_value_roots_capacity != 0) self.external_value_roots.ptr[0..self.external_value_roots_capacity] else self.external_value_roots[0..0];
        const external_host_functions: []host_function.ExternalRecord = if (self.external_host_functions_capacity != 0) self.external_host_functions.ptr[0..self.external_host_functions_capacity] else self.external_host_functions[0..0];
        const deferred_native_cleanups: []NativeCleanupJob = if (self.deferred_native_cleanups_capacity != 0) self.deferred_native_cleanups.ptr[0..self.deferred_native_cleanups_capacity] else self.deferred_native_cleanups[0..0];
        self.borrowed_reference_holders = &.{};
        self.borrowed_reference_holders_capacity = 0;
        self.root_providers = &.{};
        self.root_providers_capacity = 0;
        self.persistent_root_slots = &.{};
        self.persistent_root_slots_capacity = 0;
        self.external_symbol_roots = &.{};
        self.external_symbol_roots_capacity = 0;
        self.external_value_roots = &.{};
        self.external_value_roots_capacity = 0;
        self.external_host_functions = &.{};
        self.external_host_functions_capacity = 0;
        self.deferred_native_cleanups = &.{};
        self.deferred_native_cleanups_capacity = 0;
        if (borrowed_reference_holders.len != 0) self.memory.free(*Object, borrowed_reference_holders);
        if (root_providers.len != 0) self.memory.free(RootProvider, root_providers);
        if (persistent_root_slots.len != 0) self.memory.free(*RootSlot, persistent_root_slots);
        if (external_symbol_roots.len != 0) self.memory.free(atom.Atom, external_symbol_roots);
        if (external_value_roots.len != 0) self.memory.free(JSValue, external_value_roots);
        if (external_host_functions.len != 0) self.memory.free(host_function.ExternalRecord, external_host_functions);
        if (deferred_native_cleanups.len != 0) self.memory.free(NativeCleanupJob, deferred_native_cleanups);
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

    pub fn registerObject(self: *JSRuntime, object: *Object) !void {
        try self.gc.addWithGeneration(&object.header, self.initialObjectGeneration(object), @sizeOf(Object));
        if (self.gc.hasPendingMajorRequest() or self.memory.allocated_bytes > self.malloc_gc_threshold) {
            _ = self.pollGC(self.active_value_roots, .normal) catch {};
        }
    }

    fn initialObjectGeneration(self: JSRuntime, object: *const Object) gc.Generation {
        if (!self.gc.policy.enable_nursery) return .old;
        return switch (object.class_id) {
            class.ids.object,
            class.ids.array,
            class.ids.error_,
            class.ids.number,
            class.ids.string,
            class.ids.boolean,
            class.ids.symbol,
            class.ids.arguments,
            class.ids.mapped_arguments,
            class.ids.date,
            class.ids.big_int,
            class.ids.for_in_iterator,
            class.ids.iterator,
            class.ids.iterator_concat,
            class.ids.iterator_helper,
            class.ids.iterator_wrap,
            class.ids.map_iterator,
            class.ids.set_iterator,
            class.ids.array_iterator,
            class.ids.string_iterator,
            class.ids.regexp_string_iterator,
            class.ids.async_from_sync_iterator,
            class.ids.promise,
            class.ids.promise_resolve_function,
            class.ids.promise_reject_function,
            class.ids.dom_exception,
            class.ids.call_site,
            class.ids.raw_json,
            => .young,
            else => .old,
        };
    }

    pub fn unregisterObject(self: *JSRuntime, object: *Object) void {
        self.unregisterBorrowedReferenceHolder(object);
        self.gc.unlinkObject(&object.header);
    }

    pub fn registerBorrowedReferenceHolder(self: *JSRuntime, object: *Object) !void {
        for (self.borrowed_reference_holders) |holder| {
            if (holder == object) return;
        }
        try appendRuntimeObject(&self.memory, &self.borrowed_reference_holders, &self.borrowed_reference_holders_capacity, object);
    }

    pub fn borrowedReferenceHolderRegistered(self: *const JSRuntime, object: *Object) bool {
        for (self.borrowed_reference_holders) |holder| {
            if (holder == object) return true;
        }
        return false;
    }

    pub fn unregisterBorrowedReferenceHolder(self: *JSRuntime, object: *Object) void {
        if (self.borrowed_reference_holders.len != 0 and self.borrowed_reference_holders[self.borrowed_reference_holders.len - 1] == object) {
            self.borrowed_reference_holders = self.borrowed_reference_holders[0 .. self.borrowed_reference_holders.len - 1];
            return;
        }
        var found: ?usize = null;
        for (self.borrowed_reference_holders, 0..) |candidate, index| {
            if (candidate == object) {
                found = index;
                break;
            }
        }
        const index = found orelse return;
        if (index + 1 < self.borrowed_reference_holders.len) {
            std.mem.copyForwards(*Object, self.borrowed_reference_holders[index .. self.borrowed_reference_holders.len - 1], self.borrowed_reference_holders[index + 1 ..]);
        }
        self.borrowed_reference_holders = self.borrowed_reference_holders[0 .. self.borrowed_reference_holders.len - 1];
    }

    pub fn registerRootProvider(self: *JSRuntime, provider: RootProvider) !void {
        for (self.root_providers) |registered| {
            if (registered.context == provider.context and registered.trace == provider.trace) return;
        }
        try appendRuntimeRootProvider(&self.memory, &self.root_providers, &self.root_providers_capacity, provider);
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
            const old_providers = self.root_providers.ptr[0..self.root_providers_capacity];
            self.root_providers = &.{};
            self.root_providers_capacity = 0;
            self.memory.free(RootProvider, old_providers);
        }
    }

    pub fn traceRoots(self: *JSRuntime, roots: ?*const ValueRootFrame, visitor: *RootVisitor) RootTraceError!void {
        try self.traceValueRootFrames(roots, visitor);
        try visitor.value(&self.current_exception);
        for (&self.internal_destructuring_helpers) |*maybe_helper| {
            try visitor.optionalValue(maybe_helper);
        }
        for (self.persistent_root_slots) |slot| {
            try visitor.value(&slot.value);
        }
        try visitor.values(self.external_value_roots);
        for (self.pending_finalization_jobs) |*job| {
            try job.traceRoots(visitor);
        }
        try self.job_queue.traceRoots(visitor);
        for (self.root_providers) |provider| {
            try provider.trace(provider.context, visitor);
        }
    }

    pub fn traceActiveRoots(self: *JSRuntime, visitor: *RootVisitor) RootTraceError!void {
        try self.traceRoots(self.active_value_roots, visitor);
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
                }
            }
            frame = current.previous;
        }
    }

    fn createPersistentRootSlot(self: *JSRuntime, value: JSValue) !*RootSlot {
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
        try appendRuntimeRootSlot(&self.memory, &self.persistent_root_slots, &self.persistent_root_slots_capacity, slot);
        slot.value = value;
        return slot;
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

    pub fn persistentRootCountForTest(self: JSRuntime) usize {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.persistent_root_slots.len;
    }

    pub fn registerExternalSymbolRoot(self: *JSRuntime, atom_id: atom.Atom) !void {
        if (self.atoms.kind(atom_id) != .symbol) return;
        const retained = self.atoms.dup(atom_id);
        errdefer self.atoms.free(retained);
        try appendRuntimeAtom(&self.memory, &self.external_symbol_roots, &self.external_symbol_roots_capacity, retained);
    }

    /// External roots are useful for host-owned Values or Atoms that must not be garbage collected
    /// but are stored outside the engine's standard call stack / execution state.
    ///
    /// Invariants:
    /// 1. Values registered with `registerExternalValueSymbolRoot` must be unregistered with
    ///    `unregisterExternalValueSymbolRoot` when the host no longer needs them.
    /// 2. If a registered JSValue is a Symbol atom, it is retained via the atom subsystem.
    /// 3. Registered value roots are preserved across cycle-collection GC passes.
    pub fn registerExternalValueSymbolRoot(self: *JSRuntime, value: JSValue) !bool {
        if (value.asSymbolAtom()) |atom_id| {
            try self.registerExternalSymbolRoot(atom_id);
            return true;
        }
        if (!valueMayContainNestedSymbolRoots(value)) return false;
        try appendRuntimeValue(&self.memory, &self.external_value_roots, &self.external_value_roots_capacity, value);
        return true;
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

    pub fn unregisterExternalSymbolRoot(self: *JSRuntime, atom_id: atom.Atom) void {
        var found: ?usize = null;
        for (self.external_symbol_roots, 0..) |registered, index| {
            if (registered == atom_id) {
                found = index;
                break;
            }
        }
        const index = found orelse return;
        const retained = self.external_symbol_roots[index];
        if (index + 1 < self.external_symbol_roots.len) {
            std.mem.copyForwards(atom.Atom, self.external_symbol_roots[index .. self.external_symbol_roots.len - 1], self.external_symbol_roots[index + 1 ..]);
        }
        self.external_symbol_roots = self.external_symbol_roots[0 .. self.external_symbol_roots.len - 1];
        self.atoms.free(retained);
        if (self.external_symbol_roots.len == 0 and self.external_symbol_roots_capacity != 0) {
            const old_roots = self.external_symbol_roots.ptr[0..self.external_symbol_roots_capacity];
            self.external_symbol_roots = &.{};
            self.external_symbol_roots_capacity = 0;
            self.memory.free(atom.Atom, old_roots);
        }
    }

    pub fn unregisterExternalValueSymbolRoot(self: *JSRuntime, value: JSValue) void {
        if (value.asSymbolAtom()) |atom_id| {
            self.unregisterExternalSymbolRoot(atom_id);
            return;
        }
        if (!valueMayContainNestedSymbolRoots(value)) return;
        self.unregisterExternalValueRoot(value);
    }

    pub fn clearExternalSymbolRoots(self: *JSRuntime) void {
        const roots = self.external_symbol_roots;
        const capacity = self.external_symbol_roots_capacity;
        self.external_symbol_roots = &.{};
        self.external_symbol_roots_capacity = 0;
        for (roots) |atom_id| self.atoms.free(atom_id);
        if (capacity != 0) self.memory.free(atom.Atom, roots.ptr[0..capacity]);
    }

    fn unregisterExternalValueRoot(self: *JSRuntime, value: JSValue) void {
        var found: ?usize = null;
        for (self.external_value_roots, 0..) |registered, index| {
            if (registered.same(value)) {
                found = index;
                break;
            }
        }
        const index = found orelse return;
        if (index + 1 < self.external_value_roots.len) {
            std.mem.copyForwards(JSValue, self.external_value_roots[index .. self.external_value_roots.len - 1], self.external_value_roots[index + 1 ..]);
        }
        self.external_value_roots = self.external_value_roots[0 .. self.external_value_roots.len - 1];
        if (self.external_value_roots.len == 0 and self.external_value_roots_capacity != 0) {
            const old_roots = self.external_value_roots.ptr[0..self.external_value_roots_capacity];
            self.external_value_roots = &.{};
            self.external_value_roots_capacity = 0;
            self.memory.free(JSValue, old_roots);
        }
    }

    pub fn clearExternalValueRoots(self: *JSRuntime) void {
        const roots = self.external_value_roots;
        const capacity = self.external_value_roots_capacity;
        self.external_value_roots = &.{};
        self.external_value_roots_capacity = 0;
        if (capacity != 0) self.memory.free(JSValue, roots.ptr[0..capacity]);
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
        return self.runObjectCycleRemovalWithValueRoots(self.active_value_roots);
    }

    pub fn runObjectCycleRemovalWithValueRoots(self: *JSRuntime, roots: ?*const ValueRootFrame) usize {
        const result = self.tryRunObjectCycleRemovalWithValueRoots(roots) catch return 0;
        return result.freed_objects;
    }

    pub fn tryRunObjectCycleRemoval(self: *JSRuntime) gc.CollectionError!gc.CollectionResult {
        return self.tryRunObjectCycleRemovalWithValueRoots(self.active_value_roots);
    }

    pub fn tryRunObjectCycleRemovalWithValueRoots(
        self: *JSRuntime,
        roots: ?*const ValueRootFrame,
    ) gc.CollectionError!gc.CollectionResult {
        if (self.gc_running) return .{};
        if (builtin.mode == .Debug) self.gc.verifyIntrusiveList() catch unreachable;
        if (builtin.mode == .Debug) self.gc.verifyNurseryCoverage() catch unreachable;
        defer if (builtin.mode == .Debug) self.gc.verifyIntrusiveList() catch unreachable;
        self.gc_running = true;
        defer self.gc_running = false;

        const start_ns = profile.nowNanos();
        const freed = Object.destroyRuntimeCyclesWithValueRoots(self, roots) catch |err| {
            const mapped: gc.CollectionError = switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.PayloadMarkFailed => error.PayloadMarkFailed,
            };
            self.gc.recordFailure(mapped);
            self.gc.requestGC(.major, .collection_failed, .soon);
            return mapped;
        };

        const result = gc.CollectionResult{
            .freed_objects = freed,
            .duration_ns = blk: {
                const end_ns = profile.nowNanos();
                break :blk if (end_ns > start_ns) end_ns - start_ns else 0;
            },
        };
        self.gc.recordSuccess(result);
        self.resetGCThreshold();
        return result;
    }

    fn tryCollectMinorNonMoving(
        self: *JSRuntime,
        roots: ?*const ValueRootFrame,
    ) gc.CollectionError!gc.CollectionResult {
        if (self.gc_running) return .{};
        if (builtin.mode == .Debug) self.gc.verifyIntrusiveList() catch unreachable;
        if (builtin.mode == .Debug) self.gc.verifyNurseryCoverage() catch unreachable;
        if (builtin.mode == .Debug) self.verifyRememberedSetCoverage() catch unreachable;
        defer if (builtin.mode == .Debug) self.gc.verifyIntrusiveList() catch unreachable;
        self.gc_running = true;
        defer self.gc_running = false;

        const MinorPromotionVisitor = struct {
            rt: *JSRuntime,
            object_worklist: std.ArrayList(*Object) = .empty,
            bytecode_worklist: std.ArrayList(*bytecode_function.FunctionBytecode) = .empty,
            promoted_young_objects: usize = 0,
            promoted_young_bytes: usize = 0,
            err: ?gc.CollectionError = null,

            fn deinit(self_visitor: *@This()) void {
                self_visitor.object_worklist.deinit(self_visitor.rt.memory.persistent_allocator);
                self_visitor.bytecode_worklist.deinit(self_visitor.rt.memory.persistent_allocator);
            }

            fn rootVisitValue(context: *anyopaque, slot: *JSValue) RootTraceError!void {
                const self_visitor: *@This() = @ptrCast(@alignCast(context));
                try self_visitor.visitValue(slot);
            }

            fn rootVisitObject(context: *anyopaque, slot: *?*Object) RootTraceError!void {
                const self_visitor: *@This() = @ptrCast(@alignCast(context));
                try self_visitor.visitObject(slot);
            }

            fn visitObject(self_visitor: *@This(), slot: *?*Object) !void {
                self_visitor.rt.rewriteForwardedObjectSlot(slot);
                const obj = slot.* orelse return;
                try self_visitor.evacuateHeader(&obj.header);
            }

            fn visitValue(self_visitor: *@This(), slot: *JSValue) !void {
                self_visitor.rt.rewriteForwardedValueSlot(slot);
                if (slot.refHeader()) |header| {
                    try self_visitor.evacuateHeader(header);
                }
                if (slot.objectHeader()) |header| {
                    try self_visitor.evacuateHeader(header);
                }
            }

            fn evacuateHeader(self_visitor: *@This(), header: *gc.Header) !void {
                if (header.generation() != .young) return;

                if (self_visitor.rt.gc.forwardedHeader(header)) |forwarded| {
                    if (forwarded != header) {
                        header.setGeneration(.old);
                        return;
                    }
                } else {
                    try self_visitor.rt.gc.recordForwarding(header, header);
                }

                try self_visitor.promoteInPlace(header);
            }

            fn promoteInPlace(self_visitor: *@This(), header: *gc.Header) !void {
                std.debug.assert(header.generation() == .young);
                self_visitor.rt.gc.markNurserySurvivor(header);
                switch (header.kind) {
                    .object => {
                        const obj: *Object = @alignCast(@fieldParentPtr("header", header));
                        try self_visitor.object_worklist.append(self_visitor.rt.memory.persistent_allocator, obj);
                    },
                    .function_bytecode => {
                        const fb: *bytecode_function.FunctionBytecode = @alignCast(@fieldParentPtr("header", header));
                        try self_visitor.bytecode_worklist.append(self_visitor.rt.memory.persistent_allocator, fb);
                    },
                    .string, .big_int => {},
                }

                header.setGeneration(.old);
                self_visitor.promoted_young_objects +|= 1;
                self_visitor.promoted_young_bytes +|= promotedSize(header);
            }

            fn promotedSize(header: *const gc.Header) usize {
                return switch (header.kind) {
                    .object => @sizeOf(Object),
                    .function_bytecode => @sizeOf(bytecode_function.FunctionBytecode),
                    .string, .big_int => 0,
                };
            }

            fn drain(self_visitor: *@This()) !void {
                var object_index: usize = 0;
                var bytecode_index: usize = 0;
                while (object_index < self_visitor.object_worklist.items.len or bytecode_index < self_visitor.bytecode_worklist.items.len) {
                    while (object_index < self_visitor.object_worklist.items.len) : (object_index += 1) {
                        const obj = self_visitor.object_worklist.items[object_index];
                        try obj.traceChildEdgesFallible(self_visitor.rt, self_visitor);
                    }
                    while (bytecode_index < self_visitor.bytecode_worklist.items.len) : (bytecode_index += 1) {
                        const fb = self_visitor.bytecode_worklist.items[bytecode_index];
                        try self_visitor.traceFunctionBytecode(fb);
                    }
                }
            }

            fn traceFunctionBytecode(self_visitor: *@This(), fb: *bytecode_function.FunctionBytecode) !void {
                if (fb.class_fields_init) |*stored| try self_visitor.visitValue(stored);
                for (fb.cpool) |*stored| try self_visitor.visitValue(stored);
            }
        };

        const Helper = struct {
            fn mapRootTraceError(err: RootTraceError) gc.CollectionError {
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.PayloadMarkFailed => error.PayloadMarkFailed,
                };
            }
        };

        const start_ns = profile.nowNanos();
        _ = self.gc.clearMinorRequest();
        errdefer self.gc.clearForwarding();

        var visitor = MinorPromotionVisitor{ .rt = self };
        defer visitor.deinit();

        var root_visitor = RootVisitor{
            .context = &visitor,
            .visit_value = MinorPromotionVisitor.rootVisitValue,
            .visit_object = MinorPromotionVisitor.rootVisitObject,
        };
        self.traceRoots(roots orelse self.active_value_roots, &root_visitor) catch |err| {
            const mapped = Helper.mapRootTraceError(err);
            self.gc.recordFailure(mapped);
            self.gc.requestGC(.minor, .collection_failed, .soon);
            return mapped;
        };

        for (self.gc.remembered_set) |owner| {
            switch (owner.kind) {
                .object => {
                    const obj: *Object = @alignCast(@fieldParentPtr("header", owner));
                    obj.traceChildEdgesFallible(self, &visitor) catch |err| {
                        self.gc.recordFailure(err);
                        self.gc.requestGC(.minor, .collection_failed, .soon);
                        return err;
                    };
                },
                .function_bytecode => {
                    const fb: *bytecode_function.FunctionBytecode = @alignCast(@fieldParentPtr("header", owner));
                    visitor.traceFunctionBytecode(fb) catch |err| {
                        self.gc.recordFailure(err);
                        self.gc.requestGC(.minor, .collection_failed, .soon);
                        return err;
                    };
                },
                .string, .big_int => {},
            }
        }

        visitor.drain() catch |err| {
            self.gc.recordFailure(err);
            self.gc.requestGC(.minor, .collection_failed, .soon);
            return err;
        };

        var nursery_index: usize = 0;
        while (self.gc.nurseryEntryHeader(nursery_index)) |header| : (nursery_index += 1) {
            visitor.evacuateHeader(header) catch |err| {
                self.gc.recordFailure(err);
                self.gc.requestGC(.minor, .collection_failed, .soon);
                return err;
            };
        }
        visitor.drain() catch |err| {
            self.gc.recordFailure(err);
            self.gc.requestGC(.minor, .collection_failed, .soon);
            return err;
        };

        const result = gc.CollectionResult{
            .promoted_young_objects = visitor.promoted_young_objects,
            .promoted_young_bytes = visitor.promoted_young_bytes,
            .duration_ns = blk: {
                const end_ns = profile.nowNanos();
                break :blk if (end_ns > start_ns) end_ns - start_ns else 0;
            },
        };
        self.gc.finishMinorCollection(result);
        if (builtin.mode == .Debug) self.gc.verifyMinorPostcondition() catch unreachable;
        return result;
    }

    pub fn pollGC(
        self: *JSRuntime,
        roots: ?*const ValueRootFrame,
        mode: GCPollMode,
    ) gc.CollectionError!gc.CollectionResult {
        if (self.gc_running) return .{};
        const over_threshold = self.memory.allocated_bytes > self.malloc_gc_threshold;
        const pending_minor = self.gc.hasPendingMinorRequest();
        const pending_major = self.gc.hasPendingMajorRequest();
        if (mode != .urgent and !pending_minor and !pending_major and !over_threshold) return .{};

        var result: gc.CollectionResult = .{};
        if (pending_minor) {
            result = try self.tryCollectMinorNonMoving(roots orelse self.active_value_roots);
        }

        const major_request = self.gc.pendingMajorRequest();
        const run_major = mode == .urgent or over_threshold or switch (mode) {
            .normal, .idle => pending_major,
            .callback_boundary => if (major_request) |request| request.urgency == .urgent else false,
            .urgent => true,
        };
        if (run_major) {
            if (pending_major) _ = self.gc.clearMajorRequest();
            const major_result = try self.tryRunObjectCycleRemovalWithValueRoots(roots orelse self.active_value_roots);
            result.freed_objects +|= major_result.freed_objects;
            result.freed_bytecodes +|= major_result.freed_bytecodes;
            result.promoted_young_objects +|= major_result.promoted_young_objects;
            result.promoted_young_bytes +|= major_result.promoted_young_bytes;
            result.duration_ns +|= major_result.duration_ns;
        }
        return result;
    }

    pub fn requestGCForTest(self: *JSRuntime) void {
        if (!builtin.is_test) @compileError("test-only helper");
        self.gc.requestGC(.major, .manual, .soon);
    }

    pub fn gcPendingForTest(self: JSRuntime) bool {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.gc.hasPendingRequest();
    }

    pub fn gcLastRequestReasonForTest(self: JSRuntime) ?gc.RequestReason {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.gc.stats.last_request_reason;
    }

    pub fn gcPendingKindForTest(self: JSRuntime) ?gc.RequestKind {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.gc.pendingRequestKind();
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

    pub fn reportExternalAlloc(self: *JSRuntime, bytes: usize) gc.ExternalMemoryToken {
        const token = self.gc.reportExternalAlloc(bytes);
        if (self.gc.externalMemoryRequestReason()) |reason| {
            self.gc.requestGC(.major, reason, self.gc.externalMemoryRequestUrgency());
        }
        return token;
    }

    pub fn reportExternalFree(self: *JSRuntime, bytes: usize) void {
        self.gc.reportExternalFree(bytes);
    }

    pub fn externalMemoryBytes(self: JSRuntime) usize {
        return self.gc.stats.external_bytes;
    }

    pub fn allocationDebtBytes(self: JSRuntime) usize {
        return self.gc.stats.allocation_debt;
    }

    pub fn gcStats(self: JSRuntime) gc.Stats {
        var stats = self.gc.statsSnapshot();
        stats.pending_finalization_job_count = self.pending_finalization_jobs.len;
        stats.deferred_native_cleanup_count = self.deferred_native_cleanups.len;
        stats.deferred_native_cleanup_run_count = self.deferred_native_cleanup_run_count;
        return stats;
    }

    pub fn rewriteForwardedValueSlot(self: *JSRuntime, slot: *JSValue) void {
        const header = slot.refHeader() orelse slot.objectHeader() orelse return;
        const forwarded = self.gc.forwardedHeader(header) orelse return;
        slot.payload = @intFromPtr(forwarded);
    }

    pub fn rewriteForwardedObjectSlot(self: *JSRuntime, slot: *?*Object) void {
        const obj = slot.* orelse return;
        const forwarded = self.gc.forwardedHeader(&obj.header) orelse return;
        std.debug.assert(forwarded.kind == .object);
        slot.* = @alignCast(@fieldParentPtr("header", forwarded));
    }

    pub fn writeBarrierValue(self: *JSRuntime, owner: *gc.GCObjectHeader, value: JSValue) !void {
        const child = value.refHeader() orelse value.objectHeader() orelse return;
        try self.gc.writeBarrier(owner, child, null);
    }

    pub fn writeBarrierValueAt(self: *JSRuntime, owner: *gc.GCObjectHeader, value: JSValue, slot_addr: *const anyopaque) !void {
        const child = value.refHeader() orelse value.objectHeader() orelse return;
        try self.gc.writeBarrier(owner, child, slot_addr);
    }

    pub fn writeBarrierObjectAt(self: *JSRuntime, owner: *gc.GCObjectHeader, object: ?*Object, slot_addr: *const anyopaque) !void {
        const child = object orelse return;
        try self.gc.writeBarrier(owner, &child.header, slot_addr);
    }

    pub fn writeBarrierObjectSlot(self: *JSRuntime, owner: *gc.GCObjectHeader, slot: *const ?*Object) !void {
        try self.writeBarrierObjectAt(owner, slot.*, @ptrCast(slot));
    }

    pub fn writeBarrierValueSlot(self: *JSRuntime, owner: *gc.GCObjectHeader, slot: *const JSValue) !void {
        try self.writeBarrierValueAt(owner, slot.*, slot);
    }

    pub fn writeBarrierValueSlice(self: *JSRuntime, owner: *gc.GCObjectHeader, values: []const JSValue) !void {
        for (values, 0..) |value, index| {
            try self.writeBarrierValueAt(owner, value, &values[index]);
        }
    }

    pub fn writeBarrierOptionalValueSlot(self: *JSRuntime, owner: *gc.GCObjectHeader, slot: *const ?JSValue) !void {
        if (slot.*) |stored| try self.writeBarrierValueAt(owner, stored, slot);
    }

    pub fn verifyRememberedSetCoverage(self: *JSRuntime) gc.InvariantError!void {
        const RememberedVerifier = struct {
            rt: *JSRuntime,
            owner: *gc.GCObjectHeader,
            err: ?gc.InvariantError = null,

            pub fn visitValue(verifier: *@This(), slot: *JSValue) gc.InvariantError!void {
                if (slot.refHeader()) |header| try verifier.verifyValueChild(header, slot);
                if (slot.objectHeader()) |header| try verifier.verifyValueChild(header, slot);
            }

            pub fn visitObject(verifier: *@This(), slot: *?*Object) gc.InvariantError!void {
                const object = slot.* orelse return;
                try verifier.verifyObjectChild(&object.header, slot);
            }

            pub fn visitWeakCollectionEntry(verifier: *@This(), entry: *object_mod.WeakCollectionEntry) gc.InvariantError!void {
                try verifier.visitValue(&entry.value);
            }

            pub fn visitFinalizationCell(verifier: *@This(), entry: *object_mod.FinalizationRegistryCell) gc.InvariantError!void {
                if (!entry.keepsHeldValuesAlive()) return;
                try verifier.visitValue(&entry.held_value);
                try verifier.visitValue(&entry.unregister_token);
            }

            fn verifyChild(verifier: *@This(), child: *gc.GCObjectHeader) gc.InvariantError!void {
                _ = verifier.rt;
                if (child.generation() != .young) return;
                if (!verifier.owner.remembered()) return error.MissingRememberedEdge;
            }

            fn verifyValueChild(verifier: *@This(), child: *gc.GCObjectHeader, slot: *const JSValue) gc.InvariantError!void {
                try verifier.verifyChild(child);
                if (child.generation() != .young) return;
                if (!verifier.rt.gc.hasDirtyCard(verifier.owner, slot)) return error.MissingDirtyCard;
            }

            fn verifyObjectChild(verifier: *@This(), child: *gc.GCObjectHeader, slot: *const ?*Object) gc.InvariantError!void {
                try verifier.verifyChild(child);
                if (child.generation() != .young) return;
                if (!verifier.rt.gc.hasDirtyCard(verifier.owner, @ptrCast(slot))) return error.MissingDirtyCard;
            }
        };

        var current = self.gc.gc_obj_list_head;
        while (current) |node| {
            const owner = gc.headerFromGcNode(node);
            if (owner.generation() != .old) {
                current = node.next;
                continue;
            }

            var verifier = RememberedVerifier{
                .rt = self,
                .owner = owner,
            };
            switch (owner.kind) {
                .object => {
                    const obj: *Object = @alignCast(@fieldParentPtr("header", owner));
                    try obj.traceChildEdgesFallible(self, &verifier);
                },
                .function_bytecode => {
                    const fb: *bytecode_function.FunctionBytecode = @alignCast(@fieldParentPtr("header", owner));
                    if (fb.class_fields_init) |*stored| try verifier.visitValue(stored);
                    for (fb.cpool) |*stored| try verifier.visitValue(stored);
                },
                .string, .big_int => {},
            }
            current = node.next;
        }
    }

    fn maybeRunObjectCycleRemoval(self: *JSRuntime) void {
        if (self.gc_running) return;
        if (self.memory.allocated_bytes <= self.malloc_gc_threshold) return;
        _ = self.runObjectCycleRemoval();
    }

    fn triggerGCOnAllocation(ctx: ?*anyopaque, size: usize) void {
        const self: *JSRuntime = @ptrCast(@alignCast(ctx));
        if (self.gc_running) return;
        const total = std.math.add(usize, self.memory.allocated_bytes, size) catch std.math.maxInt(usize);
        if (total > self.malloc_gc_threshold) {
            self.gc.requestGC(.major, .allocation_threshold, .soon);
        }
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
        if (old) |stored| JSValue.string(&stored.string.header).free(self);
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
        if (self.atoms.kind(atom_id) == .string) {
            created.atom_id = self.atoms.dup(atom_id);
        }
        const slot_index = self.recent_atom_string_next % self.recent_atom_strings.len;
        const old = self.recent_atom_strings[slot_index];
        self.recent_atom_strings[slot_index] = .{
            .atom_id = atom_id,
            .string = created,
        };
        self.recent_atom_string_next = (slot_index + 1) % self.recent_atom_strings.len;
        if (old) |stored| JSValue.string(&stored.string.header).free(self);
        return created;
    }

    pub fn cachedRegExpSimpleClassAlternation(self: *JSRuntime, source_atom: atom.Atom, flags_atom: atom.Atom) ?object_mod.RegExpSimpleClassAlternationPattern {
        for (self.regexp_simple_class_alternation_cache) |slot| {
            if (slot) |entry| {
                if (entry.source_atom == source_atom and entry.flags_atom == flags_atom) return entry.pattern;
            }
        }
        return null;
    }

    pub fn setRegExpSimpleClassAlternationCache(self: *JSRuntime, source_atom: atom.Atom, flags_atom: atom.Atom, pattern: object_mod.RegExpSimpleClassAlternationPattern) void {
        for (&self.regexp_simple_class_alternation_cache) |*slot| {
            if (slot.*) |entry| {
                if (entry.source_atom == source_atom and entry.flags_atom == flags_atom) {
                    slot.*.?.pattern = pattern;
                    return;
                }
            }
        }

        const slot_index = self.regexp_simple_class_alternation_cache_next % self.regexp_simple_class_alternation_cache.len;
        const old = self.regexp_simple_class_alternation_cache[slot_index];
        self.regexp_simple_class_alternation_cache[slot_index] = .{
            .source_atom = self.atoms.dup(source_atom),
            .flags_atom = self.atoms.dup(flags_atom),
            .pattern = pattern,
        };
        if (old) |entry| {
            self.atoms.free(entry.source_atom);
            self.atoms.free(entry.flags_atom);
        }
        self.regexp_simple_class_alternation_cache_next = (slot_index + 1) % self.regexp_simple_class_alternation_cache.len;
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
        const digits = "0123456789ABCDEF";
        const bytes: [3]u8 = .{
            '%',
            digits[value >> 4],
            digits[value & 0x0f],
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

    pub fn hasDeferredNativeCleanups(self: *const JSRuntime) bool {
        return self.deferred_native_cleanups.len != 0;
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

    pub fn drainDeferredNativeCleanups(self: *JSRuntime) void {
        while (self.runDeferredNativeCleanupBudgeted(std.math.maxInt(usize)) != 0) {}
        self.releaseEmptyDeferredNativeCleanupBuffer();
    }

    pub fn pendingDeferredNativeCleanupCountForTest(self: JSRuntime) usize {
        if (!builtin.is_test) @compileError("test-only helper");
        return self.deferred_native_cleanups.len;
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

    pub fn enqueueDeferredWeakValueFree(self: *JSRuntime, value: JSValue) !void {
        try self.enqueueDeferredWeakValueFreeWithPrequeuedIdentity(value, null);
    }

    pub fn enqueueDeferredWeakValueFreeWithPrequeuedIdentity(self: *JSRuntime, value: JSValue, prequeued_identity: ?usize) !void {
        const index = self.deferred_weak_value_frees.len;
        try self.ensureDeferredWeakValueFreeCapacity(index + 1);
        self.deferred_weak_value_frees = self.deferred_weak_value_frees.ptr[0 .. index + 1];
        self.deferred_weak_value_frees[index] = .{ .value = value, .prequeued_identity = prequeued_identity };
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
            var skip_identity = item.prequeued_identity;
            if (skip_identity == null) {
                if (objectFromLastRefValue(item.value)) |object| {
                    const identity = @intFromPtr(&object.header) & ~@as(usize, 1);
                    if (self.borrowed_weak_cleanup_active) {
                        if (object.is_global) self.enqueueBorrowedWeakCleanupRealmIdentity(identity);
                        if (self.borrowed_weak_cleanup_seen_holder) self.markBorrowedWeakCleanupNeedsRescan();
                        var enqueued_current_identity = false;
                        self.enqueueBorrowedWeakCleanupIdentity(identity) catch {
                            enqueued_current_identity = false;
                        };
                        if (self.borrowed_weak_cleanup_identities.len != 0 and self.borrowed_weak_cleanup_identities[self.borrowed_weak_cleanup_identities.len - 1] == identity) {
                            enqueued_current_identity = true;
                        }
                        if (enqueued_current_identity) skip_identity = identity;
                    }
                }
            }
            const previous_skip_identity = self.current_deferred_weak_value_free_identity;
            self.current_deferred_weak_value_free_identity = skip_identity;
            defer self.current_deferred_weak_value_free_identity = previous_skip_identity;
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
        self.borrowed_weak_cleanup_identities = self.borrowed_weak_cleanup_identities.ptr[0 .. index + 1];
        self.borrowed_weak_cleanup_identities[index] = identity;
    }

    pub fn enqueueBorrowedWeakCleanupIdentityForLastRefValue(self: *JSRuntime, value: JSValue) !void {
        const object = objectFromLastRefValue(value) orelse return;
        const identity = @intFromPtr(&object.header) & ~@as(usize, 1);
        if (object.is_global) self.enqueueBorrowedWeakCleanupRealmIdentity(identity);
        if (self.borrowed_weak_cleanup_seen_holder) self.markBorrowedWeakCleanupNeedsRescan();
        try self.enqueueBorrowedWeakCleanupIdentity(identity);
    }

    pub fn prequeueBorrowedWeakCleanupIdentityForLastRefValue(self: *JSRuntime, value: JSValue) ?usize {
        if (!self.borrowed_weak_cleanup_active) return null;
        const object = objectFromLastRefValue(value) orelse return null;
        const identity = @intFromPtr(&object.header) & ~@as(usize, 1);
        if (object.is_global) self.enqueueBorrowedWeakCleanupRealmIdentity(identity);
        if (self.borrowed_weak_cleanup_seen_holder) self.markBorrowedWeakCleanupNeedsRescan();
        self.enqueueBorrowedWeakCleanupIdentity(identity) catch return null;
        return identity;
    }

    pub fn borrowedWeakCleanupIdentityMatches(self: *const JSRuntime, identity: usize) bool {
        var index = self.borrowed_weak_cleanup_identities.len;
        while (index != 0) {
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
    if (header.kind != .object) return null;
    if (header.rc != 1) return null;
    return @alignCast(@fieldParentPtr("header", header));
}

fn valueMayContainNestedSymbolRoots(value: JSValue) bool {
    if (value.tag == @import("value.zig").Tag.object) return true;
    const header = value.objectHeader() orelse return false;
    return header.kind == .function_bytecode;
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

fn appendRuntimeValue(account: *memory.MemoryAccount, slice: *[]JSValue, capacity: *usize, item: JSValue) !void {
    if (slice.*.len == capacity.*) {
        const next_capacity = if (capacity.* == 0) 4 else capacity.* * 2;
        const next = try account.alloc(JSValue, next_capacity);
        errdefer account.free(JSValue, next);
        @memcpy(next[0..slice.*.len], slice.*);
        const old_capacity = capacity.*;
        const old = if (old_capacity != 0) slice.*.ptr[0..old_capacity] else slice.*[0..0];
        slice.* = next[0..slice.*.len];
        capacity.* = next_capacity;
        if (old_capacity != 0) account.free(JSValue, old);
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

fn appendRuntimeRootProvider(account: *memory.MemoryAccount, slice: *[]RootProvider, capacity: *usize, item: RootProvider) !void {
    if (slice.*.len == capacity.*) {
        const next_capacity = if (capacity.* == 0) 4 else capacity.* * 2;
        const next = try account.alloc(RootProvider, next_capacity);
        errdefer account.free(RootProvider, next);
        @memcpy(next[0..slice.*.len], slice.*);
        const old_capacity = capacity.*;
        const old = if (old_capacity != 0) slice.*.ptr[0..old_capacity] else slice.*[0..0];
        slice.* = next[0..slice.*.len];
        capacity.* = next_capacity;
        if (old_capacity != 0) account.free(RootProvider, old);
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

fn appendRuntimeAtom(account: *memory.MemoryAccount, slice: *[]atom.Atom, capacity: *usize, item: atom.Atom) !void {
    if (slice.*.len == capacity.*) {
        const next_capacity = if (capacity.* == 0) 4 else capacity.* * 2;
        const next = try account.alloc(atom.Atom, next_capacity);
        errdefer account.free(atom.Atom, next);
        @memcpy(next[0..slice.*.len], slice.*);
        const old_capacity = capacity.*;
        const old = if (old_capacity != 0) slice.*.ptr[0..old_capacity] else slice.*[0..0];
        slice.* = next[0..slice.*.len];
        capacity.* = next_capacity;
        if (old_capacity != 0) account.free(atom.Atom, old);
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

    var token = rt.reportExternalAlloc(8);
    try std.testing.expectEqual(@as(usize, 8), rt.externalMemoryBytes());
    try std.testing.expectEqual(@as(usize, 16), rt.allocationDebtBytes());
    try std.testing.expect(rt.gcPendingForTest());
    try std.testing.expectEqual(@as(?gc.RequestReason, gc.RequestReason.allocation_debt), rt.gcLastRequestReasonForTest());

    const result = try rt.pollGC(null, .normal);
    try std.testing.expectEqual(@as(usize, 0), result.freed_objects);
    try std.testing.expectEqual(@as(usize, 0), rt.allocationDebtBytes());
    try std.testing.expectEqual(@as(usize, 8), rt.externalMemoryBytes());
    try std.testing.expect(!rt.gcPendingForTest());

    token.release();
    try std.testing.expectEqual(@as(usize, 0), rt.externalMemoryBytes());
    token.release();
    try std.testing.expectEqual(@as(usize, 0), rt.externalMemoryBytes());
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

    var token = rt.reportExternalAlloc(8);
    defer token.release();

    const pending = rt.gcStats();
    try std.testing.expect(pending.pending_major);
    try std.testing.expectEqual(@as(?gc.RequestReason, gc.RequestReason.external_memory), pending.pending_request_reason);
    try std.testing.expectEqual(@as(?gc.RequestUrgency, gc.RequestUrgency.urgent), pending.pending_request_urgency);

    _ = try rt.pollGC(null, .callback_boundary);
    try std.testing.expectEqual(@as(usize, 1), rt.gcStats().major_gc_count);
    try std.testing.expect(!rt.gcPendingForTest());
}
