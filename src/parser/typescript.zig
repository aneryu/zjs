//! TypeScript: the emission-free type grammar, tsc-style ambiguity probes, enum and namespace lowering.

const std = @import("std");
const root = @import("../parser.zig");
const bytecode = @import("../bytecode.zig");
const atom_module = @import("../core/atom.zig");
const core = @import("../core/root.zig");
const JSValue = @import("../core/value.zig").JSValue;
const opcode = bytecode.opcode;
const tok = root.token;
const Atom = atom_module.Atom;
const parse_state = @import("parse_state.zig");
const declarations = @import("declarations.zig");
const identifiers = @import("identifiers.zig");
const lookahead = @import("lookahead.zig");
const emitter = @import("emitter.zig");
const expressions = @import("expressions.zig");
const statements = @import("statements.zig");
const functions = @import("functions.zig");
const classes = @import("classes.zig");
const modules = @import("modules.zig");
const Error = parse_state.Error;
const PendingDiagnostic = parse_state.PendingDiagnostic;
const ParseFlags = parse_state.ParseFlags;
const DeclMask = parse_state.DeclMask;
const State = parse_state.State;
const ParserSnapshot = lookahead.ParserSnapshot;
const Emitter = emitter.Emitter;

/// `namespace N { export <decl> }`: copy the member binding onto the
/// namespace object right after its declaration.
fn emitNamespaceExport(s: *State, ns_atom: Atom, member: Atom) Error!void {
    try s.emitScopeGetVar(ns_atom);
    try s.emitScopeGetVar(member);
    try Emitter.opAtom(s, opcode.op.put_field, member);
}

pub fn emitNamespaceExportIfExported(s: *State, member: Atom) Error!void {
    if (!s.ctx.namespace_export) return;
    if (s.ctx.current_namespace_atom) |ns_atom| try emitNamespaceExport(s, ns_atom, member);
}

/// The binding of an `enum` or `namespace` declaration. tsc emits
/// `var N;` at function level and `let N;` inside a namespace body, and a
/// second declaration of the same name re-opens the first (declaration
/// merging), so an existing binding in the same scope is reused.
fn tsDefineNamespaceLikeBinding(s: *State, name: Atom) Error!void {
    if (s.ctx.in_namespace) {
        if (functions.findCurrentScopeVar(s, name) != null) return;
        _ = try declarations.defineVar(s, name, .let_);
        // `let N;` leaves the binding in its TDZ until here; the
        // `N = N || {}` prologue that follows reads it, so initialise
        // it to undefined exactly like `let N;` would.
        try Emitter.op(s, opcode.op.undefined);
        try s.emitScopePutVarInit(name);
        return;
    }
    _ = try declarations.defineVar(s, name, .var_);
}

pub fn parseEnumDeclaration(s: *State) Error!void {
    try s.expectToken(.kw_enum);
    if (!identifiers.isIdentifierLikeToken(s)) return s.failExpectedToken(.ident);
    const enum_atom = identifiers.identifierLikeAtom(s);
    try tsDefineNamespaceLikeBinding(s, enum_atom);
    try s.advance();

    // Emit Enum = Enum || {}
    try s.emitScopeGetVarUndef(enum_atom);
    try Emitter.op(s, opcode.op.dup);
    const skip_label = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.if_true, skip_label);
    try Emitter.op(s, opcode.op.drop);
    try Emitter.op(s, opcode.op.object);
    try Emitter.bind(s, skip_label);
    try s.emitScopePutVar(enum_atom);

    try s.expectToken(.lbrace);

    const allocator = s.scratch;
    var members = std.ArrayList(TsEnumMember).empty;
    defer {
        for (members.items) |member| tsFreeEnumValue(s, member.value);
        members.deinit(allocator);
    }
    // Value of the next member without an initializer; null after a
    // string or runtime-computed member (tsc: "Enum member must have
    // initializer").
    var next_auto: ?f64 = 0;
    while (s.peekKind() != .rbrace and s.peekKind() != .eof) {
        const member_atom = try tsEnumMemberName(s);
        const member_name = s.lex.atoms.name(member_atom) orelse "";

        var folded: ?TsEnumValue = null;
        if (s.peekKind() == .assign) {
            try s.advance();
            folded = try tsTryFoldEnumInitializer(s, enum_atom, members.items);
            if (folded == null) {
                // Runtime-computed member: the value is evaluated in
                // place, exactly like tsc's `E[E["A"] = expr] = "A"`.
                try expressions.parseAssignExpr(s);
            }
        } else {
            const auto = next_auto orelse return s.failWithMessage(null, "enum member must have initializer");
            folded = .{ .number = auto };
        }

        var reverse_mapping = true;
        if (folded) |value| {
            switch (value) {
                .number => |n| try tsEmitNumber(s, n),
                .string => |bytes| {
                    // String member: forward mapping only.
                    try s.emitScopeGetVar(enum_atom);
                    try emitter.emitStringLiteralValue(s, bytes);
                    try Emitter.opAtom(s, opcode.op.put_field, member_atom);
                    reverse_mapping = false;
                },
            }
        }
        if (reverse_mapping) {
            // Double mapping: Enum[Enum["Member"] = value] = "Member"
            try s.emitScopeGetVar(enum_atom); // Stack: [value, outer_obj]
            try Emitter.op(s, opcode.op.swap); // Stack: [outer_obj, value]
            try Emitter.op(s, opcode.op.dup); // Stack: [outer_obj, value, value]
            try s.emitScopeGetVar(enum_atom); // Stack: [outer_obj, value, value, inner_obj]
            try Emitter.op(s, opcode.op.swap); // Stack: [outer_obj, value, inner_obj, value]
            try Emitter.opAtom(s, opcode.op.put_field, member_atom); // Stack: [outer_obj, value]
            try emitter.emitStringLiteralValue(s, member_name); // Stack: [outer_obj, value, "Member"]
            try Emitter.op(s, opcode.op.put_array_el);
        }

        if (folded) |value| {
            next_auto = switch (value) {
                .number => |n| n + 1,
                .string => null,
            };
            members.append(allocator, .{ .name = member_atom, .value = value }) catch |err| {
                tsFreeEnumValue(s, value);
                return err;
            };
        } else {
            next_auto = null;
        }

        if (s.peekKind() == .comma) {
            try s.advance();
        } else if (s.peekKind() != .rbrace) {
            return s.failUnexpectedToken();
        }
    }

    try s.expectToken(.rbrace);
    s.setLastDeclaredAtom(enum_atom);

    try emitNamespaceExportIfExported(s, enum_atom);
}

pub fn parseNamespaceDeclaration(s: *State) Error!void {
    try s.expectToken(.ident); // Already matched "namespace" in caller
    try parseNamespaceDeclarationWithIdent(s);
}

