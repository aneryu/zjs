# PEROP-GUARD-ELISION-PLAN — arg-slot 长期对齐一次性实施计划（2026-07-15）

> 本计划取代此前的双 dispatch table、按函数种类分流 opcode、α/β A/B 候选路线。
> 最终形态只有一种：所有有效 bytecode frame 的 arg slot 恒为裸 `JSValue`，所有
> 参数别名通过 side `VarRef.pvalue` 指向稳定 arg backing，VM 使用单 dispatch
> table，arg opcode 不再识别 cell。

---

## 0. “一次性完成”的定义

本计划允许实现过程中设置内部检查点，但只允许一次最终交付：

- 不交付双表过渡态；
- 不交付“普通函数裸值、generator/async 仍 cellified”的双表示；
- 不保留按 run、函数 flag 或 opcode 形态选择 arg representation 的兼容分支；
- 不以“语义已过、性能以后再测”或“性能已过、GC/OOM 以后再补”为完成；
- 任一最终门禁不满足时，不提交/不宣称完成，保留诊断证据并报告阻塞点。

这里的“一次性”指一次实现会话、一次完整收口，不指一个不可审查的大 patch。
实现者可以按 §5 的顺序做本地 checkpoint，必要时拆成少量聚焦 commit，但这些
commit 不得作为可单独合入的半成品交付。

---

## 1. 硬约束

1. 禁止 `git checkout`、`git stash`、`git reset`、`git clean`、改写历史；不得覆盖
   用户已有未提交改动。文本文件只用 `apply_patch` 编辑。
2. 不删除、跳过、弱化测试，不扩大 test262 excludes，不以 broad mock 或特殊常量
   制造通过。
3. QuickJS 是语义和 representation 参照。偏离逐行镜像处必须写
   `zjs-side adaptation:` 注释并说明 zjs ownership 差异。
4. arg slot 的裸值不变式必须在 representation seam 上证明；禁止把 per-op cell
   guard 移到另一个热 handler、run selector 或函数 flag 判断中伪装成消除。
5. malformed/synthetic bytecode 不得通过把 arg slot 改回 cell 来“保正确”；容量或
   metadata 不满足时必须返回 `error.InvalidBytecode`，且失败前后 arg slot 保持裸值。
6. 性能声明必须给出逐次原始 `instructions`/`cycles`、二进制 sha256、HEAD、构建命令；
   cycles 是取舍尺，未满足 §7.4 噪声判据时只能报告“无结论”。
7. ReleaseSafe 只在最终门禁运行一次；OOM injection 和全量 test262 只在收口运行，
   不在每个小改动后重复。
8. 若需要修改 §2.2 未授权的 production 文件，立即停下，报告缺失 seam；不得静默
   扩 scope。

---

## 2. 决策、scope 与参照

### 2.1 唯一目标模型

| 场景 | frame arg slot | 别名载体 | suspension | teardown |
|---|---|---|---|---|
| ordinary | 裸 `JSValue` | open side `VarRef` | 不适用 | frame 退出前 close |
| generator | 裸 `JSValue` | open side `VarRef` | resident backing 原址保留 | completion/GC 前 close |
| async | 裸 `JSValue` | open side `VarRef` | resident backing 原址保留 | completion/GC 前 close |
| malformed/容量不足 | 不得 cellify | 无 | 拒绝执行 | `InvalidBytecode` |

捕获参数、mapped `arguments`、direct eval、`make_arg_ref` 必须复用同一 arg-slot
`VarRef`。同一 slot 同时存在两个 cell（一个 closed、一个 open）视为 representation
错误。

### 2.2 授权修改范围

Production：

- `src/exec/frame.zig`
- `src/exec/slot_ops.zig`
- `src/exec/call_runtime.zig`
- `src/exec/vm_gen_async.zig`
- `src/exec/tailcall_dispatch.zig`

永久回归：

- `src/tests/exec.zig`
- `src/tests/bytecode.zig`

文档：

- `docs/qjs-align/PEROP-GUARD-ELISION-PLAN.md`
- `docs/qjs-align/PEROP-GUARD-ELISION-PERF-RAW.csv`
- `docs/qjs-align/PEROP-GUARD-ELISION-PERF-SUMMARY.csv`
- `docs/qjs-align/PEROP-GUARD-ELISION-PERF-META.txt`

只读审计锚点，不预期修改：

- `src/core/var_ref.zig`
- `src/core/object.zig`
- `src/exec/object_ops.zig`
- `src/exec/eval_ops.zig`
- `src/exec/vm_property_ref.zig`
- `src/exec/zjs_vm.zig`
- `src/exec/tailcall_dispatch_colds.zig`
- `src/bytecode.zig`

### 2.3 明确不在本次 scope

- `get_var_ref` TDZ/check opcode 分流；
- string/GC refcount offset 统一；
- call setup、return、inline-frame 其他优化；
- mapped `arguments` 超出 formal parameter 数量的独立规范问题；
- dispatch 架构的其他已冻结实验。

这些问题不得夹带进本次 landing。

### 2.4 QuickJS 锚点

基于 `/home/aneryu/quickjs/quickjs.c`：

- `JSStackFrame.arg_buf` 与 `JSVarRef.pvalue`：约 399–463；
- `get_var_ref(..., is_arg)` 令 `pvalue = &sf->arg_buf[var_idx]`：16997–17054；
- `close_var_ref(s)`：17521–17543；
- 通用/短 `OP_get_arg`、`put_arg`、`set_arg` 均直接访问裸 `arg_buf`：18557–18604；
- generator/async 共用 `JSAsyncFunctionState` FAM：20893–20928；
- resume 与完成时 close：20951–20988；
- `get_arg` 通用短化，不按 generator/async 分流：34751 起。

