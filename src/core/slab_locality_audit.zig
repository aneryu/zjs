//! Slab free-list locality audit (measurement instrument, off by default).
//!
//! Answers one question no profile answers directly: *why* the same slab code
//! takes sixty times more L2D refills on the alloc side under tracing than
//! under refcounting. The counters describe the arena-visiting order of the
//! alloc and free sides, not their cost.
//!
//! To use it, flip `memory.slab_locality_audit` to `true`, rebuild
//! ReleaseFast, and run a workload; the report goes to stderr when the slab
//! tears down (the CLI calls it explicitly, because it does not tear the
//! runtime down on the happy path).
//!
//! This lives in its own file rather than inside `memory.zig` on purpose.
//! `memory.zig` is on the refcounting build's hottest path, and 300 lines of
//! `comptime`-dead instrumentation parked there still moved that build:
//! +171 instructions and a 688-byte `.bss` change with no semantic difference
//! anywhere. Imported only from the taken side of a `comptime` branch, this
//! file is never even parsed unless the audit is on.
//!
//! Findings and the design decision they drove: `docs/slab-reuse-2026-08-29.md`.

const std = @import("std");
const build_options = @import("build_options");
const memory = @import("memory.zig");
const Slab = memory.SmallObjectSlab;

/// The slab the report describes. Registered when the account enables its
/// slab; there is no owner to reach it from at report time.
pub var audit_slab: ?*Slab = null;

/// Depth of the "was this block freed very recently" probe. rc's slab is a
/// perfect LIFO hand-off, so under rc nearly every pop should hit depth 0.
const ring_len: usize = 32;
/// Buckets for both run-length histograms: 1, 2, 3-4, 5-8, 9-16, 17-32,
/// 33-64, 65+.
const run_buckets: usize = 8;

var pops: u64 = 0;
var pops_same_arena: u64 = 0;
var pops_same_line: u64 = 0;
var pops_descending_neighbour: u64 = 0;
var prev_pop_arena: usize = 0;
var prev_pop_header: usize = 0;
var pop_run: u64 = 0;
var pop_run_hist: [run_buckets]u64 = @splat(0);
/// Free blocks the arena still held when the alloc side switched to it.
/// A run of 1 means the alloc side pays a fresh page for every object.
var switch_free_hist: [run_buckets]u64 = @splat(0);
var switch_free_total: u64 = 0;
var switches: u64 = 0;

var frees: u64 = 0;
var frees_same_arena: u64 = 0;
var prev_free_arena: usize = 0;
var free_run: u64 = 0;
var free_run_hist: [run_buckets]u64 = @splat(0);
var frees_refilling: u64 = 0;

var ring: [ring_len]usize = @splat(0);
var ring_next: usize = 0;
var ring_hits: [ring_len]u64 = @splat(0);
var ring_misses: u64 = 0;

var arenas_created: u64 = 0;
var arenas_released: u64 = 0;
var pops_by_class: [64]u64 = @splat(0);

/// Per-class variants of the alloc-side run metric. The global stream
/// interleaves 6 hot classes, so "same arena as the previous pop" reads
/// near zero for a reason that has nothing to do with locality; the free
/// list is per class, so the run that matters is the per-class one.
var prev_pop_arena_by_class: [64]usize = @splat(0);
var class_run: [64]u64 = @splat(0);
var class_run_hist: [run_buckets]u64 = @splat(0);
var class_switches: u64 = 0;
/// Did the alloc side come back to one of the last 8 arenas it used for
/// this class? Distinguishes "cycling a small hot set" from "walking a
/// large set once each".
/// Intra-arena drain order. Within one arena visit the alloc side touches
/// every free block's header; whether it does so ascending (a stride the
/// hardware prefetcher covers) or in scattered free-list order (a serial
/// dependent-load chain) is the whole difference in cost.
var prev_pop_header_by_class: [64]usize = @splat(0);
var intra_steps: u64 = 0;
var intra_delta_total: u64 = 0;
var intra_ascending_adjacent: u64 = 0;
var recent_class_arenas: [64][8]usize = @splat(@splat(0));
var recent_class_next: [64]u8 = @splat(0);
var class_switch_revisits: u64 = 0;

