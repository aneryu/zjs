# IC-SITE-CENSUS — 属性访问位点 shape 稳定性

日期：2026-08-17。**只读普查，无产品码，工装不入库。**  
基 `main@1c9972ab`。孤岛 `/tmp/wt-ic-site-census`（detached，**无 commit**）。  
钩子 `ZJS_IC_CENSUS`：env 未设时 `ensure()` 永久 off。本轮每案 `ZJS_IC_CENSUS=/tmp/ic-site-census/<bench>.tsv`。  
生产形签名：`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`。  
夹具 `/tmp/r5/fixed/*.js` 15/15。测量核 **CPU 8**。避核 5/6/7/19。编译核 0-4,8-14。  
参照 CH3-P0 工装纪律。原始 `/tmp/ic-site-census/{*.tsv,summary.json}`，分类器 `/tmp/lanes/ic-site-census/analyze.py`。

位点 = `(op, function*, pc_off)`。shape = 对象 `shape_ref` 指针；非对象单独记 prim，不计入 shape 数。  
分档（按该位点见过的 **对象** shape 数）：**mono=1** / **low=2–4** / **mega=>4**（表满 16 记 overflow→mega）。  
**mono 命中率上界** = 落在 mono 位点上的 **对象发数 / 该口径总发数**。IC 若只缓存 1 个 shape，不可能高于此。

钩子会拖慢分数（Box2D 4683 / TS 17599），只服务计数，**非裁决**。

---

## 0. 判决（可行性核心数）

**get_field+put_field zoo 并集：mono 上界 48.85%。**  
1–4 shape（mono+low）上界 **87.1%**。mega 残 **12.9%**。几乎全是对象接收者（prim 0.02%）。

| 口径 | 发数 | mono | low 2–4 | mega >4 | prim |
|---|---:|---:|---:|---:|---:|
| **get+put（主口径）** | **389,954,931** | **48.8%** | **38.3%** | **12.9%** | 0.0% |
| +get_field2 | 452,161,429 | 47.4% | 38.9% | 12.6% | 1.1% |
| get_field only | 311,598,989 | 50.0% | 38.1% | 11.9% | 0 |
| put_field only | 78,355,942 | 44.3% | 39.0% | 16.7% | 0 |
| get_field2 only | 62,206,498 | 38.1% | 43.1% | 11.0% | 7.8% |

并集 34,848 个 get+put 位点：mono 30,453 / low 2,778 / mega 1,612。  
**少数 low 位点吃掉大量发数**——Richards 一案 101.1M 发（并集 26%）几乎全是 2–4 shape，把 zoo mono 从「多数案 80–98%」拉到 48.8%。

| IC 形 | 上界（主口径发数） | 读法 |
|---|---|---|
| 纯 mono IC | **48.8%** | 硬上界 |
| 4 槽 poly IC | **87.1%** | Richards / splay 树节点对进得去 |
| mega 仍要慢径 | 12.9% | raytrace 57%、deltablue 27%、TS 18% |

重点五案（主口径）：

| 案 | 发数 | **mono** | low | mega | 读 |
|---|---:|---:|---:|---:|---|
| **typescript** | 66.02M | **77.5%** | 4.5% | 18.1% | 头部位点全 mono；mega 是长尾 |
| **box2d** | 34.78M | **92.5%** | 5.9% | 1.6% | 几乎全稳定 |
| **earley-boyer** | 36.20M | **98.5%** | 0.0% | 1.5% | 最干净 |
| **splay** | 4.27M | **10.8%** | **81.1%** | 8.1% | 树 left/right 两形；要 2 槽才吃得开 |
| **pdfjs** | 2.32M | **90.8%** | 2.6% | 4.5% | 另 2.0% prim |

五案加权 mono（按发数）≈ **80.3%**（不含 Richards）。  
**立项含义：mono IC 对 TS/box2d/EB/pdfjs 够用；zoo 并集被 Richards+splay 的 2–4 形拖低——若 IC 做 4 槽，并集上界到 87%。**

---

## 1. 十五案主口径（get+put）

