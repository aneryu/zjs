# TGC S5 规格：收尾消融（恒真门、重复路径、误名、Registry 拆分、文档 supersede）

状态：v0.1（driver，2026-09-06）；上游 `docs/tracing-gc-completion-plan.md` §3 S5；owner 2026-09-06 裁「R1 不立项，S5 消融后转 TS/AOT」。
基线：main ≥ 448b0b09（S4-h 头部位终态、R1-b 合入后）。勘察：只读报告（2026-09-06，Opus）。**目标是净删行与可维护性，不是性能**；每批 Stage 0 只做快筛确认无回归（insn 口径）。

## 0. 计划外调整

计划 S5 的「删 gc_conservative 生产路径的门」以 R1 全精确根为前提，R1 已按 owner 裁决不立项 → **该项删除**；保守扫描保持生产默认。

## 1. 事实（勘察摘录）

- `gc.zig` 5,438 行，`Registry`（1643–5438）3,796 行 / 37 字段 / 114 方法；分组：Scheduler 7 字段、Heap 8、Lists 7、IncrementalMajor（`concurrent`/`concurrent_mark_queue`/`mark_stack`/`doomed_*`）10、Pin 3、Diagnostics 1（`stats`，但 16 个 verify/statistics 方法 ≈900 行）、地址注册表 1。注释 1742–1754 已自承 concurrent marker/queue 不该是 Registry 字段。
- 耦合最紧：`expectedBarrierGate/refreshBarrierGate/setMajorMarkingActive`（`barrier_gate` = `markingActive ∨ detailed_reports`，inline 热路径）；`unlinkObjectWithBytes`（链表/记账/注册表/pin 一次改四组）；`finishIncrementalCycle` 凝判段（写 6 个 `doomed_*` + 四组）；`verifyHeapAccounting`（160 行全组）；`generationalBarrierSlow`/`rememberOwnerForBulkWriteSlow`（remembered set 与增量灰队列共入口）。
- 重复路径：`destroyCondemned`（138 行，STW）与 `destroyDoomedSlice`（201 行，增量）是同一套五遍 kind 顺序析构（代码自承），差别 = 链表 vs `doomed_by_kind[6]` 分桶、`budget_ns` 续跑、尾部 `sweepExtents`；三处凝判扫链（`sweepUnmarked` 110 / `sweepUnmarkedYoung` 174 / `finishIncrementalCycle` 内联 ~90）写法各异；增量 `markStep` 手写 `popSegmentedFrontier` 循环而非 `drain`；STW 入口 `block_heap.beginMajor` 调两次。
- `gc_concurrent.zig` 127 行零线程：`Stats`（~60 字段）+ `State`（8 字段，`major_marking_active` 是 atomic 但注释明写单线程）；`concurrent` 标识符 278 处（gc.zig 103、tests/core.zig 106、gc_trace_stw 35、runtime 11、zjs.zig 6；`atomics_ops.zig`/`compiler/tests.zig`/`run_test262*` 各 2 处与 GC 无关）。
- 恒真 comptime 门：`trace_stw_enabled`（`-Dzjs_gc` 只剩 `trace_stw`，rc/shadow 走报错分支 build.zig:64–70）、`block_heap_enabled` 100 处、`generation_enabled` 67、`address_registry_enabled`+`space_model_enabled`、`concurrent_enabled`。真开关：`zjs_gc_roots_diag`（21）、`zjs_ownership_audit`（→ `authority_audit_enabled` 派生 6 个）、`zjs_force_gc`；运行时 `verify_major_all`/`minor_audit`/`detailed_reports`/`mark_footprint_census`。
- 死/近死：`pub fn` 无外部生产调用者 32 个（13 个可降私有、3 个 test-only 加门、5 个 diag-only、其余双用）；rc 残留只剩命名 `metadata_rc_offset`（3 处）、poison 的 `cycle_visited` 注释与 `@compileError` 文案、`refcount_removed_headers` 恒等 `marked_headers`、`zero-ref drains` 硬编码 0、`parked_frees 0` 字面量。
- `--gc-stats` 50 行 / 10 个 `dumpGc*`；解析器 39 处匹配；过期行：`zero-ref drains`、`refcount-removed headers`、`pass-A settled cells`（字段已改名 `bitmap_reclaimed_cells`）、`parked_frees 0`；**`atom audit stale-edge/shell-edge` 行解析器找的是 `missing-edge/over-marked`，永不匹配静默回 0**。
- 文档：`tracing-gc-header-v2-design.md`（APPROVED r2）、`tracing-gc-block-drain-hot-reuse-design.md`（Pass-A/B）必标 superseded；`corpse-final-design`/`corpse-census`/`rc-retirement`/`pause-plan`/S1–S4 spec 标 historical/已完成；`gc-invariants.md`/`gc-inventory.md`/`gc-ablation-plan.md` 是活文档就地改写。
- Registry 拆分风险：`phase align(64)` 必须在 offset 0 且与 `barrier_gate` 相邻（K4 热路径，`gc.zig:1644–1667`）；`@offsetOf(Registry)` 全仓 0 命中（低风险）；`expectedBarrierGate` inline 跨三组，拆后须验证 aarch64 仍单条 imm-offset `ldrb`；OOM 部分构造回滚义务随子结构 `deinit` 幂等性验证；`gc_mark_pool`（`IncrementalMarkState`，2 字段：`footprint` 诊断 + `last_settled_live_bytes` pacing）名不副实。

