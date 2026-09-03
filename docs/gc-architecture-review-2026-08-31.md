# GC 架构整体评审（2026-08-31）

Status: **DRAFT — pending owner ruling**
作者：driver。证据：本日战役全部 lane 报告（docs/reports/gc-campaign-2026-08-31/ 及三份勘察：DIFFERENTIAL_REPORT / ALLOC_FORENSICS / CONSERVATIVE_RETIREMENT，暂存各 worktree .scratch/，批合并时归档）。

## 0. 评审动因与方法

owner 裁决（2026-08-31 晚）：性能是结构性问题，单点优化会被锁死，需整体评估 GC——与 08-27 opcode 线「单点回收暂停升级整套重设计」同构。本评审基于三条并行证据 lane：
1. splay 差分（trace vs 冻结 rc，符号桶级，+20.4pp 全闭账）；
2. 分配路径法医（zjs vs JSC/V8/qjs 的逐义务对照）；
3. 保守扫描退役距离（C1/C2/JSC-comp 三路线量级）。

## 1. 账：splay +20.4pp 的构成（当前口径，cycles，对 rc 总量）

| 成分 | pp | 判词 |
|---|---:|---|
| kernel/缺页足迹残差 | **+9.04** | 第一大项。trace 多 9.3 万次 minor fault（committed 268MB vs rc 峰值 114MB）；growth 2.0 + 浮动垃圾的足迹在内核侧收税 |
| marking（净额） | **+7.64** | shadeExact+traceHeader 毛 13.2pp；symbol 口径 > 相位口径（barrier 精确着色的 shade 发生在 mutator 时间内） |
| pollGC + GcObjectIterator 走堆 | **+4.81** | trace 独有；混合 safepoint/condemn/整块扫描 |
| alloc front | **+3.21** | 法医判决：可删义务 ≤~1pp，余为冷 free-list 依赖链（局部性/足迹问题） |
| barrier/remember | +1.07 | |
| minor/young | +0.03 | minor 叙事出局 |
| destroy/sweep | **−5.28** | trace 净赢；settle 刀被杀正确 |
| rc 专属机器 | −2.61 | |
| 其余 mutator/漂移 | +2.48 | 含非 GC 源码漂移 |

## 2. 三个被证据否决的叙事

1. ❌「分配路径白付大钱」：全部可删义务乐观相加 ~1pp（P1 冷端派生 0.16-0.33pp、P2 延迟位图 0.27-0.38pp、P3 分代同质块 0.33-0.44pp 且撞 A2/A3）；u16 index 与 count 取舍正确（NO-GO）。
2. ❌「minor 无产出→短命对象全价 major」：trace 死亡侧净赢 7.9pp。
3. ❌「0B prefix 优于 A1 的 8B」：40/56/72B body 去前缀后仍落同 class，零 footprint 红利；A1 目标维持。

## 3. 方法论缺陷（本身即结构偏差之一）

**verification-policy 的 user-insn 筛对 9pp 的内核账全盲。** splay 战役以 insn 尺决策（growth 1.5→2.0 等），user 侧收益可能同时在 kernel 侧付了未测的税。修正案（建议立即入 policy）：
- 足迹敏感刀（分配器/阈值/释放策略类）的 screen 增加两列硬证据：**含 kernel 的 cycles**（perf stat 默认口径）与 **minflt**；
- 历史用纯 insn 判死且内存侧收益大的刀获得一次含内核口径的复审资格（首个对象：refill-v2，候选二进制已冻结，零实现成本）。

## 4. 结构选项与建议排序

### O1 足迹线（打 +9.04pp，性价比第一）
- **O1a refill-v2 含内核复审**（零实现：冻结二进制在案，补 cycles(u+k)+wall ABBA 六负载）；小堆负载 minflt 已实测 0.12-0.85×，内核口径下可能整体翻案。
- **O1b growth/阈值含内核重定价**：growth 2.0 的 +10-13% RSS 在内核侧的真实税首次可测；1.75/2.0 A/B 用新尺。
- **O1c A2 机制群复活评估**：按新尺重排（empty 高水位、decommit pacing 等桌面否决项的分母变了）。

### O2 marking 线（打 +7.64pp，在途）
A1+S2 合并 header 切换：obj-prereq 已落（靶测+①退链表，splay cycles screen 0.9924），**A1v2 设计稿等 owner 过审**（docs/tracing-gc-header-v2-design.md @ gc/obj-prereq-20260831）。法医报告确认 8B 目标正确、0B 无红利。

### O3 走堆线（打 +4.81pp，需归因）
pollGC/GcObjectIterator 的 4.81pp 尚无命名机制——立一个归因任务（walk 的触发源、频次、每次量），归因后才谈刀。obj-prereq ① 可能已改变此桶，重测优先。

### O4 分配微刀（≤1pp，选做）
仅 P1（old_space.live_bytes 冷端派生，0.16-0.33pp，接受线已在法医报告）值得单独走；P2 需协议设计审查先行；P3/P4 是架构实验缓议。

### O5 结构大注（长期）
- **C2-P0 pinability census（1-2 lane-week，可撤销）**：保守 word 逐来源/重合/命中块普查——C1（全精确 14-22lw）vs C2（pin-page copying 22-32lw）vs 永久非移动（JSC-comp 15-24lw）的分岔判据。census 之前不写 evacuator。
- 好信号：splay conservative-only young 实测仅 1/12 minors。
- 注意：O1/O2 若兑现，splay 差距可能收到 +5~8pp，届时 O5 的性价比要重估——**先便宜后昂贵**。

## 5. 建议执行序（每步可撤销、带预注册线）

1. 立即：方法论修正入 policy + O1a refill 复审（零实现）+ O3 走堆归因；
2. owner 过审 A1v2 → O2 header 切换 lane 群；
3. O1b/O1c 按新尺重定价；
4. 上述兑现后重测差分，再裁 O5 的 census 是否开。

## 6. owner 决策点

1. 方法论修正案（§3）批准与否；
2. A1v2 设计稿过审；
3. refill 若在含内核口径下翻案，其落地形态（默认开 / flag）；
4. O5 census 的开工时机（现在并行 vs 等 O1/O2 兑现后）。
