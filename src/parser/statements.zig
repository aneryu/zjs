//! Statements and declarations: `js_parse_statement_or_decl`, variables, loops, switch, try, using.

const std = @import("std");
const root = @import("../parser.zig");
const bytecode = @import("../bytecode.zig");
const atom_module = @import("../core/atom.zig");
const core = @import("../core/root.zig");
const unicode = @import("../libs/unicode.zig");
const array_list_erased = @import("../core/array_list_erased.zig");
const compiler = @import("../compiler/root.zig");
const opcode = bytecode.opcode;
const tok = root.token;
const Atom = atom_module.Atom;
const parse_state = @import("parse_state.zig");
const declarations = @import("declarations.zig");
const identifiers = @import("identifiers.zig");
const lookahead = @import("lookahead.zig");
const emitter = @import("emitter.zig");
const expressions = @import("expressions.zig");
const functions = @import("functions.zig");
const classes = @import("classes.zig");
const modules = @import("modules.zig");
const typescript = @import("typescript.zig");
const shared_iterator_close_marker = parse_state.shared_iterator_close_marker;
const direct_iterator_close_marker = parse_state.direct_iterator_close_marker;
const FinallyLabel = parse_state.FinallyLabel;
const Error = parse_state.Error;
const ParseFlags = parse_state.ParseFlags;
const BlockEnv = parse_state.BlockEnv;
const LabelFrame = parse_state.LabelFrame;
const DeclMask = parse_state.DeclMask;
const ParseFunctionKind = parse_state.ParseFunctionKind;
const State = parse_state.State;
const Emitter = emitter.Emitter;
const LValue = expressions.LValue;

const DisposalHint = core.object.DisposalHint;

fn expressionStatementKeepsCompletion(s: *const State) bool {
    return s.eval_ret_idx != null and !s.lex.is_module;
}

/// Decide whether a switch clause body can fall through.
/// The temp stream carries no line_num pseudo-ops, so the last opcode
/// of the case body (bounded forward scan from the body start) is the
/// answer.
///
/// The retired phase-1 twin read the last non-line opcode of the WHOLE
/// stream, so a body that emitted nothing did not answer "true" — it
/// answered with whatever preceded the clause. That case is reachable: an
/// empty `default` clause emits no dispatch test of its own, so the
/// previous clause's tail goto (or the dispatch-continuation goto a
/// leading `default` emits) is the live last opcode and the tail jump is
/// suppressed. `scan_start` is the switch's own first emission position;
/// scanning from there reproduces that whole-stream answer without an
/// O(code_len) walk.
///
/// When the last opcode is a terminator, the tail is still live if a
/// referenced label is bound at `code_len` — the same incoming-edge rule
/// as `isLiveCode` / qjs `js_is_live_code`. v2 label
/// binds emit zero bytes, so a while-family back-edge `goto` would otherwise
/// look like "cannot continue" even though `break` lands at the case end.
/// Keep this 5-opcode terminator set; do not reuse `isLiveCode`'s wider set.
fn caseTailCanFallthrough(s: *State, scan_start: u32, body_start: u32) bool {
    const v2b = s.activeBuilder();
    var pc: usize = if (v2b.code_len > body_start) body_start else scan_start;
    var last: ?u8 = null;
    while (pc < v2b.code_len) {
        const op_id = v2b.code[pc];
        const size: usize = @intCast(opcode.sizeOfPhase1(op_id));
        std.debug.assert(size != 0);
        if (size == 0) break;
        last = op_id;
        pc += size;
    }
    std.debug.assert(pc == v2b.code_len);
    const op_id = last orelse return true;
    switch (op_id) {
        opcode.op.goto,
        opcode.op.@"return",
        opcode.op.return_undef,
        opcode.op.return_async,
        opcode.op.throw,
        => {},
        else => return true,
    }
    var label_index: u32 = 0;
    while (label_index < v2b.label_len) : (label_index += 1) {
        const slot = v2b.label_slots[label_index];
        if (slot.flags.bound and slot.bound_offset == v2b.code_len and slot.ref_count > 0) return true;
    }
    return false;
}

fn usingDeclarationStart(s: *State) bool {
    if (s.peekKind() != .ident or !s.isIdent("using")) return false;
    if (s.token.payload.ident.has_escape) return false;
    const next_peek = s.peekNext();
    const next = next_peek.kind;
    const has_line_terminator = next_peek.line_terminator;
    if (has_line_terminator) return false;
    return tokenKindCanStartUsingBinding(s, next);
}

fn awaitUsingDeclarationStart(s: *State) bool {
    if (s.peekKind() != .kw_await) return false;
    const saved_cursor = lookahead.takeLexerCursorSnapshot(s);
    defer lookahead.restoreLexerCursorSnapshot(s, saved_cursor);

    var using_token = s.lex.next() catch return false;
    defer s.lex.freeToken(&using_token);
    if (s.lex.gotLineTerminator()) return false;
    if (using_token.val != .ident) return false;
    if (using_token.payload.ident.has_escape) return false;
    if (!identifiers.atomNameEquals(s, using_token.payload.ident.atom, "using")) return false;

    var binding_token = s.lex.next() catch return false;
    defer s.lex.freeToken(&binding_token);
    if (s.lex.gotLineTerminator()) return false;
    return tokenKindCanStartUsingBinding(s, binding_token.val);
}

fn directUsingDeclarationKind(s: *State) ?DisposalHint {
    if (awaitUsingDeclarationStart(s)) return .async;
    if (usingDeclarationStart(s)) return .sync;
    return null;
}

fn tokenKindCanStartUsingBinding(s: *State, kind: tok.TokenKind) bool {
    return kind == .ident or
        (kind == .kw_await and identifiers.canUseAwaitAsIdentifier(s)) or
        (kind == .kw_yield and !s.ctx.in_generator and !(s.is_strict or s.curFunc().is_strict_mode)) or
        (!(s.is_strict or s.curFunc().is_strict_mode) and
            (kind == .kw_static or kind == .kw_let or
                kind == .kw_implements or kind == .kw_interface or kind == .kw_package or
                kind == .kw_private or kind == .kw_protected or kind == .kw_public));
}

fn advanceUsingDeclarationPrefixForLookahead(s: *State, kind: DisposalHint) bool {
    switch (kind) {
        .sync => {
            if (!usingDeclarationStart(s)) return false;
            s.advance() catch return false;
            return true;
        },
        .async => {
            if (!awaitUsingDeclarationStart(s)) return false;
            s.advance() catch return false;
            s.advance() catch return false;
            return true;
        },
    }
}

fn usingDeclarationBindingIsOf(s: *State, kind: DisposalHint) Error!bool {
    const snapshot = try lookahead.takeParserSnapshot(s);
    defer lookahead.restoreParserLexerSnapshot(s, snapshot);
    if (!advanceUsingDeclarationPrefixForLookahead(s, kind)) return false;
    return s.isOfToken();
}

fn emitCreateUsingDisposableStack(s: *State) Error!u16 {
    const stack_loc = try functions.appendAnonymousTempLocal(s);
    // zjs-only explicit-resource-management lowering: mirror the
    // legacy stack creation and local-store sequence exactly.
    try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.create);
    try Emitter.opU16(s, opcode.op.put_loc, stack_loc);
    return stack_loc;
}

fn emitUsingAwait(s: *State) Error!void {
    if (s.lex.is_module and s.cur_func_stack.len == 0) s.function.ensureModule().has_top_level_await = true;
    if (!s.ctx.in_async and !(s.lex.is_module and s.cur_func_stack.len == 0)) return Error.AwaitOutsideAsyncFunction;
    // zjs-only explicit-resource-management lowering reuses the
    // ordinary await opcode through the identity-native emitter.
    try Emitter.op(s, opcode.op.await);
}

fn emitUsingAddResource(s: *State, kind: DisposalHint, stack_loc: u16, resource_loc: u16) Error!void {
    // zjs-only explicit-resource-management lowering: preserve the
    // legacy stack/resource operand order and disposal hint.
    try Emitter.opU16(s, opcode.op.get_loc, stack_loc);
    try Emitter.opU16(s, opcode.op.get_loc, resource_loc);
    try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.add(@intFromEnum(kind)));
}

fn emitUsingAwaitIfNeeded(s: *State, may_be_async: bool) Error!void {
    if (!may_be_async) return;
    // zjs-only explicit-resource-management lowering: the optional
    // await continuation is born and bound as a label.
    try Emitter.op(s, opcode.op.dup);
    try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.is_undefined);
    const skip_await = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.if_true, skip_await);
    try emitUsingAwait(s);
    try Emitter.bind(s, skip_await);
}

pub fn emitUsingDisposeStack(s: *State, stack_loc: u16, may_be_async: bool) Error!void {
    // zjs-only explicit-resource-management lowering: mirror the
    // normal-completion disposal prefix exactly.
    try Emitter.opU16(s, opcode.op.get_loc, stack_loc);
    try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.dispose);
    try emitUsingAwaitIfNeeded(s, may_be_async);
    try Emitter.op(s, opcode.op.drop);
}

fn emitUsingDisposeStackForThrow(s: *State, stack_loc: u16, may_be_async: bool) Error!void {
    // zjs-only explicit-resource-management lowering: preserve the
    // thrown value beneath the disposable stack before suppression.
    try Emitter.opU16(s, opcode.op.get_loc, stack_loc);
    try Emitter.op(s, opcode.op.swap);
    try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.dispose_throw);
    try emitUsingAwaitIfNeeded(s, may_be_async);
    try Emitter.op(s, opcode.op.drop);
}

fn armCurrentUsingBlockFrame(s: *State) Error!u16 {
    if (s.using_block_frames.items.len == 0) return error.ParserInvariant;
    const frame_index = s.using_block_frames.items.len - 1;
    if (s.using_block_frames.items[frame_index].stack_loc) |stack_loc| return stack_loc;

    const stack_loc = try emitCreateUsingDisposableStack(s);
    var catch_label: ?compiler.LabelId = null;
    // zjs-only explicit-resource-management lowering: keep the
    // synthetic catch edge identity-native until final layout.
    catch_label = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.@"catch", catch_label.?);
    s.active_catch_marker_depth += 1;
    s.using_block_frames.items[frame_index] = .{
        .stack_loc = stack_loc,
        .catch_label = catch_label,
        .catch_marker_depth = s.active_catch_marker_depth,
    };
    return stack_loc;
}

fn noteUsingResourceHint(s: *State, hint: DisposalHint) Error!void {
    if (s.using_block_frames.items.len == 0) return Error.ParserInvariant;
    if (hint == .async) {
        s.using_block_frames.items[s.using_block_frames.items.len - 1].seen_async_hint = true;
    }
}

