> 注：原始二进制证据在临时 worktree，未入库。

# gc/minorfb-20260831 负值报告

## 结论

**KILLED，不合并。** 预注册验收线没有改动；128K 设计候选虽把
earley-boyer fixed-work 的 minor 次数从 9,348 降到 2,975（3.142x），但
EB MaxRSS 从 63,012 KiB 升到 95,536 KiB（+51.61%，硬线 +5%），且
ABBA instruction screen 的 deltablue 为 1.003474，超过 1.003 硬线。
最终 `zig build test` 还因本 worktree 未初始化 `test262` submodule 而有
两个 `FileNotFound`。任一项已足够否决，本报告不以其他收益抵消失败。

基线为 `main@7c067f01`，冻结 ReleaseFast 二进制：

- `.scratch/zjs-base-7c067f01`
- SHA-256 `6a90e5dd9a79b36ea25ad80ef193fdcde7c953c7612d2b3bdd8b3238447b1ff9`

测量候选 ReleaseFast 二进制：

- `zig-out/bin/zjs`
- SHA-256 `d368bcafe59b8e791c8dfb68627c08529b94a54294e1aedeee88488947dbdf95`

没有 commit、merge 或 push。

## 实现的控制律

控制量是每个 runtime 的 young-object 阈值，不是字节数：

- 初值/下限：16,384（原固定值，绝不低于现状）。
- 上限：131,072（128K，brief 预期 128K--256K 的低端）。
- whole-minor pause 预算：1,000,000 ns。理由是现有 minor p99 目标为
  1 ms，而 2026-08-29 EB 单次约 0.4 ms；以现有目标本身作为收缩线。
- 乘性调整：便宜且有效的 minor 为 `x1.1`，超预算为 `x0.9`，并在
  `[16K, 128K]` 夹紧。小步调整避免单个噪声样本造成数量级跳变。
- 回收率 `<10%` 时先执行 `x1.1`，给对象更长死亡窗口；放大后仍连续
  三次低 yield 才进入原有 suspension。高于等于 10% 的 productive
  结果清除低-yield streak 和 probe backoff。
- 只有 scheduler 发起且完整完成的 minor 才使用 whole-pause 时长调参；
  incomplete arena minor 不调参。collector 内的 direct/test minor 仍只记
  reclaimed/promoted 账，不用不完整的时长信号调参。
- `--gc-stats` 新增 current/min/max/budget/grows/shrinks，令控制器活动可审计。

常量及入口在 `src/core/gc.zig`；状态与控制律在
`src/core/gc_generation.zig`；runtime 在已有 whole-pause 计时落点喂回结果。
`MajorRetirement` enum、begin/commit/abandon、minor-closed 判据均未改动。

## 与停用状态机的统一梯子

```text
completed scheduled minor
        |
        +-- reclaimed >= 10% ------------------------------+
        |                                                   |
        |     pause <= 1 ms: threshold x1.1                 |
        |     pause >  1 ms: threshold x0.9                 |
        |     reset low-yield streak / probe backoff         |
        |                                                   v
        +-- reclaimed < 10% -> threshold x1.1 -> streak 1/2: keep probing
                                             -> streak 3: suspend minors
                                                           |
                                                           v
                                        existing major-count decay and
                                        exponential probe backoff (unchanged)
```

也就是放大是 suspension 前的中间档，不是与 suspension 并行的第二台状态机。

## 预注册验收线逐条对账

### 1. Tests + grow/shrink/hand-off 单测：FAIL

- `zig build check --summary all`：PASS，3/3。
- `zig build test-core --summary all`：PASS，459 passed / 6 skipped / 0 failed。
  新测试 `minor feedback grows, shrinks, then hands low yield to suspension`
  覆盖初值、放大、收缩、第三次低 yield 交给 suspension、major decay/backoff
  和 productive reset。
- 唯一一次最终 `set -o pipefail; zig build test --summary all`：FAIL，
  2488 passed / 6 skipped / 2 failed。两项均为 `FileNotFound`：
  `test262` submodule 状态为
  `-4249661388e5d3f92a85186213da140a6481490f`，且 `test262/test/` 不存在。
  失败点是 embedded Debug runner fixture 与
  `test262/test/staging/sm/TypedArray/entries.js`。这是 worktree 前置条件缺失，
  不是本 diff 的语义失败，但验收要求“全绿”，所以仍按 FAIL 记账；没有
  事后初始化并重跑来覆盖这次最终记录。

### 2. EB minor 次数下降至少 3x：PASS

同一 host lock、CPU 19、`--gc-stats`、同一
`/tmp/gcgap-fixed/earley-boyer.js`：

| arm | minor | major | threshold final | young mean/max |
|---|---:|---:|---:|---:|
| base | 9,348 | 239 | fixed 16,384 | baseline max 64,078（相邻基线采样） |
| candidate | 2,975 | 137 | 65,068 | 54,446 / 122,604 |

