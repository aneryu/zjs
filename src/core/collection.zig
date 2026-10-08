//! Map/Set/WeakMap/WeakSet hash + index backend.
//!
//! These are the pure engine data-structure operations behind the collection
//! object storage slots (`core.Object` `collectionEntriesSlot` /
//! `weakCollectionEntriesSlot` / `collectionBucketHeads` / active-count slots).
//! They implement the open-chained hash index over the entry arrays: hashing,
//! bucket linking/unlinking, capacity growth/rehash, entry append/take/rollback,
//! and the weak-key identity resolution that drives WeakMap/WeakSet inserts.
//!
//! Everything here depends only on `core` (`Object` storage slots, `JSValue`
//! sameValueZero, `string`, `bigint`, `symbol.canBeHeldWeakly`, the runtime
//! borrowed-reference holder registry) and `libs` (`bigint`, `number_format`). There is
//! zero exec/VM dependency: the weak-key GC interaction is entirely
//! core-resident (`Object.weakIdentityFromValue*`, `rt.*BorrowedReferenceHolder`).
//! The collection native method bodies (`exec/collection_ops.zig`) call these
//! backend entry points directly.

const std = @import("std");
const gc_weak = @import("gc_weak.zig");
const property_state = @import("property_state.zig");

const core = @import("root.zig");
const bignum = @import("../libs/bigint.zig");
const dtoa = @import("../libs/number_format.zig");

pub const strong_no_entry = core.object.collection_no_entry;
pub const weak_no_entry = core.object.collection_no_entry;
const strong_index_threshold: usize = 8;
const weak_index_threshold: usize = 8;

// === Strong-entry lookup ===

pub fn findStrongEntry(object: *core.Object, key: core.JSValue) ?usize {
    refreshStrongIndex(object);
    const hash = strongEntryHash(key);
    const heads = object.collectionBucketHeads();
    if (heads.len != 0) {
        var cursor = heads[bucketIndex(hash, heads.len)];
        const entries = object.collectionEntriesSlot().items;
        while (cursor != strong_no_entry) {
            if (cursor >= entries.len) return null;
            const entry = entries[cursor];
            if (entry.active and entry.hash == hash and entry.key.sameValueZero(key)) return cursor;
            cursor = entry.hash_next;
        }
        return null;
    }

    for (object.collectionEntriesSlot().items, 0..) |entry, index| {
        if (!entry.active) continue;
        if (entry.key.sameValueZero(key)) return index;
    }
    return null;
}

pub fn findStrongEntryLatin1Concat(object: *core.Object, prefix: []const u8, digits: []const u8, hash: u64) ?usize {
    refreshStrongIndex(object);
    const heads = object.collectionBucketHeads();
    if (heads.len != 0) {
        var cursor = heads[bucketIndex(hash, heads.len)];
        const entries = object.collectionEntriesSlot().items;
        while (cursor != strong_no_entry) {
            if (cursor >= entries.len) return null;
            const entry = entries[cursor];
            if (entry.active and entry.hash == hash and stringValueEqlLatin1Concat(entry.key, prefix, digits)) return cursor;
            cursor = entry.hash_next;
        }
        return null;
    }

    for (object.collectionEntriesSlot().items, 0..) |entry, index| {
        if (!entry.active) continue;
        if (stringValueEqlLatin1Concat(entry.key, prefix, digits)) return index;
    }
    return null;
}

pub fn strongSize(object: *core.Object) usize {
    return object.collectionActiveCount();
}

// === Hashing ===

pub fn strongEntryHash(value: core.JSValue) u64 {
    return switch (value.tagOf()) {
        core.Tag.int => hashNumber(@floatFromInt(value.as(.int).?)),
        core.Tag.float64 => hashNumber(value.as(.float64).?),
        core.Tag.boolean => mix64(if (value.as(.boolean).?) 0x8d53_0d8d_f34a_2d55 else 0x2eac_9a17_54d3_1c11),
        core.Tag.null_value => mix64(0x6c8e_9cf5_7093_c241),
        core.Tag.undefined_value => mix64(0x3c6e_f372_fe94_f82b),
        core.Tag.short_big_int, core.Tag.big_int => hashBigIntValue(value),
        core.Tag.string, core.Tag.string_rope => hashStringValue(value),
        core.Tag.symbol => mix64(0x19e3_7789_7cc9_8f7d ^ @as(u64, value.asSymbolAtom().?.raw())),
        core.Tag.object, core.Tag.module => hashRefPointer(value),
        core.Tag.function_bytecode => hashObjectPointer(value),
        else => mix64(tagHashBits(value.tagOf())),
    };
}

