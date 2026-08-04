//! Unified parse entry for compiler-migration-relevant tests.

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const parser = @import("../parser.zig");
const coverage = @import("coverage.zig");

const Parser = parser.Parser;

pub const SourceKind = enum { javascript, typescript };
pub const RootKind = enum { script, module };

pub const Options = struct {
    source_kind: SourceKind = .javascript,
    root: RootKind = .script,
    /// Phase-1 temp scope markers. The parser scope-event tests need them on.
    emit_phase1_temp: bool = true,
};

pub const Backend = enum { legacy, v2 };

pub const Observation = struct {
    fallbacks: std.EnumSet(coverage.LegacyConstruct),
    unallowed: u64,
};

pub const ObservationStart = struct {
    counters: coverage.Counters,
};

pub const Program = struct {
    function: bytecode.Bytecode,
    backend: Backend,
    /// Constructs that emitted through a LEGACY funnel during this parse while
    /// `emit_v2` was true. Empty on a legacy build.
    fallbacks: std.EnumSet(coverage.LegacyConstruct),
    /// True when `fallbacks` is non-empty: the program's instructions are split
    /// across the v2 temporary stream and the legacy stream, so neither stream
    /// alone describes the whole program.
    split_stream: bool,
    /// In-v2-scope legacy emissions whose construct is NOT allowlisted.
    unallowed_emissions: u64,

    name_atom: core.atom.Atom,
    lexer: parser.Lexer,
    state: Parser.ParseState,

    /// The phase-1 instruction stream to assert on: the compiler_v2 temporary
    /// stream on a v2 build, `function.code` / the FunctionDef byte code on a
    /// legacy build.
    pub fn phase1Code(p: *const Program) []const u8 {
        return switch (p.backend) {
            .legacy => if (p.state.emit_to_function_def)
                p.state.function_def.byte_code
            else
                p.function.code,
            .v2 => p.state.function_def.v2_builder.?.code[0..p.state.function_def.v2_builder.?.code_len],
        };
    }

    pub fn observation(p: *const Program) Observation {
        return .{
            .fallbacks = p.fallbacks,
            .unallowed = p.unallowed_emissions,
        };
    }

    pub fn deinit(p: *Program, rt: *core.JSRuntime) void {
        // Program is returned by value, so repair the two pointers that named
        // its construction-time result location before releasing the owners.
        p.state.lex = &p.lexer;
        p.state.function = &p.function;
        p.state.deinit(rt);
        p.lexer.deinit();
        p.function.deinit(rt);
        rt.atoms.free(p.name_atom);
    }
};

pub fn beginObservation() ObservationStart {
    return .{ .counters = coverage.snapshot() };
}

pub fn endObservation(start: ObservationStart) Observation {
    if (comptime !coverage.enabled) {
        return .{ .fallbacks = .empty, .unallowed = 0 };
    }

    const finish = coverage.snapshot();
    var fallbacks: std.EnumSet(coverage.LegacyConstruct) = .empty;
    inline for (@typeInfo(coverage.LegacyConstruct).@"enum".fields) |field| {
        const construct: coverage.LegacyConstruct = @enumFromInt(field.value);
        const index = @intFromEnum(construct);
        if (finish.per_construct[index] > start.counters.per_construct[index]) {
            fallbacks.insert(construct);
        }
    }
    return .{
        .fallbacks = fallbacks,
        .unallowed = finish.legacy_in_v2_unallowed - start.counters.legacy_in_v2_unallowed,
    };
}

/// Test-surface gate: fails loudly when the observation contains any legacy
/// emission that is not on `coverage.legacy_allowlist`.
pub fn expectNoUnallowedFallback(obs: Observation) error{InvalidBytecode}!void {
    var offending: ?coverage.LegacyConstruct = null;
    inline for (@typeInfo(coverage.LegacyConstruct).@"enum".fields) |field| {
        const construct: coverage.LegacyConstruct = @enumFromInt(field.value);
        if (obs.fallbacks.contains(construct) and !coverage.isAllowlisted(construct)) {
            offending = construct;
        }
    }
    if (obs.unallowed == 0 and offending == null) return;

    std.debug.print(
        "compiler-v2 test entry observed {d} un-allowlisted legacy emissions (construct={s})\n",
        .{ obs.unallowed, if (offending) |construct| @tagName(construct) else "unknown" },
    );
    return error.InvalidBytecode;
}

pub fn configureScriptRoot(state: *Parser.ParseState) void {
    state.function_def.is_eval = true;
    state.function_def.is_global_var = true;
    state.top_level_functions_as_children = true;
    state.top_level_lexical_as_global_ref = true;
}

pub fn configureModuleRoot(state: *Parser.ParseState) void {
    state.function_def.is_eval = true;
    state.function_def.is_module = true;
    state.function_def.is_global_var = true;
    state.function_def.is_strict_mode = true;
    state.is_strict = true;
    state.top_level_functions_as_children = true;
    state.top_level_lexical_as_module_ref = true;
}

pub fn parseAndCompileV2TestProgram(
    rt: *core.JSRuntime,
    testing_allocator: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
    options: Options,
) !Program {
    const name_atom = try rt.atoms.internString(name);
    errdefer rt.atoms.free(name_atom);

    var function = bytecode.Bytecode.init(&rt.memory, &rt.atoms, name_atom);
    errdefer function.deinit(rt);

    var lexer = parser.Lexer.init(testing_allocator, &rt.atoms, source);
    errdefer lexer.deinit();
    if (options.source_kind == .typescript) try lexer.enableTypeScript();

    var state = try Parser.ParseState.init(&lexer, &function);
    errdefer state.deinit(rt);
    state.runtime = rt;
    switch (options.root) {
        .script => configureScriptRoot(&state),
        .module => configureModuleRoot(&state),
    }
    state.emit_phase1_temp = options.emit_phase1_temp;

    const observation_start = beginObservation();
    if (Parser.v2_available) try state.beginV2ProgramEmission();
    try Parser.parseProgramStatements(
        &state,
        .{ .func = true, .func_with_label = true, .other = true },
    );
    const observation = endObservation(observation_start);
    const backend: Backend = if (Parser.v2_available) .v2 else .legacy;

    return .{
        .function = function,
        .backend = backend,
        .fallbacks = observation.fallbacks,
        .split_stream = backend == .v2 and observation.fallbacks.count() != 0,
        .unallowed_emissions = observation.unallowed,
        .name_atom = name_atom,
        .lexer = lexer,
        .state = state,
    };
}
