# TGC S0 规格：止血与安全网（+ R3 诊断开工）

Status: **EXECUTED**（driver 亲写，2026-09-03；owner「不需要 codex，你自己来」；上位文档 `tracing-gc-completion-plan.md` 已批准）。执行记录与偏离见 §执行记录。

原计划四条 lane 并行派发；实际由 driver 在分支 `gc/tgc-s0-20260903` 上按 L1→L2→L3→L4 顺序亲手实现，规格正文保留为验收清单。

## L1 僵尸删除（纯减法，行为不变）

| # | 删除 | 证据 |
|---|---|---|
| 1 | `src/core/gc_candidate.zig`、`gc_snapshot.zig`、`gc_marker.zig` 三文件；gc.zig:353 `candidate_validation`、:367 `marker`、:371 `layout_snapshot` 三个 re-export；tests/core.zig 中使用它们的用例（16494-16513、17089-17124、17148-17205 附近，按符号 grep 定位，整 test 删） | 生产零引用 |
| 2 | object_gc.zig 40-262：`MarkMode`、`collectCycleMarkChildForTest`、`markFuncFor`、`markHeader`、`markUnusualPropertyCold`、`markIteratorNextCacheCold`、`markPropertyDataSlots`、`markOrdinaryObjectHot`、`markFastArrayHot`、`markShapeHot`、`markChildrenCold`、`markOne`；549 起 `collectCycleMarkChildHeadersForTest` 与 `CycleMarkPathForTest`；object.zig:7087-7088 两个 re-export；object.zig:7631 注释改指 `Object.traceChildEdgesFallible`；tests/core.zig 8808-8950 三个「cycle-mark hot arm matches authority」用例及其 helper。**保留** `drainCycleDeferredFrees(Budgeted)`、`trySettleTracerBlockCorpse`、`enqueueFinalizationCleanup` | 生产边枚举是 gc_trace_stw.zig:63 `traceHeaderEdges` → `traceChildEdgesFallible`，hot 臂只被测试到达 |
| 3 | corpse census 实验：`src/core/gc_corpse_census.zig`、root.zig:113-114、cli/zjs.zig:441-442、build.zig:95-100 选项与 build/config.zig:124/144、gc.zig `corpse_census_enabled` 及 object_gc.zig:356 `censusNoteParked` 与其调用 | 测量已完成（08-29 一 commit），默认 off |
| 4 | gc.zig 内恒真门死臂：`if (comptime !generation_enabled) return …`、`!concurrent_enabled`、`!block_heap_enabled`、`!address_registry_enabled` 共 39 处（只删 gc.zig 内的；跨文件常量本期不动）；15 个 `X: if (Y_enabled) T else void` 字段改为 `X: T`（gc.zig:2232-2409、3475）；gc.zig:29 注释「roughly 270 gates」改为实情 | 常量恒 true |
| 5 | `Phase.cycle` 枚举值（无用点） | grep 零命中 |

自验：`zig build check`；`zig build test`；`zig build test -Doptimize=ReleaseSafe`；`zig build smoke`。行为不变的证明：`zig build zjs` 后 `./zig-out/bin/zjs --gc-stats /tmp/gcgap-fixed/splay.js` 的 `collection entries`/`destroyed counted objects` 两行与 main 一致。

## L2 安全网入门禁

