//! Expressions: the QuickJS `js_parse_expr` family, lvalues, calls, member chains, literals.

const std = @import("std");
const root = @import("../parser.zig");
const bytecode = @import("../bytecode.zig");
const atom_module = @import("../core/atom.zig");
const core = @import("../core/root.zig");
const regexp_lib = @import("../libs/regexp.zig");
const JSValue = @import("../core/value.zig").JSValue;
const compiler = @import("../compiler/root.zig");
const function_def_mod = bytecode.function_def;
const opcode = bytecode.opcode;
const tok = root.token;
const diagnostics = root.diagnostics;
const Atom = atom_module.Atom;
const parse_state = @import("parse_state.zig");
const closure = @import("closure.zig");
const identifiers = @import("identifiers.zig");
const lookahead = @import("lookahead.zig");
const emitter = @import("emitter.zig");
const functions = @import("functions.zig");
const classes = @import("classes.zig");
const typescript = @import("typescript.zig");
const atom_this = parse_state.atom_this;
const atom_new_target = parse_state.atom_new_target;
const atom_this_active_func = parse_state.atom_this_active_func;
const atom_home_object = parse_state.atom_home_object;
const atom_class_fields_init = parse_state.atom_class_fields_init;
const OptionalChainLabel = parse_state.OptionalChainLabel;
const FunctionSourceStart = parse_state.FunctionSourceStart;
const Error = parse_state.Error;
const ParseFlags = parse_state.ParseFlags;
const ParseFunctionKind = parse_state.ParseFunctionKind;
const State = parse_state.State;
const Emitter = emitter.Emitter;

fn forceResultNeeded(flags: ParseFlags) ParseFlags {
    var value_flags = flags;
    value_flags.result_needed = true;
    return value_flags;
}

/// QuickJS tests arrow cover forms at the assignment-expression boundary,
/// before destructuring and the ordinary conditional-expression path.
fn parseArrowAssignment(s: *State, flags: ParseFlags) Error!bool {
    if (s.peekKind() == .lparen) {
        if (!(try lookahead.checkArrowHead(s, flags.arrow_return_type_forbidden))) return false;
        const source_start = s.currentFunctionSourceStart();
        try functions.parseArrowFunction(s, .normal, source_start, flags);
        return true;
    }

    if (typescript.tsAtLess(s)) {
        // TypeScript generic arrow `<T>(...) => body`; anything else that
        // starts with `<` is a type assertion handled by parseUnary.
        if (!(try typescript.tsGenericArrowHead(s, flags.arrow_return_type_forbidden))) return false;
        const source_start = s.currentFunctionSourceStart();
        try typescript.tsParseTypeParameters(s);
        try functions.parseArrowFunction(s, .normal, source_start, flags);
        return true;
    }

    if (s.isAsyncIdentifier()) {
        if (try lookahead.checkAsyncArrowHeadAfterAsync(s, flags.arrow_return_type_forbidden)) {
            const source_start = s.currentFunctionSourceStart();
            try s.advance(); // consume contextual `async`
            if (typescript.tsAtLess(s)) try typescript.tsParseTypeParameters(s);
            try functions.parseArrowFunction(s, .async, source_start, flags);
            return true;
        }
        // Otherwise `async` may itself be the parameter of `async => ...`.
    }

    // QuickJS handles generator `yield` before arrow cover grammar, and
    // Await is not a BindingIdentifier in async/module contexts. Preserve
    // the same qualification that parsePrimary applies to identifiers so
    // this earlier dispatch cannot reinterpret either expression form (or
    // an escaped reserved word) as an arrow parameter.
    if (s.peekKind() == .kw_yield and
        (s.ctx.in_generator or s.isStrict())) return false;
    if (s.peekKind() == .kw_await and !identifiers.canUseAwaitAsIdentifier(s)) return false;
    if (s.peekKind() == .ident) {
        if (s.token.payload.ident.has_escape and
            identifiers.escapedIdentifierIsReservedWordForCurrentContext(s, s.token.payload.ident.atom, true)) return false;
    } else if (!identifiers.isIdentifierLikeToken(s)) return false;
    if (!(try lookahead.checkIdentArrowHead(s))) return false;
    const source_start = s.currentFunctionSourceStart();
    try functions.parseArrowFunction(s, .normal, source_start, flags);
    return true;
}

/// `js_parse_expr`.
pub fn parseExpr(s: *State) Error!void {
    return parseExpr2(s, ParseFlags.default) catch |err| s.propagateFailureHere(err);
}

/// `js_parse_expr2`. Comma operator.
pub fn parseExpr2(s: *State, flags: ParseFlags) Error!void {
    s.features.insert(.expression);
    var operand_flags = flags;
    try parseAssignExpr2(s, operand_flags);
    var saw_comma = false;
    while (s.peekKind() == .comma) {
        saw_comma = true;
        try s.advance();
        // Discard left-hand side; `a, b` evaluates to b.
        try Emitter.op(s, opcode.op.drop);
        operand_flags.result_needed = flags.result_needed;
        try parseAssignExpr2(s, operand_flags);
    }
    if (saw_comma) {
        // QuickJS invalidates last_opcode_pos after parsing the rightmost
        // operand of a comma expression: `(a, b)` is a value, never an
        // lvalue merely because `b` ended in a getter.
        s.invalidateLastOpcode();
    }
}

/// `js_parse_assign_expr`.
pub fn parseAssignExpr(s: *State) Error!void {
    return parseAssignExpr2(s, ParseFlags.default) catch |err| s.propagateFailureHere(err);
}

/// `js_parse_assign_expr2`. Assignment-target check
/// and compound-assignment lowering for identifiers, member targets,
/// destructuring, and arrow cover forms.
pub fn parseAssignExpr2(s: *State, flags: ParseFlags) Error!void {
    s.assign_expr_depth += 1;
    const current_assign_depth = s.assign_expr_depth;
    if (s.last_coalesce_expr_depth == current_assign_depth) {
        s.last_coalesce_expr_depth = null;
    }
    defer s.assign_expr_depth -= 1;

    // A YieldExpression is a whole AssignmentExpression: nothing continues
    // it, so a line break before `+`, `?` or `/` ends the statement (ASI)
    // instead of applying the operator to the yield (qjs js_parse_assign_expr2).
    if (s.ctx.in_generator and !s.ctx.in_class_static_block and s.peekKind() == .kw_yield) {
        return parseYieldExpression(s, flags);
    }

    if (try parseArrowAssignment(s, flags)) return;
    if (try parseDestructuringAssignment(s, flags)) return;
    // QuickJS's `name0` is not duplicated because the emitted getter pins
    // it. Keep a local owner instead, so anonymous-function naming does
    // not depend on that downstream operand's lifetime.
    const direct_lhs_atom: ?Atom = if (s.peekKind() == .ident)
        s.token.payload.ident.atom
    else
        null;

    try parseCondExpr(s, flags);

    const op_kind = s.peekKind();
    const assign_opcode = compoundAssignOpcode(op_kind);
    const logical_assign = logicalAssignKind(op_kind);
    const is_plain_assign = op_kind == .assign;
    if (!is_plain_assign and assign_opcode == null and logical_assign == null) return;
    const operator_source = s.currentSourcePosition();

    if (s.last_coalesce_expr_depth == current_assign_depth) {
        return Error.InvalidAssignmentTarget;
    }

    try s.advance(); // consume the assignment operator
    var lvalue = try getLValue(s, !is_plain_assign);

    if (lvalue.invalid_call and logical_assign != null) {
        // Annex B does not extend runtime errors to logical assignment
        // targets; these remain early SyntaxErrors.
        return Error.InvalidAssignmentTarget;
    }

    if (lvalue.invalid_call) {
        // Runtime-error CallExpression targets evaluate the call, then
        // throw before evaluating the RHS. Parse the RHS into an
        // unreachable, stack-balanced tail so syntax and nested parser
        // state remain identical to an ordinary assignment.
        const invalid_target_label = try Emitter.newLabel(s);
        try Emitter.jump(s, opcode.op.goto, invalid_target_label);
        const rhs_flags = ParseFlags{ .in_accepted = flags.in_accepted, .arrow_return_type_forbidden = flags.arrow_return_type_forbidden };
        try parseAssignExpr2(s, rhs_flags);
        try Emitter.opNoSource(s, opcode.op.drop);
        try Emitter.bind(s, invalid_target_label);
        try emitInvalidAssignmentTarget(s);
        return;
    }

    if (logical_assign) |kind| {
        try parseLogicalAssignment(s, flags, &lvalue, kind, direct_lhs_atom);
        return;
    }

    const rhs_flags = ParseFlags{ .in_accepted = flags.in_accepted, .arrow_return_type_forbidden = flags.arrow_return_type_forbidden };
    try parseAssignExpr2(s, rhs_flags);
    if (assign_opcode) |op_byte| {
        // qjs js_parse_assign_expr2: the
        // compound op is pinned to the operator's source event.
        try Emitter.opAt(s, op_byte, operator_source.line_num, operator_source.col_num);
    }

    if (is_plain_assign and direct_lhs_atom != null and lvalue.owns_name and
        lvalue.name == direct_lhs_atom.?)
    {
        // qjs js_parse_assign_expr2 / set_object_name:
        // patch only a directly
        // trailing anonymous placeholder.
        try functions.setObjectName(s, lvalue.name);
    }

    try putLValue(s, &lvalue, .keep_top);
}

fn parseDestructuringAssignment(s: *State, flags: ParseFlags) Error!bool {
    if (s.peekKind() != .lbracket and
        s.peekKind() != .lbrace)
    {
        return false;
    }
    // Only `[...] =` / `{...} =` is a destructuring assignment. An unclosed
    // scan (including nesting deeper than the lookahead tracks) is not one,
    // nor is a scan that misread a token (`f<A<T>> / 2` lexed as a regex);
    // the expression parser reports any real error.
    const balanced = lookahead.scanBalancedToken(s, false) catch |err| {
        if (err == error.OutOfMemory) return err;
        return false;
    };
    if (!balanced.closed or balanced.following != .assign) return false;
    _ = try functions.parseDestructuringElement(s, .assignment, .{ .allow_outer_initializer = true }, ParseFlags{ .in_accepted = flags.in_accepted, .arrow_return_type_forbidden = flags.arrow_return_type_forbidden });
    return true;
}

const LogicalAssignKind = enum {
    land,
    lor,
    nullish,
};

fn parseLogicalAssignment(
    s: *State,
    flags: ParseFlags,
    lvalue: *LValue,
    kind: LogicalAssignKind,
    direct_lhs_atom: ?Atom,
) Error!void {
    // qjs js_parse_assign_expr2 logical assignment (quickjs.c:
    // 28167-28204): all topology bookkeeping is source-less.
    try Emitter.opNoSource(s, opcode.op.dup);
    if (kind == .nullish) try Emitter.opNoSource(s, opcode.op.is_undefined_or_null);
    const skip_assign = try Emitter.newLabel(s);
    try Emitter.jumpNoSource(
        s,
        if (kind == .lor) opcode.op.if_true else opcode.op.if_false,
        skip_assign,
    );
    try Emitter.opNoSource(s, opcode.op.drop);

    const rhs_flags = ParseFlags{ .in_accepted = flags.in_accepted, .arrow_return_type_forbidden = flags.arrow_return_type_forbidden };
    try parseAssignExpr2(s, rhs_flags);
    if (direct_lhs_atom != null and lvalue.owns_name and
        lvalue.name == direct_lhs_atom.?)
    {
        try functions.setObjectName(s, lvalue.name);
    }

    if (lvalue.depth == 3) {
        try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.insert4);
    } else {
        try Emitter.opNoSource(s, switch (lvalue.depth) {
            0 => opcode.op.dup,
            1 => opcode.op.insert2,
            2 => opcode.op.insert3,
            else => unreachable,
        });
    }
    try putLValue(s, lvalue, .no_keep_depth);
    const end = try Emitter.newLabel(s);
    try Emitter.jumpNoSource(s, opcode.op.goto, end);
    try Emitter.bind(s, skip_assign);
    var depth = lvalue.depth;
    while (depth != 0) : (depth -= 1) try Emitter.opNoSource(s, opcode.op.nip);
    try Emitter.bind(s, end);
}

const LValueOpcode = enum {
    scope_var,
    field,
    private_field,
    array_element,
    super_value,
    ref_value,
};

/// The assignment target get_lvalue describes. `owns_name` marks a `name`
/// taken from the getter's atom operands that putLValue has not consumed.
pub const LValue = struct {
    opcode: LValueOpcode,
    scope: u16 = 0,
    name: Atom = atom_module.null_atom,
    owns_name: bool = false,
    /// scope_make_ref aux label as a LabelId; put binds it
    /// (qjs put_lvalue emit_label).
    ref_label: ?compiler.LabelId = null,
    depth: u8,
    invalid_call: bool = false,
};

fn isRuntimeInvalidCallOpcode(op_id: u8) bool {
    return switch (op_id) {
        opcode.op.call,
        opcode.op.call_method,
        opcode.op.apply,
        opcode.op.eval,
        opcode.op.apply_eval,
        => true,
        else => false,
    };
}

/// Drop the evaluated CallExpression target and throw the Annex-B
/// runtime ReferenceError. Spoken through `Emitter` so both backends
/// materialize it: the legacy stream keeps the exact two calls it made
/// before, and a v2 parse routes them into the Builder instead of
/// silently appending to the unconsumed legacy buffer.
pub fn emitInvalidAssignmentTarget(s: *State) Error!void {
    try Emitter.opNoSource(s, opcode.op.drop);
    try Emitter.opAtomU8(
        s,
        opcode.op.throw_error,
        atom_module.null_atom,
        opcode.throw_error_invalid_assignment_target,
    );
}

const PutLValueMode = enum {
    no_keep,
    no_keep_depth,
    keep_top,
    keep_second,
    no_keep_bottom,
};

/// Whether a `with` object may sit between this reference and its binding:
/// a `with` body scope in this or an enclosing function, or, for direct-eval
/// code, a `with` in the caller's environment.
fn hasWithScopeFrom(fd_start: *const function_def_mod.FunctionDef, scope_start: i32) bool {
    var fd: ?*const function_def_mod.FunctionDef = fd_start;
    var scope = scope_start;
    while (fd) |current| {
        if (scope >= 0 and @as(usize, @intCast(scope)) < current.scopes.len and
            current.scopes[@intCast(scope)].inside_with) return true;
        if (current.parent == null) return current.eval_inside_with;
        scope = current.parent_scope_level;
        fd = current.parent;
    }
    return false;
}

/// Re-emit the lvalue getter with no source marker (qjs get_lvalue).
fn reemitLValueGetter(s: *State, lvalue: *const LValue) Error!void {
    switch (lvalue.opcode) {
        .scope_var => {
            // qjs get_lvalue: re-emit the retained
            // scope getter while preserving the assignment target.
            try Emitter.opAtomU16NoSource(s, opcode.op.scope_get_var, lvalue.name, lvalue.scope);
        },
        .field => {
            // qjs get_lvalue: get_field2 preserves
            // the base object beneath the loaded value.
            try Emitter.opAtomNoSource(s, opcode.op.get_field2, lvalue.name);
        },
        .private_field => {
            // qjs get_lvalue: the private-field
            // getter retains its base and phase-1 scope operand.
            try Emitter.opAtomU16NoSource(s, opcode.op.scope_get_private_field2, lvalue.name, lvalue.scope);
        },
        .array_element => {
            // qjs get_lvalue: get_array_el3 keeps
            // both base and property key for the later setter.
            try Emitter.opNoSource(s, opcode.op.get_array_el3);
        },
        .super_value => {
            // qjs get_lvalue: preserve the super
            // receiver/base/key triple around the value load.
            try Emitter.opNoSource(s, opcode.op.to_propkey);
            try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.dup3);
            try Emitter.opNoSource(s, opcode.op.get_super_value);
        },
        .ref_value => {
            // qjs get_lvalue: load through the
            // with-scope reference while retaining the ref pair.
            try Emitter.opNoSource(s, opcode.op.get_ref_value);
        },
    }
}

