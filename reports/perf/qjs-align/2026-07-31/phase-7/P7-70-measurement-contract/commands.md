# P7-70 复现命令

全部命令从 worktree 根执行。环境前缀本文件统一写作 `$ENV`：

```sh
cd /home/aneryu/worktrees/zjs-p7-measurement-contract
export ZIG_GLOBAL_CACHE_DIR="$PWD/.zig-global-cache"
export TMPDIR="$PWD/.tmp"
export ZJS_REPO_ROOT="$PWD"
export ZJS_MEASUREMENT_LOCK=/tmp/zjs-host-heavy.lock
export ZJS_MEASUREMENT_LOCK_MODE=exclusive
export ZJS_BUILD_MODE=ReleaseFast
export ZJS_JSVALUE_REPRESENTATION="16-byte payload+tag (zjs_nan_boxing=false, aarch64 default)"
```

锁契约：编辑 / grep / objdump / JSON 分析不取锁；构建与测试取 `flock -s`；
**正式采样取 `flock -x`**。

## Part A：合同测试与红队

```sh
# 合同测试（纯函数，不需要二进制，不占锁）
zig build perf-measurement-contract
bun tools/compare/test_measurement_contract.js \
  --output reports/perf/qjs-align/2026-07-31/phase-7/P7-70-measurement-contract/measurement-contract-tests.json

# 红队（要求干净 worktree；会真实拉起 runner 与 validator）
flock -x /tmp/zjs-host-heavy.lock bun tools/compare/test_measurement_redteam.js \
  --zjs "$PWD/.build-a/out/bin/zjs" --qjs /home/aneryu/quickjs/qjs --cpu 19 \
  --workdir .zig-cache/perf/p7-70/redteam \
  --output .zig-cache/perf/p7-70/red-team-results.json
```

## Part B：两个独立冷缓存构建

```sh
flock -s /tmp/zjs-host-heavy.lock bash .tmp/build-a.sh   # 见 binaries.sha256 内嵌脚本
flock -s /tmp/zjs-host-heavy.lock bash .tmp/build-b.sh
```

`binaries.sha256` 记录两次构建的 sha256、体积、`.text` 体积与构建命令。
两个构建**不是**逐字节相同，因此本轮没有免费噪声尺。

## Part C：正式采样

```sh
# 主轮：75 case，CPU 19，8 样本，warmup 4，独占锁
flock -x /tmp/zjs-host-heavy.lock taskset -c 19 bun tools/compare/run_microbench.js \
  --formal --cpu 19 --iters 8 --warmup 4 \
  --zjs "$PWD/.build-a/out/bin/zjs" --qjs /home/aneryu/quickjs/qjs \
  --output .zig-cache/perf/p7-70/microbench-75-run-a.json

# 独立验证轮：16 个 case（top10 绝对差 + top5 执行主导比值 + 5 个稳定哨兵），全新执行轮
flock -x /tmp/zjs-host-heavy.lock taskset -c 19 bun tools/compare/run_microbench.js \
  --formal --cpu 19 --iters 8 --warmup 4 \
  --case uri_component_decode_4byte --case uri_decode_4byte --case arrow_call_loop \
  --case call2_loop --case closure_call_loop --case array_map_callback \
  --case vm_int_sum_large --case dense_array_write_read --case proto_read \
  --case global_read_loop --case math_min --case prop_read_poly3 \
  --case prop_read_mono --case regexp_test_cached --case func_call --case int_sum \
  --zjs "$PWD/.build-a/out/bin/zjs" --qjs /home/aneryu/quickjs/qjs \
  --output .zig-cache/perf/p7-70/microbench-validation-run-b.json

# 构建实例敏感性：同样 16 个 case，换成 zjs-B x qjs-B
flock -x /tmp/zjs-host-heavy.lock taskset -c 19 bun tools/compare/run_microbench.js \
  --formal --cpu 19 --iters 8 --warmup 4 <同样的 --case 列表> \
  --zjs "$PWD/.build-b/out/bin/zjs" --qjs /home/aneryu/quickjs-zjs-ref/qjs \
  --output .zig-cache/perf/p7-70/microbench-build-instance-b.json
```

## 放大诊断（5 个，诊断性）

```sh
flock -x /tmp/zjs-host-heavy.lock taskset -c 19 bun tools/compare/run_microbench.js \
  --suite amplified --formal --cpu 19 --iters 8 --warmup 4 \
  --zjs "$PWD/.build-a/out/bin/zjs" --qjs /home/aneryu/quickjs/qjs \
  --output .zig-cache/perf/p7-70/amplified.json
```

## 校验与分析

```sh
bun tools/compare/validate_measurement_artifact.js --formal \
  .zig-cache/perf/p7-70/microbench-75-run-a.json

bun reports/perf/qjs-align/2026-07-31/phase-7/P7-70-measurement-contract/build-pareto.js \
  --run-a .zig-cache/perf/p7-70/microbench-75-run-a.json \
  --run-b .zig-cache/perf/p7-70/microbench-validation-run-b.json \
  --build-b .zig-cache/perf/p7-70/microbench-build-instance-b.json \
  --outdir reports/perf/qjs-align/2026-07-31/phase-7/P7-70-measurement-contract
```

`build-pareto.js` 同时产出 `resolvability.json` / `pareto-current.json` /
`pareto-current.md`，以及三份**裁剪后**可入库的 microbench 产物（保留全部原始样本、
执行顺序、median/p25/p75/IQR、比值、绝对差、启动占比、可分辨分档、stdout 校验和与
stdout/stderr 校验结果；去掉 PMU 审计行与 peak-RSS 探针样本）。完整未裁剪产物留在
`.zig-cache/perf/p7-70/`，不入库。

## 仓库门禁

```sh
zig fmt --check .
git diff --check
flock -s /tmp/zjs-host-heavy.lock zig build test-runner
flock -s /tmp/zjs-host-heavy.lock zig build perf-self-check
ls test262/test | wc -l          # 必须非零，否则不得把缺语料记成引擎失败
flock -s /tmp/zjs-host-heavy.lock zig build test262-smoke
git diff 042e4962 -- src/        # 必须无输出
```

## 采样期间的独占约束

正式采样窗口内不跑：Zig 编译、test262、随机差分、其他 `perf`/`stat`、任何其他
whole-process 基准。本轮曾出现一次违例并已处理：早先被中断的 `zig build
perf-native-callback` 留下了一个仍在跑的 bun 子进程，它持有共享锁并在 CPU 上产生负载；
该进程在正式采样开始**之前**被杀掉，主轮与验证轮均在其之后采集。
