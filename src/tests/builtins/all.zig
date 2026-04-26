const std = @import("std");
const engine = @import("quickjs_zig_engine");

const builtins = engine.builtins;
const core = engine.core;
const libs = engine.libs;

test "support libraries cover unicode dtoa bignum and regexp basics" {
    try std.testing.expect(libs.unicode.isIdentifierStart('A'));
    try std.testing.expect(libs.unicode.isIdentifierContinue('9'));
    try std.testing.expectEqual(@as(u8, 'A'), libs.unicode.toUpperAscii('a'));
    try std.testing.expect(libs.unicode.equalsIgnoreAsciiCase("AbC", "aBc"));

    const n = try libs.dtoa.parseNumber("12.5");
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("12.5", try libs.dtoa.formatNumber(&buf, n));

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
}

test "object function array string number boolean symbol bigint math date json regexp error promise collections" {
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
    try std.testing.expectError(error.UnsupportedObjectCall, builtins.object.ownEntriesArray(rt, core.Value.int32(1), .keys));

    const this_value = core.Value.int32(7);
    try std.testing.expectEqual(@as(?i32, 7), builtins.function.applyReturnThis(this_value).asInt32());
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
    try std.testing.expectError(error.UnsupportedArrayCall, builtins.array.methodCall(rt, core.Value.int32(1), 1, &.{}));
    try std.testing.expectError(error.UnsupportedArrayCall, builtins.array.methodCall(rt, array_value, 3, &.{}));

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
    const number_string_object = try builtins.string.construct(rt, &.{core.Value.int32(123)});
    defer number_string_object.free(rt);
    try expectStringValue(rt, "123", try builtins.string.methodCall(rt, number_string_object, 9, &.{}));
    try expectStringValue(rt, "Hello", try builtins.string.fromCharCode(rt, &.{ core.Value.int32(72), core.Value.int32(101), core.Value.int32(108), core.Value.int32(108), core.Value.int32(111) }));
    var too_many_chars: [65]core.Value = undefined;
    for (&too_many_chars) |*slot| slot.* = core.Value.int32(65);
    try std.testing.expectError(error.UnsupportedStringCall, builtins.string.fromCharCode(rt, too_many_chars[0..]));
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
    try expectStringValue(rt, "Mon Jan 01 2024 00:00:00 GMT+0000", try builtins.date.call(rt, &.{}));
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

    var json_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("42", try builtins.json.stringifyInt(&json_buf, 42));
    try std.testing.expectEqual(@as(i32, 42), try builtins.json.parseInt("42"));

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
    try std.testing.expectError(error.UnsupportedPromiseCall, builtins.promise.staticCall(promise_ctx, 99, null));

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
    try std.testing.expect(map_set.isUndefined());
    try expectIntProperty(rt, collection_map, "size", 1);
    const map_get_args = [_]core.Value{map_key};
    try expectStringValue(rt, "value", try builtins.collection.methodCall(rt, collection_map, 2, map_get_args[0..]));
    const map_has = try builtins.collection.methodCall(rt, collection_map, 3, map_get_args[0..]);
    defer map_has.free(rt);
    try std.testing.expectEqual(@as(?bool, true), map_has.asBool());
    const map_delete = try builtins.collection.methodCall(rt, collection_map, 4, map_get_args[0..]);
    defer map_delete.free(rt);
    try std.testing.expectEqual(@as(?bool, true), map_delete.asBool());
    try expectIntProperty(rt, collection_map, "size", 0);
    const map_clear = try builtins.collection.methodCall(rt, collection_map, 5, &.{});
    defer map_clear.free(rt);
    try std.testing.expect(map_clear.isUndefined());

    const collection_set = try builtins.collection.construct(rt, 2);
    defer collection_set.free(rt);
    try expectObjectClass(collection_set, core.class.ids.set);
    const set_add_args = [_]core.Value{core.Value.int32(1)};
    const set_add = try builtins.collection.methodCall(rt, collection_set, 6, set_add_args[0..]);
    defer set_add.free(rt);
    try std.testing.expect(set_add.isUndefined());
    try expectIntProperty(rt, collection_set, "size", 1);
    const set_has = try builtins.collection.methodCall(rt, collection_set, 3, set_add_args[0..]);
    defer set_has.free(rt);
    try std.testing.expectEqual(@as(?bool, true), set_has.asBool());

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
    const weakset_has = try builtins.collection.methodCall(rt, collection_weakset, 3, weakset_args[0..]);
    defer weakset_has.free(rt);
    try std.testing.expectEqual(@as(?bool, true), weakset_has.asBool());

    try std.testing.expectError(error.TypeError, builtins.collection.methodCall(rt, core.Value.int32(1), 3, set_add_args[0..]));
    try std.testing.expectError(error.UnsupportedCollectionCall, builtins.collection.construct(rt, 99));
    try std.testing.expectError(error.UnsupportedCollectionCall, builtins.collection.methodCall(rt, collection_map, 99, &.{}));
    try std.testing.expectEqualStrings("boom", builtins.error_.create("boom").message);
    try std.testing.expect(builtins.collection.sameValueZero(core.Value.int32(1), core.Value.int32(1)));
}

