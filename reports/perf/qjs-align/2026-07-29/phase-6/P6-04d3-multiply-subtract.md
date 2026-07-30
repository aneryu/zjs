# P6-04d3 — multiply-subtract 内核：画像（d3a）与融合 carry 链（d3b）

- **日期**：2026-07-30
- **P0**：`e20425a2`　**P1**：`bdbd617d`
- **裁决**：**通过**。d3a 的反汇编直接指向**情况 A**，d3b 修掉它：
  **每 limb 指令 21.25 → 11.13（−47.6%）、周期 5.64 → 4.61（−18.3%）**；
  direct-core 全部形态变快、全 16 组合同向、单 limb 未动
- **原始数据**：`P6-04d3-results.json`

---

# 第一部分：P6-04d3a 画像

## 1. 八个问题的逐条回答

| # | 问题 | 结论 |
|---|---|---|
| 1 | 64×64→128 是否 `mul + umulh` | **是**，无 helper |
| 2 | carry 与 borrow 是否分开计算 | **是，而且更糟** —— 见 §2 |
| 3 | 每 limb 是否有条件分支 | **无**（`cset`/`cinc` 是无分支的，只有回边） |
| 4 | 是否残留 bounds check | **无**（`[base, idx, lsl #3]`，无比较） |
| 5 | 是否重复加载 `len` / base pointer / qhat | **无**，全部驻留寄存器（x28 / x24,x26 / x8） |
| 6 | `subMul` 是否有独立 native frame | **无** —— `subMulAt`、`addBackAt`、`shiftLeftInto`、`unshiftedLimbAt` 全部内联（`nm` 里 0 符号） |
| 7 | 是否有意外的 compiler-rt helper | **无** —— 整个函数只有 4 个 `bl`：2× `memcpy` + 2× `__udivti3`（reciprocal init 与低于阈值的估算）。没有 `__multi3` / `__suboti4` / `__umodti3` |
| 8 | add-back 是否在冷边 | 在同一函数体内、被 2 路展开，且**带有同样的缺陷**；但它冷（10192 商位里 24 次），只影响代码体积 |

## 2. ⚠️ 决定性发现：每 limb 两次**死存储**

`11e272c`–`11e277c`，**18 条指令**，未展开：

```asm
ldr   x12, [x26, x10, lsl #3]   ; divisor[i]
umulh x13, x12, x8              ; product high
mul   x12, x12, x8              ; product low
adds  x12, x12, x9              ; + carry
cinc  x9,  x13, cs              ; carry = high + carryout
ldr   x13, [x24, x10, lsl #3]   ; numerator[i]
subs  x12, x13, x12
cset  w13, cc                   ; ← 溢出位变成值
strb  w13, [sp, #192]           ; ← ★ 存到栈上，且从不读回
subs  x11, x12, x11
cset  w12, cc                   ; ← 第二个溢出位
strb  w12, [sp, #200]           ; ← ★ 又一次死存储
and   w12, w12, #0xff           ; ← 再窄化
and   w13, w13, #0xff           ; ←
str   x11, [x24, x10, lsl #3]   ; 结果
and   x11, x13, #0x1            ; ← 掩位
and   x12, x12, #0x1            ; ←
add   x11, x12, x11             ; borrow = first + second
add   x10, x10, #0x1
cmp   x28, x10
b.ne  ...
```

`@subWithOverflow` 返回 `struct{T, u1}`，LLVM 把两个 `u1` 各自**物化成寄存器、溢出到栈槽、
再窄化并掩位** —— 6 条纯开销指令，外加 **2 条写了永不读回的死存储**。
qjs 的写法里这些一条都没有。

`addBackAt` 是同一个模式（`cset` / `strb [sp,#208/#216]` / `and #0xff` / `and #0x1`）。

## 3. 成本矩阵（P0）

| shape | nb | 商位 | subMul limbs | ns/op | insn/op | cyc/op | IPC |
|---|---:|---:|---:|---:|---:|---:|---:|
| `4×4` | 4 | 1 | 4 | 53.93 | 1146.8 | 217.5 | 5.27 |
| `8×4` | 4 | 5 | 20 | 109.52 | 1748.9 | 439.3 | 3.98 |
| `12×4` | 4 | 9 | 36 | 154.98 | 2330.9 | 619.6 | 3.76 |
| `16×4` | 4 | 13 | 52 | 200.94 | 2914.6 | 800.6 | 3.64 |
| `8×8` | 8 | 1 | 8 | 59.30 | 1254.2 | 238.5 | 5.26 |
| `16×8` | 8 | 9 | 72 | 209.77 | 3134.1 | 834.6 | 3.76 |
| `24×8` | 8 | 17 | 136 | 344.37 | 4955.9 | 1362.8 | 3.64 |
| `16×16` | 16 | 1 | 16 | 70.35 | 1459.3 | 284.1 | 5.14 |
| `32×16` | 16 | 17 | 272 | 541.96 | 7896.6 | 2145.6 | 3.68 |

