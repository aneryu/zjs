# SCPAIR-LIFECYCLE — 一颗 sc_Pair 从生到死的逐步单价（只析不改）

日期：2026-08-17。lane w1:pW。**只析不改。无产品 commit。无新分支。**  
数字一律 **非裁决用**。CPU **15**（`armv8_pmuv3_1`）。原始 `/tmp/lanes/scpair-lifecycle/`。

| | |
|---|---|
| z | `/home/aneryu/zjs/zig-out/bin/zjs` @ **main `553840ab`** w45R，sha `a61d0f77…`，`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off` |
| q | `/home/aneryu/quickjs/qjs` `04be246` sha `b76d1542…` |
| 尺 | `/tmp/lanes/eb-func/eb.d16.{earley,boyer}-only.js`（官方 det ÷16，双引擎同份） |
| 发次 | 注入 `__sc_pair_n++` 的计数件（只计数，不进 PMU） |
| PMU | ABBA n=4 `cycles/u`+`instructions/u`；record `-F 4000` ~3k 样本/凳（份额有噪声，总量以 ABBA 为准） |

**已封条、本单不重开：** r11c s5 ctor 不是比值载体；P6 adopt / 就地 realloc；8b / `simple_field_ctor` bypass；⑦ RC teardown iron。

---

## 0. 一句话

d16 发次 **Earley 1.368M / Boyer 3.338M / 合计 4.706M**（z=q 同数）。档案「Earley 4.7M `new sc_Pair`」是 **合凳 d16 发次**，不是 Earley 半场。Boyer 是干净面（几乎全是 Pair）；Earley 掺 `deriv_trees` 闭包。

ctor 体是 `this.car=car; this.cdr=cdr`——**两次都是空对象 ADD**（hashed transition），不是覆盖写。覆盖写（`set-car!` / `falseHead.cdr=`）在 Boyer annotate 上 `str q` 几乎不进 top。

三处「尚未逐指令对过账」的步：

| 步 | 公平对位后 Δcyc（Boyer / 合凳） | ≥30M？ |
|---|---|---|
| 创建期 shape 缓存命中 | **+5 / +16** | 否 |
| put_field 已知 shape 覆盖写 | **≈0**（不是热步） | 否 |
| destroy 尾（普通对象） | **+51 / +74** | **是（贴门）** |

**刀案候裁：K1 普通对象 destroy 瘦尾。** 其余不立项。ctor 入帧差是 Entry 税，封条内。

---

## 1. 发次与总账（d16，ABBA n=4 中位）

| 凳 | n_pair | z cyc | q cyc | z/q | 超额 cyc | z insn | q insn | insn z/q |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Earley | **1,368,316** | 3178M | 2365M | **1.344** | +813M | 13763M | 11041M | **1.247** |
| Boyer | **3,337,797** | 3333M | 2975M | **1.120** | +358M | 15826M | 14894M | **1.063** |
| 合计 | **4,706,113** | 6511M | 5340M | 1.219 | +1171M | 29589M | 25935M | 1.141 |

与 EB-FUNC-ATTRIB d16 半场同号（Earley 1.35 / Boyer 1.12）。det ≈ ×15.60。

Boyer q 侧 `sc_Pair` 占 mapped JCI **15.3%**（EB-FUNC-Q-SIDE，det 尺）——本单不重测函数级 JCI，只把那份额当「Boyer 主粮是 Pair」的旁证。

---

## 2. 一颗 Pair 的逐步回路（源级）

`sc_Pair`（`eb.d16.*.js:939`）：

```
function sc_Pair(car, cdr) { this.car = car; this.cdr = cdr; }
```

稳态（第一个 Pair 之后，`{car,cdr}` 已 hashed）：

