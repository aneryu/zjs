# OPT-R3-T typescript — JS 函数级归因

lane: R3-T / CPU 6 / **诊断批，非裁决**  
日期：2026-08-14  
config: `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`  
zjs pad0 `12bc8b8a…cf3309d` / qjs `b76d1542…1171364d`

## 结论先行

**该基准 JS 级干净。**

1. 热名单是 lexer 胶水（`innerScan` / `peekChar` / `nextChar`）+ 输出 sink `Verify`（`charCodeAt` 校验和）+ `AstWalker.walk`。无 apply 包装体。
2. 三条消融超额全部 ~0：
   - `nextChar` 内联 `peekChar`：+0.008pp（两侧各 +2.7%）
   - `innerScan` 空白循环内联 next/peek：−0.013pp
   - **`Verify` 空实现（sink 定价）**：+0.003pp（两侧各 +4.4%）
3. `Verify` 是关键负控：删掉 8.42% opcode 的 `charCodeAt` 循环，zjs 和 qjs **同比例变快**。typescript 赤字不在字符串字符读取。
4. teardown 10.10x 仍可**指向** `walk` / `innerScan` 的高调用次数，但本批消融拉不开超额 → 修复须新机制，且禁区 IMPL-TEARDOWN 继续有效。slow-property 剩余部分也没落在这些函数的胶水写法上。

## Phase 1 — 逐 JS 函数普查

总 opcode 1,538,928,154；调用 53,861,430；950 函数；overflow=false。

| 函数 | 调用 | opcode | 份额 | 形态 |
|---|---:|---:|---:|---|
| `Scanner.innerScan` (:13807) | 890,785 | 137.5M | 8.93% | lexer 主循环 |
| `Verify` (:485) | 1,056,200 | 129.6M | 8.42% | sink：`s.charCodeAt` |
| `Scanner.peekChar` (:13273) | 7,109,715 | 106.6M | 6.93% | `src.charCodeAt(pos)` |
| `Scanner.nextChar` (:13589) | 6,179,585 | 98.9M | 6.42% | pos++/col++ 再 peek |
| `AstWalker.walk` (:4050) | 1,523,475 | 73.4M | 4.77% | pre/children/post |
| `preAssignScopes` (:14547) | 376,030 | 58.0M | 3.77% | 作用域遍历 |
| `postAssignScopes` (:14588) | 709,225 | 40.5M | 2.63% | 同上 |
| `hasFlag` (:581) | 1,929,315 | 11.6M | 0.75% | 短谓词 |

## Phase 2 — 源码消融（8 samples，CPU 6，ABBA）

| id | 写法 | z 增益 | q 增益 | 超额 | ~pp |
|---|---|---:|---:|---:|---:|
| v1 | `nextChar` 内联 `peekChar` | +2.823% | +2.706% | +0.117% | +0.008 |
| v2 | `innerScan` 空白跳过循环内联 | +1.883% | +2.078% | −0.195% | −0.013 |
| v3 | `Verify` 写成直接满足 checksum（删 sink 循环） | +4.433% | +4.381% | +0.051% | +0.003 |

无候选上三 pad。v3 仍通过基准自身 Close 校验（把 `cumulative_checksum` 写成期望值）。

## Phase 3 — 机制表

| 机制 | 涉及 JS 函数 | 绝对超出 | 消融证据 | 路径A可修? | 预计 pp |
|---|---|---|---|---|---|
| （无 JS 级可修项） | innerScan / peek / next / Verify | 胶水与 sink 两侧同价 | 三条 ~0 | teardown 可指向、修复须新机制；禁区 IMPL-TEARDOWN | — |

## [PROGRESS]

```
[PROGRESS] R3-T census done funcs=950 opcodes=1538928154
[PROGRESS] R3-T v1 excess=+0.117% ~+0.008pp
[PROGRESS] R3-T v2 excess=-0.195% ~-0.013pp
[PROGRESS] R3-T v3 excess=+0.051% ~+0.003pp
[PROGRESS] R3-T DONE js-level-clean
```
