# ZJS Current Architecture Snapshot

本文记录当前源码中的架构状态，而不是历史路线图、口号式目标或未落地的
设计承诺。语义参考仍是 QuickJS；验证边界以根目录 `test262.conf`、
`test262/` 和 Zig regression 为准。

## 1. Runtime And Ownership

当前运行时核心在 `src/core/`：

- `runtime.zig`: `JSRuntime`、`JSContext`、根追踪、GC 调度和宿主资源。
- `value.zig`: `JSValue` 表示与引用计数入口。
- `object.zig`: JS 对象、属性表、prototype、class payload 和 child-edge tracing。
- `function_bytecode.zig`: GC 管理的函数字节码对象。
- `gc.zig`: GC registry、policy、外部内存记账和统计。

已落地的生命周期模型是：

- 非原子引用计数负责大多数对象的即时释放。
- `runObjectCycleRemoval` / `tryRunObjectCycleRemovalWithValueRoots` 负责
  root-aware 的对象与 `FunctionBytecode` 环清理。
- `ValueRootFrame` 是当前 VM 和宿主边界使用的显式根链表。
- `FrameRootScope` 会把 VM operand stack、locals、args、var refs 和 eval
  snapshot 挂到 `JSRuntime.active_value_roots`。
- 宿主持有跨调用生命周期的值时，必须使用 public API 中的 handle /
  persistent-root 机制，而不是裸保存 `JSValue`。

Z-GE 分代脚手架（nursery / remembered-set / dirty-card / minor 调度，默认
关闭、从未投产）已按 Phase 4 计划整体移除（git 历史可找回）；`gc.zig` 保留
RC + 循环回收主路径、old/large 空间记账与 GC scheduler。

Object 头瘦身第一步已完成：13 个散装 bool 收敛为 `flags: ObjectFlags`
（packed u16），`sizeOf(Object)` 192 → 184 字节。余项为 shape.props 与
object.properties 的 `atom_id`/`flags` 双份元数据去重（shape 持元数据、
对象持值，QuickJS 模型）。

已评估待做（Phase 4 余项）：
- 循环回收的 `visited`/`preserved`/`free_set` 三个 AutoHashMap（每轮全堆
  hash put）可改为 header 2-bit 状态机，预期消除每轮 O(对象数) 的 hash
  开销；改动触及 resurrection 与 weak 边扫描的核心正确性，需专门会话以
  全门禁节奏实施。
- ~~weak identity 裸 header 地址 + O(n) 全堆扫描兜底~~：已实施 weak_id
  （单调递增）双表注册表（`weak_object_ids`/`weak_id_objects`，
  `Object.has_weak_id` flag 门控销毁清理）。weak 槽（WeakRef/WeakMap/
  WeakSet/FinalizationRegistry/WeakRootSlot）统一存 `weak_id << 1` 编码
  （symbol 仍为 `(atom<<1)|1`），`liveObjectFromWeakIdentity` 改为 O(1)
  查表，地址复用 ABA 误命中随 id 永不复用而根治；matcher 偶数分支由
  「解引用 header flag」改为批量 identity 哈希集合查询，消除了对已释放
  对象内存的读取。

JSValue 表示（Phase 5）：访问器封装 pass 已完成——`core/value.zig` 之外的
直接 `tag`/`payload` 字段访问为零（仅 `binding/ffi.zig` 的 comptime 布局
反射保留，用于 NaN-boxing 切换时自动失配 ABI 指纹），NaN-boxing 的 8 字节
表示可作为 build option 双模式实施。

## 2. Frontend And TypeScript Erasure

当前 frontend 在 `src/frontend/`：

- `parser.zig` 是 public parse wrapper。
- `zjs_lexer.zig` 提供 lexer、source-kind 判断和 TypeScript erasure。
- `zjs_parser.zig` 是 QuickJS-aligned parser/emitter。
- `source_pos.zig` 和 `zjs_token.zig` 提供位置与 token 支撑。

TypeScript 支持是语法擦除，不是类型检查器：

- `parser.parse` 根据 `SourceKind` 和文件名调用 `zjs_lexer.shouldStrip`。
- 需要擦除时调用 `Lexer.enableTypeScript()`。
- `enableTypeScript` 设置 `is_typescript`，并由 `markTypeRanges` 生成
  `skipped_intervals`。
- lexer 在扫描时跳过这些区间，让 parser 消费近似纯 JS 的 token stream。

这条路径只应描述为“当前支持的 TypeScript 语法擦除”。不要在文档中承诺完整
TypeScript 语义、类型检查、source-map 等价物或固定性能提升百分比。

## 3. Bytecode Carrier

当前执行载体是 `src/bytecode/function.zig` 中的 `Bytecode`，不是单独的
`CodeBlock` 抽象。`Bytecode` 持有：

