//! QuickJS-aligned expression parser (F4 first slice).
//!
//! Mirrors `js_parse_expr` family in `quickjs.c:27049..27645` row-for-row:
//!
//!     parseExpr            -> parseExpr2(PF_IN_ACCEPTED)
//!     parseExpr2(flags)    -> parseAssignExpr2(flags); while ',' { drop ; ... }
//!     parseAssignExpr2     -> parseCondExpr(flags); if assign-op { ... }
//!     parseCondExpr        -> parseCoalesceExpr; if '?' { ... }
//!     parseCoalesceExpr    -> parseLogicalAndOr(OP_or); if '??' { ... }
//!     parseLogicalAndOr    -> parseExprBinary(level=8) ; while op_match { ... }
//!     parseExprBinary(L,f) -> if L==0 parseUnary ; switch(L) on token table
//!     parseUnary           -> handle delete/void/typeof/+/-/~/!/++/--/await ; ** if PF_POW_ALLOWED
//!     parsePostfixExpr     -> parseLhsExpr ; postfix ++/--
//!     parseLhsExpr         -> primary or new ... ; member chain
//!
//! This is a STRUCTURAL implementation that emits real QuickJS opcode
//! ids (`bytecode.opcode.op.<name>`) into the bytecode buffer. It does
//! NOT yet feed an existing VM dispatcher — F2-3 (atomic VM swap) must
//! land before this parser can drive end-to-end execution. F4 tests
//! validate the parser by byte-sequence comparison against the QuickJS
//! lowering reference.
//!
//! This module coexists with the legacy `frontend/parser.zig`
//! (QuickParser) until F11 deletes the latter.

const std = @import("std");

const atom_module = @import("../core/atom.zig");
const memory = @import("../core/memory.zig");
const Value = @import("../core/value.zig").Value;

const bytecode_function = @import("../bytecode/function.zig");
const function_def_mod = @import("../bytecode/function_def.zig");
const opcode = @import("../bytecode/opcode.zig");

const lexer_mod = @import("qjs_lexer.zig");
const tok = @import("qjs_token.zig");

const Atom = atom_module.Atom;

pub const Error = lexer_mod.Error || error{
    UnexpectedToken,
    InvalidLhs,
    InvalidNumberLiteral,
    InvalidIdentifier,
    InvalidAssignmentTarget,
    YieldOutsideGenerator,
    AwaitOutsideAsyncFunction,
};

/// Parse flags mirror the QuickJS `PF_*` macros (`quickjs.c:21358..21370`).
pub const ParseFlags = packed struct(u32) {
    in_accepted: bool = false,
    pow_allowed: bool = false,
    arrow_func: bool = false,
    trailing_comma_ok: bool = false,
    result_needed: bool = true,
    _padding: u27 = 0,

    pub const default = ParseFlags{ .in_accepted = true };
};

/// Mirror `quickjs.c:21352` — BlockEnv for break/continue/finally tracking.
pub const BlockEnv = struct {
    prev: ?*BlockEnv,
    label_name: Atom,
    label_break: i32,
    label_cont: i32,
    drop_count: i32,
    label_finally: i32,
    scope_level: i32,
    has_iterator: bool,
    is_regular_stmt: bool,
};

/// Declaration mask for `parseStatementOrDecl`. Mirrors QuickJS `DECL_MASK_*`.
pub const DeclMask = packed struct(u32) {
    func: bool = false,
    func_with_label: bool = false,
    other: bool = false,
    _padding: u29 = 0,
};

/// Function kind for F6. Mirrors QuickJS `JSFunctionKindEnum`.
pub const FunctionKind = enum {
    normal,
    generator,
    async,
    async_generator,
};

/// Parse function kind for F6. Mirrors QuickJS `JSParseFunctionEnum`.
pub const ParseFunctionKind = enum {
    normal,
    generator,
    async,
    async_generator,
    arrow,
    method,
    get,
    set,
    class_constructor,
    derived_class_constructor,
    class_static_block,
};

/// Class element kind for F7. Mirrors QuickJS class element types.
pub const ClassElementKind = enum {
    field,
    method,
    getter,
    setter,
    static_field,
    static_method,
    static_getter,
    static_setter,
    private_field,
    private_method,
    private_getter,
    private_setter,
    static_block,
};

/// Minimal `JSParseState` analogue for F4 expression-level work. F5/F6
/// expand this with `cur_func`, scope chain, label tracking, etc.
pub const ParseState = struct {
    lex: *lexer_mod.Lexer,
    function: *bytecode_function.Bytecode,
    /// One-token lookahead. The lexer is the source of truth; we cache
    /// the most recently produced token here so the parser can `peek`.
    token: tok.Token,
    /// Block environment stack for break/continue/finally tracking.
    top_break: ?*BlockEnv = null,
    /// Current scope level (for lexical declarations).
    scope_level: i32 = 0,
    /// Whether we're in strict mode.
    is_strict: bool = false,
    /// Whether we're in an eval context.
    is_eval: bool = false,
    /// Whether we're inside a class body (F7).
    in_class: bool = false,
    /// Whether the current class has an extends clause (F7).
    class_has_extends: bool = false,
    /// Whether we're in a static class element context (F7).
    is_static: bool = false,
    /// Whether we're in a constructor (F7).
    in_constructor: bool = false,
    /// Whether the last primary expression was super (F7).
    last_was_super: bool = false,
    /// Whether we're in a generator function (F9).
    in_generator: bool = false,
    /// Whether we're in an async function (F9).
    in_async: bool = false,
    /// Whether to emit Phase 1 temporary opcodes (F10 pipeline).
    /// When true, emits scope_get_var/scope_put_var/scope_get_var_undef
    /// instead of the final get_var/put_var/get_var_undef opcodes.
    ///
    /// **Default is `true`** as of the F10 interim pipeline landing.
    /// Callers run `bytecode.pipeline.finalize.run` after parsing to
    /// lower the temp opcodes to their final shapes. The pipeline:
    ///   * shrinks scope_get_var (7 bytes) → get_var (5 bytes), and
    ///     equivalents for scope_put_var / scope_get_var_undef;
    ///   * drops enter_scope / leave_scope / OP_label entirely;
    ///   * patches every absolute u32 jump operand using an
    ///     old→new pc map so `&&`/`||`/`??`/`?:` keep working
    ///     across the byte-offset shift.
    ///
    /// Setting this to `false` skips temp emission entirely (the
    /// parser writes final-form opcodes directly), which is useful
    /// for golden-byte tests that assert the lowered shape and want
    /// to bypass the pipeline.
    emit_phase1_temp: bool = true,

    /// Parity/tooling mode for top-level program dumps. QuickJS-ng dumps
    /// top-level lexical bindings in the eval/module wrapper as var-ref
    /// closure variables (`module_decl`) instead of ordinary local TDZ slots.
    /// Keep this opt-in so existing expression/unit-test paths retain their
    /// current local-slot behavior until full module/eval semantics land.
    top_level_lexical_as_module_ref: bool = false,
    top_level_functions_as_children: bool = false,

    /// QuickJS `eval_ret_idx` mirror (`quickjs.c:21480`). When ≥ 0,
    /// the slot at this local index receives the result of every
    /// expression statement (instead of the placeholder `drop`), and
    /// the caller's `finalizeEvalReturn` retrieves it at script end.
    /// `enableEvalReturn` allocates the slot using the `<ret>` atom
    /// (id 82, `quickjs-atom.h:115`). `-1` means non-eval mode.
    eval_ret_idx: i32 = -1,

    /// QuickJS `JSFunctionDef` companion state (F10.1a). Populated
    /// during parsing with scope chain (`pushScope`/`popScope`),
    /// variable declarations (`addScopeVar`), and later closure/label
    /// data. The interim pipeline does not consume this yet — the
    /// full FunctionDef-based `resolve_variables` / `resolve_labels`
    /// (PARSER_REWRITE_PLAN.md §F10.1/§F10.2 Outstanding) will read
    /// from it to drive scope-chain walking, closure synthesis, TDZ,
    /// and local-slot assignment.
    ///
    /// The parser still emits to `function.code` as before; this is a
    /// parallel structure that mirrors `JSParseState.cur_func`
    /// (`quickjs.c:21581`). Tests in `qjs_parser_test.zig` assert the
    /// `vars` / `scopes` layout is populated correctly.
    function_def: function_def_mod.FunctionDef,

    /// Stack of FunctionDef pointers for nested function parsing.
    /// Mirrors `JSParseState.cur_func` stack management. The top of
    /// the stack is the current function being parsed. When entering
    /// a nested function, we push a new FunctionDef; when exiting,
    /// we pop back to the parent.
    cur_func_stack: []*function_def_mod.FunctionDef = &.{},

    /// When true, emit bytecode to the current FunctionDef's byte_code
    /// buffer instead of the Bytecode object's code buffer. Used for
    /// nested functions to maintain separate bytecode buffers.
    emit_to_function_def: bool = false,
    pending_function_name: ?Atom = null,
    pending_function_is_decl: bool = false,
    last_function_child_index: ?u16 = null,
    last_anonymous_function_expr: bool = false,
    return_expr_mode: bool = false,
    return_expr_emitted_return: bool = false,
    suppress_expr_statement_drop: bool = false,
    last_var_decl_atom: ?Atom = null,
    last_var_decl_can_skip_get: bool = false,
    skip_next_ident_get: ?Atom = null,
    emit_lexical_tdz_at_decl: bool = false,

    pub fn init(lex: *lexer_mod.Lexer, function: *bytecode_function.Bytecode) Error!ParseState {
        // Mark bytecode as QuickJS-aligned format for dual-dispatch VM.
        // See PARSER_REWRITE_PLAN.md §F2+F3 and bytecode/function.zig `OpcodeFormat`.
        function.opcode_format = .qjs;
        var state = ParseState{
            .lex = lex,
            .function = function,
            .token = undefined,
            .function_def = function_def_mod.FunctionDef.init(function.memory, function.atoms, function.name),
        };
        // Mirror `js_new_function_def` (`quickjs.c:31511`): scope 0
        // is the function's var/arg scope, parent = -1.
        _ = state.function_def.appendScope(-1) catch return error.OutOfMemory;
        state.token = try lex.next();
        // Note: cur_func_stack starts empty; cur_func() returns &function_def when empty
        return state;
    }

    /// Release ParseState-owned resources. `rt` is forwarded to
    /// `FunctionDef.deinit` so constants in `function_def.cpool` can
    /// be released. `anytype` matches `Bytecode.deinit`'s signature
    /// so callers pass their existing runtime pointer.
    pub fn deinit(self: *ParseState, rt: anytype) void {
        self.lex.freeToken(&self.token);
        // Free any nested function definitions on the stack
        for (self.cur_func_stack) |fd| {
            fd.deinit(rt);
        }
        if (self.cur_func_stack.len != 0) {
            self.function.memory.free(*function_def_mod.FunctionDef, self.cur_func_stack);
        }
        self.function_def.deinit(rt);
    }

    /// Get the current FunctionDef from the top of the stack.
    /// Mirrors `JSParseState.cur_func` access. Returns the root
    /// function_def when the stack is empty (top-level parsing).
    fn cur_func(self: *ParseState) *function_def_mod.FunctionDef {
        if (self.cur_func_stack.len == 0) {
            return &self.function_def;
        }
        return self.cur_func_stack[self.cur_func_stack.len - 1];
    }

    /// Push a new FunctionDef onto the stack. Called when entering
    /// a nested function. Mirrors the parent link setup in
    /// `js_new_function_def` (`quickjs.c:31484-31490`).
    fn pushFunction(self: *ParseState, fd: *function_def_mod.FunctionDef) Error!void {
        const new_len = self.cur_func_stack.len + 1;
        const next = try self.function.memory.alloc(*function_def_mod.FunctionDef, new_len);
        errdefer self.function.memory.free(*function_def_mod.FunctionDef, next);
        @memcpy(next[0..self.cur_func_stack.len], self.cur_func_stack);
        next[self.cur_func_stack.len] = fd;
        if (self.cur_func_stack.len != 0) self.function.memory.free(*function_def_mod.FunctionDef, self.cur_func_stack);
        self.cur_func_stack = next;
    }

    /// Pop the current FunctionDef from the stack. Called when exiting
    /// a nested function. Returns the popped FunctionDef pointer.
    fn popFunction(self: *ParseState) *function_def_mod.FunctionDef {
        const fd = self.cur_func_stack[self.cur_func_stack.len - 1];
        const new_len = self.cur_func_stack.len - 1;
        if (new_len > 0) {
            const next = self.function.memory.alloc(*function_def_mod.FunctionDef, new_len) catch unreachable;
            @memcpy(next[0..new_len], self.cur_func_stack[0..new_len]);
            self.function.memory.free(*function_def_mod.FunctionDef, self.cur_func_stack);
            self.cur_func_stack = next;
        } else {
            self.function.memory.free(*function_def_mod.FunctionDef, self.cur_func_stack);
            self.cur_func_stack = &.{};
        }
        return fd;
    }

    /// Mirror `push_scope` (`quickjs.c:23486`): allocate a new
    /// `VarScope` whose parent is the current scope, then switch
    /// `scope_level` to it. Call on entry to a new lexical block.
    pub fn pushScope(self: *ParseState) Error!void {
        const parent = self.scope_level;
        const new_scope = self.cur_func().appendScope(parent) catch return error.OutOfMemory;
        self.scope_level = new_scope;
        self.cur_func().scope_level = new_scope;
    }

    /// Mirror `pop_scope` (`quickjs.c:23532`): restore the parent
    /// scope. Also updates `function_def.scope_first` to the outer
    /// scope's first lexical var so subsequent lookups see the
    /// correct chain.
    pub fn popScope(self: *ParseState) void {
        if (self.scope_level < 0) return;
        const parent = self.cur_func().scopes[@intCast(self.scope_level)].parent;
        self.scope_level = parent;
        self.cur_func().scope_level = parent;
        // Recompute scope_first for the new current scope (mirrors
        // `get_first_lexical_var` at `quickjs.c:23521`).
        var scope = parent;
        self.cur_func().scope_first = -1;
        while (scope >= 0) {
            const s_idx = self.cur_func().scopes[@intCast(scope)].first;
            if (s_idx >= 0) {
                self.cur_func().scope_first = s_idx;
                break;
            }
            scope = self.cur_func().scopes[@intCast(scope)].parent;
        }
    }

    /// Register a variable declaration in `function_def.vars`.
    /// Mirrors `add_scope_var` (`quickjs.c:23577`). `kind` selects
    /// the `VarKind` (normal for `var`, normal + is_lexical for let,
    /// normal + is_lexical + is_const for const). Returns the var
    /// index. Currently informational only; the interim pipeline
    /// ignores `function_def` and relies on global fallback for all
    /// var references.
    pub fn addScopeVar(
        self: *ParseState,
        name: Atom,
        kind: function_def_mod.VarKind,
        is_lexical: bool,
        is_const: bool,
    ) Error!i32 {
        return self.cur_func().addScopeVar(name, kind, self.scope_level, is_lexical, is_const) catch return error.OutOfMemory;
    }

    /// Atom id reserved for the eval-return slot, mirroring
    /// `JS_ATOM__ret_` / `<ret>` (`quickjs-atom.h:115`). Used as the
    /// var name for the synthetic local that captures every
    /// expression-statement result in eval mode.
    pub const eval_ret_atom: Atom = 82;

    /// Switch the parser into eval mode and allocate the synthetic
    /// `<ret>` local that holds the result of the last evaluated
    /// expression. Mirrors `set_eval_ret_undefined` setup +
    /// `add_var(JS_ATOM__ret_)` (`quickjs.c:28219`/`28834`). The
    /// caller invokes this immediately after `ParseState.init` and
    /// before parsing any statements.
    ///
    /// Effect:
    /// 1. `is_eval` is set so `parseExprStatement` emits
    ///    `scope_put_var <ret>` (lowered to `put_loc <idx>`)
    ///    instead of `drop`.
    /// 2. The `<ret>` slot is registered in `function_def.vars`
    ///    (non-lexical so it bypasses TDZ).
    /// 3. The slot is initialised to `undefined` so an empty script
    ///    (no expressions) still returns a sensible value.
    pub fn enableEvalReturn(self: *ParseState) Error!void {
        self.is_eval = true;
        self.cur_func().is_eval = true;
        const idx = try self.addScopeVar(eval_ret_atom, .normal, false, false);
        self.eval_ret_idx = idx;
        self.cur_func().eval_ret_idx = idx;
        // Emit the initialiser:  undefined ; scope_put_var <ret>.
        try self.emitOp(opcode.op.undefined);
        try self.emitScopePutVar(eval_ret_atom);
    }

    /// Mirror the tail of `js_parse_program` (`quickjs.c:31459`):
    /// after the last statement is parsed, emit
    /// `scope_get_var <ret>` so the eval result sits on the stack
    /// for `vm.run` to return. No-op when not in eval mode.
    pub fn finalizeEvalReturn(self: *ParseState) Error!void {
        if (self.eval_ret_idx < 0) return;
        try self.emitScopeGetVar(eval_ret_atom);
    }

    /// Advance one token. Frees the payload of the consumed token.
    fn advance(self: *ParseState) Error!void {
        self.lex.freeToken(&self.token);
        self.token = try self.lex.next();
    }

    pub fn peekKind(self: ParseState) tok.TokenKind {
        return self.token.val;
    }

    fn isPunct(self: ParseState, ch: u8) bool {
        return self.token.val == @as(tok.TokenKind, @intCast(ch));
    }

    /// Check if we got a line terminator before the current token (for ASI).
    fn gotLineTerminator(self: ParseState) bool {
        return self.lex.gotLineTerminator();
    }

    // ---- label management ----
    //
    // F5/F6/F7 statement parsing uses direct `emitForwardJump` /
    // `emitBackwardJump` / `patchForwardJump` to wire control flow.
    // F10's resolve_labels pipeline will introduce proper LabelSlot
    // tables (mirroring `quickjs.c:21338..21412`) to support labelled
    // break/continue, finally pop counts, and iterator-close on break.
    // The `BlockEnv` chain on this struct is reserved for that pipeline.

    /// Expect a semicolon, applying ASI rules. Returns true if a semicolon
    /// was present or inserted via ASI.
    fn expectSemicolon(s: *ParseState) Error!bool {
        if (s.isPunct(';')) {
            try s.advance();
            return true;
        }
        // ASI: if we have a line terminator or are at EOF or closing brace,
        // insert a semicolon automatically.
        if (s.gotLineTerminator() or s.peekKind() == tok.TOK_EOF or s.isPunct('}')) {
            return true;
        }
        return Error.UnexpectedToken;
    }

    /// Expect a specific token kind.
    fn expectToken(s: *ParseState, kind: tok.TokenKind) Error!void {
        if (s.peekKind() != kind) return Error.UnexpectedToken;
        try s.advance();
    }

    /// Peek at the next token kind without consuming the current token.
    /// Saves and restores lexer position so the cached token stays valid.
    fn peekNextKind(s: *ParseState) tok.TokenKind {
        const saved_pos = s.lex.pos;
        const saved_line = s.lex.line;
        const saved_col = s.lex.col;
        const saved_mark_pos = s.lex.mark_pos;
        const saved_mark_line = s.lex.mark_line;
        const saved_mark_col = s.lex.mark_col;
        const peek_token = s.lex.next() catch return tok.TOK_EOF;
        defer {
            s.lex.freeToken(@constCast(&peek_token));
            s.lex.pos = saved_pos;
            s.lex.line = saved_line;
            s.lex.col = saved_col;
            s.lex.mark_pos = saved_mark_pos;
            s.lex.mark_line = saved_mark_line;
            s.lex.mark_col = saved_mark_col;
        }
        return peek_token.val;
    }

    /// Check if the for loop head is for-in or for-of by looking ahead
    /// for `for (var x in expr)` or `for (var x of expr)`
    fn checkForInOfHead(s: *ParseState) bool {
        const saved_pos = s.lex.pos;
        const saved_line = s.lex.line;
        const saved_col = s.lex.col;
        const saved_mark_pos = s.lex.mark_pos;
        const saved_mark_line = s.lex.mark_line;
        const saved_mark_col = s.lex.mark_col;
        const saved_token = s.token;
        var advanced = false;
        defer {
            if (advanced) s.lex.freeToken(&s.token);
            s.lex.pos = saved_pos;
            s.lex.line = saved_line;
            s.lex.col = saved_col;
            s.lex.mark_pos = saved_mark_pos;
            s.lex.mark_line = saved_mark_line;
            s.lex.mark_col = saved_mark_col;
            s.token = saved_token;
        }

        const advanceLocal = struct {
            fn call(state: *ParseState, did_advance: *bool) bool {
                const next = state.lex.next() catch return false;
                state.lex.freeToken(&state.token);
                state.token = next;
                did_advance.* = true;
                return true;
            }
        }.call;

        // Skip var/let/const if present
        if (s.peekKind() == tok.TOK_VAR or s.peekKind() == tok.TOK_LET or s.peekKind() == tok.TOK_CONST) {
            if (!advanceLocal(s, &advanced)) return false;
        }

        // Skip identifier
        if (s.peekKind() == tok.TOK_IDENT) {
            if (!advanceLocal(s, &advanced)) return false;
        }

        // Check if next token is 'in' or 'of'
        const next_kind = s.peekKind();
        return next_kind == tok.TOK_IN or next_kind == tok.TOK_OF;
    }

    /// Check if the current token is an identifier with the given name
    fn isIdent(s: *ParseState, name: []const u8) bool {
        if (s.peekKind() != tok.TOK_IDENT) return false;
        const ident_str = s.lex.atoms.name(s.token.payload.ident.atom) orelse return false;
        return std.mem.eql(u8, ident_str, name);
    }

    // ---- emit primitives -------------------------------------------------
    //
    // Direct byte writes into `function.code`. F2.2 will move these into a
    // shared `bytecode/qjs_emitter.zig` once the legacy emitter is retired.

    fn emitOp(self: *ParseState, op_id: u8) Error!void {
        try self.appendBytes(&[_]u8{op_id});
    }

    fn emitOpU8(self: *ParseState, op_id: u8, val: u8) Error!void {
        try self.appendBytes(&[_]u8{ op_id, val });
    }

    fn emitOpU16(self: *ParseState, op_id: u8, val: u16) Error!void {
        var bytes: [3]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u16, bytes[1..3], val, .little);
        try self.appendBytes(&bytes);
    }

    fn emitOpI32(self: *ParseState, op_id: u8, val: i32) Error!void {
        var bytes: [5]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(i32, bytes[1..5], val, .little);
        try self.appendBytes(&bytes);
    }

    fn emitOpU32(self: *ParseState, op_id: u8, val: u32) Error!void {
        var bytes: [5]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u32, bytes[1..5], val, .little);
        try self.appendBytes(&bytes);
    }

    fn emitFClosure8(self: *ParseState, idx: u8) Error!void {
        try self.emitOpU8(opcode.op.fclosure8, idx);
    }

    fn emitSetVarRef(self: *ParseState, idx: u16) Error!void {
        if (idx < 4) {
            try self.emitOp(opcode.op.set_var_ref0 + @as(u8, @intCast(idx)));
        } else {
            try self.emitOpU16(opcode.op.set_var_ref, idx);
        }
    }

    fn emitOpAtom(self: *ParseState, op_id: u8, atom_id: Atom) Error!void {
        if (self.emit_to_function_def) {
            try self.cur_func().appendAtomOperand(atom_id);
        } else {
            try self.function.retainAtomOperand(atom_id);
        }
        try self.emitOpU32(op_id, atom_id);
    }

    // ---- Phase 1 temporary opcode helpers (F10) ----
    // These emit scope_* opcodes that will be lowered by resolve_variables.

    fn emitOpAtomU16(self: *ParseState, op_id: u8, atom_id: Atom, u16_val: u16) Error!void {
        if (self.emit_to_function_def) {
            try self.cur_func().appendAtomOperand(atom_id);
        } else {
            try self.function.retainAtomOperand(atom_id);
        }
        var bytes: [7]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u32, bytes[1..5], atom_id, .little);
        std.mem.writeInt(u16, bytes[5..7], u16_val, .little);
        try self.appendBytes(&bytes);
    }

    fn emitOpAtomU8(self: *ParseState, op_id: u8, atom_id: Atom, u8_val: u8) Error!void {
        if (self.emit_to_function_def) {
            try self.cur_func().appendAtomOperand(atom_id);
        } else {
            try self.function.retainAtomOperand(atom_id);
        }
        var bytes: [6]u8 = undefined;
        bytes[0] = op_id;
        std.mem.writeInt(u32, bytes[1..5], atom_id, .little);
        bytes[5] = u8_val;
        try self.appendBytes(&bytes);
    }

    fn emitScopeGetVar(self: *ParseState, atom_id: Atom) Error!void {
        try self.ensureClosureVar(atom_id);
        if (self.emit_phase1_temp) {
            try self.emitOpAtomU16(opcode.op.scope_get_var, atom_id, @intCast(self.scope_level));
        } else {
            try self.emitOpAtom(opcode.op.get_var, atom_id);
        }
    }

    fn emitScopePutVar(self: *ParseState, atom_id: Atom) Error!void {
        try self.ensureClosureVar(atom_id);
        if (self.emit_phase1_temp) {
            try self.emitOpAtomU16(opcode.op.scope_put_var, atom_id, @intCast(self.scope_level));
        } else {
            try self.emitOpAtom(opcode.op.put_var, atom_id);
        }
    }

    fn emitScopeGetVarUndef(self: *ParseState, atom_id: Atom) Error!void {
        try self.ensureClosureVar(atom_id);
        if (self.emit_phase1_temp) {
            try self.emitOpAtomU16(opcode.op.scope_get_var_undef, atom_id, @intCast(self.scope_level));
        } else {
            try self.emitOpAtom(opcode.op.get_var_undef, atom_id);
        }
    }

    /// Emit `scope_put_var_init` for `let` / `const` initialisers.
    /// Mirrors `quickjs.c:282` (Phase 1 init form). The pipeline
    /// lowers this to `put_loc` when the var resolves locally, or
    /// to `put_var_init` when it's a top-level lexical global.
    fn emitScopePutVarInit(self: *ParseState, atom_id: Atom) Error!void {
        try self.ensureClosureVar(atom_id);
        if (self.emit_phase1_temp) {
            try self.emitOpAtomU16(opcode.op.scope_put_var_init, atom_id, @intCast(self.scope_level));
        } else {
            // Direct emission path (no pipeline): use the plain
            // `put_var_init` 5-byte form.
            try self.emitOpAtom(opcode.op.put_var_init, atom_id);
        }
    }

    fn ensureClosureVar(self: *ParseState, atom_id: Atom) Error!void {
        if (!self.emit_to_function_def) return;
        const current = self.cur_func();
        if (current.findVar(atom_id) >= 0 or current.findArg(atom_id) >= 0) return;
        for (current.closure_var) |cv| {
            if (cv.var_name == atom_id) return;
        }

        var parent_index = self.cur_func_stack.len - 1;
        while (parent_index > 0) {
            parent_index -= 1;
            const parent = self.cur_func_stack[parent_index];
            const parent_var = parent.findVar(atom_id);
            if (parent_var >= 0) {
                try self.ensureClosureChain(parent_index, .{
                    .closure_type = .local,
                    .is_lexical = parent.vars[@intCast(parent_var)].is_lexical,
                    .is_const = parent.vars[@intCast(parent_var)].is_const,
                    .var_kind = parent.vars[@intCast(parent_var)].var_kind,
                    .var_idx = @intCast(parent_var),
                    .var_name = atom_id,
                });
                return;
            }
            const parent_arg = parent.findArg(atom_id);
            if (parent_arg >= 0) {
                try self.ensureClosureChain(parent_index, .{
                    .closure_type = .arg,
                    .is_lexical = false,
                    .is_const = false,
                    .var_kind = .normal,
                    .var_idx = @intCast(parent_arg),
                    .var_name = atom_id,
                });
                return;
            }
            for (parent.closure_var, 0..) |cv, idx| {
                if (cv.var_name == atom_id) {
                    try self.ensureClosureChain(parent_index, .{
                        .closure_type = .ref,
                        .is_lexical = cv.is_lexical,
                        .is_const = cv.is_const,
                        .var_kind = cv.var_kind,
                        .var_idx = @intCast(idx),
                        .var_name = atom_id,
                    });
                    return;
                }
            }
        }
    }

    fn ensureClosureChain(self: *ParseState, source_index: usize, source: function_def_mod.ClosureVar) Error!void {
        var parent_ref_idx: ?u16 = null;
        var child_index = source_index + 1;
        while (child_index < self.cur_func_stack.len) : (child_index += 1) {
            const child = self.cur_func_stack[child_index];
            var existing: ?u16 = null;
            for (child.closure_var, 0..) |cv, idx| {
                if (cv.var_name == source.var_name) {
                    existing = @intCast(idx);
                    break;
                }
            }
            if (existing) |idx| {
                parent_ref_idx = idx;
                continue;
            }

            const cv = if (child_index == source_index + 1) source else function_def_mod.ClosureVar{
                .closure_type = .ref,
                .is_lexical = source.is_lexical,
                .is_const = source.is_const,
                .var_kind = source.var_kind,
                .var_idx = parent_ref_idx orelse return Error.UnexpectedToken,
                .var_name = source.var_name,
            };
            parent_ref_idx = @intCast(try child.addClosureVar(cv));
        }
    }

    fn emitPushConst(self: *ParseState, value: Value) Error!void {
        const idx = if (self.emit_to_function_def or self.top_level_functions_as_children)
            try self.cur_func().appendCpool(value)
        else
            try self.function.addConstant(value);
        try self.emitOpU32(opcode.op.push_const, idx);
    }

    fn appendBytes(self: *ParseState, bytes: []const u8) Error!void {
        if (self.emit_to_function_def) {
            // Emit to current FunctionDef's byte_code buffer
            try self.cur_func().appendByteCode(bytes);
        } else {
            // Emit to Bytecode object's code buffer (legacy behavior)
            const old_len = self.function.code.len;
            const next = try self.function.memory.alloc(u8, old_len + bytes.len);
            errdefer self.function.memory.free(u8, next);
            @memcpy(next[0..old_len], self.function.code);
            @memcpy(next[old_len..], bytes);
            if (self.function.code.len != 0) self.function.memory.free(u8, self.function.code);
            self.function.code = next;
        }
    }

    fn currentCodeLen(self: *ParseState) usize {
        if (self.emit_to_function_def) return self.cur_func().byte_code.len;
        return self.function.code.len;
    }

    fn currentCode(self: *ParseState) []u8 {
        if (self.emit_to_function_def) return self.cur_func().byte_code;
        return self.function.code;
    }

    /// Drop bytes appended after `target_len`. Used by parseAssignExpr2 /
    /// parsePostfixExpr to roll back a speculative LHS emission once an
    /// assignment / update operator is recognised. Atom operand counts are
    /// rolled back via `truncateAtomOperands`; callers must coordinate the
    /// two so retain/free ref-counts stay balanced.
    fn truncateCode(self: *ParseState, target_len: usize) Error!void {
        if (self.emit_to_function_def) {
            // Truncate current FunctionDef's byte_code buffer
            const fd = self.cur_func();
            std.debug.assert(target_len <= fd.byte_code.len);
            if (target_len == fd.byte_code.len) return;
            if (target_len == 0) {
                self.function.memory.free(u8, fd.byte_code);
                fd.byte_code = &.{};
                return;
            }
            const next = try self.function.memory.alloc(u8, target_len);
            errdefer self.function.memory.free(u8, next);
            @memcpy(next, fd.byte_code[0..target_len]);
            self.function.memory.free(u8, fd.byte_code);
            fd.byte_code = next;
        } else {
            // Truncate Bytecode object's code buffer
            std.debug.assert(target_len <= self.function.code.len);
            if (target_len == self.function.code.len) return;
            if (target_len == 0) {
                self.function.memory.free(u8, self.function.code);
                self.function.code = &.{};
                return;
            }
            const next = try self.function.memory.alloc(u8, target_len);
            errdefer self.function.memory.free(u8, next);
            @memcpy(next, self.function.code[0..target_len]);
            self.function.memory.free(u8, self.function.code);
            self.function.code = next;
        }
    }

    /// Drop atom-operand entries beyond `target_len`, releasing the held
    /// atom refcounts. The retain happens in `emitOpAtom`/`retainAtomOperand`.
    fn truncateAtomOperands(self: *ParseState, target_len: usize) Error!void {
        std.debug.assert(target_len <= self.function.atom_operands.len);
        if (target_len == self.function.atom_operands.len) return;
        var i: usize = target_len;
        while (i < self.function.atom_operands.len) : (i += 1) {
            self.function.atoms.free(self.function.atom_operands[i]);
        }
        if (target_len == 0) {
            self.function.memory.free(Atom, self.function.atom_operands);
            self.function.atom_operands = &.{};
            return;
        }
        const next = try self.function.memory.alloc(Atom, target_len);
        errdefer self.function.memory.free(Atom, next);
        @memcpy(next, self.function.atom_operands[0..target_len]);
        self.function.memory.free(Atom, self.function.atom_operands);
        self.function.atom_operands = next;
    }
};

