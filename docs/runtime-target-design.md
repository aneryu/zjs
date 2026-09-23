# JSRuntime 目标设计与详细实施计划

日期：2026-09-23（计划始于 2026-09-22）。初始审查基线：14baded4；实施状态核对：945b8a6b 加当前工作区变更，src/runtime.zig（由 src/runtime.zig 搬迁）。
状态：**45 个任务已交付**；后续对抗性审查修复与最终验证见 §13。修复后全量 1936 个引擎测试 + 59 个 CLI 测试通过；batch-gate-profile（含 ReleaseFast test262）通过。A9 后 allocator 复测完成，默认 c_allocator 已落地；详情集中于 §12。

本文是唯一活动设计入口，保留详细任务、最终所有权及验收边界。
原逐项讨论和六批审计已由本文收敛；需要追溯旧讨论时查 Git 历史。旧阶段验证不是当前源码的最终验证。
测量依据见 [allocator TODO](runtime-allocator-todo.md) 与 [nursery TODO](runtime-nursery-todo.md)。

执行索引：§1–6 为最终设计与迁移矩阵，§7 保留 45 张任务卡及依赖，§8 为类型绑定契约，
§9 为交付边界，§10 为 QuickJS 对照，§11 为实施前风险审查，§12 为交付快照验收，§13 为后续对抗性审查及最终验证。

## 1. 目标与边界

JSRuntime 是一个独立引擎实例：拥有内存与共享资源，允许多个 Context 共用执行与 GC，
向宿主提供控制入口，并保证执行、收集、任务和销毁之间的正确顺序。

最合理的收敛不是最少字段，而是：**每份状态只有一个负责人，Runtime 只实现实例级协调。**
Runtime 拥有全部引擎资源，不要求它亲自实现每个容器、分配算法和弱引用遍历。
不再有 MemoryAccount，不引入 Platform/后台线程池，不建立另一份完整 Runtime 配置镜像。

设计服务当前 zjs：保留现有 GC 存储、VM 热布局、FIFO 和对象表示。
功能上沿用已确认的宿主控制与微任务方向，不将其他引擎全部接口列为本轮前置条件。

## 2. 目标组成

以下是所有权示意，不是可编译补丁，也不是要求立即移动字段的物理布局。
默认内嵌成员；已有稳定地址记录继续独立分配。hot、VM 栈和活动入口的热布局单独保持。

```zig
pub const JSRuntime = struct {
    allocator: std.mem.Allocator,
    owner_thread: ThreadId,

    execution: ExecutionState, // 栈、活动调用、栈预算、回溯；保留现有热布局
    gc: GC,                    // 存储、收集驱动、阈值、弱身份和 GC 统计
    atoms: AtomTable,
    shapes: ShapeRegistry,
    types: TypeRegistry,

    contexts: ContextRegistry, // 借用的构造/发布成员索引，不负责保活
    roots: RootSet,            // 宿主句柄和 root provider，栈根仍按作用域存在
    jobs: Microtasks,          // FIFO、checkpoint 状态、WeakRef kept-alive
    exception: ExceptionState,
    bindings: NativeBindings,
    cleanup: DeferredCleanup,
    strings: StringCache,
    properties: PropertyState,// AutoInit 描述池、对象附属表；追踪规则各自保留

    host: HostState,           // 宿主回调、阻塞许可、终止/中断控制、时间原点
    hooks: *const EngineHooks,// 创建时一次接线的内部实现接口，不向宿主开放
    wake: CompletionSignal,   // 现有跨线程 Atomics 完成通知
    diagnostics: Diagnostics,// 可选采样/追踪；不能挤占 GC 热布局
};
```

这些类型只命名已有的责任，不要求引入通用注册、反射、插件或层层委托。
例如 ExecutionState 是逻辑归属：hot 和 vm_stack 可以继续直接位于 Runtime 的对齐位置，
其余冷执行字段再成组管理。不能为了与示意代码一致牺牲布局。

| 负责人 | 它决定什么 | 它不决定什么 |
| --- | --- | --- |
| Runtime | 创建/销毁、所属线程、跨 Context 执行边界、根汇总和清理时机 | GC 算法、属性查找、模块路径与 I/O |
| GC | JS heap 分配、收集进度、预算/阈值和弱处理 | 宿主超时、事件循环、Context 的 global 安装 |
| Execution | 调用栈、重入恢复、执行预算、回溯 | 每个 Context 的全局变量或模块实例 |
| Context | Realm 的 globals、原型、模块实例及 bootstrap 事务 | Runtime allocator、GC 阈值或共享类型定义 |
| Microtasks | 单队列 FIFO、checkpoint 状态与任务保活 | 定时器、网络等待、宿主事件调度 |
| Roots | 句柄登记与移除、声明的 root provider | 将所有 Runtime 侧表无条件变成强根 |
| Bindings / Types | 原生函数记录、类型定义、Runtime 局部绑定 | 全局宿主类型身份映射或自动热重载框架 |
| HostState / EngineHooks | 分别保存宿主策略入口、内部固定实现入口 | 混用宿主可替换回调和引擎必须具备的实现 |

PropertyState 内的描述池和对象附属表仍是两种不同存储，不合并保活语义。
borrowed_reference_holders 等对象借用引用登记也归这里的对象生命周期操作；
weak_reference_holder 链归 GC。两者都需要 Runtime 存储生命周期，但不是同一张表。

## 3. 创建配置与公开操作

创建只用 `create(options) -> *JSRuntime`，销毁只用 `destroy()`。
只读操作使用指针接收者，Runtime 不作为可复制的值使用。内部构造助手不构成第二套公开入口。

创建配置保持下面这些明确概念，不直接公开内部 gc.Policy：

| 配置 | 目标语义 |
| --- | --- |
| allocator（可选） | 覆盖引擎默认 allocator，默认 c_allocator，选择依据见 allocator 测量记录 |
| memory_limit（可选） | JS heap 预算；不是进程 RSS 或所有宿主内存 |
| stack_size、native_stack_size | 分开限制 VM 帧与机器栈；不再把不相关深度限制当成永久公共模型 |
| gc_threshold（默认值可覆盖） | 初次触发提示，后续由 GC 调整；Context 不保存/恢复 |
| microtask_policy | 沿用 auto / explicit / scoped，默认 outermost auto |
| interrupt_handler / interrupt_context、can_block | 创建时配置中断回调与阻塞许可；其他通知通过所属控制入口安装 |
| trace_writer（可选）、setOpcodeProfile | 明确启用的追踪与 profiler；不是脚本输出通道 |

内存压力控制能力保留，可通过明确的宿主控制接口表达；内部 large_object_threshold、
external_weight、每次清理任务数等不自动成为稳定公开选项。具体兼容迁移不在示意字段中掩盖。

Runtime 公开操作只覆盖这些职责族：

- 生命周期与执行控制：create/destroy、栈/堆限额、中断与终止/恢复。
- 宿主资源：注册类型、创建持久/弱句柄、handle scope、报告外部内存及释放计账 token。
- 任务：runMicrotasks 与策略配置；有 handler 时普通异常通知后继续；无 handler 时返回异常并保留队列，终止/OOM 单独处理。
- GC 与观测：一个显式 forceGC 入口、廉价统计、明确选择的详细诊断。
- 宿主接入：动态 import、Promise/拒绝/GC 等已确认的通知入口按需实现。

`Context.create(rt, .{})`、eval、call、global 安装仍由 Context/执行层承担，不给 Runtime 再复制一套。
内部对象登记、弱身份、缓存查找、GC 切片、底层 alloc/free 不逐个导出为 Runtime 宿主方法。
跨 Zig 文件所需的 pub 不等于承诺为宿主 API，但 root 模块的公开导出必须同步收敛。

D3 已实现：无 handler 返回异常并保留后续队列；handler 成功后继续，handler 失败返回宿主并保留队列；checkpoint 重入返回 MicrotaskReentry。
已确认但尚未实现的通知能力不预先分配队列或后台设施，也不宣称本轮已经具备。

## 4. 四条必要流程

### 创建

选 allocator → 分配 Runtime 本体 → 在最终地址初始化子系统 → 一次安装 EngineHooks → 返回可用实例。
每步负责回滚已完成资源，不对半初始化对象调用完整 destroy。
Options 消费后不整份复制保存；状态交给实际负责人。

宿主只见一个引擎入口。内部静态接线由能够连接 core/exec 的组装代码提供，
不再靠“先创建过其他 Runtime”留下的进程可变默认配置。
当前 root.Runtime 直接别名 core.JSRuntime；B1 已接通并验证命名模块注入，B3 已删除进程可变默认配置，
目标明确为一个公开 Runtime 类型、一套固定内部接口，不增加宿主 Hook 参数或第二个公开工厂。

### 执行与收集

执行入口确认 Runtime/线程 → 建立根、栈与重入状态 → 执行 → 恢复入口状态 → 最外层按策略 checkpoint。
GC 在允许收集的边界运行；普通 allocator 不暗中回调 Runtime 触发 GC。
GC 管理的分配在有根保护的慢路径回收/重试；最终失败交给宿主。
跨线程仅允许专门设计的终止/中断请求、内存压力通知和完成 signal，不扩大为任意 Runtime 操作可并发。

### 任务

保留 FIFO，任务保留其 Realm。嵌套 checkpoint 不重复进入；正常执行到队列空。
WeakRef kept-alive 由 checkpoint 清除，不能按任意 GC 周期清除。
延迟原生清理与 JS 微任务分开；Runtime 协调两者，不把原生 finalizer 当 JS 作业执行。

### 销毁

宿主停止外部访问、释放句柄/Realm 引用 → 确认执行空闲 → 退役执行器 → 撤销保活来源和待执行任务 →
GC 与原生清理按依赖完成 → 释放类型/atom/辅助存储 → 用保存的 allocator 释放 Runtime。
已有 Atomics 等外部生产者必须完成其注销/生命周期协议后才可释放信号，本方案不自动建设通用后台任务平台。
不得提前释放 finalizer 仍依赖的类型定义或 atom 表，不以简单初始化逆序替代当前销毁依赖。

## 5. 现状逐组对照

“保留”指能力和状态必要，不等于原样保留字段位置。“迁移”不意味着 Runtime 放弃资源所有权。