fn parseNamespaceDeclarationWithIdent(s: *State) Error!void {
    if (s.peekKind() != .ident) return s.failExpectedToken(.ident);
    const ns_atom = identifiers.identifierLikeAtom(s);
    try tsDefineNamespaceLikeBinding(s, ns_atom);
    try s.advance();

    // Emit Namespace = Namespace || {}
    try s.emitScopeGetVarUndef(ns_atom);
    try Emitter.op(s, opcode.op.dup);
    const skip_label = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.if_true, skip_label);
    try Emitter.op(s, opcode.op.drop);
    try Emitter.op(s, opcode.op.object);
    try Emitter.bind(s, skip_label);
    try s.emitScopePutVar(ns_atom);

    if (s.peekKind() == .dot) {
        try s.advance(); // consume '.'

        // The nested namespace is a block of its own: a real lexical
        // scope, so its declarations (block-level functions included)
        // are instantiated at scope entry and never collide with
        // same-named members of sibling namespaces.
        var nested_scope = try s.openScope();
        errdefer nested_scope.pop(s);
        const saved_in_namespace = s.ctx.in_namespace;
        const saved_namespace_atom = if (s.ctx.current_namespace_atom) |atom_id|
            atom_id
        else
            null;
        s.ctx.in_namespace = true;
        s.setCurrentNamespaceAtom(ns_atom);
        defer {
            s.ctx.in_namespace = saved_in_namespace;
            s.setCurrentNamespaceAtom(saved_namespace_atom);
        }

        try parseNamespaceDeclarationWithIdent(s);

        if (s.last_declared_atom) |nested_atom| {
            try s.emitScopeGetVar(ns_atom);
            try s.emitScopeGetVar(nested_atom);
            try Emitter.opAtom(s, opcode.op.put_field, nested_atom);
        }
        try nested_scope.close(s);

        s.setLastDeclaredAtom(ns_atom);
        try emitNamespaceExportIfExported(s, ns_atom);
        return;
    }

    try s.expectToken(.lbrace);
    // The namespace body is a real lexical scope (tsc: an IIFE): block
    // level function declarations are instantiated at scope entry, and
    // sibling namespaces may export same-named members.
    var body_scope = try s.openScope();
    errdefer body_scope.pop(s);
    const saved_in_namespace = s.ctx.in_namespace;
    const saved_namespace_atom = if (s.ctx.current_namespace_atom) |atom_id|
        atom_id
    else
        null;
    s.ctx.in_namespace = true;
    s.setCurrentNamespaceAtom(ns_atom);
    defer {
        s.ctx.in_namespace = saved_in_namespace;
        s.setCurrentNamespaceAtom(saved_namespace_atom);
    }

    while (s.peekKind() != .rbrace and s.peekKind() != .eof) {
        try parseNamespaceStatement(s);
    }

    try s.expectToken(.rbrace);
    try body_scope.close(s);
    s.setLastDeclaredAtom(ns_atom);

    if (s.ctx.namespace_export) {
        if (saved_namespace_atom) |parent_ns| try emitNamespaceExport(s, parent_ns, ns_atom);
    }
}

fn parseNamespaceStatement(s: *State) Error!void {
    var is_exported = false;
    if (s.peekKind() == .kw_export) {
        is_exported = true;
        try s.advance();
    }

    const saved_namespace_export = s.ctx.namespace_export;
    s.ctx.namespace_export = is_exported;
    defer s.ctx.namespace_export = saved_namespace_export;

    try statements.parseStatementOrDecl(s, DeclMask{ .func = true, .func_with_label = true, .other = true });
}

pub fn tsKindIsIdentifierLike(kind: tok.TokenKind) bool {
    return kind == .ident or kind == .kw_await or kind == .kw_yield or
        kind == .kw_static or kind == .kw_let or identifiers.isSloppyFutureReservedToken(kind);
}

/// Token that may name a type, a type parameter, or the head of an
/// entity name.
fn tsAtTypeName(s: *State) bool {
    return tsKindIsIdentifierLike(s.peekKind());
}

/// Token that may follow `.` in an entity name or name a member of an
/// object type: any identifier, keyword, string, or number.
fn tsAtPropertyNameToken(s: *State) bool {
    const k = s.peekKind();
    return tsKindIsIdentifierLike(k) or tok.isKeyword(k) or k == .string or k == .number;
}

fn tsIsIdentNoLineTerminator(s: *State, name: []const u8) bool {
    return !s.gotLineTerminator() and s.isIdent(name);
}

pub fn tsIsMethodStart(s: *State) bool {
    const k = s.peekKind();
    return k == .lparen or k == .lt or k == .shl;
}

fn tsAtGreater(s: *State) bool {
    const k = s.peekKind();
    return k == .gt or k == .sar or k == .shr or k == .gte or
        k == .sar_assign or k == .shr_assign;
}

pub fn tsAtLess(s: *State) bool {
    const k = s.peekKind();
    return k == .lt or k == .shl;
}

/// Identifier-name test on the token after the current one. `same_line`
/// additionally rejects a line terminator before that token.
pub fn tsPeekNextIsIdent(s: *State, name: []const u8, same_line: bool) bool {
    const saved_cursor = lookahead.takeLexerCursorSnapshot(s);
    defer lookahead.restoreLexerCursorSnapshot(s, saved_cursor);
    var next = s.lex.next() catch return false;
    defer s.lex.freeToken(&next);
    if (same_line and s.lex.gotLineTerminator()) return false;
    return next.val == .ident and !next.payload.ident.has_escape and
        identifiers.atomNameEquals(s, next.payload.ident.atom, name);
}

/// Kind of the token two positions ahead of the current one.
fn tsPeekSecondKind(s: *State) tok.TokenKind {
    const saved_cursor = lookahead.takeLexerCursorSnapshot(s);
    defer lookahead.restoreLexerCursorSnapshot(s, saved_cursor);
    var first = s.lex.next() catch return .eof;
    s.lex.freeToken(&first);
    var second = s.lex.next() catch return .eof;
    defer s.lex.freeToken(&second);
    return second.val;
}

const TsSpeculation = struct {
    snapshot: ParserSnapshot,
    pending_diagnostic: ?PendingDiagnostic,
};

pub fn tsBeginSpeculation(s: *State) Error!TsSpeculation {
    return .{
        .snapshot = try lookahead.takeParserSnapshot(s),
        .pending_diagnostic = s.pending_diagnostic,
    };
}

pub fn tsRollback(s: *State, spec: TsSpeculation) void {
    lookahead.restoreParserLexerSnapshot(s, spec.snapshot);
    s.pending_diagnostic = spec.pending_diagnostic;
}

fn tsCommit(s: *State, spec: TsSpeculation) void {
    var snapshot = spec.snapshot;
    s.lex.freeToken(&snapshot.token);
}

/// Run a pure parse as a probe: syntax failures become `false`, resource
/// exhaustion propagates.
fn tsProbe(s: *State, comptime parse_fn: fn (*State) Error!void) Error!bool {
    parse_fn(s) catch |err| switch (err) {
        error.OutOfMemory, error.StackOverflow, error.BytecodeOverflow => return err,
        else => return false,
    };
    return true;
}

/// Consume one balanced `(...)` / `[...]` / `{...}` group starting at the
/// current opening token. Templates are consumed as one item, including
/// their substitutions.
fn tsSkipBalancedGroup(s: *State) Error!void {
    const k = s.peekKind();
    if (k != .lparen and k != .lbracket and k != .lbrace) return s.failExpectedDescription("opening delimiter");
    try s.advance();
    try tsSkipBalancedRest(s, 1, true);
}

/// Continue a balanced skip that is already `depth` levels deep. Stops at
/// the closer that brings the depth to zero; `consume_close` selects
/// whether that closer is consumed or left as the current token.
fn tsSkipBalancedRest(s: *State, initial_depth: u32, consume_close: bool) Error!void {
    var depth = initial_depth;
    while (true) {
        const k = s.peekKind();
        if (k == .lparen or k == .lbracket or k == .lbrace) {
            depth += 1;
        } else if (k == .rparen or k == .rbracket or k == .rbrace) {
            depth -= 1;
            if (depth == 0) {
                if (consume_close) try s.advance();
                return;
            }
        } else if (k == .eof) {
            return s.failUnexpectedToken();
        } else if (k == .template) {
            try tsSkipTemplate(s);
            continue;
        }
        try s.advance();
    }
}

fn tsSkipTemplate(s: *State) Error!void {
    while (true) {
        if (s.peekKind() != .template) return s.failUnexpectedToken();
        const part = s.token.payload.str.template orelse return s.failUnexpectedToken();
        switch (part) {
            .no_substitution, .tail => return s.advance(),
            .head, .middle => {
                try s.advance();
                try tsSkipBalancedRest(s, 1, false);
                if (s.peekKind() != .rbrace) return s.failExpectedToken(.rbrace);
                s.lex.freeToken(&s.token);
                try s.lex.nextTemplatePartAfterBraceInto(&s.token);
            },
        }
    }
}

