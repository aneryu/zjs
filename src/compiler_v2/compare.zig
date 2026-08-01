//! QCP-1 Stage 5: fail-closed normalized comparison for dual compilation.

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const atom = @import("../core/atom.zig");
const value_mod = @import("../core/value.zig");

const JSValue = value_mod.JSValue;
const opcode = bytecode.opcode;
const op = opcode.op;

pub const Ledger = struct {
    functions_lowered: usize = 0,
    labels_created: usize = 0,
    labels_unbound: usize = 0,
    relocs_created: usize = 0,
    relocs_applied: usize = 0,
    source_markers: usize = 0,
    source_events_emitted: usize = 0,
    closure_sources_threaded: usize = 0,
};

pub const CompareOptions = struct {
    diag: bool = true,
};

pub const CompareError = error{
    OutOfMemory,
    DualCompileMismatch,
};

const Tier = enum {
    l0,
    structural,
    normalized,
};

const AtomPair = struct {
    legacy: atom.Atom,
    v2: atom.Atom,
};

const CompareState = struct {
    rt: *core.JSRuntime,
    allocator: std.mem.Allocator,
    opts: CompareOptions,
    mode: []const u8,
    atom_pairs: std.ArrayList(AtomPair) = .empty,
    failed_tier: ?Tier = null,

    fn init(rt: *core.JSRuntime, root: *const bytecode.FunctionBytecode, opts: CompareOptions) CompareState {
        return .{
            .rt = rt,
            // compile() points MemoryAccount.allocator at its parse arena. The
            // comparator's scratch must instead be individually releasable.
            .allocator = rt.memory.persistent_allocator,
            .opts = opts,
            .mode = inferMode(root),
        };
    }

    fn deinit(self: *CompareState) void {
        self.atom_pairs.deinit(self.allocator);
    }

    fn mismatch(
        self: *CompareState,
        tier: Tier,
        path: []const u8,
        field: []const u8,
        legacy: anytype,
        v2: anytype,
    ) CompareError {
        if (self.failed_tier == null) self.failed_tier = tier;
        if (self.opts.diag) {
            std.debug.print(
                "ZJS-DUAL-MISMATCH tier={s} mode={s} fn={s} field={s} legacy={any} v2={any}\n",
                .{ tierName(tier), self.mode, path, field, legacy, v2 },
            );
        }
        return error.DualCompileMismatch;
    }

    fn mismatchText(
        self: *CompareState,
        tier: Tier,
        path: []const u8,
        field: []const u8,
        legacy: []const u8,
        v2: []const u8,
    ) CompareError {
        if (self.failed_tier == null) self.failed_tier = tier;
        if (self.opts.diag) {
            std.debug.print(
                "ZJS-DUAL-MISMATCH tier={s} mode={s} fn={s} field={s} legacy={s} v2={s}\n",
                .{ tierName(tier), self.mode, path, field, legacy, v2 },
            );
        }
        return error.DualCompileMismatch;
    }

    fn mismatchBytes(
        self: *CompareState,
        tier: Tier,
        path: []const u8,
        field: []const u8,
        legacy: []const u8,
        v2: []const u8,
    ) CompareError {
        if (self.failed_tier == null) self.failed_tier = tier;
        if (self.opts.diag) {
            std.debug.print(
                "ZJS-DUAL-MISMATCH tier={s} mode={s} fn={s} field={s} legacy=len:{d}:hash:{x} v2=len:{d}:hash:{x}\n",
                .{
                    tierName(tier),
                    self.mode,
                    path,
                    field,
                    legacy.len,
                    std.hash.Wyhash.hash(0, legacy),
                    v2.len,
                    std.hash.Wyhash.hash(0, v2),
                },
            );
        }
        return error.DualCompileMismatch;
    }
};

fn tierName(tier: Tier) []const u8 {
    return switch (tier) {
        .l0 => "L0",
        .structural => "1",
        .normalized => "2",
    };
}

fn inferMode(root: *const bytecode.FunctionBytecode) []const u8 {
    if (root.isModule()) return "module";
    if (!root.isDirectOrIndirectEval()) return "script";
    // Canonical direct eval inherits its caller's ScriptOrModule identity,
    // while indirect eval owns its ordinary eval filename identity.
    return if (root.scriptOrModule() != root.filenameAtom())
        "eval_direct"
    else
        "eval_indirect";
}

pub fn compareCompiles(
    rt: *core.JSRuntime,
    legacy_root: *const bytecode.FunctionBytecode,
    v2_root: *const bytecode.FunctionBytecode,
    legacy_atom_delta: usize,
    v2_atom_delta: usize,
    ledger: Ledger,
    opts: CompareOptions,
) CompareError!void {
    var state = CompareState.init(rt, v2_root, opts);
    defer state.deinit();

    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(state.allocator);
    try path.appendSlice(state.allocator, "root");
    try appendFunctionName(&state, &path, v2_root);

    // Ordering is intentional and binding: no structural or normalized walk
    // begins until the complete L0 ledger/tree scalar pass succeeds.
    try compareL0(
        &state,
        legacy_root,
        v2_root,
        legacy_atom_delta,
        v2_atom_delta,
        ledger,
        &path,
    );
    try compareTier1(&state, legacy_root, v2_root, &path);
    try compareTier2(&state, legacy_root, v2_root, &path);
}

fn appendFunctionName(
    state: *CompareState,
    path: *std.ArrayList(u8),
    function: *const bytecode.FunctionBytecode,
) CompareError!void {
    const function_name = state.rt.atoms.name(function.funcName()) orelse return;
    if (function_name.len == 0) return;
    try path.append(state.allocator, '(');
    const visible_len = @min(function_name.len, 64);
    for (function_name[0..visible_len]) |byte| {
        const safe = if (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$' or
            byte == '.' or byte == '-') byte else '_';
        try path.append(state.allocator, safe);
    }
    if (visible_len != function_name.len) {
        var hash_buf: [24]u8 = undefined;
        const suffix = std.fmt.bufPrint(&hash_buf, "~{x}", .{std.hash.Wyhash.hash(0, function_name)}) catch
            return error.OutOfMemory;
        try path.appendSlice(state.allocator, suffix);
    }
    try path.append(state.allocator, ')');
}

fn pushChildPath(
    state: *CompareState,
    path: *std.ArrayList(u8),
    index: usize,
    function: *const bytecode.FunctionBytecode,
) CompareError!usize {
    const restore_len = path.items.len;
    var index_buf: [32]u8 = undefined;
    const segment = std.fmt.bufPrint(&index_buf, "/cpool[{d}]", .{index}) catch
        return error.OutOfMemory;
    try path.appendSlice(state.allocator, segment);
    try appendFunctionName(state, path, function);
    return restore_len;
}

fn functionBytecodeFromValue(value: JSValue) ?*const bytecode.FunctionBytecode {
    if (!value.isFunctionBytecode()) return null;
    const header = value.objectHeader() orelse return null;
    return @fieldParentPtr("header", header);
}

fn countFunctions(root: *const bytecode.FunctionBytecode) usize {
    var count: usize = 1;
    for (root.cpoolSlice()) |value| {
        if (functionBytecodeFromValue(value)) |child| count +|= countFunctions(child);
    }
    return count;
}

fn countClosureRows(root: *const bytecode.FunctionBytecode) usize {
    var count = root.closureVar().len;
    for (root.cpoolSlice()) |value| {
        if (functionBytecodeFromValue(value)) |child| count +|= countClosureRows(child);
    }
    return count;
}

const Pc2LineEvent = struct {
    pc: u32,
    line: i32,
    col: i32,
};