QuickJS 对 async state 增加 refcount，是其 cycle-removal 阶段不能修改 GC graph 的
ownership 选择。zjs 已在 resident locals 上使用 open refs，并在 state teardown 中
close-before-free；本次复用 zjs 既有 implementation，不机械复制 QuickJS backpointer
refcount。

### 2.5 Architecture shape

长期方向的核心不是新增一个 dispatch adapter，而是增加现有 arg-alias module 的
depth：

- `ensureFrameVarRefCell` 是唯一 public interface；它的 implementation 隐藏 arg/local
  分类、cell identity、capacity 与 rollback，因此是一个 deep module；
- `slot_ops.zig` 是四条 alias channel 汇合的 seam。在此修正一次即可同时覆盖 closure、
  mapped `arguments`、direct eval 和 `make_arg_ref`，具有最高 leverage 与 locality；
- 参数环境关闭只在 `frame.zig` 暴露语义 interface，在 `vm_gen_async.zig` 的
  parameter/body seam 调用，避免把生命周期知识散入 opcode handler；
- 双 dispatch table 是 shallow module：selector、第二张表和专用 handler 暴露同一个
  representation 分歧，却没有消除底层分歧；长期形态不保留该 adapter；
- bytecode shortener 不承担 frame ownership，保持 compile-time 与 runtime seam 分离。

---

## 3. 已验证事实与原型结论

### 3.1 zjs 已有的基础

- `VarRef.createOpen` 已让 `pvalue` 指向 frame slot；`close` 会复制值并改指向 cell
  自有 storage。
- `GeneratorExecutionState` 已一次分配 resident stack/frame FAM。
- suspend/resume 会发布同一 args/locals/open-var-ref typed window。
- frame local backing 扩容已会 rebase open `pvalue`；arg backing 当前没有运行时扩容。
- `SuspendedFrameStorage.deinit{Resident}` 已先 close open refs，再释放 args/locals。
- GC trace 已遍历 resident args、var refs、open refs。

### 3.2 真实 VM 原型发现的必要修正

朴素原型仅做“generator/async 允许 open arg alias + 扩大容量”时，`test-exec`
从 203/203 变为 202/204。根因：

1. generator 创建阶段先为 mapped `arguments` 建 arg cell；
2. `vm_gen_async.stopBeforePc` 在参数环境/body seam 调 `closeOpenVarRefs()`；
3. mapped `arguments` 留在旧 closed cell；
4. body closure 再为裸 arg slot 创建新 open cell；
5. `arguments[0]` 与参数/closure 永久断开。

只关闭非 arg refs、保留 `pvalue` 落在 `frame.args` 内的 refs 后：

- `test-exec`：204/204；
- 自引用 suspended generator 经 force-GC 后，arg cell 正确 close，逃逸
  `arguments`/closure 仍联动；
- async/await：`arguments[0]=55 → closure=55 → await 后=55 → resolved=55`；
- generator direct eval：`20 → 30`；
- alternate representation：1407/1407；
- OOM injection：8/8；
- test262 smoke：12/12；
- ReleaseFast 单表构建与 fib 输出通过。

因此“参数环境/body seam 选择性 close”是长期模型的组成部分，不是可选补丁。

### 3.3 已否决路线

- 按 VM run 选择双 dispatch table：保留双 representation、放大 inline-run coupling，
  且多一份 256-entry table；
- generator/async 禁止短 `get_arg`：bytecode 编码承担 runtime ownership 差异，偏离
  QuickJS universal shortener；
- handler 内判断 generator/async flag：仍是 per-op 税；
- 保留 silent closed-cell fallback：会让裸 handler 对 malformed/under-sized frame
  读取内部 cell 对象，soundness 不成立。

### 3.4 全量 test262 暴露的输入表示 seam

移除短 `get_arg` 的 cell guard 后，staging 用例
`derivedConstructorArrowEvalGetThis.js` 暴露了一个此前被 guard 掩盖的内部值泄漏：

1. derived constructor 的 lexical `this` 可以由 zjs 内部 closed `VarRef` 承载；
2. 完整 direct eval 会经 `push_this`/`slotValueDup` 读取 cell 的用户值；
3. `evalSimpleCallerExpression("this")` 快捷路径此前直接 `.dup()` cell representation；
4. 该内部 cell 随后作为普通调用参数进入 frame，违反 I1；
5. 将快捷路径改为 `slotValueDup` 后，最小回归由 `true false` 变为
   `true true`，原 staging test262 由 1/1 失败变为 1/1 通过。

这是 zjs 内部用 `JSValue` 表示 VarRef cell 所需的 representation seam；QuickJS 的
`JSVarRef *` 本身不会成为用户 `JSValue`，因此不存在对应的 cell 泄漏路径。

---

## 4. 必须同时成立的不变式

### I1 — Bare arg slot

所有有效 frame 的 `frame.args[i]` 从初始化到 teardown 恒为用户可见裸 `JSValue`；
`core.VarRef.fromValue(frame.args[i]) == null`。

### I2 — Single alias identity

同一 arg slot 最多一个 live `VarRef`。closure、mapped `arguments`、direct eval、
`make_arg_ref` 全部经 `ensureFrameVarRefCell` 找到/创建并 dup 同一 cell。

### I3 — Stable address

open arg cell 存活期间，其 `pvalue` 必须等于当前 authoritative `&frame.args[i]`。
generator/async 的初始 park、每次 resume、再次 park 均不得改变该地址；若未来新增
arg backing relocation，relocation implementation 必须先 rebase 所有 open refs。

### I4 — Exact-enough capacity

