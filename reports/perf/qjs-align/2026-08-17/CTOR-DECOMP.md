# CTOR-DECOMP — Boyer ctor 族 +160M 分解对账（只析不改）

日期：2026-08-17。**只析不改。** CPU **16**（`armv8_pmuv3_1`，避 5/6/7/19）。数字 **非裁决**。

| | |
|---|---|
| 问 | +160 ctor 与 pW「入帧差=Entry 税封条内」相抵。181 逐段：哪段是 Entry 发布，哪段可对齐 q。shape +47.6 是否启动 P6 挂队。get_arg +35 顺带。 |
| z | `/home/aneryu/zjs/zig-out/bin/zjs` @ `553840ab`/`fc4b82eb`（docs-only 后）RF `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,…` |
| q | `/tmp/qjs-r4-labels/qjs`（`label_OP_*`） |
| 尺 | `/tmp/census/det/boyer-only.d16.js`；FW / 独占 sit 复用 `BOYER-RESID`（CPU16，ABBA n=4） |
| 对账 | `SCPAIR-LIFECYCLE` pW；`r14a-DESIGN` 臂 T/E；`p6-REJECT-ARCHIVE` 挂队口 |
| 原始 | `/tmp/lanes/ctor-decomp/{asm,ann-*}` + `/tmp/lanes/boyer-resid/` |

Boyer d16 发次 **3,337,797** `new sc_Pair`（z=q，`scpair-lifecycle/counts.json`）。

---

## 0. 一句话

**Boyer 热 `new sc_Pair` 走臂 T（TAKE），不走 Entry。**  
`pushConstructorCall` / `setupSimpleConstructorEntry` / `setupInlineEntry` 独占合计 **0.2M**。pW 把 S0 叫「Entry 税」——在 **这张凳** 上名字错了，钱在 **v1.5 TAKE 窗**（q 没有）。封条精神仍在：不是 put、不是 get_field、不是 RC、不是 shape 建毁单价。

+160 重拆：

| 公平桶 | z | q | Δ | 归属 |
|---|---:|---:|---:|---|
| **入帧（CASE + TAKE/CCI）** | 180.8 handler + 31.1 `installInlineWindow` = **211.9** | CASE 39.0 + `JS_CallConstructorInternal` 29.0 = **68.0** | **+143.9** | TAKE 查找/applyForward/`consumedArgSlots`/fused proto + 窗发布。Entry 发布 ≈0 |
| **建对象** | `createObjectRoot` 54.2 + `createPlainObject` 28.1 = **82.3** | NOPC 33.1 + FromShape 33.7 + `js_create_from_ctor` 13.6 = **80.4** | **+1.9** | **齐。** HIT 对 HIT |
| **shape 建/毁** | `destroyShape` 45.0（create 在 Root 里少数） | `js_new_shape2` 24.8 + `js_free_shape` 26.6 | 见 §3 | **不启动 P6 挂队** |
| **adopt / ADD 转** | `adoptShape` 48.9 | `add_property` 59.4（已在 put 桶）+ `add_shape_property` 23.1 | put 已齐 | 应从 +47.6 挪回 put |

原 +47.6 是错配：把 `installInline`（TAKE）和 `adoptShape`（ADD）塞进 NewObject，q 侧又漏了 `js_create_from_ctor`。拆开后 **shape/create 不是 +160 的主色。**

`get_arg` +35：TAKE 之后 `sc_Pair` 体应变成 loc；剩下的是 unify/assq 等读 `Frame.args` 的 3 跳，对比 q JCI `arg_buf`。帧局部性，不是 assq 环、不是 ctor 刀。

---

## 1. 静态形（对位）

### 1.1 z `op_call_constructor`

- **0xfa4 B / 1001 insn / 帧 `stp #96` + `sub sp,#0x270`**（720B）。r14a 记 0x260，现 0x270。
- 热 `bl`：`prepareSameMachine…`、`installInlineWindow`、`pushConstructorCall`、`noteMonomorphic`、`specializeCallSite`、`findInlinedSite`、`createPlainObject`（fused）。
- `resolveSameMachineConstructor` **熔进 handler**（无独立符号）。
- `pushConstructorCall` 0x860 outlined，但 Boyer sit **0 样本**（`prepare` 1 样本 / 0.01%）。

### 1.2 q `OP_call_constructor` + CCI

`label_OP_call_constructor`（18203–18218，~19 insn + FreeValue 环）→ `bl JS_CallConstructorInternal`（0x2a8 / 0x80 帧）：

