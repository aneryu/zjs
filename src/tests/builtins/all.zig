const std = @import("std");
const engine = @import("quickjs_zig_engine");

const builtins = engine.builtins;
const core = engine.core;
const exec = engine.exec;
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

    try std.testing.expect(libs.unicode_tables.isEmojiCodePoint(0x01f600));
    try std.testing.expect(libs.unicode_tables.isEmojiPresentationCodePoint(0x01f600));
    try std.testing.expect(!libs.unicode_tables.isEmojiPresentationCodePoint(0x260e));

    const flag = [_]u16{ 0xd83c, 0xdde8, 0xd83c, 0xddf6 };
    const flag_match = libs.unicode_tables.findRgiEmojiMatch(.{ .utf16 = &flag }, 0, false).?;
    try std.testing.expectEqual(@as(usize, 0), flag_match.index);
    try std.testing.expectEqual(@as(usize, flag.len), flag_match.len);
    try std.testing.expect(libs.unicode_tables.rgiEmojiSequencesCover(.{ .utf16 = &flag }));

    const phone_text = [_]u16{0x260e};
    try std.testing.expect(!libs.unicode_tables.rgiEmojiSequencesCover(.{ .utf16 = &phone_text }));
    const phone_emoji = [_]u16{ 0x260e, 0xfe0f };
    try std.testing.expect(libs.unicode_tables.rgiEmojiSequencesCover(.{ .utf16 = &phone_emoji }));

    const prefixed = [_]u16{ 'a', 0xd83c, 0xdde8, 0xd83c, 0xddf6 };
    const prefixed_match = libs.unicode_tables.findRgiEmojiMatch(.{ .utf16 = &prefixed }, 0, false).?;
    try std.testing.expectEqual(@as(usize, 1), prefixed_match.index);
    try std.testing.expectEqual(@as(usize, 4), prefixed_match.len);
    try std.testing.expect(libs.unicode_tables.findRgiEmojiMatch(.{ .utf16 = &prefixed }, 0, true) == null);

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

    const program = try libs.regexp.compile("abc", .{ .ignore_case = true });
    const match = program.exec("xxAbCy").?;
    try std.testing.expectEqual(@as(usize, 2), match.start);
    try std.testing.expectEqual(@as(usize, 5), match.end);
}

test "intrinsic bootstrap registers global builtin domains through object properties" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var intrinsics = try builtins.Intrinsics.init(rt);
    defer intrinsics.deinit(rt);

    for (builtins.domains) |name| {
        const atom_id = try rt.internAtom(name);
        defer rt.atoms.free(atom_id);
        try std.testing.expect(intrinsics.global.hasOwnProperty(atom_id));
        const desc = intrinsics.global.getOwnProperty(atom_id).?;
        defer desc.destroy(rt);
        try std.testing.expectEqual(true, desc.writable.?);
        try std.testing.expectEqual(false, desc.enumerable.?);
        try std.testing.expectEqual(true, desc.configurable.?);
    }

    const map_atom = try rt.internAtom("Map");
    defer rt.atoms.free(map_atom);
    const map_ctor = intrinsics.global.getProperty(map_atom);
    defer map_ctor.free(rt);
    try expectObjectClass(map_ctor, core.class.ids.c_function);
    const map_ctor_object: *core.Object = @fieldParentPtr("header", map_ctor.refHeader().?);
    const prototype_atom = try rt.internAtom("prototype");
    defer rt.atoms.free(prototype_atom);
    const prototype_desc = map_ctor_object.getOwnProperty(prototype_atom).?;
    defer prototype_desc.destroy(rt);
    try std.testing.expectEqual(false, prototype_desc.writable.?);
    try std.testing.expectEqual(false, prototype_desc.enumerable.?);
    try std.testing.expectEqual(false, prototype_desc.configurable.?);
    try expectObjectClass(prototype_desc.value, core.class.ids.object);
    const map_proto: *core.Object = @fieldParentPtr("header", prototype_desc.value.refHeader().?);
    const set_atom = try rt.internAtom("set");
    defer rt.atoms.free(set_atom);
    const set_desc = map_proto.getOwnProperty(set_atom).?;
    defer set_desc.destroy(rt);
    try std.testing.expectEqual(true, set_desc.writable.?);
    try std.testing.expectEqual(false, set_desc.enumerable.?);
    try std.testing.expectEqual(true, set_desc.configurable.?);
    try expectObjectClass(set_desc.value, core.class.ids.c_function);
}

test "host global bootstrap installs and tears down builtin plus host domains" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const global = try core.Object.create(rt, core.class.ids.object, null);
    global.is_global = true;
    defer global.value().free(rt);

    try exec.call.installHostGlobals(rt, global);
}

test "engine eval host globals and throw intrinsic tear down cleanly" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    const value = try js.evalWithOutput("print(1);", &output);
    defer value.free(js.runtime);

    try std.testing.expect(value.isUndefined());
    try std.testing.expectEqualStrings("1\n", output.buffered());
}

test "object keys values entries literal sameValue + function" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const obj = try builtins.object.create(rt, null);
    defer obj.value().free(rt);
    const key = try rt.internAtom("x");
    defer rt.atoms.free(key);
    try obj.defineOwnProperty(rt, key, core.Descriptor.data(core.Value.int32(1), true, true, true));
    const keys = try builtins.object.keys(rt, obj);
    defer core.Object.freeKeys(rt, keys);
    try std.testing.expectEqual(@as(usize, 1), keys.len);
    const object_keys = try builtins.object.ownEntriesArray(rt, obj.value(), .keys);
    defer object_keys.free(rt);
    try expectObjectClass(object_keys, core.class.ids.array);
    const object_keys_obj: *core.Object = @fieldParentPtr("header", object_keys.refHeader().?);
    try expectStringValue(rt, "x", object_keys_obj.getProperty(core.atom.atomFromUInt32(0)));
    const object_values = try builtins.object.ownEntriesArray(rt, obj.value(), .values);
    defer object_values.free(rt);
    const object_values_obj: *core.Object = @fieldParentPtr("header", object_values.refHeader().?);
    const object_first_value = object_values_obj.getProperty(core.atom.atomFromUInt32(0));
    defer object_first_value.free(rt);
    try std.testing.expectEqual(@as(?i32, 1), object_first_value.asInt32());
    const object_entries = try builtins.object.ownEntriesArray(rt, obj.value(), .entries);
    defer object_entries.free(rt);
    const object_entries_obj: *core.Object = @fieldParentPtr("header", object_entries.refHeader().?);
    const object_entry = object_entries_obj.getProperty(core.atom.atomFromUInt32(0));
    defer object_entry.free(rt);
    try expectObjectClass(object_entry, core.class.ids.array);
    const object_entry_obj: *core.Object = @fieldParentPtr("header", object_entry.refHeader().?);
    try expectStringValue(rt, "x", object_entry_obj.getProperty(core.atom.atomFromUInt32(0)));
    const object_entry_value = object_entry_obj.getProperty(core.atom.atomFromUInt32(1));
    defer object_entry_value.free(rt);
    try std.testing.expectEqual(@as(?i32, 1), object_entry_value.asInt32());
    const literal_a = try rt.internAtom("a");
    defer rt.atoms.free(literal_a);
    const literal_b = try rt.internAtom("b");
    defer rt.atoms.free(literal_b);
    const literal_names = [_]core.Atom{ literal_a, literal_b };
    const literal_values = [_]core.Value{ core.Value.int32(10), core.Value.int32(20) };
    const literal = try builtins.object.literal(rt, literal_names[0..], literal_values[0..]);
    defer literal.free(rt);
    try expectObjectClass(literal, core.class.ids.object);
    try expectIntProperty(rt, literal, "a", 10);
    try expectIntProperty(rt, literal, "b", 20);
    try std.testing.expect(builtins.object.sameValue(core.Value.float64(std.math.nan(f64)), core.Value.float64(std.math.nan(f64))));
    try std.testing.expect(!builtins.object.sameValue(core.Value.float64(0.0), core.Value.float64(-0.0)));
    const object_same_string_a_obj = try core.string.String.createUtf8(rt, "same");
    const object_same_string_a = object_same_string_a_obj.value();
    defer object_same_string_a.free(rt);
    const object_same_string_b_obj = try core.string.String.createUtf8(rt, "same");
    const object_same_string_b = object_same_string_b_obj.value();
    defer object_same_string_b.free(rt);
    try std.testing.expect(builtins.object.sameValue(object_same_string_a, object_same_string_b));
    try std.testing.expectError(error.TypeError, builtins.object.ownEntriesArray(rt, core.Value.int32(1), .keys));

    const this_value = core.Value.int32(7);
    try std.testing.expectEqual(@as(?i32, 7), builtins.function.applyReturnThis(this_value).asInt32());
}

