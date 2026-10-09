//! Ambient root for atom ids a compile holds in plain fields.
//!
//! `atom.zig` re-exports `CompileAtomScope`.

const std = @import("std");
const runtime_mod = @import("../runtime.zig");
const atom = @import("atom.zig");

const JSRuntime = runtime_mod.JSRuntime;
const Atom = atom.Atom;
const AtomTable = atom.AtomTable;
const null_atom = atom.null_atom;

/// TGC S3 §2.2 "编译作用域 provider" (K/L/M): a precise root for every atom id
/// the compile front end is holding in plain `u32` fields.
///
/// The parser/lexer/compiler chain (lexer token -> `FunctionDef` -> builder ->
/// `resolve_variables`/`resolve_labels` -> published `FunctionBytecode`) parks
/// atom ids in Zig-heap structs that the conservative stack scan cannot read
/// as roots and that carry no tracer edge until the `FunctionBytecode` is
/// published, so a major inside a compile would retire them mid-flight. This scope is the interval root: every id the
/// compile OBTAINS is recorded (including ids that already existed -- an atom
/// whose only other holder dies during the compile must not be swept), and the
/// registered provider reports the whole list on every trace.
///
/// Recording is ambient: `AtomTable.compile_scope` points at the innermost
/// active scope and every intern/dup entry point notes into it, so the ~267
/// compile-side call sites need no signature change and none can be missed.
/// Scopes nest (direct eval, sub-parse); each one registers its own provider,
/// so an inner scope's death cannot orphan an outer scope's ids.
///
/// `rt == null` (the standalone `AtomTable` the parser/compiler fixtures build,
/// which has no collector at all) degrades to record-only: no registration, no
/// provider, and the list is still kept so the type behaves identically.
pub const CompileAtomScope = struct {
    /// Power of two; `note` masks with `recent_slots - 1`.
    const recent_slots: u32 = 64;

    rt: ?*runtime_mod.JSRuntime,
    table: *AtomTable,
    allocator: std.mem.Allocator,
    ids: std.ArrayListUnmanaged(Atom) = .empty,
    /// Ambient chain: the scope that was installed on the table when this one
    /// activated. Restored on `deinit`.
    prev: ?*CompileAtomScope = null,
    active: bool = false,
    registered: bool = false,
    /// Direct-mapped "already in `ids`" filter. A compile re-obtains the same
    /// identifier constantly (every `get_field`, every scope-var resolution),
    /// so without a filter a large file appends millions of entries. A hit is
    /// exact -- the slot only ever holds an id this scope really appended --
    /// so a miss costs a duplicate list entry, never a missing root.
    /// Measured: the 1.2 MB `typescript-compiler.js` records 27,875 ids
    /// (~112 KB) for one compile, roughly 2x its distinct-identifier count.
    recent: [recent_slots]Atom = @splat(null_atom),

    /// Build a detached scope. `activate` must run once the scope sits at its
    /// final address -- the provider stores `&self`, so a scope that is still
    /// going to be moved (e.g. a `State` returned by value) must not register
    /// yet. Mirrors `ReplaceMatchRoots.activate` in exec/string_ops.zig.
    pub fn init(table: *AtomTable, rt: ?*JSRuntime) CompileAtomScope {
        if (rt) |owner| std.debug.assert(owner.atoms == table);
        return .{
            .rt = rt,
            .table = table,
            .allocator = table.native_allocator,
        };
    }

    fn traceRootsThunk(context: *anyopaque, visitor: *runtime_mod.RootVisitor) runtime_mod.RootTraceError!void {
        const self: *CompileAtomScope = @ptrCast(@alignCast(context));
        for (self.ids.items) |id| try visitor.atomRoot(id);
    }

    fn provider(self: *CompileAtomScope) runtime_mod.RootProvider {
        return .{ .context = @ptrCast(self), .trace = traceRootsThunk };
    }

    /// Install as the innermost ambient scope and (when there is a runtime)
    /// register the root provider.
    pub fn activate(self: *CompileAtomScope) !void {
        std.debug.assert(!self.active);
        if (self.rt) |rt| {
            try rt.registerRootProvider(self.provider());
            self.registered = true;
        }
        self.prev = self.table.compile_scope;
        self.table.compile_scope = self;
        self.active = true;
    }

    pub fn deinit(self: *CompileAtomScope) void {
        if (self.active) {
            // Scopes are strictly stack-disciplined; anything else means a
            // caller leaked one.
            std.debug.assert(self.table.compile_scope == self);
            self.table.compile_scope = self.prev;
            self.prev = null;
            self.active = false;
        }
        if (self.registered) {
            self.rt.?.unregisterRootProvider(self.provider());
            self.registered = false;
        }
        self.ids.deinit(self.allocator);
        self.ids = .empty;
        self.recent = @splat(null_atom);
    }

    /// Record an id the compile obtained. Predefined and tagged-int ids are
    /// not table entries and can never be retired, so they are dropped here
    /// rather than growing the list.
    pub fn note(self: *CompileAtomScope, id: Atom) void {
        if (id == null_atom or id.isConst() or id.isTaggedInt()) return;
        const slot = id.raw() & (recent_slots - 1);
        if (self.recent[slot] == id) return;
        self.ids.append(self.allocator, id) catch {
            // A root list that cannot grow must not silently drop a root.
            // Pin the id for the rest of the runtime instead: over-retention
            // is the only safe direction, and this is an OOM-only path.
            self.table.pinForHost(id);
            return;
        };
        self.recent[slot] = id;
    }

    /// Explicit form of the ambient recording, for a call site that wants the
    /// scope spelled out. The symbol family (`newSymbol`/`internGlobalSymbol`,
    /// the parser's private names) needs no wrapper: those entry points note into
    /// the ambient scope like every other one.
    pub fn intern(self: *CompileAtomScope, bytes: []const u8) !Atom {
        const id = try self.table.internString(bytes);
        self.note(id);
        return id;
    }

    /// Explicit form for an id the scope did not intern itself (the caller
    /// obtained it before the scope opened).
    pub fn noteExisting(self: *CompileAtomScope, id: Atom) Atom {
        self.note(id);
        return id;
    }
};
