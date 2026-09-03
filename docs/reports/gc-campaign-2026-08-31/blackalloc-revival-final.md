> 注：原始二进制证据在临时 worktree，未入库。

# gc/blackalloc-20260831 复活线报告（Phase A + Phase B）

## 结论

**KILLED — 不合并，不放宽预注册线。**

Phase A 已由 commit `0894f072` 正确闭合：EB 崩溃被归因到
**black-allocation 块级豁免的浮动垃圾悬空边洞**，修复为 finish pause 内的
`shadeBlackAllocationSurvivors`，并有确定性回归测试。Phase B 的 N=4 pacing
也通过 correctness、EB 20 连跑、EB/其余四负载 instructions 与 EB peak，
但至少三条钉死的验收线失败：

1. splay instructions ratio = **1.004386706**，要求 `<= 0.96`；
2. splay committed peak 的 ABBA 有效腿出现 **+4.032258%**，要求 `<= +3%`；
3. splay mark-queue overflow 的有效 candidate 腿为 `9, 8`，历史同仪表
   baseline 为 `8`，最大值 `8 -> 9`，不满足“不升”。

当前分支 HEAD 仍是 `0894f072`；Phase B 仅有两个未提交文件：
`src/core/gc_block_heap.zig`、`src/tests/core.zig`。未改 Phase A 修复或回归，
未 push、未合 main。

## Phase A：归因、否证与修复（commit 0894f072）

### 复现与现场

- 原 candidate 脱离 perf、CPU19 直跑 20 次有 **8/20 SIGSEGV**，否证
  “perf 是必要条件”。
- sticky + `VERIFY_MAJOR_ALL` oracle 12 次有 3 次 SIGSEGV，但
  **0 precise condemnation violation**；禁 publication skip 的 oracle 对照
  0/8 崩溃，publication skip 是必要条件。
- Debug 将下游 SEGV 变成 `collectMinor -> drain -> visitValue -> shadeExact ->
  headerMarked/isCycleCandidate` 断言；Release core 还出现空 Shape 与错误
  ModuleRecord dispatch。三类栈均表示 tracer 正在踩已经释放/复用的 child。
- `ZJS_GC_BLACKALLOC_DANGLE_AUDIT=1` 在每次 EB finish 实测
  **20,486--26,963** 条悬空边，主要形态是 bytecode function -> young var_ref。

### 被否证的假设

1. **perf 必要**：直跑 8/20 崩，否证。
2. **hot-reuse 清戳使当前块丢豁免**：当前黑块不能进入 hot list；minor 在
   marking 期被双重关闭，否证。
3. **epoch 与 free-time clock 撞号**：奇数小 epoch、0、单调 clock 三态互斥，
   否证。
4. **sticky mark 前提破坏**：sticky 是默认关闭的 comptime 实验项，原崩溃
   二进制未启用，否证。
5. **minor 错扫 ex-black cell**：minor 只走 per-cell young bitmap，finish 会清
   young，否证。
6. **major 精确错杀可达对象**：full oracle 0 precise violation，否证。
7. **RC kind 队列条目自身悬空**：入队 kind 与 baseline 相同；最终栈与 dangle
   audit 证明是 retained owner 的 child 悬空，不是第一因。

### 命名机制

`attachFunctionCaptures`/js_closure2 的合法历史构造顺序是：先发布闭包对象，
再把 capture array 挂上并裸填 var_ref。baseline 的 published-grey queue 会在
finish 前整体 trace 该对象，因而这个 store 历史上不需要逐 slot barrier。
black allocation 的 publication skip 撤掉了这张安全网：

1. 闭包 P 在当前 epoch 黑块中发布，不 mark、不入 grey queue；
2. publication replay 发生在 capture fill 之前，无法看到后装边；
3. P 在 finish 前死亡，根重播到不了它；
4. block exemption 保留 P 的 cell，但未 shade 的 var_ref/target 被同周期 condemn；
5. P 留下悬空边；后续 conservative root scan 从栈残值复活 P 并 trace 悬空 child，
   产生随机 kind dispatch、断言或 SIGSEGV。

机制名：**black-allocation 浮动垃圾悬空边洞**。

### 修复与回归

- `shadeBlackAllocationSurvivors` 在 finish pause 中、最终根重播 drain 之后、
  weak/ephemeron/condemnation 之前，遍历当前 epoch 黑块；对已发布且未标记的
  retained cell 做 `shadeExact` 并 drain。合同变成“豁免保留 cell，同时保留
  child graph”，不再依赖所有 publish-then-fill 路径都已有 barrier。
