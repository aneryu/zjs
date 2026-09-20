//! Typed views over the three small integer slots of an iterator payload
//! (`kind`, `zip_mode`, `zip_state`). The payload stores bare bytes because
//! every iterator class shares one payload struct; what a byte means depends
//! on the class, and these accessors are the only place that knowledge lives.

const core = @import("../core/root.zig");
const std = @import("std");

const Object = core.Object;

/// `Array.prototype.keys / values / entries` (and the typed-array twins).
pub const ArrayIteratorKind = enum(u8) {
    key = 1,
    value = 2,
    key_value = 3,
};

/// `Map` / `Set` iterators.
pub const CollectionIteratorKind = enum(u8) {
    key = 1,
    value = 2,
    key_value = 3,
};

/// Iterator helper objects (`Iterator.prototype.map` and friends).
pub const IteratorHelperKind = enum(u8) {
    map = 1,
    filter = 2,
    take = 3,
    drop = 4,
    flatMap = 5,
    concat = 6,
    zip = 7,
    zip_keyed = 8,
};

/// `Iterator.zip` / `Iterator.zipKeyed` padding rule.
pub const IteratorZipMode = enum(u8) {
    shortest = 0,
    longest = 1,
    strict = 2,
};

/// Where a zip helper is in its protocol.
pub const ZipState = enum(u8) {
    /// Created, no `next` yet.
    fresh = 0,
    /// Last `next` produced a result.
    yielded = 1,
    /// A `next`/`return` is executing (re-entry is a TypeError).
    running = 2,
    /// Closed, every further `next` reports done.
    done = 3,
};

/// `RegExp.prototype[Symbol.matchAll]` string iterators keep the two flags
/// that drive the match loop in the kind slot.
pub const RegExpStringIteratorFlags = packed struct(u8) {
    global: bool = false,
    unicode: bool = false,
    _reserved: u6 = 0,
};

pub fn arrayIteratorKind(iterator: *const Object) ArrayIteratorKind {
    return @enumFromInt(iterator.iteratorKind());
}

pub fn setArrayIteratorKind(iterator: *Object, kind: ArrayIteratorKind) void {
    iterator.iteratorKindSlot().* = @intFromEnum(kind);
}

pub fn collectionIteratorKind(iterator: *const Object) ?CollectionIteratorKind {
    return std.enums.fromInt(CollectionIteratorKind, iterator.iteratorKind());
}

pub fn setCollectionIteratorKind(iterator: *Object, kind: CollectionIteratorKind) void {
    iterator.iteratorKindSlot().* = @intFromEnum(kind);
}

pub fn helperKind(helper: *const Object) IteratorHelperKind {
    return @enumFromInt(helper.iteratorKind());
}

pub fn setHelperKind(helper: *Object, kind: IteratorHelperKind) void {
    helper.iteratorKindSlot().* = @intFromEnum(kind);
}

pub fn zipMode(helper: *const Object) IteratorZipMode {
    return @enumFromInt(helper.iteratorZipMode());
}

pub fn setZipMode(helper: *Object, mode: IteratorZipMode) void {
    helper.iteratorZipModeSlot().* = @intFromEnum(mode);
}

pub fn zipState(helper: *const Object) ZipState {
    return @enumFromInt(helper.iteratorZipState());
}

pub fn setZipState(helper: *Object, state: ZipState) void {
    helper.iteratorZipStateSlot().* = @intFromEnum(state);
}

pub fn regExpStringIteratorFlags(iterator: *const Object) RegExpStringIteratorFlags {
    return @bitCast(iterator.iteratorKind());
}

pub fn setRegExpStringIteratorFlags(iterator: *Object, flags: RegExpStringIteratorFlags) void {
    iterator.iteratorKindSlot().* = @bitCast(flags);
}