fn expectStringValue(rt: *core.Runtime, expected: []const u8, value: core.Value) !void {
    defer value.free(rt);
    try std.testing.expect(value.isString());
    const header = value.refHeader().?;
    const string_value: *core.string.String = @fieldParentPtr("header", header);
    try std.testing.expect(string_value.eqlBytes(expected));
}

fn expectNumberValue(rt: *core.Runtime, expected: f64, value: core.Value) !void {
    defer value.free(rt);
    try std.testing.expectEqual(expected, numberValue(value).?);
}

fn expectObjectClass(value: core.Value, expected: core.ClassId) !void {
    try std.testing.expect(value.isObject());
    const header = value.refHeader().?;
    const object: *core.Object = @fieldParentPtr("header", header);
    try std.testing.expectEqual(expected, object.class_id);
}

fn expectObjectPropertyClass(rt: *core.Runtime, object_value: core.Value, name: []const u8, expected: core.ClassId) !void {
    try std.testing.expect(object_value.isObject());
    const header = object_value.refHeader().?;
    const object: *core.Object = @fieldParentPtr("header", header);
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

fn countPromiseJob() void {
    promise_jobs += 1;
}

test "promise buffers reflect proxy iterator and atomics helpers" {
    var js = try engine.Engine.init(std.testing.allocator);
    defer js.deinit();

    promise_jobs = 0;
    try builtins.promise.enqueueReaction(&js.job_queue, countPromiseJob);
    js.runJobs();
    try std.testing.expectEqual(@as(usize, 1), promise_jobs);

    var bytes = [_]u8{ 1, 2, 3 };
    var buffer = builtins.buffer.ArrayBuffer{ .bytes = &bytes };
    try std.testing.expectEqual(@as(usize, 3), buffer.byteLength());
    buffer.detach();
    try std.testing.expectEqual(@as(usize, 0), buffer.byteLength());

    const array_buffer = try builtins.buffer.arrayBufferConstruct(js.runtime, core.Value.int32(8));
    defer array_buffer.free(js.runtime);
    try expectObjectClass(array_buffer, core.class.ids.array_buffer);
    try expectIntProperty(js.runtime, array_buffer, "byteLength", 8);

    const typed_array = try builtins.buffer.typedArrayConstruct(js.runtime, 4, array_buffer);
    defer typed_array.free(js.runtime);
    try expectIntProperty(js.runtime, typed_array, "length", 2);
    try expectIntProperty(js.runtime, typed_array, "byteLength", 8);
    try expectIntProperty(js.runtime, typed_array, "byteOffset", 0);

    const view_args = [_]core.Value{ array_buffer, core.Value.int32(1), core.Value.int32(4) };
    const data_view = try builtins.buffer.dataViewConstruct(js.runtime, view_args[0..]);
    defer data_view.free(js.runtime);
    try expectObjectClass(data_view, core.class.ids.dataview);
    try expectIntProperty(js.runtime, data_view, "byteOffset", 1);
    try expectIntProperty(js.runtime, data_view, "byteLength", 4);

    const set_u16_args = [_]core.Value{ core.Value.int32(0), core.Value.int32(0x1234), core.Value.boolean(true) };
    const set_u16 = try builtins.buffer.dataViewSet(js.runtime, data_view, 4, set_u16_args[0..]);
    defer set_u16.free(js.runtime);
    try std.testing.expect(set_u16.isUndefined());
    const get_u16_args = [_]core.Value{ core.Value.int32(0), core.Value.boolean(true) };
    const get_u16 = try builtins.buffer.dataViewGet(js.runtime, data_view, 4, get_u16_args[0..]);
    defer get_u16.free(js.runtime);
    try std.testing.expectEqual(@as(?i32, 0x1234), get_u16.asInt32());

    const full_view_args = [_]core.Value{array_buffer};
    const full_view = try builtins.buffer.dataViewConstruct(js.runtime, full_view_args[0..]);
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
    try expectIntProperty(js.runtime, slice, "byteLength", 2);

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
