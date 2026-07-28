# Zig build bistability（2026-07-28 发现）

- **状态**：调查中；**所有正式 A/B/C 性能采样已暂停**
- **影响面**：不限于 1A。任何需要比较**两个独立构建产物**的性能裁决都受污染
- **调查分支**：`investigate/zig-build-bistability`
- **1A experiment commit**（不 amend，保留原样）：`a2447792`
- **诊断工具**：`tools/perf/compare_symbol_disassembly.py`（commit `3741a9b8`）

---

## 1. 现象

同一 commit、同一命令、同一工具链，`zig build zjs` 产出的二进制在**两个确定的代码状态**之间交替。
这不是布局位移，**代码体本身不同**。

```text
冷构建（每次全新 local cache）：
  p1 == p3        p2 == p4        相邻皆不同      → 严格 X Y X Y 交替
```

差异集合在多次测量中**完全相同**：

```text
|d12| = |d23| = |d34| = 1575        d12 == d23 == d34        交集 = 1575
```

（用更精确的 `compare_symbol_disassembly.py` 重测同一对二进制得 `size_changed 203` /
`body_changed 2193`；早期粗糙脚本的 209/1366 低估了差异，因为它未保留分支距离等语义字段。
结论不变：这是一个确定的二元切换，不是随机噪声。）

## 2. 环境与命令

| 项 | 值 |
|---|---|
| Zig | `0.16.0`（mise: `/home/aneryu/.local/share/mise/installs/zig/0.16.0`） |
| 命令 | `zig build zjs --seed 0 [--cache-dir <dir>] [-j1]` |
| commit | `a2447792`（Phase 1 分支），工作区 **clean** |
| local cache | 每次 `mktemp -d` 全新 |
| **global cache** | ⚠️ **未隔离** —— 全程共享 `~/.cache/zig`（见 §5 C1） |
| 主机 | aarch64 big.LITTLE，Cortex-X925 + Cortex-A725，20 核 |
| 绑核 | 构建未绑核（测量绑 CPU 19） |

## 3. 已排除的假设

| 假设 | 测试 | 结果 |
|---|---|---|
| `--seed` 是布局变量 | seed 0 / 1 / 2 | **排除**：热缓存下三者收敛到同一 `.text` |
| 并行编译顺序 | `-j20` → `-j1` | **部分相关**：不稳定率 2/2 → 1/3，**未消除** |
| ASLR 影响编译器内部指针哈希遍历 | `setarch -R` + `-j1` ×4 | **排除**：p1/p2/p4 相同、p3 跳到另一态 |
| 增量缓存部分命中 | 每次全新 local cache ×4 | **未解释**：4/4 文件 hash 全不同，但严格 X Y X Y 交替 |

## 4. 差异的结构

### 4.1 顶层前缀分布（1575 符号，早期口径）

```text
exec       948
core       213
parser     138
Io          56
libs        55
bytecode    43
debug       24
sort        19
```

### 4.2 constructor 热路径**受影响**

这是本问题阻塞 1A 的直接原因 —— 两态不是"无害的额外 lineage"：

| symbol | 两态间 |
|---|---|
| `exec.call_runtime.constructOrdinaryBytecodeFunctionObject` | **DIFFERS** |
| `exec.call_runtime.constructSimpleFieldConstructor` | **DIFFERS** |
| `core.object.Object.materializeAutoInit` | **DIFFERS** |
| `exec.call_runtime.callFunctionBytecodeConstruct` | **DIFFERS** |
| `core.object.Object.defineOwnPropertyAssumingNew` | identical |
| `core.object.Object.materializeAutoInitEntryForMutation` | identical |
| `core.object.Object.getOwnConstructorPrototypeObject` | identical |

## 5. 调查漏斗（C 路线）

### C1 — 隔离 local cache、global cache 与 install 阶段 ← **下一步**

⚠️ **已知缺口**：§2 记录的四次"冷构建"**只清了 local cache**，`~/.cache/zig` 全程共享。
因此当前尚未测试真正的完全冷构建。必须同时隔离：

```text
独立 local cache      (--cache-dir)
独立 global cache     (--global-cache-dir)
独立 install prefix   (--prefix)
独立 TMPDIR
```

