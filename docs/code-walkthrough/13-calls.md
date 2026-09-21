# 13 — 调用、构造、eval、闭包与 native 边界

本册讲 JS 的 `[[Call]]` / `[[Construct]]`、宿主再入、直接/间接 eval，以及闭包捕获。源码在 `src/exec/`。语义权威是 ECMA-262；对照实现是 pinned QuickJS 的 `JS_CallInternal` / `JS_CallConstructorInternal`（native 调用对照 `js_call_c_function` quickjs.c:17562 与 `OP_call_method` 18220，构造对照 quickjs.c:20809–20951）。

子文件：

| 文件 | 覆盖 |
| --- | --- |
| [13-calls.md](13-calls.md) | 流水线总览（本文） |
| [13-calls-runtime.md](13-calls-runtime.md) | `call_runtime.zig`：`OP_call`、分发、inline、apply/call、bound |
| [13-calls-runtime-construct.md](13-calls-runtime-construct.md) | `call_runtime.zig`：`[[Construct]]`、same-Machine `new`、Realm |
| [13-calls-runtime-env.md](13-calls-runtime-env.md) | `call_runtime.zig`：全局词法、间接 eval、generator、instanceof |
| [13-calls-call.md](13-calls-call.md) | `call.zig`：host 全局、唯一 Bound 创建、Object.* 无 Realm 数据平面、`evalGlobalScriptSource` |
| [13-calls-construct.md](13-calls-construct.md) | `construct.zig`：剩余构造体（`objectConstructorValue`、WeakRef/DOMException、TypedArray 复制） |
| [13-calls-site.md](13-calls-site.md) | `call_site.zig` + `host_invocation.zig`：resolved-once CallSite |
| [13-calls-eval.md](13-calls-eval.md) | `eval_entry.zig` + `eval_ops.zig`：脚本入口与直接 eval |
| [13-calls-closure.md](13-calls-closure.md) | 历史：`c_closure` 执行器已删（ClassId 16 空位保留） |
| [13-calls-native.md](13-calls-native.md) | `native_legacy.zig`：`InternalEntry` → `NativeEntry` thunk |

## 1. 一次 JS 调用怎么走

```
opcode OP_call / OP_tail_call / OP_call_method
        │
        ▼
 execCall / vm_call  （操作数窗口零拷贝：func + args 仍在调用者栈上）
        │
        ├─ allow_inline 且 resolveInlineTarget 命中
        │     → InlineCallRequest（req_out）
        │     → Machine.push*Entry + tailcall_dispatch
        │     → 严格模式 `return f(...)` 的 OP_tail_call 复用调用者帧
        │
        └─ 否则 callValueOrBytecodeRootPreRootedInternal
              │
              ▼
        callValueOrBytecodeDispatchAfterInterruptPoll
              │
              ├─ FunctionBytecode 裸值     → callRawFunctionBytecode
              ├─ bytecode_* 函数对象       → callFunctionObjectBytecode
              ├─ Proxy 且 target 可调用    → object_ops.callProxyApply
              ├─ c_function / bound / data → callNativeCallableObject
              │     ├ NativeEntry 记录     → builtin_dispatch
              │     ├ InternalCallableTag  → Promise/async 合成函数
              │     ├ hostFunctionKind     → print/console
              │     └ 名字慢路             → callNativeCallableByName
              │           ├ Object [[Call]] → objectConstructorValue
              │           ├ 无/空 dispatch 名 → undefined
              │           └ 有名链尽         → TypeError
              └─ 其余                     → TypeError "not a function"
```

宿主 → JS（`JSContext.callFunction`、内建回调）不走 opcode，走 `CallSite`：

```
CallSite.init / initInternal     解析一次：class + inline 资格 + Realm
        │
        ▼
CallSite.call / call0..call4
        │  pollInterrupt 一次
        ├─ bytecode 臂 + 当前 Machine 匹配 → runSyncInlineRouteCopiedArgs（压 .native_boundary Entry）
        ├─ 无活动 invocation + host_eligible → HostInvocation.publish 再走同一条
        └─ generic（bound / proxy / native / generator / 跨 Realm）
              → callValueOrBytecodeDispatchAfterInterruptPoll（JS_Call 形根路径）
```

`new F(...)` / `OP_call_constructor`：

```
constructValueOrBytecodeWithNewTarget
        │  pollInterrupt（调用者 Realm，一次）
        ├─ Proxy trap                    → constructProxy
        ├─ bound                         → 合并 boundArgs，递归
        ├─ 普通字节码函数对象            → constructOrdinaryBytecodeFunctionObject
        │     派生类：this = uninitialized，无实例
        │     基类：js_create_from_ctor 实例再跑体
        │     same-Machine 快路径：resolveSameMachineConstructor
        ├─ TypedArray 元数据             → typedArrayConstructVm
        │     TypedArray 源复制：constructTypedArrayTypedArrayInput
        ├─ Date/String/RegExp/Array/…    → NativeEntry construct 记录或域 *ops
        ├─ Number/Boolean/WeakRef/FR/Iterator/Proxy
        │                                → 唯一 helper（不造空对象兜底）
        └─ 非法                          → TypeError "not a constructor"
```

## 2. 必须记住的不变量

- **参数就地**：`OP_call` 不拷 `argv`；窗口活到调用结束才 `popOwnedStackRegion`。`copy_argv=true` 只给 C-API / `JS_Call` 形入口。
- **Realm**：`global` 是本次调用的 Realm 权威，不经共享 VM 状态转发。Bound/Proxy 包装工作在调用者 Realm，最终字节码臂才切到函数 Realm。
- **异常一轨**：`HostError` 在 native thunk 里变成 `JSValue.exception` 哨兵；`ctx.hasException()` 必须一致。
- **尾调用**：严格模式普通调用的 `return f(...)` 降成 `OP_tail_call`，复用调用者帧（相对 pinned QuickJS 的文档化分叉）。方法位置尾调用仍不在范围内。`return eval(...)` 若 callee 不是 `%eval%`，`execDirectEval` 产出 `tail_inline`。
- **CallSite resolved-once**：`init` 付 class 检查 / `resolveInlineFunction` / Realm / pin；`call` 只做 poll + 压 Entry + 跑到边界。
- **直接 vs 间接 eval**：直接 eval 用调用者作用域种子（`createDirectEvalClosureSeed`）和调用者 `this`/`new.target`；间接 eval 编译为 `eval_indirect`，`this` 是全局对象，sloppy `var` 进全局变量环境。
- **字节码闭包捕获**在 `object_ops.createRootBytecodeFunctionObject` + 帧 `captureLocal`/`captureArg`。`c_closure` 执行器已删（ClassId 16 空位保留）。

## 3. 覆盖核对

- 清单函数数: 437
- 本文标题覆盖: 见各子文件；核对命令：

```sh
python3 docs/code-walkthrough/_check_coverage.py \
  --docs 'docs/code-walkthrough/13-*.md' \
  src/exec/call.zig src/exec/call_runtime.zig src/exec/construct.zig \
  src/exec/call_site.zig src/exec/call_site.zig \
  src/exec/eval_entry.zig src/exec/eval_entry.zig \
  src/exec/call.zig src/exec/builtin_dispatch.zig
```

- 未覆盖: 无（以该命令 `missing 0` 为准）