const Pc2LineIterator = struct {
    bytes: []const u8,
    index: usize,
    current: Pc2LineEvent,

    fn init(bytes: []const u8) error{Malformed}!Pc2LineIterator {
        var index: usize = 0;
        const stored_line = readLeb128(bytes, &index) catch return error.Malformed;
        const stored_col = readLeb128(bytes, &index) catch return error.Malformed;
        const line = std.math.cast(i32, stored_line) orelse return error.Malformed;
        const col = std.math.cast(i32, stored_col) orelse return error.Malformed;
        if (line == std.math.maxInt(i32) or col == std.math.maxInt(i32))
            return error.Malformed;
        return .{
            .bytes = bytes,
            .index = index,
            .current = .{ .pc = 0, .line = line + 1, .col = col + 1 },
        };
    }

    fn next(self: *Pc2LineIterator) error{Malformed}!?Pc2LineEvent {
        if (self.index == self.bytes.len) return null;
        if (self.index > self.bytes.len) return error.Malformed;
        const marker = self.bytes[self.index];
        self.index += 1;

        var pc = self.current.pc;
        var line = self.current.line;
        if (marker == 0) {
            const diff_pc = readLeb128(self.bytes, &self.index) catch return error.Malformed;
            const diff_line = readSleb128(self.bytes, &self.index) catch return error.Malformed;
            pc = std.math.add(u32, pc, diff_pc) catch return error.Malformed;
            line = std.math.add(i32, line, diff_line) catch return error.Malformed;
        } else {
            const adjusted: i32 = @as(i32, marker) - bytecode.pipeline_pc2line.PC2LINE_OP_FIRST;
            const diff_pc: u32 = @intCast(@divFloor(adjusted, bytecode.pipeline_pc2line.PC2LINE_RANGE));
            const diff_line = @mod(adjusted, bytecode.pipeline_pc2line.PC2LINE_RANGE) +
                bytecode.pipeline_pc2line.PC2LINE_BASE;
            pc = std.math.add(u32, pc, diff_pc) catch return error.Malformed;
            line = std.math.add(i32, line, diff_line) catch return error.Malformed;
        }
        const diff_col = readSleb128(self.bytes, &self.index) catch return error.Malformed;
        const col = std.math.add(i32, self.current.col, diff_col) catch return error.Malformed;
        self.current = .{ .pc = pc, .line = line, .col = col };
        return self.current;
    }
};

fn readLeb128(bytes: []const u8, index: *usize) error{Malformed}!u32 {
    var result: u32 = 0;
    var shift: u32 = 0;
    while (true) {
        if (index.* >= bytes.len) return error.Malformed;
        const byte = bytes[index.*];
        index.* += 1;
        const payload: u32 = byte & 0x7f;
        if (shift == 28 and payload > 0x0f) return error.Malformed;
        result |= payload << @intCast(shift);
        if (byte & 0x80 == 0) return result;
        if (shift == 28) return error.Malformed;
        shift += 7;
    }
}

fn readSleb128(bytes: []const u8, index: *usize) error{Malformed}!i32 {
    const encoded = try readLeb128(bytes, index);
    const decoded: u32 = (encoded >> 1) ^ (0 -% (encoded & 1));
    return @bitCast(decoded);
}

fn countSourceEventsTree(
    state: *CompareState,
    root: *const bytecode.FunctionBytecode,
    path: []const u8,
) CompareError!usize {
    var iterator = Pc2LineIterator.init(root.pc2lineBuf()) catch
        return state.mismatchText(.l0, path, "pc2line", "valid", "malformed");
    var count: usize = 0;
    while (iterator.next() catch
        return state.mismatchText(.l0, path, "pc2line", "valid", "malformed")) |_|
    {
        count +|= 1;
    }
    for (root.cpoolSlice()) |value| {
        if (functionBytecodeFromValue(value)) |child| {
            count +|= try countSourceEventsTree(state, child, path);
        }
    }
    return count;
}

fn compareScalar(
    state: *CompareState,
    comptime T: type,
    tier: Tier,
    path: []const u8,
    field: []const u8,
    legacy: T,
    v2: T,
) CompareError!void {
    if (legacy != v2) return state.mismatch(tier, path, field, legacy, v2);
}

fn compareL0(
    state: *CompareState,
    legacy_root: *const bytecode.FunctionBytecode,
    v2_root: *const bytecode.FunctionBytecode,
    legacy_atom_delta: usize,
    v2_atom_delta: usize,
    ledger: Ledger,
    path: *std.ArrayList(u8),
) CompareError!void {
    try compareScalar(state, usize, .l0, path.items, "atom_delta", legacy_atom_delta, v2_atom_delta);

    const legacy_functions = countFunctions(legacy_root);
    const v2_functions = countFunctions(v2_root);
    try compareScalar(state, usize, .l0, path.items, "function_count", legacy_functions, v2_functions);
    try compareScalar(state, usize, .l0, path.items, "ledger.functions_lowered", v2_functions, ledger.functions_lowered);

    if (ledger.labels_unbound != 0)
        return state.mismatch(.l0, path.items, "ledger.labels_unbound", 0, ledger.labels_unbound);
    try compareScalar(
        state,
        usize,
        .l0,
        path.items,
        "ledger.relocs_applied",
        ledger.relocs_created,
        ledger.relocs_applied,
    );
    if (ledger.source_events_emitted > ledger.source_markers) {
        return state.mismatch(
            .l0,
            path.items,
            "ledger.source_events_emitted",
            ledger.source_markers,
            ledger.source_events_emitted,
        );
    }
    try compareScalar(
        state,
        usize,
        .l0,
        path.items,
        "ledger.closure_sources_threaded",
        countClosureRows(v2_root),
        ledger.closure_sources_threaded,
    );
    try compareScalar(
        state,
        usize,
        .l0,
        path.items,
        "ledger.source_events_emitted",
        try countSourceEventsTree(state, v2_root, path.items),
        ledger.source_events_emitted,
    );

    try compareL0Tree(state, legacy_root, v2_root, path);
}

fn compareL0Tree(
    state: *CompareState,
    legacy: *const bytecode.FunctionBytecode,
    v2: *const bytecode.FunctionBytecode,
    path: *std.ArrayList(u8),
) CompareError!void {
    try compareScalar(state, usize, .l0, path.items, "closure_var_count", legacy.closureVar().len, v2.closureVar().len);
    try compareScalar(state, usize, .l0, path.items, "cpool_count", legacy.cpoolSlice().len, v2.cpoolSlice().len);
    try compareScalar(state, u16, .l0, path.items, "arg_count", legacy.arg_count, v2.arg_count);
    try compareScalar(state, u16, .l0, path.items, "var_count", legacy.var_count, v2.var_count);
    try compareScalar(state, u16, .l0, path.items, "defined_arg_count", legacy.defined_arg_count, v2.defined_arg_count);
    try compareScalar(state, u16, .l0, path.items, "stack_size", legacy.stack_size, v2.stack_size);

    for (legacy.cpoolSlice(), v2.cpoolSlice(), 0..) |legacy_value, v2_value, index| {
        const legacy_child = functionBytecodeFromValue(legacy_value) orelse continue;
        const v2_child = functionBytecodeFromValue(v2_value) orelse continue;
        const restore_len = try pushChildPath(state, path, index, v2_child);
        defer path.items.len = restore_len;
        try compareL0Tree(state, legacy_child, v2_child, path);
    }
}

fn compareAtom(
    state: *CompareState,
    tier: Tier,
    path: []const u8,
    field: []const u8,
    legacy: atom.Atom,
    v2: atom.Atom,
) CompareError!void {
    if (legacy == v2) return;
    if (legacy < atom.first_dynamic_atom or v2 < atom.first_dynamic_atom or
        legacy >= atom.tagged_int_bit or v2 >= atom.tagged_int_bit)
    {
        return state.mismatch(tier, path, field, legacy, v2);
    }

    const legacy_kind = state.rt.atoms.kind(legacy) orelse
        return state.mismatch(tier, path, field, legacy, v2);
    const v2_kind = state.rt.atoms.kind(v2) orelse
        return state.mismatch(tier, path, field, legacy, v2);
    if (legacy_kind != v2_kind)
        return state.mismatch(tier, path, field, legacy_kind, v2_kind);

    const legacy_name = state.rt.atoms.name(legacy) orelse
        return state.mismatch(tier, path, field, legacy, v2);
    const v2_name = state.rt.atoms.name(v2) orelse
        return state.mismatch(tier, path, field, legacy, v2);
    if (!std.mem.eql(u8, legacy_name, v2_name))
        return state.mismatchBytes(tier, path, field, legacy_name, v2_name);

    if (atom.isValueSymbolKind(legacy_kind)) {
        const legacy_index: usize = @intCast(legacy - atom.first_dynamic_atom);
        const v2_index: usize = @intCast(v2 - atom.first_dynamic_atom);
        if (legacy_index >= state.rt.atoms.entries.len or v2_index >= state.rt.atoms.entries.len)
            return state.mismatch(tier, path, field, legacy, v2);
        const legacy_has_no_description = state.rt.atoms.entries[legacy_index].no_symbol_description;
        const v2_has_no_description = state.rt.atoms.entries[v2_index].no_symbol_description;
        if (legacy_has_no_description != v2_has_no_description)
            return state.mismatch(tier, path, field, legacy_has_no_description, v2_has_no_description);
    }

    // Ordinary symbols and private names carry source identity, not merely a
    // description. Two parses mint different atoms, so remember the first
    // semantic pairing and reject a later many-to-one or one-to-many match.
    if (legacy_kind == .symbol or legacy_kind == .private) {
        for (state.atom_pairs.items) |pair| {
            if (pair.legacy == legacy or pair.v2 == v2) {
                if (pair.legacy != legacy or pair.v2 != v2)
                    return state.mismatch(tier, path, field, legacy, v2);
                return;
            }
        }
        try state.atom_pairs.append(state.allocator, .{ .legacy = legacy, .v2 = v2 });
    }
}

