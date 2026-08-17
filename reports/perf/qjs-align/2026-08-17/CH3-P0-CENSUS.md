# CH3-P0-CENSUS — 通道 #3 分派形态 P0 普查

日期：2026-08-17。**只读普查，无产品码，不进岛，不占 254/255，无 commit。**  
基 `main@9deb9f45`（wave-41 pdfjs-L1）。工装在 `/tmp/wt-ch3-p0` 未提交钩子（`ZJS_CH3_CENSUS`），**未合 main**。  
生产形：`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`（二进制 `--print-config-signature` 自报）。  
夹具：`/tmp/r5/fixed/*.js` 15/15。测量核 **CPU 8**（`taskset -c 8`）。避核 5/6/7（w42 组包窗）与 19。编译核 0-4,8-14。  
合同：`/tmp/lanes/CH3-DISPATCH-SPIKE.md` + 用户 A 线裁决两修正 **R1 / R2**。  
原始：`/tmp/ch3-p0/win-*.tsv` + `summary.json`；分类器 `/tmp/lanes/ch3-p0/analyze.py`。

---

## 0. 判决

**P0 杀门未过。按 R2：通道 #3 v1 = REJECT-ARCHIVE。不进 P1，不试探占槽。**

机制仍合宪（spike 已 APPROVED）。矿尽：融合之后、§1.3 切开的小组件 3/4 原子直线窗，zoo 并集第一名只有 **39.17M hop**。  
合同折算 `hop × 0.2–0.4 cyc/预测 br` = **7.8–15.7M cyc < 30M**。硬门。

| 项 | 值 |
|---|---|
| 冠军形（小组件 3） | `get_loc8 → mul → get_loc8` |
| zoo Σ | **39,169,178** |
| 主付款 | crypto 38,621,430（98.6%）；box2d 547,748 |
| ×0.2 / ×0.3 / ×0.4 | 7.83 / 11.75 / 15.67 M cyc |
| 30M 所需 hop | 75–150M（§4.1） |
| 差 | 第一名只有门槛的 **26–52%** |
| 冠军形（小组件 4） | `push_1 → shl → add → push_1` 23.90M（zlib 100%）→ 4.8–9.6M cyc |
| 全形 3 第一名 | **同一形** 39.17M（肥窗没有另开更大矿） |

不预选「像 zlib 的 push/loc/add」——表自己把头排到 crypto 乘法链和 zlib `shl/add`。两者都过不了门。

P1 占槽按 R2 **释放**：254/255 仍空。不写区域 handler，不进岛。工装钩子丢弃（不入库）。

---

## 1. 入合同的两修正（本普查已遵守）

| 修正 | 文 | 本轮动作 |
|---|---|---|
| **R1** | 冷表项禁止另写「按形解释」慢体。区域 id 冷表项直接指 **首原子原 handler**（形静态已知、操作数字节未动、原 handler 逐字可用）。依赖偷看的 fused 首原子形已被 spike §3 / leftover 梯排除。 | P0 不实现冷表。选型已排除 `PEEK_HEAD`（`get_loc8_push_{0,1,2,i8}` / `get_var_ref0_get_loc8`）。合法小组件列里 **peek-head = 0 条**。若将来有人重开，冷表必须指回改写前的首原子 handler，不得新写一份形解释器。 |
| **R2** | P0 杀门为 **硬门**。折算 <30M cyc 即 **REJECT-ARCHIVE**，不准用「先占 254 看微核」试探。 | 本文件即归档理由。下面的「即使把折算放宽」也过不了诚实上限，不构成占槽借口。 |

---

## 2. 方法（对照 §1.3）

### 2.1 工装

- 孤岛 worktree `/tmp/wt-ch3-p0` @ `9deb9f45` + 未提交 `tailcall_dispatch.zig` 174 行。  
  `next` 记 `last_pc` 并切断 ring（跳入 / L0 / 函数入场）；`cont` 在 `npc == last_pc + sizeOf(A)` 时累加 3-gram（256³ `u32`）和 4-gram（1M 槽开放寻址）。  
  `atexit` 写 `3 a b c names n` / `4 a b c d names n`。  
  **env 未设时 `ensure()` 立即 off**——热路径不进表。本普查每案 `ZJS_CH3_CENSUS=/tmp/ch3-p0/win-<bench>.tsv`。
