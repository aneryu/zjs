const std = @import("std");
const data = @import("data.zig");

const MapEntry = struct { []const u8, usize };

fn parseNameTableComptime(comptime table: []const u8) []const MapEntry {
    comptime {
        @setEvalBranchQuota(100000);
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

const ScriptMap = std.StaticStringMap(usize).initComptime(parseNameTableComptime(&data.unicode_script_name_table));
const GcMap = std.StaticStringMap(usize).initComptime(parseNameTableComptime(&data.unicode_gc_name_table));
const PropMap = std.StaticStringMap(usize).initComptime(parseNameTableComptime(&data.unicode_prop_name_table));

pub fn isScriptPropertyName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Script") or std.mem.eql(u8, name, "sc");
}

pub fn isScriptExtensionsPropertyName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Script_Extensions") or std.mem.eql(u8, name, "scx");
}

pub fn isGeneralCategoryPropertyName(name: []const u8) bool {
    return std.mem.eql(u8, name, "General_Category") or std.mem.eql(u8, name, "gc");
}

pub fn scriptIndex(script_name: []const u8) ?u32 {
    if (std.mem.eql(u8, script_name, "Unknown") or std.mem.eql(u8, script_name, "Zzzz")) return data.Script.Unknown;
    const found = ScriptMap.get(script_name) orelse return null;
    return @intCast(found + data.Script.Unknown + 1);
}

pub fn gcIndex(gc_name: []const u8) ?usize {
    return GcMap.get(gc_name);
}

pub fn propIndex(prop_name: []const u8) ?usize {
    const found = PropMap.get(prop_name) orelse return null;
    return found + data.Prop.ASCII_Hex_Digit;
}

pub fn gcBit(comptime name: []const u8) u32 {
    return @as(u32, 1) << @intCast(@field(data.GC, name));
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

pub fn gcMaskByIndex(gc_idx: usize) u32 {
    if (gc_idx < data.GC.LC) return @as(u32, 1) << @intCast(gc_idx);
    return gc_mask_table[gc_idx - data.GC.LC];
}

pub const ScriptExpression = struct {
    idx: u32,
    is_ext: bool,
};

pub const PropertyExpression = union(enum) {
    script: ScriptExpression,
    gc_mask: u32,
    prop_idx: usize,
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
