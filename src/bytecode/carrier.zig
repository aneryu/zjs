const std = @import("std");
const bytecode = @import("../bytecode.zig");
const atom = @import("../core/atom.zig");
const context = @import("../core/context.zig");
const runtime = @import("../runtime.zig");
const execution = @import("../core/execution.zig");
const FunctionBytecode = bytecode.FunctionBytecode;
const CallFacts = bytecode.CallFacts;
const FunctionDef = bytecode.FunctionDef;
const pipeline = bytecode.pipeline;
const opcode = bytecode.opcode;
const module = bytecode.module;
const EntryContract = bytecode.EntryContract;
const function_bytecode = bytecode.function_bytecode;
const pipeline_pc2line = bytecode.pipeline.pc2line;

const function_bytecode_mod = function_bytecode;
const pc2line = pipeline_pc2line;

/// Generic geometric growth helper, identical in shape to the FunctionDef
/// helper of the same name. Keeps `slice.*.len` as the *used* count and
/// `slice.*.ptr[0..capacity.*]` as the allocator-owned buffer. Returns the
/// freshly grown tail (length `n`).
fn growSliceBy(
    comptime T: type,
    allocator: std.mem.Allocator,
    slice: *[]T,
    capacity: *usize,
    n: usize,
) ![]T {
    const used = slice.len;
    const new_used = used + n;
    if (new_used <= capacity.*) {
        slice.* = slice.ptr[0..new_used];
        return slice.ptr[used..new_used];
    }
    var new_cap: usize = if (capacity.* == 0) 8 else capacity.* * 2;
    if (new_cap < new_used) new_cap = new_used;
    const new_buf = try allocator.alloc(T, new_cap);
    @memcpy(new_buf[0..used], slice.*);
    var old_buf: []T = &.{};
    if (capacity.* != 0) old_buf = slice.ptr[0..capacity.*];
    slice.* = new_buf[0..new_used];
    capacity.* = new_cap;
    if (old_buf.len != 0) allocator.free(old_buf);
    return slice.ptr[used..new_used];
}

fn freeGrowableSlice(
    comptime T: type,
    allocator: std.mem.Allocator,
    slice: *[]T,
    capacity: *usize,
) void {
    var old_buf: []T = &.{};
    if (capacity.* != 0) old_buf = slice.ptr[0..capacity.*];
    slice.* = &.{};
    capacity.* = 0;
    if (old_buf.len != 0) allocator.free(old_buf);
}

fn freeOwnedAtomSlice(allocator: std.mem.Allocator, slot: *[]atom.Atom) void {
    const items = slot.*;
    slot.* = &.{};
    if (items.len != 0) allocator.free(items);
}

fn freeGrowableAtomSlice(
    allocator: std.mem.Allocator,
    slice: *[]atom.Atom,
    capacity: *usize,
) void {
    const items = slice.*;
    const old_capacity = capacity.*;
    slice.* = &.{};
    capacity.* = 0;
    if (old_capacity != 0) {
        allocator.free(items.ptr[0..old_capacity]);
    } else if (items.len != 0) {
        allocator.free(items);
    }
}

pub const Flags = packed struct(u16) {
    has_prototype: bool = false,
    has_simple_parameter_list: bool = true,
    is_derived_class_constructor: bool = false,
    need_home_object: bool = false,
    is_async: bool = false,
    is_generator: bool = false,
    is_strict: bool = false,
    runtime_strict: bool = false,
    is_global_var: bool = false,
    is_module: bool = false,
    is_direct_or_indirect_eval: bool = false,
    /// Compile/finalize fact used to distinguish strict snapshot frames
    /// from strict functions that never create an arguments object.
    materializes_arguments_object: bool = false,
    /// Runtime-created mapped Arguments objects open-alias every supplied
    /// argument slot in addition to the statically captured bindings.
    has_mapped_arguments: bool = false,
    /// Exact-zero-argument sloppy plain-function leaf whose frame cannot
    /// acquire cold state or value-bearing local/capture/open-ref windows.
    /// Published in the previously reserved execution flag bit. The
    /// raw-`this` twin for strict plain functions lives in the
    /// `raw_this_inline_empty_leaf` field, so this established sloppy test
    /// stays single-bit while this packed carrier retains its u16 ABI.
    simple_inline_empty_leaf: bool = false,
    _reserved: u2 = 0,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 2);
    }
};