## 2. 分批（每批一个 lane，顺序执行，互不并行——都动 gc.zig/gc_trace_stw.zig）

### S5-a 恒真门与过期面板（预计 −250 行）
1. 删 `-Dzjs_gc` 选择器（build.zig:58–75）与 `build_options.zjs_gc`；`trace_stw_enabled/block_heap_enabled/generation_enabled/address_registry_enabled/space_model_enabled/concurrent_enabled` 六常量删除，~190 处 `if (comptime …)` 展开为无条件代码、`else` 分支删除（含 tests）；`gc_representation` 快照重生成。
2. rc 命名整改：`metadata_rc_offset` → `metadata_lifetime_offset`（3 处）；poison 常量注释与 `@compileError` 文案改为「bit7 = reserved，poison 字节值不变」；`gc_block_heap.zig:240` 注释更新。
3. `--gc-stats`：删 `zero-ref drains`、`refcount-removed headers`（`MarkFootprint.refcount_removed_headers` 字段一并删）、`pass-A settled cells` 改名 `bitmap reclaimed cells`、`parked_frees 0` 删；`gc_stats_snapshot.py` 三条正则同步 + **`SCHEMA_VERSION 9` 加 `SCHEMA_REMOVED_LEAVES` 映射**（候选缺的 leaf 若登记为该版本删除则允许）；**修 atom audit 行的正则**（`stale-edge/shell-edge/entries`）并加校验 `stale_edge == 0`；`tools/perf/verify/test_gc_stats_snapshot.py`、`test_stage0_screen.py` 同步；两个 `.scratch/stage0` 基线 JSON 只读不改（靠映射）。
4. 13 个 `pub fn` 降私有、3 个 test-only 加 `builtin.is_test` 门。
门：test / stress / roots_diag / test-oom；`mise run stage0` 快筛（insn ±0.5% 内视为无变化）。

### S5-b 重复路径合一（预计 −250 行）
1. `destroyCondemned` ⊕ `destroyDoomedSlice` → 一个 `destroyCondemnedSlice(budget_ns, clock_cadence, sweep_extents)`：输入统一为 `doomed_by_kind` 分桶（STW 路径也走分桶，`residual_kinds` 位图预扫删除），`budget = maxInt` 即 STW 语义；尾部 `sweepExtents` 由参数控制；`destroyCondemned` 删除，`collectCycles` 改调用；`doomedStateSnapshot` 只保留一处。
2. 三处凝判扫链 → `condemnListSweep(rt, sink, young_only)`（未标记 ∧ 非 pinned → 摘链 → 入 sink；`young=false` 清除、shape 退表、`heapByteSizeFromHeader` 记账在 sink 内统一）；`sweepUnmarked`/`sweepUnmarkedYoung`/finish 内联段改调用；块 cell 半边保持位图路径不动。
3. 增量 `markStep` 的手写 frontier 循环改用带预算的 `drain(budget)`；STW 入口双 `beginMajor` 去重。
4. `collectCycles` 生产只剩 1 个调用点：保留（`runObjectCycleRemoval` 契约），但其体收缩为「begin → 全量 markStep → finish(budget=maxInt)」的增量路径复用（若能做到，STW 专用函数体整体删除；做不到就止于 1–3）。
门：同 S5-a + test262 script（析构语义面）。

