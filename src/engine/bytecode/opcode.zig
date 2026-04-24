const std = @import("std");

pub const quickjs_opcode_path = "quickjs/quickjs-opcode.h";
pub const max_opcode_count = 320;

pub const Format = enum {
    none,
    none_int,
    none_loc,
    none_arg,
    none_var_ref,
    u8,
    i8,
    loc8,
    const8,
    label8,
    u16,
    i16,
    label16,
    npop,
    npopx,
    npop_u16,
    loc,
    arg,
    var_ref,
    u32,
    u32x2,
    i32,
    @"const",
    label,
    atom,
    atom_u8,
    atom_u16,
    atom_label_u8,
    atom_label_u16,
    label_u16,
};

pub const Kind = enum {
    normal,
    temp,
    short,
};

pub const Metadata = struct {
    index: u16,
    name: []const u8,
    size: u8,
    n_pop: u8,
    n_push: u8,
    format: Format,
    kind: Kind,

    pub fn stackDelta(self: Metadata) i16 {
        return @as(i16, self.n_push) - @as(i16, self.n_pop);
    }
};

pub const ParsedTable = struct {
    entries: [max_opcode_count]Metadata = undefined,
    count: usize = 0,
    format_count: usize = 0,
    op_count: usize = 0,
    temp_start: usize = 0,
    temp_end: usize = 0,
    short_start: usize = 0,

    pub fn all(self: *const ParsedTable) []const Metadata {
        return self.entries[0..self.count];
    }

    pub fn at(self: *const ParsedTable, index: usize) ?Metadata {
        if (index >= self.count) return null;
        return self.entries[index];
    }

    pub fn find(self: *const ParsedTable, name: []const u8) ?Metadata {
        for (self.all()) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    pub fn indexOf(self: *const ParsedTable, name: []const u8) ?usize {
        for (self.all(), 0..) |entry, index| {
            if (std.mem.eql(u8, entry.name, name)) return index;
        }
        return null;
    }
};

pub fn parse(text: []const u8) ParsedTable {
    @setEvalBranchQuota(100000);
    var parsed = ParsedTable{};
    var seen_temp = false;
    var seen_short = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "FMT(")) {
            parsed.format_count += 1;
            continue;
        }

        const macro = if (std.mem.startsWith(u8, trimmed, "DEF("))
            "DEF"
        else if (std.mem.startsWith(u8, trimmed, "def("))
            "def"
        else
            continue;

        const start = std.mem.indexOfScalar(u8, trimmed, '(').? + 1;
        const end = std.mem.indexOfScalarPos(u8, trimmed, start, ')').?;
        const args_text = trimmed[start..end];
        var args = std.mem.splitScalar(u8, args_text, ',');

        const name = trimArg(args.next().?);
        const size_text = trimArg(args.next().?);
        const pop_text = trimArg(args.next().?);
        const push_text = trimArg(args.next().?);
        const format_text = trimArg(args.next().?);

        const index = parsed.count;
        var kind: Kind = .normal;
        if (std.mem.eql(u8, macro, "def")) {
            if (!seen_temp) parsed.temp_start = index;
            seen_temp = true;
            kind = .temp;
        } else if (seen_temp) {
            if (!seen_short) parsed.short_start = index;
            seen_short = true;
            kind = .short;
        }

        parsed.entries[index] = .{
            .index = @intCast(index),
            .name = name,
            .size = parseU8(size_text),
            .n_pop = parseU8(pop_text),
            .n_push = parseU8(push_text),
            .format = parseFormat(format_text),
            .kind = kind,
        };
        parsed.count += 1;
    }

    parsed.temp_end = parsed.short_start;
    parsed.op_count = parsed.temp_start;
    return parsed;
}

fn trimArg(arg: []const u8) []const u8 {
    return std.mem.trim(u8, arg, " \t\r");
}

fn parseU8(text: []const u8) u8 {
    return std.fmt.parseInt(u8, text, 10) catch unreachable;
}

fn parseFormat(text: []const u8) Format {
    inline for (@typeInfo(Format).@"enum".fields) |field| {
        if (std.mem.eql(u8, field.name, text)) return @enumFromInt(field.value);
    }
    unreachable;
}