并分别比较**编译步骤直接产出的 executable** 与 **install 后的 executable**：
若编译产物稳定而安装后交替，问题属 build/install graph 而非 codegen。

### C2 — 捕获并直接执行实际 compiler invocation

用 `zig build --verbose` 保存完整编译调用，绕过 build runner 重复执行同一条 invocation：

```text
直接调用稳定      → build runner / cache / install orchestration 问题
直接调用仍切换    → compiler / LLVM codegen / 源码 comptime 顺序问题
```

### C3 — 定位最早出现差异的产物层

```text
build options / generated modules
  → compiler input command
  → emitted IR 或中间产物
  → object / codegen artifact
  → link input 顺序
  → final executable
```

用 pinned Zig 0.16 支持的 emit 方式，**不为调查升级工具链**。关键分叉：
X/Y 在 IR 前已不同？相同 IR 被生成为两态？还是 object 相同而链接输入顺序不同？

### C4 — 按归属层深入

- **输入/IR 已不同**：comptime `HashMap`/无序容器遍历、依赖地址或插入顺序的声明生成、
  options module 字段生成顺序、文件系统枚举顺序、mutable global/comptime state、
  build graph 中同一模块经不同路径实例化
- **IR 相同而 object 不同**：incremental/global cache、LLVM pass 顺序或随机 seed、
  inliner/code-layout 非确定性、CPU feature 探测或环境输入
- **object 相同而 executable 不同**：link response 文件、object/archive 输入顺序、
  重复 install/link step、section ordering

## 6. 完成条件

仓库侧修复只有达到以下条件才算完成：

```text
3 次全新隔离 local+global cache 的 -j1 构建
+
3 次全新隔离 local+global cache 的默认并行构建
```

六次构建的 **symbol presence / symbol size / normalized per-symbol body /
global normalized signature** 必须完全相同。整体文件 hash 可因 build-id 等非代码元数据不同，
但差异必须被解释并限制在非代码 section。

修复后：独立分支提交 → 跑语义与性能基础门禁 → 合并回 Phase 1 →
**重新冻结新的 1A experiment commit** → 重新证明默认 A 与修复后 HEAD 等价。
（此前尚无正式采样，无数据需要迁移。）

若最终确认是 pinned Zig 0.16 的外部编译器问题：保存最小复现，或至少保存
直接 compiler invocation 的 X/Y 证据，然后退出 C。

## 7. 兜底协议（仅当 C 不可修）

**兜底选 B，不选 A。** 因为 X/Y 改变的是 constructor 热函数的**代码体**，
只强制所有候选落在 X 状态只能回答"A/B/C 在 compiler state X 下的差异"，
无法排除 `variant × compiler_state` 交互。

```text
block     = pad × compiler_state
treatment = A / B / C

4 pad × 2 state = 8 block   或   5 pad × 2 state = 10 block
```

目标状态通过**全局或 anchor state fingerprint** 选择，不得只看一个 constructor 符号。
dossier 必须单独报告：X 状态下的 A/B、B/C、A/C；Y 状态下同样三个；`variant × state` 交互；
pad 内方向一致性；state 本身对 A、B、C 的影响量级。
若 X/Y 使 treatment effect 方向实质反转，结论为 `compiler-state-sensitive / no default change`。

A 路线（强制单一状态）最多用于调查性 pilot，**不能作为改变生产默认值的最终证据**。

## 8. 尚未证明的事

- 只证明了**在本文件记录的协议下**严格交替；**未证明**任何环境下都严格交替；
- 未确定切换的触发输入；
- 未测试真正的完全冷构建（global cache 未隔离，见 C1）；
- 未确定该现象是否影响其他 build step（`test-*`、harness、`run-test262`）。

## 9. 由此确立的流程规则

> **验证命令不得通过 `grep` 是否匹配来推断成功。**
> 使用管道时必须启用 `set -o pipefail`，或先保存完整输出并独立检查原命令的退出码。

来源：本轮曾出现 `zig build test-exec` 实际失败、但因输出被 `grep` 过滤而未被发现、
从而带着编译错误完成提交的事故（随后 amend 修正）。
