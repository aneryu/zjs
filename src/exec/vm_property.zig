//! Bytecode property/global/local/var-ref decoding and guarded fast paths.
//!
//! Operand values are borrowed while frame-rooted; result structs name whether
//! a returned value is borrowed or owned, and `Owned` stores transfer their
//! input. Generic proxy/coercion/property behavior stays in the slower owning
//! exec modules. Preserve the dedicated hot probes and fused dispatch arms:
//! they discharge representation guards before raw slot access rather than
//! sharing cold fallback code. QuickJS coordinates include dense array reads
//! at quickjs.c:9047-9049 and integer-atom lookup at quickjs.c:12005.

const std = @import("std");
const bytecode = @import("../bytecode.zig");

// F0b: the runtime matchers below keep their one-byte-compare shape (P1-1)
// -- what changes is where the numbers come from. Burned-in operand values
// and next_pc increments are derived from the declaration at comptime, so
// the generated code is identical and a drifted declaration is a compile
// error instead of a silent mis-decode.
const Form = bytecode.opcode.logical.LogicalOpcode;
comptime {
    // The sequence matchers (`canFinishUndefinedCompletionTail` and
    // friends) walk adjacent instructions with `pc + 1` steps. That is
    // only sound while every form they step over is one byte; this turns
    // the assumption into a build error.
    for ([_]Form{ .put_loc0, .get_loc0, .undefined, .drop, .return_undef, .return_async }) |f| {
        if (bytecode.opcode.decode.sizeOfForm(f) != 1)
            @compileError("sequence matcher step is no longer one byte: " ++ @tagName(f));
    }
}
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const property_direct = @import("property_direct.zig");
const call_runtime = @import("call_runtime.zig");
const object_ops = @import("object_ops.zig");
const slot_ops = @import("slot_ops.zig");

const globalDataPropertyValueForFastPath = property_direct.globalDataPropertyValueForFastPath;

const op = bytecode.opcode.op;

pub const Step = enum { done, continue_loop };

const FieldAtom = struct {
    atom: core.Atom,
    next_pc: usize,
};

pub fn decodeFieldAtom(code: []const u8, pc: usize, expected_op: u8) ?FieldAtom {
    comptime {
        // Callers pass get_field-family ops; the hard-coded stride is only
        // sound while the whole family is atom-sized.
        for ([_]Form{ .get_field, .get_field2, .put_field }) |f| {
            if (bytecode.opcode.decode.sizeOfForm(f) != 5)
                @compileError("decodeFieldAtom stride is stale for " ++ @tagName(f));
        }
    }
    if (pc + 5 > code.len or code[pc] != expected_op) return null;
    return .{
        .atom = readInt(u32, code[pc + 1 ..][0..4]),
        .next_pc = pc + 5,
    };
}

pub fn globalVarAtom(function: *const bytecode.FunctionBytecode, idx: u16) ?core.Atom {
    if (idx < function.closureVar().len) return function.closureVar()[idx].var_name;
    if (idx >= function.varRefNamesLen()) return null;
    return function.varRefName(idx);
}

pub fn varRefReadableBorrowed(frame: *const frame_mod.Frame, idx: u16) ?core.JSValue {
    if (idx >= frame.var_refs.len) return null;
    // Slot is a cell by type (phase D); its value is plain by the terminal
    // invariant (guard #7 retired — the direct-eval const view pvalue-aliases
    // its target instead of nesting).
    const cell = slot_ops.varRefSlotCell(frame, idx);
    // Deleted binding = cell parked at UNINITIALIZED; the check below covers it.
    const value = cell.varRefValue();
    if (value.isUninitialized()) return null;
    return value;
}

fn canFinishUndefinedCompletionTail(function: *const bytecode.FunctionBytecode, pc: usize) bool {
    if (function.isGenerator() or function.isAsync()) return false;
    const code = function.byteCode();
    if (pc + 4 == code.len and
        code[pc] == op.put_loc0 and
        code[pc + 1] == op.undefined and
        code[pc + 2] == op.put_loc0 and
        code[pc + 3] == op.get_loc0) return true;
    if (pc + 3 == code.len and
        code[pc] == op.undefined and
        code[pc + 1] == op.put_loc0 and
        code[pc + 2] == op.get_loc0) return true;
    if (pc + 2 == code.len and
        code[pc] == op.undefined and
        code[pc + 1] == op.put_loc0) return true;
    if (pc + 2 == code.len and
        code[pc] == op.put_loc0 and
        code[pc + 1] == op.get_loc0) return true;
    return false;
}

