const source_pos = @import("source_pos.zig");

pub const Kind = enum {
    eof,
    identifier,
    private_identifier,
    numeric,
    bigint,
    string,
    template_no_substitution,
    template_head,
    template_middle,
    template_tail,
    regexp,
    keyword,
    punctuator,
};

pub const Keyword = enum {
    async,
    await,
    @"break",
    case,
    @"catch",
    class,
    @"const",
    default,
    @"export",
    extends,
    function,
    import,
    let,
    module,
    @"return",
    static,
    super,
    throw,
    var_,
    yield,
};

pub const Token = struct {
    kind: Kind,
    lexeme: []const u8 = "",
    range: source_pos.Range,
    keyword: ?Keyword = null,

    pub fn isKeyword(self: Token, keyword: Keyword) bool {
        return self.kind == .keyword and self.keyword == keyword;
    }
};

pub fn keywordFor(bytes: []const u8) ?Keyword {
    inline for (@typeInfo(Keyword).@"enum".fields) |field| {
        const spelling = if (std.mem.eql(u8, field.name, "var_")) "var" else field.name;
        if (std.mem.eql(u8, spelling, bytes)) return @enumFromInt(field.value);
    }
    return null;
}

const std = @import("std");
