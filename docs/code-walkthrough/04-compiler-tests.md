# 04 — 测试入口与契约测试

`test_entry.zig` 给编译器测试一个统一 parse 入口。`tests.zig` 是契约测试：IR 构造、标签/变量解析、packed 字节码、生产 short 布局、VM 执行。清单里的是 harness / 断言助手，不是每条 `test "…"` 块；下面按函数写场景。

## `test_entry.zig`

`RootKind`：script / module。`Options.emit_phase1_temp` 默认 true（生产 parser 也默认开）；S2-G1 语句片段测试会关。

`Program` 持有 Bytecode、name_atom、Lexer、ParseState。按值返回，所以 `deinit` 要先把 `state.lex` / `state.function` 修回自身字段地址。

### `Program.phase1Code` (`src/compiler/test_entry.zig:29`)

- **签名**：`pub fn phase1Code(p: *const Program) []const u8`。
- **作用**：断言用的 parser 阶段指令流：lowering 前 Builder 紧凑临时流。
- **实现**：`builder.code[0..code_len]`。
- **所有权 / 错误 / 调用**：切片借 Builder；Program 活着才能用。

### `Program.deinit` (`src/compiler/test_entry.zig:33`)

- **签名**：`pub fn deinit(p: *Program, rt: *core.JSRuntime) void`。
- **作用**：按值返回后修复两个指向构造时结果位置的指针，再释放 ParseState、lexer、Bytecode。
- **实现**：`state.lex = &p.lexer`；`state.function = &p.function`；然后三级 deinit。
- **所有权 / 错误 / 调用**：不 destroy runtime（调用方持有）。name_atom 随 AtomTable。

### `configureScriptRoot` (`src/compiler/test_entry.zig:44`)

- **签名**：`pub fn configureScriptRoot(state: *Parser.ParseState) void`。
- **作用**：把 ParseState 收成 completion 脚本根：eval、global var、顶层函数当 child、词法当 global ref。
- **实现**：四个布尔字段。
- **所有权 / 错误 / 调用**：`parseAndCompileV2TestProgram` 的 `.script`。

### `configureModuleRoot` (`src/compiler/test_entry.zig:51`)

- **签名**：`pub fn configureModuleRoot(state: *Parser.ParseState) void`。
- **作用**：模块根：eval+module+global var+strict，词法当 module ref。
- **实现**：另置 `state.is_strict`。
- **所有权 / 错误 / 调用**：`.module`。

### `parseAndCompileV2TestProgram` (`src/compiler/test_entry.zig:61`)

- **签名**：`pub fn parseAndCompileV2TestProgram( rt: *core.JSRuntime, testing_allocator: std.mem.Allocator, name: []const u8, source: []const u8, options: Options, ) !Program`。
- **作用**：intern 名、建 Bytecode/lexer/ParseState、配根、可选 TS、beginProgramEmission、parseProgramStatements。**不**跑 resolve/finalize。
- **实现**：errdefer 各级 deinit。`emit_phase1_temp` 来自 options。
- **所有权 / 错误 / 调用**：parser 与需要看 phase-1 流的测试。lexer 用 testing_allocator。

---

## `tests.zig` harness

`ParseHarness`：无 realm 的解析夹具，`emit_phase1_temp = false`，只 `beginBuilderEmissionForTest`，用来断言迁移面内的语句片段。`ExecHarness`：带 Context、standard_globals、canonical root、compile roots、`is_global_var`，跑完整 parse→finalize→VM。

### `ParseHarness.init` (`src/compiler/tests.zig:35`)

- **签名**：`fn init(h: *ParseHarness, src: []const u8) !void`。
- **作用**：栈上夹具必须 `var h: ParseHarness = undefined`。建 runtime、Bytecode（名 `s2g1`）、lexer、ParseState；关 phase-1 作用域标记；`beginBuilderEmissionForTest`。
- **实现**：errdefer destroy runtime / deinit function / deinit lexer。
- **所有权 / 错误 / 调用**：S2-G1/G2/G3/G4 形态测试。`defer h.deinit()`。

### `ParseHarness.builder` (`src/compiler/tests.zig:51`)

- **签名**：`fn builder(h: *ParseHarness) *builder_mod.Builder`。
- **作用**：根 FunctionDef 的 v2 builder。
- **实现**：unwrap。
- **所有权 / 错误 / 调用**：`expectV2Stream` / `expectRelocIntegrity`。

### `ParseHarness.childBuilder` (`src/compiler/tests.zig:55`)

