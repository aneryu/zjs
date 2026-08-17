# EB-HOT-RESIDENCY — 计分窗热驻留普查

日期：2026-08-17。lane **w1:pS**。**只析不改。**  
S1 卫生刀 **REJECT**（`grok/eb-s1-hygiene` @ `bc2e9ddb` 留作反证，**不合入**）：单态副本是定价资产（comptime 折叠 + 直跳），塌成一份付 `blr`/运行时 classIndex，TS/splay insn 回退、EB refill +22%。**A3 助手单态瘦身死。主路径收窄为 A1 冷叶出岛。** 本单不碰那棵树。

件：冻结基线 `main@0f721021` RF `/tmp/eb-s1/zjs-base`（与 `/home/aneryu/zjs/zig-out/bin/zjs` 同文件，31377912）。  
夹具合凳 `/tmp/r11/earley-boyer.fixed.js`（Octane；`doWarmup=false`、`doDeterministic=true`，迭代 /16）。  
拆分件（pQ）`/tmp/census/det/{earley,boyer}-only.js`（full det：Earley 2500 / Boyer 200；说明 `/tmp/census/det/EB-SPLIT.md`）。  
CPU **16**，`armv8_pmuv3_1`。数字 **非裁决用**。

签名：`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`。

原始：`/tmp/eb-hot/{fetch,refill}{0,1}.data` · `tables.json` · 分侧 `/tmp/eb-hot/{earley,boyer}-{fetch,refill}{0,1}.data` · `split_tables.json`。

---

## 0. 一句

**合凳 90% 取指 = 68 符 / 125KB。撑爆 L1I 的是 Earley，不是 Boyer。**  
Earley refill/cyc **0.0224**（1118M / 49814M），Boyer **0.00338**（172M / 50706M）——同量级周期，Earley miss 率 **6.6×**。Boyer 90% 取指只需 **30 符 / 44KB**（进 1×L1I）；Earley 要 **79 符 / 131KB**，且热集多出一整坨 GC + 构图/闭包助手。

A1 冷叶出岛本窗能开的账：**两侧都冷 239 符 / 108KB**（纯冷页按交集热集算 **88KB**）。搬完岛剩两侧都热的 **61KB + 缝**。Earley 独热岛叶只有 7.2KB，不是墙。墙在 Earley 岛外构图助手，出岛吃不到。

---

## 1. 方法

| | |
|---|---|
| 取指侧（主尺，驻留） | `perf record -e armv8_pmuv3_1/l1i_cache/ -c 100003 --no-inherit` ×2，合 **110 702** 样本 |
| refill（哨，miss 压） | 同核 `l1i_cache_refill/ -c 2003` ×2，合 **87 699** 样本 |
| 报告 | `perf report --stdio --no-children -n --percent-limit 0`（独占、可加） |
| 体积 | `nm -S` 对名；岛 = `.text.zjs.op_handlers` `[0x1070000, 0x109d688)` = **181.6KB**（343 符 / 178.2KB，对齐缝 3.4KB） |
| 三桶 | **岛内** = 地址在 handler 段；**GC-RC** = `traceChildren` / `destroy*` / `drainCycle` / `destroyZeroRef` / `collectBeforeObject` / `core.gc.*`；其余引擎符 = **岛外助手**（含 `MemoryAccount`） |
| 分数 | 3563 / 3494 / 3566 / 3568（四发，与近 FW 同档） |

未解析用户态 **0.39%** 取指（glibc `malloc`/`_int_free` 族）。内核样本无 kallsyms，不计。0 样本 ≠ 死代码（本夹具是 Earley+Boyer 确定性迭代，别的 opcode 可以一次都打不着）。

---

## 2. 三桶

### 2.1 取指（`l1i_cache`，驻留主尺）

