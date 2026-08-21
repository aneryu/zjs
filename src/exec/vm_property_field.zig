//! Property field and array-element opcode handlers (get/put_field, get/put_array_el, in/instanceof, to_prop_key).

const std = @import("std");
const builtin = @import("builtin");
const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const method_ids = core.host_function.builtin_method_ids;
const frame_mod = @import("frame.zig");
const property_direct = @import("property_direct.zig");
const property_ops = @import("property_ops.zig");
const stack_mod = @import("stack.zig");
const value_ops = @import("value_ops.zig");

const call_runtime = @import("call_runtime.zig");
const builtin_glue = @import("builtin_glue.zig");
const array_ops = @import("array_ops.zig");
const forof_ops = @import("forof_ops.zig");
const object_ops = @import("object_ops.zig");
const regexp_fastpath = @import("regexp_fastpath.zig");
const slot_ops = @import("slot_ops.zig");
const string_ops = @import("string_ops.zig");
const objectFromValue = object_ops.objectFromValue;
const readInt = call_runtime.readInt;
const varRefCellFromValue = slot_ops.varRefCellFromValue;

// Helpers that remain in vm_property.zig (shared with the leftover handlers).
const vm_property = @import("vm_property.zig");
const BindingGet = vm_property.BindingGet;
const BindingPut = vm_property.BindingPut;
const DecodedFalseBranch = vm_property.DecodedFalseBranch;
const GlobalBindingGet = vm_property.GlobalBindingGet;
const GlobalBindingPut = vm_property.GlobalBindingPut;
const LoopLimitGet = vm_property.LoopLimitGet;
const Step = vm_property.Step;
const atomAsciiText = vm_property.atomAsciiText;
const atomStringValueForFastPath = vm_property.atomStringValueForFastPath;
const bindingReadableBorrowed = vm_property.bindingReadableBorrowed;
const bindingStoreWritableForFastPath = vm_property.bindingStoreWritableForFastPath;
const decodeBindingGet = vm_property.decodeBindingGet;
const decodeBindingPut = vm_property.decodeBindingPut;
const decodeFalseBranch = vm_property.decodeFalseBranch;
const decodeGlobalDataGet = vm_property.decodeGlobalDataGet;
const decodeGlobalPut = vm_property.decodeGlobalPut;
const decodeGotoTarget = vm_property.decodeGotoTarget;
const decodeLocalGet = vm_property.decodeLocalGet;
const decodeLocalPut = vm_property.decodeLocalPut;
const decodeLoopLimitGet = vm_property.decodeLoopLimitGet;
const decodeOptionalLocalCompletionTail = vm_property.decodeOptionalLocalCompletionTail;
const decodeStringSliceConstLocalStore = vm_property.decodeStringSliceConstLocalStore;
const fastArrayPrototypeMethodIsDefault = vm_property.fastArrayPrototypeMethodIsDefault;
pub const fastDenseArrayElementValue = vm_property.fastDenseArrayElementValue;
pub const fastMappedArgumentsElementValue = vm_property.fastMappedArgumentsElementValue;
pub const fastArrayOwnIntElementValue = vm_property.fastArrayOwnIntElementValue;
pub const fastArrayOwnIntElementSet = vm_property.fastArrayOwnIntElementSet;
const fastRegExpPrototypeMethodIsDefault = vm_property.fastRegExpPrototypeMethodIsDefault;
const finishUndefinedCallResult = vm_property.finishUndefinedCallResult;
const frameHasVarRefBinding = vm_property.frameHasVarRefBinding;
const immediateInt32Operand = vm_property.immediateInt32Operand;
const isHostOutputFunctionValue = vm_property.isHostOutputFunctionValue;
const loopLimitReadableInt32 = vm_property.loopLimitReadableInt32;
const mathMinMaxInductionRangeSum = vm_property.mathMinMaxInductionRangeSum;
const mathMinMaxPrimitive2 = vm_property.mathMinMaxPrimitive2;
const sameBinding = vm_property.sameBinding;
const slotValueBorrowed = vm_property.slotValueBorrowed;
const storeBindingOwnedValue = vm_property.storeBindingOwnedValue;
const storeLocalCompletionBorrowedValue = vm_property.storeLocalCompletionBorrowedValue;
const storeStringSliceConstLocal = vm_property.storeStringSliceConstLocal;
const stringFromCharCodeInt32Arg = vm_property.stringFromCharCodeInt32Arg;
const varRefReadableBorrowed = vm_property.varRefReadableBorrowed;

