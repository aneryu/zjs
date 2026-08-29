# 停顿基值 2026-08-29(修正后仪器,双臂)

Status: 现行基值。**在此之前的一切 zjs 停顿数字,凡采自 `--gc-stats` 且落在
`dd768214`(2026-08-28,`recordFinalMarkFootprint` 进入 final-remark 计时窗)
与 `7e233ccb`(2026-08-29,普查退出 `--gc-stats` + 增量路径补扣)之间的构建,
一律作废**;这一区间之外的历史读数各有各的口径,见 §5。

本文件把 `.scratch/quiet-verdict.md` §2d 的三张表收编为正式基线。每一格都从
`.scratch/quiet/2d-raw/{tip,rc}-<bench>.txt` 的引擎面板逐行回源核对过,不是
从上游表格转抄。

---

## 1. 采集条件

| | |
|---|---|
| 日期 | 2026-08-29(安静窗口,机器上唯一 agent) |
| 候选臂(tip) | `main@6374ba73` ReleaseFast,`sha256 2e155412…5480` |
| 参照臂(rc) | 冻结 `zjs-rc-branchtip-bf624dea`,`sha256 d1cbdf86…9450` |
| 语料 | `/tmp/gcgap-fixed`(fixed-work 变体,六基准) |
| 协议 | 六基准并行各占一颗空闲大核(15/16/17/18/19/9),**每臂各一次运行** |
| 分位数来源 | 引擎内部直方图(不是跨运行中位数)——设计口径,不是采样不足 |
| 场况 | 开跑前 `pgrep -x zig`=0,十核 idle 97.49–99.50% |
| 原始件 | `.scratch/quiet/2d-raw/`(未进仓,gitignore) |

`a7919ebd` 与 `6374ba73` 之间只差一个纯文档 commit(`docs/splay-account-2026-08-28.md`
+31 行),故本基值对 `a7919ebd` 同样成立。

```bash
for spec in 15:deltablue 16:regexp 17:pdfjs 18:raytrace 19:earley-boyer 9:splay; do
  c=${spec%%:*}; b=${spec##*:}
  ( taskset -c $c <arm-binary> --gc-stats /tmp/gcgap-fixed/$b.js \
      > .scratch/quiet/2d-raw/<arm>-$b.txt 2>&1 ) &
done; wait
```

---

## 2. 表 1:major pause 双臂对照

| bench | tip p50 | tip p95 | **tip p99** | tip max | **保留/总(口径列)** | rc p50 | rc p95 | **rc p99** | **rc max** | rc rounds |
|---|---:|---:|---:|---:|:--|---:|---:|---:|---:|---:|
| deltablue | 54.0 µs | 154.8 µs | 171.8 µs | 181.4 µs | **1024/2751 蓄水池** | 57.5 µs | 75.2 µs | 76.7 µs | 78.1 µs | 4768 |
| regexp | 49.9 µs | 439.8 µs | 453.7 µs | 464.0 µs | 455/455 全保留 | 20.0 µs | 30.1 µs | 30.1 µs | 30.1 µs | 4 |
| pdfjs | 471.3 µs | 1030.5 µs | 1053.6 µs | 1053.6 µs | 45/45 全保留 | 1400.1 µs | 2603.6 µs | 2603.6 µs | 2603.6 µs | 12 |
| raytrace | 31.6 µs | 136.1 µs | 137.8 µs | 139.5 µs | **1024/10530 蓄水池** | 25.9 µs | 27.1 µs | 27.1 µs | 27.1 µs | 3 |
| earley-boyer | 225.4 µs | 1002.2 µs | 1003.4 µs | 1032.9 µs | **1024/12037 蓄水池** | 412.8 µs | 578.4 µs | 962.0 µs | 3332.6 µs | 7266 |
| **splay** | 1001.4 µs | 1009.6 µs | **1012.9 µs** | 1030.5 µs | 706/706 全保留 | 448.2 µs | 44727.8 µs | **44727.8 µs** | 44727.8 µs | 16 |

**口径列不是装饰**:deltablue / raytrace / earley-boyer 的 tip 行是 1024 条
蓄水池保留样本的分位数,不是全体停顿的分位数(环容量 `pause_sample_capacity
= 1024`)。regexp / pdfjs / splay 是全保留,无采样偏差。**跨基准比较分位数
时必须带上这一列**;跨臂比较时注意 rc 面板本来就只有一个停顿环。

**样本 = 一次 STW 切片,不是一次 major**。四种切片(begin / increment /
destroy / finish)都各自入环。段数之和通常**大于**环样本总数,因为
`runtime.zig:3272` 把 finish 内部的标记时间直接记入 increment 段而不入环
(那段纳秒已经作为 finish 切片的一部分入过环了,再入一次就是重复计数)。
逐个对得上:

| bench | begin+finish+destroy 段 | + 真正的 increment 切片 | = 环样本总数 |
|---|---:|---:|---:|
| deltablue | 917+917+917 = 2751 | 0 | **2751** ✓ |
| earley-boyer | 2534+2534+6840 = 11908 | 129 | **12037** ✓ |
| splay | 22+22+346 = 390 | 316 | **706** ✓ |

(increment 段计数 = 真切片数 + 每个 cycle 一次的 finish 内标记:
EB 129+2534=2663 ✓,splay 316+22=338 ✓。)

### 读法

- **splay 是停顿故事的全部来源:tip p99 1.01 ms vs rc p99 44.7 ms(44 倍)。**
  这是 tracing 相对 rc 的最大停顿优势,也是 `gc_merge_policy.json` 预注册
  收益指标(`splay major pause p99`)的现行锚点。
- **pdfjs 亦 tip 胜**(p99 1.05 ms vs 2.60 ms)。**EB 分位数与尾部给出相反
  的符号**:p50 tip 胜(0.225 vs 0.413 ms)、p99 rc 略胜(1.003 vs 0.962 ms)、
  **max tip 大胜(1.03 vs 3.33 ms)**——tip 的分布被增量预算削平了顶,rc 的
  尾巴则拖出 3.3 ms。只报一个分位数会得到相反结论,EB 必须三个一起报。
- **regexp / raytrace / deltablue 是 tip 输**,但要看清输在什么上:这三个
  负载 rc 侧几乎不发生真正的收集(rounds 4 / 3 / 4768,rc 的「pause」很大
  程度上只是 zero-ref drain 的尾巴),而 tip 每次 major 都要付
  begin+increment+destroy+finish 四段。绝对值仍在 0.14–0.46 ms 量级。

---

## 3. 表 2:tip 臂 STW 相位分段

| bench | 段 max:begin | increment | destroy | finish | 段总计 ns / segments |
|---|---:|---:|---:|---:|:--|
| deltablue | 363.7 µs | 66.7 µs | 183.6 µs | 57.4 µs | 10.32 ms/917, 34.54 ms/917, **131.46 ms/917**, 17.81 ms/917 |
| regexp | 408.2 µs | 46.2 µs | 464.0 µs | 47.3 µs | 3.13 ms/152, 4.93 ms/152, **62.62 ms/151**, 2.62 ms/152 |
| pdfjs | 315.8 µs | 925.3 µs | 1034.7 µs | 128.3 µs | 0.66 ms/13, 7.48 ms/13, **12.20 ms/19**, 1.14 ms/13 |
| raytrace | 317.2 µs | 17.7 µs | 159.5 µs | 82.4 µs | 34.34 ms/3510, 36.67 ms/3510, **473.93 ms/3510**, 75.56 ms/3510 |
| earley-boyer | 354.5 µs | 1003.2 µs | 1004.0 µs | 98.6 µs | 38.48 ms/2534, **494.03 ms/2663**, **727.59 ms/6840**, 156.46 ms/2534 |
| splay | 416.3 µs | 1004.6 µs | 1029.9 µs | 256.2 µs | 3.85 ms/22, **324.18 ms/338**, **335.31 ms/346**, 3.63 ms/22 |

**destroy 在六个基准里全部是最大的 STW 相位消费者**(占四相位合计:
deltablue 68%、regexp 85%、pdfjs 57%、raytrace 76%、EB 51%、splay 50%)。
既有的「destroy 才是最大停顿消费者」结论**没有被仪器修正推翻**。
increment 只在 splay / EB 这两个增量标记真正跑起来的负载上追平 destroy。

splay 的 finish 段:总计 3.63 ms / 22 段 = **均值 165 µs、段 max 256 µs**。
2026-08-28 记的「splay 最大段 18.5 ms(finish)」是仪器造出来的数字,见 §5。

---

## 4. 表 3:tip 臂 minor pause 与堆足迹

| bench | minor p50 | p95 / p99 / max | minor 次数 | minor STW 总计 | heap live | account peak | block committed / live |
|---|---:|---:|---:|---:|---:|---:|:--|
| deltablue | —(0 次) | — | 0 | 0 | 345.7 KB | 2.43 MB | 2.04 MB / 287 KB (×7.09) |
| regexp | 599.2 µs | 627.9 / 642.9 / 642.9 µs | 21 | 12.45 ms | 872.1 KB | 8.25 MB | 1.79 MB / 641 KB (×2.80) |
| pdfjs | 529.3 µs | 606.4 / 649.9 / 667.2 µs | 157 | 84.72 ms | 5.70 MB | 46.13 MB | 14.62 MB / 2.16 MB (×6.77) |
| raytrace | —(0 次) | — | 0 | 0 | 525.1 KB | 2.56 MB | 2.10 MB / 443 KB (×4.74) |
| earley-boyer | 391.6 µs | 537.5 / 592.3 / 727.1 µs | 7701 | **3153.90 ms** | 6.26 MB | 16.51 MB | 16.72 MB / 6.61 MB (×2.53) |
| splay | 608.6 µs | 1024.8 / 1024.8 / 1024.8 µs | 8 | 5.71 ms | **108.13 MB** | **267.57 MB** | **138.35 MB / 119.36 MB (×1.16)** |