fn finalizeCurrentUsingBlockFrame(s: *State) Error!void {
    if (s.using_block_frames.items.len == 0) return Error.ParserInvariant;
    const frame = s.using_block_frames.items[s.using_block_frames.items.len - 1];
    const stack_loc = frame.stack_loc orelse {
        _ = s.using_block_frames.pop();
        return;
    };
    if (frame.catch_marker_depth != s.active_catch_marker_depth or s.active_catch_marker_depth == 0) {
        return Error.ParserInvariant;
    }

    s.active_catch_marker_depth -= 1;
    // zjs-only explicit-resource-management lowering: normal and
    // throw completions converge through real catch/end LabelIds.
    const catch_label = frame.catch_label orelse return Error.ParserInvariant;
    try Emitter.op(s, opcode.op.drop);
    try emitUsingDisposeStack(s, stack_loc, frame.seen_async_hint);
    try s.emitCloseLoc(stack_loc);
    const end_label = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.goto, end_label);
    try Emitter.bind(s, catch_label);
    try emitUsingDisposeStackForThrow(s, stack_loc, frame.seen_async_hint);
    try Emitter.bind(s, end_label);
    _ = s.using_block_frames.pop();
}

fn restoreUsingBlockFramesAfterError(s: *State, frame_len: usize, catch_marker_depth: u32) void {
    while (s.using_block_frames.items.len > frame_len) {
        _ = s.using_block_frames.pop();
    }
    s.active_catch_marker_depth = catch_marker_depth;
}

/// An explicit-resource-management frame opened with `openUsingBlock` for
/// a program body, a block, or a loop head. `finalize` emits the disposal
/// epilogue and pops it; `unwind` drops it and anything nested inside
/// after an error, and is a no-op once finalized.
const OpenUsingBlock = struct {
    frame_len: usize,
    catch_marker_depth: u32,
    open: bool = true,

    fn finalize(self: *OpenUsingBlock, s: *State) Error!void {
        try finalizeCurrentUsingBlockFrame(s);
        self.open = false;
    }

    fn unwind(self: *OpenUsingBlock, s: *State) void {
        if (!self.open) return;
        self.open = false;
        restoreUsingBlockFramesAfterError(s, self.frame_len, self.catch_marker_depth);
    }
};

fn openUsingBlock(s: *State) Error!OpenUsingBlock {
    const frame_len = s.using_block_frames.items.len;
    const catch_marker_depth = s.active_catch_marker_depth;
    try array_list_erased.append(&s.using_block_frames, s.function.memory.allocator, .{});
    return .{ .frame_len = frame_len, .catch_marker_depth = catch_marker_depth };
}

pub fn parseProgramStatements(s: *State, decl_mask: DeclMask) Error!void {
    var using_block = try openUsingBlock(s);
    errdefer using_block.unwind(s);
    while (s.peekKind() != .eof) {
        parseStatementOrDecl(s, decl_mask) catch |err| return s.propagateFailureHere(err);
    }
    try using_block.finalize(s);
}

fn parseBlockContentsAfterOpen(s: *State) Error!void {
    if (s.ctx.is_outer_constructor_block and !s.class.has_extends) {
        s.ctx.is_outer_constructor_block = false;
        if (s.current_parameter_properties) |props| {
            for (props.items) |prop_atom| {
                // zjs-only TypeScript parameter-property lowering:
                // mirror the legacy constructor prelude exactly.
                try Emitter.op(s, opcode.op.push_this);
                try s.emitScopeGetVar(prop_atom);
                // zjs-only TypeScript parameter-property lowering:
                // retain the field atom for the v2 instruction owner.
                try Emitter.opAtom(s, opcode.op.put_field, prop_atom);
            }
        }
    }
    var using_block = try openUsingBlock(s);
    errdefer using_block.unwind(s);
    while (s.peekKind() != .rbrace and s.peekKind() != .eof) {
        try parseStatementOrDecl(s, DeclMask{ .func = true, .func_with_label = true, .other = true });
    }
    try s.expectToken(.rbrace);
    try using_block.finalize(s);
}

/// Mirror QuickJS `js_parse_block`: an empty ordinary block does not
/// allocate a lexical scope, and directive prologues are not recognized
/// here. Function bodies use `parseFunctionBodyBlock` below.
pub fn parseBlock(s: *State) Error!void {
    try s.expectToken(.lbrace);
    if (s.peekKind() == .rbrace) {
        try s.expectToken(.rbrace);
        return;
    }

    try s.pushScope();
    errdefer s.popScopeIdentity();
    try parseBlockContentsAfterOpen(s);
    try s.popScope();
}

/// Mirror the distinct function-body path in QuickJS
/// `js_parse_function_decl2`: body scope and directives belong to the
/// FormalParameters/FunctionBody production, not to ordinary blocks.
pub fn parseFunctionBodyBlock(s: *State) Error!void {
    try s.expectToken(.lbrace);
    try s.beginFunctionBody();
    errdefer s.popScopeIdentity();
    try parseDirectives(s);
    try parseBlockContentsAfterOpen(s);
}

/// Mirror the directive-prologue portion of `js_parse_directives`
/// for runtime-visible strict-mode behavior.
pub fn parseDirectives(s: *State) Error!void {
    // Only directives before the first non-directive statement participate in
    // strict-mode detection; non-strict directives are consumed as statements.
    var directive_contains_legacy_escape = false;
    while (s.peekKind() == .string) {
        if (!stringLiteralStatementHasDirectiveTerminator(s)) break;
        const str_payload = s.token.payload.str;
        // Check if this is "use strict"
        if (!str_payload.contains_escape and
            str_payload.bytes.len == 10 and
            std.mem.eql(u8, str_payload.bytes, "use strict"))
        {
            if (directive_contains_legacy_escape or str_payload.contains_legacy_escape) return s.failUnexpectedToken();
            s.curFunc().has_use_strict = true;
            s.is_strict = true;
            s.curFunc().is_strict_mode = true;
            s.lex.is_strict_mode = true;
        }
        if (expressionStatementKeepsCompletion(s)) {
            try emitter.emitGrammarSource(s, s.currentSourcePosition());
            try emitter.emitStringLiteralValue(s, str_payload.bytes);
            try s.emitEvalRetPut();
        }
        directive_contains_legacy_escape = directive_contains_legacy_escape or str_payload.contains_legacy_escape;
        try s.advance();
        // Check for semicolon or ASI
        if (s.peekKind() == .semicolon) {
            try s.advance();
        } else if (!s.gotLineTerminator() and
            s.peekKind() != .rbrace and
            s.peekKind() != .eof)
        {
            // Not a directive, break
            break;
        }
    }
}

fn stringLiteralStatementHasDirectiveTerminator(s: *const State) bool {
    var index = s.currentTokenEndOffset();
    const source = s.lex.source;
    while (index < source.len) {
        switch (source[index]) {
            ';', '}' => return true,
            '\n', '\r' => return !lineTerminatorContinuesStringLiteralExpression(source, index),
            ' ', '\t', 0x0B, 0x0C => {
                index += 1;
                continue;
            },
            '/' => {
                if (index + 1 >= source.len) return false;
                if (source[index + 1] == '/') return true;
                if (source[index + 1] == '*') {
                    index += 2;
                    var saw_lf = false;
                    while (index + 1 < source.len and !(source[index] == '*' and source[index + 1] == '/')) : (index += 1) {
                        if (source[index] == '\n' or source[index] == '\r') saw_lf = true;
                    }
                    if (index + 1 >= source.len) return false;
                    index += 2;
                    if (saw_lf) return true;
                    continue;
                }
                return false;
            },
            else => return false,
        }
    }
    return true;
}

fn lineTerminatorContinuesStringLiteralExpression(source: []const u8, start: usize) bool {
    var index = start;
    while (index < source.len) {
        switch (source[index]) {
            ' ', '\t', 0x0B, 0x0C, '\n', '\r' => index += 1,
            '/' => {
                if (index + 1 >= source.len) return false;
                if (source[index + 1] == '/') return false;
                if (source[index + 1] != '*') return false;
                index += 2;
                while (index + 1 < source.len and !(source[index] == '*' and source[index + 1] == '/')) : (index += 1) {}
                if (index + 1 >= source.len) return false;
                index += 2;
            },
            else => break,
        }
    }
    return startsKeywordAt(source, index, "in") or startsKeywordAt(source, index, "instanceof");
}

fn startsKeywordAt(source: []const u8, index: usize, keyword: []const u8) bool {
    if (index + keyword.len > source.len) return false;
    if (!std.mem.eql(u8, source[index .. index + keyword.len], keyword)) return false;
    if (index + keyword.len >= source.len) return true;
    return !isAsciiIdentifierContinue(source[index + keyword.len]);
}

fn isAsciiIdentifierContinue(c: u8) bool {
    return unicode.isAsciiIdentifierPartByte(c);
}

/// Mirror `js_parse_statement_or_decl`.
pub fn parseStatementOrDecl(s: *State, decl_mask: DeclMask) Error!void {
    s.features.insert(.statement);
    const tok_kind = s.peekKind();

    // Keep recursive function declarations out of the large statement
    // dispatcher. Debug codegen otherwise retains storage for every switch
    // arm across every nested body and exhausts the native stack budget.
    if (tok_kind == .kw_function) {
        if (!decl_mask.func and !decl_mask.func_with_label) return s.failUnexpectedToken();
        const source_start = s.currentFunctionSourceStart();
        functions.parseFunctionDecl(s, .normal, source_start) catch |err| return s.propagateFailureHere(err);
        return;
    }
    if (tok_kind == .ident and
        s.isIdent("async") and
        s.peekNext().isBefore(.kw_function))
    {
        if (!decl_mask.func and !decl_mask.func_with_label) return s.failUnexpectedToken();
        const source_start = s.currentFunctionSourceStart();
        try s.advance();
        functions.parseFunctionDecl(s, .async, source_start) catch |err| return s.propagateFailureHere(err);
        return;
    }

    parseStatementOrDeclSlow(s, decl_mask) catch |err| return s.propagateFailureHere(err);
}

