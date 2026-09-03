> 注：原始二进制证据在临时 worktree，未入库。

# GC v2 S2b：growth factor 含内核重定价

日期：2026-09-01
基点：`main@8aba23bd07c49aac1fd4f4e33d81da1a6d7283bf`
分支：`gc/s2b-growth-pricing-20260901`
性质：**纯测量；不改默认值；结论交 owner 终裁。**

## 结论

**推荐保持 growth 2.0，交 owner 终裁；本 lane 没有改默认值。** 两个收紧臂
都被 splay 硬线直接淘汰：

- 1.5 / 2.0 的 splay cycles(user+kernel) 为 **`1.073327`**，六负载
  cycles geomean **`1.010986`**；
- 1.75 / 2.0 的 splay cycles 为 **`1.030306`**，六负载 cycles geomean
  **`1.005913`**；
- 2.0 是 geomean 最优臂 `1.000000`，且与次优 1.75 相差 `0.5913%`，大于
  `<0.3%` 的同速省内存 tie-break 窗口。

growth 确实是当前唯一不靠 decommit/refault 的 committed 杠杆：在 splay 上，
1.75 把 median committed `281 -> 251 MiB`，MaxRSS/minflt 配对 factor 分别为
`0.863954 / 0.868693`；1.5 进一步到 `237 MiB`，factor
`0.783414 / 0.782229`。但代价分别是 splay cycles `+3.03% / +7.33%`，均越过
预注册的 `+1%` 底线。旧账中 1.75→2.0 是 cycles `-7.25%`；S1 后本轮直接量到
1.75/2.0 `+3.03%`，阻力明显缩小但尚未缩到可接受区。

## 1. 转段与账目输入

- S2a 已按三条冻结硬线 KILLED，并以
  `gc/s2a-block-lifecycle-20260901@cf4607f7` 归档：PDF.js checker-v2
  `2.0901x`、DeltaBlue minflt `2.054748x`、splay committed/live
  `1.209006x`。archive commit 正文引用 `.scratch/REPORT_S2A.md`，未 push。
- driver 判定 decommit 机制家族到头；S2a 不进入 main，因此本轮按改判直接在
  `main@8aba23bd` 定价。
- 差分账中 splay 最大项是 kernel/缺页足迹残差 **+9.04pp**，对应 trace
  committed `268 MB`、冻结 rc 峰值 `114 MB`。S1 后 splay cycles 已约
  `-4.6%`；本轮直接实测 1.75 相对 2.0 的新阻力，不把历史 user-insn 结论当现值。

## 2. 预注册裁决与测量合同

- 三个独立 ReleaseFast 构建把 `resetGCThreshold` 的编译常数分别固定为
  `1.5 / 1.75 / 2.0`；1.5 与 1.75 使用历史移位算式，2.0 是当前默认。
- 六个 vendored Octane fixed-work 负载；PMU 默认权限的
  `armv8_pmuv3_1/cycles/`（user+kernel）与 `instructions/` 同次采集。
- CPU 19 + `/tmp/zjs-host-heavy.lock` 排他；编译只用 CPU 0-14；测量前后
  CPU19 idle 必须 `>=95%`，且起跑前不允许 `zig` / `zjs`。
- 每个较低 growth 臂分别对 2.0 做 paired ABBA：常规负载每臂 4 legs，splay
  每臂 6 legs。ratio 均为候选 growth / 2.0 的同 sample 配对比值中位数；不删腿。
- `/usr/bin/time + --gc-stats` 同样按 paired ABBA 获取 minflt、MaxRSS、block
  committed/live、account peak 与 major/minor；每腿必须 exit 0、有数值完成行、
  failed collections=0、retirement abandons=0。terminal pending 不是 brief 的排除条件，
  settled/pending 分布和尸体字段逐腿保留，不能只挑 settled 腿。
- 预注册裁决：六负载 cycles geomean 最小的 arm 为推荐；若它与 2.0 差距
  `<0.3%`，改由 RSS/committed 较低者胜；任何候选 splay cycles 相对 2.0
  `>1.01` 直接出局。

## 3. 三臂产物身份

三个臂都从精确基点构建，分别使用独立 local cache 与 prefix；每个构建
`4/4 steps succeeded`，三个二进制都用 `-e 'print(21 * 2)'` 实跑输出 `42`。
`ZJS_GC_GROWTH_PERCENT`/headroom/min-threshold 在测量环境中均未设置。

