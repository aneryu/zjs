# CH3-DISPATCH-SPIKE — 通道 #3 分派形态机制（只设计）

日期：2026-08-17。**只设计，不实施，无 commit，无 FW 刀。**  
递用户过审。数字非裁决。生产形参照 main 尖（`9deb9f45` 族：L-1 岛 + 融合六包 + leftover 梯 + 4 参 `cont` musttail）。

对照档案（本通道前史，不重开）：

| 档案 | 结论 | 本 spike 关系 |
|---|---|---|
| 通道 #2 opcode-fusion | 六包收官；leftover 梯末刀 zlib insn/br 赢、cyc 贴线 | **下层已铺满。** 本机制在融合原子之上，不替代融合 |
| DT-SPIKE（通道 #3 第一案） | HANG：少 1 载、BTB 下周期≈0；sidecar ×8 出 L2 | **不重开 hop 胶水。** 本机制砍的是 **hop 次数**，不是 hop 长度 |
| 5 参 / 8 参 / `preserve_none` | C 封存 | 不加参、不等 toolchain |

---

## 0. 一句话

在 **不并进 CASE 单体、不外提热体、不克隆 `get_field`/`get_array_el`、不改 hop 胶水** 的前提下，用 emit 期认出的 **直线窗口** 换「每用户 op 一次预测正确的间接 `br`」。合法编码只剩一种：首字节改写成 **区域 opcode**，窗内其余字节保留（与融合 leftover 同构），特化 handler 里顺序做完窗口语义再 `cont`。

u8 槽只剩 **254、255**。目录硬顶 **2 个形**。v1 目录 **禁止** 含 `get_field` / `get_array_el` / `call_method` 体——否则必克隆或必再付那一次 `br`，box2d/TS 的大 hop 不在诚实奖金里。

P0 普查（zoo 并集、融合之后、跳入点切开）若找不出 ≥30M hop 的「小组件直线窗」，通道应 **REJECT-ARCHIVE**：机制合宪，矿尽。

---

## 1. ① 机制定义

### 1.1 要砍的税

今日热 hop 只走 `cont`（`tailcall_dispatch.zig`），RF 典型：

```
ldrb w8, [x0, #1]!
adrp+add 表基
ldr  x4, [x9, x8, lsl #3]
br   x4
```

BTB 已预测这条多态 `br`（DT-SPIKE / 8 参：再短 hop 周期不赢）。税不在「少 1 载」，在 **每用户 op 付 1 次预测正确的间接跳 + 目标取指**。zlib/mandreel 审计把残差归到这层；融合吃掉了相邻对，**对与对之间的 hop 还在**。

qjs 的红利是 `JS_CallInternal` 里 CASE 直线段（同函数、无间接跳）。monolith no-go 禁止我们做 91 臂巨函数。本机制是 **局部、有界、多入口表** 的 CASE 切片——超越 qjs 的是「按形特化的直线段」可跨任意同类窗口，不绑在一个解释器函数里。

### 1.2 三个候选族 = 一种机制、三种编码

| 编码 | 入场 | 新槽 | 窗内 hop | 前史 |
|---|---|---|---|---|
| **A. 热路径超块（首字节改写）** | 窗口首 op 改成区域 id，`br` 进该形 handler | 每形 1，全空间剩 2 | **0**（顺序做完再 `cont`） | 融合同构，已证可赢周期 |
| **B. 多 op 特化直线段（handler 偷看后继）** | 不改首字节；现 fused handler 看 `pc[k]` | 0 | 少 1，若把后继内联 | 即 leftover 梯；fusion-END zlib **insn 赢 cyc 贴零**，物理下限 |
| **C. emit 期区域线索 sidecar** | 字节码不动；并行 `shape[pc]`，每 hop 先问 | 0 | hop **更长** | DT-A 同轴，已 HANG |

**主推 A。** B 不重开（下限已量）。C 不重开（hop 税同 DT）。  
A 是融合从「2-原子」升到「N-原子窗口」的一般化，不是新发明。

