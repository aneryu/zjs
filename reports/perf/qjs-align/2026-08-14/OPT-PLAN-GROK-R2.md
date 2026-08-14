# OPT-R2 计划 — grok 第二批：性能通道三 lane（回收 / 字符串 / tail_call）

日期：2026-08-14。制定者：driver。执行者：grok。状态：**计划定稿，未派发**。
前批 = AUDIT-EXEC（正确性通道，17/17 落地，§10 审查记录）。本批是**性能通道**，
每条 lane 按 PARITY-LEDGER 准入规则**先报预计 zoo 价值**。

## 0. 价值预算（先报后做）

当前 geomean ≈ 0.9295（0.9278 基线 × audit-exec +0.18%）。追平需 +7.78%。

| lane | 方向 | 预计 zoo 价值 | 准入通道 |
|---|---|---:|---|
| **H1** mandreel G2 回退回收 | 自引入回退的修复 | **+0.09 pp**（mandreel +1.33% 恢复） | 维护通道（回退回收不受 0.3pp 登记线约束） |
| **H2** 字符串 concat 策略对齐 | pdfjs string+regexp +70M 区 | **0.1–0.3 pp**（不确定，先频次） | 机制银行（0.3–0.5 组包目标） |
| **H3** tail_call/tail_call_method 发射 | deltablue 调用边界 595.6M（其赤字 80.4%） | **0.2–0.5 pp**（投机） | 正式候选 |

合计乐观 0.4–0.9 pp。**诚实声明**：本批仍是增量收敛，不是追平方案；
若 H2/H3 都失败，按 PARITY-LEDGER 触发路径 A/B 架构决策，不找第九个微机制。

## 1. 公共契约（继承 AUDIT-EXEC §1，四处修订）

继承：worktree 隔离／禁碰 `test262.conf`、`test262_errors.txt`、`reports/**`、`docs/**`、`tools/perf/**`／
test262 裁决归 driver（worktree submodule 为空）／镜像 qjs 机制并注 `qjs:<行号>`／
`lint_anti_goals.sh` 退出 0／ReleaseSafe 必验／`[PROGRESS]` 行／⛔禁做清单（bind [[Prototype]]、
08·#48/#50+13·K8、X-23/X-24 等裁决）。

**修订（全部来自上批教训）**：

1. **允许且要求逐条目 commit**：grok 可在自己的 lane 分支上 `git add` + `git commit`
   （**仍禁** checkout/reset/merge/rebase/stash/push）。上批 G2 五条目 squash 成单 commit
   直接阻碍了 mandreel 回退归因——**一个语义改动 = 一个 commit** 是硬要求。
2. **测量协议**：grok **不跑任何 zoo/PMU**。需要测量裁决时，把候选二进制复制到
   `/tmp/<lane>-bins/<标签>` 并在总结中列清单，打 `[PROGRESS] <lane> AWAIT-MEASURE <标签列表>`，
   然后**继续做不依赖该结果的部分**；driver 串行测量后把结果写回
   `/tmp/<lane>-bins/RESULTS.md`，grok 轮询该文件继续。
   driver 侧工具：单基准 `run_zoo_compare.py --benches <b> --samples 16 --cpu 19`（须外部
   `taskset -c 19` 包住，runner 是证实制）；打包验收**逐基准过 lineage 判据**
   （三 pad 同号且 |中位|>离散 → SEMANTIC），geomean 只是汇总不是裁决。
3. **频次先行**（测量合同第 9 条）：任何「每次 X 都付」的静态断言，动手前先要动态频次。
   计数器构建只供频率（历史：计数器构建不 cost-neutral），成本读数一律取生产二进制。
4. **zsh 陷阱**：编排循环一律 `bash -c`（`set -- $pair` 在 zsh 不分词，上批踩过）。

## 2. Lane H1 — mandreel G2 回退回收（CPU 6；足迹 `src/core/object.zig`、`src/exec/object_ops.zig`、`src/exec/call_runtime.zig`）

**背景**：audit-exec 的 G2（`b9f5731e`+`192a097d`）在 mandreel 上 −1.33%（单基准二分坐实，
±16 samples CV≈0.25%），同 lane 在 TS 上 +1.71%。回退未归因到条目。

