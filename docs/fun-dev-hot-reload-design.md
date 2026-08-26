# fun / zjs Hot Reload 与开发时更新系统设计

版本：1.5（阶段 2 拆 P2A/P2B、阶段 1 zjs 侧工作量修正;无新设计。
1.4:roadmap v1.5 治理对齐——冻结项 21 修订为 SER-CORE+profile 模型）  
日期：2026-08-26  
状态：对抗性复审修订版（实现对账 + owner 裁决 + 三路对抗评审 + 序列化
条款同步——冻结项 21、§27.10、§37 W1 的「同一交付物」表述统一改指
SER-ARTIFACT profile,详见冻结项 21 v1.4 注;其余欠账仍开放,
见 process-model-design.md §20.2/§20.2a:state 默认值、
save-to-restored-state 指标、fire-and-forget 警示、A.11 接管等）  
替代版本：1.4  
涉及组件：fun、zjs、zabel、Native Plugin、CDP Inspector  
目标读者：fun/zjs 核心开发者、图形运行时开发者、Native Plugin 开发者

---

## 0. 审查与裁决记录

### 0.1 v1.0 → v1.1 对抗性审查

上一版方向基本正确，但存在若干可能导致实现过度复杂、语义承诺过强或无法可靠落地的问题。

v1.1 重点修正如下。

| 原设计 | 对抗性问题 | 修订结论 |
|---|---|---|
| Parallel Candidate Session 作为主要 Session Swap 方案 | 任意 top-level 代码仍可能写文件、发送请求或修改 plugin 状态，无法通用回滚 | 普通应用默认使用顺序 Session Reload；Shadow Session Swap 仅对显式适配的应用开放 |
| 将 Candidate Swap 描述为“事务式” | 只能保证 host binding 原子切换，不能回滚外部副作用 | 改称 Guarded Shadow Swap；只承诺 runtime-local atomic publication |
| Candidate 激活失败后切回 Standby | `activate()` 可能已经产生不可逆副作用，通用回滚不成立 | commit 中禁止执行用户代码；发布后不承诺回滚 |
| NativeHost 整体跨 Session 保留 | 容易让应用级资源和旧 JS wrapper 意外存活 | 拆分为严格 allowlist 的 HostCore、SessionHostView 和 SessionOwned 资源 |
| Active 与 Candidate 可同时使用 GPU | 未定义 Surface、Queue、cache 的并发和独占关系 | 增加 HostScheduler 和资源并发类别；Candidate 禁止 presentation |
| 使用 generation 检查解决异步安全 | generation 只能阻止调用 JS，不能完成 native 清理和资源释放 | 增加 SessionLease、Scope、CancellationToken 和 native-only completion |
| HMR callback 支持异步 | dispose、evaluate、accept 并发后状态机复杂，失败语义模糊 | v1 的 HMR callback 全部限定为同步 |
| self-accept 作为普通能力 | 现存 importer 不会自动获得新 lexical binding，容易产生半新半旧状态 | 只推荐 side-effect module、entry 和 framework-generated boundary 使用；编译器提供警告 |
| snapshot/restore 默认保留状态 | 快照可能阻塞、失败、过大或包含不兼容对象 | 状态迁移默认关闭，显式选择 `none`、`best-effort` 或 `required` |
| 第一阶段直接实现双 Session | 工程量大，遮蔽真正关键的 Session 生命周期问题 | 先实现 HostCore + Disposable Session + Sequential Reload，再逐步增加 HMR 和 Shadow Swap |
| commit 期间事件处理未定义 | 输入、网络、timer、GPU completion 可能丢失、重复或发往错误 Session | 引入 Epoch Barrier 和按事件类型定义的缓冲、合并、背压与丢弃策略 |
| HMR 是普通修改主路径 | 容易把 zjs module 系统设计成 HMR 专用结构 | HMR 保持为显式优化；Session Reload 仍是通用正确性基础 |

### 0.2 v1.1 → v1.2 实现对账与 owner 裁决

v1.2 将设计与 zjs `main`（`bce28d11`）的实现现状逐项对账，并由 owner 做出四项裁决。

**四项 owner 裁决（2026-08-26）：**

| 决策点 | 裁决 | 后果 |
|---|---|---|
| Shadow Swap 的 JS 线程模型 | **v1 砍掉 Guarded Shadow Swap** | 整章移入附录 A（未来工作，未冻结）；线程模型裁决推迟到有真实需求时；v1 主线只保留 Fast Refresh / HMR / Sequential Reload / Worker Restart 四层 |
| §26 与 FNABI v0.3 的关系 | **并入 FNABI** | plugin 生命周期以 `docs/fun-native-plugin-design.md`（FNABI v0.3）§22 为权威规范；本文只定义映射与增量；candidate_mode 等增量作为 FNABI v0.4 议题（附录 A） |
| bytecode 序列化器 | **显式交付物 + 与 typed plan 联合设计** | v1 每次 Reload 付全量 re-parse + re-compile；heap-independent artifact 为独立工作项 W1，序列化格式与 type-directed plan 的离线 emitter 输出联合设计（~~同一交付物~~ **v1.4 修订为 SER-CORE+profile 模型,见冻结项 21 注**） |
| CDP Inspector | **移出阶段 1，列独立工作项** | 阶段 1 MVP 不含 debugger；「zjs 最小 CDP backend」为独立工作项 W2，阶段 6 依赖之 |

**引擎现状对账要点（zjs main@`bce28d11`）：**

已具备、可直接使用：

- 多 `JSRuntime` 共存与独立销毁：per-runtime atom 表，无阻碍性 process-global 状态；destroy 路径断言加固（`assertIdleForTeardown`、销毁末尾 `!hasOutstandingAllocations()` 断言）。「Session = Runtime、销毁重建」今天即成立，泄漏是硬 panic 而非慢性漂移。唯一例外是进程级动态 class id 分配器（自旋锁保护、**永不回收、u16 上限即 `error.ClassIdExhausted`**）：HostCore 与 plugin 必须复用静态 class id 槽，不得每次 Reload 重新分配（§38.1 有对应压测行）。
- Interrupt：`JS_SetInterruptHandler` 等价物齐全，tail-call dispatch 的每个 backedge 与 call seam 均有检查点，可中断纯循环与纯递归代码，抛不可捕获 Interrupted。检查点执行的是每 Realm 的 cadence 计数器 tick（reset 值 10000），handler 每 10000 次 tick 才运行一次（§32）。
- Loader：`HostHooks { resolveModule, loadModule }`、scoped dynamic-import override、synthetic module、`import.meta`（含 `main`）均已存在。
- Teardown finalizer 枚举：qjs 式侵入链表 `gc_obj_list` 五阶段遍历，native payload finalizer 带 generation 戳内联执行。

缺失、属于真实工程量：

- bytecode 序列化为零：`FunctionBytecode` 内嵌 Realm 引用与 `JSValue` 常量池，atom id 直接编码在指令流内，跨 Heap 复用在结构上不可能，需要翻译层/序列化格式（→ 工作项 W1）。
- module registry 每 realm 单实例、按 atom 线性扫描、无公开 evict/replace 入口：多版本 ModuleInstance 与 UpdateOverlay 需要 registry 层重构（→ 阶段 3 引擎侧主要工作量）。
- CDP/inspector 实现为零（README 明示未实现）（→ 工作项 W2）。
- FNABI v0.3 的 PluginInstance/七态关闭机/纪元验证均为文档设计，`src/` 中尚无实现。

硬约束：

- Runtime 严格线程亲和（`owner_thread_id` 每次变更与销毁均断言，`tryDestroy` 返回 `WrongRuntimeThread`），不存在跨线程 Session 句柄。这是 Shadow Swap 被移出 v1 的直接原因之一（附录 A.0）。

**v1.2 其他修正（评审直接采纳）：**

1. §5.5 钉死 Session = zjs Runtime，删除共享 Heap 的 Realm 备选。
2. §27 补四项原语：root handle 表、跨 Heap 结构化状态序列化、module registry 多版本/evict、`origin_module_instance_id` 走 bytecode metadata 侧车（与 IC / typed plan 共享侧车设计）。
3. 「所有异步 callback 携带 Session/Epoch/Scope」拆为方向冻结 + 生产成本经 PERF-MECHANISM-LEDGER A/B 后冻结。
4. Sequential Reload 初始化失败：同一 Update 最多自动重试一次，之后 Overlay + 等待下一次保存，消除 reload 风暴（§12.2、§36）。
5. 语义修正四处：开发期 503 限定 `persistent_listener`（§12.2、§30）；Epoch Barrier 的 timer 行改为 HostCore 帧调度语义（§11.1）；Session teardown 前的 microtask/job drain 规则明确（§28）；内容寻址 cache 预热的幂等性豁免明确（附录 A.2）。
6. §41 冻结清单按裁决重写并增补。
7. §38 压力测试增加 `ZJS_GC_STRESS` 下 1000 次 Reload。

### 0.3 v1.2 → v1.3 对抗性复审

对 v1.2 执行三路独立对抗评审：①语义攻击（无上下文新鲜视角，专攻内部矛盾与不可实现承诺）；②v1.1→v1.2 修订完整性对账；③仓库锚定核查（逐条验证「现状对账」与 FNABI 引用）。共 22 条实质发现，v1.3 全部修复。要点：

| 发现 | v1.3 修复 |
|---|---|
| compile error「旧应用继续运行」与「compile 必须在新 Session 内」+「先销毁旧 Session」三角矛盾 | §12.1 流程重排：新 Session 先创建并完成 compile 预检（此窗口旧应用照常运行，引擎支持同线程多 Runtime 并存），成功后才进入 Reload 窗口；顺带把全量重编译成本移出窗口 |
| `dispose(reason)` 在所有流程中无调用点 | §12.1 第 9 步接线；§28 定义其在 QUIESCING 之前以特权 lease 执行；§36 补故障行 |
| 旧 Session 销毁后失败落入未定义的「无 Active」状态 | §12.2 定义 Vacant 模式：失败 Session 立即 teardown，事件按类型丢弃/降级，不无限缓冲 |
| 异步 factory 在事件暂停窗口内 await timer/IO 必然死锁 | §11 重构：区分 Reload 窗口（暂停外部输入派发）与 commit（仅指针切换、无用户 JS）；初始化中 Session 自身的 job/timer/IO completion 正常运转；新增 init 超时预算 |
| §28 掐断 completion 使 I/O drain 无法推进；cancel/drain 相抵；parked lease 无法 interrupt | §28 重写第 3-6 步：已归属 completion 继续投递至 drain 截止；区分可取消/在途 job；超时先 cancel 后 interrupt（§10.2 同步修正） |
| framework refresh 绕过 retired-memory 预算，纯 Fast Refresh 流内存无界 | §8/§33.1：预算覆盖 framework 与 HMR 两条留存路径，决策树统一前置检查 |
| debugger 四处矛盾（§16.1 直接 Reload；§8 顺序使 plugin 重建蒸发调试会话） | §8 把 debugger 检查提到 native 之前；§16.1 修正为延迟 apply；§29.4 补 tainted 与 `defer=false` 语义 |
| 未发布 Session 的 epoch 未定义 | §5.7：创建时预分配，发布生效，失败作废 |
| 主文 Shadow 残留（RETIRING 不可达、DRAINING 顺序、`allowed_phases`、Barrier timeout 措辞） | 逐处清扫或标注附录 A 专用 |
| prune 有 API 无流程；冻结项 10「apply 失败」边界含糊；冻结项 18 无定价失败分支 | §20 接线 prune；§41 逐条改写 |
| FNABI 引用三处不准（§26.3 误引 manifest；「已批准」；纪元条款出处） | 改为 §25.1 artifact identity + §11.5 兼容性 tuple；「已采纳的评审修订版（未冻结）」；注明 §17.2 条款外推 |
| `FunctionBytecode`「不得内联加字段」与既有 FAM tail 扩展机制不符 | §27.6 改为「不得改变核心 96B 偏移；新状态走 inline FAM tail / 侧车」 |
| interrupt cadence、teardown deferred finalizer 队列、动态 class id 分配器三个落地事实缺失 | §32/§28/§0.2 补全，§38 补压测行 |
| 附录 A 相对授权清单的 8 处收录差集、§19 术语撞名、验收/测试覆盖缺口 | 附录 A 补齐；「Pending ModuleInstance」；§38.1/§38.7/§39 补行 |

修订后的核心判断不变：

> **fun/zjs 的正确基础不是“任意代码都能原地热替换”，而是“JS Session 可以低成本、确定性地销毁和重建，同时昂贵且明确安全的 HostCore 可以继续存活”。**

v1.2 的补充判断是：