fn hashNumber(number: f64) u64 {
    if (std.math.isNan(number)) return mix64(0x7ff8_0000_0000_0000);
    if (number == 0) return mix64(0);
    const bits: u64 = @bitCast(number);
    return mix64(bits);
}

fn hashStringValue(value: core.JSValue) u64 {
    const hash = core.string.stringValueContentHash(value) orelse return hashRefPointer(value);
    return mix64(@as(u64, hash) ^ (@as(u64, core.string.stringValueLen(value)) << 32));
}

pub fn strongEntryHashLatin1ConcatWithSeed(prefix: []const u8, digits: []const u8, seed: u32) u64 {
    // Fold to 30 bits so this matches `hashStringValue` → `String.contentHash()`
    // (which folds); the concat fast path and the general string-key path must
    // produce the same bucket for a content-equal key.
    const hash: u32 = core.string.foldHash30(core.string.hashLatin1(digits, seed));
    return mix64(@as(u64, hash) ^ (@as(u64, prefix.len + digits.len) << 32));
}

fn stringValueEqlLatin1Concat(value: core.JSValue, prefix: []const u8, digits: []const u8) bool {
    if (!value.isString()) return false;
    const len = prefix.len + digits.len;
    if (core.string.stringValueLenUnchecked(value) != len) return false;
    if (core.string.asFlat(value)) |string| return switch (string.resolveData()) {
        .latin1 => |bytes| std.mem.eql(u8, bytes[0..prefix.len], prefix) and std.mem.eql(u8, bytes[prefix.len..], digits),
        .utf16 => |units| utf16EqlLatin1Concat(units, prefix, digits),
    };
    // The collection entry and caller's prefix stay borrowed throughout this
    // allocation-free comparison; looking up a rope key must never collect.
    var iterator = core.string.StringValueIterator.init(value);
    var offset: usize = 0;
    while (iterator.next()) |chunk| switch (chunk) {
        inline else => |units| for (units) |unit| {
            const expected = if (offset < prefix.len) prefix[offset] else digits[offset - prefix.len];
            if (unit != expected) return false;
            offset += 1;
        },
    };
    return true;
}

fn utf16EqlLatin1Concat(units: []const u16, prefix: []const u8, digits: []const u8) bool {
    if (units.len != prefix.len + digits.len) return false;
    for (prefix, 0..) |byte, index| {
        if (units[index] != byte) return false;
    }
    for (digits, 0..) |byte, digit_index| {
        if (units[prefix.len + digit_index] != byte) return false;
    }
    return true;
}

const BigIntHashParts = struct {
    negative: bool,
    limbs: []const bignum.Limb,
};

fn bigIntHashParts(value: core.JSValue, scratch: *[2]bignum.Limb) ?BigIntHashParts {
    if (value.as(.short_big_int)) |short| {
        const signed: i128 = short;
        var magnitude: u128 = if (signed < 0) @intCast(-signed) else @intCast(signed);
        var len: usize = 0;
        while (magnitude != 0) {
            scratch[len] = @truncate(magnitude);
            magnitude >>= @bitSizeOf(bignum.Limb);
            len += 1;
        }
        return .{ .negative = short < 0, .limbs = scratch[0..len] };
    }
    const header = value.refHeader() orelse return null;
    const bigint: *core.bigint.BigInt = @alignCast(@fieldParentPtr("header", header));
    return .{ .negative = bigint.negative(), .limbs = bigint.limbs() };
}

