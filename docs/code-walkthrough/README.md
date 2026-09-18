# zjs 源码逐函数讲解

zjs 是用 Zig 写的可嵌入 JavaScript 引擎，语义权威是 ECMA-262（test262 验证），QuickJS 是对照实现。本系列按分层把 **`src/` 与构建入口的非测试函数** 讲一遍，作为现有 [architecture.md](../architecture.md) 的函数级展开。

先读 [00-overview.md](00-overview.md)，再按一次 `eval` 的数据流往下走。写作规范见 [_spec.md](_spec.md)。函数清单见 [_inventory.tsv](_inventory.tsv)。

## 阅读顺序（数据流）

```
宿主 / CLI
    → 公共 API（01）
    → lexer / parser（02–03）
    → compiler + bytecode（04–05）
    → core：值 / 对象 / GC / Runtime（06–10）
    → VM 内核与 opcode（11–12）
    → 调用、属性、内建、模块（13–17）
    → 事件循环、库、CLI、构建与测试（18–20）
```

怎么查一个函数：在 [`_inventory.tsv`](_inventory.tsv) 里搜名字拿到 `file:line`，再打开 [`_filemap.md`](_filemap.md) 对应源文件的分册，或直接 `rg 'fnName' docs/code-walkthrough`。

## 分册

| 册 | 文件 | 覆盖 |
| --- | --- | --- |
| 00 | [00-overview.md](00-overview.md) | 项目地图、一次 eval 的路径、表示与 GC、如何用本系列 |
| 01 | [01-public-api.md](01-public-api.md) | `src/root.zig`、`internal_root.zig`、`binding/`、配置签名 |
| 02 | [02-lexer.md](02-lexer.md) | `lexer.zig`、`simple_token.zig` |
| 03 | [03-parser.md](03-parser.md) | `parser.zig`（词法之后的语法、作用域、发射） |
| 04 | [04-compiler.md](04-compiler.md) | `src/compiler/`：builder、变量/标签解析、CFG |
| 05 | [05-bytecode.md](05-bytecode.md) | `bytecode.zig`、`opcode_logical.zig`（子文档：opcodes / function / function-def / pipeline / binding） |
| 06 | [06-core-value.md](06-core-value.md) | `JSValue`、atom、string、number、bigint、json、uri、error |
| 07 | [07-core-object.md](07-core-object.md) | `object.zig` 对象模型与 payload 访问 |
| 08 | [08-core-shape-property.md](08-core-shape-property.md) | shape、property、array、class、function、typed array、collection |
| 09 | [09-gc.md](09-gc.md) | tracing GC：registry、block heap、mark/sweep、conservative scan |
| 10 | [10-core-runtime.md](10-core-runtime.md) | `JSRuntime`、`JSContext`、jobs、module 记录、句柄 |
| 11 | [11-vm-kernel.md](11-vm-kernel.md) | `run`→Machine→尾分发外壳、`VmExecState` ABI、剖析与精确根；子册：[dispatch](11-vm-dispatch.md) / [colds](11-vm-dispatch-colds.md) / [frame-stack](11-vm-frame-stack.md) / [inline-calls](11-vm-inline-calls.md) |
| 12 | [12-vm-opcodes.md](12-vm-opcodes.md) | `vm_*.zig` / `vm_property_*.zig` opcode 族 |
| 13 | [13-calls.md](13-calls.md) | call / construct / eval / closure / native / CallSite |
| 14 | [14-property-ops.md](14-property-ops.md) | 属性读写、object 抽象操作、slot、class init |
| 15 | [15-array-string-iterator.md](15-array-string-iterator.md) | Array / String / Iterator / for-of |
| 16 | [16-async-modules.md](16-async-modules.md) | Promise、async/generator、module graph、using/disposable |
| 17 | [17-builtins.md](17-builtins.md) | 其余内建、standard_globals、builtin_dispatch |
| 18 | [18-runtime-cli-abi.md](18-runtime-cli-abi.md) | 事件循环、CLI、test262 runner、FNABI |
| 19 | [19-libs.md](19-libs.md) | regexp、unicode、bigint、number_format |
| 20 | [20-build-tests.md](20-build-tests.md) | `build.zig`、测试入口、架构依赖检查 |

大文件拆成同编号子文档（例如 `03-parser-emit.md`），主文件里有目录。源文件对照表：[`_filemap.md`](_filemap.md)。

## 和现有文档的关系

| 已有文档 | 本系列补充什么 |
| --- | --- |
| [architecture.md](../architecture.md) | 层与入口；本系列把入口下的函数写开 |
| [public-api-contract.md](../public-api-contract.md) | 对外契约；01 册讲 binding 如何实现契约 |
| [compiler-contract.md](../compiler-contract.md) | 编译器身份规则；04–05 册讲实现 |
| [gc-invariants.md](../gc-invariants.md) | 生产 tracing 收集器不变量；09 册讲当前函数 |
| [embedding-cookbook.md](../embedding-cookbook.md) | 怎么用；本系列讲引擎内部 |

## 规模（当前树）

当前树扫描（`_inventory.tsv`，含 `noinline fn`；历史清单保留测试辅助函数，但测试不属于本轮讲解验收范围）：

| 项 | 数量 |
| --- | ---: |
| `src/**/*.zig` | 224 |
| 函数 / 方法（含 `inline` / `noinline` / 私有） | 10,359 |
| 讲解 Markdown | 153 篇 |
| 带 `file.zig:LINE` 的 `###` 标题 | 12,501 |
| 清单与标题 | 按当前源码声明的文件、行号、函数名核对；不代表正文已通过语义审核 |

清单另含构建入口的 21 个函数，共 10,380 条。19 个 `src/` 零函数文件（error set、re-export、ABI 类型）按文件讲解，不漏。`build.zig` / `build/*.zig` 的 21 个函数有条目。`test262/` 子模块不在范围内。

清单随源码变化；若源码改了而分册没跟上，以源码为准。核对脚本：[`_check_coverage.py`](_check_coverage.py)。
