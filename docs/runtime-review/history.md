# JSRuntime 历史讨论与审计依据

归档日期：2026-09-22。此文件合并原逐项记录、清单和六批审计，保留原文供追溯。

**本文件冻结，不是活动 TODO 或当前审批状态。** 原文中的“当前”“待确认”“下一步”仅描述当时讨论；
以最新用户裁决及[唯一活动方案](../runtime-target-design.md)为准。后续结论只更新活动方案。


<a id="archive-runtime-design-review"></a>

---

原路径：`docs/runtime-design-review.md`

# JSRuntime 设计与实现 Review

更新日期：2026-09-22。

本文件记录 `src/core/runtime.zig` 的逐项讨论、用户裁决和待验证问题。
目标是改善 **现有 zjs 的正确性、复杂度与性能**，不是建设 V8 功能清单。
本轮只 review 和记录，未修改引擎源码；设计同意不等于授权实施或已经实现。

**活动方案：[JSRuntime 目标设计与现状对照](../runtime-target-design.md)。**
用户最新要求先设计完整目标、再对照现状，取代前六批从现有字段出发的推进方式。
后续围绕目标缺口收敛；本文件保留原始裁决和证据，不再增加逐批字段讨论。

## 工作方式与状态

- 每项讨论均落到本文件，包括问题、当前证据、方案、结论及尚缺的验证。
- 按用户最新要求，先维护完整清单，能根据代码和既有裁决判断的事项自行 review，
  只有真正需要用户取舍时再询问，不再逐项等待确认。优先从 zjs 当前实现出发。
