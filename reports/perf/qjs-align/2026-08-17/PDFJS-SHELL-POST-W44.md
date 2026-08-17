# PDFJS-SHELL-POST-W44 — RET-ABI 落袋后 ② 壳复走

日期：2026-08-17。lane：w1:pW。**只析不改。** CPU **15**。数字 **非裁决用**。

| | |
|---|---|
| 票 | post-w44 壳归因（用户裁：先只归因，不实施 typed 延伸） |
| z | `/home/aneryu/zjs/zig-out/bin/zjs` official RF（w44 `0f721021` / engine `4c9058ab`；sha256 `a61d0f77…`） |
| 几何 | NMFD **0x7b4** / 帧 **0xa0**；assume **0x2c4** / 帧 **`sub #0x140`**；typed **0x648** / 帧 **0x1e0**；`op_call_method` **0x3f0** |
| q | `/home/aneryu/quickjs/qjs` |
| FW | `/tmp/census/det/pdfjs.js` |
| 原始 | `/tmp/lanes/pdfjs-shell-post-w44/` |
| 纸面 | `/tmp/lanes/PDFJS-SHELL-UNITCOST.md`（RET-ABI **前**：NMFD **312** / assume **327**） |
| 配置 | `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off` |

本尺：exclusive `perf record/stat --no-inherit`（本机 `perf` 无 `--no-children`）。n=1。

| | z w44 | q | z/q |
|---|---:|---:|---:|
| cycles | 12.424G（stat）/ 12.350G（record） | 10.148G / 10.058G | 1.224 |
| insn | — | 55.369G | |
| br | 11.332G / 11.336G | 9.388G | 1.207 |
| 分 | 8041 / 8054 | 9886 | |

份额用 **record** 同一次样本（cyc 12.350G / br 11.336G）。M = % × 12.350G。

| 符号 | %cyc | M | %br | 纸面 M |
|---|---:|---:|---:|---:|
| NMFD | 2.33 | **288** | 2.37 | **312** |
| assume | 1.42 | **175** | 1.29 | **327** |
| **z 壳 Σ（NMFD+assume）** | | **463** | | **639** |
| typed `callTypedInternalRecordDirect` | 0.23 | **28** | 0.16 | （当时未单列） |
| q `js_call_c_function` | 1.39 | **140** | | **133** |
| cca Direct（体，非壳） | 0.64 | 79 | 0.42 | 63 |
| `JSValue.destroyZeroRef` | 0.31 | 38 | | |

n ≈ **29M** native（与纸面同量级）。

| | cyc/call |
|---|---:|
| z 壳（NMFD+assume）/ 29M | **16.0**（纸面 22.0） |
| q `js_call_c` / 29M | **4.8**（纸面 4.6） |
| assume 单独 | **6.0**（纸面 11.3） |
| NMFD 单独 | **9.9**（纸面 10.8） |

RET-ABI 把壳单价 22→16。剩下 16 vs 4.8 仍是 **记账边界 + 两跳 + NMFD 代收 RC**，不是同一函数慢 3 倍。

---

## 0. 终判（只归因）

1. **assume 纸面 327 → 现值 175（−152M）。** 对上 RET-ABI P1+P2 立刀。汇合口 `str q0,[x19]`（纸面 107M）**从 assume 热路径消失**；NMFD 在 `bl assume` 后 `cmp x1,#0x6`（tag 在 x1）。
2. **NMFD 纸面 312 → 现值 288（−24M）。** 帧 0xd0→0xa0（少 24B sret 槽）。热结构没变：大头仍是成功路径 RC 收栈。
3. **typed TLS 臂现付 28M（0.23%）。** L1 后 pdfjs 热臂是 exec_direct；typed 冷。其中 **`str q0,[x19]` 占 typed 的 62% ≈ 18M**——叶 `!JSValue` 仍 sret 进 assume 的 typed 槽，再被 assume 收成 x0+x1。
4. **② 还剩壳 Σ 463 vs q 140，差 ~323M。** 构成排序见 §3。没有任何一段「还能在宪里再剪一条 ≥30M 协议跳」被本尺新立；本档不实施。

---

## 1. 对位（谁跟谁比）

未变：

```
q:  OP_call_method ⊂ JS_CallInternal
      poll / 弹栈 / 压结果          ← 不进 140M
      hook = js_call_c_function     ← 对位
        建 sf · realm · overflow · cproto · blr · 拆 sf · ret  (x0 JSValue)

z:  op_call_method 帧 0x3f0         ← 仍不进本账
      bl NMFD  0x7b4 / 0xa0
        rec · poll · bl assume
        assume 返回 x0+x1 后 popOwned · drop/push
      assume  0x2c4 / 0x140
        preflight · realm · sf · blr exec_direct   ← 热
        或 TLS env · bl typed（typed 仍 sret）     ← 冷
```

