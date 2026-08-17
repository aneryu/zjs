# IC-SPIKE — 属性访问 inline-cache（只设计）

日期：2026-08-17。**只设计，不实施，无 commit，无 FW 刀，不占 254/255。**  
递用户过审。数字非裁决。生产形：`main@9deb9f45` 族 RF，`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,…`。

承接：通道 #3 v1 / 肥窗 **REJECT-ARCHIVE**（`CH3-P0-CENSUS` ACCEPTED + `CH3-FAT-SCOPING` 不可达）。本机制是下一档 **通用大额对冲**，不是 CH3 的补丁。

对照（不重开）：

| 档案 | 结论 | 本 spike |
|---|---|---|
| 退役 IC（`docs/perf/inline-cache-design.md`） | 已删，与 qjs「无 IC」对齐；`cached*` 恒 miss | **不复辟旧 `ic.zig`。** 本文件按四条件重开立项 |
| F / `TS-GET-FIELD` | 热臂 **47 insn / 10 跳**，短于 qjs CASE **51 / 8**；TS 53.58M 发占用 21.7%，不是超额 | IC 必须比 47 **显著更短**才有奖金 |
| `BOX2D-F-RESID` | `op_get_field` **−61.8M cyc** 信用；残差在 BIN-MUL | box2d 不是 IC 主尺，是「别把信用打穿」的哨 |
| DT-SPIKE | pc 键 sidecar ×8 出 L2，hop 再短周期≈0 | IC 表是 **每位点** 不是每字节；禁 DT 形 sidecar |
| EB L1I 墙 | 岛 185.7KB vs qjs CASE 38.5KB，refill **21.6×** | IC **不得胀岛**；命中臂原地替换，walk 出岛 |
| 融合 leftover / L-1 | 只改首字节，B 可 dispatch；墓碑钉址 | 见 §5 |
| `constructor-allocation-profile` | FB hot 尾画像，ledger 已挂名 | 同族「FB 侧缓存」，不是 load IC |
| PERF-MECHANISM-LEDGER L63 | 「解释器 store IC 等候选将来按同一四条件申报」 | **本文即该条** |

pT 普查已落 `/tmp/ic-site-census/`（`ZJS_IC_CENSUS`，CPU 8，15/15 rc=0）。§0.1 / §6 引用其表。口径：位点 = `(op, atom, fn, pc)`，`n_shapes==1` 为 mono，2–4 为 low，>4 或溢出为 mega。未分 own/proto（TS/box2d 热臂 annotate 原型 0%，那两案可把 mono≈可学）。

---

## 0. 一句话（请裁）

在 **不改 4 参 ABI、不占 254/255、不胀岛、不克隆 `get_field` 热 walk、不跳过 getter/proxy/exotic/语义** 的前提下，用 emit 期写入的 **位点 id + FunctionBytecode 侧 shape 槽表**，把「每次哈希查找」换成「shape 指针 + 已学 Property 字一比，命中则直载槽」。

v1 只收 **own 数据属性** 的 `get_field`（随后 `put_field` 覆盖写、`get_field2`）。原型链 / getter / proxy / exotic / 缺席 **永不填表**，miss 走今日 walk（出岛、表跳，防 LLVM 折回）。

**机制主推：字节码内嵌 `u16 site_id`（`get_field` 5→7 字节）+ FB 侧 32B 槽数组。**  
位点表（pc 哈希 sidecar）命中路径多一载且无稠密下标。quickening 要新 opcode，254/255 只剩两槽，**排除**。

诚实：今日 F 已短于 qjs。IC 的奖金不在「再对齐 CASE」，在 **越过查找**——这是 qjs 没有、四条件允许的机制。若 P0 显示位点不稳（mono 覆盖不够）或 P1 命中臂做不到 ≤28 insn，**整通道 REJECT-ARCHIVE**，与 CH3 同判。

建议裁：**P0 主尺已过（TS/box2d/EB），先批 P1 金丝雀。** 并集 50% 不是矿不稳，是 richards 稳定 3-shape + raytrace mega——那是 P4/哨，不是杀 P1 的理由。

---

## 0.1 pT 位点表（2026-08-17，非裁决）

`get_field` 单列（P1 范围）：

