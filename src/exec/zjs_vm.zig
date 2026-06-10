//! QuickJS-aligned VM dispatcher for bytecode produced by
//! `frontend/zjs_parser.zig`, tracked by the current semantic
//! alignment plans.
//!
//! This is the only VM dispatcher after the parser-rewrite M2 swap.
//!
//! The dispatcher handles QuickJS-format opcodes emitted by the parser after
//! the bytecode pipeline has removed temporary opcodes.

const std = @import("std");

const bytecode = @import("../bytecode/root.zig");
const builtins = @import("../builtins/root.zig");
const core = @import("../core/root.zig");
const frontend = @import("../frontend/root.zig");
const call_mod = @import("call.zig");
const construct_mod = @import("construct.zig");
const frame_mod = @import("frame.zig");
const stack_mod = @import("stack.zig");
const arith_vm = @import("vm_arith.zig");
const call_vm = @import("vm_call.zig");
const class_vm = @import("object_ops.zig");
const control_vm = @import("vm_control.zig");
const date_vm = @import("date_ops.zig");
const eval_module_vm = @import("vm_eval_module.zig");
const exception_ops = @import("vm_exception_ops.zig");
const exceptions = @import("exceptions.zig");
const gen_async_vm = @import("vm_gen_async.zig");
const iter_vm = @import("iterator_ops.zig");
const json_vm = @import("json_ops.zig");
const literal_vm = @import("vm_literal.zig");
const property_vm = @import("vm_property.zig");
const profile_vm = @import("vm_profile.zig");
const regexp_vm = @import("vm_regexp.zig");
const shared_vm = @import("shared.zig");
const value_vm = @import("vm_value.zig");
const HostError = exceptions.HostError;

const op = bytecode.opcode.op;
const eval_class_field_initializer_flag: u16 = 0x8000;
const eval_parameter_initializer_flag: u16 = 0x4000;
const eval_ret_atom: core.Atom = 82;

/// Execute QuickJS-format bytecode.
pub fn run(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
) !core.JSValue {
    return runWithOutput(ctx, stack, function, null);
}

pub fn runWithOutput(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    output: ?*std.Io.Writer,
) !core.JSValue {
    const global_object = try contextGlobal(ctx);
    const this_value = if (function.flags.is_module or function.flags.runtime_strict) core.JSValue.undefinedValue() else global_object.value();
    return runWithArgs(ctx, stack, function, this_value, &.{}, &.{}, output, global_object, true, false, false, &.{}, &.{}, &.{}, &.{});
}

pub fn runWithOutputAndVarRefs(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    output: ?*std.Io.Writer,
    var_refs: []const core.JSValue,
) !core.JSValue {
    const global_object = try contextGlobal(ctx);
    const this_value = if (function.flags.is_module or function.flags.runtime_strict) core.JSValue.undefinedValue() else global_object.value();
    return runWithArgs(ctx, stack, function, this_value, &.{}, var_refs, output, global_object, false, false, false, &.{}, &.{}, &.{}, &.{});
}

pub fn runModuleWithOutputAndVarRefsState(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    output: ?*std.Io.Writer,
    var_refs: []const core.JSValue,
    module_state: *core.Object,
    resume_value: ?core.JSValue,
) !core.JSValue {
    const global_object = try contextGlobal(ctx);
    return runWithArgsState(ctx, stack, function, core.JSValue.undefinedValue(), &.{}, var_refs, output, global_object, false, false, false, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, &.{}, module_state, resume_value, null, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), false, false, core.JSValue.undefinedValue(), true, true);
}

/// Lazily build and cache the per-context global object. Subsequent
/// eval calls reuse this object, matching QuickJS semantics where
/// `JS_Eval` shares the per-context globals across invocations.
/// Building the global object eagerly installs every standard
/// constructor (Object, Array, String, ..., 43 specs and ~362
/// methods) plus generic host helpers such as `print` and `console`;
/// keeping it cached avoids paying that cost on every eval call.
pub fn contextGlobal(ctx: *core.JSContext) !*core.Object {
    if (ctx.global) |existing| return existing;
    const global_object = try core.Object.createWithOwnPropertyCapacity(
        ctx.runtime,
        core.class.ids.object,
        null,
        call_mod.contextGlobalOwnPropertyCapacity(),
    );
    errdefer global_object.value().free(ctx.runtime);
    global_object.is_global = true;
    try call_mod.installHostGlobals(ctx.runtime, global_object);
    const thrower = try throwTypeErrorIntrinsicForGlobal(ctx.runtime, global_object);
    thrower.free(ctx.runtime);
    const next_eval = global_object.getProperty(core.atom.predefinedId("eval", .string).?);
    const old_eval = ctx.eval_function;
    ctx.eval_function = next_eval;
    ctx.global = global_object;
    old_eval.free(ctx.runtime);
    return global_object;
}

pub fn runWithArgs(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    initial_this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const core.JSValue,
    output: ?*std.Io.Writer,
    global: *core.Object,
    break_var_ref_cycles_on_exit: bool,
    strict_unresolved_get_var: bool,
    stop_on_yield: bool,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    eval_var_ref_names: []const core.Atom,
    input_eval_var_refs: []const core.JSValue,
) !core.JSValue {
    return runWithArgsState(ctx, stack, function, initial_this_value, args, var_refs, output, global, break_var_ref_cycles_on_exit, strict_unresolved_get_var, stop_on_yield, eval_local_names, eval_local_slots, eval_var_ref_names, input_eval_var_refs, &.{}, &.{}, &.{}, &.{}, null, null, null, core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), core.JSValue.undefinedValue(), false, false, core.JSValue.undefinedValue(), true, false) catch |err| {
        if (!ctx.preserve_uncaught_exception and err != error.JSException and ctx.hasException()) ctx.clearException();
        return err;
    };
}

