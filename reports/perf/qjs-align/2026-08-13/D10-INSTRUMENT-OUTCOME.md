# D10-INSTRUMENT outcome：fixed-work cycles 退出裁决，Zoo 采用多谱系分辨率门禁

## 0. 结论

本轮修正了尺子，也改变了 reject bin 中一个候选的结论：

1. **裁决指标只用 causal Zoo geomean。** fixed-work instructions/cycles 只保留为机制证据。对同一组 `485a7c5a` 候选与 `e31af460` 基线，在 7 条 pad 谱系、每条 8 samples 上，instructions/cycles/Zoo 的谱系极差分别是 **0.124 / 0.817 / 1.148 pp**。Zoo 同一 pad 的两轮 geomean 只差 **0.0158 pp**，所以主要不确定性不是重复采样，而是布局谱系。
2. 用本轮数据拟合的随机谱系模型，在双侧 5% 显著性、80% power、以谱系中位数裁决时，可靠检出 0.3% 所需的最小实用设计是：instructions **3×8**，cycles **7×8**，Zoo **7×8**。实际候选统一采用裁决指标所需的 **7 条谱系 × 每侧每基准 8 samples**。
3. 新判据为：Zoo 谱系中位数的有利效应必须超过设计相关 MDE，且最坏 pad 不得回退；不满足通过条件但也没有显著负效应时记 **INCONCLUSIVE**，不得再伪装成 reject。
4. **IMPL-TAILCALL：原“否决”撤销，改判 INCONCLUSIVE。** 三条原始冻结谱系的 causal Zoo geomean 为 **+0.233 / +0.042 / +0.281%**，中位 +0.233%、最坏仍 +0.042%。但 3×8 的 Zoo MDE 是 0.664%，且只有 3 条冻结谱系，不能通过。DeltaBlue 三条均受益，旧 cycles 判决不能成立；需要按 7–9 条新谱系续测。
5. **T4-B `get_array_el`：确认拒绝，但理由改为 causal Zoo。** 三条冻结谱系 geomean 为 **−10.696 / −10.597 / −10.778%**；中位 −10.696%，远超 3×8 的 0.664% MDE，且三个 pad 全退。Crypto/Zlib/Mandreel 的 Zoo 分数分别约退 40%/36%/34%（普通百分比），这是真回退，不是 cycles 噪声。
6. **布局不是本轮可立项的 +1% 杠杆。** 在 `e31af460` 的 7 个 pad 上，Zoo geomean 极差只有 **0.380 pp**；最好的 pad 1 相对发布 pad 0 是 **+0.268%**，没有 +1%。而把同一布局关系与 `485a7c5a/e31af460` 的逐 pad 因果交互合成后，pad 1 从 e31 的最好变成 485 的最差（推导值 −0.835%），排名明显洗牌。因此 pad 仍应作为验收扰动，不应固定成“优化值”。

没有生产源码改动留在工作树；只留下本文件及 `D10-INSTRUMENT-*` 原始产物。未执行任何 git 写操作。

## 1. 测量合同与冻结材料

- 核：**CPU 8**，Cortex-X925，performance governor，测量时 3.9 GHz；PMU 为 `armv8_pmuv3_1`，其 cpulist 是 `5-9,15-19`。全部命令由 `taskset -c 8` 约束，串行度 1；没有加 `flock`，没有借用其他核。
- 样本：每侧每基准 **8** 个样本，偶数，按 sample parity 交替首发，runner 产物均记录 `firstPositionBalanced=true` 和有效 affinity `[8]`。
- 配置：所有被测二进制自报
  `zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`。
- Q1 已知效应对：候选 `485a7c5a`，基线 `e31af460d94c5c368a243f37afbf15d4cefed392`；pads `0,1,3,7,15,31,63`。每个 pad 的两侧分别构建，冻结后才开始测量。
- fixed-work：`run_zoo_fixed_pmu.py`，EarleyBoyer，deterministic fixed work，divisor 16，同时读 instructions/cycles；`<not counted>` 不接受。
- Zoo：`run_zoo_compare.py --zjs <candidate> --qjs <frozen baseline> --samples 8 --cpu 8`；两侧都是 zjs。全 15 个 throughput 基准进入 geomean，latency 项不进入。
- 效应统一用对数百分比点 `E = 100 × ln(candidate/base)`。Zoo 正数有利；fixed-work counter 负数有利。小效应下它与普通百分比几乎相同，但可直接做 geomean 与加法分解。