fn indexedField(buffer: []u8, prefix: []const u8, index: usize, suffix: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}[{d}].{s}", .{ prefix, index, suffix }) catch prefix;
}

fn compareTier1(
    state: *CompareState,
    legacy: *const bytecode.FunctionBytecode,
    v2: *const bytecode.FunctionBytecode,
    path: *std.ArrayList(u8),
) CompareError!void {
    try compareAtom(state, .structural, path.items, "func_name", legacy.funcName(), v2.funcName());
    try compareAtom(state, .structural, path.items, "filename", legacy.filenameAtom(), v2.filenameAtom());
    try compareAtom(state, .structural, path.items, "script_or_module", legacy.scriptOrModule(), v2.scriptOrModule());

    try compareScalar(state, bool, .structural, path.items, "flags.strict", legacy.isStrictMode(), v2.isStrictMode());
    try compareScalar(state, bool, .structural, path.items, "flags.runtime_strict", legacy.runtimeStrictMode(), v2.runtimeStrictMode());
    try compareScalar(state, u2, .structural, path.items, "flags.func_kind", @intFromEnum(legacy.functionKind()), @intFromEnum(v2.functionKind()));
    try compareScalar(state, bool, .structural, path.items, "flags.has_prototype", legacy.hasPrototype(), v2.hasPrototype());
    try compareScalar(state, bool, .structural, path.items, "flags.simple_parameters", legacy.hasSimpleParameterList(), v2.hasSimpleParameterList());
    try compareScalar(state, bool, .structural, path.items, "flags.derived_constructor", legacy.isDerivedClassConstructor(), v2.isDerivedClassConstructor());
    try compareScalar(state, bool, .structural, path.items, "flags.need_home_object", legacy.needHomeObject(), v2.needHomeObject());
    try compareScalar(state, bool, .structural, path.items, "flags.new_target", legacy.newTargetAllowed(), v2.newTargetAllowed());
    try compareScalar(state, bool, .structural, path.items, "flags.super_call", legacy.superCallAllowed(), v2.superCallAllowed());
    try compareScalar(state, bool, .structural, path.items, "flags.super", legacy.superAllowed(), v2.superAllowed());
    try compareScalar(state, bool, .structural, path.items, "flags.arguments", legacy.argumentsAllowed(), v2.argumentsAllowed());
    try compareScalar(state, bool, .structural, path.items, "flags.eval", legacy.isDirectOrIndirectEval(), v2.isDirectOrIndirectEval());
    try compareScalar(state, bool, .structural, path.items, "flags.module", legacy.isModule(), v2.isModule());
    try compareScalar(state, bool, .structural, path.items, "flags.mapped_arguments", legacy.hasMappedArguments(), v2.hasMappedArguments());
    try compareScalar(state, bool, .structural, path.items, "flags.simple_inline", legacy.simpleInlineEligible(), v2.simpleInlineEligible());
    try compareScalar(state, bool, .structural, path.items, "flags.strict_simple_inline", legacy.strictSimpleInlineEligible(), v2.strictSimpleInlineEligible());
    try compareScalar(state, bool, .structural, path.items, "flags.snapshot_inline", legacy.strictSimpleSnapshotInlineEligible(), v2.strictSimpleSnapshotInlineEligible());
    try compareScalar(state, bool, .structural, path.items, "flags.simple_empty_leaf", legacy.simpleInlineEmptyLeaf(), v2.simpleInlineEmptyLeaf());
    try compareScalar(state, bool, .structural, path.items, "flags.raw_this_empty_leaf", legacy.rawThisInlineEmptyLeaf(), v2.rawThisInlineEmptyLeaf());
    try compareScalar(state, bool, .structural, path.items, "flags.simple_exact_args_leaf", legacy.simpleInlineExactArgsLeaf(), v2.simpleInlineExactArgsLeaf());
    try compareScalar(state, bool, .structural, path.items, "flags.raw_this_exact_args_leaf", legacy.rawThisInlineExactArgsLeaf(), v2.rawThisInlineExactArgsLeaf());
    try compareScalar(state, u2, .structural, path.items, "flags.exact_args_leaf_kind", @intFromEnum(legacy.exactArgsLeafKind()), @intFromEnum(v2.exactArgsLeafKind()));
    try compareScalar(state, u2, .structural, path.items, "flags.capture_leaf_kind", @intFromEnum(legacy.captureLeafKind()), @intFromEnum(v2.captureLeafKind()));
    try compareScalar(state, bool, .structural, path.items, "flags.entry_rejects_plain_call", legacy.executionFlags().entry_rejects_plain_call, v2.executionFlags().entry_rejects_plain_call);
    try compareScalar(state, u16, .structural, path.items, "open_var_ref_count", legacy.openVarRefCount(), v2.openVarRefCount());
    try compareScalar(state, bool, .structural, path.items, "debug.present", legacy.debugInfo() != null, v2.debugInfo() != null);

    const legacy_source = legacy.sourceText();
    const v2_source = v2.sourceText();
    if ((legacy_source == null) != (v2_source == null))
        return state.mismatch(.structural, path.items, "debug.source_present", legacy_source != null, v2_source != null);
    if (legacy_source) |lhs| {
        const rhs = v2_source.?;
        if (!std.mem.eql(u8, lhs, rhs))
            return state.mismatch(
                .structural,
                path.items,
                "debug.source_hash",
                std.hash.Wyhash.hash(0, lhs),
                std.hash.Wyhash.hash(0, rhs),
            );
    }

    try compareVarDefs(state, legacy.allVarDefs(), v2.allVarDefs(), path.items);
    try compareClosureVars(state, legacy.closureVar(), v2.closureVar(), path.items);
    try compareScalar(
        state,
        usize,
        .structural,
        path.items,
        "code_atom_owner_count",
        countCodeAtomOwners(legacy),
        countCodeAtomOwners(v2),
    );

    for (legacy.cpoolSlice(), v2.cpoolSlice(), 0..) |legacy_value, v2_value, index| {
        const legacy_child = functionBytecodeFromValue(legacy_value);
        const v2_child = functionBytecodeFromValue(v2_value);
        if ((legacy_child == null) != (v2_child == null)) {
            var field_buf: [64]u8 = undefined;
            return state.mismatch(
                .structural,
                path.items,
                indexedField(&field_buf, "cpool", index, "tag"),
                legacy_value.tagOf(),
                v2_value.tagOf(),
            );
        }
        if (legacy_child) |legacy_function| {
            const restore_len = try pushChildPath(state, path, index, v2_child.?);
            defer path.items.len = restore_len;
            try compareTier1(state, legacy_function, v2_child.?, path);
            continue;
        }
        try compareConstant(state, path.items, index, legacy_value, v2_value);
    }
}

