//! Runtime-owned native allocation and allocation diagnostics.
//! Native allocations never enter GC cell storage or its heap budget.
//! The optional probe preserves test/force-GC observation at opted-in callers.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const JSRuntime = @import("runtime.zig").JSRuntime;

pub const diagnostic_accounting_enabled = builtin.is_test or builtin.mode == .Debug;

/// OOM-injection coverage (v1), gated by `-Dzjs_oom_coverage` (default
/// false; the recording branches below are `comptime`-eliminated so the
/// default build's allocation hot path is unchanged).
///
/// When enabled, every `Runtime allocation helpers` allocation entry point records its
/// caller via `@returnAddress()` into a process-global deduplicated set.
/// `zig build test-oom -Dzjs_oom_coverage=true` reports the number of
/// distinct allocation call sites the OOM corpus reached, giving a
/// comparable coverage figure across corpus changes.
///
/// v1 scope: a raw count of distinct return addresses (no symbolization).
/// Possible evolution: symbolize sites via std.debug.SelfInfo for a
/// human-readable report, track per-site hit counts, capture the direct
/// nativeAllocator container call sites at the backing-allocator
/// vtable instead, and schedule fail-injection toward not-yet-failed sites.
pub const oom_coverage_enabled: bool = build_options.zjs_oom_coverage;

pub const force_gc_on_allocation_enabled: bool = build_options.zjs_force_gc;

/// Whether an ordinary allocation consults the GC threshold at all.
///
/// QuickJS reaches its allocation-threshold GC from exactly one site:
/// `js_trigger_gc(ctx->rt, sizeof(JSObject))` at the top of
/// `JS_NewObjectFromShape`. The allocators underneath it —
/// `js_malloc_rt` / `js_realloc_rt` / `js_mallocz_rt`
/// and the `__js_malloc` family they call — only ever check
/// `malloc_limit`; none of them reads `malloc_gc_threshold`, which is touched
/// exclusively by `js_trigger_gc` itself. Property
/// arrays, bytecode buffers, atom tables and parser scratch
/// therefore carry no per-allocation GC bookkeeping in QuickJS at all.
///
/// zjs mirrors that shape: `JSRuntime.collectBeforeObjectAllocation` is the
/// single production threshold boundary. The condition is level-triggered on
/// the heap budget's `bytes`, and it is recomputed from scratch at that
/// boundary and again at every `pollGC` (`over_threshold` feeds
/// `Registry.shouldRunMajorAt`), so a crossing produced by a non-object
/// allocation is still serviced at the next boundary — exactly as a prop-array
/// `js_malloc` crossing in qjs waits for the next `js_trigger_gc`. Recording a
/// request per allocation adds no scheduling information those boundaries
/// cannot recompute.
///
/// TGC S2-f (3) adds the one deliberate divergence: string bodies are
/// collector carriers under the tracer, not malloc+refcount as in qjs, so
/// `String.createUninitialized` / `allocRopeNode` cross the SAME
/// `collectBeforeObjectAllocation` boundary. That is still one boundary
/// function, not a per-allocation trigger.
///
/// Test builds inject probes through `Budget.probe` to observe allocation
/// events, and force-GC builds must still collect before every allocation, so
/// those comptime modes retain the full per-allocation notify. The heap-limit
/// retry is `Budget.admit`, not this notify. `NoTrigger` allocations skip
/// notify and retry, but GC allocations still enforce `Budget.checkOnly`.
pub const allocation_gc_trigger_enabled: bool = builtin.is_test or force_gc_on_allocation_enabled;