| # | 改什么 | 位置 |
|---|---|---|
| 1 | 新 step `test-gc-stress`：同一 `unified_tests` 产物再加一个 `addRunArtifact`，`setEnvironmentVariable` 设 `ZJS_GC_STRESS=1`、`ZJS_GC_VERIFY_MINOR=1`、`ZJS_MINOR_AUDIT=1`；先测耗时，**≤10 min 挂 checkpoint-gate，否则挂 engine-production-gate** 并在 step 描述写明耗时 | build/tests.zig:63 附近；build/gates.zig:120/138 |
| 2 | 新 mise task `test262-stress`：以 `ZJS_GC_STRESS=1` 跑 `zig build test262-check`（或等价 run-test262 调用），输出到 `reports/test262-stress/`（目录由 driver 建，lane 只加 task 不跑） | mise.toml |
| 3 | `liveBytes()` / `committedLiveMilli()` 每 major 的全块遍历改为仅在 `detailed_reports` 为真时执行；否则 `last_report` 两字段置 0 并在 `--gc-stats` 输出里标 `n/a` | gc_trace_stw.zig:763-767 |
| 4 | `--gc-stats` 的「incremental subphase ns totals」与「incremental STW phase totals」口径对不上（splay 上 finish 段 117ms 而子相位合计 ~7ms）：查明子相位是否只记最后一轮，改成累计或在标签里写清「last cycle」 | gc_trace_stw.zig / gc_concurrent.zig stats |

自验：`zig build test-gc-stress` 全绿并报告 wall 时间；`zig build checkpoint-gate`；`./zig-out/bin/zjs --gc-stats` 输出两行口径一致。

## L3 三处可疑无屏障写的插桩审计

背景：静态阅读发现三处对已发布 owner 的 slot 写入没有经过 `generationalBarrierValue` / `rememberOwnerForBulkWrite`，但 driver 在 `ZJS_GC_STRESS=1 ZJS_GC_VERIFY_MINOR=1` 下 15,543 次 minor 校验未复现。要一个**决定性结论**。

| 站点 | 写入 |
|---|---|
| A | object.zig:10141 `Object.setProperty` `.data` 覆写臂 `entry.slot = .{ .data = next_value }` |
| B | src/exec/array_ops.zig:6115 `putDenseArrayElementOverwriteOwnedFast` 容量内追加臂 `fastArraySlotAssumeCapacity(index).* = value` |
| C | src/exec/call_runtime.zig:3362 `ensureGlobalLexicalCell` 新 VarRef 写入 global 的 var_ref slot |

做法：
1. 加一个仅在 `gc.minor_audit` 为真时生效的探针 `gc.auditUnbarrieredStore(owner: *Header, value: JSValue, site: enum{A,B,C})`：条件 `owner 已发布 && !owner.young && !owner.remembered && value 有 header && value.young` 时计数并打印一次 site + owner class + 调用栈（`std.debug.dumpCurrentStackTrace`），生产构建为 comptime 空。
2. 在三处站点写入后各插一次探针调用。
3. 跑：`ZJS_MINOR_AUDIT=1` 下 Octane 九个负载（tools/perf/bench_v8/suite）+ `zig build test`（同 env）+ 一组定向脚本（driver 已写 /tmp/gcrev/append2.js、setprop.js，复制进 lane 的 .scratch）。
4. 结论三选一，每处单独：(i) 计数 > 0 → 真缺陷，给最小 JS 复现与修复（在站点补 barrier，barrier 形式与同文件邻近写入一致）；(ii) 计数 = 0 且能从代码证明该状态不可达（例如 owner 到达此臂前必经某个已带 barrier 的路径）→ 写出证明并把探针改成 `std.debug.assert` 形式的不变量留在 audit 构建；(iii) 计数 = 0 但无法证明 → 保留探针，报告为待观察。

自验：`zig build test`、`zig build test -Doptimize=ReleaseSafe`，三处探针在 ReleaseFast 生成的机器码里不存在（`objdump -d zig-out/bin/zjs | grep auditUnbarrieredStore` 为空）。

## L4 R3 根集诊断（T-R 开工）

目标：回答「生产二进制里保守扫描到底救了谁」。不改生产行为。