| arm | 编译常数表达式 | `runtime.zig` SHA-256 | 二进制 SHA-256 |
|---:|---|---|---|
| 1.5 | `live + (live >> 1)` | `d725251755049a7821f793b8632baa7743bc1d1022177b65a82376b36925a302` | `acb37d38ee42f4e072f4a1f514469862ad6353120326932edfd596f50a4f0369` |
| 1.75 | `live + (live >> 1) + (live >> 2)` | `ada6e2576193d439563694d8fe703c0948d6ac41e5a6682b14bf3e809df48846` | `69e95738fd05423b117b0454f8aec170fd68079c9c4f5e0733d85144147892f5` |
| 2.0 | `live + live` | `45cffec9c3121860b3943cba78abcc8888c012f7f02db105d0d29b0b59a686e1` | `907b29dd72c1eba7abf25180953ccb1d50dae1d6998787ede24d19700004fd6f` |

三者实跑配置签名相同：
`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`。
构建后已把源码恢复到 2.0；恢复后的 `runtime.zig` SHA 与 2.0 构建源完全相同。

## 4. cycles / instructions 对账

下表 ratio 均为该 arm / 2.0；括号是 paired-ratio MAD。2.0 定义为 `1.000000`。
PMU 四份 JSON 的 effective affinity 都是 `[19]`，普通组首位计数
`qjs=10/zjs=10`，splay `3/3`，均 balanced。默认事件的 `perf_event_attr`
没有 `exclude_kernel`；对照的显式 `/u` 探针会显示 `exclude_kernel=1`，因此主读数
确为 user+kernel。

| 负载 | 1.5 cycles（MAD） | 1.5 insn | 1.75 cycles（MAD） | 1.75 insn | 2.0 cycles/insn |
|---|---:|---:|---:|---:|---:|
| DeltaBlue | `1.000951` (`0.001401`) | `1.001251` | `1.001150` (`0.001042`) | `1.000351` | `1 / 1` |
| Earley-Boyer | `1.003907` (`0.000820`) | `1.007545` | `1.003051` (`0.001056`) | `1.006100` | `1 / 1` |
| PDF.js | `0.998414` (`0.002327`) | `1.002176` | `1.000124` (`0.001877`) | `0.999754` | `1 / 1` |
| RayTrace | `0.995418` (`0.005844`) | `1.000201` | `0.994629` (`0.001345`) | `0.999885` | `1 / 1` |
| RegExp | `0.996133` (`0.009222`) | `1.000168` | `1.006607` (`0.002204`) | `1.000463` | `1 / 1` |
| **splay（6 legs/臂）** | **`1.073327`** (`0.004674`) | `1.037933` | **`1.030306`** (`0.002590`) | `1.017531` | `1 / 1` |
| **六负载 geomean** | **`1.010986`** | `1.008123` | **`1.005913`** | `1.003993` | `1 / 1` |

splay 的完整 paired cycles ratios 为：

- 1.5：`1.067533 / 1.072673 / 1.087470 / 1.079935 / 1.073981 / 1.069773`；
- 1.75：`1.022197 / 1.035032 / 1.030300 / 1.030312 / 1.029851 / 1.036147`。

两组没有一条侥幸落到 `<=1.01`；裁决不依赖单个离群腿。

## 5. minflt / MaxRSS / committed 对账

### 5.1 三臂绝对中位数

2.0 每个普通负载有两个配对窗口共 8 legs，splay 共 12 legs；下表 2.0 绝对值是
这两个窗口合并后的 median。低 growth 臂分别是普通 4 legs、splay 6 legs。
`C/L` 用 raw committed/live bytes 计算，不用尾板截断到千分位的展示值。