pub const oom_coverage = struct {
    // Plain atomic spinlock: diagnostic instrumentation must not depend on
    // an Io handle (std.Io.Mutex) and contention is negligible (worker
    // threads only).
    var lock_state: std.atomic.Value(bool) = .init(false);
    var sites: std.AutoHashMapUnmanaged(usize, void) = .empty;

    fn lock() void {
        while (lock_state.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    fn unlock() void {
        lock_state.store(false, .release);
    }

    pub fn record(site: usize) void {
        lock();
        defer unlock();
        // Diagnostic-only bookkeeping: the set grows via page_allocator so
        // it never perturbs engine allocation counts; a failed insert just
        // drops one sample.
        sites.put(std.heap.page_allocator, site, {}) catch {};
    }
};

/// Number of distinct allocation call sites observed since process start.
/// The set is never reset -- there is no reset entry point. Always 0 when
/// coverage is disabled.
pub fn oomCoverageDistinctSiteCount() usize {
    if (comptime !oom_coverage_enabled) return 0;
    oom_coverage.lock();
    defer oom_coverage.unlock();
    return oom_coverage.sites.count();
}

/// Optional observations, never a production allocator or a heap budget.
pub const AllocationDiagnostics = struct {
    allocated_bytes: usize = 0,
    allocation_count: usize = 0,
    peak_allocated_bytes: usize = 0,
    peak_allocation_count: usize = 0,
    alloc_calls: usize = 0,
    free_calls: usize = 0,
    create_calls: usize = 0,
    destroy_calls: usize = 0,
    /// Failure injection only; production never reads this field.
    limit: ?usize = null,
};

/// Production allocations go straight to the host allocator. Debug/test builds
/// interpose only to record diagnostics and inject failures, never to enforce
/// a production-wide native-memory quota or to collect during container growth.
pub fn nativeAllocator(self: *JSRuntime) std.mem.Allocator {
    return nativeAllocatorWithBacking(self, self.allocator);
}

/// Build the facade without reading Runtime storage. The context must be
/// initialized before the first allocation, resize, or free through it.
pub fn nativeAllocatorWithBacking(self: *JSRuntime, backing: std.mem.Allocator) std.mem.Allocator {
    if (comptime !diagnostic_accounting_enabled) return backing;
    return .{ .ptr = self, .vtable = &diagnostic_allocator_vtable };
}

/// Container allocations with the same accounting and probe behavior as
/// alloc/free. Constructing this facade does not read the Runtime context.
pub fn probedAllocator(self: *JSRuntime) std.mem.Allocator {
    return .{ .ptr = self, .vtable = &probed_allocator_vtable };
}

const probed_allocator_vtable: std.mem.Allocator.VTable = .{
    .alloc = probedAlloc,
    .resize = diagnosticResize,
    .remap = diagnosticRemap,
    .free = diagnosticFree,
};

fn probedAlloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const self: *JSRuntime = @ptrCast(@alignCast(context));
    const bytes = allocAlignedBytesInternal(self, len, alignment, true) catch return null;
    return bytes.ptr;
}

const diagnostic_allocator_vtable: std.mem.Allocator.VTable = .{
    .alloc = diagnosticAlloc,
    .resize = diagnosticResize,
    .remap = diagnosticRemap,
    .free = diagnosticFree,
};

fn diagnosticAlloc(
    context: *anyopaque,
    len: usize,
    alignment: std.mem.Alignment,
    return_address: usize,
) ?[*]u8 {
    _ = return_address;
    const self: *JSRuntime = @ptrCast(@alignCast(context));
    // Raw library/container allocation is accounted but is not a new GC
    // safepoint. Object creation owns the QuickJS-aligned threshold trigger.
    const allocation = allocAlignedBytesNoTrigger(self, len, alignment) catch return null;
    return allocation.ptr;
}

fn diagnosticResize(
    context: *anyopaque,
    bytes: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    return_address: usize,
) bool {
    const self: *JSRuntime = @ptrCast(@alignCast(context));
    if (new_len == bytes.len) return true;
    if (new_len > bytes.len) {
        const growth = new_len - bytes.len;
        checkAllocation(self, growth) catch return false;
    }
    if (!self.allocator.rawResize(bytes, alignment, new_len, return_address)) return false;
    recordResize(self, bytes.len, new_len);
    return true;
}

fn diagnosticRemap(
    context: *anyopaque,
    bytes: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    return_address: usize,
) ?[*]u8 {
    const self: *JSRuntime = @ptrCast(@alignCast(context));
    if (new_len == bytes.len) return bytes.ptr;
    if (new_len > bytes.len) {
        const growth = new_len - bytes.len;
        checkAllocation(self, growth) catch return null;
    }
    const remapped = self.allocator.rawRemap(bytes, alignment, new_len, return_address) orelse return null;
    recordResize(self, bytes.len, new_len);
    return remapped;
}

fn diagnosticFree(
    context: *anyopaque,
    bytes: []u8,
    alignment: std.mem.Alignment,
    return_address: usize,
) void {
    _ = return_address;
    const self: *JSRuntime = @ptrCast(@alignCast(context));
    freeAlignedBytes(self, bytes, alignment);
}

fn recordResize(self: *JSRuntime, old_len: usize, new_len: usize) void {
    if (comptime !diagnostic_accounting_enabled) return;
    if (new_len > old_len) {
        self.diagnostics.allocations.allocated_bytes += new_len - old_len;
    } else {
        self.diagnostics.allocations.allocated_bytes -= old_len - new_len;
    }
    if (comptime diagnostic_accounting_enabled) updatePeak(self);
}

/// Replace an exact-fit native array with a larger allocation and copy.
/// old_count == 0 means there is no old buffer to free.
pub noinline fn reallocElements(
    self: *JSRuntime,
    old_ptr: [*]u8,
    old_count: usize,
    new_count: usize,
    elem_size: usize,
    alignment: std.mem.Alignment,
) ![]u8 {
    std.debug.assert(new_count > old_count);
    const new_buf = try allocElements(self, new_count, elem_size, alignment);
    const used_bytes = std.math.mul(usize, old_count, elem_size) catch return error.OutOfMemory;
    if (used_bytes != 0) @memcpy(new_buf[0..used_bytes], old_ptr[0..used_bytes]);
    if (old_count != 0) freeAlignedBytes(self, old_ptr[0..used_bytes], alignment);
    return new_buf;
}

pub inline fn noteAllocDiagnostics(
    self: *JSRuntime,
    comptime is_create: bool,
) void {
    if (comptime diagnostic_accounting_enabled) {
        self.diagnostics.allocations.allocation_count += 1;
        if (comptime is_create) {
            self.diagnostics.allocations.create_calls += 1;
        } else {
            self.diagnostics.allocations.alloc_calls += 1;
        }
        updatePeak(self);
        if (self.opcode_profile) |prof| prof.recordAlloc();
    }
}

pub inline fn noteFreeDiagnostics(self: *JSRuntime, comptime is_destroy: bool) void {
    if (comptime diagnostic_accounting_enabled) {
        self.diagnostics.allocations.allocation_count -= 1;
        if (comptime is_destroy) {
            self.diagnostics.allocations.destroy_calls += 1;
        } else {
            self.diagnostics.allocations.free_calls += 1;
        }
    }
}

/// Attempts to resize an existing native allocation through the backing
/// allocator. Returns null when that allocator cannot grow it without a
/// caller-managed copy. Ordinary native memory is not slab-backed.
pub fn remap(self: *JSRuntime, comptime T: type, slice: []T, new_count: usize) !?[]T {
    comptime requireNative(T);
    if (slice.len == 0) return null;
    if (new_count == 0) {
        free(self, T, slice);
        return &.{};
    }
    const old_bytes = std.math.mul(usize, @sizeOf(T), slice.len) catch return error.OutOfMemory;
    const new_bytes = std.math.mul(usize, @sizeOf(T), new_count) catch return error.OutOfMemory;
    if (new_bytes == old_bytes) return slice.ptr[0..new_count];
    if (new_bytes > old_bytes) try checkAllocation(self, new_bytes - old_bytes);
    const alignment = std.mem.Alignment.of(T);
    const old_raw: []u8 = @as([*]u8, @ptrCast(slice.ptr))[0..old_bytes];
    const remapped_ptr = self.allocator.rawRemap(old_raw, alignment, new_bytes, @returnAddress()) orelse return null;
    recordResize(self, old_bytes, new_bytes);
    if (comptime diagnostic_accounting_enabled) {
        updatePeak(self);
    }
    const new_ptr: [*]T = @ptrCast(@alignCast(remapped_ptr));
    return new_ptr[0..new_count];
}

/// Native byte allocation without a GC probe; the caller owns GC preparation.
pub fn allocAlignedBytesNoTrigger(self: *JSRuntime, byte_count: usize, alignment: std.mem.Alignment) ![]u8 {
    return allocAlignedBytesInternal(self, byte_count, alignment, false);
}

fn allocAlignedBytesInternal(self: *JSRuntime, byte_count: usize, alignment: std.mem.Alignment, comptime trigger_gc: bool) ![]u8 {
    if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
    if (byte_count == 0) return &.{};
    return allocAlignedBytesSlow(self, byte_count, alignment, trigger_gc);
}

/// Native backing allocation with optional diagnostic limit and probe.
noinline fn allocAlignedBytesSlow(self: *JSRuntime, byte_count: usize, alignment: std.mem.Alignment, comptime trigger_gc: bool) ![]u8 {
    try checkAllocation(self, byte_count);
    if (comptime trigger_gc) {
        self.gc.noteAllocationProbe(byte_count);
    }
    const ptr = self.allocator.rawAlloc(byte_count, alignment, @returnAddress()) orelse
        return error.OutOfMemory;
    creditAlloc(self, byte_count);
    noteAllocDiagnostics(self, false);
    return ptr[0..byte_count];
}

pub noinline fn freeAlignedBytes(self: *JSRuntime, bytes: []u8, alignment: std.mem.Alignment) void {
    if (bytes.len == 0) return;
    if (comptime diagnostic_accounting_enabled) {
        self.diagnostics.allocations.allocation_count -= 1;
        self.diagnostics.allocations.free_calls += 1;
    }
    debitAlloc(self, bytes.len);
    self.allocator.rawFree(bytes, alignment, @returnAddress());
}

pub fn hasOutstandingAllocations(self: *const JSRuntime) bool {
    if (comptime diagnostic_accounting_enabled) {
        return self.diagnostics.allocations.allocated_bytes != 0 or self.diagnostics.allocations.allocation_count != 0;
    }
    return self.diagnostics.allocations.allocated_bytes != 0;
}

/// Debug/test failure-injection cap on diagnostic allocation bytes. This is
/// not the JS heap limit; enforcement is absent when diagnostics are disabled.
pub fn setLimit(self: *JSRuntime, limit: ?usize) void {
    self.diagnostics.allocations.limit = limit;
}

/// Returns the diagnostic failure-injection cap, not Registry.heap_budget.limit.
pub fn getLimit(self: *const JSRuntime) ?usize {
    return self.diagnostics.allocations.limit;
}

/// Diagnostic failure-injection check used by native and GC allocation routes.
/// The JS heap limit is enforced separately by admitHeapCharge.
pub fn checkAllocation(self: *JSRuntime, bytes: usize) !void {
    if (comptime !diagnostic_accounting_enabled) return;
    const limit = self.diagnostics.allocations.limit orelse {
        @branchHint(.likely);
        return;
    };
    const next = std.math.add(usize, self.diagnostics.allocations.allocated_bytes, bytes) catch return error.OutOfMemory;
    if (next > limit) return error.OutOfMemory;
}

/// Sample the lifetime account high-water at a collection boundary.
///
/// Per-allocation peak tracking is Debug/test-only (`updatePeak` under
/// `diagnostic_accounting_enabled`) because a RMW per allocation is the
/// kind of tax this allocator exists to avoid. This historical field is a
/// cheap lifetime diagnostic, not §1.3's cycle peak: allocations continue
/// while an incremental major is open. GC cycle peaks are tracked separately
/// by heap_budget, using the same bytes as the production heap budget.
pub fn samplePeakAtCollection(self: *JSRuntime) void {
    if (comptime !diagnostic_accounting_enabled) return;
    updatePeak(self);
}

fn updatePeak(self: *JSRuntime) void {
    if (comptime !diagnostic_accounting_enabled) return;
    self.diagnostics.allocations.peak_allocated_bytes = @max(self.diagnostics.allocations.peak_allocated_bytes, self.diagnostics.allocations.allocated_bytes);
    self.diagnostics.allocations.peak_allocation_count = @max(self.diagnostics.allocations.peak_allocation_count, self.diagnostics.allocations.allocation_count);
}

pub inline fn creditAlloc(self: *JSRuntime, bytes: usize) void {
    if (comptime diagnostic_accounting_enabled) self.diagnostics.allocations.allocated_bytes +%= bytes;
}

pub inline fn debitAlloc(self: *JSRuntime, bytes: usize) void {
    if (comptime diagnostic_accounting_enabled) self.diagnostics.allocations.allocated_bytes -%= bytes;
}

fn requireNative(comptime T: type) void {
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, "gc_kind_tag"))
        @compileError("GC cells must be allocated and released through Registry");
}