- opcode bytes: `code`
- constants: `constant.Pool`
- atom operands
- args、vars、var refs、global vars、private names
- module metadata
- `pc2line_buf`、`source_loc_slots`、`debug_table`
- property inline-cache slots: `ic_slots`、`ic_site_ids`、`ic_sites`

pipeline 入口在 `src/bytecode/pipeline/`：

- `resolve_labels.zig`
- `resolve_variables.zig`
- `stack_size.zig`
- `pc2line.zig`
- `finalize.zig`

`stack_size.zig` 负责按字节码图计算最大 stack depth，并验证 underflow、
overflow、stack mismatch 和无效 opcode 等错误。它不是完整 JIT-style GC
stack-map 系统。

### 3.1 编译管线与 QuickJS 的对应关系

p3-pipeline / p4-fb-compact 的对照结论（语义已由 test262 门禁 0 失败 +
行为探针验证；下表记录结构差异及其成本评估，消除「未知偏差」）：

| QuickJS pass / 机制 | zjs 等价机制 | 差异点 | 实质成本 |
| --- | --- | --- | --- |
| `js_create_function` scope 重链（quickjs.c:36120-36144：重算 `scope_next`/`scopes[].first`，空 scope 继承父链） | `FunctionDef.addScopeVar` 在解析时增量维护 `scope_next`/`scopes[].first`；`resolveScopeVar`（resolve_variables.zig）显式沿 `scopes[].parent` 上溯 | zjs 链接关系自构造起即正确且只含本 scope 变量，无需收尾重链 pass；QuickJS 的「空 scope 继承父链」由查找方上溯替代 | 无。按构造等价 |
| `add_eval_variables`（quickjs.c:33694：编译期把调用方全部绑定闭包化，`capture_var` 标记所有 locals） | 运行时 eval overlay：`eval_ops.zig` 把 caller frame 的 `eval_local_names`/slots/`var_ref_names`/refs 传入嵌套执行，`getVar`/`putVar` 按名查 overlay | 编译期闭包转换 vs 运行时按名叠加视图；zjs 无需预捕获 caller 全部 locals（overlay 直读 frame 槽位） | eval 路径按名扫描慢于索引访问，但 direct eval 是冷路径；语义等价 |
| `add_module_variables`（quickjs.c:36073：模块 global vars 入 closure，`export_entries[i].var_idx` 编译末期定索引） | 解析期 `ensureTopLevelModuleDeclClosureVar`（zjs_parser.zig）为顶层模块绑定建 `module_decl` closure_var；实例化期 `buildModuleVarRefs`（exec/module.zig）按 `var_ref_names` 名字解析到模块 cell（import → 他模块 cell = live binding） | export → 索引的绑定从编译末期推迟到模块实例化期，按名而非按 `var_idx` | 实例化期 O(绑定数) 名字解析，一次性；稳态访问同为 `get_var_ref` 索引访问。live binding 探针通过 |
| `capture_var`（quickjs.c:33022：置 `is_captured` + 分配 `var_ref_idx`，`b->var_ref_count` = 被捕获自有局部数；运行时 `sf->var_refs[]` 存开放 JSVarRef） | `ensureClosureChain`（zjs_parser.zig）置 `VarDef.is_captured`；无 `var_ref_idx`——cell 由 `ensureLocalVarRefCell`（slot_ops.zig）就地装箱在局部槽内 | QuickJS 是「旁路 var_ref 表 + 栈槽开放引用」模型；zjs 是「槽内 boxed cell」模型，捕获状态即槽位内容，无需帧侧 var_refs 表寻自有局部 | 无正确性差异。字段语义差异：zjs `var_ref_count` = closure_var 数（父引用数，供 frame.var_refs 定容），不是 QuickJS 的被捕获自有局部数 |
| `OP_enter_scope` 降级（quickjs.c:34476：对 scope 内 lexical 发 `set_loc_uninitialized`，函数声明发 `fclosure` 重实例化） | `resolve_variables` 的 `enterScopeRefreshSize`/`writeEnterScopeRefresh`：对 scope 内被捕获槽发 `close_loc`（detach cell），对 `.normal` lexical 发 `set_loc_uninitialized`（TDZ 重 arm） | zjs 把 close 也放在 scope **入口**（QuickJS 在 `leave_scope` 出口 + break/continue 跳转点 `close_scopes`，quickjs.c:27948）。入口位置支配一切重入路径（正常回边/continue/内层 break），单点发射即可；因局部槽不复用、cell 仅经闭包可达，观察等价 | 无。函数/箭头体块（每帧仅进入一次，且提升函数初始化先于体码捕获槽位）显式抑制发射（`suppress_block_enter_scope`） |
| `OP_leave_scope` 降级（quickjs.c:34510：对 `is_captured` 变量发 `close_loc`） | 解析器在 for 头作用域回边处 `emitCloseCurrentScopeLexicals`；块作用域由上行 enter_scope 入口刷新覆盖；`removeUncapturedCloseLoc`（finalize.zig）以 `localIsCaptured`（resolve_variables.zig，共享谓词）剔除未捕获槽的 close_loc | 出口 close 改为入口 close + for 头回边 close 的组合 | 无（语义探针覆盖 per-iteration 捕获、TDZ 重入、capture-before-decl、catch/switch/嵌套循环） |
| 编译期载体：`JSFunctionDef`（含 `byte_code` DynBuf）→ pass 原地改写 → 一次 memcpy 进单块 `JSFunctionBytecode`（quickjs.c:36219-36294） | `FunctionDef`（变量/scope 元数据 + `byte_code`）→ finalize **move**（非拷贝）code/atom_operands 进 `Bytecode` lowered 载体 → pass 改写 → 一次拷贝进单块 `core.FunctionBytecode.block` | zjs 多一个 `Bytecode` 结构，但 move 后拷贝次数与 QuickJS 相同（仅终态打包一次）；`Bytecode` 同时是 VM 执行视图类型（`asBytecodeView` 借用切片），贯穿全部 exec 签名 | 收敛为「VM 直接执行 FunctionBytecode」= exec 层签名级重写，收益仅省一个借用视图构造（无堆分配），不实施，记录为既定设计 |
| 顶层脚本执行载体 | 顶层经 `runWithFunctionDefRuntime` 直接执行解析器产出的 `Bytecode`（不物化 `FunctionBytecode`）；嵌套函数经 `createFunctionBytecode` 物化 | QuickJS 顶层同样物化 `JSFunctionBytecode` | 顶层少一次打包；module/debug 元数据留在 `Bytecode` 上（`module_record`/`debug_table`），属同一既定设计 |