> **这个基础的引擎侧原语（多 Runtime、断言加固销毁、interrupt、loader 钩子）已经存在；v1 的主要工程量在 fun 侧的 HostCore 拆分与 BindingRouter，以及 zjs 侧的 module registry 多版本化。**
>
> （v1.5 修正：阶段 1 的 zjs 侧亦非零新增——主要新增 = Root Handle 表 API 与 epoch-safe deref/release，§27.8 明示该表现不存在。）

---

# 1. 摘要

fun / zjs 的 Hot Reload 应当是一套分层开发时更新系统，而不是单一的模块替换机制。

v1 的更新层级为：

```text
Framework Fast Refresh
        ↓ 不适用或无法证明安全
Explicit ESM HMR
        ↓ 不存在完整 accept boundary
Sequential Session Reload
        ↓ native、ABI、hang 或进程级状态变化
Worker Restart
```

Guarded Shadow Swap 作为未来体验优化移入附录 A，v1 不实现、不冻结。

各层的语义如下：

| 层级 | JS Heap | HostCore | 状态保留 | 适用范围 |
|---|---:|---:|---|---|
| Framework Fast Refresh | 保留 | 保留 | 框架判断兼容性 | fun-native 等声明式 UI |
| Explicit ESM HMR | 保留 | 保留 | `import.meta.hot.data` | 显式 accept 的 ESM |
| Sequential Session Reload | 替换 | 保留 | 可选结构化状态 | 所有普通 JS/TS 应用 |
| Worker Restart | 替换 | 替换 | 进程外持久化 | native、ABI、crash、hang |

默认策略是：

```text
能由 framework 明确处理
    → Framework Fast Refresh

否则存在完整 ESM HMR boundary
    → Module HMR

否则
    → Sequential Session Reload

native 或 ABI 变化
    → Worker Restart
```

---

# 2. 设计原则

## 2.1 正确性优先于表面状态保留

无法证明旧状态和新代码兼容时，不尝试保留任意 JS object。

允许重新创建：

- JS Heap。
- global object。
- module registry。
- Promise。
- closure。
- timer。
- listener。
- three.js scene object。
- JS native wrapper。

优先保留：

- Window。
- GPU Device。
- Queue。
- Surface。
- Inspector transport。
- 明确声明的 listener socket。
- 内容寻址的资源 cache。

## 2.2 HostCore 只能通过允许列表持久化

不能因为某个对象由 native 实现，就默认跨 Session 存活。

只有明确满足以下条件的对象才可进入 HostCore：

1. 不持有裸 JS pointer。
2. 生命周期不依赖某个 Session。
3. 可以重新创建每个 Session 的 JS wrapper。
4. 所有 callback 均通过 BindingRouter 路由。
5. 所有异步 completion 均携带 owner metadata。
6. 对多个 Session 的访问规则明确。
7. Worker Restart 时可以完整释放。

## 2.3 Session Reload 是正确性基础

即使未来 HMR 和 Fast Refresh 体验很好，仍必须保留完整 Session Reload。

它用于：

- 无 HMR boundary。
- HMR apply 失败。
- HMR 内存预算超限。
- top-level await。
- CJS。
- debugger paused。
- 状态不兼容。
- framework refresh 失败。
- 用户主动 invalidate。

## 2.4 HMR 不进入生产 hot path

生产模式中不应存在：

- 每次 builtin 调用的 generation branch。
- 每次 property access 的 export proxy。
- 每次函数调用的 HMR indirection。
- 多版本 ModuleInstance registry。
- `import.meta.hot` object。
- HotDataRegistry。

生产环境仍可保留必要的 Session ownership，以支持正常 shutdown 和异步安全，但不应承担开发期更新策略开销。

任何进入生产构建的通用机制（如每 job 的 owner metadata）必须走 PERF-MECHANISM-LEDGER，A/B 定价（qjs 为尺）后才可冻结实现形态。

---

# 3. 目标

## 3.1 功能目标

1. 保存 JS/TS 文件后自动更新应用。
2. transform、syntax 或 compile 错误时尽量保持旧应用运行。
3. 普通 JS 更新不重新创建 Window、GPU Device 和 Surface。
4. 支持明确边界的 ESM HMR。
5. 为 fun-native 提供 Framework Fast Refresh 基础。
6. 支持 GUI、three.js、Canvas、WebGPU、server 和长期 Program。
7. 与 CDP、source map、断点、REPL 协同（依赖工作项 W2 完成后）。
8. Native Plugin 或 ABI 变化时自动 Worker Restart。
9. 快速连续保存时只应用最新有效更新。
10. 长期开发过程中不产生无限 timer、listener、module 和 native handle 泄漏。

## 3.2 正确性目标

1. 已销毁 Session 的 JS callback 永远不会再次执行。
2. 旧 Session 的异步 completion 可以完成 native 清理，但不得重新进入 JS。
3. HMR 只在每条传播路径都有明确 boundary 时使用。
4. HMR 进入 dispose 阶段后发生错误，当前 Session 必须标记为 tainted。
5. commit 中不得执行任意用户 JS。
6. 持久化资源必须来自 HostCore allowlist。
7. GPU 资源必须等待 submission fence 后释放。
8. Native Plugin 不得在 process-global 状态中保存裸 JS Root。
9. 所有长期资源都有明确 Owner。

## 3.3 开发体验目标

1. JS-only Reload 不关闭窗口。
2. GUI 在 reload 期间保留最后一帧。
3. 错误由 Native Error Overlay 展示。
4. CDP endpoint 尽量保持稳定（W2 落地后）。
5. 日志明确说明本次选择 HMR、Session Reload 或 Worker Restart 的原因。
6. 无法安全保留状态时，系统自动降级，而不是静默产生半旧半新状态。

---

# 4. 非目标

第一版不实现：

1. 任意 JS Heap 自动迁移。
2. 任意 closure 跨 Session 保存。
3. 任意 class instance 自动升级。
4. 任意外部副作用事务回滚。
5. 通用文件写入、数据库写入或 HTTP 请求撤销。
6. Native Plugin 通用 `dlclose` 热卸载。
7. CJS 模块级 HMR。
8. top-level await 模块图的局部 HMR。
9. 通用 WebAssembly instance 热替换。
10. 所有 ESM export 的自动代理转发。
11. Worker Restart 后继续保留进程内 GPU Device。
12. 对第三方 native library 生命周期进行隐式推断。
13. Guarded Shadow Swap（v1.2 裁决移出，见附录 A）。

---

# 5. 术语与生命周期

## 5.1 DevCoordinator

位于 App Worker 外部，负责：

- FileWatcher。
- zabel 增量转换。
- Build Cache。
- ModuleGraph。
- UpdatePlanner。
- Worker supervision。
- InspectorProxy（依赖 W2）。
- Update cancellation。

对于命名 Program，可由 fun daemon 承担。

对于 `fun dev`，由 CLI 父进程承担，不需要隐式创建命名 Program。

## 5.2 App Worker

实际运行 NativeHost 和 zjs Session 的进程。

v1 中一个 App Worker 内同一时刻只有一个 JS 执行线程（冻结决策，见 §41）。

## 5.3 HostCore

跨多个 Session 存活的最小 native 宿主集合。

```text
HostCore
├── Window / Input backend
├── Dawn Instance / Adapter / Device / Queue
├── Surface
├── Skia Graphite Context
├── Inspector backend（W2）
├── Native Error Overlay
├── Host Resource Cache
├── HostScheduler
└── 显式声明为 persistent 的 listener socket
```

HostCore 不得持有裸 JS object。

## 5.4 SessionHostView

每个 Session 对 HostCore 的隔离视图：

```text
SessionHostView
├── JS wrappers
├── BindingSet
├── SessionScope
└── Session-local resource handles
```

销毁 Session 时，SessionHostView 必须同步销毁。

## 5.5 zjs Session

可整体创建和销毁的 JS 执行隔离单元。

**冻结（v1.2）：Session = 一个完整 zjs Runtime。** 一个 Session 独占一个 JS Heap、一个 atom 表、一个 root set，通过 `Runtime.create` / `Runtime.destroy` 整体创建和销毁。

```text
ZjsSession（= JSRuntime）
├── JS Heap
├── Global Object
├── Module Registry
├── Job Queue
├── Promise/Microtask Queue
├── JS Native Wrappers
├── SessionScope
└── Inspector Execution Context（W2）
```

不采用共享 Heap 的 Realm/Context 作为 Session：zjs 的 Realm 层虽然存在且可独立销毁，但多个 Realm 共享同一 Heap 与 atom 表，销毁一个 Realm 不能整体回收其内存，不满足“确定性彻底销毁”的判据。

现状对账：多 Runtime 共存、独立销毁、销毁末尾零残留断言在引擎中已具备并有测试覆盖；Runtime 严格线程亲和（所有操作必须在 owner 线程执行）。

## 5.6 Session 状态

```text
CREATING
PREPARING
READY
ACTIVE
QUIESCING
RETIRING
DESTROYING
DESTROYED
TAINTED
FAILED
```

`RETIRING`（发布后旧 Session 并存 drain）仅在 Shadow Swap（附录 A）下可达；v1 Sequential 路径为 ACTIVE → QUIESCING → DESTROYING → DESTROYED，初始化失败走 FAILED → DESTROYING。

## 5.7 Session Epoch

每个 Session 在创建时即预分配下一个 epoch 值；发布（commit，原子替换 BindingSet）使其成为 `active_epoch`：

```text
epoch = 41   Active
epoch = 42   新 Session 创建时预分配；发布后成为 active_epoch
```

初始化期发起的异步操作携带该预分配 epoch。若 Session 初始化失败被销毁，其 epoch 作废：相关 completion 经 Session 存活性检查后只执行 native cleanup，不投递 JS。

Epoch 用于：

- callback 路由。
- event 派发。
- inspector context。
- stale completion 检测。
- 日志关联。

## 5.8 BindingSet

某个 Session 向 HostCore 提交的一组回调：

```text
BindingSet
├── onFrame
├── onResize
├── onPointer
├── onKeyboard
├── onRequest
├── onWebSocket
└── application tick
```

HostCore 始终只发布一个 Active BindingSet。

---

# 6. 总体架构

```text
fun daemon / fun dev parent
│
├── DevCoordinator
│   ├── FileWatcher
│   ├── ChangeCoalescer
│   ├── zabel Incremental Compiler
│   ├── Build Cache（transform 输出 / source map / 模块图元数据；
│   │                 bytecode 层待工作项 W1 落地后接入）
│   ├── ModuleGraph
│   ├── UpdatePlanner
│   ├── InspectorProxy（W2）
│   └── WorkerSupervisor
│
└── App Worker
    │
    ├── HostCore
    │   ├── Window / Input
    │   ├── GPU / Surface
    │   ├── Inspector Backend（W2）
    │   ├── Host Cache
    │   ├── Error Overlay
    │   └── HostScheduler
    │
    ├── BindingRouter
    │   ├── active_epoch
    │   ├── active_binding_set
    │   └── event barrier
    │
    ├── SessionManager
    │   ├── Active / Quiescing Session
    │   └── Initializing Session（compile 预检窗口并存，§12.1）
    │
    ├── ResourceScopeManager
    │
    └── HmrRuntime
        ├── ModuleVersionRegistry
        ├── HotDataRegistry
        ├── HotScopeManager
        └── HmrTransaction
```

DevCoordinator 必须位于 Worker 外部，因为：

- JS 无限循环时仍需检测文件变化。
- Worker crash 后仍需恢复。
- Native Plugin 改变时需要重建 Worker。
- 增量构建缓存不应随 Worker 丢失。
- Inspector 外部 endpoint 不应绑定单个 Session。
- 快速连续保存需要取消过期构建。

---

# 7. 更新模型

## 7.1 Framework Fast Refresh

适用于框架能够证明状态兼容的组件。

特性：

- 不替换 Session。
- 不替换整个模块图。
- 框架管理 component identity、hook signature 和 subtree remount。
- 失败后降级到 Module HMR 或 Session Reload。

## 7.2 Explicit ESM HMR

适用于显式声明：

```ts
import.meta.hot.accept(...)
```

的 ESM 模块图。

特性：

- 同一个 Session 内新旧 ModuleInstance 短暂共存。
- 只在所有传播路径都有 accept boundary 时使用。
- 无法安全完成时 Session Reload。

## 7.3 Sequential Session Reload

v1 唯一的 Session Reload 策略。

```text
停止旧 Session
      ↓
创建新 Session
      ↓
HostCore 保留
```

适用于所有普通应用。

（Guarded Shadow Swap 移入附录 A，v1 不实现。）

## 7.4 Worker Restart

适用于：