- 回归测试：`black-allocated floating closure keeps its post-publication capture
  graph across finish`。它复刻 published-then-fill closure，释放 closure 唯一引用，
  finish 后断言 closure cell、capture target 和 target mark 均存活；删除 survivor
  trace 时确定性失败。
- Phase A 修复后 EB direct 20/20、perf 20/20 零崩，dangle audit 0。
- Phase B 最终 N=4 二进制又独立完成 perf 20/20，见下文。

完整 Phase A 原始报告：`.scratch/PHASE_A_REPORT.md`。

## Phase B：committed pacing 实现

### 机制

最终候选为预注册范围上界 **N=4**：

- `src/core/gc_block_heap.zig:59-65`：每 size class 最多四个当前 epoch 黑块；
- `gc_block_heap.zig:643-646,683-686`：8 个 size class 的冷计数数组在
  `beginBlackAllocation` 一次性清零；没有 per-publication counter/RMW；
- `gc_block_heap.zig:709-727`：只有 empty block 的 0->1 激活边界占用配额；
  配额满时把 `free_time_ns` 保持为 0，不盖当前 epoch；
- 之后 `markPublishedYoungClassified` 的既有 `headerIsBlackAllocated` 判定为 false，
  Object 自动走老 `publishGreyCold`，没有新增正确性分支；
- `gc_block_heap.zig:770-785` 的 active block 在 `popCell` 失败前始终被优先填充，
  因而已有未满 allocation-current block 先于下一次 empty activation；populated
  hot-reuse block 仍永不打黑戳。

正确性退化是单向的：配额内仍由 Phase A survivor trace 保护；配额外完全回到
baseline published-grey。旧黑戳随 `endBlackAllocation` 的 epoch 前进立即过期，
下周期 `snapshotAllDoomed` 正常获得 condemnation 资格；没有改变 Phase A 的
survivor trace 或 snapshot exemption。

### 针对性测试

`src/tests/core.zig:9356-9397` 的
`block black-allocation pacing caps empty activations per class` 确定性验证：

1. 周期前已经 active 的老块必须先填满且不变黑；
2. 恰好 N 个后续 empty activation 获得当前 epoch；
3. 每个黑块在下一块打开前被填满；
4. 第 N+1 个块不带黑戳，从而发布漏斗回退 `publishGreyCold`；
5. heap 全量不变量验证通过。

`test-core`：463 passed / 6 skipped / 0 failed。

### N 搜索结果

| N | splay black skips | splay peak（单腿筛选） | splay insn | 结论 |
|---:|---:|---:|---:|---|
| 2 | 70,880 | 260,046,848 B | 1.0067 | insn 失败 |
| 4 | 124,612--134,351 | 260,046,848--270,532,608 B | 1.004386706（最终六负载账） | insn、peak、overflow 失败 |

N=4 是范围内保留 black skips 最多、最有利于 instructions 的端点；它仍比 0.96
差 4.44 个百分点，故 N=3 不可能靠“少一个黑块、更多 publishGreyCold”恢复该缺口，
没有为已被端点支配的中间值再跑昂贵全门禁。不得把 N 扩到 4 以上，因为这会在
看到结果后放宽预注册搜索范围。

brief 的第二方向也已确认是现状：finish 结束推进 epoch，旧黑块下一周期不再豁免，
浮动垃圾只被 block exemption 延迟一个周期。它不能消除本轮观测到的 superblock
峰值，不能作为未实现的“免费修复”宣称通过。

## 验收线逐条对账

### 1. correctness、全测、Phase A 回归、注入 — PASS

- `zig build check`：PASS（N=2 与最终 N=4 均执行）。
- 最终 `zig build test --summary all`：
  **2494 passed; 6 skipped; 0 failed; 0 filtered；9/9 steps succeeded**。
  Phase A floating-closure 回归与 Phase B pacing 测试均实际运行。
- `ZJS_GC_BLACKALLOC_INJECT=1 zig build test --summary all`：按预期 SIGABRT，
  精确命中：
  `GC black-allocation invariant violated: current-epoch block reached condemnation`。
- `git diff --check`：PASS。

证据：`.scratch/phaseb-final-zig-build-test.txt`、
`.scratch/phaseb-final-blackalloc-injection.txt`。

### 2. EB perf 20/20 + 六负载 PMU — PASS（但不能挽救整刀）

