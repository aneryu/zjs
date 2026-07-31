# P7-70：测量合同修复与当前权威基线

- 日期：2026-07-31
- 基线：**`042e4962`**（Phase 7 集成提交）　对照：pinned qjs **`04be2460`**（VERSION 2026-06-04）
- 性质：仅测量工具与基线重采，**不改引擎生产代码**
- 数据产物：本目录 14 份；原始大体积样本在 `.zig-cache/perf/p7-70/`

`git diff 042e4962 -- src/` 无输出。

## 裁决摘要（三问三答）

**1. 当前真正 execution-dominant 的 top 10**（按绝对差，全部在独立验证轮中方向一致）：

| # | case | 子系统 | zjs−qjs | paired | 启动占比 | 验证轮 |
|---|---|---|---:|---:|---:|---|
| 1 | `uri_component_decode_4byte` | string/URI | +4.129 ms | 1.295 | 3.1% | 1.289 同向 |
| 2 | `uri_decode_4byte` | string/URI | +4.047 ms | 1.285 | 3.1% | 1.287 同向 |
| 3 | `arrow_call_loop` | call | +3.388 ms | 1.251 | 3.2% | 1.253 同向 |
| 4 | `call2_loop` | call | +3.362 ms | 1.247 | 3.2% | 1.250 同向 |
| 5 | `closure_call_loop` | closure/function-creation | +3.148 ms | 1.229 | 3.2% | 1.236 同向 |
| 6 | `array_map_callback` | array | +1.835 ms | 1.337 | 7.9% | 1.334 同向 |
| 7 | `vm_int_sum_large` | call | +1.518 ms | 1.121 | 3.6% | 1.119 同向 |
| 8 | `dense_array_write_read` | array | +1.139 ms | 1.255 | 9.5% | 1.252 同向 |
| 9 | `proto_read` | binding/property | +1.083 ms | 1.063 | 2.5% | 1.060 同向 |
| 10 | `global_read_loop` | binding/property | +0.960 ms | 1.079 | 3.6% | 1.083 同向 |

**2. 当前最大绝对执行成本子系统：`string/URI`，10.267 ms。** 其后是
`startup/bootstrap` 9.653 ms（suite 常量，非 case）与 `call` 9.038 ms（仅 5 个 case 承担）。
`regexp` 为 **−1.849 ms**，zjs 净赢。

**3. 下一条生产 one-cut：没有一个"已归因候选"够格，正确的下一步是一条归因线。**
详见第 6 节 —— 这是本报告唯一一处与提问预设不符的地方，据实回答。

## 1. 合同修复（P7-70A）

工具合同测试 **43/43 通过**，红队 **21/21 攻击全部被挡下**，且每一项都有具体证据
（exit code、`expectedExitCode`、`artifactWritten`、真实错误文本），不是"抛了异常即通过"。样例：

```
RT-01 request an odd sample count (--iters 5)
  defence : SampleBalanceError before any process is spawned; exit 3
  evidence: exitCode=3, artifactWritten=false
            "sample-count-odd: samples=5 is odd; ABBA cannot balance an odd sample count |
             first-position-imbalance: first-position counts are {qjs:3, zjs:2} |
             position-imbalance: treatment qjs appears 3 time(s) in position 0, expected 2.5"
```

四项 fail-closed 均已落地：样本数与顺序（偶数、首位次数相等、声明与执行记录一致、每 treatment
每序位次数相同）；CPU affinity（collector 与被测 child 的有效 affinity 必须**精确为 `{19}`**，
运行前后各验一次，"allowed-list 含 19"不算绑核）；`startupAdjusted` 降级为 diagnostic-only
（`startupAdjustedGeometricMean: null`，残差低于启动基线 IQR / 该 case total-time IQR /
预设最小分辨率时该 case 记 `unresolved`，不对近零分母做除法）；provenance 完整性
（缺任一必填字段即 `complete=false` / `headline=null` / 非零退出，且**门槛由仓库权威 policy 提供，
artifact 不得自带**）。

