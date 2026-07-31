# ZJS Current Architecture Snapshot

本文记录当前源码中的架构状态，而不是历史路线图、口号式目标或未落地的
设计承诺。语义参考仍是 QuickJS；验证边界以根目录 `test262.conf`、
`test262/` 和 Zig regression 为准。

## 1. Runtime And Ownership

当前运行时核心在 `src/core/`：

- `runtime.zig`: `JSRuntime`、`JSContext`、根追踪、GC 调度和宿主资源。
- `value.zig`: `JSValue` 表示与引用计数入口。
- `object.zig`: JS 对象、属性表、prototype、class payload 和 child-edge tracing。
- `bytecode.function_bytecode`: GC 管理的函数字节码对象。
- `gc.zig`: GC registry、policy、外部内存记账和统计。

已落地的生命周期模型是：

- 非原子引用计数负责大多数对象的即时释放。
- `runObjectCycleRemoval` / `tryRunObjectCycleRemovalWithValueRoots` 负责
  root-aware 的对象与 `FunctionBytecode` 环清理。
- `ValueRootFrame` / `ValueRootBuffer` / `ValueSliceRoot` 是宿主边界与 builtin
  在途值使用的显式根（挂到 `JSRuntime.active_value_roots`）。
- VM 运行帧的 operand stack / locals / args / var refs **不再经 per-frame
  root-scope 登记**：它们由 `FrameSlab` carve 帧自有、`Frame.deinit` 确定性释放，
  运行帧靠 refcount-on-push 保活（对齐 qjs：运行帧 `cur_sp=NULL` 不扫，仅扫挂起
  async/gen 帧）。
- 宿主持有跨调用生命周期的值时，必须使用 public API 中的 handle /
  persistent-root 机制，而不是裸保存 `JSValue`。

当前没有 nursery、moving、generational 或 concurrent collector。GC 是
QuickJS 风格的非原子 RC + intrusive-list cycle removal；`gc.Policy` 中的
concurrent/selective 字段均为关闭状态，不能当作已实现能力。

关键 64-bit 固定布局为：

- `gc.Metadata` 8-byte allocation prefix；
- `GCObjectHeader` 16-byte intrusive links；
- `Object` 64 bytes，含 24-byte class union；
- `Shape` 56-byte header + inline FAM；
- `shape.Property` 8 bytes；
- `FunctionBytecode` 96-byte QuickJS core header，debug 与 zjs-only state
  置于可选 inline tails。

Weak object identity 使用单调递增 id 和双向 runtime maps，避免地址复用 ABA；
这是相对 QuickJS weakref list/count 的安全实现差异，也是需要单独测量的
side-table 成本。

`JSValue` 永久支持两种表示。64-bit 默认是 16-byte payload + signed tag；
`-Dzjs_nan_boxing=true` 选择 8-byte、48-bit payload 的 zjs encoding。alternate
模式守护语义和所有权，但不是 QuickJS narrow representation 的 bit-level ABI。
`test-altrepr` 必须持续守护相反表示。

## 2. Parser And TypeScript Erasure

当前 parser 在 `src/parser.zig`：

- `parser.compile` 是 public compile wrapper。
- `parser.lexer` 提供 lexer、source-kind 判断和 TypeScript erasure。
- `parser.Parser` 是 QuickJS-aligned parser/emitter namespace。
- `parser.diagnostics` 和 `parser.token` 提供位置与 token 支撑。

TypeScript 支持是语法擦除，不是类型检查器：

- `parser.compile` 根据 `SourceKind` 和文件名调用 `parser.lexer.shouldStrip`。
- 需要擦除时调用 `Lexer.enableTypeScript()`。
- `enableTypeScript` 设置 `is_typescript`，并由 `markTypeRanges` 生成
  `skipped_intervals`。
- lexer 在扫描时跳过这些区间，让 parser 消费近似纯 JS 的 token stream。

这条路径只应描述为“当前支持的 TypeScript 语法擦除”。不要在文档中承诺完整
TypeScript 语义、类型检查、source-map 等价物或固定性能提升百分比。