| 桶 | 样本 | 热度 | 触达符号并集体积 | 触达个数 |
|---|---:|---:|---:|---:|
| **handler 岛内** | 57 269 | **51.7%** | **55.4KB** | 83 / 343 |
| **岛外助手** | 34 231 | **30.9%** | **286.2KB** | 170 |
| **GC-RC 族** | 17 731 | **16.0%** | **61.6KB** | 13 |
| host / libc | 1 471 | 1.3% | 59.9KB | 39 |

引擎触达并集 **403KB**（6.3×L1I）。那是「至少取过一次」的上限，不是同时热核。

### 2.2 refill（`l1i_cache_refill`，miss 压）

| 桶 | 样本 | 热度 | 触达并集 |
|---|---:|---:|---:|
| **岛内** | 42 771 | **48.8%** | 64.2KB / 90 符 |
| **岛外助手** | 39 560 | **45.1%** | 331KB / 215 符 |
| **GC-RC** | 3 349 | **3.8%** | 61.7KB / 13 符 |
| host | 2 019 | 2.3% | 76.7KB |

与 STALL-FOLLOWUP（旧件 158 符、interpreter ~50%、GC miss 3.9%）同构：**GC 周期热、I-miss 冷**；打穿 L1I 的是换来换去的短符号。本窗助手 miss 升到 45%（call/frame 13.7、shape/prop 9.3、alloc 7.0），岛仍约一半。

---

## 3. 热驻留集合（按取指热度）

累计覆盖（体积 = 前缀符号 `nm -S` 之和，不去重页）：

| 覆盖取指 | 符号数 | 体积 | vs 64 / 128 / 192 |
|---|---:|---:|---|
| 80% | 42 | **109.7KB** | 1.71× / 0.86× / 0.57× |
| **90%** | **68** | **125.1KB** | 1.95× / **0.98×** / 0.65× |
| 95% | 97 | 138.2KB | 2.16× / 1.08× / 0.72× |
| 99% | 150 | 175.2KB | 2.74× / 1.37× / 0.91× |

**90% 取指已经能装进 2×L1I（128KB）——如果那 68 个符号是一团。** 它们不是：散在岛 55KB + 岛外助手 + 两份 `traceChildren` + `destroy*`。qjs 是 38KB 一团，refill 6.5M；z 同量级「核」撕成 68 片，refill 本基线 ~83M。

refill 自己的 90% 更瘦（71 符 / 86KB）：miss 集中在短跳符号，不在 GC 大函数里打转。

### 3.1 取指 top-15

| % | KB | 桶 | 符号 |
|---:|---:|---|---|
| 8.37 | 0.79 | 岛 | `op_get_field` |
| 6.30 | 2.48 | 岛 | `op_instanceof` |
| 5.13 | **9.78** | 岛 | `op_return`（热且肥） |
| 4.69 | 10.76 | GC-RC | `Object.destroyFromHeader` |
| 4.49 | 1.34 | 助手 | `setOrDefineOwnDataPropertyForPutFieldOwned` |
| 4.12 | 3.91 | 岛 | `op_call_constructor` |
| 3.26 | 0.36 | 岛 | `op_get_var` |
| 3.10 | **16.32** | GC-RC | `destroyRuntimeCyclesWithValueRoots` |
| 2.67 | **14.92** | GC-RC | `traceChildren__anon_108732` |
| 2.65 | 0.40 | 岛 | `coldStd__struct_115320.h` |
| 2.43 | 0.90 | 助手 | `pushExactSimpleFrame` |
| 2.17 | 0.25 | 岛 | `op_put_field` |
| 1.65 | **15.30** | GC-RC | `traceChildren__anon_108744` |
| 1.53 | 2.25 | 岛 | `opCall`（一份） |
| 1.52 | 1.32 | 助手 | `ordinaryHasInstance`（**岛外**） |

`traceChildren` 两份合计 **4.32% / 30.2KB**，与 scoping 静态度同。`MemoryAccount` 20 个特化合计 **4.43% / 9.3KB**（free+alloc+create），体积不是墙，份数是。

