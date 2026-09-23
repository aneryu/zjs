# Runtime 契约

Runtime 是独立引擎实例的资源所有者，协调执行、GC、微任务与销毁。
公开 API 和宿主句柄以 [Public API contract](public-api-contract.md) 为准；
收集器约束以 [GC invariants](gc-invariants.md) 为准。
本文保存当前责任边界；已完成的重构任务、审查和验收流水留在 Git 历史。

## 所有权

| 负责人 | 职责与边界 |
| --- | --- |
| [`JSRuntime`](../src/runtime.zig) | 实例生命周期、所属线程、共享资源、执行入口和子系统协调 |
| [`GC`](../src/core/gc.zig) / [`gc_driver`](../src/core/gc_driver.zig) | JS heap 存储、预算、阈值、收集与弱处理；不决定宿主事件策略 |
| [`Execution`](../src/core/execution.zig) | 调用栈、VM/原生栈预算、重入和回溯；不保存 Realm globals |
| [`RealmContext`](../src/core/context.zig) | globals、原型、模块实例、Realm-local PRNG 与 bootstrap 事务 |
| [`jobs`](../src/core/jobs.zig) | FIFO、checkpoint、活动任务和 WeakRef kept-alive；不拥有定时器或 I/O |
| [`RootSet`](../src/core/roots.zig) | 宿主句柄和 root provider；弱槽不作为强根 |
| 类型与原生绑定 | Runtime 局部类型身份、不可变 native entry 和绑定存储 |

职责分组不要求每组都成为独立堆对象或嵌套结构。VM 栈和活动执行状态的
热布局需保留；仅为对齐文档示意而移动字段不构成重构理由。
构造中与已发布的 Realm 索引仅表示成员关系，不负责保活。
对象附属表、借用引用登记和 GC 弱引用链各有生命周期，不能合并成永久强根。

## 创建与销毁

唯一生命周期入口是 `Runtime.create(allocator, options)` / `destroy()`。
Runtime 不作为可复制值使用，子系统和 observer 必须绑定其最终地址。

创建顺序：选 allocator → 分配 Runtime → 独立创建 GC、atoms、classes、shapes
→ 一次性建立 Runtime 默认状态与配置，保存四个子系统指针
→ `gc.activate` 接入完整 Runtime 并启用分配服务 → 返回可用实例。
子系统创建不读取 Runtime；atoms 显式借用分配服务和 GC，classes 借用
分配服务和 atoms，shapes 借用分配服务、atoms 和 GC。分配服务只保存上下文，
Runtime 组装前不经这些服务分配。class 动态注册和 shape 单元操作显式接收
Runtime；三个子系统不保存 Runtime 反向指针，也没有后置绑定步骤。
RootSet 默认值即可使用，按需取得内联数组视图，不保存内联自引用。
内部地址在各自的 `create` 内固定，失败自行清理，成功后由 Runtime
持有并负责销毁。Runtime 按依赖顺序回滚已完成的子系统，不对半初始化对象
运行完整的托管堆清理。parser/compiler 的临时 atom 表保留值式 `init/deinit`，
不参与 Runtime 的子系统所有权转移。
固定执行服务由 `engine_services.zig` 提供，不参与 Runtime 初始化，
也不增加宿主参数。Context/global 安装仍由 Context 和执行层负责。

销毁前，宿主应停止外部访问、释放句柄和 Realm 引用，并保证没有活动执行。
先退役驻留执行器，再清理任务、根和 GC/原生资源；类型定义和 atom 表必须
存活到依赖它们的 finalizer 完成。GC 在托管堆清理后继续存活，直到原生
资源清理结束，再销毁 GC，最后使用保存的 allocator 释放 Runtime。
销毁过程可能再次产生 JS 清理任务，现有后续队列清理不能按“重复”删除。
外部 Atomics 等生产者必须先完成注销协议，才能释放唤醒信号和 Runtime。

## 固定执行服务

`JSRuntime` 负责实例资源和生命周期；固定引擎实现由编译产物决定。
[`engine_services.zig`](../src/engine_services.zig) 用普通 Zig 函数提供固定的
执行服务，不是可安装、可替换或可部分初始化的 hooks 表。
`JSRuntime.create(allocator, options)` 仍是真实的类型内构造函数；不增加外置工厂、
创建别名或 `createWithHooks`，宿主不提供执行实现。

### 职责与接口

