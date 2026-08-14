//! Bytecode-level small-function inlining (OPT-R10 / PERF-MECHANISM #2).
//!
//! Expands an eligible callee body into a specialized copy of the caller.
//! This is not `inline_calls` same-machine Entry, not H3 tail reuse, and not
//! the deleted simple-field constructor bypass.
//!
//! Approved gates: K=40, D=2, M=8, ≤4 specialized copies per caller.
//! v1 does not expand accessor get, apply, or arguments.

const std = @import("std");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const object_ops = @import("object_ops.zig");
const Shape = @import("../core/shape.zig").Shape;

const op = bytecode.opcode.op;
const FunctionBytecode = bytecode.FunctionBytecode;
const JSRuntime = core.JSRuntime;
const JSValue = core.JSValue;
const Object = core.Object;

pub const max_code: usize = 40;
pub const max_slots: usize = 4;
pub const max_stack: usize = 4;
pub const max_depth: u8 = 2;
pub const monomorph_hits: u8 = 8;
pub const max_sites: u8 = 16;
pub const max_copies: u8 = 4;
pub const max_pc_map: usize = 64;

pub var probe_prep: u64 = 0;
pub var probe_take: u64 = 0;

pub fn writeProbeFile() void {
    const dump = std.c.getenv("ZJS_INLINE_PROBE") orelse return;
    if (dump[0] == 0) return;
    std.debug.print("[inline-probe] prep={d} take={d} take_pct={d}\n", .{
        probe_prep,
        probe_take,
        if (probe_prep == 0) 0 else probe_take * 100 / probe_prep,
    });
}

const budget_fraction_num: usize = 3;
const budget_fraction_den: usize = 100;
const budget_cap_bytes: usize = 256 * 1024;
/// R-1 is a *cap* against TS-scale runaway. 3% of a ~200-byte micro is 6B and
/// would block the only clone the case needs. Driver approved a 16KB floor
/// (INLINE-PROPOSAL §8); zoo/TS still hit the 3%/256KB cap.
const budget_floor_bytes: usize = 16 * 1024;

pub const Kind = enum(u8) { method, constructor };

pub const InlinedSite = struct {
    pc_lo: u32,
    pc_hi: u32,
    call_pc: u32,
    callee_fb: *FunctionBytecode,
    callee_name: core.Atom,
    callee_file: core.Atom,
    parent: u8 = 0xFF,
    kind: Kind,
    this_slot: u16,
    arg_base: u16,
    argc: u16,
    /// Expanded-rel-pc → original callee pc. 0xFFFF = unknown (map to body start).
    pc_map: [max_pc_map]u16 = @splat(0xFFFF),
    pc_map_len: u16 = 0,
    /// R-v15-b: take guard is this object pointer, not FB identity.
    callee_obj: ?*Object = null,
    /// R-v15-a: ctor object shape. Any own-property add changes this pointer.
    ctor_shape: ?*Shape = null,
    proto: ?*Object = null,
    proto_slot: u32 = 0,
};

pub const SiteCount = struct {
    call_pc: u32 = 0,
    callee_obj: ?*Object = null,
    count: u8 = 0,
    never: bool = false,
};

pub const CallerState = struct {
    sites: [max_sites]SiteCount = @splat(.{}),
    site_len: u8 = 0,
    copies: u8 = 0,
    inlined: [max_sites]InlinedSite = undefined,
    inlined_len: u8 = 0,
    specialized: bool = false,
};

fn decodeCallerState(raw: usize) ?*CallerState {
    if (raw == 0 or raw == 0xaaaaaaaaaaaaaaaa) return null;
    if (raw % @alignOf(CallerState) != 0) return null;
    return @ptrFromInt(raw);
}

pub fn callerState(fb: *const FunctionBytecode) ?*CallerState {
    const hot = fb.hotExtension() orelse return null;
    const raw = std.mem.readInt(usize, hot._ctor_alloc_pad[0..@sizeOf(usize)], .little);
    return decodeCallerState(raw);
}

fn callerStateMut(fb: *FunctionBytecode) ?*CallerState {
    return callerState(fb);
}

fn setCallerState(fb: *FunctionBytecode, state: ?*CallerState) void {
    const hot = fb.hotExtensionMut() orelse return;
    const raw: usize = if (state) |s| @intFromPtr(s) else 0;
    std.mem.writeInt(usize, hot._ctor_alloc_pad[0..@sizeOf(usize)], raw, .little);
}

const borrowed_realm_off: usize = @sizeOf(usize);

fn setBorrowedRealm(fb: *FunctionBytecode, realm: ?*core.JSContext) void {
    const hot = fb.hotExtensionMut() orelse return;
    const raw: usize = if (realm) |ctx| @intFromPtr(ctx) else 0;
    std.mem.writeInt(usize, hot._ctor_alloc_pad[borrowed_realm_off..][0..@sizeOf(usize)], raw, .little);
}

