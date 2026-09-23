//! Traced Symbol identities with inline descriptions, plus registry queries.
//! String and Symbol have separate types and GC kinds. WTF-8 preserves lone
//! surrogates and lets atom/diagnostic readers borrow the inline bytes;
//! `.description` materializes a normal String only when requested.

const core = @import("root.zig");
const atom = @import("atom.zig");
const std = @import("std");
const gc = @import("gc.zig");
const block_heap = @import("gc_block_heap.zig");
const string = @import("string.zig");
const memory = @import("memory.zig");

/// A unique identity with an inline WTF-8 description. The collector owns the
/// body; the atom table only indexes it. No String pointer aliases this body.
pub const Symbol = struct {
    atom_id: atom.Atom,
    byte_len: u32,
    has_description: bool,

    pub const no_atom_id = string.String.no_atom_id;

    pub fn header(self: *const Symbol) *gc.Header {
        return @ptrCast(@alignCast(@constCast(self)));
    }

    pub fn fromHeader(h: *gc.Header) *Symbol {
        std.debug.assert(h.metaConst().flags.kind == .symbol);
        return @ptrCast(@alignCast(h));
    }

    /// Borrowed until this body dies. Empty and absent descriptions differ.
    pub fn descriptionBytes(self: *const Symbol) ?[]const u8 {
        if (!self.has_description) return null;
        const base: [*]const u8 = @ptrCast(self);
        return base[@sizeOf(Symbol)..][0..self.byte_len];
    }

    pub fn value(self: *Symbol) core.JSValue {
        return core.JSValue.symbol(self.header());
    }

    pub fn descriptionValue(self: *const Symbol, rt: *core.JSRuntime) !core.JSValue {
        var rooted = @constCast(self).value();
        var roots = core.runtime.rootValues(.{&rooted});
        roots.activate(rt);
        defer roots.deactivate(rt);
        const bytes = self.descriptionBytes() orelse return core.JSValue.undefinedValue();
        if (bytes.len == 0) return (try rt.emptyString()).value();
        return (try string.String.createUtf8(rt, bytes)).value();
    }

    /// The caller protects the atom entry and its input across allocation,
    /// then installs this body without another allocation.
    pub fn create(rt: *core.JSRuntime, id: atom.Atom, bytes: ?[]const u8) !*Symbol {
        const text = bytes orelse "";
        try string.validateUtf8Length(text);
        const len = std.math.cast(u32, text.len) orelse return error.StringTooLong;
        const total = try std.math.add(usize, gc.string_prefix_size + @sizeOf(Symbol), text.len);
        rt.collectBeforeObjectAllocation(total);
        const base = if (try memory.createStringCell(rt, gc.representation.symbol_kind_tag, total)) |cell|
            cell
        else
            (try memory.createExtent(rt, gc.representation.symbol_kind_tag, total)).ptr;
        const self: *Symbol = @ptrCast(@alignCast(base + gc.string_prefix_size));
        self.* = .{ .atom_id = id, .byte_len = len, .has_description = bytes != null };
        const payload: [*]u8 = @ptrCast(self);
        @memcpy(payload[@sizeOf(Symbol)..][0..text.len], text);
        rt.gc.addInitializedWithSizeNoFail(self.header(), self.accountedSize());
        if (!id.isConst()) rt.gc.setNeedsFinalizer(self.header());
        return self;
    }

    fn allocationSize(self: *const Symbol) usize {
        return gc.string_prefix_size + @sizeOf(Symbol) + @as(usize, self.byte_len);
    }

    pub fn accountedSize(self: *const Symbol) usize {
        const total = self.allocationSize();
        if (gc.Registry.isBlockCellHeader(self.header()))
            return block_heap.accountedBodyBytesForRequest(total, gc.string_prefix_size).?;
        return total - gc.string_prefix_size;
    }

    pub fn destroy(rt: *core.JSRuntime, h: *gc.Header) void {
        const self = fromHeader(h);
        const total = self.allocationSize();
        if (self.atom_id != no_atom_id and !self.atom_id.isConst())
            rt.atoms.onSymbolBodyDead(self.atom_id, self);
        if (gc.Registry.isBlockCellHeader(h)) {
            rt.gc.unpublishStringCell(h, self.accountedSize());
            memory.destroyStringCell(rt, self, total);
        } else {
            rt.gc.unpublishStringExtent(h, total - gc.string_prefix_size);
            memory.destroyStringExtent(rt, self, total);
        }
    }
};

/// Returns the description string of `symbol`, or null when the symbol has no
/// description.
pub fn description(rt: *const core.JSRuntime, symbol: atom.Atom) ?[]const u8 {
    const kind = rt.atoms.kind(symbol) orelse return null;
    if (!atom.isPublicSymbolKind(kind) and kind != .private) return null;
    return rt.atoms.symbolDescription(rt, symbol);
}