/// Skip to the end of the current statement: `;`, EOF, or the first
/// token that starts a new line at nesting depth zero.
fn tsSkipToStatementEnd(s: *State) Error!void {
    var first = true;
    while (true) {
        const k = s.peekKind();
        if (k == .eof) return;
        if (k == .semicolon) return s.advance();
        if (!first and s.gotLineTerminator()) return;
        first = false;
        if (k == .lparen or k == .lbracket or k == .lbrace) {
            try tsSkipBalancedGroup(s);
        } else if (k == .template) {
            try tsSkipTemplate(s);
        } else {
            try s.advance();
        }
    }
}

pub fn tsParseTypeAnnotationOpt(s: *State) Error!void {
    if (s.peekKind() != .colon) return;
    try s.advance();
    try tsParseTypeAllowConditional(s);
}

/// Return-type position: a type, or a predicate `x is T` /
/// `asserts x [is T]` / `this is T`.
pub fn tsParseReturnTypeOpt(s: *State) Error!void {
    if (s.peekKind() != .colon) return;
    try s.advance();
    try tsParseTypeOrPredicate(s);
}

fn tsParseTypeOrPredicate(s: *State) Error!void {
    const saved = s.ts_disallow_conditional;
    s.ts_disallow_conditional = false;
    defer s.ts_disallow_conditional = saved;
    if (s.isIdent("asserts")) {
        const next_peek = s.peekNext();
        const next = next_peek.kind;
        const has_lt = next_peek.line_terminator;
        if (!has_lt and (next == .kw_this or tsKindIsIdentifierLike(next))) {
            try s.advance();
            try s.advance();
            if (tsIsIdentNoLineTerminator(s, "is")) {
                try s.advance();
                try tsParseType(s);
            }
            return;
        }
    }
    if ((s.peekKind() == .kw_this or tsAtTypeName(s)) and tsPeekNextIsIdent(s, "is", true)) {
        try s.advance();
        try s.advance();
        try tsParseType(s);
        return;
    }
    try tsParseType(s);
}

pub fn tsParseTypeAllowConditional(s: *State) Error!void {
    const saved = s.ts_disallow_conditional;
    s.ts_disallow_conditional = false;
    defer s.ts_disallow_conditional = saved;
    try tsParseType(s);
}

fn tsParseTypeDisallowConditional(s: *State) Error!void {
    const saved = s.ts_disallow_conditional;
    s.ts_disallow_conditional = true;
    defer s.ts_disallow_conditional = saved;
    try tsParseType(s);
}

/// Type := FunctionType | ConstructorType | UnionType [`extends` Type `?` Type `:` Type]
fn tsParseType(s: *State) Error!void {
    if (try tsAtFunctionTypeStart(s)) return tsParseFunctionType(s);
    try tsParseUnionType(s);
    if (s.peekKind() == .kw_extends and !s.gotLineTerminator() and !s.ts_disallow_conditional) {
        try s.advance();
        try tsParseTypeDisallowConditional(s);
        try s.expectToken(.question);
        try tsParseTypeAllowConditional(s);
        try s.expectToken(.colon);
        try tsParseTypeAllowConditional(s);
    }
}

fn tsAtFunctionTypeStart(s: *State) Error!bool {
    const k = s.peekKind();
    if (k == .lt or k == .shl or k == .kw_new) return true;
    if (s.isIdent("abstract") and s.peekNextKind() == .kw_new) return true;
    if (k != .lparen) return false;
    const balanced = lookahead.scanBalancedToken(s, false) catch |err| return lookahead.lookaheadErrorAsNoMatch(err);
    return balanced.closed and balanced.following == .arrow;
}

fn tsParseFunctionType(s: *State) Error!void {
    if (s.isIdent("abstract")) try s.advance();
    if (s.peekKind() == .kw_new) try s.advance();
    if (tsAtLess(s)) try tsParseTypeParameters(s);
    try tsParseSignatureParameters(s);
    try s.expectToken(.arrow);
    try tsParseTypeOrPredicate(s);
}

fn tsParseUnionType(s: *State) Error!void {
    if (s.peekKind() == .pipe) try s.advance();
    try tsParseIntersectionType(s);
    while (s.peekKind() == .pipe) {
        try s.advance();
        try tsParseIntersectionType(s);
    }
}

fn tsParseIntersectionType(s: *State) Error!void {
    if (s.peekKind() == .amp) try s.advance();
    try tsParseTypeOperator(s);
    while (s.peekKind() == .amp) {
        try s.advance();
        try tsParseTypeOperator(s);
    }
}

fn tsParseTypeOperator(s: *State) Error!void {
    if (s.isIdent("keyof") or s.isIdent("unique") or s.isIdent("readonly")) {
        try s.advance();
        return tsParseTypeOperator(s);
    }
    if (s.isIdent("infer")) {
        try s.advance();
        if (!tsAtTypeName(s)) return s.failExpectedDescription("type parameter name");
        try s.advance();
        if (s.peekKind() == .kw_extends) {
            // `infer U extends C` keeps its constraint unless the constraint
            // would steal the `?` of the enclosing conditional type.
            const spec = try tsBeginSpeculation(s);
            try s.advance();
            const ok = try tsProbe(s, tsParseTypeDisallowConditional);
            if (ok and (s.ts_disallow_conditional or s.peekKind() != .question)) {
                tsCommit(s, spec);
            } else {
                tsRollback(s, spec);
            }
        }
        return;
    }
    return tsParsePostfixType(s);
}

/// Array and indexed-access suffixes must start on the same line.
fn tsParsePostfixType(s: *State) Error!void {
    try tsParsePrimaryType(s);
    while (s.peekKind() == .lbracket and !s.gotLineTerminator()) {
        try s.advance();
        if (s.peekKind() == .rbracket) {
            try s.advance();
        } else {
            try tsParseTypeAllowConditional(s);
            try s.expectToken(.rbracket);
        }
    }
}

fn tsParsePrimaryType(s: *State) Error!void {
    const k = s.peekKind();
    if (k == .lparen) {
        if (try tsAtFunctionTypeStart(s)) return tsParseFunctionType(s);
        try s.advance();
        try tsParseTypeAllowConditional(s);
        try s.expectToken(.rparen);
        return;
    }
    if (k == .lbracket) return tsParseTupleType(s);
    if (k == .lbrace) return tsParseObjectType(s);
    if (k == .lt or k == .shl or k == .kw_new) return tsParseFunctionType(s);
    if (k == .string or k == .number or k == .kw_true or k == .kw_false or
        k == .kw_null or k == .kw_void or k == .kw_this)
    {
        return s.advance();
    }
    if (k == .template) return tsParseTemplateLiteralType(s);
    if (k == .minus) {
        try s.advance();
        if (s.peekKind() != .number) return s.failExpectedDescription("number literal");
        return s.advance();
    }
    if (k == .kw_typeof) {
        try s.advance();
        if (s.peekKind() == .kw_import) return tsParseImportType(s);
        try tsParseEntityName(s);
        if (s.peekKind() == .lt and !s.gotLineTerminator()) try tsParseTypeArguments(s);
        return;
    }
    if (k == .kw_import) return tsParseImportType(s);
    if (s.isIdent("abstract") and s.peekNextKind() == .kw_new) return tsParseFunctionType(s);
    if (tsAtTypeName(s)) return tsParseTypeReference(s);
    return s.failExpectedDescription("type");
}

pub fn tsParseTypeReference(s: *State) Error!void {
    try tsParseEntityName(s);
    if (s.peekKind() == .lt and !s.gotLineTerminator()) try tsParseTypeArguments(s);
}

fn tsParseEntityName(s: *State) Error!void {
    if (!tsAtTypeName(s) and s.peekKind() != .kw_this) return s.failExpectedDescription("type name");
    try s.advance();
    while (s.peekKind() == .dot) {
        try s.advance();
        if (!tsAtPropertyNameToken(s) and s.peekKind() != .private_name) {
            return s.failExpectedDescription("property name");
        }
        try s.advance();
    }
}