/// Returns native memory; release through free or the same Runtime allocator.
pub inline fn alloc(self: *JSRuntime, comptime T: type, count: usize) ![]T {
    return allocTyped(self, T, count, true);
}

pub inline fn allocNoTrigger(self: *JSRuntime, comptime T: type, count: usize) ![]T {
    return allocTyped(self, T, count, false);
}

fn allocTyped(self: *JSRuntime, comptime T: type, count: usize, comptime probe: bool) ![]T {
    comptime requireNative(T);
    if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
    if (count == 0) return &.{};
    const size = std.math.mul(usize, @sizeOf(T), count) catch return error.OutOfMemory;
    const bytes = try allocAlignedBytesSlow(self, size, std.mem.Alignment.of(T), probe);
    return @as([*]T, @ptrCast(@alignCast(bytes.ptr)))[0..count];
}

/// Type-erased native array allocation, paired with freeAlignedBytes.
pub fn allocElements(self: *JSRuntime, count: usize, elem_size: usize, alignment: std.mem.Alignment) ![]u8 {
    if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
    if (count == 0) return &.{};
    const size = std.math.mul(usize, elem_size, count) catch return error.OutOfMemory;
    return allocAlignedBytesSlow(self, size, alignment, true);
}

pub inline fn free(self: *JSRuntime, comptime T: type, slice: []T) void {
    comptime requireNative(T);
    if (slice.len == 0) return;
    freeAlignedBytes(self, @as([*]u8, @ptrCast(slice.ptr))[0 .. @sizeOf(T) *% slice.len], std.mem.Alignment.of(T));
}

