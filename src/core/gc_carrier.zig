//! Allocation-carrier identity shared by the tracing allocator and collector.
//!
//! This module deliberately knows neither `gc.Header` nor `Registry`.  Raw
//! allocation code writes the authority before an object can be published;
//! collector code supplies the immutable kind and lifecycle transitions only
//! after a carrier has made dereferencing the header legal.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

/// Tests and explicit ownership-audit builds carry the shadow carrier
/// authorities (block generation, extent identity, lifecycle state, and the
/// heap-accounting oracle); shipped builds carry none of them. The
/// per-component "production selection" lattice that used to sit here never
/// had a production point and was removed in the 2026-09-03 ablation.
pub const authority_audit_enabled: bool = builtin.is_test or build_options.zjs_ownership_audit;
pub const block_generation_enabled: bool = authority_audit_enabled;
pub const extent_identity_enabled: bool = authority_audit_enabled;
pub const lifecycle_state_enabled: bool = authority_audit_enabled;
pub const audit_oracle_enabled: bool = authority_audit_enabled;
pub const block_tracking_enabled: bool = authority_audit_enabled;
pub const extent_tracking_enabled: bool = authority_audit_enabled;

pub const CurrentMembershipKey = extern struct {
    base: usize,
};

pub const AllocationHandle = extern struct {
    base: usize,
    generation: u64,
};

pub const LifecycleState = enum(u4) {
    free,
    constructing,
    published,
    doomed,
    finalizer_current,
    parked,
    rollback_pending,
    raw_free_in_progress,
};

pub const StateMask = packed struct {
    bits: u16 = 0,

    pub fn of(states: []const LifecycleState) StateMask {
        var mask: u16 = 0;
        for (states) |state| mask |= @as(u16, 1) << @intFromEnum(state);
        return .{ .bits = mask };
    }

    pub fn publishedOnly() StateMask {
        return of(&.{.published});
    }

    pub fn owned() StateMask {
        return .{ .bits = ~@as(u16, 1) };
    }

    pub fn contains(self: StateMask, state: LifecycleState) bool {
        return self.bits & (@as(u16, 1) << @intFromEnum(state)) != 0;
    }
};

pub const ResolveError = error{
    NotFound,
    NotExactStart,
    GenerationMismatch,
    StateMismatch,
    KindMismatch,
    HeaderMismatch,
};

pub const ExtentReservation = struct { generation: u64 };

pub const ExtentIdentityRecord = struct {
    base: usize,
    raw_base: usize,
    payload_bytes: usize,
    raw_bytes: usize,
    generation: u64,
    kind: u8,
};

/// Non-block generations are runtime-monotonic.  Capacity is reserved before
/// the raw allocator is entered, so `commit` is the no-fail publication of a
/// still-private allocation record.
pub const ExtentIdentityAuthority = struct {
    records: std.AutoHashMapUnmanaged(usize, ExtentIdentityRecord) = .empty,
    next_generation: u64 = 1,
    generation_exhausted: bool = false,

    pub fn deinit(self: *ExtentIdentityAuthority, allocator: std.mem.Allocator) void {
        self.records.deinit(allocator);
        self.* = .{};
    }

    pub fn reserve(self: *ExtentIdentityAuthority, allocator: std.mem.Allocator) std.mem.Allocator.Error!ExtentReservation {
        if (self.generation_exhausted or self.next_generation == std.math.maxInt(u64)) {
            self.generation_exhausted = true;
            return error.OutOfMemory;
        }
        try self.records.ensureUnusedCapacity(allocator, 1);
        const generation = self.next_generation;
        self.next_generation += 1;
        return .{ .generation = generation };
    }

    pub fn commit(self: *ExtentIdentityAuthority, reservation: ExtentReservation, entry: ExtentIdentityRecord) void {
        std.debug.assert(entry.base != 0);
        std.debug.assert(entry.raw_base != 0);
        std.debug.assert(entry.raw_bytes != 0);
        std.debug.assert(entry.generation == reservation.generation);
        std.debug.assert(!self.records.contains(entry.base));
        self.records.putAssumeCapacity(entry.base, entry);
    }

    pub fn record(self: *const ExtentIdentityAuthority, base: usize) ?*const ExtentIdentityRecord {
        return self.records.getPtr(base);
    }

    fn recordMut(self: *ExtentIdentityAuthority, base: usize) ?*ExtentIdentityRecord {
        return self.records.getPtr(base);
    }

    pub fn handle(self: *const ExtentIdentityAuthority, base: usize) ?AllocationHandle {
        const entry = self.record(base) orelse return null;
        return .{ .base = base, .generation = entry.generation };
    }

    pub fn resolve(
        self: *const ExtentIdentityAuthority,
        allocation_handle: AllocationHandle,
        expected_kind: ?u8,
    ) ResolveError!*const ExtentIdentityRecord {
        const entry = self.record(allocation_handle.base) orelse return error.NotFound;
        if (entry.base != allocation_handle.base) return error.NotExactStart;
        if (entry.generation != allocation_handle.generation) return error.GenerationMismatch;
        if (expected_kind) |kind| if (entry.kind != kind) return error.KindMismatch;
        return entry;
    }

    pub fn finishRawFree(self: *ExtentIdentityAuthority, base: usize) ResolveError!void {
        _ = self.records.fetchRemove(base) orelse return error.NotFound;
    }

    pub fn verify(self: *const ExtentIdentityAuthority) ResolveError!void {
        if (self.next_generation == 0) return error.GenerationMismatch;
        var iterator = self.records.iterator();
        while (iterator.next()) |entry| {
            const record_entry = entry.value_ptr;
            if (entry.key_ptr.* != record_entry.base or record_entry.base == 0 or
                record_entry.raw_base == 0 or record_entry.raw_bytes == 0)
            {
                return error.NotExactStart;
            }
            if (record_entry.generation == 0 or record_entry.generation >= self.next_generation) {
                return error.GenerationMismatch;
            }
        }
    }
};