test "array construct join filter reduce some every indexOf includes at slice splice" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    try std.testing.expect(builtins.array.isArrayIndex("42"));
    try std.testing.expectEqual(@as(u32, 43), builtins.array.lengthAfterSet(42, 1));
    const array_values = [_]core.Value{ core.Value.int32(1), core.Value.int32(2), core.Value.int32(3), core.Value.int32(4) };
    const array_value = try builtins.array.construct(rt, array_values[0..]);
    defer array_value.free(rt);
    try expectObjectClass(array_value, core.class.ids.array);
    try expectArrayLength(array_value, 4);
    try expectIntIndex(rt, array_value, 0, 1);
    try expectIntIndex(rt, array_value, 3, 4);
    const pipe_separator_obj = try core.string.String.createUtf8(rt, "|");
    const pipe_separator = pipe_separator_obj.value();
    defer pipe_separator.free(rt);
    try expectStringValue(rt, "1|2|3|4", try builtins.array.join(rt, array_value, pipe_separator));
    const comma_separator_obj = try core.string.String.createUtf8(rt, ",");
    const comma_separator = comma_separator_obj.value();
    defer comma_separator.free(rt);
    const filtered_array = try builtins.array.methodCall(rt, array_value, 1, &.{});
    defer filtered_array.free(rt);
    try expectStringValue(rt, "2,4", try builtins.array.join(rt, filtered_array, comma_separator));
    const reduced_array = try builtins.array.methodCall(rt, array_value, 2, &.{});
    defer reduced_array.free(rt);
    try std.testing.expectEqual(@as(?i32, 10), reduced_array.asInt32());
    const some_even_array = try builtins.array.methodCall(rt, array_value, 4, &.{});
    defer some_even_array.free(rt);
    try std.testing.expectEqual(@as(?bool, true), some_even_array.asBool());
    const every_positive_array = try builtins.array.methodCall(rt, array_value, 5, &.{});
    defer every_positive_array.free(rt);
    try std.testing.expectEqual(@as(?bool, true), every_positive_array.asBool());
    const three_arg = [_]core.Value{core.Value.int32(3)};
    const first_index = try builtins.array.methodCall(rt, array_value, 6, three_arg[0..]);
    defer first_index.free(rt);
    try std.testing.expectEqual(@as(?i32, 2), first_index.asInt32());
    const includes_three = try builtins.array.methodCall(rt, array_value, 7, three_arg[0..]);
    defer includes_three.free(rt);
    try std.testing.expectEqual(@as(?bool, true), includes_three.asBool());
    const last_index = try builtins.array.methodCall(rt, array_value, 8, three_arg[0..]);
    defer last_index.free(rt);
    try std.testing.expectEqual(@as(?i32, 2), last_index.asInt32());
    const at_last_arg = [_]core.Value{core.Value.int32(-1)};
    const last_item = try builtins.array.methodCall(rt, array_value, 9, at_last_arg[0..]);
    defer last_item.free(rt);
    try std.testing.expectEqual(@as(?i32, 4), last_item.asInt32());
    const slice_arg = [_]core.Value{core.Value.int32(-2)};
    const sliced_array = try builtins.array.methodCall(rt, array_value, 10, slice_arg[0..]);
    defer sliced_array.free(rt);
    try expectStringValue(rt, "3,4", try builtins.array.join(rt, sliced_array, comma_separator));
    const splice_values = [_]core.Value{ core.Value.int32(1), core.Value.int32(2), core.Value.int32(3) };
    const splice_target = try builtins.array.construct(rt, splice_values[0..]);
    defer splice_target.free(rt);
    const splice_args = [_]core.Value{ core.Value.int32(1), core.Value.int32(1), core.Value.int32(9), core.Value.int32(8) };
    const removed_array = try builtins.array.methodCall(rt, splice_target, 11, splice_args[0..]);
    defer removed_array.free(rt);
    try expectStringValue(rt, "2", try builtins.array.join(rt, removed_array, comma_separator));
    try expectStringValue(rt, "1,9,8,3", try builtins.array.join(rt, splice_target, comma_separator));
    try std.testing.expectError(error.TypeError, builtins.array.methodCall(rt, core.Value.int32(1), 1, &.{}));
    try std.testing.expectError(error.TypeError, builtins.array.methodCall(rt, array_value, 3, &.{}));
}

test "Array sort OOM releases pending sort entry value" {
    var saw_oom = false;
    var saw_success = false;
    const sort_method = builtins.array.decodePrototypeMethodId(@intFromEnum(builtins.array.PrototypeMethod.sort)).?;

    var fail_offset: usize = 0;
    while (fail_offset < 80) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.Runtime.create(failing.allocator());

        const array = try core.Object.createArray(rt, null);
        const array_value = array.value();
        const retained = try core.Object.create(rt, core.class.ids.object, null);
        try array.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(retained.value(), true, true, true));
        array.length = 1;
        const retained_refs = retained.header.rc;

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = builtins.array.methodCall(rt, array_value, sort_method, &.{});
        failing.fail_index = std.math.maxInt(usize);

        const expect_exact_refs = if (result) |value| exact: {
            saw_success = true;
            value.free(rt);
            break :exact true;
        } else |err| switch (err) {
            error.OutOfMemory => exact: {
                saw_oom = true;
                break :exact false;
            },
            else => |unexpected| {
                array_value.free(rt);
                retained.value().free(rt);
                rt.destroy();
                return unexpected;
            },
        };

        const observed_refs = retained.header.rc;
        array_value.free(rt);
        retained.value().free(rt);
        rt.destroy();

        if (expect_exact_refs) {
            try std.testing.expectEqual(retained_refs, observed_refs);
        } else {
            try std.testing.expect(observed_refs <= retained_refs);
        }
        if (saw_oom and saw_success) return;
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

test "string construct charAt substring toUpperCase indexOf includes trim fromCharCode" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    var upper: [8]u8 = undefined;
    try std.testing.expectEqualStrings("ABC", builtins.string.toUpperAscii(&upper, "abc"));
    try std.testing.expectEqualStrings("b", builtins.string.charAt("abc", 1));
    const string_input_obj = try core.string.String.createUtf8(rt, "Hello World");
    const string_input = string_input_obj.value();
    defer string_input.free(rt);
    const string_object = try builtins.string.construct(rt, &.{string_input});
    defer string_object.free(rt);
    try expectObjectClass(string_object, core.class.ids.string);
    try expectIntProperty(rt, string_object, "length", 11);
    try expectStringValue(rt, "W", try builtins.string.charAtValue(rt, string_object, core.Value.int32(6)));
    try expectStringValue(rt, "Hello", try builtins.string.methodCall(rt, string_object, 1, &.{ core.Value.int32(0), core.Value.int32(5) }));
    try expectStringValue(rt, "HELLO WORLD", try builtins.string.methodCall(rt, string_object, 2, &.{}));
    try expectStringValue(rt, "hello world", try builtins.string.methodCall(rt, string_object, 3, &.{}));
    try expectStringValue(rt, "<big>Hello World</big>", try builtins.string.methodCall(rt, string_object, 12, &.{}));
    const html_attr_obj = try core.string.String.createUtf8(rt, "a\"b");
    const html_attr = html_attr_obj.value();
    defer html_attr.free(rt);
    try expectStringValue(rt, "<a name=\"a&quot;b\">Hello World</a>", try builtins.string.methodCall(rt, string_object, 11, &.{html_attr}));
    const string_search_obj = try core.string.String.createUtf8(rt, "World");
    const string_search = string_search_obj.value();
    defer string_search.free(rt);
    const string_search_args = [_]core.Value{string_search};
    const string_index = try builtins.string.methodCall(rt, string_object, 4, string_search_args[0..]);
    defer string_index.free(rt);
    try std.testing.expectEqual(@as(?i32, 6), string_index.asInt32());
    const string_includes = try builtins.string.methodCall(rt, string_object, 5, string_search_args[0..]);
    defer string_includes.free(rt);
    try std.testing.expectEqual(@as(?bool, true), string_includes.asBool());
    const string_starts_obj = try core.string.String.createUtf8(rt, "Hello");
    const string_starts = string_starts_obj.value();
    defer string_starts.free(rt);
    const string_starts_args = [_]core.Value{string_starts};
    const string_starts_result = try builtins.string.methodCall(rt, string_object, 6, string_starts_args[0..]);
    defer string_starts_result.free(rt);
    try std.testing.expectEqual(@as(?bool, true), string_starts_result.asBool());
    const string_ends_result = try builtins.string.methodCall(rt, string_object, 7, string_search_args[0..]);
    defer string_ends_result.free(rt);
    try std.testing.expectEqual(@as(?bool, true), string_ends_result.asBool());
    const string_trim_obj = try core.string.String.createUtf8(rt, "  abc  ");
    const string_trim = string_trim_obj.value();
    defer string_trim.free(rt);
    try expectStringValue(rt, "abc", try builtins.string.methodCall(rt, string_trim, 8, &.{}));
    try expectStringValue(rt, "abc  ", try builtins.string.methodCall(rt, string_trim, 21, &.{}));
    try expectStringValue(rt, "  abc", try builtins.string.methodCall(rt, string_trim, 22, &.{}));
    const number_string_object = try builtins.string.construct(rt, &.{core.Value.int32(123)});
    defer number_string_object.free(rt);
    try expectStringValue(rt, "123", try builtins.string.methodCall(rt, number_string_object, 9, &.{}));
    try expectStringValue(rt, "Hello", try builtins.string.fromCharCode(rt, &.{ core.Value.int32(72), core.Value.int32(101), core.Value.int32(108), core.Value.int32(108), core.Value.int32(111) }));
    var many_chars: [65]core.Value = undefined;
    for (&many_chars) |*slot| slot.* = core.Value.int32(65);
    try expectStringValue(rt, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", try builtins.string.fromCharCode(rt, many_chars[0..]));
    const wide_from_char_code = try builtins.string.fromCharCode(rt, &.{core.Value.int32(0x0100)});
    defer wide_from_char_code.free(rt);
    const wide_string: *core.string.String = @fieldParentPtr("header", wide_from_char_code.refHeader().?);
    try std.testing.expect(wide_string.isWide());
    try std.testing.expectEqual(@as(u16, 0x0100), wide_string.codeUnitAt(0));
}

