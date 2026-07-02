//! Z-GE (Garbage Engine) Core Implementation
//! Governing Layer: third_party/zjs/src/core/gc.zig
//! Following Z-GE Architecture Contract v1.0

const std = @import("std");
const builtin = @import("builtin");
const memory = @import("memory.zig");
const bigint = @import("bigint.zig");
const object = @import("object.zig");
const var_ref = @import("var_ref.zig");
const string = @import("string.zig");
const function_bytecode_mod = @import("../bytecode.zig").function_bytecode;
const FunctionBytecode = function_bytecode_mod.FunctionBytecode;
const shape = @import("shape.zig");

const KB: usize = 1024;
const MB: usize = 1024 * KB;
pub const logical_page_size: usize = 16 * KB;

pub const Mode = enum {
    balanced,
    throughput,
    low_rss,
    low_latency,
};

pub const Policy = struct {
    mode: Mode = .balanced,

    old_heap_growth_factor: f64 = 1.6,
    old_fragmentation_trigger: f64 = 0.45,
    old_fragmentation_trigger_per_mille: usize = 450,

    large_object_threshold: usize = 8 * KB,

    callback_slice_budget_ns: u64 = 300_000,
    idle_slice_budget_ns: u64 = 2_000_000,
    allocation_slow_path_budget_ns: u64 = 2_000_000,
    native_cleanup_slice_jobs: usize = 8,

    old_weight: usize = 4,
    large_weight: usize = 8,
    external_weight: usize = 8,
    major_debt_threshold: usize = 64 * MB,
    external_soft_limit: ?usize = null,
    external_hard_limit: ?usize = null,
    rss_soft_limit: ?usize = null,
    rss_hard_limit: ?usize = null,
    cgroup_soft_ratio_per_mille: usize = 0,
    cgroup_hard_ratio_per_mille: usize = 0,

    decommit_empty_pages: bool = true,
    retain_hot_empty_pages: usize = 64,

    enable_concurrent_mark: bool = false,
    enable_concurrent_sweep: bool = false,
    enable_selective_evacuation: bool = false,

    pub fn forMode(mode: Mode) Policy {
        var policy = Policy{
            .mode = mode,
        };
        switch (mode) {
            .balanced => {},
            .throughput => {
                policy.old_heap_growth_factor = 1.8;
                policy.callback_slice_budget_ns = 200_000;
                policy.idle_slice_budget_ns = 2_000_000;
                policy.allocation_slow_path_budget_ns = 2_000_000;
                policy.native_cleanup_slice_jobs = 16;
            },
            .low_rss => {
                policy.old_heap_growth_factor = 1.3;
                policy.callback_slice_budget_ns = 300_000;
                policy.idle_slice_budget_ns = 5_000_000;
                policy.decommit_empty_pages = true;
                policy.external_weight = 12;
                policy.native_cleanup_slice_jobs = 16;
                policy.cgroup_soft_ratio_per_mille = 850;
                policy.cgroup_hard_ratio_per_mille = 950;
            },
            .low_latency => {
                policy.callback_slice_budget_ns = 100_000;
                policy.idle_slice_budget_ns = 1_000_000;
                policy.allocation_slow_path_budget_ns = 500_000;
                policy.native_cleanup_slice_jobs = 4;
            },
        }
        return policy;
    }
};

pub const ExternalMemoryToken = struct {
    registry: ?*Registry = null,
    id: u64 = 0,
    bytes: usize = 0,

    pub fn release(self: *ExternalMemoryToken) void {
        const registry = self.registry orelse return;
        const id = self.id;
        const bytes = self.bytes;
        self.registry = null;
        self.id = 0;
        self.bytes = 0;
        registry.releaseExternalToken(id, bytes);
    }

    pub fn deinit(self: *ExternalMemoryToken) void {
        self.release();
    }
};

/// 6.2 BlockHeader / GcKind definition
pub const RefKind = enum(u8) {
    string = 0,
    object = 1,
    big_int = 2,
    function_bytecode = 3,
    var_ref = 4,
    shape = 5,
};

pub const GcKind = RefKind;
pub const ObjectKind = enum(u8) {
    object = 0,
    function_bytecode = 1,
    module = 2,
    shape = 3,
    string = 4,
};

pub const Phase = enum {
    none,
    decref,
    remove_cycles,
    deinit,
    cycle,
};

pub const MajorPhase = enum(u8) {
    idle,
    mark_roots,
    mark_incremental,
    weak_fixpoint,
    finalize_mark,
    sweep,
};

pub const PageState = enum(u8) {
    allocating,
    full,
    marking,
    needs_sweep,
    sweeping,
    swept,
    empty,
    decommitted,
};

pub const SchedulerPoint = enum(u8) {
    allocation_slow_path,
    callback_boundary,
    idle,
    safepoint,
    urgent,
};

pub const RequestReason = enum(u8) {
    manual,
    allocation_threshold,
    allocation_debt,
    external_memory,
    rss_pressure,
    collection_failed,
};

pub const RequestUrgency = enum(u8) {
    soon,
    urgent,
};

pub const Request = struct {
    pending: bool = false,
    reason: ?RequestReason = null,
    urgency: RequestUrgency = .soon,
};

pub const PressureRequest = struct {
    reason: RequestReason,
    urgency: RequestUrgency,
};

pub const ExternalTokenEntry = struct {
    id: u64 = 0,
    bytes: usize = 0,
};

pub const PinEntry = struct {
    header: *GCObjectHeader,
    count: usize = 0,
};

pub const SpaceAccount = struct {
    live_bytes: usize = 0,
    committed_bytes: usize = 0,
    free_bytes: usize = 0,
    decommitted_bytes: usize = 0,
    allocating_page_count: usize = 0,
    full_page_count: usize = 0,
    empty_page_count: usize = 0,
    decommitted_page_count: usize = 0,
    needs_sweep_page_count: usize = 0,
    evacuation_candidate_page_count: usize = 0,
    sweep_cursor_page: usize = 0,

    fn recordAlloc(self: *SpaceAccount, bytes: usize) void {
        if (bytes == 0) return;
        self.live_bytes = std.math.add(usize, self.live_bytes, bytes) catch std.math.maxInt(usize);
        if (self.free_bytes >= bytes) {
            self.free_bytes -= bytes;
            return;
        }

        const needed = bytes - self.free_bytes;
        self.free_bytes = 0;
        const committed = alignForwardSaturating(needed, logical_page_size);
        self.committed_bytes = std.math.add(usize, self.committed_bytes, committed) catch std.math.maxInt(usize);
        if (committed > needed) {
            self.free_bytes = std.math.add(usize, self.free_bytes, committed - needed) catch std.math.maxInt(usize);
        }
    }

    fn recordFree(self: *SpaceAccount, bytes: usize, retain_hot_empty_pages: usize, decommit_empty_pages: bool) void {
        if (bytes == 0) return;
        self.live_bytes -|= bytes;
        self.free_bytes = std.math.add(usize, self.free_bytes, bytes) catch std.math.maxInt(usize);
        if (decommit_empty_pages) self.trimFreePages(retain_hot_empty_pages);
    }

    fn trimFreePages(self: *SpaceAccount, retain_hot_empty_pages: usize) void {
        const retain_bytes = std.math.mul(usize, retain_hot_empty_pages, logical_page_size) catch std.math.maxInt(usize);
        if (self.free_bytes <= retain_bytes) return;
        const releasable = alignDown(self.free_bytes - retain_bytes, logical_page_size);
        if (releasable == 0) return;
        self.free_bytes -= releasable;
        self.committed_bytes -|= releasable;
        self.decommitted_bytes = std.math.add(usize, self.decommitted_bytes, releasable) catch std.math.maxInt(usize);
    }

    fn fragmentationPerMille(self: SpaceAccount) usize {
        return ratioPerMille(self.free_bytes, self.committed_bytes);
    }

    fn refreshPageState(self: *SpaceAccount, fragmentation_trigger_per_mille: usize) void {
        const committed_pages = self.committedPageCount();
        const empty_pages = @min(committed_pages, self.free_bytes / logical_page_size);
        const live_pages = @min(committed_pages, alignForwardSaturating(self.live_bytes, logical_page_size) / logical_page_size);
        self.empty_page_count = empty_pages;
        self.decommitted_page_count = self.decommitted_bytes / logical_page_size;
        self.full_page_count = @min(live_pages, self.live_bytes / logical_page_size);
        self.allocating_page_count = if (live_pages > self.full_page_count) 1 else 0;
        const fragmented_pages = committed_pages -| self.full_page_count -| self.empty_page_count -| self.allocating_page_count;
        self.evacuation_candidate_page_count = if (fragmentation_trigger_per_mille != 0 and self.fragmentationPerMille() >= fragmentation_trigger_per_mille)
            fragmented_pages
        else
            0;
        if (self.needs_sweep_page_count > committed_pages) self.needs_sweep_page_count = committed_pages;
        if (self.sweep_cursor_page > committed_pages) self.sweep_cursor_page = committed_pages;
    }

    fn startSweep(self: *SpaceAccount, fragmentation_trigger_per_mille: usize) void {
        self.refreshPageState(fragmentation_trigger_per_mille);
        self.needs_sweep_page_count = self.committedPageCount() -| self.empty_page_count -| self.decommitted_page_count;
        self.sweep_cursor_page = 0;
    }

    fn sweepSomePages(self: *SpaceAccount, max_pages: usize, fragmentation_trigger_per_mille: usize) usize {
        if (max_pages == 0 or self.needs_sweep_page_count == 0) return 0;
        const swept = @min(max_pages, self.needs_sweep_page_count);
        self.needs_sweep_page_count -= swept;
        self.sweep_cursor_page +|= swept;
        if (self.needs_sweep_page_count == 0) self.sweep_cursor_page = 0;
        self.refreshPageState(fragmentation_trigger_per_mille);
        return swept;
    }

    fn sweepAllPages(self: *SpaceAccount, fragmentation_trigger_per_mille: usize) usize {
        return self.sweepSomePages(std.math.maxInt(usize), fragmentation_trigger_per_mille);
    }

    fn cancelSweep(self: *SpaceAccount, fragmentation_trigger_per_mille: usize) void {
        self.needs_sweep_page_count = 0;
        self.sweep_cursor_page = 0;
        self.refreshPageState(fragmentation_trigger_per_mille);
    }

    fn committedPageCount(self: SpaceAccount) usize {
        return self.committed_bytes / logical_page_size;
    }
};

