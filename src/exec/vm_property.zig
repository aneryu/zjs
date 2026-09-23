//! Bytecode property/global/local/var-ref decoding and guarded fast paths.
//!
//! Operand values are borrowed while frame-rooted; result structs name whether
//! a returned value is borrowed or owned, and `Owned` stores transfer their
//! input. Generic proxy/coercion/property behavior stays in the slower owning
//! exec modules. Preserve the dedicated hot probes and fused dispatch arms:
//! they discharge representation guards before raw slot access rather than
//! sharing cold fallback code. QuickJS coordinates include dense array reads
//! at quickjs.c and integer-atom lookup at quickjs.c.

const std = @import("std");
const bytecode = @import("../bytecode.zig");

// F0b: the runtime matchers below keep their one-byte-compare shape (P1-1)
// -- what changes is where the numbers come from. Burned-in operand values
// and next_pc increments are derived from the declaration at comptime, so
// the generated code is identical and a drifted declaration is a compile
// error instead of a silent mis-decode.
const Form = bytecode.opcode.logical.LogicalOpcode;
comptime {
    // Completion-tail sequences walk adjacent instructions with
    // `pc + 1` steps. That is
    // only sound while every form they step over is one byte; this turns
    // the assumption into a build error.
    for ([_]Form{ .put_loc0, .get_loc0, .undefined, .drop, .return_undef, .return_async }) |f| {
        if (bytecode.opcode.decode.sizeOfForm(f) != 1)
            @compileError("sequence matcher step is no longer one byte: " ++ @tagName(f));
    }
}
const core = @import("../core/root.zig");
const frame_mod = @import("frame.zig");
const property_direct = @import("property_ops.zig");
const call_runtime = @import("call_runtime.zig");
const object_ops = @import("object_ops.zig");
const slot_ops = @import("property_ops.zig");

const globalDataPropertyValueForFastPath = property_direct.globalDataPropertyValueForFastPath;
const dispatch = @import("tailcall_dispatch.zig");
const Vm = dispatch.Vm;
const HostError = @import("exception_ops.zig").HostError;

pub const Step = enum { done, continue_loop };

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
    if (value.is(.uninitialized)) return null;
    return value;
}

pub fn fastInstalledGlobalDataValueForAtomAtPc(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    site_pc: usize,
    atom_id: core.Atom,
) ?core.JSValue {
    if (!canUseInstalledGlobalDataIc(ctx, function, atom_id, frame)) return null;
    if (functionFrameBindingShadowsGlobal(ctx.runtime, function, frame, atom_id)) return null;
    if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |_| {
        return null;
    }
    return globalDataPropertyValueForFastPath(ctx.runtime, global, function, site_pc, atom_id);
}

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
) bool {
    if (atom_id == core.atom.ids.undefined_ or atom_id == core.atom.ids.arguments) return false;
    if (frameHasVarRefBinding(function, frame, atom_id)) return false;
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
    if (frame.var_refs.len != 0) {
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
    for (0..count) |idx| {
        const name = function.varRefName(idx);
        if (name == atom_id) return true;
    }
    return false;
}

pub fn fastDenseArrayElementValue(value: core.JSValue, key: core.JSValue) ?core.JSValue {
    const index_i32 = key.as(.int) orelse return null;
    if (index_i32 < 0) return null;
    const object = objectFromValue(value) orelse return null;
    const index: u32 = @intCast(index_i32);
    return object.fastArrayElementDup(index);
}

/// qjs's JS_GetPropertyValue switches on class_id, and JS_CLASS_MAPPED_ARGUMENTS
/// sits right beside the ARRAY/ARGUMENTS arms with its own cell-dereferencing
/// read. `fastDenseArrayElementValue` covers ARRAY and
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
    const index_i32 = key.as(.int) orelse return null;
    if (index_i32 < 0) return null;
    const object = objectFromValue(value) orelse return null;
    return object.mappedArgumentsElementDup(@intCast(index_i32));
}

/// Own integer-element read for a NON-fast (sparse/slow) Array — the leg after
/// fastDenseArrayElementValue misses. qjs JS_GetPropertyValue's JS_CLASS_ARRAY
/// arm, when `idx >= u.array.count`, routes to JS_GetPropertyInternal with the
/// int atom (quickjs.c / __JS_AtomFromUInt32); a slow array holds its
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
    const index_i32 = key.as(.int) orelse return null;
    if (index_i32 < 0) return null;
    const object = objectFromValue(value) orelse return null;
    if (!object.isArray()) return null;
    return object.getOwnDataPropertyValue(core.Atom.taggedInt(@intCast(index_i32)));
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
    const index_i32 = key.as(.int) orelse return false;
    if (index_i32 < 0) return false;
    const object = objectFromValue(value) orelse return false;
    if (!object.isArray()) return false;
    return object.setOwnWritableDataProperty(rt, core.Atom.taggedInt(@intCast(index_i32)), new_value);
}

const objectFromValue = core.value_semantics.objectFromValueTrustedExpression;

// ----- merged from vm_property_field.zig -----
// Property field and array-element opcode handlers (get/put_field, get/put_array_el, in/instanceof, to_prop_key).
const builtin = @import("builtin");
const method_ids = core.host_function.builtin_method_ids;
const property_ops = @import("property_ops.zig");
const stack_mod = @import("stack.zig");
const array_ops = @import("array_ops.zig");
const forof_ops = @import("iterator_ops.zig");
const string_ops = @import("string_ops.zig");
const readInt = call_runtime.readInt;
fn PoppedWindow(comptime n: usize) type {
    return struct {
        slots: [n]core.JSValue = undefined,
        /// Slice header over `slots`, so the frame roots the array as a
        /// MUTABLE window: a visitor that relocates a body writes the new
        /// address back into the slot this window will hand to the caller.
        slot_view: []core.JSValue = &.{},
        slices: [1]core.runtime.ValueRootSlice = undefined,
        frame: core.runtime.ValueRootFrame = .{},

        inline fn activate(self: *@This(), rt: *core.JSRuntime, values: [n]core.JSValue) void {
            if (comptime !core.runtime.value_root_frames_enabled) return;
            self.slots = values;
            self.slot_view = self.slots[0..];
            self.slices[0] = .{ .mutable = &self.slot_view };
            self.frame.slices = &self.slices;
            self.frame.activate(rt);
        }

        inline fn deactivate(self: *@This(), rt: *core.JSRuntime) void {
            self.frame.deactivate(rt);
        }
    };
}

// Helpers that remain in zig (shared with the leftover handlers).
const functionOwnDataPropertyValueForFastPath = property_direct.functionOwnDataPropertyValueForFastPath;
const dataPropertyValueForFastPath = property_direct.dataPropertyValueForFastPath;
const ordinaryDataPropertyValueOrUndefinedForFastPath = property_direct.ordinaryDataPropertyValueOrUndefinedForFastPath;
const op = bytecode.opcode.op;
const atom_byte_length = core.atom.predefinedId("byteLength", .string).?;
const atom_byte_offset = core.atom.predefinedId("byteOffset", .string).?;
pub fn toPropKey(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    const value = try stack.pop();
    const key = try object_ops.toPropertyKeyValue(ctx, output, global, value, function, frame);
    try stack.pushOwned(key);
}

pub noinline fn toPropKeyVm(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    toPropKey(ctx, output, global, stack, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    return .done;
}

pub noinline fn setName(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    opc: u8,
) !void {
    switch (opc) {
        op.set_name => {
            const atom_id = core.Atom.fromRaw(readInt(u32, function.byteCode()[frame.pc..][0..4]));
            frame.pc += 4;
            if (stack.len() == 0) return error.StackUnderflow;
            const value = try stackValueFromTop(stack, 0);
            if (value.is(.object)) {
                const object = try property_ops.expectObject(value);
                const name_value = try call_runtime.functionNameValueFromAtom(ctx.runtime, atom_id, null);
                try object_ops.defineFunctionNameProperty(ctx.runtime, object, name_value);
            }
        },
        op.set_name_computed => {
            if (stack.len() < 2) return error.StackUnderflow;
            const value = stack.values[stack.len() - 1];
            const key = stack.values[stack.len() - 2];
            if (value.is(.object)) {
                const object = try property_ops.expectObject(value);
                const atom_id = try object_ops.toPropertyKeyAtom(ctx, output, global, key, function, frame);
                const name_value = try call_runtime.functionNameValueFromAtom(ctx.runtime, atom_id, null);
                try object_ops.defineFunctionNameProperty(ctx.runtime, object, name_value);
            }
        },
        else => unreachable,
    }
}

pub noinline fn inOrInstanceof(vm: *Vm, opc: u8) HostError!void {
    const err = if (opc == op.in)
        call_runtime.inOp(vm.ctx, vm.stack, vm.output, vm.global, vm.function, vm.frame)
    else
        call_runtime.instanceofOp(vm.ctx, vm.stack, vm.output, vm.global, vm.function, vm.frame);
    err catch |runtime_err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, runtime_err)) return;
        return runtime_err;
    };
}

pub noinline fn field(vm: *Vm, opc: u8) align(16) HostError!void {
    const ctx = vm.ctx;
    const output = vm.output;
    const global = vm.global;
    const stack = vm.stack;
    const function = vm.function;
    const frame = vm.frame;
    const catch_target = vm.catch_target;
    const atom_id = core.Atom.fromRaw(readInt(u32, function.byteCode()[frame.pc..][0..4]));
    // W1: every opcode routed here is `atom_cache_u8` (atom u32 + cache_idx
    // u8), so the operand region is five bytes. The cold shell answers
    // generically; capture lives in the resident handlers' miss leg.
    frame.pc += 5;
    switch (opc) {
        op.get_field, op.get_field_field2 => {
            if (stack.len() == 0) return error.StackUnderflow;
            const top_index = stack.len() - 1;
            const receiver = stack.values[top_index];
            if (dataPropertyValueForFastPath(ctx.runtime, receiver, atom_id)) |value| {
                replaceTopBorrowed(ctx.runtime, stack, top_index, receiver, value);
                return;
            }
            // The `getFieldFast` shape walk that used to sit here is gone: it
            // is the SAME walk the resident `op_get_field` already ran
            // (`getFieldFastSlotOrAbsent`, tailcall_dispatch.zig) — this
            // shell is only ever reached THROUGH that handler's miss (see the
            // `cold_table` note: the all-cold table is the fast handlers' miss
            // target, never a primary dispatch table). The resident probe runs
            // with `trust_non_private_atom = true`, so its admission set is a
            // superset of this one's; a miss there is a guaranteed miss here.
            // Same shape as the `h_put_var` cell arm removal above. qjs's
            // GET_FIELD_INLINE window likewise runs once per access and drops
            // straight into JS_GetPropertyInternal.
            if (ordinaryDataPropertyValueOrUndefinedForFastPath(ctx.runtime, receiver, atom_id)) |value| {
                replaceTopBorrowed(ctx.runtime, stack, top_index, receiver, value);
                return;
            }
            if (fastRegExpPrototypeMethodValue(ctx.runtime, receiver, atom_id)) |value| {
                replaceTopOwned(ctx.runtime, stack, top_index, receiver, value);
                return;
            }
            if (functionOwnDataPropertyValueForFastPath(receiver, atom_id)) |value| {
                replaceTopOwned(ctx.runtime, stack, top_index, receiver, value);
                return;
            }
            if (fastCollectionPrototypeMethodValue(ctx.runtime, receiver, atom_id)) |value| {
                replaceTopOwned(ctx.runtime, stack, top_index, receiver, value);
                return;
            }
            stack.setLen(top_index);
            const obj = receiver;
            const value = object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                try forof_ops.closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            };
            stack.pushOwnedAssumeCapacity(value);
        },
        op.get_field2, op.get_field2_call_method => {
            const obj = try stackValueFromTop(stack, 0);
            if (dataPropertyValueForFastPath(ctx.runtime, obj, atom_id)) |value| {
                stack.pushAssumeCapacity(value);
                return;
            }
            // Removed for the same reason as the get_field arm above: the
            // resident `op_get_field2` already ran this exact walk and tailed
            // here only because it missed.
            if (ordinaryDataPropertyValueOrUndefinedForFastPath(ctx.runtime, obj, atom_id)) |value| {
                stack.pushAssumeCapacity(value);
                return;
            }
            if (fastRegExpPrototypeMethodValue(ctx.runtime, obj, atom_id)) |value| {
                stack.pushOwnedAssumeCapacity(value);
                return;
            }
            if (functionOwnDataPropertyValueForFastPath(obj, atom_id)) |value| {
                stack.pushOwnedAssumeCapacity(value);
                return;
            }
            if (fastCollectionPrototypeMethodValue(ctx.runtime, obj, atom_id)) |value| {
                stack.pushOwnedAssumeCapacity(value);
                return;
            }
            const value = object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                try forof_ops.closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            };
            try stack.pushOwned(value);
        },
        op.put_field => {
            const value = try stack.pop();
            const obj = try stack.pop();
            if (setArrayLengthForPutFieldFastPath(ctx.runtime, obj, atom_id, value)) return;
            // Single-walk cold put (qjs OP_put_field's slow path is ONE call
            // into JS_SetPropertyInternal, quickjs.c ->
            // 9706-9890): one trusted own probe, one prototype walk, then
            // add_property. The old cascade here re-ran the same gates and
            // own probe up to four times per new-property write
            // (setObjectDataPropertyForPutFieldFastPath's guaranteed-miss
            // re-probe — the `pf_bail_missing == 2 * pf_cold` census
            // signature — then setValueProperty's own pair). The resident
            // `op_put_field` already ran `putFieldFastSlot` and tailed
            // here on its miss; field operand atoms are proven non-private
            // (debugAssertNonPrivateFieldOperandAtom), so no private probe.
            if (object_ops.objectFromValueTrustedExpression(obj)) |receiver| {
                debugAssertNonPrivateFieldOperandAtom(ctx.runtime, atom_id);
                // Owned contract: `.done` consumes `value`; `.slow` (decline
                // or rolled-back OOM) leaves it with the defer. The resolver
                // below is still `!T` and consumes on its own OOM.
                switch (receiver.setOrDefineOwnDataPropertyForPutFieldOwned(ctx.runtime, atom_id, value)) {
                    .done => return,
                    .slow => {},
                }
            }
            _ = object_ops.setValueProperty(ctx, output, global, obj, atom_id, value, function, frame) catch |err| {
                try forof_ops.closeStackTopForOfIteratorForPendingError(ctx, output, global, stack);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            };
        },
        else => unreachable,
    }
}

/// `.length` of a plain fast array (qjs OP_get_length / OP_get_array_length leg):
/// the element count as int32 (float64 above i32) for an own, non-exotic,
/// non-proxy array. Null for everything else — strings are handled by the
/// caller's string leg; exotic/subclassed arrays, typed arrays (not is_array),
/// and objects with a `length` getter fall to the cold getLength.
pub inline fn fastArrayLengthValue(value: core.JSValue) ?core.JSValue {
    const object = objectFromValue(value) orelse return null;
    if (!object.isArray() or object.hasExoticMethods() or object.proxyTarget() != null) return null;
    const len = object.arrayLength();
    if (len <= @as(u32, @intCast(std.math.maxInt(i32)))) return core.JSValue.int32(@intCast(len));
    return core.JSValue.float64(@floatFromInt(len));
}

