//! Speculative lookahead: cursor and parser snapshots, balanced scans, arrow-head probes.

const std = @import("std");
const root = @import("../parser.zig");
const atom_module = @import("../core/atom.zig");
const simple_token = @import("../simple_token.zig");
const lexer_mod = root.lexer;
const tok = root.token;
const diagnostics = root.diagnostics;
const parse_state = @import("parse_state.zig");
const identifiers = @import("identifiers.zig");
const typescript = @import("typescript.zig");
const Error = parse_state.Error;
const State = parse_state.State;

/// Check if `<ident> =>` is the arrow function head shape.
/// Saves and restores lexer position so the cached token stays valid.
pub fn checkIdentArrowHead(s: *State) Error!bool {
    if (s.lex.simpleNextIsArrowNoLineTerminator()) |matched| return matched;

    const snapshot = takeLexerCursorSnapshot(s);
    defer restoreLexerCursorSnapshot(s, snapshot);

    const peek_kind = nextRegexpAwareLookaheadKind(s, s.peekKind()) catch |err| return lookaheadErrorAsNoMatch(err);
    return peek_kind == .arrow and !s.lex.gotLineTerminator();
}

/// QuickJS enters this path only after
/// `token_is_pseudo_keyword(JS_ATOM_async)` succeeds. Keep that atom-id
/// gate at the caller so ordinary identifiers never take a speculative
/// lexer snapshot here.
pub fn checkAsyncArrowHeadAfterAsync(s: *State, return_type_forbidden: bool) Error!bool {
    std.debug.assert(s.isAsyncIdentifier());

    const snapshot = takeLexerCursorSnapshot(s);
    defer restoreLexerCursorSnapshot(s, snapshot);

    const param_kind = nextRegexpAwareLookaheadKind(s, s.peekKind()) catch |err| return lookaheadErrorAsNoMatch(err);
    if (s.lex.gotLineTerminator()) return false;
    if (param_kind == .lt or param_kind == .shl) {
        // TypeScript `async <T>(...) => body`.
        restoreLexerCursorSnapshot(s, snapshot);
        const spec = try typescript.tsBeginSpeculation(s);
        defer typescript.tsRollback(s, spec);
        s.advance() catch |err| return lookaheadErrorAsNoMatch(err);
        return typescript.tsGenericArrowHead(s, return_type_forbidden);
    }
    // qjs `update_token_ident` keeps sloppy
    // context keywords as TOK_IDENT. zjs lexes them as dedicated kinds,
    // so AsyncArrowBindingIdentifier must accept those kinds here.
    if (isAsyncArrowBindingIdentifierKind(s, param_kind)) {
        const arrow_kind = nextRegexpAwareLookaheadKind(s, param_kind) catch |err| return lookaheadErrorAsNoMatch(err);
        if (s.lex.gotLineTerminator()) return false;
        return arrow_kind == .arrow;
    }
    if (param_kind != .lparen) return false;
    const balanced = scanBalancedAfterOpening(s, param_kind, true) catch |err| return lookaheadErrorAsNoMatch(err);
    if (!balanced.closed) return false;
    if (balanced.following == .arrow) return true;
    if (balanced.following == .colon and !return_type_forbidden) {
        // TypeScript `async (...): R => body`.
        restoreLexerCursorSnapshot(s, snapshot);
        const spec = try typescript.tsBeginSpeculation(s);
        defer typescript.tsRollback(s, spec);
        s.advance() catch |err| return lookaheadErrorAsNoMatch(err);
        return typescript.tsParenArrowHeadWithReturnType(s);
    }
    return false;
}

/// AsyncArrowBindingIdentifier in sloppy non-generator. Keep `await`
/// rejected: +Await makes it illegal even though qjs accepts
/// `async await => 1` at sloppy top-level.
fn isAsyncArrowBindingIdentifierKind(s: *State, kind: tok.Kind) bool {
    if (kind == .ident) return true;
    if (s.isStrict()) return false;
    return switch (kind) {
        .kw_yield => !s.ctx.in_generator,
        .kw_static, .kw_let => true,
        else => identifiers.isSloppyFutureReservedToken(kind),
    };
}

