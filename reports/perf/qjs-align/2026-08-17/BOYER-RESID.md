# BOYER-RESID — Boyer 池守恒闭合（只析不改）

日期：2026-08-17。**只析不改。** CPU **16**（`armv8_pmuv3_1`，避 5/6/7/19）。数字 **非裁决**。

| | |
|---|---|
| 问 | +356M Boyer 池从未单独守恒。钱在哪一步？（get_field 已对位 / instanceof 已地板） |
| z | `/home/aneryu/zjs/zig-out/bin/zjs` @ `553840ab` RF `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,…` |
| q | `/tmp/qjs-r4-labels/qjs`（`label_OP_*`，与 pV 官方 q 同族） |
| 夹具 | `/tmp/census/det/boyer-only.d16.js`（只 `BgL_nboyerzd2benchmarkzd2`，官方 ÷16） |
| pV q 账 | `/tmp/lanes/EB-FUNC-Q-SIDE.md` §3b：unify 33.6% / rewrite 30.9% / `sc_Pair` 15.3% mapped JCI |
| 原始 | `/tmp/lanes/boyer-resid/{fw.json,z,q-report.txt,sit.py}` |

---

## 0. 一句话

**独占守恒 98.0%（+343 / +350），在 ±10% 内。**  
get_field **+2M**（已对位）。put/setOrDefine **−28M**（齐）。RC/GC **−129M**（z 更便宜）。instanceof 簇 492M 是符号可见化，q CASE 熔在 JCI——**地板，不记刀**。

+350M 里能点名、且不是那两块禁地的 ≥30M 桶：

| # | 桶 | 配对 Δ | 机制 |
|---|---|---:|---|
| 1 | **`new sc_Pair` 入场** | **+160M** | `op_call_constructor` 181 vs q CASE+`CallConstructorInternal` 68（+113）；create/adopt/installInline 162 vs `JS_NewObject*`+shape 115（+47） |
| 2 | **帧建/撤** | 占用 **284M**（return 202 + `pushExactSimpleFrame` 82） | q `alloca`+`done:` 熔 JCI，无独立符号。不是 RC 对 |
| 3 | **`get_arg0/1`** | **+35M** | unify / rewrite / assq 读参 |

assq 环：**没有**单独 ≥30M 的环内差。环上 get_field 对位、instanceof 地板；多出来的并进 `===`（strict_eq 46，q 熔 JCI）和 assq 自己的 call/return（并进帧桶）。

---

## 1. FW（CPU16，ABBA n=4）

| | q | z | Δ | z/q |
|---|---:|---:|---:|---:|
| cycles | 2956.3M | 3306.1M | **+349.8M** | **1.118** |
| insn | 14867.6M | 15786.3M | +918.7M | **1.062** |
| IPC | 5.029 | 4.775 | | |

与 `EB-FUNC-ATTRIB` boyer-only d16（+356M / 1.125 / insn 1.064）同带。本发 +350 即那笔池。

insn 1.062：若 z 用 q 的 IPC，cyc ≈ 15786/5.029 = 3139 → 比 q 只多 **+183M**（多干活）。剩下 **+167M** 是单价/IPC（ctor 帧更肥）。

分数：z EarleyBoyer 1010–1033 / q 1146–1160（拆凳 reference 不可横比）。

---

## 2. 守恒（独占 sit，`cycles/u` `-c 200003`）

解析覆盖 z 99.4% / q 99.6%。

| | M |
|---|---:|
| FW Δ | **+349.8** |
| 独占 ΣΔ（已解析符号） | **+342.7** |
| **独占 / FW** | **98.0%** |

未解析 +7M。**闭合。**

---

## 3. 配对桶（占用 ≠ 独占）

q `label_OP_instanceof` / `get_var` / `return` / `eq` / `call` **几乎不出现**（return_undef 1.2M；无 instanceof 标签）。这些 CASE 的样本落在 `JS_CallInternal` **743.5M**。z 是具名 handler，看起来「贵」，是可见化，不是第二套守恒。

### 3.1 两边都有名字、可直接减