### 1.3 A 形合同（实现规格，本轮不写码）

**窗口（静态，finalize / `resolve_labels` 之后、在融合之后）：**

1. 连续 op；**已融合 id 算 1 原子**（`get_loc0_field` 是 1，不是 2）。
2. 除窗口首字节外，**没有入边**：label / `catch` / 融合 leftover 且存在跳到该 pc / `using` 前缀切点，一律切窗。
3. 窗内无 `call*` / `tail_call*` / `eval` / `apply` / `return*` / `await` / `yield*` / `throw` 源 / 会 `pollInterrupt` 的 op（`call_method` 的 poll 在 handler 里——此类 op **只能当窗尾，且 v1 不收**）。
4. 长度 3..K，**K=4**（含已融原子）。2 原子 = 通道 #2，不要再占槽。
5. 形 = opcode id 元组。目录 = zoo **并集动态权重** 最高的 ≤2 个形（禁单基准拟合，同 L-1.5 / 融合名单纪律）。

**改写：** 只改窗口 **第一个字节** 为区域 opcode（254 或 255）。后续字节 **原样**（含 leftover B、操作数、再融的第三原子）。跳入窗内任一后继 pc 仍落到原 op，表项合法。

**handler `op_region_<shape>`：**

- 按序执行各原子的 **热臂语义**（读操作数、改 `sp`/`pc` 的本地游标、做完该 op 的用户可见工作）。
- 原子之间 **禁止** `cont` / `next` / 表 `br`。
- 窗尾：`@call(.always_tail, cont, .{ pc_after, sp, vb, vm })`。
- 任一原子 miss/cold：musttail **现成** 单 op / cold handler，且 **pc 指向该原子原字节**（与融合 leftover 进 `get_field` 同合同）。
- **禁止** 把 `get_field` / `get_array_el` / `put_field` 热体抄进区域 handler（克隆禁；L-1 岛）。v1 目录因此只收 **小组件**（`get_loc*` / `put_loc*` / `push_*` / `drop` / `dup` / 已是小体的 arith-cmp / 已融小组件）。
- 区域 handler 自身：`linksection(op_handler_section)`，`align(16)`，**体长硬顶 0x100**（超过则该形不进目录）。帧 = 今日小组件水平（禁止新的 0x1c0）。
- 自己的帧上 **ZERO 非尾调用**（handler 不变量）。

**realize：** 不预解码 handler 地址（ASLR / 可序列化 FB）。全部是 emit 期立即数 id，和融合一样。

**L0 / `active_dispatch_tbl`：** 区域 id 在快表和冷表都要有项；冷表项 = 拆回逐原子 `cont`（或直接指回窗口首 **原** op——若已改写则冷路径走「按形解释」的一份 noinline 慢体，岛外）。禁止 256 个 `profiledHandler` 进岛（fusion-END 学案）。

### 1.4 四条件自证（通道 #2 判例格式）

对照 `PERF-MECHANISM-LEDGER.md` 与条目 #2（opcode-fusion）申报文。

**1. 通用**

- 先例：JSC superinstruction / V8 字节码融合的一般化；qjs 自己有 `get_field2` 等 emit 期融合。本机制是同一思想从 2-原子扩到 **有界直线窗口**。
- 选形：**全 zoo 并集** 窗口频次，禁「splay 里常见就收」。形 = opcode 元组，不认函数名、字段数、G 形、`initialize`。
- 命中 = 字节码静态长这样；不命中 = 仍走今日逐 op。失败是 miss，不是悬崖。
- 必须仍成立的例子（否则就是分类器）：