fn compareVarDefs(
    state: *CompareState,
    legacy: []const bytecode.function_bytecode.BytecodeVarDef,
    v2: []const bytecode.function_bytecode.BytecodeVarDef,
    path: []const u8,
) CompareError!void {
    for (legacy, v2, 0..) |lhs, rhs, index| {
        var field_buf: [64]u8 = undefined;
        try compareAtom(state, .structural, path, indexedField(&field_buf, "vardef", index, "name"), lhs.var_name, rhs.var_name);
        try compareScalar(state, i32, .structural, path, indexedField(&field_buf, "vardef", index, "scope_next"), lhs.scope_next, rhs.scope_next);
        try compareScalar(state, bool, .structural, path, indexedField(&field_buf, "vardef", index, "has_scope"), lhs.hasScope(), rhs.hasScope());
        try compareScalar(state, bool, .structural, path, indexedField(&field_buf, "vardef", index, "is_lexical"), lhs.isLexical(), rhs.isLexical());
        try compareScalar(state, bool, .structural, path, indexedField(&field_buf, "vardef", index, "is_const"), lhs.isConst(), rhs.isConst());
        try compareScalar(state, bool, .structural, path, indexedField(&field_buf, "vardef", index, "is_captured"), lhs.isCaptured(), rhs.isCaptured());
        try compareScalar(state, u4, .structural, path, indexedField(&field_buf, "vardef", index, "var_kind"), @intFromEnum(lhs.varKind()), @intFromEnum(rhs.varKind()));
        if (lhs.isCaptured() and rhs.isCaptured())
            try compareScalar(state, u16, .structural, path, indexedField(&field_buf, "vardef", index, "open_binding_idx"), lhs.var_ref_idx, rhs.var_ref_idx);
    }
}

fn compareClosureVars(
    state: *CompareState,
    legacy: []const bytecode.function_bytecode.BytecodeClosureVar,
    v2: []const bytecode.function_bytecode.BytecodeClosureVar,
    path: []const u8,
) CompareError!void {
    for (legacy, v2, 0..) |lhs, rhs, index| {
        var field_buf: [64]u8 = undefined;
        try compareAtom(state, .structural, path, indexedField(&field_buf, "closure", index, "name"), lhs.var_name, rhs.var_name);
        try compareScalar(state, u3, .structural, path, indexedField(&field_buf, "closure", index, "type"), @intFromEnum(lhs.closureType()), @intFromEnum(rhs.closureType()));
        try compareScalar(state, bool, .structural, path, indexedField(&field_buf, "closure", index, "is_lexical"), lhs.isLexical(), rhs.isLexical());
        try compareScalar(state, bool, .structural, path, indexedField(&field_buf, "closure", index, "is_const"), lhs.isConst(), rhs.isConst());
        try compareScalar(state, u4, .structural, path, indexedField(&field_buf, "closure", index, "var_kind"), @intFromEnum(lhs.varKind()), @intFromEnum(rhs.varKind()));
        try compareScalar(state, u16, .structural, path, indexedField(&field_buf, "closure", index, "var_idx"), lhs.var_idx, rhs.var_idx);
    }
}

fn countCodeAtomOwners(function: *const bytecode.FunctionBytecode) usize {
    var iterator = function.atomOperandIterator();
    var count: usize = 0;
    while (iterator.next() != null) count +|= 1;
    return count;
}

fn canonicalNumberBits(value: JSValue) ?u64 {
    const number = value.asNumber() orelse return null;
    if (std.math.isNan(number)) return @bitCast(std.math.nan(f64));
    return @bitCast(number);
}

fn compareConstant(
    state: *CompareState,
    path: []const u8,
    index: usize,
    legacy: JSValue,
    v2: JSValue,
) CompareError!void {
    var field_buf: [64]u8 = undefined;
    const field = indexedField(&field_buf, "cpool", index, "value");
    return compareConstantValue(state, path, field, legacy, v2, 0);
}

fn compareConstantValue(
    state: *CompareState,
    path: []const u8,
    field: []const u8,
    legacy: JSValue,
    v2: JSValue,
    depth: u8,
) CompareError!void {
    if (legacy.isNumber() or v2.isNumber()) {
        const lhs = canonicalNumberBits(legacy) orelse
            return state.mismatch(.structural, path, field, legacy.tagOf(), v2.tagOf());
        const rhs = canonicalNumberBits(v2) orelse
            return state.mismatch(.structural, path, field, legacy.tagOf(), v2.tagOf());
        if (lhs != rhs) return state.mismatch(.structural, path, field, lhs, rhs);
        return;
    }
    if (legacy.isBigInt() or v2.isBigInt()) {
        if (!legacy.isBigInt() or !v2.isBigInt() or !legacy.sameValue(v2))
            return state.mismatch(.structural, path, field, legacy.tagOf(), v2.tagOf());
        return;
    }
    if (legacy.isString() or v2.isString()) {
        if (!legacy.isString() or !v2.isString() or !legacy.sameValue(v2))
            return state.mismatch(.structural, path, field, legacy.tagOf(), v2.tagOf());
        return;
    }
    if (legacy.isSymbol() or v2.isSymbol()) {
        const lhs = legacy.asSymbolAtom() orelse
            return state.mismatch(.structural, path, field, legacy.tagOf(), v2.tagOf());
        const rhs = v2.asSymbolAtom() orelse
            return state.mismatch(.structural, path, field, legacy.tagOf(), v2.tagOf());
        return compareAtom(state, .structural, path, field, lhs, rhs);
    }
    if (legacy.isObject() or v2.isObject()) {
        if (!legacy.isObject() or !v2.isObject())
            return state.mismatch(.structural, path, field, legacy.tagOf(), v2.tagOf());
        if (depth >= 16)
            return state.mismatch(.structural, path, field, depth, depth);
        const lhs = core.Object.expect(legacy) catch
            return state.mismatch(.structural, path, field, legacy.tagOf(), v2.tagOf());
        const rhs = core.Object.expect(v2) catch
            return state.mismatch(.structural, path, field, legacy.tagOf(), v2.tagOf());
        return compareArrayConstant(state, path, field, lhs, rhs, depth + 1);
    }
    if (legacy.tagOf() != v2.tagOf() or !legacy.sameValue(v2))
        return state.mismatch(.structural, path, field, legacy.tagOf(), v2.tagOf());
}

/// Tagged-template records are the only ordinary objects published into the
/// compiler constant pool. Dual parses necessarily allocate distinct frozen
/// template/raw arrays, so object identity is not a semantic comparison. Keep
/// tier 1 fail-closed by comparing the complete own-property product instead:
/// array kind/length/extensibility, ordered keys, descriptor attributes, and
/// recursively the cooked/raw values.
fn compareArrayConstant(
    state: *CompareState,
    path: []const u8,
    field: []const u8,
    legacy: *core.Object,
    v2: *core.Object,
    depth: u8,
) CompareError!void {
    if (!legacy.isArray() or !v2.isArray())
        return state.mismatch(.structural, path, field, legacy.isArray(), v2.isArray());
    if (legacy.arrayLength() != v2.arrayLength())
        return state.mismatch(.structural, path, field, legacy.arrayLength(), v2.arrayLength());
    if (legacy.isExtensible() != v2.isExtensible())
        return state.mismatch(.structural, path, field, legacy.isExtensible(), v2.isExtensible());

    const legacy_keys = try legacy.*.ownKeys(state.rt);
    defer core.Object.freeKeys(state.rt, legacy_keys);
    const v2_keys = try v2.*.ownKeys(state.rt);
    defer core.Object.freeKeys(state.rt, v2_keys);
    if (legacy_keys.len != v2_keys.len)
        return state.mismatch(.structural, path, field, legacy_keys.len, v2_keys.len);

    for (legacy_keys, v2_keys) |legacy_key, v2_key| {
        try compareAtom(state, .structural, path, field, legacy_key, v2_key);
        const legacy_desc_opt = legacy.getOwnProperty(state.rt, legacy_key) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return state.mismatch(.structural, path, field, true, false),
        };
        const v2_desc_opt = v2.getOwnProperty(state.rt, v2_key) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return state.mismatch(.structural, path, field, false, true),
        };
        if ((legacy_desc_opt == null) != (v2_desc_opt == null))
            return state.mismatch(.structural, path, field, legacy_desc_opt != null, v2_desc_opt != null);
        var legacy_desc = legacy_desc_opt orelse continue;
        defer legacy_desc.destroy(state.rt);
        var v2_desc = v2_desc_opt.?;
        defer v2_desc.destroy(state.rt);

        if (legacy_desc.kind != v2_desc.kind)
            return state.mismatch(.structural, path, field, legacy_desc.kind, v2_desc.kind);
        if (legacy_desc.value_present != v2_desc.value_present)
            return state.mismatch(.structural, path, field, legacy_desc.value_present, v2_desc.value_present);
        if (legacy_desc.getter_present != v2_desc.getter_present)
            return state.mismatch(.structural, path, field, legacy_desc.getter_present, v2_desc.getter_present);
        if (legacy_desc.setter_present != v2_desc.setter_present)
            return state.mismatch(.structural, path, field, legacy_desc.setter_present, v2_desc.setter_present);
        if (legacy_desc.writable != v2_desc.writable)
            return state.mismatch(.structural, path, field, legacy_desc.writable, v2_desc.writable);
        if (legacy_desc.enumerable != v2_desc.enumerable)
            return state.mismatch(.structural, path, field, legacy_desc.enumerable, v2_desc.enumerable);
        if (legacy_desc.configurable != v2_desc.configurable)
            return state.mismatch(.structural, path, field, legacy_desc.configurable, v2_desc.configurable);
        // Compiler-published tagged-template arrays contain data descriptors
        // only. An accessor here is a new constant kind and must fail closed.
        if (!legacy_desc.value_present or legacy_desc.getter_present or legacy_desc.setter_present)
            return state.mismatch(.structural, path, field, legacy_desc.kind, v2_desc.kind);
        try compareConstantValue(
            state,
            path,
            field,
            legacy_desc.value,
            v2_desc.value,
            depth,
        );
    }
}

