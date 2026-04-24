# 对比脚本使用说明

## 位置

- Bun 主脚本：`tools/compare/run_compare.js`
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
3. `../quickjs/build/qjs`

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