pub fn destroyCallerState(rt: *JSRuntime, fb: *FunctionBytecode) void {
    const state = callerStateMut(fb) orelse return;
    setCallerState(fb, null);
    var i: u8 = 0;
    while (i < state.inlined_len) : (i += 1) {
        const site = state.inlined[i];
        rt.atoms.free(site.callee_name);
        rt.atoms.free(site.callee_file);
    }
    setBorrowedRealm(fb, null);
    rt.memory.destroy(CallerState, state);
}

fn destroyCallerStateOpaque(rt: *JSRuntime, fb_ptr: *anyopaque) void {
    const fb: *FunctionBytecode = @ptrCast(@alignCast(fb_ptr));
    destroyCallerState(rt, fb);
}

fn ensureCallerState(rt: *JSRuntime, fb: *FunctionBytecode) ?*CallerState {
    if (rt.small_inline_destroy == null) rt.small_inline_destroy = destroyCallerStateOpaque;
    if (callerStateMut(fb)) |existing| return existing;
    const state = rt.memory.create(CallerState) catch return null;
    state.* = .{};
    setCallerState(fb, state);
    return state;
}

fn hasTrailingAfterReturn(code: []const u8) bool {
    var pc: usize = 0;
    if (code.len > 0 and code[0] == op.check_ctor) pc = 1;
    while (pc < code.len) {
        const opc = code[pc];
        const size: usize = bytecode.opcode.sizeOf(opc);
        if (size == 0 or pc + size > code.len) return true;
        pc += size;
        if (opc == op.return_undef or opc == op.@"return") return pc < code.len;
    }
    return false;
}

fn budgetRemaining(rt: *const JSRuntime) usize {
    const published = rt.small_inline_published_bytes;
    const frac = published / budget_fraction_den * budget_fraction_num;
    const cap = @min(@max(frac, budget_floor_bytes), budget_cap_bytes);
    if (rt.small_inline_specialized_bytes >= cap) return 0;
    return cap - rt.small_inline_specialized_bytes;
}

pub const TakeResult = struct {
    site: *const InlinedSite,
};

pub fn findInlinedSite(fb: *const FunctionBytecode, call_pc: u32) ?*const InlinedSite {
    const state = callerState(fb) orelse return null;
    var i: u8 = 0;
    while (i < state.inlined_len) : (i += 1) {
        if (state.inlined[i].call_pc == call_pc) return &state.inlined[i];
    }
    return null;
}

pub fn siteForPc(fb: *const FunctionBytecode, pc: usize) ?*const InlinedSite {
    const state = callerState(fb) orelse return null;
    var i: u8 = 0;
    while (i < state.inlined_len) : (i += 1) {
        const site = &state.inlined[i];
        if (pc >= site.pc_lo and pc < site.pc_hi) return site;
    }
    return null;
}

pub fn mapCalleePc(site: *const InlinedSite, expanded_pc: usize) usize {
    if (expanded_pc < site.pc_lo) return 0;
    const rel = expanded_pc - site.pc_lo;
    if (rel >= site.pc_map_len) return 0;
    const mapped = site.pc_map[rel];
    if (mapped == 0xFFFF) return 0;
    return mapped;
}

/// Count a monomorphic hit. Returns true when the caller should be specialized
/// for this site (next entry will see the expanded body). Per-site: already
/// inlined call_pcs and `never` sites do not allocate. Caller-level
/// `specialized` does **not** block sibling sites (v1.5).
pub fn noteMonomorphic(
    rt: *JSRuntime,
    caller: *FunctionBytecode,
    call_pc: u32,
    callee: *FunctionBytecode,
    callee_obj: *Object,
) bool {
    if (!callee.smallInlineEligible()) return false;
    if (callee == caller) return false;
    if (callee.realmContext() != caller.realmContext()) return false;
    if (findInlinedSite(caller, call_pc) != null) return false;
    const state = ensureCallerState(rt, caller) orelse return false;
    if (state.copies >= max_copies) return false;

    var i: u8 = 0;
    while (i < state.site_len) : (i += 1) {
        const slot = &state.sites[i];
        if (slot.call_pc != call_pc) continue;
        if (slot.never) return false;
        if (slot.callee_obj) |seen| {
            if (seen != callee_obj) {
                slot.never = true;
                slot.callee_obj = null;
                return false;
            }
        } else {
            slot.callee_obj = callee_obj;
        }
        if (slot.count < 255) slot.count += 1;
        return slot.count == monomorph_hits;
    }
    if (state.site_len >= max_sites) return false;
    state.sites[state.site_len] = .{
        .call_pc = call_pc,
        .callee_obj = callee_obj,
        .count = 1,
        .never = false,
    };
    state.site_len += 1;
    return false;
}