const Fold = struct {
    semantic: u8,
    implicit_operand: ?i64 = null,
    implicit_atom: ?atom.Atom = null,
};

/// Canonicalize final-form encodings. This table deliberately names every
/// compact family instead of treating the short-id interval as arithmetic:
/// the interval also contains derived semantic opcodes which remain distinct.
fn foldOpcode(op_id: u8) Fold {
    if (op_id >= op.push_minus1 and op_id <= op.push_7) {
        return .{
            .semantic = op.push_i32,
            .implicit_operand = @as(i64, op_id) - @as(i64, op.push_0),
        };
    }
    if (op_id >= op.get_loc0 and op_id <= op.get_loc3)
        return .{ .semantic = op.get_loc, .implicit_operand = op_id - op.get_loc0 };
    if (op_id >= op.put_loc0 and op_id <= op.put_loc3)
        return .{ .semantic = op.put_loc, .implicit_operand = op_id - op.put_loc0 };
    if (op_id >= op.set_loc0 and op_id <= op.set_loc3)
        return .{ .semantic = op.set_loc, .implicit_operand = op_id - op.set_loc0 };
    if (op_id >= op.get_arg0 and op_id <= op.get_arg3)
        return .{ .semantic = op.get_arg, .implicit_operand = op_id - op.get_arg0 };
    if (op_id >= op.put_arg0 and op_id <= op.put_arg3)
        return .{ .semantic = op.put_arg, .implicit_operand = op_id - op.put_arg0 };
    if (op_id >= op.set_arg0 and op_id <= op.set_arg3)
        return .{ .semantic = op.set_arg, .implicit_operand = op_id - op.set_arg0 };
    if (op_id >= op.get_var_ref0 and op_id <= op.get_var_ref3)
        return .{ .semantic = op.get_var_ref, .implicit_operand = op_id - op.get_var_ref0 };
    if (op_id >= op.put_var_ref0 and op_id <= op.put_var_ref3)
        return .{ .semantic = op.put_var_ref, .implicit_operand = op_id - op.put_var_ref0 };
    if (op_id >= op.set_var_ref0 and op_id <= op.set_var_ref3)
        return .{ .semantic = op.set_var_ref, .implicit_operand = op_id - op.set_var_ref0 };
    if (op_id >= op.call0 and op_id <= op.call3)
        return .{ .semantic = op.call, .implicit_operand = op_id - op.call0 };

    return switch (op_id) {
        op.push_i8, op.push_i16 => .{ .semantic = op.push_i32 },
        op.push_const8 => .{ .semantic = op.push_const },
        op.fclosure8 => .{ .semantic = op.fclosure },
        op.push_empty_string => .{ .semantic = op.push_atom_value, .implicit_atom = atom.ids.empty_string },
        op.get_loc8 => .{ .semantic = op.get_loc },
        op.put_loc8 => .{ .semantic = op.put_loc },
        op.set_loc8 => .{ .semantic = op.set_loc },
        op.get_length => .{ .semantic = op.get_field, .implicit_atom = atom.ids.length },
        op.if_false8 => .{ .semantic = op.if_false },
        op.if_true8 => .{ .semantic = op.if_true },
        op.goto8, op.goto16 => .{ .semantic = op.goto },
        else => .{ .semantic = op_id },
    };
}

const NormalizedInstruction = struct {
    raw_op: u8,
    semantic_op: u8,
    pc: u32,
    ordinal: u32,
    operands: [3]i64 = @splat(0),
    operand_count: u8 = 0,
    atom_id: ?atom.Atom = null,
    target_pc: ?u32 = null,
    target_ordinal: ?u32 = null,

    fn addOperand(self: *@This(), value: anytype) bool {
        if (self.operand_count == self.operands.len) return false;
        self.operands[self.operand_count] = @intCast(value);
        self.operand_count += 1;
        return true;
    }
};

const NormalizedEvent = struct {
    ordinal: u32,
    line: i32,
    col: i32,
};

const NormalizedFunction = struct {
    instructions: std.ArrayList(NormalizedInstruction) = .empty,
    events: std.ArrayList(NormalizedEvent) = .empty,
    start_line: i32 = 0,
    start_col: i32 = 0,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.instructions.deinit(allocator);
        self.events.deinit(allocator);
    }
};

fn readIntAt(comptime T: type, code: []const u8, offset: usize) ?T {
    const size = @sizeOf(T);
    if (offset > code.len or code.len - offset < size) return null;
    return std.mem.readInt(T, code[offset..][0..size], .little);
}

fn setRelativeTarget(
    instruction: *NormalizedInstruction,
    code_len: usize,
    operand_pos: usize,
    relative: i64,
) bool {
    const target = std.math.add(i64, @intCast(operand_pos), relative) catch return false;
    if (target < 0 or target > code_len) return false;
    instruction.target_pc = @intCast(target);
    return true;
}

