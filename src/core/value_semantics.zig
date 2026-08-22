//! Ownership-neutral predicates and conversions over the tagged JSValue model.
//!
//! These helpers neither retain nor release inputs. Checked object conversion
//! rejects VarRef cell wrappers that share the object tag; the trusted
//! expression form relies on compiler stack discipline and keeps that proof as
//! a Debug assertion. QuickJS analogue: `JS_VALUE_GET_OBJ` and ToBoolean paths
//! around quickjs.c:19123. This core leaf may import core only and never any
//! parser/exec/runtime/binding layer.

const std = @import("std");
const builtin = @import("builtin");

const object = @import("object.zig");
const string = @import("string.zig");
const value_mod = @import("value.zig");

const JSValue = value_mod.JSValue;

/// Authoritative JSValue → *Object conversion. The `kind != .object` re-check
/// is load-bearing: zjs wraps VarRef cells in the SAME object tag
/// (VarRef.valueRef) for the JSValue-typed cell domains (eval name tables,
/// property cells, make_ref pairs) — a discrimination qjs never needs since
/// its JSVarRef* stays typed. Feeding a cell wrapper to a converter without
/// this check yields a misaligned `@fieldParentPtr` (type confusion), so
/// every conversion site must either call this checked form or the
/// `TrustedExpression` variant below with its documented precondition.
pub fn objectFromValue(value: JSValue) ?*object.Object {
    if (!value.isObject()) return null;
    const header = value.refHeader() orelse return null;
    if (header.meta().flags.kind != .object) return null;
    return @fieldParentPtr("header", header);
}

/// Expression-receiver variant — qjs JS_VALUE_GET_OBJ: tag test then raw
/// pointer cast, no second header-kind probe (GET_FIELD_INLINE,
/// quickjs.c:19123-19125; OP_put_field, 19190-19192). Precondition: the value
/// is an evaluated EXPRESSION value (popped operand, argument, property
/// read result). The only handler that pushes a cell wrapper onto the operand
/// stack is h_make_slot_ref (make_loc_ref/make_arg_ref/make_var_ref_ref), and
/// the parser consumes that ref pair exclusively through get_ref_value /
/// put_ref_value, which unwrap the cell before any value flows on (the same
/// trusted-compiler stack discipline that lets get_loc skip bounds checks).
/// So the kind re-load is dead on this path; Debug keeps it as an assert.
pub inline fn objectFromValueTrustedExpression(value: JSValue) ?*object.Object {
    if (!value.isObject()) return null;
    const header = value.refHeaderAssumeObject();
    if (comptime builtin.mode == .Debug) {
        std.debug.assert(header.meta().flags.kind == .object);
    }
    return @fieldParentPtr("header", header);
}

/// Checked conversion with the canonical error contract.
pub fn expectObject(value: JSValue) error{TypeError}!*object.Object {
    return objectFromValue(value) orelse error.TypeError;
}

pub fn toBoolean(value: JSValue) bool {
    if (isHTMLDDA(value)) return false;
    if (value.isUndefined() or value.isNull()) return false;
    if (value.asBool()) |bool_value| return bool_value;
    if (value.asInt32()) |int_value| return int_value != 0;
    if (value.asFloat64()) |float_value| return float_value != 0 and !std.math.isNan(float_value);
    if (value.isBigInt()) {
        return !(value_mod.isZeroBigInt(value) orelse return true);
    }
    if (value.isString()) {
        const string_value = value.asStringBody() orelse return false;
        return string_value.len() != 0;
    }
    return true;
}

pub fn isHTMLDDA(value: JSValue) bool {
    if (!value.isObject()) return false;
    const header = value.refHeader() orelse return false;
    const object_value: *object.Object = @fieldParentPtr("header", header);
    return object_value.flags.is_html_dda;
}
