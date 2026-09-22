const std = @import("std");
const mem_ops = @import("../core/memory.zig");
const bytecode = @import("../bytecode.zig");
const builtin = @import("builtin");
const atom = @import("../core/atom.zig");
const bulk_memory = @import("../core/bulk_memory.zig");
const context = @import("../core/context.zig");
const gc = @import("../core/gc.zig");
const memory = @import("../core/memory.zig");
const runtime = @import("../core/runtime.zig");
const JSValue = @import("../core/value.zig").JSValue;
const compiler = @import("../compiler/root.zig");
const Bytecode = bytecode.Bytecode;
const pipeline = bytecode.pipeline;
const opcode = bytecode.opcode;
const module = bytecode.module;
const EntryContract = bytecode.EntryContract;
const pipeline_pc2line = bytecode.pipeline.pc2line;
const function_bytecode = @This();

pub const AsyncExecutionPolicy = enum(u16) { unknown, no_suspend, may_suspend };

/// Mirrors `JSFunctionKindEnum`.
pub const FunctionKind = enum(u2) {
    normal = 0,
    generator = 1 << 0,
    async = 1 << 1,
    async_generator = 3, // generator | async
};

/// Mirrors `JSClosureTypeEnum`.
pub const ClosureType = enum(u3) {
    local, // 'var_idx' is the index of a local variable in the parent function
    arg, // 'var_idx' is the index of an argument variable in the parent function
    ref, // 'var_idx' is the index of a closure variable in the parent function
    global_ref, // 'var_idx' is the index of a closure variable referencing a global variable
    global_decl, // global variable declaration (eval code only)
    global, // global variable (eval code only)
    module_decl, // definition of a module variable (eval code only)
    module_import, // definition of a module import (eval code only)
};

/// Mirrors `JSVarKindEnum`.
pub const VarKind = enum(u4) {
    normal = 0,
    function_decl = 1, // lexical var with function declaration
    new_function_decl = 2, // lexical var with async/generator function declaration
    catch_ = 3,
    function_name = 4, // function expression name
    private_field = 5,
    private_method = 6,
    private_getter = 7,
    private_setter = 8,
    private_getter_setter = 9,
    /// QuickJS JS_VAR_GLOBAL_FUNCTION_DECL: validation/property surgery
    /// class for a non-lexical GLOBAL_DECL carrier. Distinct from a local
    /// lexical function declaration; initialization still lives in the
    /// fclosure/put_var_ref prefix.
    global_function_decl = 10,
};

/// Sentinel used when a local/argument binding has no frame-open cell.
/// Valid binding indices are dense in `[0, open_var_ref_count)`.
pub const no_open_binding: u16 = std.math.maxInt(u16);

/// QuickJS's special end marker for a lexical chain that terminates in the
/// separate parameter environment (`ARG_SCOPE_END`, quickjs.c).
pub const arg_scope_end: i32 = -2;

/// Mirrors `JSVarDef`.
pub const VarDef = struct {
    var_name: atom.Atom,
    scope_level: i32, // index into scopes of this variable lexical scope
    scope_next: i32 = -1, // index into vars of the next variable in the same or enclosing lexical scope
    /// Constant-pool entry for the function declaration hoisted into this
    /// binding.  As in QuickJS, duplicate body declarations overwrite this
    /// one slot, so the prologue emits only the last initializer.
    func_pool_idx: ?u32 = null,
    is_lexical: bool = false,
    is_const: bool = false,
    is_captured: bool = false,
    /// Parser-only discriminator used while pairing private accessors.
    /// QuickJS drops this bit when JSVarDef becomes JSBytecodeVarDef.
    is_static_private: bool = false,
    tdz_emitted_at_decl: bool = false,
    var_kind: VarKind = .normal,
    /// Stable index into the owning frame's open-binding table. This is the
    /// zjs counterpart of qjs `JSVarDef.var_ref_idx`; locals and arguments
    /// remain plain JSValue slots regardless of capture state.
    open_binding_idx: u16 = no_open_binding,
};

/// Final runtime variable row, mirroring `JSBytecodeVarDef`
///. Unlike the compile-time `VarDef`, this carries
/// only data read after finalization. Arguments and locals occupy one
/// contiguous table in `FunctionBytecode`, with arguments first.
pub const BytecodeVarDef = extern struct {
    var_name: atom.Atom,
    scope_next: i32 = -1,
    flags: u8 = 0,
    reserved: u8 = 0,
    var_ref_idx: u16 = 0,

    const is_const_mask: u8 = 1 << 0;
    const is_lexical_mask: u8 = 1 << 1;
    const is_captured_mask: u8 = 1 << 2;
    const has_scope_mask: u8 = 1 << 3;
    const var_kind_shift = 4;
    const var_kind_mask: u8 = 0xf << var_kind_shift;

    pub const Init = struct {
        var_name: atom.Atom,
        scope_next: i32 = -1,
        is_const: bool = false,
        is_lexical: bool = false,
        is_captured: bool = false,
        has_scope: bool = false,
        var_kind: VarKind = .normal,
        var_ref_idx: u16 = 0,
    };

    pub fn init(value: Init) BytecodeVarDef {
        return .{
            .var_name = value.var_name,
            .scope_next = value.scope_next,
            .flags = (if (value.is_const) is_const_mask else 0) |
                (if (value.is_lexical) is_lexical_mask else 0) |
                (if (value.is_captured) is_captured_mask else 0) |
                (if (value.has_scope) has_scope_mask else 0) |
                (@as(u8, @intFromEnum(value.var_kind)) << var_kind_shift),
            .var_ref_idx = if (value.is_captured) value.var_ref_idx else 0,
        };
    }

    pub fn fromCompile(vd: VarDef, scope_next: i32) BytecodeVarDef {
        return init(.{
            .var_name = vd.var_name,
            .scope_next = scope_next,
            .is_const = vd.is_const,
            .is_lexical = vd.is_lexical,
            .is_captured = vd.is_captured,
            .has_scope = vd.scope_level != 0,
            .var_kind = vd.var_kind,
            // QuickJS leaves this zero for uncaptured rows and consults it
            // only when is_captured is set. Do not persist zjs's compile-
            // time no_open_binding sentinel into the runtime artifact.
            .var_ref_idx = if (vd.is_captured) vd.open_binding_idx else 0,
        });
    }

    pub inline fn isConst(self: BytecodeVarDef) bool {
        return self.flags & is_const_mask != 0;
    }

    pub inline fn isLexical(self: BytecodeVarDef) bool {
        return self.flags & is_lexical_mask != 0;
    }

    pub inline fn isCaptured(self: BytecodeVarDef) bool {
        return self.flags & is_captured_mask != 0;
    }

    pub inline fn hasScope(self: BytecodeVarDef) bool {
        return self.flags & has_scope_mask != 0;
    }

    pub inline fn varKind(self: BytecodeVarDef) VarKind {
        return @enumFromInt((self.flags & var_kind_mask) >> var_kind_shift);
    }
};

/// Shared compile/final closure row, byte-for-byte matching QuickJS's
/// `JSClosureVar` on the supported little-endian targets. Explicit bytes
/// make the bit contract independent of Zig packed-struct layout rules.
pub const ClosureVar = extern struct {
    flags: u8,
    kind_flags: u8,
    var_idx: u16, // index to a normal variable of the parent function, or index to a closure variable
    var_name: atom.Atom,

    const closure_type_mask: u8 = 0x07;
    const is_lexical_mask: u8 = 1 << 3;
    const is_const_mask: u8 = 1 << 4;
    const var_kind_mask: u8 = 0x0f;

    pub const Init = struct {
        closure_type: ClosureType,
        is_lexical: bool = false,
        is_const: bool = false,
        var_kind: VarKind = .normal,
        var_idx: u16,
        var_name: atom.Atom,
    };

    pub fn init(value: Init) ClosureVar {
        return .{
            .flags = @as(u8, @intFromEnum(value.closure_type)) |
                (if (value.is_lexical) is_lexical_mask else 0) |
                (if (value.is_const) is_const_mask else 0),
            .kind_flags = @intFromEnum(value.var_kind),
            .var_idx = value.var_idx,
            .var_name = value.var_name,
        };
    }

    pub inline fn closureType(self: ClosureVar) ClosureType {
        return @enumFromInt(self.flags & closure_type_mask);
    }

    pub inline fn isLexical(self: ClosureVar) bool {
        return self.flags & is_lexical_mask != 0;
    }

    pub inline fn isConst(self: ClosureVar) bool {
        return self.flags & is_const_mask != 0;
    }

    pub inline fn varKind(self: ClosureVar) VarKind {
        return @enumFromInt(self.kind_flags & var_kind_mask);
    }

    pub fn toInit(self: ClosureVar) Init {
        return .{
            .closure_type = self.closureType(),
            .is_lexical = self.isLexical(),
            .is_const = self.isConst(),
            .var_kind = self.varKind(),
            .var_idx = self.var_idx,
            .var_name = self.var_name,
        };
    }
};

/// Finalization transfers the same physical row instead of translating to
/// a second, layout-divergent Zig struct.
pub const BytecodeClosureVar = ClosureVar;