/// Live arena population -- the working set the alloc side walks over.
var live_arenas: u64 = 0;
var max_live_arenas: u64 = 0;
/// Length of each class's free-arena list, maintained incrementally.
var free_list_len: [64]i64 = @splat(0);
var free_len_at_switch_total: u64 = 0;
var free_len_hist: [run_buckets]u64 = @splat(0);

// ---------------------------------------------------------------------------
// Population instrumentation (round 2).
//
// Round 1 established *that* the alloc side walks a 2,733-arena candidate set
// with a 0.04% revisit rate. These counters ask where that population comes
// from and why nothing is revisited: arena lifetimes, whether a released
// arena's page ever comes back, how long an arena sits in the free list before
// the alloc side reaches it, whether the population ever drains, and how the
// sweep's free burst is shaped.
// ---------------------------------------------------------------------------

/// Open-addressed side table keyed by arena base address. Deliberately not a
/// field on `Arena`: `memory.zig` is the refcounting build's hottest file and
/// even comptime-dead declarations there have been measured to move it.
const log_buckets: usize = 24;

const map_cap: usize = 1 << 20;
const map_mask: usize = map_cap - 1;
const key_empty: usize = 0;
const key_dead: usize = 1;

var map_key: [map_cap]usize = @splat(key_empty);
/// Global pop count when this arena was created.
var map_birth: [map_cap]u64 = @splat(0);
/// Global pop count when this arena last entered its class's free list.
var map_free_enter: [map_cap]u64 = @splat(0);
var map_len: usize = 0;
var map_overflow: u64 = 0;

fn mapHash(addr: usize) usize {
    // Arenas are 4 KiB aligned, so the low 12 bits carry no information.
    var h = addr >> 12;
    h *%= 0x9E3779B97F4A7C15;
    return @as(usize, @truncate(h >> 20)) & map_mask;
}

/// Slot holding `addr`, or a free slot to claim. Null only when the table is
/// full, which `map_overflow` reports so no silent data loss can hide here.
fn mapSlot(addr: usize, for_insert: bool) ?usize {
    var i = mapHash(addr);
    var probes: usize = 0;
    var first_dead: ?usize = null;
    while (probes < map_cap) : (probes += 1) {
        const k = map_key[i];
        if (k == addr) return i;
        if (k == key_empty) {
            if (!for_insert) return null;
            return first_dead orelse i;
        }
        if (k == key_dead and first_dead == null) first_dead = i;
        i = (i + 1) & map_mask;
    }
    return null;
}

fn mapInsert(addr: usize, birth: u64) void {
    const slot = mapSlot(addr, true) orelse {
        map_overflow += 1;
        return;
    };
    if (map_key[slot] != addr) map_len += 1;
    map_key[slot] = addr;
    map_birth[slot] = birth;
    map_free_enter[slot] = birth;
}

fn mapRemove(addr: usize) ?u64 {
    const slot = mapSlot(addr, false) orelse return null;
    const birth = map_birth[slot];
    map_key[slot] = key_dead;
    map_len -= 1;
    return birth;
}

/// Arena lifetime, measured in pops elapsed between creation and release.
var arena_lifetime_hist: [log_buckets]u64 = @splat(0);
var arena_lifetime_total: u64 = 0;
var arena_lifetime_n: u64 = 0;
var arenas_created_by_class: [64]u64 = @splat(0);
var arenas_released_by_class: [64]u64 = @splat(0);

/// Does a released arena's page come back? `recent_released` is the last 64
/// released bases (is the backing allocator LIFO?); `ever_released` counts a
/// create whose address the run has seen released at least once.
const released_ring_len: usize = 64;
var released_ring: [released_ring_len]usize = @splat(0);
var released_ring_next: usize = 0;
var create_hits_recent8: u64 = 0;
var create_hits_recent64: u64 = 0;
var create_hits_ever: u64 = 0;
var ever_released_key: [map_cap]usize = @splat(key_empty);