/// Compatibility aliases for finalized runtime function bytecode.
/// The GC object lives in core; bytecode keeps opcode-aware helpers below.
/// Fused exact-args-leaf dispatch classification (see
/// `BytecodeImpl.exact_args_leaf_kind`).
pub const ExactArgsLeafKind = function_bytecode_mod.ExactArgsLeafKind;

/// The finalize staging record: `resolve_labels` installs the final code,
/// atom ledger and source slots here, `publishLoweredMetadata` adds stack
/// depth, pc2line and the frame/entry facts, and
/// `createFunctionBytecodeAfterChildren` packs it into the GC-owned
/// `FunctionBytecode`. It lives on the finalizer's stack for one function
/// and is never executed.
pub const BytecodeImpl = struct {
    /// Ordinary code, atom, and pc2line buffers.
    allocator: std.mem.Allocator,
    /// NoTrigger facade for stack-size scratch. Same account as `allocator`.
    scratch: std.mem.Allocator,
    atoms: *atom.AtomTable,
    /// Borrowed realm pointer copied into the canonical FB. Mutable legacy
    /// module/test bytecode leaves this null and supplies its realm at the
    /// module/test entry boundary.
    realm: ?*context.RealmContext = null,
    name: atom.Atom,
    filename: atom.Atom,
    /// Stable ScriptOrModule identity used for host referrer resolution.
    /// It is separately owned because eval keeps filename "<eval>".
    script_or_module: atom.Atom,
    line_num: i32 = 1,
    col_num: i32 = 1,
    pc2line_buf: []u8 = &.{},
    owns_pc2line_buf: bool = false,
    source_loc_slots: []pipeline_pc2line.SourceLocSlot = &.{},
    source_loc_capacity: usize = 0,
    /// W1 property-site cache slots the final code addresses:
    /// `resolve_labels` assigns `cache_idx` operands 0.. in emission
    /// order; sites past 255 carry the no-cache index.
    prop_site_count: u16 = 0,
    flags: Flags = .{},
    entry_contract: EntryContract = .{},
    /// Precomputed bytecode-only half of simple inline-call eligibility.
    /// Call-site predicates remain checked in the exec inline-call path.
    simple_inline_eligible: bool = false,
    /// Strict-mode twin of `simple_inline_eligible`. Kept separate so the
    /// established sloppy hot path does not gain a per-call strict-mode
    /// branch; inline_calls instantiates a dedicated strict setup whose
    /// only semantic difference is preserving an undefined plain `this`.
    strict_simple_inline_eligible: bool = false,
    /// Strict simple-frame variant that also snapshots the incoming args
    /// before mutable parameter slots can change them. Selected only when
    /// finalized bytecode materializes an arguments object.
    strict_simple_snapshot_inline_eligible: bool = false,
    /// Raw-`this` twin of `flags.simple_inline_empty_leaf` (the packed
    /// flags word remains a stable u16): identical empty-leaf frame
    /// geometry, published for strict-mode plain functions whose frame
    /// preserves the caller-supplied raw `this` word instead of
    /// substituting the sloppy realm global.
    /// Plain call sites select the undefined-`this` arm; the method
    /// receiver arm is mode-independent. Kept as a separate byte so
    /// the established sloppy call arms retain their exact single-bit
    /// test.
    raw_this_inline_empty_leaf: bool = false,
    /// Exact-args generalization of the empty-leaf family: same leaf body
    /// geometry (no locals/captures/open refs/arguments/direct eval) with
    /// `arg_count > 0`. A call site that supplies exactly `arg_count`
    /// arguments borrows them in place from the caller's operand region
    /// (qjs `arg_buf = argv`, quickjs.c) and enters the warm leaf
    /// constructor. Published as two separate bytes mirroring the
    /// zero-arg family split (folding modes into one bit measured
    /// +3 insn/call on the established sloppy arm): this byte is the
    /// sloppy plain twin
    /// (`this` = realm global on plain calls).
    simple_inline_exact_args_leaf: bool = false,
    /// Raw-`this` twin of `simple_inline_exact_args_leaf`: strict plain
    /// functions preserving the raw incoming `this` word exactly like
    /// `raw_this_inline_empty_leaf`.
    raw_this_inline_exact_args_leaf: bool = false,
    /// Fused dispatch byte for the two exact-args policy bits above:
    /// one load answers "is this ANY exact-args leaf, and which `this`
    /// policy". The dominant real-world shape at the with-args call arms
    /// is a NON-leaf callee (locals, named-expression self-binding), so
    /// the miss must cost one byte test, not two (measured +1.3% insn on
    /// call-closure-two-arg from the two-byte chain). The bools stay
    /// published for asserts and eligibility tests.
    exact_args_leaf_kind: ExactArgsLeafKind = .none,
    /// Capture-leaf fused dispatch byte (O2): zero-arg callees whose ONLY
    /// frame window is the inherited capture array — `() => this.x`
    /// arrows (lexical `this` is an ordinary closure cell since the
    /// capture conversion) and zero-arg closures over upvalues. Same
    /// `leaf_body_geometry` as the exact-args family (no locals, no cell
    /// CREATION, no arguments/direct eval) with `arg_count == 0` and
    /// `closure_var_count > 0`, so the three leaf families partition cleanly:
    /// empty leaf owns argc==0 without captures, this byte owns argc==0
    /// with captures, exact-args owns argc==arg_count>0. The frame
    /// borrows the closure's cell array (qjs `var_refs =
    /// p->u.func.var_refs`, quickjs.c; rooted by the owned
    /// callable) and publishes the `exact_args_leaf` teardown bit: its
    /// guarded return arm (callee operand window must be empty) is
    /// load-bearing here because inherited-capture bodies may read free
    /// names and leave parser-elided leftovers at `return`, and its args
    /// release loop zero-trips on the empty args window.
    capture_leaf_kind: ExactArgsLeafKind = .none,
    arg_count: u16 = 0,
    var_count: u16 = 0,
    stack_size: u16 = 0,
    open_var_ref_count: u16 = 0,
    /// Exact stack-BFS result published by the normal stack-size pass.
    /// This prevents leaf classification from rerunning an allocating scan
    /// when the FB is attached or first called.
    leaf_returns_balanced: bool = false,
    /// `code` and `atom_operands` are installed by `resolve_labels`, which
    /// hands over its own backing through `installCodeWithCapacity` /
    /// `installAtomOperandsWithCapacity`. The visible slice length is the
    /// *used* count; `code_capacity` / `atom_operands_capacity` keep naming
    /// that backing rather than dropping to the used length.
    code: []u8 = &.{},
    code_capacity: usize = 0,
    atom_operands: []atom.Atom = &.{},
    atom_operands_capacity: usize = 0,

    pub fn init(allocator: std.mem.Allocator, scratch: std.mem.Allocator, atoms: *atom.AtomTable, name: atom.Atom) BytecodeImpl {
        return .{
            .allocator = allocator,
            .scratch = scratch,
            .atoms = atoms,
            .name = name,
            .filename = name,
            .script_or_module = name,
        };
    }

    pub fn deinit(self: *BytecodeImpl) void {
        self.name = atom.null_atom;
        self.filename = atom.null_atom;
        self.script_or_module = atom.null_atom;
        freeGrowableAtomSlice(self.allocator, &self.atom_operands, &self.atom_operands_capacity);
        freeGrowableSlice(u8, self.allocator, &self.code, &self.code_capacity);
        freeGrowableSlice(pipeline_pc2line.SourceLocSlot, self.allocator, &self.source_loc_slots, &self.source_loc_capacity);
        const pc2line_buf = self.pc2line_buf;
        const owns_pc2line_buf = self.owns_pc2line_buf;
        self.pc2line_buf = &.{};
        self.owns_pc2line_buf = false;
        if (owns_pc2line_buf and pc2line_buf.len != 0) self.allocator.free(pc2line_buf);
    }

    pub inline fn byteCode(self: *const BytecodeImpl) []const u8 {
        return self.code;
    }
    pub inline fn funcName(self: *const BytecodeImpl) atom.Atom {
        return self.name;
    }
    pub inline fn pc2lineBuf(self: *const BytecodeImpl) []const u8 {
        return self.pc2line_buf;
    }
    pub inline fn lineNum(self: *const BytecodeImpl) i32 {
        return self.line_num;
    }
    pub inline fn colNum(self: *const BytecodeImpl) i32 {
        return self.col_num;
    }
    pub inline fn scriptOrModule(self: *const BytecodeImpl) atom.Atom {
        return self.script_or_module;
    }
    pub inline fn realmContext(self: *const BytecodeImpl) ?*context.RealmContext {
        return self.realm;
    }
    pub inline fn isGlobalVar(self: *const BytecodeImpl) bool {
        return self.flags.is_global_var;
    }
    pub inline fn isModule(self: *const BytecodeImpl) bool {
        return self.flags.is_module;
    }
    pub inline fn functionKind(self: *const BytecodeImpl) function_bytecode_mod.FunctionKind {
        return if (self.flags.is_async and self.flags.is_generator)
            .async_generator
        else if (self.flags.is_async)
            .async
        else if (self.flags.is_generator)
            .generator
        else
            .normal;
    }
    pub inline fn isDerivedClassConstructor(self: *const BytecodeImpl) bool {
        return self.flags.is_derived_class_constructor;
    }
    pub inline fn hasPrototype(self: *const BytecodeImpl) bool {
        return self.flags.has_prototype;
    }
    pub inline fn hasSimpleParameterList(self: *const BytecodeImpl) bool {
        return self.flags.has_simple_parameter_list;
    }
    pub inline fn needHomeObject(self: *const BytecodeImpl) bool {
        return self.flags.need_home_object;
    }
    pub inline fn newTargetAllowed(self: *const BytecodeImpl) bool {
        return self.entry_contract.new_target_allowed;
    }
    pub inline fn superCallAllowed(self: *const BytecodeImpl) bool {
        return self.entry_contract.super_call_allowed;
    }
    pub inline fn superAllowed(self: *const BytecodeImpl) bool {
        return self.entry_contract.super_allowed;
    }
    pub inline fn argumentsAllowed(self: *const BytecodeImpl) bool {
        return self.entry_contract.arguments_allowed;
    }
    pub inline fn isDirectOrIndirectEval(self: *const BytecodeImpl) bool {
        return self.flags.is_direct_or_indirect_eval;
    }
    pub inline fn isAsync(self: *const BytecodeImpl) bool {
        return self.flags.is_async;
    }
    pub inline fn isGenerator(self: *const BytecodeImpl) bool {
        return self.flags.is_generator;
    }
    pub inline fn entryContract(self: *const BytecodeImpl) EntryContract {
        return self.entry_contract;
    }
    pub inline fn isStrictMode(self: *const BytecodeImpl) bool {
        return self.flags.is_strict;
    }
    pub inline fn runtimeStrictMode(self: *const BytecodeImpl) bool {
        return self.flags.runtime_strict;
    }
    pub inline fn hasMappedArguments(self: *const BytecodeImpl) bool {
        return self.flags.has_mapped_arguments;
    }
    pub inline fn simpleInlineEligible(self: *const BytecodeImpl) bool {
        return self.simple_inline_eligible;
    }
    pub inline fn strictSimpleInlineEligible(self: *const BytecodeImpl) bool {
        return self.strict_simple_inline_eligible;
    }
    pub inline fn strictSimpleSnapshotInlineEligible(self: *const BytecodeImpl) bool {
        return self.strict_simple_snapshot_inline_eligible;
    }
    pub inline fn simpleInlineEmptyLeaf(self: *const BytecodeImpl) bool {
        return self.flags.simple_inline_empty_leaf;
    }
    pub inline fn rawThisInlineEmptyLeaf(self: *const BytecodeImpl) bool {
        return self.raw_this_inline_empty_leaf;
    }
    pub inline fn simpleInlineExactArgsLeaf(self: *const BytecodeImpl) bool {
        return self.simple_inline_exact_args_leaf;
    }
    pub inline fn rawThisInlineExactArgsLeaf(self: *const BytecodeImpl) bool {
        return self.raw_this_inline_exact_args_leaf;
    }
    pub inline fn exactArgsLeafKind(self: *const BytecodeImpl) function_bytecode_mod.ExactArgsLeafKind {
        return self.exact_args_leaf_kind;
    }
    pub fn setCode(self: *BytecodeImpl, bytes: []const u8) !void {
        freeGrowableSlice(u8, self.allocator, &self.code, &self.code_capacity);
        if (bytes.len == 0) return;
        const owned = try self.allocator.alloc(u8, bytes.len);
        errdefer self.allocator.free(owned);
        @memcpy(owned, bytes);
        self.code = owned;
        self.code_capacity = bytes.len;
    }

    /// Append bytes to `code` with geometric growth. The visible slice
    /// length tracks the used count so callers can read `code.len` for
    /// the current size, while reallocations are amortised O(1).
    pub fn appendCode(self: *BytecodeImpl, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const tail = try growSliceBy(u8, self.allocator, &self.code, &self.code_capacity, bytes.len);
        @memcpy(tail, bytes);
    }

    /// Truncate `code` back to `target_len` bytes, preserving capacity so
    /// re-emission after speculative rollback does not reallocate.
    pub fn truncateCode(self: *BytecodeImpl, target_len: usize) void {
        std.debug.assert(target_len <= self.code.len);
        self.code = self.code.ptr[0..target_len];
    }

    /// Replace the `code` buffer with a caller-owned backing allocation
    /// of `owned_capacity` elements while exposing only the used prefix
    /// `owned_used`. Used by pipeline passes that fully rewrite the
    /// buffer (e.g. `resolve_labels`). `deinit`, `setCode` and the
    /// growable append helpers all free `code.ptr[0..code_capacity]`, so
    /// the full backing is released on every later path — including
    /// `owned_used.len == 0` with `owned_capacity > 0`, where the caller
    /// passes `backing.ptr[0..0]` so the pointer still names the backing.
    pub fn installCodeWithCapacity(self: *BytecodeImpl, owned_used: []u8, owned_capacity: usize) void {
        std.debug.assert(owned_used.len <= owned_capacity);
        std.debug.assert(owned_capacity != 0 or owned_used.len == 0);
        freeGrowableSlice(u8, self.allocator, &self.code, &self.code_capacity);
        self.code = owned_used;
        self.code_capacity = owned_capacity;
    }

    pub fn installPc2Line(self: *BytecodeImpl, owned: []u8) void {
        const old = self.pc2line_buf;
        const old_owned = self.owns_pc2line_buf;
        self.pc2line_buf = owned;
        self.owns_pc2line_buf = owned.len != 0;
        if (old_owned and old.len != 0) self.allocator.free(old);
    }

    /// Replace the `atom_operands` buffer with a caller-owned backing
    /// allocation of `owned_capacity` entries, exposing only the used
    /// prefix `owned_used`. Atom ids are plain values under the tracing
    /// GC, so nothing is released here. When `owned_capacity` is
    /// nonzero, `owned_used.ptr` must name the head of the backing.
    pub fn installAtomOperandsWithCapacity(self: *BytecodeImpl, owned_used: []atom.Atom, owned_capacity: usize) void {
        std.debug.assert(owned_used.len <= owned_capacity);
        std.debug.assert(owned_capacity != 0 or owned_used.len == 0);
        freeGrowableSlice(atom.Atom, self.allocator, &self.atom_operands, &self.atom_operands_capacity);
        self.atom_operands = owned_used;
        self.atom_operands_capacity = owned_capacity;
    }
};

