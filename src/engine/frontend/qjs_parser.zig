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
/// and compound-assignment lowering. F4 first slice supports simple
/// identifier targets only; member-target, destructuring, and arrow
/// forms come in later F4/F6 slices.
pub fn parseAssignExpr2(s: *ParseState, flags: ParseFlags) Error!void {
    // For F4 first slice we capture identifier targets up-front so that
    // we can re-emit if an assignment operator follows. A full
    // implementation will defer the LHS emission until the assignment
    // shape is known (matching QuickJS's deferred LHS path through
    // `JS_INIT_LV`/`emit_op_with_atom`); for now we use a simple
    // truncate-and-re-emit strategy.
    const saved_atom: ?Atom = if (s.peekKind() == tok.TOK_IDENT) blk: {
        break :blk s.token.payload.ident.atom;
    } else null;

    try parseCondExpr(s, flags);

    const op_kind = s.peekKind();
    const assign_opcode = compoundAssignOpcode(op_kind);
    const is_plain_assign = op_kind == @as(tok.TokenKind, @intCast('='));
    if (!is_plain_assign and assign_opcode == null) return;

    // Assignment present. For now we only support simple identifier
    // targets.
    const ident = saved_atom orelse return Error.InvalidAssignmentTarget;
    // Roll back the cond-expr emission. We must free the speculative
    // bytecode to keep the MemoryAccount counts balanced; truncating
    // the slice length leaks the underlying allocation.
    if (s.function.code.len != 0) s.function.memory.free(u8, s.function.code);
    s.function.code = &.{};
    // Atom operands accumulated by the speculative emit must also be
    // released to balance retainAtomOperand's `dup` calls.
    for (s.function.atom_operands) |a| s.function.atoms.free(a);
    if (s.function.atom_operands.len != 0) {
        s.function.memory.free(Atom, s.function.atom_operands);
        s.function.atom_operands = &.{};
    }

    try s.advance(); // consume the assignment operator

    if (assign_opcode) |op_byte| {
        try s.emitOpAtom(opcode.op.get_var, ident);
        try parseAssignExpr2(s, flags);
        try s.emitOp(op_byte);
        try s.emitOpAtom(opcode.op.put_var, ident);
    } else {
        try parseAssignExpr2(s, flags);
        try s.emitOpAtom(opcode.op.put_var, ident);
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

/// `js_parse_unary` (`quickjs.c:26922`). F4 first slice covers prefix
/// `+`, `-`, `~`, `!`, `void`, `typeof`. `delete`, `++`/`--`, `await`,
/// and `**` (PF_POW_ALLOWED) come in later F4 slices.
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
    try parsePostfixExpr(s, flags);
    // PF_POW_ALLOWED: `a ** b` is right-associative and only allowed
    // when no unary prefix was consumed.
    if (flags.pow_allowed and s.peekKind() == tok.TOK_POW) {
        try s.advance();
        try parseUnary(s, ParseFlags{ .in_accepted = flags.in_accepted, .pow_allowed = true });
        try s.emitOp(opcode.op.pow);
    }
}

/// `js_parse_postfix_expr` (`quickjs.c:26176`). F4 first slice covers
/// only the primary expression and `.`/`[]` member access without
/// calls. Calls and `new` are deferred to F4.4.
pub fn parsePostfixExpr(s: *ParseState, flags: ParseFlags) Error!void {
    try parsePrimary(s, flags);
    while (true) {
        const k = s.peekKind();
        if (k == @as(tok.TokenKind, @intCast('.'))) {
            try s.advance();
            if (s.peekKind() != tok.TOK_IDENT) return Error.UnexpectedToken;
            const name = s.token.payload.ident.atom;
            try s.advance();
            try s.emitOpAtom(opcode.op.get_field, name);
        } else if (k == @as(tok.TokenKind, @intCast('['))) {
            try s.advance();
            try parseExpr(s);
            try expectPunct(s, ']');
            try s.emitOp(opcode.op.get_array_el);
        } else {
            break;
        }
    }
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
            // Deferred: F4.5 will route through atom interning + `push_atom_value`.
            // For F4 first slice we use push_const with a string value.
            return Error.UnexpectedToken;
        },
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
            return Error.UnexpectedToken;
        },
    }
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