| 案 | fires | mono | low 2–4 | mega | 读 |
|---|---:|---:|---:|---:|---|
| **typescript** | 52.41M | **80.4%** | 4.3% | 15.4% | 主尺过 70% |
| **box2d** | 30.69M | **94.1%** | 5.3% | 0.6% | 哨过 70% |
| **earley-boyer** | 26.43M | **100%** | 0 | 0 | L1I 哨：几乎永不 mega |
| gbemu / pdfjs | 30.0 / 1.62M | 88.8 / 89.5% | | | 同形 |
| **richards** | **75.10M** | **0.0%** | **100%**（热位点恰 3 shape） | 0 | 并集第一大付款；v1 吃不到；P4 矿 |
| **raytrace** | 26.48M | 28.4% | 20.9% | **50.7%** | 四资产；mega 不得比今日慢 |
| deltablue | 54.91M | 33.4% | 38.7% | 27.9% | 中 |
| crypto | 10.82M | 36.9% | 63.1% | 0 | 四资产，low |
| splay | 3.11M | 12.0% | 88.0% | 0 | 不承诺 |
| zlib / mandreel / navier | ≤285 | 高 | | | 位点近 0 |
| **zoo Σ** | 311.60M / 23,816 位点 | **50.0%** | 38.1% | 11.9% | 被 richards+raytrace+DB 拉低 |

`get+put` 并集 390.0M、34,848 位点、mono 48.9%（pT `analyze.txt`）。  
TS `get_field` 12,365 位点、每函数 max 1,122 < 65534。全 zoo 行数 ×32B ≈ **1.32MB** < 2MB。  
mono fires 155.8M × 8 cyc = **1.25G** 纸面 ≫ 30M。

`put_field`：TS 13.61M / 66.3% mono；box2d 4.09M / 81.0%；raytrace put **0% mono / 热位点 17-shape mega**（`initialize` 族）。P2 不要拿 raytrace put 当赢面。

---

## 1. ① 四条件申报文

对照 `PERF-MECHANISM-LEDGER.md` 条目 #2（opcode-fusion）格式。拟名：`property-load-ic`。

### 1. 通用

- 先例：JSC `get_by_id` IC / V8 `LdaNamedProperty` feedback / SM PIC。qjs **没有** 对应物——本条是「QuickJS 没有、按通用性原则允许」的正例（ledger 封面句）。
- **全位点、全 shape。** 任何函数里任何 `get_field`/`put_field`/`get_field2` 都是一个位点；学习键是 **接收者当前 `shape*`**（+ 学得的 `Property` 8 字节字），不认对象身份、构造器名、字段名白名单、G 形、`initialize`、benchmark。
- 选名单：**zoo 并集** 的位点动态权重只用于 **分期**（先做哪条 op），不是「只给 TS 的某几个 pc 开 IC」。实现一旦落地，**所有** 位点走同一状态机。禁「TS `checker.ts:1234` 特判」。
- 失败是 miss（走今日 walk），不是悬崖。megamorphic 位点冻结为永 walk，仍正确。
- 必须仍成立：

| 位点 | 应收 / 学习？ |
|---|---|
| 任意函数 `obj.foo`，own 数据，单 shape | 是，学 |
| 同上，两个稳定 shape（poly） | v1 **不学第二份**（升 mega→永 walk）；v2 才允许 2 槽 |
| 同一位点 5+ shape | mega，永 walk |
| getter / Proxy / exotic / typed 特殊原子 | **不学**；每次 walk |
| 属性在原型上 | v1 **不学**（own only） |
| 只在某个 benchmark 里出现的原子名 | 是（原子不是分类器） |

### 2. 用户码必执行

| 层 | 用户语义？ | 本机制 |
|---|---|---|
| 从对象槽读出 **当前** 值、dup、释放接收者 | 是 | **每次命中都做**。禁止缓存 JSValue 本身 |
| getter 调用 / Proxy trap / exotic `[[Get]]` | 是 | v1 不进 IC；走今日 resolver |
| 哈希桶 + atom 环 + proto walk | **查找**，非语义 | 命中时用 guard 代替。guard 失败必须跑完整查找 |
| 解释器 `cont` 间接跳 | 否 | 不动（不是 CH3） |

