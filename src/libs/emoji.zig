pub const StringUnits = union(enum) {
    latin1: []const u8,
    utf16: []const u16,

    fn len(self: StringUnits) usize {
        return switch (self) {
            .latin1 => |bytes| bytes.len,
            .utf16 => |units| units.len,
        };
    }
};

pub const MatchSpan = struct {
    index: usize,
    len: usize,
};

pub fn findRgiEmojiMatch(units: StringUnits, start_index: usize, sticky: bool) ?MatchSpan {
    var index = start_index;
    while (index < units.len()) {
        if (rgiEmojiSequenceEndAt(units, index)) |end| {
            return .{ .index = index, .len = end - index };
        }
        if (sticky) break;
        index = nextCodePointIndex(units, index);
    }
    return null;
}

pub fn rgiEmojiSequencesCover(units: StringUnits) bool {
    if (units.len() == 0) return false;
    var index: usize = 0;
    while (index < units.len()) {
        const end = rgiEmojiSequenceEndAt(units, index) orelse return false;
        if (end <= index) return false;
        index = end;
    }
    return true;
}

fn rgiEmojiSequenceEndAt(units: StringUnits, start: usize) ?usize {
    const first = codePointAt(units, start) orelse return null;
    if (isRegionalIndicatorCodePoint(first.code_point)) {
        const second = codePointAt(units, first.end) orelse return null;
        if (isRegionalIndicatorCodePoint(second.code_point)) return second.end;
        return null;
    }
    if (isKeycapStartCodePoint(first.code_point)) {
        if (tryConsumeKeycapSequence(units, first.end)) |end| return end;
    }
    if (first.code_point == 0x01f3f4) {
        if (tryConsumeEmojiTagSequence(units, first.end)) |end| return end;
    }
    var index = tryConsumeEmojiCore(units, start) orelse return null;
    while (true) {
        const joiner = codePointAt(units, index) orelse break;
        if (joiner.code_point != 0x200d) break;
        const next = tryConsumeEmojiCore(units, joiner.end) orelse break;
        index = next;
    }
    return index;
}

fn tryConsumeEmojiCore(units: StringUnits, start: usize) ?usize {
    const first = codePointAt(units, start) orelse return null;
    if (isRegionalIndicatorCodePoint(first.code_point)) {
        const second = codePointAt(units, first.end) orelse return null;
        if (isRegionalIndicatorCodePoint(second.code_point)) return second.end;
        return null;
    }
    if (isKeycapStartCodePoint(first.code_point)) {
        if (tryConsumeKeycapSequence(units, first.end)) |end| return end;
    }
    if (first.code_point == 0x01f3f4) {
        if (tryConsumeEmojiTagSequence(units, first.end)) |end| return end;
    }
    if (!isRgiEmojiCoreCodePoint(first.code_point)) return null;
    var index = first.end;
    const variation = codePointAt(units, index);
    const emoji_presentation = isEmojiPresentationCodePoint(first.code_point);
    if (variation != null and variation.?.code_point == 0xfe0f) {
        index = variation.?.end;
    } else if (!emoji_presentation) {
        return null;
    }
    const modifier = codePointAt(units, index);
    if (modifier != null and isEmojiModifierCodePoint(modifier.?.code_point) and isEmojiModifierBaseCodePoint(first.code_point)) {
        index = modifier.?.end;
    }
    return index;
}

fn tryConsumeKeycapSequence(units: StringUnits, after_first: usize) ?usize {
    var index = after_first;
    const variation = codePointAt(units, index);
    if (variation != null and variation.?.code_point == 0xfe0f) index = variation.?.end;
    const combining = codePointAt(units, index) orelse return null;
    return if (combining.code_point == 0x20e3) combining.end else null;
}

fn tryConsumeEmojiTagSequence(units: StringUnits, after_flag: usize) ?usize {
    var index = after_flag;
    var tag_count: usize = 0;
    while (true) {
        const tag = codePointAt(units, index) orelse return null;
        if (tag.code_point == 0xe007f) return if (tag_count > 0) tag.end else null;
        if (tag.code_point < 0xe0020 or tag.code_point > 0xe007e) return null;
        tag_count += 1;
        index = tag.end;
    }
}

const CodePointSpan = struct {
    code_point: u21,
    end: usize,
};