fn tsParseImportType(s: *State) Error!void {
    try s.expectToken(.kw_import);
    try s.expectToken(.lparen);
    if (s.peekKind() != .string) return s.failExpectedDescription("module string");
    try s.advance();
    if (s.peekKind() == .comma) {
        try s.advance();
        if (s.peekKind() == .lbrace) try tsSkipBalancedGroup(s);
    }
    try s.expectToken(.rparen);
    while (s.peekKind() == .dot) {
        try s.advance();
        if (!tsAtPropertyNameToken(s)) return s.failExpectedDescription("property name");
        try s.advance();
    }
    if (s.peekKind() == .lt and !s.gotLineTerminator()) try tsParseTypeArguments(s);
}

fn tsParseTemplateLiteralType(s: *State) Error!void {
    while (true) {
        if (s.peekKind() != .template) return s.failUnexpectedToken();
        const part = s.token.payload.str.template orelse return s.failUnexpectedToken();
        switch (part) {
            .no_substitution, .tail => return s.advance(),
            .head, .middle => {
                try s.advance();
                try tsParseTypeAllowConditional(s);
                if (s.peekKind() != .rbrace) return s.failExpectedToken(.rbrace);
                s.lex.freeToken(&s.token);
                try s.lex.nextTemplatePartAfterBraceInto(&s.token);
            },
        }
    }
}

/// `>` that closes a type argument or type parameter list. `>>`, `>>>`,
/// `>=`, `>>=`, `>>>=` are re-cut so their first byte closes the list.
fn tsExpectGreater(s: *State) Error!void {
    const k = s.peekKind();
    if (k == .gt) return s.advance();
    if (k == .sar or k == .shr or k == .gte or
        k == .sar_assign or k == .shr_assign)
    {
        s.lex.splitGreaterThan(&s.token);
        return s.advance();
    }
    return s.failExpectedToken(.gt);
}

fn tsExpectLess(s: *State) Error!void {
    const k = s.peekKind();
    if (k == .lt) return s.advance();
    if (k == .shl or k == .shl_assign) {
        s.lex.splitLessThan(&s.token);
        return s.advance();
    }
    return s.failExpectedToken(.lt);
}

pub fn tsParseTypeArguments(s: *State) Error!void {
    try tsParseTypeArgumentList(s, false);
}

/// In expression position the closing `>` must be a stand-alone token:
/// tsc re-scans it and refuses `>>`, `>>>`, `>=` there, which keeps
/// `x>>>0<y>>>0` a comparison (`parseTypeArgumentsInExpression`).
fn tsParseTypeArgumentsInExpression(s: *State) Error!void {
    try tsParseTypeArgumentList(s, true);
}

fn tsParseTypeArgumentList(s: *State, expression_context: bool) Error!void {
    try tsExpectLess(s);
    while (true) {
        try tsParseTypeAllowConditional(s);
        if (s.peekKind() != .comma) break;
        try s.advance();
        if (tsAtGreater(s)) break;
    }
    if (expression_context and s.peekKind() != .gt) return s.failExpectedToken(.gt);
    try tsExpectGreater(s);
}

/// `<const in out T extends C = D, ...>`
pub fn tsParseTypeParameters(s: *State) Error!void {
    try tsExpectLess(s);
    while (true) {
        while (true) {
            const k = s.peekKind();
            if (k == .kw_const or k == .kw_in) {
                try s.advance();
                continue;
            }
            if (s.isIdent("out")) {
                const next = s.peekNextKind();
                if (tsKindIsIdentifierLike(next) or next == .kw_const or next == .kw_in) {
                    try s.advance();
                    continue;
                }
            }
            break;
        }
        if (!tsAtTypeName(s)) return s.failExpectedDescription("type parameter name");
        try s.advance();
        if (s.peekKind() == .kw_extends) {
            try s.advance();
            try tsParseTypeAllowConditional(s);
        }
        if (s.peekKind() == .assign) {
            try s.advance();
            try tsParseTypeAllowConditional(s);
        }
        if (s.peekKind() != .comma) break;
        try s.advance();
        if (tsAtGreater(s)) break;
    }
    try tsExpectGreater(s);
}

fn tsParseTupleType(s: *State) Error!void {
    try s.expectToken(.lbracket);
    while (s.peekKind() != .rbracket) {
        if (s.peekKind() == .eof) return s.failExpectedToken(.rbracket);
        if (s.peekKind() == .ellipsis) try s.advance();
        if (tsAtTypeName(s) and tsTupleMemberIsNamed(s)) {
            try s.advance();
            if (s.peekKind() == .question) try s.advance();
            try s.expectToken(.colon);
        }
        try tsParseTypeAllowConditional(s);
        if (s.peekKind() == .question) try s.advance();
        if (s.peekKind() != .comma) break;
        try s.advance();
    }
    try s.expectToken(.rbracket);
}

fn tsTupleMemberIsNamed(s: *State) bool {
    const next = s.peekNextKind();
    if (next == .colon) return true;
    return next == .question and tsPeekSecondKind(s) == .colon;
}

/// Object type literal, interface body, or mapped type.
fn tsParseObjectType(s: *State) Error!void {
    try s.expectToken(.lbrace);
    const saved = s.ts_disallow_conditional;
    s.ts_disallow_conditional = false;
    defer s.ts_disallow_conditional = saved;
    while (s.peekKind() != .rbrace) {
        if (s.peekKind() == .eof) return s.failExpectedToken(.rbrace);
        try tsParseObjectTypeMember(s);
        if (s.peekKind() == .semicolon or s.peekKind() == .comma) {
            try s.advance();
        } else if (s.peekKind() != .rbrace and !s.gotLineTerminator()) {
            return s.failExpectedToken(.semicolon);
        }
    }
    try s.expectToken(.rbrace);
}

fn tsParseObjectTypeMember(s: *State) Error!void {
    if (s.peekKind() == .plus or s.peekKind() == .minus) {
        try s.advance();
        if (!s.isIdent("readonly")) return s.failExpectedDescription("'readonly'");
        try s.advance();
        return tsParseIndexOrMappedMember(s);
    }
    if (s.isIdent("readonly") and tsWordIsMemberModifier(s)) try s.advance();
    const k = s.peekKind();
    if (k == .lbracket) return tsParseIndexOrMappedMember(s);
    if (k == .lparen or k == .lt or k == .shl) return tsParseMethodSignatureRest(s);
    if (k == .kw_new) {
        const next = s.peekNextKind();
        if (next == .lparen or next == .lt or next == .shl) {
            try s.advance();
            return tsParseMethodSignatureRest(s);
        }
    }
    if ((s.isIdent("get") or s.isIdent("set")) and tsWordIsMemberModifier(s)) try s.advance();
    if (!tsAtPropertyNameToken(s) and k != .private_name) return s.failExpectedDescription("type member");
    try s.advance();
    if (s.peekKind() == .question) try s.advance();
    const after = s.peekKind();
    if (after == .lparen or after == .lt or after == .shl) return tsParseMethodSignatureRest(s);
    try tsParseTypeAnnotationOpt(s);
}

/// A contextual word (`readonly`, `get`, `set`) is a member modifier only
/// when a member name follows it on the same line.
fn tsWordIsMemberModifier(s: *State) bool {
    const next_peek = s.peekNext();
    const next = next_peek.kind;
    const has_lt = next_peek.line_terminator;
    if (has_lt) return false;
    return tsKindIsIdentifierLike(next) or tok.isKeyword(next) or next == .string or
        next == .number or next == .lbracket or next == .private_name;
}

fn tsParseMethodSignatureRest(s: *State) Error!void {
    if (tsAtLess(s)) try tsParseTypeParameters(s);
    try tsParseSignatureParameters(s);
    try tsParseReturnTypeOpt(s);
}

