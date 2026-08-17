# CH3-FAT-SCOPING — 肥 op 窗合法形态存在性

日期：2026-08-17。**只设计，无码，无 commit，不占 254/255，不进岛。**  
承接：`CH3-DISPATCH-SPIKE` APPROVED + `CH3-P0-CENSUS` ACCEPTED（通道 #3 v1 = REJECT-ARCHIVE）。  
生产形：`main@9deb9f45` 族 RF，`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,…`。  
体长钉自干净 RF `/home/aneryu/zjs/zig-out/bin/zjs`（`nm`；普查钩子件会胀岛，不用它的尺寸）。  
单案 hop 复用 P0 工装 TSV（`/tmp/ch3-p0/win-*.tsv`），不重跑 zoo。

诚实优先。本文件允许、并且给出的结论是：**不可达。**

---

## 0. 判决

**不可达定理成立。没有「共享热臂、LLVM 保证不克隆」的合法进入方式。**  
用户点名的两种形（musttail 进共享体非入口；comptime `noinline` + tail）分别撞 **LLVM IR 不可表示** 和 **本仓库已证的 fn-type / 折回墙**。其余编码分别撞克隆禁、外提禁、monolith no-go、局部性墙、或 5 参 C 封存。

因此：**不出施工 spike，不开杀门试探，254/255 继续保全。** 肥 hop 不是通道 #3 的下一刀。

附证（非判决主因，但封死「就算有形也该试」）：box2d/TS 的 `get_field→get_field` 直线对并集下界只有 **22.5M hop**，折 4.5–9.0M cyc，远低于 30M；具名 3 窗更矮（TS 6.55M / box2d 1.91M）。而且 box2d 上 `op_get_field` 已经是对 qjs 的 **信用**（F-RESID −62M cyc），残差在 BIN-MUL 不是字段 hop。

---

## 1. 问题框

CH3 v1 因克隆禁 / 外提禁不收肥体。架构段（box2d / TS）的 hop 主要在 `get_field` 上。本 spike 只问：

> 有没有一种编码，能让 3–4 原子直线窗在 **窗内 0 次表 `br`** 的前提下跑完 ≥1 发肥 op 热臂，同时满足：热臂在 `.text` 里只有一份、LLVM 不把它抄进区域 handler、不 `bl` 外提、不并进 CASE 单体、区域体 ≤0x100、4 参 `Handler` ABI 不动？

「合法」= 同时满足通道 #3 合同 + 负定理群（局部性墙 / 外提禁 / 融合物理下限 / monolith no-go）+ R1（冷表指回首原子原 handler）+ 254/255 保全。

肥 = `get_field` / `get_field2` / `get_array_el` / `put_field` / `call_method` 及已融肥原子。本文件主线用 `get_field`（最大、最热、体最长的诚实代表）；`get_array_el` 已有 v4 克隆滑岛判例，`call_method` 另坐 0x3f0 外提禁。

---

## 2. 单案 hop（P0 TSV 另量，不是并集一句）

口径：融合后、`cont` fallthrough、§1.3 `legal_all`（无 jump；poll 不在中间）。动态 n-gram 是静态无入边窗的 **上界**。

### 2.1 具名 3 窗（派单原文）

| 案 | 形 | hop | ×0.2–0.4 cyc |
|---|---|---:|---|
| typescript | `get_var_ref0 → get_field → get_field` | **6.55M** | 1.3–2.6M |
| box2d | `get_loc1 → get_field → get_field` | **1.91M** | 0.4–0.8M |
| box2d | `get_loc3 → get_field → get_field` | 1.30M | 0.3–0.5M |
| box2d | `get_field → get_field → get_loc8` | 1.50M | 0.3–0.6M |

并集：`get_var_ref0 → get_field → get_field` 6.58M（几乎纯 TS）；`get_loc1 → get_field → get_field` 2.58M。

### 2.2 `get_field → get_field` 2-原子对（3-gram 下界）

