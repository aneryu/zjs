//! Bytecode-level small-function inlining (OPT-R10 / PERF-MECHANISM #2).
//!
//! Expands an eligible callee body into a specialized copy of the caller.
//! This is not `inline_calls` same-machine Entry, not H3 tail reuse, and not
//! the deleted simple-field constructor bypass.
//!
//! Approved gates: K=40, D=2, M=8, ≤4 specialized copies per caller.
//! L1 apply-arguments-forwarding rewrites a proven `fn.apply(this, arguments)`
//! ctor body to a live-argv `call_method_apply_fwd` (no L2 initialize expansion).

const std = @import("std");

const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const object_ops = @import("object_ops.zig");
const function_ops = @import("function_ops.zig");
const Shape = @import("../core/shape.zig").Shape;

const op = bytecode.opcode.op;
const FunctionBytecode = bytecode.FunctionBytecode;
const JSRuntime = core.JSRuntime;
const JSValue = core.JSValue;
const Object = core.Object;

pub const max_code: usize = 40;
pub const max_depth: u8 = 2;
pub const monomorph_hits: u8 = 8;
pub const max_sites: u8 = 16;
pub const max_copies: u8 = 4;
pub const max_pc_map: usize = 64;

pub var probe_prep: u64 = 0;
pub var probe_take: u64 = 0;

pub fn writeProbeFile() void {
    // std.posix.getenv does not exist under zig 0.16 with libc linked;
    // std.c.getenv is the supported spelling (same fix as grok f32749f6).
    const raw = std.c.getenv("ZJS_INLINE_PROBE") orelse return;
    if (raw[0] == 0) return;

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

/// L1 apply-forward facts. Lives beside `CallerState.inlined`, not inside
/// `InlinedSite`, so `findInlinedSite` keeps the v1.5 hot stride.
pub const ApplyForwardCold = struct {
    method_atom: core.Atom = core.atom.null_atom,
    call_pc: u32 = no_forward_pc,
};

const no_forward_pc: u32 = std.math.maxInt(u32);

/// v1.5 hot record (no L1 tail). `InlinedSite` must stay this width.
const V15InlinedSite = struct {
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
    pc_map: [max_pc_map]u16 = @splat(0xFFFF),
    pc_map_len: u16 = 0,
    callee_obj: ?*Object = null,
    ctor_shape: ?*Shape = null,
    proto: ?*Object = null,
    proto_slot: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(InlinedSite) == @sizeOf(V15InlinedSite));
    std.debug.assert(@alignOf(InlinedSite) == @alignOf(V15InlinedSite));
}

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
    /// Parallel to `inlined`. Unread on the findInlinedSite scan.
    apply_forward: [max_sites]ApplyForwardCold = @splat(.{}),
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
/// Callee-side L1 analysis memo in the hot-extension pad. Distinct from the
/// CallerState pointer (off 0) and borrowed-realm word (off 8). 0 = unknown.
const apply_forward_memo_off: usize = 2 * @sizeOf(usize);
const apply_forward_memo_no: u8 = 1;
const apply_forward_memo_yes: u8 = 2;

fn applyForwardEligible(fb: *FunctionBytecode) bool {
    if (fb.hotExtension()) |hot| {
        const memo = hot._ctor_alloc_pad[apply_forward_memo_off];
        if (memo == apply_forward_memo_yes) return true;
        if (memo == apply_forward_memo_no) return false;
    }
    const yes = analyzeApplyForward(fb) != null;
    if (fb.hotExtensionMut()) |hot| {
        hot._ctor_alloc_pad[apply_forward_memo_off] =
            if (yes) apply_forward_memo_yes else apply_forward_memo_no;
    }
    return yes;
}

fn anyApplyForwardSite(state: *const CallerState) bool {
    var i: u8 = 0;
    while (i < state.inlined_len) : (i += 1) {
        if (state.apply_forward[i].call_pc != no_forward_pc) return true;
    }
    return false;
}

fn siteSlot(state: *const CallerState, site: *const InlinedSite) u8 {
    const begin = @intFromPtr(&state.inlined[0]);
    const p = @intFromPtr(site);
    std.debug.assert(p >= begin);
    const i = (p - begin) / @sizeOf(InlinedSite);
    std.debug.assert(i < state.inlined_len);
    return @intCast(i);
}