fn decodeFunction(
    state: *CompareState,
    function: *const bytecode.FunctionBytecode,
    path: []const u8,
    side: []const u8,
) CompareError!NormalizedFunction {
    var result: NormalizedFunction = .{};
    errdefer result.deinit(state.allocator);

    const code = function.byteCode();
    var pc: usize = 0;
    while (pc < code.len) {
        const raw_op = code[pc];
        const size: usize = opcode.sizeOf(raw_op);
        if (raw_op == op.invalid or size == 0 or size > code.len - pc)
            return decoderMismatch(state, path, side, pc, "opcode_size");
        const folded = foldOpcode(raw_op);
        var instruction = NormalizedInstruction{
            .raw_op = raw_op,
            .semantic_op = folded.semantic,
            .pc = @intCast(pc),
            .ordinal = @intCast(result.instructions.items.len),
            .atom_id = folded.implicit_atom,
        };
        if (folded.implicit_operand) |operand| {
            if (!instruction.addOperand(operand))
                return decoderMismatch(state, path, side, pc, "operand_overflow");
        }

        const operand_pos = pc + 1;
        switch (opcode.formatOf(raw_op)) {
            .none => {},
            .none_int, .none_loc, .none_arg, .none_var_ref, .npopx => {
                if (folded.implicit_operand == null)
                    return decoderMismatch(state, path, side, pc, "unfolded_implicit");
            },
            .u8, .loc8, .const8 => {
                if (!instruction.addOperand(code[operand_pos]))
                    return decoderMismatch(state, path, side, pc, "operand_overflow");
            },
            .i8 => {
                if (!instruction.addOperand(@as(i8, @bitCast(code[operand_pos]))))
                    return decoderMismatch(state, path, side, pc, "operand_overflow");
            },
            .label8 => {
                const relative: i8 = @bitCast(code[operand_pos]);
                if (!setRelativeTarget(&instruction, code.len, operand_pos, relative))
                    return decoderMismatch(state, path, side, pc, "jump_target");
            },
            .u16, .npop, .loc, .arg, .var_ref => {
                const operand = readIntAt(u16, code, operand_pos) orelse
                    return decoderMismatch(state, path, side, pc, "u16_operand");
                if (!instruction.addOperand(operand))
                    return decoderMismatch(state, path, side, pc, "operand_overflow");
            },
            .i16 => {
                const operand = readIntAt(i16, code, operand_pos) orelse
                    return decoderMismatch(state, path, side, pc, "i16_operand");
                if (!instruction.addOperand(operand))
                    return decoderMismatch(state, path, side, pc, "operand_overflow");
            },
            .label16 => {
                const relative = readIntAt(i16, code, operand_pos) orelse
                    return decoderMismatch(state, path, side, pc, "label16_operand");
                if (!setRelativeTarget(&instruction, code.len, operand_pos, relative))
                    return decoderMismatch(state, path, side, pc, "jump_target");
            },
            .npop_u16 => {
                const first = readIntAt(u16, code, operand_pos) orelse
                    return decoderMismatch(state, path, side, pc, "npop_operand");
                const second = readIntAt(u16, code, operand_pos + 2) orelse
                    return decoderMismatch(state, path, side, pc, "u16_operand");
                if (!instruction.addOperand(first) or !instruction.addOperand(second))
                    return decoderMismatch(state, path, side, pc, "operand_overflow");
            },
            .u32, .@"const" => {
                const operand = readIntAt(u32, code, operand_pos) orelse
                    return decoderMismatch(state, path, side, pc, "u32_operand");
                if (!instruction.addOperand(operand))
                    return decoderMismatch(state, path, side, pc, "operand_overflow");
            },
            .i32 => {
                const operand = readIntAt(i32, code, operand_pos) orelse
                    return decoderMismatch(state, path, side, pc, "i32_operand");
                if (!instruction.addOperand(operand))
                    return decoderMismatch(state, path, side, pc, "operand_overflow");
            },
            .label => {
                const relative = readIntAt(i32, code, operand_pos) orelse
                    return decoderMismatch(state, path, side, pc, "label_operand");
                if (!setRelativeTarget(&instruction, code.len, operand_pos, relative))
                    return decoderMismatch(state, path, side, pc, "jump_target");
            },
            .atom => {
                instruction.atom_id = readIntAt(u32, code, operand_pos) orelse
                    return decoderMismatch(state, path, side, pc, "atom_operand");
            },
            .atom_u8 => {
                instruction.atom_id = readIntAt(u32, code, operand_pos) orelse
                    return decoderMismatch(state, path, side, pc, "atom_operand");
                if (!instruction.addOperand(code[operand_pos + 4]))
                    return decoderMismatch(state, path, side, pc, "operand_overflow");
            },
            .atom_u16 => {
                instruction.atom_id = readIntAt(u32, code, operand_pos) orelse
                    return decoderMismatch(state, path, side, pc, "atom_operand");
                const operand = readIntAt(u16, code, operand_pos + 4) orelse
                    return decoderMismatch(state, path, side, pc, "u16_operand");
                if (!instruction.addOperand(operand))
                    return decoderMismatch(state, path, side, pc, "operand_overflow");
            },
            .atom_label_u8, .atom_label_u16 => |format| {
                instruction.atom_id = readIntAt(u32, code, operand_pos) orelse
                    return decoderMismatch(state, path, side, pc, "atom_operand");
                const label_pos = operand_pos + 4;
                const relative = readIntAt(i32, code, label_pos) orelse
                    return decoderMismatch(state, path, side, pc, "label_operand");
                if (!setRelativeTarget(&instruction, code.len, label_pos, relative))
                    return decoderMismatch(state, path, side, pc, "jump_target");
                const trailing_pos = label_pos + 4;
                if (format == .atom_label_u8) {
                    if (!instruction.addOperand(code[trailing_pos]))
                        return decoderMismatch(state, path, side, pc, "operand_overflow");
                } else {
                    const operand = readIntAt(u16, code, trailing_pos) orelse
                        return decoderMismatch(state, path, side, pc, "u16_operand");
                    if (!instruction.addOperand(operand))
                        return decoderMismatch(state, path, side, pc, "operand_overflow");
                }
            },
            .label_u16 => {
                const relative = readIntAt(i32, code, operand_pos) orelse
                    return decoderMismatch(state, path, side, pc, "label_operand");
                if (!setRelativeTarget(&instruction, code.len, operand_pos, relative))
                    return decoderMismatch(state, path, side, pc, "jump_target");
                const operand = readIntAt(u16, code, operand_pos + 4) orelse
                    return decoderMismatch(state, path, side, pc, "u16_operand");
                if (!instruction.addOperand(operand))
                    return decoderMismatch(state, path, side, pc, "operand_overflow");
            },
        }
        try result.instructions.append(state.allocator, instruction);
        pc += size;
    }

    for (result.instructions.items) |*instruction| {
        if (instruction.target_pc) |target_pc| {
            instruction.target_ordinal = pcToOrdinal(result.instructions.items, code.len, target_pc) orelse
                return decoderMismatch(state, path, side, instruction.pc, "jump_target_boundary");
        }
    }

    var iterator = Pc2LineIterator.init(function.pc2lineBuf()) catch
        return decoderMismatch(state, path, side, 0, "pc2line_header");
    result.start_line = iterator.current.line;
    result.start_col = iterator.current.col;
    while (iterator.next() catch
        return decoderMismatch(state, path, side, 0, "pc2line_event")) |event|
    {
        const ordinal = pcToOrdinal(result.instructions.items, code.len, event.pc) orelse
            return decoderMismatch(state, path, side, event.pc, "pc2line_boundary");
        try result.events.append(state.allocator, .{
            .ordinal = ordinal,
            .line = event.line,
            .col = event.col,
        });
    }
    return result;
}

fn pcToOrdinal(
    instructions: []const NormalizedInstruction,
    code_len: usize,
    pc: u32,
) ?u32 {
    if (pc == code_len) return @intCast(instructions.len);
    var low: usize = 0;
    var high = instructions.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (instructions[middle].pc < pc)
            low = middle + 1
        else
            high = middle;
    }
    if (low < instructions.len and instructions[low].pc == pc) return @intCast(low);
    return null;
}

fn decoderMismatch(
    state: *CompareState,
    path: []const u8,
    side: []const u8,
    pc: anytype,
    reason: []const u8,
) CompareError {
    if (state.failed_tier == null) state.failed_tier = .normalized;
    if (state.opts.diag) {
        if (std.mem.eql(u8, side, "legacy")) {
            std.debug.print(
                "ZJS-DUAL-MISMATCH tier=2 mode={s} fn={s} field=decoder legacy=pc:{d}:{s} v2=valid\n",
                .{ state.mode, path, pc, reason },
            );
        } else {
            std.debug.print(
                "ZJS-DUAL-MISMATCH tier=2 mode={s} fn={s} field=decoder legacy=valid v2=pc:{d}:{s}\n",
                .{ state.mode, path, pc, reason },
            );
        }
    }
    return error.DualCompileMismatch;
}

fn firstNormalizedDifference(
    legacy: []const NormalizedInstruction,
    v2: []const NormalizedInstruction,
) usize {
    const shared_len = @min(legacy.len, v2.len);
    for (legacy[0..shared_len], v2[0..shared_len], 0..) |lhs, rhs, index| {
        if (lhs.semantic_op != rhs.semantic_op or
            lhs.operand_count != rhs.operand_count or
            lhs.atom_id != rhs.atom_id)
        {
            return index;
        }
        const operand_count: usize = lhs.operand_count;
        if (!std.mem.eql(
            i64,
            lhs.operands[0..operand_count],
            rhs.operands[0..operand_count],
        )) return index;
    }
    return shared_len;
}

