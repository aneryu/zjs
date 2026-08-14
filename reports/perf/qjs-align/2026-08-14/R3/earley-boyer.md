# OPT-R3-E earley-boyer — JS 函数级归因

lane: R3-E / CPU 7（true-inline 复测 CPU 6/7） / **诊断批，非裁决**  
日期：2026-08-14  
config: `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`  
zjs pad0 `12bc8b8a…cf3309d` / qjs `b76d1542…1171364d`

## 结论先行

**该基准 JS 级干净**（胶水层）。引擎级三桶（闭包+var_ref / GC / ctor）落在 `rewrite_nboyer` / `rewrite_args_nboyer` 的算法体（`new sc_Pair`、递归），**不是**可消融的短胶水。

1. 热名单：`one_way_unify1` 36% + `rewrite_nboyer` 28% + `sc_assq` 6% + `rewrite_args` 5%。
2. 第一条写法把 `sc_assq` 包成 IIFE，两侧都变慢；v3 IIFE 组合出现 +0.174pp 假信号（qjs 多付 5%）。已作废，见 `ab/iife-invalid/`。
3. 换写法（while 真内联，无新函数）后：
   - v1 真内联 `sc_assq`：+0.010pp
   - v2 内联 `typeof === "number"` + `===`：−0.018pp
   - v3 组合：+0.026pp
4. ⛔ 不碰 fclosure 常驻 handler。ctor/GC 在 `new sc_Pair` 上，消融它等于改算法，不是胶水。

## Phase 1 — 逐 JS 函数普查

总 opcode 919,097,429；调用 31,110,200；108 函数；overflow=false。  
pc2line 落在函数体内部，按邻近定义对齐。

| 函数 | 调用 | opcode | 份额 | 形态 |
|---|---:|---:|---:|---|
| `one_way_unify1_nboyer` (:4042) | 10,158,650 | 332.5M | 36.18% | unify；调 sc_assq / sc_isNumber / sc_isEqual |
| `rewrite_nboyer` (:4014) | 4,751,200 | 255.8M | 27.83% | 递归 + `new sc_Pair` |
| `sc_assq` (:1426) | 2,558,650 | 56.9M | 6.19% | while `al.car.car === o` |
| `rewrite_args_nboyer` (:4035) | 2,992,150 | 46.9M | 5.10% | 递归分配 |
| `sc_list` (:1188) | 1,117,397 | 35.4M | 3.85% | 列表构造 |
| `sc_isNumber` (:562) | 1,830,400 | 9.2M | 1.00% | `typeof n === "number"` |

## Phase 2 — 源码消融（8 samples，ABBA）

| id | 写法 | z 增益 | q 增益 | 超额 | ~pp | 注 |
|---|---|---:|---:|---:|---:|---|
| v1-IIFE | assq 包成立即函数（作废） | −3.838% | −3.384% | −0.454% | −0.030 | 加调用，无效 |
| v3-IIFE | IIFE+number（作废） | −2.507% | −5.136% | +2.629% | +0.174 | qjs 多伤，假阳性 |
| v1 | while 真内联 `sc_assq` | +0.769% | +0.611% | +0.158% | +0.010 | 有效 |
| v2 | 内联 `sc_isNumber` + `===` | +0.616% | +0.886% | −0.270% | −0.018 | 有效 |
| v3 | v1+v2 真内联 | +1.669% | +1.276% | +0.393% | +0.026 | 有效 |

无候选上三 pad。

## Phase 3 — 机制表

| 机制 | 涉及 JS 函数 | 绝对超出 | 消融证据 | 路径A可修? | 预计 pp |
|---|---|---|---|---|---|
| （胶水层无） | unify / assq / isNumber | 短谓词两侧同价 | 真内联三条 ≤0.026pp | 算法体的 ctor/GC/闭包仍是引擎级三桶，不在 JS 胶水 | — |

引擎级三桶定位：`rewrite_nboyer:4019` / `rewrite_args_nboyer:4035` 的 `new sc_Pair(...)` 是 ctor+GC 的 JS 锚点；`one_way_unify1` 里对 `sc_Pair` 的 `instanceof` 是闭包/形状路径。这些不是「换一种 JS 写法就能拉开超额」的胶水。

## [PROGRESS]

```
[PROGRESS] R3-E census done funcs=108 opcodes=919097429
[PROGRESS] R3-E v1-IIFE INVALID excess=-0.030pp
[PROGRESS] R3-E v3-IIFE FALSE-POSITIVE +0.174pp discarded
[PROGRESS] R3-E v1-true excess=+0.158% ~+0.010pp
[PROGRESS] R3-E v2 excess=-0.270% ~-0.018pp
[PROGRESS] R3-E v3-true excess=+0.393% ~+0.026pp
[PROGRESS] R3-E DONE js-level-clean
```
