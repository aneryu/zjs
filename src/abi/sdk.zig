//! Minimal typed thunk / descriptor generator skeleton (FN-M0I; design §23).
//!
//! The Zig SDK's job at full size (§23.2): from a plugin author's natural
//! Zig function, generate the C-ABI entry thunk, the machine signature id,
//! the marshal policy id, and the export descriptor — with compile errors
//! for anything outside the fast contract (§23.3). This file is the M0I
//! skeleton of that pipeline: the leaf numeric subset (arity <= 2 over
//! i32/f64/void), enough to prove the whole chain
//!     Zig fn -> signature id -> C thunk -> FunFunctionDescriptorV1
//!     -> NativeCallPlanSpec (one validation path) -> callable target.
//! Buffer/state/self/managed/async shapes are FN-M1A+ scope and must be
//! added HERE, against the same schema — never as a parallel table.
//!
//! Placement note: the SDK ships to plugin authors through fun; it lives
//! next to the schema because the schema is the single source of truth and
//! fun consumes zjs as a dependency. Relocation (if any) is an FN-M3
//! packaging decision, not a schema event.

const std = @import("std");
const abi = @import("fun_native_abi.zig");

fn sigIdByName(comptime name: []const u8) abi.FunSignatureId {
    return comptime blk: {
        for (abi.signatures) |s| {
            if (std.mem.eql(u8, s.name, name)) break :blk s.id;
        }
        @compileError("unknown signature name: " ++ name);
    };
}

/// Compile-time mapping from a Zig function type to the v1 signature id.
/// Only the leaf numeric subset is recognized in the M0I skeleton; anything
/// else is a §23.3 compile error, never a silent generic fallback (§23.4).
pub fn signatureIdFor(comptime F: type) abi.FunSignatureId {
    const info = @typeInfo(F).@"fn";
    const R = info.return_type.?;
    const params = info.params;
    if (params.len == 0 and R == void) return sigIdByName("VOID_TO_VOID");
    if (params.len == 1 and params[0].type.? == i32 and R == i32) return sigIdByName("I32_TO_I32");
    if (params.len == 2 and params[0].type.? == i32 and params[1].type.? == i32 and R == i32)
        return sigIdByName("I32_I32_TO_I32");
    if (params.len == 1 and params[0].type.? == f64 and R == f64) return sigIdByName("F64_TO_F64");
    if (params.len == 2 and params[0].type.? == f64 and params[1].type.? == f64 and R == f64)
        return sigIdByName("F64_F64_TO_F64");
    if (params.len == 1 and params[0].type.? == f64 and R == void) return sigIdByName("F64_TO_VOID");
    @compileError("fun SDK (M0I skeleton): unsupported leaf signature " ++ @typeName(F) ++
        " — the v1 leaf subset here is arity<=2 over i32/f64/void; buffer/state/self/" ++
        "managed/async shapes land with FN-M1A (design §23.3: fail the build, " ++
        "never auto-degrade to a generic entry)");
}

/// Generates the C-callconv leaf entry for a natural Zig function plus its
/// v1 function descriptor. Usage:
///     const Add = LeafExport(add);
///     const desc = Add.descriptor();
pub fn LeafExport(comptime func: anytype) type {
    const F = @TypeOf(func);
    const info = @typeInfo(F).@"fn";
    const R = info.return_type.?;
    return struct {
        pub const signature_id: abi.FunSignatureId = signatureIdFor(F);

        /// The exact C prototype for this signature; zjs casts the stored
        /// FunNativeCodePtr back to this type before calling (§12.1).
        pub const Prototype = switch (info.params.len) {
            0 => *const fn () callconv(.c) R,
            1 => *const fn (info.params[0].type.?) callconv(.c) R,
            2 => *const fn (info.params[0].type.?, info.params[1].type.?) callconv(.c) R,
            else => unreachable, // signatureIdFor already rejected it
        };

        pub const thunk: Prototype = switch (info.params.len) {
            0 => &struct {
                fn call() callconv(.c) R {
                    return func();
                }
            }.call,
            1 => &struct {
                fn call(a: info.params[0].type.?) callconv(.c) R {
                    return func(a);
                }
            }.call,
            2 => &struct {
                fn call(a: info.params[0].type.?, b: info.params[1].type.?) callconv(.c) R {
                    return func(a, b);
                }
            }.call,
            else => unreachable,
        };

        pub fn descriptor() abi.FunFunctionDescriptorV1 {
            return .{
                .struct_size = @sizeOf(abi.FunFunctionDescriptorV1),
                .call_kind = abi.call_kind.leaf_static,
                .signature = signature_id,
                .marshal_policy = abi.marshal_policy.canonical,
                .reserved0 = 0,
                .flags = 0,
                .target = @ptrCast(thunk),
            };
        }
    };
}

// ---- tests -----------------------------------------------------------------

const plan = @import("../binding/native_call_plan.zig");

fn add(a: i32, b: i32) i32 {
    return a +% b;
}

fn halve(x: f64) f64 {
    return x / 2.0;
}

test "SDK skeleton: Zig fn -> signature id" {
    try std.testing.expectEqual(@as(abi.FunSignatureId, 3), signatureIdFor(@TypeOf(add)));
    try std.testing.expectEqual(@as(abi.FunSignatureId, 4), signatureIdFor(@TypeOf(halve)));
}

test "SDK skeleton: descriptor round-trips through the single validation path and the target is callable" {
    const Add = LeafExport(add);
    const desc = Add.descriptor();
    const spec = try plan.NativeCallPlanSpec.fromFunctionDescriptor(&desc);
    try std.testing.expectEqual(abi.call_kind.leaf_static, spec.call_kind);
    try std.testing.expectEqual(Add.signature_id, spec.signature);

    // §12.1: the engine casts the generic code pointer back to the exact
    // descriptor-declared prototype before calling.
    const target: Add.Prototype = @ptrCast(desc.target.?);
    try std.testing.expectEqual(@as(i32, 5), target(2, 3));

    const Halve = LeafExport(halve);
    const hdesc = Halve.descriptor();
    _ = try plan.NativeCallPlanSpec.fromFunctionDescriptor(&hdesc);
    const htarget: Halve.Prototype = @ptrCast(hdesc.target.?);
    try std.testing.expectEqual(@as(f64, 4.5), htarget(9.0));
}