/// Geometry-only body-expansion gate (OPT-R10 small-function-inlining).
/// Does not look at function names or field patterns. Forbidden opcodes
/// that require a real frame (eval / arguments / fclosure / new.target /
/// apply / generators) reject the candidate.
pub const small_inline_max_code: usize = 40;
pub const small_inline_max_slots: usize = 4;
pub const small_inline_max_stack: usize = 4;

fn scanSmallInlineEligible(fb: *const FunctionBytecode, facts: ExecutionFacts) bool {
    if (fb.functionKind() != .normal) return false;
    if (facts.class_syntax_excludes_inline) return false;
    if (fb.isDerivedClassConstructor()) return false;
    if (!fb.hasSimpleParameterList()) return false;
    if (facts.materializes_arguments_object or facts.contains_direct_eval) return false;
    if (fb.closureVarCount() != 0 or fb.openVarRefCount() != 0) return false;
    const code = fb.byteCode();
    if (code.len == 0 or code.len > small_inline_max_code) return false;
    if (@as(usize, fb.arg_count) + @as(usize, fb.var_count) > small_inline_max_slots) return false;
    if (fb.stack_size > small_inline_max_stack) return false;

    // F0b: the reject set is derived from the declaration, so a form
    // that moves behind a carrier keeps its policy. The hand-written
    // list this replaces matched on opcode identity and therefore could
    // not see a carrier resident at all -- which is how demoting
    // `put_super_value` silently made `super.x = v` bodies inlinable,
    // with no test turning red (5.2 clause 3). A carrier is now asked
    // about its resident instead of being special-cased.
    var pc: u32 = 0;
    while (pc < code.len) {
        const h = opcode.decode.headerAt(.final, code, pc) catch return false;
        if (opcode.logical.traitsOf(h.form).inline_policy == .forbidden) return false;
        if (h.form == .ext0) {
            const sub = opcode.decode.operandAt(h, code, 0, u8) catch return false;
            const resident = opcode.logical.subForm(sub) orelse return false;
            if (opcode.logical.traitsOf(resident).inline_policy == .forbidden) return false;
        }
        pc = h.next_pc();
    }
    return true;
}