### 3.2 岛外助手再拆（取指%）

| 子桶 | 取指% | 触达 KB | n | refill% |
|---|---:|---:|---:|---:|
| shape / prop | 8.76 | 11.7 | 12 | 9.27 |
| call / frame | 5.88 | 25.5 | 14 | **13.68** |
| alloc（MemoryAccount 等） | 4.61 | 9.8 | 22 | 7.03 |
| instanceof 助手（岛外） | 2.64 | 1.7 | 2 | 2.78 |
| 其余长尾 | ~8.8 | ~235 | 113 | ~9 |

call/frame 取指 5.9、refill **13.7**：`pushExactSimpleFrame` / `captureArg` / `captureLocal` / `createArgumentsObject` / `attachFunctionCaptures` 是 miss 第二坨，与 STALL-FOLLOWUP 的 11% 同方向。  
「其余」235KB 只付 8.8% 取指——并集肥、热度薄，不是同时驻留。

### 3.3 GC-RC 族（13 个触达 / 静态 27 符 67KB）

| % | KB | |
|---:|---:|---|
| 4.69 | 10.8 | `destroyFromHeader` |
| 3.10 | 16.3 | `destroyRuntimeCyclesWithValueRoots` |
| 2.67+1.65 | 14.9+15.3 | `traceChildren` ×2 |
| 1.19 | 0.89 | `destroyShape` |
| 0.90 | 0.31 | `destroyZeroRef` |
| 0.69 | 1.27 | `drainCycleDeferredFrees` |
| 其余 | <0.5 各 | var_ref destroy / `collectBeforeObject` / `heapByteSizeFromHeader` |

取指 16%，refill 3.8%。**驻得住、换不勤。** 瘦 GC 体减周期，不减 22× refill。S1 塌双份是卫生，不是本窗 refill 付款面。

---

## 4. 若做瘦身：冷体积可迁账

对象 = 岛内 343 符 / 178.2KB + 3.4KB 对齐缝。热 = 本窗 **取指或 refill 至少 1 样本**。

| 口径 | n | KB | 读 |
|---|---:|---:|---|
| 岛段 | — | 181.6 | section |
| 热（either） | 94 | **65.5** | Boyer/Earley 真碰到的叶 |
| **冷（either=0）** | **249** | **112.7** | 本窗未取指也未 refill |
| 仅取指未见到 | 260 | 122.8 | 略宽 |
| 热但取指 &lt;0.05% | 31 | 20.9 | 低热，迁不迁看误伤 |
| **纯冷 4K 页** | 17 页 | **68** | 整页可搬，不跟热叶共页 |
| 混页里的冷字节 | 22 页 | 47.5 | 要重排才离开热页 |
| 纯冷 64B 线 | 1822 线 | 113.9 | 与符号口径几乎重合 |

冷符家族（either=0，按体积）：

| 族 | n | KB | 例 |
|---|---:|---:|---|
| 具名 `_cold` / Cold 尾 | 34 | 25.4 | `op_add_loc_cold`、`opCompareCold` |
| get 族未触达 | 18 | 18.3 | `op_get_array_el_atom_key_proxy` 3.4、`op_get_static_cached_proxy` 3.3、`op_get_field_cached_getter` 1.6 |
| 其它未触达 op | 172 | 58.1 | 大量 set/loc 特化、稀有 opcode |
| `op_for_of_next` / apply / internalMethod | 3 | 6.9 | 本夹具用不到 |

**A1（冷叶出岛）本窗上账：**

```
搬 either=0 的 112.7KB
岛剩下 65.5 热 + 3.4 缝 ≈ 69KB   （< 1×L1I）
纯冷页先搬走就有 68KB，不碰混页
```

这是 **Earley+Boyer 确定性窗** 的上界。pdfjs/zlib 可能吃的正是这些「EB 冷」叶（scoping S3-A 风险 1）。迁之前必须用那两案的同样取指覆盖做差集，本单不做。

