# 20 — 构建、测试入口

本册是第 20 卷的**目录**。函数级正文按体积拆开：

| 文件 | 覆盖 |
| --- | --- |
| [20-build.md](20-build.md) | `build.zig`、`build/*.zig`：每个 `pub fn`、每个 `b.step`、无函数的 profile 表 |
| [20-tests.md](20-tests.md) | 测试 shell、`tests/harness.zig` + `tests/harness/`、中小测试文件（abi/smoke/gc-stress/oom/embedding/bytecode/…） |
| [20-tests-core.md](20-tests-core.md) | `tests/core.zig` 每个 `fn` 与每个 `test` |
| [20-tests-parser.md](20-tests-parser.md) | `src/parser/tests.zig` |
| [20-tests-exec.md](20-tests-exec.md) | `tests/exec.zig` |
| [20-tests-builtins.md](20-tests-builtins.md) | builtins 段（现并入 `tests/exec.zig`） |
| [20-tools.md](20-tools.md) | `test262.conf` / `tests/fixtures/` |

写作规范：[`_spec.md`](_spec.md)。函数清单：[`_inventory.tsv`](_inventory.tsv)。引擎分层总览：[00-overview.md](00-overview.md)。

---

## 1. 测试图三句话

1. **一个引擎模块**：`src/root.zig` 是 `@import("zjs")`。生产 CLI 和 `test-embedding` 编这一文件。引擎 Zig 套件根是 `test_root.zig`（re-export 同一模块，才能看到 `tests/`）。CLI 测试把 `src/root.zig` 当独立模块 import。
2. **引擎套件是包测试的唯一编译根**：子系统选择走 `test-fast` 编译期 `--test-filter`，不为每个引擎领域再编一份根。CLI / embedding / OOM 是宿主族，各自编译。
3. **一次 `zig build` 一种 `-Doptimize`**：默认 Debug；发货显式 `-Doptimize=ReleaseFast`。需要独立 options 文件时各自 `addOptions`，不为第二种优化模式再钉一颗 CLI。

细节与 attest 矩阵：[docs/testing-graph.md](../testing-graph.md)。

---

## 2. GUIDE B.6 验证梯子（短式）

义务权威是 [docs/verification-policy.md](../verification-policy.md)，不是本册。梯子上的**仪器**如下。

**内循环**

```bash
zig build check                          # 只 sema，不 codegen/link/跑测试
mise run test-fast -- '测试名子串'       # 编译期 --test-filter；空选择失败
git diff --check
# 直接复现：JS 夹具或 run-test262 -d/-f 切片
```

子系统选择：`mise run test-fast -- 'tests.exec.'`（或其它名字子串），空选择失败。

CLI/runtime 胶水：`mise run quick-gate`（= `smoke`）。

**每改动收尾**

```bash
zig build test                           # 引擎套件 + CLI 测试
```

**checkpoint**（额外表面需要时；收尾仍是一次 `test`）

```bash
mise run checkpoint-gate                 # test + gc-stress + smoke + check-embedding
```

不含 Fast `zjs`、不含全量 test262。

**合并批 / 发布**

```bash
mise run batch-gate                      # Debug checkpoint-gate，再 ReleaseFast test262-check
mise run production-gate                 # engine-production-gate -Doptimize=ReleaseFast
zig build test -Doptimize=ReleaseSafe --summary all
```

**仪器层（夜间 CI；改到对应子系统才本地先跑）**

```bash
zig build test-oom --summary all
zig build test-leak-census --summary all
zig build test -Dzjs_ownership_audit=true --summary all
# zig build test -Dzjs_force_gc=true     # 诊断，不是门
```

test262 零失败门在 PR：`zig build test262-check`。本地先跑聚焦切片。

门禁用 mise（`-j32`）；裸 `zig build` 会把多余步骤内联进主线程。

---

## 3. 产物与步骤速查

发货：`zig build -Doptimize=ReleaseFast`，`layout=short`。

| 步骤 | 编什么 | 谁依赖 |
| --- | --- | --- |
| `zjs` | 跟随 `-Doptimize` 的 CLI | install、smoke |
| `zjs-profile` | 同模式 + opcode profile | smoke（profile 合同） |
| `zjs-size` | 同引擎第二安装名 | 不进门 |
| `run-test262` | 跟随 `-Doptimize` 的 runner | `test262-check` |
| `check` | 统一根 sema-only | **无门依赖** |
| `test` | 引擎根 + CLI 测试根 | checkpoint / production |
| `test-gc-stress` | 同一二进制 + GC 诊断环境 | checkpoint |
| `test-oom` / `test-leak-census` | test-oom 独立产物；leak-census 同一根 + 两遍 runner | 夜间 |
| `test-embedding` / `check-embedding` | 公共根；后者 sema-only | production / checkpoint |
| `quick-gate` | smoke | 内循环胶水 |
| `checkpoint-gate` | 见上表 | 需要额外表面时 / batch-gate |
| `engine-production-gate` | 见 B.6 | 发布 / 夜间 |

Run 步可选钉核：`-Dgate-run-cpus`（默认不钉）。

---

## 4. 输入与夹具（文件级）

- **`test262.conf`**：全量 test262 的 INI（模式、async/module、features、errorfile）。`test262-check` 传 `-c test262.conf -d test262/test`。exclude 只能收紧，不能为绿而放宽。
- **`test262/` 子模块**：上游用例。本系列不逐文件讲。
- **`tests/fixtures/`**：仓内 harness 与 overrides（见 [20-tools.md](20-tools.md)）。
- **`src/parser/tests.zig`、`src/bytecode/tests.zig`、`src/compiler/tests.zig`**：Zig 单元测试，跟子系统走。
- **`tests/core.zig`、`tests/exec.zig`、`tests/public_api.zig`**：引擎集成测试，由 `tests/engine.zig` 拉进 `test_root.zig`。

---

## 5. 怎么查一个测试或一个步骤

1. 步骤名 → [20-build.md](20-build.md) 搜 `b.step("`。
2. 测试名 → 对应 `20-tests-*.md` 搜 `` `test "…" ``。
3. 夹具函数 → [20-tests.md](20-tests.md) 的 `helpers.zig` 或大文件册的「函数」节。

源码与文档冲突，信源码。清单随树扫描；若源码改了分册没跟上，以源码和 `_inventory.tsv` 为准。

---

## 覆盖核对

本目录文件本身不承载清单函数。各子文件文末有自己的核对。对任务指定的 Zig 测试文件，用：

```sh
python3 docs/code-walkthrough/_check_coverage.py --docs 'docs/code-walkthrough/20-*.md' \
  src/root.zig tests/harness.zig tests/harness/*.zig \
  tests/exec.zig src/bytecode/tests.zig tests/core.zig \
  tests/embedding_examples.zig src/parser/tests.zig \
  tests/oom.zig tests/smoke_test.zig
```

`build.zig` / `build/*.zig` 的 18 个函数已纳入 `_inventory.tsv`；函数条目见 [20-build.md](20-build.md) 文末列表。