/// Debug oracle for the trusted-atom entries below. The precise claim (kind,
/// not the imprecise `mightBePrivate` id-range filter): a get_field/get_field2/
/// put_field/get_length atom operand never names a private atom. Proof chain:
/// every `.`/`?.` member site discriminates TOK_PRIVATE_NAME into the
/// scope_get/put_private_field family or a SyntaxError (parser.zig
/// parseMemberChain/parseNewCalleeMemberAccess), those scope ops lower only to
/// get/put_private_field/check_brand (bytecode.zig writeLoweredPrivateField),
/// object-property names reject TOK_PRIVATE_NAME (parseObjectPropertyName),
/// peepholes copy atoms from already-emitted field ops, and `internString`
/// can never mint a .private atom (kind-filtered predefinedId + .string
/// internDynamic). Mirrors qjs, whose OP_get_field operand is likewise
/// unreachable by JS_ATOM_TYPE_PRIVATE atoms (js_parse_postfix_expr routes
/// #name through OP_scope_get_private_field, quickjs.c, resolved at
/// 27574 into the OP_get_private_field family).
inline fn debugAssertNonPrivateFieldOperandAtom(rt: *const core.JSRuntime, atom_id: core.Atom) void {
    if (comptime builtin.mode == .Debug) {
        const kind = rt.atoms.kind(atom_id) orelse .string;
        std.debug.assert(kind != .private);
    }
}

inline fn getFieldFastSlotWithExoticOrder(
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
    comptime trust_mapped_arguments_probe: bool,
    comptime trust_non_private_atom: bool,
    comptime report_absent: bool,
    absent: *bool,
) ?*const core.JSValue {
    // Object-ness gate FIRST, mirroring qjs GET_FIELD_INLINE's leading
    // JS_VALUE_GET_TAG(obj)==JS_TAG_OBJECT check: a non-object
    // receiver (e.g. a string routed here from op_get_field2) returns immediately
    // without paying the private-atom probe. Two pure guards reordered.
    // Trusted-expression classification: the receiver came off the operand
    // stack as an expression value, so the header-kind re-load in the generic
    // objectFromValue is dead here (see objectFromValueTrustedExpression).
    var object = object_ops.objectFromValueTrustedExpression(receiver) orelse return null;
    // Bytecode atom operands are proven non-private at compile time (see
    // debugAssertNonPrivateFieldOperandAtom), exactly why qjs GET_FIELD_INLINE
    // carries no private-atom probe. Only the computed-key entry
    // (atomPropertyValueForFastPath), whose atoms come from runtime string
    // interning, still pays the range filter.
    if (comptime trust_non_private_atom) {
        debugAssertNonPrivateFieldOperandAtom(rt, atom_id);
    } else {
        if (rt.atoms.mightBePrivate(atom_id)) return null;
    }
    // The mapped-Arguments compensation only matters when the operand atom could
    // name one of the out-of-shape numeric bindings. Those bindings cover indices
    // [0, argc); argc is a u16 arg_count, so every binding atom interns as a
    // tagged-int atom (<= max_int_atom == 2^31-1). A named/symbol atom can never
    // alias a binding, so its shape slot is authoritative — exactly as in qjs,
    // whose find_own_property leans solely on the per-property TMASK/kind check.
    // Hoisting this loop-invariant decision keeps the common named-field walk (the
    // get_field / get_field2 hot path) off the per-object class test entirely; the
    // predicate comptime-folds to false for the get_length caller (trust=true).
    const probe_mapped_arguments = !trust_mapped_arguments_probe and atom_id.isTaggedInt();
    // Phase 1 — the absence-authoritative prefix (only compiled for callers that
    // ask for the tri-state). qjs ends its inline window at the chain root with
    // `p = p->shape->proto; if (!p) { val = JS_UNDEFINED; break; }`
    //, because there a shape miss on a non-exotic link
    // is the whole answer. After deleting the zjs-only class-name miss
    // fallback, a complete ordinary miss is also JS_UNDEFINED
    //. `undefined` is still synthesized only when EVERY
    // link walked was one of the two classes with no exotic miss behaviour —
    // plain `object` and the global object — matching the per-cursor admission
    // set of the out-of-line `property_direct.ordinaryDataPropertyLookup`. This
    // leg is a fusion of that walk into the handler, not a new semantic.
    //
    // Structured as a separate loop rather than a running "still ordinary" latch
    // so the own-hit path stays byte-identical to the two-state walk: a latch is
    // loop-carried and forces its initializer into the loop preheader, which the
    // depth-0 hit executes (measured: +2 insn/read on hit4..hit256 and del).
    // Crossing a non-authoritative link just falls into phase 2 below.
    if (comptime report_absent) {
        while (true) {
            // zjs-only divergence from qjs's probe-first order: mapped Arguments
            // numeric bindings live in out-of-shape var-ref cells, so a shape
            // data slot on a mapped Arguments object can be stale and its hit
            // cannot be trusted — bail before probing. (qjs stores those
            // bindings as JS_PROP_VARREF shape entries, which its own probe
            // rejects via JS_PROP_TMASK.) Only a tagged-int operand atom can
            // alias one of those numeric bindings; named atoms and the constant
            // `length` atom skip it.
            if (probe_mapped_arguments and object.class_id == core.class.ids.mapped_arguments) return null;
            var slow_property = false;
            if (object.findOwnDataSlotFast(atom_id, &slow_property)) |slot| return slot;
            if (slow_property) return null;
            // qjs GET_FIELD_INLINE consults `p->is_exotic` only AFTER the own
            // probe misses: an own plain-data hit — a
            // sparse array element, named data on a typed array, anything the
            // shape authoritatively owns — never pays the class test.
            //
            // For `object`/`global_object`, `classNeedsSlowPropertyAccess`
            // reduces exactly to the exotic-methods bit (neither class appears
            // in any of its slow arms), so an authoritative link costs one
            // compare plus one bit test instead of the whole class switch.
            // A NativeObject (NB2 §8.1, embedder class instance) is exactly as
            // ordinary as a plain object: no class exotics, only the shape.
            if (object.class_id == core.class.ids.object or object.isGlobal() or object.flags.is_native_object) {
                if (object.hasExoticMethods()) return null;
                object = object.getPrototype() orelse {
                    absent.* = true;
                    return null;
                };
                continue;
            }
            // qjs GET_FIELD_INLINE: `is_exotic` after
            // own miss, with an XXX to keep arrays off the slow path when
            // `prop` is not numeric. Array/Arguments exotic [[Get]] is index
            // + `length` only; a named non-index atom (bytecode `.push`) is
            // ordinary lookup, so keep the fast proto walk and stay
            // absence-authoritative. TypedArray / Proxy / String stay slow.
            if (namedAtomUsesOrdinaryWalkOnIndexExotic(object.class_id, atom_id)) {
                object = object.getPrototype() orelse {
                    absent.* = true;
                    return null;
                };
                continue;
            }
            // Non-authoritative link: it may still hold or inherit the property,
            // so keep walking — but absence can no longer be concluded from here
            // on, which is precisely phase 2's two-state contract.
            if (object.needsSlowPropertyAccess()) return null;
            object = object.getPrototype() orelse return null;
            break;
        }
    }
    // Phase 2 — the pre-existing two-state walk, verbatim. Reached directly by
    // the two-state callers and by phase 1 once a non-authoritative link has
    // been crossed. Running off the end here returns null (= "defer to the
    // resolver"), which now returns JS_UNDEFINED after the real proto walk.
    while (true) {
        if (probe_mapped_arguments and object.class_id == core.class.ids.mapped_arguments) return null;
        var slow_property = false;
        if (object.findOwnDataSlotFast(atom_id, &slow_property)) |slot| return slot;
        if (slow_property) return null;
        if (namedAtomUsesOrdinaryWalkOnIndexExotic(object.class_id, atom_id)) {
            object = object.getPrototype() orelse return null;
            continue;
        }
        if (object.needsSlowPropertyAccess()) return null;
        object = object.getPrototype() orelse return null;
    }
}

/// Array / unmapped Arguments / mapped Arguments are exotic only for
/// canonical numeric indices and `length`. A
/// named non-index atom cannot be an element or the length slot, so the
/// GET_FIELD_INLINE proto walk is semantically the same as for a plain
/// object. Tagged-int atoms cover the interned 0..2^31-1 index window;
/// `length` stays on the slow arm so the dense-array length scalar is
/// not skipped. TypedArray / Proxy / String objects are not included.
inline fn namedAtomUsesOrdinaryWalkOnIndexExotic(class_id: core.class.ClassId, atom_id: core.Atom) bool {
    if (atom_id.isTaggedInt() or atom_id == core.atom.ids.length) return false;
    return class_id == core.class.ids.array or
        class_id == core.class.ids.arguments or
        class_id == core.class.ids.mapped_arguments;
}

/// Borrowed own/prototype data slot for op_get_field / op_get_field2.
/// The pointer is valid until the next potentially shape-mutating operation;
/// callers consume it immediately (see findOwnDataSlotFast).
/// A null return now carries a discriminator: `absent.*` is set only when the
/// walk ran off the end of a chain whose every link was absence-authoritative
/// (see the terminal comment above), i.e. the property is genuinely missing and
/// the result is `undefined` — qjs GET_FIELD_INLINE's `if (!p) { val =
/// JS_UNDEFINED; break; }`. `absent.*` false keeps the
/// previous meaning: defer to the resolver. The caller must initialize it to
/// false; the walk only ever writes it on the chain-exhausted leg.
pub inline fn getFieldFastSlotOrAbsent(
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
    absent: *bool,
) ?*const core.JSValue {
    // Named bytecode atom: skip isTaggedInt / mapped-args (F2). Computed-key
    // `getFieldFast` keeps the tagged-int probe.
    return getFieldFastSlotWithExoticOrder(rt, receiver, atom_id, true, true, true, absent);
}

/// Continuation of the named-bytecode field walk after the resident handler
/// has already proved that the receiver has no own data slot and no own
/// unusual slot. Keeping this half separate prevents prototype/exotic
/// classification from being speculated into the dominant own-hit handler;
/// the property search and its ordering are otherwise the same as
/// `getFieldFastSlotOrAbsent`.
/// After the inline data walk stopped on a non-data slot: walk the ordinary
/// links (plain object / global / NativeObject, no exotics) from
/// `probed_object` and return the getter of the FIRST hit when that hit is an
/// accessor (undefined getter included). Null when the first hit is not an
/// accessor or the chain reaches a link the ordinary rules do not cover, so
/// the caller keeps its resolver path. Same admission set as
/// `property_direct.ordinaryDataPropertyLookup`; the receiver's own probe has
/// already been done by the caller.
pub fn ordinaryAccessorGetterAfterOwnMiss(probed_object: *core.Object, atom_id: core.Atom) ?core.JSValue {
    var object = probed_object;
    while (true) {
        if (object.hasExoticMethods()) return null;
        if (!(object.class_id == core.class.ids.object or object.isGlobal() or object.flags.is_native_object)) return null;
        if (object.findOwnPropertySlotTrusted(atom_id)) |lookup| {
            if (lookup.flags.deleted or lookup.flags.kind != .accessor) return null;
            return lookup.entry.slot.accessor.getterValue();
        }
        object = object.getPrototype() orelse return null;
    }
}

pub inline fn getFieldFastSlotOrAbsentAfterOwnMiss(
    rt: *core.JSRuntime,
    probed_object: *core.Object,
    atom_id: core.Atom,
    absent: *bool,
) ?*const core.JSValue {
    debugAssertNonPrivateFieldOperandAtom(rt, atom_id);

    var object = probed_object;
    // Classify the already-probed object before entering the ordinary
    // prototype loop. Only object/global and named Array/Arguments misses are
    // absence-authoritative; all other non-slow classes may still expose an
    // inherited data property, but running off their chain must defer to the
    // resolver rather than synthesize undefined here.
    if (object.class_id == core.class.ids.object or object.isGlobal()) {
        if (object.hasExoticMethods()) return null;
        object = object.getPrototype() orelse {
            absent.* = true;
            return null;
        };
    } else if (namedAtomUsesOrdinaryWalkOnIndexExotic(object.class_id, atom_id)) {
        object = object.getPrototype() orelse {
            absent.* = true;
            return null;
        };
    } else {
        if (object.needsSlowPropertyAccess()) return null;
        object = object.getPrototype() orelse return null;
        return getFieldFastSlotAfterNonAuthoritativeLink(object, atom_id);
    }

    while (true) {
        var slow_property = false;
        if (object.findOwnDataSlotFast(atom_id, &slow_property)) |slot| return slot;
        if (slow_property) return null;
        if (object.class_id == core.class.ids.object or object.isGlobal()) {
            if (object.hasExoticMethods()) return null;
            object = object.getPrototype() orelse {
                absent.* = true;
                return null;
            };
            continue;
        }
        if (namedAtomUsesOrdinaryWalkOnIndexExotic(object.class_id, atom_id)) {
            object = object.getPrototype() orelse {
                absent.* = true;
                return null;
            };
            continue;
        }
        if (object.needsSlowPropertyAccess()) return null;
        object = object.getPrototype() orelse return null;
        return getFieldFastSlotAfterNonAuthoritativeLink(object, atom_id);
    }
}

inline fn getFieldFastSlotAfterNonAuthoritativeLink(
    first: *core.Object,
    atom_id: core.Atom,
) ?*const core.JSValue {
    var object = first;
    while (true) {
        var slow_property = false;
        if (object.findOwnDataSlotFast(atom_id, &slow_property)) |slot| return slot;
        if (slow_property) return null;
        if (namedAtomUsesOrdinaryWalkOnIndexExotic(object.class_id, atom_id)) {
            object = object.getPrototype() orelse return null;
            continue;
        }
        if (object.needsSlowPropertyAccess()) return null;
        object = object.getPrototype() orelse return null;
    }
}

pub inline fn getFieldFast(rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    var absent = false;
    const slot = getFieldFastSlotWithExoticOrder(rt, receiver, atom_id, false, false, false, &absent) orelse return null;
    return slot.*;
}

/// qjs GET_FIELD_INLINE probes an own shape entry before `p->is_exotic`.
/// This ordering is safe for the constant `length` atom because it can never
/// alias zjs's out-of-shape mapped Arguments numeric bindings. It lets ordinary
/// own `length` data on Arguments and typed arrays hit before their slow class
/// semantics while misses and accessor entries still defer to the resolver.
pub inline fn getLengthFieldFast(rt: *core.JSRuntime, receiver: core.JSValue) ?core.JSValue {
    var absent = false;
    const slot = getFieldFastSlotWithExoticOrder(rt, receiver, core.atom.ids.length, true, true, false, &absent) orelse return null;
    return slot.*;
}

