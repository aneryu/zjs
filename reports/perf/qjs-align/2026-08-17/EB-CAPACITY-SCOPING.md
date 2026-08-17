# EB-CAPACITY-SCOPING — 容量墙完整实现型裁决材料

日期：2026-08-17。lane **w1:pS**。**只设计、无码。** 未绑 5/6/7/19；未重测 L1I/zoo（超额引用既有报告）。  
递 driver 审后转用户裁。数字 **非裁决用**。

| 引用（不重测） | 冻结点 |
|---|---|
| 官方站位 | **EB 0.7984**（最大落后项；用户口径） |
| 历审三分 | **形税一半 + 容量墙 + RC/GC 固有** |
| stall / 22× | [`/tmp/r11/STALL-TAXONOMY.md`](/tmp/r11/STALL-TAXONOMY.md)（POSTS2 件 `82bea336`，EB 1.303 / +1647M） |
| 热核体积 | [`/tmp/r11/HOTCORE-SIZE-AUDIT.md`](/tmp/r11/HOTCORE-SIZE-AUDIT.md)（L-1.5 件，414KB / 183） |
| 布局终局 | [`/tmp/lanes/LAYOUT-CLOSED.md`](/tmp/lanes/LAYOUT-CLOSED.md) · [`layout-L15.md`](/tmp/lanes/layout-L15.md) |
| 守恒 | [`/tmp/r11/EB-R14-MAP.md`](/tmp/r11/EB-R14-MAP.md) · [`EB-POSTS2-MAP.md`](/tmp/r11/EB-POSTS2-MAP.md) · [`EB-W25-REFRESH.md`](/tmp/lanes/EB-W25-REFRESH.md) |
| 近审 | [`EB-GETFIELD-MIX.md`](/tmp/lanes/EB-GETFIELD-MIX.md) · [`EB-CTOR-WALK.md`](/tmp/lanes/EB-CTOR-WALK.md) · [`EB-GEO-RECOVER.md`](/tmp/lanes/EB-GEO-RECOVER.md) |
| 边界案 | [`BRIEF-CONCAT-INPLACE.md`](/tmp/lanes/BRIEF-CONCAT-INPLACE.md) **H2** · [`p6-REJECT-ARCHIVE.md`](/tmp/lanes/p6-REJECT-ARCHIVE.md) **P6** |
| 分捡 | [`/tmp/r11/DIVERGENCE-BACKLOG-TRIAGE.md`](/tmp/r11/DIVERGENCE-BACKLOG-TRIAGE.md)「L1I 22× 是容量墙…已结案」 |

现件静态度（**不是** L1I 复测，只核对岛还在不在）：`main@9deb9f45` RF  
`.text.zjs.op_handlers` **0x2d688 = 185.7KB**（审计 174.3）；**无** `.text.zjs.hot`（L-1.5 未合）。  
`traceChildren` 仍 **两份** `0x3bac+0x3d34 = 30.8KB`。qjs `JS_CallInternal` 仍 **0x9654 = 38.5KB**。

---

## 0. 给裁者的一句

**容量墙的机制本体不是任何一条 malloc / 属性扩容 / String 增长路径。**  
它是：**Earley-Boyer 解释器工作集（handler 岛 + 热助手）装不进 64KB L1I**，相对 qjs「一团 `JS_CallInternal` 37.6KB」打出 **L1I refill 21.6×**（139.8M vs 6.5M），把多出来的周期里那截 **效率税** 变成前端 stall。

- 形税（insn / 分派地板 / 具名 opcode）是**另一半**，GET-FIELD 已证 555M 对位 q CASE，不是本墙。
- H2（String capacity 字段）和 P6（adopt/reloc 就地扩）是**别的容量故事**，本墙完整实现**不准**借它们的刀形，也**不准**当本墙的付款面。
- 布局三轮（L-1 已合 / L-1.5 拒 / L-2 闭）已经证明：**只重排、不缩体积 = 墙还在**（L1I −7.7%，cyc −0.3%，分数 ≈0）。
- **完整实现** = 把 EB 可达工作集打进 **≤3×L1I（192KB），最好 ≤2×（128KB）**。那是解释器密度重写，不是现役 FAITHFUL 刀。卫生项吃不满。

