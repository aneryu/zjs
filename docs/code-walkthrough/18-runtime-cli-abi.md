# 18 — 事件循环、CLI、test262 runner

本册覆盖引擎边界上的宿主代码：`src/event_loop.zig` 的事件循环、`src/cli/` 的 `zjs` 与 `run-test262`。它们都不进 `core`：`src/core/` 不得依赖 `src/event_loop.zig`、`src/cli/`，也不得依赖 `binding`/`builtins`/`exec`/`parser`。

语义权威仍是 ECMA-262；QuickJS libc / `qjs.c` / `run-test262.c` 是对照实现。动态插件加载器已于 2026-09-06 删除（owner D8），公开宿主函数只走 `zjs.native`。叶签名是引擎私有 `LeafSig`，在 08 / 13 册。

## 分层地图

```
zjs / zjs-profile                    run-test262 / test-runner
        │                                      │
        ▼                                      ▼
 src/cli/zjs.zig                      src/cli/run_test262.zig
   parseArgs / main                     prepareSelection / workers
   eval 或 file 模块图                   installTest262Globals
        │                                      │
        └──────────────┬───────────────────────┘
                       ▼
              src/event_loop.zig
                EventLoop.install → JSContext.host_event_loop
                       │
                       ▼
              exec/promise_ops.drainPendingPromiseJobs
                1. 排空 job 队列（微任务 / Promise）
                2. 一个待处理 OS 信号回调
                3. 一个就绪 fd 读/写回调
                4. 一个到期定时器（或睡到下一期限 / atomics）
                5. 一个 Atomics.waitAsync 宿主完成
                再回到 1，直到四条宿主臂都空
```

`src/event_loop.zig` 就是嵌入方看见的门面（`zjs.runtime`：事件循环）。模块图、Atomics wake/cleanup、ArrayBuffer detach 由 CLI / test262 直接调 `src/exec/`。`src/cli/panic_policy.zig` 给两个二进制钉 ReleaseFast 的无符号表 panic。

## 分册目录

| 文件 | 覆盖 |
| --- | --- |
| [18-event-loop.md](18-event-loop.md) | `src/event_loop.zig` |
| [18-cli.md](18-cli.md) | `src/cli/zjs.zig`、`cli_process.zig`、`panic_policy.zig` |
| [18-test262.md](18-test262.md) | `run_test262*.zig`：选项、配置、名字、元数据、已知失败、源、host `$262.agent`、reporter、编排 |

## CLI argv 契约

`zjs` 的 argv 合同写在 `src/cli/zjs.zig` 的 `parseArgs` / `main` / `printUsage`，与 `AGENTS.md` 的 CLI contract 一条（`zjs -e "<script>"` / `zjs <file.js>`，参数缺失或非法打 usage 并非零退出）一致：

| 调用 | 行为 |
| --- | --- |
| `zjs -e "<script>"` | 把第二个参数当脚本源，`filename = "<eval>"`，`EvalMode.script`，`discard_script_result = true`。`-e` **不能**与 `--can-block` 同用，且 `rest` 必须正好两个词（`-e` + 源）。 |
| `zjs <file.js>` | 读文件（上限 64 MiB）。`.mjs` 或首 token 为 `import`（后不跟 `(`/`.`）/`export` 则当模块，否则脚本。文件名及其后参数成为 `scriptArgs`（含路径自身，对齐 qjs）。 |
| `zjs -m <file>` | 强制模块模式；其余同文件路径。 |
| 缺参 / 未知旗标 / `-h` / `--help` | `parseArgs` 返回 `error.Usage`；`main` 打 usage 到 stderr 并 **`exit(2)`**。 |

可选旗标必须出现在位置参数之前：`-d`/`--dump`、`-T`/`--trace`、`--profile-opcodes`、`--gc-stats`、`--gc-gate-settle`、`--gc-mark-footprint`、`--gc-block-census`、`--perf-json`、`--leak-check`、`--memory-limit n`、`--stack-size n`、`-I`/`--include file`、`--can-block`（仅文件模式）。读文件失败、引擎 init 失败、求值抛错走 `exit(1)`。成功路径默认 `exit(0)` 而不 `deinit` Runtime（短命进程把内存还给 OS；`--leak-check` 才显式拆循环/context/runtime 好让 GPA 验漏）。

`run-test262` 是另一条根：缺 `-c` 且没有任何选择器时 `error.Usage` → stderr + `exit(2)`。默认每测 20 s 超时。意外失败或 known-error 被修掉（`fixed != 0`）`exit(1)`，否则 `exit(0)`。

## 事件循环排空顺序

`EventLoop.runUntilIdle` 本身只调 `exec.zjs_vm.drainPendingPromiseJobs`。真正的宿主臂顺序在 `exec/promise_ops.zig` 的 `drainPendingPromiseJobs`（CLI 的 `DynamicImportState.runJobs` 走模块图的 `drainModuleJobLoop`，宿主臂顺序相同）：

