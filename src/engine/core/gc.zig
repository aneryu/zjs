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
pub const logical_page_size: usize = 16 * KB;

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
    old_fragmentation_trigger_per_mille: usize = 450,

    large_object_threshold: usize = 8 * KB,

    callback_slice_budget_ns: u64 = 300_000,
    idle_slice_budget_ns: u64 = 2_000_000,
    allocation_slow_path_budget_ns: u64 = 2_000_000,
    native_cleanup_slice_jobs: usize = 8,

    young_weight: usize = 1,
    old_weight: usize = 4,
    large_weight: usize = 8,
    external_weight: usize = 8,
    promotion_weight: usize = 6,
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
                policy.enable_nursery = true;
                policy.nursery_initial_size = 4 * MB;
                policy.nursery_max_size = 64 * MB;
                policy.old_heap_growth_factor = 1.8;
                policy.callback_slice_budget_ns = 200_000;
                policy.idle_slice_budget_ns = 2_000_000;
                policy.allocation_slow_path_budget_ns = 2_000_000;
                policy.native_cleanup_slice_jobs = 16;
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
                policy.native_cleanup_slice_jobs = 16;
                policy.cgroup_soft_ratio_per_mille = 850;
                policy.cgroup_hard_ratio_per_mille = 950;
            },
            .low_latency => {
                policy.enable_nursery = true;
                policy.nursery_initial_size = 1 * MB;
                policy.nursery_max_size = 16 * MB;
                policy.minor_pause_target_ns = 1_000_000;
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
    nursery_full,
    allocation_threshold,
    allocation_debt,
    external_memory,
    rss_pressure,
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

pub const PressureRequest = struct {
    reason: RequestReason,
    urgency: RequestUrgency,
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

const invalid_page_index = std.math.maxInt(usize);
const invalid_slot_index = std.math.maxInt(usize);

pub const PageSlot = struct {
    page_index: usize = invalid_page_index,
    slot_index: usize = invalid_slot_index,
    slot_size: usize = 0,

    fn isValid(self: PageSlot) bool {
        return self.page_index != invalid_page_index and self.slot_index != invalid_slot_index;
    }
};

pub const HeapAllocation = struct {
    header: *GCObjectHeader,
    generation: Generation,
    bytes: usize = 0,
    page: PageSlot = .{},
};

pub const ExternalTokenEntry = struct {
    id: u64 = 0,
    bytes: usize = 0,
};

pub const PinEntry = struct {
    header: *GCObjectHeader,
    count: usize = 0,
};

pub const PageKind = enum(u8) {
    size_class,
    large,
};

pub const HeapPage = struct {
    kind: PageKind = .size_class,
    state: PageState = .empty,
    size_class: usize = 0,
    capacity_bytes: usize = logical_page_size,
    live_bytes: usize = 0,
    free_bytes: usize = logical_page_size,
    slot_count: usize = 0,
    allocated_count: usize = 0,
    free_slots: []usize = &.{},
    free_list_len: usize = 0,
    allocation_bitmap: []usize = &.{},
    mark_bitmap: []usize = &.{},

    fn init(account: *memory.MemoryAccount, kind: PageKind, slot_size: usize, capacity_bytes: usize) !HeapPage {
        if (slot_size == 0 or capacity_bytes == 0) return error.OutOfMemory;
        const slot_count = switch (kind) {
            .size_class => capacity_bytes / slot_size,
            .large => 1,
        };
        if (slot_count == 0) return error.OutOfMemory;

        const bitmap_words = bitmapWordCount(slot_count);
        const free_slots = try account.alloc(usize, slot_count);
        errdefer account.free(usize, free_slots);
        const allocation_bitmap = try account.alloc(usize, bitmap_words);
        errdefer account.free(usize, allocation_bitmap);
        const mark_bitmap = try account.alloc(usize, bitmap_words);
        errdefer account.free(usize, mark_bitmap);

        for (free_slots, 0..) |*slot, index| {
            slot.* = slot_count - 1 - index;
        }
        @memset(allocation_bitmap, 0);
        @memset(mark_bitmap, 0);

        return .{
            .kind = kind,
            .state = .empty,
            .size_class = slot_size,
            .capacity_bytes = capacity_bytes,
            .live_bytes = 0,
            .free_bytes = capacity_bytes,
            .slot_count = slot_count,
            .allocated_count = 0,
            .free_slots = free_slots,
            .free_list_len = slot_count,
            .allocation_bitmap = allocation_bitmap,
            .mark_bitmap = mark_bitmap,
        };
    }

    fn deinit(self: *HeapPage, account: *memory.MemoryAccount) void {
        if (self.free_slots.len != 0) account.free(usize, self.free_slots);
        if (self.allocation_bitmap.len != 0) account.free(usize, self.allocation_bitmap);
        if (self.mark_bitmap.len != 0) account.free(usize, self.mark_bitmap);
        self.* = .{};
    }

    fn canAllocate(self: HeapPage, kind: PageKind, slot_size: usize, capacity_bytes: usize) bool {
        if (self.kind != kind) return false;
        if (self.state == .decommitted and self.live_bytes != 0) return false;
        if (kind == .size_class and self.size_class != slot_size) return false;
        if (kind == .large and self.capacity_bytes != capacity_bytes) return false;
        return self.free_list_len != 0;
    }

    fn allocateSlot(self: *HeapPage, bytes: usize) ?usize {
        if (self.free_list_len == 0 or self.state == .decommitted) return null;
        self.free_list_len -= 1;
        const slot_index = self.free_slots[self.free_list_len];
        if (bitmapGet(self.allocation_bitmap, slot_index)) return null;
        bitmapSet(self.allocation_bitmap, slot_index, true);
        bitmapSet(self.mark_bitmap, slot_index, false);
        self.allocated_count += 1;
        self.live_bytes = std.math.add(usize, self.live_bytes, bytes) catch std.math.maxInt(usize);
        self.free_bytes -|= self.size_class;
        self.refreshState();
        return slot_index;
    }

    fn freeSlot(self: *HeapPage, slot_index: usize, bytes: usize) void {
        if (slot_index >= self.slot_count) return;
        if (!bitmapGet(self.allocation_bitmap, slot_index)) return;
        bitmapSet(self.allocation_bitmap, slot_index, false);
        bitmapSet(self.mark_bitmap, slot_index, false);
        self.allocated_count -|= 1;
        self.live_bytes -|= bytes;
        self.free_bytes = std.math.add(usize, self.free_bytes, self.size_class) catch std.math.maxInt(usize);
        if (self.allocated_count == 0) self.free_bytes = self.capacity_bytes;
        if (self.free_list_len < self.free_slots.len) {
            self.free_slots[self.free_list_len] = slot_index;
            self.free_list_len += 1;
        }
        self.refreshState();
    }

    fn recommit(self: *HeapPage) void {
        if (self.state != .decommitted) return;
        self.state = .empty;
        self.live_bytes = 0;
        self.free_bytes = self.capacity_bytes;
        self.allocated_count = 0;
        self.free_list_len = self.slot_count;
        for (self.free_slots, 0..) |*slot, index| {
            slot.* = self.slot_count - 1 - index;
        }
        self.clearBitmaps();
    }

    fn decommit(self: *HeapPage) void {
        if (self.state == .decommitted or self.allocated_count != 0) return;
        self.state = .decommitted;
        self.live_bytes = 0;
        self.free_bytes = 0;
        self.free_list_len = self.slot_count;
        for (self.free_slots, 0..) |*slot, index| {
            slot.* = self.slot_count - 1 - index;
        }
        self.clearBitmaps();
    }

    fn startSweep(self: *HeapPage) void {
        if (self.state == .decommitted) return;
        if (self.allocated_count == 0) {
            self.state = .empty;
            self.clearMarkBits();
            return;
        }
        @memcpy(self.mark_bitmap, self.allocation_bitmap);
        self.state = .needs_sweep;
    }

    fn finishSweep(self: *HeapPage) void {
        if (self.state == .decommitted) return;
        self.clearMarkBits();
        self.refreshState();
    }

    fn cancelSweep(self: *HeapPage) void {
        if (self.state == .needs_sweep or self.state == .sweeping or self.state == .marking) {
            self.clearMarkBits();
            self.refreshState();
        }
    }

    fn markSlot(self: *HeapPage, slot_index: usize) bool {
        if (slot_index >= self.slot_count) return false;
        if (!bitmapGet(self.allocation_bitmap, slot_index)) return false;
        bitmapSet(self.mark_bitmap, slot_index, true);
        return true;
    }

    fn isAllocated(self: HeapPage, slot_index: usize) bool {
        if (slot_index >= self.slot_count) return false;
        return bitmapGet(self.allocation_bitmap, slot_index);
    }

    fn isMarked(self: HeapPage, slot_index: usize) bool {
        if (slot_index >= self.slot_count) return false;
        return bitmapGet(self.mark_bitmap, slot_index);
    }

    fn clearBitmaps(self: *HeapPage) void {
        @memset(self.allocation_bitmap, 0);
        self.clearMarkBits();
    }

    fn clearMarkBits(self: *HeapPage) void {
        @memset(self.mark_bitmap, 0);
    }

    fn refreshState(self: *HeapPage) void {
        if (self.state == .decommitted) return;
        if (self.allocated_count == 0) {
            self.state = .empty;
        } else if (self.free_list_len == 0) {
            self.state = .full;
        } else {
            self.state = .allocating;
        }
    }

    fn logicalPageCount(self: HeapPage) usize {
        return @max(@as(usize, 1), self.capacity_bytes / logical_page_size);
    }

    fn fragmented(self: HeapPage) bool {
        return self.allocated_count != 0 and self.free_bytes != 0 and self.state != .decommitted;
    }
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
    pages: []HeapPage = &.{},
    pages_capacity: usize = 0,
    sweep_cursor_index: usize = 0,

    fn deinit(self: *SpaceAccount, account: *memory.MemoryAccount) void {
        for (self.pages) |*page| page.deinit(account);
        if (self.pages_capacity != 0) {
            account.free(HeapPage, self.pages.ptr[0..self.pages_capacity]);
        } else if (self.pages.len != 0) {
            account.free(HeapPage, self.pages);
        }
        self.* = .{};
    }

    fn allocateSizeClass(self: *SpaceAccount, account: *memory.MemoryAccount, bytes: usize) !PageSlot {
        if (bytes == 0) return .{};
        const slot_size = sizeClassForBytes(bytes);
        if (slot_size > logical_page_size) return self.allocateLarge(account, bytes);

        for (self.pages, 0..) |*page, index| {
            if (!page.canAllocate(.size_class, slot_size, logical_page_size)) continue;
            page.recommit();
            const slot_index = page.allocateSlot(bytes) orelse continue;
            self.refreshPageState(0);
            return .{ .page_index = index, .slot_index = slot_index, .slot_size = slot_size };
        }

        try self.ensurePageCapacity(account, self.pages.len + 1);
        var page = try HeapPage.init(account, .size_class, slot_size, logical_page_size);
        errdefer page.deinit(account);
        const slot_index = page.allocateSlot(bytes) orelse return error.OutOfMemory;
        const page_index = self.pages.len;
        self.pages.ptr[page_index] = page;
        self.pages = self.pages.ptr[0 .. self.pages.len + 1];
        self.refreshPageState(0);
        return .{ .page_index = page_index, .slot_index = slot_index, .slot_size = slot_size };
    }

    fn allocateLarge(self: *SpaceAccount, account: *memory.MemoryAccount, bytes: usize) !PageSlot {
        if (bytes == 0) return .{};
        const capacity = alignForwardSaturating(bytes, logical_page_size);
        for (self.pages, 0..) |*page, index| {
            if (!page.canAllocate(.large, bytes, capacity)) continue;
            page.recommit();
            page.size_class = bytes;
            const slot_index = page.allocateSlot(bytes) orelse continue;
            self.refreshPageState(0);
            return .{ .page_index = index, .slot_index = slot_index, .slot_size = bytes };
        }

        try self.ensurePageCapacity(account, self.pages.len + 1);
        var page = try HeapPage.init(account, .large, bytes, capacity);
        errdefer page.deinit(account);
        const slot_index = page.allocateSlot(bytes) orelse return error.OutOfMemory;
        const page_index = self.pages.len;
        self.pages.ptr[page_index] = page;
        self.pages = self.pages.ptr[0 .. self.pages.len + 1];
        self.refreshPageState(0);
        return .{ .page_index = page_index, .slot_index = slot_index, .slot_size = bytes };
    }

    fn freeSlot(self: *SpaceAccount, slot: PageSlot, bytes: usize, retain_hot_empty_pages: usize, decommit_empty_pages: bool) void {
        if (!slot.isValid() or slot.page_index >= self.pages.len) return;
        self.pages[slot.page_index].freeSlot(slot.slot_index, bytes);
        if (decommit_empty_pages) self.trimFreePages(retain_hot_empty_pages);
        self.refreshPageState(0);
    }

    fn markSlot(self: *SpaceAccount, slot: PageSlot) bool {
        if (!slot.isValid() or slot.page_index >= self.pages.len) return false;
        return self.pages[slot.page_index].markSlot(slot.slot_index);
    }

    fn trimFreePages(self: *SpaceAccount, retain_hot_empty_pages: usize) void {
        var retained_pages: usize = 0;
        for (self.pages) |*page| {
            if (page.state == .decommitted or page.allocated_count != 0) continue;
            const page_count = page.logicalPageCount();
            if (retained_pages < retain_hot_empty_pages) {
                retained_pages = std.math.add(usize, retained_pages, page_count) catch std.math.maxInt(usize);
                continue;
            }
            page.decommit();
        }
        self.refreshPageState(0);
    }

    fn fragmentationPerMille(self: SpaceAccount) usize {
        return ratioPerMille(self.free_bytes, self.committed_bytes);
    }

    fn refreshPageState(self: *SpaceAccount, fragmentation_trigger_per_mille: usize) void {
        self.live_bytes = 0;
        self.committed_bytes = 0;
        self.free_bytes = 0;
        self.decommitted_bytes = 0;
        self.allocating_page_count = 0;
        self.full_page_count = 0;
        self.empty_page_count = 0;
        self.decommitted_page_count = 0;
        self.needs_sweep_page_count = 0;
        self.evacuation_candidate_page_count = 0;

        var fragmented_pages: usize = 0;
        for (self.pages) |page| {
            const page_count = page.logicalPageCount();
            if (page.state == .decommitted) {
                self.decommitted_bytes = std.math.add(usize, self.decommitted_bytes, page.capacity_bytes) catch std.math.maxInt(usize);
                self.decommitted_page_count = std.math.add(usize, self.decommitted_page_count, page_count) catch std.math.maxInt(usize);
                continue;
            }

            self.live_bytes = std.math.add(usize, self.live_bytes, page.live_bytes) catch std.math.maxInt(usize);
            self.committed_bytes = std.math.add(usize, self.committed_bytes, page.capacity_bytes) catch std.math.maxInt(usize);
            self.free_bytes = std.math.add(usize, self.free_bytes, page.free_bytes) catch std.math.maxInt(usize);

            switch (page.state) {
                .empty => self.empty_page_count = std.math.add(usize, self.empty_page_count, page_count) catch std.math.maxInt(usize),
                .full => self.full_page_count = std.math.add(usize, self.full_page_count, page_count) catch std.math.maxInt(usize),
                .needs_sweep, .sweeping => self.needs_sweep_page_count = std.math.add(usize, self.needs_sweep_page_count, page_count) catch std.math.maxInt(usize),
                .allocating, .marking, .swept => self.allocating_page_count = std.math.add(usize, self.allocating_page_count, page_count) catch std.math.maxInt(usize),
                .decommitted => unreachable,
            }
            if (page.fragmented()) {
                fragmented_pages = std.math.add(usize, fragmented_pages, page_count) catch std.math.maxInt(usize);
            }
        }

        self.evacuation_candidate_page_count = if (fragmentation_trigger_per_mille != 0 and self.fragmentationPerMille() >= fragmentation_trigger_per_mille)
            fragmented_pages
        else
            0;
        if (self.sweep_cursor_index > self.pages.len) self.sweep_cursor_index = self.pages.len;
        self.sweep_cursor_page = self.sweep_cursor_index;
    }

    fn startSweep(self: *SpaceAccount, fragmentation_trigger_per_mille: usize) void {
        for (self.pages) |*page| page.startSweep();
        self.sweep_cursor_index = 0;
        self.sweep_cursor_page = 0;
        self.refreshPageState(fragmentation_trigger_per_mille);
    }

    fn sweepSomePages(self: *SpaceAccount, max_pages: usize, fragmentation_trigger_per_mille: usize) usize {
        if (max_pages == 0 or self.needs_sweep_page_count == 0) return 0;
        var swept: usize = 0;
        var index = self.sweep_cursor_index;
        while (index < self.pages.len and swept < max_pages) : (index += 1) {
            const page = &self.pages[index];
            if (page.state != .needs_sweep and page.state != .sweeping) continue;
            const page_count = page.logicalPageCount();
            if (swept != 0 and swept + page_count > max_pages) break;
            page.state = .sweeping;
            page.finishSweep();
            swept = std.math.add(usize, swept, page_count) catch std.math.maxInt(usize);
        }
        self.sweep_cursor_index = index;
        self.refreshPageState(fragmentation_trigger_per_mille);
        if (self.needs_sweep_page_count == 0) {
            self.sweep_cursor_index = 0;
            self.sweep_cursor_page = 0;
        }
        return swept;
    }

    fn sweepAllPages(self: *SpaceAccount, fragmentation_trigger_per_mille: usize) usize {
        return self.sweepSomePages(std.math.maxInt(usize), fragmentation_trigger_per_mille);
    }

    fn cancelSweep(self: *SpaceAccount, fragmentation_trigger_per_mille: usize) void {
        for (self.pages) |*page| page.cancelSweep();
        self.sweep_cursor_index = 0;
        self.sweep_cursor_page = 0;
        self.refreshPageState(fragmentation_trigger_per_mille);
    }

    fn committedPageCount(self: SpaceAccount) usize {
        return self.committed_bytes / logical_page_size;
    }

    fn pageAllocated(self: SpaceAccount, slot: PageSlot) bool {
        if (!slot.isValid() or slot.page_index >= self.pages.len) return false;
        return self.pages[slot.page_index].isAllocated(slot.slot_index);
    }

    fn pageMarked(self: SpaceAccount, slot: PageSlot) bool {
        if (!slot.isValid() or slot.page_index >= self.pages.len) return false;
        return self.pages[slot.page_index].isMarked(slot.slot_index);
    }

    fn ensurePageCapacity(self: *SpaceAccount, account: *memory.MemoryAccount, required: usize) !void {
        if (required <= self.pages_capacity) return;
        var new_capacity = if (self.pages_capacity == 0) @as(usize, 4) else self.pages_capacity * 2;
        while (new_capacity < required) new_capacity *= 2;
        const next = try account.alloc(HeapPage, new_capacity);
        @memcpy(next[0..self.pages.len], self.pages);
        if (self.pages_capacity != 0) {
            account.free(HeapPage, self.pages.ptr[0..self.pages_capacity]);
        } else if (self.pages.len != 0) {
            account.free(HeapPage, self.pages);
        }
        self.pages = next[0..self.pages.len];
        self.pages_capacity = new_capacity;
    }
};

fn sizeClassForBytes(bytes: usize) usize {
    const min_size_class: usize = 16;
    if (bytes <= min_size_class) return min_size_class;
    return alignForwardSaturating(bytes, min_size_class);
}

const bitmap_word_bits = @bitSizeOf(usize);

fn bitmapWordCount(bit_count: usize) usize {
    return (bit_count + bitmap_word_bits - 1) / bitmap_word_bits;
}

fn bitmapSet(bitmap: []usize, bit_index: usize, value: bool) void {
    const word_index = bit_index / bitmap_word_bits;
    const shift: std.math.Log2Int(usize) = @intCast(bit_index % bitmap_word_bits);
    const mask = @as(usize, 1) << shift;
    if (value) {
        bitmap[word_index] |= mask;
    } else {
        bitmap[word_index] &= ~mask;
    }
}

fn bitmapGet(bitmap: []const usize, bit_index: usize) bool {
    const word_index = bit_index / bitmap_word_bits;
    const shift: std.math.Log2Int(usize) = @intCast(bit_index % bitmap_word_bits);
    const mask = @as(usize, 1) << shift;
    return (bitmap[word_index] & mask) != 0;
}

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
    copied_young_objects: usize = 0,
    copied_young_bytes: usize = 0,
    nursery_allocated_bytes: usize = 0,
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
    NurseryBytesNotReset,
    RememberedSetNotCleared,
    DirtyCardSetNotCleared,
    YoungCellAfterMinor,
    YoungCellNotTracked,
    NurseryEntryNotYoung,
    MissingRememberedEdge,
    MissingDirtyCard,
    DuplicateHeapAllocation,
    MissingHeapAllocation,
    DuplicatePageSlot,
    MissingPageAllocation,
    InvalidPageAllocation,
    PageLiveBytesMismatch,
    PageCommittedBytesMismatch,
    PageFreeBytesMismatch,
    PageDecommittedBytesMismatch,
    HeapLiveBytesMismatch,
    YoungLiveBytesMismatch,
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
    minor_gc_count: usize = 0,
    minor_gc_time_ns: u64 = 0,
    last_minor_pause_ns: u64 = 0,
    minor_pause_samples: PauseSamples = .{},
    last_minor_survival_per_mille: usize = 0,
    last_promotion_per_mille: usize = 0,
    nursery_resize_count: usize = 0,
    promoted_young_objects: usize = 0,
    promoted_young_bytes: usize = 0,
    copied_young_objects: usize = 0,
    copied_young_bytes: usize = 0,
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
    young_live_bytes: usize = 0,
    old_live_bytes: usize = 0,
    large_object_bytes: usize = 0,
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
    external_invalid_release_count: usize = 0,
    allocation_debt: usize = 0,
    gc_request_count: usize = 0,
    last_request_reason: ?RequestReason = null,
};

pub const Stats = struct {
    total_allocated_bytes: usize = 0,
    peak_allocated_bytes: usize = 0,
    heap_live_bytes: usize = 0,
    young_live_bytes: usize = 0,
    old_live_bytes: usize = 0,
    large_object_bytes: usize = 0,
    heap_committed_bytes: usize = 0,
    young_committed_bytes: usize = 0,
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
    external_token_count: usize = 0,
    external_token_bytes: usize = 0,
    external_invalid_release_count: usize = 0,
    allocation_debt: usize = 0,

    minor_gc_count: usize = 0,
    minor_gc_time_ns: u64 = 0,
    last_minor_pause_ns: u64 = 0,
    minor_pause_ns_p50: u64 = 0,
    minor_pause_ns_p95: u64 = 0,
    minor_pause_ns_p99: u64 = 0,
    last_minor_survival_per_mille: usize = 0,
    last_promotion_per_mille: usize = 0,
    nursery_resize_count: usize = 0,
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

    promoted_young_objects: usize = 0,
    promoted_young_bytes: usize = 0,
    copied_young_objects: usize = 0,
    copied_young_bytes: usize = 0,
    remembered_set_size: usize = 0,
    dirty_card_count: usize = 0,
    forwarding_entry_count: usize = 0,
    pinned_cell_count: usize = 0,
    weak_ref_count: usize = 0,
    finalizer_queue_length: usize = 0,
    pending_finalization_job_count: usize = 0,
    deferred_native_cleanup_count: usize = 0,
    deferred_native_cleanup_run_count: usize = 0,
    deferred_class_payload_finalizer_count: usize = 0,
    deferred_class_payload_finalizer_run_count: usize = 0,

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
    heap_allocations: []HeapAllocation = &.{},
    heap_allocations_capacity: usize = 0,
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
    minor_request: Request = .{ .kind = .minor },
    major_request: Request = .{ .kind = .major },
    nursery: Nursery = .{},
    old_space: SpaceAccount = .{},
    large_space: SpaceAccount = .{},
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
            .old_space = .{},
            .large_space = .{},
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
            const h = headerFromGcNode(node);
            self.recordHeapFree(h);
            self.unlinkNode(node);
            h.flags.finalizing = true;
            if (h.kind == .object) {
                object.Object.destroyFromHeader(rt, h);
                rt.drainDeferredClassPayloadFinalizers();
            } else if (h.kind == .function_bytecode) {
                bytecode_function.destroyFromHeader(rt, h);
            }
        }

        self.gc_obj_list_head = null;
        self.gc_obj_list_tail = null;

        self.freeForwardingShadows(rt);

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
        if (self.heap_allocations_capacity != 0) {
            self.memory.free(HeapAllocation, self.heap_allocations.ptr[0..self.heap_allocations_capacity]);
        } else if (self.heap_allocations.len != 0) {
            self.memory.free(HeapAllocation, self.heap_allocations);
        }
        self.heap_allocations = &.{};
        self.heap_allocations_capacity = 0;
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
        self.old_space.deinit(self.memory);
        self.large_space.deinit(self.memory);

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

    pub fn reportExternalFree(self: *Registry, bytes: usize) void {
        if (bytes == 0) return;
        self.stats.external_bytes -|= bytes;
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
        if (urgency == .urgent and slot.urgency != .urgent) {
            slot.urgency = .urgent;
            slot.reason = reason;
            return;
        }
        if (slot.reason == null) slot.reason = reason;
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

    pub fn sliceBudgetNs(self: Registry, point: SchedulerPoint) u64 {
        return switch (point) {
            .allocation_slow_path => self.policy.allocation_slow_path_budget_ns,
            .callback_boundary, .safepoint => self.policy.callback_slice_budget_ns,
            .idle => self.policy.idle_slice_budget_ns,
            .urgent => self.policy.allocation_slow_path_budget_ns,
        };
    }

    pub fn shouldRunMinorAt(self: Registry, point: SchedulerPoint) bool {
        _ = point;
        return self.minor_request.pending;
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
            .young_live_bytes = self.stats.young_live_bytes,
            .old_live_bytes = self.stats.old_live_bytes,
            .large_object_bytes = self.stats.large_object_bytes,
            .heap_committed_bytes = self.nursery.committed_bytes +| self.old_space.committed_bytes +| self.large_space.committed_bytes,
            .young_committed_bytes = self.nursery.committed_bytes,
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
            .external_token_count = self.external_tokens.len,
            .external_token_bytes = self.externalTokenBytes(),
            .external_invalid_release_count = self.stats.external_invalid_release_count,
            .allocation_debt = self.stats.allocation_debt,
            .minor_gc_count = self.stats.minor_gc_count,
            .minor_gc_time_ns = self.stats.minor_gc_time_ns,
            .last_minor_pause_ns = self.stats.last_minor_pause_ns,
            .minor_pause_ns_p50 = self.stats.minor_pause_samples.percentile(500),
            .minor_pause_ns_p95 = self.stats.minor_pause_samples.percentile(950),
            .minor_pause_ns_p99 = self.stats.minor_pause_samples.percentile(990),
            .last_minor_survival_per_mille = self.stats.last_minor_survival_per_mille,
            .last_promotion_per_mille = self.stats.last_promotion_per_mille,
            .nursery_resize_count = self.stats.nursery_resize_count,
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
            .promoted_young_objects = self.stats.promoted_young_objects,
            .promoted_young_bytes = self.stats.promoted_young_bytes,
            .copied_young_objects = self.stats.copied_young_objects,
            .copied_young_bytes = self.stats.copied_young_bytes,
            .remembered_set_size = self.remembered_set.len,
            .dirty_card_count = self.dirty_cards.len,
            .forwarding_entry_count = self.forwarding_entries.len,
            .pinned_cell_count = self.pin_entries.len,
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
        const requested_generation = if (h.kind == .function_bytecode and generation == .young) .old else generation;
        const actual_generation = self.classifyGeneration(requested_generation, bytes);
        const track_nursery = self.nursery.enabled and actual_generation == .young;
        if (track_nursery) try self.ensureNurseryEntryCapacity(self.nursery_entries.len + 1);
        if (bytes != 0) try self.ensureHeapAllocationCapacity(self.heap_allocations.len + 1);
        const page = try self.recordHeapAlloc(actual_generation, bytes);

        h.rc = 1;
        h.flags = .{};
        h.size_class = @intCast(@min(if (page.slot_size != 0) page.slot_size else bytes, std.math.maxInt(u16)));
        h.setGeneration(actual_generation);
        if (bytes != 0) {
            self.heap_allocations.ptr[self.heap_allocations.len] = .{
                .header = h,
                .generation = actual_generation,
                .bytes = bytes,
                .page = page,
            };
            self.heap_allocations = self.heap_allocations.ptr[0 .. self.heap_allocations.len + 1];
        }

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

    fn classifyGeneration(self: Registry, requested: Generation, bytes: usize) Generation {
        if (requested == .immortal or bytes == 0) return requested;
        if (bytes >= self.policy.large_object_threshold) return .large;
        return requested;
    }

    fn recordHeapAlloc(self: *Registry, generation: Generation, bytes: usize) !PageSlot {
        if (bytes == 0) return .{};
        const page = try self.recordSpaceAlloc(generation, bytes);
        self.stats.allocated_bytes = std.math.add(usize, self.stats.allocated_bytes, bytes) catch std.math.maxInt(usize);
        self.stats.peak_allocated_bytes = @max(self.stats.peak_allocated_bytes, self.stats.allocated_bytes);
        self.addLiveHeapBytes(generation, bytes);
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
        return page;
    }

    fn recordHeapFree(self: *Registry, header: *GCObjectHeader) void {
        const index = self.heapAllocationIndex(header) orelse return;
        const entry = self.heap_allocations[index];
        self.subtractLiveHeapBytes(entry.generation, entry.bytes);
        self.recordSpaceFree(entry.generation, entry.bytes, entry.page);
        if (index + 1 < self.heap_allocations.len) {
            std.mem.copyForwards(
                HeapAllocation,
                self.heap_allocations[index .. self.heap_allocations.len - 1],
                self.heap_allocations[index + 1 ..],
            );
        }
        self.heap_allocations = self.heap_allocations[0 .. self.heap_allocations.len - 1];
        header.size_class = 0;
    }

    pub fn promoteHeapAllocationToOld(self: *Registry, header: *GCObjectHeader) !void {
        const index = self.heapAllocationIndex(header) orelse return;
        const entry = &self.heap_allocations[index];
        if (entry.generation == .old) return;
        if (entry.generation != .young) return;
        const page = try self.recordSpaceAlloc(.old, entry.bytes);
        self.subtractLiveHeapBytes(entry.generation, entry.bytes);
        self.addLiveHeapBytes(.old, entry.bytes);
        const weighted = std.math.mul(usize, entry.bytes, self.policy.promotion_weight) catch std.math.maxInt(usize);
        self.stats.allocation_debt = std.math.add(usize, self.stats.allocation_debt, weighted) catch std.math.maxInt(usize);
        if (self.stats.allocation_debt >= self.policy.major_debt_threshold) {
            self.requestGC(.major, .allocation_debt, .soon);
        }
        entry.generation = .old;
        entry.page = page;
        header.size_class = @intCast(@min(if (page.slot_size != 0) page.slot_size else entry.bytes, std.math.maxInt(u16)));
    }

    pub fn promoteYoungHeaderToOld(self: *Registry, header: *GCObjectHeader) !void {
        if (header.generation() != .young) return;
        const nursery_bytes = blk: {
            for (self.nursery_entries) |entry| {
                if (entry.header == header) break :blk entry.bytes;
            }
            break :blk @as(usize, 0);
        };
        try self.promoteHeapAllocationToOld(header);
        header.setGeneration(.old);
        self.removeNurseryEntry(header);
        self.nursery.used_bytes -|= nursery_bytes;
    }

    pub fn moveYoungAllocationToOld(self: *Registry, from: *GCObjectHeader, to: *GCObjectHeader) !void {
        std.debug.assert(from.generation() == .young);
        std.debug.assert(from.kind == to.kind);
        std.debug.assert(!from.pinned());
        const index = self.heapAllocationIndex(from) orelse return;
        const entry = &self.heap_allocations[index];
        if (entry.generation != .young) return;
        const nursery_bytes = blk: {
            for (self.nursery_entries) |nursery_entry| {
                if (nursery_entry.header == from) break :blk nursery_entry.bytes;
            }
            break :blk @as(usize, 0);
        };

        const page = try self.recordSpaceAlloc(.old, entry.bytes);
        self.subtractLiveHeapBytes(.young, entry.bytes);
        self.addLiveHeapBytes(.old, entry.bytes);
        const weighted = std.math.mul(usize, entry.bytes, self.policy.promotion_weight) catch std.math.maxInt(usize);
        self.stats.allocation_debt = std.math.add(usize, self.stats.allocation_debt, weighted) catch std.math.maxInt(usize);
        if (self.stats.allocation_debt >= self.policy.major_debt_threshold) {
            self.requestGC(.major, .allocation_debt, .soon);
        }

        entry.header = to;
        entry.generation = .old;
        entry.page = page;
        to.setGeneration(.old);
        to.setRemembered(false);
        to.size_class = @intCast(@min(if (page.slot_size != 0) page.slot_size else entry.bytes, std.math.maxInt(u16)));
        from.setGeneration(.old);
        from.setRemembered(false);
        from.size_class = to.size_class;
        self.removeNurseryEntry(from);
        self.nursery.used_bytes -|= nursery_bytes;
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
        errdefer {
            self.pin_entries = self.pin_entries[0 .. self.pin_entries.len - 1];
            header.setPinned(false);
        }
        try self.promoteYoungHeaderToOld(header);
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

    fn addLiveHeapBytes(self: *Registry, generation: Generation, bytes: usize) void {
        self.stats.heap_live_bytes = std.math.add(usize, self.stats.heap_live_bytes, bytes) catch std.math.maxInt(usize);
        switch (generation) {
            .young => self.stats.young_live_bytes = std.math.add(usize, self.stats.young_live_bytes, bytes) catch std.math.maxInt(usize),
            .old, .immortal => self.stats.old_live_bytes = std.math.add(usize, self.stats.old_live_bytes, bytes) catch std.math.maxInt(usize),
            .large => self.stats.large_object_bytes = std.math.add(usize, self.stats.large_object_bytes, bytes) catch std.math.maxInt(usize),
        }
    }

    fn subtractLiveHeapBytes(self: *Registry, generation: Generation, bytes: usize) void {
        self.stats.heap_live_bytes -|= bytes;
        switch (generation) {
            .young => self.stats.young_live_bytes -|= bytes,
            .old, .immortal => self.stats.old_live_bytes -|= bytes,
            .large => self.stats.large_object_bytes -|= bytes,
        }
    }

    fn recordSpaceAlloc(self: *Registry, generation: Generation, bytes: usize) !PageSlot {
        const slot = switch (generation) {
            .young => PageSlot{},
            .old, .immortal => try self.old_space.allocateSizeClass(self.memory, bytes),
            .large => try self.large_space.allocateLarge(self.memory, bytes),
        };
        self.refreshSpacePageState();
        return slot;
    }

    fn recordSpaceFree(self: *Registry, generation: Generation, bytes: usize, slot: PageSlot) void {
        switch (generation) {
            .young => {},
            .old, .immortal => self.old_space.freeSlot(slot, bytes, self.policy.retain_hot_empty_pages, self.policy.decommit_empty_pages),
            .large => self.large_space.freeSlot(slot, bytes, 0, self.policy.decommit_empty_pages),
        }
        self.refreshSpacePageState();
    }

    fn heapAllocationIndex(self: Registry, header: *const GCObjectHeader) ?usize {
        for (self.heap_allocations, 0..) |entry, index| {
            if (entry.header == header) return index;
        }
        return null;
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

    pub fn externalTokenBytes(self: Registry) usize {
        var total: usize = 0;
        for (self.external_tokens) |entry| {
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
        const nursery_allocated = result.nursery_allocated_bytes;
        const promoted_bytes = @min(result.promoted_young_bytes, nursery_allocated);
        const survival_per_mille = ratioPerMille(promoted_bytes, nursery_allocated);

        self.stats.minor_gc_count +|= 1;
        self.stats.freed_objects +|= result.freed_objects;
        self.stats.minor_gc_time_ns +|= result.duration_ns;
        self.stats.last_minor_pause_ns = result.duration_ns;
        self.stats.minor_pause_samples.record(result.duration_ns);
        self.stats.last_minor_survival_per_mille = survival_per_mille;
        self.stats.last_promotion_per_mille = survival_per_mille;
        self.stats.promoted_young_objects +|= result.promoted_young_objects;
        self.stats.promoted_young_bytes +|= result.promoted_young_bytes;
        self.stats.copied_young_objects +|= result.copied_young_objects;
        self.stats.copied_young_bytes +|= result.copied_young_bytes;
        self.tuneNurseryAfterMinor(survival_per_mille, result.duration_ns);
        self.nursery.used_bytes = 0;
        self.clearNurseryEntries();
        self.clearRememberedSet();
        self.clearMarkStackDepth();
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
        self.recordHeapFree(h);
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

    pub fn releaseForwardingShadows(self: *Registry, rt: anytype) void {
        self.freeForwardingShadows(rt);
    }

    fn freeForwardingShadows(self: *Registry, rt: anytype) void {
        for (self.forwarding_entries) |entry| {
            if (entry.from == entry.to) continue;
            switch (entry.from.kind) {
                .object => {
                    const old_obj: *object.Object = @alignCast(@fieldParentPtr("header", entry.from));
                    rt.memory.destroy(object.Object, old_obj);
                },
                .function_bytecode => {
                    const old_fb: *bytecode_function.FunctionBytecode = @alignCast(@fieldParentPtr("header", entry.from));
                    rt.memory.free(bytecode_function.FunctionBytecode, old_fb[0..1]);
                },
                .string, .big_int => {},
            }
        }
        self.clearForwarding();
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

    fn ensureHeapAllocationCapacity(self: *Registry, required: usize) !void {
        if (required <= self.heap_allocations_capacity) return;
        var new_capacity = if (self.heap_allocations_capacity == 0) @as(usize, 8) else self.heap_allocations_capacity * 2;
        while (new_capacity < required) new_capacity *= 2;
        const next = try self.memory.alloc(HeapAllocation, new_capacity);
        errdefer self.memory.free(HeapAllocation, next);
        @memcpy(next[0..self.heap_allocations.len], self.heap_allocations);
        if (self.heap_allocations_capacity != 0) {
            self.memory.free(HeapAllocation, self.heap_allocations.ptr[0..self.heap_allocations_capacity]);
        } else if (self.heap_allocations.len != 0) {
            self.memory.free(HeapAllocation, self.heap_allocations);
        }
        self.heap_allocations = next[0..self.heap_allocations.len];
        self.heap_allocations_capacity = new_capacity;
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
        self.stats.major_pause_samples.record(result.duration_ns);
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

    pub fn verifyHeapAccounting(self: Registry) InvariantError!void {
        var heap_live_bytes: usize = 0;
        var young_live_bytes: usize = 0;
        var old_live_bytes: usize = 0;
        var large_object_bytes: usize = 0;

        for (self.heap_allocations, 0..) |entry, index| {
            for (self.heap_allocations[0..index]) |previous| {
                if (previous.header == entry.header) return error.DuplicateHeapAllocation;
                if (samePageSpace(entry.generation, previous.generation) and entry.page.isValid() and previous.page.isValid() and entry.page.page_index == previous.page.page_index and entry.page.slot_index == previous.page.slot_index) {
                    return error.DuplicatePageSlot;
                }
            }
            try self.verifyAllocationPage(entry);

            heap_live_bytes = std.math.add(usize, heap_live_bytes, entry.bytes) catch std.math.maxInt(usize);
            switch (entry.generation) {
                .young => young_live_bytes = std.math.add(usize, young_live_bytes, entry.bytes) catch std.math.maxInt(usize),
                .old, .immortal => old_live_bytes = std.math.add(usize, old_live_bytes, entry.bytes) catch std.math.maxInt(usize),
                .large => large_object_bytes = std.math.add(usize, large_object_bytes, entry.bytes) catch std.math.maxInt(usize),
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

        var current = self.gc_obj_list_head;
        while (current) |node| {
            const header = headerFromGcNode(node);
            if (defaultHeapBytes(header) != 0 and self.heapAllocationIndex(header) == null) {
                return error.MissingHeapAllocation;
            }
            current = node.next;
        }

        if (heap_live_bytes != self.stats.heap_live_bytes) return error.HeapLiveBytesMismatch;
        if (young_live_bytes != self.stats.young_live_bytes) return error.YoungLiveBytesMismatch;
        if (old_live_bytes != self.stats.old_live_bytes) return error.OldLiveBytesMismatch;
        if (large_object_bytes != self.stats.large_object_bytes) return error.LargeObjectBytesMismatch;
        if (external_token_bytes != self.stats.external_bytes) return error.ExternalTokenBytesMismatch;
        if (old_live_bytes != self.old_space.live_bytes) return error.OldSpaceLiveBytesMismatch;
        if (large_object_bytes != self.large_space.live_bytes) return error.LargeSpaceLiveBytesMismatch;
        try verifySpacePages(self.old_space);
        try verifySpacePages(self.large_space);
        if (self.old_space.live_bytes +| self.old_space.free_bytes > self.old_space.committed_bytes) return error.OldSpaceCommittedBytesMismatch;
        if (self.large_space.live_bytes +| self.large_space.free_bytes > self.large_space.committed_bytes) return error.LargeSpaceCommittedBytesMismatch;
        if (!self.spacePageStateMatches(self.old_space)) return error.OldSpacePageStateMismatch;
        if (!self.spacePageStateMatches(self.large_space)) return error.LargeSpacePageStateMismatch;
    }

    pub fn verifyNoExternalTokenLeaks(self: Registry) InvariantError!void {
        if (self.external_tokens.len != 0) return error.LeakedExternalMemoryToken;
        if (self.stats.external_bytes != 0) return error.ExternalTokenBytesMismatch;
    }

    fn verifyAllocationPage(self: Registry, entry: HeapAllocation) InvariantError!void {
        switch (entry.generation) {
            .young => {
                if (entry.page.isValid()) return error.InvalidPageAllocation;
            },
            .old, .immortal => try verifyAllocationInSpace(self.old_space, entry, false),
            .large => try verifyAllocationInSpace(self.large_space, entry, true),
        }
    }

    fn verifyAllocationInSpace(space: SpaceAccount, entry: HeapAllocation, require_large_page: bool) InvariantError!void {
        if (!entry.page.isValid() or entry.page.page_index >= space.pages.len) return error.MissingPageAllocation;
        const page = space.pages[entry.page.page_index];
        if (!page.isAllocated(entry.page.slot_index)) return error.MissingPageAllocation;
        if (require_large_page and page.kind != .large) return error.InvalidPageAllocation;
        if (!require_large_page and page.kind == .size_class and entry.bytes > page.size_class) return error.InvalidPageAllocation;
        if (page.kind == .large and page.size_class != entry.bytes) return error.InvalidPageAllocation;
        if (entry.page.slot_size != page.size_class) return error.InvalidPageAllocation;
    }

    fn verifySpacePages(space: SpaceAccount) InvariantError!void {
        var live_bytes: usize = 0;
        var committed_bytes: usize = 0;
        var free_bytes: usize = 0;
        var decommitted_bytes: usize = 0;

        for (space.pages) |page| {
            var allocated_bits: usize = 0;
            for (0..page.slot_count) |slot_index| {
                const allocated = page.isAllocated(slot_index);
                const marked = page.isMarked(slot_index);
                if (allocated) allocated_bits += 1;
                if (marked and !allocated) return error.InvalidPageAllocation;
            }
            if (allocated_bits != page.allocated_count) return error.InvalidPageAllocation;
            if (page.free_list_len + page.allocated_count != page.slot_count) return error.InvalidPageAllocation;
            for (page.free_slots[0..page.free_list_len], 0..) |slot_index, index| {
                if (slot_index >= page.slot_count) return error.InvalidPageAllocation;
                if (page.isAllocated(slot_index)) return error.InvalidPageAllocation;
                for (page.free_slots[0..index]) |previous| {
                    if (previous == slot_index) return error.InvalidPageAllocation;
                }
            }

            if (page.state == .decommitted) {
                decommitted_bytes = std.math.add(usize, decommitted_bytes, page.capacity_bytes) catch std.math.maxInt(usize);
                continue;
            }
            live_bytes = std.math.add(usize, live_bytes, page.live_bytes) catch std.math.maxInt(usize);
            committed_bytes = std.math.add(usize, committed_bytes, page.capacity_bytes) catch std.math.maxInt(usize);
            free_bytes = std.math.add(usize, free_bytes, page.free_bytes) catch std.math.maxInt(usize);
        }

        if (live_bytes != space.live_bytes) return error.PageLiveBytesMismatch;
        if (committed_bytes != space.committed_bytes) return error.PageCommittedBytesMismatch;
        if (free_bytes != space.free_bytes) return error.PageFreeBytesMismatch;
        if (decommitted_bytes != space.decommitted_bytes) return error.PageDecommittedBytesMismatch;
    }

    fn samePageSpace(lhs: Generation, rhs: Generation) bool {
        return switch (lhs) {
            .young => rhs == .young,
            .old, .immortal => rhs == .old or rhs == .immortal,
            .large => rhs == .large,
        };
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

    pub fn replaceNode(self: *Registry, old_node: *GcNode, new_node: *GcNode) void {
        new_node.prev = old_node.prev;
        new_node.next = old_node.next;
        new_node.tmp_rc = old_node.tmp_rc;
        new_node.color = old_node.color;
        new_node._pad = old_node._pad;
        if (old_node.prev) |prev| {
            prev.next = new_node;
        } else {
            self.gc_obj_list_head = new_node;
        }
        if (old_node.next) |next| {
            next.prev = new_node;
        } else {
            self.gc_obj_list_tail = new_node;
        }
        old_node.prev = null;
        old_node.next = null;
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
    if (rt.gc.forwardedHeader(header)) |forwarded| {
        if (forwarded != header) {
            release(rt, forwarded);
            return;
        }
    }
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