**建议裁：S3-B 关墙（接受 architectural-capacity），或 S3-A 单独立「密度战役」由用户批预算。不要开 S1/S2 当过线刀，不要重开 L-1.5/P6-B/H2。**

---

## ① 机制本体（精确）

### 1.1 它是哪条「分配 / 扩容」？

**I-cache 线的分配，不是堆块的扩容。**

| 问 | 答 |
|---|---|
| 哪条路径？ | Boyer 热环上的 **取指**：musttail handler 岛（现 185.7KB）+ 岛外 GC/调用/put/alloc 助手。每换一个 `op_*` / `traceChildren` / `destroy*` 就可能跨 64B 线、跨 4K 页。 |
| 谁在「扩」？ | 工作集随 **同时热的符号数** 涨，不随某个 `js_realloc`。EB 热符号是一长串 `op_get_field` / `op_return` / `op_instanceof` / `op_call_constructor` / `destroyRuntimeCycles` / `traceChildren`×2 / `destroyFromHeader` / `setOrDefine`… |
| qjs 对位？ | **没有**对位的扩容函数。对位是 `JS_CallInternal` **37.6–38.5KB 一团**（一半周期、IPC ~5.0），L1I refill **6.5M / 0.0012 per cyc**。z 是「一岛多叶 + 岛外助手」。 |
| 不是什么？ | 不是 `adoptShapeForNewProperty` / `relocateShape`（P6）。不是 String `usable_size` 就地追加（CONCAT / H2）。不是 `createObjectRootWithCapacity` 的对象初值。W25 shape 五件对 q 超额 +172M 是**生命周期单价**，已判「不是第二颗钉」。 |

DIVERGENCE 分捡原话：*「EB 的 L1I 22× 不是 278 里任何一条能收的。容量墙已结案。」*

### 1.2 既有量化（不重测）

**STALL-TAXONOMY**（EB FW，8-sample ABBA，件 POSTS2）：

| | z | q | z/q |
|---|---:|---:|---:|
| cycles | 7082M | 5435M | **1.303**（~0.767） |
| insn | 31666M | 25867M | **1.224** |
| `l1i_cache_refill` | **139.8M** | **6.5M** | **21.6×** |
| FE stall | 614M | 275M | **2.23×** |
| BE/cyc | 更低 | 更高 | **不是** L1D 墙 |

超额 +1647M 拆开（报告原算术，**不是** miss×12）：

| 摊 | M | 读 |
|---|---:|---|
| 按 q IPC 消化多出来的 insn | **1218** | **形税 / 真多干活**（本墙吃不到） |
| 余下效率税 | **429** | cyc 比 insn 多的那截 |
| 其中多出来的 FE stall | **339** | 与效率税同量级；**本墙的周期上限** |
| 多出来的 L1I refill | **+133M 次** | 数量级对得上「前端为何多停」 |

报告原文禁止把 133M×12 加到 1647 上（与 FE stall 重叠）。

**L-1.5**（只聚不瘦，已拒）：

| | 对照 | L-1.5 | |
|---|---:|---:|---|
| EB L1I refill | 139.7M | 128.9M | **−7.7% / −10.8M 次** |
| EB cycles | 7086.5M | 7065.4M | **0.997（−0.3%）** |
| 相对 q | | 仍 ~20× | 收的是散布，不是 CASE 单体 |
| 三 pad geomean | | **−0.2~0.3% 同号负** | mandreel −1.2~1.5%；EB 分数 ≈0 |

**守恒位移（超额，不是本墙独有）：**

| 图 | z/q | ~score | 超出 |
|---|---:|---:|---:|
| R14 wave2 | 1.402 | 0.713 | +2192M |
| POSTS2 | 1.299 | 0.770 | +1592M |
| W25 `40e83160` | 1.264 | **0.791** | **+1413M** |
| GETFIELD-MIX `9deb9f45` FW | 1.232 | 0.805（3574/4442） | +1242M |
| **官方（用户）** | ≈1.253 | **0.7984** | zoo 口径（FW 与三 pad 之间） |