- **签名**：`fn childBuilder(h: *ParseHarness, index: usize) *builder_mod.Builder`。
- **作用**：第 `index` 个嵌套函数的 builder（方法、默认 ctor）。
- **实现**：`child_list[index].builder`。
- **所有权 / 错误 / 调用**：class 测试。

### `ParseHarness.grandchildBuilder` (`src/compiler/tests.zig:59`)

- **签名**：`fn grandchildBuilder(h: *ParseHarness, index: usize, sub: usize) *builder_mod.Builder`。
- **作用**：两层嵌套（静态块里的函数等）。
- **实现**：`child_list[index].child_list[sub]`。
- **所有权 / 错误 / 调用**：static block 测试。

### `ParseHarness.deinit` (`src/compiler/tests.zig:63`)

- **签名**：`fn deinit(h: *ParseHarness) void`。
- **作用**：state → lexer → function → runtime。
- **实现**：`h.state.deinit(rt)` / `h.lex.deinit()` / `h.function.deinit(rt)` / `rt.destroy()`。
- **所有权 / 错误 / 调用**：测试夹具释放序：`state.deinit(rt)` 连带放掉 `function_def` 树上的各级 `builder`（`builder`/`childBuilder`/`grandchildBuilder` 返回的都是这棵树上的借用指针），接着 `lex.deinit()`（与 `ExecHarness` 对齐——今天 JS 源下 `Lexer.deinit` 只释放 TS 的 `skipped_intervals`、此夹具无此缓冲，但一旦给本夹具加 TS 语料就会立刻变成 testing-allocator 泄漏），再 `function.deinit(rt)`，最后 `rt.destroy()` 关掉这些缓冲所挂的 memory 账户——runtime 必须最后走。`void`、不返回错误，由各测试的 `defer` 调用。

### `ExecHarness.init` (`src/compiler/tests.zig:81`)

- **签名**：`fn init(h: *ExecHarness, src: []const u8) !void`。
- **作用**：执行夹具：runtime+globals+context+canonical ParseState，`activateCompileRoots`，`beginProgramEmission`。
- **实现**：名 `compiler-s4-exec`。`installed_short_opcode = false`。TGC S3-b：`h` 栈上且 state 不再移动，故可在此注册 root provider。
- **所有权 / 错误 / 调用**：fuse / 执行 / escape / GC 窗口测试。

### `ExecHarness.deinit` (`src/compiler/tests.zig:102`)

- **签名**：`fn deinit(h: *ExecHarness) void`。
- **作用**：state、lexer、function、ctx、rt。
- **实现**：显式 `lex.deinit`（canonical 路径 lexer 独立）。
- **所有权 / 错误 / 调用**：反向所有权。

### `expectV2Stream` (`src/compiler/tests.zig:118`)

- **签名**：`fn expectV2Stream(b: *const builder_mod.Builder, expected: []const ExpectedInsn) !void`。
- **作用**：phase-1 流按 (op, size, 可选 LabelId/atom) 精确走完，无剩余字节。
- **实现**：pc 累加 size；label/atom 从 pc+1 读 LE u32。
- **所有权 / 错误 / 调用**：S2 组形态测试。`ExpectedInsn` 是本文件结构体。

### `expectResolvedStream` (`src/compiler/tests.zig:132`)

- **签名**：`fn expectResolvedStream( product: *const resolve_variables.ResolvedProduct, expected: []const ExpectedInsn, ) !void`。
- **作用**：S3 产物同样形状断言。
- **实现**：同 expectV2Stream，读 `product.code`。
- **所有权 / 错误 / 调用**：S3 解析后的死代码/gosub 测试。

### `expectLabel` (`src/compiler/tests.zig:155`)

- **签名**：`fn expectLabel(b: *const builder_mod.Builder, index: u32, ref_count: u32, bound_offset: u32) !void`。
- **作用**：phase-1 标签必须 bound，ref 与 offset 匹配。
- **实现**：三字段。
- **所有权 / 错误 / 调用**：控制流测试。

### `expectResolvedLabel` (`src/compiler/tests.zig:163`)

- **签名**：`fn expectResolvedLabel( product: *const resolve_variables.ResolvedProduct, index: u32, ref_count: u32, bound_offset: u32, ) !void`。
- **作用**：S3 标签：ref、offset、bound 标志、`first_reloc == no_reloc`。
- **实现**：unbound 必须与 `!flags.bound` 一致。
- **所有权 / 错误 / 调用**：死标签测 unbound。

### `installedFunctionHasShortOpcode` (`src/compiler/tests.zig:177`)

