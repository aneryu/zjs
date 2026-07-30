# Zig build bistability（2026-07-28 发现）

- **状态**：已定位到**直接 compiler invocation**；C3/C4 对 1A 延后。**所有正式 A/B/C 性能采样仍暂停**
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

**新口径（`compare_symbol_disassembly.py`，权威）**：同一对二进制为
`size_changed 203` / `body_changed 2193`。早期粗糙脚本报的 209/1366 是**低估** ——
它把裸地址一律替换为占位符，抹掉了分支距离等语义字段。

两个 global normalized signature：`ae585f569f166f313d57…` 与 `648d4f0163126ec08a78…`。

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

## 2.1 归因（C1/C2 后）

> 在固定仓库输入、固定 compiler invocation 和隔离显式状态目录后，pinned Zig 0.16 的直接编译输出
> 仍在两个确定代码状态间交替。**状态选择源尚未定位**到 frontend、comptime、LLVM、linker
> 或 compiler-visible host input。

⚠️ 严格交替**不等于**已证明"编译器内部持久状态每次翻转"。它同样可能来自 PID、文件描述符编号、
inode 序列或其他 compiler-visible host state。本文件不对选择器机制作断言。

## 3. 已排除的假设

| 假设 | 测试 | 结果 |
|---|---|---|
| `--seed` 是布局变量 | seed 0 / 1 / 2 | **排除**：热缓存下三者收敛到同一 `.text` |
| 并行编译顺序 | `-j20` → `-j1` | **部分相关**：不稳定率 2/2 → 1/3，**未消除** |
| ASLR 影响编译器内部指针哈希遍历 | `setarch -R` + `-j1` ×4 | **排除**：p1/p2/p4 相同、p3 跳到另一态 |
| 增量缓存部分命中 | 每次全新 local cache ×4 | **未解释**：4/4 文件 hash 全不同，但严格 X Y X Y 交替 |
| **C1** local+global cache+prefix+TMPDIR 全隔离 | ×4，`-j1` | **排除**：仍严格两态（p1==p3、p2==p4） |
| **C1** install / build graph | raw compile artifact vs installed artifact | **排除**：同一 pass 内**完全一致**（rc=0） |
| **C2** build runner / orchestration | 绕过 runner 直接重复同一条 `zig build-exe` ×4 | **排除**：仍严格两态，且落在**同一对** signature |

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

### C1 — 隔离 local cache、global cache 与 install 阶段 ✅ **已完成**

结果：四类目录全部隔离后**仍严格两态**；且 raw compile artifact 与 installed artifact
在同一 pass 内完全一致 —— **build/install graph 不是切换源**。

隔离的四类：

```text
独立 local cache      (--cache-dir)
独立 global cache     (--global-cache-dir)
独立 install prefix   (--prefix)
独立 TMPDIR
```

并分别比较**编译步骤直接产出的 executable** 与 **install 后的 executable**：
若编译产物稳定而安装后交替，问题属 build/install graph 而非 codegen。

### C2 — 捕获并直接执行实际 compiler invocation ✅ **已完成**

用 `zig build --verbose` 保存完整编译调用，绕过 build runner 重复执行同一条 invocation：

```text
直接调用稳定      → build runner / cache / install orchestration 问题
直接调用仍切换    → compiler / LLVM codegen / 源码 comptime 顺序问题
```

**实测结果：直接调用仍切换。**

单条 invocation（`zig build-exe -OReleaseFast ... -Mbuild_options=<固定 options.zig>`，
`options.zig` 内容 sha `2c288e4d`），每次全新 local+global cache，`-femit-bin` 直出：

```text
pass1 648d4f01…   pass2 ae585f56…   pass3 648d4f01…   pass4 ae585f56…
```

这两个 global signature 与 C1 经 build runner 产出的是**同一对**。
因此归因落在 compiler 侧，build runner 与 orchestration 被排除。

### C3 / C4 — 对 1A **延后**

归因已越过仓库边界：若 C4 确认是 Zig 0.16 缺陷，仓库侧无法修复，产出将是上游最小复现
而非 1A 能等到的结果。因此 1A 转入 §7 的 B 型 blocked experiment，
C3/C4 作为独立基础设施问题推进（见 §10）。

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


---

## 10. 对既有性能资产的影响

**Phase 0 已落库数据仍然有效**：它描述的是带 SHA-256 的固定二进制，那些数字就是那两个二进制的真实表现。
失效的是另一个假设 —— **"重新构建后可以无条件与它作同配置性能比较"**。

在 pinned Zig 或仓库侧修复出现前，任何两个**独立构建产物**之间的性能比较都必须满足其一：

- 固定 exact binary hash，且记录 compiler state；
- 做 matched-state blocking；
- 或明确标记为"仅描述单一 build instance"，**不得**作因果 A/B 结论。

`perf-self-check` 据此登记为 **state-sensitive**：在实现双态 baseline 或 matched-state gate 之前，
**跨 state 的失败不能直接解释为源码性能回退**。

## 11. 最小复现（独立立项，不阻塞 1A）

已保存的证据：完整 direct compiler invocation、固定输入 hash（`options.zig` sha `2c288e4d`）、
四次 `X Y X Y`、两态的 normalized manifest、host 与 Zig 版本、C1/C2 排除矩阵。

缩减为上游最小复现可由另一 agent 并行处理，或在 1A dossier 完成后、
进入下一项多 binary 性能实验前处理。