test "Iterator next OOM releases pending value" {
    try expectIteratorNextOOMCleanup(.string);
    try expectIteratorNextOOMCleanup(.array);
    try expectIteratorNextOOMCleanup(.collection);
}

test "Iterator done result OOM preserves targets" {
    try expectIteratorDoneOOMPreservesTarget(.string);
    try expectIteratorDoneOOMPreservesTarget(.array);
    try expectIteratorDoneOOMPreservesTarget(.collection);
}

const IteratorNextOOMKind = enum { string, array, collection };

fn expectIteratorNextOOMCleanup(kind: IteratorNextOOMKind) !void {
    var saw_oom = false;
    var saw_success = false;

    var fail_offset: usize = 0;
    while (fail_offset < 120) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.Runtime.create(failing.allocator());

        const setup = try createIteratorNextOOMFixture(rt, kind);

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = iteratorNextOOMCall(rt, kind, setup.iterator);
        failing.fail_index = std.math.maxInt(usize);

        if (result) |value| {
            saw_success = true;
            value.free(rt);
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => |unexpected| {
                setup.deinit(rt);
                rt.destroy();
                return unexpected;
            },
        }

        setup.deinit(rt);
        rt.destroy();
        if (saw_oom and saw_success) return;
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

const IteratorNextOOMFixture = struct {
    source: core.Value,
    iterator: core.Value,

    fn deinit(self: IteratorNextOOMFixture, rt: *core.Runtime) void {
        self.iterator.free(rt);
        self.source.free(rt);
    }
};

fn createIteratorNextOOMFixture(rt: *core.Runtime, kind: IteratorNextOOMKind) !IteratorNextOOMFixture {
    return switch (kind) {
        .string => blk: {
            const source = (try core.string.String.createUtf8(rt, "A")).value();
            errdefer source.free(rt);
            const iterator = try builtins.string.iterator(rt, source);
            break :blk .{ .source = source, .iterator = iterator };
        },
        .array => blk: {
            const array = try core.Object.createArray(rt, null);
            const source = array.value();
            errdefer source.free(rt);
            const item = try core.Object.create(rt, core.class.ids.object, null);
            defer item.value().free(rt);
            try array.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(item.value(), true, true, true));
            array.length = 1;
            const iterator = try builtins.array.methodCall(rt, source, 17, &.{});
            break :blk .{ .source = source, .iterator = iterator };
        },
        .collection => blk: {
            const source = try builtins.collection.construct(rt, 1);
            errdefer source.free(rt);
            const item = try core.Object.create(rt, core.class.ids.object, null);
            defer item.value().free(rt);
            const set_result = try builtins.collection.methodCall(rt, source, 1, &.{ core.Value.int32(1), item.value() });
            set_result.free(rt);
            const iterator = try builtins.collection.methodCall(rt, source, 8, &.{});
            break :blk .{ .source = source, .iterator = iterator };
        },
    };
}

fn expectIteratorDoneOOMPreservesTarget(kind: IteratorNextOOMKind) !void {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const setup = try createIteratorDoneOOMFixture(rt, kind);
    defer setup.deinit(rt);

    const iterator = objectFromValue(setup.iterator);
    try std.testing.expect(iterator.iteratorTargetSlot().* != null);

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, iteratorNextOOMCall(rt, kind, setup.iterator));
    rt.setMemoryLimit(null);

    try std.testing.expect(iterator.iteratorTargetSlot().* != null);
    const done = try iteratorNextOOMCall(rt, kind, setup.iterator);
    defer done.free(rt);
    try std.testing.expect(iterator.iteratorTargetSlot().* == null);
}

fn createIteratorDoneOOMFixture(rt: *core.Runtime, kind: IteratorNextOOMKind) !IteratorNextOOMFixture {
    return switch (kind) {
        .string => blk: {
            const source = (try core.string.String.createUtf8(rt, "")).value();
            errdefer source.free(rt);
            const iterator = try builtins.string.iterator(rt, source);
            break :blk .{ .source = source, .iterator = iterator };
        },
        .array => blk: {
            const array = try core.Object.createArray(rt, null);
            const source = array.value();
            errdefer source.free(rt);
            const iterator = try builtins.array.methodCall(rt, source, 17, &.{});
            break :blk .{ .source = source, .iterator = iterator };
        },
        .collection => blk: {
            const source = try builtins.collection.construct(rt, 1);
            errdefer source.free(rt);
            const iterator = try builtins.collection.methodCall(rt, source, 8, &.{});
            break :blk .{ .source = source, .iterator = iterator };
        },
    };
}

fn iteratorNextOOMCall(rt: *core.Runtime, kind: IteratorNextOOMKind, iterator: core.Value) !core.Value {
    return switch (kind) {
        .string => builtins.string.iteratorNext(rt, iterator),
        .array => builtins.array.methodCall(rt, iterator, 20, &.{}),
        .collection => builtins.collection.methodCall(rt, iterator, 13, &.{}),
    };
}

test "number parseFloat parseInt toFixed + boolean toString + symbol + bigint" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    try std.testing.expectEqual(@as(f64, 3.5), try builtins.number.parseFloat("3.5"));
    const parse_input_string = try core.string.String.createUtf8(rt, "0x10");
    const parse_input = parse_input_string.value();
    defer parse_input.free(rt);
    try std.testing.expectEqual(@as(f64, 16.0), try builtins.number.parseIntValue(rt, parse_input, null));
    try std.testing.expectEqual(@as(f64, 0.0), try builtins.number.parseIntValue(rt, parse_input, core.Value.int32(10)));
    try std.testing.expect(std.math.isNan(try builtins.number.parseIntValue(rt, parse_input, core.Value.int32(1))));

    const partial_int_string = try core.string.String.createUtf8(rt, "12px");
    const partial_int = partial_int_string.value();
    defer partial_int.free(rt);
    try std.testing.expectEqual(@as(f64, 12.0), try builtins.number.parseIntValue(rt, partial_int, null));

    const binary_int_string = try core.string.String.createUtf8(rt, "11");
    const binary_int = binary_int_string.value();
    defer binary_int.free(rt);
    const binary_radix_string = try core.string.String.createUtf8(rt, "2");
    const binary_radix = binary_radix_string.value();
    defer binary_radix.free(rt);
    try std.testing.expectEqual(@as(f64, 3.0), try builtins.number.parseIntValue(rt, binary_int, binary_radix));
    try std.testing.expect(std.math.isNan(try builtins.number.parseIntValue(rt, binary_int, core.Value.boolean(true))));

    const partial_float_string = try core.string.String.createUtf8(rt, "1.5x");
    const partial_float = partial_float_string.value();
    defer partial_float.free(rt);
    try std.testing.expectEqual(@as(f64, 1.5), try builtins.number.parseFloatValue(rt, partial_float));

    const plus_fraction_string = try core.string.String.createUtf8(rt, "+.5x");
    const plus_fraction = plus_fraction_string.value();
    defer plus_fraction.free(rt);
    try std.testing.expectEqual(@as(f64, 0.5), try builtins.number.parseFloatValue(rt, plus_fraction));

    const infinity_float_string = try core.string.String.createUtf8(rt, "Infinityx");
    const infinity_float = infinity_float_string.value();
    defer infinity_float.free(rt);
    try std.testing.expect(std.math.isPositiveInf(try builtins.number.parseFloatValue(rt, infinity_float)));

    const invalid_float_string = try core.string.String.createUtf8(rt, "x1");
    const invalid_float = invalid_float_string.value();
    defer invalid_float.free(rt);
    try std.testing.expect(std.math.isNan(try builtins.number.parseFloatValue(rt, invalid_float)));

    const neg_zero_string = try core.string.String.createUtf8(rt, "-0");
    const neg_zero = neg_zero_string.value();
    defer neg_zero.free(rt);
    try std.testing.expect(std.math.isNegativeInf(1.0 / try builtins.number.parseFloatValue(rt, neg_zero)));
    try expectStringValue(rt, "1.10000", try builtins.number.toFixed(rt, core.Value.float64(1.1), &.{core.Value.int32(5)}));
    try expectStringValue(rt, "1.00", try builtins.number.toFixed(rt, core.Value.int32(1), &.{core.Value.int32(2)}));
    try std.testing.expectEqualStrings("false", builtins.boolean.toString(false));

    const sym = try rt.atoms.newSymbol("desc", .symbol);
    defer rt.atoms.free(sym);
    try std.testing.expectEqualStrings("desc", builtins.symbol.description(&rt.atoms, sym).?);

    var five = try libs.bignum.BigInt.fromInt(std.testing.allocator, 5);
    defer five.deinit();
    var seven = try libs.bignum.BigInt.fromInt(std.testing.allocator, 7);
    defer seven.deinit();
    var twelve = try builtins.bigint.add(five, seven);
    defer twelve.deinit();
    const twelve_text = try twelve.formatBase10Alloc(std.testing.allocator);
    defer std.testing.allocator.free(twelve_text);
    try std.testing.expectEqualStrings("12", twelve_text);
}