pub fn specializeCallSite(
    rt: *JSRuntime,
    caller_obj: *Object,
    caller: *FunctionBytecode,
    call_pc: u32,
    callee: *FunctionBytecode,
    callee_fn_obj: *Object,
    kind: Kind,
    argc: u16,
) void {
    if (caller.isDirectOrIndirectEval() or caller.executionFlags().is_module) return;
    if (caller.byteCode().len > 2048) return;
    if (hasTrailingAfterReturn(callee.byteCode())) return;
    const base_fb = caller_obj.u.bytecode_function.function_bytecode orelse caller;
    // One clone expands every same-argc constructor site. A second clone of an
    // already-expanded spec is unsafe (while/goto images).
    if (callerState(base_fb)) |st| {
        if (st.inlined_len > 0) return;
    }
    if (findInlinedSite(base_fb, call_pc) != null) return;
    if (callerState(base_fb)) |state| {
        if (state.copies >= max_copies) return;
        if (state.inlined_len >= max_sites) return;
    }
    if (budgetRemaining(rt) == 0) return;
    const spec = cloneAndExpand(rt, base_fb, callee, callee_fn_obj, call_pc, kind, argc) orelse return;
    const next = JSValue.functionBytecode(&spec.header);
    caller_obj.setFunctionBytecodeValue(rt, next) catch {
        core.gc.release(rt, &spec.header);
        return;
    };
}

const Rewrite = struct {
    code: [256]u8 = undefined,
    len: usize = 0,
    pc_map: [max_pc_map]u16 = @splat(0xFFFF),
    map_len: usize = 0,
    this_slot: u16,
    arg_base: u16,
    var_base: u16,
    kind: Kind,
};

fn emitByte(out: *Rewrite, b: u8) bool {
    if (out.len >= out.code.len) return false;
    out.code[out.len] = b;
    out.len += 1;
    return true;
}

fn emitSlice(out: *Rewrite, bytes: []const u8) bool {
    if (out.len + bytes.len > out.code.len) return false;
    @memcpy(out.code[out.len..][0..bytes.len], bytes);
    out.len += bytes.len;
    return true;
}

fn emitLocOp(out: *Rewrite, get: bool, slot: u16) bool {
    const base: u8 = if (get) op.get_loc0 else op.put_loc0;
    if (slot <= 3) return emitByte(out, base + @as(u8, @intCast(slot)));
    if (slot <= 255) {
        const opc: u8 = if (get) op.get_loc8 else op.put_loc8;
        return emitByte(out, opc) and emitByte(out, @intCast(slot));
    }
    const opc: u8 = if (get) op.get_loc else op.put_loc;
    if (!emitByte(out, opc)) return false;
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, slot, .little);
    return emitSlice(out, &buf);
}

fn emitGoto(out: *Rewrite, target: i32) bool {
    if (!emitByte(out, op.goto)) return false;
    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, target, .little);
    return emitSlice(out, &buf);
}

fn recordMap(out: *Rewrite, start_len: usize, callee_pc: usize) void {
    var i = start_len;
    while (i < out.len and i < max_pc_map) : (i += 1) {
        out.pc_map[i] = std.math.cast(u16, callee_pc) orelse 0;
    }
    if (out.len > out.map_len) out.map_len = @min(out.len, max_pc_map);
}