/// Assignment-target capture — qjs get_lvalue.
/// Builder.last_opcode_pos is the sole target fact;
/// getter removal is the qjs `fd->byte_code.size = fd->last_opcode_pos`
/// rewind (Builder.truncateLastOpcodePreserveSources after the ledger take-back).
pub fn getLValue(s: *State, keep: bool) Error!LValue {
    const v2b = s.activeBuilder();
    const pos = v2b.last_opcode_pos orelse return Error.InvalidAssignmentTarget;
    const op_id = v2b.code[pos];
    const fd = s.curFunc();

    // Annex-B runtime-error CallExpression target: the call opcode must
    // be the whole tail. The temp stream uses the phase-1 encodings, so
    // the size table applies unchanged.
    // The concat call of a template literal is no CallExpression:
    // `\`${a}\` = 1` is an early error, not the Annex B runtime one.
    if (s.template_concat_call_pos == pos) return Error.InvalidAssignmentTarget;
    if (!s.is_strict and !fd.is_strict_mode and isRuntimeInvalidCallOpcode(op_id)) {
        const call_size = opcode.sizeOfPhase1(op_id);
        if (call_size == 0 or pos + call_size != v2b.code_len) return Error.InvalidAssignmentTarget;
        return .{
            .opcode = .scope_var,
            .depth = 1,
            .invalid_call = true,
        };
    }

    var lvalue: LValue = undefined;
    switch (op_id) {
        opcode.op.scope_get_var => {
            // qjs get_lvalue: decode the phase-1
            // scope getter and retain its atom across the rewind.
            if (pos + 7 != v2b.code_len) return Error.InvalidAssignmentTarget;
            const name: Atom = Atom.fromRaw(std.mem.readInt(u32, v2b.code[pos + 1 ..][0..4], .little));
            const scope = std.mem.readInt(u16, v2b.code[pos + 5 ..][0..2], .little);
            if ((s.is_strict or fd.is_strict_mode) and
                (identifiers.atomNameEquals(s, name, "eval") or identifiers.atomNameEquals(s, name, "arguments")))
            {
                return Error.InvalidAssignmentTarget;
            }
            if (name == atom_this or name == atom_new_target) return Error.InvalidAssignmentTarget;
            // Same reference-form selection as QuickJS: a sloppy
            // assignment whose RHS can run a direct eval must keep the
            // binding it selected while evaluating the LHS, because the
            // eval may insert a same-named var before the store happens.
            // `resolve_variables` folds the reference back to a direct
            // store when no dynamic environment is present.
            //
            // The strict-unresolved snapshot is the same decision
            // QuickJS makes: an unresolvable Reference in strict code
            // must be decided when the LHS is evaluated, before the RHS
            // can create the global property.
            const strict_unresolved = identifiers.strictUnresolvedAssignmentNeedsReference(s, name, keep);
            const with_scope = hasWithScopeFrom(fd, scope);
            // The binding scan is linear in the function's locals, so it runs
            // only for the sloppy case that reads it.
            const needs_reference = with_scope or
                strict_unresolved or
                (!s.is_eval and !s.is_strict and !fd.is_strict_mode and
                    !closure.hasVisibleCurrentBinding(fd, name, @intCast(scope)) and
                    fd.findGlobalVarName(name) == null and
                    try State.rhsContainsDirectEval(s));
            const owned_name = try v2b.takeTrailingAtomOpcodeOwned(pos, op_id, name);
            lvalue = .{
                .opcode = .scope_var,
                .scope = scope,
                .name = owned_name,
                .owns_name = true,
                .depth = 0,
            };
            if (needs_reference) {
                lvalue.opcode = .ref_value;
                lvalue.depth = 2;
                // qjs get_lvalue: scope_make_ref carries the label as an aux
                // operand; putLValue binds it.
                const ref_label = try Emitter.newLabel(s);
                try Emitter.scopeRefOp(s, opcode.op.scope_make_ref, owned_name, ref_label, scope);
                lvalue.ref_label = ref_label;
            }
        },
        opcode.op.get_field => {
            // qjs get_lvalue: take the
            // field-name retain back before removing the getter.
            // W1: `get_field` is `atom_cache_u8` (opcode + atom + cache_idx).
            if (pos + 6 != v2b.code_len) return Error.InvalidAssignmentTarget;
            const name: Atom = Atom.fromRaw(std.mem.readInt(u32, v2b.code[pos + 1 ..][0..4], .little));
            const owned_name = try v2b.takeTrailingAtomOpcodeOwned(pos, op_id, name);
            lvalue = .{ .opcode = .field, .name = owned_name, .owns_name = true, .depth = 1 };
        },
        opcode.op.scope_get_private_field => {
            // qjs get_lvalue: retain
            // the private name and scope across the getter rewind.
            if (pos + 7 != v2b.code_len) return Error.InvalidAssignmentTarget;
            const name: Atom = Atom.fromRaw(std.mem.readInt(u32, v2b.code[pos + 1 ..][0..4], .little));
            const scope = std.mem.readInt(u16, v2b.code[pos + 5 ..][0..2], .little);
            const owned_name = try v2b.takeTrailingAtomOpcodeOwned(pos, op_id, name);
            lvalue = .{
                .opcode = .private_field,
                .scope = scope,
                .name = owned_name,
                .owns_name = true,
                .depth = 1,
            };
        },
        opcode.op.get_array_el => {
            // qjs get_lvalue: remove
            // the one-byte array getter; its base/key remain on the stack.
            if (pos + 1 != v2b.code_len) return Error.InvalidAssignmentTarget;
            try v2b.truncateLastOpcodePreserveSources(pos);
            lvalue = .{ .opcode = .array_element, .depth = 2 };
        },
        opcode.op.get_super_value => {
            // qjs get_lvalue: remove
            // the super getter and preserve its three-value target depth.
            if (pos + 1 != v2b.code_len) return Error.InvalidAssignmentTarget;
            try v2b.truncateLastOpcodePreserveSources(pos);
            lvalue = .{ .opcode = .super_value, .depth = 3 };
        },
        else => return Error.InvalidAssignmentTarget,
    }

    if (keep) try reemitLValueGetter(s, &lvalue);
    return lvalue;
}

/// QuickJS `put_lvalue`, with LabelId binding
/// instead of a deferred absolute-target publish.
pub fn putLValue(s: *State, lvalue: *LValue, mode: PutLValueMode) Error!void {
    const shuffle_op: ?u8 = switch (lvalue.opcode) {
        .scope_var => switch (mode) {
            .keep_top => opcode.op.dup,
            .no_keep, .no_keep_depth, .keep_second, .no_keep_bottom => null,
        },
        .field, .private_field => switch (mode) {
            .no_keep, .no_keep_depth => null,
            .keep_top => opcode.op.insert2,
            .keep_second => opcode.op.perm3,
            .no_keep_bottom => opcode.op.swap,
        },
        .array_element, .ref_value => switch (mode) {
            .no_keep => opcode.op.nop,
            .no_keep_depth => null,
            .keep_top => opcode.op.insert3,
            .keep_second => opcode.op.perm4,
            .no_keep_bottom => opcode.op.rot3l,
        },
        .super_value => switch (mode) {
            .no_keep, .no_keep_depth => null,
            .keep_top => null,
            .keep_second => null,
            .no_keep_bottom => null,
        },
    };

    switch (lvalue.opcode) {
        .scope_var, .field, .private_field => if (!lvalue.owns_name) return Error.InvalidAssignmentTarget,
        .ref_value => {
            if (!lvalue.owns_name) return Error.InvalidAssignmentTarget;
            if (lvalue.ref_label == null) return Error.ParserInvariant;
        },
        .array_element, .super_value => {},
    }

    if (lvalue.opcode == .ref_value) {
        // qjs put_lvalue: JS_FreeAtom(name) then
        // emit_label(label) — the ref target binds here, before the mode
        // shuffle; the bind is the provenance boundary the legacy arm expressed
        // as invalidateLastOpcode + deferred absolute publish.
        lvalue.owns_name = false;
        // qjs put_lvalue's emit_label is a physical matcher boundary even
        // after scope_make_ref consumes its auxiliary refcount. Preserve
        // that identity as a Stage-4 match barrier; the legacy phase-1
        // stream expresses the same boundary with OP_label.
        try Emitter.bindParser(s, lvalue.ref_label.?);
    }

    // qjs put_lvalue: apply the selected stack
    // preservation shuffle before emitting the setter. insert4 was
    // reclaimed for fusion v4 and emits as using+sub.
    if (lvalue.opcode == .super_value and mode == .keep_top)
        try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.insert4)
    else if (lvalue.opcode == .super_value and mode == .keep_second)
        try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.perm5)
    else if (lvalue.opcode == .super_value and mode == .no_keep_bottom)
        try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.rot4l)
    else if (shuffle_op) |op_id| try Emitter.opNoSource(s, op_id);

    switch (lvalue.opcode) {
        .scope_var => {
            // qjs put_lvalue: transfer the retained
            // binding atom into scope_put_var's phase-1 operand ledger.
            lvalue.owns_name = false;
            try Emitter.opAtomU16NoSource(s, opcode.op.scope_put_var, lvalue.name, lvalue.scope);
        },
        .field => {
            // qjs put_lvalue: transfer the retained
            // field-name atom into put_field.
            lvalue.owns_name = false;
            try Emitter.opAtomNoSource(s, opcode.op.put_field, lvalue.name);
        },
        .private_field => {
            // qjs put_lvalue: transfer the retained
            // private name and scope into the phase-1 setter.
            lvalue.owns_name = false;
            try Emitter.opAtomU16NoSource(s, opcode.op.scope_put_private_field, lvalue.name, lvalue.scope);
        },
        .array_element => {
            // qjs put_lvalue: consume base/key/value.
            try Emitter.opNoSource(s, opcode.op.put_array_el);
        },
        .ref_value => {
            // qjs put_lvalue: store through the
            // reference pair whose label was bound above.
            try Emitter.opNoSource(s, opcode.op.put_ref_value);
        },
        .super_value => {
            // qjs put_lvalue: store through the
            // preserved super receiver/base/key triple.
            try Emitter.opU8NoSource(s, opcode.op.ext0, opcode.ext0_sub.put_super_value);
        },
    }
}

/// `js_parse_cond_expr`. `a ? b: c`.
pub fn parseCondExpr(s: *State, flags: ParseFlags) Error!void {
    try parseCoalesceExpr(s, flags);
    if (s.peekKind() == .question) {
        try s.advance();
        var then_flags = forceResultNeeded(flags);
        then_flags.in_accepted = true;
        then_flags.arrow_return_type_forbidden = true;
        const else_flags = forceResultNeeded(flags);
        // qjs js_parse_cond_expr: label1 = emit_goto(if_false), label2 = emit_goto(goto), emit_label at each merge.
        const else_label = try Emitter.newLabel(s);
        try Emitter.jump(s, opcode.op.if_false, else_label);
        try parseAssignExpr2(s, then_flags);
        const end_label = try Emitter.newLabel(s);
        try Emitter.jump(s, opcode.op.goto, end_label);
        try Emitter.bind(s, else_label);
        try s.expectToken(.colon);
        try parseAssignExpr2(s, else_flags);
        try Emitter.bind(s, end_label);
    }
}

/// `js_parse_coalesce_expr`. `a ?? b`.
pub fn parseCoalesceExpr(s: *State, flags: ParseFlags) Error!void {
    try parseLogicalAndOr(s, .lor, flags);
    if (s.peekKind() == .double_question_mark) {
        s.last_coalesce_expr_depth = s.assign_expr_depth;
        // qjs js_parse_coalesce_expr: label1 = new_label(); every non-nullish
        // test jumps to it; emit_label(label1) after the operand loop.
        const end_label = try Emitter.newLabel(s);
        const rhs_flags = forceResultNeeded(flags);
        while (s.peekKind() == .double_question_mark) {
            try s.advance();
            try Emitter.op(s, opcode.op.dup);
            try Emitter.op(s, opcode.op.is_undefined_or_null);
            try Emitter.jump(s, opcode.op.if_false, end_label);
            try Emitter.op(s, opcode.op.drop);
            try parseExprBinary(s, 8, rhs_flags);
        }
        try Emitter.bind(s, end_label);
    }
}

/// `js_parse_logical_and_or`. `a && b` / `a || b`.
pub fn parseLogicalAndOr(s: *State, op_kind: tok.Kind, flags: ParseFlags) Error!void {
    if (op_kind == .lor) {
        try parseLogicalAndOr(s, .land, flags);
        if (s.peekKind() == .lor) {
            // qjs js_parse_logical_and_or: label1 = new_label() before the loop;
            // dup ; if_true label1 ; drop per operand; emit_label(label1) at end.
            const end_label = try Emitter.newLabel(s);
            while (s.peekKind() == .lor) {
                try s.advance();
                // `a || b` → `dup ; if_true L_skip ; drop ; <b> ; L_skip:`
                try Emitter.opNoSource(s, opcode.op.dup);
                try Emitter.jumpNoSource(s, opcode.op.if_true, end_label);
                try Emitter.opNoSource(s, opcode.op.drop);
                try parseLogicalAndOr(s, .land, forceResultNeeded(flags));
                if (s.peekKind() != .lor and s.peekKind() == .double_question_mark) {
                    return s.failUnexpectedToken();
                }
            }
            try Emitter.bindParser(s, end_label);
        }
    } else {
        try parseExprBinary(s, 8, flags);
        if (s.peekKind() == .land) {
            // qjs js_parse_logical_and_or: label1 = new_label() before the loop;
            // dup ; if_false label1 ; drop per operand; emit_label(label1) at end.
            const end_label = try Emitter.newLabel(s);
            while (s.peekKind() == .land) {
                try s.advance();
                // `a && b` → `dup ; if_false L_skip ; drop ; <b> ; L_skip:`
                try Emitter.opNoSource(s, opcode.op.dup);
                try Emitter.jumpNoSource(s, opcode.op.if_false, end_label);
                try Emitter.opNoSource(s, opcode.op.drop);
                try parseExprBinary(s, 8, forceResultNeeded(flags));
                if (s.peekKind() != .land and s.peekKind() == .double_question_mark) {
                    return s.failUnexpectedToken();
                }
            }
            try Emitter.bindParser(s, end_label);
        }
    }
}

/// `js_parse_expr_binary`: binary expression up to precedence `level` (1 binds tightest; 0 is a
/// unary operand). Precedence climbing: one unary operand, then each level's
/// operators from tightest to loosest. Every right operand is parsed at the
/// next tighter level and so consumes all tighter operators, so once a
/// level's loop stops no tighter operator can follow. One native frame per
/// nesting (not one per level) keeps deep parenthesization within the
/// parser's native stack budget.
pub fn parseExprBinary(s: *State, level: u32, flags: ParseFlags) Error!void {
    if (level >= 4 and flags.in_accepted and s.peekKind() == .private_name and try s.peekNextKind() == .kw_in) {
        // `#x in o` is itself a RelationalExpression (level 4): further
        // relational operators take it as their left operand.
        s.features.insert(.private_name);
        const private_atom = classes.findClassPrivateBoundName(s, s.token.payload.ident.atom, 0) orelse return s.failUnexpectedToken();
        try s.advance();
        try s.expectToken(.kw_in);
        if ((try lookahead.checkArrowHead(s, false)) or
            (s.isAsyncIdentifier() and (try lookahead.checkAsyncArrowHeadAfterAsync(s, false))))
        {
            return s.failUnexpectedToken();
        }
        try parseExprBinary(s, 3, flags);
        try Emitter.opAtomU16(s, opcode.op.scope_in_private_field, private_atom, @intCast(s.scope_level));
        return parseBinaryOperators(s, 4, level, flags);
    }
    try parseUnary(s, ParseFlags{
        .in_accepted = flags.in_accepted,
        .pow_allowed = true,
        .result_needed = flags.result_needed,
        .yield_forbidden = flags.yield_forbidden,
    });
    return parseBinaryOperators(s, 1, level, flags);
}