fn parseStatementOrDeclSlow(s: *State, decl_mask: DeclMask) Error!void {
    const tok_kind = s.peekKind();

    if (s.labelStartAtom()) |label_atom| {
        // LabelFrame deliberately does not own atoms, so this local owner
        // spans `advance()` and the complete labelled statement.
        if (s.isReservedLabelIdentifier(label_atom)) return s.failUnexpectedToken();
        if (s.hasActiveLabel(label_atom)) return s.failUnexpectedToken();

        try s.advance();
        try s.expectToken(.colon);

        const labelled_kind = s.peekKind();
        if (labelled_kind == .kw_while or labelled_kind == .kw_do or labelled_kind == .kw_for or labelled_kind == .kw_switch) {
            const saved_pending_label = s.pending_label_atom;
            s.pending_label_atom = label_atom;
            defer s.pending_label_atom = saved_pending_label;
            try parseStatementOrDecl(s, decl_mask);
            return;
        }

        const label_frame = try s.pushLabelFrame(label_atom, false);
        errdefer s.popLabelFrame(label_frame);
        var label_block: BlockEnv = undefined;
        emitter.pushControlBlock(s, &label_block, .{ .label = label_atom, .has_break_target = true, .is_regular_stmt = true, .scope_level = s.scope_level });
        defer emitter.popControlBlock(s, &label_block);
        if (labelled_kind == .kw_class or
            (labelled_kind == .kw_function and s.peekNextKind() == .star) or
            (labelled_kind == .ident and s.isIdent("async") and s.peekNextKind() == .kw_function))
        {
            return s.failUnexpectedToken();
        }
        const mask = if (!s.curFunc().is_strict_mode and decl_mask.func_with_label)
            DeclMask{ .func = true, .func_with_label = true }
        else
            DeclMask{};
        try parseStatementOrDecl(s, mask);
        try s.patchLabelBreaks(label_frame);
        s.popLabelFrame(label_frame);
        return;
    }

    switch (tok_kind) {
        .lbrace => try parseBlockStatement(s),
        .string => try parseStringStatement(s),
        .kw_enum => try typescript.parseEnumDeclaration(s),
        .kw_interface => if (typescript.tsDeclarationStart(s) == .interface)
            try typescript.tsParseInterfaceDeclaration(s)
        else
            try parseExpressionStatement(s),
        .kw_return => try parseReturnStatement(s),
        .kw_throw => try parseThrowStatement(s),
        .kw_var, .kw_let, .kw_const => try parseVariableStatement(s, tok_kind, decl_mask),
        .kw_function => try parseFunctionDeclarationStatement(s, decl_mask),
        .kw_class => try parseClassDeclarationStatement(s, decl_mask),
        .ident => try parseIdentifierStatement(s, decl_mask),
        .kw_await => try parseAwaitStatement(s, decl_mask),
        .kw_import => try parseImportStatement(s, decl_mask),
        .kw_export => try parseExportStatement(s, decl_mask),
        .kw_if => try parseIfStatement(s),
        .kw_while => try parseWhileStatement(s),
        .kw_with => try parseWithStatement(s),
        .kw_do => try parseDoStatement(s),
        .kw_for => try parseForStatement(s),
        .kw_break, .kw_continue => try parseBreakOrContinueStatement(s),
        .kw_switch => try parseSwitchStatement(s),
        .kw_try => try parseTryStatement(s),
        .kw_debugger => try parseDebuggerStatement(s),
        .semicolon => try parseEmptyStatement(s),
        else => try parseExpressionStatement(s),
    }
}

fn parseBlockStatement(s: *State) Error!void {
    try parseBlock(s);
}

fn parseStringStatement(s: *State) Error!void {
    try parseExpressionStatementTail(s);
}

fn parseReturnStatement(s: *State) Error!void {
    if (s.is_eval or s.return_depth == 0) return s.failUnexpectedToken();
    const statement_source = s.currentSourcePosition();
    try s.advance();
    const has_expr = s.peekKind() != .semicolon and s.peekKind() != .rbrace and !s.gotLineTerminator();
    if (has_expr) try expressions.parseExpr(s);
    const return_snapshot = s.takeEmissionSnapshot();
    errdefer s.rollbackEmission(return_snapshot);
    const updated_source_loc = try emitter.reattributeReturnTailCallSource(s, has_expr, statement_source);
    errdefer if (updated_source_loc) |updated| emitter.restoreSourceLoc(s, updated);
    // qjs emits one return-keyword source event before the whole
    // emit_return lowering, including async/finally cleanup.
    try emitter.emitGrammarSource(s, statement_source);
    try emitter.emitParsedReturn(s, has_expr);
    _ = try s.expectSemicolon();
}

fn parseThrowStatement(s: *State) Error!void {
    const statement_source = s.currentSourcePosition();
    try s.advance();
    if (s.gotLineTerminator()) return s.failUnexpectedToken();
    try expressions.parseExpr(s);
    const throw_snapshot = s.takeEmissionSnapshot();
    errdefer s.rollbackEmission(throw_snapshot);
    // qjs TOK_THROW emits the keyword source immediately before
    // its source-less OP_throw.
    try emitter.emitGrammarSource(s, statement_source);
    try Emitter.op(s, opcode.op.throw);
    _ = try s.expectSemicolon();
}

fn parseVariableStatement(s: *State, tok_kind: tok.TokenKind, decl_mask: DeclMask) Error!void {
    if (tok_kind == .kw_let and canTreatLetAsExpressionStatement(s, decl_mask)) {
        try parseLetKeywordExpressionStatement(s);
        return;
    }
    if (tok_kind == .kw_const and s.peekNextKind() == .kw_enum) {
        try s.advance();
        try typescript.parseEnumDeclaration(s);
        return;
    }
    if (!decl_mask.other and (tok_kind == .kw_let or tok_kind == .kw_const)) {
        return s.failUnexpectedToken();
    }
    const var_tok = tok_kind;
    try s.advance();
    try parseVar(s, var_tok, false, ParseFlags.default);
    _ = try s.expectSemicolon();
}

fn parseFunctionDeclarationStatement(s: *State, decl_mask: DeclMask) Error!void {
    if (!decl_mask.func and !decl_mask.func_with_label) {
        return s.failUnexpectedToken();
    }
    // Only reached from the TOK_FUNCTION statement arm, so the current token
    // is never the `async` TOK_IDENT; async declarations enter through
    // `parseIdentifierStatement`.
    const source_start = s.currentFunctionSourceStart();
    try functions.parseFunctionDecl(s, .normal, source_start);
}

fn parseClassDeclarationStatement(s: *State, decl_mask: DeclMask) Error!void {
    if (!decl_mask.func) {
        return s.failUnexpectedToken();
    }
    const name_atom = (try classes.parseClass(s, true)) orelse return s.failUnexpectedToken();
    _ = name_atom;
}

fn parseIdentifierStatement(s: *State, decl_mask: DeclMask) Error!void {
    switch (typescript.tsDeclarationStart(s)) {
        .none => {},
        .interface => return typescript.tsParseInterfaceDeclaration(s),
        .type_alias => return typescript.tsParseTypeAliasDeclaration(s),
        .ambient => return typescript.tsParseAmbientDeclaration(s),
        .namespace => return typescript.parseNamespaceDeclaration(s),
        .abstract_class => {
            if (!decl_mask.func) return s.failUnexpectedToken();
            try s.advance();
            _ = (try classes.parseClass(s, true)) orelse return s.failUnexpectedToken();
            return;
        },
    }
    if (usingDeclarationStart(s)) {
        if (!decl_mask.other) return s.failUnexpectedToken();
        try parseUsingDeclaration(s, .sync);
        _ = try s.expectSemicolon();
        return;
    }
    // Check for async function declaration (async is a contextual keyword)
    if (s.isIdent("async") and s.peekNext().isBefore(.kw_function)) {
        if (!decl_mask.func and !decl_mask.func_with_label) {
            return s.failUnexpectedToken();
        }
        const source_start = s.currentFunctionSourceStart();
        try s.advance(); // consume async
        const func_kind: ParseFunctionKind = .async;
        try functions.parseFunctionDecl(s, func_kind, source_start);
        return;
    }
    // Not async function: fall through to expression statement.
    // Like the `else` branch, eval mode redirects the value
    // into `<ret>` instead of dropping it.
    try parseExpressionStatementTail(s);
}

fn parseAwaitStatement(s: *State, decl_mask: DeclMask) Error!void {
    if (awaitUsingDeclarationStart(s)) {
        if (!decl_mask.other) return s.failUnexpectedToken();
        try parseUsingDeclaration(s, .async);
        _ = try s.expectSemicolon();
        return;
    }
    try parseExpressionStatementTail(s);
}

fn parseImportStatement(s: *State, decl_mask: DeclMask) Error!void {
    const import_next = s.peekNextKind();
    if (import_next == .lparen or import_next == .dot) {
        try parseExpressionStatementTail(s);
        return;
    }
    if (typescript.tsImportAliasAhead(s)) {
        // TypeScript `import x = A.B;` is a declaration in any goal.
        if (!decl_mask.other) return s.failUnexpectedToken();
        try s.advance();
        return typescript.tsParseImportAlias(s, false);
    }
    if (!decl_mask.other or !canParseModuleDeclarationHere(s)) {
        return s.failUnexpectedToken();
    }
    try modules.parseImport(s);
}

fn parseExportStatement(s: *State, decl_mask: DeclMask) Error!void {
    if (!decl_mask.other or !canParseModuleDeclarationHere(s)) {
        return s.failUnexpectedToken();
    }
    try modules.parseExport(s);
}

fn parseIfStatement(s: *State) Error!void {
    try s.advance();
    // QuickJS creates one wrapper scope for the whole IfStatement,
    // before the condition. Both Annex-B clauses share it.
    try s.pushScope();
    errdefer s.popScopeIdentity();
    try s.setEvalReturnUndefined();
    try s.expectToken(.lparen);
    try expressions.parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = true });
    try s.expectToken(.rparen);
    // qjs TOK_IF: emit_goto(OP_if_false) / emit_goto(OP_goto) / emit_label at each merge.
    const if_false_label = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.if_false, if_false_label);
    const allow_annex_b_if_function = !s.is_strict and !s.curFunc().is_strict_mode;
    const then_is_annex_b_function =
        allow_annex_b_if_function and
        s.peekKind() == .kw_function and
        s.peekNextKind() != .star;
    const then_decl_mask = if (then_is_annex_b_function) DeclMask{ .func = true } else DeclMask{};
    const saved_annex_b_if_function_decl_clause = s.annex_b_if_function_decl_clause;
    s.annex_b_if_function_decl_clause = then_is_annex_b_function;
    defer s.annex_b_if_function_decl_clause = saved_annex_b_if_function_decl_clause;
    try parseStatementOrDecl(s, then_decl_mask);
    s.annex_b_if_function_decl_clause = saved_annex_b_if_function_decl_clause;
    if (s.peekKind() == .kw_else) {
        try s.advance();
        const else_goto_label = try Emitter.newLabel(s);
        try Emitter.jump(s, opcode.op.goto, else_goto_label);
        // Patch if_false to land at the start of the else block.
        try Emitter.bind(s, if_false_label);
        const else_is_annex_b_function =
            allow_annex_b_if_function and
            s.peekKind() == .kw_function and
            s.peekNextKind() != .star;
        const else_decl_mask = if (else_is_annex_b_function) DeclMask{ .func = true } else DeclMask{};
        s.annex_b_if_function_decl_clause = else_is_annex_b_function;
        try parseStatementOrDecl(s, else_decl_mask);
        s.annex_b_if_function_decl_clause = saved_annex_b_if_function_decl_clause;
        // Patch the goto-over-else to land after the else block.
        try Emitter.bind(s, else_goto_label);
    } else {
        // No else: patch if_false to land just past the then block.
        try Emitter.bind(s, if_false_label);
    }
    try s.popScope();
}

