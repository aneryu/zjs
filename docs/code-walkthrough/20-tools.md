# 20 — 测试输入

本册交代 `test262.conf` / `tests/fixtures/`。构建图如何跑 test262 见 [`20-build.md`](20-build.md) 的 `addGates`。

---

## 文件级：`test262.conf` 与 `tests/fixtures/`

这两处不是 Zig 函数，但是测试图的输入。

### `test262.conf`（仓根）

`run-test262` / `test262-check` 的 INI。`[config]`：`nostrict=yes`、`strict=yes`、`mode=default`、`async=yes`、`module=yes`、`verbose=yes`、`harnessdir=test262/harness`、`errorfile=test262_errors.txt`、`testdir=test262/test`。`[features]` 列出引擎声称支持的语言特性（含 `=!tcc` 这类实现限制标记）。还有 `[exclude]` 等段排除已知无关或未实现路径。**禁止为了让门禁变绿而放宽 exclude**（AGENTS.md / GUIDE B.6）。

`zig build test262-check` 把它以 `-c test262.conf -d test262/test` 传给 Fast `run-test262`，要求 stdout 含 `Result: 0/`。

### `tests/fixtures/`

仓内 harness 与覆盖夹具，**不是** test262 子模块：

| 路径 | 用途 |
| --- | --- |
| `tests/fixtures/test262/harness/` | 本地精简 harness（`asyncHelpers.js`、`doneprintHandle.js`），给 runner 单测 / 嵌入夹具，不替代 `test262/harness` |
| `tests/fixtures/test262-overrides/test/` | 覆盖上游 test262 个别用例（TypedArray slice species、BigInt string-nan、Error prototype 等 staging） |

统一套件与 CLI smoke 还读 `tests/perf/`、`.zig-cache/smoke-*` 临时脚本；那些由测试自己写。

旁路：`tools/timing_test_runner.zig` 是统一套件的 test runner（分片、`--skip-prefix`、多 `--filter`、leak-census）。属工具树，函数级讲解不在本册重复。

---

## 覆盖核对

- 清单函数数: 0（本册无函数）
- 本文函数标题：无
- 未覆盖: 无