pub fn runWithArgsState(
    ctx: *core.JSContext,
    stack: *stack_mod.Stack,
    function: *const bytecode.Bytecode,
    initial_this_value: core.JSValue,
    args: []const core.JSValue,
    var_refs: []const core.JSValue,
    output: ?*std.Io.Writer,
    global: *core.Object,
    break_var_ref_cycles_on_exit: bool,
    strict_unresolved_get_var: bool,
    stop_on_yield: bool,
    eval_local_names: []const core.Atom,
    eval_local_slots: []core.JSValue,
    input_eval_var_ref_names: []const core.Atom,
    input_eval_var_refs: []const core.JSValue,
    inherited_eval_local_names: []const core.Atom,
    inherited_eval_local_slots: []core.JSValue,
    inherited_eval_var_ref_names: []const core.Atom,
    inherited_eval_var_refs: []const core.JSValue,
    generator_state: ?*core.Object,
    resume_value: ?core.JSValue,
    stop_before_pc: ?usize,
    current_function_value: core.JSValue,
    new_target_value: core.JSValue,
    constructor_this_value: core.JSValue,
    eval_global_var_bindings: bool,
    is_eval_code: bool,
    eval_with_object: core.JSValue,
    sync_global_lexical_locals: bool,
    suspend_on_module_await: bool,
) HostError!core.JSValue {
    const call_depth_guard = try call_vm.enterCallDepth(ctx, global);
    defer call_depth_guard.deinit();
    const call_profile_guard = call_vm.enterCallProfile(ctx.runtime);
    defer call_profile_guard.deinit();
    const backtrace_name = try exception_ops.backtraceFunctionNameAtom(ctx, function.name, current_function_value);
    defer ctx.runtime.atoms.free(backtrace_name);
    try ctx.pushBacktraceFrameWithResolver(backtrace_name, function.filename, function.line_num, function.col_num, function, exception_ops.resolveBacktraceLocation);
    defer ctx.popBacktraceFrame();

    var frame = frame_mod.Frame.init(function);
    ctx.borrowBacktracePc(&frame.pc);
    defer {
        if (break_var_ref_cycles_on_exit) _ = ctx.runtime.runObjectCycleRemoval();
    }
    defer frame.deinit(&ctx.runtime.memory, ctx.runtime);
    var frame_eval_var_refs = try frame.initCallBindings(ctx.runtime, .{
        .initial_this_value = initial_this_value,
        .current_function_value = current_function_value,
        .new_target_value = new_target_value,
        .constructor_this_value = constructor_this_value,
        .eval_local_names = eval_local_names,
        .eval_local_slots = eval_local_slots,
        .input_eval_var_ref_names = input_eval_var_ref_names,
        .input_eval_var_refs = input_eval_var_refs,
        .inherited_eval_local_names = inherited_eval_local_names,
        .inherited_eval_local_slots = inherited_eval_local_slots,
        .inherited_eval_var_ref_names = inherited_eval_var_ref_names,
        .inherited_eval_var_refs = inherited_eval_var_refs,
    });
    defer frame_eval_var_refs.deinit(ctx.runtime);
    const eval_var_ref_names = frame.eval_var_ref_names;
    const eval_var_refs = frame.eval_var_refs;

    var frame_roots = frame_mod.FrameRootScope{};
    frame_roots.init(ctx.runtime, stack, &frame, &frame_eval_var_refs);
    defer frame_roots.deinit();

    const use_inline_frame_storage = generator_state == null and !function.flags.is_generator and !function.flags.is_async;
    try call_vm.initFrameLocals(ctx, function, &frame, eval_local_names, eval_local_slots, use_inline_frame_storage);
    try frame.initArguments(&ctx.runtime.memory, args, use_inline_frame_storage);
    try call_vm.initFrameVarRefs(ctx, global, function, &frame, var_refs, use_inline_frame_storage);

    const resume_state = try gen_async_vm.resumeExecutionState(ctx, stack, function, &frame, generator_state, resume_value, generatorYieldStarSuspended, generatorResumeCompletionType, setGeneratorYieldStarSuspended, setGeneratorResumeCompletionType);
    errdefer {
        closeFrameDestructuringIteratorsForAbruptCompletion(ctx, output, global, stack, &frame);
    }
    var catch_target = try gen_async_vm.completeResumeState(ctx, output, global, stack, function, &frame, resume_state, resume_value, closeForAwaitIteratorForPendingError, closeStackTopForOfIteratorForPendingError, handleCatchableRuntimeError);
    var interrupt_poller = control_vm.InterruptPoller.init(ctx.runtime);
    while (frame.pc < function.code.len) {
        try interrupt_poller.poll(ctx.runtime);
        if (try gen_async_vm.stopBeforePc(ctx, stack, &frame, generator_state, stop_before_pc)) |result| return result;

        const opc = function.code[frame.pc];
        frame.pc += 1;
        const opcode_profile_scope = profile_vm.enterOpcode(ctx.runtime, opc);
        defer opcode_profile_scope.deinit();
        switch (opc) {
            // ---- Push constants ----
            op.push_i32 => try value_vm.pushInt32Operand(stack, function, &frame),
            op.push_bigint_i32 => try value_vm.pushBigIntI32Operand(stack, function, &frame),
            op.push_i16 => {
                try value_vm.pushI16OperandVm(ctx, stack, function, &frame, .{
                    .global = global,
                    .eval_local_names = eval_local_names,
                    .eval_var_ref_names = eval_var_ref_names,
                    .eval_with_object = eval_with_object,
                }, property_vm.tryFuseGlobalInt32PrefixTermsStore, globalLexicalValue);
            },
            op.push_i8 => try value_vm.pushI8Operand(stack, function, &frame),
            op.push_minus1 => try value_vm.pushSmallIntMaybeFuse(stack, function, &frame, -1),
            op.push_0 => try value_vm.pushSmallIntMaybeFuse(stack, function, &frame, 0),
            op.push_1 => try value_vm.pushSmallIntMaybeFuse(stack, function, &frame, 1),
            op.push_2 => try value_vm.pushSmallIntMaybeFuse(stack, function, &frame, 2),
            op.push_3 => try value_vm.pushSmallIntMaybeFuse(stack, function, &frame, 3),
            op.push_4 => try value_vm.pushSmallIntMaybeFuse(stack, function, &frame, 4),
            op.push_5 => try value_vm.pushSmallIntMaybeFuse(stack, function, &frame, 5),
            op.push_6 => try value_vm.pushSmallIntMaybeFuse(stack, function, &frame, 6),
            op.push_7 => try value_vm.pushSmallIntMaybeFuse(stack, function, &frame, 7),
            op.push_const => try value_vm.pushConst(ctx, stack, function, &frame, opc),
            op.push_const8 => try value_vm.pushConst8(ctx, stack, function, &frame, opc),
            op.private_symbol => try value_vm.pushPrivateSymbol(ctx, stack, function, &frame),
            op.regexp => try regexp_vm.pushLiteral(ctx, stack, constructorPrototypeFromGlobal(ctx.runtime, global, "RegExp")),
            op.fclosure, op.fclosure8 => switch (try call_vm.closure(ctx, output, global, stack, function, &frame, &catch_target, opc, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, handleCatchableRuntimeError, pushFunctionClosure)) {
                .done => {},
                .continue_loop => continue,
            },
            op.undefined => try value_vm.pushUndefined(stack),
            op.null => try value_vm.pushNull(stack),
            op.push_false => try value_vm.pushBoolean(stack, false),
            op.push_true => try value_vm.pushBoolean(stack, true),

            // ---- Locals (F10.1b / F10.2 short-forms) ----
            // get_loc / put_loc / set_loc lowered from scope_get_var /
            // scope_put_var by `resolve_variables` when the atom
            // resolves to a `VarDef` in the parser's `function_def`.
            // `selectShortLoc` picks the shortest encoding:
            //   - idx ∈ [0, 4)    → 1-byte short form (idx in opcode)
            //   - idx ∈ [4, 256)  → 2-byte u8-form (`get_loc8`, ...)
            //   - idx ∈ [256, 2^16) → 3-byte u16-form
            op.get_loc, op.put_loc, op.set_loc, op.get_loc8, op.put_loc8, op.set_loc8, op.get_loc0, op.get_loc1, op.get_loc2, op.get_loc3, op.put_loc0, op.put_loc1, op.put_loc2, op.put_loc3, op.set_loc0, op.set_loc1, op.set_loc2, op.set_loc3, op.get_loc0_loc1 => try property_vm.loc(ctx, function, global, &frame, stack, opc, stop_before_pc == null, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, execGetLoc, execPutLoc, execSetLoc, setSlotValue, syncTopLevelGlobalLexicalLocal),

            op.get_arg, op.put_arg, op.set_arg, op.get_arg0, op.get_arg1, op.get_arg2, op.get_arg3, op.put_arg0, op.put_arg1, op.put_arg2, op.put_arg3, op.set_arg0, op.set_arg1, op.set_arg2, op.set_arg3 => try property_vm.arg(ctx, function, &frame, stack, opc, execGetArg, execPutArg, execSetArg),

            op.get_var_ref, op.get_var_ref_check, op.put_var_ref, op.put_var_ref_check, op.put_var_ref_check_init, op.set_var_ref, op.get_var_ref0, op.get_var_ref1, op.get_var_ref2, op.get_var_ref3, op.put_var_ref0, op.put_var_ref1, op.put_var_ref2, op.put_var_ref3, op.set_var_ref0, op.set_var_ref1, op.set_var_ref2, op.set_var_ref3 => {
                switch (try property_vm.varRefVm(ctx, function, global, &frame, stack, opc, &catch_target, eval_global_var_bindings, is_eval_code, stop_before_pc == null, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, execGetVarRefMaybeTdz, execPutVarRef, execSetVarRef, globalLexicalValue, setSlotValue, syncTopLevelGlobalLexicalLocal, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- TDZ (Temporal Dead Zone) for let/const ----
            // Emitted by resolve_variables for lexical locals:
            //   set_loc_uninitialized: mark slot as in-TDZ (prologue).
            //   get_loc_check: read; throw ReferenceError if in TDZ.
            //   put_loc_check: write; throw ReferenceError if in TDZ.
            //   put_loc_check_init: write + clear TDZ flag.
            op.set_loc_uninitialized, op.get_loc_check, op.put_loc_check, op.put_loc_check_init => {
                switch (try property_vm.checkedLocVm(ctx, function, global, &frame, stack, opc, &catch_target, stop_before_pc == null, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_with_object, globalLexicalValue, pushSlotValue, setSlotValue, syncTopLevelGlobalLexicalLocal, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.push_atom_value => {
                try value_vm.pushAtomValueVm(ctx, stack, function, &frame, .{
                    .global_env = .{
                        .global = global,
                        .eval_local_names = eval_local_names,
                        .eval_var_ref_names = eval_var_ref_names,
                        .eval_with_object = eval_with_object,
                    },
                    .regexp_prototype = constructorPrototypeFromGlobal(ctx.runtime, global, "RegExp"),
                }, property_vm.tryFuseAtomPercentHexGlobalStringStore, regexp_vm.tryPushLiteralFromAtomPair, globalLexicalValue);
            },
            op.push_empty_string => try value_vm.pushEmptyString(ctx, stack),
            op.to_propkey => switch (try property_vm.toPropKeyVm(ctx, output, global, stack, function, &frame, &catch_target, toPropertyKeyValue, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },
            op.to_propkey2 => switch (try property_vm.toPropKey2Vm(ctx, output, global, stack, function, &frame, &catch_target, toPropertyKeyValue, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },
            op.set_name, op.set_name_computed => try property_vm.setName(ctx, output, global, stack, function, &frame, opc, toPropertyKeyAtom, functionNameValueFromAtom, defineFunctionNameProperty),

            // ---- Stack manipulation ----
            op.drop => switch (try value_vm.drop(ctx.runtime, stack)) {
                .value => {},
                .catch_target => |target| {
                    catch_target = target;
                    continue;
                },
            },
            op.nip_catch => try value_vm.nipCatch(ctx.runtime, stack),
            op.dup => try value_vm.dup(ctx, stack, opc),
            op.swap => try value_vm.swap(ctx, stack),

            // ---- Return ----
            op.@"return" => return control_vm.returnTop(ctx, stack, &frame, generator_state),
            op.return_undef => return control_vm.returnUndefined(ctx, &frame, generator_state),
            op.return_async => return control_vm.returnTop(ctx, stack, &frame, generator_state),

            // ---- Binary arithmetic ----
            op.add, op.sub, op.mul, op.div, op.mod, op.pow, op.shl, op.sar, op.shr, op.@"and", op.@"or", op.xor => {
                if (opc == op.add or opc == op.sub or opc == op.mul) {
                    if (try arith_vm.tryFuseLocalNumericBinary(ctx, stack, function, global, &frame, opc, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) {
                        continue;
                    }
                }
                if (opc == op.add and try arith_vm.tryFuseLocalStringAppend(ctx, stack, function, global, &frame, sync_global_lexical_locals, syncTopLevelGlobalLexicalLocal)) {
                    continue;
                }
                if (opc == op.add and try arith_vm.tryFuseGlobalDataAdd(ctx, stack, function, global, &frame, eval_local_names, eval_var_ref_names, eval_with_object)) {
                    continue;
                }
                switch (try arith_vm.binaryVm(ctx, stack, &frame, &catch_target, opc, output, global, toPrimitiveForAddition, toPrimitiveForNumber, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Comparisons ----
            op.lt, op.lte, op.gt, op.gte, op.eq, op.neq, op.strict_eq, op.strict_neq => {
                switch (try arith_vm.compareVm(ctx, stack, &frame, &catch_target, opc, output, global, toPrimitiveForNumber, toPrimitiveForAddition, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.in, op.instanceof => switch (try property_vm.inOrInstanceof(ctx, output, global, stack, function, &frame, &catch_target, opc, inOp, instanceofOp, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },
            op.private_in => {
                switch (try class_vm.privateInVm(ctx, output, global, stack, function, &frame, &catch_target, toPropertyKeyAtom, throwTypeErrorMessage, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Unary ----
            op.neg, op.plus => {
                switch (try arith_vm.unaryVm(ctx, stack, &frame, &catch_target, opc, output, global, toPrimitiveForNumber, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.not => {
                switch (try arith_vm.bitNotVm(ctx, stack, &frame, &catch_target, output, global, toPrimitiveForNumber, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.lnot => try value_vm.logicalNot(ctx.runtime, stack),
            op.inc, op.dec => {
                switch (try arith_vm.unaryVm(ctx, stack, &frame, &catch_target, opc, output, global, toPrimitiveForNumber, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Control flow ----
            op.goto => {
                if (stop_before_pc == null and property_vm.tryFuseBackwardGotoGlobalDataInt32CompareFalseBranch(ctx, global, function, &frame, op.goto, eval_local_names, eval_var_ref_names, eval_with_object)) continue;
                control_vm.jump32(function, &frame);
            },
            op.goto16 => {
                if (stop_before_pc == null and property_vm.tryFuseBackwardGotoGlobalDataInt32CompareFalseBranch(ctx, global, function, &frame, op.goto16, eval_local_names, eval_var_ref_names, eval_with_object)) continue;
                control_vm.jump16(function, &frame);
            },
            op.goto8 => {
                if (stop_before_pc == null and regexp_vm.tryFuseGoto8LiteralAssignmentLoop(ctx, global, function, &frame)) continue;
                if (stop_before_pc == null and control_vm.tryFuseGoto8LocalLessThanFalseBranch(function, &frame)) continue;
                if (stop_before_pc == null and property_vm.tryFuseBackwardGotoGlobalDataInt32CompareFalseBranch(ctx, global, function, &frame, op.goto8, eval_local_names, eval_var_ref_names, eval_with_object)) continue;
                control_vm.jump8(function, &frame);
            },
            op.if_false => try control_vm.branch32(ctx, stack, function, &frame, false),
            op.if_true => try control_vm.branch32(ctx, stack, function, &frame, true),
            op.if_false8 => try control_vm.branch8(ctx, stack, function, &frame, false),
            op.if_true8 => try control_vm.branch8(ctx, stack, function, &frame, true),
            op.gosub => try control_vm.gosub(function, &frame, stack),
            op.ret => try control_vm.ret(ctx, function, &frame, stack),

            // ---- Variable access ----
            op.get_var, op.get_var_undef => switch (try property_vm.getVar(ctx, output, global, stack, function, &frame, &catch_target, opc, sync_global_lexical_locals, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, eval_with_object, frameCurrentFunctionIsArrow, lookupFrameLocalValue, lookupFrameVarRef, lookupFrameFirstEvalBindingValue, withObjectBindingValue, lookupEvalBindingValue, lookupParentFunctionEvalBindingValue, directEvalShouldExposeImplicitArguments, frameArgumentsObject, globalLexicalValue, getValueProperty, setSlotValue, syncTopLevelGlobalLexicalLocal, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },
            op.make_loc_ref, op.make_arg_ref, op.make_var_ref_ref => try property_vm.makeSlotRef(ctx, stack, function, &frame, opc, ensureVarRefsCapacity, ensureVarRefCell, ensureLocalVarRefCell),
            op.make_var_ref => {
                switch (try property_vm.makeVarRefVm(ctx, output, global, stack, function, &frame, &catch_target, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.get_ref_value => {
                switch (try property_vm.getRefValueVm(ctx, output, global, stack, function, &frame, &catch_target, slotValueDup, toPropertyKeyAtom, getValueProperty, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.put_ref_value => {
                switch (try property_vm.putRefValueVm(ctx, output, global, stack, function, &frame, &catch_target, setSlotValue, toPropertyKeyAtom, setValueProperty, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.put_var => switch (try property_vm.putVar(ctx, output, global, stack, function, &frame, &catch_target, strict_unresolved_get_var, eval_global_var_bindings, is_eval_code, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, eval_with_object, setNamedSlotValue, setNamedVarRefValue, directEvalShouldExposeImplicitArguments, setGlobalLexicalValue, setValueProperty, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },
            op.with_get_var, op.with_delete_var, op.with_make_ref, op.with_get_ref, op.with_get_ref_undef => switch (try property_vm.withGetOrDelete(ctx, output, global, stack, function, &frame, &catch_target, opc, hasPropertyForWith, isBlockedByUnscopables, getValueProperty, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },
            op.with_put_var => switch (try property_vm.withPut(ctx, output, global, stack, function, &frame, &catch_target, hasPropertyForWith, setValueProperty, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },
            op.to_object => switch (try value_vm.toObjectVm(ctx, stack, &frame, &catch_target, global, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },

            // ---- Object properties ----
            op.get_field, op.get_field2, op.put_field => switch (try property_vm.field(ctx, output, global, stack, function, &frame, &catch_target, opc, sync_global_lexical_locals, eval_local_names, eval_var_ref_names, eval_var_refs, eval_with_object, getValueProperty, setValueProperty, setSlotValue, syncTopLevelGlobalLexicalLocal, closeStackTopForOfIteratorForPendingErrorWithFrame, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },
            op.get_private_field => {
                switch (try property_vm.getPrivateFieldVm(ctx, output, global, stack, function, &frame, &catch_target, toPropertyKeyAtom, getValueProperty, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.put_private_field => {
                switch (try property_vm.putPrivateFieldVm(ctx, output, global, stack, function, &frame, &catch_target, toPropertyKeyAtom, setValueProperty, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.define_private_field => {
                switch (try property_vm.definePrivateFieldVm(ctx, output, global, stack, function, &frame, &catch_target, toPropertyKeyAtom, defineClassFieldDataProperty, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Array elements ----
            op.get_array_el, op.get_array_el2, op.put_array_el => switch (try property_vm.arrayElement(ctx, output, global, stack, function, &frame, &catch_target, opc, sync_global_lexical_locals, toPropertyKeyAtom, toPropertyKeyValue, getValueProperty, setValueProperty, putDenseArrayElementFast, setSlotValue, syncTopLevelGlobalLexicalLocal, throwNullishComputedPropertyTypeError, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },

            // ---- Super ----
            op.get_super => try class_vm.getSuper(ctx, stack, &frame),
            op.get_super_value => switch (try class_vm.getSuperValue(ctx, output, global, stack, function, &frame, &catch_target, varRefSlotIsUninitialized, handleCatchableRuntimeError, slotValueDup, toPropertyKeyAtom, sameObjectIdentity, getSuperPropertyValue)) {
                .done => {},
                .continue_loop => continue,
            },
            op.put_super_value => switch (try class_vm.putSuperValue(ctx, output, global, stack, function, &frame, &catch_target, varRefSlotIsUninitialized, handleCatchableRuntimeError, slotValueDup, toPropertyKeyAtom, sameObjectIdentity, setSuperPropertyValue)) {
                .done => {},
                .continue_loop => continue,
            },

            // ---- Calls ----
            op.call, op.call0, op.call1, op.call2, op.call3 => {
                switch (try call_vm.call(ctx, output, global, stack, function, &frame, &catch_target, opc, execCall)) {
                    .done => {},
                    .continue_loop => continue,
                }
                if (frame.pc < function.code.len and function.code[frame.pc] == op.add and
                    try arith_vm.tryFuseLocalAddWithTopValue(ctx, stack, function, global, &frame, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal))
                {
                    continue;
                }
            },
            op.tail_call => switch (try call_vm.tailCall(ctx, output, global, stack, function, &frame, &catch_target, execCall)) {
                .handled => continue,
                .return_value => |value| return value,
            },
            op.eval => switch (try eval_module_vm.directEval(ctx, stack, function, &frame, &catch_target, output, global, eval_class_field_initializer_flag, eval_parameter_initializer_flag, execDirectEval)) {
                .done => {},
                .continue_loop => continue,
            },
            op.apply_eval => switch (try eval_module_vm.applyEval(ctx, stack, function, &frame, &catch_target, output, global, eval_class_field_initializer_flag, eval_parameter_initializer_flag, execApplyEval)) {
                .done => {},
                .continue_loop => continue,
            },
            op.import => try eval_module_vm.dynamicImport(ctx, output, global, stack, function, &frame, toStringForAnnexB, getValueProperty, promisePrototypeFromGlobal, createNamedError, rejectedPromiseForRuntimeError),
            op.prepare_call_prop_atom => switch (try call_vm.prepareCallPropAtom(ctx, output, global, stack, function, &frame, &catch_target, getValueProperty, closeStackTopForOfIteratorForPendingErrorWithFrame, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },
            op.call_prepared => switch (try call_vm.callPrepared(ctx, output, global, stack, function, &frame, &catch_target, qjsArrayMethodFastCall, callValueOrBytecodeClassMode, isCurrentSuperConstructor, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },
            op.call_method => switch (try call_vm.callMethod(ctx, output, global, stack, function, &frame, &catch_target, qjsArrayMethodFastCall, callValueOrBytecodeClassMode, isCurrentSuperConstructor, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },
            op.tail_call_method => switch (try call_vm.tailCallMethod(ctx, output, global, stack, function, &frame, &catch_target, qjsArrayMethodFastCall, callValueOrBytecode, handleCatchableRuntimeError)) {
                .handled => continue,
                .return_value => |value| return value,
            },

            // ---- Object/array literals ----
            op.object => try literal_vm.object(ctx, output, stack, function, &frame, global, eval_local_names, eval_var_ref_names, eval_with_object, objectPrototypeFromGlobal, globalLexicalValue),
            op.array_from => try literal_vm.arrayFrom(ctx, output, stack, function, &frame, global, arrayPrototypeFromGlobal),
            op.define_field => switch (try literal_vm.defineField(ctx, output, global, stack, function, &frame, &catch_target, remapPrivateAtomForOperation, defineClassFieldDataProperty, createDataPropertyOrThrow, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },
            op.set_proto => try literal_vm.setProto(ctx, stack),
            op.set_home_object => try class_vm.setHomeObject(ctx, stack, functionBytecodeFromValue),
            op.define_class, op.define_class_computed => {
                switch (try class_vm.defineClass(ctx, output, global, stack, function, &frame, &catch_target, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, handleCatchableRuntimeError, createBytecodeFunctionObject, objectPrototypeFromGlobal, isConstructorLike, getValueProperty, toPropertyKeyAtom, functionBytecodeFromValue, clearPrivateNameRemap, installLexicalPrivateNameRemap, installFreshPrivateNameRemap, copyPrivateNameRemap, objectFromValue, functionNameValueFromAtom, defineFunctionNameProperty, opc == op.define_class_computed)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.define_array_el => switch (try literal_vm.defineArrayEl(ctx, output, global, stack, function, &frame, &catch_target, toPropertyKeyAtom, createDataPropertyOrThrow, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },
            op.define_method => {
                switch (try class_vm.defineMethod(ctx, global, stack, function, &frame, &catch_target, remapPrivateAtomFromObject, functionBytecodeFromValue, installLexicalPrivateNameRemap, functionNameValueFromAtom, defineFunctionNameProperty, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.define_method_computed => {
                switch (try class_vm.defineMethodComputed(ctx, output, global, stack, function, &frame, &catch_target, toPropertyKeyAtom, remapPrivateAtomFromObject, functionBytecodeFromValue, installLexicalPrivateNameRemap, functionNameValueFromAtom, defineFunctionNameProperty, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.append => switch (try literal_vm.appendSpreadValuesVm(ctx, output, global, stack, opc, &frame, &catch_target, appendIteratorValues, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },
            op.copy_data_properties => {
                const mask = function.code[frame.pc];
                frame.pc += 1;
                switch (try literal_vm.copyDataProperties(ctx, output, global, stack, mask, function, &frame, &catch_target, objectRestOwnKeys, objectRestOwnPropertyDescriptor, getValueProperty, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Generators (F9) ----
            op.initial_yield => switch (try gen_async_vm.initialYield(ctx, stack, &frame, generator_state, stop_on_yield)) {
                .none => {},
                .continue_loop => continue,
                .return_value => |value| return value,
            },
            op.yield => switch (try gen_async_vm.yieldValue(ctx, stack, &frame, generator_state, stop_on_yield)) {
                .none => {},
                .continue_loop => continue,
                .return_value => |value| return value,
            },
            op.yield_star, op.async_yield_star => {
                const yield_star_result = try gen_async_vm.yieldStar(ctx, output, global, stack, function, &frame, generator_state, stop_on_yield, &catch_target, iteratorForValue, iteratorStepResult, setGeneratorYieldStarSuspended, handleCatchableRuntimeError);
                switch (yield_star_result) {
                    .none => {},
                    .continue_loop => continue,
                    .return_value => |value| return value,
                }
            },
            op.await => {
                const await_result = try gen_async_vm.awaitValue(ctx, output, global, stack, function, &frame, generator_state, suspend_on_module_await, stop_on_yield, &catch_target, settlePendingPromiseReaction, awaitPendingPromise, drainPendingPromiseJobs, awaitThenableValue, closeForAwaitIteratorForPendingError, closeStackTopForOfIteratorForPendingError, handleCatchableRuntimeError);
                switch (await_result) {
                    .none => {},
                    .continue_loop => continue,
                    .return_value => |value| return value,
                }
            },

            // ---- Global variable operations ----
            op.check_define_var, op.define_var, op.define_func, op.put_var_init => switch (try property_vm.globalDefinition(ctx, global, stack, function, &frame, &catch_target, opc, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, eval_global_var_bindings, is_eval_code, globalLexicalHas, defineGlobalLexicalValue, setFrameLocalValue, setFrameVarRefValue, setNamedSlotValue, setNamedVarRefValue, defineGlobalFunctionBindingValue, setGlobalLexicalValue, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },

            // ---- Special object (prologue) ----
            op.special_object => try literal_vm.specialObject(ctx, stack, function, &frame, global, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, capturedArgumentsObject, frameArgumentsObjectForSpecialObject),

            // ---- Typeof ----
            op.typeof => try value_vm.typeOf(ctx, stack),
            op.typeof_is_undefined => try value_vm.typeOfIsUndefined(ctx.runtime, stack),
            op.typeof_is_function => try value_vm.typeOfIsFunction(ctx.runtime, stack),

            // ---- Throw ----
            op.throw => switch (try control_vm.throwTop(ctx, output, global, stack, &frame, &catch_target, closeStackTopForOfIteratorForPendingError)) {
                .handled => continue,
            },
            op.throw_error => switch (try control_vm.throwErrorVm(ctx, stack, function, &frame, &catch_target, global, handleCatchableRuntimeError)) {
                .handled => continue,
            },
            op.@"catch" => try control_vm.catchTarget(function, &frame, stack, &catch_target),
            op.check_ctor => {
                switch (try call_vm.checkCtorVm(ctx, stack, &frame, &catch_target, global, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.check_ctor_return => {
                switch (try call_vm.checkCtorReturnVm(ctx, stack, &frame, &catch_target, global, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.init_ctor => {
                switch (try call_vm.initCtorVm(ctx, output, global, stack, function, &frame, &catch_target, constructValueOrBytecodeWithNewTarget, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.check_brand => {
                switch (try class_vm.checkBrandVm(ctx, stack, &frame, &catch_target, global, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.add_brand => {
                switch (try class_vm.addBrandVm(ctx, stack, &frame, &catch_target, global, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.close_loc => try property_vm.closeLoc(ctx, function, &frame, closeLocalVarRef),

            // ---- NOP ----
            op.nop => control_vm.nop(),

            // ---- Push this ----
            op.push_this => switch (try value_vm.pushThisVm(ctx, stack, &frame, &catch_target, global, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },

            // ---- Delete ----
            op.delete_var => try property_vm.deleteVar(ctx, global, stack, function, &frame, eval_local_names, eval_local_slots, eval_var_ref_names, eval_var_refs, deleteEvalBinding),
            op.delete => switch (try property_vm.deletePropertyVm(ctx, output, global, stack, function, &frame, &catch_target, deleteValueProperty, functionHasFrameBinding, typedArrayCanonicalDelete, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },

            // ---- Additional stack manipulation ----
            op.nip => try value_vm.nip(ctx, stack),
            op.nip1 => try value_vm.nip1(ctx, stack),
            op.dup1 => try value_vm.dup1(ctx, stack),
            op.dup2 => try value_vm.dup2(ctx, stack),
            op.dup3 => try value_vm.dup3(ctx, stack),
            op.insert2 => try value_vm.insert2(ctx, stack),
            op.insert3 => try value_vm.insert3(ctx, stack),
            op.insert4 => try value_vm.insert4(ctx, stack),
            op.rot3l => try value_vm.rot3l(ctx, stack),
            op.rot3r => try value_vm.rot3r(ctx, stack),
            op.rot4l => try value_vm.rot4l(ctx, stack),
            op.rot5l => try value_vm.rot5l(ctx, stack),
            op.perm3 => try value_vm.perm3(ctx, stack),
            op.perm4 => try value_vm.perm4(ctx, stack),
            op.perm5 => try value_vm.perm5(ctx, stack),
            op.swap2 => try value_vm.swap2(ctx, stack),
            op.is_undefined_or_null => try value_vm.isUndefinedOrNull(ctx.runtime, stack),
            op.is_undefined => try value_vm.isUndefined(ctx.runtime, stack),
            op.is_null => try value_vm.isNull(ctx.runtime, stack),
            op.get_length => switch (try literal_vm.getLength(ctx, output, global, stack, function, &frame, &catch_target, getValueProperty, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },
            op.post_inc, op.post_dec => {
                if (try arith_vm.tryFuseDroppedLocalPostUpdate(ctx, stack, function, global, &frame, opc, sync_global_lexical_locals, setSlotValue, syncTopLevelGlobalLexicalLocal)) {
                    continue;
                }
                if (try arith_vm.tryFuseDroppedGlobalDataPostUpdate(ctx, stack, function, global, &frame, opc, eval_local_names, eval_var_ref_names, eval_with_object)) {
                    continue;
                }
                switch (try arith_vm.postUpdateVm(ctx, stack, &frame, &catch_target, opc, output, global, toPrimitiveForNumber, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.inc_loc, op.dec_loc => {
                switch (try arith_vm.updateLocalVm(ctx, stack, function, global, &frame, &catch_target, opc, output, sync_global_lexical_locals, slotValueDup, setSlotValue, syncTopLevelGlobalLexicalLocal, toPrimitiveForNumber, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.add_loc => {
                switch (try arith_vm.addLocalVm(ctx, stack, function, global, &frame, &catch_target, output, sync_global_lexical_locals, slotValueDup, setSlotValue, syncTopLevelGlobalLexicalLocal, toPrimitiveForAddition, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.apply => {
                switch (try call_vm.apply(ctx, output, global, stack, function, &frame, &catch_target, argsFromArray, freeArgs, isCurrentSuperConstructor, currentArrowLexicalSuperThis, currentArrowConstructorThis, constructValueOrBytecodeWithNewTarget, callValueOrBytecodeClassMode, varRefSlotIsUninitialized, setSlotValue, pushSlotValue, initializeCurrentConstructorClassInstanceElements, setCurrentArrowLexicalThis, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Rest / spread ----
            op.rest => try literal_vm.rest(ctx, stack, function, &frame),

            // ---- Iterator protocol ----
            op.for_of_start, op.for_await_of_start => {
                switch (try iter_vm.forOfStartVm(ctx, output, global, stack, function, &frame, &catch_target, opc == op.for_await_of_start, getIteratorMethod, getValueProperty, isCallableValue, callValueOrBytecode, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.for_in_start => {
                switch (try iter_vm.forInStartVm(ctx, output, global, stack, &frame, &catch_target, createForInIterator, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.iterator_next => {
                switch (try iter_vm.iteratorNextVm(ctx, output, global, stack, function, &frame, &catch_target, callValueOrBytecode, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.iterator_check_object => {
                switch (try iter_vm.iteratorCheckObjectVm(ctx, stack, &frame, &catch_target, global, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.iterator_get_value_done => {
                switch (try iter_vm.iteratorGetValueDoneVm(ctx, output, global, stack, function, &frame, &catch_target, getValueProperty, valueTruthy, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.iterator_call => {
                switch (try iter_vm.iteratorCallVm(ctx, output, global, stack, function, &frame, &catch_target, getValueProperty, callValueOrBytecode, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.for_of_next => {
                switch (try iter_vm.forOfNextVm(ctx, output, global, stack, function, &frame, &catch_target, findForOfIteratorIndex, callValueOrBytecode, getValueProperty, valueTruthy, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },
            op.for_in_next => try iter_vm.forInNext(ctx, output, global, stack, hasValueProperty),
            op.iterator_close => {
                switch (try iter_vm.iteratorCloseVm(ctx, output, global, stack, &frame, &catch_target, closeIteratorFromVm, closeForAwaitIteratorFromVm, handleCatchableRuntimeError)) {
                    .done => {},
                    .continue_loop => continue,
                }
            },

            // ---- Constructor ----
            op.call_constructor => switch (try call_vm.constructor(ctx, output, global, stack, function, &frame, &catch_target, popDuplicateConstructorTarget, constructValueOrBytecodeWithNewTarget, handleCatchableRuntimeError)) {
                .done => {},
                .continue_loop => continue,
            },

            op.invalid => return error.InvalidBytecode,

            else => return error.InvalidBytecode,
        }
    }

    const value = stack.peek() orelse core.JSValue.undefinedValue();
    return control_vm.finishFunctionReturn(ctx, &frame, value);
}

// ---- Helpers ----
// ---- Shared helper aliases ----
const ensureLocalsCapacity = shared_vm.ensureLocalsCapacity;
const ensureVarRefsCapacity = shared_vm.ensureVarRefsCapacity;
const catchTargetFromMarker = shared_vm.catchTargetFromMarker;
const popCatchMarker = shared_vm.popCatchMarker;
const createForInIterator = shared_vm.createForInIterator;
const atomListContains = shared_vm.atomListContains;
const appendAtom = shared_vm.appendAtom;
const freeAtomList = shared_vm.freeAtomList;
const findForOfIteratorIndex = shared_vm.findForOfIteratorIndex;
const isIteratorLikeValue = shared_vm.isIteratorLikeValue;
const closeStackTopForOfIteratorForPendingError = shared_vm.closeStackTopForOfIteratorForPendingError;
const closeStackTopForOfIteratorForPendingErrorWithFrame = shared_vm.closeStackTopForOfIteratorForPendingErrorWithFrame;
const objectPrototypeFromGlobal = shared_vm.objectPrototypeFromGlobal;
const constructorPrototypeFromGlobal = shared_vm.constructorPrototypeFromGlobal;
const constructorPrototypeFromGlobalAtom = shared_vm.constructorPrototypeFromGlobalAtom;
const arrayPrototypeFromGlobal = shared_vm.arrayPrototypeFromGlobal;
const functionPrototypeFromGlobal = shared_vm.functionPrototypeFromGlobal;
const promisePrototypeFromGlobal = shared_vm.promisePrototypeFromGlobal;
const asyncFunctionPrototypeFromGlobal = shared_vm.asyncFunctionPrototypeFromGlobal;
const generatorPrototypeFromGlobal = shared_vm.generatorPrototypeFromGlobal;
const installGeneratorPrototypeProperties = shared_vm.installGeneratorPrototypeProperties;
const asyncIteratorPrototypeFromGlobal = shared_vm.asyncIteratorPrototypeFromGlobal;
const asyncGeneratorPrototypeFromGlobal = shared_vm.asyncGeneratorPrototypeFromGlobal;
const installAsyncGeneratorPrototypeProperties = shared_vm.installAsyncGeneratorPrototypeProperties;
const defineNativeDataMethod = shared_vm.defineNativeDataMethod;
const generatorFunctionPrototypeFromGlobal = shared_vm.generatorFunctionPrototypeFromGlobal;
const asyncGeneratorFunctionPrototypeFromGlobal = shared_vm.asyncGeneratorFunctionPrototypeFromGlobal;
const stackValueFromTop = shared_vm.stackValueFromTop;
const toPrimitiveForAddition = shared_vm.toPrimitiveForAddition;
const toPrimitiveForNumber = shared_vm.toPrimitiveForNumber;
const toOrdinaryPrimitive = shared_vm.toOrdinaryPrimitive;
const toOrdinaryPrimitiveNumber = shared_vm.toOrdinaryPrimitiveNumber;
const toStringForAnnexB = shared_vm.toStringForAnnexB;
const toPrimitiveForString = shared_vm.toPrimitiveForString;
const toOrdinaryPrimitiveString = shared_vm.toOrdinaryPrimitiveString;
const qjsStringFunctionCall = shared_vm.qjsStringFunctionCall;
const qjsNumberFunctionCall = shared_vm.qjsNumberFunctionCall;
const qjsBigIntFunctionCall = shared_vm.qjsBigIntFunctionCall;
const qjsGlobalIsNaNOrFinite = shared_vm.qjsGlobalIsNaNOrFinite;
const qjsStringConcat = shared_vm.qjsStringConcat;
const qjsStringReplace = shared_vm.qjsStringReplace;
const qjsStringReplaceFastRegExp = shared_vm.qjsStringReplaceFastRegExp;
const callStringReplaceMethod = shared_vm.callStringReplaceMethod;
const isArrayMethodReceiver = shared_vm.isArrayMethodReceiver;
const valueTruthy = shared_vm.valueTruthy;
const execGetLoc = shared_vm.execGetLoc;
const execPutLoc = shared_vm.execPutLoc;
const execSetLoc = shared_vm.execSetLoc;
const syncTopLevelGlobalLexicalLocal = shared_vm.syncTopLevelGlobalLexicalLocal;
const execGetArg = shared_vm.execGetArg;
const execPutArg = shared_vm.execPutArg;
const execSetArg = shared_vm.execSetArg;
const execGetVarRef = shared_vm.execGetVarRef;
const execGetVarRefMaybeTdz = shared_vm.execGetVarRefMaybeTdz;
const execPutVarRef = shared_vm.execPutVarRef;
const publishTopLevelFunctionVarRef = shared_vm.publishTopLevelFunctionVarRef;
const defineGlobalFunctionBindingValue = shared_vm.defineGlobalFunctionBindingValue;
const execSetVarRef = shared_vm.execSetVarRef;
const pushSlotValue = shared_vm.pushSlotValue;
const slotValueDup = shared_vm.slotValueDup;
const slotValueBorrow = shared_vm.slotValueBorrow;
const varRefSlotIsUninitialized = shared_vm.varRefSlotIsUninitialized;
const varRefSlotIsDeleted = shared_vm.varRefSlotIsDeleted;
const evalLocalSlotIsEvalVarCell = shared_vm.evalLocalSlotIsEvalVarCell;
const setSlotValue = shared_vm.setSlotValue;
const closeLocalVarRef = shared_vm.closeLocalVarRef;
const pushFunctionClosure = shared_vm.pushFunctionClosure;
const createBytecodeFunctionObject = shared_vm.createBytecodeFunctionObject;
const functionBytecodeHasDirectEval = shared_vm.functionBytecodeHasDirectEval;
const evalBytecodeHasVarDeclarations = shared_vm.evalBytecodeHasVarDeclarations;
const shouldSkipDirectEvalLocalCapture = shared_vm.shouldSkipDirectEvalLocalCapture;
const functionBytecodeUsesAtom = shared_vm.functionBytecodeUsesAtom;
const functionBytecodeHasClosureVarName = shared_vm.functionBytecodeHasClosureVarName;
const functionBytecodeUsesArgumentsSpecialObject = shared_vm.functionBytecodeUsesArgumentsSpecialObject;
const shouldSkipDirectEvalScopeCaptureName = shared_vm.shouldSkipDirectEvalScopeCaptureName;
const appendFunctionEvalLocal = shared_vm.appendFunctionEvalLocal;
const execCall = shared_vm.execCall;
const execDirectEval = shared_vm.execDirectEval;
const execApplyEval = shared_vm.execApplyEval;
const qjsArrayMethodFastCall = shared_vm.qjsArrayMethodFastCall;
const handleCatchableRuntimeError = shared_vm.handleCatchableRuntimeError;
const callValueOrBytecode = shared_vm.callValueOrBytecode;
const callValueOrBytecodeClassMode = shared_vm.callValueOrBytecodeClassMode;
const classConstructorNewTarget = shared_vm.classConstructorNewTarget;
const constructBuiltinSuperConstructor = shared_vm.constructBuiltinSuperConstructor;
const constructPrimitiveWrapperWithPrototype = shared_vm.constructPrimitiveWrapperWithPrototype;
const currentArrowFunctionObject = shared_vm.currentArrowFunctionObject;
const currentArrowLexicalSuperThis = shared_vm.currentArrowLexicalSuperThis;
const currentArrowConstructorThis = shared_vm.currentArrowConstructorThis;
const setCurrentArrowLexicalThis = shared_vm.setCurrentArrowLexicalThis;
const isCurrentSuperConstructor = shared_vm.isCurrentSuperConstructor;
const qjsUriCallId = shared_vm.qjsUriCallId;
const qjsJsonParseCall = json_vm.qjsJsonParseCall;
const qjsJsonInternalizeProperty = json_vm.qjsJsonInternalizeProperty;
const qjsJsonInternalizeChild = json_vm.qjsJsonInternalizeChild;
const qjsJsonCreateDataProperty = json_vm.qjsJsonCreateDataProperty;
const qjsJsonStringifyCall = json_vm.qjsJsonStringifyCall;
const qjsJsonStringifyGap = json_vm.qjsJsonStringifyGap;
const qjsJsonSerializeProperty = json_vm.qjsJsonSerializeProperty;
const qjsJsonAppendValue = json_vm.qjsJsonAppendValue;
const qjsJsonAppendArray = json_vm.qjsJsonAppendArray;
const qjsJsonAppendObject = json_vm.qjsJsonAppendObject;
const qjsJsonPrimitiveWrapperValue = json_vm.qjsJsonPrimitiveWrapperValue;
const qjsJsonObjectInStack = json_vm.qjsJsonObjectInStack;
const qjsJsonAppendIndent = json_vm.qjsJsonAppendIndent;
const qjsStringFromCodePoint = shared_vm.qjsStringFromCodePoint;
const qjsStringFromCodePointArray = shared_vm.qjsStringFromCodePointArray;
const qjsStringFromCodePointDenseArray = shared_vm.qjsStringFromCodePointDenseArray;
const validStringCodePoint = shared_vm.validStringCodePoint;
const appendCodePointUnits = shared_vm.appendCodePointUnits;
const qjsStringFromCharCode = shared_vm.qjsStringFromCharCode;
const toUint16CodeUnit = shared_vm.toUint16CodeUnit;
const qjsRegExpFunctionCall = shared_vm.qjsRegExpFunctionCall;
const qjsRegExpConstructCall = shared_vm.qjsRegExpConstructCall;
const qjsRegExpExecMethod = shared_vm.qjsRegExpExecMethod;
const qjsRegExpTestMethod = shared_vm.qjsRegExpTestMethod;
const qjsRegExpSymbolSearch = shared_vm.qjsRegExpSymbolSearch;
const qjsRegExpSymbolMatch = shared_vm.qjsRegExpSymbolMatch;
const qjsRegExpSymbolMatchAll = shared_vm.qjsRegExpSymbolMatchAll;
const qjsStringMatchAll = shared_vm.qjsStringMatchAll;
const qjsRegExpStringIteratorPrototype = shared_vm.qjsRegExpStringIteratorPrototype;
const qjsRegExpSymbolReplace = shared_vm.qjsRegExpSymbolReplace;
const qjsRegExpSymbolSplit = shared_vm.qjsRegExpSymbolSplit;
const qjsRegExpSpeciesConstructor = shared_vm.qjsRegExpSpeciesConstructor;
const isDefaultRegExpConstructor = shared_vm.isDefaultRegExpConstructor;
const qjsRegExpSplitFlags = shared_vm.qjsRegExpSplitFlags;
const qjsStringValueContainsByte = shared_vm.qjsStringValueContainsByte;
const qjsRegExpSymbolSplitGeneric = shared_vm.qjsRegExpSymbolSplitGeneric;
const toLengthIndex = shared_vm.toLengthIndex;
const toLengthNumber = shared_vm.toLengthNumber;
const advanceStringIndexBytes = shared_vm.advanceStringIndexBytes;
const qjsRegExpSymbolSearchGeneric = shared_vm.qjsRegExpSymbolSearchGeneric;
const qjsRegExpSymbolMatchGeneric = shared_vm.qjsRegExpSymbolMatchGeneric;
const qjsRegExpExecSimpleUnicodeLiteral = shared_vm.qjsRegExpExecSimpleUnicodeLiteral;
const qjsRegExpSymbolReplaceGeneric = shared_vm.qjsRegExpSymbolReplaceGeneric;
const replaceSingleUnitGlobalSimpleClassEscape = shared_vm.replaceSingleUnitGlobalSimpleClassEscape;
const replaceGlobalSimpleClassEscape = shared_vm.replaceGlobalSimpleClassEscape;
const appendStringValueUnits = shared_vm.appendStringValueUnits;
const simpleQuantifiedClassSourceFromValue = shared_vm.simpleQuantifiedClassSourceFromValue;
const stringValueContainsUnitByte = shared_vm.stringValueContainsUnitByte;
const stringValueUnitsEqualBytes = shared_vm.stringValueUnitsEqualBytes;
const setRegExpLastIndexZero = shared_vm.setRegExpLastIndexZero;
const getRegExpFlagsStringForReplace = shared_vm.getRegExpFlagsStringForReplace;
const captureReplaceMatch = shared_vm.captureReplaceMatch;
const freeReplaceMatches = shared_vm.freeReplaceMatches;
const callReplaceFunction = shared_vm.callReplaceFunction;
const getSubstitutionString = shared_vm.getSubstitutionString;
const appendNamedCaptureSubstitution = shared_vm.appendNamedCaptureSubstitution;
const replacementCapture = shared_vm.replacementCapture;
const stringLengthIndex = shared_vm.stringLengthIndex;
const isEmptyStringValue = shared_vm.isEmptyStringValue;
const advanceStringIndexNumber = shared_vm.advanceStringIndexNumber;
const qjsRegExpExecGeneric = shared_vm.qjsRegExpExecGeneric;
const setValuePropertyStrict = shared_vm.setValuePropertyStrict;
const qjsRegExpAccessor = shared_vm.qjsRegExpAccessor;
const throwRegExpAccessorTypeError = shared_vm.throwRegExpAccessorTypeError;
const isSameRealmRegExpPrototypeGetter = shared_vm.isSameRealmRegExpPrototypeGetter;
const objectHasRegExpInternalSlots = shared_vm.objectHasRegExpInternalSlots;
const qjsRegExpExecResult = shared_vm.qjsRegExpExecResult;
const qjsStringTrim = shared_vm.qjsStringTrim;
const qjsStringPrototypeMethod = shared_vm.qjsStringPrototypeMethod;
const qjsStringNumericArgsMethod = shared_vm.qjsStringNumericArgsMethod;
const toNumberLikeArgument = shared_vm.toNumberLikeArgument;
const qjsStringSearchPositionMethod = shared_vm.qjsStringSearchPositionMethod;
const isRegExpValue = shared_vm.isRegExpValue;
const isRegExpObservable = shared_vm.isRegExpObservable;
const isRegExpForStringSearch = shared_vm.isRegExpForStringSearch;
const qjsStringReplaceAll = shared_vm.qjsStringReplaceAll;
const qjsStringSearch = shared_vm.qjsStringSearch;
const qjsStringMatch = shared_vm.qjsStringMatch;
const callStringWellKnownMethod = shared_vm.callStringWellKnownMethod;
const qjsStringSplit = shared_vm.qjsStringSplit;
const qjsRegExpSplit = shared_vm.qjsRegExpSplit;
const qjsRegExpSplitWholeString = shared_vm.qjsRegExpSplitWholeString;
const qjsRegExpSearch = shared_vm.qjsRegExpSearch;
const qjsRegExpMatch = shared_vm.qjsRegExpMatch;
const appendRegExpSource = shared_vm.appendRegExpSource;
const appendRegExpFlags = shared_vm.appendRegExpFlags;
const appendRegExpInputUnits = shared_vm.appendRegExpInputUnits;
const singleUnicodeEscapeUnit = shared_vm.singleUnicodeEscapeUnit;
const singleUnicodeClassEscapeUnit = shared_vm.singleUnicodeClassEscapeUnit;
const findStringUnitMatch = shared_vm.findStringUnitMatch;
const isSimpleUnicodeLiteralSource = shared_vm.isSimpleUnicodeLiteralSource;
const simpleUnicodeLiteralMatch = shared_vm.simpleUnicodeLiteralMatch;
const parseSimpleUnicodeLiteralSource = shared_vm.parseSimpleUnicodeLiteralSource;
const simpleUnicodeLiteralAt = shared_vm.simpleUnicodeLiteralAt;
const isStringLineStartPosition = shared_vm.isStringLineStartPosition;
const isStringLineEndPosition = shared_vm.isStringLineEndPosition;
const isLineTerminatorUnit = shared_vm.isLineTerminatorUnit;
const unicodeSurrogatePairClassMatch = shared_vm.unicodeSurrogatePairClassMatch;
const parseSurrogatePairClassSource = shared_vm.parseSurrogatePairClassSource;
const readFixedUnicodeEscapeUnit = shared_vm.readFixedUnicodeEscapeUnit;
const surrogatePairClassAt = shared_vm.surrogatePairClassAt;
const unicodeAstralSpecialMatch = shared_vm.unicodeAstralSpecialMatch;
const parseUnicodeAstralSpecialSource = shared_vm.parseUnicodeAstralSpecialSource;
const parseUnicodeAstralClassSpecialSource = shared_vm.parseUnicodeAstralClassSpecialSource;
const readAstralAtom = shared_vm.readAstralAtom;
const readSurrogatePairEscape = shared_vm.readSurrogatePairEscape;
const unicodeAstralSpecialAt = shared_vm.unicodeAstralSpecialAt;
const repeatedSurrogatePairAt = shared_vm.repeatedSurrogatePairAt;
const exactSurrogatePairClassAt = shared_vm.exactSurrogatePairClassAt;
const astralRangeAt = shared_vm.astralRangeAt;
const negatedSurrogatePairClassAt = shared_vm.negatedSurrogatePairClassAt;
const stringCodePointAt = shared_vm.stringCodePointAt;
const codePointFromSurrogatePair = shared_vm.codePointFromSurrogatePair;
const surrogatePairFromCodePoint = shared_vm.surrogatePairFromCodePoint;
const findUnicodeFoldClassMatch = shared_vm.findUnicodeFoldClassMatch;
const unicodeSimpleFoldClassMatches = shared_vm.unicodeSimpleFoldClassMatches;
const isStringHighSurrogateAt = shared_vm.isStringHighSurrogateAt;
const singleDotAnchoredMatches = shared_vm.singleDotAnchoredMatches;
const isRegExpLineTerminator = shared_vm.isRegExpLineTerminator;
const anchoredWhitespaceMatches = shared_vm.anchoredWhitespaceMatches;
const anchoredSingleNonWhitespaceMatches = shared_vm.anchoredSingleNonWhitespaceMatches;
const isSimpleStringClassEscapeSource = shared_vm.isSimpleStringClassEscapeSource;
const findStringClassEscapeMatch = shared_vm.findStringClassEscapeMatch;
const classEscapeRunLengthLatin1 = shared_vm.classEscapeRunLengthLatin1;
const classEscapeRunLengthUtf16 = shared_vm.classEscapeRunLengthUtf16;
const classEscapeIsQuantified = shared_vm.classEscapeIsQuantified;
const classEscapeUnitMatches = shared_vm.classEscapeUnitMatches;
const classEscapeKindIndex = shared_vm.classEscapeKindIndex;
const isEcmaWhitespaceOrLineTerminator = shared_vm.isEcmaWhitespaceOrLineTerminator;
const anchoredComplementClassMatches = shared_vm.anchoredComplementClassMatches;
const isAnchoredBinaryPropertySource = shared_vm.isAnchoredBinaryPropertySource;
const anchoredBinaryPropertyMatches = shared_vm.anchoredBinaryPropertyMatches;
const anchoredCodePointPredicateMatches = shared_vm.anchoredCodePointPredicateMatches;
const isUnicodePropertyMatches = shared_vm.isUnicodePropertyMatches;
const complementClassUnitMatches = shared_vm.complementClassUnitMatches;
const isAsciiDigitUnit = shared_vm.isAsciiDigitUnit;
const isAsciiWordUnit = shared_vm.isAsciiWordUnit;
const isHighSurrogateUnit = shared_vm.isHighSurrogateUnit;
const isLowSurrogateUnit = shared_vm.isLowSurrogateUnit;
const isRegExpSyntaxByte = shared_vm.isRegExpSyntaxByte;
const hasFlag = shared_vm.hasFlag;
const regexpLastIndex = shared_vm.regexpLastIndex;
const setRegExpLastIndex = shared_vm.setRegExpLastIndex;
const defineSplitStringElement = shared_vm.defineSplitStringElement;
const createStringFromByteUnits = shared_vm.createStringFromByteUnits;
const defineSplitValueElement = shared_vm.defineSplitValueElement;
const createRegExpMatchArray = shared_vm.createRegExpMatchArray;
const createRegExpIndicesArray = shared_vm.createRegExpIndicesArray;
const createRegExpIndexPair = shared_vm.createRegExpIndexPair;
const defineRegExpIndicesGroupsProperty = shared_vm.defineRegExpIndicesGroupsProperty;
const createStartOfLineUnicodeMatchArray = shared_vm.createStartOfLineUnicodeMatchArray;
const defineRegExpGroupsProperty = shared_vm.defineRegExpGroupsProperty;
const appendDecodedRegExpGroupName = shared_vm.appendDecodedRegExpGroupName;
const readRegExpGroupNameEscape = shared_vm.readRegExpGroupNameEscape;
const appendUtf8CodePointForRegExpName = shared_vm.appendUtf8CodePointForRegExpName;
const isHighSurrogateCodePoint = shared_vm.isHighSurrogateCodePoint;
const isLowSurrogateCodePoint = shared_vm.isLowSurrogateCodePoint;
const combinedSurrogateCodePoint = shared_vm.combinedSurrogateCodePoint;
const createRegExpMatchArrayFromStringValue = shared_vm.createRegExpMatchArrayFromStringValue;
const createRegExpMatchArrayFromStringSliceValue = shared_vm.createRegExpMatchArrayFromStringSliceValue;
const stringSliceValue = shared_vm.stringSliceValue;
const toUint32Number = shared_vm.toUint32Number;
const uint32NumberValue = shared_vm.uint32NumberValue;
const getStringPrototypeMethodId = shared_vm.getStringPrototypeMethodId;
const qjsPrimitivePrototypeMethod = shared_vm.qjsPrimitivePrototypeMethod;
const getNumberPrototypeMethodId = shared_vm.getNumberPrototypeMethodId;
const qjsNumberPrototypeMethod = shared_vm.qjsNumberPrototypeMethod;
const coerceOptionalNumberMethodArgument = shared_vm.coerceOptionalNumberMethodArgument;
const primitivePrototypeThisValue = shared_vm.primitivePrototypeThisValue;
const primitiveWrapperStoredValue = shared_vm.primitiveWrapperStoredValue;
const standardStringMethodId = shared_vm.standardStringMethodId;
const genericTrimStringMethodId = shared_vm.genericTrimStringMethodId;
const isStringMethodReceiver = shared_vm.isStringMethodReceiver;
const annexBStringMethodId = shared_vm.annexBStringMethodId;
const qjsDateSetYear = date_vm.qjsDateSetYear;
const qjsDateSetTime = date_vm.qjsDateSetTime;
const qjsDateStaticId = date_vm.qjsDateStaticId;
const toNumberForDateMethod = shared_vm.toNumberForDateMethod;
const constructValueOrBytecode = shared_vm.constructValueOrBytecode;
const constructValueOrBytecodeWithNewTarget = shared_vm.constructValueOrBytecodeWithNewTarget;
const initializeClassInstanceElements = shared_vm.initializeClassInstanceElements;
const initializeCurrentConstructorClassInstanceElements = shared_vm.initializeCurrentConstructorClassInstanceElements;
const initializeClassPrivateMethods = shared_vm.initializeClassPrivateMethods;
const initializeClassInstanceFields = shared_vm.initializeClassInstanceFields;
const defineClassFieldDataProperty = shared_vm.defineClassFieldDataProperty;
const qjsTypedArrayConstructFromIterable = shared_vm.qjsTypedArrayConstructFromIterable;
const qjsTypedArrayConstructorName = shared_vm.qjsTypedArrayConstructorName;
const qjsDataViewAccessor = shared_vm.qjsDataViewAccessor;
const dataViewGetId = shared_vm.dataViewGetId;
const dataViewSetId = shared_vm.dataViewSetId;
const bigIntStaticUnsigned = shared_vm.bigIntStaticUnsigned;
const qjsArrayBufferAccessor = shared_vm.qjsArrayBufferAccessor;
const qjsSharedArrayBufferAccessor = shared_vm.qjsSharedArrayBufferAccessor;
const qjsArrayBufferIsView = shared_vm.qjsArrayBufferIsView;
const qjsErrorIsError = shared_vm.qjsErrorIsError;
const qjsWeakRefDeref = shared_vm.qjsWeakRefDeref;
const qjsFinalizationRegistryRegister = shared_vm.qjsFinalizationRegistryRegister;
const qjsFinalizationRegistryUnregister = shared_vm.qjsFinalizationRegistryUnregister;
const qjsCanBeHeldWeakly = shared_vm.qjsCanBeHeldWeakly;
const qjsTypedArrayAccessor = shared_vm.qjsTypedArrayAccessor;
const typedArrayNameFromKind = shared_vm.typedArrayNameFromKind;
const qjsTypedArraySetCall = shared_vm.qjsTypedArraySetCall;
const qjsPromiseConstruct = shared_vm.qjsPromiseConstruct;
const qjsPromiseConstructWithPrototype = shared_vm.qjsPromiseConstructWithPrototype;
const createPromiseResolvingFunction = shared_vm.createPromiseResolvingFunction;
const qjsPromiseResolvingFunctionCall = shared_vm.qjsPromiseResolvingFunctionCall;
const constructCollectionFromVm = shared_vm.constructCollectionFromVm;
const constructCollectionWithPrototypeFromVm = shared_vm.constructCollectionWithPrototypeFromVm;
const constructorPrototypeObject = shared_vm.constructorPrototypeObject;
const addCollectionEntriesFromArray = shared_vm.addCollectionEntriesFromArray;
const addCollectionEntriesFromIterator = shared_vm.addCollectionEntriesFromIterator;
const callCollectionAdderFromVm = shared_vm.callCollectionAdderFromVm;
const closeIteratorFromVm = shared_vm.closeIteratorFromVm;
const closeForAwaitIteratorFromVm = shared_vm.closeForAwaitIteratorFromVm;
const collectionConstructorId = shared_vm.collectionConstructorId;
const isBuiltinConstructorName = shared_vm.isBuiltinConstructorName;
const isErrorConstructorName = shared_vm.isErrorConstructorName;
const createConstructorInstance = shared_vm.createConstructorInstance;
const constructFunctionFromSource = shared_vm.constructFunctionFromSource;
const constructAsyncFunctionFromSource = shared_vm.constructAsyncFunctionFromSource;
const constructGeneratorFunctionFromSource = shared_vm.constructGeneratorFunctionFromSource;
const constructAsyncGeneratorFunctionFromSource = shared_vm.constructAsyncGeneratorFunctionFromSource;
const constructDynamicFunctionFromSource = shared_vm.constructDynamicFunctionFromSource;
const dynamicFunctionNewTargetPrototype = shared_vm.dynamicFunctionNewTargetPrototype;
const dynamicFunctionDefaultPrototype = shared_vm.dynamicFunctionDefaultPrototype;
const dynamicFunctionRealmGlobal = shared_vm.dynamicFunctionRealmGlobal;
const objectRealmGlobal = shared_vm.objectRealmGlobal;
const nativeTypedArraySubclassBase = shared_vm.nativeTypedArraySubclassBase;
const copyRealmPrototypeKeys = shared_vm.copyRealmPrototypeKeys;
const clearFunctionEvalCaptures = shared_vm.clearFunctionEvalCaptures;
const qjsAssertThrows = shared_vm.qjsAssertThrows;
const thrownValueMatchesConstructor = shared_vm.thrownValueMatchesConstructor;
const callAssertThrowsCallback = shared_vm.callAssertThrowsCallback;
const collectCallerEvalRefs = shared_vm.collectCallerEvalRefs;
const qjsArrayForEachCall = shared_vm.qjsArrayForEachCall;
const qjsArrayAtCall = shared_vm.qjsArrayAtCall;
const qjsArrayIterationCall = shared_vm.qjsArrayIterationCall;
const qjsTypedArrayMapFilter = shared_vm.qjsTypedArrayMapFilter;
const qjsArrayReduceCall = shared_vm.qjsArrayReduceCall;
const qjsArrayReduceRightSparseLarge = shared_vm.qjsArrayReduceRightSparseLarge;
const propertyIndexFromLengthKey = shared_vm.propertyIndexFromLengthKey;
const lengthIndexValue = shared_vm.lengthIndexValue;
const qjsArraySearchCall = shared_vm.qjsArraySearchCall;
const qjsArrayLastIndexSparseLarge = shared_vm.qjsArrayLastIndexSparseLarge;
const arrayFirstIndexStart = shared_vm.arrayFirstIndexStart;
const arrayLastIndexStart = shared_vm.arrayLastIndexStart;
const valuesStrictEqual = shared_vm.valuesStrictEqual;
const qjsArraySliceCall = shared_vm.qjsArraySliceCall;
const qjsTypedArraySliceSubarrayCall = shared_vm.qjsTypedArraySliceSubarrayCall;
const typedArrayConstructorForObject = shared_vm.typedArrayConstructorForObject;
const typedArraySpeciesConstructorForObject = shared_vm.typedArraySpeciesConstructorForObject;
const qjsArraySpliceCall = shared_vm.qjsArraySpliceCall;
const qjsArrayCopyWithinCall = shared_vm.qjsArrayCopyWithinCall;
const qjsArrayFillCall = shared_vm.qjsArrayFillCall;
const qjsArrayPushCall = shared_vm.qjsArrayPushCall;
const qjsArrayPopCall = shared_vm.qjsArrayPopCall;
const qjsArrayShiftCall = shared_vm.qjsArrayShiftCall;
const qjsArrayUnshiftCall = shared_vm.qjsArrayUnshiftCall;
const qjsArrayReverseCall = shared_vm.qjsArrayReverseCall;
const qjsArrayUnshiftSparseLarge = shared_vm.qjsArrayUnshiftSparseLarge;
const unshiftMoveIndex = shared_vm.unshiftMoveIndex;
const ensureSettableForArrayBuiltin = shared_vm.ensureSettableForArrayBuiltin;
const ensureLengthWritableForArrayBuiltin = shared_vm.ensureLengthWritableForArrayBuiltin;
const verifyArrayLikeLengthSet = shared_vm.verifyArrayLikeLengthSet;
const propertyAtomFromLengthIndex = shared_vm.propertyAtomFromLengthIndex;
const arrayRelativeIndex = shared_vm.arrayRelativeIndex;
const toIntegerOrInfinityForArrayMethod = shared_vm.toIntegerOrInfinityForArrayMethod;
const arraySpeciesCreate = shared_vm.arraySpeciesCreate;
const arraySpeciesOriginalIsArray = shared_vm.arraySpeciesOriginalIsArray;
const arraySpeciesConstructorIsForeignArray = shared_vm.arraySpeciesConstructorIsForeignArray;
const qjsArrayConcatCall = shared_vm.qjsArrayConcatCall;
const concatAppendValue = shared_vm.concatAppendValue;
const concatSpreadLengthValue = shared_vm.concatSpreadLengthValue;
const isConcatSpreadable = shared_vm.isConcatSpreadable;
const qjsArrayFromCall = shared_vm.qjsArrayFromCall;
const qjsArrayFromArrayLike = shared_vm.qjsArrayFromArrayLike;
const qjsArrayFromIteratorLike = shared_vm.qjsArrayFromIteratorLike;
const qjsIteratorClose = shared_vm.qjsIteratorClose;
const qjsArrayOfCall = shared_vm.qjsArrayOfCall;
const createDataPropertyOrThrow = shared_vm.createDataPropertyOrThrow;
const qjsCreateArrayDataOrTypedArrayElement = shared_vm.qjsCreateArrayDataOrTypedArrayElement;
const typedArrayConstructorObject = shared_vm.typedArrayConstructorObject;
const proxyCreateDataPropertyOrThrow = shared_vm.proxyCreateDataPropertyOrThrow;
const isConstructorForArrayOf = shared_vm.isConstructorForArrayOf;
const qjsObjectIsPrototypeOf = shared_vm.qjsObjectIsPrototypeOf;
const qjsObjectGetPrototypeOfStep = shared_vm.qjsObjectGetPrototypeOfStep;
const qjsObjectGetPrototypeOfValue = shared_vm.qjsObjectGetPrototypeOfValue;
const qjsArrayMapCall = shared_vm.qjsArrayMapCall;
pub const qjsArraySortCall = shared_vm.qjsArraySortCall;
const arraySortCompare = shared_vm.arraySortCompare;
const stableArraySortEntries = shared_vm.stableArraySortEntries;
pub const qjsArrayByCopyCall = shared_vm.qjsArrayByCopyCall;
const qjsArrayFlatCall = shared_vm.qjsArrayFlatCall;
const flattenIntoArray = shared_vm.flattenIntoArray;
const createArrayByCopyOutput = shared_vm.createArrayByCopyOutput;
const defineArrayByCopyElement = shared_vm.defineArrayByCopyElement;
const toIntegerOrInfinityForArrayByCopy = shared_vm.toIntegerOrInfinityForArrayByCopy;
const arrayByCopySortCompare = shared_vm.arrayByCopySortCompare;
const qjsDestructuringGet = shared_vm.qjsDestructuringGet;
const qjsDestructuringElide = shared_vm.qjsDestructuringElide;
const qjsDestructuringRest = shared_vm.qjsDestructuringRest;
const qjsDestructuringObjectRest = shared_vm.qjsDestructuringObjectRest;
const objectRestOwnKeys = shared_vm.objectRestOwnKeys;
const appendOwnedAtom = shared_vm.appendOwnedAtom;
const typedArrayOwnKeys = shared_vm.typedArrayOwnKeys;
const isTypedArrayInternalOwnKey = shared_vm.isTypedArrayInternalOwnKey;
const validateProxyOwnKeysResult = shared_vm.validateProxyOwnKeysResult;
const objectRestOwnPropertyDescriptor = shared_vm.objectRestOwnPropertyDescriptor;
const proxyAwareOwnPropertyDescriptor = shared_vm.proxyAwareOwnPropertyDescriptor;
const proxyAwareIsExtensible = shared_vm.proxyAwareIsExtensible;
const completeProxyDescriptor = shared_vm.completeProxyDescriptor;
const isCompatibleProxyDescriptor = shared_vm.isCompatibleProxyDescriptor;
const objectRestKeyExcluded = shared_vm.objectRestKeyExcluded;
const arrayUsesDefaultIterator = shared_vm.arrayUsesDefaultIterator;
const qjsDestructuringClose = shared_vm.qjsDestructuringClose;
const qjsDestructuringRequireIterator = shared_vm.qjsDestructuringRequireIterator;
const ensureDestructuringIterator = shared_vm.ensureDestructuringIterator;
const getIteratorMethod = shared_vm.getIteratorMethod;
const iteratorForValue = shared_vm.iteratorForValue;
const cacheIteratorNextMethod = shared_vm.cacheIteratorNextMethod;
const destructuringIteratorStep = shared_vm.destructuringIteratorStep;
const appendIteratorValues = shared_vm.appendIteratorValues;
const iteratorStepValue = shared_vm.iteratorStepValue;
const iteratorStepResult = shared_vm.iteratorStepResult;
const clearDestructuringIteratorState = shared_vm.clearDestructuringIteratorState;
const isCallableValue = shared_vm.isCallableValue;
const qjsAtomicsIsLockFree = shared_vm.qjsAtomicsIsLockFree;
const qjsAtomicsPause = shared_vm.qjsAtomicsPause;
const qjsAtomicsReadModifyWrite = shared_vm.qjsAtomicsReadModifyWrite;
const qjsAtomicsStore = shared_vm.qjsAtomicsStore;
const qjsAtomicsNotify = shared_vm.qjsAtomicsNotify;
const qjsAtomicsWait = shared_vm.qjsAtomicsWait;
const atomicsTypedArray = shared_vm.atomicsTypedArray;
const atomicsTypedArrayIsBigInt = shared_vm.atomicsTypedArrayIsBigInt;
const atomicsValidateIndex = shared_vm.atomicsValidateIndex;
const atomicsBufferObject = shared_vm.atomicsBufferObject;
const atomicsElementBytes = shared_vm.atomicsElementBytes;
const atomicsReadBits = shared_vm.atomicsReadBits;
const atomicsWriteBits = shared_vm.atomicsWriteBits;
const atomicsMaskBits = shared_vm.atomicsMaskBits;
const atomicsValueFromBits = shared_vm.atomicsValueFromBits;
const toIndexForAtomics = shared_vm.toIndexForAtomics;
const toNumberForAtomics = shared_vm.toNumberForAtomics;
const toInt32ForAtomics = shared_vm.toInt32ForAtomics;
const toInt32BitsForAtomics = shared_vm.toInt32BitsForAtomics;
const toUint32ForAtomics = shared_vm.toUint32ForAtomics;
const toIntegerValueForAtomics = shared_vm.toIntegerValueForAtomics;
const uint32FromIntegerValueForAtomics = shared_vm.uint32FromIntegerValueForAtomics;
const toBigIntValueForAtomics = shared_vm.toBigIntValueForAtomics;
const toBigIntBitsForAtomics = shared_vm.toBigIntBitsForAtomics;
const atomicsNumberResult = shared_vm.atomicsNumberResult;
const bigintBitsForAtomics = shared_vm.bigintBitsForAtomics;
const qjsUint8ArrayCodecCall = shared_vm.qjsUint8ArrayCodecCall;
const expectUint8ArrayObject = shared_vm.expectUint8ArrayObject;
const uint8ArrayStringBytes = shared_vm.uint8ArrayStringBytes;
const uint8ArrayBase64Alphabet = shared_vm.uint8ArrayBase64Alphabet;
const uint8ArrayOmitPadding = shared_vm.uint8ArrayOmitPadding;
const createUint8ArrayFromBytes = shared_vm.createUint8ArrayFromBytes;
const uint8ArrayConstructorPrototypeObject = shared_vm.uint8ArrayConstructorPrototypeObject;
const uint8ArrayViewBytes = shared_vm.uint8ArrayViewBytes;
const writeUint8ArrayPrefix = shared_vm.writeUint8ArrayPrefix;
const uint8ArrayCodecResult = shared_vm.uint8ArrayCodecResult;
const decodeHexBytes = shared_vm.decodeHexBytes;
const encodeHexBytes = shared_vm.encodeHexBytes;
const hexNibble = shared_vm.hexNibble;
const decodeBase64Bytes = shared_vm.decodeBase64Bytes;
const encodeBase64Bytes = shared_vm.encodeBase64Bytes;
const base64Value = shared_vm.base64Value;
const isAsciiWhitespace = shared_vm.isAsciiWhitespace;
const isTypedArrayPrototypeMethod = shared_vm.isTypedArrayPrototypeMethod;
const isIteratorIdentityFunction = shared_vm.isIteratorIdentityFunction;
const globalLexicalEnv = shared_vm.globalLexicalEnv;
const existingGlobalLexicalEnv = shared_vm.existingGlobalLexicalEnv;
const globalLexicalHas = shared_vm.globalLexicalHas;
const globalLexicalValue = shared_vm.globalLexicalValue;
const defineGlobalLexicalValue = shared_vm.defineGlobalLexicalValue;
const setGlobalLexicalValue = shared_vm.setGlobalLexicalValue;
const initializeGlobalLexicalValue = shared_vm.initializeGlobalLexicalValue;
const withObjectBindingValue = shared_vm.withObjectBindingValue;
const directEvalWithObject = shared_vm.directEvalWithObject;
const directEval = shared_vm.directEval;
const normalizeEvalRuntimeError = shared_vm.normalizeEvalRuntimeError;
const validateGlobalEvalFunctionDeclarations = shared_vm.validateGlobalEvalFunctionDeclarations;
const looksLikeStatementFunctionKeyword = shared_vm.looksLikeStatementFunctionKeyword;
const canDeclareGlobalFunction = shared_vm.canDeclareGlobalFunction;
const isIdentifierStartByte = shared_vm.isIdentifierStartByte;
const isIdentifierPartByte = shared_vm.isIdentifierPartByte;
const directEvalThisValue = shared_vm.directEvalThisValue;
const classStaticThisAtom = shared_vm.classStaticThisAtom;
const classStaticThisValue = shared_vm.classStaticThisValue;
const directEvalPrivateBoundNames = shared_vm.directEvalPrivateBoundNames;
const appendPrivateBoundNamesFromValue = shared_vm.appendPrivateBoundNamesFromValue;
const appendPrivateBoundNamesFromObject = shared_vm.appendPrivateBoundNamesFromObject;
const appendPrivateBoundName = shared_vm.appendPrivateBoundName;
const privateAtomNamesMatch = shared_vm.privateAtomNamesMatch;
const evalFunctionDeclarationNames = shared_vm.evalFunctionDeclarationNames;
const braceDepthBefore = shared_vm.braceDepthBefore;
const evalFunctionDeclarationNameAt = shared_vm.evalFunctionDeclarationNameAt;
const simpleEvalFunctionDeclarationNames = shared_vm.simpleEvalFunctionDeclarationNames;
const skipAsciiWhitespace = shared_vm.skipAsciiWhitespace;
const startsWithKeyword = shared_vm.startsWithKeyword;
const appendIdentifierEscape = shared_vm.appendIdentifierEscape;
const createEvalVarRefCells = shared_vm.createEvalVarRefCells;
const createDirectEvalVarRefCells = shared_vm.createDirectEvalVarRefCells;
const createDirectEvalVisibleLocalBindings = shared_vm.createDirectEvalVisibleLocalBindings;
const directEvalVisibleBindingExists = shared_vm.directEvalVisibleBindingExists;
const directEvalVisibleLocalNameCount = shared_vm.directEvalVisibleLocalNameCount;
const directEvalShouldExposeImplicitArguments = shared_vm.directEvalShouldExposeImplicitArguments;
const frameCurrentFunctionIsArrow = shared_vm.frameCurrentFunctionIsArrow;
const directEvalCallerAllowsNewTarget = shared_vm.directEvalCallerAllowsNewTarget;
const directEvalCallerAllowsSuperProperty = shared_vm.directEvalCallerAllowsSuperProperty;
const functionHasArgOrLocal = shared_vm.functionHasArgOrLocal;
const callerArgIndex = shared_vm.callerArgIndex;
const callerLocalIndex = shared_vm.callerLocalIndex;
const directEvalVarDeclarationNames = shared_vm.directEvalVarDeclarationNames;
const directEvalVarNameIsNonLeadingFunctionCallerArg = shared_vm.directEvalVarNameIsNonLeadingFunctionCallerArg;
const directEvalSourceHasLexicalDeclarationName = shared_vm.directEvalSourceHasLexicalDeclarationName;
const minOptionalIndex = shared_vm.minOptionalIndex;
const looksLikeIdentifierKeyword = shared_vm.looksLikeIdentifierKeyword;
const functionHasNonLexicalLocal = shared_vm.functionHasNonLexicalLocal;
const freeValueSlice = shared_vm.freeValueSlice;
const publishDirectEvalVarRefs = shared_vm.publishDirectEvalVarRefs;
const replaceFrameVarRefBinding = shared_vm.replaceFrameVarRefBinding;
const indirectEval = shared_vm.indirectEval;
const appendSourceStringUtf8 = shared_vm.appendSourceStringUtf8;
const appendCodepointUtf8 = shared_vm.appendCodepointUtf8;
const simpleEvalRegExpLiteral = shared_vm.simpleEvalRegExpLiteral;
const containsUtf8LineSeparator = shared_vm.containsUtf8LineSeparator;
const evalSimpleCallerExpression = shared_vm.evalSimpleCallerExpression;
const simpleEvalStringLiteral = shared_vm.simpleEvalStringLiteral;
const isSimpleIdentifierName = shared_vm.isSimpleIdentifierName;
const isSimpleIntegerLiteral = shared_vm.isSimpleIntegerLiteral;
const callerFunctionNameEql = shared_vm.callerFunctionNameEql;
const simpleVarDeclarationName = shared_vm.simpleVarDeclarationName;
const callerFunctionHasArg = shared_vm.callerFunctionHasArg;
const callerFunctionHasLexicalLocal = shared_vm.callerFunctionHasLexicalLocal;
const callerFunctionHasBinding = shared_vm.callerFunctionHasBinding;
const functionHasFrameBinding = shared_vm.functionHasFrameBinding;
const atomNamesEqual = shared_vm.atomNamesEqual;
const putDenseArrayElementFast = shared_vm.putDenseArrayElementFast;
const argsFromArray = shared_vm.argsFromArray;
const argsFromArrayLike = shared_vm.argsFromArrayLike;
const freeArgs = shared_vm.freeArgs;
const callFunctionBytecode = shared_vm.callFunctionBytecode;
const callFunctionBytecodeConstruct = shared_vm.callFunctionBytecodeConstruct;
const callFunctionBytecodeMode = shared_vm.callFunctionBytecodeMode;
const callFunctionBytecodeModeState = shared_vm.callFunctionBytecodeModeState;
const createGeneratorObject = shared_vm.createGeneratorObject;
const generatorObjectPrototype = shared_vm.generatorObjectPrototype;
const runGeneratorParameterInit = shared_vm.runGeneratorParameterInit;
const qjsGeneratorNext = shared_vm.qjsGeneratorNext;
const qjsGeneratorReturn = shared_vm.qjsGeneratorReturn;
const qjsGeneratorYieldStarReturn = shared_vm.qjsGeneratorYieldStarReturn;
const qjsGeneratorThrow = shared_vm.qjsGeneratorThrow;
const findGeneratorReturnFinallyTarget = shared_vm.findGeneratorReturnFinallyTarget;
const findEnclosingCatchTarget = shared_vm.findEnclosingCatchTarget;
const findThrowFrom = shared_vm.findThrowFrom;
const forwardGotoTarget = shared_vm.forwardGotoTarget;
const closeGeneratorDestructuringIterators = shared_vm.closeGeneratorDestructuringIterators;
const closeDestructuringIteratorsInValues = shared_vm.closeDestructuringIteratorsInValues;
const closeFrameDestructuringIteratorsForAbruptCompletion = shared_vm.closeFrameDestructuringIteratorsForAbruptCompletion;
const closeForAwaitIteratorForPendingError = shared_vm.closeForAwaitIteratorForPendingError;
const generatorYieldStarSuspended = shared_vm.generatorYieldStarSuspended;
const setGeneratorYieldStarSuspended = shared_vm.setGeneratorYieldStarSuspended;
const generatorResumeCompletionType = shared_vm.generatorResumeCompletionType;
const setGeneratorResumeCompletionType = shared_vm.setGeneratorResumeCompletionType;
const qjsGeneratorSlice = shared_vm.qjsGeneratorSlice;
const qjsArrayIteratorMethod = shared_vm.qjsArrayIteratorMethod;
const qjsIteratorPrototypeAccessor = shared_vm.qjsIteratorPrototypeAccessor;
const qjsIteratorPrototypeAccessorSet = shared_vm.qjsIteratorPrototypeAccessorSet;
const qjsIteratorStaticCall = shared_vm.qjsIteratorStaticCall;
const qjsIteratorPrototypeMethodCall = shared_vm.qjsIteratorPrototypeMethodCall;
const qjsIteratorFromCall = shared_vm.qjsIteratorFromCall;
const qjsIteratorConcatCall = shared_vm.qjsIteratorConcatCall;
const iteratorFlattenableForIteratorFrom = shared_vm.iteratorFlattenableForIteratorFrom;
const isDirectIteratorClass = shared_vm.isDirectIteratorClass;
const iteratorIsOnIteratorPrototypeChain = shared_vm.iteratorIsOnIteratorPrototypeChain;
const wrapIteratorFromIterator = shared_vm.wrapIteratorFromIterator;
const wrapForValidIteratorPrototype = shared_vm.wrapForValidIteratorPrototype;
const tagIteratorWrapPrototypeMethod = shared_vm.tagIteratorWrapPrototypeMethod;
const qjsIteratorWrapNext = shared_vm.qjsIteratorWrapNext;
const qjsIteratorWrapReturn = shared_vm.qjsIteratorWrapReturn;
const qjsIteratorHelperNext = shared_vm.qjsIteratorHelperNext;
const qjsIteratorHelperReturn = shared_vm.qjsIteratorHelperReturn;
const iteratorPrototypeFromGlobal = shared_vm.iteratorPrototypeFromGlobal;
const qjsIteratorPrototype = shared_vm.qjsIteratorPrototype;
const qjsDefineToStringTag = shared_vm.qjsDefineToStringTag;
const qjsRegExpStringIteratorNext = shared_vm.qjsRegExpStringIteratorNext;
const qjsArrayIteratorNext = shared_vm.qjsArrayIteratorNext;
const qjsArrayIteratorValue = shared_vm.qjsArrayIteratorValue;
const qjsPromiseThen = shared_vm.qjsPromiseThen;
const settlePendingPromiseReaction = shared_vm.settlePendingPromiseReaction;
const awaitPendingPromise = shared_vm.awaitPendingPromise;
pub const drainPendingPromiseJobs = shared_vm.drainPendingPromiseJobs;
pub const cleanupAtomicsWaitersForContext = shared_vm.cleanupAtomicsWaitersForContext;
pub const cleanupWorkersForRuntime = shared_vm.cleanupWorkersForRuntime;
const awaitThenableValue = shared_vm.awaitThenableValue;
const rejectedPromiseForRuntimeError = shared_vm.rejectedPromiseForRuntimeError;
const createIteratorResult = shared_vm.createIteratorResult;
const createArgumentsObject = shared_vm.createArgumentsObject;
const throwTypeErrorIntrinsicForGlobal = shared_vm.throwTypeErrorIntrinsicForGlobal;
const installFunctionPrototypeThrowTypeErrorAccessors = shared_vm.installFunctionPrototypeThrowTypeErrorAccessors;
const qjsThrowTypeErrorIntrinsic = shared_vm.qjsThrowTypeErrorIntrinsic;
const isThrowTypeErrorIntrinsicObject = shared_vm.isThrowTypeErrorIntrinsicObject;
const currentFrameFunctionIsStrict = shared_vm.currentFrameFunctionIsStrict;
const frameArgumentsObject = shared_vm.frameArgumentsObject;
const frameArgumentsObjectForSpecialObject = shared_vm.frameArgumentsObjectForSpecialObject;
const arrayPrototypeValuesFromGlobal = shared_vm.arrayPrototypeValuesFromGlobal;
const functionBytecodeFromValue = shared_vm.functionBytecodeFromValue;
const functionObjectFromValue = shared_vm.functionObjectFromValue;
const objectFromValue = shared_vm.objectFromValue;
const isFunctionLikeClass = shared_vm.isFunctionLikeClass;
const callableObjectFromValue = shared_vm.callableObjectFromValue;
const proxyTargetIsCallable = shared_vm.proxyTargetIsCallable;
const proxyTargetIsConstructor = shared_vm.proxyTargetIsConstructor;
const isConstructorLike = shared_vm.isConstructorLike;
const createArrayFromArgs = shared_vm.createArrayFromArgs;
const callProxyApply = shared_vm.callProxyApply;
const constructProxy = shared_vm.constructProxy;
const callBoundFunction = shared_vm.callBoundFunction;
const boundFunctionArgs = shared_vm.boundFunctionArgs;
const toPropertyKeyValue = shared_vm.toPropertyKeyValue;
const toPropertyKeyAtom = shared_vm.toPropertyKeyAtom;
const callObjectToPrimitiveMethod = shared_vm.callObjectToPrimitiveMethod;
const getMethodPropertyForOrdinaryToPrimitive = shared_vm.getMethodPropertyForOrdinaryToPrimitive;
pub const getValueProperty = shared_vm.getValueProperty;
pub const qjsErrorStackGetter = shared_vm.qjsErrorStackGetter;
const getPrivateValueProperty = shared_vm.getPrivateValueProperty;
const setPrivateValueProperty = shared_vm.setPrivateValueProperty;
const throwPrivateBrandTypeError = shared_vm.throwPrivateBrandTypeError;
const throwTypeErrorMessage = shared_vm.throwTypeErrorMessage;
const throwNullishComputedPropertyTypeError = shared_vm.throwNullishComputedPropertyTypeError;
const getPrimitiveProperty = shared_vm.getPrimitiveProperty;
const getProxyProperty = shared_vm.getProxyProperty;
const primitiveObjectForAccess = shared_vm.primitiveObjectForAccess;
const defineStringWrapperIndexProperty = shared_vm.defineStringWrapperIndexProperty;
const getStringIndexValue = shared_vm.getStringIndexValue;
const setValueProperty = shared_vm.setValueProperty;
const proxySetValueProperty = shared_vm.proxySetValueProperty;
const arrayLengthAssignmentValue = shared_vm.arrayLengthAssignmentValue;
const qjsReflectSetCall = shared_vm.qjsReflectSetCall;
const proxyDefineValueForReflectSet = shared_vm.proxyDefineValueForReflectSet;
const qjsArrayToStringCall = shared_vm.qjsArrayToStringCall;
const qjsArrayJoinCall = shared_vm.qjsArrayJoinCall;
const qjsArrayToLocaleStringCall = shared_vm.qjsArrayToLocaleStringCall;
const qjsObjectToLocaleStringCall = shared_vm.qjsObjectToLocaleStringCall;
const qjsObjectToStringCall = shared_vm.qjsObjectToStringCall;
const qjsObjectToStringIntrinsic = shared_vm.qjsObjectToStringIntrinsic;
const qjsObjectTagString = shared_vm.qjsObjectTagString;
const defaultObjectToStringTag = shared_vm.defaultObjectToStringTag;
const objectIsArrayForToString = shared_vm.objectIsArrayForToString;
const proxyTargetIsCallableObject = shared_vm.proxyTargetIsCallableObject;
const bytecodeFunctionObjectTag = shared_vm.bytecodeFunctionObjectTag;
const proxyDefineOwnProperty = shared_vm.proxyDefineOwnProperty;
const qjsDefinePropertiesCall = shared_vm.qjsDefinePropertiesCall;
const qjsObjectCreateCall = shared_vm.qjsObjectCreateCall;
const qjsObjectAssignCall = shared_vm.qjsObjectAssignCall;
const qjsObjectAssignKeys = shared_vm.qjsObjectAssignKeys;
const qjsObjectEnumerableOwnPropertiesCall = shared_vm.qjsObjectEnumerableOwnPropertiesCall;
const qjsObjectEntryArrayValue = shared_vm.qjsObjectEntryArrayValue;
const qjsObjectHasOwnCall = shared_vm.qjsObjectHasOwnCall;
const qjsObjectPrototypeOwnPropertyCall = shared_vm.qjsObjectPrototypeOwnPropertyCall;
const qjsObjectPrototypeDefineAccessorCall = shared_vm.qjsObjectPrototypeDefineAccessorCall;
const qjsObjectPrototypeLookupAccessorCall = shared_vm.qjsObjectPrototypeLookupAccessorCall;
const qjsObjectProtoGetterCall = shared_vm.qjsObjectProtoGetterCall;
const qjsObjectProtoSetterCall = shared_vm.qjsObjectProtoSetterCall;
const qjsObjectFromEntriesCall = shared_vm.qjsObjectFromEntriesCall;
const qjsObjectGroupByCall = shared_vm.qjsObjectGroupByCall;
const qjsObjectSetIntegrityCall = shared_vm.qjsObjectSetIntegrityCall;
const qjsObjectTestIntegrityCall = shared_vm.qjsObjectTestIntegrityCall;
const objectIsExtensibleForIntegrity = shared_vm.objectIsExtensibleForIntegrity;
const appendObjectGroupByValue = shared_vm.appendObjectGroupByValue;
const qjsObjectPreventExtensionsCall = shared_vm.qjsObjectPreventExtensionsCall;
const qjsObjectIsExtensibleCall = shared_vm.qjsObjectIsExtensibleCall;
const qjsReflectIsExtensibleCall = shared_vm.qjsReflectIsExtensibleCall;
const qjsReflectPreventExtensionsCall = shared_vm.qjsReflectPreventExtensionsCall;
const qjsObjectSetPrototypeOfCall = shared_vm.qjsObjectSetPrototypeOfCall;
const qjsReflectSetPrototypeOfCall = shared_vm.qjsReflectSetPrototypeOfCall;
const qjsReflectConstructCall = shared_vm.qjsReflectConstructCall;
const reflectConstructPrototypeVm = shared_vm.reflectConstructPrototypeVm;
const objectHasImmutablePrototype = shared_vm.objectHasImmutablePrototype;
const closeIteratorForFromEntriesAbrupt = shared_vm.closeIteratorForFromEntriesAbrupt;
const qjsDefinePropertiesOnTarget = shared_vm.qjsDefinePropertiesOnTarget;
const qjsGetOwnPropertyDescriptorCall = shared_vm.qjsGetOwnPropertyDescriptorCall;
const qjsObjectGetPrototypeOfCall = shared_vm.qjsObjectGetPrototypeOfCall;
const qjsObjectPrototypeMethodFunctionPrototype = shared_vm.qjsObjectPrototypeMethodFunctionPrototype;
const qjsGetOwnPropertyDescriptorsCall = shared_vm.qjsGetOwnPropertyDescriptorsCall;
const qjsObjectOwnPropertyKeysCall = shared_vm.qjsObjectOwnPropertyKeysCall;
const qjsReflectDeletePropertyCall = shared_vm.qjsReflectDeletePropertyCall;
const qjsReflectGetCall = shared_vm.qjsReflectGetCall;
const qjsReflectOwnKeysCall = shared_vm.qjsReflectOwnKeysCall;
const descriptorObjectFromDescriptor = shared_vm.descriptorObjectFromDescriptor;
const qjsDescriptorFromObject = shared_vm.qjsDescriptorFromObject;
const qjsOptionalBoolDescriptorProperty = shared_vm.qjsOptionalBoolDescriptorProperty;
const arrayLengthDefineValue = shared_vm.arrayLengthDefineValue;
const getAccessorDescriptorValue = shared_vm.getAccessorDescriptorValue;
const getSuperPropertyValue = shared_vm.getSuperPropertyValue;
const setSuperPropertyValue = shared_vm.setSuperPropertyValue;
const callAccessorSetter = shared_vm.callAccessorSetter;
const findPropertyDescriptor = shared_vm.findPropertyDescriptor;
const popDuplicateConstructorTarget = shared_vm.popDuplicateConstructorTarget;
const sameObjectIdentity = shared_vm.sameObjectIdentity;
const clearPrivateNameRemap = shared_vm.clearPrivateNameRemap;
const appendPrivateNameRemap = shared_vm.appendPrivateNameRemap;
const installLexicalPrivateNameRemap = shared_vm.installLexicalPrivateNameRemap;
const installFreshPrivateNameRemap = shared_vm.installFreshPrivateNameRemap;
const copyPrivateNameRemap = shared_vm.copyPrivateNameRemap;
const remapPrivateAtomFromObject = shared_vm.remapPrivateAtomFromObject;
const remapPrivateAtomFromFrame = shared_vm.remapPrivateAtomFromFrame;
const remapPrivateAtomForOperation = shared_vm.remapPrivateAtomForOperation;
const stringObjectHasIndexProperty = shared_vm.stringObjectHasIndexProperty;
const getPrototypeMethodWithFallback = shared_vm.getPrototypeMethodWithFallback;
const inOp = shared_vm.inOp;
const instanceofOp = shared_vm.instanceofOp;
const constructorNameEqlLocal = shared_vm.constructorNameEqlLocal;
const nativeFunctionNameValueLocal = shared_vm.nativeFunctionNameValueLocal;
const getPrototypeMethod = shared_vm.getPrototypeMethod;
const isBlockedByUnscopables = shared_vm.isBlockedByUnscopables;
const hasPropertyForWith = shared_vm.hasPropertyForWith;
const hasValueProperty = shared_vm.hasValueProperty;
const validateProxyHasResult = shared_vm.validateProxyHasResult;
const indexedExoticHasProperty = shared_vm.indexedExoticHasProperty;
const typedArrayCanonicalGet = shared_vm.typedArrayCanonicalGet;
const typedArrayCanonicalOwnDescriptor = shared_vm.typedArrayCanonicalOwnDescriptor;
const typedArrayCanonicalSet = shared_vm.typedArrayCanonicalSet;
const typedArrayCanonicalHas = shared_vm.typedArrayCanonicalHas;
const typedArrayCanonicalDelete = shared_vm.typedArrayCanonicalDelete;
const typedArrayCanonicalNumericIndex = shared_vm.typedArrayCanonicalNumericIndex;
const deleteValuePropertyOrThrow = shared_vm.deleteValuePropertyOrThrow;
const deleteValueProperty = shared_vm.deleteValueProperty;
const proxyTrapKeyValue = shared_vm.proxyTrapKeyValue;
const lookupFrameVarRef = shared_vm.lookupFrameVarRef;
const lookupFrameLocalValue = shared_vm.lookupFrameLocalValue;
const lookupEvalBindingValue = shared_vm.lookupEvalBindingValue;
const lookupFrameFirstEvalBindingValue = shared_vm.lookupFrameFirstEvalBindingValue;
const lookupParentFunctionEvalBindingValue = shared_vm.lookupParentFunctionEvalBindingValue;
const capturedArgumentsObject = shared_vm.capturedArgumentsObject;
const atomIdOrNameEql = shared_vm.atomIdOrNameEql;
const lookupNamedVarRef = shared_vm.lookupNamedVarRef;
const deleteEvalBinding = shared_vm.deleteEvalBinding;
const deleteFrameLocalBinding = shared_vm.deleteFrameLocalBinding;
const deleteNamedSlotBinding = shared_vm.deleteNamedSlotBinding;
const deleteNamedVarRefBinding = shared_vm.deleteNamedVarRefBinding;
const deleteVarRefSlot = shared_vm.deleteVarRefSlot;
const lookupNamedSlotValue = shared_vm.lookupNamedSlotValue;
const lookupNamedRawSlotValue = shared_vm.lookupNamedRawSlotValue;
const setNamedSlotValue = shared_vm.setNamedSlotValue;
const setFrameLocalValue = shared_vm.setFrameLocalValue;
const setFrameVarRefValue = shared_vm.setFrameVarRefValue;
const setNamedVarRefValue = shared_vm.setNamedVarRefValue;
const defineValueProperty = shared_vm.defineValueProperty;
const defineFunctionNameProperty = shared_vm.defineFunctionNameProperty;
const objectHasNonEmptyName = shared_vm.objectHasNonEmptyName;
const functionNameValueFromAtom = shared_vm.functionNameValueFromAtom;
const mappedArgumentsValue = shared_vm.mappedArgumentsValue;
const setMappedArgumentsValue = shared_vm.setMappedArgumentsValue;
const createNamedError = shared_vm.createNamedError;
const createNamedErrorWithConstructor = shared_vm.createNamedErrorWithConstructor;
const ensureVarRefCell = shared_vm.ensureVarRefCell;
const ensureLocalVarRefCell = shared_vm.ensureLocalVarRefCell;
const readInt = shared_vm.readInt;

test "engine eval host globals and throw intrinsic tear down cleanly" {
    const exec = @import("root.zig");

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const ctx = try core.JSContext.create(rt);
    defer ctx.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    global.is_global = true;
    defer global.value().free(rt);

    try exec.call.installHostGlobals(rt, global);

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);

    const eval_entry = @import("eval_entry.zig");
    const value = try eval_entry.eval(ctx, "print(1);", .{ .output = &output });
    defer value.free(rt);

    try std.testing.expect(value.isUndefined());
    try std.testing.expectEqualStrings("1\n", output.buffered());
}