`frameOpenVarRefStorageCount` 对所有 mapped frames（包括 generator/async）加入运行时
arg window 上界，并保留 compile-time captured refs 上界。正常 parser output 不得走
open-ref table 满的分支。

### I5 — Selective parameter-boundary close

generator 尚未 started 时到达 parameter/body seam：

- close 参数-eval/body 环境需要分离的非 arg open refs；
- 保留所有 `pvalue` 指向 `frame.args` 的 refs；
- started 后的 yield/finally suspension 不做该 close。

### I6 — Close before backing release

completion、abandonment、cycle GC、error unwind 均先 close open arg refs，再释放 resident
args backing。外部仍持有的 mapped `arguments`/closure 必须看到 closed cell 的最终值。

### I7 — No fallback cellification

对 arg slot：open-ref storage 缺失、表满、slot 已是 cell 或 slot 不属于当前 frame，均
返回 `InvalidBytecode`；失败不得改写 arg slot。local/lexical 的既有 closed-cell 语义
保持不变。

### I8 — One dispatch representation

只保留一个 hot dispatch table。短和通用 `get_arg`/`put_arg`/`set_arg` 都直接操作裸
slot；不得调用 `slotValueBorrow`/`setSlotValue` 去兼容 arg cell。Debug 可断言不变式，
Release 热路径不得含 cell tag/class 检查。

---

## 5. 一次性实施顺序

### Step 0 — 基线冻结与工作区保护

1. 记录 `git rev-parse HEAD`、`git status --short`、`git diff --check`。
2. 明确现有 `tailcall_dispatch.zig` 双表原型属于待吸收改动，不覆盖其他用户修改；
   将其 diff、构建命令和 binary 单独保存为 dual 候选证据。
3. 在隔离的临时 worktree 构建 `HEAD` guard-aware 基线；不得为此还原主工作区：

   ```bash
   git worktree add --detach /tmp/zjs-arg-slot-head "$(git rev-parse HEAD)"
   (cd /tmp/zjs-arg-slot-head && zig build zjs -Doptimize=ReleaseFast --summary all)
   cp /tmp/zjs-arg-slot-head/zig-out/bin/zjs /tmp/zjs-arg-slot-guard
   sha256sum /tmp/zjs-arg-slot-guard
   ```

4. 在主工作区不改代码，构建并保存现有 dual 原型：

   ```bash
   git diff -- src/exec/tailcall_dispatch.zig > /tmp/zjs-arg-slot-dual.patch
   zig build zjs -Doptimize=ReleaseFast --summary all
   cp zig-out/bin/zjs /tmp/zjs-arg-slot-dual
   sha256sum /tmp/zjs-arg-slot-dual
   zig build test-exec --summary all
   zig build test-bytecode --summary all
   ```

5. 用 QuickJS、guard 与 dual 运行 §7.4 的固定脚本，保存逐字输出和 perf 原始值。

### Step 1 — 先加入永久回归（预期红）

在 `src/tests/exec.zig` 加入真实 VM 测试：

1. **mapped generator 结构测试**：
   - `frame.args[0]` 是裸值；
   - mapped `arguments` payload 中的 cell 与 `open_var_refs` 中的 cell 指针相同；
   - `cell.pvalue == &state.storage.frame.args[0]`；
   - resume 前后 arg slot 地址不变。
2. **alias 行为测试**：`arguments[0]`、参数读、closure、direct eval 跨两次 resume
   双向联动。
3. **cyclic abandonment 测试**：suspended generator 自引用，移除外部 generator
   引用并 force-GC；保留的 cell 变 closed，逃逸 `arguments`/closure 仍联动。
4. **async/await 测试**：mapped arg 写入在 await 前后、closure 与 promise resolution
   中保持同一值。
5. **parameter/body seam 测试**：非 arg parameter-eval refs 仍关闭，arg refs 保持
   open；现有 `generator parameter eval cells close before body resume` 必须继续通过。
6. **通用 opcode 测试**：使用索引 ≥4 的参数覆盖通用 u16 `get_arg`/`put_arg`/
   `set_arg`，同时检查 slot 仍为裸值。
7. **malformed capacity 测试**：构造 open-ref capacity 为 0/满的 synthetic frame，
   `ensureFrameVarRefCell` 返回 `InvalidBytecode`，arg 未被 cellify、无 cell 泄漏。

在 `src/tests/bytecode.zig` 加入 sizing 测试：

- ordinary/generator/async mapped frame 都得到 `static_count + frame_arg_count` 上界；
- non-mapped frame 保持 `static_count`；
- captured arg 与 mapped window 共存时容量足够，允许空余 null slot；
- alternate representation 下 typed pointer tail partition 对齐不变。

先运行定向测试并记录预期失败点；失败必须命中 representation/close/capacity 断言，
不能是无关 crash。

### Step 2 — 深化 arg-alias module

在 `src/exec/slot_ops.zig` 保留 `ensureFrameVarRefCell` 作为唯一深 interface；其
implementation 吸收 slot 分类、容量、复用和错误语义，调用者不感知 frame kind：

1. `frameSlotCanOpenAlias` 允许 locals 和 args，不再读取 generator/async flags。
2. 若 arg slot 已含 cell，返回 `InvalidBytecode`；不得复用/继续嵌套。
3. 先用 `findOpenVarRef` 复用同一 `pvalue` cell。
4. 新建 open cell 后加入 `frame.open_var_refs`；加入失败时 close/free 临时 cell，
   返回 `InvalidBytecode`，不调用 `ensureVarRefCell`。
