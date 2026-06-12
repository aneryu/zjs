//! Per-fusion-pattern hit counters for the hand-written multi-instruction
//! `tryFuse*` fast paths. Every `tryFuse*` call site is wrapped in
//! `counted(...)`; a hit is recorded when the pattern matched and the fused
//! execution replaced the generic opcode sequence. The counters are the
//! measurement basis for keeping or deleting individual fusions.
//!
//! Zero-cost by default: counting only compiles in with
//! `-Dzjs_enable_opcode_profile=true`. With that build flag, the `zjs` CLI
//! appends per-process totals to `$ZJS_FUSION_STATS_FILE` on exit and the
//! `--profile-opcodes` dump includes the per-fusion table.

const std = @import("std");
const build_options = @import("build_options");

pub const enabled = build_options.zjs_enable_opcode_profile;

/// One tag per hand-written multi-instruction fusion entry point.
pub const Fusion = enum(u16) {
    tryFuseArrayLengthLessThanFalseBranch,
    tryFuseArrayPushCallFromField2,
    tryFuseAtomPercentHexGlobalStringStore,
    tryFuseBackwardGotoGlobalDataInt32CompareFalseBranch,
    tryFuseCheckedLocalArrayMapSimpleCallbackRange,
    tryFuseCheckedLocalArrayPushInt32Range,
    tryFuseCheckedLocalCheckedLocalNumericAdd,
    tryFuseCheckedLocalDenseArrayChunkedInt32ValueAppendRange,
    tryFuseCheckedLocalDenseArrayInt32AppendRange,
    tryFuseCheckedLocalDenseArrayLengthIndexedInt32SumRange,
    tryFuseCheckedLocalDenseArrayModFieldInt32AddRange,
    tryFuseCheckedLocalEmptyInt32Range,
    tryFuseCheckedLocalFastPath,
    tryFuseCheckedLocalGlobalDataStoreInductionRange,
    tryFuseCheckedLocalInductionInt32AddRange,
    tryFuseCheckedLocalInvariantBindingInt32AddRange,
    tryFuseCheckedLocalInvariantInt32LoadAddRange,
    tryFuseCheckedLocalLatin1AtomAppendRange,
    tryFuseCheckedLocalMapGetLatin1PrefixInt32SumRange,
    tryFuseCheckedLocalMapSetLatin1PrefixInt32Range,
    tryFuseCheckedLocalMathMinMaxAddRange,
    tryFuseCheckedLocalRegExpLiteralTestConstStringCountRange,
    tryFuseCheckedLocalShortBigIntInductionAddRange,
    tryFuseCheckedLocalSimpleNumericCallAddRange,
    tryFuseCheckedLocalSparseArrayLiteralLengthAddRange,
    tryFuseDroppedCheckedLocalPostUpdateRead,
    tryFuseDroppedCheckedLocalPostUpdateReadAndGoto8Condition,
    tryFuseDroppedGlobalDataPostUpdateFromValue,
    tryFuseDroppedLocalPostUpdateGoto8AtPc,
    tryFuseDroppedLocalPostUpdateGoto8FromGet,
    tryFuseFollowingCheckedLocalPostUpdateReadAndGoto8Condition,
    tryFuseFollowingGlobalInt32Goto16Condition,
    tryFuseFollowingLocalStringLengthGtConstSliceConstBranch,
    tryFuseFollowingSameGlobalDataInt32ImmediateBinaryStore,
    tryFuseGlobalDataAdd,
    tryFuseGlobalDataInt32CompareFalseBranch,
    tryFuseGlobalDataInt32ImmediateBinary,
    tryFuseGlobalDataValueStore,
    tryFuseGlobalDateNowCall,
    tryFuseGlobalInductionInt32AddRange,
    tryFuseGlobalInt32PrefixTermsStore,
    tryFuseGlobalStringCall1NumberConst,
    tryFuseGlobalStringPercentHexAddStore,
    tryFuseGlobalUriCall1,
    tryFuseGlobalUriFourByteDecodeCountRange,
    tryFuseGoto8LocalInt32LessThanFalseBranch,
    tryFuseGoto8LocalLessThanFalseBranch,
    tryFuseHostOutputAtomLiteralCall1,
    tryFuseHostOutputAutoInitAtomCall1,
    tryFuseHostOutputCall1,
    tryFuseHostOutputLocalCall1,
    tryFuseHostOutputLocalDenseElementCall1,
    tryFuseHostOutputLocalFieldCall1,
    tryFuseHostOutputLocalFieldStrictEqUndefinedCall1,
    tryFuseHostOutputLocalImmediateCompareCall1,
    tryFuseHostOutputLocalInt32AddCall1,
    tryFuseHostOutputLocalLengthCall1,
    tryFuseHostOutputLocalSimpleNumericCall0Call1,
    tryFuseHostOutputNumberStaticLiteralCall1,
    tryFuseHostOutputStringLocalNumberCall1,
    tryFuseHostOutputStringNumberConstCall1,
    tryFuseHostOutputTypeofLocalCall1,
    tryFuseImmediateSimpleArrayMapClosure,
    tryFuseLocal0Local1DenseArrayIndexedAppend,
    tryFuseLocalDenseArrayLengthIndexedInt32SumRangeAt,
    tryFuseLocalFieldGet,
    tryFuseLocalInt32CompareBranch,
    tryFuseLocalInt32GlobalInt32AddRange,
    tryFuseLocalInt32LessThanArgFalseBranchAtPc,
    tryFuseLocalInt32LessThanArgFalseBranchFromGet,
    tryFuseLocalShortBigIntCompareBranch,
    tryFuseLocalStringAppend,
    tryFuseLocalStringFromCharCodeInt32AppendFromGet,
    tryFuseLocalStringLengthGtConstSliceConstBranchFromGet,
    tryFuseMathMinMaxPrimitiveCallFromField2,
    tryFuseNumberStaticLiteralCallFromField2,
    tryFusePercentHexGlobalStringStoreAfterPrefix,
    tryFuseRegExpTestConstStringFromField2,
    tryFuseShortLocal0Local1DenseArrayMulAndMaskAppendRange,
    tryFuseShortLocal0Local1Int32ArithmeticStoreRange,
    tryFuseShortLocalDenseArrayLengthIndexedInt32SumRange,
    tryFuseShortLocalObjectFieldUpdateAccumulateRange,
    tryFuseStringFromCharCodeInt32CallFromField2,
    tryFuseStringSliceConstLocalStoreFromField2,
    tryFuseTypedArrayFromArrayBufferConstructorSequence,
    tryFuseUriDecodeSingleFourByteStrictEqFromCharCode,
    tryFuseVarRefSimpleStringCall1GlobalIntArgument,
};