/// Check if `<ident> =>` is the arrow function head shape.
/// Saves and restores lexer position so the cached token stays valid.
fn checkIdentArrowHead(s: *ParseState) bool {
    const saved_pos = s.lex.pos;
    const saved_line = s.lex.line;
    const saved_col = s.lex.col;
    const saved_mark_pos = s.lex.mark_pos;
    const saved_mark_line = s.lex.mark_line;
    const saved_mark_col = s.lex.mark_col;
    const peek_token = s.lex.next() catch return false;
    defer {
        s.lex.freeToken(@constCast(&peek_token));
        s.lex.pos = saved_pos;
        s.lex.line = saved_line;
        s.lex.col = saved_col;
        s.lex.mark_pos = saved_mark_pos;
        s.lex.mark_line = saved_mark_line;
        s.lex.mark_col = saved_mark_col;
    }
    return peek_token.val == tok.TOK_ARROW;
}

/// Check if we're at an arrow function head
/// Mirrors `js_parse_skip_parens_token` in quickjs.c:24194.
///
/// Saves the lexer position and current token, performs lookahead by
/// repeatedly advancing through tokens, then restores both on return.
/// Each scan step both updates `s.token` (so peekKind reflects the
/// lookahead) and frees the consumed token's payload to avoid leaks.
fn checkArrowHead(s: *ParseState) bool {
    // Save lexer position and the cached one-token lookahead.
    const saved_pos = s.lex.pos;
    const saved_line = s.lex.line;
    const saved_col = s.lex.col;
    const saved_mark_pos = s.lex.mark_pos;
    const saved_mark_line = s.lex.mark_line;
    const saved_mark_col = s.lex.mark_col;
    const saved_token = s.token;

    // Restore lexer + token state on every exit path. The intermediate
    // scratch tokens we advance through get freed during the scan.
    var success = false;
    defer {
        // Free the final scratch token (if any) before restoring.
        if (!success) {
            s.lex.freeToken(&s.token);
        } else {
            s.lex.freeToken(&s.token);
        }
        s.lex.pos = saved_pos;
        s.lex.line = saved_line;
        s.lex.col = saved_col;
        s.lex.mark_pos = saved_mark_pos;
        s.lex.mark_line = saved_mark_line;
        s.lex.mark_col = saved_mark_col;
        s.token = saved_token;
    }

    // Helper: advance s.token to the next token. Frees the consumed
    // token's payload. Returns false on lex error.
    const advanceLocal = struct {
        fn call(state: *ParseState) bool {
            const next = state.lex.next() catch return false;
            state.lex.freeToken(&state.token);
            state.token = next;
            return true;
        }
    }.call;

    // Check for ( ... ) => or ident =>
    if (s.peekKind() == '(') {
        if (!advanceLocal(s)) return false; // consume the '('
        var depth: i32 = 1;
        while (depth > 0) {
            const k = s.peekKind();
            if (k == tok.TOK_EOF) return false;
            if (k == '(') depth += 1;
            if (k == ')') depth -= 1;
            if (depth == 0) break;
            if (!advanceLocal(s)) return false;
        }
        if (!advanceLocal(s)) return false; // consume the ')'
    } else if (s.peekKind() == tok.TOK_IDENT) {
        if (!advanceLocal(s)) return false;
    } else {
        return false;
    }

    // Check for =>
    success = s.peekKind() == tok.TOK_ARROW;
    return success;
}

// =====================================================================
// Expression parser entry points (mirror QuickJS function names).
// =====================================================================

/// `js_parse_expr` (`quickjs.c:27645`).
pub fn parseExpr(s: *ParseState) Error!void {
    return parseExpr2(s, ParseFlags.default);
}

/// `js_parse_expr2` (`quickjs.c:27621`). Comma operator.
pub fn parseExpr2(s: *ParseState, flags: ParseFlags) Error!void {
    try parseAssignExpr2(s, flags);
    while (s.isPunct(',')) {
        try s.advance();
        // Discard left-hand side; `a, b` evaluates to b.
        try s.emitOp(opcode.op.drop);
        try parseAssignExpr2(s, flags);
    }
}

/// `js_parse_assign_expr` (`quickjs.c:27615`).
pub fn parseAssignExpr(s: *ParseState) Error!void {
    return parseAssignExpr2(s, ParseFlags.default);
}

