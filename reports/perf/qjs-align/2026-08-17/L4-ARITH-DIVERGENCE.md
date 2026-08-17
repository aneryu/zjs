# L4-ARITH-DIVERGENCE — 算术/二元 op 忠实差异

日期：2026-08-17。**只析不改。** CPU **15**。数字非裁决。

| | |
|---|---|
| z | `/home/aneryu/zjs/zig-out/bin/zjs` `repr=tagged` RF · `opBinary` 117319 add / 117327 sub / 117335 mul / 117343 div |
| q | `qjs-04be2460` ≡ `/home/aneryu/quickjs/qjs`（L1 已钉 16B tagged） |
| 源 | z `tailcall_dispatch.zig:2461` · q `quickjs.c:19696–19893` |
| 前账 | `BOX2D-POSTF` +30M BIN · `BOX2D-BIN` 外提 float 已回滚 |
| 反汇编 | `/tmp/lanes/l4-arith/` |
| PMU | `/tmp/lanes/l4-arith/pmu.log` |

---

## 0. 一句话

**`orr 两 tag` int 快门同构。** add/sub/mul/div 的 int 算法、float 混型语义、div 的 `JS_NewFloat64` 规范化，都在镜像 q CASE。箱2d +30M BIN **不是**还没对齐的算法洞。

剩下来看得见的差是 **布局**（q 把 float/`-0` 编到 CASE 外 +6KB 岛；z 留在同一 handler）和 **add 的 miss 序**（z 先探 string，q 先探 float）。把 float 外提去「对齐 q 二进制岛」已经做过（`BOX2D-BIN`），box2d 主尺 **+20.5M / +121M insn**——因为 box2d 的热粮就是混型 float。

**签 L4 算法封条。** box2d 残差里那 +30M 独占，主色是「z 符号含 float、q CASE-mul 独占只采到 int 岛」的记账 + 统一 handler 的 IPC，归微架构弥散。没有可开的 L4 忠实刀。

---

## 1. 现场尺（CPU15 n=1）

| 案 | z cyc | q cyc | z/q | z insn | q insn | z IPC | q IPC |
|---|---:|---:|---:|---:|---:|---:|---:|
| box2d | 1.208G | 1.181G | **1.023** | 5.188G | 5.408G | 4.30 | 4.58 |
| zlib | 13.92G | 15.22G | **0.914** | 63.11G | 89.38G | 4.53 | 5.87 |

与 POSTF 同形：box2d **insn 更少、cyc 略多、IPC 更低**。zlib 算术不是主粮，z 仍大赢。体积账解释不了 box2d 分差。

POSTF（当时 CPU16）：BIN 三件 20.35M 次，独占 **+30.1M cyc**（mul +22.5 / add +2.2 / sub +5.4），占当时 +43M 的 70%。mul **4.71 vs 2.58 cyc/发**。

---

## 2. `orr 两 tag` — 同构

`JS_VALUE_IS_BOTH_INT` = `(tag1 | tag2) == 0`（tag.int = 0）。z `asInt32Pair` 同一折。

| | z mul `1075690` | q mul `23844` |
|---|---|---|
| 折 | `orr x11, x9, x10` | `orr w4, w0, w3` |
| 门 | `cbz` → both-int | `cbnz` → 非 int 岛 |
| 极性 | 同测，跳向相反 | 同 |

add/sub/div 四条都是这一对。**不是忠实偏离。**

---

## 3. 逐 op：int 热臂

两侧都无帧、无 `bl`。q 用 `ldp` 一次搬 16B；z 先 `ldur` 两个 tag 再按需搬 payload（同一 16B 槽）。

### 3.1 mul

**q int** `0x2383c`（~22 insn 到 `br`）：

```
ldp  ×2
orr  tags; cbnz  → 0x29a3c     ; 非 int，+6.2KB
smull
cmp  sxtw; b.ne  → 0x29a28     ; overflow → __JS_NewFloat64
cbz  result      → 0x2a634     ; −0 远岛
stur payload; stur tag=0
dispatch
```