| q 步 | 锚 | CCI 独占落点（140 样本） |
|---|---|---:|
| Q1 poll | 20817 / `js_poll_interrupts` | 2.9% |
| Q2 object / `is_constructor` / class | 20820–20825 | 1.4 + 7.1 + 5.0 |
| Q3 derived? | 20837 | **19.3** |
| Q4 `js_create_from_ctor` | 20842 | 10.0（`bl`；体在 NOPC） |
| Q5 NewObject | 5743 / 5613 | **outlined** |
| Q6 `JS_CallInternal` 前言 | 20845 → 17828 | **16.4**（只 `bl`；前言熔 JCI 743M） |
| Q8 完成 Free | 20846–20855 | 3.6 + 5.7 + 5.0 |

q CASE 独占 39.0M 的 **76%** 是区 `JS_FreeValue` 环（h:691 / 18214），不是建帧。

### 1.3 为什么 Boyer 是臂 T 不是臂 E

`specializeCallSite` 仍有 `caller.byteCode().len > 2048 → return`（`small_inline.zig:358`）。  
Earley `deriv_trees` 超限；**Boyer 热调用方都很小**：

```
rewrite_nboyer(term)        // ~25 行，1 参，体内 new sc_Pair
rewrite_args_nboyer(lst)    // 一行，1 参
one_way_unify1_nboyer       // 2 参，一处 new
```

8 次 monomorph 后 specialize，后续 `findInlinedSite` 命中 → fused create + `installInlineWindow`。  
`sc_Pair` 体 `this.car=car; this.cdr=cdr` 收进 caller locals（测试字面：`rewrite sc_Pair-shaped body keeps put_field`）。

SCPAIR/r14a「caller>2048 拒 TAKE」对 **Earley** 成立，对 **Boyer-only 不成立**。

---

## 2. `op_call_constructor` 181M 逐段（annotate × FW）

独占 880 样本 / 180.8M。指令级百分数之和 99.8%。地址用 `/tmp/lanes/ctor-decomp/asm/z-op_call_constructor.s`（`-dl`）归源。

| # | 段 | % | M | vs q | 封条 / 可对齐 |
|---|---|---:|---:|---|---|
| A | Q0 publish / argc / 区基（2011–2016；`str q0,[sp,#64]` 独占 3.64%） | 11.7 | **21.1** | CASE 里 argc+sp ~6；q 更贵的是 Free 环 | 共享步。z 不贵 |
| B | TAKE `findInlinedSite` / `callerState` / hotExt / `mem.readInt` | 13.5 | **24.4** | **q 无** | **可削（z-only 查找）** |
| C | TAKE `applyForwardTakeOk` / `siteSlot`（`#0xfffffffeffffffff` + `cmp`） | 15.6 | **28.1** | **q 无** | **可削。** Boyer `new` 不是 apply-fwd，每次仍走哨 |
| F | `windowFits` / `consumedArgSlots`（`1280` 一条 `cmp` **14.20%**） | 19.4 | **35.1** | **q 无** | **可削。** 最大单点 |
| E | `tryFusedConstructor` proto/shape/`asDataAt`/`objectFromValue` | 15.8 | **28.5** | q 在 `js_create_from_ctor`+NOPC（outlined 13.6+33.1） | 资格可对齐；**创建本身不在 181** |
| H+G | TAKE 尾：`install` `bl` + `setLen` + tail `br`（2035–2051 / 2126） | ~8 | **~15** | q 无窗；Q6 在 JCI | 窗发布（见下） |
| I | `resolveSameMachine` / `plainBytecodeFunctionObjectFromValue` | 3.8 | **6.9** | CCI 20820–20825 ≈ 1.4+2.1+1.5=**5.0** | **已对位** |
| D | `pollInterrupt` | 0.7 | **1.2** | CCI poll **0.8** | **已对位** |
| N | **`bl pushConstructorCall`（Entry 发布）** | 0.11 | **0.2** | Q6 熔 JCI | **封条内。Boyer 热径空** |
| K | `bl prepareSameMachine…` | 0 | **0** | 体在 create* | — |
| L | `noteMonomorphic` / `specializeCallSite` | 0 | **0** | q 无；已特化后不再付 | — |
| Q | 区 RC `free` displaced | 2.6 | **4.7** | CASE Free 环 ~30 | z TAKE 把 Free 挪到 `install`/`release` |
| O | `enterEntry` / `byteCode` / `maybeStop` | 1.5 | **2.7** | JCI 前言 | 可忽略 |
| — | 未归 / 冷 | ~7 | ~12 | | |

**加法：** B+C+F+E + TAKE 尾 ≈ **131 + 15 = 146M / 181 = 81%。**  
Entry 发布 **0.2M。** poll+resolve **8.1 vs q CCI 同名步 ~6。**

