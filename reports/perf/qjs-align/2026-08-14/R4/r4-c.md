# R4-C LEDGER — TS fixed-work 残差

lane: R4-C / CPU 8  
日期：2026-08-14。诊断批。  
接 `ts-88-percent-refuted-2026-08-11`（commit `dec6961d`）。

## 闭合声明

**旧 782M 残差作废，当前净超出重测后闭合到 ±10%。**

`dec6961d` 上 FW 是 1.0812x / +367M，残差 other +782M（净超出的 213%）。  
当前生产（`12bc8b8a`，含 X-10 等）FW **1.0291x / +132M**。782M 不能再当现账。

## 当前 FW（d16，8 samples，CPU 5）

| | qjs | zjs | z/q | 超出 |
|---|---:|---:|---:|---:|
| cycles | 4.624G | 4.756G | **1.0291** | **+132M** |
| insn | 16.145G | 17.890G | 1.1081 | +1.745G |

IPC z/q = 1.0775：zjs 指令更多但更饱，所以 cycle 差远小于指令差。

## 7 桶守恒（labeled qjs）

份额 × 上表。

| 桶 | z 份额 | q 份额 | z Mcyc | q Mcyc | 超出 M | 占净 |
|---|---:|---:|---:|---:|---:|---:|
| other | 21.5% | 9.8% | 1023 | 453 | **+570** | 432% |
| dispatch | 15.5% | 13.0% | 737 | 601 | +136 | 103% |
| property | 37.0% | 37.0% | 1760 | 1711 | +49 | 37% |
| call | 17.3% | 19.1% | 823 | 883 | −60 | −45% |
| arith | 0.2% | 0.3% | 10 | 14 | −4 | −3% |
| string | 5.9% | 9.5% | 281 | 439 | −158 | −120% |
| GC（分类器字面） | 0.1% | 4.3% | 5 | 199 | −194 | −147% |
| alloc | 2.6% | 7.1% | 124 | 328 | −204 | −155% |
| **合计** | | | 4763 | 4628 | **+135** | **102%** |

Σ 超出 +135 vs PMU +132，**残差 2%**。守恒成立。  
other 的 432% 被 GC/alloc/string 的 zjs 优势对冲——形态与 ts-88「三桶净优势、残差 > 净超出」同构，只是量级从 367M 收到 132M。

## other 拆开（zjs 顶符号）

| 符号 | samples | 应归 |
|---|---:|---|
| `Object.destroyRuntimeCyclesWithValueR` | 2117 | RC / teardown（禁区 IMPL-TEARDOWN 可记账） |
| `Object.traceChildren` ×2 | 3844 | RC / 扫描 |
| `Machine.pushExactSimpleFrame` | 1575 | call |
| `Object.destroyFromHeader` | 952 | RC |

这四项占 other 的 ~80%。把 destroy/trace 并进 GC/RC 后：

- zjs RC+GC ≈ 14.2% × 4.756G = 675M
- qjs GC 4.3% × 4.624G = 199M
- 超出 **+476M**（teardown 家族，含 ts-88 的 +189M 10x teardown）

剩余 other（atom intern、alloc 内联、ctor）约 −100M 量级。  
**782M「未归因 other」在当前二进制上就是 RC destroy/trace + frame push，加上分类器把 qjs GC 算进 GC、zjs RC 算进 other 的错位。**

## 与 ts-88 锚点

| 锚点 | ts-88 (`dec6961d`) | 本轮 |
|---|---|---|
| teardown 10x +189M | 有效 | 仍在 destroy/trace/frame；禁区只禁再投工程 |
| slow property +180M | X-10 后需重测 | property 桶两侧 37.0%/37.0%，超出仅 +49M。X-10 后慢路径税已大幅收缩 |
| GC zjs 优势 265 vs 682 | 有效 | 分类器字面 GC −194M；把 zjs destroy 加回去后 RC 变正，collector 仍可能是优势 |
| 残差 782M | **过时** | 现净 +132M，other 已点名 |

## 与 R4-T

R4-T 证明 17% 折差是前端摊销。R4-C 的 1.029x 是整进程；内层循环是 1.215x。  
driver 合账：分数差 1.205x ≈ 内层 1.215x；整进程 1.029x 的 +132M 被前端优势压扁，**不能**拿 +132M 去除以 1.205 去估 zoo pp。

## [PROGRESS]

```
[PROGRESS] R4-C 782M STALE; current net +132M
[PROGRESS] R4-C 7-bucket +135 vs +132 (2%)
[PROGRESS] R4-C other = RC destroy/trace + pushExactSimpleFrame
[PROGRESS] R4-C DONE closed
```
