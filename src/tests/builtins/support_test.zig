const std = @import("std");
const engine = @import("quickjs_zig_engine");
const libs = engine.libs;

fn rangesContain(ranges: []const libs.unicode.CodePointRange, code_point: u21) bool {
    for (ranges) |range| {
        if (code_point >= range.lo and code_point < range.hi) return true;
    }
    return false;
}

test "support libraries cover unicode dtoa bignum and regexp basics" {
    try std.testing.expect(libs.unicode.isIdentifierStart('A'));
    try std.testing.expect(libs.unicode.isIdentifierStart(0x03c0));
    try std.testing.expect(!libs.unicode.isIdentifierStart(0x01f600));
    try std.testing.expect(libs.unicode.isIdentifierContinue('9'));
    try std.testing.expect(libs.unicode.isIdentifierContinue(0x200c));
    try std.testing.expectEqual(@as(u8, 'A'), libs.unicode.toUpperAscii('a'));
    try std.testing.expect(libs.unicode.equalsIgnoreAsciiCase("AbC", "aBc"));
    try std.testing.expectEqual(@as(u21, 'k'), libs.unicode.regexpCanonicalize(0x212a, true));
    try std.testing.expectEqual(@as(u21, 's'), libs.unicode.regexpCanonicalize(0x017f, true));

    const nfc_input = [_]u32{ 0x1e9b, 0x0323 };
    const nfc = try libs.unicode.normalizeAlloc(std.testing.allocator, &nfc_input, .nfc);
    defer std.testing.allocator.free(nfc);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0x1e9b, 0x0323 }, nfc);
    const nfd = try libs.unicode.normalizeAlloc(std.testing.allocator, &nfc_input, .nfd);
    defer std.testing.allocator.free(nfd);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0x017f, 0x0323, 0x0307 }, nfd);
    const nfkc = try libs.unicode.normalizeAlloc(std.testing.allocator, &nfc_input, .nfkc);
    defer std.testing.allocator.free(nfkc);
    try std.testing.expectEqualSlices(u32, &[_]u32{0x1e69}, nfkc);
    const nfkd = try libs.unicode.normalizeAlloc(std.testing.allocator, &nfc_input, .nfkd);
    defer std.testing.allocator.free(nfkd);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0x0073, 0x0323, 0x0307 }, nfkd);

    const ascii_ranges = try libs.unicode.propertyRangesAlloc(std.testing.allocator, "ASCII", false);
    defer std.testing.allocator.free(ascii_ranges);
    try std.testing.expect(rangesContain(ascii_ranges, 'A'));
    try std.testing.expect(!rangesContain(ascii_ranges, 0x80));
    const non_ascii_ranges = try libs.unicode.propertyRangesAlloc(std.testing.allocator, "ASCII", true);
    defer std.testing.allocator.free(non_ascii_ranges);
    try std.testing.expect(!rangesContain(non_ascii_ranges, 'A'));
    try std.testing.expect(rangesContain(non_ascii_ranges, 0x80));
    try std.testing.expect(rangesContain(non_ascii_ranges, 0x10ffff));
    const greek_ranges = try libs.unicode.propertyRangesAlloc(std.testing.allocator, "Script=Greek", false);
    defer std.testing.allocator.free(greek_ranges);
    try std.testing.expect(rangesContain(greek_ranges, 0x03c0));
    try std.testing.expect(!rangesContain(greek_ranges, 'A'));

    try std.testing.expect(libs.emoji.isEmojiCodePoint(0x01f600));
    try std.testing.expect(libs.emoji.isEmojiPresentationCodePoint(0x01f600));
    try std.testing.expect(!libs.emoji.isEmojiPresentationCodePoint(0x260e));

    const flag = [_]u16{ 0xd83c, 0xdde8, 0xd83c, 0xddf6 };
    const flag_match = libs.emoji.findRgiEmojiMatch(.{ .utf16 = &flag }, 0, false).?;
    try std.testing.expectEqual(@as(usize, 0), flag_match.index);
    try std.testing.expectEqual(@as(usize, flag.len), flag_match.len);
    try std.testing.expect(libs.emoji.rgiEmojiSequencesCover(.{ .utf16 = &flag }));

    const phone_text = [_]u16{0x260e};
    try std.testing.expect(!libs.emoji.rgiEmojiSequencesCover(.{ .utf16 = &phone_text }));
    const phone_emoji = [_]u16{ 0x260e, 0xfe0f };
    try std.testing.expect(libs.emoji.rgiEmojiSequencesCover(.{ .utf16 = &phone_emoji }));

    const prefixed = [_]u16{ 'a', 0xd83c, 0xdde8, 0xd83c, 0xddf6 };
    const prefixed_match = libs.emoji.findRgiEmojiMatch(.{ .utf16 = &prefixed }, 0, false).?;
    try std.testing.expectEqual(@as(usize, 1), prefixed_match.index);
    try std.testing.expectEqual(@as(usize, 4), prefixed_match.len);
    try std.testing.expect(libs.emoji.findRgiEmojiMatch(.{ .utf16 = &prefixed }, 0, true) == null);

    const n = try libs.dtoa.parseNumber("12.5");
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12.5", try libs.dtoa.formatNumber(&buf, n));
    try std.testing.expect(std.math.isPositiveInf(try libs.dtoa.parseNumber("+Infinity")));

    var forty = try libs.bignum.parseBase10(std.testing.allocator, "40");
    defer forty.deinit();
    var two = try libs.bignum.BigInt.fromInt(std.testing.allocator, 2);
    defer two.deinit();
    var big = try forty.add(two);
    defer big.deinit();
    const big_text = try big.formatBase10Alloc(std.testing.allocator);
    defer std.testing.allocator.free(big_text);
    try std.testing.expectEqualStrings("42", big_text);
    var zero = try libs.bignum.BigInt.fromInt(std.testing.allocator, 0);
    defer zero.deinit();
    try std.testing.expectError(error.DivisionByZero, big.div(zero));
    var huge = try libs.bignum.parseBase10(std.testing.allocator, "12345678901234567890123456789012345678901234567890");
    defer huge.deinit();
    const huge_text = try huge.formatBase10Alloc(std.testing.allocator);
    defer std.testing.allocator.free(huge_text);
    try std.testing.expectEqualStrings("12345678901234567890123456789012345678901234567890", huge_text);
    var divisor = try libs.bignum.BigInt.fromInt(std.testing.allocator, 97);
    defer divisor.deinit();
    var quotient = try huge.div(divisor);
    defer quotient.deinit();
    var remainder = try huge.rem(divisor);
    defer remainder.deinit();
    const quotient_text = try quotient.formatBase10Alloc(std.testing.allocator);
    defer std.testing.allocator.free(quotient_text);
    const remainder_text = try remainder.formatBase10Alloc(std.testing.allocator);
    defer std.testing.allocator.free(remainder_text);
    try std.testing.expectEqualStrings("127275040218913071032200585453735522462899325442", quotient_text);
    try std.testing.expectEqualStrings("16", remainder_text);
    var neg_seven = try libs.bignum.BigInt.fromInt(std.testing.allocator, -7);
    defer neg_seven.deinit();
    var three = try libs.bignum.BigInt.fromInt(std.testing.allocator, 3);
    defer three.deinit();
    var neg_q = try neg_seven.div(three);
    defer neg_q.deinit();
    var neg_r = try neg_seven.rem(three);
    defer neg_r.deinit();
    const neg_q_text = try neg_q.formatBase10Alloc(std.testing.allocator);
    defer std.testing.allocator.free(neg_q_text);
    const neg_r_text = try neg_r.formatBase10Alloc(std.testing.allocator);
    defer std.testing.allocator.free(neg_r_text);
    try std.testing.expectEqualStrings("-2", neg_q_text);
    try std.testing.expectEqualStrings("-1", neg_r_text);
    var compiled = try libs.quickjs_regexp.compile(std.testing.allocator, "abc", "i");
    defer compiled.deinit(std.testing.allocator);
    const status = try libs.regexp.exec(std.testing.allocator, compiled.bytecode, .{ .latin1 = "xxAbCy" }, 0);
    try std.testing.expect(status.result == .match);
    try std.testing.expectEqual(@as(usize, 2), status.match.start);
    try std.testing.expectEqual(@as(usize, 5), status.match.end);
}
