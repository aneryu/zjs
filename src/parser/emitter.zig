//! The `Emitter` facade over the Builder, control-flow frames, break/continue/return/finally lowering, and using-declaration cleanup.

const std = @import("std");
const root = @import("../parser.zig");
const bytecode = @import("../bytecode.zig");
const atom_module = @import("../core/atom.zig");
const core = @import("../core/root.zig");
const array_list_erased = @import("../core/array_list_erased.zig");
const JSValue = @import("../core/value.zig").JSValue;
const compiler = @import("../compiler/root.zig");
const opcode = bytecode.opcode;
const Atom = atom_module.Atom;
const parse_state = @import("parse_state.zig");
const declarations = @import("declarations.zig");
const identifiers = @import("identifiers.zig");
const lookahead = @import("lookahead.zig");
const expressions = @import("expressions.zig");
const statements = @import("statements.zig");
const functions = @import("functions.zig");
const classes = @import("classes.zig");
const modules = @import("modules.zig");
const typescript = @import("typescript.zig");
const atom_this = parse_state.atom_this;
const shared_iterator_close_marker = parse_state.shared_iterator_close_marker;
const direct_iterator_close_marker = parse_state.direct_iterator_close_marker;
const FinallyLabel = parse_state.FinallyLabel;
const SourcePosition = parse_state.SourcePosition;
const Error = parse_state.Error;
const BlockEnv = parse_state.BlockEnv;
const ReturnFinallyBoundary = parse_state.ReturnFinallyBoundary;
const FinallyControlTarget = parse_state.FinallyControlTarget;
const State = parse_state.State;

// ---------------------------------------------------------------------------
// The raw sink under `Emitter`: the Builder calls. Grammar code never
// calls these; it goes through `Emitter`.
// ---------------------------------------------------------------------------

/// Record the (line,col) authority for the next emitted opcode.
/// The Builder ignores non-positive coordinates.
fn builderAddSourceMarker(s: *State, line_num: u32, col_num: u32) Error!void {
    const v2b = s.activeBuilder();
    if (v2b.source_len != 0) {
        const previous = v2b.source_slots[v2b.source_len - 1];
        // QuickJS compares the last explicit source pointer and does
        // not emit a second OP_line_num for the same grammar site.
        if (previous.line == @as(i32, @intCast(line_num)) and
            previous.col == @as(i32, @intCast(col_num))) return;
    }
    try v2b.addSourceMarker(@intCast(line_num), @intCast(col_num));
}

/// QuickJS-style plain opcode emission: grammar productions add source
/// markers explicitly; `emit_op()` itself is source-less.
fn builderEmitOp(s: *State, op_id: u8) Error!void {
    try s.activeBuilder().emitOp(op_id);
}

/// Source-less immediate emitters, matching QuickJS emit_op + emit_u*.
fn builderEmitOpU8(s: *State, op_id: u8, val: u8) Error!void {
    try s.activeBuilder().emitOpU8(op_id, val);
}

fn builderEmitOpU16(s: *State, op_id: u8, val: u16) Error!void {
    try s.activeBuilder().emitOpU16(op_id, val);
}

fn builderEmitOpU32(s: *State, op_id: u8, val: u32) Error!void {
    try s.activeBuilder().emitOpU32(op_id, val);
}

fn builderEmitOpI32(s: *State, op_id: u8, val: i32) Error!void {
    try s.activeBuilder().emitOpI32(op_id, val);
}

/// Source-less owned-atom emission. The grammar site owns any source
/// marker; the Builder sink owns `atom_id` on every outcome.
fn builderEmitAtomOpOwned(s: *State, op_id: u8, atom_id: Atom) Error!void {
    try s.activeBuilder().emitAtomOpOwned(op_id, atom_id);
}

fn builderEmitAtomOpU8Owned(s: *State, op_id: u8, atom_id: Atom, val: u8) Error!void {
    try s.activeBuilder().emitAtomOpU8Owned(op_id, atom_id, val);
}

fn builderEmitAtomOpU16Owned(s: *State, op_id: u8, atom_id: Atom, val: u16) Error!void {
    try s.activeBuilder().emitAtomOpU16Owned(op_id, atom_id, val);
}

/// QuickJS `emit_goto()` is source-less. The LabelId operand remains
/// pending until resolve_labels.
fn builderEmitJump(s: *State, op_id: u8, label: compiler.LabelId) Error!void {
    try s.activeBuilder().emitJump(op_id, label);
}

fn builderNewLabel(s: *State) Error!compiler.LabelId {
    return s.activeBuilder().newLabel();
}

/// Bind `label` at the current v2 position. A bound label is a
/// control-flow merge: forget the last opcode, exactly as qjs
/// emit_label leaves OP_label as the visible last opcode so no
/// peephole fuses across the join (quickjs.c emit_label /
/// fd->last_opcode_pos).
fn builderBindLabel(s: *State, label: compiler.LabelId) Error!void {
    const v2b = s.activeBuilder();
    try v2b.bindLabel(label);
    v2b.invalidateLastOpcode();
}

/// Bind the identity analogue of a physical parser `OP_label`.
/// Besides invalidating last-opcode provenance, this preserves the
/// sequential-peephole barrier after the label loses all references.
fn builderBindParserLabel(s: *State, label: compiler.LabelId) Error!void {
    const v2b = s.activeBuilder();
    try v2b.bindLabelMatchBarrier(label);
    v2b.invalidateLastOpcode();
}