| # | 步 | z | q |
|---|---|---|---|
| S0 | `new` 入帧 | `op_call_constructor` → Entry（caller 字节码 >2048，v1.5 拒 TAKE） | `OP_call_constructor` → `JS_CallConstructorInternal` 20809 → `JS_CallInternal` |
| S1 | 取 proto | `prepare…` / GetProperty `prototype` | `js_create_from_ctor` 20783 |
| S2 | **shape 缓存 HIT** | `createObjectRoot`：hash proto → 桶走 → `prop_count==0` → `retain`（outlined `!*Shape`，**0x50 帧 + sret**） | `find_hashed_shape_proto` **熔在** `JS_NewObjectProtoClass` 5514 / 446e0，HIT 后 **tail** `JS_NewObjectFromShape` |
| S3 | 分配对象 | `createPlainObject`：`collectBefore` + slab `createInternal` + 登记。**不**分配 prop 值缓冲 | `JS_NewObjectFromShape` 5613：`js_malloc(JSObject)` + **`js_malloc(prop[prop_size])`**（空 shape `prop_size=2`）+ `add_gc_object` |
| S4 | 跑体 | Entry 内 `push_this` + 两次 `put_field` | 同一 `JS_CallInternal` 的 `this` |
| S5a | **put car/cdr = ADD** | `op_put_field` 探 **miss**（空/半空）→ `add_tail` → `setOrDefine` proto 走（`sc_Pair.prototype` 无 car/cdr）→ `tryCachedTransition` HIT → 第一次附带 `ensurePropertyCapacity` 分配值缓冲 | CASE `find_own` miss → `JS_SetPropertyInternal` proto 走 → `add_property` `find_hashed_shape_prop` HIT（第一次可能 `realloc` 但 `prop_size` 已是 2，不扩） |
| S5b | **put 覆盖写** | `qjsPutFieldFastSlot` 命中 → `str q` + 旧值 rc--（`op_put_field` 无序言叶，63 insn） | CASE 快臂 `set_value`（熔在 JCI） |
| S6 | RC 存续 | 传参/get_field/栈槽 Dup/Free。L3 已证次数对齐 | 同 |
| S7 | 死亡 | `destroyFromHeader`（0xf0 / **2755 静态**）+ `destroyShape` + `destroyZeroRef` | `free_gc_object` → `free_object` 6340 + 每槽 `free_property` + `js_free_shape` + `__js_free` |

S5a 每发两次。S5b 只在 `sc_setCarBang` / `tail.cdr = …` / `falseHead` 上出现，Boyer 相对 2×ADD 可忽略。

---

## 3. 逐步单价（Boyer = 干净面）

分母 = 3,337,797 Pair。符号份额来自本单 record（~3k 样本），× ABBA 总量。

### 3.1 可见符号 / 发

| 步 | z 符号 | z insn/发 | z cyc/发 | q 符号 | q insn/发 | q cyc/发 | Δcyc 凳 |
|---|---|---:|---:|---|---:|---:|---:|
| S0 入帧 | `op_call_constructor` | 234 | 50.5 | `JS_CallConstructorInternal` | 46 | 9.0 | **封条**（余在 JCI / Entry） |
| S2 shape HIT | `createObjectRoot` | **108** | 13.5 | `JS_NewObjectProtoClass` | 77 | 11.9 | **+5M** |
| S3 对象 | `createPlainObject`+`collectBefore`+`createInternal` | 72 | 16.8 | `JS_NewObjectFromShape`+`js_create_from_ctor` | 76 | 14.4 | +8M |
| S5a 探×2 | `op_put_field`（几乎全是 miss 探） | 193 | 26.5 | CASE 熔在 JCI | （不独立） | （不独立） | 见 §4.2 |
| S5a ADD×2 | `add_tail`+`setOrDefine`+`adoptShape` | 367 | 82.4 | `JS_SetPropertyInternal`+`add_property` | 344 | 75.8 | +22M |
| S5b 覆盖 | `op_put_field` `str q` 臂 | ≈0 | ≈0 | CASE `set_value` | ≈0 | ≈0 | **不是热步** |
| S7 毁 | `destroyFromHeader`+`destroyShape`+`destroyZeroRef` | **313** | **59.3** | `free_gc_object`+`free_property`+`js_free_shape` | 202 | 43.9 | **+51M** |

malloc/free 共享池（`__js_malloc` 81M / `__js_free` 70M Boyer）含对象+prop[2]，z 的第二块在第一次 ADD 上付，不并进 S3，避免双计。

### 3.2 Earley 半场（掺闭包，不能当 Pair 单价）

Earley `destroyRuntimeCycles` **273M cyc / 199 cyc/pair**、`drainCycle` 71M——这是 `deriv_trees` 互捕获环，不是 Pair 槽。`createObjectRootWithPropertyCapacity` 19M 是闭包/其它形。r11c s3 压扁闭包塌 −631M，本单不重开。

---

## 4. 三处未对过账的步（逐指令）

### 4.1 创建期 shape 缓存命中

**q HIT（`JS_NewObjectProtoClass` 56 静态 / 48B 帧）**

```
hash proto (9e3779b1) → 取桶 → cbnz 非空 (annotate 54% insn 落在这条)
→ hash/proto/prop_count==0 → rc++ → ldp 拆帧 → b JS_NewObjectFromShape
```

HIT 本身约 20 insn，然后 **tail** 进 FromShape（再付 2×malloc + add_gc）。

**z HIT（`createObjectRoot` 185 静态 / **0x50 帧** / `!*Shape` sret）**

```
sub sp,#0x50; 6×callee-saved
hash proto（同 9e3779b1）
取桶 → cbnz （annotate 17% insn / 35% cyc）
walk: hash → proto → prop_count==0 → retain
strh 0 / str ptr 到 sret 槽
ldp×3; add sp,#0x50; ret
```

