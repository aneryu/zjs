//! Core var-ref cell for closure captures.
//!
//! This is an internal GC node, not a JS Object. It mirrors QuickJS's
//! JSVarRef shape: an open ref aliases a live frame slot through `pvalue`;
//! a closed ref owns `value` and points `pvalue` at it.

const std = @import("std");

const gc = @import("gc.zig");
const JSValue = @import("value.zig").JSValue;

pub const VarRef = struct {
    pub const gc_kind_tag: u8 = @intFromEnum(gc.GcKind.var_ref);
    header: gc.Header = .{},
    value: JSValue = JSValue.undefinedValue(),
    pvalue: *JSValue = undefined,
    is_const: bool = false,
    // QuickJS JSVarRef.is_lexical (quickjs.c:453) — only meaningful for
    // top-level global lexical bindings; gates TDZ-throw on read.
    is_lexical: bool = false,
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
            .header = .{},
            .value = initial_value,
        };
        self.header.meta().* = .{ .kind = .var_ref };
        self.pvalue = &self.value;
        try rt.gc.addWithSize(&self.header, @sizeOf(VarRef));
        return self;
    }

    pub fn createOpen(rt: anytype, slot: *JSValue) !*VarRef {
        const self = try rt.createRuntime(VarRef);
        errdefer rt.destroyRuntime(VarRef, self);
        self.* = .{
            .header = .{},
            .value = JSValue.undefinedValue(),
            .pvalue = slot,
            .is_open = true,
        };
        self.header.meta().* = .{ .kind = .var_ref };
        try rt.gc.addWithSize(&self.header, @sizeOf(VarRef));
        return self;
    }

    pub fn destroyFromHeader(rt: anytype, header: *gc.Header) void {
        const self: *VarRef = @alignCast(@fieldParentPtr("header", header));
        if (!self.is_open) self.value.free(rt);
        // Cycle removal: keep the struct alive for the Pass-B drain so a sibling
        // still decref-ing this var_ref does not read freed memory (qjs defers
        // non-value GC types to gc_zero_ref_count_list, quickjs.c:6790).
        if (rt.gc.phase == .remove_cycles) {
            rt.gc.deferCycleStructFree(header);
            return;
        }
        rt.destroyRuntime(VarRef, self);
    }

    pub fn freeCycleDeferredStruct(rt: anytype, header: *gc.Header) void {
        const self: *VarRef = @alignCast(@fieldParentPtr("header", header));
        rt.destroyRuntime(VarRef, self);
    }

    pub fn valueRef(self: *VarRef) JSValue {
        return JSValue.object(&self.header);
    }

    pub fn fromValue(value: JSValue) ?*VarRef {
        const header = value.refHeader() orelse return null;
        if (header.meta().kind != .var_ref) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    pub fn close(self: *VarRef, rt: anytype) void {
        if (!self.is_open) return;
        const closed_value = self.pvalue.*.dup();
        self.value = closed_value;
        self.pvalue = &self.value;
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
