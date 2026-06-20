//! Core var-ref cell for closure captures.
//!
//! This is an internal GC node, not a JS Object. It mirrors QuickJS's
//! JSVarRef shape: an open ref aliases a live frame slot through `pvalue`;
//! a closed ref owns `value` and points `pvalue` at it.

const std = @import("std");

const gc = @import("gc.zig");
const JSValue = @import("value.zig").JSValue;

pub const VarRef = struct {
    header: gc.Header = .{ .kind = .var_ref },
    value: JSValue = JSValue.undefinedValue(),
    pvalue: *JSValue = undefined,
    next_open: ?*VarRef = null,
    is_const: bool = false,
    is_function_name: bool = false,
    is_deletable: bool = false,
    is_deleted: bool = false,
    is_open: bool = false,

    comptime {
        std.debug.assert(@offsetOf(VarRef, "header") == 0);
    }

    pub fn createClosed(rt: anytype, initial_value: JSValue) !*VarRef {
        const self = try rt.createRuntime(VarRef);
        errdefer rt.destroyRuntime(VarRef, self);
        self.* = .{
            .header = .{ .kind = .var_ref },
            .value = initial_value,
        };
        self.pvalue = &self.value;
        try rt.gc.addWithSize(&self.header, @sizeOf(VarRef));
        return self;
    }

    pub fn createOpen(rt: anytype, slot: *JSValue) !*VarRef {
        const self = try rt.createRuntime(VarRef);
        errdefer rt.destroyRuntime(VarRef, self);
        self.* = .{
            .header = .{ .kind = .var_ref },
            .value = JSValue.undefinedValue(),
            .pvalue = slot,
            .is_open = true,
        };
        try rt.gc.addWithSize(&self.header, @sizeOf(VarRef));
        return self;
    }

    pub fn destroyFromHeader(rt: anytype, header: *gc.Header) void {
        const self: *VarRef = @alignCast(@fieldParentPtr("header", header));
        if (!self.is_open) self.value.free(rt);
        rt.destroyRuntime(VarRef, self);
    }

    pub fn valueRef(self: *VarRef) JSValue {
        return JSValue.object(&self.header);
    }

    pub fn fromValue(value: JSValue) ?*VarRef {
        const header = value.refHeader() orelse return null;
        if (header.kind != .var_ref) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    pub fn close(self: *VarRef, rt: anytype) void {
        if (!self.is_open) return;
        const closed_value = self.pvalue.*.dup();
        self.value = closed_value;
        self.pvalue = &self.value;
        self.next_open = null;
        self.is_open = false;
        _ = rt;
    }

    pub fn setVarRefValue(self: *VarRef, rt: anytype, next_value: JSValue) !void {
        errdefer next_value.free(rt);
        const old_value = self.pvalue.*;
        self.pvalue.* = next_value;
        old_value.free(rt);
    }

    pub fn varRefValueSlot(self: *VarRef) *JSValue {
        return self.pvalue;
    }

    pub fn varRefValue(self: *const VarRef) JSValue {
        return self.pvalue.*;
    }

    pub fn varRefIsConstSlot(self: *VarRef) *bool {
        return &self.is_const;
    }

    pub fn varRefIsFunctionNameSlot(self: *VarRef) *bool {
        return &self.is_function_name;
    }

    pub fn varRefIsDeletableSlot(self: *VarRef) *bool {
        return &self.is_deletable;
    }

    pub fn varRefIsDeletedSlot(self: *VarRef) *bool {
        return &self.is_deleted;
    }
};