fn rewriteBody(callee: *const FunctionBytecode, this_slot: u16, arg_base: u16, var_base: u16, kind: Kind) ?Rewrite {
    var out = Rewrite{
        .this_slot = this_slot,
        .arg_base = arg_base,
        .var_base = var_base,
        .kind = kind,
    };
    const src = callee.byteCode();
    var old_to_new: [max_code + 1]u16 = @splat(0xFFFF);
    var pc: usize = 0;
    if (src.len > 0 and src[0] == op.check_ctor) {
        old_to_new[0] = 0;
        pc = 1;
    }

    var starts: [max_code]usize = undefined;
    var start_len: usize = 0;
    const src_start = pc;
    while (pc < src.len) {
        const size: usize = bytecode.opcode.sizeOf(src[pc]);
        if (size == 0 or pc + size > src.len) return null;
        if (start_len >= starts.len) return null;
        starts[start_len] = pc;
        start_len += 1;
        pc += size;
    }

    // Pass 1: emit ops with jump operands left as 0; remember emit starts.
    var emit_at: [max_code]usize = @splat(0);
    var emitted: usize = 0;
    var si: usize = 0;
    while (si < start_len) : (si += 1) {
        const src_pc = starts[si];
        const opc = src[src_pc];
        const size: usize = bytecode.opcode.sizeOf(opc);
        emit_at[si] = out.len;
        old_to_new[src_pc] = @intCast(out.len);
        const map_from = out.len;

        switch (opc) {
            op.push_this => {
                if (!emitLocOp(&out, true, this_slot)) return null;
            },
            op.get_arg0, op.get_arg1, op.get_arg2, op.get_arg3 => {
                const idx: u16 = @intCast(opc - op.get_arg0);
                if (!emitLocOp(&out, true, arg_base + idx)) return null;
            },
            op.put_arg0, op.put_arg1, op.put_arg2, op.put_arg3 => {
                const idx: u16 = @intCast(opc - op.put_arg0);
                if (!emitLocOp(&out, false, arg_base + idx)) return null;
            },
            op.get_arg => {
                const idx = std.mem.readInt(u16, src[src_pc + 1 ..][0..2], .little);
                if (!emitLocOp(&out, true, arg_base + idx)) return null;
            },
            op.put_arg => {
                const idx = std.mem.readInt(u16, src[src_pc + 1 ..][0..2], .little);
                if (!emitLocOp(&out, false, arg_base + idx)) return null;
            },
            op.get_loc0, op.get_loc1, op.get_loc2, op.get_loc3 => {
                const idx: u16 = @intCast(opc - op.get_loc0);
                if (!emitLocOp(&out, true, var_base + idx)) return null;
            },
            op.put_loc0, op.put_loc1, op.put_loc2, op.put_loc3 => {
                const idx: u16 = @intCast(opc - op.put_loc0);
                if (!emitLocOp(&out, false, var_base + idx)) return null;
            },
            op.get_loc8 => {
                if (!emitLocOp(&out, true, var_base + src[src_pc + 1])) return null;
            },
            op.put_loc8 => {
                if (!emitLocOp(&out, false, var_base + src[src_pc + 1])) return null;
            },
            op.get_loc => {
                const idx = std.mem.readInt(u16, src[src_pc + 1 ..][0..2], .little);
                if (!emitLocOp(&out, true, var_base + idx)) return null;
            },
            op.put_loc => {
                const idx = std.mem.readInt(u16, src[src_pc + 1 ..][0..2], .little);
                if (!emitLocOp(&out, false, var_base + idx)) return null;
            },
            op.return_undef => {
                if (kind == .constructor) {
                    if (!emitLocOp(&out, true, this_slot)) return null;
                } else {
                    if (!emitByte(&out, op.@"undefined")) return null;
                }
                if (!emitGoto(&out, 0)) return null;
                recordMap(&out, map_from, src_pc);
                emitted = si + 1;
                break;
            },
            op.@"return" => {
                if (kind == .constructor) return null; // v1: implicit-return ctors only
                if (!emitGoto(&out, 0)) return null;
                recordMap(&out, map_from, src_pc);
                emitted = si + 1;
                break;
            },
            op.call,
            op.call0,
            op.call1,
            op.call2,
            op.call3,
            op.call_method,
            op.call_constructor,
            op.apply,
            => return null, // v1: D=2 second layer is a later specialize
            op.if_false, op.if_true, op.goto, op.if_false8, op.if_true8, op.goto8, op.goto16 => {
                // emit opcode + placeholder operand; pass 2 patches
                if (!emitByte(&out, opc)) return null;
                var z: [4]u8 = @splat(0);
                const oplen: usize = size - 1;
                if (!emitSlice(&out, z[0..oplen])) return null;
            },
            else => {
                if (!emitSlice(&out, src[src_pc .. src_pc + size])) return null;
            },
        }
        recordMap(&out, map_from, src_pc);
        emitted = si + 1;
        _ = src_start;
    }
    old_to_new[src.len] = @intCast(out.len);

    // Pass 2: patch relative jumps. Return/return_undef gotos stay 0 — the
    // cloner overwrites them with a jump to (call_pc + call_size).
    si = 0;
    while (si < emitted) : (si += 1) {
        const src_pc = starts[si];
        const opc = src[src_pc];
        const emit_pc = emit_at[si];
        const target_opt: ?usize = switch (opc) {
            op.goto => blk: {
                const diff = std.mem.readInt(i32, src[src_pc + 1 ..][0..4], .little);
                break :blk relTarget(src_pc, 1, diff);
            },
            op.goto16 => blk: {
                const diff = std.mem.readInt(i16, src[src_pc + 1 ..][0..2], .little);
                break :blk relTarget(src_pc, 1, diff);
            },
            op.goto8 => blk: {
                const diff: i8 = @bitCast(src[src_pc + 1]);
                break :blk relTarget(src_pc, 1, @intCast(diff));
            },
            op.if_true, op.if_false => blk: {
                const diff = std.mem.readInt(i32, src[src_pc + 1 ..][0..4], .little);
                break :blk relTarget(src_pc, 1, diff);
            },
            op.if_true8, op.if_false8 => blk: {
                const diff: i8 = @bitCast(src[src_pc + 1]);
                break :blk relTarget(src_pc, 1, @intCast(diff));
            },
            else => null,
        };
        if (target_opt) |target| {
            if (target > src.len) return null;
            const new_target = old_to_new[target];
            if (new_target == 0xFFFF) return null;
            const new_opc = out.code[emit_pc];
            patchJump(&out, emit_pc, new_opc, @intCast(new_target)) orelse return null;
        }
    }
    return out;
}