fn ratioPerMille(numerator: usize, denominator: usize) usize {
    if (denominator == 0) return 0;
    const scaled = std.math.mul(usize, numerator, 1000) catch std.math.maxInt(usize);
    return @min(@as(usize, 1000), scaled / denominator);
}

fn alignForwardSaturating(value: usize, alignment: usize) usize {
    if (value == 0) return 0;
    const rem = value % alignment;
    if (rem == 0) return value;
    return std.math.add(usize, value, alignment - rem) catch std.math.maxInt(usize);
}

fn alignDown(value: usize, alignment: usize) usize {
    return value - (value % alignment);
}

pub const BlockFlags = packed struct(u8) {
    mark: bool = false,
    in_cycle_list: bool = false,
    finalizing: bool = false,
    is_pinned: bool = false,
    /// Cycle-removal garbage flag (valid only during destroyRuntimeCyclesWithValueRoots;
    /// unconditionally re-initialized at the start of every cycle-removal round).
    /// `cycle_visited` = object is condemned garbage in the current round (it was still
    /// `mark`ed after gc_scan, i.e. not resurrected). Resurrection is carried purely by
    /// the `mark` bit (ScanIncrefVisitor clears `mark` on reachable objects, so they
    /// never get `cycle_visited` set); there is no separate "preserved" bit.
    cycle_visited: bool = false,
    _reserved: u3 = 0,
};

/// Z-GE v1.0 block header metadata. Phase 1: grouped into a sub-struct so a
/// later phase can relocate it to an allocator prefix. Layout/size unchanged.
/// qjs-style block-prefix metadata. Mirrors `JSMallocBlockHeader`
/// (quickjs.c:270): refcount + gc type + GC mark/cycle bits + heap-byte size
/// live in an 8-byte prefix that the allocator places immediately BEFORE the
/// object (at `objectPtr - 8`), so the in-object `BlockHeader` is just the
/// intrusive GC list links (= qjs `JSGCObjectHeader`, 16 bytes).
pub const Metadata = extern struct {
    size_class: u16 align(8) = 0,
    kind: GcKind = .object,
    flags: BlockFlags = .{},
    rc: i32 = 1,
};

/// Size of the metadata prefix that precedes every GC object (objectPtr - 8).
pub const metadata_prefix_size: usize = @sizeOf(Metadata);

comptime {
    // The allocator initializes the prefix by raw byte writes (memory.zig has no
    // gc import); these offsets must hold: kind at byte 2, rc (i32) at byte 4.
    std.debug.assert(@offsetOf(Metadata, "kind") == 2);
    std.debug.assert(@offsetOf(Metadata, "rc") == 4);
}

/// In-object GC header = intrusive list links only (qjs `JSGCObjectHeader`,
/// 16 bytes). The refcount / kind / flags / heap-size live in the `Metadata`
/// prefix 8 bytes before this header; reach them via `meta()`.
pub const BlockHeader = extern struct {
    prev: ?*BlockHeader = null,
    next: ?*BlockHeader = null,

    comptime {
        std.debug.assert(@sizeOf(BlockHeader) == 16);
        std.debug.assert(@sizeOf(Metadata) == 8);
    }

    pub inline fn meta(self: *BlockHeader) *Metadata {
        return @ptrFromInt(@intFromPtr(self) - metadata_prefix_size);
    }

    pub inline fn metaConst(self: *const BlockHeader) *const Metadata {
        return @ptrFromInt(@intFromPtr(self) - metadata_prefix_size);
    }

    pub inline fn retain(self: *BlockHeader) void {
        const m = self.meta();
        std.debug.assert(m.rc > 0);
        m.rc += 1;
    }

    pub fn pinned(self: *const BlockHeader) bool {
        return self.metaConst().flags.is_pinned;
    }

    pub fn setPinned(self: *BlockHeader, value: bool) void {
        self.meta().flags.is_pinned = value;
    }
};

/// Standalone refcount word for flat strings and string ropes. It is NOT
/// embedded in the `String`/`StringRope` structs (which stay at their exact qjs
/// sizes): each string/rope allocation reserves this 4-byte prefix immediately
/// ahead of the struct (`objectPtr - string_rc_prefix_size`), mirroring qjs's
/// `JSRefCountHeader` prefix. The struct reaches it through `String.header()` /
/// `StringRope.header()`, and a `Tag.string`/`Tag.string_rope`/`Tag.symbol`
/// JSValue's pointer payload IS this prefix.
pub const StringHeader = extern struct {
    rc: i32 = 1,

    comptime {
        std.debug.assert(@sizeOf(StringHeader) == 4);
    }

    pub inline fn retain(self: *StringHeader) void {
        std.debug.assert(self.rc > 0);
        self.rc += 1;
    }
};

/// Byte size of the refcount prefix reserved ahead of every flat `String` and
/// `StringRope` allocation. Equal to `@sizeOf(StringHeader)` (4).
pub const string_rc_prefix_size: usize = @sizeOf(StringHeader);

pub const Header = BlockHeader;
pub const GCObjectHeader = Header;
pub const ObjectHeader = Header;
const large_heap_size_class = std.math.maxInt(u16);

pub const FailureKind = enum(u8) {
    none = 0,
    out_of_memory = 1,
    payload_mark_failed = 2,
};

pub const CollectionError = error{
    OutOfMemory,
    PayloadMarkFailed,
};

pub const CollectionResult = struct {
    freed_objects: usize = 0,
    freed_bytecodes: usize = 0,
    duration_ns: u64 = 0,
};

const pause_sample_capacity: usize = 64;