| 窗口 | 应收？ |
|---|---|
| 任意函数里出现目录形 `⟨push_i8, get_loc0, add⟩` | 是 |
| 同上但中间有 label / 跳入 leftover | 否（切开后不够 3 原子） |
| `⟨get_loc0_field, put_loc0⟩`（已融原子 + 小组件） | 普查后若进目录则是 |
| `⟨get_field, get_field2, call_method⟩` | **v1 否**（肥体/poll；不是「TS 专用」否，是合同否） |
| 只在某个 benchmark 里出现的 5 元组 | 否（并集门槛） |

**2. 用户码必执行**

| 层 | 用户语义？ | 本机制 |
|---|---|---|
| `get_loc` / `add` / `put_loc` 的读写真值 | 是 | 必须跑，只换分派边界 |
| `get_field` 哈希+槽+exotic | 是 | v1 **不收进窗**；若将来收，必须跑同一热臂，禁止画像代替 |
| 解释器 `cont` 间接跳 | 否 | 可消。与融合「只并分派边界」同一句话 |
| poll / 调用 / return | 是（时序可观察） | 窗不含；与融合「不跨 qjs 会 poll 的边」同一句话 |

已删 bypass 的罪：跳过 ctor **体**。本机制若用「窗口长得像」代替其中一发 `add`，就重犯。

**3. 可观察等价**

| 面 | 义务 |
|---|---|
| 跳入窗内 | leftover 字节仍是合法 dispatch；test：goto/if 落在窗第二原子 |
| `frame.pc` / pc2line / `Error.stack` | throw 时 pc 落在 **当前原子原字节**（miss 路径 musttail 前 `syncPc`）；窗内热成功路径若 throw（几乎只有 OOM），同样 |
| poll / interrupt | 窗内无 poll 点；与 qjs 同文不会在 `push`+`get_loc` 中间 poll |
| fusion leftover 偷看（`tailPush2` 看 `pc[2]`） | 区域改写只动窗口 **首** 字节；若窗口从非 fused A 开始，后继偷看不变。若窗口首是 fused id，该 fused handler **不再跑**（被区域 handler 取代），偷看逻辑要搬进区域 handler 或该形不准以 fused 首开头——P0 选型时回避「首原子依赖偷看」的形 |
| L0 `stop_before_pc` | 字节 pc；窗内 stop 落在后继原子 → 该原子仍可从冷表进 |
| test262 + difftest | 全量；另加：跳入 leftover、OOM 在窗第二原子、融合+区域同函数 |

**4. zoo 验收**

- 3-pad lineage；判读主尺 = **cyc**（insn/br 降、cyc 平 = IPC 税，**杀**，fusion-END / 8 参同判）。
- 四资产（crypto / raytrace / navier / code-load 惯例）不得同号负。
- 主判读：**zlib**（分派密度残、compute 直线段多）+ **mandreel** 哨。box2d/TS **不是** v1 过线条件（v1 吃不到 `get_field` hop）。
- 单 pad 噪声带内（DB 0.997–1.005）不单独当赢。

---

## 2. ② 负定理群相容（逐条）

### 2.1 局部性承重墙（K-ret-slim / unusual 四形）

**定理：** 边界 unusual 内联体是局部性承重；外提任何形均输周期。岛内热叶必须短，unusual 远跳。

**本机制：** 区域 handler 是 **新的短热叶**，不是把 unusual 拉回岛。miss 仍 musttail **现成** 岛外/岛尾 unusual。体长 0x100 硬顶。禁止把 `op_return` unusual、`call_method` 0x3f0、`stringAddStringsOwned` 0x140 卷进区域体。

若 LLVM 把区域 handler 和某个 unusual 尾合并成 0x200+：该形从目录删除，不是「再 outline」。

### 2.2 外提禁（G-BL / call1 0x1c0 / F-resid）

**定理：** 帧为承认+热构造而建；外提热体 = 双付。学案：`call_method` 外提、call-entry-slim。

**本机制：** 窗内语义在区域 handler **自己的帧**里做完（小组件本就无大帧）。禁止 `bl` 到通用「解释 N 个 op」的 outlined 解释器。禁止为区域再开一层 Entry。