/// `[k: string]: T`, `[K in T as U]?: V`, or a computed member name.
fn tsParseIndexOrMappedMember(s: *State) Error!void {
    try s.expectToken(.lbracket);
    if (tsAtTypeName(s)) {
        const next = s.peekNextKind();
        if (next == .kw_in) {
            try s.advance();
            try s.advance();
            try tsParseTypeAllowConditional(s);
            if (s.isIdent("as")) {
                try s.advance();
                try tsParseTypeAllowConditional(s);
            }
            try s.expectToken(.rbracket);
            if (s.peekKind() == .plus or s.peekKind() == .minus) {
                try s.advance();
                try s.expectToken(.question);
            } else if (s.peekKind() == .question) {
                try s.advance();
            }
            try tsParseTypeAnnotationOpt(s);
            return;
        }
        if (next == .colon) {
            try s.advance();
            try s.advance();
            try tsParseTypeAllowConditional(s);
            try s.expectToken(.rbracket);
            if (s.peekKind() == .question) try s.advance();
            try tsParseTypeAnnotationOpt(s);
            return;
        }
    }
    try tsSkipBalancedRest(s, 1, true);
    if (s.peekKind() == .question) try s.advance();
    const after = s.peekKind();
    if (after == .lparen or after == .lt or after == .shl) return tsParseMethodSignatureRest(s);
    try tsParseTypeAnnotationOpt(s);
}

/// Parameter list of a signature that has no body: function types,
/// method signatures, overloads, ambient functions. Patterns are skipped
/// as balanced groups; initializers are not allowed here.
fn tsParseSignatureParameters(s: *State) Error!void {
    try s.expectToken(.lparen);
    const saved = s.ts_disallow_conditional;
    s.ts_disallow_conditional = false;
    defer s.ts_disallow_conditional = saved;
    while (s.peekKind() != .rparen) {
        if (s.peekKind() == .eof) return s.failExpectedToken(.rparen);
        while (s.isParameterModifier()) try s.advance();
        if (s.peekKind() == .ellipsis) try s.advance();
        const k = s.peekKind();
        if (k == .kw_this or tsKindIsIdentifierLike(k)) {
            try s.advance();
        } else if (k == .lbrace or k == .lbracket) {
            try tsSkipBalancedGroup(s);
        } else {
            return s.failExpectedDescription("parameter");
        }
        if (s.peekKind() == .question) try s.advance();
        try tsParseTypeAnnotationOpt(s);
        if (s.peekKind() == .assign) return s.failWithMessage(null, "initializers are not allowed in a signature");
        if (s.peekKind() != .comma) break;
        try s.advance();
    }
    try s.expectToken(.rparen);
}

const TsDeclarationKind = enum { none, interface, type_alias, ambient, abstract_class, namespace };

/// Contextual keywords open a declaration only in these shapes, and only
/// when the next token is on the same line: `interface X`, `type X`,
/// `declare <decl>`, `abstract class`, `namespace X`, `module X`.
pub fn tsDeclarationStart(s: *State) TsDeclarationKind {
    const k = s.peekKind();
    if (k == .kw_interface) {
        const next_peek = s.peekNext();
        const next = next_peek.kind;
        const has_lt = next_peek.line_terminator;
        return if (!has_lt and tsKindIsIdentifierLike(next)) .interface else .none;
    }
    if (k != .ident or s.token.payload.ident.has_escape) return .none;
    const name = s.lex.atoms.name(s.token.payload.ident.atom) orelse return .none;
    const word: TsDeclarationKind = if (std.mem.eql(u8, name, "type"))
        .type_alias
    else if (std.mem.eql(u8, name, "declare"))
        .ambient
    else if (std.mem.eql(u8, name, "abstract"))
        .abstract_class
    else if (std.mem.eql(u8, name, "namespace") or std.mem.eql(u8, name, "module"))
        .namespace
    else
        return .none;
    const next_peek = s.peekNext();
    const next = next_peek.kind;
    const has_lt = next_peek.line_terminator;
    if (has_lt) return .none;
    return switch (word) {
        .type_alias => if (tsKindIsIdentifierLike(next)) .type_alias else .none,
        .abstract_class => if (next == .kw_class) .abstract_class else .none,
        .namespace => if (tsKindIsIdentifierLike(next) or (next == .string and name[0] == 'm')) .namespace else .none,
        .ambient => if (tsAmbientDeclarationFollows(next)) .ambient else .none,
        else => .none,
    };
}

fn tsAmbientDeclarationFollows(kind: tok.TokenKind) bool {
    return kind == .kw_var or kind == .kw_let or kind == .kw_const or
        kind == .kw_function or kind == .kw_class or kind == .kw_enum or
        kind == .kw_interface or kind == .ident;
}

pub fn tsParseInterfaceDeclaration(s: *State) Error!void {
    try s.advance();
    if (!tsAtTypeName(s)) return s.failExpectedDescription("interface name");
    try s.advance();
    if (tsAtLess(s)) try tsParseTypeParameters(s);
    if (s.peekKind() == .kw_extends) {
        try s.advance();
        while (true) {
            try tsParseTypeReference(s);
            if (s.peekKind() != .comma) break;
            try s.advance();
        }
    }
    try tsParseObjectType(s);
}

pub fn tsParseTypeAliasDeclaration(s: *State) Error!void {
    try s.advance();
    if (!tsAtTypeName(s)) return s.failExpectedDescription("type alias name");
    try s.advance();
    if (tsAtLess(s)) try tsParseTypeParameters(s);
    try s.expectToken(.assign);
    try tsParseTypeAllowConditional(s);
    _ = try s.expectSemicolon();
}

/// `declare ...`: the whole declaration is ambient and produces nothing.
pub fn tsParseAmbientDeclaration(s: *State) Error!void {
    try s.advance();
    try tsParseAmbientDeclarationBody(s);
}

fn tsParseAmbientDeclarationBody(s: *State) Error!void {
    const k = s.peekKind();
    switch (k) {
        .kw_var, .kw_let, .kw_const => {
            try s.advance();
            if (k == .kw_const and s.peekKind() == .kw_enum) {
                try s.advance();
                return tsSkipNamedBraceBlock(s);
            }
            while (true) {
                if (tsAtTypeName(s)) {
                    try s.advance();
                } else if (s.peekKind() == .lbrace or s.peekKind() == .lbracket) {
                    try tsSkipBalancedGroup(s);
                } else {
                    return s.failExpectedDescription("binding name");
                }
                if (s.peekKind() == .bang) try s.advance();
                try tsParseTypeAnnotationOpt(s);
                if (s.peekKind() == .assign) {
                    try s.advance();
                    try tsSkipAmbientInitializer(s);
                }
                if (s.peekKind() != .comma) break;
                try s.advance();
            }
            _ = try s.expectSemicolon();
        },
        .kw_function => {
            try s.advance();
            if (s.peekKind() == .star) try s.advance();
            if (!tsAtTypeName(s)) return s.failExpectedDescription("function name");
            try s.advance();
            try tsParseMethodSignatureRest(s);
            _ = try s.expectSemicolon();
        },
        .kw_class => return tsParseAmbientClass(s),
        .kw_enum => {
            try s.advance();
            return tsSkipNamedBraceBlock(s);
        },
        .kw_interface => return tsParseInterfaceDeclaration(s),
        else => {
            if (s.isIdent("abstract") and s.peekNextKind() == .kw_class) {
                try s.advance();
                return tsParseAmbientClass(s);
            }
            if (s.isIdent("type")) return tsParseTypeAliasDeclaration(s);
            if (s.isIdent("global")) {
                try s.advance();
                return tsSkipBraceBlock(s);
            }
            if (s.isIdent("namespace") or s.isIdent("module")) {
                try s.advance();
                if (s.peekKind() == .string) {
                    try s.advance();
                    if (s.peekKind() == .lbrace) return tsSkipBraceBlock(s);
                    _ = try s.expectSemicolon();
                    return;
                }
                try tsParseEntityName(s);
                return tsSkipBraceBlock(s);
            }
            return s.failExpectedDescription("ambient declaration");
        },
    }
}