/// Check if we're at an arrow function head
/// Mirrors `js_parse_skip_parens_token` in quickjs.c.
///
/// Saves the lexer position, scans forward with scratch tokens, then
/// restores the lexer so the cached parser token remains valid.
pub fn checkArrowHead(s: *State, return_type_forbidden: bool) Error!bool {
    if (s.peekKind() == .lparen) {
        if (s.lex.simpleCurrentParenIsArrowHead()) |matched| return matched;
        const balanced = scanBalancedToken(s, true) catch |err| return lookaheadErrorAsNoMatch(err);
        if (!balanced.closed) return false;
        if (balanced.following == .arrow) return true;
        if (return_type_forbidden) return false;
        // TypeScript `(...): R => body`; only `=>` must stay on the line, so
        // the return-type colon may follow a line break.
        if (balanced.following == .colon) return typescript.tsParenArrowHeadWithReturnType(s);
        if (balanced.following == .newline) {
            const across_lines = scanBalancedToken(s, false) catch |err| return lookaheadErrorAsNoMatch(err);
            if (across_lines.closed and across_lines.following == .colon) return typescript.tsParenArrowHeadWithReturnType(s);
        }
        return false;
    }
    if (s.peekKind() == .ident) return try checkIdentArrowHead(s);
    return false;
}

pub fn lookaheadErrorAsNoMatch(err: Error) Error!bool {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => false,
    };
}

const DiagnosticToken = struct {
    kind: tok.Kind,
    position: diagnostics.Position,
};

fn diagnosticTokenFromToken(found_token: *const tok.Token) DiagnosticToken {
    return .{
        .kind = found_token.kind,
        .position = .{
            .offset = found_token.start,
            .line = found_token.line_num,
            .column = found_token.col_num,
        },
    };
}

pub fn mapLookaheadLexerError(s: *State, err: lexer_mod.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => s.failWithMessage(.{
            .offset = s.lex.mark_pos,
            .line = s.lex.mark_line,
            .column = s.lex.mark_col,
        }, State.decoratorDiagnosticMessage(s.lex.source, err, s.lex.mark_pos) orelse State.failureMessage(err)),
    };
}

pub fn peekNextDiagnosticToken(s: *State) Error!DiagnosticToken {
    const snapshot = takeLexerCursorSnapshot(s);
    defer restoreLexerCursorSnapshot(s, snapshot);
    var next = s.lex.next() catch |err| return mapLookaheadLexerError(s, err);
    defer s.lex.freeToken(&next);
    return diagnosticTokenFromToken(&next);
}

/// One token past the lexer cursor. `null` is a non-fatal lexer error, the
/// same "no match" the speculative peeks already returned. OutOfMemory and
/// StackOverflow propagate. The caller frees a returned token. This does not
/// restore the cursor, so one snapshot can cover several calls; arm that
/// restore before the first call, because `nextInto` advances `pos` before an
/// identifier intern can fail.
pub fn peekAhead(s: *State) Error!?tok.Token {
    if (s.runtime) |rt| {
        if (rt.stack.checkNativeOverflow(0)) return error.StackOverflow;
    }
    const next = s.lex.next() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return next;
}

/// QuickJS `js_parse_skip_parens_token` keeps one `JSToken` in parse state
/// and returns only the following token kind. Keep the speculative token
/// owned inside this helper as well: callers never need its 80-byte payload,
/// and returning it by value otherwise copies that payload at every step of
/// a long parenthesized lookahead.
fn nextRegexpAwareLookaheadKind(s: *State, previous_token_kind: ?tok.Kind) Error!tok.Kind {
    var lookahead_token = s.lex.next() catch |err| return mapLookaheadLexerError(s, err);
    defer s.lex.freeToken(&lookahead_token);
    try rescanLookaheadTokenIfRegexp(s, &lookahead_token, previous_token_kind);
    return lookahead_token.kind;
}

fn rescanLookaheadTokenIfRegexp(s: *State, lookahead_token: *tok.Token, previous_token_kind: ?tok.Kind) Error!void {
    if (!(lookahead_token.kind == .slash or lookahead_token.kind == .div_assign)) return;
    if (!predeclareSlashStartsRegexp(s, previous_token_kind)) return;

    s.lex.freeToken(lookahead_token);
    s.lex.rescanLastSlashAsRegexpInto(lookahead_token) catch |err| return mapLookaheadLexerError(s, err);
}

