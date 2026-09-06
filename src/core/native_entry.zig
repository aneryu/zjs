//! NativeEntry: the single native-function kind of the NB2 boundary
//! (docs/perf/native-boundary-design.md §3.1, §4). Builtins, host functions,
//! plugin functions and native accessors all resolve to one immutable entry;
//! steady-state dispatch never branches on where the entry came from.
//!
//! Layout is `extern` and offset-pinned because the entry is the direct input
//! of the interpreter's native arms today and of machine code tomorrow (§15
//! R1): the JIT reads `target`/`kind`/`sig`/`class_id` at fixed offsets.
//!
//! Lifetime (§5.5): an entry is never freed before its runtime dies. Builtin
//! entries are comptime rodata; host entries live in the runtime's entry
//! arena. Retiring an entry rewrites `kind = .retired` in place (tombstone),
//! so a call-site cache that compares `func_obj.entry == cached` on a live
//! object can never reach freed memory.

const std = @import("std");
const atom = @import("atom.zig");
const value = @import("value.zig");
const context_mod = @import("context.zig");
const object_mod = @import("object.zig");

pub const JSValue = value.JSValue;
pub const JSContext = context_mod.JSContext;
pub const Object = object_mod.Object;

/// Call kinds (§4). The VM switches on this once per call; everything the
/// arm needs is in the entry.
pub const Kind = enum(u8) {
    /// K0: `ManagedFn`, `this` by value, argv into the operand window.
    managed = 0,
    /// K4: `CtorFn`; only constructible (`new`); calling throws TypeError.
    constructor = 1,
    /// K4: `CtorFn`; callable both ways, `new_target` tells which.
    constructor_or_func = 2,
    /// K3: `GetterFn`.
    getter = 3,
    /// K3: `SetterFn`.
    setter = 4,
    /// K1: typed leaf; `sig` selects the comptime-generated VM arm.
    leaf = 5,
    /// K2: typed leaf with `self` unwrapped from a NativeObject receiver.
    method_leaf = 6,
    /// K2: `MethodManagedFn` with `self` unwrapped.
    method_managed = 7,
    /// Function.prototype.call: window-forwarding arm, no native target.
    forward_call = 8,
    /// Function.prototype.apply: same.
    forward_apply = 9,
    /// Tombstone: owner retired the entry; calling throws.
    retired = 255,

    pub inline fn isConstructor(self: Kind) bool {
        return self == .constructor or self == .constructor_or_func;
    }
};

pub const Flags = packed struct(u8) {
    /// Legacy builtin body reads the stack-local native environment
    /// (`builtin_dispatch.nativeCall`): the managed arm materializes it.
    /// Phase A2 sets it for every legacy entry; A4 strips it by census.
    needs_env: bool = false,
    /// Function.prototype.call/apply-style transparent forwarding: the VM's
    /// native arms skip `vm_native.dispatch` and, for a same-Realm bytecode
    /// target, rewrite the operand window into an ordinary method call
    /// (§5.4; `op_call_method` selects the call / apply body by target
    /// identity, `function_ops.call_entry_target` / `apply_entry_target`).
    /// Any other receiver or argument-list shape falls to the managed body.
    forwards_call: bool = false,
    /// The target reads `argv[0..arity]` without checking `argc`: the
    /// dispatcher must pad the operand window with `undefined` (§4.1).
    /// Legacy bodies take an exact slice and leave this clear.
    pad_args: bool = false,
    _pad: u5 = 0,
};

/// JIT scheduling annotation (§15 R2); same meaning as the engine plan's
/// `HelperDescriptor { can_gc, can_throw, can_reenter_js }`. Leaf = all zero.
/// The interpreter only reads `may_throw`.
pub const Effect = packed struct(u8) {
    may_throw: bool = true,
    may_alloc: bool = true,
    may_reenter_js: bool = true,
    reads_heap: bool = true,
    writes_heap: bool = true,
    _pad: u3 = 0,

    pub const leaf: Effect = .{ .may_throw = false, .may_alloc = false, .may_reenter_js = false, .reads_heap = false, .writes_heap = false };
    pub const managed: Effect = .{};
};

