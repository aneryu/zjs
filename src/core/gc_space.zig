//! Size-class generation and publication histogram for Stage 4 spaces
//! (tracing-gc-design.md §4.2 / §4.3).
//!
//! This module does not allocate 64 KiB blocks. It classifies the compatibility
//! heap's published sizes so the later block allocator has a measured table:
//! 16-byte classes through 128, then a ~1.25 geometric series, each class
//! holding at least 16 cells in a future 64 KiB block. The maximum small class
//! is taken from a publication histogram, not a hard-coded 4 KiB cutoff.
//! Default production `rc` does not import this file.

/// Future block size used only to enforce the 16-cell rule. Not an allocator.
pub const future_block_bytes: usize = 64 * 1024;
pub const min_cells_per_block: usize = 16;

/// §4.3 large-object dedicated mapping floor. This is a space boundary, not
/// the small-class cutoff.
pub const large_min_bytes: usize = 64 * 1024;

/// 8-byte GC metadata prefix that occupies a cell with the payload.
pub const metadata_prefix_size: usize = 8;

pub const min_class_bytes: usize = 16;
pub const linear_limit_bytes: usize = 128;
pub const linear_step_bytes: usize = 16;
pub const geometric_num: usize = 5;
pub const geometric_den: usize = 4;

/// Coverage target used to freeze `measured_max_small_payload`. Linear classes
/// through 128 always remain; geometric classes are kept only when this
/// percentile of sub-64 KiB publications sits above 128.
pub const coverage_hundredths: usize = 99;

/// Smallest generated class that covers `coverage_hundredths` of sub-64 KiB
/// publications in the mixed TestEngine bootstrap + JS workload (frozen by
/// `src/tests/core.zig` "size-class table matches measured publication
/// histogram"): p50=64, p95=96, p99=128. Linear table through 128 is enough;
/// geometric classes stay in `generateAllFittingClasses` for a later histogram.
/// Not 4 KiB.
pub const measured_max_small_payload: usize = 128;

pub const Space = enum {
    small,
    medium,
    large,
};

pub fn cellBytes(payload: usize) usize {
    return payload + metadata_prefix_size;
}

pub fn cellsPerFutureBlock(payload: usize) usize {
    const cell = cellBytes(payload);
    if (cell == 0) return 0;
    return future_block_bytes / cell;
}

pub fn payloadFitsSmallRule(payload: usize) bool {
    return payload >= min_class_bytes and cellsPerFutureBlock(payload) >= min_cells_per_block;
}

fn nextGeometricPayload(prev: usize) usize {
    // Round *5/4 to nearest, then down to 16 so the series stays in ~1.20–1.25
    // (160→192 = 1.20, 192→240 = 1.25) instead of align-up jumping 160→208.
    const scaled = prev * geometric_num;
    const rounded = (scaled + geometric_den / 2) / geometric_den;
    var next = rounded / linear_step_bytes * linear_step_bytes;
    if (next <= prev) next = prev + linear_step_bytes;
    return next;
}

fn appendClass(buf: []usize, n: *usize, payload: usize) bool {
    if (!payloadFitsSmallRule(payload)) return false;
    if (n.* >= buf.len) return false;
    buf[n.*] = payload;
    n.* += 1;
    return true;
}

/// Every class the 16-cell rule allows, ignoring the histogram cutoff.
pub fn generateAllFittingClasses(buf: []usize) usize {
    var n: usize = 0;
    var payload: usize = min_class_bytes;
    while (payload <= linear_limit_bytes) : (payload += linear_step_bytes) {
        if (!appendClass(buf, &n, payload)) break;
    }
    if (n == 0) return 0;
    while (true) {
        const next = nextGeometricPayload(buf[n - 1]);
        if (!appendClass(buf, &n, next)) break;
    }
    return n;
}

pub fn generateMeasuredClasses(buf: []usize) usize {
    const all = generateAllFittingClasses(buf);
    var n: usize = 0;
    while (n < all and buf[n] <= measured_max_small_payload) : (n += 1) {}
    return n;
}