`musttail` 到 `get_field` 以「不克隆」：合法，但 **那一跳正是要砍的 hop**，该形奖金为 0，目录不应收「以肥 op 结尾且不内联它」的窗——除非前缀小组件 hop 单独过 30M（P0 决定）。

### 2.3 融合物理下限（通道 #2 收官）

**定理：** leftover B 必须可 dispatch；禁克隆 `get_field`/`get_array_el`；再偷看后继 = 胀 A 体，zlib 已 insn 赢 cyc 不赢。

**本机制：**

- leftover 合同 **继承**：区域只改首字节，B..N 留着。
- 不靠「再偷看」扩现有 fused handler（那是 B 编码）。
- 新 handler 是 **另一入口**，不是把 `get_loc0_field` 从 0x40 拉到 0x200。
- 已融对仍由通道 #2 服务；区域把它们当原子，不拆开重融。
- 254/255 融合-END 明确未占用——本机制才动它们。

### 2.4 monolith no-go（2026-07-14，91 臂 4/4 回退）

**定理：** 一个函数里塞全部 op = FE/I-cache/LLVM 回退。

**本机制：** 仍是 **一张表、许多小 handler**。区域形 ≤2，每个 ≤0x100。不是「按基本块 JIT 进一个 stub 池」。禁止 `switch(shape)` 的单一 `op_region` 巨函数（那是 2 槽换 1 个隐形 monolith）。

qjs CASE 直线段不可整体搬来。本机制只搬「有界切片」。

### 2.5 相邻负定理（点名不相容则杀）

| 负定理 | 相容？ |
|---|---|
| DT / 5 参 / 8 参 hop 胶水 | 不相交。不加参、不 sidecar 每 hop |
| Entry 几何不可缩 | 不相交。不碰 Entry |
| RC teardown / splay 固有 | 不相交。不承诺 splay |
| CONCAT-INPLACE / 松弛定理 | 不相交 |
| limit-slim REJECT（微基准不迁 DB） | 验收必须 zoo 3-pad cyc，禁 A_direct 当过线 |

---

## 3. ③ 分期验证（先何形 / 何基准杀门）

### P0 — 普查（半日，无产品码）

输入：zoo 并集（`/tmp/r5/fixed` + det 若权重需要分开报）。生产件 RF，opcode profile **不进岛**（fusion-END 的 `cont` 计数器，或离线扫 `byte_code` × 动态入函数计数）。

产出：融合之后、按 §1.3 切开的 3–4 原子窗口表，按动态 hop 排序。两列：

- **全形**（含肥 op）——只说明论，v1 不收
- **小组件形**（§1.3 目录约束）——候选

**杀门：** 小组件列第一名动态 hop × 1 `br` 的诚实上限 < 30M cyc（按 0.2–0.4 cyc/预测 br 折，或直接「hop×0.3」）→ **通道 REJECT-ARCHIVE**，机制合宪、矿尽。不进入 P1。

不预选「像 zlib 的 push/loc/add」。让表说话。

### P1 — 一形（目录 #1 = P0 小组件冠军）

- 占 **254**。handler 手写/生成一份，体长/帧/岛址（`get_field`/`if_false8`/`goto8` 钉死）进硬门。
- 微核：纯该形循环。insn/hop 少 `(N-1)×5` 量级；**cyc/hop 3-pad 同号降** 才继续（否则 BTB 藏税，同 DT P2）。
- 主尺：**zlib**（或 P0 显示该形权重所在的那一个 compute 案，但不得换成「只有 TS 才有的肥窗」）。n≥4 ABBA，cyc 主尺。
- 岛：`nm` `op_get_field` / `op_if_false8` 址与基线比，滑则杀。
- `test-exec` 全过。

**P1 cyc 不降 → 杀。** 不准加第 2 形「再试试」。

### P2 — 第二形（仅 P1 过）

占 **255**。两形一起 3-pad。任一资产同号负 → 撤第 2 形或整通道停。