纸面把 107M 记成 tagged vs nanbox，**已更正**：那是 `HostError!JSValue` 24B sret。RET-ABI 拆掉的是 NMFD↔assume 这一环。assume↔typed / assume↔叶 的 24B sret **还在**（叶 P2 只改了五片 Direct；typed 与其余叶仍 `!JSValue`）。

---

## 2. 逐段新账

M = 本尺 record × 段内 annotate 份额。annotate 是符号内归一，所以段 M 加总 ≈ 符号 M。

### A. NMFD（**288M**，帧 0xa0，尺寸 0x7b4）

| # | 步 | 址 | 段内% | ≈M | vs 纸面 | 注 |
|---|---|---|---:|---:|---|---|
| 1 | 墓碑 `cbnz` | `1236100–08` | 2.0 | **6** | 4.8 | 仍从不采取 |
| 2 | 建帧 0xa0 + argc/region | `610c–50` | 7.5 | **21** | 27 | 帧缩 0xd0→0xa0 |
| 3 | recv 快照 + rec/payload | `6150–61a4` | 11.5 | **33** | 28 | 仍是 memo+旗，不是 q 的 1×ldr |
| 4 | `pc+=2` + poll tick | `61a4–61d8` | 4.7 | **14** | 20 | |
| 5 | poll-slow / interrupt | `61d8–6368` | 6.8 | **19** | （并入 4） | 冷边 |
| 6 | marshall + `bl assume` | `6368–90` | 4.1 | **12** | 11 | **不再** `add x0,sp,#0x50` |
| 7 | 回收 `cmp x1,#6` | `6390–63ac` | 3.4 | **10** | 3（当时 `ldrh` error） | 替换 sret 的 `ldrh+cbz` |
| 8 | 异常 / pop 预备 | `63ac–6440` | 3.1 | **9** | | |
| 9 | **RC pop/dec 热环** | `6440–94` | **42.6** | **123** | 197 的主体 | `sub/cmp/ldr/cmn/ldur/subs/stur` |
| 10 | push/drop/epilogue | `6494–6620` | 14.6 | **42** | 197 的尾巴 | |
| | 另：outlined `destroyZeroRef` | 独立符号 | 0.31% 全进程 | **38** | | 从 NMFD 打出去的 RC |

**NMFD 入口到 `bl assume`（1–6）≈ 105M / 3.6 cyc/call。**  
**回来之后的税（7–10）≈ 184M**，其中 RC 环+收尾 **165M**（57% 本符号）。

纸面 197M RC 现拆成环 123 + 收尾 42 + outlined 38。量级仍在。q 的等价弹栈 **不进** `js_call_c`。

### B. assume（**175M**，帧 `sub #0x140`，体 0x2c4，`.text.zjs.nmfd_term`）

| # | 步 | 址 | 段内% | ≈M | vs 纸面 | 注 |
|---|---|---|---:|---:|---|---|
| 11 | 建帧 0x140 | `14399d0–9f8` | 16.1 | **28** | 21（当时 0x1c0） | 含 callee-save；total 小于纸面 0x200 |
| 12 | preflight `cmp sp` | `99f8–9a44` | 5.6 | **10** | 6 | |
| 13 | realm / payload 旗 | `9a44–9aac` | 20.6 | **36** | 19 | 仍比 q 一 ldr 贵 |
| 14 | exec_direct vs TLS `cbz [rec,#32]` | `9aac–9ab4` | 2.8 | **5** | 28（当时整段含冷） | L1 后金丝雀走 fallthrough |
| 15 | **sf push + 7 参 + `blr` 叶** | `9ab4–9b10` | 18.9 | **33** | 39+3 | 热臂。叶仍 x8 sret（五 Direct 已是 NativeBits 入口，但 assume 仍按 7 参调） |
| 16 | sf pop + `ret`（direct 成功） | `9b10–9b44` | 10.6 | **19** | 81 的一部分 | **无** `str q0,[x19]` |
| 17 | TLS env + `bl typed` | `9b5c–9be8` | 7.8 | **14** | 12 | 冷于金丝雀 |
| 18 | typed sret 回收 / materialize | `9be8–9c54` | 0.6 | **1** | 11 | `ldurh [x29,#-16]` 仍读 typed 的 24B 槽 |
| 19 | typed 成功 `ldp x0,x1` + 公共 epilogue | `9c54–9c94` | 17.2 | **30** | 含旧汇合口邻居 | 最热单条 `ldp x20,x19,[sp,#304]` **10%** |