`BENCH_SESSIONS` / `benchInterleaved` 已重新落地，**默认关闭**、schema 带版本、
legacy 单进程路径逐字未变；本轮只做合同测试与短 case 诊断采样，未进入主 headline。

## 2. 权威基线（P7-70B/C）

二进制两份独立冷缓存构建，qjs 取两份独立身份，`binaries.sha256` 与 `.text` 尺寸均记录，
**未建 compiler state matcher**。

**启动基线在同一测量代次重采**（代次 `2026-07-30T17:59:14.142Z#2057153`）：

| 轮次 | qjs | zjs | 比值 |
|---|---:|---:|---:|
| run-a | 0.431 ms | 0.560 ms | **1.319** |
| validation-b | 0.460 ms | 0.584 ms | 1.268 |
| build-instance-b | 0.440 ms | 0.560 ms | 1.274 |

Phase 6 的 0.7907/0.9986 与 Phase 0 的 0.4324/0.5552 已在产物中显式标记 `doNotReuse`。
**启动不对称（约 1.27–1.32）在当前绑核二进制上复现**，它不是旧快照的采样瑕疵。

## 3. 分辨力分档（按当前实测重算，不沿用 23/52）

| 档位 | case 数 | paired geomean | 绝对差合计 | 启动占比中位 | stable | unstable |
|---|---:|---:|---:|---:|---:|---:|
| execution-dominant (≤20%) | **15** | **1.1548** | 23.884 ms | 3.2% | 15 | 0 |
| partially-resolvable (20–50%) | 8 | 1.2143 | 2.396 ms | 31.1% | 5 | 3 |
| startup-dominated (>50%) | **52** | **1.3399** | 8.605 ms | 92.5% | 30 | 22 |

历史的"23 可分辨 / 52 启动主导"未被沿用；当前是 **15 / 8 / 52**。

**不稳定性完全集中在低分辨档**：execution-dominant 15 个**全部 stable**，
而 startup-dominated 52 个里有 22 个 unstable。这本身就是分档判据有效的证据。

兼容口径 `all_75_paired_geomean = 1.2871`，标记 `compatibility_metric = true` /
`route_priority_metric = false`，只用于与 Phase 0/6 对照，**不得用于排序**。

## 4. 最重要的发现：启动主导档会把结论**反号**

5 个 amplified 诊断 case（qjs 执行时间放大到启动基线的 33–94 倍，全部 `targetMet`）：

| amplified | 源 case | qjs | zjs | **放大后比值** | 短 case 历史比值 |
|---|---|---:|---:|---:|---:|
| `amp_sort_bench` | `sort_bench` | 16.74 ms | 48.73 ms | **2.909** | 1.373 |
| `amp_map_set` | `map_set` | 16.28 ms | 24.08 ms | 1.479 | 1.356 |
| `amp_date_now` | `date_now` | 28.19 ms | 39.53 ms | 1.402 | 1.444 |
| `amp_string_slice3` | `string_slice3` | 14.91 ms | 18.95 ms | 1.271 | 1.449 |
| `amp_json_roundtrip` | `json_roundtrip` | 41.08 ms | **21.19 ms** | **0.516** | 1.532 |

两个方向的失真都出现了：

- **`json_roundtrip` 符号是错的。** 短 case 报 1.532（zjs 慢），放大后是 **0.516 —— zjs 快近一倍**。
- **`sort_bench` 被严重低估。** 短 case 报 1.373，放大后 **2.909**，是**当前全套已知最大的执行比值**，
  而它此前一直躺在启动主导档里。

`amp_sort_bench` 的测量质量很高：qjs IQR 0.048 ms、zjs IQR 0.073 ms，paired p25/p75 = 2.904/2.915，
启动占比 2.6%。