已删 bypass 的罪：跳过 ctor **体**。本机制若缓存「上次读到的值」、或把 getter 当成数据槽，就重犯。合同句：

> **只免查找，不免语义。Guard 必验。**

Guard 最小集（命中路径上 **每一次** 都跑，不准「学过就信」）：

1. 接收者是对象（与今日 `isObject` 同位）；
2. `obj.shape_ref == ic.shape`；
3. `shape.props[ic.slot]` 的 8 字节 `Property` 字 == 学得字（含 `flags`+`atom_id`+`hash_next`）。delete / 改 accessor / 换原子 / 槽复用 → 字变 → miss。

`deleted_prop_count` 被 (3) 覆盖（delete 清/改该字）。Shape 头是钉死的 **56B qjs `JSShape`**，**禁止**加 generation 字段。

### 3. 可观察等价

| 面 | 协议 |
|---|---|
| **getter** | 学点仅在 `Kind.data`。flags 变 GETSET → Property 字变 → miss → resolver 调 getter。禁止把 getter 对象当值缓存 |
| **Proxy** | 今日 fast path 不命中，不填表。之后仍走 trap |
| **exotic / typed / mapped args** | 同：只有 `qjsGetFieldFastSlotOrAbsent` **成功且 own** 才 `learn` |
| **原型链变更** | v1 不缓存原型槽。own 属性：proto 是 shape 身份的一部分，换 proto = 新 `shape*` → miss。对象上后加 own = 新 shape → miss 再学 |
| **delete** | 同位 in-place 删不换 `shape*`（`object-shape-design`：`deleted_prop_count++`、不立即压槽）。靠 Property 字不等。学「缺席」**禁止**（原型上后补会假命中 `undefined`） |
| **define / 改 writable / 数据→访问器** | Property 字变 → miss |
| **put 扩容 / transition** | v1 put 只覆盖已有 own 数据槽；`shape*` 变则 miss，不在 v1 学 transition |
| **`frame.pc` / 栈迹 / L0 stop** | 不改分派；`get_field` 仍从自己的 pc 进。size 5→7 后 `sizeOf` / pc2line / leftover 跳入按新宽度 |
| **poll** | `get_field` 本就不 poll（与 qjs GET_FIELD_INLINE 同位） |
| **融合 leftover** | leftover B 仍是完整 `get_field`（现含 site_id）。`get_loc0_field` 仍 musttail `op_get_field`，读 leftover 的 atom+id |
| **test262 + difftest** | 全量。另加：delete 后同位点、defineProperty 改 getter、Proxy、原型替换、OOM 在 learn 分配 |

### 4. zoo 验收

- 3-pad lineage；**主尺 cyc**（insn 降、cyc 平 = IPC 税，**杀**，fusion-END / 8 参 / limit-slim 同判）。
- 四资产（crypto / raytrace / navier / code-load）不得同号负。
- **主判读：typescript**（`get_field` 53.58M / 独占 21.7% / insn 洞 +7.40G 不在热臂，但占用最大）。**box2d 哨**：F-GET 信用 −61.8M 不得打穿（cyc 不得同号变差超噪声带）。
- **EB 哨**：L1I refill 不得明显升（墙在取指；IC 若胀岛或表抖动会在这里先炸）。
- zlib / mandreel：字段位点少，作岛/布局回归哨，不作赢面。
- 单 pad 在 DB 0.997–1.005 噪声带内不单独报功。
- **禁** `prop_read_mono_loop` / A_direct 当过线（limit-slim 学案；退役 IC 文档点名过这个夹具）。

---

## 2. ② 机制选型

### 2.1 三候选

| 形 | 编码 | 命中多付 | 新槽 | 失效 | 与融合 / 序列化 |
|---|---|---|---|---|---|
| **A. 位点表（pc 键 sidecar）** | 字节码不动；`hash(fb, pc)` 或 `u16[byte_code.len]` | 哈希或 **每字节 2B** 的下标载 | 0 | 表在 FB 侧，可清 | 不改 `sizeOf`。稠密下标 = DT-A 同轴内存（mandreel 码流 MB 级 ×2）。哈希 = 命中多一次不可预测载 |
| **B. quickening** | 改首字节 → `get_field_mono` / `_poly` / `_mega` | 0（换 handler） | **每态 1** | 改回通用 op 或改表 | **254/255 只剩 2。** 三态 × `get_field`/`put_field`/`get_field2` 就要 9 槽。排除 |
| **C. 字节码内嵌槽（主推）** | emit 写 `u16 site_id`；状态在 `FB.ic[site_id]` | 从 `pc+5` 读 id（已有 pc）+ 基址一载 | 0 | 写槽 / 升 mega；不改 opcode | leftover B 变宽，`sizeOf` 更新。FB 可序列化：id 是立即数，**状态不进产物**（realize / 首次入函分配空表） |