**纸面 107M `str q0,[x19]`：本符号 0 条。** 成功回 NMFD 走 x0+x1。  
assume 热到 `blr` 叶（11–15）≈ **112M / 3.9 cyc/call**，仍贵过整个 q `js_call_c` 的到-blr。

### C. typed TLS（**28M**，`callTypedInternalRecordDirect`，0x648 / 0x1e0）

| # | 步 | 段内% | ≈M | 注 |
|---|---|---:|---:|---|
| 20 | prologue + cproto `br` 表 | 20.7 | **6** | `br x11` 6.9% |
| 21 | 各 cproto 臂 + **sret 写回** | 79.3 | **23** | 最热：`1190804 str q0,[x19]` **62.1% ≈ 18M** |
| | 叶 `NativeGenericFn` 本体 | 不在本符号 | | `anyerror!JSValue`，另计 |

pdfjs 上 typed = **0.23% / 28M / ~1.0 cyc/call（摊到全部 29M native）**。只摊到真正走 TLS 的调用，单价会高得多，但次数少。

入口 `mov x19,x0`：这里 x0 是 **Zig sret 目的**（assume 传入的 24B 槽），不是 ctx。与 P2 Direct 的 `mov x19,x0`（ctx）不是同一件事。

---

## 3. 剩余壳构成排序

只计 ② 壳相关、RET-ABI 之后还在付的。按本尺 M：

| 序 | 块 | ≈M | 属 | 为何还在 |
|---|---|---:|---|---|
| **1** | NMFD 成功 RC 收栈（环 123 + 收尾 42） | **165** | RC | q 做在 `JS_CallInternal`。搬走仍付。⑦ 不属 native 协议 |
| **2** | assume 协议核（帧+realm+sf+blr+pop，**不含** 已删 sret） | **~130** | 协议 | 0x140 第二帧 + 7 参 + sf。B-R1 已证换跳板 1:1 |
| **3** | NMFD 入口（墓碑+帧+rec+poll+hop+tag 比） | **~105** | 协议/义务 | rec 传入会涨 0x3f0；poll 必须在用户代码前 |
| **4** | outlined `destroyZeroRef` | **38** | RC | 从 NMFD 打出去的零引用析构 |
| **5** | assume 上的 typed 开销（env 14 + 收 x0+x1/epilogue 30） | **~44** | TLS 冷臂 | 与下行部分重叠（收 sret） |
| **6** | **typed 符号本身** | **28**（内 18 = sret `str q0,[x19]`） | TLS 冷臂 | pdfjs 0.23%。叶仍 `!JSValue` |
| 7 | cca Direct 体 | 79 | **非壳** | q `js_string_charCodeAt` 同量级 |

若把 RC（1+4 ≈ **203M**）从「壳协议」里拿掉：NMFD 入口 105 + assume 175 = **280M / 29 ≈ 9.7 cyc/call**，仍是 q 140/29=4.8 的 **2.0×**。纸面同一口径是 15.2 cyc（3.3×）。RET-ABI 把协议核对位从 3.3×收到 2.0×。

**排序一句话：** 剩壳先是 **NMFD 代收 RC**，再是 **assume 第二帧/sf/7 参**，再是 **NMFD 入口+rec+poll**，typed TLS 整臂只有 **28M**，排在壳协议的末席。

---

## 4. 和纸面封条的关系

纸面签过：22 vs 4.6 不是一条能在 0x7b4 / 0x1c0 / 0x3f0 里剪掉的 ≥30M 退役跳。  
RET-ABI 是纸面当时 **归因错** 的那一行（sret，不是 tagged vs nanbox）被纠正后的刀，已经落袋。

本尺不改结论的结构部分：

- NMFD RC 仍不是 native 协议刀
- rec 传入仍涨 0x3f0
- 再切 hop 已有 B-R1 1:1
- typed 在 pdfjs **28M &lt; 30M**，且 62% 是自己的 sret 汇合；即便当作同族 ABI，也不是本资产上的立刀门

本档 **不实施、不立新刀**。

---

## 5. 方法

- z：`taskset -c 15 perf record -e armv8_pmuv3_1/cycles|branches/ --no-inherit`
- 份额：`perf report --no-children`
- 段：`perf annotate --stdio -s <sym>`，按 w44 反汇编切址
- q：同核 exclusive `perf stat` + `record` 取 `js_call_c_function` 1.39%
- 纸面对照：`/tmp/lanes/PDFJS-SHELL-UNITCOST.md`（pre-RET-ABI official，NMFD 0xd0 / assume 0x1c0）
