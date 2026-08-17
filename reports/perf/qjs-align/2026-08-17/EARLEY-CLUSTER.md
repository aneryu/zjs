# EARLEY-CLUSTER — 真热集聚簇实验

日期：2026-08-17。lane **w1:pS**。  
分支 `grok/earley-cluster` @ **ba7e003e**（REWORK；首刀 `a5772141` 未杀），基 `main@0f721021`。件 `/tmp/wt-earley-cluster`。  
对照 RF `/tmp/eb-s1/zjs-base`（同 sha，无热段）。数字 **非裁决用**（CPU **16**）。  
REWORK 见 **§6**。

名单来源：[`EB-HOT-RESIDENCY.md`](/tmp/lanes/EB-HOT-RESIDENCY.md)。  
对照档案：[`layout-L15.md`](/tmp/lanes/layout-L15.md)（L-1.5 拒：zoo-15 并集 183 / 426KB）。

钉：① 岛内热叶不动（`.text.zjs.op_handlers` 长 **0x2d688** 与基线逐字节同）。② 只挪整函数段位，不外提、不拆体。③ 3-pad 谱系 `zjs_dossier_layout_pad=0/3/7`。

---

## 0. 判决

**实验做完了：聚的是对的集合，refill 尺没过。不宣 win，不合 main。**

| | L-1.5（拒） | 本实验 |
|---|---|---|
| 名单 | zoo-15 独占 ≥0.1% **并集 183** | Earley 90% ∪ Boyer 90% 取指，**去岛+host** |
| 符 / 体积 | 183 fn / **426KB** | 45 源函数 → 热段 **93 符 / 117.6KB** |
| 岛 | 不动 | **钉死 +0** |
| EB refill | **−7.7%** | **+12%** 合凳 / **+18%** Earley-only |
| EB cyc | −0.3% | 合凳 **−45M** / Earley-only **−320M** |
| 3-pad geomean | −0.2~0.3% 同号负 | **+0.16~0.29% 三 pad 同号微正** |

L-1.5 聚错集合还能降 refill；本刀聚对集合 refill 反而涨。说明「125KB 碎核装进连续段」**不是**缺一张对的名单——热助手贴上 **整座 182KB 岛（含 113KB 冷叶）** 仍是 ~300KB 邻域，进不了 64KB。cyc 略好、refill 变差 = 局部性换了一种 miss，不是墙倒了。

---

## 1. 名单（避开 L-1.5）

Earley 90% = 79 符，Boyer 90% = 30 符，并集 **82**。丢掉岛叶 32 + host 2，apply **48 符号 / 45 stem**。采样体积 102KB。

冻结：`src/exec/earley_cluster_union.json`。盖戳：`scripts/layout/apply_hot_section.py`（只在 `)…{` 无既有 `linksection` 时插入；handler 已有 `op_handler_section`，不会被改）。

岛外+GC 包括：`destroyRuntimeCycles` / `traceChildren` / `destroyFromHeader` / `pushExactSimpleFrame` / `setOrDefine…PutFieldOwned` / `captureArg|Local` / `createArgumentsObject` / `getArrayElement` / `ordinaryHasInstance` / `completeOrdinaryInstanceof`（本就在岛外）/ `MemoryAccount.{allocInternal,free,createInternal}` 等。

泛型整函数搬家会把未进 90% 的特化一并拉进热段（`MemoryAccount.free` 等）→ 段内 93 符 / 117.6KB，比采样 102KB 略肥。仍远小于 L-1.5 的 426KB。

---

## 2. 几何

| | 基 `0f721021` | 本刀 pad0 |
|---|---|---|
| `.text.zjs.op_handlers` | `0x1070000` **0x2d688** | **同址同长** |
| `.text.zjs.hot` | 无 | `0x109d6a0` **0x1d63c = 117.6KB** |
| 岛→热间隙 | — | **24B**（未页对齐） |
| 岛+热邻域 | 182KB | **300KB**（4.7×L1I） |

`nm`：45 stem 在热段里都有实例，missing=0。`completeOrdinaryInstanceof` 从 `.text` 迁入热段，**不是**岛内叶。

---

## 3. FW（CPU16 ABBA n=4，pad0）

A=`/tmp/eb-s1/zjs-base` B=`/tmp/earley-cluster/zjs-pad0`。原始 `/tmp/earley-cluster/fw.json`。

