const std = @import("std");

const object = @import("object.zig");
const string = @import("string.zig");
const value_mod = @import("value.zig");

const JSValue = value_mod.JSValue;

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