- Native Plugin binary 变化。
- fun/zjs ABI 变化。
- runtime native code 变化。
- Worker crash。
- 无法中断的 JS hang。
- Session teardown 无法收敛。
- GPU Device 或 native host 出现不可恢复错误。

---

# 8. 更新决策算法

```text
文件变化
   ↓
规范化并合并事件
   ↓
zabel 增量转换
   ↓
比较 runtime output hash
   ↓
生成 ChangeSet
```

推荐决策顺序：

```text
1. runtime output 未变化
       → DiagnosticsOnly

2. debugger 正暂停
       → 只 build，延迟 apply
         （含延迟自动 Worker Restart；强制 Restart 可绕过，§29.4）

3. native binary、ABI 或 Worker 配置变化
       → WorkerRestart

4. 当前 Session 已 tainted
       → SessionReload

5. retired 内存预算已超（framework 与 HMR 共用，§33.1）
       → SessionReload

6. framework adapter 可证明安全
       → FrameworkFastRefresh

7. ESM HMR plan 完整
       → ModuleHMR

8. 其他情况
       → SequentialSessionReload
```

伪代码：

```zig
fn planUpdate(
    change: ChangeSet,
    runtime: RuntimeState,
) UpdatePlan {
    if (!change.runtime_output_changed) {
        return .diagnostics_only;
    }

    if (runtime.debugger_paused) {
        // 含自动 Worker Restart 在内全部延迟；强制 Restart 绕过（§29.4）。
        return .defer_apply;
    }

    if (change.native_changed or
        change.fun_abi_changed or
        change.zjs_abi_changed or
        change.worker_config_changed)
    {
        return .worker_restart;
    }

    if (runtime.active_session_tainted) {
        return .sequential_session_reload;
    }

    if (runtime.retired_budget_exceeded) {
        // framework refresh 与 HMR 共用留存内存预算（§33.1）。
        return .sequential_session_reload;
    }

    if (framework_planner.plan(change)) |plan| {
        return .{ .framework_refresh = plan };
    }

    if (hmr_planner.plan(change)) |plan| {
        return .{ .module_hmr = plan };
    }

    return .sequential_session_reload;
}
```

---

# 9. Host 资源所有权

## 9.1 资源类别

| 类别 | 生命周期 | 并发规则 | 示例 |
|---|---|---|---|
| HostPersistentExclusive | Worker | 只有 Active Session 可使用 | Window presentation、Surface |
| HostPersistentScheduled | Worker | 经 HostScheduler 串行或限流 | GPU Device、Queue、shader cache |
| HostPersistentReadOnly | Worker | 多 Session 可读 | immutable asset cache |
| SessionOwned | Session | 只能被所属 Session 使用 | timer、listener、JS wrapper、scene |
| ScopeOwned | ResourceScope | 随 Scope 关闭 | request、subscription、watcher |
| Transferable | 显式迁移 | 通过 token 重建 wrapper | 特定 socket、asset handle |
| WorkerOwned | Worker | 不跨 Worker | plugin instance、native thread |

v1 中 HostPersistentExclusive 的现实含义：compile 预检窗口内并存的 Initializing Session（§12.1 第 5-6 步）不得使用 presentation 类资源。

## 9.2 默认归属原则

任何新 native 资源默认都是：

```text
SessionOwned
```

只有明确注册到 HostCore allowlist 后才可以跨 Session。

## 9.3 ResourceHandle

```zig
const ResourceHandle = struct {
    id: ResourceId,
    kind: ResourceKind,
    owner: OwnerId,
    access_class: AccessClass,
    last_gpu_fence: ?FenceId,
};
```

（Candidate phase 字段 `allowed_phases: PhaseMask` 随 Shadow Swap 移入附录 A，恢复时再加。）

## 9.4 HostScheduler

HostScheduler 负责：

- GPU Queue 提交顺序。
- Surface presentation 独占。
- native resource cache 引用计数。
- GPU fence-aware destruction。

（Candidate 相关职责随 Shadow Swap 移入附录 A。）

---

# 10. 异步安全模型

generation 检查是必要条件，但不是完整方案。

完整异步操作需要：

```zig
const AsyncOperation = struct {
    session_id: SessionId,
    epoch: u64,
    owner_scope: ScopeId,
    cancellation: CancellationToken,
    js_callback: ?CallbackRef,
    native_cleanup: NativeCleanupFn,
};
```

异步 completion 到达时：

```text
1. 执行必要 native completion
2. 释放 native buffer、request 和 OS handle
3. 检查 cancellation
4. 检查 Session 是否存活
5. 检查 epoch
6. 检查 Scope 是否 open
7. 满足条件才投递 JS callback
```

旧 Session 已销毁时：

```text
native cleanup 仍然执行
JS callback 丢弃
```

生产成本注记：AsyncOperation 的每 job 元数据与每次 completion 的检查属于进入生产构建的通用机制，实现形态须经 PERF-MECHANISM-LEDGER A/B 定价后冻结（见 §41）。定价对象是完整元数据（scope/cancellation）的形态，而非是否携带：Session 存活性验证所需的最小 owner 标记是 §3.2 条 1/2 的硬前提，生产构建不可移除；若完整形态定价不过，降级为「开发构建完整元数据 + 生产构建最小集」。

## 10.1 CallbackRef

```zig
const CallbackRef = struct {
    session_id: SessionId,
    epoch: u64,
    root_handle: RootHandle,
    owner_scope: ScopeId,
};
```

HostCore 中禁止保存裸 `JSValue`。

`root_handle` 依赖 zjs 提供的 root handle 表原语（§27.8）。epoch 验证与 FNABI 的纪元验证条款（“裸指针比较不构成 guard”）使用同一机制，不另造一套。

## 10.2 SessionLease

调用 JS 前获取 SessionLease：

```text
acquire lease
    ↓
执行 JS callback
    ↓
release lease
```

lease 分两类：

- **普通 lease**：新的 JS 进入（事件、timer、新 request）。
- **特权 lease**：teardown 编排自身的调用（`dispose()`、`snapshot()`，§12.1）与已在途 request 的后续 JS 进入（§25.2）。

Session 进入 QUIESCING 后：

- 不再允许创建普通 lease；特权 lease 仍可创建，受 drain timeout 约束。
- 当前 lease 可以在 deadline 内返回。
- 超时后先经 CancellationToken 取消挂起中的异步操作（parked-on-await 的 lease 没有可中断的执行中 JS，只能靠 cancel 释放）；正在执行 JS 的经 requestInterrupt 中断。
- 两者都无法终止则 Worker Restart。

## 10.3 Background Thread

后台线程不得直接进入 zjs。

正确路径：

```text
background thread
      ↓
EventEnvelope
      ↓
worker control/event queue
      ↓
JS thread validation
      ↓
SessionLease
      ↓
JS callback
```

这与引擎的 Runtime 线程亲和约束一致：所有 Session 操作（包括销毁）必须发生在其 owner 线程。

---

# 11. Reload 窗口、Epoch Barrier 与事件处理

区分两个概念：

- **Reload 窗口**：从暂停外部输入派发（§12.1 第 8 步）到恢复派发（第 16 步）的整段时间。其长度由 dispose/teardown/evaluate 决定，不承诺「极短」；§11.1 的事件策略覆盖整个窗口。
- **Epoch Barrier / commit**：第 15 步的原子发布本身——替换 `active_binding_set`、递增 `active_epoch` 的指针切换。它必须极短，且**不得执行任何用户 JS**（冻结项 6 约束的就是这一步；dispose/snapshot/evaluate/restore 都发生在 commit 之前的 Reload 窗口内，不属于 commit）。

```text
进入 Reload 窗口（暂停外部输入派发）
       ↓
dispose / snapshot / teardown / evaluate / restore
（初始化中 Session 自身的 job、timer 与 IO completion 正常运转）
       ↓
等待 JS stack 为空
       ↓
commit：原子替换 BindingSet + active_epoch++（无用户 JS）
       ↓
退出 Reload 窗口（恢复事件派发）
```

**初始化中 Session 的运转豁免**：Reload 窗口暂停的是外部输入与 host 事件向 BindingSet 的派发；正在初始化的新 Session 自身的 job queue、microtask、其创建的 timer 与其发起的 IO completion 必须正常运转——否则任何 `await` 过 timer/IO 的异步 factory（§14 明确支持的形态）都会死锁。初始化受 `init_timeout_ms` 预算约束，超时按 init 失败处理（§12.2）。

## 11.1 Reload 窗口期间的事件策略

| 事件类型 | Reload 窗口处理 |
|---|---|
| pointer move | 只保留最后一个 |
| resize | 只保留最新尺寸 |
| keyboard/button | 有界 FIFO |
| touch sequence | 保持顺序；溢出则取消当前 gesture |
| animation frame | 合并为下一帧一次 |
| HostCore 帧/定时调度 | barrier 后按新 Active 重新武装；SessionOwned timer 随旧 Session 取消，不迁移 |
| server accept | OS backlog 或显式背压 |
| HTTP request | 已进入旧 Session 的继续持有旧 lease |
| file watch | 合并为下一轮 Update |
| GPU completion | 发往原 owner，不得重定向到新 Session |
| native task completion | 原 owner 已失效则只执行 cleanup |

事件队列必须有上限。

溢出策略必须显式，不能无限缓存。

---

# 12. Sequential Session Reload

Sequential Reload 是 v1 的默认且唯一的 Session Reload 实现。

## 12.1 流程

```text
1. File change
2. zabel transform
3. module resolution
4. syntax precheck
5. 创建新 Session（与旧 Session 同线程并存；创建其 PluginInstance）
6. 新 Session 内全量 parse + compile（不 evaluate）
   —— 此窗口旧应用继续运行、事件照常派发；
      compile error 在此发现则销毁新 Session，旧应用不受影响
7. 等待 safe point
8. 进入 Reload 窗口：暂停外部输入向 BindingSet 派发
9. 调用旧 application dispose("reload")
   （特权 lease，受 dispose timeout 约束）
10. 可选 snapshot（特权 lease）
11. teardown 旧 Session（§28）
12. evaluate 新 Session entry（top-level + async factory；
    其自身 job/timer/IO completion 正常运转，受 init_timeout 约束）
13. 可选 restore
14. 生成 BindingSet
15. commit：原子发布 BindingSet 与新 epoch（无用户 JS）
16. 退出 Reload 窗口：恢复事件派发
```

在停止旧 Session 前完成（第 1-6 步，旧应用照常运行）：

- zabel transform。
- source map。
- module resolution。
- syntax check。
- asset hash 计算。
- 新 Session 内的全量 parse + compile（只编译不 evaluate，无用户可见副作用）。

**现状对账：** zjs bytecode 是 Heap 绑定的——`FunctionBytecode` 内嵌 Realm 引用与 `JSValue` 常量池，atom id 编码在指令流内，且引擎不存在任何序列化格式。因此：

- v1 中 bytecode compile 必须在（新）Session 的 Heap 内进行，每次 Reload 付全量 parse + compile；第 5-6 步「先建新 Session、在其中预编译」正是把这笔成本移出 Reload 窗口（引擎支持同线程多 Runtime 并存，此窗口的新 Heap 只含编译产物）。
- save-to-first-frame 预算必须按全量重编译的现实设定。
- heap-independent serialized artifact 是独立交付物（工作项 W1，§27.10、§37），落地后可进一步省去重复 parse/compile。

## 12.2 错误语义

在销毁旧 Session 前发现（§12.1 第 1-6 步）：

- transform error。
- syntax error。
- module resolution error。
- compile error（在新 Session 的 compile 预检中发现，销毁新 Session 即可）。

则旧应用继续运行。

旧 Session 已销毁后（第 11 步之后）出现：

- top-level runtime error。
- application initialization error / init 超时。
- restore error（按 §15 策略分叉：`best-effort` 记诊断、丢状态、照常发布；`required` 才进入失败路径）。

失败路径：

- GUI 保留最后一帧并显示 Native Error Overlay。
- 声明了 `persistent_listener = true` 的 server 保留 listener，返回开发期 503；SessionOwned listener 已随旧 Session 关闭，无 503 可言。
- CLI supervisor 保持运行并等待下一次保存。

**重试上限：** 同一 Update 的初始化失败最多自动重试一次（用于排除瞬态原因）；再次失败后不再重试，显示 Overlay 并等待下一次保存。禁止同一份代码的 reload 循环。

**Vacant 模式（无 Active Session 的等待期）：** 重试耗尽后系统进入 Vacant 模式，直到下一次保存产生可用 Session：

