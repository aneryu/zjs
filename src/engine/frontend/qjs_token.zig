//! QuickJS-aligned token API mirroring `JSToken` and `TOK_*` from
//! `quickjs/quickjs.c:21246..21645`.
//!
//! This module is the F1 deliverable. It coexists with the legacy
//! `frontend/token.zig` until F11 deletes the QuickParser. New parser
//! code (F4+) consumes `Token` from this module; legacy code keeps
//! using the old `Kind` enum until migration.
//!
//! Strong-alignment contract (PARSER_REWRITE_PLAN §1):
//!   * `TokenKind` integer values match `enum { TOK_NUMBER = -128, ... }`
//!     in `quickjs.c:21246` exactly.
//!   * Single-character punctuators reuse their raw ASCII byte (so `+`
//!     is `0x2B`, `;` is `0x3B`, …) — QuickJS does the same.
//!   * The keyword block `TOK_NULL..TOK_AWAIT` is laid out so that
//!     `tokenAtomFromKeyword(tok) == ATOM_null + (tok - TOK_NULL)`
//!     because `quickjs-atom.h:29..76` matches `quickjs.c:21291..21338`
//!     row-for-row. `keywordAtomAlignmentTest` enforces the invariant.

const std = @import("std");
const atom = @import("../core/atom.zig");

/// QuickJS-equivalent of `enum { TOK_NUMBER = -128, ... }`.
/// Stored as `i16` to make signedness and overflow explicit.
pub const TokenKind = i16;

pub const TOK_NUMBER: TokenKind = -128;
pub const TOK_STRING: TokenKind = -127;
pub const TOK_TEMPLATE: TokenKind = -126;
pub const TOK_IDENT: TokenKind = -125;
pub const TOK_REGEXP: TokenKind = -124;

// Order is significant: js_parse_assign_expr2 derives the assignment
// opcode from `OP_mul + (op - TOK_MUL_ASSIGN)`.
pub const TOK_MUL_ASSIGN: TokenKind = -123;
pub const TOK_DIV_ASSIGN: TokenKind = -122;
pub const TOK_MOD_ASSIGN: TokenKind = -121;
pub const TOK_PLUS_ASSIGN: TokenKind = -120;
pub const TOK_MINUS_ASSIGN: TokenKind = -119;
pub const TOK_SHL_ASSIGN: TokenKind = -118;
pub const TOK_SAR_ASSIGN: TokenKind = -117;
pub const TOK_SHR_ASSIGN: TokenKind = -116;
pub const TOK_AND_ASSIGN: TokenKind = -115;
pub const TOK_XOR_ASSIGN: TokenKind = -114;
pub const TOK_OR_ASSIGN: TokenKind = -113;
pub const TOK_POW_ASSIGN: TokenKind = -112;
pub const TOK_LAND_ASSIGN: TokenKind = -111;
pub const TOK_LOR_ASSIGN: TokenKind = -110;
pub const TOK_DOUBLE_QUESTION_MARK_ASSIGN: TokenKind = -109;

pub const TOK_DEC: TokenKind = -108;
pub const TOK_INC: TokenKind = -107;
pub const TOK_SHL: TokenKind = -106;
pub const TOK_SAR: TokenKind = -105;
pub const TOK_SHR: TokenKind = -104;
pub const TOK_LT: TokenKind = -103;
pub const TOK_LTE: TokenKind = -102;
pub const TOK_GT: TokenKind = -101;
pub const TOK_GTE: TokenKind = -100;
pub const TOK_EQ: TokenKind = -99;
pub const TOK_STRICT_EQ: TokenKind = -98;
pub const TOK_NEQ: TokenKind = -97;
pub const TOK_STRICT_NEQ: TokenKind = -96;
pub const TOK_LAND: TokenKind = -95;
pub const TOK_LOR: TokenKind = -94;
pub const TOK_POW: TokenKind = -93;
pub const TOK_ARROW: TokenKind = -92;
pub const TOK_ELLIPSIS: TokenKind = -91;
pub const TOK_DOUBLE_QUESTION_MARK: TokenKind = -90;
pub const TOK_QUESTION_MARK_DOT: TokenKind = -89;
pub const TOK_ERROR: TokenKind = -88;
pub const TOK_PRIVATE_NAME: TokenKind = -87;
pub const TOK_EOF: TokenKind = -86;