/// Publish all zjs-only call classifications once, after the final FB
/// tables/code and the normal stack-BFS result are complete. These facts
/// are deliberately kept out of attach and call resolution: both paths
/// must remain allocation-free and scan-free like qjs JSFunctionBytecode.
const AsyncExecutionPolicy = function_bytecode.AsyncExecutionPolicy;

/// A conservative whole-code proof: even unreachable suspension rejects.
/// Final canonical bytecode has already passed decoder/CFG validation.
/// Adapters borrow mutable bytes and are never given a reusable proof.
pub fn classifyAsyncExecution(fb: *const FunctionBytecode) AsyncExecutionPolicy {
    if (fb.functionKind() != .async or fb.byte_code == null) return .unknown;
    const code = fb.byteCode();
    if (code.len == 0) return .unknown;
    var pc: u32 = 0;
    while (pc < code.len) {
        const h = opcode.decode.headerAt(.final, code, pc) catch return .unknown;
        const form = if (h.form == .ext0) blk: {
            const tag = opcode.decode.operandAt(h, code, 0, u8) catch return .unknown;
            break :blk opcode.logical.subForm(tag) orelse return .unknown;
        } else h.form;
        switch (opcode.logical.asyncSuspension(form)) {
            .none => {},
            .possible => return .may_suspend,
            .unknown => return .unknown,
        }
        pc = h.next_pc();
    }
    return .no_suspend;
}