- 已融 id 是 1 原子（`sizeOf(fused)` 一步跨过 leftover）。与 §1.3「已融合 id 算 1 原子」同构。
- 钩子 **不进岛**（`cont` 里 `inline` 计数，env off 为零）。profile 计数器未开。
- 15 案全部 rc=0，stderr 空。分数与日常 RF 同量级（Crypto 501 / zlib 1499 / Mandreel 662 / Box2D 2530 / TS 12272）。

### 2.2 窗口切开（动态 = 静态 §1.3 的上界）

| §1.3 条 | 工装如何兑现 |
|---|---|
| 连续 op；已融 = 1 原子 | `npc == last_pc + sizeOf(A)`；fused 一步 |
| 除窗首外无入边（label / catch / leftover 跳入 / using 切点） | 跳入走 `next` → ring 清零。**但** A 落到 B（B 另有入边）的 fallthrough 仍记账。故动态 n-gram **≥** 静态合法窗。REJECT 用上界，不漏杀。 |
| 窗内无 `call*` / `return*` / `await` / `yield*` / `throw*` / poll；jump 切窗 | `analyze.py`：`JUMP` 全窗弃；`POLL` 不得出现在非窗尾（全形允许 poll 尾，v1 小组件连尾也不收） |
| 长 3..4；2 原子 = 通道 #2 不占槽 | 3-gram / 4-gram 分表 |
| 形 = opcode 元组；zoo **并集** 动态权重 | 15 案 `Counter` 相加，禁单基准拟合 |
| 首原子依赖偷看 → 回避 | `PEEK_HEAD` 不进冠军；本轮小组件列无此类 |

### 2.3 两列

- **全形** `legal_all`：无 jump；无中间 poll。含肥 op（`get_field*` / `get_array_el` / `put_field` / `put_array_el` / `call_method*`）。**只说明论，v1 不收。**
- **小组件** `legal_small`：再要求全窗 ∈ `SMALL` 且 ∉ `FAT`/`POLL`。`SMALL` = `get/put/set_loc*`、`push_*`、`drop/dup/swap`、arith-cmp（含 `add/mul/shl`）、`get_var*`/`get_arg*`、已融小组件（`get_loc8_push_*`、`push_0_or`、`cmp_if_false8`、`sar_get_array_el` 等）。

`sar_get_array_el` / `get_array_el_push_0` 按「已融原子」进了 `SMALL`。若审阅把它们当肥尾巴踢出，小组件 3 的第 6 名（`add → push_1 → sar_get_array_el` 24.43M）掉列，**冠军不变**。

### 2.4 折算

spike P0 原文：「小组件列第一名动态 hop × 1 `br` … 0.2–0.4 cyc/预测 br，或 hop×0.3」。  
用户派单：「冠军形 hop×0.2~0.4 cyc 折算 30M」。  
§4.1：「30M cyc ≈ 75–150M 被消 hop」。  
**官方尺 = 窗频次 × 0.2–0.4。** 3 原子窗纸面上省 2 跳，放宽算法写在 §3.2，不改判决。

---

## 3. 冠军与 30M

### 3.1 官方折算（R2 硬门）

| 列 | 形 | hop | ×0.2 | ×0.3 | ×0.4 | vs 30M |
|---|---|---:|---:|---:|---:|---|
| 小组件 3 | `get_loc8 → mul → get_loc8` | 39.17M | 7.83 | 11.75 | **15.67** | **FAIL** |
| 小组件 3 #2 | `get_loc3 → get_loc8 → mul` | 38.84M | 7.77 | 11.65 | 15.54 | FAIL（与 #1 同 crypto 链，不可并计入目录） |
| 小组件 3 #3 | `shl → add → push_1` | 35.72M | 7.14 | 10.72 | 14.29 | FAIL |
| 小组件 4 | `push_1 → shl → add → push_1` | 23.90M | 4.78 | 7.17 | 9.56 | FAIL |
| 全形 3 | 同小组件冠军 | 39.17M | 15.67 封顶 | | | 肥窗没把第一名抬上去 |

### 3.2 放宽也不构成占槽理由（非官方尺）

| 放宽 | 算法 | 结果 | 为何仍拒 |
|---|---|---|---|
| 3 原子省 2 `br` | 39.17M × 2 × 0.2–0.4 | 15.7–31.3M | 只有 0.4 乐观端刚贴 30M；付款 98.6% 在 **crypto**（非 3-pad 主尺 zlib/mandreel）；R2 禁止「贴线就占槽」 |
| 4 原子省 3 `br` | 23.90M × 3 × 0.2–0.4 | 14.3–28.7M | 仍 <30M |
| 两槽并集、不重叠 | crypto 冠军 + zlib 冠军 74.89M × 0.2–0.4 | 15.0–**29.96M** | 乐观端仍 <30M；且要占满 254+255 才摸到纸面，R2 连一槽都不许试 |
| #1+#2 相加 | 39.17+38.84 | — | **禁止。** 同是 crypto SHA 热环前后缀，目录两形会双计同一圈 |

