pub const Category = enum {
    uppercase_letter,
    lowercase_letter,
    decimal_number,
    identifier_start,
    identifier_continue,
    other,
};

pub fn asciiCategory(c: u21) Category {
    if (c >= 'A' and c <= 'Z') return .uppercase_letter;
    if (c >= 'a' and c <= 'z') return .lowercase_letter;
    if (c >= '0' and c <= '9') return .decimal_number;
    if (c == '_' or c == '$') return .identifier_start;
    return .other;
}
