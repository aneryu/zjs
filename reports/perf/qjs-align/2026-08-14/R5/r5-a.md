# R5-A BUDGET — 算术 / 比较 / 分支 / 位运算（含 zlib per-opcode）

lane: R5-A / CPU 7 / 诊断批，src 只读  
日期：2026-08-14  
config / 指纹：同 R5-S。  
锚点：zlib · mandreel · box2d · gbemu。

## 结论先行

1. **zlib 是单热循环、谱极窄、C=0.0%。** 4.019G opcode。R4-U「dispatch+call=净超出 111%」在本批被 **改写**：call 份额是 0；「dispatch」是 `tailcall_dispatch.*` 误桶（见 R5-S §4）。
2. **A 家族热体同样是 ZJS-ADVANTAGE。**  
   int `add` 17 vs 23、`or` 13 vs 16、`sar` 13 vs 17、`and/xor` 同形 −3、`shl` −4、`shr` −11 静态。qjs `OP_add`（quickjs.c:19696–19710）热臂把同一槽 `ldp` 两次（x2/x5 与 x6/x7），zjs 只 `ldur` 两次 tag。
3. **PMU 与静态同向在 insn、反向在 cycles：**  
   zlib insn z/q **0.9355**、cycles **1.0862**、IPC **0.8609**（R4-T d16 n=8 CPU5）。zjs **少跑 6.5% 指令、多付 8.6% 周期**。
4. 闭合：Σ(freq×Δinsn) 为负，对准 insn 轴 ±15%。周期残差 = 分派 I-cache/BTB（ARCHITECTURAL），不是少写 `add` 能收回的。
5. **无 FAITHFUL-FIXABLE 过门槛项。** 不要按 zoo 去「加速 zlib 算术」——算术已经更快。

## 1. 频次

| bench | A 份额 | 头部 A |
|---|---:|---|
| zlib | **33.8%** | or 9.7 / sar 5.6 / add 5.3 / shr 2.0 / if_false8 1.9 / shl 1.8 / sub 1.4 / and 1.3 |
| mandreel | 28.3% | （宽谱，无单点 ≥10%） |
| gbemu | 28.0% | |
| box2d | 22.9% | |
| crypto | 35.0% | 资产，勿回退 |
| navier | 34.1% | 资产 |

zlib 头部 A ∪ S ∪ `get_array_el` 已过家族超出的 90%。

opcode 数 z/q：zlib 0.9980 / mandreel 1.0002 / box2d 0.9996 / gbemu 1.0001。**不是多跑 bytecode。**

## 2. 热路径（int 臂，含 SWITCH 尾）

冷路：zjs `cbz/b.hi` 失败则 `br cold_table[+0x988]`。下表只计 int 成功臂。

### 样张 `add` int（quickjs.c:19696 `JS_VALUE_IS_BOTH_INT` + 溢出升 float）

zjs `opBinary add` 热：5（tag `orr`+`cbz`）+ 12（`ldursw`×2 / `add` / `cmp sxtw` / `stur` / dispatch 5）= **17**。

qjs 23：四次 `ldp`（同一 −32/−16 槽打两遍）+ `sxtw` 溢出 + `stur` 结果/tag0 + SWITCH。

### 样张 `or` / `sar`（zlib 第一、第二热算术）

zjs `or`：

```
ldur x8, [x1, #-24]     // lhs tag
ldur x9, [x1, #-8]      // rhs tag
orr  x8, x9, x8
cbz  x8, int_path       // 两 tag 都是 0
; cold br
int_path:
ldr  w8, [x1, #-16]!    // rhs payload，sp--
ldur w9, [x1, #-16]     // lhs payload
orr  w8, w9, w8
stur x8, [x1, #-16]     // 结果，tag 槽保持 0
; dispatch 5
```

13 vs qjs 16（quickjs.c 位运算 CASE，同样 `JS_VALUE_IS_BOTH_INT`）。

`sar` 13 vs 17，多一条 `asr`，结构相同。

### 预算表

| opcode | zlib freq | z hot | q hot | Δinsn | freq×Δ / 1e9 | 归类 | 裁决 |
|---|---:|---:|---:|---:|---:|---|---|
| or | 9.7% | 13 | 16 | −3 | −1.17 | 值搬运 + arith | **ZJS-ADVANTAGE** |
| sar | 5.6% | 13 | 17 | −4 | −0.91 | 同上 | **ZJS-ADVANTAGE** |
| add | 5.3% | 17 | 23 | −6 | −1.29 | 同上；qjs 双 ldp | **ZJS-ADVANTAGE** |
| shr | 2.0% | ~13 | 20 | −7 | −0.56 | 同上 | **ZJS-ADVANTAGE** |
| shl | 1.8% | ~13 | 17 | −4 | −0.29 | 同上 | **ZJS-ADVANTAGE** |
| and | 1.3% | 13 | 16 | −3 | −0.16 | 同上 | **ZJS-ADVANTAGE** |
| if_false8 | 1.9% | ~14 | 22 | −8 | −0.61 | 分支 + interrupt_counter（qjs:7877） | **ZJS-ADVANTAGE** |
| sub | 1.4% | （同 add 形） | 22 | ~−5 | −0.29 | 同上 | **ZJS-ADVANTAGE** |
| mul | RT 2.6% | ~20 | 23 | −3 | — | 多一条 `−0*−0` 零检查 | 近平 / 略优 |
| lt | pdfjs 4.1% | 18 | 17 | +1 | — | 比较 | 近平 |

A 家族 zlib Σ(freq×Δinsn) ≈ **−5e9**。加上 S 的 −5e9，总量约 −10e9。相对 qjs 89.6G ≈ −11%，PMU insn −6.45%。符号一致，量级在 ±15% 宽松带（启动/GC/非 int 臂未进表，预算偏负是预期）。

## 3. 周期为什么更差

不是少写 `orr`。R4-T：insn 少、IPC 低。机制：

- 每个 opcode 一个 `align(64)` 函数 + `br x4`，zlib 内层在 `get_loc8`/`push_0`/`or`/`sar`/`put_loc8`/`add`/`get_array_el` 之间跳。
- qjs 全部 CASE 落在同一个 `JS_CallInternal`（quickjs.c:17749），computed-goto 目标在数十字节到数 KB 内。
- 这不是 D8「无主 ISSUE 单点」——有名字：musttail 分派的 I-cache/BTB。**ARCHITECTURAL。**

`get_array_el` 占 zlib 5.3%，handler **一进门就 `sub sp,#0x50` + 4×stp**（因为零 RC 臂 `bl destroyZeroRef`）。qjs CASE 无帧。这是 **P 家族** 的 FAITHFUL-FIXABLE 候选，见 R5-P；A 预算不靠它闭合。

## 4. 不要做

- 不要为 zlib 改 int `add`/`or`/`sar` 热体。  
- 不要把 R4-U 的 dispatch% 当「解释器循环本身 2×」。  
- 不要用 profile `avg_ns≈40` 定价——那是 `noteDispatch` 墙钟，不是生产单位成本。