/// The operator loops of binary levels `min_level..max_level`, tightest
/// first, with the left operand already on the stack.
fn parseBinaryOperators(s: *State, min_level: u32, max_level: u32, flags: ParseFlags) Error!void {
    var level = min_level;
    while (level <= max_level) : (level += 1) {
        while (true) {
            if (level == 4 and typescript.tsAtAsOrSatisfies(s)) {
                // TypeScript `x as T` / `x as const` / `x satisfies T` bind at
                // relational precedence and erase to their operand.
                try s.advance();
                if (s.peekKind() == .kw_const) {
                    try s.advance();
                } else {
                    try typescript.tsParseTypeAllowConditional(s);
                }
                // `x as T!`: a non-null assertion on the assertion erases too.
                while (s.peekKind() == .bang and !s.gotLineTerminator()) try s.advance();
                // `x as T ** 2`: exponentiation is tighter still, and right
                // associative like the unary-level `**` it mirrors.
                try parsePowTail(s, .{ .in_accepted = flags.in_accepted, .pow_allowed = true });
                // tsc keeps consuming tighter operators with the asserted value
                // as their left operand: `y as number + 1` is `(y as number) + 1`.
                try parseBinaryOperators(s, 1, 3, flags);
                continue;
            }
            const op_byte = matchBinaryOp(s.peekKind(), level, flags);
            if (op_byte == opcode.op.invalid) break;
            const operator_source = s.currentSourcePosition();
            try s.advance();
            if (s.ctx.in_generator and s.peekKind() == .kw_yield) return s.failUnexpectedToken();
            try parseExprBinary(s, level - 1, flags);
            // qjs js_parse_expr_binary pins the selected operator to its token
            // after parsing the RHS.
            try Emitter.opAt(s, op_byte, operator_source.line_num, operator_source.col_num);
        }
    }
}

/// `js_parse_unary`. Covers prefix `+`, `-`, `~`,
/// `!`, `void`, `typeof`, `delete`, prefix `++`/`--`, right-associative
/// `**`, contextual `yield`, and contextual `await`.
// Keep this hot successor on a stable fetch boundary when the preceding
// recursive precedence dispatcher changes code size.
pub fn parseUnary(s: *State, flags: ParseFlags) align(16) Error!void {
    const k = s.peekKind();
    if (k == .lt or k == .shl) return typescript.tsParseTypeAssertion(s, flags);
    if (k == .plus) {
        const operator_source = s.currentSourcePosition();
        try s.advance();
        try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
        try Emitter.opAt(s, opcode.op.to_number, operator_source.line_num, operator_source.col_num);
        return;
    }
    if (k == .minus) {
        const operator_line_num = s.token.line_num;
        const operator_col_num = s.token.col_num;
        try s.advance();
        if (s.curFunc().use_short_opcodes and
            s.peekKind() == .number and
            !s.token.payload.num.is_bigint)
        {
            const value = s.token.payload.num.value;
            if (value != 0 and identifiers.numberIsExactI32(value)) {
                try s.advance();
                try emitter.emitGrammarSource(s, .{ .line_num = operator_line_num, .col_num = operator_col_num });
                try Emitter.opI32(s, opcode.op.push_i32, -@as(i32, @intFromFloat(value)));
                return;
            }
        }
        try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
        try Emitter.opAt(s, opcode.op.neg, operator_line_num, operator_col_num);
        return;
    }
    if (k == .tilde) {
        const operator_source = s.currentSourcePosition();
        try s.advance();
        try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
        try Emitter.opAt(s, opcode.op.not, operator_source.line_num, operator_source.col_num);
        return;
    }
    if (k == .bang) {
        try s.advance();
        try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
        try Emitter.op(s, opcode.op.lnot);
        return;
    }
    if (k == .kw_void) {
        try s.advance();
        try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
        try Emitter.opNoSource(s, opcode.op.drop);
        try Emitter.opNoSource(s, opcode.op.undefined);
        return;
    }
    if (k == .kw_typeof) {
        try s.advance();
        try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
        // QuickJS patches only the actual last phase-1 scope getter. A
        // member/call/comma/control tail therefore remains untouched.
        const v2b = s.activeBuilder();
        if (v2b.last_opcode_pos) |last_pos| {
            const pos: usize = last_pos;
            if (pos < v2b.code_len and v2b.code[pos] == opcode.op.scope_get_var) {
                v2b.code[pos] = opcode.op.scope_get_var_undef;
            }
        }
        try Emitter.op(s, opcode.op.typeof);
        return;
    }
    if (k == .kw_delete) {
        const delete_position = s.currentDiagnosticPosition();
        try s.advance();
        return parseDelete(s, flags, delete_position);
    }
    if (k == .inc or k == .dec) return parsePrefixUpdate(s, flags, k);
    // Handle yield expressions in generator functions.
    if (s.ctx.in_class_static_block and (k == .kw_await or k == .kw_yield)) {
        return s.failUnexpectedToken();
    }
    if (k == .kw_yield) return parseYieldExpression(s, flags);
    // Handle await expressions in async functions.
    if (k == .kw_await) return parseAwaitExpression(s, flags);
    try parsePostfixExpr(s, flags);
    try parsePowTail(s, flags);
}

/// PF_POW_ALLOWED: `a ** b` is right-associative and only allowed after an
/// UpdateExpression, never after a unary prefix (`-a ** b`, `await a ** b`).
fn parsePowTail(s: *State, flags: ParseFlags) Error!void {
    if (flags.pow_allowed and s.peekKind() == .pow) {
        const operator_source = s.currentSourcePosition();
        try s.advance();
        try parseUnary(s, ParseFlags{ .in_accepted = flags.in_accepted, .pow_allowed = true });
        try Emitter.opAt(s, opcode.op.pow, operator_source.line_num, operator_source.col_num);
    }
}

/// `++x` / `--x` (qjs js_parse_unary TOK_INC/TOK_DEC, quickjs.c).
fn parsePrefixUpdate(s: *State, flags: ParseFlags, k: tok.Kind) Error!void {
    const update_op: u8 = if (k == .inc) opcode.op.inc else opcode.op.dec;
    const operator_source = s.currentSourcePosition();
    try s.advance();
    try parseUnary(s, .{ .in_accepted = flags.in_accepted });
    var lvalue = try getLValue(s, true);
    if (lvalue.invalid_call) {
        try emitInvalidAssignmentTarget(s);
        return;
    }
    // qjs js_parse_unary: prefix update is
    // pinned to the operator's source event.
    try Emitter.opAt(s, update_op, operator_source.line_num, operator_source.col_num);
    try putLValue(s, &lvalue, .keep_top);
    if (flags.pow_allowed and s.peekKind() == .pow) {
        const exponent_source = s.currentSourcePosition();
        try s.advance();
        try parseUnary(s, ParseFlags{ .in_accepted = flags.in_accepted, .pow_allowed = true });
        // qjs js_parse_unary: emit the
        // exponentiation tail after its right operand.
        try Emitter.opAt(s, opcode.op.pow, exponent_source.line_num, exponent_source.col_num);
    }
    return;
}

/// YieldExpression, or `yield` as an identifier outside generators.
fn parseYieldExpression(s: *State, flags: ParseFlags) Error!void {
    if (!s.ctx.in_generator) {
        if (s.isStrict()) return Error.YieldOutsideGenerator;
        const next_kind_peek = try s.peekNext();
        const next_kind = next_kind_peek.kind;
        const next_has_line_terminator = next_kind_peek.line_terminator;
        if (!next_has_line_terminator and
            next_kind != .lparen and
            next_kind != .lbracket and
            next_kind != .template and
            identifiers.tokenStartsYieldExpressionOperand(next_kind))
        {
            return Error.YieldOutsideGenerator;
        }
        // Sloppy non-generator code: `yield` is a plain identifier.
        try parsePostfixExpr(s, flags);
        return parsePowTail(s, flags);
    }
    // A YieldExpression is not a UnaryExpression operand.
    if (flags.yield_forbidden) return s.failUnexpectedToken();
    if (s.ctx.in_parameter_initializer) return s.failUnexpectedToken();
    try s.advance();
    // Check for yield*. A line terminator after `yield` ends the
    // YieldExpression before any following operand.
    const has_line_terminator = s.lex.got_lf;
    if (has_line_terminator and s.peekKind() == .star) return s.failUnexpectedToken();
    const is_yield_star = !has_line_terminator and s.peekKind() == .star;
    if (is_yield_star) {
        try s.advance();
        try parseAssignExpr2(s, ParseFlags{ .in_accepted = flags.in_accepted, .arrow_return_type_forbidden = flags.arrow_return_type_forbidden });
        try emitYieldStarDelegation(s, s.ctx.in_async);
    } else {
        // Check if there's an expression after yield
        // yield without an expression is equivalent to yield undefined
        if (has_line_terminator or
            s.peekKind() == .semicolon or
            s.peekKind() == .comma or
            s.peekKind() == .colon or
            s.peekKind() == .rbrace or
            s.peekKind() == .rbracket or
            s.peekKind() == .rparen or
            s.peekKind() == .eof)
        {
            // yield without expression
            try Emitter.op(s, opcode.op.undefined);
        } else {
            // yield with expression
            try parseAssignExpr2(s, ParseFlags{ .in_accepted = flags.in_accepted, .arrow_return_type_forbidden = flags.arrow_return_type_forbidden });
        }
        try Emitter.op(s, opcode.op.yield);
        const normal_resume = try Emitter.newLabel(s);
        try Emitter.jump(s, opcode.op.if_false, normal_resume);
        try emitter.emitReturnValue(s, s.ctx.in_async and s.ctx.in_generator);
        try Emitter.bind(s, normal_resume);
    }
    return;
}

/// AwaitExpression, or `await` as an identifier outside async code.
fn parseAwaitExpression(s: *State, flags: ParseFlags) Error!void {
    // AwaitExpression is forbidden in formal-parameter initializers
    // of async functions.  Reject the actual grammar production here,
    // not every lexical `await` token in the initializer: IdentifierName
    // uses such as `({ await: 1 }).await` remain valid.
    if (s.ctx.in_parameter_initializer and s.ctx.reject_await_in_parameter_initializer) {
        return s.failUnexpectedToken();
    }
    const top_level_module_await = s.lex.is_module and s.cur_func_stack.len == 0;
    if (!s.ctx.in_async and !top_level_module_await) {
        const next = try s.peekNext();
        const next_kind = next.kind;
        // Outside async code `await` is an identifier; one followed by a
        // line break is an identifier statement that ASI terminates.
        if (identifiers.canUseAwaitAsIdentifier(s) and
            (next.line_terminator or
                !identifiers.tokenCanStartExpression(next_kind) or
                next_kind == .lparen or
                next_kind == .dot or
                next_kind == .lbracket or
                next_kind == .inc or
                next_kind == .dec))
        {
            try parsePostfixExpr(s, flags);
            return parsePowTail(s, flags);
        }
        return Error.AwaitOutsideAsyncFunction;
    }
    if (top_level_module_await) s.ensureModule().has_top_level_await = true;
    try s.advance();
    // `await`'s operand is a UnaryExpression (spec AwaitExpression:
    // `await UnaryExpression`; qjs js_parse_unary TOK_AWAIT parses a
    // unary operand), NOT an AssignmentExpression — so
    // `await Promise.resolve(2) * x` is `(await …) * x`, not
    // `await (… * x)`; as a unary prefix it also bars `**`.
    var operand_flags = flags;
    operand_flags.pow_allowed = false;
    operand_flags.yield_forbidden = true;
    try parseUnary(s, operand_flags);
    try Emitter.op(s, opcode.op.await);
    return;
}

/// LabelId-native mirror of QuickJS yield-star delegation
///; no absolute parser PC enters the v2 stream.
fn emitYieldStarDelegation(s: *State, is_async: bool) Error!void {
    const done_atom = atom_module.predefinedId("done", .string) orelse return Error.ParserInvariant;
    const value_atom = atom_module.predefinedId("value", .string) orelse return Error.ParserInvariant;

    try Emitter.op(s, if (is_async) opcode.op.for_await_of_start else opcode.op.for_of_start);
    try Emitter.op(s, opcode.op.drop);
    try Emitter.op(s, opcode.op.undefined);
    try Emitter.op(s, opcode.op.undefined);

    const loop_label = try Emitter.newLabel(s);
    try Emitter.bindRaw(s, loop_label);
    try Emitter.op(s, opcode.op.iterator_next);
    if (is_async) try Emitter.op(s, opcode.op.await);
    try Emitter.op(s, opcode.op.iterator_check_object);
    try Emitter.opAtom(s, opcode.op.get_field2, done_atom);
    const label_next = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.if_true, label_next);

    const yield_label = try Emitter.newLabel(s);
    try Emitter.bindRaw(s, yield_label);
    if (is_async) {
        try Emitter.opAtom(s, opcode.op.get_field, value_atom);
        try Emitter.op(s, opcode.op.async_yield_star);
    } else {
        try Emitter.op(s, opcode.op.yield_star);
    }
    try Emitter.op(s, opcode.op.dup);
    const label_return = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.if_true, label_return);
    try Emitter.op(s, opcode.op.drop);
    try Emitter.jump(s, opcode.op.goto, loop_label);

    try Emitter.bind(s, label_return);
    try Emitter.opI32(s, opcode.op.push_i32, 2);
    try Emitter.op(s, opcode.op.strict_eq);
    const label_throw = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.if_true, label_throw);

    if (is_async) {
        // AsyncGeneratorUnwrapYieldResumption awaits a return value; a
        // rejection resumes yield* as a throw (step 7.b). The await runs
        // under a handler whose catch slot takes the value's place, so the
        // reason lands on the throw path exactly where a thrown value would.
        const received = try functions.appendAnonymousTempLocal(s);
        try Emitter.opU16(s, opcode.op.put_loc, received);
        try Emitter.jump(s, opcode.op.@"catch", label_throw);
        try Emitter.opU16(s, opcode.op.get_loc, received);
        try Emitter.op(s, opcode.op.await);
        try Emitter.op(s, opcode.op.nip_catch);
    }
    try Emitter.opU8(s, opcode.op.iterator_call, 0);
    const label_return1 = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.if_true, label_return1);
    if (is_async) try Emitter.op(s, opcode.op.await);
    try Emitter.op(s, opcode.op.iterator_check_object);
    try Emitter.opAtom(s, opcode.op.get_field2, done_atom);
    try Emitter.jump(s, opcode.op.if_false, yield_label);

    try Emitter.opAtom(s, opcode.op.get_field, value_atom);
    // The inner return()'s value is returned as is (yield* step 7.c.viii);
    // only a missing inner return method awaits the received value (7.c.iii).
    const label_return_value = try Emitter.newLabel(s);
    if (is_async) {
        try Emitter.op(s, opcode.op.nip);
        try Emitter.op(s, opcode.op.nip);
        try Emitter.op(s, opcode.op.nip);
        try Emitter.jump(s, opcode.op.goto, label_return_value);
    }

    try Emitter.bind(s, label_return1);
    try Emitter.op(s, opcode.op.nip);
    try Emitter.op(s, opcode.op.nip);
    try Emitter.op(s, opcode.op.nip);
    if (is_async) try Emitter.op(s, opcode.op.await);
    try Emitter.bind(s, label_return_value);
    try emitter.emitReturnValue(s, false);

    try Emitter.bind(s, label_throw);
    try Emitter.opU8(s, opcode.op.iterator_call, 1);
    const label_throw1 = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.if_true, label_throw1);
    if (is_async) try Emitter.op(s, opcode.op.await);
    try Emitter.op(s, opcode.op.iterator_check_object);
    try Emitter.opAtom(s, opcode.op.get_field2, done_atom);
    try Emitter.jump(s, opcode.op.if_false, yield_label);
    const goto_next = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.goto, goto_next);

    try Emitter.bind(s, label_throw1);
    try Emitter.opU8(s, opcode.op.iterator_call, 2);
    const label_throw2 = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.if_true, label_throw2);
    if (is_async) try Emitter.op(s, opcode.op.await);
    try Emitter.bind(s, label_throw2);
    try Emitter.opAtomU8(s, opcode.op.throw_error, atom_module.null_atom, 4);

    try Emitter.bind(s, label_next);
    try Emitter.bind(s, goto_next);
    try Emitter.opAtom(s, opcode.op.get_field, value_atom);
    try Emitter.op(s, opcode.op.nip);
    try Emitter.op(s, opcode.op.nip);
    try Emitter.op(s, opcode.op.nip);
}

/// Emit `this` for a super-property receiver. QuickJS emits the same scope
/// lookup in methods and nested arrows; resolve_pseudo_var decides whether
/// this is an owner local or a closure over the nearest ThisBinding.
fn emitSuperThis(s: *State) Error!void {
    try s.emitScopeGetVar(atom_this);
}

/// Emit the `[this, home_object]` pair consumed by a super property
/// reference through ordinary pseudo-variable resolution.
fn emitSuperThisAndHomeObject(s: *State) Error!void {
    try emitSuperThis(s);
    try s.emitScopeGetVar(atom_home_object);
}

fn discardTrailingGetSuper(s: *State) Error!void {
    const builder = s.activeBuilder();
    const pos = builder.last_opcode_pos orelse return Error.ParserInvariant;
    if (pos + 1 != builder.code_len or builder.code[pos] != opcode.op.get_super)
        return Error.ParserInvariant;
    try builder.truncateLastOpcodePreserveSources(pos);
}