/// Compile-time result of resolving an eval declaration's variable
/// environment. The index variants address the finalized closure_var table.
pub const EvalBindingTarget = union(enum(u8)) {
    unresolved,
    global,
    closure: u16,
    var_object: u16,
};

/// Mirrors `JSGlobalVar`.
pub const GlobalVar = struct {
    cpool_idx: i32,
    force_init: bool = false,
    is_configurable: bool = false,
    is_lexical: bool = false,
    is_const: bool = false,
    scope_level: i32,
    var_name: atom.Atom,
    eval_target: EvalBindingTarget = .unresolved,
};

/// Exact optional QuickJS debug tail (`JSFunctionBytecode.debug`). It is
/// stored inline immediately after the 96-byte base when `has_debug` is
/// set, never as a separately allocated box.
pub const DebugInfo = extern struct {
    filename: atom.Atom,
    source_len: i32,
    pc2line_len: i32,
    _padding: u32,
    pc2line_buf: ?[*]u8,
    /// NUL-terminated allocation whose logical length is `source_len`.
    source_ptr: ?[*:0]const u8,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
        std.debug.assert(@alignOf(@This()) == 8);
        std.debug.assert(@offsetOf(@This(), "filename") == 0x00);
        std.debug.assert(@offsetOf(@This(), "source_len") == 0x04);
        std.debug.assert(@offsetOf(@This(), "pc2line_len") == 0x08);
        std.debug.assert(@offsetOf(@This(), "_padding") == 0x0c);
        std.debug.assert(@offsetOf(@This(), "pc2line_buf") == 0x10);
        std.debug.assert(@offsetOf(@This(), "source_ptr") == 0x18);
        std.debug.assert(@sizeOf(?[*]u8) == @sizeOf(usize));
        std.debug.assert(@sizeOf(?[*:0]const u8) == @sizeOf(usize));
    }
};

/// zjs execution classifications with no QuickJS header counterpart.
/// They are published once by the finalizer and read directly from the FB;
/// no attach/call path may scan bytecode or allocate a parallel record.
pub const ExactArgsLeafKind = enum(u2) {
    none = 0,
    sloppy = 1,
    raw_this = 2,
};

pub const ExecutionFlags = packed struct(u16) {
    has_mapped_arguments: bool = false,
    simple_inline_eligible: bool = false,
    strict_simple_inline_eligible: bool = false,
    strict_simple_snapshot_inline_eligible: bool = false,
    simple_inline_empty_leaf: bool = false,
    raw_this_inline_empty_leaf: bool = false,
    simple_inline_exact_args_leaf: bool = false,
    raw_this_inline_exact_args_leaf: bool = false,
    exact_args_leaf_kind: ExactArgsLeafKind = .none,
    capture_leaf_kind: ExactArgsLeafKind = .none,
    /// The finalized root is an ECMAScript module body.
    is_module: bool = false,
    /// Publication-time image of the entry-opcode probe
    /// `byte_code[0] == OP_check_ctor` (base-class constructors): plain
    /// [[Call]] must take the authoritative slow path so rejection runs
    /// with full construct-context semantics. Published code is immutable,
    /// so hoisting the probe out of per-call resolution is exact. qjs
    /// needs no such bit — its OP_check_ctor throws inside the callee
    /// — but zjs's inline frame constructors must reject
    /// before entering. Derived constructors keep the canonical qjs
    /// header bit; this covers only the base-class entry probe.
    entry_rejects_plain_call: bool = false,
    /// Geometry-only small-function body-expansion candidate. Not the
    /// existing same-machine `simple_inline_eligible` Entry path.
    small_inline_eligible: bool = false,
    /// This image contains a rewritten L1 apply-forward site
    /// (`op.call_method_apply_fwd`). Consulted by constructor TAKE and
    /// D8-L1 native_caller attach — not by vanilla `op_call_method`.
    apply_forward_inlined: bool = false,
};

/// Immutable execution policy published before a FunctionBytecode escapes.
/// Hot call resolution takes one coherent 16-bit snapshot and threads it
/// through the selected inline target.
pub const CallFacts = packed struct(u16) {
    execution: ExecutionFlags = .{},

    comptime {
        std.debug.assert(@sizeOf(@This()) == 2);
        std.debug.assert(@bitOffsetOf(@This(), "execution") == 0);
    }
};

/// Widest named-property reserve the constructor allocation profile will
/// learn. Larger instances still construct; they just stop growing the hint.
pub const max_ctor_alloc_capacity: u16 = 32;

pub const CtorAllocState = enum(u8) {
    empty = 0,
    live = 1,
    inert = 2,
};

/// Learned property-slot reserve for `new`. Zero-fill is `empty`.
/// Lives in the FB hot tail (not Object/Shape) so qjs's 96-byte header
/// offsets stay untouched. No heap pointers — GC mark is unchanged.
pub const CtorAllocProfile = extern struct {
    capacity: u16 = 0,
    state: CtorAllocState = .empty,
    _pad: [5]u8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(@This()) == 8);
    }
};

/// Per-property-site inline cache (W1, Hermes `ReadPropertyCacheEntry`
/// shape; native-boundary design 8.2 / 15 R8). One slot per `get_field` /
/// `get_field2` / `put_field` / fused-form instruction, named by that
/// instruction's trailing `cache_idx` operand.
///
/// Guards (representation contract 5.2: slot caches hold NON-OWNING
/// references and must be validated by version/identity, never by
/// pointer):
///   - `guard_key` = the receiver `Shape.identity` (monotonic, never
///     reused, refreshed before every in-place shape mutation), so a
///     recycled Shape address can never re-match;
///   - `proto_key` = the HOLDER `Shape.identity` on the prototype arms
///     (zero on `.own`); the receiver's own key already pins WHICH object
///     is its prototype, because `proto` lives in the shape;
///   - `class_id` = the receiver's class, which the shape does NOT pin.
///     Required by every arm that walks past the receiver's own shape,
///     since exotic own-property behaviour (Array `length`, typed-array
///     and string indices, Proxy, module namespaces) is a property of the
///     class, not of the layout.
///   - `secondary_guard_key` = a second own-data layout identity, zero
///     unless `.own`; `secondary_slot` is its receiver slot. Prototype
///     and native-getter arms never carry a secondary entry.
/// Nothing here is a GC edge: no slot holds a heap pointer. Storage is
/// the `prop_sites` FAM tail of the owning FunctionBytecode,
/// zero-initialised with it and freed with it.
///
/// 32 bytes, i.e. a power of two, so site addressing is `base + (idx << 5)`
/// instead of a multiply (PERF-T-SPIKE fairness rule 2: a 24-byte stride
/// put a `madd` on the hit path and under-priced nothing but the cache).
pub const PropSiteCache = extern struct {
    guard_key: u64 = 0,
    proto_key: u64 = 0,
    /// Index into the HOLDER's `prop_values` (own arm: the receiver).
    slot: u16 = 0,
    /// Receiver `class_id` for the arms that need it (see above).
    class_id: u16 = 0,
    state: u8 = @intFromEnum(State.empty),
    misses: u8 = 0,
    /// Second own-data arm; its guard is zero on every non-own state.
    secondary_slot: u16 = 0,
    secondary_guard_key: u64 = 0,

    pub const State = enum(u8) {
        /// Never captured. `guard_key` is 0 and identities start at 1, so
        /// an empty entry can never guard-match and the hit path needs no
        /// separate emptiness test.
        empty,
        /// Up to two own-data layouts on the receiver.
        own,
        /// Data slot one prototype link up.
        proto,
        /// Native (K3) accessor `get` one prototype link up.
        native_getter,
        /// Retired after `miss_budget` misses; never captured again.
        mega,
    };

    /// The operand value that means "this site has no cache slot".
    pub const no_cache_idx: u8 = 255;

    /// Hermes overwrites a missed entry rather than locking it
    /// monomorphic (`Interpreter.cpp` GET_BY_ID_IMPL); the 2026-09-06
    /// T-spike re-run priced permanent locking at -9.8% on poly_stress.
    /// A site that keeps missing after this many overwrites is genuinely
    /// polymorphic and retires to `.mega`.
    pub const miss_budget: u8 = 4;

    comptime {
        std.debug.assert(@sizeOf(@This()) == 32);
        std.debug.assert(@alignOf(@This()) == 8);
        std.debug.assert(@offsetOf(@This(), "guard_key") == 0);
        std.debug.assert(@offsetOf(@This(), "proto_key") == 8);
        std.debug.assert(@offsetOf(@This(), "slot") == 16);
        std.debug.assert(@offsetOf(@This(), "class_id") == 18);
        std.debug.assert(@offsetOf(@This(), "state") == 20);
        std.debug.assert(@offsetOf(@This(), "misses") == 21);
        std.debug.assert(@offsetOf(@This(), "secondary_slot") == 22);
        std.debug.assert(@offsetOf(@This(), "secondary_guard_key") == 24);
    }
};

