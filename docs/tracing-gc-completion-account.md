# Tracing GC 完成对账（S0–S4 + T-R R3）

日期：2026-09-06（driver）。上游：`docs/tracing-gc-completion-plan.md`（v0.1，2026-09-03 owner 批 D1-D6）。执行记录分册：`tracing-gc-s2-spec.md` §7、`tracing-gc-s3-spec.md` §7、`tracing-gc-s4-spec.md` §7、完成计划 T-R 段。本页只对账，不复述细节。

## 1. 目标态达成表（对照计划 §2.1 所有权矩阵）

| kind | 计划 | 现状（main 3ff3f8d3） |
|---|---|---|
| object | 块 cell / 位图 / 位图 sweep，仅 `needs_finalizer` 走 finalizer | ✅ S4-d：普通对象死亡零析构（deletion-probe：5.49M 回收中 plain-object 析构调用 0） |
| string（flat / rope / symbol body） | 块 cell 或 extent，位图/表标记，无析构 | ✅ S2：flat/rope/symbol body 全入 tracer；只有绑定动态 atom 的 body 进 fin 集合做握手；rope 独立 kind（S4-a）；`s = s + x` 由 extensible 尾缓冲（kind 12）恢复均摊 O(1)（S2-i） |
| big_int | 块 cell / medium | ✅（S1） |
| property_storage / array_storage / payload（新 kind） | owner 边标记，位图 sweep | ✅ S4-b/c：kind 8/9/10，`createStorageCellPublished` 唯一漏斗，无析构；a 类 payload 与从属切片全入 cell；`slots2_payloads` 侧表消除 |
| shape / realm / module / FB / var_ref | 现状（非块），mark，保留析构 | ✅ S1；S3 后加 `visitAtom` 边 |
| atom 表 | S3 全弱化 | ✅ S3：`ref_count` 删除（`DynamicAtom` 80→72B），活性 = `visitAtom` 边 ∨ body 标记 ∨ `host_pins` ∨ 黑分配；`atoms.dup/free` 1,279+209 处删除；`CompileAtomScope`、`ValueRootFrame.atoms`、`JsonRecordRoots` 等根 |
| rc 归零 | `RefCountHeader/retain/release/JSValue.dup/free/DeferredFreeStack/Pass B` 全删 | ✅ `JSValue.dup/free` 与调用点（903/2966）在 owner 消融中删除；`RefCountHeader/StringHeader` 删（S2）；husk、Pass A/B、`DeferredFreeStack`、`weakref_count` 删（S4-e，−784 行） |
| 头部位 | `kind:u4 | young | needs_finalizer | finalizing | reserved` | ✅ S4-h：`kind:u4 | young | finalizing | needs_finalizer | reserved`（`mark`/`is_pinned`/`cycle_visited` 全删；condemn = `mark_epoch` 保留值 0xffff；byte 7 整字节空闲） |
| 根集 | R3 诊断 → R1 全精确 | ✅ R3 完成（归因普查，`.bss` 表，诊断构建与生产同布局）；R1-a 落地：六窗口中只有 regexp 匹配数组是真缺根（direct −7.8%）+ 一个真 bug（publishing-shape 根帧提前 deactivate），其余为栈残渣/callee-saved 溢出——**R1 不能按 R3 清单驱动**，需普查加残渣分辨列、eval 帧靠缩帧 |

## 2. 门（main f005aee7，S5 收官后）

| 门 | 读数 |
|---|---|
| `zig build test` | 2558/0（`-Dzjs_ownership_audit` 2559/0，预存红已修） |
| `test-gc-stress` | 2554/0 |
| `-Dzjs_gc_roots_diag` | 2562/0 |
| test262 script | 0/49778 |
| **`ZJS_GC_STRESS=1` test262** | **0/49778** |
| leak-census | 1570/0 |
| test-oom | 22/0（注入拓扑由 `-Dzjs_oom_injection` 显式开启，单测不再跑在发布版没有的分配器拓扑上） |
| test-stress | 6/0（Debug 与 ReleaseSafe） |
| 三个架构检查器 | 通过（此前基线就红） |

## 3. Stage 0 轨迹（对冻结基线 main-d944f26d，insn / cycles）