W25 细桶（闭合 +1413）：①′ ctor +342 · ⑤ 窄 +301 · ⑧ other +319 · ③ GC +213 · ⑦ RC +204 · ④′ Fast +156 · ② +110。  
POSTS2 原判：**⑤ 宽口径仍是超额的一半**（+730 / 46%）。这就是「形税一半」——分派地板 + 拆开的具名 handler，**不是** L1I 次数本身。容量墙是其中 **效率税 / FE** 那一截（当时 429M 里的 339M），叠在形税的 insn 体积上。

**近审把「再砍 handler」从本墙划出去：**

- GETFIELD-MIX：`op_get_field` 549 vs q CASE 542，每发 8.8 vs 10.0 cyc，**形对位**。555M = n×单价。
- CTOR-WALK：258M 是 poll/proto/窗/进体，**不是空巢**。
- GEO-RECOVER：w39 −0.9×3 是 IPC，墓碑收回滑址 **cyc 不回来**。

### 1.3 和「一半形税 / RC·GC 固有」怎么拼

```
官方 0.7984
├── 形税 ≈ 一半超额
│     insn 1.15–1.22×（GETFIELD 1.152 / STALL 1.224 / W25 1.199）
│     ⑤ 窄分派 + 具名 opcode（get_field/return/instanceof…）
│     HASINST-DIRECT 已啃 instanceof 族 insn；get_field 已证对位
├── 容量墙 ≈ 效率税
│     L1I 22× → 多出来的 FE stall（STALL 339M 上限）
│     布局已证：聚了装不下
└── RC/GC 固有
      ③ destroy+trace +213（W25）；⑦ destroyFromHeader +204
      禁区 / drain 已齐；TRACE-ORDINARY 吃的是 TS 形，EB 双份 trace 仍在
```

三块**有重叠**：同一份 `op_get_field` 既付形税（真指令）也付容量墙（叶散、换线）。裁的时候按 **可动杠杆** 分，不要把 555M 整段算进本墙。

### 1.4 谁不是这个墙（防串案）

| 案 | 墙种 | 证据 |
|---|---|---|
| zlib / mandreel / box2d / gbemu | **compute / FE-B2** | L1I 绝对次数可忽略（gbemu 1.9M vs EB 140M）；br/insn 密 |
| TS | **13.3× 姊妹、浅一档** | L-1.5 zoo TS 1.000；过线不押在墙上 |
| P6 `{}`+3 | **shape 扩容单价** | adopt/reloc；刀 B REJECT（跨 slab 类） |
| pdfjs concat | **String 就地追加** | H2 禁字段；EB 不是付款面 |
| splay ⑦ | **RC teardown 固有** | 与本墙同「禁区」族，机制不同 |

---

## ② 「完整实现」要动什么；H2 / P6 边界

### 2.1 完整实现的定义（可验收）

工作集口径（EB 可达，不是 zoo-15 并集）：

> handler 岛 + Boyer 热环实际取到的助手，**合计 ≤ 192KB（3×L1I）**，目标 **≤ 128KB（2×）**。  
> 验成：EB FW `l1i_cache_refill` z/q **≤ 4×**（现 21.6×），且多出来的 FE stall **≤ +100M**（现 +339M）。

HOTCORE 算术（不重做）：热核 414 + handler 174 = **589KB ≈ 9.2×L1I**。  
top-20 减半 → 300KB 仍 4.7×；**整段删除** top-20 才擦 3×，且 handler 岛还在。  
Zig 可刮脂肪（comptime 副本 + mux）天花板 **50–70KB** → 仍 ~5×。  
现件 handler 岛已涨到 **185.7KB = 2.9×L1I 单岛**。qjs 把 opcode **熔进** 38.5KB 的 CallInternal。

所以完整实现 **必须同时** 动：