/// Primitive twin of getFieldFast. QuickJS selects
/// `ctx->class_proto[primitive_tag]` inside JS_GetPropertyInternal and then
/// performs the same shape walk as an object receiver. Realm prototype slots
/// are the zjs class_proto equivalent; only ordinary data hits are returned.
/// Accessors, auto-init/var-ref properties, exotic/proxy holders, and string
/// own index/length semantics fall back to the full resolver.
pub inline fn primitivePrototypeDataPropertyValueForFastPath(
    rt: *core.JSRuntime,
    global: *core.Object,
    receiver: core.JSValue,
    atom_id: core.Atom,
) ?core.JSValue {
    if (rt.atoms.mightBePrivate(atom_id)) return null;
    var object = primitivePrototypeObjectForFastPath(rt, global, receiver, atom_id) orelse return null;
    while (true) {
        if (object.needsSlowPropertyAccess() or object.hasExoticMethods() or object.proxyTarget() != null) return null;
        var slow_property = false;
        if (object.findOwnDataValueFast(atom_id, &slow_property)) |value| return value;
        if (slow_property) return null;
        object = object.getPrototype() orelse return null;
    }
}

inline fn primitivePrototypeObjectForFastPath(
    rt: *core.JSRuntime,
    global: *core.Object,
    receiver: core.JSValue,
    atom_id: core.Atom,
) ?*core.Object {
    const slot: core.object.RealmValueSlot = if (receiver.isString()) blk: {
        if (atom_id == core.atom.ids.length or atom_id.isTaggedInt()) return null;
        break :blk .string_prototype;
    } else if (receiver.isNumber())
        .number_prototype
    else if (receiver.is(.boolean))
        .boolean_prototype
    else if (receiver.isBigInt())
        .bigint_prototype
    else if (receiver.is(.symbol))
        .symbol_prototype
    else
        return null;

    const prototype_value = global.cachedRealmValue(rt, slot) orelse return null;
    return objectFromValue(prototype_value);
}

pub const PropertyFastValue = union(enum) {
    borrowed: core.JSValue,
    owned: core.JSValue,
    getter: core.JSValue,
    proxy: *core.Object,
};
inline fn typedArrayAccessorMethodId(atom_id: core.Atom) ?u32 {
    const TypedArrayAccessorMethod = method_ids.buffer.TypedArrayAccessorMethod;
    if (atom_id == core.atom.ids.length) return @intFromEnum(TypedArrayAccessorMethod.length);
    if (atom_id == atom_byte_length) return @intFromEnum(TypedArrayAccessorMethod.byte_length);
    if (atom_id == atom_byte_offset) return @intFromEnum(TypedArrayAccessorMethod.byte_offset);
    return null;
}

pub inline fn isTypedArrayPayloadAtomForFastPath(atom_id: core.Atom) bool {
    return atom_id == core.atom.ids.length or atom_id == atom_byte_length or atom_id == atom_byte_offset;
}

inline fn typedArrayNativeAccessorIdMatches(encoded_id: i32, expected_id: u32) bool {
    const native_ref = core.function.decodeNativeBuiltinId(encoded_id) orelse return false;
    return native_ref.domain == .buffer and native_ref.id == expected_id;
}

inline fn typedArrayIntrinsicNamedValue(
    rt: *core.JSRuntime,
    receiver: *core.Object,
    atom_id: core.Atom,
) ?PropertyFastValue {
    if (atom_id == core.atom.ids.length) {
        const length = core.object.typedArrayLength(rt, receiver) catch return null;
        return .{ .owned = array_ops.lengthIndexValue(@intCast(length)) };
    }
    if (atom_id == atom_byte_length) {
        const length = core.object.typedArrayByteLength(rt, receiver) catch return null;
        return .{ .owned = array_ops.lengthIndexValue(length) };
    }
    if (atom_id == atom_byte_offset) {
        const offset = core.object.typedArrayEffectiveByteOffset(receiver) catch return null;
        return .{ .owned = array_ops.lengthIndexValue(offset) };
    }
    return null;
}

inline fn typedArrayShapePropertyForFastPath(
    rt: *core.JSRuntime,
    receiver: *core.Object,
    holder: *core.Object,
    index: usize,
    atom_id: core.Atom,
    expected_id: u32,
) ?PropertyFastValue {
    return switch (holder.propKindAt(index)) {
        .data => .{ .borrowed = holder.propertyEntry(index).*.slot.data },
        .accessor => accessor: {
            const getter = holder.propertyEntry(index).*.slot.accessor.getterValue();
            if (objectFromValue(getter)) |getter_object| {
                if (typedArrayNativeAccessorIdMatches(getter_object.nativeFunctionId(), expected_id)) {
                    break :accessor typedArrayIntrinsicNamedValue(rt, receiver, atom_id);
                }
            }
            break :accessor .{ .getter = getter };
        },
        .auto_init => null,
        .var_ref => null,
    };
}

noinline fn typedArrayPrototypeNamedPropertyForFastPath(
    rt: *core.JSRuntime,
    receiver: *core.Object,
    atom_id: core.Atom,
    expected_id: u32,
) ?PropertyFastValue {
    var holder = receiver.getPrototype() orelse return .{ .borrowed = core.JSValue.undefinedValue() };
    while (true) {
        // Trusted hash-chain probe: mirrors qjs's force-inlined find_own_property
        //, which walks hash_next off the already-loaded property
        // with no per-step cycle/bounds guards. The defensive findProperty's
        // extra `steps < prop_count` / `index >= prop_count` / `index >= props.len`
        // guards are dead on any well-formed shape (the trusted probe's debug
        // asserts confirm the invariants), so this is the same lean probe the
        // ordinary get_field data path already uses — a faithful alignment, not a
        // behavior change — on this hot `.length`/`.byteLength`/`.byteOffset` walk.
        if (holder.findPropertyIndexTrusted(atom_id)) |index| {
            return typedArrayShapePropertyForFastPath(rt, receiver, holder, index, atom_id, expected_id);
        }
        if (holder.proxyTarget() != null) return .{ .proxy = holder };
        if (holder.needsSlowPropertyAccess() or holder.hasExoticMethods()) return null;
        holder = holder.getPrototype() orelse return .{ .borrowed = core.JSValue.undefinedValue() };
    }
}

noinline fn typedArrayNamedPropertyForFastPath(
    rt: *core.JSRuntime,
    object: *core.Object,
    atom_id: core.Atom,
) ?PropertyFastValue {
    const expected_id = typedArrayAccessorMethodId(atom_id) orelse return null;
    // Trusted hash-chain probe (qjs find_own_property, quickjs.c), matching
    // the ordinary get_field data path rather than the defensive findProperty
    // whose per-step guards are dead on a well-formed shape.
    if (object.findPropertyIndexTrusted(atom_id)) |index| {
        return typedArrayShapePropertyForFastPath(rt, object, object, index, atom_id, expected_id);
    }
    return typedArrayPrototypeNamedPropertyForFastPath(rt, object, atom_id, expected_id);
}

/// Cheap routing guard used only after the ordinary static-field data lookup
/// misses. TypedArray instance class ids are a contiguous range; checking that
/// range avoids probing the out-of-line payload on every ordinary accessor
/// miss. Keeping the test in the opcode handler prevents the larger typed-array
/// action classifier from changing the shared ordinary accessor/Proxy tail.
pub inline fn typedArrayReceiverForFastPath(receiver: core.JSValue) ?*core.Object {
    const object = objectFromValue(receiver) orelse return null;
    if (object.class_id < core.class.ids.uint8c_array or object.class_id > core.class.ids.float64_array) return null;
    return object;
}

/// Static named-property action classifier for TypedArray instances. This is
/// deliberately outlined from atomPropertyValueForFastPath: ordinary static
/// accessor/Proxy reads should retain the same resident handler shape whether
/// or not TypedArray payload accessors are accelerated.
pub inline fn typedArrayPropertyValueForFastPath(
    rt: *core.JSRuntime,
    object: *core.Object,
    atom_id: core.Atom,
) ?PropertyFastValue {
    if (rt.atoms.mightBePrivate(atom_id)) return null;
    return typedArrayNamedPropertyForFastPath(rt, object, atom_id);
}

/// Action half of qjs GET_FIELD_INLINE for the constant `length` atom. The
/// data-only helper above already settles the hot case; after that misses, qjs
/// still inspects an own accessor before consulting `p->is_exotic`. That order
/// matters for user-defined `length` accessors on typed arrays and mapped
/// Arguments. Proxies become resident actions; unsupported exotic misses retain
/// the existing slow machinery.
pub inline fn getLengthActionForFastPath(rt: *core.JSRuntime, receiver: core.JSValue) ?PropertyFastValue {
    const receiver_object = objectFromValue(receiver) orelse return null;
    var object = receiver_object;
    while (true) {
        if (object.findProperty(core.atom.ids.length)) |index| {
            return switch (object.propKindAt(index)) {
                .data => .{ .borrowed = object.propertyEntry(index).*.slot.data },
                .accessor => .{ .getter = object.propertyEntry(index).*.slot.accessor.getterValue() },
                .var_ref, .auto_init => null,
            };
        }
        // qjs continues from the typed-array exotic object into its current
        // prototype chain for this non-numeric name. The helper recognizes the
        // unmodified intrinsic accessor without calling it, but custom/null/
        // Proxy prototype chains keep their observable lookup semantics.
        if (core.object.isTypedArrayObject(object)) {
            const expected_id = typedArrayAccessorMethodId(core.atom.ids.length).?;
            // The intrinsic getter's brand check applies to the original
            // receiver, not to the typed-array object where prototype walking
            // happened to arrive (for example Object.create(typedArray)).
            return typedArrayPrototypeNamedPropertyForFastPath(rt, receiver_object, core.atom.ids.length, expected_id);
        }
        if (object.proxyTarget() != null) return .{ .proxy = object };
        if (object.needsSlowPropertyAccess() or object.hasExoticMethods()) return null;
        object = object.getPrototype() orelse return null;
    }
}

inline fn primitivePrototypePropertyForFastPath(
    rt: *core.JSRuntime,
    global: *core.Object,
    receiver: core.JSValue,
    atom_id: core.Atom,
) ?PropertyFastValue {
    if (rt.atoms.mightBePrivate(atom_id)) return null;
    var object = primitivePrototypeObjectForFastPath(rt, global, receiver, atom_id) orelse return null;
    while (true) {
        if (object.proxyTarget() != null) return .{ .proxy = object };
        if (object.needsSlowPropertyAccess() or object.hasExoticMethods()) return null;
        if (object.findProperty(atom_id)) |index| {
            return switch (object.propKindAt(index)) {
                .data => .{ .borrowed = object.propertyEntry(index).*.slot.data },
                .accessor => .{ .getter = object.propertyEntry(index).*.slot.accessor.getterValue() },
                .var_ref, .auto_init => null,
            };
        }
        object = object.getPrototype() orelse return null;
    }
}

/// Atom-keyed counterpart shared by static and computed property handlers.
/// Ordinary receivers return a semantically complete data/getter/Proxy/missing
/// result. Class-specific exotics and primitive index/length cases remain on
/// the general resolver. Returned data/getter values are borrowed from their
/// holder and must be duplicated before the caller releases the receiver.
pub inline fn atomPropertyValueForFastPath(
    rt: *core.JSRuntime,
    global: *core.Object,
    receiver: core.JSValue,
    atom_id: core.Atom,
) ?PropertyFastValue {
    if (objectFromValue(receiver)) |object| {
        if (object.class_id == core.class.ids.object or object.isArray() or object.isGlobal() or object.flags.is_native_object) {
            return switch (property_direct.ordinaryDataPropertyLookup(rt, receiver, atom_id)) {
                .value => |value| .{ .borrowed = value },
                .getter => |getter| .{ .getter = getter },
                .proxy => |proxy| .{ .proxy = proxy },
                .undefined => .{ .borrowed = core.JSValue.undefinedValue() },
                .slow => null,
            };
        }
        const value = getFieldFast(rt, receiver, atom_id) orelse return null;
        return .{ .borrowed = value };
    }
    return primitivePrototypePropertyForFastPath(rt, global, receiver, atom_id);
}

/// Computed-property twin of the field fast paths. qjs `JS_ValueToAtom` turns a
/// symbol value directly into its atom, then sends strings
/// and symbols through the same `JS_GetProperty` / `find_own_property` path. zjs
/// can likewise borrow the atom carried by a live symbol body or the weak atom
/// back-pointer on a materialized string. Indexed storage is string-only; both
/// key kinds share the ordinary atom-keyed lookup below. The operation cannot
/// re-enter, so borrowing either id is safe.
pub inline fn existingPropertyKeyValueForFastPath(
    rt: *core.JSRuntime,
    global: *core.Object,
    receiver: core.JSValue,
    key: core.JSValue,
) ?PropertyFastValue {
    const atom_id = existingPropertyKeyAtomForFastPath(key) orelse return null;
    if (key.isString()) {
        if (core.array.arrayIndexFromAtom(rt.atoms, atom_id)) |index| {
            if (index <= @as(u32, @intCast(std.math.maxInt(i32)))) {
                const index_value = core.JSValue.int32(@intCast(index));
                if (fastDenseArrayElementValue(receiver, index_value)) |value| return .{ .owned = value };
                if (fastStringIndexValue(rt, receiver, index_value)) |value| return .{ .owned = value };
                if (fastTypedArrayElementValue(receiver, index_value)) |value| return .{ .owned = value };
            }
        }
    }
    return atomPropertyValueForFastPath(rt, global, receiver, atom_id);
}

/// qjs `JS_ValueToAtom` handles an existing symbol before any general
/// ToPropertyKey/string conversion. Both returned ids
/// are borrowed from the still-live key value; a caller that can re-enter must
/// retain the atom first.
pub inline fn existingPropertyKeyAtomForFastPath(value: core.JSValue) ?core.Atom {
    if (value.asSymbolAtom()) |atom_id| return atom_id;
    return string_ops.stringAtomId(value);
}