fn codePointAt(units: StringUnits, index: usize) ?CodePointSpan {
    switch (units) {
        .latin1 => |bytes| {
            if (index >= bytes.len) return null;
            return .{ .code_point = bytes[index], .end = index + 1 };
        },
        .utf16 => |items| {
            if (index >= items.len) return null;
            var next = index;
            const code_point = readUtf16CodePoint(items, &next);
            return .{ .code_point = code_point, .end = next };
        },
    }
}

fn nextCodePointIndex(units: StringUnits, index: usize) usize {
    return if (codePointAt(units, index)) |span| span.end else units.len();
}

fn readUtf16CodePoint(units: []const u16, index: *usize) u21 {
    const high = units[index.*];
    if (high >= 0xd800 and high <= 0xdbff and index.* + 1 < units.len) {
        const low = units[index.* + 1];
        if (low >= 0xdc00 and low <= 0xdfff) {
            index.* += 2;
            return @intCast(0x10000 + ((@as(u32, high) - 0xd800) << 10) + (@as(u32, low) - 0xdc00));
        }
    }
    index.* += 1;
    return @intCast(high);
}

fn isRgiEmojiCoreCodePoint(code_point: u21) bool {
    if (isEmojiModifierCodePoint(code_point) or
        isRegionalIndicatorCodePoint(code_point) or
        isEmojiComponentCodePoint(code_point) or
        code_point == 0x200d or
        code_point == 0x20e3 or
        code_point == 0xfe0f)
    {
        return false;
    }
    return isEmojiCodePoint(code_point);
}

fn isRegionalIndicatorCodePoint(code_point: u21) bool {
    return code_point >= 0x01f1e6 and code_point <= 0x01f1ff;
}

fn isEmojiModifierCodePoint(code_point: u21) bool {
    return code_point >= 0x01f3fb and code_point <= 0x01f3ff;
}

fn isKeycapStartCodePoint(code_point: u21) bool {
    return (code_point >= '0' and code_point <= '9') or code_point == '#' or code_point == '*';
}

pub fn isEmojiComponentCodePoint(code_point: u21) bool {
    return code_point == 0x000023 or
        code_point == 0x00002a or
        code_point == 0x00200d or
        code_point == 0x0020e3 or
        code_point == 0x00fe0f or
        (code_point >= 0x000030 and code_point <= 0x000039) or
        (code_point >= 0x01f1e6 and code_point <= 0x01f1ff) or
        (code_point >= 0x01f3fb and code_point <= 0x01f3ff) or
        (code_point >= 0x01f9b0 and code_point <= 0x01f9b3) or
        (code_point >= 0x0e0020 and code_point <= 0x0e007f);
}