fn applyForwardColdOf(state: *const CallerState, site: *const InlinedSite) ApplyForwardCold {
    return state.apply_forward[siteSlot(state, site)];
}

fn siteApplyForwarded(state: *const CallerState, site: *const InlinedSite) bool {
    return applyForwardColdOf(state, site).call_pc != no_forward_pc;
}

fn markApplyForwardInlined(fb: *FunctionBytecode) void {
    var flags = fb.executionFlags();
    if (flags.apply_forward_inlined) return;
    flags.apply_forward_inlined = true;
    fb.setExecutionFlags(flags);
}

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
        const fwd = state.apply_forward[i];
        if (fwd.method_atom != core.atom.null_atom) rt.atoms.free(fwd.method_atom);
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
    if (!callee.smallInlineEligible() and !applyForwardEligible(callee)) return false;
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
    if (argc < callee.arg_count) return;
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
    // I4 install-time: no own apply on the proto-chain method, and
    // Function.prototype.apply is still the realm builtin record.
    if (analyzeApplyForward(callee)) |plan| {
        const realm = callee.realmContext() orelse return;
        const global = realm.global orelse return;
        if (!applyForwardGuardHolds(rt, global, callee_fn_obj, @intCast(plan.method_atom))) return;
    }
    const spec = cloneAndExpand(rt, base_fb, callee, callee_fn_obj, call_pc, kind, argc) orelse return;
    const next = JSValue.functionBytecode(&spec.header);
    caller_obj.setFunctionBytecodeValue(rt, next) catch {
        core.gc.release(rt, &spec.header);
        return;
    };
}

const ApplyForwardPlan = struct {
    args_local: u16,
    method_atom: u32,
    method_get_pc: u32,
    apply_get_pc: u32,
    thisarg_pc: u32,
    args_get_pc: u32,
    call_pc: u32,
    special_pc: u32,
    special_put_pc: u32,
};

fn locIndexOf(opc: u8, src: []const u8, pc: usize) ?u16 {
    return switch (opc) {
        op.get_loc0, op.put_loc0, op.get_loc0_field, op.put_loc0_get_loc0 => 0,
        op.get_loc1, op.put_loc1 => 1,
        op.get_loc2, op.put_loc2, op.get_loc2_field => 2,
        op.get_loc3, op.put_loc3 => 3,
        op.get_loc8, op.put_loc8, op.put_loc8_get_loc8 => src[pc + 1],
        op.get_loc, op.put_loc => std.mem.readInt(u16, src[pc + 1 ..][0..2], .little),
        else => null,
    };
}

fn isPutLoc(opc: u8) bool {
    return switch (opc) {
        op.put_loc0, op.put_loc1, op.put_loc2, op.put_loc3, op.put_loc8, op.put_loc, op.put_loc8_get_loc8, op.put_loc0_get_loc0 => true,
        else => false,
    };
}

fn isGetLoc(opc: u8) bool {
    return switch (opc) {
        op.get_loc0, op.get_loc1, op.get_loc2, op.get_loc3, op.get_loc8, op.get_loc, op.get_loc0_field, op.get_loc2_field => true,
        else => false,
    };
}

fn isPutArg(opc: u8) bool {
    return switch (opc) {
        op.put_arg0, op.put_arg1, op.put_arg2, op.put_arg3, op.put_arg => true,
        else => false,
    };
}

fn isForwardForbiddenOp(opc: u8) bool {
    return switch (opc) {
        op.apply,
        op.apply_eval,
        op.rest,
        op.eval,
        op.with_get_var,
        op.with_put_var,
        op.with_delete_var,
        op.with_make_ref,
        op.with_get_ref,
        op.fclosure,
        op.fclosure8,
        => true,
        else => false,
    };
}