/// Leftover do/while parse. candidate103 still compiles
/// `parseWhileStatement` (1817) / `parseDoStatement` (1515, extra
/// 1515, 10.6% match). The leftover is pending-label + eval-undef +
/// bind loop top + break/label frames + control block + body +
/// continue patch + pop/patch. Comptime identity is test-first vs
/// body-first (expect '(', if_false/goto vs while/if_true). Take
/// that at runtime. Private names stay `inline` and pass only the
/// flag — no leftover setup at the wrapper (knives 94/98).
noinline fn parseDoOrWhileStatement(s: *State, is_do: bool) Error!void {
    try s.advance();
    const loop_label = s.pending_label_atom;
    s.pending_label_atom = null;
    try s.setEvalReturnUndefined();
    if (!is_do) try s.expectToken(.lparen);
    // qjs TOK_WHILE: label_cont bound at the test; the back edge is
    // emit_goto against the bound label. TOK_DO: label1 bound at the
    // body; if_true back edge re-enters it.
    const loop_top = try Emitter.newLabel(s);
    try Emitter.bind(s, loop_top);
    var exit_label: compiler.LabelId = undefined;
    if (!is_do) {
        try expressions.parseExpr(s);
        exit_label = try Emitter.newLabel(s);
        try Emitter.jump(s, opcode.op.if_false, exit_label);
        try s.expectToken(.rparen);
    }
    try emitter.pushBreakFrame(s);
    const label_frame = if (loop_label) |atom_id| try s.pushLabelFrame(atom_id, true) else null;
    var loop_block: BlockEnv = undefined;
    emitter.pushControlBlock(s, &loop_block, .{ .label = loop_label, .has_break_target = true, .has_continue_target = true, .scope_level = s.scope_level });
    defer emitter.popControlBlock(s, &loop_block);
    try parseStatementOrDecl(s, DeclMask{});
    try emitter.patchContinueFrame(s);
    if (label_frame) |idx| try s.patchLabelContinues(idx);
    if (is_do) {
        try s.expectToken(.kw_while);
        try s.expectToken(.lparen);
        try expressions.parseExpr(s);
        try s.expectToken(.rparen);
        try Emitter.jump(s, opcode.op.if_true, loop_top);
        if (s.peekKind() == .semicolon) try s.advance();
    } else {
        try Emitter.jump(s, opcode.op.goto, loop_top);
        try Emitter.bind(s, exit_label);
    }
    try emitter.popBreakFrameAndPatch(s);
    if (label_frame) |idx| {
        try s.patchLabelBreaks(idx);
        s.popLabelFrame(idx);
    }
}

inline fn parseWhileStatement(s: *State) Error!void {
    return parseDoOrWhileStatement(s, false);
}

fn parseWithStatement(s: *State) Error!void {
    try parseWith(s);
}

inline fn parseDoStatement(s: *State) Error!void {
    return parseDoOrWhileStatement(s, true);
}

fn parseForStatement(s: *State) Error!void {
    try s.advance();
    const loop_label = s.pending_label_atom;
    s.pending_label_atom = null;
    try s.setEvalReturnUndefined();
    if (s.peekKind() == .kw_await) {
        if (!s.ctx.in_async) return Error.AwaitOutsideAsyncFunction;
        try s.advance();
        try s.expectToken(.lparen);
        s.pending_label_atom = loop_label;
        try parseForInOf(s, true);
        return;
    }
    try s.expectToken(.lparen);

    // QuickJS routes every head without a top-level semicolon to
    // the for-in/of grammar; that parser performs the real LHS and
    // `in`/`of` validation.
    const is_for_in_of = s.forHeadHasNoTopLevelSemicolon();
    if (is_for_in_of) {
        s.pending_label_atom = loop_label;
        try parseForInOf(s, false);
    } else {
        const block_scope_level = s.scope_level;
        var for_head_is_lexical = false;
        var for_has_initializer = false;
        // C-style `for (init ; test ; update) body`. Lower as:
        //   init
        //   top: test ; if_false → end ; body ; update ; goto → top
        //   end:
        // This pattern keeps `continue` semantics consistent by
        // routing continue targets through the update block.
        // QuickJS creates this head scope for every classic for,
        // even when the initializer is empty or non-lexical.
        var for_scope = try s.openScope();
        errdefer for_scope.pop(s);
        var for_using_block: ?OpenUsingBlock = null;
        errdefer if (for_using_block) |*block| block.unwind(s);
        if (directUsingDeclarationKind(s)) |using_kind| {
            for_head_is_lexical = true;
            for_has_initializer = true;
            for_using_block = try openUsingBlock(s);
            try parseUsingDeclaration(s, using_kind);
            try s.expectToken(.semicolon);
        } else if ((s.peekKind() == .kw_var or s.peekKind() == .kw_let or s.peekKind() == .kw_const) and
            !s.canTreatLetAsForInitializerExpression())
        {
            const var_tok = s.peekKind();
            try s.advance();
            if (var_tok == .kw_let or var_tok == .kw_const) {
                for_head_is_lexical = true;
            }
            for_has_initializer = true;
            const saved_tdz_at_decl = s.emit_lexical_tdz_at_decl;
            s.emit_lexical_tdz_at_decl = for_head_is_lexical;
            defer s.emit_lexical_tdz_at_decl = saved_tdz_at_decl;
            try parseVar(s, var_tok, false, ParseFlags{ .in_accepted = false });
            try s.expectToken(.semicolon);
        } else if (s.peekKind() != .semicolon) {
            for_has_initializer = true;
            try expressions.parseExpr2(s, ParseFlags{ .in_accepted = false });
            try Emitter.op(s, opcode.op.drop);
            try s.expectToken(.semicolon);
        } else {
            try s.advance(); // consume ';'
        }
        if (for_has_initializer) try s.closeScopes(s.scope_level, block_scope_level);

        var top_label: compiler.LabelId = undefined;
        const v2b = s.activeBuilder();
        const snapshot = v2b.snapshot();
        errdefer v2b.rollback(snapshot);
        // qjs TOK_FOR binds label_test before the condition;
        // labels themselves carry no source event.
        top_label = try Emitter.newLabel(s);
        // Bind a physical-label analogue so the sequential-match
        // barrier stays even once the backedge dies (a loop body
        // whose only exit is an outer `continue` leaves this label
        // unreferenced, and QuickJS still refuses to fuse
        // `put_loc; get_loc` across it).
        try Emitter.bindParser(s, top_label);

        // Test condition.
        if (s.peekKind() != .semicolon) {
            try expressions.parseExpr(s);
        } else {
            try Emitter.op(s, opcode.op.push_true);
        }
        try s.expectToken(.semicolon);

        var exit_label: compiler.LabelId = undefined;
        exit_label = try Emitter.newLabel(s);
        try Emitter.jump(s, opcode.op.if_false, exit_label);

        // Parse the update while still inside the parenthesized
        // for-head, then move its emitted bytes after the body.
        var update_mark: compiler.builder.Snapshot = undefined;
        update_mark = s.activeBuilder().snapshot();
        if (s.peekKind() != .rparen) {
            // Phase 1 keeps the normal expression result and emits
            // the discard explicitly, like QuickJS. The final pass
            // owns the `post_inc; put; drop` -> `inc_loc` rewrite.
            try expressions.parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = false });
            // qjs TOK_FOR: discard the update expression value
            // before moving the complete update block.
            try Emitter.op(s, opcode.op.drop);
        }
        var update_seg: compiler.builder.DetachedSegment = .{};
        defer s.activeBuilder().discardSegment(&update_seg);
        // qjs TOK_FOR: the update block is moved after the body. v2 detach keeps
        // LabelIds intact — only slot offsets shift at the splice. An empty
        // update detaches nothing.
        if (s.activeBuilder().code_len != update_mark.code_len) {
            update_seg = try Emitter.detachTail(s, update_mark);
            // Legacy truncateCode + appendMovedCodeWithAtoms
            // drops the detached update's out-of-band markers.
            Emitter.discardDetachedSources(s, &update_seg);
        }
        try s.expectToken(.rparen);
        // Body.
        try emitter.pushBreakFrame(s);
        const label_frame = if (loop_label) |atom_id| try s.pushLabelFrame(atom_id, true) else null;
        var loop_block: BlockEnv = undefined;
        emitter.pushControlBlock(s, &loop_block, .{ .label = loop_label, .has_break_target = true, .has_continue_target = true, .scope_level = s.scope_level });
        defer emitter.popControlBlock(s, &loop_block);
        try parseStatementOrDecl(s, DeclMask{});

        // Update: run after normal body completion and continue paths.
        try s.closeScopes(s.scope_level, block_scope_level);
        try emitter.patchContinueFrame(s);
        if (label_frame) |idx| try s.patchLabelContinues(idx);
        // qjs TOK_FOR: append the detached update after the
        // body and patched continue exits.
        if (update_seg.code.len != 0) try Emitter.spliceSegment(s, &update_seg);

        try Emitter.jump(s, opcode.op.goto, top_label);
        try Emitter.bind(s, exit_label);
        try emitter.popBreakFrameAndPatch(s);
        if (label_frame) |idx| {
            try s.patchLabelBreaks(idx);
            s.popLabelFrame(idx);
        }
        if (for_using_block) |*block| try block.finalize(s);
        try for_scope.close(s);
    }
}

fn parseBreakOrContinueStatement(s: *State) Error!void {
    const is_break = s.peekKind() == .kw_break;
    try s.advance();
    var label_atom: ?Atom = null;
    if (!s.gotLineTerminator() and identifiers.isIdentifierLikeToken(s)) {
        // The identifier token is released by advance; retain the
        // lookup key until the labelled jump has been emitted.
        const atom_id = identifiers.identifierLikeAtom(s);
        label_atom = atom_id;
        if (s.peekKind() == .ident and identifiers.escapedIdentifierIsReservedWordForCurrentContext(s, atom_id, s.token.payload.ident.has_escape)) return s.failUnexpectedToken();
        try s.advance(); // consume the label name
    }
    _ = try s.expectSemicolon();
    if (label_atom) |atom_id| {
        if (is_break) {
            try s.emitLabelledBreak(atom_id);
        } else {
            try s.emitLabelledContinue(atom_id);
        }
        return;
    }
    if (is_break) {
        if (s.break_frame_lens.items.len == 0) return s.failUnexpectedToken();
        try emitter.emitUnlabelledBreak(s);
    } else {
        if (s.continue_frame_lens.items.len == 0) return s.failUnexpectedToken();
        try emitter.emitUnlabelledContinue(s);
    }
}

