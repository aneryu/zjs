//! The tracer visitor protocol, in one place.
//!
//! A visitor is any value whose type declares some of `visitValue`,
//! `visitObject`, `visitShape`, `visitRealm`, `visitAtom`, `visitModule`, `storageCell`,
//! `visitWeakCollectionEntry` and `visitFinalizationCell`.  Each method may
//! return `void` or an error union, and a visitor that does not declare a
//! method simply does not see that edge kind (the root adaptors, for example,
//! never enumerate heap edges, so `storageCell` compiles away for them).
//!
//! Every `traceChildEdges` body in core/ walks its edges through the typed
//! helpers below instead of open-coding the "declared? fallible?" dance.

const std = @import("std");
const atom_mod = @import("atom.zig");
const context_mod = @import("context.zig");
const gc = @import("gc.zig");
const module_mod = @import("module.zig");
const object_payloads = @import("object_payloads.zig");
const shape_mod = @import("shape.zig");
const string = @import("string.zig");
const JSValue = @import("value.zig").JSValue;
const Object = @import("object.zig").Object;

/// Invoke `method` on the visitor with `arg` when the visitor declares it.
/// Void-returning methods are called directly; fallible ones are `try`ed.
pub inline fn call(vis: anytype, comptime method: []const u8, arg: anytype) !void {
    const Vis = comptime visitorType(@TypeOf(vis));
    if (comptime !@hasDecl(Vis, method)) return;
    const f = @field(Vis, method);
    const info = @typeInfo(@TypeOf(f)).@"fn";
    // Method-call syntax would auto-dereference a pointer visitor for a
    // by-value `self`; `@call` does not, so do it explicitly.
    const self_arg = if (comptime @TypeOf(vis) == info.params[0].type.?) vis else vis.*;
    if (comptime @typeInfo(info.return_type.?) == .error_union) {
        try @call(.auto, f, .{ self_arg, arg });
    } else {
        @call(.auto, f, .{ self_arg, arg });
    }
}

fn visitorType(comptime Vis: type) type {
    return switch (@typeInfo(Vis)) {
        .pointer => |p| p.child,
        else => Vis,
    };
}

pub inline fn value(vis: anytype, slot: *JSValue) !void {
    return call(vis, "visitValue", slot);
}

pub inline fn optionalValue(vis: anytype, slot: *?JSValue) !void {
    if (slot.*) |*stored| try value(vis, stored);
}

pub inline fn object(vis: anytype, slot: *?*Object) !void {
    return call(vis, "visitObject", slot);
}

pub inline fn shape(vis: anytype, shape_ref: *shape_mod.Shape) !void {
    return call(vis, "visitShape", shape_ref);
}

pub inline fn realm(vis: anytype, slot: *?*context_mod.RealmContext) !void {
    return call(vis, "visitRealm", slot);
}

/// TGC S3 §2.2: a holder of an atom id names the atom.  Visitors without a
/// `visitAtom` decl (the cycle visitor, the census walkers, the minor audit)
/// skip the edge silently, exactly like `shape` does.
pub inline fn atom(vis: anytype, id: atom_mod.Atom) !void {
    return call(vis, "visitAtom", id);
}

/// TGC S4 spec 2.2: an owner's edge to a bare storage cell (property
/// entries, array elements, payload slices).
/// A storage cell named by a raw pointer inside its owner.
///
/// `slot` is the owner's pointer itself, read as an address. Every such
/// pointer IS the cell's `Header` address (each `*CellHeader` helper is a bare
/// `@ptrCast`), so a collector that relocates the cell writes the new address
/// straight back through the slot. Handing over a copy of the pointer instead
/// leaves the owner naming the old cell, which is a dangling read the moment
/// anything moves.
pub const CellSlot = struct {
    slot: *usize,
    /// Low bits the owner keeps in the stored word. Zero for a plain pointer;
    /// `bytecode_function_aux_tag` for the one owner that tags.
    tag: usize = 0,

    pub inline fn address(self: CellSlot) usize {
        return self.slot.* & ~self.tag;
    }

    pub inline fn rebind(self: CellSlot, moved: usize) void {
        self.slot.* = moved | (self.slot.* & self.tag);
    }
};

pub inline fn storageCell(vis: anytype, edge: CellSlot) !void {
    if (edge.address() == 0) return;
    return call(vis, "storageCell", edge);
}

pub inline fn module(vis: anytype, record: *module_mod.ModuleRecord) !void {
    return call(vis, "visitModule", record);
}

