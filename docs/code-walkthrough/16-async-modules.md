# 16 — Promise、async/generator、模块图、using/disposable

本册把 **异步与模块** 拆开讲：Promise 抽象操作、async 函数/生成器、ES 模块链接求值、以及显式资源管理 opcode。语义权威仍是 ECMA-262；QuickJS（`quickjs.c:53415-54663` Promise、`quickjs.c:30525-31563` 模块、`quickjs.c:21345-21706` async generator）是对照实现。

子文件：

| 文件 | 覆盖 |
| --- | --- |
| [16-promise.md](16-promise.md) | `promise_ops.zig`、`promise_builtin_ops.zig`、`async_generator.zig`、`async_completion.zig` |
| [16-module.md](16-module.md) | `module.zig`、`module_graph.zig` |
| [16-disposable.md](16-disposable.md) | `using_ops.zig`、`disposable_ops.zig` |

函数级正文在子文件。这里只钉分层、FIFO 与链接/求值协议，以及 `using` opcode 怎么落到资源栈。

## 1. 分层：core 记状态，exec 跑算法

```
core/promise.zig          造 Promise 对象、fulfilled/rejected 原语、unhandled 记账
core/jobs.zig             Runtime FIFO：Job / Queue / Payload 标签
core/module.zig           ModuleRecord 身份、status、export cell、registry
        ▲
        │  禁止 core 调 VM
        │
exec/promise_ops.zig      NewPromiseCapability、then、combinator、async 函数
exec/promise_builtin_ops.zig  NativeEntry 表（resolve/all/then/catch/finally）
exec/async_generator.zig  AsyncGenerator 请求队列与 resume
exec/async_completion.zig Machine 拥有的 async 完成根（与 callee arena 无关）
exec/module.zig           安装、链接、声明实例化、单步求值、namespace
exec/module_graph.zig     宿主加载、dynamic import job、TLA 续体排水
exec/using_ops.zig        ext0 字节码：using create/add/dispose + 回收 opcode
exec/disposable_ops.zig   DisposableStack / AsyncDisposableStack 算法
src/event_loop.zig        宿主循环：定时器 / fd / 再调 drainPendingPromiseJobs
```

`core/jobs.zig` **不含 VM 调用**。exec 安装 runner、消费 payload。宿主 `JSContext.runJobs` / `zjs.job.drain` 最终落到 `promise_ops.drainOnePendingJob`。

## 2. Promise jobs vs `core/jobs.zig`

ECMA-262 的 Jobs 是「稍后跑一次的抽象任务」。zjs 把它钉成 Runtime 上的**类型化 FIFO**，不是 JS 可调用对象。

`core/jobs.Job`（`src/core/jobs.zig:147`）公共字段：

- `runtime` / `realm: RealmRef`：执行 realm 跟**登记时的 context**走，不跟排水宿主 context 走。
- `payload: union(enum)`：`generic` / `promise` / `promise_reaction` / `promise_thenable` / `promise_settlement` / `dynamic_import` / `atomics_waiter` / `finalization` / `async_resume`。

`promise_ops` 的职责是：

1. **构造** typed job（`Job.initPromiseReaction` 等，无失败的 JSValue 搬家）。
2. **先 reserve 再 publish once-guard**。resolving function 赢了 `[[AlreadyResolved]]` 之后若反应准备 OOM，FIFO 里留下 `promise_settlement` 续体；原 resolving pair 可以死。
3. **执行** `drainOnePendingJob`：按 payload 分发到 `promiseReactionJobCall` / `promiseThenableJobCall` / `asyncResumeJobCall` / `dynamicImportJobRun` 等。OOM 可重试的条目 `prependReserved` 回队头，用户回调不重跑。

对照 QuickJS：`JS_EnqueueJob` / `JS_ExecutePendingJob`（`quickjs.c` Runtime job list）。zjs 的分叉是 payload 有类型、有 phase（`PromiseReactionPhase` / `PromiseThenablePhase`），专门扛「once-guard 已发布、结算还没写完」的 OOM。

**不是 job 的东西**：

- Promise 对象本身在 `core/promise.zig`（payload：result / reactions / already-resolved 共享状态）。
- 反应记录是 `class_payload_kind = promise_reaction_record` 的普通对象，挂在 pending promise 的 reactions 数组上。
- 模块 TLA 续体是 `module_graph.ModuleContinuation` 原生数组，**另有** `ContinuationRoots` 向 tracer 登记；它和 FIFO 交替排水（`drainModuleJobLoop`），但不是 `Job` 条目。

排水入口：

| 调用方 | 做什么 |
| --- | --- |
| `drainOnePendingJob` | 恰好一条 typed FIFO |
| `drainPendingPromiseJobs` | FIFO + signal/rw/timer/atomics，直到空 |
| `src/event_loop.zig` | 事件循环一轮后调 `drainPendingPromiseJobs` |
| `module_graph.drainModuleJobLoop` | 一条 TLA 续体 ↔ 一条 FIFO/host 事件 |

## 3. 模块：加载 → 链接 → 求值

`ModuleRecord.status`（`src/core/module.zig:23`）：`unlinked` → `linking` → `linked` → `evaluating` → `evaluated` | `errored`。

**加载（preload）** 在 `module.preloadFileModuleGraph*` / `module_graph.preloadFileModuleGraphWithHostHooks*`：

