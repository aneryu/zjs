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

唯一生命周期入口是 `Runtime.create(options)` / `destroy()`。
Runtime 不作为可复制值使用，子系统和 observer 必须绑定其最终地址。

创建顺序：选 allocator → 分配 Runtime → 原位初始化子系统 → 安装固定
`EngineHooks` → 返回可用实例。构造失败只回滚已完成资源，不对半初始化对象
运行完整销毁。引擎接线由命名模块 `engine_hooks` 提供，不依赖进程可变默认值，
也不增加宿主 Hook 参数。Context/global 安装仍由 Context 和执行层负责。

销毁前，宿主应停止外部访问、释放句柄和 Realm 引用，并保证没有活动执行。
先退役驻留执行器，再清理任务、根和 GC/原生资源；类型定义和 atom 表必须
存活到依赖它们的 finalizer 完成。最后使用保存的 allocator 释放 Runtime。
销毁过程可能再次产生 JS 清理任务，现有后续队列清理不能按“重复”删除。
外部 Atomics 等生产者必须先完成注销协议，才能释放唤醒信号和 Runtime。

## 分配与预算

- 默认 allocator 是 `std.heap.c_allocator`，宿主可显式覆盖；选择依据及额外实验
  见 [allocator 待办](runtime-allocator-todo.md)。不宣称它在所有平台更快。
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