fn parseSwitchStatement(s: *State) Error!void {
    // Switch lowering: each case tests the discriminant, and its body falls
    // through to the next clause when `caseTailCanFallthrough` says the tail
    // is live (C-style fallthrough); otherwise the clause exits to the end.
    try s.advance();
    const switch_label = s.pending_label_atom;
    s.pending_label_atom = null;
    try s.expectToken(.lparen);
    try s.setEvalReturnUndefined();
    try expressions.parseExpr(s); // discriminant on stack
    try s.expectToken(.rparen);
    try s.expectToken(.lbrace);
    try s.pushScope();
    errdefer s.popScopeIdentity();
    const saved_switch_case_block_scope = s.in_switch_case_block_scope;
    s.in_switch_case_block_scope = true;
    defer s.in_switch_case_block_scope = saved_switch_case_block_scope;
    try emitter.pushBreakOnlyFrame(s);
    emitter.setCurrentBreakCrossCleanupDrops(s, 1);
    emitter.enterSwitchContinueCleanup(s);
    defer emitter.leaveSwitchContinueCleanup(s);
    const label_frame = if (switch_label) |atom_id| try s.pushLabelFrame(atom_id, false) else null;
    var switch_block: BlockEnv = undefined;
    emitter.pushControlBlock(s, &switch_block, .{ .label = switch_label, .has_break_target = true, .scope_level = s.scope_level, .drop_count = 1 });
    defer emitter.popControlBlock(s, &switch_block);

    // Keep unmatched case-test exits separate from matched
    // fallthrough jumps: once a case has matched, later case tests
    // are skipped and only their bodies run.
    var no_match_labels: [64]compiler.LabelId = undefined;
    var no_match_jumps_count: usize = 0;
    var fallthrough_label: ?compiler.LabelId = null;
    var has_default = false;
    var default_label: ?compiler.LabelId = null;
    var default_waiting_for_body = false;
    // Floor for the v2 clause-tail flow scan: an empty clause body has
    // to fall back to the code emitted before it (see
    // `caseTailCanFallthrough`). Every clause
    // emits its dispatch test (or, for a leading `default`, the
    // dispatch-continuation goto) after this point, so the widened
    // range always carries the answer.
    const clause_scan_start: u32 = s.activeBuilder().code_len;

    while (s.peekKind() != .rbrace and s.peekKind() != .eof) {
        if (s.peekKind() == .kw_case) {
            // qjs TOK_SWITCH: label_case binds at
            // the next case test before dispatch continues.
            for (no_match_labels[0..no_match_jumps_count]) |label| {
                try Emitter.bind(s, label);
            }
            no_match_jumps_count = 0;

            try s.advance();
            // dup ; case_expr ; strict_eq ; if_false → next_case
            try Emitter.op(s, opcode.op.dup);
            try expressions.parseExpr(s);
            try s.expectToken(.colon);
            try Emitter.op(s, opcode.op.strict_eq);
            const next_case_label = try Emitter.newLabel(s);
            try Emitter.jump(s, opcode.op.if_false, next_case_label);
            if (no_match_jumps_count >= no_match_labels.len) return Error.ParserInvariant;
            no_match_labels[no_match_jumps_count] = next_case_label;
            no_match_jumps_count += 1;
            if (fallthrough_label) |label| {
                try Emitter.bind(s, label);
                fallthrough_label = null;
            }

            // Matched: keep the discriminant on stack until the
            // common switch epilogue, matching QuickJS's case shape.
            var body_start: u32 = undefined;
            body_start = s.activeBuilder().code_len;
            const has_case_body = s.peekKind() != .kw_case and
                s.peekKind() != .kw_default and
                s.peekKind() != .rbrace and
                s.peekKind() != .eof;
            if (default_waiting_for_body and has_case_body) {
                const clause_default_label = try Emitter.newLabel(s);
                try Emitter.bind(s, clause_default_label);
                default_label = clause_default_label;
                default_waiting_for_body = false;
            }
            while (s.peekKind() != .kw_case and
                s.peekKind() != .kw_default and
                s.peekKind() != .rbrace and
                s.peekKind() != .eof)
            {
                try parseStatementOrDecl(s, DeclMask{ .func = true, .func_with_label = true, .other = true });
            }
            // qjs TOK_SWITCH always emits
            // the fallthrough goto; js_is_live_code strips dead
            // tails. Do not also require "no switch-break in the
            // body" — that drops `case 0: if(false) break; y(); case 1:`.
            const case_tail_can_fallthrough =
                caseTailCanFallthrough(s, clause_scan_start, body_start);
            if ((s.peekKind() == .kw_case or s.peekKind() == .kw_default) and
                case_tail_can_fallthrough)
            {
                const clause_fallthrough_label = try Emitter.newLabel(s);
                try Emitter.jump(s, opcode.op.goto, clause_fallthrough_label);
                fallthrough_label = clause_fallthrough_label;
            }
        } else if (s.peekKind() == .kw_default) {
            if (has_default) return s.failUnexpectedToken();
            try s.advance();
            try s.expectToken(.colon);
            if (no_match_jumps_count == 0) {
                if (no_match_jumps_count >= no_match_labels.len) return Error.ParserInvariant;
                const no_match_label = try Emitter.newLabel(s);
                try Emitter.jump(s, opcode.op.goto, no_match_label);
                no_match_labels[no_match_jumps_count] = no_match_label;
                no_match_jumps_count += 1;
            }
            var body_start: u32 = undefined;
            body_start = s.activeBuilder().code_len;
            if (fallthrough_label) |label| {
                try Emitter.bind(s, label);
                fallthrough_label = null;
            }

            // Default body label.
            var default_candidate: compiler.LabelId = undefined;
            // Eager candidate: legacy decides default_body_start after parsing the
            // body; the v2 bind must happen at the body-start position itself.
            default_candidate = try Emitter.newLabel(s);
            try Emitter.bind(s, default_candidate);
            has_default = true;
            while (s.peekKind() != .kw_case and
                s.peekKind() != .kw_default and
                s.peekKind() != .rbrace and
                s.peekKind() != .eof)
            {
                try parseStatementOrDecl(s, DeclMask{ .func = true, .func_with_label = true, .other = true });
            }
            if (s.activeBuilder().code_len == body_start and s.peekKind() == .kw_case) {
                default_waiting_for_body = true;
            } else {
                default_label = default_candidate;
                default_waiting_for_body = false;
            }
            const case_tail_can_fallthrough =
                caseTailCanFallthrough(s, clause_scan_start, body_start);
            if (s.peekKind() == .kw_case and case_tail_can_fallthrough) {
                const clause_fallthrough_label = try Emitter.newLabel(s);
                try Emitter.jump(s, opcode.op.goto, clause_fallthrough_label);
                fallthrough_label = clause_fallthrough_label;
            }
        } else {
            return s.failUnexpectedToken();
        }
    }
    try s.expectToken(.rbrace);

    // qjs binds the default label backwards with an in-stream patch
    // (the "ugly patch", quickjs.c ~29365) and legacy mirrors it with
    // `patchJumpTarget`. V2 forbids rewriting a jump's PC, but the
    // unmatched-dispatch boundary and the default body are ONE program
    // point, so the references move onto the default identity instead
    // (`retargetLabelRefs`) — the same arm-for-arm shape as legacy.
    //
    // The earlier epilogue trampoline (`goto SKIP; NO_MATCH: goto
    // DEFAULT; SKIP:`) is gone. It was an instruction pair legacy
    // never materializes, and every syntactic probe that legacy runs
    // over this stream had to be taught to see through it: its skip
    // goto sat exactly where the last clause body's converging labels
    // bind, so `findJumpTarget` threaded one hop further than legacy
    // and `codeHasLabel` then compared two different boundaries.
    // `switch (0) { default: if (false) ; else ; }` kept a `goto` to
    // its own fallthrough that legacy folds away.
    if (no_match_jumps_count != 0) {
        if (default_label) |bound_default_label| {
            for (no_match_labels[0..no_match_jumps_count]) |label| {
                try Emitter.retargetLabel(s, label, bound_default_label);
            }
        } else {
            // No default clause: unmatched dispatch falls through to
            // the common discriminant drop (`patchForwardJump`).
            for (no_match_labels[0..no_match_jumps_count]) |label| {
                try Emitter.bind(s, label);
            }
        }
    }
    if (fallthrough_label) |label| try Emitter.bind(s, label);
    try emitter.popBreakOnlyFrameAndPatch(s);
    if (label_frame) |idx| {
        try s.patchLabelBreaks(idx);
        s.popLabelFrame(idx);
    }
    try Emitter.op(s, opcode.op.drop);
    try s.popScope();
}

fn parseTryStatement(s: *State) Error!void {
    try s.advance();
    try s.setEvalReturnUndefined();

    var label_catch: compiler.LabelId = undefined;
    var label_catch2: compiler.LabelId = undefined;
    var label_finally: compiler.LabelId = undefined;
    var label_end: compiler.LabelId = undefined;
    // qjs TOK_TRY creates all four labels upfront;
    // v2 label discipline requires every created label to end up bound, and
    // a no-catch try never binds catch2 — so catch2 is created at its first
    // use in the catch clause (id order differs from qjs; resolved output
    // is unaffected because ids are per-function creation indices).
    label_catch = try Emitter.newLabel(s);
    label_finally = try Emitter.newLabel(s);
    label_end = try Emitter.newLabel(s);
    const finally_ref: FinallyLabel = label_finally;

    // qjs TOK_TRY: emit_goto(OP_catch, label_catch) — the handler target is born as a LabelId.
    try Emitter.jump(s, opcode.op.@"catch", label_catch);
    var try_region = try emitter.openProtectedRegion(s, finally_ref);
    errdefer try_region.leave(s);

    try parseBlock(s);

    try_region.leave(s);

    if (emitter.isLiveCode(s)) {
        // qjs TOK_TRY live try tail: drop, undefined, gosub finally, drop, goto end.
        try Emitter.opNoSource(s, opcode.op.drop);
        try Emitter.opNoSource(s, opcode.op.undefined);
        try Emitter.jumpNoSource(s, opcode.op.gosub, label_finally);
        try Emitter.opNoSource(s, opcode.op.drop);
        try Emitter.jumpNoSource(s, opcode.op.goto, label_end);
    }

    if (s.peekKind() == .kw_catch) {
        try s.advance();
        // qjs TOK_TRY catch entry: bind label_catch at the handler entry.
        try Emitter.bindParser(s, label_catch);

        var catch_binding_scope = try s.openScope();
        errdefer catch_binding_scope.pop(s);
        if (s.peekKind() == .lbrace) {
            // qjs TOK_TRY optional catch binding: drop the exception object.
            try Emitter.opNoSource(s, opcode.op.drop);
        } else {
            try s.expectToken(.lparen);
            if (s.peekKind() == .lbracket or s.peekKind() == .lbrace) {
                _ = try functions.parseDestructuringElement(s, .{ .binding = .{
                    .define_type = .let_,
                    .is_parameter = false,
                    .export_flag = false,
                } }, .{ .has_value = true, .allow_outer_initializer = true }, ParseFlags.default);
            } else {
                if (!identifiers.isIdentifierLikeToken(s)) return s.failUnexpectedToken();
                const catch_atom = identifiers.identifierLikeAtom(s);
                if ((s.is_strict or s.curFunc().is_strict_mode) and
                    (identifiers.atomNameEquals(s, catch_atom, "eval") or identifiers.atomNameEquals(s, catch_atom, "arguments")))
                {
                    return s.failUnexpectedToken();
                }
                _ = try declarations.defineVar(s, catch_atom, .catch_);
                try s.advance();
                try typescript.tsParseTypeAnnotationOpt(s);
                try s.emitScopePutVar(catch_atom);
            }
            try s.expectToken(.rparen);
        }

        // qjs TOK_TRY catch body: create and target the second catch handler.
        label_catch2 = try Emitter.newLabel(s);
        try Emitter.jump(s, opcode.op.@"catch", label_catch2);
        var catch_region = try emitter.openProtectedRegion(s, finally_ref);
        errdefer catch_region.leave(s);

        // QuickJS owns a wrapper scope for the catch statement in
        // addition to the catch-binding scope and the ordinary
        // block's own scope.
        var catch_wrapper_scope = try s.openScope();
        errdefer catch_wrapper_scope.pop(s);
        try parseBlock(s);

        catch_region.leave(s);
        try catch_wrapper_scope.close(s);
        try catch_binding_scope.close(s);

        if (emitter.isLiveCode(s)) {
            // qjs TOK_TRY live catch tail: drop, undefined, gosub finally, drop, goto end.
            try Emitter.opNoSource(s, opcode.op.drop);
            try Emitter.opNoSource(s, opcode.op.undefined);
            try Emitter.jumpNoSource(s, opcode.op.gosub, label_finally);
            try Emitter.opNoSource(s, opcode.op.drop);
            try Emitter.jumpNoSource(s, opcode.op.goto, label_end);
        }

        // qjs TOK_TRY catch rethrow: bind catch2, gosub finally, then throw.
        try Emitter.bindParser(s, label_catch2);
        try Emitter.jumpNoSource(s, opcode.op.gosub, label_finally);
        try Emitter.opNoSource(s, opcode.op.throw);
    } else if (s.peekKind() == .kw_finally) {
        // qjs TOK_TRY finally-only rethrow: bind catch, gosub finally, then throw.
        try Emitter.bindParser(s, label_catch);
        try Emitter.jumpNoSource(s, opcode.op.gosub, label_finally);
        try Emitter.opNoSource(s, opcode.op.throw);
    } else {
        return s.failUnexpectedToken();
    }

    // qjs TOK_TRY finally entry: bind label_finally.
    try Emitter.bindParser(s, label_finally);
    if (s.peekKind() == .kw_finally) {
        try s.advance();
        try emitter.parseSharedFinallyBlock(s);
    }
    // qjs TOK_TRY finally return: emit OP_ret.
    try Emitter.opNoSource(s, opcode.op.ret);
    // qjs TOK_TRY exit: bind label_end.
    try Emitter.bindParser(s, label_end);
}