fn hashBigIntValue(value: core.JSValue) u64 {
    var scratch: [2]bignum.Limb = undefined;
    const parts = bigIntHashParts(value, &scratch) orelse return hashRefPointer(value);
    var hash: u64 = if (parts.negative) 0x9d77_4424_2d81_353f else 0x4f1b_bcdc_baa7_2b39;
    hash ^= @as(u64, parts.limbs.len) *% 0x9e37_79b9_7f4a_7c15;
    for (parts.limbs) |limb| hash = mix64(hash ^ limb);
    return mix64(hash);
}

fn hashRefPointer(value: core.JSValue) u64 {
    const header = value.refHeader() orelse return mix64(tagHashBits(value.tagOf()));
    return mix64(@as(u64, @intCast(@intFromPtr(header))));
}

fn hashObjectPointer(value: core.JSValue) u64 {
    const header = value.functionBytecodeHeader() orelse return mix64(tagHashBits(value.tagOf()));
    return mix64(@as(u64, @intCast(@intFromPtr(header))));
}

fn mix64(input: u64) u64 {
    var value = input +% 0x9e37_79b9_7f4a_7c15;
    value = (value ^ (value >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    value = (value ^ (value >> 27)) *% 0x94d0_49bb_1331_11eb;
    return value ^ (value >> 31);
}

fn tagHashBits(tag: i32) u64 {
    return @bitCast(@as(i64, tag));
}

fn bucketIndex(hash: u64, bucket_count: usize) usize {
    return @intCast(hash & @as(u64, @intCast(bucket_count - 1)));
}

// === Weak-entry lookup ===

pub fn findWeakEntry(object: *core.Object, key_identity: usize) ?usize {
    const hash = weakEntryHash(key_identity);
    const heads = object.collectionBucketHeads();
    if (heads.len != 0) {
        var cursor = heads[bucketIndex(hash, heads.len)];
        const entries = object.weakCollectionEntriesSlot().items;
        while (cursor != weak_no_entry) {
            if (cursor >= entries.len) return null;
            const entry = entries[cursor];
            if (entry.hash == hash and entry.key_identity == key_identity) return cursor;
            cursor = entry.hash_next;
        }
        return null;
    }

    for (object.weakCollectionEntriesSlot().items, 0..) |entry, index| {
        if (entry.key_identity == key_identity) return index;
    }
    return null;
}

fn weakEntryHash(key_identity: usize) u64 {
    return mix64(@as(u64, @intCast(key_identity)));
}

// === Strong-entry append / index growth ===

fn appendStrongEntryWithHash(rt: *core.JSRuntime, object: *core.Object, entry: core.object.CollectionEntry, hash: u64) !usize {
    var stored = entry;
    stored.hash = hash;
    stored.hash_next = strong_no_entry;
    const next_active_count = object.collectionActiveCount() + 1;
    try ensureStrongIndexForInsert(rt, object, next_active_count);
    const index = try object.appendCollectionEntryUnindexed(rt, stored);
    object.collectionActiveCountSlot().* = next_active_count;
    linkStrongEntry(object, index);
    return index;
}

pub fn appendStrongEntryOwned(rt: *core.JSRuntime, object: *core.Object, entry: core.object.CollectionEntry) !void {
    _ = try appendStrongEntryWithHash(rt, object, entry, strongEntryHash(entry.key));
}

pub fn ensureStrongIndexForInsert(rt: *core.JSRuntime, object: *core.Object, next_active_count: usize) !void {
    // Without an index a lookup scans every slot, deleted ones included, and
    // a live iterator blocks compaction: a small queue churned under
    // `for...of` would otherwise scan its whole history on every lookup.
    const next_slot_count = object.collectionEntriesSlot().items.len + 1;
    if (@max(next_active_count, next_slot_count) < strong_index_threshold) return;
    const heads = object.collectionBucketHeads();
    if (heads.len == 0) {
        try rebuildStrongIndex(rt, object, bucketCountForActiveCount(next_active_count));
        return;
    }
    if (next_active_count * 4 > heads.len * 3) {
        try rebuildStrongIndex(rt, object, heads.len * 2);
    }
}

fn bucketCountForActiveCount(active_count: usize) usize {
    var bucket_count: usize = 16;
    while (active_count * 4 > bucket_count * 3) bucket_count *= 2;
    return bucket_count;
}

fn rebuildStrongIndex(rt: *core.JSRuntime, object: *core.Object, bucket_count: usize) !void {
    const next = try rt.allocNative(usize, bucket_count);
    errdefer rt.freeNative(usize, next);
    @memset(next, strong_no_entry);

    for (object.collectionEntriesSlot().items, 0..) |*entry, index| {
        entry.hash_next = strong_no_entry;
        if (!entry.active) continue;
        entry.hash = strongEntryHash(entry.key);
        const bucket = bucketIndex(entry.hash, next.len);
        entry.hash_next = next[bucket];
        next[bucket] = index;
    }

    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len != 0) rt.freeNative(usize, heads.*);
    heads.* = next;
}

/// Rehash after the collector relocated object keys. Reuses the existing
/// bucket array, so lookups stay allocation-free and cannot fail.
fn refreshStrongIndex(object: *core.Object) void {
    const stale = object.collectionIndexStaleSlot() orelse return;
    if (!stale.*) return;
    stale.* = false;
    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len == 0) return;
    @memset(heads.*, strong_no_entry);
    for (object.collectionEntriesSlot().items, 0..) |*entry, index| {
        entry.hash_next = strong_no_entry;
        if (!entry.active) continue;
        entry.hash = strongEntryHash(entry.key);
        const bucket = bucketIndex(entry.hash, heads.*.len);
        entry.hash_next = heads.*[bucket];
        heads.*[bucket] = index;
    }
}

