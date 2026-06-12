const std = @import("std");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");

pub fn ensureLocalsCapacity(ctx: *core.JSContext, frame: *frame_mod.Frame, idx: usize) !void {
    if (idx < frame.locals.len and idx < frame.locals_uninit.len) return;
    const next_len = @max(idx + 1, @max(frame.locals.len, frame.locals_uninit.len));

    if (!frame.locals_on_heap and !frame.locals_uninit_on_heap and
        next_len <= frame.inline_locals.len and next_len <= frame.inline_locals_uninit.len)
    {
        const next_locals = frame.inline_locals[0..next_len];
        const next_uninit = frame.inline_locals_uninit[0..next_len];
        if (frame.locals.len != 0 and frame.locals.ptr != next_locals.ptr) {
            @memcpy(next_locals[0..frame.locals.len], frame.locals);
        }
        if (next_len > frame.locals.len) @memset(next_locals[frame.locals.len..next_len], core.JSValue.undefinedValue());
        if (frame.locals_uninit.len != 0 and frame.locals_uninit.ptr != next_uninit.ptr) {
            @memcpy(next_uninit[0..frame.locals_uninit.len], frame.locals_uninit);
        }
        if (next_len > frame.locals_uninit.len) @memset(next_uninit[frame.locals_uninit.len..next_len], false);
        frame.locals = next_locals;
        frame.locals_uninit = next_uninit;
        return;
    }

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
    const old_locals_on_heap = frame.locals_on_heap;
    const old_locals_uninit_on_heap = frame.locals_uninit_on_heap;
    frame.locals = next_locals;
    frame.locals_uninit = next_uninit;
    frame.locals_on_heap = true;
    frame.locals_uninit_on_heap = true;
    if (old_locals.len != 0 and old_locals_on_heap) ctx.runtime.memory.free(core.JSValue, old_locals);
    if (old_locals_uninit.len != 0 and old_locals_uninit_on_heap) ctx.runtime.memory.free(bool, old_locals_uninit);
}

pub fn ensureVarRefsCapacity(ctx: *core.JSContext, frame: *frame_mod.Frame, idx: usize) !void {
    if (idx < frame.var_refs.len) return;
    const next_len = idx + 1;
    if (!frame.var_refs_on_heap and next_len <= frame.inline_var_refs.len) {
        const next = frame.inline_var_refs[0..next_len];
        if (frame.var_refs.len != 0 and frame.var_refs.ptr != next.ptr) {
            @memcpy(next[0..frame.var_refs.len], frame.var_refs);
        }
        @memset(next[frame.var_refs.len..next_len], core.JSValue.undefinedValue());
        frame.var_refs = next;
        return;
    }

    const next = try ctx.runtime.memory.alloc(core.JSValue, next_len);
    errdefer ctx.runtime.memory.free(core.JSValue, next);
    for (frame.var_refs, 0..) |value, i| next[i] = value;
    @memset(next[frame.var_refs.len..next_len], core.JSValue.undefinedValue());
    const old_var_refs = frame.var_refs;
    const old_var_refs_on_heap = frame.var_refs_on_heap;
    frame.var_refs = next;
    frame.var_refs_on_heap = true;
    if (old_var_refs.len != 0 and old_var_refs_on_heap) ctx.runtime.memory.free(core.JSValue, old_var_refs);
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

// Atom-list helpers (moved from the VM call runtime).

pub fn atomListContains(list: []const core.Atom, needle: core.Atom) bool {
    for (list) |atom_id| {
        if (atom_id == needle) return true;
    }
    return false;
}

pub fn appendAtom(rt: *core.JSRuntime, list: *[]core.Atom, atom_id: core.Atom) !void {
    const next = try rt.memory.alloc(core.Atom, list.len + 1);
    errdefer rt.memory.free(core.Atom, next);
    @memcpy(next[0..list.len], list.*);
    next[list.len] = rt.atoms.dup(atom_id);
    const old = list.*;
    list.* = next;
    if (old.len != 0) rt.memory.free(core.Atom, old);
}

pub fn freeAtomList(rt: *core.JSRuntime, list: []core.Atom) void {
    for (list) |atom_id| rt.atoms.free(atom_id);
    if (list.len != 0) rt.memory.free(core.Atom, list);
}

pub fn appendOwnedAtom(rt: *core.JSRuntime, keys: *[]core.Atom, atom_id: core.Atom) !void {
    const next = try rt.memory.alloc(core.Atom, keys.*.len + 1);
    errdefer rt.memory.free(core.Atom, next);
    @memcpy(next[0..keys.*.len], keys.*);
    next[keys.*.len] = atom_id;
    const old = keys.*;
    keys.* = next;
    if (old.len != 0) rt.memory.free(core.Atom, old);
}