const PauseSamples = struct {
    values: [pause_sample_capacity]u64 = [_]u64{0} ** pause_sample_capacity,
    len: usize = 0,
    next: usize = 0,

    fn record(self: *PauseSamples, duration_ns: u64) void {
        self.values[self.next] = duration_ns;
        self.next = (self.next + 1) % pause_sample_capacity;
        if (self.len < pause_sample_capacity) self.len += 1;
    }

    fn percentile(self: PauseSamples, per_mille: usize) u64 {
        if (self.len == 0) return 0;
        var scratch = self.values;
        const samples = scratch[0..self.len];
        std.mem.sort(u64, samples, {}, u64LessThan);
        const clamped = @min(per_mille, @as(usize, 1000));
        const rank = @max(@as(usize, 1), (clamped * self.len + 999) / 1000);
        return samples[@min(rank - 1, self.len - 1)];
    }
};

fn u64LessThan(_: void, lhs: u64, rhs: u64) bool {
    return lhs < rhs;
}

pub const InvariantError = error{
    CorruptGcList,
    NegativeRefCount,
    MarkBitLeftSet,
    DuplicateHeapAllocation,
    MissingHeapAllocation,
    HeapLiveBytesMismatch,
    OldLiveBytesMismatch,
    LargeObjectBytesMismatch,
    OldSpaceLiveBytesMismatch,
    LargeSpaceLiveBytesMismatch,
    OldSpaceCommittedBytesMismatch,
    LargeSpaceCommittedBytesMismatch,
    OldSpacePageStateMismatch,
    LargeSpacePageStateMismatch,
    DuplicateExternalMemoryToken,
    EmptyExternalMemoryToken,
    ExternalTokenBytesMismatch,
    LeakedExternalMemoryToken,
    DuplicatePinEntry,
    EmptyPinEntry,
    PinnedHeaderFlagMismatch,
};

/// 19. GE Stats
pub const GeStats = struct {
    rc_inc: usize = 0,
    rc_dec: usize = 0,
    zero_ref_drains: usize = 0,

    cycle_gc_count: usize = 0,
    cycle_gc_time_ns: u64 = 0,
    cycles_collected: usize = 0,
    failed_collections: usize = 0,
    last_failure: FailureKind = .none,
    last_collection_time_ns: u64 = 0,
    major_pause_samples: PauseSamples = .{},
    incremental_slice_samples: PauseSamples = .{},
    last_incremental_slice_ns: u64 = 0,
    major_slice_count: usize = 0,
    concurrent_mark_time_ns: u64 = 0,
    sweep_time_ns: u64 = 0,
    swept_page_count: usize = 0,
    last_swept_page_count: usize = 0,
    current_mark_stack_depth: usize = 0,
    mark_stack_peak: usize = 0,

    allocated_bytes: usize = 0,
    peak_allocated_bytes: usize = 0,
    heap_live_bytes: usize = 0,
    old_live_bytes: usize = 0,
    large_object_bytes: usize = 0,
    collections: usize = 0,
    freed_objects: usize = 0,

    old_allocated_bytes: usize = 0,
    old_alloc_count: usize = 0,
    large_allocated_bytes: usize = 0,
    large_alloc_count: usize = 0,

    external_bytes: usize = 0,
    external_untracked_bytes: usize = 0,
    peak_external_bytes: usize = 0,
    external_alloc_count: usize = 0,
    external_free_count: usize = 0,
    external_invalid_release_count: usize = 0,
    allocation_debt: usize = 0,
    gc_request_count: usize = 0,
    last_request_reason: ?RequestReason = null,
};

pub const Stats = struct {
    total_allocated_bytes: usize = 0,
    peak_allocated_bytes: usize = 0,
    heap_live_bytes: usize = 0,
    old_live_bytes: usize = 0,
    large_object_bytes: usize = 0,
    heap_committed_bytes: usize = 0,
    old_committed_bytes: usize = 0,
    old_empty_page_bytes: usize = 0,
    large_committed_bytes: usize = 0,
    large_empty_page_bytes: usize = 0,
    empty_page_bytes: usize = 0,
    decommitted_bytes: usize = 0,
    old_fragmentation_ratio: usize = 0,
    old_page_count: usize = 0,
    old_allocating_page_count: usize = 0,
    old_full_page_count: usize = 0,
    old_empty_page_count: usize = 0,
    old_decommitted_page_count: usize = 0,
    old_needs_sweep_page_count: usize = 0,
    old_sweep_cursor_page: usize = 0,
    old_evacuation_candidate_page_count: usize = 0,
    large_page_count: usize = 0,
    large_empty_page_count: usize = 0,
    large_decommitted_page_count: usize = 0,
    large_needs_sweep_page_count: usize = 0,
    rss_bytes: usize = 0,
    cgroup_limit_bytes: usize = 0,

    old_allocated_bytes: usize = 0,
    old_alloc_count: usize = 0,
    large_allocated_bytes: usize = 0,
    large_alloc_count: usize = 0,

    external_bytes: usize = 0,
    external_untracked_bytes: usize = 0,
    peak_external_bytes: usize = 0,
    external_alloc_count: usize = 0,
    external_free_count: usize = 0,
    external_token_count: usize = 0,
    external_token_bytes: usize = 0,
    external_invalid_release_count: usize = 0,
    allocation_debt: usize = 0,

    major_gc_count: usize = 0,
    major_gc_time_ns: u64 = 0,
    major_phase: MajorPhase = .idle,
    major_slice_count: usize = 0,
    last_incremental_slice_ns: u64 = 0,
    major_pause_ns_p50: u64 = 0,
    major_pause_ns_p95: u64 = 0,
    major_pause_ns_p99: u64 = 0,
    incremental_slice_ns_p50: u64 = 0,
    incremental_slice_ns_p95: u64 = 0,
    incremental_slice_ns_p99: u64 = 0,
    concurrent_mark_time_ns: u64 = 0,
    sweep_time_ns: u64 = 0,
    swept_page_count: usize = 0,
    last_swept_page_count: usize = 0,
    mark_stack_peak: usize = 0,
    failed_collections: usize = 0,
    last_failure: FailureKind = .none,
    freed_objects: usize = 0,

    pinned_cell_count: usize = 0,
    weak_ref_count: usize = 0,
    finalizer_queue_length: usize = 0,
    pending_finalization_job_count: usize = 0,
    deferred_native_cleanup_count: usize = 0,
    deferred_native_cleanup_run_count: usize = 0,
    deferred_class_payload_finalizer_count: usize = 0,
    deferred_class_payload_finalizer_run_count: usize = 0,

    gc_request_count: usize = 0,
    pending_major: bool = false,
    pending_request_reason: ?RequestReason = null,
    pending_request_urgency: ?RequestUrgency = null,
    last_request_reason: ?RequestReason = null,
};