Q1 二进制 SHA-256：

| pad | e31 baseline | 485 candidate |
|---:|---|---|
| 0 | `4b2d7043eeffa4db49574a39fdf59d5aee98cb5abed36c959c93479ecbffe1f6` | `934dc280dd3ef73a8e0881b4e542bd38f2d98e7dcd36ff49176f7481bf700ce9` |
| 1 | `fd8ac0f3a0b169f5e83813e6b430c87b4bd01ddd7a34e2a7e6cfe0c843b4b761` | `d6192128ca782e6aa8587a5edcce741a51e603814d5f6a5c73416659627d0026` |
| 3 | `1ff78f8f966b893e6dcc0a35cfc73431e205b5daf25cb8e53400253aafb7840c` | `dc0ea89ec2849880f6cbe89719e6c1ac0b2846e95d5627ecfa45ba175b4cc340` |
| 7 | `d371932c2f83c14af523fdbb6ad05328b7ba66f769f481a9f885e2fb10c28887` | `d5833fc4e3bc8a4e2d40b89ba3464be668c8f3402dbf5b368899495520c961aa` |
| 15 | `409689d780498203920db5b915a42619a4731cccc58d562943699496aa616dba` | `578f2ca5c25274a52d757ae7be4ac0dee1a0048ed3942a6a2f97040cf303fe79` |
| 31 | `b7956126cb94392aae18f47170d5f873662b61f91f87ff38dd670d7e4bc93a65` | `6254267347d06f53b1a6f847e43f6ffeb86cb988165ca2c631aad35dce0c16ec` |
| 63 | `7989d286a5f9cccc95f52df8915ad3a5d678713fc9901c2495e91e12b7635f5c` | `734ca4fab02281f54a32e244479d87355d7d92725f7a2c6b4f1e31d2af7c730a` |

第一次 pad 1 Zoo 尝试期间发现另一终端仍在编译，CodeLoad 即时值异常；该尝试在 runner 写 JSON 前被中止，随后无编译重跑。它没有进入任何统计，也没有留下冒充有效结果的 JSON。

## 2. Q1：三把尺子的实测分辨率

### 2.1 同一对二进制的 7-pad 分布

| pad | fixed instructions | fixed cycles | causal Zoo geomean |
|---:|---:|---:|---:|
| 0 | −0.0460% | −0.4298% | +0.5261% |
| 1 | −0.0016% | +0.3328% | −0.5770% |
| 3 | +0.0395% | +0.0878% | +0.0536% |
| 7 | −0.0842% | +0.0103% | +0.0232% |
| 15 | −0.0165% | +0.0649% | +0.5707% |
| 31 | −0.0126% | +0.3873% | +0.0285% |
| 63 | −0.0384% | −0.0599% | −0.0917% |
| **谱系中位** | **−0.0165%** | **+0.0649%** | **+0.0285%** |
| **极差** | **0.1237 pp** | **0.8171 pp** | **1.1478 pp** |

这里的 Zoo 结果尤其重要：同一源码差异在 pad 0/15 看起来约 +0.5%，pad 1 却是 −0.58%，而 pad 3/7/31 接近零。单 pad 无法判断这次修改的宏观效应。

### 2.2 离散度分解

对每个指标先取各 pad 的 8 个配对 log-ratio 中位；谱系观测离散度为这些中位的 `1.4826 × MAD`。谱系内离散度为每条谱系去中位后的全部样本残差的 `1.4826 × MAD`。最后用

```
tau = sqrt(max(0, sigma_lineage_observed^2 - sigma_within^2 / 8))
```

估计样本数趋于无穷时仍存在的谱系间分量。单位都是 log percentage points。