fn everReleasedMark(addr: usize) bool {
    var i = mapHash(addr);
    var probes: usize = 0;
    while (probes < map_cap) : (probes += 1) {
        const k = ever_released_key[i];
        if (k == addr) return true;
        if (k == key_empty) {
            ever_released_key[i] = addr;
            return false;
        }
        i = (i + 1) & map_mask;
    }
    return false;
}

fn everReleasedHas(addr: usize) bool {
    var i = mapHash(addr);
    var probes: usize = 0;
    while (probes < map_cap) : (probes += 1) {
        const k = ever_released_key[i];
        if (k == addr) return true;
        if (k == key_empty) return false;
        i = (i + 1) & map_mask;
    }
    return false;
}

/// Pops the arena spent sitting in the free list before the alloc side reached
/// it. This is the number that says whether "free list head" means "the page
/// we just touched" (rc) or "a page freed a whole GC cycle ago" (trace).
var residency_hist: [log_buckets]u64 = @splat(0);
var residency_total: u64 = 0;
var residency_n: u64 = 0;
var residency_unknown: u64 = 0;

/// Live-arena population over time, sampled every `sample_period` pops.
const sample_period: u64 = 1 << 16;
const sample_cap: usize = 4096;
var samples: [sample_cap]u64 = @splat(0);
var sample_n: usize = 0;
var next_sample_at: u64 = sample_period;
var min_live_after_warmup: u64 = std.math.maxInt(u64);
const warmup_pops: u64 = 1 << 20;

/// Free bursts: maximal runs of frees with no pop in between. A sweep shows up
/// here as one very long burst; rc's per-object frees show up as bursts of 1.
var burst_hist: [log_buckets]u64 = @splat(0);
var burst_len: u64 = 0;
var burst_n: u64 = 0;
var burst_max: u64 = 0;
var burst_refills: u64 = 0;
var burst_refill_total: u64 = 0;
var burst_releases: u64 = 0;
var burst_release_total: u64 = 0;
var pops_at_last_free: u64 = 0;
/// Frees landing in an arena that was already partial (already in the free
/// list) -- these gain free space without moving the arena anywhere.
var frees_into_partial: u64 = 0;

/// Shadow simulation of the candidate knife: "allocate from the arena of the
/// most recent free for this class" (arena-granularity LIFO). The free path
/// has just written that arena's block header, so its line is in L1; the free
/// list head, by contrast, has a mean residency of ~300k pops under splay.
///
/// This counts how often the knife would *change* the choice, which is its
/// entire headroom -- if the head already is the hot arena, it buys nothing.
var sim_hot_arena: [64]usize = @splat(0);
var sim_hot_header: [64]usize = @splat(0);
var sim_hot_free_seq: [64]u64 = @splat(0);
/// The knife only fires when the hot arena still has room. Alloc is the only
/// thing that fills an arena, so the shadow clears it when it would fill.
var sim_hot_valid: [64]bool = @splat(false);
/// Free blocks the shadow hot arena still holds.
var sim_hot_blocks: [64]i64 = @splat(0);
var sim_pops_with_hot: u64 = 0;
var sim_pops_changed: u64 = 0;
var sim_pops_already_hot: u64 = 0;
var sim_pops_no_hot: u64 = 0;
/// Frees elapsed between the free that set the hot arena and the pop that
/// would have consumed it -- the reuse distance the knife would deliver.
var sim_reuse_hist: [log_buckets]u64 = @splat(0);
/// Actual reuse distance of the block the base build popped, for comparison.
var actual_reuse_hist: [log_buckets]u64 = @splat(0);
var actual_reuse_unknown: u64 = 0;
/// Free sequence number at which each block header was last freed.
const blk_cap: usize = 1 << 22;
const blk_mask: usize = blk_cap - 1;
var blk_key: [blk_cap]usize = @splat(0);
var blk_seq: [blk_cap]u64 = @splat(0);

fn blkSlot(addr: usize, for_insert: bool) ?usize {
    var h = addr >> 3;
    h *%= 0x9E3779B97F4A7C15;
    var i = @as(usize, @truncate(h >> 20)) & blk_mask;
    var probes: usize = 0;
    while (probes < 64) : (probes += 1) {
        const k = blk_key[i];
        if (k == addr) return i;
        if (k == 0) return if (for_insert) i else null;
        i = (i + 1) & blk_mask;
    }
    return null;
}

