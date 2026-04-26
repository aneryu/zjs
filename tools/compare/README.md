# 对比脚本使用说明

## 位置

- Bun 主脚本：`tools/compare/run_compare.js`
- QuickJS microbench 迁移 runner：`tools/compare/run_microbench.js`
- Shell 包装入口：`tools/compare/compare.sh`
- 兼容旧入口：`tests/zig-smoke/run_compare.sh`

## 作用

用于对比当前仓库中的 Zig 版本 `zjs` 与 C 版本 `qjs` 的：

1. **功能差异**
    - stdout
    - stderr
    - 退出码
2. **性能差异**
    - 多轮 wall-clock 耗时
    - `zig/c` 比值
    - 哪一边更快

## 前置条件

### Zig 版本

默认使用：

```bash
zig-out/bin/zjs
```

如果不存在，请先构建：

```bash
zig build qjs
```

也可以通过环境变量覆盖：

```bash
QJS_ZIG=/path/to/zjs
```

### C 版本

默认按以下顺序查找：

1. `QJS` 环境变量
2. `build/qjs`
3. `quickjs/build/qjs`

可手动指定：

```bash
QJS=/path/to/qjs
```

## 使用方式

### 1. 只做功能对比

```bash
bun tools/compare/run_compare.js --functional-only
```

或：

```bash
bash tools/compare/run_compare.sh --functional-only
```

### 2. 只做性能对比

```bash
bun tools/compare/run_compare.js --performance-only --iters 10 --warmup 2
```

### 3. 同时做功能与性能对比

```bash
bun tools/compare/run_compare.js
```

默认行为是：

- 先做功能对比
- 再对行为一致的脚本做性能测试

### 4. 只比较指定脚本

```bash
bun tools/compare/run_compare.js --script json.js --script math.js
```

也可以传完整路径：

```bash
bun tools/compare/run_compare.js --script tests/zig-smoke/arith.js
```

## 参数说明

- `--functional-only`：只做功能对比
- `--performance-only`：只做性能对比
- `--iters N`：每个脚本基准测试轮数
- `--warmup N`：每个脚本基准预热轮数
- `--script PATH`：指定要比较的脚本，可重复传入
- `-h`, `--help`：显示帮助

## 环境变量

- `QJS_ZIG`：指定 Zig 版可执行文件路径
- `QJS`：指定 C 版可执行文件路径
- `BENCH_ITERS`：默认 benchmark 轮数
- `BENCH_WARMUP`：默认 warmup 轮数

## 输出说明

### 功能对比

一致时输出：

```text
ok   <script>
```

不一致时输出：

```text
FAIL <script> (rc x vs y)
```

并附带 stdout/stderr 差异。

### 性能对比

输出表格字段：

- `c_ms`：C 版平均耗时
- `zig_ms`：Zig 版平均耗时
- `zig/c`：Zig 相对 C 的耗时倍数
- `winner`：更快的一方

## 示例

### 功能验证两个脚本

```bash
bun tools/compare/run_compare.js --functional-only --script arith.js --script vars.js
```

### 对单个脚本做快速性能测试

```bash
bash tools/compare/run_compare.sh --performance-only --iters 2 --warmup 0 --script arith.js
```

## 备注

脚本默认扫描目录：

- `tests/zig-smoke/*.js`

如果功能对比存在失败：

- 默认会返回非 0 退出码
- 默认不会继续把失败脚本纳入性能统计

## QuickJS microbench 迁移

`quickjs/tests/microbench.js` 依赖 QuickJS 专用模块 `qjs:std` / `qjs:os`，
不能直接由当前 `zjs` 执行。迁移 runner 把基准项拆成独立脚本，由外部
Bun 进程计时，并在计时前对比 C `qjs` 与 `zjs` 的 stdout、stderr、退出码。
只有行为一致的 case 会进入性能统计；若后续新增的 case 暂不支持，会标记为
`unsupported`。当前主路径使用 zjs 可执行的迁移脚本片段，覆盖 58 个
QuickJS microbench 派生 case，默认应为 0 个 unsupported。该路径会通过 zjs VM
执行生成的脚本，不使用 `quickjs/tests/microbench.js` 的 CLI 特判。

```bash
bun tools/compare/run_microbench.js --iters 10 --warmup 3 --include-unsupported
```

也可以通过 Zig 构建入口运行默认 microbench：

```bash
zig build microbench -Doptimize=ReleaseFast --summary all
```

列出已迁移的 case：

```bash
bun tools/compare/run_microbench.js --list
```

按 case 或 category 过滤：

```bash
bun tools/compare/run_microbench.js --case int_sum
bun tools/compare/run_microbench.js --category arithmetic
```

输出 JSON 报告：

```bash
bun tools/compare/run_microbench.js --json
bun tools/compare/run_microbench.js --output /tmp/zjs-microbench.json
```

JSON 报告包含：

- `qjs` / `zjs`：参与对比的二进制路径
- `iters` / `warmup`：采样设置
- `summary`：兼容、跳过、unsupported 数量和几何平均
- `cases`：每个 case 的状态、样本、平均值、中位数、最小值、最大值、标准差和 `zjs/qjs` 比值