/// Hot zjs-only state placed immediately after the exact code bytes. Code
/// has byte alignment, so canonical access must use `*align(1)`. The
/// execution snapshot is two bytes; explicit padding preserves the
/// four-byte ScriptOrModule offset.
///
/// The total stays a multiple of eight.
pub const FunctionBytecodeHotExtension = extern struct {
    call_facts: function_bytecode.CallFacts,
    /// Preserve ScriptOrModule's aligned offset without widening CallFacts
    /// back into a second semantic carrier.
    async_execution_policy: u16 = 0,
    /// Stable ScriptOrModule identity used as the dynamic-import referrer.
    script_or_module: atom.Atom,
    ctor_alloc: CtorAllocProfile = .{},
    /// small_inline owns bytes 0..24 (CallerState pointer, borrowed
    /// realm word, apply-forward memo byte); the rest of the original
    /// 32-byte pad now carries the W1 property-site array pointer below.
    _ctor_alloc_pad: [24]u8 = @splat(0),
    /// Property-site cache slots: `prop_site_count` entries at the
    /// aligned `prop_sites` FAM tail behind this extension (null when
    /// zero). Written once by `FunctionLayout.seedHeader`; the layout
    /// re-reads `prop_site_count` to size the allocation on teardown.
    prop_sites: ?[*]function_bytecode.PropSiteCache = null,
    prop_site_count: u16 = 0,
    _tail_pad: [6]u8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(@This()) == 56);
        std.debug.assert(@sizeOf(@This()) % 8 == 0);
        std.debug.assert(@offsetOf(@This(), "call_facts") == 0x00);
        std.debug.assert(@offsetOf(@This(), "async_execution_policy") == 0x02);
        std.debug.assert(@offsetOf(@This(), "script_or_module") == 0x04);
        std.debug.assert(@offsetOf(@This(), "ctor_alloc") == 0x08);
        std.debug.assert(@offsetOf(@This(), "prop_sites") == 0x28);
        std.debug.assert(@offsetOf(@This(), "prop_site_count") == 0x30);
    }
};