/// Power-of-two buckets: index b holds [2^(b-1), 2^b), with 0 in bucket 0 and
/// everything at or above 2^(log_buckets-1) in the last one.
fn logBucket(v: u64) usize {
    if (v == 0) return 0;
    var b: usize = 1;
    var x = v;
    while (x > 1 and b < log_buckets - 1) : (b += 1) x >>= 1;
    return b;
}

fn dumpLogHist(name: []const u8, hist: *const [log_buckets]u64) void {
    var total: u64 = 0;
    for (hist) |h| total += h;
    std.debug.print("  {s} (n={d}):", .{ name, total });
    for (hist, 0..) |h, b| {
        if (h == 0) continue;
        if (b == 0) {
            std.debug.print(" 0={d}({d:.1}%)", .{ h, percent(h, total) });
        } else {
            std.debug.print(" 2^{d}={d}({d:.1}%)", .{ b - 1, h, percent(h, total) });
        }
    }
    std.debug.print("\n", .{});
}

fn bucket(run: u64) usize {
    if (run <= 1) return 0;
    if (run == 2) return 1;
    if (run <= 4) return 2;
    if (run <= 8) return 3;
    if (run <= 16) return 4;
    if (run <= 32) return 5;
    if (run <= 64) return 6;
    return 7;
}

pub fn notePop(arena_addr: usize, header_addr: usize, free_blocks: u64, class: usize) void {
    pops += 1;
    pops_by_class[class & 63] += 1;
    if (pops >= next_sample_at) {
        next_sample_at += sample_period;
        if (sample_n < sample_cap) {
            samples[sample_n] = live_arenas;
            sample_n += 1;
        }
        if (pops > warmup_pops and live_arenas < min_live_after_warmup) {
            min_live_after_warmup = live_arenas;
        }
    }
    if (arena_addr == prev_pop_arena) {
        pops_same_arena += 1;
        pop_run += 1;
    } else {
        if (pop_run != 0) pop_run_hist[bucket(pop_run)] += 1;
        pop_run = 1;
        switches += 1;
        switch_free_total += free_blocks;
        switch_free_hist[bucket(free_blocks)] += 1;
    }
    if (prev_pop_header != 0) {
        if ((prev_pop_header ^ header_addr) < 64 and (prev_pop_header & ~@as(usize, 63)) == (header_addr & ~@as(usize, 63))) {
            pops_same_line += 1;
        }
        if (prev_pop_header > header_addr and prev_pop_header - header_addr <= 128) {
            pops_descending_neighbour += 1;
        }
    }
    prev_pop_arena = arena_addr;
    prev_pop_header = header_addr;

    const c = class & 63;
    if (prev_pop_arena_by_class[c] == arena_addr) {
        class_run[c] += 1;
        const prev = prev_pop_header_by_class[c];
        intra_steps += 1;
        intra_delta_total += if (header_addr > prev) header_addr - prev else prev - header_addr;
        if (header_addr > prev and header_addr - prev == Slab.blockSize(c)) {
            intra_ascending_adjacent += 1;
        }
    } else {
        if (class_run[c] != 0) class_run_hist[bucket(class_run[c])] += 1;
        class_run[c] = 1;
        class_switches += 1;
        const flen: u64 = if (free_list_len[c] < 0) 0 else @intCast(free_list_len[c]);
        free_len_at_switch_total += flen;
        free_len_hist[bucket(flen)] += 1;
        var seen = false;
        for (recent_class_arenas[c]) |a| {
            if (a == arena_addr) {
                seen = true;
                break;
            }
        }
        if (seen) class_switch_revisits += 1;
        recent_class_arenas[c][recent_class_next[c] & 7] = arena_addr;
        recent_class_next[c] +%= 1;
        prev_pop_arena_by_class[c] = arena_addr;
        // How stale is the page the alloc side just switched to? This is the
        // number that separates "the free list head is the block we touched a
        // moment ago" from "it is a page a sweep freed a whole cycle ago".
        if (mapSlot(arena_addr, false)) |slot| {
            const age = pops - map_free_enter[slot];
            residency_total += age;
            residency_n += 1;
            residency_hist[logBucket(age)] += 1;
        } else {
            residency_unknown += 1;
        }
    }
    prev_pop_header_by_class[c] = header_addr;

    // --- shadow simulation of the arena-LIFO knife ---
    if (sim_hot_valid[c]) {
        sim_pops_with_hot += 1;
        if (sim_hot_arena[c] == arena_addr) {
            sim_pops_already_hot += 1;
        } else {
            sim_pops_changed += 1;
            sim_reuse_hist[logBucket(frees - sim_hot_free_seq[c])] += 1;
        }
        // The shadow arena would have been drained by one block; it stays a
        // candidate until a free names another arena or it would fill up.
        sim_hot_blocks[c] -= 1;
        if (sim_hot_blocks[c] == 0) sim_hot_valid[c] = false;
    } else {
        sim_pops_no_hot += 1;
    }
    if (blkSlot(header_addr, false)) |slot| {
        actual_reuse_hist[logBucket(frees - blk_seq[slot])] += 1;
    } else {
        actual_reuse_unknown += 1;
    }

    var depth: usize = 0;
    while (depth < ring_len) : (depth += 1) {
        const slot = (ring_next + ring_len - 1 - depth) % ring_len;
        if (ring[slot] == header_addr) {
            ring_hits[depth] += 1;
            return;
        }
    }
    ring_misses += 1;
}