test "math abs call + date construct methodCall staticCall + json" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    try std.testing.expectEqual(@as(f64, 2.0), builtins.math.abs(-2.0));
    const math_args = [_]core.Value{ core.Value.int32(9), core.Value.int32(3), core.Value.int32(6) };
    try std.testing.expectEqual(@as(f64, 3.0), try builtins.math.call(7, &math_args));
    try std.testing.expectEqual(@as(f64, 9.0), try builtins.math.call(8, &math_args));
    try std.testing.expect(std.math.isNan(try builtins.math.call(1, &.{})));
    const undefined_arg = [_]core.Value{core.Value.undefinedValue()};
    try std.testing.expect(std.math.isNan(try builtins.math.call(1, &undefined_arg)));
    const null_arg = [_]core.Value{core.Value.nullValue()};
    try std.testing.expectEqual(@as(f64, 0.0), try builtins.math.call(1, &null_arg));
    const bool_arg = [_]core.Value{core.Value.boolean(true)};
    try std.testing.expectEqual(@as(f64, 1.0), try builtins.math.call(1, &bool_arg));
    try std.testing.expectEqual(@as(i64, 1), builtins.date.dayFromTime(builtins.date.ms_per_day));
    try expectStringValueContains(rt, "GMT+0000", try builtins.date.call(rt, &.{}));
    const date_utc_args = [_]core.Value{ core.Value.int32(2024), core.Value.int32(0), core.Value.int32(1) };
    try expectNumberValue(rt, 1704067200000, try builtins.date.staticCall(rt, 1, &date_utc_args));
    const date_utc_short_year_args = [_]core.Value{ core.Value.int32(99), core.Value.int32(0), core.Value.int32(1) };
    try expectNumberValue(rt, 915148800000, try builtins.date.staticCall(rt, 1, &date_utc_short_year_args));
    const date_parse_string = try core.string.String.createUtf8(rt, "2024-01-01T12:34:56.789Z");
    const date_parse_input = date_parse_string.value();
    defer date_parse_input.free(rt);
    const date_parse_args = [_]core.Value{date_parse_input};
    try expectNumberValue(rt, 1704112496789, try builtins.date.staticCall(rt, 2, &date_parse_args));
    const now_value = try builtins.date.staticCall(rt, 3, &.{});
    defer now_value.free(rt);
    try std.testing.expect((numberValue(now_value) orelse 0) > 0);

    const local_date_args = [_]core.Value{
        core.Value.int32(2024),
        core.Value.int32(0),
        core.Value.int32(2),
        core.Value.int32(3),
        core.Value.int32(4),
        core.Value.int32(5),
        core.Value.int32(6),
    };
    const local_date = try builtins.date.construct(rt, &local_date_args);
    defer local_date.free(rt);
    try expectNumberValue(rt, 2024, try builtins.date.methodCall(rt, local_date, 3));
    try expectNumberValue(rt, 0, try builtins.date.methodCall(rt, local_date, 4));
    try expectNumberValue(rt, 2, try builtins.date.methodCall(rt, local_date, 5));
    try expectNumberValue(rt, 3, try builtins.date.methodCall(rt, local_date, 6));
    try expectNumberValue(rt, 4, try builtins.date.methodCall(rt, local_date, 7));
    try expectNumberValue(rt, 5, try builtins.date.methodCall(rt, local_date, 8));
    try expectNumberValue(rt, 6, try builtins.date.methodCall(rt, local_date, 9));

    const epoch_args = [_]core.Value{core.Value.int32(0)};
    const epoch_date = try builtins.date.construct(rt, &epoch_args);
    defer epoch_date.free(rt);
    try expectNumberValue(rt, 0, try builtins.date.methodCall(rt, epoch_date, 1));
    try expectStringValue(rt, "1970-01-01T00:00:00.000Z", try builtins.date.methodCall(rt, epoch_date, 10));
    try expectStringValue(rt, "1970-01-01T00:00:00.000Z", try builtins.date.methodCall(rt, epoch_date, 11));
    try expectNumberValue(rt, 1970, try builtins.date.methodCall(rt, epoch_date, 12));
    try expectNumberValue(rt, 0, try builtins.date.methodCall(rt, epoch_date, 13));
    try expectNumberValue(rt, 1, try builtins.date.methodCall(rt, epoch_date, 14));
    try expectNumberValue(rt, 4, try builtins.date.methodCall(rt, epoch_date, 19));

    const invalid_date_args = [_]core.Value{core.Value.float64(std.math.nan(f64))};
    const invalid_date = try builtins.date.construct(rt, &invalid_date_args);
    defer invalid_date.free(rt);
    const invalid_json = try builtins.date.methodCall(rt, invalid_date, 11);
    defer invalid_json.free(rt);
    try std.testing.expect(invalid_json.isNull());
    try std.testing.expectError(error.RangeError, builtins.date.methodCall(rt, invalid_date, 10));
    try std.testing.expectError(error.TypeError, builtins.date.methodCall(rt, core.Value.int32(1), 1));

    const annex_date = try builtins.date.construct(rt, &.{ core.Value.int32(1970), core.Value.int32(0) });
    defer annex_date.free(rt);
    try expectNumberValue(rt, 70, try builtins.date.methodCall(rt, annex_date, 22));
    const annex_set_year = try builtins.date.methodCallArgs(rt, annex_date, 23, &.{core.Value.int32(50)});
    defer annex_set_year.free(rt);
    try expectNumberValue(rt, 1950, try builtins.date.methodCall(rt, annex_date, 3));
    try expectNumberValue(rt, 50, try builtins.date.methodCall(rt, annex_date, 22));

    var json_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("42", try builtins.json.stringifyInt(&json_buf, 42));
    try std.testing.expectEqual(@as(i32, 42), try builtins.json.parseInt("42"));
}

