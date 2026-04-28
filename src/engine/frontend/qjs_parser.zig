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
};

/// Parse flags mirror the QuickJS `PF_*` macros (`quickjs.c:21358..21370`).
pub const ParseFlags = packed struct(u32) {
    in_accepted: bool = false,
    pow_allowed: bool = false,
    arrow_func: bool = false,
    trailing_comma_ok: bool = false,
    _padding: u28 = 0,

    pub const default = ParseFlags{ .in_accepted = true };
};

/// Minimal `JSParseState` analogue for F4 expression-level work. F5/F6
/// expand this with `cur_func`, scope chain, label tracking, etc.
pub const ParseState = struct {
    lex: *lexer_mod.Lexer,
    function: *bytecode_function.Bytecode,
    /// One-token lookahead. The lexer is the source of truth; we cache
    /// the most recently produced token here so the parser can `peek`.
    token: tok.Token,

    pub fn init(lex: *lexer_mod.Lexer, function: *bytecode_function.Bytecode) Error!ParseState {
        var state = ParseState{
            .lex = lex,
            .function = function,
            .token = undefined,
        };
        state.token = try lex.next();
        return state;
    }

    pub fn deinit(self: *ParseState) void {
        self.lex.freeToken(&self.token);
    }

    /// Advance one token. Frees the payload of the consumed token.
    fn advance(self: *ParseState) Error!void {
        self.lex.freeToken(&self.token);
        self.token = try self.lex.next();
    }

    fn peekKind(self: ParseState) tok.TokenKind {
        return self.token.val;
    }

    fn isPunct(self: ParseState, ch: u8) bool {
        return self.token.val == @as(tok.TokenKind, @intCast(ch));
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

    fn emitOpAtom(self: *ParseState, op_id: u8, atom_id: Atom) Error!void {
        try self.function.retainAtomOperand(atom_id);
        try self.emitOpU32(op_id, atom_id);
    }

    fn emitPushConst(self: *ParseState, value: Value) Error!void {
        const idx = try self.function.addConstant(value);
        try self.emitOpU32(opcode.op.push_const, idx);
    }

    fn appendBytes(self: *ParseState, bytes: []const u8) Error!void {
        const old_len = self.function.code.len;
        const next = try self.function.memory.alloc(u8, old_len + bytes.len);
        errdefer self.function.memory.free(u8, next);
        @memcpy(next[0..old_len], self.function.code);
        @memcpy(next[old_len..], bytes);
        if (self.function.code.len != 0) self.function.memory.free(u8, self.function.code);
        self.function.code = next;
    }

    /// Drop bytes appended after `target_len`. Used by parseAssignExpr2 /
    /// parsePostfixExpr to roll back a speculative LHS emission once an
    /// assignment / update operator is recognised. Atom operand counts are
    /// rolled back via `truncateAtomOperands`; callers must coordinate the
    /// two so retain/free ref-counts stay balanced.
    fn truncateCode(self: *ParseState, target_len: usize) Error!void {
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
    const pre_lhs_code_len = s.function.code.len;
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
        try parseAssignExpr2(s, flags);
        try s.emitOp(op_byte);
        try emitPutLValueKeepTop(s, shape);
    } else {
        // Plain `=`: drop the speculative load (we don't need the old value).
        switch (shape) {
            .var_ref => |v| {
                try s.truncateCode(v.code_pos);
                try s.truncateAtomOperands(pre_lhs_atom_len);
                try parseAssignExpr2(s, flags);
                try s.emitOp(opcode.op.dup);
                try s.emitOpAtom(opcode.op.put_var, v.atom);
            },
            .dotted => |d| {
                // Drop the speculative `get_field <atom>` (5 bytes plus
                // its atom_operand entry); the receiver stays on the
                // stack from earlier emission.
                try s.truncateCode(d.code_pos);
                try s.truncateAtomOperands(s.function.atom_operands.len - 1);
                try parseAssignExpr2(s, flags);
                try s.emitOp(opcode.op.insert2);
                try s.emitOpAtom(opcode.op.put_field, d.atom);
            },
            .indexed => |i| {
                // Drop the speculative `get_array_el` (1 byte); the
                // receiver+key stay on the stack.
                try s.truncateCode(i.code_pos);
                try parseAssignExpr2(s, flags);
                try s.emitOp(opcode.op.insert3);
                try s.emitOp(opcode.op.put_array_el);
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
    const code = s.function.code;
    // var_ref: exactly `get_var <atom>` was added.
    if (saved_atom) |ident| {
        if (code.len == pre_lhs_code_len + 5 and
            code[pre_lhs_code_len] == opcode.op.get_var and
            s.function.atom_operands.len == pre_lhs_atom_len + 1 and
            s.function.atom_operands[pre_lhs_atom_len] == ident)
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
            try s.emitOp(opcode.op.dup);
            try s.emitOpAtom(opcode.op.put_var, v.atom);
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

/// `put_lvalue` with PUT_LVALUE_KEEP_SECOND semantics — used for
/// postfix update where the OLD value is the expression result. Mirrors
/// `quickjs.c:25470..25530`.
fn emitPutLValueKeepSecond(s: *ParseState, shape: LhsShape) Error!void {
    switch (shape) {
        .var_ref => |v| {
            try s.emitOpAtom(opcode.op.put_var, v.atom);
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
        if (s.peekKind() == tok.TOK_IDENT) {
            const ident = s.token.payload.ident.atom;
            try s.advance();
            try s.emitOpAtom(opcode.op.get_var_undef, ident);
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
    const pre_lhs_code_len = s.function.code.len;
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
    const pre_lhs_code_len = s.function.code.len;
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
}

fn parseNewExpr(s: *ParseState, flags: ParseFlags) Error!void {
    try s.advance(); // consume 'new'
    // F4 slice 2: `new X(a, b)` only — no chained `new new ...`, no
    // `new.target`, no member lookup before the args. The QuickJS
    // grammar permits MemberExpression here; we'll grow this once F4
    // proves out.
    try parsePrimary(s, flags);
    if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
        const shape = try parseCallArgs(s, flags);
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
            try s.advance();
            if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
            const name = s.token.payload.ident.atom;
            try s.advance();
            // If a call follows, use get_field2 to keep `obj` on the stack
            // so we can lower as `obj func args... call_method`. Otherwise
            // a plain get_field is sufficient.
            if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
                try s.emitOpAtom(opcode.op.get_field2, name);
                const shape = try parseCallArgs(s, flags);
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
                try s.emitOpAtom(opcode.op.get_field, name);
            }
        } else if (k == tok.TOK_QUESTION_MARK_DOT) {
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
            try s.advance();
            try parseExpr(s);
            try expectPunct(s, ']');
            // Same shape as dotted: if a call follows, keep obj on stack via
            // get_array_el2 + call_method.
            if (s.peekKind() == @as(tok.TokenKind, @intCast('('))) {
                try s.emitOp(opcode.op.get_array_el2);
                const shape = try parseCallArgs(s, flags);
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
            const shape = try parseCallArgs(s, flags);
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
            if (numberIsExactI32(value)) {
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
        },
        tok.TOK_IDENT => {
            const ident = s.token.payload.ident.atom;
            try s.emitOpAtom(opcode.op.get_var, ident);
            try s.advance();
        },
        else => {
            if (k == @as(tok.TokenKind, @intCast('('))) {
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
    var spread_active = false;
    while (s.peekKind() != @as(tok.TokenKind, @intCast(']'))) {
        if (s.peekKind() == @as(tok.TokenKind, @intCast(','))) {
            // Hole — leading or interior. Push `undefined` and count it
            // (or, in spread mode, define_array_el+inc).
            if (spread_active) {
                try s.emitOp(opcode.op.@"undefined");
                try s.emitOp(opcode.op.define_array_el);
                try s.emitOp(opcode.op.inc);
            } else {
                try s.emitOp(opcode.op.@"undefined");
                count += 1;
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
    } else {
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
    if (k == tok.TOK_IDENT) {
        const name = s.token.payload.ident.atom;
        try s.advance();
        if (s.peekKind() == @as(tok.TokenKind, @intCast(':'))) {
            try s.advance();
            try parseAssignExpr2(s, flags);
        } else {
            // Shorthand `{ x }` — stack: obj, then push value of `x`.
            try s.emitOpAtom(opcode.op.get_var, name);
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
    const operand_offset = s.function.code.len + 1;
    try s.appendBytes(&bytes);
    return operand_offset;
}

fn patchForwardJump(s: *ParseState, operand_offset: usize) Error!void {
    if (operand_offset + 4 > s.function.code.len) return Error.UnexpectedToken;
    const target: u32 = @intCast(s.function.code.len);
    std.mem.writeInt(u32, s.function.code[operand_offset..][0..4], target, .little);
}
