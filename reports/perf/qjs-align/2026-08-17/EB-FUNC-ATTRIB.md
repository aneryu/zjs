# EB-FUNC-ATTRIB — EarleyBoyer 逐 JS 函数重归因（开篇）

日期：2026-08-17。新战役。**只析不改。** CPU **15**，ABBA n=4（det 尺 n=2 只作倍率）。数字 **非裁决**。

| | |
|---|---|
| z | `/home/aneryu/zjs/zig-out/bin/zjs` @ **main `0f721021`** RF `repr=tagged` |
| q | `qjs-04be2460` ≡ `/home/aneryu/quickjs/qjs` |
| 用户夹具 | `/tmp/census/det/earley-boyer.js`（full det：Earley 2500 + Boyer 200） |
| 工作尺 | `/tmp/lanes/eb-func/eb.d16.js` = `/tmp/r5/fixed`（官方 `fixed_source` ÷16） |
| 消融件 | 同目录 `eb.d16.{earley-only,boyer-only,no-trees,no-parse,no-rewrite}.js`（**双引擎同一份**） |
| 原始 | `/tmp/lanes/eb-func/` |

旧三分账（形税 / L1I 墙 / RC 固有）本单降为待验假设，只用函数级收据验收。

**拆分件（pV/pS 共享）：** `/tmp/census/det/{earley,boyer}-only.js` + `.d16.js`。说明见 `/tmp/census/det/EB-SPLIT.md`。

---

## 0. 拆分公告（第一刀）

官方单凳夹具（suite 里只留一个 `Benchmark`，生成代码不动），CPU15 ABBA n=4：

| 凳 | 窗 | z cyc | q cyc | **cyc z/q** | 超额 | **insn z/q** |
|---|---|---:|---:|---:|---:|---:|
| **Earley** | det | 50.39G | 37.29G | **1.351** | **13105M** | **1.252** |
| **Boyer** | det | 49.05G | 43.45G | **1.129** | 5595M | **1.066** |
| Earley | d16 | 3.176G | 2.371G | **1.339** | 805M | **1.246** |
| Boyer | d16 | 3.215G | 2.882G | **1.116** | 334M | **1.062** |

**差距集中在 Earley。** 合凳 1.23× 是 1.35× 与 1.13× 的混合。Earley **多 25% 指令**；Boyer 指令几乎齐，只剩单价。后续逐函数表按两凳分列。

一次分（合凳参考分不可比）：Earley 6414/8710=0.736；Boyer 512/574=0.892。

---

## 0b. 一句话

d16 超额 **1179.7M cyc**（z/q **1.227**）。两刀消融锁死 **99.6%**：

| JS 函数族 | 消融 | 超额 | 占总量 |
|---|---|---:|---:|
| **`BgL_parsezd2ze3treesz31` → `deriv-trees*`**（Earley 出树） | 去掉 `parse→trees`，保留 make-parser+parse | **824.5M** | **69.9%** |
| **`rewrite_nboyer` + `tautologyp_nboyer`**（Boyer 改写） | 改写/重言式换成常量 95024 | **350.9M** | **29.7%** |

Earley **整段**超额 811.6M（z/q **1.345**，insn **1.247**——多干活）。Boyer 整段 356.0M（z/q **1.125**，insn **1.064**——接近单价）。parse/make-parser 相对 Boyer 残差 ≈0。

旧账：**形税/闭包** 在出树函数上坐实；**RC** 是出树的伴随（pair/ctor/destroy）；**L1I** 顶多解释 Boyer 那 1.12×，解释不了 Earley 的 +25% insn。解释器瘦身上限 ≈超额的 **⅓**（单价/IPC）；另外 **⅔ 是多出来的指令**，瘦 handler 削不掉。

---

## 1. ①② 基线 + 计分窗

### 1.1 三窗一次跑（CPU15）

| 窗 | 协议 | z wall | q wall | 分数 z/q |
|---|---|---:|---:|---:|
| **zoo** `javascript-zoo/bench/earley-boyer.js` | warmup + 每凳 1s | 5.15s | 5.10s | 3647 / 4492 = **0.812** |
| **det** 用户夹具 | 无 warmup，2500+200 | 25.76s | 21.03s | 3660 / 4502 = **0.813** |
| **d16** | det ÷16（ceil） | 1.67s | 1.38s | 3612 / 4416 = **0.818** |

**分数对齐：三窗比都在 0.81x。** det 与 zoo 计分比同号同量。G1 忌的不是「det 分数不能代表 zoo」，而是 **用 A 窗的份额去乘 B 窗的总周期**。