**主推 C。** B 物理排除。A 的诚实命中路径 **长于** C（多一次 pc→槽映射），和「必须显著短于 47」打架；稠密 sidecar 重演 DT 内存反噬。

C 的 site_id 是 **下标**，不是缓存的 shape。运行时只写 FB 侧数组。与融合「只改首字节、操作数原样」相容：atom 仍在 `pc+1..5`，id 在 `pc+5..7`。

### 2.2 存储（C 的落地规格）

**字节码**

- `get_field` / `get_field2` / `get_field_opt_chain` / 以它们为体的 fused（`get_field_field2`、`get_field2_call_method`）`size` **5→7**。
- 格式：`[op][atom u32 le][site_id u16 le]`。
- `put_field` 同期或 P2 同样 +2。
- 位点 id 在 finalize / 融合之后、按函数内出现序从 0 编号。`0xffff` = 不参与（超过 65534 个位点的函数整函数永 walk——应不存在；P0 报 max/fn）。
- fused A（`get_loc0_field` 等）**不加** id：它们 musttail 进 leftover 的 `get_field`，id 在 B 上。

**FB 侧表**

- `FunctionBytecode` **96B 核心头不动**（QCP-1B 学案）。
- `FunctionBytecodeHotExtension` 仍 64B。`_ctor_alloc_pad[48]` **已经占用**：
  - +0 `CallerState*`（small-function-inlining）
  - +8 borrowed realm
  - +16 apply-forward memo
- IC 指针放在 pad **+24**（8B）+ `u32 count`（+32）。剩 12B 不动。禁止挤 `ctor_alloc` / CallerState。
- 表本身：**单独分配**、FB mark 时追溯每槽 `shape*`。不把表嵌进 FAM（避整 FB 重分配、避 0.16 布局抽奖）。
- 槽 32B（一行一 cache line 半；对齐 16）：

```
shape*:     8   // null = uninit 或 mega
prop_word:  8   // 学得的 shape.Property 位型
slot:       u16
state:      u8  // empty / mono / mega   （v1 无 poly）
fires:      u8  // 饱和计数，只给 P0/画像；热臂可不读
_pad:       12
```

v1 热臂 **不读 `fires`**。mega 时 `shape* = null`，probe 一次 cmp 失败就表跳 walk。

**`Vm` 热字段（可选，P1 微核决定）**

- `enterEntry` 已有 FB。可把 `ic_base` 打进 `Vm` 一个指针，免每 hop `vm→fb→hot→ptr`。
- 这是 4 参 ABI **内部** 的 vm 字段，不加参。若 LLVM 因此给 handler 摊帧 → **删这个字段**，改从 fb 走（多 1–2 载，计入 28 insn 预算）。

### 2.3 多态度数

| 态 | v1 | 行为 |
|---|---|---|
| empty | 有 | 第一次 own 数据命中 → 学，变 mono |
| **mono** | 有 | `shape*`+`prop_word` 等 → 直载槽。不等 → 若仍是 own 数据且 shape 不同 → **直接 mega**（v1 不升 poly） |
| poly 2–4 | **无** | 多一份比较就是多一份岛内代码。P0 若显示大量「恰 2 shape」再开 P2 |
| **mega** | 有 | 永 walk，不再写槽。防止失效风暴里反复学 |

v1 把「第二个稳定 shape」也打成 mega，是 **故意保守**：保命中臂最短。P0 会报 1-shape / 2-shape / ≥3 的 fire 加权。若 2-shape 占主奖金，P2 再加 **一份** 第二槽（仍在 FB 表，不在岛里循环展开成 4 路）。

### 2.4 失效（不广播）

