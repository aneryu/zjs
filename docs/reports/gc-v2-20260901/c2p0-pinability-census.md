> 注：原始二进制证据在临时 worktree，未入库。

# C2-P0 pinability census：S4 分岔报告

日期：2026-09-01
分支：`probe/pinability-census-20260901`
基点 / 收尾 HEAD：`main@8aba23bd07c49aac1fd4f4e33d81da1a6d7283bf`

## 0. 结论

**C2 object-only nursery：有条件 GO；整块 pin：NO-GO；现在不能裁成 pin ABI。**

六负载里，真正被 conservative word 直接命中的 young block-object bytes
只有 object-nursery live 的 **0.00064%--0.0633%**。因此若 C2 能做到对象级
self-forward / pin，六负载仍有至少 **99.9367%** 的对象 live 可撤离，pinability
本身不是 evacuator 的阻断项。

但「命中一个对象就 pin 整个 64 KiB block」把这点直接 pin 放大了
**205--383 倍**（按各负载双腿均值）：除 splay 外，加权损失撤离面
**8.46%--24.24%**；EB minor 单列 **24.66%**，全 collection p95
**54.72%**。所以 C2 的下一步只能是 **object-only + object-granular pin / self-forward
shadow**，不能先落 cheap whole-block pin，更不能把它当生产形态。

独立 exact oracle 在 DeltaBlue / RegExp / PDF.js / RayTrace / splay 完成；EB
逐 minor full-trace 腿在 **900 s** 超时，失败已归档，未用同源 mark bit 补数。
完成的五个负载中，young-hit word 的 exact 重合从 RegExp 的约 **8.21%** 到
PDF.js 的 **89.17%**、splay 的 **90.70%--93.48%**，不是一个统一分布。
这说明 C1 对 exact-heavy 负载有明确 headroom，但不能仅凭五负载把全局路线改裁
为 C1；RegExp 是显著反例，EB 还缺独立 exact 数据。

`conservative-only` 只表示独立 precise full trace 未覆盖该命中，不证明它是仍会
被 native 代码读取的真 raw root。尤其完成 oracle 的 RegExp / PDF.js / splay
conservative-only hit 全来自普通栈而非寄存器 spill；在做 temporal lifetime / host
API 语义归因前，**不进入 pin ABI 决策**。

## 1. 仪表与口径

临时仪表只在 `ZJS_GC_PIN_CENSUS=1` 下开启，位于
`gc_conservative.scanWords` 与 `Collector.seedConservativeRoots` 的观察缝：

- AArch64 `SpillImage` 的精确地址区间标为 `register_spill`，其余扫描槽标为
  `ordinary_stack`；每个 candidate 仍走原 `forEachGcObjectAt`。
- observer 在原 shade 前记录 word→header 边，然后**无条件调用原 shade**；诊断
  map OOM 只把 collection 标成 `incomplete=true`，不改变 liveness 或 collection
  错误结果。本轮所有完成腿 `incomplete=0`。
- carrier 分类为 block cell / large / standalone / slab。large 与 standalone 在
  header 级互斥（large 优先）；word 可在 one-past 边界同时命中两个 allocation，
  因此 word 类百分比不是互斥直方图，不能强求和为 100%。
- 同一 collection 内按 header 去重。增量 major 的 begin / final remark 共享同一
  去重集合并只输出一行；minor 使用独立序号。
- `pinned_young_block_bytes` 是直接命中 distinct young block object 的 live bytes；
  `affected_block_young_live_bytes` 是这些 64 KiB block 内所有 young block-object
  live bytes；`block_pin_span_bytes` 则是物理 block span。三者没有混算。
- S4 object-only 分母固定为 `young_block_live_bytes`，不再用所有 young carrier
  稀释 block pin 损失。

### 1.1 exact oracle 为什么分成第二臂

生产 minor 的真实顺序是 exact seeds → conservative scan → closure drain；扫描当下
的 mark bit 不是 full exact closure。把它叫 `exact_duplicate` 会与既有
`ZJS_GC_VERIFY_MINOR` oracle 同源混淆。

因此 exact 臂先按**生产时序完成真实 native scan并保存 word→header 边**，再运行
`ZJS_GC_VERIFY_MINOR=1` 的独立 full-reachability trace，最后按其
`.precise / .conservative_only` authority 回填 word/object 分类。oracle 自己制造的
栈残值不会回流到本 collection 已冻结的 pin surface。增量 major 没有这份独立
oracle，相关 mark-at-window 列只作诊断，不参与 nursery 的 exact 裁决。

这也是为什么本报告没有把此前 splay `1/12 minors` 与 raw hit object 机械比较：
前者数“real minor 判死但 full trace 保守可达”的 condemned disagreement；本轮数
每个扫描 word 直接命中的对象，分母不同。

## 2. 测量合同与身份

