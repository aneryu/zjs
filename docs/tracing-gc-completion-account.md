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
| 头部位 | `kind:u4 | young | needs_finalizer | finalizing | reserved` | ⚠️ 现为 `kind:u4 | young | finalizing | needs_finalizer | cycle_visited`：`mark`/`is_pinned` 已删；**`cycle_visited` 留**（list carrier 缺 condemned 判据，S4-e 记） |
| 根集 | R3 诊断 → R1 全精确 | ✅ R3 完成（归因普查，`.bss` 表，诊断构建与生产同布局）；R1-a 落地：六窗口中只有 regexp 匹配数组是真缺根（direct −7.8%）+ 一个真 bug（publishing-shape 根帧提前 deactivate），其余为栈残渣/callee-saved 溢出——**R1 不能按 R3 清单驱动**，需普查加残渣分辨列、eval 帧靠缩帧 |

## 2. 门（main 3ff3f8d3）

| 门 | 读数 |
|---|---|
| `zig build test` | 2553/0 |
| `test-gc-stress` | 2549/0 |
| `-Dzjs_gc_roots_diag` | 2553/0 |
| test262 script | 0/49778（空闲/负载 ×3） |
| **`ZJS_GC_STRESS=1` test262** | **0/49778**（修 byte6 共享位缺陷前 84% 处必崩） |
| leak-census | 1562/0 |
| test-oom | 21/0（注入窗口 `fail_index` 6→38） |
| test-stress | 6/0（Debug 与 ReleaseSafe） |
| 三个架构检查器 | 通过（此前基线就红） |

## 3. Stage 0 轨迹（对冻结基线 main-d944f26d，insn / cycles）

| workload | S2 翻开关 | S2-f | S2-i | S4 a–f | **S4 收口** |
|---|---|---|---|---|---|
| pdfjs | 111.9 / 275.4 | 1.40 / 2.35 | 0.83 / 0.82 | 0.85 / 0.88 | **0.82 / 0.85** |
| splay | 1.17 / 1.29 | 1.21 / 1.34 | 1.22 / 1.33 | 1.33 / 1.36 | **1.22 / 1.32** |
| regexp | 1.20 / 1.47 | 0.99 / 0.99 | 0.99 / 1.01 | 0.99 / 1.03 | 0.98 / 1.01 |
| earley-boyer | 0.89 / 0.93 | 0.89 / 0.93 | 0.89 / 0.94 | 0.96 / 1.01 | 0.92 / 0.96 |
| raytrace | 0.90 / 0.93 | 0.90 / 0.93 | 0.89 / 0.92 | 0.96 / 1.00 | 0.92 / 0.95 |
| deltablue | 0.89 / 0.98 | 0.90 / 0.99 | 0.90 / 0.98 | 0.91 / 1.00 | 0.90 / 1.00 |

足迹（maxrss，S4 收口）：raytrace **0.35**、regexp 0.72、eb 0.92、pdfjs 0.91、splay 0.80、deltablue 0.97。

**唯一 STOP = splay cycles 1.32**：tracing 相对「rc 即时释放 = 完美 nursery」的结构账（2026-08-31 结构评审的中心假设）叠加 S4 每对象一个存储 cell 的标记成本。可继续的刀见 s4-spec §7 末段。

## 4. 战役中修掉的真缺陷（均有回归测试）

extent 永久 young 位与 `young_count` 虚高；medium 分配器二次方 first-fit；string 分配不触发 GC；`pollGC` 先判阈值再给 minor（pdfjs 908 次 major）；regexp 匹配数组 fill 原生暂存无根 + `adoptDenseArrayElements` 绕过 remembered set；`setErrorStack`/`setCallSiteMetadata`/`replaceRegExpLegacySlot`/JSON 覆盖臂等老→新 string 屏障；atom 判决与 sweep 不同 pause；`op_push_atom_value`/`op_add_strings` 与 8 处 resident handler 分配前不发布 sp（含 call region 窗口从未发布）；young symbol body 对 minor 不可见 + `markAtomAtEpoch` 短路；JSON reviver 记录树无根；`takeClassedBlock` errdefer 写在 comptime-if 内从未生效；`VERIFY_MAJOR_ALL` 探针撑大 `JSRuntime` 挪动 GC 时机 + 让 atom 戳过期；新 extent kind 的 occupant 表泄漏；prefix-carrier 漏斗缺 payload 臂；minor 打出的洞回不到分配器（committed/live 36.9×）；**byte 6 共享字节让 remembered 位撤销 construction-root**（活 generator shell 被 minor 判死）。

## 5. KILLED / 未合入

S2-h2 nursery 按字节触发（无配置支配 16K 计数，4MiB 让 eb maxrss +63%）；医 medium 归还 idle 门 1s 维持。

## 6. 待 owner 的裁决

1. `cycle_visited` 删除需给 list carrier 补 condemned 判据（epoch 或位图），规格外重构。
2. splay 剩余刀：promote 走位图当权（净 +2.5%，波及 43 处 `flags.young`）/ minor 内 trace-coupled retirement / `opCall +66`（H4）定价。
3. ~~OOM 注入对块堆 cell 级仍不可见~~ → harness lane 已加独立 cell 级钩子（不计 backing、非粘性，同一 `fail_index` 空间；retry sweep 62→72、64→74；parse 窗口零 cell 分配故 lookahead canary 不变）；`builtin.is_test` 粗粒度门是否收窄为 oom artifact 选项仍待裁。
4. ~~run-test262 用绝对路径 `-d` 静默丢 override manifest~~ → 已归一到 test262 根并对越界绝对路径硬错；余：known-error 文件未归一、相对越界选择器仍静默（保 `-d built-ins/Object` 用法）。
5. ~~`byKind.bigInt` 未进 JSON；schema 长期方案~~ → `SCHEMA_VERSION = 8` + `SCHEMA_ADDED_LEAVES` 版本映射，候选多出未登记 leaf 改为硬错；余：冻结基线的 v7 戳其实早于 v7 内容（用「stamp N 可缺 N 的新增」规则容纳，更干净是重标 v6）。
6. R1 的量级：R3 修正后「可归因」29% 经 R1-a 实证绝大部分是 LLVM 栈槽残渣与调用方 callee-saved 溢出（`eval_entry.zig:196` 加根无效），真缺根只有 regexp 匹配数组一处；R1 的正路 = 普查加 `word-header` 偏移/帧内槽位两列以分辨残渣 → 缩帧/擦栈（eval 编译阶段大局部限定作用域）→ cold 出口 publish + reg_sp windowed 根 → 翻 `value_root_link_containers_only`；量级需按修正后的清单重新估（不再是 12-20 lane-week 的「补 740 个候选」）。`class/elements` 缺陷已修，「shape 年轻路径存活性依赖保守钉住」的同型窗口未普查。
7. push 前压缩：main 领先 origin 42 个 commit（含 8 个 WIP 快照），建议按时间段压成 5–6 个主题 commit（S2 flip+S3-a/b、S2-g+S3-c/d、S2-h/i+S4-a、S4-b/c+测试 tier、S4-d..g+R3+修复、docs）。