### 3.3 切窗弃掉的近线（证明工装没漏 50M 矿）

| 形 | hop | 弃因 |
|---|---:|---|
| `push_0 → gte → if_false8` | 36.18M | jump（`if_false8`） |
| `gte → if_false8 → get_loc0` | 19.41M | jump |
| `and → put_array_el → goto8` | 19.68M | jump + 肥 `put_array_el` |

2-op 层 SUPERCHAIN 仍见 `add→push_0_or` 133M 等——那些是通道 #2 已收 / 已定性的对，不是本通道 3/4 窗。

---

## 4. 3-原子窗口（zoo 并集，按 hop 降序）

### 4.1 全形（说明论；v1 不收肥体）

| # | hop | 形 | 主付款 | small? | 注 |
|---:|---:|---|---|---|---|
| 1 | **39.17M** | `get_loc8 → mul → get_loc8` | crypto 38.62 | 是 | 冠军 |
| 2 | 38.84M | `get_loc3 → get_loc8 → mul` | crypto 38.61 | 是 | 同环前缀 |
| 3 | 37.60M | `sar → get_loc8 → put_array_el` | mandreel 25.24 | **否** | 肥 `put_array_el` |
| 4 | 35.72M | `shl → add → push_1` | zlib 35.72 | 是 | compute 主尺上最大 |
| 5 | 28.60M | `put_loc8 → get_var → get_loc8_push_i8` | mandreel 28.60 | 是 | fused 尾；leftover 先例 |
| 6 | 28.17M | `get_loc8 → add → push_0_or` | zlib 18.63 | 是 | 前缀拆散的 2-op 大对 |
| 7 | 27.10M | `push_i32 → and → put_array_el` | crypto 19.31 | **否** | 肥 |
| 8 | 26.26M | `get_loc8 → put_array_el → get_var` | mandreel 26.26 | **否** | 肥 |
| 9 | 24.43M | `add → push_1 → sar_get_array_el` | zlib 23.89 | 是* | *已融肥尾巴，见 §2.3 |
| 10 | 23.97M | `push_1 → shl → add` | zlib 23.97 | 是 | 4-窗冠军的前缀 |
| 11 | 23.07M | `get_loc8 → push_i16 → and` | crypto 19.31 | 是 | |
| 12 | 22.65M | `get_loc8 → push_i32 → and` | crypto 19.31 | 是 | |

peek-head：本表前 30 名 **无**。

肥窗单独看：含 `get_array_el` 的全形 3 头是 `get_array_el → push_i8 → sar` **20.53M**（crypto）。`get_field` 链在 TS/box2d 分案里（§6），并集进不了前 12。**v1 就算违宪收肥，也没有 ≥75M 的 3 窗。**

### 4.2 小组件（v1 候选列）

| # | hop | 形 | 主付款 | ×0.4 cyc |
|---:|---:|---|---|---:|
| 1 | **39.17M** | `get_loc8 → mul → get_loc8` | crypto 38.62 / box2d 0.55 | 15.67 |
| 2 | 38.84M | `get_loc3 → get_loc8 → mul` | crypto 38.61 | 15.54 |
| 3 | 35.72M | `shl → add → push_1` | zlib 35.72 | 14.29 |
| 4 | 28.60M | `put_loc8 → get_var → get_loc8_push_i8` | mandreel 28.60 | 11.44 |
| 5 | 28.17M | `get_loc8 → add → push_0_or` | zlib 18.63 | 11.27 |
| 6 | 24.43M | `add → push_1 → sar_get_array_el` | zlib 23.89 | 9.77 |
| 7 | 23.97M | `push_1 → shl → add` | zlib 23.97 | 9.59 |
| 8 | 23.07M | `get_loc8 → push_i16 → and` | crypto 19.31 | 9.23 |
| 9 | 22.65M | `get_loc8 → push_i32 → and` | crypto 19.31 | 9.06 |
| 10 | 22.61M | `add → add → push_0_or` | zlib 22.61 | 9.04 |
| 11 | 20.77M | `get_loc8 → mul → add` | crypto 19.32 | 8.31 |
| 12 | 20.18M | `push_i16 → and → put_loc8` | crypto 19.31 | 8.07 |