六负载 fixed-work 各两条完整腿，`taskset -c 19`，runner 强校验 affinity 恰为
`{19}`，全程持有 `/tmp/zjs-host-heavy.lock`。普通 census 最终轮开跑 / 收尾 CPU19
idle 均为 **100.00%**；exact splay 补腿同样为 100.00% / 100.00%。这是诊断时间
归因级运行，不作吞吐性能判决，也没有 PMU ratio。

普通 pin-surface 权威件：

- binary：`031312c3fb15d4b322c912b97a5e4ae69e1a013a93fab5eb00f0fe63576fa9b5`
- summary：`.scratch/raw/c2p0/summary-pin-surface.json`
- summary SHA-256：`ad354545cefbfd300b714899f2c6397246a7c38a8914fe3d99dc9429affc7bf7`
- 冻结 binary：`.scratch/bin/zjs-c2p0-census-031312c3`

exact-oracle 部分腿 binary：
`c21f28d69dd1ea08fd4425024a9868ac78f3a1221a891545230f0b16a59c690f`
（`.scratch/bin/zjs-c2p0-exact-c21f28d6`）。EB 失败记录为
`.scratch/raw/c2p0/earley-boyer-exact-timeout.txt`，SHA-256
`bed05408c0c8f2658a04905cc8af9a176cf69e62f1004a21033e4edb328cd932`。

fixed-work SHA-256：

| workload | SHA-256 |
|---|---|
| DeltaBlue | `55a3f692271d7f54b80b903669d4d4ddb07c40b8697801849bf2763aafeac48a` |
| RegExp | `67f770174b9743502612835b656d033179f279a39848b985765a12516e301d46` |
| PDF.js | `b6328cef73513b04621a1f77bfb191f67a8fe9967a927d675751645074e38c94` |
| RayTrace | `c70e5303a58a4fc39eb64634b1c5451758f0874956a2c4ee839afd0b2b42e45f` |
| Earley-Boyer | `9f5a58a178cc4a50b0bfb291dea0a7c00c608c8cc951262359bd59b250d6813d` |
| splay | `35ebfb84c40827b7ef9908d9338903f3e1dc42beeef6c549118d4f148c36e4a7` |

## 3. 六负载 pin surface

下表均为两腿平均；`direct pin` 与 `whole-block loss` 的分母都是累计
`young_block_live_bytes`。`minor loss` 单列真正的 nursery collection；`all p*`
按每 collection 的 whole-block loss 取分位数。

| workload | collections/leg | elapsed/leg | candidate hit | direct pin | whole-block loss | 放大 | minor loss | all p50 / p95 / p99 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| DeltaBlue | 589 | 19.02 s | 2.35% | 0.05397% | **12.94%** | 239.8× | 12.74% | 13.14 / 20.76 / 25.10% |
| RegExp | 165 | 5.23--5.28 s | 2.97% | 0.02890% | **8.46%** | 292.9× | 8.46% | 7.42 / 21.60 / 32.13% |
| PDF.js | 161 | 3.18--3.21 s | 2.34% | 0.05094% | **12.34%** | 242.2× | 12.59% | 12.95 / 21.08 / 27.38% |
| RayTrace | 2623 | 13.66--13.72 s | 2.11% | 0.04583% | **9.41%** | 205.2× | 9.41% | 6.70 / 15.57 / 23.83% |
| Earley-Boyer | 9677--9682 | 33.68--33.81 s | 1.91% | 0.06330% | **24.24%** | 383.0× | **24.66%** | 17.69 / **54.72** / **71.28%** |
| splay | 18 | 2.54--2.56 s | 1.65% | **0.000642%** | **0.146%** | 227.2× | 3.15% | 0.75 / 100 / 100%* |

`*` 每个负载的 startup incremental major 都可能只有 7--27 KiB young block live；
命中其 2--3 个 block 就得到 98.8%--100% 的 collection max。splay 仅 18 个
collection，nearest-rank p95 因此就是这个 startup max；它不应覆盖加权 0.146%
和 minor 3.15% 的主口径。相同原因，RegExp 的 major-weighted loss 是 100%，但
只对应一个 7248-byte startup population。

从直接对象面读，六负载可撤离比例为 **99.9367%--99.9994%**；从 whole-block
面读，EB 只剩约 **75.76%**，其余（除 splay）约 **87.1%--91.5%**。这就是
object-granular C2 与 whole-block C2 的分岔。

### 3.1 来源 span 与 carrier

下表仍为普通 census 两腿平均。`spill hit` 是全部 hit word 中来自 register spill
image 的比例；最后四列按 word 是否命中该 carrier，one-past 多命中会重叠。

