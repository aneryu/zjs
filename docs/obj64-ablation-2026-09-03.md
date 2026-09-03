# obj64 消融(2026-09-03)

S1 把 trailing-property 普通对象从 96B cell 收到 80B。S2(64B 线轴)停在
① list-exit。本题把 80B→96B 和 64B→80B 两段从「改引擎」里拆出来单独定价,
方法学同 [slab-reuse 的 pad-only 臂](slab-reuse-2026-08-29.md):只加填充、
不改被碰到的字段。

两臂:

1. **引擎外 stride 微基准** `tools/perf/obj64_stride/` — 不链引擎。packed
   cell 只放 payload word + `next`,对应 `shadeExact` 跟 child 之前的两次
   header 载入。步长 64/80/96 × 访问序 `seq`/`chase`/`shuf` × 预取开/关。
   等功:每个 cell 访问一次、XOR 同一份不可变 payload,checksum 与访问序无关。
2. **引擎内 pad-only** `-Dzjs_obj64_s1_pad`(默认关,comptime 擦除) — 只给
   `ids.object` 且带 trailing FAM 的分配在 FAM **之后**垫 16 B。活字段偏移
   仍是 S1 packing;数组/宽类不动。生产 size class 不变。

本机不是 ARM Cortex-X925 测量机。读数标 **x86 方向性**,不入 cycles 账。
S0 kill line(带 prefetch 的 64 vs 96:<1.5% cycles 且 <8% refill ⇒ 线轴死)
仍以 ARM 安静窗口为准。

## 主机

- Intel Xeon (KVM), `emeraldrapids`, 4 核, L1d 192 KiB / L2 8 MiB / L3 320 MiB,
  16 GiB。`perf_event_paranoid=2` 且 `perf_event_open` 对用户态 HW 计数器返回
  `EACCES`,所以没有 insn/cycles/cache-misses;`ns` 是 wall 中位数。
- 绑核:`taskset -c 0` + `--cpu 0`。录前 `vmstat` idle ~100%。
- 二进制:`zig-out/bin/obj64-stride-ablation` ReleaseFast;种子
  `0x6a09e667f3bcc909`。

1 MiB cell 的工作集约 240 MiB,落在这颗 320 MiB L3 里,chase 出现 80>96
的反转,不入账。下面只报 **8 MiB cell**(三块 slab 合计 ~1.9 GiB,出 L3)
的 DRAM-bound 臂。

## 引擎外:8 MiB cells × 5 repeats(DRAM-bound)

`ns/cell` 中位数。`vs80`/`vs96` 是同序+同预取。

| arm | ns/cell | vs80 | vs96 |
|---|---:|---:|---:|
| 64-seq-np | 3.635 | 0.916 | 0.869 |
| 80-seq-np | 3.969 | 1.000 | 0.949 |
| 96-seq-np | 4.185 | 1.054 | 1.000 |
| 64-chase-np | 153.173 | 0.946 | 0.903 |
| 80-chase-np | 161.915 | 1.000 | 0.954 |
| 96-chase-np | 169.683 | 1.048 | 1.000 |
| 64-chase-pf | 153.059 | 0.945 | 0.918 |
| 80-chase-pf | 162.027 | 1.000 | 0.972 |
| 96-chase-pf | 166.749 | 1.029 | 1.000 |
| 64-shuf-np | 15.037 | 0.963 | 0.926 |
| 80-shuf-np | 15.615 | 1.000 | 0.962 |
| 96-shuf-np | 16.232 | 1.040 | 1.000 |

读法:

- **线轴仍活(方向性)**。S0 的引擎忠实臂是 `chase`。这里 64-chase-pf vs 96
  是 **−8.2% ns**,远大于 kill line 的 1.5%。没有 refill 计数,不能把 kill
  line 判死或判活写成 ARM 账;只能说这台 x86 上随机链的步长差没有被硬件
  预取抹平。
- **相邻线预取盖不住随机链**。8 MiB chase 上 pf 与 np 几乎同一条线
  (64: 153.173 vs 153.059 ns/cell)。与 S0「随机序预取覆盖率 0%」同向。
- **seq 不是纯带宽**。字节比 64/96=0.667,测得 seq-np vs96=0.869。每 cell
  有一块与步长无关的固定开销,步长只吃到 ~13% 的顺序扫描差。
- **80 vs 96(S1 pad 问的那一段)**。chase-pf −2.8% ns、chase-np −4.6% ns。
  16 B 填充在随机链上不是零,也不是 S0 上 64 vs 96 的 −30% 量级。这是
  方向性单价,不是 splay 账。

原始 JSON:`obj64_stride_8m_x86.json`(本工作区 artifacts)。1 MiB 臂
`obj64_stride_1m_x86.json` 留作 L3-resident 对照,不引用其中位数。

复跑(ARM 测量机,安静窗口,大核,`armv8_pmuv3_1`):

```sh
zig build obj64-stride-ablation -Doptimize=ReleaseFast
taskset -c 17 zig-out/bin/obj64-stride-ablation --cpu 17 --pmu armv8_pmuv3_1 --cells 1048576 --repeats 8 --json obj64-stride-arm.json
```

## 引擎内 pad-only:`pad_alloc.js` 300k 个 `{a,b}`

两条 ReleaseFast `zjs`,`--gc-stats --perf-json`。负载是 300 000 个带两个
own data 属性的普通对象(Reserved2 / trailing FAM),外加一个 Array 托住
活集。checksum `90000000000` 两侧相同。

| | pad off (S1 80B) | pad on (96B) |
|---|---:|---:|
| block-heap class 80 live-cells | **300000** | 0 |
| block-heap class 96 live-cells | 0 | **300000** |
| class 64 live-cells(数组) | 6 | 6 |
| class 48 live-cells | 179 | 179 |
| heap live bytes | 21630672 | 26430672 |
| allocated_bytes(exit) | 26707168 | 31507168 |
| maxrss KiB | 36684 | 41368 |

- `heap live` 差 **+4 800 000 B = 16 × 300 000**。填充按个数精确入账,没有
  漏到别的 size class。
- class 64 两侧都是 6:数组线足迹没动,S1 的 fast-array 不变量还在。
- 不要读 `allocated_bytes_peak` 或 `vm_run_ns`:major 次数 5 vs 6,不是等工况,
  墙钟也不是 ABBA。隔离证据是 class 直方图和 live 差。

## 对 S2 的含义

x86 方向性读数**没有**触发 S0 kill line,也**没有**给出 ARM 上 64 vs 96
−30% cycles 的复现。S2 仍停在 ①。本变更默认关:生产 80B cell 不动。ARM
安静窗口应用同一份 harness 才能把 ns 换成 cycles/L2D 入账。
