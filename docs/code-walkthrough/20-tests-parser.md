# 20 — 词法 / 语法 / 发射 / opcode 序列

`src/tests/parser.zig` 用 `ParserTestEnv` 在**裸 realm** 里 `parser.compile`，避免标准库物化。表达式/语句助手经 `pipeline.finalize` 降到最终 opcode 再比字节序列。 源文件 `src/tests/parser.zig`（13909 行）。

## `src/tests/parser.zig`

`src/tests/parser.zig` 用 `ParserTestEnv` 在**裸 realm** 里 `parser.compile`，避免标准库物化。表达式/语句助手经 `pipeline.finalize` 降到最终 opcode 再比字节序列。

文件头：Exercises lexer/parser semantics and emitted bytecode invariants.

类型：`LexerTestEnv`（只持 Runtime，给词法单测）；`ParserTestEnv`/`TestEnv`（Runtime + 裸 `RealmContext`，finalize 走生产 RealmRef 但不物化标准全局）。大量 `parse*` / `count*` / `expectOpcode*` 助手把源文编到最终 opcode 再比字节。文件后部只有两个 `pub` 声明：`atomLiveEntryTotal`（数 atom 表的 OCCUPIED 条目，供本文件的 atom 平衡测试）和 `phase_ownership`（相位边界普查结构与 B1/B3/B4 断言，被 `src/tests/bytecode.zig` 的「four-ledger phase-boundary ownership」测试复用）。

### 函数（清单 134）

### `LexerTestEnv.init` (`src/tests/parser.zig:57`)

- **签名**：`fn init() !LexerTestEnv`。
- **作用**：测试夹具/探针 `LexerTestEnv.init`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。直接构造 `JSRuntime`（绕过共享引擎）。关键调用：`engine.core.runtime.JSRuntime.create`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。返回 `!LexerTestEnv`，由测试 `try`/`expectError` 消费。

### `LexerTestEnv.deinit` (`src/tests/parser.zig:60`)

- **签名**：`fn deinit(self: *LexerTestEnv) void`。
- **作用**：测试夹具/探针 `LexerTestEnv.deinit`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：关键调用：`self.rt.destroy`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `LexerTestEnv.lexer` (`src/tests/parser.zig:63`)

- **签名**：`fn lexer(self: *LexerTestEnv, src: []const u8) QjsLexer`。
- **作用**：测试夹具/探针 `LexerTestEnv.lexer`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：关键调用：`QjsLexer.init`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。无独立 error set 时失败以断言或 panic 终止测试。

### `freeToken` (`src/tests/parser.zig:70`)

- **签名**：`fn freeToken(lx: *QjsLexer, tok: *t.Token) void`。
- **作用**：测试夹具/探针 `freeToken`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：函数体只有 `lx.freeToken(tok)` 一行，把 token 持有的 atom/字符串所有权交还词法器。原名 `freeAndDrain` 里的 "drain" 没有对应动作，已随全部 43 个调用点一起改名。关键调用：`lx.freeToken`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `ParserTestEnv.init` (`src/tests/parser.zig:819`)

- **签名**：`fn init() !TestEnv`。
- **作用**：测试夹具/探针 `ParserTestEnv.init`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。直接构造 `JSRuntime`（绕过共享引擎）。关键调用：`engine.core.runtime.JSRuntime.create`、`rt.destroy`、`core.RealmContext.create`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。失败路径靠 `errdefer` 对称释放。返回 `!TestEnv`，由测试 `try`/`expectError` 消费。

### `ParserTestEnv.deinit` (`src/tests/parser.zig:827`)

- **签名**：`fn deinit(self: *TestEnv) void`。
- **作用**：测试夹具/探针 `ParserTestEnv.deinit`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：关键调用：`self.realm.destroy`、`self.rt.destroy`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `ParserTestEnv.compileContext` (`src/tests/parser.zig:832`)

- **签名**：`fn compileContext(self: *const TestEnv) parser.CompileContext`。
- **作用**：测试夹具/探针 `ParserTestEnv.compileContext`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`return .{ .realm = self.realm }`——把裸 realm 包成 `parser.CompileContext`，供 `parser.compile` / `pipeline.finalize.runWithFunctionDefRuntime` 使用。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `compileForTest` (`src/tests/parser.zig:840`)

- **签名**：`fn compileForTest(rt: *core.JSRuntime, source: []const u8, options: parser.Options) !parser.Result`。
- **作用**：Parser-only tests deliberately compile in a fresh bare realm so every finalized FB exercises the production RealmRef owner without paying for or depending on standard-global materialization.。
- **实现**：Parser-only tests deliberately compile in a fresh bare realm so every finalized FB exercises the production RealmRef owner without paying for or depending on standard-global materialization.。热路径用 `try` 传播分配/引擎错误。`defer` 释放本次成功路径上的临时资源。关键调用：`core.RealmContext.create`、`realm.destroy`、`parser.compile`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。返回 `!parser.Result`，由测试 `try`/`expectError` 消费。

### `restoreFinalizedFragmentView` (`src/tests/parser.zig:851`)

- **签名**：`fn restoreFinalizedFragmentView(function: *engine.bytecode.Bytecode) !void`。
- **作用**：The helpers below exercise parser/lowering fragments rather than runnable function bodies. Give finalize a real terminator so it can enforce the production CFG invariant, then restore the fragment-only view that these byte-sequence tests are designed to inspect. These returned fixtures are never dispatched by the VM.。
- **实现**：先看 `function.code` 是否以 `op.return_undef` 结尾（空码或已是 `return`/`throw` 等 abrupt 结尾时直接返回，不做修复），是则把 `function.code` 切掉最后一个字节，恢复「片段视图」。不释放任何内存，只改切片长度。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `parseExpr` (`src/tests/parser.zig:865`)

- **签名**：`fn parseExpr(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode`。
- **作用**：Helper: parse `src` as an expression, run the F10 pipeline, and return the produced final-form bytecode for byte-sequence comparison. The parser's default is `emit_phase1_temp = true`, so raw parser output contains scope_get_var/scope_put_var and other Phase 1 temp opcodes; `pipeline.finalize.runWithFunctionDefRuntime` lowers them to the final shapes the tests assert against (including get_loc/put_loc for vars in `function_def.vars`).。
- **实现**：intern 名字 `"test"` → `Bytecode.init` → `QjsLexer.init` → `ParseState.init` → `parser_core.parseExpr(&state)` → `state.emitReturnUndefined()` → `pipeline.finalize.runWithFunctionDefRuntime(&function, &state.function_def, env.compileContext())` → `restoreFinalizedFragmentView`。热路径用 `try` 传播分配/引擎错误；`errdefer function.deinit(env.rt)` 回滚失败路径；`defer state.deinit(env.rt)` 释放解析态。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。失败路径靠 `errdefer` 对称释放。返回 `!engine.bytecode.Bytecode`，由测试 `try`/`expectError` 消费。

### `parseExprWithTopLevelChildren` (`src/tests/parser.zig:879`)

- **签名**：`fn parseExprWithTopLevelChildren(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode`。
- **作用**：测试夹具/探针 `parseExprWithTopLevelChildren`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。`defer` 释放本次成功路径上的临时资源。关键调用：`env.rt.internAtom`、`engine.bytecode.Bytecode.init`、`function.deinit`、`QjsLexer.init`、`ParseState.init`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。失败路径靠 `errdefer` 对称释放。返回 `!engine.bytecode.Bytecode`，由测试 `try`/`expectError` 消费。

### `parseExprStrict` (`src/tests/parser.zig:895`)

- **签名**：`fn parseExprStrict(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode`。
- **作用**：测试夹具/探针 `parseExprStrict`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。`defer` 释放本次成功路径上的临时资源。关键调用：`env.rt.internAtom`、`engine.bytecode.Bytecode.init`、`function.deinit`、`QjsLexer.init`、`ParseState.init`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。失败路径靠 `errdefer` 对称释放。返回 `!engine.bytecode.Bytecode`，由测试 `try`/`expectError` 消费。

### `parseStatement` (`src/tests/parser.zig:915`)

- **签名**：`fn parseStatement(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode`。
- **作用**：Helper: parse `src` as a statement, run the F10 pipeline, and return the produced final-form bytecode for byte-sequence comparison.。
- **实现**：Helper: parse `@src` as a statement, run the F10 pipeline, and return the produced final-form bytecode for byte-sequence comparison.。热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。`defer` 释放本次成功路径上的临时资源。关键调用：`env.rt.internAtom`、`engine.bytecode.Bytecode.init`、`function.deinit`、`QjsLexer.init`、`ParseState.init`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。失败路径靠 `errdefer` 对称释放。返回 `!engine.bytecode.Bytecode`，由测试 `try`/`expectError` 消费。

### `parseTSStatement` (`src/tests/parser.zig:930`)

- **签名**：`fn parseTSStatement(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode`。
- **作用**：测试夹具/探针 `parseTSStatement`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。`defer` 释放本次成功路径上的临时资源。关键调用：`env.rt.internAtom`、`engine.bytecode.Bytecode.init`、`function.deinit`、`QjsLexer.init`、`lex.deinit`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。失败路径靠 `errdefer` 对称释放。返回 `!engine.bytecode.Bytecode`，由测试 `try`/`expectError` 消费。

### `parseTSProgram` (`src/tests/parser.zig:947`)

- **签名**：`fn parseTSProgram(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode`。
- **作用**：测试夹具/探针 `parseTSProgram`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。`defer` 释放本次成功路径上的临时资源。关键调用：`env.rt.internAtom`、`engine.bytecode.Bytecode.init`、`function.deinit`、`QjsLexer.init`、`lex.deinit`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。失败路径靠 `errdefer` 对称释放。返回 `!engine.bytecode.Bytecode`，由测试 `try`/`expectError` 消费。

### `parseStatementWithTopLevelChildren` (`src/tests/parser.zig:967`)

- **签名**：`fn parseStatementWithTopLevelChildren(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode`。
- **作用**：测试夹具/探针 `parseStatementWithTopLevelChildren`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。`defer` 释放本次成功路径上的临时资源。关键调用：`env.rt.internAtom`、`engine.bytecode.Bytecode.init`、`function.deinit`、`QjsLexer.init`、`ParseState.init`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。失败路径靠 `errdefer` 对称释放。返回 `!engine.bytecode.Bytecode`，由测试 `try`/`expectError` 消费。

### `parseModuleStatement` (`src/tests/parser.zig:983`)

- **签名**：`fn parseModuleStatement(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode`。
- **作用**：测试夹具/探针 `parseModuleStatement`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。`defer` 释放本次成功路径上的临时资源。关键调用：`env.rt.internAtom`、`engine.bytecode.Bytecode.init`、`function.deinit`、`QjsLexer.init`、`ParseState.init`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。失败路径靠 `errdefer` 对称释放。返回 `!engine.bytecode.Bytecode`，由测试 `try`/`expectError` 消费。

### `parseModuleRefStatement` (`src/tests/parser.zig:1000`)

- **签名**：`fn parseModuleRefStatement(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode`。
- **作用**：测试夹具/探针 `parseModuleRefStatement`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。`defer` 释放本次成功路径上的临时资源。关键调用：`env.rt.internAtom`、`engine.bytecode.Bytecode.init`、`function.deinit`、`QjsLexer.init`、`ParseState.init`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。失败路径靠 `errdefer` 对称释放。返回 `!engine.bytecode.Bytecode`，由测试 `try`/`expectError` 消费。

### `moduleBodyStart` (`src/tests/parser.zig:1018`)

- **签名**：`fn moduleBodyStart(code: []const u8) !usize`。
- **作用**：测试夹具/探针 `moduleBodyStart`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：主体是 `switch` 分发。关键调用：`@bitCast`、`std.mem.readInt`。显式 `return error.TestExpectedEqual`。
- **所有权 / 错误 / 调用**：返回 `!usize`，由测试 `try`/`expectError` 消费。

### `moduleRecord` (`src/tests/parser.zig:1032`)

- **签名**：`fn moduleRecord(function: *const engine.bytecode.Bytecode) !*const engine.bytecode.module.Record`。
- **作用**：测试夹具/探针 `moduleRecord`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`if (function.module_record) |*record| return record;`——有模块记录就返回其内部指针，否则显式 `return error.TestExpectedEqual`。
- **所有权 / 错误 / 调用**：返回 `!*const engine.bytecode.module.Record`，由测试 `try`/`expectError` 消费。

### `rootCode` (`src/tests/parser.zig:1037`)

- **签名**：`fn rootCode(function: anytype) []const u8`。
- **作用**：测试夹具/探针 `rootCode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：关键调用：`function.byteCode`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `rootConstants` (`src/tests/parser.zig:1044`)

- **签名**：`fn rootConstants(function: anytype) []const core.JSValue`。
- **作用**：测试夹具/探针 `rootConstants`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：关键调用：`function.constants`、`function.cpoolSlice`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `rootClosureVars` (`src/tests/parser.zig:1051`)

- **签名**：`fn rootClosureVars(function: anytype) []const engine.bytecode.function_bytecode.BytecodeClosureVar`。
- **作用**：测试夹具/探针 `rootClosureVars`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：关键调用：`function.closureVars`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `rootVarDefs` (`src/tests/parser.zig:1057`)

- **签名**：`fn rootVarDefs(function: anytype) []const engine.bytecode.function_bytecode.BytecodeVarDef`。
- **作用**：测试夹具/探针 `rootVarDefs`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：关键调用：`function.varDefs`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `expectAtomName` (`src/tests/parser.zig:1066`)

- **签名**：`fn expectAtomName(env: *TestEnv, atom_id: engine.core.Atom, expected: []const u8) !void`。
- **作用**：测试夹具/探针 `expectAtomName`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`env.rt.atoms.name`、`std.testing.expectEqualStrings`。显式 `return error.TestExpectedEqual`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `functionBytecodeFromValue` (`src/tests/parser.zig:1071`)

- **签名**：`fn functionBytecodeFromValue(value: engine.core.JSValue) ?*const engine.bytecode.FunctionBytecode`。
- **作用**：测试夹具/探针 `functionBytecodeFromValue`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：关键调用：`value.isFunctionBytecode`、`value.objectHeader`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `expectNoGlobalArgumentsVarOpcode` (`src/tests/parser.zig:1077`)

- **签名**：`fn expectNoGlobalArgumentsVarOpcode(function: *const engine.bytecode.FunctionBytecode) !void`。
- **作用**：测试夹具/探针 `expectNoGlobalArgumentsVarOpcode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：主体是 `switch` 分发。含循环。热路径用 `try` 传播分配/引擎错误。关键调用：`expectNoGlobalArgumentsVarOpcode`、`function.byteCode`、`function.closureVar`、`engine.bytecode.opcode.sizeOf`、`std.testing.expect`、`std.mem.readInt`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectFunctionConstant` (`src/tests/parser.zig:1102`)

- **签名**：`fn expectFunctionConstant(function: anytype, index: usize) !*const engine.bytecode.FunctionBytecode`。
- **作用**：测试夹具/探针 `expectFunctionConstant`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`rootConstants`、`std.testing.expect`、`functionBytecodeFromValue`。
- **所有权 / 错误 / 调用**：返回 `!*const engine.bytecode.FunctionBytecode`，由测试 `try`/`expectError` 消费。

### `findFunctionConstantNamed` (`src/tests/parser.zig:1108`)

- **签名**：`fn findFunctionConstantNamed( function: anytype, rt: *core.JSRuntime, expected_name: []const u8, ) ?*const engine.bytecode.FunctionBytecode`。
- **作用**：测试夹具/探针 `findFunctionConstantNamed`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`rootConstants`、`functionBytecodeFromValue`、`std.mem.eql`、`rt.atoms.name`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。无独立 error set 时失败以断言或 panic 终止测试。

### `countFunctionConstantsNamed` (`src/tests/parser.zig:1120`)

- **签名**：`fn countFunctionConstantsNamed( function: anytype, rt: *core.JSRuntime, expected_name: []const u8, ) usize`。
- **作用**：测试夹具/探针 `countFunctionConstantsNamed`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`rootConstants`、`functionBytecodeFromValue`、`std.mem.eql`、`rt.atoms.name`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。无独立 error set 时失败以断言或 panic 终止测试。

### `globalDeclarationClosureNamed` (`src/tests/parser.zig:1133`)

- **签名**：`fn globalDeclarationClosureNamed( function: anytype, rt: *core.JSRuntime, expected_name: []const u8, ) ?*const engine.bytecode.function_bytecode.BytecodeClosureVar`。
- **作用**：测试夹具/探针 `globalDeclarationClosureNamed`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`rootClosureVars`、`cv.closureType`、`std.mem.eql`、`rt.atoms.name`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。无独立 error set 时失败以断言或 panic 终止测试。

### `declarationClosureNamed` (`src/tests/parser.zig:1146`)

- **签名**：`fn declarationClosureNamed( function: anytype, rt: *core.JSRuntime, expected_name: []const u8, ) ?*const engine.bytecode.function_bytecode.BytecodeClosureVar`。
- **作用**：测试夹具/探针 `declarationClosureNamed`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。比 `globalDeclarationClosureNamed` 多收一种：`cv.closureType()` 为 `.global_decl` 或 `.module_decl` 都算，其余跳过，再按 `rt.atoms.name(cv.var_name)` 比名字。关键调用：`rootClosureVars`、`cv.closureType`、`std.mem.eql`、`rt.atoms.name`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。无独立 error set 时失败以断言或 panic 终止测试。

### `globalDeclarationClosureCount` (`src/tests/parser.zig:1159`)

- **签名**：`fn globalDeclarationClosureCount(function: anytype) usize`。
- **作用**：测试夹具/探针 `globalDeclarationClosureCount`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`rootClosureVars`、`cv.closureType`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `varDefNamed` (`src/tests/parser.zig:1167`)

- **签名**：`fn varDefNamed( function: anytype, rt: *core.JSRuntime, expected_name: []const u8, ) ?*const engine.bytecode.function_bytecode.BytecodeVarDef`。
- **作用**：测试夹具/探针 `varDefNamed`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`rootVarDefs`、`std.mem.eql`、`rt.atoms.name`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。无独立 error set 时失败以断言或 panic 终止测试。

### `countPutVarRefStores` (`src/tests/parser.zig:1181`)

- **签名**：`fn countPutVarRefStores(code: []const u8) usize`。
- **作用**：测试夹具/探针 `countPutVarRefStores`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`countOpcode` 对 `put_var_ref`、`put_var_ref0..3` 五个变体求和（不含 check 版）。关键调用：`countOpcode`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countCheckedPutVarRefStores` (`src/tests/parser.zig:1189`)

- **签名**：`fn countCheckedPutVarRefStores(code: []const u8) usize`。
- **作用**：测试夹具/探针 `countCheckedPutVarRefStores`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`countOpcode` 对 `put_var_ref_check`、`put_var_ref_check_init` 两个 TDZ 检查变体求和。关键调用：`countOpcode`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countSetVarRefStores` (`src/tests/parser.zig:1194`)

- **签名**：`fn countSetVarRefStores(code: []const u8) usize`。
- **作用**：测试夹具/探针 `countSetVarRefStores`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`countOpcode` 对 `set_var_ref`、`set_var_ref0..3` 五个变体求和。关键调用：`countOpcode`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countDynEnvProbe` (`src/tests/parser.zig:1202`)

- **签名**：`fn countDynEnvProbe(code: []const u8, kind: engine.bytecode.opcode.dyn_env.ProbeKind) usize`。
- **作用**：测试夹具/探针 `countDynEnvProbe`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`engine.bytecode.opcode.sizeOf`、`engine.bytecode.opcode.dyn_env.decode`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countDynEnvProbeInFunctionBytecode` (`src/tests/parser.zig:1218`)

- **签名**：`fn countDynEnvProbeInFunctionBytecode( fb: *const engine.bytecode.FunctionBytecode, kind: engine.bytecode.opcode.dyn_env.ProbeKind, ) usize`。
- **作用**：测试夹具/探针 `countDynEnvProbeInFunctionBytecode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`countDynEnvProbeInFunctionBytecode`、`countDynEnvProbe`、`fb.byteCode`、`fb.cpoolSlice`、`functionBytecodeFromValue`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countDynEnvProbeRecursive` (`src/tests/parser.zig:1231`)

- **签名**：`fn countDynEnvProbeRecursive(function: anytype, kind: engine.bytecode.opcode.dyn_env.ProbeKind) usize`。
- **作用**：测试夹具/探针 `countDynEnvProbeRecursive`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`countDynEnvProbe`、`rootCode`、`rootConstants`、`functionBytecodeFromValue`、`countDynEnvProbeInFunctionBytecode`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countOpcodeInFunctionBytecode` (`src/tests/parser.zig:1241`)

- **签名**：`fn countOpcodeInFunctionBytecode(fb: *const engine.bytecode.FunctionBytecode, opcode: u8) usize`。
- **作用**：测试夹具/探针 `countOpcodeInFunctionBytecode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`countOpcodeInFunctionBytecode`、`countOpcode`、`fb.byteCode`、`fb.cpoolSlice`、`functionBytecodeFromValue`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countOpcodeRecursive` (`src/tests/parser.zig:1251`)

