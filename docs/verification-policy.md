# 验证与门禁政策(Verification Policy)

Status: **现行**(owner 裁决 2026-08-29:精简影响效率的门禁;验证摊销从批内
扩到批间)。本文件是唯一权威;与旧文档/旧派工惯例冲突时以本文件为准。
适用于所有实现工作(人类、driver、subagent)。

## 原则

**验证成本后置给失败案例,不预付给每次改动。** 批次的意义是留下 bisect
粒度;昂贵验证在合并批边界跑一次,失败才用批内 commit 二分定位。

## 每次改动(implementer 侧)必须做的

1. 迭代验证用 `zig build check`(纯 sema,~80s),不用完整构建;
2. 为改动写针对性测试(新行为/新不变量);
3. 收尾跑**一次** `zig build test`(pipefail)全绿;
4. 注入验证:**仅**对守护新不变量的检查器;用「一次构建多注入点」模式
   (`ZJS_*_INJECT=<n>` 环境选择),不许每断言单独构建;注入必须在
   `zig build test` 形态下做(默认 zjs 产物 safety 关闭会假通过),且确认
   开火的是自己的守卫(「触发别的守卫 ≠ 你的守卫有效」)。
5. 性能刀附目标负载的指令数 ABBA(匹配 `armv8_pmuv3_1/instructions`);
   足迹敏感刀(分配器/阈值/释放策略类)的 screen 必须另附
   `cycles(user+kernel)` 与 `minflt` 两列硬证据,instructions 降为对照列
   (退休指令数看不见缺页处理/stall/内核指令单价;依据
   `docs/gc-architecture-review-2026-08-31.md` §3 与 REPORT5 实证)。历史仅按
   insn 判死且内存收益大的刀获得一次新货币复审资格(先例:refill-v2);
   **不要求**陪跑全负载矩阵。CPU、L3、锁、编译池与裁决等级统一服从
   [`docs/perf/measurement-contracts.md`](perf/measurement-contracts.md):默认场 B
   单核 CPU19,编译池默认大核 `5-8,15-18`(2026-09-06 起;要与 insn 粗筛并行
   时显式 `ZJS_BUILD_CPUS=0-4,10-14`);显式 `--field`/`ZJS_MEASURE_FIELD` 才可换场。
   2026-09-01 校准的失败判定全部保留;补充裁决仅允许 `insn@B ∥ 编译` 与
   `insn@B ∥ cycles@A` 作探索/粗筛,且每个结果必须显式标
   `resolution >= 0.5% (coarse/concurrent)`。该结果只能决定是否值得静场复跑,
   永不跨越任何预注册通过/失败线。预注册裁决一律回到串行/静场并维持 0.1%
   精度制度;并发采到的 cycles 仍仅为归因诊断。不得把“有两个锁”解释成
   “数据已有 verdict 权威”。

## 分级验证金字塔(2026-09-02 owner 令「效率」后增补;实现片与性能刀一律遵守)

**原则:最贵的仪器只用来确认 GO,不用来发现问题。** 2026-09-02 M 切换片实录:
正式 2×2 冷构建 ABBA + 两轮 batch-gate 约 5 小时后才看到 +12% 回归,而一次
`--gc-stats` 对比(10 分钟)就能暴露根因(minor 判死块误入 hot-reuse 门)。

| 阶段 | 内容 | 成本 | 通过线 → 下一阶段 |
|---|---|---:|---|
| **Stage 0 快筛**(commit 后立刻,强制) | warm ReleaseFast 构建候选;`tools/perf/gc_stats_snapshot.py compare`(候选 vs 缓存的基线快照,阈值 ±10%:hot reuse/reopened/deferred runs/major+minor 次数/minor STW/committed/bitmap reclaimed cells);`run_fixed_pmu.py --samples 2`(runner 最小合法 paired ABBA)候选 vs 基线二进制,场 A(CPU9,可与他人并行),标 `resolution>=0.5%` | ≤15 min | STOP 线:任一负载 **insn >+0.5%**,或 **cycles >+2%**(场 A 2 样本同 SHA 自比 EB 单腿可漂 +2.85%,cycles 在 Stage 0 只作粗指示;0.5%~2% 区间记「待正式」),或确定性指标越阈 → **先 perf 符号差分归因并修**(≤30 min),不进任何后续门禁;否则 → Stage 1 |
| Stage 1 | `zig build test`(Debug;2026-09-05 起分片并行,源码改动后 ~75 s) | ~1.5 min | 绿 → Stage 2 |
| Stage 2 | 一次 `zig build test` + **一轮** `mise run batch-gate` | ~15 min | 绿 → Stage 3 |
| Stage 3 正式 | **1×1** 冷构建 ABBA(CPU19 静场,0.1% 制度) | ~40 min | 全部过线 → GO;任一负载落在线 ±0.5% 内 → 才加 2×2 总中位裁布局噪声;明显超线 → NO-GO,不追加功率 |
| 整合批 | 第二轮 batch-gate、settled 两轮 | — | 只在 integration 分支合并后做一次,不在每个 lane 迭代做 |

