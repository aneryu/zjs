//! Core var-ref cell for closure captures.
//!
//! This is an internal GC node, not a JS Object. It mirrors QuickJS's
//! JSVarRef shape: an open ref aliases a live frame slot through `pvalue`;
//! a closed ref owns `value` and points `pvalue` at it.

const std = @import("std");
const builtin = @import("builtin");

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
    // qjs has no per-cell deleted flag: deleting a captured binding parks the
    // cell's value at UNINITIALIZED (remove_global_object_property,
    // quickjs.c:9289-9309); deletable-ness itself is a zjs bookkeeping bit for
    // eval-created bindings (qjs encodes it as the property's CONFIGURABLE flag).
    is_deletable: bool = false,
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
        std.debug.assert(self.header.meta().kind == .var_ref);
        self.pvalue = &self.value;
        try rt.gc.addInitializedWithSize(&self.header, @sizeOf(VarRef));
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
        std.debug.assert(self.header.meta().kind == .var_ref);
        try rt.gc.addInitializedWithSize(&self.header, @sizeOf(VarRef));
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

    /// Runtime teardown keeps VarRef structs alive until objects and bytecode
    /// have released their cell pointers. Drop the cell-owned value first,
    /// while every referenced GC object is still structurally valid.
    pub fn prepareForRuntimeDeinit(rt: anytype, header: *gc.Header) void {
        const self: *VarRef = @alignCast(@fieldParentPtr("header", header));
        if (!self.is_open) {
            const old_value = self.value;
            self.value = JSValue.undefinedValue();
            self.pvalue = &self.value;
            old_value.free(rt);
        } else {
            // A surviving open cell may point into a frame that has already
            // unwound. It never owns that slot's value.
            self.value = JSValue.undefinedValue();
            self.pvalue = &self.value;
            self.is_open = false;
        }
    }

    pub fn valueRef(self: *VarRef) JSValue {
        return JSValue.object(&self.header);
    }

    pub fn fromValue(value: JSValue) ?*VarRef {
        const header = value.refHeader() orelse return null;
        if (header.meta().kind != .var_ref) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// Slot-typed retain: rc++ on the cell and return it — the qjs
    /// `JSVarRef*` copy `js_rc(var_ref)->ref_count++` (js_closure2,
    /// quickjs.c:17322-17324). Routed through `valueRef().dup()` so the
    /// refcount/profiling behavior is bit-identical to the pre-typed
    /// `slot.dup()` on the cell's JSValue form.
    pub inline fn dupCell(self: *VarRef) *VarRef {
        _ = self.valueRef().dup();
        return self;
    }

    /// Slot-typed release — qjs `free_var_ref` (quickjs.c:16199): rc--,
    /// destroy at 0. Routed through `valueRef().free(rt)` so the deinit-phase
    /// and cycle-removal gates of the JSValue path apply unchanged.
    pub inline fn freeCell(self: *VarRef, rt: anytype) void {
        self.valueRef().free(rt);
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
        // Terminal-state invariant (VARREFS-SLOT-TYPING-BLUEPRINT risk 3): a
        // cell's VALUE is NEVER itself a cell — every write path unwraps an
        // incoming cell value first (setSlotValueRefCounted / execPutVarRef),
        // and the direct-eval const view pvalue-ALIASES its target cell instead
        // (eval_ops.directEvalOuterVarRefView), so readers do qjs's bare
        // `*var_ref->pvalue` (quickjs.c:18627) with no chase. Debug-resident
        // so a regression that would silently corrupt the read fast path traps.
        if (comptime builtin.mode == .Debug) {
            std.debug.assert(fromValue(next_value) == null);
        }
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
};
