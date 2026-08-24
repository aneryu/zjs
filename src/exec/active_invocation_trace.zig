//! Exec-owned no-fail root walk for `JSRuntime.active_invocation`.
//!
//! Core only sees `ActiveInvocationTrace` at offset 0 of the published record
//! (tracing-gc-design.md §7.1). This module is imported solely when
//! `value_root_frames_enabled`; default `rc` never compiles it.
//!
//! Live windows only: typed Frame slices, Stack `top_ptr` prefix, VarRef
//! cells that are present, and Entry.native_caller when that slot is a
//! JSValue. Unused slab/stack capacity is not visited.

const std = @import("std");

const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const inline_calls = @import("inline_calls.zig");
const stack_mod = @import("stack.zig");

const RootTraceError = core.runtime.RootTraceError;
const RootVisitor = core.runtime.RootVisitor;

comptime {
    std.debug.assert(core.runtime.value_root_frames_enabled);
    std.debug.assert(@offsetOf(inline_calls.ActiveInvocation, "header") == 0);
}

pub fn traceRoots(invocation_ptr: *anyopaque, visitor: *RootVisitor) RootTraceError!void {
    var current: ?*inline_calls.ActiveInvocation = @ptrCast(@alignCast(invocation_ptr));
    while (current) |invocation| {
        try traceMachine(invocation.machine, visitor);
        current = invocation.previous;
    }
}

fn traceMachine(machine: *inline_calls.Machine, visitor: *RootVisitor) RootTraceError!void {
    const rt = machine.ctx.runtime;
    try traceFrame(rt, machine.l0.level.frame, visitor);
    try traceStack(machine.l0.level.stack, visitor);
    // A generator/module shell stays deliberately unpublished (off
    // gc_obj_list, not in the address registry) through parameter init
    // (`createGeneratorObject` -> `runGeneratorParameterInit` ->
    // `finishGeneratorShell`). The sweep cannot reach an unpublished
    // object, so the slot needs no root protection in that window — and
    // the shell's body (shape_ref) is not initialized yet, so tracing it
    // walks undefined memory (0xaa autopsy, 2026-08-24). Trace the slot
    // only once the object is published; `prev != null` is the linked
    // (published) predicate, and seedRoots never runs while sweep-side
    // detachment transiently unlinks live headers. The shell's children
    // are independently covered: the init sub-invocation's own
    // frame/stack windows are traced above.
    if (machine.l0.generator_state) |generator_state| {
        if (generator_state.header.prev != null) {
            try visitor.constOptionalObject(generator_state);
        }
    }

    var entry = machine.top;
    while (entry) |current| {
        try traceFrame(rt, &current.frame, visitor);
        try traceStack(&current.stack, visitor);
        try traceEntryExtras(current, visitor);
        entry = current.prev;
    }
}

fn traceFrame(rt: *core.JSRuntime, frame: *frame_mod.Frame, visitor: *RootVisitor) RootTraceError!void {
    try visitor.value(&frame.this_value);
    try visitor.value(&frame.current_function);
    // A fixture top-level Bytecode is stack-resident, not a gc object:
    // reporting it as an FB-tagged value would shade native stack memory
    // (mark-bit write into a Zig local) and then trace garbage. The address
    // registry is the published-gc-object oracle — the stack struct's
    // `header` bytes are uninitialized garbage, so no header-field predicate
    // is reliable here. Registry membership covers every published FB
    // (`addInitializedWithSizeNoFail` registers unconditionally in the
    // configs that compile this module).
    if (rt.gc.address_registry.containsHeader(&frame.function.header)) {
        var function_bytecode = core.JSValue.functionBytecode(@constCast(&frame.function.header));
        try visitor.value(&function_bytecode);
    }
    try visitor.values(frame.args);
    try visitor.values(frame.locals);
    if (frame.cold) |cold| {
        if (frame.ownership.new_target != .aliases_function) {
            try visitor.value(&cold.new_target);
        }
        try visitor.values(cold.original_args);
    }
    for (frame.var_refs) |cell| {
        var cell_value = cell.valueRef();
        try visitor.value(&cell_value);
    }
    for (frame.open_var_refs) |maybe_cell| {
        const cell = maybe_cell orelse continue;
        var cell_value = cell.valueRef();
        try visitor.value(&cell_value);
    }
}

fn traceStack(stack: *stack_mod.Stack, visitor: *RootVisitor) RootTraceError!void {
    try visitor.values(stack.liveValues());
    // The in-flight call's operands, which sit above `top_ptr` between the
    // region retreat and the frame push. See `Stack.pending_call_region`.
    const pending = stack_mod.pendingCallRegion();
    if (pending.len != 0) try visitor.values(pending);
}

fn traceEntryExtras(entry: *inline_calls.Entry, visitor: *RootVisitor) RootTraceError!void {
    if (entry.teardown.has_native_caller or entry.teardown.constructor_completion) {
        try visitor.value(&entry.native_caller);
    }
}