| workload | S2 翻开关 | S2-f | S2-i | S4 a–f | S4 收口 | **S4-i** | S5 收官 |
|---|---|---|---|---|---|---|---|
| pdfjs | 111.9 / 275.4 | 1.40 / 2.35 | 0.83 / 0.82 | 0.85 / 0.88 | 0.82 / 0.85 | **0.81 / 0.83** | 0.81 / 0.83 |
| splay | 1.17 / 1.29 | 1.21 / 1.34 | 1.22 / 1.33 | 1.33 / 1.36 | 1.22 / 1.32 | **1.17 / 1.26** | 1.17 / 1.26 |
| regexp | 1.20 / 1.47 | 0.99 / 0.99 | 0.99 / 1.01 | 0.99 / 1.03 | 0.98 / 1.01 | 0.98 / 1.02 | 0.98 / 0.99 |
| earley-boyer | 0.89 / 0.93 | 0.89 / 0.93 | 0.89 / 0.94 | 0.96 / 1.01 | 0.92 / 0.96 | **0.90 / 0.92** | 0.90 / 0.91 |
| raytrace | 0.90 / 0.93 | 0.90 / 0.93 | 0.89 / 0.92 | 0.96 / 1.00 | 0.92 / 0.95 | **0.90 / 0.92** | 0.90 / 0.92 |
| deltablue | 0.89 / 0.98 | 0.90 / 0.99 | 0.90 / 0.98 | 0.91 / 1.00 | 0.90 / 1.00 | 0.90 / 0.99 | 0.90 / 0.99 |

足迹（maxrss，S4 收口）：raytrace **0.35**、regexp 0.72、eb 0.92、pdfjs 0.91、splay 0.80、deltablue 0.97。

S5（消融/拆分，`f005aee7`）对 insn 中立：六项相对 S4-i 均在 ±0.3% 内，见 s5-spec §7.9。

**唯一 STOP = splay cycles 1.26（S4-i 后，S5 后 1.257）**：tracing 相对「rc 即时释放 = 完美 nursery」的结构账（2026-08-31 结构评审的中心假设）叠加 S4 每对象一个存储 cell 的标记成本。可继续的刀见 s4-spec §7 末段。

## 4. 战役中修掉的真缺陷（均有回归测试）

extent 永久 young 位与 `young_count` 虚高；medium 分配器二次方 first-fit；string 分配不触发 GC；`pollGC` 先判阈值再给 minor（pdfjs 908 次 major）；regexp 匹配数组 fill 原生暂存无根 + `adoptDenseArrayElements` 绕过 remembered set；`setErrorStack`/`setCallSiteMetadata`/`replaceRegExpLegacySlot`/JSON 覆盖臂等老→新 string 屏障；atom 判决与 sweep 不同 pause；`op_push_atom_value`/`op_add_strings` 与 8 处 resident handler 分配前不发布 sp（含 call region 窗口从未发布）；young symbol body 对 minor 不可见 + `markAtomAtEpoch` 短路；JSON reviver 记录树无根；`takeClassedBlock` errdefer 写在 comptime-if 内从未生效；`VERIFY_MAJOR_ALL` 探针撑大 `JSRuntime` 挪动 GC 时机 + 让 atom 戳过期；新 extent kind 的 occupant 表泄漏；prefix-carrier 漏斗缺 payload 臂；minor 打出的洞回不到分配器（committed/live 36.9×）；**byte 6 共享字节让 remembered 位撤销 construction-root**（活 generator shell 被 minor 判死）。

## 5. KILLED / 未合入

S2-h2 nursery 按字节触发（无配置支配 16K 计数，4MiB 让 eb maxrss +63%）；医 medium 归还 idle 门 1s 维持。

## 6. 待 owner 的裁决