| 当前字段/入口 | 判定 | 目标归属 / 实际变化 |
| --- | --- | --- |
| 原 memory: MemoryAccount | A9 已删除 | Runtime 持有标准 allocator；GC 接管 heap 预算/路由，诊断独立 |
| 公开 init/deinit、owns_self_allocation | L3 已删除 | 最终地址 initInPlace；保存宿主 allocator 并直接释放本体，无账户复制 |
| owner_thread_id | 保留 | Runtime 线程权威；类型表不再另存一份 |
| hot、vm_stack、vm_stack_arena_policy | S8 保持原位 | `HotExecState` 仍是 64 字节 `extern` 且 `align(64)`。`vm_stack` 仍 `align(64)`。opcode profile 与 diagnostics 不在 hot 里 |
| active_invocation、host_invocation/retire、active_native_call | S8 保持三份 | 活动字节码入口、驻留执行器、活动原生环境各自保存和恢复。销毁时先 `retireHostInvocation`，再释放 `vm_stack` |
| small_inline_* | S8 已收拢记账 | `execution.zig` 安装 destroy/trace hook，并累加 published/specialized 字节。字段留在 Runtime |
| gc、malloc_gc_threshold、gc_running | 收拢 | GC 状态与驱动归 GC；不把 running 与 phase 机械合并 |
| pollGC、resetGCThreshold、finishDoomedCompletion | G1 已归 `gc_driver.zig` | Runtime 仍做线程检查、payload finalizer 跳过和 cleanup 排空。`gc_running` 与 `phase` 没有合并 |
| atoms、shapes | 保留 | Runtime 共享子系统，保留各自存储算法 |
| classes、newClassId | 收拢注册 | 类型表局部动态编号；一个注册入口返回绑定，固定内置编号保持 |
| context_*、constructing_context_* | S9 已归 `context_registry.zig` | 构造名单和发布名单分开。链接不是保活，扩容时用 `RealmRef`。字段留在 Runtime |
| installStandardGlobals 的 Context 搜索/adoption | 移出 Runtime | 目标 Context 明确绑定 global 并负责失败回滚 |
| installer/materializer/internal_builtins/容量 | B1 已安装 EngineHooks | B2/B3 已删除进程全局 installer/default 和重复 ensure；CLI 的同名私有 configureRuntime 仅配置当前实例 |
| root_providers、local/persistent/weak_root_slots | S1 已封装 | `JSRuntime.roots`（`RootSet`）。句柄协议、测试计数和 GC 访问保留。弱槽不进强根 trace。栈上 ValueRootFrame 仍在 Runtime |
| active_value_roots、活动 job 根 | 保留 | 栈上作用域与 Runtime 汇总入口，不能转成无条件永久根 |
| job_queue、weakref_kept_alive | J1 已收拢操作 | `jobs.zig` 的 `Queue` 仍是 FIFO。`keepAliveWeakRef` / `clearKeptAlive` 在同模块。列表字段留在 Runtime。J2–J5 统一策略与 checkpoint 异常恢复 |
| weak_object_ids/weak_id_objects/next_weak_id | S2 操作已归 `gc_weak.zig` | 字段仍在 `JSRuntime`。auto layout 加 `vm_stack align(64)`，收成结构会重排冷区。两表写入失败成对回滚，死亡 `take` 成对摘除，id 不复用 |
| weak_reference_holder_head/tail | S2 操作已归 `gc_weak.zig` | 字段仍在 `JSRuntime`。登记/摘链在 `gc_weak.zig`。收集器经 `holderHead` 走链。borrowed holder 与 `weakref_kept_alive` 未并入 |
| borrowed_reference_holders、borrowed_weak_cleanup_* | S7 操作已归 `property_state.zig` | 与 GC weak holder 链分开。字段留在 Runtime。标志查询在 `Object.isBorrowedReferenceHolder` |
| deferred_native_*、deferred_class_payload_*、reserved/active 状态 | S3 操作已归 `deferred_cleanup.zig` | 两种队列仍分开。payload callback 只在收集器空闲时运行。字段留在 Runtime，避免重排 `vm_stack` |
| current_exception 及两个标志 | S4 已统一更新 | `exception.install` / `take` / `clear` 同时清 uncatchable 和 out-of-memory。单独标记终止或 OOM 的入口保留。字段留在 Runtime |
| formatting_error_stack、backtrace_frames/capacity | 保留 | Execution 的回溯状态，非可关闭的 profiler |
| 字符串缓存与 recent_atom_string_next | S6 已归 `string_cache.zig` | 槽仍是强根。四路游标是 `recent_atom_string_next: u8`，占原 `compact_state` 的 align-1 位置。容量和命中策略未改 |
| auto_init_descriptors | 保留并封装 | PropertyState 的稳定地址描述池，不改成全局池 |
| cached_iterator_next_entries | 保留并封装 | PropertyState 的对象附属表，由所属对象追踪，不是 Runtime 强根 |
| native_entries/native_entry_finalizers | 保留并封装 | NativeBindings，按 Runtime 生命周期释放 |
| native_entry_epoch | S5 已删除 | 全树只有写入。退休仍把 entry 标成 retired，不释放记录 |
| slots2_payload_attach_count | F1 已删除 | 无读取计数删除，payload spill 行为保留 |
| compact_state | L3 已删所有权位 | `recent_atom_string_next` 仍在，归 S6 |
| dynamic_import_loader 与作用域恢复 | 保留 | HostState；exec 负责所绑定状态的 root/lifetime |
| interrupt_handler/context、can_block | 保留 | HostState，callback/userdata 配对、遵守线程契约 |
| host_completion_event | L1 已在构造时写 `.unset` | 字段仍是 Runtime 唤醒原语，不归微任务队列 |
| performance_time_origin_ms | 保留 | Runtime 共享的宿主功能状态，不属于 profiler |
| opcode_profile、gc_mark_footprint、trace_writer | 归诊断 | 保留已用诊断能力与热布局隔离，按需采样 |
| memoryUsage/gcStats | 保留并改内部契约 | Runtime 汇总廉价快照，详细遍历显式调用；不保留虚假统一总账 |
| RSS/cgroup 采样与压力策略 | 移除 | 不属于实例 Runtime；宿主自行监控进程 |
| reportExternalAlloc | 保留 | 宿主外部内存计账与压力通知，token 不替宿主释放缓冲区 |
| reportExternal*Untracked | 移出 Runtime | 内部对象存储直接调用 GC 分类记账 |
| forceMajorGC/forceGC | 合并同义入口 | 一个 forceGC；其他旧收集入口要迁移扫描/错误语义，不能机械别名 |
| create/takeValueHandle/createPersistentValue | S1 已合并 | 三者都调用 `JSValueHandle.init`。弱句柄和局部 scope 保留 |
| borrowedReferenceHolderRegistered | 移出 Runtime | 无 Runtime 依赖的 Object 查询 |
| collectionEpoch、ownsObject | 保留内部语义 | 根有效期和实例归属查询，不复制 GC 权威状态 |
| *ForTest/test_root_scan_override | 迁移测试支持 | 跟随责任模块，保留验证覆盖，不进入宿主 API |

## 6. 为什么保留这些现有机制

- slab/nursery/block heap：它们是 GC 存储实现，Runtime 重构本身没有理由推翻它们；普通原生分配的额外 slab 按既定方向移除默认依赖。
- 字符串缓存：现有不可变字符串共享有真实消费者，先保留策略；不能用结构简洁代替性能证据。
- 三种活动/驻留执行状态：生命周期不同，合并反而需要标志和分支来恢复这些区别。
- 构造/发布 Context 索引：用于区分可见性，删除区别会把状态过滤扩散到调用方。
- 原生/类 payload 清理：释放和重入约束不同，封装但不合并成一种泛型作业。
- Object 附属表：不是 Runtime 全局保活，搬迁必须保持对象死亡即撤销边的关系。

## 7. 可执行详细计划

### 7.1 使用规则与交付范围

每个任务有唯一 ID、前置任务、文件范围、具体动作、完成条件和定向验证。
完整路径均相对仓库根；除 `runtime.zig`（位于 `src/`）外，memory.zig、gc.zig 等未写目录的 core 文件均在 src/core，
其他省略目录的文件由条目中的子系统限定。标注“拟新增”的文件尚不存在，实施时可复用相邻模块，但不能遗漏责任。
任务是可 review 的最小工作单元，不强制每项一个提交；同一任务若无法保持可编译，必须连同直接消费者迁移。
P1/P2 静态核对完成。L1、L2、B1、L3、A1、A2、A4、O1、O2、A5、A6、A7、A8、S1–S9、G1、J1 已按完成记录落地。A3 只记录了口径，没有改分配器。G2/G3、B2/B3、T1–T4、E1/J0、J2–J4 已完成本组验证，下一项是 A9。通过编译本身不算任务完成，验证范围以各任务完成记录为准。

**本轮结构交付**：生命周期、MemoryAccount 拆除、状态归属、内置接线、类型绑定、现有宿主 API 迁移。
**独立行为交付**：新栈预算、checkpoint 策略、终止与通知能力，单列 E1/J 组；不得混进纯结构迁移。
结构交付以 F3 为终点，不等待 E1/J 组；新增行为交付以 J5 为终点。任一交付都不等于 §7.11 全部后续能力完成。
Promise hooks、延续数据、异步宿主模块等其他已确认能力列在 §7.11，不在此次结构批次隐式实现。

所有迁移均遵守：先建立新负责人并迁移调用，再删除旧路径；允许短暂编译适配，但不能双写两份权威状态。
每个中间可合入版本都必须保持尚未明确改变的诊断、限额、GC 安全点和清理能力。
临时适配在所属任务组收尾移除，不能把 MemoryAccount 改名为另一个通用账户后保留下来。
每个任务改公开名称时，当项迁移 root 导出、调用者、示例和相关文档，不能拖到 F1 才修复破损入口；F1 只总核对。
不改 nursery/block/slab 内部算法，不重写 FIFO，不给每个逻辑分组新增堆对象。

### 7.2 已核对事实与剩余 TODO

核对证据、源码位置和已执行命令集中在 §12，不能再把已查明的源码事实写成“后续需调查”。
D 编号保留用于任务依赖；“核对完成”不等于对应实施完成。

| ID | 当前核对结论 | 明确 TODO 与交付物 | 阻塞范围 |
| --- | --- | --- | --- |
| D1 | A9 前后 c/smp 比较完成，本机长期/并发负载 c 销毁后 RSS 较低，耗时无普遍优胜结论 | [x] 24 个复测样本与源码/二进制身份已归档；F1 默认 c_allocator，可显式覆盖 | 已关闭 |
| D2 | 命名模块注入已接入真实引擎：每个 engine 模块 `addImport("engine_hooks")`，provider 以同一模块为 `zjs`。`JSRuntime.hooks` 在 `initInPlace` 安装，core 不 import exec | [x] B1 已关闭。见 §7.7 B1 完成记录 | 不再阻塞 B2/B3、L3 |
| D3 | 已按用户采用的明确失败契约实现，宿主包装不再吞错 | [x] J2–J5：无 handler 保留异常和队列；handler 成功继续、失败返回；拒绝重入；OOM/终止独立处理 | 已关闭 |
| D4 | 公式已记录在 A3，不是未决项。heap 字节是 block 细胞尺寸类减前缀，加上已发布 extent/standalone 的 `heapByteSizeFromHeader`。nursery 不进 `allocated_bytes`。外部 token、untracked 和 RSS 是压力，不是 heap 字节 | [x] O1 已分开普通快照和详细普查；[x] A5 已按该表实现生产预算 | 不再阻挡 |
| D5 | Debug/test 的 trace 与 allocation diagnostics 由 Runtime.diagnostics 持有；生产 nativeAllocator 直接返回宿主 allocator | [x] A9 移除账户借用指针，alloc/free/remap 仍向同一 sink 各记一次；writer 失败不影响分配 | 已关闭 |

D2 接线和 D4 预算均已落地。D4 的生产权威是 Registry.heap_budget；诊断计数不可替代它。
ReleaseFast 原生计数不可用时由 allocation_tracking_enabled=false 显式标明，相关字段返回零；heap_bytes 始终可用。
若未来要在 ReleaseFast 开启全量 trace，应另立功能变更。

### 7.3 依赖与建议批次

| 批次 | 任务 | 退出条件 |
| --- | --- | --- |
| C0 基础核对 | P1–P2、B1 | 已完成：调用迁移表、验证入口和真实引擎接线都已落地 |
| C1 生命周期 | L1–L3 | 已完成：Runtime 只有 create/destroy，构造失败走 rollbackConstruction |
| C2 分配职责 | A1–A9、O1–O2 | 先完成依赖，再执行 A9；普通分配与 GC 分配分开，旧账本可删除 |
| C3 状态归位 | S1–S9 | 每组状态、操作、trace、销毁一起迁移 |
| C4 GC/引擎接线/类型 | G1–G3、B2–B3、T1–T4 | 单一控制面，无全局 installer 和全局动态类型编号依赖 |
| C5 独立行为批次 | E1、J0–J5 | 栈预算、checkpoint 和错误/终止契约逐项通过，不改宿主事件循环职责 |
| C6 结构收口 | F1–F3 | 结构 API、文档、CLI、销毁与批门完成；可先于 C5 完成，不依赖其新增行为 |

批次是建议集成边界，不是不可调整的大提交；以下各条“前置”才是精确依赖。
默认先 C0→C1→C2→C3→C4→C6 交付结构，再单独 C5；编号保留以便追溯。每批过大时可按已完成依赖拆批。
同一批中 A9 必须等 O1/O2 完成；不会先删除 MemoryAccount 再补统计与 trace。
初次推进顺序：P1 → B1 → P2 → L1 → L2 → L3 → A1 → A2 → A3。
最终迁移：A1/A2 分离 scratch 与产物；A4–A9 分开 GC 存储、heap 预算和可选诊断并删除账户；S1–S9 归位各责任模块；G/B/T/O 完成控制与绑定；E/J 完成栈预算和微任务；F 收口 API、teardown、文档及验证。
B1 应在 P1 后、L3 对公开入口定形前完成，避免先迁移全部调用再发现组装方案不可行。

### 7.4 基线与生命周期

#### P1 — 建立调用和分配迁移表

- [x] **静态核对完成**：调用族与最终删除项见 §12；P1/P2 本身为静态核对，运行时验证由后续任务承担。

- 前置：无。文件：runtime.zig、memory.zig、root.zig、core/root.zig、src/parser*、src/exec*、tests/harness。
- 动作：用 `rg` 清点 Runtime 原地 init、create/destroy、按值接收者、公开别名、MemoryAccount 参数及直接字段访问；区分普通分配、GC cell/backing、临时编译、外部计账。
- 完成：在本任务末尾记录实际触及文件/调用族；每个旧入口有目标任务，不以搜索命中数代替生命周期判断。
- 验证：只读核对 HEAD/工作区，识别用户已有变更；不在这一步启动全量性能或 test262。

#### P2 — 固定回归入口与变更契约

- [x] **静态核对完成**：调用族与最终删除项见 §12；P1/P2 本身为静态核对，运行时验证由后续任务承担。

- 前置：P1。文件：tests/core.zig、tests/oom.zig、tests/public_api.zig、tests/embedding_examples.zig、tests/exec.zig。
- 动作：找到生命周期、OOM、根、Realm、原生 payload、任务的已有测试；记录旧 API 中本计划明确改变的契约以及不变的语义。
- 完成：每项变更都有真实测试入口；缺少覆盖只在相应实施任务补测试，不复制一套全面镜像测试。
- 验证：需要修复已有缺陷的任务先跑其失败用例；不存在失败的纯迁移不得虚称“已复现 bug”。

#### L1 — 修正完整默认初始化

- [x] **已落地**：create 先初始化 diagnostics（包括 mark footprint），initInPlace 显式写 host_completion_event = .unset；预填内存测试覆盖默认值，不依赖 struct 默认初始化。

- 前置：P2。文件：src/runtime.zig、tests/core.zig。
- 动作：明确 host_completion_event、gc_mark_footprint 等全部字段的初始值；在最终地址初始化带自引用成员，不覆盖已经构造的 allocator/GC 状态。
- 完成：不会读到未初始化事件或诊断状态。L1 当时不改公开入口；该入口随后由 L3 收成 create/destroy。
- 验证：R04 的两项失败已复现并修复。正式测试覆盖预填充本体、到期等待和显式 reset。原诊断探针及输出已不在当前检出中，回归以正式测试为准。

#### L2 — 建立可回滚的稳定地址构造