pub const ExtentLifecycleRecord = struct {
    state: LifecycleState = .constructing,
    accounted_bytes: usize = 0,
};

/// Lifecycle is deliberately a different table from extent identity.  A
/// future generation-only consumer cannot accidentally productionize state
/// transitions (or vice versa) by flipping one aggregate gate.
pub const ExtentLifecycleAuthority = struct {
    records: std.AutoHashMapUnmanaged(usize, ExtentLifecycleRecord) = .empty,

    pub fn deinit(self: *ExtentLifecycleAuthority, allocator: std.mem.Allocator) void {
        self.records.deinit(allocator);
        self.* = .{};
    }

    pub fn prepare(self: *ExtentLifecycleAuthority, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        try self.records.ensureUnusedCapacity(allocator, 1);
    }

    pub fn commit(self: *ExtentLifecycleAuthority, base: usize) void {
        std.debug.assert(base != 0);
        std.debug.assert(!self.records.contains(base));
        self.records.putAssumeCapacity(base, .{});
    }

    pub fn record(self: *const ExtentLifecycleAuthority, base: usize) ?*const ExtentLifecycleRecord {
        return self.records.getPtr(base);
    }

    fn recordMut(self: *ExtentLifecycleAuthority, base: usize) ?*ExtentLifecycleRecord {
        return self.records.getPtr(base);
    }

    pub fn transition(self: *ExtentLifecycleAuthority, base: usize, state: LifecycleState) ResolveError!void {
        const entry = self.recordMut(base) orelse return error.NotFound;
        entry.state = state;
    }

    pub fn publish(self: *ExtentLifecycleAuthority, base: usize, accounted_bytes: usize) ResolveError!void {
        const entry = self.recordMut(base) orelse return error.NotFound;
        entry.state = .published;
        entry.accounted_bytes = accounted_bytes;
    }

    pub fn resolve(self: *const ExtentLifecycleAuthority, base: usize, allowed_states: StateMask) ResolveError!*const ExtentLifecycleRecord {
        const entry = self.record(base) orelse return error.NotFound;
        if (!allowed_states.contains(entry.state)) return error.StateMismatch;
        return entry;
    }

    pub fn finishRawFree(self: *ExtentLifecycleAuthority, base: usize) ResolveError!void {
        const removed = self.records.fetchRemove(base) orelse return error.NotFound;
        if (removed.value.state != .raw_free_in_progress) return error.StateMismatch;
    }

    pub fn verify(self: *const ExtentLifecycleAuthority) ResolveError!void {
        var iterator = self.records.iterator();
        while (iterator.next()) |entry| {
            if (entry.key_ptr.* == 0 or entry.value_ptr.state == .free) return error.StateMismatch;
        }
    }
};

comptime {
    // Pins remain active while their component is enabled.  They therefore
    // guard the act of flipping a gate, not merely today's disabled shape.
    if (@sizeOf(ExtentIdentityRecord) != 48) @compileError("extent identity record budget changed");
    const identity_authority_budget: usize = if (std.debug.runtime_safety) 40 else 32;
    if (@sizeOf(ExtentIdentityAuthority) != identity_authority_budget) @compileError("extent identity authority budget changed");
    if (@sizeOf(ExtentLifecycleRecord) != 16) @compileError("extent lifecycle record budget changed");
    const lifecycle_authority_budget: usize = if (std.debug.runtime_safety) 24 else 16;
    if (@sizeOf(ExtentLifecycleAuthority) != lifecycle_authority_budget) @compileError("extent lifecycle authority budget changed");
}