fn tsParseAmbientClass(s: *State) Error!void {
    try s.expectToken(.kw_class);
    if (!tsAtTypeName(s)) return s.failExpectedDescription("class name");
    try s.advance();
    if (tsAtLess(s)) try tsParseTypeParameters(s);
    if (s.peekKind() == .kw_extends) {
        try s.advance();
        try tsParseTypeReference(s);
    }
    if (s.peekKind() == .kw_implements) {
        try s.advance();
        while (true) {
            try tsParseTypeReference(s);
            if (s.peekKind() != .comma) break;
            try s.advance();
        }
    }
    try tsSkipBraceBlock(s);
}

fn tsSkipAmbientInitializer(s: *State) Error!void {
    if (s.peekKind() == .minus) try s.advance();
    const k = s.peekKind();
    if (k == .number or k == .string or k == .kw_true or k == .kw_false or
        k == .kw_null or tsKindIsIdentifierLike(k))
    {
        return s.advance();
    }
    if (k == .template) return tsSkipTemplate(s);
    return s.failExpectedDescription("literal initializer");
}

fn tsSkipNamedBraceBlock(s: *State) Error!void {
    if (!tsAtTypeName(s)) return s.failExpectedDescription("declaration name");
    try s.advance();
    try tsSkipBraceBlock(s);
}

fn tsSkipBraceBlock(s: *State) Error!void {
    if (s.peekKind() != .lbrace) return s.failExpectedToken(.lbrace);
    try tsSkipBalancedGroup(s);
}

/// Decide whether a function body follows the parameter list before the
/// ordinary function machinery creates a child FunctionDef. Overload,
/// abstract, and ambient signatures have none. Current token: the `<` or
/// `(` that opens the parameter list.
pub fn tsFunctionHasBodyAhead(s: *State) Error!bool {
    if (s.peekKind() == .lparen) {
        const balanced = lookahead.scanBalancedToken(s, false) catch |err| return lookahead.lookaheadErrorAsNoMatch(err);
        if (!balanced.closed) return true;
        if (balanced.following == .lbrace) return true;
        if (balanced.following != .colon) return false;
    } else if (!tsAtLess(s)) {
        return true;
    }
    const spec = try tsBeginSpeculation(s);
    defer tsRollback(s, spec);
    const ok = try tsProbe(s, tsSkipParameterListAndReturnType);
    return ok and s.peekKind() == .lbrace;
}

fn tsSkipParameterListAndReturnType(s: *State) Error!void {
    if (tsAtLess(s)) try tsParseTypeParameters(s);
    if (s.peekKind() != .lparen) return s.failExpectedToken(.lparen);
    try tsSkipBalancedGroup(s);
    try tsParseReturnTypeOpt(s);
}

/// Body-less function declaration (overload signature). It declares
/// nothing; the implementation that must follow declares the binding.
pub fn tsSkipFunctionSignature(s: *State) Error!void {
    try tsSkipParameterListAndReturnType(s);
    _ = try s.expectSemicolon();
    const k = s.peekKind();
    if (k != .kw_function and k != .kw_export and k != .kw_default and !s.isIdent("async")) {
        return s.failWithMessage(null, "function implementation is missing or not immediately following the declaration");
    }
}

/// Body-less class method (overload or abstract signature).
pub fn tsSkipMethodSignature(s: *State, is_abstract: bool) Error!void {
    try tsSkipParameterListAndReturnType(s);
    _ = try s.expectSemicolon();
    if (!is_abstract and s.peekKind() == .rbrace) {
        return s.failWithMessage(null, "function implementation is missing or not immediately following the declaration");
    }
}

/// `declare` class field: no runtime field is defined.
pub fn tsSkipDeclaredField(s: *State) Error!void {
    if (s.peekKind() == .private_name) {
        try s.advance();
    } else if (s.peekKind() == .lbracket) {
        try tsSkipBalancedGroup(s);
    } else if (try expressions.parseObjectPropertyName(s)) |_| {} else {
        return s.failExpectedDescription("property name");
    }
    if (s.peekKind() == .question or s.peekKind() == .bang) try s.advance();
    try tsParseTypeAnnotationOpt(s);
    _ = try s.expectSemicolon();
}

/// Modifier word in a class body. tsc `nextTokenCanFollowModifier`: the
/// next token must be able to start a member; `static` alone tolerates a
/// line terminator before that token.
pub fn tsCanFollowClassModifier(kind: tok.TokenKind) bool {
    return kind == .lbracket or kind == .lbrace or kind == .star or kind == .ellipsis or
        kind == .ident or tok.isKeyword(kind) or kind == .string or
        kind == .number or kind == .private_name;
}

/// Current token is `[`: is this a class index signature `[k: T]: U`?
pub fn tsIndexSignatureAhead(s: *State) bool {
    const saved_cursor = lookahead.takeLexerCursorSnapshot(s);
    defer lookahead.restoreLexerCursorSnapshot(s, saved_cursor);
    var first = s.lex.next() catch return false;
    const first_kind = first.val;
    s.lex.freeToken(&first);
    if (!tsKindIsIdentifierLike(first_kind)) return false;
    var second = s.lex.next() catch return false;
    defer s.lex.freeToken(&second);
    return second.val == .colon;
}

pub fn tsSkipIndexSignature(s: *State) Error!void {
    try tsParseIndexOrMappedMember(s);
    _ = try s.expectSemicolon();
}

/// `{...}: T = v` / `[...]?: T = v` binding: the pattern's outer
/// initializer sits behind an optional marker and a type annotation.
pub fn tsPatternHasInitializerAfterAnnotation(s: *State) Error!bool {
    const spec = try tsBeginSpeculation(s);
    defer tsRollback(s, spec);
    if (!(try tsProbe(s, tsSkipBalancedGroup))) return false;
    if (s.peekKind() == .question) try s.advance();
    if (s.peekKind() == .colon) {
        try s.advance();
        if (!(try tsProbe(s, tsParseTypeAllowConditional))) return false;
    }
    return s.peekKind() == .assign;
}

/// `<T>(x) => ...` and `<T>(x): R => ...` at the current `<`.
pub fn tsGenericArrowHead(s: *State, return_type_forbidden: bool) Error!bool {
    const spec = try tsBeginSpeculation(s);
    defer tsRollback(s, spec);
    if (!(try tsProbe(s, tsParseTypeParameters))) return false;
    if (s.peekKind() != .lparen) return false;
    if (!(try tsProbe(s, tsSkipBalancedGroup))) return false;
    if (s.peekKind() == .colon) {
        if (return_type_forbidden) return false;
        try s.advance();
        if (!(try tsProbe(s, tsParseTypeOrPredicate))) return false;
    }
    return s.peekKind() == .arrow and !s.gotLineTerminator();
}

/// `(...): R => ...` at the current `(`; the balanced scan already saw
/// the `:` after the closing parenthesis.
pub fn tsParenArrowHeadWithReturnType(s: *State) Error!bool {
    const spec = try tsBeginSpeculation(s);
    defer tsRollback(s, spec);
    if (!(try tsProbe(s, tsSkipBalancedGroup))) return false;
    if (s.peekKind() != .colon) return false;
    try s.advance();
    if (!(try tsProbe(s, tsParseTypeOrPredicate))) return false;
    return s.peekKind() == .arrow and !s.gotLineTerminator();
}

/// `<T>expr` type assertion at the current `<`.
pub fn tsParseTypeAssertion(s: *State, flags: ParseFlags) Error!void {
    try tsExpectLess(s);
    if (s.peekKind() == .kw_const) {
        try s.advance();
    } else {
        try tsParseTypeAllowConditional(s);
    }
    try tsExpectGreater(s);
    try expressions.parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted, .yield_forbidden = true });
}