## 4. VM Execution

当前 VM dispatcher 是 `src/exec/zjs_vm.zig`。Phase 1 执行模型改进已落地：

- **连续 VM 栈**：`JSRuntime.vm_stack`（`VmStackArena`）为 `[args | locals | operand]` 提供
  arena 窗口；普通字节码调用的 operand stack 与 frame locals/args 优先从 arena 雕刻，
  替代每调用 `Stack.init` 堆分配。generator/async 帧**有意豁免** arena：
  挂起经 `saveGeneratorExecutionState` 做零拷贝所有权转移（帧缓冲指针挂入
  generator 对象，resume 装回），arena 窗口是借用的、无法转移所有权；QuickJS
  的 `async_func_init` 同样创建即堆分配，从不入栈。把 generator 帧塞回 arena
  的唯一方案（挂起拷出/恢复拷回）会把成本从「每 generator 一次分配」搬到
  「每次 yield 两趟 memcpy + 全部按地址持有的根重定向」——负优化，不做。
  若未来 profile 证明 generator 帧分配是瓶颈，处方是 size-class 帧池，仍非
  arena。同理 `zjs_parser.zig`（15.5K 行单体 parser/emitter）是参照形态——
  QuickJS 的 parser 同为单体且 `ParseState` 贯穿全部产生式，强拆只会重新
  制造跨文件状态穿线。
- **同循环内联调用**：`src/exec/inline_calls.zig` 的 `Machine` 在 `dispatchLoop` 内
  push/pop 字节码帧，替代递归 `runWithArgsState`；`catch_target` 按 inline 帧记录。
- **零拷贝参数**：`Frame.initArgumentsFromStack` 从 operand stack 转移参数所有权，
  仅 `argc < arg_count` 时补 `undefined`。
- **CallEnv**：`runWithCallEnv` 收敛原 25 参数 `runWithArgsState` 入口面。
- **热路径门控**：`-Dzjs_enable_opcode_profile=true` 才编译 per-opcode profile scope；
  `stopBeforePc` 仅在 generator resume 外壳生效；backtrace 使用 lazy name 解析。

- **真 TCO（帧复用）**：`op.tail_call`（及 tail 位置的非 %eval% 直接 eval 调用）在
  inline 帧（depth>0）上经 `Machine.tailCallReuse` 替换当前帧——call region 先移出垂死
  帧的 operand stack，`popTeardown` 后用共享的 `pushFrame` 重建，逻辑 call depth 恒定。
  带 direct-eval 绑定的 callee 也可内联（`pushFrame` 合并 var-ref 视图，镜像
  `callFunctionBytecodeModeState`）。parser 端 `rewriteTrailingCallAsTailCall` 以
  Phase 1 线性解码验证指令边界（修复 `push_i32` payload 误判），并覆盖条件分支下推
  （`?:`）、短路合流（`&&`/`||`/`??`，jump-to-end 路径保留 return 落点）与无 finally
  catch 体（rethrow marker 前置 drop）。`test262.conf` 已启用 `tail-call-optimization`。