/// K0 machine signature (§4.1): 7 integer registers on AArch64 / SysV.
/// With `flags.pad_args`, `argv[0..max(argc, entry.arity)]` is readable (the
/// dispatcher pads with `undefined`); extra arguments are ignored. `func_obj`
/// is the callee (qjs `js_call_c_function` has it too): legacy bodies need it
/// for realm resolution and `c_function_data` bound values; it is null only
/// for synthetic algorithm-internal invocations (`callInternalRecord` with no
/// carrier). Returns the exception sentinel iff `ctx.hasException()`.
///
/// Phase A2: `.constructor` / `.constructor_or_func` entries also carry this
/// prototype (the construct path passes `this = undefined` and publishes
/// `new_target` through the native environment, as before); `CtorFn`
/// adoption is phase A4.
pub const ManagedFn = *const fn (
    ctx: *JSContext,
    this: JSValue,
    argv: [*]const JSValue,
    argc: u32,
    entry: *const NativeEntry,
    func_obj: ?*Object,
) callconv(.c) JSValue;

/// K4: `new_target` is `undefined` when called as a plain function
/// (only legal for `.constructor_or_func`).
pub const CtorFn = *const fn (
    ctx: *JSContext,
    new_target: JSValue,
    argv: [*]const JSValue,
    argc: u32,
    entry: *const NativeEntry,
    func_obj: ?*Object,
) callconv(.c) JSValue;

pub const GetterFn = *const fn (ctx: *JSContext, this: JSValue, entry: *const NativeEntry) callconv(.c) JSValue;
pub const SetterFn = *const fn (ctx: *JSContext, this: JSValue, new_value: JSValue, entry: *const NativeEntry) callconv(.c) JSValue;

/// K2 managed: `self` is the NativeObject payload pointer.
pub const MethodManagedFn = *const fn (
    ctx: *JSContext,
    self: *anyopaque,
    this: JSValue,
    argv: [*]const JSValue,
    argc: u32,
    entry: *const NativeEntry,
) callconv(.c) JSValue;

/// Opaque code pointer: every `target` is one of the typed prototypes above
/// or a leaf C prototype selected by `sig`.
pub const CodePtr = *const fn () callconv(.c) void;

pub const NativeEntry = extern struct {
    /// @0 Native code pointer; typed by `kind` (+ `sig` for leaf kinds).
    target: CodePtr,
    /// @8 Leaf tag-check failure fallback (builtin ToNumber semantics);
    /// null = throw TypeError/RangeError at the VM side (plugin policy).
    fallback: ?ManagedFn = null,
    /// @16 Stateful entries; null for builtins.
    state: ?*anyopaque = null,
    /// @24
    kind: Kind,
    /// @25
    flags: Flags = .{},
    /// @26 Leaf signature id (FNABI schema); 0 for managed kinds.
    sig: u16 = 0,
    /// @28 JS `length`; also the argv padding upper bound.
    arity: u8 = 0,
    /// @29
    effect: Effect = Effect.managed,
    /// @30 K2: required receiver class id (NativeType); 0 otherwise.
    class_id: u16 = 0,
    /// @32 Builtin magic selector (qjs `magic`).
    magic: u16 = 0,
    /// @34 Static builtin table index (§15 R9); 0 for host entries.
    builtin_id: u16 = 0,
    /// @36 Name atom for backtraces / diagnostics (null_atom = anonymous).
    name: atom.Atom = atom.null_atom,
    /// @40 Cold provenance (FNABI §10.3); arms never read it.
    owner: ?*anyopaque = null,

    pub inline fn managed(self: *const NativeEntry) ManagedFn {
        std.debug.assert(self.kind == .managed or self.kind.isConstructor());
        return @ptrCast(self.target);
    }

    pub inline fn ctor(self: *const NativeEntry) CtorFn {
        std.debug.assert(self.kind.isConstructor());
        return @ptrCast(self.target);
    }

    /// K3 managed prototype. A typed accessor (`sig != 0`, the `SELF_*`
    /// leaf prototypes of §4.4) is dispatched by the VM-side typed arm
    /// instead and never through this cast.
    pub inline fn getter(self: *const NativeEntry) GetterFn {
        std.debug.assert(self.kind == .getter and self.sig == 0);
        return @ptrCast(self.target);
    }

    pub inline fn setter(self: *const NativeEntry) SetterFn {
        std.debug.assert(self.kind == .setter and self.sig == 0);
        return @ptrCast(self.target);
    }

    pub inline fn methodManaged(self: *const NativeEntry) MethodManagedFn {
        std.debug.assert(self.kind == .method_managed);
        return @ptrCast(self.target);
    }

    pub inline fn isConstructor(self: *const NativeEntry) bool {
        return self.kind.isConstructor();
    }

    /// Registration-side type eraser: the only sanctioned way to fill
    /// `target`, so every stored pointer provably carries the prototype its
    /// `kind` implies.
    pub inline fn code(comptime f: anytype) CodePtr {
        return @ptrCast(f);
    }
};