- 失败的新 Session 立即标记 FAILED 并走 §28 teardown（其初始化期注册的 timer/listener/资源随之销毁，保证 §3.1 条 10）。
- `active_binding_set` 置空；外部输入事件**按类型直接处理而不缓冲**（§11.1 的有界队列只服务于 Reload 窗口，不服务于可能长达数小时的 Vacant 等待期）：pointer/keyboard/touch 丢弃；resize 只记录最新尺寸供下个 Session 使用；persistent listener 返回 503；GPU 保留末帧；file watch 照常触发下一轮 Update。

Sequential Reload 不承诺运行时初始化错误时旧应用仍可继续执行。

## 12.3 为什么默认选择 Sequential Reload

它不要求：

- 两个完整应用 Heap 同时存在（compile 预检窗口内短暂并存的新 Heap 只含编译产物，未 evaluate、无应用状态）。
- 跨线程的 Session 协调。
- 外部副作用可 staging。
- Host API 全量区分 active 和 shadow。
- 通用 rollback。

它先解决最重要的问题：

```text
JS 可以彻底重建
Window/GPU/Surface 不重建
```

引擎侧对账：这条路径所需的 zjs 原语大体已具备（多 Runtime、断言加固销毁、interrupt、loader 钩子、teardown finalizer 枚举在 main 上均存在）；zjs 侧小增量 = Root Handle 表 API 与 epoch-safe deref/release（§27.8，现不存在），不是零新增。

---

# 13. Guarded Shadow Swap（已移出 v1）

按 v1.2 owner 裁决，Guarded Shadow Swap 整体移出 v1 主线。

设计内容、启用条件、Candidate Mode、以及恢复主线前必须裁决的问题（首要是 JS 线程模型），见附录 A。

v1 中任何原本会选择 Shadow Swap 的场景，一律使用 Sequential Session Reload。

---

# 14. Application Lifecycle

推荐 GUI、server 和 daemon 应用使用声明式 lifecycle：

```ts
import { defineApplication } from "fun:app";

export default defineApplication(async context => {
    const scene = await createScene(context);

    return {
        bindings: {
            onFrame(frame) {
                scene.render(frame);
            },

            onPointer(event) {
                scene.handlePointer(event);
            },
        },

        snapshot() {
            return {
                camera: scene.cameraState(),
            };
        },

        restore(state) {
            scene.restoreCamera(state.camera);
        },

        onPublished() {
            // 发布完成后调用。
            // 不属于 atomic commit。
        },

        async dispose(reason) {
            await scene.dispose(reason);
        },
    };
});
```

逻辑接口：

```ts
interface FunApplication {
    readonly bindings: ApplicationBindings;

    snapshot?(): StructuredState;

    restore?(state: StructuredState): void;

    onPublished?(): void;

    dispose?(
        reason: "reload" | "stop" | "restart",
    ): void | Promise<void>;
}
```

`defineApplication()` factory 可以异步，用于：

- 资源加载。
- scene 构建。
- shader 预热。
- handler 创建。

## 14.1 约束

- `snapshot()` 必须同步。
- `restore()` 必须同步。
- 两者都受时间和大小预算限制。
- commit 中只执行 runtime 内部指针切换，不调用 `onPublished()`。
- `onPublished()` 在事件恢复后运行。
- `dispose()` 为 best-effort，并有 timeout。
- `dispose()` 必须幂等。
- `dispose()` 的调用点：Sequential Reload 的 §12.1 第 9 步（Reload 窗口内、snapshot 之前，特权 lease）；异步 continuation 在 dispose timeout 内 drain，超时放弃并继续 Reload。
- v1 中 factory 在新 Session 的正常权限下执行，无 capability 限制；Candidate Mode 下的 capability 约束随 Shadow Swap 见附录 A。

---

# 15. 状态迁移

跨 Session 状态迁移默认关闭。

配置策略：

```text
none
best-effort
required
```

## 15.1 `none`

不调用 snapshot/restore。

最安全，也是默认策略。

## 15.2 `best-effort`

snapshot 或 restore 失败时：

- 记录诊断。
- 不保留状态。
- 继续完成 Reload。

## 15.3 `required`

snapshot 或 restore 失败时：

- 销毁旧 Session 前必须先成功 snapshot；snapshot 失败则本次 Update 中止，旧应用继续运行。
- restore 失败则显示错误，不发布新 BindingSet。

## 15.4 允许类型

- primitive。
- plain object。
- array。
- Map。
- Set。
- Date。
- ArrayBuffer。
- TypedArray。
- 明确定义的 HostHandleToken。

默认禁止：

- Function。
- closure。
- Promise。
- Proxy。
- WeakMap。
- WeakSet。
- 任意 class identity。
- 任意 JS native wrapper。
- three.js Scene。
- GPUBuffer wrapper。
- WebSocket wrapper。

实现依赖：跨两个独立 Heap 传递上述类型需要 zjs 提供结构化序列化原语（§27.9 = SER-SNAPSHOT profile）；该原语现状不存在，属于阶段 2B 的引擎侧交付物（§37；前置 = 阶段 2A + SER-SNAPSHOT，阶段 2A 本身不依赖任何序列化）。

## 15.5 预算

建议初始限制：

```text
snapshot time ≤ 2 ms
restore time ≤ 2 ms
serialized state ≤ 4 MiB
```

这些数值属于可配置工程参数，不属于 ABI。

---

# 16. ESM Module HMR

Module HMR 是显式优化，不是默认正确性路径。

## 16.1 v1 支持范围

支持：

- ESM。
- 稳定 ModuleIdentity。
- 字面量 HMR dependency。
- 同一 Session 内更新。
- 无 affected top-level await。
- 无 CJS。
- debugger 未暂停。
- HMR memory budget 未超限。

以下情况直接 Session Reload：

- CJS。
- affected graph 含 top-level await。
- 无法确定 ModuleIdentity。
- HMR 传播到 entry root。
- module loader hook 不可安全重入。
- Session 已 tainted。
- retired module 超预算。

debugger paused 不属于此列表：它触发延迟 apply（§8 第 2 步、§29.4），resume 后再按本节判定。

## 16.2 API

```ts
interface HotContext {
    readonly data: Record<string, unknown>;

    accept(): void;

    accept(
        callback: (
            module: ModuleNamespace
        ) => void,
    ): void;

    accept(
        dependency: string,
        callback: (
            module: ModuleNamespace
        ) => void,
    ): void;

    accept(
        dependencies: string[],
        callback: (
            modules: ModuleNamespace[]
        ) => void,
    ): void;

    dispose(
        callback: (
            data: Record<string, unknown>
        ) => void,
    ): void;

    prune(
        callback: (
            data: Record<string, unknown>
        ) => void,
    ): void;

    invalidate(reason?: string): void;

    track(
        disposable:
            | (() => void)
            | { dispose(): void },
    ): void;
}
```

v1 中：

- `accept` callback 必须同步。
- `dispose` callback 必须同步。
- `prune` callback 必须同步。
- callback 返回 Promise 视为错误。
- 需要异步 teardown 时应触发 Session Reload。

生产模式：

```ts
import.meta.hot === undefined
```

## 16.3 self-accept 限制

```ts
import.meta.hot.accept();
```

不会自动修改已有 importer 的 lexical import binding。

因此只推荐用于：

- entry module。
- side-effect module。
- stable registry adapter。
- framework transform 生成的 boundary。
- 不向普通 importer 暴露运行时 export 的模块。

如果一个有外部 importer 的 exported module 使用 self-accept，zabel 应给出开发期警告：

```text
HMR_SELF_ACCEPT_EXPORT_WARNING
```

## 16.4 dependency accept

推荐普通业务模块使用：

```ts
import * as initialScene from "./scene.ts";

let scene = initialScene.createScene();

if (import.meta.hot) {
    import.meta.hot.accept(
        "./scene.ts",
        nextScene => {
            scene.dispose();
            scene = nextScene.createScene();
        },
    );
}
```

accept dependency 必须是字面量：

```ts
import.meta.hot.accept("./scene.ts", callback);
```

动态字符串不进入 v1 HMR graph。

---

# 17. Module Identity 与版本模型

必须区分：

```text
ModuleIdentity
ModuleVersion
ModuleInstance
```

示例：

```text
ModuleIdentity:
    fun:///src/scene.ts

ModuleVersion:
    sha256:9c2d...

ModuleInstance:
    session=18
    identity=fun:///src/scene.ts
    version=sha256:9c2d...
    instance=442
```

用户可见信息始终使用 canonical identity：

- `import.meta.url`。
- stack trace。
- source map。
- CDP breakpoint。
- diagnostics。

禁止公开：

```text
scene.ts?generation=42
```

版本信息只能存在于内部 registry 和 inspector auxiliary metadata。

---

# 18. HMR ModuleGraph

ModuleGraph 记录：

```text
static dependencies
static importers
loaded dynamic-import edges
self-accept boundaries
dependency-accept boundaries
framework boundaries
entry roots
module format
top-level-await flag
runtime output hash
module version
```

循环依赖先压缩为 SCC：

```text
A → B
↑   ↓
└── C
```

视为：

```text
SCC(A, B, C)
```

同一个 SCC 必须作为整体重新实例化。

## 18.1 边界判断

从 changed SCC 沿 importer 反向传播。

只有每一条通往 entry root 的路径都在以下边界停止时，HMR 才成立：

1. self-accept。
2. importer dependency-accept。
3. framework refresh boundary。

任何路径到达 entry root：

```text
Session Reload
```

不使用启发式判断模块是否“看起来无副作用”。

---

# 19. HMR Update Overlay

HMR 不能直接覆盖 Active Module Registry。

应创建 UpdateOverlay：

```text
ModuleIdentity
      ↓
Pending ModuleInstance
```

（v1.1 称 Candidate ModuleInstance；为避免与附录 A 的 Candidate Session 撞名，改称 Pending。）

解析规则：

```text
dependency 在 affected set 中
    → 使用 UpdateOverlay 中的新实例

dependency 不在 affected set 中
    → 使用 Active Registry 最新实例
```

这样可以在调用旧 dispose 之前完成：

- compile。
- link。
- import resolution。
- export validation。
- cycle validation。
- source map registration。

**现状对账（v1.2）：** zjs 的 module registry 目前是每 realm 单实例、按 interned atom 线性扫描、无公开 evict/replace 入口。UpdateOverlay 与多版本 ModuleInstance（§27.4）需要 registry 层重构，这是阶段 3 引擎侧的主要工作量，不是既有能力。另外线性扫描在大模块图上整图加载为 O(n²)，registry 重构时应一并处理。

---

# 20. HMR 应用流程

```text
1. transform changed modules
2. 计算 affected graph 和 SCC
3. compile 所有 ModuleVersion
4. 创建 UpdateOverlay
5. instantiate 所有新 ModuleInstance
6. 验证 import/export
7. 调用旧 dispose callbacks 与被移除模块
   （rename/delete 后不再被图引用）的 prune callbacks
8. 关闭旧 HotScope
9. evaluate 新 ModuleInstance
10. 调用 boundary accept callbacks
11. 原子提交 Active Module Registry
12. 替换 boundary registration
13. 解除旧 ModuleInstance registry root
14. 调度 GC
```

顺序：

- dispose：importer-first。
- evaluate：dependency-first。
- accept：距离 changed module 最近的 boundary 先执行。
- SCC 内按照 zjs 标准 module link/evaluate 语义处理。

## 20.1 错误语义

| 失败阶段 | Session 是否可信 | 处理 |
|---|---:|---|
| transform | 是 | 保持旧程序 |
| compile | 是 | 保持旧程序 |
| instantiate | 是 | 保持旧程序 |
| export validation | 是 | 保持旧程序 |
| dispose | 否 | taint + Session Reload |
| prune | 否 | taint + Session Reload |
| evaluate | 否 | taint + Session Reload |
| accept | 否 | taint + Session Reload |
| registry commit | 否 | Session Reload；必要时 Worker Restart |

一旦调用旧 dispose，就不再宣称本次更新可回滚。

---

# 21. 为什么不原地修改 ModuleRecord

禁止：

- 修改旧 bytecode。
- 替换已有 Function 的 code pointer。
- 强制更新 `const` 或 lexical binding。
- 原地重置 module environment。
- 修改已有 namespace object。
- 隐式升级 class instance。
- 为所有 export 增加通用 Proxy。

正确方式：

```text
scene.ts@17 → old ModuleInstance
scene.ts@18 → new ModuleInstance
```

新旧实例短暂共存。

旧实例解除 registry root 后，由 GC 回收。

这样避免定义以下不稳定语义：

- 旧 closure 应引用旧变量还是新变量。
- cycle 中哪个 binding 先切换。
- TDZ 如何重新进入。
- namespace identity 是否改变。
- prototype 和 instance layout 如何迁移。
- top-level await 如何中断和恢复。

