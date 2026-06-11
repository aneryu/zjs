# ZJS Current Architecture Snapshot

本文记录当前源码中的架构状态，而不是历史路线图、口号式目标或未落地的
设计承诺。语义参考仍是 QuickJS；验证边界以根目录 `test262.conf`、
`test262/` 和 Zig regression 为准。

## 1. Runtime And Ownership

当前运行时核心在 `src/core/`：

- `runtime.zig`: `JSRuntime`、`JSContext`、根追踪、GC 调度和宿主资源。
- `value.zig`: `JSValue` 表示与引用计数入口。
- `object.zig`: JS 对象、属性表、prototype、class payload 和 child-edge tracing。
- `function_bytecode.zig`: GC 管理的函数字节码对象。
- `gc.zig`: GC registry、policy、外部内存记账、nursery/remembered-set 结构和统计。

已落地的生命周期模型是：

- 非原子引用计数负责大多数对象的即时释放。
- `runObjectCycleRemoval` / `tryRunObjectCycleRemovalWithValueRoots` 负责
  root-aware 的对象与 `FunctionBytecode` 环清理。
- `ValueRootFrame` 是当前 VM 和宿主边界使用的显式根链表。
- `FrameRootScope` 会把 VM operand stack、locals、args、var refs 和 eval
  snapshot 挂到 `JSRuntime.active_value_roots`。
- 宿主持有跨调用生命周期的值时，必须使用 public API 中的 handle /
  persistent-root 机制，而不是裸保存 `JSValue`。

`src/core/gc.zig` 已包含 nursery、remembered set、minor request、external memory
accounting 和 GC scheduler 的实现骨架与测试覆盖；但不要把它理解成已经具备
moving generational / concurrent old-space GC 的完整生产实现。默认语义仍以
引用计数、显式根和环清理为主。

## 2. Frontend And TypeScript Erasure

当前 frontend 在 `src/frontend/`：

- `parser.zig` 是 public parse wrapper。
- `zjs_lexer.zig` 提供 lexer、source-kind 判断和 TypeScript erasure。
- `zjs_parser.zig` 是 QuickJS-aligned parser/emitter。
- `source_pos.zig` 和 `zjs_token.zig` 提供位置与 token 支撑。

TypeScript 支持是语法擦除，不是类型检查器：

- `parser.parse` 根据 `SourceKind` 和文件名调用 `zjs_lexer.shouldStrip`。
- 需要擦除时调用 `Lexer.enableTypeScript()`。
- `enableTypeScript` 设置 `is_typescript`，并由 `markTypeRanges` 生成
  `skipped_intervals`。
- lexer 在扫描时跳过这些区间，让 parser 消费近似纯 JS 的 token stream。

这条路径只应描述为“当前支持的 TypeScript 语法擦除”。不要在文档中承诺完整
TypeScript 语义、类型检查、source-map 等价物或固定性能提升百分比。

## 3. Bytecode Carrier

当前执行载体是 `src/bytecode/function.zig` 中的 `Bytecode`，不是单独的
`CodeBlock` 抽象。`Bytecode` 持有：

- opcode bytes: `code`
- constants: `constant.Pool`
- atom operands
- args、vars、var refs、global vars、private names
- module metadata
- `pc2line_buf`、`source_loc_slots`、`debug_table`
- property inline-cache slots: `ic_slots`、`ic_site_ids`、`ic_sites`

pipeline 入口在 `src/bytecode/pipeline/`：

- `resolve_labels.zig`
- `resolve_variables.zig`
- `stack_size.zig`
- `pc2line.zig`
- `finalize.zig`

`stack_size.zig` 负责按字节码图计算最大 stack depth，并验证 underflow、
overflow、stack mismatch 和无效 opcode 等错误。它不是完整 JIT-style GC
stack-map 系统。

## 4. VM Execution

当前 VM dispatcher 是 `src/exec/zjs_vm.zig`。Phase 1 执行模型改进已落地：

- **连续 VM 栈**：`JSRuntime.vm_stack`（`VmStackArena`）为 `[args | locals | operand]` 提供
  arena 窗口；普通字节码调用的 operand stack 与 frame locals/args 优先从 arena 雕刻，
  替代每调用 `Stack.init` 堆分配（generator/async 仍用堆栈）。