/// Hot-handler variant of the qjs OP_put_field fast window (quickjs.c-
/// 19203): returns the MUTABLE own plain-writable-data slot address so the
/// resident op_put_field can perform set_value's swap-then-free itself with
/// integer-pair slot accesses. Mirrors the get-side probe-first ordering:
/// - Object-ness gate FIRST (qjs's leading JS_VALUE_GET_TAG(obj) ==
///   JS_TAG_OBJECT check), then the private-atom probe.
/// - find_own_property runs with NO class qualification at all: qjs's write
///   fast path trusts any own shape hit whose flags pass the single
///   (TMASK|WRITABLE|LENGTH) == WRITABLE mask, whatever the class — exotic
///   index storage (typed arrays, strings) never lives in the shape, mapped
///   Arguments numeric bindings are JS_PROP_VARREF entries the mask rejects,
///   and array `length` carries JS_PROP_LENGTH. Unlike GET_FIELD_INLINE
///   there is no miss-side `p->is_exotic` consultation either: the write
///   window is own-hit-only and every miss already defers to the cold
///   resolver (put_field_slow_path -> JS_SetPropertyInternal), which walks
///   prototypes for setters/read-only holders and runs the exotic machinery.
/// - zjs-only deviation, same as getFieldFastSlotOrAbsent: a mapped Arguments
///   receiver bails before probing — its numeric bindings live in
///   out-of-shape var-ref cells, so a shape data hit could be a stale mirror
///   and a direct slot write would desync the aliased parameter.
/// The pointer is only valid until the next potentially-shape-mutating
/// operation; both callers consume it immediately.
pub inline fn putFieldFastSlot(rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom) ?*core.JSValue {
    // Trusted-expression receiver contract (qjs OP_put_field's raw
    // JS_VALUE_GET_OBJ, quickjs.c): expression receivers are
    // never cells, so the header-kind recheck is a Debug assert only.
    const object = object_ops.objectFromValueTrustedExpression(receiver) orelse return null;
    // Bytecode put_field atom operands are proven non-private (qjs
    // OP_put_field's inline window carries no private probe either,
    // quickjs.c; private stores are OP_put_private_field only).
    debugAssertNonPrivateFieldOperandAtom(rt, atom_id);
    if (object.class_id == core.class.ids.mapped_arguments) return null;
    var slow_property = false;
    if (object.findWritableOwnDataSlotFast(atom_id, &slow_property)) |slot| return slot;
    return null;
}

inline fn replaceTopBorrowed(
    _: *core.JSRuntime,
    stack: *stack_mod.Stack,
    index: usize,
    _: core.JSValue,
    new_value: core.JSValue,
) void {
    stack.values[index] = new_value;
}

inline fn replaceTopOwned(
    _: *core.JSRuntime,
    stack: *stack_mod.Stack,
    index: usize,
    _: core.JSValue,
    new_value: core.JSValue,
) void {
    stack.values[index] = new_value;
}

fn setArrayLengthForPutFieldFastPath(
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
) bool {
    if (atom_id != core.atom.ids.length) return false;
    const length = value.as(.int) orelse return false;
    if (length < 0) return false;
    const object = objectFromValue(receiver) orelse return false;
    if (!object.isArray() or object.hasExoticMethods() or object.proxyTarget() != null) return false;
    if (!object.flags.length_writable) return false;
    const new_len: u32 = @intCast(length);
    if (new_len < object.arrayLength()) {
        if (object.arrayElementStorageMode() != .dense) return false;
        for (object.shapeProps()) |prop| {
            if (core.property.Flags.fromBits(prop.flags).deleted) continue;
            const index = core.array.arrayIndexFromAtom(rt.atoms, prop.atom_id) orelse continue;
            if (index >= new_len) return false;
        }
        object.truncateArrayElements(rt, new_len);
    }
    // Growth keeps the fast array and just extends `.length` into tail holes
    // (faithful to set_array_length quickjs.c — count is unchanged,
    // no sparse conversion). This is the `arr.length = bigger` fast path.
    object.setArrayLength(new_len);
    return true;
}

/// OP_put_array_el continuation after the resident handler misses. The caller
/// has already published pc/sp, so this is the direct counterpart of qjs's
/// put_array_el_slow_path -> JS_SetPropertyValue call, without the shared
/// get/put opcode switch.
pub fn putArrayElementAfterFastMiss(vm: *Vm) HostError!void {
    const ctx = vm.ctx;
    const output = vm.output;
    const global = vm.global;
    const stack = vm.stack;
    const function = vm.function;
    const frame = vm.frame;
    const catch_target = vm.catch_target;
    const value = try stack.pop();
    const key = try stack.pop();
    const obj = try stack.pop();
    var put_window: PoppedWindow(3) = .{};
    put_window.activate(ctx.runtime, .{ obj, key, value });
    defer put_window.deactivate(ctx.runtime);
    // The resident OP_put_array_el handler already ran qjs
    // JS_SetPropertyValue's object+int class switch (Array, slow Array, then
    // TypedArray). On that exact miss, continue at qjs's JS_ValueToAtom ->
    // JS_SetPropertyInternal slow-path boundary instead of repeating the same
    // typed/dense probes here.
    const int_object_fast_miss = key.is(.int) and obj.is(.object);
    if (!int_object_fast_miss) {
        switch (putTypedArrayElementFast(ctx.runtime, obj, key, value) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
            return err;
        }) {
            .handled => return,
            .not_typed_array => {},
        }
        switch (array_ops.putDenseArrayElementFast(ctx.runtime, obj, key, value)) {
            .handled => return,
            .out_of_memory => return error.OutOfMemory,
            .miss => {},
        }
    }
    if (int_object_fast_miss) {
        const index = key.as(.int).?;
        if (index >= 0) {
            // qjs JS_ValueToAtom -> __JS_AtomFromUInt32: a non-negative int32
            // key is already a tagged integer atom. No JSValue copy/string
            // conversion or dynamic atom ownership is needed.
            const atom_id = core.Atom.taggedInt(@intCast(index));
            _ = object_ops.setValueProperty(ctx, output, global, obj, atom_id, value, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            };
            return;
        }
    }
    const key_value = object_ops.toPropertyKeyValue(ctx, output, global, key, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
        return err;
    };
    // qjs JS_SetPropertyValue slow path runs
    // JS_ValueToAtom on the key BEFORE JS_SetPropertyInternal's nullish base
    // TypeError, so user key-coercion side effects fire first.
    if (obj.is(.null_value) or obj.is(.undefined_value)) {
        _ = object_ops.throwNullishComputedPropertyTypeError(ctx, global, obj, key_value) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
            return err;
        };
        unreachable;
    }
    if (!int_object_fast_miss) {
        switch (array_ops.putDenseArrayElementFast(ctx.runtime, obj, key_value, value)) {
            .handled => return,
            .out_of_memory => return error.OutOfMemory,
            .miss => {},
        }
    }
    const atom_id = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
    _ = object_ops.setValueProperty(ctx, output, global, obj, atom_id, value, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
        return err;
    };
}

pub noinline fn getArrayElement(vm: *Vm, opc: u8) HostError!void {
    const ctx = vm.ctx;
    const output = vm.output;
    const global = vm.global;
    const stack = vm.stack;
    const function = vm.function;
    const frame = vm.frame;
    const catch_target = vm.catch_target;
    switch (opc) {
        op.get_array_el => {
            const key = try stack.pop();
            const obj = try stack.pop();
            var get_window: PoppedWindow(2) = .{};
            get_window.activate(ctx.runtime, .{ obj, key });
            defer get_window.deactivate(ctx.runtime);
            if (obj.is(.null_value) or obj.is(.undefined_value)) {
                _ = object_ops.throwNullishComputedPropertyTypeError(ctx, global, obj, key) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                    return err;
                };
                unreachable;
            }
            // Mapped-arguments first: an integer key used to intern as an
            // atom and fall into getValueProperty (full resolver) before the
            // var-ref arm below could run. qjs JS_GetPropertyValue switches
            // on class_id first.
            if (fastMappedArgumentsElementValue(obj, key)) |value| {
                try stack.pushOwned(value);
                return;
            }
            if (existingPropertyKeyAtomForFastPath(key)) |atom_id| {
                // String.atom_id is a weak cache, while a symbol value carries
                // its atom id in the live body. A Proxy/getter can re-enter;
                // retain either borrowed id across the complete lookup.
                const retained_atom = atom_id;
                const value = object_ops.getValueProperty(ctx, output, global, obj, retained_atom, function, frame) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                    return err;
                };
                try stack.pushOwned(value);
                return;
            }
            if (fastDenseArrayElementValue(obj, key)) |value| {
                try stack.pushOwned(value);
                return;
            }
            if (fastStringIndexValue(ctx.runtime, obj, key)) |value| {
                try stack.pushOwned(value);
                return;
            }
            if (fastTypedArrayElementValue(obj, key)) |value| {
                try stack.pushOwned(value);
                return;
            }
            const atom_id = object_ops.toPropertyKeyAtom(ctx, output, global, key, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            };
            const value = object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            };
            try stack.pushOwned(value);
        },
        op.get_array_el2 => {
            const key = try stackValueFromTop(stack, 0);
            const obj = try stackValueFromTop(stack, 1);
            if (obj.is(.null_value) or obj.is(.undefined_value)) {
                _ = object_ops.throwNullishComputedPropertyTypeError(ctx, global, obj, key) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                    return err;
                };
                unreachable;
            }
            if (fastDenseArrayElementValue(obj, key)) |value| {
                stack.values[stack.len() - 1] = value;
                return;
            }
            if (fastStringIndexValue(ctx.runtime, obj, key)) |value| {
                stack.values[stack.len() - 1] = value;
                return;
            }
            if (fastTypedArrayElementValue(obj, key)) |value| {
                stack.values[stack.len() - 1] = value;
                return;
            }
            const key_value = object_ops.toPropertyKeyValue(ctx, output, global, key, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            };
            const atom_id = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
            const value = object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            };
            stack.values[stack.len() - 1] = value;
        },
        op.get_array_el3 => {
            const key = try stackValueFromTop(stack, 0);
            const obj = try stackValueFromTop(stack, 1);
            if (obj.is(.null_value) or obj.is(.undefined_value)) {
                _ = object_ops.throwNullishComputedPropertyTypeError(ctx, global, obj, key) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                    return err;
                };
                unreachable;
            }
            if (fastDenseArrayElementValue(obj, key)) |value| {
                try stack.pushOwned(value);
                return;
            }
            if (fastStringIndexValue(ctx.runtime, obj, key)) |value| {
                try stack.pushOwned(value);
                return;
            }
            if (fastTypedArrayElementValue(obj, key)) |value| {
                try stack.pushOwned(value);
                return;
            }
            const key_value = object_ops.toPropertyKeyValue(ctx, output, global, key, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            };
            const atom_id = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
            const value = object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            };
            stack.values[stack.len() - 1] = key_value;
            try stack.pushOwned(value);
        },
        else => unreachable,
    }
}

// qjs JS_GetPropertyValue TA arm: one live-count
// bounds check (detach publishes count=0), then a class-id load. No second
// data/width probe — `live_length > 0` implies a published pointer.
/// Non-optional JSValue (same two-reg ABI as `readNumericElement`) so the
/// get_array_el caller does not grow a 0x160 optional-unwrap frame.
pub noinline fn readTypedArrayIndexFast(
    object: *const core.Object,
    class_id: core.class.ClassId,
    index: u32,
) core.JSValue {
    const payload = object.typedArrayPayloadFast() orelse return core.JSValue.undefinedValue();
    // Detach/OOB: qjs only checks `idx >= u.array.count`. zjs publishes
    // live_length=0 (and data=null) on detach, so this one compare is enough.
    if (index >= payload.live_length) return core.JSValue.undefinedValue();
    return core.typed_array.decodeNumericElementByClass(class_id, payload.data.?, index);
}

// Inline typed-array element read for `obj[int]`. Callers that already
// classified `class_id` should use `readTypedArrayIndexFast` so ARRAY/own-int
// probes never run on a TA receiver (qjs CASE: class!=ARRAY → GPV jumptable).
pub fn fastTypedArrayElementValue(obj: core.JSValue, key: core.JSValue) ?core.JSValue {
    const object = objectFromValue(obj) orelse return null;
    const key_int = key.as(.int) orelse return null;
    if (key_int < 0) return null;
    const class_id = object.class_id;
    if (!core.class.isNumericTypedArrayClass(class_id)) return null;
    return readTypedArrayIndexFast(object, class_id, @intCast(key_int));
}

pub const TypedArrayWriteFast = enum { not_typed_array, handled };
pub fn putTypedArrayElementFast(rt: *core.JSRuntime, obj: core.JSValue, key: core.JSValue, value: core.JSValue) !TypedArrayWriteFast {
    const object = objectFromValue(obj) orelse return .not_typed_array;
    const key_int = key.as(.int) orelse return .not_typed_array;
    if (key_int < 0) return .not_typed_array;
    // A value object needs ToPrimitive (valueOf / Symbol.toPrimitive), which runs
    // user code and needs the full interpreter context (ctx/output/global) — that
    // conversion lives in the slow path's coerceTypedArrayElementForSet. The
    // canonical typedArraySetElement only coerces primitives, so an object value
    // punts to the slow path; the numeric-primitive write is the fast case.
    if (value.is(.object)) return .not_typed_array;
    // A BigInt or Symbol value has a ToNumber that THROWS a TypeError, and per
    // IntegerIndexedElementSet (ToNumber at spec step 6) that throw must happen
    // BEFORE the in-bounds/immutable validity check. typedArraySetElement does the
    // validity check first (silent no-op on OOB/immutable), which would swallow the
    // throw for an out-of-bounds / immutable-buffer element — so punt these
    // throwing-conversion values to the slow path, which converts first. (Number /
    // string / boolean / null / undefined have non-throwing conversions, so the
    // validity-check-first order is observably identical for them — they stay fast.)
    if (value.isBigInt() or value.is(.symbol)) return .not_typed_array;
    // Resolve the payload once. Its live count/data pair is maintained from the
    // backing ArrayBuffer's view list, exactly like qjs `u.array.count/u.ptr`.
    // Keep the qjs operation order: immutable reject -> coerce -> RE-check the
    // live pair -> store; detach/OOB after conversion is a silent no-op.
    const payload = object.typedArrayPayloadFast() orelse return .not_typed_array;
    const kind = payload.kind;
    if (!kind.isNumeric()) return .not_typed_array; // BigInt / non-TA -> slow
    const backing = payload.backing_payload orelse return .not_typed_array;
    if (backing.immutable) return .handled; // silent no-op
    const width = payload.element_size;
    if (width == 0) return .not_typed_array;
    const index: u32 = @intCast(key_int);

    // qjs's integer typed-array arms keep an existing int32 entirely in the
    // JS_SetPropertyValue switch: conversion is infallible/non-observable, then
    // the post-conversion bounds check and sized store happen directly. Avoid
    // routing that dominant case through an error-union call, an 8-byte scratch
    // buffer, and a second runtime kind switch. Since int32 conversion cannot
    // run user code, reading the live pair here is equivalent to qjs's required
    // post-conversion recheck; every other value keeps the canonical order below.
    if (core.typed_array.isIntegerNumericKind(kind)) {
        if (value.as(.int)) |integer| {
            if (index >= payload.live_length) return .handled;
            const data = payload.data orelse return .handled;
            const off = @as(usize, index) * @as(usize, width);
            if (core.typed_array.writeInt32NumericElement(kind, data + off, integer)) return .handled;
        }
    }

    var scratch: [8]u8 = undefined;
    try core.typed_array.writeNumericElement(rt, kind, scratch[0..width], value); // coerce FIRST
    if (index >= payload.live_length) return .handled;
    const data = payload.data orelse return .handled;
    const byte_width: usize = width;
    const off = @as(usize, index) * byte_width;
    // Store the coerced element with a direct sized copy. `width` is a runtime
    // value (payload.element_size), so a plain @memcpy lowers to a memcpyFast
    // CALL even for a 1-byte Uint8 store — the top self-cost of typed-array-heavy
    // code (gbemu VRAM/memory writes). Switch to comptime lengths so each arm is
    // a single sized load+store. Widths are always one of {1,2,4,8}.
    storeElementBytes(data[off .. off + byte_width], &scratch, width);
    return .handled;
}