1. ~~`cycle_visited` 删除~~ → S4-h 已用 `mark_epoch` 保留值完成；余：`unlinkObjectWithBytes`/`recordDetachedHeapFreeWithBytes` 读点仍在。
2. ~~trace-coupled retirement~~ → S4-i 已修根因并合入（三条不经 frontier 的 mark claim 在窗口前触达），splay +5.4%/raytrace +2.4%/eb +3.2%；余：promote 走位图当权与 `opCall +66` 定价。
3. ~~OOM 注入对块堆 cell 级仍不可见~~ → harness lane 已加独立 cell 级钩子（不计 backing、非粘性，同一 `fail_index` 空间；retry sweep 62→72、64→74；parse 窗口零 cell 分配故 lookahead canary 不变）；~~`builtin.is_test` 粗粒度门~~ → misc2 已收窄为 `-Dzjs_oom_injection`（只由 `test-oom` 步设置）。
4. ~~run-test262 用绝对路径 `-d` 静默丢 override manifest~~ → 已归一到 test262 根并对越界绝对路径硬错；余：known-error 文件未归一、相对越界选择器仍静默（保 `-d built-ins/Object` 用法）。
5. ~~`byKind.bigInt` 未进 JSON；schema 长期方案~~ → `SCHEMA_VERSION = 8` + `SCHEMA_ADDED_LEAVES` 版本映射，候选多出未登记 leaf 改为硬错；余：冻结基线的 v7 戳其实早于 v7 内容（用「stamp N 可缺 N 的新增」规则容纳，更干净是重标 v6）。
6. R1 的量级：R3 修正后「可归因」29% 经 R1-a 实证绝大部分是 LLVM 栈槽残渣与调用方 callee-saved 溢出（`eval_entry.zig:196` 加根无效），真缺根只有 regexp 匹配数组一处；R1 的正路 = 普查加 `word-header` 偏移/帧内槽位两列以分辨残渣 → 缩帧/擦栈（eval 编译阶段大局部限定作用域）→ cold 出口 publish + reg_sp windowed 根 → 翻 `value_root_link_containers_only`；量级需按修正后的清单重新估（不再是 12-20 lane-week 的「补 740 个候选」）。`class/elements` 缺陷已修，「shape 年轻路径存活性依赖保守钉住」的同型窗口未普查。
7. push 前压缩：~~压缩~~ 已完成（2026-09-06，6 主题 commit + 后续 3 个，备份 `backup/pre-squash-2026-09-06`）；未 push。
4. S5-b 析构合一后 deltablue 稳定多 1 次 major（18→19）：析构 kind 次序改变 ⇒ cell 复用次序 ⇒ 阈值边界相位位移，insn/cycles/objectsFreed 均 <0.05%，S5-a 自身复跑包络已覆盖该读数；回退面只有分桶次序（合一的前提）。**owner 2026-09-05 裁决：接受。**
5. push：S0–S5 全部落在本地 main（未 push），S5 末全门 + STRESS test262 + Stage 0 均绿；等 owner 确认。

## 6a. S5 后清账（2026-09-05 晚，driver）

批门禁（`mise run batch-gate` 的 gate_smoke 半段）与 checkpoint-gate 在 S4/S5 阶段末都没跑过，落下两笔：

1. **checkpoint-gate 红**：`test-embedding` 的公共 API 声明数 pin（JSValue 84 / JSRuntime 164）在 rc 表面删除后没更新（实测 80 / 162，消失的正是 `dup/free/dupValue/freeValue` 等十个 rc 声明）。已重钉（`79170834`）。
2. **gate_smoke 红**：pdfjs 的 arena-audit 运行报 `PROPERTY STORAGE AUDIT: DanglingArrayStorageCell`，且对代码布局敏感（加一行冷路径打印就消失，改动前的 `d30ae3a0` 单独构建 6/6 复现）。用同一二进制的环境变量开关逐个证伪了五个假设（mapped-arguments 采纳缺屏障、审计跳 condemned 戳、标记期 bulk-write 只 requeue 不登记、young extent 被 major 标记后未晋升、trace 只在 `fast_array` 时访问元素 cell），最后由 doomed 位定案：**owner 是本次 major 位图判死的尸体**（块 cell 判死不盖 header 戳，所以 `headerCondemned` 读不出来），它的 6035 元素 extent 在 finish 时被同步的 `sweepExtents` 先回收，而 `verifyObjectPropertyStorageLayouts` 在销毁切片之前遍历到这个尸体——**审计误报，不是健全性缺陷**（`ZJS_GC_VERIFY_MINOR` / `ZJS_MINOR_AUDIT` 全程静默）。修法：审计跳过已判死 owner（块 cell 看 doomed 位，其余看戳）；审计失败时打印 owner class/capacity/cell 地址且不解引用 cell。
   - 顺手补上的两处屏障（按代码自己的约定应有）：`allocateMappedArgumentsVarRefsAssumingEmpty` 采纳 var-ref 表后 `rememberOwnerForBulkWrite`；`createArgumentsObject` 填完表再登记一次。环境开关证明它们与本次失败无关，保留为防御。
   - 未动的疑点（入 backlog）：`Object.traceChildEdges` 只在 `fast_array` 时访问元素 cell，而 `recomputeArrayStorageMode` 可以在 capacity 不变的情况下把 `fast_array` 清掉再置回；理论上存在"非 fast 期间 extent 被 major 回收、再 fast 后悬空"的窗口。按 class+capacity 访问的尝试在 pdfjs 上 SIGSEGV（疑为 `arguments` 类的 arm 与 payload 重叠），需要先把 arm 可读性判据弄清再改。