## 3. Bytecode Carrier

编译期载体是 `src/bytecode.zig` 的 `FunctionDef` 与 lowered `Bytecode`；
发布后的唯一生产执行载体是 GC-managed canonical `FunctionBytecode`。没有
单独的 `CodeBlock` 抽象。编译期数据包括：

- opcode bytes: `code`
- constants: `constant.Pool`
- atom operands
- args、vars、var refs、global vars、private names
- module metadata
- `pc2line_buf`、`source_loc_slots`、`debug_table`
- module/debug/source-position metadata

pipeline 入口在 `src/bytecode.zig` 的 `pipeline` namespace：

- `resolve_labels`
- `resolve_variables`
- `stack_size`
- `pc2line`
- `finalize`

`stack_size.zig` 负责按字节码图计算最大 stack depth，并验证 underflow、
overflow、stack mismatch 和无效 opcode 等错误。它不是完整 JIT-style GC
stack-map 系统。

### 3.1 与 QuickJS 的当前边界

- QuickJS real opcode 顺序保持稳定；zjs 仅在尾部增加 4 个 explicit-resource
  management opcode。
- script、eval、nested function 和 module root 都发布 canonical
  `FunctionBytecode`。
- zjs core header 对齐 QuickJS 的 96-byte offset，但另有 optional 32-byte
  debug tail 和 8-byte `call_facts/script_or_module` extension。
- direct eval 的 caller-binding overlay、FunctionBytecode call/leaf facts 和
  explicit-resource opcode 是需要单独验证的实现差异。

完整字段级对照见
[`qjs-align/SUBSYSTEM-DIFFERENCE-BASELINE-2026-07-27.md`](qjs-align/SUBSYSTEM-DIFFERENCE-BASELINE-2026-07-27.md)。

## 4. VM Execution

当前 VM dispatcher 是 `src/exec/zjs_vm.zig`。当前执行模型：

- **连续 VM 栈**：`JSRuntime.vm_stack`（`VmStackArena`）为 `[args | locals | operand]` 提供
  arena 窗口；普通字节码调用的 operand stack 与 frame locals/args 优先从 arena 雕刻，
  替代每调用 `Stack.init` 堆分配。generator/async 帧**有意豁免** arena：
  挂起经 `saveGeneratorExecutionState` 做零拷贝所有权转移（帧缓冲指针挂入
  generator 对象，resume 装回），arena 窗口是借用的、无法转移所有权；QuickJS
  的 `async_func_init` 同样创建即堆分配，从不入栈。把 generator 帧塞回 arena
  的唯一方案（挂起拷出/恢复拷回）会把成本从「每 generator 一次分配」搬到
  「每次 yield 两趟 memcpy + 全部按地址持有的根重定向」——负优化，不做。
  若未来 profile 证明 generator 帧分配是瓶颈，处方是 size-class 帧池，仍非
  arena。同理 `parser.zig` 的单体 parser/emitter 是参照形态——
  QuickJS 的 parser 同为单体且 `ParseState` 贯穿全部产生式，强拆只会重新
  制造跨文件状态穿线。
- **同循环内联调用**：`src/exec/inline_calls.zig` 的 `Machine` 在 `dispatchLoop` 内
  push/pop 字节码帧，替代递归 `runWithArgsState`；`catch_target` 按 inline 帧记录。
- **零拷贝参数**：`Frame.initArgumentsFromStack` 从 operand stack 转移参数所有权，
  仅 `argc < arg_count` 时补 `undefined`。
- **CallEnv**：`runWithCallEnv` 收敛原 25 参数 `runWithArgsState` 入口面。
- **热路径门控**：`stopBeforePc` 仅在 generator resume 外壳生效；backtrace
  使用 lazy name 解析。`-Dzjs_enable_opcode_profile=true` 与
  `--profile-opcodes` 入口仍存在，但当前 dispatcher 没有接入 per-opcode
  scope，计数保持为零；修复并加入端到端门禁前不得把它当作可用 profiler。