/// Delimiters seen by a brace-body scan, so `of` can be classified only at
/// the top of the paren `for (` or `for await (` opened.
pub const ForHeadDelim = struct {
    frames: std.ArrayList(Frame) = .empty,
    allocator: std.mem.Allocator,

    const Frame = struct {
        opener: tok.Kind,
        for_head: bool,
    };

    pub fn init(allocator: std.mem.Allocator) ForHeadDelim {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ForHeadDelim) void {
        self.frames.deinit(self.allocator);
    }

    pub fn atForHead(self: *const ForHeadDelim) bool {
        if (self.frames.items.len == 0) return false;
        return self.frames.items[self.frames.items.len - 1].for_head;
    }

    pub fn onToken(self: *ForHeadDelim, kind: tok.Kind, previous: ?tok.Kind, before_previous: ?tok.Kind) Error!void {
        switch (kind) {
            .lparen, .lbracket, .lbrace => {
                try self.frames.append(self.allocator, .{
                    .opener = kind,
                    .for_head = kind == .lparen and forParenOpener(previous, before_previous),
                });
            },
            .rparen, .rbracket, .rbrace => {
                if (self.frames.items.len == 0) return;
                const top = self.frames.items[self.frames.items.len - 1];
                if (closerOf(top.opener) != kind) return;
                _ = self.frames.pop();
            },
            else => {},
        }
    }
};

fn forParenOpener(previous: ?tok.Kind, before_previous: ?tok.Kind) bool {
    const prev = previous orelse return false;
    if (prev == .kw_for) return true;
    const earlier = before_previous orelse return false;
    return prev == .kw_await and earlier == .kw_for;
}

/// The lexer keeps `of` as `.ident`. Inside a for-head this is `.kw_of`
/// after a finished left-hand side, matching `forHeadSlashPrevious`.
pub fn contextualOfKind(s: *State, token: *const tok.Token, previous: ?tok.Kind, at_for_head: bool) tok.Kind {
    if (!at_for_head) return token.kind;
    if (!identifiers.tokenIsPlainName(s, token, "of")) return token.kind;
    const prev = previous orelse return token.kind;
    return switch (prev) {
        .ident,
        .rparen,
        .rbracket,
        .rbrace,
        .kw_yield,
        .kw_await,
        .kw_static,
        .kw_implements,
        .kw_interface,
        .kw_package,
        .kw_private,
        .kw_protected,
        .kw_public,
        => .kw_of,
        else => token.kind,
    };
}

/// Skip the function a `function` token heads, the lexer sitting just past
/// that token. A token-level scan also meets `function` as a property name
/// (`e.function`, `{ function: 1 }`, a class field `function = 1`); those
/// head nothing and are left for the caller to scan past as a plain token.
pub fn skipFunctionInPredeclareScan(s: *State, before_keyword: ?tok.Kind) Error!void {
    if (s.runtime) |rt| {
        if (rt.stack.checkNativeOverflow(0)) return error.StackOverflow;
    }
    if (before_keyword) |previous| {
        if (previous == .dot or previous == .question_mark_dot) return;
    }
    const after_keyword = takeLexerCursorSnapshot(s);
    const next_kind = blk: {
        var next = try s.lex.next();
        defer s.lex.freeToken(&next);
        break :blk next.kind;
    };
    restoreLexerCursorSnapshot(s, after_keyword);
    switch (next_kind) {
        .colon, .comma, .rbrace, .rparen, .rbracket, .semicolon, .assign, .question => return,
        else => {},
    }
    while (true) {
        var t = try s.lex.next();
        defer s.lex.freeToken(&t);
        if (t.kind == .eof) return;
        if (t.kind == .lbrace) break;
    }
    var depth: usize = 1;
    var previous_token_kind: ?tok.Kind = .lbrace;
    var before_previous: ?tok.Kind = null;
    var for_head = ForHeadDelim.init(s.scratch);
    defer for_head.deinit();
    while (depth != 0) {
        var t = try s.lex.next();
        defer s.lex.freeToken(&t);
        if (try skipOpaqueLiteral(s, t, previous_token_kind)) |skipped| {
            before_previous = previous_token_kind;
            previous_token_kind = skipped;
            continue;
        }
        switch (t.kind) {
            .eof => return,
            .lbrace => depth += 1,
            .rbrace => depth -= 1,
            else => {},
        }
        const at_for_head = for_head.atForHead();
        try for_head.onToken(t.kind, previous_token_kind, before_previous);
        before_previous = previous_token_kind;
        previous_token_kind = contextualOfKind(s, &t, previous_token_kind, at_for_head);
    }
}