test "uri encode decode escape unescape + regexp construct methodCall + promise + collections" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const uri_input_string = try core.string.String.createUtf8(rt, "a b?x=1&y=2#z");
    const uri_input = uri_input_string.value();
    defer uri_input.free(rt);
    try expectStringValue(rt, "a%20b?x=1&y=2#z", try builtins.uri.call(rt, 1, uri_input));
    try expectStringValue(rt, "a%20b%3Fx%3D1%26y%3D2%23z", try builtins.uri.call(rt, 2, uri_input));

    const reserved_input_string = try core.string.String.createUtf8(rt, "%3F");
    const reserved_input = reserved_input_string.value();
    defer reserved_input.free(rt);
    try expectStringValue(rt, "%3F", try builtins.uri.call(rt, 3, reserved_input));
    try expectStringValue(rt, "?", try builtins.uri.call(rt, 4, reserved_input));

    const non_ascii_uri_input = try builtins.string.fromCharCode(rt, &.{core.Value.int32(0x100)});
    defer non_ascii_uri_input.free(rt);
    const non_ascii_decoded = try builtins.uri.call(rt, 3, non_ascii_uri_input);
    defer non_ascii_decoded.free(rt);
    try expectSameStringValue(non_ascii_uri_input, non_ascii_decoded);

    const lone_surrogate = try builtins.string.fromCharCode(rt, &.{core.Value.int32(0xd800)});
    defer lone_surrogate.free(rt);
    try std.testing.expectError(error.URIError, builtins.uri.call(rt, 1, lone_surrogate));

    const annex_escape_input = try builtins.string.fromCharCode(rt, &.{
        core.Value.int32(0x21),
        core.Value.int32(0x2a),
        core.Value.int32(0x7f),
        core.Value.int32(0x80),
        core.Value.int32(0x100),
        core.Value.int32(0xd834),
        core.Value.int32(0xdf06),
    });
    defer annex_escape_input.free(rt);
    try expectStringValue(rt, "%21*%7F%80%u0100%uD834%uDF06", try builtins.uri.escape(rt, annex_escape_input));

    const annex_unescape_input_string = try core.string.String.createUtf8(rt, "%21*%7F%80%u0100%uD834%uDF06");
    const annex_unescape_input = annex_unescape_input_string.value();
    defer annex_unescape_input.free(rt);
    const annex_unescaped = try builtins.uri.unescape(rt, annex_unescape_input);
    defer annex_unescaped.free(rt);
    try expectSameStringValue(annex_escape_input, annex_unescaped);

    const re = try libs.regexp.compile("x", .{});
    try std.testing.expect(builtins.regexp.matches(re, "xyz"));
    const regexp_pattern_string = try core.string.String.createUtf8(rt, "a");
    const regexp_pattern = regexp_pattern_string.value();
    defer regexp_pattern.free(rt);
    const regexp_flags_string = try core.string.String.createUtf8(rt, "g");
    const regexp_flags = regexp_flags_string.value();
    defer regexp_flags.free(rt);
    const regexp_object = try builtins.regexp.construct(rt, regexp_pattern, regexp_flags);
    defer regexp_object.free(rt);
    try expectStringValue(rt, "/a/g", try builtins.regexp.methodCall(rt, regexp_object, 1, null));
    const regexp_arg_string = try core.string.String.createUtf8(rt, "a");
    const regexp_arg = regexp_arg_string.value();
    defer regexp_arg.free(rt);
    const regexp_test = try builtins.regexp.methodCall(rt, regexp_object, 2, regexp_arg);
    defer regexp_test.free(rt);
    try std.testing.expectEqual(true, regexp_test.asBool().?);
    const regexp_exec = try builtins.regexp.methodCall(rt, regexp_object, 3, regexp_arg);
    defer regexp_exec.free(rt);
    try std.testing.expect(regexp_exec.isNull());
    try std.testing.expectError(error.TypeError, builtins.regexp.methodCall(rt, core.Value.int32(1), 1, null));

    const promise_object = try builtins.promise.construct(rt);
    defer promise_object.free(rt);
    try expectObjectClass(promise_object, core.class.ids.promise);
    try expectObjectPropertyClass(rt, promise_object, "then", core.class.ids.c_function);
    try expectObjectPropertyClass(rt, promise_object, "catch", core.class.ids.c_function);
    const promise_ctx = try core.Context.create(rt);
    defer promise_ctx.destroy();
    const promise_resolve = try builtins.promise.staticCall(promise_ctx, 1, null);
    defer promise_resolve.free(rt);
    try expectObjectClass(promise_resolve, core.class.ids.promise);
    const promise_all = try builtins.promise.staticCall(promise_ctx, 2, null);
    defer promise_all.free(rt);
    try expectObjectClass(promise_all, core.class.ids.promise);
    const promise_race = try builtins.promise.staticCall(promise_ctx, 3, null);
    defer promise_race.free(rt);
    try expectObjectClass(promise_race, core.class.ids.promise);
    const promise_reject = try builtins.promise.staticCall(promise_ctx, 4, core.Value.int32(7));
    defer promise_reject.free(rt);
    try expectObjectClass(promise_reject, core.class.ids.promise);
    try std.testing.expect(promise_ctx.hasException());
    const promise_reason = promise_ctx.takeException();
    defer promise_reason.free(rt);
    try std.testing.expectEqual(@as(?i32, 7), promise_reason.asInt32());
    try std.testing.expectError(error.TypeError, builtins.promise.staticCall(promise_ctx, 99, null));

    const collection_map = try builtins.collection.construct(rt, 1);
    defer collection_map.free(rt);
    try expectObjectClass(collection_map, core.class.ids.map);
    try expectIntProperty(rt, collection_map, "size", 0);
    try expectObjectPropertyClass(rt, collection_map, "set", core.class.ids.c_function);
    try expectObjectPropertyClass(rt, collection_map, "get", core.class.ids.c_function);
    const map_key_string = try core.string.String.createUtf8(rt, "key");
    const map_key = map_key_string.value();
    defer map_key.free(rt);
    const map_stored_string = try core.string.String.createUtf8(rt, "value");
    const map_stored = map_stored_string.value();
    defer map_stored.free(rt);
    const map_set_args = [_]core.Value{ map_key, map_stored };
    const map_set = try builtins.collection.methodCall(rt, collection_map, 1, map_set_args[0..]);
    defer map_set.free(rt);
    try expectObjectClass(map_set, core.class.ids.map);
    try expectIntProperty(rt, collection_map, "size", 1);
    const map_second_key = core.Value.int32(2);
    const map_second_value = core.Value.int32(22);
    const map_second_args = [_]core.Value{ map_second_key, map_second_value };
    const map_second_set = try builtins.collection.methodCall(rt, collection_map, 1, map_second_args[0..]);
    defer map_second_set.free(rt);
    try expectObjectClass(map_second_set, core.class.ids.map);
    try expectIntProperty(rt, collection_map, "size", 2);
    const map_get_args = [_]core.Value{map_key};
    try expectStringValue(rt, "value", try builtins.collection.methodCall(rt, collection_map, 2, map_get_args[0..]));
    const map_second_get = try builtins.collection.methodCall(rt, collection_map, 2, &.{map_second_key});
    defer map_second_get.free(rt);
    try std.testing.expectEqual(@as(?i32, 22), map_second_get.asInt32());
    const map_has = try builtins.collection.methodCall(rt, collection_map, 3, map_get_args[0..]);
    defer map_has.free(rt);
    try std.testing.expectEqual(@as(?bool, true), map_has.asBool());
    const map_delete = try builtins.collection.methodCall(rt, collection_map, 4, map_get_args[0..]);
    defer map_delete.free(rt);
    try std.testing.expectEqual(@as(?bool, true), map_delete.asBool());
    try expectIntProperty(rt, collection_map, "size", 1);
    const map_clear = try builtins.collection.methodCall(rt, collection_map, 5, &.{});
    defer map_clear.free(rt);
    try std.testing.expect(map_clear.isUndefined());
    try expectIntProperty(rt, collection_map, "size", 0);

    const collection_set = try builtins.collection.construct(rt, 2);
    defer collection_set.free(rt);
    try expectObjectClass(collection_set, core.class.ids.set);
    const set_add_args = [_]core.Value{core.Value.int32(1)};
    const set_add = try builtins.collection.methodCall(rt, collection_set, 6, set_add_args[0..]);
    defer set_add.free(rt);
    try expectObjectClass(set_add, core.class.ids.set);
    try expectIntProperty(rt, collection_set, "size", 1);
    const set_second_add = try builtins.collection.methodCall(rt, collection_set, 6, &.{core.Value.int32(2)});
    defer set_second_add.free(rt);
    try expectObjectClass(set_second_add, core.class.ids.set);
    const set_duplicate_add = try builtins.collection.methodCall(rt, collection_set, 6, set_add_args[0..]);
    defer set_duplicate_add.free(rt);
    try expectObjectClass(set_duplicate_add, core.class.ids.set);
    try expectIntProperty(rt, collection_set, "size", 2);
    const set_has = try builtins.collection.methodCall(rt, collection_set, 3, set_add_args[0..]);
    defer set_has.free(rt);
    try std.testing.expectEqual(@as(?bool, true), set_has.asBool());

    const collection_weakmap = try builtins.collection.construct(rt, 3);
    defer collection_weakmap.free(rt);
    try expectObjectClass(collection_weakmap, core.class.ids.weakmap);
    const weakmap_key_object = try builtins.object.create(rt, null);
    const weakmap_key = weakmap_key_object.value();
    defer weakmap_key.free(rt);
    const weakmap_set = try builtins.collection.methodCall(rt, collection_weakmap, 1, &.{ weakmap_key, core.Value.int32(44) });
    defer weakmap_set.free(rt);
    try expectObjectClass(weakmap_set, core.class.ids.weakmap);
    const weakmap_get = try builtins.collection.methodCall(rt, collection_weakmap, 2, &.{weakmap_key});
    defer weakmap_get.free(rt);
    try std.testing.expectEqual(@as(?i32, 44), weakmap_get.asInt32());
    const weakmap_primitive_has = try builtins.collection.methodCall(rt, collection_weakmap, 3, &.{core.Value.int32(1)});
    defer weakmap_primitive_has.free(rt);
    try std.testing.expectEqual(@as(?bool, false), weakmap_primitive_has.asBool());
    try std.testing.expectError(error.TypeError, builtins.collection.methodCall(rt, collection_weakmap, 1, &.{ core.Value.int32(1), core.Value.int32(2) }));
    const weakmap_delete = try builtins.collection.methodCall(rt, collection_weakmap, 4, &.{weakmap_key});
    defer weakmap_delete.free(rt);
    try std.testing.expectEqual(@as(?bool, true), weakmap_delete.asBool());
    const weakmap_get_after_delete = try builtins.collection.methodCall(rt, collection_weakmap, 2, &.{weakmap_key});
    defer weakmap_get_after_delete.free(rt);
    try std.testing.expect(weakmap_get_after_delete.isUndefined());
    const weakmap_set_after_delete = try builtins.collection.methodCall(rt, collection_weakmap, 1, &.{ weakmap_key, core.Value.int32(45) });
    defer weakmap_set_after_delete.free(rt);
    try expectObjectClass(weakmap_set_after_delete, core.class.ids.weakmap);
    const weakmap_get_after_reinsert = try builtins.collection.methodCall(rt, collection_weakmap, 2, &.{weakmap_key});
    defer weakmap_get_after_reinsert.free(rt);
    try std.testing.expectEqual(@as(?i32, 45), weakmap_get_after_reinsert.asInt32());

    const collection_weakset = try builtins.collection.construct(rt, 4);
    defer collection_weakset.free(rt);
    try expectObjectClass(collection_weakset, core.class.ids.weakset);
    try expectObjectPropertyClass(rt, collection_weakset, "add", core.class.ids.c_function);
    const weak_key_object = try builtins.object.create(rt, null);
    const weak_key = weak_key_object.value();
    defer weak_key.free(rt);
    const weakset_args = [_]core.Value{weak_key};
    const weakset_add = try builtins.collection.methodCall(rt, collection_weakset, 6, weakset_args[0..]);
    defer weakset_add.free(rt);
    try expectObjectClass(weakset_add, core.class.ids.weakset);
    const weakset_has = try builtins.collection.methodCall(rt, collection_weakset, 3, weakset_args[0..]);
    defer weakset_has.free(rt);
    try std.testing.expectEqual(@as(?bool, true), weakset_has.asBool());
    const weakset_primitive_has = try builtins.collection.methodCall(rt, collection_weakset, 3, &.{core.Value.int32(1)});
    defer weakset_primitive_has.free(rt);
    try std.testing.expectEqual(@as(?bool, false), weakset_primitive_has.asBool());
    var live_identity = @intFromPtr(weak_key.refHeader().?);
    const removed_weakmap_entries = try builtins.collection.sweepWeakEntries(rt, @fieldParentPtr("header", collection_weakmap.refHeader().?), @ptrCast(&live_identity), keepOnlyIdentityLive);
    try std.testing.expectEqual(@as(usize, 1), removed_weakmap_entries);
    const weakmap_after_sweep = try builtins.collection.methodCall(rt, collection_weakmap, 3, &.{weakmap_key});
    defer weakmap_after_sweep.free(rt);
    try std.testing.expectEqual(@as(?bool, false), weakmap_after_sweep.asBool());
    const weakmap_set_after_sweep = try builtins.collection.methodCall(rt, collection_weakmap, 1, &.{ weakmap_key, core.Value.int32(46) });
    defer weakmap_set_after_sweep.free(rt);
    try expectObjectClass(weakmap_set_after_sweep, core.class.ids.weakmap);
    const weakmap_clear = try builtins.collection.methodCall(rt, collection_weakmap, 5, &.{});
    defer weakmap_clear.free(rt);
    try std.testing.expect(weakmap_clear.isUndefined());
    const weakmap_has_after_clear = try builtins.collection.methodCall(rt, collection_weakmap, 3, &.{weakmap_key});
    defer weakmap_has_after_clear.free(rt);
    try std.testing.expectEqual(@as(?bool, false), weakmap_has_after_clear.asBool());
    const removed_weakset_entries = try builtins.collection.sweepWeakEntries(rt, @fieldParentPtr("header", collection_weakset.refHeader().?), @ptrCast(&live_identity), keepOnlyIdentityLive);
    try std.testing.expectEqual(@as(usize, 0), removed_weakset_entries);

    try std.testing.expectError(error.TypeError, builtins.collection.methodCall(rt, core.Value.int32(1), 3, set_add_args[0..]));
    try std.testing.expectError(error.TypeError, builtins.collection.construct(rt, 99));
    try std.testing.expectError(error.TypeError, builtins.collection.methodCall(rt, collection_map, 99, &.{}));
    try std.testing.expectEqualStrings("boom", builtins.error_.create("boom").message);
    try std.testing.expect(builtins.collection.sameValueZero(core.Value.int32(1), core.Value.int32(1)));
}