| 面 | 要动 | 不要动 |
|---|---|---|
| **数据结构** | 解释器工作集的**驻留集合**：哪些函数进 `.text.zjs.op_handlers` / 未来的 EB-core 段；comptime 单态份数；`traceChildren` 双份合成一份 | String 头布局；shape FAM / `prop_size` / hash bits；`JSValue` 表示 |
| **生命周期** | 「Boyer 一圈里哪些代码保持 I-cache 热」——regexp/dtoa/math mux 对 EB 应冷；GC mark/destroy 若必须热，体必须短到能和 handler 共 2–3 个 L1I | 对象/shape 的建毁语义；RC 协议；`compact_properties`（那是 splay X-84） |
| **几何** | 段、对齐、musttail 岛**内容密度**（每叶多少字节、冷臂是否还占 64 对齐槽） | 再垫墓碑 / 再聚 183 函数进 `.text.zjs.hot`（L-1.5 已拒） |

qjs 对位几何：一个 `JS_CallInternal` + 中口径助手 **47KB**。完整实现的终态是 **接近这个密度**，不是接近这个源码结构（不必退回巨型 switch，但必须退回「热环 ≤3 个 L1I」）。

### 2.2 H2 禁区（String capacity 字段）

| | |
|---|---|
| 原文 | CONCAT：*`⛔严禁给 String 加 capacity 字段=H2 禁区原样`*。qjs 也无此字段，靠 `malloc_usable_size`。 |
| 本墙关系 | **零。** String 追加不是 EB 热环，L1I 22× 的付款人里没有 concat。 |
| 完整实现若踩 | 给 String（或 Object/Shape）加 capacity **只会长工作集**，与缩码目标相反。 |
| 允许的相邻 | 分配器 `usable_size` 查询本身已裁定不违 H2——但那是 pdfjs concat / 已死的 P6-B，**不要**为 EB 再做一条。 |

### 2.3 P6 区（adopt / reloc 单价勿单开）

| | |
|---|---|
| 原文 | P6-B REJECT：slab 精确类 2→4 永跨类，就地臂 0 命中。宪法：*`qjs 靠 malloc 松弛的就地优化在 zjs slab 生态一律不可移植`*。改判口是 shape **建/毁单位成本**（+86/对），挂队，**不是**本墙。 |
| W25 | `adoptShape` 83 / `createObjectRoot` 74 / 五件对 q +172。乐观再刮 20–40M，**盖不住 +1413**。 |
| 本墙关系 | adopt 2.2KB、shape 域整段 4.6KB，**不是** 22× 的体积。GETFIELD 热臂甚至不走 put/扩容。 |
| 完整实现若踩 | 为「容量」去改 `relocateShape` / 就地 realloc = 重开已封存的 P6-B，且 **L1I 次数不会掉**。 |
| 允许的相邻 | 若以后单开 shape 生命周期（清 props / 毁信 header），验尺走 P6 微基准 + splay/EB **insn 不回退**，**不要**把 EB L1I 22× 写进那把刀的成功标准。 |

### 2.4 和已合工事的边界

| 已合 / 已拒 | 完整实现 |
|---|---|
| **L-1** handler 岛 | **保留。** 完整实现瘦的是岛**内容**，不拆段。 |
| **L-1.5** 183 聚簇 | **不复活。** 聚了 426KB ≫ 64KB。 |
| **L-2** 频次序 | **仍闭。** |
| musttail / `align(64)` | 完整实现若要密度，必须 **减少占槽的冷叶**（或接受冷叶出岛），不能靠再 `align`。 |
| TRACE-ORDINARY | 普通对象 mark 已瘦形；**现件仍两份** `traceChildren` 30.8KB。塌双份是 S1 卫生，不是完整实现。 |
| F / HASINST / GETFIELD | 形税刀。完整实现 **禁止** 再把 555/352 当容量钉。 |

---

## ③ 分段落地方案 + 验尺 + 风险

### S0 — 本材料（已做）

定名、边界、预期。**无码。** 用户裁 S3-A / S3-B。

### S1 — 卫生（可做，**声明吃不满墙**）

| | |
|---|---|
| 做什么 | 塌 `traceChildren` 双份（−15.6KB 岛外）；`MemoryAccount.free/alloc` 28/13 份合一；EB 用不到的 regexp/math mux **不要**再 stamp 进任何热段（现已无 `.hot`，守住即可）。 |
| 不动 | handler 体、adopt/reloc、String、RC 语义、L-1.5。 |
| 验尺 | `nm -S` 双份消失；EB FW `l1i_cache_refill` 与 cyc（CPU **15**，ABBA n≥4）；splay/TS insn 不回退。**成功 ≠ 分数 +1pp。** |
| 预期 | L1I −5–10%（L-1.5 量级或更小），cyc **0–20M**，官方 **0.7984 → 0.798–0.802**。 |
| 风险 | `noinline` 把叶子赶到更远页 = L-1.5 反面，L1I 可能涨。必须前后 `nm`+refill 对照。 |
| 过线？ | **否。** HOTCORE：刮完仍 5×L1I。 |

