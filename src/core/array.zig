//! Core array-index classification, Array identity checks, and literal construction.
//!
//! Index helpers are pure. Literal constructors either duplicate borrowed
//! values or explicitly consume already-owned operand values, as their names
//! and comments specify; temporary root slices cover allocating borrowed paths.
//! QuickJS map: `JS_AtomIsArrayIndex` at quickjs.c and `OP_array_from`
//! near quickjs.c. Exec owns Array builtins, while this lower-layer seam
//! may import core/libs only and never parser/exec/runtime/binding.

const atom = @import("atom.zig");
const JSValue = @import("value.zig").JSValue;
const Object = @import("object.zig").Object;
const JSRuntime = @import("../runtime.zig").JSRuntime;
const runtime = @import("../runtime.zig");
const value_semantics = @import("value_semantics.zig");
const Descriptor = @import("descriptor.zig").Descriptor;
const shape_mod = @import("shape.zig");

pub const max_array_index = atom.max_array_index;
pub const max_array_length: u32 = 0xffff_ffff;
/// 2^53 - 1: the largest length ToLength produces, and the bound the
/// generic Array methods check before growing an array-like.
pub const max_safe_length: usize = (1 << 53) - 1;

pub fn isArrayIndexName(bytes: []const u8) bool {
    return arrayIndexFromName(bytes) != null;
}

pub fn arrayIndexFromAtom(atoms: anytype, atom_id: atom.Atom) ?u32 {
    // Mirrors QuickJS JS_AtomIsArrayIndex: tagged integer
    // atoms are array indexes directly. zjs internString tags every
    // array-index-form decimal string <= atom.max_int_atom, so a non-tagged
    // atom shorter than the 10-digit high-index window cannot be an array index.
    if (atom_id.isTaggedInt()) {
        const index = atom_id.toUInt32();
        if (index <= max_array_index) return index;
        return null;
    }
    const name = atoms.name(atom_id) orelse return null;
    if (name.len < 10) return null;
    if (atoms.kind(atom_id) != .string) return null;
    return arrayIndexFromName(name);
}

pub const arrayIndexFromName = atom.parseHighArrayIndex;

const objectFromValue = value_semantics.objectFromValue;
const expectObject = value_semantics.expectObject;

/// Proxy-aware `Array.isArray` predicate. Pure: walks the proxy target chain
/// via the object's `is_proxy`/`is_array` flags with no VM state. Relocated to
/// engine core in Phase 6b-3 STEP 2; `exec/array_ops.zig` owns the
/// native record surface that re-exports it.
pub fn isArrayValue(value: JSValue) !bool {
    // Iterative proxy-chain walk with a depth cap, mirroring QuickJS
    // `js_resolve_proxy`: a chain deeper than 1000 is a
    // stack overflow (InternalError), not a native recursion crash. A revoked
    // proxy (null handler) is a TypeError.
    var object = objectFromValue(value) orelse return false;
    var depth: usize = 0;
    while (object.isProxy()) {
        if (depth > 1000) return error.StackOverflow;
        depth += 1;
        if (object.proxyHandler() == null) return error.RevokedProxy;
        const target = object.proxyTarget() orelse return error.RevokedProxy;
        object = objectFromValue(target) orelse return false;
    }
    return object.isArray();
}

/// Coerce a value to an array `*Object` or fail with TypeError.
pub fn expectArray(value: JSValue) !*Object {
    const object = try expectObject(value);
    if (!object.isArray()) return error.TypeError;
    return object;
}

/// Hot-path array-literal constructor for `array_from`: allocate the array
/// from the realm's initial array Shape and move the already-evaluated
/// element `values` into its dense storage. On success the values belong to
/// the array; on error they are untouched and still owned by the caller.
pub fn constructLiteralOwnedDenseFromShape(rt: *JSRuntime, values: []const JSValue, initial_shape: *shape_mod.Shape) !JSValue {
    // Frameless `op_array_from` does not `syncSp` before this allocation, so
    // the operand-stack values are not yet visible to tracing: name them.
    var values_root: []JSValue = @constCast(values);
    var root_slices = [_]runtime.ValueRootSlice{.{ .mutable = &values_root }};
    var root_frame = runtime.ValueRootFrame{ .slices = &root_slices };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);
    return constructLiteralOwnedDenseFromShapeWork(rt, values, initial_shape);
}

inline fn constructLiteralOwnedDenseFromShapeWork(rt: *JSRuntime, values: []const JSValue, initial_shape: *shape_mod.Shape) !JSValue {
    const object = try Object.createArrayFromInitialShape(rt, initial_shape);
    errdefer Object.destroyFromHeader(rt, object.gcHeader());
    try object.initDenseArrayLiteralValuesOwnedTrusted(rt, values);
    return object.value();
}

/// Construct a dense array from literal element `values` with `prototype`.
/// Unlike the Array constructor this never applies the single-number length
/// semantics: a one-element `[n]` literal yields `[n]`. `values` are
/// borrowed and rooted for the call.
pub fn constructLiteralWithPrototype(rt: *JSRuntime, values: []const JSValue, prototype: ?*Object) !JSValue {
    // The backing storage is mutable (caller-owned stack/heap buffer); the
    // const on the borrow is a contract, not a guarantee the memory is
    // read-only. The GC visitor only reads these slots to keep referenced
    // objects marked, so registering them as a `.mutable` slice is sound.
    var values_root: []JSValue = @constCast(values);
    var root_slices = [_]runtime.ValueRootSlice{
        .{ .mutable = &values_root },
    };
    // Keep the newly allocated array alive while allocating its element
    // storage. The input slice and the output are independent GC roots.
    var array_value = JSValue.undefinedValue();
    var root_values = [_]*JSValue{&array_value};
    var root_frame = runtime.ValueRootFrame{
        .slices = &root_slices,
        .values = &root_values,
    };
    root_frame.activate(rt);
    defer root_frame.deactivate(rt);

    const object = try Object.createArray(rt, prototype);
    array_value = object.value();
    errdefer Object.destroyFromHeader(rt, object.gcHeader());

    if (try object.initDenseArrayLiteralValuesAssumingEmpty(rt, values)) return object.value();

    try object.reserveDenseArrayElements(rt, @intCast(values.len));
    for (values, 0..) |value, index| {
        const atom_id = atom.Atom.taggedInt(@intCast(index));
        if (try object.appendDenseArrayLiteralIndex(rt, @intCast(index), value)) continue;
        try object.defineOwnProperty(rt, atom_id, Descriptor.data(value, .all));
    }
    return object.value();
}

const std = @import("std");

test "array index detection handles QuickJS boundaries" {
    try std.testing.expect(isArrayIndexName("0"));
    try std.testing.expect(isArrayIndexName("4294967294"));
    try std.testing.expect(!isArrayIndexName("4294967295"));
    try std.testing.expect(!isArrayIndexName("01"));
    try std.testing.expect(!isArrayIndexName("-1"));
}