- **签名**：`fn countOpcodeRecursive(function: anytype, opcode: u8) usize`。
- **作用**：测试夹具/探针 `countOpcodeRecursive`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`countOpcode`、`rootCode`、`rootConstants`、`functionBytecodeFromValue`、`countOpcodeInFunctionBytecode`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countDefineClassNamedInCode` (`src/tests/parser.zig:1261`)

- **签名**：`fn countDefineClassNamedInCode( rt: *core.JSRuntime, code: []const u8, opcode_id: u8, expected_name: []const u8, ) usize`。
- **作用**：测试夹具/探针 `countDefineClassNamedInCode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`engine.bytecode.opcode.sizeOf`、`std.mem.readInt`、`std.mem.eql`、`rt.atoms.name`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。无独立 error set 时失败以断言或 panic 终止测试。

### `countDefineClassNamedInFunctionBytecode` (`src/tests/parser.zig:1281`)

- **签名**：`fn countDefineClassNamedInFunctionBytecode( rt: *core.JSRuntime, function: *const engine.bytecode.FunctionBytecode, opcode_id: u8, expected_name: []const u8, ) usize`。
- **作用**：测试夹具/探针 `countDefineClassNamedInFunctionBytecode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`countDefineClassNamedInFunctionBytecode`、`countDefineClassNamedInCode`、`function.byteCode`、`function.cpoolSlice`、`functionBytecodeFromValue`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。无独立 error set 时失败以断言或 panic 终止测试。

### `countDefineClassNamedRecursive` (`src/tests/parser.zig:1295`)

- **签名**：`fn countDefineClassNamedRecursive( function: anytype, rt: *core.JSRuntime, opcode_id: u8, expected_name: []const u8, ) usize`。
- **作用**：测试夹具/探针 `countDefineClassNamedRecursive`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`countDefineClassNamedInCode`、`rootCode`、`rootConstants`、`functionBytecodeFromValue`、`countDefineClassNamedInFunctionBytecode`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。无独立 error set 时失败以断言或 panic 终止测试。

### `countSemanticOpcodeInFunctionBytecode` (`src/tests/parser.zig:1309`)

- **签名**：`fn countSemanticOpcodeInFunctionBytecode( fb: *const engine.bytecode.FunctionBytecode, opcode_id: u8, ) usize`。
- **作用**：测试夹具/探针 `countSemanticOpcodeInFunctionBytecode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`countSemanticOpcodeInFunctionBytecode`、`countSemanticOpcode`、`fb.byteCode`、`fb.cpoolSlice`、`functionBytecodeFromValue`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countSemanticOpcodeRecursive` (`src/tests/parser.zig:1321`)

- **签名**：`fn countSemanticOpcodeRecursive(function: anytype, opcode_id: u8) usize`。
- **作用**：测试夹具/探针 `countSemanticOpcodeRecursive`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`countSemanticOpcode`、`rootCode`、`rootConstants`、`functionBytecodeFromValue`、`countSemanticOpcodeInFunctionBytecode`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countVarRefStoresRecursive` (`src/tests/parser.zig:1330`)

- **签名**：`fn countVarRefStoresRecursive(function: anytype) usize`。
- **作用**：测试夹具/探针 `countVarRefStoresRecursive`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`inline for` 遍历 12 个写 var_ref 的 opcode（`put_var_ref`、`put_var_ref_check`、`put_var_ref_check_init`、`put_var_ref0..3`、`set_var_ref`、`set_var_ref0..3`），逐个 `countOpcodeRecursive` 累加。含循环。关键调用：`countOpcodeRecursive`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `expectOpcode` (`src/tests/parser.zig:1351`)

- **签名**：`fn expectOpcode(code: []const u8, opcode: u8) !void`。
- **作用**：测试夹具/探针 `expectOpcode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`std.testing.expect`、`countOpcode`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectOpcodeSequence` (`src/tests/parser.zig:1355`)

- **签名**：`fn expectOpcodeSequence(code: []const u8, expected: []const u8) !void`。
- **作用**：测试夹具/探针 `expectOpcodeSequence`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。热路径用 `try` 传播分配/引擎错误。关键调用：`std.testing.expect`、`std.testing.expectEqual`、`engine.bytecode.opcode.sizeOf`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `semanticOpcodeForTest` (`src/tests/parser.zig:1367`)

- **签名**：`fn semanticOpcodeForTest(op_id: u8) u8`。
- **作用**：测试夹具/探针 `semanticOpcodeForTest`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：把 quickened / 短编码 opcode 折回语义代表：先用区间判断压平 `push_minus1..push_7`→`push_i32`、`get_loc0..3`→`get_loc`（`put_loc`/`set_loc`/`get_arg`/`put_arg`/`set_arg`/`get_var_ref`/`put_var_ref`/`set_var_ref` 同构）、`call0..3`→`call`；再用 `switch` 处理零散映射（`push_i8`/`push_i16`→`push_i32`、`push_const8`→`push_const`、`fclosure8`→`fclosure`、`push_empty_string`→`push_atom_value`、`get_loc8`→`get_loc`、`put_loc8`/`put_loc8_get_loc8`→`put_loc`、`get_loc0_field`/`get_loc2_field`→`get_loc`、`push_this_put_loc0`→`push_this`、`cmp_if_false8`→`lt`、`eq_if_false8`→`eq`、`get_field2_call_method`→`get_field2`、`set_loc8`→`set_loc`、`get_length`→`get_field`、`if_false8`/`if_true8`/`goto8`/`goto16`→对应长形），其余原样返回。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `expectSemanticOpcodeAt` (`src/tests/parser.zig:1400`)

- **签名**：`fn expectSemanticOpcodeAt(code: []const u8, pc: usize, expected: u8) !void`。
- **作用**：测试夹具/探针 `expectSemanticOpcodeAt`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`std.testing.expect`、`std.testing.expectEqual`、`semanticOpcodeForTest`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectSemanticOpcodeSequence` (`src/tests/parser.zig:1405`)

- **签名**：`fn expectSemanticOpcodeSequence(code: []const u8, expected: []const u8) !void`。
- **作用**：测试夹具/探针 `expectSemanticOpcodeSequence`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。热路径用 `try` 传播分配/引擎错误。关键调用：`expectSemanticOpcodeAt`、`engine.bytecode.opcode.sizeOf`、`std.testing.expect`、`std.testing.expectEqual`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `firstSemanticOpcodeOffset` (`src/tests/parser.zig:1416`)

- **签名**：`fn firstSemanticOpcodeOffset(code: []const u8, expected: u8) ?usize`。
- **作用**：测试夹具/探针 `firstSemanticOpcodeOffset`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`engine.bytecode.opcode.sizeOf`、`semanticOpcodeForTest`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countSemanticOpcode` (`src/tests/parser.zig:1427`)

- **签名**：`fn countSemanticOpcode(code: []const u8, expected: u8) usize`。
- **作用**：测试夹具/探针 `countSemanticOpcode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`engine.bytecode.opcode.sizeOf`、`@intFromBool`、`semanticOpcodeForTest`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `integerPushValueAtOpcode` (`src/tests/parser.zig:1439`)

- **签名**：`fn integerPushValueAtOpcode(code: []const u8, pc: usize) ?i32`。
- **作用**：测试夹具/探针 `integerPushValueAtOpcode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：主体是 `switch` 分发。关键调用：`@bitCast`、`std.mem.readInt`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countIntegerPushValue` (`src/tests/parser.zig:1452`)

- **签名**：`fn countIntegerPushValue(code: []const u8, expected: i32) usize`。
- **作用**：测试夹具/探针 `countIntegerPushValue`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`engine.bytecode.opcode.sizeOf`、`integerPushValueAtOpcode`、`@intFromBool`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `slotIndexAtOpcode` (`src/tests/parser.zig:1465`)

- **签名**：`fn slotIndexAtOpcode(code: []const u8, pc: usize) ?u16`。
- **作用**：测试夹具/探针 `slotIndexAtOpcode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：主体是 `switch` 分发。含循环。关键调用：`engine.bytecode.opcode.formatOf`、`std.mem.readInt`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `labelTargetAtOpcode` (`src/tests/parser.zig:1488`)

- **签名**：`fn labelTargetAtOpcode(code: []const u8, pc: usize) ?usize`。
- **作用**：测试夹具/探针 `labelTargetAtOpcode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：主体是 `switch` 分发。关键调用：`engine.bytecode.opcode.formatOf`、`@bitCast`、`std.mem.readInt`、`std.math.add`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `readU16AtOpcode` (`src/tests/parser.zig:1506`)

- **签名**：`fn readU16AtOpcode(code: []const u8, op_offset: usize) u16`。
- **作用**：测试夹具/探针 `readU16AtOpcode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：关键调用：`std.mem.readInt`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `readConstIndexAtOpcode` (`src/tests/parser.zig:1510`)

- **签名**：`fn readConstIndexAtOpcode(code: []const u8, op_offset: usize) u32`。
- **作用**：测试夹具/探针 `readConstIndexAtOpcode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：主体是 `switch` 分发。关键调用：`readU32`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `expectOpcodeRecursive` (`src/tests/parser.zig:1518`)

- **签名**：`fn expectOpcodeRecursive(function: anytype, opcode: u8) !void`。
- **作用**：测试夹具/探针 `expectOpcodeRecursive`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`std.testing.expect`、`countOpcodeRecursive`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectModuleRecordCounts` (`src/tests/parser.zig:1522`)

- **签名**：`fn expectModuleRecordCounts( record: *const engine.bytecode.module.Record, requests: usize, imports: usize, exports: usize, indirect_exports: usize, star_exports: usize, ) !void`。
- **作用**：测试夹具/探针 `expectModuleRecordCounts`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`std.testing.expectEqual`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectModuleRequest` (`src/tests/parser.zig:1538`)

- **签名**：`fn expectModuleRequest(env: *TestEnv, record: *const engine.bytecode.module.Record, index: usize, module_name: []const u8) !void`。
- **作用**：测试夹具/探针 `expectModuleRequest`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`expectAtomName`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectModuleImport` (`src/tests/parser.zig:1542`)

- **签名**：`fn expectModuleImport( env: *TestEnv, record: *const engine.bytecode.module.Record, index: usize, request_index: u32, import_name: []const u8, local_name: []const u8, ) !void`。
- **作用**：测试夹具/探针 `expectModuleImport`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`std.testing.expectEqual`、`expectAtomName`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectModuleExport` (`src/tests/parser.zig:1556`)

- **签名**：`fn expectModuleExport( env: *TestEnv, record: *const engine.bytecode.module.Record, index: usize, export_name: []const u8, local_name: []const u8, ) !void`。
- **作用**：测试夹具/探针 `expectModuleExport`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`expectAtomName`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectModuleIndirectExport` (`src/tests/parser.zig:1568`)