### S2 — 工作集裁员（中，仍不进 ×3）

| | |
|---|---|
| 做什么 | 把 Boyer **冷** 的大函数从「容易和热环页交错」的邻域清走（regexp 88KB 本就不是 EB 主集，但勿再被 union stamp）；瘦 `constructValue` / `setupSimpleInlineEntry` 多份（14 份 14KB）——只减 **副本**，不改 TAKE 语义。 |
| 不动 | P6 adopt/reloc 体；`initial_prop_size`；handler 热叶语义。 |
| 验尺 | 静态：EB 取样 IP 的函数合计 KB（`perf record l1i_cache_refill` 符号覆盖，CPU 15）。动态：refill z/q、FE stall。哨：pdfjs/zlib/splay。 |
| 预期 | 热核观感 → ~300KB；L1I 或到 **12–16×**；分数 **≤0.81**。 |
| 风险 | 搬函数 = 扰动偶然局部性（L-1.5 已付过 −0.2% geomean）。union 名单一动，TS/pdfjs 可能回吐。 |
| 过线？ | **否。** 差 108KB 才到 ×3，且 handler 186KB 原封。 |

### S3-A — 完整实现：密度战役（唯一能推倒墙）

**先决：用户批「这是新战役，不是 wave 里的一把 FAITHFUL」。**

终态：EB 热环驻留 **≤192KB**（理想 128KB）= 瘦后的 handler 核 + 共享尾 + 短 GC/RC 叶。

| 段 | 内容 | 验尺 |
|---|---|---|
| A1 冷叶出岛 | 64 对齐下 EB 0% 的 opcode 叶迁出 `op_handlers`，岛只留 Boyer 热 op。现岛 186KB，EB 热 op 大约十几二十个，有望先打到 **<64–80KB 岛** | `nm` 岛长；musttail flagged=0；**pdfjs/zlib 不得 −1%**（它们吃的叶可能被迁出） |
| A2 共享尾 | dup/free/cont/dispatch 收成岛内共享 stub，避免每叶一份序言（get_field 已是瘦叶；`op_return` 0x2720 是反例） | 热叶平均字节 ↓；return 独占不涨 |
| A3 助手密度 | `destroyRuntimeCycles` / `traceChildren` / `destroyFromHeader` 以 **体积** 为第一约束（一份、短路径），语义对齐 qjs `mark_children`/`free_gc_object` 已有的 TRACE 方向 | 三符号合计 KB；③⑦ **insn** 不回退 |
| A4 可选终形 | 若 A1–A3 仍 >192KB：把剩余热 op **熔回少数大函数**（接近 CallInternal）。这与「每 op 一叶、prologue-free」战役冲突，必须单独立宪 | refill ≤4×；FE stall 差 ≤100M |

**A1–A3 仍可能进不了 ×2**（HOTCORE：真语义体 164KB + GC/call 真体）。A4 才是「另一门语言实现」。

风险（S3-A 专属）：

1. **拆 L-1 纪律** → pdfjs 真收过的确定性/I-cache 回吐。  
2. **熔回大函数** → 帧/spill 回到 S2 挖空之前（ctor 0x270 前车）。  
3. **GC 体按体积砍** → 踩 ⑦ 禁区，splay 双模态/正确性。  
4. **工期 XL**，和 w42 组包、形税残余并行必抢同一几何。  
5. 分数路径：墙推倒也只吃效率税，**insn 1.15× 仍在**。

### S3-B — 关墙（建议默认）

写进 LAYOUT-CLOSED 续页：容量墙 **architectural**；完整实现 = S3-A 战役，不在 FAITHFUL 队列。  
EB 过线杠杆改走：形税残余（已所剩无几：get_field 对位、instanceof 已直）+ 用户若批的 Entry 几何 / 禁区外 GC 微刮。  
**不立项、不平行刀、不把 22× 再当 handler-section 缺口。**