| # | 改什么 | 位置 |
|---|---|---|
| 1 | build 选项 `-Dzjs_gc_roots_diag=true`（默认 false）：为真时 `value_root_link_containers_only = false`（生产也链入标量 ValueRootFrame）；同时 `computeFullReachable` 的对照臂在该选项下改为「精确根 only」 | runtime.zig:501；build/config.zig；gc_trace_stw.zig:388 |
| 2 | conservative-only 归因：`ZJS_GC_VERIFY_MINOR=1` / `ZJS_GC_VERIFY_MAJOR_ALL=1` 下，每个仅由保守 word 保活的对象记录：word 来源（原生栈偏移 / 寄存器名）、命中的 header 类别、当时解释器 pc 所在函数名（若有）、是否为 interior 指针；汇总到 `--gc-stats` 新段「conservative-only census」：按来源桶计数 + 前 20 个最频繁 (函数, 类别) 对 | gc_conservative.zig；gc_trace_stw.zig:395-445 |
| 3 | 跑 diag 构建：Octane 九负载 + test262 全量（本 lane 用 `mise run worktree-init` 拿语料）在 `ZJS_GC_VERIFY_MINOR=1` 下，产出 `.scratch/R3_REPORT.md`：conservative-only 总数、按来源分布、前 20 站点、以及 F9 类（解释器 reg_sp 未提交操作数）是否出现 | — |
| 4 | 报告里对每个前 20 站点给出「补精确根的最小改法」一行（ValueSliceRoot / windowed / publish(pc,sp)） | — |

自验：`zig build test`（默认与 diag 两种）；diag 构建 test262 0 回归（保守扫描仍开，只是多了精确根，不应有行为差异）。

## 门（driver 亲跑）

L1-L3 合入前：`mise run batch-gate`；`zig build test-gc-stress`；test262 双模式对 main 0 回归；`--gc-stats` splay/EB/raytrace 三负载读数与 §L1 自验一致。L4 只合 build 选项与仪表，报告归档到 `docs/reports/tgc-r3/`。


## 执行记录（2026-09-03，driver）

### L1 僵尸删除 — 完成

- 三文件（gc_candidate / gc_snapshot / gc_marker）、corpse census 全套（文件、build 选项、root/cli re-export、`object_gc.zig` 钩子）、object_gc.zig 测试专用 mark 臂全套（`MarkMode`…`collectCycleMarkChildHeadersForTest`）、object.zig `CycleHotEdgeKind` 三张表、tests/core.zig 对应用例全部删除；gc.zig 内 38 处单行恒真门死臂 + `verifyIntrusiveList` 的 `!generation_enabled` 块 + 15 个 `else void` 字段 + `ConcurrentState` 的 void 臂 + `Phase.cycle` 删除；gc.zig:29 注释改为实情。
- 文档对账：gc-invariants.md 重写（混合所有权 → 目标全 tracing）；gc-inventory.md 去 `markChildrenCold`/热臂守卫段、`value_root_link_containers_only` 定义更新；tracing-gc-design.md 加 2026-09-03 banner、`gc_marker.Worker` 段标已删；gc-v2-systemic-design.md 状态 DONE；tracing-gc-pause-plan.md 状态补合入日期。
- 行为不变证明：`--gc-stats` 三负载读数落在基线自身抖动带内（EB 基线两次 9627/236/9391 与 9674/260/9414，候选 9645/246/9399；raytrace 逐字相同）；`mise run stage0` 对 `shared-h_pre0/main-d944f26d` **PASS**，六负载 insn 比 0.9995-1.0012。

### L2 安全网 — 完成，两处偏离