| workload | spill hit | block cell | standalone | large | slab |
|---|---:|---:|---:|---:|---:|
| DeltaBlue | 4.44% | 61.83% | 27.69% | 0 | 10.48% |
| RegExp | 2.02% | 49.48% | 42.88% | 8.57% | 6.88% |
| PDF.js | 5.35% | 43.75% | 39.92% | 7.94% | 8.56% |
| RayTrace | 3.72% | 58.72% | 28.55% | 0 | 12.73% |
| Earley-Boyer | 5.47% | 51.53% | 33.25% | 8.99% | 12.61% |
| splay | 2.71% | 49.75% | 36.04% | 0 | 14.21% |

普通栈是绝对主来源。独立 exact 回填后，minor conservative-only word 中 spill
占比为 DeltaBlue **20.00%**、RayTrace **0.284%**，RegExp / PDF.js / splay
均为 **0%**。这给 C1 的优先普查面是 stack/native frame，不是额外 ABI register
scanner。

## 4. 独立 exact overlap

下表只列 `ZJS_GC_VERIFY_MINOR=1` 独立 full-reachability oracle 完成的腿；百分比
分母是 minor 的 young-hit words。一个 one-past word 可同时命中 precise 与
conservative-only 两个对象，所以两列可略微超过 100%。对象数是 collection 内
去重后再跨 collection 求和，故不是终态 distinct heap objects。

| workload | exact-duplicate words | conservative-only words | exact young objects/leg | conservative-only young objects/leg | minor rows/leg |
|---|---:|---:|---:|---:|---:|
| DeltaBlue | 73.46% | 27.09% | 3185 | 1838 | 559 |
| RegExp | **8.21%** | **91.79%** | 64 | 650--651 | 164 |
| PDF.js | **89.17%** | 12.09% | 834 | 162 | 154 |
| RayTrace | 73.54% | 27.50% | 12586 | 7065 | 2619 |
| splay | **90.70%--93.48%** | 6.52%--9.30% | 21--24 | 2--3 | 6 |
| Earley-Boyer | **unavailable** | **unavailable** | — | — | 900 s timeout，0 完整腿 |

exact oracle 是诊断，不是可常驻机制。普通 EB census 每腿约 34 s；逐 minor full
trace 的 exact 腿 900 s 仍未完成，即至少 >26×。失败腿没有进入表格，也没有用
“扫描当下已 marked”补值。

## 5. 按 §7 的路线建议

1. **低 direct object pin → C2 object-only nursery 可行。** 六负载最坏仅
   0.0633% young block live 被直接 pin；下一可撤销动作应是 young-only allocator
   shadow + object-level self-forward/pin 计数，不写完整 evacuator。
2. **whole-block pin 不通过。** EB 加权损失 24.24%、minor 24.66%、p95 54.72%；
   这不是“pin 率低”。若 C2 原型只能冻结整块，应停在 shadow，不进入生产语义。
3. **高 exact duplicate → C1 有定向价值，但当前不是全局替代裁决。** PDF.js、
   splay、DeltaBlue、RayTrace 的 exact 比例高，适合优先做 frame/handle migration；
   RegExp 91.79% conservative-only，EB 又无完整 oracle，阻止“全负载都可由 C1
   轻易消 pin”的结论。
4. **高 true native root → pin ABI：证据不足。** oracle 的 conservative-only
   仍混有 stale residue 与真 native root。下一 census 应对 RegExp（第一优先）及
   DeltaBlue/RayTrace 做跨 collection lifetime、native window / host-call-site
   归因；只有反复存活且能映射到真实 raw-pointer API 的对象才进入 pin/handle ABI
   裁决。
5. **JSC-comp 不由本 census 触发。** 本轮证明的是 pin granularity 问题，不是
   永久非移动的 committed/live 收益；结构降法仍由 S3/J1 数据单独定价。

## 6. 验证、失败保留与清理

- `zig build check`：仪表各次口径修正后均通过；最终 instrumented source 通过。
- 定向 `zig build test-core`：**471 passed / 6 skipped / 0 failed**。
- 唯一一次收尾全量：
  `set -o pipefail; zig build test 2>&1 | tee .scratch/raw/c2p0/zig-build-test.log`
  → **2505 passed / 6 skipped / 0 failed**；日志 SHA-256
  `c1db845264487e342380440385784504da6bb5d0a1a150b7f369a69429593709`。
- 定向测试覆盖：(a) spill-image 边界；(b) 同 word 同时含 exact / conservative
  header；(c) header 去重与 young/block byte 账；(d) 独立 oracle 回填保持 word
  级两类重合。
- EB exact 900 s timeout 按失败归档；没有删除或缩短 workload，也没有用 partial
  output。
- 收尾选择：**移除仪表**。`src/core/gc_conservative.zig`、
  `src/core/gc_trace_stw.zig` 已恢复到 `main@8aba23bd`；临时 runner 已删除。
  `git diff --check` 通过，`git diff --exit-code HEAD -- src/...` 为空，`git status`
  tracked clean。仅 `.scratch/` 内保留报告、raw、失败记录与冻结诊断 binary。
- 无 commit，无 push。