/// `expr<T, U>` after a member expression: a type argument list that a
/// call, a tagged template, or an instantiation expression may follow.
/// tsc `parseTypeArgumentsInExpression` + `canFollowTypeArgumentsInExpression`.
pub fn tsTryParseTypeArgumentsInExpression(s: *State) Error!bool {
    const spec = try tsBeginSpeculation(s);
    if ((try tsProbe(s, tsParseTypeArgumentsInExpression)) and tsCanFollowTypeArgumentsInExpression(s)) {
        tsCommit(s, spec);
        return true;
    }
    tsRollback(s, spec);
    return false;
}

fn tsCanFollowTypeArgumentsInExpression(s: *State) bool {
    const k = s.peekKind();
    if (k == .lparen or k == .template) return true;
    if (k == .lt or k == .gt or k == .plus or k == .minus) return false;
    // JavaScript keeps `a < b >= c` and `a < b > = c` as comparisons.
    if (k == .assign or expressions.compoundAssignOpcode(k) != null or expressions.logicalAssignKind(k) != null) return false;
    if (s.gotLineTerminator()) return true;
    if (tsIsBinaryOperatorKind(k)) return true;
    return !tsTokenStartsExpression(k);
}

fn tsIsBinaryOperatorKind(k: tok.TokenKind) bool {
    return switch (k) {
        .star, .slash, .percent, .amp, .pipe, .caret, .question => true,
        .pow, .shl, .sar, .shr, .lte, .gte, .eq, .strict_eq, .neq, .strict_neq, .land, .lor, .double_question_mark, .kw_in, .kw_instanceof => true,
        else => false,
    };
}

fn tsTokenStartsExpression(k: tok.TokenKind) bool {
    if (tsKindIsIdentifierLike(k) or tok.isKeyword(k)) return true;
    return switch (k) {
        .number, .string, .template, .regexp, .private_name, .inc, .dec, .div_assign => true,
        .lparen, .lbracket, .lbrace, .slash, .plus, .minus, .tilde, .bang, .lt => true,
        else => false,
    };
}

/// `as T`, `as const`, `satisfies T` after a relational-level operand.
pub fn tsAtAsOrSatisfies(s: *State) bool {
    if (s.peekKind() != .ident or s.gotLineTerminator()) return false;
    return s.isIdent("as") or s.isIdent("satisfies");
}

/// `import` followed by `x =`: an import alias declaration.
pub fn tsImportAliasAhead(s: *State) bool {
    const saved_cursor = lookahead.takeLexerCursorSnapshot(s);
    defer lookahead.restoreLexerCursorSnapshot(s, saved_cursor);
    var first = s.lex.next() catch return false;
    const first_kind = first.val;
    s.lex.freeToken(&first);
    if (!tsKindIsIdentifierLike(first_kind)) return false;
    var second = s.lex.next() catch return false;
    defer s.lex.freeToken(&second);
    return second.val == .assign;
}

/// `import x = A.B.C;` lowers to `const x = A.B.C;`. `require(...)` is
/// CommonJS and rejected.
pub fn tsParseImportAlias(s: *State, export_decl: bool) Error!void {
    if (!identifiers.isIdentifierLikeToken(s)) return s.failExpectedDescription("binding name");
    const alias_atom = identifiers.identifierLikeAtom(s);
    try s.advance();
    try s.expectToken(.assign);
    if (s.isIdent("require")) {
        return s.failWithMessage(null, "'import x = require()' is not supported; use ESM import");
    }
    if (!identifiers.isIdentifierLikeToken(s)) return s.failExpectedDescription("entity name");
    if (s.top_level_lexical_as_module_ref and s.atProgramBodyScope() and identifiers.hasKnownBinding(s, alias_atom)) {
        return s.failUnexpectedToken();
    }
    _ = try declarations.defineVar(s, alias_atom, .const_);
    try s.emitScopeGetVar(identifiers.identifierLikeAtom(s));
    try s.advance();
    while (s.peekKind() == .dot) {
        try s.advance();
        const name = if (identifiers.isIdentifierLikeToken(s))
            identifiers.identifierLikeAtom(s)
        else if (tok.isKeyword(s.peekKind()))
            tok.keywordAtom(s.peekKind())
        else
            return s.failExpectedDescription("property name");
        try Emitter.opAtom(s, opcode.op.get_field, name);
        try s.advance();
    }
    try s.emitScopePutVarInit(alias_atom);
    if (export_decl) try modules.addModuleExportName(s, alias_atom, alias_atom);
    try emitNamespaceExportIfExported(s, alias_atom);
    _ = try s.expectSemicolon();
}

/// Current token is the identifier `type` right after `import`. tsc: it is
/// the type-only modifier when `{`, `*`, or a binding name follows, except
/// for the default import that is itself named `type` (`import type from
/// "m"`, but not `import type from from "m"`).
pub fn tsImportTypeModifier(s: *State) bool {
    const saved_cursor = lookahead.takeLexerCursorSnapshot(s);
    defer lookahead.restoreLexerCursorSnapshot(s, saved_cursor);
    var first = s.lex.next() catch return false;
    defer s.lex.freeToken(&first);
    if (first.val == .lbrace or first.val == .star) return true;
    if (!tsKindIsIdentifierLike(first.val)) return false;
    const first_is_from = first.val == .ident and !first.payload.ident.has_escape and
        identifiers.atomNameEquals(s, first.payload.ident.atom, "from");
    if (!first_is_from) return true;
    var second = s.lex.next() catch return false;
    defer s.lex.freeToken(&second);
    if (second.val == .assign) return true;
    return second.val == .ident and !second.payload.ident.has_escape and
        identifiers.atomNameEquals(s, second.payload.ident.atom, "from");
}

/// Current token is the identifier `type` at the start of an import or
/// export specifier. tsc `parseImportOrExportSpecifier`.
pub fn tsSpecifierTypeModifier(s: *State) bool {
    const saved_cursor = lookahead.takeLexerCursorSnapshot(s);
    defer lookahead.restoreLexerCursorSnapshot(s, saved_cursor);
    var first = s.lex.next() catch return false;
    defer s.lex.freeToken(&first);
    const first_is_name = modules.isModuleNameToken(first.val);
    if (!first_is_name) return false;
    const first_is_as = first.val == .ident and !first.payload.ident.has_escape and
        identifiers.atomNameEquals(s, first.payload.ident.atom, "as");
    if (!first_is_as) return true;
    // `{ type as ... }`
    var second = s.lex.next() catch return false;
    defer s.lex.freeToken(&second);
    const second_is_as = second.val == .ident and !second.payload.ident.has_escape and
        identifiers.atomNameEquals(s, second.payload.ident.atom, "as");
    if (second_is_as) return true; // `{ type as as X }`
    if (modules.isModuleNameToken(second.val)) return false; // `{ type as X }`
    return true; // `{ type as }`
}

/// The remainder of a type-only import after `import type`.
pub fn tsSkipTypeOnlyImport(s: *State) Error!void {
    while (true) {
        const k = s.peekKind();
        if (k == .eof) return s.failUnexpectedToken();
        if (k == .lbrace) {
            try tsSkipBalancedGroup(s);
            continue;
        }
        if (k == .assign) return tsSkipToStatementEnd(s);
        if (k == .string) {
            try s.advance();
            break;
        }
        try s.advance();
    }
    if (s.peekKind() == .kw_with) {
        try s.advance();
        try tsSkipBraceBlock(s);
    }
    _ = try s.expectSemicolon();
}

/// The remainder of a type-only export after `export type`.
pub fn tsSkipTypeOnlyExport(s: *State) Error!void {
    if (s.peekKind() == .lbrace) {
        try tsSkipBalancedGroup(s);
    } else {
        try s.expectToken(.star);
        if (s.isIdent("as")) {
            try s.advance();
            if (!modules.isModuleNameToken(s.peekKind())) return s.failExpectedDescription("export name");
            try s.advance();
        }
    }
    if (s.isIdent("from")) try tsSkipFromClause(s);
    _ = try s.expectSemicolon();
}