pub fn fastInstalledGlobalDataValueForAtomAtPc(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    site_pc: usize,
    atom_id: core.Atom,
) ?core.JSValue {
    if (!canUseInstalledGlobalDataIc(ctx, function, atom_id, frame, global)) return null;
    if (functionFrameBindingShadowsGlobal(ctx.runtime, function, frame, atom_id)) return null;
    if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |_| {
        return null;
    }
    return globalDataPropertyValueForFastPath(ctx.runtime, global, function, site_pc, atom_id);
}

// --- With-statement and reference opcode handlers moved to vm_property_ref.zig ---
const vm_property_ref = @import("vm_property_ref.zig");

pub fn hasObjectBinding(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    receiver: core.JSValue,
    object: *core.Object,
    atom_id: core.Atom,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !bool {
    return object_ops.hasValueProperty(ctx, output, global, receiver, object, atom_id, function, frame);
}

// --- Private-field opcode handlers moved to vm_property_private.zig ---
const vm_property_private = @import("vm_property_private.zig");

pub fn canUseFastGlobalVarLookup(
    function: *const bytecode.FunctionBytecode,
    atom_id: core.Atom,
    frame: *const frame_mod.Frame,
) bool {
    if (atom_id == core.atom.ids.undefined_ or atom_id == core.atom.ids.arguments) return false;
    if (frameHasVarRefBinding(function, frame, atom_id)) return false;
    return true;
}

pub fn canUseInstalledGlobalDataIc(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    atom_id: core.Atom,
    frame: *const frame_mod.Frame,
    global: *const core.Object,
) bool {
    if (atom_id == core.atom.ids.undefined_ or atom_id == core.atom.ids.arguments) return false;
    if (frameHasVarRefBinding(function, frame, atom_id)) return false;
    _ = global;
    if (ctx.lexicals) |env| {
        if (env.hasOwnProperty(atom_id)) return false;
    }
    return true;
}

pub fn functionFrameBindingShadowsGlobal(rt: *core.JSRuntime, function: *const bytecode.FunctionBytecode, frame: *const frame_mod.Frame, atom_id: core.Atom) bool {
    if (call_runtime.atomIdOrNameEql(rt, function.funcName(), atom_id)) return true;
    if (functionHasDynamicScopeBindings(function, frame)) return true;
    if (functionLocalOrArgBindingShadowsGlobal(rt, function, frame, atom_id)) return true;
    return false;
}

fn functionHasDynamicScopeBindings(function: *const bytecode.FunctionBytecode, frame: *const frame_mod.Frame) bool {
    if (function.legacyBytecodeAdapter() == null and frame.var_refs.len != 0) {
        std.debug.assert(frame.var_refs.len == function.closureVar().len);
    }
    return function.varRefNamesLen() != 0 or frame.var_refs.len != 0;
}

fn functionLocalOrArgBindingShadowsGlobal(rt: *core.JSRuntime, function: *const bytecode.FunctionBytecode, frame: *const frame_mod.Frame, atom_id: core.Atom) bool {
    const arg_count = @min(function.argVarDefs().len, frame.args.len);
    for (function.argVarDefs()[0..arg_count]) |arg| {
        if (call_runtime.atomIdOrNameEql(rt, arg.var_name, atom_id)) return true;
    }
    const local_count = @min(function.varDefs().len, frame.locals.len);
    for (function.varDefs()[0..local_count]) |vd| {
        if (call_runtime.atomIdOrNameEql(rt, vd.var_name, atom_id)) return true;
    }
    return false;
}

pub fn canFuseGlobalDataWrite(
    function: *const bytecode.FunctionBytecode,
    frame: *const frame_mod.Frame,
    atom_id: core.Atom,
) bool {
    if (atom_id == core.atom.ids.undefined_ or atom_id == core.atom.ids.arguments) return false;
    if (frameHasVarRefBinding(function, frame, atom_id)) return false;
    return true;
}

pub fn frameHasVarRefBinding(function: *const bytecode.FunctionBytecode, frame: *const frame_mod.Frame, atom_id: core.Atom) bool {
    const count = @min(frame.var_refs.len, function.varRefNamesLen());
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const name = function.varRefName(idx);
        if (name == atom_id) return true;
    }
    return false;
}

pub fn fastDenseArrayElementValue(value: core.JSValue, key: core.JSValue) ?core.JSValue {
    const index_i32 = key.asInt32() orelse return null;
    if (index_i32 < 0) return null;
    const object = objectFromValue(value) orelse return null;
    const index: u32 = @intCast(index_i32);
    return object.fastArrayElementDup(index);
}