配套纪律:
- **锁与超时纪律**(2026-09-02 事故:一条 `zjs --gc-stats /dev/stdin` 等 stdin 挂起 8 分钟并持有 host 编译锁,全机构建队列停摆 12 分钟):
  host 编译锁(`/tmp/zjs-host-heavy.lock`)**只包编译**,测量/校准/gc-stats 采集只走 measure_fields 的场锁;任何 lane 单条命令必须
  `timeout <秒>` 包裹(构建 1200、单负载运行 600);fixed-work 一律用文件路径,禁止 `/dev/stdin`;driver 发现锁持有者 0% CPU 超过
  5 分钟即 kill 并通报。
- **基线产物缓存**:H_PRE 的 ReleaseFast 二进制(a/b 两冷构建)、gc-stats 快照、
  单样本 PMU 表在 `~/worktrees/<lane>/.scratch/h_pre0/` 或共享目录冻结一次,各 lane
  各迭代复用;禁止每次迭代重建基线臂。
- **足迹列**:Stage 0/3 各一次 paired `/usr/bin/time`(minflt/maxrss)+ `--gc-stats`
  committed 即可(实测 MAD≈0);不做 8 样本足迹 ABBA。
- **预注册加一列**:性能片除 insn/cycles 线外,必须声明「生命周期指标不变」
  或显式列出预期变化——表示/机制切换不得夹带策略变化。指标分两类:
  **确定性指标**(minor 次数、bitmap reclaimed cells、deferred block runs)硬线 ±10%;
  **相位敏感指标**(major 次数、hot reuse published、reopened、committed、minor STW total〔ns,
  wall-clock;同 SHA 自比可漂 −10.7%〕)受
  wall-clock GC 预算混沌影响(同一基线两次 run major 22 vs 29),只报方向+幅度并标
  `phase-sensitive`,不单独构成 STOP。
- **设计对抗循环上限**:codex↔codex 对抗评审每份设计最多 **1 轮**,之后由 driver
  亲自对源码复审并裁决(2026-09-02 实录:四轮 codex 循环 5 小时的混合终案被 driver
  30 分钟源码核验推翻——前提「不可变 header 承重」无人质疑)。设计评审必须先答
  「现状是否已满足目标合同」。

## 每合并批(driver 侧)做的

1. 合并载荷审查(`git log trunk..candidate`,合并 commit = 合并其全部祖先);
2. 批门禁一轮:`mise run batch-gate` = `zig build merge-gate` 单构建图:
   统一套件(含 stress 层)+ gc-stress + Debug CLI smoke + 架构检查 +
   ReleaseFast zjs/run-test262 + 全量 test262 + gate_smoke(每负载含一次
   arena-audit run)全部并行;引擎编译 2 ReleaseFast + 2 Debug。相比
   engine-production-gate(发布门,`mise run production-gate`)少了
   ReleaseFast `zjs-profile` 的 smoke 与 `test-embedding` 的第二个 Debug 引擎
   编译(改为 sema-only `check-embedding`;运行期 pin 在统一套件里跑)。默认
   构建 affinity 为大核池 `5-8,15-18` 且构建阶段持 host 排他锁;
3. 失败 → 按批内 commit bisect,只对肇事 commit 追加验证;
4. cycles/L2D 终裁攒安静窗口一次做:用 measurement contract 的 field/host
   锁作仲裁并保存 mpstat/进程诊断。当前校准没有批准任何跨场或编译重叠的
   verdict;粗筛例外不构成终裁权限。因此同域外来计算使终裁腿无效;不得仅因
   取得 field 锁就忽略未协调的同域负载。

## 明确废止的(勿再执行)

- **rc 中立性检查全套**(.text 对比、双变体单测、rc 语义论证)——rc 收集器
  已退役(2026-08-29),无对象;
- 每次改动跑 test262 / gate_smoke / arena audit(移至批门禁);
- 每断言两次构建的注入验证;
- 全负载矩阵的指令筛选。

## 保留的纪律(便宜且有战功)

- **预注册验收线**:性能刀开工前写下通过/失败判据(曾正确否决整把刀);
- 设计文过审:仅限触碰对象表示层/GC 语义/公共 ABI 的大刀;
- 测量合同:编译池默认 `5-8,15-18`(与测量并行时 `0-4,10-14`),测量走 field registry/锁、测量前 mpstat、
  指令数筛选/cycles 终裁两级仪器、wall-clock 在并发场不可信;CPU9 与 CPU19
  的绝对数不可混腿,拓扑层只与同拓扑基线比较;并发粗筛显式标
  `resolution >= 0.5%`,任何预注册裁决保持串行/静场 0.1% 制度;
- 环境陷阱清单:linked worktree 的 test262 空 submodule 时先跑
  `mise run worktree-init`;该任务复用主 worktree 的 corpus,且 symlink 不进提交。
  scratch 一律 worktree 内
  `.scratch/`,严禁 /tmp 裸文件名(agent 间撞车实录)。

## 风险自认(owner 已知情)

正确性缺陷的拦截点从「改动内」后移到「批门+bisect」。同一笔验证账,
成本从每次改动的预付改为失败案例的后付。