每个案 `max(Σ as01, Σ as12)`，as01 = 三连前两格都是 `get_field|get_field2`。

| 案 | 对 hop 下界 |
|---|---:|
| typescript | **10.21M** |
| box2d | **6.70M** |
| earley-boyer | 2.07M |
| crypto | 1.50M |
| raytrace | 0.99M |
| 其余 10 案 | ≤0.51M |
| **zoo Σ of max** | **22.51M** |

TS 4 窗头：`get_field → get_var_ref0 → get_field → get_field` 4.11M。没有藏着的 50M 肥链。

对照占用（`TS-GET-FIELD` / `BOX2D-F-RESID`，软件计时）：TS `get_field` **53.58M** 发、box2d **31.43M** 发。直线 `gf→gf` 只覆盖其中 10.2 / 6.7M——**大多数字段 hop 不在可切的直线窗里**（中间有 label / call / 入边）。就算窗形合法，也吃不到那 53M。

### 2.3 并集最热的「肥 3」不是字段链

`sar → get_loc8 → put_array_el` 37.60M、`get_array_el → push_i8 → sar` 20.53M——mandreel/crypto/zlib 的数组肥，v4 已定性克隆禁。与 box2d/TS 架构段无关。

---

## 3. 今日树上已经存在的「合法共享」

这些不是新缝，是合同里已经用过、且 **不能** 推广成 0-hop 肥窗的形。

| 形 | 体长（生产 RF） | 做什么 | 为什么不是本问的答案 |
|---|---|---|---|
| `op_get_field` | **0x340** | 唯一热臂正本。命中走 `qjsGetFieldFastSlotOrAbsent`（`inline fn`，源级一份、编译期抄进本函数） | 区域体硬顶 **0x100**。一份热臂已经 3.3× 顶 |
| `op_get_loc0_field` / `get_loc2_field` / `get_var_field` | **0x40** | 小组件 A 做完，`always_tail op_get_field`。B 字节留着 | 通道 **#2** 2-原子 leftover。窗内对第二发 `get_field` 仍 `cont`。DT 已证直 `b` 相对表 `br` **周期≈0** |
| `op_get_field_field2` | **0x240**（`.op_handlers.tail`） | **抄** 第一发 walk，命中后 `always_tail op_get_field2` | 已经是克隆。放岛尾以免滑 `get_field`/`if_false8`。仍付 1 hop 给第二发。CH3 要的是窗内 0 hop |
| `property_tail_tbl[slot]` | 冷尾 0x1c0–0x710，岛外/岛尾 | 运行时下标，LLVM 折不回 unusual | ** hop**（`ldr+br`）。只养 miss/primitive/destroy。热臂用它 = 把要砍的税加回去 |
| `qjsGetFieldFastSlotOrAbsent` | `pub inline fn` | 源级共享 | 编译期 **必克隆**。这是 F 热臂零 `bl` 的代价，也是「再多一个调用者 = 再抄一份 0x340」的原因 |

`get_field2` 0x320、`get_array_el` 0x280、`put_field` 0x120、`call_method` **0x1800** / 入口 `sub #0x3f0`。无一能进 ≤0x100 的区域叶。

墓碑合同（源注释，对 `8d6ae58c`）：`get_field 0x35c` 量级。现尖 0x340，同档。CH3 区域叶若把这团抄进去，岛钉（`get_field` / `if_false8` 0x140）必滑。

---

## 4. ① 候选进入方式（逐条撞墙）

### 4.1 musttail 至共享体 **非入口点**

想要：区域 handler 做完 `get_loc1`，`b` 进 `op_get_field` 的 walk 标签（跳过它自己的 `ldrb`/`atom` 序言，或从序言后接着跑），第二发再落回区域。

**LLVM IR 不可表示。**