/// Mirrors `JSFunctionBytecode`.
///
/// This is the final compiled bytecode structure produced by the
/// js_create_function equivalent. It contains the fully processed bytecode
/// after all bytecode pipeline phases. Core owns this GC object so runtime,
/// object graph cleanup, and tracing can operate without depending on the
/// bytecode compile-time module.
///
/// The fixed record is the exact 96-byte, align-8 QuickJS core header.
/// Optional debug metadata and zjs-only state are addressed as inline FAM
/// tails and therefore cannot perturb any core offset.
pub const FunctionBytecodeImpl = extern struct {
    pub const gc_kind_tag: u8 = @intFromEnum(gc.GcKind.function_bytecode);

    /// Logical initialization carrier only. The physical representation is
    /// `js_mode` plus the two explicit integer bytes below; accessors apply
    /// masks so no Zig packed-bitfield layout is trusted.
    pub const Flags = struct {
        is_strict_mode: bool = false,
        runtime_strict_mode: bool = false,
        has_prototype: bool = false,
        has_simple_parameter_list: bool = true,
        is_derived_class_constructor: bool = false,
        need_home_object: bool = false,
        func_kind: FunctionKind = .normal,
        new_target_allowed: bool = false,
        super_call_allowed: bool = false,
        super_allowed: bool = false,
        arguments_allowed: bool = false,
        is_direct_or_indirect_eval: bool = false,
    };

    pub const js_mode_strict_mask: u8 = 1 << 0;
    pub const byte17_has_prototype_mask: u8 = 1 << 0;
    pub const byte17_simple_parameters_mask: u8 = 1 << 1;
    pub const byte17_derived_constructor_mask: u8 = 1 << 2;
    pub const byte17_need_home_object_mask: u8 = 1 << 3;
    pub const byte17_func_kind_shift: u3 = 4;
    pub const byte17_func_kind_mask: u8 = 0b11 << byte17_func_kind_shift;
    pub const byte17_new_target_mask: u8 = 1 << 6;
    pub const byte17_super_call_mask: u8 = 1 << 7;
    pub const byte18_super_mask: u8 = 1 << 0;
    pub const byte18_arguments_mask: u8 = 1 << 1;
    pub const byte18_has_debug_mask: u8 = 1 << 2;
    pub const byte18_rom_mask: u8 = 1 << 3;
    pub const byte18_eval_mask: u8 = 1 << 4;
    /// Named zjs extension bits in QuickJS's otherwise-unused high bits.
    pub const byte18_has_extension_mask: u8 = 1 << 5;
    pub const byte18_runtime_strict_mask: u8 = 1 << 6;

    // quickjs.c JSFunctionBytecode, exact offsets on the pinned 64-bit ABI.
    header: gc.Header, // 0x00
    js_mode: u8, // 0x10
    flag_byte17: u8, // 0x11
    flag_byte18: u8, // 0x12
    _flag_padding0: u8, // 0x13, js_mallocz zero hole
    /// Header-resident image of the hot-extension CallFacts word, living
    /// in QuickJS's 0x13..0x17 flag-padding hole so no core offset moves.
    /// The FAM tail behind the code bytes stays authoritative (it is what
    /// layout/serialization own); both copies are written together by the
    /// only two publication funnels (publishExecutionFlags /
    /// setExecutionFlags), so per-call resolution reads one fixed-offset
    /// halfword instead of a code-ptr + code-len dependent tail load that
    /// touches the far end of the bytecode array every call.
    call_facts_mirror: function_bytecode.CallFacts, // 0x14
    _flag_padding: [2]u8, // 0x16..0x17, js_mallocz zero holes
    byte_code: ?[*]u8, // 0x18
    byte_code_len: i32, // 0x20
    func_name: atom.Atom,
    vardefs: ?[*]BytecodeVarDef, // 0x28
    closure_var: ?[*]BytecodeClosureVar, // 0x30
    arg_count: u16, // 0x38
    var_count: u16,
    defined_arg_count: u16,
    stack_size: u16,
    var_ref_count: u16, // 0x40, open local/argument VarRefs
    _realm_padding: [6]u8,
    realm: context.RealmRef, // 0x48
    cpool: ?[*]JSValue, // 0x50
    cpool_count: i32,
    closure_var_count: i32,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 88);
        std.debug.assert(@alignOf(@This()) == 8);
        std.debug.assert(@offsetOf(@This(), "header") == 0x00);
        const header_bytes = @sizeOf(gc.Header);
        std.debug.assert(@offsetOf(@This(), "js_mode") == header_bytes);
        std.debug.assert(@offsetOf(@This(), "flag_byte17") == header_bytes + 1);
        std.debug.assert(@offsetOf(@This(), "flag_byte18") == header_bytes + 2);
        std.debug.assert(@offsetOf(@This(), "_flag_padding0") == header_bytes + 3);
        std.debug.assert(@offsetOf(@This(), "call_facts_mirror") == header_bytes + 4);
        std.debug.assert(@offsetOf(@This(), "_flag_padding") == header_bytes + 6);
        std.debug.assert(@offsetOf(@This(), "byte_code") == header_bytes + 8);
        std.debug.assert(@offsetOf(@This(), "byte_code_len") == header_bytes + 16);
        std.debug.assert(@offsetOf(@This(), "func_name") == header_bytes + 20);
        std.debug.assert(@offsetOf(@This(), "vardefs") == header_bytes + 24);
        std.debug.assert(@offsetOf(@This(), "closure_var") == header_bytes + 32);
        std.debug.assert(@offsetOf(@This(), "arg_count") == header_bytes + 40);
        std.debug.assert(@offsetOf(@This(), "var_count") == header_bytes + 42);
        std.debug.assert(@offsetOf(@This(), "defined_arg_count") == header_bytes + 44);
        std.debug.assert(@offsetOf(@This(), "stack_size") == header_bytes + 46);
        std.debug.assert(@offsetOf(@This(), "var_ref_count") == header_bytes + 48);
        std.debug.assert(@offsetOf(@This(), "_realm_padding") == header_bytes + 50);
        std.debug.assert(@offsetOf(@This(), "realm") == header_bytes + 56);
        std.debug.assert(@offsetOf(@This(), "cpool") == header_bytes + 64);
        std.debug.assert(@offsetOf(@This(), "cpool_count") == header_bytes + 72);
        std.debug.assert(@offsetOf(@This(), "closure_var_count") == header_bytes + 76);
        std.debug.assert(@sizeOf(?[*]BytecodeVarDef) == @sizeOf(usize));
        std.debug.assert(@sizeOf(?[*]BytecodeClosureVar) == @sizeOf(usize));
        std.debug.assert(@sizeOf(?[*]JSValue) == @sizeOf(usize));
        std.debug.assert(@sizeOf(context.RealmRef) == @sizeOf(usize));
        std.debug.assert(@alignOf(DebugInfo) <= @alignOf(@This()));
    }

    inline fn bit(byte: u8, mask: u8) bool {
        return byte & mask != 0;
    }

    inline fn assignBit(byte: *u8, mask: u8, enabled: bool) void {
        if (enabled) byte.* |= mask else byte.* &= ~mask;
    }

    pub inline fn hasDebug(self: *const FunctionBytecodeImpl) bool {
        return bit(self.flag_byte18, byte18_has_debug_mask);
    }

    pub inline fn hasExtension(self: *const FunctionBytecodeImpl) bool {
        return bit(self.flag_byte18, byte18_has_extension_mask);
    }

    pub fn layout(self: *const FunctionBytecodeImpl) function_bytecode.FunctionLayout {
        return function_bytecode.FunctionLayout.fromFunction(self) catch unreachable;
    }

    pub inline fn famBytes(self: *const FunctionBytecodeImpl) usize {
        return self.layout().famBytes();
    }

    pub inline fn debugInfo(self: *const FunctionBytecodeImpl) ?*const DebugInfo {
        if (!self.hasDebug()) return null;
        const bytes: [*]const u8 = @ptrCast(self);
        return @ptrCast(@alignCast(bytes + @sizeOf(FunctionBytecodeImpl)));
    }

    pub inline fn debugInfoMut(self: *FunctionBytecodeImpl) ?*DebugInfo {
        if (!self.hasDebug()) return null;
        const bytes: [*]u8 = @ptrCast(self);
        return @ptrCast(@alignCast(bytes + @sizeOf(FunctionBytecodeImpl)));
    }

    pub inline fn hotExtension(self: *const FunctionBytecodeImpl) ?*align(1) const FunctionBytecodeHotExtension {
        if (!bit(self.flag_byte18, byte18_has_extension_mask)) return null;
        // Canonical production bytecode is non-empty and self-owned. The
        // hot extension begins at exact code_end, so CallFacts needs no
        // table/count walk or alignment arithmetic.
        if (self.byte_code) |ptr| {
            return canonicalHotExtension(ptr, self.byte_code_len);
        }
        return self.hotExtensionSlow();
    }

    /// Leaf-safe sibling of `hotExtension` for resident handlers: the
    /// canonical (self-owned, materialized) layout only, never the
    /// outlined layout probe, so a handler that reads it in a cold leg
    /// keeps no frame.
    pub inline fn hotExtensionCanonical(self: *const FunctionBytecodeImpl) ?*align(1) const FunctionBytecodeHotExtension {
        if (!bit(self.flag_byte18, byte18_has_extension_mask)) return null;
        const ptr = self.byte_code orelse return null;
        return canonicalHotExtension(ptr, self.byte_code_len);
    }

    pub inline fn hotExtensionMut(self: *FunctionBytecodeImpl) ?*align(1) FunctionBytecodeHotExtension {
        if (!bit(self.flag_byte18, byte18_has_extension_mask)) return null;
        if (self.byte_code) |ptr| {
            return @constCast(canonicalHotExtension(ptr, self.byte_code_len));
        }
        return self.hotExtensionMutSlow();
    }

    inline fn canonicalHotAddress(code_ptr: [*]const u8, code_len: i32) usize {
        std.debug.assert(code_len > 0);
        @setRuntimeSafety(false);
        // FunctionLayout checked this addition before publishing the
        // canonical self-pointer and length.
        return @intFromPtr(code_ptr) +% @as(usize, @intCast(code_len));
    }

    inline fn canonicalHotExtension(
        code_ptr: [*]const u8,
        code_len: i32,
    ) *align(1) const FunctionBytecodeHotExtension {
        return @ptrFromInt(canonicalHotAddress(code_ptr, code_len));
    }

    noinline fn hotExtensionSlow(self: *const FunctionBytecodeImpl) *align(1) const FunctionBytecodeHotExtension {
        const bytes: [*]const u8 = @ptrCast(self);
        const offset = self.layout().hot_off.?;
        return @ptrCast(bytes + offset);
    }

    noinline fn hotExtensionMutSlow(self: *FunctionBytecodeImpl) *align(1) FunctionBytecodeHotExtension {
        const bytes: [*]u8 = @ptrCast(self);
        const offset = self.layout().hot_off.?;
        return @ptrCast(bytes + offset);
    }

    pub inline fn hotExtensionRequiredMut(self: *FunctionBytecodeImpl) *align(1) FunctionBytecodeHotExtension {
        return self.hotExtensionMut().?;
    }

    /// Fast-path accessor for callers that have already established a
    /// canonical non-empty code pointer and extension presence. It skips
    /// the optional-tail discriminator; general consumers must use
    /// `callFacts()` below.
    pub inline fn canonicalCallFacts(self: *const FunctionBytecodeImpl) function_bytecode.CallFacts {
        // Production publication rejects empty code and always installs
        // the zjs tail, and every publication funnel writes the header
        // mirror together with the authoritative FAM word — so the hot
        // read is one fixed-offset halfword instead of a code-ptr +
        // code-len dependent load that touches the far end of the
        // bytecode array. Keep the mirror self-checking in Debug so
        // fixture/embedding misuse fails at the contract boundary.
        std.debug.assert(self.hasExtension());
        std.debug.assert(self.byte_code != null);
        std.debug.assert(self.byte_code_len > 0);
        if (comptime builtin.mode == .Debug) {
            @setRuntimeSafety(false);
            const code_ptr = self.byte_code.?;
            const code_len: usize = @intCast(self.byte_code_len);
            const hot: *align(1) const FunctionBytecodeHotExtension =
                @ptrFromInt(@intFromPtr(code_ptr) +% code_len);
            std.debug.assert(@as(u16, @bitCast(hot.call_facts)) ==
                @as(u16, @bitCast(self.call_facts_mirror)));
        }
        return self.call_facts_mirror;
    }

    pub fn applyFlags(self: *FunctionBytecodeImpl, flags: Flags) void {
        assignBit(&self.js_mode, js_mode_strict_mask, flags.is_strict_mode);
        assignBit(&self.flag_byte17, byte17_has_prototype_mask, flags.has_prototype);
        assignBit(&self.flag_byte17, byte17_simple_parameters_mask, flags.has_simple_parameter_list);
        assignBit(&self.flag_byte17, byte17_derived_constructor_mask, flags.is_derived_class_constructor);
        assignBit(&self.flag_byte17, byte17_need_home_object_mask, flags.need_home_object);
        self.flag_byte17 = (self.flag_byte17 & ~byte17_func_kind_mask) |
            (@as(u8, @intFromEnum(flags.func_kind)) << byte17_func_kind_shift);
        assignBit(&self.flag_byte17, byte17_new_target_mask, flags.new_target_allowed);
        assignBit(&self.flag_byte17, byte17_super_call_mask, flags.super_call_allowed);
        assignBit(&self.flag_byte18, byte18_super_mask, flags.super_allowed);
        assignBit(&self.flag_byte18, byte18_arguments_mask, flags.arguments_allowed);
        assignBit(&self.flag_byte18, byte18_eval_mask, flags.is_direct_or_indirect_eval);
        assignBit(&self.flag_byte18, byte18_runtime_strict_mask, flags.runtime_strict_mode);
    }

    pub inline fn functionKind(self: *const FunctionBytecodeImpl) FunctionKind {
        return @enumFromInt((self.flag_byte17 & byte17_func_kind_mask) >> byte17_func_kind_shift);
    }
    pub inline fn hasPrototype(self: *const FunctionBytecodeImpl) bool {
        return bit(self.flag_byte17, byte17_has_prototype_mask);
    }
    pub inline fn hasSimpleParameterList(self: *const FunctionBytecodeImpl) bool {
        return bit(self.flag_byte17, byte17_simple_parameters_mask);
    }
    pub inline fn isDerivedClassConstructor(self: *const FunctionBytecodeImpl) bool {
        return bit(self.flag_byte17, byte17_derived_constructor_mask);
    }
    pub inline fn needHomeObject(self: *const FunctionBytecodeImpl) bool {
        return bit(self.flag_byte17, byte17_need_home_object_mask);
    }
    pub inline fn newTargetAllowed(self: *const FunctionBytecodeImpl) bool {
        return bit(self.flag_byte17, byte17_new_target_mask);
    }
    pub inline fn superCallAllowed(self: *const FunctionBytecodeImpl) bool {
        return bit(self.flag_byte17, byte17_super_call_mask);
    }
    pub inline fn superAllowed(self: *const FunctionBytecodeImpl) bool {
        return bit(self.flag_byte18, byte18_super_mask);
    }
    pub inline fn argumentsAllowed(self: *const FunctionBytecodeImpl) bool {
        return bit(self.flag_byte18, byte18_arguments_mask);
    }
    pub inline fn isDirectOrIndirectEval(self: *const FunctionBytecodeImpl) bool {
        return bit(self.flag_byte18, byte18_eval_mask);
    }
    pub inline fn callFacts(self: *const FunctionBytecodeImpl) function_bytecode.CallFacts {
        const hot = self.hotExtension() orelse return .{};
        return hot.call_facts;
    }
    pub inline fn ctorAllocProfile(self: *const FunctionBytecodeImpl) ?*align(1) const function_bytecode.CtorAllocProfile {
        const hot = self.hotExtension() orelse return null;
        return &hot.ctor_alloc;
    }
    pub inline fn ctorAllocProfileMut(self: *const FunctionBytecodeImpl) ?*align(1) function_bytecode.CtorAllocProfile {
        const hot = self.hotExtension() orelse return null;
        return &@constCast(hot).ctor_alloc;
    }
    pub inline fn openVarRefCount(self: *const FunctionBytecodeImpl) u16 {
        return self.var_ref_count;
    }
    pub inline fn closureVarCount(self: *const FunctionBytecodeImpl) usize {
        std.debug.assert(self.closure_var_count >= 0);
        return @intCast(self.closure_var_count);
    }
    pub inline fn filenameAtom(self: *const FunctionBytecodeImpl) atom.Atom {
        const dbg = self.debugInfo() orelse return atom.null_atom;
        return dbg.filename;
    }

    // Slice accessors materialize a `[]T` from the bare pointer + length pair.
    // The VM/readers use these instead of touching the raw fields.
    /// Hot-path sibling of `byteCode` for callers holding a proven
    /// materialization invariant: a resolved InlineTarget (its published
    /// call_facts and code[0] eligibility reads exist only for finalized,
    /// materialized FBs) or a resumed caller (its bytecode is executing).
    /// Skips the optional probe branch the interpreter otherwise re-runs
    /// on every call entry and return republication.
    pub inline fn byteCodeAssumeMaterialized(self: *const FunctionBytecodeImpl) []u8 {
        std.debug.assert(self.byte_code != null and self.byte_code_len > 0);
        return self.byte_code.?[0..@intCast(self.byte_code_len)];
    }

    pub inline fn byteCode(self: *const FunctionBytecodeImpl) []u8 {
        // Canonical compiler-produced FBs always have exact, non-empty
        // code in the QJS core pointer/length pair. Keep that path to the
        // two fixed header loads: the Debug tail-dispatch bound assertion
        // calls this accessor for every opcode, so probing the optional
        // legacy extension first would put tail-layout branches in the
        // ordinary interpreter loop. Only the non-escaping mutable-
        // bytecode fixture adapter deliberately leaves the core pointer
        // null.
        if (self.byte_code) |ptr| {
            std.debug.assert(self.byte_code_len > 0);
            return ptr[0..@intCast(self.byte_code_len)];
        }
        return self.byteCodeSlow();
    }

    /// Outlined empty-code arm for byteCode(). Keeping it out of every
    /// Debug threaded-handler instantiation is as important as keeping it
    /// off the dynamic production path.
    noinline fn byteCodeSlow(self: *const FunctionBytecodeImpl) []u8 {
        std.debug.assert(self.byte_code_len >= 0);
        const len: usize = @intCast(self.byte_code_len);
        if (len == 0) {
            return &.{};
        }
        unreachable;
    }
    pub inline fn allVarDefs(self: *const FunctionBytecodeImpl) []BytecodeVarDef {
        const count: usize = @as(usize, self.arg_count) + @as(usize, self.var_count);
        if (count == 0) {
            std.debug.assert(self.vardefs == null);
            return &.{};
        }
        return (self.vardefs.?)[0..count];
    }
    pub inline fn argVarDefs(self: *const FunctionBytecodeImpl) []BytecodeVarDef {
        return self.allVarDefs()[0..self.arg_count];
    }
    pub inline fn localVarDefs(self: *const FunctionBytecodeImpl) []BytecodeVarDef {
        return self.allVarDefs()[self.arg_count..];
    }
    /// Compatibility name for readers whose indices address frame locals.
    pub inline fn varDefs(self: *const FunctionBytecodeImpl) []BytecodeVarDef {
        return self.localVarDefs();
    }
    pub inline fn closureVar(self: *const FunctionBytecodeImpl) []BytecodeClosureVar {
        const count = self.closureVarCount();
        if (count == 0) {
            std.debug.assert(self.closure_var == null);
            return &.{};
        }
        return (self.closure_var.?)[0..count];
    }
    pub inline fn cpoolSlice(self: *const FunctionBytecodeImpl) []JSValue {
        std.debug.assert(self.cpool_count >= 0);
        const count: usize = @intCast(self.cpool_count);
        if (count == 0) {
            std.debug.assert(self.cpool == null);
            return &.{};
        }
        return (self.cpool.?)[0..count];
    }
    pub inline fn constantAt(self: *const FunctionBytecodeImpl, index: usize) ?JSValue {
        const values = self.cpoolSlice();
        if (index >= values.len) return null;
        return values[index];
    }
    pub inline fn funcName(self: *const FunctionBytecodeImpl) atom.Atom {
        return self.func_name;
    }
    pub inline fn varRefIsLexicalAt(self: *const FunctionBytecodeImpl, idx: usize) bool {
        const closure_vars = self.closureVar();
        return idx < closure_vars.len and closure_vars[idx].isLexical();
    }
    pub inline fn varRefIsConstAt(self: *const FunctionBytecodeImpl, idx: usize) bool {
        const closure_vars = self.closureVar();
        return idx < closure_vars.len and closure_vars[idx].isConst();
    }
    pub inline fn varRefIsGlobalDeclAt(self: *const FunctionBytecodeImpl, idx: usize) bool {
        const closure_vars = self.closureVar();
        return idx < closure_vars.len and closure_vars[idx].closureType() == .global_decl;
    }
    pub inline fn varRefNamesLen(self: *const FunctionBytecodeImpl) usize {
        return self.closureVarCount();
    }
    pub inline fn varRefName(self: *const FunctionBytecodeImpl, idx: usize) atom.Atom {
        return self.closureVar()[idx].var_name;
    }
    pub inline fn localOpenBindingIndex(self: *const FunctionBytecodeImpl, idx: usize) ?u16 {
        const vardefs = self.varDefs();
        if (idx >= vardefs.len) return null;
        return if (vardefs[idx].isCaptured()) vardefs[idx].var_ref_idx else null;
    }
    pub inline fn argOpenBindingIndex(self: *const FunctionBytecodeImpl, idx: usize) ?u16 {
        const argdefs = self.argVarDefs();
        if (idx >= argdefs.len) return null;
        return if (argdefs[idx].isCaptured()) argdefs[idx].var_ref_idx else null;
    }
    pub inline fn isModule(self: *const FunctionBytecodeImpl) bool {
        return self.callFacts().execution.is_module;
    }
    pub inline fn isAsync(self: *const FunctionBytecodeImpl) bool {
        return self.functionKind() == .async or self.functionKind() == .async_generator;
    }
    pub inline fn isGenerator(self: *const FunctionBytecodeImpl) bool {
        return self.functionKind() == .generator or self.functionKind() == .async_generator;
    }
    pub inline fn entryContract(self: *const FunctionBytecodeImpl) EntryContract {
        return .{
            .new_target_allowed = self.newTargetAllowed(),
            .super_call_allowed = self.superCallAllowed(),
            .super_allowed = self.superAllowed(),
            .arguments_allowed = self.argumentsAllowed(),
        };
    }
    pub inline fn isStrictMode(self: *const FunctionBytecodeImpl) bool {
        return bit(self.js_mode, js_mode_strict_mask);
    }
    pub inline fn runtimeStrictMode(self: *const FunctionBytecodeImpl) bool {
        // As above, applyFlags publishes the adapter's policy into the
        // named zjs bit before the wrapper can escape to execution.
        return bit(self.flag_byte18, byte18_runtime_strict_mask);
    }
    pub inline fn executionFlags(self: *const FunctionBytecodeImpl) ExecutionFlags {
        return self.callFacts().execution;
    }
    pub inline fn setExecutionFlags(self: *FunctionBytecodeImpl, value: ExecutionFlags) void {
        const hot = self.hotExtensionRequiredMut();
        var facts = hot.call_facts;
        facts.execution = value;
        hot.call_facts = facts;
        // Keep the header-resident hot mirror coherent with the
        // authoritative FAM word (canonicalCallFacts reads the mirror).
        self.call_facts_mirror = facts;
    }
    pub inline fn hasMappedArguments(self: *const FunctionBytecodeImpl) bool {
        return self.executionFlags().has_mapped_arguments;
    }
    pub inline fn simpleInlineEligible(self: *const FunctionBytecodeImpl) bool {
        return self.executionFlags().simple_inline_eligible;
    }
    pub inline fn strictSimpleInlineEligible(self: *const FunctionBytecodeImpl) bool {
        return self.executionFlags().strict_simple_inline_eligible;
    }
    pub inline fn strictSimpleSnapshotInlineEligible(self: *const FunctionBytecodeImpl) bool {
        return self.executionFlags().strict_simple_snapshot_inline_eligible;
    }
    pub inline fn simpleInlineEmptyLeaf(self: *const FunctionBytecodeImpl) bool {
        return self.executionFlags().simple_inline_empty_leaf;
    }
    pub inline fn rawThisInlineEmptyLeaf(self: *const FunctionBytecodeImpl) bool {
        return self.executionFlags().raw_this_inline_empty_leaf;
    }
    pub inline fn simpleInlineExactArgsLeaf(self: *const FunctionBytecodeImpl) bool {
        return self.executionFlags().simple_inline_exact_args_leaf;
    }
    pub inline fn rawThisInlineExactArgsLeaf(self: *const FunctionBytecodeImpl) bool {
        return self.executionFlags().raw_this_inline_exact_args_leaf;
    }
    pub inline fn exactArgsLeafKind(self: *const FunctionBytecodeImpl) ExactArgsLeafKind {
        return self.executionFlags().exact_args_leaf_kind;
    }
    pub inline fn captureLeafKind(self: *const FunctionBytecodeImpl) ExactArgsLeafKind {
        return self.executionFlags().capture_leaf_kind;
    }
    pub inline fn smallInlineEligible(self: *const FunctionBytecodeImpl) bool {
        return self.executionFlags().small_inline_eligible;
    }
    pub inline fn applyForwardInlined(self: *const FunctionBytecodeImpl) bool {
        return self.executionFlags().apply_forward_inlined;
    }
    pub inline fn pc2lineBuf(self: *const FunctionBytecodeImpl) []u8 {
        const dbg = self.debugInfo() orelse return &.{};
        std.debug.assert(dbg.pc2line_len >= 0);
        const len: usize = @intCast(dbg.pc2line_len);
        if (len == 0) {
            std.debug.assert(dbg.pc2line_buf == null);
            return &.{};
        }
        return (dbg.pc2line_buf.?)[0..len];
    }
    /// Starting source line, or 0 when no debug info was captured.
    pub inline fn lineNum(self: *const FunctionBytecodeImpl) i32 {
        const bytes = self.pc2lineBuf();
        if (bytes.len != 0) {
            if (pipeline_pc2line.decodeHeader(bytes)) |header| return header.line_num else |_| return 0;
        }
        return 0;
    }
    /// Starting source column, or 0 when no debug info was captured.
    pub inline fn colNum(self: *const FunctionBytecodeImpl) i32 {
        const bytes = self.pc2lineBuf();
        if (bytes.len != 0) {
            if (pipeline_pc2line.decodeHeader(bytes)) |header| return header.col_num else |_| return 0;
        }
        return 0;
    }
    /// Original source text, or `null` if none was captured. Materializes the
    /// `[]const u8` from the boxed `source_ptr` + `source_len` pair.
    pub inline fn sourceText(self: *const FunctionBytecodeImpl) ?[]const u8 {
        const dbg = self.debugInfo() orelse return null;
        const ptr = dbg.source_ptr orelse return null;
        std.debug.assert(dbg.source_len >= 0);
        return ptr[0..@intCast(dbg.source_len)];
    }

    pub inline fn scriptOrModule(self: *const FunctionBytecodeImpl) atom.Atom {
        if (self.hotExtension()) |hot| {
            if (hot.script_or_module != atom.null_atom) return hot.script_or_module;
        }
        return self.filenameAtom();
    }

    /// Number of call-site cache slots (0 for fixtures, legacy adapters
    /// and functions without an extension tail).
    pub inline fn propSiteCount(self: *const FunctionBytecodeImpl) u16 {
        const hot = self.hotExtension() orelse return 0;
        return hot.prop_site_count;
    }

    /// The property-site slot a field instruction's `cache_idx` operand
    /// names, or null for the no-cache index (255) and for indices past
    /// the function's slot count (fixture streams carry placeholder
    /// bytes). The resident handlers do not call this: they read
    /// `Vm.prop_sites` (published per frame) so the hit path is one
    /// shifted index, no optional and no extension walk.
    pub inline fn propSiteCache(self: *const FunctionBytecodeImpl, idx: u8) ?*function_bytecode.PropSiteCache {
        if (idx == function_bytecode.PropSiteCache.no_cache_idx) return null;
        const hot = self.hotExtension() orelse return null;
        if (idx >= hot.prop_site_count) return null;
        const sites = hot.prop_sites orelse return null;
        return &sites[idx];
    }

    fn createRaw(
        rt: *runtime.JSRuntime,
        layout_value: function_bytecode.FunctionLayout,
    ) !*FunctionBytecodeImpl {
        const result = try mem_ops.createWithFam(rt, FunctionBytecodeImpl, layout_value.famBytes());
        const payload: [*]u8 = @ptrCast(result);
        bulk_memory.fillByte(payload[0..layout_value.mainPayloadBytes()], 0);
        assignBit(&result.flag_byte18, byte18_has_debug_mask, layout_value.has_debug);
        assignBit(&result.flag_byte18, byte18_has_extension_mask, layout_value.has_extension);
        // Seed every layout-driving count and self-pointer before any
        // extension accessor runs. The W1c5 extension follows exact code,
        // so a partially seeded header cannot locate it safely.
        layout_value.seedHeader(result);
        for (layout_value.cpoolSliceMut(result)) |*slot| slot.* = JSValue.undefinedValue();
        // There is no binary-bytecode reader yet. Preserve QuickJS's ROM
        // bit position as a permanently-zero hole for every current producer.
        std.debug.assert(!bit(result.flag_byte18, byte18_rom_mask));
        return result;
    }

    /// Sole production main-allocation owner. It owns no atoms/values until
    /// the finalizer's no-fail commit, but its complete packed payload and
    /// canonical self-pointers already exist.
    pub fn createProductionShell(rt: *runtime.JSRuntime, layout_value: function_bytecode.FunctionLayout) !*FunctionBytecodeImpl {
        std.debug.assert(layout_value.has_debug and layout_value.has_extension);
        return createRaw(rt, layout_value);
    }

    pub fn destroyProductionShell(rt: *runtime.JSRuntime, fb: *FunctionBytecodeImpl, fam_bytes: usize) void {
        mem_ops.destroyWithFam(rt, FunctionBytecodeImpl, fb, fam_bytes);
    }

    pub const FixtureOptions = struct {
        name: atom.Atom = atom.ids.empty_string,
        realm: ?*context.RealmContext = null,
        flags: Flags = .{},
        arg_count: u16 = 0,
        var_count: u16 = 0,
        defined_arg_count: u16 = 0,
        stack_size: u16 = 0,
        var_ref_count: u16 = 0,
        closure_var_count: usize = 0,
        cpool_count: usize = 0,
        byte_code: []const u8 = &.{},
        has_debug: bool = false,
        /// Most fixtures need zjs-only mutable facts. Set false only when
        /// the fixture intentionally has no extension tail.
        has_extension: bool = true,
        filename: atom.Atom = atom.null_atom,
        script_or_module: atom.Atom = atom.null_atom,
        /// W1 property-site cache slots to allocate (fixture streams
        /// carry whatever `cache_idx` bytes the test wrote).
        prop_site_count: u16 = 0,
    };

    /// Fixture-only constructor. It uses the same packed FAM topology as
    /// production; tests may fill initialized table slots before GC
    /// publication and may explicitly omit debug and/or extension tails.
    pub fn createFixture(rt: *runtime.JSRuntime, options: FixtureOptions) !*FunctionBytecodeImpl {
        if (options.defined_arg_count > options.arg_count) return error.BytecodeOverflow;
        const has_extension = options.has_extension or options.script_or_module != atom.null_atom;
        const layout_value = try function_bytecode.FunctionLayout.init(
            options.has_debug,
            has_extension,
            options.cpool_count,
            options.arg_count,
            options.var_count,
            options.closure_var_count,
            options.byte_code.len,
            options.prop_site_count,
        );
        const fb = try createRaw(rt, layout_value);
        var raw_owned = true;
        errdefer if (raw_owned) mem_ops.destroyWithFam(rt, FunctionBytecodeImpl, fb, layout_value.famBytes());

        const byte_code = layout_value.byteCodeSliceMut(fb);
        @memcpy(byte_code, options.byte_code);

        fb.applyFlags(options.flags);
        fb.defined_arg_count = options.defined_arg_count;
        fb.stack_size = options.stack_size;
        fb.var_ref_count = options.var_ref_count;

        fb.func_name = rt.atoms.noteHolderStore(options.name);
        if (options.has_debug) {
            const dbg = fb.debugInfoMut().?;
            dbg.filename = rt.atoms.noteHolderStore(if (options.filename == atom.null_atom) options.name else options.filename);
        }
        if (options.script_or_module != atom.null_atom) {
            fb.hotExtensionRequiredMut().script_or_module = rt.atoms.noteHolderStore(options.script_or_module);
        }
        if (options.realm) |realm| fb.realm = context.RealmRef.retain(realm);

        raw_owned = false;
        return fb;
    }

    /// A fixture whose constant pool is known up front: create, fill and
    /// publish in one step.  `cpool.len` must equal `options.cpool_count`.
    pub fn createPublishedFixture(rt: *runtime.JSRuntime, options: FixtureOptions, cpool: []const JSValue) !*FunctionBytecodeImpl {
        std.debug.assert(cpool.len == options.cpool_count);
        const fb = try createFixture(rt, options);
        @memcpy(fb.cpoolSlice(), cpool);
        fb.publishFixtureNoFail(rt);
        return fb;
    }

    pub fn destroyUnpublishedFixture(self: *FunctionBytecodeImpl, rt: *runtime.JSRuntime) void {
        const layout_value = self.layout();
        self.deinitWithLayout(rt, layout_value);
        mem_ops.destroyWithFam(rt, FunctionBytecodeImpl, self, layout_value.famBytes());
    }

    /// Final no-fail phase of a fixture transaction. All fallible values,
    /// side boxes, and cycle edges must be prepared before this call.
    pub fn publishFixtureNoFail(self: *FunctionBytecodeImpl, rt: *runtime.JSRuntime) void {
        rt.gc.addInitializedWithSizeNoFail(&self.header, self.heapByteSize());
    }

    pub inline fn realmContext(self: *const FunctionBytecodeImpl) ?*context.RealmContext {
        // Production FBs publish the authoritative RealmRef directly in
        // the QJS core header; the borrowed inline-entry realm in the hot
        // pad is the slow fallback.
        if (self.realm.borrow()) |realm| return realm;
        return self.realmContextSlow();
    }

    noinline fn realmContextSlow(self: *const FunctionBytecodeImpl) ?*context.RealmContext {
        // Next-entry inline specs borrow the entry realm in the hot pad
        // (not RealmRef) so GC does not visit or retain it. See appendix B.
        if (self.hotExtension()) |hot| {
            const raw = std.mem.readInt(usize, hot._ctor_alloc_pad[@sizeOf(usize)..][0..@sizeOf(usize)], .little);
            if (raw != 0 and raw != 0xaaaaaaaaaaaaaaaa) {
                return @ptrFromInt(raw);
            }
        }
        return null;
    }

    /// True when the final-form opcode carries an atom operand (its atom is
    /// always the 4-byte field at `pc + 1`). Mirrors the pipeline's
    /// `hasAtomOperand` but lives here so the retention walk is self-contained.
    inline fn hasAtomOperandFmt(op_id: u8) bool {
        const fmt = opcode.formatOf(op_id);
        return fmt == .atom or fmt == .atom_u8 or fmt == .atom_cache_u8 or
            fmt == .atom_u16 or fmt == .atom_label_u8 or fmt == .atom_label_u16;
    }

    /// Iterator over the atom operands embedded in final-form bytecode.
    /// Replaces reads of the removed `atom_operands` array for runtime
    /// consumers (direct-eval scope scans). Yields each atom-operand
    /// opcode's inline 4-byte atom in bytecode order — the same sequence the
    /// former array held. Does not touch refcounts.
    pub const BytecodeAtomIterator = struct {
        byte_code: []const u8,
        pc: usize = 0,

        pub fn next(self: *BytecodeAtomIterator) ?atom.Atom {
            while (self.pc < self.byte_code.len) {
                const op_id = self.byte_code[self.pc];
                const size: usize = opcode.sizeOf(op_id);
                if (size == 0) return null; // unknown id: stop
                const has_atom = self.pc + size <= self.byte_code.len and hasAtomOperandFmt(op_id);
                const atom_id: ?atom.Atom = if (has_atom)
                    atom.Atom.fromRaw(std.mem.readInt(u32, self.byte_code[self.pc + 1 ..][0..4], .little))
                else
                    null;
                self.pc += size;
                if (atom_id) |a| return a;
            }
            return null;
        }
    };

    /// Convenience constructor for `BytecodeAtomIterator` over this FB.
    pub fn atomOperandIterator(self: *const FunctionBytecodeImpl) BytecodeAtomIterator {
        return .{ .byte_code = self.byteCode() };
    }

    pub fn deinit(self: *FunctionBytecodeImpl, rt: anytype) void {
        self.deinitWithLayout(rt, self.layout());
    }

    fn deinitWithLayout(
        self: *FunctionBytecodeImpl,
        rt: anytype,
        layout_value: function_bytecode.FunctionLayout,
    ) void {
        const mem = rt;
        // Capture the one checked layout and every inline view before
        // clearing an owner field. The hot extension follows code, so no
        // teardown step may try to rediscover it from cleared state.
        const hot_extension_ptr = layout_value.hotExtensionPtrMut(self);
        const debug_ptr = self.debugInfoMut();

        // Small-inline CallerState lives in the hot pad and is found via
        // the live code pointer. Tear it down before the code pointer is
        // cleared.
        if (rt.small_inline_destroy) |cb| cb(rt, @ptrCast(self));

        self.byte_code = null;
        self.byte_code_len = 0;
        // Inline atom operands, the compact vardef table and the closure
        // rows are plain values under the tracing GC: nothing is released
        // here, the whole FAM goes away with the cell.
        self.vardefs = null;

        // Match QuickJS's owner order: constant-pool child functions and
        // values are released before closure-name atoms and before Realm.
        self.cpool = null;
        self.cpool_count = 0;

        // closure_var sized by `closure_var_count`. The former separate
        // `var_ref_names` name array was a redundant mirror of
        // `closure_var[i].var_name` and was
        // removed; every reader now derives the var-ref name from
        // `closure_var[i].var_name` (see `Bytecode.varRefName`).
        self.closure_var = null;
        self.closure_var_count = 0;

        // Match QuickJS free_function_bytecode ordering: release child
        // constants before JS_FreeContext(b->realm). A nested FB may be
        // the reference that keeps this same realm alive during teardown.
        self.realm.deinit();

        self.func_name = atom.null_atom;

        // Source and pc2line remain exact independent allocations; every
        // table and code byte above lives in the main FAM.
        if (debug_ptr) |dbg| {
            dbg.filename = atom.null_atom;
            std.debug.assert(dbg.pc2line_len >= 0);
            const pc2line_len: usize = @intCast(dbg.pc2line_len);
            const pc2line_buf: []u8 = if (pc2line_len == 0)
                &.{}
            else
                (dbg.pc2line_buf.?)[0..pc2line_len];
            dbg.pc2line_buf = null;
            dbg.pc2line_len = 0;
            if (pc2line_buf.len != 0) mem_ops.free(mem, u8, pc2line_buf);
            if (dbg.source_ptr) |src_ptr| {
                std.debug.assert(dbg.source_len >= 0);
                const logical_len: usize = @intCast(dbg.source_len);
                const src = src_ptr[0 .. logical_len + 1];
                dbg.source_ptr = null;
                dbg.source_len = 0;
                mem_ops.free(mem, u8, @constCast(src));
            }
        }

        if (hot_extension_ptr) |hot| {
            hot.script_or_module = atom.null_atom;
        }

        // Pass B receives only the header pointer. Preserve the minimum
        // sizing state it needs to reconstruct this exact FAM length after
        // Pass A has released all owners and nulled their pointers.
        if (rt.gc.hot.phase == .deinit) {
            layout_value.restoreSizing(self);
        }
    }

    pub fn heapByteSize(self: *const FunctionBytecodeImpl) usize {
        return self.heapByteSizeWithLayout(self.layout());
    }

    pub fn heapByteSizeWithLayout(
        self: *const FunctionBytecodeImpl,
        layout_value: function_bytecode.FunctionLayout,
    ) usize {
        var bytes: usize = layout_value.mainPayloadBytes();
        if (self.debugInfo()) |dbg| {
            bytes = addSliceBytes(bytes, u8, @intCast(dbg.pc2line_len));
            if (dbg.source_ptr != null) bytes = addSaturating(bytes, @as(usize, @intCast(dbg.source_len)) + 1);
        }
        return bytes;
    }
};