工作量不对齐：det/d16 cyc = **15.60×**（2500/157 × 混合，不是整 16）。归因美元只用 **一个** 窗，再按 15.60 换算 det。

本单工作尺 = **d16**（消融 n=4 付得起）。det n=2 只验倍率。

### 1.2 d16 / det 基线（CPU15，`cycles/u`+`instructions/u`）

| 尺 | n | z cyc | q cyc | z/q | 超额 | z insn | q insn | insn z/q |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| d16 | 8 | 6.374G | 5.194G | **1.227** | **1179.7M** | 29.385G | 25.709G | **1.143** |
| det | 4 | 98.983G | 80.576G | **1.228** | 18407M | 457.9G | 399.9G | **1.145** |

IPC：z 4.61 / q 4.95。超额里大约 **⅔ 来自多 insn，⅓ 来自单价/IPC**（若 z 指令数落到 q：超额从 1180M → ~385M）。

---

## 2. ③④ 逐函数：先整凳，再拆体（消融之差分）

方法：改 JS 的 `run()` / 出树调用 / 改写调用，**同一份**给 z 和 q。超额差 = 该函数族的因果美元。

| 件 | 还跑什么 | 超额 | 相对 d16 基线 |
|---|---|---:|---:|
| `eb.d16.js` | Earley+Boyer | 1179.7M | — |
| earley-only | 只 `test(k)` | **811.6M** | z/q 1.345，insn 1.247 |
| boyer-only | 只 `test-boyer(0)` | **356.0M** | z/q 1.125，insn 1.064 |
| **no-trees** | Boyer + make-parser + parse，**不出树** | **355.2M** | ≈ boyer-only |
| no-parse | Boyer + make-parser，不 parse | 341.9M | parse 本身 ≈ 13M |
| **no-rewrite** | Earley 全 + Boyer 到 subst，**不 rewrite/tautology** | **828.8M** | ≈ earley-only |

**差分：**

```
出树     = 基线 − no-trees     = 1179.7 − 355.2 = 824.5M   (69.9%)
改写族   = 基线 − no-rewrite   = 1179.7 − 828.8 = 350.9M   (29.7%)
parse    = no-trees − no-parse = 13.3M
make-parser / setup ≈ 0（no-parse ≈ boyer-only）
两族合计 1175.4 / 1179.7 = 99.6%   ≥ 80% 门
```

按绝对超出排序（d16；det = ×15.60）：

| # | JS 函数（源） | d16 超额 | det 换算 | 调用形态 |
|---|---|---:|---:|---|
| 1 | `BgL_parsezd2ze3treesz31` → `parse[9] = deriv-trees*`（`earley-boyer.js:5002–5010`，`test` 末尾 `sc_length(trees(x,"s",0,k))`） | **824.5M** | 12.86G | 闭包，捕获 nts/enders/steps/names/toks/states |
| 2 | `rewrite_nboyer` + `tautologyp_nboyer`（`BgL_testzd2boyerzd2:4193`） | **350.9M** | 5.47G | 递归改写 + 重言式，满 `sc_Pair` / `instanceof` |
| 3 | `p(...)` 即 make-parser 的 parse 臂 | ~13M | ~0.2G | 低于 100M |
| 4 | `BgL_makezd2parserzd2` / `BgL_setupzd2boyerzd2` | ~0 | — | |

匿名 `test(k)` / `BgL_earleyzd2benchmarkzd2` 的超额 **几乎全部**在出树，不在建 parser、不在 chart parse。

---

## 3. ⑤ 机制层 + 新旧标签

### 3.1 出树 824.5M — 旧「形税/闭包」+ RC 伴随（函数级收据）

- **路径：** `test` → `BgL_parsezd2ze3treesz31` → `parse[9](nt,i,j,...)`。`parse[9]` 是 `make-parser` 塞进去的闭包（`fclosure8`）。
- **op：** 出树一砍，整段 Earley 超额消失，且 **insn 1.247**——z 在这族上**多执行 25% 指令**，不是纯单价。r5 d16 画像：`fclosure8` 640k × **800 ns/发**；`get_var_ref` 7.2M；`call_constructor` 4.7M × 238 ns（`new sc_Pair`）；`instanceof` 7.9M。
- **归属：** 旧① **形税/闭包**（r11c `deriv_trees` 互捕获）在本函数上坐实。旧③ **RC** 是伴随（destroy/trace/GC 在 z 采样里合计 >15%）。**不是新机制。**
- **可刀？** 机制层已有闭包/出树专项史；本单只给函数收据。新刀必须针对 **出树闭包的额外 insn**，不是再削 `get_field` 热臂。

