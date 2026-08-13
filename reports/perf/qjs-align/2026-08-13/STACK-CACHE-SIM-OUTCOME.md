# STACK-CACHE-SIM-OUTCOME

**Decision: workload opportunity passes; production ABI remains on hold**

```
STACK-CACHE-SIM
Final-methodology coverage: 9 / 15
Opportunity gate:           PASS
Full-Zoo aggregation:       NOT AVAILABLE
Production implementation:  HOLD
Next gate:                  independent read-forwarding codegen harness (A1/A2)
```

## 1. 实验范围与数据完整性

```
raw traces (final methodology):   9 / 15 complete, gzip -t all OK
initial reduction:                9 / 15
final archived reduction:         9 / 15
samples:                          69, zero buffer overflow, edge count conserved in all
```

⚠️ **未重跑、未补采任何 benchmark。** 在线任务在无文件写入时终止。

**NOT REDUCED**: `raytrace / regexp / richards / splay / typescript / zlib`
> Superseded-methodology traces exist but are **not interoperable**.
> 逐字段比对确认两版在 33 处字段不等价（crypto 连 `baseline`/`eliminable` 都不同，
> `one_slot_failure` 与 `local_round_trips` 在多个基准上变化）。
> 补齐延后到 codegen harness 通过之后，届时按合同第 12 条用
> `divisor=256 + single sample` 重跑。**现在重跑是在优化报告，不是在优化引擎。**

⚠️ **本报告的聚合值只对 9 个 final-methodology benchmark 成立，不得称为 full Zoo。**
缺失的 6 个中既有当前重要缺口也有已领先项，可能改变等权聚合与 flush 类型分布。

provenance 见 `stack-cache-traces/TRACE-MANIFEST.json`（commit、binary hash、逐文件 SHA-256）。

## 2. A/B 模型定义

```
A (read-forwarding opportunity)
    eliminable_loads / baseline_operand_stack_loads
    内存始终 authoritative，producer 仍写回；只计可消除的 load

B (write-back opportunity)
    (avoided_loads + avoided_stores - flush_materialization_stores)
        / baseline_operand_stack_total_traffic
```

⚠️ **A、B 分母不同，数值不可直接横向比较。** B 尚未获得后续实现授权。

⚠️ **本表只衡量 workload opportunity，不预测 cycles，也不证明实际实现会获益。**
d12 已证明「减少指令/traffic」与「缩短依赖链」可能方向相反。

## 3. 逐 benchmark 决策表（9 / 15）

| benchmark | A1 | A2 | B1 | B2 | depth-2 增量 | 主 flush 原因 | n | 稳定性 |
|---|---:|---:|---:|---:|---:|---|---:|---:|
| box2d | 0.661 | 0.825 | 0.502 | 0.750 | +0.164 | capacity_evict | 8 | Δ0.0000 |
| code-load | 0.298 | 0.406 | 0.102 | 0.265 | +0.108 | cold_helper | 8 | Δ0.0000 |
| crypto | 0.575 | 0.847 | 0.366 | 0.774 | +0.272 | capacity_evict | 8 | Δ0.0000 |
| deltablue | 0.506 | 0.560 | 0.313 | 0.394 | +0.054 | call | 8 | Δ0.0000 |
| earley-boyer | 0.499 | 0.576 | 0.306 | 0.424 | +0.076 | call | 8 | Δ0.0000 |
| gbemu | 0.580 | 0.752 | 0.400 | 0.658 | +0.172 | capacity_evict | 8 | Δ0.0000 |
| mandreel | 0.536 | 0.830 | 0.311 | 0.751 | +0.294 | capacity_evict | 8 | Δ0.0000 |
| navier-stokes | 0.514 | 0.685 | 0.319 | 0.576 | +0.172 | capacity_evict | 8 | Δ0.0000 |
| pdfjs | 0.509 | 0.712 | 0.291 | 0.601 | +0.203 | capacity_evict | 5 | Δ0.0000 |