- `musttail` / `call` 的目标必须是 **函数**。不存在「tail-call a basic block」。
- `indirectbr` 的目的地必须在 **当前函数内**（LangRef）。跨函数的 `blockaddress` 不能当间接跳目标。
- 把 walk 标签提成新函数入口 → 退回 §4.2（仍是入口，musttail 不返回）。
- 把区域和 `get_field` 写进 **同一个** 函数、用 `indirectbr` 在窗标签之间跳 → 这就是 **91 臂 monolith**（2026-07-14，PMU 4/4 回退）。有界 2 窗切片仍是「按形 `switch` 的隐形单体」，spike §2.4 明文禁。

裸 `asm` `b get_field_walk`：两函数必须比特级同帧、同活寄存器约定，且标签不能被 LLVM 重排（与 L-1 墓碑钉址对打）。这不是 LLVM 保证，是跟 LLVM 打仗。CFI / 岛序 / tombstone 任一动就静默坏。**非法。**

结论：非入口 musttail **不是** 一个可实施形。

### 4.2 comptime 强制 `noinline` + tail 形

想要：

```text
fn getFieldHot(...) callconv(.c) Outcome { /* 唯一 walk */ }
op_get_field  = decode;  always_tail getFieldHot
op_region     = loc;     always_tail getFieldHot   // 然后还想做第二发
```

三堵已经砌好的墙：

1. **musttail 不返回。** `getFieldHot` 出口是 `cont` 或另一条固定尾。区域无法「调用两次 walk」而不再付 hop。要第二次，只能：再 `cont`（0 奖金）、或把第二发抄进 `getFieldHot`（克隆）、或加 continuation 参（§4.6）。
2. **`noinline` 标不上 `Handler`。** `call-entry-slim-LESSONS` / `v2-k-ret-slim-UNUSUAL-SPLIT` 原文：
   > 同文件、同 `Handler` 类型的 `always_tail`，LLVM ReleaseFast 会内联目标。`noinline` 又改 fn type，编不过。
   所以「comptime 强制 noinline + 同 ABI tail」**编不过**。LLVM RF 的实际行为是把目标 **折回调用者** = 克隆。pV 连 ctor rest 都折过（9912B → 10204B）。
3. **改成运行时表防折回**（今日 `property_tail_tbl` / `cold_table[pc[0]]`）= 多一次 `ldr+br`。DT-SPIKE：再短的 hop 周期≈0；CH3 要砍的就是这次 hop。热臂走冷表共享 = 机制自相矛盾。

结论：这种形要么编不过，要么被折回成克隆，要么退化成 hop。

### 4.3 区域叶内联两发 walk（「就抄两遍」）

源级最直。体长 ≥ 0x340 + 0x340，远超 0x100。进主岛 → 滑 `get_field`/`if_false8`（v4：`get_array_el → push_0` 克隆把热体缩短 84B，**整岛后滑**，对已弃）。进岛尾 → 几何或许可（`get_field_field2` 先例），但仍是 **两份** 热臂，I-cache 双载，局部性墙；且 `call_method` 0x1800 绝不能抄。

这是克隆禁的正例，不是缝。

### 4.4 肥只当窗尾，前缀小组件 + `always_tail op_get_field`

合法，**已经在做**（`get_loc0_field` 0x40）。奖金 = 省掉前缀小组件的表 `br`，末发肥仍是一次 `b`/`cont`。

- 3 窗 `get_loc1 → get_field → get_field` 这样只能吃掉 `get_loc1`，第二发字段仍 hop。
- 前缀 hop：box2d 1.91M、TS 的 `get_var_ref0` 6.55M。P0 已判 39M 都过不了 30M cyc。
- 2 原子，通道 #2 编制。**不要占 254。**

DT：直 `b` vs 表 `br` 周期不可测。末发肥从 `cont` 改成直 `b` 不是新矿。

### 4.5 `bl` 到共享 walk，walk `ret` 回区域

共享一份、可序列化两发。同时违反：