/// Sole checked authority for the W1c5 main FunctionBytecode allocation.
/// Offsets are absolute from the 88-byte FB base (`FunctionBytecodeImpl`
/// asserts that size) and follow QuickJS's allocation order exactly:
/// optional debug, cpool, vardefs, closure rows, and exact code bytes.
/// Core segments have no inserted padding. The 64-byte hot extension
/// (`FunctionBytecodeHotExtension` asserts that size) starts at exact
/// code_end and is the complete canonical zjs tail.
pub const FunctionLayout = struct {
    has_debug: bool,
    has_extension: bool,
    cpool_count: usize,
    arg_count: usize,
    var_count: usize,
    closure_var_count: usize,
    byte_code_len: usize,
    /// W1 property-site cache slots (<= 255; requires `has_extension`).
    prop_site_count: usize,
    cpool_off: usize,
    vardefs_off: usize,
    closure_var_off: usize,
    byte_code_off: usize,
    byte_code_end: usize,
    hot_off: ?usize,
    /// Aligned start of the `PropSiteCache` array, or null when there are
    /// no slots. Sits behind the hot extension so every QuickJS core
    /// offset and the extension's exact-code_end placement are untouched.
    prop_sites_off: ?usize,
    total_size: usize,

    pub fn init(
        has_debug: bool,
        has_extension: bool,
        cpool_count: usize,
        arg_count: usize,
        var_count: usize,
        closure_var_count: usize,
        byte_code_len: usize,
        prop_site_count: usize,
    ) error{BytecodeOverflow}!@This() {
        if (arg_count > std.math.maxInt(u16) or var_count > std.math.maxInt(u16) or
            cpool_count > std.math.maxInt(i32) or closure_var_count > std.math.maxInt(i32) or
            byte_code_len > std.math.maxInt(i32) or
            prop_site_count > function_bytecode.PropSiteCache.no_cache_idx or
            (prop_site_count != 0 and !has_extension))
        {
            return error.BytecodeOverflow;
        }
        const vardef_count = std.math.add(usize, arg_count, var_count) catch return error.BytecodeOverflow;
        const debug_bytes: usize = if (has_debug) @sizeOf(DebugInfo) else 0;
        const cpool_off = std.math.add(usize, @sizeOf(FunctionBytecodeImpl), debug_bytes) catch return error.BytecodeOverflow;
        const cpool_bytes = std.math.mul(usize, cpool_count, @sizeOf(JSValue)) catch return error.BytecodeOverflow;
        const vardefs_off = std.math.add(usize, cpool_off, cpool_bytes) catch return error.BytecodeOverflow;
        const vardef_bytes = std.math.mul(usize, vardef_count, @sizeOf(BytecodeVarDef)) catch return error.BytecodeOverflow;
        const closure_var_off = std.math.add(usize, vardefs_off, vardef_bytes) catch return error.BytecodeOverflow;
        const closure_bytes = std.math.mul(usize, closure_var_count, @sizeOf(BytecodeClosureVar)) catch return error.BytecodeOverflow;
        const byte_code_off = std.math.add(usize, closure_var_off, closure_bytes) catch return error.BytecodeOverflow;
        const byte_code_end = std.math.add(usize, byte_code_off, byte_code_len) catch return error.BytecodeOverflow;
        const hot_off: ?usize = if (has_extension) byte_code_end else null;
        const hot_end = if (hot_off) |offset|
            std.math.add(usize, offset, @sizeOf(FunctionBytecodeHotExtension)) catch return error.BytecodeOverflow
        else
            byte_code_end;
        const prop_sites_off: ?usize = if (prop_site_count != 0)
            std.mem.alignForward(usize, hot_end, @alignOf(function_bytecode.PropSiteCache))
        else
            null;
        const total_size = if (prop_sites_off) |offset|
            std.math.add(usize, offset, prop_site_count * @sizeOf(function_bytecode.PropSiteCache)) catch return error.BytecodeOverflow
        else
            hot_end;

        // The pinned QuickJS order is naturally aligned for both supported
        // JSValue representations; padding there would be a layout bug.
        std.debug.assert(cpool_off % @alignOf(JSValue) == 0);
        std.debug.assert(vardefs_off % @alignOf(BytecodeVarDef) == 0);
        std.debug.assert(closure_var_off % @alignOf(BytecodeClosureVar) == 0);
        if (hot_off) |offset| std.debug.assert(offset == byte_code_end);

        return .{
            .has_debug = has_debug,
            .has_extension = has_extension,
            .cpool_count = cpool_count,
            .arg_count = arg_count,
            .var_count = var_count,
            .closure_var_count = closure_var_count,
            .byte_code_len = byte_code_len,
            .prop_site_count = prop_site_count,
            .cpool_off = cpool_off,
            .vardefs_off = vardefs_off,
            .closure_var_off = closure_var_off,
            .byte_code_off = byte_code_off,
            .byte_code_end = byte_code_end,
            .hot_off = hot_off,
            .prop_sites_off = prop_sites_off,
            .total_size = total_size,
        };
    }

    pub fn fromFunction(fb: *const FunctionBytecodeImpl) error{ InvalidBytecode, BytecodeOverflow }!@This() {
        if (fb.cpool_count < 0 or fb.closure_var_count < 0 or fb.byte_code_len < 0) return error.InvalidBytecode;
        // The slot count lives in the extension, which sits at exact
        // code_end -- locatable from the header fields alone, before
        // the tail behind it is known. Read it through the slot-free
        // layout rather than `hotExtension()`: the empty-code arm of
        // that accessor comes back through `layout()`.
        const base = try init(
            fb.hasDebug(),
            fb.hasExtension(),
            @intCast(fb.cpool_count),
            fb.arg_count,
            fb.var_count,
            @intCast(fb.closure_var_count),
            @intCast(fb.byte_code_len),
            0,
        );
        const hot_off = base.hot_off orelse return base;
        const bytes: [*]const u8 = @ptrCast(fb);
        const hot: *align(1) const FunctionBytecodeHotExtension = @ptrCast(bytes + hot_off);
        if (hot.prop_site_count == 0) return base;
        return init(
            base.has_debug,
            base.has_extension,
            base.cpool_count,
            base.arg_count,
            base.var_count,
            base.closure_var_count,
            base.byte_code_len,
            hot.prop_site_count,
        );
    }

    pub inline fn famBytes(self: @This()) usize {
        return self.total_size - @sizeOf(FunctionBytecodeImpl);
    }

    pub inline fn mainPayloadBytes(self: @This()) usize {
        return self.total_size;
    }

    pub fn cpoolSliceMut(self: @This(), fb: *FunctionBytecodeImpl) []JSValue {
        return packedSlice(fb, JSValue, self.cpool_off, self.cpool_count, self.total_size);
    }

    pub fn vardefsSliceMut(self: @This(), fb: *FunctionBytecodeImpl) []BytecodeVarDef {
        return packedSlice(fb, BytecodeVarDef, self.vardefs_off, self.arg_count + self.var_count, self.total_size);
    }

    pub fn closureVarSliceMut(self: @This(), fb: *FunctionBytecodeImpl) []BytecodeClosureVar {
        return packedSlice(fb, BytecodeClosureVar, self.closure_var_off, self.closure_var_count, self.total_size);
    }

    pub fn byteCodeSliceMut(self: @This(), fb: *FunctionBytecodeImpl) []u8 {
        return packedSlice(fb, u8, self.byte_code_off, self.byte_code_len, self.total_size);
    }

    pub fn propSitesSliceMut(self: @This(), fb: *FunctionBytecodeImpl) []function_bytecode.PropSiteCache {
        const offset = self.prop_sites_off orelse return &.{};
        return packedSlice(fb, function_bytecode.PropSiteCache, offset, self.prop_site_count, self.total_size);
    }

    pub fn hotExtensionPtrMut(self: @This(), fb: *FunctionBytecodeImpl) ?*align(1) FunctionBytecodeHotExtension {
        const offset = self.hot_off orelse return null;
        const bytes: [*]u8 = @ptrCast(fb);
        return @ptrCast(bytes + offset);
    }

    fn seedHeader(self: @This(), fb: *FunctionBytecodeImpl) void {
        fb.arg_count = @intCast(self.arg_count);
        fb.var_count = @intCast(self.var_count);
        fb.cpool_count = @intCast(self.cpool_count);
        fb.closure_var_count = @intCast(self.closure_var_count);
        fb.byte_code_len = @intCast(self.byte_code_len);
        const cpool = self.cpoolSliceMut(fb);
        const vardefs = self.vardefsSliceMut(fb);
        const closure_var = self.closureVarSliceMut(fb);
        const byte_code = self.byteCodeSliceMut(fb);
        fb.cpool = if (cpool.len == 0) null else cpool.ptr;
        fb.vardefs = if (vardefs.len == 0) null else vardefs.ptr;
        fb.closure_var = if (closure_var.len == 0) null else closure_var.ptr;
        fb.byte_code = if (byte_code.len == 0) null else byte_code.ptr;
        if (self.hotExtensionPtrMut(fb)) |hot| {
            const prop_sites = self.propSitesSliceMut(fb);
            hot.prop_site_count = @intCast(self.prop_site_count);
            hot.prop_sites = if (prop_sites.len == 0) null else prop_sites.ptr;
        }
    }

    fn restoreSizing(self: @This(), fb: *FunctionBytecodeImpl) void {
        fb.arg_count = @intCast(self.arg_count);
        fb.var_count = @intCast(self.var_count);
        fb.cpool_count = @intCast(self.cpool_count);
        fb.closure_var_count = @intCast(self.closure_var_count);
        fb.byte_code_len = @intCast(self.byte_code_len);
    }
};