### S5-c 改名与文档（净删 0，机械）
1. `concurrent` → `incremental`：`gc_concurrent.zig` → `gc_incremental.zig`，`Registry.concurrent` → `incremental`，`concurrent_enabled` 已在 S5-a 删；`major_marking_active` 去 atomic（注释明写单线程；若保留 atomic 写明将来并行标记的意图）；`atomics_ops.zig`/`compiler/tests.zig`/`run_test262*` 的无关命中不动。`IncrementalMarkState`（`gc_mark_pool`）拆：`footprint` 归 Diagnostics、`last_settled_live_bytes` 归 incremental state，删该结构。
2. 文档：header-v2、block-drain-hot-reuse 标 **SUPERSEDED**（指向 `tracing-gc-completion-account.md` 与 s4-spec §7）；corpse-final/corpse-census/rc-retirement/pause-plan/S1–S4 spec 顶部加「历史/已完成」状态行；`gc-invariants.md`、`gc-inventory.md`、`gc-ablation-plan.md` 就地改写（删 husk/Pass A-B/rc 段落，补 needs_finalizer 位图、storage cell、atom 戳、condemn 保留值）。
门：test；`zig build check` 全部 build 步骤名。

### S5-d Registry 拆分（净删 0，可维护性；**owner 可选**）
拆为 `gc/registry/{scheduler,heap,lists,incremental,pins,diagnostics,address}.zig` 七个子结构；`Registry` 首字段 `hot: HotWords align(64) { phase, barrier_gate }`（K4 约束：offset 0、相邻）；`expectedBarrierGate` 等 inline 热函数留在 Registry 顶层读 `hot.*` 与 `incremental.state`；`unlinkObjectWithBytes`/`finishIncrementalCycle` 凝判段/`verifyHeapAccounting` 作为跨组函数留顶层。验证：aarch64 objdump `barrierOwnerSkips`/`expectedBarrierGate` 仍单条 imm-offset `ldrb`；K4 dossier 的 earley-boyer/splay 计数复跑；`-Dzjs_ownership_audit` + test-oom（子结构 `deinit` 幂等）。
建议：**做**——这是计划立的可维护性项，且 S5-a/b 后 Registry 仍 >3,000 行；但放最后，独立成 PR，owner 可按时间叫停。

## 3. 门与对账

每批：test / stress / roots_diag / test-oom；S5-b 加 test262 script；S5 末：全套 + STRESS test262 + Stage 0 一次；代码量对账写入 `docs/code-volume.md`（S5 净删目标 ≥ 400 行，不含 S5-d）。

## 4. 风险

- S5-a 展开 190 处门时容易把 `else` 分支里仍被测试引用的符号一起删掉——按文件逐个编译。
- S5-b 合一后 STW 路径改走分桶：`residual_kinds` 位图曾是 STW 的性能捷径，快筛看 deltablue/raytrace 的 major 析构 STW 时间。
- S5-c 改名与 S5-d 拆分的 diff 巨大，必须在 S5-a/b 合入且门绿后单独进行，禁止与任何功能 lane 并行。

## 7. 执行记录

### 7.1 S5-a（合入 main `99793e8b`，2026-09-06）
- `-Dzjs_gc` 选择器与 `build_options.zjs_gc` 删除；六个恒真门常量删除，门展开为无条件代码（含 tests）；`memory.zig` 里派生的 `arena_addressable` 一并删除（misc2 合并时的冲突就在这一处，见 7.3）。
- rc 命名整改与 poison 文案更新；`--gc-stats` 删 `zero-ref drains`/`refcount-removed headers`/`parked_frees`，`pass-A settled cells` → `bitmap reclaimed cells`；`gc_stats_snapshot.py` 升 `SCHEMA_VERSION 9`，新增 `SCHEMA_REMOVED_LEAVES`/`SCHEMA_RENAMED_LEAVES`；atom audit 行正则修正（`stale-edge/shell-edge/entries`）并校验 `stale_edge == 0`。
- 28 个 `pub fn` 降私有（勘察估 13+3，实做时另找到 12 个无外部调用者）。
- 净 −294 行。门：test / stress / roots_diag / test-oom 绿。

### 7.2 S5-c 文档半边（合入 main `15a6d291`）
- `tracing-gc-header-v2-design.md`、`tracing-gc-block-drain-hot-reuse-design.md` 标 SUPERSEDED；十二份记录标 historical；`gc-invariants.md`/`gc-inventory.md`/`gc-ablation-plan.md`/`architecture.md` 改写到 S4 后模型。代码半边（`concurrent → incremental`、`IncrementalMarkState` 拆）等 S5-b 合入后单独 lane。

### 7.3 misc2（合入 main `6bf7729e`）
- 三件计划外小修：`callValueWithThisGlobalsAndGlobal` 在 >8 参数拷贝前根住源参数；run-test262 known-error 列表按 test262 根归一化；OOM 注入的 backing 拓扑改为显式 build option `zjs_oom_injection`（只由 `test-oom` 步设置），不再用 `builtin.is_test` 让整套单测跑在发布版没有的分配器拓扑上。
- 合并冲突：misc2 基于 `6253b239`，与 S5-a 在 `memory.zig` 门常量区域相撞；裁决保留 `oom_injection_enabled`，删 `arena_addressable`（其条件在 S5-a 后恒真），`useIndependentSmallObjectSlabArenaBacking` 只剩注入门一条早退。门：test 2558/0、test-oom 22/0。