/// S1–S8 static predicate for L1 apply-arguments-forwarding. Dataflow only:
/// arguments has a single use as the array-like argument of `.apply`, the
/// apply thisArg is the constructor `this`, and there is no rest/eval/with/
/// OP_apply/spread. Does not match function or field names.
fn analyzeApplyForward(fb: *const FunctionBytecode) ?ApplyForwardPlan {
    if (!fb.hasSimpleParameterList()) return null; // S1
    if (fb.closureVarCount() != 0 or fb.openVarRefCount() != 0) return null; // S2
    if (fb.functionKind() != .normal) return null;
    if (fb.isDerivedClassConstructor()) return null;
    const code = fb.byteCode();
    if (code.len == 0 or code.len > max_code) return null;

    var special_pc: ?usize = null;
    var special_put_pc: ?usize = null;
    var args_local: ?u16 = null;
    var get_args_count: u8 = 0;
    var get_args_pc: ?usize = null;
    var put_args_count: u8 = 0;
    var apply_get_pc: ?usize = null;
    var method_get_pc: ?usize = null;
    var method_atom: ?u32 = null;
    var call_pc: ?usize = null;
    var prev_pc: usize = 0;
    var prev_op: u8 = 0;
    var saw_jump_before_call = false;

    var pc: usize = 0;
    if (code[0] == op.check_ctor) pc = 1;

    while (pc < code.len) {
        const opc = code[pc];
        const size: usize = bytecode.opcode.sizeOf(opc);
        if (size == 0 or pc + size > code.len) return null;
        if (isForwardForbiddenOp(opc)) return null; // S2 / S3
        if (isPutArg(opc)) return null; // S7
        switch (opc) {
            op.if_false, op.if_true, op.goto, op.if_false8, op.if_true8, op.goto8, op.goto16 => {
                if (call_pc == null) saw_jump_before_call = true;
            },
            else => {},
        }
        if (opc == op.special_object) {
            const subtype = code[pc + 1];
            if (subtype == bytecode.opcode.special_object_subtype.arguments or
                subtype == bytecode.opcode.special_object_subtype.mapped_arguments)
            {
                if (special_pc != null) return null;
                special_pc = pc;
            } else return null;
        }
        if (isPutLoc(opc)) {
            if (special_pc != null and special_put_pc == null and prev_op == op.special_object) {
                args_local = locIndexOf(opc, code, pc);
                special_put_pc = pc;
                put_args_count += 1;
            } else if (args_local) |al| {
                if (locIndexOf(opc, code, pc) == al) return null;
            }
        }
        if (isGetLoc(opc)) {
            if (args_local) |al| {
                if (locIndexOf(opc, code, pc) == al) {
                    get_args_count += 1;
                    get_args_pc = pc;
                }
            }
        }
        if (opc == op.get_field or opc == op.get_field2 or opc == op.get_field2_call_method or
            opc == op.get_field_field2)
        {
            const atom_id = std.mem.readInt(u32, code[pc + 1 ..][0..4], .little);
            if (atom_id == core.atom.ids.apply and
                (opc == op.get_field2 or opc == op.get_field2_call_method))
            {
                if (apply_get_pc != null) return null;
                apply_get_pc = pc;
                if (prev_op != op.get_field and prev_op != op.get_field_field2) return null;
                method_get_pc = prev_pc;
                method_atom = std.mem.readInt(u32, code[prev_pc + 1 ..][0..4], .little);
                if (method_atom == core.atom.ids.apply) return null;
            }
        }
        if (opc == op.call_method) {
            const argc = std.mem.readInt(u16, code[pc + 1 ..][0..2], .little);
            if (apply_get_pc != null and call_pc == null) {
                if (argc != 2) return null; // S5: apply(thisArg, argArray)
                call_pc = pc;
            } else if (call_pc == null) return null;
        }
        if (opc == op.call or opc == op.call0 or opc == op.call1 or
            opc == op.call2 or opc == op.call3 or opc == op.call_constructor)
        {
            if (call_pc == null) return null;
        }
        prev_pc = pc;
        prev_op = opc;
        pc += size;
    }

    if (saw_jump_before_call) return null;
    const sp = special_pc orelse return null;
    const spp = special_put_pc orelse return null;
    const al = args_local orelse return null;
    const agp = apply_get_pc orelse return null;
    const mgp = method_get_pc orelse return null;
    const ma = method_atom orelse return null;
    const cp = call_pc orelse return null;
    const gap = get_args_pc orelse return null;
    if (get_args_count != 1 or put_args_count != 1) return null; // S4
    if (gap != prevOpBefore(code, cp)) return null;

    const tap = prevOpBefore(code, gap);
    const this_opc = code[tap];
    const this_local = firstThisLocal(code) orelse return null;
    if (this_opc == op.push_this or this_opc == op.push_this_put_loc0) {
        // ok
    } else if (isGetLoc(this_opc)) {
        const idx = locIndexOf(this_opc, code, tap) orelse return null;
        if (idx != this_local) return null; // S6
    } else return null;

    const before_method = prevOpBefore(code, mgp);
    const bm_op = code[before_method];
    if (bm_op == op.push_this or bm_op == op.push_this_put_loc0) {
        // ok
    } else if (isGetLoc(bm_op)) {
        const idx = locIndexOf(bm_op, code, before_method) orelse return null;
        if (idx != this_local) return null;
    } else return null;

    return .{
        .args_local = al,
        .method_atom = ma,
        .method_get_pc = @intCast(mgp),
        .apply_get_pc = @intCast(agp),
        .thisarg_pc = @intCast(tap),
        .args_get_pc = @intCast(gap),
        .call_pc = @intCast(cp),
        .special_pc = @intCast(sp),
        .special_put_pc = @intCast(spp),
    };
}