1. **Job 队列排空**：`drainOnePendingJob` 循环直到 `job_queue` 空。这是微任务 / Promise reaction / 入队的 JS 回调。
2. **OS 信号**：`runNextOsSignalHandler` → `EventLoop.runNextSignalHandler`。`osSignalHandler`（`callconv(.c)`）只置 `os_pending_signals` 位图；真正的 JS 回调在 owner 线程这一臂执行。每次只跑**一个**匹配的 handler。
3. **fd 就绪**：`runNextOsRwHandler`。POSIX 用 `poll(2)`；Windows 只等 stdin CRT fd 0（对齐 `quickjs-libc.c`）。有待处理 job 或 atomics waiter 时 timeout=0（忙轮询宿主完成），否则睡到下一 timer 或无限等。每次只派发**一个**读或写回调。
4. **定时器**：`runNextOsTimer`。到期的一次性 timer 在调用前回队并临时挂 `ValueRootFrame`（生产 tracing 会擦标量根，回调必须在调用窗口内可见）。Promise 对象当回调时走 `settlePendingPromiseReaction` 而不是 `call`。没有到期项时，若存在 atomics waiter 则 `waitForAtomicsHostSignalUntil`，否则 `sleep` 到下一期限。
5. **Atomics 宿主完成**：`runNextAtomicsHostCompletion`。`waitAsync` 通知不能叫醒 `poll`/盲睡，所以这一臂与 timer 睡眠共用 Runtime completion event。

任一宿主臂返回 `true`（做了工作）就回到 1，先把新产生的微任务排完。这是 HTML / ECMA 的「先微任务、再宿主宏任务」在 zjs 里的落地，对照 QuickJS `quickjs-libc.c:2422-2627`。

拓扑：循环拥有 timer / rw / signal 的回调 `JSValue` 与 `RealmRef`；`output` 只是宿主借来的 writer。GC 经 `HostEventLoop.VTable.traceRoots` 访问这些槽。引用计数已退役，deinit 释放数组即可，不必逐值 `free`。

## test262 宿主 `$262.agent`

`src/cli/run_test262_host.zig` 实现 test262 的多 agent 协调器，不是引擎公共 API。

进程级 `Test262AgentCoordinator`（mutex + cond + agent 表 + report 表）跨 worker 线程共享。每个 `$262.agent.start(source)`：

1. 把 source ToString 拷到 `test262_gpa`（thread-safe DebugAllocator）。
2. 登记 `Test262Agent{ source, owner_runtime }`。
3. `std.Thread.spawn` + `detach` 跑 `test262AgentRun`。

agent 线程：新建独立 `JSRuntime`（`can_block = true`）、装自己的 `EventLoop`、再 `installTest262Globals`、`eval` 源、然后 `runJobs` 直到 `agent.done`。`setInterruptHandler` 看 `agent.done`，好让主线程 `cleanupTest262Agents` 打断在飞的 `Atomics.wait`。

| `$262.agent.*` | 作用 |
| --- | --- |
| `start` | 拉起 worker agent |
| `broadcast(sab)` | 把 SharedArrayBuffer 引用发给**同一 owner runtime** 且未 `done` 的 agent，`cond.broadcast` |
| `receiveBroadcast(cb)` | 当前线程必须是 agent；等 `broadcast_buffer` 或 `done`，再 `callFunction(cb, sab)` |
| `report(value)` | ToString 后入 report 队列 |
| `getReport` | 取出本 owner runtime 的下一条 report；空则 `null` |
| `leaving` | 置 `done` 并唤醒等待者 |
| `sleep(ms)` | 上限 60 s |
| `monotonicNow` | 醒时钟 ns → 毫秒 Number |

`cleanupTest262Agents` 在每测 teardown：给本 runtime 的 agent 置 `done`、`wakeAtomicsWaitersForRuntimes`（只改 mutex 保护的 `completion` 标量，不碰 JS 堆）、最多等 500×1 ms、扫 report、销毁 `thread_done` 的 agent。跨线程规则与 `JSRuntime` 单线程所有权一致：agent 有自己的 Runtime；协调器只传 SAB 引用和 UTF-8 report 字节。

同一文件还装 `$262.evalScript` / `createRealm` / `detachArrayBuffer` / `gc` / `IsHTMLDDA`，以及全局 `assert` / `Test262Error` / `verifyProperty*` / `setTimeout`。`setTimeout` 走已安装的 `HostEventLoop`。

## FNABI vs 已删除的 runtime plugin ABI

owner 2026-09-06 D8（设计稿 0.9）：**硬切**。下列路径已从树中删除，无过渡：

- `src/runtime/plugin.zig`（`Plugin.load` / dlopen）
- `src/binding/ffi.zig`（`CallFrame` / `HostServices`）
- `docs/runtime-plugin-abi.md`
- `tests/fixtures/*plugin*`
- 公共名 `zjs.host.*` 旧 FFI、`zjs.ffi`、`zjs.runtime.Plugin`

`src/event_loop.zig` 的测试钉死：`plugin` / `ffi` / `cleanup` 等内部名不得出现在嵌入门面。

**留下的公开面**只有：

- `zjs.native`（`managed` / `leaf` / `leafWithState` / `Class`）
- `JSContext.defineFunction` / `createFunction` / `defineClass` / `CallSite`

## 本册不讲什么

- `drainPendingPromiseJobs` 的 job 载荷分发在 16 册（Promise）。
- `NativeEntry` / `zjs.native` thunk 在 01 / 13 册。
- `src/libs/` 不在本册。
- test262 子模块用例正文不逐行讲；本册只讲 runner 与 host。

## 覆盖核对

- 清单函数数: 见当前 `src/event_loop.zig` + `src/cli/*`
- 零函数文件: `src/cli/panic_policy.zig`（正文有文件级讲解）
- 本文标题覆盖: 见各分册合计；以 `_check_coverage.py` 为准
- 未覆盖: 无