搬完岛 **推不倒 Earley 墙**：90% 取指核仍是 131KB 碎片，付款人在岛外构图助手。S1 已证 **A3 单态瘦身死**（副本是定价资产）。出岛之后若还要密度，是 A2 共享尾（`op_return` 9.8KB 热肥）或 A4 熔回，不是再塌 `MemoryAccount`/`traceChildren`。

不该算进「可迁冷体积」：

- `op_return_undef` 9.68KB / 取指 0.12% — 肥、几乎冷，但是 **见过**；迁要单独看 return 族。
- GC 两份 `traceChildren` 30KB — 热，不是冷。
- 助手 286KB 并集 — 其中 90% 热度不在里面；不能整段标冷。

---

## 5. 给「归因完再谈方案」的材料

1. **驻留核 ≠ 岛长。** 岛 182KB，本窗热 65KB。186KB 当工作集会高估一倍。  
2. **90% 取指 = 125KB / 68 符 ≈ 2×L1I。** 体积够进 ×2，形态不够（碎）。L-1.5 只聚不瘦，所以 L1I −8%、分数 0。  
3. **冷叶出岛有 113KB 真账**（页 68KB 先手）。验收必须带 pdfjs/zlib 覆盖差集，禁止只看 EB 0 样本。  
4. **refill 第二付款人是岛外 call/frame + shape + alloc**，不是 GC。S1 REJECT 坐实：塌副本会涨 refill，不能当 A3。  
5. **主路径 = A1 冷叶出岛**（§6.6：两侧都冷 108KB / 纯冷页 88KB）。验收必须带 pdfjs/zlib 覆盖差集。  
6. **分侧：Earley 才是 22× 的付款面**（§6）。Boyer 90% = 44KB，墙薄。对 Boyer 瘦 `op_get_field` 吃不到合凳 refill。

未测 qjs 本窗取指覆盖（既有 CallInternal 38.5KB / refill 6.5M 仍作对照，不重测）。未改 src。未合 main。

---

## 6. Earley-only vs Boyer-only（pQ 拆分件）

件 `/tmp/census/det/earley-only.js`（2500）与 `boyer-only.js`（200）。同 RF、CPU16、同一对事件 ×2。  
`perf stat` 中位 n=2；取指/refill 各两发合并。分数不可与合凳比（参考分 666463 是合的）。

### 6.1 谁撑爆 L1I

| | Earley | Boyer | E/B |
|---|---:|---:|---:|
| cycles | 49814M | 50706M | 0.98 |
| instructions | 218179M | 241973M | 0.90 |
| IPC | 4.38 | 4.77 | 0.92 |
| **l1i_cache_refill** | **1118M** | **172M** | **6.5** |
| **refill / cyc** | **0.02244** | **0.00338** | **6.6** |
| l1i_cache / cyc | 0.864 | 0.839 | 1.03 |

周期几乎一样，取指次数也同量级。**差在 miss 率。**  
合凳 /16 的 83M refill ≈ Earley 全量/16（70M）+ Boyer 全量/16（11M）。22× 的主体是 Earley。  
对照 STALL qjs 合凳 refill/cyc **0.0012**：Boyer 2.8×，Earley **19×**。

### 6.2 驻留核体积

| | Earley 取指 | Boyer 取指 |
|---|---|---|
| 样本 | 874 358 / 353 符 | 854 160 / 236 符 |
| 90% 覆盖 | **79 符 / 131KB** | **30 符 / 44KB** |
| 80% | 51 / 121KB | 21 / 41KB |
| 岛热 / 冷 | 92 符 65KB / 251 符 113KB | 68 符 59KB / 275 符 120KB |

Boyer 的 90% 核 **小于 1×L1I**。Earley 的 90% 核 ≈ 合凳（125KB），是碎片墙。

### 6.3 三桶（取指%）