/// Z-GE Registry
pub const Registry = struct {
    memory: *memory.MemoryAccount,
    policy: Policy = .{},

    // qjs-style cycle-collection candidates (Object, FunctionBytecode, VarRef):
    // each GC object header embeds its permanent list node, so add/remove are
    // O(1) pointer splices.
    gc_object_head: ?*GCObjectHeader = null,
    gc_object_tail: ?*GCObjectHeader = null,
    gc_object_count: usize = 0,
    external_tokens: []ExternalTokenEntry = &.{},
    external_tokens_capacity: usize = 0,
    next_external_token_id: u64 = 1,
    pin_entries: []PinEntry = &.{},
    pin_entries_capacity: usize = 0,

    phase: Phase = .none,
    major_phase: MajorPhase = .idle,
    major_reason: ?RequestReason = null,
    major_epoch: u64 = 0,
    major_started_ns: u64 = 0,
    major_request: Request = .{},
    old_space: SpaceAccount = .{},
    large_space: SpaceAccount = .{},
    stats: GeStats = .{},

    // Reusable structures for cycle detection
    preserved_bytecodes: std.AutoHashMap(usize, void),
    object_worklist: std.ArrayList(*object.Object),
    var_ref_worklist: std.ArrayList(*var_ref.VarRef),
    bytecode_worklist: std.ArrayList(*FunctionBytecode),
    // Pass-B struct-free deferral for cycle removal (qjs gc_zero_ref_count_list,
    // quickjs.c:6382/6797): during JS_GC_PHASE_REMOVE_CYCLES an object's
    // resources are torn down but its struct memory survives until every sibling
    // in the batch has run, so a sibling finalizer/decref never dereferences a
    // freed struct. The batch driver drains this list after the resource pass.
    cycle_deferred_frees: std.ArrayList(*GCObjectHeader),

    pub fn init(account: *memory.MemoryAccount, policy: Policy) Registry {
        return .{
            .memory = account,
            .policy = policy,
            .old_space = .{},
            .large_space = .{},
            .preserved_bytecodes = std.AutoHashMap(usize, void).init(account.persistent_allocator),
            .object_worklist = std.ArrayList(*object.Object).empty,
            .var_ref_worklist = std.ArrayList(*var_ref.VarRef).empty,
            .bytecode_worklist = std.ArrayList(*FunctionBytecode).empty,
            .cycle_deferred_frees = std.ArrayList(*GCObjectHeader).empty,
        };
    }

    /// Reserve capacity so `deferCycleStructFree` cannot fail mid-batch (a failed
    /// defer would have to choose between an unsafe immediate free or a leak).
    pub fn reserveCycleDeferred(self: *Registry, capacity: usize) !void {
        try self.cycle_deferred_frees.ensureTotalCapacity(self.memory.persistent_allocator, capacity);
    }

    /// Park a resource-stripped GC object's struct for the Pass-B drain. The
    /// header is already unlinked from the GC object list by the resource pass.
    pub fn deferCycleStructFree(self: *Registry, header: *GCObjectHeader) void {
        self.cycle_deferred_frees.append(self.memory.persistent_allocator, header) catch {
            // Capacity was reserved up-front; reaching here means OOM. Leaking the
            // struct is the only memory-safe fallback (freeing now risks the very
            // use-after-free this deferral prevents).
        };
    }

    pub fn deinit(self: *Registry, rt: anytype) void {
        self.phase = .deinit;

        // Phase 1: free every non-shape GC object. Shapes are spliced out of the
        // GC list into a holding stack (reusing their now-unused `next` link) so
        // they outlive every object that still owns a shape_ref — destroying a
        // shape early would have those object destructors release freed memory.
        // (qjs avoids the ordering hazard via its mark/decref cycle collector;
        // we keep zjs's explicit teardown but defer shapes to a second pass.)
        var held_shapes: ?*GCObjectHeader = null;
        while (self.gc_object_tail) |h| {
            if (h.meta().kind == .shape) {
                self.removeGcObject(h);
                h.next = held_shapes;
                held_shapes = h;
                continue;
            }
            self.removeGcObject(h);
            self.recordHeapFreeWithBytes(h, heapByteSizeFromHeader(rt, h));
            h.meta().flags.finalizing = true;
            if (h.meta().kind == .object) {
                object.Object.destroyFromHeader(rt, h);
                rt.drainDeferredClassPayloadFinalizers();
            } else if (h.meta().kind == .function_bytecode) {
                function_bytecode_mod.destroyFromHeader(rt, h);
            }
        }

        // Phase 2: now every object is gone, so destroying the held shapes can no
        // longer dangle a shape_ref. `destroyShape` self-removes from the GC list
        // (guarded no-op here) and frees property storage + bucket links.
        while (held_shapes) |h| {
            const next = h.next;
            h.next = null;
            rt.shapes.destroyFromHeader(h);
            held_shapes = next;
        }

        rt.shapes.deinit();

        self.gc_object_head = null;
        self.gc_object_tail = null;
        self.gc_object_count = 0;

        self.preserved_bytecodes.deinit();
        self.object_worklist.deinit(self.memory.persistent_allocator);
        self.var_ref_worklist.deinit(self.memory.persistent_allocator);
        self.bytecode_worklist.deinit(self.memory.persistent_allocator);
        self.cycle_deferred_frees.deinit(self.memory.persistent_allocator);
        if (self.external_tokens_capacity != 0) {
            self.memory.free(ExternalTokenEntry, self.external_tokens.ptr[0..self.external_tokens_capacity]);
        } else if (self.external_tokens.len != 0) {
            self.memory.free(ExternalTokenEntry, self.external_tokens);
        }
        self.external_tokens = &.{};
        self.external_tokens_capacity = 0;
        if (self.pin_entries_capacity != 0) {
            self.memory.free(PinEntry, self.pin_entries.ptr[0..self.pin_entries_capacity]);
        } else if (self.pin_entries.len != 0) {
            self.memory.free(PinEntry, self.pin_entries);
        }
        self.pin_entries = &.{};
        self.pin_entries_capacity = 0;

        self.phase = .none;
    }

    pub fn reportExternalAlloc(self: *Registry, bytes: usize) !ExternalMemoryToken {
        if (bytes == 0) return .{};
        try self.ensureExternalTokenCapacity(self.external_tokens.len + 1);
        const id = self.nextExternalTokenId();
        self.external_tokens.ptr[self.external_tokens.len] = .{
            .id = id,
            .bytes = bytes,
        };
        self.external_tokens = self.external_tokens.ptr[0 .. self.external_tokens.len + 1];
        self.stats.external_bytes = std.math.add(usize, self.stats.external_bytes, bytes) catch std.math.maxInt(usize);
        self.stats.peak_external_bytes = @max(self.stats.peak_external_bytes, self.stats.external_bytes);
        self.stats.external_alloc_count +|= 1;
        const weighted = std.math.mul(usize, bytes, self.policy.external_weight) catch std.math.maxInt(usize);
        self.stats.allocation_debt = std.math.add(usize, self.stats.allocation_debt, weighted) catch std.math.maxInt(usize);
        return .{
            .registry = self,
            .id = id,
            .bytes = bytes,
        };
    }

    pub fn reportExternalAllocUntracked(self: *Registry, bytes: usize) void {
        if (bytes == 0) return;
        self.stats.external_bytes = std.math.add(usize, self.stats.external_bytes, bytes) catch std.math.maxInt(usize);
        self.stats.external_untracked_bytes = std.math.add(usize, self.stats.external_untracked_bytes, bytes) catch std.math.maxInt(usize);
        self.stats.peak_external_bytes = @max(self.stats.peak_external_bytes, self.stats.external_bytes);
        self.stats.external_alloc_count +|= 1;
        const weighted = std.math.mul(usize, bytes, self.policy.external_weight) catch std.math.maxInt(usize);
        self.stats.allocation_debt = std.math.add(usize, self.stats.allocation_debt, weighted) catch std.math.maxInt(usize);
    }

    pub fn reportExternalFree(self: *Registry, bytes: usize) void {
        if (bytes == 0) return;
        self.stats.external_bytes -|= bytes;
        self.stats.external_free_count +|= 1;
    }

    pub fn reportExternalFreeUntracked(self: *Registry, bytes: usize) void {
        if (bytes == 0) return;
        self.stats.external_bytes -|= bytes;
        self.stats.external_untracked_bytes -|= bytes;
        self.stats.external_free_count +|= 1;
    }

    pub fn releaseExternalToken(self: *Registry, id: u64, bytes: usize) void {
        if (id == 0 or bytes == 0) {
            if (id != 0 or bytes != 0) self.stats.external_invalid_release_count +|= 1;
            return;
        }
        const index = self.externalTokenIndex(id) orelse {
            self.stats.external_invalid_release_count +|= 1;
            return;
        };
        const entry = self.external_tokens[index];
        if (entry.bytes != bytes) {
            self.stats.external_invalid_release_count +|= 1;
            return;
        }
        self.stats.external_bytes -|= entry.bytes;
        self.stats.external_free_count +|= 1;
        if (index + 1 < self.external_tokens.len) {
            std.mem.copyForwards(
                ExternalTokenEntry,
                self.external_tokens[index .. self.external_tokens.len - 1],
                self.external_tokens[index + 1 ..],
            );
        }
        self.external_tokens = self.external_tokens[0 .. self.external_tokens.len - 1];
    }

    pub fn externalMemoryRequestReason(self: Registry) ?RequestReason {
        if (self.policy.external_hard_limit) |limit| {
            if (self.stats.external_bytes >= limit) return .external_memory;
        }
        if (self.stats.allocation_debt >= self.policy.major_debt_threshold) return .allocation_debt;
        if (self.policy.external_soft_limit) |limit| {
            if (self.stats.external_bytes >= limit) return .external_memory;
        }
        return null;
    }

    pub fn externalMemoryRequestUrgency(self: Registry) RequestUrgency {
        if (self.policy.external_hard_limit) |limit| {
            if (self.stats.external_bytes >= limit) return .urgent;
        }
        return .soon;
    }

    pub fn processMemoryRequest(self: Registry, rss_bytes: usize, cgroup_limit_bytes: usize) ?PressureRequest {
        if (self.policy.rss_hard_limit) |limit| {
            if (rss_bytes >= limit) return .{ .reason = .rss_pressure, .urgency = .urgent };
        }
        if (self.policy.cgroup_hard_ratio_per_mille != 0 and cgroup_limit_bytes != 0 and ratioPerMille(rss_bytes, cgroup_limit_bytes) >= self.policy.cgroup_hard_ratio_per_mille) {
            return .{ .reason = .rss_pressure, .urgency = .urgent };
        }
        if (self.policy.rss_soft_limit) |limit| {
            if (rss_bytes >= limit) return .{ .reason = .rss_pressure, .urgency = .soon };
        }
        if (self.policy.cgroup_soft_ratio_per_mille != 0 and cgroup_limit_bytes != 0 and ratioPerMille(rss_bytes, cgroup_limit_bytes) >= self.policy.cgroup_soft_ratio_per_mille) {
            return .{ .reason = .rss_pressure, .urgency = .soon };
        }
        return null;
    }

    pub fn decommitEmptyPagesNow(self: *Registry) void {
        self.old_space.trimFreePages(0);
        self.large_space.trimFreePages(0);
        self.refreshSpacePageState();
    }

    pub fn requestGC(self: *Registry, reason: RequestReason, urgency: RequestUrgency) void {
        self.stats.gc_request_count +|= 1;
        self.stats.last_request_reason = reason;
        const slot = &self.major_request;
        if (!slot.pending) {
            slot.* = .{
                .pending = true,
                .reason = reason,
                .urgency = urgency,
            };
            return;
        }
        if (urgency == .urgent and slot.urgency != .urgent) {
            slot.urgency = .urgent;
            slot.reason = reason;
            return;
        }
        if (slot.reason == null) slot.reason = reason;
    }

    pub fn hasPendingRequest(self: Registry) bool {
        return self.major_request.pending;
    }

    pub fn hasPendingMajorRequest(self: Registry) bool {
        return self.major_request.pending;
    }

    pub fn pendingMajorRequest(self: Registry) ?Request {
        return if (self.major_request.pending) self.major_request else null;
    }

    pub fn clearMajorRequest(self: *Registry) ?Request {
        if (!self.major_request.pending) return null;
        const request = self.major_request;
        self.major_request = .{};
        return request;
    }

    pub fn sliceBudgetNs(self: Registry, point: SchedulerPoint) u64 {
        return switch (point) {
            .allocation_slow_path => self.policy.allocation_slow_path_budget_ns,
            .callback_boundary, .safepoint => self.policy.callback_slice_budget_ns,
            .idle => self.policy.idle_slice_budget_ns,
            .urgent => self.policy.allocation_slow_path_budget_ns,
        };
    }

    pub fn shouldRunMajorAt(self: Registry, point: SchedulerPoint, over_threshold: bool) bool {
        if (point == .urgent or over_threshold) return true;
        const request = self.pendingMajorRequest() orelse return false;
        return switch (point) {
            .allocation_slow_path, .idle => true,
            .callback_boundary, .safepoint => request.urgency == .urgent,
            .urgent => true,
        };
    }

    pub fn beginMajorCycle(self: *Registry, reason: RequestReason, start_ns: u64) void {
        if (self.major_phase != .idle) {
            if (self.major_reason == null) self.major_reason = reason;
            return;
        }
        self.major_phase = .mark_roots;
        self.major_reason = reason;
        self.major_epoch +%= 1;
        self.major_started_ns = start_ns;
        self.stats.current_mark_stack_depth = 0;
        self.old_space.startSweep(self.fragmentationTriggerPerMille());
        self.large_space.startSweep(self.fragmentationTriggerPerMille());
    }

    pub fn setMajorPhase(self: *Registry, phase: MajorPhase) void {
        if (self.major_phase == .idle and phase != .idle) return;
        self.major_phase = phase;
    }

    pub fn activeMajorReason(self: Registry) ?RequestReason {
        return self.major_reason;
    }

    pub fn abortMajorCycle(self: *Registry) void {
        self.major_phase = .idle;
        self.major_reason = null;
        self.major_started_ns = 0;
        self.stats.current_mark_stack_depth = 0;
        self.old_space.cancelSweep(self.fragmentationTriggerPerMille());
        self.large_space.cancelSweep(self.fragmentationTriggerPerMille());
    }

    pub fn finishMajorCycle(self: *Registry, result: CollectionResult) void {
        self.recordIncrementalSlice(result.duration_ns);
        const swept_pages = self.old_space.sweepAllPages(self.fragmentationTriggerPerMille()) +| self.large_space.sweepAllPages(self.fragmentationTriggerPerMille());
        self.stats.last_swept_page_count = swept_pages;
        self.stats.swept_page_count +|= swept_pages;
        self.stats.sweep_time_ns +|= result.duration_ns;
        self.major_phase = .idle;
        self.major_reason = null;
        self.major_started_ns = 0;
        self.stats.current_mark_stack_depth = 0;
    }

    pub fn recordIncrementalSlice(self: *Registry, duration_ns: u64) void {
        self.stats.last_incremental_slice_ns = duration_ns;
        self.stats.major_slice_count +|= 1;
        self.stats.incremental_slice_samples.record(duration_ns);
    }

    pub fn recordMarkStackDepth(self: *Registry, depth: usize) void {
        self.stats.current_mark_stack_depth = depth;
        self.stats.mark_stack_peak = @max(self.stats.mark_stack_peak, depth);
    }

    pub fn clearMarkStackDepth(self: *Registry) void {
        self.stats.current_mark_stack_depth = 0;
    }

    fn refreshSpacePageState(self: *Registry) void {
        const trigger = self.fragmentationTriggerPerMille();
        self.old_space.refreshPageState(trigger);
        self.large_space.refreshPageState(trigger);
    }

    fn fragmentationTriggerPerMille(self: Registry) usize {
        return self.policy.old_fragmentation_trigger_per_mille;
    }

    pub fn resetAllocationDebt(self: *Registry) void {
        self.stats.allocation_debt = 0;
    }

    pub fn statsSnapshot(self: Registry) Stats {
        return .{
            .total_allocated_bytes = self.stats.allocated_bytes,
            .peak_allocated_bytes = self.stats.peak_allocated_bytes,
            .heap_live_bytes = self.stats.heap_live_bytes,
            .old_live_bytes = self.stats.old_live_bytes,
            .large_object_bytes = self.stats.large_object_bytes,
            .heap_committed_bytes = self.old_space.committed_bytes +| self.large_space.committed_bytes,
            .old_committed_bytes = self.old_space.committed_bytes,
            .old_empty_page_bytes = self.old_space.free_bytes,
            .large_committed_bytes = self.large_space.committed_bytes,
            .large_empty_page_bytes = self.large_space.free_bytes,
            .empty_page_bytes = self.old_space.free_bytes +| self.large_space.free_bytes,
            .decommitted_bytes = self.old_space.decommitted_bytes +| self.large_space.decommitted_bytes,
            .old_fragmentation_ratio = self.old_space.fragmentationPerMille(),
            .old_page_count = self.old_space.committedPageCount(),
            .old_allocating_page_count = self.old_space.allocating_page_count,
            .old_full_page_count = self.old_space.full_page_count,
            .old_empty_page_count = self.old_space.empty_page_count,
            .old_decommitted_page_count = self.old_space.decommitted_page_count,
            .old_needs_sweep_page_count = self.old_space.needs_sweep_page_count,
            .old_sweep_cursor_page = self.old_space.sweep_cursor_page,
            .old_evacuation_candidate_page_count = self.old_space.evacuation_candidate_page_count,
            .large_page_count = self.large_space.committedPageCount(),
            .large_empty_page_count = self.large_space.empty_page_count,
            .large_decommitted_page_count = self.large_space.decommitted_page_count,
            .large_needs_sweep_page_count = self.large_space.needs_sweep_page_count,
            .old_allocated_bytes = self.stats.old_allocated_bytes,
            .old_alloc_count = self.stats.old_alloc_count,
            .large_allocated_bytes = self.stats.large_allocated_bytes,
            .large_alloc_count = self.stats.large_alloc_count,
            .external_bytes = self.stats.external_bytes,
            .external_untracked_bytes = self.stats.external_untracked_bytes,
            .peak_external_bytes = self.stats.peak_external_bytes,
            .external_alloc_count = self.stats.external_alloc_count,
            .external_free_count = self.stats.external_free_count,
            .external_token_count = self.external_tokens.len,
            .external_token_bytes = self.externalTokenBytes(),
            .external_invalid_release_count = self.stats.external_invalid_release_count,
            .allocation_debt = self.stats.allocation_debt,
            .major_gc_count = self.stats.cycle_gc_count,
            .major_gc_time_ns = self.stats.cycle_gc_time_ns,
            .major_phase = self.major_phase,
            .major_slice_count = self.stats.major_slice_count,
            .last_incremental_slice_ns = self.stats.last_incremental_slice_ns,
            .major_pause_ns_p50 = self.stats.major_pause_samples.percentile(500),
            .major_pause_ns_p95 = self.stats.major_pause_samples.percentile(950),
            .major_pause_ns_p99 = self.stats.major_pause_samples.percentile(990),
            .incremental_slice_ns_p50 = self.stats.incremental_slice_samples.percentile(500),
            .incremental_slice_ns_p95 = self.stats.incremental_slice_samples.percentile(950),
            .incremental_slice_ns_p99 = self.stats.incremental_slice_samples.percentile(990),
            .concurrent_mark_time_ns = self.stats.concurrent_mark_time_ns,
            .sweep_time_ns = self.stats.sweep_time_ns,
            .swept_page_count = self.stats.swept_page_count,
            .last_swept_page_count = self.stats.last_swept_page_count,
            .mark_stack_peak = self.stats.mark_stack_peak,
            .failed_collections = self.stats.failed_collections,
            .last_failure = self.stats.last_failure,
            .freed_objects = self.stats.freed_objects,
            .pinned_cell_count = self.pin_entries.len,
            .gc_request_count = self.stats.gc_request_count,
            .pending_major = self.major_request.pending,
            .pending_request_reason = if (self.major_request.pending) self.major_request.reason else null,
            .pending_request_urgency = if (self.major_request.pending) self.major_request.urgency else null,
            .last_request_reason = self.stats.last_request_reason,
        };
    }

    pub fn add(self: *Registry, h: *GCObjectHeader) !void {
        try self.addWithSize(h, defaultHeapBytes(h));
    }

    pub fn addWithSize(self: *Registry, h: *GCObjectHeader, bytes: usize) !void {
        const is_large = self.isLargeAllocation(bytes);
        const tracked = isCycleCandidate(h);

        h.meta().rc = 1;
        h.meta().flags = .{};
        h.prev = null;
        h.next = null;
        h.meta().size_class = encodeHeapBytes(bytes);
        self.recordHeapAlloc(is_large, bytes);

        if (tracked) self.appendGcObject(h);
    }

    fn defaultHeapBytes(h: *const GCObjectHeader) usize {
        return switch (h.metaConst().kind) {
            .object => @sizeOf(object.Object),
            .function_bytecode => @sizeOf(FunctionBytecode),
            .var_ref => @sizeOf(var_ref.VarRef),
            // A shape's heap footprint includes its inline FAM (hash table +
            // prop[]); recompute from the live capacity fields (qjs get_shape_size).
            .shape => blk: {
                const sh: *const shape.Shape = @alignCast(@fieldParentPtr("header", h));
                break :blk sh.allocationSize();
            },
            .string, .big_int => 0,
        };
    }

    fn encodeHeapBytes(bytes: usize) u16 {
        return @intCast(@min(bytes, large_heap_size_class));
    }

    fn storedHeapBytes(h: *const GCObjectHeader) ?usize {
        if (h.metaConst().size_class == 0) return 0;
        if (h.metaConst().size_class == large_heap_size_class) return null;
        return h.metaConst().size_class;
    }

    pub fn heapByteSizeFromHeader(rt: anytype, h: *const GCObjectHeader) usize {
        if (storedHeapBytes(h)) |bytes| return bytes;
        return switch (h.metaConst().kind) {
            .object => blk: {
                const obj: *const object.Object = @alignCast(@fieldParentPtr("header", h));
                break :blk obj.allocationSize(rt);
            },
            .function_bytecode => blk: {
                const fb: *const FunctionBytecode = @alignCast(@fieldParentPtr("header", h));
                break :blk fb.heapByteSize();
            },
            .var_ref => @sizeOf(var_ref.VarRef),
            .shape => blk: {
                const sh: *const shape.Shape = @alignCast(@fieldParentPtr("header", h));
                break :blk sh.allocationSize();
            },
            .string, .big_int => 0,
        };
    }

    fn isLargeAllocation(self: Registry, bytes: usize) bool {
        return bytes != 0 and bytes >= self.policy.large_object_threshold;
    }

    fn isCycleCandidate(h: *const GCObjectHeader) bool {
        return h.metaConst().kind == .object or h.metaConst().kind == .function_bytecode or h.metaConst().kind == .var_ref or h.metaConst().kind == .shape;
    }

    fn recordHeapAlloc(self: *Registry, is_large: bool, bytes: usize) void {
        if (bytes == 0) return;
        self.stats.allocated_bytes = std.math.add(usize, self.stats.allocated_bytes, bytes) catch std.math.maxInt(usize);
        self.stats.peak_allocated_bytes = @max(self.stats.peak_allocated_bytes, self.stats.allocated_bytes);
        self.addLiveHeapBytes(is_large, bytes);
        self.recordSpaceAlloc(is_large, bytes);
        const kind_weight = if (is_large) self.policy.large_weight else self.policy.old_weight;
        const weighted = std.math.mul(usize, bytes, kind_weight) catch std.math.maxInt(usize);
        self.stats.allocation_debt = std.math.add(usize, self.stats.allocation_debt, weighted) catch std.math.maxInt(usize);

        if (is_large) {
            self.stats.large_allocated_bytes = std.math.add(usize, self.stats.large_allocated_bytes, bytes) catch std.math.maxInt(usize);
            self.stats.large_alloc_count +|= 1;
        } else {
            self.stats.old_allocated_bytes = std.math.add(usize, self.stats.old_allocated_bytes, bytes) catch std.math.maxInt(usize);
            self.stats.old_alloc_count +|= 1;
        }
    }

    fn recordHeapFreeWithBytes(self: *Registry, header: *GCObjectHeader, bytes: usize) void {
        if (header.meta().size_class == 0 or bytes == 0) return;
        const is_large = self.isLargeAllocation(bytes);
        self.subtractLiveHeapBytes(is_large, bytes);
        self.recordSpaceFree(is_large, bytes);
        header.meta().size_class = 0;
    }

    pub fn pinHeader(self: *Registry, header: *GCObjectHeader) !void {
        if (self.pinEntryIndex(header)) |index| {
            self.pin_entries[index].count +|= 1;
            return;
        }
        try self.ensurePinEntryCapacity(self.pin_entries.len + 1);
        self.pin_entries.ptr[self.pin_entries.len] = .{
            .header = header,
            .count = 1,
        };
        self.pin_entries = self.pin_entries.ptr[0 .. self.pin_entries.len + 1];
        header.setPinned(true);
    }

    pub fn unpinHeader(self: *Registry, header: *GCObjectHeader) void {
        const index = self.pinEntryIndex(header) orelse return;
        if (self.pin_entries[index].count > 1) {
            self.pin_entries[index].count -= 1;
            return;
        }
        if (index + 1 < self.pin_entries.len) {
            std.mem.copyForwards(
                PinEntry,
                self.pin_entries[index .. self.pin_entries.len - 1],
                self.pin_entries[index + 1 ..],
            );
        }
        self.pin_entries = self.pin_entries[0 .. self.pin_entries.len - 1];
        header.setPinned(false);
    }

    fn addLiveHeapBytes(self: *Registry, is_large: bool, bytes: usize) void {
        self.stats.heap_live_bytes = std.math.add(usize, self.stats.heap_live_bytes, bytes) catch std.math.maxInt(usize);
        if (is_large) {
            self.stats.large_object_bytes = std.math.add(usize, self.stats.large_object_bytes, bytes) catch std.math.maxInt(usize);
        } else {
            self.stats.old_live_bytes = std.math.add(usize, self.stats.old_live_bytes, bytes) catch std.math.maxInt(usize);
        }
    }

    fn subtractLiveHeapBytes(self: *Registry, is_large: bool, bytes: usize) void {
        self.stats.heap_live_bytes -|= bytes;
        if (is_large) {
            self.stats.large_object_bytes -|= bytes;
        } else {
            self.stats.old_live_bytes -|= bytes;
        }
    }

    fn recordSpaceAlloc(self: *Registry, is_large: bool, bytes: usize) void {
        if (is_large) {
            self.large_space.recordAlloc(bytes);
        } else {
            self.old_space.recordAlloc(bytes);
        }
        self.refreshSpacePageState();
    }

    fn recordSpaceFree(self: *Registry, is_large: bool, bytes: usize) void {
        if (is_large) {
            self.large_space.recordFree(bytes, 0, self.policy.decommit_empty_pages);
        } else {
            self.old_space.recordFree(bytes, self.policy.retain_hot_empty_pages, self.policy.decommit_empty_pages);
        }
        self.refreshSpacePageState();
    }

    fn externalTokenIndex(self: Registry, id: u64) ?usize {
        for (self.external_tokens, 0..) |entry, index| {
            if (entry.id == id) return index;
        }
        return null;
    }

    fn nextExternalTokenId(self: *Registry) u64 {
        const id = self.next_external_token_id;
        self.next_external_token_id +%= 1;
        if (self.next_external_token_id == 0) self.next_external_token_id = 1;
        return id;
    }

    fn pinEntryIndex(self: Registry, header: *const GCObjectHeader) ?usize {
        for (self.pin_entries, 0..) |entry, index| {
            if (entry.header == header) return index;
        }
        return null;
    }

    pub fn externalTokenBytes(self: Registry) usize {
        var total: usize = 0;
        for (self.external_tokens) |entry| {
            total = std.math.add(usize, total, entry.bytes) catch std.math.maxInt(usize);
        }
        return total;
    }

    pub fn unlinkObjectWithBytes(self: *Registry, h: *GCObjectHeader, bytes: usize) void {
        self.recordHeapFreeWithBytes(h, bytes);
        if (isCycleCandidate(h)) self.removeGcObject(h);
    }

    pub fn unlinkObject(self: *Registry, h: *GCObjectHeader) void {
        const bytes = storedHeapBytes(h) orelse defaultHeapBytes(h);
        self.unlinkObjectWithBytes(h, bytes);
    }

    pub fn retainObject(self: *Registry, h: *GCObjectHeader) void {
        _ = self;
        h.retain();
    }

    pub fn releaseObject(self: *Registry, h: *GCObjectHeader) bool {
        std.debug.assert(h.meta().rc > 0);
        h.meta().rc -= 1;
        self.stats.rc_dec += 1;

        if (h.meta().rc == 0) {
            self.unlinkObject(h);
            return true;
        }
        return false;
    }

    fn ensureExternalTokenCapacity(self: *Registry, required: usize) !void {
        if (required <= self.external_tokens_capacity) return;
        var new_capacity = if (self.external_tokens_capacity == 0) @as(usize, 8) else self.external_tokens_capacity * 2;
        while (new_capacity < required) new_capacity *= 2;
        const next = try self.memory.alloc(ExternalTokenEntry, new_capacity);
        errdefer self.memory.free(ExternalTokenEntry, next);
        @memcpy(next[0..self.external_tokens.len], self.external_tokens);
        if (self.external_tokens_capacity != 0) {
            self.memory.free(ExternalTokenEntry, self.external_tokens.ptr[0..self.external_tokens_capacity]);
        } else if (self.external_tokens.len != 0) {
            self.memory.free(ExternalTokenEntry, self.external_tokens);
        }
        self.external_tokens = next[0..self.external_tokens.len];
        self.external_tokens_capacity = new_capacity;
    }

    fn ensurePinEntryCapacity(self: *Registry, required: usize) !void {
        if (required <= self.pin_entries_capacity) return;
        var new_capacity = if (self.pin_entries_capacity == 0) @as(usize, 8) else self.pin_entries_capacity * 2;
        while (new_capacity < required) new_capacity *= 2;
        const next = try self.memory.alloc(PinEntry, new_capacity);
        errdefer self.memory.free(PinEntry, next);
        @memcpy(next[0..self.pin_entries.len], self.pin_entries);
        if (self.pin_entries_capacity != 0) {
            self.memory.free(PinEntry, self.pin_entries.ptr[0..self.pin_entries_capacity]);
        } else if (self.pin_entries.len != 0) {
            self.memory.free(PinEntry, self.pin_entries);
        }
        self.pin_entries = next[0..self.pin_entries.len];
        self.pin_entries_capacity = new_capacity;
    }

    pub const GcObjectIterator = struct {
        cursor: ?*GCObjectHeader,

        pub fn next(self: *GcObjectIterator) ?*GCObjectHeader {
            const current = self.cursor orelse return null;
            self.cursor = current.next;
            return current;
        }
    };

    pub fn objectIterator(self: *const Registry) GcObjectIterator {
        return .{ .cursor = self.gc_object_head };
    }

    fn appendGcObject(self: *Registry, header: *GCObjectHeader) void {
        std.debug.assert(isCycleCandidate(header));
        std.debug.assert(header.prev == null);
        std.debug.assert(header.next == null);

        header.prev = self.gc_object_tail;
        header.next = null;
        if (self.gc_object_tail) |tail| {
            tail.next = header;
        } else {
            self.gc_object_head = header;
        }
        self.gc_object_tail = header;
        self.gc_object_count += 1;
    }

    fn removeGcObject(self: *Registry, header: *GCObjectHeader) void {
        const prev = header.prev;
        const next = header.next;
        if (prev == null and next == null and self.gc_object_head != header and self.gc_object_tail != header) return;

        if (prev) |p| {
            p.next = next;
        } else {
            self.gc_object_head = next;
        }
        if (next) |n| {
            n.prev = prev;
        } else {
            self.gc_object_tail = prev;
        }
        header.prev = null;
        header.next = null;
        std.debug.assert(self.gc_object_count != 0);
        self.gc_object_count -= 1;
    }

    pub fn recordFailure(self: *Registry, err: CollectionError) void {
        self.stats.failed_collections += 1;
        self.stats.last_failure = switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.PayloadMarkFailed => .payload_mark_failed,
        };
    }

    pub fn recordSuccess(self: *Registry, result: CollectionResult) void {
        self.stats.last_failure = .none;
        self.stats.last_collection_time_ns = result.duration_ns;
        self.stats.cycle_gc_count +|= 1;
        self.stats.cycle_gc_time_ns +|= result.duration_ns;
        self.stats.major_pause_samples.record(result.duration_ns);
        self.stats.freed_objects +|= result.freed_objects;
        self.stats.cycles_collected +|= result.freed_objects;
    }

    pub fn verifyIntrusiveList(self: *Registry) InvariantError!void {
        if (self.gc_object_count == 0) {
            if (self.gc_object_head != null or self.gc_object_tail != null) return error.CorruptGcList;
            return;
        }
        if (self.gc_object_head == null or self.gc_object_tail == null) return error.CorruptGcList;

        var tortoise = self.gc_object_head;
        var hare = self.gc_object_head;
        while (hare) |hare_node| {
            hare = hare_node.next orelse break;
            hare = hare.?.next;
            tortoise = tortoise.?.next;
            if (hare != null and tortoise == hare) return error.CorruptGcList;
        }

        var previous: ?*GCObjectHeader = null;
        var current = self.gc_object_head;
        var count: usize = 0;
        while (current) |h| {
            if (!isCycleCandidate(h)) return error.CorruptGcList;
            if (h.meta().rc < 0) return error.NegativeRefCount;
            if (h.meta().flags.mark and self.phase == .none) return error.MarkBitLeftSet;

            if (h.prev != previous) return error.CorruptGcList;

            if (h.next) |next| {
                if (next.prev != h) return error.CorruptGcList;
            } else if (self.gc_object_tail != h) return error.CorruptGcList;

            previous = h;
            current = h.next;
            count += 1;
        }
        if (previous != self.gc_object_tail) return error.CorruptGcList;
        if (count != self.gc_object_count) return error.CorruptGcList;
    }

    pub fn verifyHeapAccounting(self: Registry, rt: anytype) InvariantError!void {
        var heap_live_bytes: usize = 0;
        var old_live_bytes: usize = 0;
        var large_object_bytes: usize = 0;

        var iterator = self.objectIterator();
        while (iterator.next()) |header| {
            const bytes = heapByteSizeFromHeader(rt, header);
            if (bytes == 0) return error.MissingHeapAllocation;
            heap_live_bytes = std.math.add(usize, heap_live_bytes, bytes) catch std.math.maxInt(usize);
            if (self.isLargeAllocation(bytes)) {
                large_object_bytes = std.math.add(usize, large_object_bytes, bytes) catch std.math.maxInt(usize);
            } else {
                old_live_bytes = std.math.add(usize, old_live_bytes, bytes) catch std.math.maxInt(usize);
            }
        }

        for (self.pin_entries, 0..) |entry, index| {
            if (entry.count == 0) return error.EmptyPinEntry;
            if (!entry.header.pinned()) return error.PinnedHeaderFlagMismatch;
            for (self.pin_entries[0..index]) |previous| {
                if (previous.header == entry.header) return error.DuplicatePinEntry;
            }
        }

        var external_token_bytes: usize = 0;
        for (self.external_tokens, 0..) |entry, index| {
            if (entry.id == 0 or entry.bytes == 0) return error.EmptyExternalMemoryToken;
            for (self.external_tokens[0..index]) |previous| {
                if (previous.id == entry.id) return error.DuplicateExternalMemoryToken;
            }
            external_token_bytes = std.math.add(usize, external_token_bytes, entry.bytes) catch std.math.maxInt(usize);
        }

        if (heap_live_bytes != self.stats.heap_live_bytes) return error.HeapLiveBytesMismatch;
        if (old_live_bytes != self.stats.old_live_bytes) return error.OldLiveBytesMismatch;
        if (large_object_bytes != self.stats.large_object_bytes) return error.LargeObjectBytesMismatch;
        const accounted_external_bytes = std.math.add(usize, external_token_bytes, self.stats.external_untracked_bytes) catch std.math.maxInt(usize);
        if (accounted_external_bytes != self.stats.external_bytes) return error.ExternalTokenBytesMismatch;
        if (old_live_bytes != self.old_space.live_bytes) return error.OldSpaceLiveBytesMismatch;
        if (large_object_bytes != self.large_space.live_bytes) return error.LargeSpaceLiveBytesMismatch;
        if (self.old_space.live_bytes +| self.old_space.free_bytes > self.old_space.committed_bytes) return error.OldSpaceCommittedBytesMismatch;
        if (self.large_space.live_bytes +| self.large_space.free_bytes > self.large_space.committed_bytes) return error.LargeSpaceCommittedBytesMismatch;
        if (!self.spacePageStateMatches(self.old_space)) return error.OldSpacePageStateMismatch;
        if (!self.spacePageStateMatches(self.large_space)) return error.LargeSpacePageStateMismatch;
    }

    pub fn verifyNoExternalTokenLeaks(self: Registry) InvariantError!void {
        if (self.external_tokens.len != 0) return error.LeakedExternalMemoryToken;
        if (self.stats.external_bytes != 0) return error.ExternalTokenBytesMismatch;
        if (self.stats.external_untracked_bytes != 0) return error.ExternalTokenBytesMismatch;
    }

    fn spacePageStateMatches(self: Registry, space: SpaceAccount) bool {
        var expected = space;
        expected.refreshPageState(self.fragmentationTriggerPerMille());
        return expected.allocating_page_count == space.allocating_page_count and
            expected.full_page_count == space.full_page_count and
            expected.empty_page_count == space.empty_page_count and
            expected.decommitted_page_count == space.decommitted_page_count and
            expected.needs_sweep_page_count == space.needs_sweep_page_count and
            expected.sweep_cursor_page == space.sweep_cursor_page and
            expected.evacuation_candidate_page_count == space.evacuation_candidate_page_count;
    }

    pub fn liveCount(self: Registry) usize {
        return self.gc_object_count;
    }

    pub fn containsHeader(self: Registry, header: *const GCObjectHeader) bool {
        var iterator = self.objectIterator();
        while (iterator.next()) |candidate| {
            if (candidate == header) return true;
        }
        return false;
    }
};