禁止「一个 delete 扫全世界 IC」。

| 事件 | 如何看见 |
|---|---|
| 该对象 transition（加属性 / 换 proto） | 新 `shape*`，cmp 失败 |
| 同位 delete / 改 flags | `prop_word` 失败 |
| 其它对象、其它 shape | 不相干，不碰 |
| mega | 不再写，无风暴 |
| GC 回收无人引用的 shape | 见 §7：FB 强根会钉住学过的 shape；mega 或 FB 死时放下 |

没有 shape 头上的 gen（56B 钉死）。没有全局 IC 链表。

---

## 3. ③ 命中路径预算

### 3.1 今日（必须短过它）

`TS-GET-FIELD`，own 首探、数据、RC>1，落点 → 下一条用户 `br`（**含 `cont`**）：

| | zjs `op_get_field` | qjs `label_OP_get_field` ⊂ CASE |
|---|---|---|
| insn | **47** | **51** |
| 跳 | **10**（含从未采取的 F1/F2/F3） | **8** |
| 帧 | 无 | CASE 父帧 |
| 生产 `nm` 体长 | **0x340**（`/home/aneryu/zjs/zig-out/bin/zjs`） | ⊂ 0x9654 |

再削 F1–F3 只是 −3 跳，填不满 TS +7.40G insn。IC 的活在 **砍掉哈希+atom 环**（今日热臂里那截与 qjs 同构的查找），不是再抠 F 守卫。

### 3.2 目标形（mono own 数据，RC>1，无 destroy）

同一口径：handler 入场 → `cont` 的 `br`。

```
; x0=pc  x1=sp  x2=var_buf  x3=vm
ldp    payload, tag, [sp, #-16]     ; 接收者
cmn    tag, #1
b.ne   miss_tbl                     ; 非对象
ldr    shape, [obj, #shape_ref]
ldr    icb, [vm, #ic_base]          ; 或 fb 两载，计入预算
ldrh   id, [pc, #5]
add    ic, icb, id lsl #5           ; 32B 槽
ldr    cshape, [ic]
cmp    shape, cshape
b.ne   miss_tbl
ldr    cprop, [ic, #8]
ldr    lprop, [shape, #56 + slot*8] ; FAM 常数偏 + 槽
cmp    lprop, cprop
b.ne   miss_tbl
; slot 可与 cprop 同槽取出，或 ic.slot
ldr    vals, [obj, #prop_values]
ldp    vlo, vhi, [vals, slot lsl #4]
; dup（rc 值）+ 覆盖接收者 + 接收者 rc>1 释放
; cont(pc+7)
```

`miss_tbl` = `br property_tail_tbl[.get_field_walk]`（运行时下标，**禁止** 同文件 `always_tail` 直跳 walk——会折回，见 §5）。

### 3.3 数字门

| | 目标 | 硬顶（超过则 P1 杀） |
|---|---|---|
| 命中路径 insn（含 `cont`） | **22** | **28** |
| 相对今日 47 | −25 | 至少 **−19**（≤28） |
| 跳（含未采取） | **4**（对象 / shape / prop_word / 值-rc） | **6** |
| `bl` | **0** | **0** |
| 帧 | 无 `sub sp` | 无 |
| 体长 `nm op_get_field` | ≤0x80 活代码 + 尾部墓碑 | **≤0x340**（不准变大） |

28 仍比 qjs 51 短 23，比今日 47 短 19。再长就不是「显著」，是「查找上再挂一个 IC 探针」——DT / leftover 梯已证这种加法 insn 赢 cyc 不赢。

P1 微核（纯 mono 位点循环）必须同时：insn/hop 过门 **且** cyc/hop 3-pad 同号降。只 insn = 杀。

纸面奖金（非门、待 P0 加权）：

| 假设 | 算法 | 量级 |
|---|---|---|
| TS 85% mono × 10 cyc | 53.58M × 0.85 × 10 | **~455M cyc**（TS 洞 +1712M 的 ~27%） |
| TS 85% × 25 insn | 53.58M × 0.85 × 25 | **~1.14G insn**（+7.40G 的 ~15%） |
| box2d 90% × 10 cyc | 31.43M × 0.90 × 10 | ~283M cyc（**超过** 现残差 +43M——若数字真，box2d 会从「微负」翻成大胜；P1 必须 3-pad 真测，不准用这个纸面报功） |

