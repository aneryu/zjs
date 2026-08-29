//! Shadow runtime write audit (tracing-gc-design.md §5.2 / Stage 2).
//!
//! Compile-time census cannot see FAM/slice stores, `@memcpy` of live
//! JSValue/Entry storage, union arms selected by Shape flags, or opaque
//! plugin memory. This observer records those bypasses at runtime.
//!
//! Hits are the Stage 6 barrier candidate list; they are not a failure.
//! Default `rc` never imports this module (`core/root.zig`).

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const enabled = builtin.is_test or std.mem.eql(u8, build_options.zjs_gc, "shadow");

/// Bypass class named by design §5.2. `plugin_opaque` is reserved: host DSO
/// stores into class payload are outside the engine ABI and stay
/// uninstrumented (always 0 from engine choke points).
pub const Kind = enum {
    fam_slice,
    memcpy_bulk,
    union_arm,
    shape_slot,
    plugin_opaque,
};

/// Named choke point. `slot_api` is the allowed path (counted separately via
/// `noteSlot`); every other site is a Slot bypass.
pub const Site = enum {
    object_prop_values_memcpy,
    object_prop_slot,
    object_set_entry_kind_and_slot,
    object_dense_memcpy,
    object_dense_store,
    object_collection_memcpy,
    object_collection_store,
    object_weak_collection_memcpy,
    object_finalization_memcpy,
    object_disposable_memcpy,
    object_iterator_cache_memcpy,
    collection_entries_memcpy,
    generator_values_memcpy,
    slot_api,
    plugin_opaque,
};

const kind_count = @typeInfo(Kind).@"enum".fields.len;
const site_count = @typeInfo(Site).@"enum".fields.len;

var kind_counts: [kind_count]std.atomic.Value(usize) = @splat(.init(0));
var site_counts: [site_count]std.atomic.Value(usize) = @splat(.init(0));
var slot_writes: std.atomic.Value(usize) = .init(0);

pub fn hit(kind: Kind, site: Site) void {
    hitN(kind, site, 1);
}

pub fn hitN(kind: Kind, site: Site, n: usize) void {
    if (n == 0) return;
    _ = kind_counts[@intFromEnum(kind)].fetchAdd(n, .monotonic);
    _ = site_counts[@intFromEnum(site)].fetchAdd(n, .monotonic);
}

/// Slot API publish. Not a bypass; compared against hits at report time.
pub fn noteSlot() void {
    _ = slot_writes.fetchAdd(1, .monotonic);
}

pub fn reset() void {
    for (&kind_counts) |*counter| counter.store(0, .monotonic);
    for (&site_counts) |*counter| counter.store(0, .monotonic);
    slot_writes.store(0, .monotonic);
}

pub const Snapshot = struct {
    kind: [kind_count]usize = @splat(0),
    site: [site_count]usize = @splat(0),
    slot_writes: usize = 0,

    pub fn hits(self: Snapshot) usize {
        var total: usize = 0;
        for (self.kind) |count| total += count;
        return total;
    }

    pub fn kindCount(self: Snapshot, kind: Kind) usize {
        return self.kind[@intFromEnum(kind)];
    }

    pub fn siteCount(self: Snapshot, site: Site) usize {
        return self.site[@intFromEnum(site)];
    }

    pub fn format(self: Snapshot, writer: anytype) !void {
        try writer.print(
            "write-audit: hits={d} slot_writes={d} (hits are Stage 6 candidates, not a failure)\n",
            .{ self.hits(), self.slot_writes },
        );
        try writer.print("  by kind:", .{});
        inline for (@typeInfo(Kind).@"enum".fields) |field| {
            const count = self.kind[field.value];
            if (count != 0) try writer.print(" {s}={d}", .{ field.name, count });
        }
        try writer.print("\n  by site:\n", .{});
        inline for (@typeInfo(Site).@"enum".fields) |field| {
            const count = self.site[field.value];
            if (count != 0) try writer.print("    {s}: {d}\n", .{ field.name, count });
        }
        if (self.kindCount(.plugin_opaque) == 0) {
            try writer.print("    plugin_opaque: uninstrumented (host DSO ABI)\n", .{});
        }
    }
};

pub fn snapshot() Snapshot {
    var kind: [kind_count]usize = undefined;
    var site: [site_count]usize = undefined;
    for (&kind, &kind_counts) |*dst, *src| dst.* = src.load(.monotonic);
    for (&site, &site_counts) |*dst, *src| dst.* = src.load(.monotonic);
    return .{
        .kind = kind,
        .site = site,
        .slot_writes = slot_writes.load(.monotonic),
    };
}

pub fn format(writer: anytype) !void {
    try snapshot().format(writer);
}