/// `js_parse_delete`. Generic implementation: parse
/// a unary-style operand normally, then classify the trailing emission
/// and rewrite it into a delete shape:
///
///   * `var_ref a`     → truncate `get_var a` ; emit `delete_var a`
///   * `dotted obj.b`  → in-place rewrite trailing `get_field b` to
///                       `push_atom_value b` (same byte length); emit
///                       `delete`
///   * `indexed a[i]`  → truncate trailing `get_array_el` (1 byte);
///                       emit `delete`
///   * `none`          → operand is not a reference; per spec return
///                       `true` after evaluating the operand for side
///                       effects: emit `drop ; push_true`
///
/// This handles arbitrary chain depths (`delete a.b.c`,
/// `delete a.b[i]`, etc.) because the rewrite touches only the final
/// access. Optional-chain and `super` references have dedicated trailing
/// opcode rewrites; private references are rejected.
fn parseDelete(s: *State, flags: ParseFlags, delete_position: diagnostics.Position) Error!void {
    try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
    return finishDelete(s, delete_position);
}

/// Compact a replacement appended after `snapshot.code_len` over a
/// source-less, atom-less trailing parser instruction. This is the v2
/// counterpart of qjs `fd->byte_code.size = fd->last_opcode_pos` followed
/// by fresh emission: old source events at the removed tail disappear,
/// while newly appended events, relocations, and binds move left with the
/// replacement. All invariants are checked before the no-fail commit.
fn compactAppendedTailReplacement(
    s: *State,
    snapshot: compiler.builder.Snapshot,
    remove_start: u32,
) Error!void {
    const v2b = s.activeBuilder();
    if (remove_start >= snapshot.code_len or snapshot.code_len > v2b.code_len) {
        return error.ParserInvariant;
    }
    const removed_len = snapshot.code_len - remove_start;
    const appended_len = v2b.code_len - snapshot.code_len;

    var reloc_index: u32 = 0;
    while (reloc_index < snapshot.reloc_len) : (reloc_index += 1) {
        const operand_offset = v2b.relocs[reloc_index].operand_offset;
        if (operand_offset >= remove_start and operand_offset < snapshot.code_len) {
            return Error.ParserInvariant;
        }
    }
    while (reloc_index < v2b.reloc_len) : (reloc_index += 1) {
        if (v2b.relocs[reloc_index].operand_offset < snapshot.code_len) {
            return Error.ParserInvariant;
        }
    }

    var label_index: u32 = 0;
    while (label_index < snapshot.label_len) : (label_index += 1) {
        const slot = v2b.label_slots[label_index];
        if (slot.flags.bound and slot.bound_offset > remove_start and
            slot.bound_offset < snapshot.code_len)
        {
            return Error.ParserInvariant;
        }
    }
    while (label_index < v2b.label_len) : (label_index += 1) {
        const slot = v2b.label_slots[label_index];
        if (slot.flags.bound and slot.bound_offset < snapshot.code_len) {
            return Error.ParserInvariant;
        }
    }

    var old_source_keep: u32 = 0;
    while (old_source_keep < snapshot.source_len and
        v2b.source_slots[old_source_keep].temp_offset < remove_start)
    {
        old_source_keep += 1;
    }
    var source_index = snapshot.source_len;
    while (source_index < v2b.source_len) : (source_index += 1) {
        if (v2b.source_slots[source_index].temp_offset < snapshot.code_len) {
            return Error.ParserInvariant;
        }
    }
    if (v2b.last_opcode_pos) |last_pos| {
        if (last_pos < snapshot.code_len) return Error.ParserInvariant;
    }

    const old_code_len = v2b.code_len;
    std.mem.copyForwards(
        u8,
        v2b.code[remove_start .. remove_start + appended_len],
        v2b.code[snapshot.code_len..old_code_len],
    );
    v2b.code_len = remove_start + appended_len;

    reloc_index = snapshot.reloc_len;
    while (reloc_index < v2b.reloc_len) : (reloc_index += 1) {
        v2b.relocs[reloc_index].operand_offset -= removed_len;
    }
    label_index = snapshot.label_len;
    while (label_index < v2b.label_len) : (label_index += 1) {
        const slot = &v2b.label_slots[label_index];
        if (slot.flags.bound) slot.bound_offset -= removed_len;
    }

    const new_source_count = v2b.source_len - snapshot.source_len;
    source_index = 0;
    while (source_index < new_source_count) : (source_index += 1) {
        var slot = v2b.source_slots[snapshot.source_len + source_index];
        slot.temp_offset -= removed_len;
        v2b.source_slots[old_source_keep + source_index] = slot;
    }
    v2b.source_len = old_source_keep + new_source_count;
    if (v2b.last_opcode_pos) |last_pos| v2b.last_opcode_pos = last_pos - removed_len;
}

/// Recover the shared optional-chain exit from Builder label identity.
/// The chain producer binds it raw at the getter end and at least one
/// source-less `goto` relocation references it. Ambiguity fails closed.
fn optionalChainExitAtEnd(s: *State) Error!compiler.LabelId {
    const v2b = s.activeBuilder();
    var found: ?compiler.LabelId = null;
    var label_index: u32 = 0;
    while (label_index < v2b.label_len) : (label_index += 1) {
        const slot = v2b.label_slots[label_index];
        if (!slot.flags.bound or slot.bound_offset != v2b.code_len) continue;

        var has_chain_goto = false;
        var reloc_index = slot.first_reloc;
        var walked: u32 = 0;
        while (reloc_index != compiler.labels.no_reloc) {
            if (reloc_index >= v2b.reloc_len or walked >= v2b.reloc_len) {
                return Error.ParserInvariant;
            }
            const reloc = v2b.relocs[reloc_index];
            if (reloc.kind == .jump32 and reloc.operand_offset > 0 and
                reloc.operand_offset + 4 <= v2b.code_len and
                v2b.code[reloc.operand_offset - 1] == opcode.op.goto and
                std.mem.readInt(u32, v2b.code[reloc.operand_offset..][0..4], .little) == label_index)
            {
                has_chain_goto = true;
            }
            reloc_index = reloc.next;
            walked += 1;
        }
        if (!has_chain_goto) continue;
        if (found != null) return Error.ParserInvariant;
        found = @enumFromInt(label_index);
    }
    return found orelse Error.UnexpectedToken;
}

fn emitDeleteNonReference(s: *State) Error!void {
    const v2b = s.activeBuilder();
    const snapshot = v2b.snapshot();
    errdefer v2b.rollback(snapshot);
    try Emitter.op(s, opcode.op.drop);
    try Emitter.op(s, opcode.op.push_true);
}

/// `js_parse_delete` over Builder.last_opcode_pos. Same-width
/// field/scope rewrites retain their atom-ledger entries; truncated
/// atom-less getters are replaced transactionally by appending first and
/// compacting only after every allocation succeeds.
fn finishDelete(s: *State, delete_position: diagnostics.Position) Error!void {
    const private_field_delete = "private fields cannot be deleted";
    const v2b = s.activeBuilder();
    const pos = v2b.last_opcode_pos orelse {
        if (s.private_opt_chain_end == v2b.code_len)
            return s.failWithMessage(delete_position, private_field_delete);
        return emitDeleteNonReference(s);
    };
    if (pos >= v2b.code_len) return Error.ParserInvariant;

    switch (v2b.code[pos]) {
        opcode.op.get_field_opt_chain,
        opcode.op.get_array_el_opt_chain,
        => return rewriteOptionalChainDeleteBuilder(s, pos),
        opcode.op.get_field => {
            // W1: `get_field` is `atom_cache_u8` (6 bytes).
            if (pos + 6 != v2b.code_len or v2b.atom_len == 0) return Error.ParserInvariant;
            const atom_id = Atom.fromRaw(std.mem.readInt(u32, v2b.code[pos + 1 ..][0..4], .little));
            if (v2b.atom_operands[v2b.atom_len - 1] != atom_id) return Error.ParserInvariant;
            if (identifiers.atomNameIsPrivate(s, atom_id))
                return s.failWithMessage(delete_position, private_field_delete);
            const snapshot = v2b.snapshot();
            errdefer v2b.rollback(snapshot);
            // qjs rewrites the getter into `push_atom_value` in place. The
            // replacement is one byte SHORTER than the W1 getter, so drop
            // the trailing `cache_idx` before appending `delete`.
            v2b.code[pos] = opcode.op.push_atom_value;
            v2b.code_len = pos + 5;
            try Emitter.op(s, opcode.op.delete);
        },
        opcode.op.get_array_el => {
            if (pos + 1 != v2b.code_len) return Error.ParserInvariant;
            const snapshot = v2b.snapshot();
            errdefer v2b.rollback(snapshot);
            try Emitter.op(s, opcode.op.delete);
            try compactAppendedTailReplacement(s, snapshot, pos);
        },
        opcode.op.get_length => {
            if (pos + 1 != v2b.code_len) return Error.ParserInvariant;
            const snapshot = v2b.snapshot();
            errdefer v2b.rollback(snapshot);
            try Emitter.opAtom(s, opcode.op.push_atom_value, atom_module.ids.length);
            try Emitter.op(s, opcode.op.delete);
            try compactAppendedTailReplacement(s, snapshot, pos);
        },
        opcode.op.scope_get_var => {
            if (pos + 7 != v2b.code_len or v2b.atom_len == 0) return Error.ParserInvariant;
            const name = std.mem.readInt(u32, v2b.code[pos + 1 ..][0..4], .little);
            if (v2b.atom_operands[v2b.atom_len - 1] != Atom.fromRaw(name)) return Error.ParserInvariant;
            if (name == atom_this.raw() or name == atom_new_target.raw()) {
                return emitDeleteNonReference(s);
            }
            if (s.isStrict())
                return s.failWithMessage(delete_position, "unqualified identifiers cannot be deleted in strict mode");
            v2b.code[pos] = opcode.op.scope_delete_var;
        },
        opcode.op.scope_get_private_field => return s.failWithMessage(delete_position, private_field_delete),
        opcode.op.get_super_value => {
            if (pos + 1 != v2b.code_len) return Error.ParserInvariant;
            const snapshot = v2b.snapshot();
            errdefer v2b.rollback(snapshot);
            try Emitter.opAtomU8(s, opcode.op.throw_error, atom_module.null_atom, 3);
            try compactAppendedTailReplacement(s, snapshot, pos);
        },
        else => return emitDeleteNonReference(s),
    }
}

/// v2 optional-delete bridge using the already-bound chain-exit LabelId.
/// No absolute PC enters the v2 stream: the exit bind is moved to the
/// cleanup pad, and the new join is born as a LabelId relocation.
fn rewriteOptionalChainDeleteBuilder(s: *State, pos: u32) Error!void {
    const v2b = s.activeBuilder();
    const field_form = v2b.code[pos] == opcode.op.get_field_opt_chain;
    // W1: `get_field_opt_chain` is `atom_cache_u8` (6 bytes).
    const getter_size: u32 = if (field_form) 6 else 1;
    if (pos + getter_size != v2b.code_len) return Error.ParserInvariant;
    const optional_label = try optionalChainExitAtEnd(s);

    if (field_form) {
        if (v2b.atom_len == 0) return Error.ParserInvariant;
        const atom_id = Atom.fromRaw(std.mem.readInt(u32, v2b.code[pos + 1 ..][0..4], .little));
        if (v2b.atom_operands[v2b.atom_len - 1] != atom_id) return Error.ParserInvariant;
    }

    const snapshot = v2b.snapshot();
    errdefer v2b.rollback(snapshot);
    if (field_form) {
        // qjs rewrites the pseudo getter into `push_atom_value` in place.
        // W1 made `get_field_opt_chain` one byte longer than that
        // replacement, so the rewrite has to happen BEFORE the tail is
        // appended -- every offset captured below (cleanup_offset, the
        // goto relocation, the bound label) must already be final.
        v2b.code[pos] = opcode.op.push_atom_value;
        v2b.code_len = pos + 5;
    }
    const next_label = try Emitter.newLabel(s);
    try Emitter.opNoSource(s, opcode.op.delete);
    try Emitter.jumpNoSource(s, opcode.op.goto, next_label);
    const cleanup_offset = v2b.code_len;
    try Emitter.opNoSource(s, opcode.op.drop);
    try Emitter.opNoSource(s, opcode.op.push_true);
    try Emitter.bindParser(s, next_label);

    if (field_form) {
        v2b.label_slots[optional_label.index()].bound_offset = cleanup_offset;
    } else {
        try compactAppendedTailReplacement(s, snapshot, pos);
        v2b.label_slots[optional_label.index()].bound_offset = cleanup_offset - getter_size;
    }
}

/// `js_parse_delete` OP_get_field_opt_chain / OP_get_array_el_opt_chain
/// handling: delete of an optional-chain
/// member access. qjs reads the chain label out of the `*_opt_chain`
/// opcode, truncates the access, emits `OP_delete`, then routes the
/// chain's short-circuit path through a `drop ; push_true` pad:
///
///     push_atom_value <prop> ; delete ; goto NEXT
///     OPT_CHAIN: drop ; push_true
///     NEXT:
///
/// The pseudo getter is immediately followed by the raw shared-label
/// marker, so delete consumes label identity directly without collecting
/// exits or recognising an emitted byte signature.
const CallReferenceKind = enum {
    plain,
    method,
    direct_eval,
};

const CallConsumerKind = enum {
    normal,
    template,
};

const PreparedCallReference = struct {
    kind: CallReferenceKind,
    optional_drop_count: u8,
};

/// qjs js_parse_postfix_expr: a call on a closed optional-chain reference
/// preserves the receiver (the getter at `pos` becomes `method_op`),
/// bypasses the undefined pad on the live path, and moves the shared chain
/// exit to that pad. v2 carries both targets as LabelIds instead of raw
/// OP_label bytes.
fn closedOptionalChainCall(s: *State, pos: usize, method_op: u8) Error!PreparedCallReference {
    const v2b = s.activeBuilder();
    const optional_label = try optionalChainExitAtEnd(s);
    const snapshot = v2b.snapshot();
    errdefer v2b.rollback(snapshot);
    const next_label = try Emitter.newLabel(s);
    try Emitter.jumpNoSource(s, opcode.op.goto, next_label);
    const cleanup_offset = v2b.code_len;
    try Emitter.opNoSource(s, opcode.op.undefined);
    try Emitter.bindParser(s, next_label);

    v2b.code[pos] = method_op;
    v2b.label_slots[optional_label.index()].bound_offset = cleanup_offset;
    return .{ .kind = .method, .optional_drop_count = 2 };
}