pub fn isEmojiCodePoint(code_point: u21) bool {
    const singles = [_]u21{
        0x000023, 0x00002a, 0x0000a9, 0x0000ae, 0x00203c, 0x002049, 0x002122, 0x002139,
        0x002328, 0x0023cf, 0x0024c2, 0x0025b6, 0x0025c0, 0x00260e, 0x002611, 0x002618,
        0x00261d, 0x002620, 0x002626, 0x00262a, 0x002640, 0x002642, 0x002663, 0x002668,
        0x00267b, 0x002699, 0x0026a7, 0x0026c8, 0x0026d1, 0x0026fd, 0x002702, 0x002705,
        0x00270f, 0x002712, 0x002714, 0x002716, 0x00271d, 0x002721, 0x002728, 0x002744,
        0x002747, 0x00274c, 0x00274e, 0x002757, 0x0027a1, 0x0027b0, 0x0027bf, 0x002b50,
        0x002b55, 0x003030, 0x00303d, 0x003297, 0x003299, 0x01f004, 0x01f0cf, 0x01f18e,
        0x01f21a, 0x01f22f, 0x01f587, 0x01f590, 0x01f5a8, 0x01f5bc, 0x01f5e1, 0x01f5e3,
        0x01f5e8, 0x01f5ef, 0x01f5f3, 0x01f6e9, 0x01f6f0, 0x01f7f0, 0x01fac8,
    };
    const ranges = [_][2]u21{
        .{ 0x000030, 0x000039 },
        .{ 0x002194, 0x002199 },
        .{ 0x0021a9, 0x0021aa },
        .{ 0x00231a, 0x00231b },
        .{ 0x0023e9, 0x0023f3 },
        .{ 0x0023f8, 0x0023fa },
        .{ 0x0025aa, 0x0025ab },
        .{ 0x0025fb, 0x0025fe },
        .{ 0x002600, 0x002604 },
        .{ 0x002614, 0x002615 },
        .{ 0x002622, 0x002623 },
        .{ 0x00262e, 0x00262f },
        .{ 0x002638, 0x00263a },
        .{ 0x002648, 0x002653 },
        .{ 0x00265f, 0x002660 },
        .{ 0x002665, 0x002666 },
        .{ 0x00267e, 0x00267f },
        .{ 0x002692, 0x002697 },
        .{ 0x00269b, 0x00269c },
        .{ 0x0026a0, 0x0026a1 },
        .{ 0x0026aa, 0x0026ab },
        .{ 0x0026b0, 0x0026b1 },
        .{ 0x0026bd, 0x0026be },
        .{ 0x0026c4, 0x0026c5 },
        .{ 0x0026ce, 0x0026cf },
        .{ 0x0026d3, 0x0026d4 },
        .{ 0x0026e9, 0x0026ea },
        .{ 0x0026f0, 0x0026f5 },
        .{ 0x0026f7, 0x0026fa },
        .{ 0x002708, 0x00270d },
        .{ 0x002733, 0x002734 },
        .{ 0x002753, 0x002755 },
        .{ 0x002763, 0x002764 },
        .{ 0x002795, 0x002797 },
        .{ 0x002934, 0x002935 },
        .{ 0x002b05, 0x002b07 },
        .{ 0x002b1b, 0x002b1c },
        .{ 0x01f170, 0x01f171 },
        .{ 0x01f17e, 0x01f17f },
        .{ 0x01f191, 0x01f19a },
        .{ 0x01f1e6, 0x01f1ff },
        .{ 0x01f201, 0x01f202 },
        .{ 0x01f232, 0x01f23a },
        .{ 0x01f250, 0x01f251 },
        .{ 0x01f300, 0x01f321 },
        .{ 0x01f324, 0x01f393 },
        .{ 0x01f396, 0x01f397 },
        .{ 0x01f399, 0x01f39b },
        .{ 0x01f39e, 0x01f3f0 },
        .{ 0x01f3f3, 0x01f3f5 },
        .{ 0x01f3f7, 0x01f4fd },
        .{ 0x01f4ff, 0x01f53d },
        .{ 0x01f549, 0x01f54e },
        .{ 0x01f550, 0x01f567 },
        .{ 0x01f56f, 0x01f570 },
        .{ 0x01f573, 0x01f57a },
        .{ 0x01f58a, 0x01f58d },
        .{ 0x01f595, 0x01f596 },
        .{ 0x01f5a4, 0x01f5a5 },
        .{ 0x01f5b1, 0x01f5b2 },
        .{ 0x01f5c2, 0x01f5c4 },
        .{ 0x01f5d1, 0x01f5d3 },
        .{ 0x01f5dc, 0x01f5de },
        .{ 0x01f5fa, 0x01f64f },
        .{ 0x01f680, 0x01f6c5 },
        .{ 0x01f6cb, 0x01f6d2 },
        .{ 0x01f6d5, 0x01f6d8 },
        .{ 0x01f6dc, 0x01f6e5 },
        .{ 0x01f6eb, 0x01f6ec },
        .{ 0x01f6f3, 0x01f6fc },
        .{ 0x01f7e0, 0x01f7eb },
        .{ 0x01f90c, 0x01f93a },
        .{ 0x01f93c, 0x01f945 },
        .{ 0x01f947, 0x01f9ff },
        .{ 0x01fa70, 0x01fa7c },
        .{ 0x01fa80, 0x01fa8a },
        .{ 0x01fa8e, 0x01fac6 },
        .{ 0x01facd, 0x01fadc },
        .{ 0x01fadf, 0x01faea },
        .{ 0x01faef, 0x01faf8 },
    };
    return codePointInSet(code_point, &singles, &ranges);
}

