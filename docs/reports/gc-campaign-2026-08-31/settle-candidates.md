> 注：原始二进制证据在临时 worktree，未入库。

# gc/settle-20260831 lane report

日期：2026-08-31
基线：`main@7c067f0101511df2bde8a5432940dc13be853e19`
结论：**KILLED（3/3 候选刀均不落地）**

本 lane 按“先普查定价，再决定是否实现”执行。刀 1 和刀 3 在普查后直接否决；刀 2 做了最小候选、定向测试、故障注入、census 和六负载 PMU ABBA，但违反预注册的 settle-miss 与写路径成本硬线，已完整回滚。最终不留源码改动、不提交、不 push；原始证据保存在 `.scratch/`。

## 1. 测量合同与产物身份

- 编译固定在 CPU `0-14`；测量固定在 CPU `19`，持有 `/tmp/zjs-host-heavy.lock` 排他锁。
- 指令筛选通过 `mise run perf-screen` / `run_fixed_pmu.py`，每引擎每负载 2 样本，顺序 ABBA；事件为 `armv8_pmuv3_1/instructions/`。wall-clock 不作证据。
- census 与相位补测在同一锁、同一 CPU 上按 base/candidate/candidate/base 排列。
- candidate 与 base 的配置签名相同：
  `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`

| 产物 | SHA-256 |
|---|---|
| baseline `7c067f01` | `2830841f7d2b2992cec3386cf677fc99dbaf458a4f32e8b7ae6d85f7889ab959` |
| 刀 2 candidate（census off） | `a9e9b4590d10fe6361184f0cc32be059f9a50a71440777bc81c814937867ad90` |
| baseline + write census | `259a2abccd01b9a43545b3a08ccb342472be80dd1b879b06f889ef2fb2cb1f88` |
| 刀 2 candidate + census | `486f282cd6a783104d1f96d64237a35c4d3f43209d5b789ccbfc9bd0824e2dbf` |

三条 census fixed-work 输入 SHA-256：splay `35ebfb84…e4a7`、earley-boyer `9f5a58a1…1b3d`、pdfjs `b6328cef…8c94`。六负载 PMU JSON 另记录了每个拼接 fixed-work 文件的完整 hash、二进制 hash、stdout 与逐腿计数。

## 2. 候选刀定价与裁决

### 刀 1：扩 settle class 门槛 — KILLED（无可扩分母）

临时计数器在 `trySettleTracerBlockCorpse` 的每个否决门记录原因，并按 class 计数。三负载的 class / weak / non-block 拒绝全为零：

| 负载 | settle attempts | pass-A settled | class miss | non-block miss | weak miss | 仍 park 的 block entry |
|---|---:|---:|---:|---:|---:|---:|
| splay | 10,311,720 | 10,307,746 | **0** | 0 | 0 | 3,974 |
| earley-boyer | 98,067,805 | 91,494,956 | **0** | 0 | 0 | 6,572,849 |
| pdfjs | 2,749,693 | 2,625,714 | **0** | 0 | 0 | 123,979 |

当前源码已接受所有 `class_id < ids.init_count && !has_inline_payload` 的标准 class；候选中点名的 array 已经在门内。余下 miss 全来自 block 侧 active/empty 否决，不是 class 门槛。不存在能靠扩 class 获得的一个样本，因此不改代码。

### 刀 3：收窄 active/empty block 否决 — KILLED（命中多但价值上限不够）

| 负载 | attempts | active veto | empty veto | 两者合计占 attempts |
|---|---:|---:|---:|---:|
| splay | 8,478,995 | 2,449 | 1,450 | 0.0460% |
| earley-boyer | 98,050,198 | 6,524,796 | 63,544 | 6.7194% |
| pdfjs | 2,761,664 | 121,569 | 2,304 | 4.4854% |

EB 的 active veto 在计数上高频，但按已落地 stage-3 的结构单价（仓库报告：EB 约 29 instructions/corpse）计算，全部收掉也只约 `6.525 M × 29 = 0.189 G` instructions，占本轮 EB 基线 `451.48 G` 的约 **0.042%**，远低于预注册的 0.2%。splay 即使把 active+empty 全收掉，按 39 instructions/corpse 也只有约 **0.00047%**。

而 active handoff/换块会在 allocator 热路径新增状态转换，empty 则会把空块发布生命周期搬进 Pass A。没有足够指令预算支付这些机制，因此未实现；这也避免用复杂度换一个低于筛选噪声的数字。