/// One patch-label identity.
///
/// A `Label` is a real `LabelId` from the identity model; unbound until
/// `bind`, and any jump that references it before then is a relocation the
/// resolver patches.
/// The emission interface the parser speaks: `Emitter.<verb>(state, ...)`.
///
/// A namespace of functions over `*State`, deliberately NOT a value type:
/// a `struct { s: *State }` receiver costs one materialised temporary per
/// call site in Debug, which is enough to overflow a 64 KiB native stack.
/// The Builder error set is a subset of `Error`, so calls are plain `try`;
/// the hottest walks stay outlined (`noinline`) because every inline copy
/// costs machine code. Grammar sites own source markers: the `NoSource`
/// spellings are the same walk and only document that QuickJS emits that
/// opcode without a source event.
///
/// Labels are plain `compiler.LabelId`s. `bind` forgets the last opcode
/// (a control-flow merge, qjs emit_label); `bindRaw` keeps it visible as
/// call/delete provenance (qjs emit_label_raw); the `Parser` pair is the
/// physical-label family that survives into the stream as an `OP_label`
/// marker with its Stage-4 match barrier.
pub const Emitter = struct {
    pub fn newLabel(s: *State) Error!compiler.LabelId {
        return builderNewLabel(s);
    }
    pub fn jump(s: *State, op_id: u8, label: compiler.LabelId) Error!void {
        try builderEmitJump(s, op_id, label);
    }
    pub fn jumpNoSource(s: *State, op_id: u8, label: compiler.LabelId) Error!void {
        return jump(s, op_id, label);
    }
    pub fn bind(s: *State, label: compiler.LabelId) Error!void {
        try builderBindLabel(s, label);
    }
    pub fn bindRaw(s: *State, label: compiler.LabelId) Error!void {
        try s.activeBuilder().bindLabel(label);
    }
    pub fn bindParser(s: *State, label: compiler.LabelId) Error!void {
        try builderBindParserLabel(s, label);
    }
    pub fn bindParserRaw(s: *State, label: compiler.LabelId) Error!void {
        try s.activeBuilder().bindLabelMatchBarrier(label);
    }
    /// Redirect a pending jump to a boundary bound elsewhere. Emits nothing
    /// and keeps the last opcode: no merge happens here (qjs patchJumpTarget).
    pub fn retargetLabel(s: *State, from: compiler.LabelId, to: compiler.LabelId) Error!void {
        try s.activeBuilder().retargetLabelRefs(from, to);
    }

    pub noinline fn op(s: *State, op_id: u8) Error!void {
        try builderEmitOp(s, op_id);
    }
    pub inline fn opNoSource(s: *State, op_id: u8) Error!void {
        return op(s, op_id);
    }
    /// One opcode pinned to an explicit source event (assignment/update).
    pub inline fn opAt(s: *State, op_id: u8, line_num: u32, col_num: u32) Error!void {
        try builderAddSourceMarker(s, line_num, col_num);
        return op(s, op_id);
    }
    pub fn opU8(s: *State, op_id: u8, val: u8) Error!void {
        try builderEmitOpU8(s, op_id, val);
    }
    /// Cold-plane carrier opcode plus its sub byte; the demoted opcode had
    /// no source marker of its own.
    pub fn opU8NoSource(s: *State, op_id: u8, val: u8) Error!void {
        try s.activeBuilder().emitOpU8(op_id, val);
    }
    pub noinline fn opU16(s: *State, op_id: u8, val: u16) Error!void {
        try builderEmitOpU16(s, op_id, val);
    }
    pub inline fn opU16NoSource(s: *State, op_id: u8, val: u16) Error!void {
        return opU16(s, op_id, val);
    }
    /// Explicit source marker followed by the compact u16 instruction, as
    /// one rollback transaction.
    pub fn opU16At(s: *State, op_id: u8, val: u16, line_num: u32, col_num: u32) Error!void {
        const v2b = s.activeBuilder();
        const snapshot = v2b.snapshot();
        errdefer v2b.rollback(snapshot);
        try addSourceMarker(s, line_num, col_num);
        try v2b.emitOpU16(op_id, val);
    }
    /// `call` / `call_method` family: `argc:u16`. Source-less: qjs pins the
    /// call's one source event on the callee.
    pub fn callOp(s: *State, op_id: u8, argc: u16) Error!void {
        try s.activeBuilder().emitOpU16(op_id, argc);
    }
    pub fn opU32(s: *State, op_id: u8, val: u32) Error!void {
        try builderEmitOpU32(s, op_id, val);
    }
    pub fn opU32NoSource(s: *State, op_id: u8, val: u32) Error!void {
        try s.activeBuilder().emitOpU32(op_id, val);
    }
    /// QuickJS emits the signed literal payload directly after OP_push_i32
    pub fn opI32(s: *State, op_id: u8, val: i32) Error!void {
        try builderEmitOpI32(s, op_id, val);
    }
    pub fn opAtom(s: *State, op_id: u8, atom_id: Atom) Error!void {
        try builderEmitAtomOpOwned(s, op_id, atom_id);
    }
    pub fn opAtomNoSource(s: *State, op_id: u8, atom_id: Atom) Error!void {
        try s.activeBuilder().emitAtomOpOwned(op_id, atom_id);
    }
    pub fn opAtomU8(s: *State, op_id: u8, atom_id: Atom, val: u8) Error!void {
        try builderEmitAtomOpU8Owned(s, op_id, atom_id, val);
    }
    pub inline fn opAtomU16(s: *State, op_id: u8, atom_id: Atom, val: u16) Error!void {
        return builderEmitAtomOpU16Owned(s, op_id, atom_id, val);
    }
    pub fn opAtomU16NoSource(s: *State, op_id: u8, atom_id: Atom, val: u16) Error!void {
        try s.activeBuilder().emitAtomOpU16Owned(op_id, atom_id, val);
    }
    /// qjs get_lvalue OP_scope_make_ref: atom, aux32 LabelId operand,
    /// scope operand; no marker.
    pub fn scopeRefOp(s: *State, op_id: u8, atom_id: Atom, label: compiler.LabelId, scope: u16) Error!void {
        try s.activeBuilder().emitScopeRefOpOwned(op_id, atom_id, label, scope);
    }
    /// Publish the placeholder instruction first, then append the value and
    /// patch its cpool index: QuickJS emit_push_const ordering
    ///, and a Builder rollback removes the
    /// instruction if the cpool grow fails.
    pub noinline fn pushConst(s: *State, value: JSValue) Error!void {
        const v2b = s.activeBuilder();
        const snapshot = v2b.snapshot();
        errdefer v2b.rollback(snapshot);
        try opU32(s, opcode.op.push_const, 0);
        const opcode_pos: usize = v2b.last_opcode_pos.?;
        const idx = try s.curFunc().appendCpool(value);
        std.mem.writeInt(u32, v2b.code[opcode_pos + 1 ..][0..4], idx, .little);
    }
    /// An explicit source event that one or more NoSource instructions
    /// follow; the caller owns the surrounding Builder transaction.
    pub fn addSourceMarker(s: *State, line_num: u32, col_num: u32) Error!void {
        try builderAddSourceMarker(s, line_num, col_num);
    }
    pub fn detachTail(s: *State, mark: compiler.builder.Snapshot) Error!compiler.builder.DetachedSegment {
        return s.activeBuilder().detachTail(mark);
    }
    /// Moved code keeps code and atom ownership while its parser source
    /// slots are discarded; the splice does not replay them (class runtime
    /// and for-update chunks both use that contract).
    pub fn discardDetachedSources(s: *State, seg: *compiler.builder.DetachedSegment) void {
        const sources = seg.sources;
        seg.sources = &.{};
        if (sources.len != 0) s.memory.free(compiler.builder.SourceSlot, sources);
    }
    pub fn spliceSegment(s: *State, seg: *compiler.builder.DetachedSegment) Error!void {
        try s.activeBuilder().spliceSegment(seg);
    }
};