// Keyword block — order MUST match `quickjs-atom.h:29..76` so that
// `s->token.u.ident.atom == ATOM_null + (s->token.val - TOK_NULL)`
// for any keyword token, exactly like QuickJS.
pub const TOK_NULL: TokenKind = -85;
pub const TOK_FALSE: TokenKind = -84;
pub const TOK_TRUE: TokenKind = -83;
pub const TOK_IF: TokenKind = -82;
pub const TOK_ELSE: TokenKind = -81;
pub const TOK_RETURN: TokenKind = -80;
pub const TOK_VAR: TokenKind = -79;
pub const TOK_THIS: TokenKind = -78;
pub const TOK_DELETE: TokenKind = -77;
pub const TOK_VOID: TokenKind = -76;
pub const TOK_TYPEOF: TokenKind = -75;
pub const TOK_NEW: TokenKind = -74;
pub const TOK_IN: TokenKind = -73;
pub const TOK_INSTANCEOF: TokenKind = -72;
pub const TOK_DO: TokenKind = -71;
pub const TOK_WHILE: TokenKind = -70;
pub const TOK_FOR: TokenKind = -69;
pub const TOK_BREAK: TokenKind = -68;
pub const TOK_CONTINUE: TokenKind = -67;
pub const TOK_SWITCH: TokenKind = -66;
pub const TOK_CASE: TokenKind = -65;
pub const TOK_DEFAULT: TokenKind = -64;
pub const TOK_THROW: TokenKind = -63;
pub const TOK_TRY: TokenKind = -62;
pub const TOK_CATCH: TokenKind = -61;
pub const TOK_FINALLY: TokenKind = -60;
pub const TOK_FUNCTION: TokenKind = -59;
pub const TOK_DEBUGGER: TokenKind = -58;
pub const TOK_WITH: TokenKind = -57;
pub const TOK_CLASS: TokenKind = -56;
pub const TOK_CONST: TokenKind = -55;
pub const TOK_ENUM: TokenKind = -54;
pub const TOK_EXPORT: TokenKind = -53;
pub const TOK_EXTENDS: TokenKind = -52;
pub const TOK_IMPORT: TokenKind = -51;
pub const TOK_SUPER: TokenKind = -50;
pub const TOK_IMPLEMENTS: TokenKind = -49;
pub const TOK_INTERFACE: TokenKind = -48;
pub const TOK_LET: TokenKind = -47;
pub const TOK_PACKAGE: TokenKind = -46;
pub const TOK_PRIVATE: TokenKind = -45;
pub const TOK_PROTECTED: TokenKind = -44;
pub const TOK_PUBLIC: TokenKind = -43;
pub const TOK_STATIC: TokenKind = -42;
pub const TOK_YIELD: TokenKind = -41;
pub const TOK_AWAIT: TokenKind = -40;
pub const TOK_OF: TokenKind = -39;
pub const TOK_ASYNC: TokenKind = -38;

pub const TOK_FIRST_KEYWORD: TokenKind = TOK_NULL;
pub const TOK_LAST_KEYWORD: TokenKind = TOK_AWAIT;

pub fn isKeyword(val: TokenKind) bool {
    return val >= TOK_FIRST_KEYWORD and val <= TOK_LAST_KEYWORD;
}

/// Map a keyword token id to its predefined atom. Mirrors the QuickJS
/// invariant `s->token.u.ident.atom = atom_null + (val - TOK_NULL)`
/// (see `quickjs.c:21649`). Predefined atom ids start at 1 and the
/// 47 keywords occupy ids 1..47 in `quickjs-atom.h:29..76`.
pub fn keywordAtom(val: TokenKind) atom.Atom {
    std.debug.assert(isKeyword(val));
    return atom.ids.null_ + @as(atom.Atom, @intCast(val - TOK_NULL));
}

/// Per-token payload union (mirrors JSToken's anonymous union).
pub const TemplatePart = enum(u8) {
    no_substitution, // `...`
    head, // `... ${
    middle, // }... ${
    tail, // }...`
};

pub const Payload = union(enum) {
    none,
    /// TOK_NUMBER — for now we keep both the lexeme bytes and the parsed
    /// double; bigint is reported via `is_bigint`. F4 will move to a
    /// JSValue payload (matching `JSToken.u.num.val`).
    num: struct {
        value: f64,
        is_bigint: bool = false,
        bigint_text: []const u8 = "",
    },
    /// TOK_STRING / TOK_TEMPLATE — owns the decoded UTF-8 byte slice.
    /// `sep` matches QuickJS `JSToken.u.str.sep` (`'`, `"`, `` ` ``, or
    /// the substitution delimiter).
    str: struct {
        bytes: []u8,
        sep: u8,
        template: ?TemplatePart = null,
    },
    /// TOK_IDENT, TOK_PRIVATE_NAME, and any keyword.
    ident: struct {
        atom: atom.Atom,
        has_escape: bool,
        is_reserved: bool,
    },
    /// TOK_REGEXP — pattern + flags as raw source bytes (compiled in F12).
    regexp: struct {
        pattern: []const u8,
        flags: []const u8,
    },
};

/// QuickJS-aligned token. Mirrors `JSToken` (quickjs.c:21539) with the
/// same field set (`val`, `line_num`, `col_num`, `ptr`) plus a sum type
/// for the per-kind payload. Lifetime: `payload.str.bytes` is owned by
/// the lexer's allocator; `payload.regexp.{pattern,flags}` are slices
/// into the source buffer.
pub const Token = struct {
    val: TokenKind,
    line_num: u32,
    col_num: u32,
    /// Pointer to the first byte of the token in the source buffer.
    ptr: [*]const u8,
    /// Length of the token in source bytes. Not present in JSToken
    /// (which uses `s->buf_ptr - s->mark`); we expose it for tests.
    len: usize,
    payload: Payload,
};