pub inline fn weakCollectionEntry(vis: anytype, entry: *object_payloads.WeakCollectionEntry) !void {
    return call(vis, "visitWeakCollectionEntry", entry);
}

pub inline fn finalizationCell(vis: anytype, entry: *object_payloads.FinalizationRegistryCell) !void {
    return call(vis, "visitFinalizationCell", entry);
}

/// A string body's child edges: the rope children and the out-of-line
/// buffer cell.  Bodies are reached through `JSValue` slots, so the helper
/// takes the value form the visitors understand.
/// A string body named by an optional `*String` field. Same contract as
/// `storageCell`: the owner's slot, so a relocation is written back.
pub inline fn stringBody(vis: anytype, slot: *?*string.String) !void {
    const body = slot.* orelse return;
    var boxed = body.value();
    try value(vis, &boxed);
    slot.* = boxed.asStringBodyRaw();
}

test "call skips undeclared methods and adapts to void or fallible ones" {
    const Counting = struct {
        values: usize = 0,
        objects: usize = 0,

        pub fn visitValue(self: *@This(), _: *JSValue) void {
            self.values += 1;
        }

        pub fn visitObject(self: *@This(), _: *?*Object) error{Stop}!void {
            self.objects += 1;
            if (self.objects == 2) return error.Stop;
        }
    };
    var counting: Counting = .{};
    var v = JSValue.undefinedValue();
    var o: ?*Object = null;
    try value(&counting, &v);
    try shape(&counting, undefined);
    try object(&counting, &o);
    try std.testing.expectError(error.Stop, object(&counting, &o));
    try std.testing.expectEqual(@as(usize, 1), counting.values);
    try std.testing.expectEqual(@as(usize, 2), counting.objects);

    const ByValue = struct {
        sink: *usize,
        pub fn visitValue(self: @This(), _: *JSValue) void {
            self.sink.* += 1;
        }
    };
    var hits: usize = 0;
    var by_value: ByValue = .{ .sink = &hits };
    try value(by_value, &v);
    try value(&by_value, &v);
    try std.testing.expectEqual(@as(usize, 2), hits);
}

/// A struct's collector-edge manifest.  `assertClassified` proves at
/// comptime that every field which can carry a heap reference sits in
/// exactly one list, so adding a `?JSValue` (or `[]CollectionEntry`, or
/// `RealmRef`) field without deciding how the tracer sees it fails to
/// compile instead of leaking an edge.
pub const Edges = struct {
    /// Traced by `traceDeclared`: `JSValue`, `?JSValue` and `?*Object` slots.
    strong: []const []const u8 = &.{},
    /// Aggregates traced through their own `traceChildEdges`.
    nested: []const []const u8 = &.{},
    /// Walked by hand in the owner's `traceChildEdges`: slices that need a
    /// `storageCell` edge first, entry arrays, realm refs, atom holders.
    manual: []const []const u8 = &.{},
    /// Deliberately not strong edges: weak links and weak identities.
    weak: []const []const u8 = &.{},

    fn listings(comptime self: Edges, comptime name: []const u8) usize {
        var n: usize = 0;
        for ([_][]const []const u8{ self.strong, self.nested, self.manual, self.weak }) |list| {
            for (list) |entry| n += @intFromBool(std.mem.eql(u8, entry, name));
        }
        return n;
    }
};

/// Whether a field of type `T` can hold a reference the collector must see:
/// a value, an object/string/realm pointer, an atom id, or any optional,
/// slice, array, struct or union that contains one.  Pointers to anything
/// else (payload-internal links, host handles) are not collector edges.
pub fn carriesReference(comptime T: type) bool {
    if (T == JSValue or T == atom_mod.Atom) return true;
    return switch (@typeInfo(T)) {
        .optional => |info| carriesReference(info.child),
        .array => |info| carriesReference(info.child),
        .pointer => |info| if (info.size == .slice)
            carriesReference(info.child)
        else
            info.child == Object or info.child == string.String or info.child == context_mod.RealmContext,
        .@"struct", .@"union" => inline for (std.meta.fields(T)) |field| {
            if (carriesReference(field.type)) break true;
        } else false,
        else => false,
    };
}