- 当前汇总入口：[目标设计](../runtime-target-design.md)；[结构清单](history.md#archive-runtime-review-checklist)保留历史审计索引。
- 性能收益必须经测量验证；减少字段、分支或代码行数不自动等于提速。
- 不因参考引擎有某个 API 就自动列为新增功能任务。
- 用户最新裁决优先，旧讨论保留并标注被替代或暂缓。
- TODO 放在 `docs/`，不放容易丢失或被忽略的 `.scratch/`。
- 实现和验证遵循 [verification-policy.md](../verification-policy.md)。文档记录不要求运行引擎测试。

状态含义：

| 状态 | 含义 |
| --- | --- |
| 已确定 | 用户明确接受的方向，尚不代表实现完成 |
| 方向记录 | 已讨论，但没有明确裁决具体方案；不能把“继续”当作同意 |
| 待评估 | 需要当前代码审计、复现或测量才能决定 |
| 暂缓 | 曾讨论或同意，后被“暂时不用这么复杂”收敛，当前不实施 |
| 待确认 | 最新提出的具体改法，尚未获用户确认 |

## 当前焦点：初始化路径

### R01：Runtime 的责任范围

**已确定。** JSRuntime 是一个引擎实例的资源所有者与协调者。
GC、对象存储、类型元数据等内部算法由各子系统实现。
“由 Runtime 管理”不意味着把所有实现代码和算法放在 runtime.zig 中。

### R02：单一、稳定地址的生命周期

**已确定。** 目标是 Runtime 在堆上创建，使用单一 `create(options)` / `destroy()`
生命周期；不再同时公开原地 `init/deinit` 与自分配 `create/destroy` 两种所有权模式。
可选宿主 allocator 经 options 表达，具体 API 修改尚未实施。

当前 `init` 与 `create` 均进入 `initWithAccount`，通过
`owns_self_allocation` 区分 Runtime 本体由谁分配。
GC、allocator facade、atoms 和内联存储切片等保存内部地址，说明地址稳定是实际要求。
迁移时需要核对现有调用者和失败回收路径，不能只删除一个入口。

### R03：initWithAccount 与 MemoryAccount 的初始化耦合

**已确定设计方向：移除独立的 MemoryAccount 抽象；尚未实施。** 用户明确认为不需要
MemoryAccount，内存管理责任归 JSRuntime。本结论取代此前“是否保留待评估”的状态。

当前 `create` 先在栈上建立临时 MemoryAccount，
用它分配 Runtime，再按值复制进 `rt.memory`，最后绑定带自指针的 allocator facade。
`destroy` 又复制 `self.memory` 到局部变量，用于释放 Runtime 本体。

目标生命周期：

1. 用选定的底层 allocator 直接分配 Runtime 本体。
2. 在最终地址建立 Runtime 基础状态，再按依赖顺序初始化子系统及内部指针。
3. 创建失败时释放已成功建立的资源，最后释放 Runtime 本体。
4. 销毁时保存底层 allocator 值，释放 Runtime 拥有的资源，最后用该 allocator 释放本体。

由此取消临时账户转移、`initWithAccount` 及销毁时复制账户的需要。
Runtime 持有必要的内存管理状态，GC 和存储算法仍由子系统实现；
现有 MemoryAccount 的能力需逐项评估去留与归属，不把整个类型换名后原样搬入 Runtime。
本体的统计口径、分配接口迁移及失败回收细节留待后续具体 review。
这是所有权和生命周期的简化，尚无测量证明性能收益，见 M01。

### R04：逐字段初始化没有应用结构体默认值

**以下是 2026-09-21 的复现记录。L1 已修复；不要把「修复尚未实施」读成当前结论。**

**初始化缺陷及一个接口层后果已复现；记录当时修复尚未实施。**

此项保留为缺陷记录。用户指出复现与修复讨论偏离设计 review 主线，
当前不继续展开，主线回到 R03 / M01 的所有权简化。

证据（2026-09-21 当前工作树）：

- `JSRuntime.host_completion_event` 声明默认值 `std.Io.Event = .unset`。
- `initWithAccount` 没有整体赋值 Runtime，也没有初始化此字段。
- `tests/core.zig` 的 `gc stress deterministic tiny heap preserves live roots` 从
  `var rt: core.JSRuntime = undefined` 开始调用 `rt.init(...)`。
- Runtime 的宿主完成通知方法会对该字段调用 `set/reset/waitUncancelable/waitTimeout`。

结构体字段默认值不会自动写入一个 `undefined` 对象；因此这条初始化路径未建立该字段状态。
补充验证（2026-09-21，HEAD `14baded420b35168ba31dcee1017dd10d1dfea8e`，
Zig 0.16.0 / aarch64-linux / Debug，未改引擎源码）：

| 探针 | 结果 |
| --- | --- |
| 在原地 Runtime 存储中预置合法旧值 `.is_set`，调用 init 后要求 `.unset`。 | 失败：仍为 `.is_set`。 |
| 用 FixedBufferAllocator 为 create 提供带同样旧值的存储，断言 Runtime 确实使用该地址；无通知、截止时间已到时等待应超时。 | 失败：等待返回 true，误认为收到完成信号。 |
| 同样预置旧值并 init，再显式调用 resetHostCompletionSignal，执行相同等待。 | 通过：事件恢复 unset，无通知时超时。 |

共 3 项，1 通过、2 项缺陷断言失败、0 跳过，进程退出码 1。
这是预期失败的诊断，不是门禁通过。使用合法已知旧值避免靠读取任意 undefined 位模式推断结果。
探针及命令见 [R04 复现说明](probes/README.md)，
保留了 [原始输出](probes/init-event-baseline.txt)。

实际调用边界：`atomicsWakeWaiters` 可以直接调用 `signalHostCompletion`；
`waitForAtomicsHostSignalUntil` 则在持锁检查后先 reset 再 wait。
因此本次证明的是初始化缺陷与 Runtime 等待接口的错误结果，
不是一个已复现的端到端 Atomics.waitAsync 丢通知、崩溃或挂起。
尚无性能数据。`gc_mark_footprint` 等其他字段留待单独审计。

据复现收敛后的建议：

1. **最小修复**：在两条入口共用的 initWithAccount 中初始化 host_completion_event 为 `.unset`，
   将定向回归断言纳入正式测试。尚未实施，当前仅 review 与记录。
2. **结构改进候选**：结合 R02 先整体建立基础状态，再按依赖顺序初始化子系统及内部指针；
   这比字段修复范围更大，需要单独审计和裁决，不能捆绑为本缺陷的必要改动。
3. 结构改进时核对逐步失败回收；部分构造失败不能直接当作完整 Runtime 销毁。

风险：初始化会发布内部指针，不能在绑定这些指针之后再整体覆盖或移动 Runtime。
这属于生命周期与正确性修复，目前不声称性能收益，也不借此重写整个内存系统。

当前代码入口：[runtime.zig](../../src/core/runtime.zig)、
[memory.zig](../../src/core/memory.zig)、[tests/core.zig](../../tests/core.zig)。

### R05：普通原生分配是否需要 Runtime 的泛型包装接口

**已确定设计方向；未实施。** 用户确认普通原生分配不需要
`allocRuntime/createRuntime/freeRuntime/destroyRuntime` 这套同义包装。
移除 MemoryAccount 后，不将其泛型 `alloc/create/free/destroy` 接口整套搬入 JSRuntime。

当前具体例子：`enqueueDeferredStdFileClose` 使用
`rt.createRuntime(DeferredStdFileClose)` 分配文件关闭任务，
任务完成或入队失败后却使用 `rt.memory.destroy` 释放。
该结构体没有 `gc_kind_tag`，由明确的原生清理路径释放。
`createRuntime` 当前还带有编译期开关控制的 GC 请求逻辑，再转交
`MemoryAccount.createNoTrigger`；并非纯粹的 allocator 别名。

普通、显式释放的原生任务和容器使用 Runtime 所持有的稳定
`std.mem.Allocator`，直接调用其 create/destroy/alloc/free。
此处 allocator 代表引擎选定的默认或宿主提供的底层 allocator，
不沿用解析器可以临时替换的 `memory.allocator` 字段语义。
Runtime 仍负责这些资源的生命周期，不因此增加一套同义泛型 API。
GC 对象保留由 GC 子系统处理的专用分配路径；本项不决定其接口形式。

价值是减少重复入口并让分配/释放配对明确。迁移不能只机械替换调用：
需核对现有统计、限额、slab 路由及失败行为的变化；本项不声称性能提升，
不默认保留旧账户的全量记账包装。

### R06：编译期间是否应替换 Runtime 的 allocator

**已确定设计方向，具体迁移待 review；未实施。** 经原因审计，取消编译期间
对 Runtime allocator 的临时替换；该切换不是实现临时分配的必要条件。
Runtime 的普通原生 allocator 保持稳定；
编译临时 arena 由编译操作持有，通过解析/编译状态显式传给需要它的代码。
不把“当前操作用哪个 allocator”存成 Runtime 的可变共享状态。

当前证据：MemoryAccount 同时保存 `allocator`、`persistent_allocator` 和
`backing_allocator`。`parser.zig` 的 `compile` 用 persistent allocator 建立 arena，
保存并将 `rt.memory.allocator` 替换为 arena allocator，退出时恢复。
finalize 前又将同一字段临时切换到 `CompileContext.artifactAllocator()`；
后者在 `bytecode.zig` 中返回 persistent allocator。正常编译成功后释放 arena。

补充原因审计：

- `ParseState.initWithRuntime` 将 `&rt.memory` 传入 State，State 和 FunctionDef
  保存同一个账户指针；控制流跳转修补列表、标签帧及临时字符串等直接读取
  `s.memory.allocator`，lexer 则在入口取得该字段的 allocator 值。
  因而入口替换一个字段就能让这些既有调用使用 arena，无需逐处显式传递临时 allocator。
  这是当前结构的实际效果；“为减少传参改动而选择它”是结构推断，不当作作者自述。
- arena 服务于编译临时分配的集中管理和批量释放；此次未找到证明该切换方式
  本身必需或带来性能收益的测量。长期数据已有另外的分配路径，例如
  FunctionDef 的缓冲区调用 `memory.alloc`，变量索引显式调用 `accountedAllocator()`。
  因此临时替换并没有把所有编译分配统一收进 arena。
- 历史上 `321a6eca` 的 frontend 代码已存在入口 arena 切换；
  `519317b8` 将相关代码并入 parser.zig，不能把文件迁移误认为首次设计。
  `8d761e6c` 添加 finalize 前的稳定 allocator 切换，其注释明确解释为防止
  finalizer 辅助函数将 arena 分配保留进产物，并在 State 清理前恢复原分配路径。

结论：临时内存与长期产物的生命周期区分有实际用途，修改 Runtime 共享字段
是现有接口结构下的传递方式，并非实现这种区分的必要条件。先明确各调用的
分配归属，再取消字段切换；不能只删赋值语句而保留原有依赖。

这使读取同一个 Runtime 字段得到的分配生命周期依赖编译所处阶段。
现有保存/恢复与稳定分配路径确实提供了保护；此项不宣称已复现悬垂指针。
设计上的负担是所有辅助函数都要区分当前操作内存与长期保留内存，
否则新增代码可能把需保留的数据放入即将释放的 arena。

目标是保留临时 arena 的批量回收用途，让其作用域在编译状态中明确表达；
普通长期原生数据使用 Runtime 稳定 allocator，GC 管理的编译产物继续走相应专用路径。
迁移时需逐项核对临时数据、产物、诊断信息及失败清理的实际生命周期。
本项收敛 Runtime 字段责任，不决定 arena 性能优劣，也不引入新的 allocator 包装类型。

### R07：普通小对象是否还需要引擎自建 slab

**已确定设计方向；未实施。** 延续 R05，普通原生分配默认直接使用标准 allocator，
不为保留现有 SmallObjectSlab 而重新包一层通用 allocator。
如希望保留普通分配的 slab 优化，需要结合 M03 / M11 的实际性能比较证明价值。

当前 SmallObjectSlab 在 `memory.zig` 中按尺寸分级，将 4 KiB arena 切成小块，
通过空闲链表分配和回收；Runtime 初始化时启用。它承担两种现有用途：

- 普通小分配的存储复用，潜在价值是减少向底层 allocator 请求小块的开销。
  代价包括块头、尺寸取整、arena/空闲链表管理和空 arena 保留；
  当前未据此证明它优于直接使用选定的标准 allocator。
- 部分 GC 对象的存储，包含 Object block heap 分配失败后的回退路径。
  GC 地址注册结构观察 slab arena 的创建与释放，并利用其布局识别对象地址。
  此职责具有当前实现依赖，不能把整个 slab 当成纯原生分配缓存直接删除。

具体证据入口：`SmallObjectSlab.allocAtIndex/freeAtIndex/releaseEmptyArena`、
`MemoryAccount.createInternal`、`gc.Registry.observeSlabArenas`、
`gc_address_registry.zig` 的 arena 地址注册。
这里不以旧源码注释中的性能数字作为当前测量结果。

本项只评估普通原生分配是否默认经过额外 slab；GC 专用存储的去留与迁移
另行 review。尚未实现普通分配绕过，也未授权删除 GC 依赖的 slab 路径。

### R08：GC 分配路由应由谁负责

**已确定设计方向；未实施。** GC 对象的存储选择归 GC 子系统，Runtime 持有该子系统；
不将 MemoryAccount 中的 nursery/block heap/slab 路由原样搬成 Runtime 的通用分配逻辑。

当前证据：`MemoryAccount.createInternal` 根据 `T.gc_kind_tag` 区分 GC 类型。
只有 Object 类型且尺寸受支持时才尝试 nursery（启用时）和 block heap；
block heap 分配失败会继续进入 slab/独立分配路径。其他 GC 类型也使用账户分配，
例如 `BigInt.createFromOwnedReserved` 调用 `rt.memory.create(BigInt)`，
尺寸和对齐满足 slab 条件时可走 slab，否则走独立分配。
因此当前 slab 的 GC 用途不仅是 Object 的失败回退，block heap 尚未覆盖所有 GC 类型。

GC 的地址注册结构会识别 block、slab 和独立分配中的对象；slab arena 的创建和释放
由 `Registry.observeSlabArenas` 接入。这些是现有回收正确性依赖。

职责上的绕行是：GC Registry 自己持有 block heap 和 nursery，
`serveObjectCells` 却将它们的指针写回 MemoryAccount，由账户选择存储，
再由 GC 识别和回收这些存储。取消账户后，把 GC 分配路由收回 GC 子系统。
此处只确定职责归属，不决定专用接口名称，不把所有类型迁移到 block heap，
不改变 nursery 策略，也不直接删除 slab 或失败回退；这些算法变化须另行评估。

### R09：账户层的 GC 回调是否还需要存在

**已确定设计方向（2026-09-22）；未实施。** 随 MemoryAccount 移除，取消其
`trigger_gc_fn/ctx`、`limit_gc_fn/ctx` 这两组内部回调桥接。
GC 分配慢路径显式检查堆预算并在安全条件下请求/执行回收、重新检查预算；
普通原生 allocator 不隐式回调 Runtime 发起 GC，延续 M09 / M10。

当前回调承担不同工作，不能混称为“每次分配都 GC”：

- `trigger_gc_fn` 接到 Runtime 的分配阈值请求入口。
  `allocation_gc_trigger_enabled` 仅在测试或 force-GC 配置启用；
  默认生产配置的常规阈值判断已有对象分配边界和 GC poll。
- `limit_gc_fn` 在 `checkAllocation` 发现账户总量加请求量超过限额时调用，
  回收返回后重新检查账户用量。此检查可被普通原生分配触发，
  不受上述逐分配阈值开关控制；回调实现使用 engine_active 根扫描。
  这里是限额重检查，不是通用的底层 allocator 分配失败重试。

问题是通用分配层通过函数指针绕回 Runtime 做回收，使普通分配也隐含 GC 行为，
且这两组回调的上下文都指向同一 Runtime。目标分层已让普通分配使用标准 allocator、
GC 分配归 GC 子系统，因此无需延续账户层的桥接协议。
Runtime 仍可提供根枚举和执行状态协调；不据此将完整 GC 调度器搬家。
测试注入、force-GC、回收期间禁止嵌套 GC 及临时根保护必须在新路径中保留或明确迁移。
此项不涉及宿主 GC 通知回调，也不修改具体阈值策略和堆上限数值。

### R10：是否保留 allocated_bytes 统一账户总量

**已确定设计方向（2026-09-22）；未实施。** 不为保留 MemoryAccount 的 `allocated_bytes`
而重新包装所有普通原生分配。Runtime 对外汇总定义清楚的子系统统计，
GC 堆预算和调度使用对应的堆计量；不把旧账户总量直接改名为 JS heap 用量。

当前 `Runtime.memoryUsage` 直接导出账户的 allocated_bytes，
同一字段又用于 `checkAllocation` 限额检查、分配阈值和阈值重置。
账户同时记入原生分配与部分 GC 分配；slab 以尺寸级别记账，
nursery 的逐对象分配则不在该账户逐笔增加。因此它既不是全部 Runtime
实际占用的完整统计，也不是纯 JS heap 用量，更不是进程 RSS。

已有可用的子系统计量包括 block heap 的 `stats.live_bytes/committed_bytes`
及 nursery 的 `allocated_bytes`。这些字段的覆盖和定义不同，
不可直接相加就当作最终公共统计；迁移须核对 slab、独立 GC 分配、
对象附属缓冲区等归属与重叠，堆上限的具体计量口径另行 review。

普通原生分配改为标准 allocator 后，不承诺从该接口直接取得精确总用量。
需要的原生分类统计可由资源所有者记录尺寸/容量；是否提供全量原生账本
需有独立需求，不能作为删除 MemoryAccount 的隐含前提。
本项保留内存可观测性的目标，不因总账取消而删除 GC 预算或统计能力。

### R11：object_bytes 是否应继续由数量乘固定尺寸得到

**已确定设计方向（2026-09-22）；未实施。** 不将“对象数量 × 普通对象尺寸”继续作为对象用量统计。
Runtime 对外报告对象字节数时，应汇总 GC 侧有明确口径的数据；
尚未具备对应统计时应明确不可用，不能用固定尺寸乘法冒充实际对象占用。

当前 `Runtime.memoryUsage` 的计算是
`object_count * Object.objectBodyBytes(class.ids.object, false)`。
但 `Object.objectBodyBytes` 接受 class_id 和 slots2_layout，
实际构造路径还可能包含内联 class payload；不同 Object 的本体尺寸并不相同。
此外，本体大小也不等于附属属性/元素缓冲区的占用，更不等于堆提交容量。
该公式本身只给出固定尺寸折算值，不能回答宿主“这些对象用了多少内存”。

建议去掉 Runtime 中这项固定尺寸推算；对象本体、附属存储及堆容量需各自
定义口径，具体统计实现继续 review。此项不要求为查询统计强制 GC，
也不要求每次查询遍历整个堆；不据此承诺新增计数器的零成本。
现有计数仍需明确是在堆中尚未回收的节点数，不将其宣传为已证明可达的对象数。
本项不自动修改其他统计字段，仅记录它们需遵守相同的明确口径原则。

### R12：普通内存统计查询是否应隐含遍历整个堆

**已确定设计方向（2026-09-22）；未实施。** 常规内存统计读取已有的、口径明确的子系统计量，
不隐含全堆遍历；按类型计数等需要遍历的详细诊断由宿主明确请求。
具体 API 形式另定，不为此预建统计框架。

当前 `Runtime.memoryUsage` 遍历 atoms.entries 和 classes.records，
随后分别调用 `gc.liveCountKind(.object/.shape/.module)`。
`gc_registry_diagnostics.liveCountKind` 每次都以 `objectIterator(.all)`
遍历节点并过滤类型，因此一次查询会做三次全节点枚举。
这不是只读取若干计数器的接口；对象规模增大时查询工作量随之增大。
本次仅确认结构成本，未测量延迟或宣称实际性能瓶颈。

场景：宿主定时采样内存曲线时，不应为读取堆用量而顺带枚举全部对象三次。
排查对象类型分布时则可以显式执行详细查询；此时可一次遍历汇总多种类型，
无需每种类型重复遍历。详细查询只描述当前尚未回收的节点，不自动触发 GC。

取舍：不为让所有查询恒定时间而默认给每次对象分配/释放添加全部分类计数。
详细遍历的执行阶段须满足 GC/线程安全约束；本项不承诺任意线程可直接查询。

### R13：动态类型表是否应按进程全局 ClassId 扩容

**建议，待确认；未实施。** 保留 Runtime 对类型定义的所有权，但动态类型
存储不应被进程全局 ID 的数值直接决定。类型身份与本 Runtime 的存储位置应分开评估。
这不批准立即改成哈希表或给每个对象添加描述指针。

当前 class.Record 保存 payload 布局、清理和引用遍历回调、binding_data 等，
具有对象构造与回收用途，并非 JS class 声明清单；类型定义属于 Runtime 的方向仍成立。
具体存储问题是 `ClassIdSlot` 使用进程全局递增 ID，
`Table.register` 却按 `id + 1` 调用 ensureCapacity，后者同时分配并初始化
Record 与 RegistrationState 两个连续数组，recordPtr 直接以 ID 为下标。

由代码可推导的场景：如果一个新 Runtime 只注册一个动态类型，其 ID 已是 10000，
两张数组都必须容纳至少 10001 项，尽管绝大多数动态槽位未注册。
这是机制示例，未执行该场景或测量内存；复用同一个 ClassIdSlot 不会反复分配新 ID。
现有直接下标的好处是查找简单，替代布局的查询成本也必须纳入评估。

本项建议让动态表规模跟本 Runtime 实际注册类型相关，避免继承进程其他类型
分配造成的空洞；内置固定 ID 的直接索引另行处理。具体布局、对象携带何种身份、
注册/注销和回调存活保证仍需后续 review，见 C13 / C14。

#### R13 参考：V8 的宿主类型模板（2026-09-22 核对 main）

V8 的 FunctionTemplate / ObjectTemplate 以 Isolate 为参数创建，
FunctionTemplate.GetFunction(context) 在指定 Context 实例化函数。
这条公开绑定路径以模板描述身份与行为，不要求宿主先申请进程全局递增 ClassId。
`FunctionTemplateInfo::IsTemplateFor` 通过对象 Map 的构造信息取得模板，
比较模板身份并检查父模板链，不通过 zjs 式全局 ClassId 索引 Record 数组。

V8 仍有内部编号和缓存：`TemplateInfo::EnsureHasSerialNumber` 从该 Isolate 的 heap
取得序号；实例化缓存位于 NativeContext，小序号走固定大小的快速数组，
其余走 EphemeronHashTable。因此不能表述为“V8 完全不用 ID 或表”。
这也不说明 V8 模板完整替代 zjs Record 的 payload 清理/引用遍历职责。

对 zjs 的参考是让类型身份、Runtime 内的定义与实际存储位置分离，
而非照搬完整模板系统。R13 仍待确认，具体表示需比较现有对象布局与查找成本。

来源：[V8 模板公共接口](https://raw.githubusercontent.com/v8/v8/main/include/v8-template.h)、
[模板身份检查、序号和缓存实现](https://raw.githubusercontent.com/v8/v8/main/src/objects/templates.cc)。

### R14：全局类型身份与 Runtime 内部编号是否必须相同

**建议，待确认；未实施。** 在 R13 的基础上，优先评估“宿主类型身份稳定、
Runtime 内部编号局部化”。同一宿主类型在不同 Runtime 中可以拥有不同内部编号，
每个 Runtime 内仍可用紧凑整数索引类型记录；不默认给每个 JS 对象增加类型描述指针。

全局 ID 有实际便利：`native_object.unwrap` 仅比较对象 class_id 与传入 class_id，
类型匹配即可取出原生指针。`ClassIdSlot` 的设计意图是让同一宿主类型跨 Runtime
复用身份。不能把这一便利说成无用，也不能把类型 slot 每次注册都会消耗 ID 当作事实。
不过当前仓库搜索仅找到 ClassIdSlot 定义和相关说明，未找到 getOrAllocate 的实际调用；
Runtime.newClassId 调用全局分配器，NativeType.registerType 接受调用者提供的 ID。
因此注释中的高层集成不能直接当成已经实现的完整绑定流程。

当前已存在每 Runtime 的 NativeType（含 owner 和 class_id），可作为进一步设计
类型身份到局部编号关联的起点。示意场景：同一宿主 File 类型在 Runtime A、B
中分别注册为局部编号 80、83，其定义与回调数据仍分别属于 A、B。
这里的数字只说明编号允许不同，不是当前运行结果。

代价是注册及类型检查需要使用正确 Runtime 对应的绑定记录，现有
unwrap(value, global_id) 调用约定必须审计；需防止不同 Runtime 的相同局部编号
被误当成同一类型。宿主身份 token 的表示、注销后编号复用与存活约束尚未选定。
此项保留直接整数索引的候选优势，不声称性能收益，不改变已确认的跨 Context 类型规则。

#### R14 收敛：先定简单方案，继续 review

用户明确“先简单实现”指先定简单方案，不是授权现在修改源码。
简单候选收敛为：保留内置固定编号，动态编号由各 Runtime 分配；
宿主分别保存各 Runtime 的 NativeType 绑定，同一宿主类型可在不同 Runtime
分别注册，不预建全局身份 token 到局部编号的映射框架。
先前稳定身份分层作为扩展可能性保留，不列为本阶段必要工作。
对象继续使用小整数，跨 Runtime 的绑定误用检查和绑定有效期仍需明确。
具体接口继续逐项 review，不把本条当作源码迁移完成。

### R15：是否需要公开“先申请类型 ID，再注册定义”两步流程

**已确定设计方向（2026-09-22）；未实施。** 简单的宿主类型注册入口接收定义并返回 Runtime
所属的绑定，内部负责分配局部编号；宿主不必先调用 newClassId 再传回编号。
内置类型的固定编号初始化属于内部需求，不要求与动态宿主注册共用公开流程。

当前 `tests/core.zig` 的 registerStandaloneInlineObjectTestClass 和
registerS4cPayloadClass 都先调用 `rt.newClassId(0)`，再 `rt.classes.register(id, def)`。
`native_object.registerType` 同样要求调用者传入 ID，然后创建并返回 NativeType。
两步方式配合全局身份可复用的设计有其背景，但在 Runtime 局部编号方案中，
这部分编号协调可以留在注册内部。

建议成功时一次返回可用绑定，失败时回收本次已创建的资源，不向宿主暴露
尚未完成注册的绑定。具体错误回滚与 ID 分配顺序仍需实现前审计。
本项不引入按类型名称去重，也不将同名当成同一类型；宿主复用已返回绑定即可。
所有类型定义是否都用现有 NativeType 表达仍待确定，不将仅适用于 native_object
的结构直接泛化为完整 class.Record 替代品。

### R16：是否支持单独注销动态类型

**已确定设计方向（2026-09-22）；未实施。** 简单方案中，注册的类型定义保留至 Runtime 销毁，
暂不提供单独注销。对象仍正常由 GC 回收；延长的是类型定义及其绑定数据的生命周期。

当前 `class.Table.unregisterDynamicOwned` 设置 unregister_pending，
`completePendingUnregister` 等待对象、构造及回调等 pin 释放后才清除定义并清理绑定数据。
这支持 Runtime 存活期间撤销类型，但引入延迟注销及存活协调。
暂不支持单独注销可收敛该生命周期；代价是长期运行、动态注册大量类型时，
定义不会提前释放。需要运行中卸载类型的场景留待有具体需求时再评估。
相关 pin/generation 是否还有其他用途必须审计，不能因本项获批就机械删除所有保护。

### R17：注册后的类型布局与回调是否可变

**已确定设计方向（2026-09-22）；未实施。** 注册成功后固定类型的 payload 布局、GC 引用遍历
和清理回调，不增加在线替换这些定义的接口。需要不同定义时注册新类型。
对象实例的宿主数据及 JS 属性、prototype 的正常变化不受这条元数据规则限制。

当前 `Table.registerAtom` 拒绝已注册 ID（DuplicateClass），并在注册时写入定义，
对内置类型同时生成 standard_plans。该入口已经不支持覆盖注册，
但 Record 存储的整体可变访问尚未做完整审计，不能声称所有路径已强制不可变。
布局决定实例分配大小，清理和标记回调解释实例 payload；在线替换必须处理旧实例兼容。
结合 R16 的 Runtime 生命周期定义，保持元数据固定可避免引入这套迁移机制。

### R18：类型表是否独立保存所属线程

**已确定设计方向（2026-09-22）；未实施。** Runtime 是所属线程状态的唯一权威，
类型表沿用该权威，不独立维护一份可能分歧的 owner_thread_id。
当前 JSRuntime 与 class.Table 各自在初始化时读取当前线程，并各有
isOwnerThread/requireOwnerThread/assertOwnerThread 检查。
类型表属于 Runtime，不需要独立迁移线程的生命周期。

结合 C06 已确定的串行线程迁移方向，单一权威可避免更新 Runtime 后遗留
子系统旧线程状态；当前尚未实现迁移，未据此宣称已复现线程错误。
本项不删除线程检查：宿主入口仍需拒绝不合法线程访问，内部可保留一致性断言。
共享检查状态的访问方式及独立 Table 测试如何适配，实施前另行核对。

### R19：类型表是否保留两套初始化入口

**单一初始化路径已确定（2026-09-22）；未实施。** class.Table 作为 Runtime 内部子系统，
保留在最终地址原地初始化的一条路径，不继续维护返回 Table 值的另一套入口。
Runtime 本体先分配并固定地址，再初始化内嵌类型表，延续 R02 / R03。

当前 Table.init 返回值，通过 ensureCapacity 为 records 和 registration_states
分配外部数组；Table.initInPlace 将这两个切片绑定到自身 inline 数组。
Runtime 当前使用 initInPlace。两者均注册内置类型，却维护不同的初始存储路径。
原地初始化后不能随意移动 Table，因为切片指向自身内嵌存储。
此项不将 Table 改成独立堆对象，也不决定 inline 容量；只收敛内部构造入口。
实施前仍需核对所有调用及测试，不以初始化方式不同作为现有代码错误的证据。

命名建议（待确认）：原 `initInPlace` 改名为 `init`，以 `self: *Table`
参数表达原地初始化，与 `deinit` 配对；单一入口不再需要 InPlace 后缀区分。
Runtime 本体仍用 create/destroy，表达自行分配和释放本体的不同所有权职责。
初始化后地址必须稳定的约束应写入类型/方法说明，不依赖方法名表达。

### R20：微任务清空是否应顺带驱动宿主事件循环

**已确定设计方向（2026-09-22）；未实施。** 引擎的微任务 checkpoint 只运行队列里的微任务；
OS 信号、I/O、定时器及宿主完成通知由宿主事件循环调度，相关处理入队的微任务
再交给 checkpoint。具体入口命名与自动 checkpoint 接入另行 review。

当前 `JSContext.runJobs` 调用 `drainPendingPromiseJobs`；后者在微任务队列为空后
继续调用 runNextOsSignalHandler、runNextOsRwHandler、runNextOsTimer 和
runNextAtomicsHostCompletion，再回头处理新作业。这是一个同时驱动宿主事件的循环，
并非只清空微任务。建议拆清这项职责，避免宿主执行 checkpoint 时意外运行定时器等回调。
现有便利的综合执行能力可由 EventLoop 承担，不以边界调整删除已有宿主事件支持。

顺带核对 E03 的当前差异：drainPendingPromiseJobs 遇到 `.exception` 返回 JSException，
JSContext.runJobs 在已有异常或未处理拒绝时又可能吞掉该错误返回；
这与既定的宿主获知普通作业异常并继续下一项尚不一致。此处先记录差异，
不把它扩展为本轮缺陷复现或将 OOM/终止混同普通作业异常。

#### R20 参考：V8 的微任务与平台任务入口

2026-09-22 核对 V8 main：`Isolate::PerformMicrotaskCheckpoint` 清空默认
MicrotaskQueue 并执行 ClearKeptObjects 等 checkpoint 收尾；
`MicrotaskQueue::PerformCheckpoint` 是指定微任务队列的入口。
平台前台任务另由 `v8::platform::PumpMessageLoop` 驱动，宿主负责集成事件循环。
这两个入口不能混同；微任务 checkpoint 本身不轮询宿主 I/O 或派发宿主定时器。
微任务调用宿主函数仍可产生宿主副作用，不将职责边界解释为副作用隔离。

因此 R20 的边界与 V8 一致，但不需要为 zjs 引入已暂缓的完整 Platform 抽象。
异常处理的对外形式另行对齐：V8 文档说明 checkpoint 不向调用者传播微任务回调异常，
不能把它说成用 checkpoint 的普通返回值逐项返回异常；此处只比较调度边界。

来源：[Isolate 微任务入口](https://raw.githubusercontent.com/v8/v8/main/include/v8-isolate.h)、
[MicrotaskQueue](https://raw.githubusercontent.com/v8/v8/main/include/v8-microtask-queue.h)、
[平台任务入口](https://raw.githubusercontent.com/v8/v8/main/include/libplatform/libplatform.h)。

### R21：微任务 checkpoint 的公开入口属于 Runtime 还是 Context

**已确定设计方向（2026-09-22）；未实施。** 在 E01 的单一共享队列方案下，公开 checkpoint
入口属于 Runtime；执行每个作业时使用该作业保存的 Realm，宿主无需选一个 Context
来清空整个 Runtime 的队列。用户确认简短名称 `Runtime.runMicrotasks()`，
取代此前 performMicrotaskCheckpoint 命名建议；具体参数和返回形式待定。
说明中明确其执行到微任务队列为空并完成必要 checkpoint 收尾的语义。

当前 JSContext.runJobs 先取自身 global，再传入 drainPendingPromiseJobs；
实际 drainOnePendingJob 忽略传入 global，从 ctx.runtime.job_queue 取作业，
通过 entry.realm.borrow 取得 job_ctx 和 job_global 执行。因此 Context 方法名称
容易掩盖队列的 Runtime 范围，入口 Context 也未必是发生异常的作业 Context。

此项明确公开 API 的归属，不将 exec 层作业执行代码搬入 core/runtime.zig；
还需迁移过期 Atomics 等宿主事件处理，并核对跨 Realm 异常报告。
队列中的 RealmRef 必须保持到作业结束，不能因入口改为 Runtime 而去掉它。

### R22：runMicrotasks 的嵌套调用是否再次清空队列

**已确定设计方向（2026-09-22）；未实施。** 同一 Runtime 正在执行微任务时，再次调用
runMicrotasks 直接返回，不递归启动第二轮清空，也不将此情况作为普通错误。
当前作业结束后，外层循环继续处理队列，包括期间新加入的微任务。

场景：微任务 A 调用宿主函数，宿主再次调用 runMicrotasks；
若内层继续出队，微任务 B 会在 A 尚未结束时执行。禁止嵌套清空可保持微任务
逐个完成的执行边界，不限制宿主函数正常重入执行 JS。
当前 drainPendingPromiseJobs 本身只有循环，没有同队列正在运行的入口保护；
本次未运行嵌套调用复现，不据此扩大为所有上层调用路径均无保护的结论。

可用 Runtime 内一个“正在执行微任务”的状态表达，所有退出路径都必须恢复。
嵌套返回不会执行第二次 checkpoint 收尾；收尾归外层，异常/终止具体清理另行核对。
参考已核对的 V8 MicrotaskQueue.PerformCheckpoint：队列已在运行时不再次执行。
来源：[V8 MicrotaskQueue](https://raw.githubusercontent.com/v8/v8/main/include/v8-microtask-queue.h)。

### R23：WeakRef 临时保活何时清理

**已确定设计方向（2026-09-22，参照 V8）；未实施。** WeakRef 的临时保活
在外层 runMicrotasks 的整轮收尾清理，不在每个微任务结束时清理。
嵌套调用按 R22 直接返回，不清理外层保活状态；空队列的有效 checkpoint
仍需处理已有保活对象，不因没有作业就遗漏收尾。

当前 `drainOnePendingJob` 在取出单个作业后设置
`defer ctx.runtime.clearWeakRefKeptAlive()`，因此清理边界是单个作业。
V8 main（2026-09-22 核对）`PerformCheckpointInternal` 先 RunMicrotasks，
再 ClearKeptObjects。新边界可使本轮因 WeakRef 访问获得的保活持续到整轮结束。
这不是强制回收对象，只是撤销这项临时强引用保护；异常/终止收尾须另行审计。
此次只做源码对照，未复现可见差异，不宣称当前行为已被证明违反 ECMA-262。

来源：[V8 checkpoint 收尾](https://raw.githubusercontent.com/v8/v8/main/src/execution/microtask-queue.cc)。

### R24：微任务执行遭终止后的剩余队列

**已确定设计方向（2026-09-22）；未实施。** 参照 V8，在微任务执行期间遭到执行终止时，
停止本轮并清空该队列剩余微任务；宿主显式恢复执行能力后，不续跑被丢弃的旧队列。
这仅针对执行终止，不把普通 JS 异常、Promise 拒绝或所有 OOM 自动归入同一处理。

V8 main（2026-09-22 核对）MicrotaskQueue.RunMicrotasks 检测到
is_execution_terminating 后释放 ring_buffer、归零 size/capacity/start，
调用终止处理及完成通知，再返回失败标志。
当前 zjs drainPendingPromiseJobs 遇错误直接返回，该函数没有专门的终止清队列分支；
完整 Interrupted 传播及上层清理仍需审计，本次未执行终止复现。

清空队列意味着丢弃执行机会而非执行回调，必须释放每个 Job 持有的 RealmRef
及 payload 资源。不会替所有相关 Promise 自动生成拒绝，它们可能保持 pending。
也不据此取消所有宿主 I/O 或定时器；宿主任务的终止策略另行 review。
同一队列共享的 Context 都受此影响，符合 E01 的 Runtime 队列范围。

补充 V8 终止流程核对：清空的是本次正在运行的 MicrotaskQueue，不泛指所有
Isolate 队列或宿主事件。OnTerminationDuringRunMicrotasks 清理 current_microtask、
Promise 调试栈等状态，对适用的 Promise 作业补齐 after 通知，并向外层 TryCatch
标记终止。RunMicrotasks 的 -1 是内部返回值，公开 PerformMicrotaskCheckpoint
是 void，不能描述成宿主通过该入口的 -1 获知终止。
CancelTerminateExecution 可恢复继续调用引擎的能力，不恢复已经丢弃的队列和退出的调用帧。
清队列不等于自动 reject 对应 Promise；相关 Promise 可能保持 pending。

补充来源：[终止状态清理](https://raw.githubusercontent.com/v8/v8/main/src/execution/isolate.cc)、
[公开终止与恢复接口](https://raw.githubusercontent.com/v8/v8/main/include/v8-isolate.h)。

来源：[V8 终止分支](https://raw.githubusercontent.com/v8/v8/main/src/execution/microtask-queue.cc)。

### R25：runMicrotasks 是否接收 output Writer

**已确定设计方向（2026-09-22）；未实施。** 新的 Runtime.runMicrotasks 不接收输出流参数，
输出目的地由宿主安装的 console/print 等绑定配置并管理。
不将 Writer 从方法参数机械搬成 Runtime 的全局输出字段。

当前 JSContext.runJobs(output) 将同一个 Writer 传给整个共享队列的执行路径，
exec.call.hostOutputValues 据此输出参数；output 为 null 时不写出内容。
这使队列执行入口还承担日志目的地选择，多个 Realm 的输出也受本次 drain 参数影响。
目标是作业按自身 Realm 执行，所调用的宿主输出绑定决定去向，微任务调度无需了解 Writer。

此项不取消默认 console/print 能力，不吞掉写入错误，也不直接改造所有
eval/call/output 参数链。输出绑定及 Writer 有效期需在相关子系统 review 时落实；
当前仅确定该微任务接口的推荐边界，具体签名中的其他参数和错误结果另议。

### R26：普通微任务异常通过什么接口交给宿主

**建议，待确认；未实施。** 延续 E03 的“宿主处理、继续下一项”，
由 Runtime 配置的宿主通知回调逐项报告未被作业内部处理的普通 JS 异常，
回调携带实际作业的 Realm/Context 与异常值；不将每个普通异常变成
runMicrotasks 提前返回的错误，也不累积异常数组后才统一报告。

当前 drainPendingPromiseJobs 在 `.exception` 时直接返回 JSException，
JSContext.runJobs 又在 hasException 或 hasUnhandledRejection 时吞掉 Zig 错误返回。
新接口须明确区分普通异常通知、执行终止及其他无法继续的失败。
Promise reaction 内已转换为 Promise rejection 的抛出不因此重复当作未捕获异常报告，
未处理拒绝仍使用已有独立设计 O01。

实现时须在继续下一项前处理该异常状态，并在宿主回调期间保护异常值及作业 Realm，
使回调触发 GC 不导致其失效。通知接口的命名、未安装回调时的策略、
回调允许的操作与保留异常值的方式待逐项 review，本项不预先批准吞异常默认值。

### R27：异常状态能否把底层执行失败变成成功返回

**已确定设计方向（2026-09-22）；未实施。** runMicrotasks 应按实际失败类别处理返回值，
不能仅因为存在 pending exception 或未处理 Promise rejection 就吞掉底层错误。
普通作业异常按 E03 报告并继续，具体报告接口 R26 仍待确认；
执行终止、OOM 等无法继续的失败必须让宿主获知。

当前 JSContext.runJobs 对 drainPendingPromiseJobs 的所有错误统一 catch，
只要 hasException 或 hasUnhandledRejection 为真就直接成功返回，不检查 err 类别。
RuntimeError 包含 Interrupted、OutOfMemory 等；因此这段包装没有保持失败类别的边界。
此处确认的是代码分支，尚未复现某个具体负载将 OOM/终止错误遮蔽，
不把风险推断当成已有端到端证据。

目标是在原始错误信息仍可用时区分普通 JS 异常与终止/资源失败，
不把异常槽或 rejection 通知状态当成通用成功条件；也不为消除该状态而
擅自清除宿主尚未处理的 Promise rejection。具体返回错误集合在接口实施前核对。

### R28：是否需要重写微任务队列的 FIFO 存储

**已确定保留现有基本存储方式（2026-09-22）；未实施改动。** 当前 Queue.takeFirst
读取首项后推进 jobs 切片与 head，不搬动剩余作业，单次头部出队为 O(1)。
ensureCapacity 只在尾部容量不足时按条件回收前缀或扩容，已有摊销控制，
不能将当前实现误判为每次出队都线性搬移。

因此此次 Runtime 职责拆分不需要顺带把队列改为链表或环形缓冲区。
分配改用标准 allocator 的既定方向另行实施；reserved_entries 和
unlinked_head_slots 涉及准备中的事务及失败后重入队，不能只凭字段多而删除。
takeAt 的中间删除仍搬移尾部，本项不声称所有队列操作都为 O(1)。
未测量性能，此结论仅说明当前 FIFO 路径没有需要立即修复的逐次搬移问题。

### R29：弱对象身份映射是否应直接放在 JSRuntime

**已确定设计方向（2026-09-22）；未实施。** 将 weak_object_ids、weak_id_objects、next_weak_id
及注册/解析/移除操作归入 GC 子系统内的弱身份管理模块，Runtime 不直接维护这套映射算法。
Runtime 仍拥有 GC，并保留必要的宿主弱句柄接口；具体模块名称及调用层次待实施前核对。

当前 runtime.zig 直接保存两张哈希表与递增序号，registerWeakObjectIdentity
负责双向插入和失败回滚，objectFromWeakIdentity 负责解析，takeWeakObjectIdentity
负责对象销毁时移除映射。这是对象回收相关的内部机制，防止地址重用后旧弱引用
误指向新对象，具有必要作用；不应仅因 Runtime 臃肿而删掉。

本项只收敛职责，不改弱 ID 编码、容器、GC 回收算法或异常回滚行为。
不要求把字段直接塞入 gc.Registry 的热状态布局；可由 GC 内部模块封装，
避免以拆文件名义改变热字段位置或扩大公共 API。

### R30：GC 诊断数据是否直接内嵌在 Runtime

**已确定设计方向（2026-09-22）；未实施。** gc_mark_footprint 归 GC 的诊断状态管理，
不继续作为 Runtime 的独立内嵌数据块；诊断存储可按需建立，
Runtime 提供必要的查询入口，不暴露诊断字段给 CLI 直接读写。

当前 gc_trace_stw 写 rt.gc_mark_footprint，CLI 的 --gc-mark-footprint 报告读取它。
源码注释明确将其留在 Runtime 的原因：曾直接放入 gc.stats 时改变 Registry
热字段布局。注释中的 680 字节及偏移数字是历史记录，本轮未重新测量。
因此不建议简单把整个数据块塞回 gc.Registry；归属调整须隔离诊断存储与热状态。

本项保留已有诊断能力，不调整 GC 算法、不新增诊断系统；具体按需存储方式、
启用时机与失败反馈在实施前核对。未声称此项已有实测性能收益。

### R31：延迟资源清理的内部状态是否直接铺在 Runtime

**已确定设计方向（2026-09-22）；未实施。** 将现有延迟原生清理及 class payload 清理的
队列、预约状态、防重入状态和执行逻辑封装到一个内部清理模块，Runtime 持有它，
负责在允许的执行边界及销毁阶段协调调用。

当前 Runtime 直接维护 deferred_native_cleanups、deferred_class_payload_finalizers、
draining 标志、active_deferred_class_payload_finalizer、预约计数和相关根等，
并实现入队、执行、清空及缓冲区释放。它们构成完整资源清理职责，可作为一个单元维护。
Runtime.deinit 及 GC/分配安全边界有多处调用，表明执行时机仍需要 Runtime 协调。

本项只收敛字段和方法归属，不合并两类任务的语义，不改清理时序或队列算法，
不加入后台线程或通用任务框架。JS FinalizationRegistry 的队列作业也不因此搬到
原生资源清理队列。搬迁须保留回调重入保护、在途 payload 根及销毁顺序。
模块封装本身不保证 Runtime 的 sizeof 下降，不声称性能收益。

### R32：异常值及附带标志是否应作为整体管理

**已确定设计方向（2026-09-22）；未实施。** Runtime 继续持有当前执行的异常状态，
将 current_exception、current_exception_uncatchable、current_exception_out_of_memory
封装为一个小型 ExceptionState，同时收拢设置、取走、清空及状态保存恢复操作。
不将异常槽迁移成每个 Context 各一份，也不增加独立堆分配。

当前 Context.throwValue/takeException/clearException 与 Runtime 初始化、销毁
都分别写这三个字段。它们需要保持一致：普通抛出清除特殊标志，取走或清空异常时
也须清除标志。集中操作可避免调用方逐字段维护这项约束；仅包字段而继续散写没有意义。

本项不改变哪些异常可捕获、OOM 传播或执行终止规则；实施前须审计 exec 层
对当前异常的直接访问和重入保存恢复，并保留异常值的 GC 根追踪。
类型名为建议，不据此宣称 sizeof 或执行性能改善。

### R33：内置全局对象的安装器是否需要进程全局注册

**建议，待确认；未实施。** 引擎内部创建流程显式接好 Runtime 所需的内置初始化
回调及配套信息，不依赖先修改进程全局默认值再由 Runtime 复制。
宿主继续使用单一 create 入口，不承担手工注册内置实现的步骤。

当前 core/runtime.zig 有 default_standard_globals_installer 及容量全局变量，
Runtime 初始化时复制它们；exec.standard_globals.configureRuntime 又同时注册全局默认
并设置当前 Runtime，js_context.ensureStandardGlobalsRegistered 还会在缺失时补接回调。
这些都在解决 core 不能依赖 exec 的分层问题，但引入多个接线时机和进程状态依赖。

建议保留必要的层间回调，由能访问 core 和 exec 的引擎组装层在创建时统一配置。
不让 core 直接 import exec，不增加 Platform 或宿主公开的回调配置框架。
本项讨论安装器接线，内置对象的按需创建策略保持独立；具体测试用 core-only
构造路径和初始化失败清理，实施前核对。

## 内存能力：已讨论的边界

| 编号 | 问题、场景与结论 | 状态／尚缺工作 |
| --- | --- | --- |
| M01 | 移除独立 MemoryAccount 抽象，内存管理责任归 JSRuntime；必要状态由 Runtime 持有，内部算法留在子系统。宿主 allocator、统计、限制、GC 重试和存储算法继续逐项评估。 | 已确定设计方向，尚未实施；生命周期简化见 R03，具体接口和字段迁移尚待 review。 |
| M02 | 是否接受宿主 allocator？提供引擎默认 allocator，也允许宿主覆盖，供已有内存池、分配诊断和受控嵌入使用。 | 已确定；不强制每个宿主提供 allocator，不因此自动增加另一层包装。 |
| M03 | 默认选择 `c_allocator` 还是 `smp_allocator`？两者在 libc 依赖、并发小对象分配、释放与驻留内存上取舍不同。 | 待测量，未选型；见 [allocator TODO](../runtime-allocator-todo.md)。 |
| M04 | 宿主 allocator 覆盖范围。当前 GC block heap、nursery、地址注册结构、slab 等存在独立 allocator 路径；仅替换入口不能声称覆盖全部内存。 | 待评估：列出实际分配路由；性能比较必须说明覆盖范围。 |
| M05 | 内存统计参考 V8，用户要求提供 V8 有的统计能力；区分已用、容量、物理提交、外部内存等口径。 | 已确定的能力方向；不为尚不存在的子系统伪造对应值，不因此默认实施全量原生分配账本。 |
| M06 | 内存上限参考 V8，针对 JS heap，而非进程全部内存或全部宿主分配。 | 已确定；当前 MemoryAccount 全量记账限制与目标的差异需另行迁移评估。 |
| M07 | 最终 OOM 交给宿主处理，不由引擎结束进程。 | 已确定，刻意不同于 V8 的最终 fatal OOM；安全清理与 OOM 后可继续使用的边界仍需审计。 |
| M08 | 临近堆上限时允许宿主扩容的回调，曾建议可选、不自动扩容。 | 方向记录，不能把“继续”视为具体 API 已批准。 |
| M09 | GC 管理的分配可以在安全的慢路径触发 GC 与重试；普通 backing allocator 不承担选择 GC 时机的责任。 | 已确定；具体安全点与根保护需要当前实现证据。 |
| M10 | 普通原生分配失败返回 OOM，不在通用 allocator 内隐式 GC；上层可在根已保护的安全点明确重试。 | 已确定。当前限制回调即便在部分 `NoTrigger` 路径也可能 GC，名称不等于保证。 |
| M11 | 普通原生分配默认直接使用标准 allocator，额外通用 slab 需比较实际收益后再评估。 | 默认方向已确定，见 R07；性能比较待办，现有 GC 对 slab 的依赖单独 review。 |
| M12 | GC 专用存储层有合理职责；同块固定 size class 与 V8 式不同大小对象布局如何选择？ | 方向记录／待测量：对象大小分布、舍入浪费和块利用率，块尺寸未定案。 |
| M13 | 释放后的内存复用与空闲后归还系统。 | 方向记录；保留能力方向，阈值、周期和平台差异需验证。当前检查触发点不能描述成常驻后台定时器。 |
| M14 | 是否采用当前复制式 nursery、是否默认启用？ | 待评估；见 [nursery TODO](../runtime-nursery-todo.md)。含写屏障、复制晋升、保守 pin、整页保留成本。 |

参考：[V8 堆统计](https://v8.github.io/api/head/classv8_1_1HeapStatistics.html)、
[堆约束](https://v8.github.io/api/head/classv8_1_1ResourceConstraints.html)、
[V8 分代机制说明（2019，历史机制参考）](https://v8.dev/blog/trash-talk)。
allocator 性能判断以当前 Zig、平台和实际路由测量为准。

## 引用、Context 与原生类型

| 编号 | 问题、场景与结论 | 状态／尚缺工作 |
| --- | --- | --- |
| C01 | 宿主持有 JS 对象使用 handle，不承诺对象地址永久不变，允许 GC 移动对象。 | 已确定。 |
| C02 | 区分作用域内的临时 handle 与显式持有的 persistent/global handle。 | 已确定；生命周期与根登记实现需另行 review。 |
| C03 | 支持 weak handle，用于不阻止回收的宿主引用。 | 已确定。 |
| C04 | weak 通知不可执行 JS 或复活目标；允许约定范围内的宿主清理，JS 工作另行调度。 | 已确定的边界；V8 第一阶段仅允许 Reset、第二阶段仍禁止 JS，不能声称两者细节已完全一致。 |
| C05 | Runtime 销毁参考 V8：残留 handle 不延长 Runtime 生命周期，不因“仍有 handle”返回可恢复的销毁拒绝。 | 已确定；宿主必须提前结束 handle 使用，销毁后 handle 失效，不是自动变成可安全访问的空 handle。 |
| C06 | Runtime 可在不同线程间串行迁移，同一时刻由一个线程使用，包括 handle 操作。 | 已确定；当前固定 owner thread 实现需要单独迁移设计，不能仅改线程 ID。 |
| C07 | 同线程普通宿主回调允许重入 JS，嵌套调用需恢复状态。 | 已确定；不解除 weak 等特殊回调的限制。 |
| C08 | 一个 Runtime 支持多个 Context，各有全局对象及内建实例，共享 GC 与实例级资源预算。 | 已确定。 |
| C09 | 同 Runtime 的不同 Context 可共享对象和函数身份；函数保留词法环境及所属 Realm。 | 已确定。 |
| C10 | 是否增加 V8 security token / access check 式跨 Context 权限机制？ | 已确定暂不增加，缺少实际 use case；Context 隔离全局对象不是完整安全边界。 |
| C11 | 宿主释放 Context 根后，仍被跨 Context 对象或函数引用的 Realm 可继续存活，最终由 GC 回收。 | 方向记录。 |
| C12 | Runtime 提供宿主数据槽，用于关联日志器、加载器等 EngineState，避免外部全局映射。 | 已确定方向；仅保存指针，宿主管理生命周期、协调槽位，槽位不自动追踪 JS 引用。 |
| C13 | 共享类型描述记录类型身份、宿主 payload 清理与引用遍历规则，由 Runtime 管理；各 Context 分别创建构造函数和 prototype。 | 已确定。对象跨 Context 传递后仍需保持原类型规则。 |
| C14 | 是否因此必须保留当前 `classes: class.Table`？ | 待评估。类型描述有必要不等于 ID→表查找必需；可比较对象直接引用描述等方式。当前字段、legacy callback、注册流程须以代码为起点逐项分析。 |

C13/C14 当前证据：[class.Definition / Table](../../src/core/class.zig) 包含
`payload_finalizer`、`payload_mark`、类型数据及其他字段，Runtime 持有 `classes`。
前一版“建议保留注册表”的表述已收敛为“保留共享类型描述，表结构待评估”。

参考：[V8 嵌入与 handles](https://v8.dev/docs/embed)、
[Locker](https://raw.githubusercontent.com/v8/v8/main/include/v8-locker.h)、
[weak callback](https://raw.githubusercontent.com/v8/v8/main/include/v8-weak-callback-info.h)、
[templates](https://raw.githubusercontent.com/v8/v8/main/include/v8-template.h)。
V8 templates 不是 zjs class.Table 的直接对应物。

## 作业、异常与执行控制

| 编号 | 问题、场景与结论 | 状态／尚缺工作 |
| --- | --- | --- |
| E01 | 默认每个 Runtime 一个共享微任务队列，作业保存对应 Realm。 | 已确定；适用于能够同步交互的多个 Context。 |
| E02 | 微任务策略参考 V8：auto / explicit / scoped，默认 auto，在最外层 JS 调用退出时检查，不在每次嵌套返回时执行。 | 已确定方向，具体入口待当前代码 review。 |
| E03 | 普通作业异常交给宿主处理，之后自动继续下一项。 | 已确定；不可把执行终止或无法安全继续的故障当作普通异常直接继续。 |
| E04 | 正常 checkpoint 执行到队列为空，包括执行期间新入队任务，不用任务数量截断后宣称完成。 | 已确定；失控任务链通过独立执行终止机制处理。 |
| E05 | 允许宿主从其他线程请求终止当前 JS，终止结果回到宿主，不杀进程或 OS 线程。 | 已确定；不能承诺打断阻塞中的宿主函数。 |
| E06 | 终止后允许恢复执行能力、复用 Runtime，业务状态是否适合继续由宿主判断。 | 已确定；不回滚已发生的修改，不恢复已退出调用的断点。V8 CancelTerminateExecution 甚至允许栈尚未完全退栈，不能把简化使用流程误称为 V8 唯一语义。 |
| E07 | 提供 RequestInterrupt 类能力：跨线程请求执行线程回调，正常返回继续 JS。 | 已确定；回调不得重入被中断 Runtime 执行 JS，不承诺立即响应。 |
| E08 | 执行超时由宿主计时、制定策略，再请求终止。 | 已确定；Runtime 不内置 timeout_ms 策略。上层封装须防止旧计时器误终止后续执行。 |
| E09 | 提供默认原生栈保护，允许宿主设置线程对应的边界。 | 已确定；线程迁移必须使用新线程边界。 |
| E10 | 堆上的活动调用帧另设可配置执行栈字节预算，嵌套/重入共享，达到预算报栈溢出 RangeError。 | 已确定；按 zjs 实际帧布局评估计量，不能直接保留 QuickJS 估算口径。 |
| E11 | 不增加独立的最大调用层数配置，资源保护由原生栈边界及执行栈字节预算承担。 | 已确定；预算须覆盖每帧管理开销，覆盖完整前不移除旧保护；用于重入判断等深度计数保留。 |

E10/E11 当前证据：[vm_opcodes.zig](../../src/exec/vm_opcodes.zig) 的
`maxNativeJsCallDepth` 使用 `stackLimit()/16384`，`maxLogicalJsCallDepth` 直接返回
`stackLimit()`；`admissionCeilingsReject` 又将累计估算帧字节与原生栈地址边界结合。
因此当前实现尚不是已经解耦的两套字节预算，不能把目标设计当作现状。

参考：[V8 微任务策略](https://raw.githubusercontent.com/v8/v8/main/include/v8-microtask.h)、
[微任务队列](https://raw.githubusercontent.com/v8/v8/main/include/v8-microtask-queue.h)、
[执行控制与栈边界](https://raw.githubusercontent.com/v8/v8/main/include/v8-isolate.h)、
[Ignition 栈帧机制说明](https://v8.dev/blog/sparkplug#interpreter-compatible-frames)。

## 模块加载

| 编号 | 问题、场景与结论 | 状态／尚缺工作 |
| --- | --- | --- |
| L01 | 模块身份、查找规则与内容来源由宿主决定；引擎提供编译、链接、执行语义。 | 已确定；CLI 文件、游戏资源包和内存加载可采用不同规则。 |
| L02 | 随引擎提供可选的默认文件加载器。 | 已确定方向；宿主负责加载不等于每个嵌入者都从零实现。文件系统规则不放入 JSRuntime。 |
| L03 | 默认加载器按 Context/Realm 隔离模块实例，同一环境按模块身份复用；Runtime 不强制同名模块跨 Context 共用可变状态。 | 已确定；源码或编译缓存可单独复用，缓存键细节未决定。 |
| L04 | 支持异步获取模块，也允许立即完成；I/O 与调度由宿主负责。 | 已确定方向。 |
| L05 | 动态 import 采用 V8 式宿主组织流程：获取模块，调用引擎编译/实例化/执行接口，按结果兑现或拒绝导入 Promise。 | 已确定，用户否决了“宿主交回模块后由引擎组织整个导入”的建议。循环依赖、绑定与顶层 await 的语义仍由引擎实现。 |
| L06 | import.meta 由引擎创建、保存，首次访问时调用宿主填充，后续复用对象。 | 已确定；url、main、resolve 等环境属性由宿主/默认加载器决定。 |
| L07 | 支持宿主直接创建模块、声明导出名称并设置 JS 导出值，无需生成包装源码。 | 已确定方向；参考 V8 SyntheticModule，可用于原生 API 或配置。名称到实例的解析仍由宿主决定。 |

对比证据：

- [QuickJS 接口](https://github.com/bellard/quickjs/blob/master/quickjs.h) 提供归一化与加载回调；
  [quickjs-libc.c](https://github.com/bellard/quickjs/blob/master/quickjs-libc.c) 提供文件加载实现。
  [quickjs.c](https://github.com/bellard/quickjs/blob/master/quickjs.c) 的 loaded_modules 属于 JSContext。
- [SpiderMonkey Modules.h](https://searchfox.org/firefox-main/source/js/public/Modules.h)
  提供 ModuleLoadHook / FinishLoadingImportedModule，宿主决定加载与复用，须遵守身份一致性。
  SpiderMonkey JSContext 不等价于这里的独立全局环境，应对照 Realm/global。
- JavaScriptCore 的 [JSGlobalObject](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/runtime/JSGlobalObject.cpp)
  拥有自己的 [JSModuleLoader](https://github.com/WebKit/WebKit/blob/main/Source/JavaScriptCore/runtime/JSModuleLoader.cpp)；
  [WebCore ScriptModuleLoader](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/bindings/js/ScriptModuleLoader.cpp)
  和 shell 提供环境加载规则。这是内部 C++ 接入机制，不等于公开稳定 C API。
- [V8 Module 接口](https://raw.githubusercontent.com/v8/v8/main/include/v8-script.h)、
  [动态导入与 import.meta 回调](https://raw.githubusercontent.com/v8/v8/main/include/v8-callbacks.h)。
  静态链接回调同步返回模块，异步获取依赖需由宿主提前组织。

## 宿主通知与观测能力

以下记录已经接受的能力边界，不自动展开为当前优化任务。

| 编号 | 问题、场景与结论 | 状态／尚缺工作 |
| --- | --- | --- |
| O01 | 通知 Promise“拒绝时没有处理器”以及“拒绝后添加处理器”；由宿主决定报告时机与处置。 | 已确定；避免把暂时没有 handler 立即等同于最终未处理错误。 |
| O02 | 提供 Promise 生命周期 hook，默认关闭，用于异步追踪。 | 已确定方向；init、resolve、before、after 参考 V8；resolve 通知不等于最终 settled。开启成本需测量。 |
| O03 | 提供随 Promise/await 后续执行保存、恢复宿主上下文数据的能力，用于请求 ID 与日志关联。 | 已确定方向；宿主定时器与 I/O 需要主动接入，不是 Runtime 单个数据槽；会增加持有数据及其引用的生命周期。 |
| O04 | 提供 GC 前后回调，默认不注册，可按类型过滤；不执行 JS，并避免回调递归通知。 | 已确定方向；参考 V8 允许分配的约束；未来增量/并发阶段必须明确，回调时间差不能直接当作全部 GC 暂停。 |
| O05 | 提供 none / moderate / critical 内存压力通知，宿主判断进程或系统压力，Runtime 调整回收策略。 | 已确定方向；不改变堆上限，不保证释放指定字节，允许跨线程通知；更积极回收有 CPU/延迟成本。 |

参考：[V8 Promise hooks 与拒绝事件](https://raw.githubusercontent.com/v8/v8/main/include/v8-promise.h)、
[上下文传递、GC 通知与内存压力](https://raw.githubusercontent.com/v8/v8/main/include/v8-isolate.h)。

## 调度平台讨论与后续收敛

用户在讨论全局初始化后明确要求“zjs 暂时不用这么复杂”。以下以此为最新裁决。

| 编号 | 原讨论内容 | 当前状态 |
| --- | --- | --- |
| P01 | 可选 idle task，宿主给截止时间，引擎执行可分段维护；必要 GC 不依赖空闲时间。 | 暂缓：当前不新增空闲任务接入抽象。 |
| P02 | Runtime 产生维护任务，默认调度器或宿主调度器执行；微任务仍遵守 checkpoint。 | 暂缓：当前不引入可替换调度平台。 |
| P03 | 销毁参考 V8，取消未开始的引擎任务，等待仍访问 Runtime 的后台工作退出；调度器释放其持有任务对象，不排空整个宿主事件循环。 | 保留生命周期原则；若涉及现有后台工作需审计，不能据此新增任务管理框架。 |
| P04 | 后台线程池归可共享平台，多 Runtime 共用；不随单个 Runtime 销毁而关闭共享池。 | 暂缓：当前不引入共享线程池抽象，哪些工作值得后台执行也未确定。 |
| P05 | 支持不创建引擎后台线程的运行方式，必要工作在执行线程完成。 | 已接受的能力方向；不为此预先引入平台层或新模式切换框架。默认后台策略未选型。 |
| P06 | 曾建议 create(options) 隐式默认平台，或宿主显式传入平台，避免强制进程级初始化。 | 被收敛：当前不引入独立 Platform、全局初始化流程或隐式全局平台方案。 |

P06 讨论中的分析保留：

- V8 的全局初始化处理真实的进程级平台、配置、CPU 能力及按配置启用的共享设施，
  不是纯粹 API 惯例；[初始化源码](https://raw.githubusercontent.com/v8/v8/main/src/init/v8.cc)。
- 单一 Runtime create 入口并不排斥独立平台对象，两者是不同生命周期。
- 显式平台可让宿主决定共享范围；隐式默认平台则仍需解决首次配置、并发初始化、失败、最后释放和库卸载。
- 当前 zjs 已存在进程级默认标准库安装回调、nursery_enabled 等状态，尚未完成全局资源审计，
  不能声称已经无全局依赖，也不能据此预先建设完整平台层。
- 当前结论是维持简单 create/destroy；未来有具体需求和成本证据时再讨论共享资源抽象。

参考：[V8 平台与任务接口](https://raw.githubusercontent.com/v8/v8/main/include/v8-platform.h)、
[默认/单线程平台](https://raw.githubusercontent.com/v8/v8/main/include/libplatform/libplatform.h)、
[Isolate Deinit 的取消与等待](https://chromium.googlesource.com/v8/v8/+/refs/heads/main/src/execution/isolate.cc)。
V8 默认平台还有 NotifyIsolateShutdown 集成要求；任务对象所有权和 Runtime 资源释放是不同责任。

## 下一步与记录规则

当前焦点是 **JSRuntime 的字段和方法是否必要、归属是否合理、是否重复**。
用户再次指出讨论滑向微任务细节和队列算法；R28 已同意保留，队列内部不再展开。
按清单分批审计 Runtime 结构问题，只有判断归属所需时才深入子系统。
R04 缺陷证据及未决事项保留，不让缺陷修复、子系统算法或宿主 API 扩展接管主线。

后续每次讨论更新对应编号：补充当前证据、候选改法、用户结论和验证状态。
用户最新要求改为先列完整清单，后续自行推进 review，仅拿不准的取舍再询问。
这取代此前每轮展开一个新问题的节奏；新建议与用户已确认结论仍需区分，源码实施另行授权。
发现旧结论不准确时在原条目更正并说明，不把被否决方案留作活动实施任务。
只有实际修改与验证完成后才记录“已实现”，需要性能数据时链接可复核测量结果。

2026-09-22 已完成一批[生命周期与所有权审计](history.md#archive-lifecycle-ownership)：
保留执行状态、Context 构造/发布成员索引及 Atomics 唤醒信号；根、缓存和绑定可按责任封装。
native_entry_epoch 无读取方，列为删除候选。创建按已初始化步骤回滚，销毁遵循 GC/清理/共享表依赖，
不能机械逆序。以上是审计建议，未修改源码；其余待查项继续见清单。

2026-09-22 第二批：[JSRuntime 字段与方法收敛](history.md#archive-runtime-surface)。
GC 驱动与弱引用登记实现移入责任模块，Runtime 保留执行边界协调；WeakRef 保活清理由 checkpoint 控制。
建议合并同义 GC/持久句柄入口，消解 RuntimeCompactState，将无 Runtime 依赖的对象查询归还 Object。
回溯是执行错误状态，profiler 是可选诊断，分别保留其责任。本批均为审计建议，尚未实施。

2026-09-22 第三批：[初始化接线与注册入口](history.md#archive-bootstrap-registration)。
建议内置实现统一接线，Context 明确承担 global 绑定和安装回滚，Runtime 不按成员顺序猜测目标。
类型注册沿用单一入口；局部编号迁移必须补齐绑定/对象所属 Runtime 验证。
公开 Runtime 当前直接别名 core 类型，组装接线方式和高效对象归属验证仍需实施前核对；未修改源码。

2026-09-22 第四批：[宿主配置、统计与执行控制](history.md#archive-host-statistics)。
常规统计由 Runtime 汇总快照，移出全堆诊断及系统文件采样；保留宿主外部内存报告，
内部 Untracked 分类转发归 GC。动态 import 作用域、栈限制、中断和阻塞许可有实际职责，保留。
只读方法建议使用 *const JSRuntime，保持稳定身份语义；不据此宣称性能收益。未修改源码。

2026-09-22 第五批：[剩余状态与整体结构](history.md#archive-remaining-state)。
属性描述池、对象附属 iterator next 状态分别归属内部模块，不与强根字符串缓存混合；
保留原生活动调用与栈派生配置，slots2_payload_attach_count 无读取方列为删除候选。
整体收敛为 Runtime 管理实例与执行、持有子系统、保留协调入口；不以指针化或大杂项结构代替职责划分。
组装入口、类型归属验证和原有性能/接口未决项仍保留。未修改源码。

2026-09-22 第六批：[创建配置审计](history.md#archive-options)。
gc_threshold 当前混用初始配置与动态状态，Context bootstrap 还保存/恢复它；建议明确初始阈值，
之后归 GC 管理，移除 Context 干预。Options 仅作为创建输入，保留有实际用途的 setter。
gc_policy 的资源策略与内部调优分开评估，trace_writer 保留诊断能力但不重建 MemoryAccount。未实施。

<a id="archive-runtime-review-checklist"></a>

---

原路径：`docs/runtime-review-checklist.md`

# JSRuntime 结构 review 清单

**当前主入口：[JSRuntime 目标设计与现状对照](../runtime-target-design.md)。**
用户最新要求先形成完整目标再比较现状；本清单保留审计依据，不再作为逐字段讨论队列。
目标文档 §5 给出当前各组状态的完整去向，§7 给出实施顺序和剩余决策。

更新：2026-09-22。范围：当前 src/core/runtime.zig 的职责、状态和接口归属。
本轮仅 review 与文档；未修改源码。用户要求先给清单，自行核对可判断事项，
仅对未能从代码和既有结论解决的取舍提问，不再逐项确认。
详细裁决及证据见 [讨论记录](history.md#archive-runtime-design-review)。
首批已核对：[生命周期与所有权](history.md#archive-lifecycle-ownership)。下表“已审建议”仍不代表已实施。
第二批：[JSRuntime 字段与方法收敛](history.md#archive-runtime-surface)。
第三批：[初始化接线与注册入口](history.md#archive-bootstrap-registration)。
第四批：[宿主配置、统计与执行控制](history.md#archive-host-statistics)。
第五批：[剩余状态与整体结构](history.md#archive-remaining-state)。
第六批：[创建配置](history.md#archive-options)。

“已定”指用户已确认设计；“建议”指可继续审计的推荐处理，非已获实施授权；
“待查”指尚需调用链/生命周期证据或测量，不默认需要用户答题。
封装子系统不要求新增独立堆分配，不承诺降低 sizeof 或改善性能。

## 已确定的结构调整

| 项 | 处理 | 记录 |
| --- | --- | --- |
| Runtime 生命周期 | 稳定堆地址，单一 create/destroy；取消原地公开入口和双所有权模式 | R02–R03 |
| MemoryAccount | 删除独立账户抽象，按职责分配现有能力 | M01、R03 |
| 普通原生分配 | Runtime 持有标准 allocator，删除同义泛型包装；默认不额外经过通用 slab | R05、R07 |
| parser 临时 allocator | 编译操作持有 arena，不替换 Runtime allocator | R06 |
| GC 分配及回调桥接 | 存储路由归 GC，取消账户回调绕回 Runtime；保留安全边界 | R08–R09 |
| 统计与限额 | 不重建原生分配统一总账；明确统计口径，取消固定对象尺寸推算；常规查询不扫全堆 | R10–R12 |
| 类型注册 | 注册时分配编号并返回绑定；定义保留至 Runtime 销毁，布局/回调固定 | R15–R17 |
| 类型表线程与初始化 | 所属线程以 Runtime 为权威；类型表只保留原地初始化 | R18–R19 |
| 微任务 | Runtime.runMicrotasks；宿主事件归 EventLoop；入口不接收 Writer | R20–R25 |
| 错误传播 | 普通异常与终止/OOM 分开处理，不因已有异常或拒绝状态吞掉执行失败 | E03、R27 |
| 微任务队列存储 | 保留当前基本 FIFO 存储，不顺带重写算法 | R28 |
| 弱对象身份 | 两张弱身份表、编号及操作归 GC 子系统 | R29 |
| GC 诊断 | gc_mark_footprint 归独立诊断状态，避免扰动热布局 | R30 |
| 延迟清理 | 队列及配套状态/操作封装，Runtime 协调执行与销毁时机 | R31 |
| 当前异常 | ExceptionState 统一管理异常值及标志，仍属于 Runtime | R32 |

## 剩余结构项与建议

| 项 | 当前字段/方法 | 推荐处理 | 状态 |
| --- | --- | --- | --- |
| 类型编号 | 全局 ClassId、classes、newClassId | 简单候选用 Runtime 局部编号，暂不建全局身份映射；核对跨 Runtime 绑定误用和现有调用 | 已查：现有 create/unwrap 未充分验证归属；局部编号仍待高效对象归属验证方案 |
| 类型表命名 | initInPlace | 单一入口改名 init，与 deinit 配对 | 建议：R19 命名补充 |
| 内置初始化 | 全局默认 installer、Runtime 回调、Context 补接 | 创建时由引擎组装层统一接线，保留 core/exec 边界，取消可变全局默认注册 | 已审建议：统一接线；Context 明确负责 global 安装事务，组装入口实现待查 |
| 执行热状态 | hot、active_invocation、vm_stack、栈预算 | 保留 Runtime 级共享执行状态与热布局；不按 Context 重复，不为拆文件强制搬字段 | 已审建议：保留所有权与热布局 |
| 执行层私有状态 | host_invocation/retire、small_inline_* | 生命周期仍由 Runtime 协调，实现在 exec；核对哪些 hook 与状态可成组管理 | 已审建议：保留驻留/活动区别及 trace/销毁接口 |
| Context 成员管理 | context_head/tail、constructing_context_head/tail | Runtime 负责成员管理；构造中与已发布链表暂保留区别 | 已审建议：两组成员索引保留，不作为保活根 |
| 根与句柄 | root_providers、各类 root_slots、active_value_roots | 相关操作由内部根/句柄模块管理，Runtime 保留宿主入口与执行协调 | 已审建议：封装存储，Runtime 汇总各来源根 |
| 弱引用其他状态 | borrowed_reference_holders、weak_reference_holder_*、weakref_kept_alive、borrowed_weak_cleanup_* | 与 GC 弱处理职责一起审计，保活清理时机遵循 R23；避免遗漏根 | 已审建议：GC 弱处理与借用引用清理分开；任务保活由 Runtime 协调 |
| GC 调度状态 | malloc_gc_threshold、gc_running、poll/forceGC | 核对与 gc.Registry.scheduler 的边界；GC 策略归 GC，执行安全点由 Runtime 协调 | 已审建议：驱动/阈值归 GC，安全点和清理协调留 Runtime；不合并重入守卫 |
| atom 与 shape | atoms、shapes、相关便捷方法 | 保留 Runtime 级共享子系统；审计 Runtime 是否有无必要的转发接口 | 建议保留所有权 |
| 字符串缓存 | single_byte/empty/recent/percent_hex/small_int 字符串字段及方法 | 可封装为一个 Runtime 所有的缓存模块；先保留现有策略与根追踪 | 已审建议：状态、trace 和清理一起封装；保留策略 |
| 原生函数绑定 | native_entries、native_entry_finalizers、native_entry_epoch | 注册、退休和销毁归内部绑定模块，Runtime 持有并协调 teardown | 已审建议：epoch 无读取方，列删除候选；保留退休标记 |
| 动态 import | dynamic_import_loader 及作用域安装接口 | 保留 Runtime 级宿主回调配置；路径和 I/O 策略仍由宿主负责 | 已审建议：保留回调与作用域恢复，配套状态根由执行模块管理 |
| 完成通知 | host_completion_event、signal/reset/wait* | 核对跨线程生产者、Atomics 和 EventLoop 依赖，再决定归属 | 已审建议：保留 Runtime 唤醒信号，维持锁内 reset 协议 |
| 宿主执行控制 | interrupt_handler/context、can_block | 保留 Runtime 配置；不要把超时计时器塞进 Runtime | 已审建议：保留执行控制；setter 遵守线程契约，跨线程 signal 单独处理 |
| 诊断和宿主功能 | opcode_profile、performance_time_origin_ms、backtrace 等 | 分别按诊断、宿主 API、执行错误状态审计，避免混成一个杂项模块 | 已审建议：时间原点、可选 profiler、回溯各自保留职责 |

## 第二批新增精简候选

- `forceMajorGC` 合入 `forceGC`；其他收集入口的扫描及错误契约不能机械合并。
- 强持久句柄统一为 `createPersistentValue`；当前 create/take 已无实现差异，同步清理旧所有权描述。
- `borrowedReferenceHolderRegistered` 是纯 Object 查询，移出 Runtime。
- `RuntimeCompactState` 随本体所有权标志删除、缓存索引归位而消解。
- 上述为设计建议；调用点、公开 API 及文档迁移在实施阶段处理。

## 第四批新增收敛项

- 常规统计保留 Runtime 汇总，详细遍历归诊断，Linux 文件采样归内部系统采样模块。
- 保留宿主外部内存报告；内部 Untracked 分类转发移出 Runtime。
- 只读 Runtime 方法统一采用 `*const JSRuntime`，不宣称已有性能收益。

## 不在本轮结构 review 中提前决定

第六批建议：gc_threshold 明确为初始触发阈值，后续归 GC，取消 Context 创建的保存/恢复。
创建选项不作为另一份状态镜像；gc_policy 区分公开资源策略与内部调优，trace_writer 归诊断配置。
具体公开字段集合及旧调用迁移仍需核对；以上尚未实施。

第五批补齐：auto_init_descriptors 归内部属性描述池，cached_iterator_next_entries 归对象附属状态；
两者仍由 Runtime 管理存储生命周期。保留 active_native_call、vm_stack_arena_policy 和 collectionEpoch 的实际职责。
slots2_payload_attach_count 没有读取方，新增删除候选；源码中错位注释随未来实施清理。

- c_allocator 与 smp_allocator 的选型、通用 slab 的收益：保留既有性能 TODO。
- nursery、block heap、队列及缓存的内部算法：没有具体证据不顺带重写。
- 类型映射的具体容器、ID 复用策略：先完成局部编号及绑定生命周期审计。
- 普通微任务异常报告接口 R26：能力方向已确认，回调形式及未安装回调时的行为尚未定案。
- R04 初始化缺陷：保留已有复现，放入未来实施的正确性工作，不接管结构 review。

## 推进顺序

1. 先审计创建/销毁与子系统所有权，产出稳定的 Runtime 组成。
2. 再审计根、执行状态和宿主边界，确认依赖方向与保留的接口。
3. 汇总真正未决的取舍后集中询问；不把每个字段搬迁都变成用户确认题。
4. 得到源码实施授权后再拆最小变更与验证；当前没有实施、提交或测试通过的声明。

<a id="archive-lifecycle-ownership"></a>

---

原路径：`docs/runtime-review/lifecycle-ownership.md`

# JSRuntime 生命周期与所有权审计

日期：2026-09-22。仅审计当前源码、记录建议，未实施、未提交。
沿用[已确认设计](history.md#archive-runtime-design-review)，新审计结论不冒充用户已确认项。
本批对应[结构清单](history.md#archive-runtime-review-checklist)的创建/销毁、执行、成员、根及绑定。

## 结构结论

| 组成 | 审计建议 | 当前源码依据 |
| --- | --- | --- |
| 执行热状态、VM 栈 | 保留 Runtime 所有；不按 Context 复制，不为模块拆分搬动热布局 | runtime.zig 的 HotExecState、vm_stack；call_site.zig 的 publish/unpublish 会设置 active_invocation 和回溯链 |
| host_invocation | 保留 Runtime 所有、exec 实现及销毁 hook；与 active_invocation 不重复 | call_site.zig acquire 缓存驻留执行器，publish 仅在一次调用期间发布活动入口；Runtime deinit 先 retire 再释放 VM 栈 |
| small_inline 状态和 hook | 保留预算、trace 和 destroy 职责；以后可成组封装，不能直接删 hook | small_inline.zig 安装 hook，function_bytecode.zig 使用销毁入口，gc_trace_stw.zig 使用 atom trace 入口 |
| Context 两组链表 | 保留构造中/已发布区别，仍由 Runtime 管理成员关系 | context.zig 的初始化失败路径摘除构造链；publishLive 在唯一可失败步骤成功后换链；runtime.zig 提供区分构造态的查询 |
| 根与句柄 | 存储及操作可封装；Runtime 汇总执行根与子系统根，GC 消费根 | runtime.zig traceRoots/traceActiveRoots 涵盖句柄、异常、清理任务、微任务、缓存、活动调用等不同来源 |
| 字符串缓存 | 可封装缓存状态、操作、trace、清空；保留 Runtime 生命周期和当前策略 | traceStringCacheRoots 与 deinit 同时枚举这些缓存；仅搬字段会遗漏根或清理 |
| 原生绑定 | 封装注册、退休、原生清理及销毁；保留退休标记，删除无消费者的 epoch 是明确候选 | native_entry_epoch 在 src/tests 中只有声明、初始化、递增；retireNativeEntry 另行设置 entry.kind = retired |
| Atomics 完成信号 | 暂留 Runtime；不能随宿主事件循环机械迁走 | atomics_ops.zig 在 waiter 锁内 reset，解锁后 wait，通知方 signal 对应 Runtime；这是跨线程唤醒协议 |
| performance 时间原点 | 保留现有 Runtime 级共享状态，不当成闲置字段删除 | object.zig 初始化并暴露 timeOrigin；builtin_glue.zig 的 performance.now 读取它 |

Context 链表是借用的成员索引，不是保活根，也不是 Runtime 逐项 destroy Context 的所有权清单。
当前构造过程另外注册 root provider，发布过程保留该保活责任。
不建议为了少两个指针而合并状态；这会让原本只遍历已发布 Context 的调用承担额外过滤责任。

根封装也不意味着所有根都搬进 GC：栈上的 ValueRootFrame 和活动调用具有执行作用域，
字符串缓存、异常、微任务和延迟清理各自负责报告其持有值。Runtime 负责汇总。
内部模块可以直接内嵌，不要求每个模块独立堆分配，不据此声称内存或性能改善。

## 创建约束

沿用 R02–R03：先分配 Runtime 本体，在最终地址初始化子系统，只公开 create/destroy。
当前 initWithAccount 中 allocator facade、GC observer、AtomTable、Shape Registry
都建立指向 Runtime 或其字段的引用，证明稳定地址是实际依赖。

替换构造路径时，每个可失败步骤只回滚已经初始化的资源；不能对半初始化 Runtime 调用完整 destroy。
应在各步骤成功时建立局部回滚责任，最终成功后才对外发布 Runtime。
这属于未来实现约束；本轮没有对所有 OOM 分支做故障注入，也不声称现有路径全部正确。

## 销毁约束

当前 runtime.zig deinit（审计时第 1707 行起）显示，销毁不能简单等于初始化逆序：

1. 在所属线程且执行空闲时，先退役驻留执行器，再释放 VM 栈等执行资源。
2. 撤销异常、缓存和待执行任务等保活来源，处理原生清理；宿主应已释放其句柄和 Realm 引用。
3. GC 回收与延迟原生清理交错进行。类型定义、atom 和相关清理设施仍须有效。
4. 最后释放已经不再被使用的表、容器和 Runtime 本体。

这是依赖约束，不是已验证的新销毁算法。保留当前阶段间具体清理要求，实施时再逐步收敛。
尤其不能删掉看似重复的 job_queue.deinit：前面的 GC 会因 FinalizationRegistry 再次入队，
清空任务后还需要释放重新增长的队列存储。销毁不应因此开始执行 JS 清理回调。

当前还区分 GC 前释放普通 atom 字符串缓存、GC 后释放动态 symbol bodies，再销毁 AtomTable；
动态 symbol 与 shape 中的 property-key atom 生命周期有关。不能提前销毁共享表。
未来移除 MemoryAccount 后，本体释放只需保存原始 allocator，不再复制账户完成销毁。

## 留给后续批次

- GC scheduler 与 Runtime 安全点的边界、其余弱状态的完整归属。
- Runtime 局部类型编号的跨 Runtime 误用防护、内置初始化接线。
- opcode_profile、回溯及转发接口的进一步精简；本批未据此决定删除接口。
- 微任务普通异常的具体宿主报告接口仍沿用 R26 未决状态，不影响本批所有权建议。

验证：只读源码/调用点核对；文档空白检查。未修改源码，未运行引擎测试或性能测量。

<a id="archive-runtime-surface"></a>

---

原路径：`docs/runtime-review/runtime-surface.md`

# JSRuntime 字段与方法收敛

2026-09-22。仅设计审计；以下是建议，未修改源码或公共 API。
本批重点是 JSRuntime 本身，不展开 GC 算法。参见[总清单](history.md#archive-runtime-review-checklist)。

## Runtime 留下什么

- 本体生命周期、allocator、所属线程，以及它拥有的子系统。
- 跨 Context 的执行状态、根汇总和 Context 成员管理。
- 宿主控制入口：栈/内存配置、终止与中断、微任务、句柄、显式 GC 等。
- 执行边界协调：何时允许收集、何时运行延迟清理、何时清除 WeakRef 保活集合。

不以“方法少”为唯一目标：封装内部实现后，不为每个搬走的方法再添加同名 Runtime 转发。
只保留确有宿主语义或跨子系统协调责任的入口；内部调用直接进入所属模块。
这里区分设计上的宿主 API 与 Zig 跨文件访问所需的 pub，不能机械删除所有 pub。

## 本批具体处理

| 当前字段/方法 | 建议 | 源码依据与边界 |
| --- | --- | --- |
| pollGC 的收集调度、resetGCThreshold、finishDoomedCompletion | 实现归 GC；Runtime 保留安全点和必要的清理协调 | runtime.zig:3077 起直接控制 minor/major、阈值、销毁续作及统计，并非单纯转发 |
| malloc_gc_threshold、gc_running | 随 GC 驱动状态归 GC；Runtime 保留配置入口 | threshold 当前基于 MemoryAccount.allocated_bytes，需随既定统计口径调整，不能只搬名；gc_running 与 gc.hot.phase 两个检查不能未经证明合并 |
| weak_reference_holder_head/tail 及登记方法 | GC 弱处理模块负责 | runtime.zig:1976 起维护侵入链；gc_trace_stw.zig 消费该链；对象死亡时摘链 |
| borrowed_reference_holders、borrowed_weak_cleanup_* 及操作 | 内部对象生命周期模块负责，不继续铺在 Runtime 上 | object.zig:2884 起处理销毁 global 后的借用引用清理；它与 WeakRef holder 链用途不同，不能合并为一张表 |
| weakref_kept_alive | Runtime 所有的任务保活状态；边界清理由 Runtime 协调 | traceRoots 把它作为强根；清空时机沿用 R23 的 checkpoint 决议，不能交由任意 GC 周期清空 |
| formatting_error_stack、backtrace_frames/capacity | 作为 Runtime 的回溯状态封装；不作为可关闭诊断整体移除 | context.zig 捕获/维护帧，exception_ops.zig 使用格式化重入标志；活跃回溯链仍留 HotExecState |
| opcode_profile | 保留借用的可选 profiler 指针及安装入口 | exec/tailcall_dispatch.zig、vm_property.zig 读取；setOpcodeProfile 同时连接分配计数，移除 MemoryAccount 时需要迁移该连接 |
| RuntimeCompactState | 随既定调整消解，不保留杂项状态袋 | 只有 owns_self_allocation 和 recent_atom_string_next 两项；前者随单一 create/destroy 删除，后者归字符串缓存 |

GC 迁移的边界：线程检查、执行根准备及回调清理顺序仍需要 Runtime 协调。
afterCallbackBoundaryGC / beforeEventLoopIdleGC 不仅调用 pollGC，还执行有预算的延迟清理，
不能按“简单转发”删除。gc_running 在 gc_trace_stw.zig 的回调边界也被保存/恢复，迁移必须覆盖这些访问。

## 可精简的接口

1. **forceMajorGC / forceGC**：前者完全转发后者（runtime.zig:3345）。建议保留 forceGC 一个名称，
   在实施时迁移 parser 和测试调用。不能把它与 runObjectCycleRemoval 直接合并：后者采用 declared_only
   根扫描且旧包装会吞掉 CollectionError，两者当前契约不同。后续入口收敛必须明确扫描与错误语义。
2. **createPersistentValue / createValueHandle / takeValueHandle**：前者直接转发 createValueHandle，
   后两者分别调用 initDup/init，但 initDup 当前也直接调用 init（runtime.zig:970–987、2906–2916）。
   建议强持久句柄只保留 createPersistentValue，与 createWeakPersistentValue 对应；不继续保留没有实现差异的
   create/take 两种入口。迁移需同时更正文档中的“复制/接管”旧描述，不改变根的注册/释放责任。
3. **borrowedReferenceHolderRegistered**：忽略 self，只读取 Object 标志（runtime.zig:2039）。
   建议变为对象查询，调用者无需为了读取一个对象属性经过 Runtime。
4. **internAtom / symbolValue 等**：转发本身不构成删除理由。internAtom 是直接表操作，
   newSymbolValue 则包含创建失败清理；先保留现有能力，不统一按一行函数批量删除。

以上涉及已有公开名称，当前只是设计候选；源码实施时需要同步迁移调用和 API 文档，不能声称兼容性不变。
本批无需用户补充选择。类型编号及引擎组装接线仍待后续审计，不扩展新机制。

验证：核对当前定义及 src/tests 调用点；文档空白检查。未运行引擎测试或性能测量。

<a id="archive-bootstrap-registration"></a>

---

原路径：`docs/runtime-review/bootstrap-registration.md`

# JSRuntime 初始化接线与注册入口

2026-09-22。仅审计与设计建议，未修改源码、公共 API 或测试。
承接 R14–R15、R33；重点是 Runtime 的职责，不设计新的平台或绑定框架。

## 内置初始化：配置一次，按 Context 安装

当前有四处接线：

- runtime.zig 的 initWithAccount 复制进程全局默认 installer 与容量。
- exec/standard_globals.zig 的 configureRuntime 同时修改全局默认值和当前 Runtime。
- js_context.zig 的 ensureStandardGlobalsRegistered 在多个入口补齐回调。
- standard_globals.installStandardGlobals 再调用 configureRuntime，并设置 namespace materializer 和 internal_builtins。

这些地方共同建立同一组引擎内部依赖。建议在引擎创建流程统一配置一次：
installer、global/namespace materializer、静态 builtin 表和容量信息作为一组内部配置保持一致。
这不是新增宿主配置项；宿主仍使用单一 create 入口，不需要理解 core/exec 接线。
保留 core 不依赖 exec 的分层，按需创建内置对象的策略不变。

当前 root.zig 的 Runtime/JSRuntime 都直接别名到 core.JSRuntime，
因此实施时必须明确组装入口如何接入该公开类型，不能只删除全局变量就声称创建路径完成。
core-only 测试所需的内部构造仍可保留，但不能变成第二套公开生命周期。
本轮不预先决定用包装类型还是构建期依赖注入；这是实施前仍需核对的模块接线问题。

## Runtime 不应猜测 global 属于哪个 Context

runtime.zig 的 installStandardGlobals 当前除调用 installer 外，还会：

1. 按 global 查 Context；
2. 找不到时，遍历已发布 Context，选择第一个 global 为空的 Context；
3. 将对象提升为 global，设置 ctx.global，失败时回滚该 Context 的 bootstrap。

因此这个方法实际上承担了 Realm 绑定和安装事务，并非 Runtime 级共享初始化。
建议由明确的 Context 作为安装目标，在 Context/exec 初始化流程中完成 global 绑定和失败回滚。
Runtime 保存共享配置；删除按链表顺序猜测目标的 fallback。
这不意味着发现了现有语义故障，而是调用方已有或应明确提供 Context 时，不必让 Runtime 再推断。

调用迁移必须覆盖 exec.call.installHostGlobals、标准库辅助创建流程和裸 core 测试。
宿主扩展 global 的能力保留，只要求绑定目标明确。
standardGlobalOwnPropertyCapacity 是安装实现的容量提示，不是宿主 Runtime 能力；
建议随内部配置使用，不再维持独立的宿主可见 Runtime 查询。容量优化本身不删除。

## 类型注册：保留一个 Runtime 入口

沿用已确认的 R15：注册定义并返回绑定，编号在 Runtime 内部产生。
newClassId 不再作为独立宿主步骤，固定内置编号初始化仍由类型表内部处理。
Context 原型槽扩容由注册流程协调，ensureContextClassPrototypeCapacity 不应要求宿主另行调用。

当前 native_object.NativeType 已有 owner 和 class_id；但 create(rt, native_type, ...)
直接使用编号，unwrap(value, class_id) 也只比较编号。因此局部编号迁移必须同步做到：

- 创建实例时检查绑定所属 Runtime 与目标 Runtime 相同；绑定保留至该 Runtime 销毁。
- 解包入口使用绑定和明确的 Runtime 来源，验证值所属 Runtime 后再比较编号；仅检查 binding.owner 不够。
- 不在每个 Runtime 中创建全局类型身份映射，不按名字猜测或合并类型。

这是必要契约，尚未选择对象归属验证的具体实现；不能为此直接给每个对象新增指针，
也不能默认在热路径扫描全堆。完成该核对前，局部编号方案仍是简单候选，不能标记实施就绪。
当前 NativeType 只服务特定 native_object 绑定，也不直接替代全部 class.Definition/Record。

## 对 JSRuntime 的结果

保留共享内置配置、类型表和一个宿主注册入口；移出 Context bootstrap 事务，
取消重复接线、全局默认 installer 和独立申请类型 ID 的宿主流程。
未决点是内部接线实现与高效归属验证，不需要用户再确认已确定的职责方向。

验证：核对 runtime、js_context、standard_globals、call、class、native_object 的定义和调用点；
文档空白检查。没有运行引擎测试，也未作性能结论。

<a id="archive-host-statistics"></a>

---

原路径：`docs/runtime-review/host-statistics.md`

# JSRuntime 宿主配置、统计与执行控制

2026-09-22。仅审计和设计建议，未修改源码。重点为 Runtime 的接口与职责边界。

## 统计保留入口，移出采样实现

runtime.zig 的 memoryUsage 遍历 atom 与 class 表；gcStats 调用 weakReferenceCount 遍历堆，
并通过 currentRssBytes/cgroupLimitBytes 读取 Linux 文件。它们不是单纯读取计数器。
沿用 R10–R12：Runtime 可以汇总统计，但常规查询不隐式做全堆分析或操作系统文件 I/O。

建议：

- 子系统提供已有、口径明确的计数快照，Runtime 负责组合；无法廉价提供的字段进入显式详细统计。
- weakReferenceCount 等遍历实现归详细诊断，不为了维持旧字段强制给所有分配增加计数操作。
- currentRssBytes、cgroupLimitBytes、readLinuxFile 及解析实现归内部系统内存采样模块。
  现有内存压力策略仍可按需调用它，不取消压力响应，也不新建宿主平台框架。
- 进程 RSS、cgroup 上限与单个 Runtime 的内存分开表述；未知/不可用不解释为真实的零。
- gcPauseDistribution 当前单独暴露会排序的统计，保留这种显式成本边界。

MemoryAccount 移除后，不继续承诺旧的原生分配统一计数；统计字段迁移遵循已定口径。
这里不对系统采样实现的完整性作背书，也不展开 cgroup 检测算法。

## 外部内存：区分宿主入口与内部分类

保留 reportExternalAlloc 的宿主能力：返回计账 token，并通知 GC 压力策略。
这不转移宿主缓冲区所有权，也不意味着由 Runtime 执行宿主资源释放。
token 的具体生命周期沿用现有契约，不能仅因精简 Runtime 而换成无约束的加减接口。

reportExternalAllocUntracked / reportExternalFreeUntracked 只是对 GC 的转发；
当前调用来自 object.zig、object_payloads.zig 的 inline buffer 分类。
建议内部调用直接进入 GC，移除 Runtime 上的这两个转发入口；不删除分类记账本身。
allocationDebtBytes 返回加权调度债务，不是实际内存用量，建议归 GC 调度统计，不混入内存使用量。

## 宿主配置和执行控制：保留有实际语义的入口

| 项目 | 结论及源码依据 |
| --- | --- |
| dynamic_import_loader | 保留 Runtime 级 callback/userdata；exec/module.zig 调用时传入活动 Context，路径/I/O 策略仍属于宿主 |
| DynamicImportLoaderScope | 保留按 LIFO 恢复的作用域；exec/module.zig 的 DynamicImportScope 还配套管理 loader 状态的根，不应当作重复 setter 删除 |
| 栈限制 | 保留 Runtime 配置及执行层的安全检查；setStackSize 同时调整 VM arena policy，不能替换为无约束的字段赋值 |
| updateNativeStackTop | 属于引擎进入执行时的内部职责，不要求宿主每次手动调用；实际执行线程的栈基准仍须正确维护 |
| interrupt_handler/context | 保留成对配置，hasInterruptHandler/runInterruptHandler 有 regexp、Context 等实际消费者；不引入超时计时器 |
| can_block | 保留 Runtime 的阻塞许可，与 Atomics 等执行能力相关 |

动态 import 作用域有明确的恢复和 root 生命周期；这与此前否决的 parser 临时替换通用 allocator
影响范围不同。保留作用域不等于证明任意异步操作都可越过它的生命周期；不得捕获失效的 userdata。

配置改变仍需遵守 Runtime 所属线程契约。实现阶段应核对 setter 的一致性；
host_completion_event 的跨线程 signal 是既有明确例外，不能一律增加 owner-thread 断言。

## 只读方法的接收者

gcThreshold、memoryLimit、stackSize、canBlock、hasInterruptHandler 等当前使用 self: JSRuntime。
建议统一为 *const JSRuntime：它们读取的是一个有稳定身份的 Runtime，不需要按值语义。
这使接口与不可随意复制的生命周期设计一致；不能据此声称当前编译产物实际复制了整个结构或已经提速。

验证：核对 runtime.zig 及 module、regexp、context、object/object_payloads 的调用点，检查文档空白。
未运行引擎测试或性能测量。以上新建议均未实施。

<a id="archive-remaining-state"></a>

---

原路径：`docs/runtime-review/remaining-state.md`

# JSRuntime 剩余状态与整体结构

2026-09-22。只读源码审计及设计建议，未实施。承接前四批，补查尚未明确归属的字段。

## 剩余字段

| 当前状态 | 建议 | 当前代码依据 |
| --- | --- | --- |
| auto_init_descriptors | Runtime 拥有的内部属性描述池；分配、去重、释放由同一模块管理 | property.zig:372 的 internAutoInit 分配稳定地址描述符；Runtime 在 GC 后逐个释放。描述符可引用当前 Runtime 的 NativeEntry，不能直接改成全局池 |
| cached_iterator_next_entries | 归对象附属状态管理；Runtime 只持有该内部存储的生命周期 | object.zig:2214 起负责查询、插入、移除；traceChildEdgesFallible 通过所属对象追踪值，对象销毁时移除条目。不是 NativeEntry 注册表，也不是无条件的 Runtime 强根 |
| slots2_payload_attach_count | 删除候选 | 当前仓库非文档代码仅有 Runtime 声明、初始化及 object.zig:2300 递增，没有读取方。保留 payload spill 行为，删除候选只是计数 |
| active_native_call | 保留 Runtime 执行状态 | builtin_dispatch.zig 保存/设置/恢复栈上的 NativeCallEnvironment，nativeCall 从中取回当前原生调用参数；与 active_invocation 的字节码执行入口并非同一状态 |
| vm_stack_arena_policy | 保留派生的执行配置，随栈配置维护 | 多个 inline_calls/call_runtime 入口直接使用；setStackSize 同步更新。虽然由 stack_size 派生，也不能仅为少一个字段就在每次调用重新计算 |
| collectionEpoch | 保留内部查询入口 | core/local.zig 通过这一接口校验借用值是否跨越收集；状态仍以 GC 为权威，不在 Runtime 复制一个 epoch |

cached_iterator_next_entries 保存已经取得的 next 方法，exec 的 iterator/collection 调用会读取它。
本批不判断其具体容器或优化算法；不能因名字有 cached 就直接删除或把值改成弱引用。
它和字符串缓存应分开：前者的边由所属对象报告，后者由 Runtime 报告强根。

Runtime 中另有错位的历史注释：performance_time_origin_ms 前描述预分配 OOM 对象，
cached_iterator_next_entries 前描述外部函数 dispatch record，atoms 前残留 GC pacing 描述。
未来实施时同步清理，以实际字段为准，不能据注释虚构缺失职责。本轮不改源码注释。

## 整体判断

JSRuntime 确实承担了过多实现细节，但大部分存储仍需要由引擎实例拥有。
目标不是让每个字段变成一个指针，也不是把所有冷字段装进一个没有明确责任的大结构。

建议以三条边界组织最终 Runtime：

1. **直接管理实例与执行**：allocator、所属线程、执行栈与热状态、活动调用、Context 成员、宿主配置。
2. **持有有明确责任的子系统**：GC、atom/shape、类型、根与句柄、微任务、异常/回溯、原生绑定、延迟清理、缓存和属性描述池。
3. **只保留协调入口**：创建/销毁、注册、宿主执行控制、微任务 checkpoint、GC 安全点与根汇总、统计汇总。

这个分类是职责图，不要求每项单独分配、不要求增加新层级，也不改变热布局。
对象附属表、内部 GC 操作等调用应转向责任模块，避免 Runtime 搬走实现后又保留整套同名转发。
测试入口按所属模块迁移，保留现有不变量验证，不因精简公开方法而删除测试。

可直接形成后续实施候选的是：无读取字段、重复入口、错误注释，以及已有明确生命周期的责任封装。
仍需设计/证据的是：组装入口接线、局部类型编号的对象归属验证、普通微任务异常报告接口、allocator 性能选型。
本批不把这些未决点标记完成，也不再为已清楚的字段归属要求逐项确认。

验证：当前字段定义、src/tests 消费者和对象 trace/销毁路径核对；文档空白检查。
未运行引擎测试、未测量结构大小或性能，未修改源码或提交。

<a id="archive-options"></a>

---

原路径：`docs/runtime-review/options.md`

# JSRuntime 创建配置审计

2026-09-22。设计建议，未实施。只审 RuntimeOptions 与 Runtime 状态的关系，不调整 GC 算法或参数。

## 具体问题：gc_threshold 同时被当作配置和运行状态

- RuntimeOptions.gc_threshold 初始化 malloc_gc_threshold。
- Runtime.resetGCThreshold 在收集后按当前用量自动更新同一个字段。
- js_context.zig 的 initWithOptionsImpl 保存 gcThreshold，在 Context bootstrap 后恢复旧值，注释将其解释为宿主配置。

这使 Context 创建介入了 Runtime 的 GC 状态管理。当前没有两份值，却同时赋予它固定配置与动态阈值两种含义。
本批不据此声称已复现性能或正确性缺陷。

**建议简单收敛**：创建选项表达初始触发阈值，后续动态阈值由 GC 拥有；Context 不再保存/恢复。
实现时可将创建选项明确命名为 initial_gc_threshold；不新增一份“固定阈值”来保留这个绕行。
如保留运行时 setGCThreshold，其语义是显式重设当前触发阈值，不保证之后 GC 不更新。
内存硬上限是另一种契约，不与 GC 触发阈值混用。按既有决定，统计基础会随 MemoryAccount 移除而迁移。

现有测试和宿主调用依赖旧名称及行为，实施时需逐个核对，不能直接删断言或机械替换名称。
如果确有“固定阈值”使用场景，再单独讨论；当前不预建第二种运行模式。

## 其余创建选项

| 选项 | 建议 |
| --- | --- |
| allocator | 沿用既定方向：可选宿主覆盖，放进 create 的 options；默认实现待性能比较 |
| memory_limit | 保留宿主能力；沿用已定 JS heap 口径，不能把旧 MemoryAccount 总账直接换名 |
| stack_size | 保留；创建与 setter 共享同一配置逻辑，保持 VM arena policy 一致，不让 Context 代管 |
| interrupt_handler/context | 保留回调与 userdata 配对配置；不因为有 setter 就删除创建选项 |
| can_block | 保留；创建给初值、setter 修改当前许可，两者不是重复入口 |
| gc_policy | 不把整个内部 gc.Policy 永久当作宿主选项类型；分清内存压力控制与内部调优参数 |
| trace_writer | 保留分配诊断用途，但从普通 Runtime 配置迁入明确的诊断配置；不是脚本输出 Writer |

gc.Policy 当前包含 large_object_threshold、native_cleanup_slice_jobs、external_weight、major_debt_threshold，
也包含外部内存、RSS 与 cgroup 压力控制。前者描述实现调优，后者表达资源策略，不能整包删除能力，
也不应让内部字段变化自动变成宿主 API 变化。建议先明确字段的公开级别，不新增平台或策略框架。
具体公开集合仍需与已有宿主调用对账，本批不宣称已完成公共配置类型设计。

trace_writer 当前由 CLI --trace-memory 路径接入 MemoryAccount 的 A/F 分配记录。
它与 runMicrotasks 不接收脚本输出 Writer 的 R25 不是同一问题。
移除 MemoryAccount 后，诊断需要重新明确覆盖的分配路径；不能承诺仍记录全引擎每笔分配。
本批不为了保留追踪重建独立账户抽象，也不直接移除 CLI 功能。

## 原则

Options 是创建时输入，不是另一份需要与 Runtime 同步保存的配置镜像。
初始化后，状态由对应子系统拥有；少量 setter 表达明确的运行时操作。
不把“创建选项 + setter”误判为两套生命周期入口，也不为每个内部可调字段添加宿主 setter。

验证：核对 RuntimeOptions、阈值更新、Context bootstrap、CLI trace 和 MemoryAccount trace 调用；
文档空白检查。未修改源码、测试或公共接口，未运行性能测量。