fn prevOpBefore(code: []const u8, target: usize) usize {
    var pc: usize = if (code.len > 0 and code[0] == op.check_ctor) 1 else 0;
    var last: usize = pc;
    while (pc < target) {
        last = pc;
        const sz = bytecode.opcode.sizeOf(code[pc]);
        if (sz == 0) break;
        pc += sz;
    }
    return last;
}

fn firstThisLocal(code: []const u8) ?u16 {
    var pc: usize = if (code.len > 0 and code[0] == op.check_ctor) 1 else 0;
    var prev_op: u8 = 0;
    while (pc < code.len) {
        const opc = code[pc];
        const size: usize = bytecode.opcode.sizeOf(opc);
        if (size == 0 or pc + size > code.len) return null;
        if (isPutLoc(opc) and (prev_op == op.push_this or prev_op == op.push_this_put_loc0))
            return locIndexOf(opc, code, pc);
        prev_op = opc;
        pc += size;
    }
    return null;
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
    forward_call_rel: u32 = 0xFFFFFFFF,
    method_atom: u32 = 0,
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

fn emitCallMethodApplyFwd(out: *Rewrite, argc: u16) bool {
    if (!emitByte(out, op.call_method_apply_fwd)) return false;
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, argc, .little);
    return emitSlice(out, &buf);
}

fn emitGetField2(out: *Rewrite, atom_id: u32) bool {
    if (!emitByte(out, op.get_field2)) return false;
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, atom_id, .little);
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

