//! Core array-index classification, Array identity checks, and literal construction.
//!
//! Index helpers are pure. Literal constructors either duplicate borrowed
//! values or explicitly consume already-owned operand values, as their names
//! and comments specify; temporary root slices cover allocating borrowed paths.
//! QuickJS map: `JS_AtomIsArrayIndex` at quickjs.c:3634 and `OP_array_from`
//! near quickjs.c:18239. Exec owns Array builtins, while this lower-layer seam
//! may import core/libs only and never parser/exec/runtime/binding.

const atom = @import("atom.zig");
const JSValue = @import("value.zig").JSValue;
const Object = @import("object.zig").Object;
const JSRuntime = @import("runtime.zig").JSRuntime;
const runtime = @import("runtime.zig");
const value_semantics = @import("value_semantics.zig");
const Descriptor = @import("descriptor.zig").Descriptor;
const shape_mod = @import("shape.zig");

pub const max_array_index: u32 = 0xffff_fffe;
pub const max_array_length: u32 = 0xffff_ffff;

pub fn isArrayIndexName(bytes: []const u8) bool {
    return arrayIndexFromName(bytes) != null;
}

pub fn arrayIndexFromAtom(atoms: anytype, atom_id: atom.Atom) ?u32 {
    // Mirrors QuickJS JS_AtomIsArrayIndex (quickjs.c:3634): tagged integer
    // atoms are array indexes directly. zjs internString tags every
    // array-index-form decimal string <= atom.max_int_atom, so a non-tagged
    // atom shorter than the 10-digit high-index window cannot be an array index.
    if (atom.isTaggedInt(atom_id)) {
        const index = atom.atomToUInt32(atom_id);
        if (index <= max_array_index) return index;
        return null;
    }
    const name = atoms.name(atom_id) orelse return null;
    if (name.len < 10) return null;
    if (atoms.kind(atom_id) != .string) return null;
    return arrayIndexFromName(name);
}

pub fn arrayIndexFromName(bytes: []const u8) ?u32 {
    if (bytes.len == 0) return null;
    if (bytes.len > 1 and bytes[0] == '0') return null;

    var n: u64 = 0;
    for (bytes) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
        if (n > max_array_index) return null;
    }
    return @intCast(n);
}

pub fn canonicalNumericIndex(bytes: []const u8) ?f64 {
    if (std.mem.eql(u8, bytes, "-0")) return -0.0;
    if (std.fmt.parseFloat(f64, bytes)) |value| {
        var buf: [64]u8 = undefined;
        const printed = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return null;
        if (std.mem.eql(u8, printed, bytes)) return value;
    } else |_| {}
    return null;
}

const objectFromValue = value_semantics.objectFromValue;
const expectObject = value_semantics.expectObject;

/// Proxy-aware `Array.isArray` predicate. Pure: walks the proxy target chain
/// via the object's `is_proxy`/`is_array` flags with no VM state. Relocated to
/// engine core in Phase 6b-3 STEP 2; `exec/array_builtin_ops.zig` owns the
/// native record surface that re-exports it.
pub fn isArrayValue(value: JSValue) !bool {
    // Iterative proxy-chain walk with a depth cap, mirroring QuickJS
    // `js_resolve_proxy` (quickjs.c:51412-51434): a chain deeper than 1000 is a
    // stack overflow (InternalError), not a native recursion crash. A revoked
    // proxy (null handler) is a TypeError.
    var object = objectFromValue(value) orelse return false;
    var depth: usize = 0;
    while (object.isProxy()) {
        if (depth > 1000) return error.StackOverflow;
        depth += 1;
        if (object.proxyHandler() == null) return error.TypeError;
        const target = object.proxyTarget() orelse return error.TypeError;
        object = objectFromValue(target) orelse return false;
    }
    return object.isArray();
}

/// Coerce a value to an array `*Object` or fail with TypeError. Pure object
/// predicate (object shape + `is_array` flag); relocated to engine core in
/// Phase 6b-3 STEP 2 and re-exported from `exec/array_builtin_ops.zig`.
pub fn expectArray(value: JSValue) !*Object {
    const object = try expectObject(value);
    if (!object.isArray()) return error.TypeError;
    return object;
}

