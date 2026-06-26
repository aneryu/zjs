const std = @import("std");
const data = @import("data.zig");

const MapEntry = struct { []const u8, usize };

fn parseNameTableComptime(comptime table: []const u8) []const MapEntry {
    comptime {
        @setEvalBranchQuota(200000);
        var entries: []const MapEntry = &[_]MapEntry{};
        var p = table;
        var pos: usize = 0;
        while (p.len > 0 and p[0] != 0) {
            var len_to_null: usize = 0;
            while (len_to_null < p.len and p[len_to_null] != 0) : (len_to_null += 1) {}
            const group = p[0..len_to_null];

            var start: usize = 0;
            var i: usize = 0;
            while (i <= group.len) : (i += 1) {
                if (i == group.len or group[i] == ',') {
                    if (i > start) {
                        entries = entries ++ &[_]MapEntry{.{ group[start..i], pos }};
                    }
                    start = i + 1;
                }
            }

            p = p[len_to_null + 1 ..];
            pos += 1;
        }
        return entries;
    }
}

fn countNameGroupsComptime(comptime table: []const u8) usize {
    comptime {
        @setEvalBranchQuota(200000);
        var p = table;
        var count: usize = 0;
        while (p.len > 0 and p[0] != 0) {
            var len_to_null: usize = 0;
            while (len_to_null < p.len and p[len_to_null] != 0) : (len_to_null += 1) {}
            p = p[len_to_null + 1 ..];
            count += 1;
        }
        return count;
    }
}

fn validateNameTable(comptime label: []const u8, comptime table: []const u8, comptime group_count: usize) void {
    comptime {
        @setEvalBranchQuota(200000);
        const entries = parseNameTableComptime(table);
        if (entries.len == 0) @compileError(label ++ " name table is empty");
        for (entries, 0..) |entry, i| {
            if (entry[0].len == 0) @compileError(label ++ " name table has an empty alias");
            if (entry[1] >= group_count) @compileError(label ++ " alias points past the declared value count");
            var j: usize = 0;
            while (j < i) : (j += 1) {
                if (std.mem.eql(u8, entries[j][0], entry[0]) and entries[j][1] != entry[1]) {
                    @compileError(label ++ " name table has a duplicate alias for different values");
                }
            }
        }
    }
}

fn firstAliasMatchesEnumField(comptime table: []const u8, comptime enum_type: type, comptime enum_offset: usize) bool {
    comptime {
        @setEvalBranchQuota(200000);
        const enum_fields = @typeInfo(enum_type).@"enum".fields;
        var p = table;
        var pos: usize = 0;
        while (p.len > 0 and p[0] != 0) {
            var len_to_sep: usize = 0;
            while (len_to_sep < p.len and p[len_to_sep] != 0 and p[len_to_sep] != ',') : (len_to_sep += 1) {}
            if (enum_offset + pos >= enum_fields.len) return false;
            if (!std.mem.eql(u8, p[0..len_to_sep], enum_fields[enum_offset + pos].name)) return false;

            while (p.len > 0 and p[0] != 0) : (p = p[1..]) {}
            if (p.len == 0) break;
            p = p[1..];
            pos += 1;
        }
        return true;
    }
}

fn findName(table: []const u8, name: []const u8) ?usize {
    var p: usize = 0;
    var pos: usize = 0;
    while (p < table.len and table[p] != 0) {
        while (true) {
            const start = p;
            while (p < table.len and table[p] != 0 and table[p] != ',') : (p += 1) {}
            if (std.mem.eql(u8, table[start..p], name)) return pos;
            if (p >= table.len or table[p] == 0) break;
            p += 1;
        }
        if (p >= table.len) break;
        p += 1;
        pos += 1;
    }
    return null;
}

pub fn isScriptPropertyName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Script") or std.mem.eql(u8, name, "sc");
}

pub fn isScriptExtensionsPropertyName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Script_Extensions") or std.mem.eql(u8, name, "scx");
}

pub fn isGeneralCategoryPropertyName(name: []const u8) bool {
    return std.mem.eql(u8, name, "General_Category") or std.mem.eql(u8, name, "gc");
}

pub fn scriptIndex(script_name: []const u8) ?data.Script {
    const found = findName(&data.unicode_script_name_table, script_name) orelse return null;
    return @enumFromInt(found);
}

pub fn gcIndex(gc_name: []const u8) ?data.GC {
    const found = findName(&data.unicode_gc_name_table, gc_name) orelse return null;
    return @enumFromInt(found);
}

pub fn propIndex(prop_name: []const u8) ?data.Prop {
    const found = findName(&data.unicode_prop_name_table, prop_name) orelse return null;
    return @enumFromInt(found + @intFromEnum(data.prop_public_first));
}

pub fn sequencePropIndex(prop_name: []const u8) ?data.SequenceProp {
    const found = findName(&data.unicode_sequence_prop_name_table, prop_name) orelse return null;
    return @enumFromInt(found);
}

pub fn gcBit(comptime name: []const u8) u32 {
    return @as(u32, 1) << @intCast(@intFromEnum(@field(data.GC, name)));
}

pub const gc_mask_table = [_]u32{
    gcBit("Lu") | gcBit("Ll") | gcBit("Lt"),
    gcBit("Lu") | gcBit("Ll") | gcBit("Lt") | gcBit("Lm") | gcBit("Lo"),
    gcBit("Mn") | gcBit("Mc") | gcBit("Me"),
    gcBit("Nd") | gcBit("Nl") | gcBit("No"),
    gcBit("Sm") | gcBit("Sc") | gcBit("Sk") | gcBit("So"),
    gcBit("Pc") | gcBit("Pd") | gcBit("Ps") | gcBit("Pe") | gcBit("Pi") | gcBit("Pf") | gcBit("Po"),
    gcBit("Zs") | gcBit("Zl") | gcBit("Zp"),
    gcBit("Cc") | gcBit("Cf") | gcBit("Cs") | gcBit("Co") | gcBit("Cn"),
};