- [x] **已落地**：稳定地址按 GC storage → atoms → classes → shapes 安装 errdefer；半初始化只调用 rollbackConstruction，类表自身失败只清理一次；完整 destroy 另走依赖顺序。

- 前置：L1。文件：runtime.zig、gc.zig、class.zig、atom.zig、shape.zig、tests/oom.zig。
- 动作：分配本体后在最终地址依次构造，逐步建立 errdefer；覆盖 serveObjectCells、类型表等可失败阶段；失败只销毁已成功资源。
- 完成：完整销毁与半初始化回滚分开；带内部指针的 Runtime 不搬移；暂时使用旧 MemoryAccount 的适配不成为最终抽象。
- 验证：按构造分配点注入失败，证明无泄漏、重复释放及遗留 GC observer；成功路径验证关键自引用指向最终实例。

#### L3 — 迁移为堆生命周期

- [x] **已落地**：唯一 Runtime.create(options) 在堆上创建，destroy 保存宿主 allocator 并直接释放本体；无公开 init/deinit、owns_self_allocation 或账户副本。tryDestroy 在外线程返回 WrongRuntimeThread；Context 保留原地生命周期。

- 前置：L2、B1。文件：runtime.zig、root.zig、tests/harness/test_engine.zig、CLI、所有原地初始化调用者。
- 动作：迁移栈上 Runtime、测试夹具和清理路径到创建指针/销毁；删除公开 init/deinit 与 owns_self_allocation 分支。此时可保留内部初始化助手及显式 allocator 参数，F1 再统一 options。
- 完成：无宿主原地初始化路径；析构明确保存 allocator/过渡分配来源；wrong-thread 检查和 idle 断言继续有效。
- 验证：嵌入实例独立、构造失败、反复创建销毁、错误线程拒绝及已有销毁测试；API 快照只随明确接口变更更新。

### 7.5 解除 MemoryAccount 依赖

#### A1 — parser scratch 显式传入

- [x] **已落地**。`ParseState.scratch` 在 `init` 记下显式传入的 allocator，`compile` 再改成该次 compile 的 arena。parser 临时列表、lexer 和语法错误回退扫描都用这个 allocator，不再读 `rt.memory.allocator`。当时两处切换还在，已由 A2 删除。
  文件：`src/parser.zig`、`src/parser/parse_state.zig` 及 parser 下临时列表消费者。
  验证：与 A2 一起，`zig build test` 1903+59 通过。

- 前置：L3。文件：src/parser.zig、src/parser/parse_state.zig、其临时列表消费者。
- 动作：编译操作拥有 ArenaAllocator；ParseState 的临时列表及其 deinit 显式取得 scratch allocator。此步保留现有两处成对 allocator 切换，先迁移全部 scratch 消费者，不提前删除一半协议。
- 完成：临时分配和释放不再依赖环境中的 rt.memory.allocator；仍保留的兼容切换明确由 A2 一起删除。
- 验证：脚本/模块解析、语法失败与 OOM unwind；嵌套编译或回调分配不误入外层 parser arena。

#### A2 — 编译产物与 arena 生命周期分开

- [x] **已落地**。`compile` 与 `compileQjsProgram` 不再改 `rt.memory.allocator`。`CompileContext.artifactAllocator` 显式取得 Runtime 的产物分配器；FunctionDef、模块记录和已发布 bytecode 通过接收 Runtime 的分配助手创建。arena 只服务 scratch，`compile` 返回前 `arena.deinit`。
  验证：`zig build test` 1903 引擎 + 59 CLI 通过。定向包含嵌入 eval、bigint 字面量、direct eval 和 dynamic import OOM。
  边界：未单独断言嵌套 compile 的两份 arena 地址；每次 compile 的局部 arena 独立，Runtime allocator 全程不替换。

- 前置：A1。文件：src/parser.zig、src/bytecode.zig、src/bytecode/function_def.zig、finalize/pipeline 调用者。
- 动作：CompileContext 的 artifactAllocator 与 scratch 明确分工，确认 artifact 调用和 A1 scratch 消费者全部迁好后，在同一变更删除 compile/finalize 两处及各自 defer 的 allocator 切换；核对 BigInt、atom、模块与 FunctionBytecode 的存储来源。
- 完成：Runtime allocator 在整次解析/编译期间不再变化；编译返回后释放 arena 不影响 bytecode/模块及其引用，失败时各来源匹配释放。
- 验证：现有 parser/编译产物 churn 测试、模块与函数执行、BigInt 常量、定向 OOM；不能仅检查 allocator 字段未变。

#### A3 — 固定分配与 heap 预算口径

本表保留迁移前的审计证据；最终所有者和入口见 A9，heap 字节公式不变。

- [x] **口径已按现有源码落定**，没有改分配器行为。A5 按此实现生产预算，不能改用对象数乘固定尺寸，也不能把 nursery 或 RSS 加进 heap 用量。

| 族 | 所有者 / 分配器 | 计账单位 | 可收集 | 释放 |
| --- | --- | --- | --- | --- |
| 普通原生 | MemoryAccount 仍计账、追踪并执行测试限额；字节来自宿主 backing allocator，不进通用 slab | 请求字节。GC slab 的 `accountedMallocSize`（class 尺寸，非 Darwin 再加 8）只用于 GC 细胞 | 否 | 与 alloc 成对的 free/destroy，同一 backing allocator |
| parser scratch | compile 拥有的 ArenaAllocator，块来自 `persistent_allocator` | 只计 arena 块本身；块内列表不再单笔计入 | 否，随 `arena.deinit` | 列表 deinit 用 `ParseState.scratch`，然后 arena 整块释放 |
| 编译产物 | FunctionDef / module / FunctionBytecode 走账户方法；`artifactAllocator` = `persistent_allocator` | 与普通原生相同 | bytecode 细胞可收集；Zig 侧表不可 | 账户 free，或 GC 回收已发布细胞 |
| GC block cell | block heap；`creditAlloc(accountedBodyBytesForRequest)` | 尺寸类减去 8 字节 metadata 前缀。请求大于等于 large 阈值的不走这条 | 是 | `recordHeapFreeWithBytes` 与 block free 成对 |
| nursery 细胞 | nursery page，page 来自 smp/page allocator | 细胞不进 `allocated_bytes`；`nursery.allocated_bytes` 只驱动 minor | 是，复制收集 | 整页归还，不按细胞 debit 账户 |
| 详细尺寸 | `heapByteSizeFromHeader` | object/bytecode/shape/string/bigint 用各自 `accountedAllocationSize`；storage/payload 的 block 用尺寸类减前缀，extent 用 `extentUserBytes - prefix` | 诊断，不是每次限额 | 与发布时同一字节数 debit |
| 外部 token | `gc_registry_heap.Tokens` | `external_bytes` 与 `external_weight * bytes` 的 debt | 否 | `release` 撤销计账，不 free 宿主缓冲 |
| inline untracked | object/object_payloads 报告 | `external_untracked_bytes`，不加入 heap 用量 | 否 | 与报告成对撤销 |

A3 调查时，旧 `MemoryAccount.allocated_bytes` 同时含普通原生和已入账的 block 细胞，不含 nursery 细胞、外部 token 和 RSS。生产 heap 预算采用 block 细胞的 `accountedBodyBytesForRequest` 加已发布 extent/standalone 的 `heapByteSizeFromHeader`；外部 debt 保留现有权重，作为独立 GC 压力，不加入 heap 字节。不得把 `allocated_bytes`、nursery、untracked 或 RSS 再加一遍。未发布分配在 publish 前仍算 reserved，失败 rollback 立刻 debit，不把“活对象”当成已经归还。

A3 核对时生产计数器仍是 `allocated_bytes`；A5 已按上表替换为 `Registry.heap_budget.bytes`。A9 已删除账户，混合计数只存在于可选 AllocationDiagnostics，生产预算不依赖它。

- 前置：A2。文件：memory.zig、gc.zig、gc_block_heap.zig、gc_nursery.zig、gc_space.zig、gc_carrier.zig。
- 动作：列出每种 cell/backing/普通原生缓冲的所有者、分配器、计账单位、可否收集、释放路径；同时列出旧 allocated_bytes/allocation_count 等所有读取方（限额、触发、debt、cycle baseline、诊断、销毁断言和测试），形成 D4 口径表。列出绕过宿主 allocator 的路径及原因。
- 完成：heap 使用量、reserved/committed、外部报告各自定义明确，不重复计字节，不用 malloc_total 伪装 JS heap。
- 验证：逐条对照分配和释放；不预先声称宿主 allocator 覆盖全部引擎内存，也不暗改 OS 页分配能力。

#### A4 — GC 专用存储归 GC

- [x] **已落地**：Registry.cell_storage 拥有 slab/observer 与 carrier audit 状态，并引用同一 Registry 的 block heap 和 nursery；gc_slab.zig 实现尺寸类算法。memory.zig 提供显式接收 Runtime 的分配函数，无独立账户。普通原生容器不进入 GC slab。

- 前置：A3。文件：memory.zig、gc*.zig、object/shape/string/bytecode 的 carrier 入口。
- 动作：把 GC 使用的 slab/arena、carrier/FAM 路由及必要 observer 迁到 GC 存储负责人；普通 Runtime 本体和原生容器不再借用 GC 路由。
- 完成：现有 size class、nursery、block/extent、对齐与释放匹配保持；过渡适配只转发一份存储，不同时创建两个 allocator 权威。
- 验证：现有 storage-cell/block/extent/nursery 路由断言及失败释放测试，检查 trace metadata/地址稳定性；不凭“整套测试通过”推断稀有路由已覆盖。

#### A5 — heap 限额与增长阈值归 GC

- [x] **已落地**。`Registry.heap_budget` 是 JS heap 字节、heap 限额和增长阈值的唯一存放处。非 nursery 的发布在 `observeNewPublication` 加上调用方已经算好的字节（block 为 `accountedBodyBytesForRequest`，extent/standalone 为 `heapByteSizeFromHeader` 那条），`recordHeapFreeWithBytes` 按同一字节数减掉。nursery 不加。外部 token、untracked 和 RSS 不进这个计数。`setMemoryLimit` / `memoryLimit` 读写这份限额；`setGCThreshold` / `gcThreshold`、`pollGC` 的越阈判断、`resetGCThreshold` 和 cycle baseline 都读这份 `bytes` 与 `gc_threshold`。原混合计数现为 `diagnostics.allocations`，只给 Debug/test 诊断和失败注入使用，生产原生路径不维护它。测试里原来用账户限额制造分配失败的调用改成 `setNativeBytesLimitForTest`；GC 分配路径在 heap 限额之外仍会看这个测试限额，所以原有 OOM 断言保持。
  验证：`heap budget caps published cells without capping native alloc or external bytes`（少 1 字节拒绝、恰好等于限额成功、回收后字节回到基线、原生 remap 的失败不改 heap 字节、外部 token 不改 heap 字节、另一个 Runtime 不受限额影响）、heap budget 单元测试、以及原先依赖账户限额的 OOM 回归。阶段验证已通过；最终验证见 §12。
  最终验证见 §12。G1 已把增长阈值驱动归到 gc_driver，Runtime 保留入口协调。

- 前置：A4、O1；D4 已收敛。文件：gc.zig、gc_registry_scheduler.zig、runtime.zig、CLI 内存限制入口。
- 动作：用明确的 heap 预算替代 MemoryAccount 全量原生限制；保留外部压力计账而不双计；在成功分配/释放、resize、失败回滚维护相同口径；同步迁移仍位于 Runtime 的触发/阈值/debt/baseline 消费者，G1 后续只搬驱动而不才修正口径。
- 完成：heap_limit 和动态 GC 阈值各自有单一权威；没有对象数量乘固定尺寸的替代账本。
- 验证：边界内/恰好边界/超限、resize 失败、对象回收后的预算释放、多个 Runtime 隔离；普通原生 OOM 单独注入，不再拿 heap_limit 充当所有分配失败开关。

#### A6 — GC 重试显式化，删除账户回调桥

- [x] **已落地**。`MemoryAccount` 上的 `trigger_gc_fn/ctx` 与 `limit_gc_fn/ctx` 已删除。heap 限额的一次重试是 `Budget.admit`：超限时调用 `retry`（生产为 `JSRuntime.retryHeapLimitOnce`），`retrying` 挡住嵌套 admit，`suppress_retry` 跳过它，收回来仍放不下就 `error.OutOfMemory`。`retryHeapLimitOnce` 在 `gc_running` 或 `phase != .none` 时直接返回，否则做一次 `.engine_active` major，所以调用方还握在 Zig 局部里的对象不会被精确扫描清掉。`limit_retries` 计这一次尝试。
  旧回调的去向：
  - `limit_gc_fn`：对象构造在第一块未发表单元格出现之前调用 `prepareConstructionCharges`（对象本体 + 属性缓冲 + tracer payload 的合计）。随后的 `NoTrigger` 对象分配和 `createStorageCell` 只做 `checkOnly`，不再收集。属性缓冲增长、payload 挂接和 payload 切片在自己的 mint 之前调用 `prepareHeapCharge`，此时所有者已经发表。字符串单元格仍在 `createStringCell` / `createStringExtent` 的 admit 里重试，因为那次检查发生在单元格存在之前，而且这两个函数不是 NoTrigger。字符串缓冲在 `createStringBuffer` 里先 `prepareHeapCharge`，再走不收集的 `createStorageCell`。
  - `trigger_gc_fn` 的生产阈值请求仍是 `collectBeforeObjectAllocation` 和字符串边界，pending request 仍由 `requestGCForAllocationTotal`、`pollGC` 和 `clearStaleAllocationThresholdRequest` 触发与消费。test/force 构建才把 `owner_notify` 设为 `triggerGCOnAllocation`，并且只挂在主动 opt-in 的分配上。生产 std allocator 不调用它。
  - 测试探针从账户回调改到 `heap_budget.probe`。自定义探针替换默通知，并吞掉这一次调用上的阈值请求。`suspend_alloc_notify` 关掉通知：根槽分配、属性还原，以及 force-GC。
  原生 `checkAllocation` 不再收集。`setNativeBytesLimitForTest` 是立即 OOM 注入器。`setMemoryLimit` 仍是 heap 预算，超限时最多收集一次。
  验证：`heap budget admits exact fit, rejects one byte over, and retries once`（嵌套 admit 在 `retrying` 时失败）、`heap limit collects once and then admits another object`、`heap limit retry keeps a local object the precise root set cannot name`、`heap limit of zero collects once and still rejects`、`native byte cap does not retry the heap limit`、`heap limit retry does not nest while a collection is running`，以及原先的 heap 限额与分配探针回归。阶段验证已通过；最终验证见 §12。
  最终验证见 §12。finalizer 自己再分配时的退出就是 `retrying` 与 `gc_running`；没有另写一个会在 finalizer 里分配的运行时用例。