fn linkStrongEntry(object: *core.Object, index: usize) void {
    linkBucketEntry(object.collectionBucketHeadsSlot().*, object.collectionEntriesSlot().items, index);
}

fn unlinkStrongEntry(object: *core.Object, index: usize) void {
    unlinkBucketEntry(object.collectionBucketHeadsSlot().*, object.collectionEntriesSlot().items, index);
}

/// Push entry `index` onto the head of its bucket chain.
fn linkBucketEntry(heads: []usize, entries: anytype, index: usize) void {
    if (heads.len == 0) return;
    const bucket = bucketIndex(entries[index].hash, heads.len);
    entries[index].hash_next = heads[bucket];
    heads[bucket] = index;
}

/// Splice entry `index` out of its bucket chain. Mirrors `map_delete_record`,
/// which walks the one bucket the record hashes to and re-points the
/// predecessor link.
fn unlinkBucketEntry(heads: []usize, entries: anytype, index: usize) void {
    if (heads.len == 0) return;
    if (index >= entries.len) return;
    var link = &heads[bucketIndex(entries[index].hash, heads.len)];
    while (link.* != core.object.collection_no_entry) {
        const current = link.*;
        if (current >= entries.len) {
            link.* = core.object.collection_no_entry;
            return;
        }
        if (current == index) {
            link.* = entries[current].hash_next;
            return;
        }
        link = &entries[current].hash_next;
    }
}

// === Weak-entry append / index growth ===

pub fn appendWeakEntry(rt: *core.JSRuntime, object: *core.Object, entry: core.object.WeakCollectionEntry) !void {
    var stored = entry;
    stored.hash = weakEntryHash(stored.key_identity);
    stored.hash_next = weak_no_entry;
    gc_weak.retain(rt, stored.key_identity);
    errdefer gc_weak.release(rt, stored.key_identity);
    const entries_slot = object.weakCollectionEntriesSlot();
    const index = entries_slot.items.len;
    const inserted_holder = try property_state.registerHolder(rt, object);
    errdefer if (inserted_holder) property_state.unregisterHolder(rt, object);
    try ensureWeakIndexForInsert(rt, object, index + 1);
    try object.ensureWeakCollectionEntryCapacity(rt, index + 1);
    const refreshed_entries = object.weakCollectionEntriesSlot();
    refreshed_entries.items = refreshed_entries.items.ptr[0 .. index + 1];
    errdefer refreshed_entries.items = refreshed_entries.items[0..index];
    refreshed_entries.items[index] = stored;
    linkWeakEntry(object, index);
    // No second `property_state.registerHolder` here: the registration above
    // is idempotent and already covered by `errdefer`, whereas a repeat call on
    // the success path could only fail, and its failure would run that errdefer
    // and unregister a holder whose entry is already linked into the bucket.
}