| 指标 | 谱系 MAD | 观测 robust σ | 谱系内 robust σ | 去采样后的谱系 σ (`tau`) | `|中位效应| / 观测 σ` |
|---|---:|---:|---:|---:|---:|
| instructions | 0.0220 pp | 0.0326 pp | 0.0593 pp | 0.0249 pp | 0.51× |
| cycles | 0.1248 pp | 0.1850 pp | 0.4132 pp | 0.1135 pp | 0.35× |
| Zoo geomean | 0.1202 pp | 0.1783 pp | 0.1852 pp | 0.1658 pp | 0.16× |

这组数据中 cycles 的 robust σ 没有历史 RegExp 的 3.59 pp 极端值大，但极差仍是被追效应的 2.7 倍。instructions 确实最精确，却只能证明“少做了工作”，不能预测最终 Zoo 分数。

### 2.3 Zoo 重复性

同一个 pad 0、同一对冻结二进制完整跑两轮：

| round | Zoo ratio | log effect |
|---:|---:|---:|
| 1 | 1.0052753 | +0.5261% |
| 2 | 1.0054342 | +0.5419% |
| **轮间绝对差** |  | **0.0158 pp** |

因此本会话中，同 pad 重跑抖动比 7-pad 极差小约 73 倍（1.1478 / 0.0158）。增加同一 pad 的 samples 有用，但无法替代增加独立 pad 谱系。

### 2.4 「谱系数 × 样本数 → 可检出效应量」

规划模型以谱系中位为最终估计：

```
SE_median(L,n) = 1.2533 × sqrt(tau²/L + sigma_within²/(L×n))
MDE(L,n) = (t[0.975,L-1] + 0.842) × SE_median(L,n)
```

`0.842` 是 80% power 的正态分位；`t[0.975,L-1]` 给双侧 α=0.05；`1.2533` 是正态近似下中位数相对均值的标准误代价。换句话说，设计相关的 `k` 不是拍脑袋的 2 或 3：在 **7 条谱系时 k=4.12 个基础 SE**，并明确包含小样本 t 惩罚、80% power 和中位数效率。

下表单位均为 percentage points；数值越小，尺子越细。

| 指标 | 3×8 | 5×8 | 5×32 | 7×8 | 7×16 | 9×8 | 9×16 | 15×8 | 31×8 | 检出 0.3% 的最小实用设计 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| fixed instructions | 0.121 | 0.066 | 0.055 | 0.051 | 0.045 | 0.043 | 0.038 | 0.031 | 0.021 | **3×8** |
| fixed cycles | 0.689 | 0.375 | 0.274 | 0.288 | 0.239 | 0.243 | 0.202 | 0.179 | 0.120 | **7×8**（5×20 也可，但总运行更多） |
| causal Zoo geomean | 0.664 | 0.361 | 0.343 | 0.278 | 0.268 | 0.234 | 0.226 | 0.172 | 0.116 | **7×8** |

注意 Zoo 在 5 条谱系时即使无限增加同谱系 samples，谱系间 `tau` 仍使 MDE 下不去 0.3%；这正是不能靠单 pad 重复“磨精度”的原因。该表只由一对二进制、当前机器与当前 Zoo 校准，内核、工具链、基准集合或代码布局制度变化后必须重校，不应当作跨机器常数。

## 3. Q2：新验收判据

### 3.1 正式规则

对性能候选冻结 candidate/base 每条 pad 的二进制和 SHA，至少跑 `L=7` 条预先登记的 pad、每侧每基准 `n=8` 个样本；不得测完后挑 pad。定义：

- `E_l = 100 × ln(zoo_candidate_l / zoo_baseline_l)`，正数有利；
- `M = median(E_l)`；
- `W = min(E_l)`；
- `U(L,n) = MDE_zoo(L,n)`，由上节当前校准给出；7×8 时 `U=0.278 pp`；
- 信号比 `S = |M| / U`。

裁决：

1. **PASS**：`M > U`，同时 `W >= 0`，并通过正确性、配置签名、hash 前后不变、样本完整、ABBA/首发平衡、stdout 与 affinity 检查。
2. **REJECT**：`M < -U`；或某条 pad 的回退在该 pad 自身采样不确定度之外，形成可复现的最坏谱系回退。拒绝理由必须写 causal Zoo，不得用 cycles 代替。
3. **INCONCLUSIVE**：其余全部情况，包括中位有利但 `M <= U`、最坏 pad 轻微为负、谱系数不足、或数据质量门禁不完整。INCONCLUSIVE 可以加谱系/样本再测，不能记入 reject bin。

