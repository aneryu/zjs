//! Z-GE (Garbage Engine) Core Implementation
//! Governing Layer: third_party/zjs/src/engine/core/gc.zig
//! Following Z-GE Architecture Contract v1.0

const std = @import("std");
const builtin = @import("builtin");
const memory = @import("memory.zig");
const bigint = @import("bigint.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const bytecode_function = @import("../bytecode/function.zig");

const KB: usize = 1024;
const MB: usize = 1024 * KB;
pub const card_size: usize = 512;

pub const Mode = enum {
    balanced,
    throughput,
    low_rss,
    low_latency,
};

pub const Policy = struct {
    mode: Mode = .balanced,

    enable_nursery: bool = false,
    nursery_initial_size: usize = 2 * MB,
    nursery_min_size: usize = 512 * KB,
    nursery_max_size: usize = 32 * MB,

    minor_pause_target_ns: u64 = 1_000_000,

    old_heap_growth_factor: f64 = 1.6,
    old_fragmentation_trigger: f64 = 0.45,

    large_object_threshold: usize = 8 * KB,

    callback_slice_budget_ns: u64 = 300_000,
    idle_slice_budget_ns: u64 = 2_000_000,

    young_weight: usize = 1,
    old_weight: usize = 4,
    large_weight: usize = 8,
    external_weight: usize = 8,
    promotion_weight: usize = 6,
    major_debt_threshold: usize = 64 * MB,
    external_soft_limit: ?usize = null,
    external_hard_limit: ?usize = null,

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
                policy.enable_nursery = true;
                policy.nursery_initial_size = 4 * MB;
                policy.nursery_max_size = 64 * MB;
                policy.old_heap_growth_factor = 1.8;
                policy.callback_slice_budget_ns = 200_000;
                policy.idle_slice_budget_ns = 2_000_000;
            },
            .low_rss => {
                policy.enable_nursery = true;
                policy.nursery_initial_size = 1 * MB;
                policy.nursery_max_size = 8 * MB;
                policy.old_heap_growth_factor = 1.3;
                policy.callback_slice_budget_ns = 300_000;
                policy.idle_slice_budget_ns = 5_000_000;
                policy.decommit_empty_pages = true;
                policy.external_weight = 12;
            },
            .low_latency => {
                policy.enable_nursery = true;
                policy.nursery_initial_size = 1 * MB;
                policy.nursery_max_size = 16 * MB;
                policy.minor_pause_target_ns = 1_000_000;
                policy.callback_slice_budget_ns = 100_000;
                policy.idle_slice_budget_ns = 1_000_000;
            },
        }
        return policy;
    }
};