fn ensureWeakIndexForInsert(rt: *core.JSRuntime, object: *core.Object, next_count: usize) !void {
    if (next_count < weak_index_threshold) return;
    const heads = object.collectionBucketHeads();
    if (heads.len == 0) {
        try rebuildWeakIndex(rt, object, bucketCountForActiveCount(next_count));
        return;
    }
    if (next_count * 4 > heads.len * 3) {
        try rebuildWeakIndex(rt, object, heads.len * 2);
    }
}

fn rebuildWeakIndex(rt: *core.JSRuntime, object: *core.Object, bucket_count: usize) !void {
    const next = try rt.allocNative(usize, bucket_count);
    errdefer rt.freeNative(usize, next);
    @memset(next, weak_no_entry);

    for (object.weakCollectionEntriesSlot().items, 0..) |*entry, index| {
        entry.hash = weakEntryHash(entry.key_identity);
        const bucket = bucketIndex(entry.hash, next.len);
        entry.hash_next = next[bucket];
        next[bucket] = index;
    }

    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len != 0) rt.freeNative(usize, heads.*);
    heads.* = next;
}

fn linkWeakEntry(object: *core.Object, index: usize) void {
    linkBucketEntry(object.collectionBucketHeadsSlot().*, object.weakCollectionEntriesSlot().items, index);
}

fn unlinkWeakEntry(object: *core.Object, index: usize) void {
    unlinkBucketEntry(object.collectionBucketHeadsSlot().*, object.weakCollectionEntriesSlot().items, index);
}

// === Entry removal / rollback / clear ===

/// Minimum tombstone count before compaction is worth its memmove; below this
/// the linear rescan a small collection does is already bounded by a handful of
/// slots.
const strong_compact_min_tombstones: usize = 4;

/// True when the entry array is at least half tombstones and no cursor is
/// parked in it. qjs frees a deleted record immediately unless an enumerator
/// holds it (`map_delete_record_internal`, quickjs.c); zjs cursors
/// address entries by index, so the whole array has to be pinned instead of one
/// record, and the reclaim is batched behind a 50% fill test to keep the
/// per-delete cost amortized O(1).
fn shouldCompactStrongEntries(object: *core.Object) bool {
    if (object.collectionLiveCursors() != 0) return false;
    const len = object.collectionEntriesSlot().items.len;
    const tombstones = len - object.collectionActiveCount();
    return tombstones >= strong_compact_min_tombstones and tombstones * 2 >= len;
}

/// Drop every tombstone from the entry array, preserving insertion order, and
/// rebuild the bucket chains over the new indices. Allocation-free (it reuses
/// the existing entry buffer and bucket-head array in place), so it cannot fail
/// and needs no OOM rollback.
///
/// This is the batched form of qjs's per-record `list_del(&mr->link)` +
/// `js_free_rt(rt, mr)`. The caller must have checked
/// `collectionLiveCursors() == 0`: every surviving entry moves to a lower index,
/// so any parked cursor index would silently change meaning — the qjs analogue
/// is that a record is only unlinked once its `ref_count` reaches zero.
fn compactStrongEntries(object: *core.Object) void {
    const entries_slot = object.collectionEntriesSlot();
    const old_len = entries_slot.items.len;
    var write: usize = 0;
    for (0..old_len) |read| {
        if (!entries_slot.items[read].active) continue;
        if (write != read) entries_slot.items[write] = entries_slot.items[read];
        write += 1;
    }
    // Blank the vacated tail so a stale `[]CollectionEntry` slice captured
    // before the compaction (the Set-composition scans hold one across user
    // code) sees inactive slots instead of duplicated live entries.
    for (entries_slot.items[write..old_len]) |*entry| {
        entry.* = .{
            .key = core.JSValue.undefinedValue(),
            .value = core.JSValue.undefinedValue(),
            .active = false,
            .hash_next = strong_no_entry,
        };
    }
    entries_slot.items = entries_slot.items.ptr[0..write];
    std.debug.assert(write == object.collectionActiveCount());
    if (object.collectionPayload()) |payload| payload.leading_tombstones = 0;
    // No rehash is needed (unlike `rebuildStrongIndex`): compaction moves
    // entries, it never rewrites keys.
    relinkStrongIndex(object);
}

