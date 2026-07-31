# Phase 7 收口

- 日期：2026-07-31
- 起点：`a5bbbe52`（Phase 1–6 合入 `main` 后的集成起点）
- 终点：`ca483766`
- 对照：pinned Bellard QuickJS `04be2460`

**本阶段唯一合入的生产优化是 P7-31。** `git diff a5bbbe52 -- src/` 只有四个文件、155 行：
`core/gc.zig` +17、`core/runtime.zig` +21、`tests/core.zig` +88（P7-31 的契约测试）、
`tests/parser.zig` +30（P7-61 回退后存活的字节码形状钉子）。

## 1. 账目

### 合入

| 线 | 内容 | 兑现 |
|---|---|---|
| **P7-31** | 默认策略下跳过无人消费的进程内存快照 | 每次外部分配 5 syscall → **0**；`Uint8Array(64)` 4175.8 → **263.9 ns/op**；**gbemu +8.49%~+8.97%**（4/4 组合）|

判据是**能力谓词**而非 `Policy.mode`：`rss_soft_limit` / `rss_hard_limit` /
`cgroup_soft_ratio_per_mille` / `cgroup_hard_ratio_per_mille` 四项中任一启用即采样，
`external_*` 两项刻意排除（由内部计数回答）。gate 位于 external accounting 之后。

### 确认机制但关闭

| 线 | 结论 |
|---|---|
| **P7-00** allocator arena churn | 与 qjs **逐项相同**（arena 4096 / 头 40 / block 头 8 / block_sizes / 类映射 / 释放臂 `qjs:1626-1630` / glibc 后端），实测 qjs churn 率相同或更高。非 zjs 税，不开 P7-01 |
| **P7-42** builtin→JS 桥 | 税真实存在（27.26 cyc/callback，7/7 builtin 同向）但**分散在必需控制状态上**：11 个阶段落在 3.3–6.4 cyc 带内，最大单阶段 6.98 < 10.91 门槛 |
| **P7-60 / P7-62** logicalNot 热路由 | immediate 侧收益确凿（边际 −86.3%~−92.2% cyc）但**取不出来**：间接路由每复杂操作数 +8.00 指令（10/14 类型稳定回退 ≥1%）；直连尾跳减半到 +4.00 仍不达标，且触发 `op_compare_cold` 式反噬（`earley-boyer` 从 +1.39% 改善翻转为 −2.37% 回退）。**实测两难，非待调参数** |
| **P7-80** URI/string decode | 基准名误导：decode 只占 24.7%，fusion **确实命中**（miss 0.008/迭代），字符串半边最大单项 21.4%。**成本分散，无一刀** |

### 确认但 deferred

| 线 | 状态 |
|---|---|
| **P7-51A** same-flags shape COW | 机制是对 `qjs:10332` 的不忠实偏差、单事件 423.6 cyc，但**动态冷**：除三个合成 case 外 170 个语料条目共 6 次，`gbemu` 整轮 21 次 ≈ 8.9k cyc |
| **P7-42** push/derive 冗余 | 界定 5–8 cyc（18–29%），所属线已按分散控制税关闭 |

### 测量基础设施

**P7-70**：合同测试 43/43、红队 21/21 全挡（每项带 exit code、`artifactWritten`、真实错误文本）。
四项 fail-closed 落地：样本平衡、affinity 精确为 `{19}`、`startupAdjusted` 降级为 diagnostic-only、
provenance 完整性（门槛由仓库 policy 提供，artifact 不得自带）。权威基线在同代次重采。

## 2. 本阶段最重要的方法论产出

### 2.1 startup-dominated 档会把结论**反号**

5 个 amplified 诊断 case（qjs 执行放大到启动基线 33–94 倍）：

| 源 case | 短 case 值 | 放大后 |
|---|---:|---:|
| `json_roundtrip` | 1.532 | **0.516**（zjs 快近一倍，**符号相反**）|
| `sort_bench` | 1.373 | **2.909**（当前已知最大执行比值）|

**该档不是"低分辨的噪声"，而是系统性地既高估又反号。** 其 52 个 case 与 1.3399 的 geomean
不具任何路线价值。当前分档为 **15 / 8 / 52**（execution-dominant 全部 stable，
startup-dominated 有 22 个 unstable）。

### 2.2 「名义子系统」不等于「引擎机制」

P7-80 的机制层拆分（与 PMU 计数模式偏差 0.24%）：

| 合并桶 | qjs | zjs | 差 |
|---|---:|---:|---:|
| VM dispatch + call machinery + property read | 417.6 | 710.3 | **+292.7** |
| 整条 string/URI 机制 | 321.4 | 215.7 | **−105.7** |
| value free + other | 91.8 | 156.8 | +65.0 |

URI decode 本体 37.5 → 40.3，基本平价。字符串构造语句携带 44–47% 的差额，
但**那些周期落在执行这些语句的 dispatch / call / property 机制里**，不落在 concat 与 allocator 本身。