pub fn skipTemplateInPredeclareScan(s: *State, first: tok.Token) Error!void {
    // Nested substitutions recurse; bound the native stack like `advance`.
    if (s.runtime) |rt| {
        if (rt.stack.checkNativeOverflow(0)) return error.StackOverflow;
    }
    const first_part = first.payload.str.template orelse return Error.ParserInvariant;
    switch (first_part) {
        .no_substitution, .tail => return,
        .head, .middle => {},
    }

    while (true) {
        var expr_depth: usize = 0;
        var previous_token_kind: ?tok.Kind = .lbrace;
        while (true) {
            var t = try s.lex.next();
            defer s.lex.freeToken(&t);
            if (try skipOpaqueLiteral(s, t, previous_token_kind)) |skipped| {
                previous_token_kind = skipped;
                continue;
            }
            switch (t.kind) {
                .eof => {
                    return;
                },
                .kw_function => try skipFunctionInPredeclareScan(s, previous_token_kind),
                .lbrace, .lparen, .lbracket => expr_depth += 1,
                .rbrace, .rparen, .rbracket => {
                    if (t.kind == .rbrace and expr_depth == 0) {
                        break;
                    }
                    if (expr_depth != 0) expr_depth -= 1;
                },
                else => {},
            }
            previous_token_kind = t.kind;
        }

        var next_part: tok.Token = undefined;
        try s.lex.nextTemplatePartAfterBraceInto(&next_part);
        defer s.lex.freeToken(&next_part);
        const part = next_part.payload.str.template orelse return Error.ParserInvariant;
        switch (part) {
            .tail, .no_substitution => return,
            .head, .middle => continue,
        }
    }
}

pub fn skipRegexpInPredeclareScan(s: *State, previous_token_kind: ?tok.Kind) Error!bool {
    if (!predeclareSlashStartsRegexp(s, previous_token_kind)) return false;

    var regexp_token: tok.Token = undefined;
    try s.lex.rescanLastSlashAsRegexpInto(&regexp_token);
    defer s.lex.freeToken(&regexp_token);
    return true;
}

/// Skip one template or a `/` that starts a regexp in this context.
/// Null means the token stays (a dividing slash). Callers that only
/// pre-scan must not turn `error.OutOfMemory` into "not a regexp".
pub fn skipOpaqueLiteral(s: *State, token: tok.Token, prev: ?tok.Kind) Error!?tok.Kind {
    if (token.kind == .template) {
        try skipTemplateInPredeclareScan(s, token);
        return .template;
    }
    if (identifiers.tokenCanStartSlashRegexp(token.kind) and try skipRegexpInPredeclareScan(s, prev)) {
        return .regexp;
    }
    return null;
}

fn predeclareSlashStartsRegexp(s: *State, previous_token_kind: ?tok.Kind) bool {
    const previous = previous_token_kind orelse return true;
    // Sloppy `yield` / non-async `await` are identifiers, so `/` divides.
    // A generator or async function still starts a regexp after the keyword.
    if (previous == .kw_yield and !s.ctx.in_generator and !s.isStrict()) {
        return false;
    }
    if (previous == .kw_await and identifiers.canUseAwaitAsIdentifier(s)) {
        return false;
    }
    // `of` is lexed as `.ident`. One kind cannot mean both `for (x of /re/)`
    // and `of / g`, so only a caller that has already classified the
    // contextual keyword passes `.kw_of`.
    if (previous == .kw_of) return true;
    return tok.slashAfterStartsRegexp(previous);
}

pub const LexerCursorSnapshot = struct {
    pos: usize,
    line: u32,
    col: u32,
    got_lf: bool,
    mark_pos: usize,
    mark_line: u32,
    mark_col: u32,
};

pub const ParserSnapshot = struct {
    cursor: LexerCursorSnapshot,
    token: tok.Token,
    last_token_end_offset: usize,
    last_token_line_num: u32,
    last_token_col_num: u32,
};

pub fn takeParserSnapshot(s: *State) Error!ParserSnapshot {
    return .{
        .cursor = takeLexerCursorSnapshot(s),
        // qjs speculative scans restore via reparse_ident_token; retain
        // the complete token payload while the scan consumes its owner.
        .token = try s.lex.dupToken(s.token),
        .last_token_end_offset = s.last_token_end_offset,
        .last_token_line_num = s.last_token_line_num,
        .last_token_col_num = s.last_token_col_num,
    };
}