### 7.4 S5-b（进行中，worktree `s5-b`，基线 `99793e8b`）
待记。

（7.4 补记）S5-b 合入 main `899c5a7c`，净 −171 行（规格估 −250，差额是合并函数的文档注释）。
- 项 1：`destroyCondemnedSlice(rt, budget_ns, sweep_string_extents)` 成唯一析构权威，STW = `budget = maxInt`；两条路径都走 `doomed_by_kind` 分桶，`residual_kinds`/`KindSet`/`tmp_obj_list`/`NonBlockObjectAuthority.temporary` 车道一并删除。可观测差异只有同 pause 内的 kind 析构次序（shape 严格最后）。
- 项 2：`condemnListSweep(rt, sink, young_only)` + `SamePauseSink`/`FinishCondemnSink` 取代三处扫链；块 cell 位图半边不动。
- 项 3：`drainSegmentedFrontier(budget_ns, comptime prefetch, comptime drain_work)` 合并 `incrementalMarkStep` 与 `drainBarrierQueue`（规格写的 `drain` 排的是 work list，与分段前沿不同形，已按实际同形函数落地）；`collectCycles` 多余的 `beginMajor` 删除（每次同步 major 少一次 epoch bump 与 `withdrawHotBlocks`）。
- 项 4 STOP：`collectCycles` 收缩为增量路径会改返回值语义（析构计数 vs 凝判计数，单测断言精确常量）、`--gc-stats` 读数与析构时机，不是消融。
- 门：test 2556/0 ×4、stress 2552/0、roots_diag 2560/0、test262 0/49778。Stage 0 vs S5-a 自建参照：六 bench insn 全在 ±0.07% 内；`residual_kinds` 捷径删除后 deltablue/raytrace STW 析构时间在复跑噪声内。
- 待 owner 知悉：deltablue 稳定多 1 次 major（18→19），归因于项 1 改变析构次序 ⇒ cell 复用次序 ⇒ 阈值边界相位位移；insn/cycles/objectsFreed 均 <0.05%，且 S5-a 自身复跑包络已覆盖该读数。回退面只有分桶次序（合一的前提），不建议回退。
- 合入 main 后补跑 `ZJS_GC_STRESS=1` test262（核 0-9，`reports/test262-s5b-stress`）：`Result: 0/49778 errors, passed 44584`。

### 7.5 S5-c 代码半边（合入 main `fc21a7dd`）
- `gc_concurrent.zig` → `gc_incremental.zig`、`gc.concurrent` → `gc.incremental`、`Registry.concurrent` → `incremental`、`ConcurrentState` → `IncrementalState`、`concurrent_mark_queue` → `incremental_mark_queue`、`shadeForConcurrentMark` → `shadeForIncrementalMark`。净 +9 行（310+/301−）。
- §1 勘误：`compiler/tests.zig` 的两处与 `tests/helpers.zig:824` 都是 `gc.concurrent.markingActive()` 轮询，属 GC 命中，已改；真正无关的只有 atomics_ops、run_test262 runner/reporter、两处 python。表达「将来并行标记」意图的注释保留并改写为 future parallel marking（condemn 戳 atomic store、块位图 epoch CAS、`generationalBarrierSlow` 撕裂前提、两块 STW-split 面板）。
- `major_marking_active` 去 atomic：`src/core/gc*.zig` 无 `std.Thread`，S4-b 并行标记已撤回而非默认关，唯一写方 `setMajorMarkingActive` 全在 owner 线程；`comptime order` 形参随之删除。
- `IncrementalMarkState` 拆：`last_settled_live_bytes` → `gc.incremental.State`（仍是 write-only，B03 消融候选，未删）；`footprint`（680B）**未进 Registry**——实测进 Registry 会把 `barrier_gate` 从 offset 16 推到 2432、`@sizeOf(Registry)` 6080→6784（正是 K4 要防的），改放 `JSRuntime.gc_mark_footprint`，Registry 字节等同。
- 门：test 2558/0、roots_diag 2562/0、check + 五个 exe 步 18/18；`--gc-stats` 标签无 `concurrent`，schema 不动。
- 工具教训：`git worktree add` 后主树 `test262` 已作为目录存在，再 `ln -s` 会把软链套进目录一层导致两条 run_test262 单测 FileNotFound；正确做法 `rm -rf <wt>/test262 && ln -s`。