pub fn noteFree(arena_addr: usize, header_addr: usize, was_full: bool, class: usize, free_blocks: u64) void {
    frees += 1;
    if (was_full) frees_refilling += 1 else frees_into_partial += 1;
    // A burst is a maximal run of frees with no pop between them. rc frees one
    // object at a time between allocations; a sweep frees thousands with the
    // mutator stopped, so the two show up as different shapes here.
    if (pops != pops_at_last_free) {
        if (burst_len != 0) endBurst();
        pops_at_last_free = pops;
    }
    burst_len += 1;
    if (was_full) burst_refills += 1;
    if (arena_addr == prev_free_arena) {
        frees_same_arena += 1;
        free_run += 1;
    } else {
        if (free_run != 0) free_run_hist[bucket(free_run)] += 1;
        free_run = 1;
    }
    const c = class & 63;
    sim_hot_arena[c] = arena_addr;
    sim_hot_header[c] = header_addr;
    sim_hot_free_seq[c] = frees;
    sim_hot_blocks[c] = @intCast(free_blocks);
    sim_hot_valid[c] = true;
    if (blkSlot(header_addr, true)) |slot| {
        blk_key[slot] = header_addr;
        blk_seq[slot] = frees;
    }
    prev_free_arena = arena_addr;
    ring[ring_next] = header_addr;
    ring_next = (ring_next + 1) % ring_len;
}

fn endBurst() void {
    burst_hist[logBucket(burst_len)] += 1;
    burst_n += 1;
    if (burst_len > burst_max) burst_max = burst_len;
    burst_refill_total += burst_refills;
    burst_release_total += burst_releases;
    burst_len = 0;
    burst_refills = 0;
    burst_releases = 0;
}

pub fn noteArena(created: bool, addr: usize, class: usize) void {
    const c = class & 63;
    if (created) {
        arenas_created += 1;
        arenas_created_by_class[c] += 1;
        live_arenas += 1;
        if (live_arenas > max_live_arenas) max_live_arenas = live_arenas;
        // Did this page come back from the backing allocator, and how warm is
        // it? A page released a moment ago is still in cache; one drawn fresh
        // from the OS is not, and neither is one recycled a million pops later.
        var i: usize = 0;
        while (i < released_ring_len) : (i += 1) {
            const slot = (released_ring_next + released_ring_len - 1 - i) % released_ring_len;
            if (released_ring[slot] == addr) {
                if (i < 8) create_hits_recent8 += 1;
                create_hits_recent64 += 1;
                break;
            }
        }
        if (everReleasedHas(addr)) create_hits_ever += 1;
        mapInsert(addr, pops);
    } else {
        arenas_released += 1;
        arenas_released_by_class[c] += 1;
        live_arenas -= 1;
        burst_releases += 1;
        if (mapRemove(addr)) |birth| {
            const life = pops - birth;
            arena_lifetime_total += life;
            arena_lifetime_n += 1;
            arena_lifetime_hist[logBucket(life)] += 1;
        }
        _ = everReleasedMark(addr);
        released_ring[released_ring_next] = addr;
        released_ring_next = (released_ring_next + 1) % released_ring_len;
    }
}