- **尾调用字节码 ABI**：VM 仍支持手写/内部路径产生的 `op.tail_call` 与
  `op.tail_call_method`，inline 帧可经 `Machine.tailCallReuse` 替换当前帧；但默认源码
  compiler 与 pinned QuickJS parser 一样只产生普通 `call + return`，不在 parser 中
  按未来源码或 return 分支下推尾调用。`test262.conf` 因而跳过
  `tail-call-optimization`。若未来提供产品级 PTC 扩展，它只能是默认关闭、语义字节码
  完成后运行的独立 CFG pass，并与 baseline 单独 A/B。

当内部/手写字节码实际进入复用路径时，arrow target 与 `tail_call_method` 仍支持
inline-frame reuse：
字节码 arrow 与 QuickJS 一样在创建期把 lexical `this` / `new.target` 绑定为普通
closure cells（函数对象 rare slots 只保留给内部/兼容路径），method tail call
把 receiver 带入复用帧并经共享 `this` 装箱原语处理。仍走递归慢路径的 tail
目标（深尾递归会增长 native 栈）包括：L0 帧（generator/eval 外壳）、
class-constructor、跨 realm callee、async/generator target、native builtin，
以及故意走专门化路径的 simple fusion body。

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

The VM call runtime lives in `src/exec/call_runtime.zig`（原 `shared.zig`，
已改名并删除其转发别名层；调用点直接引用归属模块）。Splits
so far: `regexp_fastpath.zig`（RegExp 快路径）、`slot_ops.zig`（槽位操作）、
`builtin_glue.zig`（Math/Number/URI/JSON/collections/weak/Symbol/DataView
glue）、`error_stack_ops.zig`、`forof_ops.zig`（迭代器记录与关闭路径）；
`vm_property.zig` 按 globals/locals/field/ref/private 拆为五个子模块。
`call_runtime.zig` 当前约 7.9K 行，剩余大簇为 call runtime 核心、
direct-eval 支撑、generator 恢复与 Atomics 等待机制，继续按域收敛。

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

### 4.1 Standard Globals And Native Functions

QuickJS has no separate builtin or intrinsic layer. Standard objects are engine
bootstrap: `JS_AddIntrinsic*` hand-wires globals, constructors, prototypes, and
namespaces; each domain owns `JSCFunctionListEntry` arrays beside the C method
bodies; `JS_CallInternal` dispatches C functions through the function object's
payload (`realm`, `cproto`, `magic`, and function pointer).

The zjs target mirrors that shape:

- `core/host_function.zig` owns the neutral native-function ABI:
  `NativeCProto`, QJS-style function-pointer variants, and `InternalRecord`.
  Construct capability is encoded by the cproto; records do not carry a second
  generic call pointer or constructor flag.
- `exec/builtin_dispatch.zig` is the typed native C-function dispatch bridge.
  Realm/output/VM caller state is stack-local exec state; it is not part of the
  core record ABI. Every standard native record dispatches through its
  cproto-tagged function pointer, including the observable-coercion fallback
  for numeric cprotos.
- `exec/standard_globals.zig` owns the hand-written `JS_AddIntrinsic*`
  equivalent: global constructors, prototypes, namespaces, descriptors, and
  installation ordering. Constructor installation is an explicit ordered call
  sequence rather than a generic `ConstructorSpec` registry. `configureRuntime`
  is the setup interface for an existing runtime; core retains only a callback
  Adapter so it does not depend on exec.
- `exec/internal_builtins.zig` aggregates the compile-time record table for
  every engine-owned standard-native domain, including Atomics, performance,
  and every Promise static. Each domain function-list table lives beside
  the implementation it points at (`exec/*_ops.zig`). VM/property/call/
  coercion/iterator behavior stays in exec; pure algorithms stay in core/libs.
  The `.host` domain remains deliberately separate: it represents embedder
  helpers rather than standard native functions.
