//! Unified parse entry for compiler tests.

const std = @import("std");
const bytecode = @import("../bytecode.zig");
const core = @import("../core/root.zig");
const parser = @import("../parser.zig");

const Parser = parser.Parser;

pub const RootKind = enum { script, module };

pub const Options = struct {
    root: RootKind = .script,
};

pub const Program = struct {
    name_atom: core.atom.Atom,
    lexer: parser.Lexer,
    state: Parser.ParseState,

    /// The parser-phase instruction stream to assert on: the compact
    /// temporary stream the Builder holds before lowering.
    pub fn phase1Code(p: *const Program) []const u8 {
        return p.state.function_def.builder.?.code[0..p.state.function_def.builder.?.code_len];
    }

    pub fn deinit(p: *Program, rt: *core.JSRuntime) void {
        // Program is returned by value, so repair the lexer pointer that
        // named its construction-time result location before releasing.
        p.state.lex = &p.lexer;
        p.state.deinit(rt);
        p.lexer.deinit();
    }
};

pub fn configureScriptRoot(state: *Parser.ParseState) void {
    state.function_def.is_eval = true;
    state.function_def.is_global_var = true;
    state.top_level_lexical_as_global_ref = true;
}

pub fn configureModuleRoot(state: *Parser.ParseState) void {
    state.function_def.is_eval = true;
    state.function_def.is_module = true;
    state.function_def.is_global_var = true;
    state.function_def.is_strict_mode = true;
    state.is_strict = true;
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

    var lexer = parser.Lexer.init(testing_allocator, &rt.atoms, source);
    errdefer lexer.deinit();

    var state = try Parser.ParseState.initFromRuntime(&lexer, rt, &rt.atoms, name_atom);
    errdefer state.deinit(rt);
    state.runtime = rt;
    switch (options.root) {
        .script => configureScriptRoot(&state),
        .module => configureModuleRoot(&state),
    }

    try state.beginProgramEmission();
    try Parser.parseProgramStatements(
        &state,
        .{ .func = true, .func_with_label = true, .other = true },
    );

    return .{
        .name_atom = name_atom,
        .lexer = lexer,
        .state = state,
    };
}
