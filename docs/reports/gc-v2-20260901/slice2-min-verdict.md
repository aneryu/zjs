# GC v2 S3 slice2-min：消灭 zero_ref published borrower

状态：**GO / 等待 driver 确认**。最终候选 `3714c1242219fb55535e82ee6a9af08ba6e12c06`
通过结构、正确性、2×2 整程性能、H_PRE destroy 双线与两轮 settled 门禁。本 lane 未
merge/push。

- 分支：`gc/s3-slice2min-20260902`；
- 基点：`main@39083407224ddd5d98b82819435bcc525dc1655e`；
- 第一版失败归档：`e467e0db83178ed837b099df07e5e86fdf683116`；
- 最终修正：`3714c1242219fb55535e82ee6a9af08ba6e12c06`。

## 1. 验收总表

| 验收面 | 最终结果 | 结论 |
|---|---:|---|
| `zero_ref_list` / `zero_ref_current` / `enqueueZeroRef` | 源码 0 matches | PASS |
| zero-ref 对 published `Header.next` 写入 | 0；scratch 只持外部 Header 指针 | PASS |
| 五组 corpse topology / `CorpseHandle` / condemn 改造 | 未引入，保持 H_PRE | PASS |
| published borrower | 仅 `gc_obj_list` / young 后缀 | PASS |
| 深级联反递归 | 20,000 Shape，8 inline + 19,992 overflow | PASS |
| `zig build check` | PASS | PASS |
| `zig build test-core --summary all` | 483 passed / 6 skipped / 0 failed | PASS |
| 最终 `zig build test --summary all` | 2520 passed / 6 skipped / 0 failed | PASS |
| splay 整程 instructions / cycles | 1.000103 / 1.001028 | PASS / PASS |
| EB 整程 instructions / cycles | 1.001592 / 0.990919 | PASS / PASS |
| splay destroy 双线 | 857,208,035；1.022258× H_PRE | PASS / PASS |
| EB destroy 双线 | 10,009,264,327；0.973835× H_PRE | PASS / PASS |
| settled 六负载 | 6/6 clean × 2 个独立冷构建 | PASS |

## 2. 实现边界

### 2.1 只提取 zero_ref 消灭

- `Registry.zero_ref_list` 与 `zero_ref_current` 删除；初始化、deinit、heap-accounting
  iterator、invariant checker、`containsHeader` 中相应持有窗口全部删除。
- `ZeroRefScratch` 是单次调用所有的外部 worklist：8 个 inline Header 指针，超过后使用
  `ArrayListUnmanaged(*Header)` scratch overflow；排干后立即释放 overflow。排队节点仍是
  published member，scratch 不写 cell 内的 `Header.next`。
- Realm 最后一个 body RC 由 `enqueueEagerZeroDirect` 直接 unlink/account/destroy；Realm
  teardown 释放的五个 context-owned Shape 走专用 `releaseForRealmTeardown` admission，追加到
  当前 scratch 后迭代排干。
- 普通 Shape 最后释放保持 H_PRE 原热路 `release -> destroyShape`。Shape 析构在 tracing
  collector 下不会再释放另一个 Shape，因此没有必要为每次普通 Shape 死亡建立通用 scratch
  frame；这也是最终性能修正的关键。
- `processWeak` 与 cycle weak-collection sweep 显式携带栈上 scratch，保留原 `.decref`
  遍历隔离合同。BigInt tag-directed 冷尾不变；Object/FunctionBytecode/VarRef/Module 仍由 tracer
  拥有，不新增 RC 死亡路径。

### 2.2 明确未带入的代码

相对 main 的 diff 不含 `CorpseHandle`、`CorpseQueue`、`DoomedOrigin`、`enqueueDoomed`、
`parked_extents` 或 `finalizer_current`。`tmp_obj_list`、`doomed_by_kind`、
`cycle_deferred_frees` 和 deinit hold stacks 保持 H_PRE 原样；按本轮 driver 战略裁决，它们只在
判死后触碰 canonical word，不是 published borrower。本片没有迁移五组尸体拓扑。