test "promise array combinator OOM releases intermediate arrays once" {
    try expectPromiseCombinatorOOMCleanup(2);
    try expectPromiseCombinatorOOMCleanup(5);
    try expectPromiseCombinatorOOMCleanup(6);
}

test "JSON stringify property list release preserves memory account" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const object = try core.Object.create(rt, core.class.ids.object, null);
    defer object.value().free(rt);
    const replacer = try core.Object.createArray(rt, null);
    defer replacer.value().free(rt);

    const a = try rt.internAtom("a");
    const b = try rt.internAtom("b");
    defer rt.atoms.free(a);
    defer rt.atoms.free(b);

    try object.defineOwnProperty(rt, a, core.Descriptor.data(core.Value.int32(1), true, true, true));
    try object.defineOwnProperty(rt, b, core.Descriptor.data(core.Value.int32(2), true, true, true));

    const key = try core.string.String.createAscii(rt, "a");
    defer key.value().free(rt);
    try replacer.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(key.value(), true, true, true));

    const before_bytes = rt.memory.allocated_bytes;
    const before_allocations = rt.memory.allocation_count;
    try expectStringValue(rt, "{\"a\":1}", try builtins.json.stringify(rt, object.value(), replacer.value(), core.Value.undefinedValue()));
    try std.testing.expectEqual(before_bytes, rt.memory.allocated_bytes);
    try std.testing.expectEqual(before_allocations, rt.memory.allocation_count);
}

test "JSON stringify property list OOM releases pending atom" {
    const property_name = "json_oom_pending_atom";
    var saw_oom = false;
    var saw_success = false;

    var fail_offset: usize = 0;
    while (fail_offset < 120) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.Runtime.create(failing.allocator());
        defer rt.destroy();

        const object = try core.Object.create(rt, core.class.ids.object, null);
        const object_value = object.value();
        defer object_value.free(rt);
        const replacer = try core.Object.createArray(rt, null);
        const replacer_value = replacer.value();
        defer replacer_value.free(rt);

        const key = try core.string.String.createAscii(rt, property_name);
        defer key.value().free(rt);
        try replacer.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(key.value(), true, true, true));

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = builtins.json.stringify(rt, object_value, replacer_value, core.Value.undefinedValue());
        failing.fail_index = std.math.maxInt(usize);

        if (result) |value| {
            saw_success = true;
            value.free(rt);
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => |unexpected| return unexpected,
        }

        const probe = try rt.internAtom(property_name);
        rt.atoms.free(probe);
        try std.testing.expect(rt.atoms.name(probe) == null);
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

test "JSON parse stringify and rawJSON keep nested values under forced GC" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const old_threshold = rt.gcThreshold();
    rt.setGCThreshold(0);
    defer rt.setGCThreshold(old_threshold);

    const input = try core.string.String.createAscii(rt, "{\"a\":[1,\"x\",true],\"b\":{\"c\":2}}");
    const input_value = input.value();
    defer input_value.free(rt);

    const parsed = try builtins.json.parse(rt, null, input_value);
    defer parsed.free(rt);
    try expectObjectClass(parsed, core.class.ids.object);

    try expectStringValue(rt, "{\"a\":[1,\"x\",true],\"b\":{\"c\":2}}", try builtins.json.stringify(rt, parsed, core.Value.undefinedValue(), core.Value.undefinedValue()));

    const raw_input = try core.string.String.createAscii(rt, "123");
    const raw_input_value = raw_input.value();
    defer raw_input_value.free(rt);
    const raw = try builtins.json.rawJSON(rt, raw_input_value);
    defer raw.free(rt);
    try expectObjectClass(raw, core.class.ids.raw_json);
    try std.testing.expect(builtins.json.isRawJSON(raw));

    const wrapper = try core.Object.create(rt, core.class.ids.object, null);
    const wrapper_value = wrapper.value();
    defer wrapper_value.free(rt);
    const raw_atom = try rt.internAtom("raw");
    defer rt.atoms.free(raw_atom);
    try wrapper.defineOwnProperty(rt, raw_atom, core.Descriptor.data(raw, true, true, true));

    try expectStringValue(rt, "{\"raw\":123}", try builtins.json.stringify(rt, wrapper_value, core.Value.undefinedValue(), core.Value.undefinedValue()));
}

fn expectPromiseCombinatorOOMCleanup(mode: u32) !void {
    var saw_oom = false;
    var saw_success = false;

    var fail_offset: usize = 0;
    while (fail_offset < 160) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.Runtime.create(failing.allocator());
        const ctx = try core.Context.create(rt);

        const array = try core.Object.createArray(rt, null);
        const payload = array.value();
        const item = if (mode == 6)
            try builtins.promise.rejectedWithPrototype(rt, core.Value.int32(13), null)
        else
            core.Value.int32(13);
        try array.defineOwnProperty(rt, core.atom.atomFromUInt32(0), core.Descriptor.data(item, true, true, true));
        array.length = 1;

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = builtins.promise.staticCall(ctx, mode, payload);
        failing.fail_index = std.math.maxInt(usize);

        if (result) |value| {
            saw_success = true;
            value.free(rt);
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => |unexpected| {
                cleanupPromiseCombinatorOOMIteration(rt, ctx, payload, item);
                return unexpected;
            },
        }

        cleanupPromiseCombinatorOOMIteration(rt, ctx, payload, item);
        if (saw_oom and saw_success) return;
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

fn cleanupPromiseCombinatorOOMIteration(rt: *core.Runtime, ctx: *core.Context, payload: core.Value, item: core.Value) void {
    if (ctx.hasException()) {
        const exception = ctx.takeException();
        exception.free(rt);
    }
    if (ctx.hasUnhandledRejection()) {
        const rejection = ctx.takeUnhandledRejection();
        rejection.free(rt);
    }
    payload.free(rt);
    if (item.requiresRefCount()) item.free(rt);
    ctx.destroy();
    rt.destroy();
}

test "iterator prototype OOM releases fallback prototypes once" {
    try expectIteratorPrototypeOOMCleanup(.array);
    try expectIteratorPrototypeOOMCleanup(.string);
}

const IteratorPrototypeOOMKind = enum { array, string };

fn expectIteratorPrototypeOOMCleanup(kind: IteratorPrototypeOOMKind) !void {
    var saw_oom = false;
    var saw_success = false;

    var fail_offset: usize = 0;
    while (fail_offset < 140) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.Runtime.create(failing.allocator());

        const receiver = switch (kind) {
            .array => (try core.Object.createArray(rt, null)).value(),
            .string => (try core.string.String.createAscii(rt, "abc")).value(),
        };

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = switch (kind) {
            .array => builtins.array.methodCall(rt, receiver, 17, &.{}),
            .string => builtins.string.iterator(rt, receiver),
        };
        failing.fail_index = std.math.maxInt(usize);

        if (result) |value| {
            saw_success = true;
            value.free(rt);
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => |unexpected| {
                receiver.free(rt);
                rt.destroy();
                return unexpected;
            },
        }

        receiver.free(rt);
        rt.destroy();
        if (saw_oom and saw_success) return;
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

test "Map set rolls back inserted entry when size update fails" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const map_value = try builtins.collection.construct(rt, 1);
    defer map_value.free(rt);
    const map_object: *core.Object = @fieldParentPtr("header", map_value.refHeader().?);

    const first_set = try builtins.collection.methodCall(rt, map_value, 1, &.{ core.Value.int32(1), core.Value.int32(11) });
    defer first_set.free(rt);

    try fillOwnPropertyStorage(rt, map_object);
    try std.testing.expect(map_object.deleteProperty(rt, core.atom.predefinedId("size", .string).?));

    const retained = try core.Object.create(rt, core.class.ids.object, null);
    defer retained.value().free(rt);
    const retained_refs = retained.header.rc;
    const old_len = map_object.collectionEntries().len;
    const old_active = map_object.collectionActiveCount();

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, builtins.collection.methodCall(rt, map_value, 1, &.{ core.Value.int32(2), retained.value() }));
    rt.setMemoryLimit(null);

    const entries_slot = map_object.collectionEntriesSlot();
    const observed_len = entries_slot.*.len;
    const observed_active = map_object.collectionActiveCount();
    if (entries_slot.*.len > old_len) {
        entries_slot.*[old_len] = .{ .key = core.Value.undefinedValue(), .value = core.Value.undefinedValue(), .active = false };
        entries_slot.* = entries_slot.*.ptr[0..old_len];
        map_object.collectionActiveCountSlot().* = old_active;
        map_object.clearCollectionIndex(rt);
    }

    try std.testing.expectEqual(retained_refs, retained.header.rc);
    try std.testing.expectEqual(old_len, observed_len);
    try std.testing.expectEqual(old_active, observed_active);
}