10 cyc/命中是「哈希链 L1D 命中」的保守中位。若 IC 表本身打出 L1D（§7），真实值会小得多，甚至为负。

---

## 4. ④ 工作集纪律（EB L1I）

**教训：** 只重排不缩体积，L1I −7.7%、cyc −0.3%。墙是 **同时热的符号体积**，不是某条 malloc。IC 新加热叶 = 加压。

| 放哪 | 谁 | 为什么 |
|---|---|---|
| **岛内、原 `op_get_field` 符号** | mono 命中臂（§3.2） | 不新增符号。活代码变短。尾部 `.space` 保持 `nm`≤0x340，**`cont` 之后的墓碑不进 I$ 工作集**（与今日 primitive 臂 tombstone 同构） |
| **岛尾 / `property_tail_tbl`** | 完整 walk（今日热体搬走）+ learn + mega | 表跳，LLVM 折不回。第一次 / miss / mega 走这里 |
| **禁止进岛** | poly 展开、learn 慢路径、getter/proxy、profiled 256 项 | fusion-END：禁止 256 个 `profiledHandler` 进岛 |
| **`op_if_false8` / 其它钉** | 址不变 | `get_field` 体积不增；墓碑填到原 0x340。P1 `nm` 金丝雀 |

EB 上 `get_field` 本就热。把 0x340 的 **执行足迹** 收到 ~0x80，对 L1I **有利**（少取 walk 的哈希环）。代价是 miss 远跳——EB 若 mega 率高，会多付一次 `br` 到尾。故 P0 必须报 **EB 的 mono 覆盖**；覆盖低则 P1 不准拿 EB 当赢面，只当「L1I 不得更差」的哨。

D-cache：IC 表是 **新工作集**（见 §7）。I 墙和 D 墙分开记账。

---

## 5. ⑤ 与融合 / L-1 / 负定理

| 约束 | 相容？ | 怎么守 |
|---|---|---|
| leftover B 可 dispatch | 是 | B 仍是合法 `get_field`（7 字节）。跳入 B 进 `op_get_field` 正本，R1 同构：冷表仍指原 handler |
| 融合只改首字节 | 是 | site_id 是操作数，不是 fused id。254/255 不动 |
| 禁克隆 `get_field` walk | 是 | walk **一份**，在尾。命中臂不含哈希环。`get_field_field2` 今日抄的那份 walk：**P1 不准再抄**；它 musttail 进同一 `op_get_field`（第一发）/ `op_get_field2`（第二发），让 IC 长在正本上 |
| L-1 岛钉址 | 是 | 体长不增；`if_false8` 金丝雀 |
| 局部性墙 | 是 | 命中叶短；unusual / walk 远 |
| 外提禁 | 是 | 命中路径 ZERO `bl`。learn/walk 是 musttail，不是 `bl` 子程序 |
| 同文件 `always_tail` 折回 | **已知墙** | walk **必须**经 `property_tail_tbl` 运行时下标。直跳 = 折回 = 岛内又变成 0x340+探针 |
| monolith no-go | 是 | 不并 CASE |
| DT / 5 参 / 8 参 | 不相交 | 不加参、不做 per-byte sidecar |
| Shape 56B / Object 64B / FB 96B | 是 | 不改这些 sizeof |
| CH3-FAT 不可达 | 不相交 | 不把两发 `get_field` 并进一个 handler |
| 退役「无 IC」文档 | 政策以本立项为准 | 过审后才改 `docs/perf/inline-cache-design.md`；未批保持「已退役」 |

`get_loc0_field`（0x40）继续 musttail `op_get_field`：前缀小组件 + 正本 IC。不要给 fused A 单独做 IC 臂。

---

## 6. ⑥ 分期与杀门

### P0 — 位点稳定性普查（已跑，见 §0.1）

pT 表已齐。原拟「zoo 并集 ≥70%」**不作硬门**——并集 50% 的付款是 richards 稳定 3-shape（75M）和 raytrace mega，不是 TS/box2d 不稳。硬门改成 **主尺案 + 纸面 + 体积**：