/// The parser's direct counterpart of QuickJS `emit_source_pos()`. Plain
/// emitters never infer a location; only grammar sites call this helper.
pub fn emitGrammarSource(s: *State, source: SourcePosition) Error!void {
    try Emitter.addSourceMarker(s, source.line_num, source.col_num);
}

pub fn pushBreakFrame(s: *State) Error!void {
    try s.break_frame_lens.append(s.memory.allocator, s.break_fixups.items.len);
    try s.continue_frame_lens.append(s.memory.allocator, s.continue_fixups.items.len);
    try s.continue_frame_break_frame_indices.append(s.memory.allocator, s.break_frame_lens.items.len - 1);
    try s.break_frame_catch_marker_depths.append(s.memory.allocator, s.active_catch_marker_depth);
    try s.break_frame_cleanup_drops.append(s.memory.allocator, 0);
    try s.break_frame_cross_cleanup_drops.append(s.memory.allocator, 0);
    try s.continue_frame_catch_marker_depths.append(s.memory.allocator, s.active_catch_marker_depth);
    try s.continue_frame_cleanup_drops.append(s.memory.allocator, 0);
    // qjs push_break_entry order: label_cont first, then label_break.
    try array_list_erased.append(&s.continue_frame_labels, s.memory.allocator, try Emitter.newLabel(s));
    try array_list_erased.append(&s.break_frame_labels, s.memory.allocator, try Emitter.newLabel(s));
}

pub fn pushBreakOnlyFrame(s: *State) Error!void {
    try s.break_frame_lens.append(s.memory.allocator, s.break_fixups.items.len);
    try s.break_frame_catch_marker_depths.append(s.memory.allocator, s.active_catch_marker_depth);
    try s.break_frame_cleanup_drops.append(s.memory.allocator, 0);
    try s.break_frame_cross_cleanup_drops.append(s.memory.allocator, 0);
    try array_list_erased.append(&s.break_frame_labels, s.memory.allocator, try Emitter.newLabel(s));
}

/// Put a real break/continue target in the same ordered environment chain
/// that already carries iterator and shared-finally-body cleanup.  Jump
/// operands remain owned by the existing fixup lists; the `has_*_target`
/// flags say which targets this environment provides.
/// What a break/continue frame protects: mirrors the arguments of QuickJS
/// `push_break_entry`.
pub const ControlBlockOptions = struct {
    label: ?Atom = null,
    has_break_target: bool = false,
    has_continue_target: bool = false,
    /// A labelled ordinary statement rather than a loop or switch.
    is_regular_stmt: bool = false,
    scope_level: i32,
    /// Stack values a `break` out of this frame must drop.
    drop_count: i32 = 0,
    has_iterator: bool = false,
};

pub fn pushControlBlock(s: *State, block: *BlockEnv, options: ControlBlockOptions) void {
    block.* = .{
        .prev = s.top_break,
        .label_name = options.label,
        .has_break_target = options.has_break_target,
        .has_continue_target = options.has_continue_target,
        .drop_count = options.drop_count,
        .scope_level = options.scope_level,
        .catch_marker_depth = s.active_catch_marker_depth,
        .has_iterator = options.has_iterator,
        .is_regular_stmt = options.is_regular_stmt,
    };
    s.top_break = block;
}

