# 性能追平战役 — 交接

最后更新 2026-08-13。**接手先读这一份，再按需展开。**

---

## 1. 现在在哪

```
zoo throughput geomean   0.9137   (15 基准 × 每侧 24 samples，3 车道并行)
总 log deficit           1.3539
追平需相对提升            9.45%
基线 zjs fb680e41  vs  qjs 04be2460
```

**今天净落地两刀，geomean 0.9111 → 0.9137（+0.29%）。**

| commit | 内容 | 实测效果 |
|---|---|---|
| `485a7c5a` | `fclosure` 常驻 handler + 压平 capture source 分派（qjs:17914） | **zoo 效应为零**；保留理由是忠实性（qjs 有常驻 CASE 而 zjs 两表都挂 coldStd）+ 指令 −0.371% 稳定 |
| `fb680e41` | `build_arg_list` 的 length 快前缀（qjs:41171 / qjs:8268） | **RayTrace +2.25/+2.54/+2.04%（三 pad），geomean +0.24%**；RayTrace 0.754 → 0.783 |

⚠️ **目前没有已验证的追平方向。** 见 §5。

---

## 2. 治理框架（新接手必须先接受这四份）

| 文件 | 作用 |
|---|---|
| `PARITY-LEDGER.md` | **任务准入**。所有新任务开工前必须先报「预计 full-Zoo geomean 贡献」。<0.3pp 只登记不实施；0.3–0.5pp 等组包；0.5–1.0pp 正式候选；≥1.0pp 才是主线 |
| `measurement-contracts.md` | **12 条**，每条都有实际事故来源。违反则数字不得作为门禁/裁决依据 |
| `MECHANISM-REGISTRY.md` | 已因果验证但**未获准成为候选**的机制及其解锁条件 |
| `2026-08-13/RULINGS-2026-08-13.md` | 三条线的裁决与执行边界，**与任何任务书冲突时以它为准** |

### 量纲校准（最容易搞错的地方）

```
单基准 +1%   → geomean +0.066 pp
单基准 +10%  → +0.637 pp
PdfJS 修到 1.0 → +1.69 pp
zoo MDE（7 pad × 8 samples） = 0.278 pp
组包目标应取 0.35–0.40 pp 以留余量
```

⇒ **「找到 20M cycles」「省掉 2 cycles/opcode」除非跨多基准复用，否则从一开始就不够。**

### 裁决指标

**zoo 分数，不是 cycles。** fixed-work insn/cycles 只作机制证据。
理由：D6 实测 TypeScript fixed-work cycles **1.0817x** 而 zoo 分数 **0.826**，
模型对 throughput 低估 **10.16%**。

判据：**≥3 条 pad 谱系，中位有利 且 最坏 pad 不回退 且 效应 > MDE**，并报效应/离散比。
⚠️ **单 pad 的 bootstrap 会系统性低估不确定度**——某候选在 pad0 判两项「显著」，
换 pad3 后 15 个基准里 **9 个符号翻转**。

---

## 3. 已封板的方向（**不要重启**）

### 调用边界的 12.46 cyc/call 无主后端停顿 — 六条独立诊断

| 诊断 | 攻击面 | 上限 |
|---|---|---:|
| D1 | 删指令 | +0.234% |
| D2 | cache-miss | +0.0385%，**且 2.89x 信号本身是假的**（L1 refill，99.8% L2 命中，真 LL miss 仅 15.2K） |
| D7 | 首分派依赖链 | **0.000%**（双探针，阳性控制通过：强塞链能检出 +2.32 cyc） |
| D8 | SPE 逐指令延迟 | **0.000%**，最热 IP 仅占 ISSUE weight 0.83%，**弥散无单点** |
| D9 | 帧复用子系统 | −0.27%（三 pad 全败），且普通 `op_call2` 对复用状态读写**全为 0** |
| IMPL-TEARDOWN | 共享出口 ABI | 负（RT +1.303%）；静态代码 19,868→6,768 B 但动态指令增加 |

### 浮点表示与调度（D12，已 CLOSED）

NaN boxing 恶化（串行惩罚 2.986→**9.998**）；operand 前置加载**拿延迟换吞吐**；
tag-before-payload 无收益（21.0193→21.0255）；16B 宽度不是病因；
**C ABI 边界已被编译器消除**。
⚠️ 关键负结论：**机制暴露量甚至不能预测 benchmark 移动方向**
（navier 暴露 109.16M 却回退 0.24%，box2d 仅 23.62M 却改善 1.57%）。

### 布局彩票不是杠杆

7-pad zoo 极差仅 **0.380pp**，最好 pad 仅 +0.268%，且源码一改排名重排。