仍走递归慢路径的 tail 目标（深尾递归会增长 native 栈）：L0 帧（generator/eval 外壳）、
arrow/class-constructor/跨 realm callee、`tail_call_method`。

Opcode family 仍拆到 `src/exec/vm_*.zig`：

- arithmetic: `vm_arith.zig`
- calls: `vm_call.zig`
- control flow: `vm_control.zig`
- eval/modules: `vm_eval_module.zig`
- exceptions/backtrace: `vm_exception_ops.zig`
- generators/async: `vm_gen_async.zig`
- literals: `vm_literal.zig`
- property opcodes: `vm_property.zig`
- regexp: `vm_regexp.zig`
- value operations: `vm_value.zig`
- opcode profiling helper: `vm_profile.zig`

The VM call runtime lives in `src/exec/call_runtime.zig`（原 `shared.zig`，
已改名并删除其转发别名层；调用点直接引用归属模块）。Splits
so far: `regexp_fastpath.zig`（RegExp 快路径）、`slot_ops.zig`（槽位操作）、
`builtin_glue.zig`（Math/Number/URI/JSON/collections/weak/Symbol/DataView
glue）、`error_stack_ops.zig`、`forof_ops.zig`（迭代器记录与关闭路径）；
`vm_property.zig` 按 globals/locals/field/ref/private 拆为五个子模块
（13135 → 2125 行，达成 <3K 目标）。call_runtime.zig 当前约 8.3K 行（自
15.3K），剩余大簇为 call runtime 核心、direct-eval 支撑、generator 恢复、
worker 与 Atomics 等待机制，继续按域收敛。

RegExp 语义状态：duplicate named groups（alternation 路径验证 + `\k` 多发射 +
groups matched 优先）、quantifier 每迭代 capture 清零（对齐 RepeatMatcher，
超越 QuickJS）、v-flag ClassSetExpression（嵌套类/差集/交集/运算符纪律）与
`\q{}` 字符串集合均已实现；`test262.conf` 仅余 properties-of-strings 类排除
（需要 Unicode 序列枚举数据）。

Frame state is in `src/exec/frame.zig` and operand stack state is in
`src/exec/stack.zig`. `Frame` includes small inline argument buffers
(`inline_args: [4]JSValue`) for common call shapes, plus locals, args, var refs
and eval-specific binding snapshots.

Exception handling uses both Zig errors and VM-level catch handling:

- uncaught JS exceptions bubble through Zig error returns.
- catchable runtime errors are routed by VM catch-target handling.
- backtrace source locations resolve through `source_loc_slots` and `pc2line_buf`
  where available.

## 5. Object Shapes And Property IC

Object-shape state lives in `src/core/shape.zig`; IC slot storage lives in
`src/core/ic.zig`, with `src/bytecode/ic.zig` kept as a compatibility import path.

Property opcode fast paths are implemented in `src/exec/property_ic.zig` and used
from `src/exec/vm_property.zig`. Current IC behavior is shape/version guarded and
tracks the states:

- `empty`
- `mono`
- `poly`
- `mega`
- `invalid`

The active IC covers own/prototype data-property fast paths and records feedback
through `core.OpcodeProfile`. It is not a call inline cache and it is not JIT
metadata. Builds can disable property IC with `-Dzjs_enable_ic=false`.

## 6. Modules, Promises, And Jobs

Execution support beyond the VM loop is split under `src/exec/`:

- `module.zig` and `module_graph.zig`: module records, linking/evaluation and
  graph lifecycle.
- `promise.zig` and `promise_ops.zig`: Promise objects and abstract operations.
- `jobs.zig`: job queue integration.
- `call.zig`, `construct.zig`, `eval.zig`, `eval_entry.zig`: call/eval/construct
  entrypoints and binding behavior.

## 7. Host Runtime Policy

Host/runtime policy helpers live in `src/runtime/` and are re-exported through
the public runtime namespace:

- `event_loop.zig`: timers, file-descriptor handlers, signal handlers and job
  draining around a `JSContext`.
- `cleanup.zig`: Atomics waiter and worker cleanup helpers.
- `modules.zig`: file-based module graph evaluation and specifier resolution.
- `plugin.zig`: native plugin loading and installation helpers.
- `buffer.zig`: buffer/ArrayBuffer host operations.

This layer is separate from `src/core/`; core runtime/context/value ownership
must stay independent of host event-loop and plugin policy.

## 8. Validation Map

Use the narrowest validation that covers the changed surface:

```sh
zig build zjs --summary all
zig build smoke --summary all
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build test262-gate --summary all
zig build architecture-check --summary all
git diff --check
```

For parser, runner, execution, or semantic compatibility changes, run a focused
test262 slice before relying on the full gate.
