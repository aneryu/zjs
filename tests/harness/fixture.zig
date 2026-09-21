//! Hand-written bytecode fixtures and parse-then-run helpers.

const std = @import("std");
const zjs = @import("zjs");
const core = zjs.core;
const bytecode = zjs.bytecode;
const exec = zjs.exec;
const parser = zjs.parser;
const test_engine = @import("test_engine.zig");

const QjsLexer = parser.Lexer;
const parser_core = parser.Parser;
const ParseState = parser_core.ParseState;
const op = bytecode.opcode.op;

/// A published, rooted `FunctionBytecode` built from raw final-form bytecode:
/// the fixture shape for tests that execute hand-written instruction
/// streams. `release` drops the root; the collector reclaims the artifact.
pub const Fixture = struct {
    fb: *bytecode.FunctionBytecode,
    value: core.JSValue,
    scope: core.runtime.ValueRootScope(1),

    pub fn release(self: *Fixture, rt: *core.JSRuntime) void {
        self.scope.deactivate(rt);
        rt.memory.destroy(Fixture, self);
    }
};

pub const FixtureSpec = struct {
    name: []const u8 = "exec",
    code: []const u8,
    /// Constant-pool values addressed by `push_const`.
    cpool: []const core.JSValue = &.{},
    /// Ordinary global names addressed by `get_var` / `put_var`, in index
    /// order: each becomes a `.global` closure row exactly as a compiled
    /// script root carries them.
    globals: []const core.Atom = &.{},
    arg_count: u16 = 0,
    var_count: u16 = 0,
    var_ref_count: u16 = 0,
    flags: bytecode.FunctionBytecode.Flags = .{},
    /// Computed by the stack-size pass when null; give an explicit value to
    /// bypass that proof for a deliberately malformed stream.
    stack_size: ?u16 = null,
};

pub fn makeFixture(rt: *core.JSRuntime, realm: ?*core.JSContext, spec: FixtureSpec) !*Fixture {
    const stack_size = spec.stack_size orelse
        try bytecode.pipeline.stack_size.compute(spec.code, .{});
    const fb = try bytecode.FunctionBytecode.createFixture(rt, .{
        .name = try rt.internAtom(spec.name),
        .realm = realm,
        .flags = spec.flags,
        .arg_count = spec.arg_count,
        .var_count = spec.var_count,
        .var_ref_count = spec.var_ref_count,
        .closure_var_count = spec.globals.len,
        .cpool_count = spec.cpool.len,
        .stack_size = stack_size,
        .byte_code = spec.code,
    });
    errdefer fb.destroyUnpublishedFixture(rt);
    @memcpy(fb.cpoolSlice(), spec.cpool);
    for (fb.closureVar(), spec.globals) |*cv, name| {
        cv.* = bytecode.function_bytecode.BytecodeClosureVar.init(.{
            .closure_type = .global,
            .var_idx = 0,
            .var_name = name,
        });
    }
    const item = try rt.memory.create(Fixture);
    item.* = .{
        .fb = fb,
        .value = core.JSValue.functionBytecode(&fb.header),
        .scope = .{},
    };
    fb.publishFixtureNoFail(rt);
    item.scope = core.runtime.rootValues(.{&item.value});
    item.scope.activate(rt);
    return item;
}

/// Run a fixture as a script root on a fresh VM with the bare host globals.
pub fn runFixture(rt: *core.JSRuntime, ctx: *core.JSContext, fb: *const bytecode.FunctionBytecode) !core.JSValue {
    test_engine.registerStandardGlobalsBare(rt);
    var vm_instance = exec.Vm.init(ctx);
    defer vm_instance.deinit();
    return vm_instance.run(fb);
}

/// Publishes a hand-assembled bytecode function fixture on the runtime and
/// returns a rooted function object for it. Shared by the exec suite's raw
/// tail-call opcode test.
pub fn createTailOpcodeFixture(
    js: *test_engine.TestEngine,
    name_bytes: []const u8,
    code: []const u8,
    stack_size: u16,
) !core.JSValue {
    const name = try js.runtime.internAtom(name_bytes);
    const fb = try bytecode.FunctionBytecode.createFixture(js.runtime, .{
        .name = name,
        .realm = js.context,
        .flags = .{
            .has_simple_parameter_list = true,
            .func_kind = .normal,
        },
        .stack_size = stack_size,
        .byte_code = code,
    });
    fb.publishFixtureNoFail(js.runtime);
    const global = try exec.zjs_vm.contextGlobal(js.context);
    return exec.object_ops.createRootBytecodeFunctionObject(
        js.context,
        global,
        core.JSValue.functionBytecode(&fb.header),
        .root_global,
    );
}

pub const vm_helpers = struct {
    pub fn parseAndRunWithTopLevelChildren(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue {
        const name = try rt.internAtom("test");
        var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
        var state = try ParseState.initWithRuntime(rt, &lex, name);
        defer state.deinit(rt);
        try parser_core.parseExpr(&state);
        try parser_core.Emitter.op(&state, op.@"return");

        return runLoweredRoot(rt, ctx, &state.function_def);
    }

    /// Finalize the parsed root into its canonical FunctionBytecode and run
    /// it as a script root. The artifact is GC-owned; it is rooted for the
    /// duration of the run.
    fn runLoweredRoot(rt: *core.JSRuntime, ctx: *core.JSContext, fd: *bytecode.FunctionDef) !core.JSValue {
        const artifacts = try bytecode.pipeline.finalize.createFunctionBytecode(fd, .{ .realm = ctx });
        var root_value = core.JSValue.functionBytecode(&artifacts[0].header);
        var roots = core.runtime.rootValues(.{&root_value});
        roots.activate(rt);
        defer roots.deactivate(rt);
        return runFixture(rt, ctx, &artifacts[0]);
    }

    pub fn parseStmtAndRunWithTopLevelChildren(rt: *core.JSRuntime, ctx: *core.JSContext, src: []const u8) !core.JSValue {
        const name = try rt.internAtom("test");
        var lex = QjsLexer.init(std.testing.allocator, &rt.atoms, src);
        var state = try ParseState.initWithRuntime(rt, &lex, name);
        defer state.deinit(rt);
        state.top_level_lexical_as_global_ref = true;
        state.function_def.is_eval = true;
        state.function_def.is_global_var = true;

        // This helper executes global script code and only needs completion
        // capture; enableEvalReturn would incorrectly switch declarations to
        // direct-eval placement. Mirror compileQjsProgram's script setup.
        try state.beginProgramEmission();
        try state.enableReturnCompletion();
        while (state.token.val != .eof) {
            try parser_core.parseStatementOrDecl(&state, parser_core.DeclMask{ .func = true, .func_with_label = true, .other = true });
        }
        try state.finalizeEvalReturn();

        return runLoweredRoot(rt, ctx, &state.function_def);
    }
};
