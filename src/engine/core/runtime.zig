const std = @import("std");

const memory = @import("memory.zig");
const atom = @import("atom.zig");
const class = @import("class.zig");
const gc = @import("gc.zig");
const host_function = @import("host_function.zig");
const module = @import("module.zig");
const object_mod = @import("object.zig");
const shape = @import("shape.zig");
const string = @import("string.zig");
const Value = @import("value.zig").Value;
const Object = object_mod.Object;
const profile = @import("profile.zig");

pub const default_stack_size = 1024 * 1024;
pub const default_gc_threshold = 256 * 1024;

pub const ValueRootSlice = union(enum) {
    mutable: *const []Value,
    constant: *const []const Value,
};

pub const ValueRootValue = struct {
    value: *const Value,
};

pub const ValueRootFrame = struct {
    previous: ?*const ValueRootFrame = null,
    slices: []const ValueRootSlice = &.{},
    values: []const ValueRootValue = &.{},
};

pub const FinalizationJob = struct {
    sequence: u64 = 0,
    callback: Value = Value.undefinedValue(),
    held_value: Value = Value.undefinedValue(),
    symbol_root_mask: u2 = 0,

    pub fn init(rt: *Runtime, sequence: u64, callback: Value, held_value: Value) !FinalizationJob {
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

    pub fn deinit(self: FinalizationJob, rt: *Runtime) void {
        self.unregisterSymbolRoots(rt);
        self.callback.free(rt);
        self.held_value.free(rt);
    }

    fn unregisterSymbolRoots(self: FinalizationJob, rt: *Runtime) void {
        if ((self.symbol_root_mask & 0b01) != 0) rt.unregisterExternalValueSymbolRoot(self.callback);
        if ((self.symbol_root_mask & 0b10) != 0) rt.unregisterExternalValueSymbolRoot(self.held_value);
    }
};

pub const DeferredWeakValueFree = struct {
    value: Value,
    prequeued_identity: ?usize = null,
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

pub const Runtime = struct {
    memory: memory.MemoryAccount,
    gc: gc.Registry,
    atoms: atom.AtomTable,
    classes: class.Table,
    shapes: shape.Registry,
    modules: module.Registry,

    borrowed_reference_holders: []*Object = &.{},
    borrowed_reference_holders_capacity: usize = 0,
    context_value_roots: []*ValueRootFrame = &.{},
    context_value_roots_capacity: usize = 0,
    external_symbol_roots: []atom.Atom = &.{},
    external_symbol_roots_capacity: usize = 0,
    external_value_roots: []Value = &.{},
    external_value_roots_capacity: usize = 0,
    active_value_roots: ?*const ValueRootFrame = null,
    gc_pending: bool = false,
    pending_finalization_jobs: []FinalizationJob = &.{},
    pending_finalization_jobs_capacity: usize = 0,
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
    current_exception: Value = Value.uninitialized(),
    stack_size: usize = default_stack_size,
    interrupt_handler: ?*const fn (*Runtime, ?*anyopaque) bool = null,
    interrupt_context: ?*anyopaque = null,
    can_block: bool = false,
    random_state: u64 = 0x1234_5678_9abc_def0,
    /// Lazy cache of single-byte (latin1) strings for ASCII code units.
    /// Populated on first request via `singleByteString`. Each cached
    /// String holds a permanent ref-count + 1 contributed by the cache;
    /// borrowers `retain` and `free` normally, and the cache slot is
    /// torn down on `Runtime.destroy`.
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
    /// Runtime-owned internal destructuring helper functions. Parser-emitted
    /// destructuring bytecode uses these as stack-only callees instead of
    /// resolving pseudo-private `__zjs_dstr_*` globals.
    internal_destructuring_helpers: [internal_destructuring_helper_slots]?Value = @splat(null),
    performance_time_origin_ms: f64 = 0,
    opcode_profile: ?*profile.OpcodeProfile = null,
    cli_argv0: []const u8 = "",
    cli_exec_argv: []const []const u8 = &.{},
    cli_script_args: []const []const u8 = &.{},
    external_host_functions: []host_function.ExternalRecord = &.{},
    external_host_functions_capacity: usize = 0,

    /// Returns an owned runtime. Caller must release it with `destroy`.
    pub fn create(allocator: std.mem.Allocator) !*Runtime {
        return createWithTrace(allocator, null);
    }

    /// Returns an owned runtime with optional allocation tracing.
    /// Caller must release it with `destroy`.
    pub fn createWithTrace(allocator: std.mem.Allocator, trace_writer: ?*std.Io.Writer) !*Runtime {
        var account = if (trace_writer) |writer|
            memory.MemoryAccount.initWithTrace(allocator, writer)
        else
            memory.MemoryAccount.init(allocator);
        const rt = try account.create(Runtime);
        errdefer account.destroy(Runtime, rt);
        rt.memory = account;
        rt.memory.trigger_gc_fn = null;
        rt.memory.trigger_gc_ctx = null;
        rt.gc = gc.Registry.init(&rt.memory);
        rt.atoms = atom.AtomTable.init(&rt.memory);
        rt.classes = try class.Table.init(&rt.memory, &rt.atoms);
        errdefer {
            rt.classes.deinit();
            rt.memory.destroy(Runtime, rt);
        }
        rt.shapes = shape.Registry.init(&rt.memory, &rt.atoms);
        rt.modules = module.Registry.init(&rt.memory, &rt.atoms);
        rt.borrowed_reference_holders = &.{};
        rt.borrowed_reference_holders_capacity = 0;
        rt.context_value_roots = &.{};
        rt.context_value_roots_capacity = 0;
        rt.external_symbol_roots = &.{};
        rt.external_symbol_roots_capacity = 0;
        rt.external_value_roots = &.{};
        rt.external_value_roots_capacity = 0;
        rt.active_value_roots = null;
        rt.gc_pending = false;
        rt.pending_finalization_jobs = &.{};
        rt.pending_finalization_jobs_capacity = 0;
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
        rt.malloc_gc_threshold = default_gc_threshold;
        rt.gc_running = false;
        rt.current_exception = Value.uninitialized();
        rt.stack_size = default_stack_size;
        rt.interrupt_handler = null;
        rt.interrupt_context = null;
        rt.can_block = false;
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
        rt.memory.profile_alloc_count = null;
        rt.memory.trigger_gc_fn = Runtime.triggerGCOnAllocation;
        rt.memory.trigger_gc_ctx = rt;
        return rt;
    }

    pub fn setOpcodeProfile(self: *Runtime, opcode_profile: ?*profile.OpcodeProfile) void {
        self.opcode_profile = opcode_profile;
        self.memory.profile_alloc_count = if (opcode_profile) |prof| &prof.alloc_count else null;
    }

    pub fn destroy(self: *Runtime) void {
        const current_exception = self.current_exception;
        self.current_exception = Value.uninitialized();
        current_exception.free(self);
        self.drainDeferredWeakValueFrees();
        self.clearPendingFinalizationJobs();
        const recent_two_unit_string = self.recent_two_unit_string;
        self.recent_two_unit_string = null;
        if (recent_two_unit_string) |cached| Value.string(&cached.string.header).free(self);
        for (&self.recent_atom_strings) |*slot| {
            const cached = slot.*;
            slot.* = null;
            if (cached) |stored| Value.string(&stored.string.header).free(self);
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
        if (empty_string) |cached| Value.string(&cached.header).free(self);
        for (&self.single_byte_strings) |*slot| {
            const cached = slot.*;
            slot.* = null;
            if (cached) |stored| Value.string(&stored.header).free(self);
        }
        for (&self.percent_hex_strings) |*slot| {
            const cached = slot.*;
            slot.* = null;
            if (cached) |stored| Value.string(&stored.header).free(self);
        }
        for (&self.small_int_strings) |*slot| {
            const cached = slot.*;
            slot.* = null;
            if (cached) |stored| Value.string(&stored.header).free(self);
        }
        for (&self.internal_destructuring_helpers) |*slot| {
            const cached = slot.*;
            slot.* = null;
            if (cached) |stored| stored.free(self);
        }
        self.clearExternalSymbolRoots();
        self.clearExternalValueRoots();
        self.clearExternalHostFunctions();
        self.modules.deinit(self);
        _ = self.runObjectCycleRemoval();
        self.drainDeferredWeakValueFrees();
        self.clearPendingFinalizationJobs();
        Object.releaseCallbackOwnedFunctionBytecodeCycles(self);
        self.gc.releaseCallbackOwnedObjects();
        _ = self.runObjectCycleRemoval();
        self.drainDeferredWeakValueFrees();
        self.clearBorrowedWeakCleanupIdentities();
        self.clearPendingFinalizationJobs();
        self.gc.deinit(self);
        self.shapes.deinit();
        self.classes.deinit();
        self.atoms.deinit();
        const borrowed_reference_holders: []*Object = if (self.borrowed_reference_holders_capacity != 0) self.borrowed_reference_holders.ptr[0..self.borrowed_reference_holders_capacity] else self.borrowed_reference_holders[0..0];
        const context_value_roots: []*ValueRootFrame = if (self.context_value_roots_capacity != 0) self.context_value_roots.ptr[0..self.context_value_roots_capacity] else self.context_value_roots[0..0];
        const external_symbol_roots: []atom.Atom = if (self.external_symbol_roots_capacity != 0) self.external_symbol_roots.ptr[0..self.external_symbol_roots_capacity] else self.external_symbol_roots[0..0];
        const external_value_roots: []Value = if (self.external_value_roots_capacity != 0) self.external_value_roots.ptr[0..self.external_value_roots_capacity] else self.external_value_roots[0..0];
        const external_host_functions: []host_function.ExternalRecord = if (self.external_host_functions_capacity != 0) self.external_host_functions.ptr[0..self.external_host_functions_capacity] else self.external_host_functions[0..0];
        self.borrowed_reference_holders = &.{};
        self.borrowed_reference_holders_capacity = 0;
        self.context_value_roots = &.{};
        self.context_value_roots_capacity = 0;
        self.external_symbol_roots = &.{};
        self.external_symbol_roots_capacity = 0;
        self.external_value_roots = &.{};
        self.external_value_roots_capacity = 0;
        self.external_host_functions = &.{};
        self.external_host_functions_capacity = 0;
        if (borrowed_reference_holders.len != 0) self.memory.free(*Object, borrowed_reference_holders);
        if (context_value_roots.len != 0) self.memory.free(*ValueRootFrame, context_value_roots);
        if (external_symbol_roots.len != 0) self.memory.free(atom.Atom, external_symbol_roots);
        if (external_value_roots.len != 0) self.memory.free(Value, external_value_roots);
        if (external_host_functions.len != 0) self.memory.free(host_function.ExternalRecord, external_host_functions);
        std.debug.assert(!self.memory.hasOutstandingAllocations() or self.memory.allocation_count == 1);

        var account = self.memory;
        account.destroy(Runtime, self);
        std.debug.assert(!account.hasOutstandingAllocations());
    }

    pub fn registerObject(self: *Runtime, object: *Object) !void {
        try self.gc.add(&object.header);
        if (self.gc_pending or self.memory.allocated_bytes > self.malloc_gc_threshold) {
            self.gc_pending = false;
            self.maybeRunObjectCycleRemoval();
        }
    }

    pub fn unregisterObject(self: *Runtime, object: *Object) void {
        self.unregisterBorrowedReferenceHolder(object);
        self.gc.unlinkObject(&object.header);
    }

    pub fn registerBorrowedReferenceHolder(self: *Runtime, object: *Object) !void {
        for (self.borrowed_reference_holders) |holder| {
            if (holder == object) return;
        }
        try appendRuntimeObject(&self.memory, &self.borrowed_reference_holders, &self.borrowed_reference_holders_capacity, object);
    }

    pub fn borrowedReferenceHolderRegistered(self: *const Runtime, object: *Object) bool {
        for (self.borrowed_reference_holders) |holder| {
            if (holder == object) return true;
        }
        return false;
    }

    pub fn unregisterBorrowedReferenceHolder(self: *Runtime, object: *Object) void {
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

    pub fn registerContextValueRoots(self: *Runtime, roots: *ValueRootFrame) !void {
        for (self.context_value_roots) |registered| {
            if (registered == roots) return;
        }
        try appendRuntimeValueRootFrame(&self.memory, &self.context_value_roots, &self.context_value_roots_capacity, roots);
    }

    pub fn unregisterContextValueRoots(self: *Runtime, roots: *ValueRootFrame) void {
        var found: ?usize = null;
        for (self.context_value_roots, 0..) |registered, index| {
            if (registered == roots) {
                found = index;
                break;
            }
        }
        const index = found orelse return;
        if (index + 1 < self.context_value_roots.len) {
            std.mem.copyForwards(*ValueRootFrame, self.context_value_roots[index .. self.context_value_roots.len - 1], self.context_value_roots[index + 1 ..]);
        }
        self.context_value_roots = self.context_value_roots[0 .. self.context_value_roots.len - 1];
        if (self.context_value_roots.len == 0 and self.context_value_roots_capacity != 0) {
            const old_roots = self.context_value_roots.ptr[0..self.context_value_roots_capacity];
            self.context_value_roots = &.{};
            self.context_value_roots_capacity = 0;
            self.memory.free(*ValueRootFrame, old_roots);
        }
    }

    pub fn registerExternalSymbolRoot(self: *Runtime, atom_id: atom.Atom) !void {
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
    /// 2. If a registered Value is a Symbol atom, it is retained via the atom subsystem.
    /// 3. Registered value roots are preserved across cycle-collection GC passes.
    pub fn registerExternalValueSymbolRoot(self: *Runtime, value: Value) !bool {
        if (value.asSymbolAtom()) |atom_id| {
            try self.registerExternalSymbolRoot(atom_id);
            return true;
        }
        if (!valueMayContainNestedSymbolRoots(value)) return false;
        try appendRuntimeValue(&self.memory, &self.external_value_roots, &self.external_value_roots_capacity, value);
        return true;
    }

    pub fn unregisterExternalSymbolRoot(self: *Runtime, atom_id: atom.Atom) void {
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

    pub fn unregisterExternalValueSymbolRoot(self: *Runtime, value: Value) void {
        if (value.asSymbolAtom()) |atom_id| {
            self.unregisterExternalSymbolRoot(atom_id);
            return;
        }
        if (!valueMayContainNestedSymbolRoots(value)) return;
        self.unregisterExternalValueRoot(value);
    }

    pub fn clearExternalSymbolRoots(self: *Runtime) void {
        const roots = self.external_symbol_roots;
        const capacity = self.external_symbol_roots_capacity;
        self.external_symbol_roots = &.{};
        self.external_symbol_roots_capacity = 0;
        for (roots) |atom_id| self.atoms.free(atom_id);
        if (capacity != 0) self.memory.free(atom.Atom, roots.ptr[0..capacity]);
    }

    fn unregisterExternalValueRoot(self: *Runtime, value: Value) void {
        var found: ?usize = null;
        for (self.external_value_roots, 0..) |registered, index| {
            if (registered.same(value)) {
                found = index;
                break;
            }
        }
        const index = found orelse return;
        if (index + 1 < self.external_value_roots.len) {
            std.mem.copyForwards(Value, self.external_value_roots[index .. self.external_value_roots.len - 1], self.external_value_roots[index + 1 ..]);
        }
        self.external_value_roots = self.external_value_roots[0 .. self.external_value_roots.len - 1];
        if (self.external_value_roots.len == 0 and self.external_value_roots_capacity != 0) {
            const old_roots = self.external_value_roots.ptr[0..self.external_value_roots_capacity];
            self.external_value_roots = &.{};
            self.external_value_roots_capacity = 0;
            self.memory.free(Value, old_roots);
        }
    }

    pub fn clearExternalValueRoots(self: *Runtime) void {
        const roots = self.external_value_roots;
        const capacity = self.external_value_roots_capacity;
        self.external_value_roots = &.{};
        self.external_value_roots_capacity = 0;
        if (capacity != 0) self.memory.free(Value, roots.ptr[0..capacity]);
    }

    pub fn registerExternalHostFunction(self: *Runtime, record: host_function.ExternalRecord) !u32 {
        try appendRuntimeExternalHostFunction(&self.memory, &self.external_host_functions, &self.external_host_functions_capacity, record);
        return @intCast(self.external_host_functions.len);
    }

    pub fn externalHostFunction(self: *Runtime, id: u32) ?host_function.ExternalRecord {
        if (id == 0) return null;
        const index: usize = @intCast(id - 1);
        if (index >= self.external_host_functions.len) return null;
        return self.external_host_functions[index];
    }

    pub fn clearExternalHostFunctions(self: *Runtime) void {
        const records = self.external_host_functions;
        const capacity = self.external_host_functions_capacity;
        self.external_host_functions = &.{};
        self.external_host_functions_capacity = 0;

        for (records) |record| {
            if (record.finalizer) |finalizer| finalizer(record.ptr);
        }
        if (capacity != 0) self.memory.free(host_function.ExternalRecord, records.ptr[0..capacity]);
    }

    pub fn runObjectCycleRemoval(self: *Runtime) usize {
        return self.runObjectCycleRemovalWithValueRoots(self.active_value_roots);
    }

    pub fn runObjectCycleRemovalWithValueRoots(self: *Runtime, roots: ?*const ValueRootFrame) usize {
        if (self.gc_running) return 0;
        self.gc_running = true;
        defer self.gc_running = false;
        const freed = Object.destroyRuntimeCyclesWithValueRoots(self, roots) catch 0;
        self.resetGCThreshold();
        return freed;
    }

    pub fn setGCThreshold(self: *Runtime, threshold: usize) void {
        self.malloc_gc_threshold = threshold;
    }

    pub fn gcThreshold(self: Runtime) usize {
        return self.malloc_gc_threshold;
    }

    pub fn setMemoryLimit(self: *Runtime, limit: ?usize) void {
        self.memory.setLimit(limit);
    }

    pub fn memoryLimit(self: Runtime) ?usize {
        return self.memory.getLimit();
    }

    fn maybeRunObjectCycleRemoval(self: *Runtime) void {
        if (self.gc_running) return;
        if (self.memory.allocated_bytes <= self.malloc_gc_threshold) return;
        _ = self.runObjectCycleRemoval();
    }

    fn triggerGCOnAllocation(ctx: ?*anyopaque, size: usize) void {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        if (self.gc_running) return;
        const total = std.math.add(usize, self.memory.allocated_bytes, size) catch std.math.maxInt(usize);
        if (total > self.malloc_gc_threshold) {
            self.gc_pending = true;
        }
    }

    fn resetGCThreshold(self: *Runtime) void {
        self.malloc_gc_threshold = std.math.add(usize, self.memory.allocated_bytes, self.memory.allocated_bytes >> 1) catch std.math.maxInt(usize);
    }

    /// Return a cached single-byte (latin1) string for an ASCII byte
    /// (0..127), creating it lazily on the first request. The returned
    /// pointer is borrowed; callers that need to participate in normal
    /// ref-counting should call `gc.retain(&result.header)` themselves.
    /// Returns `null` for non-ASCII bytes (the caller must allocate).
    pub fn singleByteString(self: *Runtime, byte: u8) !?*string.String {
        if (byte > 0x7f) return null;
        if (self.single_byte_strings[byte]) |cached| return cached;
        const created = try string.String.createAscii(self, &.{byte});
        self.single_byte_strings[byte] = created;
        return created;
    }

    pub fn cachedSingleByteString(self: *Runtime, byte: u8) ?*string.String {
        if (byte > 0x7f) return null;
        return self.single_byte_strings[byte];
    }

    pub fn emptyString(self: *Runtime) !*string.String {
        if (self.empty_string) |cached| return cached;
        const created = try string.String.createAscii(self, "");
        self.empty_string = created;
        return created;
    }

    /// Return a borrowed cached string for a two-code-unit sequence. Callers
    /// that return the value must `dup` it, matching `singleByteString`.
    pub fn recentTwoUnitString(self: *Runtime, first: u16, second: u16) !*string.String {
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
        if (old) |stored| Value.string(&stored.string.header).free(self);
        return created;
    }

    /// Return a borrowed cached string for a recently materialized atom.
    /// Callers that return the value must `dup` it.
    pub fn recentAtomString(self: *Runtime, atom_id: atom.Atom, bytes: []const u8) !*string.String {
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
        if (old) |stored| Value.string(&stored.string.header).free(self);
        return created;
    }

    pub fn cachedRegExpSimpleClassAlternation(self: *Runtime, source_atom: atom.Atom, flags_atom: atom.Atom) ?object_mod.RegExpSimpleClassAlternationPattern {
        for (self.regexp_simple_class_alternation_cache) |slot| {
            if (slot) |entry| {
                if (entry.source_atom == source_atom and entry.flags_atom == flags_atom) return entry.pattern;
            }
        }
        return null;
    }

    pub fn setRegExpSimpleClassAlternationCache(self: *Runtime, source_atom: atom.Atom, flags_atom: atom.Atom, pattern: object_mod.RegExpSimpleClassAlternationPattern) void {
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
    pub fn smallIntString(self: *Runtime, value: u8) !*string.String {
        if (self.small_int_strings[value]) |s| return s;
        var buf: [4]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        const s = try string.String.createLatin1(self, text);
        // The cache owns the string's initial reference and releases it in
        // Runtime.destroy; callers receive a borrowed pointer.
        self.small_int_strings[value] = s;
        return s;
    }

    pub fn percentHexString(self: *Runtime, value: u8) !*string.String {
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

    pub fn setStackSize(self: *Runtime, size: usize) void {
        self.stack_size = size;
    }

    pub fn stackSize(self: Runtime) usize {
        return self.stack_size;
    }

    pub fn internAtom(self: *Runtime, bytes: []const u8) !atom.Atom {
        return self.atoms.internString(bytes);
    }

    pub fn newClassId(self: *Runtime, requested: class.ClassId) class.ClassId {
        return self.classes.newClassId(requested);
    }

    pub fn setInterruptHandler(self: *Runtime, handler: ?*const fn (*Runtime, ?*anyopaque) bool, context: ?*anyopaque) void {
        self.interrupt_handler = handler;
        self.interrupt_context = context;
    }

    pub fn hasInterruptHandler(self: Runtime) bool {
        return self.interrupt_handler != null;
    }

    pub fn runInterruptHandler(self: *Runtime) bool {
        const handler = self.interrupt_handler orelse return false;
        return handler(self, self.interrupt_context);
    }

    pub fn setCanBlock(self: *Runtime, can_block: bool) void {
        self.can_block = can_block;
    }

    pub fn canBlock(self: Runtime) bool {
        return self.can_block;
    }

    pub fn nextJobSequence(self: *Runtime) u64 {
        const sequence = self.next_job_sequence;
        self.next_job_sequence +%= 1;
        return sequence;
    }

    pub fn enqueueFinalizationJob(self: *Runtime, callback: Value, held_value: Value) !void {
        const index = self.pending_finalization_jobs.len;
        try self.ensurePendingFinalizationJobCapacity(index + 1);
        var job = try FinalizationJob.init(self, self.nextJobSequence(), callback, held_value);
        errdefer job.deinit(self);
        self.pending_finalization_jobs = self.pending_finalization_jobs.ptr[0 .. index + 1];
        self.pending_finalization_jobs[index] = job;
    }

    pub fn peekPendingFinalizationJobSequence(self: Runtime) ?u64 {
        if (self.pending_finalization_jobs.len == 0) return null;
        return self.pending_finalization_jobs[0].sequence;
    }

    pub fn takePendingFinalizationJob(self: *Runtime) ?FinalizationJob {
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

    pub fn clearPendingFinalizationJobs(self: *Runtime) void {
        const jobs = self.pending_finalization_jobs;
        const capacity = self.pending_finalization_jobs_capacity;
        self.pending_finalization_jobs = &.{};
        self.pending_finalization_jobs_capacity = 0;
        for (jobs) |job| job.deinit(self);
        if (capacity != 0) {
            self.memory.free(FinalizationJob, jobs.ptr[0..capacity]);
        }
    }

    fn ensurePendingFinalizationJobCapacity(self: *Runtime, min_capacity: usize) !void {
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

    pub fn enqueueDeferredWeakValueFree(self: *Runtime, value: Value) !void {
        try self.enqueueDeferredWeakValueFreeWithPrequeuedIdentity(value, null);
    }

    pub fn enqueueDeferredWeakValueFreeWithPrequeuedIdentity(self: *Runtime, value: Value, prequeued_identity: ?usize) !void {
        const index = self.deferred_weak_value_frees.len;
        try self.ensureDeferredWeakValueFreeCapacity(index + 1);
        self.deferred_weak_value_frees = self.deferred_weak_value_frees.ptr[0 .. index + 1];
        self.deferred_weak_value_frees[index] = .{ .value = value, .prequeued_identity = prequeued_identity };
    }

    pub fn hasDeferredWeakValueFrees(self: *const Runtime) bool {
        return self.deferred_weak_value_frees.len != 0;
    }

    pub fn drainDeferredWeakValueFrees(self: *Runtime) void {
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

    fn ensureDeferredWeakValueFreeCapacity(self: *Runtime, min_capacity: usize) !void {
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

    pub fn beginBorrowedWeakCleanup(self: *Runtime) void {
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

    pub fn endBorrowedWeakCleanup(self: *Runtime) void {
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

    pub fn borrowedWeakCleanupActive(self: *const Runtime) bool {
        return self.borrowed_weak_cleanup_active;
    }

    pub fn markBorrowedWeakCleanupHolderSeen(self: *Runtime) void {
        self.borrowed_weak_cleanup_seen_holder = true;
    }

    pub fn borrowedWeakCleanupSeenHolder(self: *const Runtime) bool {
        return self.borrowed_weak_cleanup_seen_holder;
    }

    pub fn markBorrowedWeakCleanupNeedsRescan(self: *Runtime) void {
        self.borrowed_weak_cleanup_needs_rescan = true;
    }

    pub fn takeBorrowedWeakCleanupNeedsRescan(self: *Runtime) bool {
        const needs_rescan = self.borrowed_weak_cleanup_needs_rescan;
        self.borrowed_weak_cleanup_needs_rescan = false;
        return needs_rescan;
    }

    pub fn enqueueBorrowedWeakCleanupRealmIdentity(self: *Runtime, identity: usize) void {
        const index = self.borrowed_weak_cleanup_realm_identities.len;
        self.ensureBorrowedWeakCleanupRealmIdentityCapacity(index + 1) catch {
            self.borrowed_weak_cleanup_realm_identity_fallback = true;
            return;
        };
        self.borrowed_weak_cleanup_realm_identities = self.borrowed_weak_cleanup_realm_identities.ptr[0 .. index + 1];
        self.borrowed_weak_cleanup_realm_identities[index] = identity;
    }

    pub fn borrowedWeakCleanupRealmIdentityMatches(self: *const Runtime, identity: usize) bool {
        if (self.borrowed_weak_cleanup_realm_identity_fallback) return self.borrowedWeakCleanupIdentityMatches(identity);
        var index = self.borrowed_weak_cleanup_realm_identities.len;
        while (index != 0) {
            index -= 1;
            if (self.borrowed_weak_cleanup_realm_identities[index] == identity) return true;
        }
        return false;
    }

    pub fn borrowedWeakCleanupMayMatchRealmIdentity(self: *const Runtime) bool {
        return self.borrowed_weak_cleanup_realm_identity_fallback or self.borrowed_weak_cleanup_realm_identities.len != 0;
    }

    pub fn borrowedWeakCleanupIdentityCount(self: *const Runtime) usize {
        return self.borrowed_weak_cleanup_identities.len;
    }

    pub fn enqueueBorrowedWeakCleanupIdentity(self: *Runtime, identity: usize) !void {
        const index = self.borrowed_weak_cleanup_identities.len;
        try self.ensureBorrowedWeakCleanupIdentityCapacity(index + 1);
        self.borrowed_weak_cleanup_identities = self.borrowed_weak_cleanup_identities.ptr[0 .. index + 1];
        self.borrowed_weak_cleanup_identities[index] = identity;
    }

    pub fn enqueueBorrowedWeakCleanupIdentityForLastRefValue(self: *Runtime, value: Value) !void {
        const object = objectFromLastRefValue(value) orelse return;
        const identity = @intFromPtr(&object.header) & ~@as(usize, 1);
        if (object.is_global) self.enqueueBorrowedWeakCleanupRealmIdentity(identity);
        if (self.borrowed_weak_cleanup_seen_holder) self.markBorrowedWeakCleanupNeedsRescan();
        try self.enqueueBorrowedWeakCleanupIdentity(identity);
    }

    pub fn prequeueBorrowedWeakCleanupIdentityForLastRefValue(self: *Runtime, value: Value) ?usize {
        if (!self.borrowed_weak_cleanup_active) return null;
        const object = objectFromLastRefValue(value) orelse return null;
        const identity = @intFromPtr(&object.header) & ~@as(usize, 1);
        if (object.is_global) self.enqueueBorrowedWeakCleanupRealmIdentity(identity);
        if (self.borrowed_weak_cleanup_seen_holder) self.markBorrowedWeakCleanupNeedsRescan();
        self.enqueueBorrowedWeakCleanupIdentity(identity) catch return null;
        return identity;
    }

    pub fn borrowedWeakCleanupIdentityMatches(self: *const Runtime, identity: usize) bool {
        var index = self.borrowed_weak_cleanup_identities.len;
        while (index != 0) {
            index -= 1;
            if (self.borrowed_weak_cleanup_identities[index] == identity) return true;
        }
        return false;
    }

    pub fn isCurrentDeferredWeakValueFreeIdentity(self: *const Runtime, identity: usize) bool {
        return self.current_deferred_weak_value_free_identity == identity;
    }

    pub fn clearBorrowedWeakCleanupIdentities(self: *Runtime) void {
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

    fn ensureBorrowedWeakCleanupIdentityCapacity(self: *Runtime, min_capacity: usize) !void {
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

    fn ensureBorrowedWeakCleanupRealmIdentityCapacity(self: *Runtime, min_capacity: usize) !void {
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

fn objectFromLastRefValue(value: Value) ?*Object {
    const header = value.refHeader() orelse return null;
    if (header.kind != .object) return null;
    if (header.rc != 1) return null;
    return @alignCast(@fieldParentPtr("header", header));
}

fn valueMayContainNestedSymbolRoots(value: Value) bool {
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

fn appendRuntimeValue(account: *memory.MemoryAccount, slice: *[]Value, capacity: *usize, item: Value) !void {
    if (slice.*.len == capacity.*) {
        const next_capacity = if (capacity.* == 0) 4 else capacity.* * 2;
        const next = try account.alloc(Value, next_capacity);
        errdefer account.free(Value, next);
        @memcpy(next[0..slice.*.len], slice.*);
        const old_capacity = capacity.*;
        const old = if (old_capacity != 0) slice.*.ptr[0..old_capacity] else slice.*[0..0];
        slice.* = next[0..slice.*.len];
        capacity.* = next_capacity;
        if (old_capacity != 0) account.free(Value, old);
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

fn appendRuntimeValueRootFrame(account: *memory.MemoryAccount, slice: *[]*ValueRootFrame, capacity: *usize, item: *ValueRootFrame) !void {
    if (slice.*.len == capacity.*) {
        const next_capacity = if (capacity.* == 0) 4 else capacity.* * 2;
        const next = try account.alloc(*ValueRootFrame, next_capacity);
        errdefer account.free(*ValueRootFrame, next);
        @memcpy(next[0..slice.*.len], slice.*);
        const old_capacity = capacity.*;
        const old = if (old_capacity != 0) slice.*.ptr[0..old_capacity] else slice.*[0..0];
        slice.* = next[0..slice.*.len];
        capacity.* = next_capacity;
        if (old_capacity != 0) account.free(*ValueRootFrame, old);
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