/// QuickJS call-site consumer (`js_parse_postfix_expr`): classify and
/// rewrite only the actual last opcode. Producers never choose a receiver
/// form by peeking at the following token.
fn prepareCallReference(
    s: *State,
    consumer: CallConsumerKind,
    has_optional_site: bool,
) Error!PreparedCallReference {
    const v2b = s.activeBuilder();
    const pos = v2b.last_opcode_pos orelse {
        // A chain closed on `?.#m` leaves no last opcode; the getter is the
        // private field read just before the chain exit.
        if (s.private_opt_chain_end == v2b.code_len and v2b.code_len >= 7 and
            v2b.code[v2b.code_len - 7] == opcode.op.scope_get_private_field)
        {
            return closedOptionalChainCall(s, v2b.code_len - 7, opcode.op.scope_get_private_field2);
        }
        return .{ .kind = .plain, .optional_drop_count = 1 };
    };
    if (pos >= v2b.code_len) return Error.ParserInvariant;

    switch (v2b.code[pos]) {
        opcode.op.get_field_opt_chain,
        opcode.op.get_array_el_opt_chain,
        => {
            const field_form = v2b.code[pos] == opcode.op.get_field_opt_chain;
            // W1: `get_field_opt_chain` is `atom_cache_u8` (6 bytes).
            const getter_size: u32 = if (field_form) 6 else 1;
            if (pos + getter_size != v2b.code_len) return Error.ParserInvariant;
            if (field_form) {
                if (v2b.atom_len == 0) return Error.ParserInvariant;
                const atom_id = Atom.fromRaw(std.mem.readInt(u32, v2b.code[pos + 1 ..][0..4], .little));
                if (v2b.atom_operands[v2b.atom_len - 1] != atom_id) return Error.ParserInvariant;
            }
            return closedOptionalChainCall(s, pos, if (field_form) opcode.op.get_field2 else opcode.op.get_array_el2);
        },
        opcode.op.get_field => {
            if (pos + 6 != v2b.code_len)
                return .{ .kind = .plain, .optional_drop_count = 1 };
            // qjs js_parse_postfix_expr: preserve receiver+callee for
            // method dispatch by rewriting the same-width getter.
            v2b.code[pos] = opcode.op.get_field2;
            return .{ .kind = .method, .optional_drop_count = 2 };
        },
        opcode.op.scope_get_private_field => {
            if (pos + 7 != v2b.code_len) return .{ .kind = .plain, .optional_drop_count = 1 };
            v2b.code[pos] = opcode.op.scope_get_private_field2;
            return .{ .kind = .method, .optional_drop_count = 2 };
        },
        opcode.op.get_array_el => {
            if (pos + 1 != v2b.code_len)
                return .{ .kind = .plain, .optional_drop_count = 1 };
            v2b.code[pos] = opcode.op.get_array_el2;
            return .{ .kind = .method, .optional_drop_count = 2 };
        },
        opcode.op.get_super_value => {
            if (pos + 1 != v2b.code_len)
                return .{ .kind = .plain, .optional_drop_count = 1 };
            // [this home key] -> [this this home key] -> [this value]: the
            // super reference's thisValue is also the Get receiver (§13.3.7.3),
            // not the home object (QuickJS's `get_array_el` rewrite).
            try v2b.truncateLastOpcodePreserveSources(pos);
            try Emitter.opNoSource(s, opcode.op.rot3l);
            try Emitter.opNoSource(s, opcode.op.insert3);
            try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.rot3r);
            try Emitter.op(s, opcode.op.get_super_value);
            return .{ .kind = .method, .optional_drop_count = 2 };
        },
        opcode.op.scope_get_var => {
            if (pos + 7 != v2b.code_len) return .{ .kind = .plain, .optional_drop_count = 1 };
            const name: Atom = Atom.fromRaw(std.mem.readInt(u32, v2b.code[pos + 1 ..][0..4], .little));
            const scope = std.mem.readInt(u16, v2b.code[pos + 5 ..][0..2], .little);
            if (consumer == .normal and !has_optional_site and name == atom_module.ids.eval_) {
                return .{ .kind = .direct_eval, .optional_drop_count = 1 };
            }
            if (hasWithScopeFrom(s.curFunc(), scope)) {
                // scope_get_ref pushes [this, func]: an optional-call
                // short-circuit drops both.
                v2b.code[pos] = opcode.op.scope_get_ref;
                return .{ .kind = .method, .optional_drop_count = 2 };
            }
        },
        else => {},
    }
    return .{ .kind = .plain, .optional_drop_count = 1 };
}

fn emitPreparedCall(
    s: *State,
    prepared: PreparedCallReference,
    shape: CallArgsShape,
    line_num: u32,
    col_num: u32,
) Error!void {
    const snapshot = s.activeBuilder().snapshot();
    errdefer s.activeBuilder().rollback(snapshot);
    // qjs call emission pins one source event to the callee and emits
    // the selected call/apply tail without further markers
    try Emitter.addSourceMarker(s, line_num, col_num);
    switch (shape) {
        .direct => |argc| switch (prepared.kind) {
            .plain => try Emitter.callOp(s, opcode.op.call, argc),
            .method => try Emitter.callOp(s, opcode.op.call_method, argc),
            .direct_eval => {
                const eval_scope: u16 = @intCast(s.scope_level);
                try Emitter.opU32NoSource(s, opcode.op.eval, @as(u32, argc) | (@as(u32, eval_scope) << 16));
            },
        },
        .applied => switch (prepared.kind) {
            .plain => {
                try Emitter.opNoSource(s, opcode.op.undefined);
                try Emitter.opNoSource(s, opcode.op.swap);
                try Emitter.opU16NoSource(s, opcode.op.apply, 0);
            },
            .method => {
                try Emitter.opNoSource(s, opcode.op.perm3);
                try Emitter.opU16NoSource(s, opcode.op.apply, 0);
            },
            .direct_eval => {
                const eval_scope: u16 = @intCast(s.scope_level);
                try Emitter.opU16NoSource(s, opcode.op.apply_eval, eval_scope);
            },
        },
    }
    if (prepared.kind == .direct_eval) try s.markDirectEvalCall();
}

/// `js_parse_postfix_expr`. Wraps `parseLhsExpr`
/// with the postfix `++` / `--` update operators.
pub fn parsePostfixExpr(s: *State, flags: ParseFlags) Error!void {
    try parseLhsExpr(s, flags);

    const k = s.peekKind();
    if (k != .inc and k != .dec) return;
    // ASI: per QuickJS, a postfix `++` / `--` after
    // a LineTerminator is forbidden. The lexer's `got_lf` flag tracks that.
    if (s.lex.got_lf) return;

    var lvalue = try getLValue(s, true);
    const operator_source = s.currentSourcePosition();
    const update_op: u8 = if (k == .inc) opcode.op.post_inc else opcode.op.post_dec;
    try s.advance(); // consume `++` or `--`

    if (lvalue.invalid_call) {
        try emitInvalidAssignmentTarget(s);
        return;
    }
    // qjs js_parse_unary postfix arm: postfix
    // update is pinned to the operator's source event.
    try Emitter.opAt(s, update_op, operator_source.line_num, operator_source.col_num);
    try putLValue(s, &lvalue, .keep_second);
}

/// `js_parse_left_hand_side_expr`. Primary
/// expression followed by zero or more member accesses (`.x`, `[x]`),
/// function calls (`(...)`), and `new` constructions.
///
/// Each `?.` access emits QuickJS's inline `optional_chain_test` and
/// branches to one shared parser label. The chain closes with a raw label
/// marker, so call/delete consume its identity from the real last getter;
/// no per-exit buffer or byte-signature recovery is involved.
pub fn parseLhsExpr(s: *State, flags: ParseFlags) Error!void {
    const starts_with_template = s.peekKind() == .template;
    if (s.peekKind() == .kw_new) {
        try parseNewExpr(s, flags);
    } else {
        try parsePrimary(s);
    }
    const primary_end = s.activeBuilder().last_opcode_pos;
    const was_super = s.last_was_super;
    var optional_chain_label: ?OptionalChainLabel = null;
    try parseMemberChain(s, &optional_chain_label);
    const bare_template = starts_with_template and s.activeBuilder().last_opcode_pos == primary_end;
    s.template_concat_call_pos = if (bare_template) primary_end else null;
    if (optional_chain_label) |label| {
        // v2 chain close: no in-stream raw label marker — the bind slot
        // carries the position; the pseudo getter rewrite is identical.
        // resolve_labels later lowers *_opt_chain exactly like phase 2.
        const v2b = s.activeBuilder();
        const getter_end = v2b.code_len;
        try Emitter.bindParserRaw(s, label);
        if (v2b.last_opcode_pos) |last_pos| {
            const pos: usize = last_pos;
            if (pos + 6 == getter_end and v2b.code[pos] == opcode.op.get_field) {
                v2b.code[pos] = opcode.op.get_field_opt_chain;
            } else if (pos + 1 == getter_end and v2b.code[pos] == opcode.op.get_array_el) {
                v2b.code[pos] = opcode.op.get_array_el_opt_chain;
            } else {
                if (v2b.code[pos] == opcode.op.scope_get_private_field) s.private_opt_chain_end = getter_end;
                v2b.invalidateLastOpcode();
            }
        }
    }
    // Handle super() constructor calls after member chain.
    if (was_super and optional_chain_label == null and s.peekKind() == .lparen) {
        if (!s.ctx.allow_super_call) return s.failUnexpectedToken();
        const call_source = SourceLoc{ .line = s.token.line_num, .col = s.token.col_num };
        const super_locals = superCallLocals(s) orelse {
            try parseCapturedSuperConstructorCall(s, call_source);
            s.last_was_super = false;
            return;
        };
        try discardTrailingGetSuper(s);
        try Emitter.opU16(s, opcode.op.get_loc, super_locals.active_func);
        try Emitter.op(s, opcode.op.get_super);
        try Emitter.opU16(s, opcode.op.get_loc, super_locals.new_target);
        const shape = try parseCallArgs(s);
        switch (shape) {
            .direct => |argc| try Emitter.opU16At(s, opcode.op.call_constructor, argc, call_source.line, call_source.col),
            .applied => try Emitter.opU16At(s, opcode.op.apply, 1, call_source.line, call_source.col),
        }
        try Emitter.op(s, opcode.op.dup);
        try Emitter.opU16(s, opcode.op.put_loc_check_init, super_locals.this);
        try emitClassFieldInitCall(s);
        if (s.ctx.in_constructor and s.class.has_extends) {
            if (s.current_parameter_properties) |props| {
                for (props.items) |prop_atom| {
                    try s.emitThisValue();
                    try s.emitScopeGetVar(prop_atom);
                    try Emitter.opAtom(s, opcode.op.put_field, prop_atom);
                }
            }
        }
        s.last_was_super = false;
    }
}

/// The name after `.` or `?.`: an identifier, a private name or any
/// keyword (`a.delete`, `a.#x`).
fn memberNameAtom(s: *State) ?Atom {
    const kind = s.peekKind();
    if (kind == .ident or kind == .private_name) return s.token.payload.ident.atom;
    if (kind.isKeyword()) return kind.keywordAtom();
    return null;
}

const SourceLoc = struct {
    line: u32,
    col: u32,
};

/// The three hidden locals a direct `super(...)` in a constructor needs,
/// or null when this function has not materialized them (an arrow or a
/// nested function captures them instead).
const SuperCallLocals = struct { active_func: u16, new_target: u16, this: u16 };

fn superCallLocals(s: *State) ?SuperCallLocals {
    const fd = s.curFunc();
    return .{
        .active_func = fd.this_active_func_var_idx orelse return null,
        .new_target = fd.new_target_var_idx orelse return null,
        .this = fd.this_var_idx orelse return null,
    };
}

fn parseCapturedSuperConstructorCall(s: *State, loc: ?SourceLoc) Error!void {
    try discardTrailingGetSuper(s);

    try s.emitScopeGetVar(atom_this_active_func);
    try Emitter.op(s, opcode.op.get_super);
    try s.emitScopeGetVar(atom_new_target);
    const shape = try parseCallArgs(s);
    switch (shape) {
        .direct => |argc| {
            if (loc) |source_loc| {
                try Emitter.opU16At(s, opcode.op.call_constructor, argc, source_loc.line, source_loc.col);
            } else {
                try Emitter.opU16(s, opcode.op.call_constructor, argc);
            }
        },
        .applied => {
            if (loc) |source_loc| {
                try Emitter.opU16At(s, opcode.op.apply, 1, source_loc.line, source_loc.col);
            } else {
                try Emitter.opU16(s, opcode.op.apply, 1);
            }
        },
    }
    try Emitter.op(s, opcode.op.dup);
    try s.emitScopePutVarInit(atom_this);
    try emitClassFieldInitCall(s);
    if (s.ctx.in_constructor and s.class.has_extends) {
        if (s.current_parameter_properties) |props| {
            for (props.items) |prop_atom| {
                try s.emitScopeGetVar(atom_this);
                try s.emitScopeGetVar(prop_atom);
                try Emitter.opAtom(s, opcode.op.put_field, prop_atom);
            }
        }
    }
}

/// Initialize the current class's instance elements from the lexical
/// `<class_fields_init>` closure. Both names stay as phase-1 scope
/// operands so a direct constructor uses locals while an arrow containing
/// `super()` receives the ordinary threaded captures.
pub fn emitClassFieldInitCall(s: *State) Error!void {
    try s.emitScopeGetVar(s.ctx.super_fields_init);
    // qjs emit_class_field_init: the skip
    // target is born as a label bound at the shared drop.
    try Emitter.op(s, opcode.op.dup);
    const skip_call = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.if_false, skip_call);
    try s.emitScopeGetVar(atom_this);
    try Emitter.op(s, opcode.op.swap);
    try Emitter.callOp(s, opcode.op.call_method, 0);
    try Emitter.bind(s, skip_call);
    try Emitter.op(s, opcode.op.drop);
}

fn parseNewExpr(s: *State, flags: ParseFlags) Error!void {
    try s.advance(); // consume 'new'
    if (s.peekKind() == .dot) {
        try s.advance();
        if (s.peekKind() != .ident or
            s.token.payload.ident.has_escape or
            s.token.payload.ident.atom != atom_module.ids.target)
        {
            return s.failUnexpectedToken();
        }
        if (!s.ctx.new_target_allowed) return s.failUnexpectedToken();
        try s.advance();
        try s.emitScopeGetVar(atom_new_target);
        return;
    }
    if (s.peekKind() == .kw_new) {
        try parseNewExpr(s, flags);
        // The member tail following the inner NewExpression binds to the
        // inner `new`'s result: `new new F().m` is `new ((new F()).m)`.
        // qjs gets this from the recursive `js_parse_postfix_expr(s, 0)`
        // whose postfix loop consumes `.x`/`[x]`
        // before the outer `new` applies.
        try parseNewCalleeMemberAccess(s);
    } else if (s.peekKind() == .kw_import) {
        const following = try lookahead.peekNextDiagnosticToken(s);
        if (following.kind != .dot) {
            return s.failExpectedDescriptionAt("'.'", following.kind, following.position);
        }
        try parsePrimary(s);
        try parseNewCalleeMemberAccess(s);
    } else {
        try parsePrimary(s);
        try parseNewCalleeMemberAccess(s);
    }
    // TypeScript `new C<T>(...)`.
    if (s.typescript and typescript.tsAtLess(s)) _ = try typescript.tsTryParseTypeArgumentsInExpression(s);
    // An OptionalChain cannot follow an argument-less NewExpression.
    if (s.peekKind() == .question_mark_dot) return s.failWithMessage(null, "optional chain is not allowed after 'new' without arguments");
    if (s.peekKind() == .lparen) {
        const call_line = s.token.line_num;
        const call_col = s.token.col_num;
        try Emitter.op(s, opcode.op.dup);
        const shape = try parseCallArgs(s);
        switch (shape) {
            .direct => |argc| try Emitter.opU16At(s, opcode.op.call_constructor, argc, call_line, call_col),
            .applied => {
                // `new X(...args)`. Stack here: [func, func(dup =
                // new.target), array]. QuickJS FUNC_CALL_NEW emits
                // `perm3; apply 1` (`quickjs.c`,
                // "obj func array -> func obj array") so apply consumes
                // the dup'd callee as the new.target slot.
                try Emitter.op(s, opcode.op.perm3);
                try Emitter.opU16At(s, opcode.op.apply, 1, call_line, call_col);
            },
        }
    } else {
        // `new X` (no args) is equivalent to `new X()`.
        const call_line = s.token.line_num;
        const call_col = s.token.col_num;
        // qjs's no-parentheses arm emits one source event before both
        // `dup` and `call_constructor`.
        try emitter.emitGrammarSource(s, .{ .line_num = call_line, .col_num = call_col });
        try Emitter.op(s, opcode.op.dup);
        try Emitter.opU16(s, opcode.op.call_constructor, 0);
    }
}

fn parseNewCalleeMemberAccess(s: *State) Error!void {
    while (true) {
        const k = s.peekKind();
        // `new super.x()` / `new super[k]()`: a SuperProperty callee. A bare
        // `super` cannot be constructed.
        const was_super = s.last_was_super;
        if (was_super) {
            if (k != .dot and k != .lbracket) return s.failUnexpectedToken();
            s.last_was_super = false;
            try discardTrailingGetSuper(s);
            try emitSuperThisAndHomeObject(s);
            try Emitter.op(s, opcode.op.get_super);
        }
        if (k == .dot) {
            const access_source = s.currentSourcePosition();
            try s.advance();
            const private_name = s.peekKind() == .private_name;
            if (was_super and private_name) return s.failUnexpectedToken();
            const raw_name = memberNameAtom(s) orelse return s.failUnexpectedToken();
            if (private_name and !s.class.in_body) return s.failUnexpectedToken();
            const private_atom = if (private_name) try classes.privateNameAtom(s, raw_name) else null;
            if (private_atom) |atom_id| {
                if (!classes.classPrivateNameIsBound(s, atom_id)) return s.failUnexpectedToken();
            }
            const name = private_atom orelse raw_name;
            try emitter.emitGrammarSource(s, access_source);
            // qjs emits the operand while the property token still owns
            // its atom, then next_token releases that token. Keep the
            // same one-retain path instead of pinning a second temporary
            // atom across advance.
            if (was_super) {
                try Emitter.opAtom(s, opcode.op.push_atom_value, name);
                try Emitter.op(s, opcode.op.get_super_value);
            } else if (private_name) {
                try Emitter.opAtomU16(s, opcode.op.scope_get_private_field, name, @intCast(s.scope_level));
            } else {
                try Emitter.opAtom(s, opcode.op.get_field, name);
            }
            try s.advance();
        } else if (k == .lbracket) {
            const access_source = s.currentSourcePosition();
            try s.advance();
            try parseExpr(s);
            try s.expectToken(.rbracket);
            try emitter.emitGrammarSource(s, access_source);
            try Emitter.op(s, if (was_super) opcode.op.get_super_value else opcode.op.get_array_el);
        } else if (k == .template) {
            try parseTaggedTemplateInvocation(s);
        } else if (k == .bang and s.typescript and !was_super and !s.gotLineTerminator()) {
            // TypeScript non-null assertion `new K!<T>()` erases to `new K<T>()`.
            try s.advance();
        } else {
            return;
        }
    }
}

