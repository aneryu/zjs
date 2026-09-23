//! Shared root tracing protocol used by GC implementations and root providers.
//!
//! This module defines how a collector visits root slots. Runtime root-frame
//! activation and root-set ownership stay with `runtime.zig` and `roots.zig`.

const std = @import("std");
const atom = @import("atom.zig");
const gc = @import("gc.zig");
const module = @import("module.zig");
const Object = @import("object.zig").Object;
const shape = @import("shape.zig");
const string = @import("string.zig");
const JSValue = @import("value.zig").JSValue;
pub const value_root_frames_enabled = true;

pub const RootTraceError = std.mem.Allocator.Error || error{PayloadMarkFailed};

pub const RootVisitor = struct {
    context: *anyopaque,
    visit_value: *const fn (context: *anyopaque, slot: *JSValue) RootTraceError!void,
    visit_object: *const fn (context: *anyopaque, slot: *?*Object) RootTraceError!void,
    /// Direct GC headers (Shape, Module, VarRef, FunctionBytecode, realm).
    /// Void in default `rc` so RootVisitor constructions stay two callbacks.
    visit_header: if (value_root_frames_enabled)
        ?*const fn (context: *anyopaque, header: *const gc.Header) RootTraceError!void
    else
        void = if (value_root_frames_enabled) null else {},
    /// Atom ids are bare `u32`s, so roots holding them have no value or header
    /// to report; this callback is optional for visitors without atom tracing.
    visit_atom: if (value_root_frames_enabled)
        ?*const fn (context: *anyopaque, id: atom.Atom) RootTraceError!void
    else
        void = if (value_root_frames_enabled) null else {},

    pub fn value(self: *RootVisitor, slot: *JSValue) RootTraceError!void {
        try self.visit_value(self.context, slot);
    }

    pub fn values(self: *RootVisitor, slots: []JSValue) RootTraceError!void {
        for (slots) |*slot| try self.value(slot);
    }

    pub fn constValue(self: *RootVisitor, stored: JSValue) RootTraceError!void {
        var slot = stored;
        try self.value(&slot);
    }

    /// A cache slot that holds a bare `*String` rather than a `JSValue`.
    /// Round-trip through a value so a relocating visitor can update the slot.
    pub fn stringSlot(self: *RootVisitor, slot: *?*string.String) RootTraceError!void {
        const stored = slot.* orelse return;
        var boxed = JSValue.string(stored.header());
        try self.value(&boxed);
        slot.* = boxed.asStringBodyRaw();
    }

    /// Same contract for a slot whose `*String` sits inside a cache record.
    pub fn stringField(self: *RootVisitor, slot: *(*string.String)) RootTraceError!void {
        var boxed = JSValue.string(slot.*.header());
        try self.value(&boxed);
        if (boxed.asStringBodyRaw()) |moved| slot.* = moved;
    }

    pub fn constValues(self: *RootVisitor, stored: []const JSValue) RootTraceError!void {
        for (stored) |stored_value| try self.constValue(stored_value);
    }

    pub fn optionalObject(self: *RootVisitor, slot: *?*Object) RootTraceError!void {
        try self.visit_object(self.context, slot);
    }

    pub fn constOptionalObject(self: *RootVisitor, stored: ?*Object) RootTraceError!void {
        var slot = stored;
        try self.optionalObject(&slot);
    }

    pub fn constHeader(self: *RootVisitor, header: *const gc.Header) RootTraceError!void {
        if (comptime value_root_frames_enabled) {
            const callback = self.visit_header orelse return;
            try callback(self.context, header);
        }
    }

    /// No-op unless the visitor is a tracer that owns atom liveness.
    pub fn atomRoot(self: *RootVisitor, id: atom.Atom) RootTraceError!void {
        if (comptime value_root_frames_enabled) {
            const callback = self.visit_atom orelse return;
            try callback(self.context, id);
        }
    }

    pub fn shapeRoot(self: *RootVisitor, stored: *shape.Shape) RootTraceError!void {
        try self.constHeader(&stored.header);
    }

    pub fn moduleRoot(self: *RootVisitor, stored: *module.ModuleRecord) RootTraceError!void {
        try self.constHeader(&stored.header);
    }
};