pub fn popControlBlock(s: *State, block: *BlockEnv) void {
    std.debug.assert(s.top_break == block);
    s.top_break = block.prev;
}

pub fn setCurrentBreakCleanupDrops(s: *State, drops: u8) void {
    if (s.break_frame_cleanup_drops.items.len == 0) return;
    s.break_frame_cleanup_drops.items[s.break_frame_cleanup_drops.items.len - 1] = drops;
    s.break_frame_cross_cleanup_drops.items[s.break_frame_cross_cleanup_drops.items.len - 1] = drops;
}

pub fn setCurrentBreakCrossCleanupDrops(s: *State, drops: u8) void {
    if (s.break_frame_cross_cleanup_drops.items.len == 0) return;
    s.break_frame_cross_cleanup_drops.items[s.break_frame_cross_cleanup_drops.items.len - 1] = drops;
}

fn emitUnlabelledBreakCleanup(s: *State, cleanup_drops: u8) Error!void {
    if (cleanup_drops == shared_iterator_close_marker) return;
    try emitCrossFrameCleanup(s, cleanup_drops);
}

fn emitCrossFrameCleanup(s: *State, cleanup_drops: u8) Error!void {
    if (cleanup_drops == shared_iterator_close_marker or cleanup_drops == direct_iterator_close_marker) {
        try Emitter.opNoSource(s, opcode.op.iterator_close);
        return;
    }
    var remaining = cleanup_drops;
    while (remaining > 0) : (remaining -= 1) {
        try Emitter.opNoSource(s, opcode.op.drop);
    }
}

fn emitCatchMarkerDropsFromDepth(s: *State, current_depth: *u32, target_depth: u32) Error!void {
    if (current_depth.* < target_depth) return Error.ParserInvariant;
    while (current_depth.* > target_depth) {
        // qjs abrupt cleanup: drop each crossed catch-marker slot without a source marker.
        try Emitter.opNoSource(s, opcode.op.drop);
        try emitUsingDisposesForCatchMarkerDepth(s, current_depth.*);
        current_depth.* -= 1;
    }
}

pub fn emitUsingDisposesForCatchMarkerDepth(s: *State, depth: u32) Error!void {
    var i = s.using_block_frames.items.len;
    while (i != 0) {
        i -= 1;
        const frame = s.using_block_frames.items[i];
        if (frame.catch_marker_depth != depth) continue;
        const stack_loc = frame.stack_loc orelse continue;
        try statements.emitUsingDisposeStack(s, stack_loc, frame.seen_async_hint);
        try s.emitCloseLoc(stack_loc);
    }
}

pub fn emitUnlabelledBreak(s: *State) Error!void {
    if (s.break_frame_lens.items.len == 0) return;
    try emitControlThroughFinally(s, .{ .kind = .@"break" });
}

pub fn emitUnlabelledContinue(s: *State) Error!void {
    if (s.continue_frame_lens.items.len == 0) return;
    try emitControlThroughFinally(s, .{ .kind = .@"continue" });
}

pub fn enterSwitchContinueCleanup(s: *State) void {
    for (s.continue_frame_cleanup_drops.items) |*drops| {
        if (drops.* != shared_iterator_close_marker and drops.* != direct_iterator_close_marker) drops.* += 1;
    }
}

pub fn leaveSwitchContinueCleanup(s: *State) void {
    for (s.continue_frame_cleanup_drops.items) |*drops| {
        if (drops.* != shared_iterator_close_marker and drops.* != direct_iterator_close_marker and drops.* > 0) drops.* -= 1;
    }
}

/// qjs js_is_live_code over the temp stream:
/// get_prev_opcode is
/// Builder.last_opcode_pos (every emitterBindLabel invalidated it, so any merge
/// bound at the current end already answers live, exactly like qjs OP_label
/// being the visible prev opcode). The ref_count scan covers raw binds
/// (emitterBindLabelRaw keeps call/delete provenance): a referenced label BOUND
/// exactly at the current end is an incoming edge (the legacy
/// max_absolute_target >= tail_start answer). Labels not yet bound are
/// future handler/exit targets and are NOT incoming edges — the twin of the
/// legacy tagged-parser-label exclusion.
pub fn isLiveCode(s: *State) bool {
    const v2b = s.activeBuilder();
    const live = blk: {
        const last_pos = v2b.last_opcode_pos orelse break :blk true;
        break :blk switch (v2b.code[last_pos]) {
            opcode.op.goto,
            opcode.op.@"return",
            opcode.op.return_undef,
            opcode.op.return_async,
            opcode.op.tail_call,
            opcode.op.tail_call_method,
            opcode.op.throw,
            opcode.op.throw_error,
            opcode.op.ret,
            => false,
            else => true,
        };
    };
    if (live) return true;
    var label_index: u32 = 0;
    while (label_index < v2b.label_len) : (label_index += 1) {
        const slot = v2b.label_slots[label_index];
        if (slot.flags.bound and slot.bound_offset == v2b.code_len and slot.ref_count > 0) return true;
    }
    return false;
}

/// TEST HOOK: the script/plain-function epilogue tail (decision +
/// terminal), callable from the emission harness as the script epilogue
/// runs it.
pub fn emitPlainTailForTest(s: *State) Error!void {
    if (isLiveCode(s)) try s.emitReturnUndefined();
}