/// Returns an uninitialized native value; release through destroy.
pub inline fn create(self: *JSRuntime, comptime T: type) !*T {
    return createTyped(self, T, true);
}

pub inline fn createNoTrigger(self: *JSRuntime, comptime T: type) !*T {
    return createTyped(self, T, false);
}

fn createTyped(self: *JSRuntime, comptime T: type, comptime probe: bool) !*T {
    comptime requireNative(T);
    if (comptime oom_coverage_enabled) oom_coverage.record(@returnAddress());
    return @ptrCast(@alignCast(try createSlow(self, @sizeOf(T), std.mem.Alignment.of(T), probe)));
}

noinline fn createSlow(self: *JSRuntime, size: usize, alignment: std.mem.Alignment, comptime probe: bool) ![*]u8 {
    try checkAllocation(self, size);
    if (comptime probe) self.gc.noteAllocationProbe(size);
    const ptr = self.allocator.rawAlloc(size, alignment, @returnAddress()) orelse return error.OutOfMemory;
    creditAlloc(self, size);
    noteAllocDiagnostics(self, true);
    return ptr;
}

pub inline fn destroy(self: *JSRuntime, comptime T: type, ptr: *T) void {
    comptime requireNative(T);
    destroySlow(self, @as([*]u8, @ptrCast(ptr))[0..@sizeOf(T)], std.mem.Alignment.of(T));
}

noinline fn destroySlow(self: *JSRuntime, bytes: []u8, alignment: std.mem.Alignment) void {
    debitAlloc(self, bytes.len);
    noteFreeDiagnostics(self, true);
    self.allocator.rawFree(bytes, alignment, @returnAddress());
}