- 前置：A5。文件：runtime.zig、memory.zig、GC-managed allocation 慢路径、对象构造调用者。
- 动作：迁移 trigger_gc_fn/ctx、limit_gc_fn/ctx 到显式受保护的 GC 分配重试；核对未发布对象/临时值的根；普通 std allocator 不触发 GC。逐一记录旧回调产生的 GC 请求由哪个对象/执行安全点接替，保留 pending request 的触发和消费；不能只删除回调使 GC 长期不运行。
- 完成：失败重试有确定退出条件，重入守卫仍在；不存在 NoTrigger 名称下隐式收集。
- 验证：能回收后成功、回收后仍 OOM、GC 自身 OOM、finalizer 重入和未发布对象存活；断言走到目标慢路径。

#### A7 — core 普通分配改用标准 allocator

- [x] **已落地**：生产 nativeAllocator 直接返回宿主 allocator。GC 类型按前缀、FAM、block/nursery/extent 的匹配入口分配和释放。Debug/test 适配器只做追踪与失败注入，不参与生产 heap 限额或隐式 GC。

- 前置：A6、O2。文件：runtime.zig、atom/class/shape/property/native_object、VM arena 的普通 backing 分配。
- 动作：普通 alloc/free/create/destroy 使用 Runtime allocator；GC cell 必须继续走 A4；每个消费者同时切换分配、释放、resize、诊断和 failure injection 来源；迁移 allocRuntime 等包装消费者，不统一文本替换。对象布局有前缀的指针不能直接传 std allocator.free。
- 完成：每个释放与原分配源匹配；普通原生默认路径不再自动套通用 slab；GC slab 依赖仍完整。
- 验证：对应 core 分配失败、grow/shrink、外部 payload cleanup；默认选择性能不在此任务裁决。

#### A8 — 编译、执行、宿主工具的普通分配迁移

- [x] **已落地**：parser/compiler/bytecode/exec/宿主层普通缓冲使用标准 allocator；parser scratch 使用本次编译 arena。Stack 和 VM arena 扩容显式接收 Runtime；parser 的 reserved BigInt 从 atom 表 owner 取得 Runtime；前缀载体使用显式 FAM 函数。无 allocator context 反查，VM arena 及 Entry 尺寸守卫保留。

- 前置：A7。文件：src/parser*、compiler、bytecode、exec、event_loop.zig、js_context.zig、CLI、tests/harness。
- 动作：逐层替换 MemoryAccount 参数和泛型包装，并与 O2 约定的诊断来源同步切换；保持 scratch、artifact、外部宿主内存与 Runtime allocator 不混用。
- 完成：列出的编译、执行、宿主层不再用账户做普通分配。A8 阶段留下的三处过渡依赖已由 A9 清理：操作数栈显式保存 Runtime，Entry 保持 240 字节；FunctionBytecode 保留显式 FAM 配对助手；core 子系统直接使用其 Runtime owner。错误分类和宿主 payload 所有权不变。
- 验证：parser/exec/module/job 队列 OOM 回归及 embedding allocation failures；旧失败测试迁移注入方式，保留原行为断言。

#### A9 — 删除账户与过渡适配

- [x] **已落地并通过最终验证**：MemoryAccount 类型、账户字段/指针、复制销毁、persistent_allocator、双 vtable 和反查桥已删除。GC slab 归 cell_storage；类型/shape 表移除重复 Runtime 指针。生产 nativeAllocator 直接返回宿主 allocator；原混合计数仅保留为 Debug/test 诊断，allocation_tracking_enabled 标明可用性，heap_bytes 始终来自 heap_budget。GC 周期峰值在 heap_budget.charge 时维护，与增长阈值同域。58 项分配/生命周期/微任务定向通过；三处根探针改为显式执行分配边界，保留原断言。

- 前置：A8、O1、O2。文件：memory.zig、runtime.zig、core/root.zig、测试/工具所有残余调用者。
- 动作：移除 MemoryAccount、account facade、persistent_allocator 双入口、initWithAccount、账户复制销毁和已迁空的包装；保留 memory.zig 内仍有独立用途的非账户组件。
- 完成：A3 的旧账本全部读取方都有新来源或明确删除理由，源码搜索无运行中的 MemoryAccount/账户回调依赖；允许历史文档命中。不能留下等价改名账户或自定义总账 allocator。
- 验证：构造/销毁全失败点、heap 预算、编译 arena、诊断、GC route 定向回归；按批边界跑统一门禁。

### 7.6 状态归位，每项同时迁移 trace 与 teardown

#### S1 — 根与句柄封装

- [x] **已落地**。`src/core/roots.zig` 的 `RootSet` 持有 root providers、inline 存储、local/persistent/weak slots 及登记、摘除、trace。`JSRuntime.roots` 内嵌这份状态。`bindInline` 在 `initInPlace` 里把提供者切片指到 Runtime 最终地址上的 inline 数组。`traceRoots` 仍由 Runtime 汇总：先 trace 句柄槽，原顺序再 trace provider，弱槽不在其中。栈上 `ValueRootFrame` 留在 Runtime。`Local` 仍只是 epoch 检测，不是保活。`createPersistentValue`、`createValueHandle`、`takeValueHandle` 都进入 `JSValueHandle.init`。公开名字保留。弱身份登记操作已由 S2 归入 gc_weak。阶段验证已通过；最终验证见 §12。定向 13/13 通过。最终 test262 结果见 §12。

- 前置：L3、A8。文件：runtime.zig、core/local.zig、context.zig、gc_trace_stw.zig；新增 core/roots.zig。
- 动作：集中 root providers、inline 存储、local/persistent/weak slots 及操作；保留栈 ValueRootFrame 生命周期；统一强持久句柄创建，迁移 create/take 旧描述和调用。
- 完成：Runtime 只负责汇总根；inline slices 指向最终地址；弱槽不是强根；没有为搬迁新增长期保活。
- 验证：nested handle scope、allocation-failed registration、host-held values、weak handle 清除/通知和销毁前释放检查。

#### S2 — 弱身份及 holder 链归 GC

- [x] **已落地**。`src/core/gc_weak.zig` 拥有 holder 链登记/摘链，以及双向弱 id 表的登记、第二次插入失败时回滚第一张表、死亡 `take`。`next_weak_id` 只在两表都写入成功后递增，`take` 不回收 id，所以回收后的地址不会命中旧身份。`gc.zig` 再导出该模块。收集器经 `gc.gc_weak.holderHead` 走链。五个字段仍留在 `JSRuntime`：该结构是 auto layout，`vm_stack` 为 `align(64)`，把字段收成一个结构会重排冷区并挪动 `vm_stack`。borrowed holder 表和 `weakref_kept_alive` 未动。对象侧仍调用 Runtime 上的原方法名。阶段验证已通过；最终验证见 §12。定向 17/17 通过。最终 test262 结果见 §12。

- 前置：S1、A4。文件：runtime.zig、gc.zig、gc_trace_stw.zig、object.zig；新增 core/gc_weak.zig。
- 动作：迁移双向弱 ID 表、next ID、weak holder 链及登记/摘链；不合并 borrowed holder 表，不搬 checkpoint 的 kept-alive 时机。
- 完成：地址复用不误命中旧弱身份，死亡摘链与异常回滚成对。
- 验证：WeakMap 活/死 key、WeakRef symbol、FinalizationRegistry、回收后地址复用及跨 Runtime 隔离。

#### S3 — 延迟清理状态与操作封装

- [x] **已落地**。`src/core/deferred_cleanup.zig` 拥有两条队列的入队、预留、摘除和排空。原生 cleanup 与 class payload finalizer 仍是两份列表。`drainClassPayloadAtSafeBoundary` 在 `gc_running` 或 `phase != .none` 时不跑 payload callback。字段留在 `JSRuntime`：auto layout 下把它们收成结构会重排 `vm_stack`。Runtime 方法保留为调度入口。与 S4、J1 和 `native_entry_epoch` 删除一起阶段验证已通过；最终验证见 §12。最终 test262 结果见 §12。

- 前置：S1、A8。文件：runtime.zig、object_gc.zig、native payload finalizer、gc_trace_stw.zig；新增 core/deferred_cleanup.zig。
- 动作：迁移两种队列、reserved slots、active job、draining flags、运行计数与 payload roots；保留 Runtime 的安全边界调度。
- 完成：不把原生 cleanup 与 JS 作业混用；GC 执行中不误运行可重入 payload callback。
- 验证：预留槽失败、queued/active payload root、重入 finalizer、exactly-once cleanup、销毁期间新增清理工作。

#### S4 — 异常值与标志统一

- [x] **已落地**。`exception.install`、`take`、`clear` 一起写异常值和 uncatchable、out-of-memory 两个标志。普通 `throwValue` 走 `install`，所以新异常不会留下旧终止或 OOM 标志。`setUncatchable` 和 `markOutOfMemory` 仍是抛出之后的单独标记。Context 的 throw/take/clear 和 Runtime 构造/销毁都走这组函数。字段留在 `JSRuntime`。与 S3 同一轮 `zig build test` 1915 引擎 + 59 CLI 通过。最终 test262 结果见 §12。

- 前置：S1。文件：runtime.zig、core/exception.zig、context.zig、exec/exception_ops.zig、builtin_dispatch.zig。
- 动作：由 ExceptionState 集中 throw/take/clear 及 OOM/uncatchable 标志；迁移直接字段操作，不借此改是否可捕获。
- 完成：任一普通异常更新都不会保留旧终止/OOM 标志；异常值仍正确追踪。
- 验证：普通 catch、uncatchable interrupt、构造错误时 OOM、跨原生边界错误映射和清除后重用。

#### S5 — 原生函数绑定生命周期归位

- [x] **已落地**。`src/core/native_bindings.zig` 拥有 entry 分配、finalizer 登记、原地退休和 teardown。`native_entry_epoch` 已删除（全树只有写入）。退休仍把记录标成 `.retired`，不释放，地址保持稳定。静态 builtin 表不在 `native_entries` 里，teardown 不把它当 owned allocation 释放。列表字段留在 `JSRuntime`。与 S6 一起阶段验证已通过；最终验证见 §12。最终 test262 结果见 §12。

- 前置：S3。文件：runtime.zig、native_entry.zig、host_function 及 builtin dispatch；新增 core/native_bindings.zig。
- 动作：收拢 entries/finalizers、注册/退休/销毁；删除无读取的 native_entry_epoch，保留 retired marker 与稳定记录地址。
- 完成：finalizer 数据有单一所有者；没有悬空已嵌入 entry；静态 builtin 表不被当作 owned allocation 释放。
- 验证：退休后调用行为、注册失败不夺取宿主所有权、清理一次、Runtime teardown。

#### S6 — 字符串缓存归位

- [x] **已落地**。`src/core/string_cache.zig` 拥有单字节、空串、两 code-unit、atom、percent、小整数的查找、生成、trace 和清空。`traceRoots` 先走这一次缓存 trace，再 trace atom 表。槽仍是强根，命中仍返回借用指针。`compact_state` 已删除；四路游标是 `recent_atom_string_next: u8`，放在原来那个 align-1 槽，避免挪动 `vm_stack`。容量仍是 256 / 1 / 4 / 256 / 256。与 S5 一起阶段验证已通过；最终验证见 §12。最终 test262 结果见 §12。

- 前置：S1、A8。文件：runtime.zig、string/atom 消费者；新增 core/string_cache.zig。
- 动作：将所有缓存字段、recent 索引、查找/生成、trace、清空一起迁移；容量和命中策略原样保持。
- 完成：Runtime 通过一次子系统 trace 汇总；compact_state 剩余索引移除；不改变缓存强根关系。
- 验证：空串、单字节、整数、percent、两 code-unit、atom materialization 在 GC 前后语义和销毁正确。

#### S7 — 属性描述与对象附属状态归位