然后 `createPlainObject`（0x50 帧，112 静态）再 `bl collectBefore` + `bl createInternal` + 填字段 + TLS 哨 + 挂 GC 链。

**差额来源：** 不是哈希算法（两边同一 `9e3779b1`），是 **outlined error-union 调用**。q 把 find+dup 熔进 NOPC 再 tail；z 为 `!*Shape` 建 0x50 帧、写 sret、ret 回 CPO。

Boyer Δ **+30 insn/发 × 3.34M = +100M insn，+1.6 cyc/发 = +5M cyc**。合凳 createObjectRoot 77M vs NOPC 61M = **+16M cyc**。**<30M，不立项。**

（annotate 在 miss/create 块上也有样本：`index z0.s` 清 FAM、`createWithFam`。HIT 占主导；miss 块静态长，少数非 Pair / 首发 / PMU skid 会被放大。不影响「HIT 比 q 多一个 outlined 帧」这条。）

静态对照：

| | z | q |
|---|---:|---:|
| shape HIT 函数 | 185 insn / 0x50 | 56 insn / 48B（含 miss 臂） |
| 对象分配函数 | CPO 112 / 0x50 | FromShape 223 / 64B（含 2 malloc + class switch） |

z 创建时 **不** 分配 prop 值缓冲（对齐 `createInternal` `capacity==0`）；q 在 FromShape 付 `prop[2]`。第一发 ADD 补上。不是少干活，是记账窗右移。

### 4.2 put_field：覆盖写 vs ADD

`op_put_field` 63 insn，**无序言**（岛内叶）。快臂：tag → 禁 mapped_args → 桶探 → 可写 data 掩码 → `ldp` 旧值 / `str q` 新值 → 旧值/receiver rc--。

Boyer annotate（insn）几乎全在 **miss 探**：

| 地址 | insn% | 是什么 |
|---|---:|---|
| `1073414` `cmp x14, x13` | **26.7** | 空桶哨兵 `0x3ffffff` |
| `1073410` `mov w13, #0x3ffffff` | **20.3** | 同上 |
| `107340c` `ldr` 桶 | 11.6 | 哈希探 |
| `10733dc` `adrp` | 8.1 | **miss → add_tail** |
| `str q0` / `subs rc` | **不进 top 18** | 覆盖写 |

结论：ctor 两次 put 都 miss。覆盖写不是本回路主粮。TS-PUT-SHELL 已记过哨兵 `0x3ffffff` vs q `cbz 0`（约 +9 insn/put）。摊到 Boyer 6.68M ADD ≈ +60M insn / ≲15M cyc——**<30M cyc，且不是新洞。**

ADD 栈公平对：

| | z | q |
|---|---:|---:|
| helper | `setOrDefine` 258 insn/发 / 57 cyc / **0xd0 帧** / 344 静态 | SPI 290 / 65 / 0x120 / 687 静态 |
| transition | `adoptShape` 77 / 18 | `add_property` 54 / 11 |
| 跳板 | `add_tail` 32 / 8 / 0x50 | CASE `goto slow` 熔在 JCI |

z helper **已经不贵过** SPI（Boyer −25M cyc）。`setOrDefine` 热在 proto 走的 `cmp w13,w8`（空桶哨兵，29% insn）——`sc_Pair.prototype` 上没有 car/cdr，走完再 ADD。q SPI 同样热在 proto 链 `cbz`（31%）。**形态对齐，z 略便宜。**

`adoptShape` 59M Boyer = hashed transition 的 outlined 尾。P6 封条：不重开就地 realloc / 跨 slab 类。本单不把它当新刀。

### 4.3 destroy 尾

`destroyFromHeader`：**2755 静态 / 0xf0 帧**。q `free_object` 熔在 `free_gc_object`（591 静态，含所有 class）+ 每槽 outlined `free_property`（61 / 32B 帧）。

Boyer annotate 分桶（本单按地址切）：

| 桶 | insn% | cyc% | × DFH 126.6M cyc | 对 q |
|---|---:|---:|---:|---|
| 入口 / class_id 派发 / 0xf0 序言 | 22.9 | 17.0 | **22M** | q 是 `class_array[id].finalizer` 空指针，几条 |
| 槽循环（2× data free + rc--） | 44.2 | 53.6 | **68M** | `free_property` 52M（outlined 每槽） |
| payload switch | 4.8 | 3.1 | 4M | 普通对象走不到 |
| 摘链 / 还 slab | 27.9 | 26.3 | **33M** | `b __js_free` + `__js_free` 共享池 |

公平三件套（Boyer）：

| | z M cyc | z insn/发 | q M cyc | q insn/发 |
|---|---:|---:|---:|---:|
| 对象毁 | DFH 127 | 201 | fgc 65 + fprop 51 = **116** | 91+57=**148** |
| shape 放 | destroyShape 38 | 66 | js_free_shape 30 | 55 |
| rc==0 跳板 | destroyZeroRef 33 | 46 | `__JS_FreeValueRT` 22 | 18 |
| **Σ** | **198** | **313** | **168** | **202** |

