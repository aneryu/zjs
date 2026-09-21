# 12 — VM opcode 适配器

本册覆盖 `src/exec/vm_*.zig` 与 `vm_property_*.zig`：热分发（`tailcall_dispatch.zig`，11 册）命中失败或冷 opcode 时落到这里。函数吃操作数栈 / 帧 / `NativeEntry`，不实现 ECMA-262 抽象操作本身（那些在 `*_ops.zig`）。

热路径惯例：

- 分发层把 `pc` / `sp` 留在寄存器；`*At` 变体拿槽指针与已弹出的值，避免再读 `frame.pc`。
- `*Vm` 包装把 Zig error 交给 `call_runtime.handleCatchableRuntimeError`：命中 catch 则 `Step.continue_loop`，否则上抛。
- 栈槽按所有权移动；borrow 快路径必须在形状突变前消费指针。
- 可观察的 ToPrimitive / getter / 构造会再入 JS，必须带着 `output` / `global` / 调用环境。

## NativeEntry：内建与宿主共用一条分发

`NativeEntry`（`src/core/native_entry.zig`）是不可变 48 字节记录：`target` + `kind` + `flags` + `sig` + `arity`。内建表是 comptime rodata；宿主 / 插件条目活在 runtime arena。对象 payload 上的 `c_function` 只缓存 `*const NativeEntry`，不区分来源。

JS → native 的 VM 入口是 `vm_native.dispatch`（`src/exec/vm_opcodes.zig:32`）：

1. `op.call*` 窗口 `[callee, args...]`（`Shape.plain`）；`op.call_method` 窗口 `[receiver, callee, args...]`（`Shape.method`）。
2. `vm_call.resolvedNativeCallTargetAssumeCFunction` 一次走完 payload，取出 entry 与 callee realm。
3. `kind == .leaf` → `builtin_dispatch.invokeLeafFastEntry`（tag 检查 + 直接 C 调用 + 装箱；无环境、无 backtrace、无中断轮询）。
4. `flags.forwards_call`（`Function.prototype.call` / `apply`）返回 `.miss`，让分发层改写窗口而不是走进 managed 体。
5. 其余走 `builtin_dispatch.callRecordFromVmInRealm`：预检、realm、仅当 `needs_env` 才造 native 环境。
6. 异常走 `failure`：丢掉调用窗口，再 `handleCatchableRuntimeError`。

内建（Math.abs、Array.push）和 `zjs.native` 注册的宿主函数是同一条路径。差别只在 entry 字段：`builtin_id` / rodata vs `state` / arena。`managedInlineEligible` / `getterInlineEligible` / `methodManagedInlineEligible` 决定驻留 handler 能否 `bl` 进 managed/getter 快臂，否则退回 `dispatch`。

## 子文件（按 opcode 族）

| 子文件 | 源文件 | 族 |
| --- | --- | --- |
| [12-vm-opcodes-value.md](12-vm-opcodes-value.md) | `vm_value.zig` | 立即数、常量、栈洗牌、`typeof`、drop |
| [12-vm-opcodes-arith.md](12-vm-opcodes-arith.md) | `vm_arith.zig` | 二元算术、比较、inc/dec、`add_loc` |
| [12-vm-opcodes-control.md](12-vm-opcodes-control.md) | `vm_control.zig` | return / goto / if / throw / catch / gosub |
| [12-vm-opcodes-call.md](12-vm-opcodes-call.md) | `vm_call.zig` | call / method / apply / construct / 深度预算 |
| [12-vm-opcodes-native.md](12-vm-opcodes-native.md) | `vm_native.zig` | NativeEntry 分发与 inline 资格 |
| [12-vm-opcodes-literal.md](12-vm-opcodes-literal.md) | `vm_literal.zig` | `{}` / `[]` / define_field / spread / rest |
| [12-vm-opcodes-eval-module.md](12-vm-opcodes-eval-module.md) | `vm_eval_module.zig` | `eval` / `apply_eval` / `import()` |
| [12-vm-opcodes-gen-async.md](12-vm-opcodes-gen-async.md) | `vm_gen_async.zig` | yield / await 驻留与恢复 |
| [12-vm-opcodes-property.md](12-vm-opcodes-property.md) | `vm_property.zig` | 字段原子、全局 IC 门、数组快读 |
| [12-vm-opcodes-property-field.md](12-vm-opcodes-property-field.md) | `vm_property_field.zig` | get/put_field、数组元素、PropSiteCache |
| [12-vm-opcodes-property-globals.md](12-vm-opcodes-property-globals.md) | `vm_property_globals.zig` | get/put_var、全局声明实例化 |
| [12-vm-opcodes-property-locals.md](12-vm-opcodes-property-locals.md) | `vm_property_locals.zig` | loc / arg / var_ref / close_loc |
| [12-vm-opcodes-property-private.md](12-vm-opcodes-property-private.md) | `vm_property_private.zig` | 私有字段 get/put/define |
| [12-vm-opcodes-property-ref.md](12-vm-opcodes-property-ref.md) | `vm_property_ref.zig` | with / make_ref / delete |
| [12-vm-opcodes-regexp.md](12-vm-opcodes-regexp.md) | `vm_regexp.zig` | `OP_regexp` 字面量 |

## `*Vm` 与 `Step`

多数冷适配器返回 `Step = { done, continue_loop }`。`done`：分发层继续下一条；`continue_loop`：catch 已把 `frame.pc` 改到 handler，必须重新进入循环而不是再 `pc += n`。`CallStep` 额外带 `inline_call` / `inline_constructor`，`EvalStep` 额外带 `tail_inline`；`InlineCallRequest` 写进调用方的 `req_out` 槽（`tail_inline` 例外，它把请求带在负载里），避免 sret。

## 覆盖核对

- 清单函数数: 316（本册 15 个源文件在 `_inventory.tsv` 中的行）
- 本文标题覆盖: 见各子文件；聚合核对命令：

```sh
python3 docs/code-walkthrough/_check_coverage.py \
  --docs 'docs/code-walkthrough/12-*.md' \
  src/exec/vm_opcodes.zig src/exec/vm_opcodes.zig src/exec/vm_opcodes.zig \
  src/exec/vm_opcodes.zig src/exec/vm_opcodes.zig src/exec/vm_opcodes.zig \
  src/exec/vm_opcodes.zig src/exec/vm_property.zig src/exec/vm_property.zig \
  src/exec/vm_property.zig src/exec/vm_property.zig \
  src/exec/vm_property.zig src/exec/vm_property.zig \
  src/exec/vm_opcodes.zig src/exec/vm_opcodes.zig
```

- 未覆盖: 无（以该命令 `missing 0` 为准）

当前清单包含 noinline 与嵌套方法。测试条目保留，但不属于本轮讲解验收要求。
