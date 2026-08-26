# 吞吐三角选项 A 定价:growth factor 1.75x → 2.5x(2026-08-26,GC 会话)

G1-GC margin 决策输入。fixed-work(doWarmup=false, doDeterministic=true),
三臂配对 ABBA 轮换,pinned CPU 19,host-heavy flock,n=4 中位。

臂:g175 = gc/tracing bf624dea trace_stw(growth 1.75x,现状);
g250 = 同源仅改 `resetGCThreshold` trace 臂为 2.5x;
rc_mb = 冻结 zjs-rc-mergebase-14b0618d。

| 基准 | 臂 | wall 中位 (s) | RSS 中位 (MB) | wall/rc | RSS/rc |
|---|---|---|---|---|---|
| splay | g175 | 3.79 | 545 | 2.037 | 3.63 |
| splay | g250 | 3.18 | 691 | **1.713** | **4.61** |
| earley-boyer | g175 | 30.84 | 42 | 1.299 | 2.25 |
| earley-boyer | g250 | 29.70 | 59 | 1.251 | 3.16 |
| deltablue | g175 | 19.49 | 8 | 0.979 | 1.44 |
| deltablue | g250 | 19.51 | 8 | 0.980 | 1.44 |

三基准 geomean:g175 **1.372** → g250 **1.280**(−9pp),RSS 代价
splay +27%(至 4.6x rc)、eb +40%(至 3.2x rc)。

**判读**:放宽 43% 的内存包络只买回约三分之一的吞吐差;deltablue
(major 频率低)完全不动。§20.2a 的预言(「增长因子封顶 ⇒ mark×major
税有下限,P3 全兑现仍 ≈1.15-1.2」)被定价证实:即便 2.5x,GC 压力口径
仍 ~1.28(三基准口径)。**选项 A 单独无法把吞吐差压进任何常规非劣效
margin(≤1.10);它至多是 B(parallel marking)或 C(判据分层)的辅助
项。** 且 §1.3 的 cycle peak/live ≤ 1.8 封顶在 2.5x growth 下必然违宪
(splay 现状已 3.8x account peak),选 A 必须连带修宪。
