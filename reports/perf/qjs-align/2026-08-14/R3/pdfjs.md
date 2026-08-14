# OPT-R3-P pdfjs — JS 函数级归因

lane: R3-P / CPU 5 / **诊断批，非裁决**  
日期：2026-08-14  
config: `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`  
zjs pad0 `12bc8b8a…cf3309d` / qjs `b76d1542…1171364d`

## 结论先行

**该基准 JS 级干净。** 这是路径 B 裁决的直接证据。

1. 本轮普查复现 D11 热名单：`FlateStream_getCode` 20%、`extractFontProgram` 12%、`decrypt` 8%。两侧总 opcode 在 D11 已是 0.9973。
2. D11 已否决 getCode 内联（三 pad 全恶化 −0.77% ~ −1.03%）。本 lane **换三条未测写法**，全部超额 < 0.04pp：
   - `executeOperatorList` 的 `this[fnName].apply` → arity-switch + `call`：+0.035pp
   - `ctx.transform.apply` → 6 实参直调：+0.022pp
   - `isSeparator` 谓词内联：+0.038pp
3. 最大的「RayTrace 同类」形态（`apply` 动态派发）消融几乎为零。pdfjs 60% 未具名残差 **不能**再从一个 JS 函数名或胶水写法下刀。
4. 下一步若还要挖路径 A，必须离开 JS 函数粒度（数组元素 / typed-array backing / 分配与 GC 宏观路径）——那已不是本批方法。

## Phase 1 — 逐 JS 函数普查

总 opcode 234,995,232；调用 1,570,727；410 函数；overflow=false。

| 函数 | 调用 | opcode | 份额 | 形态 |
|---|---:|---:|---:|---|
| `FlateStream_getCode` (:28035) | 498,870 | 47.2M | 20.10% | 长循环；D11 消融否决 |
| `Type1Parser_extractFontProgram` (:17348) | 45 | 28.1M | 11.97% | 少调用大体 |
| `decrypt` (:17049) | 2,320 | 19.1M | 8.14% | 字节循环 |
| `flateStreamGenerateHuffmanTable` (:28063) | 150 | 16.9M | 7.19% | 少调用 |
| `DecodeStream_ensureBuffer` (:27741) | 425 | 15.9M | 6.77% | 数组扩容 |
| base64 body (:558) | 45 | 14.3M | 6.10% | 少调用 |
| `FlateStream_readBlock` (:28100) | 55 | 12.4M | 5.29% | 少调用 |
| `isSeparator` (:17344) | 382,710 | 5.5M | 2.32% | 三字符谓词 |
| `executeOperatorList` apply (:2732) | — | 低 | — | `this[fnName].apply(this, args)` |

## Phase 2 — 源码消融（8 samples，CPU 5，ABBA）

| id | 写法 | z 增益 | q 增益 | 超额 | ~pp |
|---|---|---:|---:|---:|---:|
| v1 | apply → arity 0–6 `call`，其余回落 apply | +0.291% | −0.242% | +0.533% | +0.035 |
| v2 | `transform.apply` → 6 实参直调（8 处） | +0.188% | −0.148% | +0.336% | +0.022 |
| v3 | `isSeparator(x)` → `(x==' '\|\|x=='\\n'\|\|x=='\\x0d')` | +1.059% | +0.488% | +0.571% | +0.038 |

无候选达到 0.15pp，不上三 pad。  
`v3-issep-iife.js` 曾语法错误，已删；有效用例是 `v3-issep-inline.js`。

## Phase 3 — 机制表

| 机制 | 涉及 JS 函数 | 绝对超出 | 消融证据 | 路径A可修? | 预计 pp |
|---|---|---|---|---|---|
| （无） | 热函数 + apply 胶水 + isSeparator | D11 残差 ~137M cyc / 60% 仍未具名 | 三条新写法 + D11 getCode 全 <0.04pp 或为负 | 不在 JS 函数粒度 | — |

## [PROGRESS]

```
[PROGRESS] R3-P census done funcs=410 opcodes=234995232
[PROGRESS] R3-P v1 excess=+0.533% ~+0.035pp
[PROGRESS] R3-P v2 excess=+0.336% ~+0.022pp
[PROGRESS] R3-P v3 excess=+0.571% ~+0.038pp
[PROGRESS] R3-P DONE js-level-clean
```
