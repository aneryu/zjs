# STRING-SLACK — 十期 REJECT-ARCHIVE

driver 终裁 2026-08-17。QPIN 收。**十期结案，不合 main。**  
枝 `grok/string-slack` @ **`fad30cea`（P1 留支归档）**。P2/P3 未开。  
钉：`/tmp/lanes/STRING-SLACK-QPIN.md`。设计：`STRING-SLACK-DESIGN.md`。普查：`STRING-SLACK-CENSUS.md`。  
数字非裁决用。候 **w46 后收尾**（宪文进仓 / 枝处置归那一波，本票不改 `docs/`、不合、不推）。

---

## 0. 裁

| 项 | 裁 |
|---|---|
| 2.32M / 6.85 GB / 2.0–4.3 G 上限 | **作废为刀申报。** q 在该池也不就地 |
| P1b（z 再融 `add_loc`） | **无对象。** 终态 `add_loc` 133=133 |
| P2 几何类 + usable/destroy | **REJECT** |
| P3 flat InPlace（原 1–2 G） | **REJECT** |
| P1 `@fad30cea` | **留支归档，不合。** 形对 q `19770`，门绿；杀门 2.0M rc1 是口径错不是刀错 |
| 另开「只对齐 q 的 443k `add_loc` InPlace」 | 不属本族。要另立设计 |

---

## 1. 对称成本定理（入宪）

**定理。** 普查钩子上的「z 独占 × 仿真命中 × 省 lhs 字节」**不是**可申报上限。上限只成立当且仅当 **q 在同一源位点、同一 opcode 形上真实兑现了那笔省**。否则两边付同一笔拷贝，是对称成本，不是忠实缺口。

本票实例：

- 2.32M 源位点两边都是 `get_loc + add + put_loc`（`fromCharCode` / `charAt` 环）。`resolve_labels` 融不了。
- `OP_add` 先 Dup，InPlace 看 rc==1 → q 自己 89.4% `rc≠1`，`ConcatString1` 4.82M 整段 memcpy。
- z 付同样的拷 / 同样的 8192 改绳。没有「q 省、z 还在拷」。

与 P6-B 定理并列，不互相吞：

| 定理 | 管什么 |
|---|---|
| P6-B：对象/Shape 精确 slab 类上，q malloc 松弛就地 **不可移植** | 分配器几何 |
| **本票：未在 q 兑现的普查仿真体积 = 对称成本，不是缺口** | 申报口径 |

String 载荷「可以单独改几何 + usable」的设计书改述 **仍成立为事实**，但 **不再构成十期开工理由**：服务对象（2.32M 就地）q 没兑现。

---

## 2. 普查方法论修正

命中率仿真必须配 **q 侧真实兑现验证**，缺一不可：

1. **位点形：** dump q 终态——是 `add_loc` 还是 `get+add+put`。钩子发数不能反推 opcode。
2. **兑现：** 数 q 的命中/失败路径（InPlace 谓词、`js_alloc_string`/`ConcatString1`、或等价），不能只用 z 钩子 rc 反推「q 一定 rc==1」。
3. **齐射：** z 同位点 dump。两边已同形则不是 emit 缺口。
4. **上限：** 只把「q 兑现 ∩ z 未兑现」记为缺口体积。仿真命中 × lhs 字节在兑现验证前 **不得** 写成 G 档申报。

本票缺第 1–2 步就开了设计书；QPIN 补完后上限作废。后续凡「census 命中率 → 周期天花板」的票，QPIN 这三步是门，不是 nicety。

---

## 3. 枝与待命

- `grok/string-slack` @ `fad30cea`：**P1 留支**，一 commit，热路径无普查钩。不合、不 rebase、不推。
- 工装留 `/tmp/lanes/string-slack-qpin/`、`/tmp/qjs-count`（非仓）。
- lane **收案待命**。w46 后收尾：宪文/方法论进仓、P1 枝留或丢，听那一波。本回合不改 `src/`、不改 `docs/`。
