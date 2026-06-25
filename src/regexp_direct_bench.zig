const std = @import("std");
const regexp = @import("libs/regexp.zig");

const Case = struct {
    name: []const u8,
    pattern: []const u8,
    flags: []const u8 = "",
    input: []const u8,
    iterations: usize,
    warmup: usize = 1_000,
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    const long_a = try repeatByte(allocator, 'a', 4096, "");
    defer allocator.free(long_a);
    const medium_a = try repeatByte(allocator, 'a', 128, "b");
    defer allocator.free(medium_a);
    const class_input = try repeatSlice(allocator, "ABCDEF0123456789_", 64);
    defer allocator.free(class_input);
    const capture_reset_input = try joinRepeated(allocator, "", "ab", 32, "b");
    defer allocator.free(capture_reset_input);
    const named_backref_input = try joinRepeated(allocator, "abc", "-12", 32, "-abc-12");
    defer allocator.free(named_backref_input);
    const lookbehind_input = try joinRepeated(allocator, "", "xxfoo---", 128, "barABC12yy");
    defer allocator.free(lookbehind_input);
    const neg_lookahead_input = try repeatSlice(allocator, "abcdefgh", 64);
    defer allocator.free(neg_lookahead_input);
    const html_input = try joinRepeated(allocator, "<section data-id=\"42\">", "alpha123-", 256, "</section>");
    defer allocator.free(html_input);
    const domain_input = try joinRepeated(allocator, "", "noise-", 128, "www1.Example123.API_v2.Node99.local tail");
    defer allocator.free(domain_input);
    const unicode_hex_input = try joinRepeated(allocator, "", "0A:", 127, "0A");
    defer allocator.free(unicode_hex_input);
    const unicode_sets_input = try repeatSlice(allocator, "Alpha_123", 64);
    defer allocator.free(unicode_sets_input);

    const cases = [_]Case{
        .{ .name = "literal-hit", .pattern = "abc", .input = "zzzzzzabczzzz", .iterations = 100_000 },
        .{ .name = "search-miss-long", .pattern = "Z", .input = long_a, .iterations = 20_000 },
        .{ .name = "simple-quant", .pattern = "a+b", .input = medium_a, .iterations = 100_000 },
        .{ .name = "class-quant", .pattern = "^[A-Z0-9_]+$", .input = class_input, .iterations = 50_000 },
        .{ .name = "backref", .pattern = "(a+)b\\1", .input = "aaaaabaaaaa", .iterations = 100_000 },
        .{ .name = "alt-quant", .pattern = "(?:ab|a)+b", .input = "ababababababababababababababababab", .iterations = 100_000 },
        .{ .name = "lookahead", .pattern = "(?=a+)a+z", .input = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaz", .iterations = 100_000 },
        .{ .name = "lazy", .pattern = "a+?z", .input = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaz", .iterations = 100_000 },
        .{ .name = "complex/overlap-alt-hit", .pattern = "^(?:a|aa|aaa|aaaa){12}$", .input = "aaaaaaaaaaaaaaaaaaaaaaaa", .iterations = 1_000, .warmup = 20 },
        .{ .name = "complex/overlap-alt-miss", .pattern = "^(?:a|aa|aaa|aaaa){12}b$", .input = "aaaaaaaaaaaaaaaaaaaaaaaa", .iterations = 10, .warmup = 1 },
        .{ .name = "complex/capture-reset-loop-long", .pattern = "^(?:(a)|(b)){64}\\2$", .input = capture_reset_input, .iterations = 5_000, .warmup = 100 },
        .{ .name = "complex/named-backref-chain-long", .pattern = "^(?<word>[A-Za-z]{3})(?:-(\\d{2})){32}-\\k<word>-\\2$", .input = named_backref_input, .iterations = 5_000, .warmup = 100 },
        .{ .name = "complex/lookbehind-alt-long-search", .pattern = "(?<=foo|bar)[A-Z]{3}(?=\\d{2})", .input = lookbehind_input, .iterations = 5_000, .warmup = 100 },
        .{ .name = "complex/negative-lookahead-loop-long", .pattern = "^(?:(?!bad)[a-z]){512}$", .input = neg_lookahead_input, .iterations = 1_000, .warmup = 20 },
        .{ .name = "complex/lazy-tag-backref-long", .pattern = "^<([A-Za-z][A-Za-z0-9]*)\\b[^>]*>.*?</\\1>$", .input = html_input, .iterations = 1_000, .warmup = 20 },
        .{ .name = "complex/ignore-case-domain-long-search", .pattern = "\\b(?:[a-z][a-z0-9_]{3,12}\\.){4}[a-z]{2,6}\\b", .flags = "i", .input = domain_input, .iterations = 2_000, .warmup = 100 },
        .{ .name = "complex/unicode-property-hex-long", .pattern = "^(?:\\p{ASCII_Hex_Digit}{2}:){127}\\p{ASCII_Hex_Digit}{2}$", .flags = "u", .input = unicode_hex_input, .iterations = 1_000, .warmup = 20 },
        .{ .name = "complex/unicode-sets-intersection-long", .pattern = "^[\\p{ASCII}&&\\p{ID_Continue}]+$", .flags = "v", .input = unicode_sets_input, .iterations = 5_000, .warmup = 100 },
    };

    std.debug.print("engine,case,iterations,nanoseconds,matches\n", .{});
    for (cases) |case| {
        try runCase(allocator, case);
    }
}

fn runCase(allocator: std.mem.Allocator, case: Case) !void {
    const bytecode = try regexp.engine.compile(allocator, case.pattern, case.flags);
    defer allocator.free(bytecode);

    var matches: usize = 0;
    var warmup: usize = 0;
    while (warmup < case.warmup) : (warmup += 1) {
        const status = try regexp.engine.exec(allocator, bytecode, .{ .latin1 = case.input }, 0);
        if (status.result == .match) matches += 1;
    }

    const start = monotonicNanos();
    var i: usize = 0;
    while (i < case.iterations) : (i += 1) {
        const status = try regexp.engine.exec(allocator, bytecode, .{ .latin1 = case.input }, 0);
        if (status.result == .match) matches += 1;
    }
    const elapsed = elapsedNanosSince(start);

    std.debug.print("zjs-regexp-facade,{s},{d},{d},{d}\n", .{ case.name, case.iterations, elapsed, matches });
}

fn repeatByte(allocator: std.mem.Allocator, byte: u8, count: usize, suffix: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, count + suffix.len);
    @memset(buf[0..count], byte);
    @memcpy(buf[count..], suffix);
    return buf;
}

fn repeatSlice(allocator: std.mem.Allocator, slice: []const u8, count: usize) ![]u8 {
    const buf = try allocator.alloc(u8, slice.len * count);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        @memcpy(buf[i * slice.len ..][0..slice.len], slice);
    }
    return buf;
}

fn joinRepeated(allocator: std.mem.Allocator, prefix: []const u8, slice: []const u8, count: usize, suffix: []const u8) ![]u8 {
    const repeated_len = slice.len * count;
    const buf = try allocator.alloc(u8, prefix.len + repeated_len + suffix.len);
    @memcpy(buf[0..prefix.len], prefix);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const start = prefix.len + i * slice.len;
        @memcpy(buf[start..][0..slice.len], slice);
    }
    @memcpy(buf[prefix.len + repeated_len ..], suffix);
    return buf;
}

fn elapsedNanosSince(start: u64) u64 {
    const end = monotonicNanos();
    return if (end > start) end - start else 0;
}

fn monotonicNanos() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
