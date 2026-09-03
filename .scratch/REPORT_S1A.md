# GC v2 S1a：无界分段 mark frontier 验收报告

- 日期：2026-08-31
- 分支：`gc/frontier-v2-20260831`
- 基线：`7c067f0101511df2bde8a5432940dc13be853e19`
- 测量 candidate：`17c111b08dab778d1e8ed3612f61e531a4ae0d66`

## 结论

**NO-GO，本期不入 main；实现按 owner 裁决留在 archive 分支，供 S4 组合重测。**

正确性、旧 overflow/re-scan 路径消除、splay cycles、六负载 cycles geomean 和峰值账都通过。唯一死因是固定语料 earley-boyer 的一组独立冷构建对照：

- `candidate-b / base-a` instructions 中位比 `1.003013249`，MAD `0.000223644`；
- 预注册硬线为 `≤ 1.003000000`；
- 即实际 `+0.3013249%`，超过允许的 `+0.3000000%` 共 `0.0013249` 个百分点。

该超线很小且小于样本 MAD，但预注册线没有噪声豁免；不能用 splay 的明显收益覆盖这一失败。

## 实现

主实现 commit：

- `7df5bbd6` `gc: replace bounded mark queues with segmented frontier`
- `17c111b0` `docs: update marker frontier contract`
- `d2550592` `docs: name shared segmented mark chain`（测量后纯注释修正，不改变二进制）

机制边界：

1. 本地固定 65,536 项 `MarkStack` 已替换为分段 LIFO。每段严格 4 KiB；AArch64 上段头 24 bytes、可装 509 个 header 指针。`popPrefetch` 可跨段预取下一项。
2. 共享固定 Vyukov ring 已替换为互斥保护的段链。普通 owner barrier 可走单项 push/pop；并行 donation 转移最老的完整段，helper 整段 steal，热 top 留在原 worker。
3. 并行终止改为 `stop + busy + shared-chain-empty`。预算停止时 worker 把所有剩余完整段交还共享链后 park，不把 frontier 困在休眠线程中。
4. 段从 `std.heap.smp_allocator` 获取，不进入 JS heap 账户，因此不会递归触发 GC。小池最多缓存 8 段（32 KiB），多余段在释放时归还 backing allocator。
5. 段分配失败或无法安全排队的 barrier 会显式 invalidation 当前 marking cycle；collector 返回 OOM/payload failure，abort 且不 sweep。没有丢地址后再全堆补扫的降级。
6. `overflow` 状态、CLI overflow-rescan 面板项和 `drainBarrierQueue` 的全堆 marked-object 重 trace 分支已经删除。`drainBarrierQueue` 只从分段 frontier 整段 steal 并 trace。`GcObjectIterator` 仍服务于其他合法 GC 阶段，但不再出现在该 drain 调用路径。

## 正确性与验证

新增覆盖：

- 共享 frontier 跨多段增长，验证所有已接收地址均可取回；
- private stack 以完整段 donation/steal；
- 0-byte backing allocator 强制分配失败，验证 cycle invalidation、队列为空且没有 re-scan；
- 一个 dense array 同时暴露 `131,073` 个对象孩子，严格超过旧 private `65,536` + shared `65,536` 的合计边界；验证全部孩子 marked，且实际 peak active frontier 超过旧合计指针字节数。

执行结果：

| 层级 | 结果 |
|---|---:|
| `zig build check`（迭代与收尾） | PASS |
| `zig build test-core --summary all` | 460 passed, 6 skipped, 0 failed |
| 唯一一次最终 `zig build test --summary all` | 2491 passed, 6 skipped, 0 failed；Build Summary 9/9 |
| `git diff --check` | PASS |

最终全测在 `17c111b0` 上执行；其后的 `d2550592` 只把一处注释中的旧称 “ring” 改为 “shared chain”。按 `docs/verification-policy.md`，本 lane 没有重复运行 test262、gate_smoke 或 arena audit；这些昂贵门只在 merge batch 执行。

## 固定语料测量合同

- CPU：19；`/tmp/zjs-host-heavy.lock` 独占；编译限定 CPU 0-14。
- 配置签名：`zjs-config-v2:compiler=v2,layout=short,repr=tagged,optimize=ReleaseFast,force_gc=off,ownership_audit=off`。
- candidate/base 各做两个独立 cold-cache ReleaseFast 构建；每个二进制每 workload 4 legs。
- 顺序按 `B-A-B-A` / 反序 `A-B-A-B` 交替；cycles 与 instructions 在同一次 `perf stat` 采集；每腿校验退出码、stdout score keys、PMU 可计数和整机无 `zig` 进程。
- 正式 run 前两个 60 秒 landing 窗口：CPU19 平均 idle `99.63%`、`99.72%`。
- 比值是同 sample index 的 `candidate/base` 比值再取中位数；MAD 同样由四个 paired ratios 得出。四个独立构建组合全部保留。

二进制：

| arm | SHA-256 |
|---|---|
| candidate-a | `d86a818668fc953f02a0d65dce1c70830235381006b15a0f3cf5333cae922a30` |
| candidate-b | `f6257801013bebf0c2f369bd246c74bfa8307a4f3041a4db45f04bc4f3d0712e` |
| base-a | `89557b85f0e81b0a8388575de25bc8cf8537033d7bf9d9f47d2514a7404c0943` |
| base-b | `c387fcb68077c305200ebf285397a72e09d52d3640deb851e41ad39efb9ae6d5` |