/// Hand surplus entry/bucket capacity back once a collection has shrunk far
/// below its high-water mark. qjs releases the memory of every deleted record
/// on the spot (`js_free_rt(rt, mr)`, quickjs.c), so a map that shed most
/// of its records also sheds their memory; zjs holds one array, so the
/// equivalent is re-sizing that array. Best effort: on allocation failure the
/// existing buffers stay in use, so a delete can never fail or half-apply.
fn shrinkStrongStorage(rt: *core.JSRuntime, object: *core.Object) void {
    const entries = object.collectionEntriesSlot();
    const live = entries.items.len;
    if (entries.capacity >= 32 and live * 4 <= entries.capacity) {
        var next_capacity: usize = 8;
        while (next_capacity < live * 2) next_capacity *= 2;
        if (next_capacity < entries.capacity) shrink: {
            var next = std.ArrayListUnmanaged(core.object.CollectionEntry).initCapacity(rt.nativeAllocator(), next_capacity) catch break :shrink;
            next.appendSliceAssumeCapacity(entries.items);
            entries.deinit(rt.nativeAllocator());
            entries.* = next;
        }
    }

    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len < 32 or live * 4 > heads.*.len) return;
    const next_count = bucketCountForActiveCount(live);
    if (next_count >= heads.*.len) return;
    const next = rt.allocNative(usize, next_count) catch return;
    @memset(next, strong_no_entry);
    for (entries.items, 0..) |*entry, index| {
        const bucket = bucketIndex(entry.hash, next.len);
        entry.hash_next = next[bucket];
        next[bucket] = index;
    }
    rt.freeNative(usize, heads.*);
    heads.* = next;
}

/// The entry at an iterator's logical `position` (see `entries_base`), and
/// advance past it; null once past the end. A position inside a trimmed
/// prefix resumes at the first remaining entry.
pub fn nextIteratorEntry(object: *core.Object, position: *usize) ?core.object.CollectionEntry {
    const base = object.collectionEntriesBase();
    const index = if (position.* > base) position.* - base else 0;
    const entries = object.collectionEntriesSlot().items;
    if (index >= entries.len) return null;
    position.* = base + index + 1;
    return entries[index];
}

pub fn removeStrongEntry(rt: *core.JSRuntime, object: *core.Object, index: usize) void {
    _ = takeStrongEntry(object, index) orelse return;
    if (shouldCompactStrongEntries(object)) {
        compactStrongEntries(object);
        shrinkStrongStorage(rt, object);
        return;
    }
    trimLeadingStrongTombstones(object);
}

/// Minimum leading tombstone run worth a trim.
const strong_trim_min_tombstones: usize = 32;

/// Drop the run of tombstones at the front of the entry array while only
/// parked iterators pin it, advancing `entries_base` so their logical
/// positions keep their meaning. This is what keeps a map used as a FIFO or
/// LRU cache -- delete the oldest entry while an iterator from
/// `keys().next()` is still alive -- from rescanning every deleted slot. The
/// run must be at least half the array, so the memmove is amortized O(1) per
/// delete.
fn trimLeadingStrongTombstones(object: *core.Object) void {
    if (object.collectionScopedCursors() != 0) return;
    const payload = object.collectionPayload() orelse return;
    const entries_slot = object.collectionEntriesSlot();
    const len = entries_slot.items.len;
    const trim = payload.leading_tombstones;
    if (trim < strong_trim_min_tombstones or trim * 2 < len) return;
    std.mem.copyForwards(core.object.CollectionEntry, entries_slot.items[0 .. len - trim], entries_slot.items[trim..len]);
    entries_slot.items = entries_slot.items.ptr[0 .. len - trim];
    payload.entries_base += trim;
    payload.leading_tombstones = 0;
    relinkStrongIndex(object);
}