| 负载 | arm | minflt | MaxRSS MiB | committed/live MiB（C/L） | account peak MiB | major/minor |
|---|---:|---:|---:|---:|---:|---:|
| DeltaBlue | 1.5 | 5,904 | 16.75 | `4.945 / 0.829` (`5.966x`) | 6.993 | `64 / 502` |
|  | 1.75 | 6,548 | 18.66 | `7.414 / 1.440` (`5.150x`) | 7.850 | `40 / 542` |
|  | 2.0 | 7,451 | 21.01 | `8.242 / 1.628` (`5.063x`) | 9.057 | `28 / 560` |
| Earley-Boyer | 1.5 | 28,918 | 42.66 | `15.256 / 5.441` (`2.723x`) | 18.443 | `436 / 8,940` |
|  | 1.75 | 32,737 | 51.62 | `20.062 / 7.398` (`3.052x`) | 20.422 | `306 / 9,235` |
|  | 2.0 | 34,972 | 60.55 | `23.408 / 5.773` (`3.986x`) | 23.453 | `258 / 9,412` |
| PDF.js | 1.5 | 19,604 | 76.41 | `17.941 / 3.250` (`5.520x`) | 55.865 | `11 / 144` |
|  | 1.75 | 21,981 | 85.04 | `20.971 / 4.215` (`5.124x`) | 60.944 | `8 / 150` |
|  | 2.0 | 27,078 | 105.18 | `28.000 / 3.844` (`7.284x`) | 77.882 | `7 / 154` |
| RayTrace | 1.5 | 63,143 | 48.73 | `13.625 / 1.051` (`12.968x`) | 7.247 | `9 / 2,611` |
|  | 1.75 | 63,775 | 78.91 | `57.336 / 1.798` (`31.892x`) | 8.929 | `5 / 2,618` |
|  | 2.0 | 65,111 | 101.44 | `82.441 / 2.803` (`29.409x`) | 9.997 | `4 / 2,619` |
| RegExp | 1.5 | 8,018 | 35.15 | `18.000 / 0.862` (`20.884x`) | 11.611 | `2 / 163` |
|  | 1.75 | 8,353 | 34.11 | `5.219 / 0.607` (`8.596x`) | 13.217 | `2 / 163` |
|  | 2.0 | 7,255 | 32.15 | `18.000 / 1.213` (`14.842x`) | 10.970 | `1 / 164` |
| splay | 1.5 | 114,530 | 450.32 | `237.000 / 135.620` (`1.748x`) | 342.660 | `17 / 7` |
|  | 1.75 | 128,312 | 500.27 | `251.000 / 111.775` (`2.255x`) | 405.329 | `13 / 6` |
|  | 2.0 | 146,816 | 576.42 | `281.000 / 148.157` (`1.897x`) | 479.099 | `11 / 6` |

当前 fixed-work 的 splay 2.0 committed `281 MiB` 与差分报告的 `268 MB` 同量级，
也再次说明 growth 是 footprint 的真杠杆。它不是小堆结构比的解法：即使 1.5，
Delta/PDF/Ray 的 endpoint C/L 仍为 `5.966x / 5.520x / 12.968x`，没有触到
S2a 已关闭的 `<2.0` 结构目标。

### 5.2 相邻配对 factor

均为低 growth / 同窗口 2.0；低于 1 是减少。C/L factor 用 raw bytes 精算。

| 负载 | arm | minflt | MaxRSS | committed | C/L |
|---|---:|---:|---:|---:|---:|
| DeltaBlue | 1.5 | `0.792444` | `0.797249` | `0.600000` | `1.178331` |
|  | 1.75 | `0.650164` | `0.778090` | `0.855839` | `1.146624` |
| Earley-Boyer | 1.5 | `0.836628` | `0.713448` | `0.648076` | `0.880281` |
|  | 1.75 | `0.937470` | `0.832796` | `0.831381` | `0.763373` |
| PDF.js | 1.5 | `0.724402` | `0.727307` | `0.640765` | `0.757733` |
|  | 1.75 | `0.811486` | `0.809773` | `0.748954` | `0.703362` |
| RayTrace | 1.5 | `0.969782` | `0.480437` | `0.165269` | `0.440949` |
|  | 1.75 | `0.977907` | `0.777953` | `0.692291` | `1.075415` |
| RegExp | 1.5 | `1.112599` | `1.095863` | `1.000000` | `1.407028` |
|  | 1.75 | `1.151827` | `1.060172` | `0.289931` | `0.579176` |
| **splay** | **1.5** | **`0.782229`** | **`0.783414`** | **`0.841000`** | `0.811707` |
|  | **1.75** | **`0.868693`** | **`0.863954`** | **`0.887401`** | `1.012586` |