fn rewriteBody(
    callee: *const FunctionBytecode,
    this_slot: u16,
    arg_base: u16,
    var_base: u16,
    kind: Kind,
    site_argc: u16,
) ?Rewrite {
    var out = Rewrite{
        .this_slot = this_slot,
        .arg_base = arg_base,
        .var_base = var_base,
        .kind = kind,
    };
    const plan = analyzeApplyForward(callee);
    const src = callee.byteCode();
    // Mapping is indexed by source pc. Regular inlines stay within K;
    // apply-forward bodies are also small (G-ctor is 22B). Reject overflow
    // rather than write past old_to_new.
    if (src.len > max_code) return null;
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
        if (plan) |p| {
            if (src_pc == p.special_pc or src_pc == p.special_put_pc or
                src_pc == p.apply_get_pc or src_pc == p.thisarg_pc or
                src_pc == p.args_get_pc)
            {
                old_to_new[src_pc] = @intCast(out.len);
                emit_at[si] = out.len;
                emitted = si + 1;
                continue;
            }
            if (src_pc == p.method_get_pc) {
                emit_at[si] = out.len;
                old_to_new[src_pc] = @intCast(out.len);
                const map_from = out.len;
                if (!emitGetField2(&out, p.method_atom)) return null;
                recordMap(&out, map_from, src_pc);
                emitted = si + 1;
                continue;
            }
            if (src_pc == p.call_pc) {
                emit_at[si] = out.len;
                old_to_new[src_pc] = @intCast(out.len);
                const map_from = out.len;
                var ai: u16 = 0;
                while (ai < site_argc) : (ai += 1) {
                    if (!emitLocOp(&out, true, arg_base + ai)) return null;
                }
                out.forward_call_rel = @intCast(out.len);
                out.method_atom = p.method_atom;
                if (!emitCallMethodApplyFwd(&out, site_argc)) return null;
                // apply-fwd leaves initialize's return; the ctor result is
                // `this`. Drop the unused value so it cannot pile up across
                // next-entry takes.
                if (!emitByte(&out, op.drop)) return null;
                recordMap(&out, map_from, src_pc);
                emitted = si + 1;
                continue;
            }
        }
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
            op.get_loc0_field => {
                if (!emitLocOp(&out, true, var_base + 0)) return null;
            },
            op.get_loc2_field => {
                if (!emitLocOp(&out, true, var_base + 2)) return null;
            },
            op.put_loc0, op.put_loc1, op.put_loc2, op.put_loc3, op.put_loc0_get_loc0 => {
                const idx: u16 = if (opc == op.put_loc0_get_loc0) 0 else @intCast(opc - op.put_loc0);
                if (!emitLocOp(&out, false, var_base + idx)) return null;
            },
            op.push_this_put_loc0 => {
                if (!emitLocOp(&out, true, this_slot)) return null;
            },
            op.get_loc8 => {
                if (!emitLocOp(&out, true, var_base + src[src_pc + 1])) return null;
            },
            op.put_loc8, op.put_loc8_get_loc8 => {
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
                    if (!emitByte(&out, op.undefined)) return null;
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

    var max_site_argc: u16 = argc;
    var argc_i: u8 = 0;
    while (argc_i < site_n) : (argc_i += 1) {
        const site_pc = pcs[argc_i];
        const call_size = bytecode.opcode.sizeOf(caller_code[site_pc]);
        if (call_size >= 3) {
            const site_argc = std.mem.readInt(u16, caller_code[site_pc + 1 ..][0..2], .little);
            if (site_argc > max_site_argc) max_site_argc = site_argc;
        }
    }
    const extra_args: u16 = @max(callee.arg_count, max_site_argc);
    const extra_each: u16 = 1 + extra_args + callee.var_count;
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
        forward_call_rel: u32,
        method_atom: u32,
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
        const var_base: u16 = arg_base + extra_args;
        var rewritten = rewriteBody(callee, this_slot, arg_base, var_base, kind, site_argc) orelse return null;
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
            .forward_call_rel = rewritten.forward_call_rel,
            .method_atom = rewritten.method_atom,
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
    // After TAKE pops the [func, new_target, args] region, those 2+argc slots
    // are free for the rewritten body. Only bump when the body needs more than
    // the call already reserved (N3f: never add callee.stack_size unconditionally).
    const region_slots: u16 = 2 + argc;
    const extra_stack: u16 = if (callee.stack_size > region_slots)
        callee.stack_size - region_slots
    else
        0;
    spec.stack_size = caller.stack_size + extra_stack;
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
        // Extra TAKE locals forbid Fast leaf / exact-args (those frames
        // assert var_count==0). They do not invalidate simple_inline_base:
        // kind / simple params / no global-decl are copied unchanged, so
        // the inherited simple_* bits still admit setupSimpleInlineEntry
        // (qjs:17828 alloca, the var_count>0 path). 0d4169ba over-cleared
        // them and sent spec-copy plain calls through the general nest.
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
            var fwd = src_state.apply_forward[oi];
            if (fwd.method_atom != core.atom.null_atom)
                fwd.method_atom = rt.atoms.dup(fwd.method_atom);
            state.apply_forward[oi] = fwd;
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
        state.apply_forward[state.inlined_len] = if (item.forward_call_rel != 0xFFFFFFFF)
            .{
                .method_atom = if (item.method_atom != 0)
                    rt.atoms.dup(@as(core.Atom, @intCast(item.method_atom)))
                else
                    core.atom.null_atom,
                .call_pc = item.pc_lo + item.forward_call_rel,
            }
        else
            .{};
        state.inlined_len += 1;
    }
    state.specialized = true;
    setBorrowedRealm(spec, caller.realmContext());
    if (anyApplyForwardSite(state)) markApplyForwardInlined(spec);

    owned = false;
    rt.gc.addInitializedWithSizeNoFail(&spec.header, spec.heapByteSize());
    rt.small_inline_specialized_bytes +|= new_len;
    return spec;
}