pub fn gcMaskByIndex(gc: data.GC) u32 {
    const gc_idx = @intFromEnum(gc);
    if (gc_idx < @intFromEnum(data.GC.LC)) return @as(u32, 1) << @intCast(gc_idx);
    return gc_mask_table[gc_idx - @intFromEnum(data.GC.LC)];
}

pub const ScriptExpression = struct {
    idx: data.Script,
    is_ext: bool,
};

pub const PropertyExpression = union(enum) {
    script: ScriptExpression,
    gc_mask: u32,
    prop_idx: data.Prop,
};

pub fn parsePropertyExpression(property_expr: []const u8) ?PropertyExpression {
    if (std.mem.indexOfScalar(u8, property_expr, '=')) |equals| {
        const property_name = property_expr[0..equals];
        const value = property_expr[equals + 1 ..];
        if (isScriptPropertyName(property_name) or isScriptExtensionsPropertyName(property_name)) {
            return .{ .script = .{
                .idx = scriptIndex(value) orelse return null,
                .is_ext = isScriptExtensionsPropertyName(property_name),
            } };
        }
        if (isGeneralCategoryPropertyName(property_name)) {
            return .{ .gc_mask = gcMaskByIndex(gcIndex(value) orelse return null) };
        }
        return null;
    }

    if (gcIndex(property_expr)) |gc_idx| {
        return .{ .gc_mask = gcMaskByIndex(gc_idx) };
    }

    if (propIndex(property_expr)) |prop_idx| {
        return .{ .prop_idx = prop_idx };
    }

    return null;
}

comptime {
    const prop_public_count = @intFromEnum(data.prop_public_last) - @intFromEnum(data.prop_public_first) + 1;

    if (countNameGroupsComptime(&data.unicode_gc_name_table) != data.GC.count()) {
        @compileError("unicode_gc_name_table must cover every GC value");
    }
    if (countNameGroupsComptime(&data.unicode_script_name_table) != data.Script.count()) {
        @compileError("unicode_script_name_table must cover every Script value");
    }
    if (countNameGroupsComptime(&data.unicode_prop_name_table) != prop_public_count) {
        @compileError("unicode_prop_name_table must cover the public named property range");
    }
    if (countNameGroupsComptime(&data.unicode_sequence_prop_name_table) != data.SequenceProp.count()) {
        @compileError("unicode_sequence_prop_name_table must cover every SequenceProp value");
    }

    validateNameTable("general category", &data.unicode_gc_name_table, data.GC.count());
    validateNameTable("script", &data.unicode_script_name_table, data.Script.count());
    validateNameTable("property", &data.unicode_prop_name_table, prop_public_count);
    validateNameTable("sequence property", &data.unicode_sequence_prop_name_table, data.SequenceProp.count());

    if (!firstAliasMatchesEnumField(&data.unicode_gc_name_table, data.GC, 0)) {
        @compileError("unicode_gc_name_table order must match GC tags");
    }
    if (!firstAliasMatchesEnumField(&data.unicode_script_name_table, data.Script, 0)) {
        @compileError("unicode_script_name_table order must match Script tags");
    }
    if (!firstAliasMatchesEnumField(&data.unicode_prop_name_table, data.Prop, @intFromEnum(data.prop_public_first))) {
        @compileError("unicode_prop_name_table order must match public Prop tags");
    }
    if (!firstAliasMatchesEnumField(&data.unicode_sequence_prop_name_table, data.SequenceProp, 0)) {
        @compileError("unicode_sequence_prop_name_table order must match SequenceProp tags");
    }
}

test "unicode name tables map aliases to QuickJS indexes" {
    try std.testing.expectEqual(data.GC.Lu, gcIndex("Lu").?);
    try std.testing.expectEqual(data.GC.Lu, gcIndex("Uppercase_Letter").?);
    try std.testing.expectEqual(data.Script.Unknown, scriptIndex("Zzzz").?);
    try std.testing.expectEqual(data.Script.Greek, scriptIndex("Grek").?);
    try std.testing.expectEqual(data.Prop.ASCII_Hex_Digit, propIndex("AHex").?);
    try std.testing.expectEqual(data.Prop.ID_Compat_Math_Start, propIndex("ID_Compat_Math_Start").?);
    try std.testing.expectEqual(data.Prop.ID_Compat_Math_Continue, propIndex("ID_Compat_Math_Continue").?);
    try std.testing.expectEqual(data.Prop.InCB, propIndex("InCB").?);
    try std.testing.expectEqual(data.Prop.Lowercase, propIndex("Lower").?);
    try std.testing.expectEqual(data.Prop.Math, propIndex("Math").?);
    try std.testing.expectEqual(data.Prop.Uppercase, propIndex("Upper").?);
    try std.testing.expectEqual(data.Prop.XID_Start, propIndex("XIDS").?);
    try std.testing.expectEqual(data.SequenceProp.Basic_Emoji, sequencePropIndex("Basic_Emoji").?);
    try std.testing.expectEqual(data.SequenceProp.RGI_Emoji, sequencePropIndex("RGI_Emoji").?);
    try std.testing.expectEqual(@as(?data.Prop, null), propIndex("Cased1"));
}
