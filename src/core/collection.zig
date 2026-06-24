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
//! borrowed-reference holder registry) and `libs` (`bignum`, `dtoa`). There is
//! zero exec/builtins/VM dependency: the weak-key GC interaction is entirely
//! core-resident (`Object.weakIdentityFromValue*`, `rt.*BorrowedReferenceHolder`).
//! The builtins collection method bodies (`builtins/collection.zig`) call these
//! backend entry points directly; the VM Map-fusion fast paths
//! (`mapSetLatin1PrefixInt32Range` / `mapGetLatin1PrefixIntValue`, consumed by
//! `exec/vm_property_locals.zig`) and the WeakMap test-support mutator
//! (`setWeakMapEntry`, consumed by `exec/closure.zig`) live here too so neither
//! consumer needs to import builtins.

const std = @import("std");

const core = @import("root.zig");
const bignum = @import("../libs/bignum.zig");
const dtoa = @import("../libs/dtoa.zig");

pub const strong_no_entry = core.object.collection_no_entry;
pub const weak_no_entry = core.object.collection_no_entry;
const strong_index_threshold: usize = 8;
const weak_index_threshold: usize = 8;

// === Strong-entry lookup ===

pub fn findStrongEntry(object: *core.Object, key: core.JSValue) ?usize {
    const hash = strongEntryHash(key);
    const heads = object.collectionBucketHeads();
    if (heads.len != 0) {
        var cursor = heads[bucketIndex(hash, heads.len)];
        const entries = object.collectionEntriesSlot().*;
        while (cursor != strong_no_entry) {
            if (cursor >= entries.len) return null;
            const entry = entries[cursor];
            if (entry.active and entry.hash == hash and entry.key.sameValueZero(key)) return cursor;
            cursor = entry.hash_next;
        }
        return null;
    }

    for (object.collectionEntriesSlot().*, 0..) |entry, index| {
        if (!entry.active) continue;
        if (entry.key.sameValueZero(key)) return index;
    }
    return null;
}

pub fn findStrongEntryLatin1Concat(object: *core.Object, prefix: []const u8, digits: []const u8, hash: u64) ?usize {
    const heads = object.collectionBucketHeads();
    if (heads.len != 0) {
        var cursor = heads[bucketIndex(hash, heads.len)];
        const entries = object.collectionEntriesSlot().*;
        while (cursor != strong_no_entry) {
            if (cursor >= entries.len) return null;
            const entry = entries[cursor];
            if (entry.active and entry.hash == hash and stringValueEqlLatin1Concat(entry.key, prefix, digits)) return cursor;
            cursor = entry.hash_next;
        }
        return null;
    }

    for (object.collectionEntriesSlot().*, 0..) |entry, index| {
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
        core.Tag.int => hashNumber(@floatFromInt(value.asInt32().?)),
        core.Tag.float64 => hashNumber(value.asFloat64().?),
        core.Tag.boolean => mix64(if (value.asBool().?) 0x8d53_0d8d_f34a_2d55 else 0x2eac_9a17_54d3_1c11),
        core.Tag.null_value => mix64(0x6c8e_9cf5_7093_c241),
        core.Tag.undefined_value => mix64(0x3c6e_f372_fe94_f82b),
        core.Tag.short_big_int, core.Tag.big_int => hashBigIntValue(value),
        core.Tag.string, core.Tag.string_rope => hashStringValue(value),
        core.Tag.symbol => mix64(0x19e3_7789_7cc9_8f7d ^ @as(u64, value.asSymbolAtom().?)),
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
    const string = stringFromValue(value) orelse return hashRefPointer(value);
    return mix64(@as(u64, string.contentHash()) ^ (@as(u64, string.len()) << 32));
}

pub fn strongEntryHashLatin1Concat(prefix: []const u8, digits: []const u8) u64 {
    const seed = core.string.hashLatin1(prefix, 0);
    return strongEntryHashLatin1ConcatWithSeed(prefix, digits, seed);
}

pub fn strongEntryHashLatin1ConcatWithSeed(prefix: []const u8, digits: []const u8, seed: u32) u64 {
    const hash = core.string.hashLatin1(digits, seed);
    return mix64(@as(u64, hash) ^ (@as(u64, prefix.len + digits.len) << 32));
}

fn stringValueEqlLatin1Concat(value: core.JSValue, prefix: []const u8, digits: []const u8) bool {
    const string = stringFromValue(value) orelse return false;
    const len = prefix.len + digits.len;
    if (string.len() != len) return false;
    return switch (string.resolveData()) {
        .latin1 => |bytes| std.mem.eql(u8, bytes[0..prefix.len], prefix) and std.mem.eql(u8, bytes[prefix.len..], digits),
        .utf16 => |units| utf16EqlLatin1Concat(units, prefix, digits),
    };
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
    if (value.asShortBigInt()) |short| {
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
    return .{ .negative = bigint.value.negative, .limbs = bigint.value.limbs };
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
    const header = value.objectHeader() orelse return mix64(tagHashBits(value.tagOf()));
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
        const entries = object.weakCollectionEntriesSlot().*;
        while (cursor != weak_no_entry) {
            if (cursor >= entries.len) return null;
            const entry = entries[cursor];
            if (entry.hash == hash and entry.key_identity == key_identity) return cursor;
            cursor = entry.hash_next;
        }
        return null;
    }

    for (object.weakCollectionEntriesSlot().*, 0..) |entry, index| {
        if (entry.key_identity == key_identity) return index;
    }
    return null;
}

fn weakEntryHash(key_identity: usize) u64 {
    return mix64(@as(u64, @intCast(key_identity)));
}

// === Strong-entry append / index growth ===

pub fn appendStrongEntry(rt: *core.JSRuntime, object: *core.Object, entry: core.object.CollectionEntry) !usize {
    return try appendStrongEntryWithHash(rt, object, entry, strongEntryHash(entry.key));
}

pub fn appendStrongEntryWithHash(rt: *core.JSRuntime, object: *core.Object, entry: core.object.CollectionEntry, hash: u64) !usize {
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
    var entry_owned = true;
    errdefer if (entry_owned) entry.destroy(rt);
    const index = try appendStrongEntry(rt, object, entry);
    entry_owned = false;
    var inserted = true;
    errdefer if (inserted) rollbackLastStrongEntry(rt, object, index);
    inserted = false;
}

pub fn ensureStrongIndexForInsert(rt: *core.JSRuntime, object: *core.Object, next_active_count: usize) !void {
    if (next_active_count < strong_index_threshold) return;
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
    const next = try rt.memory.alloc(usize, bucket_count);
    errdefer rt.memory.free(usize, next);
    @memset(next, strong_no_entry);

    for (object.collectionEntriesSlot().*, 0..) |*entry, index| {
        entry.hash_next = strong_no_entry;
        if (!entry.active) continue;
        entry.hash = strongEntryHash(entry.key);
        const bucket = bucketIndex(entry.hash, next.len);
        entry.hash_next = next[bucket];
        next[bucket] = index;
    }

    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len != 0) rt.memory.free(usize, heads.*);
    heads.* = next;
}

