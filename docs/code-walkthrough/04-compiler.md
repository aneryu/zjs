# 04 — compiler：Builder、变量解析、标签布局

本册覆盖 `src/compiler/`：parser 发射的紧凑临时字节码，经 **resolve_variables → resolve_labels** 变成可执行最终码。语义权威是 ECMA-262；身份规则以 [compiler-contract.md](../compiler-contract.md) 为准。QuickJS `resolve_variables` / `resolve_labels` 是对照实现。

子文件：

| 文件 | 覆盖 |
| --- | --- |
| [04-compiler-builder.md](04-compiler-builder.md) | `builder.zig`：临时流、标签槽、重定位、snapshot/rollback、detach/splice |
| [04-compiler-temp-stream.md](04-compiler-temp-stream.md) | `temp_stream.zig`：两路 resolve 共用的 bind 索引行、phase-1 指令视图、SourcePoint |
| [04-compiler-resolve-variables.md](04-compiler-resolve-variables.md) | `resolve_variables.zig`：作用域 lowering、死代码、S3 产物 |
| [04-compiler-resolve-labels.md](04-compiler-resolve-labels.md) | `resolve_labels.zig`：最终布局、跳转穿线、short/plain |
| [04-compiler-tests.md](04-compiler-tests.md) | `test_entry.zig`、`tests.zig`：测试入口与 harness |

本文件讲身份模型、管线顺序、`labels.zig` 与 `root.zig`。

## 1. 管线：一次函数怎么被 lower

`pipeline_finalize.createFunctionBytecode` 的树递归（`createFunctionBytecodeAfterChildren`，`bytecode.zig:10825`）对每个 `finalization_state == .prepared` 的 `FunctionDef` 调 `compileFunctionForPackedFinalize`；`compileFunction` 由片段级入口 `runWithFunctionDef` / `runWithFunctionDefRuntime` 经 `lowerAttachedBuilder`（`bytecode.zig:11037`）调用：

```
parser 发射
    │  compact temp stream：opcode + 立即数 + LabelId + Atom + scope
    │  旁表：LabelSlot[] / RelocEntry[] / SourceSlot[]
    ▼
Builder（builder.zig）
    │  跳转操作数永远是 LabelId（LE u32），不是绝对 PC
    ▼
resolve_variables.run  （Stage 3）
    │  只读 Builder
    │  建 BindEntry 索引
    │  作用域 lowering → 死代码 skip（qjs update_label 记账）
    │  输出 ResolvedProduct：code / atom ledger / 更新后的 LabelSlot / source
    │  first_reloc 清空；ref_count 按 qjs update_label 记账
    ▼
releaseConsumedBuilder
    │  S3 是临时流最后一个读者；Builder 在此释放
    ▼
resolve_labels.run / runForPackedFinalize  （Stage 4）
    │  前向走 S3 产物，写最终码
    │  绑定点变成输出 PC；跳转写成相对位移
    │  layout=short（生产）或 plain（A/B 诊断）
    │  原子/源码槽提交到 Bytecode
    ▼
FunctionBytecode 打包（bytecode.zig，05 册）
```

**顺序不可颠倒。** S3 决定「哪些指令活着、变量绑到哪一格、LabelId 的 ref_count」。S4 才第一次出现字节地址。契约：parser 不得把绝对 PC 写进跳转操作数；相对位移只存在于 `resolve_labels.zig` 最终布局。

## 2. 身份：LabelId / LabelSlot / RelocEntry

### `LabelId`

函数内创建序号，`enum(u32)`。detach/splice 时块带着自己的 `LabelId` 走，操作数字节**不改写**；只有槽里的 `bound_offset` 随新基址重绑。

### `LabelSlot`

每个标签一行：

| 字段 | 含义 |
| --- | --- |
| `bound_offset` | 绑定位置。S1/S3 输入是临时流偏移；S3 输出是产物偏移；未绑定或死区为 `unbound`（`maxInt(u32)`） |
| `ref_count` | qjs `update_label` 记账。每条引用发射 +1，rollback/detach/死代码 −1。S3R 之后**不是**活性输入；S4 short-form 选宽仍用它 |
| `first_reloc` | 该标签待改写操作数链头。S3 产物上恒为 `no_reloc`；S4 再建自己的 `FinalReloc` 链 |
| `flags.bound` | 是否已绑定。每个创建的标签必须结束于 bound；死标签由 resolve 丢掉 |
| `flags.backward_target` | 引用发出时目标已绑定（或 splice 后绑定点在操作数之前）。short-form 保守标记；rollback **不清** |
| `flags.match_barrier` | 身份版 `OP_label`：即使 ref 清零，S4 也不得跨此绑定做顺序匹配折叠 |

### `RelocEntry`

待改写的一个操作数：`operand_offset` + `kind`（`.jump32` 跳转 4 字节 / `.aux32` 如 `scope_make_ref` 的辅标签）+ `next`。链按 reloc 下标**严格递减**压头；rollback/detach 依赖这个顺序。

### 绑定 vs 重定向