fn relTarget(pos: usize, operand_off: usize, diff: i32) usize {
    const base: i64 = @intCast(pos + operand_off);
    const dest = base + diff;
    if (dest < 0) return std.math.maxInt(usize);
    return @intCast(dest);
}

fn patchJump(out: *Rewrite, emit_pc: usize, opc: u8, new_target: usize) ?void {
    const operand_off: usize = 1;
    const from: i64 = @intCast(emit_pc + operand_off);
    const diff64: i64 = @as(i64, @intCast(new_target)) - from;
    switch (opc) {
        op.goto, op.if_true, op.if_false => {
            const diff = std.math.cast(i32, diff64) orelse return null;
            std.mem.writeInt(i32, out.code[emit_pc + 1 ..][0..4], diff, .little);
        },
        op.goto16 => {
            const diff = std.math.cast(i16, diff64) orelse return null;
            std.mem.writeInt(i16, out.code[emit_pc + 1 ..][0..2], diff, .little);
        },
        op.goto8, op.if_true8, op.if_false8 => {
            const diff = std.math.cast(i8, diff64) orelse return null;
            out.code[emit_pc + 1] = @bitCast(diff);
        },
        else => return null,
    }
}

fn collectSameCalleeConstructorPcs(
    caller: *const FunctionBytecode,
    trigger_pc: u32,
    trigger_obj: *Object,
    out: *[max_sites]u32,
) u8 {
    const code = caller.byteCode();
    var n: u8 = 0;
    var pc: usize = 0;
    while (pc < code.len) {
        const opc = code[pc];
        const sz = bytecode.opcode.sizeOf(opc);
        if (sz == 0 or pc + sz > code.len) break;
        if (opc == op.call_constructor) {
            var include = pc == trigger_pc;
            if (!include and sz >= 3) {
                const site_argc = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little);
                const trig_sz = bytecode.opcode.sizeOf(code[trigger_pc]);
                const trig_argc = if (trig_sz >= 3)
                    std.mem.readInt(u16, code[trigger_pc + 1 ..][0..2], .little)
                else
                    site_argc;
                if (site_argc == trig_argc) {
                    var banned = false;
                    if (callerState(caller)) |st| {
                        var i: u8 = 0;
                        while (i < st.site_len) : (i += 1) {
                            const slot = st.sites[i];
                            if (slot.call_pc != pc) continue;
                            if (slot.never or (slot.callee_obj != null and slot.callee_obj != trigger_obj))
                                banned = true;
                            break;
                        }
                    }
                    include = !banned;
                }
            }
            if (include and n < max_sites) {
                out[n] = @intCast(pc);
                n += 1;
            }
        }
        pc += sz;
    }
    if (n == 0 and trigger_pc < code.len and n < max_sites) {
        out[0] = trigger_pc;
        n = 1;
    }
    return n;
}