| 服务 | 消费者 | 所有者及边界 |
| --- | --- | --- |
| `installStandardGlobals(ctx, global)` | `RealmContext.installStandardGlobals` | Context 保留 bootstrap 事务、所有权检查和回滚；exec 安装标准 globals |
| `materializeContextGlobal(ctx)` | `RealmContext.globalObject` | Context 保留已有 global 快路径；exec 完成惰性创建 |
| `materializeBuiltinNamespace(rt, global, kind)` | `Object.materializeBuiltinNamespaceAutoInit` | exec 构造 namespace；Object 保留缺失 global/结果的校验 |
| `runMicrotask(rt)` | `jobs.runCheckpointStep` | exec 只执行一步；FIFO、checkpoint 策略、终止、重入和异常报告仍归 jobs |
| `internalBuiltinRecord(domain, id)` | Runtime 同名查询方法 | 查询 exec 的静态表；保留 domain/id 边界检查、host 域和缺项返回 null |
| `standardGlobalOwnPropertyCapacity()` | Runtime 同名查询方法 | 与标准 globals 共用容量数据源，不保存 Runtime 副本 |

过去的 `EngineHooks`、Runtime 的 `hooks` 指针、两个可空 materializer 副本
和 `internal_builtins` slice 均已移除。固定执行代码没有 Runtime 所有权，
无需 GC 标记、构造回滚或析构；宿主动态回调与外部 native entries 的生命周期
保持各自原契约，不受这次固定服务整理影响。

### 明确的依赖边界

依赖关系是 core 的指定调用点 → engine_services → exec 实现；exec 仍使用
core 类型。用户裁决先放宽 core 不依赖 exec 的代码组织限制，职责边界继续
保留。服务模块直接导入实现 owner，不通过 `zjs` 或 `exec/root.zig` 聚合入口。
不再创建 `attachEngineHooks` provider，生产、测试、embedding、OOM 构建均
通过同一编译模块内的相对路径得到服务和类型。

这消除了 build 模块的 engine/provider 双向接线，**不消除源码层的所有
互引，也不让 core 成为独立执行后端库**。core 通过这个有范围的服务入口
调用固定实现，不扩散到 CLI、event loop、test262 或宿主策略。若未来需要
独立 core 或多执行后端，应重新设计类型与装配边界，不恢复可变全局注册表。

Runtime 构造完全不涉及服务安装，因而没有“函数内 import 以等待 provider
解析”的步骤。普通函数的签名明确服务边界，实际类型与调用循环由 Zig 编译
检查验证，不依赖另一编译模块反向取得 engine 的类型身份。

### 错误、初始化与生命周期

- 固定代码和 builtin records 与所在 engine 编译产物同寿命；Context 尚未
  创建时即可查询 records。这与原先 Runtime 构造时已绑定表的实际行为一致。
  不同编译模块各自解析类型和配置，不跨 engine 模块共享 Zig 实例状态。
- 服务入口仅转发，不增加分配、缓存、线程切换或额外初始化流程。Runtime
  稳定地址、owner-thread、GC 最后激活、部分构造回滚保持原契约。
- Context 在安装 globals 之前仍检查 Runtime/Realm 所有权，在采用 global
  后失败时仍回滚 intrinsics 和关联；服务不绕过或重复这套事务。
- `runMicrotask` 保持 `HostError!RunOneStatus`，不自行排空队列；jobs 仍负责
  前后终止检查、reportException、重入拒绝及状态恢复。
- bootstrap 与 namespace 服务保持原回调的 `anyerror` 传播接口及调用方的
  既有错误转换；这次不扩大或缩窄错误集合，也不增加吞错或 unreachable。
- 删除可空执行实现字段后，缺失 hook 不再是合法 Runtime 的状态。未知
  namespace、无效 builtin id、错误 Realm/global 等实际输入校验仍保留。
- Runtime 的 builtin/容量查询方法保留。内部字段删除会改变 Zig 布局，不
  宣称稳定 C ABI、体积改善或性能提升；公开方法和宿主 handle 契约不变。

### 回归覆盖与对抗性顺序

`tests/core.zig` 的 fixed-services 回归覆盖未创建 Context 时的静态 builtin
查询、无效域/id、两个 Runtime 的同一静态 record、惰性 Math/JSON namespace
以及独立 globals 和显式微任务队列。原有构造失败回滚、自引用、bootstrap
失败、异常/终止/重入测试继续保留；旧 hook 副本指针断言由实际服务行为替代。