**结论：startup-dominated 档不是"低分辨的噪声"，而是会系统性地既高估又反号的区域。**
它的 52 个 case 与 1.3399 的 geomean 不具备任何路线价值。

## 5. 子系统绝对成本（当前 75-case）

| 子系统 | case 数 | geomean(全部) | 可分辨数 | geomean(可分辨) | 绝对差合计 |
|---|---:|---:|---:|---:|---:|
| **string/URI** | 13 | 1.3146 | 3 | 1.2846 | **10.267 ms** |
| startup/bootstrap | — | 1.2983 | — | — | 9.653 ms |
| **call** | 5 | 1.2041 | 5 | 1.2041 | **9.038 ms** |
| binding/property | 20 | 1.2604 | 7 | 1.1068 | 5.412 ms |
| array | 13 | 1.3169 | 4 | 1.2690 | 5.058 ms |
| closure/function-creation | 2 | 1.3135 | 1 | 1.2257 | 3.313 ms |
| number/dtoa | 12 | 1.3277 | 2 | 1.2284 | 2.383 ms |
| BigInt | 3 | 1.2922 | 0 | — | 0.577 ms |
| typed-array/ArrayBuffer | 2 | 1.4149 | 0 | — | 0.363 ms |
| regexp | 3 | 1.1114 | 1 | 0.7829 | **−1.849 ms** |

`binding/property` 覆盖最广（20 case）但可分辨子集 geomean 仅 **1.1068** —— 与 P7-10
「own-property read 已达或超过对齐，残差在写路径」一致。

## 6. 关于第三问的据实回答

问题预设是"选哪一个**已归因**候选"。按当前数据，**没有一个够格**：

- **已归因的两个 deferred 项都已被自身证据否掉。** P7-51A 的 shape-COW gate 动态冷
  （产品负载整轮 21 次 ≈ 8.9k cycles）；P7-42 的 push/derive 冗余界定在 5–8 cyc，
  且其所属的桥接线已按"分散控制税"关闭。`lnot` 线已永久关闭。
- **当前 top 项恰恰都没有归因。** top 10 里 6 项标注"已有归因=否"，
  其中最大的两项（两个 URI 4-byte decode，合计 **+8.18 ms**）完全没有归因线；
  call 家族三项合计 **+9.90 ms**，而 P7-41/P7-42 归因的是 **builtin→JS 桥**，
  不是普通 JS→JS 调用，不能挪用。
- **最大比值项是新浮出来的。** `amp_sort_bench = 2.909` 没有任何归因。

所以**正确的下一步是一条归因线，不是一刀**。按绝对成本与比值两个口径，两个候选：

1. **string/URI**（绝对最大，10.267 ms；两个 URI case 占 8.18 ms，比值 1.285–1.295，
   IQR 极小、验证轮同向）；
2. **Array sort**（比值最大，2.909，IQR 极小，但目前只有 amplified 诊断形态）。

我**不在本报告中做这个选择** —— 本线的职责到基线为止。

## 7. 本条线没有建立的东西

- **amplified 的绝对差不可与 75-case 的绝对差同表比较**（迭代规模不同）。
  `amp_sort_bench` 的 +31.99 ms 只在 amplified 语境内有意义。
- amplified 只覆盖 5 个 case，是从 startup-dominated 档中挑的；**其余 47 个启动主导 case
  是否也存在反号或低估，未测**。已知至少有一个（`json_roundtrip`）符号是错的，
  因此不能假定其余是对的。
- 未对 top 项做任何机制归因，也未采集 PMU 阶段数据。
- `src/` 全程未改，因此未跑完整 test262 作为工具逻辑前置；`test262-smoke` 与
  `test262/test` 条目数非零已确认，避免把缺 submodule 的响亮失败误记为引擎失败。
- 三个 partially-resolvable case 与 22 个 startup-dominated case 标记为 unstable，
  它们**不具备路线资格**，本报告未对其成因做诊断。