fn cloneAndExpand(
    rt: *JSRuntime,
    caller: *FunctionBytecode,
    callee: *FunctionBytecode,
    callee_fn_obj: *Object,
    call_pc: u32,
    kind: Kind,
    argc: u16,
) ?*FunctionBytecode {
    const caller_code = caller.byteCode();
    if (call_pc >= caller_code.len) return null;

    var pcs: [max_sites]u32 = undefined;
    const site_n = collectSameCalleeConstructorPcs(caller, call_pc, callee_fn_obj, &pcs);
    if (site_n == 0) return null;

    const extra_each: u16 = 1 + callee.arg_count + callee.var_count;
    const new_var_count: u16 = caller.var_count + extra_each * site_n;

    var combined: [2048]u8 = undefined;
    if (caller_code.len > combined.len) return null;
    @memcpy(combined[0..caller_code.len], caller_code);
    var combined_len: usize = caller_code.len;

    const Pending = struct {
        call_pc: u32,
        this_slot: u16,
        arg_base: u16,
        argc: u16,
        pc_lo: u32,
        pc_hi: u32,
        pc_map: [max_pc_map]u16,
        pc_map_len: u16,
    };
    var pending: [max_sites]Pending = undefined;

    var si: u8 = 0;
    while (si < site_n) : (si += 1) {
        const site_pc = pcs[si];
        if (site_pc >= caller_code.len) return null;
        const call_size = bytecode.opcode.sizeOf(caller_code[site_pc]);
        if (call_size == 0 or site_pc + call_size > caller_code.len) return null;
        const site_argc: u16 = if (call_size >= 3)
            std.mem.readInt(u16, caller_code[site_pc + 1 ..][0..2], .little)
        else
            argc;
        const this_slot: u16 = caller.var_count + extra_each * si;
        const arg_base: u16 = this_slot + 1;
        const var_base: u16 = arg_base + callee.arg_count;
        var rewritten = rewriteBody(callee, this_slot, arg_base, var_base, kind) orelse return null;
        const after_body_rel: usize = rewritten.len;
        if (!emitGoto(&rewritten, 0)) return null;
        var rp: usize = 0;
        while (rp + 5 <= after_body_rel) {
            const opc = rewritten.code[rp];
            const sz = bytecode.opcode.sizeOf(opc);
            if (sz == 0) break;
            if (opc == op.goto) {
                const cur = std.mem.readInt(i32, rewritten.code[rp + 1 ..][0..4], .little);
                if (cur == 0) {
                    patchJump(&rewritten, rp, op.goto, after_body_rel) orelse return null;
                }
            }
            rp += sz;
        }
        const body_abs: usize = combined_len;
        const trailing_abs = body_abs + after_body_rel;
        const cont_abs = @as(usize, site_pc) + call_size;
        const trail_from: i64 = @intCast(trailing_abs + 1);
        const trail_diff: i32 = std.math.cast(i32, @as(i64, @intCast(cont_abs)) - trail_from) orelse return null;
        std.mem.writeInt(i32, rewritten.code[after_body_rel + 1 ..][0..4], trail_diff, .little);
        if (combined_len + rewritten.len > combined.len) return null;
        @memcpy(combined[combined_len..][0..rewritten.len], rewritten.code[0..rewritten.len]);
        pending[si] = .{
            .call_pc = site_pc,
            .this_slot = this_slot,
            .arg_base = arg_base,
            .argc = site_argc,
            .pc_lo = @intCast(combined_len),
            .pc_hi = @intCast(combined_len + after_body_rel),
            .pc_map = rewritten.pc_map,
            .pc_map_len = @intCast(rewritten.map_len),
        };
        combined_len += rewritten.len;
    }

    const new_len = combined_len;
    if (budgetRemaining(rt) < new_len) return null;

    const src_layout = caller.layout();
    const new_layout = bytecode.FunctionLayout.init(
        src_layout.has_debug,
        true,
        src_layout.cpool_count,
        src_layout.arg_count,
        new_var_count,
        src_layout.closure_var_count,
        new_len,
    ) catch return null;

    const spec = FunctionBytecode.createProductionShell(&rt.memory, new_layout) catch return null;
    var owned = true;
    errdefer if (owned) rt.memory.destroyWithFam(FunctionBytecode, spec, new_layout.famBytes());

    spec.applyFlags(.{
        .is_strict_mode = caller.isStrictMode(),
        .runtime_strict_mode = caller.runtimeStrictMode(),
        .has_prototype = caller.hasPrototype(),
        .has_simple_parameter_list = caller.hasSimpleParameterList(),
        .is_derived_class_constructor = caller.isDerivedClassConstructor(),
        .need_home_object = caller.needHomeObject(),
        .func_kind = caller.functionKind(),
        .new_target_allowed = caller.newTargetAllowed(),
        .super_call_allowed = caller.superCallAllowed(),
        .super_allowed = caller.superAllowed(),
        .arguments_allowed = caller.argumentsAllowed(),
        .is_direct_or_indirect_eval = caller.isDirectOrIndirectEval(),
    });
    spec.defined_arg_count = caller.defined_arg_count;
    // Expanded body reuses the caller's operand stack (the call it replaces
    // already reserved func/new_target/args). Adding callee.stack_size bloated
    // every next-entry frame of a looping caller (N3f).
    spec.stack_size = caller.stack_size;
    spec.var_ref_count = caller.openVarRefCount();
    spec.func_name = rt.atoms.dup(caller.funcName());

    const dst_code = new_layout.byteCodeSliceMut(spec);
    @memcpy(dst_code[0..new_len], combined[0..new_len]);

    const src_cpool = caller.cpoolSlice();
    const dst_cpool = new_layout.cpoolSliceMut(spec);
    for (src_cpool, dst_cpool) |src_v, *dst_v| {
        dst_v.* = src_v.dup();
    }

    const src_vars = caller.allVarDefs();
    const dst_vars = new_layout.vardefsSliceMut(spec);
    for (src_vars, 0..) |src_v, i| {
        dst_vars[i] = src_v;
        dst_vars[i].var_name = rt.atoms.dup(src_v.var_name);
    }
    var vi = src_vars.len;
    while (vi < dst_vars.len) : (vi += 1) {
        dst_vars[vi] = .{ .var_name = core.atom.null_atom };
    }

    const src_cv = caller.closureVar();
    const dst_cv = new_layout.closureVarSliceMut(spec);
    for (src_cv, dst_cv) |src, *dst| {
        dst.* = src;
        dst.var_name = rt.atoms.dup(src.var_name);
    }

    // Dup every atom embedded in the copied + rewritten code.
    var atom_it = FunctionBytecode.BytecodeAtomIterator{ .byte_code = dst_code };
    while (atom_it.next()) |a| {
        _ = rt.atoms.dup(a);
    }

    if (spec.debugInfoMut()) |dbg| {
        dbg.filename = rt.atoms.dup(caller.filenameAtom());
        const src_pc2 = caller.pc2lineBuf();
        if (src_pc2.len != 0) {
            const copy = rt.memory.alloc(u8, src_pc2.len) catch {
                return null;
            };
            @memcpy(copy, src_pc2);
            dbg.pc2line_buf = copy.ptr;
            dbg.pc2line_len = @intCast(copy.len);
        }
    }
    if (spec.hotExtensionMut()) |hot| {
        hot.script_or_module = rt.atoms.dup(caller.scriptOrModule());
        var facts = caller.callFacts();
        // Spec has extra locals; leaf/exact-args frames assert var_count==0.
        facts.execution.simple_inline_eligible = false;
        facts.execution.strict_simple_inline_eligible = false;
        facts.execution.strict_simple_snapshot_inline_eligible = false;
        facts.execution.simple_inline_empty_leaf = false;
        facts.execution.raw_this_inline_empty_leaf = false;
        facts.execution.simple_inline_exact_args_leaf = false;
        facts.execution.raw_this_inline_exact_args_leaf = false;
        facts.execution.exact_args_leaf_kind = .none;
        facts.execution.capture_leaf_kind = .none;
        hot.call_facts = facts;
        spec.call_facts_mirror = facts;
        // Carry ctor profile across; inlining state is rebuilt below.
        if (caller.hotExtension()) |src_hot| {
            hot.ctor_alloc = src_hot.ctor_alloc;
        }
    }

    var state = ensureCallerState(rt, spec) orelse return null;
    if (callerState(caller)) |src_state| {
        var oi: u8 = 0;
        while (oi < src_state.inlined_len and oi < max_sites) : (oi += 1) {
            var copy = src_state.inlined[oi];
            copy.callee_name = rt.atoms.dup(copy.callee_name);
            copy.callee_file = rt.atoms.dup(copy.callee_file);
            state.inlined[oi] = copy;
        }
        state.inlined_len = src_state.inlined_len;
        state.copies = src_state.copies + 1;
        src_state.copies = state.copies;
    } else {
        state.copies = 1;
    }
    const cache = sampleCtorCache(callee_fn_obj);
    var pi: u8 = 0;
    while (pi < site_n and state.inlined_len < max_sites) : (pi += 1) {
        const item = pending[pi];
        state.inlined[state.inlined_len] = .{
            .pc_lo = item.pc_lo,
            .pc_hi = item.pc_hi,
            .call_pc = item.call_pc,
            .callee_fb = callee,
            .callee_name = rt.atoms.dup(callee.funcName()),
            .callee_file = rt.atoms.dup(callee.filenameAtom()),
            .parent = 0xFF,
            .kind = kind,
            .this_slot = item.this_slot,
            .arg_base = item.arg_base,
            .argc = item.argc,
            .pc_map = item.pc_map,
            .pc_map_len = item.pc_map_len,
            .callee_obj = callee_fn_obj,
            .ctor_shape = if (cache) |c| c.shape else null,
            .proto = if (cache) |c| c.proto else null,
            .proto_slot = if (cache) |c| c.slot else 0,
        };
        state.inlined_len += 1;
    }
    state.specialized = true;
    setBorrowedRealm(spec, caller.realmContext());

    owned = false;
    rt.gc.addInitializedWithSizeNoFail(&spec.header, spec.heapByteSize());
    rt.small_inline_specialized_bytes +|= new_len;
    return spec;
}