/// Direct sized store of a coerced typed-array element from `scratch` into the
/// destination buffer. Comptime lengths per width so LLVM emits a plain sized
/// store instead of a runtime-length memcpyFast call.
inline fn storeElementBytes(dst: []u8, scratch: *const [8]u8, width: u32) void {
    switch (width) {
        1 => dst[0] = scratch[0],
        2 => dst[0..2].* = scratch[0..2].*,
        4 => dst[0..4].* = scratch[0..4].*,
        8 => dst[0..8].* = scratch[0..8].*,
        else => @memcpy(dst[0..width], scratch[0..width]),
    }
}

const FastPrototypeMethodKind = enum { regexp, collection };
noinline fn fastPrototypeMethodValue(
    rt: *core.JSRuntime,
    value: core.JSValue,
    atom_id: core.Atom,
    kind: FastPrototypeMethodKind,
) ?core.JSValue {
    const object = objectFromValue(value) orelse return null;
    const name = rt.atoms.name(atom_id) orelse return null;
    const expected_id: u32 = switch (kind) {
        .regexp => blk: {
            if (object.class_id != core.class.ids.regexp) return null;
            if (std.mem.eql(u8, name, "test"))
                break :blk @intFromEnum(method_ids.regexp.PrototypeMethod.test_);
            if (std.mem.eql(u8, name, "exec"))
                break :blk @intFromEnum(method_ids.regexp.PrototypeMethod.exec);
            return null;
        },
        .collection => core.host_function.builtin_method_id_lookup.collection.fastPrototypeMethodIdForClass(
            object.class_id,
            name,
        ) orelse return null,
    };
    if (object.hasOwnProperty(atom_id)) return null;
    const proto = object.getPrototype() orelse return null;
    const lookup = proto.getOwnDataPropertyLookup(atom_id) orelse return null;
    const method = lookup.value;
    const function_object = objectFromValue(method) orelse return null;
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse return null;
    const domain: core.function.NativeBuiltinDomain = switch (kind) {
        .regexp => .regexp,
        .collection => .collection,
    };
    if (native_ref.domain != domain or native_ref.id != expected_id) return null;
    return method;
}

inline fn fastRegExpPrototypeMethodValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    return fastPrototypeMethodValue(rt, value, atom_id, .regexp);
}

inline fn fastCollectionPrototypeMethodValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    return fastPrototypeMethodValue(rt, value, atom_id, .collection);
}

fn fastStringIndexValue(rt: *core.JSRuntime, value: core.JSValue, key: core.JSValue) ?core.JSValue {
    if (!value.isString() or !key.is(.int)) return null;
    const index_i32 = key.as(.int).?;
    if (index_i32 < 0) return null;
    const index: usize = @intCast(index_i32);
    if (index >= core.string.stringValueLenUnchecked(value)) return null;
    const unit = core.string.stringValueCodeUnitAtUnchecked(value, index);
    if (unit < 0x100) {
        const cached = rt.cachedSingleByteString(@intCast(unit)) orelse return null;
        return cached.value();
    }
    return null;
}

fn stackValueFromTop(stack: *const stack_mod.Stack, offset: u8) !core.JSValue {
    const index_from_top: usize = offset;
    if (index_from_top >= stack.len()) return error.StackUnderflow;
    return stack.values[stack.len() - 1 - index_from_top];
}

// ===== W1 property-site inline cache (native-boundary design 8.2 / R8) =====
//
// Hermes `GET_BY_ID_IMPL` shape: the instruction names one `PropSiteCache`
// slot of its own FunctionBytecode; the slot holds the receiver's
// `Shape.identity`, the receiver's `class_id`, and a slot index. See
// `bytecode.PropSiteCache` for the guard contract and
// `docs/vm-value-representation-contract.md` 5.2 for why the guard is a
// monotonic identity and never a pointer.
//
// Placement rule (PERF-T-SPIKE fairness rule 1): the HIT arms are inline in
// the resident handlers; every CAPTURE body here is `noinline` and reached
// only from a guard miss, so a hit never pays a prologue for machinery it
// does not use.

pub const PropSiteCache = bytecode.PropSiteCache;
const site_empty: u8 = @intFromEnum(PropSiteCache.State.empty);
pub const site_own: u8 = @intFromEnum(PropSiteCache.State.own);
pub const site_proto: u8 = @intFromEnum(PropSiteCache.State.proto);
pub const site_native_getter: u8 = @intFromEnum(PropSiteCache.State.native_getter);
pub const site_mega: u8 = @intFromEnum(PropSiteCache.State.mega);
var no_prop_sites: [256]PropSiteCache = [_]PropSiteCache{.{ .state = site_mega }} ** 256;
pub inline fn noPropSite() *PropSiteCache {
    return &no_prop_sites[0];
}

pub inline fn noPropSiteBase() [*]PropSiteCache {
    return &no_prop_sites;
}

/// A guard miss may overwrite the entry (Hermes overwrites rather than
/// locking a site monomorphic; the 2026-09-06 T-spike re-run priced permanent
/// locking at -9.8% on `poly_stress`). After `miss_budget` overwrites, or on
/// the first receiver this cache shape cannot express, the site retires to
/// `.mega` -- which no capture leg ever leaves, so a retired site costs one
/// predictable compare and then takes the ordinary walk unchanged.
pub inline fn siteCapturable(site: *const PropSiteCache) bool {
    return site.state != site_mega;
}

fn retireSite(site: *PropSiteCache) CaptureOutcome {
    site.state = site_mega;
    site.guard_key = 0;
    site.proto_key = 0;
    site.secondary_guard_key = 0;
    return .settled;
}

/// Charge one overwrite; false once the site has retired.
fn noteSiteMiss(site: *PropSiteCache) bool {
    if (site.state == site_mega) return false;
    if (site.state != site_empty) {
        if (site.misses >= PropSiteCache.miss_budget) {
            _ = retireSite(site);
            return false;
        }
        site.misses += 1;
    }
    return true;
}

inline fn slotIndexOf(holder: *const core.Object, slot: *const core.JSValue) ?u16 {
    const base = @intFromPtr(holder.prop_values);
    const addr = @intFromPtr(slot);
    // Shapes admit u32 slot indices; the compact cache only admits u16.
    // An unrepresentable slot must use the ordinary property walk.
    return std.math.cast(u16, (addr - base) / @sizeOf(core.property.Entry));
}

/// The receiver classes whose own-property probe is authoritative for a NAMED
/// atom and whose prototype link may therefore be cached. Exotic own-property
/// behaviour (Array `length`, typed-array and string indices, Proxy, module
/// namespaces) is a property of the CLASS, and a Shape does not pin the class
/// -- shapes are reused across classes (`createRegExpFromShape`, realm
/// templates). So the prototype and native-getter arms carry `class_id` and
/// re-check it on every hit; the own arm needs no class test at all, because
/// a shape-identity match proves the property really is in that layout and
/// the resident handler already probes own slots for every object class.
inline fn siteCacheableReceiverClass(object: *const core.Object) bool {
    // Exactly the classes whose own-property probe the resident walk itself
    // treats as authoritative before it follows the prototype link (the
    // `needsSlowPropertyAccess` step of `getFieldFastSlotWithExoticOrder`):
    // everything except Array / Arguments / module namespace / Proxy /
    // TypedArray / DataView, and anything carrying exotic methods.
    //
    // This was the narrower `object / global / NativeObject` triple, which
    // retired -- on its first execution -- the site of every property read
    // whose RECEIVER is a function, a Date, a RegExp, an Error, a Map or any
    // other ordinary-storage class. `f.call(...)` is the boundary corpus's
    // instance: `f` is class `bytecode_function`, so `.call` missed the own
    // probe, failed this test, went `.mega`, and paid the full own-shape hash
    // walk plus the prototype walk on every iteration.
    //
    // Widening is sound because the guard did not change: the hit arms still
    // re-check the receiver's shape identity AND `class_id` (a Shape does not
    // pin a class), and the prototype arm the holder's identity as well. The
    // one fact the cached prototype link stands on is that for these classes
    // an own-probe miss really means "no own property" -- which is what
    // `needsSlowPropertyAccess` decides, here for the receiver exactly as the
    // resident walk decides it for every link of the chain.
    return !object.needsSlowPropertyAccess();
}

/// Is `accessor` a native (K3) getter -- the `.native_getter` admission test?
/// Only the accessor SLOT is cached, never the resolved `NativeEntry`:
/// `Object.defineProperty` can replace the getter function without changing
/// any shape flag, so the hit arm re-reads the accessor out of the slot and
/// re-resolves its entry every time.
fn isNativeGetterValue(accessor: core.JSValue) bool {
    const func_obj = object_ops.objectFromValueTrustedExpression(accessor) orelse return false;
    if (func_obj.class_id != core.class.ids.c_function) return false;
    const target = func_obj.nativeCallTarget() orelse return false;
    return target.entry.kind == .getter;
}

/// What the caller must do next. `.settled` is the historical contract --
/// the site now either guards this receiver or is retired, so re-entering the
/// instruction terminates. `.deferred` is the one case where the site is
/// deliberately left capturable: re-entering would come straight back here,
/// so the caller must take the ordinary (cold) path exactly once.
pub const CaptureOutcome = enum { settled, deferred };
pub noinline fn captureFieldSite(site: *PropSiteCache, object: *core.Object, atom_id: core.Atom, allow_native_getter: bool) CaptureOutcome {
    if (!noteSiteMiss(site)) return .settled;
    var slow = false;
    if (object.findOwnDataSlotFast(atom_id, &slow)) |slot| {
        const index = slotIndexOf(object, slot) orelse return retireSite(site);
        // Keep the previous own layout, rather than charging alternating
        // receivers another capture until a two-shape site retires forever.
        // No pointer is retained; mutation and address reuse miss by identity.
        site.secondary_guard_key = if (site.state == site_own) site.guard_key else 0;
        site.secondary_slot = site.slot;
        site.slot = index;
        site.class_id = object.class_id;
        site.proto_key = 0;
        site.guard_key = object.shape_ref.identity;
        site.state = site_own;
        return .settled;
    }
    site.secondary_guard_key = 0;
    if (slow) return retireSite(site);
    if (!siteCacheableReceiverClass(object)) return retireSite(site);
    const holder = object.getPrototype() orelse return retireSite(site);
    if (holder.hasExoticMethods()) return retireSite(site);
    var proto_slow = false;
    if (holder.findOwnDataSlotFast(atom_id, &proto_slow)) |slot| {
        const proto_identity = holder.shape_ref.identity;
        // A live identity is never zero; zero is what discriminates `.own`.
        std.debug.assert(proto_identity != 0);
        site.slot = slotIndexOf(holder, slot) orelse return retireSite(site);
        site.class_id = object.class_id;
        site.proto_key = proto_identity;
        site.guard_key = object.shape_ref.identity;
        site.state = site_proto;
        return .settled;
    }
    if (proto_slow) {
        // The holder's entry is an accessor / var_ref / auto_init.
        if (holder.findOwnPropertySlotTrusted(atom_id)) |lookup| {
            if (!lookup.flags.deleted) {
                // Only a native (K3) getter is expressible as a site arm
                // (design 8.2).
                if (allow_native_getter and lookup.flags.kind == .accessor and
                    isNativeGetterValue(lookup.entry.slot.accessor.getterValue()))
                {
                    const index = holder.findPropertyIndexTrusted(atom_id).?;
                    site.slot = std.math.cast(u16, index) orelse return retireSite(site);
                    site.class_id = object.class_id;
                    site.proto_key = holder.shape_ref.identity;
                    site.guard_key = object.shape_ref.identity;
                    site.state = site_native_getter;
                    return .settled;
                }
                // A lazily installed builtin is a data property that has not
                // been born yet: every intrinsic method -- `Function.prototype
                // .call`, `Object.prototype.hasOwnProperty`, `Date.prototype
                // .getTime` -- reads as `.auto_init` until its first access
                // materializes the slot and flips the shape entry to `.data`
                // (`commitAutoInitValue`). Capture runs AHEAD of that read, so
                // retiring here locked out, permanently and on the very first
                // execution, essentially every prototype-method site in the
                // program. Defer instead: the caller takes the ordinary path
                // once (which materializes), the site stays capturable, and
                // the next execution captures the `.proto` data slot. The miss
                // budget still bounds a placeholder that never materializes.
                if (lookup.flags.kind == .auto_init and site.misses < PropSiteCache.miss_budget) {
                    site.misses += 1;
                    return .deferred;
                }
            }
        }
    }
    return retireSite(site);
}

/// `put_field` capture: a writable own data slot only. The writable and
/// data-kind bits live in the shape flags, so the identity guard alone proves
/// a later direct slot write is legal.
pub noinline fn capturePutSite(site: *PropSiteCache, object: *core.Object, atom_id: core.Atom) void {
    site.secondary_guard_key = 0;
    if (!noteSiteMiss(site)) return;
    // Same admission set as the resident `putFieldFastSlot` arm this cache
    // replaces (mapped `arguments` writes must reach the mapping).
    if (object.class_id == core.class.ids.mapped_arguments) {
        _ = retireSite(site);
        return;
    }
    var slow = false;
    if (object.findWritableOwnDataSlotFast(atom_id, &slow)) |slot| {
        site.slot = slotIndexOf(object, slot) orelse {
            _ = retireSite(site);
            return;
        };
        site.class_id = object.class_id;
        site.proto_key = 0;
        site.guard_key = object.shape_ref.identity;
        site.state = site_own;
        return;
    }
    _ = retireSite(site);
}

// ----- merged from vm_property_globals.zig -----
// Global variable read/write/define opcode handlers and their fused fast paths.
const exception_ops = @import("exception_ops.zig");
const setGlobalWritableDataStoreForFastPathOwned = property_direct.setGlobalWritableDataStoreForFastPathOwned;
inline fn closureVarAt(function: *const bytecode.FunctionBytecode, idx: u16) ?bytecode.function_bytecode.BytecodeClosureVar {
    if (idx >= function.closureVar().len) return null;
    return function.closureVar()[idx];
}

fn throwGlobalTdzReferenceError(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) HostError!void {
    const err = exception_ops.throwTdzReferenceError(ctx);
    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
    return err;
}

