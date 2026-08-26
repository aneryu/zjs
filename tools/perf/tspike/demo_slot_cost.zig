//! Controlled demo: what is a property read's probe chain actually worth?
//!
//! The engine A/B answered "the whole prototype buys 3.8% wall on one
//! workload". That number mixes four things: the probe chain, the rest of the
//! handler, the dispatch floor, and whatever ILP the surrounding code has to
//! hide all of it. This demo separates them by rebuilding ONLY the data
//! structures zjs actually uses and timing the two access forms directly.
//!
//! Layouts are copied field-for-field from src/core/{object,shape,property}.zig
//! (Object 64B, Shape 56B + inline FAM [props u64 x prop_size][buckets u32],
//! Property = packed{hash_next:u26, flags:u6, atom_id:u32}, values in a
//! separate 16-byte-per-entry array). The probe is a transcription of
//! Object.findOwnDataSlotFast, including the two loads needed to compute the
//! bucket array base (prop_size) and the mask.
//!
//! Regimes (mode argument):
//!   dep-probe / dep-slot     dependent chain: each access feeds the next
//!                            index. No ILP to hide latency => this is the
//!                            mechanism's CEILING.
//!   ind-probe / ind-slot     independent accesses summed. ILP-friendly.
//!   fp-probe  / fp-slot      independent accesses interleaved with float
//!                            math, like the engine benchmark's physics loop.
//!   disp-probe / disp-slot   same as ind-*, but every access goes through an
//!                            indirect call through a function-pointer table,
//!                            standing in for the interpreter's dispatch.
//!
//! Run each mode under `perf stat` pinned; compare probe vs slot within a
//! regime. Cross-regime comparison shows how much of the mechanism the
//! surrounding code was hiding.

const std = @import("std");

// hash_next is 26 bits wide, so the sentinel must fit in u26 (same
// constraint the engine's Property packing imposes).
const no_property_index: u32 = std.math.maxInt(u26);

const Property = packed struct(u64) {
    hash_next: u26,
    flags: u6,
    atom_id: u32,
};

const Value = extern struct { payload: u64, tag: i64 };

const Shape = extern struct {
    header: [16]u8 = @splat(0),
    is_hashed: bool = false,
    hash: u32 = 0,
    prop_hash_mask: u32 = 0,
    prop_size: u32 = 0,
    prop_count: u32 = 0,
    deleted_prop_count: u32 = 0,
    registry_hash_next: ?*Shape = null,
    proto: ?*Object = null,
    /// The spike's identity field sits right after the fixed fields; the FAM
    /// starts after it, exactly as in the prototype build.
    identity: u64 = 0,

    inline fn props(self: *const Shape) [*]Property {
        const base: [*]u8 = @constCast(@ptrCast(self));
        return @alignCast(@ptrCast(base + @sizeOf(Shape)));
    }
    inline fn buckets(self: *const Shape) [*]u32 {
        const base: [*]u8 = @constCast(@ptrCast(self));
        return @alignCast(@ptrCast(base + @sizeOf(Shape) + @sizeOf(Property) * self.prop_size));
    }
};

const Object = extern struct {
    header: [16]u8 = @splat(0),
    weakref_count: u32 = 0,
    class_id: u16 = 0,
    flags: u16 = 0,
    shape_ref: *Shape,
    prop_values: [*]Value,
    tail: [24]u8 = @splat(0),
};

/// Transcription of Object.findOwnDataSlotFast: bucket index from the atom and
/// the mask, bucket array base derived from prop_size, then the hash_next walk
/// with the atom compare and the kind-bits test.
inline fn probe(obj: *const Object, atom_id: u32) ?*Value {
    const shape = obj.shape_ref;
    const props = shape.props();
    var chain = shape.buckets()[atom_id & shape.prop_hash_mask];
    while (chain != no_property_index) {
        const index: usize = @intCast(chain);
        const prop = props[index];
        chain = prop.hash_next;
        if (prop.atom_id == atom_id) {
            if ((prop.flags >> 3) & 0x3 != 0) return null;
            // `index`, not the advanced `chain` -- the engine keeps the
            // matching index in its own local for exactly this reason.
            return &obj.prop_values[index];
        }
    }
    return null;
}

const Site = extern struct {
    guard_key: u64 = 0,
    slot_index: u32 = 0,
    pad: u32 = 0,
    pad2: u64 = 0,
    pad3: u64 = 0, // 32 bytes, matching the prototype's site entry stride
};

inline fn guarded(obj: *const Object, s: *const Site) ?*Value {
    if (obj.shape_ref.identity != s.guard_key) return null;
    return &obj.prop_values[s.slot_index];
}

const object_count = 64;
const prop_count = 8;
const prop_size = 8;
const bucket_count = 16;