rc 臂对照(live / peak):deltablue 159 KB / 673 KB、regexp 315 KB / 2.76 MB、
pdfjs 2.56 MB / 35.40 MB、raytrace 108 KB / 967 KB、earley-boyer 1.84 MB /
14.20 MB、**splay 77 KB / 114.82 MB**。

- ⭐**EB 的 minor 停顿总计 3.15 s(7,701 × 0.39 ms)是全表最大的单项 STW
  支出**,是它自己 major destroy 总计(0.73 s)的四倍多。**EB 的停顿问题
  是 minor 频次问题,不是 major 问题**——这是本轮的新观察项,此前的账本
  从未把它单列过。
- splay 的 committed/live = ×1.16 已经很紧(其余基准 ×2.5–×7.1),但绝对
  足迹 committed 138 MB 对 rc peak 115 MB 仍是 ~1.2×。rc 终值 live 77 KB
  vs tip 108 MB 反映的是「tip 结束时还没收完」,不是泄漏。
- deltablue / raytrace 完全没有 minor(0 次),它们的全部 STW 都来自高频
  小 major(917 / 3510 次)。

---

## 5. 这份基值替换了什么,以及没替换什么

### 5.1 被仪器修正作废的:`dd768214` .. `7e233ccb` 区间

`recordFinalMarkFootprint`(全堆普查)于 `dd768214`(2026-08-28)进入
`finishIncrementalCycle` 的 `t_remark..t_weak` 计时窗内;整体 STW 路径会扣
`last_census_ns` 而**增量路径忘了扣**。于是同一个 `--gc-stats` 开关,让
「实际会跑的那条路径」报出膨胀的停顿,还在同一张面板里声称已排除普查。
`7e233ccb` 修正:普查改由 `--gc-mark-footprint` 自立开关,增量路径补扣。

**作废范围**:该区间内一切开着 `--gc-stats` 的 tracing 停顿读数。最著名的
一条是 `docs/splay-account-2026-08-28.md` 曾记的「splay finish 段 18.5 ms」
——真值 165 µs 均值 / 256 µs max,差了两个量级。

### 5.2 **不**在作废范围内:GC-GAP(2026-08-26)

⚠️ **这一条纠正了此前文档里的一句过头话。** `docs/splay-account-2026-08-28.md`
的仪器修正注记写道「GC-GAP 时代 trace 臂的全部停顿数字都含未扣普查 ⇒ trace
的停顿优势历史上被系统性低估(splay 官方 6.87 ms 实为 ~1 ms 量级)」。**逐条
回源后不成立**:

- GC-GAP 的候选臂是 `62061f94`(2026-08-26);`dd768214` 是 2026-08-28 的
  commit,`git merge-base --is-ancestor dd768214 62061f94` 为假。
- 读 `62061f94:src/core/gc_trace_stw.zig` 的 `finishIncrementalCycle`:全函数
  **没有任何 census / liveCount 调用**(begin / markStep 两条也没有)。该文件
  六处 `censusStart`(245、410、424、835、846、856)**全在整体 STW 路径**上,
  而那条路径在 `62061f94:src/core/runtime.zig` 的 `duration_ns` blk 里
  **明确减掉了** `last_census_ns`。
- splay 在 GC-GAP 的 29 次 major **全部是增量的**(面板:`incremental cycles 29`,
  `collection entries 37`),所以它压根没跑过普查——面板那句「census 0 ns
  (excluded from the pause above)」在那一版上是字面属实的。

GC-GAP 的 splay p99 6.87 ms 的真实成分,面板自己写着:
`last finish slice remark 194113 ns, weak 144 ns, sweep+destroy 5080984 ns`
——**尾巴是 final-remark 切片里的 condemn 走查,是真 STW 工作,不是仪器**。

⇒ **6.87 ms → 1.01 ms 这个改善是收集器工作挣来的,不是仪器修正让出来的。**
详见 `reports/evidence/GC-GAP/ERRATA-2026-08-29.md`。

### 5.3 未受影响的历史读数

`docs/tracing-gc-pause-plan.md` 的 P0-P2 读数(splay major p50 112 ms → 1.00 ms、
p95 1.007 ms 等)同样早于 `dd768214`,口径上不受该缺陷影响;它们被本基值
**取代**(收集器已换了几代),但不被**作废**。

---

## 6. 消费者

- `policies/gc_merge_policy.json` → `primary_benefit.preregistered_metric`
  的现行账(splay major pause p99)。
- `policies/gc_merge_policy.json` → `activation_canary.categorical_requirements`
  的 “pause timer excludes census” 一条:**增量路径自 `7e233ccb` 起才真正满足**。
- `docs/roadmap.md` G1-GC 裁决行的停顿列。
- `docs/splay-account-2026-08-28.md` 的停顿章节。