### P3 — zoo 3-pad 包验收

主判 zlib+mandreel；box2d/TS 只作哨（v1 不承诺动）。DB 钉线带内不单独报功。

### 明确后置（本 spike 不批）

- 肥 op 入目录（需先有「共享热臂、LLVM 保证不克隆」的新证据，另案）。
- 槽 >2（要动 `op_count` 以外的编码，另案）。
- sidecar / DT / 加参。
- 把区域 handler 做成 mini-JIT。

---

## 4. ④ 预算与风险

### 4.1 预算

| 资源 | 现状 | 本机制 |
|---|---|---|
| opcode u8 | `op_count=254`，254/255 空（融合-END 书面保留） | v1 用完。没有第 3 形 |
| L-1 岛 | 热 handler 源序 + 墓碑钉址 | +1~2 个 ≤0x100 叶；必须钉 `get_field` 族址 |
| 区域 handler 帧 | 小组件今日近 0 | 禁止 ≥0x80 新序言 |
| compile | 每形一份 handler | 2 份，可接受 |
| realize / 加载 | 无 | 无（纯 emit） |
| 人 | P0 半日；P1 一日+门；P2/P3 各一日 | 总预算约 3 日；P0 可单独先裁 |

周期奖金（诚实）：

- 每消 1 hop ≈ 1 预测 `br` + 目标 I-fetch。历史：预测正确 `br` 约 0.2–0.4 cyc（DB 钉线 / TAILCALL-DEEP）。
- **30M cyc 门 ≈ 75–150M 被消 hop。** 目录 2 形必须合计过这个门，否则不要开工。
- box2d `get_field` 55M 次、TS 同量级：**v1 吃不到**。架构段（box2d/TS）不能靠本 v1 翻案。

### 4.2 风险

| 风险 | 为何像真 | 对策 |
|---|---|---|
| P0 小组件窗 <30M hop | 融合已吃最密的 2-原子；3-原子小组件可能稀疏 | P0 杀门，不硬上 |
| insn↓ cyc→（IPC） | fusion-END leftover、8 参、limit-slim 全是此病 | 主尺 cyc；微核 3-pad |
| 岛滑 / 墓碑失效 | 新 handler 进 `.op_handlers` | 钉址金丝雀；超 0x100 不收 |
| LLVM 内联肥体进区域 | 变相克隆 `get_field` | v1 目录禁肥 op；objdump 查 `bl`/`体长` |
| leftover 偷看失效 | 区域取代 fused 首 handler | P0 回避「依赖 `pc[2]` 偷看」的首原子 |
| 冷表 / L0 stop | 改写后无「原首字节」 | 冷路径按形拆开或保留一份解释慢体（岛外） |
| 用户期望吃 box2d/TS | PARITY 曾写「架构段需 #3」 | **本文把期望改准**：#3 合宪，v1 奖金在 compute 直线段；肥 hop 要另案（共享热臂不克隆）才碰架构段 |

### 4.3 超越 qjs 在哪、不在哪

- **超越：** 按形特化的有界直线段，表驱动、多入口，不绑死在一个 `JS_CallInternal`。qjs 没有「第 3 原子超块」这一层。
- **不超越、也不许超越：** 把 `get_field`+`call_method` 收进同一激活而不付帧——那是 monolith / 克隆 / 外提三者之一。

---

## 5. 请用户裁

| 选项 | 含义 |
|---|---|
| **先批 P0 普查**（推荐） | 只出窗口表+30M 判定，再决定是否开 P1 |
| 预批 P0+P1 | P0 过门才写 254；P1 杀门照旧 |
| 要求 v1 必须吃 `get_field` | **不建议。** 与克隆禁/外提禁冲突；请另开「共享热臂」案 |
| 整通道挂起 | 与 DT 并列存档；等 P0 以外的新证据 |

本 spike 不申请写产品码。P0 若批，另单只读普查。