### 刀 2：无 RC 属性对象免逐槽析构 — KILLED（机制成立，成本线失败）

#### 定价

对 plain-object destroy 与全部属性发布 choke point 普查：

| 负载 | plain objects | 可跳对象 | 可跳对象占比 | slots | 可跳 slots | 可跳 slot 占比 | property writes | 需 cleanup writes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| splay | 5,796,890 | 3,115,834 | 53.75% | 12,630,902 | 7,268,790 | 57.55% | 17,904,515 | 3,840,774 (21.45%) |
| earley-boyer | 72,961,682 | 61,557,165 | 84.37% | 145,923,360 | 123,114,326 | 84.37% | 230,727,309 | 47,248,101 (20.48%) |
| pdfjs | 125,898 | 46,672 | 37.07% | 466,147 | 102,211 | 21.93% | 5,270,657 | 3,277,728 (62.19%) |

`rc_data` duties 分别为 2,681,056 / 16,659,639 / 126,913；pdfjs 另有 44 个 accessor，但 accessor children 是 tracer-owned，不构成 RC cleanup 义务。var-ref/auto-init 在 destroy census 中为 0，但写普查证实路径存在，因此候选保守置位。

#### 临时候选机制与正确性证据

候选借用 `TraceHeaderFlags` 的 bit 1，作为 Object-only sticky cleanup summary：

- data publication 用 branch-free RC-owned leaf tag range 检查后 OR 位；
- var-ref / auto-init publication 置位；accessor 与 tracer-owned Object 不置位；
- `destroyPlainObjectFast` 仅在位为 0 时跳过 property-slot loop，仍无条件释放外部 property storage 与 Shape；
- Debug/ReleaseSafe 在真正跳过前重新扫描 slot，断言没有 RC/var-ref/auto-init 义务；census 同时记录 false negative。

三负载候选 census：

| 负载 | 实际 short-circuit objects | 实际跳过 slots | summary false negatives |
|---|---:|---:|---:|
| splay | 3,764,118 | 8,851,956 | **0** |
| earley-boyer | 61,557,483 | 123,114,962 | **0** |
| pdfjs | 46,647 | 102,109 | **0** |

候选 `zig build check` 通过；`zig build test-core` 为 **462 passed / 6 skipped / 0 failed**。新增定向覆盖了 immediate/tracer-only 清位短路、RC string refcount、weak target 清理。`ZJS_SETTLE_INJECT=1 zig build test` 故意清掉一个真实 RC slot 的 summary，按预期 ABRT；首个相关守卫是候选 `object.zig:2516` 的 `assert(!propertySlotCleanupRequired(...))`，不是其它检查器。

#### 指令 ABBA：违反刀 2 的独立成本线

ratio 为 candidate / baseline；负数是改善。原始 JSON：`.scratch/raw/perf/candidate-vs-base-six.json`。

| 负载 | instructions ratio | Δ | paired-ratio MAD | 总体 +0.3% 线 | 刀 2 +0.1% 线 |
|---|---:|---:|---:|---|---|
| deltablue | 1.000059 | +0.0059% | 0.0082% | PASS | PASS |
| earley-boyer | 1.002422 | **+0.2422%** | 0.0710% | PASS | **FAIL** |
| pdfjs | 1.000307 | +0.0307% | 0.0022% | PASS | PASS |
| raytrace | 0.998352 | −0.1648% | 0.1166% | PASS | PASS |
| regexp | 1.001560 | **+0.1560%** | 0.0193% | PASS | **FAIL** |
| splay | 0.995295 | −0.4705% | 0.8931% | PASS | PASS |

splay 的净收益满足“至少一个目标改善 ≥0.2%”，六负载也没有超过 +0.3%；但刀 2 的专属要求是每个负载写路径代价 ≤+0.1%，EB 与 regexp 明确越线。不能用 destroy 收益抵消已预注册为不可见的热写路径成本，故 KILLED。

## 3. settle-miss 与 destroy 相位补测

### splay settle miss ABBA

miss = active veto + empty veto − both；两腿取中位数：

| arm | raw misses | median | miss / attempts（两腿平均） |
|---|---|---:|---:|
| baseline | 4,446 / 4,174 | 4,310 | 0.04180% |
| candidate | 4,937 / 4,237 | 4,587 | 0.04629% |

