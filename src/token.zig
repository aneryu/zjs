//! QuickJS-aligned token API mirroring `JSToken` and `TOK_*` from
//! QuickJS `quickjs.c`.
//!
//! Strong-alignment contract:
//!   * `Kind` integer values match `enum { TOK_NUMBER = -128, ... }`
//! in `quickjs.c` exactly.
//!   * Single-character punctuators reuse their raw ASCII byte (so `+`
//!     is `0x2B`, `;` is `0x3B`, …) — QuickJS does the same.
//!   * The keyword block `TOK_NULL..TOK_AWAIT` is laid out so that
//!     `tokenAtomFromKeyword(tok) == ATOM_null + (tok - TOK_NULL)`
//! because `quickjs-atom.h:29..76` matches `quickjs.c`
//!     row-for-row. `keywordAtomAlignmentTest` enforces the invariant.

const std = @import("std");
const atom = @import("core/atom.zig");

/// Token kinds. The integer values are QuickJS's `TOK_*` numbering
///: keyword tokens map onto the predefined atom ids
/// (`keywordAtom`), the assignment operators derive their opcode from
/// `OP_mul + (op - mul_assign)`, and single-byte punctuators keep their
/// ASCII value so the lexer can `@enumFromInt` them.
pub const Kind = enum(i16) {
    number = -128,
    string = -127,
    template = -126,
    ident = -125,
    regexp = -124,
    // Order is significant: js_parse_assign_expr2 derives the assignment
    // opcode from `OP_mul + (op - mul_assign)`.
    mul_assign = -123,
    div_assign = -122,
    mod_assign = -121,
    plus_assign = -120,
    minus_assign = -119,
    shl_assign = -118,
    sar_assign = -117,
    shr_assign = -116,
    and_assign = -115,
    xor_assign = -114,
    or_assign = -113,
    pow_assign = -112,
    land_assign = -111,
    lor_assign = -110,
    double_question_mark_assign = -109,
    // `<` and `>` are lexed as the single-byte `lt` / `gt`; the two QuickJS
    // slots are kept so the numbering stays aligned.
    dec = -108,
    inc = -107,
    shl = -106,
    sar = -105,
    shr = -104,
    lt_reserved = -103,
    lte = -102,
    gt_reserved = -101,
    gte = -100,
    eq = -99,
    strict_eq = -98,
    neq = -97,
    strict_neq = -96,
    land = -95,
    lor = -94,
    pow = -93,
    arrow = -92,
    ellipsis = -91,
    double_question_mark = -90,
    question_mark_dot = -89,
    err = -88,
    private_name = -87,
    eof = -86,
    // Keywords, in `quickjs-atom.h` order; `kw_of` and `kw_async` are
    // pseudo keywords the lexer never emits (they stay TOK_IDENT).
    kw_null = -85,
    kw_false = -84,
    kw_true = -83,
    kw_if = -82,
    kw_else = -81,
    kw_return = -80,
    kw_var = -79,
    kw_this = -78,
    kw_delete = -77,
    kw_void = -76,
    kw_typeof = -75,
    kw_new = -74,
    kw_in = -73,
    kw_instanceof = -72,
    kw_do = -71,
    kw_while = -70,
    kw_for = -69,
    kw_break = -68,
    kw_continue = -67,
    kw_switch = -66,
    kw_case = -65,
    kw_default = -64,
    kw_throw = -63,
    kw_try = -62,
    kw_catch = -61,
    kw_finally = -60,
    kw_function = -59,
    kw_debugger = -58,
    kw_with = -57,
    kw_class = -56,
    kw_const = -55,
    kw_enum = -54,
    kw_export = -53,
    kw_extends = -52,
    kw_import = -51,
    kw_super = -50,
    kw_implements = -49,
    kw_interface = -48,
    kw_let = -47,
    kw_package = -46,
    kw_private = -45,
    kw_protected = -44,
    kw_public = -43,
    kw_static = -42,
    kw_yield = -41,
    kw_await = -40,
    kw_of = -39,
    kw_async = -38,
    // Single-byte punctuators; `newline` is the balanced scan's
    // line-terminator sentinel.
    newline = '\n',
    bang = '!',
    percent = '%',
    amp = '&',
    lparen = '(',
    rparen = ')',
    star = '*',
    plus = '+',
    comma = ',',
    minus = '-',
    dot = '.',
    slash = '/',
    colon = ':',
    semicolon = ';',
    lt = '<',
    assign = '=',
    gt = '>',
    question = '?',
    lbracket = '[',
    rbracket = ']',
    caret = '^',
    lbrace = '{',
    pipe = '|',
    rbrace = '}',
    tilde = '~',
};

pub const first_keyword = Kind.kw_null;
pub const last_keyword = Kind.kw_await;

pub fn isKeyword(val: Kind) bool {
    const raw = @intFromEnum(val);
    return raw >= @intFromEnum(first_keyword) and raw <= @intFromEnum(last_keyword);
}

/// Map a keyword token to its predefined atom. Mirrors the QuickJS
/// invariant `s->token.u.ident.atom = atom_null + (val - TOK_NULL)`
/// (see `quickjs.c`). Predefined atom ids start at 1 and the
/// 47 keywords occupy ids 1..47 in `quickjs-atom.h:29..76`.
pub fn keywordAtom(val: Kind) atom.Atom {
    std.debug.assert(isKeyword(val));
    return atom.Atom.fromRaw(atom.ids.null_.raw() + @as(u32, @intCast(@intFromEnum(val) - @intFromEnum(first_keyword))));
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
        raw_bytes: []u8 = &.{},
        cooked_invalid: bool = false,
        contains_escape: bool = false,
        contains_legacy_escape: bool = false,
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

/// QuickJS-aligned token. Mirrors `JSToken` with the
/// same field set (`val`, `line_num`, `col_num`, `ptr`) plus a sum type
/// for the per-kind payload. Lifetime: `payload.str.bytes` and optional
/// `payload.str.raw_bytes` are owned by
/// the lexer's allocator; `payload.regexp.{pattern,flags}` are slices
/// into the source buffer.
pub const TokenImpl = struct {
    val: Kind,
    line_num: u32,
    col_num: u32,
    /// Pointer to the first byte of the token in the source buffer.
    ptr: [*]const u8,
    /// Length of the token in source bytes. Not present in JSToken
    /// (which uses `s->buf_ptr - s->mark`); we expose it for tests.
    len: usize,
    payload: Payload,
};

test "F1: keyword token integer values match QuickJS TOK_*" {
    // Spot-check anchors from quickjs.c.
    try std.testing.expectEqual(@as(i16, -128), @intFromEnum(Kind.number));
    try std.testing.expectEqual(@as(i16, -127), @intFromEnum(Kind.string));
    try std.testing.expectEqual(@as(i16, -125), @intFromEnum(Kind.ident));
    try std.testing.expectEqual(@as(i16, -86), @intFromEnum(Kind.eof));
    try std.testing.expectEqual(@as(i16, -85), @intFromEnum(Kind.kw_null));
    try std.testing.expectEqual(@as(i16, -40), @intFromEnum(Kind.kw_await));
    try std.testing.expectEqual(@as(i16, -39), @intFromEnum(Kind.kw_of));
}

pub const TokenKind = Kind;
pub const Token = TokenImpl;