## 3. 确定性正确性证据

新增两条直接回归：

1. Realm host release 后 live Realm 立即从 1 降到 0，`doomedStateSnapshot`、
   `zero_ref_drains` 与 `doomed_pending` 均不变；
2. 在显式 outer scratch 中释放 20,000 个 Shape，断言 `inline_len == 8`、
   `overflow.items.len == 19,992`，排干前节点仍有 live-list `header.next`，排干后 live Shape
   恢复基线且 corpse snapshot 完全不变。

第二条既证明 overflow 臂真实执行，也把深级联排干钉为迭代 worklist，不依赖 C/Zig 调用栈
深度。自然 Realm teardown 同时覆盖五个 context-owned Shape 进入同一 scratch 的生产入口。

最终实现上的验证顺序：

```text
zig build check                         PASS
zig build test-core --summary all      483 pass / 6 skip / 0 fail
zig build test --summary all           2520 pass / 6 skip / 0 fail
git diff --check                        PASS
```

## 4. 第一版 NO-GO 与修正

`e467e0db` 正确删除了 persistent queue，但让**所有**普通 Shape last-release 绕行
`destroyZeroRef -> enqueueEagerZeroDirect -> ZeroRefScratch`。2×2 正式结果稳定复现其成本：

| workload | instructions | cycles |
|---|---:|---:|
| splay | 1.020079 | 1.021517 |
| EB | 1.021453 | 1.016339 |

反汇编/符号边界显示 H_PRE 普通 Shape release 直接进入 `destroyShape`，失败版却进入约 560B 的
通用 `destroyZeroRef` 实例并建立 scratch。这个绕行不是消灭 zero_ref queue 的必要成本。

`3714c124` 将普通 Shape release 恢复为 H_PRE 原路径，只把真正会在 Realm destructor 内成批
发生的 context-owned Shape 释放送入 scratch。失败 commit 与原始证据目录
`.scratch/s3-slice2min-evidence/` 均保留，没有改写或删除失败腿。

## 5. 最终 2×2 整程性能

### 5.1 合同与 identity

- 冷构建顺序 `base-a, candidate-a, candidate-b, base-b`；每份独立 local/global cache 与
  prefix，编译绑 CPU0-14；
- 四个 build combination，每组合 4 个 balanced ABBA paired blocks；
- 正式运行 CPU19 + `/tmp/zjs-host-heavy.lock`；instructions/cycles 同腿采集；
- 决策量是每 workload/event 全部 16 个 paired ratios 的总中位；cluster bootstrap
  200,000 replicates；冻结线 `<= 1.003`；
- matrix 与 attribution 的 Zig monitor 均为 0 byte，未发生整组污染作废。

四份均现场通过 shipped ReleaseFast config signature 与 `print(6*7) == 42`：

| binary | bytes | SHA-256 |
|---|---:|---|
| candidate-a | 29,109,504 | `5d6ea725410d50dfb41a07a5524a83ae39411f88dd679fd152c2d26ddb09f85e` |
| candidate-b | 29,056,696 | `4358aed0246ea66b8aba8db9b517dc3bcf81e71bb9d7910d2f9454d1bb8dd958` |
| base-a | 29,072,848 | `2fb6b5ba038546b6581ba79bda84ebf2fb76856ddf6219dc93b5f61e4c58aa79` |
| base-b | 29,072,848 | `7887a025753af7a2394495eba6946a15440801b957d58c6977252914cf8e859a` |

### 5.2 总中位裁决

| workload | event | 总中位 | MAD | 95% bootstrap CI | range | 结论 |
|---|---|---:|---:|---|---|---|
| splay | instructions | 1.000103 | 0.001638 | [0.996569, 1.003479] | [0.991729, 1.009639] | PASS |
| splay | cycles | 1.001028 | 0.004440 | [0.990648, 1.006581] | [0.978813, 1.012442] | PASS |
| EB | instructions | 1.001592 | 0.000816 | [1.000484, 1.002660] | [0.999448, 1.004504] | PASS |
| EB | cycles | 0.990919 | 0.009140 | [0.982780, 1.008887] | [0.981203, 1.018054] | PASS |