候选相对基线是 **+6.43% misses**，不是预注册要求的 **−30%**。刀 2 不改变 settle 资格，这个反方向结果也说明不能把调度造成的单次 count 漂移包装成命中率改进。

### splay `--gc-stats` phase panel

ABBA 两腿中位数：

| arm | destroy total | destroy / 四相位合计 |
|---|---:|---:|
| baseline | 264,708,409 ns | 42.596% |
| candidate | 262,229,502 ns | 42.114% |

destroy 绝对值约 **−0.94%**，占比约 **−0.482 个百分点**，方向满足相位要求。该面板是 clock ns，不冒充 per-phase PMU cycles；cycles/L2D 终裁按 brief 留给 driver 安静窗口，但候选已在更早的硬线上 KILLED，因此本 lane 不申请终裁。

## 4. 预注册验收线逐条对账

| # | 验收线 | 结果 | 裁决 |
|---:|---|---|---|
| 1 | 全量测试 + weak/RC 注入验证 | 候选 targeted 与注入均通过；候选在性能硬失败后未再支付正常全量测试。回滚后的最终树 `zig build test` 为 2490 passed / 6 skipped / 0 failed。 | **FAIL（候选不具备落地所需完整证据）** |
| 2 | splay settle miss 至少 −30% | 4,310 → 4,587，**+6.43%** | **FAIL** |
| 3 | splay 或 EB 至少 −0.2%，六负载均不差于 +0.3% | splay −0.4705%；最差 EB +0.2422% | **PASS（screen only）** |
| 4 | 受益负载 destroy 相位下降 | splay 264.71 ms → 262.23 ms，约 −0.94%；占比 −0.482 pp | **PASS** |
| 5 | 刀 2 写路径全负载 ≤+0.1% | EB +0.2422%，regexp +0.1560% | **FAIL** |

必要条件 2、5 失败；条件 1 对候选也未完整满足。最终裁决只能是 **KILLED / 不合并**。

## 5. 验证与环境记录

- 普查版、候选版多轮 `zig build check`：PASS。
- 候选 `zig build test-core`：462 passed / 6 skipped / 0 failed。
- 候选故障注入 `ZJS_SETTLE_INJECT=1 zig build test`：预期非零，命中新守卫。
- 第一次回滚后 `zig build test`：2488 passed / 6 skipped / 2 failed；仅因本 worktree 的空 `test262/` 子模块导致两个 fixture `FileNotFound`。
- 按 `docs/verification-policy.md` 的 worktree 陷阱说明，临时链接 `/home/aneryu/zjs/test262` 后重跑：**2490 passed / 6 skipped / 0 failed**。
- 未跑 test262/gate_smoke/arena audit；按现行 policy 它们属于 driver 批门禁。

## 6. 遗留风险与建议

1. 刀 1 的结论很强：三个目标负载 class miss 精确为 0；除非 class 表或 inline-payload 策略改变，不应再次以“array 尚未进入”为假设开工。
2. 刀 3 的 active veto 在 EB 数量大，但按已测 stage-3 单价仍只有约 0.042% 指令上限。若未来 active block 表示或 allocator handoff 已因其它工作改变，可重新定价；当前不值得独立加状态机。
3. 刀 2 的 summary 正确性与可跳分母均已证实，失败点是对称写成本，不是 coverage。若未来已有写屏障能免费携带这个 bit，才值得重开；当前不应复制本候选。
4. splay 的 2-sample paired-ratio MAD 为 0.893%，其 −0.47% 只应视作 screen 结果；EB/regexp 的回归分别有 0.071%/0.019% MAD，足以否决 +0.1% 线。
5. 所有临时 counters、候选实现与测试已从源码移除；没有 commit，也没有 push。

## 7. 证据索引

- 初始/写路径/候选 census：`.scratch/raw/census/`
- 六负载 PMU JSON：`.scratch/raw/perf/candidate-vs-base-six.json`
- PMU 控制台：`.scratch/perf-screen-six.log`
- settle miss ABBA：`.scratch/raw/settle-abba/`
- phase ABBA：`.scratch/raw/phase-abba/`
- 注入栈：`.scratch/candidate-injected-zig-build-test.log`
- candidate targeted tests：`.scratch/candidate-test-core.log`
- 最终全量测试：`.scratch/final-zig-build-test-after-test262-link.log`
- 固定二进制：`.scratch/bin/`