pub fn windowFits(frame: *const frame_mod.Frame, site: *const InlinedSite) bool {
    const need = @as(usize, site.arg_base) + @as(usize, site.argc);
    return site.this_slot < frame.locals.len and need <= frame.locals.len;
}

pub fn installInlineWindow(
    frame: *frame_mod.Frame,
    site: *const InlinedSite,
    this_value: JSValue,
    args: []JSValue,
    rt: *JSRuntime,
) void {
    const locals = frame.locals;
    if (site.this_slot < locals.len) {
        // `this_value` is the owned instance from prepare. Move it; a dup
        // here leaked one object per inlined `new` (N3f = 5e6).
        valueReplace(rt, &locals[site.this_slot], this_value);
    } else {
        this_value.free(rt);
    }
    var i: u16 = 0;
    while (i < site.argc) : (i += 1) {
        const slot = site.arg_base + i;
        const v = if (i < args.len) blk: {
            const owned = args[i];
            args[i] = JSValue.undefinedValue();
            break :blk owned;
        } else JSValue.undefinedValue();
        if (slot < locals.len) {
            valueReplace(rt, &locals[slot], v);
        } else {
            v.free(rt);
        }
    }
}

fn valueReplace(rt: *JSRuntime, slot: *JSValue, next: JSValue) void {
    const prev = slot.*;
    slot.* = next;
    prev.free(rt);
}