comptime {
    std.debug.assert(@sizeOf(NativeEntry) == 48);
    std.debug.assert(@alignOf(NativeEntry) == 8);
    std.debug.assert(@offsetOf(NativeEntry, "target") == 0);
    std.debug.assert(@offsetOf(NativeEntry, "fallback") == 8);
    std.debug.assert(@offsetOf(NativeEntry, "state") == 16);
    std.debug.assert(@offsetOf(NativeEntry, "kind") == 24);
    std.debug.assert(@offsetOf(NativeEntry, "flags") == 25);
    std.debug.assert(@offsetOf(NativeEntry, "sig") == 26);
    std.debug.assert(@offsetOf(NativeEntry, "arity") == 28);
    std.debug.assert(@offsetOf(NativeEntry, "effect") == 29);
    std.debug.assert(@offsetOf(NativeEntry, "class_id") == 30);
    std.debug.assert(@offsetOf(NativeEntry, "magic") == 32);
    std.debug.assert(@offsetOf(NativeEntry, "builtin_id") == 34);
    std.debug.assert(@offsetOf(NativeEntry, "name") == 36);
    std.debug.assert(@offsetOf(NativeEntry, "owner") == 40);
}

/// Per-domain static table of builtin entries (replaces InternalRecordTable):
/// a dense low-id prefix plus a sparse tail, both comptime rodata.
pub const SparseEntry = struct {
    id: u32,
    entry: NativeEntry,
};

pub const EntryTable = struct {
    dense: []const NativeEntry = &.{},
    sparse: []const SparseEntry = &.{},

    pub inline fn get(self: EntryTable, id: u32) ?*const NativeEntry {
        if (id < self.dense.len) {
            const entry = &self.dense[id];
            return if (entry.kind == .retired) null else entry;
        }
        for (self.sparse) |*item| {
            if (item.id == id) return &item.entry;
        }
        return null;
    }
};

/// Gap filler for dense tables: a retired tombstone that `get` treats as
/// missing. `target` must be non-null in an `extern struct`, so it points at
/// a trap that must never be called.
fn retiredTrap() callconv(.c) void {
    unreachable;
}

pub const retired_entry: NativeEntry = .{
    .target = &retiredTrap,
    .kind = .retired,
};

test "NativeEntry layout is the pinned 48-byte extern shape" {
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(NativeEntry));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(NativeEntry, "owner"));
}

fn testManaged(ctx: *JSContext, this: JSValue, argv: [*]const JSValue, argc: u32, entry: *const NativeEntry, func_obj: ?*Object) callconv(.c) JSValue {
    _ = ctx;
    _ = this;
    _ = func_obj;
    _ = entry;
    return if (argc > 0) argv[0] else JSValue.undefinedValue();
}

test "managed target round-trips through the erased code pointer" {
    const entry: NativeEntry = .{ .target = NativeEntry.code(&testManaged), .kind = .managed, .arity = 1 };
    const f = entry.managed();
    try std.testing.expect(@intFromPtr(f) == @intFromPtr(&testManaged));
}