其后 crypto 乘法/移位环在 19.3–20.1M 一把（`put_loc8 → get_loc3 → get_loc8`、`and → push_i8 → shl`、`get_loc8 → inc → set_loc8` 的 navier 19.93M 等）。没有第二条独立矿脉。

唯一计数：3-gram 18,454 形；`legal_all` 16,147；`legal_small` 7,230。长尾，无隐藏冠军。

---

## 5. 4-原子窗口

### 5.1 全形

| # | hop | 形 | 主付款 | small? |
|---:|---:|---|---|---|
| 1 | **23.90M** | `push_1 → shl → add → push_1` | zlib 23.90 | 是 |
| 2 | 22.91M | `sar → get_loc8 → put_array_el → get_var` | mandreel 22.91 | **否** |
| 3 | 20.74M | `shl → add → push_1 → sar_get_array_el` | zlib 20.74 | 是* |
| 4 | 20.67M | `dec → set_arg → push_0 → gte` | crypto 20.67 | **否**（`set_arg` 非 SMALL） |
| 5 | 20.67M | `get_arg → dec → set_arg → push_0` | crypto 20.67 | **否** |
| 6 | 19.79M | `and → push_i8 → shl → add` | crypto 19.79 | 是 |
| 7 | 19.60M | `put_loc8 → get_loc2 → get_loc8 → mul` | crypto 19.31 | 是 |
| 8 | 19.45M | `get_loc3 → get_loc8 → mul → add` | crypto 19.31 | 是 |

4-gram 再把 3-窗拆一刀，质量只减不增。唯一：30,170 形；`legal_small` 7,882。

### 5.2 小组件

| # | hop | 形 | 主付款 | ×0.4 cyc |
|---:|---:|---|---|---:|
| 1 | **23.90M** | `push_1 → shl → add → push_1` | zlib 23.90 | 9.56 |
| 2 | 20.74M | `shl → add → push_1 → sar_get_array_el` | zlib 20.74 | 8.29 |
| 3 | 19.79M | `and → push_i8 → shl → add` | crypto 19.79 | 7.92 |
| 4 | 19.60M | `put_loc8 → get_loc2 → get_loc8 → mul` | crypto 19.31 | 7.84 |
| 5–12 | 19.31–19.45M | crypto 乘法环四连（`get_loc3/get_loc8/mul/add` 等） | crypto | ≤7.78 |

---

## 6. 分案头（小组件 3 / 全形 3 / 小组件 4）

| 案 | small-3 | M | all-3（若不同） | small-4 | M |
|---|---|---:|---|---|---:|
| **crypto** | `get_loc8 → mul → get_loc8` | **38.62** | 同 | `and → push_i8 → shl → add` | 19.79 |
| **zlib** | `shl → add → push_1` | **35.72** | 同 | `push_1 → shl → add → push_1` | **23.90** |
| **mandreel** | `put_loc8 → get_var → get_loc8_push_i8` | 28.60 | 同 | `get_var → push_4 → div → cmp_if_false8` | 11.93 |
| **navier-stokes** | `get_loc8 → inc → set_loc8` | 19.86 | 同 | `get_arg1 → get_loc8 → inc → set_loc8` | 16.12 |
| richards | `get_var → and → push_0` | 5.47 | `put_loc1 → get_loc1 → get_field` 5.59 | `and → push_0 → neq → dup` | 5.47 |
| earley-boyer | `put_loc8 → get_loc8 → get_loc8` | 3.71 | `get_loc8 → get_loc8 → put_field` 7.46 | 4×`get_var_ref` | 1.33 |
| gbemu | `get_loc8 → post_inc → put_loc8` | 3.07 | 同 | `get_loc1 → get_loc3 → post_inc → put_loc3` | 2.07 |
| box2d | `get_loc8 → mul → add` | 1.24 | `get_loc1 → get_field → get_field` 1.91 | `get_loc8 → mul → sub → mul` | 0.59 |
| typescript | `shl → get_loc1 → xor` | 1.19 | `get_var_ref0 → get_field → get_field` 6.55 | `push_1 → shl → get_loc1 → xor` | 1.19 |
| pdfjs | `dup → push_atom_value → strict_eq` | 1.39 | 同 | loc 四连 | 0.53 |
| raytrace | `mul → add → get_loc0_field` | 1.01 | `get_arg0 → get_field → get_arg1` 3.24 | `dup → push_0 ×3` | 0.95 |
| splay | `get_arg0 → push_0 → eq_if_false8` | 0.95 | 同 | `get_arg0 → push_1 → sub → get_arg1` | 0.93 |
| deltablue | `set_loc3 → get_loc0 → neq` | 0.48 | `get_arg0 → get_array_el → return` 4.10 | — | 0.28 |
| regexp | `push_0 → put_loc0 → get_arg0` | 0.42 | `get_loc1 → get_length → cmp_if_false8` 1.23 | — | 0.42 |
| code-load | ~0 | — | `insert2 → put_field → put_loc0` 0.01 | — | ~0 |

