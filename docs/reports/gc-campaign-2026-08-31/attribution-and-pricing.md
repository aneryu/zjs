> 注：原始二进制证据在临时 worktree，未入库。

# GC attribution and pricing report 2

日期：2026-08-31（Asia/Shanghai）
证据等级：**归因级**，用于决定是否开实验 lane；不是合并门禁或因果证明。

## 技术摘要

- **任务 1 没有触发 `<1%` 的桌面提前关闭。** 在 clean-main `7c067f01` 上，Splay 两腿的 marking 份额中位数 `S=6.3857%`，按 brief 的保守账 `S×0.70×0.40` 得整程上限 **`1.7880%`**。这只是把当前所有可消除等待都留给 8B header 之后的残余，因而是上界，不是收益预测。EB 对照上限仅 `0.2609%`。
- 继续做的两个来源归因没有找到一把 `≥1%` 的已命名“第二刀”：CPU 19 单核亲和下并行 marker 的 helper 数按实现恒为 `0`，所以 bitmap claim 竞争在这套受控测量中的份额为 **`0%`**；关闭 `popPrefetch` 的四对 ABBA 中位数为 instructions `0.999231×`、cycles **`1.002889×`**、L2D refill `0.994050×`（off/base），即现有预取只兑现约 **`0.289%`** 整程 cycles。结论是：**不能用总上限关闭整个 marking 侧，但这两个候选已被定价为不够一条 1% lane；若再开刀，需要新的来源证据。**
- **任务 2 按预注册判据 Reject，终结本模型的 gate 候选。** 六负载每条有效 major 区间的 `F` 都被 `[1.1,4.0]` 上界夹成 `4.0`。Splay 的 `F_med=4.0≥2.0` 满足，但 DeltaBlue/PDF.js/RayTrace 分别为 `4.0/4.0/4.0`，全部不满足 `≤1.4`；“当且仅当”条件失败。
- 本 lane 没有留下机制或统计代码。上一轮 KILLED 候选已归档到 `gc/minorfb-20260831` 的 `8e49a9fe`；本报告分支是 `gc/gc-attr-20260831`，基线/HEAD 为 `7c067f01`。

## 任务 1：Splay marking 侧不能被桌面关闭，但两个候选均不足 1%

### 口径与提前关闭判定

`marking_ns` 严格取 `begin-precise-seed + begin-conservative-seed + increment`；不把 begin 的 clear/retire 和 finish/destroy 算作 marking。`S=marking_ns/total_ns`。为检查口径敏感性，另给出更宽的 `whole begin + increment` 上界。已知的 `133 cycles/object`、`5.92 L2D refills/object`、`70%` memory-wait 锚点实际位于 `docs/tracing-gc-pause-plan.md` §4m；brief 中的 `docs/tracing-gc-design.md §4m` 是路径漂移。

| workload / leg | total (ms) | narrow marking (ms) | S | `S×0.70×0.40` | whole begin+increment S | corresponding upper |
|---|---:|---:|---:|---:|---:|---:|
| Splay 1 | 2402.053 | 151.634 | 6.3127% | 1.7676% | 6.4008% | 1.7922% |
| Splay 2 | 2374.185 | 153.342 | 6.4587% | 1.8084% | 6.5399% | 1.8312% |
| **Splay median** | — | — | **6.3857%** | **1.7880%** | **6.4703%** | **1.8117%** |
| Earley-Boyer 1 | 23751.925 | 221.522 | 0.9326% | 0.2611% | 0.9350% | 0.2618% |
| Earley-Boyer 2 | 23753.568 | 221.085 | 0.9307% | 0.2606% | 0.9329% | 0.2612% |
| **Earley-Boyer median** | — | — | **0.9317%** | **0.2609%** | **0.9339%** | **0.2615%** |

Splay 的 narrow 与 whole-begin 两种口径都高于 1%，所以没有执行 brief 的提前停止。8B header 不在本分支；把 **8B 前**测得的全部 marking 等待继续当作 8B 后可消除量，只会高估残余空间，因此 `1.7880%` 可作保守桌面上界，不能当作候选机制的预期收益。

### 消融 1：受控 CPU 19 跑法中不存在 helper claim 竞争

`gc_parallel_mark.Pool` 以进程 affinity mask 的 CPU 数决定 helper 数，`want=min(3, cpus-1)`；本合同用 `taskset -c 19`，可见 CPU 数为 1，因此 helper 数恒为 0。相位面板也没有任何 parallel slice/worker 计数。于是本次 Splay 的 block mark bitmap 共享行 claim 竞争归因是 **0% 整程、0% marking**。另开多核对照会改变 brief 钉死的 CPU 19 测量合同，故没有把不同拓扑混成一组数字。

### 消融 2：`popPrefetch` 兑现约 0.289% cycles，不解释 5.92 refills/object