pub fn isEmojiModifierBaseCodePoint(code_point: u21) bool {
    return code_point == 0x00261d or
        code_point == 0x0026f9 or
        code_point == 0x01f385 or
        code_point == 0x01f3c7 or
        code_point == 0x01f47c or
        code_point == 0x01f48f or
        code_point == 0x01f491 or
        code_point == 0x01f4aa or
        code_point == 0x01f57a or
        code_point == 0x01f590 or
        code_point == 0x01f6a3 or
        code_point == 0x01f6c0 or
        code_point == 0x01f6cc or
        code_point == 0x01f90c or
        code_point == 0x01f90f or
        code_point == 0x01f926 or
        code_point == 0x01f977 or
        code_point == 0x01f9bb or
        (code_point >= 0x00270a and code_point <= 0x00270d) or
        (code_point >= 0x01f3c2 and code_point <= 0x01f3c4) or
        (code_point >= 0x01f3ca and code_point <= 0x01f3cc) or
        (code_point >= 0x01f442 and code_point <= 0x01f443) or
        (code_point >= 0x01f446 and code_point <= 0x01f450) or
        (code_point >= 0x01f466 and code_point <= 0x01f478) or
        (code_point >= 0x01f481 and code_point <= 0x01f483) or
        (code_point >= 0x01f485 and code_point <= 0x01f487) or
        (code_point >= 0x01f574 and code_point <= 0x01f575) or
        (code_point >= 0x01f595 and code_point <= 0x01f596) or
        (code_point >= 0x01f645 and code_point <= 0x01f647) or
        (code_point >= 0x01f64b and code_point <= 0x01f64f) or
        (code_point >= 0x01f6b4 and code_point <= 0x01f6b6) or
        (code_point >= 0x01f918 and code_point <= 0x01f91f) or
        (code_point >= 0x01f930 and code_point <= 0x01f939) or
        (code_point >= 0x01f93c and code_point <= 0x01f93e) or
        (code_point >= 0x01f9b5 and code_point <= 0x01f9b6) or
        (code_point >= 0x01f9b8 and code_point <= 0x01f9b9) or
        (code_point >= 0x01f9cd and code_point <= 0x01f9cf) or
        (code_point >= 0x01f9d1 and code_point <= 0x01f9dd) or
        (code_point >= 0x01fac3 and code_point <= 0x01fac5) or
        (code_point >= 0x01faf0 and code_point <= 0x01faf8);
}

