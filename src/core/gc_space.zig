//! Size classes and publication histogram for the 64 KiB block heap
//! (tracing-gc-design.md §4.2 / §4.3).

const gc_representation = @import("gc_representation_constants.zig");

const block_bytes: usize = 64 * 1024;
pub const min_cells_per_block: usize = 16;

/// §4.3 large-object dedicated mapping floor. This is a space boundary, not
/// the small-class cutoff.
pub const large_min_bytes: usize = 64 * 1024;

pub const min_class_bytes: usize = 16;

/// Coverage target used to freeze `measured_max_small_payload`. Linear classes
/// through 128 always remain; geometric classes are kept only when this
/// percentile of sub-64 KiB publications sits above 128.
pub const coverage_hundredths: usize = 99;

/// Largest linear class. Below this the series is one class per 16 bytes; the
/// geometric series (`nextGeometricClass`) takes over above it.
pub const linear_max_bytes: usize = 128;
const linear_class_count: usize = linear_max_bytes / min_class_bytes;

/// Smallest class that covers `coverage_hundredths` of sub-64 KiB publications
/// in the frozen mixed workload, per the `cutoffForCoverage` rule. Not 4 KiB,
/// and not a round number: it is the last member of `nextGeometricClass`'s
/// series that still fits `min_cells_per_block` cells in a 64 KiB block
/// (`block_bytes / (3760 + 8) = 17`; the successor 4688 would fit only 13).
///
/// TGC S2-f measurement (2026-09-04, ReleaseFast, `--gc-stats` allocation
/// histogram, one fixed-work run each on CPU19). The pre-S2 freeze at 128 was
/// taken from an OBJECT-ONLY publication mix; string bodies became collector
/// carriers in S2, and the p99 moved by more than an order of magnitude:
///
///   workload      below-large pubs   p50   p95     p99    covered by 128
///   deltablue          19,981,642     64   160     160    18,208,272 (91.1%)
///   earley-boyer      255,036,828     48    96     128   255,035,896 (100.0%)
///   raytrace           90,423,361     96    96     160    88,547,848 (97.9%)
///   regexp              8,713,114     48    64   3,840     8,519,276 (97.8%)
///   splay              25,132,439     64    96     112    25,132,333 (100.0%)
///   pdfjs (zoo)        21,806,898     96  >4096  >4096    12,989,640 (59.6%)
///   pdfjs.fixed        21,806,899     96  >4096  >4096    12,989,639 (59.6%)
///
/// `>4096` is the histogram's `over_fine` answer (`fine_bucket_limit`): more
/// than 5% of pdfjs's sub-64 KiB publications are larger than 4 KiB, so its
/// p99 is above every class this geometry can hold. The rule
/// (`cutoffForCoverage`, max p99 over the set) therefore saturates at the
/// geometric cap, 3760. That is the intended answer, not a fallback: pdfjs
/// paid a whole 4 KiB page for each of its 8.8M 129..4095-byte string bodies.
pub const measured_max_small_payload: usize = 3760;

fn nextGeometricClass(prev: usize) usize {
    // Round *5/4 to nearest, then down to 16 so the series stays in ~1.20-1.25
    // (160->192 = 1.20, 192->240 = 1.25) instead of align-up jumping 160->208.
    const scaled = prev * 5;
    const rounded = (scaled + 2) / 4;
    var next = rounded / min_class_bytes * min_class_bytes;
    if (next <= prev) next = prev + min_class_bytes;
    return next;
}

/// The §4.2 rule, evaluated at comptime instead of transcribed: linear
/// 16..`linear_max_bytes`, then `nextGeometricClass` up to the frozen cutoff,
/// with the same `min_cells_per_block` geometry stop `cutoffForCoverage` uses.
/// Nothing here is a literal table; changing `measured_max_small_payload`
/// regenerates the classes, the index table and every `[class_count]` array.
const generated_class_count: usize = blk: {
    var count: usize = linear_class_count;
    var class: usize = linear_max_bytes;
    while (class < measured_max_small_payload) {
        const next = nextGeometricClass(class);
        if (block_bytes / (next + gc_representation.metadata_size) < min_cells_per_block) break;
        class = next;
        count += 1;
    }
    break :blk count;
};

pub const classes: [generated_class_count]usize = blk: {
    var out: [generated_class_count]usize = undefined;
    var i: usize = 0;
    while (i < linear_class_count) : (i += 1) out[i] = (i + 1) * min_class_bytes;
    var class: usize = linear_max_bytes;
    while (i < generated_class_count) : (i += 1) {
        class = nextGeometricClass(class);
        out[i] = class;
    }
    break :blk out;
};
pub const class_count = classes.len;
pub const max_small_payload = classes[classes.len - 1];

comptime {
    // The freeze must name a member of the generated series, otherwise
    // `max_small_payload` and `measured_max_small_payload` silently disagree
    // and `cutoffForCoverage` can never return the frozen value.
    if (max_small_payload != measured_max_small_payload)
        @compileError("measured_max_small_payload is not a generated class");
    // Every class is a whole number of 16-byte steps: the geometric index
    // table below is keyed on that step, and `blockGeometry` assumes cells of
    // a class tile the block without sub-16-byte remainders.
    for (classes) |class| {
        if (class % min_class_bytes != 0) @compileError("class is not a multiple of min_class_bytes");
    }
}