- **按动态 stack traffic 加权**：A1 0.548 · A2 0.773 · B1 0.342 · B2 0.679
- **benchmark 等权**：A1 0.520 · A2 0.688 · B1 0.323 · B2 0.577

**样本稳定性：全部基准 Δ = 0.0000。** 分布完全收敛——重复样本零信息增益。
这就是测量合同第 12 条的事故来源。
point estimate 取 `sample-01` 作为 canonical，其余样本仅用于收敛证明。

## 4. 三个结构性发现（限定于 9 个 final-methodology benchmark）

### 4.1 2-slot 的增量是真实且广泛的

A2 相对 A1 的增量：**+0.054 ～ +0.294，中位 +0.172**。
**2-slot 不是边缘扩展，而是主要机会来源之一。**
而 2-slot 正是机器 ABI 风险最高的一档（JSValue 16 字节 = 2 个寄存器，
现有 handler 已占 4 个参数寄存器），必须由 codegen harness 用反汇编确认。

### 4.2 容量驱逐比语义 flush 更重要

| benchmark | 1-slot 失效比例 | 主 flush 原因 |
|---|---:|---|
| box2d | 0.652 | capacity_evict |
| code-load | 0.678 | cold_helper |
| crypto | 0.732 | capacity_evict |
| deltablue | 0.640 | call |
| earley-boyer | 0.740 | call |
| gbemu | 0.647 | capacity_evict |
| mandreel | 0.782 | capacity_evict |
| navier-stokes | 0.502 | capacity_evict |
| pdfjs | 0.737 | capacity_evict |

6/9 由 `capacity_evict` 支配（0.69–0.95）：**主要损失不是 call、异常或 helper seam，
而是缓存深度本身不足。**

⚠️ **DeltaBlue 与 EarleyBoyer 必须单列**——它们由 `call` seam 主导（0.61 / 0.32），
可能代表另一类 workload，**不能用统一模型解释全部基准**。

1-slot 相对 2-slot 的额外加载比例为 **0.502–0.782**，
`mul → get_loc b → add` 型驱逐是**常态而非边缘**。

### 4.3 local-slot traffic 是独立问题

9 个基准**全部** `eliminable_by_pure_tos_cache = False`、
`local_slot_traffic_in_tos_coverage = False`。

⛔ **禁止外推**：「TOS forwarding 能解决 Navier 或 DeltaBlue 的完整依赖链成本」。
它只处理 operand stack。local / arg / var slot 的立即 store→load 需要另一种机制；
当前项目规则下**不应顺手扩展为 local value cache**，
否则会把一个受控的 read-forwarding 实验扩大成新的 register/accumulator VM 状态模型。

（DeltaBlue 有 30,374,030 次 immediate put→same-local-get 完全不在覆盖范围内。）

## 5. 措辞约束

本报告**不得**被引述为「可消除解释器栈流量的 77%」。严格表述是：

> 在所模拟的 operand-stack read-forwarding 模型下，可消除 baseline **operand-stack loads**
> 的相应比例；**local / arg / var slot traffic 不在该模型覆盖范围内**。

## 6. 下一阶段批准范围

批准 **独立的 read-forwarding codegen harness**，仅测：

```
baseline memory stack
A1: 1-slot read-forwarding
A2: 2-slot read-forwarding
```

⛔ 不测 write-back；不碰生产 handler；不改 RC / live-stack 合同。

**硬停止条件（任一触发即 NO-GO）**：

```
dependent FP chain 稳定回退        -> 永久 NO-GO
dependent integer chain 稳定回退   -> 永久 NO-GO
empty dispatch 回退                -> NO-GO
A2 参数落栈                        -> NO-GO
hot handler 新增 spill             -> NO-GO
handler frame 增长                 -> NO-GO
musttail 未完全消除                -> NO-GO
GP<->FP 依赖链变长                 -> NO-GO
```

只有同时满足「dependent 不回退 + independent 改善 + A2 不 spill + empty dispatch 不回退」，
才值得补那 6 个 trace 并开始估算完整 Zoo 价值。

**当前状态不是「方向明确」，而是：动态覆盖已证明；机器码可行性完全未知。**