**Phase 1 — 拆分定位**（半天）：
1. 在 worktree 里把 `b9f5731e` 的 diff 按条目拆成**五个独立 commit**：
   X-10（含 `192a097d` 依赖方）→ X-07 → X-08 → X-09 → X-02。
   校验：五 commit 合计 diff 与 `6d8295ce..192a097d` 中 G2 足迹部分**逐字节一致**
   （`git diff` 对比，不允许任何「顺手改进」）。
2. 每个 commit 点构建 ReleaseFast 二进制 → `/tmp/h1-bins/{base,x10,x10+x07,…,full}`，
   打 `AWAIT-MEASURE`。driver 跑 mandreel 单基准梯子（16 samples）定位回退条目。
   嫌疑先验排序：**X-07 整数键 Set 冷路径重构**（mandreel 大量整数键写）＞
   **X-10 依赖方**（arguments dense-Get 臂、rest/iterator/keys 数组换真原型）＞ X-02/08/09（纯冷）。

**Phase 2 — 忠实路径成本对齐**：
- 对命中条目，逐指令对照 qjs 同路径（X-07 → `quickjs.c:9839-9853` retry2 循环形状；
  arguments → `:8296-8303` exotic 分派位置），把 zjs 调到同等成本。
  **⚠️ 臂序就是性能**（历史教训：同一份逻辑三个位置三种结果）——注意新增检查在链中的位置。
- **红线：不得回滚语义、不得加 qjs 没有的门。** qjs 在相同语义下不亏，
  所以答案一定存在于「qjs 怎么把同样的检查做便宜的」。
- 验收：mandreel 恢复到 base ±噪声（driver 测），X-02/07/08/09/10 的 difftest 全部仍 IDENTICAL，
  TS 的 +1.71% 不得丢（同轮测 TS）。

## 3. Lane H2 — 字符串 concat 策略对齐（CPU 7；足迹 `src/core/string.zig`、`src/exec/value_ops.zig`、`src/core/value_format.zig`）

**背景**：MECHANISM-REGISTRY 的 `rope-strict-equality`（9.6M，pdfjs 赤字 4.38%）被
「上游 rope-population mismatch 未命名」阻塞：zjs 在热操作数上比 qjs **多产生 1.090M 个 rope**。
审计 §4.4 已核实一条结构性差异：**qjs `JS_ConcatStringInPlace`（`quickjs.c:4671`，调用点
`4712`/`19770`）在 refcount==1 且容量足够时对扁平串原地增长；zjs `tryAppendStringInPlace`
（`value_ops.zig:1230-1238`）只接受 rope lhs**——扁平串 append 在 zjs 走 rope 化或重分配。
这很可能就是 rope 多产的上游。

**Phase 1 — 命名上游**（先频次）：
1. 在计数器构建上跑 pdfjs 语料，分桶统计 concat 形态：
   lhs=rope / lhs=flat·rc==1·容量够（qjs 会原地）/ lhs=flat 其它；对齐 qjs 的 1.090M 差值。
2. 产出一页机制命名报告：差值的 X% 落在哪个桶。若「flat·rc==1」桶 ≥ 差值的一半，
   Phase 2 开工；否则打 `[PROGRESS] H2 BLOCKED <分桶结论>` 交 driver 改道
   （候补方向：concat 阈值、flatten 时机、substring 表示——registry 列的六问逐一排除）。

**Phase 2 — 镜像 `JS_ConcatStringInPlace`**：
- 给 zjs 扁平串补原地增长路径，条件逐格镜像 qjs（refcount、容量、宽度匹配；qjs:4671-4712）。
  ⚠️ zjs string 是 FAM 定长——「原地」需要分配器容量协议支持；先查 `memory.zig` 的
  slab 尺寸类，若 FAM 结构性做不到原地增长，**写决策简报交 driver**（这触及表示层架构，
  不擅自改 string 内存布局）。
- 验收：rope 生成计数（计数器构建）显著下降向 qjs 靠拢；pdfjs 单基准 driver 测；
  **splay/typescript 是字符串重用户，负对照必须同测**。

## 4. Lane H3 — tail_call / tail_call_method 发射（CPU 8；足迹 `src/parser.zig`、`src/bytecode.zig`、`src/resolve_*.zig`；⚠️ VM 侧文件动前必须报 driver）