- `zig build test-gc-stress`：同一 `unified_tests` 产物第二个 run step，env `ZJS_GC_STRESS=1 ZJS_GC_VERIFY_MINOR=fatal ZJS_MINOR_AUDIT=fatal`。**偏离 1**：新增 `fatal` 拼写（gc.zig `minor_audit_fatal` / `verify_minor_fatal`）——原三开关只打印不判红，作为门禁必须能 panic；`VERIFY-MINOR` 只对 precise 违规致命（conservative-only 违规是探针帧深度不同的固有噪音，见 gc_trace_stw.zig 注释）。耗时 55 s → 挂 **checkpoint-gate**。四个精确 interrupt-poll 算术用例在 stress 下 `SkipZigTest`（stress 改写 cadence）。
- `mise run test262-stress`：`zig build run-test262` 后以 `ZJS_GC_STRESS=1` 直接调 `run-test262 … -R reports/test262-stress`（`-R` 目录由 reporter 自建；.gitignore 加行）。**偏离 2**：不经 `zig build test262-check`，因为该 step 把 `-R` 硬编码为 `reports/test262-latest`。
- `liveBytes()/committedLiveMilli()`：`collectCycles` 末尾的两次全块遍历直接删除（`Report.block_live_bytes/committed_live_milli` 两字段无任何读者；`--gc-stats` 的「block heap … live …」行自己调用一次并由 gate_smoke_check.py 解析，保持不动）。
- 口径对账：两行都是全程累计（`+|=`），规格假设的「只记最后一轮」不成立；差额是**覆盖**缺口——finish 停顿里 `Collector.init`（remark 前）和 condemn 后的 `clearYoungState`/sweep-model 收尾/安全构建不变量检查没有子相位计时。新增 `phase_finish_init_ns`/`phase_finish_tail_ns`（Stats 尺寸 pin 376→392），并新打印一行「incremental subphase reconciliation」把 begin/finish 两侧 STW 总量减子相位之和的残差直接印出来。

### L3 三处可疑写 — A、C 为真缺陷已修；B 不可达；另揪出两处同类

探针 `Registry.auditUnbarrieredStore(owner, child, site)`：条件 `owner 已发布 ∧ !owner.young ∧ child.young ∧ owner ∉ remembered 映射`；Debug/ReleaseSafe 与 `-Dzjs_gc_roots_diag` 构建武装，ReleaseFast 默认构建擦除（`nm zig-out/bin/zjs | grep auditUnbarrieredStore` 为空，diag 二进制为 1）。

| 站点 | 结论 | 证据 |
|---|---|---|
| A `Object.setProperty` `.data` 覆写臂 | **(i) 真缺陷，已补 barrier** | `/tmp/gcrev/siteA-variants.js` V1：`Iterator.prototype[Symbol.toStringTag]` 的 setter 作用于持有同名自有数据属性的老对象 → `iterator_ops.iteratorPrototypeAccessorSet` → `setProperty` → 探针 12+ 次命中。注意 `Reflect.set` 三参形式**到不了**此臂（reflect_ops.zig 对非数组走 `ordinarySetWithReceiver`），勘察员的最小复现建议有误。 |
| B `putDenseArrayElementOverwriteOwnedFast` 容量内追加臂 | **(ii) 不可达，探针留作不变量** | 唯一生产调用者是 tailcall_dispatch 的 `op_put_array_el_cold`，只在常驻 `op_put_array_el` miss 后到达；常驻处理器自己的追加臂（带 barrier）条件集是站点 B 条件集的**严格超集**（fast_array ∧ index==count ∧ new_count≤capacity ∧ canExtendFastArray ∧ (≤length ∨ length_writable)），且 `op_put_array_el_ta` 尾接的 receiver 是 TypedArray，过不了 `isArray()`；两张 colds 表均如此。Octane 14 + 六负载 + 单测 stress 探针 0 命中。 |
| C `ensureGlobalLexicalCell` 新 VarRef 写入 global | **(i) 真缺陷，已补 barrier（含回滚路径）** | `zjs -I /tmp/gcrev/lexvar-a.js /tmp/gcrev/lexvar-b.js`（a: `eval("var x = {}")`，b: `let x = 1`）探针 1 次命中，栈 `createRootGlobalClosureCell → ensureGlobalLexicalCell`。 |