“中位有利且最坏 pad 不回退”负责工程稳健性；`M > U` 负责统计分辨率。最坏 pad 的单个轻微负值只阻止 PASS，不自动制造 REJECT，避免把噪声重新包装成否决。

### 3.2 fixed-work 与计数器的新角色

- fixed instructions/cycles 只回答机制是否实际走到、是否少做工作、IPC/布局是否改变；它们不参与 PASS/REJECT。
- 计数器构建只供动态频率。先用已知发生场景证明计数器能检出，再用它证明某路径“不发生”。单位成本必须来自未插桩生产二进制。
- 微基准命中机制不等于 Zoo 宏观路径会兑现；报告必须同时给出 causal Zoo。
- 当前默认 7×8 能以约 80% power 检出 0.3%。若目标效应约 0.2%，应预登记更宽设计；从本表看 9×8 仍只到 0.234 pp，至少应采用约 9×16 或更多谱系，而不是只加同 pad 重复。

## 4. Q3-A：IMPL-TAILCALL 重裁

### 4.1 机制与源码重建

QuickJS 在 `quickjs.c:34941-34952` 的 label resolution 中把精确相邻的 `OP_call`/`OP_call_method + OP_return` 改写成 tail opcode；return cleanup 先由 `quickjs.c:28392-28478` 发出，因此 iterator/finally/derived-constructor cleanup 会自然阻止相邻匹配。运行时 `quickjs.c:18182-18201` 与 `quickjs.c:18220-18238` 仍调用 `JS_CallInternal` 并保留 caller frame，只在成功后直接 `goto done`。

当前 zjs 已有 tail opcode，但 `src/exec/tailcall_dispatch.zig:2096-2123` 走的是更强的物理 frame reuse，不能直接拿来承载 QuickJS 的源码 tail fold。候选从原任务会话的成功补丁逐个重放，恢复了 transactional 尾段识别、保持 caller linked、callee `tail_return` continuation 与成功 teardown 融合；保护 async/generator/derived/finally/catch/iterator 边界。原补丁中的机制行带 `qjs:18183-18201/18221-18240/20698-20710` 注释，anti-goal lint 通过。

重建源码可通过门禁，但 Zig 0.16 重建 hash 与原报告冻结 hash 不同；为避免已登记的 whole-program build bistability，性能重裁严格复用原始冻结二进制，而不是把新 hash 冒充同一二进制。

冻结 SHA：

| pad | baseline | tailcall candidate |
|---:|---|---|
| 0 | `6a28894631167c33ac904845a7c44a872f4ca9e3fac8d98cfa7265daae4d7572` | `6a1116409667c49afc78f0d5fcff4d378e2527f5c087337f556b935f9f576256` |
| 3 | `91a53541767cd2d59fc65ee869dd1bb110fb6cb48027e762f65097c45cd4cfe7` | `333f408e2eab041254866505212fc7fd5b4d5cea5859ed4557bd679ad8aa7255` |
| 7 | `0513c1565aafc071c81f663e2cb582d7b25fc1c864910bb7ecef423bb9b8915f` | `98393b07f95da9254a7c169b1fb3a1974242b5d2258591207e2f54c87ac1ef8f` |

### 4.2 因果 Zoo A/B（candidate/base，log %，高为好）

| benchmark | pad0 | pad3 | pad7 | median |
|---|---:|---:|---:|---:|
| box2d | +1.600% | +0.239% | +1.357% | +1.357% |
| code-load | −0.259% | −0.100% | +0.159% | −0.100% |
| crypto | +0.065% | +0.196% | −0.022% | +0.065% |
| deltablue | +0.481% | +0.801% | +0.761% | +0.761% |
| earley-boyer | −1.210% | −0.661% | −1.078% | −1.078% |
| gbemu | +0.453% | −0.682% | +0.000% | +0.000% |
| mandreel | +0.794% | +0.437% | +0.547% | +0.547% |
| navier-stokes | −0.350% | −0.917% | −0.290% | −0.350% |
| pdfjs | −0.520% | −1.263% | −0.889% | −0.889% |
| raytrace | −1.032% | −1.186% | −1.051% | −1.051% |
| regexp | +2.547% | +3.441% | +3.957% | +3.441% |
| richards | +0.940% | +1.207% | +1.241% | +1.207% |
| splay | +0.000% | +0.046% | +0.061% | +0.046% |
| typescript | −0.857% | −0.864% | −0.756% | −0.857% |
| zlib | +0.850% | −0.069% | +0.211% | +0.211% |
| **geomean** | **+0.233%** | **+0.042%** | **+0.281%** | **+0.233%** |