pub fn patchContinueFrame(s: *State) Error!void {
    if (s.continue_frame_labels.items.len == 0) return Error.ParserInvariant;
    try Emitter.bind(s, s.continue_frame_labels.getLast());
}

pub fn popBreakFrameAndPatch(s: *State) Error!void {
    if (s.break_frame_lens.items.len == 0 or s.continue_frame_lens.items.len == 0) return Error.ParserInvariant;
    _ = s.continue_frame_lens.pop().?;
    _ = s.continue_frame_break_frame_indices.pop().?;
    _ = s.continue_frame_catch_marker_depths.pop().?;
    _ = s.continue_frame_cleanup_drops.pop().?;
    const start = s.break_frame_lens.pop().?;
    _ = s.break_frame_catch_marker_depths.pop().?;
    _ = s.break_frame_cleanup_drops.pop().?;
    _ = s.break_frame_cross_cleanup_drops.pop().?;
    // The continue label was bound by patchContinueFrame; only pop it.
    _ = s.continue_frame_labels.pop() orelse return Error.ParserInvariant;
    const break_label = s.break_frame_labels.pop() orelse return Error.ParserInvariant;
    try Emitter.bind(s, break_label);
    std.debug.assert(s.break_fixups.items.len == start);
}

pub fn popBreakOnlyFrameAndPatch(s: *State) Error!void {
    if (s.break_frame_lens.items.len == 0) return Error.ParserInvariant;
    const start = s.break_frame_lens.pop().?;
    _ = s.break_frame_catch_marker_depths.pop().?;
    _ = s.break_frame_cleanup_drops.pop().?;
    _ = s.break_frame_cross_cleanup_drops.pop().?;
    const break_label = s.break_frame_labels.pop() orelse return Error.ParserInvariant;
    try Emitter.bind(s, break_label);
    std.debug.assert(s.break_fixups.items.len == start);
}

pub fn emitStringLiteralValue(s: *State, bytes: []const u8) Error!void {
    const atom_id = try s.atoms.internString(bytes);

    // QuickJS's emit_push_const(..., as_atom = true) keeps ordinary
    // string atoms as push_atom_value, but a canonical numeric name is a
    // tagged-int atom and therefore falls back to an owned cpool string.
    // Runtime-less parser fragments cannot own JSValues and retain their
    // existing atom-only fallback, like the tagged-template test path.
    if (atom_id.isTaggedInt()) {
        if (s.runtime) |rt| {
            const string = core.string.String.createUtf8(rt, bytes) catch |err| switch (err) {
                error.OutOfMemory, error.StringTooLong => return Error.OutOfMemory,
                error.InvalidUtf8 => return Error.InvalidUtf8,
            };
            try Emitter.pushConst(s, string.value());
            return;
        }
    }
    // qjs emit_push_const(as_atom=true) emits OP_push_atom_value with
    // one owned atom operand.
    try Emitter.opAtom(s, opcode.op.push_atom_value, atom_id);
}

pub fn pushReturnFinallyFrame(
    s: *State,
    finally_label: FinallyLabel,
    catch_marker_depth: u32,
) Error!usize {
    if (catch_marker_depth > s.active_catch_marker_depth) return error.ParserInvariant;
    try s.return_finally_frames.append(s.memory.allocator, .{
        .finally_label = finally_label,
        .scope_level = s.scope_level,
        .catch_marker_depth = catch_marker_depth,
        .break_depth = s.break_frame_lens.items.len,
        .continue_depth = s.continue_frame_lens.items.len,
        .label_depth = s.label_frames.items.len,
        .block_boundary = s.top_break,
    });
    return s.return_finally_frames.items.len - 1;
}

pub fn popReturnFinallyFrame(s: *State, frame_index: usize) void {
    std.debug.assert(frame_index + 1 == s.return_finally_frames.items.len);
    _ = s.return_finally_frames.pop().?;
}

/// A `try` block or `catch` body opened with `openProtectedRegion`: one
/// catch marker is active and one return-finally frame is on the stack
/// until `leave`. Leaving twice is harmless, so `errdefer region.leave(s)`
/// stays armed across the explicit leave.
pub const OpenProtectedRegion = struct {
    frame_index: usize,
    outer_catch_depth: u32,
    active: bool = true,

    fn enter(s: *State, finally_label: FinallyLabel) Error!OpenProtectedRegion {
        const outer_catch_depth = s.active_catch_marker_depth;
        s.active_catch_marker_depth += 1;
        errdefer s.active_catch_marker_depth = outer_catch_depth;
        return .{
            .frame_index = try pushReturnFinallyFrame(s, finally_label, outer_catch_depth),
            .outer_catch_depth = outer_catch_depth,
        };
    }

    pub fn leave(self: *OpenProtectedRegion, s: *State) void {
        if (self.active) {
            popReturnFinallyFrame(s, self.frame_index);
            self.active = false;
        }
        s.active_catch_marker_depth = self.outer_catch_depth;
    }
};

pub fn openProtectedRegion(s: *State, finally_label: FinallyLabel) Error!OpenProtectedRegion {
    return OpenProtectedRegion.enter(s, finally_label);
}

pub fn enterReturnFinallyFunctionBoundary(s: *State) ReturnFinallyBoundary {
    const saved = ReturnFinallyBoundary{
        .frames = s.return_finally_frames,
        .finally_body_control_frames = s.finally_body_control_frames,
    };
    s.return_finally_frames = .empty;
    s.finally_body_control_frames = .empty;
    return saved;
}