/// `js_parse_assign_expr2` (`quickjs.c:27311`). Assignment-target check
/// and compound-assignment lowering. F4 slice 3 supports
/// simple-identifier targets, dotted targets (`a.b = v`), and indexed
/// targets (`a[i] = v`). Destructuring and arrow forms come in F6.
pub fn parseAssignExpr2(s: *ParseState, flags: ParseFlags) Error!void {
    // Capture an identifier target up front so we can re-emit if an
    // assignment operator follows. A full implementation would defer the
    // LHS emission until the assignment shape is known (QuickJS's
    // `JS_INIT_LV` deferred-emit path); for now we truncate the
    // speculative `get_var` and re-emit. Track the pre-LHS code/atom
    // lengths so the rollback is targeted (deeper recursion may have
    // already emitted unrelated bytes — wiping the whole buffer is
    // unsound, e.g. `1 + (a = b)`).
    const saved_atom: ?Atom = if (s.peekKind() == tok.TOK_IDENT) blk: {
        break :blk s.token.payload.ident.atom;
    } else null;
    const pre_lhs_code_len = s.currentCodeLen();
    const pre_lhs_atom_len = s.function.atom_operands.len;

    try parseCondExpr(s, flags);

    const op_kind = s.peekKind();
    const assign_opcode = compoundAssignOpcode(op_kind);
    const is_plain_assign = op_kind == @as(tok.TokenKind, @intCast('='));
    if (!is_plain_assign and assign_opcode == null) return;

    const shape = classifyLhs(s, pre_lhs_code_len, pre_lhs_atom_len, saved_atom);
    if (shape == .none) return Error.InvalidAssignmentTarget;

    try s.advance(); // consume the assignment operator

    if (assign_opcode) |op_byte| {
        // Compound: `a.b += v` etc. The receiver stays on the stack via
        // the *2 form of the speculative load; we emit rhs, the binop,
        // and then the put-keep-top sequence.
        switch (shape) {
            .var_ref => |v| {
                // Already loaded by the speculative `get_var <atom>`.
                _ = v;
            },
            .dotted, .indexed => rewriteToGetForm2(s, shape),
            .none => unreachable,
        }
        const rhs_flags = ParseFlags{ .in_accepted = flags.in_accepted };
        try parseAssignExpr2(s, rhs_flags);
        try s.emitOp(op_byte);
        if (flags.result_needed) {
            try emitPutLValueKeepTop(s, shape);
        } else {
            try emitPutLValueNoKeep(s, shape);
        }
    } else {
        // Plain `=`: drop the speculative load (we don't need the old value).
        const rhs_flags = ParseFlags{ .in_accepted = flags.in_accepted };
        switch (shape) {
            .var_ref => |v| {
                try s.truncateCode(v.code_pos);
                try s.truncateAtomOperands(pre_lhs_atom_len);
                try parseAssignExpr2(s, rhs_flags);
                if (flags.result_needed) {
                    try s.emitOp(opcode.op.dup);
                    try s.emitScopePutVar(v.atom);
                } else {
                    try emitPutLValueDropResult(s, shape);
                }
            },
            .dotted => |d| {
                // Drop the speculative `get_field <atom>` (5 bytes plus
                // its atom_operand entry); the receiver stays on the
                // stack from earlier emission.
                try s.truncateCode(d.code_pos);
                try s.truncateAtomOperands(s.function.atom_operands.len - 1);
                try parseAssignExpr2(s, rhs_flags);
                if (flags.result_needed) {
                    try s.emitOp(opcode.op.insert2);
                    try s.emitOpAtom(opcode.op.put_field, d.atom);
                } else {
                    try emitPutLValueDropResult(s, shape);
                }
            },
            .indexed => |i| {
                // Drop the speculative `get_array_el` (1 byte); the
                // receiver+key stay on the stack.
                try s.truncateCode(i.code_pos);
                try parseAssignExpr2(s, rhs_flags);
                if (flags.result_needed) {
                    try s.emitOp(opcode.op.insert3);
                    try s.emitOp(opcode.op.put_array_el);
                } else {
                    try emitPutLValueDropResult(s, shape);
                }
            },
            .none => unreachable,
        }
    }
}

/// Classification of the bytecode tail emitted by `parseLhsExpr` (or a
/// sub-parse). Mirrors QuickJS's `get_lvalue` opcode return value; the
/// caller turns it into the appropriate `put_lvalue` (KEEP_TOP for
/// assignment / prefix update; KEEP_SECOND for postfix update) sequence
/// per `quickjs.c:25466..25553`.
const LhsShape = union(enum) {
    none,
    /// `get_var <atom>` (5 bytes) — depth 0 reference.
    var_ref: struct { atom: Atom, code_pos: usize },
    /// `get_field <atom>` (5 bytes) — depth 1 reference. Compound assign
    /// rewrites this in place to `get_field2`.
    dotted: struct { atom: Atom, code_pos: usize },
    /// `get_array_el` (1 byte) — depth 2 reference. Compound assign
    /// rewrites this in place to `get_array_el2`.
    indexed: struct { code_pos: usize },
};

/// Inspect the trailing emission of a sub-parse and classify the LHS
/// shape. `pre_lhs_code_len` / `pre_lhs_atom_len` capture the buffer
/// state right before the sub-parse started; `saved_atom` is the atom
/// of a leading IDENT token if the caller observed one (used to
/// disambiguate a bare-identifier emission from a complex sub-parse
/// that happened to end at the same byte length).
fn classifyLhs(
    s: *ParseState,
    pre_lhs_code_len: usize,
    pre_lhs_atom_len: usize,
    saved_atom: ?Atom,
) LhsShape {
    const code = s.currentCode();
    // var_ref: exactly `get_var <atom>` (5 bytes) or `scope_get_var <atom> <u16>` (7 bytes) was added.
    if (saved_atom) |ident| {
        const is_final = code.len == pre_lhs_code_len + 5 and code[pre_lhs_code_len] == opcode.op.get_var;
        const is_temp = code.len == pre_lhs_code_len + 7 and code[pre_lhs_code_len] == opcode.op.scope_get_var;
        const atom_operand_matches = s.emit_to_function_def or
            (s.function.atom_operands.len == pre_lhs_atom_len + 1 and
            s.function.atom_operands[pre_lhs_atom_len] == ident);
        if ((is_final or is_temp) and atom_operand_matches)
        {
            const emitted = std.mem.readInt(u32, code[pre_lhs_code_len + 1 ..][0..4], .little);
            if (@as(Atom, emitted) == ident) {
                return .{ .var_ref = .{ .atom = ident, .code_pos = pre_lhs_code_len } };
            }
        }
    }
    // dotted: trailing `get_field <atom>` (5 bytes).
    if (code.len >= pre_lhs_code_len + 5 and code[code.len - 5] == opcode.op.get_field) {
        const atom_id: Atom = std.mem.readInt(u32, code[code.len - 4 ..][0..4], .little);
        return .{ .dotted = .{ .atom = atom_id, .code_pos = code.len - 5 } };
    }
    // indexed: trailing `get_array_el` (1 byte).
    if (code.len > pre_lhs_code_len and code[code.len - 1] == opcode.op.get_array_el) {
        return .{ .indexed = .{ .code_pos = code.len - 1 } };
    }
    return .none;
}

/// `put_lvalue` with PUT_LVALUE_KEEP_TOP semantics — used for plain
/// assignment, compound assignment, and prefix update. Mirrors
/// `quickjs.c:25470..25530`.
fn emitPutLValueKeepTop(s: *ParseState, shape: LhsShape) Error!void {
    switch (shape) {
        .var_ref => |v| {
            if (s.cur_func().use_short_opcodes and s.emit_to_function_def) {
                s.suppress_expr_statement_drop = true;
                try s.emitScopePutVarInit(v.atom);
            } else {
                try s.emitOp(opcode.op.dup);
                try s.emitScopePutVar(v.atom);
            }
        },
        .dotted => |d| {
            try s.emitOp(opcode.op.insert2);
            try s.emitOpAtom(opcode.op.put_field, d.atom);
        },
        .indexed => {
            try s.emitOp(opcode.op.insert3);
            try s.emitOp(opcode.op.put_array_el);
        },
        .none => return Error.InvalidAssignmentTarget,
    }
}

/// `put_lvalue` when the enclosing expression statement discards the
/// assignment result. QuickJS omits the KEEP_TOP shuffle in this context.
fn emitPutLValueDropResult(s: *ParseState, shape: LhsShape) Error!void {
    switch (shape) {
        .var_ref => |v| {
            try s.emitOp(opcode.op.dup);
            try s.emitScopePutVar(v.atom);
        },
        .dotted => |d| {
            s.suppress_expr_statement_drop = true;
            try s.emitOpAtom(opcode.op.put_field, d.atom);
        },
        .indexed => {
            s.suppress_expr_statement_drop = true;
            try s.emitOp(opcode.op.put_array_el);
        },
        .none => return Error.InvalidAssignmentTarget,
    }
}

/// Store an lvalue without preserving the assigned value. QuickJS uses
/// this for compound assignments in expression statements.
fn emitPutLValueNoKeep(s: *ParseState, shape: LhsShape) Error!void {
    switch (shape) {
        .var_ref => |v| {
            if (isNonLexicalBinding(s, v.atom)) {
                s.suppress_expr_statement_drop = true;
                try s.emitScopePutVar(v.atom);
            } else {
                try s.emitOp(opcode.op.dup);
                try s.emitScopePutVar(v.atom);
            }
        },
        .dotted => |d| {
            s.suppress_expr_statement_drop = true;
            try s.emitOpAtom(opcode.op.put_field, d.atom);
        },
        .indexed => {
            s.suppress_expr_statement_drop = true;
            try s.emitOp(opcode.op.put_array_el);
        },
        .none => return Error.InvalidAssignmentTarget,
    }
}

fn isNonLexicalBinding(s: *ParseState, atom_id: Atom) bool {
    for (s.cur_func().closure_var) |cv| {
        if (cv.var_name == atom_id) return !cv.is_lexical;
    }
    for (s.cur_func().vars) |v| {
        if (v.var_name == atom_id) return !v.is_lexical;
    }
    return s.emit_to_function_def;
}

fn hasKnownBinding(s: *ParseState, atom_id: Atom) bool {
    for (s.cur_func().closure_var) |cv| {
        if (cv.var_name == atom_id) return true;
    }
    for (s.cur_func().vars) |v| {
        if (v.var_name == atom_id) return true;
    }
    for (s.cur_func().args) |a| {
        if (a.var_name == atom_id) return true;
    }
    return false;
}

/// `put_lvalue` with PUT_LVALUE_KEEP_SECOND semantics — used for
/// postfix update where the OLD value is the expression result. Mirrors
/// `quickjs.c:25470..25530`.
fn emitPutLValueKeepSecond(s: *ParseState, shape: LhsShape) Error!void {
    switch (shape) {
        .var_ref => |v| {
            try s.emitScopePutVar(v.atom);
        },
        .dotted => |d| {
            try s.emitOp(opcode.op.perm3);
            try s.emitOpAtom(opcode.op.put_field, d.atom);
        },
        .indexed => {
            try s.emitOp(opcode.op.perm4);
            try s.emitOp(opcode.op.put_array_el);
        },
        .none => return Error.InvalidAssignmentTarget,
    }
}

/// Rewrite the trailing `get_field` / `get_array_el` to its `*2` form
/// so the receiver stays on the stack for compound or update lowering.
/// Var-refs need a fresh `get_var` re-emission and are handled by the
/// caller; this helper handles only the depth-1/2 cases.
fn rewriteToGetForm2(s: *ParseState, shape: LhsShape) void {
    switch (shape) {
        .dotted => |d| s.function.code[d.code_pos] = opcode.op.get_field2,
        .indexed => |i| s.function.code[i.code_pos] = opcode.op.get_array_el2,
        else => {},
    }
}

/// `js_parse_cond_expr` (`quickjs.c:27282`). `a ? b : c`.
pub fn parseCondExpr(s: *ParseState, flags: ParseFlags) Error!void {
    try parseCoalesceExpr(s, flags);
    if (s.isPunct('?')) {
        try s.advance();
        if (s.return_expr_mode) {
            const else_jump_offset = try emitForwardJump(s, opcode.op.if_false);
            try parseAssignExpr2(s, flags);
            try s.emitOp(opcode.op.@"return");
            try patchForwardJump(s, else_jump_offset);
            try expectPunct(s, ':');
            try parseAssignExpr2(s, flags);
            try s.emitOp(opcode.op.@"return");
            s.return_expr_emitted_return = true;
            return;
        }
        // Short-circuit: if false, jump to else branch. F4 first slice
        // uses absolute u32 offsets; F10 lowers to relative goto8/goto16.
        const else_jump_offset = try emitForwardJump(s, opcode.op.if_false);
        try parseAssignExpr2(s, flags);
        const end_jump_offset = try emitForwardJump(s, opcode.op.goto);
        try patchForwardJump(s, else_jump_offset);
        try expectPunct(s, ':');
        // The `parse_flags` propagated to the else-branch must keep
        // `PF_IN_ACCEPTED` per QuickJS (`quickjs.c:27305`).
        try parseAssignExpr2(s, flags);
        try patchForwardJump(s, end_jump_offset);
    }
}

/// `js_parse_coalesce_expr` (`quickjs.c:27254`). `a ?? b`.
pub fn parseCoalesceExpr(s: *ParseState, flags: ParseFlags) Error!void {
    try parseLogicalAndOr(s, tok.TOK_LOR, flags);
    if (s.peekKind() == tok.TOK_DOUBLE_QUESTION_MARK) {
        try s.advance();
        // Short-circuit on non-nullish: `a ?? b` keeps a if not
        // null/undefined, else evaluates b. Lowering matches QuickJS:
        //   dup ; is_undefined_or_null ; if_false L_skip ; drop ;
        //   <rhs> ; L_skip:
        try s.emitOp(opcode.op.dup);
        try s.emitOp(opcode.op.is_undefined_or_null);
        const skip_jump = try emitForwardJump(s, opcode.op.if_false);
        try s.emitOp(opcode.op.drop);
        try parseLogicalAndOr(s, tok.TOK_LOR, flags);
        try patchForwardJump(s, skip_jump);
    }
}

/// `js_parse_logical_and_or` (`quickjs.c:27213`). `a && b` / `a || b`.
pub fn parseLogicalAndOr(s: *ParseState, op_kind: tok.TokenKind, flags: ParseFlags) Error!void {
    if (op_kind == tok.TOK_LOR) {
        try parseLogicalAndOr(s, tok.TOK_LAND, flags);
        while (s.peekKind() == tok.TOK_LOR) {
            try s.advance();
            // `a || b` → `dup ; if_true L_skip ; drop ; <b> ; L_skip:`
            try s.emitOp(opcode.op.dup);
            const skip_jump = try emitForwardJump(s, opcode.op.if_true);
            try s.emitOp(opcode.op.drop);
            try parseLogicalAndOr(s, tok.TOK_LAND, flags);
            try patchForwardJump(s, skip_jump);
        }
    } else {
        try parseExprBinary(s, 8, flags);
        while (s.peekKind() == tok.TOK_LAND) {
            try s.advance();
            // `a && b` → `dup ; if_false L_skip ; drop ; <b> ; L_skip:`
            try s.emitOp(opcode.op.dup);
            const skip_jump = try emitForwardJump(s, opcode.op.if_false);
            try s.emitOp(opcode.op.drop);
            try parseExprBinary(s, 8, flags);
            try patchForwardJump(s, skip_jump);
        }
    }
}

/// `js_parse_expr_binary` (`quickjs.c:27049`). Pratt-style with hand
/// rolled level table. Levels 1..8 covered (private-name `in` deferred).
pub fn parseExprBinary(s: *ParseState, level: u8, flags: ParseFlags) Error!void {
    if (level == 0) {
        return parseUnary(s, ParseFlags{ .in_accepted = flags.in_accepted, .pow_allowed = true });
    }
    try parseExprBinary(s, level - 1, flags);
    while (true) {
        const op_byte = matchBinaryOp(s.peekKind(), level, flags) orelse return;
        try s.advance();
        try parseExprBinary(s, level - 1, flags);
        try s.emitOp(op_byte);
    }
}

/// `js_parse_unary` (`quickjs.c:26922`). F4 slice 2 covers prefix
/// `+`, `-`, `~`, `!`, `void`, `typeof`, `delete`, prefix `++`/`--`,
/// and right-associative `**`. `await` is deferred to F9.
pub fn parseUnary(s: *ParseState, flags: ParseFlags) Error!void {
    const k = s.peekKind();
    if (k == @as(tok.TokenKind, @intCast('+'))) {
        try s.advance();
        try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted });
        try s.emitOp(opcode.op.plus);
        return;
    }
    if (k == @as(tok.TokenKind, @intCast('-'))) {
        try s.advance();
        if (s.cur_func().use_short_opcodes and s.peekKind() == tok.TOK_NUMBER) {
            if (s.token.payload.num.is_bigint) {
                const bigint_value = std.fmt.parseInt(i32, s.token.payload.num.bigint_text, 0) catch null;
                if (bigint_value) |v| {
                    try s.emitOpI32(opcode.op.push_bigint_i32, -v);
                    try s.advance();
                    return;
                }
            }
            const value = s.token.payload.num.value;
            if (value != 0 and numberIsExactI32(value)) {
                try s.emitOpI32(opcode.op.push_i32, -@as(i32, @intFromFloat(value)));
                try s.advance();
                return;
            }
        }
        try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted });
        try s.emitOp(opcode.op.neg);
        return;
    }
    if (k == @as(tok.TokenKind, @intCast('~'))) {
        try s.advance();
        try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted });
        try s.emitOp(opcode.op.not);
        return;
    }
    if (k == @as(tok.TokenKind, @intCast('!'))) {
        try s.advance();
        try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted });
        try s.emitOp(opcode.op.lnot);
        return;
    }
    if (k == tok.TOK_VOID) {
        try s.advance();
        try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted });
        try s.emitOp(opcode.op.drop);
        try s.emitOp(opcode.op.@"undefined");
        return;
    }
    if (k == tok.TOK_TYPEOF) {
        try s.advance();
        // typeof on a missing global returns "undefined", not a
        // ReferenceError. QuickJS uses `get_var_undef` for that.
        if (s.peekKind() == tok.TOK_IDENT and
            s.peekNextKind() != @as(tok.TokenKind, @intCast('(')) and
            s.peekNextKind() != @as(tok.TokenKind, @intCast('.')) and
            s.peekNextKind() != @as(tok.TokenKind, @intCast('[')))
        {
            const ident = s.token.payload.ident.atom;
            try s.advance();
            if (hasKnownBinding(s, ident)) {
                try s.emitScopeGetVar(ident);
            } else {
                try s.emitScopeGetVarUndef(ident);
            }
        } else {
            try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted });
        }
        try s.emitOp(opcode.op.typeof);
        return;
    }
    if (k == tok.TOK_DELETE) {
        try s.advance();
        return parseDelete(s, flags);
    }
    if (k == tok.TOK_INC or k == tok.TOK_DEC) {
        const update_op: u8 = if (k == tok.TOK_INC) opcode.op.inc else opcode.op.dec;
        try s.advance();
        const saved_atom: ?Atom = if (s.peekKind() == tok.TOK_IDENT) blk: {
            break :blk s.token.payload.ident.atom;
        } else null;
        const pre_lhs_code_len = s.function.code.len;
        const pre_lhs_atom_len = s.function.atom_operands.len;
        try parseLhsExpr(s, .{ .in_accepted = flags.in_accepted });
        const shape = classifyLhs(s, pre_lhs_code_len, pre_lhs_atom_len, saved_atom);
        if (shape == .none) return Error.InvalidAssignmentTarget;
        // For member targets, rewrite the speculative get_field /
        // get_array_el to its *2 form so the obj/key stay on the stack.
        rewriteToGetForm2(s, shape);
        try s.emitOp(update_op);
        try emitPutLValueKeepTop(s, shape);
        return;
    }
    // F9: Handle yield expressions in generator functions
    if (k == tok.TOK_YIELD) {
        if (!s.in_generator) {
            return Error.YieldOutsideGenerator;
        }
        try s.advance();
        // Check for yield*
        const is_yield_star = s.peekKind() == '*';
        if (is_yield_star) {
            try s.advance();
            // Parse the expression after yield*
            // TODO: F9 proper yield* semantics - for now, parse and drop
            try parseAssignExpr(s);
            try s.emitOp(opcode.op.yield_star);
        } else {
            // Check if there's an expression after yield
            // yield without an expression is equivalent to yield undefined
            if (s.peekKind() == @as(tok.TokenKind, @intCast(';')) or
                s.peekKind() == @as(tok.TokenKind, @intCast('}')) or
                s.peekKind() == @as(tok.TokenKind, @intCast(')')) or
                s.peekKind() == tok.TOK_EOF) {
                // yield without expression
                try s.emitOp(opcode.op.@"undefined");
            } else {
                // yield with expression
                try parseAssignExpr(s);
            }
            try s.emitOp(opcode.op.yield);
        }
        return;
    }
    // F9: Handle await expressions in async functions
    if (k == tok.TOK_AWAIT) {
        if (!s.in_async) {
            return Error.AwaitOutsideAsyncFunction;
        }
        try s.advance();
        // Parse the awaited expression
        try parseAssignExpr(s);
        try s.emitOp(opcode.op.await);
        return;
    }
    try parsePostfixExpr(s, flags);
    // PF_POW_ALLOWED: `a ** b` is right-associative and only allowed
    // when no unary prefix was consumed.
    if (flags.pow_allowed and s.peekKind() == tok.TOK_POW) {
        try s.advance();
        try parseUnary(s, ParseFlags{ .in_accepted = flags.in_accepted, .pow_allowed = true });
        try s.emitOp(opcode.op.pow);
    }
}

