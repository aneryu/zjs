# 20 — 构建、测试入口

本册是第 20 卷的**目录**。函数级正文按体积拆开：

| 文件 | 覆盖 |
| --- | --- |
| [20-build.md](20-build.md) | `build.zig`、`build/*.zig`：每个 `pub fn`、每个 `b.step`、无函数的 profile 表 |
| [20-tests.md](20-tests.md) | 测试 shell、`helpers.zig`、中小测试文件（abi/smoke/stress/gc-stress/oom/embedding/bytecode/…） |
| [20-tests-core.md](20-tests-core.md) | `src/tests/core.zig` 每个 `fn` 与每个 `test` |
| [20-tests-parser.md](20-tests-parser.md) | `src/tests/parser.zig` |
| [20-tests-exec.md](20-tests-exec.md) | `src/tests/exec.zig` |
| [20-tests-builtins.md](20-tests-builtins.md) | `src/tests/builtins.zig` |
| [20-tools.md](20-tools.md) | `test262.conf` / `tests/fixtures/` |

写作规范：[`_spec.md`](_spec.md)。函数清单：[`_inventory.tsv`](_inventory.tsv)。引擎分层总览：[00-overview.md](00-overview.md)。

---

## 1. 测试图三句话

1. **三个编译根**：公共 `src/root.zig` ⊂ 内部 `src/internal_root.zig` ⊂ 统一 `src/all_tests.zig`。生产 CLI 编内部根；`zig build test` 编统一根；`test-embedding` 是唯一把公共根当 `zjs` 模块来编的测试产物。
2. **统一套件是唯一 Zig 单测编译**：子系统选择走 `test-fast` 运行期过滤，不为每个领域再编一份根。
3. **每份引擎模块自己的 `addOptions`**：Debug 产物与 ReleaseFast 产物不得共享同一 options 对象，否则会 attest 错 `optimize`。

细节与 attest 矩阵：[docs/testing-graph.md](../testing-graph.md)。

---

## 2. GUIDE B.6 验证梯子（短式）

义务权威是 [docs/verification-policy.md](../verification-policy.md)，不是本册。梯子上的**仪器**如下。

**内循环**

```bash
zig build check                          # 只 sema，不 codegen/link/跑测试
mise run test-fast -- '测试名子串'       # 同一统一二进制，运行期过滤；空选择失败
git diff --check
# 直接复现：JS 夹具或 run-test262 -d/-f 切片
```

子系统选择：`mise run test-fast -- 'tests.core.'`（或其它名字子串），空选择失败。

CLI/runtime 胶水：`mise run quick-gate`（= Debug `smoke-dev`）。

**每改动收尾**

```bash
zig build test                           # 统一套件，默认 16 分片，跳过 tests.stress.*
```

**checkpoint**（额外表面需要时；收尾仍是一次 `test`）

```bash
mise run checkpoint-gate                 # test + gc-stress + smoke-dev + check-embedding
```

不含 Fast `zjs`、不含全量 test262、不含 `test-stress`。碰栈展开/bigint 内核时本地加 `zig build test-stress`。

**合并批 / 发布**

```bash
mise run batch-gate                      # checkpoint-gate + test-stress + test262-check（与 CI linux-arm64 同组）
mise run production-gate                 # engine-production-gate：再加 zjs-profile smoke 与 test-embedding 全跑
zig build test test-stress -Doptimize=ReleaseSafe --summary all
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

生产配置签名（编译期钉死）：

```
zjs-config-v3:compiler=v2,layout=short,repr=tagged,gc_layout=obj64_m,optimize=ReleaseFast,force_gc=off,ownership_audit=off
```

| 步骤 | 编什么 | 谁依赖 |
| --- | --- | --- |
| `zjs` | Fast CLI | install、smoke、config-signature-check、perf-benchmark |
| `zjs-dev` | Debug CLI | smoke-dev / quick-gate |
| `zjs-profile` | Fast + opcode profile | smoke（profile 合同） |
| `zjs-size` | 跟随 `-Doptimize` 的体积实验 | 不进门 |
| `run-test262` | Fast runner | `test262-check` |
| `check` | 统一根 sema-only | **无门依赖** |
| `test` | 统一根，16 分片，跳过 stress | checkpoint / production |
| `test-stress` | 同一二进制 `--only-prefix tests.stress.` | batch-gate / production / CI |
| `test-gc-stress` | 同一二进制 + GC 诊断环境 | checkpoint |
| `test-oom` / `test-leak-census` | test-oom 独立产物；leak-census 复用统一二进制 | 夜间 |
| `test-embedding` / `check-embedding` | 公共根；后者 sema-only | production / checkpoint |
| `quick-gate` | smoke-dev | 内循环胶水 |
| `checkpoint-gate` | 见上表 | 需要额外表面时 / batch-gate |
| `engine-production-gate` | 见 B.6 | 发布 / 夜间 |

Run 步可选钉核：`-Dgate-run-cpus`（默认不钉）。

---

## 4. 输入与夹具（文件级）

- **`test262.conf`**：全量 test262 的 INI（模式、async/module、features、errorfile）。`test262-check` 传 `-c test262.conf -d test262/test`。exclude 只能收紧，不能为绿而放宽。
- **`test262/` 子模块**：上游用例。本系列不逐文件讲。
- **`tests/fixtures/`**：仓内 harness 与 overrides（见 [20-tools.md](20-tools.md)）。
- **`src/tests/*.zig`**：Zig 单测体；统一编译根是 `src/all_tests.zig`。

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
  src/all_tests.zig \
  src/tests/builtins.zig src/tests/bytecode.zig src/tests/core.zig \
  src/tests/embedding_examples.zig src/tests/engine_production.zig src/tests/exec.zig \
  src/tests/gc_stress.zig src/tests/helpers.zig src/tests/oom.zig src/tests/oom_cap.zig \
  src/tests/parser.zig src/tests/smoke_test.zig src/tests/stress.zig
```

`build.zig` / `build/*.zig` 的 13 个函数已纳入 `_inventory.tsv`；函数条目见 [20-build.md](20-build.md) 文末列表。