pub const fusion_count = @typeInfo(Fusion).@"enum".fields.len;

var hits: [fusion_count]u64 = @splat(0);

/// Wraps a `tryFuse*` result and forwards it unchanged. Records a hit when
/// the fusion matched (`true` / non-null payload). The counter update is
/// atomic so multi-threaded embedders (and the test262 runner workers) can
/// share the process-wide table.
pub inline fn counted(comptime tag: Fusion, result: anytype) @TypeOf(result) {
    if (comptime enabled) {
        if (isHit(result)) _ = @atomicRmw(u64, &hits[@intFromEnum(tag)], .Add, 1, .monotonic);
    }
    return result;
}

inline fn isHit(result: anytype) bool {
    return switch (@typeInfo(@TypeOf(result))) {
        .error_union => if (result) |payload| payloadHit(payload) else |_| false,
        else => payloadHit(result),
    };
}

inline fn payloadHit(payload: anytype) bool {
    return switch (@typeInfo(@TypeOf(payload))) {
        .bool => payload,
        .optional => payload != null,
        else => @compileError("unsupported tryFuse result type: " ++ @typeName(@TypeOf(payload))),
    };
}

pub fn hitCount(tag: Fusion) u64 {
    return @atomicLoad(u64, &hits[@intFromEnum(tag)], .monotonic);
}

pub fn snapshot() [fusion_count]u64 {
    var out: [fusion_count]u64 = undefined;
    for (&out, 0..) |*slot, index| slot.* = @atomicLoad(u64, &hits[index], .monotonic);
    return out;
}

pub fn tagName(index: usize) []const u8 {
    return @tagName(@as(Fusion, @enumFromInt(index)));
}

extern "c" fn close(fd: std.c.fd_t) c_int;

var append_text_buf: [32 * 1024]u8 = undefined;

/// Append the non-zero hit counts as `name count` lines to `path`. The whole
/// payload goes out in one `O_APPEND` write so dumps from concurrently
/// exiting processes (microbench harness, spawned test262 engines) stay
/// line-intact and can be summed afterwards. Uses libc directly so the `zjs`
/// CLI can call it from an `atexit` handler.
pub fn appendToFile(path: [*:0]const u8) void {
    if (comptime !enabled) return;
    const counts = snapshot();
    var text: std.Io.Writer = .fixed(&append_text_buf);
    for (counts, 0..) |count, index| {
        if (count == 0) continue;
        text.print("{s} {d}\n", .{ tagName(index), count }) catch return;
    }
    const payload = text.buffered();
    if (payload.len == 0) return;
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true }, @as(c_int, 0o644));
    if (fd < 0) return;
    defer _ = close(fd);
    _ = std.c.write(fd, payload.ptr, payload.len);
}