/// `js_parse_delete` (`quickjs.c:26829`). Generic implementation: parse
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
/// access. Optional-chain `delete a?.b` / `delete super.x` /
/// `delete #priv` are deferred.
fn parseDelete(s: *ParseState, flags: ParseFlags) Error!void {
    const saved_atom: ?Atom = if (s.peekKind() == tok.TOK_IDENT) blk: {
        break :blk s.token.payload.ident.atom;
    } else null;
    const pre_lhs_code_len = s.currentCodeLen();
    const pre_lhs_atom_len = s.function.atom_operands.len;
    try parseUnary(s, .{ .pow_allowed = false, .in_accepted = flags.in_accepted });
    const shape = classifyLhs(s, pre_lhs_code_len, pre_lhs_atom_len, saved_atom);
    switch (shape) {
        .var_ref => |v| {
            try s.truncateCode(v.code_pos);
            try s.truncateAtomOperands(pre_lhs_atom_len);
            try s.emitOpAtom(opcode.op.delete_var, v.atom);
        },
        .dotted => |d| {
            // Same byte width (atom format = opcode + atom4); just flip
            // the opcode byte. The atom is already retained from the
            // original `get_field` emission, and `push_atom_value` also
            // takes the atom as its operand, so refcount stays balanced.
            s.function.code[d.code_pos] = opcode.op.push_atom_value;
            try s.emitOp(opcode.op.delete);
        },
        .indexed => |i| {
            try s.truncateCode(i.code_pos);
            try s.emitOp(opcode.op.delete);
        },
        .none => {
            try s.emitOp(opcode.op.drop);
            try s.emitOp(opcode.op.push_true);
        },
    }
}

fn isMemberStart(k: tok.TokenKind) bool {
    return k == @as(tok.TokenKind, @intCast('.')) or
        k == @as(tok.TokenKind, @intCast('[')) or
        k == @as(tok.TokenKind, @intCast('('));
}

/// `js_parse_postfix_expr` (`quickjs.c:26176`). Wraps `parseLhsExpr`
/// with the postfix `++` / `--` update operators. F4 slice 2 supports
/// simple-identifier targets only.
pub fn parsePostfixExpr(s: *ParseState, flags: ParseFlags) Error!void {
    const saved_atom: ?Atom = if (s.peekKind() == tok.TOK_IDENT) blk: {
        break :blk s.token.payload.ident.atom;
    } else null;
    const pre_lhs_code_len = s.currentCodeLen();
    const pre_lhs_atom_len = s.function.atom_operands.len;

    try parseLhsExpr(s, flags);

    const k = s.peekKind();
    if (k != tok.TOK_INC and k != tok.TOK_DEC) return;
    // ASI: per QuickJS (`quickjs.c:26206`), a postfix `++` / `--` after
    // a LineTerminator is forbidden. The lexer's `got_lf` flag tracks
    // that. F5 will check `s.lex.got_lf` once strict ASI is wired up; for
    // F4 slice 2 we trust the parser-side check.
    if (s.lex.got_lf) return;

    const shape = classifyLhs(s, pre_lhs_code_len, pre_lhs_atom_len, saved_atom);
    if (shape == .none) return Error.InvalidAssignmentTarget;
    const update_op: u8 = if (k == tok.TOK_INC) opcode.op.post_inc else opcode.op.post_dec;
    try s.advance(); // consume `++` or `--`

    // For member targets, rewrite the speculative get_field /
    // get_array_el to its *2 form so the receiver/key stay on the
    // stack alongside the value to update.
    rewriteToGetForm2(s, shape);
    try s.emitOp(update_op);
    try emitPutLValueKeepSecond(s, shape);
}

/// `js_parse_left_hand_side_expr` (`quickjs.c:24487`). Primary
/// expression followed by zero or more member accesses (`.x`, `[x]`),
/// function calls (`(...)`), and `new` constructions.
///
/// Tracks optional-chain state per call: each `?.` access emits an
/// inline `optional_chain_test` (mirror `quickjs.c:26158`) whose
/// chain-exit `OP_goto` operand is recorded in `chain_exits` and
/// patched to the post-chain byte offset after the member chain
/// finishes. Most chains have ≤4 `?.` accesses so a fixed-size
/// 16-slot buffer is sufficient.
pub fn parseLhsExpr(s: *ParseState, flags: ParseFlags) Error!void {
    if (s.peekKind() == tok.TOK_NEW) {
        try parseNewExpr(s, flags);
    } else {
        try parsePrimary(s, flags);
    }
    const was_super = s.last_was_super;
    var chain_buf: [16]usize = undefined;
    var chain_count: usize = 0;
    try parseMemberChain(s, flags, &chain_buf, &chain_count);
    if (chain_count > 0) {
        // Patch every chain-exit `OP_goto` operand to the current byte
        // offset so the chain returns `undefined` from the right place.
        const chain_end: u32 = @intCast(s.function.code.len);
        for (chain_buf[0..chain_count]) |offset| {
            std.mem.writeInt(u32, s.function.code[offset..][0..4], chain_end, .little);
        }
    }
    // F7: Handle super() constructor calls after member chain
    if (was_super and chain_count == 0 and s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
        // This is a direct super() call (not super.prop())
        // TODO: F7 proper super() constructor call semantics
        // For now, emit as a regular call as placeholder
        const shape = try parseCallArgs(s, flags);
        switch (shape) {
            .direct => |argc| try s.emitOpU16(opcode.op.call, argc),
            .applied => {
                try s.emitOp(opcode.op.@"undefined");
                try s.emitOp(opcode.op.swap);
                try s.emitOpU16(opcode.op.apply, 0);
            },
        }
        s.last_was_super = false;
    }
}

fn parseNewExpr(s: *ParseState, flags: ParseFlags) Error!void {
    try s.advance(); // consume 'new'
    // F4 slice 2: `new X(a, b)` only — no chained `new new ...`, no
    // `new.target`, no member lookup before the args. The QuickJS
    // grammar permits MemberExpression here; we'll grow this once F4
    // proves out.
    try parsePrimary(s, flags);
    if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
        try s.emitOp(opcode.op.dup);
        const shape = try parseCallArgs(s, flags);
        s.last_anonymous_function_expr = false;
        switch (shape) {
            .direct => |argc| try s.emitOpU16(opcode.op.call_constructor, argc),
            .applied => {
                // `new X(...args)`. Stack on entry to apply: [func, array].
                // QuickJS rewrites with perm3 to feed apply a dummy `this`
                // (`quickjs.c:26693-26697`); for the plain `new` path we
                // synthesize that `this` slot here.
                try s.emitOp(opcode.op.@"undefined");
                try s.emitOp(opcode.op.swap);
                try s.emitOpU16(opcode.op.apply, 1); // 1 = is_new
            },
        }
    } else {
        // `new X` (no args) is equivalent to `new X()`.
        try s.emitOpU16(opcode.op.call_constructor, 0);
    }
}

fn parseMemberChain(s: *ParseState, flags: ParseFlags, chain_buf: []usize, chain_count: *usize) Error!void {
    while (true) {
        const k = s.peekKind();
        if (k == @as(tok.TokenKind, @intCast('.'))) {
            s.last_anonymous_function_expr = false;
            try s.advance();
            const name = if (s.peekKind() == tok.TOK_IDENT)
                s.token.payload.ident.atom
            else if (s.peekKind() == tok.TOK_DELETE)
                @as(Atom, 9)
            else if (s.peekKind() == tok.TOK_CATCH)
                @as(Atom, 25)
            else
                return Error.UnexpectedToken;
            try s.advance();
            // If a call follows, use get_field2 to keep `obj` on the stack
            // so we can lower as `obj func args... call_method`. Otherwise
            // a plain get_field is sufficient.
            // F7: if base was super, use get_super_value for property access.
            // Note: get_super_value2 doesn't exist in QuickJS, so super method
            // calls temporarily use get_field2 as a placeholder.
            const was_super = s.last_was_super;
            s.last_was_super = false;
            if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
                if (was_super) {
                    // TODO: F7 proper super method call - QuickJS uses different opcodes
                    try s.emitOpAtom(opcode.op.get_field2, name);
                } else {
                    try s.emitOpAtom(opcode.op.get_field2, name);
                }
                const shape = try parseCallArgs(s, flags);
                s.last_anonymous_function_expr = false;
                switch (shape) {
                    .direct => |argc| try s.emitOpU16(opcode.op.call_method, argc),
                    .applied => {
                        // Method call with spread. Stack: [obj, func, array].
                        // QuickJS emits `perm3 ; apply 0` (`quickjs.c:26672-26676`).
                        try s.emitOp(opcode.op.perm3);
                        try s.emitOpU16(opcode.op.apply, 0);
                    },
                }
            } else {
                if (was_super) {
                    try s.emitOpAtom(opcode.op.get_super_value, name);
                } else if (name == atom_module.ids.length and
                    s.peekKind() != @as(tok.TokenKind, @intCast('=')) and
                    compoundAssignOpcode(s.peekKind()) == null and
                    s.peekKind() != tok.TOK_INC and
                    s.peekKind() != tok.TOK_DEC)
                {
                    try s.emitOp(opcode.op.get_length);
                } else {
                    try s.emitOpAtom(opcode.op.get_field, name);
                }
            }
        } else if (k == tok.TOK_QUESTION_MARK_DOT) {
            s.last_anonymous_function_expr = false;
            // Optional-chain access: `obj?.x` / `obj?.[k]` / `obj?.()`.
            // QuickJS (`quickjs.c:26158` `optional_chain_test`) emits an
            // inline check at each `?.` site: dup the receiver, check
            // null/undefined, branch to either the normal access (NEXT)
            // or the chain exit (push undefined and goto). The chain
            // exit address is shared across all `?.` in the same
            // parseLhsExpr call and patched at chain end.
            try s.advance();
            try emitOptionalChainTest(s, chain_buf, chain_count, 1);
            const next = s.peekKind();
            if (next == @as(tok.TokenKind, @intCast('['))) {
                try s.advance();
                try parseExpr(s);
                try expectPunct(s, ']');
                if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
                    // `obj?.[k](args)` — keep obj on stack via get_array_el2.
                    try s.emitOp(opcode.op.get_array_el2);
                    const shape = try parseCallArgs(s, flags);
                    s.last_anonymous_function_expr = false;
                    switch (shape) {
                        .direct => |argc| try s.emitOpU16(opcode.op.call_method, argc),
                        .applied => {
                            try s.emitOp(opcode.op.perm3);
                            try s.emitOpU16(opcode.op.apply, 0);
                        },
                    }
                } else {
                    try s.emitOp(opcode.op.get_array_el);
                }
            } else if (next == @as(tok.TokenKind, @intCast('('))) {
                // `a?.()` — optional function call. The chain test drop
                // already cleared `a`; on the success path `a` is the
                // function receiver, args follow on the stack, then a
                // plain `call` consumes them.
                const shape = try parseCallArgs(s, flags);
                s.last_anonymous_function_expr = false;
                switch (shape) {
                    .direct => |argc| try s.emitOpU16(opcode.op.call, argc),
                    .applied => {
                        try s.emitOp(opcode.op.@"undefined");
                        try s.emitOp(opcode.op.swap);
                        try s.emitOpU16(opcode.op.apply, 0);
                    },
                }
            } else if (next == tok.TOK_IDENT) {
                const name = s.token.payload.ident.atom;
                try s.advance();
                if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
                    // `obj?.b(args)` — method call. Use get_field2 to
                    // keep obj on the stack as the call's `this`.
                    try s.emitOpAtom(opcode.op.get_field2, name);
                    const shape = try parseCallArgs(s, flags);
                    s.last_anonymous_function_expr = false;
                    switch (shape) {
                        .direct => |argc| try s.emitOpU16(opcode.op.call_method, argc),
                        .applied => {
                            try s.emitOp(opcode.op.perm3);
                            try s.emitOpU16(opcode.op.apply, 0);
                        },
                    }
                } else {
                    try s.emitOpAtom(opcode.op.get_field, name);
                }
            } else {
                return Error.UnexpectedToken;
            }
        } else if (k == @as(tok.TokenKind, @intCast('['))) {
            s.last_anonymous_function_expr = false;
            try s.advance();
            try parseExpr(s);
            try expectPunct(s, ']');
            // Same shape as dotted: if a call follows, keep obj on stack via
            // get_array_el2 + call_method.
            if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
                try s.emitOp(opcode.op.get_array_el2);
                const shape = try parseCallArgs(s, flags);
                s.last_anonymous_function_expr = false;
                switch (shape) {
                    .direct => |argc| try s.emitOpU16(opcode.op.call_method, argc),
                    .applied => {
                        try s.emitOp(opcode.op.perm3);
                        try s.emitOpU16(opcode.op.apply, 0);
                    },
                }
            } else {
                try s.emitOp(opcode.op.get_array_el);
            }
        } else if (k == @as(tok.TokenKind, @intCast('('))) {
            s.last_anonymous_function_expr = false;
            const shape = try parseCallArgs(s, flags);
            s.last_anonymous_function_expr = false;
            switch (shape) {
                .direct => |argc| try s.emitOpU16(opcode.op.call, argc),
                .applied => {
                    // Plain function call with spread. Stack: [func, array].
                    // QuickJS rearranges to [func, undef, array] for apply
                    // (`quickjs.c:26699-26703`).
                    try s.emitOp(opcode.op.@"undefined");
                    try s.emitOp(opcode.op.swap);
                    try s.emitOpU16(opcode.op.apply, 0);
                },
            }
        } else if (k == tok.TOK_TEMPLATE) {
            s.last_anonymous_function_expr = false;
            // Tagged template `tag\`...\``. The previously emitted tag
            // expression sits on the stack. If the tag was a member
            // access we rewrite the trailing get_field/get_array_el to
            // its `*2` form so the receiver stays on the stack as
            // `this` for the call. Mirror `quickjs.c:26480..26486` /
            // `js_parse_template(s, 1, &arg_count)` (`quickjs.c:23880`,
            // `call=1` branch).
            //
            // **F12 deviation**: the template-object construction
            // (sealed array of cooked strings with a `raw` property
            // pointing to a sealed array of raw strings) belongs to F12
            // (per `PARSER_REWRITE_PLAN.md` §2 phase map and §F12). For
            // F4 we emit `OP_undefined` as a placeholder for that
            // template-object slot so the parser accepts the syntax and
            // the call shape matches QuickJS; runtime semantics await
            // F12 wiring.
            const code = s.function.code;
            var use_method_call = false;
            if (code.len >= 5 and code[code.len - 5] == opcode.op.get_field) {
                s.function.code[code.len - 5] = opcode.op.get_field2;
                use_method_call = true;
            } else if (code.len >= 1 and code[code.len - 1] == opcode.op.get_array_el) {
                s.function.code[code.len - 1] = opcode.op.get_array_el2;
                use_method_call = true;
            }
            try s.emitOp(opcode.op.@"undefined"); // placeholder template object
            var argc: u16 = 1; // template object counts as the first arg
            while (true) {
                const part = s.token.payload.str.template orelse return Error.UnexpectedToken;
                if (part == .no_substitution or part == .tail) {
                    try s.advance();
                    break;
                }
                // .head or .middle: parse substitution then resume.
                try s.advance();
                try parseExpr(s);
                argc += 1;
                if (s.peekKind() != @as(tok.TokenKind, @intCast('}'))) {
                    return Error.UnexpectedToken;
                }
                s.lex.freeToken(&s.token);
                s.token = try s.lex.nextTemplatePartAfterBrace();
            }
            if (use_method_call) {
                try s.emitOpU16(opcode.op.call_method, argc);
            } else {
                try s.emitOpU16(opcode.op.call, argc);
            }
            s.last_anonymous_function_expr = false;
        } else {
            break;
        }
    }
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
    /// `perm3` for method calls / `new`). Mirrors `quickjs.c:26667-26706`.
    applied,
};

/// Emit the QuickJS `optional_chain_test` sequence (`quickjs.c:26158`):
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
    s: *ParseState,
    chain_buf: []usize,
    chain_count: *usize,
    drop_count: u8,
) Error!void {
    if (chain_count.* >= chain_buf.len) return Error.OutOfMemory;
    try s.emitOp(opcode.op.dup);
    try s.emitOp(opcode.op.is_undefined_or_null);
    const next_jump = try emitForwardJump(s, opcode.op.if_false);
    var i: u8 = 0;
    while (i < drop_count) : (i += 1) {
        try s.emitOp(opcode.op.drop);
    }
    try s.emitOp(opcode.op.@"undefined");
    const exit_jump = try emitForwardJump(s, opcode.op.goto);
    try patchForwardJump(s, next_jump);
    chain_buf[chain_count.*] = exit_jump;
    chain_count.* += 1;
}

/// Parse a `(arg0, arg1, ...)` argument list and return the call shape.
/// Caller consumed nothing yet — this consumes the leading `(` and the
/// matching `)`.
fn parseCallArgs(s: *ParseState, flags: ParseFlags) Error!CallArgsShape {
    try expectPunct(s, '(');
    var argc: u16 = 0;
    var has_spread = false;
    while (s.peekKind() != @as(tok.TokenKind, @intCast(')'))) {
        if (s.peekKind() == tok.TOK_ELLIPSIS) {
            has_spread = true;
            break;
        }
        try parseAssignExpr2(s, flags);
        argc += 1;
        if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) {
            try s.advance();
            continue;
        }
        break;
    }
    if (!has_spread) {
        try expectPunct(s, ')');
        return .{ .direct = argc };
    }
    // Spread path mirrors `quickjs.c:26633..26664`. The leading args
    // become an array, then each remaining arg is appended (via the
    // iterator protocol for spread, via define_array_el+inc otherwise).
    try s.emitOpU16(opcode.op.array_from, argc);
    try s.emitOpI32(opcode.op.push_i32, @intCast(argc));
    while (s.peekKind() != @as(tok.TokenKind, @intCast(')'))) {
        if (s.peekKind() == tok.TOK_ELLIPSIS) {
            try s.advance();
            try parseAssignExpr2(s, flags);
            try s.emitOp(opcode.op.append);
        } else {
            try parseAssignExpr2(s, flags);
            try s.emitOp(opcode.op.define_array_el);
            try s.emitOp(opcode.op.inc);
        }
        if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) {
            try s.advance();
            continue;
        }
        break;
    }
    try expectPunct(s, ')');
    try s.emitOp(opcode.op.drop); // drop the index, leave array on stack
    return .applied;
}