**IPC 从单商位形态的 5.14–5.27 掉到商位密集形态的 3.64–3.76** ——
subMul 循环本身跑得比其余代码稀疏，与栈流量一致。

## 4. 每 processed limb 的自身成本

固定 `nb` 扫商位求斜率，再对 `nb` 求差（三条轴：nb = 4 / 8 / 16）：

| | per-digit insn nb4 / nb8 / nb16 | **per-limb** |
|---|---|---:|
| **P0** | 147.3 / 231.3 / 402.3 | **21.25 insn** |
| **P0** cyc | 48.8 / 70.3 / 116.5 | **5.64 cyc** |

**21.25 insn/limb** 与反汇编（18 条循环体 + 3 条控制，未展开）一致。

**→ 情况 A 成立**：carry/borrow 链既有冗余算术，又有栈流量。

---

# 第二部分：P6-04d3b 融合链

## 5. 机制

镜像 qjs `mp_sub_mul1`（quickjs.c:11419），每 limb 一条 `u128` wrapping 链：

```zig
const wide: DoubleLimb = @as(DoubleLimb, numerator[i]) -%
    @as(DoubleLimb, limb) *% @as(DoubleLimb, qhat) -%
    @as(DoubleLimb, borrow);
numerator[i] = @truncate(wide);
borrow = 0 -% @as(Limb, @truncate(wide >> limb_bits));
```

**宽值的高半取负就是下一个 borrow**，因此溢出位永远不必变成一个值。
注意 borrow 是**整个 limb** 而不是 0/1 标志（与 qjs 一致），
所以顶 limb 用 wrapping 减法 + 无符号大于判断。

**只改 carry 链**：函数属性、估算、修正、add-back、归一化、分配拓扑全部未动。
`addBackAt` **刻意保留旧形态** —— 它冷（10192 商位里 24 次），
折进来会给这一刀加第二个机制。

## 6. 新循环：11 条/limb，LLVM 自行 2 路展开

```asm
ldur  x11, [x13, #-8]        ; divisor[i]
umulh x14, x8, x11
mul   x11, x8, x11
adds  x9,  x11, x9
cinc  x11, x14, cs
ldp   x14, x15, [x12, #-8]   ; ★ 成对加载 numerator[i], [i+1]
subs  x9,  x14, x9
ngc   x11, x11               ; ★ negate-with-carry = 下一个 borrow
stur  x9,  [x12, #-8]
neg   x9,  x11
...（第二个 limb 复用成对加载）
sub/cmp/b.ne
```

**没有 `strb [sp]`、没有 `and #0xff`、没有 `and #0x1`。**
22 条指令 / 2 limbs = **11 条/limb**。

## 7. 每 limb 成本：实测

| | per-digit insn nb4 / nb8 / nb16 | **per-limb insn** | per-limb cyc |
|---|---|---:|---:|
| P0 | 147.3 / 231.3 / 402.3 | 21.25 | 5.64 |
| **P1** | **103.2 / 146.8 / 236.7** | **11.13** | **4.61** |
| **Δ** | | **−47.6%** | **−18.3%** |

11.13 与反汇编的 11 条/limb 吻合。

## 8. 性能：两侧各 4 实例，全 16 组合

### 8.1 direct-core —— 全部变快，零回退