fn parseMemberChain(s: *State, optional_chain_label: *?OptionalChainLabel) Error!void {
    while (true) {
        const k = s.peekKind();
        if (k == .dot) {
            const access_source = s.currentSourcePosition();
            try s.advance();
            const private_name = s.peekKind() == .private_name;
            const raw_name = memberNameAtom(s) orelse return s.failUnexpectedToken();
            if (private_name and !s.class.in_body) return s.failUnexpectedToken();
            const private_atom = if (private_name) try classes.privateNameAtom(s, raw_name) else null;
            if (private_atom) |atom_id| {
                if (s.last_was_super or !classes.classPrivateNameIsBound(s, atom_id)) return s.failUnexpectedToken();
            }
            const name = private_atom orelse raw_name;
            const was_super = s.last_was_super;
            s.last_was_super = false;
            if (was_super) {
                try discardTrailingGetSuper(s);
                try emitSuperThisAndHomeObject(s);
                try Emitter.op(s, opcode.op.get_super);
                try emitter.emitGrammarSource(s, access_source);
                try Emitter.opAtom(s, opcode.op.push_atom_value, name);
                try Emitter.op(s, opcode.op.get_super_value);
            } else if (private_name) {
                try emitter.emitGrammarSource(s, access_source);
                try Emitter.opAtomU16(s, opcode.op.scope_get_private_field, name, @intCast(s.scope_level));
            } else {
                try emitter.emitGrammarSource(s, access_source);
                try Emitter.opAtom(s, opcode.op.get_field, name);
            }
            // qjs parse_property emits from s->token.u.ident.atom before
            // next_token owns the release; no parser-local retain exists.
            try s.advance();
        } else if (k == .question_mark_dot) {
            if (s.last_was_super) return s.failUnexpectedToken();
            const optional_source = s.currentSourcePosition();
            try s.advance();
            if (typescript.tsAtLess(s)) {
                // TypeScript `a?.<T>(...)`.
                if (!(try typescript.tsTryParseTypeArgumentsInExpression(s))) return s.failUnexpectedToken();
            }
            const next = s.peekKind();
            if (next == .lparen) {
                const call_line = s.token.line_num;
                const call_col = s.token.col_num;
                const prepared = try prepareCallReference(s, .normal, true);
                try emitOptionalChainTest(s, optional_chain_label, prepared.optional_drop_count);
                const shape = try parseCallArgs(s);
                try emitPreparedCall(s, prepared, shape, call_line, call_col);
            } else if (next == .lbracket) {
                try emitOptionalChainTest(s, optional_chain_label, 1);
                try s.advance();
                try parseExpr(s);
                try s.expectToken(.rbracket);
                try emitter.emitGrammarSource(s, optional_source);
                try Emitter.op(s, opcode.op.get_array_el);
            } else if (memberNameAtom(s)) |raw_name| {
                // qjs parse_property emits the `?.` source before the
                // optional-chain test and the selected getter.
                try emitter.emitGrammarSource(s, optional_source);
                try emitOptionalChainTest(s, optional_chain_label, 1);
                const private_name = next == .private_name;
                if (private_name and !s.class.in_body) return s.failUnexpectedToken();
                const private_atom = if (private_name) try classes.privateNameAtom(s, raw_name) else null;
                if (private_atom) |atom_id| {
                    if (!classes.classPrivateNameIsBound(s, atom_id)) return s.failUnexpectedToken();
                }
                const name = private_atom orelse raw_name;
                if (private_name) {
                    try Emitter.opAtomU16(s, opcode.op.scope_get_private_field, name, @intCast(s.scope_level));
                } else {
                    try Emitter.opAtom(s, opcode.op.get_field, name);
                }
                try s.advance();
            } else {
                return s.failUnexpectedToken();
            }
        } else if (k == .lbracket) {
            const access_source = s.currentSourcePosition();
            const was_super = s.last_was_super;
            s.last_was_super = false;
            try s.advance();
            if (was_super) {
                try discardTrailingGetSuper(s);
                try emitSuperThisAndHomeObject(s);
                try Emitter.op(s, opcode.op.get_super);
            }
            try parseExpr(s);
            try s.expectToken(.rbracket);
            try emitter.emitGrammarSource(s, access_source);
            if (was_super) {
                try Emitter.op(s, opcode.op.get_super_value);
            } else {
                try Emitter.op(s, opcode.op.get_array_el);
            }
        } else if (k == .lparen) {
            const callee_line = s.token.line_num;
            const callee_col = s.token.col_num;
            const was_super = s.last_was_super;
            s.last_was_super = false;
            if (was_super and !s.ctx.allow_super_call) return s.failUnexpectedToken();
            if (was_super) {
                const super_locals = superCallLocals(s) orelse {
                    try parseCapturedSuperConstructorCall(s, .{ .line = callee_line, .col = callee_col });
                    continue;
                };
                try discardTrailingGetSuper(s);
                try Emitter.opU16(s, opcode.op.get_loc, super_locals.active_func);
                try Emitter.op(s, opcode.op.get_super);
                try Emitter.opU16(s, opcode.op.get_loc, super_locals.new_target);
                const shape = try parseCallArgs(s);
                switch (shape) {
                    .direct => |argc| try Emitter.opU16At(s, opcode.op.call_constructor, argc, callee_line, callee_col),
                    .applied => try Emitter.opU16At(s, opcode.op.apply, 1, callee_line, callee_col),
                }
                try Emitter.op(s, opcode.op.dup);
                try Emitter.opU16(s, opcode.op.put_loc_check_init, super_locals.this);
                try emitClassFieldInitCall(s);
                continue;
            }
            const prepared = try prepareCallReference(s, .normal, false);
            const shape = try parseCallArgs(s);
            try emitPreparedCall(s, prepared, shape, callee_line, callee_col);
        } else if (k == .template) {
            if (optional_chain_label.* != null) return s.failUnexpectedToken();
            try parseTaggedTemplateInvocation(s);
        } else if (k == .bang and s.typescript and !s.gotLineTerminator()) {
            // TypeScript non-null assertion `x!` erases to `x`.
            if (s.last_was_super) return s.failUnexpectedToken();
            try s.advance();
        } else if ((k == .lt or k == .shl) and s.typescript and !s.last_was_super) {
            // TypeScript `f<T>(...)`, `f<T>\`...\``, or `f<T>`.
            if (!(try typescript.tsTryParseTypeArgumentsInExpression(s))) break;
        } else {
            break;
        }
    }
}

fn parseTaggedTemplateInvocation(s: *State) Error!void {
    const call_line = s.token.line_num;
    const call_col = s.token.col_num;
    const prepared = try prepareCallReference(s, .template, false);

    const first_part = s.token.payload.str.template orelse return s.failUnexpectedToken();
    if (first_part == .no_substitution) {
        if (s.runtime) |rt| {
            var builder = try TaggedTemplateObjectBuilder.init(rt, templateArrayPrototype(s, rt));
            try builder.addPart(s.token.payload.str.bytes, s.token.payload.str.raw_bytes, s.token.payload.str.cooked_invalid);
            try builder.finish();
            try Emitter.pushConst(s, builder.template_value);
        } else {
            try emitTaggedTemplateSingletonObject(s, s.token.payload.str.bytes, s.token.payload.str.raw_bytes);
        }
        try s.advance();
        try emitPreparedCall(s, prepared, .{ .direct = 1 }, call_line, call_col);
        // A tagged template is a CallExpression TemplateLiteral, not a
        // bare CallExpression assignment target. Keep the emitted call
        // from being mistaken for the latter by getLValue; a subsequent
        // member/call suffix will publish its own final opcode.
        s.invalidateLastOpcode();
        return;
    }

    var template_builder = if (s.runtime) |rt| try TaggedTemplateObjectBuilder.init(rt, templateArrayPrototype(s, rt)) else null;
    if (template_builder) |*builder| {
        try Emitter.pushConst(s, builder.template_value);
    } else {
        try Emitter.op(s, opcode.op.undefined); // parser-only fallback placeholder
    }
    var argc: u16 = 1; // template object counts as the first arg
    while (true) {
        const part = s.token.payload.str.template orelse return s.failUnexpectedToken();
        if (template_builder) |*builder| {
            try builder.addPart(s.token.payload.str.bytes, s.token.payload.str.raw_bytes, s.token.payload.str.cooked_invalid);
        }
        if (part == .no_substitution or part == .tail) {
            try s.advance();
            break;
        }
        try s.advance();
        try parseExpr(s);
        argc += 1;
        if (s.peekKind() != .rbrace) return s.failExpectedToken(.rbrace);
        s.lex.freeToken(&s.token);
        try s.lex.nextTemplatePartAfterBraceInto(&s.token);
    }
    if (template_builder) |*builder| try builder.finish();
    try emitPreparedCall(s, prepared, .{ .direct = argc }, call_line, call_col);
    s.invalidateLastOpcode();
}

/// Result of parsing a `(...)` argument list. When the list contains a
/// spread (`...x`), QuickJS switches to an `apply`-based lowering that
/// builds an args array on the stack; the caller-side dispatch differs
/// for normal call / method call / `new` / `super(...)`.
const CallArgsShape = union(enum) {
    /// No spread. Stack contract: argc args on top of stack; caller
    /// emits `call`/`call_method`/`call_constructor` with this argc.
    direct: u16,
    /// One or more spreads. The args array is now on top of the stack
    /// (above whatever was there: func / obj+func / etc.). Caller is
    /// responsible for the final `apply <is_new>` opcode and any
    /// stack-rearrange (`undefined ; swap` for plain calls;
    /// `perm3` for method calls / `new`). Mirrors `quickjs.c`.
    applied,
};

/// Emit the QuickJS `optional_chain_test` sequence:
///
///     dup
///     is_undefined_or_null
///     if_false NEXT          ; if NOT null/undef, skip to NEXT
///     drop * drop_count       ; remove the dup'd receiver (and any
///                              ;   companion stack entries)
///     undefined               ; chain result on null/undef
///     goto CHAIN_EXIT         ; jump to chain end (patched later)
///     NEXT:                   ; resume normal access here
///
/// The CHAIN_EXIT goto offset is recorded so `parseLhsExpr` can patch
/// it to the post-chain byte. `drop_count` is 1 for member access
/// (`?.b` / `?.[k]`) and 2 for method call after a member dup
/// (`obj?.b()` / `?.()`); slice 7 only handles the member-access cases.
fn emitOptionalChainTest(
    s: *State,
    optional_chain_label: *?OptionalChainLabel,
    drop_count: u8,
) Error!void {
    // qjs optional_chain_test, labels born as LabelIds.
    const v2b = s.activeBuilder();
    const snap = v2b.snapshot();
    const old_label = optional_chain_label.*;
    errdefer {
        v2b.rollback(snap);
        optional_chain_label.* = old_label;
    }
    if (optional_chain_label.* == null)
        optional_chain_label.* = try Emitter.newLabel(s);
    try Emitter.op(s, opcode.op.dup);
    try Emitter.op(s, opcode.op.is_undefined_or_null);
    const next_label = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.if_false, next_label);
    var i: u8 = 0;
    while (i < drop_count) : (i += 1) {
        try Emitter.op(s, opcode.op.drop);
    }
    try Emitter.op(s, opcode.op.undefined);
    try Emitter.jumpNoSource(s, opcode.op.goto, optional_chain_label.*.?);
    try Emitter.bind(s, next_label);
}

/// Parse a `(arg0, arg1, ...)` argument list and return the call shape.
/// Caller consumed nothing yet — this consumes the leading `(` and the
/// matching `)`.
fn parseCallArgs(s: *State) Error!CallArgsShape {
    try s.expectToken(.lparen);
    // Call arguments always parse with `PF_IN_ACCEPTED`
    // (`js_parse_assign_expr`, quickjs.c) — argument
    // positions reset the for-init no-`in` restriction.
    const arg_flags = ParseFlags.default;
    var argc: u16 = 0;
    var has_spread = false;
    while (s.peekKind() != .rparen) {
        if (s.peekKind() == .ellipsis) {
            has_spread = true;
            break;
        }
        try parseAssignExpr2(s, arg_flags);
        argc = std.math.add(u16, argc, 1) catch return s.failWithMessage(null, "Too many call arguments");
        if (s.peekKind() == .comma) {
            try s.advance();
            continue;
        }
        break;
    }
    if (!has_spread) {
        try s.expectToken(.rparen);
        return .{ .direct = argc };
    }
    s.features.insert(.spread_rest);
    // Spread path mirrors `quickjs.c`. The leading args
    // become an array, then each remaining arg is appended (via the
    // iterator protocol for spread, via define_array_el+inc otherwise).
    try Emitter.opU16(s, opcode.op.array_from, argc);
    try Emitter.opI32(s, opcode.op.push_i32, @intCast(argc));
    while (s.peekKind() != .rparen) {
        if (s.peekKind() == .ellipsis) {
            try s.advance();
            try parseAssignExpr2(s, arg_flags);
            try Emitter.op(s, opcode.op.append);
        } else {
            try parseAssignExpr2(s, arg_flags);
            try Emitter.op(s, opcode.op.define_array_el);
            try Emitter.op(s, opcode.op.inc);
        }
        if (s.peekKind() == .comma) {
            try s.advance();
            continue;
        }
        break;
    }
    try s.expectToken(.rparen);
    try Emitter.op(s, opcode.op.drop); // drop the index, leave array on stack
    return .applied;
}

fn parseRegExpLiteral(s: *State) Error!void {
    s.lex.freeToken(&s.token);
    try s.lex.rescanLastSlashAsRegexpInto(&s.token);
    const pattern = s.token.payload.regexp.pattern;
    const flags = s.token.payload.regexp.flags;

    // QuickJS publishes the source pattern as the first constant-pool
    // operand before compiling the regexp. Keep the raw source spelling,
    // but decode its UTF-8 bytes into the runtime's Latin-1/UTF-16 string
    // representation instead of interning it as an atom.
    const pattern_string = core.string.String.createUtf8(s.runtime.?, pattern) catch |err| switch (err) {
        error.OutOfMemory, error.StringTooLong => return Error.OutOfMemory,
        error.InvalidUtf8 => return Error.InvalidUtf8,
    };
    try Emitter.pushConst(s, pattern_string.value());

    var compiled = regexp_lib.compilePatternAndFlagsWithOptions(s.scratch, pattern, flags, .{
        .host = core.regexp.libraryHost(s.runtime.?),
    }) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        // qjs:libregexp.c re_parse_error "stack overflow" -> JS_ThrowSyntaxError
        error.StackOverflow => return Error.StackOverflow,
        else => return Error.InvalidRegExp,
    };
    defer compiled.deinit(s.scratch);
    // qjs compiles a literal once while parsing, stores the lre bytecode as
    // an 8-bit JSString constant, and lets OP_regexp share that immutable
    // string with each fresh RegExp instance (quickjs.c).
    // ZJS used to discard this validation result and emit the
    // flags string, forcing the runtime constructor to compile on every
    // literal evaluation.
    const compiled_string = core.string.String.createLatin1(s.runtime.?, compiled.bytecode) catch |err| switch (err) {
        error.OutOfMemory, error.StringTooLong => return Error.OutOfMemory,
    };
    try Emitter.pushConst(s, compiled_string.value());
    try Emitter.op(s, opcode.op.regexp);
    try s.advance();
}