/// Parse a primary expression. `js_parse_primary_expr` lives inside
/// `js_parse_postfix_expr` in QuickJS (`quickjs.c:25500..25800`).
fn parsePrimary(s: *ParseState, flags: ParseFlags) Error!void {
    const k = s.peekKind();
    switch (k) {
        tok.TOK_NUMBER => {
            const value = s.token.payload.num.value;
            // Encode small integers with push_i32 to match QuickJS.
            if (s.token.payload.num.is_bigint) {
                const bigint_value = std.fmt.parseInt(i32, s.token.payload.num.bigint_text, 0) catch 0;
                try s.emitOpI32(opcode.op.push_bigint_i32, bigint_value);
            } else if (numberIsExactI32(value)) {
                try s.emitOpI32(opcode.op.push_i32, @as(i32, @intFromFloat(value)));
            } else {
                try s.emitPushConst(Value.float64(value));
            }
            try s.advance();
        },
        tok.TOK_STRING => {
            // QuickJS emits `OP_push_atom_value <atom>` for short string
            // literals (`quickjs.c:25510`). We always intern; the empty
            // string is special-cased to `push_empty_string`.
            const bytes = s.token.payload.str.bytes;
            if (bytes.len == 0) {
                try s.emitOp(opcode.op.push_empty_string);
            } else {
                const atom_id = try s.function.atoms.internString(bytes);
                defer s.function.atoms.free(atom_id);
                try s.emitOpAtom(opcode.op.push_atom_value, atom_id);
            }
            try s.advance();
        },
        tok.TOK_TEMPLATE => return parseTemplate(s, flags),
        tok.TOK_TRUE => {
            try s.emitOp(opcode.op.push_true);
            try s.advance();
        },
        tok.TOK_FALSE => {
            try s.emitOp(opcode.op.push_false);
            try s.advance();
        },
        tok.TOK_NULL => {
            try s.emitOp(opcode.op.@"null");
            try s.advance();
        },
        tok.TOK_THIS => {
            try s.emitOp(opcode.op.push_this);
            try s.advance();
            s.last_was_super = false;
        },
        tok.TOK_SUPER => {
            // F7: emit get_super as placeholder. Full super semantics
            // require class system integration and constructor context tracking.
            try s.emitOp(opcode.op.get_super);
            try s.advance();
            s.last_was_super = true;
        },
        tok.TOK_CLASS => {
            // Class expression
            try parseClass(s, false);
        },
        tok.TOK_FUNCTION => {
            // Function expression: function or async function
            // Check for async function
            const is_async = s.isIdent("async");
            if (is_async) {
                try s.advance();
            }
            const func_kind: ParseFunctionKind = if (is_async) .async else .normal;
            try parseFunctionExpr(s, func_kind);
        },
        tok.TOK_IDENT => {
            // Check for async function (async is a contextual keyword)
            if (s.isIdent("async") and s.peekNextKind() == tok.TOK_FUNCTION) {
                try s.advance(); // consume async
                const func_kind: ParseFunctionKind = .async;
                try parseFunctionExpr(s, func_kind);
                s.last_was_super = false;
                return;
            }
            // Check if this is an arrow function: ident => or async ident =>
            // Use proper lexer state save/restore for the lookahead so we
            // don't desynchronize the lexer position from the cached token.
            if (checkIdentArrowHead(s)) {
                // Check for async arrow function
                const is_async = s.isIdent("async");
                const func_kind: ParseFunctionKind = if (is_async) .async else .normal;
                if (is_async) {
                    try s.advance();
                }
                return parseArrowFunction(s, func_kind);
            }
            const ident = s.token.payload.ident.atom;
            if (s.skip_next_ident_get) |skip_atom| {
                if (skip_atom == ident) {
                    s.skip_next_ident_get = null;
                } else {
                    s.skip_next_ident_get = null;
                    try s.emitScopeGetVar(ident);
                }
            } else {
                try s.emitScopeGetVar(ident);
            }
            try s.advance();
            s.last_was_super = false;
        },
        else => {
            if (k == @as(tok.TokenKind, @intCast('('))) {
                // Check if this is an arrow function
                if (checkArrowHead(s)) {
                    // Check for async arrow function
                    const is_async = s.isIdent("async");
                    const func_kind: ParseFunctionKind = if (is_async) .async else .normal;
                    if (is_async) {
                        try s.advance();
                    }
                    return parseArrowFunction(s, func_kind);
                }
                try s.advance();
                try parseExpr2(s, flags);
                try expectPunct(s, ')');
                return;
            }
            if (k == @as(tok.TokenKind, @intCast('['))) {
                return parseArrayLiteral(s, flags);
            }
            if (k == @as(tok.TokenKind, @intCast('{'))) {
                return parseObjectLiteral(s, flags);
            }
            return Error.UnexpectedToken;
        },
    }
}

/// `js_parse_template` (`quickjs.c:23880`). F4 slice 5: non-tagged
/// template literals. Lowers `\`a${b}c${d}e\`` to:
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
/// (`tag\`...\``) and lazy raw-string evaluation are deferred to a
/// later F4 slice that follows the `call=1` branch in
/// `js_parse_template`.
fn parseTemplate(s: *ParseState, flags: ParseFlags) Error!void {
    _ = flags;
    var depth: u16 = 0;
    while (s.peekKind() == tok.TOK_TEMPLATE) {
        const part_payload = s.token.payload.str;
        const bytes = part_payload.bytes;
        const part = part_payload.template orelse return Error.UnexpectedToken;

        if (bytes.len != 0 or depth == 0) {
            if (bytes.len == 0) {
                try s.emitOp(opcode.op.push_empty_string);
            } else {
                const atom_id = try s.function.atoms.internString(bytes);
                defer s.function.atoms.free(atom_id);
                try s.emitOpAtom(opcode.op.push_atom_value, atom_id);
            }
            if (depth == 0) {
                if (part == .no_substitution) {
                    // Whole template is a single string constant; skip
                    // the concat-method setup and just consume the token.
                    try s.advance();
                    return;
                }
                const concat_atom = try s.function.atoms.internString("concat");
                defer s.function.atoms.free(concat_atom);
                try s.emitOpAtom(opcode.op.get_field2, concat_atom);
            }
            depth += 1;
        }

        if (part == .tail) {
            try s.emitOpU16(opcode.op.call_method, depth - 1);
            try s.advance(); // consume the tail TOK_TEMPLATE
            return;
        }
        // .head or .middle: parse the substitution expression and
        // resume template lexing after the closing `}`.
        try s.advance(); // consume head/middle TOK_TEMPLATE
        try parseExpr(s);
        depth += 1;
        if (s.peekKind() != @as(tok.TokenKind, @intCast('}'))) return Error.UnexpectedToken;
        // The lookahead `}` has already moved lex.pos one byte past it;
        // free the token and ask the lexer for the next template part
        // (middle or tail) without re-bumping.
        s.lex.freeToken(&s.token);
        s.token = try s.lex.nextTemplatePartAfterBrace();
    }
    return Error.UnexpectedToken;
}

/// `js_parse_array_literal` (`quickjs.c:25194`). F4 slice 2 introduced
/// the dense form; slice 4 added holes; slice 6 (this) adds spread
/// (`[a, ...b]`). The QuickJS strategy switches dynamically: leading
/// non-spread elements collect into an `array_from <count>`; on the
/// first spread, the parser pushes `<count>` as the running index,
/// then alternates between `define_array_el; inc` (for plain entries)
/// and `append` (for spread entries). The trailing `drop` removes
/// the index, leaving the constructed array on the stack.
fn parseArrayLiteral(s: *ParseState, flags: ParseFlags) Error!void {
    try s.advance(); // consume '['
    var count: u16 = 0;
    var sparse_active = false;
    var sparse_index: u32 = 0;
    var spread_active = false;
    while (s.peekKind() != @as(tok.TokenKind, @intCast(']'))) {
        if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) {
            // Hole — leading or interior. QuickJS switches to an
            // object-style sparse array shape: `array_from <dense-prefix>`
            // followed by `define_field "<index>"` for present elements.
            if (spread_active) {
                try s.emitOp(opcode.op.@"undefined");
                try s.emitOp(opcode.op.define_array_el);
                try s.emitOp(opcode.op.inc);
            } else {
                if (!sparse_active) {
                    try s.emitOpU16(opcode.op.array_from, count);
                    sparse_active = true;
                    sparse_index = count;
                }
                sparse_index += 1;
            }
            try s.advance();
            continue;
        }
        if (s.peekKind() == tok.TOK_ELLIPSIS) {
            if (!spread_active) {
                // Switch from collect-then-array_from to running-array
                // mode. Emit array_from on the leading elements and push
                // <count> as the initial index.
                try s.emitOpU16(opcode.op.array_from, count);
                try s.emitOpI32(opcode.op.push_i32, @intCast(count));
                spread_active = true;
            }
            try s.advance();
            try parseAssignExpr2(s, flags);
            try s.emitOp(opcode.op.append);
        } else {
            try parseAssignExpr2(s, flags);
            if (spread_active) {
                try s.emitOp(opcode.op.define_array_el);
                try s.emitOp(opcode.op.inc);
            } else if (sparse_active) {
                var index_buf: [16]u8 = undefined;
                const index_name = std.fmt.bufPrint(&index_buf, "{d}", .{sparse_index}) catch return Error.UnexpectedToken;
                const index_atom = try s.function.atoms.internString(index_name);
                defer s.function.atoms.free(index_atom);
                try s.emitOpAtom(opcode.op.define_field, index_atom);
                sparse_index += 1;
            } else {
                count += 1;
            }
        }
        if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) {
            try s.advance();
            continue;
        }
        break;
    }
    try expectPunct(s, ']');
    if (spread_active) {
        try s.emitOp(opcode.op.drop); // drop the running index
    } else if (!sparse_active) {
        try s.emitOpU16(opcode.op.array_from, count);
    }
}

/// `js_parse_object_literal` (`quickjs.c:24361`). F4 slice 2 supports
/// `{ name: value, ... }` and shorthand `{ name }`. Computed keys,
/// methods, getters/setters, spread, and `__proto__` are deferred.
fn parseObjectLiteral(s: *ParseState, flags: ParseFlags) Error!void {
    try s.advance(); // consume '{'
    try s.emitOp(opcode.op.object);
    if (s.peekKind() != @as(tok.TokenKind, @intCast('}'))) {
        while (true) {
            try parseObjectProperty(s, flags);
            if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) {
                try s.advance();
                if (s.peekKind() == @as(tok.TokenKind, @intCast('}'))) break;
                continue;
            }
            break;
        }
    }
    try expectPunct(s, '}');
}

fn parseObjectProperty(s: *ParseState, flags: ParseFlags) Error!void {
    const k = s.peekKind();
    
    // Spread property: ...obj
    if (k == tok.TOK_ELLIPSIS) {
        try s.advance();
        try parseAssignExpr2(s, flags);
        // TODO: F10 Use proper spread opcode (copy_data_properties)
        // For now, emit as regular property (placeholder)
        try s.emitOp(opcode.op.drop);
        return;
    }
    
    // Computed property name: [expr]: value
    if (k == @as(tok.TokenKind, @intCast('['))) {
        try s.advance();
        try parseAssignExpr2(s, flags);
        try expectPunct(s, ']');
        try expectPunct(s, ':');
        try parseAssignExpr2(s, flags);
        // TODO: F10 Use proper computed property opcode
        // For now, emit as regular property (placeholder)
        try s.emitOp(opcode.op.drop);
        try s.emitOp(opcode.op.drop);
        return;
    }
    
    if (k == tok.TOK_IDENT) {
        const name = s.token.payload.ident.atom;
        try s.advance();
        
        // Method shorthand: method() {}
        if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
            // Parse method parameters and body
            try parseFunctionParamsAndBody(s, .method);
            // TODO: F10 Register method property
            try s.emitOp(opcode.op.drop);
            return;
        }
        
        if (s.peekKind() == @as(tok.TokenKind, @intCast(':'))) {
            try s.advance();
            try parseAssignExpr2(s, flags);
        } else {
            // Shorthand `{ x }` — stack: obj, then push value of `x`.
            try s.emitScopeGetVar(name);
        }
        try s.emitOpAtom(opcode.op.define_field, name);
        return;
    }
    if (k == tok.TOK_STRING) {
        const bytes = s.token.payload.str.bytes;
        const atom_id = try s.function.atoms.internString(bytes);
        defer s.function.atoms.free(atom_id);
        try s.advance();
        try expectPunct(s, ':');
        try parseAssignExpr2(s, flags);
        try s.emitOpAtom(opcode.op.define_field, atom_id);
        return;
    }
    if (k == tok.TOK_NUMBER) {
        // Numeric property keys are stringified and interned.
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{s.token.payload.num.value}) catch
            return Error.InvalidNumberLiteral;
        const atom_id = try s.function.atoms.internString(text);
        defer s.function.atoms.free(atom_id);
        try s.advance();
        try expectPunct(s, ':');
        try parseAssignExpr2(s, flags);
        try s.emitOpAtom(opcode.op.define_field, atom_id);
        return;
    }
    return Error.UnexpectedToken;
}

// =====================================================================
// Helpers
// =====================================================================

/// Map an assignment-operator token to its compound-arithmetic opcode.
/// Returns `null` for plain `=` and non-assignment tokens.
fn compoundAssignOpcode(k: tok.TokenKind) ?u8 {
    return switch (k) {
        tok.TOK_MUL_ASSIGN => opcode.op.mul,
        tok.TOK_DIV_ASSIGN => opcode.op.div,
        tok.TOK_MOD_ASSIGN => opcode.op.mod,
        tok.TOK_PLUS_ASSIGN => opcode.op.add,
        tok.TOK_MINUS_ASSIGN => opcode.op.sub,
        tok.TOK_SHL_ASSIGN => opcode.op.shl,
        tok.TOK_SAR_ASSIGN => opcode.op.sar,
        tok.TOK_SHR_ASSIGN => opcode.op.shr,
        tok.TOK_AND_ASSIGN => opcode.op.@"and",
        tok.TOK_XOR_ASSIGN => opcode.op.xor,
        tok.TOK_OR_ASSIGN => opcode.op.@"or",
        tok.TOK_POW_ASSIGN => opcode.op.pow,
        else => null,
    };
}

/// Mirror `quickjs.c:27083..27201` — token-to-opcode level table.
fn matchBinaryOp(k: tok.TokenKind, level: u8, flags: ParseFlags) ?u8 {
    return switch (level) {
        1 => switch (k) {
            @as(tok.TokenKind, @intCast('*')) => opcode.op.mul,
            @as(tok.TokenKind, @intCast('/')) => opcode.op.div,
            @as(tok.TokenKind, @intCast('%')) => opcode.op.mod,
            else => null,
        },
        2 => switch (k) {
            @as(tok.TokenKind, @intCast('+')) => opcode.op.add,
            @as(tok.TokenKind, @intCast('-')) => opcode.op.sub,
            else => null,
        },
        3 => switch (k) {
            tok.TOK_SHL => opcode.op.shl,
            tok.TOK_SAR => opcode.op.sar,
            tok.TOK_SHR => opcode.op.shr,
            else => null,
        },
        4 => switch (k) {
            @as(tok.TokenKind, @intCast('<')) => opcode.op.lt,
            @as(tok.TokenKind, @intCast('>')) => opcode.op.gt,
            tok.TOK_LTE => opcode.op.lte,
            tok.TOK_GTE => opcode.op.gte,
            tok.TOK_INSTANCEOF => opcode.op.instanceof,
            tok.TOK_IN => if (flags.in_accepted) opcode.op.in else null,
            else => null,
        },
        5 => switch (k) {
            tok.TOK_EQ => opcode.op.eq,
            tok.TOK_NEQ => opcode.op.neq,
            tok.TOK_STRICT_EQ => opcode.op.strict_eq,
            tok.TOK_STRICT_NEQ => opcode.op.strict_neq,
            else => null,
        },
        6 => switch (k) {
            @as(tok.TokenKind, @intCast('&')) => opcode.op.@"and",
            else => null,
        },
        7 => switch (k) {
            @as(tok.TokenKind, @intCast('^')) => opcode.op.xor,
            else => null,
        },
        8 => switch (k) {
            @as(tok.TokenKind, @intCast('|')) => opcode.op.@"or",
            else => null,
        },
        else => null,
    };
}

fn expectPunct(s: *ParseState, ch: u8) Error!void {
    if (!s.isPunct(ch)) return Error.UnexpectedToken;
    try s.advance();
}

fn numberIsExactI32(value: f64) bool {
    if (std.math.isNan(value) or std.math.isInf(value)) return false;
    if (value < @as(f64, std.math.minInt(i32)) or value > @as(f64, std.math.maxInt(i32))) return false;
    const truncated: f64 = @floatFromInt(@as(i32, @intFromFloat(value)));
    return truncated == value;
}

/// Emit a forward-jump opcode with a placeholder absolute target. The
/// caller passes the offset back to `patchForwardJump` once the target
/// is known. F4 first slice uses absolute u32 offsets; F10's
/// resolve_labels lowers these to relative `goto8`/`goto16`/`label`s.
fn emitForwardJump(s: *ParseState, op_id: u8) Error!usize {
    var bytes: [5]u8 = undefined;
    bytes[0] = op_id;
    std.mem.writeInt(u32, bytes[1..5], 0, .little);
    const operand_offset = s.currentCodeLen() + 1;
    try s.appendBytes(&bytes);
    return operand_offset;
}

/// Emit a jump opcode whose target is already known (for backward jumps,
/// e.g. while-loop continue or for-loop back edge). F10's resolve_labels
/// will lower these to relative `goto8`/`goto16` once the pipeline lands.
fn emitBackwardJump(s: *ParseState, op_id: u8, target: u32) Error!void {
    var bytes: [5]u8 = undefined;
    bytes[0] = op_id;
    std.mem.writeInt(u32, bytes[1..5], target, .little);
    try s.appendBytes(&bytes);
}

fn predeclareFunctionBodyVars(s: *ParseState) Error!void {
    if (s.peekKind() != '{') return;
    const saved_pos = s.lex.pos;
    const saved_line = s.lex.line;
    const saved_col = s.lex.col;
    const saved_got_lf = s.lex.got_lf;
    const saved_mark_pos = s.lex.mark_pos;
    const saved_mark_line = s.lex.mark_line;
    const saved_mark_col = s.lex.mark_col;
    defer {
        s.lex.pos = saved_pos;
        s.lex.line = saved_line;
        s.lex.col = saved_col;
        s.lex.got_lf = saved_got_lf;
        s.lex.mark_pos = saved_mark_pos;
        s.lex.mark_line = saved_mark_line;
        s.lex.mark_col = saved_mark_col;
    }

    var body_depth: usize = 0;
    while (true) {
        var t = s.lex.next() catch return Error.UnexpectedToken;
        defer s.lex.freeToken(&t);
        switch (t.val) {
            tok.TOK_EOF => return,
            '{' => body_depth += 1,
            '}' => {
                if (body_depth == 0) return;
                body_depth -= 1;
            },
            tok.TOK_FUNCTION => try skipFunctionInPredeclareScan(s),
            tok.TOK_VAR => try predeclareVarDeclarators(s),
            else => {},
        }
    }
}