- [x] **已落地**。`src/core/property_state.zig` 拥有三块彼此独立的操作：AutoInit 描述池的 intern 和 teardown（地址稳定到 Runtime 销毁）、iterator next 侧表的登记/清空（边仍只从所属对象的 `traceChildEdges` 追踪）、borrowed holder 与 borrowed cleanup。它们没有并入 `gc_weak` 的 holder 链。`Object.isBorrowedReferenceHolder` 是标志查询；Runtime 上的同名包装仍在。字段留在 `JSRuntime`。阶段验证已通过；最终验证见 §12。最终 test262 结果见 §12。

- 前置：S1、A8。文件：property.zig、object.zig、runtime.zig、iterator_ops/collection_ops；新增 core/property_state.zig。
- 动作：收拢 AutoInit 描述池、iterator next 侧表、borrowed holder/cleanup 状态，分别保留生命周期；纯 Object 标志查询归 Object。
- 完成：AutoInit 稳定地址至 Runtime teardown；iterator 边只从所属对象追踪；borrowed 与 GC weak 链不合并。
- 验证：lazy materialization 失败/重入、next 已取得后改变属性、对象死亡侧表移除、Realm borrowed 引用清理。

#### S8 — 执行冷状态与回溯边界

- [x] **已落地**。`src/core/execution.zig` 拥有驻留执行器退休、持久回溯的增长/弹出/位置更新、活动回溯链的链接，以及 small-inline hook 安装和字节记账。`deinit` 先 `retireHostInvocation`，再 `vm_stack.deinit`。`active_invocation`、`host_invocation`、`active_native_call` 仍是三份指针，原生重入只恢复自己的那一份。`HotExecState` 保持 64 字节，不含这三份指针，也不含 opcode profile 或 diagnostics。`hot` 与 `vm_stack` 的 `align(64)` 未动。阶段验证已通过；最终验证见 §12。最终 test262 结果见 §12。本任务没有性能声明。

- 前置：S4、A8。文件：runtime.zig、context.zig、exec/call_site.zig、builtin_dispatch.zig、small_inline.zig、exception_ops.zig。
- 动作：整理 resident invocation、native env、small-inline hooks 和回溯的责任；可直接保留字段，不强制新建 ExecutionState 大结构；保留 hot/vm_stack 对齐。
- 完成：执行器 retire 在 VM 栈释放前；原生重入正确恢复三种不同状态；冷诊断不进入热状态。
- 验证：nested native fence、generator resume、interrupt unwind、Error.stack 重入；不声称本任务自动提速。

#### S9 — Context 成员管理集中

- [x] **已落地**。`src/core/context_registry.zig` 拥有构造名单和发布名单的链接、摘除、按 global 查找，以及跨 Context 的原型槽预留和清除。构造中的 realm 不进入发布名单；`publishLive` 仍先登记 root provider，成功后才从构造名单摘下并链入发布名单。扩容遍历用 `RealmRef.retain`，名单本身不保活。字段留在 `JSRuntime`。阶段验证已通过；最终验证见 §12。最终 test262 结果见 §12。

- 前置：S1。文件：runtime.zig、context.zig、class.zig。
- 动作：集中构造/发布索引、查找和跨 Context 原型操作；保留当前两种可见性与 RealmRef 保护。没有足够独立操作时可留在现有模块，不强制独立分配 Registry。
- 完成：构造失败不留下成员或 root provider；成员链不拥有 Context；注册扩容期间仍存活。
- 验证：构造中查询、发布失败、宿主释放后 Realm 仍被对象持有、多 Context 注册/销毁。

### 7.7 GC 控制、内置接线与类型注册

#### G1 — 收集驱动移出 Runtime

- [x] **已落地**。`src/core/gc_driver.zig` 拥有 `pollGC` 在 cleanup 排空之后的 minor/major 路由、`resetThreshold`、按 doomed 字节折算后再重置，以及 `finishDoomed`。`JSRuntime.pollGC` 仍先检查所属线程，在 payload finalizer 活动时直接返回，并先排空延迟 cleanup。`gc_running` 仍是 Runtime 上的旗标，没有并进 `phase`。回调边界和 idle 入口仍在 Runtime，收集之后按原预算跑 cleanup。最终全量与 GC stress 验证见 §12；原公开阈值实验未保留，宿主控制按 G2/G3 的最终契约执行。

- 前置：A6、S2、S3。文件：runtime.zig、gc.zig、gc_registry_scheduler.zig、gc_trace_stw.zig；新增 core/gc_driver.zig。
- 动作：迁移 poll 内部收集流程、阈值和销毁续作；Runtime 保留线程、根、安全点和 cleanup 协调；gc_running 与 phase 不合并。
- 完成：驱动状态只有 GC 一份，回调临时允许/禁止收集的协议保持。
- 验证：minor/major 路由、pending destruction OOM 恢复、callback/idle 边界，已有路由断言必须实际触发。

#### G2 — 阈值与显式收集接口收口

- [x] **已落地**：本组 `zig build check` 和最终 `zig build test` 通过。`gc_threshold` 明确为创建时初值，`gcThreshold()` 返回动态值；Context bootstrap 不再保存/恢复阈值。删除 `forceMajorGC`。吞错收集只留私有 `collectForTeardown` 和编译期受限 `collectForTest`；宿主 `forceGC` 传播错误，JS `gc()` 与 test262 宿主使用 `.engine_active` 并传播错误，保留活动根扫描。测试把初始值断言移到 Context 创建前，并新增 bootstrap 后动态阈值与 heap 字节关系断言。

- 前置：G1。文件：runtime.zig、js_context.zig、parser/expressions.zig、CLI、tests/core.zig。
- 动作：初始阈值与动态阈值分清，删除 Context bootstrap 保存/恢复；forceMajorGC 合并到 forceGC；旧 cycle removal 逐调用点核对 roots、scan、错误处理，保留必要内部 teardown 入口。
- 完成：普通宿主收集失败不被旧 catch return 0 吞掉；engine-active 路径不会因接口合并误用 declared-only 扫描。
- 验证：创建 Context 后阈值状态、显式 collection OOM、活跃/静止根扫描、teardown 精确回收。

#### G3 — 外部压力与系统采样边界

- [x] **已落地**：外部 token 与 inline untracked 账目由 GC 管理；进程 RSS/cgroup 采样不属于 Runtime。

- 前置：G1、O1。文件：runtime.zig、gc_registry_scheduler.zig、object.zig、object_payloads.zig；拟新增系统内存采样模块。
- 动作：Runtime 保留外部 token 报告，内部 Untracked 转发归 GC；系统采样由宿主经可选回调提供，保持策略禁用时不采样。
- 完成：token 释放不替宿主释放缓冲区。
- 验证：token 成对释放/重复释放现有契约、压力请求、禁用不读取、采样不可用及多 Runtime；不新增后台采样线程。

#### B1 — 验证并确定内部接线

- [x] **已落地**。采用方案：core 的 `EngineHooks` 只含 installer 与 global 属性容量；`src/engine_hooks.zig` `@import("zjs")` 取同一 engine 模块的 `exec.standard_globals`。`build/config.zig` 的 `attachEngineHooks` 接到 `build/artifacts.zig`（CLI、profile、具名 `zjs` 模块）和 `build/tests.zig`（unified、host engine、embedding、oom）。`initInPlace` 在函数体内 `@import("engine_hooks")`，避免文件顶层循环。core 不 import exec。宿主 `create` 没有新增 hook 参数。
  导入方向：engine module → `engine_hooks`；provider → 同一个 engine module（名字 `zjs`）。
  验证：`zig build check`；`zig build zjs zjs-profile check-embedding`；`./zig-out/bin/zjs -e '1+1'` 与 `zjs-profile -e '1+1'` 退出码 0；`zig build test-embedding` 14/14；unified 的 `production embedding can own JSRuntime and JSContext directly` 通过。
  B3 已删除进程全局 default_standard_globals_installer 和引擎配置补丁；D2 关闭。

- 前置：P1。文件：root.zig、core/root.zig、runtime.zig、js_context.zig、exec/root.zig、build/artifacts.zig、build/tests.zig、build/config.zig。
- 动作：采用 §12 已验证的命名模块注入候选，把 engine_hooks provider 接入同一 engine 模块的 core/exec 导出；统一实际 build/artifacts.zig 与 build/tests.zig 各模块创建入口，再接真实实现；在本条记录采用方案及导入方向，关闭 D2。
- 完成：core 不直接循环依赖 exec；宿主无额外 hook 参数/注册步骤；裸 core 测试有明确内部构造条件。
- 验证：公共 import、CLI、profile、unified 与 embedding 均已编译并执行真实 Context bootstrap。隔离探针只证明语言层面可行；真实集成以本条完成记录为准，不再当作待验证。

#### B2 — Context 承担 global 安装事务

- [x] **已落地**：本组 `zig build check` 和最终 `zig build test` 通过。`JSContext.installStandardGlobals(global)` 明确绑定 Realm，验证 global 所属 Runtime 和既有 Context，失败回滚本 Context；Runtime 不再扫描并选择第一个空 Context。host globals、裸 Realm 测试、Intrinsics 统一传 Context。新增两个空 Realm 的归属/拒绝误绑定与 OOM 后重试测试。

- 前置：B1、S9。文件：runtime.zig、context.zig、js_context.zig、exec/standard_globals.zig、exec/call.zig。
- 动作：调用明确传 Context，绑定 global/失败回滚由 Context/exec 负责；迁移宿主 globals 和测试裸 Realm；删除 Runtime 选择第一个空 Context 的逻辑。
- 完成：任何 global 的 Realm 可明确追溯；构造失败不会错误修改其他 Context。
- 验证：两个未绑定 Context、嵌套 bootstrap、失败重试、lazy namespaces、宿主扩展 globals。

#### B3 — 删除全局默认及重复补接

- [x] **已落地**：本组 `zig build check` 和最终 `zig build test` 通过。`engine_hooks` 一次提供 installer、两个 materializer、内置表和容量。删除进程默认 installer、standard_globals.configureRuntime/registerStandardGlobalsDefault、Context ensure 补接和测试补接。CLI 中同名配置函数负责 CLI 配置，保留。

- 前置：B2、S5。文件：runtime.zig、js_context.zig、standard_globals.zig、internal_builtins.zig。
- 动作：installer/materializer/表/容量创建时一致接线；删除全局 default、configureRuntime 的全局副作用和各入口 ensure 补接。
- 完成：新 Runtime 不依赖另一个 Runtime 先执行；安装每个 Context 不重写 Runtime 固定配置。
- 验证：进程首个实例、多个独立实例不同创建顺序、多个 Context、首次构造 OOM 后重试。

#### T1 — 原生绑定边界先补归属检查

- [x] **已落地**：本组 `zig build check` 和最终 `zig build test` 通过。NativeType 创建先核对 owner 与 prototype 所属 Runtime；unwrap 接收 Runtime 与绑定，在数值 ID 前核对 owner 和对象归属，再检查 payload。测试覆盖相同局部编号、外来 binding/object/prototype、非对象及 disposed payload。

- 前置：L3、S1。文件：native_object.zig、runtime.zig、绑定调用者、tests/core.zig。
- 动作：按 §8 在使用 class_id 前验证绑定 owner，创建检查 prototype，解包检查对象 Runtime 与 payload；复用现有 ownsObject，不加对象 owner 指针。
- 完成：此步仍可使用全局 ID，先建立局部 ID 所需保护；不将 containsHeader 当作裸悬空指针验证器。
- 验证：外来 binding/value/prototype、非对象、disposed payload、同 Runtime 不同 Context；记录 fallback 检查的成本限制。

#### T2 — 单一注册事务与类型表线程权威

- [x] **已落地**：本组 `zig build check` 和最终 `zig build test` 通过。`Runtime.registerClass(definition)` 返回 `{owner, id}`；注册前递增本地候选编号，再扩 Context 原型与类型表，失败不回退编号。Table 线程判断委托 Runtime，初始化只留原地 `init(rt)`。修正分配重入后容量快照：若内层已扩容，释放外层候选缓冲，不覆盖内层表。新增 200 次嵌套注册与失败槽未发布测试。

- 前置：T1、S9。文件：class.zig、native_object.zig、runtime.zig、tests/harness。
- 动作：公开注册定义返回绑定，内部负责 ID、定义和 Context 原型容量；在任何可触发 GC/原生重入的分配前预留候选 ID，嵌套注册不能取同一个 ID；失败槽只取消未发布定义，不回退 next ID 跨过已发布或仍在进行的注册；类表线程检查委托 Runtime；单一原地 init 命名收敛。
- 完成：失败不发布半绑定，已成功 Context 扩容可保留容量但不能产生已注册假象；注册过程有单一线程权威。
- 验证：分配/扩容/intern 失败、GC callback 中嵌套注册（或按已定契约拒绝）、外层失败但内层成功、重复使用绑定、错误线程、定义 tracer/finalizer 一致性。

#### T3 — 固定定义生命周期，迁移注销用户

- [x] **已落地**：本组 `zig build check` 和最终 `zig build test` 通过。删除 unregister/tryUnregister 和 pending 注销状态，定义保持至 teardown。保留 construction/live-object/callback pins 与 generation 检查以验证释放配对；删除无人引用的注销探针，原 payload 回收测试仍执行，取消测试中的提前注销 defer。新增实例 finalizer 执行时定义仍可见的 teardown 测试。

- 前置：T2、S3。文件：class.zig、native_object.zig、旧 unregister 调用及测试。
- 动作：取消宿主动态注销能力，定义保持至 Runtime teardown；删除或替换其依赖前逐一核对 generation、pin、pending 状态的实际用途，不批量删除 finalizer 保护。
- 完成：公开无 unregister；不可变 metadata 不被覆写；活对象 GC 回收仍正常，binding_data 在最后一个依赖清理后释放。
- 验证：实例先回收/定义后销毁、reentrant payload finalizer、不可变注册约束；旧注销测试按新契约替代，不只是删测。