| 尺 | Δ insn | Δ cyc | Δ refill | |
|---|---:|---:|---:|---|
| 合凳 `/tmp/r11/earley-boyer.fixed.js` | +7.0M | **−44.9M** | **+10.1M（+12%）** | refill 反向 |
| **Earley-only** full det | −63.2M | **−319.5M** | **+197.6M（+18%）** | 主尺 refill 反向 |
| pdfjs 哨 | +10.6M | −0.8M | — | 噪声 |
| zlib 哨（cyc） | +2.4M | **+547M** | — | pad0 单尺；分数谱见 §4 |

insn 几乎不动（只挪段位，语义/体不变）。Earley cyc 降、refill 涨：不是少干活，是 miss 形态变了。

---

## 4. 3-pad 全 zoo（分数比 B/A，>1 = 刀更好）

`/tmp/census/det/*.js`，n=2，CPU16。pad 0/3/7 各自 A/B。原始 `/tmp/earley-cluster/zoo.json`。

| pad | geomean |
|---:|---:|
| 0 | **1.0029** |
| 3 | **1.0025** |
| 7 | **1.0016** |

三 pad **同号微正**，不是 L-1.5 的同号负。单项：

| | p0 | p3 | p7 | |
|---|---:|---:|---:|---|
| earley-boyer | 1.009 | 1.007 | 1.005 | 同号正 |
| **pdfjs** | 0.999 | 0.998 | 1.002 | 翻号，噪声 |
| **zlib** | 1.006 | 1.008 | 1.004 | 同号正（分数；pad0 cyc 尺曾 +547M） |
| mandreel | 0.995 | 0.995 | 0.990 | 同号轻负 |
| crypto | 0.993 | 0.997 | 0.996 | 同号轻负 |
| typescript | 0.996 | 0.998 | 0.993 | 同号轻负 |

pdfjs/zlib **分数哨未破**。mandreel/TS 轻负在 1% 内，谱系同号，是布局税不是单项彩票。

---

## 5. 读法

1. **名单对了，墙还在。** 117.6KB 热段 ≪ 426KB，但仍贴着 182KB 全岛（含 113KB 本窗冷叶）→ 邻域 300KB。L1I 装不下「岛+助手」整坨。  
2. **A1（冷叶出岛）和本实验正交。** 本刀按宪法①没动岛。若先出岛再聚 65KB 热叶 + 118KB 助手，邻域才接近 2–3×。那是下一实验，不是把本 sha 当胜记合。  
3. **A3 单态瘦身仍死**（S1 反证）。本刀没塌副本，只搬家。  
4. refill 尺是本实验的主尺，没过。cyc/分数的微正不够改写 22×。  
5. 分支留着：证明「聚对集合 ≠ 降 refill」。L-1.5 的 −8% refill 是宽名单的散布收敛；窄名单贴冷岛会换一种冲突。

未合 main。未 push。未改 handler 体 / musttail / RC。

---

## 6. REWORK（热段改挂 `.text` 尾 + 腾槽墓碑）

driver 裁决：首刀 **不杀不合**。EB 三 pad 同号 +0.5~0.9pp 是真信号（cyc/zoo 为尺，refill 反向只记疑点）。crypto 三 pad 同号负触四资产红线、mandreel 同号负 = **117.6KB 段插入推移下游全体** 的几何外部性。

返工令：① `.text.zjs.hot` 挪到 `.text` 尾；② 45 函数原位腾槽墓碑（w33 F-retrial）；③ 复测 3-pad 全 zoo。验收 = EB 保持三 pad 同号正 **且** crypto/mandreel/四资产回到中性带。

sha **ba7e003e**。刀 `/tmp/earley-cluster/zjs-pad{0,3,7}`；首刀备份 `*-v1`。原始 `/tmp/earley-cluster/{fw,zoo}-rework.json`（`fw.json` / `zoo.json` 亦为本次）。

### 6.1 放置

| | 基 `0f721021` pad0 | 首刀 `a5772141` | **REWORK `ba7e003e`** |
|---|---|---|---|
| `.text.zjs.op_handlers` | `0x1070000` **0x2d688** | 同址同长 | **同址同长** |
| `.text` 起 | `0x109d6c0` **0x39f874** | `0x10bad00` **0x382204**（被热段推后 117KB） | `0x109d6c0` **0x39f708**（同址，−364B） |
| `.text.zjs.hot` | 无 | `0x109d6a0` **0x1d63c**（岛与 `.text` 之间） | `0x143cde0` **0x1d63c**（**INSERT AFTER `.text`**） |