pub fn isEmojiPresentationCodePoint(code_point: u21) bool {
    return code_point == 0x0023f0 or
        code_point == 0x0023f3 or
        code_point == 0x00267f or
        code_point == 0x002693 or
        code_point == 0x0026a1 or
        code_point == 0x0026ce or
        code_point == 0x0026d4 or
        code_point == 0x0026ea or
        code_point == 0x0026f5 or
        code_point == 0x0026fa or
        code_point == 0x0026fd or
        code_point == 0x002705 or
        code_point == 0x002728 or
        code_point == 0x00274c or
        code_point == 0x00274e or
        code_point == 0x002757 or
        code_point == 0x0027b0 or
        code_point == 0x0027bf or
        code_point == 0x002b50 or
        code_point == 0x002b55 or
        code_point == 0x01f004 or
        code_point == 0x01f0cf or
        code_point == 0x01f18e or
        code_point == 0x01f201 or
        code_point == 0x01f21a or
        code_point == 0x01f22f or
        code_point == 0x01f3f4 or
        code_point == 0x01f440 or
        code_point == 0x01f57a or
        code_point == 0x01f5a4 or
        code_point == 0x01f6cc or
        code_point == 0x01f7f0 or
        code_point == 0x01fac8 or
        (code_point >= 0x00231a and code_point <= 0x00231b) or
        (code_point >= 0x0023e9 and code_point <= 0x0023ec) or
        (code_point >= 0x0025fd and code_point <= 0x0025fe) or
        (code_point >= 0x002614 and code_point <= 0x002615) or
        (code_point >= 0x002648 and code_point <= 0x002653) or
        (code_point >= 0x0026aa and code_point <= 0x0026ab) or
        (code_point >= 0x0026bd and code_point <= 0x0026be) or
        (code_point >= 0x0026c4 and code_point <= 0x0026c5) or
        (code_point >= 0x0026f2 and code_point <= 0x0026f3) or
        (code_point >= 0x00270a and code_point <= 0x00270b) or
        (code_point >= 0x002753 and code_point <= 0x002755) or
        (code_point >= 0x002795 and code_point <= 0x002797) or
        (code_point >= 0x002b1b and code_point <= 0x002b1c) or
        (code_point >= 0x01f191 and code_point <= 0x01f19a) or
        (code_point >= 0x01f1e6 and code_point <= 0x01f1ff) or
        (code_point >= 0x01f232 and code_point <= 0x01f236) or
        (code_point >= 0x01f238 and code_point <= 0x01f23a) or
        (code_point >= 0x01f250 and code_point <= 0x01f251) or
        (code_point >= 0x01f300 and code_point <= 0x01f320) or
        (code_point >= 0x01f32d and code_point <= 0x01f335) or
        (code_point >= 0x01f337 and code_point <= 0x01f37c) or
        (code_point >= 0x01f37e and code_point <= 0x01f393) or
        (code_point >= 0x01f3a0 and code_point <= 0x01f3ca) or
        (code_point >= 0x01f3cf and code_point <= 0x01f3d3) or
        (code_point >= 0x01f3e0 and code_point <= 0x01f3f0) or
        (code_point >= 0x01f3f8 and code_point <= 0x01f43e) or
        (code_point >= 0x01f442 and code_point <= 0x01f4fc) or
        (code_point >= 0x01f4ff and code_point <= 0x01f53d) or
        (code_point >= 0x01f54b and code_point <= 0x01f54e) or
        (code_point >= 0x01f550 and code_point <= 0x01f567) or
        (code_point >= 0x01f595 and code_point <= 0x01f596) or
        (code_point >= 0x01f5fb and code_point <= 0x01f64f) or
        (code_point >= 0x01f680 and code_point <= 0x01f6c5) or
        (code_point >= 0x01f6d0 and code_point <= 0x01f6d2) or
        (code_point >= 0x01f6d5 and code_point <= 0x01f6d8) or
        (code_point >= 0x01f6dc and code_point <= 0x01f6df) or
        (code_point >= 0x01f6eb and code_point <= 0x01f6ec) or
        (code_point >= 0x01f6f4 and code_point <= 0x01f6fc) or
        (code_point >= 0x01f7e0 and code_point <= 0x01f7eb) or
        (code_point >= 0x01f90c and code_point <= 0x01f93a) or
        (code_point >= 0x01f93c and code_point <= 0x01f945) or
        (code_point >= 0x01f947 and code_point <= 0x01f9ff) or
        (code_point >= 0x01fa70 and code_point <= 0x01fa7c) or
        (code_point >= 0x01fa80 and code_point <= 0x01fa8a) or
        (code_point >= 0x01fa8e and code_point <= 0x01fac6) or
        (code_point >= 0x01facd and code_point <= 0x01fadc) or
        (code_point >= 0x01fadf and code_point <= 0x01faea) or
        (code_point >= 0x01faef and code_point <= 0x01faf8);
}

fn codePointInSet(code_point: u21, singles: []const u21, ranges: []const [2]u21) bool {
    for (singles) |single| {
        if (code_point == single) return true;
    }
    for (ranges) |range| {
        if (code_point >= range[0] and code_point <= range[1]) return true;
    }
    return false;
}

test "emoji functionality" {
    const std = @import("std");

    try std.testing.expect(isEmojiCodePoint(0x01f600));
    try std.testing.expect(isEmojiPresentationCodePoint(0x01f600));
    try std.testing.expect(!isEmojiPresentationCodePoint(0x260e));

    const flag = [_]u16{ 0xd83c, 0xdde8, 0xd83c, 0xddf6 };
    const flag_match = findRgiEmojiMatch(.{ .utf16 = &flag }, 0, false).?;
    try std.testing.expectEqual(@as(usize, 0), flag_match.index);
    try std.testing.expectEqual(@as(usize, flag.len), flag_match.len);
    try std.testing.expect(rgiEmojiSequencesCover(.{ .utf16 = &flag }));

    const phone_text = [_]u16{0x260e};
    try std.testing.expect(!rgiEmojiSequencesCover(.{ .utf16 = &phone_text }));
    const phone_emoji = [_]u16{ 0x260e, 0xfe0f };
    try std.testing.expect(rgiEmojiSequencesCover(.{ .utf16 = &phone_emoji }));

    const prefixed = [_]u16{ 'a', 0xd83c, 0xdde8, 0xd83c, 0xddf6 };
    const prefixed_match = findRgiEmojiMatch(.{ .utf16 = &prefixed }, 0, false).?;
    try std.testing.expectEqual(@as(usize, 1), prefixed_match.index);
    try std.testing.expectEqual(@as(usize, 4), prefixed_match.len);
    try std.testing.expect(findRgiEmojiMatch(.{ .utf16 = &prefixed }, 0, true) == null);
}