#### T4 — 切换为 Runtime 局部编号

- [x] **已落地**：本组 `zig build check` 和最终 `zig build test` 通过。删除进程锁、计数、ClassIdSlot 与 Runtime.newClassId；Table 使用 u32 递增游标，返回 u16 编号，65535 可用、下一次明确耗尽，不回绕。NativeType 注册不再接受裸预申请编号；两个 Runtime 同号绑定隔离已测。

- 前置：T3。文件：class.zig、runtime.zig、native_object.zig、root 导出、全部 newClassId/ClassIdSlot 调用。
- 动作：保留内置 ID；动态 ID 从本 Runtime 范围分配，不复用已发布 ID；删除公开预申请流程和全局锁/计数/slot 依赖。
- 完成：两个 Runtime 可各自拥有相同数字的不同类型；宿主使用绑定而非跨 Runtime 数字身份。
- 验证：局部编号碰撞拒绝误用、u16 耗尽不回绕、失败注册无半定义、跨 Context 使用同绑定；不通过扩宽对象编号掩盖耗尽。

### 7.8 统计与诊断，必须先于账户删除完成

#### O1 — 统计与公开资源口径迁移

- [x] **已落地**。`memoryUsage` 与 `gcStats` 只读已维护计数：heap_budget 字节、可选分配诊断字节和次数、动态 atom 名的真实字节、类注册数、外部 token、debt、收集计数、宿主弱根槽。这两条路径不遍历 GC 堆。`gcDetailedStats` 用 `heapByteSizeFromHeader` 做一次普查。heap 活字节与外部压力分开报告。object、shape、module 的数量乘固定尺寸已从 `MemoryUsage` 删除；`-d` 的类尺寸印成 `-`。`--gc-stats` 走详细普查，heap live 与 external 各一行。普通 `weak_ref_count` 只数宿主弱根槽；详细快照再计入对象上的 weak collection 与 FinalizationRegistry 单元。生产预算由 A5 放到 Registry.heap_budget，A9 后 memoryUsage.heap_bytes 直接读取它；原生计数用 allocation_tracking_enabled 明确可用性，不用全堆扫描伪装廉价统计。
  验证：`ordinary runtime stats do not walk the heap`（先 eval 出一个对象：普通查询不增加堆遍历，详细查询增加普查，`heap_live_bytes > 0`）、large payload 的普查字节对账、CLI 内存表与 GC 面板。阶段验证已通过；最终验证见 §12。
  最终验证见 §12。详细普查不是 A5 的生产预算。

- 前置：A3；D4 已收敛（调查在 A3 内进行）。文件：runtime.zig、gc_registry_diagnostics.zig、root.zig、CLI stats、tests/public_api.zig。
- 动作：依据 §12 最终核对中的快照/普查分离，建立旧字段→保留快照/详细诊断/删除误导字段的映射及对应统计入口；A5 完成预算迁移前只能从现有同口径来源读取，不能伪造尚未存在的新 heap 指标；去掉 object_count × 固定尺寸等不准确推算；D4 明确外部/heap/进程区别。
- 完成：普通查询不扫堆/读系统文件；缺失统计显式标记不可用（对应数字字段为零）；不重建每笔原生分配总账。
- 验证：统计口径已知的小负载、详细查询对账、调用普通查询不触发遍历/系统读取、CLI 标签与单位。

#### O2 — 分配追踪与可选 profiler 脱离账户

- [x] **已落地**。`src/core/alloc_trace.zig` 的 `Sink` 持有 writer、失败位和可选 profile 计数。`enabled` 仍是 `is_test or Debug`。格式仍是 `A <bytes> -> 0x<addr>.<bytes>` 与 `F 0x<addr>`。writer 失败只置 `failed` 并停掉后续行，分配本身继续。`JSRuntime.diagnostics` 拥有这份 sink 和 mark footprint；footprint 不放进 `Registry`，避免把 `barrier_gate` 挤出 `phase` 的前沿缓存行。A9 后分配助手直接使用 Runtime 的 sink，无账户借用指针。覆盖为：alloc/create 走 `recordAlloc`（一行 A，profile 加一）；free/destroy 走 `writeFree`（一行 F，profile 不加）；地址变化的 remap 走 `writeFree` 再 `writeAlloc`（各一行，profile 不加）。普通诊断 allocator 与 GC 分配助手各自只记录实际经过的路径，不双记。ReleaseFast 非 test 仍然不追踪。`--trace` / `-T` 没改名。
  验证：sink 的开/关、失败后不再追加、remap 不增加 profile；运行时 alloc/free 各一行且第二个无 writer 的运行时不写进前一个 writer；预填充 footprint 仍被 `diagnostics = .{}` 清掉。阶段验证已通过；最终验证见 §12。
  最终覆盖与批门见 §12；生产原生路径不安装诊断 vtable。

- 前置：A3；D5 已收敛。文件：memory.zig、runtime.zig、core/profile.zig、gc_registry_diagnostics.zig、src/cli/zjs.zig。
- 动作：先准备独立于旧账户的 trace/profiler sink、事件定义和覆盖表，旧路径暂委托该 sink；再由 A7/A8 按分配族切换。迁移 gc_mark_footprint 的负责人；保留 CLI 功能，writer 失败不破坏引擎执行。
- 完成：诊断实现不依赖 MemoryAccount，过渡调用适配可在 A9 前保留；A7/A8 前已经能记录新来源的事件，同一事件不能双记。默认关闭无诊断遍历；不通过通用总账恢复记账。
- 验证：开/关 trace、writer 失败、按已承诺分配族核对 alloc/free/realloc 与计数、诊断 reset/teardown；A7/A8 再验证实际接通，不能以 CLI 非空输出视为覆盖完成；涉及 profiling 批次使用 profile 批门。

### 7.9 执行预算与微任务：先迁移，再改变行为

#### E1 — 分离 VM 字节预算与原生栈预算

- [x] **已落地**：本组 `zig build check` 和最终 `zig build test` 通过。VM 帧的累计计划字节与 stack_size 比较，检查加法回绕；native_stack_limit 只比较实际原生栈地址，不再减 VM 字节。增加独立 native_stack_size option 与 getter，保留旧深度保护。native setter 在 idle 刷新栈基准，执行中保留入口基准。新增字节边界/回绕/原生栈独立性测试；原 native fence 回归继续执行。

- 前置：S8。文件：runtime.zig、exec/vm_opcodes.zig、inline_calls.zig、call_site.zig、parser 原生栈检查、公开配置。
- 动作：逐入口明确 JS 帧预算的字节口径，覆盖 bytecode/native/inline/generator 与重入；原生栈保留 top/limit；配置与 setter 分开表达两种限制，最外层在实际线程捕获基准。
- 完成：不把 native 栈地址当作 VM 字节上限；旧深度保护仅在等价覆盖得到证明后移除，用于 outermost/reentry 的深度计数保留。
- 验证：不同帧大小、深递归、native 重入、generator resume、异常/终止后的预算恢复及实际执行线程；Debug/生产帧差异不能通过无限放宽限制掩盖。

#### J0 — 跨线程终止的执行基础

- [x] **已落地**：本组 `zig build check` 和最终 `zig build test` 通过。Runtime 的原子 termination_requested 支持跨线程 terminateExecution；执行线程在 interrupt poll 观察，不跨线程写异常槽。cancelTerminateExecution 要求 owner 且 idle，以原子 exchange 为恢复边界，后续请求保留。RegExp timeout 始终接入以观察执行期间的新请求。新增工作线程发请求、执行退出、短执行拒绝、idle 恢复和 busy 拒绝测试。本项不实现 J4 的队列清空。

- 前置：S4、S8。文件：runtime 执行控制、context interrupt poll、exec 异常及执行入口、tests/core.zig。
- 动作：先定义 Runtime 生命周期内的原子请求、owner-thread 观察、终止状态和恢复协议；现有 interrupt callback 仍是执行线程回调，不能通过跨线程写其函数指针/异常字段来实现终止。
- 完成：请求者持有有效 Runtime 生命周期保证；销毁后不能再发请求，恢复有明确的 idle/owner 约束及并发请求处理规则；不打断宿主阻塞函数。
- 验证：真实跨线程请求被执行循环观察、请求/恢复交界、新调用不被已消费旧请求误终止、native 返回后观察；测试同步不能靠 sleep 猜测。此任务不改变队列清空行为。

#### J1 — 队列与任务保活封装

- [x] **已落地**。FIFO 仍是 `jobs.zig` 的 `Queue`，顺序未改。WeakRef [[KeptAlive]] 的 `keepAliveWeakRef` 和 `clearKeptAlive` 收到同一模块，仍在 job 结束时清空，分配失败仍丢弃保活。列表字段留在 Runtime。JS finalization job 仍在这条队列，原生 cleanup 在 S3 的另一条队列。与 S3 同一轮 `zig build test` 1915 引擎 + 59 CLI 通过。最终 test262 结果见 §12。

- 前置：S1、S3。文件：src/runtime.zig、src/core/jobs.zig、src/exec/zjs_vm.zig、src/exec/module.zig。
- 动作：收拢 queue 与 kept-alive 状态，不改 FIFO；明确每个 job Realm 和活动 job 的根，JS finalization job 与 native cleanup 分离。
- 完成：取出任务后到执行结束始终有根；所有原有失败路径保持已有所有权协议。
- 验证：job queue symbol roots、enqueue allocator failure、Realm 释放后任务仍可执行、FIFO/追加任务。

#### J2 — Runtime.runMicrotasks 宿主入口与异常报告

- [x] **已落地**：本组 `zig build check`、相关定向测试及最终 `zig build test` 通过。新增无 Writer 的 Runtime.runMicrotasks 与 setMicrotaskExceptionHandler，固定 EngineHooks.run_microtask 只执行一个引擎任务；普通异常按 D3 处理，精确 ValueRootFrame 保护通知参数，处理器重入返回 MicrotaskReentry，处理器失败恢复未消费异常并保留队尾。Context.runJobs、DynamicImportState.runJobs 与 EventLoop 不再吞返回错误；模块续作保留原有交错顺序，普通作业异常共用 jobs.reportException。timer/rw/signal/Atomics 完成调度归宿主 EventLoop/模块宿主调度边界；内部 drainOne 不再处理过期 waiter。test262 agent 使用 EventLoop.drain，模块宿主每轮先发布到期 waiter，防止 timer 重排拖延完成通知。OOM/Interrupted 先于 pending exception 分类，不改原有失败重试队列。定向异常、通知 GC 保活、宿主 timer 分离通过。

- 前置：J0、J1、S4、B3；D3 已决定。
- 文件：runtime.zig、exec/zjs_vm.zig、exec/module.zig、js_context.zig、event_loop.zig、CLI drain 调用者。
- 动作：建立无 Writer 参数的 Runtime 入口；将 promise_ops.drainPendingPromiseJobs 中的 OS signal/rw/timer/Atomics 完成调度明确移到 EventLoop，保留原宿主循环行为，再迁移 Context.runJobs/drain 调用；普通异常通知宿主后继续，OOM/终止等执行失败保留原分类。
- 完成：错误不被已有 exception/unhandled rejection 分支吞掉；console 输出仍经宿主绑定处理，Runtime.runMicrotasks 本身不执行宿主 timer/I/O/signal。
- 验证：异常→后续任务执行、通知期间异常根存活、通知重入规则、无 handler 的已定行为、OOM/终止返回；不削弱现有 dynamic import OOM FIFO 测试。

#### J3 — checkpoint 与三种调度策略

- [x] **已落地**：本组 `zig build check`、相关定向测试及最终 `zig build test` 通过。Checkpoint 集中 running/reporting/scope_depth；普通嵌套 checkpoint no-op，通知重入拒绝。RuntimeOptions.microtask_policy 支持 auto（默认）、explicit、scoped；eval 与 callOnceInto 在外层返回后按策略执行，期间精确保活返回值；enterMicrotaskScope().finish() 按 LIFO 结束且可返回执行错误。WeakRef kept-alive 在完整 checkpoint 结束清除，不在单个任务间清除。显式、嵌套 scope、新增任务、调用边界与跨任务 WeakRef 保活/完成后回收均已定向通过。

- 前置：J2、S8。文件：Runtime jobs 状态、exec 调用边界、公开 scope 支持、event_loop。
- 动作：实现 explicit；嵌套调用 no-op；排空包括新任务；在完整 checkpoint 清 WeakRef kept-alive；再接 outermost auto 和 scoped，不在每个嵌套返回时执行。
- 完成：事件循环只协调宿主事件，不拥有引擎 checkpoint 语义；未结束的 scoped 边界不提前执行。
- 验证：nested checkpoint、跨 Realm 排序、任务中新任务、nested eval、scope 嵌套退出、WeakRef 同 checkpoint 保活；无任务预算截断冒充完成。

#### J4 — 执行终止与恢复的队列边界

- [x] **已落地**：本组 `zig build check`、相关定向测试及最终 `zig build test` 通过。checkpoint 在任务前后、执行失败及异常处理器失败路径检查原子终止请求；丢弃剩余任务并释放其 Realm/value roots，但保留活 FinalizationRegistry 尚持有的预留槽。cancelTerminateExecution 同时拒绝活动 checkpoint。终止前入队、任务内请求、恢复后仅新任务执行已定向通过。