## 6b. Splay 余刀关账（2026-09-06，driver；owner 同日批「性能账关门」）

依据 S5 末 Stage 0 的符号剖面（`.scratch/stage0/s5-final/symbol-profile/`，
cycles/u，两侧各 ≈2K 样本，事件计数 7.31G → 9.54G），按类别闭合 splay 的
剩余差距（单位：样本；baseline = 冻结 rc `main-d944f26d`）：

| 类别 | rc 基线 | 候选 | Δ | 备注 |
|---|---:|---:|---:|---|
| 标记（shadeExact / storageCell / traceHeaderEdges / collectMinor / incrementalMarkStep） | 197 | 686 | **+489** | 差距本体；tracing 相对 rc 即时释放的结构账 |
| 分配/发布（allocCell / addInitializedWithSizeNoFail / createWithFam / memset / findCellState / createObjectRootReserved） | ≈289 | ≈338 | +49 | `findCellState` 41 = 位图回收后重建空闲区间 |
| 写屏障（generationalBarrierSlow） | 21 | 56 | +35 | |
| 解释器（op_get_field 等） | ≈197 | ≈236 | +39 | 缓存效应，非代码差 |
| 析构/回收（destroyCondemnedSlice / sweepUnmarkedYoung / destroyShape / freeSmall） | ≈261 | ≈154 | **−107** | 已反超 rc |

余刀逐条：

1. **`opCall +66/+70` = 符号差工具的伪影，关账无工作。** 两侧都有三个
   `opCall__struct_N.h` 实例（fixed-arity comptime 实例），基线
   `__struct_138912.h` 72 样本、候选 `__struct_139059.h` 70 样本；
   `symbol-diff.json` 按序号而非内容配对 `__struct_N`，把 72→70 记成
   0→70。S4 §7「`opCall` 定价」项据此撤销。
2. **`reclaimDoomedBlock` header 载入残留**：S5-b 后该符号并入
   `destroyCondemnedSlice`（118），而析构/回收整类已比 rc 少 107 样本；残留
   上限 ≤118 样本且只在 remembered map 非空时走 header。不再单独立项。
3. **promote 走位图当权**：S4-i 已让 `nextInBlock` 从剖面消失，minor 侧只剩
   `collectMinor` 75（3.4%）；原定价「净 +2.5%」的前提（逐 header promote）
   已不存在，低于 2pp 立项线，关闭。
4. **存储 cell 重复计价**（`unpublishStringCell → recordHeapFreeWithBytes` 与
   `bitmap_bytes` 整批 debit）：记账正确性疑点，不在 cycles 账上；转
   backlog（Q22），与 Q21 一起清。
5. **存储 cell 内联更多槽**：`storageCell` 139 样本（6%）是唯一非纯结构的大项，
   但与 M 终态 64B Object 冲突，属表示实验（vm-value-representation-contract
   禁区），不做。
6. **block 级 black allocation 上限**：标记期发布本身只有
   `publishGreyCold` 13 + `publishInitializedCold` 9 = 22 样本（≈1%）；要过
   2pp 线需 `shadeExact` 中 ≥25% 来自标记窗口内新对象的 major 复标（minor 侧
   的 young 标记不受 black alloc 影响）。无「标记期发布计数」无法闭合该上限；
   按 gc-v2-completion-and-pivot 的预注册线（≥2pp 才立项）与本账的 1% 硬下限，
   **KILLED（不加计数、不做实验）**。

裁决：splay 1.26× 的余额全部在标记类，是结构账；已定价余刀无一越线。
Octane vs qjs 自此降为回归门（≥0.95 不退），性能线关门；主力转
构建/测试/门禁迭代效率（owner 2026-09-05 裁决）。五引擎 17 项钉住快照
（zlib 契约变更后的新基线）2026-09-06 由 `10966b12` 二进制在跑，读数落
`docs/perf/bench-v8-status.md`。

## 7. S5 收官摘要

S5-a 恒真门/过期面板（−294）、S5-b 析构与凝判路径合一（−171）、S5-c `concurrent→incremental`（+9）、S5-d Registry 拆分（gc.zig 5,444→3,988 行，`@sizeOf(Registry)` 不变，屏障读仍单条 `ldr`，整机 −263 指令）、atom ownership audit 单槽隔离缺陷修复。细节与门见 `tracing-gc-s5-spec.md` §7。GC 战役收官，下一方向按 `type-directed-optimization-plan.md` v1.3 校准批转 TS/AOT。