/// Rebuild the bucket chains over the current entry positions. Stored
/// hashes stay valid: entries move, keys do not change.
fn relinkStrongIndex(object: *core.Object) void {
    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len == 0) return;
    @memset(heads.*, strong_no_entry);
    for (object.collectionEntriesSlot().items, 0..) |*entry, index| {
        entry.hash_next = strong_no_entry;
        if (!entry.active) continue;
        const bucket = bucketIndex(entry.hash, heads.*.len);
        entry.hash_next = heads.*[bucket];
        heads.*[bucket] = index;
    }
}

/// O(1) weak delete: unchain the victim, then move the tail entry into the hole
/// and rechain only that one entry.
///
/// qjs deletes a record by splicing it out of its bucket chain and its record
/// list and freeing it (`map_delete_record` quickjs.c ->
/// `map_delete_record_internal` quickjs.c) — O(1), no surviving
/// record is touched. zjs stores weak entries in a dense array, so the faithful
/// adaptation of "unlink one node" is unlink + swap-remove. Weak collections
/// have no iterator and no JS-observable order (qjs only walks the list in
/// `map_delete_weakrefs`, quickjs.c), so reordering is unobservable, and
/// the O(n) `@memmove` + full `relinkWeakIndex` rehash it replaces had no qjs
/// counterpart at all.
pub fn removeWeakEntry(rt: *core.JSRuntime, object: *core.Object, index: usize) !void {
    const entries_slot = object.weakCollectionEntriesSlot();
    const last = entries_slot.items.len - 1;
    unlinkWeakEntry(object, index);
    const entry = entries_slot.items[index];
    if (index != last) {
        // Unchain the mover under its old index first: its bucket link stores
        // the index, so it has to be rewritten after the move.
        unlinkWeakEntry(object, last);
        entries_slot.items[index] = entries_slot.items[last];
        entries_slot.items = entries_slot.items.ptr[0..last];
        linkWeakEntry(object, index);
    } else {
        entries_slot.items = entries_slot.items.ptr[0..last];
    }
    entry.destroy(rt);
    object.pruneBorrowedReferenceHolderIfEmpty(rt);
}

/// Mirrors js_map_clear: wipe the hash table first,
/// then walk the record list releasing every record. qjs's per-record release
/// reclaims the record unless an enumerator pinned it, so with no cursor parked
/// the array is truncated to zero here; with a cursor parked the slots survive
/// as tombstones, matching qjs's zombie records.
pub fn clearStrongEntries(object: *core.Object) void {
    const entries_slot = object.collectionEntriesSlot();
    const old_len = entries_slot.items.len;
    if (old_len == 0) return;
    // Parked iterators alone do not keep the slots: every slot becomes a
    // tombstone they would skip, so the whole array is a leading run.
    const drop_slots = object.collectionScopedCursors() == 0;
    const payload = object.collectionPayload().?;
    if (drop_slots) {
        if (object.collectionLiveCursors() != 0) payload.entries_base += old_len;
        payload.leading_tombstones = 0;
    } else payload.leading_tombstones = old_len;
    if (object.collectionActiveCount() == 0) {
        // Nothing to release; only the tombstone slots are left to reclaim.
        if (drop_slots) entries_slot.items = entries_slot.items.ptr[0..0];
        return;
    }

    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len != 0) @memset(heads.*, strong_no_entry);
    object.collectionActiveCountSlot().* = 0;
    if (drop_slots) entries_slot.items = entries_slot.items.ptr[0..0];

    for (0..old_len) |index| {
        if (!entries_slot.items.ptr[index].active) continue;
        entries_slot.items.ptr[index] = .{
            .key = core.JSValue.undefinedValue(),
            .value = core.JSValue.undefinedValue(),
            .active = false,
            .hash_next = strong_no_entry,
        };
    }
    // Deliberately not calling `shrinkStrongStorage` here: qjs's clear frees
    // the records but keeps the hash table, and a cleared map is nearly always
    // refilled, so releasing the entry buffer only buys a full regrow on the
    // next fill (measured: +22% instructions on a fill/clear loop). The delete
    // path releases surplus capacity instead.
}

