# P7-31：默认策略下跳过无人消费的进程内存快照

- 日期：2026-07-30
- 提交：`e94649c9`　基线：`d4ecae7d`
- 性质：生产改动（single-mechanism one-cut）
- 依据：`P7-30-typedarray-construction/`
- 数据产物：`P7-31-results.json`

## 1. 一刀的内容

P7-30 定位到：凡 backing store 超过 32 字节 inline 上限的外部分配都会走
`reportExternalAlloc`，后者**无条件**采集进程内存 —— `/proc/self/statm` 的
open/read/close，加上 cgroup v2 与 v1 两个 limit 文件的 open（后两个通常 `ENOENT`）。
而默认策略下 `Registry.processMemoryRequest` 里的四个 gate 全部关闭，它只可能返回 `null`，
**五个 syscall 的结果全部被丢弃**。

本刀只加一个早退，判据是**实际消费 OS 快照的能力**，不是 `Policy.mode`：

```zig
pub inline fn needsProcessMemorySnapshot(self: Policy) bool {
    return self.rss_soft_limit != null or
        self.rss_hard_limit != null or
        self.cgroup_soft_ratio_per_mille != 0 or
        self.cgroup_hard_ratio_per_mille != 0;
}
```

**按 mode 判断是错的**：调用方完全可以停在 `.balanced` 而显式设置 RSS 或 cgroup 阈值，
`mode == .balanced` 的判断会静默关掉嵌入方明确要求的压力策略。这四个字段正是
`processMemoryRequest` 读取的全部字段。

`external_soft_limit` / `external_hard_limit` **刻意不计入**：它们由 registry 自己维护的
external-byte 计数回答，不需要读 `/proc` 或 cgroup。

控制流是 inline gate 展开在调用侧 + `noinline` slow path，因此没有压力策略的运行时
**连一次调用边界都不付**：

```zig
inline fn requestGCForProcessMemoryPressure(self: *JSRuntime) void {
    if (!self.gc.policy.needsProcessMemorySnapshot()) return;
    self.requestGCForProcessMemoryPressureSlow();
}
```

**gate 位于 external accounting 之后**。`reportExternalAlloc` 里的 external 字节、
分配计数、allocation debt、以及既有的内部阈值请求全部先行且逐字未变；被跳过的只有
没人读的那次快照。任何消费该快照的 policy 走到的是**同一个** slow path。

### 本刀刻意不做的事

不做 RSS 缓存、不做 cgroup limit 缓存、不在启动时探测 cgroup v1/v2、不做节流、
也不做「只设了 RSS 阈值时就不读 cgroup」这类更细的拆分。缓存只能回收一部分成本，
而两个注定失败的 cgroup open 仍会留在原地 —— P7-30 已量出 statm 占 21 240 insn、
两个必失败的 cgroup open 占 18 224 insn，缓存路线**只能拿回约一半**。

## 2. Syscall 合同

`strace` 实际 syscall 作权威计数，对 N=0/1/200 次外部分配做差分：

| 目标文件 | P0（基线） | P1（本刀） |
|---|---|---|
| `/proc/self/statm` | **1.0000 /op** | **0.0000 /op** |
| `/sys/fs/cgroup/memory.max` | **1.0000 /op** | **0.0000 /op** |
| `/sys/fs/cgroup/memory/memory.limit_in_bytes` | **1.0000 /op** | **0.0000 /op** |

**这个零是实测的零，不是坏掉的过滤器。** P7-30 踩过一个仪器坑（zjs 链接 `openat64`
而非 `openat`，只拦 `openat` 会读到零并得出「抑制无效」的假结论），所以本刀先在**未改动的
二进制**上验证计数方法能检出 1.0000/op，再去测改动后的零。

`.low_rss` 与自定义策略的行为由 §3 的契约测试钉住，而不是靠 syscall 计数 —— 它证明的更强：
启用路径抵达的是同一个判定。

## 3. 语义契约测试

**Policy 矩阵**（`process memory snapshot is needed exactly when a policy field consumes it`）：

| Policy | `needsProcessMemorySnapshot()` |
|---|---:|
| 默认 `.balanced` | false |
| 默认 `.throughput` | false |
| 默认 `.low_latency` | false |
| 默认 `.low_rss` | **true** |
| balanced + `rss_soft_limit` | true |
| balanced + `rss_hard_limit` | true |
| balanced + soft cgroup ratio | true |
| balanced + hard cgroup ratio | true |
| 只有 external soft/hard limit | **false** |

并且钉住运行时 `false → true → false` 翻转：gate 读的是**当前** policy，不是латched 的陈旧答案。

**Accounting 契约**（`process memory gate preserves external accounting and still fires when consumed`）：
默认策略下 external 字节照常增加且**不**产生 `rss_pressure` 请求；把 `rss_soft_limit` 设为 1 字节
（必然被超过）后，external 字节同样增加**且**产生与从前逐字相同的 `rss_pressure` 判定。

## 4. 性能

