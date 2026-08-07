//! Unified parse entry for compiler tests.

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const parser = @import("../parser.zig");

const Parser = parser.Parser;

pub const SourceKind = enum { javascript, typescript };
pub const RootKind = enum { script, module };

pub const Options = struct {
    source_kind: SourceKind = .javascript,
    root: RootKind = .script,
    /// Phase-1 temp scope markers. The parser scope-event tests need them on.
    emit_phase1_temp: bool = true,
};

pub const Program = struct {
    function: bytecode.Bytecode,

    name_atom: core.atom.Atom,
    lexer: parser.Lexer,
    state: Parser.ParseState,

    /// The parser-phase instruction stream to assert on: the compact
    /// temporary stream the Builder holds before lowering.
    pub fn phase1Code(p: *const Program) []const u8 {
        return p.state.function_def.v2_builder.?.code[0..p.state.function_def.v2_builder.?.code_len];
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

    try state.beginV2ProgramEmission();
    try Parser.parseProgramStatements(
        &state,
        .{ .func = true, .func_with_label = true, .other = true },
    );

    return .{
        .function = function,
        .name_atom = name_atom,
        .lexer = lexer,
        .state = state,
    };
}