最终 candidate：`.scratch/phaseb-n4/bin/zjs`，SHA256
`2e8cd63c88c187efec55816592fbb2a56d71a8de3a045ff9bca6ebf11186b8ad`。
PMU baseline：`.scratch/zjs-baseline-7c067f01`，SHA256
`386b9f84a297dad4c6baa52ae53f058cb112addbf451e74eab7ca3f55893e806`。

EB 20 连跑使用 CPU19、`/tmp/zjs-host-heavy.lock`、
`armv8_pmuv3_1/instructions/`。20 腿全部 rc=0、stdout 完整、counter 有效、无
SIGSEGV/SIGBUS/ERROR：**20/20**。score 是计时派生值，会在 3950--4053 间波动；
验收依据是成功结果行 + `----` + exit/counter，不硬编码某个 score。

六负载 fixed-work、2 samples/engine、ABBA 的 instruction ratio（candidate/baseline）：

| workload | ratio | 线 | 结果 |
|---|---:|---:|---|
| splay | **1.004386706** | <=0.96 | **FAIL**（下节终裁） |
| earley-boyer | 0.999380204 | <=1.003 | PASS |
| deltablue | 0.999904042 | <=1.003 | PASS |
| regexp | 1.000207949 | <=1.003 | PASS |
| pdfjs | 0.998678624 | <=1.003 | PASS |
| raytrace | 1.000980330 | <=1.003 | PASS |

本表只使用 retired instructions；cycles/wall 不作证据。原始账：
`.scratch/phaseb-final-pmu-six.json`、
`.scratch/phaseb-eb20-n4/corrected-summary.txt` 与同目录逐腿文件。

### 3. splay instructions <=0.96 — FAIL

最终 ratio **1.004386706**，比硬线 0.96 高 **4.4387%（ratio points）**。
Phase A survivor trace 是本次 candidate 的组成部分，未复用 v1 的 0.9284。
N=2 筛选为 1.0067，N=4 已是范围内更有利端点，仍无可行交点。

### 4. splay / EB committed peak <=+3% — splay FAIL，EB PASS

按 brief 在 detached `7c067f01` baseline 测量树只回填与 candidate 同口径的
`peak_committed_bytes` 字段、三处 committed 增长更新点和 CLI 打印；不改变 GC
策略。baseline peak binary SHA256：
`bf326c71d8d7b954355fc878e23d56a19547146445e4a8b904e17aed2aeeda41`。

CPU19 + host lock 的 stats ABBA：

| workload | B1 | C1 | C2 | B2 | max(C)/max(B)-1 | 结果 |
|---|---:|---:|---:|---:|---:|---|
| splay | 260,046,848 | 260,046,848 | 270,532,608 | 260,046,848 | **+4.032258%** | **FAIL** |
| EB | 43,671,552 | 43,794,432 | 41,697,280 | 43,302,912 | +0.281373% | PASS |

splay 两个 paired ratios 的 median 是 +2.016129%，但 committed **peak** 是安全包络；
一条完整、同口径、同锁的 fixed-work candidate 腿已超过 +3%，不能挑较低腿宣称
“峰值通过”。原始账：`.scratch/phaseb-peak-abba/`。

### 5. queue overflow 不升；其余四负载 <=1.003 — 部分 FAIL

- 其余四负载 instructions 全部 PASS（见表）。
- EB overflow 为 0。
- splay 历史同仪表 baseline 为 8；N=4 ABBA candidate 两腿为 `9, 8`。
  最大值 `8 -> 9`，故“不升”不能宣称通过。原始 candidate 腿：
  `.scratch/phaseb-peak-abba/splay-candidate-{1,2}.txt`；baseline 原账：
  `.scratch/baseline-splay-gc-stats.txt`。

## 负值解释与交接

literal per-class N=2--4 cap 确实把 committed 压下来，但它通过把绝大多数
black publication 退回 published-grey 达成：splay skips 从 Phase A 无 pacing 的
约 139 万降到 N=4 的约 12.5--13.4 万。于是 v1 的指令收益几乎全部消失，queue
overflow 也重新出现；同时一次有效 splay 腿仍因分配/回收切片交错达到 129 个
superblock（270,532,608 B），超过空间线。这里没有“再调一点 N”的窗口。

因此维持 **KILLED**。Phase A 的根因修复与回归是独立正确性成果，但当前复活线
要求整把 black-allocation + pacing 同时过全部门；本 lane 不自行拆分、合并或 push。