- 解析源文成 `parser.ModuleArtifact`。
- `installParsedModuleArtifact` / `installResolvedModuleArtifact` 收成 registry 一代。
- 递归解析 `./` `../` 绝对路径；`node:` 原样；`with { type: json|text|bytes }` 或 `.json` 后缀走合成模块（registry 名 `path#type=json`）。
- 请求边 `setRequestModuleNoFail`，全部解析完 `markRequestsResolvedNoFail`。
- 后序路径列表给求值用。

**链接（`linkModule`）** 是 Tarjan SCC（对照 qjs `js_inner_module_link`）：

1. 未链接依赖 DFS；环上用 `link_dfs_index` / `link_dfs_ancestor_index`。
2. 先校验全部 indirect export（缺导出 / 歧义的诊断顺序对齐 qjs）。
3. `wireModuleImports`：把 import 槽接到被导出 `VarRef`，namespace import 写成 namespace 对象。
4. `retainLocalExports` 钉住本地导出 cell。
5. `runModuleDeclarationInstantiation`：模块函数 `this=true` 跑声明实例化（var/function 绑定）。
6. SCC 根弹出栈，成员 `status = .linked`。失败则 `rollbackActiveLinkStack` 回到 `unlinked`。

**求值（`runModuleEvaluationStep` + `module_graph` 调度）**：

- 源模块用 generator 形 continuation 跑模块函数；`suspend_on_module_await = true`，TLA 的 `await` 把帧停在 generator 上。
- 合成模块没有字节码，preload/init 写好 default cell 后直接 `evaluated`。
- 后序求值；依赖还在 TLA 上则 `enqueueDeferredModuleStart`。
- `createModuleAwaitReactionPromise` 把 awaited 值包成内部 then，兑现后在**当前 reaction job 内** resume（对齐 qjs async module continuation）。
- 失败缓存 `record.eval_exception`，后续 import 重抛，不重跑函数体。

**dynamic `import()`**：`evaluateImportCall` 同步校验 `options.with`，然后 `enqueueDynamicImportJobWithAttributes` 把 `[resolve, reject, basename, specifier, attributes]` 放进 `Job.dynamic_import`。job 里才 `JS_LoadModuleInternal` 同类工作，避免 `js_evaluate_module` 递归（qjs `quickjs.c:31155` 注释）。

## 4. using / 显式资源管理 opcode

opcode 空间：生产布局把 ERM 和一批冷 opcode 收进 **`ext0` 载体**，第二字节是 `bytecode.opcode.ext0_sub`（`src/bytecode.zig:517`）。热路径 `tailcall_dispatch` 把 `ext0` 交给 `using_ops.execVm`（`tailcall_dispatch_colds.zig:526`）。

| `ext0_sub` | 语义 |
| --- | --- |
| `create` (0) | 造内部 async-capable disposable stack，压栈 |
| `add` (`>= 64` + hint) | 栈顶 `[stack, value]`：sync 走 `usingAddSyncResource`，async 走 `usingAddAsyncResource` |
| `dispose` (1) | 正常完成：倒序 dispose，结果压回 |
| `dispose_throw` (2) | 异常完成：第二操作数是 pending throw，合成 `SuppressedError` |
| 3–20 | 回收来的冷 opcode（`to_object` / `to_propkey` / stack perm 等），与 using 无关，只是同平面 |

资源寿命在 `disposable_ops`：sync 直接调 `[Symbol.dispose]`；async 用 Promise capability + `performPromiseThen` 链式 await 每个 `[Symbol.asyncDispose]`。parser 的 `using` / `await using` **不**走用户可见的 `new AsyncDisposableStack()`，只复用同一套 payload。

Promise 调度仍在 `promise_ops`；`using_ops` 只拥有/弹出 VM 操作数，失败经 `handleCatchableRuntimeError` 进当前 catch。

## 5. async 函数与 async generator

- **async function**：`asyncFunctionStart` 造 Promise + generator 形 continuation；体停在 `OP_await` 时 `asyncFunctionAwait`。已兑现的原生 Promise 走 typed `async_resume` job（不定阅 `then`）；pending/thenable 走内部 `performPromiseThen`（undefined resolving funcs，qjs `js_async_function_resume`）。
- **async generator**：请求 FIFO 在 generator 对象 payload（`AsyncGeneratorRequest`）。`asyncGeneratorEnqueue` 先造 capability（可观察 then-getter tick），再 `resumeNext`。yield 操作数的 await 是 driver trampoline（`.yield_operand`）；`yield*` 的 await 已在字节码里。
- **async completion store**：`async_completion.Store` 是 Machine 上的根数组，溢出按 16 槽 chunk 分配，与 callee arena 解耦。

## 本册不讲什么

- `core/jobs.zig` / `core/promise.zig` / `core/module.zig` 的函数体在 10 册。
- opcode 分发在 11–12 册；这里只讲 `using_ops.execVm` 吃到的 sub。
- 事件循环 fd/timer 在 18 册；本册只说明它如何排 Promise job。

## 覆盖核对

- 清单函数数: 323（`promise_ops` 110 + `promise_builtin_ops` 5 + `async_generator` 15 + `async_completion` 5 + `module` 61 + `module_graph` 78 + `using_ops` 7 + `disposable_ops` 42）
- 本组标题覆盖: 323（含子文件，noinline 函数已计入）
- 未覆盖: 无