/// Comptime proof that `T.gc_edges` classifies every reference-carrying
/// field once and names nothing else.
pub fn assertClassified(comptime T: type) void {
    comptime {
        @setEvalBranchQuota(20_000);
        const edges: Edges = T.gc_edges;
        for (std.meta.fields(T)) |field| {
            const listed = edges.listings(field.name);
            if (carriesReference(field.type)) {
                if (listed != 1) @compileError(@typeName(T) ++ "." ++ field.name ++ " can hold a heap reference; list it in exactly one gc_edges list");
            } else if (listed != 0) {
                @compileError(@typeName(T) ++ "." ++ field.name ++ " is listed in gc_edges but cannot hold a heap reference");
            }
        }
        for (edges.strong) |name| {
            const Slot = @FieldType(T, name);
            if (Slot != JSValue and Slot != ?JSValue and Slot != ?*Object)
                @compileError(@typeName(T) ++ "." ++ name ++ " is not a JSValue/?JSValue/?*Object slot; trace it by hand under `manual`");
        }
        for (edges.nested) |name| {
            if (!@hasDecl(@FieldType(T, name), "traceChildEdges"))
                @compileError(@typeName(T) ++ "." ++ name ++ " has no traceChildEdges; it cannot be `nested`");
        }
    }
}

/// Trace the `strong` and `nested` edges `T.gc_edges` declares, in manifest
/// order.  The hand-written part of a payload's `traceChildEdges` follows.
pub inline fn traceDeclared(self: anytype, visitor: anytype) !void {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    const edges: Edges = T.gc_edges;
    inline for (edges.strong) |name| {
        const slot = &@field(self, name);
        switch (@FieldType(T, name)) {
            JSValue => try value(visitor, slot),
            ?JSValue => try optionalValue(visitor, slot),
            ?*Object => try object(visitor, slot),
            else => comptime unreachable,
        }
    }
    inline for (edges.nested) |name| try @field(self, name).traceChildEdges(visitor);
}

test "carriesReference sees through optionals, slices, arrays and aggregates" {
    const Link = struct { previous: ?*Object = null, next: ?*Object = null, n: u32 = 0 };
    const Entry = struct { key: JSValue, hash: u64 };
    try std.testing.expect(carriesReference(JSValue));
    try std.testing.expect(carriesReference(?JSValue));
    try std.testing.expect(carriesReference([]Entry));
    try std.testing.expect(carriesReference([9]?JSValue));
    try std.testing.expect(carriesReference(Link));
    try std.testing.expect(carriesReference([]atom_mod.Atom));
    try std.testing.expect(carriesReference(context_mod.RealmRef));
    try std.testing.expect(carriesReference(?*string.String));
    try std.testing.expect(!carriesReference([]u8));
    try std.testing.expect(!carriesReference(?*Link));
    try std.testing.expect(!carriesReference(?*anyopaque));
    try std.testing.expect(!carriesReference(struct { n: usize, flag: bool }));
}

test "traceDeclared walks strong slots and nested aggregates in manifest order" {
    const Inner = struct {
        held: JSValue = JSValue.undefinedValue(),
        pub const gc_edges: Edges = .{ .strong = &.{"held"} };
        pub fn traceChildEdges(self: *@This(), visitor: anytype) !void {
            try traceDeclared(self, visitor);
        }
    };
    const Outer = struct {
        first: ?JSValue = null,
        inner: Inner = .{},
        last: JSValue = JSValue.undefinedValue(),
        link: ?*Object = null,
        count: usize = 0,
        pub const gc_edges: Edges = .{ .strong = &.{ "first", "last", "link" }, .nested = &.{"inner"} };
        comptime {
            assertClassified(@This());
        }
    };
    const Recorder = struct {
        slots: std.ArrayListUnmanaged(usize) = .empty,
        pub fn visitValue(self: *@This(), slot: *JSValue) !void {
            try self.slots.append(std.testing.allocator, @intFromPtr(slot));
        }
        pub fn visitObject(self: *@This(), slot: *?*Object) !void {
            try self.slots.append(std.testing.allocator, @intFromPtr(slot));
        }
    };
    var outer: Outer = .{ .first = JSValue.undefinedValue() };
    var recorder: Recorder = .{};
    defer recorder.slots.deinit(std.testing.allocator);
    try traceDeclared(&outer, &recorder);
    const expected = [_]usize{
        @intFromPtr(&outer.first.?),
        @intFromPtr(&outer.last),
        @intFromPtr(&outer.link),
        @intFromPtr(&outer.inner.held),
    };
    try std.testing.expectEqualSlices(usize, &expected, recorder.slots.items);
}