5. local/lexical/TDZ 的 closed-cell 路径维持原行为。
6. 保留四个 arg alias 入口的只读审计：
   - closure capture：`object_ops.createBytecodeFunctionObject`；
   - mapped arguments：`object_ops.createArgumentsObject`；
   - direct eval：`eval_ops.directEvalSeedFrameVarRef`；
   - reference opcode：`vm_property_ref.makeSlotRef`。

在 `src/exec/frame.zig`：

1. `frameOpenVarRefStorageCount` 对 generator/async mapped frames 也加入动态上界；
2. 新增语义明确的 `closeParameterEnvironmentVarRefs`（名称可按现有风格微调）：
   implementation 关闭所有非 arg open refs，保留 `pvalue` 位于 `frame.args` 的 refs；
3. `closeOpenVarRefs` 继续表示 teardown 的全量 close，两个 interface 不得混用。

### Step 3 — 修正 generator parameter/body seam

在 `src/exec/vm_gen_async.zig::stopBeforePc`：

- generator 尚未 started 时调用 `closeParameterEnvironmentVarRefs`；
- started 后保持现有 park 行为；
- 注释同时记录 QuickJS resident `arg_buf` 与 zjs parameter-env adaptation；
- 不在 `parkGeneratorExecutionState`、resume 或 GC path 增加第二套 arg 特判。

完成后先跑 Step 1 的 seam、mapped generator、cycle-GC 测试，确认最初原型的
202/204 反例已被锁死。

### Step 4 — 统一 arg opcode 与 dispatch

先在 `src/exec/call_runtime.zig::evalSimpleCallerExpression` 收紧 frame 输入边界：

- `"this"` 快捷路径必须与完整 direct eval 的 `push_this` 一致，经
  `slotValueDup` 返回用户值；
- 不得直接 `.dup()` 可能承载内部 VarRef cell 的 slot representation；
- 用 derived constructor + arrow + direct eval 的真实 VM 回归证明结果为同一
  `this`，并定向运行对应 staging test262。

在 `src/exec/tailcall_dispatch.zig`：

1. `op_get_arg_short` 改为 `arg_buf[idx].dup()`；Debug-only assert arg 不是 cell；
2. 删除 `op_get_arg_short_plain`；
3. 删除 `plain_arg_dispatch_table`；
4. 删除 `dispatchTableFor`；
5. `run` 恒安装唯一 `dispatch_table`。

在 `src/exec/slot_ops.zig`：

1. `execGetArg` 直接 dup 裸 slot，不调用 `pushSlotValue`；
2. `execPutArg`/`execSetArg` 采用“先存新值、再 free 旧值”的裸 slot ownership 顺序，
   不调用 `setSlotValue`；
3. Debug-only assert 被覆盖的 arg slot 不是 cell；
4. 保留既有 bounds/stack-underflow 错误语义。

不得修改 `bytecode.selectShortSlot`：普通、generator、async 继续使用同一短化规则，
与 QuickJS 对齐。

### Step 5 — 删除迁移残留并做静态审计

必须满足：

```bash
rg -n "op_get_arg_short_plain|plain_arg_dispatch_table|dispatchTableFor" src/exec
rg -n "Generator/async parameter aliases stay closed|resident args may be cells" src/exec
rg -n "varRefCellFromValue" src/exec/tailcall_dispatch.zig
```

预期第一、第二条零结果；第三条不得命中 arg handlers（其他 local/var-ref handler
命中允许）。再次审计 `ensureFrameVarRefCell(` 的所有调用点，确认没有第五个 arg
cellification 入口。

---

## 6. 验证矩阵

| 风险 | 必须覆盖的证据 |
|---|---|
| mapped alias 分裂 | arguments payload cell 与 open-list cell identity 相同 |
| suspend/resume 悬垂指针 | 两次 resume 前后 arg 地址与 `pvalue` 相同 |
| parameter env 语义回归 | 非 arg refs close、arg refs stay open |
| normal completion | cell close 一次，最终值保留 |
| suspended abandonment | generator 释放后逃逸 alias 继续工作 |
| cycle removal | self-cycle + force-GC，无 UAF/泄漏/断链 |
| async ownership | await 前后 mapped arg/closure/promise 同值 |
| direct eval | eval 写 arg 与 mapped/closure 双向可见 |
| direct eval `this` 输入 seam | derived constructor 的 arrow/eval 均返回同一裸 `this` |
| malformed metadata | `InvalidBytecode`，arg 不变，无 fallback cell |
| short opcode | arg 0–3 裸读写 |
| generic opcode | arg ≥4 裸读写 |
| missing/extra args | undefined/actual-count 语义不变 |
| alternate JSValue | 16B repr 全套通过 |
| allocation failure | OOM injection + same-runtime recovery |

所有新增 throw site 若能到达用户代码，必须使用 message-carrying throw helper；本次
预期的 `InvalidBytecode` 属于内部 malformed path，不制造 JS-visible 新异常文本。

---

## 7. 门禁与测量

### 7.1 内循环门禁

每个内部 checkpoint 选择最窄证明：

```bash
zig build test-bytecode --summary all
zig build test-exec --summary all
zig build quick-check --summary all
git diff --check
```

### 7.2 最终语义/ownership 门禁

按此顺序一次跑完：

```bash
zig build checkpoint-check --summary all
zig build test-altrepr --summary all
zig build test-oom --summary all
zig build test262-smoke --summary all
zig build test262-gate --summary all
zig build test -Doptimize=ReleaseSafe --summary all
git diff --check
```

验收：

- Debug/alternate-repr/OOM 全绿；
- test262 全量 0 新失败，known-errors 集合逐位一致；
- 无临时日志、`PROTOTYPE` 测试名、debug tag、临时脚本进入 repo；
- 默认 8B 与 alternate 16B representation 都不含 arg cell 双表示。