| 门 | 阈值 | pT 实测 | 判 |
|---|---|---|---|
| TS `get_field` mono | ≥70% | **80.4%** | PASS |
| box2d `get_field` mono | ≥70% | **94.1%** | PASS |
| 纸面 `TS_mono_fires × 8` | ≥30M cyc | 52.41M×0.804×8 ≈ **337M** | PASS |
| 表体积（全 zoo 行 ×32B） | ≤2MB | **1.32MB** | PASS |
| 每函数位点 | <65534 | TS max 1,122 | PASS |
| zoo 并集 mono | 只报告 | 50.0% | 不杀（结构是 3-shape/mega，不是噪声） |
| EB mono | 只报告 | **100%** | P1 可保留 EB 为 L1I 哨，仍不设赢面义务 |
| own vs proto | 缺口 | 未分桶 | P1 测例补；TS/box2d 热臂先例 ≈ own |

**P0 主尺过。允许进 P1。**  
剩余缺口（不挡 P1）：pT 未报 own_data_frac / top1_frac（只用 n_shapes==1）。learn 合同仍是 own 数据才填。

### P1 — 金丝雀（一日+门）

- **只 `get_field`。** 含 leftover 进正本的那些发（`get_loc0_field` 等自动沾光）。
- **不开** `put_field` / `get_field2` / poly。
- 尺：
  - 主尺 **typescript** cyc，n≥4 ABBA，3-pad 同号降才算过；
  - 哨 **box2d** cyc 不得差过噪声；**EB** L1I refill / cyc 不得同号变差；
  - 四资产不得同号负；
  - zlib/mandreel 岛/cyc 回归。
- 硬门：§3.3 insn/体长/`bl`/帧；`nm` `op_get_field`/`op_if_false8` 址；objdump 命中臂无哈希环、无第二份 walk；`test-exec` + test262 `property-accessors` / `Object` / `Proxy` / `Reflect`。
- **P1 cyc 不降 → 杀。** 不准立刻加 put / 第二形「再试试」。

### P2 — `put_field` 覆盖写

仅 P1 过。只学 **已有 own 数据且 writable** 的覆盖。transition/add 不学。主尺仍 TS（13.60M put）+ box2d put 哨（现 +6.9M 独占，可能是真矿）。杀门同 P1。

### P3 — `get_field2` + 收口

同一张表、同一套 guard。`get_field2` 不释放接收者。zoo 3-pad 包验收。

### P4 — poly-2/3（可选，pT 已证有矿）

pT：zoo `get_field` **38.1%** 在 2–4 shape；**richards 75.1M 几乎全是恰 3 shape**（atom 821/846 循环）。这比「再削 TS 15% mega」大。

仅 P1–P3 过且命中臂加一条 cmp 仍 ≤28 insn 才开。第三槽（richards）另核预算；破 28 就停在 2、richards 继续 walk。

### 明确后置

- 数值 IC（`get_array_el`）——另一键（index 不是 atom）。
- call IC / `call_method`。
- 缓存 JSValue、缓存 getter 结果。
- 复辟旧 `src/core/ic.zig`。
- Shape 头加 gen、FB 96B 加字段。

---

## 7. ⑦ 预算与风险

### 7.1 预算

| 资源 | 现状 | 本机制 |
|---|---|---|
| opcode u8 | 254/255 空 | **不占用** |
| `get_field` 宽度 | 5 | 7。码流 +2 × 位点数。TS 源编译后量级视 pT；远小于 DT ×8 |
| FB 96B / Shape 56B / Object 64B | 钉死 | 不动 |
| 热扩展 pad | +0/+8/+16 已用 | +24 IC 指针 |
| 堆 | 无 | `n_sites × 32B` + 钉住的 `shape*` |
| 岛 | `get_field` 0x340 活走 | 活代码缩短；nm 尺寸不增 |
| compile | — | emit 多写 u16；realize 分配空表 |
| 人 | — | P0 半日（pT）；P1 一日+门；P2/P3 各一日 |

### 7.2 内存 / GC