/// Returns the global-registry key of `symbol` (the string passed to
/// `Symbol.for`), or null when `symbol` is not a registered symbol.
pub fn registryKey(atoms: *atom.AtomTable, symbol: atom.Atom) ?[]const u8 {
    if (atoms.kind(symbol) != .global_symbol) return null;
    return atoms.name(symbol);
}

/// CanBeHeldWeakly predicate: objects and non-registered (unique) symbols may be
/// held weakly; registered (`Symbol.for`) symbols and primitives may not.
pub fn canBeHeldWeakly(rt: *core.JSRuntime, value: core.JSValue) bool {
    if (value.is(.object)) return true;
    if (value.asSymbolAtom()) |atom_id| {
        return rt.atoms.kind(atom_id) == .symbol;
    }
    return false;
}

test "symbol inline description preserves absence Unicode and string boundaries" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    const descriptions = [_]?[]const u8{ null, "", "x", "a\x00b", "é😀", "\xed\xa0\x80" };
    for (descriptions) |text| {
        var value = try rt.newSymbolValue(text);
        var roots = core.runtime.rootValues(.{&value});
        roots.activate(rt);
        defer roots.deactivate(rt);
        const body = value.asSymbolBody().?;
        try std.testing.expectEqual(gc.RefKind.symbol, body.header().metaConst().flags.kind);
        try std.testing.expect(value.asStringBody() == null);
        try std.testing.expect(value.asStringBodyRaw() == null);
        try std.testing.expect(value.stringHeader() == null);
        try std.testing.expect(value.asString() == null);
        const id = value.asSymbolAtom().?;
        try std.testing.expect(rt.atoms.cachedString(id) == null);
        try std.testing.expect(rt.atoms.cachedPushValue(id) == null);
        // The table owns no duplicate description after materialization.
        try std.testing.expectEqual(@as(usize, 0), rt.atoms.entries[id.raw() - atom.first_dynamic_atom].bytes.len);
        var description_value = try body.descriptionValue(rt);
        var description_roots = core.runtime.rootValues(.{&description_value});
        description_roots.activate(rt);
        defer description_roots.deactivate(rt);
        if (text) |bytes| {
            try std.testing.expectEqualStrings(bytes, body.descriptionBytes().?);
            try std.testing.expectEqualStrings(bytes, rt.atoms.name(id).?);
            const ordinary = description_value.asStringBody().?;
            const expected = try string.String.createUtf8(rt, bytes);
            try std.testing.expect(ordinary.eqlString(expected));
            try std.testing.expect((try ordinary.internAtom(rt)) != id);
            // The atom->text helper must never return the identity body.
            const from_atom = try string.String.createAtomBacked(rt, id);
            try std.testing.expect(from_atom.eqlString(expected));
            try std.testing.expect((try from_atom.internAtom(rt)) != id);
        } else {
            try std.testing.expect(body.descriptionBytes() == null);
            try std.testing.expect(description_value.is(.undefined_value));
        }
    }
}

test "symbol registered and predefined identities never enter string caches" {
    const rt = try core.JSRuntime.create(.{ .allocator = std.testing.allocator });
    defer rt.destroy();
    var first = try rt.newSymbolValue("same");
    var roots = core.runtime.rootValues(.{&first});
    roots.activate(rt);
    defer roots.deactivate(rt);
    const second = try rt.newSymbolValue("same");
    try std.testing.expect(first.asSymbolBody().? != second.asSymbolBody().?);
    const registered = try rt.globalSymbolValue("same");
    const again = try rt.globalSymbolValue("same");
    try std.testing.expectEqual(registered.asSymbolBody().?, again.asSymbolBody().?);
    try std.testing.expect(first.asSymbolBody().? != registered.asSymbolBody().?);
    try std.testing.expectEqualStrings("same", registryKey(&rt.atoms, registered.asSymbolAtom().?).?);
    const predefined = try rt.symbolValue(atom.ids.Symbol_iterator);
    try std.testing.expect(rt.atoms.cachedString(atom.ids.Symbol_iterator) == null);
    try std.testing.expect(rt.atoms.cachedPushValue(atom.ids.Symbol_iterator) == null);
    const name_value = try rt.atoms.toStringValueForPush(rt, atom.ids.Symbol_iterator);
    try std.testing.expect(name_value.isString());
    try std.testing.expect(name_value.asStringBody().?.eqlBytes("Symbol.iterator"));
    try std.testing.expectEqual(predefined.asSymbolBody().?, (try rt.symbolValue(atom.ids.Symbol_iterator)).asSymbolBody().?);
}