`test-gc-stress` 门另外揪出两处静态阅读没找到的同类缺陷（`MINOR-AUDIT=fatal` 在 builtins.zig「constructor static prototype and accessor handlers keep their callee realm」用例上判红）：`Object.setCallSiteMetadata`（call-site 对象的 `callsite_function` 可为函数对象）与 `Object.setPromiseCapability`（成对写 resolve/reject 槽绕过了 `setOptionalValueSlot` 的 barrier）。两处均已补。审计的 `where=` 归因扩到 OrdinaryPayload 全部 14 个字段与 iterator-next 缓存。

### L4 R3 诊断 — 仪表落地，报告见 docs/reports/tgc-r3/

- `-Dzjs_gc_roots_diag=true`：runtime.zig `value_root_link_containers_only = !is_test and !diag`（生产链入标量 ValueRootFrame；`deactivate` 在 diag 下 LIFO 违规 `@panic` 而非 assert）；`ZJS_GC_VERIFY_MAJOR_ALL` 在 diag 下也生效（原只在 sticky 实验构建解析）。
- **偏离 3**：`computeFullReachable` 的对照臂**没有**改成「精确根 only」——精确臂在前、保守臂在后本来就是一次探针里的两个对照，归因必须发生在保守臂（精确 trace 已到不动点时，回调进入前未标记、`shadeExact` 后已标记 = 直接保守根）；改成精确 only 反而丢掉归因。census 记 (解释器函数名, header kind, class, word 来源桶, 指针形状, young, native) → 固定 1024 槽计数表（溢出计 dropped，打印），外加来源/指针/kind/寄存器直方图与 transitive 计数；`--gc-stats` 新段「conservative-only census」+ top 20。
- 生产扫描环路零成本：word 来源发布只在 diag 构建编译（`diag_word` threadlocal，comptime 门）。

### 门禁运行中揪出的其它缺陷（2026-09-03 下午）

| 缺陷 | 发现方式 | 修复 |
|---|---|---|
| realm 懒填槽无屏障：`JSContext.ensureInitialShapes` 五个初始 shape、`setCachedFunctionProto/setCachedPromiseProto`、`cached_values[]`（15 处写入者经 `setOptionalValueSlot(global, …)` 把 **global** 当 owner 记 remembered，而槽的 owner 是 realm；minor 在老 realm 处停住，年轻值被 condemn） | diag 单测 `Promise executor reuses the active Machine while reactions remain roots` 在 realm teardown 处 shape rc 断言（`DIAG destroyShape` 打印证明初始 shape 在 realm 之前被 tracer 单独 condemn/销毁） | context.zig 五个 barrier；object.zig 新 `setCachedRealmValue`（owner=realm header）替换全部 15 处 + `throw_type_error_intrinsic` 写入；删 `cachedRealmValueSlot/cachedThrowTypeErrorIntrinsicSlot` |
| 块 cell 的 weak husk 被 bitmap 二次 condemn；husk 被最后一个 WeakRef 释放后 cell 仍在 doomed 位图 / 缓存字里，FR 清理作业分配可拿到该 cell，drain 再销毁新对象 | `ZJS_GC_STRESS=1` 下 run-test262 于 `FinalizationRegistry/prototype/register/this-does-not-have-internal-target-throws.js` SIGSEGV（gdb：`destroyFromHeaderSlow` 读 `shape_ref=0x0`，对象 `weakref_count=1`） | gc_block_heap.zig `Block.forgetDoomedCell`（`freeSmall` 时清 doomed 位与缓存字，仅在块处于 doomed 列表时）；gc_trace_stw.zig 两处 `takeDoomedCell` 循环跳过 `!cellAllocated ∨ headerIsReclaimableWeakHusk` |
| `SortEntryRootWindow.deactivate` 对空接收者 deactivate 从未 activate 的帧 | diag 构建 test262 与 typescript 负载 `ValueRootFrame LIFO violation` panic（生产 containers-only 让 deactivate 静默返回） | array_ops.zig：未 activate 则不 deactivate |

