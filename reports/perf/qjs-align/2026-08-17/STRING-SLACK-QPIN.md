# STRING-SLACK-QPIN — q 侧 pdfjs 追加位点钉

日期：2026-08-17。lane w1:pW。**只析不改 src。** P1 `@fad30cea` 留支。P2/P3 仍暂缓。  
数字一律 **非裁决用**。

| | |
|---|---|
| q dump | `/tmp/qjs-dump/qjs` `DUMP_BYTECODE (1\|2\|4)` → `/tmp/lanes/string-slack-qpin/q-pdfjs.dump`（28 MB，982 终态函数） |
| q 计数 | `/tmp/qjs-count/qjs`（官方树副本，只加 InPlace/Concat 计数器）zoo pdfjs **CPU 15** |
| z dump | `ZJS_DISASM=1` `grok/string-slack` `zjs` @ `fad30cea` → `/tmp/lanes/string-slack-qpin/z-pdfjs.dump` |
| 语料 | `/home/aneryu/javascript-zoo/bench/pdfjs.js` |
| 对照普查 | `/tmp/lanes/STRING-SLACK-CENSUS.md` / P1 `/tmp/lanes/STRING-SLACK-P1.md` |

---

## 0. 裁决句（二选一已落地）

**q 不融那 2.32M 池。报「对称成本」+ 普查上限订正 + P2/P3 REJECT。不报 P1b。**

理由三句：

1. **2.32M 的源位点在 q 是 `get_loc + add + put_loc`（`OP_add`），不是 `add_loc`。** 那是 `str += String.fromCharCode(...)` / `str.charAt` 一类 RHS 非简单 local/atom 的循环。q `resolve_labels` 融不了（`quickjs.c:35417–35462` 只认 `get_loc + {atom,i32,get_loc/arg/var_ref} + add + dup + put_loc + drop`）。
2. **z 已经按同一规则融。** pdfjs 终态 `add_loc` **133 = 133**（q dump / z dump 逐条同数）。`Lexer_getString` / `Lexer_getName` / 循环金丝雀两边都是 `add_loc`；`bytesToString` / `stringToPDFString` / `Lexer_getHexString` 两边都是 `get + add + put`。没有「q 融、z 不融」的忠实缺口，**P1b 无对象**。
3. **q 在那 2.32M 池上并不省拷贝。** 官方等价 qjs 计数：`JS_ConcatString1`（整段 memcpy）**4.82M**；`ConcatStringInPlace` 5.54M 次进入里 **rc≠1 = 4.95M（89.4%）**。`OP_add` 先 `get_loc` Dup，槽+栈 rc≥2，InPlace 进不去。q 真省到的是 **已融合的 `add_loc` 池**（679k 试、443k 命中）——z P1 之后这条走 `startAccumulatorRope`，也已经避开 O(n²)，只是机制不同（绳 vs 原地），不是 6.85 GB 那笔。

---

## 1. q 终态位点（① 逐位点）

终态 982 函数。`add_loc` **133**：string **30** / numeric **102** / unknown **1**（`estimatedDecodedSize`，数值）。  
`add` **1231**：`add+put_loc` 399、`add+set_loc` 40、`add+other` 792。

### 1.1 q **融**成 `add_loc` 的字符串位点（30）

这些是 `str += ch` / `str += "atom"`。**不是 2.32M 主粮。**

| 函数 | 行 | n | 形 |
|---|---:|---:|---|
| **Lexer_getString** | 27031 | **10** | `get_loc ch; add_loc str` 或 `push_atom "\\n"; add_loc str` |
| Lexer_getName | 27115 | 3 | `push_atom "#"; add_loc str` / `get_arg ch; add_loc str` |
| Lexer_getNumber | 27003 | 2 | `get_arg ch; add_loc str` |
| startXRef getter | 1174 | 1 | `get_loc ch; add_loc str`（digit 环，一次/PDF） |
| Lexer_getObj | 27171 | 1 | `get_loc ch; add_loc str` |
| PostScriptLexer_getToken / getNumber | 5318 / 5371 | 1+1 | 同上 |
| Type1Parser getToken / extract* | 17347 / 17472 / 17481 | 3 | `token += c` |
| bidi | 33071 | 1 | `result += ch` |
| 其余（fontLoader / CMap / nameTable / cff / sanitizeMetrics） | — | 7 | atom 拼表，冷 |

`Lexer_getString` 十条终态（q dump `q-Lexer_getString.ops`）：

```
get_loc8 4: ch ; add_loc 2: str     // case '(' / ')' / '\\' / default / default-after-escape
push_atom "\n"/"\r"/"\t"/"\b"/"\f" ; add_loc 2: str
```

同一函数里 **一条不融**：`str += String.fromCharCode(x)`（八进制）→ `get_loc str; … call; add; put_loc str`。

### 1.2 q **不融**、1 字节热追加（2.32M 候选）