pub fn leaveReturnFinallyFunctionBoundary(s: *State, saved: *const ReturnFinallyBoundary) void {
    s.return_finally_frames.deinit(s.memory.allocator);
    s.return_finally_frames = saved.frames;
    s.finally_body_control_frames.deinit(s.memory.allocator);
    s.finally_body_control_frames = saved.finally_body_control_frames;
}

fn controlTargetCrossesFinallyFrame(s: *State, target: FinallyControlTarget, frame_index: usize) Error!bool {
    const frame = s.return_finally_frames.items[frame_index];
    if (target.label_atom) |atom_id| {
        const label_frame_index = s.findLabelFrame(atom_id) orelse return Error.ParserInvariant;
        if (target.kind == .@"continue" and !s.label_frames.items[label_frame_index].allow_continue) {
            return Error.ParserInvariant;
        }
        return label_frame_index < frame.label_depth;
    }
    return switch (target.kind) {
        .@"break" => s.break_frame_lens.items.len <= frame.break_depth,
        .@"continue" => s.continue_frame_lens.items.len <= frame.continue_depth,
    };
}

/// Parse the syntactic finalizer once. Its BlockEnv is the ordered seam
/// used by return/control walkers to discard the completion and gosub PC
/// only when an abrupt completion crosses out of this body.
pub fn parseSharedFinallyBlock(s: *State) Error!void {
    var block = BlockEnv{
        .prev = s.top_break,
        .label_name = null,
        .has_break_target = false,
        .has_continue_target = false,
        .drop_count = 2,
        .scope_level = s.scope_level,
        .catch_marker_depth = s.active_catch_marker_depth,
        .has_iterator = false,
        .is_regular_stmt = false,
    };
    s.top_break = &block;
    defer {
        std.debug.assert(s.top_break == &block);
        s.top_break = block.prev;
    }

    try s.finally_body_control_frames.append(s.memory.allocator, .{
        .block = &block,
        .catch_marker_depth = s.active_catch_marker_depth,
        .break_depth = s.break_frame_lens.items.len,
        .continue_depth = s.continue_frame_lens.items.len,
        .label_depth = s.label_frames.items.len,
    });
    defer _ = s.finally_body_control_frames.pop().?;

    var saved_eval_ret_idx: ?u16 = null;
    if (s.eval_ret_idx != null) {
        const idx = try declarations.appendFunctionVarAtOrigin(s, State.eval_ret_atom, 0);
        saved_eval_ret_idx = idx;
        try s.emitEvalRetGet();
        // zjs-only shared-finalizer lowering: spill the incoming eval
        // completion to the same anonymous local as legacy.
        try Emitter.opU16(s, opcode.op.put_loc, idx);
        try s.setEvalReturnUndefined();
    }

    try statements.parseBlock(s);

    if (saved_eval_ret_idx) |idx| {
        // zjs-only shared-finalizer lowering: restore the saved eval
        // completion after ignoring the finalizer's normal value.
        try Emitter.opU16(s, opcode.op.get_loc, idx);
        try s.emitEvalRetPut();
    }
}

/// Emit a return whose value is already on TOS. The mutable BlockEnv and
/// catch cursors ensure each iterator/catch record is unwound once while
/// all active finalizers share the same gosub target.
pub fn emitReturnValue(s: *State, await_before_unwind: bool) Error!void {
    if (await_before_unwind) {
        // qjs emit_return: await an async-generator value before unwinding.
        try Emitter.op(s, opcode.op.await);
    }

    var block_cursor = s.top_break;
    var catch_marker_depth = s.active_catch_marker_depth;
    var frame_index = s.return_finally_frames.items.len;
    while (frame_index != 0) {
        frame_index -= 1;
        const frame = s.return_finally_frames.items[frame_index];
        try functions.emitBlockEnvReturnCleanupUntil(s, &block_cursor, frame.block_boundary, &catch_marker_depth);
        try functions.emitStackTopCatchMarkerDropsToDepth(s, &catch_marker_depth, frame.catch_marker_depth);
        // qjs emit_return: execute each crossed finally via gosub.
        try Emitter.jumpNoSource(s, opcode.op.gosub, frame.finally_label);
    }
    try functions.emitBlockEnvReturnCleanupUntil(s, &block_cursor, null, &catch_marker_depth);
    try functions.emitStackTopCatchMarkerDropsToDepth(s, &catch_marker_depth, 0);
    try emitFunctionReturn(s, true);
}

/// Complete a return after its optional expression has been parsed exactly
/// once. Async-generator explicit values await before any cleanup, matching
/// QuickJS emit_return.
const UpdatedSourceLoc = struct {
    index: usize,
    previous: compiler.builder.SourceSlot,
};

pub fn restoreSourceLoc(s: *State, updated: UpdatedSourceLoc) void {
    const builder = s.activeBuilder();
    std.debug.assert(updated.index < @as(usize, @intCast(builder.source_len)));
    builder.source_slots[updated.index] = updated.previous;
}