/// `from "m" [with {...}]` without registering a module request.
pub fn tsSkipFromClause(s: *State) Error!void {
    if (!s.isIdent("from")) return s.failExpectedDescription("'from'");
    try s.advance();
    if (s.peekKind() != .string) return s.failExpectedDescription("module string");
    try s.advance();
    if (s.peekKind() == .kw_with) {
        try s.advance();
        try tsSkipBraceBlock(s);
    }
}

const TsEnumValue = union(enum) {
    number: f64,
    string: []u8,
};

const TsEnumMember = struct {
    name: Atom,
    value: TsEnumValue,
};

fn tsFreeEnumValue(s: *State, value: TsEnumValue) void {
    switch (value) {
        .string => |bytes| s.scratch.free(bytes),
        .number => {},
    }
}

/// Enum member name: identifier, keyword, or string literal. Consumes it.
fn tsEnumMemberName(s: *State) Error!Atom {
    const k = s.peekKind();
    if (k == .string) {
        const atom_id = try s.atoms.internString(s.token.payload.str.bytes);
        try s.advance();
        return atom_id;
    }
    if (identifiers.isIdentifierLikeToken(s) or tok.isKeyword(k)) {
        const atom_id = identifiers.identifierLikeAtom(s);
        try s.advance();
        return atom_id;
    }
    return s.failExpectedDescription("enum member name");
}

/// tsc constant-folds enum initializers built from literals, the usual
/// arithmetic and bitwise operators, and references to earlier members.
/// Returns null (with the lexer restored) when the initializer is not
/// such a constant expression; the caller then evaluates it at runtime.
fn tsTryFoldEnumInitializer(s: *State, enum_atom: Atom, members: []const TsEnumMember) Error!?TsEnumValue {
    const spec = try tsBeginSpeculation(s);
    const folded = tsFoldEnumBinary(s, enum_atom, members, 0) catch |err| switch (err) {
        error.OutOfMemory, error.StackOverflow, error.BytecodeOverflow => return err,
        else => null,
    };
    if (folded) |value| {
        if (s.peekKind() == .comma or s.peekKind() == .rbrace) {
            tsCommit(s, spec);
            return value;
        }
        tsFreeEnumValue(s, value);
    }
    tsRollback(s, spec);
    return null;
}

fn tsEnumBinaryPrecedence(k: tok.TokenKind) ?u8 {
    return switch (k) {
        .pipe => 1,
        .caret => 2,
        .amp => 3,
        .shl, .sar, .shr => 4,
        .plus, .minus => 5,
        .star, .slash, .percent => 6,
        .pow => 7,
        else => null,
    };
}

fn tsFoldEnumBinary(s: *State, enum_atom: Atom, members: []const TsEnumMember, min_prec: u8) Error!?TsEnumValue {
    var left = (try tsFoldEnumUnary(s, enum_atom, members)) orelse return null;
    errdefer tsFreeEnumValue(s, left);
    while (true) {
        const op = s.peekKind();
        const prec = tsEnumBinaryPrecedence(op) orelse return left;
        if (prec < min_prec) return left;
        try s.advance();
        // `**` is right-associative; everything else binds left.
        const rhs_min: u8 = if (op == .pow) prec else prec + 1;
        const right = (try tsFoldEnumBinary(s, enum_atom, members, rhs_min)) orelse {
            tsFreeEnumValue(s, left);
            return null;
        };
        const combined = try tsFoldEnumApply(s, op, left, right);
        tsFreeEnumValue(s, left);
        tsFreeEnumValue(s, right);
        left = combined orelse return null;
    }
}

fn tsFoldEnumApply(s: *State, op: tok.TokenKind, left: TsEnumValue, right: TsEnumValue) Error!?TsEnumValue {
    if (left == .string or right == .string) {
        if (op != .plus or left != .string or right != .string) return null;
        const joined = try s.scratch.alloc(u8, left.string.len + right.string.len);
        @memcpy(joined[0..left.string.len], left.string);
        @memcpy(joined[left.string.len..], right.string);
        return .{ .string = joined };
    }
    const a = left.number;
    const b = right.number;
    const result: f64 = switch (op) {
        .plus => a + b,
        .minus => a - b,
        .star => a * b,
        .slash => a / b,
        .percent => @rem(a, b),
        .pow => std.math.pow(f64, a, b),
        .pipe => @floatFromInt(tsToInt32(a) | tsToInt32(b)),
        .amp => @floatFromInt(tsToInt32(a) & tsToInt32(b)),
        .caret => @floatFromInt(tsToInt32(a) ^ tsToInt32(b)),
        .shl => @floatFromInt(tsToInt32(a) << @as(u5, @truncate(tsToUint32(b)))),
        .sar => @floatFromInt(tsToInt32(a) >> @as(u5, @truncate(tsToUint32(b)))),
        .shr => @floatFromInt(tsToUint32(a) >> @as(u5, @truncate(tsToUint32(b)))),
        else => return null,
    };
    return .{ .number = result };
}

fn tsToUint32(value: f64) u32 {
    if (!std.math.isFinite(value)) return 0;
    const truncated = @trunc(value);
    const modulo = @mod(truncated, 4294967296.0);
    return @intFromFloat(modulo);
}

fn tsToInt32(value: f64) i32 {
    return @bitCast(tsToUint32(value));
}

fn tsFoldEnumUnary(s: *State, enum_atom: Atom, members: []const TsEnumMember) Error!?TsEnumValue {
    const k = s.peekKind();
    if (k == .minus or k == .plus or k == .tilde) {
        try s.advance();
        const operand = (try tsFoldEnumUnary(s, enum_atom, members)) orelse return null;
        if (operand != .number) {
            tsFreeEnumValue(s, operand);
            return null;
        }
        return .{ .number = switch (k) {
            .minus => -operand.number,
            .plus => operand.number,
            else => @floatFromInt(~tsToInt32(operand.number)),
        } };
    }
    return tsFoldEnumPrimary(s, enum_atom, members);
}

fn tsFoldEnumPrimary(s: *State, enum_atom: Atom, members: []const TsEnumMember) Error!?TsEnumValue {
    const k = s.peekKind();
    if (k == .number) {
        if (s.token.payload.num.is_bigint) return null;
        const value = s.token.payload.num.value;
        try s.advance();
        return .{ .number = value };
    }
    if (k == .string) {
        const bytes = try s.scratch.dupe(u8, s.token.payload.str.bytes);
        errdefer s.scratch.free(bytes);
        try s.advance();
        return .{ .string = bytes };
    }
    if (k == .template) {
        const part = s.token.payload.str;
        if (part.template != .no_substitution or part.cooked_invalid) return null;
        const bytes = try s.scratch.dupe(u8, part.bytes);
        errdefer s.scratch.free(bytes);
        try s.advance();
        return .{ .string = bytes };
    }
    if (k == .lparen) {
        try s.advance();
        const inner = (try tsFoldEnumBinary(s, enum_atom, members, 0)) orelse return null;
        errdefer tsFreeEnumValue(s, inner);
        try s.expectToken(.rparen);
        return inner;
    }
    if (identifiers.isIdentifierLikeToken(s)) {
        var name = identifiers.identifierLikeAtom(s);
        try s.advance();
        if (name == enum_atom and s.peekKind() == .dot) {
            try s.advance();
            if (!identifiers.isIdentifierLikeToken(s) and !tok.isKeyword(s.peekKind())) return null;
            name = identifiers.identifierLikeAtom(s);
            try s.advance();
        }
        for (members) |member| {
            if (member.name != name) continue;
            return switch (member.value) {
                .number => |n| .{ .number = n },
                .string => |bytes| .{ .string = try s.scratch.dupe(u8, bytes) },
            };
        }
        return null;
    }
    return null;
}

fn tsEmitNumber(s: *State, value: f64) Error!void {
    if (identifiers.numberIsExactI32(value) and !(value == 0 and std.math.signbit(value))) {
        try Emitter.opI32(s, opcode.op.push_i32, @as(i32, @intFromFloat(value)));
    } else {
        try Emitter.pushConst(s, JSValue.float64(value));
    }
}