fn compareTier2(
    state: *CompareState,
    legacy_function: *const bytecode.FunctionBytecode,
    v2_function: *const bytecode.FunctionBytecode,
    path: *std.ArrayList(u8),
) CompareError!void {
    var legacy = try decodeFunction(state, legacy_function, path.items, "legacy");
    defer legacy.deinit(state.allocator);
    var v2 = try decodeFunction(state, v2_function, path.items, "v2");
    defer v2.deinit(state.allocator);

    if (legacy.instructions.items.len != v2.instructions.items.len)
        return instructionMismatch(
            state,
            path.items,
            "instruction_count",
            legacy.instructions.items.len,
            v2.instructions.items.len,
            legacy.instructions.items,
            v2.instructions.items,
            firstNormalizedDifference(
                legacy.instructions.items,
                v2.instructions.items,
            ),
        );

    for (legacy.instructions.items, v2.instructions.items, 0..) |lhs, rhs, index| {
        if (lhs.semantic_op != rhs.semantic_op)
            return instructionMismatch(state, path.items, "semantic_opcode", lhs.semantic_op, rhs.semantic_op, legacy.instructions.items, v2.instructions.items, index);
        if (lhs.operand_count != rhs.operand_count)
            return instructionMismatch(state, path.items, "operand_count", lhs.operand_count, rhs.operand_count, legacy.instructions.items, v2.instructions.items, index);
        const operand_count: usize = lhs.operand_count;
        for (lhs.operands[0..operand_count], rhs.operands[0..operand_count]) |lhs_operand, rhs_operand| {
            if (lhs_operand != rhs_operand)
                return instructionMismatch(state, path.items, "operand", lhs_operand, rhs_operand, legacy.instructions.items, v2.instructions.items, index);
        }
        if ((lhs.atom_id == null) != (rhs.atom_id == null))
            return instructionMismatch(state, path.items, "atom_present", lhs.atom_id != null, rhs.atom_id != null, legacy.instructions.items, v2.instructions.items, index);
        if (lhs.atom_id) |legacy_atom| {
            compareAtom(state, .normalized, path.items, "atom", legacy_atom, rhs.atom_id.?) catch |err| {
                printContext(state, path.items, legacy.instructions.items, v2.instructions.items, index);
                return err;
            };
        }
        if (lhs.target_ordinal != rhs.target_ordinal)
            return instructionMismatch(state, path.items, "target_ordinal", lhs.target_ordinal, rhs.target_ordinal, legacy.instructions.items, v2.instructions.items, index);
    }

    if (legacy.start_line != v2.start_line)
        return instructionMismatch(state, path.items, "source.start_line", legacy.start_line, v2.start_line, legacy.instructions.items, v2.instructions.items, 0);
    if (legacy.start_col != v2.start_col)
        return instructionMismatch(state, path.items, "source.start_col", legacy.start_col, v2.start_col, legacy.instructions.items, v2.instructions.items, 0);
    if (legacy.events.items.len != v2.events.items.len) {
        const shared_event_count = @min(legacy.events.items.len, v2.events.items.len);
        var event_index: usize = 0;
        while (event_index < shared_event_count) : (event_index += 1) {
            const lhs = legacy.events.items[event_index];
            const rhs = v2.events.items[event_index];
            if (lhs.ordinal != rhs.ordinal or lhs.line != rhs.line or lhs.col != rhs.col) break;
        }
        const legacy_event: ?NormalizedEvent = if (event_index < legacy.events.items.len)
            legacy.events.items[event_index]
        else
            null;
        const v2_event: ?NormalizedEvent = if (event_index < v2.events.items.len)
            v2.events.items[event_index]
        else
            null;
        if (state.opts.diag) {
            std.debug.print(
                "ZJS-DUAL-SOURCE fn={s} event={d} legacy={any} v2={any}\n",
                .{ path.items, event_index, legacy_event, v2_event },
            );
            const source_context_start = event_index -| 3;
            const legacy_source_end = @min(legacy.events.items.len, event_index +| 4);
            const v2_source_end = @min(v2.events.items.len, event_index +| 4);
            for (legacy.events.items[source_context_start..legacy_source_end], source_context_start..) |event, index| {
                std.debug.print(
                    "ZJS-DUAL-SOURCE-CTX side=legacy fn={s} event={d} ord={d} line={d} col={d}\n",
                    .{ path.items, index, event.ordinal, event.line, event.col },
                );
            }
            for (v2.events.items[source_context_start..v2_source_end], source_context_start..) |event, index| {
                std.debug.print(
                    "ZJS-DUAL-SOURCE-CTX side=v2 fn={s} event={d} ord={d} line={d} col={d}\n",
                    .{ path.items, index, event.ordinal, event.line, event.col },
                );
            }
        }
        const context_ordinal: usize = if (legacy_event) |event|
            event.ordinal
        else if (v2_event) |event|
            event.ordinal
        else
            0;
        return instructionMismatch(state, path.items, "source_event_count", legacy.events.items.len, v2.events.items.len, legacy.instructions.items, v2.instructions.items, context_ordinal);
    }
    for (legacy.events.items, v2.events.items) |lhs, rhs| {
        if (lhs.ordinal != rhs.ordinal)
            return instructionMismatch(state, path.items, "source.ordinal", lhs.ordinal, rhs.ordinal, legacy.instructions.items, v2.instructions.items, lhs.ordinal);
        if (lhs.line != rhs.line)
            return instructionMismatch(state, path.items, "source.line", lhs.line, rhs.line, legacy.instructions.items, v2.instructions.items, lhs.ordinal);
        if (lhs.col != rhs.col)
            return instructionMismatch(state, path.items, "source.col", lhs.col, rhs.col, legacy.instructions.items, v2.instructions.items, lhs.ordinal);
    }

    for (legacy_function.cpoolSlice(), v2_function.cpoolSlice(), 0..) |legacy_value, v2_value, index| {
        const legacy_child = functionBytecodeFromValue(legacy_value) orelse continue;
        const v2_child = functionBytecodeFromValue(v2_value) orelse unreachable;
        const restore_len = try pushChildPath(state, path, index, v2_child);
        defer path.items.len = restore_len;
        try compareTier2(state, legacy_child, v2_child, path);
    }
}

fn instructionMismatch(
    state: *CompareState,
    path: []const u8,
    field: []const u8,
    legacy: anytype,
    v2: anytype,
    legacy_instructions: []const NormalizedInstruction,
    v2_instructions: []const NormalizedInstruction,
    ordinal: usize,
) CompareError {
    const mismatch = state.mismatch(.normalized, path, field, legacy, v2);
    printContext(state, path, legacy_instructions, v2_instructions, ordinal);
    return mismatch;
}

fn printContext(
    state: *CompareState,
    path: []const u8,
    legacy: []const NormalizedInstruction,
    v2: []const NormalizedInstruction,
    ordinal: usize,
) void {
    if (!state.opts.diag) return;
    printContextSide(path, "legacy", legacy, ordinal);
    printContextSide(path, "v2", v2, ordinal);
}

fn printContextSide(
    path: []const u8,
    side: []const u8,
    instructions: []const NormalizedInstruction,
    ordinal: usize,
) void {
    const start = ordinal -| 4;
    const end = @min(instructions.len, ordinal +| 5);
    for (instructions[start..end]) |instruction| {
        std.debug.print(
            "ZJS-DUAL-CTX side={s} fn={s} ord={d} pc={d} raw={s} semantic={s} operands={any} atom={any} target={any}\n",
            .{
                side,
                path,
                instruction.ordinal,
                instruction.pc,
                opcode.nameOf(instruction.raw_op),
                opcode.nameOf(instruction.semantic_op),
                instruction.operands[0..instruction.operand_count],
                instruction.atom_id,
                instruction.target_ordinal,
            },
        );
    }
}

fn ledgerForFinalTree(root: *const bytecode.FunctionBytecode) CompareError!Ledger {
    var ledger: Ledger = .{
        .functions_lowered = countFunctions(root),
        .closure_sources_threaded = countClosureRows(root),
    };
    var scratch_state = CompareState.init(root.realmContext().?.runtime, root, .{ .diag = false });
    defer scratch_state.deinit();
    ledger.source_events_emitted = try countSourceEventsTree(&scratch_state, root, "root");
    // A final product cannot recover how many identical markers the encoder
    // coalesced. For comparator tests, the minimal valid marker ledger is one
    // marker per emitted event.
    ledger.source_markers = ledger.source_events_emitted;
    return ledger;
}