---

# 22. HotScope

每个 HMR ModuleInstance 拥有 HotScope：

```text
HotScope
├── timers
├── animation callbacks
├── event listeners
├── subscriptions
├── watchers
├── callback roots
└── custom disposables
```

更新时：

```text
user dispose
      ↓
HotScope.close()
      ↓
自动清理剩余长期资源
```

## 22.1 自动跟踪范围

Fun 内建 API 自动跟踪：

- `setTimeout`。
- `setInterval`。
- `requestAnimationFrame`。
- `addEventListener`。
- `watch`。
- `subscribe`。
- socket event handler。
- native callback registration。

以下 hot path 不跟踪：

- Canvas draw。
- WebGPU command encode。
- buffer read/write。
- 数学 builtin。
- 同步 native function。

## 22.2 Owner 解析

长期资源创建时：

```text
1. explicit scope
2. 当前 HMR callback scope
3. 当前函数 origin ModuleInstance
4. 当前 native callback owner
5. SessionScope
```

zjs code/function metadata 应保留：

```text
origin_module_instance_id
```

（实现约束见 §27.6：走 bytecode metadata 侧车，不动钉死布局。）

## 22.3 旧 closure

旧 ModuleInstance 已退休且 HotScope 已关闭后，旧 closure 再注册长期资源：

```text
ERR_HOT_SCOPE_CLOSED
```

不能静默转入 SessionScope，否则旧代码会持续制造泄漏。

---

# 23. Framework Fast Refresh

Framework Fast Refresh 不属于 zjs 核心。

推荐接口：

```ts
interface RefreshAdapter {
    analyze(
        change: ChangeSet,
        graph: ModuleGraph,
    ): RefreshPlan | null;

    apply(
        session: Session,
        plan: RefreshPlan,
    ): RefreshResult;
}
```

fun-native 可以基于：

```text
module identity
export name
component signature
hook order
state signature
component boundary
```

选择：

1. 签名兼容：替换实现并保留状态。
2. 签名不兼容：remount 最近组件边界。
3. 模块被非组件代码使用：降级到 ESM HMR。
4. 无完整边界：Session Reload。

Framework Refresh 失败后，不应继续猜测性保留组件状态。

---

# 24. GUI、Canvas、WebGPU 与 three.js

## 24.1 HostCore 保留

建议持久化：

- Window。
- Input backend。
- Dawn Instance。
- Adapter。
- Device。
- Queue。
- Surface。
- Skia Graphite Context。
- shader cache。
- pipeline cache。
- decoded image cache。
- last presented frame。

## 24.2 SessionOwned

默认随 Session 销毁：

- three.js Scene。
- Object3D。
- Camera JS object。
- Material JS object。
- JS render loop closure。
- JS GPUBuffer wrapper。
- JS GPUTexture wrapper。
- temporary command encoder。
- application listener。
- application timer。

## 24.3 Candidate GPU 规则

随 Shadow Swap 移至附录 A.2。

## 24.4 内容寻址缓存

```text
Texture Key:
    source hash
    decode options
    color space
    mip configuration

Geometry Key:
    vertex/index data hash
    vertex layout

Shader Key:
    source hash
    defines
    backend

Pipeline Key:
    shader key
    layouts
    render state
    attachment format
```

新 Session 创建新的 JS wrapper，但可引用同一个 Host cache entry。

## 24.5 GPU Fence

```text
JS wrapper released
      ↓
host refcount reaches zero
      ↓
等待 last submission fence
      ↓
销毁 native GPU resource
```

不得因为 Session 已销毁就立即释放仍在 GPU 使用中的资源。

## 24.6 three.js 状态保留

同 Session HMR 可使用：

```ts
const state =
    import.meta.hot?.data.state ??
    createSceneState();

import.meta.hot?.dispose(data => {
    data.state = state;
});
```

Session Reload 默认重建 JS Scene，但可复用纹理、shader、pipeline 和 geometry cache。

未来可提供 three.js Refresh Adapter，但不进入 zjs 核心。

---

# 25. Server 场景

## 25.1 Listener Socket

Listener Socket 只有在应用显式声明：

```text
persistent_listener = true
```

时才进入 HostCore。

否则默认 SessionOwned。

持久化模式：

```text
Host listener
     ↓
Request BindingSet
     ↓
Active Session
```

Session Reload 只替换 request handler，不重新 bind 端口。

## 25.2 In-flight Request

已进入旧 Session 的 request：

- 继续持有 SessionLease。
- 在 drain timeout 内完成。
- 超时后取消。
- native completion 始终完成 cleanup。
- 不得回调新 Session。

## 25.3 WebSocket

第一版默认：

- listener 可以 HostOwned。
- 已建立连接 SessionOwned。
- Session Reload 时关闭旧连接。

只有显式实现 HostHandleToken 和协议级重绑定后，才允许迁移 WebSocket。

---

# 26. Native Plugin

Native Plugin 的生命周期、ABI 与热重载模型以 FNABI 为权威规范：

```text
docs/fun-native-plugin-design.md
（FNABI v0.3，2026-08-25，评审修订版；完成 M0 后冻结 FNABI v1）
```

本章只定义 hot reload 系统与 FNABI 的对接方式，不重复定义 plugin ABI。旧 `runtime-plugin-abi.md` 已退役，不作为本设计的依据。

## 26.1 与 FNABI 的概念映射

| 本文概念 | FNABI 概念 |
|---|---|
| Session（= zjs Runtime） | PluginInstance 的宿主 Runtime |
| Session 创建 | 按 (Runtime, NativeImage) 创建 PluginInstance（FNABI §22.2） |
| Session 销毁 / teardown（§28） | PluginInstance 经 `Active → Closing → Cancelling → Draining → Finalizing → Destroying → Destroyed`（FNABI §22.4）；两处不得各自定义一套关闭状态机 |
| CallbackRef / AsyncOperation 的 epoch 验证（§10） | 与 FNABI §17.2 / 冻结决策 41 的纪元验证条款同源（「裸指针比较不构成 guard；命中必须经版本/纪元验证后才可比较或解引用」）；该条款在 FNABI 中约束 quicken 站点缓存，本文将同一验证机制外推到 CallbackRef/AsyncOperation，不另造一套 |
| stale completion 只做 native cleanup | FNABI Draining/Finalizing 阶段规则 |
| plugin binary 变化 → Worker Restart | FNABI §22.7 side-by-side image 世代 + 不 `dlclose` |

由于 Session = Runtime，Session Reload 天然对应“销毁旧 PluginInstance、为新 Runtime 创建新 PluginInstance”。**v1 的 Sequential Reload 与 Worker Restart 对 plugin 没有任何 hot-reload 专用 ABI 需求**——FNABI v0.3 的既有约束已覆盖：

- 不在 process-global 状态保存裸 JS Root。
- 异步 completion 携带 runtime 纪元（AsyncToken）。
- destroy 时机与七态关闭机对齐。
- background thread 只投递事件，不直接进入 JS。
- 长期 native resource 的 owner 记账（PluginInstance 的资源记账，FNABI §22.2）。

操作序列接线：新 Session 在 §12.1 第 5 步创建时即创建 PluginInstance；旧 Session teardown 各步与七态机的对应关系标注在 §28 的序列内。

现状对账：FNABI v0.3 是已采纳的评审修订版设计文档（**尚未冻结**，完成 M0 后冻结 v1），`src/` 中尚无实现；其落地里程碑（M 系列）独立于本设计排期，本设计的阶段 0 审计（§37）应与 FNABI 实现进度对表。

## 26.2 未来增量（随 Shadow Swap 移入附录 A）

Candidate Mode 所需的 `candidate_mode` 声明（提议新增到 FNABI §24.1 manifest 的 `fun.native` 段，**非现存字段**）与 Candidate-safe API 声明，属于对 FNABI 的 ABI 面增量，应在恢复 Shadow Swap 时作为 **FNABI v0.4 议题**提交，不在本文单独定义平行规范。见附录 A.8。

## 26.3 触发 Worker Restart 的变化

以下变化触发 Worker Restart（以 FNABI 的 **artifact identity（§25.1：Recipe Key / Build Key / Artifact Digest）与兼容性 tuple（§11.5）** 为准，不是 manifest 字段）：

- plugin binary hash / artifact digest（FNABI §25.1）。
- build ID（Build Key，FNABI §25.1）。
- fun ABI hash、zjs ABI hash、plugin ABI version（FNABI §11.5 兼容性 tuple；该节禁止直接用 fun runtime version 或 zjs commit 作为兼容性条件）。

## 26.4 不执行通用 `dlclose`

与 FNABI §22.7 一致：新旧 native image 并排存在、新 import 绑定新世代、旧世代在所有 owner drain 后才可卸载，v1 不 `dlclose`。本文不再重复该规范的细节。

---

# 27. zjs 需要提供的能力

zjs 不负责 watcher、HMR boundary 和 update policy。

每个小节标注现状（main@`bce28d11`），以区分“已具备”与“需新建”。

## 27.1 Session API

```zig
createSession()
requestInterrupt()
pauseJobs()
resumeJobs()
drainMicrotasks()
beginDestroy()
destroySession()
```

现状：`createSession`/`destroySession` 即 `JSRuntime.create`/`destroy`，已具备且断言加固（销毁末尾零残留断言）；`requestInterrupt` 已具备（interrupt handler + dispatch 全 backedge/call seam 检查点，可中断纯循环与纯递归）。`pauseJobs`/`resumeJobs`/`beginDestroy` 的显式 API 形态需补齐——这些待补项（含带 reason 的 `requestInterrupt` 与优先级仲裁、生命周期取消钩子）归入跨线共享工作项 **RT-LIFECYCLE**（roadmap v1.7；process-model-design.md v0.5 §16.3 同款，热更与 FNABI shutdown 共用），不在本文档单独交付。

## 27.2 Module API

```zig
compileModule()
instantiateModule()
evaluateModule()
getModuleNamespace()
releaseModuleRoot()
```

必须拆分 compile、instantiate 和 evaluate。

现状：分离步骤已存在（parse/link/instantiate/evaluate 各为独立内部入口，TLA 有 suspend 语义）；缺公开的 evict/replace 与多版本入口（见 §27.4）。

## 27.3 Loader API

fun 向 zjs 提供：

```text
resolve(specifier, referrer)
load(module_identity, module_version)
getImportMeta(module_instance)
```

现状：`HostHooks { resolveModule, loadModule }`、scoped dynamic-import override、synthetic module 与 `import.meta`（含 `main`）均已具备，基本满足本节需求。

## 27.4 多版本 ModuleInstance

同一 Session 允许：

```text
scene.ts@17
scene.ts@18
```

短暂共存。

现状：**不具备**。registry 每 realm 单实例（按 interned specifier atom 键、线性扫描查找）、无公开 evict/replace 入口。多版本化是 registry 层重构，属阶段 3 引擎侧主要工作量；重构时一并处理线性扫描的 O(n) 查找。

## 27.5 Job Metadata

```zig
const JobMetadata = struct {
    session_id: SessionId,
    epoch: u64,
    owner_scope: ScopeId,
    cancellation: CancellationToken,
};
```

生产构建的每 job 元数据成本走 PERF-MECHANISM-LEDGER，A/B 定价后冻结实现形态（§41）。

## 27.6 Function Origin

长期资源注册需要能够查询当前函数来源：

```text
origin_module_instance_id
```

不要求每次普通函数调用执行 HMR 分支。

实现约束：`FunctionBytecode` 的核心记录是 96 字节、align-8 的 QuickJS 头，全部字段偏移由 comptime 断言钉死，不得改变任何核心偏移；zjs-only 状态的既有落点是 inline FAM tail 扩展（`FunctionBytecodeHotExtension`）与已用尽的 flag padding 洞。`origin_module_instance_id` 应走 bytecode metadata 侧车 / FAM tail 扩展——该载体同时是 IC 与 type-directed plan 的既定前置，三条需求线共享同一个设计，不做三次。

## 27.7 Inspector Event（依赖工作项 W2）

zjs 需要上报：

- execution context created。
- execution context destroyed。
- script parsed。
- script failed。
- canonical source URL。
- source map URL。
- internal ModuleVersion metadata。

现状：CDP/inspector 实现为零；本节全部属于工作项 W2「zjs 最小 CDP backend」的交付范围（§37）。既有可复用的原材料：source location 表、backtrace 帧、bytecode disassembler。

## 27.8 Root Handle 表（v1.2 新增）

CallbackRef（§10.1）依赖：

```zig
createRootHandle(value) RootHandle
derefRootHandle(handle) ?JSValue
releaseRootHandle(handle) void
```