- The former `src/builtins/` compatibility layer has been retired. The
  architecture check rejects recreating it, and callers use the owning exec or
  core Module directly.

The architecture check guards all three completed migration boundaries: the
retired directory, the retired generic native-call ABI, and the retired generic
constructor registry.

`exec/call.zig`'s `HostFunction` enum is a separate mechanism: it dispatches
embedder/runtime host helpers (`print` output, destructuring runtime helpers,
the external-host-function registry, disposable-stack throw glue), not standard
ECMAScript native functions.

## 5. Object Shapes And Property Fast Paths

Object/shape state lives in `src/core/object.zig`, `shape.zig`, and
`property.zig`. `Object` is 64 bytes; `Shape` is a 56-byte header followed by
an inline property-array/hash-bucket FAM. Property values and shape metadata
remain index-compatible.

There is no property inline cache:

- `src/core/ic.zig` and `zjs_enable_ic` do not exist;
- FunctionBytecode has no IC slots;
- the retained `cached*` adapters in `src/exec/property_ic.zig` always miss.

`property_ic.zig` now contains non-cached direct own/prototype/global lookup and
simple-put helpers used by `vm_property*`. Every access validates the current
object/shape/property state; no receiver shape is retained per bytecode site.

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
- `cleanup.zig`: Atomics waiter cleanup helpers.
- `modules.zig`: file-based module graph evaluation and specifier resolution.
- `plugin.zig`: native plugin loading and installation helpers.
- `buffer.zig`: buffer/ArrayBuffer host operations.

This layer is separate from `src/core/`; core runtime/context/value ownership
must stay independent of host event-loop and plugin policy.

宿主/未来 runtime 功能接入的唯一路径是 `ExternalHostCall` + record 机制：
binding 层的 `ExternalHostCall`/`ExternalHostCallFn`/`ExternalHostFinalizer`
（public API 经 `zjs.host.Call`/`Function`/`Finalizer` re-export）注册进
`JSRuntime.external_host_functions` 的 `ExternalRecord` 表，函数对象只携带
`host_function.ids.external_host` kind + 注册 id，调用路径按 id 直达分发、
无字符串查找；finalizer 由 runtime 销毁时统一排空。引擎内部 `HostFunction`
枚举不再对宿主开放扩展。legacy qjs:std/qjs:os 宿主簇（`installLegacyStdOsGlobals`、
`hostCallStd*`/`hostCallOs*` 记录与 `exposeStdOsGlobals` 公共 API）已删除，
git 历史可找回；接口契约由 `src/tests/embedding_examples.zig` 的
"embedding external host function contract" 测试钉住（参数/this/返回值/错误
映射/finalizer 时机）。

Worker 的将来路径：引擎内的 `QjsWorker` 死簇（coordinator、postMessage/
poll/sleep、`cleanupWorkersForRuntime` 转发链）已删除，git 历史可找回。
将来真需要 Worker 时，Worker 本体——线程生命周期、postMessage、事件循环
集成——由下游 runtime（fun）经 `ExternalHostCall`/`zjs.host.*` 在宿主侧
实现，对齐 QuickJS 把 Worker 放在 quickjs-libc 的分工；zjs 侧届时要补的
是值序列化原语（对象图/循环引用/typed array/SharedArrayBuffer 共享/
transfer，对齐 `JS_WriteObject`/`JS_ReadObject`——当前无等价物）。Atomics
等待机制留在 exec，对齐 quickjs.c 把 `js_atomics_wait` 放在引擎内。

## 8. Validation Map

Use the narrowest validation that covers the changed surface:

```sh
mise run quick-check
mise run checkpoint-check
zig build test -Doptimize=ReleaseSafe --seed 0 --summary all
zig build engine-production-gate --seed 0 --summary all
git diff --check
```

For parser, runner, execution, or semantic compatibility changes, run a focused
test262 slice before relying on the full gate. `quick-check` is the default
inner-loop gate; `checkpoint-check` supersedes it before broader handoff, and
the production aggregate gate supersedes both at phase close.