每侧两个冷缓存构建，全组合报告。P1 两次构建**字节相同**（`09e025c9…`），P0 两次**不同**
（`a291cb0b…` / `6f8690f6…`），所以 P1-a vs P1-b 又一次充当免费的噪声尺：目标与中性项上
`|Δcycles|` ≤ 0.21%，哨兵 ≤ 0.48%。

### 目标（门槛：wall 或 cycles ≥70%，4/4）

| case | P0 insn/op | P1 insn/op | P0 ns/op | P1 ns/op | 四组合改善 |
|---|---|---|---|---|---|
| `Uint8Array(33)` | 46 539.0 | 5 320.3 | 4 195.3 | **261.0** | 93.7–93.8% |
| `Uint8Array(64)` | 46 585.0 | 5 377.0 | 4 175.8 | **263.9** | 93.7% |
| `Uint8Array(512)` | 47 560.9 | 6 335.2 | 4 231.8 | **331.7** | 92.2–92.3% |
| `ArrayBuffer(64)` | 44 693.5 | 3 482.2 | 4 132.7 | **168.8** | 95.9% |

最差组合 **92.16%**，门槛 70%，**4/4 PASS**。

### 边界与非目标（门槛：无稳定回退 ≥1%）

| case | max\|Δcycles\| | 四组合均回退≥1% | 方向 |
|---|---|---|---|
| `Uint8Array(0)` | 0.81% | 否 | 改善 |
| `Uint8Array(32)`（inline 上限内） | 1.29% | 否 | **改善**，指令持平 ±0.11% |
| existing-buffer view | 0.59% | 否 | 改善 |
| 重复 `fill`，不分配 backing store | 0.48% | 否 | 改善 |

`ta32` 的 1.29% 是**改善**而非回退，且落在 P0 自身双稳（0.74%）附近，指令数持平，
按中性判定。这与预期一致：32 字节走 inline storage，从来不触发该路径。

### 普通哨兵（门槛：无稳定回退 ≥1%）

`local_arith` 0.71%、`global_write` 0.64%、`prop_read_mono` 0.19%、`call_body` 0.25%，
四组合均无稳定回退。

### 产品侧 gbemu（门槛：≥5%，4/4）

| | 中位分数 |
|---|---|
| P0-a / P0-b | 10 092 / 10 048 |
| P1-a / P1-b | 10 949 / 10 949 |

四组合 **+8.49% ~ +8.97%**，最差 8.49%，**PASS**。这独立复现了 P7-30 事前给出的 **+8.4%** 预测。

## 5. 与 P7-30 预测的差异

P7-30 用 `LD_PRELOAD` 抑制探针，估计 zjs 会落到 7 327.6 insn/op；本刀实测是
**5 377.0 insn/op**，比预测更低。原因是 P7-30 的抑制只让文件打开失败，**仍然支付了
syscall 的进入与返回**；本刀连 syscall 都不发出。因此 P7-30 的份额估计（指令差 91.3%）
是本刀真实收益的**下界**。

## 6. 门禁

全部通过：

```
fmt clean / diff-check clean
test-core 315   test-exec 403   test-bytecode 188   test-parser 463
test-builtins 195   test-runtime 72   test-runner 43   test-oom 20
ReleaseSafe(test-core) 315   force-GC(test-core) 315   altrepr(nan_boxing) 315
test262-smoke  0/12 errors
test262-gate   0/49775 errors, passed 44541, known 25
perf-self-check 75/75 compatible, 0 validation failures
```

`perf-self-check` 这一轮报出 **paired geomean 1.00**（75/75），启动基线 qjs 1.025 ms /
zjs 1.033 ms（比值 1.01）。两点需要谨慎解读：

- 它**不是**本刀的受控 A/B（那是第 4 节），而是当前 zjs 对 qjs 的整体对比，
  其中还包含合并进来的其他改动。**不能把 1.3340 → 1.00 全部记在本刀账上。**
- 但它从侧面印证了 P7-20 的两个结论：该 suite 的聚合值高度依赖启动开销
  （此轮启动比值 1.01，而 Phase 6 收口快照是 1.2628），且 `array_map_callback`
  此轮为 **1.00**，与 P7-40「2.618 是过期二进制加无效 affinity 的产物」一致。

## 7. 未做的事

- **残余约 2x 未处理。** P7-30 已判定它是分散的（view wrapper 2.57x、zero fill 4.28x、
  plain construct 2.03x、out-of-line buffer 1.99x），不是第二个元凶。本刀不追。
- **未测量在 `memory.max` 真实存在的宿主上的成本。** 本机两个 cgroup 文件都 `ENOENT`；
  在 cgroup v2 生效的宿主上，第二次 open 会成功并多一次 read，P0 侧只会更贵，
  但本刀的 P1 侧同样是零，结论方向不变。
- **未验证非 Linux 平台。** `currentRssBytes` / `cgroupLimitBytes` 在非 Linux 直接返回 0，
  本刀只是让它们不再被调用；契约测试对非 Linux 早退。