- **签名**：`fn installedFunctionHasShortOpcode(fb: *const bytecode_mod.FunctionBytecode) !bool`。
- **作用**：已安装码是否含生产 short 布局的代表 opcode（goto8 / if_*8 / put_loc0–3）。
- **实现**：按 `opcode.sizeOf` 走；非法 size 失败。
- **所有权 / 错误 / 调用**：`compileAndRun` 记到 `h.installed_short_opcode`。

### `compileAndRun` (`src/compiler/tests.zig:200`)

- **签名**：`fn compileAndRun(h: *ExecHarness) !core.JSValue`。
- **作用**：当 completion 脚本 parse，整棵 FunctionDef 树走 v2，生产 packed-FB，在 VM 上跑。返回值归调用方。
- **实现**：转 `compileAndRunWithHook(h, null)`。
- **所有权 / 错误 / 调用**：大多数执行测试。

### `compileAndRunWithHook` (`src/compiler/tests.zig:207`)

- **签名**：`fn compileAndRunWithHook(h: *ExecHarness, before_finalize: ?*const fn (*ExecHarness) anyerror!void) !core.JSValue`。
- **作用**：parse 与 `createFunctionBytecode` 之间的钩子——此时 FunctionDef 树拥有全部常量、尚未发布产物（TGC S3-b）。
- **实现**：`enableReturnCompletion`、parse 到 EOF、`finalizeEvalReturn`、可选 hook、finalize、造根函数对象、`zjs_vm.runWithCallEnv`（strict this=undefined，否则 realm global；`direct_eval_vars_reach_global`）。
- **所有权 / 错误 / 调用**：`createRootBytecodeFunctionObject` 每条路径消费 FB 值。返回 JSValue 未 free（测试立刻 asInt32）。

### `expectFunctionDefInertAfterEscape` (`src/compiler/tests.zig:257`)

- **签名**：`fn expectFunctionDefInertAfterEscape( fd: *const bytecode_mod.function_def.FunctionDef, ) !void`。
- **作用**：finalize 后 FunctionDef 必须惰性：无 builder、名字/文件/模块 atom 空、源文空、args/vars/closure 名空、cpool undefined。递归 child。
- **实现**：escape 审计：所有权已迁到 FunctionBytecode。
- **所有权 / 错误 / 调用**：P5 / packed 测试。

### `expectPublishedAtomResolves` (`src/compiler/tests.zig:281`)

- **签名**：`fn expectPublishedAtomResolves(rt: *const core.JSRuntime, atom_id: core.atom.Atom) !void`。
- **作用**：已发布 atom 非 null 且 AtomTable 仍能解析名。
- **实现**：`rt.atoms.name != null`。
- **所有权 / 错误 / 调用**：escape 后编译器拆除不得退休 FB 仍引用的 atom。

### `expectPublishedFunctionBytecodeOwnersResolve` (`src/compiler/tests.zig:286`)

- **签名**：`fn expectPublishedFunctionBytecodeOwnersResolve( rt: *const core.JSRuntime, fb: *const bytecode_mod.FunctionBytecode, owners: *PublishedEscapeOwners, ) !void`。
- **作用**：递归：funcName/filename、具名 arg/var/closure、cpool 里的子 FunctionBytecode 都能解析。累加 owners 计数。
- **实现**：null_atom 跳过。子 FB 经 `functionBytecodeHeader` + fieldParentPtr。
- **所有权 / 错误 / 调用**：证明至少看到具名槽与 child。

### `expectRelocIntegrity` (`src/compiler/tests.zig:323`)

- **签名**：`fn expectRelocIntegrity(b: *const builder_mod.Builder) !void`。
- **作用**：每条 parser 创建的标签 bound；reloc 链覆盖整个 reloc 账本且无重复；parser harness 在 scope_make_ref 仍 phase-1 门控时只能产生 jump32（aux32 由 builder 内测覆盖）。
- **实现**：visited[]；链下标严格递减；操作数写着该 label；`ref_count == 链长`；每个 reloc 恰好访问一次。
- **所有权 / 错误 / 调用**：S2 控制流测试。testing allocator。

### `expectSourceOrder` (`src/compiler/tests.zig:372`)

- **签名**：`fn expectSourceOrder(b: *const builder_mod.Builder) !void`。
- **作用**：source 槽非递减，且指向临时流内某指令（`< code_len`）。
- **实现**：previous_offset。
- **所有权 / 错误 / 调用**：发射形态测试。

### `expectSourceOffsets` (`src/compiler/tests.zig:381`)

- **签名**：`fn expectSourceOffsets(b: *const builder_mod.Builder, expected: []const u32) !void`。
- **作用**：source 条数与各 temp_offset 精确匹配。
- **实现**：zip equal。
- **所有权 / 错误 / 调用**：marker 与 rewind 测试。