- handler 不变量：**ZERO 非尾调用**；
- 外提禁：热函数里任意 `bl` 会把 `sub sp` 摊回入口（G-BL / call-entry-slim §2.1）。今日 `op_get_field` 把 destroy 都 musttail 出去，就是为了保住无帧叶；
- 要让 walk `ret`，必须先把它从「handler 尾进 `cont`」改成子程序 ABI——等于拆掉 F 已经赢下来的 −62M 信用。

### 4.6 第 5 参 / `vm` 里藏 continuation / sidecar 形

`getFieldHot(..., resume)`，命中后 `always_tail resume`。4 参 ABI 加参 = **5 参 / 8 参 C 封存**。塞进 `vm` 字段 = 每 hop 多一载，DT-A sidecar 同轴，已 HANG。

### 4.7 再做一对 `get_field_field`（抄第一发，尾跳第二发）

`get_field_field2` 的翻版。通道 **#2**，岛尾克隆，仍 1 hop，对频 22.5M < 75M。不碰 254，也不解决「0 hop 窗」。**不是缝。**

---

## 5. ② 不可达定理

**定理（CH3-FAT）。**  
设现行合同为：4 参 `Handler` + `always_tail` + 自身帧 ZERO 非尾调用 + 禁克隆 `get_field`/`get_array_el` 热体 + 禁外提 + 禁 monolith + 区域叶 ≤0x100 + 不改 hop 胶水 + 不加参。  
则不存在编码使 3–4 原子直线窗在窗内 0 次间接/直接 hop 的条件下执行 ≥1 发肥 op 热臂。

**证明。** 肥热臂正本 `H` 现长 |H|≥0x340>0x100，且必须在 `.text` 里只留一份。区域叶 `R` 要跑 `H`：

| 到达 `H` 的方式 | 撞 |
|---|---|
| `always_tail` 进 `H` 的函数入口 | musttail 不返回 → 窗后继无法在 `R` 里继续；该发肥的窗奖金为 0。若肥是窗尾且前缀是小组件：即已存在的 #2 leftover，不是 3–4 窗 0 hop |
| `always_tail` / `b` 进 `H` 的块标签 | LLVM IR 无此形；做成同函数多标签 = monolith |
| 把 `H` 抽成同 ABI `noinline` 再 tail | `noinline` 改 `Handler` 类型，编不过；不标则 RF 折回 = 克隆 |
| 运行时表指向唯一 `H` | 一次 `ldr+br` = 要砍的 hop |
| `bl H; ret` | 外提 + 非尾调用 + 摊帧 |
| 把 `H` 抄进 `R` | 克隆；\|R\|≥0x340>0x100；滑岛 / 局部性墙 |
| 给 `H` 一个 resume 目标 | 第 5 参或 sidecar，C 封存 / DT HANG |

穷尽。证毕。

一句话：**共享且不克隆 ⇒ 只能跳到那一份；跳到那一份 ⇒ 要么不返回（后继要再 hop），要么返回（外提），要么同函数多出口（monolith）。** 0-hop 窗需要「不跳也不抄也不回」，在 4 参 musttail 机器上没有第四种控制转移。

### 5.1 证据链（按负定理）

| 负定理 | 证据 | 对本问 |
|---|---|---|
| **克隆禁 / 岛滑** | v4 `get_array_el→push_0` 弃：克隆缩短 84B，整岛后滑。`get_field_field2` 被迫停 `.tail` 且仍是抄 walk | 抄进区域叶 = 重演。`inline fn` walk 保证「多一个调用者多一份代码」 |
| **局部性墙** | K-ret-slim / unusual：岛内热叶必须短。区域硬顶 0x100。生产 `get_field` **0x340**、`call_method` **0x1800** | 一份肥臂就超顶。两发更超 |
| **外提禁** | `call-entry-slim-LESSONS`：热函数任意 `bl` → 入口 `sub sp`。G `0x3f0` 帧为承认而建。F 把 destroy 都 tail 出去才保住无帧 | `bl` 共享 walk = 拆 F 的 −62M 信用 |
| **musttail 折回** | 同文件同 `Handler` 的 `always_tail`，RF **内联目标**；`noinline` 编不过 | 「强制 noinline + tail」不可用 |
| **monolith no-go** | 2026-07-14，91 臂 4/4 回退 | 非入口 / computed-goto / 同函数多窗标签 |
| **融合物理下限** | leftover B 必须可 dispatch；再偷看胀 A 体，zlib insn 赢 cyc 不赢 | 不能靠把第二发 `get_field` 塞进第一发体来「省 hop」 |
| **DT / 5 参 C 封存** | hop 再短周期≈0；加参封存 | 表共享、sidecar resume、第 5 参一律出局 |
| **R1** | 冷表必须指回首原子 **原** handler，禁另写按形慢体 | 即使做区域改写，冷路径仍进 `op_get_field` 正本——正本必须留下，区域不能取而代之变成「唯一体」 |