pub const RawAuditEntry = struct {
    audit_id: u64,
    base: usize,
    raw_base: usize,
    raw_bytes: usize,
    accounted_bytes: usize,
    kind: u8,
    generation: u64,
    published: bool = false,
};

/// Existing P1-independent accounting oracle, extended down to the raw
/// allocation/free seam.  Its audit id is intentionally unrelated to carrier
/// generations so a shared counter cannot make both sides agree by accident.
pub const HeapAccountingOracle = struct {
    heap_live_bytes: usize = 0,
    old_live_bytes: usize = 0,
    large_object_bytes: usize = 0,
    raw: std.AutoHashMapUnmanaged(usize, RawAuditEntry) = .empty,
    next_audit_id: u64 = 1,

    pub fn deinit(self: *HeapAccountingOracle, allocator: std.mem.Allocator) void {
        self.raw.deinit(allocator);
        self.* = .{};
    }

    pub fn prepareRawAlloc(self: *HeapAccountingOracle, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        try self.raw.ensureUnusedCapacity(allocator, 1);
    }

    pub fn recordRawAlloc(self: *HeapAccountingOracle, entry: RawAuditEntry) void {
        std.debug.assert(entry.base != 0 and entry.raw_base != 0 and entry.raw_bytes != 0);
        std.debug.assert(!self.raw.contains(entry.base));
        var stored = entry;
        stored.audit_id = self.next_audit_id;
        self.next_audit_id +%= 1;
        if (self.next_audit_id == 0) self.next_audit_id = 1;
        self.raw.putAssumeCapacity(entry.base, stored);
    }

    pub fn recordRawFree(self: *HeapAccountingOracle, base: usize) void {
        const removed = self.raw.fetchRemove(base) orelse @panic("gc: CARRIER IDENTITY: raw ledger missing free");
        std.debug.assert(!removed.value.published);
    }

    pub fn recordPublish(self: *HeapAccountingOracle, base: usize, bytes: usize, is_large: bool) void {
        std.debug.assert(bytes != 0);
        const entry = self.raw.getPtr(base) orelse @panic("gc: CARRIER IDENTITY: publication missing raw ledger");
        std.debug.assert(!entry.published);
        entry.published = true;
        entry.accounted_bytes = bytes;
        self.heap_live_bytes += bytes;
        if (is_large) self.large_object_bytes += bytes else self.old_live_bytes += bytes;
    }

    pub fn recordUnpublish(self: *HeapAccountingOracle, base: usize, bytes: usize, is_large: bool) void {
        std.debug.assert(bytes != 0);
        const entry = self.raw.getPtr(base) orelse @panic("gc: CARRIER IDENTITY: retirement missing raw ledger");
        std.debug.assert(entry.published);
        entry.published = false;
        std.debug.assert(self.heap_live_bytes >= bytes);
        self.heap_live_bytes -= bytes;
        if (is_large) {
            std.debug.assert(self.large_object_bytes >= bytes);
            self.large_object_bytes -= bytes;
        } else {
            std.debug.assert(self.old_live_bytes >= bytes);
            self.old_live_bytes -= bytes;
        }
    }
};

comptime {
    const oracle_budget: usize = if (std.debug.runtime_safety) 56 else 48;
    if (@sizeOf(HeapAccountingOracle) != oracle_budget) @compileError("heap accounting oracle budget changed");
}

test "extent generations are monotonic across same-base reuse and never wrap" {
    var authority: ExtentIdentityAuthority = .{};
    defer authority.deinit(std.testing.allocator);

    const first = try authority.reserve(std.testing.allocator);
    authority.commit(first, .{
        .base = 0x1000,
        .raw_base = 0x1000,
        .payload_bytes = 32,
        .raw_bytes = 40,
        .generation = first.generation,
        .kind = 0,
    });
    try authority.finishRawFree(0x1000);

    const second = try authority.reserve(std.testing.allocator);
    authority.commit(second, .{
        .base = 0x1000,
        .raw_base = 0x1000,
        .payload_bytes = 32,
        .raw_bytes = 40,
        .generation = second.generation,
        .kind = 0,
    });
    try std.testing.expect(second.generation > first.generation);
    try std.testing.expectError(
        error.GenerationMismatch,
        authority.resolve(.{ .base = 0x1000, .generation = first.generation }, null),
    );
    _ = try authority.resolve(.{ .base = 0x1000, .generation = second.generation }, null);

    authority.next_generation = std.math.maxInt(u64);
    try std.testing.expectError(error.OutOfMemory, authority.reserve(std.testing.allocator));
    try std.testing.expectError(error.OutOfMemory, authority.reserve(std.testing.allocator));
}