fn linkStrongEntry(object: *core.Object, index: usize) void {
    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len == 0) return;
    const entries = object.collectionEntriesSlot().*;
    const bucket = bucketIndex(entries[index].hash, heads.*.len);
    entries[index].hash_next = heads.*[bucket];
    heads.*[bucket] = index;
}

fn unlinkStrongEntry(object: *core.Object, index: usize) void {
    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len == 0) return;
    const entries = object.collectionEntriesSlot().*;
    if (index >= entries.len) return;
    var link = &heads.*[bucketIndex(entries[index].hash, heads.*.len)];
    while (link.* != strong_no_entry) {
        const current = link.*;
        if (current >= entries.len) {
            link.* = strong_no_entry;
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
    rt.retainWeakIdentity(stored.key_identity);
    errdefer rt.releaseWeakIdentity(stored.key_identity);
    const entries_slot = object.weakCollectionEntriesSlot();
    const index = entries_slot.*.len;
    const inserted_holder = !rt.borrowedReferenceHolderRegistered(object);
    if (inserted_holder) try rt.registerBorrowedReferenceHolder(object);
    errdefer if (inserted_holder) rt.unregisterBorrowedReferenceHolder(object);
    try ensureWeakIndexForInsert(rt, object, index + 1);
    try object.ensureWeakCollectionEntryCapacity(rt, index + 1);
    const refreshed_entries = object.weakCollectionEntriesSlot();
    refreshed_entries.* = refreshed_entries.*.ptr[0 .. index + 1];
    errdefer refreshed_entries.* = refreshed_entries.*[0..index];
    refreshed_entries.*[index] = stored;
    linkWeakEntry(object, index);
    try rt.registerBorrowedReferenceHolder(object);
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
    const next = try rt.memory.alloc(usize, bucket_count);
    errdefer rt.memory.free(usize, next);
    @memset(next, weak_no_entry);

    for (object.weakCollectionEntriesSlot().*, 0..) |*entry, index| {
        entry.hash = weakEntryHash(entry.key_identity);
        entry.hash_next = weak_no_entry;
        const bucket = bucketIndex(entry.hash, next.len);
        entry.hash_next = next[bucket];
        next[bucket] = index;
    }

    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len != 0) rt.memory.free(usize, heads.*);
    heads.* = next;
}