| 桶 | Earley | Boyer | 合凳 /16 |
|---|---:|---:|---:|
| 岛内 | **37.2** | **67.2** | 51.7 |
| 岛外助手 | 37.3 | 24.2 | 30.9 |
| GC-RC | **23.5** | 8.2 | 16.0 |

合凳是加权平均。Earley 把 GC 抬到近 1/4 取指；Boyer 三分之二时间待在岛内叶上。

refill 桶：Earley 岛 47% / 助手 **47%** / GC 3.7%；Boyer 岛 **64%** / 助手 30% / GC 4.3%。GC 两边都不打 miss。

### 6.4 热符号集：有共同核，两侧不一样

取指 ≥0.3%：Earley **75**、Boyer **40**、交 **31**（Jaccard **0.37**）。≥1% 交 14（Jaccard 0.32）。

**两边都热（合凳那串叶）：**  
`op_get_field` / `op_instanceof` / `op_return` / `op_call_constructor` / `op_get_var` / `op_put_field` / `setOrDefine…PutFieldOwned` / `pushExactSimpleFrame` / `destroyFromHeader`。

**份额相反（Boyer − Earley，百分点）：**

| Δ | Earley | Boyer | |
|---:|---:|---:|---|
| **+11.7** | 2.5 | **14.1** | `op_get_field` |
| **+7.5** | 2.6 | **10.1** | `op_instanceof` |
| +3.7 | 1.4 | 5.1 | `op_get_var` |
| +3.2 | 2.3 | 5.5 | `setOrDefine` |
| +3.1 | 2.6 | 5.6 | `op_call_constructor` |
| **−6.1** | **6.1** | 0.03 | `destroyRuntimeCycles` |
| **−5.0 / −3.0** | 5.1+3.0 | 0.06+0.06 | `traceChildren` ×2 |
| −2.1 | 2.1 | 0 | `appendPreparedPropertyEntry` |
| −2.0 | 2.5 | 0.5 | `op_get_array_el` |

**Earley 独热（≥1%，Boyer 不到）：**  
构图/GC — `destroyRuntimeCycles`、`traceChildren`×2、`drainCycle`、`appendPrepared`、`replaceProperty`；  
闭包/参数 — `captureArg` / `captureLocal` / `createArgumentsObject` / `attachFunctionCaptures` / `opGetVarRef`；  
数组 — `op_get_array_el` / `op_get_length` / `getArrayElement`；  
`memset`、`allocInternal`。

**Boyer 独热（≥1%）：**  
`ordinaryHasInstance` + `completeOrdinaryInstanceof`（instanceof 走完）、`consumedArgSlots`、`opCall` 另两叶、`op_is_null` / `op_get_arg1_fast`、`createObjectRoot` / `destroyShape`。

Earley refill top 也是这套构图助手（`pushExact` 3.6、`setOrDefine` 3.5、`get_array_el` 3.4、`get_length` 2.7、`allocInternal` 2.7、`appendPrepared` 2.6、`captureArg/Local` 2.4/2.2、`createArguments` 2.3）。Boyer refill top 是岛内叶 + `setOrDefine` + instanceof 助手，**没有** capture/arguments/trace。

### 6.5 读法

1. **墙在 Earley。** 同 ~50G 周期，miss 6.6×。合凳 22× 是 Earley 把平均数拉上去的。  
2. **热集不是同一张。** 有 14 个 ≥1% 的共同叶（get_field / instanceof / return / ctor / put / setOrDefine…），但 Earley 另养一整套「出树 + 闭包窗 + 数组 + GC 环」。对 Boyer 瘦 `op_get_field` 帮合凳有限。  
3. **Boyer 已经是「浓解释器」。** 90% = 44KB / 岛内 67%。它的落后更像形税（insn 1.06×，FUNC-ATTRIB），不是容量。  
4. **Earley 的 refill 付款人是岛外构图助手，不是 GC 体。** GC 取指 23.5% 但 refill 3.7%。S1 已 REJECT，A3 死。  
5. **A1 可迁账见 §6.6。** 两侧都冷 108KB；Earley 独热岛叶只有 7.2KB，出岛帮不到构图助手。