/// Parse a primary expression. `js_parse_primary_expr` lives inside
/// `js_parse_postfix_expr` in QuickJS.
fn parsePrimary(s: *State) Error!void {
    // The nesting arms stay in this small frame; the leaf arms live in
    // `parsePrimaryLeaf`, whose inlined helpers would otherwise widen every
    // level of a deeply nested literal or parenthesization.
    switch (s.peekKind()) {
        .lparen => {
            try s.advance();
            // Parenthesized group: mirrors `js_parse_expr_paren`
            // -> `js_parse_expr` which parses
            // with `PF_IN_ACCEPTED` set — grouping resets the
            // for-init no-`in` restriction (and unary-context
            // restrictions like the yield guard).
            try parseExpr2(s, ParseFlags.default);
            try s.expectToken(.rparen);
        },
        .lbracket => return parseArrayLiteral(s),
        .lbrace => return parseObjectLiteral(s),
        else => return parsePrimaryLeaf(s),
    }
}

noinline fn parsePrimaryLeaf(s: *State) Error!void {
    switch (s.peekKind()) {
        .number => {
            const value = s.token.payload.num.value;
            // Encode small integers with push_i32 to match QuickJS.
            if (s.token.payload.num.is_bigint) {
                try s.emitBigIntLiteral(s.token.payload.num.bigint_text, false);
            } else if (identifiers.numberIsExactI32(value)) {
                try Emitter.opI32(s, opcode.op.push_i32, @as(i32, @intFromFloat(value)));
            } else {
                try Emitter.pushConst(s, JSValue.float64(value));
            }
            try s.advance();
        },
        .string => {
            // QuickJS emits `OP_push_atom_value <atom>` here, including
            // for the empty string. resolve_labels selects the short
            // push_empty_string form only when the value stays live.
            try emitter.emitStringLiteralValue(s, s.token.payload.str.bytes);
            try s.advance();
        },
        .slash, .div_assign => try parseRegExpLiteral(s),
        .template => return parseTemplate(s),
        .kw_true => {
            try Emitter.op(s, opcode.op.push_true);
            try s.advance();
        },
        .kw_false => {
            try Emitter.op(s, opcode.op.push_false);
            try s.advance();
        },
        .kw_null => {
            try Emitter.op(s, opcode.op.null);
            try s.advance();
        },
        .kw_this => {
            try s.emitThisValue();
            try s.advance();
            s.last_was_super = false;
        },
        .kw_super => {
            if (!s.ctx.allow_super) return s.failUnexpectedToken();
            // Emit get_super; runtime semantics depend on constructor context.
            try Emitter.op(s, opcode.op.get_super);
            try s.advance();
            // `super` exists only as SuperCall / SuperProperty (§13.3).
            switch (s.peekKind()) {
                .lparen, .dot, .lbracket => {},
                else => return s.failUnexpectedToken(),
            }
            s.last_was_super = true;
        },
        .kw_import => {
            if (try s.peekNextKind() == .dot) {
                if (!s.lex.is_module or s.is_eval) return s.failUnexpectedToken();
                try s.advance();
                try s.advance();
                if (s.peekKind() != .ident or
                    s.token.payload.ident.has_escape or
                    !identifiers.atomNameEquals(s, s.token.payload.ident.atom, "meta"))
                {
                    return s.failUnexpectedToken();
                }
                try s.advance();
                // qjs import.meta lowering publishes the module's
                // special object at the import expression source.
                try Emitter.opU8(s, opcode.op.special_object, opcode.special_object_subtype.import_meta);
                s.last_was_super = false;
                return;
            }
            try parseDynamicImportCall(s);
            s.last_was_super = false;
        },
        .kw_class => {
            // Class expression
            _ = try classes.parseClass(s, false);
        },
        .kw_function => {
            // Plain function expression. `async function` never reaches this
            // arm: the `async` keyword is a TOK_IDENT, so it is dispatched by
            // the identifier arm below.
            const source_start = s.currentFunctionSourceStart();
            try functions.parseFunctionExpr(s, .normal, source_start);
        },
        .ident,
        .kw_await,
        .kw_yield,
        .kw_static,
        .kw_implements,
        .kw_interface,
        .kw_package,
        .kw_private,
        .kw_protected,
        .kw_public,
        => {
            if (!identifiers.isIdentifierLikeToken(s)) return s.failUnexpectedToken();
            if (s.peekKind() == .kw_await and !identifiers.canUseAwaitAsIdentifier(s)) return Error.AwaitOutsideAsyncFunction;
            if (s.peekKind() == .kw_yield and (s.ctx.in_generator or s.isStrict())) return Error.YieldOutsideGenerator;
            if (s.peekKind() == .ident and
                identifiers.escapedIdentifierIsReservedWordForCurrentContext(s, s.token.payload.ident.atom, s.token.payload.ident.has_escape))
            {
                return s.failUnexpectedToken();
            }
            if (s.peekKind() == .ident and
                s.token.payload.ident.has_escape and
                identifiers.atomNameEquals(s, s.token.payload.ident.atom, "import"))
            {
                switch (try s.peekNextKind()) {
                    .lparen, .dot => return s.failUnexpectedToken(),
                    else => {},
                }
            }
            const is_async_identifier = s.isAsyncIdentifier();
            if (is_async_identifier) {
                // Check for async function (async is a contextual keyword)
                if ((try s.peekNext()).isBefore(.kw_function)) {
                    const source_start = s.currentFunctionSourceStart();
                    try s.advance(); // consume async
                    const func_kind: ParseFunctionKind = .async;
                    try functions.parseFunctionExpr(s, func_kind, source_start);
                    s.last_was_super = false;
                    return;
                }
            }
            const ident = identifiers.identifierLikeAtom(s);
            if (ident == atom_module.ids.arguments and identifiers.argumentsIdentifierIsForbidden(s)) {
                return s.failWithMessage(null, "'arguments' is not allowed in class field initializer or static initialization block");
            }
            // Identifier production is independent of its consumer.
            // Assignment and call sites rewrite this exact last opcode
            // after the complete operand has been parsed.
            try emitter.emitGrammarSource(s, s.currentSourcePosition());
            try typescript.emitIdentifierReference(s, ident);
            try s.advance();
            s.last_was_super = false;
        },
        .kw_let => {
            if (s.isStrict()) return s.failUnexpectedToken();
            try emitter.emitGrammarSource(s, s.currentSourcePosition());
            try s.emitScopeGetVar(tok.Kind.kw_let.keywordAtom());
            try s.advance();
            s.last_was_super = false;
        },
        else => return s.failUnexpectedToken(),
    }
}

fn parseDynamicImportCall(s: *State) Error!void {
    s.features.insert(.dynamic_import);
    try s.advance();
    try s.expectToken(.lparen);
    const import_flags = ParseFlags.default;
    try parseAssignExpr2(s, import_flags);
    if (s.peekKind() == .comma) {
        try s.advance();
        if (s.peekKind() == .rparen) {
            try Emitter.op(s, opcode.op.undefined);
        } else {
            try parseAssignExpr2(s, import_flags);
            if (s.peekKind() == .comma) try s.advance();
        }
    } else {
        try Emitter.op(s, opcode.op.undefined);
    }
    try s.expectToken(.rparen);
    try Emitter.op(s, opcode.op.import);
}

/// `js_parse_template`. Non-tagged template literals
/// lower `\`a${b}c${d}e\`` to:
///
///     push_atom_value "a"
///     get_field2 concat
///     <expr b>
///     push_atom_value "c"
///     <expr d>
///     push_atom_value "e"
///     call_method <depth-1>
///
/// matching QuickJS's `String.prototype.concat`-based concatenation
/// strategy. Empty middle/tail strings are skipped (unless they are the
/// only content, where depth==0 forces an emit). Tagged templates
/// (`tag\`...\``) and lazy raw-string evaluation follow the `call=1`
/// branch in `js_parse_template`.
fn parseTemplate(s: *State) Error!void {
    const too_many_template_substitutions = "too many template substitutions";
    var depth: u16 = 0;
    while (s.peekKind() == .template) {
        const part_payload = s.token.payload.str;
        const bytes = part_payload.bytes;
        const part = part_payload.template orelse return s.failUnexpectedToken();
        if (part_payload.cooked_invalid) return Error.InvalidEscape;

        if (bytes.len != 0 or depth == 0) {
            try emitter.emitStringLiteralValue(s, bytes);
            if (depth == 0) {
                if (part == .no_substitution) {
                    // Whole template is a single string constant; skip
                    // the concat-method setup and just consume the token.
                    try s.advance();
                    return;
                }
                const concat_atom = try s.atoms.internString("concat");
                try Emitter.opAtom(s, opcode.op.get_field2, concat_atom);
            }
            depth = std.math.add(u16, depth, 1) catch return s.failWithMessage(null, too_many_template_substitutions);
        }

        if (part == .tail) {
            try Emitter.callOp(s, opcode.op.call_method, depth - 1);
            try s.advance(); // consume the tail TOK_TEMPLATE
            return;
        }
        // .head or .middle: parse the substitution expression and
        // resume template lexing after the closing `}`.
        try s.advance(); // consume head/middle TOK_TEMPLATE
        try parseExpr(s);
        depth = std.math.add(u16, depth, 1) catch return s.failWithMessage(null, too_many_template_substitutions);
        if (s.peekKind() != .rbrace) return s.failExpectedToken(.rbrace);
        // The lookahead `}` has already moved lex.pos one byte past it;
        // free the token and ask the lexer for the next template part
        // (middle or tail) without re-bumping.
        s.lex.freeToken(&s.token);
        try s.lex.nextTemplatePartAfterBraceInto(&s.token);
    }
    return s.failUnexpectedToken();
}

fn emitTaggedTemplateSingletonObject(s: *State, bytes: []const u8, raw_bytes: []const u8) Error!void {
    const cooked_atom = try s.atoms.internString(bytes);
    try Emitter.opAtom(s, opcode.op.push_atom_value, cooked_atom);
    try Emitter.opU16(s, opcode.op.array_from, 1);

    const raw_atom = try s.atoms.internString(raw_bytes);
    try Emitter.opAtom(s, opcode.op.push_atom_value, raw_atom);
    try Emitter.opU16(s, opcode.op.array_from, 1);

    const raw_name = try s.atoms.internString("raw");
    try Emitter.opAtom(s, opcode.op.define_field, raw_name);
}

/// GetTemplateObject: the template arrays inherit from the current realm's
/// %Array.prototype%. The site object is a constant of code compiled for one
/// realm, so that realm is the compile realm -- not whichever context happens
/// to head the runtime's list.
fn templateArrayPrototype(s: *State, rt: *core.JSRuntime) ?*core.Object {
    if (s.realm) |realm| {
        if (realm.array_shape) |initial| return initial.proto;
        return realm.classPrototypeObject(core.class.ids.array);
    }
    return harnessArrayPrototype(rt);
}

/// Realm-less parser harnesses: any live realm's prototype.
fn harnessArrayPrototype(rt: *core.JSRuntime) ?*core.Object {
    if (rt.contexts.live_head) |ctx| {
        if (ctx.array_shape) |initial| return initial.proto;
    }
    if (rt.contexts.constructing_head) |ctx| {
        if (ctx.array_shape) |initial| return initial.proto;
    }
    return null;
}

const TaggedTemplateObjectBuilder = struct {
    rt: *core.JSRuntime,
    template_value: JSValue,
    raw_value: JSValue,
    template_object: *core.Object,
    raw_array: *core.Object,
    depth: u32 = 0,
    /// Test seam (TGC S3-b). `init` and `addPart` are the window in which
    /// the two arrays and the per-part cooked/raw strings exist but the
    /// template value has not yet reached a cpool slot, so the builder on
    /// the parse stack is their only holder. Nothing an ordinary test can
    /// do to the allocator schedules a collection reliably inside that
    /// window, so the test asks for one directly and asserts the compile
    /// still produces the right answer.
    pub var force_gc_in_window_for_test: bool = false;

    pub fn init(rt: *core.JSRuntime, prototype: ?*core.Object) Error!TaggedTemplateObjectBuilder {
        // A fresh array with the realm's Array prototype cannot fail with
        // anything but OutOfMemory; the other arms are runtime invariants.
        const template_object = core.Object.createArray(rt, prototype) catch |err| return runtimeInvariantToParser(err);
        errdefer core.Object.destroyFromHeader(rt, template_object.gcHeader());
        const raw_array = core.Object.createArray(rt, prototype) catch |err| return runtimeInvariantToParser(err);
        errdefer core.Object.destroyFromHeader(rt, raw_array.gcHeader());

        const raw_value = raw_array.value();
        const raw_atom = atom_module.ids.raw;
        template_object.defineOwnProperty(rt, raw_atom, core.Descriptor.data(raw_value, .none)) catch |err| return runtimeInvariantToParser(err);
        return .{
            .rt = rt,
            .template_value = template_object.value(),
            .raw_value = raw_value,
            .template_object = template_object,
            .raw_array = raw_array,
        };
    }

    fn addPart(
        self: *TaggedTemplateObjectBuilder,
        cooked_bytes: []const u8,
        raw_bytes: []const u8,
        cooked_invalid: bool,
    ) Error!void {
        const cooked_value = if (cooked_invalid) core.JSValue.undefinedValue() else blk: {
            const cooked = core.string.String.createUtf8(self.rt, cooked_bytes) catch |err| return templateStringError(err);
            break :blk cooked.value();
        };
        self.template_object.defineOwnProperty(
            self.rt,
            core.Atom.taggedInt(self.depth),
            core.Descriptor.data(cooked_value, .all),
        ) catch |err| return runtimeInvariantToParser(err);

        if (comptime @import("builtin").is_test) {
            if (force_gc_in_window_for_test) {
                _ = self.rt.forceGC(null) catch {};
            }
        }
        const raw = core.string.String.createUtf8(self.rt, raw_bytes) catch |err| return templateStringError(err);
        const raw_value = raw.value();
        self.raw_array.defineOwnProperty(
            self.rt,
            core.Atom.taggedInt(self.depth),
            core.Descriptor.data(raw_value, .all),
        ) catch |err| return runtimeInvariantToParser(err);
        self.depth += 1;
    }

    pub fn finish(self: *TaggedTemplateObjectBuilder) Error!void {
        self.raw_array.freeze(self.rt) catch |err| return runtimeInvariantToParser(err);
        self.template_object.freeze(self.rt) catch |err| return runtimeInvariantToParser(err);
    }
};

/// Leading elements an array literal collects on the operand stack before
/// switching to running-index mode.
const max_stacked_array_elements = 16384;

/// Switch from collect-then-array_from to running-index mode: build the
/// array from the `count` stacked elements and push `count` as the index.
fn beginRunningArrayLiteral(s: *State, count: u16) Error!void {
    try Emitter.opU16(s, opcode.op.array_from, count);
    try Emitter.opI32(s, opcode.op.push_i32, count);
}

/// `js_parse_array_literal`. The QuickJS strategy
/// switches dynamically: leading
/// non-spread elements collect into an `array_from <count>`; on the
/// first spread, the parser pushes `<count>` as the running index,
/// then alternates between `define_array_el; inc` (for plain entries)
/// and `append` (for spread entries); a long literal switches the same way.
/// The final index is stored as `length`, leaving the array on the stack.
fn parseArrayLiteral(s: *State) Error!void {
    try s.advance(); // consume '['
    var count: u16 = 0;
    var sparse_active = false;
    var sparse_index: u32 = 0;
    var spread_active = false;
    while (s.peekKind() != .rbracket) {
        if (s.peekKind() == .comma) {
            // Hole — leading or interior. QuickJS switches to an
            // object-style sparse array shape: `array_from <dense-prefix>`
            // followed by `define_field "<index>"` for present elements.
            if (spread_active) {
                try Emitter.op(s, opcode.op.inc);
            } else {
                if (!sparse_active) {
                    try Emitter.opU16(s, opcode.op.array_from, count);
                    sparse_active = true;
                    sparse_index = count;
                }
                sparse_index += 1;
            }
            try s.advance();
            continue;
        }
        if (s.peekKind() == .ellipsis) {
            s.features.insert(.spread_rest);
            if (!spread_active) {
                if (sparse_active) {
                    // The sparse array is already on the stack; continue it
                    // as a running literal from the next index.
                    try Emitter.opI32(s, opcode.op.push_i32, @intCast(sparse_index));
                    sparse_active = false;
                } else {
                    try beginRunningArrayLiteral(s, count);
                }
                spread_active = true;
            }
            try s.advance();
            // Array elements always parse with `PF_IN_ACCEPTED`
            // (`js_parse_assign_expr`, quickjs.c) — the bracket
            // resets the for-init no-`in` restriction.
            try parseAssignExpr2(s, ParseFlags.default);
            try Emitter.op(s, opcode.op.append);
        } else {
            // A long literal stops collecting on the operand stack, whose
            // depth and element count are both bounded.
            if (!spread_active and !sparse_active and count == max_stacked_array_elements) {
                try beginRunningArrayLiteral(s, count);
                spread_active = true;
            }
            try parseAssignExpr2(s, ParseFlags.default);
            if (spread_active) {
                try Emitter.op(s, opcode.op.define_array_el);
                try Emitter.op(s, opcode.op.inc);
            } else if (sparse_active) {
                var index_buf: [16]u8 = undefined;
                const index_name = std.fmt.bufPrint(&index_buf, "{d}", .{sparse_index}) catch return Error.ParserInvariant;
                const index_atom = try s.atoms.internString(index_name);
                try Emitter.opAtom(s, opcode.op.define_field, index_atom);
                sparse_index += 1;
            } else {
                count += 1;
            }
        }
        if (s.peekKind() == .comma) {
            try s.advance();
            continue;
        }
        break;
    }
    try s.expectToken(.rbracket);
    if (spread_active) {
        try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.dup1);
        try Emitter.opAtom(s, opcode.op.put_field, atom_module.ids.length);
    } else if (!sparse_active) {
        try Emitter.opU16(s, opcode.op.array_from, count);
    } else {
        try Emitter.op(s, opcode.op.dup);
        try Emitter.opI32(s, opcode.op.push_i32, @intCast(sparse_index));
        try Emitter.opAtom(s, opcode.op.put_field, atom_module.ids.length);
    }
}