### 7.3 ReleaseFast 与二进制结构

```bash
zig build zjs -Doptimize=ReleaseFast --summary all
size zig-out/bin/zjs
sha256sum zig-out/bin/zjs
```

反汇编/符号检查必须证明：

- 只有一个 256-entry hot dispatch table；
- `op_get_arg_short` ReleaseFast 不含 VarRef tag/class/header-kind 判别；
- 不存在 run-level table selector；
- 不因本次改动新增第二份 `.data` table。

### 7.4 性能协议与验收

固定环境：Cortex-X925，`taskset -c 19`，事件
`instructions,cycles`。只使用：

- `/tmp/fib30x3.js`（既定逐字脚本，输出 `2496120`）；
- `tests/perf/qjs-align/` 现有 `call-*.js`；
- `/home/aneryu/quickjs/qjs` 作参照。

保存并比较三个独立 binary：

- `/tmp/zjs-arg-slot-guard`：隔离 worktree 中的 `HEAD` guard-aware 基线；
- `/tmp/zjs-arg-slot-dual`：本次开始时已有的双 dispatch table 原型；
- `/tmp/zjs-arg-slot-candidate`：最终长期单表候选。

每个 binary 先 warm-up 5 次，再用平衡顺序
`guard,dual,candidate,candidate,dual,guard` 运行 15 个 block；逐次保留原始 perf 输出，
同时记录 sha256、`size`、HEAD、kernel、CPU governor 与构建命令。以每个 block 的配对
ratio 计算中位数、MAD 和 95% bootstrap confidence interval；分析脚本只放 `/tmp`，
不得进入 repo。

硬验收：

- 所有输出与 QuickJS 逐字一致；
- candidate 的 ReleaseFast `op_get_arg_short` 比 guard 基线少掉 cell
  tag/class/header-kind 路径，fib 动态 instructions 的配对中位数必须低于 guard；
- candidate 相对 guard 和 dual 的 cycles ratio，其 95% confidence interval 上界都
  必须小于 `1.015`；任一现有 `call-*.js` 也适用该 1.5% 非回退线；
- candidate 不得保留 dual 的第二张 256-entry table，`.data`/总 binary size 不得出现
  无法由符号或对齐解释的增长；
- 只有收益 delta 大于对应组内噪声带 3 倍时，才声明“性能提升”；否则写
  “已测得非回退，提升幅度无统计结论”，但不把测量延期；
- 若 15 个 block 仍无法证明 1.5% 非回退界，扩到 30 个 block；仍无结论则本次
  一次性 landing 不收口。

cycles 与 instructions 冲突时以 cycles 为准；insn 降但 cycles 升视为失败。

---

## 8. 停手条件与禁止绕法

出现以下任一情况，停止 landing、保留失败证据并报告：

1. parser 产物能合法触发 arg open-ref 容量不足；
2. 选择性 close 无法同时保持 mapped arg alias 与 parameter-eval 环境隔离；
3. cycle GC 中 close arg refs 导致 graph mutation/UAF/泄漏；
4. async 需要独立于 generator 的第二种 arg representation；
5. generic arg opcode 仍需 cell-aware helper 才能保持现有语义；
6. 必须修改 §2.2 之外的 production 文件；
7. test262、alternate-repr、OOM 或 ReleaseSafe 出现由本改动引入的失败；
8. 严格性能门禁不满足。

禁止绕法：

- 恢复 dual dispatch table；
- 给 handler 加 `is_generator`/`is_async` flag guard；
- generator/async 禁止短 opcode；
- capacity 不足时 silently closed-cell fallback；
- 为过门禁扩大 excludes、改预期或跳过 GC/OOM 场景。

---

## 9. 交付物与完成定义

一次性完成时必须同时交付：

1. 单一 arg representation 的 production implementation；
2. 参数/body seam 选择性 close；
3. malformed capacity 的 fail-closed 行为；
4. 单 dispatch table 与裸 short/generic arg opcode；
5. §6 的永久结构、语义、GC、async、direct-eval、malformed 回归；
6. §7 全部门禁结果；
7. 完整 perf 原始值、sha256、HEAD、二进制 size；
8. QuickJS 锚点与所有 `zjs-side adaptation:` 说明；
9. 工作区无 throwaway 原型、临时日志或无关改动。

最终总结必须明确列出：

- 修改文件；
- 八条不变式如何得到证明；
- base/candidate/QuickJS 原始与汇总数据；
- 所有门禁状态；
- 未完成项（理想状态为“无”）。

只有以上九项全部满足，才能宣称本计划“一次性完成”。

---

## 10. 实施与最终验收证据（2026-07-15）

### 10.1 最终实现面

实施基于 zjs HEAD `f615af3f9ba4b7bd6094f3faf3cd571f54288c13`，最终修改：

- `src/exec/frame.zig`：mapped ordinary/generator/async 统一预留 arg open-ref
  上界；新增 parameter/body seam 的选择性 close；
- `src/exec/slot_ops.zig`：arg/local alias 统一走 deep helper，arg malformed
  路径 fail-closed；通用 arg opcode 直接读写裸值；
- `src/exec/vm_gen_async.zig`：generator 未 started 时只关闭非 arg 参数环境
  refs；
- `src/exec/tailcall_dispatch.zig`：单 dispatch table，short `get_arg` 只保留
  Debug 不变式断言；
- `src/exec/call_runtime.zig`：direct-eval `"this"` 快捷路径经
  `slotValueDup` 返回用户值，阻止内部 VarRef cell 成为 frame 输入；
- `src/tests/exec.zig`、`src/tests/bytecode.zig`：结构、alias、seam、GC、async、
  direct eval、malformed、generic opcode 与 sizing 永久回归。