### 2.1 和 pW 封条怎么相抵

pW S0：`op_call_constructor` 50.5 cyc/发 vs `JS_CallConstructorInternal` 9.0，标「Entry 税，封条内」。

本尺 180.8 / 3.338M = **54.2 cyc/发**（同号）。但 54 里：

- **0.06 cyc** Entry（`pushConstructorCall`）
- **~44 cyc** TAKE 查找 + apply-fwd 哨 + `consumedArgSlots` + fused 资格
- **~6 cyc** Q0
- 其余 poll/resolve/RC

**封条该罩的 architectural 发布，在 Boyer 上几乎没采到。**  
采到的是 **q 没有的 TAKE 外壳**。精神上仍「不要当成 NewObject/put/RC 洞」；机制名要从 Entry 改成 **TAKE 窗税**。Earley 大 caller 才是 r14a 臂 E（`setupInlineEntry` 那张旧地图）。

`installInlineWindow` 另 **31.1M**（独占，handler 外）= TAKE 的 Q6 等价物：把 `this`/args MOVE 进 **caller locals**。q 是 `alloca` + `arg_buf=argv`。这 31.1 算「发布」，但不是 Entry 巢。

### 2.2 可对齐步（逐个 vs q）

| 步 | z 181 内 | q | 判 |
|---|---:|---|---|
| resolve / `is_constructor` / bytecode class | 6.9 | CCI ~5.0 + derived 5.6（derived 冷，Boyer 不是） | **齐** |
| proto 取用 | fused `asDataAt(proto_slot)` 28.5（资格；创建 outlined） | `js_create_from_ctor` GetProperty `prototype` 13.6 + NOPC HIT | 资格链 z 更肥（shape 指针 + slot + proto 三比）。创建齐 |
| auto-init 探测 | `ownConstructorPrototypeData` 在 `prepare`（0 独占）。稳态走 fused 缓存 slot | 首发物化 lazy `prototype` | **不是钱** |
| 创建链转发 | `createPlainObject` outlined 28.1 | `JS_NewObjectFromShape` 33.7 | **z 不贵** |
| 第二 poll | 已删（E6） | JCI 入口另一次 | 已对齐 |
| TAKE 查找 / apply-fwd / `consumedArgSlots` | **88M** | 无 | **z-only。最大可削面**（不是「对齐 q 的同名步」，是去掉 q 没有的税） |

不要做：放开 2048、为 `sc_Pair` 名字特判、重开 bypass、动 `call_method`。

---

## 3. NewObject / shape +47.6 重拆

BOYER-RESID 原配：

```
z 54.2 Root + 48.9 adopt + 28.1 CPO + 31.1 install = 162.3
q 33.7 FromShape + 33.1 NOPC + 24.8 new_shape2 + 23.1 add_shape_property = 114.7
Δ +47.6
```

### 3.1 公平重配

| 配对 | z | q | Δ |
|---|---:|---:|---:|
| 空对象创建（HIT + alloc） | Root 54.2 + CPO 28.1 = **82.3** | NOPC 33.1 + FromShape 33.7 + `js_create_from_ctor` **13.6** = **80.4** | **+1.9** |
| TAKE 窗（不是 shape） | `installInlineWindow` **31.1** | 0（无窗） | 并进入帧 +143.9 |
| ADD 转（car/cdr） | `adoptShape` **48.9** | `add_property` 59.4（**已在 put −4**） | put 桶；勿并 +47 |
| shape **新建** | Root 内 `createShape` 约 **8–12**（288/295/299 合计 ~12%） | `js_new_shape2` **24.8** + `add_shape_property` 23.1 | q 更贵（ADD 时建 hashed） |
| shape **毁** | `destroyShape` **45.0** | `js_free_shape` **26.6** | **+18.4** |

创建期 annotate：

- z `createObjectRoot` **27.4%** 在 `shape.zig:243` HIT `while`（hash→proto→`prop_count==0`→`retain`）。CREATE 臂（288–306）合计 ≲15%。
- q NOPC **78.8%** 在 `quickjs.c:5521` `find_hashed_shape_proto` HIT。同算法（`9e3779b1`）。
- 差额仍是 SCPAIR 已写的 **outlined `!*Shape` 0x50 帧 + sret**，Boyer **+2 cyc/发量级**，不是「每颗新建一个 shape」。

### 3.2 P6 挂队口：不启动

`p6-REJECT-ARCHIVE`：残余改判「shape 生命周期单位成本」（z 建/毁 ≈130 cyc/obj vs q 数十），挂队。

本尺：