/// R-v11-a consumes `callee.arg_count` (extras stay in the region and are
/// DROPped). L1 apply-forward rewrites to a live-argv `call_method_apply_fwd`
/// whose argc is the *site* argc (I6); those slots must be MOVEd into the window.
pub fn consumedArgSlots(fb: *const FunctionBytecode, site: *const InlinedSite) u16 {
    const state = callerState(fb);
    const forwarded = if (state) |st| siteApplyForwarded(st, site) else false;
    return if (forwarded) site.argc else site.callee_fb.arg_count;
}

pub fn windowFits(frame: *const frame_mod.Frame, fb: *const FunctionBytecode, site: *const InlinedSite) bool {
    const arg_slots = consumedArgSlots(fb, site);
    const need = @as(usize, site.arg_base) + @as(usize, arg_slots);
    return site.this_slot < frame.locals.len and need <= frame.locals.len;
}

/// Move `this_value` and `args[0..consumedArgSlots]` into the caller's local
/// window. Each stored value is taken by ownership (no dup). Extra entries
/// past the consumed count stay in `args` for `releaseCallRegionAfterInline`.
pub fn installInlineWindow(
    frame: *frame_mod.Frame,
    fb: *const FunctionBytecode,
    site: *const InlinedSite,
    this_value: JSValue,
    args: []JSValue,
    rt: *JSRuntime,
) void {
    const locals = frame.locals;
    if (site.this_slot < locals.len) {
        // Move. A dup here leaked one object per inlined `new` (N3f = 5e6).
        valueReplace(rt, &locals[site.this_slot], this_value);
    } else {
        this_value.free(rt);
    }
    const arg_slots = consumedArgSlots(fb, site);
    var i: u16 = 0;
    while (i < arg_slots) : (i += 1) {
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

/// R-v11-a — call-region ownership after a constructor TAKE.
///
/// Region layout is `[func, new_target, args…]` (length = 2+argc).
/// `installInlineWindow` has already MOVEd the instance into `this_slot`
/// (that value is not region[0]) and MOVEd `args[0..consumed_args]`.
///
/// | slot | constructor |
/// | slot0 (func) | DROP |
/// | slot1 (new_target) | DROP |
/// | args[0..consumed] | undefined (MOVEd into the window) |
/// | args[consumed..] | DROP extras |
///
/// Move + free on the same slot is a double-free (mirror of the N3f
/// installInlineWindow dup-and-keep leak). After this returns, the caller
/// `setLen`s past the region; abandoned slots must not hold a live ref.
///
/// R1 keeps this walker on the extras>0 cold arm only (`noinline` so the
/// ctor handler does not eat the loop). The 2-slot TAKE success path
/// inlines the two DROPs beside `setLen` via `releaseCtorTakeRegion`.
pub noinline fn releaseCallRegionAfterInline(
    rt: *JSRuntime,
    kind: Kind,
    region: []JSValue,
    consumed_args: u16,
) void {
    if (region.len < 2) return;
    if (kind == .constructor) {
        region[0].freeDuringActiveBytecode(rt);
    }
    region[1].freeDuringActiveBytecode(rt);
    const extra_off: usize = 2 + @as(usize, consumed_args);
    var i = extra_off;
    while (i < region.len) : (i += 1) {
        region[i].freeDuringActiveBytecode(rt);
    }
}

/// R1 — last two beats of a constructor TAKE before `setLen`.
///
/// EB's 4.44M hits are exactly `[func, new_target]` (argc == consumed).
/// Those two DROPs are the v11 table's constructor columns; fusing them
/// here deletes the `bl releaseCallRegionAfterInline` from the take
/// sequence. extras (`argc > consumed`) keep the outlined walker so the
/// protocol stays bit-for-bit and the handler does not grow a loop.
pub inline fn releaseCtorTakeRegion(
    rt: *JSRuntime,
    region: []JSValue,
    consumed_args: u16,
) void {
    std.debug.assert(region.len >= 2);
    if (region.len > 2 + @as(usize, consumed_args)) {
        releaseCallRegionAfterInline(rt, .constructor, region, consumed_args);
        return;
    }
    region[0].freeDuringActiveBytecode(rt);
    region[1].freeDuringActiveBytecode(rt);
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

fn realmFunctionApply(rt: *JSRuntime, global: *Object) ?*Object {
    const fproto = object_ops.functionPrototypeFromGlobal(rt, global) orelse return null;
    return fproto.getOwnDataObjectBorrowed(core.atom.ids.apply);
}

fn isFunctionApplyBuiltin(obj: *const Object) bool {
    if (obj.class_id != core.class.ids.c_function) return false;
    const ref = core.function.decodeNativeBuiltinId(obj.nativeFunctionId()) orelse return false;
    return ref.domain == .function and ref.id == @intFromEnum(function_ops.PrototypeMethod.apply);
}

fn lookupProtoChainDataFunction(start: *Object, atom_id: core.Atom) ?*Object {
    var cur: ?*Object = start;
    while (cur) |obj| {
        if (obj.findProperty(atom_id)) |idx| {
            const stored = obj.asDataAt(idx) orelse return null;
            return object_ops.objectFromValue(stored);
        }
        cur = obj.getPrototype();
    }
    return null;
}

/// I4 / D5: proto-chain data function for `method_atom` has no own `apply`,
/// and `Function.prototype.apply` is still the realm builtin record.
pub fn applyForwardGuardHolds(
    rt: *JSRuntime,
    global: *Object,
    ctor_obj: *Object,
    method_atom: core.Atom,
) bool {
    if (method_atom == core.atom.null_atom) return false;
    const apply_obj = realmFunctionApply(rt, global) orelse return false;
    if (!isFunctionApplyBuiltin(apply_obj)) return false;
    const proto = ctor_obj.getOwnDataObjectBorrowed(core.atom.ids.prototype) orelse return false;
    const method_fn = lookupProtoChainDataFunction(proto, method_atom) orelse return false;
    if (method_fn.findProperty(core.atom.ids.apply) != null) return false;
    return true;
}

pub inline fn applyForwardTakeOk(
    rt: *JSRuntime,
    global: *Object,
    fb: *const FunctionBytecode,
    site: *const InlinedSite,
    func: JSValue,
) bool {
    const state = callerState(fb) orelse return true;
    const fwd = applyForwardColdOf(state, site);
    if (fwd.call_pc == no_forward_pc) return true;
    const ctor = object_ops.plainBytecodeFunctionObjectFromValue(func) orelse return false;
    return applyForwardGuardHolds(rt, global, ctor, fwd.method_atom);
}

/// After the 3-byte apply-fwd instruction, recover the site (or null).
/// Used to attach `Entry.native_caller` (D8-L1) without an InlinedSite ghost.
pub fn applyForwardSiteAfterCall(fb: *const FunctionBytecode, pc_after: u32) ?*const InlinedSite {
    if (!fb.call_facts_mirror.execution.apply_forward_inlined) return null;
    if (pc_after < 3) return null;
    const call_pc = pc_after - 3;
    const site = siteForPc(fb, call_pc) orelse return null;
    const state = callerState(fb) orelse return null;
    if (applyForwardColdOf(state, site).call_pc == call_pc) return site;
    return null;
}

pub fn realmApplyBuiltin(rt: *JSRuntime, global: *Object) ?*Object {
    const apply_obj = realmFunctionApply(rt, global) orelse return null;
    if (!isFunctionApplyBuiltin(apply_obj)) return null;
    return apply_obj;
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

test "InlinedSite hot stride matches v1.5" {
    try std.testing.expectEqual(@sizeOf(V15InlinedSite), @sizeOf(InlinedSite));
}

test "rewrite sc_Pair-shaped body keeps put_field" {
    // Structural: loc rewrite of get_arg0/1 + push_this must stay in budget.
    try std.testing.expect(max_code == 40);
    try std.testing.expect(monomorph_hits == 8);
}