- deref 必须做 Session/epoch 验证；跨 Session 或过期 epoch 的 deref 返回错误，不返回悬垂值。
- epoch 验证与 FNABI 纪元机制统一。

现状：无该公开原语；引擎既有 GC root 机制可作为实现基础。

## 27.9 结构化状态序列化（v1.2 新增）

snapshot/restore（§15）跨两个独立 Heap 传递数据，需要：

```zig
structuredSerialize(value, budget) []u8
structuredDeserialize(bytes) JSValue
```

覆盖 §15.4 允许类型，带时间与大小预算，超预算返回错误。

现状：不存在，需新建（= SER-SNAPSHOT profile，属阶段 2B，§37）；与未来 Worker `postMessage`/进程消息需求（SER-MESSAGE）共享 SER-CORE 编码内核，profile 独立（冻结项 21）。

## 27.10 Bytecode 序列化（v1.2 新增，独立交付物 W1）

现状：`FunctionBytecode` 内嵌 Realm 引用与 `JSValue` 常量池，atom id 编码在指令流内；引擎不存在任何 write/read 格式。

裁决（v1.2,**v1.4 修订**）：heap-independent bytecode artifact 作为独立工作项 W1(全局 ID SER-ARTIFACT),~~与离线 emitter 输出同一交付物~~ 按 SER-CORE+profile 模型交付——共享 Core 编码内核,profile 独立;typed 侧对接物=typed plan §10.5 容器清单(其离线 emitter 是 Zig 源码路线,非序列化格式)。禁止不共享 Core 的第二套编码体系。详见冻结项 21 v1.4 注。

W1 落地前：

- DevCoordinator 的 Build Cache 只缓存 transform 输出、source map 与模块图元数据。
- 每次 Session Reload 付全量 parse + compile（§12.1）。

---

# 28. Session Teardown

推荐顺序：

```text
1. Session → QUIESCING（PluginInstance → Closing）
2. 禁止新普通 SessionLease（特权 lease 仍可创建，§10.2）
3. 停止新的外部输入与新 request 进入；
   已归属该 Session 的异步 completion（socket/DB/GPU 等）继续投递，
   直至 drain 截止——否则 I/O-bound 的 in-flight request 永远无法完成
4. 取消尚未到期的 timer、watcher 与可取消的 queued job
   （PluginInstance → Cancelling）
5. drain 不可取消的在途 job 与 in-flight request：
   共用同一 drain timeout（PluginInstance → Draining）
6. 超时处理：先经 CancellationToken 取消挂起中的操作
   （parked-on-await 的 lease 无可中断的执行中 JS）；
   正在执行 JS 的经 requestInterrupt 中断
7. 关闭 SessionScope
8. 释放 callback roots
9. 释放 module registry roots
10. 清理 inspector handles（W2）
11. 销毁 JS Heap
    （PluginInstance → Finalizing → Destroying → Destroyed）
12. 延迟释放 fence-protected GPU resource
13. Session → DESTROYED
```

application 级 `dispose()` 与 `snapshot()` 在进入本序列**之前**、Reload 窗口内以特权 lease 执行（§12.1 第 9-10 步），不属于本序列。

native wrapper finalizer 必须：

- 幂等。
- 不执行任意 JS。
- 不依赖其他 JS object。
- 能区分普通 GC 和 Session teardown。
- 只减少 native refcount 或关闭 native handle。

不保证 Session teardown 时执行用户可见 `FinalizationRegistry` callback。

与 FNABI 的对齐：plugin 侧的对应过程由 FNABI §22.4 七态关闭机定义（§26.1），本节顺序与之对表，不另立状态机。

现状对账：第 11 步的 finalizer 枚举在 main（RC 模式）经由侵入链表 `gc_obj_list` 五阶段遍历已具备；native payload finalizer 带 generation 戳，默认在对象释放路径内联同步执行（generation 不匹配即拒绝调用），可重入的 plugin 回调另走 `DeferredClassPayloadFinalizer` 延迟队列，由 runtime teardown 交替 drain 三轮；tracing GC 模式下的对应设计见 `docs/tracing-gc-design.md` §9.4「Native and plugin finalization」，两者必须保持行为一致。

---

# 29. CDP Inspector 与 REPL

> **前置依赖（v1.2）：** zjs 现状没有任何 CDP/inspector/debugger 协议实现。本章全部内容依赖工作项 W2「zjs 最小 CDP backend」（§37）完成后才可实施；阶段 1 MVP 不含 debugger。本章保留为目标态设计。

## 29.1 InspectorProxy

```text
DevTools
   ↓
stable InspectorProxy
   ↓
Current Worker
   ↓
Current Session
```

## 29.2 Module HMR

- execution context 不变。
- 新 scriptId。
- canonical URL 不变。
- URL breakpoint 重新绑定。

## 29.3 Session Reload

发送：

```text
Runtime.executionContextDestroyed(old)
Runtime.executionContextCreated(new)
```

旧 remote object、call frame 和 object group 全部失效。

## 29.4 Debugger Paused

Debugger 暂停时：

- watcher 和 build 继续。
- 不执行 HMR apply。
- 不执行 Session commit。
- 不执行自动 Worker Restart（plugin 重建同样延迟，避免调试会话无预警蒸发；§8 第 2 步）。
- 只保留最新 pending Update。
- resume 后应用最新版本；若当前 Session 已 tainted，resume 后优先 Session Reload。

强制 Worker Restart 可绕过该限制。

`defer_while_debugger_paused = false` 时忽略暂停状态照常 apply（调试会话将失效，由开发者自担）。

## 29.5 REPL

Session Reload 后：

```text
execution context changed
generation: 41 → 42
```

REPL 连接可保持，但旧 object handle 失效。

Reload 窗口期间 `fun eval` 返回：

```text
PROGRAM_TRANSITIONING
```

---

# 30. Native Error Overlay

错误展示必须独立于 JS Session。

GUI：

- 保留最后一帧。
- 显示 transform、syntax、runtime、HMR 和 Session 错误。
- 显示文件、行列、代码片段和 Update ID。
- 新版本成功后自动清除。

CLI：

- 输出 stderr。
- DevCoordinator 不退出。
- 等待下一次更新。

Server：

- Active 仍存在时继续提供旧版本。
- `persistent_listener = true` 且旧 Session 已销毁时返回开发期 503；SessionOwned listener 随 Session 关闭，由 supervisor 等待下一次保存。
- 生产配置不暴露源码和内部路径。

---

# 31. 快速连续更新

Update 使用单调编号：

```text
Update #41
Update #42
Update #43
```

规则：

1. transform/build 可以并行。
2. 过期 build 可以取消。
3. apply 一次只能有一个。
4. HMR 进入 dispose 后不能取消。
5. 当前 apply 完成后只处理最新 pending Update。
6. 旧 diagnostics 不得覆盖新结果。
7. Worker Restart 优先级高于所有 pending JS update。
8. 同一 Update 的初始化失败最多自动重试一次（§12.2）。

状态：

```text
IDLE
COLLECTING
BUILDING
PLANNED
PREPARING
READY
APPLYING
DRAINING
PUBLISHING
COMPLETED
FAILED
CANCELLED
```

（DRAINING 在 Sequential 中位于 PUBLISHING 之前——旧 Session 先 dispose/drain/teardown 再发布新 BindingSet；附录 A 的 Shadow 流程中位于其后。）

---

# 32. 无限循环与 Hang

```text
JS infinite loop
      ↓
外部 DevCoordinator 继续检测文件
      ↓
requestInterrupt
      ↓
等待 interrupt deadline
      ├── 成功 → Session Reload
      └── 失败 → Worker Restart
```

现状对账：interrupt 机制引擎已具备——dispatch 每个 backedge 与 call seam 均有检查点，纯循环与纯递归代码都能被中断，抛不可捕获 Interrupted。检查点执行的是每 Realm 的 cadence 计数器 tick（reset 值 10000），handler 每 10000 次 tick 才运行一次，因此 interrupt deadline 必须按「cadence 周期 + 最长单次 tick 间隔」设定，而非假定即时生效。本节无引擎侧新工作。

Hot Reload 不单独实现一套与 fun supervisor 冲突的 heartbeat。

应复用现有 Worker health、heartbeat 和 force-kill 机制。

---

# 33. 内存治理

## 33.1 Retired Memory（HMR 与 Framework Refresh 共用）

统计：

```text
successful_hmr_count
retired_module_count
retired_code_bytes
retired_metadata_bytes
heap_size_at_session_start
current_heap_size
closed_hot_scope_count
```

达到预算后：

```text
Session Reload
```

建议初始默认：

```text
连续留存更新（HMR + Framework Refresh）32 次
或 retired module/code > 64 MiB
或 Heap 增长超过配置阈值
```

该预算覆盖两条留存路径：Module HMR 与 Framework Fast Refresh——后者同样经由新 ModuleInstance 替换产生 retired 内存（§21 禁止原地修改），决策树在两条路径之前统一检查（§8 第 5 步），否则纯 Fast Refresh 编辑流的内存将无界增长。

## 33.2 Shadow Memory

随 Shadow Swap 移至附录 A.7。

## 33.3 Host Cache

Host cache 必须具备：

- LRU 或 size budget。
- fence-aware eviction。
- 资源类型独立上限。
- Worker Restart 时完整清理。
- 不按 Session generation 无限复制 key。

---

# 34. CLI 与配置

推荐命令：

```bash
fun dev app.ts
```

更新模式：

```bash
fun dev app.ts --reload=auto
fun dev app.ts --reload=hmr
fun dev app.ts --reload=session
fun dev app.ts --reload=worker
fun dev app.ts --reload=off
```

语义：

- `auto`：完整决策树。
- `hmr`：优先 HMR；无安全边界仍降级 Session Reload。
- `session`：所有运行时代码变化使用 Sequential Reload。
- `worker`：所有变化 Worker Restart。
- `off`：只构建和显示诊断。

（`--reload=shadow` 随 Shadow Swap 移入附录 A.9，v1 不提供。）

配置示例：

```toml
[dev.reload]
mode = "auto"
state = "none"
defer_while_debugger_paused = true

[dev.reload.session]
drain_timeout_ms = 5000
interrupt_timeout_ms = 1000   # 须覆盖 interrupt cadence 周期（§32）
init_timeout_ms = 10000
dispose_timeout_ms = 2000
init_retry_limit = 1

[dev.reload.hmr]
enabled = true
max_updates = 32
max_retired_bytes = "64MiB"
allow_commonjs = false
allow_top_level_await = false

[dev.reload.watch]
debounce_ms = 30

[dev.reload.native]
plugin_change = "worker-restart"
abi_change = "worker-restart"
```

---

# 35. 日志

```text
[dev] update #42
      changed: src/scene.ts
      action: module-hmr
      boundary: src/app.ts
      build: 11 ms
      apply: 4 ms
      retired modules: 3
```

```text
[dev] update #43
      changed: src/config.ts
      action: sequential-session-reload
      reason: update reached entry without accept boundary
      host preserved:
        window
        gpu-device
        surface
        inspector
```

```text
[dev] update #45
      changed: plugins/physics.dylib
      action: worker-restart
      reason: plugin build id changed
```

```text
[dev] update #46
      action: session-reload
      reason: HMR accept callback failed
      previous session: tainted
```

---

# 36. 故障处理矩阵

| 故障 | 处理 |
|---|---|
| 文件读取失败 | 保持旧版本，显示诊断 |
| zabel transform error | 保持旧 Session |
| syntax/compile error | 保持旧 Session（compile error 在新 Session 预检中发现，销毁新 Session 即可，§12.1） |
| HMR instantiate error | 保持旧 Session |
| HMR dispose error | taint + Session Reload |
| HMR prune error | taint + Session Reload |
| HMR evaluate error | taint + Session Reload |
| HMR accept error | taint + Session Reload |
| HMR registry commit error | Session Reload；必要时 Worker Restart |
| Framework refresh apply error | Session Reload（不猜测性保留组件状态，§23） |
| application dispose 抛错/超时 | 记录诊断，继续 Reload（dispose 为 best-effort，§14.1） |
| snapshot 失败（required） | 本次 Update 中止，旧应用继续运行（§15.3） |
| restore 失败（best-effort） | 记诊断、丢状态、照常发布（§15.2） |
| restore 失败（required） | 不发布，走 init 失败路径（§15.3） |
| Sequential init error / init 超时 | 保留最后一帧并显示错误；同一 Update 最多自动重试一次，之后进入 Vacant 模式等待保存（§12.2） |
| 发布后首帧/首 tick 失败 | Overlay；同一 Update 重试一次；再失败进入 Vacant 模式 |
| Reload 窗口超时 | cancel/interrupt 初始化中的新 Session；失败则 Worker Restart |
| SessionLease 无法归零 | 先 cancel 后 interrupt；失败则 Worker Restart（§10.2） |
| plugin ABI mismatch | Worker Restart |
| Worker crash（含 Update 在途） | WorkerSupervisor 重启 Worker，以最新 Update 重建 |
| GPU Device lost | 重建 HostCore 或 Worker Restart |
| debugger paused | 延迟 apply（含自动 Worker Restart，§29.4） |
| retired 内存超预算 | Session Reload（HMR 与 Framework Refresh 共用，§33.1） |
| stale callback | native cleanup 后丢弃 JS callback |