/// Construct a dense array from already-evaluated literal element `values` for
/// the `array_from`/array-literal opcode. Pure (only core `Object` array
/// primitives + descriptor ops), so it lives in engine core; `src/exec/vm_literal.zig`
/// calls it directly without naming `builtins`. Unlike the Array *constructor*
/// (`constructConstructorWithPrototype`) this never applies the single-number
/// length semantics — a one-element `[n]` literal yields `[n]`, not a length-n
/// hole array — so it is intentionally not routed through the Array construct
/// record.
///
/// GC rooting: the caller (`vm_literal.zig`) holds `values` in owned operand
/// storage (a stack buffer or heap `alloc`) for the whole call, and this
/// function only *borrows* them (each element is `dup()`-ed into the new array).
/// QuickJS relies on the same invariant — the array-literal opcodes build the
/// result while the source elements still sit on the VM operand stack, which
/// `[stack_buf, sp)` root scanning covers in place. We mirror that by
/// registering the borrowed `values` slice as a single `.mutable` root slice
/// (traced read-only by the non-moving cycle collector, runtime.zig:1265),
/// instead of the previous per-value `requiresRefCount` pre-scan + a rooted
/// dual-allocation copy. Immediate-only literals cost the same single
/// linked-list push as refcounted ones.
/// Hot-path array-literal constructor — the direct mirror of qjs
/// `OP_array_from`'s `js_create_array_free(ctx, argc, sp - argc)`
/// (quickjs.c:18239 -> 9625): allocate the array from the realm's prepared
/// initial Shape (`ctx->array_shape`) and MOVE the already-evaluated element
/// values into its dense storage — no per-element retain/release pair and no
/// root registration. qjs roots nothing here either: the elements sit on the
/// operand stack holding ordinary refcounts across the two allocations, and
/// the cycle collector derives its roots from external refcounts
/// (gc_decref/gc_scan — `destroyRuntimeCyclesWithValueRoots` ignores value
/// root frames entirely), so a mid-construction collection observes every
/// element as externally referenced. On success the values are consumed
/// (caller must NOT free them); on error they are untouched (the caller's
/// cold route re-runs the op or frees them, covering qjs's fail-path frees).
pub fn constructLiteralOwnedDenseFromShape(rt: *JSRuntime, values: []const JSValue, initial_shape: *shape_mod.Shape) !JSValue {
    // Frameless `op_array_from` does not `syncSp` before this allocation.
    // RC treats operand-stack refcounts as roots; STW must name the window.
    if (comptime runtime.value_root_frames_enabled) {
        var values_root: []JSValue = @constCast(values);
        var root_slices = [_]runtime.ValueRootSlice{.{ .mutable = &values_root }};
        var root_frame = runtime.ValueRootFrame{ .slices = &root_slices };
        root_frame.activate(rt);
        defer root_frame.deactivate(rt);
        return constructLiteralOwnedDenseFromShapeWork(rt, values, initial_shape);
    }
    return constructLiteralOwnedDenseFromShapeWork(rt, values, initial_shape);
}

inline fn constructLiteralOwnedDenseFromShapeWork(rt: *JSRuntime, values: []const JSValue, initial_shape: *shape_mod.Shape) !JSValue {
    const object = try Object.createArrayFromInitialShape(rt, initial_shape);
    errdefer Object.destroyFromHeader(rt, &object.header);
    try object.initDenseArrayLiteralValuesOwnedTrusted(rt, values);
    return object.value();
}

pub fn constructLiteralWithPrototype(rt: *JSRuntime, values: []const JSValue, prototype: ?*Object) !JSValue {
    // The backing storage is mutable (caller-owned stack/heap buffer); the
    // const on the borrow is a contract, not a guarantee the memory is
    // read-only. The GC visitor only reads these slots to keep referenced
    // objects marked, so registering them as a `.mutable` slice is sound.
    var values_root: []JSValue = @constCast(values);
    var root_slices = [_]runtime.ValueRootSlice{
        .{ .mutable = &values_root },
    };
    var root_frame = runtime.ValueRootFrame{
        .slices = &root_slices,
    };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const object = try Object.createArray(rt, prototype);
    errdefer Object.destroyFromHeader(rt, &object.header);

    if (try object.initDenseArrayLiteralValuesAssumingEmpty(rt, values)) return object.value();

    try object.reserveDenseArrayElements(rt, @intCast(values.len));
    for (values, 0..) |value, index| {
        const atom_id = atom.atomFromUInt32(@intCast(index));
        if (try object.appendDenseArrayLiteralIndex(rt, @intCast(index), value)) continue;
        try object.defineOwnProperty(rt, atom_id, Descriptor.data(value, true, true, true));
    }
    return object.value();
}

const std = @import("std");