### call/frame 固定税（CALL-BOUNDARY，已 CLOSED）

三个继续条件全不满足：PdfJS backtrace 税 14.074M < 20M；
跨 Zoo 暴露 132.237M raw → 校准后仅 **0.1355 pp** < 0.20 pp；
return 区域虽在 13/15 基准上 8/8 同向，但仍是**未具名区域**且与已封板的弥散调用税重叠。

---

## 4. 已归档的诊断（可复用，勿重做）

| 基准 | 状态 | 关键结论 |
|---|---|---|
| EarleyBoyer | 已归因 | 0.6450→0.798。闭包 +223M / GC 环收集 +193M / **构造 bypass 准入税 +182M（qjs 完全没有）**；属性读 −216M、属性发布 −222M 是 zjs 优势 |
| RayTrace | 已归因 | 调用机制合计 +515M（49.2%）、apply/arguments +249M；opcode 数 z/q **1.0013**（差距 100% 是单位成本） |
| PdfJS | **PHASE-1 FROZEN** | 总赤字订正为 **219.315M**（旧的「137M / 60% 未解释」已 SUPERSEDED）；97.6–97.9% 已归属；**无占比 ≥10% 的主导机制** |
| TypeScript | 已归因 | return teardown **10.10x** +189M；slow property resolver **3.24x** +180M（指令 390 vs 104） |
| DeltaBlue | 已归因 | 调用/帧/构造同边界 595.6M = 其赤字 **80.4%**；qjs 有 7.06M 次 `tail_call_method` 而 zjs **为 0** |
| stack-cache 模拟 | **9/15 归档，机会门 PASS** | A1 消除 operand-stack loads 的 0.298–0.661，A2 0.406–0.847；**local slot traffic 不在覆盖内**；1-slot 失效率 0.502–0.782 |

⚠️ **六个基准从未被归因过**：zlib / richards / mandreel / box2d / gbemu / splay，
合计占总赤字 **39.1%**。

---

## 5. 唯一存活的假设

```
readfwd-harness   CPU 5   运行中   A1/A2 read-forwarding codegen 生死门
```

**问题**：在保持 memory stack authoritative 的前提下，跨 handler 转发 1–2 个值，
能否真正缩短 dependent chain，而不是再次拿延迟换吞吐？

**状态不是「方向明确」，而是：动态覆盖已证明；机器码可行性完全未知。**

硬停止条件（任一触发即 NO-GO）：dependent FP / integer chain 稳定回退（**永久** NO-GO）、
empty dispatch 回退、A2 参数落栈、hot handler 新增 spill、handler frame 增长、
musttail 未完全消除、GP↔FP 依赖链变长。
⚠️ **「instructions 下降但 dependent cycles 上升」这个形态一出现就停**——这是 d12 的死因形态。

---

## 6. 如果 readfwd 也失败

**不要继续找第九个微机制。** 应做一次架构边界决策：

- **路径 A｜严格 QuickJS-faithful**：按子系统积累多个已验证机制，凑成超过 MDE 的
  coherent package，预期是多轮 0.5–1pp 的累积式收敛。风险低，但慢。
- **路径 B｜性能优先，扩大允许的实现机制**：generic 2-slot operand cache、
  local-slot forwarding、accumulator/registerized 解释器状态、superinstructions、
  inline cache、profile-guided opcode/layout、QJS-shaped 生成式 dispatch core。
  这些不一定改变可观察语义，但越过当前「只做 QuickJS 已有机制或纯承载优化」的边界。

⚠️ 规则措辞已建议修订（`RULINGS-2026-08-13.md` §2.1）：
现行「不得引入 QuickJS 没有的机制」无法自洽解释 zjs **现有**的 musttail threaded dispatch，
应改为「不得引入 QuickJS 没有的**语义**机制、快捷语义路径或工作量绕过；
允许不改变逻辑执行模型的代码生成、状态承载和布局优化」。

---

## 7. 工具与操作

```bash
bash tools/perf/codex_run.sh launch <名字> <CPU> <worktree> <prompt文件>
bash tools/perf/codex_run.sh status      # 状态表
bash tools/perf/codex_run.sh show <名字> # 结论
bash tools/perf/codex_run.sh reap        # 回收残留进程组
```

⚠️ **不要用 `pgrep -f`** 判活——它会匹配脚本自身的命令行。2026-08-13 因此连续两次误判，
等待器永不触发、状态永远显示「运行中」，掩盖了任务其实早已完成 2 小时。
`codex_run.sh` 改用「启动落 PID + 完成落 marker」。

### 机器