- **同循环内联调用**：`src/exec/inline_calls.zig` 的 `Machine` 在 `dispatchLoop` 内
  push/pop 字节码帧，替代递归 `runWithArgsState`；`catch_target` 按 inline 帧记录。
- **零拷贝参数**：`Frame.initArgumentsFromStack` 从 operand stack 转移参数所有权，
  仅 `argc < arg_count` 时补 `undefined`。
- **CallEnv**：`runWithCallEnv` 收敛原 25 参数 `runWithArgsState` 入口面。
- **热路径门控**：`-Dzjs_enable_opcode_profile=true` 才编译 per-opcode profile scope；
  `stopBeforePc` 仅在 generator resume 外壳生效；backtrace 使用 lazy name 解析。

待完成：L0 真 TCO（帧复用，`test262` `tail-call-optimization` 仍 skip）；`tailCallReuse`
/`reinitEntry` 已实现但未安全接线。

Opcode family 仍拆到 `src/exec/vm_*.zig`：

- arithmetic: `vm_arith.zig`
- calls: `vm_call.zig`
- control flow: `vm_control.zig`
- eval/modules: `vm_eval_module.zig`
- exceptions/backtrace: `vm_exception_ops.zig`
- generators/async: `vm_gen_async.zig`
- literals: `vm_literal.zig`
- property opcodes: `vm_property.zig`
- regexp: `vm_regexp.zig`
- value operations: `vm_value.zig`
- opcode profiling helper: `vm_profile.zig`

Shared execution helpers still live in `src/exec/shared.zig`; current perf docs
track ongoing decomposition work, but `shared.zig` has not disappeared.

Frame state is in `src/exec/frame.zig` and operand stack state is in
`src/exec/stack.zig`. `Frame` includes small inline argument buffers
(`inline_args: [4]JSValue`) for common call shapes, plus locals, args, var refs
and eval-specific binding snapshots.

Exception handling uses both Zig errors and VM-level catch handling:

- uncaught JS exceptions bubble through Zig error returns.
- catchable runtime errors are routed by VM catch-target handling.
- backtrace source locations resolve through `source_loc_slots` and `pc2line_buf`
  where available.

## 5. Object Shapes And Property IC

Object-shape state lives in `src/core/shape.zig`; IC slot storage lives in
`src/core/ic.zig`, with `src/bytecode/ic.zig` kept as a compatibility import path.

Property opcode fast paths are implemented in `src/exec/property_ic.zig` and used
from `src/exec/vm_property.zig`. Current IC behavior is shape/version guarded and
tracks the states:

- `empty`
- `mono`
- `poly`
- `mega`
- `invalid`

The active IC covers own/prototype data-property fast paths and records feedback
through `core.OpcodeProfile`. It is not a call inline cache and it is not JIT
metadata. Builds can disable property IC with `-Dzjs_enable_ic=false`.

## 6. Modules, Promises, And Jobs

Execution support beyond the VM loop is split under `src/exec/`:

- `module.zig` and `module_graph.zig`: module records, linking/evaluation and
  graph lifecycle.
- `promise.zig` and `promise_ops.zig`: Promise objects and abstract operations.
- `jobs.zig`: job queue integration.
- `call.zig`, `construct.zig`, `eval.zig`, `eval_entry.zig`: call/eval/construct
  entrypoints and binding behavior.

## 7. Host Runtime Policy

Host/runtime policy helpers live in `src/runtime/` and are re-exported through
the public runtime namespace:

- `event_loop.zig`: timers, file-descriptor handlers, signal handlers and job
  draining around a `JSContext`.
- `cleanup.zig`: Atomics waiter and worker cleanup helpers.
- `modules.zig`: file-based module graph evaluation and specifier resolution.
- `plugin.zig`: native plugin loading and installation helpers.
- `buffer.zig`: buffer/ArrayBuffer host operations.

This layer is separate from `src/core/`; core runtime/context/value ownership
must stay independent of host event-loop and plugin policy.

## 8. Validation Map

Use the narrowest validation that covers the changed surface:

```sh
zig build zjs --summary all
zig build smoke --summary all
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build test262-gate --summary all
zig build architecture-check --summary all
git diff --check
```

For parser, runner, execution, or semantic compatibility changes, run a focused
test262 slice before relying on the full gate.