/// 6.3 Header 反查与转换辅助
pub inline fn headerFromPayload(ptr: *anyopaque) *BlockHeader {
    const addr = @intFromPtr(ptr);
    return @ptrFromInt(addr - @sizeOf(BlockHeader));
}

pub inline fn checkedHeaderFromPayload(rt: anytype, ptr: *anyopaque) *BlockHeader {
    _ = rt;
    const h = headerFromPayload(ptr);
    if (builtin.mode == .Debug) {
        std.debug.assert(h.meta().rc >= 0);
    }
    return h;
}

pub inline fn payloadFromHeader(h: *BlockHeader) *anyopaque {
    const addr = @intFromPtr(h);
    return @ptrFromInt(addr + @sizeOf(BlockHeader));
}

/// 9.1 统一的非原子 retain/release/dup/free 路径
pub inline fn retain(header: anytype) void {
    header.retain();
}

pub inline fn release(rt: anytype, header: anytype) void {
    comptime {
        @setEvalBranchQuota(10_000);
    }
    if (comptime @TypeOf(header.*) == StringHeader) {
        string.String.releaseFromHeader(rt, header);
        return;
    }
    std.debug.assert(header.meta().rc > 0);
    header.meta().rc -= 1;
    rt.gc.stats.rc_dec += 1;

    if (header.meta().rc == 0) releaseAndDestroy(rt, header);
}