**背景**：审计 §4.3 首条——`tail_call`/`tail_call_method` 全仓**零发射点**，
且 `src/tests/parser.zig` 有 **5 条 `expectEqual(0, countOpcode(...))` 正面断言把「不发射」固化**。
但 **VM 侧 handler 已完整存在**（`tailcall_dispatch.zig:2096/2110`，冷表 `:805-806`，
`tailCallReuse` 帧复用路径就位）——缺口只在编译器。qjs 对 `return f(...)` 发 tail_call
（先拆帧再调），deltablue 每轮 7.06M 次全部走 zjs 的完整 call+return。
deltablue 赤字 0.93pp 的 80.4% 在调用边界。PARITY-LEDGER 旧条目：方向有利但未达精度。

**Phase 0 — 侦察（只读，产出实施简报，driver 批准后才写代码）**：
1. qjs 发射条件全集：`quickjs.c` 里 `OP_tail_call`/`OP_tail_call_method` 的发射点与
   门条件（何时**不能**发射：try 块内？finally？generator/async？derived ctor？直接 eval 帧？
   逐条列出行号）。
2. zjs 侧现状：终结符集合里已有识别逻辑（`parser.zig:7256/11864-11865/12006-12007/12020-12021`、
   `cfg.zig:934-935`、`resolve_variables.zig:1993-1994`、`resolve_labels.zig:1966-1967`）
   ——盘点这些「识别但不发射」的位点各自缺什么；handler 语义与 qjs 逐格对照
   （尤其**帧拆除时机 × 异常栈可观察面**：tail_call 后抛异常，backtrace 少一帧是 qjs 行为，
   zjs 必须一致而不是更好）。
3. 与 codex 协调面：handler 文件是 codex 活跃区（stack3 `42b6160f` 刚动过 `tailcall_dispatch*.zig`），
   **发射侧不碰它们**；若 Phase 1 发现 handler 需修，先报 driver。

**Phase 1 — 发射 + 语义**：
- 按 qjs 条件发射；**删掉那 5 条「恒零」测试断言并替换为与 qjs 对齐的正面断言**
  （这是唯一允许动测试期望的点，逐条在 commit message 里说明）。
- 帧/generator 改动纪律：**全量 test262 是唯一 oracle**（driver 亲跑），ReleaseSafe 必验
  （历史：构造帧 teardown.simple 只有 ReleaseSafe 抓到 abort）。
- 语义验收自查面：backtrace 深度（`Error().stack` 在 tail 位置）、`new.target`、
  arguments 别名、finally 内 return、深递归不再爆栈（qjs tail_call 使 `return f()` 递归 O(1) 栈？
  ——**先在 qjs 上实测**这一点，zjs 对齐实测行为而非想象）。
- **发射覆盖对账**：deltablue 上 `tail_call*` 动态次数须达到 qjs 的同量级（qjs 7.06M），
  用 profile 计数对照，防「发了但门太紧只发出 1%」。

**Phase 2 — 定价**（driver）：deltablue 单基准 16 samples → 若 ≥+1% 再打包 3 pad zoo
  逐基准 lineage 判读。richards/raytrace 调用密集，可能连带受益，同轮观察。

## 5. 排期与并行

三 lane 足迹互不相交，可同时派发；H3 的 Phase 0 只读、Phase 1 须等 driver 批准简报。
建议顺序敏感度：H1 最先出结果（半天量级），H2/H3 各 1–2 天。
driver 测量点：H1 梯子（~20 min）、H2 pdfjs+负对照（~15 min）、H3 deltablue+打包（~1 h）。

派发机制沿用 AUDIT-EXEC §7（grok headless + PID/DONE marker 驱动器），
worktree 命名 `worktree-grok-h{1,2,3}-*`，分支 `grok/opt-r2-h{1,2,3}`。

## 6. 明确不做（本批）

- **44 条热频 zjs-only 机制的批量删除**：X-10 的教训是单条实测才 +0.1pp 量级且可能带回退，
  批量删除的测量成本（每条一轮）远超当前值得投入；等 H1 建立「拆 commit + 单基准梯子」
  的低成本归因流水线后再议。
- X-40 异常漏斗、批次二 Tier A 余量：正确性通道，另立批次。
- readfwd-harness（A1/A2）：driver 自己的线，不派 grok。
- 布局、NaN-boxing、调用边界弥散停顿：**已封板，不重启**（PARITY-LEDGER）。

## 7. 结果表（执行后填写）

| lane | phase | 状态 | 实测 |
|---|---|---|---|
| （待执行） | | | |