RegExp 的 endpoint committed/live 非单调，且 1.5 的 minflt/MaxRSS 反而上升；
不能把“低 growth 必然全面省内存”当定律。splay 则给出最清楚的价格曲线：1.75
用约 11.3% committed、13.6% MaxRSS、13.1% minflt 换 3.03% cycles；1.5 用
约 15.9% / 21.7% / 21.8% 换 7.33% cycles。

### 5.3 终态与失败腿处理

- 正式 time/gc 共 104 个进程：82 settled、17 `doomed_pending=true`、5 停在
  retirement `tracing`；按 arm 为 1.5 `23/2/1`、1.75 `19/6/1`、2.0
  `40/9/3`（2.0 因两个窗口有双倍腿数）。
- pending/tracing 只出现在 EB 与 splay：EB `12 settled / 1 pending / 3 tracing`，
  splay `6 / 16 / 2`。所有状态都保留进 paired median，没有只挑 settled 腿。
- 104 条全部 exit 0、数值完成行存在、stderr 空、majflt=0、GC failed=0、
  retirement abandons=0。endpoint 状态会放大 live 与 C/L 的波动，所以报告同时给
  committed/MaxRSS/minflt 和 C/L，不用单个 endpoint 分母改裁决。
- 第一版 runner 曾把合法 terminal pending 错当失败，在启动第二进程前停止；该条
  完整保留在 `.scratch/raw/s2b-growth/time-gc-discarded-strict-terminal-v1/`，
  未混入正式 104 腿。派生器第一版又在 `0/0` threshold-floor ratio 上除零失败，
  `analyze.stdout` 保留；v3 将零分母 ratio 记为 null 后由同一原始记录重算。

## 6. 裁决

| 预注册规则 | 1.5 | 1.75 | 2.0 | 裁决 |
|---|---:|---:|---:|---|
| 六负载 cycles geomean，最小者胜 | `1.010986` | `1.005913` | **`1.000000`** | **2.0 最优** |
| splay cycles 必须 `<=1.01` | `1.073327` | `1.030306` | `1.000000` | **1.5、1.75 均出局** |
| 与 2.0 差 `<0.3%` 才用内存 tie-break | `+1.0986%` | `+0.5913%` | — | **未进入 tie-break** |

因此 lane 的唯一合规推荐是 **保持 2.0**。这不是否认 committed 杠杆：1.75 的
current-source footprint 收益很清楚，而且 S1 已把它的 splay 吞吐阻力压低；只是
`+3.03%` 仍是预注册底线的三倍，六负载总账也 `+0.591%`。owner 若以后要改值，
必须显式重议 splay `+1%` 硬线，而不是把这份测量解释成 1.75 已通过。

## 7. 收尾

- PMU pre/post CPU19 idle：`99.34% / 100.00%`；time/gc：
  `99.34% / 100.00%`。两轮全程持有排他锁，起跑前无 `zig`/`zjs`。
- 原始汇总：`.scratch/raw/s2b-growth/summary.json`，SHA-256
  `680fd4bd069330f6928dc94a8bae9666cf25f64a130e9d13a8d67fb07008d47e`。
- time/gc 原始记录：`.scratch/raw/s2b-growth/time-gc/records.json`，SHA-256
  `8a8188aad81ebcd301c4f0a19d49438d9cd5940e28fb31b02b90e02a932bb0f4`。
- PMU JSON SHA-256：
  - 1.5 normal `c4d7e7b35f210b3c0722edf3ed37422a3785fc30f2dffdfe820e452dac5d3541`；
  - 1.5 splay `c42fa046f8ead32c66e6ddd3848ae75a0e5f784d98ff15fb6074ba7e09258981`；
  - 1.75 normal `85f02ab30ef5d1baa1735abd716328fb1649d335801faa1ffd6fea5a5ee29582`；
  - 1.75 splay `f4167c6ad1596371bf819de969d4321701bc36a081a520bf0f94c9f1d57ca254`。
- 因为本轮是纯测量且最终 tracked source 与基点相同，没有为临时构建常数跑
  `zig build test`；三个 ReleaseFast 构建和实跑冒烟均通过。最终
  `git diff --check` PASS，`git status --short` 为空；没有 commit、没有 push，
  默认 growth 仍是 2.0。