全量 test262 首轮发现的
`staging/sm/class/derivedConstructorArrowEvalGetThis.js` 先被最小化为永久测试，修复前
稳定输出 `true false`，修复后输出 `true true`；原 test262 定向结果由 1/1 失败变为
1/1 通过。这证明删除 guard 确实暴露并清除了一个旧 representation 泄漏，而不是用
新兼容分支遮住它。

### 10.2 I1–I8 逐项证明

| 不变式 | 最终证据 |
|---|---|
| I1 Bare arg slot | resident generator 结构测试直接断言 arg 为裸值；short/generic handler 的 Debug assert 在 1416 项 Debug/16B 套件中通过；direct-eval `this` 输入泄漏另有回归。 |
| I2 Single alias identity | mapped `arguments` payload、open list 与 arg `pvalue` 指针同一；closure、mapped arguments、direct eval、`make_arg_ref` 四个入口经代码图审计全部汇聚 `ensureFrameVarRefCell`。 |
| I3 Stable address | generator 两次 resume 前后 `&frame.args[0]` 不变且 `cell.pvalue` 始终等于该地址。 |
| I4 Exact-enough capacity | bytecode sizing 测试证明 ordinary/generator/async mapped 均为 `static + frame_arg_count`，non-mapped 保持 static，typed tail 在 8B/16B 表示均对齐。 |
| I5 Selective close | `closeParameterEnvironmentVarRefs` 只保留指向 args 的 open refs；既有 parameter-eval cell-close 测试继续通过，mapped arg ref 跨 body seam 保持 open。 |
| I6 Close before release | normal completion 与 self-cycle force-GC 测试均观察 cell 先变 closed、最终值保留，逃逸 arguments/closure 继续双向联动；OOM recovery 8/8。 |
| I7 No fallback cellification | helper 先做 frame-membership 检查，off-frame 直接 fail-closed；synthetic frame 回归覆盖 capacity 0、表满与预 cellified，断言 `InvalidBytecode`、arg 值及已占用 entry 不变。 |
| I8 One dispatch representation | 源码无 dual handler/table/selector；ReleaseFast 符号只有一个 0x800 hot table；short handler 224B → 124B，反汇编删除 VarRef tag/class/cold-dispatch 前缀。 |

### 10.3 QuickJS 对齐证据

本地参照 `/home/aneryu/quickjs` HEAD
`04be246001599f5995fa2f2d8c91a0f198d3f34c`：

- `quickjs.c:407-455`：`JSStackFrame.arg_buf` 为裸 `JSValue *`，`JSVarRef.pvalue`
  为 side pointer；
- `16997-17052`：arg capture 令 `pvalue = &sf->arg_buf[var_idx]`；
- `17521-17543`：close 时复制值并把 `pvalue` 改指自有 storage；
- `18557-18612`：通用及 short arg opcode 都直接访问 `arg_buf`；
- `20892-20988`：generator/async 共用 resident `JSAsyncFunctionState`，完成前 close。

本次新增的 `zjs-side adaptation:` 注释分别记录 resident args/locals 共用 typed
backing 的容量与 parameter seam，以及内部 JSValue cell representation 在 direct-eval
快捷路径必须先解引用；它们都维持 QuickJS 的外部模型，而非新增第二种 arg
representation。

### 10.4 二进制结构

构建命令：`zig build zjs -Doptimize=ReleaseFast --summary all`。

| binary | sha256 | text | data | bss | dec |
|---|---|---:|---:|---:|---:|
| guard | `031282a6d1a62e6bcd6e07ba232643b763b245f516a3f443a75b61cbfb768b30` | 5,092,201 | 203,512 | 264,896 | 5,560,609 |
| dual | `dba18078bc4e39a4b34b097b87316a02ef22b14681bb7406f78ffb9559bcd852` | 5,092,421 | 205,560 | 262,592 | 5,560,573 |
| candidate | `0fdc3bc466e2bf3ea6c355f3503864d719c6685426e989d59f06ecf63dd255d5` | 5,092,833 | 203,512 | 264,272 | 5,560,617 |
| QuickJS | `b76d154265e829e64d14dafba9e8f3eb8f2215ac947ffb62cc31379d1171364d` | 996,267 | 30,008 | 208 | 1,026,483 |

`nm`/`readelf` 证明 candidate 只有
`exec.tailcall_dispatch.dispatch_table`（0x800）及 0x50 property tail table；dual 的
`plain_arg_dispatch_table` 正好额外占 0x800 `.data.rel.ro`。candidate `.data` 总量与
guard 相同，比 dual 少 2,048B；不存在 run selector 符号。

### 10.5 性能原始数据与结论

环境：Linux 6.17.0-1014-nvidia、Cortex-X925、CPU 19、`performance` governor、
perf 6.17.9；事件 `instructions,cycles`。每个 binary 每基准 warm-up 5 次，之后按
`guard,dual,candidate,candidate,dual,guard` 跑 15 blocks。每 block 对同一 binary 的
两个顺序平衡样本取算术均值，再计算 candidate/reference ratio；汇总为 median、
unscaled MAD 与固定种子的 50,000-resample bootstrap 95% CI。

- 32 个基准 × 15 blocks × 6 次 = 2,880 条有效原始样本；
- QuickJS、guard、dual、candidate 的所有基准输出逐字一致；每次 measured output
  也重新校验；fib 输出均为 `2496120`；
- 64 个 cycles candidate/guard、candidate/dual 对比的 CI 上界全部 `< 1.015`；
- 最接近阈值的是 `call-empty-zero-arg-10m.js` 对 dual：median `0.999326`，
  CI `[0.994125, 1.013846]`，仍通过；无需扩到 30 blocks；
