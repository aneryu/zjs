//! Lexer tokens: the token kinds, their per-kind payloads, and the mapping
//! from keyword kinds to predefined atoms.

const std = @import("std");
const atom = @import("core/atom.zig");

/// Token kinds. A single-byte punctuator is its own ASCII byte, so the lexer
/// can `@enumFromInt` it directly; every other kind is numbered from 0x80 up.
/// The keywords `kw_null..kw_await` are contiguous and follow the predefined
/// atom table's keyword block row for row (see `keywordAtom`).
pub const Kind = enum(u8) {
    number = 0x80,
    string,
    template,
    ident,
    regexp,
    mul_assign,
    div_assign,
    mod_assign,
    plus_assign,
    minus_assign,
    shl_assign,
    sar_assign,
    shr_assign,
    and_assign,
    xor_assign,
    or_assign,
    pow_assign,
    land_assign,
    lor_assign,
    double_question_mark_assign,
    dec,
    inc,
    shl,
    sar,
    shr,
    lte,
    gte,
    eq,
    strict_eq,
    neq,
    strict_neq,
    land,
    lor,
    pow,
    arrow,
    ellipsis,
    double_question_mark,
    question_mark_dot,
    err,
    private_name,
    eof,
    kw_null,
    kw_false,
    kw_true,
    kw_if,
    kw_else,
    kw_return,
    kw_var,
    kw_this,
    kw_delete,
    kw_void,
    kw_typeof,
    kw_new,
    kw_in,
    kw_instanceof,
    kw_do,
    kw_while,
    kw_for,
    kw_break,
    kw_continue,
    kw_switch,
    kw_case,
    kw_default,
    kw_throw,
    kw_try,
    kw_catch,
    kw_finally,
    kw_function,
    kw_debugger,
    kw_with,
    kw_class,
    kw_const,
    kw_enum,
    kw_export,
    kw_extends,
    kw_import,
    kw_super,
    kw_implements,
    kw_interface,
    kw_let,
    kw_package,
    kw_private,
    kw_protected,
    kw_public,
    kw_static,
    kw_yield,
    kw_await,
    /// Never lexed: `of` stays an `ident`. Parser lookahead uses this kind
    /// for the contextual keyword.
    kw_of,
    // Single-byte punctuators. `newline` is the balanced scan's
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

    const first_keyword: Kind = .kw_null;
    const last_keyword: Kind = .kw_await;

    pub fn isKeyword(kind: Kind) bool {
        const raw = @intFromEnum(kind);
        return raw >= @intFromEnum(first_keyword) and raw <= @intFromEnum(last_keyword);
    }

    /// The source byte of a single-byte punctuator, or null for every other
    /// kind.
    pub fn punctuatorByte(kind: Kind) ?u8 {
        const raw = @intFromEnum(kind);
        return if (raw < 0x80) raw else null;
    }

    /// The predefined atom naming a keyword kind.
    pub fn keywordAtom(kind: Kind) atom.Atom {
        std.debug.assert(kind.isKeyword());
        return atom.Atom.fromRaw(atom.ids.null_.raw() + @intFromEnum(kind) - @intFromEnum(first_keyword));
    }

    /// Keyword spellings by length, generated from the `kw_*` tag names.
    const keywords_by_len = blk: {
        @setEvalBranchQuota(10_000);
        const max_len = 10;
        var counts = [_]usize{0} ** (max_len + 1);
        for (@intFromEnum(first_keyword)..@intFromEnum(last_keyword) + 1) |raw| {
            counts[keywordSpelling(@enumFromInt(raw)).len] += 1;
        }
        var table: [max_len + 1][]const Kind = undefined;
        for (&table, counts, 0..) |*row, count, len| {
            var kinds: [count]Kind = undefined;
            var i: usize = 0;
            for (@intFromEnum(first_keyword)..@intFromEnum(last_keyword) + 1) |raw| {
                const kind: Kind = @enumFromInt(raw);
                if (keywordSpelling(kind).len != len) continue;
                kinds[i] = kind;
                i += 1;
            }
            const final = kinds;
            row.* = &final;
        }
        break :blk table;
    };

    fn keywordSpelling(comptime kind: Kind) []const u8 {
        return @tagName(kind)["kw_".len..];
    }

    /// The keyword kind spelled by `lexeme`, if any.
    pub fn keyword(lexeme: []const u8) ?Kind {
        switch (lexeme.len) {
            inline 2...keywords_by_len.len - 1 => |len| {
                const bytes: *const [len]u8 = lexeme[0..len];
                inline for (keywords_by_len[len]) |kind| {
                    if (std.mem.eql(u8, bytes, keywordSpelling(kind))) return kind;
                }
                return null;
            },
            else => return null,
        }
    }

    comptime {
        // `keywordAtom` is plain arithmetic, so a reordering on either side
        // must fail the build instead of misnaming keywords.
        @setEvalBranchQuota(10_000);
        std.debug.assert(atom.last_keyword == keywordAtom(last_keyword));
        for (@intFromEnum(first_keyword)..@intFromEnum(last_keyword) + 1) |raw| {
            const kind: Kind = @enumFromInt(raw);
            std.debug.assert(std.mem.eql(u8, atom.predefinedName(keywordAtom(kind)), keywordSpelling(kind)));
        }
    }
};

pub const TemplatePart = enum(u8) {
    no_substitution, // `...`
    head, // `... ${
    middle, // }... ${
    tail, // }...`
};

/// Per-kind token payload.
pub const Payload = union(enum) {
    none,
    /// `number`; a BigInt literal keeps its digits in `bigint_text`.
    num: struct {
        value: f64,
        is_bigint: bool = false,
        bigint_text: []const u8 = "",
    },
    /// `string` / `template`. `sep` is the opening delimiter (`'`, `"`, or
    /// `` ` ``).
    str: struct {
        bytes: []u8,
        raw_bytes: []u8 = &.{},
        cooked_invalid: bool = false,
        contains_escape: bool = false,
        contains_legacy_escape: bool = false,
        sep: u8,
        template: ?TemplatePart = null,
    },
    /// `ident`, `private_name`, and every keyword.
    ident: struct {
        atom: atom.Atom,
        has_escape: bool,
    },
    /// `regexp` — pattern and flags as source slices.
    regexp: struct {
        pattern: []const u8,
        flags: []const u8,
    },
};

/// Lifetime: `payload.str.bytes` and `payload.str.raw_bytes` are owned by the
/// lexer's allocator; `payload.regexp.{pattern,flags}` are slices into the
/// source buffer.
pub const Token = struct {
    kind: Kind,
    line_num: u32,
    col_num: u32,
    /// Byte range `start..end` of the token in the source buffer.
    start: usize,
    end: usize,
    payload: Payload,

    pub fn len(tok: *const Token) usize {
        return tok.end - tok.start;
    }
};