fn skipFunctionInPredeclareScan(s: *ParseState) Error!void {
    while (true) {
        var t = s.lex.next() catch return Error.UnexpectedToken;
        defer s.lex.freeToken(&t);
        if (t.val == tok.TOK_EOF) return;
        if (t.val == '{') break;
    }
    var depth: usize = 1;
    while (depth != 0) {
        var t = s.lex.next() catch return Error.UnexpectedToken;
        defer s.lex.freeToken(&t);
        switch (t.val) {
            tok.TOK_EOF => return,
            '{' => depth += 1,
            '}' => depth -= 1,
            else => {},
        }
    }
}

fn predeclareVarDeclarators(s: *ParseState) Error!void {
    var depth: usize = 0;
    var want_ident = true;
    while (true) {
        var t = s.lex.next() catch return Error.UnexpectedToken;
        defer s.lex.freeToken(&t);
        switch (t.val) {
            tok.TOK_EOF, ';' => return,
            ',' => {
                if (depth == 0) want_ident = true;
            },
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                if (depth == 0) return;
                depth -= 1;
            },
            tok.TOK_IDENT => {
                if (want_ident and depth == 0) {
                    const atom_id = t.payload.ident.atom;
                    const fd = s.cur_func();
                    if (fd.findVar(atom_id) < 0 and fd.findArg(atom_id) < 0) {
                        _ = try fd.addScopeVar(atom_id, .normal, 0, false, false);
                    }
                    want_ident = false;
                }
            },
            else => {},
        }
    }
}

// =====================================================================
// Statement parsing (F5)
// =====================================================================

/// Mirror `js_parse_block` (`quickjs.c:27827`).
///
/// Pushes a new lexical scope before parsing the block contents and
/// pops it on exit, so `let` / `const` declarations get attached to
/// the correct `VarScope` in `function_def.scopes`. The interim
/// pipeline ignores `function_def`, but the full FunctionDef-based
/// `resolve_variables` (§F10.1 Outstanding) will walk this chain.
pub fn parseBlock(s: *ParseState) Error!void {
    try s.expectToken('{');
    try s.pushScope();
    // Check for directive prologue (simplified)
    try parseDirectives(s);
    while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
        try parseStatementOrDecl(s, DeclMask{ .func = true, .func_with_label = true, .other = true });
    }
    try s.expectToken('}');
    s.popScope();
}

/// Mirror `js_parse_directives` (`quickjs.c:35642`) - simplified version.
/// Full directive handling deferred to F6/F10.
fn parseDirectives(s: *ParseState) Error!void {
    // TODO: Full directive prologue handling in F6/F10
    // For now, just skip string literals at the start of a block
    // and check for "use strict"
    while (s.peekKind() == tok.TOK_STRING) {
        if (s.peekNextKind() != @as(tok.TokenKind, @intCast(';'))) break;
        const str_payload = s.token.payload.str;
        // Check if this is "use strict"
        if (str_payload.bytes.len == 10 and
            std.mem.eql(u8, str_payload.bytes, "use strict")) {
            s.is_strict = true;
        }
        try s.advance();
        // Check for semicolon or ASI
        if (s.isPunct(';')) {
            try s.advance();
        } else if (!s.gotLineTerminator() and
                   s.peekKind() != '}' and
                   s.peekKind() != tok.TOK_EOF) {
            // Not a directive, break
            break;
        }
    }
}

/// Mirror `js_parse_statement_or_decl` (`quickjs.c:28228`).
pub fn parseStatementOrDecl(s: *ParseState, decl_mask: DeclMask) Error!void {
    const tok_kind = s.peekKind();

    switch (tok_kind) {
        '{' => try parseBlock(s),
        tok.TOK_RETURN => {
            if (s.is_eval) return Error.UnexpectedToken;
            try s.advance();
            if (s.peekKind() != ';' and s.peekKind() != '}' and !s.gotLineTerminator()) {
                const saved_return_expr_mode = s.return_expr_mode;
                const saved_return_expr_emitted = s.return_expr_emitted_return;
                s.return_expr_mode = true;
                s.return_expr_emitted_return = false;
                try parseExpr(s);
                const emitted_return = s.return_expr_emitted_return;
                s.return_expr_mode = saved_return_expr_mode;
                s.return_expr_emitted_return = saved_return_expr_emitted;
                if (!emitted_return) try s.emitOp(if (s.in_async) opcode.op.return_async else opcode.op.@"return");
            } else {
                try s.emitOp(opcode.op.return_undef);
            }
            _ = try s.expectSemicolon();
        },
        tok.TOK_THROW => {
            try s.advance();
            if (s.gotLineTerminator()) return Error.UnexpectedToken;
            try parseExpr(s);
            try s.emitOp(opcode.op.throw);
            _ = try s.expectSemicolon();
        },
        tok.TOK_VAR, tok.TOK_LET, tok.TOK_CONST => {
            if (!decl_mask.other and (tok_kind == tok.TOK_LET or tok_kind == tok.TOK_CONST)) {
                return Error.UnexpectedToken;
            }
            const var_tok = tok_kind;
            try s.advance();
            s.last_var_decl_atom = null;
            s.last_var_decl_can_skip_get = false;
            try parseVar(s, var_tok);
            _ = try s.expectSemicolon();
            if (var_tok == tok.TOK_VAR and s.last_var_decl_can_skip_get and s.last_var_decl_atom != null and s.peekKind() == tok.TOK_IDENT and s.token.payload.ident.atom == s.last_var_decl_atom.?) {
                s.skip_next_ident_get = s.last_var_decl_atom;
            }
        },
        tok.TOK_FUNCTION => {
            if (!decl_mask.func and !decl_mask.func_with_label) {
                return Error.UnexpectedToken;
            }
            // Check for async function
            const is_async = s.isIdent("async");
            if (is_async) {
                try s.advance();
            }
            const func_kind: ParseFunctionKind = if (is_async) .async else .normal;
            try parseFunctionDecl(s, func_kind);
        },
        tok.TOK_CLASS => {
            if (!decl_mask.func) {
                return Error.UnexpectedToken;
            }
            try parseClass(s, true);
        },
        tok.TOK_IDENT => {
            // Check for async function declaration (async is a contextual keyword)
            if (s.isIdent("async") and s.peekNextKind() == tok.TOK_FUNCTION) {
                if (!decl_mask.func and !decl_mask.func_with_label) {
                    return Error.UnexpectedToken;
                }
                try s.advance(); // consume async
                const func_kind: ParseFunctionKind = .async;
                try parseFunctionDecl(s, func_kind);
                return;
            }
            // Not async function: fall through to expression statement.
            // Like the `else` branch, eval mode redirects the value
            // into `<ret>` instead of dropping it.
            try parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = s.eval_ret_idx >= 0 });
            _ = try s.expectSemicolon();
            const final_function_expr_stmt = s.emit_to_function_def and s.peekKind() == '}';
            if (s.eval_ret_idx >= 0) {
                try s.emitScopePutVar(ParseState.eval_ret_atom);
            } else if (s.suppress_expr_statement_drop) {
                s.suppress_expr_statement_drop = false;
            } else if (final_function_expr_stmt) {
                // Function epilogue will emit return_undef.
            } else {
                try s.emitOp(opcode.op.drop);
            }
        },
        tok.TOK_IMPORT => {
            if (!decl_mask.other) {
                return Error.UnexpectedToken;
            }
            try parseImport(s);
        },
        tok.TOK_EXPORT => {
            if (!decl_mask.other) {
                return Error.UnexpectedToken;
            }
            try parseExport(s);
        },
        tok.TOK_IF => {
            try s.advance();
            try s.expectToken('(');
            try parseExpr2(s, ParseFlags{ .in_accepted = true, .result_needed = s.eval_ret_idx >= 0 });
            try s.expectToken(')');
            const if_false_off = try emitForwardJump(s, opcode.op.if_false);
            try parseStatementOrDecl(s, DeclMask{});
            if (s.peekKind() == tok.TOK_ELSE) {
                try s.advance();
                const else_goto_off = try emitForwardJump(s, opcode.op.goto);
                // Patch if_false to land at the start of the else block.
                try patchForwardJump(s, if_false_off);
                try parseStatementOrDecl(s, DeclMask{});
                // Patch the goto-over-else to land after the else block.
                try patchForwardJump(s, else_goto_off);
            } else {
                // No else: patch if_false to land just past the then block.
                try patchForwardJump(s, if_false_off);
            }
        },
        tok.TOK_WHILE => {
            try s.advance();
            try s.expectToken('(');
            // Loop top: condition is evaluated each iteration.
            const top_pc: u32 = @intCast(s.function.code.len);
            try parseExpr(s);
            const exit_off = try emitForwardJump(s, opcode.op.if_false);
            try s.expectToken(')');
            // TODO: F10 push BlockEnv so labelled break/continue can target this loop.
            try parseStatementOrDecl(s, DeclMask{});
            // Back-edge to the top to re-test the condition.
            try emitBackwardJump(s, opcode.op.goto, top_pc);
            // Patch the if_false exit to land here.
            try patchForwardJump(s, exit_off);
        },
        tok.TOK_DO => {
            try s.advance();
            // Body starts at this pc; if_true at the bottom branches back here.
            const body_pc: u32 = @intCast(s.function.code.len);
            // TODO: F10 push BlockEnv so labelled break/continue can target this loop.
            try parseStatementOrDecl(s, DeclMask{});
            try s.expectToken(tok.TOK_WHILE);
            try s.expectToken('(');
            try parseExpr(s);
            try s.expectToken(')');
            // Back-edge: re-enter body when the test is truthy.
            try emitBackwardJump(s, opcode.op.if_true, body_pc);
            _ = try s.expectSemicolon();
        },
        tok.TOK_FOR => {
            try s.advance();
            try s.expectToken('(');

            // Check if this is for-in or for-of
            const is_for_in_of = s.checkForInOfHead();
            if (is_for_in_of) {
                try parseForInOf(s);
            } else {
                var for_scope_pushed = false;
                // C-style `for (init ; test ; update) body`. Lower as:
                //   init
                //   top: test ; if_false → end ; body ; update ; goto → top
                //   end:
                // This pattern keeps `continue` semantics consistent only
                // when continue jumps to `update`; F10 will introduce a
                // dedicated continue label for the labelled-break case.
                if (s.peekKind() == tok.TOK_VAR or s.peekKind() == tok.TOK_LET or s.peekKind() == tok.TOK_CONST) {
                    const var_tok = s.peekKind();
                    try s.advance();
                    if (var_tok == tok.TOK_LET or var_tok == tok.TOK_CONST) {
                        try s.pushScope();
                        for_scope_pushed = true;
                    }
                    const saved_tdz_at_decl = s.emit_lexical_tdz_at_decl;
                    s.emit_lexical_tdz_at_decl = for_scope_pushed;
                    defer s.emit_lexical_tdz_at_decl = saved_tdz_at_decl;
                    try parseVar(s, var_tok);
                    _ = try s.expectSemicolon();
                } else if (s.peekKind() != ';') {
                    try parseExpr(s);
                    try s.emitOp(opcode.op.drop);
                    _ = try s.expectSemicolon();
                } else {
                    try s.advance(); // consume ';'
                }

                // Top of the loop — re-tested each iteration.
                const top_pc: u32 = @intCast(s.function.code.len);

                // Test condition.
                if (s.peekKind() != ';') {
                    try parseExpr(s);
                } else {
                    try s.emitOp(opcode.op.push_true);
                }
                _ = try s.expectSemicolon();

                const exit_off = try emitForwardJump(s, opcode.op.if_false);

                // Parse the update while still inside the parenthesized
                // for-head, then move its emitted bytes after the body.
                const update_start = s.currentCodeLen();
                if (s.peekKind() != ')') {
                    try parseExpr(s);
                    try s.emitOp(opcode.op.drop);
                }
                const update_code = s.currentCode()[update_start..];
                var saved_update: []u8 = &.{};
                if (update_code.len != 0) {
                    saved_update = try s.function.memory.alloc(u8, update_code.len);
                    @memcpy(saved_update, update_code);
                }
                defer if (saved_update.len != 0) s.function.memory.free(u8, saved_update);
                try s.truncateCode(update_start);
                try s.expectToken(')');

                // TODO: F10 push BlockEnv so labelled break/continue can target this loop.

                // Body.
                try parseStatementOrDecl(s, DeclMask{});

                // Update (only run after a normal body completion; F10 will
                // also route `continue` here).
                if (saved_update.len != 0) try s.appendBytes(saved_update);

                // Back-edge to the top.
                try emitBackwardJump(s, opcode.op.goto, top_pc);

                // Patch the `if_false` exit to land here.
                try patchForwardJump(s, exit_off);
                if (for_scope_pushed) s.popScope();
            }
        },
        tok.TOK_BREAK, tok.TOK_CONTINUE => {
            // Syntactically accept `break;` / `continue;` (with optional
            // label) so test262 parser-only fixtures don't reject them,
            // but emit no jump yet — F10's resolve_labels pipeline owns
            // the BlockEnv chain that knows the right break/continue
            // target for the current loop / labelled statement / switch.
            // Until then, attempting to *execute* a function whose body
            // hits this site will simply fall through to the next opcode,
            // which is observably wrong; that's why this site is gated
            // behind the `partial` F5 status in TRACKING.md.
            try s.advance();
            if (!s.gotLineTerminator() and s.peekKind() == tok.TOK_IDENT) {
                try s.advance(); // consume the label name
            }
            _ = try s.expectSemicolon();
        },
        tok.TOK_SWITCH => {
            // Simplified switch lowering. Each case checks the discriminant,
            // and a matched case runs its body then jumps to the end (i.e.
            // an *implicit* break). C-style fallthrough between cases and
            // labelled break are deferred to F10's resolve_labels pipeline,
            // which has the per-case label tables to do this correctly.
            try s.advance();
            try s.expectToken('(');
            try parseExpr(s); // discriminant on stack
            try s.expectToken(')');
            try s.expectToken('{');

            // Up to 32 case bodies per switch — enough for typical code.
            // F10 will replace this with a properly-sized label table.
            var end_jumps: [32]usize = undefined;
            var end_jumps_count: usize = 0;
            var has_default = false;

            while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
                if (s.peekKind() == tok.TOK_CASE) {
                    try s.advance();
                    // dup ; case_expr ; strict_eq ; if_false → next_case
                    try s.emitOp(opcode.op.dup);
                    try parseExpr(s);
                    try s.expectToken(':');
                    try s.emitOp(opcode.op.strict_eq);
                    const next_case_off = try emitForwardJump(s, opcode.op.if_false);

                    // Matched: keep the discriminant on stack until the
                    // common switch epilogue, matching QuickJS's case shape.
                    while (s.peekKind() != tok.TOK_CASE and
                        s.peekKind() != tok.TOK_DEFAULT and
                        s.peekKind() != '}' and
                        s.peekKind() != tok.TOK_EOF)
                    {
                        try parseStatementOrDecl(s, DeclMask{});
                    }
                    if (end_jumps_count >= end_jumps.len) return Error.UnexpectedToken;
                    end_jumps[end_jumps_count] = try emitForwardJump(s, opcode.op.goto);
                    end_jumps_count += 1;

                    // Unmatched path lands at the next case header.
                    try patchForwardJump(s, next_case_off);
                } else if (s.peekKind() == tok.TOK_DEFAULT) {
                    if (has_default) return Error.UnexpectedToken;
                    try s.advance();
                    try s.expectToken(':');

                    // Default body label.
                    has_default = true;
                    while (s.peekKind() != tok.TOK_CASE and
                        s.peekKind() != tok.TOK_DEFAULT and
                        s.peekKind() != '}' and
                        s.peekKind() != tok.TOK_EOF)
                    {
                        try parseStatementOrDecl(s, DeclMask{});
                    }
                } else {
                    return Error.UnexpectedToken;
                }
            }
            try s.expectToken('}');

            // No case matched — jump to default if it exists, otherwise fall
            // through to the common discriminant drop.
            // Patch every case-end goto to land here.
            for (end_jumps[0..end_jumps_count]) |off| {
                try patchForwardJump(s, off);
            }
            try s.emitOp(opcode.op.drop);
        },
        tok.TOK_TRY => {
            try s.advance();
            const catch_off = try emitForwardJump(s, opcode.op.@"catch");
            try parseBlock(s);
            try s.emitOp(opcode.op.drop);
            const end_off = try emitForwardJump(s, opcode.op.goto);
            if (s.peekKind() == tok.TOK_CATCH) {
                try s.advance();
                try patchForwardJump(s, catch_off);
                try s.expectToken('(');
                if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
                const catch_atom = s.token.payload.ident.atom;
                try s.pushScope();
                _ = try s.addScopeVar(catch_atom, .normal, false, false);
                try s.advance();
                try s.expectToken(')');
                try s.emitScopePutVar(catch_atom);
                const rethrow_off = try emitForwardJump(s, opcode.op.@"catch");
                try parseBlock(s);
                try s.emitOp(opcode.op.drop);
                const catch_end_off = try emitForwardJump(s, opcode.op.goto);
                try patchForwardJump(s, rethrow_off);
                try s.emitOp(opcode.op.throw);
                try patchForwardJump(s, end_off);
                try patchForwardJump(s, catch_end_off);
                s.popScope();
            } else {
                try patchForwardJump(s, catch_off);
                try s.emitOp(opcode.op.throw);
                try patchForwardJump(s, end_off);
            }
            if (s.peekKind() == tok.TOK_FINALLY) {
                try s.advance();
                try parseBlock(s);
            }
        },
        tok.TOK_DEBUGGER => {
            try s.advance();
            _ = try s.expectSemicolon();
        },
        ';' => {
            // Empty statement
            try s.advance();
        },
        else => {
            // Expression statement.
            //
            // Mirrors `quickjs.c:28960`: in eval mode, the last
            // value is stored in `eval_ret_idx` so `eval()` can
            // return it; otherwise it's dropped. `<ret>` is a
            // non-lexical slot so the lowered bytecode is just
            // `put_loc <idx>` (or short form), which the pipeline
            // handles transparently.
            try parseExpr(s);
            _ = try s.expectSemicolon();
            const final_function_expr_stmt = s.emit_to_function_def and s.peekKind() == '}';
            if (s.eval_ret_idx >= 0) {
                try s.emitScopePutVar(ParseState.eval_ret_atom);
            } else if (s.suppress_expr_statement_drop) {
                s.suppress_expr_statement_drop = false;
            } else if (final_function_expr_stmt) {
                // Function epilogue will emit return_undef.
            } else {
                try s.emitOp(opcode.op.drop);
            }
        },
    }
}