### 5.2 和「qjs CASE 直线段」的差

qjs 的 0-hop 是 **同一份** `JS_CallInternal` 里的 CASE 直落（`get_field` 符号 ⊂ 0x251c0 单体）。那份红利的实现就是 monolith。zjs 用多入口表换来了 F 热臂比 CASE **更短**（TS：47 insn / 10 跳 vs q 51 / 8；box2d F-GET **−61.8M cyc**）。再把两发 `get_field` 并回一个函数，是退回已回退的 4/4，不是超越。

---

## 6. ③ 缝？最小验证？

**无缝。不立项 spike，不设施工杀门。**

若未来 LLVM/Zig 出现 **新能力**（跨函数 `blockaddress` 可作为 `musttail` 目标，且 RF 保证不折回、不改 `Handler` 类型），再另开存在性 spike，杀门应在写第一行产品码之前：

| 门 | 不过就停 |
|---|---|
| IR/asm | 区域叶对 walk 标签是 `b` 不是 `bl`；`op_get_field` 正本 `nm` 体长与基线逐字节同档（现 0x340）；区域叶自身 ≤0x100 |
| 折回 | `objdump` 区域叶内 **没有** walk 的第二份（无复制的 `qjsGetFieldFastSlot` 指令序列） |
| 岛 | `op_get_field` / `op_if_false8` 址与基线相同 |
| 矿 | 目标形动态 hop × 0.2–0.4 ≥ 30M cyc。以今日表，**没有** 这样的肥窗 |

今日不满足「新能力」前提，故 **不占核、不占槽、不写钩子**。上面四门是给未来编译器的收件标准，不是本周的工单。

通道 #2 再收 `get_field_field`（抄 + 尾跳）也 **不建议**：对频 22.5M、必克隆、奖金 1 hop、架构段主残差不在这条边上。

---

## 7. 架构段该去哪（本文件不立项）

box2d 后 F：`+43M cyc` 主色是 **BIN-MUL/ADD/SUB +30M**，不是字段 hop（`BOX2D-F-RESID` / `BOX2D-POSTF`）。  
TS 0.913：`get_field` 21.7% 是 **占用** 不是超额，热臂已短于 qjs（`TS-GET-FIELD`）。

所以即使定理被未来 toolchain 推翻，这 6.55M / 1.91M 窗也填不满架构段。架构段不在通道 #3。

---

## 8. 明确不做

- 不写区域 handler，不占 254/255。
- 不抽 `getFieldHot` 子程序，不给 `Handler` 加 `noinline`，不加第 5 参。
- 不重开 `get_field_field` / 不重开 v4 数组克隆对。
- 不重开 F1–F3，不重开 DT / sidecar。
- 本文件在 `/tmp/lanes/`，不自动入 `reports/`。

---

## 9. 一句话

肥 op 窗在现行合同下 **不可达**：共享不克隆就必须跳进唯一热臂，跳进去就无法在 4 参 musttail 下 0-hop 接第二发；不跳就得抄（超 0x100、滑岛）或 `bl`（外提摊帧）或并进单体。点名的两种形分别是 IR 不存在、和仓库里已经编不过/折回的墙。收案。254/255 空。