- fib candidate/guard instructions median `0.933733`，CI
  `[0.933730, 0.933742]`；cycles median `0.941057`，CI
  `[0.937407, 0.945242]`；
- 11/32 个 candidate/guard cycles 对比的收益超过各自 `3 × MAD`，可声明有测得
  提升；其余项只声明已证明 1.5% 非回退，不夸大统计结论。

完整证据：

- [2,880 条逐次原始值](PEROP-GUARD-ELISION-PERF-RAW.csv)，sha256
  `6ae8437db126c218aa06b5c59008926684551c7880c21aa9ebd720c5ed5078de`；
- [128 条 median/MAD/CI 汇总](PEROP-GUARD-ELISION-PERF-SUMMARY.csv)，sha256
  `2f0f0e7e32093f259d1efbe6d38518ffd52b24d3e0b6ae72056e0f1f60832df1`；
- [环境、binary、benchmark hash 与测量协议](PEROP-GUARD-ELISION-PERF-META.txt)。

### 10.6 最终门禁

| 命令 | 结果 |
|---|---|
| `zig build test-bytecode --summary all` | 88/88 |
| `zig build test-exec --summary all` | 211/211 |
| `zig build quick-check --summary all` | 8/8 steps，CLI smoke 3/3 |
| `zig build checkpoint-check --summary all` | 32/32 steps，Debug 1416/1416 |
| `zig build test-altrepr --summary all` | 16B representation 1416/1416 |
| `zig build test-oom --summary all` | 8/8，含 same-runtime recovery |
| `zig build test262-smoke --summary all` | 12/12 |
| `zig build test262-gate --summary all` | 0/49,775 新错误；44,599 passed；known 2 |
| `zig build test -Doptimize=ReleaseSafe --summary all` | 唯一一次最终运行，1416/1416，9/9 steps |
| `git diff --check` | 通过 |

工作区无双表原型、临时日志、debug tag、测试跳过、exclude 变更或无关 production
改动。§9 的九项交付物均已满足，未完成项：无。

> **勘误（2026-07-16）**：§10.6 的「未完成项：无」曾被 §11 的 review 推翻
> （两条 fail-closed 通道 test262 未覆盖）。R1/R2/R3/R4 与清理项已于同日修复并
> 通过全量门禁（见 §11.5），landing 现已成立。

---

## 11. Landing 后 review 发现（2026-07-16）

max-effort review（9 角度 + 对抗验证 + 补漏），基线为本工作树 candidate 与隔离
`/tmp/zjs-arg-slot-{guard,dual}` 二进制。方案与 §10 的可复验声明全部再现，但门禁
遗漏两条 fail-closed 回归——合法输入被不可捕获的 `InvalidBytecode` 中止。

### 11.1 阻塞收口（landing 前必修）→ 已全部修复（§11.5）

- **R1 [CONFIRMED → FIXED] arguments 运行时救援无预留 window**
  `src/exec/slot_ops.zig:466` / `src/exec/vm_property_globals.zig:213-218,276-278`。
  get_var `arguments` 救援在 `has_mapped_arguments=false` 帧上调
  `createArgumentsObject(mapped=true)`，逐 arg 调 `ensureFrameVarRefCell` 即中止。
  复现：`function f(a){ { function arguments(){} } return arguments[0]; } f(42)`
  → qjs/guard 输出 `42`，candidate `zjs: evaluation failed: InvalidBytecode`
  （try/catch 不可见）。generator 变体、表满变体同样中止。qjs 该形状为**完全
  mapped**（`arguments[0]=5→a==5`、`a=7→arguments[0]==7` 已验证）。
  修复方向：parser/发码侧把 rescue-eligible 形状纳入 open-ref window 预留；
  **不得**降级 unmapped，**不得**恢复 cell 回退（裸 handler 下 cell 回写是
  soundness 洞）。`{arguments}` 简写不触发（parser 已正确置位）。

- **R2 [CONFIRMED → FIXED] runtime_strict 与 parse-time mapped 决策错配**
  `src/exec/object_ops.zig:2450`。`createArgumentsObject` 的 `mapped_override`
  臂只查 `has_simple_parameter_list` 而忽略 strictness；`makeBytecodeView` 的
  `has_mapped_arguments`（`bytecode.zig:8796/8826`，`strict_mode` 含
  `runtime_strict_mode`）在 runtime_strict 下为 false → 无 window，但 parse-time
  的 special_object subtype 1 仍在字节码里 → 同类中止。
  复现：embedder eval-options `.mode=.script,.runtime_strict=true` 跑 sloppy
  源（`forceRuntimeStrict` at `eval_entry.zig:60,252` 置位）。CLI 三处均传 false，
  仅 embedder 面可达。

- **R3 [CONFIRMED → FIXED] eval("this") 快捷路径缺 TDZ 臂**
  `src/exec/call_runtime.zig:4439`。只搬了 `pushThis`（`vm_value.zig:132-135`）的
  cell 解包，漏了 `varRefSlotIsUninitialized → ReferenceError`。derived constructor
  在 `super()` 之前 `eval("this")` 不抛，而是把内部 uninitialized sentinel 泄漏为
  用户值。full-eval 路径正确抛。guard 亦不抛（预存可观测），但该行本次为对齐
  push_this 而改写，未改完。

### 11.2 加固缺口（应随修）

- **R4 [PLAUSIBLE → FIXED] put_arg/set_arg 来值 cell 未洗白**
  `src/exec/slot_ops.zig:124`。丢了 `setSlotValueRefCounted:421-425` 的来值
  unwrap，Debug assert 只查旧值；恶意/合成字节码 `make_arg_ref;drop;put_arg` 可
  注入 cell，guardless `get_arg` 再泄漏——与同 diff 的 fail-closed 加固不对称。
  仅 malformed 字节码可达（无反序列化器）。对等修复：对来值加同款 assert 或
  fail-closed，把检测移到注入点。