Δ **+30M 对象+跳板 / +51M 含 shape**。合凳（Earley 掺闭包）DFH+dShape+zeroRef 385 vs q 311 = **+74M**。

insn 差主要在 DFH 入口派发（22% 的 671M = 154M insn / ~110 insn/发）和还块路径。槽循环 z 已 inline，cyc 上并不比 `free_property` 贵。

这是全回路里 **唯一跨过 30M 的未对账步**，且不碰封条。

---

## 5. RC 存续（不是新洞）

L3-RC-DIVERGENCE：EB Dup/Free 次数 z/q **1.025 / 1.002**。热径 borrow（`JS_VALUE_GET_OBJ` / 栈窗 / `set_value` 先写后 Free）已镜像。本单不再把「RC 固有」立成 Pair 刀。Earley 的 `destroyRuntimeCycles` 273M 是闭包环，r11c 已定价。

---

## 6. 刀案候裁

### K1 — 普通对象 destroy 瘦尾（FAITHFUL，候裁）

**做什么**

- 给 `class_id == object`、`.none` payload、`weakref_count==0`、非 cycle-phase 的路径做一份 **outlined 热叶**（或 `destroyFromHeader` 最前的 likely 臂），对齐 `free_object` 6340–6391：
  1. 标 mark/finalizing
  2. 两槽 `isData` 值 `free`（sc_Pair 稳态恰好 2；`prop_count` 通用）
  3. `free` 值缓冲
  4. `shapes.release`
  5. `unregisterObjectWithBytes` + slab `destroy`
- 热叶 **禁止** 物化 `InlineClassPayloadLayout`、21 臂 payload switch、borrowed/std_file/weak-id 扫描。
- 任何守卫失败立刻掉回现 `destroyFromHeader`。
- ⑦ `destroyRuntimeCycles` / Pass B / weak husk **一字不改**。

**对 q：** 就是 `free_object` 的普通对象臂。没有新语义。

**不做什么：** 不重开 P6 adopt；不扩 bypass；不特判 `sc_Pair` 名字；不把 ctor Entry 再当比值载体；不涨 2048；不动 `call_method`。

**预报（非裁决，d16）**

- Boyer：对象+跳板差 **~30M cyc**，含 shape 则 **~50M**。insn **100–180M**。
- 合凳乐观 **40–70M cyc**（Earley DFH 有一半不是 Pair）。
- 吃不完 Earley +813M，也不该吃——那是闭包。

**门（若批）**

- `test-core` 对象/GC/弱引用；`test-exec` 构造完成。
- objdump：热叶帧 ≪ 0xf0，DFH 全函数可留冷。
- 哨：P6 官方 5e6、splay、EB d16 Boyer-only 不得回退。
- 禁碰 cycle-phase / weak husk 样本。

### 不立项

| 候选 | 原因 |
|---|---|
| 内联 `createObjectRoot` HIT | +5 / +16M cyc，<30M |
| put 覆盖写快臂再瘦 | Boyer 不是热步 |
| 哨兵 `0x3ffffff`→0 | TS 已记账，摊 Pair ≲15M cyc |
| 再削 `setOrDefine` proto 走 | z 已不贵过 SPI |
| `adoptShape` / 值缓冲就地扩 | **P6 封条** |
| TAKE / 放宽 2048 / 名字特判 ctor | **r11c s5 + r14a 封条** |
| 8b bypass | **禁** |
| 解释器再瘦 `op_call_constructor` 当比值刀 | 封条；体必须跑 + Entry 税已在 r14a 定价 |

---

## 7. 合凳对照（守恒，非 Pair 单价）

旧合凳 d16 画像（EB-FUNC-ATTRIB，`0f721021`）与本单半场相加同号：

| 符号 | 旧合凳 % / M | 本单 E+B M |
|---|---:|---:|
| `destroyFromHeader` | 4.32% / 275 | 266 |
| `createObjectRoot` | 1.20% / 77 | 77 |
| `createPlainObject` | 0.71% / 45 | 38 |
| `setOrDefine` | 3.59% / 229 | 265 |
| `op_put_field` | 2.21% / 141 | 132 |
| `op_call_constructor` | 4.12% / 263 | 256 |

---

## 8. 请收

- 产物：`/tmp/lanes/SCPAIR-LIFECYCLE.md`
- 原始：`/tmp/lanes/scpair-lifecycle/`（ABBA `stat.json`、发次 `counts.json`、shares、annotate、asm）
- 合 main：无
- 候裁：K1 普通对象 destroy 瘦尾（Boyer +30–50M cyc 量级）。其余两处未对账步不对 30M 门。