- **签名**：`fn expectModuleIndirectExport( env: *TestEnv, record: *const engine.bytecode.module.Record, index: usize, request_index: u32, export_name: []const u8, import_name: []const u8, ) !void`。
- **作用**：测试夹具/探针 `expectModuleIndirectExport`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`std.testing.expectEqual`、`expectAtomName`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectModuleStarExport` (`src/tests/parser.zig:1582`)

- **签名**：`fn expectModuleStarExport( env: *TestEnv, record: *const engine.bytecode.module.Record, index: usize, request_index: u32, export_name: []const u8, ) !void`。
- **作用**：测试夹具/探针 `expectModuleStarExport`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`std.testing.expectEqual`、`expectAtomName`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `parseFunctionBodyStatement` (`src/tests/parser.zig:1594`)

- **签名**：`fn parseFunctionBodyStatement(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode`。
- **作用**：测试夹具/探针 `parseFunctionBodyStatement`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。`defer` 释放本次成功路径上的临时资源。关键调用：`env.rt.internAtom`、`engine.bytecode.Bytecode.init`、`function.deinit`、`QjsLexer.init`、`ParseState.init`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。失败路径靠 `errdefer` 对称释放。返回 `!engine.bytecode.Bytecode`，由测试 `try`/`expectError` 消费。

### `parseStrictFunctionBodyStatement` (`src/tests/parser.zig:1609`)

- **签名**：`fn parseStrictFunctionBodyStatement(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode`。
- **作用**：Same single-statement harness, but the synthesized function is strict — the strict-only PTC fold in resolve_labels keys off `fd.is_strict_mode`.。
- **实现**：Same single-statement harness, but the synthesized function is strict — the strict-only PTC fold in resolve_labels keys off `fd.is_strict_mode`.。热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。`defer` 释放本次成功路径上的临时资源。关键调用：`env.rt.internAtom`、`engine.bytecode.Bytecode.init`、`function.deinit`、`QjsLexer.init`、`ParseState.init`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。失败路径靠 `errdefer` 对称释放。返回 `!engine.bytecode.Bytecode`，由测试 `try`/`expectError` 消费。

### `expectParseStatementError` (`src/tests/parser.zig:1623`)

- **签名**：`fn expectParseStatementError(env: *TestEnv, src: []const u8) !void`。
- **作用**：测试夹具/探针 `expectParseStatementError`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`parseStatement`、`fn_bc.deinit`、`std.testing.expectEqual`。显式 `return error.TestExpectedError`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `readU32` (`src/tests/parser.zig:1641`)

- **签名**：`fn readU32(bytes: []const u8, offset: usize) u32`。
- **作用**：Read a u32 in little-endian from `bytes` starting at `offset`.。
- **实现**：Read a u32 in little-endian from `bytes` starting at `offset`.。关键调用：`std.mem.readInt`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `readI32` (`src/tests/parser.zig:1645`)

- **签名**：`fn readI32(bytes: []const u8, offset: usize) i32`。
- **作用**：测试夹具/探针 `readI32`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：关键调用：`std.mem.readInt`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `readRelTarget32` (`src/tests/parser.zig:1649`)

- **签名**：`fn readRelTarget32(bytes: []const u8, op_offset: usize) usize`。
- **作用**：测试夹具/探针 `readRelTarget32`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：主体是 `switch` 分发。关键调用：`engine.bytecode.opcode.formatOf`、`std.mem.readInt`、`readI32`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countSubOpcode` (`src/tests/parser.zig:1662`)

- **签名**：`fn countSubOpcode(code: []const u8, sub: u8) usize`。
- **作用**：冷平面对应物：被回收的 opcode 编码成「载体 + sub」一对，所以在位检查按这一对扫描；载体现为 `op.ext0`（源码注释里的 `{using, sub}` 是旧名）。
- **实现**：按指令边界走 `code`：载体即 `op.ext0`，命中 `code[pc] == op.ext0 and code[pc+1] == sub` 计一次；`engine.bytecode.opcode.sizeOf` 返回 0 时 `break`（源码注释里的 `{using, sub}` 与 `docs/perf/opcode-space-survey.md §8` 均已过时——载体已改成 `ext0`，该调研并入 `docs/perf/opcode-design.md`）。含循环。关键调用：`engine.bytecode.opcode.sizeOf`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `subOpcodeOffset` (`src/tests/parser.zig:1679`)

- **签名**：`fn subOpcodeOffset(code: []const u8, sub: u8) ?usize`。
- **作用**：Byte offset of the first carrier instruction with the given sub tag, walked on instruction boundaries. C0 moved to_propkey behind the carrier, so final-stream assertions locate residents this way instead of scanning for a direct id.。
- **实现**：Byte offset of the first carrier instruction with the given sub tag, walked on instruction boundaries. C0 moved to_propkey behind the carrier, so final-stream assertions locate residents this way instead of scanning for a direct id.。含循环。关键调用：`engine.bytecode.opcode.sizeOf`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countOpcode` (`src/tests/parser.zig:1691`)

- **签名**：`fn countOpcode(code: []const u8, opcode: u8) usize`。
- **作用**：测试夹具/探针 `countOpcode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`engine.bytecode.opcode.sizeOf`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `firstOpcodeOffset` (`src/tests/parser.zig:1704`)

- **签名**：`fn firstOpcodeOffset(code: []const u8, opcode: u8) ?usize`。
- **作用**：测试夹具/探针 `firstOpcodeOffset`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`engine.bytecode.opcode.sizeOf`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countSpecialObjectSubtype` (`src/tests/parser.zig:1716`)

- **签名**：`fn countSpecialObjectSubtype(code: []const u8, subtype: u8) usize`。
- **作用**：测试夹具/探针 `countSpecialObjectSubtype`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`engine.bytecode.opcode.sizeOf`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countVarOpcodeForAtom` (`src/tests/parser.zig:1729`)

- **签名**：`fn countVarOpcodeForAtom(function: anytype, opcode: u8, atom_id: core.Atom) usize`。
- **作用**：测试夹具/探针 `countVarOpcodeForAtom`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`rootCode`、`rootClosureVars`、`readU16AtOpcode`、`engine.bytecode.opcode.sizeOf`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `hasAnyOpcode` (`src/tests/parser.zig:1747`)

- **签名**：`fn hasAnyOpcode(code: []const u8, opcodes: []const u8) bool`。
- **作用**：测试夹具/探针 `hasAnyOpcode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环：逐个 opcode 调 `countOpcode`，任一 >0 就返回 true。关键调用：`countOpcode`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `Audit.scanCode` (`src/tests/parser.zig:5891`)

- **签名**：`fn scanCode(self: *@This(), runtime: *core.JSRuntime, code: []const u8) !void`。
- **作用**：测试夹具/探针 `Audit.scanCode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：按指令边界走一遍 `code`：第一个 `switch` 给 7 个计数器（`private_symbol`/`get_private_field`/`put_private_field`/`private_in`/`define_private_field`/`define_field`/`define_method`）累加；第二个 `switch` 断言四个 private 访问 opcode 的 size 为 1、format 为 `.none`；随后按 format 取出 atom 操作数，断言 private atom 只能出现在 `private_symbol`/`set_name`/`throw_error` 上，且 `define_field`/`define_method` 的 atom 不是 private。主体是 `switch` 分发。含循环。热路径用 `try` 传播分配/引擎错误。关键调用：`engine.bytecode.opcode.sizeOf`、`std.testing.expect`、`engine.bytecode.opcode.formatOf`、`std.testing.expectEqual`、`runtime.atoms.kind`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。返回 `!void`，由测试 `try`/`expectError` 消费。

### `Audit.scanFunction` (`src/tests/parser.zig:5947`)

- **签名**：`fn scanFunction(self: *@This(), runtime: *core.JSRuntime, function: *const engine.bytecode.FunctionBytecode) !void`。
- **作用**：测试夹具/探针 `Audit.scanFunction`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。热路径用 `try` 传播分配/引擎错误。关键调用：`scanFunction`、`self.scanCode`、`function.byteCode`、`function.cpoolSlice`、`functionBytecodeFromValue`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。返回 `!void`，由测试 `try`/`expectError` 消费。

### `tracePhase1ScopeEvents` (`src/tests/parser.zig:6770`)

- **签名**：`fn tracePhase1ScopeEvents(code: []const u8, storage: []Phase1ScopeEvent) ![]const Phase1ScopeEvent`。
- **作用**：测试夹具/探针 `tracePhase1ScopeEvents`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`engine.bytecode.opcode.sizeOfPhase1`、`std.mem.readInt`。显式 `return error.TestUnexpectedResult`。
- **所有权 / 错误 / 调用**：返回 `![]const Phase1ScopeEvent`，由测试 `try`/`expectError` 消费。

### `expectPhase1ScopeEvents` (`src/tests/parser.zig:6791`)

- **签名**：`fn expectPhase1ScopeEvents(code: []const u8, expected: []const ExpectedPhase1ScopeEvent) !void`。
- **作用**：测试夹具/探针 `expectPhase1ScopeEvents`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。热路径用 `try` 传播分配/引擎错误。关键调用：`tracePhase1ScopeEvents`、`std.testing.expectEqual`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `findPhase1Opcode` (`src/tests/parser.zig:6801`)

- **签名**：`fn findPhase1Opcode(code: []const u8, opcode_id: u8, start_pc: usize) !?usize`。
- **作用**：测试夹具/探针 `findPhase1Opcode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`engine.bytecode.opcode.sizeOfPhase1`。显式 `return error.TestUnexpectedResult`。
- **所有权 / 错误 / 调用**：返回 `!?usize`，由测试 `try`/`expectError` 消费。

### `countPhase1Opcode` (`src/tests/parser.zig:6813`)

- **签名**：`fn countPhase1Opcode(code: []const u8, opcode_id: u8) !usize`。
- **作用**：测试夹具/探针 `countPhase1Opcode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`engine.bytecode.opcode.sizeOfPhase1`。显式 `return error.TestUnexpectedResult`。
- **所有权 / 错误 / 调用**：返回 `!usize`，由测试 `try`/`expectError` 消费。

### `fdPhase1Code` (`src/tests/parser.zig:6828`)

- **签名**：`fn fdPhase1Code(fd: *const engine.bytecode.FunctionDef) []const u8`。
- **作用**：The compact phase-1 stream a FunctionDef's Builder holds while the parse is still live.。
- **实现**：`fd.v2_builder orelse return &.{}`，再返回 `b.code[0..b.code_len]`——解析仍在进行时，phase-1 紧凑流只存在于 Builder 里。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `fdLabelOffset` (`src/tests/parser.zig:6837`)

- **签名**：`fn fdLabelOffset(fd: *const engine.bytecode.FunctionDef, label_index: u32) u32`。
- **作用**：Output offset a parser-created LabelId is bound at, in the compact stream. The compact encoding stores the LabelId in the jump operand; the target is the slot's bound offset, which is what the legacy absolute operand used to carry directly.。
- **实现**：`fd.v2_builder.?.label_slots[label_index].bound_offset`——直接取 label 槽的绑定偏移（无 v2_builder 时会 panic）。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `publishPhase1Stream` (`src/tests/parser.zig:6844`)

- **签名**：`fn publishPhase1Stream(function: *engine.bytecode.Bytecode, state: *ParseState) !void`。
- **作用**：Publish the parser's compact phase-1 stream onto `function` so the byte-sequence tests below can inspect it after the ParseState — which owns the Builder the parser emitted into — is torn down.。
- **实现**：Publish the parser's compact phase-1 stream onto `function` so the byte-sequence tests below can inspect it after the ParseState — which owns the Builder the parser emitted into — is torn down.。含循环。热路径用 `try` 传播分配/引擎错误。关键调用：`function.setCode`、`function.appendAtomOperand`、`function.appendSourceLoc`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `parseRawStatement` (`src/tests/parser.zig:6853`)

- **签名**：`fn parseRawStatement(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode`。
- **作用**：测试夹具/探针 `parseRawStatement`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。`defer` 释放本次成功路径上的临时资源。关键调用：`env.rt.internAtom`、`engine.bytecode.Bytecode.init`、`function.deinit`、`QjsLexer.init`、`ParseState.init`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。失败路径靠 `errdefer` 对称释放。返回 `!engine.bytecode.Bytecode`，由测试 `try`/`expectError` 消费。

### `parseRawExprWithRuntime` (`src/tests/parser.zig:6867`)

- **签名**：`fn parseRawExprWithRuntime(env: *TestEnv, src: []const u8) !engine.bytecode.Bytecode`。
- **作用**：测试夹具/探针 `parseRawExprWithRuntime`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。`defer` 释放本次成功路径上的临时资源。关键调用：`env.rt.internAtom`、`engine.bytecode.Bytecode.init`、`function.deinit`、`QjsLexer.init`、`ParseState.initWithRuntime`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。失败路径靠 `errdefer` 对称释放。返回 `!engine.bytecode.Bytecode`，由测试 `try`/`expectError` 消费。

### `parseRawTSProgram` (`src/tests/parser.zig:6879`)

- **签名**：`fn parseRawTSProgram(env: *TestEnv, src: []const u8) !test_entry.Program`。
- **作用**：测试夹具/探针 `parseRawTSProgram`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：单表达式转调 `test_entry.parseAndCompileV2TestProgram(env.rt, std.testing.allocator, "scope-events-ts", src, .{ .source_kind = .typescript })`。关键调用：`test_entry.parseAndCompileV2TestProgram`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。返回 `!test_entry.Program`，由测试 `try`/`expectError` 消费。

### `expectContinueTargetFollowsBodyLeave` (`src/tests/parser.zig:7275`)

- **签名**：`fn expectContinueTargetFollowsBodyLeave( env: *TestEnv, source: []const u8, expected_events: usize, jump_event: usize, target_event: usize, ) !void`。
- **作用**：The labelled-continue jump must target the position immediately after the body scope's leave event, which the compact stream expresses as the bound offset of the LabelId the jump relocates to.。
- **实现**：用 `ParseState` + `configureScriptRoot` + `beginProgramEmission` 解析 `source`（只到 phase 1，不 finalize），`fdPhase1Code` 取紧凑流后 `tracePhase1ScopeEvents` 抽 scope 事件：断言事件总数 == `expected_events`；`events[jump_event].pc + 3` 处是 `op.goto`，其 u32 操作数是 LabelId，`fdLabelOffset` 解出的绑定偏移必须等于 `events[target_event].pc + 3`；再断言该目标事件是 `.leave`、scope 号为 2。热路径用 `try` 传播分配/引擎错误。`defer` 释放本次成功路径上的临时资源。关键调用：`env.rt.internAtom`、`engine.bytecode.Bytecode.init`、`function.deinit`、`QjsLexer.init`、`ParseState.init`、`fdPhase1Code`、`tracePhase1ScopeEvents`、`fdLabelOffset`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。返回 `!void`，由测试 `try`/`expectError` 消费。

### `compilePaddedDeclarationIndexCase` (`src/tests/parser.zig:7543`)

- **签名**：`fn compilePaddedDeclarationIndexCase( rt: *core.JSRuntime, tail: []const u8, filename: []const u8, ) !bool`。
- **作用**：测试夹具/探针 `compilePaddedDeclarationIndexCase`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：拼一段 `function indexedDeclarations(){` + `declaration_index_padding_count`（65）条 `const __declaration_index_pad_{i}=0;` + 调用方给的 `tail` + `}` 的源文，交给 `compileForTest(rt, ..., .{ .mode = .script, .filename = filename })`，返回 `parsed.syntax_error != null`（即「是否报语法错误」）。含循环。热路径用 `try` 传播分配/引擎错误。`defer` 释放本次成功路径上的临时资源。关键调用：`std.ArrayList`、`source.deinit`、`source.appendSlice`、`std.fmt.bufPrint`、`compileForTest`、`parsed.deinit`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。返回 `!bool`，由测试 `try`/`expectError` 消费。

### `runParserDeclarationIndexOomRetry` (`src/tests/parser.zig:7674`)

- **签名**：`fn runParserDeclarationIndexOomRetry( cleanup_rt: *core.JSRuntime, fail_offset: usize, ) !bool`。
- **作用**：测试夹具/探针 `runParserDeclarationIndexOomRetry`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：用 `std.testing.FailingAllocator` 建独立 `MemoryAccount`/`AtomTable`/`ParseState`，先 `defineVar` 前 64 个 atom，再把 `fail_index` 设成 `alloc_index + fail_offset` 后定义第 65 个：若被注入 OOM（`error.OutOfMemory`）则断言 `has_induced_failure`、`vars.len` 仍是 64，并重试一次；无论哪条路径最终都断言 `vars.len == 65`，返回是否真的触发了注入失败。主体是 `switch` 分发（对 `defineVar` 的 err 分流）。含循环。热路径用 `try` 传播分配/引擎错误。`defer` 释放本次成功路径上的临时资源。关键调用：`std.testing.FailingAllocator`、`core.memory.MemoryAccount.init`、`failing.allocator`、`core.atom.AtomTable.init`、`atoms.deinit`、`ParseState.init`、`state.defineVar`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。返回 `!bool`，由测试 `try`/`expectError` 消费。

### `Chain.end` (`src/tests/parser.zig:8976`)

- **签名**：`fn end(vardefs: []const engine.bytecode.function_bytecode.BytecodeVarDef, head: i32) !i32`。
- **作用**：测试夹具/探针 `Chain.end`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：从 `head` 起沿 `vardefs[index].scope_next` 走链，直到 index 为负返回该终止值；越界或访问次数超过 `vardefs.len`（成环）时显式 `return error.TestUnexpectedResult`。含循环。
- **所有权 / 错误 / 调用**：返回 `!i32`，由测试 `try`/`expectError` 消费。

### `Chain.containsName` (`src/tests/parser.zig:8987`)

- **签名**：`fn containsName( runtime: *core.JSRuntime, vardefs: []const engine.bytecode.function_bytecode.BytecodeVarDef, head: i32, expected: []const u8, ) !bool`。
- **作用**：测试夹具/探针 `Chain.containsName`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：同 `Chain.end` 的走链循环，但每步用 `runtime.atoms.name(vd.var_name)` 与 `expected` 比名字，命中返回 true，走完返回 false；越界/成环时显式 `return error.TestUnexpectedResult`。含循环。关键调用：`std.mem.eql`、`runtime.atoms.name`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。返回 `!bool`，由测试 `try`/`expectError` 消费。

### `countCalls` (`src/tests/parser.zig:9775`)

- **签名**：`fn countCalls(code: []const u8) usize`。
- **作用**：测试夹具/探针 `countCalls`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`countOpcode` 对 `qop.call`、`qop.call0..call3` 五个调用 opcode 求和。关键调用：`countOpcode`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `countFunctionClosures` (`src/tests/parser.zig:9783`)

- **签名**：`fn countFunctionClosures(code: []const u8) usize`。
- **作用**：测试夹具/探针 `countFunctionClosures`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`countOpcode(code, qop.fclosure) + countOpcode(code, qop.fclosure8)` 两个形式的闭包生成 opcode 求和。关键调用：`countOpcode`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `functionBytecodeHasKind` (`src/tests/parser.zig:9890`)

- **签名**：`fn functionBytecodeHasKind(fb: *const engine.bytecode.FunctionBytecode, kind: function_def.FunctionKind) bool`。
- **作用**：测试夹具/探针 `functionBytecodeHasKind`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`functionBytecodeHasKind`、`fb.functionKind`、`fb.cpoolSlice`、`functionBytecodeFromValue`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `functionBytecodeHasClosure` (`src/tests/parser.zig:9900`)

- **签名**：`fn functionBytecodeHasClosure( rt: *core.JSRuntime, fb: *const engine.bytecode.FunctionBytecode, name: []const u8, closure_type: function_def.ClosureType, ) bool`。
- **作用**：测试夹具/探针 `functionBytecodeHasClosure`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`functionBytecodeHasClosure`、`fb.closureVar`、`cv.closureType`、`std.mem.eql`、`rt.atoms.name`、`fb.cpoolSlice`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。无独立 error set 时失败以断言或 panic 终止测试。

### `findFunctionBytecodeCapturingAtom` (`src/tests/parser.zig:9917`)

- **签名**：`fn findFunctionBytecodeCapturingAtom( fb: *const engine.bytecode.FunctionBytecode, atom_id: core.Atom, ) ?*const engine.bytecode.FunctionBytecode`。
- **作用**：测试夹具/探针 `findFunctionBytecodeCapturingAtom`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`findFunctionBytecodeCapturingAtom`、`fb.closureVar`、`fb.cpoolSlice`、`functionBytecodeFromValue`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `findFunctionCapturingAtom` (`src/tests/parser.zig:9934`)

- **签名**：`fn findFunctionCapturingAtom( function: anytype, atom_id: core.Atom, ) ?*const engine.bytecode.FunctionBytecode`。
- **作用**：测试夹具/探针 `findFunctionCapturingAtom`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`rootConstants`、`functionBytecodeFromValue`、`findFunctionBytecodeCapturingAtom`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `functionHasClosure` (`src/tests/parser.zig:9948`)

- **签名**：`fn functionHasClosure( rt: *core.JSRuntime, function: anytype, name: []const u8, closure_type: function_def.ClosureType, ) bool`。
- **作用**：测试夹具/探针 `functionHasClosure`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`rootConstants`、`functionBytecodeFromValue`、`functionBytecodeHasClosure`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。无独立 error set 时失败以断言或 panic 终止测试。

### `expectFunctionClosureRecursive` (`src/tests/parser.zig:9962`)

- **签名**：`fn expectFunctionClosureRecursive( rt: *core.JSRuntime, function: anytype, name: []const u8, closure_type: function_def.ClosureType, ) !void`。
- **作用**：测试夹具/探针 `expectFunctionClosureRecursive`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`std.testing.expect`、`functionHasClosure`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。返回 `!void`，由测试 `try`/`expectError` 消费。

### `functionHasKind` (`src/tests/parser.zig:9971`)

- **签名**：`fn functionHasKind(function: anytype, kind: function_def.FunctionKind) bool`。
- **作用**：测试夹具/探针 `functionHasKind`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`rootConstants`、`functionBytecodeFromValue`、`functionBytecodeHasKind`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `expectFunctionKindRecursive` (`src/tests/parser.zig:9980`)

- **签名**：`fn expectFunctionKindRecursive(function: anytype, kind: function_def.FunctionKind) !void`。
- **作用**：测试夹具/探针 `expectFunctionKindRecursive`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`std.testing.expect`、`functionHasKind`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `expectAtomOperandName` (`src/tests/parser.zig:10069`)

- **签名**：`fn expectAtomOperandName(rt: *core.JSRuntime, function: anytype, expected: []const u8) !void`。
- **作用**：测试夹具/探针 `expectAtomOperandName`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：按指令边界扫 `rootCode(function)`，遇到 format 属 `.atom`/`.atom_u8`/`.atom_cache_u8`/`.atom_u16`/`.atom_label_u8`/`.atom_label_u16` 的指令就读出 u32 atom 操作数，名字等于 `expected` 即成功返回；扫完没命中则显式 `return error.TestExpectedEqual`。主体是 `switch` 分发。含循环。关键调用：`rootCode`、`engine.bytecode.opcode.sizeOf`、`engine.bytecode.opcode.formatOf`、`std.mem.readInt`、`rt.atoms.name`、`std.mem.eql`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。返回 `!void`，由测试 `try`/`expectError` 消费。

### `atomLiveEntryTotal` (`src/tests/parser.zig:13142`)

- **签名**：`pub fn atomLiveEntryTotal(rt: *const core.JSRuntime) usize`。
- **作用**：Count the OCCUPIED entries of the runtime atom table. TGC S3-c retired the retain counter, so the table-level invariant a compile has to satisfy is stated on entries instead of on retains: after a compile product is dropped and collected, the table must be back to the set of entries it had before.。
- **实现**：`for (rt.atoms.entries) |entry| total +|= @intFromBool(entry.slotOccupied());`——遍历 atom 表所有槽，用饱和加法累计 OCCUPIED 条目数。含循环。关键调用：`@intFromBool`、`entry.slotOccupied`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。无独立 error set 时失败以断言或 panic 终止测试。

### `phase_ownership.Baseline.capture` (`src/tests/parser.zig:13513`)

- **签名**：`fn capture(rt: *const core.JSRuntime) Baseline`。
- **作用**：MemoryAccount.recordAlloc splits its call counters by shape: a single-object `create` bumps create_calls, a slice `alloc` bumps alloc_calls, and both bump the live allocation_count (core/memory.zig recordAlloc/recordFree). The builder ledger must therefore sum both entry points, or a FunctionDef child — allocated through `create` — breaks the owned == allocated - released identity.。
- **实现**：从 `rt.memory` 取三个读数组成 `Baseline`：`acquisitions = alloc_calls + create_calls`、`releases = free_calls + destroy_calls`、`allocation_count = allocation_count`——两个入口都要求和，否则走 `create` 的 FunctionDef 子节点会破坏 `owned == allocated - released` 恒等式。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。无独立 error set 时失败以断言或 panic 终止测试。

### `phase_ownership.pendingFixupCount` (`src/tests/parser.zig:13536`)

- **签名**：`fn pendingFixupCount(state: *const ParseState) usize`。
- **作用**：测试夹具/探针 `phase_ownership.pendingFixupCount`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`state.break_fixups.items.len + state.continue_fixups.items.len` 起算，再遍历 `state.label_frames.items` 把每个 frame 的 break/continue fixup 长度累加——即解析态里尚未回填的跳转总数。含循环。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `phase_ownership.formatHasLabelOperand` (`src/tests/parser.zig:13544`)

- **签名**：`fn formatHasLabelOperand(format: engine.bytecode.opcode.Format) bool`。
- **作用**：测试夹具/探针 `phase_ownership.formatHasLabelOperand`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`switch (format)`：`.label8`、`.label16`、`.label`、`.atom_label_u8`、`.atom_label_u16`、`.label_u16` 返回 true，其余 false。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `phase_ownership.censusCode` (`src/tests/parser.zig:13551`)

- **签名**：`fn censusCode(code: []const u8, phase: CodePhase) CodeCensus`。
- **作用**：测试夹具/探针 `phase_ownership.censusCode`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：主体是 `switch` 分发。含循环。关键调用：`engine.bytecode.opcode.sizeOfPhase1`、`engine.bytecode.opcode.sizeOf`、`engine.bytecode.opcode.formatOfPhase1`、`engine.bytecode.opcode.formatOf`、`formatHasLabelOperand`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `phase_ownership.attachedSourceCount` (`src/tests/parser.zig:13583`)

- **签名**：`fn attachedSourceCount(function: *const engine.bytecode.Bytecode) usize`。
- **作用**：测试夹具/探针 `phase_ownership.attachedSourceCount`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：遍历 `function.source_loc_slots`，只数 `slot.pc < function.code.len` 的槽——即真正落在当前码流内的 source 标记数。含循环。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `phase_ownership.builderRelocCount` (`src/tests/parser.zig:13593`)

- **签名**：`fn builderRelocCount(fd: *const engine.bytecode.FunctionDef) usize`。
- **作用**：Relocations the parser produced, over the whole FunctionDef tree: the live population the resolver must consume before the artifact exists.。
- **实现**：Relocations the parser produced, over the whole FunctionDef tree: the live population the resolver must consume before the artifact exists.。含循环。关键调用：`builderRelocCount`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `phase_ownership.builderSourceCount` (`src/tests/parser.zig:13600`)

- **签名**：`fn builderSourceCount(fd: *const engine.bytecode.FunctionDef) usize`。
- **作用**：Source markers the parser produced, over the whole FunctionDef tree.。
- **实现**：Source markers the parser produced, over the whole FunctionDef tree.。含循环。关键调用：`builderSourceCount`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `phase_ownership.Window.init` (`src/tests/parser.zig:13619`)

- **签名**：`pub fn init(self: *Window, rt: *core.JSRuntime, shape: *const Shape) !void`。
- **作用**：测试夹具/探针 `phase_ownership.Window.init`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。`errdefer` 回滚本次失败路径上的分配。入口先 `rt.runObjectCycleRemoval()` 收一轮再 `Baseline.capture` 取基线（TGC S3-c：窗口内的 major 会回收 atom 条目，先收后量）；随后建 `Bytecode`（置 `artifact_live`）/`QjsLexer`（置 `lexer_live`）/`ParseState.initWithRuntime`（置 `state_live`），断言根上 `top_level_functions_as_children` 为假后置 `is_eval`/`is_global_var`，再按 `shape.tier == .nested_function_bytecode` 决定是否打开 `top_level_functions_as_children` + `top_level_lexical_as_global_ref`，跑 `parseDirectives` + `parseProgramStatements` + `emitReturnUndefined` 并断言停在 `TOK_EOF`。关键调用：`rt.runObjectCycleRemoval`、`Baseline.capture`、`engine.bytecode.Bytecode.init`、`self.deinit`、`QjsLexer.init`、`ParseState.initWithRuntime`、`parser_core.parseDirectives`、`parser_core.parseProgramStatements`。
- **所有权 / 错误 / 调用**：测试分配器或调用方传入的 `Allocator` 负责非 GC 堆。堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。失败路径靠 `errdefer` 对称释放。返回 `!void`，由测试 `try`/`expectError` 消费。

### `phase_ownership.Window.deinit` (`src/tests/parser.zig:13670`)

- **签名**：`pub fn deinit(self: *Window) void`。
- **作用**：测试夹具/探针 `phase_ownership.Window.deinit`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：关键调用：`self.discardTemporaries`、`self.releaseArtifact`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `phase_ownership.Window.discardTemporaries` (`src/tests/parser.zig:13675`)

- **签名**：`pub fn discardTemporaries(self: *Window) void`。
- **作用**：测试夹具/探针 `phase_ownership.Window.discardTemporaries`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：关键调用：`self.state.deinit`、`self.lex.deinit`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `phase_ownership.Window.releaseArtifact` (`src/tests/parser.zig:13686`)

- **签名**：`pub fn releaseArtifact(self: *Window) void`。
- **作用**：测试夹具/探针 `phase_ownership.Window.releaseArtifact`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`artifact_live` 为假直接返回；否则 `self.function.deinit(self.rt)` 后再 `self.rt.runObjectCycleRemoval()`，让终态采样能看到零存活分配（TGC S3-c：丢掉最后持有者不再退役 atom 条目，得靠收集器）。关键调用：`self.function.deinit`、`self.rt.runObjectCycleRemoval`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `phase_ownership.Window.sampleB1` (`src/tests/parser.zig:13697`)

- **签名**：`pub fn sampleB1(self: *Window) !Snapshot`。
- **作用**：测试夹具/探针 `phase_ownership.Window.sampleB1`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：关键调用：`builderRelocCount`、`builderSourceCount`、`self.sample`。
- **所有权 / 错误 / 调用**：返回 `!Snapshot`，由测试 `try`/`expectError` 消费。

### `phase_ownership.Window.sample` (`src/tests/parser.zig:13703`)

- **签名**：`pub fn sample(self: *Window, phase: CodePhase) !Snapshot`。
- **作用**：测试夹具/探针 `phase_ownership.Window.sample`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：按 `phase` 取码流普查：`.phase1` 时 relocation 还在 Builder 里，`label_markers` 用 `builderRelocCount` 代替；`.final` 时对 `self.function.code` 走 `censusCode`。再用 `pendingFixupCount` 取未回填数，算出 reloc 三元（`bound = created - fixups`、`discarded = b1_reloc_created - label_markers`、`outstanding = label_markers + fixups`）；builder 三元由 `alloc_calls + create_calls`、`free_calls + destroy_calls`、`allocation_count` 减基线得到（先断言三者都不低于基线）；source 三元按相位取 `builderSourceCount` 或 `function.source_loc_slots.len`，`attached` 在 final 相位走 `attachedSourceCount`，`committed` 取 `function.pc2line_buf.len`。原先还收一个入口即 `_ =` 丢弃的 `previous` 形参，以及只负责转发它的 `sampleNext` 包装层，两者都已删；本函数改为 `pub`，三处 `sampleNext` 调用点直接调它。主体是 `switch` 分发。热路径用 `try` 传播分配/引擎错误。关键调用：`builderRelocCount`、`censusCode`、`std.testing.expect`、`pendingFixupCount`、`builderSourceCount`、`attachedSourceCount`。
- **所有权 / 错误 / 调用**：返回 `!Snapshot`，由测试 `try`/`expectError` 消费。

### `phase_ownership.warmRuntime` (`src/tests/parser.zig:13774`)

- **签名**：`pub fn warmRuntime(rt: *core.JSRuntime, shape: *const Shape) !void`。
- **作用**：测试夹具/探针 `phase_ownership.warmRuntime`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：热路径用 `try` 传播分配/引擎错误。关键调用：`warm.init`、`warm.deinit`。
- **所有权 / 错误 / 调用**：堆对象归 tracing GC；测试必须 `destroy`/`deinit` Runtime（本文件不走共享 harness）。返回 `!void`，由测试 `try`/`expectError` 消费。

### `phase_ownership.setBuilderCommitted` (`src/tests/parser.zig:13783`)

- **签名**：`pub fn setBuilderCommitted(snapshot: *Snapshot, committed: usize) void`。
- **作用**：测试夹具/探针 `phase_ownership.setBuilderCommitted`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`snapshot.builder.committed = committed` 一行；B4 之前 committed 由 B4 的「仅剩 artifact」观测倒推，B4 自身再精确校验这个预测。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `phase_ownership.expectCommon` (`src/tests/parser.zig:13789`)

- **签名**：`pub fn expectCommon(snapshot: Snapshot) !void`。
- **作用**：测试夹具/探针 `phase_ownership.expectCommon`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：五条共同断言：`builder.allocated >= builder.released`；`builder.owned == builder.allocated - builder.released`；`builder.committed <= builder.owned`；`source.outstanding == source.created`；`source.outstanding == source.attached`。热路径用 `try` 传播分配/引擎错误。关键调用：`std.testing.expect`、`std.testing.expectEqual`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `phase_ownership.expectB1` (`src/tests/parser.zig:13800`)

- **签名**：`pub fn expectB1(snapshot: Snapshot) !void`。
- **作用**：测试夹具/探针 `phase_ownership.expectB1`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：先 `expectCommon`，再断言 B1 边界的五条：`reloc.pending_fixups == 0`、`reloc.created == reloc.outstanding`、`reloc.discarded == 0`、`source.discarded == 0`、`source.committed == 0`。热路径用 `try` 传播分配/引擎错误。关键调用：`expectCommon`、`std.testing.expectEqual`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `phase_ownership.expectB3` (`src/tests/parser.zig:13809`)

- **签名**：`pub fn expectB3(b1: Snapshot, b3: Snapshot) !void`。
- **作用**：测试夹具/探针 `phase_ownership.expectB3`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：先 `expectCommon(b3)`，再断言 `b3.reloc.outstanding == 0`、`b3.reloc.pending_fixups == 0`、`b1.reloc.created == b3.reloc.discarded`，接着 `expectSourceFromB1(b1, b3)`；若 `b3.source.outstanding != 0` 还要求 `b3.source.committed > 0`。热路径用 `try` 传播分配/引擎错误。关键调用：`expectCommon`、`std.testing.expectEqual`、`expectSourceFromB1`、`std.testing.expect`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `phase_ownership.expectB4` (`src/tests/parser.zig:13818`)

- **签名**：`pub fn expectB4(b1: Snapshot, b3: Snapshot, b4: Snapshot) !void`。
- **作用**：测试夹具/探针 `phase_ownership.expectB4`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：先 `expectCommon(b4)`，再断言 `b4.reloc.outstanding == 0`、`b4.reloc.pending_fixups == 0`、`b1.reloc.created == b4.reloc.discarded`、`b4.builder.owned <= b3.builder.owned`、`b4.builder.owned == b4.builder.committed`，最后 `expectSourceFromB1(b1, b4)`。热路径用 `try` 传播分配/引擎错误。关键调用：`expectCommon`、`std.testing.expectEqual`、`std.testing.expect`、`expectSourceFromB1`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `phase_ownership.expectSourceFromB1` (`src/tests/parser.zig:13828`)

- **签名**：`pub fn expectSourceFromB1(b1: Snapshot, current: Snapshot) !void`。
- **作用**：测试夹具/探针 `phase_ownership.expectSourceFromB1`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：两条断言：`current.source.outstanding <= b1.source.created`，以及 `b1.source.created == current.source.outstanding + current.source.discarded`（B1 造出的 source 标记要么还在，要么被丢弃，不会凭空多出）。热路径用 `try` 传播分配/引擎错误。关键调用：`std.testing.expect`、`std.testing.expectEqual`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `phase_ownership.expectTerminal` (`src/tests/parser.zig:13836`)

- **签名**：`pub fn expectTerminal(snapshot: Snapshot) !void`。
- **作用**：测试夹具/探针 `phase_ownership.expectTerminal`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：先 `expectCommon`，再要求终态七项全零：`reloc.created`、`reloc.outstanding`、`builder.owned`、`builder.committed`、`source.created`、`source.outstanding`、`source.committed`。热路径用 `try` 传播分配/引擎错误。关键调用：`expectCommon`、`std.testing.expectEqual`。
- **所有权 / 错误 / 调用**：返回 `!void`，由测试 `try`/`expectError` 消费。

### `phase_ownership.publishedFunctionBytecodeCount` (`src/tests/parser.zig:13847`)

- **签名**：`pub fn publishedFunctionBytecodeCount(function: *const engine.bytecode.Bytecode) usize`。
- **作用**：测试夹具/探针 `phase_ownership.publishedFunctionBytecodeCount`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：含循环。关键调用：`@intFromBool`、`value.tagOf`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### `phase_ownership.dump` (`src/tests/parser.zig:13855`)

- **签名**：`pub fn dump(shape: Shape, path: []const u8, boundary: []const u8, snapshot: Snapshot) void`。
- **作用**：测试夹具/探针 `phase_ownership.dump`，给周围 `test` 块提供可注入行为或断言助手。
- **实现**：`dump_phase_ledgers` 为假时直接返回；否则用一次 `std.debug.print` 打出 ATOM / RELOC / BUILDER / SOURCE 四本账的全部字段。关键调用：`std.debug.print`。
- **所有权 / 错误 / 调用**：无独立 error set 时失败以断言或 panic 终止测试。

### 测试块（513）

### `test "scope proof cache bounds ancestor scans across sibling functions"` (`src/tests/parser.zig:20`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「scope proof cache bounds ancestor scans across sibling functions」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "F1.5: every keyword token maps to its predefined atom"` (`src/tests/parser.zig:76`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1.5: every keyword token maps to its predefined atom」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1: of remains an identifier in ordinary lexing"` (`src/tests/parser.zig:141`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1: of remains an identifier in ordinary lexing」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1: freeToken releases its identifier atom owner"` (`src/tests/parser.zig:154`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1: freeToken releases its identifier atom owner」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1: replacing a token releases its owner and stays safe on lexer error"` (`src/tests/parser.zig:166`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1: replacing a token releases its owner and stays safe on lexer error」。
- **实现**：断言错误 `error.InvalidIdentifier`。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1: punctuators use raw ASCII for single-character tokens"` (`src/tests/parser.zig:184`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1: punctuators use raw ASCII for single-character tokens」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1: multi-character operator sequences land on TOK_* values"` (`src/tests/parser.zig:199`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1: multi-character operator sequences land on TOK_* values」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1.2: numeric literals (decimal, hex, octal, binary, exponent, separators)"` (`src/tests/parser.zig:239`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1.2: numeric literals (decimal, hex, octal, binary, exponent, separators)」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "direct eval this is a scope_get_var against the caller seed"` (`src/tests/parser.zig:266`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「direct eval this is a scope_get_var against the caller seed」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "F1.2: numeric literals have no 128-byte length cap"` (`src/tests/parser.zig:291`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1.2: numeric literals have no 128-byte length cap」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1.2: bigint suffix records is_bigint and source text"` (`src/tests/parser.zig:325`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1.2: bigint suffix records is_bigint and source text」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1.2: string escapes (basic, hex, unicode short and braced, surrogate pair)"` (`src/tests/parser.zig:337`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1.2: string escapes (basic, hex, unicode short and braced, surrogate pair)」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: string lexer preserves lone surrogate escapes as code units"` (`src/tests/parser.zig:351`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: string lexer preserves lone surrogate escapes as code units」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1.2: line continuation in string and \\0 NUL escape"` (`src/tests/parser.zig:362`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1.2: line continuation in string and \\0 NUL escape」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1.2: legacy octal in strict mode is rejected"` (`src/tests/parser.zig:374`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1.2: legacy octal in strict mode is rejected」。
- **实现**：断言错误 `error.LegacyOctalInStrictMode`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "G1/P0: template legacy octal escapes mark cooked value invalid"` (`src/tests/parser.zig:384`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「G1/P0: template legacy octal escapes mark cooked value invalid」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1.2: template head/middle/tail produce TemplatePart classification"` (`src/tests/parser.zig:404`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1.2: template head/middle/tail produce TemplatePart classification」。
- **实现**：断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1.2: no-substitution template"` (`src/tests/parser.zig:436`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1.2: no-substitution template」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "G1/P0: template token keeps raw escape bytes"` (`src/tests/parser.zig:447`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「G1/P0: template token keeps raw escape bytes」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "G1/P0: template token normalizes raw CR line terminators"` (`src/tests/parser.zig:459`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「G1/P0: template token normalizes raw CR line terminators」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1.2: regex literal exposes pattern and flags"` (`src/tests/parser.zig:471`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1.2: regex literal exposes pattern and flags」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1.2: regex literal may begin with equals after slash rescan"` (`src/tests/parser.zig:485`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1.2: regex literal may begin with equals after slash rescan」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1.3: private name keeps the # prefix in the atom"` (`src/tests/parser.zig:503`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1.3: private name keeps the # prefix in the atom」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1.3: unicode escape inside identifier is decoded into the atom"` (`src/tests/parser.zig:514`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1.3: unicode escape inside identifier is decoded into the atom」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1.3: escaped keyword spelling is treated as identifier (per spec)"` (`src/tests/parser.zig:526`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1.3: escaped keyword spelling is treated as identifier (per spec)」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1.3: raw Unicode identifier start accepts ID_Start and rejects emoji"` (`src/tests/parser.zig:537`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1.3: raw Unicode identifier start accepts ID_Start and rejects emoji」。
- **实现**：断言错误 `error.InvalidIdentifier`。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1.4: got_lf is true after a LineTerminator and false otherwise"` (`src/tests/parser.zig:553`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1.4: got_lf is true after a LineTerminator and false otherwise」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1.4: line_num and col_num are 1-based"` (`src/tests/parser.zig:571`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1.4: line_num and col_num are 1-based」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1: end-to-end lex of a small program"` (`src/tests/parser.zig:589`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1: end-to-end lex of a small program」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1: HTML comments are stripped in script mode but rejected in module mode"` (`src/tests/parser.zig:615`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1: HTML comments are stripped in script mode but rejected in module mode」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1: hashbang at start of file is skipped, but not later"` (`src/tests/parser.zig:641`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1: hashbang at start of file is skipped, but not later」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1.5: keyword block atom layout matches quickjs-atom.h ordering"` (`src/tests/parser.zig:651`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1.5: keyword block atom layout matches quickjs-atom.h ordering」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F1: Lexer enableTypeScript strips variable and function TypeScript annotations dynamically"` (`src/tests/parser.zig:752`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F1: Lexer enableTypeScript strips variable and function TypeScript annotations dynamically」。
- **实现**：断言 17 处 `std.testing.expect*`。约 17 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "parser accepts computed public class fields"` (`src/tests/parser.zig:1633`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住解析器：accepts computed public class fields。
- **实现**：`ParserTestEnv` 下 `parseStatement(&env, "class C { [\"x\"] = 1; }")`，只要求解析+lowering 不报错（无显式断言，失败靠 `try` 冒泡）。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: number literal lowers to short integer form"` (`src/tests/parser.zig:1756`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: number literal lowers to short integer form」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: number literal with non-integer value lowers to push_const"` (`src/tests/parser.zig:1767`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: number literal with non-integer value lowers to push_const」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: large bigint literal lowers to constant pool value"` (`src/tests/parser.zig:1780`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: large bigint literal lowers to constant pool value」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "W5: signed bigint-i32 neg matches QuickJS final bytecode boundaries"` (`src/tests/parser.zig:1793`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「W5: signed bigint-i32 neg matches QuickJS final bytecode boundaries」。
- **实现**：断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "W5: folded parenthesized bigint keeps the unary minus source position"` (`src/tests/parser.zig:1842`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「W5: folded parenthesized bigint keeps the unary minus source position」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: regexp literal stores pattern then parse-time bytecode in the constant pool"` (`src/tests/parser.zig:1861`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: regexp literal stores pattern then parse-time bytecode in the constant pool」。
- **实现**：断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: regexp pattern constant decodes UTF-8 before the following constant"` (`src/tests/parser.zig:1910`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: regexp pattern constant decodes UTF-8 before the following constant」。
- **实现**：断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: invalid regexp releases its published pattern constant"` (`src/tests/parser.zig:1966`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: invalid regexp releases its published pattern constant」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: boolean and null literals"` (`src/tests/parser.zig:1980`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: boolean and null literals」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: identifier reads global via get_var"` (`src/tests/parser.zig:1997`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: identifier reads global via get_var」。
- **实现**：断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: parseExprBinary level 1 (mul/div/mod)"` (`src/tests/parser.zig:2010`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: parseExprBinary level 1 (mul/div/mod)」。
- **实现**：`parseExpr(&env, "2 * 3")` 后 `expectOpcodeSequence` 逐字节比 `push_2 ; push_3 ; mul`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: parseExprBinary level 2 (add/sub) is left-associative"` (`src/tests/parser.zig:2019`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: parseExprBinary level 2 (add/sub) is left-associative」。
- **实现**：`parseExpr(&env, "1 + 2 - 3")` 后 `expectOpcodeSequence` 比 `push_1 ; push_2 ; add ; push_3 ; sub`——左结合体现在 `add` 先于第二个 `push`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: precedence — multiplication before addition"` (`src/tests/parser.zig:2028`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: precedence — multiplication before addition」。
- **实现**：`parseExpr(&env, "1 + 2 * 3")` 后 `expectOpcodeSequence` 比 `push_1 ; push_2 ; push_3 ; mul ; add`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: parentheses override precedence"` (`src/tests/parser.zig:2037`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: parentheses override precedence」。
- **实现**：`parseExpr(&env, "(1 + 2) * 3")` 后 `expectOpcodeSequence` 比 `push_1 ; push_2 ; add ; push_3 ; mul`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: comparison operators map to op.lt/op.lte/op.eq/op.strict_eq"` (`src/tests/parser.zig:2046`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: comparison operators map to op.lt/op.lte/op.eq/op.strict_eq」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: null comparison lowering keeps strict folds and loose equality distinct"` (`src/tests/parser.zig:2067`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: null comparison lowering keeps strict folds and loose equality distinct」。
- **实现**：同一个 env 里跑四段：`value === null` → `get_var ; is_null`；`value === void 0` → `get_var ; ext0`（载体上的 is_undefined）；`if (value !== null) result;` → `get_var ; is_null ; if_true8 ; get_var ; drop`；`value == null` → `get_var ; null ; eq`（松散相等不折成 is_null）。四处 `expectOpcodeSequence`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: bitwise levels 6/7/8 (and/xor/or) and shifts"` (`src/tests/parser.zig:2094`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: bitwise levels 6/7/8 (and/xor/or) and shifts」。
- **实现**：断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: unary +/-/~/! lower to plus/neg/not/lnot"` (`src/tests/parser.zig:2119`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: unary +/-/~/! lower to plus/neg/not/lnot」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: `!` emits exactly one lnot; plain and comparison conditions emit none"` (`src/tests/parser.zig:2102`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: `!` emits exactly one lnot; plain and comparison conditions emit none」。
- **实现**：遍历 8 个 `{src, hits}` 用例，用 `countOpcode(bc.code, op.lnot)` 比对预期出现次数；断言 1 处 `std.testing.expect*`（在循环内）。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: typeof identifier uses get_var_undef + typeof"` (`src/tests/parser.zig:2170`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: typeof identifier uses get_var_undef + typeof」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: typeof optional chain parses full chain"` (`src/tests/parser.zig:2182`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: typeof optional chain parses full chain」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: typeof comparisons select final short tests at the condition boundary"` (`src/tests/parser.zig:2191`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: typeof comparisons select final short tests at the condition boundary」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: numeric discard in void keeps only undefined"` (`src/tests/parser.zig:2214`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: numeric discard in void keeps only undefined」。
- **实现**：`parseExpr(&env, "void 0")` 后 `expectOpcodeSequence` 比单条 `undefined`——数值操作数被判为纯值直接丢弃。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: strict eval and arguments update targets are rejected"` (`src/tests/parser.zig:2223`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: strict eval and arguments update targets are rejected」。
- **实现**：断言错误 `error.InvalidAssignmentTarget`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: power operator is right-associative"` (`src/tests/parser.zig:2231`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: power operator is right-associative」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: logical && uses dup + if_false short-circuit"` (`src/tests/parser.zig:2239`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: logical && uses dup + if_false short-circuit」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: logical || uses dup + if_true short-circuit"` (`src/tests/parser.zig:2250`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: logical || uses dup + if_true short-circuit」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: if consumes three-term logical chains with final branch snapshots"` (`src/tests/parser.zig:2261`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: if consumes three-term logical chains with final branch snapshots」。
- **实现**：断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: logical producer uses one source-less shared merge label"` (`src/tests/parser.zig:2302`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: logical producer uses one source-less shared merge label」。
- **实现**：断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: collapsed multiline logical branches retain source progression"` (`src/tests/parser.zig:2374`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: collapsed multiline logical branches retain source progression」。
- **实现**：断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: nullish coalescing ?? uses is_undefined_or_null gate"` (`src/tests/parser.zig:2417`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: nullish coalescing ?? uses is_undefined_or_null gate」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: nullish coalescing chains and rejects direct logical mixing"` (`src/tests/parser.zig:2428`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: nullish coalescing chains and rejects direct logical mixing」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: discarded short-circuit with assignment RHS keeps function stack balanced"` (`src/tests/parser.zig:2441`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: discarded short-circuit with assignment RHS keeps function stack balanced」。
- **实现**：无显式 expect 的「不崩即过」栈平衡用例：4 条 failing_cases（`p ?? (p = 5)` / `||` / `&&` 三种短路 + 箭头函数版）走 `parseStatementWithTopLevelChildren`，3 条 control_cases（`let x = p ?? 5; return x;`、`p ?? 5;`、顶层 `pos ?? (pos = 5);`）走 `parseStatement`，全部只要求 lowering 成功（栈不平衡会在 finalize 里断言失败）。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: discarded conditional assignment arms keep function stack balanced"` (`src/tests/parser.zig:2467`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: discarded conditional assignment arms keep function stack balanced」。
- **实现**：5 条三元赋值臂用例（`a ? b = 1 : c`、`a ? b : c = 1`、`c ? 0 : p = 1`、`a ? b : c -= 1`、`a ? b : c[d] = b`）逐条走 `parseStatementWithTopLevelChildren`，只要求 lowering 成功——丢弃臂的栈平衡由 finalize 自检。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: ternary cond ? a : b folds the fragment exit goto to its terminator"` (`src/tests/parser.zig:2484`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: ternary cond ? a : b folds the fragment exit goto to its terminator」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: simple assignment x = 1 emits push ; dup ; put_var (KEEP_TOP)"` (`src/tests/parser.zig:2495`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: simple assignment x = 1 emits push ; dup ; put_var (KEEP_TOP)」。
- **实现**：`parseExpr(&env, "x = 1")` 后 `expectOpcodeSequence` 比 `push_1 ; dup ; put_var`——`dup` 就是 KEEP_TOP（赋值表达式留值）。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: function-local assignment result reaches dup put to set fold"` (`src/tests/parser.zig:2504`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: function-local assignment result reaches dup put to set fold」。
- **实现**：`parseStatementWithTopLevelChildren(&env, "function f() { var x; return x = 1; }")`，用 `findFunctionConstantNamed(..., "f")` 取出子函数（取不到则 `return error.TestExpectedEqual`），对其 `byteCode()` 比 `push_1 ; set_loc0 ; return`——`dup ; put_loc` 已折成 `set_loc0`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: compound assignment x += 1 emits get_var ; rhs ; add ; dup ; put_var"` (`src/tests/parser.zig:2517`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: compound assignment x += 1 emits get_var ; rhs ; add ; dup ; put_var」。
- **实现**：`parseExpr(&env, "x += 1")` 后 `expectOpcodeSequence` 比 `get_var ; push_1 ; add ; dup ; put_var`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: numeric discard in comma removes pure left and keeps right"` (`src/tests/parser.zig:2526`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: numeric discard in comma removes pure left and keeps right」。
- **实现**：`parseExpr(&env, "1, 2")` 后 `expectOpcodeSequence` 比单条 `push_2`——纯值左操作数被丢弃。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: member access a.b emits get_var_field + get_field"` (`src/tests/parser.zig:2535`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: member access a.b emits get_var_field + get_field」。
- **实现**：`parseExpr(&env, "a.b")` 后 `expectOpcodeSequence` 比 `get_var_field ; get_field`。测试名原写作 `get_var + get_field`，与断言不符，已改成实际的合并形式。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: index access a[i] emits get_var ; get_var ; get_array_el"` (`src/tests/parser.zig:2544`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: index access a[i] emits get_var ; get_var ; get_array_el」。
- **实现**：`parseExpr(&env, "a[i]")` 后 `expectOpcodeSequence` 比 `get_var ; get_var ; get_array_el`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: nested assignment 1 + (a = b) preserves the leading push"` (`src/tests/parser.zig:2555`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: nested assignment 1 + (a = b) preserves the leading push」。
- **实现**：`parseExpr(&env, "1 + (a = b)")` 后 `expectOpcodeSequence` 比 `push_1 ; get_var ; dup ; put_var ; add`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: string literal lowers to push_atom_value"` (`src/tests/parser.zig:2564`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: string literal lowers to push_atom_value」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: empty string literal lowers to push_empty_string"` (`src/tests/parser.zig:2575`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: empty string literal lowers to push_empty_string」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: array literal lowers to push elements ; array_from N"` (`src/tests/parser.zig:2585`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: array literal lowers to push elements ; array_from N」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: empty array literal emits array_from 0"` (`src/tests/parser.zig:2596`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: empty array literal emits array_from 0」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: trailing comma in array literal is allowed"` (`src/tests/parser.zig:2608`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: trailing comma in array literal is allowed」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: two-slot object literal carries its allocation capacity hint"` (`src/tests/parser.zig:2619`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: two-slot object literal carries its allocation capacity hint」。
- **实现**：`parseExpr(&env, "{ a: 1, b: 2 }")` 后 `expectOpcodeSequence` 比 `object_slots2 ; push_1 ; define_field ; push_2 ; define_field`——`object_slots2` 里的 2 就是容量提示。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: object literal capacity hint counts unique static slots only"` (`src/tests/parser.zig:2628`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: object literal capacity hint counts unique static slots only」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: empty object literal emits object"` (`src/tests/parser.zig:2658`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: empty object literal emits object」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: shorthand object property { x } emits get_var x ; define_field x"` (`src/tests/parser.zig:2671`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: shorthand object property { x } emits get_var x ; define_field x」。
- **实现**：`parseExpr(&env, "{ x }")` 后 `expectOpcodeSequence` 比 `object_slots2 ; get_var ; define_field`（简写属性等价于 `x: x`）。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: computed object property emits define_array_el"` (`src/tests/parser.zig:2680`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: computed object property emits define_array_el」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: object spread emits copy_data_properties"` (`src/tests/parser.zig:2699`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: object spread emits copy_data_properties」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: keyword object property names parse as literal keys"` (`src/tests/parser.zig:2709`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: keyword object property names parse as literal keys」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: object literal __proto__ emits set_proto"` (`src/tests/parser.zig:2719`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: object literal __proto__ emits set_proto」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: object method shorthand emits define_method"` (`src/tests/parser.zig:2729`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: object method shorthand emits define_method」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: for-await close keeps body statement source location"` (`src/tests/parser.zig:2743`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: for-await close keeps body statement source location」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: the program root's scope marker and source authority are stream events"` (`src/tests/parser.zig:2802`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: the program root's scope marker and source authority are stream events」。
- **实现**：断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: computed object method emits define_method_computed"` (`src/tests/parser.zig:2831`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: computed object method emits define_method_computed」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: object string getter emits define_method getter flag"` (`src/tests/parser.zig:2841`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: object string getter emits define_method getter flag」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: object numeric setter emits define_method setter flag"` (`src/tests/parser.zig:2852`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: object numeric setter emits define_method setter flag」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: computed object getter emits define_method_computed getter flag"` (`src/tests/parser.zig:2863`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: computed object getter emits define_method_computed getter flag」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: computed object keys emit to_propkey before definition"` (`src/tests/parser.zig:2873`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: computed object keys emit to_propkey before definition」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: duplicate non-computed __proto__ data fields reject"` (`src/tests/parser.zig:2884`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: duplicate non-computed __proto__ data fields reject」。
- **实现**：断言错误 `error.UnexpectedToken`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: computed __proto__ duplicate is permitted"` (`src/tests/parser.zig:2891`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: computed __proto__ duplicate is permitted」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: computed object key accepts logical and assignment"` (`src/tests/parser.zig:2901`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: computed object key accepts logical and assignment」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: computed object key accepts logical or assignment"` (`src/tests/parser.zig:2911`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: computed object key accepts logical or assignment」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: computed object key accepts indexed logical assignment"` (`src/tests/parser.zig:2921`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: computed object key accepts indexed logical assignment」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: computed object key accepts nullish assignment"` (`src/tests/parser.zig:2932`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: computed object key accepts nullish assignment」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: simple call f(a, b) emits get_var ; args ; call argc"` (`src/tests/parser.zig:2942`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: simple call f(a, b) emits get_var ; args ; call argc」。
- **实现**：`parseExpr(&env, "f(a, b)")` 后 `expectOpcodeSequence` 比 `get_var ; get_var ; get_var ; call2`——callee 与两个实参各一次 `get_var`，argc=2 走快编码 `call2`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: zero-arg call f() emits call 0"` (`src/tests/parser.zig:2951`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: zero-arg call f() emits call 0」。
- **实现**：`parseExpr(&env, "f()")` 后 `expectOpcodeSequence` 比 `get_var ; call0`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: method call obj.m(x) uses get_field2 + call_method"` (`src/tests/parser.zig:2960`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: method call obj.m(x) uses get_field2 + call_method」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: get_length final fold consumes the ordinary length atom operand"` (`src/tests/parser.zig:2971`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: get_length final fold consumes the ordinary length atom operand」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: length call consumer preserves get_field2 and its atom operand"` (`src/tests/parser.zig:2981`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: length call consumer preserves get_field2 and its atom operand」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: indexed call obj[k](x) uses get_array_el2 + call_method"` (`src/tests/parser.zig:2993`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: indexed call obj[k](x) uses get_array_el2 + call_method」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: new X(a) emits get_var X ; dup ; get_var a ; call_constructor 1"` (`src/tests/parser.zig:3003`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: new X(a) emits get_var X ; dup ; get_var a ; call_constructor 1」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: bare new X (no args) emits call_constructor 0"` (`src/tests/parser.zig:3013`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: bare new X (no args) emits call_constructor 0」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: postfix x++ emits get_var ; post_inc ; put_var"` (`src/tests/parser.zig:3023`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: postfix x++ emits get_var ; post_inc ; put_var」。
- **实现**：`parseExpr(&env, "x++")` 后 `expectOpcodeSequence` 比 `get_var ; post_inc ; put_var`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: postfix x-- emits get_var ; post_dec ; put_var"` (`src/tests/parser.zig:3032`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: postfix x-- emits get_var ; post_dec ; put_var」。
- **实现**：`parseExpr(&env, "x--")` 后 `expectOpcodeSequence` 比 `get_var ; post_dec ; put_var`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: prefix ++x emits get_var ; inc ; dup ; put_var"` (`src/tests/parser.zig:3041`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: prefix ++x emits get_var ; inc ; dup ; put_var」。
- **实现**：`parseExpr(&env, "++x")` 后 `expectOpcodeSequence` 比 `get_var ; inc ; dup ; put_var`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: prefix --x emits get_var ; dec ; dup ; put_var"` (`src/tests/parser.zig:3050`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: prefix --x emits get_var ; dec ; dup ; put_var」。
- **实现**：`parseExpr(&env, "--x")` 后 `expectOpcodeSequence` 比 `get_var ; dec ; dup ; put_var`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: delete unresolvable identifier emits delete_var"` (`src/tests/parser.zig:3059`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: delete unresolvable identifier emits delete_var」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: delete a.b emits get_var a ; push_atom_value b ; delete"` (`src/tests/parser.zig:3069`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: delete a.b emits get_var a ; push_atom_value b ; delete」。
- **实现**：`parseExpr(&env, "delete a.b")` 后 `expectOpcodeSequence` 比 `get_var ; push_atom_value ; delete`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: delete of a private field is rejected after ordinary-field transport"` (`src/tests/parser.zig:3078`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: delete of a private field is rejected after ordinary-field transport」。
- **实现**：用 `expectError` 钉失败路径。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: delete a.b.length rewrites optimized length load"` (`src/tests/parser.zig:3088`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: delete a.b.length rewrites optimized length load」。
- **实现**：`parseExpr(&env, "delete a.b.length")` 后 `expectOpcodeSequence` 比 `get_var_field ; get_field ; push_atom_value ; delete`——末段 `length` 的优化加载被改写回 `push_atom_value ; delete`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: delete a[i] emits get_var a ; get_var i ; delete"` (`src/tests/parser.zig:3097`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: delete a[i] emits get_var a ; get_var i ; delete」。
- **实现**：`parseExpr(&env, "delete a[i]")` 后 `expectOpcodeSequence` 比 `get_var ; get_var ; delete`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: delete on a non-reference yields drop ; push_true"` (`src/tests/parser.zig:3106`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: delete on a non-reference yields drop ; push_true」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: chained call f(a)(b) emits two call ops"` (`src/tests/parser.zig:3117`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: chained call f(a)(b) emits two call ops」。
- **实现**：`parseExpr(&env, "f(a)(b)")` 后 `expectOpcodeSequence` 比 `get_var ; get_var ; call1 ; get_var ; call1`——两个 `call1`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: dotted assignment a.b = v emits get_var ; rhs ; insert2 ; put_field"` (`src/tests/parser.zig:3128`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: dotted assignment a.b = v emits get_var ; rhs ; insert2 ; put_field」。
- **实现**：`parseExpr(&env, "a.b = v")` 后 `expectOpcodeSequence` 比 `get_var ; get_var ; insert2 ; put_field`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: indexed assignment a[i] = v emits get_var ; key ; rhs ; insert3 ; put_array_el"` (`src/tests/parser.zig:3137`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: indexed assignment a[i] = v emits get_var ; key ; rhs ; insert3 ; put_array_el」。
- **实现**：`parseExpr(&env, "a[i] = v")` 后 `expectOpcodeSequence` 比 `get_var ; get_var ; get_var ; insert3 ; put_array_el`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: compound dotted assignment a.b += v rewrites get_field to get_field2"` (`src/tests/parser.zig:3146`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: compound dotted assignment a.b += v rewrites get_field to get_field2」。
- **实现**：`parseExpr(&env, "a.b += v")` 后 `expectOpcodeSequence` 比 `get_var ; get_field2 ; get_var ; add ; insert2 ; put_field`——读侧 `get_field` 被改写成留接收者的 `get_field2`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: compound indexed assignment a[i] += v keeps QuickJS indexed lvalue shape"` (`src/tests/parser.zig:3155`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: compound indexed assignment a[i] += v keeps QuickJS indexed lvalue shape」。
- **实现**：`parseExpr(&env, "a[i] += v")` 后 `expectOpcodeSequence` 比 `get_var ; get_var ; get_array_el3 ; get_var ; add ; insert3 ; put_array_el`——`get_array_el3` 就是 QuickJS 的索引 lvalue 读法。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: postfix dotted a.b++ emits get_field2 ; post_inc ; perm3 ; put_field"` (`src/tests/parser.zig:3164`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: postfix dotted a.b++ emits get_field2 ; post_inc ; perm3 ; put_field」。
- **实现**：`parseExpr(&env, "a.b++")` 后 `expectOpcodeSequence` 比 `get_var ; get_field2 ; post_inc ; perm3 ; put_field`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: postfix indexed a[i]-- emits QuickJS indexed lvalue read ; post_dec ; perm4 ; put_array_el"` (`src/tests/parser.zig:3173`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: postfix indexed a[i]-- emits QuickJS indexed lvalue read ; post_dec ; perm4 ; put_array_el」。
- **实现**：`parseExpr(&env, "a[i]--")` 后 `expectOpcodeSequence` 比 `get_var ; get_var ; get_array_el3 ; post_dec ; perm4 ; put_array_el`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: prefix ++a.b emits get_field2 ; inc ; insert2 ; put_field"` (`src/tests/parser.zig:3182`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: prefix ++a.b emits get_field2 ; inc ; insert2 ; put_field」。
- **实现**：`parseExpr(&env, "++a.b")` 后 `expectOpcodeSequence` 比 `get_var ; get_field2 ; inc ; insert2 ; put_field`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: prefix --a[i] emits QuickJS indexed lvalue read ; dec ; insert3 ; put_array_el"` (`src/tests/parser.zig:3191`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: prefix --a[i] emits QuickJS indexed lvalue read ; dec ; insert3 ; put_array_el」。
- **实现**：`parseExpr(&env, "--a[i]")` 后 `expectOpcodeSequence` 比 `get_var ; get_var ; get_array_el3 ; dec ; insert3 ; put_array_el`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: final bytecode applies QuickJS discarded lvalue and loop update peepholes"` (`src/tests/parser.zig:3200`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: final bytecode applies QuickJS discarded lvalue and loop update peepholes」。
- **实现**：断言 11 处 `std.testing.expect*`。约 11 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: local x++ and --x reach the canonical final inc_loc snapshots"` (`src/tests/parser.zig:3224`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: local x++ and --x reach the canonical final inc_loc snapshots」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: dotted assign value remains on stack via insert2 (chained)"` (`src/tests/parser.zig:3242`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: dotted assign value remains on stack via insert2 (chained)」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: array hole [1, , 3] emits sparse define_field for present elements"` (`src/tests/parser.zig:3255`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: array hole [1, , 3] emits sparse define_field for present elements」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: leading hole [, 1] emits sparse define_field at index 1"` (`src/tests/parser.zig:3266`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: leading hole [, 1] emits sparse define_field at index 1」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: consecutive holes [, , 1] emits sparse define_field at index 2"` (`src/tests/parser.zig:3277`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: consecutive holes [, , 1] emits sparse define_field at index 2」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: multi-level delete a.b.c rewrites only the last get_field"` (`src/tests/parser.zig:3288`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: multi-level delete a.b.c rewrites only the last get_field」。
- **实现**：`parseExpr(&env, "delete a.b.c")` 后 `expectOpcodeSequence` 比 `get_var_field ; get_field ; push_atom_value ; delete`——只有最后一段 `get_field` 被改写成 `push_atom_value ; delete`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: multi-level delete a.b[i] truncates the trailing get_array_el"` (`src/tests/parser.zig:3297`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: multi-level delete a.b[i] truncates the trailing get_array_el」。
- **实现**：`parseExpr(&env, "delete a.b[i]")` 后 `expectOpcodeSequence` 比 `get_var_field ; get_field ; get_var ; delete`——尾部 `get_array_el` 被截掉。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: delete on a postfix update result evaluates and returns true"` (`src/tests/parser.zig:3306`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: delete on a postfix update result evaluates and returns true」。
- **实现**：`parseExpr(&env, "delete (a.b++)")` 后 `expectOpcodeSequence` 比 `get_var ; get_field2 ; inc ; put_field ; push_true`——非引用结果仍走 discard + true，`post_inc ; perm3 ; put_field ; drop` 被 resolve_labels 折成 `inc ; put_field`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: optional chain a?.b emits inline chain_test + normal get_field"` (`src/tests/parser.zig:3324`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: optional chain a?.b emits inline chain_test + normal get_field」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: optional length value reaches the get_length final fold"` (`src/tests/parser.zig:3335`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: optional length value reaches the get_length final fold」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: optional length call consumer preserves get_field2 and its atom operand"` (`src/tests/parser.zig:3356`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: optional length call consumer preserves get_field2 and its atom operand」。
- **实现**：断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: optional chain a?.[i] emits inline chain_test + get_array_el"` (`src/tests/parser.zig:3380`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: optional chain a?.[i] emits inline chain_test + get_array_el」。
- **实现**：`parseExpr(&env, "a?.[i]")` 后 `expectOpcodeSequence` 比 `get_var ; dup ; is_undefined_or_null ; if_false8 ; drop ; undefined ; return_undef ; get_var ; get_array_el`——chain_test 是内联展开的 7 条。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: optional chain a?.b.c — chain test only at the ?. site"` (`src/tests/parser.zig:3389`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: optional chain a?.b.c — chain test only at the ?. site」。
- **实现**：`parseExpr(&env, "a?.b.c")` 后 `expectOpcodeSequence` 比 `get_var ; dup ; is_undefined_or_null ; if_false8 ; drop ; undefined ; return_undef ; get_field ; get_field`——只有 `?.` 处有一组 chain test，后续 `.c` 是普通 `get_field`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: a?.b?.c emits two chain_tests sharing a common chain exit"` (`src/tests/parser.zig:3398`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: a?.b?.c emits two chain_tests sharing a common chain exit」。
- **实现**：`parseExpr(&env, "a?.b?.c")` 后 `expectOpcodeSequence` 比两组 `dup ; is_undefined_or_null ; if_false8 ; drop ; undefined ; return_undef`（分别跟在 `get_var` 和 `get_field` 后）再加末尾 `get_field`——两次 chain test 共用同一个链出口。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: optional call a?.() emits chain_test + plain call"` (`src/tests/parser.zig:3411`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: optional call a?.() emits chain_test + plain call」。
- **实现**：`parseExpr(&env, "a?.()")` 后 `expectOpcodeSequence` 比 `get_var ; dup ; is_undefined_or_null ; if_false8 ; drop ; undefined ; return_undef ; call0`——链测试后是普通调用。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: method-on-opt-chain obj?.b(x) uses get_field2 + call_method"` (`src/tests/parser.zig:3420`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: method-on-opt-chain obj?.b(x) uses get_field2 + call_method」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: parenthesized optional member call preserves receiver"` (`src/tests/parser.zig:3430`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: parenthesized optional member call preserves receiver」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: optional call after parenthesized optional member keeps balanced exits"` (`src/tests/parser.zig:3454`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: optional call after parenthesized optional member keeps balanced exits」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: optional chain accepts keyword property names"` (`src/tests/parser.zig:3483`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: optional chain accepts keyword property names」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: indexed-call-on-opt-chain obj?.[k](x) uses get_array_el2 + call_method"` (`src/tests/parser.zig:3499`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: indexed-call-on-opt-chain obj?.[k](x) uses get_array_el2 + call_method」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: tagged template tag`hello` emits singleton template-object + call 1"` (`src/tests/parser.zig:3468`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: tagged template tag`hello` emits singleton template-object + call 1」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: tagged template tag`a${x}b` includes substitutions in argc"` (`src/tests/parser.zig:3479`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: tagged template tag`a${x}b` includes substitutions in argc」。
- **实现**：按测试名构造最小输入并断言引擎可观察结果。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: tagged template on member access obj.tag`hello` rewrites to call_method"` (`src/tests/parser.zig:3488`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: tagged template on member access obj.tag`hello` rewrites to call_method」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "call-site cache: every final call instruction carries a cache_idx and the function owns one slot per site"` (`src/tests/parser.zig:3543`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「call-site cache: every final call instruction carries a cache_idx and the function owns one slot per site」。
- **实现**：断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "call-site cache: sites past the 255-slot budget carry the no-cache index"` (`src/tests/parser.zig:3588`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「call-site cache: sites past the 255-slot budget carry the no-cache index」。
- **实现**：断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "prop-site cache: every final field instruction carries a cache_idx and the function owns one slot per site"` (`src/tests/parser.zig:3623`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「prop-site cache: every final field instruction carries a cache_idx and the function owns one slot per site」。
- **实现**：断言 13 处 `std.testing.expect*`。约 13 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "prop-site cache: sites past the 255-slot budget carry the no-cache index"` (`src/tests/parser.zig:3670`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「prop-site cache: sites past the 255-slot budget carry the no-cache index」。
- **实现**：断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: tagged template tag`a${x}b${y}c` argc = 3 (template + 2 subs)"` (`src/tests/parser.zig:3662`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: tagged template tag`a${x}b${y}c` argc = 3 (template + 2 subs)」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: optional call without chain receiver a?.()(b) — chain only on first call"` (`src/tests/parser.zig:3715`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: optional call without chain receiver a?.()(b) — chain only on first call」。
- **实现**：`parseExpr(&env, "a?.()(b)")` 后 `expectOpcodeSequence` 比 `get_var ; dup ; is_undefined_or_null ; if_false8 ; drop ; undefined ; return_undef ; call0 ; get_var ; call1`——`a?.()` 之后链结束，尾随的 `(b)` 是无条件调用。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: no-substitution template `hello` lowers to push_atom_value"` (`src/tests/parser.zig:3684`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: no-substitution template `hello` lowers to push_atom_value」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: empty template `` lowers to push_empty_string"` (`src/tests/parser.zig:3694`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: empty template `` lowers to push_empty_string」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: simple template with one substitution uses get_field2 concat + call_method"` (`src/tests/parser.zig:3747`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: simple template with one substitution uses get_field2 concat + call_method」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: returned interpolated template carries QuickJS tail-call source provenance"` (`src/tests/parser.zig:3757`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: returned interpolated template carries QuickJS tail-call source provenance」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: empty-head template `${b}` skips middle/tail empty strings"` (`src/tests/parser.zig:3741`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: empty-head template `${b}` skips middle/tail empty strings」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: template with two substitutions accumulates argc correctly"` (`src/tests/parser.zig:3801`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: template with two substitutions accumulates argc correctly」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: spread call f(...x) emits array_from + apply 0"` (`src/tests/parser.zig:3821`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: spread call f(...x) emits array_from + apply 0」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: mixed spread call f(a, ...b) starts array_from with leading count"` (`src/tests/parser.zig:3831`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: mixed spread call f(a, ...b) starts array_from with leading count」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: trailing element after spread uses define_array_el + inc"` (`src/tests/parser.zig:3842`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: trailing element after spread uses define_array_el + inc」。
- **实现**：`parseExpr(&env, "f(...a, b)")` 后 `expectOpcodeSequence` 比 `get_var ; array_from ; push_0 ; get_var ; append ; get_var ; define_array_el ; inc ; drop ; undefined ; swap ; apply`——spread 之后的定位元素用 `define_array_el ; inc` 续写下标。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: method call with spread obj.m(...x) uses perm3 + apply 0"` (`src/tests/parser.zig:3864`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: method call with spread obj.m(...x) uses perm3 + apply 0」。
- **实现**：`parseExpr(&env, "obj.m(...x)")` 后 `expectOpcodeSequence` 比 `get_var ; get_field2 ; array_from ; push_0 ; get_var ; append ; drop ; perm3 ; apply`——`perm3` 把接收者转到 `apply` 需要的位置。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: new with spread new X(...args) uses apply with is_new=1"` (`src/tests/parser.zig:3883`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: new with spread new X(...args) uses apply with is_new=1」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: array literal spread [...a] starts with array_from 0 + push_i32 0"` (`src/tests/parser.zig:3894`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: array literal spread [...a] starts with array_from 0 + push_i32 0」。
- **实现**：`parseExpr(&env, "[...a]")` 后 `expectOpcodeSequence` 比 `array_from ; push_0 ; get_var ; append ; ext0 ; put_field`——收尾用载体指令（`ext0`）回写 `length`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: array literal mixed spread [a, ...b, c] uses define_array_el+inc"` (`src/tests/parser.zig:3903`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: array literal mixed spread [a, ...b, c] uses define_array_el+inc」。
- **实现**：`parseExpr(&env, "[a, ...b, c]")` 后 `expectOpcodeSequence` 比 `get_var ; array_from ; push_1 ; get_var ; append ; get_var ; define_array_el ; inc ; ext0 ; put_field`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F4: template with empty middle still emits call_method with correct argc"` (`src/tests/parser.zig:3912`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F4: template with empty middle still emits call_method with correct argc」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: empty statement"` (`src/tests/parser.zig:3931`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: empty statement」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: block statement folds only the final expression discard"` (`src/tests/parser.zig:3940`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: block statement folds only the final expression discard」。
- **实现**：`parseStatement(&env, "{ x; y; }")` 后 `expectOpcodeSequence` 比 `get_var ; drop ; get_var`——只有最后一条表达式语句的 `drop` 被折进终结符。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: return statement without value"` (`src/tests/parser.zig:3949`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: return statement without value」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: return statement with value"` (`src/tests/parser.zig:3959`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: return statement with value」。
- **实现**：`parseFunctionBodyStatement(&env, "return x;")` 后 `expectOpcodeSequence` 比 `get_var ; return`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: return comma and conditional expressions follow terminal goto folding"` (`src/tests/parser.zig:3968`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: return comma and conditional expressions follow terminal goto folding」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: return conditional expression folds the then goto to a plain return"` (`src/tests/parser.zig:3990`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: return conditional expression folds the then goto to a plain return」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: strict return call folds to tail_call plus return; sloppy stays call"` (`src/tests/parser.zig:4003`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: strict return call folds to tail_call plus return; sloppy stays call」。
- **实现**：断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: return method call folds to tail_call_method plus return"` (`src/tests/parser.zig:4023`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: return method call folds to tail_call_method plus return」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: throw statement"` (`src/tests/parser.zig:4044`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: throw statement」。
- **实现**：`parseStatement(&env, "throw x;")` 后 `expectOpcodeSequence` 比 `get_var ; throw`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: if statement without else"` (`src/tests/parser.zig:4053`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: if statement without else」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: constant test conditions reach the final QuickJS fold"` (`src/tests/parser.zig:4064`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: constant test conditions reach the final QuickJS fold」。
- **实现**：6 条 `{ 源文, 期望序列 }` 用例逐条 `parseStatement` + `expectOpcodeSequence`：`if (true) x;` 与 `if (1) x;` → `get_var ; drop`；`if (false) x;`、`if (null) x;`、`if (0) x;`、`if (void 0) x;` → 空序列（整条语句被常量折掉）。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "W5: constant tests prune only the QuickJS-selected control-flow arm"` (`src/tests/parser.zig:4086`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「W5: constant tests prune only the QuickJS-selected control-flow arm」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: if statement with else"` (`src/tests/parser.zig:4130`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: if statement with else」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "W5: final branches normalize at QuickJS instruction boundaries"` (`src/tests/parser.zig:4141`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「W5: final branches normalize at QuickJS instruction boundaries」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "W5: production with atom-label target threads past destructuring fallback goto"` (`src/tests/parser.zig:4202`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「W5: production with atom-label target threads past destructuring fallback goto」。
- **实现**：断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: while statement"` (`src/tests/parser.zig:4254`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: while statement」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: do-while statement"` (`src/tests/parser.zig:4270`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: do-while statement」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: for update moves optional chain code with atom operands"` (`src/tests/parser.zig:4280`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: for update moves optional chain code with atom operands」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: final expression statement discard folds into the terminator"` (`src/tests/parser.zig:4289`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: final expression statement discard folds into the terminator」。
- **实现**：`parseStatement(&env, "x;")` 后 `expectOpcodeSequence` 比单条 `get_var`——尾部表达式语句的 `drop` 被折进终结符。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "W5: numeric discarded immediates respect statement and completion boundaries"` (`src/tests/parser.zig:4298`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「W5: numeric discarded immediates respect statement and completion boundaries」。
- **实现**：断言 17 处 `std.testing.expect*`。约 17 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "W5: tagged-int numeric strings use cpool without changing other string producers"` (`src/tests/parser.zig:4393`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「W5: tagged-int numeric strings use cpool without changing other string producers」。
- **实现**：断言 25 处 `std.testing.expect*`。约 25 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "W5: string discard follows QuickJS atom and completion boundaries"` (`src/tests/parser.zig:4479`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「W5: string discard follows QuickJS atom and completion boundaries」。
- **实现**：用 `ParserTestEnv` 把一串字符串/模板输入（`""`、`"123"`、`` `456` ``、`` `` ``、`"hello"`、`/(?:)/`，以及 stringTemplate/stringConcat/stringSymbol/stringEval 四函数的 script 和 `return_completion`、module 两种根）各编一遍，逐个比 `push_atom_value`/`push_const`/`drop` 计数与末尾终结符。约 44 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: labelled break crossing switch drops discriminant"` (`src/tests/parser.zig:4608`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: labelled break crossing switch drops discriminant」。
- **实现**：用 `ParserTestEnv` 把两条同形源文（`loop: for(;;){ switch(x){ default: break loop; } }` 的普通函数版与 `function*` 版）各过一次 `parseStatementWithTopLevelChildren` 就地释放；本例没有显式 expect，钉的是「跨 switch 的带标签 break 能编完」——`finalize` 里的 `compute_stack_size` 会把栈欠载/同 pc 不同栈深判成 `error.StackUnderflow`/`error.StackMismatch`，所以 `try` 本身就是断言。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: switch CaseBlock does not treat a function expression name as a declaration"` (`src/tests/parser.zig:4622`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：F5: switch CaseBlock does not treat a function expression name as a declaration。
- **实现**：用 `expectError` 钉失败路径。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: labelled break to loop inside switch keeps discriminant stack balanced"` (`src/tests/parser.zig:4640`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: labelled break to loop inside switch keeps discriminant stack balanced」。
- **实现**：用 `ParserTestEnv` 把一个含 `switch`、`outer: do{...}while(0)` 与内层 `loop: while(true)`（两处 `break loop`）的函数源文过一次 `parseStatementWithTopLevelChildren`；无显式 expect，钉「能编完」：判别值若漏丢，`finalize` 的 `compute_stack_size` 会以 `error.StackUnderflow`/`error.StackMismatch` 失败。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: labelled continue inside switch case keeps discriminant stack balanced"` (`src/tests/parser.zig:4671`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: labelled continue inside switch case keeps discriminant stack balanced」。
- **实现**：用 `ParserTestEnv` 编一个 `while` 循环后接 `switch(b)`、`case 1:` 里是 `M: while(true){ if(a) break; continue M; }` 的函数；无显式 expect，钉「带标签 continue 落在 case 内时能编完」：判别值失衡会被 `finalize` 的 `compute_stack_size` 判错。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: labelled continue from nested loop inside switch drops discriminant once"` (`src/tests/parser.zig:4688`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: labelled continue from nested loop inside switch drops discriminant once」。
- **实现**：用 `ParserTestEnv` 编 `outer: while(true){ switch(b){ case 1: while(true){ if(a) continue outer; break; } } break; }`；无显式 expect，钉「从 switch 内嵌套循环 continue 到外层标签时判别值恰好丢一次」——多丢或少丢都会让 `finalize` 的 `compute_stack_size` 返回 `error.StackUnderflow`/`error.StackMismatch`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: var declaration without initializer"` (`src/tests/parser.zig:4709`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: var declaration without initializer」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: var declaration with initializer"` (`src/tests/parser.zig:4720`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: var declaration with initializer」。
- **实现**：断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: sloppy var initializer captures dynamic reference before RHS"` (`src/tests/parser.zig:4735`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: sloppy var initializer captures dynamic reference before RHS」。
- **实现**：断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: destructuring dynamic reference publishes an exact long-tail label"` (`src/tests/parser.zig:4787`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: destructuring dynamic reference publishes an exact long-tail label」。
- **实现**：断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: module-ref var initializer consumes value unless next statement reuses binding"` (`src/tests/parser.zig:4852`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: module-ref var initializer consumes value unless next statement reuses binding」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: module-ref var initializer preserves value for immediate same-name expression"` (`src/tests/parser.zig:4863`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: module-ref var initializer preserves value for immediate same-name expression」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: let declaration"` (`src/tests/parser.zig:4874`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: let declaration」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: let declaration with initializer"` (`src/tests/parser.zig:4890`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: let declaration with initializer」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: const declaration without initializer should fail"` (`src/tests/parser.zig:4903`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: const declaration without initializer should fail」。
- **实现**：断言错误 `error.UnexpectedToken`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: const declaration with initializer"` (`src/tests/parser.zig:4909`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: const declaration with initializer」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: multiple var declarations"` (`src/tests/parser.zig:4924`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: multiple var declarations」。
- **实现**：断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: directive prologue with 'use strict'"` (`src/tests/parser.zig:4940`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: directive prologue with 'use strict'」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M3.1 F4: strict object setter rejects eval and arguments parameters"` (`src/tests/parser.zig:4951`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M3.1 F4: strict object setter rejects eval and arguments parameters」。
- **实现**：断言错误 `error.UnexpectedToken`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: directive prologue with multiple directives"` (`src/tests/parser.zig:4959`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: directive prologue with multiple directives」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F5: directive prologue with ASI"` (`src/tests/parser.zig:4970`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F5: directive prologue with ASI」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F6: simple function declaration"` (`src/tests/parser.zig:4983`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F6: simple function declaration」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F6: line_num before explicit return does not add implicit return"` (`src/tests/parser.zig:4997`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：F6: line_num before explicit return does not add implicit return。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F6: function declaration with parameters"` (`src/tests/parser.zig:5013`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F6: function declaration with parameters」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F6: var redeclaration of parameter keeps closure bound to arg"` (`src/tests/parser.zig:5028`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F6: var redeclaration of parameter keeps closure bound to arg」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F6: function declaration with rest parameter"` (`src/tests/parser.zig:5038`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F6: function declaration with rest parameter」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F6: arrow function with block body"` (`src/tests/parser.zig:5053`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F6: arrow function with block body」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F6: arrow function with expression body"` (`src/tests/parser.zig:5066`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F6: arrow function with expression body」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F6: arrow function with single parameter"` (`src/tests/parser.zig:5080`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F6: arrow function with single parameter」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F6: identifier arrow lookahead preserves trivia and line terminators"` (`src/tests/parser.zig:5095`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F6: identifier arrow lookahead preserves trivia and line terminators」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F6: parenthesized arrow lookahead skips only context-free source"` (`src/tests/parser.zig:5143`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F6: parenthesized arrow lookahead skips only context-free source」。
- **实现**：断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F6: assignment-entry arrow dispatch preserves primary-expression boundaries"` (`src/tests/parser.zig:5205`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F6: assignment-entry arrow dispatch preserves primary-expression boundaries」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F6: arrow function with multiple parameters"` (`src/tests/parser.zig:5239`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F6: arrow function with multiple parameters」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F6: arrow function with rest parameter"` (`src/tests/parser.zig:5257`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F6: arrow function with rest parameter」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F6: function with object destructuring parameter"` (`src/tests/parser.zig:5272`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F6: function with object destructuring parameter」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F6: function with array destructuring parameter"` (`src/tests/parser.zig:5286`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F6: function with array destructuring parameter」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F6: arrow function with object destructuring parameter"` (`src/tests/parser.zig:5300`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F6: arrow function with object destructuring parameter」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F6: arrow function with array destructuring parameter"` (`src/tests/parser.zig:5315`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F6: arrow function with array destructuring parameter」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F6: direct shorthand destructuring bindings use get_field2"` (`src/tests/parser.zig:5330`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F6: direct shorthand destructuring bindings use get_field2」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F7: class with constructor"` (`src/tests/parser.zig:5343`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: class with constructor」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F7: default class constructors use canonical entry gates"` (`src/tests/parser.zig:5360`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: default class constructors use canonical entry gates」。
- **实现**：断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F7: static field initializer is a synthetic child called with the class receiver"` (`src/tests/parser.zig:5379`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: static field initializer is a synthetic child called with the class receiver」。
- **实现**：断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F7: static field direct eval uses the synthetic child lexical scope"` (`src/tests/parser.zig:5434`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: static field direct eval uses the synthetic child lexical scope」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F7: computed static fields and blocks share one ordered synthetic initializer"` (`src/tests/parser.zig:5464`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: computed static fields and blocks share one ordered synthetic initializer」。
- **实现**：断言 15 处 `std.testing.expect*`。约 15 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F7: class with getter"` (`src/tests/parser.zig:5539`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: class with getter」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F7: class with setter"` (`src/tests/parser.zig:5554`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: class with setter」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F7: class field ASI before generator method"` (`src/tests/parser.zig:5569`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: class field ASI before generator method」。
- **实现**：断言错误 `error.UnexpectedToken`。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F7: super keyword in class method"` (`src/tests/parser.zig:5604`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: super keyword in class method」。
- **实现**：用 `ParserTestEnv` 编 `class C { m() { super.x(); } }`，顶层 `expectOpcode` 查 `op.define_class`、`op.define_method`，再用 `expectOpcodeRecursive` 在子函数里查 `op.get_super`、`op.call_method`。4 处助手断言（助手内部才是 `std.testing.expect`）。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F7: super property access"` (`src/tests/parser.zig:5616`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: super property access」。
- **实现**：用 `ParserTestEnv` 编 `class C { m() { return super.x; } }`，顶层查 `op.define_class`、`op.define_method`，递归查 `op.get_super_value` 与 `op.@"return"`。4 处助手断言。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F7: super() constructor call"` (`src/tests/parser.zig:5628`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: super() constructor call」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F7: explicit derived this uses local check and return fallback uses caller check"` (`src/tests/parser.zig:5645`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: explicit derived this uses local check and return fallback uses caller check」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F7: super() rejected in base constructor"` (`src/tests/parser.zig:5660`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: super() rejected in base constructor」。
- **实现**：断言错误 `error.UnexpectedToken`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F9: yield expression"` (`src/tests/parser.zig:5667`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F9: yield expression」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "W5: generator parameter boundary emits initial_yield in scripts and modules"` (`src/tests/parser.zig:5680`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「W5: generator parameter boundary emits initial_yield in scripts and modules」。
- **实现**：断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F9: yield* expression"` (`src/tests/parser.zig:5717`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F9: yield* expression」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F8: export default statement"` (`src/tests/parser.zig:5732`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F8: export default statement」。
- **实现**：用 `parseModuleStatement` 编 `export default 42;`，`moduleRecord` 取出模块记录后 `expectModuleRecordCounts(record, 0, 0, 1, 0, 0)`（requests/imports/exports/indirect/star），再 `expectModuleExport` 校验第 0 条导出为 `default` ← 本地名 `*default*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F8: export named statement"` (`src/tests/parser.zig:5743`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F8: export named statement」。
- **实现**：`parseModuleStatement` 编 `export { x, y };`，计数 `(0, 0, 2, 0, 0)`，两条 `expectModuleExport` 分别钉 `x`←`x`、`y`←`y`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F7: private field in class"` (`src/tests/parser.zig:5755`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: private field in class」。
- **实现**：用 `ParserTestEnv` 编 `class C { #x; }`，顶层 `expectOpcode` 查 `op.define_class`，递归查 `op.private_symbol` 与 `op.define_private_field`。3 处助手断言。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "assignment inferred class name is embedded before static initialization"` (`src/tests/parser.zig:5766`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「assignment inferred class name is embedded before static initialization」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "computed property class name is embedded before static initialization"` (`src/tests/parser.zig:5782`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「computed property class name is embedded before static initialization」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "class field inferred names are embedded before static initialization"` (`src/tests/parser.zig:5798`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「class field inferred names are embedded before static initialization」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "comma expression does not infer an anonymous class name"` (`src/tests/parser.zig:5815`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：comma expression does not infer an anonymous class name。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "inferred function names do not become named-expression self bindings"` (`src/tests/parser.zig:5835`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「inferred function names do not become named-expression self bindings」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "W1d: finalized private operations have no raw private atom operands"` (`src/tests/parser.zig:5853`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「W1d: finalized private operations have no raw private atom operands」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 13 处 `std.testing.expect*`。约 13 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "F7: private method in class"` (`src/tests/parser.zig:5971`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: private method in class」。
- **实现**：用 `ParserTestEnv` 编 `class C { #m() {} }`，顶层查 `op.define_class`，递归查 `op.set_home_object`、`op.add_brand`（私有方法需要实例 brand）。3 处助手断言。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F7: private getter in class"` (`src/tests/parser.zig:5982`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: private getter in class」。
- **实现**：用 `ParserTestEnv` 编 `class C { get #x() { return this._x; } }`，顶层查 `op.define_class`，递归查 `op.set_home_object`、`op.add_brand`。3 处助手断言。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F7: private setter in class"` (`src/tests/parser.zig:5993`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: private setter in class」。
- **实现**：用 `ParserTestEnv` 编 `class C { set #x(value) { this._x = value; } }`，顶层查 `op.define_class`，递归查 `op.set_home_object`、`op.add_brand`。3 处助手断言。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F7: paired private accessor shares one instance brand prologue"` (`src/tests/parser.zig:6004`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: paired private accessor shares one instance brand prologue」。
- **实现**：用 `ParserTestEnv` 编同名私有 getter+setter 成对的 `class C { get #x() {...} set #x(value) {...} }`；`op.define_class` 顶层、`op.set_home_object` 递归仍是存在性查，`op.add_brand` 改成 `countOpcodeRecursive(...) == 1`——测试名断言的是「一对访问器共用一次 brand 序幕」，原来的存在性查在各发一次时也会绿。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F7: private name in uses scope temp before resolver"` (`src/tests/parser.zig:6022`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: private name in uses scope temp before resolver」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "unresolved descendant lookup threads direct eval var objects inside-out"` (`src/tests/parser.zig:6050`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「unresolved descendant lookup threads direct eval var objects inside-out」。
- **实现**：断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "direct eval pseudo var objects follow eval and parameter-expression gates"` (`src/tests/parser.zig:6116`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「direct eval pseudo var objects follow eval and parameter-expression gates」。
- **实现**：断言 14 处 `std.testing.expect*`。约 14 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "parameter pre-scan balances regexp and template delimiters like QuickJS"` (`src/tests/parser.zig:6169`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「parameter pre-scan balances regexp and template delimiters like QuickJS」。
- **实现**：不走 `parseStatement` 助手，手工 `internAtom` + `Bytecode.init` + `QjsLexer.init` + `ParseState.initWithRuntime`，打开 `state.top_level_functions_as_children` 后直接调 `parser_core.parseProgramStatements`；源文的参数默认值里塞了 `/[)=}]/` 正则与 `` `x${/[}]/.test("}")}` `` 模板。断言 3 处 `std.testing.expect*`：`child_list.len == 2`，且两个子函数的 `has_parameter_expressions` 都为真。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "parameter initializer direct eval emits active global-declaration carriers"` (`src/tests/parser.zig:6191`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「parameter initializer direct eval emits active global-declaration carriers」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "nested direct eval does not capture a parent global declaration carrier"` (`src/tests/parser.zig:6232`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：nested direct eval does not capture a parent global declaration carrier。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "F7: class with extends (derived constructor)"` (`src/tests/parser.zig:6255`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: class with extends (derived constructor)」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F7: class without extends (base constructor)"` (`src/tests/parser.zig:6265`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F7: class without extends (base constructor)」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F8: basic import statement"` (`src/tests/parser.zig:6275`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F8: basic import statement」。
- **实现**：`parseModuleStatement` 编 `import x from 'module'`，计数 `(1, 1, 0, 0, 0)`，`expectModuleRequest` 钉请求名 `module`，`expectModuleImport` 钉第 0 条导入 request_index 0、`default` → 本地 `x`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F8: side-effect import"` (`src/tests/parser.zig:6287`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F8: side-effect import」。
- **实现**：`parseModuleStatement` 编纯副作用 `import 'module'`，计数 `(1, 0, 0, 0, 0)`——只有一条 request、零导入条目，`expectModuleRequest` 钉请求名 `module`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F8: named imports"` (`src/tests/parser.zig:6298`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F8: named imports」。
- **实现**：`parseModuleStatement` 编 `import { x, y } from 'module'`，计数 `(1, 2, 0, 0, 0)`，一条 request `module`，两条导入 `x`→`x`、`y`→`y`（request_index 均为 0）。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F8: renamed imports"` (`src/tests/parser.zig:6311`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F8: renamed imports」。
- **实现**：`parseModuleStatement` 编 `import { x as a, y as b } from 'module'`，计数 `(1, 2, 0, 0, 0)`，两条导入钉「导入名 → 本地名」为 `x`→`a`、`y`→`b`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F8: namespace import"` (`src/tests/parser.zig:6324`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F8: namespace import」。
- **实现**：`parseModuleStatement` 编 `import * as ns from 'module'`，计数 `(1, 1, 0, 0, 0)`，唯一导入条目的导入名是 `*`、本地名 `ns`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F8: mixed import"` (`src/tests/parser.zig:6336`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F8: mixed import」。
- **实现**：`parseModuleStatement` 编 `import x, { y } from 'module'`，计数 `(1, 2, 0, 0, 0)`，两条导入按源序为 `default`→`x`、`y`→`y`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F8: export named"` (`src/tests/parser.zig:6349`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F8: export named」。
- **实现**：`parseModuleStatement` 编不带分号的 `export { x, y }`，计数 `(0, 0, 2, 0, 0)`，两条本地导出 `x`←`x`、`y`←`y`（无 request）。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F8: export renamed"` (`src/tests/parser.zig:6361`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F8: export renamed」。
- **实现**：`parseModuleStatement` 编 `export { x as a, y as b }`，计数 `(0, 0, 2, 0, 0)`，`expectModuleExport` 的两条为导出名 `a`←本地 `x`、`b`←本地 `y`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F8: export default expression"` (`src/tests/parser.zig:6373`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F8: export default expression」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F8: export default function"` (`src/tests/parser.zig:6387`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F8: export default function」。
- **实现**：`parseModuleStatement` 编 `export default function f() {}`，计数 `(0, 0, 1, 0, 0)`，唯一导出是 `default`←本地 `f`（具名默认函数保留函数名做本地名）。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "anonymous default function uses a star-default global function carrier"` (`src/tests/parser.zig:6398`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「anonymous default function uses a star-default global function carrier」。
- **实现**：断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F8: export default class"` (`src/tests/parser.zig:6436`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F8: export default class」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "anonymous default class uses the lexical star-default carrier"` (`src/tests/parser.zig:6450`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「anonymous default class uses the lexical star-default carrier」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F8: export star"` (`src/tests/parser.zig:6464`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F8: export star」。
- **实现**：`parseModuleStatement` 编 `export * from 'module'`，计数 `(1, 0, 0, 0, 1)`——落在 star_exports 而非 exports；`expectModuleRequest` 钉 `module`，`expectModuleStarExport` 钉 request_index 0、导出名 `*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F8: export star as namespace"` (`src/tests/parser.zig:6476`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F8: export star as namespace」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F8: export from"` (`src/tests/parser.zig:6489`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F8: export from」。
- **实现**：`parseModuleStatement` 编 `export { x, y } from 'module'`，计数 `(1, 0, 0, 2, 0)`——两条落在 indirect_exports；`expectModuleIndirectExport` 钉 request_index 0、导出名/导入名各为 `x`/`x` 与 `y`/`y`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F8: export const"` (`src/tests/parser.zig:6502`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F8: export const」。
- **实现**：`parseModuleStatement` 编 `export const x = 1`，计数 `(0, 0, 1, 0, 0)`，唯一导出 `x`←`x`。测试名原写作 `export var`，与源文不符，已改实；真正的 `export var` 形态（VarDef 类别不同）当前仍无覆盖。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F8: export function"` (`src/tests/parser.zig:6513`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F8: export function」。
- **实现**：`parseModuleStatement` 编 `export function f() {}`，计数 `(0, 0, 1, 0, 0)`，唯一导出 `f`←`f`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F8: export class"` (`src/tests/parser.zig:6524`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F8: export class」。
- **实现**：`parseModuleStatement` 编 `export class C {}`，计数 `(0, 0, 1, 0, 0)`，唯一导出 `C`←`C`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F9: async function expression"` (`src/tests/parser.zig:6537`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F9: async function expression」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F9: async arrow function"` (`src/tests/parser.zig:6549`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F9: async arrow function」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F9: async function declaration"` (`src/tests/parser.zig:6561`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F9: async function declaration」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F9: async function declaration with parameters"` (`src/tests/parser.zig:6573`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F9: async function declaration with parameters」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F9: async function declaration with body"` (`src/tests/parser.zig:6586`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F9: async function declaration with body」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F9: yield outside generator error"` (`src/tests/parser.zig:6598`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F9: yield outside generator error」。
- **实现**：断言错误 `error.YieldOutsideGenerator`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F9: await outside async function error"` (`src/tests/parser.zig:6605`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F9: await outside async function error」。
- **实现**：断言错误 `error.AwaitOutsideAsyncFunction`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F9: await inside async function no error"` (`src/tests/parser.zig:6612`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F9: await inside async function no error」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "Object literal: computed property name"` (`src/tests/parser.zig:6626`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Object literal: computed property name」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "Object literal: method shorthand"` (`src/tests/parser.zig:6637`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Object literal: method shorthand」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "Object literal: spread"` (`src/tests/parser.zig:6647`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Object literal: spread」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "Object literal: get/set shorthand is accepted"` (`src/tests/parser.zig:6657`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「Object literal: get/set shorthand is accepted」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "async arrow accepts sloppy context-keyword binding identifiers"` (`src/tests/parser.zig:6677`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「async arrow accepts sloppy context-keyword binding identifiers」。
- **实现**：用 `ParserTestEnv` 把 16 条应当接受的源文各 `parseStatement` 一遍（`async yield/let/static/implements/interface/package/private/protected/public/x/of/async => 1`、无 async 的 `yield/static/let => 1`、以及 `async (yield) => 1`），最后用 `expectParseStatementError` 钉唯一的负例 `var f = async await => 1;`（+Await 下 `await` 不能作 AsyncArrowBindingIdentifier）。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "for-in/of var binding rejects yield in generators and await in async"` (`src/tests/parser.zig:6708`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「for-in/of var binding rejects yield in generators and await in async」。
- **实现**：7 条 `expectParseStatementError` 钉拒绝面（generator 里 `for (var yield of/in ...)`、async 与 async generator 里 `for (var await of [1])`、`for (var yield = 1 in {a:1})`、以及 `function* g(){ var yield; }`、`async function f(){ var await; }`），再用两次 `parseStatement` 钉 sloppy 顶层的 `for (var yield of/in ...)` 必须编译通过。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "switch case after while-family still emits a fallthrough skip-goto"` (`src/tests/parser.zig:6726`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「switch case after while-family still emits a fallthrough skip-goto」。
- **实现**：用 `ParserTestEnv` 把 6 条 `switch` 源文（case 体分别是 `while(true){break;}`、`while(1)break;`、带标签 `lbl:while(true){break lbl;}`、`for(;;){break;}`、`do{break;}while(0)`、`if(false) break; y();`）各 `parseStatement` 一遍；无显式 expect，钉「case 收尾仍能编出穿透跳转」：跳转与判别值不匹配会被 `finalize` 的 `compute_stack_size` 判错。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "escapedIdentifier reserved-word CurrentContext shares the Binding walk"` (`src/tests/parser.zig:6889`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「escapedIdentifier reserved-word CurrentContext shares the Binding walk」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "emitterOpU16 and NoSource share the u16 opcode walk"` (`src/tests/parser.zig:6905`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「emitterOpU16 and NoSource share the u16 opcode walk」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "emitterPushConst and Owned share the cpool patch walk"` (`src/tests/parser.zig:6921`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「emitterPushConst and Owned share the cpool patch walk」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "emitterOp NoSource and At share the plain opcode walk"` (`src/tests/parser.zig:6938`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「emitterOp NoSource and At share the plain opcode walk」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "emitScope var wrappers keep phase-1 opcode pairs"` (`src/tests/parser.zig:6954`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「emitScope var wrappers keep phase-1 opcode pairs」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M-SCOPE event producers: ordinary scopes match QuickJS phase-1 events"` (`src/tests/parser.zig:6980`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M-SCOPE event producers: ordinary scopes match QuickJS phase-1 events」。
- **实现**：6 组 `parseRawStatement` + `expectPhase1ScopeEvents` 逐组比对 phase-1 的 enter/leave 事件序列：`{}` 只有 enter 1；`{;}` 与 `if (true) ;` 是 enter 1 / enter 2 / leave 2；`for (;;) ;` 多一次 leave 2；`for (let i = 0;;) ;` 与 `for (let value of [])`/`for (let key in {})` 则是 enter 1 / enter 2 + 三次 leave 2。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M-SCOPE event producers: switch with and class layers are eventful"` (`src/tests/parser.zig:7046`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M-SCOPE event producers: switch with and class layers are eventful」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M-SCOPE event producers: catch binding wrapper and body leave in LIFO order"` (`src/tests/parser.zig:7101`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M-SCOPE event producers: catch binding wrapper and body leave in LIFO order」。
- **实现**：3 组 `parseRawStatement` + `expectPhase1ScopeEvents`：`try {} catch (caught) {;}` 期望 enter 1/2/3/4 后按 4→3→2 的 LIFO leave；`try {} catch (caught) {}`（空 catch 体）不产生第 4 层；带 `finally {;}` 的一组在 catch 收尾后再追加 enter 5 / leave 5。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M-SCOPE event producers: structural body and namespace scopes stay identity-only"` (`src/tests/parser.zig:7146`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M-SCOPE event producers: structural body and namespace scopes stay identity-only」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M-SCOPE abrupt control: labelled break and continue close nested scopes at the source"` (`src/tests/parser.zig:7215`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M-SCOPE abrupt control: labelled break and continue close nested scopes at the source」。
- **实现**：断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M-SCOPE abrupt control: classic and for-of continue targets follow the body leave"` (`src/tests/parser.zig:7252`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M-SCOPE abrupt control: classic and for-of continue targets follow the body leave」。
- **实现**：两次 `expectContinueTargetFollowsBodyLeave(env, source, expected_events, jump_event, target_event)`：`outer: for (;;) { { continue outer; } }` 期望共 10 个作用域事件、goto 字节紧跟在事件下标 5 之后（`events[5].pc + 3`）、跳转目标是事件下标 8；`outer: for (const value of []) { { continue outer; } }` 同形，只是换成 12 个事件、下标 7、下标 10。助手内部再钉该目标事件是 scope 2 的 leave、且 `op.goto` 的标签偏移正好落在它之后。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M-SCOPE abrupt control: crossed finally sees scope leaves before gosub"` (`src/tests/parser.zig:7307`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M-SCOPE abrupt control: crossed finally sees scope leaves before gosub」。
- **实现**：断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "M-SCOPE negative contract: return cleanup and throw synthesize no scope leave"` (`src/tests/parser.zig:7332`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「M-SCOPE negative contract: return cleanup and throw synthesize no scope leave」。
- **实现**：断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: program root has var scope 0 and body scope 1"` (`src/tests/parser.zig:7378`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: program root has var scope 0 and body scope 1」。
- **实现**：断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: QuickJS root declaration rows keep body and block origins"` (`src/tests/parser.zig:7400`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: QuickJS root declaration rows keep body and block origins」。
- **实现**：断言 11 处 `std.testing.expect*`。约 11 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: function vars retain parser origins without entering lexical chains"` (`src/tests/parser.zig:7434`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: function vars retain parser origins without entering lexical chains」。
- **实现**：断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: every parsed function body has identity except class fields aggregator"` (`src/tests/parser.zig:7470`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: every parsed function body has identity except class fields aggregator」。
- **实现**：断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "defineVar core matches pinned QuickJS declaration collision matrix"` (`src/tests/parser.zig:7503`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「defineVar core matches pinned QuickJS declaration collision matrix」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "parser declaration index preserves unique and duplicate same-scope lexical declarations"` (`src/tests/parser.zig:7571`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住解析器：declaration index preserves unique and duplicate same-scope lexical declarations。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "parser declaration index preserves shadowing and catch plus two scopes"` (`src/tests/parser.zig:7587`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住解析器：declaration index preserves shadowing and catch plus two scopes。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "parser declaration index preserves function-var ancestor and sibling origins"` (`src/tests/parser.zig:7608`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住解析器：declaration index preserves function-var ancestor and sibling origins。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "parser declaration index rebuilds after bypassed linked and function-var writers"` (`src/tests/parser.zig:7624`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住解析器：declaration index rebuilds after bypassed linked and function-var writers。
- **实现**：用 `expectError` 钉失败路径。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "parser declaration index activation is retryable across allocation failures"` (`src/tests/parser.zig:7734`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住解析器：declaration index activation is retryable across allocation failures。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "F10.1a FunctionDef: empty ordinary block does not create a scope"` (`src/tests/parser.zig:7745`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：F10.1a FunctionDef: empty ordinary block does not create a scope。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: non-empty ordinary block pushes and pops one scope"` (`src/tests/parser.zig:7765`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: non-empty ordinary block pushes and pops one scope」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: nested blocks build parent chain"` (`src/tests/parser.zig:7782`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: nested blocks build parent chain」。
- **实现**：断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: nested scope inherits the visible lexical head"` (`src/tests/parser.zig:7805`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: nested scope inherits the visible lexical head」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: let registers as lexical, non-const"` (`src/tests/parser.zig:7829`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: let registers as lexical, non-const」。
- **实现**：断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: const registers as lexical + const"` (`src/tests/parser.zig:7855`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: const registers as lexical + const」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: top-level block var registers as global var"` (`src/tests/parser.zig:7873`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: top-level block var registers as global var」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: let in nested block attaches to inner scope"` (`src/tests/parser.zig:7894`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: let in nested block attaches to inner scope」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: simple catch binding keeps catch provenance"` (`src/tests/parser.zig:7914`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: simple catch binding keeps catch provenance」。
- **实现**：断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: catch has binding wrapper and body scopes"` (`src/tests/parser.zig:7941`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: catch has binding wrapper and body scopes」。
- **实现**：断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: for-of lexical head owns one binding"` (`src/tests/parser.zig:7971`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: for-of lexical head owns one binding」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: assignment for-of still owns a head scope"` (`src/tests/parser.zig:8014`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: assignment for-of still owns a head scope」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: if statement owns one wrapper scope"` (`src/tests/parser.zig:8034`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: if statement owns one wrapper scope」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: classic for always owns a head scope"` (`src/tests/parser.zig:8051`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: classic for always owns a head scope」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: with scope emits its enter event"` (`src/tests/parser.zig:8068`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: with scope emits its enter event」。
- **实现**：断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: class has name and private scopes"` (`src/tests/parser.zig:8098`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: class has name and private scopes」。
- **实现**：断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1a FunctionDef: findVar locates by name"` (`src/tests/parser.zig:8126`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1a FunctionDef: findVar locates by name」。
- **实现**：断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "F10.1b Nested function: cur_func stack management"` (`src/tests/parser.zig:8149`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1b Nested function: cur_func stack management」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "nested function declarations fit the QuickJS native parser stack budget"` (`src/tests/parser.zig:8173`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「nested function declarations fit the QuickJS native parser stack budget」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "function expressions preserve closure operands across constant index 255"` (`src/tests/parser.zig:8195`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「function expressions preserve closure operands across constant index 255」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS hoist metadata keeps only the final body local function initializer"` (`src/tests/parser.zig:8233`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS hoist metadata keeps only the final body local function initializer」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS hoist metadata keeps only the final parameter function initializer"` (`src/tests/parser.zig:8260`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS hoist metadata keeps only the final parameter function initializer」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS block function metadata does not also use the body prologue fallback"` (`src/tests/parser.zig:8287`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：QuickJS block function metadata does not also use the body prologue fallback。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS final linkage rebuild includes implicit arguments by scope level"` (`src/tests/parser.zig:8308`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS final linkage rebuild includes implicit arguments by scope level」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS add_eval_variables stages pseudo locals in VarDef append order"` (`src/tests/parser.zig:8333`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS add_eval_variables stages pseudo locals in VarDef append order」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS direct eval arguments pseudo is distinct from a simple formal"` (`src/tests/parser.zig:8399`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS direct eval arguments pseudo is distinct from a simple formal」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS entry contract carries grammar while bindings live in vardefs"` (`src/tests/parser.zig:8434`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS entry contract carries grammar while bindings live in vardefs」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 16 处 `std.testing.expect*`。约 16 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS parameter expression scope initializes lexical TDZ on entry"` (`src/tests/parser.zig:8499`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS parameter expression scope initializes lexical TDZ on entry」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS global declaration carriers precede child finalization"` (`src/tests/parser.zig:8522`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS global declaration carriers precede child finalization」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "dynamic global writes keep put_var distinct from plain var-ref stores"` (`src/tests/parser.zig:8556`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dynamic global writes keep put_var distinct from plain var-ref stores」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS open binding indices follow child capture demand order"` (`src/tests/parser.zig:8637`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS open binding indices follow child capture demand order」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "dead scope refs do not capture across a live merge"` (`src/tests/parser.zig:8686`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dead scope refs do not capture across a live merge」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS postorder capture topology records exact forwarding rows"` (`src/tests/parser.zig:8727`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS postorder capture topology records exact forwarding rows」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS postorder capture topology follows lexical scope order"` (`src/tests/parser.zig:8765`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS postorder capture topology follows lexical scope order」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS direct eval capture prefix preserves shadowed binding identities"` (`src/tests/parser.zig:8799`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS direct eval capture prefix preserves shadowed binding identities」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS direct eval capture prefix follows lexical scope order"` (`src/tests/parser.zig:8840`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS direct eval capture prefix follows lexical scope order」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS eval prefix is stable before descendant capture demand"` (`src/tests/parser.zig:8880`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS eval prefix is stable before descendant capture demand」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS eval root appends child and own ordinary globals after declarations"` (`src/tests/parser.zig:8914`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS eval root appends child and own ordinary globals after declarations」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "final eval operands address compact vardef chains"` (`src/tests/parser.zig:8945`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「final eval operands address compact vardef chains」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "final eval marker is combined and belongs only to the eval unit"` (`src/tests/parser.zig:9017`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「final eval marker is combined and belongs only to the eval unit」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "direct eval capture hints preserve the former parameter flag bit as scope data"` (`src/tests/parser.zig:9044`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「direct eval capture hints preserve the former parameter flag bit as scope data」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS direct eval captures only loop bindings live at the call site"` (`src/tests/parser.zig:9090`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS direct eval captures only loop bindings live at the call site」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS class private direct eval has complete capture events"` (`src/tests/parser.zig:9124`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS class private direct eval has complete capture events」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入是 `class C { #x = 7; good() { return eval("this.#x"); } }`（`this.#x` 只是方法里直接 eval 的字符串）；唯一断言是 `parsed.syntax_error == null`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS module closure order keeps all imports before global declarations"` (`src/tests/parser.zig:9141`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS module closure order keeps all imports before global declarations」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS module declarations append without parser closure remapping"` (`src/tests/parser.zig:9166`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS module declarations append without parser closure remapping」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 18 处 `std.testing.expect*`。约 18 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS parent module declarations exist before child direct-eval seeding"` (`src/tests/parser.zig:9240`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS parent module declarations exist before child direct-eval seeding」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。脚本/输入是一段 module：`export let moduleDirectEvalBinding = 37;` 加 `export function readModuleBindingByEval() { return eval("moduleDirectEvalBinding"); }`；断言子函数的 closure var 至少 3 条且按 `moduleDirectEvalBinding`/`readModuleBindingByEval`/`eval` 顺序、类型为 `.ref`/`.ref`/`.global_ref`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS module instantiation guard separates function hoists from the body"` (`src/tests/parser.zig:9274`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS module instantiation guard separates function hoists from the body」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS module instantiation guard excludes frame lexical preparation"` (`src/tests/parser.zig:9312`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS module instantiation guard excludes frame lexical preparation」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS module callback captures keep parent declaration indices"` (`src/tests/parser.zig:9333`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS module callback captures keep parent declaration indices」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS global eval capture stays distinct from appended declaration carrier"` (`src/tests/parser.zig:9370`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS global eval capture stays distinct from appended declaration carrier」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS script global functions publish from bytecode through the first declaration carrier"` (`src/tests/parser.zig:9395`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS script global functions publish from bytecode through the first declaration carrier」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS direct eval hoist target walk distinguishes closure var-object and lexical conflict"` (`src/tests/parser.zig:9433`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS direct eval hoist target walk distinguishes closure var-object and lexical conflict」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 10 处 `std.testing.expect*`。约 10 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "F10.1c Nested function: bytecode dual-buffering"` (`src/tests/parser.zig:9485`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「F10.1c Nested function: bytecode dual-buffering」。
- **实现**：断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "TS: Class Constructor Parameter Properties"` (`src/tests/parser.zig:9515`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TS: Class Constructor Parameter Properties」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "TS: Enum Declarations"` (`src/tests/parser.zig:9528`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TS: Enum Declarations」。
- **实现**：`parseTSStatement`（`lex.enableTypeScript()` 后走 `parseStatementOrDecl` 并 `finalize`）编 `enum Direction { Up, Down = 2, Left, Right = "Right" }`，用 `expectOpcode` 查根码里存在 `op.put_field` 与 `op.put_array_el`——即 TS enum 被降成运行时对象的正反双向赋值。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "TS: Const Enum Declarations Lower As Runtime Enums"` (`src/tests/parser.zig:9544`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TS: Const Enum Declarations Lower As Runtime Enums」。
- **实现**：`parseTSStatement` 编 `const enum Direction { Up, Down = 2 }`，同样查 `op.put_field` 与 `op.put_array_el`，钉 `const enum` 不被擦除、仍按普通运行时 enum 降级。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "TS: Nested Generic Greater Tokens"` (`src/tests/parser.zig:9558`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TS: Nested Generic Greater Tokens」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "TS: Const Type Parameters"` (`src/tests/parser.zig:9579`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TS: Const Type Parameters」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "TS: Function Overload Signatures Are Skipped"` (`src/tests/parser.zig:9593`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TS: Function Overload Signatures Are Skipped」。
- **实现**：断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "TS: Class Method Overload Signatures Are Skipped"` (`src/tests/parser.zig:9612`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TS: Class Method Overload Signatures Are Skipped」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "TS: Generic Arrow Type Parameters Are Skipped"` (`src/tests/parser.zig:9627`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TS: Generic Arrow Type Parameters Are Skipped」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "TS: Inline Object Type Parameter Constraints Are Skipped"` (`src/tests/parser.zig:9641`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TS: Inline Object Type Parameter Constraints Are Skipped」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "TS: Unsupported Syntax Scan Reports Feature And Position"` (`src/tests/parser.zig:9656`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TS: Unsupported Syntax Scan Reports Feature And Position」。
- **实现**：断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "TS: Namespaces"` (`src/tests/parser.zig:9677`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TS: Namespaces」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "TS: Nested Constructor Block Parameter Re-emission"` (`src/tests/parser.zig:9693`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TS: Nested Constructor Block Parameter Re-emission」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "TS: Derived Constructor Parameter Properties post-super"` (`src/tests/parser.zig:9710`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TS: Derived Constructor Parameter Properties post-super」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "TS: Namespace Scope Isolation"` (`src/tests/parser.zig:9724`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TS: Namespace Scope Isolation」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "TS: Dotted Namespaces"` (`src/tests/parser.zig:9737`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TS: Dotted Namespaces」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "TS: Strict Enum Constant Expression Rejection"` (`src/tests/parser.zig:9749`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「TS: Strict Enum Constant Expression Rejection」。
- **实现**：断言错误 `error.UnexpectedToken`。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "try finally parses one shared finalizer body for every abrupt exit"` (`src/tests/parser.zig:9787`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「try finally parses one shared finalizer body for every abrupt exit」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "try catch fixed topology removes calls to its empty finalizer"` (`src/tests/parser.zig:9841`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「try catch fixed topology removes calls to its empty finalizer」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "empty finally producer reaches the phase2 and phase3 cascade"` (`src/tests/parser.zig:9859`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「empty finally producer reaches the phase2 and phase3 cascade」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "arrow lexical this and new.target are ordinary closure captures"` (`src/tests/parser.zig:9984`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「arrow lexical this and new.target are ordinary closure captures」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "arrow super property captures lexical this through an ordinary cell"` (`src/tests/parser.zig:10011`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「arrow super property captures lexical this through an ordinary cell」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "arrow super call captures active constructor state through ordinary cells"` (`src/tests/parser.zig:10038`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「arrow super call captures active constructor state through ordinary cells」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "syntax error deinit balances empty message allocation"` (`src/tests/parser.zig:10090`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「syntax error deinit balances empty message allocation」。
- **实现**：断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "source positions and syntax errors carry filename line and column"` (`src/tests/parser.zig:10101`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「source positions and syntax errors carry filename line and column」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "compile syntax errors report the failing token position"` (`src/tests/parser.zig:10115`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「compile syntax errors report the failing token position」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "expectToken syntax errors name the expected and actual token kinds"` (`src/tests/parser.zig:10139`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「expectToken syntax errors name the expected and actual token kinds」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "parser error long tail names the unexpected source token"` (`src/tests/parser.zig:10151`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住解析器：error long tail names the unexpected source token。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "parser error long tail names binding pattern and module tokens"` (`src/tests/parser.zig:10177`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住解析器：error long tail names binding pattern and module tokens。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "parser error long tail closes semantic and lookahead diagnostics"` (`src/tests/parser.zig:10203`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住解析器：error long tail closes semantic and lookahead diagnostics。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "parser source-reachable invariant masks carry specific diagnostics"` (`src/tests/parser.zig:10233`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住解析器：source-reachable invariant masks carry specific diagnostics。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "lexer syntax errors retain the failing token position"` (`src/tests/parser.zig:10280`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住词法器：syntax errors retain the failing token position。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "direct eval propagates script or module identity without changing display filename"` (`src/tests/parser.zig:10292`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「direct eval propagates script or module identity without changing display filename」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "script parse mode emits bytecode metadata without AST execution"` (`src/tests/parser.zig:10333`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「script parse mode emits bytecode metadata without AST execution」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "production root modes end in visible return opcodes"` (`src/tests/parser.zig:10349`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住生产契约：root modes end in visible return opcodes。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "ordinary script compile publishes one canonical function bytecode root"` (`src/tests/parser.zig:10391`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「ordinary script compile publishes one canonical function bytecode root」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "canonical root ownership moves out of parser Result exactly once"` (`src/tests/parser.zig:10409`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「canonical root ownership moves out of parser Result exactly once」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "canonical module artifact ownership moves out of parser Result exactly once"` (`src/tests/parser.zig:10434`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「canonical module artifact ownership moves out of parser Result exactly once」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "implicit arguments always resolves before final global var opcodes"` (`src/tests/parser.zig:10464`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「implicit arguments always resolves before final global var opcodes」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "canonical root and child independently keep their compile realm alive"` (`src/tests/parser.zig:10521`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「canonical root and child independently keep their compile realm alive」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "runtime strict compile policy is published by root and child finalizers"` (`src/tests/parser.zig:10556`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「runtime strict compile policy is published by root and child finalizers」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 8 处 `std.testing.expect*`。约 8 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module compile publishes one canonical function bytecode plus metadata artifact"` (`src/tests/parser.zig:10582`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module compile publishes one canonical function bytecode plus metadata artifact」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module nested function independently keeps its compile realm alive"` (`src/tests/parser.zig:10598`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module nested function independently keeps its compile realm alive」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "canonical root and child survive parser arena release allocation churn and GC"` (`src/tests/parser.zig:10632`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「canonical root and child survive parser arena release allocation churn and GC」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。`forceGC` 前后比对 `rt.memory.allocated_bytes` 与 root/child 字节码的身份（`ValueRootFrame` 显式钉住两个 FB 头撑过回收窗口）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "root strictness comes from directives or host options, never source comments"` (`src/tests/parser.zig:10700`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：root strictness comes from directives or host options, never source comments。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "eval type owns var and lexical declaration carriers like pinned QuickJS"` (`src/tests/parser.zig:10732`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住求值：type owns var and lexical declaration carriers like pinned QuickJS。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 22 处 `std.testing.expect*`。约 22 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "ordinary block string literal is not a function-body directive"` (`src/tests/parser.zig:10794`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「ordinary block string literal is not a function-body directive」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "function body declarations preserve QuickJS source VarDef order"` (`src/tests/parser.zig:10810`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「function body declarations preserve QuickJS source VarDef order」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "body var discovery does not cross arrow or class method boundaries"` (`src/tests/parser.zig:10828`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：body var discovery does not cross arrow or class method boundaries。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "generic for-of accepts complete parenthesized and indexed member targets"` (`src/tests/parser.zig:10848`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generic for-of accepts complete parenthesized and indexed member targets」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "for-of contextual async lookahead follows QuickJS grammar"` (`src/tests/parser.zig:10867`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「for-of contextual async lookahead follows QuickJS grammar」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "generic for-of parses computed target exactly once in source order"` (`src/tests/parser.zig:10897`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「generic for-of parses computed target exactly once in source order」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "for statement dispatch only scans top-level semicolons"` (`src/tests/parser.zig:10914`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「for statement dispatch only scans top-level semicolons」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "for-in-of keeps Annex B call targets and rejects other invalid assignment targets"` (`src/tests/parser.zig:10936`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「for-in-of keeps Annex B call targets and rejects other invalid assignment targets」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "script top-level lexical captured before declaration uses QuickJS global op"` (`src/tests/parser.zig:10959`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「script top-level lexical captured before declaration uses QuickJS global op」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "captured reads encode lexical TDZ in the final var-ref opcode"` (`src/tests/parser.zig:10980`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「captured reads encode lexical TDZ in the final var-ref opcode」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "named function self-binding writes do not reach var-ref stores"` (`src/tests/parser.zig:11010`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「named function self-binding writes do not reach var-ref stores」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "final bytecode authorizes plain var-ref stores before execution"` (`src/tests/parser.zig:11067`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「final bytecode authorizes plain var-ref stores before execution」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 38 处 `std.testing.expect*`。约 38 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "assignment target scan ignores atom operand bytes"` (`src/tests/parser.zig:11294`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「assignment target scan ignores atom operand bytes」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "print calls emit global lookup generic call and receiver-preserving property call bytecode"` (`src/tests/parser.zig:11319`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「print calls emit global lookup generic call and receiver-preserving property call bytecode」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "simple variable assignments emit var bytecode"` (`src/tests/parser.zig:11355`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「simple variable assignments emit var bytecode」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "quick parser emits compound assignment and update statements"` (`src/tests/parser.zig:11373`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「quick parser emits compound assignment and update statements」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "add_loc finalization accepts only QuickJS RHS producers"` (`src/tests/parser.zig:11388`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「add_loc finalization accepts only QuickJS RHS producers」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 16 处 `std.testing.expect*`。约 16 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "add_loc finalization attributes a multiline local RHS to the operator"` (`src/tests/parser.zig:11481`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「add_loc finalization attributes a multiline local RHS to the operator」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "quick parser emits arithmetic compound assignment operators"` (`src/tests/parser.zig:11522`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「quick parser emits arithmetic compound assignment operators」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "quick parser does not claim update expression values"` (`src/tests/parser.zig:11536`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：quick parser does not claim update expression values。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "quick parser emits basic array and object literals"` (`src/tests/parser.zig:11546`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「quick parser emits basic array and object literals」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "quick parser emits object property assignment"` (`src/tests/parser.zig:11564`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「quick parser emits object property assignment」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "quick parser emits optional property access for object and nullish bases"` (`src/tests/parser.zig:11579`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「quick parser emits optional property access for object and nullish bases」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "quick parser preserves parenthesized postfix bases"` (`src/tests/parser.zig:11592`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「quick parser preserves parenthesized postfix bases」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "quick parser keeps conditional member callee branches at one stack slot"` (`src/tests/parser.zig:11609`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「quick parser keeps conditional member callee branches at one stack slot」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "quick parser retrofits forward var captures into nested closures"` (`src/tests/parser.zig:11635`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「quick parser retrofits forward var captures into nested closures」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "quick parser still promotes unconditional parenthesized member calls"` (`src/tests/parser.zig:11663`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「quick parser still promotes unconditional parenthesized member calls」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "call consumers use final-op provenance for eval with super and comma tags"` (`src/tests/parser.zig:11675`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「call consumers use final-op provenance for eval with super and comma tags」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 9 处 `std.testing.expect*`。约 9 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "quick parser lowers JSON stringify and parse to transitional JSON bytecode"` (`src/tests/parser.zig:11733`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「quick parser lowers JSON stringify and parse to transitional JSON bytecode」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "quick parser lowers Math calls to transitional Math bytecode"` (`src/tests/parser.zig:11744`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「quick parser lowers Math calls to transitional Math bytecode」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "quick parser lowers URI calls to transitional URI bytecode"` (`src/tests/parser.zig:11755`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「quick parser lowers URI calls to transitional URI bytecode」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "quick parser lowers Number parse helpers to transitional number bytecode"` (`src/tests/parser.zig:11766`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「quick parser lowers Number parse helpers to transitional number bytecode」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "quick parser lowers supported Date helpers to receiver-preserving property calls"` (`src/tests/parser.zig:11781`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「quick parser lowers supported Date helpers to receiver-preserving property calls」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "quick parser lowers supported RegExp helpers to receiver-preserving property calls"` (`src/tests/parser.zig:11798`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「quick parser lowers supported RegExp helpers to receiver-preserving property calls」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "RegExp property calls keep QuickJS call_method bytecode"` (`src/tests/parser.zig:11814`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「RegExp property calls keep QuickJS call_method bytecode」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "function predeclare scan skips slash-equals regexp literals"` (`src/tests/parser.zig:11841`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「function predeclare scan skips slash-equals regexp literals」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "quick parser lowers supported Promise helpers to receiver-preserving property calls"` (`src/tests/parser.zig:11863`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「quick parser lowers supported Promise helpers to receiver-preserving property calls」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "quick parser lowers supported collection helpers to receiver-preserving property calls"` (`src/tests/parser.zig:11887`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「quick parser lowers supported collection helpers to receiver-preserving property calls」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "template interpolation emits string concatenation"` (`src/tests/parser.zig:11925`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「template interpolation emits string concatenation」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "simple arrays emit receiver-preserving property calls"` (`src/tests/parser.zig:11939`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「simple arrays emit receiver-preserving property calls」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "simple functions and arrows emit inline helper bytecode"` (`src/tests/parser.zig:11957`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「simple functions and arrows emit inline helper bytecode」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "unsupported spread call reports syntax guard"` (`src/tests/parser.zig:11980`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「unsupported spread call reports syntax guard」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "test262 frontmatter does not affect quick parser behavior"` (`src/tests/parser.zig:11990`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：负向钉：test262 frontmatter does not affect quick parser behavior。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、1 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "test262 prelude frontmatter parses nested private methods after line_num temp"` (`src/tests/parser.zig:12013`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住 test262 runner / harness：test262 prelude frontmatter parses nested private methods after line_num temp。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "arrow early errors reject non-simple strict and invalid rest parameters"` (`src/tests/parser.zig:12058`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「arrow early errors reject non-simple strict and invalid rest parameters」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "strict parameter binding names follow directive and method grammar"` (`src/tests/parser.zig:12079`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「strict parameter binding names follow directive and method grammar」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "retroactive strict arrow parameter errors retain the binding position"` (`src/tests/parser.zig:12124`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「retroactive strict arrow parameter errors retain the binding position」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "arrow early error checks do not reject valid nested rest destructuring"` (`src/tests/parser.zig:12151`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「arrow early error checks do not reject valid nested rest destructuring」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "destructuring rest parameter defaults enforce await and yield early errors"` (`src/tests/parser.zig:12167`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「destructuring rest parameter defaults enforce await and yield early errors」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "assignment destructuring early errors reject invalid rest forms"` (`src/tests/parser.zig:12186`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「assignment destructuring early errors reject invalid rest forms」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "assignment destructuring early errors allow reserved property names"` (`src/tests/parser.zig:12233`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「assignment destructuring early errors allow reserved property names」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "assignment early errors reject invalid assignment target types"` (`src/tests/parser.zig:12256`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「assignment early errors reject invalid assignment target types」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "async arrow early errors reject await-context parse negatives"` (`src/tests/parser.zig:12274`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「async arrow early errors reject await-context parse negatives」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "object computed property names parse async arrow and module await expressions"` (`src/tests/parser.zig:12291`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「object computed property names parse async arrow and module await expressions」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 14 处 `std.testing.expect*`。约 14 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "class early errors reject class parse negatives"` (`src/tests/parser.zig:12320`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「class early errors reject class parse negatives」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module parse mode records import export metadata and strict flag"` (`src/tests/parser.zig:12341`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module parse mode records import export metadata and strict flag」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 17 处 `std.testing.expect*`。约 17 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module parser preserves regex literals across zod-like lookahead scans"` (`src/tests/parser.zig:12390`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module parser preserves regex literals across zod-like lookahead scans」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "parser rescans divide-assign token as regex literal beginning with equals"` (`src/tests/parser.zig:12439`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住解析器：rescans divide-assign token as regex literal beginning with equals。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module import local names are compiled as module var refs"` (`src/tests/parser.zig:12470`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module import local names are compiled as module var refs」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 5 处 `std.testing.expect*`。约 5 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module parser rejects duplicate exported names across export forms"` (`src/tests/parser.zig:12502`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module parser rejects duplicate exported names across export forms」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module parser validates local export bindings after full body parse"` (`src/tests/parser.zig:12519`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module parser validates local export bindings after full body parse」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module parser rejects duplicate import attribute keys per with clause"` (`src/tests/parser.zig:12545`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module parser rejects duplicate import attribute keys per with clause」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module parser accepts empty side-effect import attributes"` (`src/tests/parser.zig:12569`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module parser accepts empty side-effect import attributes」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module parser validates string module export names"` (`src/tests/parser.zig:12581`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module parser validates string module export names」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module namespace metadata is syntax-driven when the imported name is star"` (`src/tests/parser.zig:12602`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module namespace metadata is syntax-driven when the imported name is star」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 7 处 `std.testing.expect*`。约 7 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module parser rejects comma expression as default export expression"` (`src/tests/parser.zig:12627`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module parser rejects comma expression as default export expression」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module parser accepts keyword module export and import names"` (`src/tests/parser.zig:12640`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module parser accepts keyword module export and import names」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module parser allows duplicate top-level var declarations"` (`src/tests/parser.zig:12657`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module parser allows duplicate top-level var declarations」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module parser hoists block var declarations to module var refs"` (`src/tests/parser.zig:12667`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module parser hoists block var declarations to module var refs」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "direct eval closure seed lowers unresolved read to var ref"` (`src/tests/parser.zig:12687`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「direct eval closure seed lowers unresolved read to var ref」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "direct eval rebuilds private grammar bindings from ordered closure rows"` (`src/tests/parser.zig:12723`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「direct eval rebuilds private grammar bindings from ordered closure rows」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "only direct eval enables private grammar from closure seeds"` (`src/tests/parser.zig:12785`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「only direct eval enables private grammar from closure seeds」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "direct eval ref closure seed preserves table identity only"` (`src/tests/parser.zig:12808`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「direct eval ref closure seed preserves table identity only」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "parameter direct eval keeps arg var object ahead of declaration globals"` (`src/tests/parser.zig:12835`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「parameter direct eval keeps arg var object ahead of declaration globals」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QuickJS direct eval destructuring declares through the variable object"` (`src/tests/parser.zig:12867`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QuickJS direct eval destructuring declares through the variable object」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 13 处 `std.testing.expect*`。约 13 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "parser accepts dynamic import call expressions"` (`src/tests/parser.zig:12923`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住解析器：accepts dynamic import call expressions。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 6 处 `std.testing.expect*`。约 6 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "dynamic import arguments do not leak anonymous function named evaluation"` (`src/tests/parser.zig:12952`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「dynamic import arguments do not leak anonymous function named evaluation」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "parser rejects invalid dynamic import call syntax"` (`src/tests/parser.zig:12968`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住解析器：rejects invalid dynamic import call syntax。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "module parser accepts default as explicit namespace export name"` (`src/tests/parser.zig:12981`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「module parser accepts default as explicit namespace export name」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 4 处 `std.testing.expect*`。约 4 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "eval function class private destructuring spread async generator features are recorded"` (`src/tests/parser.zig:12995`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住求值：function class private destructuring spread async generator features are recorded。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 15 处 `std.testing.expect*`。约 15 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "bytecode constants retain values through Phase 4 structures"` (`src/tests/parser.zig:13031`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「bytecode constants retain values through Phase 4 structures」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "label/patch/move/truncate corpus keeps compiling after a flow-tail rewrite"` (`src/tests/parser.zig:13055`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「label/patch/move/truncate corpus keeps compiling after a flow-tail rewrite」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 1 处 `std.testing.expect*`。约 1 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "QCP-1 S2P: v2 veneer emits through the FunctionDef builder and deinit releases it"` (`src/tests/parser.zig:13100`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「QCP-1 S2P: v2 veneer emits through the FunctionDef builder and deinit releases it」。
- **实现**：断言 11 处 `std.testing.expect*`。约 11 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：无跨测试状态；失败即测试失败，不把 JS 异常漏到下一例。

### `test "parser releases identifier and private-name token atoms"` (`src/tests/parser.zig:13148`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住解析器：releases identifier and private-name token atoms。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "parser releases module and import-attribute token atoms"` (`src/tests/parser.zig:13211`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住解析器：releases module and import-attribute token atoms。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 3 处 `std.testing.expect*`。约 3 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "parser returns the atom table to balance across every token-bearing construct"` (`src/tests/parser.zig:13248`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住解析器：returns the atom table to balance across every token-bearing construct。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 2 处 `std.testing.expect*`。约 2 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

### `test "four-ledger phase-boundary ownership accounting parse-only"` (`src/tests/parser.zig:13892`)

- **签名**：无参数测试块，返回 `!void`。
- **作用**：钉住场景「four-ledger phase-boundary ownership accounting parse-only」。
- **实现**：直接 `JSRuntime.create` 建裸 Runtime（不经 TestEngine）。断言 12 处 `std.testing.expect*`。约 12 个 Zig expect、0 个 JS `assert.*`。
- **所有权 / 错误 / 调用**：测试持有 Runtime/Context 所有权，`defer destroy/deinit`；GC 对象靠 root frame 或精确扫描。

## 覆盖核对

- 清单函数数: 134
- 本文标题覆盖: 647
- 未覆盖: 无