| 组 | case | P0 ns | P1 ns | **geomean** | [min, max] |
|---|---|---:|---:|---:|---|
| 主目标 | `div-size-16x8` | 209.62 | **184.94** | **0.8850** | [0.8805, 0.8952] |
| | `mod-size-16x8` | 211.48 | 187.70 | 0.8899 | [0.8870, 0.8977] |
| | `div-size-24x8` | 342.83 | **301.45** | **0.8814** | [0.8771, 0.8901] |
| | `mod-size-24x8` | 345.35 | 304.39 | 0.8844 | [0.8797, 0.8951] |
| | **`div-size-32x16`** | 541.08 | **464.08** | **0.8571** | [0.8536, 0.8594] |
| | `div-size-8x4` | 109.16 | 99.40 | **0.9095** | [0.9009, 0.9158] |
| | `mod-size-8x4` | 109.18 | 100.54 | 0.9205 | [0.9153, 0.9248] |
| | `div/mod 12x4` | 154.85 / 155.00 | 140.23 / 141.15 | 0.9057 / 0.9113 | 同向 |
| | `div/mod 16x4` | 201.13 / 202.63 | 181.94 / 183.82 | 0.9052 / 0.9076 | 同向 |
| 单商位 | `div/mod 4x4` | 53.34 / 54.04 | 49.75 / 50.80 | 0.9321 / 0.9384 | 同向 |
| | `div/mod 8x8` | 58.94 / 60.91 | 54.06 / 56.92 | **0.9171** / 0.9348 | 同向 |
| | `div/mod 16x16` | 69.99 / 73.88 | 63.36 / 67.96 | **0.9046** / 0.9188 | 同向 |
| | `div/mod 32x32` | 94.13 / 101.33 | 84.20 / 92.34 | 0.8891 / 0.9057 | 同向 |
| | `div/mod 2x2` | 49.64 / 50.42 | 48.23 / 48.76 | 0.9714 / 0.9664 | 同向 |
| 低于阈值 | `div/mod 5x4` | 70.06 / 70.78 | 64.70 / 65.83 | 0.9236 / 0.9295 | 同向 |
| | `div/mod 6x4`（哨兵） | 88.39 / 89.13 | 82.16 / 82.93 | 0.9291 / 0.9305 | 同向 |
| | `div/mod 9x8` | 82.67 / 84.90 | 75.47 / 77.99 | 0.9120 / 0.9181 | 同向 |
| 单 limb | `div/mod 1x1` | 34.92 / 34.81 | 34.93 / 34.78 | 1.0018 / 0.9977 | 跨 1.0 |
| | `mod-size-2x1`（哨兵） | 38.76 | 38.86 | 1.0009 | 跨 1.0 |
| | `div/mod 8x1` | 101.92 / 101.07 | 102.09 / 101.09 | 1.0003 / 1.0006 | 跨 1.0 |
| | `div/mod 16x1` | 188.03 / 187.96 | 188.25 / 187.97 | 1.0009 / 1.0004 | 跨 1.0 |

**单 limb 四个形态全部跨 1.0**（0.9977–1.0027），确实未被触及。

收益随 subMul 工作量单调上升：`2×2`（4 limbs）−2.9% → `32×16`（272 limbs）−14.3%。

### 8.2 JS 层

| case | P0 | P1 | **geomean** | [min, max] | 同向 | **P1/qjs**（P0） |
|---|---:|---:|---:|---|---|---:|
| **`bigint_div_16x8`** | 0.0238 ms | **0.0217** | **0.9081** | [0.9074, 0.9087] | ✓ | **1.21**（1.33） |
| `bigint_div_8x4` | 0.0379 | 0.0365 | **0.9662** | [0.9639, 0.9702] | ✓ | **2.58**（2.68） |
| `bigint_mod_8x4` | 0.0337 | 0.0339 | 1.0033 | [0.9988, 1.0055] | ✗ | 1.54（1.53） |
| `bigint_div_8x1` | 0.0238 | 0.0238 | 1.0007 | [0.9968, 1.0029] | ✗ | 1.93（1.93） |
| `local_arith_loop`（对照） | 6.0030 | 6.0010 | 0.9997 | [0.9989, 1.0007] | ✗ | — |

`mod_8x4` 在 JS 层中性（不回退）—— 与 d2a/d2b 之后它已由固定成本主导一致。

## 9. 内核 lockstep

`fused multiply-subtract matches the reference limb for limb`：

参考实现**按定义**写（每 limb 显式 `i128` borrow），与被测的融合 wrapping 链**不共享任何算术形态**。覆盖：

- 宽度 **2..32 limbs** × 7 种 limb 模式（全 0 / 全 maxInt / 交替位 / 仅顶 limb / 全 1 / 顶位 / 随机）
  × 7 个 `qhat`（0、1、2、255、maxInt、maxInt−1、2⁶³）；
- **500 000 组随机**（宽度 2..16，偏置到除法循环真实产生的形态）。

每组要求**被修改的全部 limbs 逐位相同**且 underflow 标志相同。