/// Finalizer-side facts about a function body that the published
/// `CallFacts` classification consumes but the FB does not store itself.
pub const ExecutionFacts = struct {
    materializes_arguments_object: bool,
    has_mapped_arguments: bool,
    leaf_returns_balanced: bool,
    contains_direct_eval: bool,
    /// Class syntax is a finalizer-only exclusion fact. Runtime rejection
    /// is encoded by OP_check_ctor and derived construction keeps its
    /// canonical QJS bit; no ordinary class-constructor flag is published.
    class_syntax_excludes_inline: bool,
    is_module: bool,
};

pub fn publishExecutionFlags(fb: *FunctionBytecode, facts: ExecutionFacts) void {
    const materializes_arguments_object = facts.materializes_arguments_object;
    const has_mapped_arguments = facts.has_mapped_arguments;
    const leaf_returns_balanced = facts.leaf_returns_balanced;
    const contains_direct_eval = facts.contains_direct_eval;
    const class_syntax_excludes_inline = facts.class_syntax_excludes_inline;
    const is_module = facts.is_module;
    std.debug.assert(!fb.isDerivedClassConstructor() or class_syntax_excludes_inline);
    // All published production and legacy-adapter FBs have one extension.
    // Load its possibly-unaligned hot word once, finish every classification
    // in a local snapshot, then publish it with one store.
    var call_facts = fb.callFacts();
    const strict_mode = fb.isStrictMode() or fb.runtimeStrictMode();
    var has_global_declarations = false;
    for (fb.closureVar()) |cv| {
        if (cv.closureType() == .global_decl) {
            has_global_declarations = true;
            break;
        }
    }
    const simple_inline_base = fb.functionKind() == .normal and
        !class_syntax_excludes_inline and
        fb.hasSimpleParameterList() and
        !has_global_declarations;
    const leaf_body_geometry = fb.var_count == 0 and
        fb.openVarRefCount() == 0 and
        !materializes_arguments_object and
        !contains_direct_eval;
    const empty_leaf_geometry = fb.arg_count == 0 and fb.closureVarCount() == 0 and
        leaf_body_geometry and leaf_returns_balanced;
    const sloppy_exact = simple_inline_base and !strict_mode and fb.arg_count > 0 and leaf_body_geometry;
    const raw_exact = simple_inline_base and strict_mode and fb.arg_count > 0 and leaf_body_geometry;
    const sloppy_capture = simple_inline_base and !strict_mode and fb.arg_count == 0 and
        fb.closureVarCount() > 0 and leaf_body_geometry;
    const raw_capture = simple_inline_base and strict_mode and
        fb.arg_count == 0 and fb.closureVarCount() > 0 and leaf_body_geometry;
    // Publication-time image of the per-call entry probe the inline call
    // resolver used to run (`code[0] == OP_check_ctor`). The code bytes
    // are final here (copied and authoritative above), so this is the
    // same predicate evaluated once.
    const entry_code = fb.byteCode();
    const entry_rejects_plain_call = entry_code.len == 0 or
        entry_code[0] == opcode.op.check_ctor;
    // Leftover operands at return stay on the caller stack after rewrite
    // (`return_undef` → `undefined; goto`). The BFS proof is already
    // computed for empty-leaf publication; AND it here so leftover ctor
    // bodies never enter noteMonomorphic. Not a shape special case.
    const small_inline_eligible = scanSmallInlineEligible(fb, facts) and leaf_returns_balanced;
    if (fb.realmContext()) |realm| {
        execution.addSmallInlinePublished(realm.runtime, entry_code.len);
    }

    call_facts.execution = .{
        .has_mapped_arguments = has_mapped_arguments,
        .simple_inline_eligible = simple_inline_base and !strict_mode,
        .strict_simple_inline_eligible = simple_inline_base and strict_mode and !materializes_arguments_object,
        .strict_simple_snapshot_inline_eligible = simple_inline_base and strict_mode and materializes_arguments_object,
        .simple_inline_empty_leaf = simple_inline_base and !strict_mode and empty_leaf_geometry,
        .raw_this_inline_empty_leaf = simple_inline_base and strict_mode and empty_leaf_geometry,
        .simple_inline_exact_args_leaf = sloppy_exact,
        .raw_this_inline_exact_args_leaf = raw_exact,
        .exact_args_leaf_kind = if (sloppy_exact) .sloppy else if (raw_exact) .raw_this else .none,
        .capture_leaf_kind = if (sloppy_capture) .sloppy else if (raw_capture) .raw_this else .none,
        .is_module = is_module,
        .entry_rejects_plain_call = entry_rejects_plain_call,
        .small_inline_eligible = small_inline_eligible,
    };
    fb.hotExtensionRequiredMut().async_execution_policy = @intFromEnum(classifyAsyncExecution(fb));
    fb.hotExtensionRequiredMut().call_facts = call_facts;
    // Keep the header-resident hot mirror coherent with the authoritative
    // FAM word (canonicalCallFacts reads the mirror).
    fb.call_facts_mirror = call_facts;
}

pub const destroyFromHeader = function_bytecode_mod.destroyFromHeader;
pub const Bytecode = BytecodeImpl;