pub fn noteFreeList(class: usize, delta: i64, addr: usize) void {
    free_list_len[class & 63] += delta;
    if (delta > 0) {
        if (mapSlot(addr, false)) |slot| map_free_enter[slot] = pops;
    }
}

fn percent(part: u64, whole: u64) f64 {
    if (whole == 0) return 0;
    return @as(f64, @floatFromInt(part)) * 100.0 / @as(f64, @floatFromInt(whole));
}

fn dumpHist(name: []const u8, hist: *const [run_buckets]u64) void {
    var total: u64 = 0;
    for (hist) |h| total += h;
    std.debug.print("  {s} (n={d}):", .{ name, total });
    const labels = [run_buckets][]const u8{ "1", "2", "3-4", "5-8", "9-16", "17-32", "33-64", "65+" };
    for (labels, hist) |label, h| {
        std.debug.print(" {s}={d}({d:.1}%)", .{ label, h, percent(h, total) });
    }
    std.debug.print("\n", .{});
}

pub fn dump() void {
    if (pops == 0 and frees == 0) return;
    if (pop_run != 0) pop_run_hist[bucket(pop_run)] += 1;
    if (free_run != 0) free_run_hist[bucket(free_run)] += 1;
    pop_run = 0;
    free_run = 0;
    std.debug.print("[slab-locality] gc={s}\n", .{build_options.zjs_gc});
    std.debug.print("  pops={d} frees={d} arenas created={d} released={d}\n", .{ pops, frees, arenas_created, arenas_released });
    std.debug.print("  alloc: same-arena-as-prev {d:.2}% | same-cache-line {d:.2}% | within-128B-descending {d:.2}%\n", .{
        percent(pops_same_arena, pops),
        percent(pops_same_line, pops),
        percent(pops_descending_neighbour, pops),
    });
    std.debug.print("  alloc arena switches={d} ({d:.2}% of pops), mean free blocks at switch={d:.2}\n", .{
        switches,
        percent(switches, pops),
        if (switches == 0) 0 else @as(f64, @floatFromInt(switch_free_total)) / @as(f64, @floatFromInt(switches)),
    });
    dumpHist("alloc same-arena run", &pop_run_hist);
    dumpHist("free blocks at arena switch", &switch_free_hist);
    var cr: usize = 0;
    while (cr < 64) : (cr += 1) {
        if (class_run[cr] != 0) {
            class_run_hist[bucket(class_run[cr])] += 1;
            class_run[cr] = 0;
        }
    }
    std.debug.print("  per-class alloc: switches={d} ({d:.2}% of pops), revisit-last-8 {d:.2}%, mean free-arena-list len at switch={d:.2}\n", .{
        class_switches,
        percent(class_switches, pops),
        percent(class_switch_revisits, class_switches),
        if (class_switches == 0) 0 else @as(f64, @floatFromInt(free_len_at_switch_total)) / @as(f64, @floatFromInt(class_switches)),
    });
    std.debug.print("  intra-arena drain: steps={d}, mean |delta bytes|={d:.1}, ascending-adjacent {d:.2}%\n", .{
        intra_steps,
        if (intra_steps == 0) 0 else @as(f64, @floatFromInt(intra_delta_total)) / @as(f64, @floatFromInt(intra_steps)),
        percent(intra_ascending_adjacent, intra_steps),
    });
    dumpHist("per-class alloc same-arena run", &class_run_hist);
    dumpHist("free-arena list length at per-class switch", &free_len_hist);
    std.debug.print("  live arenas: now={d} peak={d} (peak = {d:.2} MiB of 4 KiB arenas)\n", .{
        live_arenas,
        max_live_arenas,
        @as(f64, @floatFromInt(max_live_arenas)) * 4096.0 / (1024.0 * 1024.0),
    });
    std.debug.print("  free: same-arena-as-prev {d:.2}% | refilling (full->partial) {d:.2}%\n", .{
        percent(frees_same_arena, frees),
        percent(frees_refilling, frees),
    });
    dumpHist("free same-arena run", &free_run_hist);
    var hit_total: u64 = 0;
    for (ring_hits) |h| hit_total += h;
    std.debug.print("  LIFO recency: pop hits last-{d}-freed {d:.2}%", .{ ring_len, percent(hit_total, pops) });
    std.debug.print(" (depth0={d:.2}% depth<4={d:.2}% depth<8={d:.2}%)\n", .{
        percent(ring_hits[0], pops),
        percent(ring_hits[0] + ring_hits[1] + ring_hits[2] + ring_hits[3], pops),
        percent(ring_hits[0] + ring_hits[1] + ring_hits[2] + ring_hits[3] +
            ring_hits[4] + ring_hits[5] + ring_hits[6] + ring_hits[7], pops),
    });
    if (burst_len != 0) endBurst();
    std.debug.print("  --- arena-LIFO knife simulation ---\n", .{});
    std.debug.print("  pops with a hot arena={d} ({d:.2}%): already-chosen {d:.2}% | knife would change {d:.2}% | no hot arena {d:.2}%\n", .{
        sim_pops_with_hot,
        percent(sim_pops_with_hot, pops),
        percent(sim_pops_already_hot, pops),
        percent(sim_pops_changed, pops),
        percent(sim_pops_no_hot, pops),
    });
    dumpLogHist("knife reuse distance (frees between free and pop)", &sim_reuse_hist);
    dumpLogHist("base reuse distance of the popped block (frees)", &actual_reuse_hist);
    std.debug.print("  base reuse unknown (never freed in this run)={d} ({d:.2}%)\n", .{
        actual_reuse_unknown, percent(actual_reuse_unknown, pops),
    });
    std.debug.print("  --- population ---\n", .{});
    std.debug.print("  arenas: created={d} released={d} live={d} peak={d} min-after-warmup={d}\n", .{
        arenas_created,
        arenas_released,
        live_arenas,
        max_live_arenas,
        if (min_live_after_warmup == std.math.maxInt(u64)) 0 else min_live_after_warmup,
    });
    std.debug.print("  release rate: {d:.2}% of created arenas were ever emptied; map_len={d} overflow={d}\n", .{
        percent(arenas_released, arenas_created),
        map_len,
        map_overflow,
    });
    std.debug.print("  page recycling on create: last-8 {d:.2}% | last-64 {d:.2}% | ever-released {d:.2}%\n", .{
        percent(create_hits_recent8, arenas_created),
        percent(create_hits_recent64, arenas_created),
        percent(create_hits_ever, arenas_created),
    });
    dumpLogHist("arena lifetime (pops)", &arena_lifetime_hist);
    std.debug.print("  mean arena lifetime={d:.1} pops (n={d})\n", .{
        if (arena_lifetime_n == 0) 0 else @as(f64, @floatFromInt(arena_lifetime_total)) / @as(f64, @floatFromInt(arena_lifetime_n)),
        arena_lifetime_n,
    });
    dumpLogHist("free-list residency at alloc switch (pops)", &residency_hist);
    std.debug.print("  mean residency={d:.1} pops (n={d}, unknown={d})\n", .{
        if (residency_n == 0) 0 else @as(f64, @floatFromInt(residency_total)) / @as(f64, @floatFromInt(residency_n)),
        residency_n,
        residency_unknown,
    });
    std.debug.print("  frees into already-partial arena {d:.2}% (vs full->partial {d:.2}%)\n", .{
        percent(frees_into_partial, frees),
        percent(frees_refilling, frees),
    });
    dumpLogHist("free burst length (frees with no pop between)", &burst_hist);
    std.debug.print("  bursts={d} max={d} mean full->partial per burst={d:.2} mean releases per burst={d:.2}\n", .{
        burst_n,
        burst_max,
        if (burst_n == 0) 0 else @as(f64, @floatFromInt(burst_refill_total)) / @as(f64, @floatFromInt(burst_n)),
        if (burst_n == 0) 0 else @as(f64, @floatFromInt(burst_release_total)) / @as(f64, @floatFromInt(burst_n)),
    });
    if (sample_n != 0) {
        std.debug.print("  live-arena series ({d} samples, one per {d} pops, downsampled to 32):\n   ", .{ sample_n, sample_period });
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            const idx = i * sample_n / 32;
            std.debug.print(" {d}", .{samples[idx]});
        }
        std.debug.print("\n", .{});
    }
    if (audit_slab) |slab| {
        // End-of-run occupancy census: how densely packed are the arenas
        // the alloc side is still walking over?
        var occ_hist: [run_buckets]u64 = @splat(0);
        var arenas: u64 = 0;
        var used_total: u64 = 0;
        var cap_total: u64 = 0;
        var live_by_class: [64]u64 = @splat(0);
        var arenas_by_class: [64]u64 = @splat(0);
        for (slab.arenas, 0..) |head, ci| {
            var node = head;
            while (node) |a| : (node = a.next) {
                arenas += 1;
                live_by_class[ci & 63] += a.used_blocks;
                arenas_by_class[ci & 63] += 1;
                used_total += a.used_blocks;
                cap_total += a.block_count;
                const pct = if (a.block_count == 0) 0 else @as(u64, a.used_blocks) * 100 / @as(u64, a.block_count);
                const slot: usize = if (pct == 0) 0 else if (pct < 25) 1 else if (pct < 50) 2 else if (pct < 75) 3 else if (pct < 100) 4 else 5;
                occ_hist[slot] += 1;
            }
        }
        std.debug.print("  end-of-run arenas={d} used_blocks={d} capacity={d} occupancy={d:.2}%\n", .{
            arenas, used_total, cap_total, percent(used_total, cap_total),
        });
        // Self-check against an independently maintained quantity: every pop
        // that was not matched by a free must still be occupying a block. A
        // miscounted pop or a double-counted free breaks this in either
        // direction, and without it every number above is only "I wrote a
        // script". Printed rather than asserted because the audit runs in
        // ReleaseFast, where assertions are gone.
        const outstanding = pops -% frees;
        if (outstanding == used_total) {
            std.debug.print("  self-check: pops-frees={d} == sum(used_blocks) OK\n", .{outstanding});
        } else {
            std.debug.print("  self-check: VIOLATION pops-frees={d} != sum(used_blocks)={d}\n", .{ outstanding, used_total });
        }
        std.debug.print("  occupancy buckets: empty={d} <25%={d} <50%={d} <75%={d} <100%={d} full={d}\n", .{
            occ_hist[0], occ_hist[1], occ_hist[2], occ_hist[3], occ_hist[4], occ_hist[5],
        });
        std.debug.print("  end-of-run live blocks by class:", .{});
        var lc: usize = 0;
        while (lc < Slab.class_count) : (lc += 1) {
            if (arenas_by_class[lc] == 0) continue;
            std.debug.print(" [{d}]{d}={d}b/{d}a", .{ lc, Slab.blockSize(lc), live_by_class[lc], arenas_by_class[lc] });
        }
        std.debug.print("\n", .{});
        std.debug.print("  arenas created/released by class:", .{});
        lc = 0;
        while (lc < Slab.class_count) : (lc += 1) {
            if (arenas_created_by_class[lc] == 0) continue;
            std.debug.print(" [{d}]{d}={d}/{d}", .{ lc, Slab.blockSize(lc), arenas_created_by_class[lc], arenas_released_by_class[lc] });
        }
        std.debug.print("\n", .{});
    }
    var class: usize = 0;
    std.debug.print("  pops by class:", .{});
    while (class < Slab.class_count) : (class += 1) {
        if (pops_by_class[class] == 0) continue;
        std.debug.print(" [{d}]{d}={d}", .{ class, Slab.blockSize(class), pops_by_class[class] });
    }
    std.debug.print("\n", .{});
}