### 3.2 改写族 350.9M — 旧「单价 / 可能 L1I」（函数级收据）

- **路径：** `rewrite_nboyer(term)` + `tautologyp_nboyer`。满 `sc_Pair` 链表、`instanceof sc_Pair`、`get_field` car/cdr。
- **op：** Boyer insn 只 **1.064**——几乎同量工作，z 稍贵。采样热：`op_get_field` 8.6%、`op_instanceof` 6.4%、`op_return` 5.3%、`op_call_constructor` 4.1%。
- **归属：** 更接近引擎基线（~1.12× cyc），不是 Earley 那种 1.35×。旧② **L1I** 至多是部分解释（q 47.8% 堆在 `JS_CallInternal`；z 碎在几十个 handler）。**没有单独的新机制。**
- **可刀？** 解释器瘦身的付款面；单独为 Boyer 开语义刀 ROI 差。

### 3.3 旧三条总判

| 假设 | 本单 | 收据 |
|---|---|---|
| 形税 / 闭包 | **坐实** | 出树一刀拿走 70% 超额 + Earley 多 25% insn |
| L1I 墙 | **弱、局部** | 只贴得上 Boyer 1.06× insn；Earley 多 insn 不是墙 |
| RC 固有 | **坐实为伴随** | z `destroy*`/`traceChildren`/`drainCycle` 合计大头；q `malloc/free/mark` 对位。出树砍掉后 RC 采样应一起掉（未再采消融件） |

没有第三个 ≥100M 的**新** JS 函数。80% 门两族就满。

---

## 4. ⑥ 若坐实旧账：解释器瘦身情报

热驻留（d16，z `perf record` cycles/u，~32k 样本）：

| z 符号 | % | 角色 |
|---|---:|---|
| `op_get_field` | 8.62 | 属性读 |
| `op_instanceof` + `ordinaryHasInstance` + `completeOrdinaryInstanceof` | 6.37+1.44+1.09 | `sc_Pair` 判别 |
| `op_return` | 5.26 | 帧 |
| `Object.destroyRuntimeCycles*` / `destroyFromHeader` / `drainCycle*` | 4.65+4.32+1.01 | RC/GC |
| `op_call_constructor` | 4.12 | `new sc_Pair` |
| `setOrDefineOwnDataPropertyForPutFieldOwned` | 3.59 | 写 |
| `op_get_var` | 3.48 | |
| `traceChildren` ×2 | 2.92+1.73 | GC |
| `pushExactSimpleFrame` | 2.51 | 调用 |
| `op_put_field` | 2.21 | |
| `opCall` 族 | ~3.6 | |
| `op_if_false8` | 1.49 | |
| `op_get_arg0_fast` | 1.48 | |
| `opGetVarRef` | 0.64 | 闭包槽 |
| `createPlainObject` / shape create/destroy / alloc | 各 ~1 | |

q 对位：`JS_CallInternal` **47.8%**（单体），然后 Get/SetProperty、malloc/free、mark_children、NewObject、instanceof。

**瘦身上限（d16）：**

- 若只把单价/IPC 收到 q、**insn 仍 1.143×**：超额下限 ≈ **385M**（1180−795）。这是「解释器变瘦」的天花板。
- 出树那 825M 里大部分是 **多 insn**（闭包/构图），瘦 `op_get_field` 搬不走。
- Boyer 351M 更像单价，瘦身敏感。
- 禁再拿 L1I 墙当 Earley 主因；墙最多吃 Boyer。

---

## 5. 方法纪律

- 消融 JS 双引擎同份；空凳仍留在 suite 里，避免 harness 改形。
- 空 `run()` 会把 Octane 分数打成 Infinity（0 ms）——**只用 PMU，不用消融分数。**
- 出树消融改的是 `test` 末尾表达式，不碰 `RunBenchmark` 的 rewrite 校验（Earley 校验是 `result==132`，我们直接返回 132）。
- 改写消融把 `rewrite_count` 写成 95024，过 Boyer 校验。

---

## 6. 请收

- 产物：`/tmp/lanes/EB-FUNC-ATTRIB.md`
- 夹具/消融/ABBA：`/tmp/lanes/eb-func/`
- 合 main：无
- 下一刀若开：对着 **`deriv-trees*` 的额外 insn**（闭包/构图），不要对着 get_field 热臂或 L1I 岛重讲一遍