- 前置：J3、S8。文件：runtime 执行控制、exec interrupt/exception 路径、jobs。
- 动作：复用 J0 已验证的终止请求与执行线程观察；终止 checkpoint 丢弃剩余当前队列并释放 roots；恢复不复活旧任务、不回滚业务状态。
- 完成：普通 job 异常、JS 可捕获错误、无法继续的终止各自明确；不能声称终止能打断宿主阻塞函数。
- 验证：终止前/中/后的任务所有权、请求竞争、恢复后新任务、native 返回后的终止观察；线程测试证明实际观察到请求。

#### J5 — 新执行与微任务行为集成收口

- [x] **已落地并通过最终验证**：root/test_root 导出 policy/scope/handler；auto/explicit/scoped 通过真实 native OOM 与普通异常 continuation 的统一边界测试。Context.runJobs 只排引擎队列，EventLoop 协调宿主事件并传播错误。默认值、错误恢复及输出契约已更新。

- 前置：E1、J4、F3。文件：RuntimeOptions、root 导出、Context/exec 入口、event_loop、CLI、embedding 文档与测试。
- 动作：在已经收口的结构上接入双栈预算和 microtask policy，删除其旧行为兼容入口；对比既有任务调度，记录 intentional ordering changes；验证终止/异常/自动 checkpoint 的组合。
- 完成：新行为默认值与用户裁决一致，事件循环不重复 checkpoint；结构交付记录仍独立，§7.11 能力不冒充完成。
- 验证：auto/explicit/scoped × 普通异常/OOM/终止 × nested call 的关键交界、恢复后新任务、CLI/embedding；本独立批次按 §7.12 收尾，不复用结构批门冒充行为已测。

### 7.10 总收口

#### F1 — options、公开导出与调用者一致

- [x] **已落地并通过最终验证**：唯一 Runtime.create(options)，.allocator 可省略（默认 c_allocator）或显式覆盖。源码、测试、工具、README 和活动嵌入示例已迁移。无诊断构建将原生计数标为不可用并返回零；heap_bytes 保持可用，CLI 明确说明区别。删除账户后的 c/smp 复测已完成，选择依据与边界见 allocator 记录。

- 前置：A9、G2、G3、B3、T4、O1、O2；默认选择需 D1。
- 文件：runtime.zig、root.zig、core/root.zig、js_context.zig、CLI、tests/public_api.zig、embedding_examples、相关宿主文档。
- 动作：唯一 create(options)，allocator 可选；配置不是状态副本；区分 heap limit/initial threshold/诊断；统一只读指针接收者；删无消费者 slots2 计数和剩余同义入口。此步保留原有栈/任务行为，不提前公开尚未交付的 E1/J 组新配置；后者由 J5 收口。
- 完成：公开面与示例一致，无本体双入口和旧字段依赖；保留必要 checked-host 与 asserting-internal 的线程错误边界，不强行把所有方法改为同一错误集。
- 验证：public API/embedding examples、CLI 参数与 stats/trace、错误线程操作；API 快照变更说明每个删除/替代，不为过门机械重生成。

#### F2 — 最终销毁依赖与外部访问核对

- [x] **已落地并通过最终验证**：复核顺序：退休宿主执行器/VM 栈/回溯 → 清异常/根/队列 → GC 与 deferred cleanup 多轮收尾 → 二次释放可能再增长的作业存储 → GC 对象/元数据 → 类型/atom/本地容器 → slab → Runtime 本体。address registry 拆除前解绑 slab observer；保留 host handle/Realm 先释放断言。Atomics 外线程只发布完成信号，最终释放由 owner 执行。

- 前置：F1、S2–S9。
- 文件：runtime destroy、gc deinit、types/bindings/cleanup、Atomics waiter 与 event_loop 接入。
- 动作：按真实依赖复核 teardown：执行器→撤根/任务→GC/cleanup→类型/atom/存储→本体；检查外部 waiter 注册/注销与 signal 存活，不新增通用后台平台。此核对不是首次检查：L2/L3、A4/A9、每个 S 任务都要同步维护其销毁顺序；F2 是整体复核。
- 完成：各组件清空/销毁只消费有效依赖；不会删掉 GC 再入队后必要的二次释放；没有假设“反向 init 就足够”。
- 验证：已定的“宿主先释放句柄”前置条件及现有断言（不新增 live-handle 拒绝销毁返回接口）、残留 Realm、finalizer 新增工作、原生资源一次清理、Atomics 通知与关闭交界、allocator 无泄漏。

#### F3 — 清除过渡层并交付证据

- [x] **已落地并通过最终验证**：实现中的 MemoryAccount、persistent_allocator、accountedAllocator、allocator 反查、旧初始化及全局 installer 已清理；API 文档、示例、allocator 测量与任务清单统一更新。旧阶段记录已标明历史性，最终分配职责以 A9 为准。

- 前置：F2。
- 文件：本计划触及源码/测试/公开文档。
- 动作：清点旧名、临时转发、复制状态和错位注释；验证全部结构迁移项完成；E1/J 的行为验收与结构验收分别记录；§7.11 保留为独立后续范围；回填每项实际文件、测试命令、结果、剩余限制。
- 完成：没有改名后的 MemoryAccount、第二公开生命周期、隐式 parser allocator 切换、全局 installer；没有未说明的宿主行为改变。
- 验证：最终 `zig build test` 与所属 merge batch 的 mise 门禁按 §7.12 执行；默认 allocator 性能只引用有效测量，未测不声称提速。

### 7.11 不随结构重构自动扩展的工作

| 能力/实验 | 本计划如何处理 | 何时另开实施任务 |
| --- | --- | --- |
| nursery 策略、通用 slab 性能、额外平台 allocator 比较 | 保留两份 TODO；本机 c/smp 默认选型属于本轮 D1/F1 | 按现行验证政策另做策略 A/B 与跨平台比较 |
| Promise hooks、延续数据 | 保留已确认方向，HostState 不先分配无用存储 | 结构边界稳定后列具体生命周期和测试，不能称已完成 |
| GC 前后通知、独立 RequestInterrupt、跨线程压力通知 | 已有接口迁移不等于新能力完成 | 根据实际代码缺口设计有界任务；不拿普通 interrupt callback 代替 RequestInterrupt |
| 合成模块、异步模块宿主能力 | 现有 loader 迁移保持行为 | 单独列协议/失败/取消任务，不与 bootstrap 接线混合 |
| 销毁时禁止新 FinalizationRegistry 作业 | 仅保留 QuickJS 对照结论 | 必须单独验证弱清理语义，再改当前 teardown 算法 |
| 完整 Platform、线程池、热重载/注销类型 | 暂缓 | 新需求明确出现时再讨论 |

这些项目是显式后续范围，不是因为暂缓就从已确认需求中删除。交付报告须区分“结构完成”和“完整能力完成”。

### 7.12 验证与任务完成记录

唯一政策是 [verification-policy.md](verification-policy.md)，本节只把它映射到任务，不建立新门禁。
文档整理不跑引擎测试。源码任务迭代用 `zig build check`，定向测试用
`mise run test-fast -- '<实际测试名子串>'`；任务条目中的场景是验收要求，不是保证已经存在的过滤名。
新增有意义的不变量测试随所属任务落地，零匹配不能算通过。

源码变更收尾按政策跑一次 `zig build test`；同一连续实施变更中的小编辑不逐次跑全套。
昂贵的 test262 只在 merge batch 执行一次 `mise run batch-gate`；涉及 profiler/trace 的批次采用
`mise run batch-gate-profile`，不再叠加重复普通批门。每批实际包含哪些任务需在实施开始记录。
不恢复 rc-neutrality、强制性能预注册或每任务全量 test262。

代表性现有测试入口（执行前确认仍存在）：

- 生命周期/限制：`production embedding can own JSRuntime and JSContext directly`、`production embedding API applies limits and releases eval handles`。
- 根：`production embedding roots host-held values with public handles`、`gc stress deterministic tiny heap preserves live roots`。
- 分配失败：`production embedding public API allocation failures keep host ownership intact`、tests/oom.zig 的相关 canary。
- 任务：`job queue enqueue propagates allocator failure`、`dynamic import job OOM retains its FIFO position for retry`、`job queue keeps symbol arguments rooted until release`。
- 执行边界：`synchronous native fence restores every budget after interrupt`、`Error stack reentrant formatting is capped to captured frames`。

任务完成时在对应条目追加：状态、实际文件/符号、实际命令与结果、未覆盖风险。任务的新契约改变旧断言时，
先记录批准的行为变化及替代验证，不以删测/弱化断言制造通过。源码实施授权、提交/推送均不由本计划暗含。

## 8. 简单类型绑定方案

以下方案已由 T1–T4 实现。保留内置固定编号；动态编号仅在各 Runtime 内有效。
注册返回包含 owner 和 class_id 的绑定；宿主分别保存各 Runtime 的绑定，不建全局映射，不按名字去重。
暂不注销或复用已发布编号。绑定有效期到所属 Runtime 销毁，不能拿失效指针尝试验证其有效性。

实际接口：Runtime.registerClass(def) 返回实例绑定；native_object.registerType(rt, name, finalize) 返回 NativeType，
其 owner/class_id 绑定同一 Runtime。native_object.create/unwrap 负责宿主对象的创建与解包，不另建全局映射。

检查顺序：

1. 创建/解包先确认 `binding.owner == rt`，错误绑定在使用编号前拒绝。
2. 创建时，非空 prototype 也必须属于 rt；解包时先确认 value 是对象，再检查 `rt.ownsObject(object)`。
3. 解包最后比较 class_id 并检查 native payload 是否仍有效；不同 Runtime 的同号类型不能互相解包。

初版复用现有 ownsObject → gc.containsHeader，不给每个对象新增 owner 指针，也不重建全局身份表。
源码依据：core/native_object.zig 的 create 检查类型 owner 和 prototype，unwrap 检查类型 owner、对象归属、class_id 和 payload；
gc.zig 的 containsHeader 对 nursery/block 有所属存储查询，同时仍有 morgue/list/iterator 兜底。
因此它不是所有路径都 O(1)，且“属于 Runtime”不等于“仍可用”：该查询也接受尚未销毁的 condemned 节点。
宿主入口接收有效且受根保护的值/绑定；已失效裸指针不在此检查的保证内。
GC 清理内部访问不能因为加入宿主边界检查就改变 condemned 对象的清理协议。

这将原来“需要设计高效归属机制”收敛为“先复用现有正确性检查，按实际调用成本再优化”。
实施时的必要定向验证：两个 Runtime 相同局部编号、外来绑定、外来 prototype、同 Runtime 跨 Context、
已释放 native payload，以及注册失败回滚。不能通过省略归属检查来维持旧热路径成本。

## 9. 交付边界与验证状态

本轮 45 项覆盖 Runtime 结构、内存职责、类型绑定、宿主控制及微任务契约。A3 的交付是口径表，A5/A9 实现该口径；不把文档调查当成分配器实现。

MemoryAccount 已删除。生产普通分配直接使用宿主 allocator；GC 拥有 slab/carrier/observer 和 heap_budget；Debug/test 诊断独立。Runtime 使用唯一 create(options)/destroy。D3 已实现，OOM 与终止不作为普通微任务异常通知。

§7.11 明确列出的扩展能力，以及 allocator/nursery TODO 中的额外策略与跨平台测量，保持后续范围，不能冒充本次已交付。
最终命令、通过数量、已修复的验收失败和 allocator 证据统一见 §12。

R04 初始化缺陷已由 L1 修复；正式回归覆盖预填充内存、到期等待和显式 reset。

## 10. 与 QuickJS JSRuntime 对照

本轮直接读取本机参考树 `/home/aneryu/quickjs-zjs-ref`：工作树干净，commit
`04be246001599f5995fa2f2d8c91a0f198d3f34c`，VERSION 为 `2026-06-04`。
这是本次明确选定的源码快照，不声称是最新上游或已确认的所有 benchmark 默认版本。
对照初始基线为 14baded4；生命周期与内部接线两行已按本次工作区更新。这里没有 sizeof/性能测量，实施验证见 §7。

### 总体对应

QuickJS 的 Runtime 也同时拥有分配器、GC、atom、shape、类型、Context 列表、当前异常、
执行栈指针、任务及宿主回调。它并不是只放少量接口的空壳。
其 C 结构多为平铺字段，函数实现集中在 quickjs.c；zjs 的按职责封装是自身的组织选择，
不能称为“QuickJS 就是这样拆模块的”，也不能从结构体行数推断体积或速度。

