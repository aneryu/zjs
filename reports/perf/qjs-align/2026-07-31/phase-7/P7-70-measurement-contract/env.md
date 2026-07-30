# P7-70 测量环境

全部数字来自同一台机器、同一次锁窗口、同一个测量代次。

| 项 | 值 |
|----|----|
| kernel | `6.17.0-1014-nvidia` |
| arch | `arm64` |
| CPU model | Cortex-X925 / Cortex-A725 |
| 绑核 CPU | 19（requested 19，requestedCpuMatches=true）|
| affinity mask | `19`（affinitySource=`inherited`）|
| PMU | `armv8_pmuv3_1` type 11，cpus `5-9,15-19`，来源 `/sys/devices/armv8_pmuv3_1/cpus` |
| zig | 0.16.0 |
| cc | cc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0 |
| bun | 1.3.13 |
| node | v24.15.0 |
| perf | perf version 6.17.9 |
| 测量锁 | `/tmp/zjs-host-heavy.lock`，模式 `exclusive` |
| ZIG_GLOBAL_CACHE_DIR | `/home/aneryu/worktrees/zjs-p7-measurement-contract/.zig-global-cache` |
| TMPDIR | `/home/aneryu/worktrees/zjs-p7-measurement-contract/.tmp` |
| ZJS_REPO_ROOT | `/home/aneryu/worktrees/zjs-p7-measurement-contract` |
| zjs build mode | ReleaseFast |
| zjs JSValue 表示 | 16-byte payload+tag (zjs_nan_boxing=false, aarch64 default) |
| 采样 | iters=8，warmup=4，samples=8，order=ABBA per-sample interleaved |
| 首位计数 | {"qjs":4,"zjs":4}，orderBalanced=true |
| 生命周期 | normal-cli（comparable=false）|
| 会话模式 | enabled=false，schemaVersion=2，legacyPathUnchanged=true |

## 绑核核实（A2）

collector 起始 `19`，结束 `19`。被测子进程逐一取真实 PID 后读 `/proc/<pid>/status`：

| treatment | phase | pid | Cpus_allowed_list |
|-----------|-------|-----|-------------------|
| qjs | pre | 2057158 | `19` |
| zjs | pre | 2057161 | `19` |
| qjs | post | 2059750 | `19` |
| zjs | post | 2059752 | `19` |

探针脚本 sha256 `363b51b63e0020ab9c828e4cd4ea307da7f3c9983298e100ddb5957cea0b1896`。CPU 19 在 `armv8_pmuv3_1` 上，与既有登记一致（measurement-contracts §6）。

## 生命周期口径

qjs 侧无条件释放 handler/context/runtime；zjs 侧默认走 `src/cli/zjs.zig` 的 happy path，不调用 `runtime.deinit()`。本轮**没有**加 `--teardown-matched`，所以 `lifecycle.comparable=false`：zjs 少付一次 teardown。这对 zjs 有利，因此本轮所有 zjs 慢于 qjs 的结论都是**下界**。