fn linkWeakEntry(object: *core.Object, index: usize) void {
    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len == 0) return;
    const entries = object.weakCollectionEntriesSlot().*;
    const bucket = bucketIndex(entries[index].hash, heads.*.len);
    entries[index].hash_next = heads.*[bucket];
    heads.*[bucket] = index;
}

fn relinkWeakIndex(object: *core.Object) void {
    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len == 0) return;
    @memset(heads.*, weak_no_entry);
    for (object.weakCollectionEntriesSlot().*, 0..) |*entry, index| {
        entry.hash = weakEntryHash(entry.key_identity);
        entry.hash_next = weak_no_entry;
        linkWeakEntry(object, index);
    }
}

// === Entry removal / rollback / clear ===

pub fn removeStrongEntry(rt: *core.JSRuntime, object: *core.Object, index: usize) void {
    const removed = takeStrongEntry(object, index) orelse return;
    removed.destroy(rt);
}

fn rollbackLastStrongEntry(rt: *core.JSRuntime, object: *core.Object, index: usize) void {
    const entries_slot = object.collectionEntriesSlot();
    std.debug.assert(index + 1 == entries_slot.*.len);
    const entry = takeStrongEntry(object, index) orelse return;
    entries_slot.* = entries_slot.*.ptr[0..index];
    entry.destroy(rt);
}

pub fn rollbackStrongEntriesTo(rt: *core.JSRuntime, object: *core.Object, len: usize, active_count: usize) void {
    const entries_slot = object.collectionEntriesSlot();
    while (entries_slot.*.len > len) {
        rollbackLastStrongEntry(rt, object, entries_slot.*.len - 1);
    }
    object.collectionActiveCountSlot().* = active_count;
}

pub fn removeWeakEntry(rt: *core.JSRuntime, object: *core.Object, index: usize) !void {
    const entries_slot = object.weakCollectionEntriesSlot();
    const entry = entries_slot.*[index];
    if (index + 1 < entries_slot.*.len) {
        @memmove(entries_slot.*[index .. entries_slot.*.len - 1], entries_slot.*[index + 1 ..]);
    }
    entries_slot.* = entries_slot.*.ptr[0 .. entries_slot.*.len - 1];
    relinkWeakIndex(object);
    entry.destroy(rt);
    object.pruneBorrowedReferenceHolderIfEmpty(rt);
}

pub fn clearStrongEntries(rt: *core.JSRuntime, object: *core.Object) void {
    const active_count = object.collectionActiveCount();
    if (active_count == 0) return;

    var index: usize = 0;
    while (index < object.collectionEntriesSlot().*.len) : (index += 1) {
        const entry = takeStrongEntry(object, index) orelse continue;
        entry.destroy(rt);
    }
    const heads = object.collectionBucketHeadsSlot();
    if (heads.*.len != 0) @memset(heads.*, strong_no_entry);
}

fn takeStrongEntry(object: *core.Object, index: usize) ?core.object.CollectionEntry {
    const entries_slot = object.collectionEntriesSlot();
    if (index >= entries_slot.*.len or !entries_slot.*[index].active) return null;
    unlinkStrongEntry(object, index);
    const entry = entries_slot.*[index];
    entries_slot.*[index] = .{ .key = core.JSValue.undefinedValue(), .value = core.JSValue.undefinedValue(), .active = false, .hash_next = strong_no_entry };
    const active_count = object.collectionActiveCountSlot();
    if (active_count.* != 0) active_count.* -= 1;
    return entry;
}

