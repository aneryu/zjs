# Stack Bytecode VM Status And Evolution Boundary

本文记录当前 stack bytecode VM 的真实边界，并回答是否应迁移到 register /
accumulator bytecode。字段级 QuickJS 对照见
[子系统差异基线](qjs-align/SUBSYSTEM-DIFFERENCE-BASELINE-2026-07-27.md)。

## 1. Current Answer

zjs 已经是 bytecode interpreter：

- `parser.zig` 解析并发射 QuickJS-aligned stack bytecode；
- `bytecode.zig` 完成 resolve、stack-size、pc2line 和 finalize；
- `zjs_vm.zig` / `tailcall_dispatch.zig` 执行 opcode；
- `vm_*.zig` 和 `vm_property_*` 承担具体 opcode family。

当前没有证据支持改写为 register/accumulator VM。语义、call frame、module、
eval、ownership 和通用 dispatch 的已知差异更具体，也更适合逐项与 QuickJS
对照。

## 2. Current Carriers

编译期载体：

- `FunctionDef`：变量、scope、child function、source/debug 和 emitter 状态；
- lowered `Bytecode`：pipeline 的可变 code/metadata。

发布后的生产执行载体：

- canonical GC-managed `FunctionBytecode`；
- 96-byte QuickJS-aligned core header；
- packed constant/var/closure/code data；
- optional 32-byte debug tail；
- zjs-only 8-byte call-facts/script-or-module tail。

script、eval、nested function 和 module root 都执行 canonical
`FunctionBytecode`。没有单独的 `CodeBlock`，也没有 property IC slots。

## 3. Frame And Dispatch

主要入口：

- `src/exec/frame.zig`: `Frame`, `FrameSlab` 和 frame-owned windows；
- `src/exec/stack.zig`: operand stack；
- `src/core/runtime.zig`: per-runtime `VmStackArena`；
- `src/exec/inline_calls.zig`: same-loop `Machine` frame push/pop；
- `src/exec/tailcall_dispatch.zig`: threaded/tail-called opcode handlers；
- `src/exec/call_runtime.zig`: call/eval/generator/Atomics shared runtime glue。

普通同步 bytecode frame 优先从 runtime arena carve
`[args | locals | operand | var-ref metadata]`。generator/async frame 必须在
suspend 后继续存活，所以拥有可转移的 resident storage，而不是借用 arena。

VM 中的运行值依靠 refcount-on-push 和 frame deterministic teardown 保活。
`ValueRootFrame` 用于宿主/builtin 边界，不是每个 VM frame 的通用 root
registration。

## 4. Property Access

当前没有 inline cache：

- `src/core/ic.zig` 不存在；
- `FunctionBytecode` 没有 site/slot table；
- `zjs_enable_ic` 不存在。

`src/exec/property_ic.zig` 是历史文件名，当前保存的是非缓存 direct
shape/property/global fast paths。每次访问都检查当前 object/shape/property
状态；两个 retained `cached*` adapter 恒 miss。

## 5. Tail Calls

VM 能执行 `tail_call` / `tail_call_method`，并可用
`Machine.tailCallReuse` 替换 inline frame。这是 bytecode ABI/内部能力。

默认 source compiler 与 pinned QuickJS 当前 parser 都产生普通 call+return，
不把源码自动 lower 成 proper tail calls。`test262.conf` 跳过
`tail-call-optimization`。因此文档和发布说明不得声称产品级 PTC 已启用。

## 6. zjs-Specific Call Machinery

为缩小 Zig frame/dispatch 固定成本，当前 FunctionBytecode 和 Machine 还包含：

- simple-inline eligibility；
- empty/exact/padded/capture leaf 分类；
- forwarded `Function.prototype.call` leaf；
- narrow leaf frame constructors and return epilogues；
- simple-field constructor body bypass 及 runtime memo。

这些不是 property IC，但其中多项也没有 pinned QuickJS 对应机制。它们是当前
QuickJS-faithful policy 的审计对象，不能继续以 microbenchmark 结果自动扩大。
保留或删除必须依据：

1. 对应 QuickJS 机制；
2. observable/exception/OOM/interrupt/realm 边界；
3. controlled instructions/allocations/time A/B；
4. focused + checkpoint/production gates。

## 7. Current Capabilities

已经落地：

- QuickJS-aligned stack opcode execution；
- stack-depth validation；
- pc2line/source-location diagnostics；
- canonical `FunctionBytecode`；
- same-loop bytecode call frames；
- explicit generator/async resident-frame ownership；
- direct and indirect eval entry；
- catch/finally and pending JS exception propagation；
- optional opcode profiling；
- four zjs-only explicit-resource-management opcodes。

未实现：

- register/accumulator bytecode；
- baseline JIT；
- call or property inline cache；
- JIT GC stack maps；
- moving nursery；
- concurrent collector；
- public standalone `CodeBlock`/bytecode serialization API。

## 8. Near-Term Work

保持 stack bytecode，优先：

- 用 current pinned qjs 拆解 call admission、frame publication、return 和 RC
  fixed tax；
- 审计 zjs-only leaf/body-bypass 机制；
- 收敛 direct-eval binding mechanism；
- 强化 generator/async/module exception 和 OOM ownership tests；
- 改善 source-location coverage；
- 继续按 ownership domain 收窄 `call_runtime.zig`，但不为行数指标强拆
  shared state。

只有当语义门禁稳定、call/property/array/string 等热点已用 qjs 机制收敛，且
PMU 证明 operand traffic/dispatch 是主瓶颈时，才重新评估 bytecode 架构。