### 6.6 两侧热集（带体积）+ 冷体可迁

**Earley 取指 top-12**

| % | KB | 桶 | |
|---:|---:|---|---|
| 6.14 | 16.32 | GC-RC | `destroyRuntimeCyclesWithValueRoots` |
| 5.06 | 14.92 | GC-RC | `traceChildren` #1 |
| 4.78 | 9.78 | 岛 | `op_return` |
| 4.61 | 10.76 | GC-RC | `destroyFromHeader` |
| 3.04 | 15.30 | GC-RC | `traceChildren` #2 |
| 2.59 | 2.48 | 岛 | `op_instanceof` |
| 2.56 | 3.91 | 岛 | `op_call_constructor` |
| 2.52 | 0.61 | 岛 | `op_get_array_el` |
| 2.46 | 0.79 | 岛 | `op_get_field` |
| 2.36 | 0.90 | 助手 | `pushExactSimpleFrame` |
| 2.28 | 1.34 | 助手 | `setOrDefine…PutFieldOwned` |
| 2.06 | 1.35 | 助手 | `appendPreparedPropertyEntry` |

**Boyer 取指 top-12**

| % | KB | 桶 | |
|---:|---:|---|---|
| 14.14 | 0.79 | 岛 | `op_get_field` |
| 10.07 | 2.48 | 岛 | `op_instanceof` |
| 5.72 | 9.78 | 岛 | `op_return` |
| 5.64 | 3.91 | 岛 | `op_call_constructor` |
| 5.53 | 1.34 | 助手 | `setOrDefine…PutFieldOwned` |
| 5.09 | 0.36 | 岛 | `op_get_var` |
| 4.70 | 10.76 | GC-RC | `destroyFromHeader` |
| 3.96 | 0.40 | 岛 | `coldStd__115320` |
| 3.25 | 0.25 | 岛 | `op_put_field` |
| 2.63 | 0.90 | 助手 | `pushExactSimpleFrame` |
| 2.47 | 1.32 | 助手 | `ordinaryHasInstance` |
| 2.36 | 2.25 | 岛 | `opCall` |

**岛冷体可迁（取指∪refill，either=0）：**

| 口径 | n | KB | 搬完岛剩 |
|---|---:|---:|---|
| Earley 单侧冷 | 244 | 109.8 | 热 68.4 + 缝 |
| Boyer 单侧冷 | 263 | 115.3 | 热 62.9 + 缝 |
| **两侧都冷（A1 安全上界）** | **239** | **108.1** | 两侧都热 **61.2** + 缝 ≈ **65KB** |
| Earley 独热 / Boyer 冷 | 24 | 7.2 | 合凳要留（`op_get_field_property_tail` 1.4 等） |
| Boyer 独热 / Earley 冷 | 5 | 1.7 | 合凳要留 |
| 纯冷 4K 页（按两侧都热） | 22 页 | **88** | 整页可搬，不碰混页 |
| 混页里的冷字节 | 17 页 | 31.9 | 要重排 |

两侧都冷的胖子与合凳同名单：`coldStd__115711` 5.0、`op_get_array_el_atom_key_proxy` 3.4、`op_get_static_cached_proxy` 3.3、`internalMethodRemainder` 2.6、`op_for_of_next` 2.5、三份 `opCompareCold` 各 2.4。

**A1 结论：** 合凳可迁 **108KB 符号 / 88KB 纯冷页**。Earley 独热岛叶只有 7KB，不是 refill 6.6× 的来源。出岛把 182KB 收成 ~65KB 热岛，Earley 的构图助手仍在岛外付 miss。

原始：`/tmp/eb-hot/split_tables.json` · `split_stat.json` · `{earley,boyer}-{fetch,refill}{0,1}.data`。