---

# 37. 实施计划

## 阶段 0：生命周期审计

审计：

- 所有 native → JS callback。
- 所有 process-global JS Root。
- 所有异步 task。
- 所有 plugin thread。
- 所有 GPU callback。
- 所有 HostOwned 候选资源。
- 所有 Session teardown 路径。

退出条件：

- 不存在未标记 owner 的长期 JS callback。
- 不存在 plugin global 中未登记的 JS Root。

与 FNABI 实现进度对表：plugin 侧不变量以 FNABI §22 为准。

## 阶段 1：HostCore 与 Disposable Session

实现：

- HostCore / SessionHostView 分离。
- `createSession` / `destroySession`。
- SessionId / Epoch。
- CallbackRef + Root Handle 表（§27.8）。
- SessionLease。
- Sequential Session Reload。
- Native Error Overlay。
- Native Plugin 产物（artifact digest / build ID）watch 与 Worker Restart 触发——§8 第 3 步的 `native_changed` 输入 day-one 需要，不能等到阶段 6。

这是必须优先完成的 MVP。**不含 debugger/inspector**（依赖 W2）。

现状注：Session = Runtime 的引擎侧能力大体具备（多 Runtime 共存、断言加固销毁、interrupt）；本阶段主要工程量在 fun 侧 HostCore/SessionHostView 拆分与 BindingRouter。zjs 侧不是零新增：小增量 = Root Handle 表 API 与 epoch-safe deref/release（§27.8，现不存在）。

## 阶段 2A：Scope 与异步安全（HR-P2A）

异步安全正确性件。前置仅阶段 1（HR-P1），**不依赖任何序列化**。

实现：

- HostScope。
- SessionScope。
- ResourceHandle owner。
- CancellationToken。
- native-only completion。
- event barrier。
- stale callback 检测。
- request drain。

## 阶段 2B：状态迁移（HR-P2B）

snapshot/restore 状态迁移。前置 = 阶段 2A + SER-SNAPSHOT。

实现：

- 结构化状态序列化原语（§27.9 = SER-SNAPSHOT profile，供 §15 使用）。
- §15 状态迁移策略（`none`/`best-effort`/`required`）与 §12.1 第
  10/13 步的 snapshot/restore 接线。

## 阶段 3：ESM HMR（HR-P3）

前置 = 阶段 2A + bytecode metadata 侧车载体（PERF-SIDECAR，§27.6）。

实现：

- ModuleIdentity / Version / Instance。
- compile / instantiate / evaluate 公开 API 化。
- **module registry 多版本化重构**（§27.4，引擎侧主要工作量；含 evict/replace 入口与查找去线性化）。
- ModuleGraph。
- SCC。
- UpdateOverlay。
- `import.meta.hot`。
- HotDataRegistry。
- HotScope。
- bytecode metadata 侧车中的 `origin_module_instance_id`（§27.6，与 IC/typed plan 共享侧车设计）。
- memory budget fallback。

## 阶段 4：Framework Fast Refresh

实现：

- RefreshAdapter。
- component signature。
- state compatibility。
- boundary remount。
- framework error recovery。

## 阶段 5：（已移出）Guarded Shadow Swap

移至附录 A；恢复条件与实施清单见 A.11。编号保留以便与 v1.1 对照。

## 独立工作项（与阶段并行排期，各有独立设计评审）

**W1：bytecode 序列化器**

- heap-independent artifact 格式(SER-ARTIFACT profile,挂 SER-CORE 编码内核;v1.4 修订,见冻结项 21 注)。
- 落地后接入 DevCoordinator Build Cache 的 bytecode 层，并使 §12.1 的 compile 前移成为可能。
- 阻塞项：无（v1 全量重编译可用）；但 save-to-first-frame 目标的达成大概率依赖它。

**W2：zjs 最小 CDP backend**

- executionContext created/destroyed、scriptParsed/failed、canonical URL、source map URL、断点基础。
- 现状为零实现；既有原材料：source location 表、backtrace 帧、disassembler。
- 阻塞阶段 6 的 InspectorProxy、断点重绑与 REPL context 切换。

## 阶段 6：完整开发工具（依赖 W2）

实现：

- InspectorProxy。
- URL breakpoint 重绑。
- REPL generation 切换。
- Program status。
- update metrics。
- worker auto reconnect。

（原阶段 5 Guarded Shadow Swap 已移出 v1，见附录 A；恢复条件见 A.11。）

---

# 38. 测试计划

## 38.1 Session 测试

- 连续创建和销毁 1000 个 Session。
- old callback 晚到。
- SessionLease 与 destroy 竞态。
- Promise completion 晚到。
- timer cancellation。
- interrupt 无限循环。
- finalizer 不重新进入 JS。
- Sequential Reload 初始化失败（含重试上限与 Vacant 模式）。
- compile 预检失败：旧应用不受影响。
- 异步 factory `await` timer/IO 后正常完成初始化（Reload 窗口运转豁免）。
- application dispose：调用顺序、超时放弃、抛错继续。
- 动态 class id 在 1000 次 Reload 后不增长（复用静态槽；进程级分配器永不回收、u16 上限）。
- HostCore 不重建。

## 38.2 Reload 窗口与 Event Barrier 测试

- pointer move 合并。
- keyboard FIFO。
- touch sequence。
- resize 合并。
- HostCore 帧调度重新武装。
- server backlog。
- GPU completion 原 owner 路由。
- queue overflow。

## 38.3 HMR 测试

- self accept。
- dependency accept。
- 多 importer。
- 多 entry。
- SCC。
- dynamic import。
- export shape change。
- module rename/delete。
- boundary 缺失。
- dispose throw。
- evaluate throw。
- accept throw。
- old ModuleInstance GC。
- HotScope 泄漏。
- CJS 降级。
- TLA 降级。

## 38.4 Shadow 测试

随 Shadow Swap 移至附录 A.10。

## 38.5 GUI 测试

- Window 不重建。
- Device/Queue/Surface 不重建。
- 最后一帧保留。
- error overlay。
- first frame。
- GPU fence release。
- texture/pipeline cache 复用。

## 38.6 CDP 测试（依赖 W2）

- HMR scriptParsed。
- Session context destroy/create。
- URL breakpoint 重绑。
- debugger paused pending update。
- REPL context change。
- Worker Restart proxy reconnect。

## 38.7 Framework Refresh 测试

- 签名兼容：替换实现且状态保留。
- 签名不兼容：remount 最近边界。
- 模块被非组件代码使用：降级 ESM HMR。
- adapter analyze/apply 失败：降级 Session Reload。
- 连续 refresh 的 retired 内存计入共用预算（§33.1）。

## 38.8 压力测试

- 1000 次 Sequential Reload。
- `ZJS_GC_STRESS` 下 1000 次 Sequential Reload。
- 1000 次 HMR。
- 高频保存。
- HMR 与 file watch 并发。
- request drain。
- ASAN。
- TSAN。
- GPU validation layer。
- plugin stale callback。
- OOM。
- worker crash。

---

# 39. 验收标准

| 场景 | 验收要求 |
|---|---|
| TS 类型变化但 JS 输出不变 | 不刷新 runtime |
| syntax error | 旧应用继续运行 |
| 普通 JS 修改 | HostCore 保留，Session 重建 |
| GUI Reload | Window、Device、Surface 不重建 |
| 无 HMR boundary | 自动 Session Reload |
| HMR callback throw | Session tainted 并 Reload |
| timer 模块更新 100 次 | timer 数量不增长 |
| listener 模块更新 100 次 | listener 数量不增长 |
| stale native completion | 不进入新 Session |
| plugin binary 更新 | Worker Restart |
| 状态迁移 best-effort 失败 | 丢状态继续完成 Reload，有诊断 |
| 状态迁移 required snapshot 失败 | 旧应用保持运行，Update 中止 |
| Sequential init 连续失败 | 重试一次后停止，Overlay 等待保存，无 reload 循环 |
| debugger paused | apply 延迟（依赖 W2） |
| HMR retired memory 超限 | 自动 Session Reload |
| GPU command in flight | fence 后释放 |
| JS 无限循环 | supervisor 可以恢复 |
| 生产模式 | 无 HMR module 间接层 |

---

# 40. fun 与 zjs 的职责边界

| 能力 | fun | zjs |
|---|---:|---:|
| FileWatcher | ✓ | |
| zabel 增量转换 | ✓ | |
| ModuleGraph | ✓ | |
| UpdatePlanner | ✓ | |
| HostCore | ✓ | |
| BindingRouter | ✓ | |
| Epoch Barrier | ✓ | |
| ResourceScope | ✓ | owner primitive |
| Session lifecycle orchestration | ✓ | Session primitive |
| JS Heap 创建/销毁 | | ✓ |
| interrupt | 调用 | ✓（已具备） |
| compile/instantiate/evaluate | 编排 | ✓ |
| ModuleInstance 多版本 | registry policy | ✓（需重构） |
| Root Handle 表 | 调用 | ✓（需新建） |
| 结构化状态序列化 | 调用 | ✓（需新建） |
| bytecode 序列化（W1） | Cache 编排 | ✓（与 typed plan 联合） |
| HMR propagation | ✓ | |
| old module GC | root 管理 | ✓ |
| Framework Refresh | ✓ / framework | |
| GPU/Window persistence | ✓ | |
| InspectorProxy | ✓ | protocol events（W2） |
| Native Plugin restart | ✓ | |
| JS callback generation tag | policy | primitive |

---

# 41. 冻结决策

## 41.1 直接冻结（v1.2 修订后）

1. HostCore 生命周期长于 zjs Session。
2. HostCore 使用严格 allowlist。
3. Sequential Session Reload 是 v1 默认且唯一的 Session Reload 策略。
4. **Session = zjs Runtime**：一个 Session 独占一个 Heap、一个 atom 表、一个 root set；不采用共享 Heap 的 Realm 作为 Session。
5. **v1 单 JS 线程模型**：一个 App Worker 内同一时刻只有一个 JS 执行线程；Guarded Shadow Swap 及其线程模型移入附录 A，不冻结。
6. commit（Epoch Barrier 的原子发布步骤，§11）中不执行用户 JS；dispose/snapshot/evaluate/restore 均发生在 commit 之前的 Reload 窗口内。
7. 发布后不承诺通用 rollback。
8. HMR 必须依赖完整显式 boundary。
9. HMR callback v1 只允许同步。
10. HMR 进入 dispose 阶段后的任何失败（dispose/prune/evaluate/accept/registry commit）使 Session 视为 tainted；dispose 之前的失败（transform/compile/instantiate/export validation）保持旧程序、不 taint。
11. CJS 和 affected TLA 使用 Session Reload。
12. 不原地修改旧 ModuleRecord。
13. 不为所有 export 增加通用代理层。
14. 不实现通用 Heap Snapshot 迁移。
15. Native Plugin binary 和 ABI 变化 Worker Restart。
16. **Native Plugin 以 FNABI 为权威规范**：本设计只定义映射与增量，hot reload 增量（candidate_mode 等）走 FNABI v0.4 议题，不设平行规范；Session teardown 与 FNABI §22.4 七态机对表，不另立状态机。
17. Native Plugin 不通用 `dlclose`（与 FNABI §22.7 一致）。
18. 所有异步 callback 携带 Session、Epoch 和 Scope——**方向冻结**；生产构建的每 job 元数据与检查的实现形态走 PERF-MECHANISM-LEDGER，A/B 定价后冻结。定价失败的降级形态：开发构建完整元数据，生产构建保留 Session 存活性验证所需的最小 owner 标记（§3.2 条 1/2 的硬前提，不可移除）。
19. stale completion 必须完成 native cleanup。
20. 生产同步 builtin path 不增加 reload branch。
21. ~~bytecode 序列化格式与 type-directed plan 离线 emitter 输出为同一交付物,不做两种落盘格式~~ **(v1.4 修订)**:序列化按 roadmap v1.5 的 **SER-CORE + profile** 模型——W1 的 artifact 格式是 **SER-ARTIFACT profile**,与 SER-SNAPSHOT(本文 §27.9/§15)、SER-MESSAGE(进程模型)共享 SER-CORE 编码内核(framing/section directory/atom 表原语/图遍历/版本空间/fuzz 基建),但各 profile 的 header、兼容策略与生命周期语义独立。禁止的是**不共享 Core 的第二套编码体系**,不是 profile 差异。typed plan 的「离线 emitter 输出」经 1.0 修订为 Zig 源码路线,不是序列化格式;artifact 的 typed 侧对接物是其 §10.5 容器清单。
22. **CDP backend 为独立工作项 W2**，不进入阶段 1 MVP。
23. Sequential init 失败同一 Update 最多自动重试一次。

