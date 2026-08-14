# OPT-R4 计划 — grok 第四批：解释台账守恒闭合战役（诊断批）

日期：2026-08-14。制定者：driver。执行者：grok。状态：**定稿，待派发**。

## 0. 为什么有这一批（用户质疑成立）

用户对 R3 后的「残差=弥散、路径 A 扫空」结论提出质疑：「一定是还没有找到问题，
不然没办法解释这个差距」。复查账本后**质疑成立**——「弥散」只被证明于
调用边界 stall 一个切片，被不当推广成全部残差的性质。账面上挂着四块**从未闭合**的解释缺口：

| # | 缺口 | 账面出处 | 量级 |
|---|---|---|---:|
| G1 | **TS 时间盒折差**：fixed-work cyc **1.0817x** 而 zoo 分数 0.826（=1.211x），低估 10.16%，归因「重复运行 GC 相位」后**从未追查**；EB/RT 无此签名（1.2435 vs 1.253 / 1.3225 vs 1.287），**TS 特有且其它基准从未排查** | HANDOFF §裁决指标 | **≈+0.7pp**（若闭合） |
| G2 | pdfjs 赤字 **60% 未命名机制**（≈137M） | js-level 战役遗留 | ≈+1.0pp 区间 |
| G3 | TS fixed-work 内 **782M cyc 残差未归因** | TS-88% 复验 | 与 G1 部分重叠 |
| G4 | **五个基准从未归因**（zlib/richards/box2d/splay/gbemu 合计 34.3% 净赤字） | PARITY-LEDGER | ≈+2.7pp 区间 |

R3 的「JS 级干净」仍然有效——它只证明**没有第二个 initialize.apply**，
不证明引擎级解释已完备。**A/B 裁决 DEFERRED**：解释台账闭合之前不做架构决定。

## 1. 战役判据（本批的宪法）

1. **守恒闭合**：每条 lane 的产出是一张台账，命名桶之和 = 实测总超出 **±10%**。
   到不了 ±10% 就没完工；**残差是发现，不是终点**——残差最大的地方就是「还没找到的问题」住的地方。
2. 频率来自计数器构建（只供频率），单位成本来自生产二进制（差分微基准/per-opcode census 含
   qjs 共享标签尾）。fixed-work insn 是首选度量（三 pad 离散仅 0.014-0.031pp，布局免疫）。
3. 诊断测量授权同 R3：各 lane 绑自己的核（见下表），同一对照同核 ABBA ≥8 samples，
   CPU 19 归 driver；`bash -c` 防 zsh 分词；二进制凭据绑 sha256。
4. src/ 只读；计数器 patch 留 lane worktree 不合并；发现的候选只登记不实施。
5. 已封板方向不重启（调用边界弥散 stall／布局／NaN-boxing／tail_call／rope 表示／IMPL-TEARDOWN），
   但**允许台账把成本归到封板区**——封板的是「再投工程」，不是「不准记账」。
6. **VERIFIED-LEDGER 是强制对照参考**：
   `/home/aneryu/worktree-impl-audit/docs/qjs-align/IMPL-DIVERGENCE-2026-08-13/VERIFIED-LEDGER.md`
   （已两轮核查）。每当 lane 要命名一个机制/解释一个桶，**先查对应子系统的已核实差异**，
   LEDGER.md 产出中引用条目号（如 §4.2「数组容量增长」）；反向亦然——
   若某已核实差异能解释你的桶，优先用它而不是新发明假设。
   重点清单：**§4.2 常量与阈值**（尤其内存增长类）、**§4.4 zjs-only 机制**（44 条热频）、
   §4.3 死代码表（防把不可达代码当活机制归因）、178 条「微观相同」（别在上面开实验）。

## 2. Lane R4-T「时间盒折差」（CPU 5，**头号 lane**）

**问题**：zoo 分数=时间盒内重复迭代的吞吐。若 zjs 的每轮耗时随轮次**漂移上升**
（堆老化/GC 步进/表增长），分数会比 fixed-work 单位成本差——这正是 TS 的 12% 落差形态。

1. **签名普查**（半天）：12 个落后基准逐个测 fixed-work cyc 比（单轮完整执行，两侧同核 PMU）
   vs 现成 zoo 分数比，产出「折差表」。折差 >3% 的基准全部标出。
2. **TS 迭代曲线**：harness 让 benchmark 在进程内重复 N 轮（模拟时间盒），记录每轮 wall/cyc，
   两引擎并排画轮次-耗时曲线。看形态：线性漂移=堆老化；台阶=GC 周期；平坦=折差另有原因
   （warmup？分数协议差？score 解析口径？——逐一排除）。
