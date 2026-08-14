# R4-P LEDGER — pdfjs 守恒台账

lane: R4-P / CPU 6  
日期：2026-08-14。诊断批。  
zjs `12bc8b8a…cf3309d` / qjs `b76d1542…` / labeled-qjs `394d453d…`（仅频率）

## 闭合声明

**闭合到 ±10%。** 同时更正 G2：HANDOFF / `PDFJS-DIAG-FINAL.md` 已把「137M / 60% 未命名」标为 **SUPERSEDED**。本 lane 用现生产 PMU 复测，净超出 **+216M cyc**（旧档案 219.315M），7 桶之和 +215M（**残差 0.5%**）。

## 实测总超出（FW d16，8 samples，CPU 5 折差 PMU）

| | qjs | zjs | z/q | 超出 |
|---|---:|---:|---:|---:|
| cycles | 1.107G | 1.323G | 1.1955 | **+216M** |
| insn | 5.884G | 6.187G | 1.0515 | +303M |

与冻结档案 219.315M 差 1.5%。

## 7 桶守恒（labeled qjs + 生产 zjs，`perf record -c 500009`）

份额 × 上表 PMU 中位数。

| 桶 | zjs 份额 | qjs 份额 | z Mcyc | q Mcyc | 超出 M | 占净超出 |
|---|---:|---:|---:|---:|---:|---:|
| dispatch | 30.3% | 20.7% | 401 | 229 | **+172** | 80% |
| property | 15.3% | 10.9% | 202 | 121 | **+81** | 38% |
| other | 18.1% | 10.2% | 239 | 113 | **+126** | 58% |
| string | 11.9% | 13.2% | 157 | 146 | +11 | 5% |
| call | 11.0% | 17.1% | 146 | 189 | −43 | −20% |
| arith | 2.1% | 4.6% | 28 | 51 | −23 | −11% |
| alloc | 11.1% | 22.6% | 147 | 250 | −103 | −48% |
| GC | 0.2% | 0.8% | 3 | 9 | −6 | −3% |
| **合计** | | | 1323 | 1108 | **+215** | **99.5%** |

交叉验证锚点（冻结档案，period 65521）：dispatch +153 / string+regexp +69 / call +61 / arith −32 / alloc −19。  
符号全部一致。绝对值因分类器边界（`stringAdd` 进了 other、call vs dispatch 切法）有挪动，**净守恒成立**。

冻结档案因果命名仍有效：backtrace 14.07M（6.4%）、rope strict-eq 9.62M（4.4%）。无 ≥10% 单机制。VERIFIED-LEDGER §4.4 zjs-only 热频没有单独解释这 216M。

## 与 R4-T 对账

pdfjs 折差 +6.56%（1/zoo 1.274 vs FW 1.196）。与 TS 同类、更弱：整进程 PMU 含前端，分数只量循环。不是未命名的 60% 机制。

## 堆（`-d`）

FW：zjs alloc 32.7MB / 27886 obj；qjs used 25.4MB / 24562 obj。  
timebox：zjs 17.2MB / 21266 obj；qjs used 16.8MB / 24548 obj。  
timebox 两侧堆接近。FW 下 zjs 对象 +13.5%——§4.2 数组容量（141 vs 100 槽）方向符合，但解释不了 216M 循环税。

## [PROGRESS]

```
[PROGRESS] R4-P G2 60% SUPERSEDED (HANDOFF + this rerun 216M)
[PROGRESS] R4-P 7-bucket sum +215M vs PMU +216M (0.5%)
[PROGRESS] R4-P DONE closed
```