- **表：** 32B × 位点。P0 门 2MB。空 FB 不分配（零位点）。
- **钉 shape：** 槽里的 `shape*` 是强根。已无对象的旧 shape 会被 IC 钉住，直到该位点 mega / FB 死 / 显式清空。v1 接受；mega 路径必须把指针置 null。禁止 shape 析构扫 IC 链表（风暴）。
- **写屏障：** 学的时候 `shape*` 从堆写进 FB 表，按普通堆槽走已有 barrier。不准用非追踪 raw store。
- **OOM learn：** 学失败 = 不填，走 walk。下一次再试。不准为 IC 失败抛到用户。

### 7.3 失效风暴

v1 无广播。最坏：热 shape 上一次 `delete` → 所有学过它的位点 **各 miss 一次** 再学（或若 delete 后不再是 own 数据则变 empty/mega）。代价 = 一次 walk / 位点，不是 O(全表) 补丁。

反复 delete+define 同一热属性：每次 Property 字变都 miss。若 P1 画像里这种位点多，升 mega（`fires`  saturating + 连续 miss 计数，热臂可不读，learn 路径读）。

### 7.4 D-cache（真风险，与 I 墙并列）

今日哈希走的是 **对象的 shape**（已经为了读 `shape_ref` 进 L1D）。IC 表是 **按位点** 的第二阵列：TS 热环若扫过几千个位点，32B×N 可能 >64KB L1D，IC 自己 miss，省下的哈希载被换回。

这是本机制最可能「insn 赢、cyc 平」的原因。对策：

- P1 主尺必须是 **cyc**；
- 可加 `perf` `l1d_cache_refill` 哨（非门，解释用）；
- 禁止为「提高命中率」在热臂读 `fires` 或维护 LRU（那是再加工作集）。

### 7.5 其它风险

| 风险 | 为何像真 | 对策 |
|---|---|---|
| 命中臂 ≥28 insn | guard 三比较 + IC 基址载 + RC | 硬顶；砍 `vm.ic_base` 或合并 prop_word 比较 |
| LLVM 折回 walk | 同文件 Handler `always_tail` | 只准表跳 |
| 摊帧 | `vm.ic_base` / learn 的 `bl` | 命中路径禁 `bl`；摊了就删 ic_base |
| 岛滑 | 体长涨 | nm 门；涨则杀 |
| 缓存值 / 跳过 getter | 旧 IC 的诱惑 | 合同 + 测例 |
| box2d 纸面 283M cyc | F 已是信用，增量可能没那么大 | box2d 只当哨 |
| 微基准虚胜 | `prop_read_mono_loop` | 禁；zoo 3-pad |
| leftover 宽度 | `sizeOf` 漏改 | 融合 / pc2line / L0 单测 |
| QCP-1B 布局 | 乱加 FB 字段 | 只动 pad+24 和独立分配 |

### 7.6 超越 qjs 在哪、不在哪

- **超越：** 有界、可失效的位点查找缓存。qjs 每次 GET_FIELD_INLINE 走哈希。这是四条件允许的机制红利。
- **不超越：** 更快的 getter/Proxy、把 `get_field+call_method` 合成一发、靠 IC 填 TS +7.40G 的全部 insn（IC 最多吃占用段的查找税）。

---

## 8. 请用户裁

| 选项 | 含义 |
|---|---|
| **批 P1 金丝雀**（推荐） | P0 主尺已过。只 `get_field` + §3.3/§6 杀门。不过即停 |
| 只收 P0、P1 另裁 | 表已在 §0.1，等价于再读一遍 |
| 改主推 A（pc sidecar，不改宽度） | 不建议。命中路径更长，和 §3 打架 |
| 要求 v1 含 poly / 原型 / put | 不建议。命中臂先证 28 insn。richards 3-shape 留 P4 |
| 整通道挂起 | 与 CH3 并列存档 |

本 spike 不申请写产品码。254/255 继续空。

---

## 9. 一句话回用户

属性 IC 合宪：全位点全 shape、只免查找、guard 必验、失效靠 `shape*`+`Property` 字、不广播。选型 = **内嵌 `u16 site_id` + FB 侧 32B 表**；quickening 排除；pc sidecar 不取。命中臂目标 22 / 硬顶 28 insn（今日 47），walk 出岛表跳，岛体积不增。pT：TS 80.4% / box2d 94.1% / EB 100% mono，表 1.32MB；并集 50% 是 richards 3-shape + raytrace mega。P0 主尺过，候批 P1。