pub fn clearWeakEntries(rt: *core.JSRuntime, object: *core.Object) void {
    const entries_slot = object.weakCollectionEntriesSlot();
    while (entries_slot.*.len != 0) {
        const index = entries_slot.*.len - 1;
        const entry = entries_slot.*[index];
        entries_slot.* = entries_slot.*.ptr[0..index];
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

// === Weak-collection sweep (GC reachability) ===

/// Drop every weak entry whose key identity is no longer live, as decided by
/// the `isLive` predicate the GC supplies. Returns the number removed.
pub fn sweepWeakEntries(
    rt: *core.JSRuntime,
    object: *core.Object,
    context: ?*anyopaque,
    isLive: *const fn (?*anyopaque, usize) bool,
) !usize {
    if (object.class_id != core.class.ids.weakmap and object.class_id != core.class.ids.weakset) return error.TypeError;
    var removed: usize = 0;
    var i: usize = 0;
    while (i < object.weakCollectionEntriesSlot().*.len) {
        if (isLive(context, object.weakCollectionEntriesSlot().*[i].key_identity)) {
            i += 1;
            continue;
        }
        try removeWeakEntry(rt, object, i);
        removed += 1;
    }
    return removed;
}

// === WeakMap entry mutation ===

/// Insert-or-update a WeakMap entry by already-resolved key identity. The caller
/// guarantees `object` is a WeakMap.
pub fn setWeakMapEntryByIdentityChecked(rt: *core.JSRuntime, object: *core.Object, key_identity: usize, value: core.JSValue) !void {
    if (findWeakEntry(object, key_identity)) |index| {
        const entry = &object.weakCollectionEntriesSlot().*[index];
        const next_value = value.dup();
        const old_value = entry.value;
        entry.value = next_value;
        old_value.free(rt);
        return;
    }

    var entry = core.object.WeakCollectionEntry{ .key_identity = key_identity, .value = value.dup() };
    errdefer entry.value.free(rt);
    try appendWeakEntry(rt, object, entry);
}

pub fn setWeakMapEntryByIdentity(rt: *core.JSRuntime, object: *core.Object, key_identity: usize, value: core.JSValue) !void {
    if (object.class_id != core.class.ids.weakmap) return error.TypeError;
    try setWeakMapEntryByIdentityChecked(rt, object, key_identity, value);
}

/// Insert-or-update a WeakMap entry, resolving (and registering) the weak key
/// identity from `key`. Used by the VM closure test-support path.
pub fn setWeakMapEntry(rt: *core.JSRuntime, object: *core.Object, key: core.JSValue, value: core.JSValue) !void {
    if (object.class_id != core.class.ids.weakmap) return error.TypeError;
    const key_identity = (try weakKeyIdentityRegister(rt, key)) orelse return error.TypeError;
    try setWeakMapEntryByIdentityChecked(rt, object, key_identity, value);
}

// === Map Latin1-prefix-int fusion fast paths (VM loop fusion) ===

/// Lookup a Map entry whose key is the latin1 `prefix` concatenated with the
/// decimal text of `int_value`, returning a duplicated value or null. Drives the
/// `vm_property_locals` Map-fusion read fast path; no allocation on miss.
pub fn mapGetLatin1PrefixIntValue(object: *core.Object, prefix: []const u8, int_value: i32) ?core.JSValue {
    if (object.class_id != core.class.ids.map) return null;
    var int_buf: [16]u8 = undefined;
    const digits = dtoa.formatInt32(&int_buf, int_value);
    const hash = strongEntryHashLatin1Concat(prefix, digits);
    const index = findStrongEntryLatin1Concat(object, prefix, digits, hash) orelse return null;
    return object.collectionEntriesSlot().*[index].value.dup();
}

/// Bulk insert-or-update Map entries keyed by `prefix ++ decimal(i)` for every
/// `i` in `[start, limit)`, with the integer itself as the value. Drives the
/// `vm_property_locals` Map-fusion write fast path. Rolls back any inserts on
/// failure.
pub fn mapSetLatin1PrefixInt32Range(
    rt: *core.JSRuntime,
    object: *core.Object,
    prefix: []const u8,
    start: i32,
    limit: i32,
) !void {
    if (object.class_id != core.class.ids.map or start < 0 or limit < start) return error.TypeError;
    const max_new_count: usize = @intCast(limit - start);
    if (max_new_count == 0) return;
    try object.ensureCollectionEntryCapacity(rt, object.collectionEntriesSlot().*.len + max_new_count);
    try ensureStrongIndexForInsert(rt, object, object.collectionActiveCount() + max_new_count);

    const original_len = object.collectionEntriesSlot().*.len;
    const original_active_count = object.collectionActiveCount();
    var inserted = false;
    errdefer if (inserted) rollbackStrongEntriesTo(rt, object, original_len, original_active_count);

    const prefix_seed = core.string.hashLatin1(prefix, 0);
    var int_buf: [16]u8 = undefined;
    var int_value = start;
    while (int_value < limit) : (int_value += 1) {
        const digits = dtoa.formatInt32(&int_buf, int_value);
        const hash = strongEntryHashLatin1ConcatWithSeed(prefix, digits, prefix_seed);
        if (findStrongEntryLatin1Concat(object, prefix, digits, hash)) |index| {
            const entry = &object.collectionEntriesSlot().*[index];
            const old_value = entry.value;
            entry.value = core.JSValue.int32(int_value);
            old_value.free(rt);
            continue;
        }

        const key = (try core.string.String.createLatin1ConcatWithSeed(rt, prefix, digits, prefix_seed)).value();
        const entry = core.object.CollectionEntry{
            .key = key,
            .value = core.JSValue.int32(int_value),
            .hash = hash,
            .hash_next = strong_no_entry,
        };
        errdefer entry.destroy(rt);
        _ = try appendStrongEntryWithHash(rt, object, entry, hash);
        inserted = true;
    }

    if (inserted) inserted = false;
}

// === Shared helpers ===

fn stringFromValue(value: core.JSValue) ?*core.string.String {
    return value.asStringBody();
}