```
大核 Cortex-X925 3.9GHz   cpu 5-9,15-19   PMU armv8_pmuv3_1
小核 A725      2.808GHz   cpu 0-4,10-14   PMU armv8_pmuv3_0
```
**必须绑核，不加 flock**（10 个同型大核可并行）；**同一 A/B 两侧必须同核交错**；
`perf stat` 会给未绑核 PMU 输出 `<not counted>`，必须过滤。
⚠️ 派任务时**把核号写进任务书防撞核**——2026-08-13 曾误让两个任务共用 CPU 5，
污染了一整条 pad 谱系。

### 门禁

`test-exec` / `test-bytecode` / `zig build test -Doptimize=ReleaseSafe` / `lint_anti_goals.sh`。
**canonical `zig build test262-gate` 只在 main 由 driver 亲跑**，不外包。
当前基准线：`0/49775 errors, passed 44581`。

---

## 8. 反复踩的坑（六次以上）

1. **微基准隔离出的机制 ≠ 宏观路径真走那条机制** —— 已犯 **6 次**
   （69 次出线、153 次出线、totalEvents 当命中数、instanceof 账面闭合、
   `Vector.dot` fixed-work 慢但 zoo −0.071%、PdfJS `getCode` 微基准 1.257 但 zoo 三 pad 全恶化）。
   **任何归因都必须配出线口计数器确认宏观路径真的进入该分支。**
2. **「zjs 出线函数 vs qjs 某函数」系统性高估** —— qjs 大量内联进 `JS_CallInternal`，同役踩过 3 次。
3. **qjs 的 CASE 行范围有陷阱** —— `BREAK` 在末尾使范围含**下一条** opcode 的分派，
   且多个 CASE 共享 `set_true`/`free_and_set_false` 尾标签。
   只取 `CASE(OP_is_null)` 那 7 行会读出**假的 7.12x**。
4. **计数器构建不是 cost-neutral** —— 会触发 `get_arg0..3` size ASSERT；**只供频率**。
5. **单 pad 显著性判定不可信**（见 §2）。
6. **19 个候选只有 2 个落地** —— 命中率约 10%，属正常，不要因为连续否定就放宽判据。

---

## 9. 实现差异审计（2026-08-13/14）—— ⚠️ 未经核查

分支 `audit/impl-divergence-20260813`（worktree `/home/aneryu/worktree-impl-audit`），
commit `c4fd68fc`，产物 `docs/qjs-align/IMPL-DIVERGENCE-2026-08-13/`（4.2 MB / 55,623 行）。

**1,017 条语句级差异**（臂序 / 谓词强度 / 退出点 / 操作次序 / 每次执行次数 / 常量阈值 /
结构体布局 / 定义但不发射 / 完全缺失 / zjs 独有），16 份子系统报告 + README。

### ⚠️ 可信度

**只有 6 条经手工差分复现：4 确认 / 1 核不实 / 1 前提缺失。** 其余 1,011 条未核。
全量核查 workflow（33 agent）因额度耗尽**零条完成**。
**读之前先读 `VERIFICATION-STATUS.md`；不得当作可执行清单。**

恢复核查：`Workflow({scriptPath: ".../zjs-qjs-divergence-full-verification-wf_f18cb246-df9.js",
resumeFromRunId: "wf_f18cb246-df9"})`。关键产出是「一审被推翻比例」。

### 已确认可直接行动的 4 条（附复现，见 VERIFICATION-STATUS.md）

| # | 缺陷 | zjs | qjs | 支付频率 |
|---|---|---|---|---|
| 1 | 正则递归无栈溢出检查 | **exit=139 SIGSEGV** | SyntaxError | 每次正则编译 |
| 2 | 属性读兜底到 `globalThis.<Ctor>.prototype` | `f.zzz===1` 而 `'zzz' in f===false` | 均 undefined/false | **每次属性读 miss** |
| 3 | switch 落穿丢失（case 尾为回边 goto 时） | `"a,d"` | `"a,b"` | 每 switch（窄条件） |
| 4 | generator 内 `for (var yield of …)` | 接受 | SyntaxError | 每次解析 |

⚠️ 第 2 条同时是正确性 bug 与纯税（qjs 在该位置成本为 0）；第 3 条触发条件很窄，
普通 case 尾**不复现**——写复现时必须用 `while(true){…break;}` 形态。

### 差分跑机
`/home/aneryu/worktree-impl-audit/difftest.sh <js>` —— 并排两侧 stdout+stderr+exit，
自动判 IDENTICAL / DIFFER / DIFFER—崩溃。**任何行为类断言都应先过它再相信。**
