//! Core var-ref cell for closure captures.
//!
//! This is an internal GC node, not a JS Object. It mirrors QuickJS's
//! JSVarRef shape: an open ref aliases a live frame slot through `pvalue`;
//! when that frame is parked in a generator, `value` owns the generator that
//! owns the backing slot. A closed ref owns the binding value itself and
//! points `pvalue` at it.

const std = @import("std");
const builtin = @import("builtin");

const gc = @import("gc.zig");
const JSValue = @import("value.zig").JSValue;

pub const VarRef = struct {
    pub const gc_kind_tag: u8 = @intFromEnum(gc.GcKind.var_ref);
    header: gc.Header = .{},
    // Closed: the binding value. Open: the optional parked-frame owner.
    // QuickJS stores the async-function-state pointer in the open-cell union;
    // `value` is otherwise idle in this state, so it carries the equivalent
    // owned GC edge without widening VarRef.
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
        std.debug.assert(@sizeOf(VarRef) == 40);
        std.debug.assert(@alignOf(VarRef) == 8);
        const header_bytes = @sizeOf(gc.Header);
        std.debug.assert(@offsetOf(VarRef, "value") == header_bytes);
        std.debug.assert(@offsetOf(VarRef, "pvalue") == header_bytes + 16);
        std.debug.assert(@offsetOf(VarRef, "is_const") == header_bytes + 24);
        std.debug.assert(@offsetOf(VarRef, "is_open") == header_bytes + 28);
    }

    pub fn createClosed(rt: anytype, initial_value: JSValue) !*VarRef {
        const self = try rt.createRuntime(VarRef);
        errdefer rt.destroyRuntime(VarRef, self);
        self.* = .{
            .header = .{},
            .value = initial_value,
        };
        std.debug.assert(self.header.meta().flags.kind == .var_ref);
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
        std.debug.assert(self.header.meta().flags.kind == .var_ref);
        try rt.gc.addInitializedWithSize(&self.header, @sizeOf(VarRef));
        return self;
    }

    pub fn destroyFromHeader(rt: anytype, header: *gc.Header) void {
        const self: *VarRef = @alignCast(@fieldParentPtr("header", header));
        // Keep the struct alive for Pass B while other condemned carriers may
        // still hold raw cell pointers.
        if (rt.gc.phase == .tracer_destroy) {
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
    pub fn prepareForRuntimeDeinit(_: anytype, header: *gc.Header) void {
        const self: *VarRef = @alignCast(@fieldParentPtr("header", header));
        self.value = JSValue.undefinedValue();
        self.pvalue = &self.value;
        self.is_open = false;
    }

    pub fn valueRef(self: *VarRef) JSValue {
        return JSValue.object(&self.header);
    }

    pub fn fromValue(value: JSValue) ?*VarRef {
        const header = value.refHeader() orelse return null;
        if (header.meta().flags.kind != .var_ref) return null;
        return @alignCast(@fieldParentPtr("header", header));
    }

    /// Attach the GC owner of an open cell's parked frame.
    ///
    /// A running ordinary frame cannot participate in a removable cycle, so
    /// open cells start with no owner. Before a generator frame is parked, its
    /// object is retained here exactly once. This mirrors QuickJS get_var_ref's
    /// async_func retain and makes the open-cell edge `cell -> frame owner`,
    /// never the borrowed `cell -> *pvalue`.
    pub fn attachOpenOwner(self: *VarRef, rt: anytype, owner: JSValue) void {
        std.debug.assert(self.is_open);
        std.debug.assert(owner.isObject());
        if (!self.value.isUndefined()) {
            std.debug.assert(self.value.same(owner));
            return;
        }
        self.value = owner;
        // An open cell adopting its parked-frame owner is the same kind of
        // store as `close`: a traced object gaining an edge.
        rt.gc.generationalBarrier(&self.header, owner.cycleMarkHeader());
    }

    pub fn close(self: *VarRef, rt: anytype) void {
        if (!self.is_open) return;
        const closed_value = self.pvalue.*;
        self.value = closed_value;
        // Closing copies the binding out of the dying frame and into the cell,
        // which is a store into a traced object exactly like `setVarRefValue`
        // -- and the cell is typically the older of the two, since it outlives
        // the frame whose value it is capturing.
        rt.gc.generationalBarrier(&self.header, closed_value.cycleMarkHeader());
        self.pvalue = &self.value;
        self.is_open = false;
    }

    pub fn setVarRefValue(self: *VarRef, rt: anytype, next_value: JSValue) void {
        // Terminal-state invariant (VARREFS-SLOT-TYPING-BLUEPRINT risk 3): a
        // cell's VALUE is NEVER itself a cell — every write path unwraps an
        // incoming cell value first (replaceAdapterOwned / execPutVarRef),
        // and the direct-eval const view pvalue-ALIASES its target cell instead
        // (eval_ops.directEvalOuterVarRefView), so readers do qjs's bare
        // `*var_ref->pvalue` (quickjs.c:18627) with no chase. Debug-resident
        // so a regression that would silently corrupt the read fast path traps.
        if (comptime builtin.mode == .Debug) {
            std.debug.assert(fromValue(next_value) == null);
        }
        self.pvalue.* = next_value;
        // A closure cell is a traced object owning one value slot, so storing
        // a fresh value into a long-lived cell is an old-to-young edge the
        // minor cannot rediscover: its sticky marks stop the trace at the old
        // cell. `pvalue` may alias a frame slot rather than `value`, but the
        // owner recorded here is always the cell itself, which is what the
        // remembered set re-traces.
        rt.gc.generationalBarrier(&self.header, next_value.cycleMarkHeader());
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