noinline fn releaseAndDestroy(rt: anytype, header: *Header) void {
    if (rt.gc.phase == .deinit and (header.meta().kind == .object or header.meta().kind == .var_ref or header.meta().kind == .shape)) return;
    // During cycle removal, a child reaching rc 0 must NOT be freed here: the
    // dedicated batch loop in `destroyRuntimeCyclesWithValueRoots` frees every
    // marked-garbage object exactly once. Freeing it here (a cascade) would
    // double-free it when the batch loop reaches it, and over-release any shape
    // it shares. Pure no-op = qjs `__JS_FreeValueRT`'s `if (gc_phase !=
    // JS_GC_PHASE_REMOVE_CYCLES)` gate (quickjs.c:6476): the object stays linked
    // (and in the garbage snapshot) and is reclaimed by the batch pass. This
    // makes a reference the mark phase missed harmless (leak at worst) instead of
    // a use-after-free.
    //
    // Kind-set note: qjs gates {OBJECT, FUNCTION_BYTECODE, MODULE} (quickjs.c:6476);
    // zjs gates {object, var_ref, function_bytecode} and intentionally OMITS shape.
    // A garbage (dead-cycle) shape is freed exactly once by the `garbage_shapes`
    // loop in destroyRuntimeCyclesWithValueRoots, and its owners skip releasing it
    // via the `headerIsCycleGarbage` guard (object.zig destroyFromHeader shape-skip);
    // a live/shared shape's eager release here can never reach rc 0 during a cycle
    // round, so shape needs no gate. (zjs has no `.module` GC-kind in flight, so the
    // MODULE arm of the qjs gate has no zjs analogue.)
    if (rt.gc.phase == .remove_cycles and (header.meta().kind == .object or header.meta().kind == .var_ref or header.meta().kind == .function_bytecode)) return;
    rt.gc.unlinkObjectWithBytes(header, Registry.heapByteSizeFromHeader(rt, header));

    // 10.1 静态 kind switch 派发销毁
    switch (header.meta().kind) {
        .string => unreachable,
        .object => object.Object.destroyFromHeader(rt, header),
        .big_int => bigint.BigInt.destroyFromHeader(rt, header),
        .function_bytecode => function_bytecode_mod.destroyFromHeader(rt, header),
        .var_ref => var_ref.VarRef.destroyFromHeader(rt, header),
        .shape => rt.shapes.destroyFromHeader(header),
    }
}