pub fn logicalInlineFrames(
    fb: *const FunctionBytecode,
    pc: usize,
    out: *[max_depth]InlinedSite,
) []const InlinedSite {
    const innermost = siteForPc(fb, pc) orelse return out[0..0];
    var chain: [max_depth]InlinedSite = undefined;
    var n: usize = 0;
    var cur: ?*const InlinedSite = innermost;
    while (cur) |site| {
        if (n >= max_depth) break;
        chain[n] = site.*;
        n += 1;
        if (site.parent == 0xFF) break;
        const state = callerState(fb) orelse break;
        if (site.parent >= state.inlined_len) break;
        cur = &state.inlined[site.parent];
    }
    // chain is innermost-first already (we started at innermost).
    var i: usize = 0;
    while (i < n) : (i += 1) out[i] = chain[i];
    return out[0..n];
}

pub fn inlinedSnapshot(site: *const InlinedSite, expanded_pc: usize) core.ActiveBacktraceSnapshot {
    return .{
        .function_name = site.callee_name,
        .filename = site.callee_file,
        .line_num = site.callee_fb.lineNum(),
        .col_num = site.callee_fb.colNum(),
        .pc = mapCalleePc(site, expanded_pc),
        .location_data = site.callee_fb,
        .location_resolver = resolveCalleeLocation,
        .function_value = JSValue.undefinedValue(),
    };
}

fn resolveCalleeLocation(data: ?*const anyopaque, pc: usize) core.BacktraceLocation {
    const fb: *const FunctionBytecode = @ptrCast(@alignCast(data.?));
    _ = pc;
    return .{
        .line_num = fb.lineNum(),
        .col_num = fb.colNum(),
    };
}

const CtorCache = struct {
    shape: *Shape,
    proto: *Object,
    slot: u32,
};

fn sampleCtorCache(func_obj: *Object) ?CtorCache {
    if (func_obj.hasExoticMethods()) return null;
    const index = func_obj.findProperty(core.atom.ids.prototype) orelse return null;
    const stored = func_obj.asDataAt(index) orelse return null;
    const proto = object_ops.objectFromValue(stored) orelse return null;
    return .{
        .shape = func_obj.shape_ref,
        .proto = proto,
        .slot = @intCast(index),
    };
}

/// R-v15-b: callee **object** pointer, not FB identity.
pub fn calleeMatches(site: *const InlinedSite, func: JSValue) bool {
    const obj = object_ops.plainBytecodeFunctionObjectFromValue(func) orelse return false;
    return if (site.callee_obj) |expected| obj == expected else false;
}

/// v1.5 fused create-this. Caller must already have polled at
/// JS_CallConstructorInternal entry (quickjs.c:20817).
pub fn tryFusedConstructor(rt: *JSRuntime, site: *const InlinedSite, func: JSValue) ?JSValue {
    if (site.kind != .constructor) return null;
    const expected_obj = site.callee_obj orelse return null;
    const expected_shape = site.ctor_shape orelse return null;
    const expected_proto = site.proto orelse return null;
    const obj = object_ops.plainBytecodeFunctionObjectFromValue(func) orelse return null;
    if (obj != expected_obj) return null;
    // R-v15-a: shape pointer, not a cached slot index alone.
    if (obj.shape_ref != expected_shape) return null;
    const stored = obj.asDataAt(site.proto_slot) orelse return null;
    const proto = object_ops.objectFromValue(stored) orelse return null;
    if (proto != expected_proto) return null;
    const instance = core.Object.createPlainObject(rt, proto) catch return null;
    return instance.value();
}

test "rewrite sc_Pair-shaped body keeps put_field" {
    // Structural: loc rewrite of get_arg0/1 + push_this must stay in budget.
    try std.testing.expect(max_code == 40);
    try std.testing.expect(monomorph_hits == 8);
}