pad3/7 同构：岛钉死，`.text` 同址，热段在尾，长仍 0x1d63c。

墓碑：45 个 `export`/`@export` 洞，体 `.space <baseline nm>`。导出 45，唯一址 **44**（`defineOwnPropertyAssumingNew` 与 `VarRef.destroyFromHeader` 同 408B 被 ICF 折一）。导出体积 120476B（目标 120296 + ret）。WPO 把洞挤到 `.text` 尾（`0x1411b90`…），**不是**逐函数原槽——邻域未钉死，只保住 `.text` 跨度。`SmallObjectSlab.free` 误盖戳已撤（与 `MemoryAccount.free` 撞名）。

### 6.2 FW pad0（CPU16 ABBA n=4）

| 尺 | Δ insn | Δ cyc | Δ refill | vs 首刀 |
|---|---:|---:|---:|---|
| 合凳 EB | +11.6M | **−3.9M** | +9.8M（+12%） | cyc 仍负、幅度收；refill 仍反向（疑点） |
| Earley-only | +23.6M | **−173M** | +29.7M（+2.7%） | cyc 仍负；refill 从 +18% 收到 +2.7% |
| pdfjs | +10.0M | +8.4M | — | 噪声 |
| zlib | −0.3M | **−110M** | — | 首刀 pad0 cyc 曾 **+547M**，外部性拆掉后翻号 |

### 6.3 3-pad 全 zoo（n=2，分数 B/A）

| | p0 | p3 | p7 | |
|---|---:|---:|---:|---|
| **geomean** | **1.0012** | **1.0015** | **1.0008** | 三 pad 同号微正（首刀 1.0029/1.0025/1.0016） |
| **earley-boyer** | **1.0048** | **1.0085** | **1.0084** | **同号正**（首刀 1.009/1.007/1.005） |
| crypto | 0.9983 | 0.9973 | 0.9985 | 同号微负，**\|Δ\|≤0.27% 中性带**（首刀 0.993/0.997/0.996 触红线） |
| mandreel | 0.9983 | **0.9898** | 0.9983 | p0/p7 回中性；**pad3 仍 −1.02%**（首刀 0.995/0.995/0.990） |
| code-load | 1.0045 | 1.0005 | 1.0037 | 同号正 |
| regexp | 1.0184 | 1.0173 | 1.0191 | 同号正 |
| navier-stokes | 0.9983 | 0.9986 | 0.9979 | 同号微负，**\|Δ\|≤0.21% 中性带** |
| pdfjs | 0.998 | 0.997 | 0.999 | 噪声 |
| zlib | 0.997 | 1.001 | 0.992 | 翻号；pad0 分数微负 vs FW cyc −110M |
| typescript | 1.001 | 1.004 | 0.996 | 翻号（首刀同号轻负） |
| box2d | 0.997 | 0.993 | 0.995 | 新同号轻负（非验收项） |

### 6.4 验收

| 条 | 结果 |
|---|---|
| EB 三 pad 同号正 | **过** |
| crypto 回中性带 | **过**（不再 0.993 红线） |
| 四资产回中性/正 | **过**（code-load/regexp 正；crypto/navier 中性） |
| mandreel 回中性带 | **未满过**：2/3 pad 中性，pad3 仍 −1.0% |

主尺过。几何插入推移已拆（`.text` 同址）。mandreel pad3 是残余（WPO 洞挤尾，邻域未逐函数钉死）。refill 仍反向，按裁决只记疑点。

**不宣 win。不合 main。未 push。** 同分支候审。

---

## 7. 封存（driver 改令·用户裁 2026-08-17）

**pad/布局线先放下。聚簇返工中止。**

封存点：`grok/earley-cluster` @ **a5772141**（首刀，热段贴岛）。记录在案：EB 三 pad 同号 **+0.5~0.9pp**，他日重开布局线的最佳起点。

REWORK `ba7e003e`（热段改挂 `.text` 尾 + 腾槽墓碑）同分支保留但不作布局线起点。mandreel pad3 −1.0% 未满过。

本 lane 转创建链二段：`grok/fclosure-props`，见 [`FCLOSURE-PROPS.md`](/tmp/lanes/FCLOSURE-PROPS.md)。