架构段（box2d / TS / EB）的 hop 在 `get_field` 上，v1 合同吃不到；吃到了并集也只有 6.6M 级。splay 残矿前案已见底，本表证实没有 3-窗可搬。

---

## 7. 对照 SUPERCHAIN（2026-08-16，`main@8d6ae58c`，CPU 16）

同一 fallthrough 3-gram 工装族。当时物理下限是 **50M hop**（8 insn/边），合法清单空。

| 形 | SUPERCHAIN | 本 P0 (`9deb9f45`) |
|---|---:|---:|
| `get_loc8 → mul → get_loc8` | 39.2M | **39.17M** |
| `get_loc3 → get_loc8 → mul` | 38.8M | **38.84M** |
| `sar → get_loc8 → put_array_el` | 37.6M | **37.60M** |
| `shl → add → push_1` | 35.7M | **35.72M** |
| `put_loc8 → get_var → get_loc8_push_i8` | 28.6M | **28.60M** |

wave-41 pdfjs-L1 没有改 compute 窗分布。本轮新加 4-gram：头 23.90M，更矮。  
通道 #3 把杀门从「50M hop / 8 insn」改成「hop × 0.2–0.4 cyc vs 30M」——更贴 DT 已证的预测 `br` 单价——**结论同向：没有可立项的 3/4 窗。**

---

## 8. 明确不做

- **不占 254/255。** R2 硬门。P1 预留槽释放，候用户关槽。
- **不写** `op_region_*`、不改 emit、不进岛、不钉 `get_field`/`if_false8` 址。
- **不**把 `add`/`mul` 当「再融一对」重开通道 #2（物理下限 + 克隆族已结）。
- **不**为凑 hop 把 jump/poll 窗、肥 `get_field`/`get_array_el` 收进 v1。肥 hop 要另案「共享热臂、LLVM 保证不克隆」。
- **不** sidecar / DT / 加参 / mini-JIT。
- 工装钩子 **不入库**。`/tmp/wt-ch3-p0` 可丢。main 无 `ZJS_CH3_CENSUS`。
- 本文件在 `/tmp/lanes/`，**不**自动入 `reports/` / ledger。入档另令。

---

## 9. 证据

| 件 | 路径 |
|---|---|
| spike + R1/R2 | `/tmp/lanes/CH3-DISPATCH-SPIKE.md` |
| 分类器 | `/tmp/lanes/ch3-p0/analyze.py` |
| 并集 JSON（顶 30/20） | `/tmp/ch3-p0/summary.json` |
| 分案 TSV | `/tmp/ch3-p0/win-{15 benches}.tsv`（69,208 行） |
| 分案 stdout / rc | `/tmp/ch3-p0/{bench}.{out,err}`（err 全 0 字节，rc=0） |
| 普查二进制 | `/tmp/wt-ch3-p0/zig-out/bin/zjs`（2026-08-17 01:29，RF，31,728,928 B） |
| 钩子 diff | `/tmp/wt-ch3-p0` `src/exec/tailcall_dispatch.zig` +174，未提交 |
| 前史 | `/tmp/lanes/SUPERCHAIN.md` |

复验：

```bash
# 分类器只读重放（不跑 zoo）
python3 /tmp/lanes/ch3-p0/analyze.py
# 冠军：CHAMP small3 (39169178, get_loc8 → mul → get_loc8)
#        CHAMP small4 (23899800, push_1 → shl → add → push_1)
```

---

## 10. 一句话回用户

通道 #3 v1 **P0 REJECT-ARCHIVE**：zoo 并集、融合后、§1.3 切窗，小组件冠军 `get_loc8→mul→get_loc8` 39.17M hop × 0.2–0.4 = 7.8–15.7M cyc，硬门 30M 未过。全形列同一头。4 原子更矮。R1 已遵守（无 peek-head 候选）。R2 禁止占槽。254/255 空。P1 不开工。