评审必须核对以下顺序：bootstrap OOM 后重试不留半安装状态；惰性物化重入
仍使用原事务；checkpoint/异常 handler 重入及终止不绕开 jobs；无效 builtin
id 仍有界；多个 Runtime 的 globals、异常、roots 和队列不串实例；构造失败
与完整销毁的路径不混用。固定服务本身没有额外生命周期。

构建验证覆盖 `check`、定向 Runtime 测试、公开模块 `test-embedding` 和
最终一次全量 `test`。OOM 模块接线需静态确认旧 provider 没有残留依赖；完整 OOM 注入仍按
既有 nightly 分层执行，批/发布门在对应边界执行。编译或测试通过不作为性能证据。

## 分配与预算

### 职责边界

| 所有者 | 当前职责 |
| --- | --- |
| `JSRuntime` | 宿主 allocator 与子系统生命周期；协调收集边界和 heap-limit 重试 |
| `runtime_alloc.zig` | Runtime 的 native 分配与配对释放、分配诊断；拒绝带 GC 前缀的类型 |
| `core/gc_alloc.zig` | Registry 的 GC cell 分配与释放、前缀/FAM、存储路由、载体审计；构造器仍负责语义初始化 |
| `gc_storage.Owner` | GC slab、借用的 block/nursery 路由与载体审计状态；随 Registry 管理生命周期 |
| `heap_budget.Budget` | heap 准入检查、受控重试及字节计数；检查不预留额度 |
| GC Registry | 发布/撤销发布、调用预算 charge/discharge、追踪与回收 |
| Object/Shape/String 等构造器 | 语义初始化、引用安装、根保护，以及按发布状态处理失败清理 |

分配入口跟随所有者：普通内存使用 Runtime 的 native allocator/辅助方法，
GC cell 使用 Registry 的分配方法。`memory.zig` 及 `core.memory` 聚合入口
已移除，不再提供按类型自动混合 native/GC 的通用分配器。实现文件不增加
独立管理对象，已有 slab/block/extent/nursery 路由保持原策略。

GC 分配前检查 heap 预算，发布时才计入预算。Runtime 的诊断账继续记录
native 和 GC 分配/释放事件，保持现有统计口径；它不是存储所有者，
也不代替 GC heap 预算。

`*NoTrigger` 跳过每次分配的 probe/notify 和 heap-limit GC 重试，GC 类型
仍执行只检查额度的 `checkOnly`。普通 native 分配不受 heap limit 管理。
Runtime 的 `setAllocationDiagnosticLimit/allocationDiagnosticLimit` 是
Debug/test 分配诊断的失败注入限额，不是 Runtime 的 JS heap limit。
允许收集的准备由调用方在安全边界完成。

未发布 GC 分配失败时，由构造方按原存储路由清理；已发布 cell 按类型和
Registry 的协议清理，不能直接当作原始分配释放。属性 storage 等已发布
子 cell 可在构造失败后留给 GC 回收。发布本身不提供存活引用；从发布到
安装引用之间，调用方仍须遵守该路径既有的根保护或不可收集约定。

### 分配与统计口径

- 创建 Runtime 时必须显式传入宿主 allocator，引擎不提供默认值；其底层状态
  必须保持有效直到 `destroy()` 返回。历史比较及额外实验见
  [allocator 待办](runtime-allocator-todo.md)。
- 普通原生分配使用宿主 allocator；GC 保留自己的 slab、block、extent 和
  nursery 存储。不能把 GC 前缀/FAM 分配交给普通 `allocator.free`。
- 编译临时存储与持久产物的分配/释放配对；不能通过全局切换 allocator
  混合二者。普通 allocator 不隐式回调 Runtime 触发 GC。
- `memory_limit` 限制 JS heap，权威为 `Registry.heap_budget`，不是进程 RSS
  或所有宿主内存。外部内存 token 负责计账和压力，不替宿主释放缓冲区。
- GC 分配在根保护的慢路径回收后至多重试一次；重试必须读取当前限额，
  因为清理或回调可能改变它。不能继续使用回调前捕获的上限。
- `gc_threshold` 是初次收集提示，后续随 GC 调整；Context 不保存和恢复旧值。
- VM `stack_size` 与 `native_stack_size` 分开管理，异常、重入和终止退出都
  恢复各自的执行记账。

