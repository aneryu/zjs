//! Cold execution bookkeeping: resident host invocation, stored backtrace,
//! and small-inline hooks.
//!
//! `hot` and `vm_stack` stay on `JSRuntime` at their aligned offsets. The
//! three live pointers stay distinct and are restored by their own callers:
//! `active_invocation` for the bytecode entry, `host_invocation` for the
//! resident executor, `active_native_call` for the native environment.
//! Opcode profile and diagnostics stay off `HotExecState`.

const mem_ops = @import("memory.zig");
const std = @import("std");
const atom = @import("atom.zig");
const context_mod = @import("context.zig");
const runtime_mod = @import("runtime.zig");
const JSRuntime = runtime_mod.JSRuntime;
const JSValue = @import("value.zig").JSValue;

const BacktraceFrame = context_mod.BacktraceFrame;
const ActiveBacktraceFrame = context_mod.ActiveBacktraceFrame;

pub const SmallInlineDestroy = *const fn (rt: *JSRuntime, fb: *anyopaque) void;
pub const SmallInlineTraceAtoms = *const fn (
    rt: *JSRuntime,
    fb: *anyopaque,
    ctx: *anyopaque,
    visit: *const fn (ctx: *anyopaque, id: atom.Atom) void,
) void;

/// Retire the resident executor. Destroy calls this before `vm_stack.deinit`.
pub fn retireHostInvocation(rt: *JSRuntime) void {
    const host_invocation = rt.host_invocation orelse return;
    const retire = rt.host_invocation_retire.?;
    rt.host_invocation = null;
    rt.host_invocation_retire = null;
    retire(rt, host_invocation);
}

pub fn releaseStoredBacktrace(rt: *JSRuntime) void {
    const frames = rt.backtrace_frames;
    const capacity = rt.backtrace_capacity;
    rt.backtrace_frames = &.{};
    rt.backtrace_capacity = 0;
    if (capacity != 0) mem_ops.free(rt, BacktraceFrame, frames.ptr[0..capacity]);
}

pub fn appendStoredBacktrace(rt: *JSRuntime, frame: BacktraceFrame) !void {
    if (rt.backtrace_frames.len == rt.backtrace_capacity) {
        var next_capacity: usize = if (rt.backtrace_capacity == 0) 16 else rt.backtrace_capacity * 2;
        if (next_capacity < rt.backtrace_frames.len + 1) next_capacity = rt.backtrace_frames.len + 1;
        const next = try mem_ops.alloc(rt, BacktraceFrame, next_capacity);
        const old_frames = rt.backtrace_frames;
        const old_capacity = rt.backtrace_capacity;
        @memcpy(next[0..old_frames.len], old_frames);
        rt.backtrace_frames = next[0..old_frames.len];
        rt.backtrace_capacity = next_capacity;
        if (old_capacity != 0) mem_ops.free(rt, BacktraceFrame, old_frames.ptr[0..old_capacity]);
    }
    rt.backtrace_frames.ptr[rt.backtrace_frames.len] = frame;
    rt.backtrace_frames = rt.backtrace_frames.ptr[0 .. rt.backtrace_frames.len + 1];
}

pub fn popStoredBacktrace(rt: *JSRuntime) void {
    if (rt.backtrace_frames.len == 0) return;
    rt.backtrace_frames = rt.backtrace_frames.ptr[0 .. rt.backtrace_frames.len - 1];
}

pub fn setStoredBacktracePc(rt: *JSRuntime, pc: usize) void {
    if (rt.backtrace_frames.len == 0) return;
    const idx = rt.backtrace_frames.len - 1;
    rt.backtrace_frames[idx].pc_source = null;
    rt.backtrace_frames[idx].pc = pc;
}

pub fn borrowStoredBacktracePc(rt: *JSRuntime, pc_source: *const usize) void {
    if (rt.backtrace_frames.len == 0) return;
    rt.backtrace_frames[rt.backtrace_frames.len - 1].pc_source = pc_source;
}

pub fn setStoredBacktraceLocation(rt: *JSRuntime, pc: usize, line_num: i32, col_num: i32) void {
    if (rt.backtrace_frames.len == 0) return;
    const idx = rt.backtrace_frames.len - 1;
    rt.backtrace_frames[idx].pc_source = null;
    rt.backtrace_frames[idx].pc = pc;
    rt.backtrace_frames[idx].line_num = line_num;
    rt.backtrace_frames[idx].col_num = col_num;
}

pub fn linkActiveBacktrace(rt: *JSRuntime, frame: *ActiveBacktraceFrame) void {
    frame.previous = rt.hot.current_backtrace_frame;
    rt.hot.current_backtrace_frame = frame;
}

pub fn unlinkActiveBacktrace(rt: *JSRuntime, frame: *ActiveBacktraceFrame) void {
    std.debug.assert(rt.hot.current_backtrace_frame == frame);
    rt.hot.current_backtrace_frame = frame.previous;
    frame.previous = null;
}

pub fn installSmallInlineHooks(rt: *JSRuntime, destroy_hook: SmallInlineDestroy, trace_hook: SmallInlineTraceAtoms) void {
    if (rt.small_inline_destroy == null) rt.small_inline_destroy = destroy_hook;
    if (rt.small_inline_trace_atoms == null) rt.small_inline_trace_atoms = trace_hook;
}

pub fn addSmallInlinePublished(rt: *JSRuntime, bytes: usize) void {
    rt.small_inline_published_bytes +|= bytes;
}

pub fn addSmallInlineSpecialized(rt: *JSRuntime, bytes: usize) void {
    rt.small_inline_specialized_bytes +|= bytes;
}

pub fn storedFunctionValue(value: JSValue) JSValue {
    return if (value.is(.object)) value else JSValue.undefinedValue();
}

comptime {
    const Hot = JSRuntime.HotExecState;
    std.debug.assert(@sizeOf(Hot) == 64);
    std.debug.assert(@hasField(Hot, "current_backtrace_frame"));
    std.debug.assert(!@hasField(Hot, "active_invocation"));
    std.debug.assert(!@hasField(Hot, "host_invocation"));
    std.debug.assert(!@hasField(Hot, "active_native_call"));
    std.debug.assert(!@hasField(Hot, "opcode_profile"));
    std.debug.assert(!@hasField(Hot, "diagnostics"));
}