下降倍数 `9348 / 2975 = 3.142x`；预注册上限为 3,116 次（按该配对基线
`floor(9348/3)`），候选为 2,975。

### 3. 六负载 instruction screen：FAIL

命令：

```sh
mise run perf-screen -- \
  --qjs .scratch/zjs-base-7c067f01 \
  --benches deltablue earley-boyer pdfjs raytrace regexp splay \
  --output .scratch/perf-screen-candidate-vs-base.json
```

runner 明确允许 baseline zjs 作为 `--qjs` reference。证据为 CPU 19、exclusive
host lock、2 samples/arm、balanced ABBA；ratio 是 candidate/base：

| benchmark | instructions ratio | hard line | verdict |
|---|---:|---:|---|
| deltablue | **1.003474** | <=1.003 | **FAIL** |
| earley-boyer | 0.984824 | <=1.003（<=1.000 preferred） | PASS |
| pdfjs | 0.998802 | <=1.003 | PASS |
| raytrace | 0.998973 | <=1.003 | PASS |
| regexp | 1.001137 | <=1.003 | PASS |
| splay | 0.986507 | <=1.003 | PASS |

artifact：`.scratch/perf-screen-candidate-vs-base.json`。cycles 只留在 artifact
供 driver 终裁，本 lane 不用 wall-clock 或 cycles 改写 instruction 硬线。

### 4. splay suspension 与 minor 次数不退化：PASS

同一 fixed-work stats 口径：base minor 6、candidate minor 6；candidate
`minor suspensions 3`，阈值从 16,384 经六次放大到 29,022。原 suspension / major
decay / exponential probe 路径仍实际触发，minor 次数没有增加。

### 5. EB/splay MaxRSS 涨幅不超过 5%：FAIL

`/usr/bin/time` 的 fixed-work MaxRSS，同一 host lock 与 CPU 19，且 stats 运行
同时给出第 2/4 条行为证据：

| benchmark | base KiB | candidate KiB | delta | hard line | verdict |
|---|---:|---:|---:|---:|---|
| earley-boyer | 63,012 | 95,536 | **+51.61%** | <=66,162.6 | **FAIL** |
| splay | 525,816 | 527,772 | +0.37% | <=552,106.8 | PASS |

EB 失败不是单次噪声：128K 候选的重复 MaxRSS 为 97,828 / 100,212 KiB；
64K 上界仍为 97,464 KiB。机制对照把上界钉回 16K 时回到 62,160 KiB。
32K 中间点已经是 4,827 minors（只降 1.94x）和 81,620 KiB（约 +30%）。
因此已测可达边界没有“minor 至少 3x 且 RSS 至多 +5%”交集。

外部 50 ms RSS 采样也显示 32K 点不是尾端偶发峰值：约 0.534 s 已到
69,112 KiB，11.095 s 到 78,116 KiB。扩大阈值后 safepoint 之间的批量超调
使 young-at-start 最大值从基线约 64K 升到 95K--134K；sticky young 与成批
空 block 的驻留共同把峰值抬过硬线。精确份额未归因，不能把全部涨幅武断
归给任一单项。

## 风险与后续边界

- 当前实现是可审查的最小阈值反馈候选，但不能合并：RSS 与 deltablue 两条
  独立硬线失败，tests 还缺最终全绿证据。
- 单纯降低 max 无法修复：64K RSS 几乎不变；32K 同时失去 3x 降次目标。
- 要同时降低次数与峰值，下一项工作很可能需要研究 safepoint 之间的 young
  批量超调、minor 释放整 block 后的 reuse/decommit 生命周期，或 nursery 与
  major pacing 的耦合。这些都超出本 brief 的“minor 阈值反馈控制”最小范围，
  不应在本 lane 为过门禁临时塞入 major 调度或 decommit fast path。
- `--gc-stats` 会增加诊断采样开销；控制器读取的是 shipped path 已存在的
  whole-pause 计时，而 detailed phase/sample 只在 stats 模式启用。EB 在 stats
  与非-stats 下均复现约 96--104 MiB MaxRSS，所以否决不依赖该诊断开销。
- driver 若复核 tests，应先初始化 pinned `test262` submodule；这不会改变已
  经失败的 RSS/instruction 判决，也不授权合并本候选。

## 文件与卫生

实现 diff 仅涉及：

- `src/core/gc.zig`
- `src/core/gc_generation.zig`
- `src/core/gc_trace_stw.zig`
- `src/core/runtime.zig`
- `src/cli/zjs.zig`
- `src/tests/core.zig`

`git diff --check`：PASS。没有运行 test262、gate_smoke 或 arena audit；这些是
merge-batch driver 门禁，且本候选已经 KILLED。