每格是 8-sample causal A/B，三条 pad 均用自身 matching baseline。逐基准出现真实取舍，但总体最坏 pad 仍为正。

### 4.3 fixed-work 与出线口计数器证据

旧 fixed-work 读数（8-sample ABBA，低为好）为：DeltaBlue instructions −0.1431%、cycles −0.4837%；EarleyBoyer +0.3151%/+1.6761%；TypeScript +0.5707%/+1.4659%；RegExp +0.0176%/−3.4291%。这些只作机制/布局证据，不再裁决。

计数器构建的动态出口频次证明目标路径真实发生：

| benchmark | `tail_call` | `tail_call_method` | `return` |
|---|---:|---:|---:|
| DeltaBlue | 1 | 7,063,654 | 17,880,783 |
| EarleyBoyer | 1,597,548 | 213 | 8,689,944 |
| TypeScript | 8,241 | 2,078,752 | 4,138,918 |
| crypto | 15 | 66,645 | 1,792,956 |
| regexp | 1 | 4 | 457,745 |

RegExp 只执行 5 次 tail opcode，却在旧 fixed-work cycles 上移动约 −3.4%，明确证明那个 cycles 负对照失效。新 Zoo 中 RegExp 同样移动 +2.5%～+4.0%，所以它仍不能给 tail 机制做刀级归因；它只能说明代码布局会带动不相关基准。

### 4.4 新裁决

- 实测 `M=+0.233 pp`，`W=+0.042 pp`。
- 当前 Zoo 谱系 robust σ 为 0.178 pp，效应/σ = **1.31×**。
- 但本候选只有 `L=3,n=8` 的冻结谱系；对应 `U=0.664 pp`，`S=|M|/U=0.35`，且未达到新规则最少 7 条谱系。

**裁决：INCONCLUSIVE，撤销旧 reject。** 数据方向支持重新打开：DeltaBlue 的目标收益在三条 pad 上全部兑现，geomean 三条也全部为正；但当前精度不允许 PASS。下一轮应从精确重建源码构建预登记的 7–9 条新 matching lineages；若真实效应仍约 +0.23%，7×8 仍偏粗，优先 9×16。不要再用 EB/TS cycles 直接否掉。

## 5. Q3-B：T4-B `get_array_el` 冷探测重裁

### 5.1 机制与源码重建

QuickJS 的 opcode 热臂 `quickjs.c:19396-19436` 只处理 dense Array + int；miss 调 `JS_GetPropertyValue`。后者在 `quickjs.c:9029-9086` 通过 `switch(class_id)` O(1) 分流 Arguments、mapped arguments 与 typed arrays。

zjs 当前 `src/exec/tailcall_dispatch.zig:3692-3733` 在 dense arm 后继续顺序探测 sparse Array own-int 和 typed array，再落到 `src/exec/vm_property_field.zig:1049-1124` 的 cold resolver。候选精确删除当前 `tailcall_dispatch.zig:3702-3729` 两个热预探针，保留 dense、atom-key 与完整 cold semantics；这是把边界移回 QuickJS 的位置，不新增 fast path。删除不新增源码行；anti-goal lint 通过。候选完成门禁后已恢复。

冻结 SHA：

| pad | baseline | T4-B candidate |
|---:|---|---|
| 0 | `d82bd1d897220f08ac8715f5a64a7bab0bf8874ab7b214587d21044ddd626c26` | `f9182be792dd22948ca1dbdb70479213f80283a4824b9a9539d59727ca5a5e49` |
| 3 | `0be0164aa9bcf492cf4c41e691909cde10482af88834c0894279b885c9c4d1b0` | `bddc64f6dc9cb4a0c59918b62f8b65b22ba46d37d5d91e63849d393e89494698` |
| 7 | `f6940f443267d53284781877e6565fb0c9d765efc8bd7a7e03114449a4d8f307` | `e042b2e5bbb8eb7fa5c476478bf9ce1ec16f200aef85b9dbef0715712c3a3711` |