fn patchForwardJump(s: *ParseState, operand_offset: usize) Error!void {
    var code = s.currentCode();
    if (operand_offset + 4 > code.len) return Error.UnexpectedToken;
    const target: u32 = @intCast(code.len);
    std.mem.writeInt(u32, code[operand_offset..][0..4], target, .little);
}

/// Mirror `js_parse_var` (`quickjs.c:27847`) - simplified version for F5.
///
/// Registers each identifier in `function_def.vars` with the correct
/// `VarKind` / `is_lexical` / `is_const` flags so the full
/// FunctionDef-based pipeline (§F10.1 Outstanding) can assign local
/// slots, emit TDZ checks, and synthesise closures. For `var`, the
/// variable is attached at the function's var/arg scope (level 0)
/// per QuickJS hoisting rules; for `let`/`const`, it attaches at the
/// current lexical scope.
fn parseVar(s: *ParseState, var_tok: tok.TokenKind) Error!void {
    const is_lexical = var_tok == tok.TOK_LET or var_tok == tok.TOK_CONST;
    const is_const = var_tok == tok.TOK_CONST;
    while (true) {
        if (s.peekKind() == tok.TOK_IDENT) {
            // Simple identifier binding
            const atom_id = s.token.payload.ident.atom;
            s.last_var_decl_atom = atom_id;
            var top_level_var_ref_idx: ?u16 = null;
            var local_lexical_idx: ?u16 = null;
            try s.advance();

            // Register the declaration in `function_def.vars`. For
            // `var`, QuickJS hoists to scope 0 (`add_func_var_def`
            // / `add_arguments_var`); for `let`/`const` the current
            // lexical scope is correct.
            if (s.top_level_lexical_as_module_ref and s.scope_level == 0) {
                const ref_idx = try s.cur_func().addClosureVar(.{
                    .closure_type = .module_decl,
                    .is_lexical = is_lexical,
                    .is_const = is_const,
                    .var_kind = .normal,
                    .var_idx = @intCast(s.cur_func().closure_var.len),
                    .var_name = atom_id,
                });
                if (!is_lexical) top_level_var_ref_idx = @intCast(ref_idx);
            } else if (is_lexical) {
                local_lexical_idx = @intCast(try s.addScopeVar(atom_id, .normal, true, is_const));
                if (s.emit_lexical_tdz_at_decl) {
                    s.cur_func().vars[local_lexical_idx.?].tdz_emitted_at_decl = true;
                }
            } else {
                // Hoist `var` to function scope (level 0).
                if (s.cur_func().findVar(atom_id) < 0) {
                    const saved = s.scope_level;
                    s.scope_level = 0;
                    defer s.scope_level = saved;
                    _ = try s.addScopeVar(atom_id, .normal, false, false);
                }
            }

            if (local_lexical_idx) |idx| {
                if (s.cur_func().use_short_opcodes and s.emit_lexical_tdz_at_decl) {
                    try s.emitOpU16(opcode.op.set_loc_uninitialized, idx);
                }
            }

            // Check for initializer
            if (s.peekKind() == '=') {
                try s.advance();
                s.last_anonymous_function_expr = false;
                try parseExpr(s);
                if (s.last_anonymous_function_expr) {
                    try s.emitOpAtom(opcode.op.set_name, atom_id);
                    s.last_anonymous_function_expr = false;
                }
                // §F10.1c: emit the proper Phase-1 init opcode so the
                // value is actually stored in the var's slot. The
                // pipeline (`resolve_variables`) lowers these to
                // `put_loc` when the var resolves locally, or to
                // `put_var_init` / `put_var` for global lexical /
                // hoisted-global cases.
                if (is_lexical) {
                    try s.emitScopePutVarInit(atom_id);
                } else if (top_level_var_ref_idx) |ref_idx| {
                    try s.emitSetVarRef(ref_idx);
                    s.last_var_decl_can_skip_get = true;
                } else {
                    try s.emitScopePutVar(atom_id);
                }
            } else {
                // const requires initializer
                if (var_tok == tok.TOK_CONST) {
                    return Error.UnexpectedToken;
                }
                // `let x;` (no initializer) implicitly initialises to
                // undefined. We emit `undefined; scope_put_var_init`
                // so the slot is properly marked initialised — the
                // pipeline lowers this to `put_loc_check_init` for
                // lexical locals (clears TDZ flag) or `put_var_init`
                // for global lexical vars.
                if (var_tok == tok.TOK_LET) {
                    try s.emitOp(opcode.op.undefined);
                    try s.emitScopePutVarInit(atom_id);
                }
            }
        } else if (s.peekKind() == '[' or s.peekKind() == '{') {
            // Destructuring - deferred to F6
            return Error.UnexpectedToken;
        } else {
            return Error.UnexpectedToken;
        }

        // Check for comma (multiple declarations)
        if (s.peekKind() != ',') break;
        try s.advance();
    }
}

/// Parse for-in or for-of loop
/// Mirrors `js_parse_for_in_of` in quickjs.c:27991
fn parseForInOf(s: *ParseState) Error!void {
    // Parse left-hand side (var declaration or lvalue expression)
    const var_tok = s.peekKind();
    var target_atom: ?Atom = null;
    var target_is_decl = false;
    if (var_tok == tok.TOK_VAR or var_tok == tok.TOK_LET or var_tok == tok.TOK_CONST) {
        try s.advance();
        s.last_var_decl_atom = null;
        try parseVar(s, var_tok);
        target_atom = s.last_var_decl_atom;
        target_is_decl = true;
    } else if (var_tok == tok.TOK_IDENT) {
        target_atom = s.token.payload.ident.atom;
        try s.advance();
    } else {
        // TODO: Parse member/destructuring lvalues for for-in/of.
        return Error.UnexpectedToken;
    }

    // Parse 'in' or 'of'
    const in_of_tok = s.peekKind();
    if (in_of_tok != tok.TOK_IN and in_of_tok != tok.TOK_OF) {
        return Error.UnexpectedToken;
    }
    try s.advance();

    const is_for_of = in_of_tok == tok.TOK_OF;

    // Parse the right-hand side expression (the iterable)
    try parseExpr(s);
    try s.expectToken(')');

    // Initialize the iterator for the iterable on the stack.
    if (is_for_of) {
        try s.emitOp(opcode.op.for_of_start);
    } else {
        try s.emitOp(opcode.op.for_in_start);
    }

    // QuickJS enters for-in/of loops by jumping to the iterator step,
    // then the step branches back to the body with the next value on
    // the stack. The body begins by storing that value into the LHS.
    const next_jump_off = try emitForwardJump(s, opcode.op.goto);
    const body_pc: u32 = @intCast(s.currentCodeLen());
    if (target_atom) |atom_id| {
        if (target_is_decl) {
            try s.emitScopePutVarInit(atom_id);
        } else {
            try s.emitScopePutVar(atom_id);
        }
    } else {
        return Error.UnexpectedToken;
    }

    // TODO: F10 push BlockEnv so labelled break/continue can close the iterator.

    try parseStatementOrDecl(s, DeclMask{});

    try patchForwardJump(s, next_jump_off);
    if (is_for_of) {
        try s.emitOp(opcode.op.for_of_next);
    } else {
        try s.emitOp(opcode.op.for_in_next);
    }
    try emitBackwardJump(s, opcode.op.if_false, body_pc);
    try s.emitOp(opcode.op.drop);
    try s.emitOp(opcode.op.drop);
}

/// Parse function declaration
/// Mirrors `js_parse_function_decl` in quickjs.c:36388
fn parseFunctionDecl(s: *ParseState, func_kind: ParseFunctionKind) Error!void {
    try s.advance();

    // Check for generator: function*
    const is_generator = s.peekKind() == '*';
    if (is_generator) {
        try s.advance();
    }

    // Parse function name (required for declarations)
    if (s.peekKind() != tok.TOK_IDENT) {
        return Error.UnexpectedToken;
    }
    const name_atom = s.token.payload.ident.atom;
    try s.advance();

    // Set generator flag for yield parsing
    const was_generator = s.in_generator;
    s.in_generator = is_generator;
    defer s.in_generator = was_generator;

    // Set async flag for await parsing
    const was_async = s.in_async;
    const is_async = func_kind == .async or func_kind == .async_generator;
    s.in_async = is_async;
    defer s.in_async = was_async;

    // Determine actual function kind based on async/generator combination
    const actual_kind: ParseFunctionKind = if (is_generator)
        if (func_kind == .async) .async_generator else .generator
    else
        func_kind;

    const saved_pending_name = s.pending_function_name;
    const saved_pending_decl = s.pending_function_is_decl;
    s.pending_function_name = name_atom;
    s.pending_function_is_decl = true;
    defer {
        s.pending_function_name = saved_pending_name;
        s.pending_function_is_decl = saved_pending_decl;
    }
    try parseFunctionParamsAndBody(s, actual_kind);
}

/// Parse function expression
/// Mirrors `js_parse_function_expr` in quickjs.c
fn parseFunctionExpr(s: *ParseState, func_kind: ParseFunctionKind) Error!void {
    try s.advance();

    // Check for generator: function*
    const is_generator = s.peekKind() == '*';
    if (is_generator) {
        try s.advance();
    }

    // Parse function name (optional for expressions)
    const saved_pending_name = s.pending_function_name;
    s.pending_function_name = null;
    const has_name = s.peekKind() == tok.TOK_IDENT;
    if (has_name) {
        const name_atom = s.token.payload.ident.atom;
        s.pending_function_name = name_atom;
        try s.advance();
    }

    // Set generator flag for yield parsing
    const was_generator = s.in_generator;
    s.in_generator = is_generator;
    defer s.in_generator = was_generator;

    // Set async flag for await parsing
    const was_async = s.in_async;
    const is_async = func_kind == .async or func_kind == .async_generator;
    s.in_async = is_async;
    defer s.in_async = was_async;

    // Determine actual function kind based on async/generator combination
    const actual_kind: ParseFunctionKind = if (is_generator)
        if (func_kind == .async) .async_generator else .generator
    else
        func_kind;

    const saved_pending_decl = s.pending_function_is_decl;
    s.pending_function_is_decl = false;
    defer {
        s.pending_function_name = saved_pending_name;
        s.pending_function_is_decl = saved_pending_decl;
    }
    try parseFunctionParamsAndBody(s, actual_kind);
}

/// Parse function parameters and body
/// Shared by function declarations, expressions, and methods
fn parseFunctionParamsAndBody(s: *ParseState, func_kind: ParseFunctionKind) Error!void {
    s.last_function_child_index = null;
    const parent_fd = s.cur_func();
    const capture_child = s.cur_func_stack.len > 0 or s.top_level_functions_as_children;
    const saved_emit_to_function_def = s.emit_to_function_def;
    const saved_scope_level = s.scope_level;
    const parent_code_len_before_child = s.currentCodeLen();

    if (capture_child) {
        const child_fd = try s.function.memory.create(function_def_mod.FunctionDef);
        child_fd.* = function_def_mod.FunctionDef.init(s.function.memory, s.function.atoms, s.pending_function_name orelse s.function.name);
        child_fd.parent = parent_fd;
        child_fd.parent_scope_level = parent_fd.scope_level;
        child_fd.is_strict_mode = parent_fd.is_strict_mode;
        child_fd.use_short_opcodes = parent_fd.use_short_opcodes;
        child_fd.func_type = switch (func_kind) {
            .normal, .async, .generator, .async_generator => if (s.pending_function_is_decl) .statement else .expr,
            .arrow => .arrow,
            .get => .getter,
            .set => .setter,
            .method => .method,
            .class_constructor => .class_constructor,
            .derived_class_constructor => .derived_class_constructor,
            .class_static_block => .class_static_init,
        };
        _ = child_fd.appendScope(-1) catch return error.OutOfMemory;
        if (func_kind == .class_constructor or func_kind == .derived_class_constructor) {
            child_fd.this_var_idx = @intCast(try child_fd.addScopeVar(8, .normal, 0, false, false));
            child_fd.is_derived_class_constructor = func_kind == .derived_class_constructor;
            _ = try child_fd.addClosureVar(.{
                .closure_type = .ref,
                .is_lexical = true,
                .is_const = true,
                .var_kind = .normal,
                .var_idx = 1,
                .var_name = 120, // <class_fields_init>
            });
        }
        if (s.pending_function_is_decl) {
            const name = s.pending_function_name orelse s.function.name;
            if (s.cur_func_stack.len == 0 and s.top_level_functions_as_children) {
                const parent_ref_idx = try parent_fd.addClosureVar(.{
                    .closure_type = .module_decl,
                    .is_lexical = true,
                    .is_const = false,
                    .var_kind = .function_decl,
                    .var_idx = @intCast(parent_fd.closure_var.len),
                    .var_name = name,
                });
                _ = try child_fd.addClosureVar(.{
                    .closure_type = .ref,
                    .is_lexical = true,
                    .is_const = false,
                    .var_kind = .function_decl,
                    .var_idx = @intCast(parent_ref_idx),
                    .var_name = name,
                });
                child_fd.emit_top_level_closure_init = true;
                child_fd.top_level_closure_var_idx = parent_ref_idx;
            } else {
                child_fd.child_decl_init_keep_value = parent_code_len_before_child == 0;
                _ = try parent_fd.addScopeVar(name, .function_decl, 0, false, false);
            }
        }
        try s.pushFunction(child_fd);
        s.emit_to_function_def = true;
        s.scope_level = 0;
    }

    try s.expectToken('(');

    // TODO: Parse parameters with defaults and destructuring in F6
    // For now, just skip the parameter list
    // Parse simple parameter list
    var param_count: u32 = 0;
    while (s.peekKind() != ')' and s.peekKind() != tok.TOK_EOF) {
        if (s.peekKind() == tok.TOK_IDENT) {
            // Simple parameter
            const param_atom = s.token.payload.ident.atom;
            if (capture_child) {
                _ = try s.cur_func().appendArg(.{
                    .var_name = param_atom,
                    .scope_level = 0,
                    .is_lexical = false,
                    .is_const = false,
                    .var_kind = .normal,
                });
            }
            try s.advance();
            param_count += 1;

            // Check for default value
            if (s.peekKind() == '=') {
                // TODO: Handle default values in F6
                try s.advance();
                try parseExpr(s);
                try s.emitOp(opcode.op.drop);
            }
        } else if (s.peekKind() == '{') {
            // Object destructuring parameter: {a, b}
            try parseDestructuringObject(s);
            param_count += 1;
        } else if (s.peekKind() == '[') {
            // Array destructuring parameter: [a, b]
            try parseDestructuringArray(s);
            param_count += 1;
        } else if (s.peekKind() == tok.TOK_ELLIPSIS) {
            // Rest parameter
            try s.advance();
            if (s.peekKind() == tok.TOK_IDENT) {
                const rest_atom = s.token.payload.ident.atom;
                _ = rest_atom; // TODO: Register rest parameter in F6/F10
                try s.advance();
            }
            break;
        } else {
            // TODO: Handle destructuring in F6
            return Error.UnexpectedToken;
        }

        if (s.peekKind() == ',') {
            try s.advance();
        } else if (s.peekKind() != ')') {
            return Error.UnexpectedToken;
        }
    }

    try s.expectToken(')');

    // Parse function body — parseBlock consumes its own opening '{'.
    if (capture_child) try predeclareFunctionBodyVars(s);
    try parseBlock(s);
    if (capture_child) {
        if (func_kind == .class_constructor) {
            try s.emitOp(opcode.op.check_ctor);
            try s.emitOpU16(opcode.op.get_var_ref_check, 0); // <class_fields_init>
            try s.emitOp(opcode.op.dup);
            const no_fields = try emitForwardJump(s, opcode.op.if_false);
            try s.emitOpU16(opcode.op.get_loc, 0);
            try s.emitOp(opcode.op.swap);
            try s.emitOpU16(opcode.op.call_method, 0);
            try patchForwardJump(s, no_fields);
        }
        const code = s.currentCode();
        const needs_return = code.len == 0 or switch (code[code.len - 1]) {
            opcode.op.@"return", opcode.op.return_undef, opcode.op.return_async, opcode.op.throw => false,
            else => true,
        };
        if (needs_return) try s.emitOp(opcode.op.return_undef);
    }

    if (capture_child) {
        const child_ptr = s.popFunction();
        s.emit_to_function_def = saved_emit_to_function_def;
        s.scope_level = saved_scope_level;
        const child_cpool_idx: u16 = @intCast(try parent_fd.appendCpool(Value.undefinedValue()));
        const keep_child_value = child_ptr.child_decl_init_keep_value;
        child_ptr.parent_cpool_idx = child_cpool_idx;
        try parent_fd.addChild(child_ptr.*);
        s.function.memory.destroy(function_def_mod.FunctionDef, child_ptr);
        s.last_function_child_index = @intCast(parent_fd.child_list.len - 1);
        if (!s.pending_function_is_decl) {
            try s.emitFClosure8(@intCast(child_cpool_idx));
            s.last_anonymous_function_expr = s.pending_function_name == null;
        } else if (keep_child_value) {
            s.skip_next_ident_get = s.pending_function_name;
        }
    }

    // TODO: Emit function prologue and epilogue in F6/F10
}

