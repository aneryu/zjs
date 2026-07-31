# P7-80 复现命令

全部命令从 worktree 根执行。环境前缀本文件统一写作 `$ENV`：

```sh
cd /home/aneryu/worktrees/zjs-p7-80-uri
export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache"
export TMPDIR="$PWD/.tmp"
export ZJS_REPO_ROOT="$PWD"
export ZJS_MEASUREMENT_LOCK=/tmp/zjs-host-heavy.lock
export ZJS_MEASUREMENT_LOCK_MODE=exclusive
export ZJS_BUILD_MODE=ReleaseFast
export ZJS_JSVALUE_REPRESENTATION="16-byte payload+tag (zjs_nan_boxing=false, aarch64 default)"
```

锁契约：编辑 / grep / objdump / JSON 分析不取锁；构建与 gdb 计数取 `flock -s`；
**正式采样与 `perf` 取 `flock -x`**。

## A：两个独立冷缓存构建

```sh
flock -s /tmp/zjs-host-heavy.lock bash .tmp/build-a.sh
flock -s /tmp/zjs-host-heavy.lock bash .tmp/build-b.sh
```

两份脚本除 `.build-a` / `.build-b` 与各自独立的 local+global cache 目录外逐字相同：

```sh
zig build zjs -Doptimize=ReleaseFast \
  --cache-dir  "$PWD/.build-X/zig-local-cache" \
  --global-cache-dir "$PWD/.build-X/zig-global-cache" \
  --prefix "$PWD/.build-X/out"
```

结果 sha256 见 `P7-80-results.json` 的 `meta.binaries`。两份**不是**逐字节相同，
本轮没有免费噪声尺。

## B：正式采样（四种构建组合）

```sh
flock -x /tmp/zjs-host-heavy.lock bash .tmp/round2.sh
```

其中每一轮是：

```sh
taskset -c 19 bun tools/compare/run_microbench.js \
  --suite p780-uri --formal --cpu 19 --iters 8 --warmup 4 \
  --zjs <zjs-A|zjs-B> --qjs <qjs-A|qjs-B> \
  --emit-scripts .tmp/p780-scripts \
  --output .zig-cache/perf/p7-80/r2-<combo>.json
```

四个组合：`zjsA-qjsA` / `zjsB-qjsB` / `zjsA-qjsB` / `zjsB-qjsA`。
另有一整轮独立的前置采样（另一个测量代次）产物为 `.zig-cache/perf/p7-80/p780-*.json`。

## C：校验

```sh
for f in .zig-cache/perf/p7-80/r2-*.json; do
  bun tools/compare/validate_measurement_artifact.js --formal "$f"
done
```

四份全部 `complete: true`。

## D：PMU（计数模式，无频率采样）

```sh
# instructions / cycles / stall_backend / stall_backend_mem 与
# instructions / cycles / l1d_cache / l1d_cache_refill 与
# instructions / cycles / ll_cache_miss_rd / br_mis_pred_retired
bun .tmp/pmu.js --scripts .tmp/p780-scripts --samples 8 \
  --zjs <zjs> --qjs <qjs> --output .zig-cache/perf/p7-80/p780-pmu-<A|B>.json <case...>

# stall_frontend / mem_access
taskset -c 19 perf stat -x, \
  -e armv8_pmuv3_1/instructions/,armv8_pmuv3_1/cycles/,armv8_pmuv3_1/stall_frontend/,armv8_pmuv3_1/mem_access/ \
  <bin> .tmp/p780-scripts/<case>.js
```

事件一律写全限定 `armv8_pmuv3_1/…`（CPU 19 在该 PMU 上），因此不可能解析到
`<not counted>`（measurement-contracts §6）。8 次 ABBA 采样取中位。

## E：symbol 归因（固定计数 period）

```sh
taskset -c 19 perf record -e armv8_pmuv3_1/cycles/ -c 10007 --no-inherit \
  -o .tmp/rec/<side>.<r>.data -- <bin> .tmp/p780-scripts/p780_L3_full.js
perf report -i .tmp/rec/<side>.<r>.data --no-children --sort symbol --percent-limit 0.05 --stdio
```

`-c 10007`：素数，与内层周期（qjs 833 / zjs 1085 cycles）互质。
**不用 `-F`**（measurement-contracts §2）。每侧 3 次记录，桶内极差见报告。
归属只按 symbol 聚合，无裸 `file:line`（§1）。

## F：每迭代事件计数（gdb 断点，不改任何源码）

```sh
flock -s /tmp/zjs-host-heavy.lock bash .tmp/dyn/collect.sh
```

对 `empty` / `reduced`（256 次内层迭代）/ `probe_hit` / `probe_miss` 四个脚本各跑一次，
断点脚本见 `.tmp/dyn/zjs.gdb` 与 `.tmp/dyn/qjs.gdb`（`ignore <bp> 100000000` +
`info breakpoints` 读命中数）。`probe_hit` / `probe_miss` 是**计数器有效性验证**：
每个计数点必须先在该事件已知存在的场景上被证明能检出，才信任 `reduced` 上的零
（measurement-contracts §5）。

## 仓库门禁

```sh
zig fmt --check .
git diff --check
git diff 89fa82d5 -- src/     # 必须无输出
```

`src/` 全程未改，本线不落生产改动，因此未跑 test262。
