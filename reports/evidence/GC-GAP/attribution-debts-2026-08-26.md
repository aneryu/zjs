# GC-GAP 归因债清偿(2026-08-26,GC 会话)

manifest.json(version 1)记录的两笔归因债的裁决。测量:idle 大核,
frozen 二进制(BASE-G0 集)+ 分支 tip 重建,协议逐条注明。

## 债 ① SplayLatency 0.805(rc 分支臂)——裁决:非回归,双峰抽样假象

**指控**:branchtip-rc vs mergebase-rc 全套 suite 下 SplayLatency
16239/20163 = 0.805,疑 block heap 共享代码拖累 rc 构建。

**证据(三组独立测量,同一对冻结二进制)**:

| 协议 | tip-rc 分布 | mb-rc 分布 | ratio |
|---|---|---|---|
| driver 原测(serial c19, n=8) | [15616..16880] 单模式 | [15457..21169] 3 低 + 5 高 | 0.805 |
| 本会话复刻(**同协议同二进制**, serial c19, n=8) | [15875..21002] 跨双模式 | [15736..20951] 跨双模式 | **0.959** |
| 本会话 parallel two-cluster(n=8) | — | — | **1.157**(方向反转) |
| 单跑 splay.js(无套件语境, c19, n=4) | 18072-18259 | 17890-17923 | ≈1.01 |

**机制**:SplayLatency 在全套语境下是**双峰分布**(~16k 与 ~20.5k 两个
模式);哪个 run 落哪个模式由 run 级初始条件决定(页缓存/布局),与二进制
无关——同一对二进制三次测量给出 0.805 / 0.959 / 1.157。driver 原测中
tip 8/8 落同一模式是抽样巧合。单跑口径两臂完全持平,排除 block heap
共享代码的系统性效应。

**对 G2 的含义**:paired log-ratio 在该指标上方差巨大(配对差可达
±25%),不会产生假信号但会拖宽 CI;SplayLatency 不应被单独用作任何
裁决输入,n=8 的单指标中位数比较在双峰指标上会再现 20% 级伪信号。

## 债 ② splay RSS 544MB——裁决:峰值足迹主导,已修其可修部分

**分解**(trace tip 单跑 splay,smaps 峰值快照 + `--gc-stats` 面板):

| 组分 | 大小 | 性质 |
|---|---|---|
| glibc brk 段 | ~318MB | 非 block 分配(payload/字符串,经 `init.gpa`=malloc)的高水位;free 后 glibc 不还 OS |
| block heap committed | ~180-230MB | live 仅 62-83MB;其余为页内碎片(splay 死节点分散,整块全空稀少)+ 瞬时全空块 |
| account 峰值 | 252MB(= 3.8× live 66MB) | 1.75x 增长因子 + 增量窗口内 mutator 持续分配 |

RSS 随 run 单调爬升至稳态(t=1s 已 234MB,t=8s 549MB),不是尖峰:
两个分配器都只涨不跌。**与 rc 150MB 的差 = tracing 峰值堆的结构对价**,
与吞吐三角的内存包络谈判是同一枚硬币。

**已落地修复**(分支 gc/tracing):free 块 aging decommit——完全空闲
且在 free 链上度过 ≥1 个完整 major 的 block,cell 页(64KB−4KB header)
madvise(DONTNEED) 还给 OS;header 页保留使 free 链/magic/保守扫描
解析全部不变。无 aging 的初版在 splay 上累计 decommit 337MB 又立即
recommit 299MB(纯 syscall+缺页税);aging 后稳态 madvise 降至 1.7MB,
Splay 分数无回归(3312 vs 3020-3064 同带)。该修复回收的是**堆收缩
场景**(套件切换、瞬时峰值后)的保留,splay 单跑 maxrss 不动(峰值主导,
预期内)。

**未修部分及归属**:brk 高水位(可选 malloc_trim/mmap 化,独立小项)、
页内碎片(需 hole punch 或 compaction,重型)、峰值本身(增长因子 +
增量窗口 = §20.2a 吞吐三角 owner 裁决的对象,不是缺陷)。

## Gate 状态(decommit 修复)

- `zig build test -Dzjs_gc=trace_stw`:2405/0(10 skip)
- `zig build test`(rc):2369/0(46 skip)
- macro 9/9 绿(ZJS_GC_ARENA_AUDIT=1)
- test262 trace_stw 全量:见 re-freeze commit 记录