| 职责 | QuickJS 当前快照 | zjs 当前实现 | 对目标方案的判断 |
| --- | --- | --- | --- |
| 生命周期 | JS_NewRuntime 默认分配器包装 JS_NewRuntime2；两者都返回堆对象，统一 JS_FreeRuntime | L3 已统一为 create/destroy 堆生命周期，Context 仍可原地初始化 | 保留分配器可选能力，已收敛一种 Runtime 堆生命周期；QuickJS 两个创建函数不等于 zjs 两种所有权模式 |
| 内存管理 | 内嵌 JSMallocContext，含宿主函数、统计/限制、小对象 arena/free lists | 宿主 allocator 服务原生分配；GC 专用存储与 heap budget；Debug/test 可选诊断 | QuickJS 也有账户与 arena 职责；移除 MemoryAccount 是 zjs 的取舍，不能据 QuickJS 证明这些能力全部无用 |
| GC | 引用计数配合 gc_decref/gc_scan/gc_free_cycles，Runtime 保存对象链和阶段 | tracing GC、显式根、nursery/block、调度与销毁续作 | zjs 多出的根、弱身份、保守扫描及调度状态有机制原因，不能抄 QuickJS 的字段集合删除 |
| atom/shape | Runtime 的 atom 哈希/数组和 shape 哈希 | AtomTable、Shape Registry | 同样应由 Runtime 共享拥有；zjs 已有合适子系统边界 |
| 类型 | 全局 JS_NewClassID，Runtime 本地 class_array；JS_NewClass 注册定义 | Runtime 局部动态 ID、不可注销类型表及 NativeType | 局部动态 ID 是主动偏离 QuickJS；简化注册需同时保留实例归属检查 |
| Context | 一张成员链；Context 内 class_proto、global/模块等 Realm 状态 | 构造/发布两组链，另有显式根协议 | 保留 Runtime 成员管理；两组链源于 zjs 发布过程，不能只为对齐数量合并 |
| 内置初始化 | JS_NewContextRaw/JS_NewContext 对明确 ctx 安装 intrinsic | 固定 EngineHooks + 明确 Context 安装事务；全局默认与猜测 Context 已删除 | Context 负责 bootstrap 更接近 QuickJS 的边界；B1 已解决 core/exec 静态接线，B2/B3 继续迁移 bootstrap 与删除全局配置 |
| 执行栈 | stack_size/top/limit、current_stack_frame，部分调用帧缓冲使用 native 栈 | VM arena、显式调用预算、驻留执行器和活动 native 环境 | 保留不同执行模型需要的状态；不直接缩减为一个 current_frame |
| 异常 | current_exception、uncatchable、in_out_of_memory 防 OOM 递归标志 | exception 值、uncatchable、out_of_memory 分类及回溯状态 | Runtime 级异常合理；两边 OOM 标志含义不同，不能按名字合并 |
| 任务 | Runtime job_list；JS_ExecutePendingJob 一次取一项，返回成功/异常状态 | FIFO，runMicrotasks 已实现完整 checkpoint 与 D3 | 保留队列，宿主处理普通异常后继续是 zjs 既定契约，不是 QuickJS 单步接口原样移植 |
| 模块与宿主控制 | normalize/loader/check_attrs、interrupt、promise rejection tracker、can_block | dynamic import 回调、interrupt、can_block 等，部分通知仍是目标能力 | 共用 Runtime 配置有对应依据；宿主路径/I/O 和计时策略不归 Runtime |
| 外部资源接入 | sab_funcs、user_opaque、strip_flags 等显式功能字段 | 没有全部一一对应的 Runtime 字段 | 不为字段对称增加功能；需分别检查实际 API/其他模块，不能据 Runtime 字段缺席断言整个引擎不支持 |
| 统计 | JS_ComputeMemoryUsage 显式遍历 Context/堆等结构 | `memoryUsage`/`gcStats` 只读已维护计数；`gcDetailedStats` 才普查堆 | O1 已落地。详细遍历保留给显式查询 |

主要证据（链接指向本机参考树）：[JSRuntime 结构](../../quickjs-zjs-ref/quickjs.c#L319)、
[JSMallocContext](../../quickjs-zjs-ref/quickjs.c#L303)、[创建](../../quickjs-zjs-ref/quickjs.c#L2067)、
[Context 初始化](../../quickjs-zjs-ref/quickjs.c#L2593)、[单项任务执行](../../quickjs-zjs-ref/quickjs.c#L2303)、
[GC](../../quickjs-zjs-ref/quickjs.c#L6815)、[详细统计](../../quickjs-zjs-ref/quickjs.c#L6928)。
外部参考树不随 zjs checkout 提供；commit 与 VERSION 用于定位复核。

### 对此前方案的修正与边界

1. **不以拆成许多类型为目标。** §2 的组成是职责示意。仅对能同时收拢状态、操作、trace 和销毁的
   责任引入内部类型；owner、唤醒信号、少量宿主配置可以直接保留字段。不能为每组标量新建模块和代理。
2. **MemoryAccount 已去除，但不宣称 QuickJS 没有对应物。** 本快照明确内嵌
   JSMallocContext；宿主 malloc 与引擎 arena 可并存。通用 slab 的 zjs 收益仍由测量决定。
3. **GC 阈值是动态运行状态。** QuickJS js_trigger_gc 在回收后更新阈值，JS_SetGCThreshold 设置它；
   支持 zjs 将初始提示与后续动态阈值区分，不由 Context 为维持“固定配置”而恢复旧值。
4. **不要复制引用计数销毁逻辑。** QuickJS_FreeRuntime 清空作业后用 JS_RunGCInternal(rt, FALSE)
   避免弱处理再产生 FinalizationRegistry 作业。zjs 当前会在销毁回收期间重新入队，因此二次队列释放
   有实际原因。可后续评估 teardown 模式阻止新 JS 清理任务，但本轮不删现有清理步骤或改 GC 语义。
5. **区分功能差异和冗余。** 显式根、VM arena、延迟 payload 清理是 zjs 机制差异。
   双本体生命周期已由 L3 去掉。无读取计数、同义入口和重复 installer 接线也已清理。

对照后的推荐不变：Runtime 保持实例资源总所有者，具体算法由子系统实现；
采用 QuickJS 清楚的 Runtime/Context 边界，保留 zjs 实际执行/GC 模型需要的状态。
不追求与 QuickJS 一样的字段数量，也不为本轮重构引入完整 V8 风格平台。


## 11. 实施前对抗性审查（2026-09-22）

下表保留原风险及对应解决任务；最终实施状态以任务卡与 §12 为准。

结论：此前“依赖图无环”不足以证明计划可执行。以下是计划缺陷，不是本轮已复现的源码 bug；
均已修订对应任务。源码未修改，未运行引擎测试。

| 严重程度 | 反例/风险 | 修订 |
| --- | --- | --- |
| 高 | A1 删除外层 allocator 切换但 A2 仍保留 finalize 切换，A1 的“不修改 Runtime”完成条件不成立 | A1 先迁移 scratch 分配/释放；A2 一次删除两处成对切换 |
| 高 | A7 先绕过账户、O2 后接诊断，中间版本 trace/profiler 静默漏事件 | O2 在 A3 后准备 sink，A7 依赖 O2；分配族同时迁移诊断，新增 D5 覆盖契约 |
| 高 | A9 只核对 allocator 消费者，却仍可能留下 threshold/debt/baseline 读取旧账本 | A3 枚举所有读方，A5 同步迁移 Runtime 控制口径，A9 按清单核销 |
| 高 | 宣称结构/行为分开，F1/F2 却依赖 E1/J4，使结构交付被新功能阻塞 | F1–F3 只收结构；新增 J5 独立行为收口，不减少原有功能目标 |
| 高 | J4 把跨线程终止基础与队列清空一起做，之前的 J2 已要求可靠终止分类 | 新增 J0 原子请求/观察/恢复基础，先于 J2；J4 只集成队列生命周期 |
| 中 | D2 既阻塞 B1，B1 又负责关闭 D2；并且接线太晚会迫使 L3 返工 | B1 无 D2 前置，P1 后先验证；L3 依赖 B1，B2/B3 才等待 D2 |
| 中 | 注册过程分配可触发 GC/回调，局部 ID 按“成功最后递增”会被嵌套注册抢用 | T2 在可重入点前预留，失败不回退越过其他注册；新增嵌套成功/外层失败测试 |
| 中 | F2 含糊的“句柄拒绝销毁”可能重新引入已否决宿主 API；销毁正确性又被推迟到结尾 | 明确宿主释放前置条件和断言，不新增拒绝接口；每次迁移同步验证 teardown，F2 仅总核对 |

审查当时未关闭的 D1–D5 已继续核对；当前事实与剩余 TODO 以 §7.2、§12 为准。
这些是计划明确的局部实施阻塞，不用文档检查代替技术验证。只有依赖已满足的任务可推进。


## 12. 最终核对与验收（2026-09-23）

- [x] 源码无 MemoryAccount、persistent_allocator、accountedAllocator、initWithAccount 或 allocator 反查；进程级 installer 配置已删除，CLI 私有 configureRuntime 只配置传入实例。
- [x] Runtime 无公开原地生命周期；create 仅收 options，全部自引用绑定最终地址。
- [x] GC slab/observer 与 carrier 只有一份 Registry 所有权，普通原生分配不走 GC 路由。
- [x] 编译 scratch 与持久产物分开；前缀/FAM 释放不交给普通 allocator.free。
- [x] D3 已定并实现；普通异常/OOM/终止与 handler 重入有独立规则。
- [x] 分组定向：58/58 分配及运行时，10/10 显式 GC 根边界，9/9 默认创建与 policy × OOM/普通异常；随后 dynamic import 17/17，Atomics.waitAsync test262 切片 101/101；TypedArrayConstructors 与 revoked Proxy 切片 739/739。
- [x] 最终 `zig build check`、`zig build test --summary all`：1933/1933 引擎、59/59 CLI。ReleaseFast 构建及 `zjs -d -e` Promise 示例输出 42；诊断不可用标记与 heap 字节正常。
- [x] 删除账户后的 c/smp 复测：3 场景 × 2 allocator × 4 次，共 24 个有效样本；校验结果与源码/二进制身份见 [最终测量](runtime-review/allocator-2026-09-22/README.md#after-a9--final-default-selection-2026-09-23-local)。
- [x] 最终 `mise run batch-gate-profile`：Debug checkpoint-gate 全通过（GC stress 1930 通过、3 个既有条件跳过；embedding 编译通过）；ReleaseFast test262 44583 通过、0 失败，5194 按既有 feature 配置跳过、3516 既有排除；生产 smoke 通过。没有修改 excludes、known-errors 或跳过策略。

验收期间发现并修复的实际问题（没有修改 excludes 或放宽断言）：

1. embedding 函数签名检查同步为唯一 options 参数；VmStackArena 通过显式传 Runtime 保持 1552 字节，未增加 owner 字段或放宽布局守卫。
2. 空参数调用的 GC stress 计数基线先明确保活并回收 bootstrap 垃圾，字节数与分配次数相等断言均保留。
3. ReleaseFast 的 finalize 不再要求 allocator.ptr 等于 Runtime；改为 atom owner 加 allocator ptr/vtable 校验，避免直接宿主 allocator 被误拒绝。Debug 的诊断 vtable 曾掩盖此问题；生产 CLI/test262 是必要验证。
4. test262 agent 改用 EventLoop.drain；模块宿主循环每轮先发布到期 Atomics waiter。单例从超时恢复通过，完整 waitAsync 切片 101/101。
5. DynamicImportState.runJobs 不再吞掉 pending exception 下的返回错误；与 checkpoint 共用普通异常报告，并保留 TLA 续作交错顺序。测试覆盖无 handler、handler 成功/失败、重入拒绝及剩余队列恢复。
6. 批门定位 TypedArray 原型回退误取被调用构造器 Realm 的旧分支；改从 newTarget 的 functionRealmContext 取 intrinsic，同时恢复撤销 Proxy 的 TypeError。对应 TypedArrayConstructors 与 revoked Proxy 切片 739/739。

§7.11 的新增能力与扩展实验属于独立范围，不将其计入本计划完成项。


## 13. 交付后对抗性审查（2026-09-23）

审查覆盖 Runtime 构造/失败回滚、GC storage 与 observer teardown、预算重试、微任务入口及模块宿主调度、提交边界。旧的 §12 是交付快照验证，不替代下列修复后的最终检查。

- [x] **模块调度绕过 checkpoint 状态**：反例中，首个作业内嵌套 runMicrotasks 使队尾在首个作业返回前执行（预期 phase=2，实际 1）。DynamicImportState.runJobs 现在检查 owner thread、reporting/running/scope_depth，并在整个排空期间保持 running；普通任务与 TLA 调度共用 runCheckpointStep，统一任务前后终止观察和错误报告，保留既有 TLA 交错。回归同时覆盖作用域延后、终止不执行队尾及恢复。
- [x] **handler 留下的 OOM 被误分类**：反例预期 OutOfMemory、实际 JSException。reportException 在处理器正常返回后重新检查终止和 OOM/uncatchable 标志，保留异常值给宿主。
- [x] **预算重试捕获旧限额**：回调下调限额后，admit 仍允许按旧上限分配。重试结束改用 checkOnly 读取当前限额；测试覆盖下调、上调和取消限额，保留最多重试一次的限制。
- [x] 修复前执行反例确认失败；修复后 check 与 28 项定向通过（runtime review、dynamic import、microtask checkpoint）。
- [x] 修复后 `zig build test --summary all`：1936/1936 引擎、59/59 CLI；`mise run batch-gate-profile` 退出 0，Debug checkpoint-gate 全通过（GC stress 1933 通过、3 个既有条件跳过；embedding 编译通过），ReleaseFast test262-check 通过，生产 smoke 缓存命中。未修改测试排除或跳过策略。
- [x] 本地提交分组：TypedArray Realm 修复独立提交 `d690a9b4`；本节随 Runtime 重构及审查修复提交。仅纳入对应源码、测试、API 文档及测量证据；原有无关文档变更保留，不推送。

allocator 的 24 个样本与身份文件保持原样，代表 §12 的 A9 交付快照；本轮审查没有重新测性能，不宣称修复带来速度变化。