### 5.2 因果 Zoo A/B（candidate/base，log %，高为好）

| benchmark | pad0 | pad3 | pad7 | median |
|---|---:|---:|---:|---:|
| box2d | +0.523% | −0.045% | +0.097% | +0.097% |
| code-load | +0.014% | +0.026% | +0.093% | +0.026% |
| crypto | −50.916% | −50.931% | −50.851% | −50.916% |
| deltablue | −0.241% | −0.201% | −0.121% | −0.201% |
| earley-boyer | −0.201% | +0.072% | −0.531% | −0.201% |
| gbemu | −19.114% | −19.069% | −19.169% | −19.114% |
| mandreel | −41.399% | −41.124% | −41.454% | −41.399% |
| navier-stokes | −0.228% | −0.313% | −0.506% | −0.313% |
| pdfjs | −4.844% | −4.755% | −4.935% | −4.844% |
| raytrace | −0.252% | −0.155% | −0.682% | −0.252% |
| regexp | +1.892% | +1.841% | +1.626% | +1.841% |
| richards | +0.202% | +0.101% | +0.067% | +0.101% |
| splay | −0.296% | +0.191% | +0.258% | +0.191% |
| typescript | −1.180% | −0.789% | −1.133% | −1.133% |
| zlib | −44.401% | −43.799% | −44.436% | −44.401% |
| **geomean** | **−10.696%** | **−10.597%** | **−10.778%** | **−10.696%** |

普通 ratio 下三条 geomean 是 0.8986/0.8995/0.8978。Crypto/Zlib/Mandreel 的普通分数 ratio 约 0.601/0.642/0.661；大回退在每个 pad、每个样本的中位上重复，不是单次掉速。

### 5.3 fixed-work 机制证据与新裁决

旧 lineage 的 EarleyBoyer instructions 中位 −0.127%、spread 0.006 pp，证明删除确实少做工作；cycles 中位却 +0.109%。RayTrace cycles 中位 +0.487%。typed-array 正控 `ta32_r` 为 instructions 1.0692×、cycles/wall 1.1185×，证明把 typed read 送回当前 zjs 顺序 cold resolver 会付真实成本；E2 微基准少 21 instructions/op，但这个局部收益无法覆盖宏观 class mix。

- 实测 `M=−10.696 pp`，`W=−10.778 pp`。
- 相对 Zoo robust σ 0.178 pp，`|M|/σ=60.0×`。
- 3×8 的 `U=0.664 pp`，`S=16.1`；`M < -U`，且所有 pad 都大幅回退。

**裁决：REJECT，确认原否决。** 但正式否决数字是 causal Zoo −10.696%，不是 cycles +0.487%。这也解释了为何“结构位置更像 qjs”不自动等于性能等价：QuickJS cold 入口后是 O(1) class switch，zjs 当前 cold resolver 是顺序语义链；只搬边界而不具备对应机制会严重伤害 sparse/typed-heavy Zoo 基准。

## 6. Q4：布局是否是杠杆

对同一份 `e31af460` 源码，以发布构建 pad 0 为 frozen baseline，其他六个 pad 各自做完整 15-benchmark、8-sample causal Zoo：

| pad | 相对 pad 0 的 Zoo log effect |
|---:|---:|
| 0 | +0.000% |
| 1 | +0.268% |
| 3 | +0.176% |
| 7 | −0.097% |
| 15 | −0.033% |
| 31 | +0.092% |
| 63 | −0.112% |

- 极差：**0.380 pp**。
- 最好：pad 1，**+0.268%**；远小于立项条件 +1%。
- 最坏：pad 63，−0.112%。

可复现性有两个不同层次：