/// qjs OP_get_var slow arm: an uninitialized cell for a
/// non-lexical closure var resolves via JS_GetPropertyInternal on the global
/// OBJECT — proto chain and getters included, the lexical env never consulted.
/// `op.get_var` throws ReferenceError when no binding exists; `op.get_var_undef`
/// (typeof) yields undefined (qjs `opcode - OP_get_var_undef` throw flag).
fn getVarFromGlobalObject(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
    atom_id: core.Atom,
) HostError!void {
    const value = value: {
        if (function.runtimeStrictMode()) {
            if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |lexical_value| {
                if (!lexical_value.is(.uninitialized)) break :value lexical_value;
            }
        }
        if (global.getOwnDataPropertyValue(atom_id)) |global_data_value| {
            break :value global_data_value;
        }
        const global_value = global.value();
        if (opc == op.get_var) {
            const has_global_binding = hasObjectBinding(ctx, output, global, global_value, global, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            };
            if (!has_global_binding) {
                _ = exception_ops.throwReferenceErrorNotDefined(ctx, global, atom_id) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                    return err;
                };
                return error.ReferenceError;
            }
        }
        break :value try object_ops.getValueProperty(ctx, output, global, global_value, atom_id, function, frame);
    };
    try stack.pushOwned(value);
}

pub noinline fn getVar(vm: *Vm, opc: u8) HostError!void {
    const ctx = vm.ctx;
    const output = vm.output;
    const global = vm.global;
    const stack = vm.stack;
    const function = vm.function;
    const frame = vm.frame;
    const catch_target = vm.catch_target;
    const site_pc = frame.pc - 1;
    const ref_idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
    const atom_id = globalVarAtom(function, ref_idx) orelse return error.InvalidBytecode;
    frame.pc += 2;
    if (ref_idx < frame.var_refs.len) {
        {
            // Slot is a cell by type (phase D); the non-cell arm is gone.
            const cell = slot_ops.varRefSlotCell(frame, ref_idx);
            const value = cell.pvalue.*;
            if (!value.is(.uninitialized)) {
                // The bound cell is authoritative: a global lexical shadowing
                // this name would have performed definition-time cell surgery /
                // parked-cell reuse (qjs js_closure_define_global_var,
                // quickjs.c + 17186-17205), so no per-read lexical
                // check is needed (qjs OP_get_var has none, 18461-18488).
                // Guard #7 retired: cell values are never cells (the
                // direct-eval const view pvalue-aliases its target), so
                // `value` is the plain value already.
                try stack.push(value);
                return;
            } else {
                // qjs OP_get_var uninitialized arm:
                // a lexical closure var in its TDZ window throws; everything
                // else — undeclared global, deleted binding parked at
                // UNINITIALIZED (remove_global_object_property, 9289-9309),
                // or a lexical-shadow TDZ window reached through an old
                // non-lexical capture — resolves through the plain global
                // OBJECT (JS_GetPropertyInternal(ctx->global_obj, ...)),
                // never the lexical env.
                const cv_is_lexical = if (closureVarAt(function, ref_idx)) |cv| cv.isLexical() else false;
                if (cv_is_lexical and !cell.varRefIsDeletableSlot().*) {
                    return try throwGlobalTdzReferenceError(ctx, output, global, stack, frame, catch_target);
                }
                return try getVarFromGlobalObject(ctx, output, global, stack, function, frame, catch_target, opc, atom_id);
            }
        }
    } else if (closureVarAt(function, ref_idx)) |cv| {
        if (cv.isLexical()) return try throwGlobalTdzReferenceError(ctx, output, global, stack, frame, catch_target);
    }
    const opcode_profile = ctx.runtime.opcode_profile;
    if (opcode_profile != null) {
        core.profile.recordGlobalLookup();
    }
    if (atom_id == core.atom.ids.undefined_ and canUseFastGlobalUndefinedLookup(function, frame)) {
        if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |_| {} else {
            try stack.pushOwned(core.JSValue.undefinedValue());
            return;
        }
    }
    if (fastInstalledGlobalDataValueForAtomAtPc(ctx, function, global, frame, site_pc, atom_id)) |value| {
        try stack.push(value);
        return;
    }
    if (canUseFastGlobalVarLookup(function, atom_id, frame)) {
        if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |lex_value| {
            if (lex_value.is(.uninitialized)) {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.ReferenceError)) return;
                return error.ReferenceError;
            }
            try stack.pushOwned(lex_value);
            return;
        }
        if (globalDataPropertyValueForFastPath(ctx.runtime, global, function, site_pc, atom_id)) |value| {
            try stack.push(value);
            return;
        }
    }
    const value = value: {
        if (atom_id == core.atom.ids.undefined_) break :value core.JSValue.undefinedValue();
        if (call_runtime.globalLexicalValueForGlobal(ctx, global, atom_id)) |lex_value| {
            if (lex_value.is(.uninitialized)) {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.ReferenceError)) return;
                return error.ReferenceError;
            }
            break :value lex_value;
        }
        if (global.getOwnDataPropertyValue(atom_id)) |global_data_value| {
            break :value global_data_value;
        }
        const global_value = global.value();
        if (opc == op.get_var) {
            const has_global_binding = hasObjectBinding(ctx, output, global, global_value, global, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            };
            if (!has_global_binding) {
                _ = exception_ops.throwReferenceErrorNotDefined(ctx, global, atom_id) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                    return err;
                };
                return error.ReferenceError;
            }
        }
        break :value try object_ops.getValueProperty(ctx, output, global, global_value, atom_id, function, frame);
    };
    try stack.pushOwned(value);
}

pub noinline fn putVar(vm: *Vm) HostError!void {
    const ctx = vm.ctx;
    const output = vm.output;
    const global = vm.global;
    const stack = vm.stack;
    const function = vm.function;
    const frame = vm.frame;
    const catch_target = vm.catch_target;
    const strict_unresolved_get_var = dispatch.strictUnresolvedGetVar(vm);
    const eval_global_var_bindings = dispatch.evalGlobalVarBindings(vm);
    const is_eval_code = dispatch.isEvalCode(vm);
    const ref_idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
    const atom_id = globalVarAtom(function, ref_idx) orelse return error.InvalidBytecode;
    frame.pc += 2;
    const value = try stack.pop();
    if (ref_idx < frame.var_refs.len) {
        {
            // Slot is a cell by type (phase D); the non-cell arm is gone.
            const cell = slot_ops.varRefSlotCell(frame, ref_idx);
            const current = cell.pvalue.*;
            // qjs OP_put_var: the exceptional arm is
            // keyed on `uninitialized || is_const`, and inside it on the
            // CELL's is_lexical (unlike OP_get_var's cv-keyed check) — a
            // lexical cell throws (TDZ ReferenceError while uninitialized,
            // read-only TypeError for const), a non-lexical cell (deleted
            // binding / undeclared global) falls to the global-object set
            // below (JS_HasProperty strict check + JS_SetPropertyInternal).
            // The write-through arm needs no per-write lexical check: a
            // shadowing global lexical performed definition-time cell
            // surgery, so the bound cell IS the lexical binding.
            if (current.is(.uninitialized) or cell.varRefIsConstSlot().*) {
                if (cell.is_lexical and core.VarRef.fromValue(current) == null) {
                    if (current.is(.uninitialized)) {
                        return try throwGlobalTdzReferenceError(ctx, output, global, stack, frame, catch_target);
                    }
                    // qjs JS_ThrowTypeErrorReadOnly (18507); zjs reports
                    // the const violation through the same catchable
                    // TypeError channel the lexical-env write used.
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.TypeError)) return;
                    return error.TypeError;
                }
                // Non-lexical cell: fall to the global-object set below.
            } else if (core.VarRef.fromValue(current) == null and
                !cell.varRefIsFunctionNameSlot().*)
            {
                cell.setVarRefValue(ctx.runtime, value);
                return;
            }
        }
    } else if (closureVarAt(function, ref_idx)) |cv| {
        if (cv.isLexical()) {
            return try throwGlobalTdzReferenceError(ctx, output, global, stack, frame, catch_target);
        }
    }
    const opcode_profile = ctx.runtime.opcode_profile;
    if (opcode_profile != null) core.profile.recordGlobalLookup();
    const runtime_strict = function.isStrictMode() or function.runtimeStrictMode();
    if (canUseFastGlobalVarWrite(ctx, function, atom_id, frame)) {
        if (call_runtime.setGlobalLexicalValueForFastPathOwned(ctx, atom_id, value) catch |err| {
            return err;
        }) {
            return;
        }
        if (setGlobalWritableDataStoreForFastPathOwned(ctx.runtime, ctx.lexicals, global, function, frame.pc - 3, atom_id, value)) {
            return;
        }
    }
    const updated_global_lexical = call_runtime.setGlobalLexicalValueForGlobal(ctx, global, atom_id, value) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
        return err;
    };
    if (updated_global_lexical) {
        return;
    }
    {
        // qjs OP_put_var always performs JS_HasProperty on the global object
        // before its SetProperty slow leg. Only the
        // missing-binding throw is strict-only; skipping HasProperty in sloppy
        // mode loses observable Proxy/exotic-global `has` traps.
        const global_value = global.value();
        const has_global_binding = hasObjectBinding(ctx, output, global, global_value, global, atom_id, function, frame) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
            return err;
        };
        if (!has_global_binding and (runtime_strict or strict_unresolved_get_var)) {
            _ = exception_ops.throwReferenceErrorNotDefined(ctx, global, atom_id) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            };
            return error.ReferenceError;
        }
    }
    if (is_eval_code and
        eval_global_var_bindings and
        !runtime_strict and
        evalFunctionDeclaresGlobalVar(ctx.runtime, function, atom_id) and
        (try globalOwnAccessorWithoutSetter(ctx.runtime, global, atom_id)))
    {
        return;
    }
    if (try global.setOwnWritableDataProperty(ctx.runtime, atom_id, value)) {
        return;
    }
    if (!runtime_strict and globalOwnRejectedNonStrictSet(global, atom_id)) {
        return;
    }
    const global_value = global.value();
    _ = object_ops.setValueProperty(ctx, output, global, global_value, atom_id, value, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
        return err;
    };
}

fn globalOwnRejectedNonStrictSet(global: *core.Object, atom_id: core.Atom) bool {
    if (global.hasExoticMethods()) return false;
    for (global.shapeProps(), 0..) |prop, property_index| {
        const prop_flags = core.property.Flags.fromBits(prop.flags);
        if (prop_flags.deleted or prop.atom_id != atom_id) continue;
        if (prop_flags.isAccessor()) {
            return global.propertyEntry(property_index).*.slot.accessor.setterIsUndefined();
        }
        return switch (global.propKindAt(property_index)) {
            .data => !prop_flags.writable,
            .var_ref, .auto_init, .accessor => false,
        };
    }
    return false;
}

fn canUseFastGlobalVarWrite(
    ctx: *core.JSContext,
    function: *const bytecode.FunctionBytecode,
    atom_id: core.Atom,
    frame: *const frame_mod.Frame,
) bool {
    if (!canFuseGlobalDataWrite(function, frame, atom_id)) return false;
    if (functionFrameBindingShadowsGlobal(ctx.runtime, function, frame, atom_id)) return false;
    return true;
}

fn canUseFastGlobalUndefinedLookup(
    function: *const bytecode.FunctionBytecode,
    frame: *const frame_mod.Frame,
) bool {
    if (frameHasVarRefBinding(function, frame, core.atom.ids.undefined_)) return false;
    return true;
}

fn evalFunctionDeclaresGlobalVar(rt: *core.JSRuntime, function: *const bytecode.FunctionBytecode, atom_id: core.Atom) bool {
    for (function.closureVar()) |cv| {
        if (cv.closureType() != .global_decl or cv.isLexical()) continue;
        if (call_runtime.atomIdOrNameEql(rt, cv.var_name, atom_id)) return true;
    }
    return false;
}

fn globalOwnAccessorWithoutSetter(rt: *core.JSRuntime, global: *core.Object, atom_id: core.Atom) !bool {
    const desc = (try global.getOwnProperty(rt, atom_id)) orelse return false;
    return desc.kind == .accessor and desc.setter.is(.undefined_value);
}

fn globalDeclIsFunction(cv: core.function_bytecode.BytecodeClosureVar) bool {
    return cv.closureType() == .global_decl and cv.varKind() == .global_function_decl;
}

fn validateGlobalVarDeclaration(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.FunctionBytecode,
    cv: core.function_bytecode.BytecodeClosureVar,
    is_eval_code: bool,
) !void {
    _ = function;
    _ = is_eval_code;

    const atom_id = cv.var_name;
    const has_global_lexical = call_runtime.globalLexicalHasForGlobal(ctx, global, atom_id);
    const own_flags: ?core.property.Flags = flags: {
        const index = global.findProperty(atom_id) orelse break :flags null;
        const flags = global.propFlagsAt(index);
        break :flags if (flags.deleted) null else flags;
    };
    if (own_flags) |flags| {
        // JS_CheckDefineGlobalVar reads the raw shape entry: it does not invoke
        // exotic hooks or materialize JS_PROP_AUTOINIT during PASS1. PASS2's
        // js_closure_define_global_var performs auto-init before cell surgery.
        if (cv.isLexical()) {
            if (!flags.configurable) return error.SyntaxError;
        } else if (globalDeclIsFunction(cv) and !flags.configurable) {
            if (flags.isAccessor() or !flags.writable or !flags.enumerable) return error.TypeError;
        }
    } else if (!cv.isLexical() and !global.isExtensible()) {
        return error.TypeError;
    }
    if (has_global_lexical) return error.SyntaxError;
}

/// qjs js_closure2 PASS1: GlobalVar is compile-only and has already been
/// lowered into one GLOBAL_DECL ClosureVar per declaration. Validation consumes
/// only that final descriptor table, exactly like JSFunctionBytecode.
pub fn validateGlobalVarDeclarations(
    ctx: *core.JSContext,
    global: *core.Object,
    function: *const bytecode.FunctionBytecode,
    is_eval_code: bool,
) !void {
    for (function.closureVar()) |cv| {
        if (cv.closureType() != .global_decl) continue;
        try validateGlobalVarDeclaration(ctx, global, function, cv, is_eval_code);
    }
}

test "QuickJS global declaration validation does not materialize auto-init properties" {
    const rt = try core.JSRuntime.create(std.testing.allocator, .{});
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt, .{});
    defer ctx.destroy();
    const global = try core.Object.create(rt, core.class.ids.global_object, null);
    ctx.global = global;
    _ = try global.ensureGlobalPayload(rt);

    const binding_name = try rt.internAtom("qjs-pass1-auto-init-binding");
    try global.defineAutoInitPropertyWithRealm(
        rt,
        binding_name,
        "qjs-pass1-auto-init-binding",
        0,
        core.property.Flags.data(.method),
        global,
    );
    const property_index = global.findProperty(binding_name) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(core.property.Kind.auto_init, global.propKindAt(property_index));

    const function = try bytecode.FunctionBytecode.createFixture(rt, .{ .closure_var_count = 1 });
    defer function.destroyUnpublishedFixture(rt);
    function.closureVar()[0] = core.function_bytecode.BytecodeClosureVar.init(.{
        .closure_type = .global_decl,
        .var_idx = 0,
        .var_name = binding_name,
    });

    try validateGlobalVarDeclarations(ctx, global, function, true);
    try std.testing.expectEqual(core.property.Kind.auto_init, global.propKindAt(property_index));
}