**因此 P7-70 的「`string/URI` 是绝对成本最大子系统（10.267 ms）」不应再驱动排序** ——
构成该数字主体的两个 case，在机制层是净赢 −105.7 cyc/迭代。语句层与机制层不矛盾，是互补的：
前者问「删掉哪条源码语句差额会消失」，后者问「周期实际落在哪个引擎机制里」。**排序必须用后者。**

### 2.3 频次裁决先于单事件成本

P7-51A、P7-60/62 两条线都是机制正确、单事件成本高、一刀形状清晰，却分别因动态冷与
路由两难而未合入。这条已写入 `measurement-contracts.md` 第 9 条。

### 2.4 测量合同增至 11 条

本阶段新增 5 条（未限定作用域的 `file:line` 归属泄漏、紧密周期禁用 `perf -F` 自动调频、
worktree 缺 test262 submodule 但门禁响亮失败不会假绿、`zjs_nan_boxing` 默认值依赖平台、
以及既有的频次先行）。全部附来源，因为每条都已造成过一次错误结论。

## 3. 下一阶段候选（不在本阶段启动）

| 候选 | 依据 | 缺什么 |
|---|---|---|
| **P7-90** Array sort attribution | `amp_sort_bench` **2.909**，IQR 极小（p25/p75 = 2.904/2.915） | 只有 amplified 一个形态；需先确认放大是否改变算法比例、comparator callback 是否主导、两侧 sort 实现差异 |
| **VM dispatch / call machinery** | P7-80 机制层测得 **+292.7 cyc/迭代**，是 URI 两个 case 的真实大头 | 无独立归因线；P7-41/42 归因的是 builtin→JS 桥，不可挪用于普通 JS→JS |
| **property write path** | P7-10：own-property read 已达或超对齐（净时间比 0.77–0.92），残差在写（局部 1.10 / 顶层 1.52，且顶层写 IPC 也落后） | 未进入 shape/descriptor/写屏障层归因 |
| P7-81 | P7-80 判为分散，**未登记具体机制** | — |

`logicalNot` 线永久关闭，不再尝试 register-resident complex ToBoolean、object-only 第二快路、
调整 tag 集合、或拿 complex 合成回退换产品收益。

## 4. 提交身份

```text
phase7_analysis_closeout_commit = 1fdafc62
phase7_release_source_commit    = 21e24085   (same-runtime 默认样本数修复)
main_merge_commit               = a5ec858a   (--no-ff merge; 全部 pre-tag 门禁在此树上运行)
main_head_at_tag                = 本提交本身（在 merge 之上仅追加本档案，无代码变更；
                                  其 SHA 即标签所指，故不在此自引用）
tag                             = qjs-align-phase-7-closeout  (打在 main_head_at_tag)
phase6_closeout_commit          = c95e574d
Phase 0 baseline                = frozen / unchanged
P7-70 authoritative snapshot    = 89fa82d5 generation
```

`1fdafc62` 是分析收口点；其后追加了一笔 `21e24085` —— `same-runtime` 运行器的默认
`--samples` 原为 **5**，而其配对顺序按样本序号奇偶交替，因此默认调用必然产出 3 qjs-first
对 2 zjs-first，**与测量合同第 3 条自相矛盾**。一个注定违反自身合同的默认值不应被固化进
Phase 7 标签。默认改为 6（奇偶规则下即 3/3）；显式传入奇数**拒绝并退出 2 而非向上取偶**，
因为静默调整会在调用者背后改变测量设计。新增 4 项合同测试（A7-01…04），总数 43 → **47**。

## 5. 收口门禁

因本阶段除 P7-31 外无生产代码变更，且 P7-31 在其自身线上已跑过完整门禁
（含 test262 0/49775、ReleaseSafe、force-GC、altrepr），收口只跑轻量集成门禁：
`git diff --check`、`zig fmt --check .`、`perf-self-check`、same-runtime P0 sentinel、
P7-70 measurement-contract tests。结果见 `phase-7-closeout-gates.txt`。

**打标签前在 `main` 集成树 `a5ec858a` 上重跑的完整门禁：**

```text
zig fmt --check .              clean
git diff --check               clean
measurement contract tests     47/47
red-team attacks               21/21 held
perf-self-check                75/75 compatible, 0 validation failures, paired geomean 0.99
same-runtime P0 sentinel       不传 --samples，artifact 记录 samples=6
                               七个 case 全部 3/3 平衡，geomean 1.0612 <= 1.10 PASS
                               fib_rec 1.2992 为既有 per-case 例外（Phase 1-6 合入时已存在）
test-runner                    43 passed
test262-smoke                  0/12 errors
```

红队本次**重跑**而非沿用 P7-70 的旧结果，因为默认采样行为正是本轮修改对象。
一处值得记录：红队套件最初拒绝运行，理由是工作区不干净（我的临时缓存目录），
**这正是它自身 dirty-worktree 合同生效**——把缓存移出仓库后 21/21 全挡。