**z int** `10756c4`（同一符号里）：

```
ldur payloads
smull
cmp  sxtw; b.ne  → 同符号 scvtf 存 float
orr  operands; tbz #31         ; −0 留在热臂
cbnz result
… −0 写成 0x8000… / tag 8
else stur int payload
dispatch
```

算法 = q `19836-19852`（overflow 与 −0 都 `__JS_NewFloat64`，不进 slow）。差只是 **−0 / overflow 会不会编出岛**。

### 3.2 add / sub

q add `0x23958` / sub `0x23898`：`orr; cbnz 远岛; sxtw add/sub; overflow → __JS_NewFloat64; stur payload+tag0`。

z add `10758bc` / sub `10757c4`：同算。int 成功臂用 **`fmov d0; stur d0`** 写 payload（GP→FP 再存），q 是 `stur x0`。tag 半字沿用 lhs 的 0，不再写。语义同，int 臂多一次域交叉。

### 3.3 div

源：两侧 both-int 才热；否则 slow。q 用 **`JS_NewFloat64`**（可收回 int），不是 `__JS_NewFloat64`。

q `0x237a0`：`orr; cbnz slow; scvtf×2; fdiv; fcmpe 范围; 可 fcvt 回 int32`。

z `1075580`：同门、同 `scvtf×2; fdiv`，然后 `numberToValue` 降下来的规范化（范围 + `fcvtzs/scvtf` 往返 + 一段 NaN 位运算）。**比 q 长一截，语义同族。** box2d 主粮不是 div。

---

## 4. float 路径（box2d 主粮）

源（q `19710` / `19807` / `19853`）：任一侧 `JS_TAG_IS_FLOAT64` → 另一侧必须是 float **或** int，否则 slow。结果 `__JS_NewFloat64`（**不**收回 int）。z `opBinaryFloat` + `numberValue` = `isInt` 然后 `isFloat64`，同一集合。

### 4.1 二进制布局 — 这才是「差」

| | q | z 今日 |
|---|---|---|
| int CASE | `0x2383c` 一带，~90B | `1075680` 0xf8 的前半 |
| float | **远岛** `0x29a3c`（mul，+0x6200）/ `0x2a30c`（add） | **同一 handler** `cmp #8 / scvtf\|fmov / fmul` |
| −0 / overflow 存 float | 远岛 | 同符号 |

q mul 非 int：

```
29a3c  cmp  tag, #8
       b.eq 更远
       cmp  #0; ccmp 另一侧 #8
       b.ne slow
       scvtf / fmov; fmul
       回到 int CASE 的 store+dispatch
```

z mul 非 int：同一 248B 里做完。源码「float 仍在 CASE」——z 更贴源；q 编译器把 float 拆走。

### 4.2 add 的 miss 序 — 唯一源序差

q `2a30c`（int miss 之后）：**先 `cmp #8` float，再 `add #7` string**，最后 `js_add_slow`。与 `quickjs.c:19710` 然后 `19729` 同序。

z add `1075898`：int miss 之后 **先 `tag+7` 探 string**（两 tag orr，`cmp #1; b.hi` 才进 float），string 命中 `br` `op_add_strings`。

float 加：z 每发多 4 条 string 哨。5.15M × ~0.5–1 cyc ≈ **2–5M**，盖不住 +30。可对齐（把 float 哨挪到 string 前），预算小。

mul/sub 无 string 臂，无此序差。

### 4.3 canonicalize

| 存 | q | z |
|---|---|---|
| int overflow / 混型 float 结果 | `__JS_NewFloat64` 永远 tag=8 | `JSValue.float64` 同 |
| both-int **div** | `JS_NewFloat64` 可收回 int32 | `numberToValue` 同族（z 机码多 NaN 位测） |
| 混型 **不**收回 int | 两侧都是 | 同 |