## 10. 纯度

P0/P1 同一套计数器、同一份语料，**八项逐行一致**：
digits 320754 / corrections 95009 / add-back 0 / clamp 0 / submul-limbs 2241550；
定向向量 + 全 64 shift：10192 / 2939 / **24** / **8** / 35512；估算种类计数也相同。

## 11. 裁决

| 门槛 | 实测 | |
|---|---|---|
| **机制**：per-limb 指令明确下降 **或** cycles ≥15% | **两项都满足**：insn −47.6%、cyc −18.3% | ✓ |
| direct-core `16×8` ≥8% | **11.5%** | ✓ |
| direct-core `24×8` ≥8% | **11.9%** | ✓ |
| direct-core `8×4` ≥4% | **9.1%** | ✓ |
| JS `div_16x8` ≥4% | **9.2%** | ✓ |
| JS `div_8x4` 或 `mod_8x4` ≥3% | `div_8x4` **3.4%** | ✓ |
| 等宽单商位 `8×8`/`16×16` 无 ≥1% 回退 | **−8.3% / −9.5%（都改善）** | ✓ |
| 单 limb 哨兵无新增 ≥1% 回退 | 全部跨 1.0 | ✓ |
| 算法计数完全一致 | 逐项相同 | ✓ |
| 正确性全套 | 全绿 | ✓ |

**全门槛通过。**

## 12. 正确性

| 门禁 | 结果 |
|---|---|
| 内核 lockstep | 结构化全扫 + **500 000 组随机**，逐 limb 与标志全等 |
| 20 000 组随机差分（1–64 limb） | **与 pinned qjs 逐字节相同** |
| 487 行定向探针 | **与 qjs 逐字节相同** |
| test262 | **0/49775**（passed 44541，known 25） |
| focused 套件 | core 313 / parser 463 / bytecode 188 / exec 389 / builtins 193 / runtime 72 / runner 43 |
| OOM / altrepr / ReleaseSafe / force-GC | 14 / 2003 / 313 / 313 |
| force-GC 二进制 | 20 000 组差分与 qjs 逐字节相同 |

## 13. 限制

- **`addBackAt` 仍是旧的标志物化形态** —— 同一缺陷，但它冷；留作 follow-up；
- per-limb 数值由「固定 nb 扫商位求斜率、再对 nb 求差」得到，
  **不是用计数器隔离循环**测出来的；
- `mod_8x4` 在 JS 层中性而非改善；
- 拓扑计数仍只覆盖 shift = 0；
- JS 层仍只有三个除法 case 加一个单 limb 哨兵。

## 14. 当前位置与下一步

```text
起点（P6-04a）   div_8x1 255x   div_8x4 243x   div_16x8 209x   mod_8x4 152x
P6-04c           逐 bit → normalized limb division
P6-04d1          每商位 reciprocal
P6-04d2a         删除输入 clone
P6-04d2b         按需物化结果
P6-04d2c         REJECTED（size-class 彩票）
P6-04d3          融合 multiply-subtract carry 链
现在             div_8x1 1.93x   div_8x4 2.58x   div_16x8 1.21x   mod_8x4 1.54x
```

**`div_16x8` 已到 1.21x**，`24×8` / `32×16` 这类大商位形态是本刀最大受益者。
按裁决给的收口条件：

- `div_16x8` 接近 qjs（1.21x）→ **大尺寸优化可以停止**；
- `div_8x4` 仍 2.58x → 剩余属于 **JS publication / allocator 固定成本**，
  而 d2.5 与 d2c 已经证明那块是 `SmallObjectSlab` 的 arena churn，
  **属于 allocator 层的独立课题**，不应再通过调整 BigInt 分配拓扑规避。

新的每商位成本模型：

```text
per digit ≈ 58.7 + 11.13 · nb  instructions
direct-core   16x8 184.9 / 24x8 301.5 / 32x16 464.1 / 8x4 99.4 / 8x8 54.1 / 2x2 48.2 ns
```

已登记的 follow-up（均不在 P6-04 主线）：

```text
Allocator follow-up   bounded empty-arena retention / per-class reserve
                      必须用跨类型、跨 size class 的 workload 验证
BigInt follow-up      addBackAt 的融合 carry 链（冷路径）
                      reciprocal threshold 调优（盈亏平衡点实测约 1.6 商位 < 当前 3）
                      addInPlaceExternal 的 rc==1 臂在 JS 层零命中
```