| 案 | 位点 | 发数 | mono/all | mono/obj | low | mega |
|---|---:|---:|---:|---:|---:|---:|
| box2d * | 6389 | 34,777,580 | **92.5** | 92.5 | 5.9 | 1.6 |
| code-load | 3942 | 11,467 | 55.4 | 55.4 | 13.7 | 30.9 |
| crypto | 625 | 11,089,360 | 37.9 | 37.9 | 62.1 | 0.0 |
| deltablue | 432 | 61,054,100 | 37.6 | 37.6 | 35.4 | 27.0 |
| earley-boyer * | 580 | 36,202,287 | **98.5** | 98.5 | 0.0 | 1.5 |
| gbemu | 3176 | 37,237,559 | 90.8 | 90.8 | 9.2 | 0.0 |
| mandreel | 220 | 173 | 95.4 | 95.4 | 4.6 | 0 |
| navier-stokes | 144 | 281 | 57.3 | 57.3 | 42.7 | 0 |
| pdfjs * | 1344 | 2,322,703 | **90.8** | 92.7 | 2.6 | 4.5 |
| raytrace | 979 | 35,436,553 | 21.2 | 21.2 | 21.8 | **57.0** |
| regexp | 673 | 424,473 | 100.0 | 100.0 | 0 | 0 |
| richards | 307 | 101,107,323 | **0.0** | 0.0 | **99.96** | 0.04 |
| splay * | 273 | 4,266,994 | **10.8** | 10.8 | **81.1** | 8.1 |
| typescript * | 16521 | 66,023,642 | **77.5** | 77.5 | 4.5 | 18.1 |
| zlib | 243 | 436 | 73.2 | 73.2 | 26.8 | 0 |
| **并集** | **34848** | **389,954,931** | **48.85** | **48.85** | **38.3** | **12.9** |

mandreel / navier / zlib 的 get+put 几乎不热（<500 发），IC 与它们无关。

---

## 2. 重点五案 top 位点（按发数）

`fn` 是该跑次 `FunctionBytecode*`，只在单案内可比。`atom` 是立即数 atom id。

### typescript（66.0M，mono 77.5%）

| op | atom | pc | 发 | shapes | 档 |
|---|---:|---:|---:|---:|---|
| get_field | 830 / 1798 | 9 / 3 | 1,421,943 | 1 | mono |
| get_field | 1798 / 2945 | 29 / 18 | 1,421,941 | 1 | mono |
| put_field | 1798 / 2971 / 1159 | 9 / 36 / 21 | 1,235,917 | 1 | mono |
| put_field | 812 | 32 | 1,189,939 | 1 | mono |

头 8 全 mono。mega 18.1% 是 884 个长尾位点，不是头位点。

### box2d（34.8M，mono 92.5%）

| op | atom | pc | 发 | shapes | 档 |
|---|---:|---:|---:|---:|---|
| get_field | 1575 | 200 | 220,160 | 1 | mono |
| get_field | 794 / 894 | 247 / 237 | 158,704 | 1 | mono |
| get/put 一串 | 894 / 794 / 1680 | 223–483 | 146,400 | 1 | mono |

头 8 全 mono。mega 1.6%。

### earley-boyer（36.2M，mono 98.5%）

| op | atom | pc | 发 | shapes | 档 |
|---|---:|---:|---:|---:|---|
| get_field | 899 | 88 / 94 | 1,778,213 | 1 | mono |
| get_field | 899 | 133 / 139 | 1,581,689 | 1 | mono |
| get_field | 900 | 103 / 110 | 1,144,311 | 1 | mono |

头 8 全 mono。仅 2 个 mega 位点共 0.54M（1.5%）。

### splay（4.27M，mono 10.8%）

| op | atom | pc | 发 | shapes | 档 |
|---|---:|---:|---:|---:|---|
| get_field | 813 | 43 | 344,729 | **2** | low |
| get_field | 813 | 138 | 188,664 | 2 | low |
| get_field | 807 | 147 | 174,584 | 2 | low |
| put_field | 807 | 212 | 152,521 | **5** | mega |

树 `left`/`right` 两形。**2 槽 IC 吃 81%；纯 mono 几乎吃不到。**

### pdfjs（2.32M，mono 90.8%）

| op | atom | pc | 发 | shapes | 档 |
|---|---:|---:|---:|---:|---|
| put/get 一串 | 2055/2056/1163/8323 | 13–166 | 199,548 | 1 | mono |
| get_field | 846 | 100 | 52,612 | 1 | mono |

头 8 全 mono。prim 2.0% = 1 个非对象位点。

---

## 3. 方法

- 只钩 `op_get_field` / `op_put_field`（主口径）和 `op_get_field2`（附录）。不钩 `get_loc*_field` / `get_field_field2` 等融合。  
- 每发：`function* + (pc − byteCode)` + atom + `shape_ref*` 或 prim。  
- 开地址 256K 槽 × 16 shape；满 16 记 overflow=mega。本轮 overflow 未成为头位点。  
- 并集 = 15 案发数相加（CH3 同权），不是跨案合并同一静态函数。  
- env 未设：第一次 `ensure()` 后永久 off，热路径只一次 getenv。

工装 **不入库**。`/tmp/wt-ic-site-census` 可丢。main 无 `ZJS_IC_CENSUS`。

---

## 4. 一句话

zoo 并集 **mono 上界 48.8%**（Richards 101M 发几乎全是 2–4 形）；重点五案里 TS/box2d/EB/pdfjs 已是 **77–98% mono**，splay 要 2 槽。4 槽 poly 把并集上界抬到 **87%**。mega 真残在 raytrace / deltablue / TS 长尾。