3. **GC 对账**：每时间盒内 GC 触发次数/暂停总时长/回收字节，zjs vs qjs
   （zjs 侧找现成统计口，qjs 侧 `JS_ComputeMemoryUsage`/DUMP_GC 探一下有什么可用；
   实在没有就在计数器构建里加，频率专用）。
4. **机制命名**：若坐实 GC 相位，对照两侧触发策略与堆体积。
   **VERIFIED-LEDGER §4.2 已核实的预注册嫌疑（优先于新假设）**：
   - GC 阈值**初始**常量 ✅ 同（malloc_gc_threshold 256KB）⇒ 病灶只可能在**动态增长策略**
     （qjs GC 后按 malloc_size 重算阈值的公式 vs zjs 对应物，逐行对照）或**堆体积本身**；
   - **数组容量增长 ❌ 异**：100 元素 zjs 141 槽 2256B vs qjs 100 槽 1600B（+41%，
     `object.zig:5382-5387` vs qjs:9530-9534 的 3/2+slack）；
   - **属性容量增长 ❌ 异**：恒 ×2 vs 3/2+slack 回收（`shape.zig:17-22` vs qjs:5344/5334）；
   - shape hash 初始 4×（64 vs 16 桶）、atom hash 初始 2×、`JS_PROP_INITIAL_SIZE` 4 vs 2。
   预注册假设（可证伪）：**zjs 的容量策略使同负载堆大 20-40%，GC 每轮扫更多字节，
   重复负载下每时间盒 GC 成本占比放大**——验证=直接量两侧时间盒末的 live bytes 与
   GC 扫描字节总量。若堆体积同而 GC 次数多，才转向触发策略。

**闭合判据**：折差表全谱 + TS 的折差被分解到 ≤±3% 或明确命名。

## 3. Lane R4-P「pdfjs 守恒台账」（CPU 6）

对 pdfjs 建 per-opcode 加权差分台账：动态 opcode 频次（两侧 census）×
每 opcode 单位成本差（含 qjs 共享标签尾的 per-opcode 归因，方法照 EB 模板
`2026-08-12/EARLEY-BOYER-ATTRIBUTION.md`），加 native/regexp/GC 桶，
**Σ 必须落在 pdfjs 实测总超出 ±10% 内**。已命名的 dispatch +150M/string+regexp +70M/call +62M
作为交叉验证锚点。产出=残差从 60% 压到 ≤10%，新命名桶按值排序。
⚠️ pdfjs 也在 R4-T 的折差普查里——若它有时间盒折差，两 lane 的账要对得上。

## 4. Lane R4-C「TS fixed-work 残差 782M」（CPU 8）

接 `ts-88-percent-refuted` 的账：在 fixed-work（单轮）口径下重建 TS 全量守恒表，
把 782M 残差拆掉。已知锚点：teardown 10x +189M、slow property resolver +180M（X-10 后需重测）、
GC 是 zjs 优势（265M vs 682M）。与 R4-T 分界：**R4-C 管单轮内、R4-T 管跨轮动态**；
两边各自闭合后 driver 合账（单轮超出 + 跨轮折差 ≈ 分数差的全部）。

## 5. Lane R4-U「五基准首轮归因」（CPU 7）

zlib/richards/box2d/splay/gbemu 各出 bucket 级守恒表
（dispatch/call/property/arith/GC/alloc/string 七桶，粒度到桶不到机制），
每个 ±15% 闭合即可（首轮放宽）。目的=34.3% 净赤字从「从未看过」变成「已分桶」，
为下一批选主攻面。若某桶单独 ≥50% 赤字，升级为命名任务。

## 6. 交付与 driver 验收

- 每 lane `/tmp/r4-<lane>/LEDGER.md`（守恒表+残差声明+原始 JSON）+ `[PROGRESS]` 流水。
- driver：抽验 ≥2 条（CPU 19）→ 合账（R4-C+R4-T 的 TS 合账尤其）→ 更新 PARITY-LEDGER
  各基准「主要正赤字区域」列 → 视 G1 结果决定：若时间盒机制坐实，**它就是新主线**（候选批 R5）；
  若四账全闭合且确实全是弥散单位成本，A/B 裁决带着闭合的台账重新上呈。
- 预计：R4-T 1-1.5 天，其余各 1 天，四 lane 并行。

## 7. 结果表（执行后填写）

| lane | 状态 | 闭合度 | 头部发现 |
|---|---|---|---|
| （待执行） | | | |