- `bindLabel`：把身份钉在当前 `code_len`（块边界）。双绑、外标签 fail-closed。
- `retargetLabelRefs(from, to)`：把 `from` 上所有待引用挪到已绑定的 `to`（switch 无匹配 → default）。操作数里的 `LabelId` 改成 `to`，链按递减下标归并。`from` 随后绑定到与 `to` 同一偏移（每个身份必须结束 bound）。这不是二次 bind，也不使 `last_opcode_pos` 失效。

## 3. short vs plain 布局

`resolve_labels.LayoutMode`：`.short` | `.plain`。`default_layout` 来自 `-Dzjs_compiler_layout`，配置签名读的是这个声明。

| | `short`（生产） | `plain`（A/B 诊断） |
| --- | --- | --- |
| 槽族 | `get_loc0`…`get_loc8` 等短形式 | 保持宽 `get_loc`+u16 |
| 跳转 | `goto8`/`if_false8`/`goto16`；`relaxJumps` 再压窄 | 保持 5 字节相对 i32 |
| 立即数 | `push_0`/`push_i8`… | 一律 `push_i32` |
| 融合 | `get_loc0_field`、`cmp_if_false8` 等 | 不融合 |

两条路径读同一套 S3 `LabelId` 流；差异只在最终编码。`.plain` 用来定位布局敏感回归，不是第二条语义。

## 4. 文件级类型（`labels.zig`）

`unbound` / `no_reloc` 都是 `u32` 全 1。`LabelFlags` 是 `packed struct(u8)`。`RelocKind` 只有 `jump32` 与 `aux32`。这些形状 API-frozen：改形状要 driver 决定。

---

## `labels.zig`

### `LabelId.index` (`src/compiler/labels.zig:15`)

- **签名**：`pub fn index(self: LabelId) u32`。
- **作用**：把函数局部标签身份还原成槽下标，供数组索引和 LE 操作数写入。
- **实现**：`@intFromEnum(self)`。无分支。
- **所有权 / 错误 / 调用**：无分配。`Builder.emitJump`、reloc 链、CFG 边收集都走这里。

---

## `root.zig`

`root.zig` 是 compiler 包入口：re-export `temp_stream` / `builder` / `labels` / 两路 resolve，以及 `compileFunction`。

### `compileFunction` (`src/compiler/root.zig:37`)

- **签名**：`pub fn compileFunction( function: *bytecode.Bytecode, fd: *bytecode.function_def.FunctionDef, ) resolve_variables.Error!void`。
- **作用**：每个 `FunctionDef` 的唯一 lowering：S3 产物 → 立刻释放 Builder → S4 最终发射，把最终码装进 `function`（finalize 的 staging 载体）。树递归与 packed ABI 在 `createFunctionBytecode`。
- **实现**：`var product = try resolve_variables.run(function, fd); defer product.deinitUncommitted();`，然后 `releaseConsumedBuilder(fd)`，再 `resolve_labels.run(default_layout, …)`。S4 只证明源槽；码/atom/var-ref 的最终证明留给 packed finalizer 的一次融合遍历。`noinline` 是架构边界，不是内联提示：无关遗留状态删除曾让 LLVM 把 lowering 折进 packed finalizer，crypto/code-load 回退（`docs/qcp1_switch_decision.md` §9.3）。
- **所有权 / 错误 / 调用**：错误来自两路 resolve（OOM / InvalidBytecode / 绑定失败）。`deinitUncommitted` 覆盖 S4 失败：未提交的产物码/atom/标签 backing 被释放；S4 `commit` 成功后码/atom/源已交给 `function`，defer 仍幂等。唯一调用方 `pipeline_finalize.createFunctionBytecodeAfterChildren`。

### `releaseConsumedBuilder` (`src/compiler/root.zig:52`)

- **签名**：`fn releaseConsumedBuilder(fd: *bytecode.function_def.FunctionDef) void`。
- **作用**：在消费点释放 Builder。S3 是紧凑流最后一个读者。
- **实现**：`fd.builder` 为空则返回。置空指针，`consumed.deinit()`，断言五张表 capacity 均为 0，再 `fd.memory.destroy(Builder, consumed)`。
- **所有权 / 错误 / 调用**：所有权在消费者侧。`FunctionDef.deinit` 只做解析失败/中途放弃的后盾。无 error。

---

## 覆盖核对

整册（`04-*.md`）对八个指定源文件合计清单 383 条、标题 383 条、未覆盖无。本文件：

- 清单函数数: 8（`src/compiler/labels.zig` 1 + `src/compiler/root.zig` 7）
- 本文标题覆盖: 8
- 未覆盖: 无

```sh
python3 docs/code-walkthrough/_check_coverage.py \
    --docs 'docs/code-walkthrough/04-*.md' \
    src/compiler/builder.zig src/compiler/temp_stream.zig src/compiler/labels.zig \
    src/compiler/resolve_labels.zig src/compiler/resolve_variables.zig \
    src/compiler/root.zig src/compiler/test_entry.zig src/compiler/tests.zig
```