fn expectedShortSemantic(op_id: u8) ?u8 {
    if (op_id >= op.push_minus1 and op_id <= op.push_7) return op.push_i32;
    if (op_id >= op.get_loc0 and op_id <= op.get_loc3) return op.get_loc;
    if (op_id >= op.put_loc0 and op_id <= op.put_loc3) return op.put_loc;
    if (op_id >= op.set_loc0 and op_id <= op.set_loc3) return op.set_loc;
    if (op_id >= op.get_arg0 and op_id <= op.get_arg3) return op.get_arg;
    if (op_id >= op.put_arg0 and op_id <= op.put_arg3) return op.put_arg;
    if (op_id >= op.set_arg0 and op_id <= op.set_arg3) return op.set_arg;
    if (op_id >= op.get_var_ref0 and op_id <= op.get_var_ref3) return op.get_var_ref;
    if (op_id >= op.put_var_ref0 and op_id <= op.put_var_ref3) return op.put_var_ref;
    if (op_id >= op.set_var_ref0 and op_id <= op.set_var_ref3) return op.set_var_ref;
    if (op_id >= op.call0 and op_id <= op.call3) return op.call;
    return switch (op_id) {
        op.push_i8, op.push_i16 => op.push_i32,
        op.push_const8 => op.push_const,
        op.fclosure8 => op.fclosure,
        op.push_empty_string => op.push_atom_value,
        op.get_loc8 => op.get_loc,
        op.put_loc8 => op.put_loc,
        op.set_loc8 => op.set_loc,
        op.get_length => op.get_field,
        op.if_false8 => op.if_false,
        op.if_true8 => op.if_true,
        op.goto8, op.goto16 => op.goto,
        // These are compact derived semantic operations with no wider
        // encoding. Their canonical semantic identity is themselves.
        op.is_undefined,
        op.is_null,
        op.typeof_is_undefined,
        op.typeof_is_function,
        => op_id,
        else => null,
    };
}

test "compiler_v2.compare: independently compiled identical trees pass" {
    const parser = @import("../parser.zig");

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const realm = try core.RealmContext.create(rt);
    defer realm.destroy();

    const before_first = atomStrongRefTotalForTest(rt);
    var first = try parser.compile(
        .{ .realm = realm },
        "true;",
        .{ .mode = .script, .filename = "compiler-v2-compare.js", .return_completion = true },
    );
    defer first.deinit();
    try std.testing.expect(first.syntax_error == null);
    const after_first = atomStrongRefTotalForTest(rt);

    var second = try parser.compile(
        .{ .realm = realm },
        "true;",
        .{ .mode = .script, .filename = "compiler-v2-compare.js", .return_completion = true },
    );
    defer second.deinit();
    try std.testing.expect(second.syntax_error == null);
    const after_second = atomStrongRefTotalForTest(rt);

    const first_root = first.functionBytecode() orelse return error.TestExpectedEqual;
    const second_root = second.functionBytecode() orelse return error.TestExpectedEqual;
    try std.testing.expect(after_first >= before_first);
    try std.testing.expect(after_second >= after_first);
    try compareCompiles(
        rt,
        first_root,
        second_root,
        after_first - before_first,
        after_second - after_first,
        try ledgerForFinalTree(second_root),
        .{ .diag = false },
    );
}

fn makeTaggedTemplateConstantForTest(rt: *core.JSRuntime, cooked: i32, raw: i32) !JSValue {
    const template = try core.Object.createArray(rt, null);
    const template_value = template.value();
    errdefer template_value.free(rt);
    const raw_array = try core.Object.createArray(rt, null);
    const raw_value = raw_array.value();
    var raw_owned = true;
    defer if (raw_owned) raw_value.free(rt);

    const raw_atom = try rt.atoms.internString("raw");
    defer rt.atoms.free(raw_atom);
    try template.defineOwnProperty(rt, raw_atom, core.Descriptor.data(raw_value, false, false, false));
    try template.defineOwnProperty(rt, atom.atomFromUInt32(0), core.Descriptor.data(JSValue.int32(cooked), true, true, true));
    try raw_array.defineOwnProperty(rt, atom.atomFromUInt32(0), core.Descriptor.data(JSValue.int32(raw), true, true, true));
    try raw_array.freeze(rt);
    try template.freeze(rt);

    raw_value.free(rt);
    raw_owned = false;
    return template_value;
}

test "compiler_v2.compare: tagged-template constants compare by frozen array product" {
    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();

    const first = try makeTaggedTemplateConstantForTest(rt, 1, 2);
    defer first.free(rt);
    const second = try makeTaggedTemplateConstantForTest(rt, 1, 2);
    defer second.free(rt);
    const perturbed = try makeTaggedTemplateConstantForTest(rt, 1, 3);
    defer perturbed.free(rt);

    var state = CompareState{
        .rt = rt,
        .allocator = rt.memory.persistent_allocator,
        .opts = .{ .diag = false },
        .mode = "script",
    };
    defer state.deinit();
    try compareConstantValue(&state, "root", "cpool[0].value", first, second, 0);
    state.failed_tier = null;
    try std.testing.expectError(
        error.DualCompileMismatch,
        compareConstantValue(&state, "root", "cpool[0].value", first, perturbed, 0),
    );
    try std.testing.expectEqual(Tier.structural, state.failed_tier.?);
}

test "compiler_v2.compare: code perturbation first fails tier 2" {
    const parser = @import("../parser.zig");

    const rt = try core.JSRuntime.create(std.testing.allocator);
    defer rt.destroy();
    const realm = try core.RealmContext.create(rt);
    defer realm.destroy();

    const before_first = atomStrongRefTotalForTest(rt);
    var first = try parser.compile(
        .{ .realm = realm },
        "true;",
        .{ .mode = .script, .filename = "compiler-v2-compare-perturb.js", .return_completion = true },
    );
    defer first.deinit();
    const after_first = atomStrongRefTotalForTest(rt);
    var second = try parser.compile(
        .{ .realm = realm },
        "true;",
        .{ .mode = .script, .filename = "compiler-v2-compare-perturb.js", .return_completion = true },
    );
    defer second.deinit();
    const after_second = atomStrongRefTotalForTest(rt);

    const first_root = first.functionBytecode() orelse return error.TestExpectedEqual;
    const second_root = second.functionBytecode() orelse return error.TestExpectedEqual;
    const code = second_root.byteCode();
    const perturb_pc = std.mem.indexOfScalar(u8, code, op.push_true) orelse
        return error.TestExpectedEqual;
    code[perturb_pc] = op.push_false;
    defer code[perturb_pc] = op.push_true;

    var state = CompareState.init(rt, second_root, .{ .diag = false });
    defer state.deinit();
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(state.allocator);
    try path.appendSlice(state.allocator, "root");
    const ledger = try ledgerForFinalTree(second_root);
    try compareL0(
        &state,
        first_root,
        second_root,
        after_first - before_first,
        after_second - after_first,
        ledger,
        &path,
    );
    try compareTier1(&state, first_root, second_root, &path);
    try std.testing.expectError(
        error.DualCompileMismatch,
        compareTier2(&state, first_root, second_root, &path),
    );
    try std.testing.expectEqual(Tier.normalized, state.failed_tier.?);
}

test "compiler_v2.compare: every final short opcode has a semantic fold" {
    var op_id: u16 = op.push_minus1;
    while (op_id <= op.typeof_is_function) : (op_id += 1) {
        const short_op: u8 = @intCast(op_id);
        const expected = expectedShortSemantic(short_op) orelse
            return error.TestExpectedEqual;
        try std.testing.expectEqual(expected, foldOpcode(short_op).semantic);
    }

    try std.testing.expectEqual(@as(?i64, -1), foldOpcode(op.push_minus1).implicit_operand);
    try std.testing.expectEqual(@as(?i64, 7), foldOpcode(op.push_7).implicit_operand);
    try std.testing.expectEqual(@as(?i64, 3), foldOpcode(op.call3).implicit_operand);
    try std.testing.expectEqual(@as(?atom.Atom, atom.ids.empty_string), foldOpcode(op.push_empty_string).implicit_atom);
    try std.testing.expectEqual(@as(?atom.Atom, atom.ids.length), foldOpcode(op.get_length).implicit_atom);
}

fn atomStrongRefTotalForTest(rt: *const core.JSRuntime) usize {
    var total: usize = 0;
    for (rt.atoms.entries) |entry| total +|= entry.strongRefCount();
    return total;
}