test "Map delete rolls back removed entry when size update fails" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const map_value = try builtins.collection.construct(rt, 1);
    defer map_value.free(rt);
    const map_object: *core.Object = @fieldParentPtr("header", map_value.refHeader().?);

    const retained = try core.Object.create(rt, core.class.ids.object, null);
    defer retained.value().free(rt);
    const set_result = try builtins.collection.methodCall(rt, map_value, 1, &.{ core.Value.int32(1), retained.value() });
    set_result.free(rt);

    try fillOwnPropertyStorage(rt, map_object);
    try std.testing.expect(map_object.deleteProperty(rt, core.atom.predefinedId("size", .string).?));

    const retained_refs = retained.header.rc;
    const old_len = map_object.collectionEntries().len;
    const old_active = map_object.collectionActiveCount();

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, builtins.collection.methodCall(rt, map_value, 4, &.{core.Value.int32(1)}));
    rt.setMemoryLimit(null);

    const has_result = try builtins.collection.methodCall(rt, map_value, 3, &.{core.Value.int32(1)});
    defer has_result.free(rt);
    try std.testing.expectEqual(@as(?bool, true), has_result.asBool());
    try std.testing.expectEqual(retained_refs, retained.header.rc);
    try std.testing.expectEqual(old_len, map_object.collectionEntries().len);
    try std.testing.expectEqual(old_active, map_object.collectionActiveCount());
}

test "Map clear rolls back removed entries when size update fails" {
    var saw_oom = false;
    var saw_success = false;

    var fail_offset: usize = 0;
    while (fail_offset < 220) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const rt = try core.Runtime.create(failing.allocator());
        defer rt.destroy();

        const map_value = try builtins.collection.construct(rt, 1);
        defer map_value.free(rt);
        const map_object: *core.Object = @fieldParentPtr("header", map_value.refHeader().?);

        const retained = try core.Object.create(rt, core.class.ids.object, null);
        defer retained.value().free(rt);
        const first_set = try builtins.collection.methodCall(rt, map_value, 1, &.{ core.Value.int32(1), retained.value() });
        first_set.free(rt);
        const second_set = try builtins.collection.methodCall(rt, map_value, 1, &.{ core.Value.int32(2), core.Value.int32(22) });
        second_set.free(rt);

        try fillOwnPropertyStorage(rt, map_object);
        try std.testing.expect(map_object.deleteProperty(rt, core.atom.predefinedId("size", .string).?));

        const retained_refs = retained.header.rc;
        const old_len = map_object.collectionEntries().len;
        const old_active = map_object.collectionActiveCount();

        failing.fail_index = failing.alloc_index + fail_offset;
        const result = builtins.collection.methodCall(rt, map_value, 5, &.{});
        failing.fail_index = std.math.maxInt(usize);

        if (result) |value| {
            saw_success = true;
            value.free(rt);
            try std.testing.expectEqual(@as(usize, 0), map_object.collectionActiveCount());
        } else |err| switch (err) {
            error.OutOfMemory => {
                saw_oom = true;
                const has_result = try builtins.collection.methodCall(rt, map_value, 3, &.{core.Value.int32(1)});
                defer has_result.free(rt);
                try std.testing.expectEqual(@as(?bool, true), has_result.asBool());
                try std.testing.expectEqual(retained_refs, retained.header.rc);
                try std.testing.expectEqual(old_len, map_object.collectionEntries().len);
                try std.testing.expectEqual(old_active, map_object.collectionActiveCount());
            },
            else => |unexpected| return unexpected,
        }

        if (saw_oom and saw_success) return;
    }

    try std.testing.expect(saw_oom);
    try std.testing.expect(saw_success);
}

test "WeakMap set releases duplicated value when holder registration fails" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const weakmap_value = try builtins.collection.construct(rt, 3);
    defer weakmap_value.free(rt);
    const weakmap = objectFromValue(weakmap_value);

    const key = try core.Object.create(rt, core.class.ids.object, null);
    defer key.value().free(rt);
    const retained = try core.Object.create(rt, core.class.ids.object, null);
    defer retained.value().free(rt);

    const retained_refs = retained.header.rc;
    try std.testing.expect(!rt.borrowedReferenceHolderRegistered(weakmap));

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, builtins.collection.methodCall(rt, weakmap_value, 1, &.{ key.value(), retained.value() }));
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(@as(usize, 0), weakmap.weakCollectionEntries().len);
    try std.testing.expect(!rt.borrowedReferenceHolderRegistered(weakmap));
    try std.testing.expectEqual(retained_refs, retained.header.rc);
}

test "WeakMap set preserves entries when weak entry growth fails" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const weakmap_value = try builtins.collection.construct(rt, 3);
    defer weakmap_value.free(rt);
    const weakmap = objectFromValue(weakmap_value);

    var keys: [5]core.Value = undefined;
    var key_count: usize = 0;
    defer {
        while (key_count != 0) {
            key_count -= 1;
            keys[key_count].free(rt);
        }
    }
    while (key_count < keys.len) : (key_count += 1) {
        const key = try core.Object.create(rt, core.class.ids.object, null);
        keys[key_count] = key.value();
    }

    for (keys[0..4], 0..) |key, index| {
        const set_result = try builtins.collection.methodCall(rt, weakmap_value, 1, &.{ key, core.Value.int32(@intCast(index)) });
        set_result.free(rt);
    }
    try std.testing.expectEqual(@as(usize, 4), weakmap.weakCollectionEntries().len);
    try std.testing.expect(rt.borrowedReferenceHolderRegistered(weakmap));

    const retained = try core.Object.create(rt, core.class.ids.object, null);
    defer retained.value().free(rt);
    const retained_refs = retained.header.rc;
    const old_len = weakmap.weakCollectionEntries().len;

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, builtins.collection.methodCall(rt, weakmap_value, 1, &.{ keys[4], retained.value() }));
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(old_len, weakmap.weakCollectionEntries().len);
    try std.testing.expect(rt.borrowedReferenceHolderRegistered(weakmap));
    try std.testing.expectEqual(retained_refs, retained.header.rc);
    const missing = try builtins.collection.methodCall(rt, weakmap_value, 3, &.{keys[4]});
    defer missing.free(rt);
    try std.testing.expectEqual(@as(?bool, false), missing.asBool());
}

test "WeakSet add preserves entries when weak entry growth fails" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const weakset_value = try builtins.collection.construct(rt, 4);
    defer weakset_value.free(rt);
    const weakset = objectFromValue(weakset_value);

    var keys: [5]core.Value = undefined;
    var key_count: usize = 0;
    defer {
        while (key_count != 0) {
            key_count -= 1;
            keys[key_count].free(rt);
        }
    }
    while (key_count < keys.len) : (key_count += 1) {
        const key = try core.Object.create(rt, core.class.ids.object, null);
        keys[key_count] = key.value();
    }

    for (keys[0..4]) |key| {
        const add_result = try builtins.collection.methodCall(rt, weakset_value, 6, &.{key});
        add_result.free(rt);
    }
    try std.testing.expectEqual(@as(usize, 4), weakset.weakCollectionEntries().len);
    try std.testing.expect(rt.borrowedReferenceHolderRegistered(weakset));

    rt.setMemoryLimit(rt.memory.allocated_bytes);
    try std.testing.expectError(error.OutOfMemory, builtins.collection.methodCall(rt, weakset_value, 6, &.{keys[4]}));
    rt.setMemoryLimit(null);

    try std.testing.expectEqual(@as(usize, 4), weakset.weakCollectionEntries().len);
    try std.testing.expect(rt.borrowedReferenceHolderRegistered(weakset));
    const missing = try builtins.collection.methodCall(rt, weakset_value, 3, &.{keys[4]});
    defer missing.free(rt);
    try std.testing.expectEqual(@as(?bool, false), missing.asBool());
}

fn fillOwnPropertyStorage(rt: *core.Runtime, object: *core.Object) !void {
    var index: usize = 0;
    while (object.properties.len < object.property_capacity or object.shape_ref.prop_count < object.shape_ref.props.len) : (index += 1) {
        if (index > 512) return error.TestUnexpectedResult;
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "fill_{d}", .{index});
        const atom_id = try rt.internAtom(name);
        try object.defineOwnProperty(rt, atom_id, core.Descriptor.data(core.Value.int32(@intCast(index)), true, true, true));
        rt.atoms.free(atom_id);
    }
}

fn expectStringValue(rt: *core.Runtime, expected: []const u8, value: core.Value) !void {
    defer value.free(rt);
    try std.testing.expect(value.isString());
    const header = value.refHeader().?;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    try std.testing.expect(string_value.eqlBytes(expected));
}

fn expectStringValueContains(rt: *core.Runtime, expected: []const u8, value: core.Value) !void {
    defer value.free(rt);
    try std.testing.expect(value.isString());
    const header = value.refHeader().?;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    const bytes = string_value.borrowLatin1() orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
}

fn expectSameStringValue(expected: core.Value, actual: core.Value) !void {
    try std.testing.expect(expected.isString());
    try std.testing.expect(actual.isString());
    const expected_header = expected.refHeader().?;
    const actual_header = actual.refHeader().?;
    const expected_string: *core.string.String = @fieldParentPtr("header", expected_header);
    const actual_string: *core.string.String = @fieldParentPtr("header", actual_header);
    try std.testing.expect(expected_string.eqlString(actual_string.*));
}