const functionOwnDataPropertyValueForFastPath = property_direct.functionOwnDataPropertyValueForFastPath;
const functionOwnNativeBuiltinRefForFastPath = property_direct.functionOwnNativeBuiltinRefForFastPath;
const dataPropertyValueForFastPath = property_direct.dataPropertyValueForFastPath;
const globalOwnDataPropertyValue = property_direct.globalOwnDataPropertyValue;
const ordinaryDataPropertyValueOrUndefinedForFastPath = property_direct.ordinaryDataPropertyValueOrUndefinedForFastPath;
const ownDataPropertyValueMaterializedForFastPath = property_direct.ownDataPropertyValueMaterializedForFastPath;
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
    defer value.free(ctx.runtime);
    const key = try object_ops.toPropertyKeyValue(ctx, output, global, value, function, frame);
    errdefer key.free(ctx.runtime);
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
            const atom_id = readInt(u32, function.byteCode()[frame.pc..][0..4]);
            frame.pc += 4;
            if (stack.len() == 0) return error.StackUnderflow;
            const value = try stackValueFromTop(stack, 0);
            defer value.free(ctx.runtime);
            if (value.isObject()) {
                const object = try property_ops.expectObject(value);
                const name_value = try call_runtime.functionNameValueFromAtom(ctx.runtime, atom_id, null);
                defer name_value.free(ctx.runtime);
                try object_ops.defineFunctionNameProperty(ctx.runtime, object, name_value);
            }
        },
        op.set_name_computed => {
            if (stack.len() < 2) return error.StackUnderflow;
            const value = stack.values[stack.len() - 1].dup();
            defer value.free(ctx.runtime);
            const key = stack.values[stack.len() - 2].dup();
            defer key.free(ctx.runtime);
            if (value.isObject()) {
                const object = try property_ops.expectObject(value);
                const atom_id = try object_ops.toPropertyKeyAtom(ctx, output, global, key, function, frame);
                defer ctx.runtime.atoms.free(atom_id);
                const name_value = try call_runtime.functionNameValueFromAtom(ctx.runtime, atom_id, null);
                defer name_value.free(ctx.runtime);
                try object_ops.defineFunctionNameProperty(ctx.runtime, object, name_value);
            }
        },
        else => unreachable,
    }
}

pub noinline fn inOrInstanceof(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
) !Step {
    const err = if (opc == op.in)
        call_runtime.inOp(ctx, stack, output, global, function, frame)
    else
        call_runtime.instanceofOp(ctx, stack, output, global, function, frame);
    err catch |runtime_err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, runtime_err)) return .continue_loop;
        return runtime_err;
    };
    return .done;
}