fn parseDebuggerStatement(s: *State) Error!void {
    try s.advance();
    _ = try s.expectSemicolon();
}

fn parseEmptyStatement(s: *State) Error!void {
    // Empty statement
    try s.advance();
}

/// Expression statement, `quickjs.c`: in eval mode the completion
/// value is stored in `eval_ret_idx` so `eval()` can return it, otherwise
/// it is dropped. `<ret>` is a non-lexical slot, so the lowered bytecode
/// is just `put_loc <idx>` (or its short form).
fn parseExpressionStatement(s: *State) Error!void {
    try parseExpressionStatementTail(s);
}

/// The statement-shaped tail shared by every expression statement arm:
/// one grammar source event at the first token, the expression, ASI, and
/// the completion-value store or drop.
fn parseExpressionStatementTail(s: *State) Error!void {
    const keep_completion = expressionStatementKeepsCompletion(s);
    try emitter.emitGrammarSource(s, s.currentSourcePosition());
    try expressions.parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = keep_completion });
    _ = try s.expectSemicolon();
    try emitExpressionStatementCompletion(s, keep_completion);
}

fn emitExpressionStatementCompletion(s: *State, keep_completion: bool) Error!void {
    if (keep_completion) {
        try s.emitEvalRetPut();
    } else {
        try Emitter.opNoSource(s, opcode.op.drop);
    }
}

fn parseUsingDeclaration(s: *State, kind: DisposalHint) Error!void {
    const module_top_level = s.lex.is_module and
        s.top_level_lexical_as_module_ref and
        s.atProgramBodyScope();
    if (kind == .async and !s.ctx.in_async and !module_top_level) return Error.AwaitOutsideAsyncFunction;
    if (!module_top_level and s.atProgramBodyScope()) {
        return s.failWithMessage(null, "using declaration is not allowed at the top level of a script");
    }
    if (s.using_block_frames.items.len == 0) return Error.ParserInvariant;
    if (kind == .async) try s.advance(); // consume `await`
    try s.advance(); // consume `using`

    while (true) {
        if (!identifiers.isIdentifierLikeToken(s)) return s.failUnexpectedToken();
        if (identifiers.identifierLikeHasInvalidEscapeForBinding(s)) return s.failUnexpectedToken();
        const atom_id = identifiers.identifierLikeAtom(s);
        if (identifiers.atomNameEquals(s, atom_id, "let")) return s.failUnexpectedToken();
        if ((s.is_strict or s.curFunc().is_strict_mode) and
            (identifiers.atomNameEquals(s, atom_id, "eval") or identifiers.atomNameEquals(s, atom_id, "arguments")))
        {
            return s.failUnexpectedToken();
        }
        if (module_top_level and identifiers.hasKnownBinding(s, atom_id)) return s.failUnexpectedToken();
        _ = try declarations.defineVar(s, atom_id, .const_);
        try s.advance();

        if (s.peekKind() != .assign) return s.failExpectedToken(.assign);
        try s.advance();
        const stack_loc = try armCurrentUsingBlockFrame(s);
        try expressions.parseAssignExpr(s);
        try functions.setObjectName(s, atom_id);
        // zjs-only explicit-resource-management lowering: retain one
        // initializer value for the lexical binding and one resource.
        try Emitter.op(s, opcode.op.dup);
        try s.emitScopePutVarInit(atom_id);
        const resource_loc = try functions.appendAnonymousTempLocal(s);
        // zjs-only explicit-resource-management lowering: keep the
        // retained resource in the same anonymous local as legacy.
        try Emitter.opU16(s, opcode.op.put_loc, resource_loc);
        try emitUsingAddResource(s, kind, stack_loc, resource_loc);
        try noteUsingResourceHint(s, kind);
        try s.emitCloseLoc(resource_loc);

        if (s.peekKind() != .comma) break;
        try s.advance();
    }
}

fn canParseModuleDeclarationHere(s: *State) bool {
    return s.lex.is_module and s.atProgramBodyScope();
}

/// Mirrors QuickJS `is_let`, inverted: returns true when
/// a leading `let` token introduces an ExpressionStatement instead of a
/// lexical declaration. In qjs, `let [` never introduces an
/// ExpressionStatement; `let` followed by `{`, a non-reserved identifier,
/// `let`, `yield`, or `await` is a declaration when there is no
/// intervening line terminator OR when scanning for a Declaration
/// (decl_mask & DECL_MASK_OTHER). Anything else is an expression. In
/// strict mode qjs lexes `let` as TOK_LET and never consults is_let, so
/// `let` is always a declaration there.
pub fn canTreatLetAsExpressionStatement(s: *State, decl_mask: DeclMask) bool {
    if (s.is_strict or s.curFunc().is_strict_mode) return false;
    const saved_cursor = lookahead.takeLexerCursorSnapshot(s);
    const current_line = s.token.line_num;
    // The lexer restore must be armed before the fallible scan: `nextInto()`
    // moves `pos` past the peeked token before it can fail (the identifier
    // atom is interned last), so a failure that escaped this frame with the
    // restore still unarmed would leave the parser mid-token.
    defer lookahead.restoreLexerCursorSnapshot(s, saved_cursor);
    var peek_token = s.lex.next() catch return false;
    defer s.lex.freeToken(&peek_token);
    const val = peek_token.val;
    if (val == .lbracket) {
        // `let [` is a syntax restriction: it never introduces an
        // ExpressionStatement.
        return false;
    }
    // qjs checks `{`, non-reserved TOK_IDENT, TOK_LET, TOK_YIELD and
    // TOK_AWAIT. In sloppy mode qjs lexes the contextual keywords
    // (static, implements, interface, package, private, protected,
    // public) as plain identifiers (update_token_ident); zjs gives them
    // distinct tokens, so they are matched explicitly here.
    const declaration_start = val == .lbrace or
        val == .ident or
        val == .kw_let or
        val == .kw_yield or
        val == .kw_await or
        val == .kw_static or
        identifiers.isSloppyFutureReservedToken(val);
    if (declaration_start) {
        // Check for possible ASI if not scanning for a Declaration
        if (peek_token.line_num == current_line or decl_mask.other) return false;
        return true;
    }
    return true;
}

fn parseLetKeywordExpressionStatement(s: *State) Error!void {
    const keep_completion = expressionStatementKeepsCompletion(s);
    try emitter.emitGrammarSource(s, s.currentSourcePosition());
    try expressions.parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = keep_completion });
    // A leading sloppy-mode `let` is parsed as an IdentifierReference when
    // the following token cannot begin a lexical declaration. If that
    // expression leaves another same-line token behind, ASI cannot finish
    // the statement: the useful grammar expectation is the binding that a
    // lexical declaration would require, not the generic parser sentinel.
    if (s.peekKind() != .semicolon and
        !s.gotLineTerminator() and
        s.peekKind() != .eof and
        s.peekKind() != .rbrace)
    {
        return s.failExpectedDescription("binding name");
    }
    _ = try s.expectSemicolon();
    try emitExpressionStatementCompletion(s, keep_completion);
}

/// Mirror `js_parse_var`.
///
/// Registers each identifier in `function_def.vars` with the correct
/// `VarKind` / `is_lexical` / `is_const` flags so the full
/// FunctionDef-based pipeline can assign local slots, emit TDZ checks,
/// and synthesise closures. For `var`, the
/// variable is attached at the function's var/arg scope (level 0)
/// per QuickJS hoisting rules; for `let`/`const`, it attaches at the
/// current lexical scope.
pub fn needVarReference(s: *State, var_tok: tok.TokenKind) bool {
    if (var_tok != .kw_var) return false;

    const fd = s.curFunc();
    if (!s.is_strict and !fd.is_strict_mode and !s.lex.is_module) return true;

    const is_global_var = s.cur_func_stack.len == 0 and
        (!s.is_eval or s.eval_global_var_bindings);
    return is_global_var and !s.lex.is_module;
}