## 41.2 需要 benchmark 后冻结

- watcher debounce。
- Session drain timeout。
- interrupt timeout。
- snapshot 大小和时间预算。
- HMR 最大连续次数。
- retired memory threshold。
- event barrier queue size。
- GPU cache budget。
- save-to-first-frame 目标（按 v1 全量重编译的现实设定；W1 落地后重估）。
- JobMetadata 生产形态（PERF-MECHANISM-LEDGER A/B）。

---

# 42. 最终结论

修订后的完整架构是：

```text
DevCoordinator
    比 App Worker 活得更久

HostCore
    比 zjs Session 活得更久
    但只保留严格允许的资源

zjs Session（= JSRuntime）
    可以快速、彻底、确定性地销毁和重建
    （引擎原语大体具备；zjs 侧小增量 = Root Handle 表，§27.8）

Framework Fast Refresh
    只保留框架能够证明兼容的状态

Explicit ESM HMR
    只处理具有完整 accept boundary 的局部更新

Sequential Session Reload
    是普通应用的默认正确性路径

Worker Restart
    是 native、ABI、hang 和不可恢复错误的安全边界

Guarded Shadow Swap
    移出 v1（附录 A），恢复前必须先裁决线程模型
```

最终决策树：

```text
源代码变化
   ↓
runtime output 未变化
   └─ 仅更新诊断

native / ABI 变化
   └─ Worker Restart

framework 能证明兼容
   └─ Framework Fast Refresh

ESM graph 每条路径都有 boundary
   └─ Module HMR

其他普通代码修改
   └─ Sequential Session Reload

任何生命周期不变量失效
   └─ Worker Restart
```

最关键的工程顺序是：

```text
先完成：
    HostCore
    Disposable Session
    Async ownership（含 Root Handle 表）
    Sequential Reload

再完成：
    结构化序列化
    Module HMR（含 registry 多版本化）
    Framework Refresh

并行推进：
    W1 bytecode 序列化器（与 typed plan 联合）
    W2 zjs 最小 CDP backend

未来（附录 A）：
    Guarded Shadow Swap
```

这套顺序避免为了追求开发期“无感更新”，过早把 zjs、Native Plugin 和所有 Host API 复杂化。

fun/zjs 最合理的 Hot Reload 基础不是无条件保留旧状态，而是：

> **把真正昂贵且能够证明安全的 native 状态放入 HostCore，把任意且难以证明兼容的 JS 状态限制在可销毁 Session 中；局部状态保留必须由明确的 HMR boundary、framework adapter 或结构化迁移协议负责。**

---

# 附录 A：Guarded Shadow Swap（未来工作，未冻结）

本附录保存 v1.1 的 Shadow Swap 设计全文（含 v1.2 的语义修正），供未来恢复时使用。**本附录内容不属于 v1 交付范围，不参与冻结。**

## A.0 移出 v1 的原因与未决线程模型

owner 裁决（2026-08-26）：v1 砍掉 Guarded Shadow Swap。理由：

1. **线程模型未裁决，且是硬前提。** 引擎 Runtime 严格线程亲和（`owner_thread_id` 断言、无跨线程句柄），Candidate 与 Active 并存只有两种模型，各有实质代价：
   - **同线程时间片**：Candidate 的 evaluate、scene 构建、shader 预热切片插进 Active 空闲期。实现简单，但会阻塞 Active 帧回调——Shadow 相对 Sequential 的增益缩水到接近“末帧保留”（Sequential 已提供）。
   - **thread-per-session**：Candidate 在第二线程构建，发布时 BindingRouter 切换事件派发目标线程，Retiring 在其 owner 线程 drain/destroy。引擎多线程多 Runtime 能力已具备，但 Epoch Barrier 变为跨线程协议、HostScheduler 需覆盖两个 JS 线程的 GPU 并发、§10.3 的单 JS 线程模型需要重述。
2. **Sequential 已交付核心收益**（HostCore 保留 + 末帧保留），Shadow 的增量收益在线程模型明确前无法评估。
3. Candidate capability 体系牵连 Host API 全面区分 phase 与 FNABI ABI 面增量，工程量大且遮蔽 v1 关键路径。

## A.1 启用条件（原 §13.1）

必须同时满足：

1. 应用使用明确的 Application Lifecycle。
2. 所有 host registration 都能 staged。
3. 所有已加载 Native Plugin 声明 Candidate-safe。
4. Candidate Mode 下危险 API 能被拒绝。
5. 没有未知的 process-global JS callback。
6. Active + Shadow 内存不超预算。
7. HostCore 资源并发规则已定义。
8. 应用未使用不受控的 native capability。

任一条件不满足：

```text
Sequential Session Reload
```

## A.2 Candidate Mode（原 §13.2、§24.3、§14.1 candidate 条款合并）

Shadow Session 创建时：

```text
session_phase = candidate
```

默认允许：

- 读取模块和只读资源。
- 创建 JS object。
- 构建 scene graph。
- 编译 shader。
- 创建 pipeline。
- 创建 session-owned GPU resource。
- 预热 Host cache（豁免理由：内容寻址 cache 的写入是幂等的，不构成可观察的 persistent global state 变更）。
- 注册 staged BindingSet。
- 执行纯计算。
- 使用只读配置。

默认禁止：

- Surface presentation。
- audio playback。
- 网络监听。
- 接管 server request。
- 外部网络写请求。
- 文件写入。
- process spawn。
- 修改 persistent global state（内容寻址 cache 预热除外，见上）。
- 向 Active Session 发送 JS object。
- 注册 process-global callback。
- 调用未声明 Candidate-safe 的 Native Plugin API。
- 替换 Active frame callback。
- 读取 Active Session 私有 GPU resource。
- 直接复用旧 JS wrapper。

违规时抛出：

```text
ERR_CANDIDATE_SIDE_EFFECT
```

故障与验收语义：

- Candidate 违规或 prepare 阶段出错：丢弃 Candidate，Active 继续运行；Candidate 的任何失败不得污染 Active 的状态与事件流。
- Candidate 发布前不接收真实业务事件。
- Candidate OOM：降级 Sequential Reload（A.7）。

所有 Queue 使用经过 HostScheduler；Candidate 阶段 HostScheduler 额外负责 Active/Candidate 的 cache warm-up 并发与 phase capability 检查。

`defineApplication` 的 top-level 与 factory 在 Candidate Mode 下受 capability 限制。

## A.3 Shadow 流程（原 §13.3）

```text
Active Session 继续运行
        ↓
创建 Candidate Session
        ↓
Candidate Mode evaluate
        ↓
prepare application
        ↓
生成 staged BindingSet
        ↓
Candidate READY
        ↓
等待 Active safe point
        ↓
进入 Epoch Barrier
        ↓
可选 snapshot / restore
        ↓
原子发布 Candidate BindingSet
        ↓
active_epoch++
        ↓
Candidate → Active
        ↓
旧 Active → Retiring
        ↓
恢复事件派发
        ↓
异步 drain 并销毁 Retiring Session
```

未发布的 Candidate Session 可被更新的 Update 取消（对应主文 §31 的取消规则）。

## A.4 不承诺通用回滚（原 §13.4）

发布 BindingSet 后，不承诺自动切回旧 Session。

原因：

- 新 Session 可能已经接收输入。
- 新 handler 可能已经响应请求。
- `onPublished()` 可能产生外部副作用。
- 新 Session 可能已经提交 GPU command。
- 两个 Session 的状态可能已经分叉。

旧 Session 保留为 Retiring，仅用于：

- 完成已进入旧 Session 的 request。
- 等待现有 SessionLease 归零。
- drain 已入队的 microtask/job（与 request 共用 drain timeout）。
- 执行 cleanup。

它不是通用回滚副本。

## A.5 发布后失败（原 §13.5，含 v1.2 重试修正）

如果新 Active 在首帧或首个 tick 失败：

```text
显示 Native Error Overlay
      ↓
标记新 Session unhealthy
      ↓
同一 Update 最多再尝试一次 Session Reload
      ↓
仍失败 → Overlay + 等待下一次保存
      ↓
生命周期不变量失效 → Worker Restart
```

不得假装可以无条件恢复旧 Session；也不得对同一份代码做 reload 循环。

## A.6 状态迁移的 Shadow 语义（原 §15.3 Shadow 行）

`required` 策略下：snapshot 或 restore 失败时，丢弃 Candidate，Active 继续运行。

## A.7 Shadow Memory（原 §33.2）

Shadow Swap 需要同时容纳：

- Active Heap。
- Candidate Heap。
- Host cache。
- snapshot buffer。
- candidate resources。

超预算时自动降级 Sequential Reload。

## A.8 Plugin Candidate-safe 声明 = FNABI v0.4 议题（原 §26.2）

Plugin manifest 增加：

```text
candidate_mode = unsupported | read-only | full
```

语义：

- `unsupported`：加载该 plugin 后禁用 Shadow Swap。
- `read-only`：Candidate 只能调用声明为只读的 API。
- `full`：plugin 完整实现 staged registration 和 phase isolation。

此字段与 Candidate-safe API 声明是对 FNABI 的 ABI 面增量（提议新增到 FNABI §24.1 manifest 的 `fun.native` 段，非现存字段），恢复 Shadow Swap 时作为 FNABI v0.4 议题提交，不设平行规范。

职责划分：fun 负责 capability 检查与拒绝；zjs 只提供 execution phase metadata（`session_phase` 标记）。

## A.9 CLI 与配置（原 §34 shadow 部分）

```bash
fun dev app.ts --reload=shadow
```

- `shadow`：满足条件时 Shadow Swap，否则降级 Sequential Reload。

```toml
[dev.reload.shadow]
enabled = true
max_candidate_heap = "256MiB"
snapshot_limit = "4MiB"
snapshot_budget_ms = 2
restore_budget_ms = 2
```

`[dev.reload.session] strategy = "auto"`（sequential/shadow 自动选择）随之恢复。

日志示例：

```text
[dev] update #44
      changed: src/app.ts
      action: guarded-shadow-swap
      active epoch: 18
      candidate epoch: 19
      state migration: best-effort
```

## A.10 Shadow 测试（原 §38.4）

- Candidate 写文件被拒绝。
- Candidate 网络写请求被拒绝。
- plugin Candidate-safe 检查。
- Active 与 Candidate GPU cache warm-up。
- Candidate 禁止 presentation。
- snapshot 超时。
- restore 失败。
- Candidate OOM 降级。
- publish 后 old Session drain（含 microtask/job drain）。

## A.11 恢复主线前必须裁决的问题清单

1. **JS 线程模型**：同线程时间片 vs thread-per-session（见 A.0；引擎线程亲和为硬约束）。
2. thread-per-session 时：Epoch Barrier 的跨线程协议（两线程 stack 状态的一致性判定）。
3. thread-per-session 时：HostScheduler 对两个 JS 线程的 GPU 提交与 cache 并发规则。
4. Retiring Session 在其 owner 线程上的 drain 与 destroy 编排。
5. FNABI v0.4：candidate_mode 与 Candidate-safe API 声明。
6. Candidate capability 检查在 Host API 面上的实现成本（每个 API 的 phase 检查是否进入生产构建——若是，走 PERF-MECHANISM-LEDGER）。
7. Shadow 内存预算与降级阈值（benchmark）。
8. 恢复时的实施清单（原 v1.1 阶段 5）：Candidate phase、capability enforcement、staged BindingSet、HostScheduler 的 candidate 扩展（cache warm-up 并发与 phase 检查）、`ResourceHandle.allowed_phases` 字段恢复、Shadow memory budget、Retiring Session drain。其中 structured state migration（§27.9）与 HostScheduler 基础已在主线。约束：Shadow Swap 不应早于 Session ownership 与 candidate capability 审计完成。

恢复 Shadow Swap 的前提是上述 1-6 全部有裁决记录，且阶段 1-3 与 FNABI 实现（PluginInstance/七态机）已落地。