pub noinline fn field(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
) align(16) !Step {
    const site_pc = frame.pc - 1;
    const atom_id = readInt(u32, function.byteCode()[frame.pc..][0..4]);
    frame.pc += 4;
    switch (opc) {
        op.get_field, op.get_field_field2 => {
            if (stack.len() == 0) return error.StackUnderflow;
            const top_index = stack.len() - 1;
            const receiver = stack.values[top_index];
            if (dataPropertyValueForFastPath(function, site_pc, ctx.runtime, receiver, atom_id)) |value| {
                replaceTopBorrowed(ctx.runtime, stack, top_index, receiver, value);
                return .done;
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
            // straight into JS_GetPropertyInternal (quickjs.c:19107-19160).
            if (ordinaryDataPropertyValueOrUndefinedForFastPath(ctx.runtime, receiver, atom_id)) |value| {
                replaceTopBorrowed(ctx.runtime, stack, top_index, receiver, value);
                return .done;
            }
            if (fastRegExpPrototypeMethodValue(ctx.runtime, receiver, atom_id)) |value| {
                replaceTopOwned(ctx.runtime, stack, top_index, receiver, value);
                return .done;
            }
            if (functionOwnDataPropertyValueForFastPath(ctx.runtime, receiver, atom_id)) |value| {
                replaceTopOwned(ctx.runtime, stack, top_index, receiver, value);
                return .done;
            }
            if (fastCollectionPrototypeMethodValue(ctx.runtime, receiver, atom_id)) |value| {
                replaceTopOwned(ctx.runtime, stack, top_index, receiver, value);
                return .done;
            }
            stack.setLen(top_index);
            const obj = receiver;
            defer obj.free(ctx.runtime);
            const value = object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                try forof_ops.closeStackTopForOfIteratorForPendingErrorWithFrame(ctx, output, global, stack, frame);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            errdefer value.free(ctx.runtime);
            stack.pushOwnedAssumeCapacity(value);
        },
        op.get_field2, op.get_field2_call_method => {
            const obj = try stackValueFromTop(stack, 0);
            defer obj.free(ctx.runtime);
            if (dataPropertyValueForFastPath(function, site_pc, ctx.runtime, obj, atom_id)) |value| {
                stack.pushAssumeCapacity(value);
                return .done;
            }
            // Removed for the same reason as the get_field arm above: the
            // resident `op_get_field2` already ran this exact walk and tailed
            // here only because it missed (quickjs.c:19107-19160).
            if (ordinaryDataPropertyValueOrUndefinedForFastPath(ctx.runtime, obj, atom_id)) |value| {
                stack.pushAssumeCapacity(value);
                return .done;
            }
            if (fastRegExpPrototypeMethodValue(ctx.runtime, obj, atom_id)) |value| {
                stack.pushOwnedAssumeCapacity(value);
                return .done;
            }
            if (functionOwnDataPropertyValueForFastPath(ctx.runtime, obj, atom_id)) |value| {
                stack.pushOwnedAssumeCapacity(value);
                return .done;
            }
            if (fastCollectionPrototypeMethodValue(ctx.runtime, obj, atom_id)) |value| {
                stack.pushOwnedAssumeCapacity(value);
                return .done;
            }
            const value = object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                try forof_ops.closeStackTopForOfIteratorForPendingErrorWithFrame(ctx, output, global, stack, frame);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            errdefer value.free(ctx.runtime);
            try stack.pushOwned(value);
        },
        op.put_field => {
            const value = try stack.pop();
            var value_consumed = false;
            defer if (!value_consumed) value.free(ctx.runtime);
            const obj = try stack.pop();
            defer obj.free(ctx.runtime);
            if (setArrayLengthForPutFieldFastPath(ctx.runtime, obj, atom_id, value)) return .done;
            // Single-walk cold put (qjs OP_put_field's slow path is ONE call
            // into JS_SetPropertyInternal, quickjs.c:19188-19203 ->
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
                    .done => {
                        value_consumed = true;
                        return .done;
                    },
                    .slow => {},
                }
            }
            const result = object_ops.setValueProperty(ctx, output, global, obj, atom_id, value, function, frame) catch |err| {
                try forof_ops.closeStackTopForOfIteratorForPendingErrorWithFrame(ctx, output, global, stack, frame);
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            result.free(ctx.runtime);
        },
        else => unreachable,
    }
    return .done;
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
/// #name through OP_scope_get_private_field, quickjs.c:27430, resolved at
/// 27574 into the OP_get_private_field family, 19232).
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
    // JS_VALUE_GET_TAG(obj)==JS_TAG_OBJECT check (quickjs.c:19107-19160): a non-object
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
    const probe_mapped_arguments = !trust_mapped_arguments_probe and core.atom.isTaggedInt(atom_id);
    // Phase 1 — the absence-authoritative prefix (only compiled for callers that
    // ask for the tri-state). qjs ends its inline window at the chain root with
    // `p = p->shape->proto; if (!p) { val = JS_UNDEFINED; break; }`
    // (quickjs.c:19141-19143), because there a shape miss on a non-exotic link
    // is the whole answer. After deleting the zjs-only class-name miss
    // fallback, a complete ordinary miss is also JS_UNDEFINED
    // (quickjs.c:8355-8363). `undefined` is still synthesized only when EVERY
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
            // probe misses (quickjs.c:19135-19141): an own plain-data hit — a
            // sparse array element, named data on a typed array, anything the
            // shape authoritatively owns — never pays the class test.
            //
            // For `object`/`global_object`, `classNeedsSlowPropertyAccess`
            // reduces exactly to the exotic-methods bit (neither class appears
            // in any of its slow arms), so an authoritative link costs one
            // compare plus one bit test instead of the whole class switch.
            if (object.class_id == core.class.ids.object or object.isGlobal()) {
                if (object.hasExoticMethods()) return null;
                object = object.getPrototype() orelse {
                    absent.* = true;
                    return null;
                };
                continue;
            }
            // qjs GET_FIELD_INLINE (quickjs.c:19135-19138): `is_exotic` after
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
/// canonical numeric indices and `length` (quickjs.c:19135-19138). A
/// named non-index atom cannot be an element or the length slot, so the
/// GET_FIELD_INLINE proto walk is semantically the same as for a plain
/// object. Tagged-int atoms cover the interned 0..2^31-1 index window;
/// `length` stays on the slow arm so the dense-array length scalar is
/// not skipped. TypedArray / Proxy / String objects are not included.
inline fn namedAtomUsesOrdinaryWalkOnIndexExotic(class_id: core.class.ClassId, atom_id: core.Atom) bool {
    if (core.atom.isTaggedInt(atom_id) or atom_id == core.atom.ids.length) return false;
    return class_id == core.class.ids.array or
        class_id == core.class.ids.arguments or
        class_id == core.class.ids.mapped_arguments;
}

/// Hot-handler variant: returns the BORROWED own/prototype data slot address
/// so the resident get_field handlers can re-load it as two 64-bit integer
/// words (see findOwnDataSlotFast). The pointer is only valid until the next
/// potentially-shape-mutating operation; both callers consume it immediately.
pub inline fn getFieldFastSlot(rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom) ?*const core.JSValue {
    var absent = false;
    // Named bytecode atom: never a tagged-int / mapped-args binding (F2).
    return getFieldFastSlotWithExoticOrder(rt, receiver, atom_id, true, true, false, &absent);
}

/// Tri-state twin of `getFieldFastSlot` for op_get_field / op_get_field2.
/// A null return now carries a discriminator: `absent.*` is set only when the
/// walk ran off the end of a chain whose every link was absence-authoritative
/// (see the terminal comment above), i.e. the property is genuinely missing and
/// the result is `undefined` — qjs GET_FIELD_INLINE's `if (!p) { val =
/// JS_UNDEFINED; break; }` (quickjs.c:19141-19143). `absent.*` false keeps the
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
        if (atom_id == core.atom.ids.length or core.atom.isTaggedInt(atom_id)) return null;
        break :blk .string_prototype;
    } else if (receiver.isNumber())
        .number_prototype
    else if (receiver.isBool())
        .boolean_prototype
    else if (receiver.isBigInt())
        .bigint_prototype
    else if (receiver.isSymbol())
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
        .data => .{ .borrowed = holder.prop_values[index].slot.data },
        .accessor => accessor: {
            const getter = holder.prop_values[index].slot.accessor.getterValue();
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
        // (quickjs.c:6135), which walks hash_next off the already-loaded property
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
    // Trusted hash-chain probe (qjs find_own_property, quickjs.c:6135), matching
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
                .data => .{ .borrowed = object.prop_values[index].slot.data },
                .accessor => .{ .getter = object.prop_values[index].slot.accessor.getterValue() },
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
                .data => .{ .borrowed = object.prop_values[index].slot.data },
                .accessor => .{ .getter = object.prop_values[index].slot.accessor.getterValue() },
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
        if (object.class_id == core.class.ids.object or object.isArray() or object.isGlobal()) {
            return switch (property_direct.ordinaryComputedPropertyLookupForFastPath(rt, receiver, atom_id)) {
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
/// symbol value directly into its atom (quickjs.c:9012-9015), then sends strings
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
        if (core.array.arrayIndexFromAtom(&rt.atoms, atom_id)) |index| {
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
/// ToPropertyKey/string conversion (quickjs.c:9012-9015).  Both returned ids
/// are borrowed from the still-live key value; a caller that can re-enter must
/// retain the atom first.
pub inline fn existingPropertyKeyAtomForFastPath(value: core.JSValue) ?core.Atom {
    if (value.asSymbolAtom()) |atom_id| return atom_id;
    return string_ops.stringAtomId(value);
}

/// Hot-handler variant of the qjs OP_put_field fast window (quickjs.c:19188-
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
/// - zjs-only deviation, same as getFieldFastSlot: a mapped Arguments
///   receiver bails before probing — its numeric bindings live in
///   out-of-shape var-ref cells, so a shape data hit could be a stale mirror
///   and a direct slot write would desync the aliased parameter.
/// The pointer is only valid until the next potentially-shape-mutating
/// operation; both callers consume it immediately.
pub inline fn putFieldFastSlot(rt: *core.JSRuntime, receiver: core.JSValue, atom_id: core.Atom) ?*core.JSValue {
    // Trusted-expression receiver contract (qjs OP_put_field's raw
    // JS_VALUE_GET_OBJ, quickjs.c:19190-19192): expression receivers are
    // never cells, so the header-kind recheck is a Debug assert only.
    const object = object_ops.objectFromValueTrustedExpression(receiver) orelse return null;
    // Bytecode put_field atom operands are proven non-private (qjs
    // OP_put_field's inline window carries no private probe either,
    // quickjs.c:19177-19199; private stores are OP_put_private_field only).
    debugAssertNonPrivateFieldOperandAtom(rt, atom_id);
    if (object.class_id == core.class.ids.mapped_arguments) return null;
    var slow_property = false;
    if (object.findWritableOwnDataSlotFast(atom_id, &slow_property)) |slot| return slot;
    return null;
}

inline fn replaceTopBorrowed(
    rt: *core.JSRuntime,
    stack: *stack_mod.Stack,
    index: usize,
    old_value: core.JSValue,
    new_value: core.JSValue,
) void {
    stack.values[index] = if (new_value.requiresRefCount()) new_value.dup() else new_value;
    old_value.free(rt);
}

inline fn replaceTopOwned(
    rt: *core.JSRuntime,
    stack: *stack_mod.Stack,
    index: usize,
    old_value: core.JSValue,
    new_value: core.JSValue,
) void {
    stack.values[index] = new_value;
    old_value.free(rt);
}

fn setArrayLengthForPutFieldFastPath(
    rt: *core.JSRuntime,
    receiver: core.JSValue,
    atom_id: core.Atom,
    value: core.JSValue,
) bool {
    if (atom_id != core.atom.ids.length) return false;
    const length = value.asInt32() orelse return false;
    if (length < 0) return false;
    const object = objectFromValue(receiver) orelse return false;
    if (!object.isArray() or object.hasExoticMethods() or object.proxyTarget() != null) return false;
    if (!object.flags.length_writable) return false;
    const new_len: u32 = @intCast(length);
    if (new_len < object.arrayLength()) {
        if (object.arrayElementStorageMode() != .dense) return false;
        for (object.shapeProps()) |prop| {
            if (core.property.Flags.fromBits(prop.flags).deleted) continue;
            const index = core.array.arrayIndexFromAtom(&rt.atoms, prop.atom_id) orelse continue;
            if (index >= new_len) return false;
        }
        object.truncateArrayElements(rt, new_len);
    }
    // Growth keeps the fast array and just extends `.length` into tail holes
    // (faithful to set_array_length quickjs.c:9447-9455 — count is unchanged,
    // no sparse conversion). This is the `arr.length = bigger` fast path.
    object.setArrayLength(new_len);
    return true;
}

/// OP_put_array_el continuation after the resident handler misses. The caller
/// has already published pc/sp, so this is the direct counterpart of qjs's
/// put_array_el_slow_path -> JS_SetPropertyValue call, without the shared
/// get/put opcode switch.
pub inline fn putArrayElementAfterFastMiss(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
) !Step {
    const value = try stack.pop();
    defer value.free(ctx.runtime);
    const key = try stack.pop();
    defer key.free(ctx.runtime);
    const obj = try stack.pop();
    defer obj.free(ctx.runtime);
    // The resident OP_put_array_el handler already ran qjs
    // JS_SetPropertyValue's object+int class switch (Array, slow Array, then
    // TypedArray). On that exact miss, continue at qjs's JS_ValueToAtom ->
    // JS_SetPropertyInternal slow-path boundary instead of repeating the same
    // typed/dense probes here.
    const int_object_fast_miss = key.isInt() and obj.isObject();
    if (!int_object_fast_miss) {
        switch (putTypedArrayElementFast(ctx.runtime, obj, key, value) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        }) {
            .handled => return .continue_loop,
            .not_typed_array => {},
        }
        switch (array_ops.putDenseArrayElementFast(ctx.runtime, obj, key, value)) {
            .handled => return .continue_loop,
            .out_of_memory => return error.OutOfMemory,
            .miss => {},
        }
    }
    if (int_object_fast_miss) {
        const index = key.asInt32().?;
        if (index >= 0) {
            // qjs JS_ValueToAtom -> __JS_AtomFromUInt32: a non-negative int32
            // key is already a tagged integer atom. No JSValue copy/string
            // conversion or dynamic atom ownership is needed.
            const atom_id = core.atom.atomFromUInt32(@intCast(index));
            const result = object_ops.setValueProperty(ctx, output, global, obj, atom_id, value, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            result.free(ctx.runtime);
            return .done;
        }
    }
    const key_value = object_ops.toPropertyKeyValue(ctx, output, global, key, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    defer key_value.free(ctx.runtime);
    // qjs JS_SetPropertyValue slow path (quickjs.c:10060) runs
    // JS_ValueToAtom on the key BEFORE JS_SetPropertyInternal's nullish base
    // TypeError, so user key-coercion side effects fire first.
    if (obj.isNull() or obj.isUndefined()) {
        _ = object_ops.throwNullishComputedPropertyTypeError(ctx, global, obj, key_value) catch |err| {
            if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
            return err;
        };
        unreachable;
    }
    if (!int_object_fast_miss) {
        switch (array_ops.putDenseArrayElementFast(ctx.runtime, obj, key_value, value)) {
            .handled => return .continue_loop,
            .out_of_memory => return error.OutOfMemory,
            .miss => {},
        }
    }
    const atom_id = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
    defer ctx.runtime.atoms.free(atom_id);
    const result = object_ops.setValueProperty(ctx, output, global, obj, atom_id, value, function, frame) catch |err| {
        if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
        return err;
    };
    result.free(ctx.runtime);
    return .done;
}

pub noinline fn getArrayElement(
    ctx: *core.JSContext,
    output: ?*std.Io.Writer,
    global: *core.Object,
    stack: *stack_mod.Stack,
    function: *const bytecode.FunctionBytecode,
    frame: *frame_mod.Frame,
    catch_target: *?usize,
    opc: u8,
) !Step {
    switch (opc) {
        op.get_array_el => {
            const key = try stack.pop();
            defer key.free(ctx.runtime);
            const obj = try stack.pop();
            defer obj.free(ctx.runtime);
            if (obj.isNull() or obj.isUndefined()) {
                _ = object_ops.throwNullishComputedPropertyTypeError(ctx, global, obj, key) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                unreachable;
            }
            // Mapped-arguments first: an integer key used to intern as an
            // atom and fall into getValueProperty (full resolver) before the
            // var-ref arm below could run. qjs JS_GetPropertyValue switches
            // on class_id first (quickjs.c:9047-9049).
            if (fastMappedArgumentsElementValue(obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            if (existingPropertyKeyAtomForFastPath(key)) |atom_id| {
                // String.atom_id is a weak cache, while a symbol value carries
                // its atom id in the live body. A Proxy/getter can re-enter;
                // retain either borrowed id across the complete lookup.
                const retained_atom = ctx.runtime.atoms.dup(atom_id);
                defer ctx.runtime.atoms.free(retained_atom);
                const value = object_ops.getValueProperty(ctx, output, global, obj, retained_atom, function, frame) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            if (fastDenseArrayElementValue(obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            if (fastStringIndexValue(ctx.runtime, obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            if (fastTypedArrayElementValue(obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            const atom_id = object_ops.toPropertyKeyAtom(ctx, output, global, key, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            defer ctx.runtime.atoms.free(atom_id);
            const value = object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            errdefer value.free(ctx.runtime);
            try stack.pushOwned(value);
        },
        op.get_array_el2 => {
            const key = try stackValueFromTop(stack, 0);
            defer key.free(ctx.runtime);
            const obj = try stackValueFromTop(stack, 1);
            defer obj.free(ctx.runtime);
            if (obj.isNull() or obj.isUndefined()) {
                _ = object_ops.throwNullishComputedPropertyTypeError(ctx, global, obj, key) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                unreachable;
            }
            if (fastDenseArrayElementValue(obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                const old_value = stack.values[stack.len() - 1];
                stack.values[stack.len() - 1] = value;
                old_value.free(ctx.runtime);
                return .done;
            }
            if (fastStringIndexValue(ctx.runtime, obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                const old_value = stack.values[stack.len() - 1];
                stack.values[stack.len() - 1] = value;
                old_value.free(ctx.runtime);
                return .done;
            }
            if (fastTypedArrayElementValue(obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                const old_value = stack.values[stack.len() - 1];
                stack.values[stack.len() - 1] = value;
                old_value.free(ctx.runtime);
                return .done;
            }
            const key_value = object_ops.toPropertyKeyValue(ctx, output, global, key, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            defer key_value.free(ctx.runtime);
            const atom_id = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
            defer ctx.runtime.atoms.free(atom_id);
            const value = object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            errdefer value.free(ctx.runtime);
            const old_value = stack.values[stack.len() - 1];
            stack.values[stack.len() - 1] = value;
            old_value.free(ctx.runtime);
        },
        op.get_array_el3 => {
            const key = try stackValueFromTop(stack, 0);
            defer key.free(ctx.runtime);
            const obj = try stackValueFromTop(stack, 1);
            defer obj.free(ctx.runtime);
            if (obj.isNull() or obj.isUndefined()) {
                _ = object_ops.throwNullishComputedPropertyTypeError(ctx, global, obj, key) catch |err| {
                    if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                    return err;
                };
                unreachable;
            }
            if (fastDenseArrayElementValue(obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            if (fastStringIndexValue(ctx.runtime, obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            if (fastTypedArrayElementValue(obj, key)) |value| {
                errdefer value.free(ctx.runtime);
                try stack.pushOwned(value);
                return .done;
            }
            const key_value = object_ops.toPropertyKeyValue(ctx, output, global, key, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            var key_value_owned = true;
            defer if (key_value_owned) key_value.free(ctx.runtime);
            const atom_id = try property_ops.propertyKeyAtom(ctx.runtime, key_value);
            defer ctx.runtime.atoms.free(atom_id);
            const value = object_ops.getValueProperty(ctx, output, global, obj, atom_id, function, frame) catch |err| {
                if (try call_runtime.handleCatchableRuntimeError(ctx, output, stack, frame, catch_target, global, err)) return .continue_loop;
                return err;
            };
            errdefer value.free(ctx.runtime);
            const old_key = stack.values[stack.len() - 1];
            stack.values[stack.len() - 1] = key_value;
            key_value_owned = false;
            old_key.free(ctx.runtime);
            try stack.pushOwned(value);
        },
        else => unreachable,
    }
    return .done;
}

// qjs JS_GetPropertyValue TA arm (quickjs.c:9050-9083): one live-count
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
    const key_int = key.asInt32() orelse return null;
    if (key_int < 0) return null;
    const class_id = object.class_id;
    if (!core.class.isNumericTypedArrayClass(class_id)) return null;
    return readTypedArrayIndexFast(object, class_id, @intCast(key_int));
}

pub const TypedArrayWriteFast = enum { not_typed_array, handled };

/// qjs JS_SetPropertyValue (quickjs.c:9947) typed-array arm: a single
/// per-class_id store that, for each numeric element kind, converts the value
/// (which can run user code via valueOf/Symbol.toPrimitive and DETACH/RESIZE the
/// buffer) and stores into the typed buffer after a bounds RE-check. The
/// convert-first / recheck-after / silent-no-op-on-OOB ordering (qjs comment at
/// quickjs.c:9987 + the `ta_out_of_bound: return TRUE` leg) lives in the
/// canonical `typedArraySetElement` helper, which this fast probe delegates to as
/// the single source of truth for the value->bytes mapping.
///
/// Returns `.not_typed_array` when obj/key do not select a numeric typed-array
/// element (fall through to the dense/slow path); `.handled` when the write was
/// performed or correctly turned into a no-op (OOB / detached after conversion).
/// BigInt64/BigUint64 (kinds 11/12) punt to the slow path. A conversion that
/// throws (e.g. BigInt assigned to a non-BigInt array) surfaces as a Zig error
/// for the caller to route through handleCatchableRuntimeError.
pub fn putTypedArrayElementFast(rt: *core.JSRuntime, obj: core.JSValue, key: core.JSValue, value: core.JSValue) !TypedArrayWriteFast {
    const object = objectFromValue(obj) orelse return .not_typed_array;
    const key_int = key.asInt32() orelse return .not_typed_array;
    if (key_int < 0) return .not_typed_array;
    // A value object needs ToPrimitive (valueOf / Symbol.toPrimitive), which runs
    // user code and needs the full interpreter context (ctx/output/global) — that
    // conversion lives in the slow path's coerceTypedArrayElementForSet. The
    // canonical typedArraySetElement only coerces primitives, so an object value
    // punts to the slow path; the numeric-primitive write is the fast case.
    if (value.isObject()) return .not_typed_array;
    // A BigInt or Symbol value has a ToNumber that THROWS a TypeError, and per
    // IntegerIndexedElementSet (ToNumber at spec step 6) that throw must happen
    // BEFORE the in-bounds/immutable validity check. typedArraySetElement does the
    // validity check first (silent no-op on OOB/immutable), which would swallow the
    // throw for an out-of-bounds / immutable-buffer element — so punt these
    // throwing-conversion values to the slow path, which converts first. (Number /
    // string / boolean / null / undefined have non-throwing conversions, so the
    // validity-check-first order is observably identical for them — they stay fast.)
    if (value.isBigInt() or value.isSymbol()) return .not_typed_array;
    // Resolve the payload once. Its live count/data pair is maintained from the
    // backing ArrayBuffer's view list, exactly like qjs `u.array.count/u.ptr`.
    // Keep the qjs operation order: immutable reject -> coerce -> RE-check the
    // live pair -> store; detach/OOB after conversion is a silent no-op.
    const payload = object.typedArrayPayloadFast() orelse return .not_typed_array;
    const kind = payload.kind;
    if (kind < 1 or kind > 10) return .not_typed_array; // BigInt / non-TA -> slow
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
        if (value.asInt32()) |integer| {
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

fn fastRegExpPrototypeMethodValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    const object = objectFromValue(value) orelse return null;
    if (object.class_id != core.class.ids.regexp) return null;
    const name = rt.atoms.name(atom_id) orelse return null;
    const expected_id: u32 = if (std.mem.eql(u8, name, "test"))
        @intFromEnum(method_ids.regexp.PrototypeMethod.test_)
    else if (std.mem.eql(u8, name, "exec"))
        @intFromEnum(method_ids.regexp.PrototypeMethod.exec)
    else
        return null;

    if (object.hasOwnProperty(atom_id)) return null;
    const proto = object.getPrototype() orelse return null;
    const lookup = proto.getOwnDataPropertyLookup(atom_id) orelse return null;
    const method = lookup.value;
    const function_object = objectFromValue(method) orelse {
        method.free(rt);
        return null;
    };
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse {
        method.free(rt);
        return null;
    };
    if (native_ref.domain != .regexp or native_ref.id != expected_id) {
        method.free(rt);
        return null;
    }
    return method;
}

fn fastCollectionPrototypeMethodValue(rt: *core.JSRuntime, value: core.JSValue, atom_id: core.Atom) ?core.JSValue {
    const object = objectFromValue(value) orelse return null;
    const name = rt.atoms.name(atom_id) orelse return null;
    const expected_id = core.host_function.builtin_method_id_lookup.collection.fastPrototypeMethodIdForClass(object.class_id, name) orelse return null;
    if (object.hasOwnProperty(atom_id)) return null;
    const proto = object.getPrototype() orelse return null;
    const lookup = proto.getOwnDataPropertyLookup(atom_id) orelse return null;
    const method = lookup.value;
    const function_object = objectFromValue(method) orelse {
        method.free(rt);
        return null;
    };
    const native_ref = core.function.decodeNativeBuiltinId(function_object.nativeFunctionId()) orelse {
        method.free(rt);
        return null;
    };
    if (native_ref.domain != .collection or native_ref.id != expected_id) {
        method.free(rt);
        return null;
    }
    return method;
}

fn fastStringIndexValue(rt: *core.JSRuntime, value: core.JSValue, key: core.JSValue) ?core.JSValue {
    if (!value.isString() or !key.isInt()) return null;
    const index_i32 = key.asInt32().?;
    if (index_i32 < 0) return null;
    const index: usize = @intCast(index_i32);
    if (index >= core.string.stringValueLenUnchecked(value)) return null;
    const unit = core.string.stringValueCodeUnitAtUnchecked(value, index);
    if (unit <= 0x7f) {
        const cached = rt.cachedSingleByteString(@intCast(unit)) orelse return null;
        return cached.value().dup();
    }
    return null;
}

fn stackValueFromTop(stack: *const stack_mod.Stack, offset: u8) !core.JSValue {
    const index_from_top: usize = offset;
    if (index_from_top >= stack.len()) return error.StackUnderflow;
    return stack.values[stack.len() - 1 - index_from_top].dup();
}