pub fn reattributeReturnTailCallSource(s: *State, has_expr: bool, source: SourcePosition) Error!?UpdatedSourceLoc {
    if (!has_expr or s.ctx.in_async or s.ctx.in_generator or (s.ctx.in_constructor and s.class.has_extends)) return null;
    if (s.return_finally_frames.items.len != 0 or
        s.finally_body_control_frames.items.len != 0 or
        s.top_break != null or
        s.active_catch_marker_depth != 0)
    {
        return null;
    }

    // qjs resolve_labels recognizes `call[method] ; OP_line_num ;
    // return` and attributes the call site to the return keyword. The
    // v2 marker is already out of band, so update that exact marker
    // before emitting the terminal return with the same source.
    const builder = s.activeBuilder();
    const pc = builder.last_opcode_pos orelse return null;
    if (pc >= builder.code_len) return Error.ParserInvariant;
    const op_id = builder.code[pc];
    if (op_id != opcode.op.call and op_id != opcode.op.call_method) return null;

    var index: usize = @intCast(builder.source_len);
    while (index != 0) {
        index -= 1;
        const marker = builder.source_slots[index];
        if (marker.temp_offset < pc) break;
        if (marker.temp_offset == pc) {
            builder.source_slots[index].line = @intCast(source.line_num);
            builder.source_slots[index].col = @intCast(source.col_num);
            return .{ .index = index, .previous = marker };
        }
    }
    // QuickJS's bare-template concat path emits OP_call_method with no
    // preceding source event (`js_parse_template`, quickjs.c), then
    // emits the return-keyword OP_line_num after the call. The compact
    // ledger has no in-stream OP_line_num to move, so add the equivalent
    // event directly at the call offset.
    if (builder.source_len != 0 and
        builder.source_slots[builder.source_len - 1].temp_offset > pc)
    {
        return Error.ParserInvariant;
    }
    try builder.addSourceMarker(@intCast(source.line_num), @intCast(source.col_num));
    builder.source_slots[builder.source_len - 1].temp_offset = pc;
    return null;
}

pub fn emitParsedReturn(s: *State, has_expr: bool) Error!void {
    const needs_value = has_expr or
        s.ctx.in_async or
        s.ctx.in_generator or
        s.return_finally_frames.items.len != 0 or
        s.finally_body_control_frames.items.len != 0 or
        s.top_break != null or
        s.active_catch_marker_depth != 0;
    if (!needs_value) {
        try emitFunctionReturn(s, false);
        return;
    }
    if (!has_expr) {
        // qjs emit_return: materialize the missing return value before cleanup.
        try Emitter.op(s, opcode.op.undefined);
    }
    try emitReturnValue(s, has_expr and s.ctx.in_async and s.ctx.in_generator);
}

fn emitFunctionReturn(s: *State, has_value: bool) Error!void {
    var value_on_stack = has_value;
    if (!value_on_stack and (s.ctx.in_async or s.ctx.in_generator)) {
        // qjs emit_return: synthesize undefined for async/generator returns.
        try Emitter.op(s, opcode.op.undefined);
        value_on_stack = true;
    }

    if (s.ctx.in_constructor and s.class.has_extends) {
        if (value_on_stack) {
            // qjs emit_return derived constructor: if_false skips this substitution.
            try Emitter.opU8(s, opcode.op.ext0, opcode.ext0_sub.check_ctor_return);
            const return_value = try Emitter.newLabel(s);
            try Emitter.jump(s, opcode.op.if_false, return_value);
            try Emitter.op(s, opcode.op.drop);
            try s.emitScopeGetVarCheckThis(atom_this);
            try Emitter.bind(s, return_value);
        } else {
            try s.emitScopeGetVarCheckThis(atom_this);
        }
        // qjs emit_return derived constructor terminal: OP_return.
        try Emitter.op(s, opcode.op.@"return");
    } else if (s.ctx.in_async or s.ctx.in_generator) {
        // qjs emit_return: non-normal functions use OP_return_async.
        try Emitter.op(s, opcode.op.return_async);
    } else {
        // qjs emit_return: select value return versus return_undef.
        try Emitter.op(s, if (value_on_stack) opcode.op.@"return" else opcode.op.return_undef);
    }
}

const ResolvedFinallyControlTarget = struct {
    depth: usize,
    catch_marker_depth: u32,
    cleanup_drops: u8,
    label_frame_index: ?usize,
};

fn resolveFinallyControlTarget(s: *State, target: FinallyControlTarget) Error!ResolvedFinallyControlTarget {
    if (target.label_atom) |atom_id| {
        const label_index = s.findLabelFrame(atom_id) orelse return s.failUndefinedLabel(atom_id);
        const label_frame = s.label_frames.items[label_index];
        return switch (target.kind) {
            .@"break" => .{
                .depth = label_frame.break_frame_depth,
                .catch_marker_depth = label_frame.catch_marker_depth,
                .cleanup_drops = if (label_frame.allow_continue and label_frame.break_frame_depth > 0)
                    s.break_frame_cleanup_drops.items[label_frame.break_frame_depth - 1]
                else
                    0,
                .label_frame_index = label_index,
            },
            .@"continue" => blk: {
                if (!label_frame.allow_continue or label_frame.control_frame_depth == 0) {
                    return s.failWithMessage(null, "continue must target a loop label");
                }
                break :blk .{
                    .depth = label_frame.control_frame_depth,
                    .catch_marker_depth = label_frame.catch_marker_depth,
                    .cleanup_drops = s.continue_frame_cleanup_drops.items[label_frame.control_frame_depth - 1],
                    .label_frame_index = label_index,
                };
            },
        };
    }

    return switch (target.kind) {
        .@"break" => blk: {
            if (s.break_frame_lens.items.len == 0) return Error.ParserInvariant;
            break :blk .{
                .depth = s.break_frame_lens.items.len,
                .catch_marker_depth = s.break_frame_catch_marker_depths.getLast(),
                .cleanup_drops = s.break_frame_cleanup_drops.getLast(),
                .label_frame_index = null,
            };
        },
        .@"continue" => blk: {
            if (s.continue_frame_lens.items.len == 0) return Error.ParserInvariant;
            break :blk .{
                .depth = s.continue_frame_lens.items.len,
                .catch_marker_depth = s.continue_frame_catch_marker_depths.getLast(),
                .cleanup_drops = s.continue_frame_cleanup_drops.getLast(),
                .label_frame_index = null,
            };
        },
    };
}