pub noinline fn globalDefinition(vm: *Vm, opc: u8) HostError!void {
    const ctx = vm.ctx;
    const global = vm.global;
    const frame = vm.frame;
    const eval_global_var_bindings = dispatch.evalGlobalVarBindings(vm);
    switch (opc) {
        op.put_var_init => {
            const ref_idx = readInt(u16, vm.function.byteCode()[frame.pc..][0..2]);
            const atom_id = globalVarAtom(vm.function, ref_idx) orelse return error.InvalidBytecode;
            frame.pc += 2;
            const value = try vm.stack.pop();
            // Whether this initialization targets the eval global-variable
            // environment is an L0 entry fact, not a property of every nested
            // function compiled from the same source. QuickJS's finalized FB
            // therefore needs only its combined eval marker.
            if (!eval_global_var_bindings) {
                const fast_global_lexical = call_runtime.setGlobalLexicalValueForFastPathOwned(ctx, atom_id, value) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, vm.output, vm.stack, frame, vm.catch_target, global, err)) return;
                    return err;
                };
                if (fast_global_lexical) {
                    return;
                }
                const updated_global_lexical = call_runtime.setGlobalLexicalValueForGlobal(ctx, global, atom_id, value) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, vm.output, vm.stack, frame, vm.catch_target, global, err)) return;
                    return err;
                };
                if (updated_global_lexical) return;
            }
            try property_ops.setProperty(ctx.runtime, global, atom_id, value);
        },
        else => unreachable,
    }
}

// ----- merged from vm_property_locals.zig -----
// Local/arg/var-ref slot opcode handlers (get/put/set_loc, get/put_arg, var_ref forms, close_loc).
pub noinline fn loc(vm: *Vm, opc: u8) HostError!void {
    const ctx = vm.ctx;
    const function = vm.function;
    const frame = vm.frame;
    const stack = vm.stack;
    switch (opc) {
        op.get_loc => {
            const idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
            try slot_ops.execGetLoc(ctx, frame, stack, idx, 2, opc);
        },
        op.put_loc => try slot_ops.execPutLoc(frame, stack, readInt(u16, function.byteCode()[frame.pc..][0..2]), 2, opc),
        op.set_loc => try slot_ops.execSetLoc(frame, stack, readInt(u16, function.byteCode()[frame.pc..][0..2]), 2, opc),

        op.get_loc8 => {
            const idx = function.byteCode()[frame.pc];
            try slot_ops.execGetLoc(ctx, frame, stack, idx, 1, opc);
        },
        op.put_loc8 => try slot_ops.execPutLoc(frame, stack, function.byteCode()[frame.pc], 1, opc),
        op.set_loc8 => try slot_ops.execSetLoc(frame, stack, function.byteCode()[frame.pc], 1, opc),

        op.get_loc0 => {
            try slot_ops.execGetLoc(ctx, frame, stack, 0, 0, opc);
        },
        op.get_loc1 => {
            try slot_ops.execGetLoc(ctx, frame, stack, 1, 0, opc);
        },
        op.get_loc2 => {
            try slot_ops.execGetLoc(ctx, frame, stack, 2, 0, opc);
        },
        op.get_loc3 => {
            try slot_ops.execGetLoc(ctx, frame, stack, 3, 0, opc);
        },
        op.put_loc0 => try slot_ops.execPutLoc(frame, stack, 0, 0, opc),
        op.put_loc1 => try slot_ops.execPutLoc(frame, stack, 1, 0, opc),
        op.put_loc2 => try slot_ops.execPutLoc(frame, stack, 2, 0, opc),
        op.put_loc3 => try slot_ops.execPutLoc(frame, stack, 3, 0, opc),
        op.set_loc0 => try slot_ops.execSetLoc(frame, stack, 0, 0, opc),
        op.set_loc1 => try slot_ops.execSetLoc(frame, stack, 1, 0, opc),
        op.set_loc2 => try slot_ops.execSetLoc(frame, stack, 2, 0, opc),
        op.set_loc3 => try slot_ops.execSetLoc(frame, stack, 3, 0, opc),
        else => unreachable,
    }
}

pub noinline fn getArg(vm: *Vm, opc: u8) HostError!void {
    const ctx = vm.ctx;
    const frame = vm.frame;
    const stack = vm.stack;
    switch (opc) {
        op.get_arg => try slot_ops.execGetArg(ctx, frame, stack, readInt(u16, vm.function.byteCode()[frame.pc..][0..2]), 2, opc),
        op.put_arg => try slot_ops.execPutArg(frame, stack, readInt(u16, vm.function.byteCode()[frame.pc..][0..2]), 2, opc),
        op.set_arg => try slot_ops.execSetArg(frame, stack, readInt(u16, vm.function.byteCode()[frame.pc..][0..2]), 2, opc),
        op.get_arg0 => try slot_ops.execGetArg(ctx, frame, stack, 0, 0, opc),
        op.get_arg1 => try slot_ops.execGetArg(ctx, frame, stack, 1, 0, opc),
        op.get_arg2 => try slot_ops.execGetArg(ctx, frame, stack, 2, 0, opc),
        op.get_arg3 => try slot_ops.execGetArg(ctx, frame, stack, 3, 0, opc),
        op.put_arg0 => try slot_ops.execPutArg(frame, stack, 0, 0, opc),
        op.put_arg1 => try slot_ops.execPutArg(frame, stack, 1, 0, opc),
        op.put_arg2 => try slot_ops.execPutArg(frame, stack, 2, 0, opc),
        op.put_arg3 => try slot_ops.execPutArg(frame, stack, 3, 0, opc),
        op.set_arg0 => try slot_ops.execSetArg(frame, stack, 0, 0, opc),
        op.set_arg1 => try slot_ops.execSetArg(frame, stack, 1, 0, opc),
        op.set_arg2 => try slot_ops.execSetArg(frame, stack, 2, 0, opc),
        op.set_arg3 => try slot_ops.execSetArg(frame, stack, 3, 0, opc),
        else => unreachable,
    }
}

/// `get_arg0..3`: the short forms encode the index in the opcode.
pub fn getArgShort(vm: *Vm, opc: u8) HostError!void {
    try slot_ops.execGetArg(vm.ctx, vm.frame, vm.stack, @as(u16, @intCast(opc - op.get_arg0)), 0, opc);
}

pub noinline fn checkedLocVm(vm: *Vm, opc: u8) HostError!void {
    const ctx = vm.ctx;
    const output = vm.output;
    const function = vm.function;
    const global = vm.global;
    const frame = vm.frame;
    const stack = vm.stack;
    const catch_target = vm.catch_target;
    const idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
    frame.pc += 2;
    if (idx >= frame.locals.len) return error.InvalidBytecode;

    switch (opc) {
        op.set_loc_uninitialized => {
            // A lexical reset starts a new binding instance. Detach any cell
            // from the previous instance before publishing the TDZ sentinel.
            try frame.closeLocalBinding(ctx.runtime, idx);
            frame.locals[idx] = core.JSValue.uninitialized();
        },
        op.get_loc_check => {
            if (frame.locals[idx].is(.uninitialized)) {
                const is_derived_this = function.isDerivedClassConstructor() and
                    idx < function.varDefs().len and
                    function.varDefs()[idx].var_name == core.atom.ids.this_;
                const err = if (is_derived_this) blk: {
                    _ = exception_ops.throwReferenceErrorMessage(ctx, global, "this is not initialized") catch |err| break :blk err;
                    unreachable;
                } else exception_ops.throwTdzReferenceError(ctx);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            }
            try stack.push(frame.locals[idx]);
        },
        op.get_loc_checkthis => {
            if (frame.locals[idx].is(.uninitialized)) {
                // This opcode is the compiler-generated implicit return after
                // derived-constructor return unwinding. QuickJS constructs its
                // ReferenceError in caller_ctx, so leave it as a distinct
                // sentinel for the caller frame instead of materializing here.
                return error.DerivedThisUninitialized;
            }
            try stack.push(frame.locals[idx]);
        },
        op.put_loc_check => {
            if (frame.locals[idx].is(.uninitialized)) {
                const err = exception_ops.throwTdzReferenceError(ctx);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            }
            const value = try stack.pop();
            if (idx < function.varDefs().len and function.varDefs()[idx].isConst()) {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.TypeError)) return;
                return error.TypeError;
            }
            frame.locals[idx] = value;
        },
        op.set_loc_check => {
            if (frame.locals[idx].is(.uninitialized)) {
                const err = exception_ops.throwTdzReferenceError(ctx);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            }
            const value = stack.peek() orelse return error.StackUnderflow;
            frame.locals[idx] = value;
        },
        op.put_loc_check_init => {
            // Only derived `this` has once-only init semantics (double-super ->
            // "'this' can be initialized only once"). put_loc_check_init is also
            // emitted for other lexical inits (e.g. AnnexB block-function var
            // copies) that legitimately overwrite an already-set slot, so the
            // once-only error must stay gated on the derived-this binding.
            const is_derived_this = function.isDerivedClassConstructor() and
                idx < function.varDefs().len and
                function.varDefs()[idx].var_name == core.atom.ids.this_;
            if (is_derived_this and !frame.locals[idx].is(.uninitialized)) {
                _ = exception_ops.throwReferenceErrorMessage(ctx, global, "'this' can be initialized only once") catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                    return err;
                };
                unreachable;
            }
            const value = try stack.pop();
            frame.locals[idx] = value;
        },
        else => unreachable,
    }
}

pub fn varRef(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    function: *const bytecode.FunctionBytecode,
    global: *core.Object,
    frame: *frame_mod.Frame,
    stack: *stack_mod.Stack,
    opc: u8,
    catch_target: *?usize,
) !Step {
    switch (opc) {
        op.get_var_ref, op.get_var_ref_check => {
            if (frame.pc + 2 > function.byteCode().len) return error.TypeError;
            const idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
            if (try tryFastDirectVarRefGet(function, frame, stack, idx, 2)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, output, function, frame, stack, idx, 2, catch_target, global)) return .continue_loop;
        },
        op.put_var_ref, op.put_var_ref_check, op.put_var_ref_check_init => {
            if (frame.pc + 2 > function.byteCode().len) return error.TypeError;
            const idx = readInt(u16, function.byteCode()[frame.pc..][0..2]);
            try slot_ops.execPutVarRef(ctx, function, global, frame, stack, idx, 2, opc);
        },
        op.set_var_ref => {
            if (frame.pc + 2 > function.byteCode().len) return error.TypeError;
            try slot_ops.execSetVarRef(ctx, frame, stack, readInt(u16, function.byteCode()[frame.pc..][0..2]), 2, opc);
        },

        op.get_var_ref0 => {
            if (try tryFastDirectVarRefGet(function, frame, stack, 0, 0)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, output, function, frame, stack, 0, 0, catch_target, global)) return .continue_loop;
        },
        op.get_var_ref1 => {
            if (try tryFastDirectVarRefGet(function, frame, stack, 1, 0)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, output, function, frame, stack, 1, 0, catch_target, global)) return .continue_loop;
        },
        op.get_var_ref2 => {
            if (try tryFastDirectVarRefGet(function, frame, stack, 2, 0)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, output, function, frame, stack, 2, 0, catch_target, global)) return .continue_loop;
        },
        op.get_var_ref3 => {
            if (try tryFastDirectVarRefGet(function, frame, stack, 3, 0)) return .done;
            if (try slot_ops.execGetVarRefMaybeTdz(ctx, output, function, frame, stack, 3, 0, catch_target, global)) return .continue_loop;
        },
        op.put_var_ref0 => try slot_ops.execPutVarRef(ctx, function, global, frame, stack, 0, 0, opc),
        op.put_var_ref1 => try slot_ops.execPutVarRef(ctx, function, global, frame, stack, 1, 0, opc),
        op.put_var_ref2 => try slot_ops.execPutVarRef(ctx, function, global, frame, stack, 2, 0, opc),
        op.put_var_ref3 => try slot_ops.execPutVarRef(ctx, function, global, frame, stack, 3, 0, opc),
        op.set_var_ref0 => try slot_ops.execSetVarRef(ctx, frame, stack, 0, 0, opc),
        op.set_var_ref1 => try slot_ops.execSetVarRef(ctx, frame, stack, 1, 0, opc),
        op.set_var_ref2 => try slot_ops.execSetVarRef(ctx, frame, stack, 2, 0, opc),
        op.set_var_ref3 => try slot_ops.execSetVarRef(ctx, frame, stack, 3, 0, opc),
        else => unreachable,
    }
    return .done;
}

pub noinline fn varRefVm(vm: *Vm, opc: u8) HostError!void {
    _ = varRef(vm.ctx, vm.output, vm.function, vm.global, vm.frame, vm.stack, opc, vm.catch_target) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

fn tryFastDirectVarRefGet(function: *const bytecode.FunctionBytecode, frame: *frame_mod.Frame, stack: *stack_mod.Stack, idx: u16, consume: u8) !bool {
    if (call_runtime.closureVarIsNonLexicalGlobalSentinel(function, idx)) return false;
    const value = varRefReadableBorrowed(frame, idx) orelse return false;
    frame.pc += consume;
    try stack.push(value);
    return true;
}

pub noinline fn closeLoc(vm: *Vm) HostError!void {
    const idx = readInt(u16, vm.function.byteCode()[vm.frame.pc..][0..2]);
    vm.frame.pc += 2;
    try vm.frame.closeLocalBinding(vm.ctx.runtime, idx);
}

// ----- merged from vm_property_private.zig -----
// Private-field opcode handlers (get/put/define_private_field).
fn privateFieldAtom(
    ctx: *core.JSContext,
    global: *core.Object,
    frame: *frame_mod.Frame,
    receiver: core.JSValue,
    key: core.JSValue,
) !core.Atom {
    const error_global = if (object_ops.objectFromValue(frame.current_function)) |function_object|
        object_ops.objectRealmGlobal(function_object) orelse global
    else
        global;
    if (!receiver.is(.object)) {
        _ = try exception_ops.throwTypeErrorMessage(ctx, error_global, "not an object");
        unreachable;
    }
    if (key.asSymbolAtom()) |atom_id| return atom_id;
    _ = try exception_ops.throwTypeErrorMessage(ctx, error_global, "not a symbol");
    unreachable;
}

pub fn getPrivateField(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    const key = try stack.pop();
    const obj = try stack.pop();
    const atom_id = try privateFieldAtom(ctx, global, frame, obj, key);
    const value = try object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame);
    try stack.pushOwned(value);
}