/// Geometric-segment lookup, one entry per 16-byte step above
/// `linear_max_bytes`. The linear segment keeps its two-instruction
/// arithmetic (Object's cell size lives there and its class index is a
/// comptime constant anyway); above 128 the series is irregular, so a table
/// is the only branch-free answer.
const geometric_class_index: [(max_small_payload - linear_max_bytes) / min_class_bytes]u8 = blk: {
    @setEvalBranchQuota(8 * (max_small_payload / min_class_bytes) * class_count);
    var out: [(max_small_payload - linear_max_bytes) / min_class_bytes]u8 = undefined;
    var step: usize = 0;
    while (step < out.len) : (step += 1) {
        // Steps map payloads `linear_max + 16*step + 1 ..= linear_max + 16*(step+1)`.
        const payload = linear_max_bytes + (step + 1) * min_class_bytes;
        var idx: usize = linear_class_count;
        while (classes[idx] < payload) idx += 1;
        out[step] = @intCast(idx);
    }
    break :blk out;
};

pub fn classIndexForPayload(payload: usize) ?usize {
    if (payload <= linear_max_bytes) {
        if (payload <= min_class_bytes) return 0;
        return (payload + min_class_bytes - 1) / min_class_bytes - 1;
    }
    if (payload > max_small_payload) return null;
    return geometric_class_index[(payload - 1) / min_class_bytes - linear_class_count];
}

pub const fine_bucket_step: usize = 16;
pub const fine_bucket_limit: usize = 4096;
pub const fine_bucket_count: usize = fine_bucket_limit / fine_bucket_step;

pub const Histogram = struct {
    buckets: [fine_bucket_count]usize = @splat(0),
    over_fine: usize = 0,
    large: usize = 0,
    total: usize = 0,
    bytes_total: usize = 0,
    /// Detailed-report denominator for terminal M. Updated only in test builds
    /// or when `--gc-stats` enables the already-cold publication census.
    object_publications: usize = 0,
    slots2_object_publications: usize = 0,

    pub fn record(self: *Histogram, payload: usize) void {
        self.total += 1;
        self.bytes_total +|= payload;
        if (payload >= large_min_bytes) {
            self.large += 1;
            return;
        }
        if (payload > fine_bucket_limit) {
            self.over_fine += 1;
            return;
        }
        const idx = if (payload == 0) 0 else (payload - 1) / fine_bucket_step;
        self.buckets[idx] += 1;
    }

    pub fn recordObject(self: *Histogram, payload: usize, slots2: bool) void {
        self.record(payload);
        self.object_publications +|= 1;
        if (slots2) self.slots2_object_publications +|= 1;
    }

    /// pNN of publications that are not already in the dedicated large space.
    pub fn percentilePayloadBelowLarge(self: Histogram, hundredths: usize) usize {
        const pop = self.total -| self.large;
        return percentileOf(pop, hundredths, self.buckets, self.over_fine);
    }

    pub fn coveredByMaxSmall(self: Histogram) usize {
        if (self.total == 0) return 0;
        var seen: usize = 0;
        const cutoff_idx = (max_small_payload + fine_bucket_step - 1) / fine_bucket_step;
        const last = @min(cutoff_idx, self.buckets.len);
        for (self.buckets[0..last]) |count| seen += count;
        return seen;
    }

    pub fn belowLarge(self: Histogram) usize {
        return self.total -| self.large;
    }
};

fn percentileOf(
    pop: usize,
    hundredths: usize,
    buckets: [fine_bucket_count]usize,
    over_fine: usize,
) usize {
    if (pop == 0) return 0;
    const target = (pop * hundredths + 99) / 100;
    var seen: usize = 0;
    for (buckets, 0..) |count, idx| {
        seen += count;
        if (seen >= target) return (idx + 1) * fine_bucket_step;
    }
    if (seen + over_fine >= target) return large_min_bytes - 1;
    return large_min_bytes;
}

/// Smallest generated class that covers `hundredths` of sub-64 KiB publications,
/// floored at the linear table (`linear_max_bytes`). This is how
/// `measured_max_small_payload` is derived; the constant is frozen from a
/// recorded mix, not 4 KiB.
///
/// The floor is the LINEAR table, not the current freeze: a rule that starts
/// from `max_small_payload` can only ever return the frozen value back, which
/// makes it useless both as a freeze procedure and as a test oracle. S2-f
/// found it that way (the old freeze happened to equal `linear_max_bytes`, so
/// the two floors coincided and the defect was invisible).
pub fn cutoffForCoverage(hist: Histogram, hundredths: usize) usize {
    const p = hist.percentilePayloadBelowLarge(hundredths);
    const need = @max(linear_max_bytes, p);
    var class = linear_max_bytes;
    while (class < need) {
        const next = nextGeometricClass(class);
        if (block_bytes / (next + gc_representation.metadata_size) < min_cells_per_block) break;
        class = next;
    }
    return class;
}