### S4 — 明确不做

- 给 String/Object/Shape **加 capacity 字段**（H2）。  
- 重开 P6-B 就地 realloc / 单开 adopt/reloc 当本墙刀。  
- 复活 L-1.5 / L-2 / eq 墓碑垫岛（GEO 已证 cyc 不回）。  
- 把 `op_get_field` 555 / `op_return` 352 / `op_call_constructor` 258 整段记进本墙回收。  
- 用一次 L1I 复测代替裁决（数字不会自己变成刀形）。

---

## ④ 诚实预期：修完 EB 到哪

引用守恒，不发明新测量。

### 4.1 本墙单独能吃的上限

STALL：效率税 429M，其中 FE +339M 是本墙周期上限（当时超额 1647M 的 **21%**）。  
按比例套到较近 FW（GETFIELD +1242M）：**~0.21 × 1242 ≈ 260M cyc**。  
官方 0.7984 ≈ 1/1.253；若 zoo 与 FW 同比例，完整推倒墙大约：

| 假设 | z/q | ~score | 相对 0.7984 |
|---|---:|---:|---|
| 现状（官方） | 1.253 | **0.7984** | — |
| S1 卫生 | 1.250–1.253 | **0.798–0.800** | +0.0–0.2pp |
| S2 裁员 | 1.23–1.25 | **0.80–0.81** | +0.2–1.2pp |
| S3-A 完整（吃满 ~260–339M） | **1.18–1.20** | **0.83–0.85** | **+3–5pp** |
| insn 体积不变的硬顶（GETFIELD 1.152，IPC 追平） | 1.152 | **0.87** | 还要再吃形税才摸得到 |
| 1.0 | 1.00 | 1.00 | **本墙做不到** |

L-1.5 实证给 S1/S2 打了折：L1I 真降 8%，分数真的是 0。不要用 refill 线性外推 pp。

### 4.2 三块各自的顶（过线账）

| 块 | 乐观顶 | 依据 | 到 1.0？ |
|---|---|---|---|
| **容量墙（本文）** | **+3–5pp**（S3-A 满打满算） | FE 339M / 比例 260M | 否 |
| **形税** | 现货已薄。get_field 对位；HASINST 已收 DINM；⑤ 窄 +301 是地板 | W25 / GETFIELD / HASINST | 否（地板还在） |
| **RC/GC 固有** | W25：GC 可吃 ≈0；shape 微刮 20–40M | 禁区 + drain 已齐 | 否 |
| **三块同时理想** | 0.83–0.87 | 墙满 + 形税再刮一点 | **仍不是 1.0** |

W25 / POSTS2 原判仍成立：*过线不能靠再立一把 FAITHFUL 收编 EB 命名段。*  
0.7984 → 1.0 还差 **~0.20 score ≈ +25% 吞吐**。insn 1.15× 单独就挡住 ~0.13；⑦+③ 低 IPC 井再挡一截。容量墙即使完整落地，也只是把「前端空转」从三分法里划掉。

### 4.3 给用户的三选一

1. **关墙（S3-B）** — 承认 0.80 附近的 EB 含一截 I-cache 结构税；把人力留在别的落后项或禁区外微刮。  
2. **批密度战役（S3-A）** — 独立 XL，验收是 refill≤4× 与 −3~5pp，**合同写明不到 1.0**。  
3. **只批 S1 卫生** — 塌双份 / 分配器单态，当 i-cache 清洁，**禁止**写进「EB 过线计划」。

本材料推荐 **1**，除非用户要买 2 的预算。

---

## 5. 不要做（本单收口）

- 不要把「容量墙」理解成 String/对象/shape 的 heap capacity。  
- 不要为本文去 CPU15 复测 L1I（22× 与 −7.7%/−0.3% 已够裁）。  
- 不要在 w42 组包里夹 S3-A。  
- 不要重开 L-1.5、P6-B、H2 字段、GEO 墓碑。  
- 不要改 src。

未碰 test262.conf / reports / tools/perf。未合 main。
