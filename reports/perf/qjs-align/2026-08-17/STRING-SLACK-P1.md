# STRING-SLACK P1 — RC 编排

日期：2026-08-17。枝 `grok/string-slack` @ **`fad30cea`**，基 `main@fe4eef54`。  
**候验，未开 P2。**

## 做了什么

`addLocalString` / `addLocalStringAt` 双方 string 走 `addLocBothStrings`：

- 不 `loadOwned`；对槽指针 `tryAppend(..., max_rc=1)` / `startAccumulatorRope`
- 未命中：`addStringsOwned(slot.dup(), rhs)` + `replaceOwned`（qjs `ConcatString(Dup(*pv), op2)`）
- 对象 RHS 仍 Dup，对齐 `js_add_slow` 19783

金丝雀：`add_loc exclusive accumulator stays exclusive and aliases do not mutate`。

## 杀门

| 门 | 结果 |
|---|---|
| test-exec | **482/482**（含金丝雀 + 原 snapshot/toPrimitive） |
| 别名金丝雀 | `t=s; s=s+"!"` → `t` 仍 `hello` |
| census zoo pdfjs `add_flat_flat_rc1` ≥ 2.0M | **未过：24,289**（与改前 23.8k 同号） |
| FW pdfjs/splay n=2 | insn 近零（pdfjs **−40M**）；cyc +64/+48 落 n=2 噪声 |

## 杀门未过的原因（请裁）

zoo pdfjs 与普查同尺：

| | |
|---|---|
| `add_total` | 3.83M |
| 钩子 `flat+flat` / rc1 / rc≤3 | 2.64M / **24.3k** / 2.32M |
| **`add_loc` 双方** | 543k |
| 其中 flat+flat | 110k |
| 其中 **rc==1** | **480** |
| 其中 rc>2 | 109k（intern/共享） |

2.32M rc==2 在 **`OP_add`（get_loc 槽+栈）**，不是 add_loc 的 transient dup。qjs 对这条也是 rc≥2，`ConcatStringInPlace` 同样进不去（所以才有 `add_loc`）。P1 按 19770 改对了，但 **翻不了那 2.32M**。

P3 若坚持 `rc==1`：pdfjs 就地命中上限 ≈ 原严格 rc1 **20k 发**，不是 2.3M，**吃不到 1–2 G**。

## 候裁

- **P1 形**：建议收（q 形 + 金丝雀绿 + 无热钩）。
- **P2/P3**：按原设计继续，则 P3 申报需下调到「20k 发 / 非 G 档」。
- 若仍要 2.3M 池：要另开「更多 `add_loc` 融合」或推翻 C（`rc≤3`），都不是本 commit。

原始：`/tmp/lanes/string-slack/p1-zoo-pdfjs.census`