pub const ExternalMemoryToken = struct {
    registry: ?*Registry = null,
    bytes: usize = 0,

    pub fn release(self: *ExternalMemoryToken) void {
        const registry = self.registry orelse return;
        const bytes = self.bytes;
        self.registry = null;
        self.bytes = 0;
        registry.reportExternalFree(bytes);
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

pub const RequestReason = enum(u8) {
    manual,
    nursery_full,
    allocation_threshold,
    allocation_debt,
    external_memory,
    collection_failed,
};

pub const RequestKind = enum(u8) {
    minor,
    major,
};

pub const RequestUrgency = enum(u8) {
    soon,
    urgent,
};

pub const Request = struct {
    pending: bool = false,
    kind: RequestKind = .major,
    reason: ?RequestReason = null,
    urgency: RequestUrgency = .soon,
};

pub const Nursery = struct {
    enabled: bool = false,
    used_bytes: usize = 0,
    committed_bytes: usize = 0,
    max_bytes: usize = 0,
};

pub const NurseryEntry = struct {
    header: *GCObjectHeader,
    bytes: usize = 0,
    age: u8 = 0,
};

pub const DirtyCard = struct {
    owner: *GCObjectHeader,
    card_addr: usize,
};

pub const ForwardingEntry = struct {
    from: *GCObjectHeader,
    to: *GCObjectHeader,
};

pub const Generation = enum(u2) {
    old = 0,
    young = 1,
    large = 2,
    immortal = 3,
};

const generation_mask: u4 = 0b0011;
const remembered_mask: u4 = 0b0100;
const pinned_mask: u4 = 0b1000;

pub const BlockFlags = packed struct(u8) {
    mark: bool = false,
    in_cycle_list: bool = false,
    finalizing: bool = false,
    immortal: bool = false,
    gc_metadata: u4 = 0,

    pub fn generation(self: BlockFlags) Generation {
        return @enumFromInt(self.gc_metadata & generation_mask);
    }

    pub fn setGeneration(self: *BlockFlags, target_generation: Generation) void {
        self.gc_metadata = (self.gc_metadata & ~generation_mask) | @as(u4, @intFromEnum(target_generation));
        self.immortal = target_generation == .immortal;
    }

    pub fn remembered(self: BlockFlags) bool {
        return (self.gc_metadata & remembered_mask) != 0;
    }

    pub fn setRemembered(self: *BlockFlags, value: bool) void {
        if (value) {
            self.gc_metadata |= remembered_mask;
        } else {
            self.gc_metadata &= ~remembered_mask;
        }
    }

    pub fn pinned(self: BlockFlags) bool {
        return (self.gc_metadata & pinned_mask) != 0;
    }

    pub fn setPinned(self: *BlockFlags, value: bool) void {
        if (value) {
            self.gc_metadata |= pinned_mask;
        } else {
            self.gc_metadata &= ~pinned_mask;
        }
    }
};

/// Z-GE v1.0 8-byte BlockHeader
pub const BlockHeader = extern struct {
    size_class: u16 align(8) = 0,
    kind: GcKind,
    flags: BlockFlags = .{},
    rc: i32 = 1,

    comptime {
        std.debug.assert(@sizeOf(BlockHeader) == 8);
    }

    pub fn retain(self: *BlockHeader) void {
        std.debug.assert(self.rc > 0);
        self.rc += 1;
    }

    pub fn generation(self: *const BlockHeader) Generation {
        return self.flags.generation();
    }

    pub fn setGeneration(self: *BlockHeader, target_generation: Generation) void {
        self.flags.setGeneration(target_generation);
    }

    pub fn remembered(self: *const BlockHeader) bool {
        return self.flags.remembered();
    }

    pub fn setRemembered(self: *BlockHeader, value: bool) void {
        self.flags.setRemembered(value);
    }

    pub fn pinned(self: *const BlockHeader) bool {
        return self.flags.pinned();
    }

    pub fn setPinned(self: *BlockHeader, value: bool) void {
        self.flags.setPinned(value);
    }
};

pub const Header = BlockHeader;
pub const GCObjectHeader = Header;
pub const ObjectHeader = Header;

/// 11.2 GcNode definition
pub const GcColor = enum(u8) {
    white = 0,
    gray = 1,
    black = 2,
};

pub const GcNode = extern struct {
    prev: ?*GcNode = null,
    next: ?*GcNode = null,
    tmp_rc: i32 = 0,
    color: GcColor = .white,
    _pad: [3]u8 = .{ 0, 0, 0 },

    pub fn init() GcNode {
        return .{};
    }
};

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
    promoted_young_objects: usize = 0,
    promoted_young_bytes: usize = 0,
    duration_ns: u64 = 0,
};

pub const InvariantError = error{
    CorruptGcList,
    NegativeRefCount,
    MarkBitLeftSet,
    NurseryBytesNotReset,
    RememberedSetNotCleared,
    DirtyCardSetNotCleared,
    YoungCellAfterMinor,
    YoungCellNotTracked,
    NurseryEntryNotYoung,
    MissingRememberedEdge,
    MissingDirtyCard,
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
    minor_gc_count: usize = 0,
    minor_gc_time_ns: u64 = 0,
    last_minor_pause_ns: u64 = 0,
    last_minor_survival_per_mille: usize = 0,
    nursery_resize_count: usize = 0,
    promoted_young_objects: usize = 0,
    promoted_young_bytes: usize = 0,

    allocated_bytes: usize = 0,
    peak_allocated_bytes: usize = 0,
    collections: usize = 0,
    freed_objects: usize = 0,

    young_allocated_bytes: usize = 0,
    young_alloc_count: usize = 0,
    old_allocated_bytes: usize = 0,
    old_alloc_count: usize = 0,
    large_allocated_bytes: usize = 0,
    large_alloc_count: usize = 0,

    external_bytes: usize = 0,
    peak_external_bytes: usize = 0,
    external_alloc_count: usize = 0,
    external_free_count: usize = 0,
    allocation_debt: usize = 0,
    gc_request_count: usize = 0,
    last_request_reason: ?RequestReason = null,
};

pub const Stats = struct {
    total_allocated_bytes: usize = 0,
    peak_allocated_bytes: usize = 0,

    young_allocated_bytes: usize = 0,
    young_alloc_count: usize = 0,
    old_allocated_bytes: usize = 0,
    old_alloc_count: usize = 0,
    large_allocated_bytes: usize = 0,
    large_alloc_count: usize = 0,

    nursery_enabled: bool = false,
    nursery_used_bytes: usize = 0,
    nursery_committed_bytes: usize = 0,
    nursery_max_bytes: usize = 0,
    nursery_tracked_bytes: usize = 0,
    nursery_object_count: usize = 0,

    external_bytes: usize = 0,
    peak_external_bytes: usize = 0,
    external_alloc_count: usize = 0,
    external_free_count: usize = 0,
    allocation_debt: usize = 0,

    minor_gc_count: usize = 0,
    minor_gc_time_ns: u64 = 0,
    last_minor_pause_ns: u64 = 0,
    last_minor_survival_per_mille: usize = 0,
    nursery_resize_count: usize = 0,
    major_gc_count: usize = 0,
    major_gc_time_ns: u64 = 0,
    failed_collections: usize = 0,
    last_failure: FailureKind = .none,
    freed_objects: usize = 0,

    promoted_young_objects: usize = 0,
    promoted_young_bytes: usize = 0,
    remembered_set_size: usize = 0,
    dirty_card_count: usize = 0,
    forwarding_entry_count: usize = 0,
    pending_finalization_job_count: usize = 0,
    deferred_native_cleanup_count: usize = 0,
    deferred_native_cleanup_run_count: usize = 0,

    gc_request_count: usize = 0,
    pending_minor: bool = false,
    pending_major: bool = false,
    pending_request_kind: ?RequestKind = null,
    pending_request_reason: ?RequestReason = null,
    pending_request_urgency: ?RequestUrgency = null,
    last_request_reason: ?RequestReason = null,
};

/// Z-GE Registry
pub const Registry = struct {
    memory: *memory.MemoryAccount,
    policy: Policy = .{},

    // GcNode 链表头与尾，仅串联可能参与循环检测的 GcCandidate (如 Object, FunctionBytecode)
    gc_obj_list_head: ?*GcNode = null,
    gc_obj_list_tail: ?*GcNode = null,
    remembered_set: []*GCObjectHeader = &.{},
    remembered_set_capacity: usize = 0,
    dirty_cards: []DirtyCard = &.{},
    dirty_cards_capacity: usize = 0,
    forwarding_entries: []ForwardingEntry = &.{},
    forwarding_entries_capacity: usize = 0,
    nursery_entries: []NurseryEntry = &.{},
    nursery_entries_capacity: usize = 0,

    phase: Phase = .none,
    minor_request: Request = .{ .kind = .minor },
    major_request: Request = .{ .kind = .major },
    nursery: Nursery = .{},
    stats: GeStats = .{},

    // Reusable structures for cycle detection
    visited: std.AutoHashMap(usize, void),
    preserved: std.AutoHashMap(usize, void),
    free_set: std.AutoHashMap(usize, void),
    preserved_bytecodes: std.AutoHashMap(usize, void),
    object_worklist: std.ArrayList(*object.Object),
    bytecode_worklist: std.ArrayList(*bytecode_function.FunctionBytecode),

    pub fn init(account: *memory.MemoryAccount, policy: Policy) Registry {
        return .{
            .memory = account,
            .policy = policy,
            .nursery = .{
                .enabled = policy.enable_nursery,
                .committed_bytes = if (policy.enable_nursery) policy.nursery_initial_size else 0,
                .max_bytes = if (policy.enable_nursery) policy.nursery_max_size else 0,
            },
            .visited = std.AutoHashMap(usize, void).init(account.persistent_allocator),
            .preserved = std.AutoHashMap(usize, void).init(account.persistent_allocator),
            .free_set = std.AutoHashMap(usize, void).init(account.persistent_allocator),
            .preserved_bytecodes = std.AutoHashMap(usize, void).init(account.persistent_allocator),
            .object_worklist = std.ArrayList(*object.Object).empty,
            .bytecode_worklist = std.ArrayList(*bytecode_function.FunctionBytecode).empty,
        };
    }

    pub fn deinit(self: *Registry, rt: anytype) void {
        self.phase = .deinit;

        // 释放可能存活的所有 Candidate 对象
        while (self.gc_obj_list_tail) |node| {
            self.unlinkNode(node);
            const h = headerFromGcNode(node);
            h.flags.finalizing = true;
            if (h.kind == .object) {
                object.Object.destroyFromHeader(rt, h);
            } else if (h.kind == .function_bytecode) {
                bytecode_function.destroyFromHeader(rt, h);
            }
        }

        self.gc_obj_list_head = null;
        self.gc_obj_list_tail = null;

        self.visited.deinit();
        self.preserved.deinit();
        self.free_set.deinit();
        self.preserved_bytecodes.deinit();
        self.object_worklist.deinit(self.memory.persistent_allocator);
        self.bytecode_worklist.deinit(self.memory.persistent_allocator);
        if (self.remembered_set_capacity != 0) {
            self.memory.free(*GCObjectHeader, self.remembered_set.ptr[0..self.remembered_set_capacity]);
        } else if (self.remembered_set.len != 0) {
            self.memory.free(*GCObjectHeader, self.remembered_set);
        }
        self.remembered_set = &.{};
        self.remembered_set_capacity = 0;
        if (self.dirty_cards_capacity != 0) {
            self.memory.free(DirtyCard, self.dirty_cards.ptr[0..self.dirty_cards_capacity]);
        } else if (self.dirty_cards.len != 0) {
            self.memory.free(DirtyCard, self.dirty_cards);
        }
        self.dirty_cards = &.{};
        self.dirty_cards_capacity = 0;
        if (self.forwarding_entries_capacity != 0) {
            self.memory.free(ForwardingEntry, self.forwarding_entries.ptr[0..self.forwarding_entries_capacity]);
        } else if (self.forwarding_entries.len != 0) {
            self.memory.free(ForwardingEntry, self.forwarding_entries);
        }
        self.forwarding_entries = &.{};
        self.forwarding_entries_capacity = 0;
        if (self.nursery_entries_capacity != 0) {
            self.memory.free(NurseryEntry, self.nursery_entries.ptr[0..self.nursery_entries_capacity]);
        } else if (self.nursery_entries.len != 0) {
            self.memory.free(NurseryEntry, self.nursery_entries);
        }
        self.nursery_entries = &.{};
        self.nursery_entries_capacity = 0;

        self.phase = .none;
    }

    pub fn reportExternalAlloc(self: *Registry, bytes: usize) ExternalMemoryToken {
        if (bytes == 0) return .{ .registry = self, .bytes = 0 };
        self.stats.external_bytes = std.math.add(usize, self.stats.external_bytes, bytes) catch std.math.maxInt(usize);
        self.stats.peak_external_bytes = @max(self.stats.peak_external_bytes, self.stats.external_bytes);
        self.stats.external_alloc_count +|= 1;
        const weighted = std.math.mul(usize, bytes, self.policy.external_weight) catch std.math.maxInt(usize);
        self.stats.allocation_debt = std.math.add(usize, self.stats.allocation_debt, weighted) catch std.math.maxInt(usize);
        return .{ .registry = self, .bytes = bytes };
    }

    pub fn reportExternalFree(self: *Registry, bytes: usize) void {
        if (bytes == 0) return;
        self.stats.external_bytes -|= bytes;
        self.stats.external_free_count +|= 1;
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

    pub fn requestGC(self: *Registry, kind: RequestKind, reason: RequestReason, urgency: RequestUrgency) void {
        self.stats.gc_request_count +|= 1;
        self.stats.last_request_reason = reason;
        const slot = self.requestSlot(kind);
        if (!slot.pending) {
            slot.* = .{
                .pending = true,
                .kind = kind,
                .reason = reason,
                .urgency = urgency,
            };
            return;
        }
        if (urgency == .urgent) slot.urgency = .urgent;
        if (slot.reason == null or urgency == .urgent) slot.reason = reason;
    }

    pub fn hasPendingRequest(self: Registry) bool {
        return self.minor_request.pending or self.major_request.pending;
    }

    pub fn hasPendingMajorRequest(self: Registry) bool {
        return self.major_request.pending;
    }

    pub fn hasPendingMinorRequest(self: Registry) bool {
        return self.minor_request.pending;
    }

    pub fn pendingMajorRequest(self: Registry) ?Request {
        return if (self.major_request.pending) self.major_request else null;
    }

    pub fn pendingRequestKind(self: Registry) ?RequestKind {
        if (self.minor_request.pending) return .minor;
        if (self.major_request.pending) return .major;
        return null;
    }

    pub fn clearMajorRequest(self: *Registry) ?Request {
        return self.clearRequestKind(.major);
    }

    pub fn clearMinorRequest(self: *Registry) ?Request {
        return self.clearRequestKind(.minor);
    }

    fn requestSlot(self: *Registry, kind: RequestKind) *Request {
        return switch (kind) {
            .minor => &self.minor_request,
            .major => &self.major_request,
        };
    }

    fn clearRequestKind(self: *Registry, kind: RequestKind) ?Request {
        const slot = self.requestSlot(kind);
        if (!slot.pending) return null;
        const request = slot.*;
        slot.* = .{ .kind = kind };
        return request;
    }

    pub fn resetAllocationDebt(self: *Registry) void {
        self.stats.allocation_debt = 0;
    }

    pub fn statsSnapshot(self: Registry) Stats {
        return .{
            .total_allocated_bytes = self.stats.allocated_bytes,
            .peak_allocated_bytes = self.stats.peak_allocated_bytes,
            .young_allocated_bytes = self.stats.young_allocated_bytes,
            .young_alloc_count = self.stats.young_alloc_count,
            .old_allocated_bytes = self.stats.old_allocated_bytes,
            .old_alloc_count = self.stats.old_alloc_count,
            .large_allocated_bytes = self.stats.large_allocated_bytes,
            .large_alloc_count = self.stats.large_alloc_count,
            .nursery_enabled = self.nursery.enabled,
            .nursery_used_bytes = self.nursery.used_bytes,
            .nursery_committed_bytes = self.nursery.committed_bytes,
            .nursery_max_bytes = self.nursery.max_bytes,
            .nursery_tracked_bytes = self.nurseryTrackedBytes(),
            .nursery_object_count = self.nursery_entries.len,
            .external_bytes = self.stats.external_bytes,
            .peak_external_bytes = self.stats.peak_external_bytes,
            .external_alloc_count = self.stats.external_alloc_count,
            .external_free_count = self.stats.external_free_count,
            .allocation_debt = self.stats.allocation_debt,
            .minor_gc_count = self.stats.minor_gc_count,
            .minor_gc_time_ns = self.stats.minor_gc_time_ns,
            .last_minor_pause_ns = self.stats.last_minor_pause_ns,
            .last_minor_survival_per_mille = self.stats.last_minor_survival_per_mille,
            .nursery_resize_count = self.stats.nursery_resize_count,
            .major_gc_count = self.stats.cycle_gc_count,
            .major_gc_time_ns = self.stats.cycle_gc_time_ns,
            .failed_collections = self.stats.failed_collections,
            .last_failure = self.stats.last_failure,
            .freed_objects = self.stats.freed_objects,
            .promoted_young_objects = self.stats.promoted_young_objects,
            .promoted_young_bytes = self.stats.promoted_young_bytes,
            .remembered_set_size = self.remembered_set.len,
            .dirty_card_count = self.dirty_cards.len,
            .forwarding_entry_count = self.forwarding_entries.len,
            .gc_request_count = self.stats.gc_request_count,
            .pending_minor = self.minor_request.pending,
            .pending_major = self.major_request.pending,
            .pending_request_kind = self.pendingRequestKind(),
            .pending_request_reason = if (self.minor_request.pending) self.minor_request.reason else if (self.major_request.pending) self.major_request.reason else null,
            .pending_request_urgency = if (self.minor_request.pending) self.minor_request.urgency else if (self.major_request.pending) self.major_request.urgency else null,
            .last_request_reason = self.stats.last_request_reason,
        };
    }

    pub fn add(self: *Registry, h: *GCObjectHeader) !void {
        try self.addWithGeneration(h, .old, defaultHeapBytes(h));
    }

    pub fn addWithGeneration(self: *Registry, h: *GCObjectHeader, generation: Generation, bytes: usize) !void {
        const track_nursery = self.nursery.enabled and generation == .young;
        if (track_nursery) try self.ensureNurseryEntryCapacity(self.nursery_entries.len + 1);

        h.rc = 1;
        h.flags = .{};
        h.setGeneration(generation);
        self.recordHeapAlloc(generation, bytes);

        if (h.kind == .object) {
            const obj: *object.Object = @alignCast(@fieldParentPtr("header", h));
            obj.gc._pad[0] = @intFromEnum(h.kind);
            self.linkNode(&obj.gc);
        } else if (h.kind == .function_bytecode) {
            const fb: *bytecode_function.FunctionBytecode = @alignCast(@fieldParentPtr("header", h));
            fb.gc._pad[0] = @intFromEnum(h.kind);
            self.linkNode(&fb.gc);
        }

        if (track_nursery) {
            self.nursery_entries.ptr[self.nursery_entries.len] = .{
                .header = h,
                .bytes = bytes,
                .age = 0,
            };
            self.nursery_entries = self.nursery_entries.ptr[0 .. self.nursery_entries.len + 1];
        }
    }

    fn defaultHeapBytes(h: *const GCObjectHeader) usize {
        return switch (h.kind) {
            .object => @sizeOf(object.Object),
            .function_bytecode => @sizeOf(bytecode_function.FunctionBytecode),
            .string, .big_int => 0,
        };
    }

    fn recordHeapAlloc(self: *Registry, generation: Generation, bytes: usize) void {
        if (bytes == 0) return;
        self.stats.allocated_bytes = std.math.add(usize, self.stats.allocated_bytes, bytes) catch std.math.maxInt(usize);
        self.stats.peak_allocated_bytes = @max(self.stats.peak_allocated_bytes, self.stats.allocated_bytes);
        const kind_weight = switch (generation) {
            .young => self.policy.young_weight,
            .old, .immortal => self.policy.old_weight,
            .large => self.policy.large_weight,
        };
        const weighted = std.math.mul(usize, bytes, kind_weight) catch std.math.maxInt(usize);
        self.stats.allocation_debt = std.math.add(usize, self.stats.allocation_debt, weighted) catch std.math.maxInt(usize);

        switch (generation) {
            .young => {
                self.stats.young_allocated_bytes = std.math.add(usize, self.stats.young_allocated_bytes, bytes) catch std.math.maxInt(usize);
                self.stats.young_alloc_count +|= 1;
                self.nursery.used_bytes = std.math.add(usize, self.nursery.used_bytes, bytes) catch std.math.maxInt(usize);
                if (self.nursery.enabled and self.nursery.used_bytes >= self.nursery.committed_bytes) {
                    self.requestGC(.minor, .nursery_full, .urgent);
                }
            },
            .old, .immortal => {
                self.stats.old_allocated_bytes = std.math.add(usize, self.stats.old_allocated_bytes, bytes) catch std.math.maxInt(usize);
                self.stats.old_alloc_count +|= 1;
            },
            .large => {
                self.stats.large_allocated_bytes = std.math.add(usize, self.stats.large_allocated_bytes, bytes) catch std.math.maxInt(usize);
                self.stats.large_alloc_count +|= 1;
            },
        }

        if (self.stats.allocation_debt >= self.policy.major_debt_threshold) {
            self.requestGC(.major, .allocation_debt, .soon);
        }
    }

    pub fn nurseryUsedBytes(self: Registry) usize {
        return self.nursery.used_bytes;
    }

    pub fn nurseryObjectCount(self: Registry) usize {
        return self.nursery_entries.len;
    }

    pub fn nurseryTrackedBytes(self: Registry) usize {
        var total: usize = 0;
        for (self.nursery_entries) |entry| {
            total = std.math.add(usize, total, entry.bytes) catch std.math.maxInt(usize);
        }
        return total;
    }

    pub fn nurseryObjectAge(self: Registry, header: *const GCObjectHeader) ?u8 {
        for (self.nursery_entries) |entry| {
            if (entry.header == header) return entry.age;
        }
        return null;
    }

    pub fn markNurserySurvivor(self: *Registry, header: *GCObjectHeader) void {
        for (self.nursery_entries) |*entry| {
            if (entry.header == header) {
                entry.age +|= 1;
                return;
            }
        }
    }

    pub fn nurseryEntryHeader(self: Registry, index: usize) ?*GCObjectHeader {
        if (index >= self.nursery_entries.len) return null;
        return self.nursery_entries[index].header;
    }

    pub fn finishMinorCollection(self: *Registry, result: CollectionResult) void {
        const nursery_allocated = self.nursery.used_bytes;
        const promoted_bytes = @min(result.promoted_young_bytes, nursery_allocated);
        const survival_per_mille = if (nursery_allocated == 0)
            @as(usize, 0)
        else
            (promoted_bytes * 1000) / nursery_allocated;

        self.stats.minor_gc_count +|= 1;
        self.stats.minor_gc_time_ns +|= result.duration_ns;
        self.stats.last_minor_pause_ns = result.duration_ns;
        self.stats.last_minor_survival_per_mille = survival_per_mille;
        self.stats.promoted_young_objects +|= result.promoted_young_objects;
        self.stats.promoted_young_bytes +|= result.promoted_young_bytes;
        self.tuneNurseryAfterMinor(survival_per_mille, result.duration_ns);
        self.nursery.used_bytes = 0;
        self.clearNurseryEntries();
        self.clearRememberedSet();
        self.clearForwarding();
    }

    fn tuneNurseryAfterMinor(self: *Registry, survival_per_mille: usize, pause_ns: u64) void {
        if (!self.nursery.enabled) return;
        const committed = self.nursery.committed_bytes;
        if (committed == 0) return;

        if (pause_ns > self.policy.minor_pause_target_ns or survival_per_mille > 350) {
            const floor = if (committed < self.policy.nursery_min_size) committed else self.policy.nursery_min_size;
            const next = @max(committed / 2, floor);
            self.setNurseryCommittedBytes(next);
            return;
        }

        if (survival_per_mille < 100 and committed < self.policy.nursery_max_size) {
            const doubled = std.math.mul(usize, committed, 2) catch std.math.maxInt(usize);
            self.setNurseryCommittedBytes(@min(doubled, self.policy.nursery_max_size));
        }
    }

    fn setNurseryCommittedBytes(self: *Registry, next: usize) void {
        if (next == self.nursery.committed_bytes) return;
        self.nursery.committed_bytes = next;
        self.stats.nursery_resize_count +|= 1;
    }

    pub fn unlinkObject(self: *Registry, h: *GCObjectHeader) void {
        h.setRemembered(false);
        self.removeNurseryEntry(h);
        if (h.kind == .object) {
            const obj: *object.Object = @alignCast(@fieldParentPtr("header", h));
            self.unlinkNode(&obj.gc);
        } else if (h.kind == .function_bytecode) {
            const fb: *bytecode_function.FunctionBytecode = @alignCast(@fieldParentPtr("header", h));
            self.unlinkNode(&fb.gc);
        }
    }

    pub fn retainObject(self: *Registry, h: *GCObjectHeader) void {
        _ = self;
        h.retain();
    }

    pub fn releaseObject(self: *Registry, h: *GCObjectHeader) bool {
        std.debug.assert(h.rc > 0);
        h.rc -= 1;
        self.stats.rc_dec += 1;

        if (h.rc == 0) {
            self.unlinkObject(h);
            return true;
        }
        return false;
    }

    pub fn writeBarrier(self: *Registry, owner: *GCObjectHeader, child: *Header, slot_addr: ?*const anyopaque) !void {
        if (owner.generation() != .old) return;
        if (child.generation() != .young) return;
        if (slot_addr) |slot| try self.markDirtyCard(owner, slot);
        if (owner.remembered()) return;

        try self.ensureRememberedSetCapacity(self.remembered_set.len + 1);
        self.remembered_set.ptr[self.remembered_set.len] = owner;
        self.remembered_set = self.remembered_set.ptr[0 .. self.remembered_set.len + 1];
        owner.setRemembered(true);
    }

    pub fn rememberedSetLen(self: Registry) usize {
        return self.remembered_set.len;
    }

    pub fn dirtyCardCount(self: Registry) usize {
        return self.dirty_cards.len;
    }

    pub fn recordForwarding(self: *Registry, from: *GCObjectHeader, to: *GCObjectHeader) !void {
        for (self.forwarding_entries) |*entry| {
            if (entry.from == from) {
                entry.to = to;
                return;
            }
        }
        try self.ensureForwardingCapacity(self.forwarding_entries.len + 1);
        self.forwarding_entries.ptr[self.forwarding_entries.len] = .{
            .from = from,
            .to = to,
        };
        self.forwarding_entries = self.forwarding_entries.ptr[0 .. self.forwarding_entries.len + 1];
    }

    pub fn forwardedHeader(self: Registry, from: *const GCObjectHeader) ?*GCObjectHeader {
        for (self.forwarding_entries) |entry| {
            if (entry.from == from) return entry.to;
        }
        return null;
    }

    pub fn forwardingEntryCount(self: Registry) usize {
        return self.forwarding_entries.len;
    }

    pub fn clearForwarding(self: *Registry) void {
        if (self.forwarding_entries_capacity == 0) {
            self.forwarding_entries = &.{};
        } else {
            self.forwarding_entries = self.forwarding_entries.ptr[0..0];
        }
    }

    pub fn clearNurseryEntries(self: *Registry) void {
        if (self.nursery_entries_capacity == 0) {
            self.nursery_entries = &.{};
        } else {
            self.nursery_entries = self.nursery_entries.ptr[0..0];
        }
    }

    pub fn clearRememberedSet(self: *Registry) void {
        for (self.remembered_set) |owner| owner.setRemembered(false);
        if (self.dirty_cards_capacity == 0) {
            self.dirty_cards = &.{};
        } else {
            self.dirty_cards = self.dirty_cards.ptr[0..0];
        }
        if (self.remembered_set_capacity == 0) {
            self.remembered_set = &.{};
            return;
        }
        self.remembered_set = self.remembered_set.ptr[0..0];
    }

    pub fn clearDirtyCardsForTest(self: *Registry) void {
        if (!builtin.is_test) @compileError("clearDirtyCardsForTest is only available in tests");
        if (self.dirty_cards_capacity == 0) {
            self.dirty_cards = &.{};
        } else {
            self.dirty_cards = self.dirty_cards.ptr[0..0];
        }
    }

    pub fn hasDirtyCard(self: Registry, owner: *GCObjectHeader, slot_addr: *const anyopaque) bool {
        const card_addr = cardAddress(slot_addr);
        for (self.dirty_cards) |card| {
            if (card.owner == owner and card.card_addr == card_addr) return true;
        }
        return false;
    }

    fn markDirtyCard(self: *Registry, owner: *GCObjectHeader, slot_addr: *const anyopaque) !void {
        const card_addr = cardAddress(slot_addr);
        for (self.dirty_cards) |card| {
            if (card.owner == owner and card.card_addr == card_addr) return;
        }
        try self.ensureDirtyCardCapacity(self.dirty_cards.len + 1);
        self.dirty_cards.ptr[self.dirty_cards.len] = .{
            .owner = owner,
            .card_addr = card_addr,
        };
        self.dirty_cards = self.dirty_cards.ptr[0 .. self.dirty_cards.len + 1];
    }

    fn cardAddress(slot_addr: *const anyopaque) usize {
        return @intFromPtr(slot_addr) & ~(card_size - 1);
    }

    fn ensureRememberedSetCapacity(self: *Registry, required: usize) !void {
        if (required <= self.remembered_set_capacity) return;
        var new_capacity = if (self.remembered_set_capacity == 0) @as(usize, 8) else self.remembered_set_capacity * 2;
        while (new_capacity < required) new_capacity *= 2;
        const next = try self.memory.alloc(*GCObjectHeader, new_capacity);
        errdefer self.memory.free(*GCObjectHeader, next);
        @memcpy(next[0..self.remembered_set.len], self.remembered_set);
        if (self.remembered_set_capacity != 0) {
            self.memory.free(*GCObjectHeader, self.remembered_set.ptr[0..self.remembered_set_capacity]);
        } else if (self.remembered_set.len != 0) {
            self.memory.free(*GCObjectHeader, self.remembered_set);
        }
        self.remembered_set = next[0..self.remembered_set.len];
        self.remembered_set_capacity = new_capacity;
    }

    fn ensureDirtyCardCapacity(self: *Registry, required: usize) !void {
        if (required <= self.dirty_cards_capacity) return;
        var new_capacity = if (self.dirty_cards_capacity == 0) @as(usize, 8) else self.dirty_cards_capacity * 2;
        while (new_capacity < required) new_capacity *= 2;
        const next = try self.memory.alloc(DirtyCard, new_capacity);
        errdefer self.memory.free(DirtyCard, next);
        @memcpy(next[0..self.dirty_cards.len], self.dirty_cards);
        if (self.dirty_cards_capacity != 0) {
            self.memory.free(DirtyCard, self.dirty_cards.ptr[0..self.dirty_cards_capacity]);
        } else if (self.dirty_cards.len != 0) {
            self.memory.free(DirtyCard, self.dirty_cards);
        }
        self.dirty_cards = next[0..self.dirty_cards.len];
        self.dirty_cards_capacity = new_capacity;
    }

    fn ensureForwardingCapacity(self: *Registry, required: usize) !void {
        if (required <= self.forwarding_entries_capacity) return;
        var new_capacity = if (self.forwarding_entries_capacity == 0) @as(usize, 8) else self.forwarding_entries_capacity * 2;
        while (new_capacity < required) new_capacity *= 2;
        const next = try self.memory.alloc(ForwardingEntry, new_capacity);
        errdefer self.memory.free(ForwardingEntry, next);
        @memcpy(next[0..self.forwarding_entries.len], self.forwarding_entries);
        if (self.forwarding_entries_capacity != 0) {
            self.memory.free(ForwardingEntry, self.forwarding_entries.ptr[0..self.forwarding_entries_capacity]);
        } else if (self.forwarding_entries.len != 0) {
            self.memory.free(ForwardingEntry, self.forwarding_entries);
        }
        self.forwarding_entries = next[0..self.forwarding_entries.len];
        self.forwarding_entries_capacity = new_capacity;
    }

    fn ensureNurseryEntryCapacity(self: *Registry, required: usize) !void {
        if (required <= self.nursery_entries_capacity) return;
        var new_capacity = if (self.nursery_entries_capacity == 0) @as(usize, 8) else self.nursery_entries_capacity * 2;
        while (new_capacity < required) new_capacity *= 2;
        const next = try self.memory.alloc(NurseryEntry, new_capacity);
        errdefer self.memory.free(NurseryEntry, next);
        @memcpy(next[0..self.nursery_entries.len], self.nursery_entries);
        if (self.nursery_entries_capacity != 0) {
            self.memory.free(NurseryEntry, self.nursery_entries.ptr[0..self.nursery_entries_capacity]);
        } else if (self.nursery_entries.len != 0) {
            self.memory.free(NurseryEntry, self.nursery_entries);
        }
        self.nursery_entries = next[0..self.nursery_entries.len];
        self.nursery_entries_capacity = new_capacity;
    }

    fn removeNurseryEntry(self: *Registry, header: *GCObjectHeader) void {
        for (self.nursery_entries, 0..) |entry, index| {
            if (entry.header != header) continue;
            if (index + 1 < self.nursery_entries.len) {
                std.mem.copyForwards(NurseryEntry, self.nursery_entries[index .. self.nursery_entries.len - 1], self.nursery_entries[index + 1 ..]);
            }
            self.nursery_entries = self.nursery_entries[0 .. self.nursery_entries.len - 1];
            return;
        }
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
        self.stats.freed_objects +|= result.freed_objects;
        self.stats.cycles_collected +|= result.freed_objects;
    }

    pub fn verifyIntrusiveList(self: *Registry) InvariantError!void {
        var tortoise = self.gc_obj_list_head;
        var hare = self.gc_obj_list_head;
        while (hare) |hare_node| {
            hare = hare_node.next orelse break;
            hare = hare.?.next;
            tortoise = tortoise.?.next;
            if (hare != null and tortoise == hare) return error.CorruptGcList;
        }

        var previous: ?*GcNode = null;
        var current = self.gc_obj_list_head;
        while (current) |node| {
            if (node.prev != previous) return error.CorruptGcList;
            const h = headerFromGcNode(node);
            if (h.rc < 0) return error.NegativeRefCount;
            if (h.flags.mark and self.phase == .none) return error.MarkBitLeftSet;
            previous = node;
            current = node.next;
        }
        if (previous != self.gc_obj_list_tail) return error.CorruptGcList;
    }

    pub fn verifyMinorPostcondition(self: Registry) InvariantError!void {
        if (!self.nursery.enabled) return;
        if (self.nursery.used_bytes != 0) return error.NurseryBytesNotReset;
        if (self.remembered_set.len != 0) return error.RememberedSetNotCleared;
        if (self.dirty_cards.len != 0) return error.DirtyCardSetNotCleared;

        var current = self.gc_obj_list_head;
        while (current) |node| {
            const header = headerFromGcNode(node);
            if (header.generation() == .young) return error.YoungCellAfterMinor;
            current = node.next;
        }
    }

    pub fn verifyNurseryCoverage(self: Registry) InvariantError!void {
        if (!self.nursery.enabled) return;

        for (self.nursery_entries) |entry| {
            if (entry.header.generation() != .young) return error.NurseryEntryNotYoung;
        }

        var current = self.gc_obj_list_head;
        while (current) |node| {
            const header = headerFromGcNode(node);
            if (header.generation() == .young and self.nurseryObjectAge(header) == null) {
                return error.YoungCellNotTracked;
            }
            current = node.next;
        }
    }

    pub fn linkNode(self: *Registry, node: *GcNode) void {
        node.prev = self.gc_obj_list_tail;
        node.next = null;
        if (self.gc_obj_list_tail) |tail| {
            tail.next = node;
        } else {
            self.gc_obj_list_head = node;
        }
        self.gc_obj_list_tail = node;
        node.color = .white;
    }

    pub fn unlinkNode(self: *Registry, node: *GcNode) void {
        if (self.gc_obj_list_head != node and node.prev == null) return;

        if (node.prev) |prev| {
            prev.next = node.next;
        } else {
            self.gc_obj_list_head = node.next;
        }
        if (node.next) |next| {
            next.prev = node.prev;
        } else {
            self.gc_obj_list_tail = node.prev;
        }
        node.prev = null;
        node.next = null;
    }

    pub fn liveCount(self: Registry) usize {
        var count: usize = 0;
        var current = self.gc_obj_list_head;
        while (current) |node| {
            count += 1;
            current = node.next;
        }
        return count;
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
        std.debug.assert(h.rc >= 0);
    }
    return h;
}

pub inline fn payloadFromHeader(h: *BlockHeader) *anyopaque {
    const addr = @intFromPtr(h);
    return @ptrFromInt(addr + @sizeOf(BlockHeader));
}

pub inline fn objectFromGcNode(node: *GcNode) *object.Object {
    return @alignCast(@fieldParentPtr("gc", node));
}

pub inline fn headerFromGcNode(node: *GcNode) *BlockHeader {
    const kind: RefKind = @enumFromInt(node._pad[0]);
    switch (kind) {
        .object => {
            const obj: *object.Object = @alignCast(@fieldParentPtr("gc", node));
            return &obj.header;
        },
        .function_bytecode => {
            const fb: *bytecode_function.FunctionBytecode = @alignCast(@fieldParentPtr("gc", node));
            return &fb.header;
        },
        else => unreachable,
    }
}

/// 9.1 统一的非原子 retain/release/dup/free 路径
pub fn retain(header: *Header) void {
    header.retain();
}

pub fn release(rt: anytype, header: *Header) void {
    std.debug.assert(header.rc > 0);
    header.rc -= 1;
    rt.gc.stats.rc_dec += 1;

    if (header.rc == 0) {
        if (rt.gc.phase == .deinit and header.kind == .object) return;
        rt.gc.unlinkObject(header);

        // 10.1 静态 kind switch 派发销毁
        switch (header.kind) {
            .string => string.String.destroyFromHeader(rt, header),
            .object => object.Object.destroyFromHeader(rt, header),
            .big_int => bigint.BigInt.destroyFromHeader(rt, header),
            .function_bytecode => bytecode_function.destroyFromHeader(rt, header),
        }
    }
}