### 11.3 清理项（可随修或另开小 commit）

- `frame.zig:727` `argSlotContains` 与 `Frame.slotIndexInSlice:794` / `slotInSlice`
  三份同谓词（新副本还有 overflow-catch 风格漂移）；可坍缩为
  `return slotIndexInSlice(slot, self.args) != null`。
- `slot_ops.zig:461` `ensureFrameVarRefCell` 前导双重 `slotInSlice(args)` + 双
  `varRefCellFromValue`，locals 暖通道新增 ~10insn；改 locals-first 分类可等价消除。
- `frame.zig:717` `closeParameterEnvironmentVarRefs` 是 `closeOpenVarRefs` 加一行
  过滤的第三份关闭仪式拷贝。
- `slot_ops.zig:128` put/set_arg 4 行存尾重复；bare-slot assert 内联四份。
- `frame.zig:747` `ensureOpenVarRefSlots` 仍按 static `open_var_ref_count` 尺寸，
  与新不变式矛盾（dead-by-construction 隐患）。
- `src/tests/exec.zig:124` 手写 `rejected` flag vs `std.testing.expectError` 惯用法。

### 11.4 门禁盲区

test262 语料对 annexB `function arguments(){}` 后读 `arguments`、以及
embedder runtime_strict-forced sloppy `arguments` 两种形状无覆盖。R1/R2 的最小化
永久回归须补入 `src/tests/exec.zig`，防止再次回灌绿灯。

### 11.5 修复落地（2026-07-16，workflow 驱动）

分支 `fix/perop-guard-elision-rescue`。修改文件与实现：

- **R1** `src/bytecode.zig`：新增 compile-time predicate
  `functionRescuesImplicitArgumentsViaGetVar(fb)`——扫描字节码里对 `arguments`
  atom 的 `get_var`/`get_var_undef`（经 `fb.closureVar()` 解析，与运行时救援读的
  同一 atom），arrow 早退。仅 OR 进 `has_mapped_arguments`（其唯一 production
  reader 是 `frameOpenVarRefStorageCount` 窗口尺寸），**不碰**
  `materializes_arguments_object` 与三个 strict-inline 分类字段。选 approach B2
  而非 A（改 parser 发 prologue，跨整个 arguments-resolution 面、回归风险高）。
  qjs 锚点 quickjs.c:32970-32974/24220-24227/36579-36586。
- **R2** `src/exec/object_ops.zig`：`createArgumentsObject` 的 `mapped_override`
  臂加 `!currentFrameFunctionIsStrict(frame)`（镜像 else 臂），force-strict 帧
  降级为 **unmapped**（strict 语义正确）→ 无需 window、不入 fail-closed。与 R1
  独立。qjs 锚点 quickjs.c:34864。
- **R3** `src/exec/call_runtime.zig`：eval("this") 快捷路径加
  `if (slot_ops.varRefSlotIsUninitialized(this_value)) return error.ReferenceError;`，
  与 `vm_value.pushThis` 逐字对齐（TDZ 臂先于解包）。super() 之后行为不变。
- **R4** `src/exec/slot_ops.zig`：`execPutArg`/`execSetArg` 对来值加同款
  Debug-gated `varRefCellFromValue(value)==null` assert（对称于 gateway 加固）。
- **清理** `src/exec/slot_ops.zig` `ensureFrameVarRefCell` 改 locals-first 单次
  分类、删死 `frameSlotCanOpenAlias`；`src/exec/frame.zig` `argSlotContains`
  坍缩为 `slotIndexInSlice(slot, self.args) != null`。逐案等价已核。

永久回归（`src/tests/exec.zig`）：R1 `implicit arguments runtime rescue
preserves mapped aliases`（rescue 读/双向别名/捕获闭包/generator 五形态）、
R2 `runtime-strict eval overrides parse-time mapped arguments subtype`（断言
`5 7 9 TypeError` unmapped 语义）、R3 `derived constructor direct eval this
shortcut preserves TDZ`（bytecode.zig 另有 R1 的 sizing 测试转绿）。

门禁（全部独立复跑）：

| 命令 | 结果 |
|---|---|
| `zig build test-bytecode` | 89/89 |
| `zig build test-exec` | 214/214 |
| `zig build quick-check` | 8/8 |
| `zig build checkpoint-check` | 全绿 |
| `zig build test-altrepr` | 1420/1420（16B repr）|
| `zig build test-oom` | 8/8 |
| `zig build test262-smoke` | 12/12 |
| `zig build test262-gate` | `0/49775 errors, passed 44599, known 2`——**零新失败** |
| `zig build test -Doptimize=ReleaseSafe` | 1420/1420 |
| `git diff --check` | 通过 |

复现平价：candidate2 与 qjs 在全部 R1/R3 复现 + 对抗自造边界用例上逐字节一致；
R3 由 `evalThrew: no, leaked: object` 转为 `evalThrew: ReferenceError, leaked:
undefined`（= qjs）。test262 passed 计数不变（44599）——证实 §11.4 盲区确实存在，
R1 修复的 annexB 形状不在语料内，故永久回归是唯一防回灌屏障。

**已知残留（非本次引入，guard 二进制逐字节重现，另行处理）**：①全局
`var arguments=...` + rescue 形状下 zjs 读全局绑定而非 arguments 对象；②strict
`function arguments(){}` 的 SyntaxError 文本与 qjs 不同（错误文本按计划不对齐）。
