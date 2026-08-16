# OPT-R14 计划 — EB 攻坚（wave-2 后守恒地图开工）

日期：2026-08-15。基线：main@665e1468（wave-2 合入），EB ≈0.71 = 全 zoo 最差项。
地图：`/tmp/r11/EB-R14-MAP.md`（pQ，wave2-p0 vs qjs，FW d16，守恒闭合 92%）已验收。

## 0. 总账与战略事实

EB FW 周期比 **1.4023**（7.639G vs 5.448G），超出 **+2192M**，五桶四态：

| # | 桶 | 超出 | 占 | 态 | 归属 |
|---|---|---:|---:|---|---|
| ① | ctor 管线残洞（setupInline/window/deinit vs JS_NewObjectFromShape） | +583M | 27% | 需新刀+architectural | **A 刀，排队** |
| ② | closure 残余（拆 cell 91vs51 + attach 52 vs js_closure2） | +175M | 8% | 需新刀 | **B 刀 → pQ** |
| ③ | GC 环残余（drain 116 vs gc_free_cycles 56） | +232M | 11% | 需新刀 | **C 刀 → pW** |
| ④ | pushExactSlow 57.3 + release 45.1 (+非Slow 32.8) | +135M | 6% | 已有刀 | **S1/R1 → pT（在修）** |
| ⑤ | 其它（zjs dispatch+prop+call 4.1G vs qjs 3.1G） | +1067M | 49% | architectural | 布局批论据 #3 |

**战略事实：命名刀乐观顶 A+B+C ≤570M ≈ 26%。EB 追平单靠 R14 不够，差在 ⑤
（09 分派地板）→ 并入布局批决策包（与 compute 三基准、gbemu 环同一裁决）。**

## 1. 派工与排序（防互踩）

| 刀 | lane | 分支 | 状态 | 排序理由 |
|---|---|---|---|---|
| S1（Fast 收编 open-ref≤16，零 bl rider） | pT | grok/r14-ebslow | **6db9e018 已验收**（Slow 1.278M→10，EB 方向 +1.01%） | — |
| R1（release 2 槽 40M 并进 take/return 序） | pT | 同上 | 实施中 | — |
| B（closure 拆 cell + attach 对齐） | pQ | grok/r14-closure-b | 已派 | closure/varref 区，与 entry 管线正交，可并行 |
| C（GC drain 对齐 qjs:6756） | pW | grok/r14-gc-drain | 已派 | GC 区，正交，可并行 |
| **A（ctor 管线肥 ~400M 可视）** | 待派 | — | **排队至 wave-3 落地** | 与 pV 的 L1 rebase、pT 的 S1 同在 entry/inline 管线区，三方并行改同一文件=合并地狱（07-26 教训） |

红线（全刀共通）：不重建 bypass、不扩 call_method、不动 RC teardown、不删 cycle_visited、
不做 fclosure 热表、opGetVarRef 读路径已平勿碰、Frame/Entry 几何归 R13-B 裁决。

## 2. 与其它战线的耦合

- ①vs 非法 bypass 的 ~108 cyc/构造 = architectural，**不在 R14 回收范围**（A 刀只打管线肥差 435M vs 171M）。
- ⑤ +1067M 与 R13 Entry 几何、布局批共享病根；EB 达标路径 = R14 命名刀（~26%）+ 布局批/R13-B（架构层）。
- wave-3（L1 rebase + G1 + S1/R1）落地后：A 刀开工 + 上层重定价（R13 流程）。

## 3. 结果表（滚动）

| 项 | 结果 |
|---|---|
| S1 | Slow −99.999%（1.278M→10），零 bl 保持，帧 0x20–0x30，EB FW +1.01%（非裁决） |
| R1 | e6c48245：热臂 2 拍 RC dec 替 bl walker（40M 靶），帧 0x260 未涨，18/18 测试 |
| C 刀 | 5c6017ba：drain 单遍就地释放对齐 qjs:6797，fromAsync 95/95 无 SEGV，EB FW 0.9939（非裁决）→ wave-4 批 |
| **wave-4 终裁** | **ACCEPTED @4290f89b**：3-pad geomean +0.08/+0.22/+0.11 同号，EB +0.59/+0.62/+0.31 同号；regexp 混号=布局伪影洗清。EB 站位 ≈0.720 |
| A1 普查 | **空刀避免**：EB new TAKE 94%/simple 5%/general 0，拒因全 0 → A1 eligibility 是空操作不落码 |
| **① 桶改写** | ENTRYTYPE (b) 坐实：254+131M 付款人=**5.91M 次 plain call 到 v1.5 特化副本**（specializeCallSite 清 simple 位过严，副本仍满足 simple_inline_base；ctor/method/open>16 全 0；wave-2/3 同数=L1/S1/R1 无涉）。A1 正式关闭；**S2 立项派 pV**（恢复 spec 副本 simple 位→setupSimpleInlineEntry，期望 100-300M 级）；R13-B B1 正交叠加 |
| nexec | ca6a2684 系：EB −110M/insn −273M 超图顶；pdfjs 税滑壳三连≈0（② 顶下修 0-10M）；regexp ABI 肥已撤；thin×leaf 交互证伪（v1b −55M=单 pad 彩票，探针类须 ≥2 pad 入宪） |
| **wave-8 终裁** | **ACCEPTED @ab54c31f（第 14 条单 pad+三 pad 追认）**：EB +7.3~7.5%/raytrace +6.0~7.5%/splay +0.9~1.4%/geomean +1.0% 全同号。**S2=战役最大单刀**。EB ≈0.776、raytrace ≈1.06 越线达标 |
| **wave-7 REJECTED** | 三 pad geomean −0.3~0.5% 同号、TS/pdfjs/regexp 同号负 1-2%、EB −150M 未兑现（混号）。**regexp ABI 肥是金丝雀**：exec_direct 铺开对 native 重基准有通用税，逐域 disasm+FW 立据后才可重打包（pQ 查案）。R17 拆出单走 wave-7b（EB −40M 无辜推定待验） |

## 4. 绝对站位（2026-08-15 官方实测，wave2-p0 vs qjs，8 样本 CPU 19）

geomean **0.9311**。落后 11 项：EB 0.7117 / raytrace 0.7419 / pdfjs 0.7884 /
TS 0.8785 / zlib 0.9243 / splay 0.9334 / mandreel 0.9364 / box2d 0.9373 /
DB 0.9553 / gbemu 0.9632 / richards 0.9817。
达标 4 项：navier 1.0574 / crypto 1.0630 / regexp 1.1023 / code-load 1.1062。
（此表替代此前一切复合推算；EB 0.7117 与 R14 地图 1/1.4023 互证。）