/// qjs's JS_GetPropertyValue switches on class_id, and JS_CLASS_MAPPED_ARGUMENTS
/// sits right beside the ARRAY/ARGUMENTS arms with its own cell-dereferencing
/// read (quickjs.c:9047-9049). `fastDenseArrayElementValue` covers ARRAY and
/// UNMAPPED arguments — both store JSValues inline — while a mapped arguments
/// object stores JSVarRef pointers in the same union, so it needs a separate arm
/// rather than a widened bounds check.
///
/// Kept as its own entry point instead of a tail on the dense reader: that
/// reader has six callers, and growing it moved enough code to cost 26% cycles
/// on a plain-call benchmark that never reads an element at all (instructions
/// unchanged — pure layout). Only the hot `OP_get_array_el` handler pays the
/// extra probe.
pub noinline fn fastMappedArgumentsElementValue(value: core.JSValue, key: core.JSValue) ?core.JSValue {
    const index_i32 = key.asInt32() orelse return null;
    if (index_i32 < 0) return null;
    const object = objectFromValue(value) orelse return null;
    return object.mappedArgumentsElementDup(@intCast(index_i32));
}

/// Own integer-element read for a NON-fast (sparse/slow) Array — the leg after
/// fastDenseArrayElementValue misses. qjs JS_GetPropertyValue's JS_CLASS_ARRAY
/// arm, when `idx >= u.array.count`, routes to JS_GetPropertyInternal with the
/// int atom (quickjs.c:12005 / __JS_AtomFromUInt32); a slow array holds its
/// elements as ordinary int-atom shape properties, so the overwhelmingly common
/// case (sparse-array element, crypto BigInteger digit) is an own plain-data
/// property that find_own_property resolves without a prototype walk. Read it
/// inline so the hot handler skips the cold_table -> arrayElement chain, which
/// otherwise re-tries the dense/string/typed fast paths and re-derives this same
/// int atom through toPropertyKeyAtom (two non-inlined calls + a defer-free).
/// A hole / accessor / prototype-only element returns null and falls through to
/// the full slow path; gating on isArray keeps mapped-arguments (live-cell
/// overlay) and other exotics on the exact getValueProperty ordering.
pub fn fastArrayOwnIntElementValue(value: core.JSValue, key: core.JSValue) ?core.JSValue {
    const index_i32 = key.asInt32() orelse return null;
    if (index_i32 < 0) return null;
    const object = objectFromValue(value) orelse return null;
    if (!object.isArray()) return null;
    return object.getOwnDataPropertyValue(core.atom.atomFromUInt32(@intCast(index_i32)));
}

/// Own integer-element OVERWRITE for a NON-fast (sparse/slow) Array — the write
/// twin of fastArrayOwnIntElementValue. qjs JS_SetPropertyValue's JS_CLASS_ARRAY
/// arm, when `idx >= u.array.count`, routes to JS_SetPropertyInternal with the
/// int atom; for an existing own writable data element (the slow array holds its
/// elements as int-atom shape properties) that resolves to one find_own_property
/// + set_value on the slot. setOwnWritableDataProperty is exactly that primitive
/// — it returns false for a missing (new) element, a non-writable/accessor slot,
/// or module_ns, all of which need the full JS_SetPropertyInternal semantics
/// (length growth, strict-mode throw, setter call) and so fall through to cold.
/// The value is borrowed: the helper dups into the slot when refcounted, and the
/// hot caller frees its own operand ref exactly as the dense leg does. Gating on
/// isArray keeps mapped-arguments and other exotics on the exact set path.
pub fn fastArrayOwnIntElementSet(rt: *core.JSRuntime, value: core.JSValue, key: core.JSValue, new_value: core.JSValue) !bool {
    const index_i32 = key.asInt32() orelse return false;
    if (index_i32 < 0) return false;
    const object = objectFromValue(value) orelse return false;
    if (!object.isArray()) return false;
    return object.setOwnWritableDataProperty(rt, core.atom.atomFromUInt32(@intCast(index_i32)), new_value);
}

const objectFromValue = core.value_semantics.objectFromValueTrustedExpression;

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

// --- Global variable read/write/define opcode handlers moved to vm_property_globals.zig ---
const vm_property_globals = @import("vm_property_globals.zig");

// --- Local/arg/var-ref slot opcode handlers moved to vm_property_locals.zig ---
const vm_property_locals = @import("vm_property_locals.zig");

// --- Property field and array-element opcode handlers moved to vm_property_field.zig ---
const vm_property_field = @import("vm_property_field.zig");