/// `js_parse_object_literal`. Supports ordinary,
/// shorthand, computed, method, accessor, spread, and `__proto__` forms.
fn parseObjectLiteral(s: *State) Error!void {
    try s.advance(); // consume '{'
    // qjs js_parse_object_literal starts with OP_object
    const object_opcode_pos = s.activeBuilder().code_len;
    try Emitter.op(s, opcode.op.object);
    var proto_field_seen = false;
    var capacity_hint = ObjectLiteralCapacityHint{};
    if (s.peekKind() != .rbrace) {
        while (true) {
            try parseObjectProperty(s, &proto_field_seen, &capacity_hint);
            if (s.peekKind() == .comma) {
                try s.advance();
                if (s.peekKind() == .rbrace) break;
                continue;
            }
            break;
        }
    }
    try s.expectToken(.rbrace);
    if (capacity_hint.eligible and capacity_hint.unique_count != 0) {
        s.activeBuilder().code[object_opcode_pos] = opcode.op.object_slots2;
    }
}

const ObjectLiteralCapacityHint = struct {
    atoms: [2]Atom = undefined,
    unique_count: u8 = 0,
    eligible: bool = true,

    fn invalidate(self: *@This()) void {
        self.eligible = false;
    }

    fn noteStaticProperty(self: *@This(), atom_id: Atom) void {
        if (!self.eligible) return;
        for (self.atoms[0..self.unique_count]) |existing| {
            if (existing == atom_id) return;
        }
        if (self.unique_count == self.atoms.len) {
            self.eligible = false;
            return;
        }
        self.atoms[self.unique_count] = atom_id;
        self.unique_count += 1;
    }
};

/// The name and function of an object-literal method after its `*`,
/// `async` or `async *` prefix.
fn parsePrefixedObjectMethod(
    s: *State,
    func_kind: ParseFunctionKind,
    capacity_hint: *ObjectLiteralCapacityHint,
    property_source_start: FunctionSourceStart,
) Error!void {
    if (s.peekKind() == .lbracket) {
        capacity_hint.invalidate();
        try s.advance();
        try parseAssignExpr2(s, ParseFlags.default);
        try s.expectToken(.rbracket);
        if (!typescript.tsIsMethodStart(s)) return s.failExpectedToken(.lparen);
        try parseObjectMethodFunction(s, null, func_kind, property_source_start);
        try Emitter.opU8(s, opcode.op.define_method_computed, 4);
        return;
    }
    const name_info = (try parseObjectPropertyName(s)) orelse return s.failUnexpectedToken();
    const name = name_info.atom;
    capacity_hint.noteStaticProperty(name);
    if (!typescript.tsIsMethodStart(s)) return s.failExpectedToken(.lparen);
    try parseObjectMethodFunction(s, null, func_kind, property_source_start);
    try Emitter.opAtomU8(s, opcode.op.define_method, name, 4);
}

fn parseObjectProperty(
    s: *State,
    proto_field_seen: *bool,
    capacity_hint: *ObjectLiteralCapacityHint,
) Error!void {
    const k = s.peekKind();
    const property_source_start = s.currentFunctionSourceStart();
    // Property keys/values always parse with `PF_IN_ACCEPTED`
    // (`js_parse_assign_expr`, quickjs.c) — the object literal
    // resets the for-init no-`in` restriction.
    const computed_flags = ParseFlags.default;

    // Spread property: ...obj
    if (k == .ellipsis) {
        capacity_hint.invalidate();
        s.features.insert(.spread_rest);
        try s.advance();
        try parseAssignExpr2(s, ParseFlags.default);
        try Emitter.op(s, opcode.op.null); // dummy excludeList, matching QuickJS object-spread lowering
        try Emitter.opU8(s, opcode.op.copy_data_properties, 2 | (1 << 2) | (0 << 5));
        try Emitter.op(s, opcode.op.drop); // excludeList
        try Emitter.op(s, opcode.op.drop); // source
        return;
    }

    if (k == .star) {
        try s.advance();
        return parsePrefixedObjectMethod(s, .generator, capacity_hint, property_source_start);
    }

    if (k == .ident and s.isIdent("async")) {
        const async_next = try s.peekNextKind();
        if (async_next != .colon and
            async_next != .lparen and
            async_next != .lt and
            async_next != .comma and
            async_next != .rbrace)
        {
            try s.advance();
            if (s.gotLineTerminator()) return s.failUnexpectedToken();
            const func_kind: ParseFunctionKind = if (s.peekKind() == .star) blk: {
                try s.advance();
                break :blk .async_generator;
            } else .async;
            return parsePrefixedObjectMethod(s, func_kind, capacity_hint, property_source_start);
        }
    }

    // Computed property name: [expr]: value
    if (k == .lbracket) {
        capacity_hint.invalidate();
        try s.advance();
        s.features.insert(.expression);
        try parseAssignExpr2(s, computed_flags);
        try s.expectToken(.rbracket);
        if (typescript.tsIsMethodStart(s)) {
            try parseObjectMethodFunction(s, null, .method, property_source_start);
            try Emitter.opU8(s, opcode.op.define_method_computed, 4);
        } else {
            try s.expectToken(.colon);
            try Emitter.op(s, opcode.op.to_propkey);
            try parseAssignExpr2(s, ParseFlags.default);
            try functions.setObjectNameComputed(s);
            try Emitter.op(s, opcode.op.define_array_el);
            try Emitter.op(s, opcode.op.drop);
        }
        return;
    }

    if (try parseObjectPropertyName(s)) |name_info| {
        const name = name_info.atom;
        const is_getter = !name_info.has_escape and identifiers.atomNameEquals(s, name, "get");
        const is_setter = !name_info.has_escape and identifiers.atomNameEquals(s, name, "set");
        // qjs js_parse_property_name retreats to a shorthand ident when
        // the next token is `:`, `,`, `}`, `(`, or `=`; a TypeScript type
        // parameter list (`get<T>() {}`) also names a plain method.
        if ((is_getter or is_setter) and
            s.peekKind() != .colon and
            s.peekKind() != .lparen and
            s.peekKind() != .lt and
            s.peekKind() != .comma and
            s.peekKind() != .rbrace)
        {
            try parseObjectAccessorProperty(
                s,
                computed_flags,
                if (is_getter) .get else .set,
                if (is_getter) 1 else 2,
                property_source_start,
                capacity_hint,
            );
        } else if (s.peekKind() == .colon) {
            try s.advance();
            try parseAssignExpr2(s, ParseFlags.default);
            if (name_info.is_proto) {
                if (proto_field_seen.*) return s.failWithMessage(null, "duplicate __proto__ property in object literal");
                proto_field_seen.* = true;
                try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.set_proto);
            } else {
                capacity_hint.noteStaticProperty(name);
                try functions.setObjectName(s, name);
                try Emitter.opAtom(s, opcode.op.define_field, name);
            }
        } else if (typescript.tsIsMethodStart(s)) {
            capacity_hint.noteStaticProperty(name);
            try parseObjectMethodFunction(s, null, .method, property_source_start);
            try Emitter.opAtomU8(s, opcode.op.define_method, name, 4);
        } else if (name_info.allow_shorthand) {
            capacity_hint.noteStaticProperty(name);
            // Shorthand `{ x }` is an ordinary identifier read. Keep the
            // producer uniform and let scope resolution decide whether a
            // surrounding with-object supplies the value.
            if (name == atom_module.ids.arguments and identifiers.argumentsIdentifierIsForbidden(s)) {
                return s.failWithMessage(null, "'arguments' is not allowed in class field initializer or static initialization block");
            }
            try typescript.emitIdentifierReference(s, name);
            try Emitter.opAtom(s, opcode.op.define_field, name);
        } else {
            return s.failUnexpectedToken();
        }
        return;
    }
    return s.failUnexpectedToken();
}

fn parseObjectAccessorProperty(
    s: *State,
    flags: ParseFlags,
    func_kind: ParseFunctionKind,
    define_flags: u8,
    source_start: FunctionSourceStart,
    capacity_hint: *ObjectLiteralCapacityHint,
) Error!void {
    if (s.peekKind() == .lbracket) {
        capacity_hint.invalidate();
        try s.advance();
        try parseAssignExpr2(s, flags);
        try s.expectToken(.rbracket);
        if (!typescript.tsIsMethodStart(s)) return s.failExpectedToken(.lparen);
        try parseObjectMethodFunction(s, null, func_kind, source_start);
        try Emitter.opU8(s, opcode.op.define_method_computed, define_flags | 4);
        return;
    }

    const name_info = (try parseObjectPropertyName(s)) orelse return s.failUnexpectedToken();
    const name = name_info.atom;
    capacity_hint.noteStaticProperty(name);
    if (!typescript.tsIsMethodStart(s)) return s.failExpectedToken(.lparen);
    try parseObjectMethodFunction(s, null, func_kind, source_start);
    try Emitter.opAtomU8(s, opcode.op.define_method, name, define_flags | 4);
}

pub const ObjectPropertyName = struct {
    atom: Atom,
    is_proto: bool,
    allow_shorthand: bool,
    has_escape: bool,
};

pub fn parseObjectPropertyName(s: *State) Error!?ObjectPropertyName {
    const k = s.peekKind();
    var atom_id: Atom = undefined;
    var allow_shorthand = false;
    var has_escape = false;

    if (k == .ident or (k == .kw_await and identifiers.canUseAwaitAsIdentifier(s))) {
        atom_id = if (k == .ident)
            s.token.payload.ident.atom
        else
            k.keywordAtom();
        has_escape = k == .ident and s.token.payload.ident.has_escape;
        allow_shorthand = k == .kw_await or !identifiers.escapedIdentifierIsReservedWordForShorthandBinding(s, atom_id, has_escape);
        try s.advance();
    } else if (k.isKeyword()) {
        atom_id = k.keywordAtom();
        const strict = s.isStrict();
        // Sloppy code may use the strict-reserved words as shorthand names.
        allow_shorthand = (k == .kw_yield and !s.ctx.in_generator and !strict) or
            (!strict and (k == .kw_let or k == .kw_static or identifiers.isSloppyFutureReservedToken(k)));
        try s.advance();
    } else if (k == .string) {
        atom_id = try s.atoms.internString(s.token.payload.str.bytes);
        try s.advance();
    } else if (k == .number) {
        const is_bigint = s.token.payload.num.is_bigint;
        var number_buf: [64]u8 = undefined;
        const text = if (is_bigint)
            try identifiers.formatBigIntPropertyName(s, s.token.payload.num.bigint_text)
        else
            core.value_format.formatFiniteNumberAssumeCapacity(&number_buf, s.token.payload.num.value);
        defer if (is_bigint) s.scratch.free(text);
        atom_id = try s.atoms.internString(text);
        try s.advance();
    } else {
        return null;
    }
    return .{
        .atom = atom_id,
        .is_proto = identifiers.atomNameEquals(s, atom_id, "__proto__"),
        .allow_shorthand = allow_shorthand,
        .has_escape = has_escape,
    };
}

/// Runtime object operations on parser-owned fresh objects can only run
/// out of memory; any other error is a broken invariant, not a verdict on
/// the source program.
fn templateStringError(err: anyerror) Error {
    return if (err == error.OutOfMemory) Error.OutOfMemory else Error.InvalidUtf8;
}

fn runtimeInvariantToParser(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => Error.OutOfMemory,
        else => Error.ParserInvariant,
    };
}

fn parseObjectMethodFunction(s: *State, name: ?Atom, func_kind: ParseFunctionKind, source_start: FunctionSourceStart) Error!void {
    try functions.parseFunctionParamsAndBody(s, func_kind, source_start, .{ .name = name, .is_method = true });
}

/// Map an assignment-operator token to its compound-arithmetic opcode.
/// Returns `null` for plain `=` and non-assignment tokens.
pub fn compoundAssignOpcode(k: tok.Kind) ?u8 {
    return switch (k) {
        .mul_assign => opcode.op.mul,
        .div_assign => opcode.op.div,
        .mod_assign => opcode.op.mod,
        .plus_assign => opcode.op.add,
        .minus_assign => opcode.op.sub,
        .shl_assign => opcode.op.shl,
        .sar_assign => opcode.op.sar,
        .shr_assign => opcode.op.shr,
        .and_assign => opcode.op.@"and",
        .xor_assign => opcode.op.xor,
        .or_assign => opcode.op.@"or",
        .pow_assign => opcode.op.pow,
        else => null,
    };
}

pub fn logicalAssignKind(k: tok.Kind) ?LogicalAssignKind {
    return switch (k) {
        .land_assign => .land,
        .lor_assign => .lor,
        .double_question_mark_assign => .nullish,
        else => null,
    };
}

/// Mirror `quickjs.c` — token-to-opcode level table.
fn matchBinaryOp(k: tok.Kind, level: u32, flags: ParseFlags) u8 {
    return switch (level) {
        1 => switch (k) {
            .star => opcode.op.mul,
            .slash => opcode.op.div,
            .percent => opcode.op.mod,
            else => opcode.op.invalid,
        },
        2 => switch (k) {
            .plus => opcode.op.add,
            .minus => opcode.op.sub,
            else => opcode.op.invalid,
        },
        3 => switch (k) {
            .shl => opcode.op.shl,
            .sar => opcode.op.sar,
            .shr => opcode.op.shr,
            else => opcode.op.invalid,
        },
        4 => switch (k) {
            .lt => opcode.op.lt,
            .gt => opcode.op.gt,
            .lte => opcode.op.lte,
            .gte => opcode.op.gte,
            .kw_instanceof => opcode.op.instanceof,
            .kw_in => if (flags.in_accepted) opcode.op.in else opcode.op.invalid,
            else => opcode.op.invalid,
        },
        5 => switch (k) {
            .eq => opcode.op.eq,
            .neq => opcode.op.neq,
            .strict_eq => opcode.op.strict_eq,
            .strict_neq => opcode.op.strict_neq,
            else => opcode.op.invalid,
        },
        6 => switch (k) {
            .amp => opcode.op.@"and",
            else => opcode.op.invalid,
        },
        7 => switch (k) {
            .caret => opcode.op.xor,
            else => opcode.op.invalid,
        },
        8 => switch (k) {
            .pipe => opcode.op.@"or",
            else => opcode.op.invalid,
        },
        else => opcode.op.invalid,
    };
}

pub fn parseBigIntI32(text: []const u8, negate: bool) ?i32 {
    const magnitude = core.value_format.parseAsciiInt(i64, text, 0) catch return null;
    const signed = if (negate) -magnitude else magnitude;
    if (signed < std.math.minInt(i32) or signed > std.math.maxInt(i32)) return null;
    return @intCast(signed);
}

/// TGC S3-b test seam, see `TaggedTemplateObjectBuilder`.
pub const TaggedTemplateBuilderTestHook = TaggedTemplateObjectBuilder;