| 桶 | z M | q M | Δ M | 读 |
|---|---:|---:|---:|---|
| **get_field** | 497.6 | 495.8 `label_OP_get_field` | **+1.8** | **对位。** `EB-GETFIELD-MIX` 同结论 |
| **put** | 91.6 `put_field` + 162.0 `setOrDefine` + 24.1 add_tail = 277.7 | 54.7 CASE + 167.9 SPI + 59.4 `add_property` = 282.0 | **−4.3** | **齐。不是钱** |
| **if_false8** | 57.2 | 60.9 | −3.7 | 齐 |
| **dup** | 27.8 | 27.2 | +0.6 | 齐 |
| **get_arg0+1** | 53.2+54.6=**107.8** | 41.4+31.6=**73.0** | **+34.8** | ≥30M。unify/rewrite/assq 读参 |
| **ctor CASE** | 180.8 `op_call_constructor` | 39.0 CASE + 29.0 `JS_CallConstructorInternal` = 68.0 | **+112.8** | `new sc_Pair` 入场 |
| **NewObject/shape** | 54.2 createObjectRoot + 48.9 adoptShape + 28.1 createPlain + 31.1 installInline = **162.3** | 33.7+33.1+24.8+23.1 = **114.7** | **+47.6** | 同 ctor 族 |
| **RC/GC** | destroyFromHeader 127.3 + destroyShape 45.0 + zeroRef 34.4 + free 32.4 + alloc 18.8 ≈ **258** | malloc 76 + free 70 + free_gc 69 + free_property 44 + FreeValue 28 + free_shape 27 + FreeValueRT 24 ≈ **338** | **−80~−129** | **z 更便宜** |

**ctor 合计 ≈ +160M。** 这是 ≥30M 且能对上 q 名字的最大正桶。

### 3.2 q 熔进 JCI、z 具名（不拿来当「多干活」）

| 桶 | z M | q 可见 | 读 |
|---|---:|---|---|
| instanceof 簇 | 343.2 + 85.3 ohi + 63.8 complete = **492.3** | `JS_OrdinaryIsInstanceOf` 33.1 + `JS_IsInstanceOf` 19.8 = 52.9；CASE 在 JCI | **地板**（`INSTANCEOF-PRICE` REJECT）。不记 +439 |
| `op_return` | **202.0** | CASE 1.2 | q `goto done` 在 JCI。**帧撤**占用 |
| `pushExactSimpleFrame` | **81.7** | alloca 在 JCI | **帧建** |
| `opCall` ×2 | 81.0+68.8=**149.8** | `js_call_c_function` 41.4 + `JS_CallFree` 21.3；`OP_call` 在 JCI | 调用入场 |
| `op_get_var` | **167.9** | 无标签 | 全局名；q 近亲是 **GPI 310.4** |
| `coldStd` | **126.0** | — | 反汇编是 publish + `byteCode` + `pollInterrupt` → **get_var 冷臂** |
| get_var+cold+GPI | 168+126=294 | GPI 310 | **大致齐**，不是残差主因 |
| `zjs_cmp_strict_eq_*` | 26.1+20.2=**46.3** | CASE 熔 JCI | assq / `is_term_equal` 的 `===` |
| `op_is_null` | 52.9 | JCI | rewrite `lst===null` |

JCI 743.5M ≈ q 的 instanceof + return + call + get_var + eq + null + 分派。扣掉 z 这些「被看见」的量再跟 JCI 比对，不会再长出第二个 +350。

---

## 4. +350 里每个 ≥30M 桶的机制

只列 **配对后仍 ≥30M、且不是禁地** 的正桶；instanceof / get_field 写明为什么不算。