pub const class_count = blk: {
    @setEvalBranchQuota(1000);
    var buf: [48]usize = undefined;
    break :blk generateMeasuredClasses(&buf);
};

pub const classes: [class_count]usize = blk: {
    @setEvalBranchQuota(1000);
    var buf: [48]usize = undefined;
    const n = generateMeasuredClasses(&buf);
    var out: [class_count]usize = undefined;
    for (buf[0..n], 0..) |c, i| out[i] = c;
    break :blk out;
};

pub const max_small_payload: usize = if (class_count == 0) 0 else classes[class_count - 1];

pub fn classifyPayload(payload: usize) Space {
    if (payload >= large_min_bytes) return .large;
    if (payload > max_small_payload) return .medium;
    return .small;
}

/// True when `classes` is exactly the linear series
/// `min_class_bytes, 2*min_class_bytes, ...` -- which it is today (16..128
/// step 16), and which makes the class index pure arithmetic.
pub const classes_are_linear: bool = blk: {
    if (class_count == 0) break :blk false;
    for (classes, 0..) |c, i| {
        if (c != min_class_bytes * (i + 1)) break :blk false;
    }
    break :blk true;
};

pub fn classIndexForPayload(payload: usize) ?usize {
    if (classifyPayload(payload) != .small) return null;
    // The scan below is O(class_count) and ran on every single object
    // allocation: the size is a comptime constant at each call site, but it
    // reaches the block heap through a function pointer, so the constant is
    // re-resolved at run time. earley-boyer allocates 255 M objects and the
    // scan showed up as most of a 5% profile entry. With a linear class
    // series the answer is one shift.
    if (comptime classes_are_linear) {
        const step = min_class_bytes;
        if (payload <= step) return 0;
        return (payload + step - 1) / step - 1;
    }
    var i: usize = 0;
    while (i < classes.len) : (i += 1) {
        if (classes[i] >= payload) return i;
    }
    return classes.len - 1;
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

    pub fn percentilePayload(self: Histogram, hundredths: usize) usize {
        return percentileOf(self.total, hundredths, self.buckets, self.over_fine, self.large);
    }

    /// pNN of publications that are not already in the dedicated large space.
    pub fn percentilePayloadBelowLarge(self: Histogram, hundredths: usize) usize {
        const pop = self.total -| self.large;
        return percentileOf(pop, hundredths, self.buckets, self.over_fine, 0);
    }

    pub fn coveredByMaxSmall(self: Histogram) usize {
        return coveredBy(self, max_small_payload);
    }

    pub fn coveredBy(self: Histogram, cutoff: usize) usize {
        if (self.total == 0) return 0;
        var seen: usize = 0;
        const cutoff_idx = (cutoff + fine_bucket_step - 1) / fine_bucket_step;
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
    large: usize,
) usize {
    if (pop == 0) return 0;
    const target = (pop * hundredths + 99) / 100;
    var seen: usize = 0;
    for (buckets, 0..) |count, idx| {
        seen += count;
        if (seen >= target) return (idx + 1) * fine_bucket_step;
    }
    if (seen + over_fine >= target) return large_min_bytes - 1;
    _ = large;
    return large_min_bytes;
}

pub fn snapToGeneratedClass(payload: usize) usize {
    var buf: [48]usize = undefined;
    const n = generateAllFittingClasses(&buf);
    if (n == 0) return 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (buf[i] >= payload) return buf[i];
    }
    return buf[n - 1];
}

/// Smallest generated class that covers `hundredths` of sub-64 KiB publications,
/// floored at the linear table (128). This is how `measured_max_small_payload`
/// is derived; the constant is frozen from a recorded mix, not 4 KiB.
pub fn cutoffForCoverage(hist: Histogram, hundredths: usize) usize {
    const p = hist.percentilePayloadBelowLarge(hundredths);
    const need = @max(linear_limit_bytes, p);
    return snapToGeneratedClass(need);
}


