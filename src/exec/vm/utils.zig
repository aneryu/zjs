const std = @import("std");
const core = @import("../../core/root.zig");
const frame_mod = @import("../frame.zig");
const stack_mod = @import("../stack.zig");

pub fn ensureLocalsCapacity(ctx: *core.JSContext, frame: *frame_mod.Frame, idx: usize) !void {
    if (idx < frame.locals.len and idx < frame.locals_uninit.len) return;
    const next_len = @max(idx + 1, @max(frame.locals.len, frame.locals_uninit.len));

    const next_locals = try ctx.runtime.memory.alloc(core.JSValue, next_len);
    errdefer ctx.runtime.memory.free(core.JSValue, next_locals);
    const next_uninit = try ctx.runtime.memory.alloc(bool, next_len);
    errdefer ctx.runtime.memory.free(bool, next_uninit);

    for (frame.locals, 0..) |value, i| next_locals[i] = value;
    if (next_len > frame.locals.len) @memset(next_locals[frame.locals.len..next_len], core.JSValue.undefinedValue());
    for (frame.locals_uninit, 0..) |value, i| next_uninit[i] = value;
    if (next_len > frame.locals_uninit.len) @memset(next_uninit[frame.locals_uninit.len..next_len], false);

    const old_locals = frame.locals;
    const old_locals_uninit = frame.locals_uninit;
    frame.locals = next_locals;
    frame.locals_uninit = next_uninit;
    if (old_locals.len != 0) ctx.runtime.memory.free(core.JSValue, old_locals);
    if (old_locals_uninit.len != 0) ctx.runtime.memory.free(bool, old_locals_uninit);
}

pub fn ensureVarRefsCapacity(ctx: *core.JSContext, frame: *frame_mod.Frame, idx: usize) !void {
    if (idx < frame.var_refs.len) return;
    const next_len = idx + 1;
    const next = try ctx.runtime.memory.alloc(core.JSValue, next_len);
    errdefer ctx.runtime.memory.free(core.JSValue, next);
    for (frame.var_refs, 0..) |value, i| next[i] = value;
    @memset(next[frame.var_refs.len..next_len], core.JSValue.undefinedValue());
    const old_var_refs = frame.var_refs;
    frame.var_refs = next;
    if (old_var_refs.len != 0) ctx.runtime.memory.free(core.JSValue, old_var_refs);
}

pub fn catchTargetFromMarker(marker: core.JSValue) ?usize {
    const previous = marker.asCatchOffset() orelse -1;
    if (previous < 0) return null;
    return @intCast(previous);
}

pub fn stackValueFromTop(stack: *const stack_mod.Stack, offset: u8) !core.JSValue {
    const index_from_top: usize = offset;
    if (index_from_top >= stack.values.len) return error.StackUnderflow;
    return stack.values[stack.values.len - 1 - index_from_top].dup();
}