| # | 桶 | 约 Δ | 单价差在哪一步 | 不是 |
|---|---|---:|---|---|
| **C** | `new sc_Pair` | **+160** | `op_call_constructor` 入场（181 vs q CASE 39）+ shape/create 窗。rewrite / unify 里 `new sc_Pair(car, rewrite(...))`。put 壳已齐，贵在 **建对象+进帧** | 不是 put，不是 get_field |
| **F** | 帧建/撤 | 占用 **284**（return 202 + pushExact 82） | q 无符号：`alloca` + `done:` 局部环。z 每 call 付 Entry 存 + return 走访。L3 已证 **不是多 Dup/Free** | 不是 RC 对 |
| **A** | `get_arg0/1` | **+35** | 热函数都是 2 参（unify/rewrite/assq/is_term_equal）。q CASE 73 | 不是 assq 里的 get_field |
| — | get_field | **+2** | 已对位 | — |
| — | put/define | **−4~−28** | 已齐 | 不是 ①c |
| — | RC/GC | **−80~−129** | destroy 比对 q malloc/free 还少 | 不是 ⑦ 那种固有税 |
| — | instanceof | 占用 492 / 地板 | 不记刀 | — |
| — | assq 环本体 | **无单独 ≥30M** | 环 = instanceof（地板）+ get_field×2（对位）+ `===`（46，q 熔）+ 自己的 call/return（进 F）。pV：assq 只占 Boyer mapped JCI 7.9% / 全切片 4.2% | 不是第三条大环 |

**加法：** 160 + 35 + 帧占用里「对 JCI 后仍贵」的一截 ≈ 本发 +350。insn 侧 +183（多 op 展开）对上 ctor/帧的肥臂，不是多 emit 的 Boyer 算法。

---

## 5. 对 pV q 函数账

Boyer-only mapped JCI：unify 33.6 / rewrite 30.9 / `sc_Pair` 15.3 / assq 7.9 / rewrite_args 7.0。

本发 **不** 把 z handler 摊回这三个 JS 名（没有 x23=`b` 的 z 侧转储）。方向一致：

- unify+rewrite 是流量源（get_field / instanceof / get_var / get_arg / `===` / null）
- `sc_Pair` 是 **C 桶** 的 JS 锚（ctor+shape），不是 SPI 写壳
- assq 不是第三大独占差

pV leftover 属性：`JS_SetPropertyInternal` 5.3% / GPI 3.0%。本发 put 已齐、GPI 对 get_var 冷/鉴定 Get，不改写上述三条。

---

## 6. 热符号（独占 × FW）

**z**

| % | M | 符号 |
|---:|---:|---|
| 15.05 | 497.6 | `op_get_field` |
| 10.38 | 343.2 | `op_instanceof` |
| 6.11 | 202.0 | `op_return` |
| 5.47 | 180.8 | `op_call_constructor` |
| 5.08 | 167.9 | `op_get_var` |
| 4.90 | 162.0 | `setOrDefine…PutFieldOwned` |
| 3.85 | 127.3 | `destroyFromHeader` |
| 3.81 | 126.0 | `coldStd`（get_var 冷） |
| 2.77 | 91.6 | `op_put_field` |
| 2.58 | 85.3 | `ordinaryHasInstance` |
| 2.47 | 81.7 | `pushExactSimpleFrame` |
| 2.45+2.08 | 149.8 | `opCall` ×2 |

**q**

| % | M | 符号 |
|---:|---:|---|
| 25.15 | 743.5 | `JS_CallInternal` |
| 16.77 | 495.8 | `label_OP_get_field` |
| 10.50 | 310.4 | `JS_GetPropertyInternal` |
| 5.68 | 167.9 | `JS_SetPropertyInternal` |
| 2.57–2.34 | 215.6 | malloc / free / `free_gc_object` |
| 2.06 | 60.9 | `label_OP_if_false8` |
| 2.01 | 59.4 | `add_property` |
| 1.85 | 54.7 | `label_OP_put_field` |
| 1.32 | 39.0 | `label_OP_call_constructor` |
| 1.12 | 33.1 | `JS_OrdinaryIsInstanceOf` |

---

## 7. 纪律

- 占用 ≠ 独占。instanceof / return / JCI 不对成「z 多 400M 判定」。
- 禁外提 `call_method` `0x3f0`。Boyer 热是 `call` / `call_constructor`，不是 method。
- 不重开 get_field、instanceof 刀。
- 不把 +160 ctor 写成 `sc_Pair` 特判立项——通用是 **普通 2 字段 ctor 入场**。
- 数字非裁决。