pub fn parseVar(s: *State, declared_tok: tok.TokenKind, export_decl: bool, parse_flags: ParseFlags) Error!void {
    // TypeScript `namespace N { var x }`: tsc scopes the binding to the
    // namespace's IIFE, so it is lowered as a block-level `let` here.
    const var_tok = if (s.ctx.in_namespace and declared_tok == .kw_var) .kw_let else declared_tok;
    const is_lexical = var_tok == .kw_let or var_tok == .kw_const;
    const is_const = var_tok == .kw_const;
    while (true) {
        const sloppy_keyword_var = (s.peekKind() == .kw_yield or
            s.peekKind() == .kw_static or
            s.peekKind() == .kw_let or
            s.peekKind() == .kw_await or
            identifiers.isSloppyFutureReservedBindingToken(s)) and
            !(s.is_strict or s.curFunc().is_strict_mode) and
            !(s.peekKind() == .kw_yield and s.ctx.in_generator) and
            !(s.peekKind() == .kw_await and !identifiers.canUseAwaitAsIdentifier(s));
        const binding_identifier = identifiers.isIdentifierLikeToken(s);
        if (binding_identifier or sloppy_keyword_var) {
            // Simple identifier binding
            const token_atom = if (s.peekKind() == .ident) s.token.payload.ident.atom else tok.keywordAtom(s.peekKind());
            // qjs js_parse_var takes its own `name` reference before
            // next_token frees the identifier token (quickjs.c:
            // Keep that owner through this declarator.
            const atom_id = token_atom;
            if (binding_identifier and s.peekKind() == .ident and
                identifiers.escapedIdentifierIsReservedWordForBinding(s, atom_id, s.token.payload.ident.has_escape))
            {
                return s.failUnexpectedToken();
            }
            if (is_lexical and identifiers.atomNameEquals(s, atom_id, "let")) return s.failUnexpectedToken();
            if ((s.is_strict or s.curFunc().is_strict_mode) and
                (identifiers.atomNameEquals(s, atom_id, "eval") or identifiers.atomNameEquals(s, atom_id, "arguments")))
            {
                return s.failUnexpectedToken();
            }
            var local_lexical_idx: ?u16 = null;
            try s.advance();
            // TypeScript `let x!: T` / `let x: T`.
            if (s.peekKind() == .bang and !s.gotLineTerminator()) try s.advance();
            try typescript.tsParseTypeAnnotationOpt(s);

            // Imported/module-declaration names are represented outside
            // vars/global_vars until module resolution.  Preserve that
            // QJS module-name collision at the token wrapper boundary;
            // all ordinary declaration collisions are owned by defineVar.
            if (is_lexical and s.top_level_lexical_as_module_ref and s.atProgramBodyScope() and identifiers.hasKnownBinding(s, atom_id)) {
                return s.failUnexpectedToken();
            }

            var hoisted_arguments_var_idx: ?u16 = null;
            if (!is_lexical and identifiers.atomNameEquals(s, atom_id, "arguments") and
                s.curFunc().func_type != .arrow and
                s.curFunc().func_type != .class_static_init and
                s.curFunc().has_parameter_expressions and
                s.curFunc().arguments_var_idx != null and
                s.curFunc().arguments_arg_idx == null)
            {
                hoisted_arguments_var_idx = s.curFunc().arguments_var_idx.?;
                try functions.ensureParameterArgumentsLocals(s.curFunc());
            }

            const defined = try declarations.defineVar(s, atom_id, if (is_lexical)
                (if (is_const) .const_ else .let_)
            else
                .var_);
            if (is_lexical) {
                switch (defined) {
                    .local => |idx| {
                        local_lexical_idx = idx;
                        if (s.emit_lexical_tdz_at_decl) {
                            s.curFunc().vars[idx].tdz_emitted_at_decl = true;
                        }
                    },
                    .global => {},
                    .argument => unreachable,
                }
            } else if (identifiers.atomNameEquals(s, atom_id, "arguments")) {
                switch (defined) {
                    .local => |idx| s.curFunc().arguments_var_idx = hoisted_arguments_var_idx orelse idx,
                    .argument => {},
                    .global => {},
                }
            }
            if (export_decl) try modules.addModuleExportName(s, atom_id, atom_id);

            // No decl-time set_loc_uninitialized: the enter_scope lowering
            // (qjs OP_enter_scope, writeEnterScopeRefresh) owns the single
            // TDZ arming, exactly as in QuickJS resolve_variables. Emitting
            // here again produced a duplicate arming per for-head lexical.

            // Check for initializer
            if (s.peekKind() == .assign) {
                const initializer_source = s.currentSourcePosition();
                try s.advance();
                const capture_reference = needVarReference(s, var_tok);
                var declaration_lvalue: ?LValue = null;
                defer if (declaration_lvalue) |*lvalue| lvalue.deinit(s);
                if (capture_reference) {
                    // qjs js_parse_var emits the ordinary getter and lets
                    // get_lvalue decide whether a with-scope reference is
                    // required. This keeps declaration assignment on the
                    // same descriptor and exact label target as ordinary
                    // assignment; no unpatched scope_make_ref is exposed
                    // to the resolver.
                    try s.emitScopeGetVar(atom_id);
                    declaration_lvalue = try expressions.getLValue(s, false);
                }
                try expressions.parseAssignExpr2(s, parse_flags);
                try functions.setObjectName(s, atom_id);
                // QJS pins this source event to the `=` token and then emits
                // put_lvalue/the direct put without another source marker.
                const emission_snapshot = s.activeBuilder().snapshot();
                errdefer s.activeBuilder().rollback(emission_snapshot);
                try Emitter.addSourceMarker(s, initializer_source.line_num, initializer_source.col_num);
                if (declaration_lvalue) |*lvalue| {
                    try expressions.putLValue(s, lvalue, .no_keep);
                } else if (is_lexical) {
                    try s.emitScopePutVarInitNoSource(atom_id);
                } else {
                    try s.emitScopePutVarNoSource(atom_id);
                }
            } else {
                // const requires initializer
                if (var_tok == .kw_const) {
                    return s.failExpectedToken(.assign);
                }
                // `let x;` (no initializer) implicitly initialises to
                // undefined. We emit `undefined; scope_put_var_init`
                // so the slot is properly marked initialised — the
                // pipeline lowers this to `put_loc_check_init` for
                // lexical locals (clears TDZ flag) or `put_var_init`
                // for global lexical vars.
                if (var_tok == .kw_let) {
                    try Emitter.op(s, opcode.op.undefined);
                    try s.emitScopePutVarInit(atom_id);
                }
            }
            try typescript.emitNamespaceExportIfExported(s, atom_id);
        } else if (s.peekKind() == .lbracket or s.peekKind() == .lbrace) {
            try Emitter.op(s, opcode.op.undefined);
            const has_initializer = try functions.parseDestructuringElement(s, .{ .binding = .{
                .define_type = if (is_lexical)
                    (if (is_const) .const_ else .let_)
                else
                    .var_,
                .is_parameter = false,
                .export_flag = export_decl,
            } }, .{ .has_value = true, .allow_outer_initializer = true }, parse_flags);
            if (!has_initializer) return s.failExpectedToken(.assign);
        } else {
            return s.failExpectedDescription("binding name");
        }

        // Check for comma (multiple declarations)
        if (s.peekKind() != .comma) break;
        try s.advance();
    }
}

fn parseWith(s: *State) Error!void {
    if (s.is_strict or s.curFunc().is_strict_mode) return s.failUnexpectedToken();
    try s.advance();
    try s.expectToken(.lparen);
    try expressions.parseExpr(s);
    try s.expectToken(.rparen);

    try s.pushScope();
    errdefer s.popScopeIdentity();
    const with_atom = atom_module.ids.with_object;
    const with_idx: u16 = switch (try declarations.defineVar(s, with_atom, .with_)) {
        .local => |idx| idx,
        else => unreachable,
    };
    // qjs TOK_WITH lowering: coerce the
    // expression and store the with-object binding at the same source.
    try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.to_object);
    try Emitter.opU16(s, opcode.op.put_loc, with_idx);

    const saved_with_atom = s.active_with_atom;
    s.active_with_atom = with_atom;
    defer {
        s.active_with_atom = saved_with_atom;
    }
    try s.setEvalReturnUndefined();
    try parseStatementOrDecl(s, DeclMask{});
    try s.popScope();
}

fn declareForInOfVarBinding(s: *State, atom_id: Atom) Error!void {
    const defined = try declarations.defineVar(s, atom_id, .var_);
    if (identifiers.atomNameEquals(s, atom_id, "arguments") and s.curFunc().has_arguments_binding) {
        switch (defined) {
            .local => |idx| s.curFunc().arguments_var_idx = idx,
            .argument, .global => {},
        }
    }
}

/// Parse for-in or for-of loop
/// Mirrors `js_parse_for_in_of` in quickjs.c
/// What the head of `for (target in/of rhs)` bound, for the loop lowering.
const ForInOfTarget = struct {
    atom: ?Atom = null,
    is_lexical_decl: bool = false,
    is_pattern: bool = false,
    is_using_decl: bool = false,
    using_kind: DisposalHint = .sync,
    /// Sloppy `for (var x = init in ...)`: the Annex B initializer target.
    var_initializer_atom: ?Atom = null,
    /// `for (using x of ...)`: temp local holding the iteration value.
    using_value_loc: ?u16 = null,
    /// `for (f() of ...)`: the call is evaluated and then rejected.
    invalid_assignment_target: bool = false,
};

/// `for (using x of ...)` / `for (await using x of ...)`.
fn parseForInOfUsingTarget(s: *State, using_kind: DisposalHint, target: *ForInOfTarget) Error!void {
    target.using_kind = using_kind;
    if (using_kind == .async) {
        if (!s.ctx.in_async and !(s.lex.is_module and s.cur_func_stack.len == 0)) {
            return Error.AwaitOutsideAsyncFunction;
        }
        try s.advance();
    }
    try s.advance();
    if (!identifiers.isIdentifierLikeToken(s) or identifiers.identifierLikeHasInvalidEscapeForBinding(s)) {
        return s.failExpectedDescription("binding name");
    }
    const atom_id = identifiers.identifierLikeAtom(s);
    if (identifiers.atomNameEquals(s, atom_id, "let")) return s.failUnexpectedToken();
    if ((s.is_strict or s.curFunc().is_strict_mode) and
        (identifiers.atomNameEquals(s, atom_id, "eval") or identifiers.atomNameEquals(s, atom_id, "arguments")))
    {
        return s.failUnexpectedToken();
    }
    _ = try declarations.defineVar(s, atom_id, .const_);
    target.atom = atom_id;
    target.is_lexical_decl = true;
    target.is_using_decl = true;
    try s.advance();
    if (s.peekKind() == .assign) return s.failUnexpectedToken();

    const value_loc = try functions.appendAnonymousTempLocal(s);
    target.using_value_loc = value_loc;
    try Emitter.opU16(s, opcode.op.put_loc, value_loc);
}