fn packedSlice(
    fb: *FunctionBytecodeImpl,
    comptime T: type,
    offset: usize,
    len: usize,
    total_size: usize,
) []T {
    if (len == 0) return &.{};
    const byte_len = len * @sizeOf(T);
    std.debug.assert(offset + byte_len <= total_size);
    const bytes: [*]u8 = @ptrCast(fb);
    const ptr: [*]T = @ptrCast(@alignCast(bytes + offset));
    return ptr[0..len];
}

fn addSliceBytes(total: usize, comptime T: type, len: usize) usize {
    const slice_bytes = std.math.mul(usize, @sizeOf(T), len) catch std.math.maxInt(usize);
    return addSaturating(total, slice_bytes);
}

fn addSaturating(a: usize, b: usize) usize {
    return std.math.add(usize, a, b) catch std.math.maxInt(usize);
}

pub fn destroyFromHeader(rt: anytype, header: *gc.Header) void {
    const self: *FunctionBytecodeImpl = @alignCast(@fieldParentPtr("header", header));
    const layout_value = self.layout();
    self.deinitWithLayout(rt, layout_value);
    // TGC S4-e spec 2.5: no Pass-B deferral. Runtime teardown already
    // holds every FunctionBytecode back until all object resource passes
    // have run (`Registry.deinit` phase 2), which is the ordering the
    // park used to express here.
    mem_ops.destroyWithFam(rt, FunctionBytecodeImpl, self, layout_value.famBytes());
}
pub const FunctionBytecode = FunctionBytecodeImpl;