fn controlBlockMatchesTarget(block: *const BlockEnv, target: FinallyControlTarget) bool {
    if (target.label_atom) |atom_id| {
        return switch (target.kind) {
            .@"break" => block.has_break_target and block.label_name == atom_id,
            .@"continue" => block.has_continue_target and block.label_name == atom_id,
        };
    }
    return switch (target.kind) {
        .@"break" => block.has_break_target and !block.is_regular_stmt,
        .@"continue" => block.has_continue_target,
    };
}

fn emitResolvedControlJump(
    s: *State,
    target: FinallyControlTarget,
    resolved: ResolvedFinallyControlTarget,
) Error!void {
    // v2: the jump is born as the frame's LabelId (qjs emit_goto to
    // label_break/label_cont); no operand-offset fixup lists.
    const label = if (resolved.label_frame_index) |label_index| switch (target.kind) {
        .@"break" => s.label_frames.items[label_index].break_label,
        .@"continue" => s.label_frames.items[label_index].continue_label,
    } else switch (target.kind) {
        .@"break" => blk: {
            if (resolved.depth == 0 or resolved.depth > s.break_frame_labels.items.len) break :blk null;
            break :blk s.break_frame_labels.items[resolved.depth - 1];
        },
        .@"continue" => blk: {
            if (resolved.depth == 0 or resolved.depth > s.continue_frame_labels.items.len) break :blk null;
            break :blk s.continue_frame_labels.items[resolved.depth - 1];
        },
    };
    const label_id = label orelse return Error.ParserInvariant;
    try Emitter.jumpNoSource(s, opcode.op.goto, label_id);
}

fn emitCrossedControlBlockCleanup(s: *State, block: *const BlockEnv) Error!void {
    var dropped: i32 = 0;
    if (block.has_iterator) {
        try Emitter.opNoSource(s, opcode.op.iterator_close);
        dropped = 3;
    }
    while (dropped < block.drop_count) : (dropped += 1) {
        try Emitter.opNoSource(s, opcode.op.drop);
    }
}

/// Walk ordered control environments up to `boundary`.  Scope exits are
/// emitted before each target test, exactly like QuickJS `emit_break`;
/// crossed iterator/drop/finally cleanup follows that environment's scope
/// exits before the walker advances to its parent.
fn emitControlBlocksUntil(
    s: *State,
    target: FinallyControlTarget,
    resolved: ResolvedFinallyControlTarget,
    block_cursor: *?*BlockEnv,
    boundary: ?*BlockEnv,
    scope_cursor: *i32,
    catch_marker_depth: *u32,
) Error!bool {
    while (block_cursor.*) |current| {
        if (current == boundary) return false;

        try s.closeScopes(scope_cursor.*, current.scope_level);
        scope_cursor.* = current.scope_level;
        if (controlBlockMatchesTarget(current, target)) {
            try emitCatchMarkerDropsFromDepth(s, catch_marker_depth, resolved.catch_marker_depth);
            // zjs's array-backed fixups do not all land on a QuickJS-style
            // physical break label before the target epilogue. Preserve
            // the target frame's established stack cleanup while the
            // BlockEnv walker owns only crossed-environment cleanup.
            switch (target.kind) {
                .@"break" => try emitUnlabelledBreakCleanup(s, resolved.cleanup_drops),
                .@"continue" => {},
            }
            try emitResolvedControlJump(s, target, resolved);
            return true;
        }

        try emitCatchMarkerDropsFromDepth(s, catch_marker_depth, current.catch_marker_depth);
        try emitCrossedControlBlockCleanup(s, current);
        block_cursor.* = current.prev;
    }
    if (boundary != null) return Error.ParserInvariant;
    return false;
}

pub fn emitControlThroughFinally(s: *State, target: FinallyControlTarget) Error!void {
    const resolved = try resolveFinallyControlTarget(s, target);
    var block_cursor = s.top_break;
    var scope_cursor = s.scope_level;
    var catch_marker_depth = s.active_catch_marker_depth;

    var return_index = s.return_finally_frames.items.len;
    while (return_index != 0) {
        return_index -= 1;
        if (!try controlTargetCrossesFinallyFrame(s, target, return_index)) continue;
        const return_frame = s.return_finally_frames.items[return_index];
        if (try emitControlBlocksUntil(
            s,
            target,
            resolved,
            &block_cursor,
            return_frame.block_boundary,
            &scope_cursor,
            &catch_marker_depth,
        )) return;
        try s.closeScopes(scope_cursor, return_frame.scope_level);
        scope_cursor = return_frame.scope_level;
        try emitCatchMarkerDropsFromDepth(s, &catch_marker_depth, return_frame.catch_marker_depth);
        // qjs emit_break/emit_return: keep stack depth across a crossed finally.
        try Emitter.opNoSource(s, opcode.op.undefined);
        try Emitter.jumpNoSource(s, opcode.op.gosub, return_frame.finally_label);
        // qjs emit_break: discard the crossed finalizer completion.
        try Emitter.opNoSource(s, opcode.op.drop);
    }

    if (try emitControlBlocksUntil(
        s,
        target,
        resolved,
        &block_cursor,
        null,
        &scope_cursor,
        &catch_marker_depth,
    )) return;
    return Error.ParserInvariant;
}