fn takeStrongEntry(object: *core.Object, index: usize) ?core.object.CollectionEntry {
    const entries_slot = object.collectionEntriesSlot();
    if (index >= entries_slot.items.len or !entries_slot.items[index].active) return null;
    unlinkStrongEntry(object, index);
    const entry = entries_slot.items[index];
    entries_slot.items[index] = .{ .key = core.JSValue.undefinedValue(), .value = core.JSValue.undefinedValue(), .active = false, .hash_next = strong_no_entry };
    const active_count = object.collectionActiveCountSlot();
    if (active_count.* != 0) active_count.* -= 1;
    if (object.collectionPayload()) |payload| {
        if (payload.leading_tombstones == index) {
            var first = index + 1;
            while (first < entries_slot.items.len and !entries_slot.items[first].active) first += 1;
            payload.leading_tombstones = first;
        }
    }
    return entry;
}

pub fn clearWeakEntries(rt: *core.JSRuntime, object: *core.Object) void {
    const entries_slot = object.weakCollectionEntriesSlot();
    while (entries_slot.items.len != 0) {
        const index = entries_slot.items.len - 1;
        const entry = entries_slot.items[index];
        entries_slot.items = entries_slot.items.ptr[0..index];
        entry.destroy(rt);
    }
    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len != 0) @memset(heads.*, weak_no_entry);
    object.pruneBorrowedReferenceHolderIfEmpty(rt);
}

// === Weak-key identity resolution ===

/// Returns the weak identity for a WeakMap/WeakSet key, registering objects
/// in the runtime weak identity registry. Use for inserting paths.
pub fn weakKeyIdentityRegister(rt: *core.JSRuntime, value: core.JSValue) !?usize {
    if (!core.symbol.canBeHeldWeakly(rt, value)) return null;
    return try core.Object.weakIdentityFromValue(rt, value);
}

/// Returns the weak identity for a WeakMap/WeakSet key without registering.
/// Use for read-only paths (get/has/delete): a key that was never weakly
/// referenced cannot be present in any weak collection.
pub fn weakKeyIdentityPeek(rt: *core.JSRuntime, value: core.JSValue) ?usize {
    if (!core.symbol.canBeHeldWeakly(rt, value)) return null;
    return core.Object.weakIdentityFromValuePeek(rt, value);
}

// === WeakMap entry mutation ===

/// Insert-or-update a WeakMap entry by already-resolved key identity. The caller
/// guarantees `object` is a WeakMap.
pub fn setWeakMapEntryByIdentityChecked(rt: *core.JSRuntime, object: *core.Object, key_identity: usize, value: core.JSValue) !void {
    if (findWeakEntry(object, key_identity)) |index| {
        const entry = &object.weakCollectionEntriesSlot().items[index];
        // No barrier: a minor's ephemeron pass visits every marked (so every
        // old) weak holder.
        entry.value = value;
        return;
    }

    const entry = core.object.WeakCollectionEntry{ .key_identity = key_identity, .value = value };
    try appendWeakEntry(rt, object, entry);
}

/// Insert-or-update a WeakMap entry, resolving (and registering) the weak key
/// identity from `key`. Used by the VM closure test-support path.
pub fn setWeakMapEntry(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue, value: core.JSValue) !void {
    if (object.class_id != core.class.ids.weakmap) return error.TypeError;
    const key_identity = (try weakKeyIdentityRegister(rt, key)) orelse return error.TypeError;
    try setWeakMapEntryByIdentityChecked(rt, object, key_identity, value);
}

// === Allocation-free Map probe (tests) ===

/// Lookup a Map entry whose key is the latin1 `prefix` concatenated with the
/// decimal text of `int_value`, returning the value or null. It allocates
/// nothing, so tests can read a Map inside a no-GC or failing-allocator window.
pub fn mapGetLatin1PrefixIntValue(object: *core.Object, prefix: []const u8, int_value: i32) ?core.JSValue {
    if (object.class_id != core.class.ids.map) return null;
    var int_buf: [16]u8 = undefined;
    const digits = dtoa.formatInt32(&int_buf, int_value);
    const hash = strongEntryHashLatin1ConcatWithSeed(prefix, digits, core.string.hashLatin1(prefix, 0));
    const index = findStrongEntryLatin1Concat(object, prefix, digits, hash) orelse return null;
    return object.collectionEntriesSlot().items[index].value;
}