前两项都是 **混合所有权** 的直接后果（realm/shape rc 与 tracer 双重生命周期、husk 是 rc 时代的弱引用语义），S1/S4 会把机制整个拿掉；这里只补最小修复让 S0 门禁绿。

### 门禁复跑（第二/三轮）再揪出的缺陷

| 缺陷 | 发现方式 | 修复 |
|---|---|---|
| `regExpSymbolReplaceGeneric` 先把全部匹配收进 Zig 堆上的 `matches` 列表再逐个调 replacer；列表里的 result/matched/captures/groups 没有任何根（堆内存对保守扫描不可见），replacer 里的 minor 把 `groups` 回收 | `ZJS_GC_STRESS=1` test262 `RegExp/named-groups/functional-replace-global.js` SIGSEGV（Debug runner：`objectFromValueTrustedExpression` 断言） | string_ops.zig `ReplaceMatchRoots` root provider（与 module_graph 的 `ContinuationRoots` 同款）覆盖整个列表生命周期 |
| realm→shape 边在 incremental marking 期间的屏障：`shadeForConcurrentMark` 对「owner 与 target 都是 rc 管理 kind」直接 `invalidateBarrier()` 让整轮 major 失败，失败以 `PayloadMarkFailed→OutOfMemory` 冒到 JS | 加了 realm 初始 shape 屏障后 test262 `harness/asyncHelpers-throwsAsync-same-realm.js`、`staging/sm/Promise/bug-1289040.js` 与 diag 单测报 OutOfMemory；Debug runner 新增 `ZJS_T262_ERRTRACE=1` 打印错误返回栈定位 | gc.zig：target 为 shape 时同步 shade（标记 shape、把其 proto 入队），与 `Collector.shade` 队列模式对 rc 管理 kind 的处理一致；target 为 realm 的情形维持失败 |
| realm 屏障在未发布 realm 上触发会把半构造的 realm 记进 remembered 集 | 同上排查过程 | context.zig / object.zig 的 realm 屏障加 `heap_accounted` 守卫（发布 trace 覆盖构造期边） |

`test262-stress`（`ZJS_GC_STRESS=1` 全量）在这些修复后从两处 SIGSEGV 收敛为 2 个非崩溃错误。

### 裁决门读数（第三轮，2026-09-03 晚）

| 门 | 读数 |
|---|---|
| `zig build test`（Debug） | 2519 passed / 6 skipped / 0 failed |
| `zig build test-gc-stress`（`ZJS_GC_STRESS=1 ZJS_GC_VERIFY_MINOR=fatal ZJS_MINOR_AUDIT=fatal`） | 2515 passed / 10 skipped / 0 failed，无 UNBARRIERED-STORE、无 precise 违规 |
| `zig build test -Dzjs_gc_roots_diag=true` | 2519 passed / 0 failed（首次全绿） |
| test262 script，默认构建 | **0/49778** |
| test262 script，diag 构建 + `ZJS_GC_VERIFY_MINOR=fatal` | **0/49778** |
| test262 script，`ZJS_GC_STRESS=1`（8 线程） | 2/49778：`built-ins/Iterator/zip/basic-shortest.js`、`zipKeyed/basic-shortest.js` TypeError（单线程 Debug runner 下同一文件通过；8 线程 stress 复现，GC 时机相关，记入 stress 基线 `reports/test262-stress/` 待查） |
| test262 module（`-m` 全体当模块跑，仅参考） | 2690（基线 zjs 经 `--engine` 为 3402；该模式不是 0 回归门） |
| `mise run stage0` vs `shared-h_pre0/main-d944f26d`（最终树） | **PASS**：insn 比 deltablue 0.9998 / EB 0.9986 / pdfjs 0.9997 / raytrace 0.9995 / regexp 1.0001 / splay 1.0038（记账不裁决；第一次复跑 splay 1.0125 STOP 是 husk 守卫放在每具尸体的 drain 循环里所致，改放到 `destroyFromHeaderSlow` 慢臂后回到 1.0038） |

