# R8-C PRICES — L7–L8 帧 / 调用 / `new` 阶梯

lane: R8-C / CPU 8 / 诊断批，src 只读  
**直接喂 R7-R1。** 8-sample pad0 + 4-sample pad3/7。

## 结论先行（订正 R7-R1）

**3 字段 simple `new Three(1,2,3)` 已经是 ZJS-ADVANTAGE（0.871，Δ −49）。**  
同字段字面量 0.902（Δ −26）。**「让 N3 逼近字面量」不是 +1.7pp 主线。**

R7 s8 塌缩来自 **G 形 ctor**（`initialize.apply(this, arguments)` / 只转发 initialize）：

| 形状 | z cyc/次 | q cyc/次 | Δ | z/q | 帧核证 |
|---|---:|---:|---:|---:|---|
| **N3** `new Three` 三字段在 ctor 体 | 346 | 395 | **−49** | **0.871** | `call_frames=2` **bypass** |
| **N3g** 多一个 local，破 bypass | 492 | 418 | **+74** | 1.161 | `call_frames=N` 真帧 |
| **N0** `new Empty()` 无字段 | 231 | 140 | **+92** | **1.553** | `call_frames=N` |
| **G** apply+initialize | **1007** | **701** | **+306** | **1.419** | frames=2N，`special_object`=N（arguments） |
| **O3** `{x,y,z}` | 266 | 292 | −26 | 0.902 | `object`+3×`define_field`，无帧 |

194 vs 150 的 44 cyc ≈ **N0**（231 vs 140 = +91，含循环边）。  
N3 走 bypass 之后 **比 qjs 还便宜 49**。缺口在「没打上 bypass 的 ctor」。

raytrace census：`call_constructor` 2.531M ≈ `special_object` 2.531M —— **宏观就是 G**（每次 new 都造 arguments）。  
2.531M × 306 Δ ≈ **774M / 934M = 83%** 的 raytrace 超出。这才是 R7-R1 该实施的形状。

## 1. `new` 0/1/2/3 vs 字面量阶梯

同 N=5e6，ctrl 差分：

| 字段 | new z | new q | new Δ | lit z | lit q | lit Δ | new−lit z | new−lit q |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 231 | 140 | +92 | 83 | 77 | +7 | +148 | +63 |
| 1 | 260 | 248 | +12 | 169 | 156 | +13 | +91 | +92 |
| 2 | 300 | 307 | −7 | 216 | 214 | +2 | +84 | +93 |
| 3 | 346 | 395 | −49 | 266 | 292 | −26 | +80 | +103 |

分解：

- **alloc**：O0 Δ +7（小正，不是路径错；`object`×N）。
- **每字段字面量**：(O3−O0)/3 ≈ z 61 / q 72 / Δ −11。
- **bypass 门槛**：N0 无字段写 → 真帧 +92。N1 起 `call_frames=2`。
- **N3 vs O3**：zjs `new` 比字面量贵 80 cyc，qjs 贵 103。所以 z/q 上 N3 反而赢。
- **G vs N3**：z 1007−346 = **+661 cyc** 纯包装税（apply + arguments + 二次调用）。

## 2. 调用 / teardown

| id | 形状 | z/次 | q/次 | Δ | z/q |
|---|---|---:|---:|---:|---:|
| A_direct | `f(1,2)` 空体丢弃 | 59.4 | 41.3 | **+18.1** | 1.234 |
| ret_undef | `f(); s++` | 55.9 | 42.5 | +13.4 | 1.152 |
| ret_int | `s += f()` 返回 1 | 60.7 | 51.5 | +9.2 | 1.073 |
| A2 | `s += f(1,2)` 有加法 | 73.2 | 63.4 | +9.9 | 1.070 |
| B | `o.f(1,2)` | 91.0 | 83.3 | +7.8 | 1.036 |
| ret_obj | `f()` 返回 `{x:1}` | 226 | 201 | +25 | 1.096 |

旧锚「teardown 19.26 vs 1.93」：**不能复现为 qjs teardown≈2**。空调用两侧都是 40–60 cyc，Δ +13~18。1.93 是当时共享标签低估。诚实数字：调用税 **+10~+18 cyc**，setup/teardown 拆不开到 10:1。

路径：A_direct `call2`=N + `return_undef`=N + `call_frames`=N。

## 3. 三 pad（结论条，零翻转）

| | pad0 n=8 | pad3 n=4 | pad7 n=4 |
|---|---:|---:|---:|
| N0 new Empty | 1.5527 | 1.5514 | 1.5500 |
| N3 new Three | 0.8712 | 0.8797 | 0.8700 |
| O3 lit3 | 0.9024 | 0.8990 | 0.9054 |
| G apply ctor | 1.4191 | 1.4223 | 1.4143 |
| A direct call | 1.2335 | 1.2279 | 1.2253 |

## 4. 修订候选（只登记）

| id | 方向 | 分类 | 依据 | 上限 |
|---|---|---|---|---|
| **R8-C1** = 修订 **R7-R1** | 让 `initialize`/`apply` 转发 ctor 打上 N3 simple-field bypass（`call_frames=0` 热路径，无 `special_object`） | FAITHFUL-FIXABLE | raytrace 2.53M × (G 1007−N3 346) ≈ 1.67G z 侧；Δ 差 306−(−49)=355 × 2.53M ≈ **898M** / 934M | 与 R7 s8 同量级，geomean ~+1.7pp **上限** |
| R8-C2 | 空 `new Empty` 真帧（N0 +92） | 观察 | 无字段 ctor 少 | 不够单独立项 |
| R8-C3 | 空调用 +18 | 已有 R6-K 去 0x220 | 边际 | <0.4pp |

**不要**把 R7-R1 理解成「N3 去字面量化」。N3 已经 0.87×。

## 不要做

- 不要删 bypass 换九-opcode 通用体（N3g 1.16，账面变差）。
- 不要重开 H3。
- 不要把 s8 字面量写法当产品补丁。