RHS 是 `fromCharCode` / `charAt` / 调用，编译成 `get_loc acc; <expr>; add; put_loc acc`。  
`OP_add` 吃两栈槽；`get_loc` 已 Dup → 进 `JS_ConcatString` 时 lhs **rc≥2**。

| 函数 | 行 | 源 | q 终态 |
|---|---:|---|---|
| **bytesToString** | 1350 | `str += String.fromCharCode(bytes[n])` | `get_loc str; … fromCharCode; add; put_loc str` |
| **stringToPDFString** | 1565 | `str2 += fromCharCode(...)` / `str.charAt(i)` | 同上，两条循环 |
| **Lexer_getHexString** | 27142 | `str += fromCharCode((x<<4)\|x2)` | 同上 |
| Lexer_getString | 27031 | 八进制 `fromCharCode(x)` | 1 条 `add+put_loc` |
| Lexer_getName | 27115 | hex `#` `fromCharCode` | 1 条 `add+put_loc` |
| arrayToString / parseFloatOperand / Type1 抽串 | — | 同类 | `add+put_loc` |

分类器把 `quantizeAndInverse` 的局部 `t` 误标成 string（26 条，DCT 数值）——**不是**字符串追加。热 1B 池就是上表那些 `fromCharCode` 循环。

### 1.3 和 z 普查对得上

P1 zoo pdfjs 钩子（`stringAddStringsOwned`）：

| 计数 | 发 |
|---:|---:|
| `add_total` | 3.83M |
| `add_flat_flat` / `rc_le3` | 2.64M / **2.32M** |
| **`add_loc_both`** | **543k** |
| `add_loc_flat_flat` / `rc1` | 110k / 480 |
| `add_lhs_rope` | 1.17M |
| demand=1B | 2.10M / 2.32M |

2.32M exclusive flat+flat 在 **`OP_add` 钩子**，不是 `add_loc`（`add_loc` 双方 string 只有 543k，flat+flat 110k）。  
1B demand 对得上 `fromCharCode`/`charAt` 逐字节环，也对得上 lexer `str += ch`——但后者已经是 `add_loc`，进的是 543k 那一栏，不是 2.32M。

---

## 2. q 到底省没省这些拷贝（②）

工装：`/tmp/qjs-count/qjs`（`/home/aneryu/quickjs` 副本，`JS_ConcatStringInPlace` / `ConcatString1` / `ConcatString2` / `js_new_string_rope` / `OP_add_loc` 字符串臂加计数）。zoo pdfjs，**CPU 15**。打分 `PdfJS: 9926`。原始 `/tmp/lanes/string-slack-qpin/q-count.err`。

| 计数器 | 发 | 含义 |
|---|---:|---|
| `ip_enter` | 5,541,288 | 进入 `JS_ConcatStringInPlace`（`add_loc` + `ConcatString2`） |
| **`rc_ne1`** | **4,953,257（89.4%）** | `js_rc(p1) != 1` → FALSE |
| `hit_narrow` | 486,731 | 窄串 memcpy 成功 |
| `hit_wide` | 0 | |
| `miss_slack` | 101,300 | rc==1 但 usable 不够 |
| `empty` / `widen` / `tag` | 0 / 0 / 0 | |
| **`addloc_str`** | **679,280** | `OP_add_loc` 双方 string |
| **`addloc_ip_hit`** | **443,010（65.2%）** | 其中 InPlace 成功 |
| `cs2` / `cs2_ip_hit` | 4,862,008 / 43,721（**0.90%**） | `OP_add` 短+短路 |
| **`cs1`** | **4,818,287** | `JS_ConcatString1` = **整段 lhs+rhs memcpy** |
| `rope_new` | 1,439,950 | `js_new_string_rope` |

对账：`hit_narrow` 486,731 = `addloc_ip_hit` 443,010 + `cs2_ip_hit` 43,721。

**结论：q 在 2.32M 那类 `OP_add` 上没有省拷贝。**  
`get_loc` Dup 后 rc≥2，InPlace 在 `ConcatString2` 上几乎全灭（0.90%），然后走 `ConcatString1` 整段拷。lhs > 8192 且 rhs ≤ 512 才改走绳（`JS_STRING_ROPE_SHORT2_LEN`），两边阈值相同。

q **真正**吃到 InPlace 的是已融合的 `add_loc`（65% 命中）。那是 679k 池，不是 2.32M。第一次 `str = ''` 是 intern 空串（rc≫1）必 miss；之后新串 rc==1，malloc 类有余量就命中。这解释了 P1 之后 z `add_loc_flat_flat_rc1` 仍只有 480：z 的 `tryAppend` 只认绳，miss 就 `startAccumulatorRope`，后续不再是 exclusive flat。

先前 perf（`instructions:u`，42 个 InPlace 样本、memcpy 成功 0）方向对，样本太稀；本次是全量计数。