只删除 `MarkStack.popPrefetch` 中的 `@prefetch`，生成临时 ReleaseFast 二进制，随即恢复源码。四对顺序是 `base/off, off/base, base/off, off/base`；所有测量均在 CPU 19 和 host-heavy lock 下。表内是 off/base：大于 1 表示关闭预取更贵。

| pair | instructions | cycles | L2D cache refill |
|---:|---:|---:|---:|
| 1 | 0.999657 | 1.003650 | 0.995296 |
| 2 | 0.998449 | 1.001576 | 0.988711 |
| 3 | 0.998828 | 1.005837 | 0.992984 |
| 4 | 0.999633 | 1.002127 | 0.995117 |
| **median** | **0.999231** | **1.002889** | **0.994050** |

关闭预取让整程 cycles 增加 `0.2889%`，同时 instructions 减少 `0.0769%`、硬件计数的 L2D refill 减少 `0.5950%`。后者与 cycles 方向相反，说明预取请求本身会进入该 refill 计数，不能把“少 refill”解释成更快。可守住的归因结论只有：当前 `popPrefetch` 有小幅兑现，但规模约 `0.29%`，不能解释或消除一条 `≥1%` 的第二刀。

## 任务 2：MU=0.97 的反馈公式在六负载全部夹到 F=4

### 定义与逐-major 采样

临时 stats-only ledger 以相邻两次**已完成 major**为区间：

- `L`：后一次 major 完成后的 settled `MemoryAccount.allocated_bytes`；
- `A`：两次完成点之间同一账户域内的毛分配字节（包含正向 resize/remap 增量）；
- `T_mutator`：完成点墙钟区间减去该区间 major 的 begin/increment/destroy/finish（full-STW 时用 full-STW）以及 minor-GC 时间；
- `g=A/T_mutator`，`s=L/T_major`，单位均为 bytes/s（表中显示 MiB/s）；`R=s/g`；
- `F_raw=0.03R/(0.03R-0.97)`；分母 `≤0` 时取 `4.0`，否则夹在 `[1.1,4.0]`。

每个负载跑两腿并合并逐-major 样本；最终报告的 `F` 是**先逐样本代公式并 clamp，再取中位数**，不是把各列中位数代回公式。Regexp 原 fixed-work 只有一个 major、没有区间样本，故仅为归因把同一 fixed-work 在同一 runtime 连跑 10 次；它不参与三项小堆硬判据。

| workload | samples (legs) | median L (MiB) | median A (MiB) | median mutator (ms) | median g (MiB/s) | median s (MiB/s) | R p25 / med / p75 | R range | F min / p25 / med / p75 / max | b≤0 / capped-to-4 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| DeltaBlue | 56 (28+28) | 3.413 | 78.035 | 638.340 | 122.4 | 2673.4 | 20.969 / **21.859** / 22.335 | 18.754–34.962 | 4 / 4 / **4** / 4 / 4 | 54 / 56 |
| Earley-Boyer | 526 (262+264) | 7.735 | 48.653 | 62.441 | 783.0 | 2271.0 | 1.496 / **2.915** / 3.565 | 1.182–6.815 | 4 / 4 / **4** / 4 / 4 | 526 / 526 |
| PDF.js | 12 (6+6) | 24.921 | 3736.026 | 484.383 | 7736.3 | 5672.5 | 0.658 / **0.725** / 0.761 | 0.612–1.746 | 4 / 4 / **4** / 4 / 4 | 12 / 12 |
| RayTrace | 6 (3+3) | 4.143 | 3171.906 | 3544.882 | 889.3 | 2066.9 | 2.119 / **2.310** / 5.208 | 2.014–6.554 | 4 / 4 / **4** / 4 / 4 | 6 / 6 |
| RegExp (10×) | 6 (3+3) | 10.255 | 6459.865 | 10145.519 | 635.5 | 6536.1 | 8.009 / **10.266** / 10.811 | 6.864–11.013 | 4 / 4 / **4** / 4 / 4 | 6 / 6 |
| Splay | 22 (11+11) | 161.512 | 287.051 | 190.438 | 1403.0 | 2553.5 | 1.254 / **1.952** / 6.001 | 0.899–9.079 | 4 / 4 / **4** / 4 / 4 | 22 / 22 |

`b≤0 / capped-to-4` 的后一个数包含前者。DeltaBlue 有 2/56 条记录分母为正，但未夹值仍大于 4；其余记录都是分母非正。两腿各自的 median F 也全部为 `4.0`，所以结果不是腿间漂移或 pooling 造成。

### Major 相位输入的中位数

| workload | begin (ms) | increment (ms) | destroy (ms) | finish (ms) | total major phases (ms) | median minor-GC in interval (ms) |
|---|---:|---:|---:|---:|---:|---:|
| DeltaBlue | 0.015 | 0.428 | 0.765 | 0.064 | 1.278 | 5.926 |
| Earley-Boyer | 0.024 | 0.703 | 1.847 | 0.104 | 3.336 | 4.893 |
| PDF.js | 0.028 | 1.905 | 2.573 | 0.206 | 4.901 | 11.777 |
| RayTrace | 0.017 | 0.349 | 1.506 | 0.144 | 2.010 | 212.870 |
| RegExp (10×) | 0.023 | 0.139 | 1.318 | 0.090 | 1.569 | 165.817 |
| Splay | 0.256 | 16.554 | 25.187 | 25.454 | 67.452 | 0.000 |