/// Parse arrow function
/// Mirrors arrow function parsing in quickjs.c
fn parseArrowFunction(s: *ParseState, func_kind: ParseFunctionKind) Error!void {
    const parent_fd = s.cur_func();
    const capture_child = s.cur_func_stack.len > 0 or s.top_level_functions_as_children;
    const saved_emit_to_function_def = s.emit_to_function_def;
    const saved_scope_level = s.scope_level;
    const saved_pending_name = s.pending_function_name;
    const saved_pending_decl = s.pending_function_is_decl;
    s.pending_function_name = null;
    s.pending_function_is_decl = false;
    defer {
        s.pending_function_name = saved_pending_name;
        s.pending_function_is_decl = saved_pending_decl;
    }

    if (capture_child) {
        const child_fd = try s.function.memory.create(function_def_mod.FunctionDef);
        child_fd.* = function_def_mod.FunctionDef.init(s.function.memory, s.function.atoms, s.function.name);
        child_fd.parent = parent_fd;
        child_fd.parent_scope_level = parent_fd.scope_level;
        child_fd.is_strict_mode = parent_fd.is_strict_mode;
        child_fd.use_short_opcodes = parent_fd.use_short_opcodes;
        child_fd.func_type = .arrow;
        _ = child_fd.appendScope(-1) catch return error.OutOfMemory;
        try s.pushFunction(child_fd);
        s.emit_to_function_def = true;
        s.scope_level = 0;
    }

    // Set async flag for await parsing
    const was_async = s.in_async;
    const is_async = func_kind == .async or func_kind == .async_generator;
    s.in_async = is_async;
    defer s.in_async = was_async;

    // TODO: F9 Use func_kind to emit different opcodes for async vs normal arrows

    // Parse parameters. Two valid head shapes:
    //   `ident => ...`    — single bare identifier parameter
    //   `(...) => ...`    — parenthesized parameter list
    if (s.peekKind() == tok.TOK_IDENT) {
        // Single bare identifier parameter.
        if (capture_child) {
            _ = try s.cur_func().appendArg(.{
                .var_name = s.token.payload.ident.atom,
                .scope_level = 0,
                .is_lexical = false,
                .is_const = false,
                .var_kind = .normal,
            });
        }
        try s.advance();
    } else {
        try s.expectToken('(');

        // TODO: Parse parameters with defaults and destructuring in F6
        // For now, just skip the parameter list
        while (s.peekKind() != ')' and s.peekKind() != tok.TOK_EOF) {
            if (s.peekKind() == tok.TOK_IDENT) {
                if (capture_child) {
                    _ = try s.cur_func().appendArg(.{
                        .var_name = s.token.payload.ident.atom,
                        .scope_level = 0,
                        .is_lexical = false,
                        .is_const = false,
                        .var_kind = .normal,
                    });
                }
                try s.advance();
            } else if (s.peekKind() == '{') {
                // Object destructuring parameter
                try parseDestructuringObject(s);
            } else if (s.peekKind() == '[') {
                // Array destructuring parameter
                try parseDestructuringArray(s);
            } else if (s.peekKind() == tok.TOK_ELLIPSIS) {
                try s.advance();
                if (s.peekKind() == tok.TOK_IDENT) {
                    try s.advance();
                }
                break;
            } else {
                // TODO: Handle destructuring in F6
                return Error.UnexpectedToken;
            }

            if (s.peekKind() == ',') {
                try s.advance();
            } else if (s.peekKind() != ')') {
                return Error.UnexpectedToken;
            }
        }

        try s.expectToken(')');
    }

    // Expect =>
    try s.expectToken(tok.TOK_ARROW);

    // Parse body (can be block or expression).
    // parseBlock consumes its own opening '{'.
    if (s.peekKind() == '{') {
        try parseBlock(s);
        if (capture_child) {
            const code = s.currentCode();
            const needs_return = code.len == 0 or switch (code[code.len - 1]) {
                opcode.op.@"return", opcode.op.return_undef, opcode.op.return_async, opcode.op.throw => false,
                else => true,
            };
            if (needs_return) try s.emitOp(opcode.op.return_undef);
        }
    } else {
        // Expression body
        try parseAssignExpr(s);
        if (!rewriteTrailingCallAsTailCall(s)) {
            try s.emitOp(opcode.op.@"return");
        }
    }

    if (capture_child) {
        const child_ptr = s.popFunction();
        s.emit_to_function_def = saved_emit_to_function_def;
        s.scope_level = saved_scope_level;
        const child_cpool_idx: u16 = @intCast(try parent_fd.appendCpool(Value.undefinedValue()));
        child_ptr.parent_cpool_idx = child_cpool_idx;
        try parent_fd.addChild(child_ptr.*);
        s.function.memory.destroy(function_def_mod.FunctionDef, child_ptr);
        s.last_function_child_index = @intCast(parent_fd.child_list.len - 1);
        try s.emitFClosure8(@intCast(child_cpool_idx));
        s.last_anonymous_function_expr = true;
    }
}

fn rewriteTrailingCallAsTailCall(s: *ParseState) bool {
    var code = s.currentCode();
    if (code.len < 3) return false;
    const op_index = code.len - 3;
    switch (code[op_index]) {
        opcode.op.call => {
            code[op_index] = opcode.op.tail_call;
            return true;
        },
        opcode.op.call_method => {
            code[op_index] = opcode.op.tail_call_method;
            return true;
        },
        else => return false,
    }
}

/// Parse object destructuring pattern
/// Mirrors object destructuring in quickjs.c
fn parseDestructuringObject(s: *ParseState) Error!void {
    try s.expectToken('{');

    while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
        if (s.peekKind() == tok.TOK_IDENT) {
            const prop_atom = s.token.payload.ident.atom;
            _ = prop_atom; // TODO: Register destructured property in scope in F6/F10
            try s.advance();

            // Check for renaming: {a: b}
            if (s.peekKind() == ':') {
                try s.advance();
                if (s.peekKind() == tok.TOK_IDENT) {
                    const target_atom = s.token.payload.ident.atom;
                    _ = target_atom; // TODO: Register target in scope in F6/F10
                    try s.advance();
                } else {
                    return Error.UnexpectedToken;
                }
            }

            // Check for default value
            if (s.peekKind() == '=') {
                try s.advance();
                try parseExpr(s);
                try s.emitOp(opcode.op.drop);
            }
        } else {
            return Error.UnexpectedToken;
        }

        if (s.peekKind() == ',') {
            try s.advance();
        } else if (s.peekKind() != '}') {
            return Error.UnexpectedToken;
        }
    }

    try s.expectToken('}');
}

/// Parse array destructuring pattern
/// Mirrors array destructuring in quickjs.c
fn parseDestructuringArray(s: *ParseState) Error!void {
    try s.expectToken('[');

    while (s.peekKind() != ']' and s.peekKind() != tok.TOK_EOF) {
        if (s.peekKind() == tok.TOK_IDENT) {
            const elem_atom = s.token.payload.ident.atom;
            _ = elem_atom; // TODO: Register destructured element in scope in F6/F10
            try s.advance();

            // Check for default value
            if (s.peekKind() == '=') {
                try s.advance();
                try parseExpr(s);
                try s.emitOp(opcode.op.drop);
            }
        } else if (s.peekKind() == tok.TOK_ELLIPSIS) {
            // Rest element: [...rest]
            try s.advance();
            if (s.peekKind() == tok.TOK_IDENT) {
                const rest_atom = s.token.payload.ident.atom;
                _ = rest_atom; // TODO: Register rest element in scope in F6/F10
                try s.advance();
            } else {
                return Error.UnexpectedToken;
            }
            break; // Rest element must be last
        } else {
            // Skip empty slots in array destructuring
            try s.advance();
        }

        if (s.peekKind() == ',') {
            try s.advance();
        } else if (s.peekKind() != ']') {
            return Error.UnexpectedToken;
        }
    }

    try s.expectToken(']');
}

// ---- F7 Class parsing -------------------------------------------------

/// Parse class heritage (extends clause)
/// Mirrors `js_parse_class_extends` in quickjs.c
fn parseClassHeritage(s: *ParseState) Error!void {
    if (s.peekKind() == tok.TOK_EXTENDS) {
        try s.advance();
        // Parse the parent class expression
        try parseExpr(s);
    }
}

/// Parse a single class element
/// Mirrors class element parsing in quickjs.c
fn parseClassElement(s: *ParseState) Error!void {
    const saved_static = s.is_static;
    const saved_in_constructor = s.in_constructor;

    // Check for static modifier
    if (s.peekKind() == tok.TOK_STATIC) {
        s.is_static = true;
        try s.advance();
    }

    // Check for getter/setter
    const is_getter = s.isIdent("get");
    const is_setter = s.isIdent("set");
    if (is_getter or is_setter) {
        try s.advance();
        // Check if this is a private getter/setter (get #x() or set #x())
        if (s.peekKind() == tok.TOK_PRIVATE_NAME) {
            try s.advance();
            if (s.peekKind() != '(') {
                return Error.UnexpectedToken;
            }
            // Parse parameters with proper function kind for private getter/setter
            const kind: ParseFunctionKind = if (is_getter) .get else .set;
            try parseFunctionParamsAndBody(s, kind);
        } else {
            // Regular getter/setter - parse property name (identifier, string, or number)
            if (s.peekKind() == tok.TOK_IDENT) {
                try s.advance();
            } else if (s.peekKind() == tok.TOK_STRING) {
                try s.advance();
            } else if (s.peekKind() == tok.TOK_NUMBER) {
                try s.advance();
            } else {
                return Error.UnexpectedToken;
            }
            if (s.peekKind() != '(') {
                return Error.UnexpectedToken;
            }
            // Parse parameters with proper function kind for getter/setter
            const kind: ParseFunctionKind = if (is_getter) .get else .set;
            try parseFunctionParamsAndBody(s, kind);
        }
        return;
    }

    // Check for private field (#x)
    if (s.peekKind() == tok.TOK_PRIVATE_NAME) {
        try s.advance();
        if (s.peekKind() == '(') {
            // Private method
            try parseFunctionParamsAndBody(s, .method);
        } else if (s.peekKind() == '=') {
            // Private field with initializer
            try s.advance();
            try parseExpr(s);
            try s.emitOp(opcode.op.drop);
        }
        // Optional semicolon after private field
        if (s.peekKind() == ';') try s.advance();
        return;
    }

    // Check for method or field
    if (s.peekKind() == tok.TOK_IDENT) {
        const prop_atom = s.token.payload.ident.atom;
        const is_constructor = !s.is_static and prop_atom == atom_module.ids.constructor;
        try s.advance();

        if (s.peekKind() == '(') {
            // Method or constructor
            if (is_constructor) {
                s.in_constructor = true;
            }
            // Parse parameters with proper function kind for constructor/method
            const kind: ParseFunctionKind = if (is_constructor)
                if (s.class_has_extends) .derived_class_constructor else .class_constructor
            else .method;
            try parseFunctionParamsAndBody(s, kind);
            if (is_constructor) {
                s.in_constructor = saved_in_constructor;
            }
            // Optional ASI semicolon after method
            if (s.peekKind() == ';') try s.advance();
        } else if (s.peekKind() == '=') {
            // Field with initializer
            try s.advance();
            try parseExpr(s);
            try s.emitOp(opcode.op.drop);
            // Optional ASI semicolon
            if (s.peekKind() == ';') try s.advance();
        } else if (s.peekKind() == ';') {
            // Field without initializer, with semicolon
            try s.advance();
        }
        // Else: field without initializer (no semicolon)
    } else if (s.peekKind() == '{') {
        // Static block — parseBlock consumes its own opening '{'.
        if (!s.is_static) {
            return Error.UnexpectedToken;
        }
        try parseBlock(s);
    } else {
        return Error.UnexpectedToken;
    }

    s.is_static = saved_static;
    s.in_constructor = saved_in_constructor;
}

/// Parse class body
/// Mirrors `js_parse_class_body` in quickjs.c
fn parseClassBody(s: *ParseState) Error!void {
    try s.expectToken('{');

    while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
        try parseClassElement(s);
    }

    try s.expectToken('}');
}

/// Parse class declaration or expression
/// Mirrors `js_parse_class` in quickjs.c:24667
fn parseClass(s: *ParseState, is_decl: bool) Error!void {
    try s.expectToken(tok.TOK_CLASS);

    // Parse class name (required for declarations, optional for expressions)
    var class_name: ?Atom = null;
    if (is_decl) {
        if (s.peekKind() != tok.TOK_IDENT) {
            return Error.UnexpectedToken;
        }
        const name_atom = s.token.payload.ident.atom;
        class_name = name_atom;
        try s.advance();
    } else {
        if (s.peekKind() == tok.TOK_IDENT) {
            const name_atom = s.token.payload.ident.atom;
            class_name = name_atom;
            try s.advance();
        }
    }

    // Parse heritage (extends clause)
    const saved_has_extends = s.class_has_extends;
    const saved_in_class = s.in_class;

    s.in_class = true;
    s.class_has_extends = s.peekKind() == tok.TOK_EXTENDS;
    try parseClassHeritage(s);

    // Parse class body. Constructor parsing records a child FunctionDef;
    // class definition bytecode references that child through push_const /
    // define_class instead of the normal fclosure expression path.
    const class_emit_start = s.currentCodeLen();
    try parseClassBody(s);
    try s.truncateCode(class_emit_start);

    s.in_class = saved_in_class;
    s.class_has_extends = saved_has_extends;

    const name_atom = class_name orelse s.function.name;
    if (is_decl) {
        const class_ref_idx = try s.cur_func().addClosureVar(.{
            .closure_type = .module_decl,
            .is_lexical = true,
            .is_const = false,
            .var_kind = .normal,
            .var_idx = @intCast(s.cur_func().closure_var.len),
            .var_name = name_atom,
        });
        try s.emitOpU16(opcode.op.set_loc_uninitialized, 0);
        try s.emitOp(opcode.op.undefined);
        try s.emitOpU16(opcode.op.set_loc_uninitialized, 1);
        try s.emitOpU8(opcode.op.push_const8, 0);
        try s.emitOpAtomU8(opcode.op.define_class, name_atom, 0);
        try s.emitOp(opcode.op.undefined);
        try s.emitOpU16(opcode.op.put_loc, 1);
        try s.emitOp(opcode.op.drop);
        try s.emitOpU16(opcode.op.set_loc, 0);
        try s.emitOpU16(opcode.op.close_loc, 1);
        try s.emitSetVarRef(@intCast(class_ref_idx));
    } else {
        try s.emitOp(opcode.op.undefined);
    }
}

// =====================================================================
// Module parsing (F8)
// =====================================================================

/// Parse import statement
/// Mirrors `js_parse_import` in quickjs.c:31312
fn parseImport(s: *ParseState) Error!void {
    try s.advance();

    // Side-effect import: import 'module'
    if (s.peekKind() == tok.TOK_STRING) {
        try s.advance();
        // TODO: F10+ Add to module import entries
        _ = try s.expectSemicolon();
        return;
    }

    // Default import: import x from 'module'
    if (s.peekKind() == tok.TOK_IDENT) {
        try s.advance();
        // TODO: F10+ Add to module import entries

        if (s.peekKind() != ',') {
            try parseFromClause(s);
            // parseFromClause handles with clause, so expect semicolon after
            _ = try s.expectSemicolon();
            return;
        }
        try s.advance();
    }

    // Namespace import: import * as ns from 'module'
    if (s.peekKind() == '*') {
        try s.advance();
        // Expect 'as'
        if (!s.isIdent("as")) {
            return Error.UnexpectedToken;
        }
        try s.advance();
        // Expect namespace identifier
        if (s.peekKind() != tok.TOK_IDENT) {
            return Error.UnexpectedToken;
        }
        try s.advance();
        // TODO: F10+ Add to module import entries
        try parseFromClause(s);
        _ = try s.expectSemicolon();
        return;
    }

    // Named imports: import { x, y as z } from 'module'
    if (s.peekKind() == '{') {
        try s.advance();
        while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
            // Import name (identifier or string)
            if (s.peekKind() != tok.TOK_IDENT and s.peekKind() != tok.TOK_STRING) {
                return Error.UnexpectedToken;
            }
            try s.advance();

            // Optional 'as' for renaming
            if (s.isIdent("as")) {
                try s.advance();
                if (s.peekKind() != tok.TOK_IDENT) {
                    return Error.UnexpectedToken;
                }
                try s.advance();
            }

            // TODO: F10+ Add to module import entries

            if (s.peekKind() != ',') break;
            try s.advance();
        }
        try s.expectToken('}');
        try parseFromClause(s);
        _ = try s.expectSemicolon();
        return;
    }

    return Error.UnexpectedToken;
}

/// Parse export statement
/// Mirrors `js_parse_export` in quickjs.c:31090
fn parseExport(s: *ParseState) Error!void {
    try s.advance();

    const next_tok = s.peekKind();

    // export default
    if (next_tok == tok.TOK_DEFAULT) {
        try s.advance();
        // export default x
        if (s.peekKind() == tok.TOK_CLASS) {
            try parseClass(s, false);
        } else if (s.peekKind() == tok.TOK_FUNCTION) {
            // Check for async function
            const is_async = s.isIdent("async");
            if (is_async) {
                try s.advance();
            }
            const func_kind: ParseFunctionKind = if (is_async) .async else .normal;
            try parseFunctionExpr(s, func_kind);
        } else {
            try parseExpr(s);
            try s.emitOp(opcode.op.drop);
        }
        // TODO: F10+ Add to module export entries
        _ = try s.expectSemicolon();
        return;
    }

    // export { ... }
    if (next_tok == '{') {
        try s.advance();
        while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
            // Export name (identifier or string)
            if (s.peekKind() != tok.TOK_IDENT and s.peekKind() != tok.TOK_STRING) {
                return Error.UnexpectedToken;
            }
            try s.advance();

            // Optional 'as' for renaming
            if (s.isIdent("as")) {
                try s.advance();
                if (s.peekKind() != tok.TOK_IDENT and s.peekKind() != tok.TOK_STRING) {
                    return Error.UnexpectedToken;
                }
                try s.advance();
            }

            // TODO: F10+ Add to module export entries

            if (s.peekKind() != ',') break;
            try s.advance();
        }
        try s.expectToken('}');

        // Optional from clause for re-export
        if (s.isIdent("from")) {
            try parseFromClause(s);
        }
        _ = try s.expectSemicolon();
        return;
    }

    // export * from 'module' or export * as ns from 'module'
    if (next_tok == '*') {
        try s.advance();
        // Optional 'as' for namespace re-export
        if (s.isIdent("as")) {
            try s.advance();
            if (s.peekKind() != tok.TOK_IDENT and s.peekKind() != tok.TOK_STRING) {
                return Error.UnexpectedToken;
            }
            try s.advance();
        }
        try parseFromClause(s);
        _ = try s.expectSemicolon();
        return;
    }

    // export var/let/const
    if (next_tok == tok.TOK_VAR or next_tok == tok.TOK_LET or next_tok == tok.TOK_CONST) {
        const var_tok = next_tok;
        try s.advance();
        try parseVar(s, var_tok);
        // TODO: F10+ Add to module export entries
        _ = try s.expectSemicolon();
        return;
    }

    // export function
    if (next_tok == tok.TOK_FUNCTION) {
        // Check for async function
        const is_async = s.isIdent("async");
        if (is_async) {
            try s.advance();
        }
        const func_kind: ParseFunctionKind = if (is_async) .async else .normal;
        try parseFunctionDecl(s, func_kind);
        // TODO: F10+ Add to module export entries
        return;
    }

    // export class
    if (next_tok == tok.TOK_CLASS) {
        try parseClass(s, true);
        // TODO: F10+ Add to module export entries
        return;
    }

    // export async function
    if (next_tok == tok.TOK_IDENT and s.isIdent("async")) {
        // Check if next token is function
        if (s.peekNextKind() == tok.TOK_FUNCTION) {
            try s.advance(); // consume async
            try s.advance(); // consume function
            const func_kind: ParseFunctionKind = .async;
            try parseFunctionDecl(s, func_kind);
            // TODO: F10+ Add to module export entries
            return;
        }
    }

    return Error.UnexpectedToken;
}

/// Parse from clause: from 'module'
/// Mirrors `js_parse_from_clause` in quickjs.c:31039
fn parseFromClause(s: *ParseState) Error!void {
    // Expect 'from' keyword
    if (!s.isIdent("from")) {
        return Error.UnexpectedToken;
    }
    try s.advance();

    // Expect string literal for module name
    if (s.peekKind() != tok.TOK_STRING) {
        return Error.UnexpectedToken;
    }
    try s.advance();

    // TODO: F10+ Add to module required entries

    // Optional with clause for import attributes
    if (s.isIdent("with")) {
        try parseWithClause(s);
    }
}

/// Parse with clause for import attributes
/// Mirrors `js_parse_with_clause` in quickjs.c:30950
fn parseWithClause(s: *ParseState) Error!void {
    try s.advance();
    try s.expectToken('{');

    while (s.peekKind() != '}' and s.peekKind() != tok.TOK_EOF) {
        // Key (identifier or string)
        if (s.peekKind() != tok.TOK_IDENT and s.peekKind() != tok.TOK_STRING) {
            return Error.UnexpectedToken;
        }
        try s.advance();

        try s.expectToken(':');

        // Value (string)
        if (s.peekKind() != tok.TOK_STRING) {
            return Error.UnexpectedToken;
        }
        try s.advance();

        // TODO: F10+ Store attribute

        if (s.peekKind() != ',') break;
        try s.advance();
    }

    try s.expectToken('}');
}