---

## 3. z 同位点对照（③）

`resolve_labels` 两边同一套 6 元模式（z `src/compiler_v2/resolve_labels.zig:2809–2864` = q `35417–35462`）。

| 位点 | q | z | 判 |
|---|---|---|---|
| `add_loc` 终态条数 | **133** | **133** | 齐 |
| `Lexer_getString` `str += ch` / `+= '\\n'` | 10× `add_loc 2` | 10× `add_loc 2` | 齐 |
| `Lexer_getString` `+= fromCharCode(x)` | `add; put_loc 2` | `add; put_loc` | 齐（都不融） |
| `Lexer_getName` `+= '#'` / `+= ch` | 3× `add_loc 0` | 3× `add_loc 0` | 齐 |
| `Lexer_getName` hex `fromCharCode` | `add; put_loc 0` | `add; put_loc 0` | 齐 |
| `bytesToString` | `add; put_loc 0` | `add; put_loc 0` | 齐 |
| `stringToPDFString` | `add; put_loc 2` | `add; put_loc 2` | 齐 |
| 循环金丝雀 `str += ch` / `+= 'x'` | `add_loc` | `add_loc` | 齐 |
| 循环金丝雀 `+= fromCharCode` | `get; add; put` | `get; add; put` | 齐 |
| 链式 `var s=''; s+=ch; return s`（TOS 复用 `set_loc`） | 不融 | 不融 | 齐（pdfjs 热环不是这形） |

原始：`z-canary2.dump`、`q-canary2.out`、`z-pdfjs.dump`、`q-sites.txt`、`q-classified.json`。

**没有 P1b 可补的 emit 缺口。** z 不是「少融了 q 的 `add_loc`」；2.32M 是两边都拒绝融合的 `OP_add`。

---

## 4. 普查上限订正

`STRING-SLACK-CENSUS` / 设计书把 2.32M exclusive flat+flat × 6.85 GB lhs 当成「P1 把 rc 拉回 1 之后 P3 InPlace 能吃掉」的天花板（2.0–4.3 G cyc）。**这条前提不成立。**

| 原口径 | 订正 |
|---|---|
| 2.32M 是 `add_loc` + `loadOwned` 通胀，q 看 rc==1 | **2.32M 是 `OP_add`。** q 同样 rc≥2，InPlace 进不去 |
| 6.85 GB 是 q 省掉、z 还在拷的量 | **q 也在拷**（`cs1=4.82M`）。lhs>8192 两边都改走绳，4096+ 桶里一部分根本不是拷 |
| P3 申报 1–2 G | **吃不到。** InPlace 只对 `add_loc` 且 rc==1 合法；那池 q 是 443k 命中，不是 2.32M |
| 严格 rc==1 20k 是 z 钩子通胀 | 仍对 **`add_loc` 臂**；但那臂 z 已用绳避开 O(n²)，不是 G 档拷贝 |

订正后的 InPlace 相关上限（仍非裁决）：

- **`OP_add` / 2.32M 池：** 对称成本。要省只能改 `fromCharCode` 循环本身（typed array / 预分配），那是另一个形，不是 slack/InPlace 族，也不是「对齐 q」。
- **`add_loc` 池：** q 443k 原地命中。z P1 之后走绳，拷贝账已经不是 6.85 GB。若再做 flat InPlace，只是换机制对齐 q 的 443k，量级是 lexer token（十到百字符），不是 GB。

---

## 5. 建议

| 项 | 建议 |
|---|---|
| P1 `@fad30cea` | **留支。** 形对 q `19770`（不 Dup 槽）、金丝雀绿、热路径无普查钩。杀门 2.0M rc1 失败是普查口径错，不是刀错。 |
| P1b（z 再融 `add_loc`） | **不立项。** 133=133，热函数逐址同形。 |
| P2 几何类 + usable/destroy | **REJECT。** 服务的是「2.32M 就地」故事；该池 q 自己也不就地。改 String 大块契约没有 pdfjs G 档对象。 |
| P3 flat InPlace | **REJECT（按原 1–2 G 申报）。** 合法命中面是 `add_loc` rc==1，不是 2.32M。z 该面已经绳化。另开小刀「只对齐 q 的 443k add_loc InPlace」需单独设计，不走本族 P3。 |
| 普查 2.0–4.3 G | **作废为 P3 申报上限。** 记为「exclusive flat+flat 的拷贝/绳混合体积」，不是 InPlace 可吃体积。 |

P1 不必回滚。P2/P3 不要按设计书开工。

---

## 6. 纪律

- 未改 `src/`、未开 P2/P3、未动 `test262.conf` / `reports/` / `tools/perf/`。
- 未改官方 `/home/aneryu/quickjs`。计数器只在 `/tmp/qjs-count`。
- 测量 CPU 15。数字非裁决用。
- P1 commit 未动。