pub noinline fn getPrivateFieldVm(vm: *Vm) HostError!void {
    getPrivateField(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub fn putPrivateField(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    const key = try stack.pop();
    const value = try stack.pop();
    const obj = try stack.pop();
    const atom_id = try privateFieldAtom(ctx, global, frame, obj, key);
    _ = try object_ops.setValueProperty(ctx, output, global, obj, atom_id, value, function, frame);
}

pub noinline fn putPrivateFieldVm(vm: *Vm) HostError!void {
    putPrivateField(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub fn definePrivateField(
    ctx: *core.JSContext,
    _: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    _: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    const value = try stack.pop();
    const key = try stack.pop();
    const obj = stack.peek() orelse return error.StackUnderflow;
    const atom_id = try privateFieldAtom(ctx, global, frame, obj, key);
    const object = try property_ops.expectObject(obj);
    try object_ops.defineClassFieldDataProperty(ctx.runtime, object, atom_id, value);
}

pub noinline fn definePrivateFieldVm(vm: *Vm) HostError!void {
    definePrivateField(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

// ----- merged from vm_property_ref.zig -----
// With-statement and reference opcode handlers (make_ref/get_ref_value/put_ref_value/with_*).
const varRefCellFromValue = slot_ops.varRefCellFromValue;
pub noinline fn dynEnvProbe(vm: *Vm) HostError!void {
    const flags = bytecode.opcode.dyn_env.decode(vm.function.byteCode()[vm.frame.pc + 8]) orelse
        return error.InvalidBytecode;
    return switch (flags.kind) {
        .put => dynEnvProbeStore(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, flags.is_with),
        else => dynEnvProbeAccess(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame, vm.catch_target, flags),
    };
}

fn dynEnvProbeAccess(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    flags: bytecode.opcode.dyn_env.Flags,
) HostError!void {
    const atom_id = core.Atom.fromRaw(readInt(u32, function.byteCode()[frame.pc..][0..4]));
    const diff = readInt(i32, function.byteCode()[frame.pc + 4 ..][0..4]);
    const is_with = flags.is_with;
    const operand_pc = frame.pc;
    frame.pc += 9;
    const obj_value = stack.peek() orelse return error.StackUnderflow;
    const object = core.value_semantics.objectFromValue(obj_value) orelse {
        _ = try stack.pop();
        return;
    };
    const has_binding = object_ops.hasPropertyForWith(ctx, output, global, obj_value, atom_id, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
        return err;
    };
    const blocked = if (is_with and has_binding)
        call_runtime.isBlockedByUnscopables(ctx, output, global, obj_value, atom_id, function, frame) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
            return err;
        }
    else
        false;
    if (!has_binding or blocked) {
        _ = try stack.pop();
        return;
    }
    const still_has_binding = if (flags.kind == .read or flags.kind == .get_ref)
        object_ops.hasPropertyForWith(ctx, output, global, obj_value, atom_id, function, frame) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
            return err;
        }
    else
        true;
    if (flags.kind == .read and !still_has_binding and (function.isStrictMode() or function.runtimeStrictMode())) {
        _ = exception_ops.throwReferenceErrorNotDefined(ctx, global, atom_id) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
            return err;
        };
        return error.ReferenceError;
    }
    switch (flags.kind) {
        .read => {
            const value = if (still_has_binding)
                try object_ops.getValueProperty(ctx, output, global, obj_value, atom_id, function, frame)
            else
                core.JSValue.undefinedValue();
            _ = try stack.pop();
            try stack.pushOwned(value);
        },
        .delete => {
            var deleted_cell_value = core.JSValue.undefinedValue();
            var has_deleted_cell = false;
            if (!is_with) {
                if (object.findProperty(atom_id)) |index| {
                    if (object.asVarRefAt(index)) |cell| {
                        if (cell.varRefIsDeletableSlot().*) {
                            deleted_cell_value = cell.valueRef();
                            has_deleted_cell = true;
                        }
                    }
                }
            }
            const deleted = object.deleteProperty(ctx.runtime, atom_id);
            if (deleted and has_deleted_cell) {
                if (varRefCellFromValue(deleted_cell_value)) |cell| {
                    cell.varRefValueSlot().* = core.JSValue.uninitialized();
                    cell.is_lexical = false;
                    cell.varRefIsConstSlot().* = false;
                }
            }
            if (!deleted and function.isStrictMode()) {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.TypeError)) return;
                return error.TypeError;
            }
            _ = try stack.pop();
            try stack.pushOwned(core.JSValue.boolean(deleted));
        },
        .get_ref => {
            const value = if (still_has_binding)
                try object_ops.getValueProperty(ctx, output, global, obj_value, atom_id, function, frame)
            else
                core.JSValue.undefinedValue();
            try stack.pushOwned(value);
        },
        .make_ref => {
            const key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
            try stack.pushOwned(key_value);
        },
        .put => unreachable,
    }
    frame.pc = @intCast(@as(i64, @intCast(operand_pc + 4)) + diff);
}

pub noinline fn makeSlotRef(vm: *Vm, opc: u8) HostError!void {
    const ctx = vm.ctx;
    const frame = vm.frame;
    const atom_id = core.Atom.fromRaw(readInt(u32, vm.function.byteCode()[frame.pc..][0..4]));
    const idx = readInt(u16, vm.function.byteCode()[frame.pc + 4 ..][0..2]);
    frame.pc += 6;

    const cell: *core.VarRef = switch (opc) {
        op.make_loc_ref => blk: {
            if (idx >= frame.locals.len) return error.InvalidBytecode;
            break :blk try frame.captureLocal(ctx.runtime, idx);
        },
        op.make_arg_ref => blk: {
            if (idx >= frame.args.len) return error.InvalidBytecode;
            break :blk try frame.captureArg(ctx.runtime, idx);
        },
        op.make_var_ref_ref => blk: {
            try frame_mod.ensureVarRefsCapacity(ctx, frame, idx);
            break :blk frame.var_refs[idx];
        },
        else => unreachable,
    };
    const ref_value = cell.valueRef();
    const key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
    try vm.stack.push(ref_value);
    try vm.stack.pushOwned(key_value);
}

pub fn makeVarRef(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    const atom_id = core.Atom.fromRaw(readInt(u32, function.byteCode()[frame.pc..][0..4]));
    frame.pc += 4;
    const global_value = global.value();
    const object_value = object_value: {
        // QuickJS JS_GetGlobalVarRef checks global_var_obj before touching the
        // global object. Its readonly/TDZ checks happen while the reference is
        // created, including the non-optimized scope_make_ref fallback.
        if (call_runtime.existingGlobalLexicalEnv(ctx)) |env| {
            if (env.findProperty(atom_id)) |index| {
                const flags = env.propFlagsAt(index);
                if (!flags.deleted) {
                    const is_uninitialized = switch (flags.kind) {
                        .data => env.propertyEntry(index).*.slot.data.is(.uninitialized),
                        .var_ref => env.propertyEntry(index).*.slot.var_ref.varRefValue().is(.uninitialized),
                        .accessor, .auto_init => return error.InvalidBytecode,
                    };
                    if (is_uninitialized) return exception_ops.throwTdzReferenceError(ctx);
                    if (!flags.writable) {
                        _ = exception_ops.throwTypeErrorMessage(ctx, global, "invalid assignment to const variable") catch |err| return err;
                        return error.TypeError;
                    }
                    break :object_value env.value();
                }
            }
        }
        const has_global_binding = try hasObjectBinding(ctx, output, global, global_value, global, atom_id, function, frame);
        break :object_value if (has_global_binding) global_value else core.JSValue.undefinedValue();
    };
    const key_value = try ctx.runtime.atoms.toStringValue(ctx.runtime, atom_id);
    try stack.push(object_value);
    try stack.push(key_value);
}

pub noinline fn makeVarRefVm(vm: *Vm) HostError!void {
    makeVarRef(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub fn getRefValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    if (stack.len() < 2) return error.StackUnderflow;
    const obj = stack.values[stack.len() - 2];
    const key = stack.values[stack.len() - 1];
    if (obj.is(.undefined_value)) {
        // qjs OP_get_ref_value: the atom is resolved first,
        // then the undefined base reports the identifier.
        const atom_id = try object_ops.toPropertyKeyAtom(ctx, output, global, key, function, frame);
        _ = exception_ops.throwReferenceErrorNotDefined(ctx, global, atom_id) catch |err| return err;
        return error.ReferenceError;
    }
    if (varRefCellFromValue(obj) != null) {
        const value = slot_ops.adapterValueBorrow(obj);
        if (value.is(.uninitialized)) return error.ReferenceError;
        try stack.pushOwned(value);
        return;
    }
    const atom_id = try object_ops.toPropertyKeyAtom(ctx, output, global, key, function, frame);
    const object = try property_ops.expectObject(obj);
    const still_exists = try hasObjectBinding(ctx, output, global, obj, object, atom_id, function, frame);
    if (!still_exists) {
        if (function.isStrictMode() or function.runtimeStrictMode()) {
            _ = exception_ops.throwReferenceErrorNotDefined(ctx, global, atom_id) catch |err| return err;
            return error.ReferenceError;
        }
        try stack.push(core.JSValue.undefinedValue());
        return;
    }
    const value = try object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame);
    try stack.pushOwned(value);
}

pub noinline fn getRefValueVm(vm: *Vm) HostError!void {
    getRefValue(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

pub fn putRefValue(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
) !void {
    const value = try stack.pop();
    const key = try stack.pop();
    var obj = try stack.pop();

    const runtime_strict = function.isStrictMode() or function.runtimeStrictMode();
    if (obj.is(.undefined_value)) {
        if (runtime_strict) {
            // qjs OP_put_ref_value.
            const atom_id = try object_ops.toPropertyKeyAtom(ctx, output, global, key, function, frame);
            _ = exception_ops.throwReferenceErrorNotDefined(ctx, global, atom_id) catch |err| return err;
            return error.ReferenceError;
        }
        const global_value = global.value();
        obj = global_value;
    }
    if (varRefCellFromValue(obj)) |cell| {
        if (cell.varRefIsFunctionNameSlot().*) {
            if (!runtime_strict) {
                return;
            }
            _ = exception_ops.throwTypeErrorMessage(ctx, global, "invalid assignment to const variable") catch |err| return err;
            return error.TypeError;
        }
        if (cell.varRefIsConstSlot().*) {
            _ = exception_ops.throwTypeErrorMessage(ctx, global, "invalid assignment to const variable") catch |err| return err;
            return error.TypeError;
        }
        var ref_slot = obj;
        slot_ops.replaceAdapterOwned(ctx, &ref_slot, value);
        return;
    }
    const atom_id = try object_ops.toPropertyKeyAtom(ctx, output, global, key, function, frame);
    const object = try property_ops.expectObject(obj);
    const still_exists = try hasObjectBinding(ctx, output, global, obj, object, atom_id, function, frame);
    if (!still_exists and runtime_strict) {
        _ = exception_ops.throwReferenceErrorNotDefined(ctx, global, atom_id) catch |err| return err;
        return error.ReferenceError;
    }
    _ = try object_ops.setValueProperty(ctx, output, global, obj, atom_id, value, function, frame);
}

pub noinline fn putRefValueVm(vm: *Vm) HostError!void {
    putRefValue(vm.ctx, vm.output, vm.global, vm.stack, vm.function, vm.frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(vm.ctx, vm.output, vm.stack, vm.frame, vm.catch_target, vm.global, err)) return;
        return err;
    };
}

fn dynEnvProbeStore(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    is_with: bool,
) HostError!void {
    const atom_id = core.Atom.fromRaw(readInt(u32, function.byteCode()[frame.pc..][0..4]));
    const diff = readInt(i32, function.byteCode()[frame.pc + 4 ..][0..4]);
    const operand_pc = frame.pc;
    frame.pc += 9;
    const obj = try stack.pop();
    if (obj.is(.undefined_value)) return;
    {
        const has_binding = object_ops.hasPropertyForWith(ctx, output, global, obj, atom_id, function, frame) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
            return err;
        };
        if (!has_binding) return;
        if (is_with) {
            const blocked = call_runtime.isBlockedByUnscopables(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
                return err;
            };
            if (blocked) return;
        }
    }
    const still_exists = object_ops.hasPropertyForWith(ctx, output, global, obj, atom_id, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
        return err;
    };
    if (!still_exists and (function.isStrictMode() or function.runtimeStrictMode())) {
        _ = exception_ops.throwReferenceErrorNotDefined(ctx, global, atom_id) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
            return err;
        };
        return error.ReferenceError;
    }
    const value = try stack.pop();
    _ = object_ops.setValueProperty(ctx, output, global, obj, atom_id, value, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
        return err;
    };
    frame.pc = @intCast(@as(i64, @intCast(operand_pc + 4)) + diff);
}

pub noinline fn deleteVar(vm: *Vm) HostError!void {
    const global = vm.global;
    const atom_id = core.Atom.fromRaw(readInt(u32, vm.function.byteCode()[vm.frame.pc..][0..4]));
    vm.frame.pc += 4;
    // qjs JS_DeleteGlobalVar: declarative globals are not deletable; every
    // object-environment binding goes through the ordinary global property
    // delete, which also parks a captured VARREF cell at UNINITIALIZED.
    const deleted = if (call_runtime.globalLexicalHasForGlobal(vm.ctx, global, atom_id))
        false
    else if (global.hasProperty(atom_id))
        global.deleteProperty(vm.ctx.runtime, atom_id)
    else
        true;
    try vm.stack.pushOwned(core.JSValue.boolean(deleted));
}

pub noinline fn deletePropertyVm(vm: *Vm) HostError!void {
    const ctx = vm.ctx;
    const output = vm.output;
    const global = vm.global;
    const stack = vm.stack;
    const frame = vm.frame;
    const catch_target = vm.catch_target;
    const prop = try stack.pop();
    const obj = try stack.pop();
    // qjs js_operator_delete runs JS_ValueToAtom on the key
    // FIRST: user toString/Symbol.toPrimitive side effects (and their
    // exceptions) fire before any base check.
    const atom_id = object_ops.toPropertyKeyAtom(ctx, output, global, prop, vm.function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
        return err;
    };
    if (obj.is(.null_value) or obj.is(.undefined_value)) {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.TypeError)) return;
        return error.TypeError;
    }
    // JS_DeleteProperty converts the base via JS_ToObject and
    // runs the real delete on the wrapper, so string-exotic non-configurable
    // props (indices, .length) report false and strict mode throws.
    const obj_value = if (obj.is(.object)) obj else object_ops.primitiveObjectForAccess(ctx.runtime, global, obj) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
        return err;
    };
    const object = try property_ops.expectObject(obj_value);
    const deleted = if (object.proxyTarget() != null) blk: {
        break :blk object_ops.deleteValueProperty(ctx, output, global, obj_value, object, atom_id, vm.function, frame) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return;
            return err;
        };
    } else if (object.isArray() and atom_id == core.atom.ids.length)
        false
    else if (try array_ops.typedArrayCanonicalDelete(ctx.runtime, object, atom_id)) |typed_deleted|
        typed_deleted
    else
        object.deleteProperty(ctx.runtime, atom_id);
    if (!deleted and vm.function.isStrictMode()) {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, error.TypeError)) return;
        return error.TypeError;
    }
    try stack.pushOwned(core.JSValue.boolean(deleted));
}