- **建：** Boyer 热是缓存 HIT，不是 `createShape`。单价差 <30M，SCPAIR 已判不立项。
- **毁：** `destroyShape` − `js_free_shape` = **+18.4M**（13.6 cyc/pair 量级）。annotate 热在 `destroyShape` 748 还块 / unlink / proto `freeObject`——普通 teardown，不是 P6-B 跨 slab 类。
- 130 cyc/obj 是 P6-GROW **扩容微凳**，不是 Boyer 空 shape HIT。

**本单不是启动该挂队案的证据。** 门槛 ≥30M 的 shape 建毁单价在 Boyer-only 上没出现。

`adoptShape` 热在 hashed transition 查（shape.zig:987/686），对应 q `add_property`+`find_hashed_shape_prop`。put 已齐。P6 就地 realloc 封条不动。

---

## 4. `get_arg` +35M

| | z M | q M | Δ |
|---|---:|---:|---:|
| get_arg0 | 53.2 | 41.4 | +11.8 |
| get_arg1 | 54.6 | 31.6 | **+23.0** |
| Σ | **107.8** | **73.0** | **+34.8** |

### 4.1 叶对叶（两边都 16B JSValue + Dup + 间接 `br`）

**z `op_get_arg0_fast`（0x38 / 14 insn，无序言）：**

```
ldr x8, [x3, #24]      // vm.frame
ldr x9, [x8, #64]      // frame.args.ptr
ldp x8, x9, [x9]       // arg0；arg1 是 [x9,#16]
cmn x9, #0xa           // dup 标签
ldur/add/stur rc
stp [x1], #16
ldrb / adrp 表 / br
```

**q `label_OP_get_arg0`（19 insn，JCI 内）：**

```
sub x0, x29, #0x4,lsl#12
ldr x1, [x0, #16104]   // arg_buf 已是 JCI 局部
ldp x1, x0, [x1]
cmn / rc++ / stp [x19]
表 + br
```

z **更短**，但更贵。落点：

| | z get_arg0 % | q get_arg0 % |
|---|---:|---:|
| 取槽（3 跳 vs 1 跳） | 5.0+7.0+10.4 = **22.4** | 8.5+0.5+8.0 = **17.0** |
| `stur` rc++ | **24.3** | **21.9** |
| 分派 `ldrb`/`br` | **20.8** | ~27（摊在 JCI I$） |

get_arg1 的 Δ 是 get_arg0 的两倍：q 1 参函数（`rewrite` / `rewrite_args`）只打 `get_arg0`，所以 q arg0>arg1；z 两个 handler 占用几乎一样 → **arg1 单价更高**（`Frame.args[1]` 多一跳 / 行）。

### 4.2 不是 ctor 体、不是 assq 环

TAKE 把 `sc_Pair` 的 `get_arg0/1` 收成 caller loc。ctor 体那 2×3.34M 发 **不应再进这两个符号**。剩下的是 unify / assq / `is_term_equal` / `one_way_unify1` 的 2 参读。

钱在 **Frame.args slice vs JCI `arg_buf` 寄存器**——和 F 帧桶同一类局部性，不是 get_arg 算法、不是 assq 里的 get_field（已对位）。

---

## 5. +160 最终归属（对 driver）

```
原 +160
  = (181 − 68)     +113   CASE
  + (162 − 115)     +47   错配的 NewObject/shape

公平
  入帧 212 − 68   = +144  TAKE 外壳 + 窗（Entry 发布 = 0.2）
  建对象 82 − 80  = +2    齐
  shape 毁        = +18   <30，不启 P6
  adopt           → put 已齐
  get_arg         = +35   帧 args 局部性（独立桶）
```

**单价差在哪一步：** 不在 get_field、不在 instanceof、不在 put、不在 RC、不在 assq 环内、**不在 Entry `pushConstructorCall`、不在 shape 建毁。**  
在 **每次 Boyer `new` 付的 TAKE 哨**（`consumedArgSlots` 35 + applyForward 28 + findInlined 24 + fused 资格 28）和 **窗 MOVE**（install 31）。

与 pW：封条留下（别开对象生命周期刀）；Boyer 这张凳要把「Entry」改写成「TAKE」。Earley 出树仍可能是臂 E，不外推。

---

## 6. 纪律

- 占用 ≠ 独占。JCI 743 仍含 q 的 Q6 前言；不能把 z TAKE 146 和 q JCI 直接减成第二套 +350。
- 禁外提 `call_method` `0x3f0`。
- 不重开 get_field / instanceof / P6-B / `simple_field_ctor` bypass。
- 不把 TAKE 写成 `sc_Pair` 特判立项。通用是 **已特化的 2 字段普通 `new`**。
- 数字非裁决。