1. **同一冻结源码/同一 pad 可复现。** Q1 pad 0 两轮只差 0.0158 pp，说明冻结条件下 pad 效果可测。
2. **跨源码不稳定。** 用同一会话的两组因果比值作恒等分解
   `layout_485(p) = layout_e31(p) × effect_485/e31(p) / effect_485/e31(0)`，得到以下 485 布局关系的测量推导值。它只用于稳定性诊断，不用于候选裁决：

| pad | e31 实测相对 pad0 | 485 推导相对 pad0 |
|---:|---:|---:|
| 0 | +0.000% | +0.000% |
| 1 | +0.268% | −0.835% |
| 3 | +0.176% | −0.297% |
| 7 | −0.097% | −0.600% |
| 15 | −0.033% | +0.012% |
| 31 | +0.092% | −0.406% |
| 63 | −0.112% | −0.730% |

e31 排名是 `1,3,31,0,15,7,63`，485 推导排名变成 `15,0,3,31,7,63,1`；原最好 pad 1 变成最差。`485a7c5a` 只比基线多一个 fclosure handler 改动，这已经足以使选择重洗。

**裁决：不单独立项为优化杠杆。** 当前 7-pad 搜索没有 +1%，且好值不跨源码稳定。pad 的正确用途是提供布局扰动以验收机制，而不是每次改代码后重搜并发布新的“幸运 pad”。若未来更大的预登记搜索找到 >1%，仍必须先跨多个源码快照复现同一 pad/同一生成规则，不能只在一个 commit 上挑冠军。

## 7. 门禁原文摘要

### IMPL-TAILCALL 精确重建

- `zig build test-exec --seed 0 --summary all`：`416 passed; 0 skipped; 0 failed`，4/4 steps succeeded。
- `zig build test-bytecode --seed 0 --summary all`：`70 passed; 0 skipped; 0 failed`，4/4 steps succeeded。
- `bash tools/perf/lint_anti_goals.sh`：无输出，exit 0。
- `zig build test -Doptimize=ReleaseSafe --seed 0 --summary all`：ReleaseSafe 编译成功并运行；`2165 passed; 1 skipped; 2 failed`。仅两项失败均为本 worktree 缺 test262 fixture 的 `FileNotFound`：

```text
FAIL: cli.run_test262.test.embedded Debug runner executes a representative test262 harness within its native stack budget (FileNotFound)
FAIL: cli.run_test262.test.test262 typed array iterator staging source parses after installing globals (FileNotFound)
```

### T4-B 精确重建

- `test-exec`：`416 passed; 0 skipped; 0 failed`。
- `test-bytecode`：`69 passed; 0 skipped; 0 failed`。
- anti-goal lint：无输出，exit 0。
- ReleaseSafe：编译成功并运行；`2162 passed; 1 skipped; 2 failed`，仍只有同两项缺 fixture 的 `FileNotFound`。

按任务契约，没有修改或补链接 `test262/`、`test262.conf`、`test262_errors.txt`，canonical test262 仍交 driver 在 main 执行。完整门禁 stdout 保存在对应 `D10-INSTRUMENT-*-gate-*.log`。

最终候选逆补丁恢复后，`git diff --check` 无输出、exit 0；`git status --short` 只显示 `reports/perf/qjs-align/2026-08-13/` 下新建的 D10 产物。

## 8. 原始产物索引

- Q1 fixed-work：`D10-INSTRUMENT-known-effect-fixed-pad{0,1,3,7,15,31,63}.json`
- Q1 Zoo：`D10-INSTRUMENT-known-effect-zoo-pad{0,1,3,7,15,31,63}-round1.json`；重复轮为 `...pad0-round2.json`
- tailcall：`D10-INSTRUMENT-tailcall-zoo-pad{0,3,7}.json` 与同名 `.log`
- T4-B：`D10-INSTRUMENT-t4-arrayel-zoo-pad{0,3,7}.json` 与同名 `.log`
- layout：`D10-INSTRUMENT-layout-e31-pad{1,3,7,15,31,63}-vs-pad0.json` 与同名 `.log`
- gates：`D10-INSTRUMENT-tailcall-gate-*`、`D10-INSTRUMENT-t4-arrayel-gate-*`

JSON 内含逐样本分数、逐基准中位、执行顺序、affinity、二进制 hash、配置、Zoo commit 与测量 wall time，可复算本文所有比值。