相位列分别取逐列中位数，因此不应机械相加重建 `total` 中位数；`total` 是每条记录先求和再取中位数。

### 预注册裁决：Reject

| hard condition | observed median F | result |
|---|---:|---|
| Splay `≥2.0` | 4.0 | PASS |
| DeltaBlue `≤1.4` | 4.0 | **FAIL** |
| PDF.js `≤1.4` | 4.0 | **FAIL** |
| RayTrace `≤1.4` | 4.0 | **FAIL** |

判据是 AND，三项小堆条件全失败，故 **固定 growth 2.0 换成该 MU=0.97 反馈值不值得进 gate：Reject，此事终结。** 这是对 brief 中这条特定公式、MU 和 clamp 的桌面否决，不外推成所有自适应增长策略都无效。

### sqrt 形态的定性方向

[Optimal Heap Limits for Reducing Browser Memory Use](https://arxiv.org/abs/2204.10455) 的形态可写作 `M=L+limit_factor×sqrt(gL/s)=L+limit_factor×sqrt(L/R)`：同一 `limit_factor` 下，live `L` 或分配速率 `g` 上升会增加 headroom，GC 速度 `s` 上升会减少 headroom，且变化是平方根而非线性。用本次逐-major 数据，`sqrt(L/R)` 的中位排序是 Splay `9619`、PDF.js `6327`、EB `1643`、RayTrace `1373`、RegExp `1024`、DeltaBlue `405`（单位 `sqrt(bytes)`）；方向上它能区分 Splay 与 DeltaBlue，但 PDF.js 也会得到较大 headroom。没有校准 `limit_factor` 和绝对内存成本，故只报告方向，不把它偷换成完整定价或 gate 结论。

## 可复核性、稳健性与限制

- 基线二进制 `.scratch/zjs-base-7c067f01` SHA-256 `6a90e5dd9a79b36ea25ad80ef193fdcde7c953c7612d2b3bdd8b3238447b1ff9`；no-prefetch 临时二进制 `9ac1e707787179cdbc161f8e1e8be75d56a3d447728b5fcdc814a236572d6287`；growth stats 临时二进制 `5a9af356353af8fc13e13ebe917589af423b2d88a81ddfbbf855d92686bccd03`。三者配置签名均为 `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`。
- fixed-work 源 SHA-256：DeltaBlue `55a3f692…`, EB `9f5a58a1…`, PDF.js `b6328cef…`, RayTrace `c70e5303…`, RegExp `67f77017…`, Splay `35ebfb84…`。完整哈希及原始逐-major 行保存在 `.scratch/task1-*.log`, `.scratch/task1-prefetch-*`, `.scratch/task2-*.log`。
- 所有读数在 `/tmp/zjs-host-heavy.lock` 下固定 CPU 19；编译放在其他 CPU。任务 1 时序是 Splay/EB/EB/Splay，prefetch 是四对平衡 ABBA；任务 2 第一腿正序、第二腿反序。
- 任务 2 的最终 12 份日志全部正常退出、`dropped=0`、collector failed count 为 0，且每腿 `major=samples+1`。Splay 两腿和 EB 第一腿在进程退出时有 `doomed_pending=true`，但表只消费此前已经完成并落样的 major 区间，不消费未完成尾巴。RayTrace 与放大 RegExp 各只有 6 个区间，分布精度低；它们的值离 `1.4` 很远，且 RayTrace 两腿均逐样本夹到 4，不改变硬裁决。
- 首批带 `--perf-json` 的 task-2 capture 因 stdout/stderr 同文件 seek 冲突覆盖开头而作废；表中只使用随后不带该选项、输出完整的重跑日志。
- 临时 ledger 会增加 stats-only 的分支/计数开销，因此时间只作归因级数据。它与 `L/A` 使用相同 MemoryAccount 域，避免分子分母跨域，但 `L` 不是对象-only census。这里没有实验设计足以支持机制收益的因果主张。
- 没画图：裁决只依赖六行精确阈值与逐样本 clamp，表格比图形更可审计。

## 收尾

- 归档：`gc/minorfb-20260831` → `8e49a9fe archive: KILLED minor-threshold-feedback candidate, see .scratch/REPORT.md (hard fails: EB MaxRSS +51.6%, deltablue insn 1.0035)`。
- 当前：`gc/gc-attr-20260831` at `7c067f01`；所有临时源码插桩与 `popPrefetch` 消融均已移除。
- 按 brief，本 lane 不实现机制、不运行完整 test262/gate；最终 `zig build check --summary all`：**3/3 steps succeeded**（`check-unified-tests Debug native success`）。
- 未 push。