没有「z 多做一遍 NaN-box 规范化」这种 L1 幻觉。16B tagged 上 float 就是 payload=IEEE、tag=8。

---

## 5. +30M 怎么读

POSTF 把 z `opBinary 117335` **整符号** 49.7M 对 q **CASE mul 岛** 27.2M。

q 的 `fmul` 在 `0x29a58` / `0x2ab68`，不在 `0x2383c–0x23894` 的 int CASE。若 annotate 按「CASE 标签～下一条 CASE」切，**q 的混型 float 不进 27.2**。z 的 float 与 int 在同一 0xf8，**全进 49.7**。

`BOX2D-BIN` 反证：几乎每发 mul/add/sub 都 miss both-int（外提 float 后 +6 insn/op × 20.35M = +121M insn，量对上）。所以 10.56M mul 的主流量是 **混型 float**。q 那 2.58 cyc/发是 **int 岛的单价**，不是 float 岛的单价。

**+22.5M 不是「同一条 float 臂贵 2.1 cyc」。** 是符号边界不对称。把 q 的 `0x29a3c` 岛加回去，独占会窄一截。剩下的才是真 IPC（z 热符号里塞了 float 梯，int 叶 I$ 变脏；q int 叶更瘦）。

zlib 算术不是主色，本尺 z 仍 0.91×。

---

## 6. 有差：折税 + 可行性

| 差 | 税 | 对齐 | 可行？ |
|---|---|---|---|
| float 留在 handler vs q 远岛 | POSTF 记账上的 +30；真 IPC 未知且 **小于** 符号差 | 外提 float = `BOX2D-BIN` | **已做，主尺 +20.5M。禁再开。** box2d 热的是 float，hop 反 q 源、反付款面 |
| add miss：string 先于 float | 2–5M | 对调两哨，贴 `19710` 再 `19729` | 形合法，**不够 30M / 不够立项** |
| add/sub int 成功 `fmov/stur d` | 只打 both-int | 改 `stur` GP，贴 q | int 热才赚；box2d 不是 |
| mul `−0` 留热臂 | 1–2 条未采取 | 外提贴 q 岛 | 与 BIN 同罪；源码 q 也在 CASE |
| div 规范化多一段 NaN 位测 | box2d 非主粮 | 可削 | 不立项 |

「热臂收成 q：`orr+cbnz` 非 int → 冷岛」这条 POSTF 主刀，建立在「q 热臂只有 smull」上。源码有 `mul_fp_res`；二进制只是把 float **编远**。当付款面是 float 时，学 q 的远岛 = 给热路径加 hop。已否。

---

## 7. 封条

**L4 算法封条：签。**

- int 快门 `orr` 同构。
- add/sub/mul overflow 与 mul `−0` 都在 handler / CASE，不进 `binary_arith_slow`。
- 混型 float 集合（float\|\|int）与 `__JS_NewFloat64` 结果同。
- div both-int + `JS_NewFloat64` 同族。
- 唯一源序差（add string/float）预算个位数 M。

box2d +30M BIN **不再当「没对齐的算术语义」开刀。** 归：

1. 独占记账不对称（z 符号含 float，q CASE-mul 不含）；
2. 统一 handler 的 I$/IPC（体积已比 q 少，cyc 仍略多）——微架构弥散；
3. POSTF 里其余已点名、非本层：IF8-OBJ +8、CMP-EQ 帧、PUT 卫星。

禁：再外提 add/sub/mul 的 float 臂（负定理：BIN 尸检）。顺手级：add 两哨对调，不单独立项。

---

## 8. 请收

- 产物：`/tmp/lanes/L4-ARITH-DIVERGENCE.md`
- 反汇编：`/tmp/lanes/l4-arith/{z,q}-*.s`
- 合 main：无
- 候组包：无
- 下一层若继续往上：不是再削 `smull`/`fadd`，是 IPC/IF8/CMP 那些已点名的非算术税