pub fn restoreParserLexerSnapshot(s: *State, snapshot: ParserSnapshot) void {
    s.lex.freeToken(&s.token);
    restoreLexerCursorSnapshot(s, snapshot.cursor);
    s.token = snapshot.token;
    s.last_token_end_offset = snapshot.last_token_end_offset;
    s.last_token_line_num = snapshot.last_token_line_num;
    s.last_token_col_num = snapshot.last_token_col_num;
}

pub fn takeLexerCursorSnapshot(s: *State) LexerCursorSnapshot {
    return .{
        .pos = s.lex.pos,
        .line = s.lex.line,
        .col = s.lex.col,
        .got_lf = s.lex.got_lf,
        .mark_pos = s.lex.mark_pos,
        .mark_line = s.lex.mark_line,
        .mark_col = s.lex.mark_col,
    };
}

pub fn restoreLexerCursorSnapshot(s: *State, snapshot: LexerCursorSnapshot) void {
    s.lex.pos = snapshot.pos;
    s.lex.line = snapshot.line;
    s.lex.col = snapshot.col;
    s.lex.got_lf = snapshot.got_lf;
    s.lex.mark_pos = snapshot.mark_pos;
    s.lex.mark_line = snapshot.mark_line;
    s.lex.mark_col = snapshot.mark_col;
}

/// Owns a duplicate of the current token and the lexer cursor while a scan
/// replaces `s.token`. `begin` returns null when that duplicate cannot be
/// allocated. `advance` stays on the lexer and does not run `State.advance`.
pub const TokenScanGuard = struct {
    cursor: LexerCursorSnapshot,
    token: tok.Token,

    pub fn begin(s: *State) ?TokenScanGuard {
        return .{
            .cursor = takeLexerCursorSnapshot(s),
            .token = s.lex.dupToken(s.token) catch return null,
        };
    }

    pub fn restore(self: TokenScanGuard, s: *State) void {
        s.lex.freeToken(&s.token);
        restoreLexerCursorSnapshot(s, self.cursor);
        s.token = self.token;
    }

    pub fn advance(s: *State) Error!bool {
        s.lex.nextIntoReplacing(&s.token) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        return true;
    }
};

const BalancedTokenScan = struct {
    following: tok.Kind = .eof,
    closed: bool = false,
    has_top_level_semicolon: bool = false,
    has_top_level_ellipsis: bool = false,
    has_assignment: bool = false,
    failure: ?DiagnosticToken = null,
    /// The closer the innermost open delimiter needed when `failure` was hit.
    expected_close: tok.Kind = .eof,
};

/// QuickJS-shaped balanced-token scan. The parser's current token stays
/// borrowed and valid; only the lexer cursor moves, and is restored on
/// return. No parser snapshot, token duplication, emission rollback, or
/// per-token `State.advance` work is needed.
fn closerOf(opening: tok.Kind) tok.Kind {
    return switch (opening) {
        .lparen => .rparen,
        .lbracket => .rbracket,
        .lbrace => .rbrace,
        else => unreachable,
    };
}