var shape_storage: [@sizeOf(Shape) + @sizeOf(Property) * prop_size + @sizeOf(u32) * bucket_count]u8 align(16) = @splat(0);
var objects: [object_count]Object = undefined;
var values: [object_count][prop_count]Value = undefined;
var site: Site = .{};

/// Atoms are spread so the target property is NOT the first bucket entry:
/// a realistic site walks one or two links, like the engine's own tables.
const atoms = [prop_count]u32{ 101, 117, 133, 149, 165, 181, 197, 213 };
const target_atom: u32 = atoms[5];

fn setup() void {
    const shape: *Shape = @alignCast(@ptrCast(&shape_storage));
    shape.* = .{ .prop_hash_mask = bucket_count - 1, .prop_size = prop_size, .prop_count = prop_count, .identity = 0x51A7_0000_0000_0001 };
    const props = shape.props();
    const buckets = shape.buckets();
    for (0..bucket_count) |i| buckets[i] = no_property_index;
    for (atoms, 0..) |a, i| {
        const b = a & (bucket_count - 1);
        props[i] = .{ .hash_next = @intCast(buckets[b]), .flags = 1, .atom_id = a };
        buckets[b] = @intCast(i);
    }
    for (&objects, 0..) |*o, i| {
        o.* = .{ .shape_ref = shape, .prop_values = &values[i] };
        for (&values[i], 0..) |*v, j| v.* = .{ .payload = @intCast((i * 7 + j) % object_count), .tag = 0 };
    }
    site = .{ .guard_key = shape.identity, .slot_index = 5 };
}

const iters = 40_000_000;

fn runDependent(comptime use_slot: bool) u64 {
    var idx: usize = 0;
    var acc: u64 = 0;
    for (0..iters) |_| {
        const o = &objects[idx];
        const slot = if (use_slot) guarded(o, &site).? else probe(o, target_atom).?;
        // The loaded value picks the next object: a true dependent chain, so
        // the access latency cannot be overlapped.
        idx = @intCast(slot.payload & (object_count - 1));
        acc +%= idx;
    }
    return acc;
}

fn runIndependent(comptime use_slot: bool) u64 {
    var acc: u64 = 0;
    for (0..iters) |i| {
        const o = &objects[i & (object_count - 1)];
        const slot = if (use_slot) guarded(o, &site).? else probe(o, target_atom).?;
        acc +%= slot.payload;
    }
    return acc;
}

fn runFloatMixed(comptime use_slot: bool) u64 {
    var acc: u64 = 0;
    var f: f64 = 1.0;
    for (0..iters) |i| {
        const o = &objects[i & (object_count - 1)];
        const slot = if (use_slot) guarded(o, &site).? else probe(o, target_atom).?;
        acc +%= slot.payload;
        // Independent float work, the shape of the engine benchmark's physics
        // loop: plenty of ILP for the machine to hide the access behind.
        f = f * 1.0000001 + 0.5;
        f = f - @floor(f) + 1.0;
    }
    return acc +% @as(u64, @intFromFloat(f * 1000.0));
}

const AccessFn = *const fn (*const Object) u64;

fn accessProbe(o: *const Object) u64 {
    return probe(o, target_atom).?.payload;
}
fn accessSlot(o: *const Object) u64 {
    return guarded(o, &site).?.payload;
}
var access_table: [2]AccessFn = .{ accessProbe, accessSlot };

fn runDispatched(use_slot: bool) u64 {
    var acc: u64 = 0;
    // Indirect call through a runtime-indexed table on every access: the
    // interpreter's dispatch floor, deliberately not devirtualizable.
    const which: usize = if (use_slot) 1 else 0;
    for (0..iters) |i| {
        const o = &objects[i & (object_count - 1)];
        acc +%= access_table[which](o);
    }
    return acc;
}

pub fn main() !void {
    setup();
    // Mode via env var (std.c.getenv is the idiom this repo already uses for
    // diagnostic switches); avoids the moving target of the args API.
    const raw = std.c.getenv("DEMO_MODE") orelse return error.NoMode;
    const mode = std.mem.span(raw);
    const acc: u64 = if (std.mem.eql(u8, mode, "dep-probe")) runDependent(false)
        else if (std.mem.eql(u8, mode, "dep-slot")) runDependent(true)
        else if (std.mem.eql(u8, mode, "ind-probe")) runIndependent(false)
        else if (std.mem.eql(u8, mode, "ind-slot")) runIndependent(true)
        else if (std.mem.eql(u8, mode, "fp-probe")) runFloatMixed(false)
        else if (std.mem.eql(u8, mode, "fp-slot")) runFloatMixed(true)
        else if (std.mem.eql(u8, mode, "disp-probe")) runDispatched(false)
        else if (std.mem.eql(u8, mode, "disp-slot")) runDispatched(true)
        else return error.UnknownMode;
    std.debug.print("{s} acc={d}\n", .{ mode, acc });
}