预注册规则裁决的是总中位，CI 用于报告分辨率；没有把 CI 上界改成第二条隐含验收线。

逐组合中位（instructions / cycles）：

| combo | splay | EB |
|---|---|---|
| candidate-a / base-a | 1.000711 / 1.001028 | 1.001119 / 0.985895 |
| candidate-a / base-b | 1.000283 / 1.004285 | 1.001981 / 0.983072 |
| candidate-b / base-a | 1.000048 / 0.995608 | 1.001333 / 1.008106 |
| candidate-b / base-b | 0.999443 / 1.001162 | 1.002341 / 1.006100 |

## 6. destroy 双线与 stats

profile 合同沿用 H_PRE：candidate-a 两份 997Hz cycles profile 的 bucket share 均值，乘
candidate-a 在正式矩阵的八腿 cycles 中位。

| workload | H_PRE | candidate | ratio | absolute line | ratio line | 结论 |
|---|---:|---:|---:|---:|---:|---|
| splay | 838,543,898 | 857,208,035 | 1.022258 | 880,215,649 | 1.05 | PASS / PASS |
| EB | 10,278,195,228 | 10,009,264,327 | 0.973835 | 10,743,522,182 | 1.05 | PASS / PASS |

splay 低于绝对线 23,007,614 cycles；EB 低 734,257,855 cycles。三条 stats 腿的
`zeroRefDrains` 总中位在 splay/EB 均为 **0**；major/minor 中位分别为 11/6 与 260/9413，
failed 均为 0。

## 7. 两轮 settled 门禁

每轮使用独立冷 candidate binary；六负载每个 3 ordinary + 1
`ZJS_GC_ARENA_AUDIT=1 --gc-gate-settle --gc-stats`，CPU2-7 并行且整轮持 host lock。

| round | binary | EB | splay | 六负载 |
|---|---|---|---|---|
| 1 | candidate-a | retirement=157, endpoint/state=clean | retirement=11, endpoint/state=clean | 6/6 PASS |
| 2 | candidate-b | retirement=158, endpoint/state=clean | retirement=11, endpoint/state=clean | 6/6 PASS |

deltablue/pdfjs/raytrace/regexp 两轮也全部 endpoint/state clean；没有在 settle 循环内加入全堆
审计或重复 verifier。

## 8. 证据索引

| evidence | SHA-256 |
|---|---|
| `fleet-manifest.json` | `3bd52a7c3919d37d01d490c2d5e4145b0c06a0000e75025feca763aedfca6a91` |
| `analysis.json` | `159fdb278641b4dd7711e2c55a5591e843b836f1f204c29440c71caef6277660` |
| `stats-analysis.json` | `91532aca3c4cb3ddf4793243b396332e54f5fd9bb05d427b17bf8e3c4ae0e322` |
| `profile-analysis.json` | `c75e924c261cbf924000f1bdbef8e1497e55735e6b3721a59c6b51572ffd6592` |
| `settled-round1.log` | `5acea7066ea895560f857f4b28d050c2ae65971912e47f82706096ba88184be8` |
| `settled-round2.log` | `7e47fb539e484cead26d2f869f15c2b966ca028caf77e6786fe1597d5ac516ac` |

最终证据目录：`.scratch/s3-slice2min-v2-evidence/`。第一版失败证据目录：
`.scratch/s3-slice2min-evidence/`。

## 9. handoff

slice2-min 达成目标：zero_ref published borrower 与其 `Header.next` 写入归零，五组判死后
topology 保持 H_PRE，普通 Shape 热路恢复基线，全部冻结正确性/性能/settled 门通过。结论
**GO**，等待 driver 确认；本 lane 不自行 merge/push。