fn scanBalancedAfterOpening(s: *State, opening: tok.Kind, no_line_terminator: bool) Error!BalancedTokenScan {
    // The closers of the open delimiters, above an `.eof` sentinel; the
    // opening token has already advanced lex.pos. The scan is iterative, so
    // nesting is bounded only by the recursive parse that follows it.
    var fallback = std.heap.stackFallback(256 * @sizeOf(tok.Kind), s.scratch);
    const allocator = fallback.get();
    var closers: std.ArrayList(tok.Kind) = .empty;
    defer closers.deinit(allocator);
    try closers.appendSlice(allocator, &.{ .eof, closerOf(opening) });
    // Parallel to `closers`: whether a `/` right after that closer starts a
    // regexp. A `)` ending an if/while/for/with head and a `}` ending a block
    // statement are followed by a statement, so `if (t) /re/.test(t)` and
    // `{} /re/g` hold regexps; after any other `)` or `}` a slash divides.
    var fallback_flags = std.heap.stackFallback(256, s.scratch);
    const flags_allocator = fallback_flags.get();
    var regexp_after_close: std.ArrayList(bool) = .empty;
    defer regexp_after_close.deinit(flags_allocator);
    try regexp_after_close.appendSlice(flags_allocator, &.{ false, false });
    var previous_token_kind: ?tok.Kind = opening;
    var slash_after_statement_closer = false;
    var result = BalancedTokenScan{};

    while (closers.items.len > 1) {
        var scratch = s.lex.next() catch |err| return mapLookaheadLexerError(s, err);
        defer s.lex.freeToken(&scratch);

        try rescanLookaheadTokenIfRegexp(s, &scratch, if (slash_after_statement_closer) .semicolon else previous_token_kind);
        slash_after_statement_closer = false;
        const diagnostic_token = diagnosticTokenFromToken(&scratch);
        if (scratch.kind == .template) {
            // Treat the complete template as one balanced item. The helper
            // consumes all `${ ... }` parts while the head token remains alive.
            try skipTemplateInPredeclareScan(s, scratch);
        }

        const ident_atom = if (scratch.kind == .ident)
            switch (scratch.payload) {
                .ident => |ident| ident.atom,
                else => atom_module.null_atom,
            }
        else
            atom_module.null_atom;
        const is_of = ident_atom == atom_module.ids.of;

        const kind = scratch.kind;

        var closed_statement_part = false;
        switch (kind) {
            .lparen, .lbracket, .lbrace => {
                try closers.append(allocator, closerOf(kind));
                const before = previous_token_kind orelse .semicolon;
                try regexp_after_close.append(flags_allocator, switch (kind) {
                    .lparen => before == .kw_if or before == .kw_while or before == .kw_for or before == .kw_with,
                    .lbrace => switch (before) {
                        .rparen, .lbrace, .rbrace, .semicolon, .arrow, .kw_else, .kw_do, .kw_try, .kw_finally => true,
                        else => false,
                    },
                    else => false,
                });
            },
            .rparen, .rbracket, .rbrace, .eof => {
                if (kind == .eof or closers.getLast() != kind) {
                    result.failure = diagnostic_token;
                    result.expected_close = closers.getLast();
                    return result;
                }
                _ = closers.pop();
                closed_statement_part = regexp_after_close.pop() orelse false;
            },
            .semicolon => if (closers.items.len == 2) {
                result.has_top_level_semicolon = true;
            },
            .ellipsis => if (closers.items.len == 2) {
                result.has_top_level_ellipsis = true;
            },
            .assign => result.has_assignment = true,
            else => {},
        }

        previous_token_kind = if (is_of or ident_atom == atom_module.ids.yield)
            .kw_of
        else
            kind;
        slash_after_statement_closer = closed_statement_part;
        if (closers.items.len <= 1) {
            result.closed = true;
        }
    }

    var following = s.lex.next() catch |err| return mapLookaheadLexerError(s, err);
    defer s.lex.freeToken(&following);
    result.following = if (no_line_terminator and s.lex.got_lf)
        .newline
    else
        following.kind;
    return result;
}

pub fn scanBalancedToken(s: *State, no_line_terminator: bool) Error!BalancedTokenScan {
    const opening = s.peekKind();
    if (opening != .lparen and
        opening != .lbracket and
        opening != .lbrace)
    {
        return s.failExpectedDescription("opening delimiter");
    }

    // The parser only consumes topology from this speculative walk. Keep
    // ordinary ASCII source borrowed, exactly as the simple arrow probe
    // does, and fall back to the owning Lexer for template, escaped,
    // Unicode, or otherwise context-sensitive input.
    if (simple_token.balancedAfterOpen(
        s.lex.source,
        s.lex.pos,
        @intCast(@intFromEnum(opening)),
        no_line_terminator,
    )) |simple| {
        const following: tok.Kind = switch (simple.following) {
            .arrow => .arrow,
            .assignment => .assign,
            .comma => .comma,
            .colon => .colon,
            .question => .question,
            .left_brace => .lbrace,
            .right_paren => .rparen,
            .right_bracket => .rbracket,
            .right_brace => .rbrace,
            .identifier => .ident,
            .in_keyword => .kw_in,
            .line_terminator => .newline,
            .other, .eof => .eof,
        };
        if (simple.closed) {
            return .{
                .following = following,
                .closed = true,
                .has_top_level_semicolon = simple.has_top_level_semicolon,
                .has_top_level_ellipsis = simple.has_top_level_ellipsis,
                .has_assignment = simple.has_assignment,
            };
        }
    }

    const snapshot = takeLexerCursorSnapshot(s);
    defer restoreLexerCursorSnapshot(s, snapshot);
    return scanBalancedAfterOpening(s, opening, no_line_terminator);
}