固定语料：

| workload | SHA-256 |
|---|---|
| deltablue | `55a3f692271d7f54b80b903669d4d4ddb07c40b8697801849bf2763aafeac48a` |
| regexp | `67f770174b9743502612835b656d033179f279a39848b985765a12516e301d46` |
| pdfjs | `b6328cef73513b04621a1f77bfb191f67a8fe9967a927d675751645074e38c94` |
| raytrace | `c70e5303a58a4fc39eb64634b1c5451758f0874956a2c4ee839afd0b2b42e45f` |
| earley-boyer | `9f5a58a178cc4a50b0bfb291dea0a7c00c608c8cc951262359bd59b250d6813d` |
| splay | `35ebfb84c40827b7ef9908d9338903f3e1dc42beeef6c549118d4f148c36e4a7` |

正式矩阵之前有两次明确作废的尝试，均未进入下表：第一次发现 runner 对四组合重复独立执行而在 deltablue 7 legs 后中止；第二次在正式样本产生前发现另一 lane 启动 Zig 编译而中止。原始残留保存在 `.scratch/s1a-perf/`，正式有效样本统一使用 `final-*` 文件名。

## 性能结果

### cycles paired-ratio 中位数

括号内为 splay MAD；最后一列为六负载中位比的 geomean。

| candidate / base | deltablue | regexp | pdfjs | raytrace | earley-boyer | splay | 6-load geomean |
|---|---:|---:|---:|---:|---:|---:|---:|
| cand-a / base-a | 0.998248137 | 0.963233032 | 1.000581388 | 1.012139609 | 1.014490049 | 0.945574489 (0.004048885) | 0.988707228 |
| cand-a / base-b | 0.996615241 | 0.967337809 | 1.000842350 | 1.009588895 | 1.014972739 | 0.956434882 (0.003715727) | 0.990727653 |
| cand-b / base-a | 0.996545164 | 0.953699393 | 1.000710473 | 1.006062948 | 0.995790160 | 0.938374952 (0.002140356) | 0.981516764 |
| cand-b / base-b | 0.995483199 | 0.955401873 | 1.001883953 | 1.001591820 | 0.996264202 | 0.950240418 (0.002603177) | 0.983232079 |

判定：

- splay 要求每组合 `≤ 0.975`：四组合均 PASS，范围 `0.938375–0.956435`（约改善 `4.36%–6.16%`）。
- 六负载 cycles geomean 要求每组合 `≤ 1.000`：四组合均 PASS，范围 `0.981517–0.990728`。

### instructions paired-ratio 中位数

| candidate / base | deltablue | regexp | pdfjs | raytrace | earley-boyer | splay |
|---|---:|---:|---:|---:|---:|---:|
| cand-a / base-a | 1.000032330 | 0.999883378 | 1.000787243 | 0.999836985 | 1.002978226 | 0.941921633 |
| cand-a / base-b | 0.999965792 | 0.999892494 | 1.000720155 | 0.999185624 | 1.001185747 | 0.951557626 |
| cand-b / base-a | 0.999961338 | 0.999719888 | 1.000493160 | 1.000468310 | **1.003013249** | 0.941230752 |
| cand-b / base-b | 0.999876908 | 0.999749147 | 1.000588466 | 0.999634658 | 1.001291959 | 0.945456426 |

判定：要求六负载各组合 `≤ 1.003`；23/24 个 workload/build-combination 单元通过，earley-boyer 的 `cand-b/base-a` 单元失败，因此整体 **FAIL**。

完整 paired ratios、全部 workload 的 cycles/instructions MAD、运行顺序和逐腿输出位于：

- `.scratch/s1a-perf/fixed-ab.json`
- `.scratch/s1a-perf/fixed-ab-final.log`
- `.scratch/s1a-perf/raw/final-*`

## 段池峰值账

用 candidate-a、同一固定语料、CPU19 和 host lock 采集 `--gc-stats`：

| workload | peak-active | peak-owned | 进程尾 active | 进程尾 cached | 累计 allocated / freed | allocation failures |
|---|---:|---:|---:|---:|---:|---:|
| splay | 1,757,184 B（429 段） | 1,757,184 B | 0 B | 32,768 B（8 段上限） | 4,887 / 4,879 | 0 |
| earley-boyer | 536,576 B（131 段） | 536,576 B | 532,480 B（130 段） | 0 B | 20,499 / 20,369 | 0 |

earley-boyer 在脚本退出打印面板时 collector 状态仍为 `tracing`，所以尾部 active 不为 0；这不是泄漏推断，峰值和当前状态分开报告。原始面板为 `.scratch/s1a-perf/gc-stats-splay.txt` 与 `.scratch/s1a-perf/gc-stats-earley-boyer.txt`。两者均不再有 overflow-rescan 计数项。

## 交付边界

- 不合入 main，不 push。
- 实现与失败证据保留在 `gc/frontier-v2-20260831`。
- S4 若组合重测，应重点复核 earley-boyer instructions；不得把本次 splay/六负载 cycles 通过替代 instructions 复验。