### `oomScript` (`src/compiler/tests.zig:501`)

- **签名**：`fn oomScript(allocator: std.mem.Allocator) !void`。
- **作用**：OOM 扫描脚本：10 个标签、9 条 jump、bind、source、snapshot 后再发射/bind/marker，rollback 必须恢复链头与 ref_count，然后继续 emit。
- **实现**：`checkAllAllocationFailures` 驱动。证明失败路径仍可 deinit。
- **所有权 / 错误 / 调用**：`compiler.tests: allocation failure sweep preserves cleanup`。

### `countInstalledOpcode` (`src/compiler/tests.zig:2992`)

- **签名**：`fn countInstalledOpcode(fb: *const bytecode_mod.FunctionBytecode, want: u8) !usize`。
- **作用**：已安装码（含 cpool 子 FB）中某物理 id 出现次数。
- **实现**：sizeOf 走码；递归 function_bytecode 常量。
- **所有权 / 错误 / 调用**：融合测试与回收 id 清扫。

### `compileRunAndCount` (`src/compiler/tests.zig:3012`)

- **签名**：`fn compileRunAndCount(src: []const u8, expected: i32, want: []const u8) !void`。
- **作用**：parse+finalize 后每个 `want` opcode 至少出现一次，再 VM 跑，完成值=expected。
- **实现**：与 compileAndRun 相同的根调用环境，但不经 hook。
- **所有权 / 错误 / 调用**：`compiler.fuse:*` 一系列：get_loc0_field、cmp_if_false8、push_this_put_loc0、get_field2_call_method 等。证明融合既发出又执行正确。

### `s3bDrainGc` (`src/compiler/tests.zig:3390`)

- **签名**：`fn s3bDrainGc(rt: *core.JSRuntime) void`。
- **作用**：把增量标记与 morgue 排空，最多 100k poll。
- **实现**：`pollGC(..., .safepoint)`。
- **所有权 / 错误 / 调用**：强制 major 之后。assert 防死循环。

### `s3bExpectDefTreeMarked` (`src/compiler/tests.zig:3403`)

- **签名**：`fn s3bExpectDefTreeMarked( rt: *core.JSRuntime, fd: *const bytecode_mod.function_def.FunctionDef, counted: *usize, ) !void`。
- **作用**：刚跑完的 major 必须标上 def 树里每个 GC 型 cpool 槽。undefined 占位（嵌套函数保留槽，要等 `installChildFunctionBytecodes`）无 header 则跳过。未注册的 parse-time BigInt 不在 tracer 上，也跳过。
- **实现**：`cycleMarkHeader` + `headerMarked`；递归 child_list。`counted` 让调用方证明走过真实槽。
- **所有权 / 错误 / 调用**：TGC S3-b。BigInt.register 只在 FB 发布时跑。

### `s3bMajorBeforeFinalize` (`src/compiler/tests.zig:3423`)

- **签名**：`fn s3bMajorBeforeFinalize(h: *ExecHarness) anyerror!void`。
- **作用**：compileAndRun 钩子：parse 完、未发布。字符串字面量体与模板数组只活在 Zig 堆 `FunctionDef.cpool`，保守栈扫与 tracer 边都到不了，只有 `State.traceCompileValueRoots` 能保住。
- **实现**：forceMajorGC、drain、`s3bExpectDefTreeMarked` 至少 2（RegExp 模式串+编译字节码串），且 child_list≥2。
- **所有权 / 错误 / 调用**：`TGC S3-b: a major between parse and finalize keeps cpool constants alive`。

### `s3bExpectTemplateArraysMarked` (`src/compiler/tests.zig:3475`)

- **签名**：`fn s3bExpectTemplateArraysMarked(h: *ExecHarness) anyerror!void`。
- **作用**：钩子：强制 major 后 def 树至少 1 个标上的 GC 槽，且某 cpool（根或 child）有 OBJECT（frozen cooked 数组；raw 挂在其 `raw` 属性上）。窗口在此结束：之后 hook 返回，`compileAndRunWithHook` 把 FB 放进 native 局部，`.declared_only` 看不见。ZJS_GC_STRESS 会在缝里回收 FB，所以恢复默认保守根扫描。
- **实现**：`restoreDefaultRootScanForTest`。
- **所有权 / 错误 / 调用**：tagged-template 测试在 hook 前 `forcePreciseRootScanForTest`。

---

## 覆盖核对

- 清单函数数: 32（`src/compiler/test_entry.zig` 5 + `src/compiler/tests.zig` 27）
- 本文标题覆盖: 32
- 未覆盖: 无