fn keepOnlyIdentityLive(context: ?*anyopaque, key_identity: usize) bool {
    const live: *usize = @ptrCast(@alignCast(context.?));
    return key_identity == live.*;
}

fn expectNumberValue(rt: *core.Runtime, expected: f64, value: core.Value) !void {
    defer value.free(rt);
    try std.testing.expectEqual(expected, numberValue(value).?);
}

fn expectObjectClass(value: core.Value, expected: core.ClassId) !void {
    try std.testing.expect(value.isObject());
    const object = objectFromValue(value);
    try std.testing.expectEqual(expected, object.class_id);
}

fn objectFromValue(value: core.Value) *core.Object {
    const header = value.refHeader().?;
    return @fieldParentPtr("header", header);
}

fn expectObjectPropertyClass(rt: *core.Runtime, object_value: core.Value, name: []const u8, expected: core.ClassId) !void {
    try std.testing.expect(object_value.isObject());
    const object = objectFromValue(object_value);
    const atom_id = try rt.internAtom(name);
    defer rt.atoms.free(atom_id);
    const value = object.getProperty(atom_id);
    defer value.free(rt);
    try expectObjectClass(value, expected);
}

fn expectIntProperty(rt: *core.Runtime, object_value: core.Value, name: []const u8, expected: i32) !void {
    try std.testing.expect(object_value.isObject());
    const header = object_value.refHeader().?;
    const object: *core.Object = @fieldParentPtr("header", header);
    const atom_id = try rt.internAtom(name);
    defer rt.atoms.free(atom_id);
    const value = object.getProperty(atom_id);
    defer value.free(rt);
    try std.testing.expectEqual(@as(?i32, expected), value.asInt32());
}

fn expectNoOwnProperty(rt: *core.Runtime, object: *core.Object, name: []const u8) !void {
    const atom_id = try rt.internAtom(name);
    defer rt.atoms.free(atom_id);
    try std.testing.expect(!object.hasOwnProperty(atom_id));
}

fn expectIntIndex(rt: *core.Runtime, object_value: core.Value, index: u32, expected: i32) !void {
    try std.testing.expect(object_value.isObject());
    const header = object_value.refHeader().?;
    const object: *core.Object = @fieldParentPtr("header", header);
    const value = object.getProperty(core.atom.atomFromUInt32(index));
    defer value.free(rt);
    try std.testing.expectEqual(@as(?i32, expected), value.asInt32());
}

fn expectArrayLength(object_value: core.Value, expected: u32) !void {
    try std.testing.expect(object_value.isObject());
    const header = object_value.refHeader().?;
    const object: *core.Object = @fieldParentPtr("header", header);
    try std.testing.expect(object.is_array);
    try std.testing.expectEqual(expected, object.length);
}

fn numberValue(value: core.Value) ?f64 {
    if (value.asInt32()) |int_value| return @floatFromInt(int_value);
    if (value.asFloat64()) |float_value| return float_value;
    return null;
}

var promise_jobs: usize = 0;

fn countPromiseJob(_: *core.Context, args: []const core.Value) core.Value {
    promise_jobs += 1;
    if (args.len >= 1) promise_jobs += @intCast(args[0].asInt32().?);
    return core.Value.undefinedValue();
}

test "promise buffers reflect proxy iterator and atomics helpers" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    promise_jobs = 0;
    try builtins.promise.enqueueReaction(&js.job_queue, js.context, countPromiseJob, &.{core.Value.int32(2)});
    try js.runJobs();
    try std.testing.expectEqual(@as(usize, 3), promise_jobs);

    var bytes = [_]u8{ 1, 2, 3 };
    var buffer = builtins.buffer.ArrayBuffer{ .bytes = &bytes };
    try std.testing.expectEqual(@as(usize, 3), buffer.byteLength());
    buffer.detach();
    try std.testing.expectEqual(@as(usize, 0), buffer.byteLength());

    const array_buffer = try builtins.buffer.arrayBufferConstruct(js.runtime, core.Value.int32(8));
    defer array_buffer.free(js.runtime);
    try expectObjectClass(array_buffer, core.class.ids.array_buffer);
    const array_buffer_object: *core.Object = @fieldParentPtr("header", array_buffer.refHeader().?);
    try expectNoOwnProperty(js.runtime, array_buffer_object, "byteLength");
    try expectNoOwnProperty(js.runtime, array_buffer_object, "maxByteLength");
    try std.testing.expectEqual(@as(usize, 8), array_buffer_object.byteStorage().len);

    const typed_array = try builtins.buffer.typedArrayConstruct(js.runtime, 4, array_buffer);
    defer typed_array.free(js.runtime);
    const typed_array_object: *core.Object = @fieldParentPtr("header", typed_array.refHeader().?);
    try std.testing.expectEqual(@as(u32, 2), try builtins.buffer.typedArrayLength(js.runtime, typed_array_object));
    try std.testing.expectEqual(@as(usize, 8), try builtins.buffer.typedArrayByteLength(js.runtime, typed_array_object));
    try std.testing.expectEqual(@as(usize, 0), try builtins.buffer.typedArrayByteOffset(typed_array_object));
    try expectNoOwnProperty(js.runtime, typed_array_object, "length");
    try expectNoOwnProperty(js.runtime, typed_array_object, "byteLength");
    try expectNoOwnProperty(js.runtime, typed_array_object, "byteOffset");
    try expectNoOwnProperty(js.runtime, typed_array_object, "buffer");

    const view_args = [_]core.Value{ array_buffer, core.Value.int32(1), core.Value.int32(4) };
    const data_view = try builtins.buffer.dataViewConstruct(js.runtime, view_args[0..], null);
    defer data_view.free(js.runtime);
    try expectObjectClass(data_view, core.class.ids.dataview);
    const data_view_object: *core.Object = @fieldParentPtr("header", data_view.refHeader().?);
    try expectNoOwnProperty(js.runtime, data_view_object, "buffer");
    try expectNoOwnProperty(js.runtime, data_view_object, "byteOffset");
    try expectNoOwnProperty(js.runtime, data_view_object, "byteLength");
    try std.testing.expectEqual(@as(usize, 1), try builtins.buffer.dataViewByteOffset(js.runtime, data_view_object));
    try std.testing.expectEqual(@as(usize, 4), try builtins.buffer.dataViewByteLength(js.runtime, data_view_object));

    const set_u16_args = [_]core.Value{ core.Value.int32(0), core.Value.int32(0x1234), core.Value.boolean(true) };
    const set_u16 = try builtins.buffer.dataViewSet(js.runtime, data_view, 4, set_u16_args[0..]);
    defer set_u16.free(js.runtime);
    try std.testing.expect(set_u16.isUndefined());
    const get_u16_args = [_]core.Value{ core.Value.int32(0), core.Value.boolean(true) };
    const get_u16 = try builtins.buffer.dataViewGet(js.runtime, data_view, 4, get_u16_args[0..]);
    defer get_u16.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 0x1234), get_u16.asInt32());

    const full_view_args = [_]core.Value{array_buffer};
    const full_view = try builtins.buffer.dataViewConstruct(js.runtime, full_view_args[0..], null);
    defer full_view.free(js.runtime);
    const set_big_args = [_]core.Value{ core.Value.int32(0), core.Value.shortBigInt(-1), core.Value.boolean(false) };
    const set_big = try builtins.buffer.dataViewSet(js.runtime, full_view, 9, set_big_args[0..]);
    defer set_big.free(js.runtime);
    const get_big_args = [_]core.Value{ core.Value.int32(0), core.Value.boolean(false) };
    const get_big = try builtins.buffer.dataViewGet(js.runtime, full_view, 9, get_big_args[0..]);
    defer get_big.free(js.runtime);
    try std.testing.expect(get_big.isBigInt());

    const slice = try builtins.buffer.arrayBufferSlice(js.runtime, array_buffer, core.Value.int32(1), core.Value.int32(3));
    defer slice.free(js.runtime);
    try expectObjectClass(slice, core.class.ids.array_buffer);
    const slice_object: *core.Object = @fieldParentPtr("header", slice.refHeader().?);
    try expectNoOwnProperty(js.runtime, slice_object, "byteLength");
    try std.testing.expectEqual(@as(usize, 2), slice_object.byteStorage().len);

    const out_of_bounds = [_]core.Value{core.Value.int32(8)};
    try std.testing.expectError(error.RangeError, builtins.buffer.dataViewGet(js.runtime, data_view, 1, out_of_bounds[0..]));
    try std.testing.expectError(error.TypeError, builtins.buffer.dataViewGet(js.runtime, array_buffer, 1, out_of_bounds[0..]));

    var proxy = builtins.reflect_proxy.RevocableProxy{};
    proxy.revoke();
    try std.testing.expect(proxy.revoked);

    var index: usize = 0;
    try std.testing.expectEqual(@as(usize, 0), builtins.iterator.next(&index, 2).value_index);
    try std.testing.expect(!builtins.iterator.next(&index, 2).done);
    try std.testing.expect(builtins.iterator.next(&index, 2).done);
    try std.testing.expect(builtins.atomics.isLockFree(4));
    try std.testing.expect(!builtins.atomics.isLockFree(3));
}

test "Promise withResolvers releases local promise owner" {
    const rt = try core.Runtime.create(std.testing.allocator);
    defer rt.destroy();

    const result = try builtins.promise.withResolvers(rt, null);
    result.free(rt);
}