当前 heap 口径计入 block 细胞尺寸类减前缀，以及已发布 extent/standalone
载体的 heap 字节；nursery 未计入 `allocated_bytes`。启用 nursery 前必须完成
其预算口径验证，不能把现有默认关闭路径的统计直接当作完整内存上限证明。

`memoryUsage` / `gcStats` 读取已维护计数；`gcDetailedStats` 才执行显式普查。
原生分配诊断不可用时用 `allocation_tracking_enabled=false` 标明，相关计数
为零不表示未分配。heap 统计独立可用。诊断 writer 失败不改变分配结果。

## 执行、checkpoint 与终止

执行入口检查 Runtime/线程，建立根、栈和重入状态；返回时恢复入口状态，
最外层按 microtask policy 执行 checkpoint。Context、模块调度和宿主调用必须
使用一致的异常与终止边界，不能私自吞掉待处理异常。

微任务保留 FIFO 和所属 Realm，取出任务到执行结束始终有根。JS finalization
job 与延迟原生 payload 清理是不同队列，不合并为一种泛型作业。

| 情况 | 行为 |
| --- | --- |
| `auto` | 最外层执行退出按策略排空 |
| `explicit` | 宿主显式调用 `runMicrotasks` |
| `scoped` | 最外层 scope 结束时排空；scope 按 LIFO 结束，结束操作可失败 |
| 已在 checkpoint 或 scope 内 | 不重复进入宿主排空路径 |
| exception handler 内再次排空 | `MicrotaskReentry` |
| 普通异常、无 handler | 返回异常，保留后续队列 |
| handler 成功 | 若未留下异常或终止状态，继续队列 |
| handler 失败或留下异常 | 返回宿主，保留后续队列；OOM/uncatchable 需重新分类 |
| 观察到终止 | 丢弃剩余当前队列并释放其根，返回 `Interrupted` |

普通 checkpoint 与模块/TLA 调度共用 `runCheckpointStep` 的任务前后终止检查
和异常报告；模块续作保持自身交错顺序。WeakRef kept-alive 在任务/checkpoint
边界清理，不按任意 GC 周期清理。

`terminateExecution` 是跨线程原子请求，调用者必须保证 Runtime 仍存活。
执行线程在安全边界观察请求；它不能强行打断宿主阻塞函数。
`cancelTerminateExecution` 只允许 owner thread 在执行/checkpoint 空闲时调用；
原子 exchange 之后的新请求保留。恢复不复活已丢弃的任务，也不回滚业务状态。
除明确声明线程安全的接口外，不得把 Runtime 操作视为可并发调用。

## 类型绑定

`Runtime.registerClass` 返回带 owner 与局部 class ID 的绑定；
[`native_object.registerType`](../src/core/native_object.zig) 返回同一 Runtime
所属的 `NativeType`。内置编号固定，动态编号仅在所属 Runtime 内有效，
不建立按名称去重的全局表，不注销或复用已发布编号。

创建/解包顺序：先确认绑定 owner；创建时验证非空 prototype 归属；解包时
确认值为对象并检查 `ownsObject`，再比较 class ID 和 native payload 有效性。
不同 Runtime 的同号类型不能互相解包。注册在可重入点前预留身份，失败回滚
不能越过嵌套注册已发布的编号。

`ownsObject` 复用 GC 成员资格查询，不保证所有路径 O(1)，也不证明对象仍可用：
尚未销毁的 condemned 节点可能仍属于 Runtime。宿主必须提供有效且有根保护的
值和绑定；不能拿失效裸指针调用查询来验证寿命。GC 内部清理协议保持独立。

## 后续范围

以下保留为独立工作，不由结构重构完成或本文存在推定已经交付：

- [Nursery 评估与阻塞](runtime-nursery-todo.md)：先正确性和预算，再性能与默认启用决策。
- [Allocator 额外实验](runtime-allocator-todo.md)：普通小分配/slab、长期 idle 与其他平台。
- Promise hooks、延续数据、GC 前后通知、独立 RequestInterrupt、跨线程压力通知：
  需按当前实际接口补齐生命周期与测试，不提前分配无用设施。
- 合成模块和异步宿主模块能力：分别定义失败、取消与保活协议。
- teardown 时禁止新增 FinalizationRegistry 作业：须先验证弱清理语义。
- 完整 Platform、线程池和类型热重载/注销：需求明确后再设计。

验证遵循 [verification-policy](verification-policy.md)。历史通过数量仅证明
对应版本，不替代当前改动的检查。