/// `for (var|let|const binding in/of ...)`.
fn parseForInOfDeclarationTarget(s: *State, var_tok: tok.TokenKind, target: *ForInOfTarget) Error!void {
    try s.advance();
    const is_lexical = var_tok == .kw_let or var_tok == .kw_const;
    const is_const = var_tok == .kw_const;
    target.is_lexical_decl = is_lexical;

    if (s.peekKind() == .lbracket or
        s.peekKind() == .lbrace)
    {
        target.is_pattern = true;
        _ = try functions.parseDestructuringElement(s, .{ .binding = .{
            .define_type = if (is_lexical)
                (if (is_const) .const_ else .let_)
            else
                .var_,
            .is_parameter = false,
            .export_flag = false,
        } }, .{ .has_value = true }, ParseFlags.default);
    } else {
        // Must match parseVar's full sloppy_keyword_var predicate
        // (quickjs.c update_token_ident is the one qjs gate, so
        // js_parse_var and js_parse_for_in_of cannot diverge).
        const sloppy_keyword_var = var_tok == .kw_var and
            (s.peekKind() == .kw_yield or s.peekKind() == .kw_static or
                s.peekKind() == .kw_let or s.peekKind() == .kw_await or
                identifiers.isSloppyFutureReservedBindingToken(s)) and
            !(s.is_strict or s.curFunc().is_strict_mode) and
            !(s.peekKind() == .kw_yield and s.ctx.in_generator) and
            !(s.peekKind() == .kw_await and !identifiers.canUseAwaitAsIdentifier(s));
        if (!identifiers.isIdentifierLikeToken(s) and !sloppy_keyword_var) return s.failExpectedDescription("binding name");
        if (identifiers.identifierLikeHasInvalidEscapeForBinding(s)) return s.failUnexpectedToken();
        const atom_id = identifiers.identifierLikeAtom(s);
        if (is_lexical and identifiers.atomNameEquals(s, atom_id, "let")) return s.failUnexpectedToken();
        if ((s.is_strict or s.curFunc().is_strict_mode) and
            (identifiers.atomNameEquals(s, atom_id, "eval") or identifiers.atomNameEquals(s, atom_id, "arguments")))
        {
            return s.failUnexpectedToken();
        }
        if (is_lexical) {
            _ = try declarations.defineVar(s, atom_id, if (is_const) .const_ else .let_);
        } else {
            try declareForInOfVarBinding(s, atom_id);
            target.var_initializer_atom = atom_id;
        }
        target.atom = atom_id;
        try s.advance();
        if (is_lexical) {
            try s.emitScopePutVarInit(atom_id);
        } else {
            try s.emitScopePutVar(atom_id);
        }
    }
}

/// `for (lhs in/of ...)` with an assignment target or a pattern.
fn parseForInOfExpressionTarget(s: *State, var_tok: tok.TokenKind, is_for_await: bool, expr_label: compiler.LabelId, assign_label: compiler.LabelId, target: *ForInOfTarget) Error!void {
    if (!is_for_await and var_tok == .ident and
        !s.token.payload.ident.has_escape and
        identifiers.atomNameEquals(s, s.token.payload.ident.atom, "async") and
        s.peekNextIsOfToken())
    {
        return s.failUnexpectedToken();
    }

    const is_pattern = if (var_tok == .lbracket or
        var_tok == .lbrace)
    blk: {
        const topology = try functions.scanPatternTopology(s);
        break :blk topology.following == .kw_in or
            topology.following == .ident or
            topology.following == .assign;
    } else false;

    if (is_pattern) {
        target.is_pattern = true;
        _ = try functions.parseDestructuringElement(s, .assignment, .{ .has_value = true, .allow_outer_initializer = true }, ParseFlags.default);
    } else {
        try expressions.parseLhsExpr(s, .{ .in_accepted = false });
        var lvalue = try expressions.getLValue(s, false);
        defer lvalue.deinit(s);
        if (lvalue.invalid_call) {
            // The initial jump normally skips the target until the
            // iterator has produced a value. A runtime-invalid call
            // target is different: evaluate the call immediately,
            // then throw before touching the RHS iterable.
            target.invalid_assignment_target = true;
            // V2 never rewrites a jump's PC. The entry goto and the
            // target block are now ONE program point, so the pending
            // reference moves onto the identity that already denotes
            // it (`retargetLabelRefs`).
            try Emitter.retargetLabel(s, expr_label, assign_label);
            try expressions.emitInvalidAssignmentTarget(s);
        } else {
            try expressions.putLValue(s, &lvalue, .no_keep_bottom);
        }
    }
}

fn parseForInOf(s: *State, is_for_await: bool) Error!void {
    const block_scope_level = s.scope_level;
    const var_tok = s.peekKind();
    var target: ForInOfTarget = .{};

    var for_scope = try s.openScope();
    errdefer for_scope.pop(s);

    var expr_label: compiler.LabelId = undefined;
    var assign_label: compiler.LabelId = undefined;
    // qjs js_parse_for_in_of: goto label_expr; label_assign bound at the
    // one-pass target block (backward if_false re-enters it).
    expr_label = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.goto, expr_label);
    assign_label = try Emitter.newLabel(s);
    try Emitter.bind(s, assign_label);

    const let_as_identifier = var_tok == .kw_let and
        !s.is_strict and !s.curFunc().is_strict_mode and
        s.peekNextKind() == .kw_in;
    const direct_using_kind = directUsingDeclarationKind(s);
    const parse_using_decl = if (direct_using_kind) |using_kind|
        using_kind == .async or !(try usingDeclarationBindingIsOf(s, using_kind))
    else
        false;

    if (parse_using_decl) {
        try parseForInOfUsingTarget(s, direct_using_kind.?, &target);
    } else if ((var_tok == .kw_var or var_tok == .kw_let or var_tok == .kw_const) and
        !let_as_identifier)
    {
        try parseForInOfDeclarationTarget(s, var_tok, &target);
    } else {
        try parseForInOfExpressionTarget(s, var_tok, is_for_await, expr_label, assign_label, &target);
    }

    var body_label: compiler.LabelId = undefined;
    body_label = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.goto, body_label);
    // An invalid call target already consumed `expr_label` by
    // retargeting it onto the assignment boundary (which also bound
    // it); binding it again would be a double bind.
    if (!target.invalid_assignment_target) try Emitter.bind(s, expr_label);

    // Annex-B legacy initializer: only sloppy non-lexical simple
    // for-in declarations accept it.
    var has_var_initializer = false;
    if (s.peekKind() == .assign) {
        if (target.var_initializer_atom == null or target.is_pattern or
            target.is_lexical_decl or s.is_strict or s.curFunc().is_strict_mode)
        {
            return s.failUnexpectedToken();
        }
        has_var_initializer = true;
        try s.advance();
        try expressions.parseAssignExpr2(s, ParseFlags{ .in_accepted = false });
        try s.emitScopePutVar(target.var_initializer_atom.?);
    }

    const in_of_tok = s.peekKind();
    const is_for_of = s.isOfToken();
    if (in_of_tok != .kw_in and !is_for_of) return s.failExpectedDescription("'in' or 'of'");
    if (target.is_using_decl and !is_for_of) return s.failUnexpectedToken();
    if (has_var_initializer and is_for_of) return s.failUnexpectedToken();
    if (is_for_await and !is_for_of) return s.failUnexpectedToken();
    try s.advance();

    if (is_for_of) {
        try expressions.parseAssignExpr(s);
    } else {
        try expressions.parseExpr(s);
    }
    try s.closeScopes(s.scope_level, block_scope_level);
    try s.expectToken(.rparen);

    if (is_for_of) {
        try Emitter.op(s, if (is_for_await) opcode.op.for_await_of_start else opcode.op.for_of_start);
    } else {
        try Emitter.op(s, opcode.op.for_in_start);
    }

    var next_label: compiler.LabelId = undefined;
    next_label = try Emitter.newLabel(s);
    try Emitter.jump(s, opcode.op.goto, next_label);
    try Emitter.bind(s, body_label);

    const loop_label = s.pending_label_atom;
    s.pending_label_atom = null;
    try emitter.pushBreakFrame(s);
    if (is_for_of) {
        emitter.setCurrentBreakCleanupDrops(s, if (is_for_await) shared_iterator_close_marker else direct_iterator_close_marker);
    } else {
        emitter.setCurrentBreakCleanupDrops(s, 1);
    }
    const label_frame = if (loop_label) |atom_id| try s.pushLabelFrame(atom_id, true) else null;

    var loop_block: BlockEnv = undefined;
    emitter.pushControlBlock(s, &loop_block, .{ .label = loop_label, .has_break_target = true, .has_continue_target = true, .scope_level = block_scope_level, .drop_count = if (is_for_of) 3 else 1, .has_iterator = is_for_of });
    defer emitter.popControlBlock(s, &loop_block);

    var iteration_using_block: ?OpenUsingBlock = null;
    errdefer if (iteration_using_block) |*block| block.unwind(s);
    if (target.is_using_decl) {
        iteration_using_block = try openUsingBlock(s);
        const stack_loc = try armCurrentUsingBlockFrame(s);

        const atom_id = target.atom orelse return Error.ParserInvariant;
        const value_loc = target.using_value_loc orelse return Error.ParserInvariant;
        // zjs-only `for (using ... of ...)` lowering: mirror the
        // legacy iteration-value load and duplicate exactly.
        try Emitter.opU16(s, opcode.op.get_loc, value_loc);
        try Emitter.op(s, opcode.op.dup);
        try s.emitScopePutVarInit(atom_id);
        const resource_loc = try functions.appendAnonymousTempLocal(s);
        // zjs-only `for (using ... of ...)` lowering: retain the
        // resource in the same anonymous local as legacy.
        try Emitter.opU16(s, opcode.op.put_loc, resource_loc);
        try emitUsingAddResource(s, target.using_kind, stack_loc, resource_loc);
        try noteUsingResourceHint(s, target.using_kind);
        try s.emitCloseLoc(resource_loc);
        try s.emitCloseLoc(value_loc);
    }

    try parseStatementOrDecl(s, DeclMask{});

    if (iteration_using_block) |*block| try block.finalize(s);

    try s.closeScopes(s.scope_level, block_scope_level);
    try emitter.patchContinueFrame(s);
    if (label_frame) |idx| try s.patchLabelContinues(idx);
    try Emitter.bind(s, next_label);
    if (is_for_of) {
        if (is_for_await) {
            try Emitter.opNoSource(s, opcode.op.for_await_of_next);
            try Emitter.opNoSource(s, opcode.op.await);
            try Emitter.opNoSource(s, opcode.op.iterator_get_value_done);
        } else {
            try Emitter.opU8(s, opcode.op.for_of_next, 0);
        }
    } else {
        try Emitter.op(s, opcode.op.for_in_next);
    }

    if (is_for_await) {
        try Emitter.jumpNoSource(s, opcode.op.if_false, assign_label);
    } else {
        try Emitter.jump(s, opcode.op.if_false, assign_label);
    }

    if (is_for_await) {
        try Emitter.opNoSource(s, opcode.op.drop);
        try emitter.popBreakFrameAndPatch(s);
        try Emitter.opNoSource(s, opcode.op.iterator_close);
    } else if (is_for_of) {
        try Emitter.op(s, opcode.op.drop);
        try Emitter.op(s, opcode.op.iterator_close);
        try emitter.popBreakFrameAndPatch(s);
    } else {
        try Emitter.op(s, opcode.op.drop);
        try Emitter.op(s, opcode.op.drop);
        try emitter.popBreakFrameAndPatch(s);
    }
    if (label_frame) |idx| {
        try s.patchLabelBreaks(idx);
        s.popLabelFrame(idx);
    }
    try for_scope.close(s);
}
